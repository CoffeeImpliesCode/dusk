//! Buddy suballocation over parent-owned fixed-size heaps.
//! Allocate through BuddyMemoryAllocator, return each record once, then call `deinit`.
//! The parent supplies device memory. This module owns only heap slots and the offset tree.

const std = @import("std");
const alignment = @import("align.zig");
const BuddyAllocator = @import("buddy_allocator.zig").BuddyAllocator;
const Heap = @import("resource_heap.zig").Heap;
const heap_allocator = @import("resource_heap_allocator.zig");
const ResourceHeapAllocator = heap_allocator.ResourceHeapAllocator;
const ResourceMemoryAllocation = @import("resource_memory_allocation.zig").ResourceMemoryAllocation;

/// Slots own parent heaps; returned allocation records borrow them.
/// Do not copy this owning value. All operations require compatible allocators.
/// The parent context must outlive it and must not reenter it from a callback.
/// Records borrow slot heaps until deallocation. Copied records do not retain a reference.
pub const BuddyMemoryAllocator = struct {
    parent: ResourceHeapAllocator,
    memory_block_size_byte_count: u64,
    buddy_allocator: BuddyAllocator,
    heap_slots: []HeapSlot,

    /// One slot per memory block. A zero reference count has no owned heap.
    pub const HeapSlot = struct {
        ref_count: usize = 0,
        heap: ?*Heap = null,
    };
    pub const Options = struct {
        max_system_size_byte_count: u64,
        memory_block_size_byte_count: u64,
    };
    pub const AllocateOptions = struct {
        size_byte_count: u64,
        alignment_byte_count: u64,
        /// Defaults to ordinary memory. Set this when the parent memory type is lazy.
        is_lazy_allocated: bool = false,
    };
    pub const Error = error{
        SystemSizeNotPowerOfTwo,
        MemoryBlockSizeNotPowerOfTwo,
        MemoryBlockSizeExceedsSystemSize,
        SystemSizeNotDivisibleByMemoryBlockSize,
        SystemSizeExceedsAddressSpace,
        AllocationSizeExceedsMemoryBlockSize,
        NotSubAllocated,
        HeapRefcountUnderflow,
        UnknownAllocation,
    };
    pub const OperationError = Error || BuddyAllocator.OperationError ||
        heap_allocator.AllocateError;
    pub const DeinitError = error{LiveAllocationsRemain};

    /// Validates block/system powers and divisibility before allocating bookkeeping.
    pub fn init(
        allocator: std.mem.Allocator,
        parent: ResourceHeapAllocator,
        options: Options,
    ) OperationError!BuddyMemoryAllocator {
        const block_size = options.memory_block_size_byte_count;
        const system_size = options.max_system_size_byte_count;
        if (!alignment.isPowerOfTwo(block_size)) return error.MemoryBlockSizeNotPowerOfTwo;
        if (block_size > system_size) return error.MemoryBlockSizeExceedsSystemSize;
        if (system_size % block_size != 0) return error.SystemSizeNotDivisibleByMemoryBlockSize;
        if (!alignment.isPowerOfTwo(system_size)) return error.SystemSizeNotPowerOfTwo;
        const slot_count = std.math.cast(usize, @divExact(system_size, block_size)) orelse
            return error.SystemSizeExceedsAddressSpace;
        const slots = try allocator.alloc(HeapSlot, slot_count);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        return .{
            .parent = parent,
            .memory_block_size_byte_count = block_size,
            .buddy_allocator = try BuddyAllocator.init(allocator, system_size),
            .heap_slots = slots,
        };
    }

    /// Rejects live allocations without mutation. Success frees bookkeeping and invalidates self.
    /// Use the allocator supplied to `init`. Successful teardown must occur exactly once.
    pub fn deinit(self: *BuddyMemoryAllocator, allocator: std.mem.Allocator) DeinitError!void {
        if (self.liveHeapCount() != 0) return error.LiveAllocationsRemain;
        self.buddy_allocator.deinit(allocator);
        allocator.free(self.heap_slots);
        self.* = undefined;
    }

    /// Maps a valid global offset to its owning heap slot. Rejects offsets outside the system.
    pub fn memoryBlockIndex(self: *const BuddyMemoryAllocator, offset_byte_count: u64) Error!usize {
        if (offset_byte_count >= self.buddy_allocator.max_size_byte_count) {
            return error.UnknownAllocation;
        }
        return @intCast(@divFloor(offset_byte_count, self.memory_block_size_byte_count));
    }

    /// Returns a borrowed heap record with the original request size and heap-local offset.
    /// Parent or host allocation failure restores the reserved tree capacity.
    pub fn allocate(
        allocator: std.mem.Allocator,
        self: *BuddyMemoryAllocator,
        options: AllocateOptions,
    ) OperationError!ResourceMemoryAllocation {
        if (options.size_byte_count == 0) return error.AllocationSizeIsZero;
        if (options.size_byte_count > self.memory_block_size_byte_count) {
            return error.AllocationSizeExceedsMemoryBlockSize;
        }
        const rounded_size = alignment.nextPowerOfTwo(options.size_byte_count) catch
            return error.AllocationSizeExceedsMemoryBlockSize;
        if (rounded_size > self.memory_block_size_byte_count) {
            return error.AllocationSizeExceedsMemoryBlockSize;
        }
        const global_offset = try self.buddy_allocator.allocate(
            allocator,
            rounded_size,
            options.alignment_byte_count,
        );
        errdefer self.buddy_allocator.deallocate(allocator, global_offset) catch
            @panic("reserved buddy offset could not be rolled back");
        const index = try self.memoryBlockIndex(global_offset);
        const slot = &self.heap_slots[index];
        if (slot.ref_count == std.math.maxInt(usize)) return error.OutOfMemory;
        if (slot.ref_count == 0) {
            const heap = try self.parent.allocateResourceHeap(
                allocator,
                self.memory_block_size_byte_count,
            );
            if (heap.size_byte_count != self.memory_block_size_byte_count) {
                self.parent.deallocateResourceHeap(heap);
                return error.HeapSizeMismatch;
            }
            slot.heap = heap;
        }
        slot.ref_count += 1;
        return .{
            .info = .{
                .block_offset_byte_count = global_offset,
                .method = .sub_allocated,
                .requested_size_byte_count = options.size_byte_count,
                .is_lazy_allocated = options.is_lazy_allocated,
            },
            .offset_byte_count = global_offset % self.memory_block_size_byte_count,
            .resource_heap = slot.heap,
        };
    }

    /// Validates a record before returning its tree block and releasing the final heap reference.
    /// Success invalidates the supplied record. Rejected records leave ownership unchanged.
    /// Copies of freed records must not be reused, even when an offset is later allocated again.
    pub fn deallocate(
        self: *BuddyMemoryAllocator,
        allocator: std.mem.Allocator,
        allocation: *ResourceMemoryAllocation,
    ) OperationError!void {
        if (allocation.info.method != .sub_allocated) return error.NotSubAllocated;
        const global_offset = allocation.info.block_offset_byte_count;
        const slot = &self.heap_slots[try self.memoryBlockIndex(global_offset)];
        if (slot.ref_count == 0) return error.HeapRefcountUnderflow;
        if (slot.heap == null or slot.heap != allocation.resource_heap) {
            return error.UnknownAllocation;
        }
        if (allocation.offset_byte_count != global_offset % self.memory_block_size_byte_count) {
            return error.UnknownAllocation;
        }
        const requested_size = allocation.info.requested_size_byte_count;
        if (requested_size == 0 or requested_size > self.memory_block_size_byte_count) {
            return error.UnknownAllocation;
        }
        const rounded_size = alignment.nextPowerOfTwo(requested_size) catch
            return error.UnknownAllocation;
        if (!self.matchesAllocatedBlock(global_offset, rounded_size)) {
            return error.UnknownAllocation;
        }

        // A rejected tree return must leave both heap ownership and the record intact.
        try self.buddy_allocator.deallocate(allocator, global_offset);
        slot.ref_count -= 1;
        if (slot.ref_count == 0) {
            const heap = slot.heap.?;
            slot.heap = null;
            self.parent.deallocateResourceHeap(heap);
        }
        allocation.invalidate();
    }

    /// Counts slots with at least one live allocation.
    pub fn liveHeapCount(self: *const BuddyMemoryAllocator) usize {
        var count: usize = 0;
        for (self.heap_slots) |slot| {
            if (slot.ref_count != 0) count += 1;
        }
        return count;
    }

    fn matchesAllocatedBlock(
        self: *const BuddyMemoryAllocator,
        offset_byte_count: u64,
        rounded_size_byte_count: u64,
    ) bool {
        var node = self.buddy_allocator.root orelse return false;
        for (0..self.buddy_allocator.depthBound() + 1) |_| {
            if (node.state != .split) {
                return node.state == .allocated and
                    node.offset_byte_count == offset_byte_count and
                    node.size_byte_count == rounded_size_byte_count;
            }
            const left = node.left orelse return false;
            const right = left.buddy orelse return false;
            node = if (offset_byte_count < right.offset_byte_count) left else right;
        }
        return false;
    }
};

