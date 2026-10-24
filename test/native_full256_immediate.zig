//! Real GPU proof of all 256 user immediate bytes and typed native bundle replay.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const command = dusk.command;
const native = engine.native_resources;
const Encoder = command.command_encoder.CommandEncoder;
const Finished = command.encoding_context.Finished;
const immediate_size: u32 = 256;
const sentinel: u8 = 0xa5;
const triangle: command.render_encoder_base.DrawVertexCountOptions = .{
    .vertex_count = 3,
    .instance_count = 1,
    .first_vertex = 0,
    .first_instance = 0,
};

// No skip: an unavailable GPU or a device below the requested limit is a failure.
test "native full256 word63 and viewport bundle user words reach actual GPU readback" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("full256 instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("full256 adapter teardown failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    const adapter = blk: {
        for (adapters.items) |*candidate| {
            if (candidate.limits.v1.max_immediate_size >= immediate_size) break :blk candidate;
        }
        return error.Full256ImmediateLimitRequired;
    };
    const required: api.Limits = .{ .max_immediate_size = immediate_size };
    var callback_context: u8 = 0;
    var device = try adapter.createDevice(allocator, io, .{
        .adapter = adapter,
        .feature_level = .core,
        .required_limits = &required,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("full256 device teardown failed");
    try exercise(allocator, io, &device);
}

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("full256 native proof reported an uncaptured error");
}

/// Uses the supplied real high device; its effective limit must admit all 256 bytes.
/// Every successful resource factory call owns one user alias released here.
pub fn exercise(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device) !void {
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    if (device.native == null) return error.NativeBackendRequired;
    if (device.limits.v1.max_immediate_size < immediate_size) {
        return error.Full256ImmediateLimitRequired;
    }
    try exerciseCompute(allocator, io, device);
    try exerciseRender(allocator, io, device);
}

fn release(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device, resource: anytype) void {
    device.release(allocator, io, resource) catch @panic("full256 user alias release failed");
}

fn deinitEncoder(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    encoder: *Encoder,
) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    encoder.deinit(allocator, io, &guard);
}

fn deinitFinished(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    finished: *Finished,
) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    finished.deinit(allocator, io, &guard);
}

fn exerciseCompute(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device) !void {
    const output = try device.createBuffer(allocator, io, .{
        .size = 4,
        .usage = .{ .storage = true, .copy_src = true },
    });
    defer release(allocator, io, device, output);
    const readback = try device.createBuffer(allocator, io, .{
        .size = 16,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer release(allocator, io, device, readback);
    const shader = try device.createShaderModule(allocator, io, .{ .words = &compute_words });
    defer release(allocator, io, device, shader);
    const group_layout = try device.createBindGroupLayout(allocator, io, .{
        .entries = &.{.{
            .binding_number = 0,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = 4,
            } },
        }},
    });
    defer release(allocator, io, device, group_layout);
    const layout = try device.createPipelineLayout(allocator, io, .{
        .groups = &.{group_layout},
        .immediate_size = immediate_size,
    });
    defer release(allocator, io, device, layout);
    const group = try device.createBindGroup(allocator, io, .{
        .layout = layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 0,
            .buffer = output,
            .offset = 0,
            .size = 4,
            .kind = .storage,
            .stages = .{ .compute = true },
        } }},
    });
    defer release(allocator, io, device, group);
    const pipeline = try device.createComputePipeline(allocator, io, .{
        .layout = layout,
        .compute = .{ .module = shader, .entry_point = "main", .stage = .compute },
    });
    defer release(allocator, io, device, pipeline);
    const user_words = comptime blk: {
        var words: [64]u32 = @splat(0x10203040);
        words[16] = 37;
        words[17] = 59;
        words[63] = 113;
        break :blk words;
    };
    const patch = [_]u32{173};
    var encoder = Encoder.init(allocator, device.coreDevice().borrow(), .{});
    defer deinitEncoder(allocator, io, device, &encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        const padding: [16]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
        const layout_input = try layout.input(&guard);
        const layout_id = @intFromPtr(&group_layout.header);
        for (0..2) |sample| {
            var pass = try encoder.beginComputePass(.{});
            defer pass.deinit();
            try pass.setPipeline(.{
                .pipeline = try pipeline.ref(&guard),
                .requirements = .{
                    .bind_group_layout_mask = 1,
                    .bind_group_layout_ids = .{ layout_id, 0, 0, 0 },
                    .immediate_slot_mask = try layout_input.immediateMask(),
                },
            });
            try pass.setBindGroup(.{
                .index = 0,
                .group = try group.ref(&guard),
                .layout_id = layout_id,
                .min_binding_buffer_size = 4,
                .buffers = &.{.{
                    .buffer = try output.ref(&guard),
                    .usage = (api.BufferUsage{ .storage = true }).toFlags(),
                }},
            });
            try pass.setImmediates(.{ .offset = 0, .data = std.mem.sliceAsBytes(&user_words) });
            try pass.dispatch(.{});
            if (sample == 1) {
                // The first dispatch clears dirty state; this write must dirty bit 63 alone.
                try pass.setImmediates(.{ .offset = 252, .data = std.mem.sliceAsBytes(&patch) });
                try pass.dispatch(.{});
            }
            try pass.end();
            try encoder.copyBufferToBuffer(.{
                .source = try output.ref(&guard),
                .destination = try readback.ref(&guard),
                .destination_offset = sample * 8,
                .size = 4,
            });
        }
    }
    var finished = try encoder.finish();
    defer deinitFinished(allocator, io, device, &finished);
    const serial = try device.submit(allocator, io, &finished);
    try device.wait(io, serial);
    try device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 16 });
    defer device.unmapBuffer(io, readback) catch @panic("full256 compute unmap failed");
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        const bytes = try readback.native.getConstMappedRange(0, 16);
        if (std.mem.readInt(u32, bytes[0..4], .little) != 113) {
            return error.Full256ComputeValueMismatch;
        }
        if (std.mem.readInt(u32, bytes[8..12], .little) != 173) {
            return error.Full256ComputePatchMismatch;
        }
        try expectSentinel(bytes[4..8]);
        try expectSentinel(bytes[12..16]);
        if (!std.mem.eql(u32, shader.words, &compute_words)) {
            return error.Full256ShaderWordsMutated;
        }
    }
}

