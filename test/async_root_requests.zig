//! Root requests exercise the real high owners on null and Vulkan backends.
//! Each test owns its Io provider. No backend or procedure-table substitutes are used.
const std = @import("std");
const dusk = @import("dusk");
const t = std.testing;
const api = dusk.api;
const engine = dusk.engine;
const root = engine.async_root_requests;
const registry = engine.async_registry;
const handles = engine.native_async_handles;
const native_async = engine.native_async_device;
const Event = dusk.platform.CompletionEvent;
const timeout_ns = 5 * std.time.ns_per_s;
const poll_limit = 5000;
const allocation_limit = 512;

const AdapterCall = struct {
    calls: usize = 0,
    status: ?api.RequestAdapterStatus = null,
    handle: ?api.Adapter = null,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    fn callback(userdata: ?*anyopaque, status: api.RequestAdapterStatus, adapter: ?api.Adapter, message: []const u8) void {
        const self: *AdapterCall = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.status = status;
        self.handle = adapter;
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
    }

    fn info(self: *AdapterCall, mode: api.CallbackMode) api.RequestAdapterCallbackInfo {
        return .{ .mode = mode, .callback = callback, .userdata = self };
    }
};

const DeviceCall = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    calls: usize = 0,
    status: ?api.RequestDeviceStatus = null,
    handle: ?api.Device = null,
    message: [256]u8 = undefined,
    message_len: usize = 0,
    test_release: bool = false,
    release_receipt: ?root.RootReleaseResult = null,
    callback_pinned: bool = false,

    fn callback(userdata: ?*anyopaque, status: api.RequestDeviceStatus, device: ?api.Device, message: []const u8) void {
        const self: *DeviceCall = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.status = status;
        self.handle = device;
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
        if (device) |handle| {
            const high = handles.resolveDevice(handle) catch @panic("bad callback device");
            self.callback_pinned = high.active_callbacks != 0;
            if (self.test_release) {
                self.release_receipt = root.releaseDeviceResult(self.allocator, self.io, handle);
            }
        }
    }

    fn info(self: *DeviceCall, mode: api.CallbackMode) api.RequestDeviceCallbackInfo {
        return .{ .mode = mode, .callback = callback, .userdata = self };
    }
};

const LossCall = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    calls: usize = 0,
    reason: ?api.DeviceLostReason = null,
    device_count: usize = 0,
    handle: ?api.Device = null,
    callback_pinned: bool = false,
    destroy_refused: bool = false,
    message: [256]u8 = undefined,
    message_len: usize = 0,
    completed: Event = .{},

    fn callback(userdata: ?*anyopaque, devices: ?[]const api.Device, reason: api.DeviceLostReason, message: []const u8) void {
        const self: *LossCall = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.reason = reason;
        self.device_count = if (devices) |values| values.len else 0;
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
        if (devices) |values| {
            if (values.len == 1) {
                self.handle = values[0];
                const high = handles.resolveDevice(values[0]) catch @panic("bad loss device");
                self.callback_pinned = high.active_callbacks != 0;
                self.destroy_refused = if (high.destroy(self.allocator, self.io)) |_| false else |err| err == error.ResourceInUse;
            }
        }
        Event.signal(self.io, &self.completed);
    }

    fn info(self: *LossCall, mode: api.CallbackMode) api.DeviceLostCallbackInfo {
        return .{ .mode = mode, .callback = callback, .userdata = self };
    }
};

const ErrorCall = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    calls: usize = 0,
    handle: ?api.Device = null,
    callback_pinned: bool = false,
    destroy_refused: bool = false,

    fn callback(userdata: ?*anyopaque, devices: ?[]const api.Device, _: api.ErrorType, _: []const u8) void {
        const self: *ErrorCall = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        if (devices) |values| {
            if (values.len == 1) {
                self.handle = values[0];
                const high = handles.resolveDevice(values[0]) catch @panic("bad error device");
                self.callback_pinned = high.active_callbacks != 0;
                self.destroy_refused = if (high.destroy(self.allocator, self.io)) |_| false else |err| err == error.ResourceInUse;
            }
        }
    }
};

fn descriptor() api.descriptors.DeviceDescriptorChain {
    return .{
        .default_queue = .{ .label = null },
        .device_lost_callback_info = .{ .mode = .wait_any_only },
        .uncaptured_error_callback_info = .{},
    };
}

fn pause(io: std.Io) !void {
    try std.Io.sleep(io, .fromMilliseconds(1), .awake);
}

fn waitFuture(instance: *engine.Instance, io: std.Io, future: api.Future) !void {
    var infos = [_]api.FutureWaitInfo{.{ .future = future }};
    for (0..poll_limit) |_| {
        if (try root.waitAny(handles.exportInstance(instance), io, 1, &infos, 0) == .success) {
            try t.expect(infos[0].completed);
            return;
        }
        try pause(io);
    }
    return error.RootFutureTimeout;
}

fn drainRootPins(instance: *engine.Instance, io: std.Io) !void {
    for (0..poll_limit) |_| {
        instance.lifecycle_mutex.lockUncancelable(io);
        const remaining = instance.accepted_root_operations;
        instance.lifecycle_mutex.unlock(io);
        if (remaining == 0) return;
        try pause(io);
    }
    return error.RootRunnerTimeout;
}

fn takeNative(comptime T: type, io: std.Io, future: std.Io.Future(root.RootOutcome(T))) !root.RootOutcome(T) {
    const Job = struct {
        future: std.Io.Future(root.RootOutcome(T)),
        result: ?root.RootOutcome(T) = null,
        completed: Event = .{},
        fn run(call_io: std.Io, self: *@This()) void {
            self.result = self.future.await(call_io);
            Event.signal(call_io, &self.completed);
        }
    };
    var job: Job = .{ .future = future };
    var observer = try io.concurrent(Job.run, .{ io, &job });
    errdefer observer.cancel(io);
    try Event.waitTimeout(io, &job.completed, timeout_ns);
    observer.await(io);
    return job.result.?;
}

fn adapterSuccess(allocator: std.mem.Allocator, instance: *engine.Instance, io: std.Io) !*root.OwnedAdapterSelection {
    const result = try takeNative(*root.OwnedAdapterSelection, io, try instance.requestAdapterAsync(allocator, io, null));
    try drainRootPins(instance, io);
    return switch (result) {
        .success => |selection| selection,
        .failure => |failure| blk: {
            defer failure.release();
            std.debug.print("root adapter failure: {s}\n", .{failure.view().message});
            break :blk error.RealAdapterRequestFailed;
        },
        .unavailable => error.NoActualAdapters,
        .shut_down => error.UnexpectedRootShutdown,
        .canceled => error.UnexpectedRootCancellation,
    };
}

fn deviceSuccess(allocator: std.mem.Allocator, selection: *root.OwnedAdapterSelection, io: std.Io, input: ?*const api.descriptors.DeviceDescriptorChain) !*root.OwnedDevice {
    const result = try takeNative(*root.OwnedDevice, io, try selection.selected().requestDeviceAsync(allocator, io, input));
    try drainRootPins(selection.instance, io);
    return switch (result) {
        .success => |device| device,
        .failure => |failure| blk: {
            defer failure.release();
            std.debug.print("root device failure: {s}\n", .{failure.view().message});
            break :blk error.RealDeviceRequestFailed;
        },
        .unavailable => error.UnexpectedDeviceUnavailable,
        .shut_down => error.UnexpectedRootShutdown,
        .canceled => error.UnexpectedRootCancellation,
    };
}

