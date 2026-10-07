//! Guarded object identity, intrusive references, and the device's one arena.
//!
//! Initialize with a stable caller-owned mutex, lock the list, create an
//! unpublished header, initialize its payload, then attach it. Each reference
//! is explicitly a user alias or an internal lease. Payload retirement does
//! not consume references. Final release unlinks the header; its arena storage
//! remains a tombstone until zero-reference `deinit`.
//!
//! The arena, bound mutex, allocator backing state, and optional high owner
//! must stay at stable addresses through final deinit. Pointer copies do not
//! retain. Raw forged pointers and reads after arena deinit are not supported.

const std = @import("std");
const errors = @import("errors.zig");
const handle = @import("handle.zig");

/// Whether retirement follows the last release or an explicit owner decision.
pub const DestroyReason = enum {
    last_reference_released,
    early_destroy,
};

/// Payload state. A destroyed header can still own user references and leases.
pub const State = enum {
    initializing,
    alive,
    destroyed,
    failed,
};

/// A public owned alias or an internal dependency/job/GPU lifetime lease.
pub const ReferenceClass = enum { user, lease };

/// Checked ownership failures. Every failed retain/release leaves counts unchanged.
pub const ReferenceError = error{
    ResourceDestroyed,
    ResourceDeviceMismatch,
    ReferenceCountOverflow,
    NoOwnedReference,
};

/// Final reclamation refuses references or a different storage allocator.
pub const LifetimeError = error{ ResourceInUse, AllocatorMismatch };

/// Factory failures leave no reference or published object behind.
pub const CreateError = std.mem.Allocator.Error ||
    error{ AllocatorMismatch, ResourceDestroyed, ReferenceCountOverflow };

/// Holds the list's original mutex, without storing an Io capability.
///
/// Do not copy, transfer between threads, or use after unlock. The guard's
/// mutex must outlive unlock; unlock does not read the list, so it remains valid
/// after a successful arena deinit under this guard.
pub const ObjectGuard = struct {
    objects: *ObjectList,
    mutex: *std.Io.Mutex,
    held: bool,

    /// Blocks for the bound mutex; cancellation leaves the list unchanged.
    pub fn lock(io: std.Io, objects: *ObjectList) error{Canceled}!ObjectGuard {
        const mutex = objects.mutex;
        try mutex.lock(io);
        return .{ .objects = objects, .mutex = mutex, .held = true };
    }

    /// Blocks without cancellation, for cleanup that must consume owned refs.
    pub fn lockUncancelable(io: std.Io, objects: *ObjectList) ObjectGuard {
        const mutex = objects.mutex;
        mutex.lockUncancelable(io);
        return .{ .objects = objects, .mutex = mutex, .held = true };
    }

    /// Releases the captured mutex with the caller's still-live Io provider.
    pub fn unlock(self: *ObjectGuard, io: std.Io) void {
        std.debug.assert(self.held);
        self.held = false;
        self.mutex.unlock(io);
    }

    /// Programmer precondition: this uncopied guard holds this list's mutex.
    pub fn assertOwns(self: *const ObjectGuard, objects: *const ObjectList) void {
        std.debug.assert(self.held);
        std.debug.assert(self.objects == objects);
        std.debug.assert(self.mutex == objects.mutex);
    }
};

/// Runs once on the retiring thread with the object guard held. Context points
/// to the initialized arena owner and stays valid through the callback. It may
/// release dependencies with this guard, but must not acquire the mutex again,
/// run user callbacks, or reclaim arena/index storage.
pub const DestroyFn = *const fn (
    context: *anyopaque,
    guard: *const ObjectGuard,
    io: std.Io,
    reason: DestroyReason,
) void;

/// Removes weak membership before payload retirement, under the same guard.
/// Context/index/key storage must survive the call. The callback must not
/// allocate, run user callbacks, or retire this object recursively.
pub const CacheRemoveFn = *const fn (
    context: *anyopaque,
    guard: *const ObjectGuard,
    object: *Object,
) void;

