//! GPU render consumers for native blits and typed attachment clears.
const std = @import("std");
const api = @import("../api/api.zig");
const vulkan = @import("vulkan");
const kernels = @import("native_kernels.zig");
const common = @import("native_blit_common.zig");
const texture = @import("texture.zig");
const format = @import("format.zig");
const buffer = @import("buffer.zig");
const shaders = @import("native_blit_shader_definitions.zig");
const blit = @import("native_blit.zig");

pub const Error = common.Error || error{
    InvalidBlitLayout,
    InvalidBlitFilter,
    InvalidBlitTransform,
    InvalidClearType,
    BlitSourceHasNoDepth,
    BlitTargetHasNoDepth,
    BlitTargetHasNoStencil,
};

pub const ColorTransform = struct {
    source_transfer: [7]f32,
    destination_transfer: [7]f32,
    matrix: [9]f32,
};

pub const BufferLayout = struct {
    offset_bytes: u64 = 0,
    bytes_per_row: u32,
    rows_per_image: u32,
};

pub const BufferCopyOptions = struct {
    source: kernels.BufferRange,
    target: common.Target,
    rectangle: common.Rect,
    layout: BufferLayout,
    format: api.TextureFormat,
    color_slot: u3 = 0,
};

pub const ColorCopyOptions = struct {
    source: *texture.TextureView,
    target: common.Target,
    source_rectangle: common.Rect,
    rectangle: common.Rect,
    color_slot: u3 = 0,
    filter: api.FilterMode = .nearest,
    flip_y: bool = false,
    swizzle_red_blue: bool = false,
    premultiply_alpha: bool = false,
    unpremultiply_alpha: bool = false,
    decode_srgb: bool = false,
    encode_srgb: bool = false,
    decode_destination_srgb: bool = false,
    sample_index: u32 = 0,
    source_layer: u32 = 0,
    color_transform: ?ColorTransform = null,
    source_opaque: bool = false,
};

pub const DepthCopyOptions = struct {
    source: *texture.TextureView,
    target: common.Target,
    source_rectangle: common.Rect,
    rectangle: common.Rect,
    sample_index: u32 = 0,
    source_layer: u32 = 0,
};

pub const ClearValue = union(enum) {
    float: [4]f32,
    uint: [4]u32,
    sint: [4]i32,
};

pub const DrawClearOptions = struct {
    target: common.Target,
    rectangle: common.Rect,
    values: [8]?ClearValue = @splat(null),
};

pub const PreparedClear = struct {
    draws: [8]?kernels.PreparedDraw = @splat(null),
};

pub fn bufferToColor(context: kernels.Context, options: BufferCopyOptions) Error!void {
    const target = options.target.colors[options.color_slot] orelse
        return error.BlitFormatMismatch;
    const input_format = try formatInfo(context, options.format);
    if (!input_format.isColor() or !target.format_info.isColor())
        return error.BlitFormatMismatch;
    if (input_format.aspect_info[0].base_type != target.format_info.aspect_info[0].base_type)
        return error.BlitFormatMismatch;
    try bufferToAttachment(context, options, .buffer_to_color);
}

pub fn bufferToDepth(context: kernels.Context, options: BufferCopyOptions) Error!void {
    const target = options.target.depth_stencil orelse return error.BlitTargetHasNoDepth;
    if (target.aspects.depth == 0) return error.BlitTargetHasNoDepth;
    if (options.format != .depth16_unorm and options.format != .depth32_float)
        return error.BlitFormatMismatch;
    try bufferToAttachment(context, options, .buffer_to_depth);
}

pub fn bufferToStencil(context: kernels.Context, options: BufferCopyOptions) Error!void {
    const target = options.target.depth_stencil orelse return error.BlitTargetHasNoStencil;
    if (target.aspects.stencil == 0) return error.BlitTargetHasNoStencil;
    if (options.format != .stencil8) return error.BlitFormatMismatch;
    const procs = context.queue.context.dispatch.device orelse return error.MissingDeviceProc;
    if (procs.cmd_clear_attachments == null) return error.MissingDeviceProc;
    try bufferToAttachment(context, options, .buffer_to_stencil);
}

