//! Async control state for the actual high Device. The existing lifecycle gate owns all pins.
//! The parent Instance owns registry/executor storage. This module stores no Io or native context.
const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const registry_mod = @import("async_registry.zig");
const root = @import("async_root_requests.zig");
const handles = @import("native_async_handles.zig");
const device_mod = @import("device.zig");
const instance_mod = @import("instance.zig");
const platform = @import("../platform/threads.zig");
const Device = device_mod.Device;
const Registry = registry_mod.CompletionRegistry;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnterError = @typeInfo(@typeInfo(@TypeOf(Registry.enterExternalDispatch)).@"fn".return_type.?).error_union.error_set;
pub const DispatchError = EnterError || api.ProcessEventsError;

/// Embedded state. Every pointer borrows a pinned real owner. Loss error owns one prepaid reference.
pub const State = struct {
    registry: ?*Registry = null,
    instance: ?*instance_mod.Instance = null,
    owner_identity: u64 = 0,
    lost_future: ?api.Future = null,
    loss_cell: ?*registry_mod.Cell(root.LossContext) = null,
    loss_error: ?core.ErrorRef = null,
    uncaptured_info: api.UncapturedErrorCallbackInfo = .{},
    logging_info: api.LoggingCallbackInfo = .{},
    source_callbacks_open: bool = false,
    /// First terminal event authority. Explicit destruction is not a backend fault.
    loss_won: bool = false,
    /// Derived drain classification. The LossContext owns the actual accepted pin.
    loss_pin_held: bool = false,
    dispatch_error: ?DispatchError = null,
    /// Owned high diagnostic when no loss node exists or a backend fault follows a terminal event.
    synchronous_loss_message: ?[]u8 = null,
};

fn ownerLock(device: *Device, io: Io) void {
    device.lifecycle_mutex.lockUncancelable(io);
}
fn ownerUnlock(device: *Device, io: Io) void {
    device.lifecycle_mutex.unlock(io);
}
fn ownerClaim(device: *Device, class: registry_mod.CallbackClass) bool {
    if (device.host_deinitialized) return false;
    if (class == .logging or class == .uncaptured_error) {
        if (!device.async_state.source_callbacks_open or device.destroying) return false;
    }
    if (device.active_operations == std.math.maxInt(usize) or
        device.active_callbacks == std.math.maxInt(u32)) return false;
    device.active_operations += 1;
    device.active_callbacks += 1;
    return true;
}
fn ownerEndClaim(device: *Device, _: registry_mod.CallbackClass) void {
    std.debug.assert(device.active_callbacks != 0);
    std.debug.assert(device.active_operations > device.active_async_operations);
    device.active_callbacks -= 1;
    device.active_operations -= 1;
}
/// Caller holds a real host pin. Hooks use the original high lifecycle mutex only.
pub fn ownerBinding(device: *Device) registry_mod.OwnerBinding {
    return bindingWithIdentity(device, device.async_state.owner_identity);
}
fn bindingWithIdentity(device: *Device, identity: u64) registry_mod.OwnerBinding {
    return registry_mod.OwnerBinding.bind(Device, identity, device, .{
        .lock = ownerLock,
        .unlock = ownerUnlock,
        .claim = ownerClaim,
        .end_claim = ownerEndClaim,
    });
}

/// Caller holds Instance then Device gates. Installs two real accepted pins, without allocation.
pub fn adoptRootCreationLocked(device: *Device, registry: *Registry, instance: *instance_mod.Instance, loss: *registry_mod.Cell(root.LossContext), future: api.Future, uncaptured: api.UncapturedErrorCallbackInfo) void {
    std.debug.assert(device.async_state.registry == null);
    std.debug.assert(device.active_operations == 0);
    std.debug.assert(device.active_async_operations == 0);
    std.debug.assert(future.id != 0);
    device.active_operations = 2;
    device.active_async_operations = 2;
    device.async_state = .{ .registry = registry, .instance = instance, .owner_identity = future.id, .lost_future = future, .loss_cell = loss, .uncaptured_info = uncaptured, .source_callbacks_open = true, .loss_pin_held = true };
    loss.context.device = device;
    loss.context.device_pin_held = true;
}
/// Retarget refusal returns both runner rights to Root. No high pointer or pin remains.
pub fn rollbackRootAdoptionLocked(device: *Device) void {
    const loss = device.async_state.loss_cell.?;
    loss.context.device = null;
    loss.context.device_pin_held = false;
    releaseLossOperationLocked(device);
    releaseAsyncOperationLocked(device);
    device.async_state = .{};
}

