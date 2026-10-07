//! Generated scope-pop and compilation-info delivery use the real completion cells.
//! No scope waiter thread, borrowed diagnostic storage, or secondary owner ledger.
const std = @import("std");
const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const registry = @import("async_registry.zig");
const owner = @import("native_async_device.zig");
const handles = @import("native_async_handles.zig");
const resources = @import("native_resources.zig");
const shader = @import("../pipeline/shader_module.zig");
const Device = @import("device.zig").Device;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Owns copied message text and projected records. Views borrow these allocations,
/// never the address of this value, so moving an Io Future result is safe.
pub const OwnedCompilationInfo = struct {
    messages: shader.Messages,
    records: []api.descriptors.CompilationMessageChain,

    fn clone(allocator: Allocator, source: *const shader.ShaderModule) Allocator.Error!OwnedCompilationInfo {
        const messages = try shader.snapshotCompilationInfo(allocator, source);
        errdefer messages.deinit();
        const records = try allocator.alloc(api.descriptors.CompilationMessageChain, messages.items.len);
        for (messages.items, records) |message, *record| record.* = .{
            .message = message.text,
            .type_ = switch (message.type_) {
                .error_ => .error_,
                .warning => .warning,
                .info => .info,
            },
            .line_num = message.line_num,
            .line_pos = message.line_pos_in_bytes,
            .offset = message.offset_in_bytes,
            .length = message.length_in_bytes,
            .dawn_compilation_message_utf16 = .{
                .line_pos = message.line_pos_in_utf16,
                .offset = message.offset_in_utf16,
                .length = message.length_in_utf16,
            },
        };
        return .{ .messages = messages, .records = records };
    }
    pub fn view(self: *const OwnedCompilationInfo) api.descriptors.CompilationInfoChain {
        return .{ .message_count = self.records.len, .messages = if (self.records.len == 0) null else self.records };
    }
    pub fn deinit(self: *OwnedCompilationInfo) void {
        self.messages.allocator.free(self.records);
        self.records = &.{};
        self.messages.deinit();
        self.messages = .{ .allocator = self.messages.allocator, .items = &.{} };
    }
};

pub const NativeInfoResult = union(enum) {
    success: OwnedCompilationInfo,
    canceled,
    /// Observer failures are not shader compilation failures and are never
    /// projected into the generated two-status callback domain.
    failure: core.ErrorRef,
    pub fn deinit(self: *NativeInfoResult) void {
        switch (self.*) {
            .success => |*info| info.deinit(),
            .failure => |ref| ref.release(),
            .canceled => {},
        }
        self.* = .canceled;
    }
};

pub const NativePopResult = struct {
    status: api.PopErrorScopeStatus,
    error_ref: ?core.ErrorRef = null,
    pub fn message(self: *const NativePopResult) []const u8 {
        return if (self.error_ref) |ref| ref.view().message else "";
    }
    pub fn errorType(self: *const NativePopResult) api.ErrorType {
        if (self.status != .success) return .no_error;
        return if (self.error_ref) |ref| errorTypeFromCode(ref.view().code) else .no_error;
    }
    pub fn deinit(self: *NativePopResult) void {
        if (self.error_ref) |ref| ref.release();
        self.error_ref = null;
    }
};

fn errorTypeFromCode(code: core.ErrorCode) api.ErrorType {
    return switch (code) {
        .validation => .validation,
        .device_lost => .internal,
        .unrecoverable => |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => .out_of_memory,
            else => .internal,
        },
    };
}
fn release(header: *registry.Header, io: Io, kind: registry.ReferenceKind) void {
    header.registry.release(io, header, kind) catch @panic("scope/info actor lost its reference");
}
fn pin(device: *Device, io: Io) api.AsyncStartError!void {
    device.acquireOperation(io) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return error.OwnerStopped;
    };
}
fn releaseDevice(slot: *?*Device, io: Io) void {
    const device = slot.* orelse return;
    device.lifecycle_mutex.lockUncancelable(io);
    slot.* = null;
    owner.releaseAsyncOperationLocked(device);
    device.async_condition.broadcast(io);
    device.lifecycle_mutex.unlock(io);
}

