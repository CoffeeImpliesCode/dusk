//! The object header, the list that tracks live objects, and the arena that
//! owns both.
//!
//! **What this file is.** The port of Dawn's `ObjectBase` and `ApiObjectList`
//! (`src/dawn/native/ObjectBase.h:95-208`). There is no per-object free: the
//! last reference marks the object destroyed and hands it back to the arena,
//! and `ObjectArena.deinit` reclaims every block.
//!
//! **What this file does not claim.** It does not claim a memory figure. Dawn's
//! refcount returns the allocation at the last release
//! (`src/dawn/common/RefCounted.cpp:180-182`); the arena does not, so a caller
//! that creates and destroys in a loop pays for the high-water mark of the
//! device's life. `docs/30-port-design.md` §1.1 lists that as the cost.

const std = @import("std");
const errors = @import("errors.zig");
const handle = @import("handle.zig");

/// Why an object is being destroyed.
///
/// Dawn carries the reason because its two callers mean different things
/// (`src/dawn/native/ObjectBase.h:109-116`): a destructor can not leave a
/// reference behind, and an early destroy is a decision the owner made.
pub const DestroyReason = enum {
    /// The last reference is gone, so no further reference can be taken.
    last_reference_released,
    /// The owner is destroying the object before the object goes away.
    early_destroy,
};

/// Where an object is in its life.
///
/// Dawn packs the initialized and error state into the reference-count word
/// (`src/dawn/common/RefCounted.cpp:41-43`, values at
/// `src/dawn/native/ObjectBase.cpp:60-62`) and reaches it through
/// `PayloadFetchAnd` with relaxed ordering
/// (`src/dawn/common/RefCounted.cpp:64-70`). An object is alive while the
/// tracking list holds it (`src/dawn/native/ObjectBase.cpp:229-231`), not in a
/// payload bit. The port gives each state a field, so a read is one assertion
/// and not a bit-mask argument.
///
/// `failed` is not `error`: `error` is a Zig keyword and cannot name an enum
/// member.
pub const State = enum {
    /// The header is written and the rest of the object is not.
    initializing,
    /// The object is usable. `Object.attach` is the call that puts it in the
    /// tracking list, so a caller reads `isAlive` from that call on.
    alive,
    /// The object has been destroyed. Its memory is still in the arena.
    destroyed,
    /// The object exists, but the call that made it failed.
    failed,
};

/// The back end's teardown for one object. `context` is the object header, so
/// a rule never carries a pointer it could read off the object.
pub const DestroyFn = *const fn (context: *anyopaque, reason: DestroyReason) void;