const TestParent = struct {
    allocation_count: usize = 0,
    release_count: usize = 0,
    fail_error: ?heap_allocator.Error = null,
    wrong_size: bool = false,
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
        if (self.fail_error) |err| return err;
        const owned = try allocator.create(Owned);
        owned.* = .{ .heap = .{
            .memory = null,
            .memory_type_index = 7,
            .size_byte_count = if (self.wrong_size) size - 1 else size,
        }, .allocator = allocator };
        self.allocation_count += 1;
        return &owned.heap;
    }
    fn release(context: *anyopaque, heap: *Heap) void {
        const self: *TestParent = @ptrCast(@alignCast(context));
        const owned: *Owned = @fieldParentPtr("heap", heap);
        const allocator = owned.allocator;
        self.release_count += 1;
        allocator.destroy(owned);
    }
};

test "buddy heaps share references and retain requested size with two offset domains" {
    const allocator = std.testing.allocator;
    var parent: TestParent = .{};
    var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
        .max_system_size_byte_count = 128,
        .memory_block_size_byte_count = 64,
    });
    var first = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 17,
        .alignment_byte_count = 16,
        .is_lazy_allocated = true,
    });
    var second = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 32,
        .alignment_byte_count = 32,
    });
    var third = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 64,
        .alignment_byte_count = 64,
    });
    try std.testing.expectEqual(@as(u64, 17), first.info.requested_size_byte_count);
    try std.testing.expect(first.info.is_lazy_allocated);
    try std.testing.expectEqual(first.resource_heap, second.resource_heap);
    try std.testing.expectEqual(@as(usize, 2), memory.liveHeapCount());
    try std.testing.expectEqual(@as(usize, 2), memory.heap_slots[0].ref_count);
    try std.testing.expectEqual(@as(u64, 32), second.info.block_offset_byte_count);
    try std.testing.expectEqual(@as(u64, 32), second.offset_byte_count);
    try std.testing.expectEqual(@as(u64, 64), third.info.block_offset_byte_count);
    try std.testing.expectEqual(@as(u64, 0), third.offset_byte_count);
    try std.testing.expectEqual(@as(usize, 1), try memory.memoryBlockIndex(64));
    try std.testing.expectError(error.OutOfSpace, BuddyMemoryAllocator.allocate(
        allocator,
        &memory,
        .{ .size_byte_count = 1, .alignment_byte_count = 1 },
    ));
    try std.testing.expectError(error.LiveAllocationsRemain, memory.deinit(allocator));
    try memory.deallocate(allocator, &first);
    try std.testing.expectEqual(@as(usize, 0), parent.release_count);
    try std.testing.expect(first.info.method == .invalid);
    try memory.deallocate(allocator, &second);
    try std.testing.expectEqual(@as(usize, 1), parent.release_count);
    try memory.deallocate(allocator, &third);
    try std.testing.expectEqual(@as(usize, 2), parent.release_count);
    try std.testing.expectEqual(@as(usize, 0), memory.liveHeapCount());
    try memory.deinit(allocator);
}

