const std = @import("std");
const dusk = @import("dusk");

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: dusk.core.ErrorView) void {
    @panic("unexpected uncaptured device error");
}

fn options(
    adapter: *dusk.engine.Adapter,
    context: *u8,
    object_mutex: ?*std.Io.Mutex,
) dusk.engine.Device.CreateDeviceOptions {
    return .{
        .adapter = adapter,
        .feature_level = adapter.getFeatureLevel(),
        .uncaptured_context = context,
        .uncaptured_callback = uncaptured,
        .object_mutex = object_mutex,
    };
}

fn createSafetyDevice(
    allocator: std.mem.Allocator,
    io: std.Io,
    adapter: *dusk.engine.Adapter,
    user_context: *u8,
) !dusk.engine.Device {
    const context = try allocator.create(native_context.NativeDeviceContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .native_device = undefined,
        .device_mutex = .{},
        .queue = undefined,
        .pipeline_backend = undefined,
        .render_pass_cache = undefined,
        .framebuffer_cache = undefined,
    };
    var device = try adapter.createDevice(
        allocator,
        io,
        options(adapter, user_context, &context.device_mutex.mutex),
    );
    device.native = context;
    return device;
}

const ReferenceSnapshot = struct {
    alive: bool,
    total: u32,
    user: u32,
};

fn references(io: std.Io, object: *dusk.core.Object) ReferenceSnapshot {
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, object.tracking);
    defer guard.unlock(io);
    return .{
        .alive = object.isAlive(&guard),
        .total = object.reference_count,
        .user = object.user_reference_count,
    };
}

fn bufferState(
    io: std.Io,
    device: *dusk.engine.Device,
    buffer: *dusk.engine.native_resources.Buffer,
) !dusk.engine.buffer.State {
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
    defer guard.unlock(io);
    std.debug.assert(buffer.header.isAlive(&guard));
    return buffer.native.getState();
}

const ArenaSnapshot = struct {
    capacity: usize,
    tracked: usize,
    total: u64,
    user: u64,
};

fn arenaSnapshot(io: std.Io, device: *dusk.engine.Device) ArenaSnapshot {
    const arena = &device.core.arena;
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, arena.objectList());
    defer guard.unlock(io);
    return .{
        .capacity = arena.queryCapacity(&guard),
        .tracked = arena.queryTrackedCount(&guard),
        .total = arena.objectList().total_reference_count,
        .user = arena.objectList().user_reference_count,
    };
}

test "destroy is readable and idempotent and deinit does not release owner twice" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("adapter list teardown failed");
    var context: u8 = 0;
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(allocator, io, options(&list.items[0], &context, &object_mutex));
    try std.testing.expectError(error.AdapterListInUse, list.deinit(io));
    try std.testing.expectError(error.InstanceInUse, instance.deinit(allocator, io));
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try device.destroy(allocator, io);
    try device.destroy(allocator, io);
    try std.testing.expectEqual(dusk.engine.DeviceState.destroyed, device.getState());
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try device.deinit(allocator, io);
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

test "failed device limits request does not retain adapter or instance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("adapter list teardown failed");
    var context: u8 = 0;
    var requested: dusk.api.Limits = .{};
    requested.max_bind_groups = std.math.maxInt(u32) - 1;
    var object_mutex: std.Io.Mutex = .init;
    var descriptor = options(&list.items[0], &context, &object_mutex);
    descriptor.required_limits = &requested;
    try std.testing.expectError(
        error.RequiredLimitAboveAdapterLimit,
        list.items[0].createDevice(allocator, io, descriptor),
    );
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
}

test "native pipeline layout retains its descriptor layout until released" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{});
    defer instance.deinit(allocator, io) catch @panic("native instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("native adapter list teardown failed");
    try std.testing.expect(list.items.len != 0);
    var context: u8 = 0;
    var device = try list.items[0].createDevice(allocator, io, options(&list.items[0], &context, null));
    defer device.deinit(allocator, io) catch @panic("native device teardown failed");
    const group = try device.createBindGroupLayout(allocator, io, .{ .entries = &.{} });
    const before_mismatch = arenaSnapshot(io, &device);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.AllocatorMismatch, device.createPipelineLayout(
        failing.allocator(),
        io,
        .{ .groups = &.{group} },
    ));
    try std.testing.expectEqual(before_mismatch, arenaSnapshot(io, &device));
    try std.testing.expectEqual(@as(u32, 1), references(io, &group.header).total);
    try std.testing.expect(references(io, &group.header).alive);
    const layout = try device.createPipelineLayout(allocator, io, .{ .groups = &.{group} });
    try std.testing.expectEqual(@as(u32, 2), references(io, &group.header).total);
    try device.release(allocator, io, group);
    try std.testing.expect(references(io, &group.header).alive);
    try std.testing.expectEqual(@as(u32, 1), references(io, &group.header).total);
    try std.testing.expectEqual(@as(u32, 0), references(io, &group.header).user);
    try std.testing.expectError(error.NoOwnedReference, device.release(allocator, io, group));
    try device.release(allocator, io, layout);
    try std.testing.expect(!references(io, &group.header).alive);
    const buffer = try device.createBuffer(allocator, io, .{
        .size = 4,
        .usage = .{ .copy_dst = true },
    });
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        allocator,
        device.core.borrow(),
        .{},
    );
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    {
        try device.acquireOperation(io);
        defer device.releaseOperation(io);
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try buffer.ref(&guard), .data = &.{ 1, 2, 3, 4 } });
    }
    var finished = try encoder.finish();
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    try device.release(allocator, io, buffer);
    try std.testing.expectError(error.ResourceDestroyed, device.submit(allocator, io, &finished));
    try device.destroy(allocator, io);
    try std.testing.expectError(error.DeviceNotAlive, device.getQueue(io));
}

