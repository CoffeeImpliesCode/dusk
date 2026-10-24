const std = @import("std");
const api = @import("../api/enums.zig");
const features = @import("features.zig");

pub const format_count: usize = 109;
pub const webgpu_format_count: usize = 101;
pub const dawn_format_count: usize = 8;
pub const dawn_format_base: u32 = 0x00050000;
pub const enum_prefix_mask: u32 = 0xffff0000;
pub const dawn_enum_prefix = dawn_format_base;
pub const max_planes_per_format = 3;
pub const texture_bytes_per_row_alignment = 256;

pub const Aspect = enum(u7) {
    none = 0,
    color = 1,
    depth = 2,
    stencil = 4,
    plane_0 = 8,
    plane_1 = 16,
    plane_2 = 32,
    combined_depth_stencil = 64,
    _,

    pub const bit_count = 7;
};
pub const AspectError = error{ InvalidAspect, MultipleAspects, AspectNotPresent };

pub fn aspectIndex(aspect: Aspect) AspectError!u8 {
    return switch (aspect) {
        .color, .depth, .plane_0, .combined_depth_stencil => 0,
        .stencil, .plane_1 => 1,
        .plane_2 => 2,
        else => if (@popCount(@backingInt(aspect)) > 1)
            error.MultipleAspects
        else
            error.InvalidAspect,
    };
}

pub fn aspectCount(aspects: Aspect) u8 {
    return if (aspects == .stencil) 2 else @popCount(@backingInt(aspects));
}

pub const TexelBlockInfo = struct { byte_size: u32 = 0, width: u32 = 0, height: u32 = 0 };
pub const TextureComponentType = enum { float, sint, uint };
pub const TextureSubsampling = enum { undefined_, e420, e422, e444 };
pub const SampleType = api.TextureSampleType;
pub const SampleTypeSet = packed struct(u8) {
    float: bool = false,
    unfilterable_float: bool = false,
    depth: bool = false,
    sint: bool = false,
    uint: bool = false,
    padding: u3 = 0,
};
pub const SampleTypeBit = enum(u8) {
    none = 0,
    float = 1,
    unfilterable_float = 2,
    depth = 4,
    sint = 8,
    uint = 16,
};

pub fn sampleTypeBit(sample: SampleType) error{UndefinedSampleType}!SampleTypeSet {
    return switch (sample) {
        .binding_not_used => .{},
        .undefined_ => error.UndefinedSampleType,
        .float => .{ .float = true },
        .unfilterable_float => .{ .unfilterable_float = true },
        .depth => .{ .depth = true },
        .sint => .{ .sint = true },
        .uint => .{ .uint = true },
    };
}

pub const FormatCapability = packed struct(u16) {
    multisample: bool = false,
    renderable: bool = false,
    resolve: bool = false,
    storage_read_only: bool = false,
    storage_write_only: bool = false,
    storage_read_write: bool = false,
    storage_attachment: bool = false,
    blendable: bool = false,
    padding: u8 = 0,

    pub const none: FormatCapability = .{};
};

/// These Dawn gates were excluded by the public generator's raw-tag normalization.
/// They are diagnostics, not another set of enabled features.
pub const UnavailableFeature = enum {
    dawn_multi_planar_formats,
    multi_planar_format_nv16,
    multi_planar_format_p010,
    multi_planar_format_nv12a,
    unorm16_texture_formats,
};
pub const UnsupportedReason = union(enum) {
    supported,
    requires_feature: features.Feature,
    compatibility_mode,
    unavailable_feature: UnavailableFeature,

    pub fn format(self: UnsupportedReason, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .supported => try writer.writeAll("supported"),
            .requires_feature => |feature| try writer.print("requires feature {s}", .{@tagName(feature)}),
            .compatibility_mode => try writer.writeAll("not supported in compatibility mode"),
            .unavailable_feature => |feature| try writer.print(
                "requires excluded Dawn feature {s}",
                .{@tagName(feature)},
            ),
        }
    }
};

pub const AspectInfo = struct {
    block: TexelBlockInfo = .{},
    base_type: TextureComponentType = .float,
    supported_sample_types: SampleTypeSet = .{},
    format: FormatName = .undefined_,
};

pub const Format = struct {
    format: FormatName = .undefined_,
    index: usize = 0,
    caps: FormatCapability = .{},
    is_bc: bool = false,
    is_astc: bool = false,
    is_compressed: bool = false,
    unsupported_reason: UnsupportedReason = .supported,
    aspects: Aspect = .none,
    component_count: u8 = 0,
    render_target_pixel_byte_cost: u8 = 0,
    render_target_component_alignment: u8 = 0,
    base_format: FormatName = .undefined_,
    base_view_format: FormatName = .undefined_,
    sub_sampling: TextureSubsampling = .undefined_,
    aspect_info: [max_planes_per_format]AspectInfo = @splat(.{}),

    pub fn isSupported(self: *const Format) bool {
        return self.unsupported_reason == .supported;
    }
    pub fn isColor(self: *const Format) bool {
        return self.aspects == .color;
    }
    pub fn hasDepth(self: *const Format) bool {
        return @backingInt(self.aspects) & @backingInt(Aspect.depth) != 0;
    }
    pub fn hasStencil(self: *const Format) bool {
        return @backingInt(self.aspects) & @backingInt(Aspect.stencil) != 0;
    }
    pub fn hasDepthOrStencil(self: *const Format) bool {
        return self.hasDepth() or self.hasStencil();
    }
    pub fn hasAlphaChannel(self: *const Format) bool {
        return self.component_count == 4 and self.isColor();
    }
    pub fn isSnorm(self: *const Format) bool {
        return switch (self.format) {
            .r8_snorm, .rg8_snorm, .rgba8_snorm => true,
            else => false,
        };
    }
    pub fn isMultiPlanar(self: *const Format) bool {
        return @backingInt(self.aspects) & 56 != 0;
    }
    pub fn copyCompatibleWith(self: *const Format, other: *const Format) bool {
        return self.base_format == other.base_format;
    }
    pub fn viewCompatibleWith(self: *const Format, other: *const Format) bool {
        return self.base_format == other.base_format;
    }
    pub fn viewCompatibleWithApi(self: *const Format, other: api.TextureFormat) bool {
        if (other == .undefined_) return false;
        const name = fromApiFormat(other);
        return name == self.format or name == self.base_format or name == self.base_view_format;
    }
    pub fn getAspectInfo(self: *const Format, aspect: api.TextureAspect) AspectError!*const AspectInfo {
        return self.getAspectInfoForAspect(try self.selectAspects(aspect));
    }
    pub fn selectAspects(self: *const Format, aspect: api.TextureAspect) AspectError!Aspect {
        const selected: Aspect = switch (aspect) {
            .undefined_ => return error.InvalidAspect,
            .all => self.aspects,
            .depth_only => @fromBackingInt(@intCast(@backingInt(self.aspects) & 2)),
            .stencil_only => @fromBackingInt(@intCast(@backingInt(self.aspects) & 4)),
        };
        if (selected == .none) return error.AspectNotPresent;
        return selected;
    }
    pub fn getAspectInfoForAspect(
        self: *const Format,
        aspect: Aspect,
    ) AspectError!*const AspectInfo {
        const index = try aspectIndex(aspect);
        if (@backingInt(self.aspects) & @backingInt(aspect) == 0) {
            return error.AspectNotPresent;
        }
        std.debug.assert(index < aspectCount(self.aspects));
        return &self.aspect_info[index];
    }
};
pub const FormatTable = [format_count]Format;