test "invalid allocation records and double frees leave reference counts intact" {
    const allocator = std.testing.allocator;
    var parent: TestParent = .{};
    var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
        .max_system_size_byte_count = 64,
        .memory_block_size_byte_count = 64,
    });
    var first = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 8,
        .alignment_byte_count = 1,
    });
    var second = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 8,
        .alignment_byte_count = 1,
    });
    var stale = first;
    var invalid = first;
    invalid.info.method = .direct;
    try std.testing.expectError(error.NotSubAllocated, memory.deallocate(allocator, &invalid));
    invalid = first;
    invalid.info.block_offset_byte_count = 1;
    invalid.offset_byte_count = 1;
    try std.testing.expectError(error.UnknownAllocation, memory.deallocate(allocator, &invalid));
    invalid = first;
    invalid.offset_byte_count = 1;
    try std.testing.expectError(error.UnknownAllocation, memory.deallocate(allocator, &invalid));
    invalid = first;
    invalid.resource_heap = null;
    try std.testing.expectError(error.UnknownAllocation, memory.deallocate(allocator, &invalid));
    invalid = first;
    invalid.info.requested_size_byte_count = 16;
    try std.testing.expectError(error.UnknownAllocation, memory.deallocate(allocator, &invalid));
    try std.testing.expectEqual(@as(usize, 2), memory.heap_slots[0].ref_count);
    try memory.deallocate(allocator, &first);
    try std.testing.expectError(error.UnknownAllocation, memory.deallocate(allocator, &stale));
    try std.testing.expectError(error.NotSubAllocated, memory.deallocate(allocator, &first));
    try std.testing.expectEqual(@as(usize, 1), memory.heap_slots[0].ref_count);
    try memory.deallocate(allocator, &second);
    try std.testing.expectError(error.HeapRefcountUnderflow, memory.deallocate(allocator, &stale));
    try memory.deinit(allocator);
}

