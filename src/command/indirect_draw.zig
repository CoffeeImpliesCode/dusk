//! Indirect argument locations and selected index-range snapshots.
//! The native sanitizer consumes checked batch ranges into the one draws array.
//! GPU firstInstance and baseVertex stay in the GPU argument buffer.

const std = @import("std");
const commands = @import("commands.zig");
const errors = @import("errors.zig");

pub const max_draw_count: u32 = 1 << 24;
pub const max_batch_draws: u32 = 64;

pub const IndexBufferRange = struct {
    buffer: commands.Ref,
    offset: u64,
    size: u64,
    format: commands.IndexFormat,
};

pub const MultiDrawOptions = struct {
    buffer: commands.Ref,
    offset: u64,
    max_draw_count: u32,
    draw_count_buffer: commands.Ref = null,
    draw_count_offset: u64 = 0,
    index_buffer: ?IndexBufferRange = null,
};

pub const IndirectDraw = struct {
    /// Dense indirect-command ordinal, including expanded bundle bodies.
    index: u32 = 0,
    buffer: commands.Ref = null,
    offset: u64 = 0,
    indexed: bool = false,
    multi: bool = false,
    max_draw_count: u32 = 1,
    draw_count_buffer: commands.Ref = null,
    draw_count_offset: u64 = 0,
    index_buffer: commands.Ref = null,
    index_buffer_offset: u64 = 0,
    index_buffer_size: u64 = 0,
    index_format: commands.IndexFormat = .undefined_,
    index_element_count: u64 = 0,
};

/// A contiguous bounded range into IndirectDrawMetadata.draws.
/// Native replay partitions these further at actual aligned descriptor limits.
pub const ValidationBatch = struct {
    buffer: commands.Ref,
    draw_count_buffer: commands.Ref,
    first_draw: u32,
    draw_count: u32,
};

