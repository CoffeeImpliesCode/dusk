//! Root request execution for the existing Instance, Adapter, and Device owners.
//!
//! Each request uses one delivery route: the canonical generated callback path
//! or the native observer path. The caller supplies the allocator for retained
//! root state and the `Io` provider used for each task, wait, or dispatch. Keep
//! the allocator live through root release and disposal. The initialization
//! `Io` provider must outlive pool join; each submitted provider must outlive
//! its task. Native `RootOutcome` failures transfer a `core.ErrorRef`, which the
//! receiver must release. Copying a root handle does not retain its owner.
const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const instance_mod = @import("instance.zig");
const adapter_mod = @import("adapter.zig");
const device_mod = @import("device.zig");
const registry_mod = @import("async_registry.zig");
const native_async = @import("native_async_device.zig");
const native_pipeline = @import("native_async_pipeline.zig");
const native_map_queue = @import("native_async_map_queue.zig");
const native_scope_info = @import("native_async_scope_info.zig");
const handles = @import("native_async_handles.zig");
const platform = @import("../platform/threads.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Instance = instance_mod.Instance;
const Adapter = adapter_mod.Adapter;
const Device = device_mod.Device;
const Registry = registry_mod.CompletionRegistry;
/// Failures while acquiring or keeping root-operation ownership.
pub const RootWorkError = error{
    Canceled,
    InstanceShutDown,
    ReferenceCountOverflow,
};
/// Accepted terminal failures for unsupported root descriptor fields.
pub const RootDescriptorError = error{
    UnsupportedAdapterExtension,
    UnsupportedCompatibleSurface,
    UnsupportedDeviceExtension,
};
/// Finite failures recorded for an accepted root creation request.
pub const RootCreateError = adapter_mod.Error || device_mod.InitError ||
    RootDescriptorError || RootWorkError;
/// Failures reported by an owned-root release receipt.
pub const OwnedRootReleaseError = device_mod.CleanupError || error{
    InvalidHandle,
    BorrowedRoot,
    AllocatorMismatch,
};
/// Whether a root release consumed its handle, with any cleanup failure.
pub const RootReleaseResult = struct {
    /// For a valid owned root, false leaves its owner and handle valid for retry,
    /// even when `failure` is set.
    /// True invalidates the handle, even when cleanup reports a failure.
    consumed: bool,
    failure: ?OwnedRootReleaseError = null,
};
/// Failures from explicit cleanup of retained hidden-device owners.
pub const RootDisposalError = device_mod.CleanupError || error{
    AllocatorMismatch,
    InstanceInUse,
};
/// Stable-address worker pool used by asynchronous root requests.
///
/// The registry allocator owns this record. Its initialization `Io` provider
/// must remain valid until the pool joins.
pub const RootExecutor = struct { pool: platform.WorkerPool };
/// Kind tag checked when resolving an embedded root record.
pub const RootKind = enum { instance, adapter, device };
/// Identifies a borrowed actual owner or an owned request result.
pub const RootOwnership = union(enum) {
    borrowed,
    adapter_result: *OwnedAdapterSelection,
    device_result: *OwnedDevice,
};
/// Embedded, kind-checked root metadata with borrowed ownership by default.
pub const RootRecord = struct {
    kind: RootKind,
    ownership: RootOwnership = .borrowed,
};
/// Owns the actual counted AdapterList and its stable Adapter rows.
///
/// `selected` borrows from the list until successful root release. Copying this
/// value does not retain the root owner.
pub const OwnedAdapterSelection = struct {
    allocator: Allocator,
    instance: *Instance,
    list: ?instance_mod.AdapterList = null,
    selected_index: u32 = 0,
    ownership: enum { request, caller, disposing } = .request,
    /// Returns the selected Adapter, borrowed until successful root release.
    pub fn selected(self: *OwnedAdapterSelection) *Adapter {
        return &self.list.?.items[self.selected_index];
    }
};
/// Owns one aligned allocation of copied feature names and label bytes.
///
/// `required_limits` is copied by value. Callback userdata remains borrowed.
/// `deinit` frees `storage` and invalidates every view into it.
pub const OwnedDeviceInput = struct {
    storage: []align(@alignOf(api.FeatureName)) u8,
    label: ?[]const u8,
    default_queue_label: ?[]const u8,
    required_features: []const api.FeatureName,
    required_limits: ?api.Limits,
    consume_adapter: ?bool,
    descriptor_error: ?RootDescriptorError,
    uncaptured_info: api.UncapturedErrorCallbackInfo,
    /// Frees `storage` with `allocator` and invalidates its views.
    pub fn deinit(self: *OwnedDeviceInput, allocator: Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};
/// Owns copied descriptor input and embeds `high` at its final heap address.
///
/// `high` is unreadable before `high_initialized`. The original null-device
/// mutex stays at this address. `instance` and `adapter` are borrowed actual
/// owners. Copying this value does not retain the root owner.
pub const OwnedDevice = struct {
    allocator: Allocator,
    instance: *Instance,
    adapter: *Adapter,
    high: Device,
    high_initialized: bool = false,
    null_object_mutex: Io.Mutex = .init,
    input: OwnedDeviceInput,
    ownership: enum { request, caller, disposing } = .request,
    disposal_next: ?*OwnedDevice = null,
    disposal_state: enum { none, queued, collecting } = .none,
    disposal_slot_held: bool = true,
    cleanup_error: ?device_mod.CleanupError = null,
};
/// Terminal state held by one adapter request cell.
///
/// The cell owns any `core.ErrorRef` until callback delivery, disposal, or
/// transfer to the native observer.
pub const AdapterOutcome = union(enum) {
    pending,
    success: *OwnedAdapterSelection,
    unavailable,
    failure: core.ErrorRef,
    shut_down,
    transferred,
};
/// Terminal state held by one device request cell.
///
/// The cell owns any `core.ErrorRef` until callback delivery, disposal, or
/// transfer to the native observer.
pub const DeviceOutcome = union(enum) {
    pending,
    success: *OwnedDevice,
    failure: core.ErrorRef,
    shut_down,
    transferred,
};
/// Internal linear registry payload with reserved failure storage and an
/// actual Instance pin.
///
/// A selected callback route copies callback info by value; userdata stays
/// borrowed through delivery. Pin flags pair with the actual owner reference.
/// This is not another reference-counted root owner.
pub const AdapterRequest = struct {
    instance: ?*Instance,
    options: api.RequestAdapterOptions,
    descriptor_error: ?RootDescriptorError,
    delivery: union(enum) { callback: api.RequestAdapterCallbackInfo, native },
    error_reservation: core.ErrorReservation,
    prepared_selection: ?*OwnedAdapterSelection,
    outcome: AdapterOutcome = .pending,
    root_pin_held: bool = true,
    accepted_pin_held: bool = false,
};
/// Internal linear registry payload with reserved request and loss storage.
///
/// A selected callback route copies callback info by value; userdata stays
/// borrowed through delivery. Pin flags pair with actual owner references.
/// This is not another reference-counted root owner.
pub const DeviceRequest = struct {
    instance: ?*Instance,
    adapter: ?*Adapter,
    delivery: union(enum) { callback: api.RequestDeviceCallbackInfo, native },
    error_reservation: core.ErrorReservation,
    prepared_device: ?*OwnedDevice,
    loss: ?*registry_mod.Cell(LossContext),
    outcome: DeviceOutcome = .pending,
    phase: enum { prepared, accepted, running, adopted, failed, shut_down } = .prepared,
    root_pin_held: bool = true,
    adapter_pin_held: bool = true,
    device_pin: ?*Device = null,
    accepted_pin_held: bool = false,
    disposal_owner: ?*OwnedDevice = null,
};
/// Loss callback state with reserved error storage and actual-owner pin flags.
///
/// Callback info is copied by value; userdata stays borrowed through delivery.
/// Pins pair with actual Instance and Device references. This is not another
/// reference-counted root owner.
pub const LossContext = struct {
    callback_info: api.DeviceLostCallbackInfo,
    pending_instance: ?*Instance,
    device: ?*Device = null,
    error_reservation: core.ErrorReservation,
    terminal_error: ?core.ErrorRef = null,
    reason: ?api.DeviceLostReason = null,
    root_pin_held: bool = true,
    device_pin_held: bool = false,
    accepted_pin_held: bool = false,
};
/// Result of one native observer route.
///
/// Success transfers an owned root to the caller. Failure transfers a
/// `core.ErrorRef`, which the caller must release. `unavailable` is adapter-only.
/// Cancellation stops only the observer; accepted work continues and disposes
/// any unclaimed late result.
pub fn RootOutcome(comptime T: type) type {
    return union(enum) {
        success: T,
        unavailable,
        failure: core.ErrorRef,
        shut_down,
        canceled,
    };
}

fn sameAllocator(a: Allocator, b: Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}
fn validMode(mode: api.CallbackMode) bool {
    return switch (mode) {
        .wait_any_only, .allow_process_events, .allow_spontaneous => true,
    };
}
/// Copies supported device inputs into one aligned allocation.
///
/// Limits are copied by value and callback userdata remains borrowed.
/// Malformed feature count/slice pairs and checked-size overflow return
/// `error.InvalidRequest`. Call `deinit` on the returned value.
pub fn copyDeviceInput(
    allocator: Allocator,
    descriptor: ?*const api.descriptors.DeviceDescriptorChain,
) api.AsyncStartError!OwnedDeviceInput {
    const features = if (descriptor) |d| blk: {
        if (d.required_features) |slice| {
            if (slice.len != d.required_feature_count) return error.InvalidRequest;
            break :blk slice;
        }
        if (d.required_feature_count != 0) return error.InvalidRequest;
        break :blk @as([]const api.FeatureName, &.{});
    } else &.{};
    const label = if (descriptor) |d| d.label else null;
    const queue_label = if (descriptor) |d| d.default_queue.label else null;
    const feature_bytes = std.math.mul(
        usize,
        features.len,
        @sizeOf(api.FeatureName),
    ) catch return error.InvalidRequest;
    const with_label = std.math.add(
        usize,
        feature_bytes,
        if (label) |s| s.len else 0,
    ) catch return error.InvalidRequest;
    const total = std.math.add(
        usize,
        with_label,
        if (queue_label) |s| s.len else 0,
    ) catch return error.InvalidRequest;
    const storage = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(@alignOf(api.FeatureName)),
        total,
    );
    const copied_features: []api.FeatureName =
        @as([*]api.FeatureName, @ptrCast(storage.ptr))[0..features.len];
    @memcpy(copied_features, features);
    if (label) |s| @memcpy(storage[feature_bytes..with_label], s);
    if (queue_label) |s| @memcpy(storage[with_label..], s);
    return .{
        .storage = storage,
        .label = if (label != null) storage[feature_bytes..with_label] else null,
        .default_queue_label = if (queue_label != null) storage[with_label..] else null,
        .required_features = copied_features,
        .required_limits = if (descriptor) |d| if (d.required_limits) |p| p.* else null else null,
        .consume_adapter = if (descriptor) |d|
            if (d.dawn_consume_adapter_descriptor) |c| c.consume_adapter else null
        else
            null,
        .descriptor_error = if (descriptor) |d|
            if (d.dawn_toggles_descriptor != null or
                d.dawn_cache_device_descriptor != null or
                d.dawn_device_allocator_control != null or
                d.dawn_fake_device_initialize_error_for_testing != null)
                error.UnsupportedDeviceExtension
            else
                null
        else
            null,
        .uncaptured_info = if (descriptor) |d| d.uncaptured_error_callback_info else .{},
    };
}

/// Gets the root registry and starts its worker pool on first use.
///
/// A namespace source is required before any allocation. The supplied allocator
/// must match an attached registry. A later preparation failure may leave an
/// empty registry or initialized pool attached. The initialization `Io`
/// provider must stay valid until pool join.
pub fn ensureRootAsync(
    instance: *Instance,
    allocator: Allocator,
    io: Io,
) api.AsyncStartError!*Registry {
    if (instance.future_namespace_source == null) return error.MissingFutureNamespaceSource;
    try instance.acquireRootOperation(io);
    defer instance.releaseRootOperation(io);
    instance.lifecycle_mutex.lockUncancelable(io);
    if (instance.completions) |registry| {
        if (!sameAllocator(allocator, registry.allocator)) {
            instance.lifecycle_mutex.unlock(io);
            return error.InvalidOwner;
        }
        if (instance.root_executor != null) {
            instance.lifecycle_mutex.unlock(io);
            return registry;
        }
    }
    instance.lifecycle_mutex.unlock(io);
    instance.root_work_mutex.lock(io) catch return error.Canceled;
    defer instance.root_work_mutex.unlock(io);
    instance.lifecycle_mutex.lockUncancelable(io);
    if (instance.root_state != .open) {
        instance.lifecycle_mutex.unlock(io);
        return error.InstanceShutDown;
    }
    const attached = instance.completions;
    instance.lifecycle_mutex.unlock(io);
    const registry = attached orelse try Registry.create(
        allocator,
        io,
        instance.future_namespace_source,
        instance.async_options,
    );
    if (attached == null) {
        instance.lifecycle_mutex.lockUncancelable(io);
        instance.completions = registry;
        instance.lifecycle_mutex.unlock(io);
    } else if (!sameAllocator(allocator, registry.allocator)) return error.InvalidOwner;
    if (instance.root_executor == null) {
        const executor = try allocator.create(RootExecutor);
        errdefer allocator.destroy(executor);
        platform.WorkerPool.init(
            io,
            &executor.pool,
            .{ .worker_count = instance.root_worker_count },
        ) catch |err| switch (err) {
            error.InvalidWorkerCount => return error.InvalidAsyncCapacity,
            error.WorkerSpawnFailed => return error.ConcurrencyUnavailable,
        };
        instance.lifecycle_mutex.lockUncancelable(io);
        instance.root_executor = executor;
        instance.lifecycle_mutex.unlock(io);
    }
    return registry;
}

fn ownerLock(instance: *Instance, io: Io) void {
    instance.lifecycle_mutex.lockUncancelable(io);
}
fn ownerUnlock(instance: *Instance, io: Io) void {
    instance.lifecycle_mutex.unlock(io);
}
fn ownerClaim(instance: *Instance, _: registry_mod.CallbackClass) bool {
    if (instance.root_state == .closed or
        instance.active_operations == std.math.maxInt(usize) or
        instance.active_callbacks == std.math.maxInt(u32))
        return false;
    instance.active_operations += 1;
    instance.active_callbacks += 1;
    return true;
}
fn ownerEnd(instance: *Instance, _: registry_mod.CallbackClass) void {
    std.debug.assert(instance.active_callbacks != 0);
    std.debug.assert(instance.active_operations != 0);
    instance.active_callbacks -= 1;
    instance.active_operations -= 1;
}
fn ownerBinding(instance: *Instance, registry: *Registry) registry_mod.OwnerBinding {
    return registry_mod.OwnerBinding.bind(
        Instance,
        @as(u64, registry.namespace) << 32,
        instance,
        .{
            .lock = ownerLock,
            .unlock = ownerUnlock,
            .claim = ownerClaim,
            .end_claim = ownerEnd,
        },
    );
}
fn cellOf(comptime T: type, context: *T) *registry_mod.Cell(T) {
    return @fieldParentPtr("context", context);
}
fn releaseRef(
    registry: *Registry,
    io: Io,
    header: *registry_mod.Header,
    kind: registry_mod.ReferenceKind,
) void {
    registry.release(io, header, kind) catch |err| std.debug.panic(
        "root reference invariant: {s}",
        .{@errorName(err)},
    );
}
fn dropRootPin(instance: *Instance, io: Io, accepted: bool) void {
    if (accepted) instance.releaseAcceptedRootOperation(io) else instance.releaseRootOperation(io);
}
fn postAdapter(header: *registry_mod.Header, io: Io) api.AsyncStartError!void {
    const cell: *registry_mod.Cell(AdapterRequest) = @fieldParentPtr("header", header);
    const instance = cell.context.instance.?;
    try platform.WorkerPool.postTask(
        io,
        &instance.root_executor.?.pool,
        .{ .run = runAdapter, .context = cell },
    );
}
fn postDevice(header: *registry_mod.Header, io: Io) api.AsyncStartError!void {
    const cell: *registry_mod.Cell(DeviceRequest) = @fieldParentPtr("header", header);
    const instance = cell.context.instance.?;
    try platform.WorkerPool.postTask(
        io,
        &instance.root_executor.?.pool,
        .{ .run = runDevice, .context = cell },
    );
}
fn acquireAdapter(instance: *Instance, adapter: *Adapter, io: Io) api.AsyncStartError!void {
    try instance.acquireRootOperation(io);
    instance.lifecycle_mutex.lockUncancelable(io);
    defer instance.lifecycle_mutex.unlock(io);
    if (adapter.active_root_requests == std.math.maxInt(usize)) {
        instance.active_operations -= 1;
        return error.ReferenceCountOverflow;
    }
    adapter.active_root_requests += 1;
}
fn releaseAdapterPin(instance: *Instance, adapter: *Adapter, io: Io) void {
    instance.lifecycle_mutex.lockUncancelable(io);
    std.debug.assert(adapter.active_root_requests != 0);
    adapter.active_root_requests -= 1;
    instance.lifecycle_mutex.unlock(io);
}
fn prepareAdapter(
    instance: *Instance,
    allocator: Allocator,
    io: Io,
    options: ?*const api.descriptors.RequestAdapterOptionsChain,
    delivery: @FieldType(AdapterRequest, "delivery"),
) api.AsyncStartError!*registry_mod.Cell(AdapterRequest) {
    try instance.acquireRootOperation(io);
    errdefer instance.releaseRootOperation(io);
    const registry = try ensureRootAsync(instance, allocator, io);
    if (delivery == .callback and !validMode(delivery.callback.mode))
        return error.InvalidCallbackMode;
    const selection = try allocator.create(OwnedAdapterSelection);
    errdefer allocator.destroy(selection);
    selection.* = .{ .allocator = allocator, .instance = instance };
    var reservation = try core.ErrorReservation.prepare(allocator);
    errdefer reservation.discard();
    const mapped: api.RequestAdapterOptions = if (options) |o| .{
        .feature_level = o.feature_level,
        .power_preference = o.power_preference,
        .force_fallback_adapter = o.force_fallback_adapter,
        .backend_type = o.backend_type,
        .compatible_surface = null,
    } else .{
        .feature_level = .core,
        .power_preference = .undefined_,
        .backend_type = .undefined_,
    };
    const rejected: ?RootDescriptorError = if (options) |o|
        if (o.compatible_surface != null)
            error.UnsupportedCompatibleSurface
        else if (o.request_adapter_webxr_options != null or
            o.request_adapter_webgpu_backend_options != null or
            o.dawn_toggles_descriptor != null)
            error.UnsupportedAdapterExtension
        else
            null
    else
        null;
    return registry.prepare(
        AdapterRequest,
        io,
        .{
            .instance = instance,
            .options = mapped,
            .descriptor_error = rejected,
            .delivery = delivery,
            .error_reservation = reservation,
            .prepared_selection = selection,
        },
        adapter_operations,
        .{
            .mode = if (delivery == .callback)
                delivery.callback.mode
            else
                .wait_any_only,
            .callback = delivery == .callback,
            .owner = ownerBinding(instance, registry),
        },
    );
}
fn admitAdapter(cell: *registry_mod.Cell(AdapterRequest), io: Io) api.AsyncStartError!api.Future {
    const instance = cell.context.instance.?;
    instance.lifecycle_mutex.lockUncancelable(io);
    defer instance.lifecycle_mutex.unlock(io);
    if (instance.root_state != .open) return error.InstanceShutDown;
    if (instance.accepted_root_operations == std.math.maxInt(usize))
        return error.ReferenceCountOverflow;
    const future = try cell.header.registry.accept(io, &cell.header, postAdapter);
    instance.accepted_root_operations += 1;
    cell.context.accepted_pin_held = true;
    return future;
}
/// Starts the canonical generated callback route for an Adapter request.
///
/// The function copies callback info and supported options before acceptance.
/// Keep callback userdata valid through delivery. The existing registry applies
/// `callback_info.mode`. Accepted extension refusals become request-owned
/// `core.ErrorRef` failures; the callback borrows the message through return.
/// Release a successful owned root with `releaseAdapterResult`.
pub fn requestAdapter(
    self: api.Instance,
    allocator: Allocator,
    io: Io,
    options: ?*const api.descriptors.RequestAdapterOptionsChain,
    callback_info: api.RequestAdapterCallbackInfo,
) api.AsyncStartError!api.Future {
    const cell = try prepareAdapter(
        try handles.resolveInstance(self),
        allocator,
        io,
        options,
        .{ .callback = callback_info },
    );
    errdefer cell.header.registry.rollback(io, &cell.header);
    return admitAdapter(cell, io);
}

fn reserveDisposalSlot(instance: *Instance, io: Io) api.AsyncStartError!void {
    instance.lifecycle_mutex.lockUncancelable(io);
    defer instance.lifecycle_mutex.unlock(io);
    if (instance.root_disposal_slots >= instance.async_options.max_live_operations)
        return error.AsyncCapacityExceeded;
    instance.root_disposal_slots += 1;
}
fn releaseDisposalSlot(owned: *OwnedDevice, io: Io) void {
    if (!owned.disposal_slot_held) return;
    owned.instance.lifecycle_mutex.lockUncancelable(io);
    std.debug.assert(owned.instance.root_disposal_slots != 0);
    owned.instance.root_disposal_slots -= 1;
    owned.disposal_slot_held = false;
    owned.instance.lifecycle_mutex.unlock(io);
}
fn freeUninitializedDevice(owned: *OwnedDevice, io: Io) void {
    std.debug.assert(!owned.high_initialized);
    releaseDisposalSlot(owned, io);
    const allocator = owned.allocator;
    owned.input.deinit(allocator);
    allocator.destroy(owned);
}
fn prepareDevice(
    adapter: *Adapter,
    allocator: Allocator,
    io: Io,
    descriptor: ?*const api.descriptors.DeviceDescriptorChain,
    delivery: @FieldType(DeviceRequest, "delivery"),
) api.AsyncStartError!*registry_mod.Cell(DeviceRequest) {
    const instance = adapter.instance;
    try acquireAdapter(instance, adapter, io);
    var request_pins_moved = false;
    errdefer if (!request_pins_moved) {
        releaseAdapterPin(instance, adapter, io);
        instance.releaseRootOperation(io);
    };
    const registry = try ensureRootAsync(instance, allocator, io);
    const loss_info: api.DeviceLostCallbackInfo = if (descriptor) |d|
        d.device_lost_callback_info
    else
        .{ .mode = .wait_any_only };
    if (!validMode(loss_info.mode) or
        (delivery == .callback and !validMode(delivery.callback.mode)))
        return error.InvalidCallbackMode;
    var input = try copyDeviceInput(allocator, descriptor);
    var input_moved = false;
    errdefer if (!input_moved) input.deinit(allocator);
    const owned = try allocator.create(OwnedDevice);
    var owned_moved = false;
    errdefer if (!owned_moved) allocator.destroy(owned);
    try reserveDisposalSlot(instance, io);
    var slot_moved = false;
    errdefer if (!slot_moved) {
        instance.lifecycle_mutex.lockUncancelable(io);
        instance.root_disposal_slots -= 1;
        instance.lifecycle_mutex.unlock(io);
    };
    owned.* = .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .high = undefined,
        .input = input,
    };
    var request_error = try core.ErrorReservation.prepare(allocator);
    var request_error_moved = false;
    errdefer if (!request_error_moved) request_error.discard();
    var loss_error = try core.ErrorReservation.prepare(allocator);
    errdefer loss_error.discard();
    loss_error.reserveReferences(1) catch return error.ReferenceCountOverflow;
    try instance.acquireRootOperation(io);
    var loss_pin_moved = false;
    errdefer if (!loss_pin_moved) instance.releaseRootOperation(io);
    const loss = try registry.prepare(
        LossContext,
        io,
        .{
            .callback_info = loss_info,
            .pending_instance = instance,
            .error_reservation = loss_error,
        },
        loss_operations,
        .{
            .mode = loss_info.mode,
            .callback = loss_info.callback != null,
            .owner = ownerBinding(instance, registry),
            .callback_class = .device_lost,
        },
    );
    loss_error.node = null;
    loss_pin_moved = true;
    errdefer registry.rollback(io, &loss.header);
    const request = try registry.prepare(
        DeviceRequest,
        io,
        .{
            .instance = instance,
            .adapter = adapter,
            .delivery = delivery,
            .error_reservation = request_error,
            .prepared_device = owned,
            .loss = loss,
        },
        device_operations,
        .{
            .mode = if (delivery == .callback)
                delivery.callback.mode
            else
                .wait_any_only,
            .callback = delivery == .callback,
            .owner = ownerBinding(instance, registry),
        },
    );
    request_pins_moved = true;
    input_moved = true;
    owned_moved = true;
    slot_moved = true;
    request_error_moved = true;
    return request;
}
fn rollbackDevice(cell: *registry_mod.Cell(DeviceRequest), io: Io) void {
    const loss = cell.context.loss.?;
    cell.context.loss = null;
    const registry = cell.header.registry;
    registry.rollback(io, &loss.header);
    registry.rollback(io, &cell.header);
}
fn admitDevice(
    cell: *registry_mod.Cell(DeviceRequest),
    io: Io,
) api.AsyncStartError!registry_mod.FuturePair {
    const instance = cell.context.instance.?;
    const loss = cell.context.loss.?;
    instance.lifecycle_mutex.lockUncancelable(io);
    defer instance.lifecycle_mutex.unlock(io);
    if (instance.root_state != .open) return error.InstanceShutDown;
    if (instance.accepted_root_operations > std.math.maxInt(usize) - 2)
        return error.ReferenceCountOverflow;
    const pair = try cell.header.registry.acceptPair(
        io,
        .{ .request = &cell.header, .loss = &loss.header },
        postDevice,
    );
    instance.accepted_root_operations += 2;
    cell.context.accepted_pin_held = true;
    loss.context.accepted_pin_held = true;
    cell.context.phase = .accepted;
    return pair;
}
/// Starts the canonical generated callback route for a Device request.
///
/// The function copies callback info and supported descriptor fields before
/// acceptance. Keep callback userdata valid through its last delivery. The
/// existing registry applies `callback_info.mode`. Accepted extension refusals
/// become request-owned `core.ErrorRef` failures; the callback borrows the
/// message through return. Release a successful owned root with
/// `releaseDeviceResult`.
pub fn requestDevice(
    self: api.Adapter,
    allocator: Allocator,
    io: Io,
    descriptor: ?*const api.descriptors.DeviceDescriptorChain,
    callback_info: api.RequestDeviceCallbackInfo,
) api.AsyncStartError!api.Future {
    const cell = try prepareDevice(
        try handles.resolveAdapter(self),
        allocator,
        io,
        descriptor,
        .{ .callback = callback_info },
    );
    errdefer rollbackDevice(cell, io);
    return (try admitDevice(cell, io)).request;
}

