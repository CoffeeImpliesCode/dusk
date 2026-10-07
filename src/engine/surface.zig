//! Surface ownership follows Dawn Surface.cpp and vulkan/SwapChainVk.cpp at
//! 32f77c02294310054a660c393feded4bcb3f203c. NativeSurface is Instance-owned;
//! Swapchain is Device-owned. Host display and window objects remain borrowed.
const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const platform = @import("../platform/surface.zig");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const Instance = @import("instance.zig").Instance;
const device_mod = @import("device.zig");
const Device = device_mod.Device;
const native_device = @import("native_device_context.zig");
const vulkan_device = @import("vulkan_device.zig");
const swapchain = @import("swapchain.zig");
const capabilities = @import("surface_capabilities.zig");

pub fn sourceFromDescriptor(descriptor: *const api.descriptors.SurfaceDescriptorChain) platform.SurfaceError!platform.Source {
    if (descriptor.surface_color_management != null) return error.SurfaceColorManagementUnsupported;
    var arm_count: usize = 0;
    inline for (@typeInfo(api.descriptors.SurfaceDescriptorChain).@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "label") and !std.mem.eql(u8, field.name, "surface_color_management")) {
            if (@field(descriptor, field.name) != null) arm_count += 1;
        }
    }
    if (arm_count == 0) return error.DescriptorChainEmpty;
    if (arm_count != 1) return error.UnsupportedSurfaceSource;
    const source: platform.Source = if (descriptor.surface_source_xlib_window) |value|
        .{ .xlib_window = .{ .display = value.display, .window = value.window } }
    else if (descriptor.surface_source_wayland_surface) |value|
        .{ .wayland_surface = .{ .display = value.display, .surface = value.surface } }
    else if (descriptor.surface_source_android_native_window) |value|
        .{ .android_native_window = value.window }
    else
        return error.UnsupportedSurfaceSource;
    try platform.validateSurfaceDescriptor(.{ .source = source });
    return source;
}

pub const ReferenceClass = core.ReferenceClass;
pub const SurfaceReleaseError = core.ReferenceError || dispatch.Error || dispatch.LoadError ||
    error{ Canceled, SurfaceDeviceLost, SurfaceInUse };
pub const SurfaceCreateError = core.CreateError || core.ReferenceError ||
    platform.SurfaceError || dispatch.Error || dispatch.LoadError ||
    @import("async_root_requests.zig").RootWorkError ||
    error{ ExtensionUnavailable, MissingRequiredProc, WaylandSurfaceBindingsUnavailable };

pub const NativeSurface = struct {
    header: core.Object,
    instance: *Instance,
    cached_instance: *vulkan_device.VulkanInstance,
    vk_surface: vulkan.VkSurfaceKHR,

    pub fn destroy(self: *NativeSurface, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        _ = io;
        _ = reason;
        guard.assertOwns(self.header.tracking);
        const destroy_surface = self.cached_instance.procs.destroy_surface_khr orelse
            @panic("created native surface lacks destroy proc");
        destroy_surface(self.cached_instance.vk_instance, self.vk_surface, null);
    }
};

pub const Surface = struct {
    header: core.Object,
    instance: *Instance,
    source: platform.Surface,
    native_surfaces: [vulkan_device.icd_count]?*core.Object = @splat(null),
    current_swapchain: ?*swapchain.Swapchain = null,
    state: State = .unconfigured,
    generation: u64 = 0,

    pub const State = enum { unconfigured, configured, configuring, unconfiguring, lost };

    pub fn destroy(self: *Surface, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        _ = reason;
        guard.assertOwns(self.header.tracking);
        // Final release detached the Device edge before entering this callback.
        std.debug.assert(self.current_swapchain == null);
        for (&self.native_surfaces) |*entry| {
            if (entry.*) |header| {
                header.releaseLeaseLocked(guard, io);
                entry.* = null;
            }
        }
    }
};

