const std = @import("std");
const dusk = @import("dusk");
const surface = dusk.engine.surface;
const core = dusk.core;
const Instance = dusk.engine.Instance;
const t = std.testing;
const descriptor: dusk.api.descriptors.SurfaceDescriptorChain = .{
    .label = "borrowed host surface",
    .surface_source_xlib_window = .{ .display = @ptrFromInt(4096), .window = 37 },
};

fn resolveSurface(instance: *Instance, io: std.Io, handle: dusk.api.Surface) !*surface.Surface {
    var guard = try core.ObjectGuard.lock(io, instance.surfaceObjectList().?);
    defer guard.unlock(io);
    return surface.resolve(instance, &guard, handle);
}

fn expectEmpty(instance: *Instance, io: std.Io) !void {
    if (instance.surfaceObjectList()) |objects| {
        var guard = try core.ObjectGuard.lock(io, objects);
        defer guard.unlock(io);
        try objects.preflightDeinitLocked(&guard);
        try t.expectEqual(@as(usize, 0), instance.surface_object_arena.?.queryTrackedCount(&guard));
    }
    try t.expectEqual(@as(usize, 0), instance.active_operations);
    try t.expectEqual(@as(usize, 0), instance.accepted_root_operations);
}

test "surface source rejects missing and multiple source arms" {
    try std.testing.expectError(error.DescriptorChainEmpty, surface.sourceFromDescriptor(&.{}));
    try std.testing.expectError(error.UnsupportedSurfaceSource, surface.sourceFromDescriptor(&.{
        .surface_source_android_native_window = .{ .window = @ptrFromInt(4096) },
        .surface_source_xlib_window = .{ .display = @ptrFromInt(8192), .window = 1 },
    }));
}

test "surface source preserves borrowed Xlib and Android identity" {
    const display: *anyopaque = @ptrFromInt(4096);
    const source = try surface.sourceFromDescriptor(&.{
        .surface_source_xlib_window = .{ .display = display, .window = 37 },
    });
    try std.testing.expectEqual(display, source.xlib_window.display.?);
    try std.testing.expectEqual(@as(u64, 37), source.xlib_window.window);
    const window: *anyopaque = @ptrFromInt(8192);
    const android = try surface.sourceFromDescriptor(&.{
        .surface_source_android_native_window = .{ .window = window },
    });
    try std.testing.expectEqual(window, android.android_native_window.?);
}

test "null Android window and unsupported platform sources fail before publication" {
    try std.testing.expectError(error.AndroidWindowNotSet, surface.sourceFromDescriptor(&.{
        .surface_source_android_native_window = .{},
    }));
    try std.testing.expectError(error.UnsupportedSurfaceSource, surface.sourceFromDescriptor(&.{
        .surface_source_metal_layer = .{ .layer = @ptrFromInt(4096) },
    }));
}

test "Instance lazily binds a genuine Surface arena at its stable address" {
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("surface instance cleanup");
    try t.expect(instance.surfaceObjectList() == null);
    try t.expect(instance.surface_object_arena == null);
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    defer surface.release(io, &instance, handle) catch @panic("surface cleanup");
    const arena = instance.surface_object_arena.?;
    const objects = instance.surfaceObjectList().?;
    try t.expect(objects == arena.objectList());
    const payload = try resolveSurface(&instance, io, handle);
    try t.expect(payload.instance == &instance);
    try t.expect(payload.header.tracking == objects);
    try t.expectEqual(core.Handle.Kind.surface, payload.header.kind);
    try t.expectEqual(@as(u32, 1), payload.header.reference_count);
    try t.expectEqual(@as(u32, 1), payload.header.user_reference_count);
    try t.expectEqual(descriptor.surface_source_xlib_window.?.display, payload.source.source.xlib_window.display);
    try t.expectEqual(descriptor.surface_source_xlib_window.?.window, payload.source.source.xlib_window.window);
    try t.expect(instance.native_context == null);
    var guard = try core.ObjectGuard.lock(io, objects);
    defer guard.unlock(io);
    try t.expectEqual(@as(usize, 1), arena.queryTrackedCount(&guard));
    try t.expectError(error.ResourceInUse, objects.preflightDeinitLocked(&guard));
}

