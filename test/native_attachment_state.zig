//! Real native attachment producers, command consumers, weak aliases and GPU ownership.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const command = dusk.command;
const native = engine.native_resources;
const attachment = command.attachment_state;
const State = attachment.CanonicalAttachmentState;
const Encoder = command.command_encoder.CommandEncoder;
const Finished = command.encoding_context.Finished;
const graphics = @import("fixtures/specialization_graphics.zig");
const t = std.testing;
const extent: u32 = 16;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    allocator: std.mem.Allocator = t.allocator,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        self.threaded = .init(t.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(allocator, io) catch @panic("instance rollback failed");
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback failed");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("native attachment test reported an uncaptured error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(self.allocator, io) catch @panic("device teardown failed");
        self.adapters.deinit(io) catch @panic("adapter teardown failed");
        self.instance.deinit(self.allocator, io) catch @panic("instance teardown failed");
        self.threaded.deinit();
    }

    fn release(self: *Fixture, resource: anytype) void {
        self.device.release(self.allocator, self.threaded.io(), resource) catch
            @panic("resource release failed");
    }

    fn encoder(self: *Fixture) Encoder {
        return Encoder.init(self.allocator, self.device.core.borrow(), .{});
    }

    fn deinitEncoder(self: *Fixture, command_encoder: *Encoder) void {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        command_encoder.deinit(self.allocator, io, &guard);
    }

    fn deinitFinished(self: *Fixture, finished: *Finished) void {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(self.allocator, io, &guard);
    }

    // Source shader/layout aliases end here; the returned real pipeline owns its dependencies.
    fn pipeline(
        self: *Fixture,
        colors: []const native.ColorTargetState,
        depth: ?api.TextureFormat,
        samples: u32,
        with_fragment: bool,
    ) !*native.Pipeline {
        const io = self.threaded.io();
        const layout = try self.device.createPipelineLayout(self.allocator, io, .{ .groups = &.{} });
        defer self.release(layout);
        const vertex = try self.device.createShaderModule(self.allocator, io, .{ .words = &graphics.vertex_words });
        defer self.release(vertex);
        const fragment = if (with_fragment)
            try self.device.createShaderModule(self.allocator, io, .{
                .words = if (colors.len > 1 and colors[0].format == .undefined_)
                    &sparse_fragment_words
                else
                    &graphics.fragment_words,
            })
        else
            null;
        defer if (fragment) |module| self.release(module);
        return self.device.createRenderPipeline(self.allocator, io, .{
            .layout = layout,
            .vertex = .{ .module = vertex, .entry_point = graphics.entry_point, .stage = .vertex },
            .fragment = if (fragment) |module| .{
                .module = module,
                .entry_point = graphics.entry_point,
                .stage = .fragment,
            } else null,
            .color_targets = colors,
            .depth_stencil = if (depth) |format| .{ .format = format } else null,
            .multisample = .{ .count = samples },
        });
    }

    fn begin(self: *Fixture, command_encoder: *Encoder, colors: []const command.commands.RenderPassColorAttachmentInfo, depth: command.commands.RenderPassDepthStencilAttachmentInfo) !command.render_encoder_base.RenderEncoderBase {
        return self.device.beginRenderPass(self.allocator, self.threaded.io(), command_encoder, .{
            .color_attachments = colors,
            .depth_stencil_attachment = depth,
            .width = extent,
            .height = extent,
        });
    }

    fn internLocked(self: *Fixture, guard: *const core.ObjectGuard, value: attachment.AttachmentState) !*State {
        try self.device.bindObjectsLocked(guard, self.allocator);
        return engine.native_attachment_store.create(
            self.allocator,
            self.threaded.io(),
            guard,
            &self.device.core.arena,
            &self.device.native.?.resource_store.?,
            value,
        );
    }
};

const Image = struct {
    texture: *engine.texture.Texture,
    view: *engine.texture.TextureView,

    fn init(f: *Fixture, format: api.TextureFormat, samples: u32) !Image {
        const io = f.threaded.io();
        const texture = try f.device.createTexture(f.allocator, io, .{
            .size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
            .format = format,
            .sample_count = samples,
            .usage = .{ .render_attachment = true, .copy_src = samples == 1 and format == .rgba8_unorm },
        });
        errdefer f.release(texture);
        const view = try f.device.createTextureView(f.allocator, io, .{
            .texture = texture,
            .descriptor = .{ .format = format, .dimension = ._2d },
        });
        return .{ .texture = texture, .view = view };
    }

    fn deinit(self: Image, f: *Fixture) void {
        f.release(self.view);
        f.release(self.texture);
    }

    fn color(self: Image) command.commands.RenderPassColorAttachmentInfo {
        return .{
            .view = self.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ .r = 0, .g = 0, .b = 1, .a = 1 },
        };
    }

    fn depth(self: Image) command.commands.RenderPassDepthStencilAttachmentInfo {
        return .{
            .view = self.view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .clear_depth = 1,
        };
    }
};

fn endPass(f: *Fixture, pass: *command.render_encoder_base.RenderEncoderBase) !void {
    const io = f.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    defer pass.deinit(io, &guard);
    try pass.end(io, &guard);
}

fn deinitPass(f: *Fixture, pass: *command.render_encoder_base.RenderEncoderBase) void {
    const io = f.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    pass.deinit(io, &guard);
}

