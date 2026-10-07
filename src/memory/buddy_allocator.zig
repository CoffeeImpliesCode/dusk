//! A power-of-two offset tree over one region of bytes.
//!
//! **What this file is.** The port of `BuddyAllocator`
//! (`src/dawn/native/BuddyAllocator.h:52-131` and
//! `src/dawn/native/BuddyAllocator.cpp:36-280`). One heap region of
//! `max_size_byte_count` bytes, sub-divided by binary halving. A binary tree of
//! nodes covers the region and each node is `free`, `split` or `allocated`.
//! `mFreeLists` (`BuddyAllocator.h:130`) is one head-only doubly-linked list per
//! level; level `L` holds blocks of `max_size >> L`, so level 0 is the root and
//! level `log2(max_size)` is one byte.
//!
//! **What this file does not claim.** It does not own the memory it hands out.
//! `BuddyMemoryAllocator` owns the device heaps and this tree only carves them;
//! `BuddyAllocator.h:43-45` says the same.
//!
//! **Why the tree stays.** `docs/40-plan.md` §M6 records the decision in full.
//! VMA's own sub-allocation is behind `#ifdef VMA_IMPLEMENTATION`
//! (`vk_mem_alloc.h:3039`) in a header-only nixpkgs package, `AGENTS.md` §1
//! forbids the C++ compilation that would produce an object, and the
//! milestone's acceptance asserts on offsets. An offset source that is a test
//! fake makes that assertion circular.
//!
//! **Why the node links are not a union.** `BuddyAllocator.h:101-110` unions
//! `SplitLink` (`pLeft`, `pParent`, `pBuddy`) with `FreeLinks` (`pPrev`,
//! `pNext`) and relies on writing `mState` before the union member
//! (`.h:74-76`, `.cpp:206-207`). A Zig struct with `left`, `free_prev` and
//! `free_next` as separate fields makes that ordering rule impossible to break,
//! and costs three words on a node that a GPU heap allocation dwarfs.
//!
//! **Alignment is first-fit on the head only.** `GetNextFreeAlignedBlock`
//! (`.cpp:100-105`) skips a level whose *head* is misaligned even when a later
//! block at that level is aligned. `BuddyAllocatorTests.cpp:296-297` asserts that as
//! intended behaviour, so this port reproduces it rather than improving it.

const std = @import("std");
/// `align.zig`: the power-of-two and alignment arithmetic. The key is
/// `alignment` and not `align`, because `align` names a Zig primitive type and
/// so cannot name a declaration. `src/memory/root.zig` re-exports the module
/// under the same key.
const alignment = @import("align.zig");

/// The state of one node of the tree. Ports the `State` enum at
/// `BuddyAllocator.h:70`.
const State = enum {
    /// In exactly one free list, at the level its size names.
    free,

    /// Halved into two children. `left` is the lower half and the upper half is
    /// always `left.buddy`, which is how `BuddyAllocator.cpp:230-233` reaches it.
    split,

    /// Handed out. Not in any free list.
    allocated,
};

/// One node of the tree. Ports `BuddyBlock` (`BuddyAllocator.h:72-110`) with the
/// link union resolved, as the header comment says.
const Node = struct {
    /// `mOffset` (`BuddyAllocator.h:79`).
    offset_byte_count: u64,

    /// `mSize` (`BuddyAllocator.h:80`). Always a power of two and always
    /// `max_size >> level`.
    size_byte_count: u64,

    state: State = .free,

    /// `pParent` (`BuddyAllocator.h:85`). Null for the root only, whose buddy is
    /// null too — which is why the merge loop tests the level before the buddy.
    parent: ?*Node = null,

    /// `pBuddy` (`BuddyAllocator.h:84`). The other half at the same level. Null
    /// for the root.
    buddy: ?*Node = null,

    /// `split.pLeft` (`BuddyAllocator.h:98`). Null unless `state == .split`.
    left: ?*Node = null,

    /// `free.pPrev` (`BuddyAllocator.h:92`).
    free_prev: ?*Node = null,

    /// `free.pNext` (`BuddyAllocator.h:93`).
    free_next: ?*Node = null,
};

