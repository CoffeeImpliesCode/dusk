//! The M15 shard: the command stream, decoded.
//!
//! **What this shard asserts.** The acceptance sentence
//! (`docs/40-plan.md:586-592`) has two halves. The first records a whole
//! render pass — begin, set pipeline, set bind group, set vertex buffer, a draw
//! of three, end — and decodes the stream back, asserting it holds exactly
//! those six commands in that order and nothing else. The second records a
//! draw of four against the same three-vertex buffer and asserts the failure
//! names `DrawVertexCount`.
//!
//! **No device is present.** Every object the pass names is a `commands.Ref`,
//! which is a pointer into the arena and nothing else (`commands.zig:63-66`),
//! so the pass records and the stream decodes with no `VkDevice`, no adapter
//! and no driver. That is the split `docs/40-plan.md:556-557` asks for: it is
//! the reason a stream bug is a unit-test failure rather than a device one.
//!
//! **What this shard does not claim.** It does not claim the replay is
//! correct: nothing here turns a tag into a Vulkan call, because that is M18
//! (`docs/40-plan.md:657-661`). It does not claim the payload layouts match
//! Dawn's, which `commands.zig:10-14` rules out in so many words. It decodes
//! with `Iterator.nextCommand` per tag rather than through `commands.skip`
//! because `skip` advances past a payload without interpreting it
//! (`commands.zig:509-515`) and hands nothing back, while the acceptance
//! asserts fields inside the payloads — the pass size, the attachment load
//! op, the pipeline address, the vertex counts — so the walk has to read
//! each one.

const std = @import("std");
const dusk = @import("dusk");

const command = dusk.command;
const allocator_mod = command.allocator;
const commands = command.commands;
const constants = command.constants;
const encoding_context = command.encoding_context;
const indirect_draw = command.indirect_draw;
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

test "the tag enum still holds Dawn's 38 values" {
    // `commands.zig:131-134` publishes the count as a number precisely so a
    // tag added upstream cannot pass unnoticed. The compile-time check on the
    // same file refuses a change; this asserts the value the milestone budget
    // was written against.
    try std.testing.expectEqual(@as(usize, 38), commands.tag_count);
}

test "the decoded stream is exactly the six commands the milestone names" {
    var objects: Objects = .{};
    var finished = try recordDraw(std.testing.allocator, &objects, 3);
    defer deinitUsages(std.testing.allocator, &finished);

    // The blocks move to the iterator, which owns them and frees them with its
    // own `deinit` (`allocator.zig:255-258`).
    const blocks = finished.blocks;
    finished.blocks = .empty;
    var iterator = allocator_mod.Iterator.init(std.testing.allocator, blocks);
    defer iterator.deinit();

    try expectTag(&iterator, .begin_render_pass);
    const begin = try iterator.nextCommand(commands.BeginRenderPassCmd);
    try std.testing.expectEqual(@as(u32, 4), begin.width);
    try std.testing.expectEqual(@as(u32, 4), begin.height);
    try std.testing.expect(begin.color_attachments[0].isPresent());
    try std.testing.expectEqual(commands.LoadOp.clear, begin.color_attachments[0].load_op);
    try std.testing.expectEqual(commands.StoreOp.store, begin.color_attachments[0].store_op);
    try std.testing.expect(!begin.color_attachments[1].isPresent());

    try expectTag(&iterator, .set_render_pipeline);
    const pipeline = try iterator.nextCommand(commands.SetRenderPipelineCmd);
    try std.testing.expectEqual(@as(commands.Ref, @ptrCast(&objects.pipeline)), pipeline.pipeline);

    try expectTag(&iterator, .set_bind_group);
    const group = try iterator.nextCommand(commands.SetBindGroupCmd);
    try std.testing.expectEqual(@as(u32, 0), group.index);
    try std.testing.expectEqual(@as(u32, 0), group.dynamic_offset_count);

    try expectTag(&iterator, .set_vertex_buffer);
    const vertex_buffer = try iterator.nextCommand(commands.SetVertexBufferCmd);
    try std.testing.expectEqual(@as(u32, 0), vertex_buffer.slot);
    try std.testing.expectEqual(@as(u64, 0), vertex_buffer.offset);
    // The recorded size is the resolved one, not the descriptor's null
    // (`render_encoder_base.zig:207`): a replay has no descriptor left to read.
    try std.testing.expectEqual(vertex_buffer_bytes, vertex_buffer.size);

    try expectTag(&iterator, .draw);
    const draw = try iterator.nextCommand(commands.DrawCmd);
    try std.testing.expectEqual(@as(u32, 3), draw.vertex_count);
    try std.testing.expectEqual(@as(u32, 1), draw.instance_count);
    try std.testing.expectEqual(@as(u32, 0), draw.first_vertex);

    try expectTag(&iterator, .end_render_pass);
    _ = try iterator.nextCommand(commands.EndRenderPassCmd);

    // "and nothing else": the walk ends here.
    try std.testing.expect(iterator.nextTag() == null);
}

test "a draw past the end of the vertex buffer it names is refused by name" {
    // The same pass as the test above, with one count changed. Nothing else
    // differs, so the error below is the count and nothing else.
    var objects: Objects = .{};
    try std.testing.expectError(
        error.DrawVertexCount,
        recordDraw(std.testing.allocator, &objects, 4),
    );
}