fn expectPruned(f: *Fixture, state: *State) !void {
    const io = f.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    try t.expectEqual(core.ObjectState.destroyed, state.header.state);
    try t.expectEqual(@as(u32, 0), state.header.reference_count);
    try t.expect(state.header.remove_from_cache == null);
    try t.expect(state.header.cache_context == null);
    try t.expect(state.cache_next == null);
    try t.expect(f.device.native.?.resource_store.?.attachments.isEmpty(&guard));
}

const rgba = [_]native.ColorTargetState{.{ .format = .rgba8_unorm }};
const triangle_draw: command.render_encoder_base.DrawVertexCountOptions = .{
    .vertex_count = 3,
    .instance_count = 1,
    .first_vertex = 0,
    .first_instance = 0,
};

// The exact high pipeline, pass and arena bundle all produce and consume one header.
test "native attachment equal pipeline pass bundle and Finished pending leases share one actual header" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const image = try Image.init(&f, .rgba8_unorm, 1);
    defer image.deinit(&f);
    const pipeline = try f.pipeline(&rgba, null, 1, true);
    var pipeline_owned = true;
    defer if (pipeline_owned) f.release(pipeline);
    var bundle_encoder = try f.device.createRenderBundleEncoder(f.allocator, io, .{
        .color_formats = &.{.rgba8_unorm},
        .sample_count = 1,
    });
    var bundle_encoder_owned = true;
    defer if (bundle_encoder_owned) {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        bundle_encoder.deinit(io, &guard);
    };
    const bundle = blk: {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try bundle_encoder.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try bundle_encoder.draw(triangle_draw);
        const result = try bundle_encoder.finish(io, &guard);
        bundle_encoder.deinit(io, &guard);
        bundle_encoder_owned = false;
        break :blk result;
    };
    var bundle_owned = true;
    defer if (bundle_owned) f.release(bundle);
    var encoder = f.encoder();
    var encoder_owned = true;
    defer if (encoder_owned) f.deinitEncoder(&encoder);
    var pass = try f.begin(&encoder, &.{image.color()}, .{});
    defer deinitPass(&f, &pass);
    const state = pass.attachmentState();
    const value = state.value;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const options = try pipeline.renderOptions(&guard);
        try t.expect(options.pipeline == @as(command.commands.Ref, @ptrCast(&pipeline.header)));
        try t.expect(options.attachment_state == state);
        try t.expect(bundle.attachmentState() == state);
        try t.expectEqual(@as(u32, 0), state.header.user_reference_count);
        try t.expectEqual(@as(u32, 3), state.header.reference_count);
        try pass.setPipeline(&guard, options);
        try pass.executeBundles(&guard, &.{bundle});
        {
            const alias = try f.internLocked(&guard, value);
            defer alias.header.releaseUserLocked(&guard, io) catch unreachable;
            try t.expect(alias == state);
            try t.expectEqual(@as(u32, 1), state.header.user_reference_count);
        }
        try pass.end(io, &guard);
        pass.deinit(io, &guard);
        try t.expectEqual(@as(u32, 3), state.header.reference_count);
    }
    var finished = try encoder.finish();
    defer f.deinitFinished(&finished);
    f.deinitEncoder(&encoder);
    encoder_owned = false;
    {
        var cursor = finished.iterator(f.allocator);
        defer cursor.deinit();
        try t.expectEqual(@as(?command.commands.Tag, .begin_render_pass), try cursor.nextTag());
        const begin = try cursor.nextCommand(command.commands.BeginRenderPassCmd);
        try t.expect(begin.attachment_state == state);
        var second = finished.iterator(f.allocator);
        defer second.deinit();
        try t.expectEqual(@as(?command.commands.Tag, .begin_render_pass), try second.nextTag());
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        var pending = try native.PendingUses.prepareFinishedLocked(
            f.allocator,
            &guard,
            &f.device.core,
            &finished,
            f.device.limits.v1.max_immediate_size,
        );
        defer pending.releaseLocked(&guard, io);
        try t.expect(pending.roots.contains(&state.header));
        try t.expect(pending.roots.contains(&pipeline.header));
        try t.expect(pending.roots.contains(&bundle.header));
        try t.expect(pending.roots.contains(&image.view.header));
        // Admission is the ownership boundary for ordinary borrowed resources.
        try pipeline.header.releaseUserLocked(&guard, io);
        pipeline_owned = false;
        try bundle.header.releaseUserLocked(&guard, io);
        bundle_owned = false;
        finished.deinit(f.allocator, io, &guard);
        try t.expect(state.header.isAlive(&guard));
        const alias = try f.internLocked(&guard, value);
        defer alias.header.releaseUserLocked(&guard, io) catch unreachable;
        try t.expect(alias == state);
    }
    try expectPruned(&f, state);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const fresh = try f.internLocked(&guard, value);
        defer fresh.header.releaseUserLocked(&guard, io) catch unreachable;
        try t.expect(fresh != state);
        try t.expect(fresh.header.isAlive(&guard));
    }
}