pub fn resolve(instance: *Instance, guard: *const core.ObjectGuard, handle: api.Surface) core.HandleError!*Surface {
    const objects = instance.surfaceObjectList() orelse return error.StaleHandle;
    guard.assertOwns(objects);
    const raw = handle.handle orelse return error.StaleHandle;
    if (@intFromPtr(raw) % @alignOf(core.Object) != 0) return error.StaleHandle;
    const candidate: *core.Object = @ptrCast(@alignCast(raw));
    const header = try objects.resolveHeaderLocked(guard, .{
        .ptr = @as(core.ObjectPtr, candidate),
        .kind = .surface,
    }, .{ .instance = instance });
    if (header.state != .alive) return error.StaleHandle;
    const surface: *Surface = @fieldParentPtr("header", header);
    if (surface.instance != instance) return error.StaleHandle;
    return surface;
}

fn nativeSurfaceLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    surface: *Surface,
    guard: *const core.ObjectGuard,
    cached: *vulkan_device.VulkanInstance,
) SurfaceCreateError!*NativeSurface {
    guard.assertOwns(surface.header.tracking);
    const index = @intFromEnum(cached.icd);
    if (surface.native_surfaces[index]) |header| {
        const native: *NativeSurface = @fieldParentPtr("header", header);
        std.debug.assert(native.cached_instance == cached);
        return native;
    }
    const arena = surface.instance.surface_object_arena.?;
    const native = try arena.create(allocator, guard, NativeSurface, .{
        .kind = .native_surface,
        .state = .initializing,
        .initial_reference = .lease,
    });
    errdefer native.header.discardUnpublishedLocked(guard) catch
        @panic("native surface reference escaped before publication");
    var vk_surface: vulkan.VkSurfaceKHR = null;
    try platform.createVulkanSurface(&surface.source, .{
        .instance = cached.vk_instance,
        .capabilities = &cached.capabilities,
        .platform_procs = &cached.platform_procs,
    }, &vk_surface);
    native.instance = surface.instance;
    native.cached_instance = cached;
    native.vk_surface = vk_surface;
    native.header.setInitializedNoError(guard);
    native.header.attach(guard, io);
    surface.native_surfaces[index] = &native.header;
    return native;
}

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: *Instance,
    descriptor: *const api.descriptors.SurfaceDescriptorChain,
) SurfaceCreateError!api.Surface {
    const source = try sourceFromDescriptor(descriptor);
    try instance.acquireRootOperation(io);
    defer instance.releaseRootOperation(io);
    try instance.root_work_mutex.lock(io);
    defer instance.root_work_mutex.unlock(io);
    const arena = try instance.surfaceArena(allocator, io);
    var guard = try core.ObjectGuard.lock(io, arena.objectList());
    defer guard.unlock(io);
    const surface = try arena.create(allocator, &guard, Surface, .{
        .kind = .surface,
        .state = .initializing,
        .initial_reference = .user,
        .label = descriptor.label orelse "",
    });
    surface.instance = instance;
    surface.source = .{ .source = source };
    surface.native_surfaces = @splat(null);
    surface.current_swapchain = null;
    surface.state = .unconfigured;
    surface.generation = 0;
    errdefer {
        for (surface.native_surfaces) |entry| {
            if (entry) |header| header.releaseLeaseLocked(&guard, io);
        }
        surface.header.discardUnpublishedLocked(&guard) catch
            @panic("surface reference escaped before publication");
    }
    if (instance.native_context) |context| {
        for (context.backend.instances) |entry| {
            if (entry) |cached| {
                const native = try nativeSurfaceLocked(allocator, io, surface, &guard, cached);
                std.debug.assert(native.cached_instance == cached);
            }
        }
    }
    surface.header.setInitializedNoError(&guard);
    surface.header.attach(&guard, io);
    surface.header.reference_escaped = true;
    return .{ .handle = @ptrCast(&surface.header) };
}

pub const NativeReqCompatibleSurface = struct {
    instance: *Instance,
    header: *core.Object,
    held: bool,
};

pub fn acquireCompatibleSurface(io: std.Io, instance: *Instance, handle: api.Surface) (core.HandleError || core.ReferenceError || error{Canceled})!NativeReqCompatibleSurface {
    const objects = instance.surfaceObjectList() orelse return error.StaleHandle;
    var guard = try core.ObjectGuard.lock(io, objects);
    defer guard.unlock(io);
    const surface = try resolve(instance, &guard, handle);
    try surface.header.retainLeaseLocked(&guard);
    return .{ .instance = instance, .header = &surface.header, .held = true };
}

