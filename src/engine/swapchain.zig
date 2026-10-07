//! Queue-gated Vulkan swapchain storage. Images are borrowed from Vulkan.
//! All native calls require the existing Device operation and queue gate.
//! Drain runs outside ObjectGuard; retirement requires a completed drain.
const std = @import("std");
const vulkan = @import("vulkan");
const core = @import("../core/root.zig");
const dispatch = @import("../vk/dispatch.zig");
const native_image_state = @import("native_image_state.zig");

pub const max_images = 8;
pub const Error = dispatch.Error || dispatch.LoadError || error{
    SwapchainImageCapacityExceeded, SwapchainImagesUnstable, NoSwapchainImages,
    SwapchainUnavailable,
    InvalidSwapchainGeneration, AcquireEpochExhausted, AcquireSemaphoreInUse,
    StaleSurfaceTexture, SurfaceNotAcquired, SurfaceSubmissionStaged,
    SubmissionCapacityExhausted, SerialExhausted, Canceled,
};
pub const Backend = struct {
    device: vulkan.VkDevice,
    queue: vulkan.VkQueue,
    procs: *const dispatch.DeviceProcs,
    /// Copied only from the central NativeCapabilities.swapchain authority.
    swapchain_available: bool,
};
pub const Token = struct { generation: u64, index: u32, acquire_epoch: u64 };
pub const Accepted = struct { acquire_epoch: u64, serial: u64 };
pub fn nextGeneration(generation: u64) error{SwapchainGenerationExhausted}!u64 {
    return std.math.add(u64, generation, 1) catch error.SwapchainGenerationExhausted;
}
pub const Presented = struct { acquire_epoch: u64, serial: u64, result: vulkan.VkResult };
pub const ImageState = union(enum) {
    available, acquired: u64, submit_accepted: Accepted,
    present_pending: Accepted, present_accepted: Presented, stale,
};
pub const ImageSlot = struct {
    image: vulkan.VkImage = null,
    present_semaphore: vulkan.VkSemaphore = null,
    state: ImageState = .available,
    staged: bool = false,
    /// All aliases borrow these authoritative single-layer/mip image states.
    /// Acquisition changes only the epoch; layout/content survive presentation.
    native_states: [1]native_image_state.NativeUsageState = .{.{}},
    initialized: [1]bool = .{false},
};
pub const Stage = struct { token: Token, wait: ?vulkan.VkSemaphore, signal: vulkan.VkSemaphore };
pub const AcquireResult = union(enum) { success: Token, suboptimal: Token, timeout, outdated, lost };
pub const PresentResult = enum { success, suboptimal, outdated, lost };
/// Central callback performs vkQueueSubmit with its own tracked fence, advances
/// its existing timeline only on success, and returns that accepted serial.
pub const BridgeSubmitError = dispatch.Error || dispatch.LoadError || core.ReferenceError || std.mem.Allocator.Error || error{
    Canceled, DeviceProcTierMissing, RecordingPoisoned, PendingRecordingNotSubmitted,
    FencePoolExhausted, FenceCreationReturnedNull, SubmissionCapacityExhausted,
    SerialExhausted, CommandContextPoolExhausted, CommandPoolCreationReturnedNull,
    CommandBufferAllocationReturnedNull, ResourceInUse, AllocatorMismatch,
};
pub const SerialOwner = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, std.Io, *const vulkan.VkSubmitInfo) BridgeSubmitError!u64,
};