const vk = dusk.platform.vulkan_bindings;
const dispatch = dusk.vk.dispatch;
const native_context = dusk.engine.native_device_context;
const SafetyOperationError = dusk.engine.device.OperationError ||
    dusk.command.Error || dusk.command.attachment_state.AttachmentError;

// The fake VkDevice carries the entire scenario. Real high Device operations,
// replay, queue fence retirement and core resource destruction remain in use.
const SafetyProbe = struct {
    device: *dusk.engine.Device,
    io: std.Io,
    handles: dusk.engine.vulkan_device.HandleSet = .{},
    instance_procs: dispatch.InstanceProcs = std.mem.zeroes(dispatch.InstanceProcs),
    global_procs: dispatch.GlobalProcs = std.mem.zeroes(dispatch.GlobalProcs),
    native_instance: dusk.engine.vulkan_device.VulkanInstance,
    wait_result: vk.VkResult = vk.VK_SUCCESS,
    idle_result: vk.VkResult = vk.VK_SUCCESS,
    destroy_during_wait: bool = false,
    destroy_error: ?dusk.engine.device.CleanupError = null,
    unmap_during_end: ?*dusk.engine.native_resources.Buffer = null,
    unmap_error: ?dusk.engine.device.OperationError = null,
    copies: usize = 0,
    ended_commands: usize = 0,
    submitted_batches: usize = 0,
    destroyed_devices: usize = 0,
    destroyed_layouts: usize = 0,
    destroyed_framebuffers: usize = 0,
    destroyed_fences: usize = 0,
    destroyed_pools: usize = 0,
    destroyed_query_pools: usize = 0,
    freed_command_buffers: usize = 0,
    commands_freed_before_pools: bool = true,
    freed_at_device_destroy: usize = 0,
    pools_at_device_destroy: usize = 0,
    children_before_device: bool = false,
    completed_at_device_destroy: dusk.platform.Serial = 0,
    created_fences: usize = 0,
    reset_fences: usize = 0,
    wait_calls: std.atomic.Value(usize) = .init(0),
    overlap: bool = false,
    first_status_entered: std.Io.Event = .unset,
    allow_first_status: std.Io.Event = .unset,
    contender_decided: std.Io.Event = .unset,

    /// Call attach at the fixture's final address before using its native device.
    /// Keep that address live until the device is deinitialized.
    fn initUnattached(io: std.Io, device: *dusk.engine.Device) SafetyProbe {
        // SAFETY: attach writes procs/global before publishing their borrowed
        // pointers. Native device dispatch/teardown read only those fields;
        // this fixture never reads or deinitializes the unowned instance fields.
        return .{ .device = device, .io = io, .native_instance = undefined };
    }

    fn from(handle: anytype) *SafetyProbe {
        return @ptrCast(@alignCast(handle));
    }

    fn attach(self: *SafetyProbe) !void {
        const allocator = std.testing.allocator;
        const context = self.device.native.?;
        try std.testing.expect(self.device.core.arena.objectList().mutex == &context.device_mutex.mutex);
        const procs = try allocator.create(dispatch.DeviceProcs);
        procs.* = std.mem.zeroes(dispatch.DeviceProcs);
        procs.wait_for_fences = wait;
        procs.get_fence_status = status;
        procs.device_wait_idle = idle;
        procs.end_command_buffer = end;
        procs.queue_submit = submit;
        procs.create_fence = createFence;
        procs.reset_fences = resetFences;
        procs.destroy_fence = destroyFence;
        procs.destroy_command_pool = destroyPool;
        procs.free_command_buffers = freeCommands;
        procs.reset_command_pool = resetPool;
        procs.begin_command_buffer = begin;
        procs.create_descriptor_set_layout = createLayout;
        procs.destroy_descriptor_set_layout = destroyLayout;
        procs.create_query_pool = createQueryPool;
        procs.destroy_query_pool = destroyQueryPool;
        procs.destroy_framebuffer = destroyFramebuffer;
        procs.destroy_render_pass = destroyRenderPass;
        procs.cmd_copy_buffer = copy;
        procs.destroy_buffer = destroyBuffer;
        self.instance_procs.destroy_device = destroyDevice;
        // Only the procedure tiers are borrowed; this fixture owns no loader.
        self.native_instance.procs = &self.instance_procs;
        self.native_instance.global = &self.global_procs;
        const handle: vk.VkDevice = @ptrCast(self);
        context.native_device = .{
            .vk_device = handle,
            .api_version = vk.VK_API_VERSION_1_1,
            .procs = procs,
            .instance = &self.native_instance,
            .physical = .{
                .handle = null,
                .properties = std.mem.zeroes(vk.VkPhysicalDeviceProperties),
                .features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures),
                .memory_properties = std.mem.zeroes(vk.VkPhysicalDeviceMemoryProperties),
                .max_buffer_size = 1024,
                .queue_families = &.{},
            },
            .queue_family_index = 0,
            .handles = &self.handles,
            .maintenance4_enabled = false,
            .enabled_features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures),
            .timestamp_valid_bits = 0,
            .timestamp_period = 0,
        };
        context.pipeline_backend = dusk.pipeline.pipeline.Backend.fromDeviceProcs(handle, procs);
        context.render_pass_cache = dusk.engine.render_pass_cache.RenderPassCache.init(.{
            .allocator = allocator,
            .device = .{ .procs = procs, .vk_device = handle },
        });
        context.framebuffer_cache = dusk.engine.framebuffer_cache.FramebufferCache.init(.{
            .allocator = allocator,
            .device = .{ .procs = procs, .vk_device = handle },
            .destroy_context = self,
            .destroy_when_unused = deferFramebuffer,
        });
        context.queue = .{
            .context = .{
                .allocator = allocator,
                .dispatch = .{ .global = null, .instance = null, .device = procs },
                .vk_device = handle,
                .vk_queue = @ptrCast(self),
                .queue_family_index = 0,
                .memory_properties = &context.native_device.physical.memory_properties,
                .handles = &self.handles,
            },
            .device_mutex = &context.device_mutex,
            .timeline = .{},
            .context_count = 2,
        };
        // Supply two already-begun contexts to isolate fence reuse from pool creation.
        for (context.queue.contexts[0..2]) |*slot| {
            slot.* = .{ .pool = @ptrCast(self), .command_buffer = @ptrCast(self) };
            self.handles.acquire(.command_pool);
            self.handles.acquire(.command_buffer);
        }
        self.handles.acquire(.device);
    }

    fn wait(
        handle: vk.VkDevice,
        _: u32,
        _: [*c]const vk.VkFence,
        _: vk.VkBool32,
        _: u64,
    ) callconv(.c) vk.VkResult {
        const self = from(handle);
        const call = self.wait_calls.fetchAdd(1, .acq_rel);
        if (self.destroy_during_wait) {
            self.destroy_during_wait = false;
            self.device.destroy(std.testing.allocator, self.io) catch |err| {
                self.destroy_error = err;
            };
            // The old implementation can consume the context in the callback.
            // Returning an error stops that old wait before its next queue access.
            return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        if (self.overlap and call != 0) {
            self.contender_decided.set(self.io);
            return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        return self.wait_result;
    }

    fn status(handle: vk.VkDevice, _: vk.VkFence) callconv(.c) vk.VkResult {
        const self = from(handle);
        if (self.overlap) {
            self.first_status_entered.set(self.io);
            self.allow_first_status.waitUncancelable(self.io);
        }
        return vk.VK_SUCCESS;
    }

    fn idle(handle: vk.VkDevice) callconv(.c) vk.VkResult {
        return from(handle).idle_result;
    }

    fn end(command: vk.VkCommandBuffer) callconv(.c) vk.VkResult {
        const self = from(command);
        self.ended_commands += 1;
        if (self.unmap_during_end) |resource| {
            self.unmap_during_end = null;
            self.device.unmapBuffer(self.io, resource) catch |err| {
                self.unmap_error = err;
            };
        }
        return vk.VK_SUCCESS;
    }

    fn submit(
        queue: vk.VkQueue,
        _: u32,
        _: [*c]const vk.VkSubmitInfo,
        _: vk.VkFence,
    ) callconv(.c) vk.VkResult {
        from(queue).submitted_batches += 1;
        return vk.VK_SUCCESS;
    }

    fn createFence(
        handle: vk.VkDevice,
        _: [*c]const vk.VkFenceCreateInfo,
        _: [*c]const vk.VkAllocationCallbacks,
        result: [*c]vk.VkFence,
    ) callconv(.c) vk.VkResult {
        const self = from(handle);
        self.created_fences += 1;
        result[0] = @ptrCast(self);
        return vk.VK_SUCCESS;
    }

    fn resetFences(handle: vk.VkDevice, _: u32, _: [*c]const vk.VkFence) callconv(.c) vk.VkResult {
        from(handle).reset_fences += 1;
        return vk.VK_SUCCESS;
    }

    fn destroyFence(
        handle: vk.VkDevice,
        _: vk.VkFence,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        from(handle).destroyed_fences += 1;
    }
    fn freeCommands(
        handle: vk.VkDevice,
        _: vk.VkCommandPool,
        count: u32,
        _: [*c]const vk.VkCommandBuffer,
    ) callconv(.c) void {
        from(handle).freed_command_buffers += count;
    }
    fn destroyPool(
        handle: vk.VkDevice,
        _: vk.VkCommandPool,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self = from(handle);
        self.commands_freed_before_pools = self.commands_freed_before_pools and
            self.freed_command_buffers > self.destroyed_pools;
        self.destroyed_pools += 1;
    }
    fn resetPool(
        _: vk.VkDevice,
        _: vk.VkCommandPool,
        _: vk.VkCommandPoolResetFlags,
    ) callconv(.c) vk.VkResult {
        return vk.VK_SUCCESS;
    }
    fn begin(
        _: vk.VkCommandBuffer,
        _: [*c]const vk.VkCommandBufferBeginInfo,
    ) callconv(.c) vk.VkResult {
        return vk.VK_SUCCESS;
    }
    fn destroyDevice(handle: vk.VkDevice, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = from(handle);
        const timeline = &self.device.native.?.queue.timeline;
        timeline.mutex.lockUncancelable(self.io);
        self.completed_at_device_destroy = timeline.completed;
        timeline.mutex.unlock(self.io);
        self.freed_at_device_destroy = self.freed_command_buffers;
        self.pools_at_device_destroy = self.destroyed_pools;
        self.children_before_device = self.destroyed_layouts == 1 and
            self.destroyed_framebuffers == 1 and self.destroyed_fences == 1 and
            self.destroyed_pools == 2 and self.freed_command_buffers == 2 and
            self.commands_freed_before_pools;
        self.destroyed_devices += 1;
    }

    fn expectCommandTeardown(self: *const SafetyProbe) !void {
        try std.testing.expect(self.commands_freed_before_pools);
        try std.testing.expectEqual(@as(usize, 2), self.freed_command_buffers);
        try std.testing.expectEqual(@as(usize, 2), self.destroyed_pools);
        try std.testing.expectEqual(@as(usize, 2), self.freed_at_device_destroy);
        try std.testing.expectEqual(@as(usize, 2), self.pools_at_device_destroy);
    }

    fn createQueryPool(
        handle: vk.VkDevice,
        _: [*c]const vk.VkQueryPoolCreateInfo,
        _: [*c]const vk.VkAllocationCallbacks,
        result: [*c]vk.VkQueryPool,
    ) callconv(.c) vk.VkResult {
        result[0] = @ptrCast(from(handle));
        return vk.VK_SUCCESS;
    }

    fn destroyQueryPool(
        handle: vk.VkDevice,
        _: vk.VkQueryPool,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        from(handle).destroyed_query_pools += 1;
    }

    fn createLayout(
        handle: vk.VkDevice,
        _: [*c]const vk.VkDescriptorSetLayoutCreateInfo,
        _: [*c]const vk.VkAllocationCallbacks,
        result: [*c]vk.VkDescriptorSetLayout,
    ) callconv(.c) vk.VkResult {
        result[0] = @ptrCast(from(handle));
        return vk.VK_SUCCESS;
    }
    fn destroyLayout(
        handle: vk.VkDevice,
        _: vk.VkDescriptorSetLayout,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        from(handle).destroyed_layouts += 1;
    }
    fn destroyFramebuffer(
        handle: vk.VkDevice,
        _: vk.VkFramebuffer,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        from(handle).destroyed_framebuffers += 1;
    }
    fn destroyRenderPass(
        _: vk.VkDevice,
        _: vk.VkRenderPass,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {}
    fn deferFramebuffer(context: *anyopaque, framebuffer: vk.VkFramebuffer) void {
        const self: *SafetyProbe = @ptrCast(@alignCast(context));
        self.device.native.?.deferred_framebuffers.appendAssumeCapacity(framebuffer);
    }
    fn copy(
        command: vk.VkCommandBuffer,
        _: vk.VkBuffer,
        _: vk.VkBuffer,
        _: u32,
        _: [*c]const vk.VkBufferCopy,
    ) callconv(.c) void {
        from(command).copies += 1;
    }
    fn destroyBuffer(
        _: vk.VkDevice,
        _: vk.VkBuffer,
        _: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {}
};

fn submitEmpty(io: std.Io, device: *dusk.engine.Device) SafetyOperationError!dusk.platform.Serial {
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        std.testing.allocator,
        device.core.borrow(),
        .{},
    );
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(std.testing.allocator, io, &guard);
    }
    var finished = try encoder.finish();
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(std.testing.allocator, io, &guard);
    }
    return device.submit(std.testing.allocator, io, &finished);
}