pub fn computeFormatIndex(format: api.TextureFormat) ?usize {
    return computeCanonicalFormatIndex(fromApiFormat(format));
}
pub fn computeCanonicalFormatIndex(format: FormatName) ?usize {
    const tag = @backingInt(format);
    if (tag > 0 and tag <= webgpu_format_count) return tag - 1;
    if (tag >= dawn_format_base and tag < dawn_format_base + dawn_format_count) {
        return webgpu_format_count + tag - dawn_format_base;
    }
    return null;
}
pub fn fromApiFormat(format: api.TextureFormat) FormatName {
    return @fromBackingInt(@intCast(@backingInt(format)));
}
pub fn toApiFormat(format: FormatName) error{UnrepresentableFormat}!api.TextureFormat {
    if (@backingInt(format) >= dawn_format_base) return error.UnrepresentableFormat;
    return @fromBackingInt(@intCast(@backingInt(format)));
}

const any_float: SampleTypeSet = .{ .float = true, .unfilterable_float = true };
const ColorSample = enum { any_float, uint, sint, float32, norm16 };
const ColorRow = struct {
    format: FormatName,
    byte_size: u32,
    sample: ColorSample,
    components: u8,
    pixel_cost: u8,
    alignment: u8,
};
const CompressedRow = struct {
    format: FormatName,
    byte_size: u32,
    width: u32,
    height: u32,
    components: u8,
    family: enum { bc, etc, astc },
};

fn required(enabled: features.FeaturesSet, feature: features.Feature) UnsupportedReason {
    if (enabled.isEnabled(feature)) return .supported;
    if (feature == .core_features_and_limits) return .compatibility_mode;
    return .{ .requires_feature = feature };
}

fn addFormat(out: *FormatTable, value: Format) void {
    const index = computeCanonicalFormatIndex(value.format).?;
    std.debug.assert(out[index].format == .undefined_);
    out[index] = value;
    out[index].index = index;
    if (@popCount(@backingInt(value.aspects)) == 1) {
        std.debug.assert(value.aspect_info[0].block.byte_size != 0);
        std.debug.assert(texture_bytes_per_row_alignment % value.aspect_info[0].block.byte_size == 0);
    }
}

/// The caller owns the table. No device feature specialization or allocation is hidden here.
pub fn buildFormatTable(enabled: features.FeaturesSet, out: *FormatTable) void {
    for (out) |*slot| slot.* = .{};
    for (color_rows) |row| {
        const sample: SampleTypeSet = switch (row.sample) {
            .any_float => any_float,
            .uint => .{ .uint = true },
            .sint => .{ .sint = true },
            .float32 => if (enabled.isEnabled(.float32_filterable))
                any_float
            else
                .{ .unfilterable_float = true },
            .norm16 => if (enabled.isEnabled(.unorm16_filterable))
                any_float
            else
                .{ .unfilterable_float = true },
        };
        addFormat(out, .{
            .format = row.format,
            .base_format = row.format,
            .aspects = .color,
            .component_count = row.components,
            .render_target_pixel_byte_cost = row.pixel_cost,
            .render_target_component_alignment = row.alignment,
            .aspect_info = .{ .{
                .block = .{ .byte_size = row.byte_size, .width = 1, .height = 1 },
                .base_type = if (sample.uint) .uint else if (sample.sint) .sint else .float,
                .supported_sample_types = sample,
                .format = row.format,
            }, .{}, .{} },
        });
    }
    computeFormatCapabilities(enabled, out);
    const depth_names = [_]FormatName{ .depth16_unorm, .depth24_plus, .depth32_float };
    for (depth_names) |name| {
        addFormat(out, .{
            .format = name,
            .base_format = name,
            .aspects = .depth,
            .component_count = 1,
            .caps = .{ .renderable = true, .multisample = true },
            .aspect_info = .{ .{
                .block = .{ .byte_size = if (name == .depth16_unorm) 2 else 4, .width = 1, .height = 1 },
                .supported_sample_types = .{ .depth = true, .unfilterable_float = true },
                .format = name,
            }, .{}, .{} },
        });
    }
    const stencil: AspectInfo = .{
        .block = .{ .byte_size = 1, .width = 1, .height = 1 },
        .base_type = .uint,
        .supported_sample_types = .{ .uint = true },
        .format = .stencil8,
    };
    addFormat(out, .{
        .format = .stencil8,
        .base_format = .stencil8,
        .aspects = .stencil,
        .component_count = 1,
        .caps = .{ .renderable = true, .multisample = true },
        .aspect_info = .{ stencil, stencil, .{} },
    });
    for (compressed_rows) |row| {
        const feature: features.Feature = switch (row.family) {
            .bc => .texture_compression_bc,
            .etc => .texture_compression_etc2,
            .astc => .texture_compression_astc,
        };
        addFormat(out, .{
            .format = row.format,
            .base_format = row.format,
            .aspects = .color,
            .component_count = row.components,
            .is_compressed = true,
            .is_bc = row.family == .bc,
            .is_astc = row.family == .astc,
            .unsupported_reason = required(enabled, feature),
            .aspect_info = .{ .{
                .block = .{ .byte_size = row.byte_size, .width = row.width, .height = row.height },
                .supported_sample_types = any_float,
                .format = row.format,
            }, .{}, .{} },
        });
    }
    for (multi_rows) |row| {
        var value: Format = .{
            .format = row.format,
            .base_format = row.format,
            .aspects = row.aspects,
            .component_count = row.components,
            .sub_sampling = row.sub_sampling,
            .caps = if (row.aspects == @as(Aspect, @fromBackingInt(@intCast(6))))
                .{ .renderable = true, .multisample = true }
            else
                .{},
            .unsupported_reason = switch (row.gate) {
                .always => .supported,
                .feature => |feature| required(enabled, feature),
                .excluded => |feature| .{ .unavailable_feature = feature },
            },
        };
        for (row.planes, 0..) |plane, index| {
            if (plane != .undefined_) {
                value.aspect_info[index] = out[computeCanonicalFormatIndex(plane).?].aspect_info[0];
            }
        }
        addFormat(out, value);
    }
    for (view_format_pairs) |pair| {
        out[computeCanonicalFormatIndex(pair[1]).?].base_format = pair[0];
        out[computeCanonicalFormatIndex(pair[0]).?].base_view_format = pair[1];
    }
    for (out) |slot| std.debug.assert(slot.format != .undefined_);
}