fn bufferToAttachment(
    context: kernels.Context,
    options: BufferCopyOptions,
    id: kernels.KernelId,
) Error!void {
    try common.checkRect(options.target, options.rectangle);
    try common.checkRange(options.source);
    if (options.target.attachments.value.sample_count != 1)
        return error.BlitSampleCountMismatch;
    if (options.rectangle.width == 0 or options.rectangle.height == 0) return;
    const input_format = try formatInfo(context, options.format);
    const texel_bytes = if (options.format == .stencil8)
        @as(u32, 1)
    else
        input_format.aspect_info[0].block.byte_size;
    if (texel_bytes == 0 or input_format.is_compressed) return error.BlitFormatMismatch;
    if (options.layout.rows_per_image < options.rectangle.height)
        return error.InvalidBlitLayout;
    const required = try requiredBytes(
        options.rectangle.width,
        options.rectangle.height,
        options.layout.bytes_per_row,
        texel_bytes,
    );
    if (options.layout.offset_bytes > options.source.size or
        required > options.source.size - options.layout.offset_bytes)
        return error.KernelRangeOverflow;
    const maximum = storageWindow(context);
    // Alignment padding belongs to the descriptor window, not the texel count.
    if (maximum < 8 or maximum - 7 < texel_bytes) return error.BindingRangeExceedsLimit;
    const width_maximum = @divFloor(maximum - 7, texel_bytes);
    var x: u32 = 0;
    var commands: u32 = 0;
    errdefer context.queue.poisonRecording();
    while (x < options.rectangle.width) {
        const width = @min(width_maximum, options.rectangle.width - x);
        const row_bytes = width * texel_bytes;
        const height_maximum = 1 + @divFloor(
            maximum - 7 - row_bytes,
            options.layout.bytes_per_row,
        );
        var y: u32 = 0;
        while (y < options.rectangle.height) {
            if (commands == 1 << 24) return error.BlitCommandLimitExceeded;
            commands += 1;
            const height = @min(height_maximum, options.rectangle.height - y);
            const size = try requiredBytes(
                width,
                height,
                options.layout.bytes_per_row,
                texel_bytes,
            );
            const relative = try common.add(options.layout.offset_bytes, try common.add(try common.mul(y, options.layout.bytes_per_row), try common.mul(x, texel_bytes)));
            const source: kernels.BufferRange = .{
                .owner = options.source.owner,
                .offset = try common.add(options.source.offset, relative),
                .size = size,
            };
            const input = try readableInput(context, source);
            var tile = options;
            tile.rectangle = .{
                .x = options.rectangle.x + x,
                .y = options.rectangle.y + y,
                .width = width,
                .height = height,
            };
            tile.layout.offset_bytes = 0;
            tile.layout.rows_per_image = height;
            try drawBufferTile(context, tile, input, id);
            y += height;
        }
        x += width;
    }
}

fn readableInput(context: kernels.Context, input: kernels.BufferRange) Error!kernels.BufferRange {
    const native = input.owner.native;
    const maximum = storageWindow(context);
    const storage = buffer.read_only_storage_buffer | buffer.internal_storage_buffer;
    if (native.internal_usage & storage != 0 and native.size <= maximum and
        native.size >= 4 and native.size % 4 == 0 and input.offset <= std.math.maxInt(u32))
        return input;
    return common.stageInput(context, input);
}

fn drawBufferTile(
    context: kernels.Context,
    options: BufferCopyOptions,
    input: kernels.BufferRange,
    id: kernels.KernelId,
) Error!void {
    const pass = try common.createPass(context, options.target);
    const bindings = [_]kernels.Binding{.{ .buffer = .{
        .owner = input.owner,
        .offset = 0,
        .size = input.owner.native.size,
    } }};
    var prepared: [8]kernels.PreparedDraw = undefined;
    const count: usize = if (id == .buffer_to_stencil) 8 else 1;
    const parameters = try unpackParameters(options, input.offset);
    for (0..count) |index| {
        const key: kernels.KernelKey = .{
            .id = id,
            .storage_format = options.format,
            .attachments = options.target.attachments,
            .color_write_slots = if (id == .buffer_to_color)
                @as(u8, 1) << options.color_slot
            else
                0,
            .stencil_write_bit = if (id == .buffer_to_stencil) @intCast(index) else null,
        };
        prepared[index] = if (index == 0)
            try kernels.prepareDraw(context, .{
                .key = key,
                .bindings = &bindings,
                .parameters = &parameters,
                .compatible_render_pass = pass.handle,
            })
        else
            try kernels.prepareDrawReuseBindings(context, .{
                .key = key,
                .prepared = prepared[0],
                .compatible_render_pass = pass.handle,
            });
    }
    try common.beginPass(context, options.target, pass);
    if (id == .buffer_to_stencil) clearStencilRectangle(context, options.rectangle);
    for (0..count) |index| {
        try kernels.recordDraw(context, drawOptions(
            prepared[index],
            pass.handle,
            options.target,
            options.rectangle,
            if (id == .buffer_to_stencil) @as(u32, 1) << @as(u5, @intCast(index)) else 0,
        ));
    }
    try common.endPass(context, options.target);
}

