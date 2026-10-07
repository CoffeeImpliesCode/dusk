const std = @import("std");

const FreeBlock = struct {
    previous: ?*FreeBlock,
    next: ?*FreeBlock,
    bytes: []u8,
    last_tick: u64,
};

comptime {
    std.debug.assert(@sizeOf(FreeBlock) % @alignOf(FreeBlock) == 0);
}

pub const BlockPool = struct {
    pub const Options = struct {
        block_size_byte_count: usize,
        alignment: std.mem.Alignment = .of(FreeBlock),
        keep_alive_tick_count: u64 = 2,
        max_recycled_block_count: usize = 64,
    };
    pub const Error = error{
        OutOfMemory,
        BlockTooSmallForLink,
        BlockMisalignedForLink,
        InvalidAlignment,
        BlockAlreadyReturned,
    };

    block_size_byte_count: usize,
    alignment: std.mem.Alignment,
    keep_alive_tick_count: u64,
    max_recycled_block_count: usize,
    tick_serial: u64 = 0,
    oldest: ?*FreeBlock = null,
    newest: ?*FreeBlock = null,
    recycled_count: usize = 0,

    pub fn init(options: Options) error{InvalidAlignment}!BlockPool {
        if (options.alignment.toByteUnits() < @alignOf(FreeBlock)) {
            return error.InvalidAlignment;
        }
        return .{
            .block_size_byte_count = @max(options.block_size_byte_count, @sizeOf(FreeBlock)),
            .alignment = options.alignment,
            .keep_alive_tick_count = options.keep_alive_tick_count,
            .max_recycled_block_count = options.max_recycled_block_count,
        };
    }

    pub fn allocate(
        allocator: std.mem.Allocator,
        self: *BlockPool,
        minimum_size_byte_count: usize,
    ) error{OutOfMemory}![]u8 {
        if (minimum_size_byte_count <= self.block_size_byte_count) {
            if (self.newest) |node| return self.unlinkBlock(node);
        }
        const size = @max(minimum_size_byte_count, self.block_size_byte_count);
        const bytes = allocator.rawAlloc(size, self.alignment, @returnAddress()) orelse
            return error.OutOfMemory;
        return bytes[0..size];
    }

    fn linkFromBlock(self: *BlockPool, block: []u8) Error!*FreeBlock {
        if (block.len < @sizeOf(FreeBlock)) return error.BlockTooSmallForLink;
        if (@intFromPtr(block.ptr) % @alignOf(FreeBlock) != 0) {
            return error.BlockMisalignedForLink;
        }
        const node: *FreeBlock = @ptrCast(@alignCast(block.ptr));
        std.debug.assert(@intFromPtr(node) % @alignOf(FreeBlock) == 0);
        node.* = .{
            .previous = self.newest,
            .next = null,
            .bytes = block,
            .last_tick = self.tick_serial,
        };
        if (self.newest) |tail| {
            tail.next = node;
        } else {
            self.oldest = node;
        }
        self.newest = node;
        self.recycled_count += 1;
        return node;
    }

    fn unlinkBlock(self: *BlockPool, node: *FreeBlock) []u8 {
        // Copy the slice before its placement node can be overwritten or freed.
        const bytes = node.bytes;
        if (node.previous) |previous| {
            previous.next = node.next;
        } else {
            self.oldest = node.next;
        }
        if (node.next) |next| {
            next.previous = node.previous;
        } else {
            self.newest = node.previous;
        }
        std.debug.assert(self.recycled_count > 0);
        self.recycled_count -= 1;
        return bytes;
    }

    /// Consumes block on success. Use the same allocator as allocate.
    pub fn returnBlock(
        allocator: std.mem.Allocator,
        self: *BlockPool,
        block: []u8,
    ) Error!void {
        if (@intFromPtr(block.ptr) % self.alignment.toByteUnits() != 0) {
            return error.BlockMisalignedForLink;
        }
        var cursor = self.oldest;
        for (0..self.recycled_count) |_| {
            const node = cursor.?;
            if (node.bytes.ptr == block.ptr) return error.BlockAlreadyReturned;
            cursor = node.next;
        }
        if (block.len != self.block_size_byte_count or
            self.keep_alive_tick_count == 0 or self.recycled_count == self.max_recycled_block_count)
        {
            allocator.rawFree(block, self.alignment, @returnAddress());
            return;
        }
        _ = try self.linkFromBlock(block);
    }

    /// Consumes each successful return; an error leaves only unconsumed entries.
    pub fn returnBlocks(
        allocator: std.mem.Allocator,
        self: *BlockPool,
        blocks: *std.ArrayList([]u8),
    ) Error!void {
        var consumed: usize = 0;
        defer {
            const remaining = blocks.items.len - consumed;
            @memmove(blocks.items[0..remaining], blocks.items[consumed..]);
            blocks.items.len -= consumed;
        }
        while (consumed < blocks.items.len) : (consumed += 1) {
            try returnBlock(allocator, self, blocks.items[consumed]);
        }
    }

    pub fn tick(allocator: std.mem.Allocator, self: *BlockPool) void {
        if (self.tick_serial == std.math.maxInt(u64)) {
            const count = self.recycled_count;
            for (0..count) |_| {
                const node = self.oldest orelse break;
                if (self.tick_serial - node.last_tick < self.keep_alive_tick_count) break;
                allocator.rawFree(self.unlinkBlock(node), self.alignment, @returnAddress());
            }
            // Rebase retained timestamps together instead of overflowing their ages.
            const base = if (self.oldest) |node| node.last_tick else self.tick_serial;
            std.debug.assert(base > 0);
            var cursor = self.oldest;
            for (0..self.recycled_count) |_| {
                const node = cursor.?;
                node.last_tick -= base;
                cursor = node.next;
            }
            self.tick_serial -= base;
        }
        self.tick_serial += 1;
        const count = self.recycled_count;
        for (0..count) |_| {
            const node = self.oldest orelse break;
            if (self.tick_serial - node.last_tick < self.keep_alive_tick_count) break;
            allocator.rawFree(self.unlinkBlock(node), self.alignment, @returnAddress());
        }
    }

    pub fn trim(allocator: std.mem.Allocator, self: *BlockPool) void {
        const count = self.recycled_count;
        for (0..count) |_| {
            allocator.rawFree(self.unlinkBlock(self.oldest.?), self.alignment, @returnAddress());
        }
    }

    pub fn deinit(allocator: std.mem.Allocator, self: *BlockPool) void {
        trim(allocator, self);
        std.debug.assert(self.oldest == null);
        std.debug.assert(self.newest == null);
    }

    pub fn recycledBlockCount(self: *const BlockPool) usize {
        return self.recycled_count;
    }
};