fn colorWords(comptime red: f32, comptime green: f32, comptime blue: f32) [64]u32 {
    var words: [64]u32 = @splat(0x10203040);
    words[16] = @bitCast(red);
    words[17] = @bitCast(green);
    words[63] = @bitCast(blue);
    return words;
}

fn exerciseRender(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device) !void {
    const vertex = try device.createShaderModule(allocator, io, .{ .words = &vertex_words });
    defer release(allocator, io, device, vertex);
    const fragment = try device.createShaderModule(allocator, io, .{ .words = &fragment_words });
    defer release(allocator, io, device, fragment);
    const layout = try device.createPipelineLayout(allocator, io, .{
        .groups = &.{},
        .immediate_size = immediate_size,
    });
    defer release(allocator, io, device, layout);
    const pipeline = try device.createRenderPipeline(allocator, io, .{
        .layout = layout,
        .vertex = .{ .module = vertex, .entry_point = "main", .stage = .vertex },
        .fragment = .{ .module = fragment, .entry_point = "main", .stage = .fragment },
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });
    defer release(allocator, io, device, pipeline);
    const target = try device.createTexture(allocator, io, .{
        .size = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer release(allocator, io, device, target);
    const view = try device.createTextureView(allocator, io, .{
        .texture = target,
        .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
    });
    defer release(allocator, io, device, view);
    const readback = try device.createBuffer(allocator, io, .{
        .size = 256,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer release(allocator, io, device, readback);
    const red_words = comptime colorWords(1, 0, 0);
    const green_words = comptime colorWords(0, 1, 0);
    const black_words = comptime colorWords(0, 0, 0);
    const blue_patch = [_]u32{@bitCast(@as(f32, 1))};
    var bundle_encoder = try device.createRenderBundleEncoder(allocator, io, .{
        .color_formats = &.{.rgba8_unorm},
        .sample_count = 1,
    });
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        bundle_encoder.deinit(io, &guard);
    }
    const bundle = blk: {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        const options = try pipeline.renderOptions(&guard);
        if (options.pipeline != @as(command.commands.Ref, @ptrCast(&pipeline.header))) {
            return error.Full256WrongPipelineOwner;
        }
        try bundle_encoder.setPipeline(&guard, options);
        try bundle_encoder.setImmediates(.{ .offset = 0, .data = std.mem.sliceAsBytes(&green_words) });
        try bundle_encoder.draw(triangle);
        break :blk try bundle_encoder.finish(io, &guard);
    };
    defer release(allocator, io, device, bundle);
    var encoder = Encoder.init(allocator, device.coreDevice().borrow(), .{});
    defer deinitEncoder(allocator, io, device, &encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        const padding: [256]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
    }
    // This high factory takes its own guard; never enter it under ObjectGuard.
    var pass = try device.beginRenderPass(allocator, io, &encoder, .{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        }},
        .width = 4,
        .height = 1,
    });
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        pass.deinit(io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try pass.setImmediates(.{ .offset = 0, .data = std.mem.sliceAsBytes(&red_words) });
        try pass.setViewport(.{ .width = 4, .height = 1, .min_depth = 0.25, .max_depth = 0.75 });
        try pass.setScissorRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 });
        try pass.draw(triangle);
        try pass.setViewport(.{ .width = 4, .height = 1, .min_depth = 0.125, .max_depth = 0.875 });
        try pass.setScissorRect(.{ .x = 1, .y = 0, .width = 2, .height = 1 });
        try pass.executeBundles(&guard, &.{bundle});
        // Bundles invalidate programmable state. Selection restores real shader-stage flags.
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try pass.setImmediates(.{ .offset = 0, .data = std.mem.sliceAsBytes(&black_words) });
        try pass.setImmediates(.{ .offset = 252, .data = std.mem.sliceAsBytes(&blue_patch) });
        try pass.setViewport(.{ .width = 4, .height = 1, .min_depth = 0.375, .max_depth = 0.625 });
        try pass.setScissorRect(.{ .x = 3, .y = 0, .width = 1, .height = 1 });
        try pass.draw(triangle);
        try pass.end(io, &guard);
        try encoder.copyTextureToBuffer(.{
            .source = .{
                .texture = target,
                .format = @backingInt(api.TextureFormat.rgba8_unorm),
                .dimension = ._2d,
                .aspect = .all,
                .extent = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
            },
            .destination = .{
                .buffer = try readback.ref(&guard),
                .blocks_per_row = 64,
                .rows_per_image = 1,
            },
            .copy_size = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer deinitFinished(allocator, io, device, &finished);
    const serial = try device.submit(allocator, io, &finished);
    try device.wait(io, serial);
    try device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 256 });
    defer device.unmapBuffer(io, readback) catch @panic("full256 render unmap failed");
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        const bytes = try readback.native.getConstMappedRange(0, 256);
        const expected = [_]u8{
            255, 0,   0, 255, 0, 255, 0,   255,
            0,   255, 0, 255, 0, 0,   255, 255,
        };
        if (!std.mem.eql(u8, &expected, bytes[0..16])) return error.Full256RenderPixelsMismatch;
        try expectSentinel(bytes[16..256]);
        if (!std.mem.eql(u32, vertex.words, &vertex_words)) return error.Full256ShaderWordsMutated;
        if (!std.mem.eql(u32, fragment.words, &fragment_words)) return error.Full256ShaderWordsMutated;
    }
}

