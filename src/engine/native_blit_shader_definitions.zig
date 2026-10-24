const std = @import("std");
const api = @import("../api/root.zig");

pub const ScalarKind = enum { float, sint, uint };
pub const FormatKind = enum(u8) {
    unorm8 = 1,
    snorm8,
    uint8,
    sint8,
    unorm16,
    snorm16,
    uint16,
    sint16,
    float16,
    uint32,
    sint32,
    float32,
    rgb10_a2_unorm,
    rgb10_a2_uint,
    rg11_b10_ufloat,
    rgb9_e5_ufloat,
};

pub fn formatCode(format: api.TextureFormat) error{InvalidKernelKey}!u32 {
    return switch (format) {
        .r8_unorm => code(.unorm8, 1),
        .r8_snorm => code(.snorm8, 1),
        .r8_uint, .stencil8 => code(.uint8, 1),
        .r8_sint => code(.sint8, 1),
        .r16_unorm, .depth16_unorm => code(.unorm16, 1),
        .r16_snorm => code(.snorm16, 1),
        .r16_uint => code(.uint16, 1),
        .r16_sint => code(.sint16, 1),
        .r16_float => code(.float16, 1),
        .rg8_unorm => code(.unorm8, 2),
        .rg8_snorm => code(.snorm8, 2),
        .rg8_uint => code(.uint8, 2),
        .rg8_sint => code(.sint8, 2),
        .r32_float, .depth24_plus, .depth24_plus_stencil8, .depth32_float, .depth32_float_stencil8 => code(.float32, 1),
        .r32_uint => code(.uint32, 1),
        .r32_sint => code(.sint32, 1),
        .rg16_unorm => code(.unorm16, 2),
        .rg16_snorm => code(.snorm16, 2),
        .rg16_uint => code(.uint16, 2),
        .rg16_sint => code(.sint16, 2),
        .rg16_float => code(.float16, 2),
        .rgba8_unorm => code(.unorm8, 4),
        .rgba8_unorm_srgb => code(.unorm8, 4) | (1 << 13),
        .rgba8_snorm => code(.snorm8, 4),
        .rgba8_uint => code(.uint8, 4),
        .rgba8_sint => code(.sint8, 4),
        .bgra8_unorm => code(.unorm8, 4) | (1 << 12),
        .bgra8_unorm_srgb => code(.unorm8, 4) | (1 << 12) | (1 << 13),
        .rgb10_a2_unorm => code(.rgb10_a2_unorm, 4),
        .rgb10_a2_uint => code(.rgb10_a2_uint, 4),
        .rg11_b10_ufloat => code(.rg11_b10_ufloat, 3),
        .rgb9_e5_ufloat => code(.rgb9_e5_ufloat, 3),
        .rg32_float => code(.float32, 2),
        .rg32_uint => code(.uint32, 2),
        .rg32_sint => code(.sint32, 2),
        .rgba16_unorm => code(.unorm16, 4),
        .rgba16_snorm => code(.snorm16, 4),
        .rgba16_uint => code(.uint16, 4),
        .rgba16_sint => code(.sint16, 4),
        .rgba16_float => code(.float16, 4),
        .rgba32_float => code(.float32, 4),
        .rgba32_uint => code(.uint32, 4),
        .rgba32_sint => code(.sint32, 4),
        else => error.InvalidKernelKey,
    };
}

fn code(kind: FormatKind, channels: u4) u32 {
    return @as(u32, @backingInt(kind)) | (@as(u32, channels) << 8);
}

pub fn texelByteSize(format: api.TextureFormat) error{InvalidKernelKey}!u32 {
    const value = try formatCode(format);
    const kind = value & 255;
    if (kind >= 13) return 4;
    const component_bytes: u32 = if (kind <= 4) 1 else if (kind <= 9) 2 else 4;
    return component_bytes * ((value >> 8) & 15);
}

pub fn depthFormat(format: api.TextureFormat) bool {
    return switch (format) {
        .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float, .depth32_float_stencil8 => true,
        else => false,
    };
}