test "the pass hands its resource usage to the context once" {
    // `acquireResourceUsage` moves every list out and starts over
    // (`usage.zig:546-560`), so a second call has nothing left to move. A
    // caller that acquires twice would otherwise hand the context two usages
    // over one set of lists and free them twice.
    var context = try encoding_context.Context.init(std.testing.allocator, block_size, false);
    defer context.deinit();

    var objects: Objects = .{};
    var pass = try beginPass(std.testing.allocator, &context, @ptrCast(&objects.colour_target));
    defer pass.deinit();

    try setUpPass(&pass, &objects);

    // `var`, because `deinit` frees the lists it owns and so takes
    // `*RenderPassResourceUsage` (`usage.zig:207`); a `const` binding would
    // hand it a `*const` instead.
    var first = pass.usage.acquireResourceUsage();
    defer first.deinit();
    // The vertex buffer the pass bound is the one thing it used.
    try std.testing.expectEqual(@as(usize, 1), first.scope.buffers.items.len);

    var second = pass.usage.acquireResourceUsage();
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.scope.buffers.items.len);
}

/// The pass the milestone names, ending in one draw of `vertex_count`
/// vertices.
///
/// `context` and the pass encoder are locals of this frame and the encoder
/// holds the context's address, so neither is copied after the pass is begun.
fn recordDraw(
    allocator: std.mem.Allocator,
    objects: *Objects,
    vertex_count: u32,
) !encoding_context.Finished {
    var context = try encoding_context.Context.init(allocator, block_size, false);
    defer context.deinit();

    var pass = try beginPass(allocator, &context, @ptrCast(&objects.colour_target));
    defer pass.deinit();

    try setUpPass(&pass, objects);
    try pass.draw(.{
        .vertex_count = vertex_count,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try endPass(allocator, &context, &pass);
    return context.finish();
}

/// Dawn's `WillBeginRenderPass` (`EncodingContext.cpp:154-165`) then
/// `BeginRenderPass`, which calls it and allocates the tag in one step
/// (`CommandEncoder.cpp:1513-1515`), then a pass encoder over the same context.
fn beginPass(
    allocator: std.mem.Allocator,
    context: *encoding_context.Context,
    colour_target: commands.Ref,
) !render_encoder_base.RenderEncoderBase {
    const top_level = context.open();
    try context.willBeginRenderPass();

    var attachments =
        [_]commands.RenderPassColorAttachmentInfo{.{}} ** constants.max_color_attachments;
    attachments[0] = .{
        .view = colour_target,
        .load_op = .clear,
        .store_op = .store,
    };
    const begin = try context.encodeTopLevel(
        commands.BeginRenderPassCmd,
        top_level,
        .begin_render_pass,
    );
    begin.* = .{ .color_attachments = attachments, .width = 4, .height = 4 };

    return render_encoder_base.RenderEncoderBase.init(allocator, context, false);
}

/// The pipeline, the bind group and the vertex buffer, in the order a caller
/// records them.
///
/// The bind group carries no dynamic offsets, so `recordSetBindGroup` writes
/// no counted run behind it (`programmable_encoder.zig:155-158`); the stream
/// the decoder walks above therefore holds five payloads and no runs.
fn setUpPass(pass: *render_encoder_base.RenderEncoderBase, objects: *Objects) !void {
    try pass.setPipeline(.{
        .pipeline = @ptrCast(&objects.pipeline),
        .requirements = pipelineRequirements(),
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

/// Dawn's `End` (`RenderPassEncoder.cpp:157-196`), which records the closing
/// tag and then hands the pass's usage and indirect-draw metadata to
/// `ExitRenderPass` (`RenderPassEncoder.cpp:184-187`); the context commits the
/// block the pass body lives in (`EncodingContext.cpp:207-208`).
fn endPass(
    allocator: std.mem.Allocator,
    context: *encoding_context.Context,
    pass: *render_encoder_base.RenderEncoderBase,
) !void {
    try pass.programmable.validateProgrammableEncoderEnd();
    _ = try context.encode(
        commands.EndRenderPassCmd,
        pass.programmable.id,
        .end_render_pass,
    );
    try context.exitRenderPass(
        pass.programmable.id,
        pass.usage.acquireResourceUsage(),
        // The pass issued no indirect draw, so the metadata it hands over is
        // the empty one. It is built here rather than copied out of `pass`:
        // `RenderEncoderBase.deinit` still owns that copy, and the context
        // frees the one it was given.
        indirect_draw.IndirectDrawMetadata.init(allocator),
    );
    pass.tracker.end();
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
    const got = iterator.nextTag() orelse return error.StreamEndedEarly;
    try std.testing.expectEqual(want, got);
}

/// Everything a finished command buffer owns apart from its blocks, which the
/// iterator takes.
///
/// `finished` arrives by pointer because each `deinit` frees what it owns and
/// so writes through its `*Self` (`usage.zig:207`, `array_list.zig:623`),
/// which is the shape `Context.deinit` frees itself in
/// (`encoding_context.zig:102-108`).
fn deinitUsages(allocator: std.mem.Allocator, finished: *encoding_context.Finished) void {
    for (finished.render_pass_usages.items) |*item| item.deinit();
    finished.render_pass_usages.deinit(allocator);
    for (finished.compute_pass_usages.items) |*item| item.deinit();
    finished.compute_pass_usages.deinit(allocator);
    for (finished.indirect_draws.items) |*item| item.deinit();
    finished.indirect_draws.deinit(allocator);
}
