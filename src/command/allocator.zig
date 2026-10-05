//! The bump arena the stream is written into, and the cursor that walks it.
//!
//! **What this file is.** The port of `src/dawn/native/CommandAllocator.h` and
//! `src/dawn/native/CommandAllocator.cpp`: a bump allocator over a list of
//! fixed-size blocks, writing a `u32` tag and then an eight-byte-aligned
//! payload, with two sentinels above every tag driving the walk.
//!
//! **What this file does not claim.** It does not claim a block pool. Dawn
//! takes a `MemoryBlockAllocator*` (`CommandAllocator.h:199`) that M6 ports,
//! and returns every block to it on reset (`CommandAllocator.cpp:181`). The
//! port takes a `std.mem.Allocator` and a block size instead, so `command` has
//! no dependency on `memory` and the caller chooses the granularity. That is
//! the house rule "an allocator is a parameter, never a global"; the pool's
//! own reuse policy is M6's, and `memory` can wrap this allocator later
//! without a change here.
//!
//! It does not claim the block layout matches Dawn's byte for byte. Dawn's
//! blocks come from `HeapArray<std::byte>` with an alignment the pool
//! happens to provide (`CommandAllocator.cpp:229`); the port asks for
//! `alignedAlloc` explicitly, because a `[]u8` from a general allocator is
//! only one-byte aligned and the eight-byte payload alignment is the framing.

const std = @import("std");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

/// One block of the stream. `bytes` is the whole allocation; `len` is how much
/// of it has been written, which is the only thing a reader needs.
pub const Block = struct {
    bytes: []align(constants.max_alignment) u8,
    len: usize = 0,

    pub fn remaining(self: *const Block) usize {
        return self.bytes.len - self.len;
    }
};

/// The list of blocks, moved between an `Allocator` and an `Iterator`.
pub const Blocks = std.ArrayList(Block);