fn releaseSelection(allocator: std.mem.Allocator, io: std.Io, selection: *root.OwnedAdapterSelection) void {
    const receipt = root.releaseAdapterResult(allocator, io, handles.exportAdapter(selection.selected()));
    if (!receipt.consumed or receipt.failure != null) @panic("selection cleanup failed");
}

fn releaseDevice(allocator: std.mem.Allocator, io: std.Io, owned: *root.OwnedDevice) void {
    const receipt = root.releaseDeviceResult(allocator, io, handles.exportDevice(&owned.high));
    if (!receipt.consumed or receipt.failure != null) @panic("device cleanup failed");
}

fn closeInstance(allocator: std.mem.Allocator, io: std.Io, instance: *engine.Instance) void {
    root.collectRootDisposals(instance, allocator, io) catch @panic("root collection failed");
    instance.deinit(allocator, io) catch @panic("instance cleanup failed");
}

test "root empty events and empty waits need no namespace or allocation" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer closeInstance(t.allocator, io, &instance);
    const handle = handles.exportInstance(&instance);
    const process: *const api.Instance.processEvents = root.processEvents;
    const wait: *const api.Instance.waitAny = root.waitAny;
    try process(handle, io);
    try t.expect(instance.completions == null);
    try t.expectEqual(api.WaitStatus.success, try wait(handle, io, 0, null, 1));
    var infos = [_]api.FutureWaitInfo{.{ .future = .{ .id = 1 } }};
    try t.expectError(error.FutureCountMismatch, root.waitAny(handle, io, 1, null, 0));
    try t.expectError(error.FutureCountMismatch, root.waitAny(handle, io, 0, &infos, 0));
    try t.expectError(error.MissingFutureNamespaceSource, root.waitAny(handle, io, 1, &infos, 0));
    var calls: AdapterCall = .{};
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.MissingFutureNamespaceSource, root.requestAdapter(handle, failing.allocator(), io, null, calls.info(.wait_any_only)));
    try t.expectError(error.MissingFutureNamespaceSource, instance.requestAdapterAsync(failing.allocator(), io, null));
    try t.expectEqual(@as(usize, 0), failing.alloc_index);
    try t.expectEqual(@as(usize, 0), calls.calls);
    try t.expect(instance.root_executor == null);
}

test "root unissued IDs do not create a registry and handles validate their kinds" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{
        .backend_type = .null_,
        .future_namespace_source = &source,
        .async_options = .{ .max_wait_count = 2 },
    });
    defer closeInstance(t.allocator, io, &instance);
    var infos = [_]api.FutureWaitInfo{.{ .future = .{ .id = 1 } }};
    try t.expectError(error.InvalidFutureId, root.waitAny(handles.exportInstance(&instance), io, 1, &infos, 0));
    try t.expect(instance.completions == null);
    var calls: AdapterCall = .{};
    try t.expectError(error.InvalidOwner, root.requestAdapter(.{}, t.allocator, io, null, calls.info(.wait_any_only)));
    var device_calls: DeviceCall = .{ .io = io, .allocator = t.allocator };
    const wrong: api.Adapter = .{ .handle = @ptrCast(&instance.root_record) };
    try t.expectError(error.InvalidOwner, root.requestDevice(wrong, t.allocator, io, null, device_calls.info(.wait_any_only)));
    const receipt = root.releaseAdapterResult(t.allocator, io, wrong);
    try t.expect(!receipt.consumed);
    try t.expectEqual(error.InvalidHandle, receipt.failure.?);
}

test "root adapter callback owns actual list rows and wait-only delivery is explicit" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    var call: AdapterCall = .{};
    var options: api.descriptors.RequestAdapterOptionsChain = .{
        .power_preference = .undefined_,
        .backend_type = .undefined_,
    };
    const start: *const api.Instance.requestAdapter = root.requestAdapter;
    const future = try start(handles.exportInstance(&instance), t.allocator, io, &options, call.info(.wait_any_only));
    options.backend_type = .metal;
    options.feature_level = .undefined_;
    try root.processEvents(handles.exportInstance(&instance), io);
    try t.expectEqual(@as(usize, 0), call.calls);
    try waitFuture(&instance, io, future);
    try drainRootPins(&instance, io);
    try t.expectEqual(api.RequestAdapterStatus.success, call.status.?);
    try t.expectEqual(@as(usize, 1), call.calls);
    try t.expectEqual(@as(usize, 0), call.message_len);
    const high = try handles.resolveAdapter(call.handle.?);
    const selection = high.root_record.ownership.adapter_result;
    defer releaseSelection(t.allocator, io, selection);
    try t.expect(selection.selected() == high);
    try t.expect(high.physical_device == &selection.list.?.physical_devices[0]);
    try t.expectEqual(@as(u64, 1), instance.list_count);
    try t.expectError(error.InstanceInUse, instance.deinit(t.allocator, io));
    try waitFuture(&instance, io, future);
    try t.expectEqual(@as(usize, 1), call.calls);
}

test "root adapter extensions and compatible surface fail after acceptance" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    for (0..4) |slot| {
        var options: api.descriptors.RequestAdapterOptionsChain = .{
            .power_preference = .undefined_,
            .backend_type = .undefined_,
        };
        var surface_token: u8 = 0;
        switch (slot) {
            0 => options.request_adapter_webxr_options = .{ .xr_compatible = false },
            1 => options.request_adapter_webgpu_backend_options = .{},
            2 => options.dawn_toggles_descriptor = .{},
            3 => options.compatible_surface = .{ .handle = &surface_token },
            else => unreachable,
        }
        var call: AdapterCall = .{};
        const future = try root.requestAdapter(handles.exportInstance(&instance), t.allocator, io, &options, call.info(.wait_any_only));
        options = .{ .power_preference = .undefined_, .backend_type = .null_ };
        try waitFuture(&instance, io, future);
        try drainRootPins(&instance, io);
        try t.expectEqual(api.RequestAdapterStatus.error_, call.status.?);
        try t.expect(call.handle == null);
        const expected = if (slot == 3) "UnsupportedCompatibleSurface" else "UnsupportedAdapterExtension";
        try t.expect(std.mem.indexOf(u8, call.message[0..call.message_len], expected) != null);
        try t.expectEqual(@as(u64, 0), instance.list_count);
    }
}

test "root required feature count and slice shapes reject before pair admission" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    var features = [_]api.FeatureName{.texture_formats_tier1};
    for (0..4) |shape| {
        var input = descriptor();
        switch (shape) {
            0 => input.required_feature_count = 1,
            1 => {
                input.required_feature_count = 0;
                input.required_features = &features;
            },
            2 => {
                input.required_feature_count = 2;
                input.required_features = &features;
            },
            3 => {
                input.required_feature_count = 1;
                input.required_features = &.{};
            },
            else => unreachable,
        }
        var call: DeviceCall = .{ .io = io, .allocator = t.allocator };
        const issued = instance.completions.?.issued;
        try t.expectError(error.InvalidRequest, root.requestDevice(handles.exportAdapter(selection.selected()), t.allocator, io, &input, call.info(.wait_any_only)));
        try t.expectEqual(issued, instance.completions.?.issued);
        try t.expectEqual(@as(usize, 0), call.calls);
        try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
        try t.expectEqual(@as(usize, 0), selection.selected().active_root_requests);
        try t.expect(!selection.selected().is_consumed);
    }
}

