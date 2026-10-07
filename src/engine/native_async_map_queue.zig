//! Native mapping and queue-fence observers share the canonical completion cells.
//! Cancellation abandons observation, never a submitted GPU root or its serial lease.
const std = @import("std");
const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");
const registry_mod = @import("async_registry.zig");
const native_async = @import("native_async_device.zig");
const handles = @import("native_async_handles.zig");
const resources = @import("native_resources.zig");
const raw = @import("buffer.zig");
const native_context = @import("native_device_context.zig");
const Device = @import("device.zig").Device;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Kind = enum { map, queue };
pub const fence_observation_retry_bound: u32 = 64;
pub const fence_observation_timeout_ns: u64 = 10 * std.time.ns_per_ms;
pub const ObservationError = native_context.CleanupError || error{ FenceObservationExhausted, ObservationStopped, MapAborted };

/// Move-only ownership of a native mapping. The span stays allocated through deinit,
/// including explicit buffer destruction. Unmap/remap can change its logical contents.
/// Keep the Io/allocator backing state and the high owner alive through deinit.
pub const NativeMapResult = struct {
    bytes: []const u8,
    writable_bytes: ?[]u8,
    device: ?*Device,
    buffer: ?*resources.Buffer,
    pub fn deinit(self: *NativeMapResult, io: Io) void {
        const device = self.device orelse return;
        const buffer = self.buffer.?;
        self.device = null;
        self.buffer = null;
        self.bytes = &.{};
        self.writable_bytes = null;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
            defer guard.unlock(io);
            buffer.releaseMappingLeaseLocked(&guard, io);
        }
        device.releaseOperation(io);
    }
};
pub const NativeMapOutcome = union(enum) { success: NativeMapResult, failure: core.ErrorRef, aborted, canceled, shut_down };
pub const NativeQueueOutcome = union(enum) { success, failure: core.ErrorRef, canceled, shut_down };

fn Context(comptime kind: Kind) type {
    return struct {
        device: ?*Device,
        pin_held: bool = false,
        result_pin_held: bool = false,
        buffer: ?*resources.Buffer = null,
        buffer_lease: bool = false,
        generation: ?u64 = null,
        mode: api.MapMode = .{},
        offsets: api.Buffer.MapAsyncOffsetOptions = .{ .offset = 0, .size = api.WholeMapSize },
        target_serial: platform.Serial = 0,
        scope: ?core.ScopeLeaseSet = null,
        reservation: core.ErrorReservation,
        failure: ?core.ErrorRef = null,
        validation_error: ?raw.MapError = null,
        status: enum { pending, success, failure, aborted, shut_down, transferred } = .pending,
        native_result: ?NativeMapResult = null,
        callback_info: if (kind == .map) ?api.BufferMapCallbackInfo else ?api.QueueWorkDoneCallbackInfo,
        const Self = @This();
        fn releaseBuffer(self: *Self, io: Io) void {
            const buffer = self.buffer orelse return;
            if (self.buffer_lease) {
                var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
                defer guard.unlock(io);
                if (self.generation) |generation| {
                    if (buffer.header.state == .alive) _ = buffer.native.cancelMap(generation);
                    self.generation = null;
                }
                buffer.header.releaseLeaseLocked(&guard, io);
            }
            self.buffer_lease = false;
            self.buffer = null;
        }
        fn settle(self: *Self, io: Io) void {
            if (self.scope) |*scope| {
                const device = self.device.?;
                var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
                var settlement = scope.settle(&guard, self.failure) catch unreachable;
                self.scope = null;
                guard.unlock(io);
                settlement.dispatch(io);
            }
            self.reservation.discard();
        }
        fn invoke(self: *Self, _: Io) void {
            const info = self.callback_info.?;
            const message = if (self.failure) |failure| failure.view().message else "";
            if (kind == .map) info.callback(info.userdata, switch (self.status) {
                .success => .success,
                .failure => .error_,
                .aborted => .aborted,
                .shut_down => .callback_cancelled,
                else => unreachable,
            }, message) else info.callback(info.userdata, switch (self.status) {
                .success => .success,
                .failure, .aborted => .error_,
                .shut_down => .callback_cancelled,
                else => unreachable,
            }, message);
        }
        fn dispose(self: *Self, io: Io) void {
            if (self.native_result) |*result| result.deinit(io);
            self.native_result = null;
        }
        fn shutDown(self: *Self, _: Io) void {
            std.debug.assert(self.scope == null and self.buffer == null);
            self.status = .shut_down;
        }
        fn deinit(self: *Self, _: Allocator, io: Io) void {
            self.dispose(io);
            self.releaseBuffer(io);
            if (self.scope) |*scope| {
                var guard = core.ObjectGuard.lockUncancelable(io, self.device.?.core.arena.objectList());
                var settlement = scope.deinit(&guard);
                self.scope = null;
                guard.unlock(io);
                settlement.dispatch(io);
            }
            self.reservation.discard();
            if (self.failure) |failure| failure.release();
            self.failure = null;
            if (self.result_pin_held) native_async.releaseAsyncOperation(self.device.?, io);
            self.result_pin_held = false;
            if (self.pin_held) native_async.releaseAsyncOperation(self.device.?, io);
            self.pin_held = false;
            self.device = null;
        }
        const operations: registry_mod.Cell(Self).Operations = .{
            .invoke = invoke,
            .dispose = dispose,
            .shut_down = shutDown,
            .deinit = deinit,
        };
    };
}

