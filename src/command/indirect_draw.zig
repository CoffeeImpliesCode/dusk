//! Every indirect draw a pass issued, so the back end can read back what it
//! wrote.
//!
//! **What this file is.** The port of
//! `src/dawn/native/IndirectDrawMetadata.{h,cpp}` minus the batch-splitting
//! and the argument rewriting.
//!
//! **What this file does not claim.** It does not claim the GPU-side
//! validation Dawn builds on top. Dawn's metadata splits indirect draws into
//! validation batches, allocates a scratch buffer per batch and rewrites the
//! arguments through `IndirectDrawValidationEncoder`
//! (`src/dawn/native/IndirectDrawValidationEncoder.cpp:452-918`). That
//! encoder holds 239 lines of inline WGSL (`IndirectDrawValidationEncoder.cpp:101-339`)
//! compiled at run time through Tint, and `AGENTS.md` §3.2 forbids a WGSL
//! front end in this repository. So the port records what the draws were and
//! the batches stay empty; M18 reads the arguments back through a buffer copy
//! instead, and `docs/40-plan.md` §M15 records the skipped files.
//!
//! It does not claim the `ValidatedIndirectDraw` rewrite is needed. That
//! rewrite is a debug feature; the port keeps the recording and drops the
//! rewriting, which is the simplification the budget row records.

const std = @import("std");
const commands = @import("commands.zig");
const errors = @import("errors.zig");

/// One indirect draw: where its arguments live, and at which index inside the
/// buffer they were written (`IndirectDrawMetadata.h:70-83`).
pub const IndirectDraw = struct {
    /// The position in the draw sequence. Dawn assigns one index per draw so
    /// the validation batches can be merged in order.
    index: u32 = 0,
    buffer: commands.Ref = null,
    offset: u64 = 0,
    /// Dawn's `IndirectDraw::DrawType`: whether the draw reads indices, and
    /// whether it is a multi-draw.
    indexed: bool = false,
    multi: bool = false,
    /// The first instance, which an indexed indirect draw can override.
    first_instance: u32 = 0,
    /// The `maxDrawCount` and the draw-count buffer of a multi-draw.
    max_draw_count: u32 = 0,
    draw_count_buffer: commands.Ref = null,
    draw_count_offset: u64 = 0,
};

/// A run of indirect draws Dawn would validate in one batch. The port leaves
/// the list empty; see the file header.
pub const ValidationBatch = struct {
    /// The pipeline the batch was recorded against.
    pipeline: commands.Ref = null,
    draws: std.ArrayList(IndirectDraw) = .empty,
    allocator: std.mem.Allocator,
};

/// Every indirect draw one pass issued (`IndirectDrawMetadata.h:63-93`).
pub const IndirectDrawMetadata = struct {
    allocator: std.mem.Allocator,
    draws: std.ArrayList(IndirectDraw) = .empty,
    batches: std.ArrayList(ValidationBatch) = .empty,
    next_draw_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) IndirectDrawMetadata {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IndirectDrawMetadata) void {
        for (self.batches.items) |*batch| batch.draws.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.draws.deinit(self.allocator);
        self.* = undefined;
    }

    /// Dawn's `AddIndirectDraw` (`IndirectDrawMetadata.cpp:281-300`).
    pub fn addIndirectDraw(
        self: *IndirectDrawMetadata,
        buffer: commands.Ref,
        offset: u64,
        indexed: bool,
    ) std.mem.Allocator.Error!void {
        try self.draws.append(self.allocator, .{
            .index = self.next_draw_index,
            .buffer = buffer,
            .offset = offset,
            .indexed = indexed,
        });
        self.next_draw_index += 1;
    }

    /// Dawn's `AddIndexedIndirectDraw` (`IndirectDrawMetadata.cpp:242-279`).
    /// It records no base vertex: Dawn keeps the base vertex inside the
    /// indirect arguments, and the port discards the parameter too.
    pub fn addIndexedIndirectDraw(
        self: *IndirectDrawMetadata,
        buffer: commands.Ref,
        offset: u64,
        base_vertex: i32,
        first_instance: u32,
    ) std.mem.Allocator.Error!void {
        try self.draws.append(self.allocator, .{
            .index = self.next_draw_index,
            .buffer = buffer,
            .offset = offset,
            .indexed = true,
            .first_instance = first_instance,
        });
        self.next_draw_index += 1;
        _ = base_vertex;
    }

    /// Dawn's `AddMultiDrawIndirect` (`IndirectDrawMetadata.cpp:306-315`) and
    /// its indexed sibling (`:317-336`). Dawn records the max draw count and
    /// the draw-count buffer; the port records them so the replay knows the
    /// range it must read back.
    pub fn addMultiDrawIndirect(
        self: *IndirectDrawMetadata,
        buffer: commands.Ref,
        offset: u64,
        indexed: bool,
        max_draw_count: u32,
        draw_count_buffer: commands.Ref,
        draw_count_offset: u64,
    ) std.mem.Allocator.Error!void {
        try self.draws.append(self.allocator, .{
            .index = self.next_draw_index,
            .buffer = buffer,
            .offset = offset,
            .indexed = indexed,
            .multi = true,
            .max_draw_count = max_draw_count,
            .draw_count_buffer = draw_count_buffer,
            .draw_count_offset = draw_count_offset,
        });
        self.next_draw_index += 1;
    }

    /// Dawn's `AddBundle` (`IndirectDrawMetadata.cpp:221-240`): every draw in
    /// the bundle joins this pass's list, renumbered so the indices are dense.
    pub fn addBundle(
        self: *IndirectDrawMetadata,
        bundle: *const IndirectDrawMetadata,
    ) std.mem.Allocator.Error!void {
        // `bundle.draws` and `self.draws` are two lists today, but the append
        // below reallocates whichever one it grows and a caller that passed the
        // same metadata twice would walk freed storage. The count is taken
        // first and each draw is read back from the list by index, so the walk
        // ends at the length the bundle had on entry either way.
        const draw_count = bundle.draws.items.len;
        var draw_index: usize = 0;
        while (draw_index < draw_count) : (draw_index += 1) {
            var copy = bundle.draws.items[draw_index];
            copy.index = self.next_draw_index;
            try self.draws.append(self.allocator, copy);
            self.next_draw_index += 1;
        }
    }

    /// Dawn's `GetBatches` (`IndirectDrawMetadata.cpp:151-154`). The port's
    /// list is always empty, because the batching belonged to the GPU-side
    /// validation this module does not port.
    pub fn getBatches(self: *const IndirectDrawMetadata) []const ValidationBatch {
        return self.batches.items;
    }

    pub fn drawCount(self: *const IndirectDrawMetadata) usize {
        return self.draws.items.len;
    }

    /// The one rule this module raises on its own. An indirect draw whose
    /// buffer is smaller than the arguments it reads is caught here rather
    /// than by the replay, because the port records the sizes.
    pub fn validateIndirectBufferSize(
        buffer_size: u64,
        offset: u64,
        required_size: u64,
    ) errors.Error!void {
        if (offset + required_size > buffer_size) return error.IndirectBufferTooSmall;
    }
};
