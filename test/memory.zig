//! M6 acceptance: the buddy offset tree, the serial-released size tracker, the
//! allocation record, the heap-allocator seam and the VMA declaration binding.
//!
//! **What this shard claims.** One hundred thousand allocate-and-free cycles
//! with sizes drawn from a fixed-seed PRNG between 64 B and 4 MiB. Every cycle
//! asserts that the tracked byte count is back where the cycle found it, and
//! every allocation asserts that no two live allocations share an offset and
//! that no two live ranges overlap. The nine `BuddyAllocatorTests.cpp` fixtures
//! keep their exact offsets, because the offset tree stays in Zig
//! (`docs/40-plan.md` §M6) and the offsets are the contract.
//!
//! **What this shard does not claim.** It claims nothing about a device, a
//! `VkDeviceMemory` or a mapping. The buddy tree and the size tracker are pure:
//! the tree carves offsets out of one region and the tracker counts bytes that a
//! serial releases. Neither needs a device, and neither is given one.
//!
//! **VMA needs a device and is asserted separately.** Every entry point
//! `src/memory/vma.zig` declares needs a `VkDevice`, and the test calls none of
//! them: the C++ half of `vk_mem_alloc.h` is behind `#ifdef VMA_IMPLEMENTATION`
//! (`vk_mem_alloc.h:3039`), so a translation of the header yields declarations
//! with no definition anywhere in the closure and `AGENTS.md` §1 forbids
//! compiling one. Its own test therefore asserts the declaration half — the tag
//! numbering and the struct layout — and names the gap.
//!
//! **The library is reached through `@import("dusk")`**, like every other
//! acceptance shard.

const std = @import("std");
const dusk = @import("dusk");

const memory = dusk.memory;
const alignment = memory.alignment;
const buddy_allocator = memory.buddy_allocator;
const resource_heap = memory.resource_heap;
const resource_heap_allocator = memory.resource_heap_allocator;
const allocation_record = memory.resource_memory_allocation;
const size_tracker = memory.size_tracker;

/// `SizeTracker` threads `io` before `self` in every operation it declares
/// (`src/memory/size_tracker.zig:90`), so Zig builds no member function for any
/// of them and every call below is qualified through the type name
/// (`src/engine/queue.zig:591`, `test/buffer.zig:293`). Naming the type once
/// keeps those qualified calls inside `AGENTS.md` §2's column bound.
const SizeTracker = size_tracker.SizeTracker;
const vma = memory.vma;

/// The cycle count §M6 names, verbatim.
const cycle_count = 100_000;

/// The seed. `AGENTS.md` §3, "inject the seed": the run must be the same run on
/// every machine, and a failure must be reproducible from this one number.
const prng_seed: u64 = 0xD0C5_40A6_2026_0001;

/// The small end of the acceptance size range.
const min_request_byte_count: u64 = 64;

/// The large end of the acceptance size range.
const max_request_byte_count: u64 = 4 * 1024 * 1024;

/// The region the tree covers. It has to be a power of two
/// (`BuddyAllocator.cpp:37`) and at least as large as the largest request,
/// because a request the region cannot hold is
/// `AllocationSizeExceedsMaximumSize` (`.cpp:156-158`) and not a run-time
/// condition this cycle test would have to handle.
const region_byte_count: u64 = max_request_byte_count;

/// The alignment every cycle asks for. A buddy block is always aligned to its
/// own size, and every request here is at least 64 B, so a 64 B alignment is
/// satisfiable from any free block. That is deliberate: it keeps the cycle test
/// measuring offsets rather than the head-only alignment search, which
/// `BuddyAllocatorTests.cpp:278` pins on its own.
const request_alignment_byte_count: u64 = 64;

/// The bound on the live window, and therefore on the eviction loop and on the
/// pairwise overlap scan. Eight blocks is enough that a cycle regularly runs
/// out of room and has to free, which is the state the tree is interesting in.
const live_window_capacity = 8;

/// How many cycles run between full drains. A full drain is the only point at
/// which "the tree came back whole" is a statement about the region rather than
/// about one cycle, so it is cheap and periodic rather than every cycle.
const drain_period = 1_000;

