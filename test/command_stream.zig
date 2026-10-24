//! The M15 shard: the command stream, decoded.
//!
//! **What this shard asserts.** The first test records a whole
//! render pass — begin, set pipeline, set bind group, set vertex buffer, a draw
//! of three, end — and decodes the stream back, asserting it holds exactly
//! those six commands in that order and nothing else. The second records a
//! draw of four against the same three-vertex buffer and asserts the failure
//! names `DrawVertexCount`.
//!
//! **No Vulkan device is present.** The frontend-only resource references are
//! opaque identities. Canonical attachments and bundles are genuine payloads
//! in a core Device arena, with leases released under its original ObjectGuard.
//! Recording and decoding need no adapter or driver.
//!
//! **What this shard does not claim.** It does not claim the replay is
//! correct: nothing here turns a tag into a Vulkan call. It does not claim
//! the payload layouts match Dawn's, which `commands.zig:10-14` rules out.
//! It decodes
//! with `Iterator.nextCommand` per tag rather than through `commands.skip`
//! because `skip` advances past a payload without interpreting it
//! (`commands.zig:509-515`) and hands nothing back, while the acceptance
//! asserts fields inside the payloads — the pass size, the attachment load
//! op, the pipeline address, the vertex counts — so the walk has to read
//! each one.

const std = @import("std");
const dusk = @import("dusk");

const command = dusk.command;
const core = dusk.core;
const allocator_mod = command.allocator;
const commands = command.commands;
const constants = command.constants;
const encoding_context = command.encoding_context;
const attachment_state = command.attachment_state;
const render_encoder_base = command.render_encoder_base;
const state_tracker = command.state_tracker;

/// The bytes a block of the stream starts at. `Allocator.init` raises this to
/// whatever `BeginRenderPassCmd` needs (`allocator.zig:63-71`), so this is a
/// granularity and not a bound.
const block_size: usize = 1024;

/// The bytes one vertex advances by in the pipeline the pass binds.
const vertex_stride: u32 = 4;

/// The size of the vertex buffer the pass binds. Three vertices at the stride
/// above is the whole buffer, which is what makes a draw of three the last one
/// that fits and a draw of four the first that does not
/// (`state_tracker.zig:461`: `(first_vertex + vertex_count - 1) * stride +
/// last_stride`).
const vertex_buffer_bytes: u64 = 3 * vertex_stride;

/// The identity the pipeline and the bind group agree on
/// (`state_tracker.zig:374`). `command` cannot read a layout, so the caller
/// supplies the id on both sides.
const layout_id: u64 = 0x5EED;

/// One object per thing the pass names.
///
/// The stream stores each address and never reads through it, so these stand
/// in for the arena objects a device would own. They live in one `var` so the
/// addresses outlive the pass and are stable across the calls that record it.
const Objects = struct {
    pipeline: Object = .{},
    bind_group: Object = .{},
    vertex_buffer: Object = .{},
    colour_target: Object = .{},

    const Object = struct { bytes: [8]u8 = @splat(0) };
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    device: core.Device,
    guard: core.ObjectGuard,
    attachment: *attachment_state.CanonicalAttachmentState,
    user_alias_held: bool = true,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .device = undefined,
            .guard = undefined,
            .attachment = undefined,
        };
        self.device = core.Device.init(allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = unexpectedError,
        });
        self.guard = core.ObjectGuard.lockUncancelable(std.testing.io, self.device.borrow().objects);
        errdefer self.guard.unlock(std.testing.io);
        errdefer self.device.deinit(allocator, &self.guard) catch @panic("fixture rollback failed");
        self.device.bindTrackingOwner(&self.guard, self);
        var value: attachment_state.AttachmentState = .{};
        value.color_attachments_set = 1;
        value.color_formats[0] = @backingInt(dusk.api.TextureFormat.rgba8_unorm);
        try value.validateCanonical();
        self.attachment = try self.device.create(
            allocator,
            &self.guard,
            attachment_state.CanonicalAttachmentState,
            .{ .kind = .attachment_state, .initial_reference = .user },
        );
        self.attachment.value = value;
        self.attachment.cache_hash = 0;
        self.attachment.cache_next = null;
        self.attachment.header.attach(&self.guard, std.testing.io);
    }

    fn deinit(self: *Fixture) void {
        if (self.user_alias_held) {
            self.attachment.header.releaseUserLocked(&self.guard, std.testing.io) catch
                @panic("fixture attachment alias release failed");
        }
        self.device.deinit(self.allocator, &self.guard) catch @panic("fixture reference leaked");
        self.guard.unlock(std.testing.io);
    }

    fn unexpectedError(
        _: std.mem.Allocator,
        _: std.Io,
        _: *anyopaque,
        _: core.ErrorView,
    ) void {
        @panic("unexpected frontend fixture error");
    }
};