test "root descriptor owns labels features limits and callback records" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    var label = [_]u8{ 'd', 0, 'v' };
    var queue_label = [_]u8{ 'q', 0, 'u' };
    var features = [_]api.FeatureName{ .texture_formats_tier1, .texture_formats_tier1 };
    var limits: api.Limits = .{ .max_bind_groups = 2 };
    var loss: LossCall = .{ .io = io, .allocator = t.allocator };
    var errors: ErrorCall = .{ .io = io, .allocator = t.allocator };
    var input = descriptor();
    input.label = &label;
    input.default_queue.label = &queue_label;
    input.required_feature_count = features.len;
    input.required_features = &features;
    input.required_limits = &limits;
    input.device_lost_callback_info = loss.info(.wait_any_only);
    input.uncaptured_error_callback_info = .{ .callback = ErrorCall.callback, .userdata = &errors };
    var call: DeviceCall = .{ .io = io, .allocator = t.allocator, .test_release = true };
    instance.root_work_mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) instance.root_work_mutex.unlock(io);
    const start: *const api.Adapter.requestDevice = root.requestDevice;
    const future = try start(handles.exportAdapter(selection.selected()), t.allocator, io, &input, call.info(.wait_any_only));
    const pending_receipt = root.releaseAdapterResult(t.allocator, io, handles.exportAdapter(selection.selected()));
    try t.expect(!pending_receipt.consumed);
    try t.expectEqual(error.ResourceInUse, pending_receipt.failure.?);
    @memset(&label, 'x');
    @memset(&queue_label, 'x');
    features[0] = .depth_clip_control;
    features[1] = .depth_clip_control;
    limits.max_bind_groups = 0;
    input.device_lost_callback_info.userdata = null;
    input.uncaptured_error_callback_info.userdata = null;
    input.label = null;
    instance.root_work_mutex.unlock(io);
    locked = false;
    try waitFuture(&instance, io, future);
    try drainRootPins(&instance, io);
    try t.expectEqual(api.RequestDeviceStatus.success, call.status.?);
    try t.expect(call.callback_pinned);
    try t.expect(!call.release_receipt.?.consumed);
    try t.expectEqual(error.ResourceInUse, call.release_receipt.?.failure.?);
    const high = try handles.resolveDevice(call.handle.?);
    const owned = high.root_record.ownership.device_result;
    defer releaseDevice(t.allocator, io, owned);
    try t.expect(high == &owned.high);
    try t.expectEqualSlices(u8, &.{ 'd', 0, 'v' }, high.getLabel());
    try t.expectEqualSlices(u8, &.{ 'q', 0, 'u' }, high.default_queue_label);
    try t.expect(high.hasFeature(.texture_formats_tier1));
    try t.expectEqual(@as(u32, 2), owned.input.required_limits.?.max_bind_groups);
    try t.expectEqual(api.LimitU32Undefined, owned.input.required_limits.?.max_texture_dimension_1d);
    try t.expectEqual(@as(usize, 2), owned.input.required_features.len);
    try t.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u64, 1), selection.selected().live_device_count);
    const child_receipt = root.releaseAdapterResult(t.allocator, io, handles.exportAdapter(selection.selected()));
    try t.expect(!child_receipt.consumed);
    try t.expectEqual(error.ResourceInUse, child_receipt.failure.?);
    var reservation = try dusk.core.ErrorReservation.prepare(t.allocator);
    defer reservation.discard();
    var draft = try dusk.core.ErrorDraft.initMessage(t.allocator, .{ .validation = error.TextureFormatNotRenderable }, "actual uncaptured path", &.{});
    defer draft.discard();
    try high.handleError(t.allocator, io, reservation.seal(&draft));
    try t.expectEqual(@as(usize, 1), errors.calls);
    try t.expect(errors.callback_pinned);
    try t.expect(errors.destroy_refused);
    try t.expectEqual(call.handle.?.handle, errors.handle.?.handle);
    const lost_future = try native_async.getLostFuture(high, io);
    native_async.finishLoss(high, t.allocator, io, .unknown, "copied first loss");
    native_async.finishLoss(high, t.allocator, io, .destroyed, "must not replace first");
    try root.processEvents(handles.exportInstance(&instance), io);
    try t.expectEqual(@as(usize, 0), loss.calls);
    try waitFuture(&instance, io, lost_future);
    try t.expectEqual(@as(usize, 1), loss.calls);
    try t.expectEqual(api.DeviceLostReason.unknown, loss.reason.?);
    try t.expectEqual(@as(usize, 1), loss.device_count);
    try t.expect(loss.callback_pinned);
    try t.expect(loss.destroy_refused);
    try t.expectEqual(call.handle.?.handle, loss.handle.?.handle);
    try t.expectEqual(lost_future.id, (try native_async.getLostFuture(high, io)).id);
    try t.expectEqualStrings("copied first loss", loss.message[0..loss.message_len]);
}

test "root every unsupported device extension yields null failed creation loss" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    for (0..4) |slot| {
        var loss: LossCall = .{ .io = io, .allocator = t.allocator };
        var call: DeviceCall = .{ .io = io, .allocator = t.allocator };
        var input = descriptor();
        input.device_lost_callback_info = loss.info(.allow_process_events);
        switch (slot) {
            0 => input.dawn_toggles_descriptor = .{},
            1 => input.dawn_cache_device_descriptor = .{
                .isolation_key = "not retained",
                .dawn_load_cache_data_callback_info = .{},
                .dawn_store_cache_data_callback_info = .{},
            },
            2 => input.dawn_device_allocator_control = .{},
            3 => input.dawn_fake_device_initialize_error_for_testing = .{},
            else => unreachable,
        }
        const future = try root.requestDevice(handles.exportAdapter(selection.selected()), t.allocator, io, &input, call.info(.wait_any_only));
        input = descriptor();
        try waitFuture(&instance, io, future);
        try drainRootPins(&instance, io);
        try root.processEvents(handles.exportInstance(&instance), io);
        try t.expectEqual(api.RequestDeviceStatus.error_, call.status.?);
        try t.expect(call.handle == null);
        try t.expect(std.mem.indexOf(u8, call.message[0..call.message_len], "UnsupportedDeviceExtension") != null);
        try t.expectEqual(@as(usize, 1), loss.calls);
        try t.expectEqual(api.DeviceLostReason.failed_creation, loss.reason.?);
        try t.expectEqual(@as(usize, 0), loss.device_count);
        try t.expect(loss.message_len != 0);
        try t.expect(!selection.selected().is_consumed);
        try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    }
    const owned = try deviceSuccess(t.allocator, selection, io, null);
    releaseDevice(t.allocator, io, owned);
}

test "root device pair needs two slots and commits no sequence on refusal" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{
        .backend_type = .null_,
        .future_namespace_source = &source,
        .async_options = .{ .max_live_operations = 1 },
    });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    const issued = instance.completions.?.issued;
    var call: DeviceCall = .{ .io = io, .allocator = t.allocator };
    try t.expectError(error.AsyncCapacityExceeded, root.requestDevice(handles.exportAdapter(selection.selected()), t.allocator, io, null, call.info(.wait_any_only)));
    try t.expectEqual(issued, instance.completions.?.issued);
    try t.expectEqual(@as(usize, 0), call.calls);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u32, 0), instance.root_disposal_slots);
}