/// SplitMix64.
///
/// The sequence is written out here rather than taken from `std.Random` so the
/// run is the same run under any standard-library version. That is the whole
/// point of injecting a seed: a failure has to be reproducible from the seed
/// alone, and a library-internal generator makes the sequence a property of the
/// compiler.
const Prng = struct {
    state: u64,

    /// The SplitMix64 increment, `0x9E3779B97F4A7C15`.
    const increment: u64 = 0x9E37_79B9_7F4A_7C15;

    fn init(seed: u64) Prng {
        return .{ .state = seed };
    }

    fn next(self: *Prng) u64 {
        self.state +%= increment;
        var mixed = self.state;
        mixed = (mixed ^ (mixed >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        mixed = (mixed ^ (mixed >> 27)) *% 0x94D0_49BB_1331_11EB;
        return mixed ^ (mixed >> 31);
    }

    /// A value in `low ..= high`. The modulo bias is at most 2^-59 over the
    /// 64-bit range and is irrelevant next to the property under test; what
    /// matters is that the draw is a pure function of the state.
    fn inRange(self: *Prng, low: u64, high: u64) u64 {
        std.debug.assert(low <= high);
        return low + (self.next() % (high - low + 1));
    }
};

/// One live allocation: where the tree put it, how much of the region it holds,
/// and what the tracker counts for it. The three are different numbers and the
/// test keeps them apart, because upstream does too: the record keeps the
/// pre-rounding request (`BuddyMemoryAllocator.cpp:99`) while the tree carves a
/// power-of-two block.
const Live = struct {
    offset_byte_count: u64,
    block_size_byte_count: u64,
    requested_byte_count: u64,

    fn endByteCount(self: Live) u64 {
        return self.offset_byte_count + self.block_size_byte_count;
    }

    /// True when two blocks share at least one byte.
    fn overlaps(self: Live, other: Live) bool {
        return self.offset_byte_count < other.endByteCount() and
            other.offset_byte_count < self.endByteCount();
    }
};

/// What the tracker must report for a live set: the sum of the requests, not the
/// sum of the blocks. `SizeTracker` counts what WebGPU asked for, and the
/// pre-rounding size is the value upstream keeps.
fn sumRequestedByteCount(live: []const Live) u64 {
    var total: u64 = 0;
    for (live) |entry| total += entry.requested_byte_count;
    return total;
}

/// Whether the tree can serve a block of `block_size_byte_count` at the
/// acceptance's alignment right now.
///
/// The tree's own admission predicate, not the free byte count: a buddy tree
/// merges adjacent free blocks, so it can hold `block_size_byte_count` free
/// bytes in blocks that are each too small to serve the request, and a bound on
/// the sum would call the window big enough when it is not.
fn treeCanServe(tree: *buddy_allocator.BuddyAllocator, block_size_byte_count: u64) !bool {
    const request_level = try tree.levelFromBlockSize(block_size_byte_count);
    return try tree.findFreeBlockLevel(request_level, request_alignment_byte_count) != null;
}

/// Frees one live allocation and records the release against `at_serial`.
///
/// The decrement is a record, not a subtraction (`src/memory/size_tracker.zig`
/// on `Decrement`), so the block goes back to the tree now and the byte count
/// falls when that serial drains. Splitting the two is the whole asymmetry the
/// tracker exists for.
fn releaseLive(
    allocator: std.mem.Allocator,
    io: std.Io,
    tree: *buddy_allocator.BuddyAllocator,
    tracker: *size_tracker.SizeTracker,
    entry: Live,
    at_serial: u64,
) !void {
    try tree.deallocate(allocator, entry.offset_byte_count);
    // `SizeTracker.decrement` is declared `allocator`-first, so Zig does not
    // treat it as a member function and `tracker.decrement` would bind the
    // allocator to the tracker. The qualified call is what puts each argument
    // in the parameter the signature names (`src/memory/size_tracker.zig:101`).
    try SizeTracker.decrement(allocator, io, tracker, at_serial, entry.requested_byte_count);
}

/// Everything the acceptance says about a live set, in one place so the cycle
/// test never grows a second copy of the rule.
fn expectLiveSetIsSound(live: []const Live) !void {
    for (live, 0..) |left, left_index| {
        // Inside the region, and on the alignment the request named. The
        // alignment is tested at `BuddyAllocator.cpp:103` and the offset comes
        // back at `:217`.
        try std.testing.expect(
            left.offset_byte_count % request_alignment_byte_count == 0,
        );
        try std.testing.expect(left.endByteCount() <= region_byte_count);

        var right_index = left_index + 1;
        while (right_index < live.len) : (right_index += 1) {
            const right = live[right_index];

            // The acceptance sentence: no two live allocations share an offset.
            try std.testing.expect(left.offset_byte_count != right.offset_byte_count);

            // The stronger form, and the one the sentence has to mean. Two live
            // blocks at the same offset with different sizes pass the sentence
            // above and hand back overlapping memory, which is the defect the
            // sentence exists to catch.
            try std.testing.expect(!left.overlaps(right));
        }
    }
}

// ---------------------------------------------------------------------------
// The acceptance: one hundred thousand cycles.
// ---------------------------------------------------------------------------

test "test-memory" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tree = try buddy_allocator.BuddyAllocator.init(
        std.testing.allocator,
        region_byte_count,
    );
    defer tree.deinit(std.testing.allocator);

    var tracker = SizeTracker.init();
    defer tracker.deinit(std.testing.allocator);

    // The value the acceptance calls "its starting value". It is read back
    // rather than hard-coded, so the property under test is "a cycle changes
    // nothing" and not "zero is the right number".
    const starting_byte_count = try SizeTracker.getSize(io, &tracker);
    try std.testing.expectEqual(@as(u64, 0), starting_byte_count);

    // A fresh region is one free block, so "the tree came back" has a value to
    // be compared against later.
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    var prng = Prng.init(prng_seed);
    var live: [live_window_capacity]Live = undefined;
    var live_count: usize = 0;
    var live_block_byte_count: u64 = 0;

    // Bytes this cycle released and its serial has not drained yet. A decrement
    // is a record against a serial (`PooledResourceMemoryAllocator.cpp:84-88`),
    // so the tracker still counts them until the cycle's drain.
    var banked_release_byte_count: u64 = 0;

    var cycle: usize = 0;
    while (cycle < cycle_count) : (cycle += 1) {
        const cycle_serial: u64 = @intCast(cycle);

        // Where this cycle has to end up. Read at the top of the cycle, because
        // the window can carry allocations across a cycle boundary and the
        // count is then not the global baseline.
        const cycle_start_byte_count = try SizeTracker.getSize(io, &tracker);
        const cycle_start_live_count = live_count;

        const want_count: usize = @intCast(prng.inRange(1, live_window_capacity));
        var made: usize = 0;
        while (made < want_count) : (made += 1) {
            const requested_byte_count =
                prng.inRange(min_request_byte_count, max_request_byte_count);
            const block_size_byte_count = try alignment.nextPowerOfTwo(requested_byte_count);

            // Free from the front of the window until the tree says it can serve
            // the request. Draining the window is the terminal case, and a whole
            // tree serves every request the region holds, so the allocation
            // below cannot fail for want of room. A request the region cannot
            // hold at all is the negative space and has its own test.
            while (live_count > 0 and !try treeCanServe(&tree, block_size_byte_count)) {
                const evicted = live[0];
                try releaseLive(
                    std.testing.allocator,
                    io,
                    &tree,
                    &tracker,
                    evicted,
                    cycle_serial,
                );
                banked_release_byte_count += evicted.requested_byte_count;
                live_block_byte_count -= evicted.block_size_byte_count;
                live_count -= 1;
                // The window shifts left by one, so the two ranges share
                // indices 1..live_count. `@memcpy` is undefined on an overlap;
                // `@memmove` is the forward copy the loop has always meant.
                @memmove(live[0..live_count], live[1 .. live_count + 1]);
            }

            const offset_byte_count = try tree.allocate(
                std.testing.allocator,
                block_size_byte_count,
                request_alignment_byte_count,
            );

            live[live_count] = .{
                .offset_byte_count = offset_byte_count,
                .block_size_byte_count = block_size_byte_count,
                .requested_byte_count = requested_byte_count,
            };
            live_count += 1;
            live_block_byte_count += block_size_byte_count;
            try SizeTracker.increment(io, &tracker, requested_byte_count);

            try expectLiveSetIsSound(live[0..live_count]);
            // A decrement records the size against `cycle_serial` and the drain
            // is at the end of the cycle, so mid-cycle the tracker still counts
            // what this cycle evicted. The banked bytes are part of what the
            // tracker owes, so the sum carries them: a tracker that subtracted
            // on the spot would leave them uncounted and fail this row, and a
            // tracker that dropped them early fails it the other way.
            try std.testing.expectEqual(
                sumRequestedByteCount(live[0..live_count]) + banked_release_byte_count,
                try SizeTracker.getSize(io, &tracker),
            );
        }

        // Release what this cycle made and the eviction above did not take,
        // newest first, so the merge loop at `BuddyAllocator.cpp:245-265` walks
        // the full height of the tree. The bound is the entries this cycle added
        // that are still live rather than the count it made: an eviction shifts
        // the window left and carries the entries it released away with it, so
        // the last `made` entries are not this cycle's once one has run.
        while (live_count > cycle_start_live_count) {
            live_count -= 1;
            const entry = live[live_count];
            try releaseLive(
                std.testing.allocator,
                io,
                &tree,
                &tracker,
                entry,
                cycle_serial,
            );
            banked_release_byte_count += entry.requested_byte_count;
            live_block_byte_count -= entry.block_size_byte_count;
        }

        // The bytes this cycle took are released when its serial drains, and the
        // count is back where the cycle found it. The drain is inclusive of its
        // serial (`SizeTracker.updateCompletedSerialTo` on
        // `PooledResourceMemoryAllocator.cpp:90-96`), which is what makes the
        // same serial on both sides correct.
        try SizeTracker.updateCompletedSerialTo(
            std.testing.allocator,
            io,
            &tracker,
            cycle_serial,
        );
        banked_release_byte_count = 0;
        try std.testing.expectEqual(cycle_start_byte_count, try SizeTracker.getSize(io, &tracker));
        try std.testing.expectEqual(@as(usize, 0), try SizeTracker.pendingCount(io, &tracker));

        // Every `drain_period` cycles the carried-over allocations are released
        // too, which is the only point where the whole region is asserted
        // rather than one cycle.
        if (cycle % drain_period == 0) {
            var drained: usize = 0;
            while (drained < live_count) : (drained += 1) {
                live_count -= 1;
                const entry = live[live_count];
                try releaseLive(
                    std.testing.allocator,
                    io,
                    &tree,
                    &tracker,
                    entry,
                    cycle_serial,
                );
                banked_release_byte_count += entry.requested_byte_count;
                live_block_byte_count -= entry.block_size_byte_count;
            }

            try SizeTracker.updateCompletedSerialTo(
                std.testing.allocator,
                io,
                &tracker,
                cycle_serial,
            );
            try std.testing.expectEqual(
                starting_byte_count,
                try SizeTracker.getSize(io, &tracker),
            );
            try std.testing.expectEqual(@as(usize, 0), live_count);
            try std.testing.expectEqual(@as(u64, 0), live_block_byte_count);
            try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
        }
    }

    // The bound was reached. A loop that never entered passes every assertion
    // above, so the count is checked.
    try std.testing.expectEqual(cycle, cycle_count);
    try std.testing.expectEqual(starting_byte_count, try SizeTracker.getSize(io, &tracker));
}

// ---------------------------------------------------------------------------
// The second acceptance: a simulated device loss.
// ---------------------------------------------------------------------------

/// The records one device holds when its queue goes away.
const loss_record_count: usize = 8;

/// Each record's block size, chosen so the eight blocks tile the front of the
/// region exactly and every free releases a merge.
const loss_block_byte_count: u64 = 8 * 1024;

test "a simulated device loss releases every byte and leaves every record resolvable" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tree = try buddy_allocator.BuddyAllocator.init(
        std.testing.allocator,
        region_byte_count,
    );
    defer tree.deinit(std.testing.allocator);

    var tracker = SizeTracker.init();
    defer tracker.deinit(std.testing.allocator);

    // A heap with no device memory behind it. `Heap.memory` is a handle value
    // and `null` is a legal one (`src/memory/resource_heap.zig:34-36`), so the
    // whole allocation layer runs without a driver.
    const heap = try std.testing.allocator.create(resource_heap.Heap);
    defer std.testing.allocator.destroy(heap);
    heap.* = .{
        .memory = null,
        .memory_type_index = 0,
        .size_byte_count = region_byte_count,
    };

    var records: [loss_record_count]allocation_record.ResourceMemoryAllocation = undefined;
    var offsets: [loss_record_count]u64 = undefined;

    var index: usize = 0;
    while (index < loss_record_count) : (index += 1) {
        const offset_byte_count = try tree.allocate(
            std.testing.allocator,
            loss_block_byte_count,
            loss_block_byte_count,
        );
        offsets[index] = offset_byte_count;
        records[index] = allocation_record.ResourceMemoryAllocation.init(
            .{
                .block_offset_byte_count = offset_byte_count,
                .method = .sub_allocated,
                .requested_size_byte_count = loss_block_byte_count,
                .is_lazy_allocated = false,
            },
            offset_byte_count,
            heap,
            &.{},
        );
        try SizeTracker.increment(io, &tracker, loss_block_byte_count);
    }

    // The first half of the records are freed at a serial the GPU has passed.
    // The second half are freed at a serial it has not, so they are still
    // counted. That is the state a device is in when its queue goes away: some
    // releases are banked and some are still in flight.
    index = 0;
    while (index < loss_record_count / 2) : (index += 1) {
        try SizeTracker.decrement(std.testing.allocator, io, &tracker, 1, loss_block_byte_count);
    }
    try SizeTracker.updateCompletedSerialTo(std.testing.allocator, io, &tracker, 1);
    try std.testing.expectEqual(
        @as(u64, loss_record_count / 2) * loss_block_byte_count,
        try SizeTracker.getSize(io, &tracker),
    );
    try std.testing.expectEqual(@as(usize, 0), try SizeTracker.pendingCount(io, &tracker));

    index = loss_record_count / 2;
    while (index < loss_record_count) : (index += 1) {
        try SizeTracker.decrement(std.testing.allocator, io, &tracker, 2, loss_block_byte_count);
    }

    const free_block_count_before_loss = tree.totalFreeBlockCount();

    // Device loss. `AssumeCommandsComplete`
    // (`PooledResourceMemoryAllocator.cpp:98-104`) drains every pending
    // decrement, because no serial will ever complete.
    try SizeTracker.assumeCommandsComplete(std.testing.allocator, io, &tracker);
    try std.testing.expectEqual(@as(u64, 0), try SizeTracker.getSize(io, &tracker));
    try std.testing.expectEqual(@as(usize, 0), try SizeTracker.pendingCount(io, &tracker));

    // The loss moved bytes, not blocks. The tree is unchanged, which is the
    // property that makes the records below still meaningful.
    try std.testing.expectEqual(free_block_count_before_loss, tree.totalFreeBlockCount());

    // Every live record still resolves inside the arena: the same offset, the
    // same heap, and a range that is still inside the region and still disjoint
    // from every other record's.
    index = 0;
    while (index < loss_record_count) : (index += 1) {
        try std.testing.expectEqual(offsets[index], try records[index].getOffset());
        try std.testing.expect(try records[index].getResourceHeap() == heap);
        try std.testing.expectEqual(
            allocation_record.AllocationMethod.sub_allocated,
            records[index].getInfo().method,
        );

        const entry: Live = .{
            .offset_byte_count = try records[index].getOffset(),
            .block_size_byte_count = loss_block_byte_count,
            .requested_byte_count = loss_block_byte_count,
        };
        try std.testing.expect(entry.offset_byte_count % loss_block_byte_count == 0);
        try std.testing.expect(entry.endByteCount() <= region_byte_count);

        var other_index = index + 1;
        while (other_index < loss_record_count) : (other_index += 1) {
            const other: Live = .{
                .offset_byte_count = offsets[other_index],
                .block_size_byte_count = loss_block_byte_count,
                .requested_byte_count = loss_block_byte_count,
            };
            try std.testing.expect(!entry.overlaps(other));
        }
    }

    // A tick after the loss moves nothing: the decrements are already gone.
    try SizeTracker.updateCompletedSerialTo(std.testing.allocator, io, &tracker, 3);
    try std.testing.expectEqual(@as(u64, 0), try SizeTracker.getSize(io, &tracker));

    // The tree still owns the blocks, so the records can be handed back.
    index = 0;
    while (index < loss_record_count) : (index += 1) {
        try tree.deallocate(std.testing.allocator, offsets[index]);
        records[index].invalidate();
    }
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    // Upstream calls `Invalidate` twice on one record
    // (`ResourceMemoryAllocatorVk.cpp:283` then `:312`), so the second call has
    // to be a no-op and the guarded accessors have to refuse what is left.
    records[0].invalidate();
    try std.testing.expect(records[0].isInvalid());
    try std.testing.expectError(error.AllocationIsInvalid, records[0].getOffset());
    try std.testing.expectError(error.AllocationIsInvalid, records[0].getResourceHeap());
    try std.testing.expectEqual(@as(usize, 0), records[0].getMappedSpan().len);
}