test "native safety active wait refuses destroy without releasing ownership" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer {
        probe.wait_result = vk.VK_SUCCESS;
        probe.idle_result = vk.VK_SUCCESS;
        device.deinit(allocator, io) catch @panic("device teardown failed");
    }
    const serial = try submitEmpty(io, &device);
    probe.destroy_during_wait = true;
    probe.wait_result = vk.VK_TIMEOUT;
    probe.idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    try std.testing.expectError(error.OutOfHostMemory, device.wait(io, serial));
    try std.testing.expectEqual(
        @as(?dusk.engine.device.CleanupError, error.ResourceInUse),
        probe.destroy_error,
    );
    try std.testing.expectEqual(dusk.engine.DeviceState.alive, device.getState());
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_devices);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    probe.wait_result = vk.VK_SUCCESS;
    probe.idle_result = vk.VK_SUCCESS;
    try device.wait(io, serial);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, null), device.pending_serial);
}

test "native safety failed idle preserves resources and retryable deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer {
        probe.wait_result = vk.VK_SUCCESS;
        probe.idle_result = vk.VK_SUCCESS;
        device.deinit(allocator, io) catch @panic("device teardown failed");
    }
    const layout = try device.createBindGroupLayout(allocator, io, .{ .entries = &.{} });
    const serial = try submitEmpty(io, &device);
    try device.native.?.deferred_framebuffers.append(allocator, @ptrCast(&probe));
    probe.wait_result = vk.VK_TIMEOUT;
    probe.idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    try std.testing.expectError(error.FenceWaitTimedOut, device.destroy(allocator, io));
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_devices);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_layouts);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_framebuffers);
    try std.testing.expect(references(io, &layout.header).alive);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, serial), device.pending_serial);
    try std.testing.expectError(error.InstanceInUse, instance.deinit(allocator, io));
    const wait_calls_before_refusal = probe.wait_calls.load(.acquire);
    const native_before_refusal = device.native;
    const state_before_refusal = device.getState();
    const arena_before_refusal = arenaSnapshot(io, &device);
    try std.testing.expectError(error.ResourceInUse, device.deinit(allocator, io));
    try std.testing.expectEqual(wait_calls_before_refusal, probe.wait_calls.load(.acquire));
    try std.testing.expectEqual(native_before_refusal, device.native);
    try std.testing.expectEqual(state_before_refusal, device.getState());
    try std.testing.expectEqual(arena_before_refusal, arenaSnapshot(io, &device));
    try std.testing.expectEqual(@as(?dusk.platform.Serial, serial), device.pending_serial);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try std.testing.expect(references(io, &layout.header).alive);
    probe.wait_result = vk.VK_SUCCESS;
    probe.idle_result = vk.VK_SUCCESS;
    try device.destroy(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_devices);
    try probe.expectCommandTeardown();
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_layouts);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_framebuffers);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    const retired_before_refusal = arenaSnapshot(io, &device);
    try std.testing.expectError(error.ResourceInUse, device.deinit(allocator, io));
    try std.testing.expectEqual(retired_before_refusal, arenaSnapshot(io, &device));
    try std.testing.expectEqual(native_before_refusal, device.native);
    try std.testing.expectEqual(dusk.engine.DeviceState.destroyed, device.getState());
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_devices);
    try device.retain(allocator, io, layout);
    try std.testing.expectEqual(@as(u32, 2), references(io, &layout.header).user);
    try std.testing.expect(!references(io, &layout.header).alive);
    try device.release(allocator, io, layout);
    try std.testing.expectError(error.ResourceInUse, device.deinit(allocator, io));
    try device.release(allocator, io, layout);
    try std.testing.expectError(error.NoOwnedReference, device.release(allocator, io, layout));
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_layouts);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

