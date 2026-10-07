const std = @import("std");
const BlockPool = @import("block_pool.zig").BlockPool;

/// T is initialized by the caller. The pool and its allocator must outlive all slabs.
pub fn SlabAllocator(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("slab objects must have nonzero size");
    return struct {
        const Self = @This();
        const invalid_index = std.math.maxInt(u16);
        const allocated_index = invalid_index - 1;
        const IndexLinkNode = struct { index: u16, next_index: u16 };
        const State = enum { available, full, recycled };
        const Slab = struct {
            previous: ?*Slab,
            next: ?*Slab,
            bytes: []u8,
            free_index: u16,
            blocks_in_use: usize,
            state: State,
        };
        const object_alignment = @max(@alignOf(T), @alignOf(IndexLinkNode));
        pub const allocation_alignment = @max(object_alignment, @alignOf(Slab));
        pub const slab_blocks_offset = std.mem.alignForward(
            usize,
            @sizeOf(Slab),
            object_alignment,
        );
        pub const index_link_node_offset = std.mem.alignForward(
            usize,
            @sizeOf(T),
            @alignOf(IndexLinkNode),
        );
        pub const block_stride = std.mem.alignForward(
            usize,
            index_link_node_offset + @sizeOf(IndexLinkNode),
            object_alignment,
        );
        pub const InitError = error{InvalidLayout};
        pub const AllocateError = error{ OutOfMemory, SlabLimitExceeded };
        pub const default_max_slab_count = 4096;
        pub const DeallocationError = error{ InvalidPointer, AlreadyFreed, InvalidNode };
        pub const Options = struct {
            pool: *BlockPool,
            object_budget_byte_count: usize,
            max_slab_count: usize = default_max_slab_count,
        };

        pool: *BlockPool,
        blocks_per_slab: usize,
        total_allocation_byte_count: usize,
        max_slab_count: usize,
        available: ?*Slab = null,
        full: ?*Slab = null,
        recycled: ?*Slab = null,
        slab_count: usize = 0,

        pub fn poolOptions(object_budget_byte_count: usize) InitError!BlockPool.Options {
            const count = @max(@divFloor(object_budget_byte_count, @sizeOf(T)), 1);
            if (count > allocated_index) return error.InvalidLayout;
            const bytes = std.math.mul(usize, count, block_stride) catch
                return error.InvalidLayout;
            const total = std.math.add(usize, slab_blocks_offset, bytes) catch
                return error.InvalidLayout;
            return .{
                .block_size_byte_count = total,
                .alignment = .fromByteUnits(allocation_alignment),
                .keep_alive_tick_count = 0,
                .max_recycled_block_count = 0,
            };
        }

        pub fn init(options: Options) InitError!Self {
            const expected = try poolOptions(options.object_budget_byte_count);
            if (options.max_slab_count == 0) return error.InvalidLayout;
            if (options.pool.block_size_byte_count != expected.block_size_byte_count or
                options.pool.alignment.toByteUnits() < allocation_alignment or
                options.pool.keep_alive_tick_count != 0)
            {
                return error.InvalidLayout;
            }
            return .{
                .pool = options.pool,
                .blocks_per_slab = @max(
                    @divFloor(options.object_budget_byte_count, @sizeOf(T)),
                    1,
                ),
                .total_allocation_byte_count = expected.block_size_byte_count,
                .max_slab_count = options.max_slab_count,
            };
        }

        fn head(self: *Self, state: State) *?*Slab {
            return switch (state) {
                .available => &self.available,
                .full => &self.full,
                .recycled => &self.recycled,
            };
        }

        fn prependSlab(self: *Self, slab: *Slab, state: State) void {
            const list = self.head(state);
            slab.previous = null;
            slab.next = list.*;
            slab.state = state;
            if (list.*) |next| next.previous = slab;
            list.* = slab;
        }

        fn spliceSlab(self: *Self, slab: *Slab) void {
            if (slab.previous) |previous| {
                previous.next = slab.next;
            } else {
                std.debug.assert(self.head(slab.state).* == slab);
                self.head(slab.state).* = slab.next;
            }
            if (slab.next) |next| next.previous = slab.previous;
            slab.previous = null;
            slab.next = null;
        }

        fn nodeAt(slab: *Slab, index: usize) *IndexLinkNode {
            const address = @intFromPtr(slab) + slab_blocks_offset +
                index * block_stride + index_link_node_offset;
            return @ptrFromInt(address);
        }

        fn offsetFrom(node: *IndexLinkNode, offset: isize) *IndexLinkNode {
            const address = @intFromPtr(node);
            if (offset >= 0) {
                return @ptrFromInt(address + @as(usize, @intCast(offset)) * block_stride);
            }
            return @ptrFromInt(address - @as(usize, @intCast(-offset)) * block_stride);
        }

        fn nodeFromObject(object: *T) *IndexLinkNode {
            return @ptrFromInt(@intFromPtr(object) + index_link_node_offset);
        }

        fn objectFromNode(node: *IndexLinkNode) *T {
            return @ptrFromInt(@intFromPtr(node) - index_link_node_offset);
        }

        fn nodeIsInSlab(self: *const Self, slab: *Slab, node: *IndexLinkNode) bool {
            const first = @intFromPtr(nodeAt(slab, 0));
            const address = @intFromPtr(node);
            const in_range = address >= first and
                address <= first + (self.blocks_per_slab - 1) * block_stride;
            if (!in_range) return false;
            const on_stride = (address - first) % block_stride == 0;
            if (!on_stride) return false;
            const index_matches = node.index == @divExact(address - first, block_stride);
            return index_matches;
        }

        fn initFreeList(self: *Self, slab: *Slab) void {
            for (0..self.blocks_per_slab) |index| {
                nodeAt(slab, index).* = .{
                    .index = @intCast(index),
                    .next_index = if (index + 1 == self.blocks_per_slab)
                        invalid_index
                    else
                        @intCast(index + 1),
                };
            }
        }

        fn initNewSlab(allocator: std.mem.Allocator, self: *Self) AllocateError!void {
            std.debug.assert(self.available == null);
            if (self.recycled != null) {
                self.available = self.recycled;
                self.recycled = null;
                var cursor = self.available;
                for (0..self.max_slab_count) |_| {
                    const slab = cursor orelse break;
                    slab.state = .available;
                    cursor = slab.next;
                }
                return;
            }
            if (self.slab_count == self.max_slab_count) return error.SlabLimitExceeded;
            const bytes = try BlockPool.allocate(
                allocator,
                self.pool,
                self.total_allocation_byte_count,
            );
            std.debug.assert(@intFromPtr(bytes.ptr) % allocation_alignment == 0);
            const slab: *Slab = @ptrCast(@alignCast(bytes.ptr));
            slab.* = .{
                .previous = null,
                .next = null,
                .bytes = bytes,
                .free_index = 0,
                .blocks_in_use = 0,
                .state = .available,
            };
            self.initFreeList(slab);
            self.prependSlab(slab, .available);
            self.slab_count += 1;
        }

        fn popFreeBlock(self: *Self, slab: *Slab) *IndexLinkNode {
            std.debug.assert(slab.free_index != invalid_index);
            std.debug.assert(slab.blocks_in_use < self.blocks_per_slab);
            const node = nodeAt(slab, slab.free_index);
            std.debug.assert(self.nodeIsInSlab(slab, node));
            slab.free_index = node.next_index;
            node.next_index = allocated_index;
            slab.blocks_in_use += 1;
            return node;
        }

        fn pushFreeBlock(self: *Self, slab: *Slab, node: *IndexLinkNode) void {
            std.debug.assert(self.nodeIsInSlab(slab, node));
            std.debug.assert(slab.blocks_in_use > 0);
            node.next_index = slab.free_index;
            slab.free_index = node.index;
            slab.blocks_in_use -= 1;
        }

        /// Returns uninitialized T storage. Initialize it before reading it.
        /// Available slabs are filled before recycled slabs; no next-address reuse is promised.
        /// This preserves the active slab, as in pinned Dawn SlabAllocator.h:47-70 and
        /// SlabAllocator.cpp:230-283 (tools/dawn_pin.zon).
        pub fn allocate(allocator: std.mem.Allocator, self: *Self) AllocateError!*T {
            if (self.available == null) try initNewSlab(allocator, self);
            const slab = self.available.?;
            const node = self.popFreeBlock(slab);
            if (slab.blocks_in_use == self.blocks_per_slab) {
                self.spliceSlab(slab);
                self.prependSlab(slab, .full);
            }
            return objectFromNode(node);
        }

        fn findSlab(self: *Self, object: *T) ?*Slab {
            // Validate membership before reading placement metadata from an untrusted pointer.
            const address = @intFromPtr(object);
            for ([_]?*Slab{ self.available, self.full, self.recycled }) |list| {
                var cursor = list;
                for (0..self.max_slab_count) |_| {
                    const slab = cursor orelse break;
                    const first = @intFromPtr(slab) + slab_blocks_offset;
                    if (address >= first and
                        address <= first + (self.blocks_per_slab - 1) * block_stride and
                        (address - first) % block_stride == 0) return slab;
                    cursor = slab.next;
                }
            }
            return null;
        }

        /// Does not destroy T. The caller must release its resources before this call.
        pub fn deallocate(self: *Self, object: *T) DeallocationError!void {
            const slab = self.findSlab(object) orelse return error.InvalidPointer;
            const node = nodeFromObject(object);
            if (!self.nodeIsInSlab(slab, node)) return error.InvalidNode;
            const first_node = offsetFrom(node, -@as(isize, @intCast(node.index)));
            if (@intFromPtr(objectFromNode(first_node)) - slab_blocks_offset !=
                @intFromPtr(slab)) return error.InvalidNode;
            if (node.next_index != allocated_index) return error.AlreadyFreed;
            const was_full = slab.blocks_in_use == self.blocks_per_slab;
            self.pushFreeBlock(slab, node);
            if (was_full) {
                self.spliceSlab(slab);
                self.prependSlab(slab, .recycled);
            }
        }

        fn releaseSlab(allocator: std.mem.Allocator, self: *Self, slab: *Slab) void {
            std.debug.assert(slab.blocks_in_use == 0);
            const bytes = slab.bytes;
            self.spliceSlab(slab);
            self.slab_count -= 1;
            BlockPool.returnBlock(allocator, self.pool, bytes) catch
                @panic("slab block violated the validated pool contract");
        }

        pub fn deleteEmptySlabs(allocator: std.mem.Allocator, self: *Self) void {
            for ([_]?*Slab{ self.recycled, self.available }) |list| {
                var cursor = list;
                for (0..self.max_slab_count) |_| {
                    const slab = cursor orelse break;
                    const next = slab.next;
                    if (slab.blocks_in_use == 0) releaseSlab(allocator, self, slab);
                    cursor = next;
                }
            }
        }

        pub fn destroyAllSlabs(
            allocator: std.mem.Allocator,
            self: *Self,
        ) error{LiveAllocations}!void {
            for ([_]?*Slab{ self.available, self.full, self.recycled }) |list| {
                var cursor = list;
                for (0..self.max_slab_count) |_| {
                    const slab = cursor orelse break;
                    if (slab.blocks_in_use != 0) return error.LiveAllocations;
                    cursor = slab.next;
                }
            }
            deleteEmptySlabs(allocator, self);
            std.debug.assert(self.slab_count == 0);
        }

        pub fn allocatedSlabCount(self: *const Self) usize {
            return self.slab_count;
        }

        pub fn deinit(self: *Self) error{SlabsNotDestroyed}!void {
            if (self.slab_count != 0) return error.SlabsNotDestroyed;
            std.debug.assert(self.available == null);
            std.debug.assert(self.full == null);
            std.debug.assert(self.recycled == null);
        }
    };
}

