const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const ops = engine.native_async_map_queue;
const gpa = std.testing.allocator;

const Fixture = struct {
    allocator: std.mem.Allocator = gpa,
    threaded: std.Io.Threaded = undefined,
    source: engine.async_registry.FutureNamespaceSource = .init(),
    instance: engine.Instance = undefined,
    adapters: engine.instance.AdapterList = undefined,
    device: engine.Device = undefined,
    errors: usize = 0,
    fn uncaptured(_: std.mem.Allocator, _: std.Io, context: *anyopaque, _: core.ErrorView) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.errors += 1;
    }
    fn init(self: *Fixture) !void {
        self.threaded = .init(self.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .future_namespace_source = &self.source, .root_worker_count = 1 });
        errdefer self.instance.deinit(self.allocator, io) catch unreachable;
        self.adapters = try self.instance.enumerateAdapters(self.allocator, io, .{ .backend_type = .vulkan, .feature_level = .core, .power_preference = .undefined_ });
        errdefer self.adapters.deinit(io) catch unreachable;
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(self.allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }
    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(self.allocator, io) catch |err| {
            if (err != error.DeviceLost or !self.device.host_deinitialized)
                @panic("device teardown refused");
        };
        self.adapters.deinit(io) catch @panic("adapter teardown refused");
        self.instance.deinit(self.allocator, io) catch @panic("instance teardown refused");
        self.threaded.deinit();
    }
    fn buffer(self: *Fixture) !*engine.native_resources.Buffer {
        return self.device.createBuffer(self.allocator, self.threaded.io(), .{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    }
};

fn expectMapSuccess(outcome: ops.NativeMapOutcome) !ops.NativeMapResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| blk: {
            failure.release();
            break :blk error.MapFailed;
        },
        else => error.MapDidNotComplete,
    };
}

const MapCallback = struct {
    calls: usize = 0,
    status: api.MapAsyncStatus = .success,
    thread: ?std.Thread.Id = null,
    device: *engine.Device,
    buffer: *engine.native_resources.Buffer,
    io: std.Io,
    fn run(context: ?*anyopaque, status: api.MapAsyncStatus, _: []const u8) void {
        const self: *MapCallback = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.status = status;
        self.thread = std.Thread.getCurrentId();
        if (status == .success) self.device.unmapBuffer(self.io, self.buffer) catch @panic("callback reentry failed");
    }
};

fn exportBuffer(fixture: *Fixture, buffer: *engine.native_resources.Buffer) api.Buffer {
    const io = fixture.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
    defer guard.unlock(io);
    return engine.native_async_handles.exportResource(api.Buffer, &fixture.device, &guard, buffer, .native_buffer);
}

test "real GPU write completes before native async read mapping and owned span survives destroy" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        gpa,
        fixture.device.core.borrow(),
        .{},
    );
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(gpa, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try buffer.ref(&guard), .data = &.{ 1, 9, 2, 8, 3, 7, 4, 6, 5, 0, 11, 22, 33, 44, 55, 66 } });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(gpa, io, &guard);
    }
    _ = try fixture.device.submit(gpa, io, &finished);
    var future = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = api.WholeMapSize });
    var result = try expectMapSuccess(future.await(io));
    defer result.deinit(io);
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 2, 8, 3, 7, 4, 6, 5, 0, 11, 22, 33, 44, 55, 66 }, result.bytes);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        buffer.header.retirePayloadLocked(&guard, io, .early_destroy);
    }
    try std.testing.expectEqual(@as(u8, 66), result.bytes[15]);
}

test "raw pending map unmap remap rejects stale completion and both map mode bits" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
    defer guard.unlock(io);
    try std.testing.expectError(error.BufferMapModeMismatch, buffer.native.beginMap(.{ .mode = .{ .read = true, .write = true } }));
    const first = try buffer.native.beginMap(.{ .mode = .{ .read = true } });
    try std.testing.expectEqual(engine.buffer.State.pending_map, buffer.native.state);
    try std.testing.expectError(error.BufferUseWhilePendingMap, buffer.native.validateCanUseOnQueueNow());
    _ = try buffer.native.unmap(.{ .command_buffer = null, .pending_serial = 0 });
    const second = try buffer.native.beginMap(.{ .mode = .{ .read = true } });
    try std.testing.expectEqual(engine.buffer.Buffer.MapCompletion.aborted, try buffer.native.completeMap(first, 0));
    try std.testing.expectEqual(engine.buffer.Buffer.MapCompletion.mapped, try buffer.native.completeMap(second, 0));
    try std.testing.expectEqual(engine.buffer.State.mapped, buffer.native.state);
}

