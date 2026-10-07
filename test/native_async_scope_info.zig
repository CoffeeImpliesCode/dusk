const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const operators = engine.native_async_scope_info;
const handles = engine.native_async_handles;
const root = engine.async_root_requests;
const t = std.testing;
const gpa = t.allocator;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    source: engine.async_registry.FutureNamespaceSource = .init(),
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    mutex: std.Io.Mutex = .init,
    device: engine.Device = undefined,
    uncaptured: usize = 0,
    allocator: std.mem.Allocator = gpa,

    fn init(self: *Fixture, authority: bool) !void {
        return self.initBackend(authority, .null_);
    }
    fn initBackend(self: *Fixture, authority: bool, backend: api.BackendType) !void {
        return self.initAllocated(authority, backend, gpa);
    }
    fn initAllocated(self: *Fixture, authority: bool, backend: api.BackendType, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        self.threaded = .init(gpa, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{
            .backend_type = backend,
            .future_namespace_source = if (authority) &self.source else null,
            .root_worker_count = 1,
        });
        errdefer self.instance.deinit(allocator, io) catch unreachable;
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .feature_level = .core,
            .power_preference = .undefined_,
            .backend_type = backend,
        });
        errdefer self.adapters.deinit(io) catch unreachable;
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = onUncaptured,
        });
    }
    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        if (if (self.device.host_deinitialized) null else self.device.async_state.registry) |completions| {
            var drained = false;
            for (0..10_000) |_| {
                completions.mutex.lockUncancelable(io);
                const live = completions.live_cells;
                completions.mutex.unlock(io);
                if (live == 1) {
                    drained = true;
                    break;
                }
                std.Io.sleep(io, .fromMilliseconds(1), .awake) catch @panic("scope/info drain canceled");
            }
            if (!drained) @panic("scope/info completion actors retained a cell");
        }
        self.device.deinit(self.allocator, io) catch @panic("scope/info device teardown failed");
        self.adapters.deinit(io) catch @panic("scope/info adapter teardown failed");
        self.instance.deinit(self.allocator, io) catch @panic("scope/info instance teardown failed");
        self.threaded.deinit();
    }
    fn onUncaptured(_: std.mem.Allocator, _: std.Io, context: *anyopaque, _: core.ErrorView) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.uncaptured += 1;
    }
    fn wait(self: *Fixture, future: api.Future) !void {
        var infos = [_]api.FutureWaitInfo{.{ .future = future }};
        try t.expectEqual(api.WaitStatus.success, try root.waitAny(
            handles.exportInstance(&self.instance),
            self.threaded.io(),
            1,
            &infos,
            10_000_000_000,
        ));
        try t.expect(infos[0].completed);
    }
    fn waitExecution(self: *Fixture, future: api.Future) !void {
        const io = self.threaded.io();
        const completions = self.device.async_state.registry.?;
        for (0..10_000) |_| {
            completions.mutex.lockUncancelable(io);
            const header = completions.index.get(@truncate(future.id));
            const ready = if (header) |h| h.execution == .terminal and h.runners == 0 and h.candidates == 0 else true;
            completions.mutex.unlock(io);
            if (ready) return;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.ScopeInfoExecutionDrainExhausted;
    }
};

const PopLog = struct {
    fixture: *Fixture,
    calls: usize = 0,
    status: ?api.PopErrorScopeStatus = null,
    type_: ?api.ErrorType = null,
    message: [128]u8 = undefined,
    len: usize = 0,
    reenter: bool = false,
    destroy_refused: bool = false,
    future: ?api.Future = null,
    selfwait_refused: bool = false,
    fn callback(userdata: ?*anyopaque, status: api.PopErrorScopeStatus, type_: api.ErrorType, message: []const u8) void {
        const self: *PopLog = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.status = status;
        self.type_ = type_;
        self.len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.len], message[0..self.len]);
        const io = self.fixture.threaded.io();
        self.fixture.device.destroy(gpa, io) catch |err| {
            self.destroy_refused = err == error.ResourceInUse;
        };
        if (self.future) |future| {
            var infos = [_]api.FutureWaitInfo{.{ .future = future }};
            if (root.waitAny(handles.exportInstance(&self.fixture.instance), io, 1, &infos, 0)) |_| {} else |err| {
                self.selfwait_refused = err == error.ReentrantWait;
            }
        }
        if (self.reenter) self.fixture.device.pushErrorScope(gpa, io, .validation) catch @panic("callback reentry failed");
    }
};