test "the tag enum preserves Dawn tags and appends browser utility intents" {
    try std.testing.expectEqual(@as(usize, 40), commands.tag_count);
    try std.testing.expectEqual(@as(u32, 37), @backingInt(commands.Tag.write_timestamp));
    try std.testing.expectEqual(@as(u32, 38), @backingInt(commands.Tag.copy_texture_for_browser));
    try std.testing.expectEqual(@as(u32, 39), @backingInt(commands.Tag.copy_external_texture_for_browser));
}

test "empty public write and bundle runs preserve following commands" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    try encoder.writeBuffer(.{ .buffer = null, .offset = 0, .data = &.{} });
    var pass = try encoder.beginRenderPass(std.testing.io, &fixture.guard, fixture.attachment, .{});
    defer pass.deinit(std.testing.io, &fixture.guard);
    try pass.executeBundles(&fixture.guard, &.{});
    try pass.setStencilReference(7);
    try pass.end(std.testing.io, &fixture.guard);
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();
    try expectTag(&iterator.iterator, .write_buffer);
    try commands.skip(&iterator.iterator, .write_buffer);
    try expectTag(&iterator.iterator, .begin_render_pass);
    try commands.skip(&iterator.iterator, .begin_render_pass);
    try expectTag(&iterator.iterator, .execute_bundles);
    try commands.skip(&iterator.iterator, .execute_bundles);
    try expectTag(&iterator.iterator, .set_stencil_reference);
    try commands.skip(&iterator.iterator, .set_stencil_reference);
    try expectTag(&iterator.iterator, .end_render_pass);
    try commands.skip(&iterator.iterator, .end_render_pass);
    try std.testing.expect(try iterator.nextTag() == null);
}

test "finished render usage records canonical vertex and index flags" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var vertex: u8 = 0;
    var index: u8 = 0;
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var pass = try encoder.beginRenderPass(std.testing.io, &fixture.guard, fixture.attachment, .{});
    defer pass.deinit(std.testing.io, &fixture.guard);
    try pass.setVertexBuffer(.{ .slot = 0, .buffer = &vertex, .buffer_size = 16 });
    try pass.setIndexBuffer(.{ .buffer = &index, .buffer_size = 16, .format = .uint16 });
    try pass.end(std.testing.io, &fixture.guard);
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    const scope = &finished.render_pass_usages.items[0].scope;
    try std.testing.expectEqualSlices(commands.Ref, &.{ &vertex, &index }, scope.buffers.items);
    try std.testing.expectEqual(
        (dusk.api.BufferUsage{ .vertex = true }).toFlags(),
        scope.buffer_sync_infos.items[0].usage,
    );
    try std.testing.expectEqual(
        (dusk.api.BufferUsage{ .index = true }).toFlags(),
        scope.buffer_sync_infos.items[1].usage,
    );
}