fn Observer(comptime Context: type, comptime Result: type) type {
    return struct {
        fn run(
            io: Io,
            cell: *registry_mod.Cell(Context),
            prepared_error: core.ErrorReservation,
        ) RootOutcome(Result) {
            var observer_error = prepared_error;
            defer observer_error.discard();
            const registry = cell.header.registry;
            registry.waitReady(io, &cell.header) catch |err| {
                registry.cancelObserver(io, &cell.header);
                if (err == error.Canceled) return .canceled;
                return .{ .failure = diagnostic(&observer_error, err) };
            };
            if (!registry.claimConsumer(io, &cell.header)) {
                registry.cancelObserver(io, &cell.header);
                return .canceled;
            }
            const outcome: RootOutcome(Result) =
                if (if (Context == AdapterRequest) cell.context.outcome == .unavailable else false)
                    .unavailable
                else switch (cell.context.outcome) {
                    .success => |owned| blk: {
                        owned.ownership = .caller;
                        if (Context == DeviceRequest) releaseDisposalSlot(owned, io);
                        cell.context.outcome = .transferred;
                        break :blk .{ .success = owned };
                    },
                    .failure => |failure| blk: {
                        cell.context.outcome = .transferred;
                        break :blk .{ .failure = failure };
                    },
                    .shut_down => .shut_down,
                    else => @panic("ready root observer has no terminal outcome"),
                };
            registry.finishConsumer(io, &cell.header);
            releaseRef(registry, io, &cell.header, .observer);
            return outcome;
        }
    };
}
/// Starts the native observer route for an Adapter request.
///
/// This route is exclusive with the generated callback route. Cancellation
/// stops only the observer; accepted work continues and disposes an unclaimed
/// late result. The caller must release a returned `core.ErrorRef` and release
/// a successful root with `releaseAdapterResult`.
pub fn requestAdapterAsync(
    instance: *Instance,
    allocator: Allocator,
    io: Io,
    options: ?*const api.descriptors.RequestAdapterOptionsChain,
) api.AsyncStartError!Io.Future(RootOutcome(*OwnedAdapterSelection)) {
    const cell = try prepareAdapter(instance, allocator, io, options, .native);
    const registry = cell.header.registry;
    errdefer registry.rollback(io, &cell.header);
    var observer_error = try core.ErrorReservation.prepare(allocator);
    errdefer observer_error.discard();
    registry.retain(io, &cell.header, .observer) catch return error.ReferenceCountOverflow;
    var future = io.concurrent(
        Observer(AdapterRequest, *OwnedAdapterSelection).run,
        .{ io, cell, observer_error },
    ) catch {
        releaseRef(registry, io, &cell.header, .observer);
        return error.ConcurrencyUnavailable;
    };
    observer_error.node = null;
    errdefer abandonUnacceptedObserver(*OwnedAdapterSelection, future.cancel(io));
    const accepted = try admitAdapter(cell, io);
    std.debug.assert(accepted.id != 0);
    return future;
}
/// Starts the native observer route for a Device request.
///
/// This route is exclusive with the generated callback route. Cancellation
/// stops only the observer; accepted work continues and disposes an unclaimed
/// late result. The caller must release a returned `core.ErrorRef` and release
/// a successful root with `releaseDeviceResult`.
pub fn requestDeviceAsync(
    adapter: *Adapter,
    allocator: Allocator,
    io: Io,
    descriptor: ?*const api.descriptors.DeviceDescriptorChain,
) api.AsyncStartError!Io.Future(RootOutcome(*OwnedDevice)) {
    const cell = try prepareDevice(adapter, allocator, io, descriptor, .native);
    const registry = cell.header.registry;
    errdefer rollbackDevice(cell, io);
    var observer_error = try core.ErrorReservation.prepare(allocator);
    errdefer observer_error.discard();
    registry.retain(io, &cell.header, .observer) catch return error.ReferenceCountOverflow;
    var future = io.concurrent(
        Observer(DeviceRequest, *OwnedDevice).run,
        .{ io, cell, observer_error },
    ) catch {
        releaseRef(registry, io, &cell.header, .observer);
        return error.ConcurrencyUnavailable;
    };
    observer_error.node = null;
    errdefer abandonUnacceptedObserver(*OwnedDevice, future.cancel(io));
    const accepted = try admitDevice(cell, io);
    std.debug.assert(accepted.request.id != 0);
    return future;
}