fn settle(fixture: *Fixture, lease: *core.ScopeLeaseSet, ref: ?core.ErrorRef) !void {
    const io = fixture.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    var settlement = try lease.settle(&guard, ref);
    guard.unlock(io);
    settlement.dispatch(io);
}

test "scope/info: nearest matching pop owns error and callbacks can reenter in all modes" {
    inline for (.{ api.CallbackMode.wait_any_only, api.CallbackMode.allow_process_events, api.CallbackMode.allow_spontaneous }) |mode| {
        var fixture: Fixture = .{};
        try fixture.init(true);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        try fixture.device.pushErrorScope(gpa, io, .validation);
        try fixture.device.pushErrorScope(gpa, io, .internal);
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        var lease = try fixture.device.core.captureScopeLeaseSet(gpa, &guard, .all);
        guard.unlock(io);
        var inner: PopLog = .{ .fixture = &fixture };
        var outer: PopLog = .{ .fixture = &fixture, .reenter = true };
        const first = try operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = mode, .callback = PopLog.callback, .userdata = &inner });
        const second = try operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = mode, .callback = PopLog.callback, .userdata = &outer });
        try t.expectEqual(@as(usize, 0), inner.calls);
        try t.expectEqual(@as(usize, 0), outer.calls);
        // The operation reservation prepays the one routing reference.
        var reservation = try core.ErrorReservation.prepare(gpa);
        try reservation.reserveReferences(lease.errorQuota());
        var draft = try core.ErrorDraft.initMessage(gpa, .{ .validation = error.StaleHandle }, "nearest validation scope", &.{});
        const ref = reservation.seal(&draft);
        try settle(&fixture, &lease, ref);
        ref.release();
        try fixture.wait(first);
        try fixture.wait(second);
        try t.expectEqual(@as(usize, 1), inner.calls);
        try t.expectEqual(@as(usize, 1), outer.calls);
        try t.expectEqual(api.ErrorType.no_error, inner.type_.?);
        try t.expectEqual(api.ErrorType.validation, outer.type_.?);
        try t.expectEqualStrings("nearest validation scope", outer.message[0..outer.len]);
        try t.expect(inner.destroy_refused and outer.destroy_refused);
        var reentered = try fixture.device.popErrorScope(io);
        guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        var result = try reentered.take(&guard);
        guard.unlock(io);
        result.deinit();
        try t.expectEqual(@as(usize, 0), fixture.uncaptured);
    }
}

test "scope/info: two pending operations keep popped scope pending until both settle" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    try fixture.device.pushErrorScope(gpa, io, .validation);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    var first = try fixture.device.core.captureScopeLeaseSet(gpa, &guard, .all);
    var second = try fixture.device.core.captureScopeLeaseSet(gpa, &guard, .all);
    guard.unlock(io);
    var log: PopLog = .{ .fixture = &fixture };
    const future = try operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = .allow_spontaneous, .callback = PopLog.callback, .userdata = &log });
    try settle(&fixture, &first, null);
    try t.expectEqual(@as(usize, 0), log.calls);
    try settle(&fixture, &second, null);
    try fixture.wait(future);
    try t.expectEqual(@as(usize, 1), log.calls);
    try t.expectEqual(api.PopErrorScopeStatus.success, log.status.?);
    try t.expectEqual(api.ErrorType.no_error, log.type_.?);
}

