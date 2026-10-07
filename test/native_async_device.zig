//! Real null high owners exercise the root request, registry, and core scope paths.
//! Main owns all checks. These tests do not establish Vulkan execution.

const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_async_device;
const handles = engine.native_async_handles;
const root = engine.async_root_requests;
const registry = engine.async_registry;
const t = std.testing;
const gpa = t.allocator;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    source: registry.FutureNamespaceSource = .init(),
    instance: engine.Instance = undefined,
    list: ?engine.AdapterList = null,
    device_handle: ?api.Device = null,
    high: ?*engine.Device = null,
    request_status: ?api.RequestDeviceStatus = null,
    request_callback_pinned: bool = false,
    request_destroy_refused: bool = false,
    request_callback_count: usize = 0,
    loss_callback_count: usize = 0,
    loss_reason: ?api.DeviceLostReason = null,
    loss_device_present: bool = false,
    loss_callback_pinned: bool = false,
    loss_destroy_refused: bool = false,
    loss_message: [256]u8 = undefined,
    loss_message_len: usize = 0,
    uncaptured_callback_count: usize = 0,
    uncaptured_callback_pinned: bool = false,
    uncaptured_destroy_refused: bool = false,
    uncaptured_type: ?api.ErrorType = null,
    uncaptured_message: [256]u8 = undefined,
    uncaptured_message_len: usize = 0,
    uncaptured_reentered: bool = false,
    loss_mode: api.CallbackMode = .allow_process_events,
    loss_callback: bool = true,

    fn init(self: *Fixture, loss_mode: api.CallbackMode, loss_callback: bool) !void {
        self.* = .{ .loss_mode = loss_mode, .loss_callback = loss_callback };
        self.threaded = .init(gpa, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{
            .backend_type = .null_,
            .future_namespace_source = &self.source,
            .root_worker_count = 1,
        });
        errdefer self.instance.deinit(gpa, io) catch @panic("instance rollback failed");
        self.list = try self.instance.enumerateAdapters(gpa, io, .{
            .feature_level = .core,
            .power_preference = .undefined_,
            .backend_type = .null_,
        });
        errdefer self.list.?.deinit(io) catch @panic("adapter rollback failed");
        try t.expectEqual(@as(usize, 1), self.list.?.items.len);
        var descriptor: api.descriptors.DeviceDescriptorChain = .{
            .label = "async null device",
            .default_queue = .{ .label = "async null queue" },
            .device_lost_callback_info = .{
                .mode = loss_mode,
                .callback = if (loss_callback) lost else null,
                .userdata = self,
            },
            .uncaptured_error_callback_info = .{ .callback = uncaptured, .userdata = self },
        };
        const future = try root.requestDevice(
            handles.exportAdapter(&self.list.?.items[0]),
            gpa,
            io,
            &descriptor,
            .{ .mode = .wait_any_only, .callback = requested, .userdata = self },
        );
        var infos = [_]api.FutureWaitInfo{.{ .future = future }};
        try t.expectEqual(api.WaitStatus.success, try root.waitAny(
            handles.exportInstance(&self.instance),
            io,
            infos.len,
            &infos,
            10_000_000_000,
        ));
        try t.expect(infos[0].completed);
        try t.expectEqual(api.RequestDeviceStatus.success, self.request_status.?);
        try t.expect(self.high != null);
        try t.expect(self.device_handle != null);
        try self.waitRunners();
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        defer self.threaded.deinit();
        self.waitRunners() catch @panic("root runners failed to drain");
        if (self.device_handle) |handle| {
            const receipt = root.releaseDeviceResult(gpa, io, handle);
            if (!receipt.consumed or receipt.failure != null) {
                @panic("owned null device teardown failed");
            }
            self.device_handle = null;
            self.high = null;
        }
        if (self.list) |*list| {
            list.deinit(io) catch @panic("actual adapter list retained ownership");
            self.list = null;
        }
        self.instance.deinit(gpa, io) catch @panic("actual instance retained ownership");
    }

    fn waitRunners(self: *Fixture) !void {
        const io = self.threaded.io();
        for (0..10_000) |_| {
            self.instance.lifecycle_mutex.lockUncancelable(io);
            const remaining = self.instance.accepted_root_operations;
            self.instance.lifecycle_mutex.unlock(io);
            if (remaining == 0) return;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.RootRunnerDrainExhausted;
    }

    fn device(self: *Fixture) *engine.Device {
        return self.high.?;
    }

    fn completions(self: *Fixture) *registry.CompletionRegistry {
        return self.device().async_state.registry.?;
    }

    fn owned(self: *Fixture) *root.OwnedDevice {
        return self.device().root_record.ownership.device_result;
    }

    fn requested(
        userdata: ?*anyopaque,
        status: api.RequestDeviceStatus,
        device_handle: ?api.Device,
        message: []const u8,
    ) void {
        const self: *Fixture = @ptrCast(@alignCast(userdata.?));
        const io = self.threaded.io();
        self.request_callback_count += 1;
        self.request_status = status;
        if (status != .success or device_handle == null) return;
        std.debug.assert(message.len == 0);
        self.device_handle = device_handle;
        self.high = handles.resolveDevice(device_handle.?) catch @panic("invalid actual device");
        const device_owner = self.device();
        self.request_callback_pinned = device_owner.active_callbacks != 0 and
            device_owner.active_operations > device_owner.active_async_operations;
        const before = Snapshot.take(device_owner);
        device_owner.destroy(gpa, io) catch |err| {
            self.request_destroy_refused = err == error.ResourceInUse;
        };
        std.debug.assert(before.sameStorage(Snapshot.take(device_owner)));
    }

    fn lost(
        userdata: ?*anyopaque,
        device_array: ?[]const api.Device,
        reason: api.DeviceLostReason,
        message: []const u8,
    ) void {
        const self: *Fixture = @ptrCast(@alignCast(userdata.?));
        const io = self.threaded.io();
        self.loss_callback_count += 1;
        self.loss_reason = reason;
        self.loss_device_present = device_array != null;
        copyMessage(&self.loss_message, &self.loss_message_len, message);
        if (device_array) |devices| {
            std.debug.assert(devices.len == 1);
            const device_owner = handles.resolveDevice(devices[0]) catch
                @panic("loss did not borrow an actual high device");
            std.debug.assert(device_owner == self.high.?);
            self.loss_callback_pinned = device_owner.active_callbacks != 0 and
                device_owner.active_operations > device_owner.active_async_operations;
            const before = Snapshot.take(device_owner);
            device_owner.destroy(gpa, io) catch |err| {
                self.loss_destroy_refused = err == error.ResourceInUse;
            };
            std.debug.assert(before.equal(Snapshot.take(device_owner)));
        }
    }

    fn uncaptured(
        userdata: ?*anyopaque,
        device_array: ?[]const api.Device,
        error_type: api.ErrorType,
        message: []const u8,
    ) void {
        const self: *Fixture = @ptrCast(@alignCast(userdata.?));
        const io = self.threaded.io();
        self.uncaptured_callback_count += 1;
        self.uncaptured_type = error_type;
        std.debug.assert(device_array != null);
        std.debug.assert(device_array.?.len == 1);
        const device_owner = handles.resolveDevice(device_array.?[0]) catch
            @panic("uncaptured error did not borrow the actual high device");
        std.debug.assert(device_owner == self.high.?);
        self.uncaptured_callback_pinned = device_owner.active_callbacks != 0 and
            device_owner.active_operations > device_owner.active_async_operations;
        const before = Snapshot.take(device_owner);
        device_owner.destroy(gpa, io) catch |err| {
            self.uncaptured_destroy_refused = err == error.ResourceInUse;
        };
        std.debug.assert(before.equal(Snapshot.take(device_owner)));
        device_owner.pushErrorScope(gpa, io, .validation) catch @panic("scope reentry failed");
        var ticket = device_owner.popErrorScope(io) catch @panic("scope pop reentry failed");
        var guard = core.ObjectGuard.lockUncancelable(io, device_owner.core.arena.objectList());
        defer guard.unlock(io);
        defer ticket.deinit(&guard);
        var result = ticket.take(&guard) catch @panic("empty reentrant scope is not ready");
        defer result.deinit();
        std.debug.assert(result.error_ref == null);
        self.uncaptured_reentered = true;
        copyMessage(&self.uncaptured_message, &self.uncaptured_message_len, message);
    }
};

