//! What every pass encoder can do: the debug-group stack, bind groups, and
//! immediates.
//!
//! **What this file is.** The port of
//! `src/dawn/native/ProgrammableEncoder.{h,cpp}`. It is the shared half of
//! `RenderPassEncoder` and `ComputePassEncoder` — Dawn's
//! `ProgrammableEncoder` (`ProgrammableEncoder.h:47`) — and it holds the two
//! places Dawn splits validation from recording explicitly
//! (`ProgrammableEncoder.cpp:226-242` and `:244-259`).
//!
//! **What this file does not claim.** It does not claim the pass encoders
//! share a base class at run time. Zig has no inheritance, so
//! `RenderEncoderBase` and `ComputePassEncoder` each hold a `ProgrammableEncoder`
//! as a field and forward; that is the same shape as Dawn's with the virtual
//! call replaced by a field read.
//!
//! It does not claim `setImmediates` keeps Dawn's three-argument form. Dawn
//! takes `(offset, data, size)` where `size` counts four-byte elements and
//! `data` may be a longer scratch buffer (`dawn.json` "render pass encoder"
//! "set immediates", generated at `src/api/objects.zig:884`). The port takes
//! the exact bytes to write, because the caller here is `engine` and not a C
//! ABI, and a third argument the port ignores would be a parameter a reader
//! has to prove unused.
const commands = @import("commands.zig");
const std = @import("std");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const state_tracker = @import("state_tracker.zig");
const usage = @import("usage.zig");

/// What `setBindGroup` takes. Every field beyond the group itself is something
/// only the caller can read, recorded at set time so no rule has to reach into
/// the group later.
pub const SetBindGroupOptions = struct {
    index: u32,
    group: commands.Ref,
    /// The dynamic offsets, copied into the stream behind the payload. Dawn
    /// writes them only when the count is above zero
    /// (`src/dawn/native/ProgrammableEncoder.cpp:236-238`).
    dynamic_offset_count: u32 = 0,
    dynamic_offsets: []const u32 = &.{},
    /// The identity of the group's layout, compared against the pipeline's.
    layout_id: u64 = 0,
    /// The smallest buffer any binding in this group names, for the undersized
    /// binding rule (`CommandBufferStateTracker.cpp:545-547`).
    min_binding_buffer_size: u64 = 0,
    /// The texture bindings, for the compatibility-mode view rule.
    texture_bindings: []const state_tracker.TextureBinding = &.{},
    buffers: []const usage.BindGroupBuffer = &.{},
    textures: []const usage.BindGroupTexture = &.{},
    external_textures: []const commands.Ref = &.{},
    resource_table: commands.Ref = null,
};

/// What `setImmediates` takes. See the file header on Dawn's third argument.
pub const SetImmediatesOptions = struct {
    offset: u32,
    data: []const u8,
};

/// Where the resources a bind group names are recorded. Dawn's two trackers are
/// distinct types with a shared base (`PassResourceUsageTracker.h:51-138`); the
/// port holds one of the two rather than a virtual base, and a caller that
/// names neither records nothing — which is what a bundle does, because a
/// bundle's usages are merged into the executing pass's
/// (`PassResourceUsage.h:104-106`).
pub const UsageSink = struct {
    render: ?*usage.RenderPassResourceUsageTracker = null,
    compute: ?*usage.ComputePassResourceUsageTracker = null,

    pub fn addBindGroup(
        self: UsageSink,
        resources: usage.BindGroupResources,
    ) std.mem.Allocator.Error!void {
        if (self.render) |render| {
            try render.addBindGroupResources(resources);
            return;
        }
        if (self.compute) |compute| {
            for (resources.buffers) |entry| {
                try compute.addReferencedBuffer(entry.buffer);
            }
            for (resources.textures) |entry| {
                try compute.addReferencedTexture(entry.texture);
            }
            for (resources.external_textures) |texture| {
                try compute.addReferencedExternalTexture(texture);
            }
            if (resources.resource_table != null) {
                try compute.addReferencedResourceTable(resources.resource_table);
            }
        }
    }
};