fn startPin(device: *Device, io: Io) api.AsyncStartError!void {
    device.acquireOperation(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.ResourceInUse => error.ReferenceCountOverflow,
        else => error.OwnerStopped,
    };
}
fn rawSize(size: usize) u64 {
    return if (size == api.WholeMapSize) raw.whole_map_size else @intCast(size);
}
fn prepare(
    comptime kind: Kind,
    device: *Device,
    allocator: Allocator,
    io: Io,
    buffer: ?*resources.Buffer,
    mode: api.MapMode,
    offsets: api.Buffer.MapAsyncOffsetOptions,
    callback_info: if (kind == .map) ?api.BufferMapCallbackInfo else ?api.QueueWorkDoneCallbackInfo,
) api.AsyncStartError!*registry_mod.Cell(Context(kind)) {
    const registry = try native_async.ensureRegistered(device, allocator, io);
    if (device.native == null) return error.InvalidOwner;
    var context: Context(kind) = .{ .device = device, .buffer = buffer, .mode = mode, .offsets = offsets, .callback_info = callback_info, .reservation = try core.ErrorReservation.prepare(allocator) };
    errdefer context.deinit(allocator, io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        device.bindObjectsLocked(&guard, allocator) catch return error.InvalidOwner;
        if (buffer) |resource| {
            handles.validateResourceLocked(device, &guard, &resource.header, .native_buffer) catch return error.InvalidOwner;
            if (resource.native.map_generation == std.math.maxInt(u64)) return error.InvalidRequest;
            resource.header.retainLeaseLocked(&guard) catch return error.ReferenceCountOverflow;
            context.buffer_lease = true;
        }
        context.scope = device.core.captureScopeLeaseSet(allocator, &guard, .all) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeReferenceCountOverflow => error.ReferenceCountOverflow,
            else => error.InvalidOwner,
        };
    }
    context.reservation.reserveReferences(context.scope.?.errorQuota()) catch return error.ReferenceCountOverflow;
    return registry.prepare(Context(kind), io, context, Context(kind).operations, .{
        .mode = if (callback_info) |info| info.mode else .wait_any_only,
        .callback = callback_info != null,
        .owner = native_async.ownerBinding(device),
    });
}

fn begin(comptime kind: Kind, cell: *registry_mod.Cell(Context(kind)), io: Io) api.AsyncStartError!api.Future {
    const context = &cell.context;
    const device = context.device.?;
    const native = device.native.?;
    try native.queue_operation_mutex.lock(io);
    {
        defer native.queue_operation_mutex.unlock(io);
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        if (!native.accepting_operations) return error.OwnerStopped;
        if (kind == .map) {
            const buffer = context.buffer.?;
            handles.validateResourceLocked(device, &guard, &buffer.header, .native_buffer) catch return error.InvalidOwner;
            context.generation = buffer.native.beginMap(.{ .mode = context.mode, .offset = @intCast(context.offsets.offset), .size = rawSize(context.offsets.size), .submitted_usage_serial = buffer.accepted_usage_serial }) catch |err| blk: {
                if (err == error.MapGenerationExhausted) return error.InvalidRequest;
                context.validation_error = err;
                context.status = .failure;
                break :blk null;
            };
            context.target_serial = buffer.accepted_usage_serial;
        } else context.target_serial = native.queue.timeline.lastSubmittedSerial();
    }
    device.lifecycle_mutex.lockUncancelable(io);
    defer device.lifecycle_mutex.unlock(io);
    try native_async.acquireAsyncOperationLocked(device);
    context.pin_held = true;
    errdefer {
        context.pin_held = false;
        native_async.releaseAsyncOperationLocked(device);
    }
    if (kind == .map and context.callback_info == null) {
        try native_async.acquireAsyncOperationLocked(device);
        context.result_pin_held = true;
    }
    errdefer if (context.result_pin_held) {
        context.result_pin_held = false;
        native_async.releaseAsyncOperationLocked(device);
    };
    return cell.header.registry.accept(io, &cell.header, Runner(kind).post);
}