test "scope/info: empty stack is an accepted owned error, not a start error" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var future = try operators.popErrorScopeAsync(&fixture.device, gpa, io);
    var result = future.await(io);
    defer result.deinit();
    try t.expectEqual(api.PopErrorScopeStatus.error_, result.status);
    try t.expectEqual(api.ErrorType.no_error, result.errorType());
    try t.expect(result.error_ref != null);
    try t.expect(result.message().len != 0);
}

test "scope/info: cancelling native observation does not withdraw pending scope work" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    try fixture.device.pushErrorScope(gpa, io, .validation);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    var lease = try fixture.device.core.captureScopeLeaseSet(gpa, &guard, .all);
    guard.unlock(io);
    var future = try operators.popErrorScopeAsync(&fixture.device, gpa, io);
    var canceled = future.cancel(io);
    defer canceled.deinit();
    try t.expectEqual(api.PopErrorScopeStatus.callback_cancelled, canceled.status);
    try settle(&fixture, &lease, null);
}

test "scope/info: missing namespace refuses before removing a scope" {
    var fixture: Fixture = .{};
    try fixture.init(false);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    try fixture.device.pushErrorScope(gpa, io, .validation);
    try t.expectError(error.MissingFutureNamespaceSource, operators.popErrorScopeAsync(&fixture.device, gpa, io));
    var ticket = try fixture.device.popErrorScope(io);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    var result = try ticket.take(&guard);
    guard.unlock(io);
    result.deinit();
}

fn failedShader(fixture: *Fixture, text: []const u8) !*engine.native_resources.ShaderModule {
    const io = fixture.threaded.io();
    const allocator = fixture.allocator;
    try fixture.device.acquireOperation(io);
    defer fixture.device.releaseOperation(io);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    try fixture.device.bindObjectsLocked(&guard, allocator);
    const context = fixture.device.native orelse return error.NativeDeviceMissing;
    const module = try fixture.device.core.arena.create(allocator, &guard, engine.native_resources.ShaderModule, .{
        .kind = .shader_module,
        .state = .initializing,
        .initial_reference = .user,
    });
    errdefer module.header.discardUnpublishedLocked(&guard) catch unreachable;
    module.native = try dusk.pipeline.shader_module.createErrorShaderModule(allocator, .{ .message = text });
    module.device = context.shaderVk();
    module.words = &.{};
    module.owner_device = context.resourceDevice();
    module.allocator = allocator;
    module.cleanup_error = null;
    module.header.setInitializedError(&guard, error.StaleHandle);
    module.header.attach(&guard, io);
    return module;
}

fn shaderHandle(fixture: *Fixture, module: *engine.native_resources.ShaderModule) api.ShaderModule {
    const io = fixture.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    const handle = fixture.device.core.handleFor(&guard, engine.native_resources.ShaderModule, module, .shader_module);
    return .{ .handle = @ptrCast(handle.ptr) };
}

const InfoLog = struct {
    calls: usize = 0,
    count: usize = 0,
    text: [128]u8 = undefined,
    len: usize = 0,
    status: ?api.CompilationInfoRequestStatus = null,
    type_: ?api.CompilationMessageType = null,
    positions_zero: bool = false,
    nullable_empty: bool = false,
    fn callback(userdata: ?*anyopaque, status: api.CompilationInfoRequestStatus, info: *const api.descriptors.CompilationInfoChain) void {
        const self: *InfoLog = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.status = status;
        self.count = info.message_count;
        self.nullable_empty = info.message_count == 0 and info.messages == null;
        if (info.message_count == 0) return;
        const message = info.messages.?[0];
        self.len = @min(message.message.len, self.text.len);
        @memcpy(self.text[0..self.len], message.message[0..self.len]);
        self.type_ = message.type_;
        const utf16 = message.dawn_compilation_message_utf16.?;
        self.positions_zero = message.line_num == 0 and message.line_pos == 0 and message.offset == 0 and
            message.length == 0 and utf16.line_pos == 0 and utf16.offset == 0 and utf16.length == 0;
    }
};