/// The header every arena object starts with.
///
/// A type that lives in the arena names its first field `header` and
/// publishes a `destroy` method. `ObjectArena.create` reads both, so a type
/// that forgets one is a compile error.
pub const Object = struct {
    kind: handle.Handle.Kind,
    state: State,
    reference_count: u32,
    last_error: ?errors.ValidationError,
    /// The label the caller gave the object. Dawn allocates an `ObjectLabel` on
    /// first write (`src/dawn/native/ObjectBase.cpp:190`); the arena copies the
    /// bytes once, at creation.
    label: []const u8,
    tracking: *ObjectList,
    node: ListNode = .{},
    destroy_callback: DestroyFn,
    context: *anyopaque,

    /// Adds the object to the list that owns it. The caller runs this after it
    /// has written every field of the object that follows its `header`.
    ///
    /// This is `ApiObjectList::Track` (`src/dawn/native/ObjectBase.cpp:109-115`)
    /// at the point Dawn reaches for it: in the constructor body, once the
    /// members exist. A list that is already destroyed takes the object in and
    /// destroys it on this call, so the teardown reads bytes the caller wrote
    /// and not arena fill. `ObjectArena.create` must not call it, because at
    /// that point the caller has written nothing.
    pub fn attach(self: *Object) void {
        self.tracking.track(self);
    }

    /// The object is alive while the tracking list still holds it. Dawn's
    /// `IsAlive` reads the same link state
    /// (`src/dawn/native/ObjectBase.cpp:229-231`).
    pub fn isAlive(self: *const Object) bool {
        return self.node.linked;
    }

    /// The object has finished being made. Dawn asserts the error state is set
    /// once and only once (`src/dawn/native/ObjectBase.cpp:84-92`).
    pub fn isInitialized(self: *const Object) bool {
        return self.state != .initializing;
    }

    /// The object is initialized and the call that made it failed.
    pub fn isFailed(self: *const Object) bool {
        return self.state == .failed;
    }

    pub fn setInitializedNoError(self: *Object) void {
        std.debug.assert(self.state == .initializing);
        std.debug.assert(self.last_error == null);
        self.state = .alive;
    }

    pub fn setInitializedError(self: *Object, rule: errors.ValidationError) void {
        std.debug.assert(self.state == .initializing);
        self.state = .failed;
        self.last_error = rule;
    }

    pub fn retain(self: *Object) void {
        std.debug.assert(self.reference_count != 0);
        self.reference_count += 1;
    }

    /// Hands the object back to the arena when the last reference goes.
    ///
    /// The block stays in the arena, so a handle taken before this call reads
    /// memory the arena still owns and finds `destroyed`. That is what makes a
    /// stale handle a validation error and not undefined behaviour
    /// (`docs/30-port-design.md` §1.1).
    pub fn release(self: *Object) void {
        std.debug.assert(self.reference_count != 0);
        self.reference_count -= 1;
        if (self.reference_count != 0) return;
        self.destroy(.last_reference_released);
    }

    /// Marks the object destroyed and runs the back end's teardown. A second
    /// call does nothing, because the first call untracked the object.
    pub fn destroy(self: *Object, reason: DestroyReason) void {
        if (!self.tracking.untrack(self)) return;
        self.state = .destroyed;
        self.destroy_callback(self.context, reason);
    }
};

// A handle names an `Object`, and `Handle.ptr` carries
// `handle.object_alignment` because every arena object starts with this
// header. The two must agree or the cast in `Device.resolveHeader` would
// assert on every object, so the relationship is stated here where the header
// is defined rather than assumed by the reader of the handle. Zig will not
// attach a doc comment to a `comptime` block, so this one says why in a line
// comment.
comptime {
    if (@alignOf(Object) > handle.object_alignment) {
        @compileError("Handle.ptr is under-aligned for an Object header");
    }
}

/// The two links Dawn's `LinkNode<ApiObjectBase>`
/// (`src/dawn/native/ObjectBase.h:147`) carries.
pub const ListNode = struct {
    previous: ?*Object = null,
    next: ?*Object = null,
    linked: bool = false,
};