fn abandonUnacceptedObserver(comptime T: type, outcome: RootOutcome(T)) void {
    switch (outcome) {
        .canceled => {},
        .failure => |failure| failure.release(),
        else => @panic("unaccepted observer transferred a result"),
    }
}

fn diagnostic(reservation: *core.ErrorReservation, failure: anytype) core.ErrorRef {
    const name = @errorName(failure);
    const code: core.ErrorCode = if (std.mem.eql(u8, name, "OutOfMemory"))
        .{ .unrecoverable = error.OutOfHostMemory }
    else if (std.mem.eql(u8, name, "RequiredFeatureUnsupported"))
        .{ .validation = error.RequiredFeatureMissing }
    else if (std.mem.eql(u8, name, "RequiredLimitAboveAdapterLimit") or
        std.mem.eql(u8, name, "LimitExceeded"))
        .{ .validation = error.LimitExceeded }
    else if (std.mem.startsWith(u8, name, "Unsupported"))
        .{ .unrecoverable = error.Unimplemented }
    else
        .{ .unrecoverable = error.InternalInvariantViolated };
    return reservation.sealNativeError(code, failure);
}
fn detachRootAfterRunner(comptime T: type, cell: *registry_mod.Cell(T), io: Io) void {
    const registry = cell.header.registry;
    registry.retain(io, &cell.header, .candidate) catch |err| std.debug.panic(
        "root candidate invariant: {s}",
        .{@errorName(err)},
    );
    releaseRef(registry, io, &cell.header, .runner);
    const instance = if (T == LossContext) cell.context.pending_instance else cell.context.instance;
    if (instance) |owner| {
        owner.lifecycle_mutex.lockUncancelable(io);
        registry.beginOwnerDetach(io, &cell.header) catch {
            owner.lifecycle_mutex.unlock(io);
            releaseRef(registry, io, &cell.header, .candidate);
            return;
        };
        if (T == DeviceRequest) {
            if (cell.context.adapter_pin_held) {
                std.debug.assert(cell.context.adapter.?.active_root_requests != 0);
                cell.context.adapter.?.active_root_requests -= 1;
                cell.context.adapter_pin_held = false;
                cell.context.adapter = null;
            }
        }
        if (cell.context.root_pin_held) {
            std.debug.assert(owner.active_operations != 0);
            owner.active_operations -= 1;
            if (cell.context.accepted_pin_held) owner.accepted_root_operations -= 1;
            cell.context.root_pin_held = false;
        }
        if (T == LossContext)
            cell.context.pending_instance = null
        else
            cell.context.instance = null;
        registry.detachOwner(io, &cell.header);
        owner.lifecycle_mutex.unlock(io);
    }
    releaseRef(registry, io, &cell.header, .candidate);
}
fn runAdapter(io: Io, context: *anyopaque) void {
    const cell: *registry_mod.Cell(AdapterRequest) = @ptrCast(@alignCast(context));
    const request = &cell.context;
    const instance = request.instance.?;
    const registry = cell.header.registry;
    instance.lifecycle_mutex.lockUncancelable(io);
    registry.mutex.lockUncancelable(io);
    const pending = cell.header.execution == .pending;
    registry.mutex.unlock(io);
    instance.lifecycle_mutex.unlock(io);
    if (!pending) {
        detachRootAfterRunner(AdapterRequest, cell, io);
        return;
    }
    var list: ?instance_mod.AdapterList = null;
    var failure: ?instance_mod.Error = null;
    if (request.descriptor_error == null) {
        instance.root_work_mutex.lockUncancelable(io);
        instance.lifecycle_mutex.lockUncancelable(io);
        const open = instance.root_state == .open;
        instance.lifecycle_mutex.unlock(io);
        if (open) {
            list = instance.enumerateAdaptersSerialized(
                registry.allocator,
                io,
                request.options,
            ) catch |err| blk: {
                failure = err;
                break :blk null;
            };
        }
        instance.root_work_mutex.unlock(io);
    }
    instance.lifecycle_mutex.lockUncancelable(io);
    const finish = registry.beginFinish(io, &cell.header);
    const closing = instance.root_state != .open;
    instance.lifecycle_mutex.unlock(io);
    if (finish) {
        if (closing) {
            request.outcome = .shut_down;
        } else if (request.descriptor_error) |err| {
            request.outcome = .{ .failure = diagnostic(&request.error_reservation, err) };
        } else if (failure) |err| {
            if (err == error.BackendNotCompiledIn)
                request.outcome = .unavailable
            else
                request.outcome = .{
                    .failure = diagnostic(&request.error_reservation, err),
                };
        } else if (list.?.items.len == 0) {
            request.outcome = .unavailable;
        } else {
            const selection = request.prepared_selection.?;
            selection.list = list;
            list = null;
            selection.selected().root_record.ownership = .{ .adapter_result = selection };
            request.prepared_selection = null;
            request.outcome = .{ .success = selection };
        }
    }
    if (list) |*value| value.deinit(io) catch |err| std.debug.panic(
        "unpublished list cleanup: {s}",
        .{@errorName(err)},
    );
    if (finish) registry.publish(io, &cell.header, request.outcome == .success);
    detachRootAfterRunner(AdapterRequest, cell, io);
}
fn failDevice(cell: *registry_mod.Cell(DeviceRequest), io: Io, failure: ?RootCreateError) void {
    const request = &cell.context;
    const instance = request.instance.?;
    const registry = cell.header.registry;
    const loss = request.loss.?;
    instance.lifecycle_mutex.lockUncancelable(io);
    const closing = instance.root_state != .open;
    const finish_request = registry.beginFinish(io, &cell.header);
    const finish_loss = registry.beginFinish(io, &loss.header);
    request.phase = if (closing or failure == null) .shut_down else .failed;
    instance.lifecycle_mutex.unlock(io);
    if (finish_request) request.outcome =
        if (closing or failure == null)
            .shut_down
        else
            .{ .failure = diagnostic(&request.error_reservation, failure.?) };
    if (finish_loss) {
        loss.context.reason =
            if (closing or failure == null) .callback_cancelled else .failed_creation;
        if (!closing and failure != null) {
            const error_ref = diagnostic(&loss.context.error_reservation, failure.?);
            error_ref.release();
            loss.context.terminal_error = error_ref;
        }
        registry.publish(io, &loss.header, false);
    }
    if (request.prepared_device) |owned| {
        request.prepared_device = null;
        if (owned.high_initialized) {
            queueDisposal(owned, io, true);
            request.disposal_owner = owned;
        } else freeUninitializedDevice(owned, io);
    }
    request.loss = null;
    if (finish_request) registry.publish(io, &cell.header, false);
    detachRootAfterRunner(LossContext, loss, io);
    detachRootAfterRunner(DeviceRequest, cell, io);
}
fn runDevice(io: Io, context: *anyopaque) void {
    const cell: *registry_mod.Cell(DeviceRequest) = @ptrCast(@alignCast(context));
    const request = &cell.context;
    const instance = request.instance.?;
    const registry = cell.header.registry;
    const loss = request.loss.?;
    instance.lifecycle_mutex.lockUncancelable(io);
    registry.mutex.lockUncancelable(io);
    const pending = cell.header.execution == .pending and loss.header.execution == .pending;
    registry.mutex.unlock(io);
    const open = instance.root_state == .open;
    if (pending and open) request.phase = .running;
    instance.lifecycle_mutex.unlock(io);
    if (!pending or !open) {
        failDevice(cell, io, null);
        return;
    }
    const owned = request.prepared_device.?;
    if (owned.input.descriptor_error) |err| {
        failDevice(cell, io, err);
        return;
    }
    owned.high = owned.adapter.createDevice(registry.allocator, io, .{
        .adapter = owned.adapter,
        .label = owned.input.label,
        .default_queue_label = owned.input.default_queue_label,
        .required_features = owned.input.required_features,
        .required_limits = if (owned.input.required_limits) |*value| value else null,
        .consume_adapter = owned.input.consume_adapter,
        .feature_level = owned.adapter.feature_level,
        .uncaptured_context = owned,
        .uncaptured_callback = native_async.coreUncaptured,
        .object_mutex = &owned.null_object_mutex,
    }) catch |err| {
        failDevice(cell, io, err);
        return;
    };
    owned.high_initialized = true;
    {
        // The unpublished final allocation and actual parent counts protect this
        // bind. Do not hold lifecycle or registry locks with ObjectGuard.
        var guard = core.ObjectGuard.lockUncancelable(io, owned.high.core.arena.objectList());
        defer guard.unlock(io);
        owned.high.bindObjectsLocked(&guard, registry.allocator) catch |err| {
            std.debug.panic("root creation changed its allocator identity: {s}", .{@errorName(err)});
        };
    }
    instance.lifecycle_mutex.lockUncancelable(io);
    owned.high.lifecycle_mutex.lockUncancelable(io);
    if (instance.root_state != .open or request.phase != .running) {
        owned.high.lifecycle_mutex.unlock(io);
        instance.lifecycle_mutex.unlock(io);
        failDevice(cell, io, null);
        return;
    }
    native_async.adoptRootCreationLocked(
        &owned.high,
        registry,
        instance,
        loss,
        loss.header.future,
        owned.input.uncaptured_info,
    );
    const retargeted = registry.retargetPendingPair(
        io,
        .{ .request = &cell.header, .loss = &loss.header },
        @as(u64, registry.namespace) << 32,
        native_async.ownerBinding(&owned.high),
    );
    if (!retargeted) {
        native_async.rollbackRootAdoptionLocked(&owned.high);
        owned.high.lifecycle_mutex.unlock(io);
        instance.lifecycle_mutex.unlock(io);
        failDevice(cell, io, null);
        return;
    }
    request.device_pin = &owned.high;
    loss.context.device = &owned.high;
    loss.context.device_pin_held = true;
    loss.context.pending_instance = null;
    loss.context.root_pin_held = false;
    instance.active_operations -= 1;
    instance.accepted_root_operations -= 1;
    request.loss = null;
    owned.high.root_record.ownership = .{ .device_result = owned };
    std.debug.assert(registry.beginFinish(io, &cell.header));
    request.phase = .adopted;
    owned.high.lifecycle_mutex.unlock(io);
    instance.lifecycle_mutex.unlock(io);
    request.prepared_device = null;
    request.outcome = .{ .success = owned };
    registry.publish(io, &cell.header, true);
    releaseRef(registry, io, &cell.header, .runner);
}

