//! The guarded core device: one arena, error scopes, and a failure injector.
//!
//! Bind a stable caller-owned object mutex at initialization. Once the device
//! is at its final address, bind an optional high owner under ObjectGuard and
//! publish borrows/resources. Payload retirement preserves canonical headers
//! and references. Final deinit refuses outstanding references unchanged.

const std = @import("std");
const errors = @import("errors.zig");
const error_injector = @import("error_injector.zig");
const error_scope = @import("error_scope.zig");
const handle = @import("handle.zig");
const object = @import("object.zig");

/// Everything a handle can be rejected for. A handle is rejected, never
/// crashed on: `docs/30-port-design.md` §1.1.
pub const HandleError = errors.ValidationError;

/// Immutable canonical locator, defined beside the borrowed Handle.
pub const CoreDeviceBorrow = handle.CoreDeviceBorrow;

/// One owner of arena storage; move only before the first resource or borrow.
/// Its allocator and bound object mutex outlive all payloads and late aliases.
pub const Device = struct {
    arena: object.ObjectArena,
    error_scopes: error_scope.ErrorScopeStack,
    injector: error_injector.ErrorInjector,

    pub const InitOptions = struct {
        object_mutex: *std.Io.Mutex,
        /// Where an error that no scope took goes: Dawn forwards one to the
        /// uncaptured error callback (`src/dawn/native/ErrorScope.h:92-95`) and
        /// takes that callback from the descriptor at construction
        /// (`src/dawn/native/Device.cpp:280`), as the port does.
        uncaptured_context: *anyopaque,
        uncaptured_callback: error_scope.UncapturedErrorCallback,
    };

    /// Creates a device. The arena takes `allocator` as its child, so an object
    /// comes from the arena and never from anywhere else.
    ///
    /// This allocates nothing: the arena asks its child for memory on the first
    /// object.
    pub fn init(allocator: std.mem.Allocator, options: InitOptions) Device {
        return .{
            .arena = object.ObjectArena.init(allocator, .{
                .object_mutex = options.object_mutex,
            }),
            .error_scopes = error_scope.ErrorScopeStack.init(.{
                .allocator = allocator,
                .uncaptured_context = options.uncaptured_context,
                .uncaptured_callback = options.uncaptured_callback,
            }),
            .injector = error_injector.ErrorInjector.init(),
        };
    }

    /// Reclaims the host only with matching allocator and zero user/lease refs.
    /// Refusal leaves arena, references, scopes, and payloads unchanged. Success
    /// invalidates every borrow/handle and poisons the receiver; unlock uses the
    /// guard's separately captured still-live mutex.
    pub fn deinit(
        self: *Device,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
    ) object.LifetimeError!void {
        try self.arena.checkAllocator(guard, allocator);
        try self.arena.objects.preflightDeinitLocked(guard);
        try self.error_scopes.preflightDeinit(guard);
        try self.error_scopes.deinit(allocator, guard);
        try self.arena.deinit(allocator, guard);
        self.* = undefined;
    }

    /// Borrows the canonical list at the device's final address. Copying this
    /// locator owns no reference and does not extend the device's lifetime.
    pub fn borrow(self: *Device) CoreDeviceBorrow {
        return .{ .objects = self.arena.objectList() };
    }

    /// Binds immutable host metadata at the final address, before first create.
    /// Rebinding to the same owner is harmless; changing a bound owner is invalid.
    pub fn bindTrackingOwner(
        self: *Device,
        guard: *const object.ObjectGuard,
        high_owner: *anyopaque,
    ) void {
        const objects = self.arena.objectList();
        guard.assertOwns(objects);
        self.error_scopes.bind(guard);
        if (objects.high_owner) |bound| {
            std.debug.assert(bound == high_owner);
            return;
        }
        std.debug.assert(objects.total_reference_count == 0);
        std.debug.assert(objects.tracked_count == 0);
        std.debug.assert(!objects.marked_destroyed);
        std.debug.assert(self.arena.queryCapacity(guard) == 0);
        objects.high_owner = high_owner;
    }

    /// Returns an unpublished initial user/lease ref. Initialize every payload
    /// field then attach, or clean temporaries and discardUnpublishedLocked.
    pub fn create(
        self: *Device,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        comptime T: type,
        options: object.CreateOptions(T),
    ) object.CreateError!*T {
        return self.arena.create(allocator, guard, T, options);
    }

    /// Borrows the canonical header without acquiring another reference.
    /// The pointer argument must belong to this device. Returning a handle
    /// marks identity escaped, so publish only after fallible construction;
    /// discardUnpublishedLocked is no longer permitted afterward.
    pub fn handleFor(
        self: *Device,
        guard: *const object.ObjectGuard,
        comptime T: type,
        target: *T,
        kind: handle.Handle.Kind,
    ) handle.Handle {
        // Name the actual header field, without assuming the owner's auto layout.
        const header: *object.Object = &target.header;
        guard.assertOwns(self.arena.objectList());
        std.debug.assert(header.tracking == self.arena.objectList());
        header.reference_escaped = true;
        // `@as` and not `@alignCast`: `ObjectPtr` carries the alignment the
        // header already has, and `object.zig` asserts the two agree.
        return .{ .ptr = @as(handle.ObjectPtr, header), .kind = kind };
    }

    /// Explicitly retires one live core payload without consuming its aliases.
    /// A second handle destroy reports StaleHandle; late Rc release remains valid.
    pub fn destroy(
        self: *Device,
        guard: *const object.ObjectGuard,
        io: std.Io,
        target: handle.Handle,
    ) HandleError!void {
        const header = try self.resolveHeader(guard, target);
        header.retirePayloadLocked(guard, io, .early_destroy);
    }

    /// Resolves a borrowed live core object. The pointer is usable only under
    /// this guard. Failed objects remain resolvable; native callers require alive.
    pub fn resolve(
        self: *Device,
        guard: *const object.ObjectGuard,
        comptime T: type,
        target: handle.Handle,
    ) HandleError!*T {
        const header = try self.resolveHeader(guard, target);
        return @fieldParentPtr("header", header);
    }

    /// Resolves retained host identity for owned-handle retain/release, including
    /// a retired payload. Never use this result to read native payload fields.
    /// Forged pointers and references after host deinit remain outside contract.
    pub fn resolveReference(
        self: *Device,
        guard: *const object.ObjectGuard,
        target: handle.Handle,
    ) HandleError!*object.Object {
        guard.assertOwns(self.arena.objectList());
        const header: *object.Object = @ptrCast(target.ptr);
        if (header.kind != target.kind) return error.HandleKindMismatch;
        if (header.tracking != self.arena.objectList()) return error.StaleHandle;
        if (!header.node.linked or header.reference_count == 0) return error.StaleHandle;
        if (header.state == .initializing) return error.StaleHandle;
        return header;
    }

    /// Retires payloads newest-first without force-consuming user/lease refs.
    pub fn retirePayloadsLocked(
        self: *Device,
        guard: *const object.ObjectGuard,
        io: std.Io,
        reason: object.DestroyReason,
    ) void {
        self.arena.objects.retirePayloadsLocked(guard, io, reason);
    }

    /// Arena storage bytes committed since initialization.
    pub fn queryCapacity(self: *const Device, guard: *const object.ObjectGuard) usize {
        return self.arena.queryCapacity(guard);
    }

    /// Retained canonical headers, not the count of live native payloads.
    pub fn queryTrackedCount(self: *const Device, guard: *const object.ObjectGuard) usize {
        return self.arena.queryTrackedCount(guard);
    }

    /// Pushes a stable owned record under the canonical device guard.
    pub fn pushErrorScope(
        self: *Device,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        filter: error_scope.ErrorFilter,
    ) error_scope.ScopeAllocationError!void {
        try self.arena.checkAllocator(guard, allocator);
        return self.error_scopes.push(allocator, guard, filter);
    }

    /// Detaches matching now; the ticket waits for every accepted task pin.
    pub fn popErrorScope(self: *Device, guard: *const object.ObjectGuard) error_scope.PopError!error_scope.ScopeTicket {
        guard.assertOwns(self.arena.objectList());
        return self.error_scopes.beginPop(guard);
    }

    /// Detaches and binds the current innermost scope without allocation.
    /// Admission must already have succeeded. Every error leaves the stack and
    /// prepared owner unchanged; activate the returned binding after unlocking.
    pub fn popBoundErrorScope(
        self: *Device,
        guard: *const object.ObjectGuard,
        prepared: *error_scope.PreparedScopeBinding,
    ) error_scope.PopBoundError!error_scope.PopBoundResult {
        guard.assertOwns(self.arena.objectList());
        return self.error_scopes.popBound(guard, prepared);
    }

    pub fn captureScopeLeaseSet(
        self: *Device,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        possible: error_scope.ScopeCaptureMask,
    ) error_scope.ScopeAllocationError!error_scope.ScopeLeaseSet {
        try self.arena.checkAllocator(guard, allocator);
        return self.error_scopes.captureLeaseSet(allocator, guard, possible);
    }

    /// Consumes one owned diagnostic. Dispatch any returned delivery only
    /// after releasing every lock; no user callback runs from this function.
    pub fn handleError(
        self: *Device,
        guard: *const object.ObjectGuard,
        ref: errors.ErrorRef,
    ) ?error_scope.UncapturedDelivery {
        guard.assertOwns(self.arena.objectList());
        return self.error_scopes.handleError(guard, ref);
    }

    /// Borrows this final-address device, never a worker-local error value.
    pub fn errorSink(self: *Device, guard: *const object.ObjectGuard) error_scope.ErrorSink {
        guard.assertOwns(self.arena.objectList());
        self.error_scopes.bind(guard);
        return error_scope.ErrorSink.init(self, consumeDeviceError);
    }

    /// Checks what a handle must satisfy, and names the first thing it fails.
    ///
    /// The kind byte catches a buffer passed where a device belongs
    /// (`docs/30-port-design.md` §1.1). The list check catches a handle from
    /// another device. The link check catches an object this device already
    /// destroyed.
    fn resolveHeader(
        self: *Device,
        guard: *const object.ObjectGuard,
        target: handle.Handle,
    ) HandleError!*object.Object {
        guard.assertOwns(self.arena.objectList());
        // No `@alignCast`: `Handle.ptr` is `handle.ObjectPtr`, so the alignment
        // is in the type. `@ptrCast` only narrows `anyopaque` to `Object` here.
        const header: *object.Object = @ptrCast(target.ptr);
        if (header.kind != target.kind) return error.HandleKindMismatch;
        if (header.tracking != self.arena.objectList()) return error.StaleHandle;
        if (!header.isAlive(guard)) return error.StaleHandle;
        return header;
    }
};