/// The sole reference authority and canonical identity of an arena object.
///
/// All payload/header access takes ObjectGuard except the immutable `tracking`
/// locator, which can locate a bound high owner before a host operation pin.
/// Total includes user aliases; leases equal total minus user. A retained dead
/// header remains linked, but `isAlive` excludes it. Labels survive retirement.
pub const Object = struct {
    kind: handle.Handle.Kind,
    state: State,
    reference_count: u32,
    user_reference_count: u32,
    last_error: ?errors.ValidationError,
    label: []const u8,
    tracking: *ObjectList,
    node: ListNode = .{},
    destroy_callback: DestroyFn,
    context: *anyopaque,
    /// Paired weak membership; null means no cache hook.
    cache_context: ?*anyopaque = null,
    remove_from_cache: ?CacheRemoveFn = null,
    /// Once an additional reference escaped, construction rollback is invalid.
    reference_escaped: bool = false,

    /// Publishes a fully initialized payload. A retired list retires it at once
    /// but preserves its initial reference and host identity for late release.
    pub fn attach(self: *Object, guard: *const ObjectGuard, io: std.Io) void {
        self.tracking.track(guard, io, self);
    }

    /// Core liveness includes linked error objects, not only native-usable ones.
    pub fn isAlive(self: *const Object, guard: *const ObjectGuard) bool {
        guard.assertOwns(self.tracking);
        return self.node.linked and (self.state == .alive or self.state == .failed);
    }

    /// Whether initialization finished, including failure and retirement.
    pub fn isInitialized(self: *const Object, guard: *const ObjectGuard) bool {
        guard.assertOwns(self.tracking);
        return self.state != .initializing;
    }

    /// Whether the initialized object carries a validation failure.
    pub fn isFailed(self: *const Object, guard: *const ObjectGuard) bool {
        guard.assertOwns(self.tracking);
        return self.state == .failed;
    }

    /// Completes initialization successfully, exactly once.
    pub fn setInitializedNoError(self: *Object, guard: *const ObjectGuard) void {
        guard.assertOwns(self.tracking);
        std.debug.assert(self.state == .initializing);
        std.debug.assert(self.last_error == null);
        self.state = .alive;
    }

    /// Completes initialization with an owned diagnostic/error object.
    pub fn setInitializedError(
        self: *Object,
        guard: *const ObjectGuard,
        rule: errors.ValidationError,
    ) void {
        guard.assertOwns(self.tracking);
        std.debug.assert(self.state == .initializing);
        self.state = .failed;
        self.last_error = rule;
    }

    /// Copies an already-owned user alias, even after payload retirement.
    /// It never obtains the first user reference from an internal lease.
    pub fn retainUserLocked(self: *Object, guard: *const ObjectGuard) ReferenceError!void {
        try self.checkReferenceOwner(guard);
        if (self.user_reference_count == 0) return error.NoOwnedReference;
        try self.incrementReference(.user);
    }

    /// Acquires a new owned cache/factory alias to a live payload. Unlike user
    /// retain, this accepts a lease-only object, but never a retired payload.
    pub fn acquireUserLocked(self: *Object, guard: *const ObjectGuard) ReferenceError!void {
        try self.checkReferenceOwner(guard);
        if (!self.isAlive(guard)) return error.ResourceDestroyed;
        try self.incrementReference(.user);
    }

    /// Owns an internal lifetime lease to a live core payload. Native callers
    /// must additionally require `.alive` before reading native payload fields.
    pub fn retainLeaseLocked(self: *Object, guard: *const ObjectGuard) ReferenceError!void {
        try self.checkReferenceOwner(guard);
        if (!self.isAlive(guard)) return error.ResourceDestroyed;
        try self.incrementReference(.lease);
    }

    /// Consumes one user alias without dependent/pending-work refusal. Retired
    /// aliases use the same ledger and never run the payload destructor twice.
    pub fn releaseUserLocked(
        self: *Object,
        guard: *const ObjectGuard,
        io: std.Io,
    ) ReferenceError!void {
        try self.checkReferenceOwner(guard);
        if (self.user_reference_count == 0) return error.NoOwnedReference;
        std.debug.assert(self.node.linked or self.state == .destroyed);
        self.user_reference_count -= 1;
        self.tracking.user_reference_count -= 1;
        self.releaseReference(guard, io);
    }

    /// Consumes an internal lease. A matching lease is a programmer invariant.
    pub fn releaseLeaseLocked(self: *Object, guard: *const ObjectGuard, io: std.Io) void {
        guard.assertOwns(self.tracking);
        self.assertReferences();
        std.debug.assert(self.reference_count > self.user_reference_count);
        std.debug.assert(self.node.linked or self.state == .destroyed);
        self.releaseReference(guard, io);
    }

    /// Binds one weak removal hook while its key-bearing payload is live.
    pub fn setCacheRemovalLocked(
        self: *Object,
        guard: *const ObjectGuard,
        context: *anyopaque,
        callback: CacheRemoveFn,
    ) void {
        guard.assertOwns(self.tracking);
        std.debug.assert(self.isAlive(guard));
        std.debug.assert(self.remove_from_cache == null);
        std.debug.assert(self.cache_context == null);
        self.cache_context = context;
        self.remove_from_cache = callback;
    }

    /// Retires once, evicting weak membership before the payload callback.
    /// Counts remain authoritative. Zero-count unlink is deferred only during
    /// the list's bounded retirement sweep.
    pub fn retirePayloadLocked(
        self: *Object,
        guard: *const ObjectGuard,
        io: std.Io,
        reason: DestroyReason,
    ) void {
        guard.assertOwns(self.tracking);
        self.assertReferences();
        if (self.state != .destroyed) {
            std.debug.assert(self.node.linked);
            std.debug.assert(self.state != .initializing);
            const remove = self.remove_from_cache;
            const cache_context = self.cache_context;
            std.debug.assert((remove == null) == (cache_context == null));
            self.remove_from_cache = null;
            self.cache_context = null;
            if (remove) |callback| callback(cache_context.?, guard, self);
            self.state = .destroyed;
            self.destroy_callback(self.context, guard, io, reason);
        }
        self.finalizeZero(guard);
    }

    /// Construction rollback only. Caller first cleans initialized temporaries.
    /// Rejects publication, cache membership, or escaped refs unchanged; success
    /// consumes the initial ref without reading uninitialized payload fields.
    pub fn discardUnpublishedLocked(
        self: *Object,
        guard: *const ObjectGuard,
    ) error{ResourceInUse}!void {
        guard.assertOwns(self.tracking);
        self.assertReferences();
        if (self.node.linked or self.reference_escaped) return error.ResourceInUse;
        if (self.remove_from_cache != null or self.cache_context != null) {
            return error.ResourceInUse;
        }
        if (self.reference_count != 1 or self.state == .destroyed) {
            return error.ResourceInUse;
        }
        self.tracking.total_reference_count -= 1;
        self.tracking.user_reference_count -= self.user_reference_count;
        self.reference_count = 0;
        self.user_reference_count = 0;
        self.state = .destroyed;
    }

    fn checkReferenceOwner(self: *const Object, guard: *const ObjectGuard) ReferenceError!void {
        std.debug.assert(guard.held);
        if (guard.objects != self.tracking) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.tracking);
        self.assertReferences();
    }

    fn assertReferences(self: *const Object) void {
        std.debug.assert(self.user_reference_count <= self.reference_count);
        std.debug.assert(self.tracking.user_reference_count <= self.tracking.total_reference_count);
    }

    fn incrementReference(self: *Object, class: ReferenceClass) ReferenceError!void {
        std.debug.assert(self.reference_count != 0);
        if (self.reference_count == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        if (self.tracking.total_reference_count == std.math.maxInt(u64)) {
            return error.ReferenceCountOverflow;
        }
        if (class == .user) {
            if (self.user_reference_count == std.math.maxInt(u32)) {
                return error.ReferenceCountOverflow;
            }
            if (self.tracking.user_reference_count == std.math.maxInt(u64)) {
                return error.ReferenceCountOverflow;
            }
        }
        self.reference_count += 1;
        self.tracking.total_reference_count += 1;
        if (class == .user) {
            self.user_reference_count += 1;
            self.tracking.user_reference_count += 1;
        }
        self.reference_escaped = true;
        self.assertReferences();
    }

    fn releaseReference(self: *Object, guard: *const ObjectGuard, io: std.Io) void {
        std.debug.assert(self.reference_count != 0);
        self.reference_count -= 1;
        self.tracking.total_reference_count -= 1;
        if (self.reference_count == 0) {
            self.retirePayloadLocked(guard, io, .last_reference_released);
        }
        self.assertReferences();
    }

    fn finalizeZero(self: *Object, guard: *const ObjectGuard) void {
        if (self.reference_count != 0) return;
        std.debug.assert(self.user_reference_count == 0);
        if (!self.tracking.payload_retirement_active) self.tracking.unlink(guard, self);
    }
};