test "scope/info: real failed shader diagnostics outlive source release and callback return" {
    inline for (.{ api.CallbackMode.wait_any_only, api.CallbackMode.allow_process_events, api.CallbackMode.allow_spontaneous }) |mode| {
        var fixture: Fixture = .{};
        try fixture.initBackend(true, .vulkan);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        const module = try failedShader(&fixture, "owned failed SPIR-V metadata");
        _ = try engine.native_async_device.ensureRegistered(&fixture.device, gpa, io);
        var blocker: WorkerBlock = .{};
        try engine.native_async_device.post(&fixture.device, io, .{ .context = &blocker, .run = WorkerBlock.run });
        blocker.waitEntered(io);
        defer blocker.unblock(io);
        var log: InfoLog = .{};
        const future = try operators.getCompilationInfo(shaderHandle(&fixture, module), gpa, io, .{ .mode = mode, .callback = InfoLog.callback, .userdata = &log });
        try fixture.device.release(gpa, io, module);
        blocker.unblock(io);
        try fixture.wait(future);
        try t.expectEqual(@as(usize, 1), log.calls);
        try t.expectEqual(api.CompilationInfoRequestStatus.success, log.status.?);
        try t.expectEqual(api.CompilationMessageType.error_, log.type_.?);
        try t.expectEqualStrings("owned failed SPIR-V metadata", log.text[0..log.len]);
        try t.expect(log.positions_zero);
    }
}

test "scope/info: native owned diagnostic survives source and cell destruction" {
    var fixture: Fixture = .{};
    try fixture.initBackend(true, .vulkan);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const module = try failedShader(&fixture, "native independently owned metadata");
    var future = try operators.getCompilationInfoAsync(&fixture.device, module, gpa, io);
    try fixture.device.release(gpa, io, module);
    var result = future.await(io);
    defer result.deinit();
    const view = result.success.view();
    try t.expectEqual(@as(usize, 1), view.message_count);
    try t.expectEqualStrings("native independently owned metadata", view.messages.?[0].message);
}

test "scope/info: real Vulkan shader clean diagnostics use null empty records in all modes" {
    inline for (.{ api.CallbackMode.wait_any_only, api.CallbackMode.allow_process_events, api.CallbackMode.allow_spontaneous }) |mode| {
        var fixture: Fixture = .{};
        try fixture.initBackend(true, .vulkan);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        const bytes = @embedFile("fixtures/triangle.vert.spv");
        const words = try gpa.alloc(u32, bytes.len / 4);
        defer gpa.free(words);
        for (words, 0..) |*word, index| word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        const module = try fixture.device.createShaderModule(gpa, io, .{ .words = words });
        defer fixture.device.release(gpa, io, module) catch unreachable;
        var log: InfoLog = .{};
        const future = try operators.getCompilationInfo(shaderHandle(&fixture, module), gpa, io, .{ .mode = mode, .callback = InfoLog.callback, .userdata = &log });
        try fixture.wait(future);
        try t.expectEqual(@as(usize, 1), log.calls);
        try t.expect(log.nullable_empty);
        try t.expectEqual(api.CompilationInfoRequestStatus.success, log.status.?);
    }
}

test "scope/info: null foreign and destroyed shader owners refuse without a future" {
    var fixture: Fixture = .{};
    try fixture.initBackend(true, .vulkan);
    defer fixture.deinit();
    var other: Fixture = .{};
    try other.initBackend(true, .vulkan);
    defer other.deinit();
    const io = fixture.threaded.io();
    var log: InfoLog = .{};
    try t.expectError(error.InvalidOwner, operators.getCompilationInfo(.{ .handle = null }, gpa, io, .{ .mode = .wait_any_only, .callback = InfoLog.callback, .userdata = &log }));
    const module = try failedShader(&fixture, "real failed metadata");
    defer fixture.device.release(gpa, io, module) catch unreachable;
    try t.expectError(error.InvalidOwner, operators.getCompilationInfoAsync(&other.device, module, gpa, io));
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    const handle = shaderHandleForGuard(&fixture, &guard, module);
    module.header.retirePayloadLocked(&guard, io, .early_destroy);
    guard.unlock(io);
    try t.expectError(error.InvalidOwner, operators.getCompilationInfo(handle, gpa, io, .{ .mode = .wait_any_only, .callback = InfoLog.callback, .userdata = &log }));
    try t.expectEqual(@as(usize, 0), log.calls);
}