fn stopped(device: *Device, io: Io) bool {
    device.lifecycle_mutex.lockUncancelable(io);
    defer device.lifecycle_mutex.unlock(io);
    return device.destroying or device.state != .alive or !device.async_state.source_callbacks_open;
}
fn observeSerial(
    device: *Device,
    io: Io,
    serial: platform.Serial,
    buffer: ?*resources.Buffer,
    generation: ?u64,
) ObservationError!platform.Serial {
    for (0..fence_observation_retry_bound) |_| {
        if (buffer) |resource| {
            var guard = core.ObjectGuard.lockUncancelable(io, resource.header.tracking);
            const aborted = resource.header.state != .alive or
                resource.native.state != .pending_map or resource.native.map_generation != generation.?;
            guard.unlock(io);
            if (aborted) return error.MapAborted;
        }
        if (stopped(device, io)) return error.ObservationStopped;
        return device.native.?.waitSerialObservation(io, serial, fence_observation_timeout_ns) catch |err| switch (err) {
            error.FenceWaitTimedOut, error.WaitIterationExhausted => continue,
            error.DeviceLost => {
                native_async.finishLoss(device, device.core.arena.memory.child_allocator, io, .unknown, "Vulkan device lost.");
                return err;
            },
            else => return err,
        };
    }
    return error.FenceObservationExhausted;
}
fn Runner(comptime kind: Kind) type {
    return struct {
        fn post(header: *registry_mod.Header, io: Io) api.AsyncStartError!void {
            const cell: *registry_mod.Cell(Context(kind)) = @fieldParentPtr("header", header);
            try native_async.post(cell.context.device.?, io, .{ .run = run, .context = cell });
        }
        fn run(io: Io, pointer: *anyopaque) void {
            const cell: *registry_mod.Cell(Context(kind)) = @ptrCast(@alignCast(pointer));
            const registry = cell.header.registry;
            // Posting precedes commit. Synchronize with the accepting registry transaction.
            registry.mutex.lockUncancelable(io);
            registry.mutex.unlock(io);
            const context = &cell.context;
            const device = context.device.?;
            var completed: platform.Serial = 0;
            var wait_error: ?ObservationError = null;
            if (context.status == .pending) completed = observeSerial(device, io, context.target_serial, if (kind == .map) context.buffer else null, context.generation) catch |err| blk: {
                wait_error = err;
                break :blk 0;
            };
            if (wait_error == null and stopped(device, io)) {
                context.validation_error = null;
                context.status = .shut_down;
            }
            if (!registry.beginFinish(io, &cell.header)) {
                registry.release(io, &cell.header, .runner) catch unreachable;
                return;
            }
            if (context.validation_error) |err| {
                context.failure = context.reservation.sealNativeError(.{ .validation = error.StaleHandle }, err);
                context.validation_error = null;
            }
            if (context.status == .pending) {
                if (wait_error) |err| {
                    if (err == error.MapAborted) context.status = .aborted else if (err == error.ObservationStopped or err == error.Canceled) context.status = .shut_down else {
                        const code: core.ErrorCode = if (err == error.DeviceLost)
                            .{ .device_lost = error.DeviceLost }
                        else
                            .{ .unrecoverable = error.InternalInvariantViolated };
                        context.failure = context.reservation.sealNativeError(code, err);
                        context.status = .failure;
                    }
                } else if (kind == .map) {
                    const buffer = context.buffer.?;
                    var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
                    if (buffer.header.state != .alive) context.status = .aborted else {
                        const completion = buffer.native.completeMap(context.generation.?, completed) catch |err| blk: {
                            context.failure = context.reservation.sealNativeError(.{ .unrecoverable = error.InternalInvariantViolated }, err);
                            context.status = .failure;
                            break :blk raw.Buffer.MapCompletion.aborted;
                        };
                        if (context.status != .failure) {
                            context.status = if (completion == .mapped) .success else .aborted;
                            if (completion == .mapped) {
                                context.generation = null;
                                if (context.callback_info == null) {
                                    buffer.adoptMappingLeaseLocked(&guard);
                                    const writable = if (context.mode.write) buffer.native.getMappedRange(@intCast(context.offsets.offset), rawSize(context.offsets.size)) catch unreachable else null;
                                    const bytes: []const u8 = if (writable) |span| span else buffer.native.getConstMappedRange(@intCast(context.offsets.offset), rawSize(context.offsets.size)) catch unreachable;
                                    context.native_result = .{ .bytes = bytes, .writable_bytes = writable, .device = device, .buffer = buffer };
                                    context.buffer_lease = false;
                                    context.buffer = null;
                                }
                            }
                        }
                    }
                    guard.unlock(io);
                } else context.status = .success;
            }
            context.releaseBuffer(io);
            if (context.native_result != null) {
                device.lifecycle_mutex.lockUncancelable(io);
                std.debug.assert(context.result_pin_held);
                // Convert only before destructive admission closes the same high gate.
                const can_transfer = device.state == .alive and !device.destroying and
                    device.async_state.source_callbacks_open;
                if (can_transfer) {
                    std.debug.assert(device.active_async_operations != 0);
                    device.active_async_operations -= 1;
                    context.result_pin_held = false;
                }
                device.lifecycle_mutex.unlock(io);
                if (!can_transfer) {
                    const result = context.native_result.?;
                    context.native_result = null;
                    var guard = core.ObjectGuard.lockUncancelable(io, result.buffer.?.header.tracking);
                    result.buffer.?.releaseMappingLeaseLocked(&guard, io);
                    guard.unlock(io);
                    context.status = .shut_down;
                }
            }
            if (context.result_pin_held) {
                native_async.releaseAsyncOperation(device, io);
                context.result_pin_held = false;
            }
            context.settle(io);
            registry.publish(io, &cell.header, context.native_result != null);
            device.lifecycle_mutex.lockUncancelable(io);
            context.device = null;
            if (context.pin_held) native_async.releaseAsyncOperationLocked(device);
            context.pin_held = false;
            device.async_condition.broadcast(io);
            device.lifecycle_mutex.unlock(io);
            // Publication may invoke callbacks. Runner is retained through the final cell access.
            registry.release(io, &cell.header, .runner) catch unreachable;
        }
    };
}