comptime {
    if (@alignOf(Object) > handle.object_alignment) {
        @compileError("Handle.ptr is under-aligned for an Object header");
    }
}

/// One intrusive link per canonical header; no second retained-header list.
pub const ListNode = struct {
    previous: ?*Object = null,
    next: ?*Object = null,
    linked: bool = false,
};

/// Retained canonical headers in newest-first order, sharing one owner mutex.
/// Aggregate reference counts are derived from headers, including unpublished
/// initial refs. They permit finite preflight without another allocation/list.
/// The mutex and once-bound `high_owner` are immutable until final reclamation.
pub const ObjectList = struct {
    mutex: *std.Io.Mutex,
    head: ?*Object = null,
    tail: ?*Object = null,
    tracked_count: usize = 0,
    marked_destroyed: bool = false,
    payload_retirement_active: bool = false,
    total_reference_count: u64 = 0,
    user_reference_count: u64 = 0,
    /// Null for standalone core; otherwise the stable canonical high owner.
    high_owner: ?*anyopaque = null,

    /// Attaches once after all payload fields are written. A retired list may
    /// receive an already-created object; it retires the payload immediately.
    pub fn track(
        self: *ObjectList,
        guard: *const ObjectGuard,
        io: std.Io,
        object: *Object,
    ) void {
        guard.assertOwns(self);
        std.debug.assert(object.tracking == self);
        std.debug.assert(!object.node.linked);
        std.debug.assert(object.reference_count != 0);
        std.debug.assert(object.state == .alive or object.state == .failed);
        object.node = .{ .next = self.head, .linked = true };
        if (self.head) |head| {
            head.node.previous = object;
        } else {
            self.tail = object;
        }
        self.head = object;
        self.tracked_count += 1;
        if (self.marked_destroyed) object.retirePayloadLocked(guard, io, .early_destroy);
    }

    fn unlink(self: *ObjectList, guard: *const ObjectGuard, object: *Object) void {
        guard.assertOwns(self);
        std.debug.assert(object.tracking == self);
        std.debug.assert(object.reference_count == 0);
        std.debug.assert(object.state == .destroyed);
        if (!object.node.linked) return;
        if (object.node.previous) |previous| {
            previous.node.next = object.node.next;
        } else {
            std.debug.assert(self.head == object);
            self.head = object.node.next;
        }
        if (object.node.next) |next| {
            next.node.previous = object.node.previous;
        } else {
            std.debug.assert(self.tail == object);
            self.tail = object.node.previous;
        }
        object.node = .{};
        self.tracked_count -= 1;
    }

    /// Retires newest-first in two bounded passes. Dependency final releases
    /// cannot unlink nodes while the first pass follows them. The second pass
    /// unlinks zero ledgers only, leaving retained destroyed headers in place.
    pub fn retirePayloadsLocked(
        self: *ObjectList,
        guard: *const ObjectGuard,
        io: std.Io,
        reason: DestroyReason,
    ) void {
        guard.assertOwns(self);
        std.debug.assert(!self.payload_retirement_active);
        self.marked_destroyed = true;
        self.payload_retirement_active = true;
        const bound = self.tracked_count;
        var next = self.head;
        for (0..bound) |_| {
            const current = next orelse break;
            next = current.node.next;
            current.retirePayloadLocked(guard, io, reason);
        }
        self.payload_retirement_active = false;
        next = self.head;
        const unlink_bound = self.tracked_count;
        for (0..unlink_bound) |_| {
            const current = next orelse break;
            next = current.node.next;
            if (current.reference_count == 0) self.unlink(guard, current);
        }
    }

    /// Visits retained headers newest-first under the guard. The calling-thread
    /// callback borrows context/object/guard until return and must not change
    /// list topology, acquire the same mutex, or run user callbacks.
    pub fn forEach(
        self: *const ObjectList,
        guard: *const ObjectGuard,
        context: *anyopaque,
        visit_callback: *const fn (*anyopaque, *const ObjectGuard, *Object) void,
    ) void {
        guard.assertOwns(self);
        const bound = self.tracked_count;
        var next = self.head;
        for (0..bound) |_| {
            const current = next orelse break;
            next = current.node.next;
            visit_callback(context, guard, current);
        }
    }

    /// Refuses any user or internal owner, including an unpublished creator.
    /// Nothing is retired, unlinked, or reset on refusal.
    pub fn preflightDeinitLocked(
        self: *const ObjectList,
        guard: *const ObjectGuard,
    ) error{ResourceInUse}!void {
        guard.assertOwns(self);
        if (self.user_reference_count != 0 or self.total_reference_count != 0) {
            return error.ResourceInUse;
        }
        if (self.payload_retirement_active) return error.ResourceInUse;
        std.debug.assert(self.tracked_count == 0);
        std.debug.assert(self.head == null);
        std.debug.assert(self.tail == null);
    }
};