pub const Native = struct {
    backend: Backend,
    handle: vulkan.VkSwapchainKHR,
    generation: u64,
    format: vulkan.VkFormat,
    image_usage: vulkan.VkImageUsageFlags,
    extent: vulkan.VkExtent2D,
    present_mode: vulkan.VkPresentModeKHR,
    queue_family_index: u32,
    acquire_semaphore: vulkan.VkSemaphore,
    slots: [max_images]ImageSlot = @splat(.{}),
    image_count: u32 = 0,
    acquire_epoch: u64 = 0,
    acquire_consumed_serial: u64 = 0,
    current_index: ?u32 = null,
    current_acquire_suboptimal: bool = false,
    stale: bool = false,
    reconfigure_needed: bool = false,
    device_lost: bool = false,
    drained: bool = true,

    pub fn create(backend: Backend, info: *const vulkan.VkSwapchainCreateInfoKHR, generation: u64, queue_family_index: u32, native_accepted: *bool) Error!Native {
        native_accepted.* = false;
        if (!backend.swapchain_available) return error.SwapchainUnavailable;
        if (generation == 0) return error.InvalidSwapchainGeneration;
        if (info.minImageCount > max_images) return error.SwapchainImageCapacityExceeded;
        const p = backend.procs;
        const create_swapchain = p.create_swapchain_khr orelse return error.MissingDeviceProc;
        _ = p.destroy_swapchain_khr orelse return error.MissingDeviceProc;
        const get_images = p.get_swapchain_images_khr orelse return error.MissingDeviceProc;
        const create_semaphore = p.create_semaphore orelse return error.MissingDeviceProc;
        _ = p.destroy_semaphore orelse return error.MissingDeviceProc;
        _ = p.acquire_next_image_khr orelse return error.MissingDeviceProc;
        _ = p.queue_present_khr orelse return error.MissingDeviceProc;
        _ = p.queue_wait_idle orelse return error.MissingDeviceProc;
        var self: Native = .{
            .backend = backend, .handle = null, .generation = generation,
            .format = info.imageFormat, .extent = info.imageExtent,
            .image_usage = info.imageUsage,
            .present_mode = info.presentMode, .queue_family_index = queue_family_index,
            .acquire_semaphore = null,
        };
        try dispatch.checkVkSuccess(create_swapchain(backend.device, info, null, &self.handle));
        native_accepted.* = true;
        errdefer self.deinit();
        var images: [max_images]vulkan.VkImage = @splat(null);
        var settled = false;
        for (0..3) |_| {
            var count: u32 = 0;
            const query = get_images(backend.device, self.handle, &count, null);
            if (query != vulkan.VK_SUCCESS and query != vulkan.VK_INCOMPLETE) try dispatch.checkVkSuccess(query);
            if (count > max_images) return error.SwapchainImageCapacityExceeded;
            if (count == 0) return error.NoSwapchainImages;
            const result = get_images(backend.device, self.handle, &count, &images);
            if (count > max_images) return error.SwapchainImageCapacityExceeded;
            if (result == vulkan.VK_INCOMPLETE) continue;
            try dispatch.checkVkSuccess(result);
            if (count == 0) return error.NoSwapchainImages;
            self.image_count = count;
            settled = true;
            break;
        }
        if (!settled) return error.SwapchainImagesUnstable;
        const semaphore_info: vulkan.VkSemaphoreCreateInfo = .{ .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        try dispatch.checkVkSuccess(create_semaphore(backend.device, &semaphore_info, null, &self.acquire_semaphore));
        for (self.slots[0..self.image_count], images[0..self.image_count]) |*slot, image| {
            slot.image = image;
            try dispatch.checkVkSuccess(create_semaphore(backend.device, &semaphore_info, null, &slot.present_semaphore));
        }
        return self;
    }

    pub fn currentToken(self: *const Native) Error!Token {
        if (self.stale) return error.StaleSurfaceTexture;
        const index = self.current_index orelse return error.SurfaceNotAcquired;
        return .{ .generation = self.generation, .index = index, .acquire_epoch = self.acquire_epoch };
    }

    pub fn acquire(self: *Native, timeout_ns: u64, completed_serial: u64) Error!AcquireResult {
        if (self.device_lost) return .lost;
        if (self.stale) return .outdated;
        if (self.current_index != null) {
            const token = try self.currentToken();
            return if (self.current_acquire_suboptimal) .{ .suboptimal = token } else .{ .success = token };
        }
        if (self.acquire_epoch == std.math.maxInt(u64)) return error.AcquireEpochExhausted;
        if (completed_serial < self.acquire_consumed_serial) return error.AcquireSemaphoreInUse;
        const acquire_next = self.backend.procs.acquire_next_image_khr orelse return error.MissingDeviceProc;
        var index: u32 = 0;
        const result = acquire_next(self.backend.device, self.handle, timeout_ns, self.acquire_semaphore, null, &index);
        switch (result) {
            vulkan.VK_TIMEOUT, vulkan.VK_NOT_READY => return .timeout,
            vulkan.VK_ERROR_OUT_OF_DATE_KHR => { self.stale = true; return .outdated; },
            vulkan.VK_ERROR_SURFACE_LOST_KHR => { self.stale = true; return .lost; },
            vulkan.VK_ERROR_DEVICE_LOST => { self.stale = true; self.device_lost = true; self.drained = true; return .lost; },
            vulkan.VK_SUCCESS, vulkan.VK_SUBOPTIMAL_KHR => {},
            else => try dispatch.checkVkSuccess(result),
        }
        if (index >= self.image_count) { self.stale = true; return error.StaleSurfaceTexture; }
        self.acquire_epoch += 1;
        self.current_index = index;
        self.current_acquire_suboptimal = result == vulkan.VK_SUBOPTIMAL_KHR;
        self.slots[index].state = .{ .acquired = self.acquire_epoch };
        self.drained = false;
        if (result == vulkan.VK_SUBOPTIMAL_KHR) self.reconfigure_needed = true;
        const token = try self.currentToken();
        return if (result == vulkan.VK_SUBOPTIMAL_KHR) .{ .suboptimal = token } else .{ .success = token };
    }

    pub fn stageSubmit(self: *Native, token: Token) Error!Stage {
        if (self.stale or token.generation != self.generation or token.index >= self.image_count or
            self.current_index != token.index or token.acquire_epoch != self.acquire_epoch) return error.StaleSurfaceTexture;
        const slot = &self.slots[token.index];
        if (slot.staged) return error.SurfaceSubmissionStaged;
        const wait = switch (slot.state) {
            .acquired => |epoch| blk: { if (epoch != token.acquire_epoch) return error.StaleSurfaceTexture; break :blk self.acquire_semaphore; },
            .submit_accepted => |accepted| blk: { if (accepted.acquire_epoch != token.acquire_epoch) return error.StaleSurfaceTexture; break :blk slot.present_semaphore; },
            else => return error.StaleSurfaceTexture,
        };
        slot.staged = true;
        return .{ .token = token, .wait = wait, .signal = slot.present_semaphore };
    }

    pub fn rollbackSubmit(self: *Native, stage: Stage) void {
        std.debug.assert(self.slots[stage.token.index].staged);
        self.slots[stage.token.index].staged = false;
    }

    pub fn commitSubmit(self: *Native, stage: Stage, serial: u64) void {
        const slot = &self.slots[stage.token.index];
        std.debug.assert(slot.staged and serial != 0);
        if (slot.state == .acquired) self.acquire_consumed_serial = serial;
        slot.state = .{ .submit_accepted = .{ .acquire_epoch = stage.token.acquire_epoch, .serial = serial } };
        slot.staged = false;
        self.drained = false;
    }

    pub fn present(self: *Native, io: std.Io, serial_owner: SerialOwner) (Error || BridgeSubmitError)!PresentResult {
        const token = try self.currentToken();
        const slot = &self.slots[token.index];
        if (slot.staged) return error.SurfaceSubmissionStaged;
        const present_queue = self.backend.procs.queue_present_khr orelse return error.MissingDeviceProc;
        if (slot.state == .acquired) {
            const stage = try self.stageSubmit(token);
            errdefer self.rollbackSubmit(stage);
            const wait = stage.wait.?;
            const mask: vulkan.VkPipelineStageFlags = vulkan.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            const info: vulkan.VkSubmitInfo = .{
                .sType = vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .waitSemaphoreCount = 1, .pWaitSemaphores = &wait, .pWaitDstStageMask = &mask,
                .signalSemaphoreCount = 1, .pSignalSemaphores = &stage.signal,
            };
            const serial = try serial_owner.submit_fn(serial_owner.context, io, &info);
            self.commitSubmit(stage, serial);
        }
        const accepted = switch (slot.state) { .submit_accepted => |value| value, else => return error.StaleSurfaceTexture };
        slot.state = .{ .present_pending = accepted };
        const info: vulkan.VkPresentInfoKHR = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1, .pWaitSemaphores = &slot.present_semaphore,
            .swapchainCount = 1, .pSwapchains = &self.handle, .pImageIndices = &token.index,
        };
        const result = present_queue(self.backend.queue, &info);
        self.current_index = null;
        switch (result) {
            vulkan.VK_SUCCESS, vulkan.VK_SUBOPTIMAL_KHR => {
                slot.state = .{ .present_accepted = .{ .acquire_epoch = accepted.acquire_epoch, .serial = accepted.serial, .result = result } };
                if (result == vulkan.VK_SUBOPTIMAL_KHR) self.reconfigure_needed = true;
                return if (result == vulkan.VK_SUCCESS) .success else .suboptimal;
            },
            vulkan.VK_ERROR_OUT_OF_DATE_KHR => { self.stale = true; slot.state = .stale; return .outdated; },
            vulkan.VK_ERROR_SURFACE_LOST_KHR => { self.stale = true; slot.state = .stale; return .lost; },
            vulkan.VK_ERROR_DEVICE_LOST => { self.stale = true; self.device_lost = true; self.drained = true; slot.state = .stale; return error.DeviceLost; },
            else => { self.stale = true; slot.state = .stale; try dispatch.checkVkSuccess(result); unreachable; },
        }
    }

    /// Central owner first drains accepted submit serials under the same gate.
    /// This Vulkan call is synchronous, not cancellable, and holds no ObjectGuard.
    pub fn drain(self: *Native) (dispatch.Error || dispatch.LoadError)!void {
        const idle = self.backend.procs.queue_wait_idle orelse return error.MissingDeviceProc;
        const result = idle(self.backend.queue);
        if (result == vulkan.VK_ERROR_DEVICE_LOST) { self.stale = true; self.device_lost = true; self.drained = true; return error.DeviceLost; }
        try dispatch.checkVkSuccess(result);
        self.drained = true;
    }

    /// Never destroys VkImage. All borrowed texture views have retired first.
    pub fn deinit(self: *Native) void {
        std.debug.assert(self.drained);
        const p = self.backend.procs;
        for (self.slots[0..self.image_count]) |*slot| {
            if (slot.present_semaphore != null) p.destroy_semaphore.?(self.backend.device, slot.present_semaphore, null);
            slot.* = .{};
        }
        if (self.acquire_semaphore != null) p.destroy_semaphore.?(self.backend.device, self.acquire_semaphore, null);
        if (self.handle != null) p.destroy_swapchain_khr.?(self.backend.device, self.handle, null);
        self.acquire_semaphore = null;
        self.handle = null;
        self.image_count = 0;
    }
};