fn consumeDeviceError(
    guard: *const object.ObjectGuard,
    context: *anyopaque,
    ref: errors.ErrorRef,
) ?error_scope.UncapturedDelivery {
    const device: *Device = @ptrCast(@alignCast(context));
    return device.handleError(guard, ref);
}

const Probe = struct {
    header: object.Object,
    teardown_count: *u64,
    last_reason: object.DestroyReason = .early_destroy,

    // Public because the arena trampoline crosses a module boundary.
    pub fn destroy(
        self: *Probe,
        guard: *const object.ObjectGuard,
        io: std.Io,
        reason: object.DestroyReason,
    ) void {
        _ = io;
        guard.assertOwns(self.header.tracking);
        self.teardown_count.* += 1;
        self.last_reason = reason;
    }
};

const Uncaptured = struct {
    count: u64 = 0,

    fn record(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: *anyopaque,
        data: errors.ErrorView,
    ) void {
        _ = io;
        const self: *Uncaptured = @ptrCast(@alignCast(context));
        self.count += 1;
        // `Allocator` has no `==`, and its `ptr` may be `undefined`
        // (`lib/std/mem/Allocator.zig:16-19`). The vtable is the one field that
        // names the implementation, and `std.testing.allocator` is a comptime
        // const, so both sides carry the same address.
        std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
        std.debug.assert(data.message.len > 0);
    }
};