// The staged native payload is arena-owned just like createBuffer's result.
// This fixture needs no memory allocation procs: copy recording is the seam.
fn stagedBuffer(io: std.Io, device: *dusk.engine.Device) !*dusk.engine.native_resources.Buffer {
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    const arena = &device.core.arena;
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, arena.objectList());
    defer guard.unlock(io);
    try device.bindObjectsLocked(&guard, std.testing.allocator);
    const allocator = arena.allocator(&guard);
    const owner = try arena.create(
        std.testing.allocator,
        &guard,
        dusk.engine.native_resources.Buffer,
        .{ .kind = .native_buffer, .initial_reference = .user },
    );
    errdefer owner.header.discardUnpublishedLocked(&guard) catch @panic("fixture rollback failed");
    const destination = try allocator.create(dusk.engine.buffer.Buffer);
    errdefer allocator.destroy(destination);
    const source = try std.testing.allocator.create(dusk.engine.buffer.Buffer);
    errdefer std.testing.allocator.destroy(source);
    destination.* = .{
        .device = device.native.?.bufferDevice(),
        .handle = @ptrCast(destination),
        .allocation = .{ .memory = null, .offset = 0, .size = 4, .memory_type_index = 0 },
        .mapped = null,
        .size = 4,
        .allocated_size = 4,
        .usage = .{ .copy_dst = true },
        .internal_usage = dusk.engine.buffer.computeInternalBufferUsages(.{ .copy_dst = true }),
        .state = .mapped_at_creation,
        .map_mode = .none,
        .map_offset = 0,
        .map_size = 4,
        .is_mapped_at_creation = true,
        .is_data_initialized = true,
        .staging = source,
        .last_usage_serial = 0,
        .last_write_usage = 0,
        .last_write_shader_stage = .none,
        .read_usage = 0,
        .read_shader_stages = .none,
        .host_visible = false,
        .host_coherent = true,
    };
    destination.device.allocator = std.testing.allocator;
    source.* = destination.*;
    source.handle = @ptrCast(source);
    source.usage = .{ .copy_src = true };
    source.internal_usage = dusk.engine.buffer.computeInternalBufferUsages(source.usage);
    source.staging = null;
    source.state = .unmapped;
    destination.device.handles.acquire(.buffer);
    source.device.handles.acquire(.buffer);
    owner.native = destination;
    owner.allocator = allocator;
    owner.device = device.native.?.resourceDevice();
    owner.cleanup_error = null;
    owner.header.attach(&guard, io);
    return owner;
}