/// The shared half of every pass encoder.
pub const ProgrammableEncoder = struct {
    context: *encoding_context.Context,
    /// Which encoder this is, for the identity check. Dawn compares the
    /// `ApiObjectBase*` (`EncodingContext.h:150`); see the file header for why
    /// the port issues an id instead.
    id: encoding_context.EncoderId,
    allocator: std.mem.Allocator,
    /// Dawn's `mEnded` (`ProgrammableEncoder.h:86`).
    ended: bool = false,
    /// Groups open on the parent are outside this encoder's stack.
    initial_debug_depth: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *encoding_context.Context,
    ) ProgrammableEncoder {
        return .{
            .context = context,
            .id = context.enterPass(),
            .allocator = allocator,
            .initial_debug_depth = context.debugGroupDepth(),
        };
    }

    /// Dawn's `ValidateProgrammableEncoderEnd`
    /// (`ProgrammableEncoder.cpp:74-79`): a debug group left open is a
    /// validation error at `end`, not at `finish`. Dawn reports it through the
    /// error sink; the port returns it, because the caller is `engine` and
    /// owns the sink.
    pub fn validateProgrammableEncoderEnd(self: *const ProgrammableEncoder) errors.Error!void {
        if (self.context.debugGroupDepth() != self.initial_debug_depth) {
            return error.DebugGroupUnbalanced;
        }
    }

    /// Dawn's `ValidateSetBindGroup` (`ProgrammableEncoder.cpp:146-224`). The
    /// receiver is `_` because every rule here reads the options alone.
    pub fn validateSetBindGroup(
        _: *const ProgrammableEncoder,
        options: SetBindGroupOptions,
    ) errors.Error!void {
        if (options.index >= constants.max_bind_groups) return error.BindGroupIndexOutOfRange;
        if (options.dynamic_offset_count != options.dynamic_offsets.len) {
            return error.SliceLengthMismatch;
        }
    }

    /// Dawn's `RecordSetBindGroup` (`ProgrammableEncoder.cpp:226-242`). Dawn
    /// writes no dynamic-offset run at all when the count is zero, so `skip`
    /// must not look for one; `commands.skip` reads the count off the payload.
    ///
    /// `errors.Error` is what `encode` declares (`encoding_context.zig:182`): a
    /// lifecycle rule of `core.Error`'s, or `OutOfMemory` (`allocator.zig:184`).
    pub fn recordSetBindGroup(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        sink: UsageSink,
        options: SetBindGroupOptions,
    ) errors.Error!void {
        const cmd = try self.context.encode(
            commands.SetBindGroupCmd,
            self.id,
            .set_bind_group,
        );
        cmd.* = .{ .index = options.index, .group = options.group };
        cmd.dynamic_offset_count = @intCast(options.dynamic_offsets.len);
        // Dawn guards the same call with a zero-count test (ProgrammableEncoder.cpp:236-241):
        // the counted run is written only above zero, so a bind group with no dynamic
        // offsets leaves nothing behind for `commands.skip` to consume.
        if (options.dynamic_offsets.len != 0) {
            const out = try self.context.encodeData(u32, options.dynamic_offsets.len);
            @memcpy(out, options.dynamic_offsets);
        }
        tracker.setBindGroup(options.index, .{
            .group = options.group,
            .layout_id = options.layout_id,
            .min_binding_buffer_size = options.min_binding_buffer_size,
            .texture_bindings = options.texture_bindings,
        });
        try sink.addBindGroup(.{
            .buffers = options.buffers,
            .textures = options.textures,
            .external_textures = options.external_textures,
            .resource_table = options.resource_table,
        });
    }

    /// `setBindGroup` is validate-then-record in one call, because Dawn's
    /// `APISetBindGroup` is (`ComputePassEncoder.cpp:544-568`).
    pub fn setBindGroup(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        sink: UsageSink,
        options: SetBindGroupOptions,
    ) errors.Error!void {
        try self.validateSetBindGroup(options);
        try self.recordSetBindGroup(tracker, sink, options);
    }

    /// Dawn's `ValidateSetImmediates` (`ProgrammableEncoder.cpp:130-144`). The
    /// receiver is `_` because every rule here reads the options alone.
    pub fn validateSetImmediates(
        _: *const ProgrammableEncoder,
        options: SetImmediatesOptions,
    ) errors.Error!void {
        if (options.offset % constants.immediate_element_byte_size != 0 or
            options.data.len % constants.immediate_element_byte_size != 0)
        {
            return error.ImmediateDataUnaligned;
        }
        if (options.offset > constants.max_immediate_data_bytes) return error.ImmediateDataTooLarge;
        if (options.data.len > constants.max_immediate_data_bytes - options.offset) {
            return error.ImmediateDataTooLarge;
        }
    }

    /// Dawn's `RecordSetImmediates` (`ProgrammableEncoder.cpp:244-259`). Dawn
    /// records nothing for an empty payload (`ProgrammableEncoder.cpp:248-250`)
    /// and the port keeps that: a zero-length run behind a tag is a tag a
    /// reader would have to special-case. The set is `errors.Error`, which is
    /// what `encode` declares (`encoding_context.zig:182`); the append adds no
    /// more.
    pub fn recordSetImmediates(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        options: SetImmediatesOptions,
    ) errors.Error!void {
        try self.validateSetImmediates(options);
        if (options.data.len == 0) return;
        try self.context.validateCanEncodeOn(self.id, false);
        const record = try self.context.pendingAllocator().allocateCommandWithData(
            commands.SetImmediatesCmd,
            @intFromEnum(commands.Tag.set_immediates),
            options.data.len,
        );
        record.command.* = .{ .offset = options.offset, .size = @intCast(options.data.len) };
        @memcpy(record.data, options.data);
        // Validation above proves this infallible. Commit only after the complete record exists.
        tracker.setImmediateData(options.offset, options.data) catch unreachable;
    }

    pub fn setImmediates(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        options: SetImmediatesOptions,
    ) errors.Error!void {
        try self.recordSetImmediates(tracker, options);
    }

    /// Dawn's `APIPushDebugGroup` (`ProgrammableEncoder.cpp:112-128`).
    pub fn pushDebugGroup(self: *ProgrammableEncoder, label: []const u8) errors.Error!void {
        const cmd = try self.context.encode(
            commands.PushDebugGroupCmd,
            self.id,
            .push_debug_group,
        );
        errdefer self.context.status = .error_in_recording;
        var length: u32 = 0;
        try commands.addNullTerminatedString(self.context.pendingAllocator(), label, &length);
        cmd.* = .{ .length = length };
        try self.context.pushDebugGroupLabel(label);
    }

    /// Dawn's `APIPopDebugGroup` (`ProgrammableEncoder.cpp:95-110`).
    pub fn popDebugGroup(self: *ProgrammableEncoder) errors.Error!void {
        try self.context.validateCanEncodeOn(self.id, false);
        if (self.context.debugGroupDepth() <= self.initial_debug_depth) {
            return error.DebugGroupUnbalanced;
        }
        _ = try self.context.encode(commands.PopDebugGroupCmd, self.id, .pop_debug_group);
        try self.context.popDebugGroupLabel();
    }

    /// Dawn's `APIInsertDebugMarker` (`ProgrammableEncoder.cpp:81-93`).
    pub fn insertDebugMarker(self: *ProgrammableEncoder, label: []const u8) errors.Error!void {
        const cmd = try self.context.encode(
            commands.InsertDebugMarkerCmd,
            self.id,
            .insert_debug_marker,
        );
        errdefer self.context.status = .error_in_recording;
        var length: u32 = 0;
        try commands.addNullTerminatedString(self.context.pendingAllocator(), label, &length);
        cmd.* = .{ .length = length };
    }
};

