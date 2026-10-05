//! The device: one arena, one error-scope stack, one failure injector.
//!
//! **What this file is.** The M3 part of the device. `docs/10-architecture.md`
//! "Object model" fixes the arena and the handle, and `docs/30-port-design.md`
//! §1.1 fixes what a stale handle does.
//!
//! **What this file does not claim.** It does not claim a queue, a timeline or a
//! tick. Those land with the platform module at milestone M4, and the device
//! takes a device mutex at the same milestone. Nothing here locks, because
//! nothing above `core` runs on two threads yet.

const std = @import("std");
const errors = @import("errors.zig");
const error_injector = @import("error_injector.zig");
const error_scope = @import("error_scope.zig");
const handle = @import("handle.zig");
const object = @import("object.zig");

/// Everything a handle can be rejected for. A handle is rejected, never
/// crashed on: `docs/30-port-design.md` §1.1.
pub const HandleError = errors.ValidationError;

pub const Device = struct {
    arena: object.ObjectArena,
    error_scopes: error_scope.ErrorScopeStack,
    injector: error_injector.ErrorInjector,

    pub const InitOptions = struct {
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
            .arena = object.ObjectArena.init(allocator),
            .error_scopes = error_scope.ErrorScopeStack.init(.{
                .uncaptured_context = options.uncaptured_context,
                .uncaptured_callback = options.uncaptured_callback,
            }),
            .injector = error_injector.ErrorInjector.init(),
        };
    }

    /// Destroys every object, closes every open scope and reclaims the arena.
    /// After this a handle taken before it dangles and the receiver is poison.
    pub fn deinit(self: *Device, allocator: std.mem.Allocator) void {
        self.error_scopes.deinit(allocator);
        self.arena.deinit();
        // The device is gone and nothing reads this value again, so the receiver
        // is poison rather than a half-reset device whose zero capacity is the
        // only record of the reclamation.
        self.* = undefined;
    }

    /// Creates one object and returns it untracked. The reference count starts
    /// at one, which is the reference the caller holds.
    ///
    /// The arena allocates the block and writes only the header
    /// (`src/core/object.zig:330-334`), so the bytes after it are undefined until
    /// the caller writes them. The caller then calls `Object.attach`, which is
    /// the only thing that tracks, and `handleFor` for the handle.
    pub fn create(
        self: *Device,
        comptime T: type,
        options: object.CreateOptions(T),
    ) std.mem.Allocator.Error!*T {
        return self.arena.create(T, options);
    }

    /// The handle that names `target`. This is the inverse of `resolve`: the
    /// caller holds the object because it made it, and the handle is what it
    /// hands out.
    ///
    /// **The target is a pointer, and the type says so.** `T` and `target` are
    /// named separately rather than taken as one `anytype` because a by-value
    /// object would make `&target.header` an address of this frame, and the
    /// handle would outlive it. Naming the type is what turns that mistake into
    /// a compile error at every call site instead of a dangling handle.
    ///
    /// The assert is the ownership check `resolveHeader` cannot make. The
    /// header stores the list it belongs to, and the caller here already has
    /// the object, so the only question left is whether this device owns it.
    pub fn handleFor(
        self: *Device,
        comptime T: type,
        target: *T,
        kind: handle.Handle.Kind,
    ) handle.Handle {
        // `assertHeader` puts the header first in every arena object
        // (`src/core/object.zig:275-285`), so the object pointer and the
        // header pointer are the same address and the field needs no cast.
        // `@fieldParentPtr` cannot be used: it resolves the parent from the
        // annotated result type, which here is the field type and not the
        // parent, so it reports that `Object` has no `header` field.
        const header: *object.Object = &target.header;
        std.debug.assert(header.tracking == self.arena.objectList());
        // `@as` and not `@alignCast`: `ObjectPtr` carries the alignment the
        // header already has, and `object.zig` asserts the two agree.
        return .{ .ptr = @as(handle.ObjectPtr, header), .kind = kind };
    }

    /// Marks the object destroyed and runs its teardown.
    ///
    /// The memory stays in the arena, so a second destroy on the same handle
    /// reports `error.StaleHandle` and not a read of freed memory.
    pub fn destroy(self: *Device, target: handle.Handle) HandleError!void {
        const header = try self.resolveHeader(target);
        header.destroy(.early_destroy);
    }

    /// The object a handle names, or the rule that rejects the handle.
    pub fn resolve(self: *Device, comptime T: type, target: handle.Handle) HandleError!*T {
        const header = try self.resolveHeader(target);
        return @fieldParentPtr("header", header);
    }

    /// The bytes the arena holds right now.
    ///
    /// `deinit` poisons the receiver, so a read of this after it is a read of
    /// poison. Where the blocks went is asked of the child allocator, which is
    /// the ledger that outlives the device: `test/object_arena.zig` hands the
    /// device a child of its own and asserts that child reports no leak.
    pub fn queryCapacity(self: *const Device) usize {
        return self.arena.queryCapacity();
    }

    /// The number of objects the device still holds alive.
    pub fn queryTrackedCount(self: *const Device) usize {
        return self.arena.queryTrackedCount();
    }

    pub fn pushErrorScope(
        self: *Device,
        allocator: std.mem.Allocator,
        filter: error_scope.ErrorFilter,
    ) std.mem.Allocator.Error!void {
        return self.error_scopes.push(allocator, filter);
    }

    /// Closes the innermost scope. The caller then owns the scope and frees its
    /// payload with `scope.deinit(allocator)`. The `ErrorData` struct the raiser
    /// passed in stays the raiser's (`docs/40-plan.md:2393`).
    pub fn popErrorScope(self: *Device) error_scope.PopError!error_scope.ErrorScope {
        return self.error_scopes.pop();
    }

    /// Hands the error to the innermost scope that takes it. The stack frees the
    /// payload in every case, and the `ErrorData` struct stays the raiser's.
    pub fn handleError(
        self: *Device,
        allocator: std.mem.Allocator,
        data: *errors.ErrorData,
    ) bool {
        return self.error_scopes.handleError(allocator, data);
    }

    /// The device as a sink, so a caller hands its error to the device without
    /// knowing that the device holds a scope stack.
    pub fn errorSink(self: *Device) error_scope.ErrorSink {
        return error_scope.ErrorSink.init(self, consumeDeviceError);
    }

    /// Checks what a handle must satisfy, and names the first thing it fails.
    ///
    /// The kind byte catches a buffer passed where a device belongs
    /// (`docs/30-port-design.md` §1.1). The list check catches a handle from
    /// another device. The link check catches an object this device already
    /// destroyed.
    fn resolveHeader(self: *Device, target: handle.Handle) HandleError!*object.Object {
        // No `@alignCast`: `Handle.ptr` is `handle.ObjectPtr`, so the alignment
        // is in the type. `@ptrCast` only narrows `anyopaque` to `Object` here.
        const header: *object.Object = @ptrCast(target.ptr);
        if (header.kind != target.kind) return error.HandleKindMismatch;
        if (header.tracking != self.arena.objectList()) return error.StaleHandle;
        if (!header.isAlive()) return error.StaleHandle;
        return header;
    }
};