fn invokeAdapter(request: *AdapterRequest, _: Io) void {
    const info = request.delivery.callback;
    switch (request.outcome) {
        .success => |selection| {
            const handle = handles.exportAdapter(selection.selected());
            selection.ownership = .caller;
            request.outcome = .transferred;
            info.callback(info.userdata, .success, handle, "");
        },
        .unavailable => info.callback(info.userdata, .unavailable, null, ""),
        .failure => |failure| info.callback(info.userdata, .error_, null, failure.view().message),
        .shut_down => info.callback(info.userdata, .callback_cancelled, null, ""),
        else => @panic("adapter callback without terminal result"),
    }
}
fn disposeAdapter(request: *AdapterRequest, io: Io) void {
    if (request.outcome == .success) {
        const selection = request.outcome.success;
        request.outcome = .transferred;
        selection.ownership = .disposing;
        var list = selection.list.?;
        list.deinit(io) catch |err| std.debug.panic(
            "hidden adapter cleanup: {s}",
            .{@errorName(err)},
        );
        selection.allocator.destroy(selection);
    }
}
fn shutDownAdapter(request: *AdapterRequest, _: Io) void {
    request.outcome = .shut_down;
}
fn deinitAdapter(request: *AdapterRequest, allocator: Allocator, io: Io) void {
    disposeAdapter(request, io);
    if (request.outcome == .failure) request.outcome.failure.release();
    request.error_reservation.discard();
    if (request.prepared_selection) |selection| allocator.destroy(selection);
    if (request.root_pin_held) dropRootPin(request.instance.?, io, request.accepted_pin_held);
    request.instance = null;
    request.root_pin_held = false;
}
const adapter_operations: registry_mod.Cell(AdapterRequest).Operations = .{
    .invoke = invokeAdapter,
    .dispose = disposeAdapter,
    .shut_down = shutDownAdapter,
    .deinit = deinitAdapter,
};