fn expectSentinel(bytes: []const u8) error{Full256ReadbackPaddingModified}!void {
    for (bytes) |byte| {
        if (byte != sentinel) return error.Full256ReadbackPaddingModified;
    }
}

// SPIR-V 1.0: Uniform + BufferBlock is the storage-buffer ABI. Push member 0
// remains at byte 252; neither fixture creation nor replay may compact that offset.
const compute_words = [_]u32{
    0x07230203, 0x00010000, 0, 18, 0,
    0x00020011, 1, // OpCapability Shader
    0x0003000e, 0, 1, // OpMemoryModel Logical GLSL450
    0x0005000f, 5, 1, 0x6e69616d, 0, // OpEntryPoint GLCompute %1 "main"
    0x00060010, 1, 17, 1, 1, 1, // LocalSize 1 1 1
    0x00030047, 5, 3, // %5 BufferBlock
    0x00050048, 5, 0, 35, 0, // storage member Offset 0
    0x00040047, 7, 34, 0, // %7 DescriptorSet 0
    0x00040047, 7, 33, 0, // %7 Binding 0
    0x00030047, 10, 2, // push struct Block
    0x00050048, 10, 0, 35, 252, // push member Offset 252
    0x00020013, 2, // void
    0x00030021, 3, 2, // function type
    0x00040015, 4, 32, 0, // uint
    0x0003001e, 5, 4, // storage struct
    0x00040020, 6, 2, 5, // Uniform storage struct pointer
    0x0004003b, 6, 7, 2, // storage variable
    0x00040020, 8, 2, 4, // Uniform uint pointer
    0x0004002b, 4, 9, 0, // uint zero
    0x0003001e, 10, 4, // push struct
    0x00040020, 11, 9, 10, // PushConstant struct pointer
    0x0004003b, 11, 12, 9, // push variable
    0x00040020, 13, 9, 4, // PushConstant uint pointer
    0x00050036, 2,  1, 0, 3, // main
    0x000200f8, 14,
    0x00050041, 13, 15, 12, 9, // push member pointer
    0x0004003d, 4, 16, 15, // load word63
    0x00050041, 8, 17, 7, 9, // storage member pointer
    0x0003003e, 17,         16, // store unchanged word63
    0x000100fd, 0x00010038,
};