pub const Swapchain = struct {
    header: core.Object,
    native: Native,
    native_surface_header: ?*core.Object,
    release_context: *anyopaque,
    /// Drops the exact lease under the owning Instance guard. The callback
    /// follows DeviceGuard -> InstanceSurfaceGuard and must not wait on queues.
    release_native_surface_fn: *const fn (*anyopaque, *core.Object, *const core.ObjectGuard, std.Io) void,

    pub const Options = struct {
        backend: Backend,
        create_info: *const vulkan.VkSwapchainCreateInfoKHR,
        generation: u64,
        queue_family_index: u32,
        native_surface_header: *core.Object,
        native_accepted: *bool,
        release_context: *anyopaque,
        release_native_surface_fn: *const fn (*anyopaque, *core.Object, *const core.ObjectGuard, std.Io) void,
    };

    /// Caller supplies one already-held NativeSurface lease. Ownership transfers
    /// only after success. Core owns the sole Device .swapchain reference ledger.
    pub fn createLocked(allocator: std.mem.Allocator, io: std.Io, guard: *const core.ObjectGuard, device: *core.Device, options: Options) (Error || core.CreateError)!*Swapchain {
        const self = try device.create(allocator, guard, Swapchain, .{
            .kind = .swapchain, .state = .initializing, .label = "", .initial_reference = .lease,
        });
        errdefer self.header.discardUnpublishedLocked(guard) catch @panic("swapchain lease escaped during construction");
        self.native = try Native.create(options.backend, options.create_info, options.generation, options.queue_family_index, options.native_accepted);
        self.native_surface_header = options.native_surface_header;
        self.release_context = options.release_context;
        self.release_native_surface_fn = options.release_native_surface_fn;
        self.header.setInitializedNoError(guard);
        self.header.attach(guard, io);
        return self;
    }

    pub fn destroy(self: *Swapchain, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        self.native.deinit();
        const target = self.native_surface_header orelse @panic("swapchain native surface lease missing");
        self.release_native_surface_fn(self.release_context, target, guard, io);
        self.native_surface_header = null;
    }
};