// Interior color holes are semantic locations; trailing holes are not extra attachments.
test "native attachment actual sparse views preserve holes and normalize trailing targets" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const image = try Image.init(&f, .rgba8_unorm, 1);
    defer image.deinit(&f);
    const sparse_targets = [_]native.ColorTargetState{
        .{ .format = .undefined_, .write_mask = 0 }, .{ .format = .rgba8_unorm },
    };
    const trailing_targets = sparse_targets ++ [_]native.ColorTargetState{.{ .format = .undefined_, .write_mask = 0 }};
    const sparse = try f.pipeline(&sparse_targets, null, 1, true);
    defer f.release(sparse);
    const trailing = try f.pipeline(&trailing_targets, null, 1, true);
    defer f.release(trailing);
    const dense = try f.pipeline(&rgba, null, 1, false);
    defer f.release(dense);
    const readback = try f.device.createBuffer(f.allocator, io, .{
        .size = 256 * extent,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer f.release(readback);
    var encoder = f.encoder();
    defer f.deinitEncoder(&encoder);
    var pass = try f.begin(&encoder, &.{ .{}, image.color(), .{} }, .{});
    defer deinitPass(&f, &pass);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const state = pass.attachmentState();
        try t.expectEqual(@as(u8, 0b10), state.value.color_attachments_set);
        try t.expectEqual(@as(u32, 0), state.value.color_formats[0]);
        try t.expectEqual(@intFromEnum(api.TextureFormat.rgba8_unorm), state.value.color_formats[1]);
        try t.expectEqual(@as(u32, 0), state.value.color_formats[2]);
        try t.expect((try sparse.renderOptions(&guard)).attachment_state == state);
        try t.expect((try trailing.renderOptions(&guard)).attachment_state == state);
        try t.expect((try dense.renderOptions(&guard)).attachment_state != state);
        try pass.setPipeline(&guard, try sparse.renderOptions(&guard));
        try pass.draw(triangle_draw);
    }
    try endPass(&f, &pass);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try encoder.copyTextureToBuffer(.{
            .source = .{
                .texture = image.texture,
                .format = @intFromEnum(api.TextureFormat.rgba8_unorm),
                .dimension = ._2d,
                .aspect = .all,
                .extent = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
            },
            .destination = .{
                .buffer = try readback.ref(&guard),
                .blocks_per_row = 64,
                .rows_per_image = extent,
            },
            .copy_size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer f.deinitFinished(&finished);
    const serial = try f.device.submit(f.allocator, io, &finished);
    try f.device.wait(io, serial);
    try expectRenderedPixels(&f, readback, serial);
    var mismatch_encoder = f.encoder();
    defer f.deinitEncoder(&mismatch_encoder);
    var mismatch = try f.begin(&mismatch_encoder, &.{ .{}, image.color() }, .{});
    defer deinitPass(&f, &mismatch);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectError(error.AttachmentFormatMismatch, mismatch.setPipeline(&guard, try dense.renderOptions(&guard)));
    }
}

test "native attachment preserves exact API depth aliases despite equal physical formats" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const depth24 = try Image.init(&f, .depth24_plus, 1);
    defer depth24.deinit(&f);
    const depth32 = try Image.init(&f, .depth32_float, 1);
    defer depth32.deinit(&f);
    const pipeline24 = try f.pipeline(&.{}, .depth24_plus, 1, false);
    defer f.release(pipeline24);
    const pipeline32 = try f.pipeline(&.{}, .depth32_float, 1, false);
    defer f.release(pipeline32);
    var encoder24 = f.encoder();
    defer f.deinitEncoder(&encoder24);
    var pass24 = try f.begin(&encoder24, &.{}, depth24.depth());
    defer deinitPass(&f, &pass24);
    var encoder32 = f.encoder();
    defer f.deinitEncoder(&encoder32);
    var pass32 = try f.begin(&encoder32, &.{}, depth32.depth());
    defer deinitPass(&f, &pass32);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const a = try pipeline24.renderOptions(&guard);
        const b = try pipeline32.renderOptions(&guard);
        try t.expect(a.attachment_state == pass24.attachmentState());
        try t.expect(b.attachment_state == pass32.attachmentState());
        try t.expect(a.attachment_state != b.attachment_state);
        try t.expectEqual(@intFromEnum(api.TextureFormat.depth24_plus), a.attachment_state.value.depth_stencil_format);
        try t.expectEqual(@intFromEnum(api.TextureFormat.depth32_float), b.attachment_state.value.depth_stencil_format);
        try pass24.setPipeline(&guard, a);
        try t.expectError(error.AttachmentFormatMismatch, pass24.setPipeline(&guard, b));
        try pass32.setPipeline(&guard, b);
    }
}

test "native attachment depth only MSAA comes from real view and inconsistent sources are rejected" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const depth4 = try Image.init(&f, .depth32_float, 4);
    defer depth4.deinit(&f);
    const depth1 = try Image.init(&f, .depth32_float, 1);
    defer depth1.deinit(&f);
    const color4 = try Image.init(&f, .rgba8_unorm, 4);
    defer color4.deinit(&f);
    const color1 = try Image.init(&f, .rgba8_unorm, 1);
    defer color1.deinit(&f);
    const pipeline = try f.pipeline(&.{}, .depth32_float, 4, false);
    defer f.release(pipeline);
    var encoder = f.encoder();
    defer f.deinitEncoder(&encoder);
    var pass = try f.begin(&encoder, &.{}, depth4.depth());
    defer deinitPass(&f, &pass);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(@as(u32, 4), pass.attachmentState().value.sample_count);
        try t.expectEqual(@as(u8, 0), pass.attachmentState().value.color_attachments_set);
        try t.expect((try pipeline.renderOptions(&guard)).attachment_state == pass.attachmentState());
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
    }
    try endPass(&f, &pass);
    var finished = try encoder.finish();
    defer f.deinitFinished(&finished);
    const serial = try f.device.submit(f.allocator, io, &finished);
    try f.device.wait(io, serial);
    var bad_depth = f.encoder();
    defer f.deinitEncoder(&bad_depth);
    try t.expectError(error.AttachmentSampleCountMismatch, f.begin(&bad_depth, &.{color4.color()}, depth1.depth()));
    var bad_colors = f.encoder();
    defer f.deinitEncoder(&bad_colors);
    try t.expectError(error.AttachmentSampleCountMismatch, f.begin(&bad_colors, &.{ .{}, color4.color(), color1.color() }, .{}));
}