fn clearStencilRectangle(context: kernels.Context, rectangle: common.Rect) void {
    const procs = context.queue.context.dispatch.device.?;
    const attachment: vulkan.VkClearAttachment = .{
        .aspectMask = vulkan.VK_IMAGE_ASPECT_STENCIL_BIT,
        .colorAttachment = 0,
        .clearValue = .{ .depthStencil = .{ .depth = 0, .stencil = 0 } },
    };
    const region: vulkan.VkClearRect = .{
        .rect = scissor(rectangle),
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    procs.cmd_clear_attachments.?(context.recording.command_buffer, 1, &attachment, 1, &region);
}

pub fn prepareDrawClear(
    context: kernels.Context,
    options: DrawClearOptions,
    compatible_render_pass: vulkan.VkRenderPass,
) Error!PreparedClear {
    try common.checkRect(options.target, options.rectangle);
    var result: PreparedClear = .{};
    // Check all slots before preparing any draw or changing native state.
    for (options.values, 0..) |maybe_value, slot| {
        const value = maybe_value orelse continue;
        const target = options.target.colors[slot] orelse return error.BlitFormatMismatch;
        if (!target.format_info.isColor()) return error.BlitFormatMismatch;
        const scalar = target.format_info.aspect_info[0].base_type;
        const valid = switch (value) {
            .float => scalar == .float,
            .uint => scalar == .uint,
            .sint => scalar == .sint,
        };
        if (!valid) return error.InvalidClearType;
    }
    if (options.rectangle.width == 0 or options.rectangle.height == 0) return result;
    errdefer context.queue.poisonRecording();
    var parameters: [128]u8 = @splat(0);
    for (options.values, 0..) |maybe_value, slot| {
        if (maybe_value) |value| encodeClear(&parameters, @intCast(slot), value);
    }
    var first_prepared: ?kernels.PreparedDraw = null;
    for (options.values, 0..) |maybe_value, slot| {
        if (maybe_value == null) continue;
        const key: kernels.KernelKey = .{
            .id = .clear_color,
            .attachments = options.target.attachments,
            .color_write_slots = @as(u8, 1) << @as(u3, @intCast(slot)),
        };
        const prepared = if (first_prepared) |first|
            try kernels.prepareDrawReuseBindings(context, .{
                .key = key,
                .prepared = first,
                .compatible_render_pass = compatible_render_pass,
            })
        else
            try kernels.prepareDraw(context, .{
                .key = key,
                .bindings = &.{},
                .parameters = &parameters,
                .compatible_render_pass = compatible_render_pass,
            });
        if (first_prepared == null) first_prepared = prepared;
        result.draws[slot] = prepared;
    }
    return result;
}

pub fn recordPreparedClear(
    context: kernels.Context,
    prepared: PreparedClear,
    actual_render_pass: vulkan.VkRenderPass,
    target: common.Target,
    rectangle: common.Rect,
) Error!void {
    try common.checkRect(target, rectangle);
    errdefer context.queue.poisonRecording();
    for (prepared.draws) |maybe_draw| {
        const draw = maybe_draw orelse continue;
        try kernels.recordDraw(context, drawOptions(draw, actual_render_pass, target, rectangle, 0));
    }
}

pub fn drawClear(context: kernels.Context, options: DrawClearOptions) Error!void {
    try common.checkRect(options.target, options.rectangle);
    if (options.rectangle.width == 0 or options.rectangle.height == 0) return;
    var any_value = false;
    for (options.values) |value| any_value = any_value or value != null;
    if (!any_value) return;
    errdefer context.queue.poisonRecording();
    const pass = try common.createPass(context, options.target);
    const prepared = try prepareDrawClear(context, options, pass.handle);
    try common.beginPass(context, options.target, pass);
    try recordPreparedClear(context, prepared, pass.handle, options.target, options.rectangle);
    try common.endPass(context, options.target);
}

pub fn depthToDepth(context: kernels.Context, input_options: DepthCopyOptions) Error!void {
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try validateSignedSource(input_options.source_rectangle, input_options.source_layer);
    var options = input_options;
    options.source = try common.loadDepthView(context, options.source);
    if (options.source.aspects.depth == 0) return error.BlitSourceHasNoDepth;
    const target = options.target.depth_stencil orelse return error.BlitTargetHasNoDepth;
    if (target.aspects.depth == 0) return error.BlitTargetHasNoDepth;
    if (options.source.texture.sample_count != 1 or
        options.target.attachments.value.sample_count != 1 or options.sample_index != 0)
        return error.BlitSampleCountMismatch;
    if (options.source_rectangle.width != options.rectangle.width or
        options.source_rectangle.height != options.rectangle.height)
        return error.InvalidBlitRegion;
    try validateSource(context, options.source, options.source_rectangle, options.source_layer);
    try common.checkRect(options.target, options.rectangle);
    if (aliasesTarget(options.source, options.target)) return error.BlitSourceTargetAlias;
    if (options.rectangle.width == 0 or options.rectangle.height == 0) return;
    const color_options: ColorCopyOptions = .{
        .source = options.source,
        .target = options.target,
        .source_rectangle = options.source_rectangle,
        .rectangle = options.rectangle,
        .source_layer = options.source_layer,
    };
    var parameters = copyParameters(context, color_options);
    common.putWord(&parameters, 12, 0);
    const bindings = [_]kernels.Binding{.{ .view = options.source }};
    errdefer context.queue.poisonRecording();
    const pass = try common.createPass(context, options.target);
    const prepared = try kernels.prepareDraw(context, .{
        .key = .{
            .id = .depth_to_depth,
            .source_format = options.source.format,
            .source_dimension = options.source.dimension,
            .attachments = options.target.attachments,
        },
        .bindings = &bindings,
        .parameters = parameters[0..96],
        .compatible_render_pass = pass.handle,
    });
    try common.beginPass(context, options.target, pass);
    try kernels.recordDraw(context, drawOptions(
        prepared,
        pass.handle,
        options.target,
        options.rectangle,
        0,
    ));
    try common.endPass(context, options.target);
}

pub fn colorToColor(context: kernels.Context, input_options: ColorCopyOptions) Error!void {
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try validateSignedSource(input_options.source_rectangle, input_options.source_layer);
    var options = input_options;
    options.source = try common.loadView(context, options.source);
    const target = options.target.colors[options.color_slot] orelse
        return error.BlitFormatMismatch;
    if (!options.source.format_info.isColor() or !target.format_info.isColor())
        return error.BlitFormatMismatch;
    const scalar = options.source.format_info.aspect_info[0].base_type;
    if (scalar != target.format_info.aspect_info[0].base_type) return error.BlitFormatMismatch;
    if (options.filter != .nearest and options.filter != .linear) return error.InvalidBlitFilter;
    if (scalar != .float) {
        if (options.filter != .nearest) return error.InvalidBlitFilter;
        if (options.premultiply_alpha or options.unpremultiply_alpha or
            options.decode_srgb or options.encode_srgb or options.color_transform != null or
            options.source_opaque or options.decode_destination_srgb)
            return error.InvalidBlitTransform;
    }
    if (options.sample_index >= options.source.texture.sample_count)
        return error.BlitSampleCountMismatch;
    if (options.source.texture.sample_count != 1 and options.filter != .nearest)
        return error.InvalidBlitFilter;
    if (options.target.attachments.value.sample_count != 1)
        return error.BlitSampleCountMismatch;
    try validateSource(context, options.source, options.source_rectangle, options.source_layer);
    try common.checkRect(options.target, options.rectangle);
    if (options.rectangle.width == 0 or options.rectangle.height == 0) return;
    if (options.source_rectangle.width == 0 or options.source_rectangle.height == 0)
        return error.InvalidBlitRegion;
    if (options.color_transform) |transform| {
        for (transform.source_transfer) |coefficient|
            if (!std.math.isFinite(coefficient)) return error.InvalidBlitTransform;
        for (transform.destination_transfer) |coefficient|
            if (!std.math.isFinite(coefficient)) return error.InvalidBlitTransform;
        for (transform.matrix) |coefficient|
            if (!std.math.isFinite(coefficient)) return error.InvalidBlitTransform;
    }
    const sample_types = options.source.format_info.aspect_info[0].supported_sample_types;
    const staged = aliasesTarget(options.source, options.target) or
        (options.filter == .linear and
            (!sample_types.float or !isFilterableFormat(options.source.format)));
    if (staged) return colorToColorStaged(context, options, scalar);
    const parameters = copyParameters(context, options);
    const key: kernels.KernelKey = .{
        .id = .color_to_color,
        .source_format = options.source.format,
        .source_dimension = options.source.dimension,
        .source_multisampled = options.source.texture.sample_count != 1,
        .attachments = options.target.attachments,
        .color_write_slots = @as(u8, 1) << options.color_slot,
    };
    var bindings: [2]kernels.Binding = undefined;
    var binding_count: usize = 1;
    errdefer context.queue.poisonRecording();
    bindings[0] = .{ .view = options.source };
    if (scalar == .float and options.source.texture.sample_count == 1 and
        isFilterableFormat(options.source.format))
    {
        bindings[1] = .{ .sampler = try kernels.sampler(context, .{
            .min_filter = options.filter,
            .mag_filter = options.filter,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .lod_min_clamp = 0,
            .lod_max_clamp = 0,
            .compare = .undefined_,
        }) };
        binding_count = 2;
    }
    const pass = try common.createPass(context, options.target);
    const prepared = try kernels.prepareDraw(context, .{
        .key = key,
        .bindings = bindings[0..binding_count],
        .parameters = parameters[0..if (scalar == .float) 224 else 96],
        .compatible_render_pass = pass.handle,
    });
    try common.beginPass(context, options.target, pass);
    try kernels.recordDraw(context, drawOptions(
        prepared,
        pass.handle,
        options.target,
        options.rectangle,
        0,
    ));
    try common.endPass(context, options.target);
}

const StagedTile = struct {
    rectangle: common.Rect,
    source_rectangle: common.Rect,
    input: kernels.BufferRange,
    prepared: kernels.PreparedDraw,
};

fn colorToColorStaged(
    context: kernels.Context,
    options: ColorCopyOptions,
    scalar: format.TextureComponentType,
) Error!void {
    const allocator = context.queue.context.allocator;
    var tiles: std.ArrayList(StagedTile) = .empty;
    defer tiles.deinit(allocator);
    const packed_format: api.TextureFormat = switch (scalar) {
        .float => .rgba32_float,
        .uint => .rgba32_uint,
        .sint => .rgba32_sint,
    };
    const limits = context.cache.native_device.physical.properties.limits;
    const maximum_workgroups = @min(limits.maxComputeWorkGroupCount[0], context.cache.limits.v1.max_compute_workgroups_per_dimension);
    const dispatch_bytes = @as(u64, maximum_workgroups) * 64 * 4;
    const maximum = @min(@as(u64, storageWindow(context)), dispatch_bytes) & ~@as(u64, 3);
    const source_extent = sourceSize(context, options.source);
    var x: u32 = 0;
    errdefer context.queue.poisonRecording();
    while (x < options.rectangle.width) {
        const width = try stagedColumnWidth(
            options,
            options.rectangle.width - x,
            source_extent,
            maximum,
        );
        var y: u32 = 0;
        while (y < options.rectangle.height) {
            var height = options.rectangle.height - y;
            var destination_rectangle: common.Rect = undefined;
            var source_rectangle: common.Rect = undefined;
            // A u32 height reaches one after at most 32 halvings.
            for (0..33) |_| {
                destination_rectangle = .{
                    .x = options.rectangle.x + x,
                    .y = options.rectangle.y + y,
                    .width = width,
                    .height = height,
                };
                source_rectangle = stagedFootprint(
                    options,
                    destination_rectangle,
                    source_extent,
                );
                const bytes = try common.mul(16, try common.mul(source_rectangle.width, source_rectangle.height));
                if (bytes <= maximum) break;
                if (height > 1) {
                    height = @divFloor(height, 2) + height % 2;
                } else {
                    return error.BindingRangeExceedsLimit;
                }
            } else return error.BlitCommandLimitExceeded;
            if (tiles.items.len == 1 << 24) return error.BlitCommandLimitExceeded;
            // Reserve the host record before recording its GPU pack.
            const tile = try tiles.addOne(allocator);
            tile.rectangle = destination_rectangle;
            tile.source_rectangle = source_rectangle;
            tile.input = try blit.packTexture(context, .{
                .source = options.source,
                .origin = .{ source_rectangle.x, source_rectangle.y, options.source_layer },
                .extent = .{ source_rectangle.width, source_rectangle.height, 1 },
                .mip_level = 0,
                .sample_index = options.sample_index,
                .format = packed_format,
            });
            std.debug.assert(tile.input.offset == 0);
            y += height;
        }
        x += width;
    }
    // All source reads finish before any target draw. This also covers tiles not yet drawn.
    const pass = try common.createPass(context, options.target);
    for (tiles.items) |*tile| {
        var parameters = copyParameters(context, options);
        common.putWord(&parameters, 0, tile.source_rectangle.x);
        common.putWord(&parameters, 1, tile.source_rectangle.y);
        common.putWord(&parameters, 2, options.rectangle.x);
        common.putWord(&parameters, 3, options.rectangle.y);
        common.putWord(&parameters, 4, tile.source_rectangle.width);
        common.putWord(&parameters, 5, tile.source_rectangle.height);
        common.putWord(&parameters, 6, options.rectangle.width);
        common.putWord(&parameters, 7, options.rectangle.height);
        common.putWord(&parameters, 8, tile.rectangle.x);
        common.putWord(&parameters, 9, tile.rectangle.y);
        common.putWord(&parameters, 10, tile.rectangle.width);
        common.putWord(&parameters, 11, tile.rectangle.height);
        common.putWord(&parameters, 13, 0);
        common.putWord(&parameters, 16, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.width))));
        common.putWord(&parameters, 17, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.height))));
        common.putWord(&parameters, 18, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.x))));
        common.putWord(&parameters, 19, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.y))));
        const bindings = [_]kernels.Binding{.{ .buffer = tile.input }};
        tile.prepared = try kernels.prepareDraw(context, .{
            .key = .{
                .id = .color_to_color,
                .source_format = options.source.format,
                .storage_format = packed_format,
                .source_dimension = .undefined_,
                .attachments = options.target.attachments,
                .color_write_slots = @as(u8, 1) << options.color_slot,
            },
            .bindings = &bindings,
            .parameters = parameters[0..if (scalar == .float) 224 else 96],
            .compatible_render_pass = pass.handle,
        });
    }
    try common.beginPass(context, options.target, pass);
    for (tiles.items) |*tile| {
        try kernels.recordDraw(context, drawOptions(
            tile.prepared,
            pass.handle,
            options.target,
            tile.rectangle,
            0,
        ));
    }
    try common.endPass(context, options.target);
}