fn assertHeader(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("an arena object must be a struct");
    const fields = info.@"struct".fields;
    if (fields.len == 0) @compileError("an arena object must have a header field");
    if (!std.mem.eql(u8, fields[0].name, "header")) {
        @compileError("the first field of an arena object must be header");
    }
    if (fields[0].type != Object) {
        @compileError("the header field of an arena object must be an Object");
    }
    if (!@hasDecl(T, "destroy")) {
        @compileError("arena objects require pub fn destroy(self, guard, io, reason) void");
    }
}

/// Header initialization. Ownership class is required; default state assumes a
/// successfully initialized payload that the caller will write before attach.
pub fn CreateOptions(comptime T: type) type {
    assertHeader(T);
    return struct {
        kind: handle.Handle.Kind,
        initial_reference: ReferenceClass,
        state: State = .alive,
        label: []const u8 = "",
    };
}

/// One arena for all device headers and payload storage. Move only before first
/// creation or publication of a borrow. Its child allocator/mutex remain live
/// through zero-reference deinit. Storage grows with historical allocations;
/// final individual release does not reclaim arena bytes.
pub const ObjectArena = struct {
    memory: std.heap.ArenaAllocator,
    objects: ObjectList,

    pub const InitOptions = struct {
        object_mutex: *std.Io.Mutex,
    };

    /// Allocation-free initialization; captures no pointer into the returned value.
    pub fn init(child_allocator: std.mem.Allocator, options: InitOptions) ObjectArena {
        return .{
            .memory = std.heap.ArenaAllocator.init(child_allocator),
            .objects = .{ .mutex = options.object_mutex },
        };
    }

    /// Borrows the arena allocator; its backing storage dies at final deinit.
    pub fn allocator(self: *ObjectArena, guard: *const ObjectGuard) std.mem.Allocator {
        guard.assertOwns(&self.objects);
        return self.memory.allocator();
    }

    /// Immutable lock/owner locator, valid only at the arena's final address.
    pub fn objectList(self: *ObjectArena) *ObjectList {
        return &self.objects;
    }

    /// Checks storage allocator identity before allocation or factory mutation.
    pub fn checkAllocator(
        self: *const ObjectArena,
        guard: *const ObjectGuard,
        child_allocator: std.mem.Allocator,
    ) error{AllocatorMismatch}!void {
        guard.assertOwns(&self.objects);
        const owner = self.memory.child_allocator;
        if (owner.ptr != child_allocator.ptr or owner.vtable != child_allocator.vtable) {
            return error.AllocatorMismatch;
        }
    }

    /// Allocates only the header/label and returns one unpublished initial ref.
    /// Write every payload field, then attach. On later constructor failure,
    /// clean initialized temporaries and discardUnpublishedLocked; never invoke
    /// the destructor on unwritten fields. Refuses factories after retirement.
    /// Count saturation refuses before any arena allocation or label copy.
    pub fn create(
        self: *ObjectArena,
        child_allocator: std.mem.Allocator,
        guard: *const ObjectGuard,
        comptime T: type,
        options: CreateOptions(T),
    ) CreateError!*T {
        try self.checkAllocator(guard, child_allocator);
        if (self.objects.marked_destroyed) return error.ResourceDestroyed;
        std.debug.assert(options.state != .destroyed);
        if (self.objects.total_reference_count == std.math.maxInt(u64)) {
            return error.ReferenceCountOverflow;
        }
        if (options.initial_reference == .user) {
            if (self.objects.user_reference_count == std.math.maxInt(u64)) {
                return error.ReferenceCountOverflow;
            }
        }
        const arena_allocator = self.memory.allocator();
        const object = try arena_allocator.create(T);
        errdefer arena_allocator.destroy(object);
        const label = try arena_allocator.dupe(u8, options.label);
        errdefer arena_allocator.free(label);
        const user_count: u32 = if (options.initial_reference == .user) 1 else 0;
        object.header = .{
            .kind = options.kind,
            .state = options.state,
            .reference_count = 1,
            .user_reference_count = user_count,
            .last_error = null,
            .label = label,
            .tracking = &self.objects,
            .destroy_callback = destroyTrampoline(T),
            .context = object,
        };
        self.objects.total_reference_count += 1;
        self.objects.user_reference_count += user_count;
        return object;
    }

    /// Committed arena bytes, not the number of live native payload bytes.
    pub fn queryCapacity(self: *const ObjectArena, guard: *const ObjectGuard) usize {
        guard.assertOwns(&self.objects);
        return self.memory.queryCapacity();
    }

    /// Retained linked headers, including payload-retired aliases.
    pub fn queryTrackedCount(self: *const ObjectArena, guard: *const ObjectGuard) usize {
        guard.assertOwns(&self.objects);
        return self.objects.tracked_count;
    }

    /// Reclaims storage only with zero refs and matching allocator. Refusal is
    /// unchanged; success invalidates every header and poisons this receiver.
    /// The separately captured guard mutex remains available for unlock.
    pub fn deinit(
        self: *ObjectArena,
        child_allocator: std.mem.Allocator,
        guard: *const ObjectGuard,
    ) LifetimeError!void {
        try self.checkAllocator(guard, child_allocator);
        try self.objects.preflightDeinitLocked(guard);
        self.memory.deinit();
        self.* = undefined;
    }
};