pub fn releaseCompatibleSurface(io: std.Io, request: *NativeReqCompatibleSurface) SurfaceReleaseError!void {
    if (!request.held) return;
    try releaseSurfaceReference(io, request.instance, request.header, .lease);
    request.held = false;
}

pub fn surfaceForIcd(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *const NativeReqCompatibleSurface,
    guard: *const core.ObjectGuard,
    cached: *vulkan_device.VulkanInstance,
) (SurfaceCreateError || core.HandleError)!*NativeSurface {
    if (!request.held) return error.StaleHandle;
    const surface = try resolve(request.instance, guard, .{ .handle = @ptrCast(request.header) });
    return nativeSurfaceLocked(allocator, io, surface, guard, cached);
}

pub fn getCapabilities(
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: *Instance,
    handle: api.Surface,
    adapter: *@import("adapter.zig").Adapter,
    out: *api.SurfaceCapabilities,
) (SurfaceCreateError || core.HandleError || capabilities.QueryError || error{SurfaceAdapterInstanceMismatch})!api.Status {
    if (adapter.instance != instance) return error.SurfaceAdapterInstanceMismatch;
    const native_adapter = adapter.physical_device.native_adapter orelse return error.SurfaceAdapterInstanceMismatch;
    try instance.acquireRootOperation(io);
    defer instance.releaseRootOperation(io);
    try instance.root_work_mutex.lock(io);
    defer instance.root_work_mutex.unlock(io);
    const arena = try instance.surfaceArena(allocator, io);
    var guard = try core.ObjectGuard.lock(io, arena.objectList());
    const surface = resolve(instance, &guard, handle) catch |err| {
        guard.unlock(io);
        return err;
    };
    const native = nativeSurfaceLocked(allocator, io, surface, &guard, native_adapter.instance) catch |err| {
        guard.unlock(io);
        return err;
    };
    native.header.retainLeaseLocked(&guard) catch |err| {
        guard.unlock(io);
        return err;
    };
    guard.unlock(io);
    defer {
        var release_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
        native.header.releaseLeaseLocked(&release_guard, io);
        release_guard.unlock(io);
    }
    return capabilities.publish(allocator, .{
        .physical_device = native_adapter.physical.handle,
        .surface = native.vk_surface,
        .instance_procs = native.cached_instance.procs,
    }, out);
}

pub fn release(io: std.Io, instance: *Instance, handle: api.Surface) (SurfaceReleaseError || core.HandleError)!void {
    const objects = instance.surfaceObjectList() orelse return error.StaleHandle;
    var guard = try core.ObjectGuard.lock(io, objects);
    const surface = resolve(instance, &guard, handle) catch |err| {
        guard.unlock(io);
        return err;
    };
    const header = &surface.header;
    guard.unlock(io);
    try releaseSurfaceReference(io, instance, header, .user);
}

pub fn releaseSurfaceReference(
    io: std.Io,
    instance: *Instance,
    header: *core.Object,
    class: core.ReferenceClass,
) SurfaceReleaseError!void {
    const objects = instance.surfaceObjectList() orelse return error.ResourceDestroyed;
    var guard = try core.ObjectGuard.lock(io, objects);
    if (header.tracking != objects or header.kind != .surface) {
        guard.unlock(io);
        return error.ResourceDestroyed;
    }
    if (header.reference_count > 1) {
        defer guard.unlock(io);
        switch (class) {
            .user => try header.releaseUserLocked(&guard, io),
            .lease => header.releaseLeaseLocked(&guard, io),
        }
        return;
    }
    const surface: *Surface = @fieldParentPtr("header", header);
    if (surface.state == .configuring or surface.state == .unconfiguring) {
        guard.unlock(io);
        return error.SurfaceInUse;
    }
    if (header.state != .alive) {
        guard.unlock(io);
        return error.ResourceDestroyed;
    }
    if (class == .user and header.user_reference_count == 0) {
        guard.unlock(io);
        return error.NoOwnedReference;
    }
    if (class == .lease and header.reference_count == header.user_reference_count) {
        guard.unlock(io);
        return error.NoOwnedReference;
    }
    header.state = .retiring;
    const chain = surface.current_swapchain;
    guard.unlock(io);
    if (chain) |current| {
        detachSwapchain(io, surface, current) catch |err| {
            guard = core.ObjectGuard.lockUncancelable(io, objects);
            header.state = .alive;
            guard.unlock(io);
            return err;
        };
    }
    guard = core.ObjectGuard.lockUncancelable(io, objects);
    defer guard.unlock(io);
    std.debug.assert(surface.current_swapchain == null);
    header.state = .alive;
    switch (class) {
        .user => try header.releaseUserLocked(&guard, io),
        .lease => header.releaseLeaseLocked(&guard, io),
    }
}