fn stagedFootprint(
    options: ColorCopyOptions,
    tile: common.Rect,
    source_extent: api.Extent3D,
) common.Rect {
    const origin = [2]u32{ options.rectangle.x, options.rectangle.y };
    const sizes = [2]u32{ options.rectangle.width, options.rectangle.height };
    const source_origin = [2]u32{ options.source_rectangle.x, options.source_rectangle.y };
    const source_sizes = [2]u32{ options.source_rectangle.width, options.source_rectangle.height };
    const tile_origin = [2]u32{ tile.x, tile.y };
    const tile_sizes = [2]u32{ tile.width, tile.height };
    const bounds = [2]u32{ source_extent.width, source_extent.height };
    var lower: [2]u32 = undefined;
    var upper: [2]u32 = undefined;
    for (0..2) |axis| {
        const first = @as(f64, @floatFromInt(tile_origin[axis] - origin[axis])) + 0.5;
        const last = first + @as(f64, @floatFromInt(tile_sizes[axis] - 1));
        const destination_size: f64 = @floatFromInt(sizes[axis]);
        const source_size: f64 = @floatFromInt(source_sizes[axis]);
        const source_start: f64 = @floatFromInt(source_origin[axis]);
        const first_ratio = if (axis == 1 and options.flip_y)
            1 - last / destination_size
        else
            first / destination_size;
        const last_ratio = if (axis == 1 and options.flip_y)
            1 - first / destination_size
        else
            last / destination_size;
        // One extra texel covers f32 rounding at both ends of the sample footprint.
        const texel_offset: f64 = if (options.filter == .linear) 0.5 else 0;
        const first_texel = source_start + first_ratio * source_size - texel_offset;
        const last_texel = source_start + last_ratio * source_size - texel_offset;
        const minimum = @floor(first_texel) - 1;
        const maximum = @floor(last_texel) + if (options.filter == .linear)
            @as(f64, 3)
        else
            @as(f64, 2);
        const limit: f64 = @floatFromInt(bounds[axis]);
        lower[axis] = @intFromFloat(@max(0, @min(minimum, limit - 1)));
        upper[axis] = @intFromFloat(@max(1, @min(maximum, limit)));
    }
    return .{
        .x = lower[0],
        .y = lower[1],
        .width = upper[0] - lower[0],
        .height = upper[1] - lower[1],
    };
}