test "generation overflow refuses unchanged before map acceptance" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
    defer guard.unlock(io);
    buffer.native.map_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.MapGenerationExhausted, buffer.native.beginMap(.{ .mode = .{ .read = true } }));
    try std.testing.expectEqual(engine.buffer.State.unmapped, buffer.native.state);
}

test "canonical grouped and flat map callbacks retain exact modes and allow unmap reentry" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    const handle = exportBuffer(&fixture, buffer);
    for ([_]api.CallbackMode{ .wait_any_only, .allow_process_events, .allow_spontaneous }) |mode| {
        var callback: MapCallback = .{ .device = &fixture.device, .buffer = buffer, .io = io };
        const future = try ops.mapAsyncProc(handle, gpa, io, .{ .read = true }, 0, api.WholeMapSize, .{ .mode = mode, .callback = MapCallback.run, .userdata = &callback });
        var checkpoint: WorkerGate = .{};
        try checkpoint.start(&fixture);
        defer checkpoint.releaseAndDrain(&fixture);
        if (mode == .allow_spontaneous) {
            try std.testing.expectEqual(@as(usize, 1), callback.calls);
            try std.testing.expect(callback.thread.? != std.Thread.getCurrentId());
        } else {
            try std.testing.expectEqual(@as(usize, 0), callback.calls);
            if (mode == .allow_process_events) try fixture.device.async_state.registry.?.processEvents(io);
        }
        var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
        _ = try fixture.device.async_state.registry.?.waitAny(io, &infos, std.math.maxInt(u64));
        try std.testing.expectEqual(@as(usize, 1), callback.calls);
        try std.testing.expectEqual(api.MapAsyncStatus.success, callback.status);
    }
}

test "queue observer empty completed and snapshot excludes later submit" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var empty = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    try std.testing.expectEqual(ops.NativeQueueOutcome.success, empty.await(io));
    var lease = try fixture.device.getQueue(io);
    const first = try lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{});
    lease.deinit(io);
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    var done = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    var later = try fixture.device.getQueue(io);
    const second = try later.submit(gpa, io, .{ .command_buffers = &.{later.commandBuffer()} }, &.{});
    later.deinit(io);
    try std.testing.expect(second.serial > first.serial);
    // A wrong latest-serial observation would exhaust native timeouts on the later fence.
    // The accepted target is already established by the real prior fence wait.
    var fault: FenceFault = undefined;
    fault.install(&fixture, ops.fence_observation_retry_bound);
    var restored = false;
    defer if (!restored) fault.restore(&fixture);
    gate.released.set(io);
    const outcome = done.await(io);
    if (outcome == .failure) {
        defer outcome.failure.release();
        std.debug.print("snapshot queue observation failed: {s}\n", .{outcome.failure.view().message});
    }
    try std.testing.expect(outcome == .success);
    fault.restore(&fixture);
    restored = true;
    try fixture.device.wait(io, second.serial);
    var completed = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    try std.testing.expectEqual(ops.NativeQueueOutcome.success, completed.await(io));
}

