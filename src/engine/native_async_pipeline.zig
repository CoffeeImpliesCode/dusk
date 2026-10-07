//! Device pipeline requests use the existing synchronous native factories and caches.
//! Prepared descriptors and scope leases move into typed registry cells. A native
//! observer abandons only delivery; accepted Root work always runs to completion.
const std = @import("std");
const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const device_mod = @import("device.zig");
const native = @import("native_async_device.zig");
const handles = @import("native_async_handles.zig");
const descriptors = @import("native_async_descriptors.zig");
const resources = @import("native_resources.zig");
const registry = @import("async_registry.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Device = device_mod.Device;

/// Success transfers one actual native wrapper user alias. Failure transfers one
/// immutable ErrorRef. Cancellation owns neither and does not cancel cache work.
pub const NativePipelineResult = union(enum) {
    success: *resources.Pipeline,
    failure: struct { status: api.CreatePipelineAsyncStatus, error_ref: core.ErrorRef },
    cancelled,
};
const Kind = enum { compute, render };

fn Operator(comptime kind: Kind) type {
    return struct {
        const Owned = if (kind == .compute) descriptors.OwnedCompute else descriptors.OwnedRender;
        const Chain = if (kind == .compute) api.descriptors.ComputePipelineDescriptorChain else api.descriptors.RenderPipelineDescriptorChain;
        const CallbackInfo = if (kind == .compute) api.CreateComputePipelineAsyncCallbackInfo else api.CreateRenderPipelineAsyncCallbackInfo;
        const ApiPipeline = if (kind == .compute) api.ComputePipeline else api.RenderPipeline;
        const Outcome = union(enum) {
            pending,
            success: struct { pipeline: *resources.Pipeline, handle: ApiPipeline },
            failure: struct { status: api.CreatePipelineAsyncStatus, error_ref: core.ErrorRef },
            cancelled,
            transferred,
        };
        const Context = struct {
            device: ?*Device,
            descriptor: ?Owned,
            scope: ?core.ScopeLeaseSet,
            reservation: core.ErrorReservation,
            delivery: union(enum) { callback: CallbackInfo, native },
            outcome: Outcome = .pending,
            pin: enum { ordinary, accepted, detached } = .ordinary,
        };
        const Cell = registry.Cell(Context);
        const operations: Cell.Operations = .{
            .invoke = invoke,
            .dispose = dispose,
            .shut_down = shutdown,
            .deinit = deinit,
        };

        fn prepare(device: *Device, allocator: Allocator, io: Io, chain: *const Chain, delivery: @FieldType(Context, "delivery")) api.AsyncStartError!*Cell {
            device.acquireOperation(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.ResourceInUse => return error.ReferenceCountOverflow,
                else => return error.OwnerStopped,
            };
            errdefer device.releaseOperation(io);
            const completions = try native.ensureRegistered(device, allocator, io);
            var owned = try Owned.prepare(allocator, io, device, chain);
            errdefer owned.deinit(io);
            var reservation = try core.ErrorReservation.prepare(allocator);
            errdefer reservation.discard();
            var scope = blk: {
                var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
                defer guard.unlock(io);
                break :blk device.core.captureScopeLeaseSet(allocator, &guard, .all) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ScopeReferenceCountOverflow => return error.ReferenceCountOverflow,
                    else => return error.InvalidOwner,
                };
            };
            errdefer abortScope(device, &scope, io);
            reservation.reserveReferences(scope.errorQuota()) catch return error.ReferenceCountOverflow;
            return completions.prepare(Context, io, .{
                .device = device,
                .descriptor = owned,
                .scope = scope,
                .reservation = reservation,
                .delivery = delivery,
            }, operations, .{
                .mode = if (delivery == .callback) delivery.callback.mode else .wait_any_only,
                .callback = delivery == .callback,
                .owner = native.ownerBinding(device),
            });
        }
        fn admit(cell: *Cell, io: Io) api.AsyncStartError!api.Future {
            const device = cell.context.device.?;
            device.lifecycle_mutex.lockUncancelable(io);
            defer device.lifecycle_mutex.unlock(io);
            try native.acquireAsyncOperationLocked(device);
            errdefer native.releaseAsyncOperationLocked(device);
            const future = try cell.header.registry.accept(io, &cell.header, post);
            // Move the preparation pin to the checked accepted subset under the
            // same actual lifecycle gate. No zero-pin interval can occur.
            std.debug.assert(device.active_operations > 1);
            device.active_operations -= 1;
            cell.context.pin = .accepted;
            return future;
        }
        fn post(header: *registry.Header, io: Io) api.AsyncStartError!void {
            const cell: *Cell = @fieldParentPtr("header", header);
            try native.post(cell.context.device.?, io, .{ .run = run, .context = cell });
        }
        fn run(io: Io, raw: *anyopaque) void {
            const cell: *Cell = @ptrCast(@alignCast(raw));
            const completions = cell.header.registry;
            // Acceptance publishes metadata before this registry acquisition.
            if (!completions.beginFinish(io, &cell.header)) {
                std.debug.assert(cell.context.descriptor == null and cell.context.scope == null);
                finishExecution(cell, io);
                return;
            }
            const context = &cell.context;
            const device = context.device.?;
            const owned = &context.descriptor.?;
            const options = owned.options(completions.allocator, io, device) catch |err| {
                finishFailure(cell, io, err);
                return;
            };
            const result = (if (kind == .compute)
                device.createComputePipeline(completions.allocator, io, options)
            else
                device.createRenderPipeline(completions.allocator, io, options)) catch |err| {
                finishFailure(cell, io, err);
                return;
            };
            var guard = core.ObjectGuard.lockUncancelable(io, result.header.tracking);
            const handle = handles.exportResource(ApiPipeline, device, &guard, result, .native_pipeline);
            guard.unlock(io);
            context.outcome = .{ .success = .{ .pipeline = result, .handle = handle } };
            settle(context, io, null);
            completions.publish(io, &cell.header, true);
            finishExecution(cell, io);
        }
        fn finishFailure(cell: *Cell, io: Io, failure: descriptors.DescriptorError) void {
            const context = &cell.context;
            const status = failureStatus(failure);
            if (status == .callback_cancelled) {
                context.outcome = .cancelled;
                settle(context, io, null);
            } else {
                const error_ref = context.reservation.sealNativeError(errorCode(failure, status), failure);
                context.outcome = .{ .failure = .{ .status = status, .error_ref = error_ref } };
                settle(context, io, error_ref);
            }
            const completions = cell.header.registry;
            completions.publish(io, &cell.header, false);
            finishExecution(cell, io);
        }
        fn finishExecution(cell: *Cell, io: Io) void {
            const device = cell.context.device.?;
            device.lifecycle_mutex.lockUncancelable(io);
            std.debug.assert(cell.context.pin == .accepted);
            cell.context.device = null;
            cell.context.pin = .detached;
            native.releaseAsyncOperationLocked(device);
            device.async_condition.broadcast(io);
            device.lifecycle_mutex.unlock(io);
            // Header still has its runner while the final owner access ends.
            release(cell.header.registry, io, &cell.header, .runner);
        }
        fn settle(context: *Context, io: Io, failure: ?core.ErrorRef) void {
            const device = context.device.?;
            context.descriptor.?.deinit(io);
            context.descriptor = null;
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            var settlement = context.scope.?.settle(&guard, failure) catch unreachable;
            context.scope = null;
            guard.unlock(io);
            if (failure == null) context.reservation.discard();
            settlement.dispatch(io);
        }
        fn invoke(context: *Context, io: Io) void {
            const info = switch (context.delivery) {
                .callback => |info| info,
                .native => {
                    dispose(context, io);
                    return;
                },
            };
            const callback = info.callback;
            switch (context.outcome) {
                .success => |success| {
                    // Transfer before invoking user code. It may immediately
                    // release the alias; no payload is accessed after return.
                    context.outcome = .transferred;
                    callback(info.userdata, .success, success.handle, "");
                },
                .failure => |failure| callback(info.userdata, failure.status, null, failure.error_ref.view().message),
                .cancelled => callback(info.userdata, .callback_cancelled, null, "Device stopped"),
                else => unreachable,
            }
        }
        fn dispose(context: *Context, io: Io) void {
            switch (context.outcome) {
                .success => |success| {
                    const pipeline = success.pipeline;
                    const device = handles.resourceOwner(&pipeline.header) catch unreachable;
                    acquireDisposalPin(device, io);
                    defer device.releaseOperation(io);
                    var guard = core.ObjectGuard.lockUncancelable(io, pipeline.header.tracking);
                    handles.validateResourceHostLocked(device, &guard, &pipeline.header, .native_pipeline) catch unreachable;
                    pipeline.header.releaseUserLocked(&guard, io) catch unreachable;
                    guard.unlock(io);
                },
                .failure => |failure| failure.error_ref.release(),
                else => {},
            }
            context.outcome = .transferred;
        }
        fn shutdown(context: *Context, _: Io) void {
            // Root drains accepted runners before registry close. Only a
            // detached host-only cell can reach the registry shutdown hook.
            std.debug.assert(context.descriptor == null and context.scope == null);
            context.outcome = .cancelled;
        }
        fn deinit(context: *Context, _: Allocator, io: Io) void {
            dispose(context, io);
            context.reservation.discard();
            if (context.device) |device| {
                if (context.descriptor) |*owned| owned.deinit(io);
                context.descriptor = null;
                if (context.scope) |*scope| abortScope(device, scope, io);
                context.scope = null;
                context.device = null;
                switch (context.pin) {
                    .ordinary => device.releaseOperation(io),
                    .accepted => native.releaseAsyncOperation(device, io),
                    .detached => unreachable,
                }
                context.pin = .detached;
            }
        }
        fn observer(io: Io, cell: *Cell, prepared_error: core.ErrorReservation) NativePipelineResult {
            var reservation = prepared_error;
            defer reservation.discard();
            const completions = cell.header.registry;
            completions.waitReady(io, &cell.header) catch |err| {
                completions.cancelObserver(io, &cell.header);
                if (err == error.Canceled) return .cancelled;
                return .{ .failure = .{ .status = .internal_error, .error_ref = reservation.sealNativeError(.{ .unrecoverable = error.InternalInvariantViolated }, err) } };
            };
            if (!completions.claimConsumer(io, &cell.header)) {
                completions.cancelObserver(io, &cell.header);
                return .cancelled;
            }
            const result: NativePipelineResult = switch (cell.context.outcome) {
                .success => |owned| .{ .success = owned.pipeline },
                .failure => |failure| .{ .failure = .{ .status = failure.status, .error_ref = failure.error_ref } },
                .cancelled => .cancelled,
                else => unreachable,
            };
            cell.context.outcome = .transferred;
            completions.finishConsumer(io, &cell.header);
            release(completions, io, &cell.header, .observer);
            return result;
        }
        fn startCallback(device: *Device, allocator: Allocator, io: Io, chain: *const Chain, info: CallbackInfo) api.AsyncStartError!api.Future {
            const cell = try prepare(device, allocator, io, chain, .{ .callback = info });
            errdefer cell.header.registry.rollback(io, &cell.header);
            return admit(cell, io);
        }
        fn startNative(device: *Device, allocator: Allocator, io: Io, chain: *const Chain) api.AsyncStartError!Io.Future(NativePipelineResult) {
            const cell = try prepare(device, allocator, io, chain, .native);
            const completions = cell.header.registry;
            errdefer completions.rollback(io, &cell.header);
            var reservation = try core.ErrorReservation.prepare(allocator);
            errdefer reservation.discard();
            completions.retain(io, &cell.header, .observer) catch return error.ReferenceCountOverflow;
            var future = io.concurrent(observer, .{ io, cell, reservation }) catch {
                release(completions, io, &cell.header, .observer);
                return error.ConcurrencyUnavailable;
            };
            reservation.node = null;
            // On refusal, cancellation joins the real staging observer before
            // rollback releases its descriptor leases and preparation pin.
            errdefer switch (future.cancel(io)) {
                .cancelled => {},
                .failure => |failure| failure.error_ref.release(),
                .success => unreachable,
            };
            _ = try admit(cell, io);
            return future;
        }
        fn detach(header: *registry.Header, device: *Device) bool {
            if (!Cell.matchesOperations(header, operations)) return false;
            const cell: *Cell = @fieldParentPtr("header", header);
            const context = &cell.context;
            std.debug.assert(context.descriptor == null and context.scope == null);
            std.debug.assert(context.outcome != .success and context.outcome != .pending);
            if (context.device) |owner| {
                std.debug.assert(owner == device and context.pin == .accepted);
                context.device = null;
                context.pin = .detached;
                native.releaseAsyncOperationLocked(device);
            } else {
                std.debug.assert(context.pin == .detached);
            }
            return true;
        }
    };
}
const Compute = Operator(.compute);
const Render = Operator(.render);