test "finished render bindings preserve usage and stages across groups and bundles" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var buffer: u8 = 0;
    var fallback: u8 = 0;
    var group: u8 = 0;
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var bundle_encoder = try command.render_bundle.RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &fixture.guard,
        &fixture.device,
        fixture.attachment,
        .{},
    );
    defer bundle_encoder.deinit(std.testing.io, &fixture.guard);
    try bundle_encoder.setBindGroup(.{
        .index = 0,
        .group = &group,
        .buffers = &.{.{
            .buffer = &buffer,
            .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags(),
            .shader_stages = (dusk.api.ShaderStage{ .fragment = true }).toFlags(),
        }},
    });
    const bundle = try bundle_encoder.finish(std.testing.io, &fixture.guard);
    defer bundle.header.releaseUserLocked(&fixture.guard, std.testing.io) catch
        @panic("bundle alias release failed");
    var pass = try encoder.beginRenderPass(std.testing.io, &fixture.guard, fixture.attachment, .{});
    defer pass.deinit(std.testing.io, &fixture.guard);
    try pass.setBindGroup(.{
        .index = 0,
        .group = &group,
        .buffers = &.{
            .{
                .buffer = &buffer,
                .usage = (dusk.api.BufferUsage{ .uniform = true }).toFlags(),
                .shader_stages = (dusk.api.ShaderStage{ .vertex = true }).toFlags(),
            },
            .{ .buffer = &fallback, .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags() },
        },
    });
    try pass.executeBundles(&fixture.guard, &.{bundle});
    try pass.end(std.testing.io, &fixture.guard);
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    const scope = &finished.render_pass_usages.items[0].scope;
    try std.testing.expectEqualSlices(commands.Ref, &.{ &buffer, &fallback }, scope.buffers.items);
    const render_stages = (dusk.api.ShaderStage{ .vertex = true, .fragment = true }).toFlags();
    try std.testing.expectEqual(
        (dusk.api.BufferUsage{ .uniform = true, .storage = true }).toFlags(),
        scope.buffer_sync_infos.items[0].usage,
    );
    try std.testing.expectEqual(render_stages, scope.buffer_sync_infos.items[0].shader_stages);
    try std.testing.expectEqual(
        (dusk.api.BufferUsage{ .storage = true }).toFlags(),
        scope.buffer_sync_infos.items[1].usage,
    );
    try std.testing.expectEqual(render_stages, scope.buffer_sync_infos.items[1].shader_stages);
}

test "finished inline indirect draws retain argument and count buffer usage" {
    inline for (.{ false, true }) |indexed| {
        var fixture: Fixture = undefined;
        try fixture.init(std.testing.allocator);
        defer fixture.deinit();
        var pipeline: u8 = 0;
        var index: u8 = 0;
        var args: u8 = 0;
        var multi_args: u8 = 0;
        var count: u8 = 0;
        var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
        defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
        var pass = try encoder.beginRenderPass(std.testing.io, &fixture.guard, fixture.attachment, .{});
        defer pass.deinit(std.testing.io, &fixture.guard);
        try pass.setPipeline(&fixture.guard, .{
            .pipeline = &pipeline,
            .requirements = .{},
            .attachment_state = fixture.attachment,
        });
        if (indexed) try pass.setIndexBuffer(.{ .buffer = &index, .buffer_size = 16, .format = .uint16 });
        const indirect_options: render_encoder_base.DrawIndirectOptions = .{
            .indirect_buffer = &args,
            .indirect_buffer_size = 32,
            .indirect_offset = 0,
        };
        const multi_options: render_encoder_base.MultiDrawIndirectOptions = .{
            .indirect_buffer = &multi_args,
            .indirect_buffer_size = 64,
            .indirect_offset = 0,
            .max_draw_count = 2,
            .draw_count_buffer = &count,
            .draw_count_buffer_size = 4,
        };
        if (indexed) {
            try pass.drawIndexedIndirect(indirect_options);
            try pass.multiDrawIndexedIndirect(multi_options);
        } else {
            try pass.drawIndirect(indirect_options);
            try pass.multiDrawIndirect(multi_options);
        }
        try pass.end(std.testing.io, &fixture.guard);
        var finished = try encoder.finish();
        defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
        const scope = &finished.render_pass_usages.items[0].scope;
        const start: usize = if (indexed) 1 else 0;
        try std.testing.expectEqualSlices(commands.Ref, &.{ &args, &multi_args, &count }, scope.buffers.items[start..]);
        for (scope.buffer_sync_infos.items[start..]) |info| {
            try std.testing.expectEqual((dusk.api.BufferUsage{ .indirect = true }).toFlags(), info.usage);
        }
    }
}

test "public compute labels skip to the following command" {
    for ([_][]const u8{ "", "compute", "1234567", "12345678" }) |label| {
        var fixture: Fixture = undefined;
        try fixture.init(std.testing.allocator);
        defer fixture.deinit();
        var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
        defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
        var pass = try encoder.beginComputePass(.{ .label = label });
        defer pass.deinit();
        try pass.end();
        try encoder.clearBuffer(.{ .offset = 8, .size = 16 });
        var finished = try encoder.finish();
        defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
        var iterator = finished.iterator(std.testing.allocator);
        defer iterator.deinit();
        try expectTag(&iterator.iterator, .begin_compute_pass);
        try commands.skip(&iterator.iterator, .begin_compute_pass);
        try expectTag(&iterator.iterator, .end_compute_pass);
        try commands.skip(&iterator.iterator, .end_compute_pass);
        try expectTag(&iterator.iterator, .clear_buffer);
        const clear = try iterator.nextCommand(commands.ClearBufferCmd);
        try std.testing.expectEqual(@as(u64, 8), clear.offset);
        try std.testing.expect(try iterator.nextTag() == null);
    }
}