test "constructor and request invariants have distinct failures" {
    const allocator = std.testing.allocator;
    var parent: TestParent = .{};
    const Case = struct { system: u64, block: u64, err: BuddyMemoryAllocator.Error };
    const cases = [_]Case{
        .{ .system = 64, .block = 0, .err = error.MemoryBlockSizeNotPowerOfTwo },
        .{ .system = 64, .block = 3, .err = error.MemoryBlockSizeNotPowerOfTwo },
        .{ .system = 64, .block = 128, .err = error.MemoryBlockSizeExceedsSystemSize },
        .{ .system = 96, .block = 64, .err = error.SystemSizeNotDivisibleByMemoryBlockSize },
        .{ .system = 96, .block = 32, .err = error.SystemSizeNotPowerOfTwo },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, BuddyMemoryAllocator.init(
            allocator,
            parent.interface(),
            .{
                .max_system_size_byte_count = case.system,
                .memory_block_size_byte_count = case.block,
            },
        ));
    }
    var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
        .max_system_size_byte_count = 64,
        .memory_block_size_byte_count = 32,
    });
    defer memory.deinit(allocator) catch @panic("unexpected live allocations");
    try std.testing.expectError(error.AllocationSizeIsZero, BuddyMemoryAllocator.allocate(
        allocator,
        &memory,
        .{ .size_byte_count = 0, .alignment_byte_count = 1 },
    ));
    try std.testing.expectError(
        error.AllocationSizeExceedsMemoryBlockSize,
        BuddyMemoryAllocator.allocate(allocator, &memory, .{
            .size_byte_count = std.math.maxInt(u64),
            .alignment_byte_count = 1,
        }),
    );
    try std.testing.expectError(error.AlignmentNotPowerOfTwo, BuddyMemoryAllocator.allocate(
        allocator,
        &memory,
        .{ .size_byte_count = 1, .alignment_byte_count = 3 },
    ));
    try std.testing.expectError(error.UnknownAllocation, memory.memoryBlockIndex(64));
}