const MultiRow = struct {
    format: FormatName,
    aspects: Aspect,
    components: u8,
    sub_sampling: TextureSubsampling = .undefined_,
    gate: union(enum) { always, feature: features.Feature, excluded: UnavailableFeature },
    planes: [3]FormatName,
};
const multi_rows = [_]MultiRow{
    .{
        .format = .depth24_plus_stencil8,
        .aspects = @fromBackingInt(@intCast(6)),
        .components = 2,
        .gate = .always,
        .planes = .{ .depth24_plus, .stencil8, .undefined_ },
    },
    .{
        .format = .depth32_float_stencil8,
        .aspects = @fromBackingInt(@intCast(6)),
        .components = 2,
        .gate = .{ .feature = .depth32_float_stencil8 },
        .planes = .{ .depth32_float, .stencil8, .undefined_ },
    },
    .{
        .format = .r8_bg8_biplanar420_unorm,
        .aspects = @fromBackingInt(@intCast(24)),
        .components = 3,
        .sub_sampling = .e420,
        .gate = .{ .excluded = .dawn_multi_planar_formats },
        .planes = .{ .r8_unorm, .rg8_unorm, .undefined_ },
    },
    .{
        .format = .r8_bg8_biplanar422_unorm,
        .aspects = @fromBackingInt(@intCast(24)),
        .components = 3,
        .sub_sampling = .e422,
        .gate = .{ .excluded = .multi_planar_format_nv16 },
        .planes = .{ .r8_unorm, .rg8_unorm, .undefined_ },
    },
    .{
        .format = .r8_bg8_biplanar444_unorm,
        .aspects = @fromBackingInt(@intCast(24)),
        .components = 3,
        .sub_sampling = .e444,
        .gate = .{ .feature = .multi_planar_format_nv24 },
        .planes = .{ .r8_unorm, .rg8_unorm, .undefined_ },
    },
    .{
        .format = .r10x6_bg10x6_biplanar420_unorm,
        .aspects = @fromBackingInt(@intCast(24)),
        .components = 3,
        .sub_sampling = .e420,
        .gate = .{ .excluded = .multi_planar_format_p010 },
        .planes = .{ .r16_unorm, .rg16_unorm, .undefined_ },
    },
    .{
        .format = .r10x6_bg10x6_biplanar422_unorm,
        .aspects = @fromBackingInt(@intCast(24)),
        .components = 3,
        .sub_sampling = .e422,
        .gate = .{ .feature = .multi_planar_format_p210 },
        .planes = .{ .r16_unorm, .rg16_unorm, .undefined_ },
    },
    .{
        .format = .r10x6_bg10x6_biplanar444_unorm,
        .aspects = @fromBackingInt(@intCast(24)),
        .components = 3,
        .sub_sampling = .e444,
        .gate = .{ .feature = .multi_planar_format_p410 },
        .planes = .{ .r16_unorm, .rg16_unorm, .undefined_ },
    },
    .{
        .format = .r8_bg8_a8_triplanar420_unorm,
        .aspects = @fromBackingInt(@intCast(56)),
        .components = 4,
        .sub_sampling = .e420,
        .gate = .{ .excluded = .multi_planar_format_nv12a },
        .planes = .{ .r8_unorm, .rg8_unorm, .r8_unorm },
    },
};

pub const ShapeCounts = struct {
    color: usize = 0,
    depth: usize = 0,
    stencil: usize = 0,
    bc: usize = 0,
    etc2: usize = 0,
    astc: usize = 0,
    multi_aspect: usize = 0,
};
pub fn shapeCounts(table: *const FormatTable) ShapeCounts {
    var counts: ShapeCounts = .{};
    for (table) |value| {
        if (value.is_bc) {
            counts.bc += 1;
        } else if (value.is_astc) {
            counts.astc += 1;
        } else if (value.is_compressed) {
            counts.etc2 += 1;
        } else if (value.aspects == .color) {
            counts.color += 1;
        } else if (value.aspects == .depth) {
            counts.depth += 1;
        } else if (value.aspects == .stencil) {
            counts.stencil += 1;
        } else {
            counts.multi_aspect += 1;
        }
    }
    return counts;
}

/// Internal physical domain. Dawn-only rows are not public API aliases.
/// `dawn.json:4501-4508`, `dawn_platform.h:135-136`, `Format.cpp:172-198`.
pub const FormatName = enum(u32) {
    undefined_ = 0,
    r8_unorm = 1,
    r8_snorm = 2,
    r8_uint = 3,
    r8_sint = 4,
    r16_unorm = 5,
    r16_snorm = 6,
    r16_uint = 7,
    r16_sint = 8,
    r16_float = 9,
    rg8_unorm = 10,
    rg8_snorm = 11,
    rg8_uint = 12,
    rg8_sint = 13,
    r32_float = 14,
    r32_uint = 15,
    r32_sint = 16,
    rg16_unorm = 17,
    rg16_snorm = 18,
    rg16_uint = 19,
    rg16_sint = 20,
    rg16_float = 21,
    rgba8_unorm = 22,
    rgba8_unorm_srgb = 23,
    rgba8_snorm = 24,
    rgba8_uint = 25,
    rgba8_sint = 26,
    bgra8_unorm = 27,
    bgra8_unorm_srgb = 28,
    rgb10_a2_uint = 29,
    rgb10_a2_unorm = 30,
    rg11_b10_ufloat = 31,
    rgb9_e5_ufloat = 32,
    rg32_float = 33,
    rg32_uint = 34,
    rg32_sint = 35,
    rgba16_unorm = 36,
    rgba16_snorm = 37,
    rgba16_uint = 38,
    rgba16_sint = 39,
    rgba16_float = 40,
    rgba32_float = 41,
    rgba32_uint = 42,
    rgba32_sint = 43,
    stencil8 = 44,
    depth16_unorm = 45,
    depth24_plus = 46,
    depth24_plus_stencil8 = 47,
    depth32_float = 48,
    depth32_float_stencil8 = 49,
    bc1_rgba_unorm = 50,
    bc1_rgba_unorm_srgb = 51,
    bc2_rgba_unorm = 52,
    bc2_rgba_unorm_srgb = 53,
    bc3_rgba_unorm = 54,
    bc3_rgba_unorm_srgb = 55,
    bc4_r_unorm = 56,
    bc4_r_snorm = 57,
    bc5_rg_unorm = 58,
    bc5_rg_snorm = 59,
    bc6h_rgb_ufloat = 60,
    bc6h_rgb_float = 61,
    bc7_rgba_unorm = 62,
    bc7_rgba_unorm_srgb = 63,
    etc2_rgb8_unorm = 64,
    etc2_rgb8_unorm_srgb = 65,
    etc2_rgb8a1_unorm = 66,
    etc2_rgb8a1_unorm_srgb = 67,
    etc2_rgba8_unorm = 68,
    etc2_rgba8_unorm_srgb = 69,
    eac_r11_unorm = 70,
    eac_r11_snorm = 71,
    eac_rg11_unorm = 72,
    eac_rg11_snorm = 73,
    astc_4x4_unorm = 74,
    astc_4x4_unorm_srgb = 75,
    astc_5x4_unorm = 76,
    astc_5x4_unorm_srgb = 77,
    astc_5x5_unorm = 78,
    astc_5x5_unorm_srgb = 79,
    astc_6x5_unorm = 80,
    astc_6x5_unorm_srgb = 81,
    astc_6x6_unorm = 82,
    astc_6x6_unorm_srgb = 83,
    astc_8x5_unorm = 84,
    astc_8x5_unorm_srgb = 85,
    astc_8x6_unorm = 86,
    astc_8x6_unorm_srgb = 87,
    astc_8x8_unorm = 88,
    astc_8x8_unorm_srgb = 89,
    astc_10x5_unorm = 90,
    astc_10x5_unorm_srgb = 91,
    astc_10x6_unorm = 92,
    astc_10x6_unorm_srgb = 93,
    astc_10x8_unorm = 94,
    astc_10x8_unorm_srgb = 95,
    astc_10x10_unorm = 96,
    astc_10x10_unorm_srgb = 97,
    astc_12x10_unorm = 98,
    astc_12x10_unorm_srgb = 99,
    astc_12x12_unorm = 100,
    astc_12x12_unorm_srgb = 101,
    r8_bg8_biplanar420_unorm = dawn_format_base,
    r10x6_bg10x6_biplanar420_unorm = dawn_format_base + 1,
    r8_bg8_a8_triplanar420_unorm = dawn_format_base + 2,
    r8_bg8_biplanar422_unorm = dawn_format_base + 3,
    r8_bg8_biplanar444_unorm = dawn_format_base + 4,
    r10x6_bg10x6_biplanar422_unorm = dawn_format_base + 5,
    r10x6_bg10x6_biplanar444_unorm = dawn_format_base + 6,
    opaque_y_cb_cr_android = dawn_format_base + 7,
};