// VertexIndex produces (-1,-1), (3,-1), (-1,3): a triangle covering all pixels.
const vertex_words = [_]u32{
    0x07230203, 0x00010000, 0,          26,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0007000f, 0,          1,          0x6e69616d, 0,
    10,         11,
    0x00040047, 10, 11, 42, // VertexIndex
    0x00040047, 11, 11,         0, // Position
    0x00020013, 2,  0x00030021, 3,
    2,
    0x00020014, 4, // bool
    0x00040015, 5, 32, 1, // signed int
    0x00030016, 6, 32, // float
    0x00040017, 7, 6,  4, // vec4
    0x00040020, 8, 1,  5,
    0x00040020, 9, 3,  7,
    0x0004003b, 8, 10, 1,
    0x0004003b, 9, 11, 3,
    0x0004002b, 5, 12, 0,
    0x0004002b, 5, 13, 1,
    0x0004002b, 6, 14, 0,
    0x0004002b, 6, 15, 0x3f800000, // 1
    0x0004002b, 6, 16, 0xbf800000, // -1
    0x0004002b, 6,          17, 0x40400000, // 3
    0x0004002b, 5,          18, 2,
    0x00050036, 2,          1,  0,
    3,          0x000200f8, 19, 0x0004003d,
    5,          20,         10,
    0x000500aa, 4, 21, 20, 13, // index == 1
    0x000500aa, 4, 22, 20, 18, // index == 2
    0x000600a9, 6, 23, 21, 17, 16, // x
    0x000600a9, 6,          24, 22, 17,         16, // y
    0x00070050, 7,          25, 23, 24,         14,
    15,         0x0003003e, 11, 25, 0x000100fd, 0x00010038,
};

// Fragment RGB reads actual user words16,17,63, not an engine-private depth ABI.
const fragment_words = [_]u32{
    0x07230203, 0x00010000, 0,          25,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0006000f, 4,          1,          0x6e69616d, 0,
    12,
    0x00030010, 1, 7, // OriginUpperLeft
    0x00040047, 12, 30, 0, // output Location 0
    0x00030047, 7,          2, // push struct Block
    0x00050048, 7,          0,
    35,         64,         0x00050048,
    7,          1,          35,
    68,         0x00050048, 7,
    2,          35,         252,
    0x00020013, 2,          0x00030021,
    3,          2,          0x00030016,
    4,          32,         0x00040017,
    5,          4,          4,
    0x00040015, 6,          32,
    0,          0x0005001e, 7,
    4,          4,          4,
    0x00040020, 8,          9,
    7,          0x0004003b, 8,
    9,          9,          0x00040020,
    10,         9,          4,
    0x00040020, 11,         3,
    5,          0x0004003b, 11,
    12,         3,          0x0004002b,
    6,          13,         0,
    0x0004002b, 6,          14,
    1,          0x0004002b, 6,
    15,         2,          0x0004002b,
    4,          16,         0x3f800000,
    0x00050036, 2,          1,
    0,          3,          0x000200f8,
    17,         0x00050041, 10,
    18,         9,          13,
    0x0004003d, 4,          19,
    18,         0x00050041, 10,
    20,         9,          14,
    0x0004003d, 4,          21,
    20,         0x00050041, 10,
    22,         9,          15,
    0x0004003d, 4,          23,
    22,         0x00070050, 5,
    24,         19,         21,
    23,         16,         0x0003003e,
    12,         24,         0x000100fd,
    0x00010038,
};
