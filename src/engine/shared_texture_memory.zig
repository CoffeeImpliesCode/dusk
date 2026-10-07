//! One imported native image, canonical Device-arena aliases, and transactional access.
const std = @import("std");
const vk = @import("vulkan");
const api = @import("../api/api.zig");
const core = @import("../core/object.zig");
const core_device = @import("../core/device.zig");
const dispatch = @import("../vk/dispatch.zig");
const device_mod = @import("device.zig");
const texture_mod = @import("texture.zig");
const fence_mod = @import("shared_fence.zig");
const import_mod = @import("shared_texture_import.zig");
const sampler_mod = @import("sampler.zig");
const image_state = @import("native_image_state.zig");
const queue_mod = @import("queue.zig");
const native_resources = @import("native_resources.zig");

pub const Error = core.ReferenceError || core.CreateError || core_device.HandleError || std.mem.Allocator.Error ||
    device_mod.AdmissionError || sampler_mod.NativeCreateError || texture_mod.NativeCreateError ||
    queue_mod.Queue.SubmitError || native_resources.Error ||
    dispatch.Error || dispatch.LoadError || fence_mod.Error || error{
    DeviceMismatch, TextureProvenanceMismatch, SharedMemoryAccessAlreadyActive,
    SharedMemoryAccessNotBegun, ConcurrentReadUnsupported, InvalidFenceCount,
    InvalidFenceValue, UnsupportedImageLayout, UnsupportedTextureExtent,
    UnsupportedTextureUsage, EndAccessExportPending, DeviceLost, AcquireEpochExhausted,
    NativeBackendRequired, SubmissionCapacityExhausted, SerialExhausted,
};
pub const SharedMemoryError = Error;
pub const ImportTextureError = Error || import_mod.ImportError;
pub const max_fences = 8;
pub const Provenance = enum { opaque_fd, dma_buf, android_hardware_buffer };

/// Native imports transfer these actual resources only after allocation and binding succeed.
/// The optional platform retain is released after image and memory destruction.
pub const ImportedImage = struct {
    device: vk.VkDevice,
    procs: *const dispatch.DeviceProcs,
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    format: vk.VkFormat,
    properties: api.descriptors.SharedTextureMemoryProperties,
    mip_levels: u32,
    sample_count: u32 = 1,
    array_layers: u32,
    aspect_mask: vk.VkImageAspectFlags,
    external_queue_family: u32,
    initial_layout: vk.VkImageLayout,
    provenance: Provenance,
    ycbcr: ?api.descriptors.YCbCrVkDescriptor = null,
    platform_retain: ?*anyopaque = null,
    release_platform_retain: ?*const fn (*anyopaque) void = null,
};

/// These are the existing Texture and accepted Queue/PendingUses integration seams.
/// The submit callback must retain every root before VkQueueSubmit, rollback on rejection,
/// and return only the serial actually accepted by that same native queue.
pub const Bridge = struct {
    validate_import: *const fn (std.mem.Allocator, std.Io, *const core.ObjectGuard,
        *device_mod.Device, *SharedTextureMemory) Error!void,
    create_texture: *const fn (std.mem.Allocator, std.Io, *const core.ObjectGuard,
        *device_mod.Device, *SharedTextureMemory, ?*const api.descriptors.TextureDescriptorChain) Error!api.objects.Texture,
    submit_release: *const fn (std.Io, *const core.ObjectGuard, *device_mod.Device,
        *SharedTextureMemory, *core.Object, SubmitPlan) Error!u64,
    create_fence: *const fn (std.mem.Allocator, std.Io, *const core.ObjectGuard,
        *device_mod.Device, Provenance) Error!*fence_mod.SharedFence,
};

