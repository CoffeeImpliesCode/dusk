//! Exercises collisions, final insertion failure and eviction before payload cleanup.
const std = @import("std");
const core = @import("../core/root.zig");
const WeakIndex = @import("native_weak_index.zig").WeakIndex;

const Probe = struct {
    header: core.Object,
    value: u64,
    cache_hash: u64 = 0,
    cache_next: ?*Probe = null,
    index: *WeakIndex(Probe),
    destructions: *u32,

    pub fn destroy(self: *Probe, guard: *const core.ObjectGuard, _: std.Io, _: core.DestroyReason) void {
        std.debug.assert(self.index.find(guard, self.cache_hash, self.value, matches) != self);
        self.destructions.* += 1;
    }
    fn matches(self: *const Probe, value: u64) bool {
        return self.value == value;
    }
};

fn create(arena: *core.ObjectArena, guard: *const core.ObjectGuard, index: *WeakIndex(Probe), value: u64, destructions: *u32) !*Probe {
    const object = try arena.create(std.testing.allocator, guard, Probe, .{ .kind = .pipeline_layout, .initial_reference = .user });
    object.value = value;
    object.cache_hash = 0;
    object.cache_next = null;
    object.index = index;
    object.destructions = destructions;
    object.header.attach(guard, std.testing.io);
    return object;
}

test "weak index compares full semantics in one hash bucket and returns lease-only aliases" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(gpa, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
    defer guard.unlock(io);
    defer arena.deinit(gpa, &guard) catch unreachable;
    var index = WeakIndex(Probe).init(gpa, arena.objectList());
    defer index.deinit(&guard);
    var destructions: u32 = 0;
    const first = try create(&arena, &guard, &index, 10, &destructions);
    const second = try create(&arena, &guard, &index, 20, &destructions);
    try index.insert(&guard, first, 7);
    try index.insert(&guard, second, 7);
    try std.testing.expect(index.find(&guard, 7, @as(u64, 10), Probe.matches) == first);
    try std.testing.expect(index.find(&guard, 7, @as(u64, 20), Probe.matches) == second);
    try std.testing.expect(index.find(&guard, 7, @as(u64, 30), Probe.matches) == null);
    try first.header.retainLeaseLocked(&guard);
    try first.header.releaseUserLocked(&guard, io);
    const alias = index.find(&guard, 7, @as(u64, 10), Probe.matches).?;
    try alias.header.acquireUserLocked(&guard);
    first.header.releaseLeaseLocked(&guard, io);
    try alias.header.releaseUserLocked(&guard, io);
    try std.testing.expect(index.find(&guard, 7, @as(u64, 10), Probe.matches) == null);
    try std.testing.expect(index.find(&guard, 7, @as(u64, 20), Probe.matches) == second);
    second.header.retirePayloadLocked(&guard, io, .early_destroy);
    try std.testing.expect(index.isEmpty(&guard));
    try second.header.releaseUserLocked(&guard, io);
    try std.testing.expectEqual(@as(u32, 2), destructions);
}

test "failed final weak insertion leaves no hook and can retire native payload once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(gpa, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
    defer guard.unlock(io);
    defer arena.deinit(gpa, &guard) catch unreachable;
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var index = WeakIndex(Probe).init(failing.allocator(), arena.objectList());
    defer index.deinit(&guard);
    var destructions: u32 = 0;
    const object = try create(&arena, &guard, &index, 10, &destructions);
    try std.testing.expectError(error.OutOfMemory, index.insert(&guard, object, 7));
    try std.testing.expect(object.header.remove_from_cache == null);
    try std.testing.expect(object.header.cache_context == null);
    try std.testing.expect(index.isEmpty(&guard));
    try object.header.releaseUserLocked(&guard, io);
    try std.testing.expectEqual(@as(u32, 1), destructions);
}