/// Writes commands into blocks.
///
/// One encoder holds one `Allocator` for its pending commands. `EncodingContext`
/// owns the list that a finished command buffer is built from, because Dawn
/// commits a pending allocator at three points to keep a pass body in its own
/// block (`EncodingContext.cpp:154-215`).
pub const Allocator = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    blocks: Blocks = .empty,
    /// The block being filled, or `blocks.items.len` when there is none. Dawn
    /// uses a four-byte placeholder span instead
    /// (`CommandAllocator.h:305`); an out-of-range index says the same
    /// thing without the pointer aliasing.
    current_index: usize = 0,

    /// Dawn's `CommandAllocator::CommandAllocator(MemoryBlockAllocator*)`
    /// (`CommandAllocator.cpp:146`). Dawn asserts every payload's alignment is
    /// within `kMaxAllocatedCommandAlignment`; the port refuses a block size
    /// too small for the widest payload instead, because a stream that cannot
    /// hold its own largest command is a defect at `init`, not at a draw.
    pub fn init(allocator: std.mem.Allocator, block_size: usize) AllocatorError!Allocator {
        const minimum = @sizeOf(commands.BeginRenderPassCmd) + constants.worst_case_additional_size;
        const size = @max(block_size, minimum);
        return .{
            .allocator = allocator,
            .block_size = size,
            .current_index = 0,
        };
    }

    pub fn deinit(self: *Allocator) void {
        freeBlocks(self.allocator, &self.blocks);
        self.* = undefined;
    }

    /// Dawn's `AcquireBlocks` (`CommandAllocator.cpp:198-206`). The end-of-block
    /// tag goes into the tail of the last block, and the list moves out, so the
    /// allocator is empty afterwards and a second call allocates nothing.
    ///
    /// **The returned list is the owner.** It carries the array behind `.items`
    /// and every `block.bytes` in it, and both travel with the value. Handing
    /// the value on is therefore a transfer, not a copy: the receiver is the one
    /// that releases them, exactly once, and any other copy of the value along
    /// the way is a copy of two words and not a second owner.
    pub fn acquireBlocks(self: *Allocator) Blocks {
        if (self.blocks.items.len != 0) {
            const last = &self.blocks.items[self.blocks.items.len - 1];
            std.debug.assert(last.remaining() >= @sizeOf(u32));
            std.mem.writeInt(u32, last.bytes[last.len..][0..4], constants.end_of_block, .little);
        }
        const moved: Blocks = .{
            .items = self.blocks.items,
            .capacity = self.blocks.capacity,
        };
        self.blocks = .empty;
        self.current_index = 0;
        return moved;
    }

    pub fn isEmpty(self: *const Allocator) bool {
        return self.blocks.items.len == 0;
    }

    /// Dawn's `Allocate(CommandAllocator.h:261-287)`: write the tag and hand
    /// back the payload, in this block when it fits and in a fresh one when it
    /// does not.
    pub fn allocate(
        self: *Allocator,
        command_id: u32,
        byte_count: usize,
    ) AllocatorError![]align(constants.max_alignment) u8 {
        std.debug.assert(command_id != constants.end_of_block);
        if (self.current_index < self.blocks.items.len) {
            const block = &self.blocks.items[self.current_index];
            if (fitsInBlock(block, byte_count)) return carve(block, command_id, byte_count);
        }
        return self.allocateInNewBlock(command_id, byte_count);
    }

    /// The typed form of `allocate`, used by the encoder for each of the 38
    /// payloads. Dawn's `Allocate<T, E>` is a template with the same two
    /// lines (`CommandAllocator.h:212-222`); the port names the payload type
    /// in one place, `commands.Payload`.
    pub fn allocateCommand(
        self: *Allocator,
        comptime T: type,
        command_id: u32,
    ) AllocatorError!*T {
        comptime std.debug.assert(@alignOf(T) <= constants.max_alignment);
        const raw = try self.allocate(command_id, @sizeOf(T));
        // `allocate` returns `[]align(max_alignment) u8`, so `raw.ptr` is
        // already `[*]align(max_alignment) u8`. The alignment lives in the
        // type and needs no run-time assertion, so there is no `@alignCast`.
        return @ptrCast(raw.ptr);
    }

    /// Dawn's `AllocateData` (`CommandAllocator.h:224-246`, `291-293`): the
    /// run that follows a payload, framed by the additional-data sentinel
    /// rather than a tag.
    pub fn allocateData(
        self: *Allocator,
        comptime T: type,
        count: usize,
    ) AllocatorError![]T {
        comptime std.debug.assert(@alignOf(T) <= constants.max_alignment);
        const byte_count = std.math.mul(usize, @sizeOf(T), count) catch
            return error.CopyExtentOutOfRange;
        const raw = try self.allocate(constants.additional_data, byte_count);
        // Same proof as `allocateCommand`: `raw.ptr` carries the alignment.
        const aligned: [*]align(constants.max_alignment) u8 = raw.ptr;
        return @as([*]T, @ptrCast(aligned))[0..count];
    }

    /// Dawn's `AllocateInNewBlock` (`CommandAllocator.cpp:208-224`). The old
    /// block's tail gets the end-of-block tag, so the reader knows to move on,
    /// and the new block is large enough for the payload plus the worst case.
    fn allocateInNewBlock(
        self: *Allocator,
        command_id: u32,
        byte_count: usize,
    ) AllocatorError![]align(constants.max_alignment) u8 {
        if (self.current_index < self.blocks.items.len) {
            const previous = &self.blocks.items[self.current_index];
            std.debug.assert(previous.remaining() >= @sizeOf(u32));
            std.mem.writeInt(u32, previous.bytes[previous.len..][0..4], constants.end_of_block, .little);
        }
        const requested = std.math.add(usize, byte_count, constants.worst_case_additional_size) catch
            return error.CopyExtentOutOfRange;
        try self.appendNewBlock(requested);
        return self.allocate(command_id, byte_count);
    }

    /// Dawn's `AppendNewBlock` (`CommandAllocator.cpp:226-233`). Dawn takes
    /// the larger of the request and the pool's block size; the port takes the
    /// larger of the request and the size `init` settled on.
    fn appendNewBlock(self: *Allocator, minimum_size: usize) AllocatorError!void {
        const size = @max(minimum_size, self.block_size);
        // `alignedAlloc` takes its alignment as a comptime enum tag, so the
        // tag is named here, at comptime, and `constants.max_alignment` stays
        // the one source of truth for its byte count.
        const alignment: std.mem.Alignment = comptime .fromByteUnits(constants.max_alignment);
        const bytes = try self.allocator.alignedAlloc(u8, alignment, size);
        // The append can fail after the block is allocated, and nothing else
        // holds it yet, so it is released here rather than on the floor.
        errdefer self.allocator.free(bytes);
        try self.blocks.append(self.allocator, .{ .bytes = bytes, .len = 0 });
        self.current_index = self.blocks.items.len - 1;
    }

    /// Dawn's fast-path test (`CommandAllocator.h:278-279`): the block must
    /// hold the payload and the worst-case overhead *after* it, so the reader
    /// always finds room for the next tag and for the end-of-block marker.
    fn fitsInBlock(block: *const Block, byte_count: usize) bool {
        if (block.remaining() < constants.worst_case_additional_size) return false;
        return block.remaining() - constants.worst_case_additional_size >= byte_count;
    }

    /// Dawn's tag write plus two `TakeFirst` calls
    /// (`CommandAllocator.h:280-284`): the tag slot is eight bytes so the
    /// payload that follows is aligned, and the payload is padded up to the
    /// same alignment so the next tag slot is aligned too.
    fn carve(
        block: *Block,
        command_id: u32,
        byte_count: usize,
    ) []align(constants.max_alignment) u8 {
        // Every step below leaves `block.len` a multiple of the alignment, so
        // the write cursor carries the block's own alignment. A runtime index
        // drops that from the type, so the cast below is backed by this
        // assert.
        std.debug.assert(@rem(block.len, constants.max_alignment) == 0);
        const slot = block.bytes[block.len..][0..constants.max_alignment];
        std.mem.writeInt(u32, slot[0..4], command_id, .little);
        block.len += constants.max_alignment;
        const aligned_size = std.mem.alignForward(usize, byte_count, constants.max_alignment);
        const start = block.len;
        block.len += aligned_size;
        const payload: []align(constants.max_alignment) u8 = @alignCast(
            block.bytes[start..][0..aligned_size],
        );
        return payload[0..byte_count];
    }
};