pub const IndirectDrawMetadata = struct {
    allocator: std.mem.Allocator,
    draws: std.ArrayList(IndirectDraw) = .empty,
    batches: std.ArrayList(ValidationBatch) = .empty,
    next_draw_index: u32 = 0,
    draw_slot_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) IndirectDrawMetadata {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IndirectDrawMetadata) void {
        self.batches.deinit(self.allocator);
        self.draws.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addIndirectDraw(
        self: *IndirectDrawMetadata,
        buffer: commands.Ref,
        offset: u64,
    ) errors.Error!void {
        try self.addDraw(.{ .buffer = buffer, .offset = offset });
    }

    pub fn addIndexedIndirectDraw(
        self: *IndirectDrawMetadata,
        buffer: commands.Ref,
        offset: u64,
        selected: IndexBufferRange,
    ) errors.Error!void {
        var draw: IndirectDraw = .{ .buffer = buffer, .offset = offset };
        try captureIndexRange(&draw, selected);
        try self.addDraw(draw);
    }

    pub fn addMultiDrawIndirect(
        self: *IndirectDrawMetadata,
        options: MultiDrawOptions,
    ) errors.Error!void {
        var draw: IndirectDraw = .{
            .buffer = options.buffer,
            .offset = options.offset,
            .multi = true,
            .max_draw_count = options.max_draw_count,
            .draw_count_buffer = options.draw_count_buffer,
            .draw_count_offset = options.draw_count_offset,
        };
        if (options.index_buffer) |selected| try captureIndexRange(&draw, selected);
        try self.addDraw(draw);
    }

    fn captureIndexRange(draw: *IndirectDraw, selected: IndexBufferRange) errors.Error!void {
        const element_size: u64 = switch (selected.format) {
            .uint16 => 2,
            .uint32 => 4,
            .undefined_ => return error.MissingIndexBuffer,
        };
        if (selected.buffer == null) return error.MissingIndexBuffer;
        if (selected.offset > std.math.maxInt(u64) - selected.size or
            selected.offset % element_size != 0 or selected.size % element_size != 0)
        {
            return error.DrawIndexCount;
        }
        draw.indexed = true;
        draw.index_buffer = selected.buffer;
        draw.index_buffer_offset = selected.offset;
        draw.index_buffer_size = selected.size;
        draw.index_format = selected.format;
        draw.index_element_count = @divExact(selected.size, element_size);
    }

    fn validateDraw(draw: IndirectDraw) errors.Error!void {
        if (draw.max_draw_count > max_draw_count) return error.LimitExceeded;
        const stride: u64 = if (draw.indexed) 20 else 16;
        try validateIndirectBufferSize(
            std.math.maxInt(u64),
            draw.offset,
            stride * draw.max_draw_count,
        );
        if (draw.draw_count_buffer != null) {
            try validateIndirectBufferSize(std.math.maxInt(u64), draw.draw_count_offset, 4);
        }
    }

    fn extendsBatch(batch: ValidationBatch, draw: IndirectDraw) bool {
        return batch.draw_count < max_batch_draws and batch.buffer == draw.buffer and
            batch.draw_count_buffer == draw.draw_count_buffer;
    }

    fn addDraw(self: *IndirectDrawMetadata, draw: IndirectDraw) errors.Error!void {
        try validateDraw(draw);
        if (self.next_draw_index >= max_draw_count or
            draw.max_draw_count > max_draw_count - self.draw_slot_count)
        {
            return error.LimitExceeded;
        }
        const new_batch = self.batches.items.len == 0 or
            !extendsBatch(self.batches.items[self.batches.items.len - 1], draw);
        try self.draws.ensureUnusedCapacity(self.allocator, 1);
        if (new_batch) try self.batches.ensureUnusedCapacity(self.allocator, 1);
        self.appendReserved(draw);
    }

    fn appendReserved(self: *IndirectDrawMetadata, source: IndirectDraw) void {
        var draw = source;
        draw.index = self.next_draw_index;
        if (self.batches.items.len > 0 and
            extendsBatch(self.batches.items[self.batches.items.len - 1], draw))
        {
            self.batches.items[self.batches.items.len - 1].draw_count += 1;
        } else {
            self.batches.appendAssumeCapacity(.{
                .buffer = draw.buffer,
                .draw_count_buffer = draw.draw_count_buffer,
                .first_draw = self.next_draw_index,
                .draw_count = 1,
            });
        }
        self.draws.appendAssumeCapacity(draw);
        self.next_draw_index += 1;
        self.draw_slot_count += draw.max_draw_count;
    }

    /// Capacity planning precedes mutation, including when bundle == self.
    pub fn addBundle(
        self: *IndirectDrawMetadata,
        bundle: *const IndirectDrawMetadata,
    ) errors.Error!void {
        const count = bundle.draws.items.len;
        if (count > max_draw_count - self.next_draw_index) return error.LimitExceeded;
        var slots = self.draw_slot_count;
        var extra_batches: usize = 0;
        var last: ?ValidationBatch = if (self.batches.items.len == 0) null else self.batches.items[self.batches.items.len - 1];
        for (bundle.draws.items) |draw| {
            try validateDraw(draw);
            if (draw.max_draw_count > max_draw_count - slots) return error.LimitExceeded;
            slots += draw.max_draw_count;
            if (last != null and extendsBatch(last.?, draw)) {
                last.?.draw_count += 1;
            } else {
                extra_batches += 1;
                last = .{
                    .buffer = draw.buffer,
                    .draw_count_buffer = draw.draw_count_buffer,
                    .first_draw = 0,
                    .draw_count = 1,
                };
            }
        }
        try self.draws.ensureUnusedCapacity(self.allocator, count);
        try self.batches.ensureUnusedCapacity(self.allocator, extra_batches);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            self.appendReserved(bundle.draws.items[index]);
        }
    }

    pub fn getBatches(self: *const IndirectDrawMetadata) []const ValidationBatch {
        return self.batches.items;
    }

    pub fn drawCount(self: *const IndirectDrawMetadata) usize {
        return self.draws.items.len;
    }

    pub fn validateIndirectBufferSize(
        buffer_size: u64,
        offset: u64,
        required_size: u64,
    ) errors.Error!void {
        if (offset > buffer_size or required_size > buffer_size - offset) {
            return error.IndirectBufferTooSmall;
        }
    }
};

test "indexed metadata snapshots the selected range for each index width" {
    var arguments: u8 = 0;
    var indices: u8 = 0;
    var metadata = IndirectDrawMetadata.init(std.testing.allocator);
    defer metadata.deinit();
    try metadata.addIndexedIndirectDraw(&arguments, 4, .{
        .buffer = &indices,
        .offset = 8,
        .size = 10,
        .format = .uint16,
    });
    try metadata.addIndexedIndirectDraw(&arguments, 24, .{
        .buffer = &indices,
        .offset = 20,
        .size = 12,
        .format = .uint32,
    });
    const first = metadata.draws.items[0];
    try std.testing.expectEqual(@as(commands.Ref, &indices), first.index_buffer);
    try std.testing.expectEqual(@as(u64, 8), first.index_buffer_offset);
    try std.testing.expectEqual(@as(u64, 10), first.index_buffer_size);
    try std.testing.expectEqual(commands.IndexFormat.uint16, first.index_format);
    try std.testing.expectEqual(@as(u64, 5), first.index_element_count);
    try std.testing.expectEqual(@as(u64, 3), metadata.draws.items[1].index_element_count);
}