pub const Begun = struct {
    texture_header: *core.Object,
    acquire_epoch: u64,
    input_fences: [max_fences]?*fence_mod.SharedFence = @splat(null),
    fence_count: usize,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    initialized: bool,
    acquire_accepted_serial: ?u64 = null,
};
pub const EndAccepted = struct {
    texture_header: *core.Object,
    acquire_epoch: u64,
    fence: *fence_mod.SharedFence,
    serial: u64,
    old_layout: vk.VkImageLayout,
    end_layout: vk.VkImageLayout,
    initialized: bool,
};
pub const Access = union(enum) { idle, begun: Begun, end_accepted: EndAccepted };
pub const NativeImageBacking = struct {
    imported: ImportedImage,
    layout: vk.VkImageLayout,
    native_states: []image_state.NativeUsageState = &.{},
    initialized: []bool = &.{},
    acquire_epoch: u64 = 0,
    access: Access = .idle,
};
pub const SubmitPlan = struct {
    acquire_barrier: ?vk.VkImageMemoryBarrier = null,
    release_barrier: ?vk.VkImageMemoryBarrier = null,
    waits: [max_fences]vk.VkSemaphore = undefined,
    wait_stages: [max_fences]vk.VkPipelineStageFlags = @splat(vk.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT),
    wait_count: usize = 0,
    signal: vk.VkSemaphore = null,
    roots: [max_fences + 3]*core.Object = undefined,
    root_count: usize = 0,
};

/// Owner validation precedes this nonmutating epoch preflight.
pub fn validateAccess(access: *const Access, texture_header: *core.Object, epoch: u64) Error!void {
    const begun = switch (access.*) {
        .begun => |value| value,
        else => return error.SharedMemoryAccessNotBegun,
    };
    if (begun.texture_header != texture_header or begun.acquire_epoch != epoch)
        return error.TextureProvenanceMismatch;
}

pub fn supportedLayout(layout: i32, allow_undefined: bool) bool {
    return switch (layout) {
        vk.VK_IMAGE_LAYOUT_UNDEFINED => allow_undefined,
        vk.VK_IMAGE_LAYOUT_GENERAL, vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL => true,
        else => false,
    };
}
pub fn validateBeginDescriptor(descriptor: *const api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain) Error!void {
    if (descriptor.concurrent_read) return error.ConcurrentReadUnsupported;
    if (descriptor.fence_count > max_fences or descriptor.fence_count != descriptor.signaled_value_count)
        return error.InvalidFenceCount;
    const fences = descriptor.fences orelse &.{};
    const values = descriptor.signaled_values orelse &.{};
    if (fences.len != descriptor.fence_count or values.len != descriptor.signaled_value_count)
        return error.InvalidFenceCount;
    for (values) |value| if (value != 1) return error.InvalidFenceValue;
    for (fences, 0..) |fence, index| {
        for (fences[0..index]) |earlier| {
            if (earlier.handle == fence.handle) return error.InvalidFenceCount;
        }
    }
    if (descriptor.shared_texture_memory_d3d11_begin_state != null or
        descriptor.shared_texture_memory_d3d_swapchain_begin_state != null) return error.UnsupportedImageLayout;
    const layout = descriptor.shared_texture_memory_vk_image_layout_begin_state orelse return error.UnsupportedImageLayout;
    if (!supportedLayout(layout.old_layout, !descriptor.initialized) or !supportedLayout(layout.new_layout, false))
        return error.UnsupportedImageLayout;
}

pub fn validateTextureDescriptor(imported: *const ImportedImage,
    descriptor: *const api.descriptors.TextureDescriptorChain) Error!void {
    const properties = &imported.properties;
    if (descriptor.dimension != ._2d or
        descriptor.size.width != properties.size.width or
        descriptor.size.height != properties.size.height or
        descriptor.size.depth_or_array_layers != properties.size.depth_or_array_layers or
        descriptor.mip_level_count != imported.mip_levels or
        descriptor.sample_count != imported.sample_count)
        return error.UnsupportedTextureExtent;
    if (descriptor.format != properties.format) return error.TextureProvenanceMismatch;
    const requested = descriptor.usage.toFlags();
    if (requested == 0 or requested & ~properties.usage.toFlags() != 0)
        return error.UnsupportedTextureUsage;
    if (descriptor.dawn_texture_internal_usage_descriptor) |internal| {
        if (internal.internal_usage.toFlags() & ~properties.usage.toFlags() != 0)
            return error.UnsupportedTextureUsage;
    }
}