pub fn scalarKind(format: api.TextureFormat) error{InvalidKernelKey}!ScalarKind {
    return switch (format) {
        .undefined_, .stencil8 => error.InvalidKernelKey,
        .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float, .depth32_float_stencil8 => error.InvalidKernelKey,
        .r8_uint, .r16_uint, .r32_uint, .rg8_uint, .rg16_uint, .rg32_uint, .rgba8_uint, .rgba16_uint, .rgba32_uint, .rgb10_a2_uint => .uint,
        .r8_sint, .r16_sint, .r32_sint, .rg8_sint, .rg16_sint, .rg32_sint, .rgba8_sint, .rgba16_sint, .rgba32_sint => .sint,
        else => .float,
    };
}

const dimensions = [_]api.TextureViewDimension{ ._1d, ._2d, ._2d_array, ._3d, ._2d };
const dimension_names = [_][]const u8{ "1d", "2d", "2d_array", "3d", "2d_ms" };
const scalars = [_]ScalarKind{ .float, .sint, .uint };
const Family = enum { pack, unpack, filtered, loaded, staged, clear, depth_pack, depth_unpack, depth_copy, stencil_unpack, row_merge };
const Variant = struct {
    family: Family,
    scalar: ScalarKind = .float,
    dimension_index: usize = 1,
    color_slot: u3 = 0,
    stencil_bit: u3 = 0,
};

fn Artifact(comptime Types: type, comptime name: []const u8, comptime depth: bool) type {
    return struct {
        const bytes = @embedFile("shaders/" ++ name ++ ".spv");
        const words = if (depth) Types.depthWords(bytes) else Types.words(bytes);
        const stage: Types.Stage = .{ .words = &words, .entry_point = "main" };
    };
}

fn Entry(comptime Types: type, comptime variant: Variant) type {
    const dimension = dimensions[variant.dimension_index];
    const multisampled = variant.dimension_index == 4;
    const digit_names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7" };
    const color_slot_name = digit_names[variant.color_slot];
    const stencil_bit_name = digit_names[variant.stencil_bit];
    const scalar_name = @tagName(variant.scalar);
    const dimension_name = dimension_names[variant.dimension_index];
    const depth = variant.family == .depth_unpack or variant.family == .depth_copy;
    const compute = variant.family == .pack or variant.family == .depth_pack or
        variant.family == .row_merge;
    const name = switch (variant.family) {
        .pack => "texture_to_buffer_" ++ scalar_name ++ "_" ++ dimension_name ++ ".comp",
        .depth_pack => "texture_to_buffer_depth_" ++ dimension_name ++ ".comp",
        .unpack => "buffer_to_color_" ++ scalar_name ++ "_" ++ color_slot_name ++ ".frag",
        .filtered => "color_copy_float_" ++ dimension_name ++ "_" ++ color_slot_name ++ ".frag",
        .loaded => if (variant.scalar == .float and !multisampled)
            "color_load_float_" ++ dimension_name ++ "_" ++ color_slot_name ++ ".frag"
        else
            "color_copy_" ++ scalar_name ++ "_" ++ dimension_name ++ "_" ++ color_slot_name ++ ".frag",
        .staged => if (variant.scalar == .float)
            "color_copy_buffer_" ++ color_slot_name ++ ".frag"
        else
            "color_copy_buffer_" ++ scalar_name ++ "_" ++ color_slot_name ++ ".frag",
        .clear => "clear_color_" ++ scalar_name ++ "_" ++ color_slot_name ++ ".frag",
        .depth_unpack => "buffer_to_depth.frag",
        .stencil_unpack => "buffer_to_stencil_" ++ stencil_bit_name ++ ".frag",
        .depth_copy => "depth_copy_" ++ dimension_name ++ ".frag",
        .row_merge => "buffer_row_merge.comp",
    };
    return struct {
        const sampled: Types.Slot = .{ .sampled_view = .{
            .dimension = dimension,
            .sample_type = if (variant.family == .depth_copy or variant.family == .depth_pack)
                .unfilterable_float
            else switch (variant.scalar) {
                .float => if (variant.family == .filtered) .float else .unfilterable_float,
                .sint => .sint,
                .uint => .uint,
            },
            .multisampled = multisampled,
            .depth_view = variant.family == .depth_copy or variant.family == .depth_pack,
        } };
        const storage_read: Types.Slot = .{ .buffer = .{ .access = .storage_read, .min_size = 4 } };
        const storage_write: Types.Slot = .{ .buffer = .{ .access = .storage_write, .min_size = 4 } };
        const slots = switch (variant.family) {
            .pack, .depth_pack => [_]Types.Slot{ sampled, storage_write },
            .filtered => [_]Types.Slot{ sampled, .{ .sampler = .{ .comparison = false } } },
            .loaded, .depth_copy => [_]Types.Slot{sampled},
            .unpack, .depth_unpack, .stencil_unpack, .staged => [_]Types.Slot{storage_read},
            .clear => [_]Types.Slot{},
            .row_merge => [_]Types.Slot{ storage_read, storage_read, storage_write },
        };
        const parameters: u32 = switch (variant.family) {
            .clear => 128,
            .filtered, .loaded, .staged => if (variant.scalar == .float) 224 else 96,
            .depth_copy => 96,
            .row_merge => 32,
            else => 64,
        };
        const fixed_state: Types.FixedState = blk: {
            var result: Types.FixedState = .{};
            result.color_scalar_kinds[variant.color_slot] = switch (variant.scalar) {
                .float => .float,
                .sint => .sint,
                .uint => .uint,
            };
            result.depth_output = depth;
            result.stencil_replace = variant.family == .stencil_unpack;
            break :blk result;
        };
        const definition: Types.Definition = .{
            .slots = &slots,
            .parameter_size = parameters,
            .depth_range_push_constants = depth,
            .stages = if (compute) .{ .compute = .{
                .stage = Artifact(Types, name, false).stage,
                .workgroup_size = .{ 64, 1, 1 },
            } } else .{ .render = .{
                .vertex = Types.fullscreen_vertex,
                .fragment = Artifact(Types, name, depth).stage,
                .fixed_state = fixed_state,
            } },
        };
    };
}