test "native attachment ordinary resolve mask normalizes to matching multisample pipeline" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const source = try Image.init(&f, .rgba8_unorm, 4);
    defer source.deinit(&f);
    const target = try Image.init(&f, .rgba8_unorm, 1);
    defer target.deinit(&f);
    const readback = try f.device.createBuffer(f.allocator, io, .{
        .size = 256 * extent,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer f.release(readback);
    const pipeline = try f.pipeline(&rgba, null, 4, true);
    defer f.release(pipeline);
    var resolve = source.color();
    resolve.resolve_target = target.view;
    var encoder = f.encoder();
    defer f.deinitEncoder(&encoder);
    var pass = try f.begin(&encoder, &.{resolve}, .{});
    defer deinitPass(&f, &pass);
    var plain_encoder = f.encoder();
    defer f.deinitEncoder(&plain_encoder);
    var plain = try f.begin(&plain_encoder, &.{source.color()}, .{});
    defer deinitPass(&f, &plain);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const state = pass.attachmentState();
        try t.expectEqual(@as(u32, 4), state.value.sample_count);
        try t.expectEqual(@as(u8, 0), state.value.expand_resolve.attachments_to_expand_resolve);
        try t.expectEqual(@as(u8, 0), state.value.expand_resolve.resolve_targets_mask);
        try t.expect(state == plain.attachmentState());
        try t.expect((try pipeline.renderOptions(&guard)).attachment_state == state);
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try pass.draw(triangle_draw);
    }
    try endPass(&f, &pass);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try encoder.copyTextureToBuffer(.{
            .source = .{
                .texture = target.texture,
                .format = @intFromEnum(api.TextureFormat.rgba8_unorm),
                .dimension = ._2d,
                .aspect = .all,
                .extent = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
            },
            .destination = .{
                .buffer = try readback.ref(&guard),
                .blocks_per_row = 64,
                .rows_per_image = extent,
            },
            .copy_size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer f.deinitFinished(&finished);
    const serial = try f.device.submit(f.allocator, io, &finished);
    try f.device.wait(io, serial);
    try expectRenderedPixels(&f, readback, serial);
}

test "native attachment abandoned pass prunes and Finished alone keeps lease through borrowed cursors" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const image = try Image.init(&f, .rgba8_unorm, 1);
    defer image.deinit(&f);
    var abandoned_encoder = f.encoder();
    defer f.deinitEncoder(&abandoned_encoder);
    var abandoned = try f.begin(&abandoned_encoder, &.{image.color()}, .{});
    const retired = abandoned.attachmentState();
    deinitPass(&f, &abandoned);
    try expectPruned(&f, retired);
    // Abandonment must not leave a finishable stream containing the dead Begin pointer.
    if (abandoned_encoder.finish()) |result| {
        var unexpected = result;
        f.deinitFinished(&unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}
    var encoder = f.encoder();
    var encoder_owned = true;
    defer if (encoder_owned) f.deinitEncoder(&encoder);
    var pass = try f.begin(&encoder, &.{image.color()}, .{});
    defer deinitPass(&f, &pass);
    const state = pass.attachmentState();
    try t.expect(state != retired);
    try endPass(&f, &pass);
    var finished = try encoder.finish();
    defer f.deinitFinished(&finished);
    f.deinitEncoder(&encoder);
    encoder_owned = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(@as(u32, 1), state.header.reference_count);
        try t.expectEqual(@as(u32, 0), state.header.user_reference_count);
    }
    {
        var cursor = finished.iterator(f.allocator);
        defer cursor.deinit();
        try t.expectEqual(@as(?command.commands.Tag, .begin_render_pass), try cursor.nextTag());
        try t.expect((try cursor.nextCommand(command.commands.BeginRenderPassCmd)).attachment_state == state);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const alias = try f.internLocked(&guard, state.value);
        defer alias.header.releaseUserLocked(&guard, io) catch unreachable;
        try t.expect(alias == state);
        try t.expectEqual(@as(u32, 2), state.header.reference_count);
    }
    f.deinitFinished(&finished);
    try expectPruned(&f, state);
}

test "native attachment explicit retirement evicts before late alias release and returns fresh high pass identity" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const image = try Image.init(&f, .rgba8_unorm, 1);
    defer image.deinit(&f);
    var old_encoder = f.encoder();
    defer f.deinitEncoder(&old_encoder);
    var old_pass = try f.begin(&old_encoder, &.{image.color()}, .{});
    defer deinitPass(&f, &old_pass);
    const old = old_pass.attachmentState();
    const value = old.value;
    const alias = blk: {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const result = try f.internLocked(&guard, value);
        errdefer result.header.releaseUserLocked(&guard, io) catch unreachable;
        old.header.retirePayloadLocked(&guard, io, .early_destroy);
        try t.expectEqual(core.ObjectState.destroyed, old.header.state);
        try t.expectEqual(@as(u32, 2), old.header.reference_count);
        try t.expect(old.header.remove_from_cache == null);
        try t.expect(old.header.cache_context == null);
        try t.expect(f.device.native.?.resource_store.?.attachments.isEmpty(&guard));
        break :blk result;
    };
    var alias_owned = true;
    defer if (alias_owned) f.release(alias);
    // The low command entry also rejects this genuine retired payload, not a forged token.
    var rejected_encoder = f.encoder();
    defer f.deinitEncoder(&rejected_encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectError(error.ResourceDestroyed, rejected_encoder.beginRenderPass(io, &guard, old, .{
            .color_attachments = &.{image.color()},
            .width = extent,
            .height = extent,
        }));
    }
    var fresh_encoder = f.encoder();
    defer f.deinitEncoder(&fresh_encoder);
    var fresh_pass = try f.begin(&fresh_encoder, &.{image.color()}, .{});
    defer deinitPass(&f, &fresh_pass);
    const fresh = fresh_pass.attachmentState();
    try t.expect(fresh != old);
    try t.expect(value.eql(&fresh.value));
    deinitPass(&f, &old_pass);
    f.release(alias);
    alias_owned = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(@as(u32, 0), old.header.reference_count);
        try t.expect(fresh.header.isAlive(&guard));
        const hit = try f.internLocked(&guard, value);
        defer hit.header.releaseUserLocked(&guard, io) catch unreachable;
        try t.expect(hit == fresh);
    }
    try endPass(&f, &fresh_pass);
    var finished = try fresh_encoder.finish();
    defer f.deinitFinished(&finished);
    const serial = try f.device.submit(f.allocator, io, &finished);
    try f.device.wait(io, serial);
    try expectPruned(&f, fresh);
}