const WorkerGate = struct {
    entered: std.Io.Event = .unset,
    released: std.Io.Event = .unset,
    fn run(io: std.Io, context: *anyopaque) void {
        const self: *WorkerGate = @ptrCast(@alignCast(context));
        self.entered.set(io);
        self.released.waitUncancelable(io);
    }
    fn start(self: *WorkerGate, fixture: *Fixture) !void {
        const io = fixture.threaded.io();
        _ = try engine.native_async_device.ensureRegistered(&fixture.device, fixture.allocator, io);
        try engine.native_async_device.post(&fixture.device, io, .{ .run = run, .context = self });
        try self.entered.wait(io);
    }
    /// Release is not a join: the posted task borrows these events until return.
    /// Drain before a loop iteration can reuse their stack storage.
    fn releaseAndDrain(self: *WorkerGate, fixture: *Fixture) void {
        const io = fixture.threaded.io();
        self.released.set(io);
        dusk.platform.WorkerPool.waitForAllTasks(
            io,
            &fixture.instance.root_executor.?.pool,
            10 * std.time.ns_per_s,
        ) catch @panic("borrowed worker gate task did not drain");
    }
};

test "accepted map aborts on actual unmap and destruction and pending roots refuse submit" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    var pending = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
    {
        var lease = try fixture.device.getQueue(io);
        defer lease.deinit(io);
        try std.testing.expectError(error.BufferUseWhilePendingMap, lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{&buffer.header}));
    }
    try fixture.device.unmapBuffer(io, buffer);
    gate.released.set(io);
    try std.testing.expect(pending.await(io) == .aborted);
    var next_gate: WorkerGate = .{};
    try next_gate.start(&fixture);
    defer next_gate.released.set(io);
    var destroyed = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        buffer.header.retirePayloadLocked(&guard, io, .early_destroy);
    }
    next_gate.released.set(io);
    try std.testing.expect(destroyed.await(io) == .aborted);
}

test "native cancellation abandons observation without withdrawing accepted map execution" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    var pending = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
    try std.testing.expect(pending.cancel(io) == .canceled);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectEqual(engine.buffer.State.pending_map, buffer.native.state);
    }
    gate.released.set(io);
    var drain = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    try std.testing.expect(drain.await(io) == .success);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectEqual(engine.buffer.State.mapped, buffer.native.state);
    }
    try fixture.device.unmapBuffer(io, buffer);
}

test "actual scope captures accepted map validation before pending scope pop resolves" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try fixture.device.core.pushErrorScope(gpa, &guard, .validation);
    }
    var invalid = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true, .write = true }, .{ .offset = 0, .size = 16 });
    var ticket = blk: {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        var ticket = try fixture.device.core.popErrorScope(&guard);
        try std.testing.expectError(error.ScopePending, ticket.take(&guard));
        break :blk ticket;
    };
    gate.released.set(io);
    const outcome = invalid.await(io);
    try std.testing.expect(outcome == .failure);
    outcome.failure.release();
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        var result = try ticket.take(&guard);
        defer result.deinit();
        try std.testing.expectEqualStrings("BufferMapModeMismatch", result.error_ref.?.view().message);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.errors);
}

test "foreign buffer refuses before acceptance and leaves buffer usable by actual owner" {
    var first: Fixture = .{};
    try first.init();
    defer first.deinit();
    const io = first.threaded.io();
    const buffer = try first.buffer();
    defer first.device.release(gpa, io, buffer) catch unreachable;
    {
        var second: Fixture = .{};
        try second.init();
        defer second.deinit();
        try std.testing.expectError(error.InvalidOwner, ops.mapAsyncNative(&second.device, gpa, second.threaded.io(), buffer, .{ .read = true }, .{ .offset = 0, .size = 16 }));
    }
    // Two real Vulkan fixtures were needed for provenance rejection, not for
    // observing the first owner's map. Retire the foreign driver/thread pool
    // before reserving this observer under the test's fixed address-space cap.
    var accepted = try ops.mapAsyncNative(&first.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
    var result = try expectMapSuccess(accepted.await(io));
    result.deinit(io);
    try first.device.unmapBuffer(io, buffer);
}

test "allocation failure at each native admission allocation rolls back pending map and scopes" {
    var reached_success = false;
    for (0..32) |index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        var fixture: Fixture = .{ .allocator = failing.allocator() };
        try fixture.init();
        defer fixture.deinit();
        const io = fixture.threaded.io();
        const buffer = try fixture.buffer();
        defer fixture.device.release(fixture.allocator, io, buffer) catch unreachable;
        _ = try engine.native_async_device.ensureRegistered(&fixture.device, fixture.allocator, io);
        failing.fail_index = failing.alloc_index + index;
        const attempted = ops.mapAsyncNative(&fixture.device, fixture.allocator, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
        failing.fail_index = std.math.maxInt(usize);
        if (attempted) |started| {
            var future = started;
            var result = try expectMapSuccess(future.await(io));
            result.deinit(io);
            try fixture.device.unmapBuffer(io, buffer);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.ConcurrencyUnavailable);
            var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
            defer guard.unlock(io);
            try std.testing.expectEqual(engine.buffer.State.unmapped, buffer.native.state);
        }
    }
    try std.testing.expect(reached_success);
}