pub fn createComputePipelineAsync(self: api.Device, allocator: Allocator, io: Io, descriptor: *const api.descriptors.ComputePipelineDescriptorChain, info: api.CreateComputePipelineAsyncCallbackInfo) api.AsyncStartError!api.Future {
    return Compute.startCallback(try handles.resolveDevice(self), allocator, io, descriptor, info);
}
pub fn createRenderPipelineAsync(self: api.Device, allocator: Allocator, io: Io, descriptor: *const api.descriptors.RenderPipelineDescriptorChain, info: api.CreateRenderPipelineAsyncCallbackInfo) api.AsyncStartError!api.Future {
    return Render.startCallback(try handles.resolveDevice(self), allocator, io, descriptor, info);
}
pub fn createComputePipelineFuture(device: *Device, allocator: Allocator, io: Io, descriptor: *const api.descriptors.ComputePipelineDescriptorChain) api.AsyncStartError!Io.Future(NativePipelineResult) {
    return Compute.startNative(device, allocator, io, descriptor);
}
pub fn createRenderPipelineFuture(device: *Device, allocator: Allocator, io: Io, descriptor: *const api.descriptors.RenderPipelineDescriptorChain) api.AsyncStartError!Io.Future(NativePipelineResult) {
    return Render.startNative(device, allocator, io, descriptor);
}
/// Caller holds the actual high lifecycle gate and exclusive owner-detach claim.
pub fn detachDeviceContextLocked(header: *registry.Header, device: *Device) bool {
    return Compute.detach(header, device) or Render.detach(header, device);
}