const color_rows = [_]ColorRow{
    .{ .format = .r8_unorm, .byte_size = 1, .sample = .any_float, .components = 1, .pixel_cost = 1, .alignment = 1 },
    .{ .format = .r8_snorm, .byte_size = 1, .sample = .any_float, .components = 1, .pixel_cost = 1, .alignment = 1 },
    .{ .format = .r8_uint, .byte_size = 1, .sample = .uint, .components = 1, .pixel_cost = 1, .alignment = 1 },
    .{ .format = .r8_sint, .byte_size = 1, .sample = .sint, .components = 1, .pixel_cost = 1, .alignment = 1 },
    .{ .format = .r16_uint, .byte_size = 2, .sample = .uint, .components = 1, .pixel_cost = 2, .alignment = 2 },
    .{ .format = .r16_sint, .byte_size = 2, .sample = .sint, .components = 1, .pixel_cost = 2, .alignment = 2 },
    .{ .format = .r16_float, .byte_size = 2, .sample = .any_float, .components = 1, .pixel_cost = 2, .alignment = 2 },
    .{ .format = .rg8_unorm, .byte_size = 2, .sample = .any_float, .components = 2, .pixel_cost = 2, .alignment = 1 },
    .{ .format = .rg8_snorm, .byte_size = 2, .sample = .any_float, .components = 2, .pixel_cost = 2, .alignment = 2 },
    .{ .format = .rg8_uint, .byte_size = 2, .sample = .uint, .components = 2, .pixel_cost = 2, .alignment = 1 },
    .{ .format = .rg8_sint, .byte_size = 2, .sample = .sint, .components = 2, .pixel_cost = 2, .alignment = 1 },
    .{ .format = .r32_uint, .byte_size = 4, .sample = .uint, .components = 1, .pixel_cost = 4, .alignment = 4 },
    .{ .format = .r32_sint, .byte_size = 4, .sample = .sint, .components = 1, .pixel_cost = 4, .alignment = 4 },
    .{ .format = .r32_float, .byte_size = 4, .sample = .float32, .components = 1, .pixel_cost = 4, .alignment = 4 },
    .{ .format = .rg16_uint, .byte_size = 4, .sample = .uint, .components = 2, .pixel_cost = 4, .alignment = 2 },
    .{ .format = .rg16_sint, .byte_size = 4, .sample = .sint, .components = 2, .pixel_cost = 4, .alignment = 2 },
    .{ .format = .rg16_float, .byte_size = 4, .sample = .any_float, .components = 2, .pixel_cost = 4, .alignment = 2 },
    .{ .format = .rgba8_unorm, .byte_size = 4, .sample = .any_float, .components = 4, .pixel_cost = 8, .alignment = 1 },
    .{
        .format = .rgba8_unorm_srgb,
        .byte_size = 4,
        .sample = .any_float,
        .components = 4,
        .pixel_cost = 8,
        .alignment = 1,
    },
    .{ .format = .rgba8_snorm, .byte_size = 4, .sample = .any_float, .components = 4, .pixel_cost = 4, .alignment = 4 },
    .{ .format = .rgba8_uint, .byte_size = 4, .sample = .uint, .components = 4, .pixel_cost = 4, .alignment = 1 },
    .{ .format = .rgba8_sint, .byte_size = 4, .sample = .sint, .components = 4, .pixel_cost = 4, .alignment = 1 },
    .{ .format = .bgra8_unorm, .byte_size = 4, .sample = .any_float, .components = 4, .pixel_cost = 8, .alignment = 1 },
    .{
        .format = .bgra8_unorm_srgb,
        .byte_size = 4,
        .sample = .any_float,
        .components = 4,
        .pixel_cost = 8,
        .alignment = 1,
    },
    .{ .format = .rgb10_a2_uint, .byte_size = 4, .sample = .uint, .components = 4, .pixel_cost = 8, .alignment = 4 },
    .{
        .format = .rgb10_a2_unorm,
        .byte_size = 4,
        .sample = .any_float,
        .components = 4,
        .pixel_cost = 8,
        .alignment = 4,
    },
    .{
        .format = .rg11_b10_ufloat,
        .byte_size = 4,
        .sample = .any_float,
        .components = 3,
        .pixel_cost = 8,
        .alignment = 4,
    },
    .{
        .format = .rgb9_e5_ufloat,
        .byte_size = 4,
        .sample = .any_float,
        .components = 3,
        .pixel_cost = 0,
        .alignment = 0,
    },
    .{
        .format = .opaque_y_cb_cr_android,
        .byte_size = 1,
        .sample = .any_float,
        .components = 0,
        .pixel_cost = 0,
        .alignment = 0,
    },
    .{ .format = .rg32_uint, .byte_size = 8, .sample = .uint, .components = 2, .pixel_cost = 8, .alignment = 4 },
    .{ .format = .rg32_sint, .byte_size = 8, .sample = .sint, .components = 2, .pixel_cost = 8, .alignment = 4 },
    .{ .format = .rg32_float, .byte_size = 8, .sample = .float32, .components = 2, .pixel_cost = 8, .alignment = 4 },
    .{ .format = .rgba16_uint, .byte_size = 8, .sample = .uint, .components = 4, .pixel_cost = 8, .alignment = 2 },
    .{ .format = .rgba16_sint, .byte_size = 8, .sample = .sint, .components = 4, .pixel_cost = 8, .alignment = 2 },
    .{
        .format = .rgba16_float,
        .byte_size = 8,
        .sample = .any_float,
        .components = 4,
        .pixel_cost = 8,
        .alignment = 2,
    },
    .{ .format = .rgba32_uint, .byte_size = 16, .sample = .uint, .components = 4, .pixel_cost = 16, .alignment = 4 },
    .{ .format = .rgba32_sint, .byte_size = 16, .sample = .sint, .components = 4, .pixel_cost = 16, .alignment = 4 },
    .{
        .format = .rgba32_float,
        .byte_size = 16,
        .sample = .float32,
        .components = 4,
        .pixel_cost = 16,
        .alignment = 4,
    },
    .{ .format = .r16_unorm, .byte_size = 2, .sample = .norm16, .components = 1, .pixel_cost = 2, .alignment = 2 },
    .{ .format = .rg16_unorm, .byte_size = 4, .sample = .norm16, .components = 2, .pixel_cost = 4, .alignment = 2 },
    .{ .format = .rgba16_unorm, .byte_size = 8, .sample = .norm16, .components = 4, .pixel_cost = 8, .alignment = 2 },
    .{ .format = .r16_snorm, .byte_size = 2, .sample = .norm16, .components = 1, .pixel_cost = 2, .alignment = 2 },
    .{ .format = .rg16_snorm, .byte_size = 4, .sample = .norm16, .components = 2, .pixel_cost = 4, .alignment = 2 },
    .{ .format = .rgba16_snorm, .byte_size = 8, .sample = .norm16, .components = 4, .pixel_cost = 8, .alignment = 2 },
};