const AliasRace = struct {
    fixture: *Fixture,
    value: attachment.AttachmentState,
    entered: std.Io.Event = .unset,
    result: ?*State = null,
    failure: ?anyerror = null,

    fn run(self: *AliasRace) void {
        const f = self.fixture;
        const io = f.threaded.io();
        f.device.acquireOperation(io) catch |err| {
            self.failure = err;
            self.entered.set(io);
            return;
        };
        defer f.device.releaseOperation(io);
        self.entered.set(io);
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        self.result = f.internLocked(&guard, self.value) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "native attachment concurrent misses acquire separate actual aliases consumed by high bundle" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const image = try Image.init(&f, .rgba8_unorm, 1);
    defer image.deinit(&f);
    var encoder = f.encoder();
    defer f.deinitEncoder(&encoder);
    var pass = try f.begin(&encoder, &.{image.color()}, .{});
    const retired = pass.attachmentState();
    const value = retired.value;
    deinitPass(&f, &pass);
    try expectPruned(&f, retired);
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    var locked = true;
    defer if (locked) guard.unlock(io);
    var first: AliasRace = .{ .fixture = &f, .value = value };
    var second: AliasRace = .{ .fixture = &f, .value = value };
    const first_thread = try std.Thread.spawn(.{}, AliasRace.run, .{&first});
    var first_joined = false;
    defer {
        if (locked) {
            guard.unlock(io);
            locked = false;
        }
        if (!first_joined) first_thread.join();
        if (first.result) |state| f.release(state);
    }
    const second_thread = try std.Thread.spawn(.{}, AliasRace.run, .{&second});
    var second_joined = false;
    defer {
        if (locked) {
            guard.unlock(io);
            locked = false;
        }
        if (!second_joined) second_thread.join();
        if (second.result) |state| f.release(state);
    }
    first.entered.waitUncancelable(io);
    second.entered.waitUncancelable(io);
    guard.unlock(io);
    locked = false;
    first_thread.join();
    first_joined = true;
    second_thread.join();
    second_joined = true;
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    const a = first.result orelse return error.TestUnexpectedResult;
    const b = second.result orelse return error.TestUnexpectedResult;
    try t.expect(a == b);
    try t.expect(a != retired);
    var bundle_encoder = try f.device.createRenderBundleEncoder(f.allocator, io, .{
        .color_formats = &.{.rgba8_unorm},
        .sample_count = 1,
    });
    {
        var inspect = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer inspect.unlock(io);
        defer bundle_encoder.deinit(io, &inspect);
        try t.expectEqual(@as(u32, 2), a.header.user_reference_count);
        const bundle = try bundle_encoder.finish(io, &inspect);
        defer bundle.header.releaseUserLocked(&inspect, io) catch unreachable;
        try t.expect(bundle.attachmentState() == a);
        try t.expect(a.header.isAlive(&inspect));
    }
}

// Forward real allocations unchanged, observing the genuine attached header only on failure.
// A direct factory has no allocation after WeakIndex.insert, so this identifies final insertion.
const AllocationProbe = struct {
    parent: std.mem.Allocator,
    objects: ?*core.ObjectList = null,
    attached_at_failure: ?*State = null,

    fn allocator(self: *AllocationProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(raw: *anyopaque, size: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *AllocationProbe = @ptrCast(@alignCast(raw));
        const memory = self.parent.rawAlloc(size, alignment, return_address);
        if (memory == null) {
            if (self.objects) |objects| {
                // This probe is armed only inside the original held ObjectGuard.
                var cursor = objects.head;
                for (0..objects.tracked_count) |_| {
                    const header = cursor orelse break;
                    if (header.kind == .attachment_state and header.state == .alive) {
                        self.attached_at_failure = @fieldParentPtr("header", header);
                        break;
                    }
                    cursor = header.node.next;
                }
            }
        }
        return memory;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, return_address: usize) bool {
        const self: *AllocationProbe = @ptrCast(@alignCast(raw));
        return self.parent.rawResize(memory, alignment, new_size, return_address);
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, return_address: usize) ?[*]u8 {
        const self: *AllocationProbe = @ptrCast(@alignCast(raw));
        return self.parent.rawRemap(memory, alignment, new_size, return_address);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *AllocationProbe = @ptrCast(@alignCast(raw));
        self.parent.rawFree(memory, alignment, return_address);
    }
};

test "native attachment finite fail N rolls back final weak bucket insertion after actual attach" {
    var reached_success = false;
    var saw_failure = false;
    var saw_attached_failure = false;
    for (0..64) |offset| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var probe: AllocationProbe = .{ .parent = failing.allocator() };
        var f: Fixture = undefined;
        try f.init(probe.allocator());
        defer f.deinit();
        const io = f.threaded.io();
        const image = try Image.init(&f, .rgba8_unorm, 1);
        defer image.deinit(&f);
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try f.device.bindObjectsLocked(&guard, f.allocator);
        const value = try attachment.AttachmentState.fromRenderPass(.{
            .colors = &.{.{
                .view = .{
                    .format = @intFromEnum(image.view.format),
                    .sample_count = image.view.texture.sample_count,
                    .aspects = image.view.aspects.toFlags(),
                },
                .resolve_target = null,
                .expands_resolve = false,
            }},
            .depth_stencil = null,
            .pls = null,
        }, .{ .max_color_attachments = 8, .max_storage_attachments = 4, .max_pls_bytes = 16 });
        const references = guard.objects.total_reference_count;
        const users = guard.objects.user_reference_count;
        const tracked = guard.objects.tracked_count;
        probe.objects = guard.objects;
        failing.fail_index = failing.alloc_index + offset;
        const result = f.internLocked(&guard, value);
        failing.fail_index = std.math.maxInt(usize);
        probe.objects = null;
        if (result) |state| {
            try state.header.releaseUserLocked(&guard, io);
            reached_success = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            if (probe.attached_at_failure) |state| {
                saw_attached_failure = true;
                try t.expectEqual(core.ObjectState.destroyed, state.header.state);
                try t.expectEqual(@as(u32, 0), state.header.reference_count);
                try t.expectEqual(@as(u32, 0), state.header.user_reference_count);
                try t.expect(!state.header.node.linked);
                try t.expect(state.header.remove_from_cache == null);
                try t.expect(state.header.cache_context == null);
                try t.expect(state.cache_next == null);
            }
        }
        try t.expectEqual(references, guard.objects.total_reference_count);
        try t.expectEqual(users, guard.objects.user_reference_count);
        try t.expectEqual(tracked, guard.objects.tracked_count);
        try t.expect(f.device.native.?.resource_store.?.attachments.isEmpty(&guard));
        {
            const retry = try f.internLocked(&guard, value);
            defer retry.header.releaseUserLocked(&guard, io) catch unreachable;
            const alias = try f.internLocked(&guard, value);
            defer alias.header.releaseUserLocked(&guard, io) catch unreachable;
            try t.expect(retry == alias);
            try t.expect(retry.header.isAlive(&guard));
        }
        try t.expect(f.device.native.?.resource_store.?.attachments.isEmpty(&guard));
        if (reached_success) break;
    }
    try t.expect(reached_success);
    try t.expect(saw_failure);
    try t.expect(saw_attached_failure);
}

test "native attachment high pass finite fail N rolls back temporary alias commands and leases" {
    var reached_success = false;
    var saw_failure = false;
    for (0..128) |offset| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var f: Fixture = undefined;
        try f.init(failing.allocator());
        defer f.deinit();
        const io = f.threaded.io();
        const image = try Image.init(&f, .rgba8_unorm, 1);
        defer image.deinit(&f);
        var encoder = f.encoder();
        var encoder_owned = true;
        defer if (encoder_owned) f.deinitEncoder(&encoder);
        var references: u64 = undefined;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try f.device.bindObjectsLocked(&guard, f.allocator);
            references = guard.objects.total_reference_count;
        }
        failing.fail_index = failing.alloc_index + offset;
        const result = f.begin(&encoder, &.{image.color()}, .{});
        failing.fail_index = std.math.maxInt(usize);
        if (result) |opened| {
            var pass = opened;
            defer deinitPass(&f, &pass);
            const state = pass.attachmentState();
            try endPass(&f, &pass);
            var finished = try encoder.finish();
            f.deinitFinished(&finished);
            try expectPruned(&f, state);
            reached_success = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
        }
        f.deinitEncoder(&encoder);
        encoder_owned = false;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expectEqual(references, guard.objects.total_reference_count);
            try t.expect(f.device.native.?.resource_store.?.attachments.isEmpty(&guard));
        }
        // Retry a real high producer, not a standalone key lookup.
        var retry_encoder = f.encoder();
        defer f.deinitEncoder(&retry_encoder);
        var retry = try f.begin(&retry_encoder, &.{image.color()}, .{});
        defer deinitPass(&f, &retry);
        try endPass(&f, &retry);
        var finished = try retry_encoder.finish();
        defer f.deinitFinished(&finished);
        const serial = try f.device.submit(f.allocator, io, &finished);
        try f.device.wait(io, serial);
        if (reached_success) break;
    }
    try t.expect(reached_success);
    try t.expect(saw_failure);
}