const ImmediateFixture = struct {
    mutex: std.Io.Mutex = .init,
    device: @import("../core/root.zig").Device = undefined,
    context: encoding_context.Context = undefined,

    fn init(self: *ImmediateFixture, allocator: std.mem.Allocator) errors.Error!void {
        const core = @import("../core/root.zig");
        self.device = core.Device.init(allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = unexpectedError,
        });
        self.context = try encoding_context.Context.init(allocator, self.device.borrow(), 4096, false);
        _ = self.context.open();
    }

    fn unexpectedError(
        _: std.mem.Allocator,
        _: std.Io,
        _: *anyopaque,
        _: @import("../core/errors.zig").ErrorView,
    ) void {
        @panic("unexpected immediate fixture device error");
    }

    fn deinit(self: *ImmediateFixture, allocator: std.mem.Allocator) void {
        const core = @import("../core/root.zig");
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, self.device.arena.objectList());
        defer guard.unlock(std.testing.io);
        self.context.deinit(std.testing.io, &guard);
        self.device.deinit(allocator, &guard) catch @panic("immediate fixture references leaked");
    }
};

test "programmable immediates record full256 and word63 at their user offsets" {
    var fixture: ImmediateFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var encoder = ProgrammableEncoder.init(std.testing.allocator, &fixture.context);
    var tracker = state_tracker.Tracker.init(std.testing.allocator, false);
    var full_data: [256]u8 = undefined;
    for (&full_data, 0..) |*byte, index| byte.* = @intCast(index);
    try encoder.setImmediates(&tracker, .{ .offset = 0, .data = &full_data });
    const upper_word = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try encoder.setImmediates(&tracker, .{ .offset = 252, .data = &upper_word });
    try std.testing.expectEqual(std.math.maxInt(u64), tracker.immediate_data_mask);
    try std.testing.expectEqualSlices(u8, full_data[0..252], tracker.immediate_data[0..252]);
    try std.testing.expectEqualSlices(u8, &upper_word, tracker.immediate_data[252..256]);

    const stream = @import("allocator.zig");
    var iterator = stream.Iterator.init(std.testing.allocator, fixture.context.pending.blocks);
    try std.testing.expectEqual(commands.Tag.set_immediates, (try iterator.nextTag()).?);
    const first = try iterator.nextCommand(commands.SetImmediatesCmd);
    try std.testing.expectEqual(@as(u32, 0), first.offset);
    try std.testing.expectEqual(@as(u32, 256), first.size);
    try std.testing.expectEqualSlices(u8, &full_data, try iterator.nextData(u8, 256));
    try std.testing.expectEqual(commands.Tag.set_immediates, (try iterator.nextTag()).?);
    const second = try iterator.nextCommand(commands.SetImmediatesCmd);
    try std.testing.expectEqual(@as(u32, 252), second.offset);
    try std.testing.expectEqual(@as(u32, 4), second.size);
    try std.testing.expectEqualSlices(u8, &upper_word, try iterator.nextData(u8, 4));
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}