fn stagedColumnWidth(
    options: ColorCopyOptions,
    remaining_width: u32,
    source_extent: api.Extent3D,
    maximum: u64,
) Error!u32 {
    const halo: u64 = if (options.filter == .linear) 4 else 3;
    const row_count = @min(halo, source_extent.height);
    var width = remaining_width;
    // A fixed column width prevents later rows from shrinking across earlier rows.
    for (0..33) |_| {
        const span = try common.mul(width - 1, options.source_rectangle.width);
        const span_ceil = @divFloor(
            span + options.rectangle.width - 1,
            options.rectangle.width,
        );
        const column_count = @min(span_ceil + halo, source_extent.width);
        if (try common.mul(16, try common.mul(column_count, row_count)) <= maximum)
            return width;
        if (width == 1) return error.BindingRangeExceedsLimit;
        width = @divFloor(width, 2) + width % 2;
    }
    return error.BlitCommandLimitExceeded;
}

fn isFilterableFormat(value: api.TextureFormat) bool {
    return value != .r32_float and value != .rg32_float and value != .rgba32_float;
}

fn validateSource(
    context: kernels.Context,
    source: *texture.TextureView,
    rectangle: common.Rect,
    layer: u32,
) Error!void {
    try common.retainView(context, source);
    if (source.range.level_count != 1 or
        (source.dimension != ._1d and source.dimension != ._2d and
            source.dimension != ._2d_array and source.dimension != ._3d) or
        !source.internal_usage.texture_binding)
        return error.TextureNativeUsageUnsupported;
    const extent = sourceSize(context, source);
    const layer_count = if (source.dimension == ._3d)
        extent.depth_or_array_layers
    else
        source.range.layer_count;
    if (layer >= layer_count) return error.InvalidBlitRegion;
    if (rectangle.x > extent.width or rectangle.y > extent.height or
        rectangle.width > extent.width - rectangle.x or
        rectangle.height > extent.height - rectangle.y)
        return error.InvalidBlitRegion;
    try validateSignedSource(rectangle, layer);
}