test "native attachment pending final root fail N leaves real Finished and all references intact" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var f: Fixture = undefined;
    try f.init(failing.allocator());
    defer f.deinit();
    const io = f.threaded.io();
    const pipeline = try f.pipeline(&rgba, null, 1, true);
    defer f.release(pipeline);
    // Sixteen distinct native views force growth beyond the initial root hash table.
    var images: [16]Image = undefined;
    var image_count: usize = 0;
    defer for (images[0..image_count]) |image| image.deinit(&f);
    var encoder = f.encoder();
    defer f.deinitEncoder(&encoder);
    for (&images) |*image| {
        image.* = try Image.init(&f, .rgba8_unorm, 1);
        image_count += 1;
        var pass = try f.begin(&encoder, &.{image.color()}, .{});
        defer deinitPass(&f, &pass);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
            try pass.draw(triangle_draw);
        }
        try endPass(&f, &pass);
    }
    var finished = try encoder.finish();
    defer f.deinitFinished(&finished);
    const blocks = finished.blocks.items.ptr;
    var reached_success = false;
    var failed_allocations: usize = 0;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const state = (try pipeline.renderOptions(&guard)).attachment_state;
        const references = guard.objects.total_reference_count;
        const state_references = state.header.reference_count;
        const pipeline_references = pipeline.header.reference_count;
        var view_references: [images.len]u32 = undefined;
        for (images, &view_references) |image, *count| count.* = image.view.header.reference_count;
        {
            // Aggregate headroom must be checked before acquiring even the first root lease.
            guard.objects.total_reference_count = std.math.maxInt(u64) - 1;
            defer guard.objects.total_reference_count = references;
            const overflow = native.PendingUses.prepareFinishedLocked(
                f.allocator,
                &guard,
                &f.device.core,
                &finished,
                f.device.limits.v1.max_immediate_size,
            );
            if (overflow) |prepared| {
                var pending = prepared;
                pending.releaseLocked(&guard, io);
                return error.TestUnexpectedResult;
            } else |err| {
                try t.expectEqual(error.ReferenceCountOverflow, err);
            }
            try t.expectEqual(std.math.maxInt(u64) - 1, guard.objects.total_reference_count);
            try t.expectEqual(state_references, state.header.reference_count);
            try t.expectEqual(pipeline_references, pipeline.header.reference_count);
            for (images, view_references) |image, count| try t.expectEqual(count, image.view.header.reference_count);
            try t.expectEqual(command.encoding_context.Status.finished, finished.status);
            try t.expectEqual(blocks, finished.blocks.items.ptr);
            try t.expectEqual(@as(usize, images.len), finished.render_pass_usages.items.len);
        }
        {
            var recording = try native.PendingUses.prepareDeclaredLocked(f.allocator, &guard, &f.device.core, &.{});
            defer recording.releaseLocked(&guard, io);
            guard.objects.total_reference_count = std.math.maxInt(u64);
            defer guard.objects.total_reference_count = references;
            const allocations = failing.alloc_index;
            try t.expectError(error.ReferenceCountOverflow, recording.retainRecordingRootLocked(
                &guard,
                &f.device.core,
                &state.header,
            ));
            try t.expectEqual(allocations, failing.alloc_index);
            try t.expect(recording.roots.count() == 0);
            try t.expectEqual(std.math.maxInt(u64), guard.objects.total_reference_count);
            try t.expectEqual(state_references, state.header.reference_count);
        }
        for (0..64) |offset| {
            failing.fail_index = failing.alloc_index + offset;
            const result = native.PendingUses.prepareFinishedLocked(
                f.allocator,
                &guard,
                &f.device.core,
                &finished,
                f.device.limits.v1.max_immediate_size,
            );
            failing.fail_index = std.math.maxInt(usize);
            if (result) |prepared| {
                var pending = prepared;
                defer pending.releaseLocked(&guard, io);
                try t.expect(pending.roots.contains(&state.header));
                try t.expect(pending.roots.contains(&pipeline.header));
                for (images) |image| try t.expect(pending.roots.contains(&image.view.header));
                try t.expectEqual(state_references + 1, state.header.reference_count);
                reached_success = true;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                failed_allocations += 1;
            }
            try t.expectEqual(references, guard.objects.total_reference_count);
            try t.expectEqual(state_references, state.header.reference_count);
            try t.expectEqual(pipeline_references, pipeline.header.reference_count);
            for (images, view_references) |image, count| try t.expectEqual(count, image.view.header.reference_count);
            try t.expectEqual(command.encoding_context.Status.finished, finished.status);
            try t.expectEqual(blocks, finished.blocks.items.ptr);
            try t.expectEqual(@as(usize, images.len), finished.render_pass_usages.items.len);
            if (reached_success) break;
        }
    }
    try t.expect(reached_success);
    try t.expect(failed_allocations >= 2);
    // Every failed preflight leaves this same real command owner retryable.
    const serial = try f.device.submit(f.allocator, io, &finished);
    try f.device.wait(io, serial);
}