/// Prepares the actual parent's executor and loss registration at the final Device address.
/// Allocation/admission failure leaves no accepted operation or sequence for this Device.
pub fn ensureRegistered(device: *Device, allocator: Allocator, io: Io) api.AsyncStartError!*Registry {
    device.acquireOperation(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.ResourceInUse => return error.ReferenceCountOverflow,
        else => return error.OwnerStopped,
    };
    defer device.releaseOperation(io);
    const instance = device.adapter.instance;
    if (instance.future_namespace_source == null) return error.MissingFutureNamespaceSource;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        device.bindObjectsLocked(&guard, allocator) catch return error.InvalidOwner;
    }
    const registry = try instance.ensureRootAsync(allocator, io);
    device.lifecycle_mutex.lockUncancelable(io);
    if (device.async_state.registry) |registered| {
        device.lifecycle_mutex.unlock(io);
        std.debug.assert(registered == registry);
        return registered;
    }
    device.lifecycle_mutex.unlock(io);
    var reservation = try core.ErrorReservation.prepare(allocator);
    errdefer reservation.discard();
    reservation.reserveReferences(1) catch return error.ReferenceCountOverflow;
    const cell = try registry.prepare(root.LossContext, io, .{
        .callback_info = .{ .mode = .wait_any_only },
        .pending_instance = null,
        .error_reservation = reservation,
        .root_pin_held = false,
    }, root.loss_operations, .{ .mode = .wait_any_only, .callback = false, .owner = bindingWithIdentity(device, @as(u64, registry.namespace) << 32), .callback_class = .device_lost });
    reservation.node = null;
    var accepted = false;
    defer if (!accepted) registry.rollback(io, &cell.header);
    device.lifecycle_mutex.lockUncancelable(io);
    defer device.lifecycle_mutex.unlock(io);
    if (device.async_state.registry) |registered| return registered;
    if (device.state != .alive or device.destroying or device.host_deinitialized)
        return error.OwnerStopped;
    if (device.active_operations == std.math.maxInt(usize) or
        device.active_async_operations == std.math.maxInt(usize))
        return error.ReferenceCountOverflow;
    const future = try registry.acceptIdentityFromFuture(io, &cell.header, null);
    accepted = true;
    device.active_operations += 1;
    device.active_async_operations += 1;
    cell.context.device = device;
    cell.context.device_pin_held = true;
    device.async_state = .{ .registry = registry, .instance = instance, .owner_identity = future.id, .lost_future = future, .loss_cell = cell, .source_callbacks_open = true, .loss_pin_held = true };
    return registry;
}

/// Caller holds the high gate and has prepared every fallible request resource.
pub fn acquireAsyncOperationLocked(device: *Device) api.AsyncStartError!void {
    if (device.async_state.registry == null) return error.MissingFutureNamespaceSource;
    if (device.state != .alive or device.destroying or
        !device.async_state.source_callbacks_open) return error.OwnerStopped;
    if (device.active_operations == std.math.maxInt(usize) or
        device.active_async_operations == std.math.maxInt(usize))
        return error.ReferenceCountOverflow;
    device.active_operations += 1;
    device.active_async_operations += 1;
}
/// Consumes one exact accepted pin under the caller-held lifecycle gate.
pub fn releaseAsyncOperationLocked(device: *Device) void {
    std.debug.assert(device.active_async_operations != 0);
    std.debug.assert(device.active_operations >= device.active_async_operations);
    device.active_async_operations -= 1;
    device.active_operations -= 1;
}
/// Consumes one exact accepted pin after the actor's final owner access.
pub fn releaseAsyncOperation(device: *Device, io: Io) void {
    device.lifecycle_mutex.lockUncancelable(io);
    releaseAsyncOperationLocked(device);
    device.async_condition.broadcast(io);
    device.lifecycle_mutex.unlock(io);
}
/// Consumes the LossContext's pin and its derived drain classification under the high gate.
pub fn releaseLossOperationLocked(device: *Device) void {
    std.debug.assert(device.async_state.loss_pin_held);
    device.async_state.loss_pin_held = false;
    releaseAsyncOperationLocked(device);
}
/// Ends the exact loss host pin after callback/runner payload access ends.
pub fn releaseLossOperation(device: *Device, io: Io) void {
    device.lifecycle_mutex.lockUncancelable(io);
    releaseLossOperationLocked(device);
    device.async_condition.broadcast(io);
    device.lifecycle_mutex.unlock(io);
}
/// Posts to the existing parent executor with the exact submitted Io. Never initializes a pool.
/// Root publishes a started executor before adoption/registration. Its pointer is immutable while
/// the actual Device parent count is nonzero. No Instance gate is acquired under Device/registry.
pub fn post(device: *Device, io: Io, task: platform.Task) api.AsyncStartError!void {
    return root.postTask(device.async_state.instance.?, io, task);
}