/// Every live object of one device. Dawn's `ApiObjectList`
/// (`src/dawn/native/ObjectBase.h:119-145`).
///
/// The list is not locked. Dawn locks it with a `MutexProtected`
/// (`src/dawn/native/ObjectBase.h:144`); the arena takes the device mutex at
/// the milestone that adds threads, and nothing above `core` touches the list
/// without that mutex.
pub const ObjectList = struct {
    head: ?*Object = null,
    tail: ?*Object = null,
    tracked_count: usize = 0,
    marked_destroyed: bool = false,

    /// Adds the object. A list that is already destroyed takes the object in
    /// and destroys it at once, so an object never escapes a dead list alive
    /// (`src/dawn/native/ObjectBase.cpp:109-115`).
    pub fn track(self: *ObjectList, object: *Object) void {
        if (self.marked_destroyed) {
            object.state = .destroyed;
            object.destroy_callback(object.context, .early_destroy);
            return;
        }

        object.node = .{
            .previous = null,
            .next = self.head,
            .linked = true,
        };
        if (self.head) |head| {
            head.node.previous = object;
        } else {
            self.tail = object;
        }
        self.head = object;
        self.tracked_count += 1;
    }

    /// Removes the object. The result is true when the list held it, which is
    /// what makes a second destroy a no-op (`src/dawn/native/ObjectBase.cpp:251`).
    pub fn untrack(self: *ObjectList, object: *Object) bool {
        if (!object.node.linked) return false;
        std.debug.assert(object.tracking == self);

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
        return true;
    }

    /// Destroys every object the list holds and marks the list destroyed.
    ///
    /// Dawn takes the list under a lock and unlinks each object before it runs
    /// the back end (`src/dawn/native/ObjectBase.cpp:121-148`). The port walks
    /// the same order without the lock.
    pub fn destroy(self: *ObjectList, reason: DestroyReason) void {
        self.marked_destroyed = true;
        // The bound is read before the first destroy, so a `destroy_callback`
        // that creates an object cannot extend the loop: `track` sees
        // `marked_destroyed` and destroys the newcomer at once.
        const bound = self.tracked_count;
        for (0..bound) |_| {
            const object = self.tail orelse break;
            object.destroy(reason);
        }
        std.debug.assert(self.tracked_count == 0);
    }

    /// Calls `visit_callback` for every object, newest first.
    ///
    /// Dawn's `ApiObjectList::ForEach`
    /// (`src/dawn/native/ObjectBase.h:130-138`) is a template, so the port
    /// takes a function pointer and its context.
    pub fn forEach(
        self: *const ObjectList,
        context: *anyopaque,
        visit_callback: *const fn (context: *anyopaque, object: *Object) void,
    ) void {
        const bound = self.tracked_count;
        var index: usize = 0;
        var object = self.head;
        while (index < bound) : (index += 1) {
            const current = object orelse break;
            visit_callback(context, current);
            object = current.node.next;
        }
    }
};

/// The contract `ObjectArena.create` relies on. A type that breaks it is a
/// compile error here and not a bad cast later.
///
/// `destroy` has to be public because `destroyTrampoline` calls it from this
/// module. Zig privacy is module-scoped and `@hasDecl` reports only what the
/// calling module can see, so a `destroy` private to the object's own module
/// is invisible here and is unreachable from the trampoline that must run it.
/// A type the arena reclaims in one block writes an empty `destroy` and says
/// in a comment that there is nothing left to drop.
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
        @compileError("an arena object must implement destroy as a public method");
    }
}

/// What `ObjectArena.create` needs. The type parameter is the object type, so
/// the options carry no field the caller could get wrong.
pub fn CreateOptions(comptime T: type) type {
    assertHeader(T);
    return struct {
        kind: handle.Handle.Kind,
        /// The header starts in `alive` unless the caller says otherwise, so a
        /// rule that cannot fail does not have to write a state.
        state: State = .alive,
        label: []const u8 = "",
    };
}