test "root copied consume policy shares the synchronous actual adapter latch" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    var input = descriptor();
    input.dawn_consume_adapter_descriptor = .{ .consume_adapter = false };
    const first = try deviceSuccess(t.allocator, selection, io, &input);
    defer releaseDevice(t.allocator, io, first);
    try t.expect(!selection.selected().is_consumed);
    var object_mutex: std.Io.Mutex = .init;
    var context: u8 = 0;
    var synchronous = try selection.selected().createDevice(t.allocator, io, .{
        .adapter = selection.selected(),
        .object_mutex = &object_mutex,
        .uncaptured_context = &context,
        .uncaptured_callback = syncError,
        .feature_level = selection.selected().feature_level,
        .consume_adapter = true,
    });
    defer synchronous.deinit(t.allocator, io) catch @panic("synchronous cleanup failed");
    try t.expect(selection.selected().is_consumed);
    try t.expectEqual(@as(u64, 2), instance.queryDeviceCount(io));
    const failed = try takeNative(*root.OwnedDevice, io, try selection.selected().requestDeviceAsync(t.allocator, io, &input));
    try drainRootPins(&instance, io);
    switch (failed) {
        .failure => |failure| {
            defer failure.release();
            try t.expect(std.mem.indexOf(u8, failure.view().message, "AdapterConsumed") != null);
        },
        .success => |unexpected| {
            releaseDevice(t.allocator, io, unexpected);
            return error.ConsumedAdapterCreatedDevice;
        },
        else => return error.UnexpectedRootOutcome,
    }
}

fn syncError(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: dusk.core.ErrorView) void {
    @panic("unexpected synchronous uncaptured error");
}

test "root borrowed exports refuse release and synchronous creation needs no source" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer closeInstance(t.allocator, io, &instance);
    var list = try instance.enumerateAdapters(t.allocator, io, .{
        .feature_level = .core,
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    defer list.deinit(io) catch @panic("borrowed list cleanup failed");
    try t.expect(list.items.len != 0);
    const adapter_receipt = root.releaseAdapterResult(t.allocator, io, handles.exportAdapter(&list.items[0]));
    try t.expect(!adapter_receipt.consumed);
    try t.expectEqual(error.BorrowedRoot, adapter_receipt.failure.?);
    var object_mutex: std.Io.Mutex = .init;
    var context: u8 = 0;
    var high = try list.items[0].createDevice(t.allocator, io, .{
        .adapter = &list.items[0],
        .object_mutex = &object_mutex,
        .uncaptured_context = &context,
        .uncaptured_callback = syncError,
        .feature_level = list.items[0].feature_level,
    });
    defer high.deinit(t.allocator, io) catch @panic("borrowed device cleanup failed");
    const device_receipt = root.releaseDeviceResult(t.allocator, io, handles.exportDevice(&high));
    try t.expect(!device_receipt.consumed);
    try t.expectEqual(error.BorrowedRoot, device_receipt.failure.?);
    try t.expectError(error.MissingFutureNamespaceSource, native_async.getLostFuture(&high, io));
    var callback: DeviceCall = .{ .io = io, .allocator = t.allocator };
    try t.expectError(error.MissingFutureNamespaceSource, root.requestDevice(handles.exportAdapter(&list.items[0]), t.allocator, io, null, callback.info(.wait_any_only)));
    try t.expectEqual(@as(usize, 0), callback.calls);
    try t.expect(instance.completions == null);
}

test "root native observer cancellation abandons observation not accepted creation" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const bootstrap = try adapterSuccess(t.allocator, &instance, io);
    releaseSelection(t.allocator, io, bootstrap);
    instance.root_work_mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) instance.root_work_mutex.unlock(io);
    var observer = try instance.requestAdapterAsync(t.allocator, io, null);
    const accepted_sequence = instance.completions.?.issued;
    const canceled = observer.cancel(io);
    try t.expect(canceled == .canceled);
    try t.expectEqual(accepted_sequence, instance.completions.?.issued);
    try t.expectEqual(@as(u64, 0), instance.list_count);
    instance.root_work_mutex.unlock(io);
    locked = false;
    try drainRootPins(&instance, io);
    try root.collectRootDisposals(&instance, t.allocator, io);
    try t.expectEqual(@as(u64, 0), instance.list_count);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    const again = try adapterSuccess(t.allocator, &instance, io);
    releaseSelection(t.allocator, io, again);
}

test "root actual Vulkan adapter and device never skip missing capabilities" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    try t.expect(instance.native_context != null);
    const context = instance.native_context;
    const owned = try deviceSuccess(t.allocator, selection, io, null);
    defer releaseDevice(t.allocator, io, owned);
    try t.expect(owned.high.native != null);
    try t.expect(instance.native_context == context);
    try t.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    const loss = try native_async.getLostFuture(&owned.high, io);
    try t.expect(loss.id != 0);
    try t.expectEqual(loss.id, (try native_async.getLostFuture(&owned.high, io)).id);
    const buffer = try owned.high.createBuffer(t.allocator, io, .{
        .size = 4,
        .usage = .{ .copy_dst = true },
    });
    try t.expect(buffer.header.tracking.high_owner == @as(*anyopaque, @ptrCast(&owned.high)));
    const retained = root.releaseDeviceResult(t.allocator, io, handles.exportDevice(&owned.high));
    try t.expect(!retained.consumed);
    try t.expectEqual(error.ResourceInUse, retained.failure.?);
    try t.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try owned.high.release(t.allocator, io, buffer);
    try t.expectError(error.InstanceInUse, instance.deinit(t.allocator, io));
    try owned.high.destroy(t.allocator, io);
    try waitFuture(&instance, io, loss);
    try t.expectEqual(loss.id, (try native_async.getLostFuture(&owned.high, io)).id);
}

test "root descriptor copy preserves absent and present empty values and every Limits field" {
    var absent = try root.copyDeviceInput(t.allocator, null);
    defer absent.deinit(t.allocator);
    try t.expect(absent.label == null);
    try t.expect(absent.default_queue_label == null);
    try t.expect(absent.required_limits == null);
    try t.expectEqual(@as(usize, 0), absent.required_features.len);
    var limits: api.Limits = .{};
    inline for (@typeInfo(api.Limits).@"struct".fields, 0..) |field, index| {
        @field(limits, field.name) = @intCast(index + 1);
    }
    var input = descriptor();
    input.label = "";
    input.default_queue.label = "";
    input.required_features = &.{};
    input.required_limits = &limits;
    var owned = try root.copyDeviceInput(t.allocator, &input);
    defer owned.deinit(t.allocator);
    try t.expect(owned.label != null);
    try t.expectEqual(@as(usize, 0), owned.label.?.len);
    try t.expect(owned.default_queue_label != null);
    try t.expectEqual(@as(usize, 0), owned.default_queue_label.?.len);
    inline for (@typeInfo(api.Limits).@"struct".fields) |field| {
        try t.expectEqual(@field(limits, field.name), @field(owned.required_limits.?, field.name));
    }
    var label = [_]u8{ 'a', 0, 'b' };
    var queue_label = [_]u8{ 'c', 0, 'd' };
    var features = [_]api.FeatureName{ .texture_formats_tier1, .texture_formats_tier1 };
    input.label = &label;
    input.default_queue.label = &queue_label;
    input.required_feature_count = features.len;
    input.required_features = &features;
    var copied = try root.copyDeviceInput(t.allocator, &input);
    defer copied.deinit(t.allocator);
    @memset(&label, 'x');
    @memset(&queue_label, 'x');
    @memset(&features, .depth_clip_control);
    limits = .{};
    try t.expectEqualSlices(u8, &.{ 'a', 0, 'b' }, copied.label.?);
    try t.expectEqualSlices(u8, &.{ 'c', 0, 'd' }, copied.default_queue_label.?);
    try t.expectEqualSlices(api.FeatureName, &.{
        .texture_formats_tier1, .texture_formats_tier1,
    }, copied.required_features);
    try t.expectEqual(@as(u32, 17), copied.required_limits.?.min_uniform_buffer_offset_alignment);
}