fn invokeDevice(request: *DeviceRequest, io: Io) void {
    const info = request.delivery.callback;
    switch (request.outcome) {
        .success => |owned| {
            const handle = handles.exportDevice(&owned.high);
            owned.ownership = .caller;
            releaseDisposalSlot(owned, io);
            request.outcome = .transferred;
            info.callback(info.userdata, .success, handle, "");
        },
        .failure => |failure| info.callback(info.userdata, .error_, null, failure.view().message),
        .shut_down => info.callback(info.userdata, .callback_cancelled, null, ""),
        else => @panic("device callback without terminal result"),
    }
}
fn disposeDevice(request: *DeviceRequest, io: Io) void {
    if (request.outcome != .success) return;
    const owned = request.outcome.success;
    request.outcome = .transferred;
    queueDisposal(owned, io, true);
    if (request.device_pin) |device| {
        request.device_pin = null;
        native_async.releaseAsyncOperation(device, io);
    }
    request.disposal_owner = owned;
}
fn shutDownDevice(request: *DeviceRequest, _: Io) void {
    request.outcome = .shut_down;
    request.phase = .shut_down;
}
fn deinitDevice(request: *DeviceRequest, _: Allocator, io: Io) void {
    disposeDevice(request, io);
    if (request.outcome == .failure) request.outcome.failure.release();
    request.error_reservation.discard();
    if (request.prepared_device) |owned| {
        request.prepared_device = null;
        if (owned.high_initialized) {
            queueDisposal(owned, io, true);
            collectQueuedDevice(owned, io);
        } else freeUninitializedDevice(owned, io);
    }
    if (request.device_pin) |device| {
        request.device_pin = null;
        native_async.releaseAsyncOperation(device, io);
    }
    if (request.disposal_owner) |owned| {
        request.disposal_owner = null;
        collectQueuedDevice(owned, io);
    }
    if (request.adapter_pin_held) {
        releaseAdapterPin(request.instance.?, request.adapter.?, io);
        request.adapter_pin_held = false;
    }
    if (request.root_pin_held) {
        dropRootPin(request.instance.?, io, request.accepted_pin_held);
        request.root_pin_held = false;
    }
    request.instance = null;
    request.adapter = null;
}
const device_operations: registry_mod.Cell(DeviceRequest).Operations = .{
    .invoke = invokeDevice,
    .dispose = disposeDevice,
    .shut_down = shutDownDevice,
    .deinit = deinitDevice,
};