fn registeredQuery(io: std.Io, device: *dusk.engine.Device) !*dusk.engine.query_set.QuerySet {
    const allocator = std.testing.allocator;
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try device.bindObjectsLocked(&guard, allocator);
    const queue = &device.native.?.queue;
    const handle = try dusk.engine.vulkan_query_set.create(
        allocator,
        io,
        &guard,
        &device.core,
        .{ .type_ = .occlusion, .count = 1 },
        .{},
        queue,
    );
    const set = try dusk.engine.query_set.resolveQuerySet(&device.core, &guard, handle);
    errdefer set.header.releaseUserLocked(&guard, io) catch unreachable;
    try queue.trackQuerySet(&guard, set);
    return set;
}

fn expectQueryRegistrations(io: std.Io, device: *dusk.engine.Device, count: usize) !void {
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const queue = &device.native.?.queue;
    try std.testing.expectEqual(count, queue.query_set_count);
    if (count == 0) try std.testing.expect(queue.query_sets == null);
}

fn expectTemporaryUploads(io: std.Io, device: *dusk.engine.Device, count: usize) !void {
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const uploads = device.native.?.queue.temporary_buffers.items;
    try std.testing.expectEqual(count, uploads.len);
    for (uploads) |upload| {
        try std.testing.expect(upload.allocator.ptr == std.testing.allocator.ptr);
        try std.testing.expect(upload.allocator.vtable == std.testing.allocator.vtable);
        try std.testing.expect(upload.buffer.device.allocator.ptr == std.testing.allocator.ptr);
        try std.testing.expect(upload.buffer.device.allocator.vtable == std.testing.allocator.vtable);
        try std.testing.expectEqual(dusk.engine.buffer.State.unmapped, upload.buffer.getState());
    }
}

test "native safety submission refuses staged unmap during command buffer end" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer device.deinit(allocator, io) catch @panic("device teardown failed");
    const buffer = try stagedBuffer(io, &device);
    defer device.release(allocator, io, buffer) catch @panic("buffer release failed");
    probe.unmap_during_end = buffer;
    const serial = try submitEmpty(io, &device);
    try std.testing.expectEqual(
        @as(?dusk.engine.device.OperationError, error.ResourceInUse),
        probe.unmap_error,
    );
    try std.testing.expectEqual(@as(usize, 0), probe.copies);
    try std.testing.expectEqual(
        dusk.engine.buffer.State.mapped_at_creation,
        try bufferState(io, &device, buffer),
    );
    try device.wait(io, serial);
    try device.unmapBuffer(io, buffer);
    try std.testing.expectEqual(@as(usize, 1), probe.copies);
    try std.testing.expectEqual(dusk.engine.buffer.State.unmapped, try bufferState(io, &device, buffer));
}