test "root foreign allocators refuse before admission and preserve owned release rights" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    const issued = instance.completions.?.issued;
    var adapter_call: AdapterCall = .{};
    var device_call: DeviceCall = .{ .io = io, .allocator = t.allocator };
    var foreign = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.InvalidOwner, root.requestAdapter(handles.exportInstance(&instance), foreign.allocator(), io, null, adapter_call.info(.wait_any_only)));
    try t.expectError(error.InvalidOwner, root.requestDevice(handles.exportAdapter(selection.selected()), foreign.allocator(), io, null, device_call.info(.wait_any_only)));
    const receipt = root.releaseAdapterResult(foreign.allocator(), io, handles.exportAdapter(selection.selected()));
    try t.expect(!receipt.consumed);
    try t.expectEqual(error.AllocatorMismatch, receipt.failure.?);
    try t.expectError(error.AllocatorMismatch, root.collectRootDisposals(&instance, foreign.allocator(), io));
    try t.expectEqual(@as(usize, 0), foreign.alloc_index);
    try t.expectEqual(issued, instance.completions.?.issued);
    try t.expectEqual(@as(usize, 0), adapter_call.calls);
    try t.expectEqual(@as(usize, 0), device_call.calls);
}

test "root two accepted single-use device requests produce exactly one real owner" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    instance.root_work_mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) instance.root_work_mutex.unlock(io);
    const first = try selection.selected().requestDeviceAsync(t.allocator, io, null);
    const second = try selection.selected().requestDeviceAsync(t.allocator, io, null);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    instance.root_work_mutex.unlock(io);
    locked = false;
    const results = [_]root.RootOutcome(*root.OwnedDevice){
        try takeNative(*root.OwnedDevice, io, first),
        try takeNative(*root.OwnedDevice, io, second),
    };
    try drainRootPins(&instance, io);
    var successes: usize = 0;
    var failures: usize = 0;
    for (results) |result| {
        switch (result) {
            .success => |owned| {
                successes += 1;
                releaseDevice(t.allocator, io, owned);
            },
            .failure => |failure| {
                defer failure.release();
                failures += 1;
                try t.expect(std.mem.indexOf(u8, failure.view().message, "AdapterConsumed") != null);
            },
            else => return error.UnexpectedRootOutcome,
        }
    }
    try t.expectEqual(@as(usize, 1), successes);
    try t.expectEqual(@as(usize, 1), failures);
    try t.expect(selection.selected().is_consumed);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
}

test "root native canceled device result drains through the actual hidden owner collector" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    instance.root_work_mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) instance.root_work_mutex.unlock(io);
    var observer = try selection.selected().requestDeviceAsync(t.allocator, io, null);
    const issued = instance.completions.?.issued;
    const canceled = observer.cancel(io);
    try t.expect(canceled == .canceled);
    try t.expectEqual(issued, instance.completions.?.issued);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try t.expectError(error.InstanceInUse, instance.deinit(t.allocator, io));
    instance.root_work_mutex.unlock(io);
    locked = false;
    try drainRootPins(&instance, io);
    try root.collectRootDisposals(&instance, t.allocator, io);
    try t.expect(selection.selected().is_consumed);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u32, 0), instance.root_disposal_count);
    try t.expectEqual(@as(u32, 0), instance.root_disposal_slots);
    try root.collectRootDisposals(&instance, t.allocator, io);
}

fn sweepAdapterAllocations(io: std.Io, backend: api.BackendType) !void {
    var saw_preaccept = false;
    var saw_accepted_failure = false;
    var reached_success = false;
    for (0..allocation_limit) |fail_index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var source = registry.FutureNamespaceSource.init();
        var instance = engine.Instance.init(.{
            .backend_type = backend,
            .future_namespace_source = &source,
        });
        var call: AdapterCall = .{};
        var accepted_future: ?api.Future = null;
        var closed = false;
        // Drain accepted work and release its owner before callback locals disappear.
        defer if (!closed) {
            failing.fail_index = std.math.maxInt(usize);
            if (accepted_future) |future| {
                if (call.calls == 0) {
                    waitFuture(&instance, io, future) catch @panic("adapter cleanup wait failed");
                }
                drainRootPins(&instance, io) catch @panic("adapter cleanup drain failed");
            }
            if (call.handle) |handle| {
                const receipt = root.releaseAdapterResult(allocator, io, handle);
                if (!receipt.consumed or receipt.failure != null) @panic("selection cleanup failed");
                call.handle = null;
            }
            closeInstance(allocator, io, &instance);
        };
        const started = root.requestAdapter(handles.exportInstance(&instance), allocator, io, null, call.info(.wait_any_only));
        if (started) |future| {
            accepted_future = future;
            try waitFuture(&instance, io, future);
            try drainRootPins(&instance, io);
            try t.expectEqual(@as(usize, 1), call.calls);
            if (call.status == .success) {
                const high = try handles.resolveAdapter(call.handle.?);
                releaseSelection(allocator, io, high.root_record.ownership.adapter_result);
                call.handle = null;
                reached_success = true;
            } else {
                try t.expectEqual(api.RequestAdapterStatus.error_, call.status.?);
                try t.expect(call.handle == null);
                const message = call.message[0..call.message_len];
                const is_allocation_failure = std.mem.indexOf(u8, message, "OutOfMemory") != null;
                if (!is_allocation_failure) {
                    std.debug.print(
                        "root adapter fail-N: backend={s}, fail_index={d}, message={s}\n",
                        .{ @tagName(backend), fail_index, message },
                    );
                }
                try t.expect(is_allocation_failure);
                saw_accepted_failure = true;
            }
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            saw_preaccept = true;
            try t.expectEqual(@as(usize, 0), call.calls);
            if (instance.completions) |attached| {
                try t.expectEqual(@as(u32, 0), attached.issued);
            }
        }
        failing.fail_index = std.math.maxInt(usize);
        try t.expectEqual(@as(u64, 0), instance.list_count);
        try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
        closeInstance(allocator, io, &instance);
        closed = true;
        try t.expectEqual(failing.allocations, failing.deallocations);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (reached_success) break;
    }
    try t.expect(reached_success);
    try t.expect(saw_preaccept);
    try t.expect(saw_accepted_failure);
}