fn validateSignedSource(rectangle: common.Rect, layer: u32) Error!void {
    if (rectangle.width != 0)
        try common.validateSignedTexelRange(rectangle.x, rectangle.width);
    if (rectangle.height != 0)
        try common.validateSignedTexelRange(rectangle.y, rectangle.height);
    try common.validateSignedTexelRange(layer, 1);
}

fn sourceSize(context: kernels.Context, source: *texture.TextureView) api.Extent3D {
    return source.texture.getMipLevelSingleSubresourceVirtualSize(
        context.guard,
        source.range.base_mip_level,
    );
}

fn aliasesTarget(source: *texture.TextureView, target: common.Target) bool {
    for (target.colors) |maybe_view| {
        if (maybe_view) |view| {
            if (viewOverlaps(source, view)) return true;
        }
    }
    if (target.depth_stencil) |view| {
        if (viewOverlaps(source, view)) return true;
    }
    return false;
}

fn viewOverlaps(source: *const texture.TextureView, target: *const texture.TextureView) bool {
    if (source.texture != target.texture) return false;
    if (source.aspects.toFlags() & target.aspects.toFlags() == 0) return false;
    const source_mip_end = @as(u64, source.range.base_mip_level) + source.range.level_count;
    const target_mip_end = @as(u64, target.range.base_mip_level) + target.range.level_count;
    if (source.range.base_mip_level >= target_mip_end or
        target.range.base_mip_level >= source_mip_end)
        return false;
    const source_layer_end = @as(u64, source.range.base_array_layer) + source.range.layer_count;
    const target_layer_end = @as(u64, target.range.base_array_layer) + target.range.layer_count;
    return source.range.base_array_layer < target_layer_end and
        target.range.base_array_layer < source_layer_end;
}

fn formatInfo(context: kernels.Context, value: api.TextureFormat) Error!*const format.Format {
    const index = format.computeFormatIndex(value) orelse return error.BlitFormatMismatch;
    return &context.cache.formats[index];
}

fn storageWindow(context: kernels.Context) u32 {
    return @intCast(@min(@as(u64, context.cache.resource_device.buffer_limits.max_storage_buffer_range), @min(context.cache.limits.v1.max_storage_buffer_binding_size, context.cache.limits.v1.max_buffer_size)));
}

fn requiredBytes(width: u32, height: u32, stride: u32, texel_bytes: u32) Error!u64 {
    if (width == 0 or height == 0) return 0;
    const row = try common.mul(width, texel_bytes);
    if (stride < row) return error.InvalidBlitLayout;
    return common.add(try common.mul(height - 1, stride), row);
}

fn unpackParameters(options: BufferCopyOptions, byte_offset: u64) Error![64]u8 {
    if (byte_offset > std.math.maxInt(u32)) return error.KernelRangeOverflow;
    var bytes: [64]u8 = @splat(0);
    common.putWord(&bytes, 0, @intCast(byte_offset));
    common.putWord(&bytes, 1, options.layout.bytes_per_row);
    common.putWord(&bytes, 2, options.layout.rows_per_image);
    common.putWord(&bytes, 3, options.rectangle.width);
    common.putWord(&bytes, 4, options.rectangle.height);
    common.putWord(&bytes, 5, 1);
    common.putWord(&bytes, 6, options.rectangle.x);
    common.putWord(&bytes, 7, options.rectangle.y);
    common.putWord(&bytes, 11, try shaders.formatCode(options.format));
    return bytes;
}