test "programmable immediate validation refuses alignment and overflowing ranges without recording" {
    var fixture: ImmediateFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var encoder = ProgrammableEncoder.init(std.testing.allocator, &fixture.context);
    var tracker = state_tracker.Tracker.init(std.testing.allocator, false);
    const word = [_]u8{ 1, 2, 3, 4 };
    const excessive: []const u8 = @as([*]const u8, &word)[0 .. std.math.maxInt(usize) - 3];
    const cases = [_]struct { options: SetImmediatesOptions, expected: errors.Error }{
        .{ .options = .{ .offset = 1, .data = &word }, .expected = error.ImmediateDataUnaligned },
        .{ .options = .{ .offset = 0, .data = word[0..3] }, .expected = error.ImmediateDataUnaligned },
        .{ .options = .{ .offset = 256, .data = &word }, .expected = error.ImmediateDataTooLarge },
        .{ .options = .{ .offset = 252, .data = &([_]u8{0} ** 8) }, .expected = error.ImmediateDataTooLarge },
        .{ .options = .{ .offset = 0xffff_fffc, .data = &word }, .expected = error.ImmediateDataTooLarge },
        .{ .options = .{ .offset = 4, .data = excessive }, .expected = error.ImmediateDataTooLarge },
    };
    const initial_data = tracker.immediate_data;
    for (cases) |case| {
        try std.testing.expectError(case.expected, encoder.setImmediates(&tracker, case.options));
        try std.testing.expect(fixture.context.pending.isEmpty());
        try std.testing.expectEqualSlices(u8, &initial_data, &tracker.immediate_data);
        try std.testing.expectEqual(@as(u64, 0), tracker.immediate_data_mask);
    }
    try encoder.setImmediates(&tracker, .{ .offset = 256, .data = &.{} });
    try std.testing.expect(fixture.context.pending.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), tracker.immediate_data_mask);
}