fn sweepDeviceAllocations(io: std.Io, backend: api.BackendType) !void {
    var saw_preaccept = false;
    var saw_accepted_failure = false;
    var reached_success = false;
    for (0..allocation_limit) |offset| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const allocator = failing.allocator();
        var source = registry.FutureNamespaceSource.init();
        var instance = engine.Instance.init(.{
            .backend_type = backend,
            .future_namespace_source = &source,
        });
        const selection = try adapterSuccess(allocator, &instance, io);
        var call: DeviceCall = .{ .io = io, .allocator = allocator };
        var loss: LossCall = .{ .io = io, .allocator = allocator };
        var input = descriptor();
        input.label = "copied allocation failure device";
        input.default_queue.label = "copied allocation failure queue";
        input.required_features = &.{ .core_features_and_limits, .core_features_and_limits };
        input.required_feature_count = 2;
        input.device_lost_callback_info = loss.info(.allow_process_events);
        const issued = instance.completions.?.issued;
        failing.fail_index = failing.alloc_index + offset;
        const started = root.requestDevice(handles.exportAdapter(selection.selected()), allocator, io, &input, call.info(.wait_any_only));
        if (started) |future| {
            try waitFuture(&instance, io, future);
            try drainRootPins(&instance, io);
            try t.expectEqual(issued + 2, instance.completions.?.issued);
            if (call.status == .success) {
                failing.fail_index = std.math.maxInt(usize);
                const high = try handles.resolveDevice(call.handle.?);
                releaseDevice(allocator, io, high.root_record.ownership.device_result);
                reached_success = true;
            } else {
                try t.expectEqual(api.RequestDeviceStatus.error_, call.status.?);
                try t.expect(call.handle == null);
                try t.expect(std.mem.indexOf(u8, call.message[0..call.message_len], "OutOfMemory") != null);
                try t.expect(!selection.selected().is_consumed);
                try root.processEvents(handles.exportInstance(&instance), io);
                try t.expectEqual(@as(usize, 1), loss.calls);
                try t.expectEqual(api.DeviceLostReason.failed_creation, loss.reason.?);
                try t.expectEqual(@as(usize, 0), loss.device_count);
                saw_accepted_failure = true;
            }
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(issued, instance.completions.?.issued);
            try t.expectEqual(@as(usize, 0), call.calls);
            try t.expectEqual(@as(usize, 0), loss.calls);
            try t.expect(!selection.selected().is_consumed);
            saw_preaccept = true;
        }
        failing.fail_index = std.math.maxInt(usize);
        try root.processEvents(handles.exportInstance(&instance), io);
        try root.collectRootDisposals(&instance, allocator, io);
        try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
        try t.expectEqual(@as(usize, 0), selection.selected().active_root_requests);
        try t.expectEqual(@as(u32, 0), instance.root_disposal_slots);
        releaseSelection(allocator, io, selection);
        closeInstance(allocator, io, &instance);
        try t.expectEqual(failing.allocations, failing.deallocations);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (reached_success) break;
    }
    try t.expect(reached_success);
    try t.expect(saw_preaccept);
    if (backend == .vulkan) try t.expect(saw_accepted_failure);
}

test "root fail-N covers null and Vulkan setup and actual selection owners" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    try sweepAdapterAllocations(threaded.io(), .null_);
    try sweepAdapterAllocations(threaded.io(), .vulkan);
}

test "root fail-N covers copied graph pair reservations and actual null and Vulkan devices" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    try sweepDeviceAllocations(threaded.io(), .null_);
    try sweepDeviceAllocations(threaded.io(), .vulkan);
}

test "root every valid callback mode delivers the real adapter request once" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    inline for (.{ api.CallbackMode.wait_any_only, api.CallbackMode.allow_process_events, api.CallbackMode.allow_spontaneous }) |mode| {
        var call: AdapterCall = .{};
        const future = try root.requestAdapter(handles.exportInstance(&instance), t.allocator, io, null, call.info(mode));
        try waitFuture(&instance, io, future);
        try drainRootPins(&instance, io);
        try t.expectEqual(@as(usize, 1), call.calls);
        try t.expectEqual(api.RequestAdapterStatus.success, call.status.?);
        const high = try handles.resolveAdapter(call.handle.?);
        releaseSelection(t.allocator, io, high.root_record.ownership.adapter_result);
        try root.processEvents(handles.exportInstance(&instance), io);
        try waitFuture(&instance, io, future);
        try t.expectEqual(@as(usize, 1), call.calls);
    }
}

test "root required limits preserve undefined sentinels and minimum alignment direction" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    const available = selection.selected().limits.v1;
    var requirements: api.Limits = .{
        .min_uniform_buffer_offset_alignment = available.min_uniform_buffer_offset_alignment,
        .min_storage_buffer_offset_alignment = available.min_storage_buffer_offset_alignment,
    };
    var input = descriptor();
    input.required_limits = &requirements;
    input.dawn_consume_adapter_descriptor = .{ .consume_adapter = false };
    const first = try deviceSuccess(t.allocator, selection, io, &input);
    releaseDevice(t.allocator, io, first);
    try t.expect(!selection.selected().is_consumed);
    requirements.max_bind_groups = available.max_bind_groups + 1;
    const failure_result = try takeNative(*root.OwnedDevice, io, try selection.selected().requestDeviceAsync(t.allocator, io, &input));
    try drainRootPins(&instance, io);
    switch (failure_result) {
        .failure => |failure| {
            defer failure.release();
            try t.expectEqualStrings("LimitExceeded", dusk.core.nameOf(failure.view().code));
        },
        .success => |unexpected| {
            releaseDevice(t.allocator, io, unexpected);
            return error.ExcessiveLimitAccepted;
        },
        else => return error.UnexpectedRootOutcome,
    }
    try t.expect(!selection.selected().is_consumed);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    requirements = .{};
    const second = try deviceSuccess(t.allocator, selection, io, &input);
    releaseDevice(t.allocator, io, second);
}

test "root required unsupported feature is an accepted failure without consuming the adapter" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    var unsupported: ?api.FeatureName = null;
    inline for (@typeInfo(api.FeatureName).@"enum".fields) |field| {
        const name: api.FeatureName = @enumFromInt(field.value);
        if (unsupported == null and !selection.selected().physical_device.supportsAllRequiredFeatures(&.{name}).supported) {
            unsupported = name;
        }
    }
    const missing = unsupported orelse return error.NoUnsupportedFeatureFixture;
    var input = descriptor();
    input.required_feature_count = 1;
    input.required_features = &.{missing};
    const result = try takeNative(*root.OwnedDevice, io, try selection.selected().requestDeviceAsync(t.allocator, io, &input));
    try drainRootPins(&instance, io);
    switch (result) {
        .failure => |failure| {
            defer failure.release();
            try t.expectEqualStrings("RequiredFeatureMissing", dusk.core.nameOf(failure.view().code));
        },
        .success => |unexpected| {
            releaseDevice(t.allocator, io, unexpected);
            return error.UnsupportedFeatureAccepted;
        },
        else => return error.UnexpectedRootOutcome,
    }
    try t.expect(!selection.selected().is_consumed);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    const owned = try deviceSuccess(t.allocator, selection, io, null);
    releaseDevice(t.allocator, io, owned);
}

test "root unavailable adapter publishes no counted list or fabricated handle" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const options: api.descriptors.RequestAdapterOptionsChain = .{
        .power_preference = .undefined_,
        .backend_type = .null_,
        .force_fallback_adapter = true,
    };
    var call: AdapterCall = .{};
    const future = try root.requestAdapter(handles.exportInstance(&instance), t.allocator, io, &options, call.info(.wait_any_only));
    try waitFuture(&instance, io, future);
    try drainRootPins(&instance, io);
    try t.expectEqual(api.RequestAdapterStatus.unavailable, call.status.?);
    try t.expect(call.handle == null);
    try t.expectEqual(@as(u64, 0), instance.queryAdapterListCount(io));
    const native = try takeNative(*root.OwnedAdapterSelection, io, try instance.requestAdapterAsync(t.allocator, io, &options));
    try drainRootPins(&instance, io);
    try t.expect(native == .unavailable);
    try t.expectEqual(@as(u64, 0), instance.queryAdapterListCount(io));
}