test "native attachment GPU draw and bundle readback survive source users then actual pending roots release" {
    inline for (.{ false, true }) |use_bundle| {
        var f: Fixture = undefined;
        try f.init(t.allocator);
        defer f.deinit();
        const io = f.threaded.io();
        const image = try Image.init(&f, .rgba8_unorm, 1);
        defer image.deinit(&f);
        const pipeline = try f.pipeline(&rgba, null, 1, true);
        var pipeline_owned = true;
        defer if (pipeline_owned) f.release(pipeline);
        const readback = try f.device.createBuffer(f.allocator, io, .{
            .size = 256 * extent,
            .usage = .{ .map_read = true, .copy_dst = true },
        });
        defer f.release(readback);
        var bundle: ?*command.render_bundle.RenderBundle = null;
        defer if (bundle) |owned| f.release(owned);
        if (use_bundle) {
            var bundle_encoder = try f.device.createRenderBundleEncoder(f.allocator, io, .{
                .color_formats = &.{.rgba8_unorm},
                .sample_count = 1,
            });
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            defer bundle_encoder.deinit(io, &guard);
            try bundle_encoder.setPipeline(&guard, try pipeline.renderOptions(&guard));
            try bundle_encoder.draw(triangle_draw);
            bundle = try bundle_encoder.finish(io, &guard);
        }
        var encoder = f.encoder();
        defer f.deinitEncoder(&encoder);
        var pass = try f.begin(&encoder, &.{image.color()}, .{});
        defer deinitPass(&f, &pass);
        const state = pass.attachmentState();
        const value = state.value;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            const options = try pipeline.renderOptions(&guard);
            try t.expect(options.attachment_state == state);
            try t.expect(options.pipeline == @as(command.commands.Ref, @ptrCast(&pipeline.header)));
            // All source attachment aliases are released before frontend/native consumption.
            {
                const alias = try f.internLocked(&guard, value);
                defer alias.header.releaseUserLocked(&guard, io) catch unreachable;
                try t.expect(alias == state);
            }
            try t.expectEqual(@as(u32, 0), state.header.user_reference_count);
            if (bundle) |owned| {
                try t.expect(owned.attachmentState() == state);
                try pass.executeBundles(&guard, &.{owned});
            } else {
                try pass.setPipeline(&guard, options);
                try pass.draw(triangle_draw);
            }
            try pass.end(io, &guard);
            pass.deinit(io, &guard);
            try encoder.copyTextureToBuffer(.{
                .source = .{
                    .texture = image.texture,
                    .format = @intFromEnum(api.TextureFormat.rgba8_unorm),
                    .dimension = ._2d,
                    .aspect = .all,
                    .extent = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
                },
                .destination = .{
                    .buffer = try readback.ref(&guard),
                    .blocks_per_row = 64,
                    .rows_per_image = extent,
                },
                .copy_size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
            });
        }
        var finished = try encoder.finish();
        defer f.deinitFinished(&finished);
        const serial = try f.device.submit(f.allocator, io, &finished);
        try t.expectEqual(command.encoding_context.Status.destroyed, finished.status);
        // Ordinary refs were kept through admission. Actual submission now owns their use.
        f.release(pipeline);
        pipeline_owned = false;
        if (bundle) |owned| {
            f.release(owned);
            bundle = null;
        }
        {
            const context = f.device.native.?;
            context.queue_operation_mutex.lockUncancelable(io);
            defer context.queue_operation_mutex.unlock(io);
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expect(state.header.isAlive(&guard));
            try t.expectEqual(@as(u32, 0), state.header.user_reference_count);
            const pending = &context.pending_uses.?;
            try t.expect(pending.roots.contains(&state.header));
            try t.expect(pending.roots.contains(&pipeline.header));
            const alias = try f.internLocked(&guard, value);
            defer alias.header.releaseUserLocked(&guard, io) catch unreachable;
            try t.expect(alias == state);
        }
        try f.device.wait(io, serial);
        try expectPruned(&f, state);
        try expectRenderedPixels(&f, readback, serial);
        // After the real serial completed, equal construction must allocate a new live header.
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            const fresh = try f.internLocked(&guard, value);
            defer fresh.header.releaseUserLocked(&guard, io) catch unreachable;
            try t.expect(fresh != state);
            try t.expect(fresh.header.isAlive(&guard));
        }
    }
}