const Snapshot = struct {
    state: engine.DeviceState,
    native_context: ?*anyopaque,
    object_mutex: *std.Io.Mutex,
    active_operations: usize,
    active_async_operations: usize,
    active_callbacks: u32,
    destroying: bool,
    source_callbacks_open: bool,
    host_deinitialized: bool,
    native_payloads_retired: bool,
    adapter_count: u64,
    physical_count: u64,
    instance_count: u64,
    user_references: u64,

    fn take(device: *engine.Device) Snapshot {
        return .{
            .state = device.state,
            .native_context = if (device.native) |context| @ptrCast(context) else null,
            .object_mutex = device.core.arena.objectList().mutex,
            .active_operations = device.active_operations,
            .active_async_operations = device.active_async_operations,
            .active_callbacks = device.active_callbacks,
            .destroying = device.destroying,
            .source_callbacks_open = device.async_state.source_callbacks_open,
            .host_deinitialized = device.host_deinitialized,
            .native_payloads_retired = device.native_payloads_retired,
            .adapter_count = device.adapter.live_device_count,
            .physical_count = device.adapter.physical_device.live_device_count,
            .instance_count = device.adapter.getInstance().device_count,
            .user_references = device.core.arena.objectList().user_reference_count,
        };
    }

    fn equal(self: Snapshot, other: Snapshot) bool {
        return std.meta.eql(self, other);
    }

    fn sameStorage(self: Snapshot, other: Snapshot) bool {
        return self.state == other.state and self.native_context == other.native_context and
            self.object_mutex == other.object_mutex and
            self.destroying == other.destroying and
            self.source_callbacks_open == other.source_callbacks_open and
            self.host_deinitialized == other.host_deinitialized and
            self.native_payloads_retired == other.native_payloads_retired and
            self.adapter_count == other.adapter_count and
            self.physical_count == other.physical_count and
            self.instance_count == other.instance_count and
            self.user_references == other.user_references;
    }
};