test "native safety staged recording root survives user release until submitted completion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer {
        probe.wait_result = vk.VK_SUCCESS;
        probe.idle_result = vk.VK_SUCCESS;
        device.deinit(allocator, io) catch @panic("device teardown failed");
    }
    const buffer = try stagedBuffer(io, &device);
    try device.unmapBuffer(io, buffer);
    try std.testing.expectEqual(@as(usize, 1), probe.copies);
    try device.release(allocator, io, buffer);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = true, .total = 1, .user = 0 },
        references(io, &buffer.header),
    );
    try expectTemporaryUploads(io, &device, 1);
    const serial = try submitEmpty(io, &device);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = true, .total = 1, .user = 0 },
        references(io, &buffer.header),
    );
    try expectTemporaryUploads(io, &device, 1);
    probe.wait_result = vk.VK_TIMEOUT;
    probe.idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    try std.testing.expectError(error.FenceWaitTimedOut, device.wait(io, serial));
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = true, .total = 1, .user = 0 },
        references(io, &buffer.header),
    );
    try expectTemporaryUploads(io, &device, 1);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, serial), device.pending_serial);
    probe.wait_result = vk.VK_SUCCESS;
    probe.idle_result = vk.VK_SUCCESS;
    try device.wait(io, serial);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = false, .total = 0, .user = 0 },
        references(io, &buffer.header),
    );
    try expectTemporaryUploads(io, &device, 0);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, null), device.pending_serial);
    try device.destroy(allocator, io);
    try probe.expectCommandTeardown();
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

test "native safety unrelated queue submission leaves staged recording root unchanged" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer {
        probe.wait_result = vk.VK_SUCCESS;
        probe.idle_result = vk.VK_SUCCESS;
        device.deinit(allocator, io) catch @panic("device teardown failed");
    }
    const buffer = try stagedBuffer(io, &device);
    try device.unmapBuffer(io, buffer);
    try device.release(allocator, io, buffer);
    var lease = try device.getQueue(io);
    defer lease.deinit(io);
    const unrelated: vk.VkCommandBuffer = @ptrCast(&user_context);
    try std.testing.expect(unrelated != lease.commandBuffer());
    const commands = [_]vk.VkCommandBuffer{unrelated};
    const before_refusal = arenaSnapshot(io, &device);
    const ends_before_refusal = probe.ended_commands;
    const submissions_before_refusal = probe.submitted_batches;
    const waits_before_refusal = probe.wait_calls.load(.acquire);
    try std.testing.expectError(
        error.PendingRecordingNotSubmitted,
        lease.submit(allocator, io, .{ .command_buffers = &commands }, &.{}),
    );
    try std.testing.expectEqual(before_refusal, arenaSnapshot(io, &device));
    try std.testing.expectEqual(ends_before_refusal, probe.ended_commands);
    try std.testing.expectEqual(submissions_before_refusal, probe.submitted_batches);
    try std.testing.expectEqual(waits_before_refusal, probe.wait_calls.load(.acquire));
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = true, .total = 1, .user = 0 },
        references(io, &buffer.header),
    );
    try std.testing.expectEqual(@as(dusk.platform.Serial, 0), lease.lastSubmittedSerial());
    try std.testing.expectEqual(@as(usize, 0), probe.created_fences);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, null), device.pending_serial);
    lease.deinit(io);
    const serial = try submitEmpty(io, &device);
    try device.wait(io, serial);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = false, .total = 0, .user = 0 },
        references(io, &buffer.header),
    );
    try device.destroy(allocator, io);
    try probe.expectCommandTeardown();
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

test "native safety first completed wait releases pending query root and registration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer device.deinit(allocator, io) catch @panic("device teardown failed");
    const set = try registeredQuery(io, &device);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = true, .total = 2, .user = 1 },
        references(io, &set.header),
    );
    var lease = try device.getQueue(io);
    defer lease.deinit(io);
    const commands = [_]vk.VkCommandBuffer{lease.commandBuffer()};
    const submitted = try lease.submit(allocator, io, .{ .command_buffers = &commands }, &.{&set.header});
    lease.deinit(io);
    try device.release(allocator, io, set);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = true, .total = 2, .user = 0 },
        references(io, &set.header),
    );
    try expectQueryRegistrations(io, &device, 1);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_query_pools);
    try device.wait(io, submitted.serial);
    try expectQueryRegistrations(io, &device, 0);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = false, .total = 0, .user = 0 },
        references(io, &set.header),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_query_pools);
    const waits_after_completion = probe.wait_calls.load(.acquire);
    try device.wait(io, submitted.serial);
    try expectQueryRegistrations(io, &device, 0);
    try std.testing.expectEqual(waits_after_completion, probe.wait_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_query_pools);
    try std.testing.expectEqual(
        ReferenceSnapshot{ .alive = false, .total = 0, .user = 0 },
        references(io, &set.header),
    );
    try device.destroy(allocator, io);
    try probe.expectCommandTeardown();
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_query_pools);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

const ContenderIo = struct {
    base: std.Io,
    probe: *SafetyProbe,
    vtable: std.Io.VTable,
    cancel_wait: bool = false,

    fn init(self: *ContenderIo, base: std.Io, probe: *SafetyProbe) std.Io {
        self.* = .{ .base = base, .probe = probe, .vtable = base.vtable.* };
        self.vtable.futexWait = wait;
        self.vtable.futexWaitUncancelable = waitUncancelable;
        self.vtable.futexWake = wake;
        return .{ .userdata = self, .vtable = &self.vtable };
    }
    fn wait(
        context: ?*anyopaque,
        ptr: *const u32,
        expected: u32,
        timeout: std.Io.Timeout,
    ) std.Io.Cancelable!void {
        const self: *ContenderIo = @ptrCast(@alignCast(context.?));
        self.probe.contender_decided.set(self.base);
        if (self.cancel_wait) return error.Canceled;
        return self.base.vtable.futexWait(self.base.userdata, ptr, expected, timeout);
    }
    fn waitUncancelable(context: ?*anyopaque, ptr: *const u32, expected: u32) void {
        const self: *ContenderIo = @ptrCast(@alignCast(context.?));
        self.probe.contender_decided.set(self.base);
        self.base.vtable.futexWaitUncancelable(self.base.userdata, ptr, expected);
    }
    fn wake(context: ?*anyopaque, ptr: *const u32, count: u32) void {
        const self: *ContenderIo = @ptrCast(@alignCast(context.?));
        self.base.vtable.futexWake(self.base.userdata, ptr, count);
    }
};