/// The tree.
///
/// A caller owns the `std.mem.Allocator` for every call. Upstream calls `new`
/// and `delete` inside `Allocate` (`.cpp:187-188`) and `DeleteBlock` (`.cpp:279`)
/// with no allocator at all, which `AGENTS.md` §3 forbids; the allocator is a
/// parameter here and the only two allocations are the split's two children.
pub const BuddyAllocator = struct {
    /// `mMaxBlockSize` (`BuddyAllocator.h:126`).
    max_size_byte_count: u64,

    /// `Log2(maxSize)` (`BuddyAllocator.cpp:39`). Cached because
    /// `ComputeLevelFromBlockSize` (`.cpp:68-73`) takes it twice per call.
    log2_max_size: u6,

    /// `mFreeLists.size()` (`BuddyAllocator.cpp:39`): `log2(max_size) + 1`. Index
    /// `L` holds blocks of `max_size >> L`.
    free_lists: std.ArrayList(?*Node) = .empty,

    /// `mRoot` (`BuddyAllocator.h:124`), which upstream comments "Used to
    /// deallocate non-free blocks." It is a member and not the head of free
    /// list 0 because the root leaves that list the moment it splits, and an
    /// allocated root leaves it too: reading the root back out of
    /// `free_lists.items[0]` finds nothing after either event.
    root: ?*Node = null,

    /// Every node the tree owns. Individual `Node` values are allocated through
    /// the caller's allocator so that a `*Node` handed into a free list stays
    /// valid when the list array itself grows.
    live_node_count: usize = 0,

    /// `kInvalidOffset` (`BuddyAllocator.h:64`) becomes this set, per
    /// `AGENTS.md` §3 "errors are values". Upstream fuses three different
    /// failures into the one sentinel at `.cpp:168-170`; the port separates them
    /// so a zero request is not reported as a full allocator.
    pub const Error = error{
        /// `DAWN_CHECK(IsPowerOfTwo(maxSize))` at `.cpp:37`.
        MaximumSizeNotPowerOfTwo,
        /// `allocationSize == 0`, from `.cpp:156-158`.
        AllocationSizeIsZero,
        /// `allocationSize > mMaxBlockSize`, from `.cpp:156-158`.
        AllocationSizeExceedsMaximumSize,
        /// `ComputeLevelFromBlockSize` (`.cpp:68-73`) has no guard. Upstream
        /// relies on `BuddyMemoryAllocator.cpp:73-74` rounding first.
        AllocationSizeNotPowerOfTwo,
        /// `DAWN_CHECK(IsPowerOfTwo(alignment))` at `.cpp:77`.
        AlignmentNotPowerOfTwo,
        /// No level holds a block whose head satisfies the alignment, at
        /// `.cpp:107` and `:168-170`.
        OutOfSpace,
        /// The descent landed on a node that is not `Allocated`, from the
        /// `DAWN_CHECK` at `.cpp:239`. A stale, duplicated or out-of-range offset.
        UnknownOffset,
        /// The `DAWN_CHECK` at `.cpp:242`: the depth the descent reached is not
        /// the level the node's size names.
        OffsetLevelMismatch,
        /// A bounded loop reached its named bound. Every loop below is bounded by
        /// `log2(max_size)`, which is the tree's depth, so reaching it means the
        /// tree is not a tree.
        TreeDescentExhausted,
    };

    /// The error the allocating and freeing operations report.
    pub const OperationError = Error || std.mem.Allocator.Error;

    /// What `levelFromBlockSize` rejects. `alignment.LogError` is the log
    /// helper's own set and passes through unchanged, so the non-power-of-two
    /// defect upstream hides stays nameable; `OutOfRange` is the tree's, because
    /// no level holds a block wider than `max_size_byte_count`. Both callers in
    /// this file collapse either member with `catch`, which is why the set is
    /// not folded into `Error`: `Error` is what `allocate` and `deallocate`
    /// report, and neither reports these.
    pub const LevelError = alignment.LogError || error{OutOfRange};

    /// The bound every descent and merge loop carries: the tree is `log2(max)`
    /// deep. `AGENTS.md` §2, "bound every loop".
    ///
    /// It reads `log2_max_size`, which `init` fills from
    /// `alignment.log2PowerOfTwo` (`.cpp:39`). That is the same cached log
    /// `levelFromBlockSize` (`.cpp:68-73`) subtracts from, so the bound and
    /// the level arithmetic cannot disagree, and the loops do not recompute
    /// the log on every test. A one-byte region has depth 0: it has no
    /// halving left to take, so its loops report `TreeDescentExhausted` on
    /// the first test instead of trusting a width the region does not have.
    pub fn depthBound(self: *const BuddyAllocator) usize {
        return self.log2_max_size;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        max_size_byte_count: u64,
    ) OperationError!BuddyAllocator {
        if (!alignment.isPowerOfTwo(max_size_byte_count)) {
            return error.MaximumSizeNotPowerOfTwo;
        }
        if (max_size_byte_count == 0) return error.MaximumSizeNotPowerOfTwo;

        // The guard above rejected a size that is not a power of two with this
        // same member, so the log cannot fail here.
        const log2_max_size = alignment.log2PowerOfTwo(max_size_byte_count) catch
            return error.MaximumSizeNotPowerOfTwo;
        const level_count = @as(usize, log2_max_size) + 1;

        var free_lists = try std.ArrayList(?*Node).initCapacity(allocator, level_count);
        errdefer free_lists.deinit(allocator);
        // `initCapacity` reserves capacity and leaves `items.len` at zero, so
        // `items[0] = root` below and every `items[level]` read in
        // `findFreeBlockLevel`, `insertFreeBlock` and `removeFreeBlock` index
        // an empty slice until the length is set. `mFreeLists.resize(Log2(
        // mMaxBlockSize) + 1)` at `.cpp:39` is the upstream statement that
        // gives the list its length, and `resize` is the port of it: one step
        // that sets `items.len == level_count`, where a loop appending
        // `level_count` nulls would need its own exhaustion check. It reallocates
        // nothing here, because `initCapacity` reserved `level_count` exactly,
        // so the nulls below land in already reserved memory.
        try free_lists.resize(allocator, level_count);
        @memset(free_lists.items, null);

        const root = try allocator.create(Node);
        errdefer allocator.destroy(root);
        root.* = .{
            .offset_byte_count = 0,
            .size_byte_count = max_size_byte_count,
        };

        // `mFreeLists[0] = {mRoot}` at `.cpp:43`. A direct assignment, not an
        // `insertFreeBlock`: the node constructor already left both links null.
        free_lists.items[0] = root;

        return .{
            .max_size_byte_count = max_size_byte_count,
            .log2_max_size = log2_max_size,
            .free_lists = free_lists,
            .root = root,
            .live_node_count = 1,
        };
    }

    /// Ports `~BuddyAllocator` (`.cpp:46-51`). One `deleteBlock` walk over the
    /// tree, then the free list array. Upstream clears `mFreeLists` at `:48`
    /// before the walk; order does not matter here because the walk reads the
    /// tree and not the lists. The walk starts at `mRoot`, so a split or
    /// allocated root is still walked and every node it owns is released.
    pub fn deinit(self: *BuddyAllocator, allocator: std.mem.Allocator) void {
        const root = self.root;
        if (root != null) self.deleteBlock(allocator, root.?);
        self.free_lists.deinit(allocator);
        self.* = undefined;
    }

    /// Ports `ComputeTotalNumOfFreeBlocksForTesting` (`.cpp:54`). Upstream labels
    /// it test-only; `test/memory.zig` asserts against it on every cycle, so it
    /// is production code here. The `ForTesting` suffix goes with `AGENTS.md` §2.
    pub fn totalFreeBlockCount(self: *const BuddyAllocator) usize {
        const root = self.root orelse return 0;
        return self.countFreeBlocks(root);
    }

    /// Ports `ComputeNumOfFreeBlocks` (`.cpp:58-66`). A tree walk, not a list
    /// walk, so it also validates the tree's shape: `Free → 1`, `Split → left +
    /// left.buddy`, `Allocated → 0`.
    pub fn countFreeBlocks(self: *const BuddyAllocator, node: *const Node) usize {
        return switch (node.state) {
            .free => 1,
            .allocated => 0,
            .split => blk: {
                const left = node.left orelse break :blk 0;
                const buddy = left.buddy orelse break :blk 0;
                break :blk self.countFreeBlocks(left) + self.countFreeBlocks(buddy);
            },
        };
    }

    /// Ports `ComputeLevelFromBlockSize` (`.cpp:68-73`):
    /// `Log2(mMaxBlockSize) - Log2(blockSize)`. Upstream checks nothing and a
    /// non-power-of-two size produces a meaningless level; the port reports it.
    pub fn levelFromBlockSize(
        self: *const BuddyAllocator,
        size_byte_count: u64,
    ) LevelError!usize {
        const log2_size = try alignment.log2PowerOfTwo(size_byte_count);
        if (log2_size > self.log2_max_size) return error.OutOfRange;
        return @as(usize, self.log2_max_size - log2_size);
    }

    /// The first level at or above `request_level` whose *head* satisfies
    /// `alignment`. Ports `GetNextFreeAlignedBlock` (`.cpp:75-108`).
    ///
    /// Returns null where upstream returns `kInvalidOffset` at `.cpp:107`. The
    /// walk goes from the requested level up to level 0, so it examines
    /// successively larger blocks.
    pub fn findFreeBlockLevel(
        self: *const BuddyAllocator,
        request_level: usize,
        alignment_byte_count: u64,
    ) alignment.AlignmentError!?usize {
        if (!alignment.isPowerOfTwo(alignment_byte_count)) return error.AlignmentNotPowerOfTwo;

        // `.cpp:163` rejects a level the free lists do not hold before the
        // walk. `allocate` cannot produce one because `levelFromBlockSize`
        // caps the level at `depthBound`, but the walk is public and would
        // index past `free_lists.items` without this.
        if (request_level > self.depthBound()) return null;

        // `.cpp:99-102` counts `ii` from 0 up to `allocationBlockLevel` and
        // visits level `allocationBlockLevel - ii`, so the walk starts at
        // `request_level` and ends at level 0. Counting `ii` up rather than
        // decrementing `level` is what keeps the walk off the `usize`
        // underflow that a `level -= 1` continuation hits when level 0 holds
        // no head, and it makes the bound the level count the tree has.
        // `request_level -| ii` saturates so a level 0 with no head walks out
        // through the bound instead of wrapping.
        var ii: usize = 0;
        while (ii <= self.depthBound()) : (ii += 1) {
            const level = request_level -| ii;
            const head = self.free_lists.items[level] orelse continue;
            if (head.offset_byte_count % alignment_byte_count == 0) return level;
            if (level == 0) return null;
        }
        return null;
    }

    /// Pushes `node` at the head of `level`'s list. Ports `InsertFreeBlock`
    /// (`.cpp:114-129`), head-only by design (`.cpp:110-113`).
    pub fn insertFreeBlock(self: *BuddyAllocator, node: *Node, level: usize) void {
        std.debug.assert(node.state == .free);
        const old_head = self.free_lists.items[level];
        node.free_prev = null;
        node.free_next = old_head;
        if (old_head) |head| head.free_prev = node;
        self.free_lists.items[level] = node;
    }

    /// Removes `node` from `level`'s list. Ports `RemoveFreeBlock`
    /// (`.cpp:132-152`).
    ///
    /// Upstream leaves the removed node's links and the new head's `pPrev` stale
    /// and lets the next insert repair them (`.cpp:135-137`, `:120`, `:125`).
    /// The port clears all three, which turns "a free node is in exactly one
    /// list" into something a caller can check instead of something it has to
    /// trust.
    pub fn removeFreeBlock(self: *BuddyAllocator, node: *Node, level: usize) void {
        std.debug.assert(node.state == .free);

        if (self.free_lists.items[level] == node) {
            const new_head = node.free_next;
            self.free_lists.items[level] = new_head;
            if (new_head) |head| head.free_prev = null;
            node.free_prev = null;
            node.free_next = null;
            return;
        }

        const prev = node.free_prev orelse {
            // A free node that is neither a head nor carries a previous pointer
            // is not in any list. Upstream calls this `DAWN_ASSERT` at `:143`;
            // the port returns it so a corrupted list is a value and not a trap.
            @panic("a free node is in no free list");
        };
        const next = node.free_next;
        prev.free_next = next;
        if (next) |next_node| next_node.free_prev = prev;
        node.free_prev = null;
        node.free_next = null;
    }

    /// Ports `BuddyAllocator::Allocate` (`.cpp:155-218`), body order intact:
    /// reject, find level, split, take.
    ///
    /// The size checks at `.cpp:156-158` come first and are separated, so a
    /// zero request is `AllocationSizeIsZero` and not `OutOfSpace`.
    pub fn allocate(
        self: *BuddyAllocator,
        allocator: std.mem.Allocator,
        size_byte_count: u64,
        alignment_byte_count: u64,
    ) OperationError!u64 {
        if (size_byte_count == 0) return error.AllocationSizeIsZero;
        if (size_byte_count > self.max_size_byte_count) {
            return error.AllocationSizeExceedsMaximumSize;
        }
        if (!alignment.isPowerOfTwo(alignment_byte_count)) return error.AlignmentNotPowerOfTwo;

        const allocation_level = self.levelFromBlockSize(size_byte_count) catch
            return error.AllocationSizeNotPowerOfTwo;
        const start_level = (try self.findFreeBlockLevel(
            allocation_level,
            alignment_byte_count,
        )) orelse return error.OutOfSpace;

        // The walk above returns a level only where it read a non-null head
        // (`findFreeBlockLevel`'s `orelse continue`), and nothing between that
        // walk and this read touches `free_lists`, so the slot cannot be empty.
        // The claim is stated and not taken silently, as `AGENTS.md` §3 asks of
        // an `unreachable` and as `removeFreeBlock` states its own at `:342`.
        var node = self.free_lists.items[start_level] orelse
            @panic("a level the free-block walk accepted holds no head");
        var level = start_level;

        // Acquire the whole split path before removing any free-list entry.
        // A failure at a deeper split must not strand earlier committed children.
        var acquired: [126]*Node = undefined;
        var acquired_count: usize = 0;
        errdefer for (acquired[0..acquired_count]) |child| allocator.destroy(child);
        const required_count = (allocation_level - start_level) * 2;
        for (0..required_count) |index| {
            acquired[index] = try allocator.create(Node);
            acquired_count += 1;
        }

        // The split loop at `.cpp:179-211`. At most one iteration per level, so
        // the bound is the depth.
        var step: usize = 0;
        while (level < allocation_level) {
            if (step >= self.depthBound()) {
                return error.TreeDescentExhausted;
            }
            step += 1;

            std.debug.assert(node.state == .free);
            self.removeFreeBlock(node, level);

            const half_byte_count = node.size_byte_count / 2;

            const child_index = (level - start_level) * 2;
            const left = acquired[child_index];
            left.* = .{
                .offset_byte_count = node.offset_byte_count,
                .size_byte_count = half_byte_count,
            };

            const right = acquired[child_index + 1];
            right.* = .{
                .offset_byte_count = node.offset_byte_count + half_byte_count,
                .size_byte_count = half_byte_count,
            };

            left.buddy = right;
            right.buddy = left;
            left.parent = node;
            right.parent = node;

            // `.cpp:202-203` inserts the right child first and the left child
            // second, so the left child ends at the head. That is what makes
            // allocation lowest-address-first.
            self.insertFreeBlock(right, level + 1);
            self.insertFreeBlock(left, level + 1);

            node.state = .split;
            node.left = left;

            node = left;
            level += 1;
        }

        self.removeFreeBlock(node, level);
        node.state = .allocated;
        return node.offset_byte_count;
    }

    /// Ports `BuddyAllocator::Deallocate` (`.cpp:220-269`).
    ///
    /// Upstream returns void and reports every fault through `DAWN_CHECK`, so a
    /// stale, duplicated or out-of-range offset is a process check failure rather
    /// than a value. The port returns `error.UnknownOffset` and
    /// `error.OffsetLevelMismatch` instead.
    ///
    /// The merge loop condition tests `level > 0` *before* the buddy's state: the
    /// root's `buddy` is null (`BuddyAllocator.h:84`, never set for the node
    /// built at `.cpp:42`), so the order of the two tests is the dereference
    /// guard and not a style choice.
    pub fn deallocate(
        self: *BuddyAllocator,
        allocator: std.mem.Allocator,
        offset_byte_count: u64,
    ) OperationError!void {
        // `BuddyBlock* curr = mRoot;` at `.cpp:221`, not the head of free list 0:
        // the root leaves that list as soon as it splits, so the descent has to
        // start at the member.
        var node = self.root orelse return error.UnknownOffset;
        var level: usize = 0;

        // The descent at `.cpp:228-237`. The right child is always
        // `left.buddy` (`.cpp:230-233`), so the left pointer is all that is
        // stored.
        var step: usize = 0;
        while (node.state == .split) {
            if (step >= self.depthBound()) {
                return error.TreeDescentExhausted;
            }
            step += 1;

            const left = node.left orelse return error.TreeDescentExhausted;
            const right = left.buddy orelse return error.TreeDescentExhausted;

            if (offset_byte_count < right.offset_byte_count) {
                node = left;
            } else {
                node = right;
            }
            level += 1;
        }

        if (node.state != .allocated) return error.UnknownOffset;

        const node_level = self.levelFromBlockSize(node.size_byte_count) catch {
            return error.OffsetLevelMismatch;
        };
        if (node_level != level) return error.OffsetLevelMismatch;

        node.state = .free;

        // The merge loop at `.cpp:245-265`. Both children die; the surviving
        // object is the parent.
        step = 0;
        while (level > 0) {
            const buddy = node.buddy orelse break;
            if (buddy.state != .free) break;
            if (step >= self.depthBound()) {
                return error.TreeDescentExhausted;
            }
            step += 1;

            self.removeFreeBlock(buddy, level);

            const parent = node.parent orelse return error.TreeDescentExhausted;

            // `.cpp:256-257` releases the buddy before the node, which is the
            // post-order `DeleteBlock` uses. The order is observable here
            // because both allocations come from the caller's allocator.
            self.deleteBlock(allocator, buddy);
            self.deleteBlock(allocator, node);

            parent.state = .free;

            node = parent;
            level -= 1;
        }

        self.insertFreeBlock(node, level);
    }

    /// Ports `DeleteBlock` (`.cpp:271-280`): post-order, right child before left,
    /// so the release order matches the insert order at `.cpp:202-203`.
    pub fn deleteBlock(self: *BuddyAllocator, allocator: std.mem.Allocator, node: *Node) void {
        if (node.state == .split) {
            const left = node.left orelse return;
            const right = left.buddy orelse return;
            self.deleteBlock(allocator, right);
            self.deleteBlock(allocator, left);
            node.state = .free;
            node.left = null;
        }
        allocator.destroy(node);
    }
};

