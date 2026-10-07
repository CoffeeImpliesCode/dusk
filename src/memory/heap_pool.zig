//! Fixed-size heap recycling through the existing ResourceHeapAllocator interface.
//! Return each allocated heap once, release recycled heaps, then call `deinit`.
//! Parent callbacks run on the calling thread and must not reenter this pool.
//! This module does not create device memory. The injected parent does that.

const std = @import("std");
const heap_module = @import("resource_heap.zig");
const heap_allocator = @import("resource_heap_allocator.zig");
const Heap = heap_module.Heap;
const ResourceHeapAllocator = heap_allocator.ResourceHeapAllocator;

/// The pool owns its pointer storage and recycled heaps. Do not copy an owning pool.
/// The interface borrows this pool; keep its address stable until all heaps return.
pub const HeapPool = struct {
    parent: ResourceHeapAllocator,
    block_size_byte_count: u64,
    recycled_heaps: []*Heap,
    recycled_heap_count: usize = 0,
    outstanding_heap_count: usize = 0,

    pub const Options = struct {
        block_size_byte_count: u64,
        max_recycled_heap_count: usize,
    };
    pub const InitError = std.mem.Allocator.Error || error{BlockSizeIsZero};
    pub const DeinitError = error{ OutstandingHeaps, RecycledHeapsRemain };
    pub const AllocateError = heap_allocator.AllocateError;

    const vtable: heap_allocator.VTable = .{
        .allocateResourceHeap = allocateCallback,
        .deallocateResourceHeap = deallocateCallback,
    };

    /// Reserves bounded recycling storage. The parent context must outlive the pool.
    pub fn init(
        allocator: std.mem.Allocator,
        parent: ResourceHeapAllocator,
        options: Options,
    ) InitError!HeapPool {
        if (options.block_size_byte_count == 0) return error.BlockSizeIsZero;
        return .{
            .parent = parent,
            .block_size_byte_count = options.block_size_byte_count,
            .recycled_heaps = try allocator.alloc(*Heap, options.max_recycled_heap_count),
        };
    }

    /// Rejects live or recycled heaps without mutation. Success invalidates this value.
    /// Use the allocator supplied to `init`. Call this once after `releaseRecycled`.
    pub fn deinit(self: *HeapPool, allocator: std.mem.Allocator) DeinitError!void {
        if (self.outstanding_heap_count != 0) return error.OutstandingHeaps;
        if (self.recycled_heap_count != 0) return error.RecycledHeapsRemain;
        allocator.free(self.recycled_heaps);
        self.* = undefined;
    }

    /// Returns an interface borrowing this pool until its final heap return.
    pub fn asResourceHeapAllocator(self: *HeapPool) ResourceHeapAllocator {
        return ResourceHeapAllocator.init(self, &vtable);
    }

    /// Transfers one exact-size heap to the caller. Return it through this pool.
    /// Errors leave ownership and counts unchanged, including errors from the parent.
    pub fn allocateResourceHeap(
        allocator: std.mem.Allocator,
        self: *HeapPool,
        size_byte_count: u64,
    ) AllocateError!*Heap {
        if (size_byte_count != self.block_size_byte_count) return error.HeapSizeMismatch;
        const heap = if (self.recycled_heap_count != 0) recycled: {
            self.recycled_heap_count -= 1;
            break :recycled self.recycled_heaps[self.recycled_heap_count];
        } else try self.parent.allocateResourceHeap(allocator, size_byte_count);
        if (heap.size_byte_count != self.block_size_byte_count) {
            self.parent.deallocateResourceHeap(heap);
            return error.HeapSizeMismatch;
        }
        self.outstanding_heap_count += 1;
        return heap;
    }

    /// Takes ownership without allocation. A full pool returns the heap to the parent.
    /// The heap must be a live result of this pool. Returning it twice is invalid.
    pub fn deallocateResourceHeap(self: *HeapPool, heap: *Heap) void {
        std.debug.assert(heap.size_byte_count == self.block_size_byte_count);
        std.debug.assert(self.outstanding_heap_count != 0);
        for (self.recycled_heaps[0..self.recycled_heap_count]) |recycled| {
            std.debug.assert(recycled != heap);
        }
        self.outstanding_heap_count -= 1;
        if (self.recycled_heap_count == self.recycled_heaps.len) {
            self.parent.deallocateResourceHeap(heap);
            return;
        }
        self.recycled_heaps[self.recycled_heap_count] = heap;
        self.recycled_heap_count += 1;
    }

    /// Returns every recycled heap to the parent. Outstanding heaps remain valid.
    pub fn releaseRecycled(self: *HeapPool) void {
        const count = self.recycled_heap_count;
        self.recycled_heap_count = 0;
        for (self.recycled_heaps[0..count]) |heap| {
            self.parent.deallocateResourceHeap(heap);
        }
    }

    /// Counts heaps retained for reuse, excluding outstanding heaps.
    pub fn recycledCount(self: *const HeapPool) usize {
        return self.recycled_heap_count;
    }

    fn allocateCallback(
        allocator: std.mem.Allocator,
        context: *anyopaque,
        size_byte_count: u64,
    ) AllocateError!*Heap {
        const self: *HeapPool = @ptrCast(@alignCast(context));
        return allocateResourceHeap(allocator, self, size_byte_count);
    }

    fn deallocateCallback(context: *anyopaque, heap: *Heap) void {
        const self: *HeapPool = @ptrCast(@alignCast(context));
        self.deallocateResourceHeap(heap);
    }
};