fn shaderHandleForGuard(fixture: *Fixture, guard: *const core.ObjectGuard, module: *engine.native_resources.ShaderModule) api.ShaderModule {
    const handle = fixture.device.core.handleFor(guard, engine.native_resources.ShaderModule, module, .shader_module);
    return .{ .handle = @ptrCast(handle.ptr) };
}

test "scope/info: each preaccept allocation refusal leaves the innermost scope intact" {
    var reached_success = false;
    for (0..16) |nth| {
        var failing: std.testing.FailingAllocator = .init(gpa, .{});
        const allocator = failing.allocator();
        var fixture: Fixture = .{};
        try fixture.initAllocated(true, .null_, allocator);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        _ = try engine.native_async_device.ensureRegistered(&fixture.device, allocator, io);
        try fixture.device.pushErrorScope(allocator, io, .validation);
        failing.fail_index = failing.alloc_index + nth;
        const attempt = operators.popErrorScopeAsync(&fixture.device, allocator, io);
        failing.fail_index = std.math.maxInt(usize);
        if (attempt) |future_value| {
            var future = future_value;
            var result = future.await(io);
            defer result.deinit();
            try t.expectEqual(api.PopErrorScopeStatus.success, result.status);
            reached_success = true;
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            var ticket = try fixture.device.popErrorScope(io);
            var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
            var result = try ticket.take(&guard);
            guard.unlock(io);
            result.deinit();
        }
    }
    try t.expect(reached_success);
}

test "scope/info: snapshot allocation refusal is preaccept, with no callback-status fallback" {
    var reached_success = false;
    for (0..16) |nth| {
        var failing: std.testing.FailingAllocator = .init(gpa, .{});
        const allocator = failing.allocator();
        var fixture: Fixture = .{};
        try fixture.initAllocated(true, .vulkan, allocator);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        _ = try engine.native_async_device.ensureRegistered(&fixture.device, allocator, io);
        const module = try failedShader(&fixture, "snapshot fail-N diagnostic");
        defer fixture.device.release(allocator, io, module) catch unreachable;
        const issued = fixture.device.async_state.registry.?.issued;
        var log: InfoLog = .{};
        failing.fail_index = failing.alloc_index + nth;
        const attempt = operators.getCompilationInfo(shaderHandle(&fixture, module), allocator, io, .{ .mode = .wait_any_only, .callback = InfoLog.callback, .userdata = &log });
        failing.fail_index = std.math.maxInt(usize);
        if (attempt) |future| {
            try fixture.wait(future);
            try t.expectEqual(@as(usize, 1), log.calls);
            reached_success = true;
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(issued, fixture.device.async_state.registry.?.issued);
            try t.expectEqual(@as(usize, 0), log.calls);
        }
    }
    try t.expect(reached_success);
}

test "scope/info: full registry leaves pop stack unchanged and consumes no ID" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const completions = try engine.native_async_device.ensureRegistered(&fixture.device, gpa, io);
    try fixture.device.pushErrorScope(gpa, io, .validation);
    completions.options.max_live_operations = 1; // The actual accepted loss already owns this slot.
    const issued = completions.issued;
    var log: PopLog = .{ .fixture = &fixture };
    try t.expectError(error.AsyncCapacityExceeded, operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = .allow_spontaneous, .callback = PopLog.callback, .userdata = &log }));
    completions.options.max_live_operations = engine.async_registry.max_live_async_operations;
    try t.expectEqual(issued, completions.issued);
    try t.expectEqual(@as(usize, 0), log.calls);
    var ticket = try fixture.device.popErrorScope(io);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    var result = try ticket.take(&guard);
    guard.unlock(io);
    result.deinit();
}