/// The device's object heap.
///
/// One arena per device, `docs/10-architecture.md` "Object model". Nothing is
/// freed here before `deinit`.
pub const ObjectArena = struct {
    memory: std.heap.ArenaAllocator,
    objects: ObjectList,

    pub fn init(child_allocator: std.mem.Allocator) ObjectArena {
        return .{
            .memory = std.heap.ArenaAllocator.init(child_allocator),
            .objects = .{},
        };
    }

    pub fn allocator(self: *ObjectArena) std.mem.Allocator {
        return self.memory.allocator();
    }

    /// The list of live objects. Every `Object` stores a pointer to this list,
    /// so a module that checks ownership compares against this and does not
    /// reach into `objects`.
    pub fn objectList(self: *ObjectArena) *ObjectList {
        return &self.objects;
    }

    /// Allocates one object, writes its header and returns it untracked.
    ///
    /// **The contract.** `create` returns an object the tracking list does not
    /// hold. The caller writes the bytes of `T` after its `header` — they are
    /// undefined until it does, and `std.debug` fills them with `0xaa` in a
    /// Debug build, so a caller that reads one has a loud defect and not a
    /// quiet one — and then calls `Object.attach`. `attach` is the only thing
    /// that tracks, so only an attached object is alive, counted by
    /// `queryTrackedCount`, visited by `ObjectList.forEach` and torn down by
    /// `deinit`.
    ///
    /// The order is the whole contract because `ObjectList.track` destroys an
    /// object that arrives after the list is gone
    /// (`src/dawn/native/ObjectBase.cpp:110-113`), and a teardown reads fields
    /// the caller has not written. Dawn never runs that destroy on an unwritten
    /// object: its constructors call `GetObjectTrackingList()->Track(this)` in
    /// the constructor body, after the member initialiser list has filled
    /// every member (`src/dawn/native/Buffer.cpp:505-507`), so `DestroyImpl`
    /// reads initialised bytes. The arena has no member initialiser list to run
    /// and the caller owns every field after the header, so the port splits
    /// the two steps rather than guess the order.
    ///
    /// An object the caller never attaches keeps its block and never runs its
    /// teardown: `deinit` reclaims the arena, and the list never held it.
    pub fn create(
        self: *ObjectArena,
        comptime T: type,
        options: CreateOptions(T),
    ) std.mem.Allocator.Error!*T {
        const arena_allocator = self.memory.allocator();

        const object = try arena_allocator.create(T);
        errdefer arena_allocator.destroy(object);

        const label = try arena_allocator.dupe(u8, options.label);
        errdefer arena_allocator.free(label);

        object.header = .{
            .kind = options.kind,
            .state = options.state,
            .reference_count = 1,
            .last_error = null,
            .label = label,
            .tracking = &self.objects,
            .destroy_callback = destroyTrampoline(T),
            .context = object,
        };
        return object;
    }

    /// The bytes the arena holds right now.
    ///
    /// `deinit` poisons the receiver, so a read of this after it is a read of
    /// poison. Where the blocks went is asked of the child allocator, which is
    /// the ledger that outlives the arena: `test/object_arena.zig` hands the
    /// device a child of its own and asserts that child reports no leak.
    pub fn queryCapacity(self: *const ObjectArena) usize {
        return self.memory.queryCapacity();
    }

    /// The number of objects the arena still holds alive.
    pub fn queryTrackedCount(self: *const ObjectArena) usize {
        return self.objects.tracked_count;
    }

    /// Destroys every object and reclaims every block.
    ///
    /// After this a handle taken before it dangles and the receiver is poison.
    /// That is the one case `docs/30-port-design.md` §1.1 says the model does
    /// not cover.
    pub fn deinit(self: *ObjectArena) void {
        self.objects.destroy(.early_destroy);
        // `free_all` always succeeds (`lib/std/heap/ArenaAllocator.zig:111`), and
        // it is what nulls both node lists, so the capacity is zero from here to
        // the poison line.
        std.debug.assert(self.memory.reset(.free_all));
        // Every block is back with the child allocator and nothing reads this
        // value again, so the receiver is poison rather than a half-reset arena
        // whose zero capacity is the only record of the reclamation.
        self.* = undefined;
    }
};

/// The teardown of one object type. Zig has no virtual function, so the header
/// carries the function that fills the slot Dawn declares pure virtual at
/// `src/dawn/native/ObjectBase.h:200`.
fn destroyTrampoline(comptime T: type) DestroyFn {
    const trampoline = struct {
        fn run(context: *anyopaque, reason: DestroyReason) void {
            ownerFrom(T, context).destroy(reason);
        }
    };
    return &trampoline.run;
}

/// The owner behind a header pointer. The trampoline above cannot name `T` in
/// its own scope, because the type only reaches it through the nested
/// function, so the cast lives here where `T` is a parameter.
fn ownerFrom(comptime T: type, context: *anyopaque) *T {
    const header: *Object = @ptrCast(@alignCast(context));
    return @fieldParentPtr("header", header);
}

const Counting = struct {
    early_destroy_count: u64 = 0,
    last_reference_released_count: u64 = 0,

    fn total(self: *const Counting) u64 {
        return self.early_destroy_count + self.last_reference_released_count;
    }
};

/// An arena object whose teardown only counts, because it owns nothing. Its
/// `destroy` is public because the arena calls it from `destroyTrampoline`.
const Probe = struct {
    header: Object,
    log: *Counting,

    pub fn destroy(self: *Probe, reason: DestroyReason) void {
        switch (reason) {
            .early_destroy => self.log.early_destroy_count += 1,
            .last_reference_released => self.log.last_reference_released_count += 1,
        }
    }
};