fn copyMessage(buffer: []u8, length: *usize, message: []const u8) void {
    std.debug.assert(message.len <= buffer.len);
    @memcpy(buffer[0..message.len], message);
    length.* = message.len;
}

fn makeError(message: []const u8) !core.ErrorRef {
    var reservation = try core.ErrorReservation.prepare(gpa);
    defer reservation.discard();
    var draft = try core.ErrorDraft.initMessage(
        gpa,
        .{ .validation = error.EncoderAlreadyFinished },
        message,
        &.{},
    );
    defer draft.discard();
    return reservation.seal(&draft);
}

test "actual accepted request callback pins the final high owner and refuses destroy" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_process_events, true);
    defer fixture.deinit();
    try t.expectEqual(@as(usize, 1), fixture.request_callback_count);
    try t.expect(fixture.request_callback_pinned);
    try t.expect(fixture.request_destroy_refused);
    const device = fixture.device();
    try t.expect(&fixture.owned().high == device);
    try t.expect(fixture.owned().high_initialized);
    try t.expectEqualStrings("async null device", device.label);
    try t.expectEqualStrings("async null queue", device.default_queue_label);
    try t.expectEqual(@as(u32, 0), device.active_callbacks);
    try t.expectEqual(@as(usize, 1), device.active_async_operations);
    try t.expectEqual(device.active_async_operations, device.active_operations);
    try t.expectEqual(@as(u64, 1), device.adapter.live_device_count);
    try t.expectEqual(@as(u64, 1), device.adapter.physical_device.live_device_count);
    try t.expectEqual(device.async_state.lost_future.?.id, native.ownerBinding(device).identity);
    try t.expect(device.async_state.loss_cell != null);
    try t.expectEqual(@as(u32, 1), device.async_state.loss_cell.?.header.runners);
}

test "first loss owns immutable text and retains the same Future after removal" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_process_events, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = fixture.device();
    const future = try native.getLostFuture(device, io);
    try t.expectEqual(future.id, (try native.getLostFutureApi(fixture.device_handle.?, io)).id);
    var message = "temporary first loss".*;
    native.finishLoss(device, gpa, io, .unknown, &message);
    @memset(&message, 'x');
    native.finishLoss(device, gpa, io, .destroyed, "must not replace first loss");
    try t.expect(device.isLost());
    try t.expectEqual(api.DeviceLostReason.unknown, device.lost_reason.?);
    try t.expectEqual(@as(usize, 0), fixture.loss_callback_count);
    try fixture.completions().processEvents(io);
    try t.expectEqual(@as(usize, 1), fixture.loss_callback_count);
    try t.expectEqual(api.DeviceLostReason.unknown, fixture.loss_reason.?);
    try t.expectEqualStrings("temporary first loss", fixture.loss_message[0..fixture.loss_message_len]);
    try t.expect(fixture.loss_device_present);
    try t.expect(fixture.loss_callback_pinned);
    try t.expect(fixture.loss_destroy_refused);
    try t.expectEqual(future.id, (try native.getLostFuture(device, io)).id);
    try t.expectEqualStrings("temporary first loss", device.async_state.loss_error.?.view().message);
    try t.expect(device.async_state.loss_cell == null);
    try t.expectEqual(@as(usize, 0), device.active_async_operations);
    try t.expectEqual(@as(usize, 0), device.active_operations);
    try t.expectEqual(@as(u32, 0), device.active_callbacks);
    var infos = [_]api.FutureWaitInfo{ .{ .future = future }, .{ .future = future } };
    try t.expectEqual(api.WaitStatus.success, try fixture.completions().waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expect(infos[1].completed);
    native.finishLoss(device, gpa, io, .callback_cancelled, "late loss");
    try fixture.completions().processEvents(io);
    try t.expectEqual(@as(usize, 1), fixture.loss_callback_count);
}