// ---------------------------------------------------------------------------
// The nine upstream fixtures. The exact offsets are the point.
// ---------------------------------------------------------------------------

test "a 32-byte region holds one 32-byte block at offset zero and then refuses another" {
    // `BuddyAllocatorTests.cpp:36`, SingleBlock.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    // `:47` and `:50`. Upstream fuses both into one sentinel; the port separates
    // them so a zero request is not reported as a full allocator.
    try std.testing.expectError(
        error.AllocationSizeExceedsMaximumSize,
        tree.allocate(allocator, 64, 1),
    );
    try std.testing.expectError(
        error.AllocationSizeIsZero,
        tree.allocate(allocator, 0, 1),
    );

    const offset_byte_count = try tree.allocate(allocator, 32, 1);
    try std.testing.expectEqual(@as(u64, 0), offset_byte_count);

    // `:57`, `:58`. The region is full, so the free count is zero and the next
    // request has nowhere to go.
    try std.testing.expectError(
        error.OutOfSpace,
        tree.allocate(allocator, 32, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), tree.totalFreeBlockCount());

    // `:61`, `:62`. Releasing the only block coalesces the tree back to one.
    try tree.deallocate(allocator, offset_byte_count);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
}

test "every power-of-two block size fills its region at ascending offsets" {
    // `BuddyAllocatorTests.cpp:66`, MultipleBlocks. The whole size range the
    // tree supports is filled at every level, one byte at a time up to 64 KiB.
    const allocator = std.testing.allocator;
    const max_block_byte_count: u64 = 1 << 16;

    // The bound is the exponent of the largest block the region holds, so the
    // loop visits every level the tree supports and stops there.
    const max_order: u6 = 16;
    var order: u6 = 1;
    while (order <= max_order) : (order += 1) {
        const block_size_byte_count = @as(u64, 1) << order;
        var tree = try buddy_allocator.BuddyAllocator.init(allocator, max_block_byte_count);
        defer tree.deinit(allocator);

        const block_count = max_block_byte_count / block_size_byte_count;
        var index: u64 = 0;
        while (index < block_count) : (index += 1) {
            const offset_byte_count = try tree.allocate(allocator, block_size_byte_count, 1);
            try std.testing.expectEqual(block_size_byte_count * index, offset_byte_count);
        }

        try std.testing.expectEqual(@as(usize, 0), tree.totalFreeBlockCount());
    }
}