test "an object outlives nothing: the last release destroys it and deinit reclaims it" {
    const object_count: usize = 64;
    var log: Counting = .{};
    // The arena takes its blocks from a child of its own, so where they went is
    // a question the child answers after `deinit` has poisoned the arena.
    var child: std.heap.DebugAllocator(.{}) = .{};
    defer std.testing.expect(child.deinit() == .ok) catch @panic("arena block leaked");
    var arena: ObjectArena = .init(child.allocator());

    for (0..object_count) |_| {
        const probe = try arena.create(Probe, .{ .kind = .buffer, .label = "probe" });
        probe.log = &log;
        probe.header.attach();
        probe.header.retain();
        probe.header.release();
        try std.testing.expect(probe.header.isAlive());
        probe.header.release();
        try std.testing.expect(!probe.header.isAlive());
    }

    try std.testing.expectEqual(@as(usize, 0), arena.queryTrackedCount());
    try std.testing.expect(arena.queryCapacity() > 0);

    arena.deinit();

    // The teardown count says every object ran; the child says every block came
    // home. Neither is a read of the arena, which is poison from here on.
    try std.testing.expectEqual(@as(u64, @intCast(object_count)), log.total());
}

test "a list that is already destroyed destroys the object that arrives late" {
    var log: Counting = .{};

    var arena: ObjectArena = .init(std.testing.allocator);
    defer arena.deinit();

    const probe = try arena.create(Probe, .{ .kind = .buffer });
    probe.log = &log;
    probe.header.attach();

    var seen: usize = 0;
    const list = arena.objectList();
    list.forEach(@ptrCast(&seen), countVisit);
    try std.testing.expectEqual(@as(usize, 1), seen);

    list.destroy(.early_destroy);
    try std.testing.expect(!probe.header.isAlive());
    try std.testing.expectEqual(@as(u64, 1), log.early_destroy_count);

    // The late object is written in full before it reaches the list, so the
    // teardown the dead list runs reads a `log` and not `0xaa` fill. This is
    // the case that faults when `create` tracks: the header is tracked, the
    // dead list destroys it, and `destroy` dereferences `log` before the line
    // below writes it.
    const late = try arena.create(Probe, .{ .kind = .buffer });
    late.log = &log;
    late.header.attach();
    try std.testing.expect(!late.header.isAlive());
    try std.testing.expectEqual(@as(u64, 2), log.early_destroy_count);
}

test "an object the caller never attaches is in no list and runs no teardown" {
    var log: Counting = .{};
    // The child is the ledger that outlives the arena, so it is where the
    // block is checked after `deinit` has poisoned the receiver.
    var child: std.heap.DebugAllocator(.{}) = .{};
    defer std.testing.expect(child.deinit() == .ok) catch @panic("arena block leaked");
    var arena: ObjectArena = .init(child.allocator());

    const probe = try arena.create(Probe, .{ .kind = .buffer });
    probe.log = &log;

    // The header `create` wrote is whole, and the list has not seen it. This is
    // the window the contract names, and it is the one thing `create` must not
    // leave the object in alone.
    try std.testing.expectEqual(@as(usize, 0), arena.queryTrackedCount());
    try std.testing.expect(!probe.header.isAlive());
    try std.testing.expectEqual(@as(u64, 0), log.total());

    // The block is real before the teardown runs, so the leak check above has
    // something to catch and is not vacuous.
    try std.testing.expect(arena.queryCapacity() > 0);

    // `deinit` reclaims the block without a teardown, because the list never
    // held the object. A caller that forgets `attach` pays that, and the two
    // halves of the price are on either side of this line: no teardown ran,
    // and the child still reports no leak.
    arena.deinit();
    try std.testing.expectEqual(@as(u64, 0), log.total());
}

fn countVisit(context: *anyopaque, object: *Object) void {
    const seen: *usize = @ptrCast(@alignCast(context));
    std.debug.assert(object.isAlive());
    seen.* += 1;
}