const TestObject = struct { value: u64 };
const TestSlab = SlabAllocator(TestObject);

test "slab full recycled transitions preserve storage and reject double free" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(try TestSlab.poolOptions(16));
    defer BlockPool.deinit(allocator, &pool);
    var slab = try TestSlab.init(.{ .pool = &pool, .object_budget_byte_count = 16 });
    const first = try TestSlab.allocate(allocator, &slab);
    first.* = .{ .value = 42 };
    const second = try TestSlab.allocate(allocator, &slab);
    second.* = .{ .value = 17 };
    try std.testing.expect(slab.available == null);
    try std.testing.expect(slab.full != null);
    try std.testing.expectError(error.LiveAllocations, TestSlab.destroyAllSlabs(allocator, &slab));
    try slab.deallocate(first);
    try std.testing.expectEqual(@as(u64, 42), first.value);
    try std.testing.expect(slab.recycled != null);
    try std.testing.expectError(error.AlreadyFreed, slab.deallocate(first));
    const reused = try TestSlab.allocate(allocator, &slab);
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqual(@as(usize, 1), slab.allocatedSlabCount());
    try slab.deallocate(reused);
    try slab.deallocate(second);
    TestSlab.deleteEmptySlabs(allocator, &slab);
    try std.testing.expectEqual(@as(usize, 0), slab.allocatedSlabCount());
    try std.testing.expectEqual(@as(usize, 0), pool.recycledBlockCount());
    try std.testing.expectError(error.InvalidPointer, slab.deallocate(first));
    try slab.deinit();
}