fn copyParameters(context: kernels.Context, options: ColorCopyOptions) [224]u8 {
    var bytes: [224]u8 = @splat(0);
    const extent = sourceSize(context, options.source);
    common.putWord(&bytes, 0, options.source_rectangle.x);
    common.putWord(&bytes, 1, options.source_rectangle.y);
    common.putWord(&bytes, 2, options.source_layer);
    common.putWord(&bytes, 4, options.source_rectangle.width);
    common.putWord(&bytes, 5, options.source_rectangle.height);
    common.putWord(&bytes, 6, options.sample_index);
    common.putWord(&bytes, 8, options.rectangle.x);
    common.putWord(&bytes, 9, options.rectangle.y);
    common.putWord(&bytes, 10, options.rectangle.width);
    common.putWord(&bytes, 11, options.rectangle.height);
    common.putWord(&bytes, 12, copyFlags(options));
    common.putWord(&bytes, 13, options.source_layer);
    common.putWord(&bytes, 16, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.width)) /
        @as(f32, @floatFromInt(extent.width))));
    common.putWord(&bytes, 17, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.height)) /
        @as(f32, @floatFromInt(extent.height))));
    common.putWord(&bytes, 18, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.x)) /
        @as(f32, @floatFromInt(extent.width))));
    common.putWord(&bytes, 19, @bitCast(@as(f32, @floatFromInt(options.source_rectangle.y)) /
        @as(f32, @floatFromInt(extent.height))));
    if (options.color_transform) |transform| encodeColorTransform(&bytes, transform);
    return bytes;
}

fn copyFlags(options: ColorCopyOptions) u32 {
    return @as(u32, @intFromBool(options.flip_y)) |
        (@as(u32, @intFromBool(options.swizzle_red_blue)) << 1) |
        (@as(u32, @intFromBool(options.premultiply_alpha)) << 2) |
        (@as(u32, @intFromBool(options.unpremultiply_alpha)) << 3) |
        (@as(u32, @intFromBool(options.decode_srgb)) << 4) |
        (@as(u32, @intFromBool(options.encode_srgb)) << 5) |
        (@as(u32, @intFromBool(options.filter == .linear)) << 6) |
        (@as(u32, @intFromBool(options.color_transform != null)) << 7) |
        (@as(u32, @intFromBool(options.source_opaque)) << 8) |
        (@as(u32, @intFromBool(options.decode_destination_srgb)) << 9);
}

fn encodeColorTransform(bytes: *[224]u8, transform: ColorTransform) void {
    for (transform.source_transfer, 0..) |coefficient, index|
        common.putWord(bytes, 24 + index, @bitCast(coefficient));
    for (transform.destination_transfer, 0..) |coefficient, index|
        common.putWord(bytes, 32 + index, @bitCast(coefficient));
    for (transform.matrix, 0..) |coefficient, index|
        common.putWord(bytes, 40 + @divFloor(index, 3) * 4 + index % 3, @bitCast(coefficient));
}

fn encodeClear(bytes: *[128]u8, slot: u3, value: ClearValue) void {
    switch (value) {
        .float => |components| for (components, 0..) |component, index| {
            common.putWord(bytes, @as(usize, slot) * 4 + index, @bitCast(component));
        },
        .uint => |components| for (components, 0..) |component, index| {
            common.putWord(bytes, @as(usize, slot) * 4 + index, component);
        },
        .sint => |components| for (components, 0..) |component, index| {
            common.putWord(bytes, @as(usize, slot) * 4 + index, @bitCast(component));
        },
    }
}

fn drawOptions(
    prepared: kernels.PreparedDraw,
    render_pass: vulkan.VkRenderPass,
    target: common.Target,
    rectangle: common.Rect,
    stencil_reference: u32,
) kernels.Draw {
    return .{
        .prepared = prepared,
        .render_pass = render_pass,
        .attachments = target.attachments,
        .viewport = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(target.width),
            .height = @floatFromInt(target.height),
            .minDepth = 0,
            .maxDepth = 1,
        },
        .scissor = scissor(rectangle),
        .stencil_reference = stencil_reference,
    };
}

fn scissor(rectangle: common.Rect) vulkan.VkRect2D {
    return .{
        .offset = .{ .x = @intCast(rectangle.x), .y = @intCast(rectangle.y) },
        .extent = .{ .width = rectangle.width, .height = rectangle.height },
    };
}

fn readWord(bytes: []const u8, word: usize) u32 {
    return std.mem.readInt(u32, bytes[word * 4 ..][0..4], .little);
}

// The fixed shader variant selects the bit. All eight draws share these bytes.
test "stencil unpack parameters reserve the bit selection word" {
    const options: BufferCopyOptions = .{
        .source = undefined,
        .target = undefined,
        .rectangle = .{ .x = 7, .y = 9, .width = 4, .height = 2 },
        .layout = .{ .bytes_per_row = 12, .rows_per_image = 2 },
        .format = .stencil8,
    };
    const parameters = try unpackParameters(options, 3);
    try std.testing.expectEqual(@as(u32, 3), readWord(&parameters, 0));
    try std.testing.expectEqual(@as(u32, 7), readWord(&parameters, 6));
    try std.testing.expectEqual(@as(u32, 9), readWord(&parameters, 7));
    for (12..16) |word|
        try std.testing.expectEqual(@as(u32, 0), readWord(&parameters, word));
}

// Integer clears must retain raw integer bits and leave every other slot zero.
test "clear ABI preserves signed integer values in one selected slot" {
    var parameters: [128]u8 = @splat(0);
    encodeClear(&parameters, 5, .{ .sint = .{ -1, -2147483648, 17, 0 } });
    try std.testing.expectEqual(@as(u32, 0xffffffff), readWord(&parameters, 20));
    try std.testing.expectEqual(@as(u32, 0x80000000), readWord(&parameters, 21));
    try std.testing.expectEqual(@as(u32, 17), readWord(&parameters, 22));
    for (0..20) |word| try std.testing.expectEqual(@as(u32, 0), readWord(&parameters, word));
    for (24..32) |word| try std.testing.expectEqual(@as(u32, 0), readWord(&parameters, word));
}