test "a null loss callback still owns one accepted pending loss Future" {
    var fixture: Fixture = undefined;
    try fixture.init(.wait_any_only, false);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = fixture.device();
    const future = try native.getLostFuture(device, io);
    try t.expect(future.id != 0);
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    try t.expectEqual(api.WaitStatus.timed_out, try fixture.completions().waitAny(io, &infos, 0));
    try t.expect(!infos[0].completed);
    native.finishLoss(device, gpa, io, .destroyed, "null callback loss");
    try t.expectEqual(api.WaitStatus.success, try fixture.completions().waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expectEqual(@as(usize, 0), fixture.loss_callback_count);
    try t.expectEqual(future.id, (try native.getLostFuture(device, io)).id);
    try t.expectEqual(@as(usize, 0), device.active_async_operations);
}

test "owned scope routing invokes the real core ErrorView bridge with high callback pins" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_process_events, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = fixture.device();
    try device.pushErrorScope(gpa, io, .validation);
    try device.handleError(gpa, io, try makeError("captured owned error"));
    try t.expectEqual(@as(usize, 0), fixture.uncaptured_callback_count);
    var ticket = try device.popErrorScope(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        defer ticket.deinit(&guard);
        var result = try ticket.take(&guard);
        defer result.deinit();
        try t.expectEqualStrings("captured owned error", result.error_ref.?.view().message);
    }
    var message = "uncaptured owned text".*;
    const reference = try makeError(&message);
    @memset(&message, 'x');
    try device.handleError(gpa, io, reference);
    try t.expectEqual(@as(usize, 1), fixture.uncaptured_callback_count);
    try t.expectEqual(api.ErrorType.validation, fixture.uncaptured_type.?);
    try t.expect(fixture.uncaptured_callback_pinned);
    try t.expect(fixture.uncaptured_destroy_refused);
    try t.expect(fixture.uncaptured_reentered);
    try t.expectEqualStrings("uncaptured owned text", fixture.uncaptured_message[0..fixture.uncaptured_message_len]);
    try t.expectEqual(@as(u32, 0), device.active_callbacks);
    try t.expectEqual(device.active_async_operations, device.active_operations);
    try t.expect(native.takeDispatchError(device, io) == null);
}

const LogContext = struct {
    fixture: *Fixture,
    calls: usize = 0,
    pinned: bool = false,
    destroy_refused: bool = false,
    detach_refused: bool = false,
    reentered: bool = false,
    message_survived: bool = false,
    nested: ?*LogContext = null,
    gate: ?*LogGate = null,

    fn callback(userdata: ?*anyopaque, log_type: api.LoggingType, message: []const u8) void {
        const self: *LogContext = @ptrCast(@alignCast(userdata.?));
        const io = self.fixture.threaded.io();
        const device = self.fixture.device();
        self.calls += 1;
        std.debug.assert(log_type == .info);
        self.pinned = device.active_callbacks != 0 and
            device.active_operations > device.active_async_operations;
        const before = Snapshot.take(device);
        device.destroy(gpa, io) catch |err| {
            self.destroy_refused = err == error.ResourceInUse;
        };
        native.prepareHostDetach(device, io) catch |err| {
            self.detach_refused = err == error.ResourceInUse;
        };
        std.debug.assert(before.equal(Snapshot.take(device)));
        if (self.nested) |replacement| {
            native.setLoggingCallback(self.fixture.device_handle.?, io, .{
                .callback = callback,
                .userdata = replacement,
            }) catch @panic("logging replacement reentry failed");
            native.emitLog(device, io, .info, "nested log") catch
                @panic("nested logging failed");
            self.reentered = true;
        }
        if (self.gate) |gate| {
            gate.entered.set(io);
            gate.resume_event.waitUncancelable(io);
        }
        self.message_survived = std.mem.eql(u8, message, if (self.nested != null)
            "outer log"
        else if (self.gate != null) "claimed old log" else "nested log");
    }
};

const LogGate = struct {
    entered: std.Io.Event = .unset,
    resume_event: std.Io.Event = .unset,
};

const LogJob = struct {
    device: *engine.Device,

    fn run(call_io: std.Io, self: *LogJob) native.DispatchError!void {
        try native.emitLog(self.device, call_io, .info, "claimed old log");
    }
};

test "logging reentry uses the replacement record while the old dispatch remains pinned" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_process_events, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var inner: LogContext = .{ .fixture = &fixture };
    var outer: LogContext = .{ .fixture = &fixture, .nested = &inner };
    try native.setLoggingCallback(fixture.device_handle.?, io, .{
        .callback = LogContext.callback,
        .userdata = &outer,
    });
    try native.emitLog(fixture.device(), io, .info, "outer log");
    try t.expectEqual(@as(usize, 1), outer.calls);
    try t.expectEqual(@as(usize, 1), inner.calls);
    try t.expect(outer.pinned);
    try t.expect(inner.pinned);
    try t.expect(outer.destroy_refused);
    try t.expect(inner.destroy_refused);
    try t.expect(outer.detach_refused);
    try t.expect(inner.detach_refused);
    try t.expect(outer.reentered);
    try t.expect(outer.message_survived);
    try t.expect(inner.message_survived);
    try native.setLoggingCallback(fixture.device_handle.?, io, .{});
    try native.emitLog(fixture.device(), io, .info, "unregistered log");
    try t.expectEqual(@as(usize, 1), inner.calls);
    try t.expectEqual(@as(u32, 0), fixture.device().active_callbacks);
}