const compressed_rows = [_]CompressedRow{
    .{ .format = .bc1_rgba_unorm, .byte_size = 8, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc1_rgba_unorm_srgb, .byte_size = 8, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc4_r_snorm, .byte_size = 8, .width = 4, .height = 4, .components = 1, .family = .bc },
    .{ .format = .bc4_r_unorm, .byte_size = 8, .width = 4, .height = 4, .components = 1, .family = .bc },
    .{ .format = .bc2_rgba_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc2_rgba_unorm_srgb, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc3_rgba_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc3_rgba_unorm_srgb, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc5_rg_snorm, .byte_size = 16, .width = 4, .height = 4, .components = 2, .family = .bc },
    .{ .format = .bc5_rg_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 2, .family = .bc },
    .{ .format = .bc6h_rgb_float, .byte_size = 16, .width = 4, .height = 4, .components = 3, .family = .bc },
    .{ .format = .bc6h_rgb_ufloat, .byte_size = 16, .width = 4, .height = 4, .components = 3, .family = .bc },
    .{ .format = .bc7_rgba_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .bc7_rgba_unorm_srgb, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .bc },
    .{ .format = .etc2_rgb8_unorm, .byte_size = 8, .width = 4, .height = 4, .components = 3, .family = .etc },
    .{ .format = .etc2_rgb8_unorm_srgb, .byte_size = 8, .width = 4, .height = 4, .components = 3, .family = .etc },
    .{ .format = .etc2_rgb8a1_unorm, .byte_size = 8, .width = 4, .height = 4, .components = 4, .family = .etc },
    .{ .format = .etc2_rgb8a1_unorm_srgb, .byte_size = 8, .width = 4, .height = 4, .components = 4, .family = .etc },
    .{ .format = .etc2_rgba8_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .etc },
    .{ .format = .etc2_rgba8_unorm_srgb, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .etc },
    .{ .format = .eac_r11_unorm, .byte_size = 8, .width = 4, .height = 4, .components = 1, .family = .etc },
    .{ .format = .eac_r11_snorm, .byte_size = 8, .width = 4, .height = 4, .components = 1, .family = .etc },
    .{ .format = .eac_rg11_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 2, .family = .etc },
    .{ .format = .eac_rg11_snorm, .byte_size = 16, .width = 4, .height = 4, .components = 2, .family = .etc },
    .{ .format = .astc_4x4_unorm, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .astc },
    .{ .format = .astc_4x4_unorm_srgb, .byte_size = 16, .width = 4, .height = 4, .components = 4, .family = .astc },
    .{ .format = .astc_5x4_unorm, .byte_size = 16, .width = 5, .height = 4, .components = 4, .family = .astc },
    .{ .format = .astc_5x4_unorm_srgb, .byte_size = 16, .width = 5, .height = 4, .components = 4, .family = .astc },
    .{ .format = .astc_5x5_unorm, .byte_size = 16, .width = 5, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_5x5_unorm_srgb, .byte_size = 16, .width = 5, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_6x5_unorm, .byte_size = 16, .width = 6, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_6x5_unorm_srgb, .byte_size = 16, .width = 6, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_6x6_unorm, .byte_size = 16, .width = 6, .height = 6, .components = 4, .family = .astc },
    .{ .format = .astc_6x6_unorm_srgb, .byte_size = 16, .width = 6, .height = 6, .components = 4, .family = .astc },
    .{ .format = .astc_8x5_unorm, .byte_size = 16, .width = 8, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_8x5_unorm_srgb, .byte_size = 16, .width = 8, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_8x6_unorm, .byte_size = 16, .width = 8, .height = 6, .components = 4, .family = .astc },
    .{ .format = .astc_8x6_unorm_srgb, .byte_size = 16, .width = 8, .height = 6, .components = 4, .family = .astc },
    .{ .format = .astc_8x8_unorm, .byte_size = 16, .width = 8, .height = 8, .components = 4, .family = .astc },
    .{ .format = .astc_8x8_unorm_srgb, .byte_size = 16, .width = 8, .height = 8, .components = 4, .family = .astc },
    .{ .format = .astc_10x5_unorm, .byte_size = 16, .width = 10, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_10x5_unorm_srgb, .byte_size = 16, .width = 10, .height = 5, .components = 4, .family = .astc },
    .{ .format = .astc_10x6_unorm, .byte_size = 16, .width = 10, .height = 6, .components = 4, .family = .astc },
    .{ .format = .astc_10x6_unorm_srgb, .byte_size = 16, .width = 10, .height = 6, .components = 4, .family = .astc },
    .{ .format = .astc_10x8_unorm, .byte_size = 16, .width = 10, .height = 8, .components = 4, .family = .astc },
    .{ .format = .astc_10x8_unorm_srgb, .byte_size = 16, .width = 10, .height = 8, .components = 4, .family = .astc },
    .{ .format = .astc_10x10_unorm, .byte_size = 16, .width = 10, .height = 10, .components = 4, .family = .astc },
    .{ .format = .astc_10x10_unorm_srgb, .byte_size = 16, .width = 10, .height = 10, .components = 4, .family = .astc },
    .{ .format = .astc_12x10_unorm, .byte_size = 16, .width = 12, .height = 10, .components = 4, .family = .astc },
    .{ .format = .astc_12x10_unorm_srgb, .byte_size = 16, .width = 12, .height = 10, .components = 4, .family = .astc },
    .{ .format = .astc_12x12_unorm, .byte_size = 16, .width = 12, .height = 12, .components = 4, .family = .astc },
    .{ .format = .astc_12x12_unorm_srgb, .byte_size = 16, .width = 12, .height = 12, .components = 4, .family = .astc },
};
pub const view_format_pairs = [_][2]FormatName{
    .{ .rgba8_unorm, .rgba8_unorm_srgb },
    .{ .bgra8_unorm, .bgra8_unorm_srgb },
    .{ .bc1_rgba_unorm, .bc1_rgba_unorm_srgb },
    .{ .bc2_rgba_unorm, .bc2_rgba_unorm_srgb },
    .{ .bc3_rgba_unorm, .bc3_rgba_unorm_srgb },
    .{ .bc7_rgba_unorm, .bc7_rgba_unorm_srgb },
    .{ .etc2_rgb8_unorm, .etc2_rgb8_unorm_srgb },
    .{ .etc2_rgb8a1_unorm, .etc2_rgb8a1_unorm_srgb },
    .{ .etc2_rgba8_unorm, .etc2_rgba8_unorm_srgb },
    .{ .astc_4x4_unorm, .astc_4x4_unorm_srgb },
    .{ .astc_5x4_unorm, .astc_5x4_unorm_srgb },
    .{ .astc_5x5_unorm, .astc_5x5_unorm_srgb },
    .{ .astc_6x5_unorm, .astc_6x5_unorm_srgb },
    .{ .astc_6x6_unorm, .astc_6x6_unorm_srgb },
    .{ .astc_8x5_unorm, .astc_8x5_unorm_srgb },
    .{ .astc_8x6_unorm, .astc_8x6_unorm_srgb },
    .{ .astc_8x8_unorm, .astc_8x8_unorm_srgb },
    .{ .astc_10x5_unorm, .astc_10x5_unorm_srgb },
    .{ .astc_10x6_unorm, .astc_10x6_unorm_srgb },
    .{ .astc_10x8_unorm, .astc_10x8_unorm_srgb },
    .{ .astc_10x10_unorm, .astc_10x10_unorm_srgb },
    .{ .astc_12x10_unorm, .astc_12x10_unorm_srgb },
    .{ .astc_12x12_unorm, .astc_12x12_unorm_srgb },
};