fn destroyTrampoline(comptime T: type) DestroyFn {
    const trampoline = struct {
        fn run(
            context: *anyopaque,
            guard: *const ObjectGuard,
            io: std.Io,
            reason: DestroyReason,
        ) void {
            const owner: *T = @ptrCast(@alignCast(context));
            owner.destroy(guard, io, reason);
        }
    };
    return &trampoline.run;
}

const LifetimeLog = struct {
    destroyed: [8]u8 = @splat(0),
    order: [8]u8 = @splat(0),
    count: usize = 0,
    cache_present: bool = false,
    eviction_count: u8 = 0,
    deferred_zero_links: u8 = 0,
};

const LifetimeProbe = struct {
    header: Object,
    log: *LifetimeLog,
    id: u8,
    dependency: ?*Object,

    pub fn destroy(
        self: *LifetimeProbe,
        guard: *const ObjectGuard,
        io: std.Io,
        reason: DestroyReason,
    ) void {
        _ = reason;
        guard.assertOwns(self.header.tracking);
        std.debug.assert(!self.log.cache_present);
        self.log.destroyed[self.id] += 1;
        self.log.order[self.log.count] = self.id;
        self.log.count += 1;
        if (self.dependency) |dependency| {
            dependency.releaseLeaseLocked(guard, io);
            if (self.header.tracking.payload_retirement_active) {
                if (dependency.reference_count == 0 and dependency.node.linked) {
                    self.log.deferred_zero_links += 1;
                }
            }
        }
        self.dependency = null;
    }
};

fn lifetimeProbe(
    arena: *ObjectArena,
    guard: *const ObjectGuard,
    log: *LifetimeLog,
    id: u8,
    initial_reference: ReferenceClass,
) !*LifetimeProbe {
    const probe = try arena.create(std.testing.allocator, guard, LifetimeProbe, .{
        .kind = .buffer,
        .initial_reference = initial_reference,
    });
    probe.log = log;
    probe.id = id;
    probe.dependency = null;
    probe.header.attach(guard, std.testing.io);
    return probe;
}

fn lifetimeEvict(context: *anyopaque, guard: *const ObjectGuard, header: *Object) void {
    const log: *LifetimeLog = @ptrCast(@alignCast(context));
    guard.assertOwns(header.tracking);
    std.debug.assert(header.state == .alive);
    std.debug.assert(log.cache_present);
    log.cache_present = false;
    log.eviction_count += 1;
}

test "user release leaves an internal lease alive until its final release" {
    // A dependency is an owner, not an extra public alias.
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{};
    const probe = try lifetimeProbe(&arena, &guard, &log, 0, .user);
    try probe.header.retainLeaseLocked(&guard);
    try probe.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u32, 1), probe.header.reference_count);
    try std.testing.expectEqual(@as(u32, 0), probe.header.user_reference_count);
    try std.testing.expect(probe.header.isAlive(&guard));
    try std.testing.expectEqual(@as(usize, 0), log.count);
    probe.header.releaseLeaseLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
    try std.testing.expectEqual(@as(usize, 0), arena.queryTrackedCount(&guard));
}

test "object reference saturation accepts the last slot and refuses every retain atomically" {
    // Use real linked payloads and restore synthetic counters before normal release.
    inline for (.{
        .{ .retain = Object.retainUserLocked, .class = ReferenceClass.user },
        .{ .retain = Object.acquireUserLocked, .class = ReferenceClass.user },
        .{ .retain = Object.retainLeaseLocked, .class = ReferenceClass.lease },
    }) |operation| {
        var mutex: std.Io.Mutex = .init;
        var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
        var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
        defer guard.unlock(std.testing.io);
        defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
        var log: LifetimeLog = .{ .cache_present = true };
        const probe = try lifetimeProbe(&arena, &guard, &log, 0, .user);
        probe.header.setCacheRemovalLocked(&guard, &log, lifetimeEvict);
        defer {
            probe.header.reference_count = 1;
            probe.header.user_reference_count = 1;
            arena.objects.total_reference_count = 1;
            arena.objects.user_reference_count = 1;
            probe.header.releaseUserLocked(&guard, std.testing.io) catch
                @panic("owned reference lost");
        }
        const user_increment: u32 = if (operation.class == .user) 1 else 0;
        probe.header.reference_count = std.math.maxInt(u32) - 1;
        probe.header.user_reference_count = std.math.maxInt(u32) - 1;
        arena.objects.total_reference_count = std.math.maxInt(u32) - 1;
        arena.objects.user_reference_count = std.math.maxInt(u32) - 1;
        try operation.retain(&probe.header, &guard);
        try std.testing.expectEqual(std.math.maxInt(u32), probe.header.reference_count);
        const expected_users = std.math.maxInt(u32) - 1 + user_increment;
        try std.testing.expectEqual(expected_users, probe.header.user_reference_count);
        try std.testing.expectEqual(
            @as(u64, std.math.maxInt(u32)),
            arena.objects.total_reference_count,
        );
        try std.testing.expectEqual(@as(u64, expected_users), arena.objects.user_reference_count);
        const header_before = probe.header;
        const list_before = arena.objects;
        try std.testing.expectError(
            error.ReferenceCountOverflow,
            probe.header.retainUserLocked(&guard),
        );
        try std.testing.expectError(
            error.ReferenceCountOverflow,
            probe.header.acquireUserLocked(&guard),
        );
        try std.testing.expectError(
            error.ReferenceCountOverflow,
            probe.header.retainLeaseLocked(&guard),
        );
        try std.testing.expect(std.meta.eql(header_before, probe.header));
        try std.testing.expect(std.meta.eql(list_before, arena.objects));
        try std.testing.expect(log.cache_present);
        try std.testing.expectEqual(@as(u8, 0), log.eviction_count);
        try std.testing.expectEqual(@as(usize, 0), log.count);
    }
}