fn invokeLoss(loss: *LossContext, _: Io) void {
    const callback = loss.callback_info.callback orelse return;
    const message = if (loss.terminal_error) |failure| failure.view().message else "";
    if (loss.device) |device| {
        const borrowed = [_]api.Device{handles.exportDevice(device)};
        callback(loss.callback_info.userdata, &borrowed, loss.reason.?, message);
    } else callback(loss.callback_info.userdata, null, loss.reason.?, message);
}
fn disposeLoss(_: *LossContext, _: Io) void {}
fn shutDownLoss(loss: *LossContext, _: Io) void {
    loss.reason = .callback_cancelled;
}
fn deinitLoss(loss: *LossContext, _: Allocator, io: Io) void {
    if (loss.terminal_error) |failure| {
        failure.release();
        loss.terminal_error = null;
    }
    loss.error_reservation.discard();
    if (loss.device_pin_held) {
        native_async.releaseLossOperation(loss.device.?, io);
        loss.device_pin_held = false;
    }
    if (loss.root_pin_held) {
        dropRootPin(loss.pending_instance.?, io, loss.accepted_pin_held);
        loss.root_pin_held = false;
    }
    loss.pending_instance = null;
    loss.device = null;
}
/// Registry operations for linear `LossContext` cells.
pub const loss_operations: registry_mod.Cell(LossContext).Operations = .{
    .invoke = invokeLoss,
    .dispose = disposeLoss,
    .shut_down = shutDownLoss,
    .deinit = deinitLoss,
};
/// Publishes a loss result after the caller wins first-loss arbitration.
///
/// The caller must own the loss runner and call this outside owner locks.
/// `error_ref` transfers to the cell and stays valid through delivery or disposal.
pub fn finishLossContext(
    cell: *registry_mod.Cell(LossContext),
    io: Io,
    reason: api.DeviceLostReason,
    error_ref: ?core.ErrorRef,
) void {
    cell.context.reason = reason;
    cell.context.terminal_error = error_ref;
    cell.header.registry.publish(io, &cell.header, false);
}
/// Clears matching high-device pins after reserving two-phase owner detachment.
///
/// The caller must hold `device.lifecycle_mutex` and the exclusive detach right
/// for `header`.
pub fn detachDeviceContextLocked(header: *registry_mod.Header, device: *Device) void {
    if (registry_mod.Cell(LossContext).matchesOperations(header, loss_operations)) {
        const cell: *registry_mod.Cell(LossContext) = @fieldParentPtr("header", header);
        if (cell.context.device_pin_held) {
            std.debug.assert(cell.context.device == device);
            cell.context.device = null;
            cell.context.device_pin_held = false;
            native_async.releaseLossOperationLocked(device);
        } else std.debug.assert(cell.context.device == null);
    } else if (registry_mod.Cell(DeviceRequest).matchesOperations(header, device_operations)) {
        const cell: *registry_mod.Cell(DeviceRequest) = @fieldParentPtr("header", header);
        std.debug.assert(cell.context.device_pin == device);
        cell.context.device_pin = null;
        native_async.releaseAsyncOperationLocked(device);
    } else {
        if (native_pipeline.detachDeviceContextLocked(header, device)) return;
        if (native_map_queue.detachDeviceContextLocked(header, device)) return;
        if (native_scope_info.detachDeviceContextLocked(header, device)) return;
        // Device owners attach only root, pipeline, map, queue, pop, and info cells.
        // Every supported static operations table must have a typed detach hook.
        @panic("unknown attached device cell");
    }
}
/// Posts `task` to an initialized root pool without allocating.
///
/// Keep the submitted `io` provider valid through task completion. The task
/// must keep every owner pin it needs until it finishes.
pub fn postTask(instance: *Instance, io: Io, task: platform.Task) api.AsyncStartError!void {
    try platform.WorkerPool.postTask(io, &instance.root_executor.?.pool, task);
}