test "batches are bounded nonoverlapping ranges into the sole draws array" {
    var first_buffer: u8 = 0;
    var second_buffer: u8 = 0;
    var metadata = IndirectDrawMetadata.init(std.testing.allocator);
    defer metadata.deinit();
    for (0..max_batch_draws + 1) |index| {
        try metadata.addIndirectDraw(&first_buffer, index * 16);
    }
    try metadata.addIndirectDraw(&second_buffer, 0);
    const batches = metadata.getBatches();
    try std.testing.expectEqual(@as(usize, 3), batches.len);
    var next: u32 = 0;
    for (batches) |batch| {
        try std.testing.expectEqual(next, batch.first_draw);
        try std.testing.expect(batch.draw_count <= max_batch_draws);
        for (metadata.draws.items[batch.first_draw..][0..batch.draw_count]) |draw| {
            try std.testing.expectEqual(batch.buffer, draw.buffer);
        }
        next += batch.draw_count;
    }
    try std.testing.expectEqual(metadata.draws.items.len, @as(usize, next));
}

test "bundle merge densely renumbers and retains selected index snapshots" {
    var token: u8 = 0;
    var bundle = IndirectDrawMetadata.init(std.testing.allocator);
    defer bundle.deinit();
    try bundle.addIndexedIndirectDraw(&token, 0, .{
        .buffer = &token,
        .offset = 16,
        .size = 8,
        .format = .uint16,
    });
    var pass = IndirectDrawMetadata.init(std.testing.allocator);
    defer pass.deinit();
    try pass.addIndirectDraw(&token, 20);
    try pass.addBundle(&bundle);
    try pass.addBundle(&bundle);
    try pass.addBundle(&pass);
    for (pass.draws.items, 0..) |draw, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), draw.index);
        if (index % 3 != 0) {
            try std.testing.expectEqual(@as(u64, 4), draw.index_element_count);
            try std.testing.expectEqual(@as(u64, 16), draw.index_buffer_offset);
        }
    }
    try std.testing.expectEqual(@as(usize, 6), pass.draws.items.len);
}

test "metadata refuses overflowing argument ranges and excessive expanded counts" {
    var metadata = IndirectDrawMetadata.init(std.testing.allocator);
    defer metadata.deinit();
    try std.testing.expectError(error.IndirectBufferTooSmall, IndirectDrawMetadata.validateIndirectBufferSize(
        std.math.maxInt(u64),
        std.math.maxInt(u64) - 3,
        16,
    ));
    try std.testing.expectError(error.LimitExceeded, metadata.addMultiDrawIndirect(.{
        .buffer = null,
        .offset = 0,
        .max_draw_count = max_draw_count + 1,
    }));
    try std.testing.expectError(error.IndirectBufferTooSmall, metadata.addMultiDrawIndirect(.{
        .buffer = null,
        .offset = std.math.maxInt(u64) - 3,
        .max_draw_count = 1,
    }));
    try std.testing.expectEqual(@as(usize, 0), metadata.drawCount());
}

test "fail-N metadata append and bundle merge preserve logical rollback" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, metadataRollback, .{});
}

fn metadataRollback(allocator: std.mem.Allocator) !void {
    var token: u8 = 0;
    var bundle = IndirectDrawMetadata.init(std.testing.allocator);
    defer bundle.deinit();
    for (0..max_batch_draws + 1) |index| {
        try bundle.addIndirectDraw(&token, index * 16);
    }
    var destination = IndirectDrawMetadata.init(allocator);
    defer destination.deinit();
    destination.addIndirectDraw(&token, 0) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), destination.drawCount());
        try std.testing.expectEqual(@as(usize, 0), destination.getBatches().len);
        try std.testing.expectEqual(@as(u32, 0), destination.next_draw_index);
        return err;
    };
    const old_count = destination.drawCount();
    const old_batch = destination.getBatches()[0];
    destination.addBundle(&bundle) catch |err| {
        try std.testing.expectEqual(old_count, destination.drawCount());
        try std.testing.expectEqual(@as(usize, 1), destination.getBatches().len);
        try std.testing.expectEqualDeep(old_batch, destination.getBatches()[0]);
        try std.testing.expectEqual(@as(u32, 1), destination.next_draw_index);
        return err;
    };
}