pub const SurfaceOperationError = SurfaceCreateError || core.HandleError ||
    device_mod.OperationError || native_device.CleanupError || capabilities.QueryError ||
    swapchain.Error || swapchain.BridgeSubmitError || SurfaceReleaseError || error{
        InvalidOwner, DeviceSurfaceInstanceMismatch, SurfaceQueueFamilyUnsupported,
        SurfaceAlreadyAcquired, SurfaceTransitionInProgress, SurfaceNotConfigured,
        SurfaceNotAcquired, SurfaceStale, SurfaceGenerationExhausted,
    };

fn deviceForChain(chain: *swapchain.Swapchain) error{InvalidOwner}!*Device {
    return @import("native_async_handles.zig").resourceOwner(&chain.header);
}

fn detachSwapchain(io: std.Io, surface: *Surface, chain: *swapchain.Swapchain) SurfaceReleaseError!void {
    const device = deviceForChain(chain) catch return error.SurfaceInUse;
    device.acquireHostOperation(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.SurfaceInUse,
    };
    defer device.releaseOperation(io);
    const context = device.native orelse return error.SurfaceInUse;
    try context.queue_operation_mutex.lock(io);
    defer context.queue_operation_mutex.unlock(io);
    if (!chain.native.device_lost) {
        context.drainSurfaceLocked(io) catch |err| {
            if (err == error.DeviceLost) {
                markSurfaceLost(io, surface, chain, true);
                return error.SurfaceDeviceLost;
            }
            return mapDrainError(err);
        };
        chain.native.drain() catch |err| {
            if (err == error.DeviceLost) {
                markSurfaceLost(io, surface, chain, true);
                return error.SurfaceDeviceLost;
            }
            return err;
        };
    }
    var device_guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer device_guard.unlock(io);
    var surface_guard = core.ObjectGuard.lockUncancelable(io, surface.header.tracking);
    std.debug.assert(surface.current_swapchain == chain);
    chain.native.stale = true;
    surface.current_swapchain = null;
    if (surface.state != .lost) surface.state = .unconfigured;
    surface_guard.unlock(io);
    chain.header.releaseLeaseLocked(&device_guard, io);
}