const vk = dusk.platform.vulkan_bindings;
// Tests inject only native error returns. Success always calls the real Vulkan fence wait.
const FenceFault = struct {
    var active: ?*FenceFault = null;
    device: vk.VkDevice,
    original: vk.PFN_vkWaitForFences,
    timeouts_remaining: u32,
    calls: u32 = 0,
    lose_after_real_wait: bool = false,
    fn wait(
        device: vk.VkDevice,
        count: u32,
        fences: [*c]const vk.VkFence,
        wait_all: vk.VkBool32,
        timeout_ns: u64,
    ) callconv(.c) vk.VkResult {
        const self = active.?;
        std.debug.assert(device == self.device);
        self.calls += 1;
        if (self.timeouts_remaining != 0) {
            self.timeouts_remaining -= 1;
            return vk.VK_TIMEOUT;
        }
        const result = self.original.?(device, count, fences, wait_all, timeout_ns);
        if (self.lose_after_real_wait and result == vk.VK_SUCCESS)
            return vk.VK_ERROR_DEVICE_LOST;
        return result;
    }
    fn install(self: *FenceFault, fixture: *Fixture, timeout_count: u32) void {
        const native = fixture.device.native.?;
        self.* = .{ .device = native.native_device.vk_device, .original = native.native_device.procs.wait_for_fences, .timeouts_remaining = timeout_count };
        std.debug.assert(active == null);
        active = self;
        native.native_device.procs.wait_for_fences = wait;
    }
    fn restore(self: *FenceFault, fixture: *Fixture) void {
        fixture.device.native.?.native_device.procs.wait_for_fences = self.original;
        active = null;
    }
};

test "native fence timeout retries then real fence completion succeeds" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    _ = try engine.native_async_device.ensureRegistered(&fixture.device, gpa, io);
    var lease = try fixture.device.getQueue(io);
    _ = try lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{});
    lease.deinit(io);
    var fault: FenceFault = undefined;
    fault.install(&fixture, 2);
    defer fault.restore(&fixture);
    var done = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    try std.testing.expect(done.await(io) == .success);
    try std.testing.expect(fault.calls >= 3);
}

test "timeout exhaustion is failure while GPU submitted roots remain queue owned until real wait" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    _ = try engine.native_async_device.ensureRegistered(&fixture.device, gpa, io);
    const buffer = try fixture.buffer();
    var lease = try fixture.device.getQueue(io);
    const submitted = try lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{&buffer.header});
    lease.deinit(io);
    try fixture.device.release(gpa, io, buffer);
    var fault: FenceFault = undefined;
    fault.install(&fixture, ops.fence_observation_retry_bound);
    var restored = false;
    defer if (!restored) fault.restore(&fixture);
    var done = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    const outcome = done.await(io);
    try std.testing.expect(outcome == .failure);
    defer outcome.failure.release();
    try std.testing.expectEqualStrings("FenceObservationExhausted", outcome.failure.view().message);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expect(buffer.header.isAlive(&guard));
    }
    try std.testing.expect(dusk.platform.Timeline.completedSerial(io, &fixture.device.native.?.queue.timeline) < submitted.serial);
    fault.restore(&fixture);
    restored = true;
    try fixture.device.wait(io, submitted.serial);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expect(!buffer.header.isAlive(&guard));
    }
}