test "the decoded stream is exactly the six commands the milestone names" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var objects: Objects = .{};
    var finished = try recordDraw(std.testing.allocator, &fixture, &objects, 3);
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();

    try expectTag(&iterator.iterator, .begin_render_pass);
    const begin = try iterator.nextCommand(commands.BeginRenderPassCmd);
    try std.testing.expectEqual(@as(u32, 4), begin.width);
    try std.testing.expectEqual(@as(u32, 4), begin.height);
    try std.testing.expect(begin.color_attachments[0].isPresent());
    try std.testing.expectEqual(commands.LoadOp.clear, begin.color_attachments[0].load_op);
    try std.testing.expectEqual(commands.StoreOp.store, begin.color_attachments[0].store_op);
    try std.testing.expect(!begin.color_attachments[1].isPresent());

    try expectTag(&iterator.iterator, .set_render_pipeline);
    const pipeline = try iterator.nextCommand(commands.SetRenderPipelineCmd);
    try std.testing.expectEqual(@as(commands.Ref, @ptrCast(&objects.pipeline)), pipeline.pipeline);

    try expectTag(&iterator.iterator, .set_bind_group);
    const group = try iterator.nextCommand(commands.SetBindGroupCmd);
    try std.testing.expectEqual(@as(u32, 0), group.index);
    try std.testing.expectEqual(@as(u32, 0), group.dynamic_offset_count);

    try expectTag(&iterator.iterator, .set_vertex_buffer);
    const vertex_buffer = try iterator.nextCommand(commands.SetVertexBufferCmd);
    try std.testing.expectEqual(@as(u32, 0), vertex_buffer.slot);
    try std.testing.expectEqual(@as(u64, 0), vertex_buffer.offset);
    // The recorded size is the resolved one, not the descriptor's null
    // (`render_encoder_base.zig:207`): a replay has no descriptor left to read.
    try std.testing.expectEqual(vertex_buffer_bytes, vertex_buffer.size);

    try expectTag(&iterator.iterator, .draw);
    const draw = try iterator.nextCommand(commands.DrawCmd);
    try std.testing.expectEqual(@as(u32, 3), draw.vertex_count);
    try std.testing.expectEqual(@as(u32, 1), draw.instance_count);
    try std.testing.expectEqual(@as(u32, 0), draw.first_vertex);

    try expectTag(&iterator.iterator, .end_render_pass);
    _ = try iterator.nextCommand(commands.EndRenderPassCmd);

    // "and nothing else": the walk ends here.
    try std.testing.expect(try iterator.nextTag() == null);
}

test "a draw past the end of the vertex buffer it names is refused by name" {
    // The same pass as the test above, with one count changed. Nothing else
    // differs, so the error below is the count and nothing else.
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var objects: Objects = .{};
    try std.testing.expectError(
        error.DrawVertexCount,
        recordDraw(std.testing.allocator, &fixture, &objects, 4),
    );
}

test "unknown tag is not end of stream" {
    var arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
    defer arena.deinit();
    _ = try arena.allocate(0x12345678, 0);
    var iterator = allocator_mod.Iterator.init(std.testing.allocator, arena.acquireBlocks());
    defer iterator.deinit();
    try std.testing.expectError(error.InvalidCommandTag, iterator.nextTag());
}