test "programmable immediate allocation failures leave tracker and stream unchanged" {
    var reached_success = false;
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing.allocator();
        var fixture: ImmediateFixture = .{};
        try fixture.init(allocator);
        defer fixture.deinit(allocator);
        var encoder = ProgrammableEncoder.init(allocator, &fixture.context);
        var tracker = state_tracker.Tracker.init(allocator, false);
        tracker.aspects.set(.immediate_data);
        const initial_aspects = tracker.aspects.bits;
        const initial_data = tracker.immediate_data;
        const full_data = [_]u8{0xa5} ** 256;
        if (encoder.setImmediates(&tracker, .{ .offset = 0, .data = &full_data })) |_| {
            try std.testing.expectEqualSlices(u8, &full_data, &tracker.immediate_data);
            try std.testing.expectEqual(std.math.maxInt(u64), tracker.immediate_data_mask);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(fixture.context.pending.isEmpty());
            try std.testing.expectEqualSlices(u8, &initial_data, &tracker.immediate_data);
            try std.testing.expectEqual(@as(u64, 0), tracker.immediate_data_mask);
            try std.testing.expectEqual(initial_aspects, tracker.aspects.bits);
        }
    }
    try std.testing.expect(reached_success);
}

test "programmable immediate rollover failure preserves existing records and the block tail" {
    var reached_success = false;
    for (0..8) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var fixture: ImmediateFixture = .{};
        try fixture.init(allocator);
        defer fixture.deinit(allocator);
        var encoder = ProgrammableEncoder.init(allocator, &fixture.context);
        var tracker = state_tracker.Tracker.init(allocator, false);
        const label = [_]u8{'x'} ** (4096 - 64);
        try encoder.insertDebugMarker(&label);
        var filled_block_count: usize = 1;
        while (fixture.context.pending.blocks.items.len < fixture.context.pending.blocks.capacity and
            filled_block_count < 16) : (filled_block_count += 1)
        {
            try encoder.insertDebugMarker(&label);
        }
        const pending = fixture.context.pendingAllocator();
        try std.testing.expectEqual(pending.blocks.capacity, pending.blocks.items.len);
        const old_index = pending.current_index;
        const old_count = pending.blocks.items.len;
        const old_len = pending.blocks.items[old_index].len;
        const tail = pending.blocks.items[old_index].bytes[old_len..][0..4];
        std.mem.writeInt(u32, tail, 0x1234_5678, .little);
        const saved_bytes = try std.testing.allocator.dupe(
            u8,
            pending.blocks.items[old_index].bytes[0 .. old_len + 4],
        );
        defer std.testing.allocator.free(saved_bytes);
        const initial_word = [_]u8{ 1, 2, 3, 4 };
        try tracker.setImmediateData(16, &initial_word);
        const saved_data = tracker.immediate_data;
        const saved_mask = tracker.immediate_data_mask;
        const full_data = [_]u8{0xa5} ** 256;
        failing.fail_index = failing.alloc_index + fail_offset;
        failing.resize_fail_index = failing.resize_index;
        const recorded = encoder.setImmediates(&tracker, .{ .offset = 0, .data = &full_data });
        failing.fail_index = std.math.maxInt(usize);
        if (recorded) |_| {
            try std.testing.expectEqualSlices(u8, &full_data, &tracker.immediate_data);
            try std.testing.expectEqual(std.math.maxInt(u64), tracker.immediate_data_mask);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(old_index, pending.current_index);
            try std.testing.expectEqual(old_count, pending.blocks.items.len);
            try std.testing.expectEqual(old_len, pending.blocks.items[old_index].len);
            try std.testing.expectEqualSlices(
                u8,
                saved_bytes,
                pending.blocks.items[old_index].bytes[0 .. old_len + 4],
            );
            try std.testing.expectEqualSlices(u8, &saved_data, &tracker.immediate_data);
            try std.testing.expectEqual(saved_mask, tracker.immediate_data_mask);
        }
    }
    try std.testing.expect(reached_success);
}