pub fn configure(
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: *Instance,
    handle: api.Surface,
    configuration: *const api.descriptors.SurfaceConfigurationChain,
) SurfaceOperationError!void {
    const device = try @import("native_async_handles.zig").resolveDevice(configuration.device);
    if (device.adapter.instance != instance) return error.DeviceSurfaceInstanceMismatch;
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    const context = device.native orelse return error.SwapchainUnavailable;
    try context.queue_operation_mutex.lock(io);
    defer context.queue_operation_mutex.unlock(io);
    const native_device_owner = &context.native_device;
    if (!native_device_owner.capabilities.swapchain) return error.SwapchainUnavailable;
    const arena = try instance.surfaceArena(allocator, io);
    var device_guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    var surface_guard = core.ObjectGuard.lock(io, arena.objectList()) catch |err| {
        device_guard.unlock(io);
        return err;
    };
    const surface = resolve(instance, &surface_guard, handle) catch |err| {
        surface_guard.unlock(io);
        device_guard.unlock(io);
        return err;
    };
    if (surface.state == .configuring or surface.state == .unconfiguring or surface.header.state == .retiring) {
        surface_guard.unlock(io);
        device_guard.unlock(io);
        return error.SurfaceTransitionInProgress;
    }
    if (surface.state == .lost) {
        surface_guard.unlock(io);
        device_guard.unlock(io);
        return error.SurfaceLost;
    }
    const old = surface.current_swapchain;
    if (old) |previous| {
        if (previous.native.current_index != null and !previous.native.stale) {
            surface_guard.unlock(io);
            device_guard.unlock(io);
            return error.SurfaceAlreadyAcquired;
        }
    }
    if (surface.generation == std.math.maxInt(u64)) {
        surface_guard.unlock(io);
        device_guard.unlock(io);
        return error.SurfaceGenerationExhausted;
    }
    const native_surface = nativeSurfaceLocked(allocator, io, surface, &surface_guard, native_device_owner.instance) catch |err| {
        surface_guard.unlock(io);
        device_guard.unlock(io);
        return err;
    };
    native_surface.header.retainLeaseLocked(&surface_guard) catch |err| {
        surface_guard.unlock(io);
        device_guard.unlock(io);
        return err;
    };
    const previous_state = surface.state;
    surface.state = .configuring;
    surface_guard.unlock(io);
    device_guard.unlock(io);
    var transferred = false;
    defer if (!transferred) {
        var release_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
        native_surface.header.releaseLeaseLocked(&release_guard, io);
        release_guard.unlock(io);
    };
    var committed = false;
    defer if (!committed) {
        var restore_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
        if (surface.state == .configuring) surface.state = previous_state;
        restore_guard.unlock(io);
    };
    const support_proc = native_surface.cached_instance.procs.get_physical_device_surface_support_khr orelse return error.MissingInstanceProc;
    var support: vulkan.VkBool32 = vulkan.VK_FALSE;
    try dispatch.checkVkSuccess(support_proc(native_device_owner.physical.handle, native_device_owner.queue_family_index, native_surface.vk_surface, &support));
    if (support != vulkan.VK_TRUE) return error.SurfaceQueueFamilyUnsupported;
    var validated = try capabilities.validateConfiguration(allocator, .{
        .physical_device = native_device_owner.physical.handle,
        .surface = native_surface.vk_surface,
        .instance_procs = native_surface.cached_instance.procs,
    }, configuration);
    validated.create_info.oldSwapchain = if (old) |previous| previous.native.handle else null;
    device_guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    const replacement = device.core.create(allocator, &device_guard, swapchain.Swapchain, .{
        .kind = .swapchain,
        .state = .initializing,
        .initial_reference = .lease,
    }) catch |err| {
        device_guard.unlock(io);
        return err;
    };
    device_guard.unlock(io);
    var published = false;
    defer if (!published) {
        var discard_guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        replacement.header.discardUnpublishedLocked(&discard_guard) catch
            @panic("replacement swapchain escaped before publication");
        discard_guard.unlock(io);
    };
    context.drainSurfaceLocked(io) catch |err| {
        if (err == error.DeviceLost) {
            context.markTerminalLossLocked(io);
            if (old) |previous| {
                markSurfaceLost(io, surface, previous, true);
            } else {
                var loss_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
                surface.state = .lost;
                loss_guard.unlock(io);
            }
        }
        return err;
    };
    if (old) |previous| previous.native.drain() catch |err| {
        if (err == error.DeviceLost) {
            context.markTerminalLossLocked(io);
            markSurfaceLost(io, surface, previous, true);
        }
        return err;
    };
    var native_accepted = false;
    const replacement_native = swapchain.Native.create(.{
        .device = native_device_owner.vk_device,
        .queue = context.queue.context.vk_queue,
        .procs = native_device_owner.procs,
        .swapchain_available = native_device_owner.capabilities.swapchain,
    }, &validated.create_info, surface.generation + 1, native_device_owner.queue_family_index, &native_accepted) catch |err| {
        if (err == error.DeviceLost or err == error.SurfaceLost) {
            if (old) |previous| {
                markSurfaceLost(io, surface, previous, err == error.DeviceLost);
            } else {
                var loss_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
                surface.state = .lost;
                loss_guard.unlock(io);
            }
            if (err == error.DeviceLost) context.markTerminalLossLocked(io);
        }
        if (native_accepted) {
            device_guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            surface_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
            if (old) |previous| previous.native.stale = true;
            surface.current_swapchain = null;
            surface.state = if (err == error.DeviceLost or err == error.SurfaceLost) .lost else .unconfigured;
            surface_guard.unlock(io);
            if (old) |previous| previous.header.releaseLeaseLocked(&device_guard, io);
            device_guard.unlock(io);
            committed = true;
        }
        return err;
    };
    device_guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    surface_guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
    replacement.native = replacement_native;
    replacement.native_surface_header = &native_surface.header;
    replacement.release_context = instance;
    replacement.release_native_surface_fn = releaseNativeSurfaceLease;
    replacement.header.setInitializedNoError(&device_guard);
    replacement.header.attach(&device_guard, io);
    if (old) |previous| previous.native.stale = true;
    surface.current_swapchain = replacement;
    surface.generation += 1;
    surface.state = .configured;
    surface_guard.unlock(io);
    if (old) |previous| previous.header.releaseLeaseLocked(&device_guard, io);
    device_guard.unlock(io);
    transferred = true;
    committed = true;
    published = true;
}