test "pool reuses exact blocks and bypasses oversized requests" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(.{ .block_size_byte_count = 128 });
    defer BlockPool.deinit(allocator, &pool);
    const block = try BlockPool.allocate(allocator, &pool, 1);
    const address = @intFromPtr(block.ptr);
    try BlockPool.returnBlock(allocator, &pool, block);
    const reused = try BlockPool.allocate(allocator, &pool, 128);
    try std.testing.expectEqual(address, @intFromPtr(reused.ptr));
    try BlockPool.returnBlock(allocator, &pool, reused);
    const oversized = try BlockPool.allocate(allocator, &pool, 129);
    try std.testing.expectEqual(@as(usize, 129), oversized.len);
    try BlockPool.returnBlock(allocator, &pool, oversized);
    try std.testing.expectEqual(@as(usize, 1), pool.recycledBlockCount());
}

test "pool tick expires FIFO prefix at inclusive boundary and retention is bounded" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(.{
        .block_size_byte_count = 128,
        .keep_alive_tick_count = 2,
        .max_recycled_block_count = 2,
    });
    defer BlockPool.deinit(allocator, &pool);
    const first = try BlockPool.allocate(allocator, &pool, 1);
    const second = try BlockPool.allocate(allocator, &pool, 1);
    const third = try BlockPool.allocate(allocator, &pool, 1);
    try BlockPool.returnBlock(allocator, &pool, first);
    BlockPool.tick(allocator, &pool);
    try BlockPool.returnBlock(allocator, &pool, second);
    try BlockPool.returnBlock(allocator, &pool, third);
    try std.testing.expectEqual(@as(usize, 2), pool.recycledBlockCount());
    BlockPool.tick(allocator, &pool);
    try std.testing.expectEqual(@as(usize, 1), pool.recycledBlockCount());
    BlockPool.tick(allocator, &pool);
    try std.testing.expectEqual(@as(usize, 0), pool.recycledBlockCount());
}