test "administrative source closure cancels observation but does not retire submitted GPU roots" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    var lease = try fixture.device.getQueue(io);
    const submitted = try lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{&buffer.header});
    lease.deinit(io);
    try fixture.device.release(gpa, io, buffer);
    var done = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    fixture.device.lifecycle_mutex.lockUncancelable(io);
    fixture.device.async_state.source_callbacks_open = false;
    fixture.device.lifecycle_mutex.unlock(io);
    gate.released.set(io);
    try std.testing.expect(done.await(io) == .shut_down);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expect(buffer.header.isAlive(&guard));
    }
    try fixture.device.wait(io, submitted.serial);
}

test "native device loss takes first loss route and never reports queue success or completed serial" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    _ = try engine.native_async_device.ensureRegistered(&fixture.device, gpa, io);
    var lease = try fixture.device.getQueue(io);
    const submitted = try lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{});
    lease.deinit(io);
    var fault: FenceFault = undefined;
    fault.install(&fixture, 0);
    fault.lose_after_real_wait = true;
    defer fault.restore(&fixture);
    var done = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    const outcome = done.await(io);
    try std.testing.expect(outcome == .failure);
    defer outcome.failure.release();
    try std.testing.expectEqualStrings("DeviceLost", outcome.failure.view().message);
    try std.testing.expect(fixture.device.isLost());
    try std.testing.expectEqual(api.DeviceLostReason.unknown, fixture.device.lost_reason.?);
    try std.testing.expect(dusk.platform.Timeline.completedSerial(io, &fixture.device.native.?.queue.timeline) < submitted.serial);
}

test "queue observer cancellation preserves the actual submitted work" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.releaseAndDrain(&fixture);
    var lease = try fixture.device.getQueue(io);
    const submitted = try lease.submit(gpa, io, .{ .command_buffers = &.{lease.commandBuffer()} }, &.{});
    lease.deinit(io);
    var done = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    try std.testing.expect(done.cancel(io) == .canceled);
    gate.released.set(io);
    try fixture.device.wait(io, submitted.serial);
}

const HostCallback = struct {
    calls: usize = 0,
    status: api.MapAsyncStatus = .success,
    fn run(context: ?*anyopaque, status: api.MapAsyncStatus, _: []const u8) void {
        const self: *HostCallback = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.status = status;
    }
};

test "host-only delayed map callback does not hold execution pin through high device teardown" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    var callback: HostCallback = .{};
    const future = try ops.mapAsync(exportBuffer(&fixture, buffer), gpa, io, .{ .read = true }, .{ .offset = 0, .size = 16 }, .{ .mode = .wait_any_only, .callback = HostCallback.run, .userdata = &callback });
    // FIFO executor order proves map runner publication has returned without delivering its callback.
    var drain = try ops.onSubmittedWorkDoneNative(&fixture.device, gpa, io);
    try std.testing.expect(drain.await(io) == .success);
    var checkpoint: WorkerGate = .{};
    try checkpoint.start(&fixture);
    defer checkpoint.released.set(io);
    try std.testing.expectEqual(@as(usize, 0), callback.calls);
    try fixture.device.release(gpa, io, buffer);
    try fixture.device.destroy(gpa, io);
    try fixture.device.deinit(gpa, io);
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    _ = try fixture.instance.completions.?.waitAny(io, &infos, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 1), callback.calls);
    try std.testing.expectEqual(api.MapAsyncStatus.success, callback.status);
}

test "owned native mapping refuses high device destruction until explicit result deinit" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var future = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
    var result = try expectMapSuccess(future.await(io));
    defer result.deinit(io);
    try std.testing.expectError(error.ResourceInUse, fixture.device.destroy(gpa, io));
    try std.testing.expectEqual(@as(usize, 16), result.bytes.len);
    result.deinit(io);
    try fixture.device.unmapBuffer(io, buffer);
}