fn freeBlocks(allocator: std.mem.Allocator, blocks: *Blocks) void {
    for (blocks.items) |block| allocator.free(block.bytes);
    blocks.deinit(allocator);
}

/// Everything the arena can fail with: one allocation failure and the one
/// stream rule that refuses a run too large to count.
pub const AllocatorError = std.mem.Allocator.Error || errors.CommandValidationError;

/// The cursor over a finished stream.
///
/// Dawn's `CommandIterator` returns the blocks to the pool in
/// `MakeEmptyAsDataWasDestroyed` (`CommandAllocator.cpp:124-132`), which it
/// calls after `FreeCommands` has released every `Ref`. The port has no refs
/// to release, so `deinit` is the whole epilogue.
pub const Iterator = struct {
    allocator: std.mem.Allocator,
    blocks: Blocks = .empty,
    block_index: usize = 0,
    offset: usize = 0,

    /// Dawn's `CommandIterator(CommandAllocator)` (`CommandAllocator.cpp:71-74`).
    pub fn init(allocator: std.mem.Allocator, blocks: Blocks) Iterator {
        var self: Iterator = .{ .allocator = allocator, .blocks = blocks };
        self.reset();
        return self;
    }

    pub fn deinit(self: *Iterator) void {
        freeBlocks(self.allocator, &self.blocks);
        self.* = undefined;
    }

    /// Dawn's `AcquireCommandBlocks` (`CommandAllocator.cpp:76-98`), used by
    /// `EncodingContext` to merge the pre-pass, in-pass and validation
    /// allocators into one stream. The order the list arrives in is the order
    /// the commands are replayed in, so appending is the whole rule.
    ///
    /// **This is what a `Blocks` move costs.** `appendSlice` copies the `Block`
    /// values, and each copy carries its `bytes`, so the blocks end up owned by
    /// `self.blocks` and by nothing else. What the caller is left holding is
    /// the array its own list owned, and the `deinit` after the append is what
    /// releases it. A failed append copies nothing, so nothing has moved and
    /// the `errdefer` frees the blocks and the array together.
    pub fn appendBlocks(self: *Iterator, blocks: Blocks) AllocatorError!void {
        var owned = blocks;
        errdefer freeBlocks(self.allocator, &owned);
        try self.blocks.appendSlice(self.allocator, owned.items);
        owned.deinit(self.allocator);
    }

    /// Dawn's `Reset` (`CommandAllocator.cpp:111-122`): go back to the first
    /// block without emptying the list, so a walk that stopped early can
    /// start again.
    pub fn reset(self: *Iterator) void {
        self.block_index = 0;
        self.offset = 0;
    }

    /// Dawn's `NextCommandId` (`CommandAllocator.h:155-166`): read the tag and
    /// step over its eight-byte slot, moving to the next block when the tag
    /// is the end-of-block sentinel.
    ///
    /// A raw id that is neither a tag nor a sentinel ends the walk. Dawn's
    /// stream is one it wrote, so an unknown id is a corruption it can assert
    /// on; the port's stream is input at M18, and stopping is the only answer
    /// that cannot read past the end.
    pub fn nextTag(self: *Iterator) ?commands.Tag {
        const raw = self.nextRawTag() orelse return null;
        return std.enums.fromInt(commands.Tag, raw);
    }

    fn nextRawTag(self: *Iterator) ?u32 {
        while (self.block_index < self.blocks.items.len) {
            const block = &self.blocks.items[self.block_index];
            if (block.len - self.offset < @sizeOf(u32)) {
                self.block_index += 1;
                self.offset = 0;
                continue;
            }
            const id = std.mem.readInt(u32, block.bytes[self.offset..][0..4], .little);
            if (id == constants.end_of_block) {
                self.block_index += 1;
                self.offset = 0;
                continue;
            }
            self.offset += constants.max_alignment;
            return id;
        }
        return null;
    }

    /// Dawn's `NextCommand<T>` (`CommandAllocator.h:122-126`): the payload the
    /// tag just read introduced.
    pub fn nextCommand(self: *Iterator, comptime T: type) errors.Error!*T {
        comptime std.debug.assert(@alignOf(T) <= constants.max_alignment);
        const raw = self.takeBytes(@sizeOf(T)) orelse return error.CommandStreamTruncated;
        // `takeBytes` returns `[]align(max_alignment) u8`, so the pointer is
        // aligned by type and `@alignCast` would assert what is already known.
        return @ptrCast(raw.ptr);
    }

    /// Dawn's `NextData<T>` (`CommandAllocator.h:128-142`): the counted run
    /// behind a payload, behind the additional-data sentinel.
    pub fn nextData(self: *Iterator, comptime T: type, count: usize) errors.Error![]T {
        comptime std.debug.assert(@alignOf(T) <= constants.max_alignment);
        const id = self.nextRawTag() orelse return error.CommandStreamTruncated;
        // Dawn asserts this (`CommandAllocator.h:180`). The port refuses it:
        // a run that does not follow its payload is the one corruption the
        // framing can detect, and a decoder is where input is refused.
        if (id != constants.additional_data) return error.CommandStreamTruncated;
        const byte_count = std.math.mul(usize, @sizeOf(T), count) catch
            return error.CommandStreamTruncated;
        const raw = self.takeBytes(byte_count) orelse return error.CommandStreamTruncated;
        // Same proof as `nextCommand`: `raw.ptr` carries the alignment.
        const aligned: [*]align(constants.max_alignment) u8 = raw.ptr;
        return @as([*]T, @ptrCast(aligned))[0..count];
    }

    /// Dawn's `NextCommand(size_t)` (`CommandAllocator.h:170-175`): consume an
    /// eight-byte-aligned run out of the current block. The current block never
    /// ends inside a payload, because `fitsInBlock` reserves the worst-case
    /// overhead after every payload, so this only fails for a stream this
    /// module did not write.
    fn takeBytes(self: *Iterator, byte_count: usize) ?[]align(constants.max_alignment) u8 {
        if (self.block_index >= self.blocks.items.len) return null;
        const block = &self.blocks.items[self.block_index];
        // The cursor steps by the alignment only, as `carve` writes, so the
        // bytes it names keep the block's alignment.
        std.debug.assert(@rem(self.offset, constants.max_alignment) == 0);
        const aligned_size = std.mem.alignForward(usize, byte_count, constants.max_alignment);
        if (block.len - self.offset < aligned_size) return null;
        const out: []align(constants.max_alignment) u8 = @alignCast(
            block.bytes[self.offset..][0..byte_count],
        );
        self.offset += aligned_size;
        return out;
    }

    /// The bytes a command stream occupies, for a test that asserts on the
    /// footprint. Dawn reports this as `kWorstCaseAdditionalSize`
    /// (`CommandAllocator.h:253-256`) and asserts nothing else about it.
    pub fn byteCount(self: *const Iterator) usize {
        var total: usize = 0;
        for (self.blocks.items) |block| total += block.len;
        return total;
    }
};