/// Returns the stored ID even after callback delivery removed its registry entry. Allocates nothing.
pub fn getLostFuture(device: *Device, io: Io) api.CallbackControlError!api.Future {
    try device.lifecycle_mutex.lock(io);
    defer device.lifecycle_mutex.unlock(io);
    if (device.host_deinitialized) return error.DeviceNotAlive;
    if (device.adapter.instance.future_namespace_source == null)
        return error.MissingFutureNamespaceSource;
    return device.async_state.lost_future orelse error.DeviceNotAlive;
}
/// Exact generated Device.getLostFuture adapter.
pub fn getLostFutureApi(handle: api.Device, io: Io) api.CallbackControlError!api.Future {
    return getLostFuture(try handles.resolveDevice(handle), io);
}
/// Replaces the copied registration. An already-claimed old callback retains its userdata obligation.
pub fn setLoggingCallback(handle: api.Device, io: Io, info: api.LoggingCallbackInfo) api.CallbackControlError!void {
    const device = try handles.resolveDevice(handle);
    try device.lifecycle_mutex.lock(io);
    defer device.lifecycle_mutex.unlock(io);
    if (device.host_deinitialized or device.destroying or device.state != .alive)
        return error.DeviceNotAlive;
    if (device.adapter.instance.future_namespace_source == null)
        return error.MissingFutureNamespaceSource;
    if (device.async_state.registry == null) return error.DeviceNotAlive;
    if (!device.async_state.source_callbacks_open) return error.DeviceNotAlive;
    device.async_state.logging_info = info;
}
fn latchDispatchError(device: *Device, io: Io, failure: DispatchError) void {
    device.lifecycle_mutex.lockUncancelable(io);
    if (device.async_state.dispatch_error == null) device.async_state.dispatch_error = failure;
    device.lifecycle_mutex.unlock(io);
}
/// Consumes the first void-hook failure. High owning operations and final close report this channel.
pub fn takeDispatchError(device: *Device, io: Io) ?DispatchError {
    device.lifecycle_mutex.lockUncancelable(io);
    defer device.lifecycle_mutex.unlock(io);
    const failure = device.async_state.dispatch_error;
    device.async_state.dispatch_error = null;
    return failure;
}

/// Calls the current canonical log record on this thread with a real external-dispatch callback pin.
/// The message borrows through callback return. Reentry may replace, but cannot destroy, the owner.
pub fn emitLog(device: *Device, io: Io, kind: api.LoggingType, message: []const u8) DispatchError!void {
    device.lifecycle_mutex.lockUncancelable(io);
    const registry = device.async_state.registry orelse {
        device.lifecycle_mutex.unlock(io);
        return error.InvalidOwner;
    };
    if (!device.async_state.source_callbacks_open or device.destroying or device.host_deinitialized) {
        device.lifecycle_mutex.unlock(io);
        return error.OwnerStopped;
    }
    if (device.active_operations == std.math.maxInt(usize)) {
        device.lifecycle_mutex.unlock(io);
        return error.CallbackCapacityExceeded;
    }
    device.active_operations += 1;
    device.lifecycle_mutex.unlock(io);
    defer device.releaseOperation(io);
    var frame: registry_mod.DispatchFrame = .{};
    try registry.enterExternalDispatch(io, &frame, ownerBinding(device), .logging);
    device.lifecycle_mutex.lockUncancelable(io);
    const info = device.async_state.logging_info;
    device.lifecycle_mutex.unlock(io);
    if (info.callback) |callback| callback(info.userdata, kind, message);
    try registry.leaveExternalDispatch(io, &frame);
}