test "aggregate reference saturation preflights aliases and leases before mutation" {
    // Aggregate headroom belongs to the existing list, not a cache-specific ledger.
    inline for (.{
        .{ .retain = Object.retainUserLocked, .class = ReferenceClass.user },
        .{ .retain = Object.acquireUserLocked, .class = ReferenceClass.user },
        .{ .retain = Object.retainLeaseLocked, .class = ReferenceClass.lease },
    }) |operation| {
        var mutex: std.Io.Mutex = .init;
        var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
        var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
        defer guard.unlock(std.testing.io);
        defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
        var log: LifetimeLog = .{ .cache_present = true };
        const probe = try lifetimeProbe(&arena, &guard, &log, 0, .user);
        probe.header.setCacheRemovalLocked(&guard, &log, lifetimeEvict);
        defer {
            probe.header.reference_count = 1;
            probe.header.user_reference_count = 1;
            arena.objects.total_reference_count = 1;
            arena.objects.user_reference_count = 1;
            probe.header.releaseUserLocked(&guard, std.testing.io) catch
                @panic("owned reference lost");
        }
        inline for (.{ @as(u64, 1), std.math.maxInt(u64) }) |users| {
            arena.objects.total_reference_count = std.math.maxInt(u64);
            arena.objects.user_reference_count = users;
            const header_before = probe.header;
            const list_before = arena.objects;
            try std.testing.expectError(
                error.ReferenceCountOverflow,
                operation.retain(&probe.header, &guard),
            );
            try std.testing.expect(std.meta.eql(header_before, probe.header));
            try std.testing.expect(std.meta.eql(list_before, arena.objects));
        }
        arena.objects.total_reference_count = std.math.maxInt(u64) - 1;
        arena.objects.user_reference_count = std.math.maxInt(u64) - 1;
        try operation.retain(&probe.header, &guard);
        const user_increment: u64 = if (operation.class == .user) 1 else 0;
        try std.testing.expectEqual(@as(u32, 2), probe.header.reference_count);
        try std.testing.expectEqual(
            @as(u32, 1) + @as(u32, @intCast(user_increment)),
            probe.header.user_reference_count,
        );
        try std.testing.expectEqual(
            std.math.maxInt(u64),
            arena.objects.total_reference_count,
        );
        try std.testing.expectEqual(
            std.math.maxInt(u64) - 1 + user_increment,
            arena.objects.user_reference_count,
        );
        const header_before = probe.header;
        const list_before = arena.objects;
        try std.testing.expectError(
            error.ReferenceCountOverflow,
            operation.retain(&probe.header, &guard),
        );
        try std.testing.expect(std.meta.eql(header_before, probe.header));
        try std.testing.expect(std.meta.eql(list_before, arena.objects));
        try std.testing.expect(log.cache_present);
        try std.testing.expectEqual(@as(u8, 0), log.eviction_count);
        try std.testing.expectEqual(@as(usize, 0), log.count);
    }
}

test "initial reference saturation refuses creation without allocator activity" {
    // Check both empty storage and reused arena capacity before a nonempty label copy.
    inline for (.{ false, true }) |warm_arena| {
        var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = allocations.allocator();
        var mutex: std.Io.Mutex = .init;
        var arena = ObjectArena.init(allocator, .{ .object_mutex = &mutex });
        var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
        defer guard.unlock(std.testing.io);
        defer arena.deinit(allocator, &guard) catch @panic("references leaked");
        defer {
            arena.objects.total_reference_count = 0;
            arena.objects.user_reference_count = 0;
        }
        if (warm_arena) {
            const unpublished = try arena.create(allocator, &guard, LifetimeProbe, .{
                .kind = .buffer,
                .initial_reference = .lease,
            });
            try unpublished.header.discardUnpublishedLocked(&guard);
        }
        allocations.fail_index = allocations.alloc_index;
        allocations.resize_fail_index = allocations.resize_index;
        const allocation_count = allocations.alloc_index;
        const resize_count = allocations.resize_index;
        const deallocation_count = allocations.deallocations;
        const memory_before = arena.memory.state;
        const capacity_before = arena.queryCapacity(&guard);
        inline for (.{ ReferenceClass.user, ReferenceClass.lease }) |class| {
            inline for (.{ @as(u64, 0), std.math.maxInt(u64) }) |users| {
                arena.objects.total_reference_count = std.math.maxInt(u64);
                arena.objects.user_reference_count = users;
                const list_before = arena.objects;
                try std.testing.expectError(
                    error.ReferenceCountOverflow,
                    arena.create(allocator, &guard, LifetimeProbe, .{
                        .kind = .buffer,
                        .initial_reference = class,
                        .label = "must not allocate or copy this label",
                    }),
                );
                try std.testing.expect(std.meta.eql(list_before, arena.objects));
                try std.testing.expect(std.meta.eql(memory_before, arena.memory.state));
                try std.testing.expectEqual(capacity_before, arena.queryCapacity(&guard));
                try std.testing.expectEqual(allocation_count, allocations.alloc_index);
                try std.testing.expectEqual(resize_count, allocations.resize_index);
                try std.testing.expectEqual(deallocation_count, allocations.deallocations);
                try std.testing.expect(!allocations.has_induced_failure);
            }
        }
    }
}