test "partial tag slot and payload are refused" {
    for ([_]usize{ 1, 3, 4, 7 }) |length| {
        var arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
        defer arena.deinit();
        _ = try arena.allocateCommand(commands.DrawCmd, @backingInt(commands.Tag.draw));
        var blocks = arena.acquireBlocks();
        blocks.items[0].len = length;
        var iterator = allocator_mod.Iterator.init(std.testing.allocator, blocks);
        defer iterator.deinit();
        try std.testing.expectError(error.CommandStreamTruncated, iterator.nextTag());
    }
    var arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
    defer arena.deinit();
    _ = try arena.allocateCommand(commands.DrawCmd, @backingInt(commands.Tag.draw));
    var blocks = arena.acquireBlocks();
    blocks.items[0].len = constants.max_alignment;
    var iterator = allocator_mod.Iterator.init(std.testing.allocator, blocks);
    defer iterator.deinit();
    try expectTag(&iterator, .draw);
    try std.testing.expectError(error.CommandStreamTruncated, iterator.nextCommand(commands.DrawCmd));
}

test "additional data refuses wrong sentinel truncated runs and overflowing counts" {
    var arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
    defer arena.deinit();
    _ = try arena.allocateCommand(commands.EndComputePassCmd, @backingInt(commands.Tag.end_compute_pass));
    var iterator = allocator_mod.Iterator.init(std.testing.allocator, arena.acquireBlocks());
    defer iterator.deinit();
    try std.testing.expectError(error.CommandStreamTruncated, iterator.nextData(u32, 1));

    var data_arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
    defer data_arena.deinit();
    _ = try data_arena.allocateData(u32, 2);
    var data_iterator = allocator_mod.Iterator.init(std.testing.allocator, data_arena.acquireBlocks());
    defer data_iterator.deinit();
    try std.testing.expectError(error.CommandStreamTruncated, data_iterator.nextData(u32, 3));
    data_iterator.reset();
    try std.testing.expectError(
        error.CommandStreamTruncated,
        data_iterator.nextData(u64, std.math.maxInt(usize)),
    );
}

test "all six trailing run shapes preserve subsequent alignment" {
    inline for (.{
        commands.Tag.insert_debug_marker,
        commands.Tag.push_debug_group,
        commands.Tag.set_immediates,
        commands.Tag.write_buffer,
        commands.Tag.set_bind_group,
        commands.Tag.execute_bundles,
    }) |tag| {
        for ([_]u32{ 0, 1, 7, 8, 9 }) |count| {
            var arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
            defer arena.deinit();
            const payload = try arena.allocateCommand(commands.Payload(tag), @backingInt(tag));
            payload.* = std.mem.zeroes(commands.Payload(tag));
            switch (tag) {
                .insert_debug_marker, .push_debug_group => payload.length = count + 1,
                .set_immediates, .write_buffer => payload.size = count,
                .set_bind_group => payload.dynamic_offset_count = count,
                .execute_bundles => payload.count = count,
                else => unreachable,
            }
            const run_count: usize = switch (tag) {
                .insert_debug_marker, .push_debug_group => count + 1,
                else => count,
            };
            if (tag != .set_bind_group or count != 0) {
                const run = try arena.allocateData(commands.DataElement(tag), run_count);
                @memset(run, std.mem.zeroes(commands.DataElement(tag)));
            }
            _ = try arena.allocateCommand(commands.EndComputePassCmd, @backingInt(commands.Tag.end_compute_pass));
            var iterator = allocator_mod.Iterator.init(std.testing.allocator, arena.acquireBlocks());
            defer iterator.deinit();
            try expectTag(&iterator, tag);
            try commands.skip(&iterator, tag);
            try expectTag(&iterator, .end_compute_pass);
            try commands.skip(&iterator, .end_compute_pass);
            try std.testing.expect(try iterator.nextTag() == null);
        }
    }
}

test "debug label skip rejects missing length and terminator" {
    for ([_]u32{ 0, 1 }) |length| {
        var arena = try allocator_mod.Allocator.init(std.testing.allocator, block_size);
        defer arena.deinit();
        const marker = try arena.allocateCommand(
            commands.InsertDebugMarkerCmd,
            @backingInt(commands.Tag.insert_debug_marker),
        );
        marker.* = .{ .length = length };
        const bytes = try arena.allocateData(u8, length);
        @memset(bytes, 'x');
        var iterator = allocator_mod.Iterator.init(std.testing.allocator, arena.acquireBlocks());
        defer iterator.deinit();
        try expectTag(&iterator, .insert_debug_marker);
        try std.testing.expectError(
            error.CommandStreamTruncated,
            commands.skip(&iterator, .insert_debug_marker),
        );
    }
}