test "replacement is not old userdata quiescence and loss waits for the claimed log" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_spontaneous, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var gate: LogGate = .{};
    var context: LogContext = .{ .fixture = &fixture, .gate = &gate };
    try native.setLoggingCallback(fixture.device_handle.?, io, .{
        .callback = LogContext.callback,
        .userdata = &context,
    });
    var job: LogJob = .{ .device = fixture.device() };
    var worker = try io.concurrent(LogJob.run, .{ io, &job });
    var joined = false;
    defer if (!joined) {
        gate.resume_event.set(io);
        worker.await(io) catch @panic("claimed log failed during cleanup");
    };
    gate.entered.waitUncancelable(io);
    try native.setLoggingCallback(fixture.device_handle.?, io, .{});
    const device = fixture.device();
    try t.expectEqual(@as(u32, 1), device.active_callbacks);
    try t.expectEqual(@as(usize, 0), fixture.loss_callback_count);
    native.finishLoss(device, gpa, io, .unknown, "loss behind old log");
    try t.expectEqual(@as(usize, 0), fixture.loss_callback_count);
    const before = Snapshot.take(device);
    try t.expectError(error.ResourceInUse, native.prepareHostDetach(device, io));
    try t.expect(before.equal(Snapshot.take(device)));
    try t.expectError(error.ResourceInUse, device.deinit(gpa, io));
    try t.expect(before.equal(Snapshot.take(device)));
    {
        device.lifecycle_mutex.lockUncancelable(io);
        defer device.lifecycle_mutex.unlock(io);
        try t.expect(device.async_state.loss_cell == null);
        try t.expect(device.async_state.loss_pin_held);
        const completions = device.async_state.registry.?;
        const candidate = try completions.retainOwnerCandidate(
            io,
            device.async_state.owner_identity,
        ) orelse return error.AttachedLossCellMissing;
        defer completions.release(io, candidate, .candidate) catch
            @panic("loss inspection candidate release failed");
        try t.expect(registry.Cell(root.LossContext).matchesOperations(
            candidate,
            root.loss_operations,
        ));
        const loss: *registry.Cell(root.LossContext) = @fieldParentPtr("header", candidate);
        try t.expect(loss.context.device == device);
        try t.expect(loss.context.device_pin_held);
    }
    gate.resume_event.set(io);
    try worker.await(io);
    joined = true;
    try t.expect(context.message_survived);
    try t.expectEqual(@as(usize, 1), fixture.loss_callback_count);
    try t.expectEqual(@as(u32, 0), device.active_callbacks);
    try t.expectEqual(@as(usize, 0), device.active_operations);
    try t.expectEqualStrings("loss behind old log", fixture.loss_message[0..fixture.loss_message_len]);
}