test "an 8-byte split out of a 32-byte region leaves two free blocks and rejoins to one" {
    // `BuddyAllocatorTests.cpp:80`, SingleSplitBlock.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    const offset_byte_count = try tree.allocate(allocator, 8, 1);
    try std.testing.expectEqual(@as(u64, 0), offset_byte_count);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    // `:100`, `:101`. The merge walks two levels back to the root.
    try tree.deallocate(allocator, offset_byte_count);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    try std.testing.expectError(
        error.AllocationSizeExceedsMaximumSize,
        tree.allocate(allocator, 64, 1),
    );

    // `:107`. The largest block is available again after the merge.
    const largest_offset_byte_count = try tree.allocate(allocator, 32, 1);
    try std.testing.expectEqual(@as(u64, 0), largest_offset_byte_count);

    try tree.deallocate(allocator, largest_offset_byte_count);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
}

test "four 8-byte allocations in a 32-byte region merge back one buddy at a time" {
    // `BuddyAllocatorTests.cpp:115`, MultipleSplitBlocks.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    const a = try tree.allocate(allocator, 8, 1);
    try std.testing.expectEqual(@as(u64, 0), a);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    const b = try tree.allocate(allocator, 8, 1);
    try std.testing.expectEqual(@as(u64, 8), b);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    const c = try tree.allocate(allocator, 8, 1);
    try std.testing.expectEqual(@as(u64, 16), c);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    const d = try tree.allocate(allocator, 8, 1);
    try std.testing.expectEqual(@as(u64, 24), d);
    try std.testing.expectEqual(@as(usize, 0), tree.totalFreeBlockCount());

    // `:154`. D's buddy is C, which is allocated, so only D comes free.
    try tree.deallocate(allocator, d);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    // `:159`. B's buddy is A, still allocated, so no merge.
    try tree.deallocate(allocator, b);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    // `:165`. C's buddy is D, free, so one merge and the count holds.
    try tree.deallocate(allocator, c);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    // `:170`. A's buddy is B, free, so two merges back to the root.
    try tree.deallocate(allocator, a);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
}

test "increasing sizes in a 512-byte region leave one free block and then none" {
    // `BuddyAllocatorTests.cpp:175`, MultipleSplitBlockIncreasingSize.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 512);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 0), try tree.allocate(allocator, 32, 1));
    try std.testing.expectEqual(@as(u64, 64), try tree.allocate(allocator, 64, 1));
    try std.testing.expectEqual(@as(u64, 128), try tree.allocate(allocator, 128, 1));
    try std.testing.expectEqual(@as(u64, 256), try tree.allocate(allocator, 256, 1));
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    // The only free block left is the 32-byte hole at offset 32, and the
    // head-only first fit finds it.
    try std.testing.expectEqual(@as(u64, 32), try tree.allocate(allocator, 32, 1));
    try std.testing.expectEqual(@as(usize, 0), tree.totalFreeBlockCount());

    try std.testing.expectError(
        error.OutOfSpace,
        tree.allocate(allocator, 32, 1),
    );
}

test "interleaved 64-byte and 32-byte allocations land where upstream lands them" {
    // `BuddyAllocatorTests.cpp:210`, MultipleSplitBlocksVariableSizes.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 512);
    defer tree.deinit(allocator);

    const offsets = [_]u64{ 0, 64, 128, 96, 192, 256, 320, 288 };
    const sizes = [_]u64{ 64, 32, 64, 32, 64, 32, 64, 32 };

    for (offsets, sizes) |expected_offset_byte_count, size_byte_count| {
        const offset_byte_count = try tree.allocate(allocator, size_byte_count, 1);
        try std.testing.expectEqual(expected_offset_byte_count, offset_byte_count);
    }

    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
}

test "sixteen leaves with every other one freed leave eight free blocks" {
    // `BuddyAllocatorTests.cpp:244`, MultipleSplitBlocksInterleaved.
    const allocator = std.testing.allocator;
    const max_block_byte_count: u64 = 512;
    const leaf_byte_count: u64 = 32;
    const leaf_count = max_block_byte_count / leaf_byte_count;

    var tree = try buddy_allocator.BuddyAllocator.init(allocator, max_block_byte_count);
    defer tree.deinit(allocator);

    var offsets: [leaf_count]u64 = undefined;
    var index: usize = 0;
    while (index < leaf_count) : (index += 1) {
        offsets[index] = try tree.allocate(allocator, leaf_byte_count, 1);
    }

    index = 1;
    while (index < leaf_count) : (index += 2) {
        try tree.deallocate(allocator, offsets[index]);
    }

    try std.testing.expectEqual(@as(usize, 8), tree.totalFreeBlockCount());
}

test "a 16-byte alignment skips a level whose head is misaligned" {
    // `BuddyAllocatorTests.cpp:278`, SameSizeVariousAlignment. This is the
    // head-only first fit at `BuddyAllocator.cpp:100-105`: a level whose head
    // is misaligned is skipped whole, even when a later block at that level
    // would fit. Upstream asserts that as intended behaviour, so the port
    // reproduces it rather than improving it.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    const a = try tree.allocate(allocator, 8, 16);
    try std.testing.expectEqual(@as(u64, 0), a);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    const b = try tree.allocate(allocator, 8, 16);
    try std.testing.expectEqual(@as(u64, 16), b);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    // The 8-byte level holds offset 8 and offset 24, and neither head is 16-byte
    // aligned, so the whole level is refused.
    try std.testing.expectError(
        error.OutOfSpace,
        tree.allocate(allocator, 8, 16),
    );

    // With an 8-byte alignment the same level head now serves the request with
    // no split at all.
    const c = try tree.allocate(allocator, 8, 8);
    try std.testing.expectEqual(@as(u64, 24), c);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
}