const ConfiguredOperation = struct {
    device: *Device,
    context: *native_device.NativeDeviceContext,
    surface: *Surface,
    chain: *swapchain.Swapchain,

    fn close(self: ConfiguredOperation, io: std.Io) void {
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        self.chain.header.releaseLeaseLocked(&guard, io);
        guard.unlock(io);
        self.context.queue_operation_mutex.unlock(io);
        self.device.releaseOperation(io);
    }
};

fn configuredOperation(io: std.Io, instance: *Instance, handle: api.Surface) SurfaceOperationError!ConfiguredOperation {
    const objects = instance.surfaceObjectList() orelse return error.SurfaceNotConfigured;
    var initial_guard = try core.ObjectGuard.lock(io, objects);
    const initial_surface = resolve(instance, &initial_guard, handle) catch |err| {
        initial_guard.unlock(io);
        return err;
    };
    const chain = initial_surface.current_swapchain orelse {
        initial_guard.unlock(io);
        return error.SurfaceNotConfigured;
    };
    initial_guard.unlock(io);
    const device = try deviceForChain(chain);
    try device.acquireOperation(io);
    errdefer device.releaseOperation(io);
    const context = device.native orelse return error.SurfaceNotConfigured;
    try context.queue_operation_mutex.lock(io);
    errdefer context.queue_operation_mutex.unlock(io);
    var device_guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer device_guard.unlock(io);
    var surface_guard = try core.ObjectGuard.lock(io, objects);
    defer surface_guard.unlock(io);
    const surface = try resolve(instance, &surface_guard, handle);
    if (surface.state == .configuring or surface.state == .unconfiguring) return error.SurfaceTransitionInProgress;
    if (surface.current_swapchain != chain) return error.SurfaceNotConfigured;
    if (!chain.header.isAlive(&device_guard)) return error.ResourceDestroyed;
    try chain.header.retainLeaseLocked(&device_guard);
    return .{ .device = device, .context = context, .surface = surface, .chain = chain };
}

pub fn getCurrentTexture(
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: *Instance,
    handle: api.Surface,
    out: *api.SurfaceTexture,
) SurfaceOperationError!void {
    const operation = try configuredOperation(io, instance, handle);
    defer operation.close(io);
    const native = &operation.chain.native;
    // The queue gate excludes configuration and submit; no ObjectGuard spans a wait.
    if (native.acquire_consumed_serial > operation.context.completedSerial(io)) {
        try operation.context.waitSurfaceSerialLocked(io, native.acquire_consumed_serial);
    }
    const acquired = try native.acquire(1_000_000_000, operation.context.completedSerial(io));
    const status: api.SurfaceGetCurrentTextureStatus = switch (acquired) {
        .success => .success_optimal,
        .suboptimal => .success_suboptimal,
        .timeout => .timeout,
        .outdated => .outdated,
        .lost => .lost,
    };
    if (status == .lost) {
        markSurfaceLost(io, operation.surface, operation.chain, native.device_lost);
        if (native.device_lost) operation.context.markTerminalLossLocked(io);
    }
    const token = switch (acquired) {
        .success, .suboptimal => |value| value,
        .timeout, .outdated, .lost => {
            out.* = .{ .texture = .{ .handle = null }, .status = status };
            return;
        },
    };
    var guard = try core.ObjectGuard.lock(io, operation.device.core.arena.objectList());
    defer guard.unlock(io);
    const texture = try operation.device.createSwapchainTextureLocked(
        allocator, io, &guard, operation.chain, token,
    );
    out.* = .{ .texture = texture, .status = status };
}