pub fn mapAsync(
    handle: api.Buffer,
    allocator: Allocator,
    io: Io,
    mode: api.MapMode,
    offsets: api.Buffer.MapAsyncOffsetOptions,
    info: api.BufferMapCallbackInfo,
) api.AsyncStartError!api.Future {
    const header = try handles.resourceHeader(api.Buffer, handle, .native_buffer);
    const device = try handles.resourceOwner(header);
    try startPin(device, io);
    defer device.releaseOperation(io);
    const buffer: *resources.Buffer = @fieldParentPtr("header", header);
    const cell = try prepare(.map, device, allocator, io, buffer, mode, offsets, info);
    errdefer cell.header.registry.rollback(io, &cell.header);
    return begin(.map, cell, io);
}
pub fn mapAsyncProc(
    handle: api.Buffer,
    allocator: Allocator,
    io: Io,
    mode: api.MapMode,
    offset: usize,
    size: usize,
    info: api.BufferMapCallbackInfo,
) api.AsyncStartError!api.Future {
    return mapAsync(handle, allocator, io, mode, .{ .offset = offset, .size = size }, info);
}
pub fn onSubmittedWorkDone(
    handle: api.Queue,
    allocator: Allocator,
    io: Io,
    info: api.QueueWorkDoneCallbackInfo,
) api.AsyncStartError!api.Future {
    const device = try handles.resolveQueue(handle);
    try startPin(device, io);
    defer device.releaseOperation(io);
    const cell = try prepare(.queue, device, allocator, io, null, .{}, .{ .offset = 0, .size = 0 }, info);
    errdefer cell.header.registry.rollback(io, &cell.header);
    return begin(.queue, cell, io);
}