test "slab rejects foreign pointers and preserves over-aligned layout" {
    const Object = struct { value: u8 align(128) };
    const Slab = SlabAllocator(Object);
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(try Slab.poolOptions(1));
    defer BlockPool.deinit(allocator, &pool);
    var slab = try Slab.init(.{ .pool = &pool, .object_budget_byte_count = 1 });
    const object = try Slab.allocate(allocator, &slab);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(object) % 128);
    try std.testing.expectEqual(@as(usize, 1), slab.blocks_per_slab);
    var foreign: Object = .{ .value = 1 };
    try std.testing.expectError(error.InvalidPointer, slab.deallocate(&foreign));
    try std.testing.expectError(error.SlabsNotDestroyed, slab.deinit());
    try slab.deallocate(object);
    try Slab.destroyAllSlabs(allocator, &slab);
    try slab.deinit();
}

fn exerciseSlab(allocator: std.mem.Allocator) !void {
    var pool = try BlockPool.init(try TestSlab.poolOptions(1));
    defer BlockPool.deinit(allocator, &pool);
    var slab = try TestSlab.init(.{ .pool = &pool, .object_budget_byte_count = 1 });
    defer TestSlab.destroyAllSlabs(allocator, &slab) catch @panic("live test objects");
    const first = try TestSlab.allocate(allocator, &slab);
    defer slab.deallocate(first) catch @panic("invalid test object");
    const second = try TestSlab.allocate(allocator, &slab);
    try slab.deallocate(second);
}