test "a 4-byte alignment is served from the same level head as a 16-byte one" {
    // `BuddyAllocatorTests.cpp:311`, VariousSizeSameAlignment.
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    const a = try tree.allocate(allocator, 8, 4);
    try std.testing.expectEqual(@as(u64, 0), a);
    try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());

    const b = try tree.allocate(allocator, 8, 4);
    try std.testing.expectEqual(@as(u64, 8), b);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());

    // The 16-byte request walks up to the level whose head is aligned.
    const c = try tree.allocate(allocator, 16, 4);
    try std.testing.expectEqual(@as(u64, 16), c);
    try std.testing.expectEqual(@as(usize, 0), tree.totalFreeBlockCount());
}

// ---------------------------------------------------------------------------
// The negative space.
// ---------------------------------------------------------------------------

test "the negative space of the offset tree is a named error and not a sentinel" {
    const allocator = std.testing.allocator;

    // `BuddyAllocator.cpp:37` plus `align.zig`, which adds the zero case. Upstream
    // release-assumes a non-zero power of two and reports neither.
    try std.testing.expectError(
        error.MaximumSizeNotPowerOfTwo,
        buddy_allocator.BuddyAllocator.init(allocator, 0),
    );
    try std.testing.expectError(
        error.MaximumSizeNotPowerOfTwo,
        buddy_allocator.BuddyAllocator.init(allocator, 100),
    );

    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    // `.cpp:156-158`, split into two members.
    try std.testing.expectError(
        error.AllocationSizeIsZero,
        tree.allocate(allocator, 0, 1),
    );
    try std.testing.expectError(
        error.AllocationSizeExceedsMaximumSize,
        tree.allocate(allocator, 64, 1),
    );

    // `.cpp:161` calls `ComputeLevelFromBlockSize`, which upstream checks
    // nothing. The port reports it.
    try std.testing.expectError(
        error.AllocationSizeNotPowerOfTwo,
        tree.allocate(allocator, 3, 1),
    );

    // `.cpp:77`. Dawn's `Align` and `IsAligned` release-assume the alignment.
    try std.testing.expectError(
        error.AlignmentNotPowerOfTwo,
        tree.allocate(allocator, 8, 3),
    );

    const offset_byte_count = try tree.allocate(allocator, 32, 1);

    // A second release of one offset: upstream reaches a `DAWN_CHECK` at
    // `.cpp:239`, the port returns `error.UnknownOffset`.
    try tree.deallocate(allocator, offset_byte_count);
    try std.testing.expectError(
        error.UnknownOffset,
        tree.deallocate(allocator, offset_byte_count),
    );

    // An offset the region does not cover reaches the same check.
    try std.testing.expectError(
        error.UnknownOffset,
        tree.deallocate(allocator, region_byte_count),
    );
}

test "a level and an alignment lookup report the level the free lists hold" {
    const allocator = std.testing.allocator;
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    // `ComputeLevelFromBlockSize` at `.cpp:68-73`: `log2(max) - log2(block)`.
    try std.testing.expectEqual(@as(usize, 0), try tree.levelFromBlockSize(32));
    try std.testing.expectEqual(@as(usize, 2), try tree.levelFromBlockSize(8));
    try std.testing.expectEqual(@as(usize, 5), try tree.levelFromBlockSize(1));

    // The same call upstream performs without a guard.
    try std.testing.expectError(error.NotPowerOfTwo, tree.levelFromBlockSize(3));
    try std.testing.expectError(error.OutOfRange, tree.levelFromBlockSize(64));

    // `GetNextFreeAlignedBlock` at `.cpp:75-108`. A fresh region has only the
    // root free, so any alignment the root satisfies is served at level 0.
    try std.testing.expectEqual(@as(?usize, 0), try tree.findFreeBlockLevel(2, 16));
    try std.testing.expectEqual(@as(?usize, 0), try tree.findFreeBlockLevel(2, 1));

    // Once the 8-byte level exists, its head sits at offset 8, which no longer
    // satisfies a 16-byte alignment, so the walk goes up a level.
    _ = try tree.allocate(allocator, 8, 16);
    try std.testing.expectEqual(@as(?usize, 1), try tree.findFreeBlockLevel(2, 16));
    try std.testing.expectEqual(@as(?usize, 2), try tree.findFreeBlockLevel(2, 8));

    // `.cpp:77`.
    try std.testing.expectError(
        error.AlignmentNotPowerOfTwo,
        tree.findFreeBlockLevel(2, 3),
    );
}

test "every allocation the offset tree makes fails on its own" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildAndDrain, .{});
}

/// Fail-N target: build the tree, split it down, take a block and release it, so
/// every `errdefer` in `init` and in the split loop runs at least once.
fn buildAndDrain(allocator: std.mem.Allocator) !void {
    var tree = try buddy_allocator.BuddyAllocator.init(allocator, region_byte_count);
    defer tree.deinit(allocator);

    const offset_byte_count = try tree.allocate(
        allocator,
        min_request_byte_count,
        request_alignment_byte_count,
    );
    try tree.deallocate(allocator, offset_byte_count);
}

// ---------------------------------------------------------------------------
// The record and the heap seam, with no device.
// ---------------------------------------------------------------------------

test "the allocation record keeps the four fields apart and guards two of them" {
    const allocator = std.testing.allocator;
    const heap = try allocator.create(resource_heap.Heap);
    defer allocator.destroy(heap);
    heap.* = .{ .memory = null, .memory_type_index = 7, .size_byte_count = 4096 };

    // A default record reads as nothing, never as a zero-size allocation at
    // offset 0. Upstream returns that record from every failure path.
    var record: allocation_record.ResourceMemoryAllocation = .{};
    try std.testing.expect(record.isInvalid());
    try std.testing.expectEqual(
        allocation_record.AllocationMethod.invalid,
        record.getInfo().method,
    );
    try std.testing.expectError(error.AllocationIsInvalid, record.getOffset());
    try std.testing.expectError(error.AllocationIsInvalid, record.getResourceHeap());

    var mapped: [4]u8 = .{ 1, 2, 3, 4 };
    record = allocation_record.ResourceMemoryAllocation.init(
        .{
            .block_offset_byte_count = 64,
            .method = .sub_allocated,
            .requested_size_byte_count = 100,
            .is_lazy_allocated = true,
        },
        32,
        heap,
        mapped[0..],
    );

    // The two offsets are different numbers and must not read alike. Upstream
    // computes the heap-local one from the allocator-global one at
    // `BuddyMemoryAllocator.cpp:104`.
    try std.testing.expectEqual(@as(u64, 32), try record.getOffset());
    try std.testing.expectEqual(@as(u64, 64), record.getInfo().block_offset_byte_count);
    try std.testing.expectEqual(@as(u64, 100), record.getInfo().requested_size_byte_count);
    try std.testing.expect(record.getInfo().is_lazy_allocated);
    try std.testing.expect(try record.getResourceHeap() == heap);

    // The upstream getter hands out a mutable span
    // (`ResourceMemoryAllocation.cpp:56`), so the port's is mutable and the
    // emptiness is exactly the is-persistently-mapped predicate `BufferVk.cpp:567`
    // reads.
    try std.testing.expectEqual(@as(usize, 4), record.getMappedSpan().len);
    record.getMappedSpan()[0] = 9;
    try std.testing.expectEqual(@as(u8, 9), mapped[0]);

    record.invalidate();
    try std.testing.expect(record.isInvalid());
    try std.testing.expect(record.resource_heap == null);
    try std.testing.expectEqual(@as(usize, 0), record.getMappedSpan().len);
    // Upstream's `Invalidate` (`ResourceMemoryAllocation.cpp:60-64`) clears the
    // span, the heap and the info and leaves `mOffset` alone, so the port does
    // too. The stale offset surviving is the reason `getOffset` is guarded, and
    // the guard is asserted in the other record test.
    try std.testing.expectEqual(@as(u64, 32), record.offset_byte_count);
}