test "debug label skip preserves the following tag at alignment boundaries" {
    for ([_]usize{ 0, 6, 7, 8, 14, 15, 16 }) |length| {
        var fixture: Fixture = undefined;
        try fixture.init(std.testing.allocator);
        defer fixture.deinit();
        var encoder = command.CommandEncoder.init(
            std.testing.allocator,
            fixture.device.borrow(),
            .{ .block_size = block_size },
        );
        defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        const label: [16]u8 = @splat('x');
        try pass.insertDebugMarker(label[0..length]);
        try pass.end();
        var finished = try encoder.finish();
        defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
        var iterator = finished.iterator(std.testing.allocator);
        defer iterator.deinit();
        try expectTag(&iterator.iterator, .begin_compute_pass);
        try commands.skip(&iterator.iterator, .begin_compute_pass);
        try expectTag(&iterator.iterator, .insert_debug_marker);
        try commands.skip(&iterator.iterator, .insert_debug_marker);
        try expectTag(&iterator.iterator, .end_compute_pass);
        try commands.skip(&iterator.iterator, .end_compute_pass);
        try std.testing.expect(try iterator.nextTag() == null);
    }
}

test "finished ownership and finish failure close the context across fail N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, finishOwnership, .{});
}

fn finishOwnership(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();
    var context = try encoding_context.Context.init(
        allocator,
        fixture.device.borrow(),
        block_size,
        false,
    );
    defer context.deinit(std.testing.io, &fixture.guard);
    var owned_usage = command.usage.RenderPassResourceUsage.init(allocator);
    defer owned_usage.deinit(std.testing.io, &fixture.guard);
    try owned_usage.retainAttachmentLocked(&fixture.guard, fixture.attachment);
    try context.render_pass_usages.append(allocator, owned_usage);
    owned_usage = command.usage.RenderPassResourceUsage.init(allocator);
    try fixture.attachment.header.releaseUserLocked(&fixture.guard, std.testing.io);
    fixture.user_alias_held = false;
    const encoder = context.open();
    _ = try context.encodeTopLevel(commands.ClearBufferCmd, encoder, .clear_buffer);
    try context.commitCommands();
    _ = try context.encodeTopLevel(commands.ClearBufferCmd, encoder, .clear_buffer);
    var finished = context.finish() catch |err| {
        try std.testing.expectEqual(encoding_context.Status.finished, context.status);
        try std.testing.expectError(
            error.EncoderAlreadyFinished,
            context.validateCanEncodeOn(encoder, true),
        );
        return err;
    };
    defer finished.deinit(allocator, std.testing.io, &fixture.guard);
    try std.testing.expect(finished.render_pass_usages.items[0].attachment_state == fixture.attachment);
    {
        var iterator = finished.iterator(allocator);
        defer iterator.deinit();
        var second_iterator = finished.iterator(allocator);
        defer second_iterator.deinit();
        try expectTag(&second_iterator.iterator, .clear_buffer);
        try commands.skip(&second_iterator.iterator, .clear_buffer);
        try expectTag(&second_iterator.iterator, .clear_buffer);
        try commands.skip(&second_iterator.iterator, .clear_buffer);
        try std.testing.expect(try second_iterator.nextTag() == null);
        try expectTag(&iterator.iterator, .clear_buffer);
        try commands.skip(&iterator.iterator, .clear_buffer);
        try expectTag(&iterator.iterator, .clear_buffer);
        try commands.skip(&iterator.iterator, .clear_buffer);
        try std.testing.expect(try iterator.nextTag() == null);
    }
    try std.testing.expect(fixture.attachment.header.isAlive(&fixture.guard));
}

test "the pass hands its resource usage to the context once" {
    // `acquireResourceUsage` moves every list out and starts over
    // (`usage.zig:546-560`), so a second call has nothing left to move. A
    // caller that acquires twice would otherwise hand the context two usages
    // over one set of lists and free them twice.
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);

    var objects: Objects = .{};
    var pass = try beginPass(&encoder, &fixture, @ptrCast(&objects.colour_target));
    defer pass.deinit(std.testing.io, &fixture.guard);

    try setUpPass(&pass, &fixture.guard, fixture.attachment, &objects);

    // `var`, because `deinit` frees the lists it owns and so takes
    // `*RenderPassResourceUsage` (`usage.zig:207`); a `const` binding would
    // hand it a `*const` instead.
    var first = pass.usage.acquireResourceUsage();
    defer first.deinit(std.testing.io, &fixture.guard);
    try std.testing.expect(first.attachment_state == fixture.attachment);
    // The vertex buffer the pass bound is the one thing it used.
    try std.testing.expectEqual(@as(usize, 1), first.scope.buffers.items.len);

    var second = pass.usage.acquireResourceUsage();
    defer second.deinit(std.testing.io, &fixture.guard);
    try std.testing.expect(second.attachment_state == null);
    pass.deinit(std.testing.io, &fixture.guard);
    try std.testing.expectEqual(@as(usize, 0), second.scope.buffers.items.len);
}