fn consumeDeviceError(
    allocator: std.mem.Allocator,
    context: *anyopaque,
    data: *errors.ErrorData,
) void {
    const device: *Device = @ptrCast(@alignCast(context));
    // The stack frees the payload either way, so the sink has nothing left to do
    // with the "a scope took it" answer, and `ErrorSink.consumeError` is `void`
    // (`src/core/error_scope.zig:257-261`). Dawn's `ConsumeError` is `void` for
    // the same reason (`src/dawn/native/ErrorSink.h:138-143`).
    _ = device.handleError(allocator, data);
}

const Probe = struct {
    header: object.Object,
    teardown_count: *u64,
    last_reason: object.DestroyReason = .early_destroy,

    // Public because `ObjectArena.destroyTrampoline` calls it from
    // `src/core/object.zig`, and Zig privacy is module-scoped
    // (`src/core/object.zig:416-421`).
    pub fn destroy(self: *Probe, reason: object.DestroyReason) void {
        self.teardown_count.* += 1;
        self.last_reason = reason;
    }
};

const Uncaptured = struct {
    count: u64 = 0,

    fn record(
        allocator: std.mem.Allocator,
        context: *anyopaque,
        data: *const errors.ErrorData,
    ) void {
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

test "a device resolves its own handles and rejects everything else" {
    var uncaptured: Uncaptured = .{};
    var teardown_count: u64 = 0;
    // The arena's child is the ledger that outlives the device, so it is where
    // the blocks are checked after `deinit` has poisoned the receiver.
    var child: std.heap.DebugAllocator(.{}) = .{};
    defer std.testing.expect(child.deinit() == .ok) catch @panic("device block leaked");
    var device: Device = .init(child.allocator(), .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = Uncaptured.record,
    });

    const probe = try device.create(Probe, .{ .kind = .buffer, .label = "probe" });
    probe.teardown_count = &teardown_count;
    probe.header.attach();
    const target = device.handleFor(Probe, probe, .buffer);

    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount());
    try std.testing.expect(device.queryCapacity() > 0);
    try std.testing.expectEqualStrings("probe", probe.header.label);

    const mislabelled: handle.Handle = .{ .ptr = @as(handle.ObjectPtr, probe), .kind = .device };
    try std.testing.expectError(error.HandleKindMismatch, device.resolve(Probe, mislabelled));

    try device.pushErrorScope(std.testing.allocator, .validation);
    var data = try errors.initValidation(
        std.testing.allocator,
        error.LimitExceeded,
        &.{.{ .text = "maxTextureDimension2D" }},
    );
    const sink = device.errorSink();
    sink.consumeError(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u64, 0), uncaptured.count);

    var scope = try device.popErrorScope();
    defer scope.deinit(std.testing.allocator);
    const held = scope.captured orelse return error.ScopeCapturedNothing;
    try std.testing.expectEqualStrings(
        "the request is above the device limit maxTextureDimension2D",
        held.message,
    );

    try device.destroy(target);
    try std.testing.expectError(error.StaleHandle, device.resolve(Probe, target));
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount());
    try std.testing.expectEqual(@as(u64, 1), teardown_count);
    try std.testing.expectEqual(object.DestroyReason.early_destroy, probe.last_reason);

    device.deinit(std.testing.allocator);
}