test "every parent error rolls reserved offsets back before retry" {
    const allocator = std.testing.allocator;
    inline for (@typeInfo(heap_allocator.Error).error_set.error_names.?) |member_name| {
        var parent: TestParent = .{ .fail_error = @field(heap_allocator.Error, member_name) };
        var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
            .max_system_size_byte_count = 64,
            .memory_block_size_byte_count = 64,
        });
        try std.testing.expectError(parent.fail_error.?, BuddyMemoryAllocator.allocate(
            allocator,
            &memory,
            .{ .size_byte_count = 3, .alignment_byte_count = 1 },
        ));
        try std.testing.expectEqual(@as(usize, 0), memory.liveHeapCount());
        try std.testing.expectEqual(@as(usize, 1), memory.buddy_allocator.totalFreeBlockCount());
        parent.fail_error = null;
        var allocation = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
            .size_byte_count = 64,
            .alignment_byte_count = 64,
        });
        try std.testing.expectEqual(@as(u64, 0), allocation.info.block_offset_byte_count);
        try memory.deallocate(allocator, &allocation);
        try memory.deinit(allocator);
    }
}

fn memoryFailureExercise(allocator: std.mem.Allocator) !void {
    var parent: TestParent = .{};
    var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
        .max_system_size_byte_count = 128,
        .memory_block_size_byte_count = 64,
    });
    defer memory.deinit(allocator) catch @panic("unexpected live allocations");
    var first = BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 3,
        .alignment_byte_count = 4,
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), memory.liveHeapCount());
        try std.testing.expectEqual(@as(usize, 1), memory.buddy_allocator.totalFreeBlockCount());
        return err;
    };
    defer memory.deallocate(allocator, &first) catch @panic("invalid first allocation");
    var second = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 32,
        .alignment_byte_count = 32,
    });
    defer memory.deallocate(allocator, &second) catch @panic("invalid second allocation");
    var third = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
        .size_byte_count = 64,
        .alignment_byte_count = 64,
    });
    defer memory.deallocate(allocator, &third) catch @panic("invalid third allocation");
}

test "buddy memory sweeps initialization splits and parent heap host failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, memoryFailureExercise, .{});
}

test "incorrect parent heap size returns ownership and restores full capacity" {
    const allocator = std.testing.allocator;
    var parent: TestParent = .{ .wrong_size = true };
    var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
        .max_system_size_byte_count = 64,
        .memory_block_size_byte_count = 64,
    });
    try std.testing.expectError(error.HeapSizeMismatch, BuddyMemoryAllocator.allocate(
        allocator,
        &memory,
        .{ .size_byte_count = 1, .alignment_byte_count = 1 },
    ));
    try std.testing.expectEqual(@as(usize, 1), parent.release_count);
    try std.testing.expectEqual(@as(usize, 1), memory.buddy_allocator.totalFreeBlockCount());
    try memory.deinit(allocator);
}

test "host allocation failures preserve existing heap references and allow retry" {
    const allocator = std.testing.allocator;
    for (0..10) |fail_index| {
        var parent: TestParent = .{};
        var memory = try BuddyMemoryAllocator.init(allocator, parent.interface(), .{
            .max_system_size_byte_count = 128,
            .memory_block_size_byte_count = 64,
        });
        var existing = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
            .size_byte_count = 64,
            .alignment_byte_count = 64,
        });
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const result = BuddyMemoryAllocator.allocate(failing.allocator(), &memory, .{
            .size_byte_count = 3,
            .alignment_byte_count = 4,
        });
        if (result) |value| {
            var allocation = value;
            try memory.deallocate(failing.allocator(), &allocation);
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expectEqual(@as(usize, 1), memory.liveHeapCount());
            try std.testing.expectEqual(@as(usize, 1), memory.heap_slots[0].ref_count);
            var retry = try BuddyMemoryAllocator.allocate(allocator, &memory, .{
                .size_byte_count = 64,
                .alignment_byte_count = 64,
            });
            try std.testing.expectEqual(@as(u64, 64), retry.info.block_offset_byte_count);
            try memory.deallocate(allocator, &retry);
        }
        try memory.deallocate(allocator, &existing);
        try std.testing.expectEqual(parent.allocation_count, parent.release_count);
        try memory.deinit(allocator);
    }
}

test "slot table rejects a count outside the host address space" {
    if (@bitSizeOf(usize) < 64) {
        var parent: TestParent = .{};
        try std.testing.expectError(
            error.SystemSizeExceedsAddressSpace,
            BuddyMemoryAllocator.init(std.testing.allocator, parent.interface(), .{
                .max_system_size_byte_count = @as(u64, 1) << 63,
                .memory_block_size_byte_count = 1,
            }),
        );
    }
}
