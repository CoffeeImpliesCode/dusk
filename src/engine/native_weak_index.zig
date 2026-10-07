//! Intrusive weak membership under the original ObjectGuard.
//! Key data remains in each payload. The stable index outlives all removal hooks.
const std = @import("std");
const core = @import("../core/root.zig");

pub fn WeakIndex(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        objects: *core.ObjectList,
        buckets: std.AutoHashMapUnmanaged(u64, *T) = .empty,
        member_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, objects: *core.ObjectList) Self {
            return .{ .allocator = allocator, .objects = objects };
        }

        pub fn deinit(self: *Self, guard: *const core.ObjectGuard) void {
            guard.assertOwns(self.objects);
            std.debug.assert(self.member_count == 0);
            std.debug.assert(self.buckets.count() == 0);
            self.buckets.deinit(self.allocator);
            self.* = undefined;
        }

        /// Borrows a live payload until the guard is released.
        pub fn find(
            self: *const Self,
            guard: *const core.ObjectGuard,
            hash: u64,
            query: anytype,
            comptime matches: fn (*const T, @TypeOf(query)) bool,
        ) ?*T {
            guard.assertOwns(self.objects);
            var current = self.buckets.get(hash);
            var visited: usize = 0;
            while (visited < self.member_count) : (visited += 1) {
                const object = current orelse return null;
                std.debug.assert(object.header.tracking == self.objects);
                std.debug.assert(object.header.isAlive(guard));
                std.debug.assert(object.cache_hash == hash);
                const context: *anyopaque = @ptrCast(@constCast(self));
                std.debug.assert(object.header.cache_context == context);
                if (matches(object, query)) return object;
                current = object.cache_next;
            }
            std.debug.assert(current == null);
            return null;
        }

        /// Publishes the hook only after the final fallible bucket allocation.
        pub fn insert(
            self: *Self,
            guard: *const core.ObjectGuard,
            object: *T,
            hash: u64,
        ) std.mem.Allocator.Error!void {
            guard.assertOwns(self.objects);
            std.debug.assert(object.header.tracking == self.objects);
            std.debug.assert(object.header.isAlive(guard));
            std.debug.assert(object.header.remove_from_cache == null);
            std.debug.assert(object.header.cache_context == null);
            std.debug.assert(object.cache_next == null);
            std.debug.assert(self.member_count < std.math.maxInt(usize));
            const bucket = try self.buckets.getOrPut(self.allocator, hash);
            object.cache_hash = hash;
            object.cache_next = if (bucket.found_existing) bucket.value_ptr.* else null;
            bucket.value_ptr.* = object;
            self.member_count += 1;
            object.header.setCacheRemovalLocked(guard, self, remove);
        }

        fn remove(context: *anyopaque, guard: *const core.ObjectGuard, header: *core.Object) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const victim: *T = @fieldParentPtr("header", header);
            guard.assertOwns(self.objects);
            std.debug.assert(header.tracking == self.objects);
            std.debug.assert(header.remove_from_cache == null);
            std.debug.assert(header.cache_context == null);
            const bucket = self.buckets.getPtr(victim.cache_hash) orelse unreachable;
            var previous: ?*T = null;
            var current: ?*T = bucket.*;
            var visited: usize = 0;
            while (visited < self.member_count) : (visited += 1) {
                const object = current orelse unreachable;
                if (object == victim) {
                    if (previous) |parent| {
                        parent.cache_next = object.cache_next;
                    } else if (object.cache_next) |next| {
                        bucket.* = next;
                    } else {
                        const removed = self.buckets.remove(victim.cache_hash);
                        std.debug.assert(removed);
                    }
                    victim.cache_next = null;
                    self.member_count -= 1;
                    return;
                }
                previous = object;
                current = object.cache_next;
            }
            unreachable;
        }

        pub fn isEmpty(self: *const Self, guard: *const core.ObjectGuard) bool {
            guard.assertOwns(self.objects);
            return self.member_count == 0;
        }
    };
}