/// Actual owned-scope callback. Context is Root's final stable OwnedDevice, not a temporary high value.
/// The borrowed immutable view and canonical handle array are valid only through callback return.
pub fn coreUncaptured(_: Allocator, io: Io, context: *anyopaque, view: core.ErrorView) void {
    const owned: *root.OwnedDevice = @ptrCast(@alignCast(context));
    std.debug.assert(owned.high_initialized);
    const device = &owned.high;
    const registry = device.async_state.registry orelse {
        latchDispatchError(device, io, error.InvalidOwner);
        return;
    };
    var frame: registry_mod.DispatchFrame = .{};
    registry.enterExternalDispatch(io, &frame, ownerBinding(device), .uncaptured_error) catch |err| {
        latchDispatchError(device, io, err);
        return;
    };
    device.lifecycle_mutex.lockUncancelable(io);
    const info = device.async_state.uncaptured_info;
    device.lifecycle_mutex.unlock(io);
    if (info.callback) |callback| {
        const device_array = [_]api.Device{handles.exportDevice(device)};
        callback(info.userdata, &device_array, errorType(view), view.message);
    }
    registry.leaveExternalDispatch(io, &frame) catch |err| latchDispatchError(device, io, err);
}
fn errorType(view: core.ErrorView) api.ErrorType {
    return switch (view.code) {
        .validation => .validation,
        .device_lost => .internal,
        .unrecoverable => |err| switch (err) {
            error.OutOfDeviceMemory, error.OutOfHostMemory => .out_of_memory,
            error.PipelineUncategorized, error.InternalInvariantViolated, error.Unimplemented => .internal,
        },
    };
}

/// First Future event wins under the actual high gate. Backend fault recording remains independent.
/// User callbacks run outside locks. Later backend faults cannot replace either first diagnostic.
pub fn finishLoss(device: *Device, allocator: Allocator, io: Io, reason: api.DeviceLostReason, message: []const u8) void {
    device.lifecycle_mutex.lockUncancelable(io);
    if (device.host_deinitialized) {
        device.lifecycle_mutex.unlock(io);
        return;
    }
    const first_backend_fault = reason == .unknown and device.lost_reason == null;
    if (first_backend_fault) {
        device.lost_reason = .unknown;
        device.setDisconnectingIfAlive();
    }
    if (device.async_state.loss_won) {
        if (first_backend_fault) {
            recordBackendMessageLocked(device, allocator, io, message);
        } else {
            device.lifecycle_mutex.unlock(io);
        }
        return;
    }
    const cell = device.async_state.loss_cell;
    if (cell) |loss| {
        if (!loss.header.registry.beginFinish(io, &loss.header)) {
            if (first_backend_fault) {
                recordBackendMessageLocked(device, allocator, io, message);
            } else {
                device.lifecycle_mutex.unlock(io);
            }
            return;
        }
    }
    device.async_state.loss_won = true;
    device.setDisconnectingIfAlive();
    device.async_state.source_callbacks_open = false;
    device.async_state.loss_cell = null;
    std.debug.assert(device.active_operations < std.math.maxInt(usize));
    device.active_operations += 1;
    device.lifecycle_mutex.unlock(io);
    defer device.releaseOperation(io);
    if (cell) |loss| {
        const code: core.DeviceLostError = if (reason == .destroyed)
            error.DeviceDestroyed
        else
            error.DeviceLost;
        var draft = core.ErrorDraft.initMessage(allocator, .{ .device_lost = code }, message, &.{}) catch null;
        const sealed = if (draft) |*value| loss.context.error_reservation.seal(value) else loss.context.error_reservation.sealDeviceLostFallback(code);
        device.lifecycle_mutex.lockUncancelable(io);
        device.async_state.loss_error = sealed;
        if (reason == .unknown or device.lost_reason == null)
            device.lost_message = sealed.view().message;
        device.lifecycle_mutex.unlock(io);
        root.finishLossContext(loss, io, reason, sealed);
        loss.header.registry.release(io, &loss.header, .runner) catch
            @panic("Loss finisher lost its runner reference");
    } else {
        const copied = allocator.dupe(u8, message) catch null;
        device.lifecycle_mutex.lockUncancelable(io);
        const keep_message = reason == .unknown or device.lost_reason == null;
        if (keep_message) {
            device.async_state.synchronous_loss_message = copied;
            device.lost_message = copied orelse "Device lost";
        }
        device.lifecycle_mutex.unlock(io);
        if (!keep_message) if (copied) |unused| allocator.free(unused);
    }
}