const SettleTask = struct {
    fn run(fixture: *Fixture, lease: *core.ScopeLeaseSet) void {
        settle(fixture, lease, null) catch @panic("concurrent real scope settlement failed");
    }
};

test "scope/info: cancellation racing claimed scope notification keeps the real cell alive" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    for (0..32) |_| {
        try fixture.device.pushErrorScope(gpa, io, .validation);
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        var lease = try fixture.device.core.captureScopeLeaseSet(gpa, &guard, .all);
        guard.unlock(io);
        var future = try operators.popErrorScopeAsync(&fixture.device, gpa, io);
        var task = try io.concurrent(SettleTask.run, .{ &fixture, &lease });
        var result = future.cancel(io);
        result.deinit();
        task.await(io);
    }
}

const WorkerBlock = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    entered: bool = false,
    released: bool = false,
    fn run(io: std.Io, context: *anyopaque) void {
        const self: *WorkerBlock = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        self.entered = true;
        self.condition.broadcast(io);
        while (!self.released) self.condition.waitUncancelable(io, &self.mutex);
        self.mutex.unlock(io);
    }
    fn waitEntered(self: *WorkerBlock, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        while (!self.entered) self.condition.waitUncancelable(io, &self.mutex);
        self.mutex.unlock(io);
    }
    fn unblock(self: *WorkerBlock, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.released = true;
        self.condition.broadcast(io);
        self.mutex.unlock(io);
    }
};

test "scope/info: native compilation observer cancellation leaves queued work accepted" {
    var fixture: Fixture = .{};
    try fixture.initBackend(true, .vulkan);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    _ = try engine.native_async_device.ensureRegistered(&fixture.device, gpa, io);
    const module = try failedShader(&fixture, "cancelled observation retained work");
    defer fixture.device.release(gpa, io, module) catch unreachable;
    var blocker: WorkerBlock = .{};
    try engine.native_async_device.post(&fixture.device, io, .{ .context = &blocker, .run = WorkerBlock.run });
    blocker.waitEntered(io);
    defer blocker.unblock(io);
    var future = try operators.getCompilationInfoAsync(&fixture.device, module, gpa, io);
    var result = future.cancel(io);
    defer result.deinit();
    try t.expect(result == .canceled);
    blocker.unblock(io);
    for (0..10_000) |_| {
        fixture.device.lifecycle_mutex.lockUncancelable(io);
        const active = fixture.device.active_async_operations;
        fixture.device.lifecycle_mutex.unlock(io);
        if (active == 1) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.NativeInfoRunnerDrainExhausted;
}

test "scope/info: source-less compilation request refuses before copying diagnostics" {
    var fixture: Fixture = .{};
    try fixture.initBackend(false, .vulkan);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const module = try failedShader(&fixture, "no namespace diagnostic");
    defer fixture.device.release(gpa, io, module) catch unreachable;
    try t.expectError(error.MissingFutureNamespaceSource, operators.getCompilationInfoAsync(&fixture.device, module, gpa, io));
    try t.expect(fixture.device.async_state.registry == null);
}

test "scope/info: scope callbacks preserve wait-only process-events and spontaneous scheduling" {
    inline for (.{ api.CallbackMode.wait_any_only, api.CallbackMode.allow_process_events, api.CallbackMode.allow_spontaneous }) |mode| {
        var fixture: Fixture = .{};
        try fixture.init(true);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        try fixture.device.pushErrorScope(gpa, io, .validation);
        var log: PopLog = .{ .fixture = &fixture };
        const future = try operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = mode, .callback = PopLog.callback, .userdata = &log });
        try t.expectEqual(@as(usize, if (mode == .allow_spontaneous) 1 else 0), log.calls);
        try root.processEvents(handles.exportInstance(&fixture.instance), io);
        try t.expectEqual(@as(usize, if (mode == .wait_any_only) 0 else 1), log.calls);
        try fixture.wait(future);
        try t.expectEqual(@as(usize, 1), log.calls);
    }
}