test "initial users and leases consume only their own aggregate headroom" {
    // Unpublished rollback must restore each representable max-minus-one boundary.
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    defer {
        arena.objects.total_reference_count = 0;
        arena.objects.user_reference_count = 0;
    }
    inline for (.{ ReferenceClass.user, ReferenceClass.lease }) |class| {
        arena.objects.total_reference_count = std.math.maxInt(u64) - 1;
        arena.objects.user_reference_count = std.math.maxInt(u64) - 1;
        const unpublished = try arena.create(std.testing.allocator, &guard, LifetimeProbe, .{
            .kind = .buffer,
            .initial_reference = class,
        });
        defer unpublished.header.discardUnpublishedLocked(&guard) catch
            @panic("unpublished reference escaped");
        const user_increment: u32 = if (class == .user) 1 else 0;
        try std.testing.expectEqual(@as(u32, 1), unpublished.header.reference_count);
        try std.testing.expectEqual(user_increment, unpublished.header.user_reference_count);
        try std.testing.expectEqual(
            std.math.maxInt(u64),
            arena.objects.total_reference_count,
        );
        try std.testing.expectEqual(
            std.math.maxInt(u64) - 1 + @as(u64, user_increment),
            arena.objects.user_reference_count,
        );
        try std.testing.expectEqual(@as(usize, 0), arena.queryTrackedCount(&guard));
    }
}

test "cache acquisition owns a user reference to a live lease-only object" {
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{};
    const probe = try lifetimeProbe(&arena, &guard, &log, 0, .lease);
    try std.testing.expectError(error.NoOwnedReference, probe.header.retainUserLocked(&guard));
    try std.testing.expectError(
        error.NoOwnedReference,
        probe.header.releaseUserLocked(&guard, std.testing.io),
    );
    try probe.header.acquireUserLocked(&guard);
    try std.testing.expectEqual(@as(u32, 2), probe.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), probe.header.user_reference_count);
    try probe.header.releaseUserLocked(&guard, std.testing.io);
    probe.header.releaseLeaseLocked(&guard, std.testing.io);
    try std.testing.expectError(error.ResourceDestroyed, probe.header.acquireUserLocked(&guard));
    try std.testing.expectError(
        error.NoOwnedReference,
        probe.header.releaseUserLocked(&guard, std.testing.io),
    );
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
}

test "weak eviction precedes payload destruction exactly once" {
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{ .cache_present = true };
    const probe = try lifetimeProbe(&arena, &guard, &log, 0, .user);
    probe.header.setCacheRemovalLocked(&guard, &log, lifetimeEvict);
    try probe.header.releaseUserLocked(&guard, std.testing.io);
    probe.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectEqual(@as(u8, 1), log.eviction_count);
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
    try std.testing.expect(probe.header.remove_from_cache == null);
    try std.testing.expect(probe.header.cache_context == null);
}

test "explicit retirement preserves alias counts and late releases destroy no payload twice" {
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{};
    const probe = try lifetimeProbe(&arena, &guard, &log, 0, .user);
    try probe.header.retainUserLocked(&guard);
    probe.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    probe.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectEqual(@as(u32, 2), probe.header.reference_count);
    try std.testing.expectEqual(@as(u32, 2), probe.header.user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), arena.queryTrackedCount(&guard));
    try std.testing.expect(!probe.header.isAlive(&guard));
    try std.testing.expectError(error.ResourceDestroyed, probe.header.retainLeaseLocked(&guard));
    try std.testing.expectError(error.ResourceDestroyed, probe.header.acquireUserLocked(&guard));
    try probe.header.retainUserLocked(&guard);
    try std.testing.expectError(error.ResourceInUse, arena.deinit(std.testing.allocator, &guard));
    try std.testing.expectEqual(@as(u32, 3), probe.header.reference_count);
    for (0..3) |_| try probe.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
    try std.testing.expectEqual(@as(u64, 0), arena.objects.total_reference_count);
    try std.testing.expectEqual(@as(u64, 0), arena.objects.user_reference_count);
    try std.testing.expectEqual(@as(usize, 0), arena.queryTrackedCount(&guard));
}

test "bounded reverse retirement drops dependencies past retained dead headers" {
    // Newest-first traversal must not repeatedly visit a retained destroyed head.
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{};
    const oldest = try lifetimeProbe(&arena, &guard, &log, 0, .lease);
    const middle = try lifetimeProbe(&arena, &guard, &log, 1, .lease);
    middle.dependency = &oldest.header;
    const newest = try lifetimeProbe(&arena, &guard, &log, 2, .user);
    newest.dependency = &middle.header;
    const dead_head = try lifetimeProbe(&arena, &guard, &log, 3, .user);
    dead_head.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    arena.objects.retirePayloadsLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 0 }, log.order[0..log.count]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, log.destroyed[0..4]);
    try std.testing.expectEqual(@as(u8, 2), log.deferred_zero_links);
    try std.testing.expectEqual(@as(usize, 2), arena.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 2), arena.objects.total_reference_count);
    try std.testing.expectEqual(@as(u64, 2), arena.objects.user_reference_count);
    try std.testing.expect(!oldest.header.node.linked);
    try std.testing.expect(!middle.header.node.linked);
    arena.objects.retirePayloadsLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectEqual(@as(usize, 4), log.count);
    try newest.header.releaseUserLocked(&guard, std.testing.io);
    try dead_head.header.releaseUserLocked(&guard, std.testing.io);
}