test "guarded handles preserve failed liveness and retained retired identities" {
    var uncaptured: Uncaptured = .{};
    var teardown_count: u64 = 0;
    var mutex: std.Io.Mutex = .init;
    var device = Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &uncaptured,
        .uncaptured_callback = Uncaptured.record,
    });
    var guard = object.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const probe = try device.create(std.testing.allocator, &guard, Probe, .{
        .kind = .buffer,
        .state = .initializing,
        .initial_reference = .user,
        .label = "probe",
    });
    probe.teardown_count = &teardown_count;
    probe.last_reason = .early_destroy;
    probe.header.setInitializedError(&guard, error.LimitExceeded);
    probe.header.attach(&guard, std.testing.io);
    const target = device.handleFor(&guard, Probe, probe, .buffer);
    try std.testing.expect(probe.header.isFailed(&guard));
    try std.testing.expect(probe.header.isAlive(&guard));
    try std.testing.expectEqual(probe, try device.resolve(&guard, Probe, target));
    try std.testing.expectEqualStrings("probe", probe.header.label);
    const mislabelled: handle.Handle = .{ .ptr = target.ptr, .kind = .device };
    try std.testing.expectError(
        error.HandleKindMismatch,
        device.resolve(&guard, Probe, mislabelled),
    );
    try device.pushErrorScope(std.testing.allocator, &guard, .validation);
    var draft = try errors.ErrorDraft.init(
        std.testing.allocator,
        .{ .validation = error.LimitExceeded },
        &.{.{ .text = "maxTextureDimension2D" }},
    );
    defer draft.discard();
    var reservation = try errors.ErrorReservation.prepare(std.testing.allocator);
    defer reservation.discard();
    try std.testing.expect(device.errorSink(&guard).consumeError(&guard, reservation.seal(&draft)) == null);
    try std.testing.expectEqual(@as(u64, 0), uncaptured.count);
    var ticket = try device.popErrorScope(&guard);
    var result = try ticket.take(&guard);
    defer result.deinit();
    const held = (result.error_ref orelse return error.ScopeCapturedNothing).view();
    try std.testing.expectEqualStrings(
        "the request is above the device limit maxTextureDimension2D",
        held.message,
    );
    try device.destroy(&guard, std.testing.io, target);
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, Probe, target));
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 1), teardown_count);
    try std.testing.expectEqual(object.DestroyReason.early_destroy, probe.last_reason);
    const retired_identity = try device.resolveReference(&guard, target);
    try std.testing.expectEqual(&probe.header, retired_identity);
    try retired_identity.retainUserLocked(&guard);
    try retired_identity.releaseUserLocked(&guard, std.testing.io);
    try (try device.resolveReference(&guard, target)).releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
    try std.testing.expectError(error.StaleHandle, device.resolveReference(&guard, target));
}