// The caller holds the high gate and has claimed the first real backend fault.
// One ordinary pin protects the host while its distinct hardware diagnostic is copied.
fn recordBackendMessageLocked(device: *Device, allocator: Allocator, io: Io, message: []const u8) void {
    std.debug.assert(device.lost_reason == .unknown);
    std.debug.assert(device.active_operations < std.math.maxInt(usize));
    device.active_operations += 1;
    device.lifecycle_mutex.unlock(io);
    defer device.releaseOperation(io);
    const copied = allocator.dupe(u8, message) catch null;
    device.lifecycle_mutex.lockUncancelable(io);
    const previous = device.async_state.synchronous_loss_message;
    device.async_state.synchronous_loss_message = copied;
    device.lost_message = copied orelse "Device lost";
    device.lifecycle_mutex.unlock(io);
    if (previous) |owned_message| allocator.free(owned_message);
}

/// Closes source admission only after destructive preflight. Drains Device pins, not the shared pool.
pub fn closeAndDrain(device: *Device, io: Io) error{ResourceInUse}!void {
    device.lifecycle_mutex.lockUncancelable(io);
    defer device.lifecycle_mutex.unlock(io);
    std.debug.assert(device.destroying);
    device.async_state.source_callbacks_open = false;
    const limit = if (device.async_state.registry) |registry|
        registry.options.max_wait_iterations
    else
        1;
    for (0..limit) |_| {
        const pending_loss: usize = if (device.async_state.loss_pin_held) 1 else 0;
        if (device.active_async_operations == pending_loss) return;
        device.async_condition.waitUncancelable(io, &device.lifecycle_mutex);
    }
    if (device.active_async_operations ==
        @as(usize, if (device.async_state.loss_pin_held) 1 else 0)) return;
    return error.ResourceInUse;
}

/// Reserves each host-only cell before clearing its actual owner pointer and exact high pins.
/// Concurrent callbacks/observers refuse without clearing that cell's owner.
pub fn prepareHostDetach(device: *Device, io: Io) error{ResourceInUse}!void {
    device.lifecycle_mutex.lockUncancelable(io);
    const registry = device.async_state.registry orelse {
        device.lifecycle_mutex.unlock(io);
        return;
    };
    if (device.active_callbacks != 0) {
        device.lifecycle_mutex.unlock(io);
        return error.ResourceInUse;
    }
    device.lifecycle_mutex.unlock(io);
    finishLoss(device, registry.allocator, io, .destroyed, "Device destroyed.");
    // One extra iteration proves the full bounded owner set is now empty.
    for (0..@as(usize, registry.options.max_live_operations) + 1) |_| {
        device.lifecycle_mutex.lockUncancelable(io);
        const header = registry.retainOwnerCandidate(io, device.async_state.owner_identity) catch {
            device.lifecycle_mutex.unlock(io);
            return error.ResourceInUse;
        } orelse {
            const still_pinned = device.active_async_operations != 0;
            device.lifecycle_mutex.unlock(io);
            if (still_pinned) return error.ResourceInUse;
            return;
        };
        registry.beginOwnerDetach(io, header) catch {
            device.lifecycle_mutex.unlock(io);
            registry.release(io, header, .candidate) catch
                @panic("Host detacher lost its candidate reference");
            return error.ResourceInUse;
        };
        root.detachDeviceContextLocked(header, device);
        registry.detachOwner(io, header);
        device.async_condition.broadcast(io);
        device.lifecycle_mutex.unlock(io);
        registry.release(io, header, .candidate) catch
            @panic("Host detacher lost its candidate reference");
    }
    return error.ResourceInUse;
}
/// Final host retirement consumes only the high-owned immutable error/message, never core Rc counts.
pub fn releaseHostState(device: *Device, allocator: Allocator, io: Io) void {
    device.lifecycle_mutex.lockUncancelable(io);
    std.debug.assert(device.active_async_operations == 0);
    std.debug.assert(device.active_callbacks == 0);
    const loss_error = device.async_state.loss_error;
    const copied = device.async_state.synchronous_loss_message;
    device.async_state.loss_error = null;
    device.async_state.synchronous_loss_message = null;
    device.async_state.uncaptured_info = .{};
    device.async_state.logging_info = .{};
    device.lost_message = "";
    device.lifecycle_mutex.unlock(io);
    if (loss_error) |owned_error| owned_error.release();
    if (copied) |message| allocator.free(message);
}