test "map alignment bounds usage and nonzero whole range preserve requested bytes" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectError(error.BufferMappedRangeNotAligned, buffer.native.beginMap(.{ .mode = .{ .read = true }, .offset = 4, .size = 4 }));
        try std.testing.expectError(error.BufferMappedRangeNotAligned, buffer.native.beginMap(.{ .mode = .{ .read = true }, .size = 2 }));
        try std.testing.expectError(error.BufferMapRangeOutsideBuffer, buffer.native.beginMap(.{ .mode = .{ .read = true }, .offset = 24, .size = 4 }));
        try std.testing.expectError(error.BufferMapModeMismatch, buffer.native.beginMap(.{ .mode = .{ .write = true } }));
        try std.testing.expectError(error.BufferMapModeMismatch, buffer.native.beginMap(.{ .mode = .{ .read = true, ._padding = 1 } }));
    }
    var future = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 8, .size = api.WholeMapSize });
    var result = try expectMapSuccess(future.await(io));
    defer result.deinit(io);
    try std.testing.expectEqual(@as(usize, 8), result.bytes.len);
    try std.testing.expect(result.writable_bytes == null);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectError(error.BufferMappedRangeOutsideBuffer, buffer.native.getConstMappedRange(24, engine.buffer.whole_map_size));
    }
}

test "native synchronous mapping composes pending map and actual GPU fence wait" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        gpa,
        fixture.device.core.borrow(),
        .{},
    );
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(gpa, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try buffer.ref(&guard), .data = &.{ 3, 1, 4, 1, 5, 9, 2, 6 } });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(gpa, io, &guard);
    }
    _ = try fixture.device.submit(gpa, io, &finished);
    try fixture.device.acquireOperation(io);
    {
        defer fixture.device.releaseOperation(io);
        try fixture.device.native.?.mapBuffer(io, buffer, .{ .mode = .{ .read = true } });
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectEqualSlices(u8, &.{ 3, 1, 4, 1, 5, 9, 2, 6 }, try buffer.native.getConstMappedRange(0, 8));
    }
    try fixture.device.unmapBuffer(io, buffer);
}

test "administrative map cancellation is callback cancelled not buffer aborted" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    var callback: HostCallback = .{};
    const future = try ops.mapAsync(exportBuffer(&fixture, buffer), gpa, io, .{ .read = true }, .{ .offset = 0, .size = 16 }, .{ .mode = .wait_any_only, .callback = HostCallback.run, .userdata = &callback });
    fixture.device.lifecycle_mutex.lockUncancelable(io);
    fixture.device.async_state.source_callbacks_open = false;
    fixture.device.lifecycle_mutex.unlock(io);
    gate.released.set(io);
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    _ = try fixture.device.async_state.registry.?.waitAny(io, &infos, std.math.maxInt(u64));
    try std.testing.expectEqual(api.MapAsyncStatus.callback_cancelled, callback.status);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectEqual(engine.buffer.State.unmapped, buffer.native.state);
    }
}

const QueueCallback = struct {
    device: *engine.Device,
    io: std.Io,
    calls: usize = 0,
    status: api.QueueWorkDoneStatus = .success,
    fn run(context: ?*anyopaque, status: api.QueueWorkDoneStatus, _: []const u8) void {
        const self: *QueueCallback = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.status = status;
        var lease = self.device.getQueue(self.io) catch @panic("queue callback reentry failed");
        lease.deinit(self.io);
    }
};

test "canonical queue completion callbacks obey deferred process and spontaneous modes with reentry" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const handle = engine.native_async_handles.exportQueue(&fixture.device);
    for ([_]api.CallbackMode{ .wait_any_only, .allow_process_events, .allow_spontaneous }) |mode| {
        var callback: QueueCallback = .{ .device = &fixture.device, .io = io };
        const future = try ops.onSubmittedWorkDone(handle, gpa, io, .{ .mode = mode, .callback = QueueCallback.run, .userdata = &callback });
        var checkpoint: WorkerGate = .{};
        try checkpoint.start(&fixture);
        defer checkpoint.releaseAndDrain(&fixture);
        try std.testing.expectEqual(@as(usize, if (mode == .allow_spontaneous) 1 else 0), callback.calls);
        if (mode == .allow_process_events) try fixture.device.async_state.registry.?.processEvents(io);
        var infos = [_]api.FutureWaitInfo{.{ .future = future }};
        _ = try fixture.device.async_state.registry.?.waitAny(io, &infos, std.math.maxInt(u64));
        try std.testing.expectEqual(@as(usize, 1), callback.calls);
        try std.testing.expectEqual(api.QueueWorkDoneStatus.success, callback.status);
    }
}