test "stable core borrow binds the final high owner without a captured stack address" {
    var uncaptured: Uncaptured = .{};
    var mutex: std.Io.Mutex = .init;
    var device = Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &uncaptured,
        .uncaptured_callback = Uncaptured.record,
    });
    var guard = object.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var high_owner: u64 = 7;
    device.bindTrackingOwner(&guard, &high_owner);
    device.bindTrackingOwner(&guard, &high_owner);
    const borrow = device.borrow();
    var teardown_count: u64 = 0;
    const probe = try device.create(std.testing.allocator, &guard, Probe, .{
        .kind = .buffer,
        .initial_reference = .lease,
    });
    probe.teardown_count = &teardown_count;
    probe.last_reason = .early_destroy;
    probe.header.attach(&guard, std.testing.io);
    try std.testing.expectEqual(probe.header.tracking, borrow.objectList());
    try std.testing.expectEqual(@as(?*anyopaque, &high_owner), borrow.highOwner());
    try std.testing.expectError(
        error.ResourceInUse,
        device.deinit(std.testing.allocator, &guard),
    );
    try std.testing.expectEqual(@as(u32, 1), probe.header.reference_count);
    try std.testing.expect(probe.header.isAlive(&guard));
    try std.testing.expectEqual(@as(u64, 0), teardown_count);
    device.retirePayloadsLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectEqual(@as(?*anyopaque, &high_owner), borrow.highOwner());
    try std.testing.expectEqual(@as(u64, 1), teardown_count);
    try std.testing.expectError(
        error.ResourceInUse,
        device.deinit(std.testing.allocator, &guard),
    );
    probe.header.releaseLeaseLocked(&guard, std.testing.io);
}

test "constructor rollback refuses a handle that has escaped before attachment" {
    var uncaptured: Uncaptured = .{};
    var mutex: std.Io.Mutex = .init;
    var device = Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &uncaptured,
        .uncaptured_callback = Uncaptured.record,
    });
    var guard = object.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const probe = try device.create(std.testing.allocator, &guard, Probe, .{
        .kind = .buffer,
        .initial_reference = .user,
    });
    const escaped = device.handleFor(&guard, Probe, probe, .buffer);
    try std.testing.expectError(
        error.ResourceInUse,
        probe.header.discardUnpublishedLocked(&guard),
    );
    try std.testing.expectEqual(@as(u32, 1), probe.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), probe.header.user_reference_count);
    var teardown_count: u64 = 0;
    probe.teardown_count = &teardown_count;
    probe.last_reason = .early_destroy;
    probe.header.attach(&guard, std.testing.io);
    try (try device.resolveReference(&guard, escaped)).releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), teardown_count);
}