test "constructor rollback consumes an unpublished reference without reading payload" {
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    inline for (.{ ReferenceClass.user, ReferenceClass.lease }) |class| {
        const probe = try arena.create(std.testing.allocator, &guard, LifetimeProbe, .{
            .kind = .buffer,
            .initial_reference = class,
        });
        try std.testing.expectError(error.ResourceInUse, arena.deinit(std.testing.allocator, &guard));
        try probe.header.discardUnpublishedLocked(&guard);
        try std.testing.expectEqual(@as(u32, 0), probe.header.reference_count);
        try std.testing.expectEqual(State.destroyed, probe.header.state);
    }
}

test "allocator mismatch rejects a factory before storage and reference mutation" {
    // Equal vtables with different allocator state are not the same owner.
    var first_buffer: [4096]u8 = undefined;
    var second_buffer: [4096]u8 = undefined;
    var first = std.heap.FixedBufferAllocator.init(&first_buffer);
    var second = std.heap.FixedBufferAllocator.init(&second_buffer);
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(first.allocator(), .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(first.allocator(), &guard) catch @panic("references leaked");
    try std.testing.expectError(
        error.AllocatorMismatch,
        arena.create(second.allocator(), &guard, LifetimeProbe, .{
            .kind = .buffer,
            .initial_reference = .user,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), first.end_index);
    try std.testing.expectEqual(@as(usize, 0), second.end_index);
    try std.testing.expectEqual(@as(u64, 0), arena.objects.total_reference_count);
    try std.testing.expectEqual(@as(u64, 0), arena.objects.user_reference_count);
    try std.testing.expectEqual(@as(usize, 0), arena.queryTrackedCount(&guard));
    try std.testing.expectError(error.AllocatorMismatch, arena.deinit(second.allocator(), &guard));
}

test "late attachment retires initialized payload while rejecting new factories" {
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{};
    const late = try arena.create(std.testing.allocator, &guard, LifetimeProbe, .{
        .kind = .buffer,
        .initial_reference = .user,
    });
    arena.objects.retirePayloadsLocked(&guard, std.testing.io, .early_destroy);
    late.log = &log;
    late.id = 0;
    late.dependency = null;
    late.header.attach(&guard, std.testing.io);
    try std.testing.expect(!late.header.isAlive(&guard));
    try std.testing.expectEqual(@as(u32, 1), late.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), late.header.user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), arena.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
    try std.testing.expectError(
        error.ResourceDestroyed,
        arena.create(std.testing.allocator, &guard, LifetimeProbe, .{
            .kind = .buffer,
            .initial_reference = .lease,
        }),
    );
    try late.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
}

test "rollback refuses published and cached references without invoking callbacks" {
    var mutex: std.Io.Mutex = .init;
    var arena = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var log: LifetimeLog = .{ .cache_present = true };
    const probe = try lifetimeProbe(&arena, &guard, &log, 0, .user);
    probe.header.setCacheRemovalLocked(&guard, &log, lifetimeEvict);
    try std.testing.expectError(error.ResourceInUse, probe.header.discardUnpublishedLocked(&guard));
    try std.testing.expectEqual(@as(u32, 1), probe.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), probe.header.user_reference_count);
    try std.testing.expect(log.cache_present);
    try std.testing.expectEqual(@as(u8, 0), log.eviction_count);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    try probe.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u8, 1), log.eviction_count);
    try std.testing.expectEqual(@as(u8, 1), log.destroyed[0]);
}

test "a foreign object guard cannot consume or acquire references" {
    var first_mutex: std.Io.Mutex = .init;
    var second_mutex: std.Io.Mutex = .init;
    var first = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &first_mutex });
    var second = ObjectArena.init(std.testing.allocator, .{ .object_mutex = &second_mutex });
    var first_guard = ObjectGuard.lockUncancelable(std.testing.io, first.objectList());
    defer first_guard.unlock(std.testing.io);
    defer first.deinit(std.testing.allocator, &first_guard) catch @panic("references leaked");
    var second_guard = ObjectGuard.lockUncancelable(std.testing.io, second.objectList());
    defer second_guard.unlock(std.testing.io);
    defer second.deinit(std.testing.allocator, &second_guard) catch @panic("references leaked");
    var log: LifetimeLog = .{};
    const probe = try lifetimeProbe(&first, &first_guard, &log, 0, .user);
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        probe.header.retainUserLocked(&second_guard),
    );
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        probe.header.acquireUserLocked(&second_guard),
    );
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        probe.header.retainLeaseLocked(&second_guard),
    );
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        probe.header.releaseUserLocked(&second_guard, std.testing.io),
    );
    try std.testing.expectEqual(@as(u32, 1), probe.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), probe.header.user_reference_count);
    try std.testing.expectEqual(@as(u64, 1), first.objects.total_reference_count);
    try std.testing.expectEqual(@as(u64, 0), second.objects.total_reference_count);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    try probe.header.releaseUserLocked(&first_guard, std.testing.io);
}