const DetachedPopLog = struct {
    calls: usize = 0,
    status: ?api.PopErrorScopeStatus = null,
    type_: ?api.ErrorType = null,
    fn callback(userdata: ?*anyopaque, status: api.PopErrorScopeStatus, type_: api.ErrorType, _: []const u8) void {
        const self: *DetachedPopLog = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.status = status;
        self.type_ = type_;
    }
};

test "scope/info: ready scope callback survives actual typed high host detachment" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    try fixture.device.pushErrorScope(gpa, io, .validation);
    var log: DetachedPopLog = .{};
    const future = try operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = .wait_any_only, .callback = DetachedPopLog.callback, .userdata = &log });
    try t.expectEqual(@as(usize, 0), log.calls);
    try fixture.device.deinit(gpa, io);
    try t.expect(fixture.device.host_deinitialized);
    try fixture.wait(future);
    try t.expectEqual(@as(usize, 1), log.calls);
    try t.expectEqual(api.PopErrorScopeStatus.success, log.status.?);
    try t.expectEqual(api.ErrorType.no_error, log.type_.?);
}

test "scope/info: ready diagnostic graph survives shader and actual native high host detachment" {
    var fixture: Fixture = .{};
    try fixture.initBackend(true, .vulkan);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const module = try failedShader(&fixture, "host-detached owned diagnostic");
    var log: InfoLog = .{};
    const future = try operators.getCompilationInfo(shaderHandle(&fixture, module), gpa, io, .{ .mode = .wait_any_only, .callback = InfoLog.callback, .userdata = &log });
    try fixture.device.release(gpa, io, module);
    try fixture.waitExecution(future);
    try fixture.device.deinit(gpa, io);
    try t.expect(fixture.device.host_deinitialized);
    try fixture.wait(future);
    try t.expectEqual(@as(usize, 1), log.calls);
    try t.expectEqualStrings("host-detached owned diagnostic", log.text[0..log.len]);
}

test "scope/info: a scope callback's self-wait refuses without blocking its notification cleanup" {
    var fixture: Fixture = .{};
    try fixture.init(true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    try fixture.device.pushErrorScope(gpa, io, .validation);
    var log: PopLog = .{ .fixture = &fixture };
    const future = try operators.popErrorScope(handles.exportDevice(&fixture.device), gpa, io, .{ .mode = .wait_any_only, .callback = PopLog.callback, .userdata = &log });
    log.future = future;
    try fixture.wait(future);
    try t.expect(log.selfwait_refused);
    try t.expectEqual(@as(usize, 1), log.calls);
}

test "scope/info: native info fail-N leaves no accepted task or observation" {
    var reached_success = false;
    for (0..16) |nth| {
        var failing: std.testing.FailingAllocator = .init(gpa, .{});
        const allocator = failing.allocator();
        var fixture: Fixture = .{};
        try fixture.initAllocated(true, .vulkan, allocator);
        defer fixture.deinit();
        const io = fixture.threaded.io();
        _ = try engine.native_async_device.ensureRegistered(&fixture.device, allocator, io);
        const module = try failedShader(&fixture, "native snapshot fail-N");
        defer fixture.device.release(allocator, io, module) catch unreachable;
        const issued = fixture.device.async_state.registry.?.issued;
        failing.fail_index = failing.alloc_index + nth;
        const attempt = operators.getCompilationInfoAsync(&fixture.device, module, allocator, io);
        failing.fail_index = std.math.maxInt(usize);
        if (attempt) |future_value| {
            var future = future_value;
            var result = future.await(io);
            defer result.deinit();
            try t.expect(result == .success);
            reached_success = true;
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(issued, fixture.device.async_state.registry.?.issued);
        }
    }
    try t.expect(reached_success);
}
