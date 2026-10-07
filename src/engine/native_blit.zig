//! GPU texture packing and typed render blits. Exact native transfers remain in copy replay.
const std = @import("std");
const api = @import("../api/api.zig");
const kernels = @import("native_kernels.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const shader = @import("native_blit_shader_definitions.zig");
const common = @import("native_blit_common.zig");
const render = @import("native_blit_render.zig");

pub const Error = common.Error || render.Error;
pub const Target = common.Target;
pub const Rect = common.Rect;
pub const validateSignedTexelRange = common.validateSignedTexelRange;
pub const BufferLayout = render.BufferLayout;
pub const BufferCopyOptions = render.BufferCopyOptions;
pub const ColorCopyOptions = render.ColorCopyOptions;
pub const ColorTransform = render.ColorTransform;
pub const DepthCopyOptions = render.DepthCopyOptions;
pub const ClearValue = render.ClearValue;
pub const DrawClearOptions = render.DrawClearOptions;
pub const PreparedClear = render.PreparedClear;
pub const bufferToColor = render.bufferToColor;
pub const bufferToDepth = render.bufferToDepth;
pub const bufferToStencil = render.bufferToStencil;
pub const colorToColor = render.colorToColor;
pub const depthToDepth = render.depthToDepth;
pub const drawClear = render.drawClear;
pub const prepareDrawClear = render.prepareDrawClear;
pub const recordPreparedClear = render.recordPreparedClear;

pub const PackTexture = struct {
    source: *texture.TextureView,
    origin: [3]u32 = .{ 0, 0, 0 },
    extent: [3]u32,
    mip_level: u32 = 0,
    sample_index: u32 = 0,
    format: api.TextureFormat = .undefined_,
};

pub const TextureToBuffer = struct {
    source: *texture.TextureView,
    destination: kernels.BufferRange,
    origin: [3]u32 = .{ 0, 0, 0 },
    extent: [3]u32,
    mip_level: u32 = 0,
    sample_index: u32 = 0,
    bytes_per_row: u64,
    rows_per_image: u64,
};

fn selectedFormat(source: *const texture.TextureView) api.TextureFormat {
    if (source.aspects.stencil != 0 and source.aspects.depth == 0) return .stencil8;
    if (source.aspects.depth != 0) return switch (source.format) {
        .depth16_unorm => .depth16_unorm,
        else => .depth32_float,
    };
    return source.format;
}

pub fn validatePack(context: kernels.Context, options: PackTexture) Error!void {
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    for (0..3) |axis|
        try common.validateSignedTexelRange(options.origin[axis], options.extent[axis]);
    try common.retainView(context, options.source);
    if (!options.source.internal_usage.texture_binding or
        @popCount(options.source.aspects.toFlags()) != 1 or options.source.format_info.is_compressed)
        return error.TextureNativeUsageUnsupported;
    if (options.mip_level >= options.source.range.level_count) return error.InvalidBlitRegion;
    const mip = options.source.range.base_mip_level + options.mip_level;
    const extent = options.source.texture.getMipLevelSingleSubresourceVirtualSize(context.guard, mip);
    const depth = switch (options.source.dimension) {
        ._1d, ._2d => @as(u32, 1),
        ._2d_array, .cube, .cube_array => options.source.range.layer_count,
        ._3d => extent.depth_or_array_layers,
        .undefined_ => return error.InvalidBlitRegion,
    };
    const limits = [3]u32{ extent.width, extent.height, depth };
    for (0..3) |axis| {
        if (options.origin[axis] > limits[axis] or
            options.extent[axis] > limits[axis] - options.origin[axis])
            return error.InvalidBlitRegion;
    }
    if (options.sample_index >= options.source.texture.sample_count)
        return error.BlitSampleCountMismatch;
    if (options.source.texture.sample_count != 1 and options.mip_level != 0)
        return error.BlitSampleCountMismatch;
    _ = try shader.formatCode(if (options.format == .undefined_) selectedFormat(options.source) else options.format);
    _ = try options.source.getHandle(context.guard);
}

fn maxWindowBytes(context: kernels.Context) u64 {
    const physical = context.cache.native_device.physical.properties.limits;
    const effective = context.cache.limits.v1;
    const groups = @min(physical.maxComputeWorkGroupCount[0], effective.max_compute_workgroups_per_dimension);
    const dispatch_bytes = @as(u64, groups) * 64 * 4;
    const storage_bytes = @min(@as(u64, physical.maxStorageBufferRange), effective.max_storage_buffer_binding_size);
    return @min(storage_bytes, @min(effective.max_buffer_size, @min(dispatch_bytes, std.math.maxInt(u32)))) & ~@as(u64, 3);
}

pub fn packTexture(context: kernels.Context, request: PackTexture) Error!kernels.BufferRange {
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try validatePack(context, request);
    var options = request;
    options.source = try common.loadView(context, request.source);
    const format = if (options.format == .undefined_) selectedFormat(options.source) else options.format;
    const texel_bytes = try shader.texelByteSize(format);
    const row_bytes = try common.mul(options.extent[0], texel_bytes);
    const stride = try common.align4(row_bytes);
    const byte_count = try common.mul(try common.mul(stride, options.extent[1]), options.extent[2]);
    if (byte_count > maxWindowBytes(context)) return error.KernelRangeOverflow;
    const result = try kernels.scratchBuffer(context, .{
        .size = byte_count,
        .native_usage = buffer.internal_storage_buffer | buffer.read_only_storage_buffer |
            (api.BufferUsage{ .copy_src = true, .copy_dst = true }).toFlags(),
    });
    var parameters: [64]u8 = @splat(0);
    common.putWord(&parameters, 1, @intCast(stride));
    common.putWord(&parameters, 2, options.extent[1]);
    common.putWord(&parameters, 3, options.extent[0]);
    common.putWord(&parameters, 4, options.extent[1]);
    common.putWord(&parameters, 5, options.extent[2]);
    common.putWord(&parameters, 6, options.origin[0]);
    common.putWord(&parameters, 7, options.origin[1]);
    common.putWord(&parameters, 8, options.origin[2]);
    common.putWord(&parameters, 9, options.mip_level);
    common.putWord(&parameters, 10, options.sample_index);
    common.putWord(&parameters, 11, try shader.formatCode(format));
    const bindings = [_]kernels.Binding{ .{ .view = options.source }, .{ .buffer = result } };
    const words = @divExact(byte_count, 4);
    const workgroups = @divFloor(words + 63, 64);
    errdefer context.queue.poisonRecording();
    try kernels.recordCompute(context, .{
        .key = .{
            .id = .texture_to_buffer,
            .source_format = options.source.format,
            .source_dimension = options.source.dimension,
            .source_multisampled = options.source.texture.sample_count != 1,
            .storage_format = format,
        },
        .bindings = &bindings,
        .parameters = &parameters,
        .workgroups = .{ @intCast(workgroups), 1, 1 },
    });
    return result;
}

/// Aligns GPU-resident bytes for a native image transfer without a host read.
pub fn alignBufferInput(context: kernels.Context, input: kernels.BufferRange) Error!kernels.BufferRange {
    const byte_count = try common.align4(input.size);
    if (byte_count == 0 or byte_count > maxWindowBytes(context) -| 4)
        return error.KernelRangeOverflow;
    errdefer context.queue.poisonRecording();
    const source = try common.stageInput(context, input);
    const scratch_usage = buffer.internal_storage_buffer | buffer.read_only_storage_buffer |
        (api.BufferUsage{ .copy_src = true, .copy_dst = true }).toFlags();
    const zero = try kernels.scratchBuffer(context, .{ .size = byte_count, .native_usage = scratch_usage });
    const result = try kernels.scratchBuffer(context, .{ .size = byte_count, .native_usage = scratch_usage });
    var parameters: [32]u8 = @splat(0);
    common.putWord(&parameters, 0, @intCast(source.owner.native.size));
    common.putWord(&parameters, 1, @intCast(byte_count));
    common.putWord(&parameters, 2, @intCast(input.size));
    common.putWord(&parameters, 3, 1);
    common.putWord(&parameters, 4, @intCast(source.offset));
    common.putWord(&parameters, 6, @intCast(@divExact(byte_count, 4)));
    const bindings = [_]kernels.Binding{
        .{ .buffer = .{ .owner = source.owner, .offset = 0, .size = source.owner.native.size } },
        .{ .buffer = zero },
        .{ .buffer = result },
    };
    try kernels.recordCompute(context, .{
        .key = .{ .id = .buffer_row_merge },
        .bindings = &bindings,
        .parameters = &parameters,
        .workgroups = .{ @intCast(@divFloor(@divExact(byte_count, 4) + 63, 64)), 1, 1 },
    });
    return result;
}

fn copyPackedRows(
    context: kernels.Context,
    packed_buffer_range: kernels.BufferRange,
    destination: kernels.BufferRange,
    row_bytes: u64,
    source_stride: u64,
    destination_stride: u64,
    row_count: u32,
) Error!void {
    if (packed_buffer_range.offset % 4 == 0 and destination.offset % 4 == 0 and
        row_bytes % 4 == 0 and destination_stride % 4 == 0)
    {
        for (0..row_count) |row| {
            try common.copyBuffer(context, .{
                .owner = packed_buffer_range.owner,
                .offset = try common.add(packed_buffer_range.offset, try common.mul(row, source_stride)),
                .size = row_bytes,
            }, .{
                .owner = destination.owner,
                .offset = try common.add(destination.offset, try common.mul(row, destination_stride)),
                .size = row_bytes,
            });
        }
        return;
    }
    const preimage = try common.stageInput(context, destination);
    const byte_count = preimage.owner.native.size;
    if (byte_count > maxWindowBytes(context)) return error.KernelRangeOverflow;
    const merged = try kernels.scratchBuffer(context, .{
        .size = byte_count,
        .native_usage = buffer.internal_storage_buffer |
            (api.BufferUsage{ .copy_src = true, .copy_dst = true }).toFlags(),
    });
    var parameters: [32]u8 = @splat(0);
    common.putWord(&parameters, 0, @intCast(source_stride));
    common.putWord(&parameters, 1, @intCast(if (row_count == 1) byte_count else destination_stride));
    common.putWord(&parameters, 2, @intCast(row_bytes));
    common.putWord(&parameters, 3, row_count);
    common.putWord(&parameters, 4, @intCast(packed_buffer_range.offset));
    common.putWord(&parameters, 5, @intCast(preimage.offset));
    common.putWord(&parameters, 6, @intCast(@divExact(byte_count, 4)));
    const bindings = [_]kernels.Binding{
        .{ .buffer = .{ .owner = packed_buffer_range.owner, .offset = 0, .size = packed_buffer_range.owner.native.size } },
        .{ .buffer = .{ .owner = preimage.owner, .offset = 0, .size = byte_count } },
        .{ .buffer = merged },
    };
    errdefer context.queue.poisonRecording();
    try kernels.recordCompute(context, .{
        .key = .{ .id = .buffer_row_merge },
        .bindings = &bindings,
        .parameters = &parameters,
        .workgroups = .{ @intCast(@divFloor(@divExact(byte_count, 4) + 63, 64)), 1, 1 },
    });
    try common.copyBuffer(context, merged, .{
        .owner = destination.owner,
        .offset = destination.offset & ~@as(u64, 3),
        .size = byte_count,
    });
}

pub fn textureToBuffer(context: kernels.Context, request: TextureToBuffer) Error!void {
    if (request.extent[0] == 0 or request.extent[1] == 0 or request.extent[2] == 0) return;
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try validatePack(context, .{
        .source = request.source,
        .origin = request.origin,
        .extent = request.extent,
        .mip_level = request.mip_level,
        .sample_index = request.sample_index,
    });
    var options = request;
    options.source = try common.loadView(context, request.source);
    try common.checkRange(options.destination);
    if (!options.destination.owner.native.usage.copy_dst) return error.BufferUsageMissingCopyDst;
    const texel_bytes = try shader.texelByteSize(selectedFormat(options.source));
    const row_bytes = try common.mul(options.extent[0], texel_bytes);
    if (options.bytes_per_row < row_bytes or options.rows_per_image < options.extent[1])
        return error.InvalidBlitRegion;
    const image_stride = try common.mul(options.bytes_per_row, options.rows_per_image);
    const required = try common.add(
        try common.add(try common.mul(options.extent[2] - 1, image_stride), try common.mul(options.extent[1] - 1, options.bytes_per_row)),
        row_bytes,
    );
    if (required > options.destination.size) return error.KernelRangeOverflow;
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &options.destination.owner.header);
    const max_bytes = maxWindowBytes(context);
    if (max_bytes < texel_bytes + 8) return error.KernelRangeOverflow;
    const max_columns: u32 = @intCast(@min(@divFloor(max_bytes - 8, texel_bytes), options.extent[0]));
    const columns = std.math.divCeil(u64, options.extent[0], max_columns) catch return error.KernelRangeOverflow;
    const operation_count = try common.mul(try common.mul(columns, options.extent[1]), options.extent[2]);
    if (operation_count > (1 << 24)) return error.BlitCommandLimitExceeded;
    errdefer context.queue.poisonRecording();
    for (0..options.extent[2]) |layer| {
        var column: u32 = 0;
        while (column < options.extent[0]) {
            const width = @min(max_columns, options.extent[0] - column);
            const count = try common.mul(width, texel_bytes);
            const source_stride = try common.align4(count);
            const rows_by_source = @divFloor(max_bytes, source_stride);
            const rows_by_destination = 1 + @divFloor(max_bytes - count - 8, options.bytes_per_row);
            const max_rows: u32 = @intCast(@min(options.extent[1], @min(rows_by_source, rows_by_destination)));
            var row: u32 = 0;
            while (row < options.extent[1]) {
                const height = @min(max_rows, options.extent[1] - row);
                const packed_buffer_range = try packTexture(context, .{
                    .source = options.source,
                    .origin = .{ options.origin[0] + column, options.origin[1] + row, options.origin[2] + @as(u32, @intCast(layer)) },
                    .extent = .{ width, height, 1 },
                    .mip_level = options.mip_level,
                    .sample_index = options.sample_index,
                });
                const offset = try common.add(options.destination.offset, try common.add(try common.add(try common.mul(layer, image_stride), try common.mul(row, options.bytes_per_row)), try common.mul(column, texel_bytes)));
                const span = try common.add(try common.mul(height - 1, options.bytes_per_row), count);
                try copyPackedRows(context, packed_buffer_range, .{ .owner = options.destination.owner, .offset = offset, .size = span }, count, source_stride, options.bytes_per_row, height);
                row += height;
            }
            column += width;
        }
    }
}

comptime {
    std.debug.assert(@sizeOf([64]u8) == 16 * 4);
    std.debug.assert(@sizeOf([32]u8) == 8 * 4);
}