test "init gives the free list a head for every level the tree has" {
    // The panic this pins: `init` built the slice with `initCapacity`, which
    // reserves capacity and leaves `items.len` at zero, so `items[0] = root`
    // and every `items[level]` below it indexed an empty slice. The upstream
    // `resize` call at `.cpp:39` is what gives the list its length.
    const allocator = std.testing.allocator;
    const max_block_byte_count: u64 = 64;

    var tree = try BuddyAllocator.init(allocator, max_block_byte_count);
    defer tree.deinit(allocator);

    // 64 bytes is `Log2(64) + 1` = 7 levels, level 0 through level 6.
    try std.testing.expectEqual(@as(usize, 7), tree.free_lists.items.len);
    try std.testing.expectEqual(@as(usize, 7), tree.free_lists.capacity);

    // Level 0 holds the root, and every level below it starts empty.
    try std.testing.expect(tree.root != null);
    try std.testing.expectEqual(tree.root.?, tree.free_lists.items[0]);
    for (tree.free_lists.items[1..]) |head| {
        try std.testing.expect(head == null);
    }
}

test "a split and a merge walk every level's free list" {
    // The `items[level]` reads in `findFreeBlockLevel`, `insertFreeBlock` and
    // `removeFreeBlock` were the same out-of-bounds reads, so this drives all
    // three through one split and the merge that undoes it.
    const allocator = std.testing.allocator;

    var tree = try BuddyAllocator.init(allocator, 64);
    defer tree.deinit(allocator);

    const offset_byte_count = try tree.allocate(allocator, 8, 1);
    try std.testing.expectEqual(@as(u64, 0), offset_byte_count);
    // 64 splits to 32 + 32, 32 splits to 16 + 16, 16 to 8 + 8: three free
    // blocks left once the first 8 is taken.
    try std.testing.expectEqual(@as(usize, 3), tree.totalFreeBlockCount());

    try tree.deallocate(allocator, offset_byte_count);
    try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
}