test "Instance close refuses live Surface and reopens unchanged before release" {
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("surface instance cleanup");
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    var owned = true;
    defer if (owned) surface.release(io, &instance, handle) catch @panic("surface cleanup");
    const arena = instance.surface_object_arena.?;
    const payload = try resolveSurface(&instance, io, handle);
    try t.expectError(error.InstanceInUse, instance.deinit(t.allocator, io));
    try t.expect(instance.root_state == .open);
    try t.expect(instance.surface_object_arena.? == arena);
    try t.expect((try resolveSurface(&instance, io, handle)) == payload);
    try t.expectEqual(@as(u32, 1), payload.header.reference_count);
    try surface.release(io, &instance, handle);
    owned = false;
    try expectEmpty(&instance, io);
    var guard = try core.ObjectGuard.lock(io, arena.objectList());
    defer guard.unlock(io);
    try t.expectError(error.StaleHandle, surface.resolve(&instance, &guard, handle));
}

test "last Surface user release succeeds while compatible request holds its real lease" {
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("surface instance cleanup");
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    var owned = true;
    defer if (owned) surface.release(io, &instance, handle) catch @panic("surface cleanup");
    try instance.acquireRootOperation(io);
    var pinned = true;
    defer if (pinned) instance.releaseRootOperation(io);
    var request = try surface.acquireCompatibleSurface(io, &instance, handle);
    defer surface.releaseCompatibleSurface(io, &request) catch @panic("compatible lease cleanup");
    const payload = try resolveSurface(&instance, io, handle);
    try t.expect(request.header == &payload.header);
    try t.expectEqual(@as(u32, 2), payload.header.reference_count);
    try surface.release(io, &instance, handle);
    owned = false;
    try t.expect(request.held);
    try t.expectEqual(@as(u32, 1), request.header.reference_count);
    try t.expectEqual(@as(u32, 0), request.header.user_reference_count);
    try t.expectEqual(core.ObjectState.alive, request.header.state);
    instance.releaseRootOperation(io);
    pinned = false;
    try t.expectError(error.InstanceInUse, instance.deinit(t.allocator, io));
    try t.expect(instance.root_state == .open);
    try t.expect((try resolveSurface(&instance, io, handle)) == payload);
    try surface.releaseCompatibleSurface(io, &request);
    try t.expect(!request.held);
    try expectEmpty(&instance, io);
    // Idempotent receipt cleanup must not consume a second core reference.
    try surface.releaseCompatibleSurface(io, &request);
}

fn createInto(allocator: std.mem.Allocator, io: std.Io, instance: *Instance, out: *dusk.api.Surface) !void {
    out.* = try surface.create(allocator, io, instance, &descriptor);
}

fn creationAttempt(allocator: std.mem.Allocator, expect_failure: bool) !void {
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("creation rollback cleanup");
    var out: dusk.api.Surface = .{ .handle = null };
    const result = createInto(allocator, io, &instance, &out);
    if (expect_failure) {
        try t.expectError(error.OutOfMemory, result);
        try t.expect(out.handle == null);
        try t.expect(instance.root_state == .open);
        try t.expect(instance.native_context == null);
        try expectEmpty(&instance, io);
    } else {
        try result;
        try surface.release(io, &instance, out);
        try expectEmpty(&instance, io);
    }
}

test "failN Surface creation rolls back every allocation without publishing an alias" {
    var baseline = t.FailingAllocator.init(t.allocator, .{});
    try creationAttempt(baseline.allocator(), false);
    try t.expect(baseline.alloc_index != 0);
    for (0..baseline.alloc_index) |fail_index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        try creationAttempt(failing.allocator(), true);
        try t.expect(failing.has_induced_failure);
    }
}

const CanceledCreation = struct {
    instance: *Instance,
    entered: std.Io.Event = .unset,
    out: dusk.api.Surface,

    fn run(io: std.Io, job: *CanceledCreation) !void {
        job.entered.set(io);
        job.out = try surface.create(t.allocator, io, job.instance, &descriptor);
    }
};

test "canceling Surface source admission preserves output and existing owner lifetime" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("canceled creation cleanup");
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    defer surface.release(io, &instance, handle) catch @panic("surface cleanup");
    const payload = try resolveSurface(&instance, io, handle);
    const arena = instance.surface_object_arena.?;
    instance.root_work_mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) instance.root_work_mutex.unlock(io);
    var job: CanceledCreation = .{ .instance = &instance, .out = handle };
    var task = try io.concurrent(CanceledCreation.run, .{ io, &job });
    job.entered.waitUncancelable(io);
    try t.expectError(error.Canceled, task.cancel(io));
    instance.root_work_mutex.unlock(io);
    locked = false;
    try t.expectEqual(handle.handle, job.out.handle);
    try t.expect(instance.surface_object_arena.? == arena);
    try t.expect((try resolveSurface(&instance, io, handle)) == payload);
    try t.expectEqual(@as(u32, 1), payload.header.reference_count);
    try t.expectEqual(@as(u32, 1), payload.header.user_reference_count);
    try t.expectEqual(core.ObjectState.alive, payload.header.state);
    try t.expectEqual(@as(usize, 0), instance.active_operations);
    var guard = try core.ObjectGuard.lock(io, arena.objectList());
    defer guard.unlock(io);
    try t.expectEqual(@as(usize, 1), arena.queryTrackedCount(&guard));
}