test "root pair sequence exhaustion refuses atomically and leaves the final single sequence" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    const completion = instance.completions.?;
    completion.mutex.lockUncancelable(io);
    completion.issued = std.math.maxInt(u32) - 1;
    completion.mutex.unlock(io);
    var call: DeviceCall = .{ .io = io, .allocator = t.allocator };
    try t.expectError(error.FutureIdExhausted, root.requestDevice(handles.exportAdapter(selection.selected()), t.allocator, io, null, call.info(.wait_any_only)));
    try t.expectEqual(std.math.maxInt(u32) - 1, completion.issued);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    const last = try adapterSuccess(t.allocator, &instance, io);
    releaseSelection(t.allocator, io, last);
    try t.expectEqual(std.math.maxInt(u32), completion.issued);
    var adapter_call: AdapterCall = .{};
    try t.expectError(error.FutureIdExhausted, root.requestAdapter(handles.exportInstance(&instance), t.allocator, io, null, adapter_call.info(.wait_any_only)));
    try t.expectEqual(@as(usize, 0), call.calls);
    try t.expectEqual(@as(usize, 0), adapter_call.calls);
}

test "root pair commits the final two sequences and keeps its loss Future valid" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    const completion = instance.completions.?;
    completion.mutex.lockUncancelable(io);
    completion.issued = std.math.maxInt(u32) - 2;
    completion.mutex.unlock(io);
    const owned = try deviceSuccess(t.allocator, selection, io, null);
    defer releaseDevice(t.allocator, io, owned);
    try t.expectEqual(std.math.maxInt(u32), completion.issued);
    const lost = try native_async.getLostFuture(&owned.high, io);
    try t.expectEqual(std.math.maxInt(u32), @as(u32, @truncate(lost.id)));
    var call: AdapterCall = .{};
    try t.expectError(error.FutureIdExhausted, root.requestAdapter(handles.exportInstance(&instance), t.allocator, io, null, call.info(.wait_any_only)));
    try t.expectEqual(@as(usize, 0), call.calls);
    try owned.high.destroy(t.allocator, io);
    try waitFuture(&instance, io, lost);
    try t.expectEqual(lost.id, (try native_async.getLostFuture(&owned.high, io)).id);
}

test "root explicit empty descriptor and every loss callback mode use the reserved loss Future" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    inline for (.{ api.CallbackMode.wait_any_only, api.CallbackMode.allow_process_events, api.CallbackMode.allow_spontaneous }) |mode| {
        var loss: LossCall = .{ .io = io, .allocator = t.allocator };
        var input = descriptor();
        input.required_features = &.{};
        input.dawn_consume_adapter_descriptor = .{ .consume_adapter = false };
        input.device_lost_callback_info = loss.info(mode);
        const owned = try deviceSuccess(t.allocator, selection, io, &input);
        defer releaseDevice(t.allocator, io, owned);
        try t.expectEqualStrings("", owned.high.getLabel());
        try t.expectEqualStrings("", owned.high.default_queue_label);
        const lost = try native_async.getLostFuture(&owned.high, io);
        native_async.finishLoss(&owned.high, t.allocator, io, .unknown, "real reserved loss");
        if (mode == .wait_any_only) {
            try root.processEvents(handles.exportInstance(&instance), io);
            try t.expectEqual(@as(usize, 0), loss.calls);
        } else if (mode == .allow_process_events) {
            try root.processEvents(handles.exportInstance(&instance), io);
            try t.expectEqual(@as(usize, 1), loss.calls);
        } else {
            try Event.waitTimeout(io, &loss.completed, timeout_ns);
            try t.expectEqual(@as(usize, 1), loss.calls);
        }
        try waitFuture(&instance, io, lost);
        try t.expectEqual(@as(usize, 1), loss.calls);
        try t.expect(loss.callback_pinned);
        try t.expect(loss.destroy_refused);
        try t.expectEqual(lost.id, (try native_async.getLostFuture(&owned.high, io)).id);
        try t.expect(!selection.selected().is_consumed);
    }
}

test "root native observer finite wait failure preserves the accepted runner and owned diagnostic" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .null_, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const bootstrap = try adapterSuccess(t.allocator, &instance, io);
    releaseSelection(t.allocator, io, bootstrap);
    const completion = instance.completions.?;
    completion.mutex.lockUncancelable(io);
    completion.options.max_wait_iterations = 1;
    completion.mutex.unlock(io);
    instance.root_work_mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) instance.root_work_mutex.unlock(io);
    const Job = struct {
        future: std.Io.Future(root.RootOutcome(*root.OwnedAdapterSelection)),
        result: ?root.RootOutcome(*root.OwnedAdapterSelection) = null,
        completed: Event = .{},
        fn run(call_io: std.Io, self: *@This()) void {
            self.result = self.future.await(call_io);
            Event.signal(call_io, &self.completed);
        }
    };
    var job: Job = .{ .future = try instance.requestAdapterAsync(t.allocator, io, null) };
    var observer = io.concurrent(Job.run, .{ io, &job }) catch |err| {
        const abandoned = job.future.cancel(io);
        switch (abandoned) {
            .failure => |failure| failure.release(),
            .success => |selection| releaseSelection(t.allocator, io, selection),
            else => {},
        }
        return err;
    };
    var joined = false;
    defer if (!joined) observer.cancel(io);
    var wake_call: AdapterCall = .{};
    var wake_future: ?api.Future = null;
    var barrier_observed = false;
    for (0..poll_limit) |_| {
        job.completed.mutex.lockUncancelable(io);
        const finished = job.completed.signaled;
        job.completed.mutex.unlock(io);
        if (finished) {
            barrier_observed = true;
            break;
        }
        completion.mutex.lockUncancelable(io);
        const waiting = completion.waiters;
        completion.mutex.unlock(io);
        if (waiting != 0) {
            // A second real admission supplies the wake, not a synthetic backend.
            wake_future = try root.requestAdapter(handles.exportInstance(&instance), t.allocator, io, null, wake_call.info(.wait_any_only));
            barrier_observed = true;
            break;
        }
        try pause(io);
    }
    try t.expect(barrier_observed);
    try Event.waitTimeout(io, &job.completed, timeout_ns);
    observer.await(io);
    joined = true;
    const result = job.result.?;
    switch (result) {
        .failure => |failure| {
            defer failure.release();
            try t.expect(std.mem.indexOf(u8, failure.view().message, "WaitIterationExhausted") != null);
        },
        .success => |selection| {
            releaseSelection(t.allocator, io, selection);
            return error.ObserverWaitFailureTransferredResult;
        },
        .canceled => return error.FiniteObserverFailureProjectedCancellation,
        else => return error.UnexpectedRootOutcome,
    }
    completion.mutex.lockUncancelable(io);
    const accepted_count = completion.live_cells;
    completion.options.max_wait_iterations = 1_000_000;
    completion.mutex.unlock(io);
    try t.expect(accepted_count != 0);
    try t.expectEqual(@as(u64, 0), instance.queryAdapterListCount(io));
    instance.root_work_mutex.unlock(io);
    locked = false;
    if (wake_future) |future| {
        try waitFuture(&instance, io, future);
    }
    try drainRootPins(&instance, io);
    if (wake_future != null) {
        try t.expectEqual(api.RequestAdapterStatus.success, wake_call.status.?);
        const high = try handles.resolveAdapter(wake_call.handle.?);
        releaseSelection(t.allocator, io, high.root_record.ownership.adapter_result);
    }
    try root.collectRootDisposals(&instance, t.allocator, io);
    try t.expectEqual(@as(u64, 0), instance.queryAdapterListCount(io));
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
}