pub fn subresourceCount(imported: *const ImportedImage) Error!usize {
    const aspect_count: usize = @popCount(imported.aspect_mask);
    if (aspect_count == 0 or imported.mip_levels == 0 or imported.array_layers == 0)
        return error.UnsupportedTextureExtent;
    const layers_and_mips = std.math.mul(usize, imported.mip_levels, imported.array_layers)
        catch return error.UnsupportedTextureExtent;
    return std.math.mul(usize, layers_and_mips, aspect_count)
        catch return error.UnsupportedTextureExtent;
}

pub const SharedTextureMemory = struct {
    header: core.Object,
    device: *device_mod.Device,
    backing: NativeImageBacking,
    bridge: Bridge,
    conversion_sampler: ?*sampler_mod.Sampler = null,

    pub fn createImportedLocked(allocator: std.mem.Allocator, io: std.Io,
        guard: *const core.ObjectGuard, device: *device_mod.Device, imported: ImportedImage,
        bridge: Bridge, label: []const u8) Error!*SharedTextureMemory {
        guard.assertOwns(device.core.arena.objectList());
        if (imported.image == null or imported.memory == null or imported.mip_levels == 0 or imported.array_layers == 0)
            return error.TextureProvenanceMismatch;
        if (imported.procs.destroy_image == null or imported.procs.free_memory == null)
            return error.MissingDeviceProc;
        const count = try subresourceCount(&imported);
        const self = try device.core.create(allocator, guard, SharedTextureMemory, .{
            .kind = .shared_texture_memory, .state = .initializing,
            .label = label, .initial_reference = .user,
        });
        errdefer self.header.discardUnpublishedLocked(guard) catch unreachable;
        self.device = device;
        self.backing = .{ .imported = imported, .layout = imported.initial_layout };
        const arena = device.core.arena.allocator(guard);
        self.backing.native_states = try arena.alloc(image_state.NativeUsageState, count);
        errdefer arena.free(self.backing.native_states);
        @memset(self.backing.native_states, .{ .layout = imported.initial_layout });
        self.backing.initialized = try arena.alloc(bool, count);
        errdefer arena.free(self.backing.initialized);
        @memset(self.backing.initialized, false);
        self.bridge = bridge;
        self.conversion_sampler = null;
        errdefer if (self.conversion_sampler) |sampler|
            sampler.header.releaseLeaseLocked(guard, io) catch unreachable;
        try bridge.validate_import(allocator, io, guard, device, self);
        self.header.setInitializedNoError(guard);
        self.header.attach(guard, io);
        return self;
    }

    pub fn toApi(self: *SharedTextureMemory, guard: *const core.ObjectGuard) api.objects.SharedTextureMemory {
        const published = self.device.core.handleFor(guard, SharedTextureMemory, self, .shared_texture_memory);
        return .{ .handle = @ptrCast(published.ptr) };
    }
    pub fn fromHeader(header: *core.Object, guard: *const core.ObjectGuard, device: *device_mod.Device) Error!*SharedTextureMemory {
        guard.assertOwns(device.core.arena.objectList());
        if (header.tracking != device.core.arena.objectList()) return error.DeviceMismatch;
        if (header.kind != .shared_texture_memory or !header.node.linked or header.state != .alive or header.reference_count == 0)
            return error.ResourceDestroyed;
        const self: *SharedTextureMemory = @fieldParentPtr("header", header);
        if (self.device != device) return error.DeviceMismatch;
        return self;
    }
    fn resolveTextureLocked(self: *SharedTextureMemory, guard: *const core.ObjectGuard,
        texture: api.objects.Texture) Error!*texture_mod.Texture {
        const resolved = try self.device.core.resolve(guard, texture_mod.Texture,
            .{ .ptr = @ptrCast(@alignCast(texture.handle)), .kind = .texture });
        if (resolved.header.state != .alive) return error.ResourceDestroyed;
        if (resolved.sharedMemoryLocked(guard) != self) return error.TextureProvenanceMismatch;
        return resolved;
    }
    pub fn getProperties(self: *SharedTextureMemory, io: std.Io,
        out: *api.descriptors.SharedTextureMemoryProperties) Error!api.enums.Status {
        try self.device.acquireOperation(io);
        defer self.device.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.header.tracking);
        defer guard.unlock(io);
        _ = try fromHeader(&self.header, &guard, self.device);
        out.* = self.backing.imported.properties;
        return .success;
    }
    pub fn createTexture(self: *SharedTextureMemory, allocator: std.mem.Allocator, io: std.Io,
        descriptor: ?*const api.descriptors.TextureDescriptorChain) Error!api.objects.Texture {
        try self.device.acquireOperation(io);
        defer self.device.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.header.tracking);
        defer guard.unlock(io);
        _ = try fromHeader(&self.header, &guard, self.device);
        if (descriptor) |requested| try validateTextureDescriptor(&self.backing.imported, requested);
        return self.bridge.create_texture(allocator, io, &guard, self.device, self, descriptor);
    }
    pub fn beginAccess(self: *SharedTextureMemory, io: std.Io, texture: api.objects.Texture,
        descriptor: *const api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain) Error!api.enums.Status {
        try validateBeginDescriptor(descriptor);
        try self.device.acquireOperation(io);
        defer self.device.releaseOperation(io);
        const context = self.device.native orelse return error.NativeBackendRequired;
        try context.queue_operation_mutex.lock(io);
        defer context.queue_operation_mutex.unlock(io);
        var guard = try core.ObjectGuard.lock(io, self.header.tracking);
        defer guard.unlock(io);
        _ = try fromHeader(&self.header, &guard, self.device);
        const resolved = try self.resolveTextureLocked(&guard, texture);
        switch (self.backing.access) {
            .idle => {},
            .begun => return error.SharedMemoryAccessAlreadyActive,
            .end_accepted => return error.EndAccessExportPending,
        }
        const epoch = std.math.add(u64, self.backing.acquire_epoch, 1) catch return error.AcquireEpochExhausted;
        const layout = descriptor.shared_texture_memory_vk_image_layout_begin_state.?;
        if (self.backing.acquire_epoch != 0 and layout.old_layout != self.backing.layout)
            return error.UnsupportedImageLayout;
        var staged: Begun = .{ .texture_header = &resolved.header, .acquire_epoch = epoch,
            .fence_count = descriptor.fence_count, .old_layout = layout.old_layout,
            .new_layout = layout.new_layout, .initialized = descriptor.initialized };
        const fences = descriptor.fences orelse &.{};
        for (fences, 0..) |fence, index| {
            const canonical = try self.device.core.resolve(&guard, fence_mod.SharedFence,
                .{ .ptr = @ptrCast(@alignCast(fence.handle)), .kind = .shared_fence });
            staged.input_fences[index] = try fence_mod.SharedFence.fromHeader(&canonical.header, &guard, self.device);
            _ = try staged.input_fences[index].?.waitSemaphoreLocked(&guard, self.device, 1);
        }
        var retained: usize = 0;
        errdefer for (staged.input_fences[0..retained]) |fence|
            fence.?.header.releaseLeaseLocked(&guard, io) catch unreachable;
        for (staged.input_fences[0..staged.fence_count]) |fence| {
            try fence.?.header.retainLeaseLocked(&guard);
            retained += 1;
        }
        try resolved.header.retainLeaseLocked(&guard);
        self.backing.acquire_epoch = epoch;
        self.backing.access = .{ .begun = staged };
        resolved.setSharedAcquireEpochLocked(&guard, epoch);
        @memset(self.backing.initialized, descriptor.initialized);
        return .success;
    }

    /// Recording validates the canonical header, not merely its shared VkImage.
    pub fn validateRecordingLocked(self: *SharedTextureMemory, guard: *const core.ObjectGuard,
        texture_header: *core.Object, epoch: u64) Error!void {
        _ = try fromHeader(&self.header, guard, self.device);
        try validateAccess(&self.backing.access, texture_header, epoch);
    }
    fn barrier(self: *SharedTextureMemory, old: vk.VkImageLayout, new: vk.VkImageLayout,
        acquire: bool) vk.VkImageMemoryBarrier {
        const imported = &self.backing.imported;
        const family = self.device.native.?.native_device.queue_family_index;
        return .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = if (acquire) 0 else vk.VK_ACCESS_MEMORY_READ_BIT | vk.VK_ACCESS_MEMORY_WRITE_BIT,
            .dstAccessMask = if (acquire) vk.VK_ACCESS_MEMORY_READ_BIT | vk.VK_ACCESS_MEMORY_WRITE_BIT else 0,
            .oldLayout = old, .newLayout = new,
            .srcQueueFamilyIndex = if (acquire) imported.external_queue_family else family,
            .dstQueueFamilyIndex = if (acquire) family else imported.external_queue_family,
            .image = imported.image,
            .subresourceRange = .{ .aspectMask = imported.aspect_mask, .baseMipLevel = 0,
                .levelCount = imported.mip_levels, .baseArrayLayer = 0, .layerCount = imported.array_layers } };
    }
    pub fn stageSubmitLocked(self: *SharedTextureMemory, guard: *const core.ObjectGuard,
        texture_header: *core.Object, epoch: u64) Error!SubmitPlan {
        try self.validateRecordingLocked(guard, texture_header, epoch);
        const begun = &self.backing.access.begun;
        var plan: SubmitPlan = .{};
        plan.roots[0] = &self.header;
        plan.roots[1] = texture_header;
        plan.root_count = 2;
        if (begun.acquire_accepted_serial == null) {
            plan.acquire_barrier = self.barrier(begun.old_layout, begun.new_layout, true);
            for (begun.input_fences[0..begun.fence_count], 0..) |fence, index| {
                plan.waits[index] = try fence.?.waitSemaphoreLocked(guard, self.device, 1);
                plan.roots[plan.root_count] = &fence.?.header;
                plan.root_count += 1;
            }
            plan.wait_count = begun.fence_count;
        }
        return plan;
    }
    /// Called only after native submit success and PendingUses root adoption.
    pub fn commitAcceptedLocked(self: *SharedTextureMemory, guard: *const core.ObjectGuard,
        io: std.Io, texture_header: *core.Object, epoch: u64, serial: u64) void {
        self.validateRecordingLocked(guard, texture_header, epoch) catch unreachable;
        const begun = &self.backing.access.begun;
        if (begun.acquire_accepted_serial != null) return;
        for (begun.input_fences[0..begun.fence_count]) |fence| {
            fence.?.acceptWaitLocked(guard);
            fence.?.header.releaseLeaseLocked(guard, io) catch unreachable;
        }
        begun.input_fences = @splat(null);
        begun.fence_count = 0;
        begun.acquire_accepted_serial = serial;
        self.backing.layout = begun.new_layout;
    }

    pub fn endAccess(self: *SharedTextureMemory, allocator: std.mem.Allocator, io: std.Io,
        texture: api.objects.Texture, out: *api.descriptors.SharedTextureMemoryEndAccessState) Error!api.enums.Status {
        const layout = out.shared_texture_memory_vk_image_layout_end_state orelse return error.UnsupportedImageLayout;
        if (!supportedLayout(layout.new_layout, false)) return error.UnsupportedImageLayout;
        try self.device.acquireOperation(io);
        defer self.device.releaseOperation(io);
        const context = self.device.native orelse return error.NativeBackendRequired;
        try context.queue_operation_mutex.lock(io);
        defer context.queue_operation_mutex.unlock(io);
        var guard = try core.ObjectGuard.lock(io, self.header.tracking);
        defer guard.unlock(io);
        _ = try fromHeader(&self.header, &guard, self.device);
        const resolved = try self.resolveTextureLocked(&guard, texture);
        switch (self.backing.access) {
            .idle => return error.SharedMemoryAccessNotBegun,
            .begun => |begun| if (begun.texture_header != &resolved.header) return error.TextureProvenanceMismatch,
            .end_accepted => |accepted| {
                if (accepted.texture_header != &resolved.header or accepted.end_layout != layout.new_layout)
                    return error.TextureProvenanceMismatch;
            },
        }
        const fences = try allocator.alloc(api.objects.SharedFence, 1);
        errdefer allocator.free(fences);
        const values = try allocator.alloc(u64, 1);
        errdefer allocator.free(values);
        if (self.backing.access == .begun) {
            const begun = self.backing.access.begun;
            const fence = try self.bridge.create_fence(allocator, io, &guard, self.device, self.backing.imported.provenance);
            var submitted = false;
            errdefer if (!submitted) fence.header.releaseUserLocked(&guard, io) catch unreachable;
            var plan = try self.stageSubmitLocked(&guard, &resolved.header, begun.acquire_epoch);
            const old_layout = if (plan.acquire_barrier != null) begun.new_layout else self.backing.layout;
            plan.release_barrier = self.barrier(old_layout, layout.new_layout, false);
            plan.signal = try fence.signalSemaphoreLocked(&guard, self.device);
            plan.roots[plan.root_count] = &fence.header;
            plan.root_count += 1;
            const serial = try self.bridge.submit_release(io, &guard, self.device, self, &resolved.header, plan);
            submitted = true;
            self.commitAcceptedLocked(&guard, io, &resolved.header, begun.acquire_epoch, serial);
            fence.acceptSignalLocked(&guard, serial);
            var initialized = true;
            for (self.backing.initialized) |bit| initialized = initialized and bit;
            self.backing.layout = layout.new_layout;
            @memset(self.backing.native_states, .{
                .layout = layout.new_layout, .stages = vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            });
            self.backing.access = .{ .end_accepted = .{ .texture_header = &resolved.header,
                .acquire_epoch = begun.acquire_epoch, .fence = fence, .serial = serial,
                .old_layout = old_layout, .end_layout = layout.new_layout, .initialized = initialized } };
        }
        const accepted = self.backing.access.end_accepted;
        try accepted.fence.ensureExportedLocked(io, &guard);
        fences[0] = accepted.fence.toApi(&guard);
        values[0] = 1;
        out.* = .{ .initialized = accepted.initialized, .fence_count = 1,
            .fences = fences, .signaled_value_count = 1, .signaled_values = values,
            .shared_texture_memory_vk_image_layout_end_state = .{
                .old_layout = accepted.old_layout, .new_layout = accepted.end_layout } };
        self.backing.access = .idle;
        resolved.header.releaseLeaseLocked(&guard, io) catch unreachable;
        return .success;
    }

    pub fn destroy(self: *SharedTextureMemory, guard: *const core.ObjectGuard, io: std.Io,
        reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        switch (self.backing.access) {
            .idle => {},
            .begun => |begun| {
                for (begun.input_fences[0..begun.fence_count]) |fence|
                    fence.?.header.releaseLeaseLocked(guard, io) catch unreachable;
                begun.texture_header.releaseLeaseLocked(guard, io) catch unreachable;
            },
            .end_accepted => |accepted| {
                accepted.fence.header.releaseUserLocked(guard, io) catch unreachable;
                accepted.texture_header.releaseLeaseLocked(guard, io) catch unreachable;
            },
        }
        const imported = &self.backing.imported;
        imported.procs.destroy_image.?(imported.device, imported.image, null);
        imported.procs.free_memory.?(imported.device, imported.memory, null);
        if (imported.platform_retain) |retained| imported.release_platform_retain.?(retained);
        if (self.conversion_sampler) |sampler|
            sampler.header.releaseLeaseLocked(guard, io) catch unreachable;
        self.conversion_sampler = null;
        const arena = self.device.core.arena.allocator(guard);
        arena.free(self.backing.native_states);
        arena.free(self.backing.initialized);
        self.backing.native_states = &.{};
        self.backing.initialized = &.{};
        self.backing.access = .idle;
    }
};

/// The caller retains its native descriptor. Imported resources transfer to the
/// real Device arena only when the header has been attached successfully.
pub fn importSharedTextureMemory(allocator: std.mem.Allocator, io: std.Io,
    device: *device_mod.Device,
    descriptor: *const api.descriptors.SharedTextureMemoryDescriptorChain) ImportTextureError!api.objects.SharedTextureMemory {
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var imported = try import_mod.importImage(allocator, io, device, descriptor);
    var transferred = false;
    errdefer if (!transferred) import_mod.destroyImported(&imported);
    var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try device.bindObjectsLocked(&guard, allocator);
    const self = try SharedTextureMemory.createImportedLocked(allocator, io, &guard,
        device, imported, device.sharedMemoryBridge(), descriptor.label orelse "");
    transferred = true;
    return self.toApi(&guard);
}