// A tile reads only its requested texels while retaining the source row stride.
test "buffer rectangle required bytes exclude final row padding" {
    try std.testing.expectEqual(@as(u64, 272), try requiredBytes(4, 2, 256, 4));
    try std.testing.expectError(error.InvalidBlitLayout, requiredBytes(4, 2, 15, 4));
}

// The coefficient arrays keep their pinned order and the matrix keeps 16-byte columns.
test "browser transform ABI retains all coefficients and padding" {
    var parameters: [224]u8 = @splat(0);
    const transform: ColorTransform = .{
        .source_transfer = .{ 1, 2, 3, 4, 5, 6, 7 },
        .destination_transfer = .{ 8, 9, 10, 11, 12, 13, 14 },
        .matrix = .{ 15, 16, 17, 18, 19, 20, 21, 22, 23 },
    };
    encodeColorTransform(&parameters, transform);
    for (transform.source_transfer, 0..) |value, index|
        try std.testing.expectEqual(@as(u32, @bitCast(value)), readWord(&parameters, 24 + index));
    for (transform.destination_transfer, 0..) |value, index|
        try std.testing.expectEqual(@as(u32, @bitCast(value)), readWord(&parameters, 32 + index));
    for (transform.matrix, 0..) |value, index|
        try std.testing.expectEqual(@as(u32, @bitCast(value)), readWord(&parameters, 40 + @divFloor(index, 3) * 4 + index % 3));
    for (.{ 31, 39, 43, 47, 51, 52, 53, 54, 55 }) |word|
        try std.testing.expectEqual(@as(u32, 0), readWord(&parameters, word));
}

// A downscaled overlapping copy packs only the texels its output tile can sample.
test "staged copy footprint covers bilinear halo and flipY globally" {
    var options: ColorCopyOptions = .{
        .source = undefined,
        .target = undefined,
        .source_rectangle = .{ .x = 100, .y = 200, .width = 1000, .height = 1000 },
        .rectangle = .{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .filter = .linear,
    };
    const tile: common.Rect = .{ .x = 10, .y = 20, .width = 1, .height = 1 };
    const source_extent: api.Extent3D = .{
        .width = 4096,
        .height = 4096,
        .depth_or_array_layers = 1,
    };
    const first = stagedFootprint(options, tile, source_extent);
    try std.testing.expectEqual(@as(u32, 103), first.x);
    try std.testing.expectEqual(@as(u32, 203), first.y);
    try std.testing.expectEqual(@as(u32, 4), first.width);
    try std.testing.expectEqual(@as(u32, 4), first.height);
    options.flip_y = true;
    const flipped = stagedFootprint(options, tile, source_extent);
    try std.testing.expectEqual(first.x, flipped.x);
    try std.testing.expectEqual(@as(u32, 1193), flipped.y);
    try std.testing.expectEqual(first.width, flipped.width);
    try std.testing.expectEqual(first.height, flipped.height);
}

// Browser destination decoding has a separate shader position from source decoding.
test "destination sRGB decode uses its own operation flag" {
    var options: ColorCopyOptions = .{
        .source = undefined,
        .target = undefined,
        .source_rectangle = undefined,
        .rectangle = undefined,
        .decode_destination_srgb = true,
    };
    try std.testing.expectEqual(@as(u32, 512), copyFlags(options));
    options.decode_srgb = true;
    try std.testing.expectEqual(@as(u32, 528), copyFlags(options));
}

// One effective workgroup still admits a bilinear sample and its rounding halo.
test "staged single pixel fits a 256 byte pack window" {
    const options: ColorCopyOptions = .{
        .source = undefined,
        .target = undefined,
        .source_rectangle = .{ .x = 100, .y = 200, .width = 1000, .height = 1000 },
        .rectangle = .{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .filter = .linear,
    };
    const source_extent: api.Extent3D = .{
        .width = 4096,
        .height = 4096,
        .depth_or_array_layers = 1,
    };
    try std.testing.expectEqual(@as(u32, 1), try stagedColumnWidth(options, 100, source_extent, 256));
    const footprint = stagedFootprint(options, .{ .x = 10, .y = 20, .width = 1, .height = 1 }, source_extent);
    try std.testing.expectEqual(@as(u64, 256), try common.mul(16, try common.mul(footprint.width, footprint.height)));
}

// One shared clear uniform holds different scalar types without converting their bits.
test "shared clear uniform retains all selected typed slots" {
    var parameters: [128]u8 = @splat(0);
    encodeClear(&parameters, 0, .{ .uint = .{ 0xffffffff, 17, 3, 1 } });
    encodeClear(&parameters, 5, .{ .sint = .{ -7, -1, 0, 1 } });
    encodeClear(&parameters, 7, .{ .float = .{ 0.25, 0.5, 0.75, 1 } });
    try std.testing.expectEqual(@as(u32, 0xffffffff), readWord(&parameters, 0));
    try std.testing.expectEqual(@as(u32, 17), readWord(&parameters, 1));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -7))), readWord(&parameters, 20));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.25))), readWord(&parameters, 28));
    for (4..20) |word|
        try std.testing.expectEqual(@as(u32, 0), readWord(&parameters, word));
    for (24..28) |word|
        try std.testing.expectEqual(@as(u32, 0), readWord(&parameters, word));
}