fn queueActualOwnerFixture(instance: *engine.Instance, io: std.Io, owned: *root.OwnedDevice) void {
    instance.lifecycle_mutex.lockUncancelable(io);
    defer instance.lifecycle_mutex.unlock(io);
    std.debug.assert(owned.instance == instance);
    std.debug.assert(owned.ownership == .caller);
    std.debug.assert(owned.disposal_state == .none);
    std.debug.assert(!owned.disposal_slot_held);
    std.debug.assert(instance.root_disposal_slots < instance.async_options.max_live_operations);
    // Transfer this unique, already-created owner; do not construct a replacement.
    instance.root_disposal_slots += 1;
    owned.disposal_slot_held = true;
    owned.ownership = .disposing;
    owned.disposal_state = .queued;
    owned.disposal_next = instance.root_disposals;
    instance.root_disposals = owned;
    instance.root_disposal_count += 1;
}

test "root collector retains the same actual Vulkan owner on live alias refusal" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var allocations = t.FailingAllocator.init(t.allocator, .{});
    const allocator = allocations.allocator();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan, .future_namespace_source = &source });
    defer closeInstance(allocator, io, &instance);
    const selection = try adapterSuccess(allocator, &instance, io);
    defer releaseSelection(allocator, io, selection);
    const owned = try deviceSuccess(allocator, selection, io, null);
    const buffer = try owned.high.createBuffer(allocator, io, .{
        .size = 4,
        .usage = .{ .copy_dst = true },
    });
    var alias_released = false;
    defer if (!alias_released) {
        owned.high.release(allocator, io, buffer) catch @panic("retained fixture alias cleanup failed");
    };
    const context = owned.high.native;
    const original_mutex = owned.high.core.arena.objectList().mutex;
    queueActualOwnerFixture(&instance, io, owned);
    allocations.fail_index = allocations.alloc_index;
    const allocation_count = allocations.alloc_index;
    try t.expectError(error.ResourceInUse, root.collectRootDisposals(&instance, allocator, io));
    try t.expectEqual(allocation_count, allocations.alloc_index);
    try t.expect(instance.root_disposals.? == owned);
    try t.expectEqual(@as(u32, 1), instance.root_disposal_count);
    try t.expectEqual(@as(u32, 1), instance.root_disposal_slots);
    try t.expectEqual(error.ResourceInUse, owned.cleanup_error.?);
    try t.expect(owned.disposal_state == .queued);
    try t.expect(!owned.high.host_deinitialized);
    try t.expect(owned.high.native == context);
    try t.expect(owned.high.core.arena.objectList().mutex == original_mutex);
    try t.expectEqual(@as(u64, 1), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u64, 1), selection.selected().live_device_count);
    try t.expectEqual(@as(u64, 1), selection.selected().physical_device.live_device_count);
    try t.expectError(error.InstanceInUse, instance.deinit(allocator, io));
    {
        instance.lifecycle_mutex.lockUncancelable(io);
        instance.root_disposal_collecting = true;
        instance.lifecycle_mutex.unlock(io);
        defer {
            instance.lifecycle_mutex.lockUncancelable(io);
            instance.root_disposal_collecting = false;
            instance.lifecycle_mutex.unlock(io);
        }
        try t.expectError(error.InstanceInUse, root.collectRootDisposals(&instance, allocator, io));
        try t.expect(instance.root_disposals.? == owned);
        try t.expect(owned.disposal_state == .queued);
        try t.expectEqual(@as(u32, 1), instance.root_disposal_slots);
    }
    try owned.high.release(allocator, io, buffer);
    alias_released = true;
    try root.collectRootDisposals(&instance, allocator, io);
    try t.expectEqual(allocation_count, allocations.alloc_index);
    try t.expect(instance.root_disposals == null);
    try t.expectEqual(@as(u32, 0), instance.root_disposal_count);
    try t.expectEqual(@as(u32, 0), instance.root_disposal_slots);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u64, 0), selection.selected().live_device_count);
    try t.expectEqual(@as(u64, 0), selection.selected().physical_device.live_device_count);
    try t.expect(instance.root_disposal_error == null);
    try root.collectRootDisposals(&instance, allocator, io);
}

test "root owned release receipt exposes a seeded cleanup latch after actual host consumption" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    const owned = try deviceSuccess(t.allocator, selection, io, null);
    const context = owned.high.native.?;
    context.queue_operation_mutex.lockUncancelable(io);
    // Seed the existing sticky diagnostic; this does not simulate a GPU failure.
    context.retirement_error = error.MissingDeviceProc;
    context.queue_operation_mutex.unlock(io);
    const receipt = root.releaseDeviceResult(t.allocator, io, handles.exportDevice(&owned.high));
    // The receipt is the only authority now. The consumed root cannot be inspected.
    try t.expect(receipt.consumed);
    try t.expectEqual(error.MissingDeviceProc, receipt.failure.?);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u64, 0), selection.selected().live_device_count);
    try t.expectEqual(@as(u64, 0), selection.selected().physical_device.live_device_count);
    try t.expect(instance.root_disposals == null);
}

test "root collector consumes actual hosts and reports a seeded cleanup diagnostic exactly once" {
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = registry.FutureNamespaceSource.init();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan, .future_namespace_source = &source });
    defer closeInstance(t.allocator, io, &instance);
    const selection = try adapterSuccess(t.allocator, &instance, io);
    defer releaseSelection(t.allocator, io, selection);
    var input = descriptor();
    input.dawn_consume_adapter_descriptor = .{ .consume_adapter = false };
    const first = try deviceSuccess(t.allocator, selection, io, &input);
    const second = try deviceSuccess(t.allocator, selection, io, &input);
    const context = first.high.native.?;
    context.queue_operation_mutex.lockUncancelable(io);
    // Only the pre-existing diagnostic latch is seeded; both devices are real.
    context.retirement_error = error.MissingDeviceProc;
    context.queue_operation_mutex.unlock(io);
    queueActualOwnerFixture(&instance, io, first);
    queueActualOwnerFixture(&instance, io, second);
    try t.expectEqual(@as(u32, 2), instance.root_disposal_count);
    try t.expectEqual(@as(u64, 2), instance.queryDeviceCount(io));
    try t.expectError(error.InstanceInUse, instance.deinit(t.allocator, io));
    try t.expectError(error.MissingDeviceProc, root.collectRootDisposals(&instance, t.allocator, io));
    // Independent cleanup continues through the entry snapshot despite the error.
    try t.expect(instance.root_disposals == null);
    try t.expectEqual(@as(u32, 0), instance.root_disposal_count);
    try t.expectEqual(@as(u32, 0), instance.root_disposal_slots);
    try t.expect(instance.root_disposal_error == null);
    try t.expectEqual(@as(u64, 0), instance.queryDeviceCount(io));
    try t.expectEqual(@as(u64, 0), selection.selected().live_device_count);
    try t.expectEqual(@as(u64, 0), selection.selected().physical_device.live_device_count);
    try root.collectRootDisposals(&instance, t.allocator, io);
}