pub fn present(io: std.Io, instance: *Instance, handle: api.Surface) SurfaceOperationError!api.Status {
    const operation = try configuredOperation(io, instance, handle);
    defer operation.close(io);
    const result = operation.chain.native.present(io, operation.context.surfaceSerialOwner(operation.chain)) catch |err| {
        if (err == error.DeviceLost) {
            operation.context.markTerminalLossLocked(io);
            markSurfaceLost(io, operation.surface, operation.chain, true);
        }
        return err;
    };
    if (result == .lost) markSurfaceLost(io, operation.surface, operation.chain, false);
    return switch (result) {
        .success, .suboptimal => .success,
        .outdated => error.OutOfDate,
        .lost => error.SurfaceLost,
    };
}

pub fn unconfigure(io: std.Io, instance: *Instance, handle: api.Surface) SurfaceOperationError!void {
    const objects = instance.surfaceObjectList() orelse return error.StaleHandle;
    var guard = try core.ObjectGuard.lock(io, objects);
    const surface = resolve(instance, &guard, handle) catch |err| {
        guard.unlock(io);
        return err;
    };
    if (surface.state == .configuring or surface.state == .unconfiguring) {
        guard.unlock(io);
        return error.SurfaceTransitionInProgress;
    }
    const chain = surface.current_swapchain orelse {
        guard.unlock(io);
        return;
    };
    const previous_state = surface.state;
    surface.state = .unconfiguring;
    guard.unlock(io);
    detachSwapchain(io, surface, chain) catch |err| {
        guard = core.ObjectGuard.lockUncancelable(io, objects);
        if (surface.state == .unconfiguring) surface.state = previous_state;
        guard.unlock(io);
        return err;
    };
    if (previous_state == .lost) {
        guard = core.ObjectGuard.lockUncancelable(io, objects);
        surface.state = .lost;
        guard.unlock(io);
    }
}

fn releaseNativeSurfaceLease(
    context: *anyopaque,
    header: *core.Object,
    device_guard: *const core.ObjectGuard,
    io: std.Io,
) void {
    std.debug.assert(device_guard.held);
    const instance: *Instance = @ptrCast(@alignCast(context));
    const objects = instance.surfaceObjectList() orelse
        @panic("live native surface lost its instance arena");
    var guard = core.ObjectGuard.lockUncancelable(io, objects);
    std.debug.assert(header.tracking == objects);
    std.debug.assert(header.kind == .native_surface);
    header.releaseLeaseLocked(&guard, io);
    guard.unlock(io);
}

fn markSurfaceLost(io: std.Io, surface: *Surface, chain: *swapchain.Swapchain, device_lost: bool) void {
    var device_guard = core.ObjectGuard.lockUncancelable(io, chain.header.tracking);
    defer device_guard.unlock(io);
    var surface_guard = core.ObjectGuard.lockUncancelable(io, surface.header.tracking);
    defer surface_guard.unlock(io);
    surface.state = .lost;
    chain.native.stale = true;
    if (device_lost) {
        chain.native.device_lost = true;
        chain.native.drained = true;
    }
}

fn mapDrainError(err: native_device.CleanupError) SurfaceReleaseError {
    if (err == error.Canceled) return error.Canceled;
    inline for (@typeInfo(dispatch.Error).error_set.?) |member| {
        if (err == @field(anyerror, member.name)) return @errorCast(err);
    }
    inline for (@typeInfo(dispatch.LoadError).error_set.?) |member| {
        if (err == @field(anyerror, member.name)) return @errorCast(err);
    }
    return error.SurfaceInUse;
}