fn Outcome(comptime kind: Kind) type {
    return if (kind == .map) NativeMapOutcome else NativeQueueOutcome;
}
fn Observer(comptime kind: Kind) type {
    return struct {
        fn run(io: Io, cell: *registry_mod.Cell(Context(kind)), reserved: core.ErrorReservation) Outcome(kind) {
            var reservation = reserved;
            defer reservation.discard();
            const registry = cell.header.registry;
            registry.waitReady(io, &cell.header) catch |err| {
                registry.cancelObserver(io, &cell.header);
                if (err == error.Canceled) return .canceled;
                return .{ .failure = reservation.sealNativeError(.{ .unrecoverable = error.InternalInvariantViolated }, err) };
            };
            if (!registry.claimConsumer(io, &cell.header)) {
                registry.cancelObserver(io, &cell.header);
                return .canceled;
            }
            const context = &cell.context;
            const outcome: Outcome(kind) = switch (context.status) {
                .success => if (kind == .map) blk: {
                    const result = context.native_result.?;
                    context.native_result = null;
                    break :blk .{ .success = result };
                } else .success,
                .failure => blk: {
                    const failure = context.failure.?;
                    context.failure = null;
                    break :blk .{ .failure = failure };
                },
                .aborted => if (kind == .map) .aborted else unreachable,
                .shut_down => .shut_down,
                else => unreachable,
            };
            context.status = .transferred;
            registry.finishConsumer(io, &cell.header);
            registry.release(io, &cell.header, .observer) catch unreachable;
            return outcome;
        }
    };
}
fn startNative(
    comptime kind: Kind,
    device: *Device,
    allocator: Allocator,
    io: Io,
    buffer: ?*resources.Buffer,
    mode: api.MapMode,
    offsets: api.Buffer.MapAsyncOffsetOptions,
) api.AsyncStartError!Io.Future(Outcome(kind)) {
    try startPin(device, io);
    defer device.releaseOperation(io);
    const cell = try prepare(kind, device, allocator, io, buffer, mode, offsets, null);
    const registry = cell.header.registry;
    errdefer registry.rollback(io, &cell.header);
    var reservation = try core.ErrorReservation.prepare(allocator);
    errdefer reservation.discard();
    registry.retain(io, &cell.header, .observer) catch return error.ReferenceCountOverflow;
    var future = io.concurrent(Observer(kind).run, .{ io, cell, reservation }) catch {
        registry.release(io, &cell.header, .observer) catch unreachable;
        return error.ConcurrencyUnavailable;
    };
    reservation.node = null;
    errdefer switch (future.cancel(io)) {
        .failure => |failure| failure.release(),
        .canceled => {},
        else => unreachable,
    };
    _ = try begin(kind, cell, io);
    return future;
}
pub fn mapAsyncNative(
    device: *Device,
    allocator: Allocator,
    io: Io,
    buffer: *resources.Buffer,
    mode: api.MapMode,
    offsets: api.Buffer.MapAsyncOffsetOptions,
) api.AsyncStartError!Io.Future(NativeMapOutcome) {
    return startNative(.map, device, allocator, io, buffer, mode, offsets);
}
pub fn onSubmittedWorkDoneNative(device: *Device, allocator: Allocator, io: Io) api.AsyncStartError!Io.Future(NativeQueueOutcome) {
    return startNative(.queue, device, allocator, io, null, .{}, .{ .offset = 0, .size = 0 });
}

/// Caller holds Device lifecycle and the registry's exclusive detach reservation.
/// Static vtable identity is checked before recovering typed context.
pub fn detachDeviceContextLocked(header: *registry_mod.Header, device: *Device) bool {
    inline for (.{ Kind.map, Kind.queue }) |kind| {
        const T = Context(kind);
        if (registry_mod.Cell(T).matchesOperations(header, T.operations)) {
            const cell: *registry_mod.Cell(T) = @fieldParentPtr("header", header);
            const context = &cell.context;
            std.debug.assert((context.device == null or context.device == device) and
                context.scope == null and context.buffer == null and context.native_result == null);
            if (context.pin_held) native_async.releaseAsyncOperationLocked(device);
            context.pin_held = false;
            context.device = null;
            return true;
        }
    }
    return false;
}