test "compatible Surface admission rejects a foreign Instance without retaining its header" {
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("surface instance cleanup");
    var foreign = Instance.init(.{ .backend_type = .null_ });
    defer foreign.deinit(t.allocator, io) catch @panic("foreign instance cleanup");
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    defer surface.release(io, &instance, handle) catch @panic("surface cleanup");
    const foreign_handle = try surface.create(t.allocator, io, &foreign, &descriptor);
    defer surface.release(io, &foreign, foreign_handle) catch @panic("foreign surface cleanup");
    try foreign.acquireRootOperation(io);
    defer foreign.releaseRootOperation(io);
    try t.expectError(error.StaleHandle, surface.acquireCompatibleSurface(io, &foreign, handle));
    const payload = try resolveSurface(&instance, io, handle);
    try t.expectEqual(@as(u32, 1), payload.header.reference_count);
    try t.expectEqual(@as(u32, 1), payload.header.user_reference_count);
}

test "final Surface release during a configuration transition preserves its exact source reference" {
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("surface instance cleanup");
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    defer surface.release(io, &instance, handle) catch @panic("surface cleanup");
    const payload = try resolveSurface(&instance, io, handle);
    for ([_]surface.Surface.State{ .configuring, .unconfiguring }) |transition| {
        {
            var guard = try core.ObjectGuard.lock(io, payload.header.tracking);
            defer guard.unlock(io);
            payload.state = transition;
        }
        const result = surface.release(io, &instance, handle);
        var guard = core.ObjectGuard.lockUncancelable(io, payload.header.tracking);
        defer guard.unlock(io);
        defer payload.state = .unconfigured;
        try t.expectError(error.SurfaceInUse, result);
        try t.expectEqual(transition, payload.state);
        try t.expectEqual(core.ObjectState.alive, payload.header.state);
        try t.expectEqual(@as(u32, 1), payload.header.reference_count);
        try t.expectEqual(@as(u32, 1), payload.header.user_reference_count);
        try t.expect((try surface.resolve(&instance, &guard, handle)) == payload);
    }
}

// This negative fixture publishes real core edges, not a successful native WSI
// creation. Its empty native payload owns no Vulkan handles. The Device and its
// queue/context are created by the real backend; only the failing dispatch is
// injected.
const NativeLeaseProbe = struct {
    header: core.Object,
    destroyed: *usize,

    pub fn destroy(self: *NativeLeaseProbe, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        _ = io;
        _ = reason;
        guard.assertOwns(self.header.tracking);
        self.destroyed.* += 1;
    }
};

const DrainFault = struct {
    var target: ?*surface.Surface = null;
    var calls: usize = 0;
    var saw_retiring: bool = false;

    fn idle(queue: @import("vulkan").VkQueue) callconv(.c) @import("vulkan").VkResult {
        _ = queue;
        calls += 1;
        const payload = target.?;
        var guard = core.ObjectGuard.lockUncancelable(t.io, payload.header.tracking);
        defer guard.unlock(t.io);
        saw_retiring = payload.header.state == .retiring;
        return @import("vulkan").VK_ERROR_OUT_OF_HOST_MEMORY;
    }

    fn releaseNative(context: *anyopaque, header: *core.Object, device_guard: *const core.ObjectGuard, io: std.Io) void {
        _ = context;
        _ = device_guard;
        var guard = core.ObjectGuard.lockUncancelable(io, header.tracking);
        defer guard.unlock(io);
        header.releaseLeaseLocked(&guard, io);
    }
};