const InfoContext = struct {
    device: ?*Device = null,
    callback: ?api.CompilationInfoCallbackInfo,
    info: ?OwnedCompilationInfo,
    canceled: bool = false,
    fn invoke(self: *InfoContext, _: Io) void {
        const callback = self.callback.?;
        const empty: api.descriptors.CompilationInfoChain = .{ .message_count = 0 };
        if (self.canceled) {
            callback.callback(callback.userdata, .callback_cancelled, &empty);
        } else {
            const view = self.info.?.view();
            callback.callback(callback.userdata, .success, &view);
        }
    }
    fn dispose(self: *InfoContext, _: Io) void {
        if (self.info) |*info| info.deinit();
        self.info = null;
    }
    fn shutdown(self: *InfoContext, _: Io) void {
        self.canceled = true;
    }
    fn deinit(self: *InfoContext, _: Allocator, io: Io) void {
        self.dispose(io);
        releaseDevice(&self.device, io);
    }
};
const info_ops: registry.Cell(InfoContext).Operations = .{
    .invoke = InfoContext.invoke,
    .dispose = InfoContext.dispose,
    .shut_down = InfoContext.shutdown,
    .deinit = InfoContext.deinit,
};

fn prepareInfo(device: *Device, header: *core.Object, allocator: Allocator, io: Io, callback: ?api.CompilationInfoCallbackInfo) api.AsyncStartError!*registry.Cell(InfoContext) {
    try pin(device, io);
    defer device.releaseOperation(io);
    const completions = try owner.ensureRegistered(device, allocator, io);
    const copied = blk: {
        var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
        defer guard.unlock(io);
        device.bindObjectsLocked(&guard, allocator) catch return error.InvalidOwner;
        handles.validateResourceHostLocked(device, &guard, header, .shader_module) catch return error.InvalidOwner;
        if (header.state != .alive and header.state != .failed) return error.InvalidOwner;
        if (!header.isInitialized(&guard)) return error.InvalidOwner;
        const module: *resources.ShaderModule = @fieldParentPtr("header", header);
        // A failed initialized host owns real diagnostics, not a live GPU payload.
        if ((header.state == .failed) != module.native.failed) return error.InvalidOwner;
        header.retainLeaseLocked(&guard) catch return error.InvalidOwner;
        defer header.releaseLeaseLocked(&guard, io);
        break :blk try OwnedCompilationInfo.clone(allocator, &module.native);
    };
    var context: InfoContext = .{ .callback = callback, .info = copied };
    errdefer context.dispose(io);
    const cell = try completions.prepare(InfoContext, io, context, info_ops, .{
        .mode = if (callback) |info| info.mode else .wait_any_only,
        .callback = callback != null,
        .owner = owner.ownerBinding(device),
        .owner_identity = device.async_state.owner_identity,
    });
    return cell;
}
fn postInfo(header: *registry.Header, io: Io) api.AsyncStartError!void {
    const cell: *registry.Cell(InfoContext) = @fieldParentPtr("header", header);
    try owner.post(cell.context.device.?, io, .{ .context = cell, .run = runInfo });
}
fn runInfo(io: Io, opaque_cell: *anyopaque) void {
    const cell: *registry.Cell(InfoContext) = @ptrCast(@alignCast(opaque_cell));
    const header = &cell.header;
    if (header.registry.beginFinish(io, header)) {
        header.registry.publish(io, header, false);
        releaseDevice(&cell.context.device, io);
    }
    release(header, io, .runner);
}
fn admitInfo(device: *Device, cell: *registry.Cell(InfoContext), io: Io) api.AsyncStartError!api.Future {
    try device.lifecycle_mutex.lock(io);
    defer device.lifecycle_mutex.unlock(io);
    try owner.acquireAsyncOperationLocked(device);
    cell.context.device = device;
    errdefer {
        cell.context.device = null;
        owner.releaseAsyncOperationLocked(device);
    }
    return cell.header.registry.accept(io, &cell.header, postInfo);
}