/// Consumes one callback-owned alias using its original retained host and guard.
pub fn releaseComputePipeline(target: api.ComputePipeline, io: Io) device_mod.OperationError!void {
    try releasePipeline(api.ComputePipeline, target, io);
}
pub fn releaseRenderPipeline(target: api.RenderPipeline, io: Io) device_mod.OperationError!void {
    try releasePipeline(api.RenderPipeline, target, io);
}
fn releasePipeline(comptime T: type, target: T, io: Io) device_mod.OperationError!void {
    const header = handles.resourceHeader(T, target, .native_pipeline) catch return error.StaleHandle;
    const device = handles.resourceOwner(header) catch return error.StaleHandle;
    try device.acquireHostOperation(io);
    defer device.releaseOperation(io);
    var guard = core.ObjectGuard.lockUncancelable(io, header.tracking);
    defer guard.unlock(io);
    try handles.validateResourceHostLocked(device, &guard, header, .native_pipeline);
    try header.releaseUserLocked(&guard, io);
}
fn abortScope(device: *Device, scope: *core.ScopeLeaseSet, io: Io) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    var settlement = scope.deinit(&guard);
    guard.unlock(io);
    settlement.dispatch(io);
}
fn release(completions: *registry.CompletionRegistry, io: Io, header: *registry.Header, reference: registry.ReferenceKind) void {
    completions.release(io, header, reference) catch unreachable;
}
fn failureStatus(failure: descriptors.DescriptorError) api.CreatePipelineAsyncStatus {
    return switch (failure) {
        error.DeviceNotAlive, error.DeviceDeinitialized, error.NativeDeviceStopped, error.DeviceLost, error.DeviceDestroyed, error.Canceled => .callback_cancelled,
        error.OutOfMemory, error.OutOfHostMemory, error.OutOfDeviceMemory, error.InternalInvariantViolated, error.PipelineUncategorized, error.Unimplemented, error.NativeBackendRequired => .internal_error,
        else => blk: {
            const name = @errorName(failure);
            if (std.mem.startsWith(u8, name, "Missing") or
                std.mem.endsWith(u8, name, "ProcMissing") or
                std.mem.endsWith(u8, name, "Failed") or
                std.mem.endsWith(u8, name, "Unavailable") or
                std.mem.eql(u8, name, "HandleCreationReturnedNull") or
                std.mem.eql(u8, name, "LayerNotPresent") or
                std.mem.eql(u8, name, "ExtensionNotPresent") or
                std.mem.eql(u8, name, "FeatureNotPresent") or
                std.mem.eql(u8, name, "IncompatibleDriver") or
                std.mem.eql(u8, name, "TooManyObjects") or
                std.mem.eql(u8, name, "FormatNotSupported") or
                std.mem.eql(u8, name, "FragmentedPool") or
                std.mem.eql(u8, name, "Unknown") or
                std.mem.eql(u8, name, "OutOfPoolMemory") or
                std.mem.eql(u8, name, "InvalidExternalHandle") or
                std.mem.eql(u8, name, "Fragmentation") or
                std.mem.eql(u8, name, "InvalidOpaqueCaptureAddress") or
                std.mem.eql(u8, name, "PipelineCompileRequired") or
                std.mem.eql(u8, name, "ResourceInUse") or
                std.mem.eql(u8, name, "AllocatorMismatch") or
                std.mem.eql(u8, name, "ReferenceCountOverflow")) break :blk .internal_error;
            break :blk .validation_error;
        },
    };
}
fn errorCode(failure: descriptors.DescriptorError, status: api.CreatePipelineAsyncStatus) core.ErrorCode {
    return switch (failure) {
        error.OutOfMemory, error.OutOfHostMemory => .{ .unrecoverable = error.OutOfHostMemory },
        error.OutOfDeviceMemory => .{ .unrecoverable = error.OutOfDeviceMemory },
        else => if (status == .validation_error)
            .{ .validation = error.RequiredFeatureMissing }
        else
            .{ .unrecoverable = error.PipelineUncategorized },
    };
}

fn acquireDisposalPin(device: *Device, io: Io) void {
    // A owned pipeline alias keeps the actual arena/host storage alive. Release
    // must be able to drain while logical destruction closes new operations.
    device.lifecycle_mutex.lockUncancelable(io);
    std.debug.assert(!device.host_deinitialized);
    std.debug.assert(device.active_operations != std.math.maxInt(usize));
    device.active_operations += 1;
    device.lifecycle_mutex.unlock(io);
}