const TestParent = struct {
    allocated_count: usize = 0,
    released_count: usize = 0,
    const Owned = struct { heap: Heap, allocator: std.mem.Allocator };
    const vtable: heap_allocator.VTable = .{
        .allocateResourceHeap = allocate,
        .deallocateResourceHeap = release,
    };
    fn interface(self: *TestParent) ResourceHeapAllocator {
        return ResourceHeapAllocator.init(self, &vtable);
    }
    fn allocate(allocator: std.mem.Allocator, context: *anyopaque, size: u64) heap_allocator.AllocateError!*Heap {
        const self: *TestParent = @ptrCast(@alignCast(context));
        const owned = try allocator.create(Owned);
        owned.* = .{ .heap = .{
            .memory = null,
            .memory_type_index = 0,
            .size_byte_count = size,
        }, .allocator = allocator };
        self.allocated_count += 1;
        return &owned.heap;
    }
    fn release(context: *anyopaque, heap: *Heap) void {
        const self: *TestParent = @ptrCast(@alignCast(context));
        const owned: *Owned = @fieldParentPtr("heap", heap);
        const allocator = owned.allocator;
        self.released_count += 1;
        allocator.destroy(owned);
    }
};

test "pool reuses the newest pointer and returns overflow ownership to parent" {
    const allocator = std.testing.allocator;
    var parent: TestParent = .{};
    var pool = try HeapPool.init(allocator, parent.interface(), .{
        .block_size_byte_count = 64,
        .max_recycled_heap_count = 2,
    });
    const interface = pool.asResourceHeapAllocator();
    const first = try interface.allocateResourceHeap(allocator, 64);
    const second = try interface.allocateResourceHeap(allocator, 64);
    const overflow = try interface.allocateResourceHeap(allocator, 64);
    try std.testing.expectError(error.OutstandingHeaps, pool.deinit(allocator));
    interface.deallocateResourceHeap(first);
    interface.deallocateResourceHeap(second);
    interface.deallocateResourceHeap(overflow);
    try std.testing.expectEqual(@as(usize, 1), parent.released_count);
    try std.testing.expectEqual(@as(usize, 2), pool.recycledCount());
    try std.testing.expectError(error.HeapSizeMismatch, interface.allocateResourceHeap(allocator, 32));
    try std.testing.expectError(error.HeapSizeMismatch, interface.allocateResourceHeap(allocator, 128));
    try std.testing.expectEqual(@as(usize, 2), pool.recycledCount());
    const reused = try interface.allocateResourceHeap(allocator, 64);
    try std.testing.expectEqual(second, reused);
    try std.testing.expectEqual(@as(usize, 3), parent.allocated_count);
    interface.deallocateResourceHeap(reused);
    try std.testing.expectError(error.RecycledHeapsRemain, pool.deinit(allocator));
    pool.releaseRecycled();
    pool.releaseRecycled();
    try std.testing.expectEqual(@as(usize, 3), parent.released_count);
    try pool.deinit(allocator);
}

test "zero retention releases every heap and invalid pool size is rejected" {
    const allocator = std.testing.allocator;
    var parent: TestParent = .{};
    try std.testing.expectError(error.BlockSizeIsZero, HeapPool.init(
        allocator,
        parent.interface(),
        .{
            .block_size_byte_count = 0,
            .max_recycled_heap_count = 1,
        },
    ));
    var pool = try HeapPool.init(allocator, parent.interface(), .{
        .block_size_byte_count = 1,
        .max_recycled_heap_count = 0,
    });
    const heap = try HeapPool.allocateResourceHeap(allocator, &pool, 1);
    pool.deallocateResourceHeap(heap);
    try std.testing.expectEqual(@as(usize, 0), pool.recycledCount());
    try std.testing.expectEqual(@as(usize, 1), parent.released_count);
    try pool.deinit(allocator);
}

fn poolFailureExercise(allocator: std.mem.Allocator) !void {
    var parent: TestParent = .{};
    var pool = try HeapPool.init(allocator, parent.interface(), .{
        .block_size_byte_count = 32,
        .max_recycled_heap_count = 2,
    });
    defer {
        pool.releaseRecycled();
        pool.deinit(allocator) catch @panic("pool leaked checked-out heaps");
    }
    const heap = try HeapPool.allocateResourceHeap(allocator, &pool, 32);
    pool.deallocateResourceHeap(heap);
    var rejecting = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const reused = try HeapPool.allocateResourceHeap(rejecting.allocator(), &pool, 32);
    try std.testing.expectEqual(heap, reused);
    pool.deallocateResourceHeap(reused);
}

test "pool construction and parent miss sweep every host allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, poolFailureExercise, .{});
}