/// Exact generated ShaderModule.getCompilationInfo method and ProcTable adapter.
pub fn getCompilationInfo(handle: api.ShaderModule, allocator: Allocator, io: Io, callback: api.CompilationInfoCallbackInfo) api.AsyncStartError!api.Future {
    const header = try handles.resourceHeader(api.ShaderModule, handle, .shader_module);
    const device = try handles.resourceOwner(header);
    const cell = try prepareInfo(device, header, allocator, io, callback);
    errdefer cell.header.registry.rollback(io, &cell.header);
    return admitInfo(device, cell, io);
}

fn observerDiagnostic(reservation: *core.ErrorReservation, failure: anytype) core.ErrorRef {
    return reservation.sealNativeError(.{ .unrecoverable = error.InternalInvariantViolated }, failure);
}
fn observeInfo(io: Io, cell: *registry.Cell(InfoContext), prepared: core.ErrorReservation) NativeInfoResult {
    var reservation = prepared;
    defer reservation.discard();
    const header = &cell.header;
    const completions = header.registry;
    completions.waitReady(io, header) catch |err| {
        completions.cancelObserver(io, header);
        return if (err == error.Canceled) .canceled else .{ .failure = observerDiagnostic(&reservation, err) };
    };
    if (!completions.claimConsumer(io, header)) {
        completions.cancelObserver(io, header);
        return .canceled;
    }
    const result: NativeInfoResult = if (cell.context.canceled) .canceled else .{ .success = cell.context.info.? };
    if (!cell.context.canceled) cell.context.info = null;
    completions.finishConsumer(io, header);
    release(header, io, .observer);
    return result;
}

/// The same snapshot/cell, with one native consumer and no callback registration.
pub fn getCompilationInfoAsync(device: *Device, module: *resources.ShaderModule, allocator: Allocator, io: Io) api.AsyncStartError!Io.Future(NativeInfoResult) {
    const cell = try prepareInfo(device, &module.header, allocator, io, null);
    const header = &cell.header;
    errdefer header.registry.rollback(io, header);
    var reservation = try core.ErrorReservation.prepare(allocator);
    errdefer reservation.discard();
    header.registry.retain(io, header, .observer) catch return error.ReferenceCountOverflow;
    var future = io.concurrent(observeInfo, .{ io, cell, reservation }) catch {
        release(header, io, .observer);
        return error.ConcurrencyUnavailable;
    };
    reservation.node = null;
    errdefer {
        var result = future.cancel(io);
        result.deinit();
    }
    _ = try admitInfo(device, cell, io);
    return future;
}

const PopContext = struct {
    device: ?*Device = null,
    callback: ?api.PopErrorScopeCallbackInfo,
    error_reservation: core.ErrorReservation,
    ticket: ?core.ScopeTicket = null,
    binding: ?core.OwnedScopeBinding = null,
    result: ?NativePopResult = null,

    fn invoke(self: *PopContext, _: Io) void {
        const callback = self.callback.?;
        const result = &self.result.?;
        callback.callback(callback.userdata, result.status, result.errorType(), result.message());
    }
    fn dispose(self: *PopContext, _: Io) void {
        if (self.result) |*result| result.deinit();
        self.result = null;
    }
    fn shutdown(self: *PopContext, _: Io) void {
        // Live binding/runner owners prevent registry.close from entering this
        // path. It applies only to an already host-only unowned terminal cell.
        std.debug.assert(self.ticket == null and self.binding == null);
        if (self.result) |*result| result.deinit();
        self.result = .{ .status = .callback_cancelled };
    }
    fn deinit(self: *PopContext, _: Allocator, io: Io) void {
        std.debug.assert(self.ticket == null and self.binding == null);
        self.dispose(io);
        self.error_reservation.discard();
        releaseDevice(&self.device, io);
    }
};
const pop_ops: registry.Cell(PopContext).Operations = .{
    .invoke = PopContext.invoke,
    .dispose = PopContext.dispose,
    .shut_down = PopContext.shutdown,
    .deinit = PopContext.deinit,
};