const PostedWork = struct {
    completed: std.atomic.Value(usize) = .init(0),
    fn run(_: std.Io, context: *anyopaque) void {
        const self: *PostedWork = @ptrCast(@alignCast(context));
        _ = self.completed.fetchAdd(1, .monotonic);
    }
};

test "real full executor post failure joins prepaid observer and rolls back map and scope admission" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var gate: WorkerGate = .{};
    try gate.start(&fixture);
    defer gate.released.set(io);
    var work: PostedWork = .{};
    for (0..dusk.platform.WorkerPool.max_queued_task_count) |_| {
        try engine.native_async_device.post(&fixture.device, io, .{ .run = PostedWork.run, .context = &work });
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try fixture.device.core.pushErrorScope(gpa, &guard, .validation);
    }
    try std.testing.expectError(error.TaskQueueFull, ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 }));
    try std.testing.expectError(error.TaskQueueFull, ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true, .write = true }, .{ .offset = 0, .size = 16 }));
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try std.testing.expectEqual(engine.buffer.State.unmapped, buffer.native.state);
        var ticket = try fixture.device.core.popErrorScope(&guard);
        var result = try ticket.take(&guard);
        defer result.deinit();
        try std.testing.expect(result.error_ref == null);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.errors);
    gate.released.set(io);
    try dusk.platform.WorkerPool.waitForAllTasks(io, &fixture.instance.root_executor.?.pool, 10 * std.time.ns_per_s);
    try std.testing.expectEqual(dusk.platform.WorkerPool.max_queued_task_count, work.completed.load(.acquire));
}

test "high native sampled texture arrays reject finitely instead of incomplete descriptor writes" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try std.testing.expectError(error.BindingLayoutUnsupported, fixture.device.createBindGroupLayout(gpa, fixture.threaded.io(), .{ .entries = &.{.{
        .binding_number = 7,
        .visibility = .{ .fragment = true },
        .array_size = 2,
        .kind = .{ .sampled_texture = .{ .sample_type = .float_filterable, .view_dimension = .two_d, .multisampled = false } },
    }} }));
}

const SubmitFault = struct {
    var calls: usize = 0;
    fn reject(_: vk.VkQueue, _: u32, _: [*c]const vk.VkSubmitInfo, _: vk.VkFence) callconv(.c) vk.VkResult {
        calls += 1;
        return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    }
};

test "failed native submission recording marks do not block async or synchronous mapping" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const buffer = try fixture.buffer();
    defer fixture.device.release(gpa, io, buffer) catch unreachable;
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        gpa,
        fixture.device.core.borrow(),
        .{},
    );
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(gpa, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try buffer.ref(&guard), .data = &.{ 4, 3, 2, 1 } });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(gpa, io, &guard);
    }
    const native = fixture.device.native.?;
    const original = native.native_device.procs.queue_submit;
    SubmitFault.calls = 0;
    native.native_device.procs.queue_submit = SubmitFault.reject;
    if (fixture.device.submit(gpa, io, &finished)) |_| {
        native.native_device.procs.queue_submit = original;
        return error.InjectedSubmitUnexpectedlySucceeded;
    } else |_| {}
    native.native_device.procs.queue_submit = original;
    try std.testing.expectEqual(@as(usize, 1), SubmitFault.calls);
    var future = try ops.mapAsyncNative(&fixture.device, gpa, io, buffer, .{ .read = true }, .{ .offset = 0, .size = 16 });
    var result = try expectMapSuccess(future.await(io));
    try std.testing.expectEqual(@as(usize, 16), result.bytes.len);
    result.deinit(io);
    try fixture.device.unmapBuffer(io, buffer);
    try fixture.device.acquireOperation(io);
    {
        defer fixture.device.releaseOperation(io);
        try native.mapBuffer(io, buffer, .{ .mode = .{ .read = true } });
    }
    try fixture.device.unmapBuffer(io, buffer);
}