test "final Surface drain dispatch error restores alive and preserves exact published lease graph" {
    const vk = @import("vulkan");
    const io = t.io;
    var instance = Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(t.allocator, io) catch @panic("drain instance cleanup");
    // No cached VkInstance exists here, so no borrowed fake host pointer reaches
    // native surface creation.
    const handle = try surface.create(t.allocator, io, &instance, &descriptor);
    defer surface.release(io, &instance, handle) catch @panic("drain surface cleanup");
    const payload = try resolveSurface(&instance, io, handle);
    var adapters = try instance.enumerateAdapters(t.allocator, io, .{
        .backend_type = .vulkan, .feature_level = .core, .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("drain adapter cleanup");
    try t.expect(adapters.items.len != 0);
    var device_mutex: std.Io.Mutex = .init;
    var device = try adapters.items[0].createDevice(t.allocator, io, .{
        .adapter = &adapters.items[0], .object_mutex = &device_mutex, .feature_level = .core,
    });
    defer device.deinit(t.allocator, io) catch @panic("drain device cleanup");
    {
        try device.acquireOperation(io);
        defer device.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try device.bindObjectsLocked(&guard, t.allocator);
    }
    const native = device.native.?;
    try t.expectEqual(@as(u64, 0), native.queue.timeline.lastSubmittedSerial());
    var procs = native.native_device.procs.*;
    procs.queue_wait_idle = DrainFault.idle;
    var destroyed: usize = 0;
    var instance_guard = try core.ObjectGuard.lock(io, payload.header.tracking);
    const native_lease = instance.surface_object_arena.?.create(t.allocator, &instance_guard, NativeLeaseProbe, .{
        .kind = .native_surface, .initial_reference = .lease,
    }) catch |err| {
        instance_guard.unlock(io);
        return err;
    };
    native_lease.destroyed = &destroyed;
    native_lease.header.setInitializedNoError(&instance_guard);
    native_lease.header.attach(&instance_guard, io);
    instance_guard.unlock(io);
    var native_lease_owned = true;
    defer if (native_lease_owned) {
        var guard = core.ObjectGuard.lockUncancelable(io, native_lease.header.tracking);
        defer guard.unlock(io);
        native_lease.header.releaseLeaseLocked(&guard, io);
    };
    var device_guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    const chain = device.core.create(t.allocator, &device_guard, dusk.engine.swapchain.Swapchain, .{
        .kind = .swapchain, .initial_reference = .lease,
    }) catch |err| {
        device_guard.unlock(io);
        return err;
    };
    chain.native = .{
        .backend = .{
            .device = native.native_device.vk_device, .queue = native.queue.context.vk_queue,
            .procs = &procs, .swapchain_available = false,
        },
        .handle = null, .generation = 1, .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .extent = .{ .width = 1, .height = 1 }, .present_mode = vk.VK_PRESENT_MODE_FIFO_KHR,
        .queue_family_index = native.native_device.queue_family_index, .acquire_semaphore = null,
    };
    chain.native_surface_header = &native_lease.header;
    chain.release_context = &instance;
    chain.release_native_surface_fn = DrainFault.releaseNative;
    chain.header.setInitializedNoError(&device_guard);
    chain.header.attach(&device_guard, io);
    native_lease_owned = false;
    instance_guard = core.ObjectGuard.lockUncancelable(io, payload.header.tracking);
    payload.current_swapchain = chain;
    payload.state = .configured;
    instance_guard.unlock(io);
    device_guard.unlock(io);
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        var owner_guard = core.ObjectGuard.lockUncancelable(io, payload.header.tracking);
        payload.current_swapchain = null;
        payload.state = .unconfigured;
        owner_guard.unlock(io);
        chain.header.releaseLeaseLocked(&guard, io);
        guard.unlock(io);
    }
    DrainFault.target = payload;
    DrainFault.calls = 0;
    DrainFault.saw_retiring = false;
    defer DrainFault.target = null;
    try t.expectError(error.OutOfHostMemory, surface.release(io, &instance, handle));
    try t.expectEqual(@as(usize, 1), DrainFault.calls);
    try t.expect(DrainFault.saw_retiring);
    device_guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer device_guard.unlock(io);
    instance_guard = try core.ObjectGuard.lock(io, payload.header.tracking);
    defer instance_guard.unlock(io);
    try t.expectEqual(core.ObjectState.alive, payload.header.state);
    try t.expectEqual(surface.Surface.State.configured, payload.state);
    try t.expect(payload.current_swapchain.? == chain);
    try t.expectEqual(@as(u32, 1), payload.header.reference_count);
    try t.expectEqual(@as(u32, 1), payload.header.user_reference_count);
    try t.expectEqual(core.ObjectState.alive, chain.header.state);
    try t.expectEqual(@as(u32, 1), chain.header.reference_count);
    try t.expectEqual(@as(u32, 0), chain.header.user_reference_count);
    try t.expect(chain.native_surface_header.? == &native_lease.header);
    try t.expectEqual(@as(u32, 1), native_lease.header.reference_count);
    try t.expectEqual(@as(u32, 0), native_lease.header.user_reference_count);
    try t.expectEqual(@as(usize, 0), destroyed);
}