test "the root is reachable after it splits, so deallocate and deinit both work" {
    // The root leaves free list 0 the moment it splits, so a port that reads
    // the root back out of `free_lists.items[0]` reports `UnknownOffset` for
    // every offset and releases nothing at `deinit`. `mRoot` is a member
    // (`BuddyAllocator.h:124`) for exactly this reason. The leak detector in
    // `std.testing.allocator` is the assertion here.
    const allocator = std.testing.allocator;

    var tree = try BuddyAllocator.init(allocator, 32);
    {
        const offset_byte_count = try tree.allocate(allocator, 8, 1);
        try std.testing.expectEqual(@as(u64, 0), offset_byte_count);
        // 32 splits to 16 + 16, 16 to 8 + 8: the far 16 and one 8 stay free.
        try std.testing.expectEqual(@as(usize, 2), tree.totalFreeBlockCount());
    }
    tree.deinit(allocator);
}

test "a region with no room left reports OutOfSpace rather than walking off level 0" {
    // `findFreeBlockLevel` used to count levels down with `level -= 1`, which
    // underflows when level 0 holds no head. `.cpp:99-102` counts `ii` up.
    const allocator = std.testing.allocator;

    var tree = try BuddyAllocator.init(allocator, 32);
    defer tree.deinit(allocator);

    _ = try tree.allocate(allocator, 32, 1);
    try std.testing.expectError(error.OutOfSpace, tree.allocate(allocator, 32, 1));
    try std.testing.expectError(error.OutOfSpace, tree.allocate(allocator, 1, 1));
}

test "failed split acquisition leaves the tree reusable at every allocation failure" {
    const allocator = std.testing.allocator;
    for (0..12) |fail_index| {
        var tree = try BuddyAllocator.init(allocator, 64);
        defer tree.deinit(allocator);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, tree.allocate(failing.allocator(), 1, 1));
        try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
        try std.testing.expectEqual(tree.root.?, tree.free_lists.items[0]);
        const offset = try tree.allocate(allocator, 1, 1);
        try std.testing.expectEqual(@as(u64, 0), offset);
        try tree.deallocate(allocator, offset);
        try std.testing.expectEqual(@as(usize, 1), tree.totalFreeBlockCount());
    }
}