/// The state a test double keeps so the interface can be read back rather than
/// merely called.
const HeapAllocatorFake = struct {
    allocate_count: usize = 0,
    deallocate_count: usize = 0,
    maximum_request_byte_count: u64 = 0,
    error_to_report: ?resource_heap_allocator.Error = null,

    /// The allocator the vtable was handed. `AGENTS.md` §3 makes the allocator a
    /// parameter of every allocating function, so a vtable that closed over one
    /// would be a hidden allocator and the test would not notice.
    allocator_seen: ?std.mem.Allocator = null,
};

fn fakeAllocateResourceHeap(
    allocator: std.mem.Allocator,
    context: *anyopaque,
    size_byte_count: u64,
) resource_heap_allocator.AllocateError!*resource_heap.Heap {
    const self: *HeapAllocatorFake = @ptrCast(@alignCast(context));
    self.allocate_count += 1;
    self.allocator_seen = allocator;
    if (size_byte_count > self.maximum_request_byte_count) {
        self.maximum_request_byte_count = size_byte_count;
    }
    if (self.error_to_report) |report| return report;

    const heap = try allocator.create(resource_heap.Heap);
    heap.* = .{
        .memory = null,
        .memory_type_index = 0,
        .size_byte_count = size_byte_count,
    };
    return heap;
}

fn fakeDeallocateResourceHeap(context: *anyopaque, heap: *resource_heap.Heap) void {
    const self: *HeapAllocatorFake = @ptrCast(@alignCast(context));
    self.deallocate_count += 1;

    // The interface takes no allocator (`ResourceHeapAllocator.h:45` takes the
    // heap by value and drops it), so this double frees through the allocator it
    // was handed at allocate time. That is the implementor's own resource, and
    // the interface does not pretend otherwise.
    const allocator = self.allocator_seen orelse return;
    allocator.destroy(heap);
}

test "the heap-allocator seam passes the request and the allocator to the implementation" {
    const allocator = std.testing.allocator;

    var fake: HeapAllocatorFake = .{};
    const vtable: resource_heap_allocator.VTable = .{
        .allocateResourceHeap = fakeAllocateResourceHeap,
        .deallocateResourceHeap = fakeDeallocateResourceHeap,
    };
    const interface = resource_heap_allocator.ResourceHeapAllocator.init(&fake, &vtable);

    const heap = try interface.allocateResourceHeap(allocator, 4096);
    try std.testing.expectEqual(@as(u64, 4096), heap.size_byte_count);
    try std.testing.expectEqual(@as(usize, 1), fake.allocate_count);
    try std.testing.expectEqual(@as(u64, 4096), fake.maximum_request_byte_count);

    // The allocator reached the implementation as a parameter, not as a
    // captured global. `std.mem.Allocator` has no `==` in Zig 0.16, so identity
    // is the pair of pointers the struct carries (`std/mem/Allocator.zig:19-20`)
    // and both halves are compared; comparing one alone would admit an
    // allocator that borrowed the state of another.
    try std.testing.expect(fake.allocator_seen != null);
    try std.testing.expectEqual(allocator.ptr, fake.allocator_seen.?.ptr);
    try std.testing.expectEqual(allocator.vtable, fake.allocator_seen.?.vtable);

    interface.deallocateResourceHeap(heap);
    try std.testing.expectEqual(@as(usize, 1), fake.deallocate_count);
    try std.testing.expectEqual(@as(usize, 1), fake.allocate_count);

    // Every member of the declared set, one assertion each, so a failure names
    // the member. `AGENTS.md` §2 splits the single upstream out-of-memory bit
    // into the driver's two answers and the caller's own over-large request.
    inline for (@typeInfo(resource_heap_allocator.Error).error_set.?) |member| {
        // Reflection hands back a member's name, not a value, and `@field` is
        // what turns a swept member into the error the fake reports.
        const reported: resource_heap_allocator.Error = @field(
            resource_heap_allocator.Error,
            member.name,
        );
        fake.error_to_report = reported;
        try std.testing.expectError(
            reported,
            interface.allocateResourceHeap(allocator, 4096),
        );
    }
    fake.error_to_report = null;

    // The seam carries no pool. Upstream's pooling is
    // `PooledResourceMemoryAllocator::AllocateResourceHeap`
    // (`PooledResourceMemoryAllocator.cpp:56-64`) and this double is not that
    // implementor, so what the seam makes is what is asserted here: each call
    // hands back a heap of its own, and the caller learns the size by asking
    // the heap it was handed (`ResourceHeapVk.h:44`).
    const first = try interface.allocateResourceHeap(allocator, 4096);
    defer interface.deallocateResourceHeap(first);
    const second = try interface.allocateResourceHeap(allocator, 64);
    defer interface.deallocateResourceHeap(second);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(u64, 64), second.size_byte_count);
}

// ---------------------------------------------------------------------------
// The error sets, swept so every member is named.
// ---------------------------------------------------------------------------

/// Every member of `BuddyAllocator.OperationError`, the call that produces it,
/// and whether this shard can produce it from the public surface.
///
/// `TreeDescentExhausted` and `OffsetLevelMismatch` name a tree that is not a
/// tree. Reaching either would need a corrupted node, and the only way to
/// corrupt one is through a `*Node`, which the module does not export, so the
/// rows below name them and say they are not reachable rather than pretending
/// otherwise.
const buddy_error_members = [_]struct {
    member: buddy_allocator.BuddyAllocator.OperationError,
    producer: []const u8,
    reachable: bool,
}{
    .{ .member = error.MaximumSizeNotPowerOfTwo, .producer = "init", .reachable = true },
    .{ .member = error.AllocationSizeIsZero, .producer = "allocate", .reachable = true },
    .{
        .member = error.AllocationSizeExceedsMaximumSize,
        .producer = "allocate",
        .reachable = true,
    },
    .{
        .member = error.AllocationSizeNotPowerOfTwo,
        .producer = "allocate",
        .reachable = true,
    },
    .{ .member = error.AlignmentNotPowerOfTwo, .producer = "allocate", .reachable = true },
    .{ .member = error.OutOfSpace, .producer = "allocate", .reachable = true },
    .{ .member = error.UnknownOffset, .producer = "deallocate", .reachable = true },
    .{
        .member = error.OffsetLevelMismatch,
        .producer = "deallocate",
        .reachable = false,
    },
    .{
        .member = error.TreeDescentExhausted,
        .producer = "allocate and deallocate",
        .reachable = false,
    },
    .{ .member = error.OutOfMemory, .producer = "the injected allocator", .reachable = true },
};