/// The pass the milestone names, ending in one draw of `vertex_count`
/// vertices.
///
/// The owning core fixture stays in the caller's frame until Finished is released.
fn recordDraw(
    allocator: std.mem.Allocator,
    fixture: *Fixture,
    objects: *Objects,
    vertex_count: u32,
) !encoding_context.Finished {
    var encoder = command.CommandEncoder.init(allocator, fixture.device.borrow(), .{
        .block_size = block_size,
    });
    defer encoder.deinit(allocator, std.testing.io, &fixture.guard);

    var pass = try beginPass(&encoder, fixture, @ptrCast(&objects.colour_target));
    defer pass.deinit(std.testing.io, &fixture.guard);

    try setUpPass(&pass, &fixture.guard, fixture.attachment, objects);
    try pass.draw(.{
        .vertex_count = vertex_count,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try pass.end(std.testing.io, &fixture.guard);
    return encoder.finish();
}

/// Use the public producer so the Begin command and pass usage share one lease.
fn beginPass(
    encoder: *command.CommandEncoder,
    fixture: *Fixture,
    colour_target: commands.Ref,
) !render_encoder_base.RenderEncoderBase {
    return encoder.beginRenderPass(std.testing.io, &fixture.guard, fixture.attachment, .{
        .color_attachments = &.{.{
            .view = colour_target,
            .load_op = .clear,
            .store_op = .store,
        }},
        .width = 4,
        .height = 4,
    });
}

/// The pipeline, the bind group and the vertex buffer, in the order a caller
/// records them.
///
/// The bind group carries no dynamic offsets, so `recordSetBindGroup` writes
/// no counted run behind it (`programmable_encoder.zig:155-158`); the stream
/// the decoder walks above therefore holds five payloads and no runs.
fn setUpPass(
    pass: *render_encoder_base.RenderEncoderBase,
    guard: *const core.ObjectGuard,
    attachment: *attachment_state.CanonicalAttachmentState,
    objects: *Objects,
) !void {
    try pass.setPipeline(guard, .{
        .pipeline = @ptrCast(&objects.pipeline),
        .requirements = pipelineRequirements(),
        .attachment_state = attachment,
    });
    try pass.setBindGroup(.{
        .index = 0,
        .group = @ptrCast(&objects.bind_group),
        .layout_id = layout_id,
    });
    try pass.setVertexBuffer(.{
        .slot = 0,
        .buffer = @ptrCast(&objects.vertex_buffer),
        .buffer_size = vertex_buffer_bytes,
    });
}

/// What the pipeline the pass binds declares.
///
/// `command` does not import `engine` and cannot read a pipeline
/// (`state_tracker.zig:10-17`), so Dawn's `RecomputeLazyAspects` arrives here
/// as data: one bit per bind group, one layout id, one layout per vertex slot.
fn pipelineRequirements() state_tracker.PipelineRequirements {
    var layouts: [constants.max_vertex_buffers]state_tracker.VertexBufferLayout = @splat(.{});
    layouts[0] = .{
        .array_stride = vertex_stride,
        .last_stride = vertex_stride,
        .used_bytes_in_stride = vertex_stride,
    };
    return .{
        .bind_group_layout_mask = 1,
        .bind_group_layout_ids = .{ layout_id, 0, 0, 0 },
        .vertex_buffer_mask = 1,
        .vertex_buffer_layouts = layouts,
    };
}

/// The next tag, or the stream ended early.
fn expectTag(iterator: *allocator_mod.Iterator, want: commands.Tag) !void {
    const got = try iterator.nextTag() orelse return error.StreamEndedEarly;
    try std.testing.expectEqual(want, got);
}