fn mergeCaps(value: *Format, bits: u16) void {
    value.caps = @bitCast(@as(u16, @bitCast(value.caps)) | bits);
    if (value.caps.storage_read_write) {
        value.caps.storage_read_only = true;
        value.caps.storage_write_only = true;
    }
}

fn initialCapsAddedBy(
    out: *FormatTable,
    reason: UnsupportedReason,
    formats: []const FormatName,
    bits: u16,
) void {
    for (formats) |name| {
        const value = &out[computeCanonicalFormatIndex(name).?];
        if (reason == .supported) {
            mergeCaps(value, bits);
            value.unsupported_reason = .supported;
        } else if (@as(u16, @bitCast(value.caps)) == 0 and value.unsupported_reason == .supported) {
            value.unsupported_reason = reason;
        }
    }
}

fn addCaps(out: *FormatTable, formats: []const FormatName, bits: u16) void {
    std.debug.assert(bits != 0);
    for (formats) |name| {
        const value = &out[computeCanonicalFormatIndex(name).?];
        if (value.isSupported()) mergeCaps(value, bits);
    }
}

/// Ordered rules from `Format.cpp:246-403`. Excluded gates never alias a retained feature.
fn computeFormatCapabilities(enabled: features.FeaturesSet, out: *FormatTable) void {
    initialCapsAddedBy(out, .supported, &.{
        .r8_snorm, .rg8_snorm, .rg11_b10_ufloat, .rgb9_e5_ufloat,
    }, 0);
    initialCapsAddedBy(out, .supported, &.{
        .r8_unorm,  .rg8_unorm,  .rgba8_unorm_srgb, .bgra8_unorm,
        .r16_float, .rg16_float, .rgb10_a2_unorm,
    }, 0x87);
    initialCapsAddedBy(out, .supported, &.{.rgba8_snorm}, 0x18);
    initialCapsAddedBy(out, .supported, &.{.rgba8_unorm}, 0x9f);
    initialCapsAddedBy(out, .supported, &.{
        .r8_uint,   .r8_sint,   .r16_uint,      .r16_sint, .rg8_uint, .rg8_sint,
        .rg16_uint, .rg16_sint, .rgb10_a2_uint,
    }, 2);
    initialCapsAddedBy(out, .supported, &.{ .r32_uint, .r32_sint, .r32_float }, 0x3a);
    initialCapsAddedBy(out, .supported, &.{ .rgba8_uint, .rgba8_sint }, 0x1a);
    initialCapsAddedBy(out, .supported, &.{ .rg32_uint, .rg32_sint, .rg32_float }, 2);
    initialCapsAddedBy(out, .supported, &.{ .rgba16_uint, .rgba16_sint }, 0x1a);
    initialCapsAddedBy(out, .supported, &.{.rgba16_float}, 0x9e);
    initialCapsAddedBy(out, .supported, &.{ .rgba32_uint, .rgba32_sint, .rgba32_float }, 0x1a);
    initialCapsAddedBy(out, required(enabled, .y_cb_cr_vulkan_samplers), &.{.opaque_y_cb_cr_android}, 0);
    initialCapsAddedBy(
        out,
        required(enabled, .opaque_y_cb_cr_android_for_external_texture),
        &.{.opaque_y_cb_cr_android},
        0,
    );
    // Both zero-capability YCbCr gates can independently support the same row.
    if (enabled.isEnabled(.y_cb_cr_vulkan_samplers) or
        enabled.isEnabled(.opaque_y_cb_cr_android_for_external_texture))
    {
        out[computeCanonicalFormatIndex(.opaque_y_cb_cr_android).?].unsupported_reason = .supported;
    }
    initialCapsAddedBy(out, required(enabled, .core_features_and_limits), &.{.bgra8_unorm_srgb}, 0x87);
    if (enabled.isEnabled(.core_features_and_limits)) {
        addCaps(out, &.{
            .r8_uint,      .r8_sint,     .r16_uint,      .r16_sint,  .rg8_uint,   .rg8_sint,
            .rg16_uint,    .rg16_sint,   .rgb10_a2_uint, .r32_float, .rgba8_uint, .rgba8_sint,
            .rgba16_float, .rgba16_uint, .rgba16_sint,
        }, 1);
        addCaps(out, &.{ .rg32_uint, .rg32_sint, .rg32_float }, 0x18);
    }
    // Pixel-local-storage gates are absent from FeaturesSet; no retained name substitutes.
    if (enabled.isEnabled(.float32_blendable)) {
        addCaps(out, &.{ .r32_float, .rg32_float, .rgba32_float }, 0x80);
    }
    initialCapsAddedBy(out, required(enabled, .texture_formats_tier1), &.{
        .r16_unorm, .rg16_unorm, .rgba16_unorm, .r16_snorm, .rg16_snorm, .rgba16_snorm,
    }, 0x9b);
    if (enabled.isEnabled(.texture_formats_tier1)) {
        addCaps(out, &.{ .r8_snorm, .rg8_snorm, .rgba8_snorm }, 0x87);
        addCaps(out, &.{
            .r8_unorm,  .r8_snorm,   .r8_uint,       .r8_sint,        .rg8_unorm,       .rg8_snorm,
            .rg8_uint,  .rg8_sint,   .r16_uint,      .r16_sint,       .r16_float,       .rg16_uint,
            .rg16_sint, .rg16_float, .rgb10_a2_uint, .rgb10_a2_unorm, .rg11_b10_ufloat,
        }, 0x18);
    }
    if (enabled.isEnabled(.texture_formats_tier2)) {
        addCaps(out, &.{
            .r8_unorm,    .r8_uint,     .r8_sint,      .r16_uint,    .r16_sint,    .r16_float,
            .rgba8_unorm, .rgba8_uint,  .rgba8_sint,   .rgba16_uint, .rgba16_sint, .rgba16_float,
            .rgba32_uint, .rgba32_sint, .rgba32_float,
        }, 0x20);
    }
    if (enabled.isEnabled(.bgra8_unorm_storage)) {
        addCaps(out, &.{.bgra8_unorm}, 0x10);
    }
    if (enabled.isEnabled(.rg11b10_ufloat_renderable)) {
        addCaps(out, &.{.rg11_b10_ufloat}, 0x87);
    }
    initialCapsAddedBy(
        out,
        .{ .unavailable_feature = .unorm16_texture_formats },
        &.{ .r16_unorm, .rg16_unorm, .rgba16_unorm },
        7,
    );
}