const SafetyOperation = struct {
    device: *dusk.engine.Device,
    io: std.Io,
    serial: dusk.platform.Serial,
    submit: bool = false,
    result_error: ?SafetyOperationError = null,
    submitted: ?dusk.platform.Serial = null,

    fn run(self: *SafetyOperation) void {
        if (self.submit) {
            self.submitted = submitEmpty(self.io, self.device) catch |err| {
                self.result_error = err;
                return;
            };
        } else {
            self.device.wait(self.io, self.serial) catch |err| {
                self.result_error = err;
            };
        }
    }
};

fn concurrentRetirement(submit: bool) !void {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer {
        probe.overlap = false;
        probe.idle_result = vk.VK_SUCCESS;
        device.deinit(allocator, io) catch @panic("device teardown failed");
    }
    const serial = try submitEmpty(io, &device);
    probe.overlap = true;
    probe.idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    var first: SafetyOperation = .{ .device = &device, .io = io, .serial = serial };
    const first_thread = try std.Thread.spawn(.{}, SafetyOperation.run, .{&first});
    var first_joined = false;
    defer if (!first_joined) first_thread.join();
    defer probe.allow_first_status.set(io);
    probe.first_status_entered.waitUncancelable(io);
    // SAFETY: init writes the complete wrapper at this final stack address
    // before the second thread receives its Io; it stays live through join.
    var wrapped: ContenderIo = undefined;
    var second: SafetyOperation = .{
        .device = &device,
        .io = wrapped.init(io, &probe),
        .serial = serial,
        .submit = submit,
    };
    const second_thread = try std.Thread.spawn(.{}, SafetyOperation.run, .{&second});
    // No timing assumption: the contender either entered the unsafe native wait
    // or blocked on an Io mutex. Only then may the first retirement continue.
    probe.contender_decided.waitUncancelable(io);
    probe.allow_first_status.set(io);
    second_thread.join();
    first_thread.join();
    first_joined = true;
    try std.testing.expectEqual(@as(?SafetyOperationError, null), first.result_error);
    try std.testing.expectEqual(@as(?SafetyOperationError, null), second.result_error);
    try std.testing.expectEqual(@as(usize, 1), probe.wait_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.created_fences);
    if (submit) {
        try std.testing.expectEqual(@as(?dusk.platform.Serial, serial + 1), second.submitted);
        try std.testing.expectEqual(@as(usize, 1), probe.reset_fences);
        try std.testing.expectEqual(@as(u32, 1), device.native.?.queue.fences_in_flight_count);
        try std.testing.expectEqual(@as(u32, 0), device.native.?.queue.unused_fence_count);
    } else {
        try std.testing.expectEqual(@as(u32, 0), device.native.?.queue.fences_in_flight_count);
        try std.testing.expectEqual(@as(u32, 1), device.native.?.queue.unused_fence_count);
    }
}

test "native safety public waits serialize fence retirement" {
    try concurrentRetirement(false);
}

test "native safety implicit submit wait serializes fence reuse" {
    try concurrentRetirement(true);
}

test "native safety queue lease pins device and publishes direct low submissions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer device.deinit(allocator, io) catch @panic("device teardown failed");
    const layout = try device.createBindGroupLayout(allocator, io, .{ .entries = &.{} });
    // Cancel after admission but before the queue borrow. The error must undo
    // submitting and the operation pin, so a fresh real lease still succeeds.
    {
        const context = device.native.?;
        context.queue_operation_mutex.lockUncancelable(io);
        defer context.queue_operation_mutex.unlock(io);
        var cancel_io: ContenderIo = undefined;
        const wrapped_io = cancel_io.init(io, &probe);
        cancel_io.cancel_wait = true;
        try std.testing.expectError(error.Canceled, device.getQueue(wrapped_io));
    }
    var lease = try device.getQueue(io);
    defer lease.deinit(io);
    try std.testing.expectError(error.ResourceInUse, device.destroy(allocator, io));
    try std.testing.expectEqual(dusk.engine.device.State.alive, device.getState());
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_devices);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    const commands = [_]vk.VkCommandBuffer{lease.commandBuffer()};
    const before_mismatch = arenaSnapshot(io, &device);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.AllocatorMismatch,
        lease.submit(failing.allocator(), io, .{ .command_buffers = &commands }, &.{&layout.header}),
    );
    try std.testing.expectEqual(before_mismatch, arenaSnapshot(io, &device));
    try std.testing.expectEqual(@as(dusk.platform.Serial, 0), lease.lastSubmittedSerial());
    try std.testing.expectEqual(@as(usize, 0), probe.created_fences);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, null), device.pending_serial);
    const submitted = try lease.submit(allocator, io, .{ .command_buffers = &commands }, &.{&layout.header});
    try std.testing.expectEqual(submitted.serial, lease.lastSubmittedSerial());
    lease.deinit(io);
    lease.deinit(io);
    try std.testing.expectEqual(
        @as(?dusk.platform.Serial, submitted.serial),
        device.pending_serial,
    );
    try device.release(allocator, io, layout);
    try std.testing.expectEqual(@as(u32, 0), references(io, &layout.header).user);
    try std.testing.expectEqual(@as(u32, 1), references(io, &layout.header).total);
    try std.testing.expect(references(io, &layout.header).alive);
    try std.testing.expectError(error.NoOwnedReference, device.release(allocator, io, layout));
    probe.wait_result = vk.VK_TIMEOUT;
    probe.idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    try std.testing.expectError(error.FenceWaitTimedOut, device.wait(io, submitted.serial));
    try std.testing.expectEqual(@as(u32, 1), references(io, &layout.header).total);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_layouts);
    try std.testing.expectEqual(@as(?dusk.platform.Serial, submitted.serial), device.pending_serial);
    probe.wait_result = vk.VK_SUCCESS;
    probe.idle_result = vk.VK_SUCCESS;
    try device.wait(io, submitted.serial);
    try std.testing.expectEqual(@as(u32, 0), references(io, &layout.header).total);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_layouts);
    try device.destroy(allocator, io);
    try probe.expectCommandTeardown();
    try device.deinit(allocator, io);
    try std.testing.expectEqual(dusk.engine.device.State.destroyed, device.getState());
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_devices);
}