test "detached wait-only loss survives final high host retirement without owner pointers" {
    var fixture: Fixture = undefined;
    try fixture.init(.wait_any_only, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = fixture.device();
    const future = try native.getLostFuture(device, io);
    const completions = fixture.completions();
    native.finishLoss(device, gpa, io, .destroyed, "detached destruction");
    try t.expectEqual(@as(usize, 0), fixture.loss_callback_count);
    try native.prepareHostDetach(device, io);
    try t.expectEqual(@as(usize, 0), device.active_async_operations);
    try t.expectEqual(@as(usize, 0), device.active_operations);
    try t.expect(device.async_state.loss_cell == null);
    try t.expectEqual(future.id, (try native.getLostFuture(device, io)).id);
    const receipt = root.releaseDeviceResult(gpa, io, fixture.device_handle.?);
    try t.expect(receipt.consumed);
    try t.expect(receipt.failure == null);
    fixture.device_handle = null;
    fixture.high = null;
    try t.expectEqual(@as(u64, 0), fixture.list.?.items[0].live_device_count);
    try t.expectEqual(@as(u64, 0), fixture.list.?.items[0].physical_device.live_device_count);
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    try t.expectEqual(api.WaitStatus.success, try completions.waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expectEqual(@as(usize, 1), fixture.loss_callback_count);
    try t.expect(!fixture.loss_device_present);
    try t.expectEqualStrings("detached destruction", fixture.loss_message[0..fixture.loss_message_len]);
}

test "ordinary operation pins are never reset by detach or teardown refusal" {
    var fixture: Fixture = undefined;
    try fixture.init(.wait_any_only, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = fixture.device();
    try device.acquireHostOperation(io);
    var operation_held = true;
    defer if (operation_held) device.releaseOperation(io);
    native.finishLoss(device, gpa, io, .unknown, "operation still held");
    const before = Snapshot.take(device);
    try t.expectError(error.ResourceInUse, device.destroy(gpa, io));
    try t.expect(before.equal(Snapshot.take(device)));
    try t.expectError(error.ResourceInUse, device.deinit(gpa, io));
    try t.expect(before.equal(Snapshot.take(device)));
    try native.prepareHostDetach(device, io);
    try t.expectEqual(@as(usize, 0), device.active_async_operations);
    try t.expectEqual(@as(usize, 1), device.active_operations);
    try t.expectError(error.ResourceInUse, device.deinit(gpa, io));
    try t.expectEqual(@as(usize, 1), device.active_operations);
    device.releaseOperation(io);
    operation_held = false;
    try t.expectEqual(@as(usize, 0), device.active_operations);
}

const ExternalClaims = struct {
    io: std.Io,
    completions: *registry.CompletionRegistry,
    frames: []registry.DispatchFrame,
    entered: usize = 0,

    fn init(self: *ExternalClaims, fixture: *Fixture) !void {
        const io = fixture.threaded.io();
        self.* = .{
            .io = io,
            .completions = fixture.completions(),
            .frames = try gpa.alloc(registry.DispatchFrame, registry.max_live_async_operations),
        };
        errdefer self.deinit();
        for (self.frames) |*frame| {
            frame.* = .{};
            try self.completions.enterExternalDispatch(
                io,
                frame,
                native.ownerBinding(fixture.device()),
                .logging,
            );
            self.entered += 1;
        }
    }

    fn deinit(self: *ExternalClaims) void {
        const io = self.io;
        for (0..self.entered) |index| {
            self.completions.leaveExternalDispatch(io, &self.frames[self.entered - index - 1]) catch
                @panic("external claim cleanup failed");
        }
        gpa.free(self.frames);
    }
};

test "void core bridge latches finite admission failures without dropping actual claims" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_process_events, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var claims: ExternalClaims = undefined;
    try claims.init(&fixture);
    defer claims.deinit();
    const device = fixture.device();
    const before = Snapshot.take(device);
    const reference = try makeError("capacity-bound owned error");
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    var delivery = device.core.handleError(&guard, reference) orelse
        return error.UncapturedDeliveryMissing;
    guard.unlock(io);
    delivery.dispatch(io);
    try t.expectEqual(@as(usize, 0), fixture.uncaptured_callback_count);
    try t.expect(before.equal(Snapshot.take(device)));
    try t.expectEqual(@as(?native.DispatchError, error.CallbackCapacityExceeded), native.takeDispatchError(device, io));
    try t.expect(native.takeDispatchError(device, io) == null);
    try t.expectError(error.CallbackCapacityExceeded, device.handleError(gpa, io, try makeError("high operation dispatch failure")));
    try t.expect(native.takeDispatchError(device, io) == null);
    try t.expectEqual(@as(usize, 0), fixture.uncaptured_callback_count);
    try t.expect(before.equal(Snapshot.take(device)));
    try t.expectError(error.ResourceInUse, device.destroy(gpa, io));
    try t.expect(before.equal(Snapshot.take(device)));
}

test "logging returns finite dispatch admission failure and leaves existing pins intact" {
    var fixture: Fixture = undefined;
    try fixture.init(.allow_process_events, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    var context: LogContext = .{ .fixture = &fixture };
    try native.setLoggingCallback(fixture.device_handle.?, io, .{
        .callback = LogContext.callback,
        .userdata = &context,
    });
    var claims: ExternalClaims = undefined;
    try claims.init(&fixture);
    defer claims.deinit();
    const before = Snapshot.take(fixture.device());
    try t.expectError(error.CallbackCapacityExceeded, native.emitLog(fixture.device(), io, .info, "cannot enter"));
    try t.expectEqual(@as(usize, 0), context.calls);
    try t.expect(before.equal(Snapshot.take(fixture.device())));
}

test "retirement preserves the host mutex parent counts and the reserved lost Future" {
    var fixture: Fixture = undefined;
    try fixture.init(.wait_any_only, true);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = fixture.device();
    const future = try native.getLostFuture(device, io);
    const original_mutex = device.core.arena.objectList().mutex;
    const original_adapter = device.adapter;
    const original_physical = device.adapter.physical_device;
    try device.destroy(gpa, io);
    try t.expect(!device.isLost());
    try t.expect(device.lost_reason == null);
    try t.expect(device.async_state.loss_won);
    try t.expect(!device.async_state.source_callbacks_open);
    try t.expectEqual(error.DeviceDestroyed, device.async_state.loss_error.?.view().code.device_lost);
    var hardware_message = "hardware loss after destruction".*;
    native.finishLoss(device, gpa, io, .unknown, &hardware_message);
    @memset(&hardware_message, 'x');
    try t.expect(device.isLost());
    try t.expectEqual(api.DeviceLostReason.unknown, device.lost_reason.?);
    try t.expectEqualStrings("hardware loss after destruction", device.lost_message);
    native.finishLoss(device, gpa, io, .unknown, "later hardware cause must not replace first");
    try t.expectEqualStrings("hardware loss after destruction", device.lost_message);
    try t.expectEqual(error.DeviceDestroyed, device.async_state.loss_error.?.view().code.device_lost);
    try t.expectEqualStrings("Device destroyed.", device.async_state.loss_error.?.view().message);
    try t.expect(device.native_payloads_retired);
    try t.expect(!device.host_deinitialized);
    try t.expectEqual(engine.DeviceState.destroyed, device.state);
    try t.expect(device.core.arena.objectList().mutex == original_mutex);
    try t.expect(device.adapter == original_adapter);
    try t.expect(device.adapter.physical_device == original_physical);
    try t.expectEqual(@as(u64, 1), original_adapter.live_device_count);
    try t.expectEqual(@as(u64, 1), original_physical.live_device_count);
    try t.expectEqual(@as(u64, 1), fixture.instance.queryDeviceCount(io));
    try t.expectEqual(future.id, (try native.getLostFuture(device, io)).id);
    try t.expectEqual(@as(usize, 0), fixture.loss_callback_count);
    const stopped = Snapshot.take(device);
    try device.destroy(gpa, io);
    try t.expect(stopped.equal(Snapshot.take(device)));
    try t.expectError(error.DeviceNotAlive, native.setLoggingCallback(fixture.device_handle.?, io, .{}));
    try t.expect(stopped.equal(Snapshot.take(device)));
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    try t.expectEqual(api.WaitStatus.success, try fixture.completions().waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expectEqual(@as(usize, 1), fixture.loss_callback_count);
    try t.expectEqual(api.DeviceLostReason.destroyed, fixture.loss_reason.?);
    try t.expectEqual(future.id, (try native.getLostFutureApi(fixture.device_handle.?, io)).id);
}

test "dispatch errors are the finite registry union exposed by high operations and cleanup" {
    const entry_fn = @typeInfo(@TypeOf(registry.CompletionRegistry.enterExternalDispatch)).@"fn";
    const entry_error = @typeInfo(entry_fn.return_type.?).error_union.error_set;
    const Expected = entry_error || api.ProcessEventsError;
    try t.expect(native.DispatchError == Expected);
    inline for (@typeInfo(native.DispatchError).error_set.?) |field| {
        const dispatch: native.DispatchError = @field(native.DispatchError, field.name);
        const operation: engine.device.OperationError = dispatch;
        const cleanup: engine.device.CleanupError = dispatch;
        try t.expectEqual(dispatch, operation);
        try t.expectEqual(dispatch, cleanup);
    }
}

const SynchronousErrors = struct {
    calls: usize = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    fn record(allocator: std.mem.Allocator, _: std.Io, context: *anyopaque, view: core.ErrorView) void {
        const self: *SynchronousErrors = @ptrCast(@alignCast(context));
        std.debug.assert(allocator.ptr == gpa.ptr);
        std.debug.assert(allocator.vtable == gpa.vtable);
        self.calls += 1;
        copyMessage(&self.message, &self.message_len, view.message);
    }
};

test "synchronous high creation stays real without authority and callback controls refuse unchanged" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(gpa, io) catch @panic("synchronous instance teardown failed");
    var list = try instance.enumerateAdapters(gpa, io, .{
        .feature_level = .core,
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    defer list.deinit(io) catch @panic("synchronous list teardown failed");
    var errors: SynchronousErrors = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(gpa, io, .{
        .adapter = &list.items[0],
        .feature_level = .core,
        .object_mutex = &object_mutex,
        .uncaptured_context = &errors,
        .uncaptured_callback = SynchronousErrors.record,
    });
    defer device.deinit(gpa, io) catch @panic("synchronous high teardown failed");
    const before = Snapshot.take(&device);
    try t.expectError(error.MissingFutureNamespaceSource, native.getLostFuture(&device, io));
    try t.expectError(error.MissingFutureNamespaceSource, native.getLostFutureApi(handles.exportDevice(&device), io));
    try t.expectError(error.MissingFutureNamespaceSource, native.setLoggingCallback(handles.exportDevice(&device), io, .{}));
    try t.expect(before.equal(Snapshot.take(&device)));
    try t.expect(device.async_state.registry == null);
    try t.expect(device.async_state.loss_cell == null);
    try t.expectEqual(@as(usize, 0), device.active_async_operations);
    try device.handleError(gpa, io, try makeError("real synchronous owned error"));
    try t.expectEqual(@as(usize, 1), errors.calls);
    try t.expectEqualStrings("real synchronous owned error", errors.message[0..errors.message_len]);
}

test "explicit synchronous registration reserves one real loss ID without replacing core delivery" {
    var fixture: Fixture = .{};
    fixture.threaded = .init(gpa, .{});
    defer fixture.threaded.deinit();
    const io = fixture.threaded.io();
    fixture.instance = engine.Instance.init(.{
        .backend_type = .null_,
        .future_namespace_source = &fixture.source,
    });
    defer fixture.instance.deinit(gpa, io) catch
        @panic("registered synchronous instance teardown failed");
    var list = try fixture.instance.enumerateAdapters(gpa, io, .{
        .feature_level = .core,
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    defer list.deinit(io) catch @panic("registered synchronous list teardown failed");
    var errors: SynchronousErrors = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(gpa, io, .{
        .adapter = &list.items[0],
        .feature_level = .core,
        .object_mutex = &object_mutex,
        .uncaptured_context = &errors,
        .uncaptured_callback = SynchronousErrors.record,
    });
    defer device.deinit(gpa, io) catch @panic("registered synchronous high teardown failed");
    fixture.high = &device;
    fixture.device_handle = handles.exportDevice(&device);
    const unregistered = Snapshot.take(&device);
    try t.expectError(error.DeviceNotAlive, native.getLostFuture(&device, io));
    try t.expectError(error.DeviceNotAlive, native.setLoggingCallback(fixture.device_handle.?, io, .{}));
    try t.expect(unregistered.equal(Snapshot.take(&device)));
    try t.expect(device.async_state.registry == null);
    try t.expect(device.async_state.loss_cell == null);
    const completions = try native.ensureRegistered(&device, gpa, io);
    const future = try native.getLostFuture(&device, io);
    try t.expect(future.id != 0);
    try t.expectEqual(future.id, (try native.getLostFutureApi(fixture.device_handle.?, io)).id);
    try t.expectEqual(@as(usize, 1), device.active_async_operations);
    try t.expectEqual(@as(usize, 1), device.active_operations);
    try t.expect(device.async_state.loss_cell != null);
    try t.expectEqual(@as(u32, 1), device.async_state.loss_cell.?.header.runners);
    try t.expect(completions == device.async_state.registry.?);
    const issued = completions.issued;
    const registered = Snapshot.take(&device);
    try t.expect(completions == try native.ensureRegistered(&device, gpa, io));
    try t.expectEqual(issued, completions.issued);
    try t.expectEqual(future.id, (try native.getLostFuture(&device, io)).id);
    try t.expect(registered.equal(Snapshot.take(&device)));
    var log_context: LogContext = .{ .fixture = &fixture };
    try native.setLoggingCallback(fixture.device_handle.?, io, .{
        .callback = LogContext.callback,
        .userdata = &log_context,
    });
    try native.emitLog(&device, io, .info, "nested log");
    try t.expectEqual(@as(usize, 1), log_context.calls);
    try t.expect(log_context.pinned);
    try t.expect(log_context.destroy_refused);
    try t.expect(log_context.detach_refused);
    try t.expect(log_context.message_survived);
    try t.expectEqual(@as(u32, 0), device.active_callbacks);
    try t.expectEqual(@as(usize, 1), device.active_operations);
    try device.handleError(gpa, io, try makeError("preserved synchronous core callback"));
    try t.expectEqual(@as(usize, 1), errors.calls);
    try t.expectEqualStrings("preserved synchronous core callback", errors.message[0..errors.message_len]);
    try t.expectEqual(@as(usize, 0), fixture.uncaptured_callback_count);
    try device.destroy(gpa, io);
    try t.expect(!device.host_deinitialized);
    try t.expect(device.native_payloads_retired);
    try t.expectEqual(future.id, (try native.getLostFuture(&device, io)).id);
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    try t.expectEqual(api.WaitStatus.success, try completions.waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try t.expectEqual(@as(u64, 1), list.items[0].physical_device.live_device_count);
    try t.expectEqual(@as(u64, 1), fixture.instance.queryDeviceCount(io));
    try device.deinit(gpa, io);
    try t.expect(device.host_deinitialized);
    try t.expectEqual(@as(usize, 0), device.active_async_operations);
    try t.expectEqual(@as(usize, 0), device.active_operations);
    try t.expectEqual(@as(u32, 0), device.active_callbacks);
    try t.expectEqual(@as(u64, 0), list.items[0].live_device_count);
    try t.expectEqual(@as(u64, 0), list.items[0].physical_device.live_device_count);
    try t.expectEqual(@as(u64, 0), fixture.instance.queryDeviceCount(io));
}