/// Releases the actual AdapterList behind an owned Adapter handle.
///
/// Requires the allocator used for the root. Live child devices or Adapter
/// requests refuse release unchanged. Retry with the same handle only when
/// `consumed` is false.
pub fn releaseAdapterResult(
    allocator: Allocator,
    io: Io,
    handle: api.Adapter,
) RootReleaseResult {
    const adapter = handles.resolveAdapter(handle) catch return .{
        .consumed = false,
        .failure = error.InvalidHandle,
    };
    const selection = switch (adapter.root_record.ownership) {
        .adapter_result => |owner| owner,
        else => return .{ .consumed = false, .failure = error.BorrowedRoot },
    };
    if (!sameAllocator(allocator, selection.allocator)) {
        return .{ .consumed = false, .failure = error.AllocatorMismatch };
    }
    selection.instance.lifecycle_mutex.lockUncancelable(io);
    if (selection.ownership != .caller) {
        selection.instance.lifecycle_mutex.unlock(io);
        return .{ .consumed = false, .failure = error.ResourceInUse };
    }
    for (selection.list.?.items) |item| {
        if (item.active_root_requests != 0 or item.live_device_count != 0) {
            selection.instance.lifecycle_mutex.unlock(io);
            return .{ .consumed = false, .failure = error.ResourceInUse };
        }
    }
    selection.ownership = .disposing;
    selection.instance.lifecycle_mutex.unlock(io);
    selection.list.?.deinit(io) catch {
        selection.ownership = .caller;
        return .{ .consumed = false, .failure = error.ResourceInUse };
    };
    allocator.destroy(selection);
    return .{ .consumed = true };
}
/// Releases an owned high Device and its root wrapper.
///
/// Requires the allocator used for the root. A host that remains initialized
/// keeps the handle valid for retry. Final host consumption invalidates the
/// handle, even when cleanup reports a failure.
pub fn releaseDeviceResult(
    allocator: Allocator,
    io: Io,
    handle: api.Device,
) RootReleaseResult {
    const device = handles.resolveDevice(handle) catch return .{
        .consumed = false,
        .failure = error.InvalidHandle,
    };
    const owned = switch (device.root_record.ownership) {
        .device_result => |owner| owner,
        else => return .{ .consumed = false, .failure = error.BorrowedRoot },
    };
    if (!sameAllocator(allocator, owned.allocator)) {
        return .{ .consumed = false, .failure = error.AllocatorMismatch };
    }
    if (owned.ownership != .caller) return .{ .consumed = false, .failure = error.ResourceInUse };
    var failure: ?OwnedRootReleaseError = null;
    device.deinit(allocator, io) catch |err| {
        failure = err;
    };
    if (!device.host_deinitialized) return .{ .consumed = false, .failure = failure };
    owned.input.deinit(allocator);
    allocator.destroy(owned);
    return .{ .consumed = true, .failure = failure };
}
fn queueDisposal(owned: *OwnedDevice, io: Io, collecting: bool) void {
    const instance = owned.instance;
    instance.lifecycle_mutex.lockUncancelable(io);
    defer instance.lifecycle_mutex.unlock(io);
    std.debug.assert(owned.disposal_slot_held);
    std.debug.assert(owned.disposal_state == .none);
    owned.ownership = .disposing;
    owned.disposal_state = if (collecting) .collecting else .queued;
    owned.disposal_next = instance.root_disposals;
    instance.root_disposals = owned;
    instance.root_disposal_count += 1;
}
fn collectQueuedDevice(owned: *OwnedDevice, io: Io) void {
    const instance = owned.instance;
    std.debug.assert(owned.disposal_state == .collecting);
    var failure: ?device_mod.CleanupError = null;
    owned.high.deinit(owned.allocator, io) catch |err| {
        failure = err;
    };
    instance.lifecycle_mutex.lockUncancelable(io);
    if (failure) |err| {
        if (instance.root_disposal_error == null) instance.root_disposal_error = err;
        if (owned.cleanup_error == null) owned.cleanup_error = err;
    }
    if (!owned.high.host_deinitialized) {
        owned.disposal_state = .queued;
        instance.lifecycle_mutex.unlock(io);
        return;
    }
    var link = &instance.root_disposals;
    for (0..instance.root_disposal_count) |_| {
        if (link.* == owned) break;
        link = &link.*.?.disposal_next;
    }
    std.debug.assert(link.* == owned);
    link.* = owned.disposal_next;
    instance.root_disposal_count -= 1;
    instance.root_disposal_slots -= 1;
    owned.disposal_slot_held = false;
    instance.lifecycle_mutex.unlock(io);
    const allocator = owned.allocator;
    owned.input.deinit(allocator);
    allocator.destroy(owned);
}
/// Retries hidden-device cleanup for one snapshot of the disposal queue.
///
/// It processes only the count present at entry and does not implicitly retry
/// a retained owner. It returns the first cleanup failure and leaves retained
/// owners queued for a later explicit call. Allocator mismatch or a conflicting
/// collector leaves the queue unchanged.
pub fn collectRootDisposals(
    instance: *Instance,
    allocator: Allocator,
    io: Io,
) RootDisposalError!void {
    instance.acquireRootOperation(io) catch return error.InstanceInUse;
    defer instance.releaseRootOperation(io);
    instance.lifecycle_mutex.lockUncancelable(io);
    if (instance.completions) |registry| {
        if (!sameAllocator(allocator, registry.allocator)) {
            instance.lifecycle_mutex.unlock(io);
            return error.AllocatorMismatch;
        }
    }
    if (instance.root_disposal_collecting) {
        instance.lifecycle_mutex.unlock(io);
        return error.InstanceInUse;
    }
    const count = instance.root_disposal_count;
    var cursor = instance.root_disposals;
    for (0..count) |_| {
        const owned = cursor.?;
        if (owned.disposal_state != .queued) {
            instance.lifecycle_mutex.unlock(io);
            return error.InstanceInUse;
        }
        cursor = owned.disposal_next;
    }
    instance.root_disposal_collecting = true;
    cursor = instance.root_disposals;
    for (0..count) |_| {
        cursor.?.disposal_state = .collecting;
        cursor = cursor.?.disposal_next;
    }
    cursor = instance.root_disposals;
    instance.lifecycle_mutex.unlock(io);
    for (0..count) |_| {
        const owned = cursor.?;
        cursor = owned.disposal_next;
        collectQueuedDevice(owned, io);
    }
    instance.lifecycle_mutex.lockUncancelable(io);
    const failure = instance.root_disposal_error;
    instance.root_disposal_error = null;
    instance.root_disposal_collecting = false;
    instance.lifecycle_mutex.unlock(io);
    if (failure) |err| return err;
}