test "pool batch consumes slices and zero window frees immediately" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(.{ .block_size_byte_count = 128, .keep_alive_tick_count = 0 });
    defer BlockPool.deinit(allocator, &pool);
    var blocks: std.ArrayList([]u8) = .empty;
    defer blocks.deinit(allocator);
    try blocks.append(allocator, try BlockPool.allocate(allocator, &pool, 1));
    try blocks.append(allocator, try BlockPool.allocate(allocator, &pool, 200));
    try BlockPool.returnBlocks(allocator, &pool, &blocks);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.recycledBlockCount());
}

fn exercisePool(allocator: std.mem.Allocator) !void {
    var pool = try BlockPool.init(.{ .block_size_byte_count = 128 });
    defer BlockPool.deinit(allocator, &pool);
    const block = try BlockPool.allocate(allocator, &pool, 1);
    try BlockPool.returnBlock(allocator, &pool, block);
    const large = try BlockPool.allocate(allocator, &pool, 256);
    try BlockPool.returnBlock(allocator, &pool, large);
}

test "pool allocation failure leaves intrusive state intact" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercisePool, .{});
}

test "placement links reject undersized misaligned and duplicate blocks" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(.{ .block_size_byte_count = 1 });
    defer BlockPool.deinit(allocator, &pool);
    try std.testing.expectEqual(@sizeOf(FreeBlock), pool.block_size_byte_count);
    var bytes: [@sizeOf(FreeBlock) + 1]u8 align(@alignOf(FreeBlock)) = undefined;
    try std.testing.expectError(error.BlockTooSmallForLink, pool.linkFromBlock(bytes[0..1]));
    try std.testing.expectError(error.BlockMisalignedForLink, pool.linkFromBlock(bytes[1..]));
    try std.testing.expectError(error.InvalidAlignment, BlockPool.init(.{
        .block_size_byte_count = 128,
        .alignment = .fromByteUnits(1),
    }));
    const block = try BlockPool.allocate(allocator, &pool, 1);
    try BlockPool.returnBlock(allocator, &pool, block);
    try std.testing.expectError(
        error.BlockAlreadyReturned,
        BlockPool.returnBlock(allocator, &pool, block),
    );
    BlockPool.trim(allocator, &pool);
    try std.testing.expectEqual(@as(usize, 0), pool.recycledBlockCount());
}

test "tick rollover preserves a newly returned block until its deadline" {
    const allocator = std.testing.allocator;
    var pool = try BlockPool.init(.{ .block_size_byte_count = 128 });
    defer BlockPool.deinit(allocator, &pool);
    pool.tick_serial = std.math.maxInt(u64);
    const block = try BlockPool.allocate(allocator, &pool, 1);
    try BlockPool.returnBlock(allocator, &pool, block);
    BlockPool.tick(allocator, &pool);
    try std.testing.expectEqual(@as(usize, 1), pool.recycledBlockCount());
    BlockPool.tick(allocator, &pool);
    try std.testing.expectEqual(@as(usize, 0), pool.recycledBlockCount());
}