comptime {
    std.debug.assert(@typeInfo(FormatName).@"enum".field_names.len == format_count + 1);
    std.debug.assert(color_rows.len == 44);
    std.debug.assert(compressed_rows.len == 52);
    std.debug.assert(multi_rows.len == 9);
    std.debug.assert(view_format_pairs.len == 23);
    const api_info = @typeInfo(api.TextureFormat).@"enum";
    for (api_info.field_names, api_info.field_values) |field_name, field_value| {
        std.debug.assert(@backingInt(@field(FormatName, field_name)) == field_value);
    }
    const sample_info = @typeInfo(SampleTypeBit).@"enum";
    for (sample_info.field_names, sample_info.field_values) |field_name, field_value| {
        if (field_value == 0) continue;
        const sample = @field(SampleType, field_name);
        std.debug.assert(field_value == @as(u8, 1) << @intCast(@backingInt(sample) - 2));
    }
    @setEvalBranchQuota(30000);
    // SAFETY: buildFormatTable initializes each slot, then writes all 109 canonical rows before the proof reads them.
    var proof: FormatTable = undefined;
    buildFormatTable(.{}, &proof);
    for (@typeInfo(FormatName).@"enum".field_values) |field_value| {
        const name: FormatName = @fromBackingInt(@intCast(field_value));
        if (name == .undefined_) continue;
        const index = computeCanonicalFormatIndex(name).?;
        std.debug.assert(proof[index].format == name);
        std.debug.assert(proof[index].index == index);
    }
}
test "format table contains every canonical row and retained API member" {
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    inline for (@typeInfo(FormatName).@"enum".field_values) |field_value| {
        const name: FormatName = @fromBackingInt(@intCast(field_value));
        if (name == .undefined_) continue;
        const index = computeCanonicalFormatIndex(name).?;
        try std.testing.expectEqual(name, table[index].format);
        try std.testing.expectEqual(index, table[index].index);
    }
    inline for (@typeInfo(api.TextureFormat).@"enum".field_values) |field_value| {
        const name: api.TextureFormat = @fromBackingInt(@intCast(field_value));
        try std.testing.expectEqual(name != .undefined_, computeFormatIndex(name) != null);
    }
    try std.testing.expectEqual(@as(usize, 109), table.len);
    const counts = shapeCounts(&table);
    try std.testing.expectEqual(@as(usize, 44), counts.color);
    try std.testing.expectEqual(@as(usize, 3), counts.depth);
    try std.testing.expectEqual(@as(usize, 1), counts.stencil);
    try std.testing.expectEqual(@as(usize, 14), counts.bc);
    try std.testing.expectEqual(@as(usize, 10), counts.etc2);
    try std.testing.expectEqual(@as(usize, 28), counts.astc);
    try std.testing.expectEqual(@as(usize, 9), counts.multi_aspect);
}

test "depth stencil selection rejects all and absent aspects" {
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    const combined = &table[computeFormatIndex(.depth24_plus_stencil8).?];
    try std.testing.expectEqual(@as(u32, 4), (try combined.getAspectInfo(.depth_only)).block.byte_size);
    try std.testing.expectEqual(@as(u32, 1), (try combined.getAspectInfo(.stencil_only)).block.byte_size);
    try std.testing.expectError(error.MultipleAspects, combined.getAspectInfo(.all));
    try std.testing.expectError(error.InvalidAspect, combined.getAspectInfo(.undefined_));
    const stencil = &table[computeFormatIndex(.stencil8).?];
    try std.testing.expectEqual(@as(u32, 1), (try stencil.getAspectInfo(.all)).block.byte_size);
    try std.testing.expectError(error.AspectNotPresent, stencil.getAspectInfo(.depth_only));
    try std.testing.expectEqual(@as(u8, 2), aspectCount(.stencil));
}

test "features gate capabilities without losing unsupported format facts" {
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    const bc_index = computeFormatIndex(.bc1_rgba_unorm).?;
    try std.testing.expect(!table[bc_index].isSupported());
    try std.testing.expectEqual(@as(u32, 8), table[bc_index].aspect_info[0].block.byte_size);
    try std.testing.expectEqual(@as(u32, 4), table[bc_index].aspect_info[0].block.width);
    try std.testing.expect(!table[computeFormatIndex(.rg11_b10_ufloat).?].caps.renderable);
    try std.testing.expect(!table[computeFormatIndex(.bgra8_unorm_srgb).?].isSupported());
    var enabled: features.FeaturesSet = .{};
    enabled.enable(.texture_compression_bc);
    enabled.enable(.rg11b10_ufloat_renderable);
    enabled.enable(.core_features_and_limits);
    enabled.enable(.float32_filterable);
    enabled.enable(.texture_formats_tier1);
    enabled.enable(.texture_formats_tier2);
    buildFormatTable(enabled, &table);
    try std.testing.expect(table[bc_index].isSupported());
    try std.testing.expect(table[computeFormatIndex(.rg11_b10_ufloat).?].caps.renderable);
    try std.testing.expect(table[computeFormatIndex(.r8_unorm).?].caps.storage_read_write);
    try std.testing.expect(table[computeFormatIndex(.r16_unorm).?].isSupported());
    try std.testing.expect(table[computeFormatIndex(.r32_float).?].aspect_info[0].supported_sample_types.float);
}