/// Every member of `SizeTracker.OperationError`. The module's own comptime block
/// counts four and asks for exactly this sweep.
const size_tracker_error_members = [_]struct {
    member: SizeTracker.OperationError,
    producer: []const u8,
}{
    .{ .member = error.SizeTrackerUnderflow, .producer = "decrement and the drain" },
    .{ .member = error.SerialOrderViolation, .producer = "decrement" },
    .{ .member = error.OutOfMemory, .producer = "the injected allocator" },
    .{ .member = error.Canceled, .producer = "the Io lock on a shutting-down device" },
};

comptime {
    // A member with no row is a member no test names, and a row naming a member
    // the set does not declare is a typo that would otherwise pass as coverage.
    for (@typeInfo(buddy_allocator.BuddyAllocator.OperationError).error_set.?) |member| {
        // Reflection hands back a member's name, not a value, so `@field` is
        // what turns the swept member into the error the rows hold.
        const value = @field(buddy_allocator.BuddyAllocator.OperationError, member.name);
        var named = false;
        for (buddy_error_members) |row| {
            if (row.member == value) named = true;
        }
        if (!named) @compileError("a BuddyAllocator error member has no row");
    }
    if (buddy_error_members.len !=
        @typeInfo(buddy_allocator.BuddyAllocator.OperationError).error_set.?.len)
    {
        @compileError("a BuddyAllocator row names a member the set does not declare");
    }

    for (@typeInfo(SizeTracker.OperationError).error_set.?) |member| {
        const value = @field(SizeTracker.OperationError, member.name);
        var named = false;
        for (size_tracker_error_members) |row| {
            if (row.member == value) named = true;
        }
        if (!named) @compileError("a SizeTracker error member has no row");
    }
    if (size_tracker_error_members.len !=
        @typeInfo(SizeTracker.OperationError).error_set.?.len)
    {
        @compileError("a SizeTracker row names a member the set does not declare");
    }
}

test "every member of the offset tree's error set is named and reachable as declared" {
    inline for (@typeInfo(buddy_allocator.BuddyAllocator.OperationError).error_set.?) |member| {
        const value = @field(buddy_allocator.BuddyAllocator.OperationError, member.name);
        var row: ?@TypeOf(buddy_error_members[0]) = null;
        for (buddy_error_members) |candidate| {
            if (candidate.member == value) row = candidate;
        }
        if (row == null) return error.UnnamedErrorMember;
        try std.testing.expect(row.?.producer.len != 0);
    }

    // The reachable members are each produced by a real call in the tests
    // above. Only the two tree-corruption members are declared unreachable, and
    // the count is asserted so a new member cannot quietly join them.
    var reachable_count: usize = 0;
    for (buddy_error_members) |row| {
        if (row.reachable) reachable_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), reachable_count);
}

test "the size tracker's four members are the ones the module declares" {
    try std.testing.expectEqual(@as(usize, 4), size_tracker_error_members.len);

    for (size_tracker_error_members) |row| {
        try std.testing.expect(row.producer.len != 0);
    }
}

test "the size tracker releases bytes only at a serial and refuses a negative total" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const allocator = std.testing.allocator;

    var tracker = SizeTracker.init();
    defer tracker.deinit(allocator);

    try SizeTracker.increment(io, &tracker, 100);
    try std.testing.expectEqual(@as(u64, 100), try SizeTracker.getSize(io, &tracker));

    // A decrement is a record, not a subtraction, so the count holds until the
    // serial drains.
    try SizeTracker.decrement(allocator, io, &tracker, 4, 40);
    try std.testing.expectEqual(@as(u64, 100), try SizeTracker.getSize(io, &tracker));
    try std.testing.expectEqual(@as(usize, 1), try SizeTracker.pendingCount(io, &tracker));

    // A serial below the recorded one releases nothing.
    try SizeTracker.updateCompletedSerialTo(allocator, io, &tracker, 3);
    try std.testing.expectEqual(@as(u64, 100), try SizeTracker.getSize(io, &tracker));
    try std.testing.expectEqual(@as(usize, 1), try SizeTracker.pendingCount(io, &tracker));

    try SizeTracker.updateCompletedSerialTo(allocator, io, &tracker, 4);
    try std.testing.expectEqual(@as(u64, 60), try SizeTracker.getSize(io, &tracker));
    try std.testing.expectEqual(@as(usize, 0), try SizeTracker.pendingCount(io, &tracker));

    // Upstream's `DAWN_ASSERT` at
    // `PooledResourceMemoryAllocator.cpp:86` guards the enqueue.
    try std.testing.expectError(
        error.SizeTrackerUnderflow,
        SizeTracker.decrement(allocator, io, &tracker, 5, 61),
    );

    // It does not guard the subtraction, so two decrements at two serials can
    // each pass the enqueue check and together exceed the total. The port checks
    // both, and the drain reports the entry that caused it.
    var drained = SizeTracker.init();
    defer drained.deinit(allocator);
    try SizeTracker.increment(io, &drained, 100);
    try SizeTracker.decrement(allocator, io, &drained, 1, 60);
    try SizeTracker.decrement(allocator, io, &drained, 2, 60);
    try SizeTracker.updateCompletedSerialTo(allocator, io, &drained, 1);
    try std.testing.expectEqual(@as(u64, 40), try SizeTracker.getSize(io, &drained));
    try std.testing.expectError(
        error.SizeTrackerUnderflow,
        SizeTracker.updateCompletedSerialTo(allocator, io, &drained, 2),
    );

    // The state after that partial drain is pinned: the offending entry has
    // left the queue, so the remaining total is the one the surviving entries
    // describe and a retry moves nothing.
    try std.testing.expectEqual(@as(u64, 40), try SizeTracker.getSize(io, &drained));
    try std.testing.expectEqual(@as(usize, 0), try SizeTracker.pendingCount(io, &drained));
    try SizeTracker.updateCompletedSerialTo(allocator, io, &drained, 2);
    try std.testing.expectEqual(@as(u64, 40), try SizeTracker.getSize(io, &drained));

    // The serial order is the queue's, checked in a release build upstream only.
    var ordered = SizeTracker.init();
    defer ordered.deinit(allocator);
    try SizeTracker.increment(io, &ordered, 100);
    try SizeTracker.decrement(allocator, io, &ordered, 7, 10);
    try std.testing.expectError(
        error.SerialOrderViolation,
        SizeTracker.decrement(allocator, io, &ordered, 6, 10),
    );

    // Device loss drains everything at once, whatever serial is outstanding.
    try SizeTracker.assumeCommandsComplete(allocator, io, &ordered);
    try std.testing.expectEqual(@as(u64, 90), try SizeTracker.getSize(io, &ordered));
    try std.testing.expectEqual(@as(usize, 0), try SizeTracker.pendingCount(io, &ordered));
}