const PreparedPop = struct {
    cell: *registry.Cell(PopContext),
    binding: core.PreparedScopeBinding,

    fn rollback(self: *PreparedPop, io: Io) void {
        const header = &self.cell.header;
        // The reservation owns a genuine staging observer reference. Its core
        // destructor releases that right before the sole prepared primary.
        self.binding.deinit(io);
        header.registry.rollback(io, header);
    }
};

fn preparePop(device: *Device, allocator: Allocator, io: Io, callback: ?api.PopErrorScopeCallbackInfo) api.AsyncStartError!PreparedPop {
    try pin(device, io);
    defer device.releaseOperation(io);
    const completions = try owner.ensureRegistered(device, allocator, io);
    var reservation = try core.ErrorReservation.prepare(allocator);
    errdefer reservation.discard();
    const cell = try completions.prepare(PopContext, io, .{
        .callback = callback,
        .error_reservation = reservation,
    }, pop_ops, .{
        .mode = if (callback) |info| info.mode else .wait_any_only,
        .callback = callback != null,
        .owner = owner.ownerBinding(device),
        .owner_identity = device.async_state.owner_identity,
    });
    reservation.node = null;
    errdefer completions.rollback(io, &cell.header);
    completions.retain(io, &cell.header, .observer) catch return error.ReferenceCountOverflow;
    errdefer release(&cell.header, io, .observer);
    const binding = core.prepareBinding(allocator, .{
        .context = cell,
        .notify_callback = notifyPop,
        .release_context_callback = releasePopBinding,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AllocatorMismatch => return error.InvalidOwner,
        error.ScopeReferenceCountOverflow => return error.ReferenceCountOverflow,
        error.ScopeBindingExists => return error.InvalidRequest,
    };
    return .{ .cell = cell, .binding = binding };
}

fn admitPop(device: *Device, prepared: *PreparedPop, io: Io) api.AsyncStartError!api.Future {
    const cell = prepared.cell;
    device.lifecycle_mutex.lock(io) catch return error.Canceled;
    errdefer device.lifecycle_mutex.unlock(io);
    try owner.acquireAsyncOperationLocked(device);
    cell.context.device = device;
    errdefer {
        cell.context.device = null;
        owner.releaseAsyncOperationLocked(device);
    }
    const future = try cell.header.registry.accept(io, &cell.header, null);
    device.lifecycle_mutex.unlock(io);
    // No fallible storage, posting, or reference acquisition follows admission.
    // Selection/pop occurs under the original guard within this call. Until
    // activation, settlement cannot claim the dormant prepared binding.
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    const popped = device.core.popBoundErrorScope(&guard, &prepared.binding) catch |err| {
        guard.unlock(io);
        if (!cell.header.registry.beginFinish(io, &cell.header))
            @panic("accepted scope error lost its only finisher");
        cell.context.result = .{
            .status = .error_,
            .error_ref = cell.context.error_reservation.sealNativeError(.{ .validation = error.StaleHandle }, err),
        };
        // No record was removed. The unbound reservation's final context drop
        // publishes the owned semantic error and releases both real actors.
        prepared.binding.deinit(io);
        return future;
    };
    cell.context.ticket = popped.ticket;
    cell.context.binding = popped.binding;
    const activation = popped.binding;
    guard.unlock(io);
    activation.notifyReady(io);
    return future;
}

fn notifyPop(io: Io, context: *anyopaque) void {
    const cell: *registry.Cell(PopContext) = @ptrCast(@alignCast(context));
    const header = &cell.header;
    if (!header.registry.beginFinish(io, header)) return;
    const device = cell.context.device.?;
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    var result = cell.context.ticket.?.take(&guard) catch
        @panic("claimed ready scope notification did not own a ready ticket");
    cell.context.ticket = null;
    cell.context.result = .{ .status = .success, .error_ref = result.error_ref };
    result.error_ref = null;
    var cleanup = cell.context.binding.?.deinit(&guard);
    cell.context.binding = null;
    guard.unlock(io);
    cleanup.dispatch(io);
    // The core claimed notification still owns its node/context right through
    // this return. Its final post-guard reclaim calls releasePopBinding.
}

fn releasePopBinding(io: Io, context: *anyopaque) void {
    const cell: *registry.Cell(PopContext) = @ptrCast(@alignCast(context));
    const header = &cell.header;
    const completions = header.registry;
    if (cell.context.result != null) {
        std.debug.assert(cell.context.ticket == null and cell.context.binding == null);
        // Every core binding/record/settlement pin is gone at this point.
        // Keep the actual Device pin through publication/callback claim.
        completions.publish(io, header, false);
        releaseDevice(&cell.context.device, io);
        release(header, io, .observer);
        release(header, io, .runner);
    } else {
        // Unaccepted reservation rollback owns only its staging observer.
        release(header, io, .observer);
    }
}

/// Exact generated Device.popErrorScope adapter. An empty stack is an accepted
/// status.error_ with an owned prepaid diagnostic, not a failed API start.
pub fn popErrorScope(handle: api.Device, allocator: Allocator, io: Io, callback: api.PopErrorScopeCallbackInfo) api.AsyncStartError!api.Future {
    const device = try handles.resolveDevice(handle);
    var prepared = try preparePop(device, allocator, io, callback);
    errdefer prepared.rollback(io);
    return admitPop(device, &prepared, io);
}

fn observePop(io: Io, cell: *registry.Cell(PopContext), prepared_error: core.ErrorReservation) NativePopResult {
    var reservation = prepared_error;
    defer reservation.discard();
    const header = &cell.header;
    const completions = header.registry;
    completions.waitReady(io, header) catch |err| {
        completions.cancelObserver(io, header);
        return if (err == error.Canceled) .{ .status = .callback_cancelled } else .{
            .status = .error_,
            .error_ref = observerDiagnostic(&reservation, err),
        };
    };
    if (!completions.claimConsumer(io, header)) {
        completions.cancelObserver(io, header);
        return .{ .status = .callback_cancelled };
    }
    const result = cell.context.result.?;
    cell.context.result = null; // Move the one core ScopeResult reference.
    completions.finishConsumer(io, header);
    release(header, io, .observer);
    return result;
}

/// Native observation of the very same pop cell; cancel abandons observation,
/// never accepted scope work. The caller deinitializes the returned result.
pub fn popErrorScopeAsync(device: *Device, allocator: Allocator, io: Io) api.AsyncStartError!Io.Future(NativePopResult) {
    var prepared = try preparePop(device, allocator, io, null);
    errdefer prepared.rollback(io);
    const header = &prepared.cell.header;
    var reservation = try core.ErrorReservation.prepare(allocator);
    errdefer reservation.discard();
    header.registry.retain(io, header, .observer) catch return error.ReferenceCountOverflow;
    var future = io.concurrent(observePop, .{ io, prepared.cell, reservation }) catch {
        release(header, io, .observer);
        return error.ConcurrencyUnavailable;
    };
    reservation.node = null;
    errdefer {
        var result = future.cancel(io);
        result.deinit();
    }
    _ = try admitPop(device, &prepared, io);
    return future;
}

/// Caller holds Device's real lifecycle gate and the registry's exclusive
/// beginOwnerDetach reservation. Match the static operations before typed cast.
pub fn detachDeviceContextLocked(header: *registry.Header, device: *Device) bool {
    if (registry.Cell(InfoContext).matchesOperations(header, info_ops)) {
        const cell: *registry.Cell(InfoContext) = @fieldParentPtr("header", header);
        if (cell.context.device) |actual| {
            std.debug.assert(actual == device);
            cell.context.device = null;
            owner.releaseAsyncOperationLocked(device);
        }
        return true;
    }
    if (registry.Cell(PopContext).matchesOperations(header, pop_ops)) {
        const cell: *registry.Cell(PopContext) = @fieldParentPtr("header", header);
        std.debug.assert(cell.context.ticket == null and cell.context.binding == null);
        if (cell.context.device) |actual| {
            std.debug.assert(actual == device);
            cell.context.device = null;
            owner.releaseAsyncOperationLocked(device);
        }
        return true;
    }
    return false;
}