test "sRGB view families and asymmetric compressed geometry" {
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    for (view_format_pairs) |pair| {
        const linear = &table[computeCanonicalFormatIndex(pair[0]).?];
        const srgb = &table[computeCanonicalFormatIndex(pair[1]).?];
        try std.testing.expect(linear.copyCompatibleWith(srgb));
        try std.testing.expect(srgb.viewCompatibleWith(linear));
        try std.testing.expectEqual(pair[1], linear.base_view_format);
    }
    try std.testing.expect(!table[computeFormatIndex(.rgba8_unorm).?].copyCompatibleWith(
        &table[computeFormatIndex(.bgra8_unorm).?],
    ));
    const astc = &table[computeFormatIndex(.astc_10x5_unorm).?];
    try std.testing.expectEqual(@as(u32, 10), astc.aspect_info[0].block.width);
    try std.testing.expectEqual(@as(u32, 5), astc.aspect_info[0].block.height);
    try std.testing.expectEqual(@as(u32, 16), astc.aspect_info[0].block.byte_size);
}

test "planar metadata has explicit internal planes and API conversion errors" {
    var table: FormatTable = undefined;
    var enabled: features.FeaturesSet = .{};
    enabled.enable(.multi_planar_format_p210);
    buildFormatTable(enabled, &table);
    const planar = &table[computeCanonicalFormatIndex(.r10x6_bg10x6_biplanar422_unorm).?];
    try std.testing.expect(planar.isSupported());
    try std.testing.expect(planar.isMultiPlanar());
    try std.testing.expectEqual(TextureSubsampling.e422, planar.sub_sampling);
    try std.testing.expectEqual(@as(u32, 4), (try planar.getAspectInfoForAspect(.plane_1)).block.byte_size);
    try std.testing.expectError(error.AspectNotPresent, planar.getAspectInfoForAspect(.plane_2));
    try std.testing.expectError(error.MultipleAspects, planar.getAspectInfo(.all));
    try std.testing.expectError(error.UnrepresentableFormat, toApiFormat(planar.format));
    try std.testing.expectError(error.UndefinedSampleType, sampleTypeBit(.undefined_));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(try sampleTypeBit(.binding_not_used))));
}

test "sample type bits retain API positions and undefined is an error" {
    const info = @typeInfo(SampleTypeBit).@"enum";
    inline for (info.field_names, info.field_values) |field_name, field_value| {
        if (field_value != 0) {
            const sample = @field(SampleType, field_name);
            try std.testing.expectEqual(
                @as(u8, field_value),
                @as(u8, @bitCast(try sampleTypeBit(sample))),
            );
        }
    }
    try std.testing.expectError(error.UndefinedSampleType, sampleTypeBit(.undefined_));
}

test "aspect flags reject empty combined and absent masks" {
    try std.testing.expectError(error.InvalidAspect, aspectIndex(.none));
    try std.testing.expectError(error.MultipleAspects, aspectIndex(@fromBackingInt(@intCast(6))));
    try std.testing.expectEqual(@as(u8, 0), try aspectIndex(.combined_depth_stencil));
    try std.testing.expectEqual(@as(u8, 2), try aspectIndex(.plane_2));
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    const color = &table[computeFormatIndex(.rgba8_unorm).?];
    try std.testing.expectError(
        error.AspectNotPresent,
        color.getAspectInfoForAspect(.combined_depth_stencil),
    );
    try std.testing.expectError(error.AspectNotPresent, color.getAspectInfoForAspect(.plane_0));
    try std.testing.expect(color.hasAlphaChannel());
    try std.testing.expect(!color.hasDepthOrStencil());
    try std.testing.expect(table[computeFormatIndex(.rgba8_snorm).?].isSnorm());
    try std.testing.expect(!table[computeFormatIndex(.rgba16_snorm).?].isSnorm());
}

test "disabled reasons and independent zero capability gates remain precise" {
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    const bgra = &table[computeFormatIndex(.bgra8_unorm_srgb).?];
    try std.testing.expect(bgra.unsupported_reason == .compatibility_mode);
    const bc = table[computeFormatIndex(.bc1_rgba_unorm).?].unsupported_reason;
    try std.testing.expectEqual(features.Feature.texture_compression_bc, bc.requires_feature);
    const excluded = &table[computeCanonicalFormatIndex(.r8_bg8_biplanar420_unorm).?];
    try std.testing.expectEqual(
        UnavailableFeature.dawn_multi_planar_formats,
        excluded.unsupported_reason.unavailable_feature,
    );
    var enabled: features.FeaturesSet = .{};
    enabled.enable(.y_cb_cr_vulkan_samplers);
    buildFormatTable(enabled, &table);
    const opaque_index = computeCanonicalFormatIndex(.opaque_y_cb_cr_android).?;
    try std.testing.expect(table[opaque_index].isSupported());
    enabled = .{};
    enabled.enable(.opaque_y_cb_cr_android_for_external_texture);
    buildFormatTable(enabled, &table);
    const opaque_format = &table[opaque_index];
    try std.testing.expect(opaque_format.isSupported());
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(opaque_format.caps)));
}

test "diagnostics distinguish feature requirement compatibility and excluded gate" {
    var buffer: [128]u8 = undefined;
    const feature: UnsupportedReason = .{ .requires_feature = .texture_compression_bc };
    try std.testing.expectEqualStrings(
        "requires feature texture_compression_bc",
        try std.fmt.bufPrint(&buffer, "{f}", .{feature}),
    );
    const compatibility: UnsupportedReason = .compatibility_mode;
    try std.testing.expectEqualStrings(
        "not supported in compatibility mode",
        try std.fmt.bufPrint(&buffer, "{f}", .{compatibility}),
    );
    const excluded: UnsupportedReason = .{ .unavailable_feature = .multi_planar_format_p010 };
    try std.testing.expectEqualStrings(
        "requires excluded Dawn feature multi_planar_format_p010",
        try std.fmt.bufPrint(&buffer, "{f}", .{excluded}),
    );
}

test "API view compatibility uses each canonical row family" {
    var table: FormatTable = undefined;
    buildFormatTable(.{}, &table);
    for (view_format_pairs) |pair| {
        const linear = &table[computeCanonicalFormatIndex(pair[0]).?];
        const srgb = &table[computeCanonicalFormatIndex(pair[1]).?];
        const linear_api = try toApiFormat(pair[0]);
        const srgb_api = try toApiFormat(pair[1]);
        try std.testing.expect(linear.viewCompatibleWithApi(linear_api));
        try std.testing.expect(linear.viewCompatibleWithApi(srgb_api));
        try std.testing.expect(srgb.viewCompatibleWithApi(linear_api));
        try std.testing.expect(srgb.viewCompatibleWithApi(srgb_api));
        try std.testing.expect(!linear.viewCompatibleWithApi(.undefined_));
        try std.testing.expect(!srgb.viewCompatibleWithApi(.undefined_));
    }
    const rgba = &table[computeFormatIndex(.rgba8_unorm).?];
    try std.testing.expect(!rgba.viewCompatibleWithApi(.bgra8_unorm));
    const depth = &table[computeFormatIndex(.depth24_plus).?];
    try std.testing.expect(depth.viewCompatibleWithApi(.depth24_plus));
    try std.testing.expect(!depth.viewCompatibleWithApi(.depth32_float));
}