fn expectRenderedPixels(f: *Fixture, readback: *native.Buffer, serial: engine.buffer.Serial) !void {
    const io = f.threaded.io();
    {
        const context = f.device.native.?;
        context.queue_operation_mutex.lockUncancelable(io);
        defer context.queue_operation_mutex.unlock(io);
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 256 * extent });
        try t.expectEqual(engine.buffer.Buffer.MapCompletion.mapped, try readback.native.completeMap(generation, serial));
        const bytes = try readback.native.getConstMappedRange(0, 256 * extent);
        const center = bytes[8 * 256 + 8 * 4 ..][0..4];
        try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, center);
        try t.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, bytes[0..4]);
    }
    try f.device.unmapBuffer(io, readback);
}

// Immutable SPIR-V fixture whose fragment output is location one, for a real sparse pass.
// Supplied words are neither patched at runtime nor changed by shader creation.
const sparse_fragment_words = [_]u32{
    0x07230203, 0x00010000, 0,          15,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0006000f, 4,          1,          0x6e69616d, 0,
    7,          0x00030010, 1,          7,          0x00030005,
    10,         0x00646572, 0x00040005, 11,         0x65657267,
    0x0000006e, 0x00040047, 10,         1,          7,
    0x00040047, 11,         1,          9,          0x00040047,
    7,          30,         1,          0x00020013, 2,
    0x00030021, 3,          2,          0x00030016, 4,
    32,         0x00040017, 5,          4,          4,
    0x00040020, 6,          3,          5,          0x0004003b,
    6,          7,          3,          0x0004002b, 4,
    8,          0,          0x0004002b, 4,          9,
    0x3f800000, 0x00040032, 4,          10,         0x3f800000,
    0x00040032, 4,          11,         0,          0x00050036,
    2,          1,          0,          3,          0x000200f8,
    12,         0x00070050, 5,          13,         10,
    11,         8,          9,          0x0003003e, 7,
    13,         0x000100fd, 0x00010038,
};