fn dimensionIndex(dimension: api.TextureViewDimension, multisampled: bool) error{InvalidKernelKey}!usize {
    if (multisampled) return if (dimension == ._2d) 4 else error.InvalidKernelKey;
    return switch (dimension) {
        ._1d => 0,
        ._2d => 1,
        ._2d_array => 2,
        ._3d => 3,
        else => error.InvalidKernelKey,
    };
}

fn colorSlot(comptime Types: type, key: Types.KernelKey) error{InvalidKernelKey}!u3 {
    if (@popCount(key.color_write_slots) != 1) return error.InvalidKernelKey;
    return @intCast(@ctz(key.color_write_slots));
}

fn attachmentScalar(comptime Types: type, key: Types.KernelKey, slot: u3) error{InvalidKernelKey}!ScalarKind {
    const owner = key.attachments orelse return error.InvalidKernelKey;
    const format = std.enums.fromInt(api.TextureFormat, owner.value.color_formats[slot]) orelse return error.InvalidKernelKey;
    _ = try formatCode(format);
    return scalarKind(format);
}

fn unfilterableFormat(format: api.TextureFormat) bool {
    return format == .r32_float or format == .rg32_float or format == .rgba32_float;
}

pub fn definition(comptime Types: type, key: Types.KernelKey) error{InvalidKernelKey}!*const Types.Definition {
    switch (key.id) {
        .buffer_row_merge => return &Entry(Types, .{ .family = .row_merge }).definition,
        .texture_to_buffer => {
            const output_format = try formatCode(key.storage_format);
            const index = try dimensionIndex(key.source_dimension, key.source_multisampled);
            const stencil_source = key.source_format == .stencil8 or
                (key.storage_format == .stencil8 and
                    (key.source_format == .depth24_plus_stencil8 or
                        key.source_format == .depth32_float_stencil8));
            const source_scalar: ScalarKind = if (stencil_source) .uint else if (depthFormat(key.source_format)) .float else try scalarKind(key.source_format);
            const output_kind = output_format & 255;
            const output_scalar: ScalarKind = switch (output_kind) {
                3, 7, 10, 14 => .uint,
                4, 8, 11 => .sint,
                else => .float,
            };
            if (source_scalar != output_scalar) return error.InvalidKernelKey;
            if (depthFormat(key.source_format) and !stencil_source) {
                inline for (.{ 1, 2, 4 }) |dimension_index| {
                    if (index == dimension_index)
                        return &Entry(Types, .{ .family = .depth_pack, .dimension_index = dimension_index }).definition;
                }
                return error.InvalidKernelKey;
            }
            inline for (scalars) |scalar| {
                inline for (0..5) |dimension_index| {
                    if (source_scalar == scalar and index == dimension_index)
                        return &Entry(Types, .{ .family = .pack, .scalar = scalar, .dimension_index = dimension_index }).definition;
                }
            }
        },
        .buffer_to_color => {
            _ = try formatCode(key.storage_format);
            const scalar = try scalarKind(key.storage_format);
            const slot = try colorSlot(Types, key);
            if (try attachmentScalar(Types, key, slot) != scalar) return error.InvalidKernelKey;
            inline for (scalars) |kind| {
                inline for (0..8) |location| {
                    if (scalar == kind and slot == location)
                        return &Entry(Types, .{ .family = .unpack, .scalar = kind, .color_slot = location }).definition;
                }
            }
        },
        .buffer_to_depth => {
            if (!depthFormat(key.storage_format) and key.storage_format != .r16_unorm and
                key.storage_format != .r32_float) return error.InvalidKernelKey;
            return &Entry(Types, .{ .family = .depth_unpack }).definition;
        },
        .buffer_to_stencil => {
            if (key.storage_format != .stencil8 and key.storage_format != .r8_uint)
                return error.InvalidKernelKey;
            const bit = key.stencil_write_bit orelse return error.InvalidKernelKey;
            inline for (0..8) |stencil_bit| {
                if (bit == stencil_bit)
                    return &Entry(Types, .{
                        .family = .stencil_unpack,
                        .stencil_bit = stencil_bit,
                    }).definition;
            }
            return error.InvalidKernelKey;
        },
        .clear_color => {
            const slot = try colorSlot(Types, key);
            const scalar = try attachmentScalar(Types, key, slot);
            inline for (scalars) |kind| {
                inline for (0..8) |location| {
                    if (scalar == kind and slot == location)
                        return &Entry(Types, .{ .family = .clear, .scalar = kind, .color_slot = location }).definition;
                }
            }
        },
        .color_to_color => {
            const scalar = try scalarKind(key.source_format);
            const slot = try colorSlot(Types, key);
            if (try attachmentScalar(Types, key, slot) != scalar) return error.InvalidKernelKey;
            if (key.source_dimension == .undefined_) {
                const expected: api.TextureFormat = switch (scalar) {
                    .float => .rgba32_float,
                    .sint => .rgba32_sint,
                    .uint => .rgba32_uint,
                };
                if (key.storage_format != expected or key.source_multisampled)
                    return error.InvalidKernelKey;
                inline for (scalars) |kind| {
                    inline for (0..8) |location| {
                        if (scalar == kind and slot == location)
                            return &Entry(Types, .{ .family = .staged, .scalar = kind, .color_slot = location }).definition;
                    }
                }
            } else {
                const index = try dimensionIndex(key.source_dimension, key.source_multisampled);
                const filtered = scalar == .float and !key.source_multisampled and
                    !unfilterableFormat(key.source_format);
                inline for (scalars) |kind| {
                    inline for (0..5) |dimension_index| {
                        inline for (0..8) |location| {
                            if (scalar == kind and index == dimension_index and slot == location) {
                                if (filtered) {
                                    if (comptime kind == .float and dimension_index != 4)
                                        return &Entry(Types, .{ .family = .filtered, .dimension_index = dimension_index, .color_slot = location }).definition;
                                }
                                return &Entry(Types, .{ .family = .loaded, .scalar = kind, .dimension_index = dimension_index, .color_slot = location }).definition;
                            }
                        }
                    }
                }
            }
        },
        .depth_to_depth => {
            if (!depthFormat(key.source_format)) return error.InvalidKernelKey;
            const index = try dimensionIndex(key.source_dimension, key.source_multisampled);
            inline for (.{ 1, 2, 4 }) |dimension_index| {
                if (index == dimension_index)
                    return &Entry(Types, .{ .family = .depth_copy, .dimension_index = dimension_index }).definition;
            }
        },
        else => return error.InvalidKernelKey,
    }
    return error.InvalidKernelKey;
}