test "the power-of-two helpers refuse what Dawn release-assumes" {
    try std.testing.expect(alignment.isPowerOfTwo(1));
    try std.testing.expect(alignment.isPowerOfTwo(4096));

    // Zero is not a power of two here. Dawn's `IsPowerOfTwo` at
    // `src/dawn/common/Math.h:53-56` release-assumes a non-zero input, and the
    // release-assume is compiled out in a release build.
    try std.testing.expect(!alignment.isPowerOfTwo(0));
    try std.testing.expect(!alignment.isPowerOfTwo(3));

    try std.testing.expectEqual(@as(u6, 6), try alignment.log2PowerOfTwo(64));
    try std.testing.expectError(error.NotPowerOfTwo, alignment.log2PowerOfTwo(63));

    // `NextPowerOfTwo` at `src/dawn/common/Math.h:85`, defined at
    // `src/dawn/common/Math.cpp:50-56`. Dawn shifts by `Log2(n - 1) + 1` with no
    // width guard, so it returns no zero; the port returns the error instead.
    try std.testing.expectEqual(@as(u64, 64), try alignment.nextPowerOfTwo(64));
    try std.testing.expectEqual(@as(u64, 128), try alignment.nextPowerOfTwo(65));
    try std.testing.expectEqual(@as(u64, 1), try alignment.nextPowerOfTwo(1));

    // `Align` at `src/dawn/common/Math.h:98-101`, which release-assumes a
    // non-zero power-of-two alignment.
    try std.testing.expectEqual(@as(u64, 16), try alignment.alignForwardByteCount(1, 16));
    try std.testing.expectEqual(@as(u64, 16), try alignment.alignForwardByteCount(16, 16));
    try std.testing.expectEqual(@as(u64, 32), try alignment.alignForwardByteCount(17, 16));
    try std.testing.expectError(
        error.AlignmentNotPowerOfTwo,
        alignment.alignForwardByteCount(1, 0),
    );
    try std.testing.expectError(
        error.AlignmentNotPowerOfTwo,
        alignment.alignForwardByteCount(1, 3),
    );
}

// ---------------------------------------------------------------------------
// VMA. The declaration half only, and the gap is named.
// ---------------------------------------------------------------------------

test "the VMA binding matches the pinned header's numbering and layout" {
    // `src/memory/vma.zig` tracks 3.4.0 (`vk_mem_alloc.h:136`). The version is a
    // claim about the header the binding was written against, so it is asserted
    // rather than left in a doc comment.
    try std.testing.expectEqualStrings("3.4.0", vma.pinned_version);

    // `VmaMemoryUsage` at `vk_mem_alloc.h:513-587`. The numbers are the header's
    // and a change of number is a wire change, so each tag is asserted by name.
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(vma.VmaMemoryUsage.unknown));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(vma.VmaMemoryUsage.gpu_only));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(vma.VmaMemoryUsage.cpu_only));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(vma.VmaMemoryUsage.cpu_to_gpu));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(vma.VmaMemoryUsage.gpu_to_cpu));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(vma.VmaMemoryUsage.cpu_copy));
    try std.testing.expectEqual(
        @as(u32, 6),
        @intFromEnum(vma.VmaMemoryUsage.gpu_lazily_allocated),
    );
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(vma.VmaMemoryUsage.auto));
    try std.testing.expectEqual(
        @as(u32, 8),
        @intFromEnum(vma.VmaMemoryUsage.auto_prefer_device),
    );
    try std.testing.expectEqual(
        @as(u32, 9),
        @intFromEnum(vma.VmaMemoryUsage.auto_prefer_host),
    );
    try std.testing.expectEqual(
        @as(u32, 0x7FFF_FFFF),
        @intFromEnum(vma.VmaMemoryUsage.max_enum),
    );

    // The `AUTO` arms only work where a `VkBufferCreateInfo` or a
    // `VkImageCreateInfo` is available (`vk_mem_alloc.h:552-556`), which rules
    // them out for `vmaAllocateMemory`. The check below is exhaustive over the
    // tags, so a new tag is classified here or not at all.
    try std.testing.expect(!vma.VmaMemoryUsage.gpu_only.needsResourceInfo());
    try std.testing.expect(vma.VmaMemoryUsage.auto.needsResourceInfo());
    try std.testing.expect(vma.VmaMemoryUsage.auto_prefer_device.needsResourceInfo());
    try std.testing.expect(vma.VmaMemoryUsage.auto_prefer_host.needsResourceInfo());
    inline for (@typeInfo(vma.VmaMemoryUsage).@"enum".fields) |field| {
        const tag: vma.VmaMemoryUsage = @enumFromInt(field.value);
        if (tag == .auto or tag == .auto_prefer_device or tag == .auto_prefer_host) continue;
        try std.testing.expect(!tag.needsResourceInfo());
    }

    // The header's own warning: always fully initialise a structure with zeros.
    // A zeroed record is what every caller starts from, so its pointers have to
    // be null and its numbers zero.
    const zeroed: vma.VmaAllocatorCreateInfo = std.mem.zeroes(vma.VmaAllocatorCreateInfo);
    try std.testing.expectEqual(@as(u32, 0), zeroed.flags);
    try std.testing.expect(zeroed.physicalDevice == null);
    try std.testing.expect(zeroed.device == null);
    try std.testing.expectEqual(@as(u64, 0), zeroed.preferredLargeHeapBlockSize);
    try std.testing.expect(zeroed.pAllocationCallbacks == null);
    try std.testing.expect(zeroed.pDeviceMemoryCallbacks == null);
    try std.testing.expect(zeroed.pHeapSizeLimit == null);
    try std.testing.expect(zeroed.pVulkanFunctions == null);
    try std.testing.expect(zeroed.instance == null);
    try std.testing.expectEqual(@as(u32, 0), zeroed.vulkanApiVersion);

    // The create records are `extern` in the header's declaration order, so the
    // layout holds by construction rather than by a hand-computed offset.
    // `minAlignment` is the last member of `VmaAllocationCreateInfo`
    // (`vk_mem_alloc.h:1364`) and is new in 3.4.0.
    try std.testing.expect(
        @offsetOf(vma.VmaAllocationCreateInfo, "priority") <
            @offsetOf(vma.VmaAllocationCreateInfo, "minAlignment"),
    );
    try std.testing.expectEqual(
        @sizeOf(vma.VmaAllocationCreateInfo),
        @offsetOf(vma.VmaAllocationCreateInfo, "minAlignment") +
            @sizeOf(u64),
    );

    // `VmaTotalStatistics` carries one detailed row per memory type and per
    // memory heap (`vk_mem_alloc.h:1173-1260`), so its size is a fact about the
    // header and not about this port.
    const total: vma.VmaTotalStatistics = std.mem.zeroes(vma.VmaTotalStatistics);
    try std.testing.expectEqual(@as(u32, 0), total.total.statistics.blockCount);
    try std.testing.expectEqual(@as(u32, 0), total.total.statistics.allocationCount);
    try std.testing.expectEqual(@as(u64, 0), total.total.statistics.blockBytes);
    try std.testing.expectEqual(@as(u64, 0), total.total.statistics.allocationBytes);
    try std.testing.expectEqual(@as(u64, 0), total.memoryType[0].statistics.blockBytes);

    // **What this test does not claim.** It claims nothing about a VMA
    // allocation, a heap budget, a mapping or a memory type search. Every entry
    // point in `src/memory/vma.zig` needs a `VkDevice`, and none of them has a
    // definition anywhere in the closure: `vk_mem_alloc.h` is 13,573 lines of
    // which lines 1-3047 are the declaration half and `#ifdef
    // VMA_IMPLEMENTATION` at `:3039` opens the C++ half, and the nixpkgs package
    // `vulkan-memory-allocator` installs `include/` and the CMake config and
    // nothing else. `AGENTS.md` §1 forbids the C++ compilation that would
    // produce an object to link. The `VkDeviceMemory` layer is therefore a
    // declared seam with no body, and it lands when a hand-written C shim
    // exists to give it one.
}