test "slab fresh allocation failure preserves lists" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSlab, .{});
}

test "slab validates node identity before mutating free lists" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(try TestSlab.poolOptions(16));
    defer BlockPool.deinit(allocator, &pool);
    var slab = try TestSlab.init(.{ .pool = &pool, .object_budget_byte_count = 16 });
    const object = try TestSlab.allocate(allocator, &slab);
    const node = TestSlab.nodeFromObject(object);
    const saved_index = node.index;
    node.index = 1;
    try std.testing.expectError(error.InvalidNode, slab.deallocate(object));
    try std.testing.expectEqual(@as(usize, 1), slab.available.?.blocks_in_use);
    node.index = saved_index;
    try slab.deallocate(object);
    try TestSlab.destroyAllSlabs(allocator, &slab);
    try slab.deinit();
}

test "slab rejects mismatched pool and reserved index count" {
    try std.testing.expectError(
        error.InvalidLayout,
        TestSlab.poolOptions(std.math.maxInt(usize)),
    );
    var pool = try BlockPool.init(.{ .block_size_byte_count = 128 });
    try std.testing.expectError(error.InvalidLayout, TestSlab.init(.{
        .pool = &pool,
        .object_budget_byte_count = 16,
    }));
}

test "empty slab drain preserves a partially occupied slab" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(try TestSlab.poolOptions(16));
    defer BlockPool.deinit(allocator, &pool);
    var slab = try TestSlab.init(.{ .pool = &pool, .object_budget_byte_count = 16 });
    const first = try TestSlab.allocate(allocator, &slab);
    const second = try TestSlab.allocate(allocator, &slab);
    const third = try TestSlab.allocate(allocator, &slab);
    try slab.deallocate(first);
    try slab.deallocate(second);
    TestSlab.deleteEmptySlabs(allocator, &slab);
    try std.testing.expectEqual(@as(usize, 1), slab.allocatedSlabCount());
    try slab.deallocate(third);
    try TestSlab.destroyAllSlabs(allocator, &slab);
    try slab.deinit();
}

test "slab limit rejects growth atomically and permits recycled reuse" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(try TestSlab.poolOptions(1));
    defer BlockPool.deinit(allocator, &pool);
    var slab = try TestSlab.init(.{
        .pool = &pool,
        .object_budget_byte_count = 1,
        .max_slab_count = 1,
    });
    const first = try TestSlab.allocate(allocator, &slab);
    first.* = .{ .value = 91 };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.SlabLimitExceeded,
        TestSlab.allocate(failing.allocator(), &slab),
    );
    try std.testing.expectEqual(@as(usize, 1), slab.allocatedSlabCount());
    try std.testing.expectEqual(@as(u64, 91), first.value);
    try std.testing.expect(slab.full != null);
    try std.testing.expect(slab.available == null);
    try std.testing.expect(slab.recycled == null);
    try slab.deallocate(first);
    const reused = try TestSlab.allocate(failing.allocator(), &slab);
    try std.testing.expectEqual(first, reused);
    try slab.deallocate(reused);
    TestSlab.deleteEmptySlabs(allocator, &slab);
    const fresh = try TestSlab.allocate(allocator, &slab);
    try slab.deallocate(fresh);
    try TestSlab.destroyAllSlabs(allocator, &slab);
    try slab.deinit();
    try std.testing.expectError(error.InvalidLayout, TestSlab.init(.{
        .pool = &pool,
        .object_budget_byte_count = 1,
        .max_slab_count = 0,
    }));
}