const FailedWaitScenario = struct {
    wait_result: vk.VkResult,
    idle_result: vk.VkResult,
    first_error: dusk.engine.device.CleanupError,
    public_wait: bool = false,
    lost: bool = true,
};

fn failedWaitRetirement(scenario: FailedWaitScenario) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer {
        probe.wait_result = vk.VK_SUCCESS;
        probe.idle_result = vk.VK_SUCCESS;
        device.deinit(allocator, io) catch |err| {
            if (err != error.DeviceLost) @panic("device teardown failed");
        };
    }
    const layout = try device.createBindGroupLayout(allocator, io, .{ .entries = &.{} });
    var lease = try device.getQueue(io);
    defer lease.deinit(io);
    const commands = [_]vk.VkCommandBuffer{lease.commandBuffer()};
    const submitted = try lease.submit(allocator, io, .{ .command_buffers = &commands }, &.{&layout.header});
    const serial = submitted.serial;
    lease.deinit(io);
    try device.release(allocator, io, layout);
    try std.testing.expectEqual(@as(u32, 0), references(io, &layout.header).user);
    try std.testing.expectEqual(@as(u32, 1), references(io, &layout.header).total);
    try device.native.?.deferred_framebuffers.append(allocator, @ptrCast(&probe));
    probe.wait_result = scenario.wait_result;
    probe.idle_result = scenario.idle_result;
    if (scenario.public_wait) {
        try std.testing.expectError(error.DeviceLost, device.wait(io, serial));
        try std.testing.expect(device.isLost());
        try std.testing.expectEqual(@as(?dusk.platform.Serial, serial), device.pending_serial);
        try std.testing.expectEqual(@as(usize, 0), probe.destroyed_devices);
        try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    }
    try std.testing.expectError(scenario.first_error, device.destroy(allocator, io));
    try std.testing.expectEqual(scenario.lost, device.isLost());
    try std.testing.expectEqual(dusk.engine.device.State.destroyed, device.getState());
    try std.testing.expect(probe.children_before_device);
    try probe.expectCommandTeardown();
    // Idle proof and terminal-safe lifetime retirement do not forge fence serials.
    try std.testing.expectEqual(@as(dusk.platform.Serial, 0), probe.completed_at_device_destroy);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_devices);
    try std.testing.expectEqual(@as(u32, 0), references(io, &layout.header).total);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_devices);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

test "native safety lost fence wait retires children without successful serial" {
    try failedWaitRetirement(.{
        .wait_result = vk.VK_ERROR_DEVICE_LOST,
        .idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY,
        .first_error = error.DeviceLost,
        .public_wait = true,
    });
}

test "native safety lost idle retires children and preserves first wait error" {
    try failedWaitRetirement(.{
        .wait_result = vk.VK_TIMEOUT,
        .idle_result = vk.VK_ERROR_DEVICE_LOST,
        .first_error = error.FenceWaitTimedOut,
    });
}

test "native safety successful idle preserves first wait error through cleanup" {
    try failedWaitRetirement(.{
        .wait_result = vk.VK_TIMEOUT,
        .idle_result = vk.VK_SUCCESS,
        .first_error = error.FenceWaitTimedOut,
        .lost = false,
    });
}

const ResourceOperation = struct {
    device: *dusk.engine.Device,
    io: std.Io,
    resource: ?*dusk.engine.native_resources.BindGroupLayout = null,
    result_error: ?dusk.engine.device.OperationError = null,

    fn run(self: *ResourceOperation) void {
        self.resource = self.device.createBindGroupLayout(
            std.testing.allocator,
            self.io,
            .{ .entries = &.{} },
        ) catch |err| {
            self.result_error = err;
            return;
        };
    }
};

test "native safety operation pins before blocking on native device mutex" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var list = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer list.deinit(io) catch @panic("list teardown failed");
    var user_context: u8 = 0;
    var device = try createSafetyDevice(allocator, io, &list.items[0], &user_context);
    var probe = SafetyProbe.initUnattached(io, &device);
    try probe.attach();
    defer device.deinit(allocator, io) catch @panic("device teardown failed");
    const context = device.native.?;
    context.device_mutex.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) context.device_mutex.mutex.unlock(io);
    var wrapped: ContenderIo = undefined;
    var operation: ResourceOperation = .{ .device = &device, .io = wrapped.init(io, &probe) };
    const thread = try std.Thread.spawn(.{}, ResourceOperation.run, .{&operation});
    var joined = false;
    // This defer unlocks before joining even if an assertion fails.
    defer {
        if (locked) {
            context.device_mutex.mutex.unlock(io);
            locked = false;
        }
        if (!joined) thread.join();
    }
    probe.contender_decided.waitUncancelable(io);
    try std.testing.expectError(error.ResourceInUse, device.destroy(allocator, io));
    try std.testing.expectError(error.ResourceInUse, device.deinit(allocator, io));
    try std.testing.expectEqual(dusk.engine.device.State.alive, device.getState());
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_devices);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    context.device_mutex.mutex.unlock(io);
    locked = false;
    thread.join();
    joined = true;
    try std.testing.expectEqual(
        @as(?dusk.engine.device.OperationError, null),
        operation.result_error,
    );
    const layout = operation.resource orelse return error.TestUnexpectedResult;
    try std.testing.expect(references(io, &layout.header).alive);
    try device.release(allocator, io, layout);
    try device.destroy(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed_devices);
    try probe.expectCommandTeardown();
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try device.deinit(allocator, io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}