/// Dispatches ready root completions. An empty call allocates nothing.
pub fn processEvents(self: api.Instance, io: Io) api.ProcessEventsError!void {
    const instance = handles.resolveInstance(self) catch return error.InstanceShutDown;
    instance.acquireRootOperation(io) catch |err| switch (err) {
        error.ReferenceCountOverflow => return error.ReferenceCountOverflow,
        else => return error.InstanceShutDown,
    };
    defer instance.releaseRootOperation(io);
    instance.lifecycle_mutex.lockUncancelable(io);
    const registry = instance.completions;
    instance.lifecycle_mutex.unlock(io);
    if (registry) |owner| try owner.processEvents(io);
}
/// Waits for `future_count` Future IDs with `timeout_ns` in nanoseconds.
///
/// The optional slice must match `future_count`; `null` is valid only when the
/// count is zero. A zero-count wait succeeds after this shape check. Future IDs
/// report completion but do not grant root ownership. A nonempty wait without
/// source authority returns `error.MissingFutureNamespaceSource`. With authority
/// but no issued Future, it returns `error.InvalidFutureId` without creating a
/// registry. Excess count returns `error.WaitCountExceeded`; a refused positive
/// timeout returns `error.TimedWaitUnavailable`.
pub fn waitAny(
    self: api.Instance,
    io: Io,
    future_count: usize,
    futures: ?[]api.FutureWaitInfo,
    timeout_ns: u64,
) api.FutureWaitError!api.WaitStatus {
    const instance = handles.resolveInstance(self) catch return error.InstanceShutDown;
    if (futures) |slice| {
        if (slice.len != future_count) return error.FutureCountMismatch;
    } else if (future_count != 0) return error.FutureCountMismatch;
    if (future_count == 0) return .success;
    if (future_count > instance.async_options.max_wait_count) return error.WaitCountExceeded;
    instance.acquireRootOperation(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.ReferenceCountOverflow => return error.ReferenceCountOverflow,
        error.InstanceShutDown => return error.InstanceShutDown,
    };
    defer instance.releaseRootOperation(io);
    if (instance.future_namespace_source == null) return error.MissingFutureNamespaceSource;
    instance.lifecycle_mutex.lockUncancelable(io);
    const attached = instance.completions;
    instance.lifecycle_mutex.unlock(io);
    const registry = attached orelse return error.InvalidFutureId;
    return registry.waitAnyCount(io, future_count, futures, timeout_ns);
}

fn closePreflightLocked(instance: *Instance, io: Io) error{InstanceInUse}!void {
    if (instance.root_state != .open or
        instance.list_count != 0 or
        instance.device_count != 0 or
        instance.active_callbacks != 0 or
        instance.active_operations != instance.accepted_root_operations or
        instance.root_disposal_count != 0 or
        instance.root_disposal_collecting or
        instance.root_disposal_error != null)
        return error.InstanceInUse;
    if (instance.completions) |registry| {
        registry.ownerPreflight(
            io,
            @as(u64, registry.namespace) << 32,
        ) catch return error.InstanceInUse;
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);
        if (registry.prepared_cells != 0 or
            registry.reclaiming_cells != 0 or
            registry.active_callbacks != 0 or
            registry.dispatch_exits != 0 or
            registry.waiters != 0 or
            registry.processors != 0)
            return error.InstanceInUse;
        var cursor = registry.first;
        for (0..registry.index.count()) |_| {
            const header = cursor.?;
            if (header.observers != 0 or
                header.candidates != 0 or
                header.delivery == .claimed or
                header.owner_detaching)
                return error.InstanceInUse;
            cursor = header.next;
        }
    }
}
fn detachRemainingRootCells(
    instance: *Instance,
    registry: *Registry,
    io: Io,
) error{InstanceInUse}!void {
    const identity = @as(u64, registry.namespace) << 32;
    for (0..registry.options.max_live_operations + 1) |_| {
        instance.lifecycle_mutex.lockUncancelable(io);
        const candidate = registry.retainOwnerCandidate(io, identity) catch {
            instance.lifecycle_mutex.unlock(io);
            return error.InstanceInUse;
        } orelse {
            instance.lifecycle_mutex.unlock(io);
            return;
        };
        registry.beginOwnerDetach(io, candidate) catch {
            instance.lifecycle_mutex.unlock(io);
            releaseRef(registry, io, candidate, .candidate);
            return error.InstanceInUse;
        };
        if (registry_mod.Cell(AdapterRequest).matchesOperations(candidate, adapter_operations)) {
            const cell: *registry_mod.Cell(AdapterRequest) = @fieldParentPtr("header", candidate);
            if (cell.context.root_pin_held) {
                instance.active_operations -= 1;
                if (cell.context.accepted_pin_held) instance.accepted_root_operations -= 1;
                cell.context.root_pin_held = false;
            }
            cell.context.instance = null;
        } else if (registry_mod.Cell(DeviceRequest).matchesOperations(
            candidate,
            device_operations,
        )) {
            const cell: *registry_mod.Cell(DeviceRequest) = @fieldParentPtr("header", candidate);
            if (cell.context.adapter_pin_held) {
                cell.context.adapter.?.active_root_requests -= 1;
                cell.context.adapter_pin_held = false;
            }
            if (cell.context.root_pin_held) {
                instance.active_operations -= 1;
                if (cell.context.accepted_pin_held) instance.accepted_root_operations -= 1;
                cell.context.root_pin_held = false;
            }
            cell.context.instance = null;
            cell.context.adapter = null;
        } else if (registry_mod.Cell(LossContext).matchesOperations(
            candidate,
            loss_operations,
        )) {
            const cell: *registry_mod.Cell(LossContext) = @fieldParentPtr("header", candidate);
            if (cell.context.root_pin_held) {
                instance.active_operations -= 1;
                if (cell.context.accepted_pin_held) instance.accepted_root_operations -= 1;
                cell.context.root_pin_held = false;
            }
            cell.context.pending_instance = null;
        } else @panic("unknown instance root cell");
        registry.detachOwner(io, candidate);
        instance.lifecycle_mutex.unlock(io);
        releaseRef(registry, io, candidate, .candidate);
    }
    return error.InstanceInUse;
}
/// Closes an Instance after root preflight and accepted-work drain.
///
/// Live children, callbacks, observers, waiters, processors, or queued disposals
/// return `error.InstanceInUse` without changing Instance state. After admission,
/// close drains accepted work, then runs final host-only callbacks on the closing
/// caller outside owner locks. It ignores callback mode for that delivery.
/// Native teardown marks the Instance closed even if consumed cleanup reports an
/// error.
pub fn close(
    instance: *Instance,
    _: Allocator,
    io: Io,
) Instance.DeinitError!void {
    instance.lifecycle_mutex.lockUncancelable(io);
    if (instance.root_state == .closed) {
        instance.lifecycle_mutex.unlock(io);
        return;
    }
    closePreflightLocked(instance, io) catch |err| {
        instance.lifecycle_mutex.unlock(io);
        return err;
    };
    instance.root_state = .closing;
    const executor = instance.root_executor;
    const registry = instance.completions;
    const executor_allocator = if (registry) |owner| owner.allocator else null;
    instance.lifecycle_mutex.unlock(io);
    if (executor) |owner| platform.WorkerPool.join(io, &owner.pool);
    if (registry) |owner| {
        try detachRemainingRootCells(instance, owner, io);
        try owner.close(io);
    }
    instance.lifecycle_mutex.lockUncancelable(io);
    std.debug.assert(instance.active_operations == 0);
    std.debug.assert(instance.accepted_root_operations == 0);
    std.debug.assert(instance.list_count == 0);
    std.debug.assert(instance.device_count == 0);
    instance.completions = null;
    instance.root_executor = null;
    instance.lifecycle_mutex.unlock(io);
    if (executor) |owner| executor_allocator.?.destroy(owner);
    var native_failure: ?@import("vulkan_device.zig").ProcError = null;
    if (instance.native_context) |context| {
        const allocator = context.backend.allocator;
        context.deinit() catch |err| {
            native_failure = err;
        };
        allocator.destroy(context);
        instance.native_context = null;
    }
    instance.lifecycle_mutex.lockUncancelable(io);
    instance.root_state = .closed;
    instance.lifecycle_mutex.unlock(io);
    if (native_failure) |failure| return failure;
}
