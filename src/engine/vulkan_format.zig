//! The WebGPU-format to Vulkan-format mapping the replay needs.
//!
//! **What this file is.** `VulkanImageFormat` (`vulkan/TextureVk.cpp:567`),
//! `VulkanAttachmentLoadOp` and `VulkanAttachmentStoreOp`
//! (`vulkan/UtilsVulkan.cpp:170`, `:185`), `VulkanSampleCount`
//! (`vulkan/TextureVk.cpp:839`) and `VulkanImageLayoutForDepthStencilAttachment`
//! (`vulkan/TextureVk.cpp:822`). Those helpers share one table here.
//!
//! **What this file is not.** It is not the whole of `vulkan/UtilsVulkan.cpp`.
//! The sampling and copy conversions stay M9's; only the five above are here,
//! and only because the render-pass cache and the offscreen image cannot be
//! written without them.
//!
//! **What it does not claim.** It does not claim the toggle-selected variants.
//! `Depth24PlusStencil8` follows the `VulkanUseD32S8`-off branch
//! (`TextureVk.cpp:582`) and `Stencil8` the `VulkanUseS8`-on branch (`:592`),
//! because M7's toggle set is not a parameter of a pure function. A device
//! that enables either toggle needs a `vkFormat` that takes the toggle set; the
//! two arms say which.

const std = @import("std");

const vulkan = @import("vulkan");

const api = @import("../api/api.zig");
pub const TextureFormat = api.enums.TextureFormat;
pub const LoadOp = api.enums.LoadOp;
pub const StoreOp = api.enums.StoreOp;

/// The sample counts a render pass may declare
/// (`vulkan/TextureVk.cpp:839-847`). Anything else is a validation failure
/// upstream and is one here too.
pub const k_supported_sample_count = [_]u32{ 1, 4 };

/// What a depth-stencil attachment needs to resolve to one layout.
///
/// Aspect presence and access are independent. Ignore access flags for absent
/// aspects. At least one aspect must be present.
pub const DepthStencilLayout = struct {
    has_depth: bool,
    has_stencil: bool,
    depth_read_only: bool = false,
    stencil_read_only: bool = false,
};

/// The Vulkan format for a WebGPU format.
///
/// `translate-c` gives `enum_VkFormat` the underlying `c_uint` and every
/// `VK_FORMAT_*` constant the type `c_int`, so the widening happens once here
/// rather than at a hundred arms.
///
/// The switch has no `else`: a new upstream format is a compile error until it
/// is mapped. The two toggle arms and the census below are the only
/// places a format is not a fixed Vulkan name.
pub fn vkFormat(format: TextureFormat) vulkan.VkFormat {
    return @intCast(vulkanFormatValue(format));
}

fn vulkanFormatValue(format: TextureFormat) c_int {
    return switch (format) {
        .r8_unorm => vulkan.VK_FORMAT_R8_UNORM,
        .r8_snorm => vulkan.VK_FORMAT_R8_SNORM,
        .r8_uint => vulkan.VK_FORMAT_R8_UINT,
        .r8_sint => vulkan.VK_FORMAT_R8_SINT,

        .r16_unorm => vulkan.VK_FORMAT_R16_UNORM,
        .r16_snorm => vulkan.VK_FORMAT_R16_SNORM,
        .r16_uint => vulkan.VK_FORMAT_R16_UINT,
        .r16_sint => vulkan.VK_FORMAT_R16_SINT,
        .r16_float => vulkan.VK_FORMAT_R16_SFLOAT,
        .rg8_unorm => vulkan.VK_FORMAT_R8G8_UNORM,
        .rg8_snorm => vulkan.VK_FORMAT_R8G8_SNORM,
        .rg8_uint => vulkan.VK_FORMAT_R8G8_UINT,
        .rg8_sint => vulkan.VK_FORMAT_R8G8_SINT,

        .r32_uint => vulkan.VK_FORMAT_R32_UINT,
        .r32_sint => vulkan.VK_FORMAT_R32_SINT,
        .r32_float => vulkan.VK_FORMAT_R32_SFLOAT,
        .rg16_unorm => vulkan.VK_FORMAT_R16G16_UNORM,
        .rg16_snorm => vulkan.VK_FORMAT_R16G16_SNORM,
        .rg16_uint => vulkan.VK_FORMAT_R16G16_UINT,
        .rg16_sint => vulkan.VK_FORMAT_R16G16_SINT,
        .rg16_float => vulkan.VK_FORMAT_R16G16_SFLOAT,
        .rgba8_unorm => vulkan.VK_FORMAT_R8G8B8A8_UNORM,
        .rgba8_unorm_srgb => vulkan.VK_FORMAT_R8G8B8A8_SRGB,
        .rgba8_snorm => vulkan.VK_FORMAT_R8G8B8A8_SNORM,
        .rgba8_uint => vulkan.VK_FORMAT_R8G8B8A8_UINT,
        .rgba8_sint => vulkan.VK_FORMAT_R8G8B8A8_SINT,
        .bgra8_unorm => vulkan.VK_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => vulkan.VK_FORMAT_B8G8R8A8_SRGB,
        .rgb10_a2_uint => vulkan.VK_FORMAT_A2B10G10R10_UINT_PACK32,
        .rgb10_a2_unorm => vulkan.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        .rg11_b10_ufloat => vulkan.VK_FORMAT_B10G11R11_UFLOAT_PACK32,
        .rgb9_e5_ufloat => vulkan.VK_FORMAT_E5B9G9R9_UFLOAT_PACK32,

        .rg32_uint => vulkan.VK_FORMAT_R32G32_UINT,
        .rg32_sint => vulkan.VK_FORMAT_R32G32_SINT,
        .rg32_float => vulkan.VK_FORMAT_R32G32_SFLOAT,
        .rgba16_unorm => vulkan.VK_FORMAT_R16G16B16A16_UNORM,
        .rgba16_snorm => vulkan.VK_FORMAT_R16G16B16A16_SNORM,
        .rgba16_uint => vulkan.VK_FORMAT_R16G16B16A16_UINT,
        .rgba16_sint => vulkan.VK_FORMAT_R16G16B16A16_SINT,
        .rgba16_float => vulkan.VK_FORMAT_R16G16B16A16_SFLOAT,

        .rgba32_uint => vulkan.VK_FORMAT_R32G32B32A32_UINT,
        .rgba32_sint => vulkan.VK_FORMAT_R32G32B32A32_SINT,
        .rgba32_float => vulkan.VK_FORMAT_R32G32B32A32_SFLOAT,

        // `TextureVk.cpp:585-586` maps `Depth24Plus` to the 32-bit float depth
        // format and not to `D24_UNORM_S8_UINT`: a `depth24plus` attachment
        // carries no stencil to pair with.
        .depth24_plus => vulkan.VK_FORMAT_D32_SFLOAT,
        .depth32_float_stencil8 => vulkan.VK_FORMAT_D32_SFLOAT_S8_UINT,
        // Toggle-selected upstream (`TextureVk.cpp:574-583`, `:588-595`). The
        // first arm is the `VulkanUseD32S8`-off branch, the second the
        // `VulkanUseS8`-on branch; enabling either toggle changes that arm.
        .depth24_plus_stencil8 => vulkan.VK_FORMAT_D24_UNORM_S8_UINT,
        .stencil8 => vulkan.VK_FORMAT_S8_UINT,
        .depth16_unorm => vulkan.VK_FORMAT_D16_UNORM,
        .depth32_float => vulkan.VK_FORMAT_D32_SFLOAT,

        .bc1_rgba_unorm => vulkan.VK_FORMAT_BC1_RGBA_UNORM_BLOCK,
        .bc1_rgba_unorm_srgb => vulkan.VK_FORMAT_BC1_RGBA_SRGB_BLOCK,
        .bc2_rgba_unorm => vulkan.VK_FORMAT_BC2_UNORM_BLOCK,
        .bc2_rgba_unorm_srgb => vulkan.VK_FORMAT_BC2_SRGB_BLOCK,
        .bc3_rgba_unorm => vulkan.VK_FORMAT_BC3_UNORM_BLOCK,
        .bc3_rgba_unorm_srgb => vulkan.VK_FORMAT_BC3_SRGB_BLOCK,
        .bc4_r_unorm => vulkan.VK_FORMAT_BC4_UNORM_BLOCK,
        .bc4_r_snorm => vulkan.VK_FORMAT_BC4_SNORM_BLOCK,
        .bc5_rg_unorm => vulkan.VK_FORMAT_BC5_UNORM_BLOCK,
        .bc5_rg_snorm => vulkan.VK_FORMAT_BC5_SNORM_BLOCK,
        .bc6h_rgb_ufloat => vulkan.VK_FORMAT_BC6H_UFLOAT_BLOCK,
        .bc6h_rgb_float => vulkan.VK_FORMAT_BC6H_SFLOAT_BLOCK,
        .bc7_rgba_unorm => vulkan.VK_FORMAT_BC7_UNORM_BLOCK,
        .bc7_rgba_unorm_srgb => vulkan.VK_FORMAT_BC7_SRGB_BLOCK,

        .etc2_rgb8_unorm => vulkan.VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK,
        .etc2_rgb8_unorm_srgb => vulkan.VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK,
        .etc2_rgb8a1_unorm => vulkan.VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK,
        .etc2_rgb8a1_unorm_srgb => vulkan.VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK,
        .etc2_rgba8_unorm => vulkan.VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK,
        .etc2_rgba8_unorm_srgb => vulkan.VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK,
        .eac_r11_unorm => vulkan.VK_FORMAT_EAC_R11_UNORM_BLOCK,
        .eac_r11_snorm => vulkan.VK_FORMAT_EAC_R11_SNORM_BLOCK,
        .eac_rg11_unorm => vulkan.VK_FORMAT_EAC_R11G11_UNORM_BLOCK,
        .eac_rg11_snorm => vulkan.VK_FORMAT_EAC_R11G11_SNORM_BLOCK,

        .astc_4x4_unorm => vulkan.VK_FORMAT_ASTC_4x4_UNORM_BLOCK,
        .astc_4x4_unorm_srgb => vulkan.VK_FORMAT_ASTC_4x4_SRGB_BLOCK,
        .astc_5x4_unorm => vulkan.VK_FORMAT_ASTC_5x4_UNORM_BLOCK,
        .astc_5x4_unorm_srgb => vulkan.VK_FORMAT_ASTC_5x4_SRGB_BLOCK,
        .astc_5x5_unorm => vulkan.VK_FORMAT_ASTC_5x5_UNORM_BLOCK,
        .astc_5x5_unorm_srgb => vulkan.VK_FORMAT_ASTC_5x5_SRGB_BLOCK,
        .astc_6x5_unorm => vulkan.VK_FORMAT_ASTC_6x5_UNORM_BLOCK,
        .astc_6x5_unorm_srgb => vulkan.VK_FORMAT_ASTC_6x5_SRGB_BLOCK,
        .astc_6x6_unorm => vulkan.VK_FORMAT_ASTC_6x6_UNORM_BLOCK,
        .astc_6x6_unorm_srgb => vulkan.VK_FORMAT_ASTC_6x6_SRGB_BLOCK,
        .astc_8x5_unorm => vulkan.VK_FORMAT_ASTC_8x5_UNORM_BLOCK,
        .astc_8x5_unorm_srgb => vulkan.VK_FORMAT_ASTC_8x5_SRGB_BLOCK,
        .astc_8x6_unorm => vulkan.VK_FORMAT_ASTC_8x6_UNORM_BLOCK,
        .astc_8x6_unorm_srgb => vulkan.VK_FORMAT_ASTC_8x6_SRGB_BLOCK,
        .astc_8x8_unorm => vulkan.VK_FORMAT_ASTC_8x8_UNORM_BLOCK,
        .astc_8x8_unorm_srgb => vulkan.VK_FORMAT_ASTC_8x8_SRGB_BLOCK,
        .astc_10x5_unorm => vulkan.VK_FORMAT_ASTC_10x5_UNORM_BLOCK,
        .astc_10x5_unorm_srgb => vulkan.VK_FORMAT_ASTC_10x5_SRGB_BLOCK,
        .astc_10x6_unorm => vulkan.VK_FORMAT_ASTC_10x6_UNORM_BLOCK,
        .astc_10x6_unorm_srgb => vulkan.VK_FORMAT_ASTC_10x6_SRGB_BLOCK,
        .astc_10x8_unorm => vulkan.VK_FORMAT_ASTC_10x8_UNORM_BLOCK,
        .astc_10x8_unorm_srgb => vulkan.VK_FORMAT_ASTC_10x8_SRGB_BLOCK,
        .astc_10x10_unorm => vulkan.VK_FORMAT_ASTC_10x10_UNORM_BLOCK,
        .astc_10x10_unorm_srgb => vulkan.VK_FORMAT_ASTC_10x10_SRGB_BLOCK,
        .astc_12x10_unorm => vulkan.VK_FORMAT_ASTC_12x10_UNORM_BLOCK,
        .astc_12x10_unorm_srgb => vulkan.VK_FORMAT_ASTC_12x10_SRGB_BLOCK,
        .astc_12x12_unorm => vulkan.VK_FORMAT_ASTC_12x12_UNORM_BLOCK,
        .astc_12x12_unorm_srgb => vulkan.VK_FORMAT_ASTC_12x12_SRGB_BLOCK,

        // Dawn returns `VK_FORMAT_UNDEFINED` here for `OpaqueYCbCrAndroid`
        // (`TextureVk.cpp:597-600`). The generated enum dropped that format and
        // the multiplanar ones (see the dropped-value notes at
        // `src/api/enums.zig:872-879`), so no tag reaches that branch and the
        // arm says so rather than guessing a Vulkan format for `undefined_`.
        .undefined_ => unreachable,
    };
}

/// The attachment load op for a recorded load op
/// (`vulkan/UtilsVulkan.cpp:170-183`).
///
/// `undefined_` is `unreachable` and not `DONT_CARE`: the front end resolves
/// `LoadOp::Undefined` before the back end sees it (`ActualLoadOpIfUndefined`,
/// `native/CommandEncoder.cpp:643-653`), and a replay reading an unresolved op
/// is reading a state the front end has already promised cannot exist.
pub fn attachmentLoadOp(op: LoadOp) vulkan.VkAttachmentLoadOp {
    const value: c_int = switch (op) {
        .load => vulkan.VK_ATTACHMENT_LOAD_OP_LOAD,
        .clear => vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .expand_resolve_texture => vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .undefined_ => unreachable,
    };
    return @intCast(value);
}

/// The attachment store op for a recorded store op
/// (`vulkan/UtilsVulkan.cpp:185-198`). Dawn keeps `STORE_OP_STORE_NONE_QCOM`
/// behind a TODO (`:186-187`); the port has no such extension and returns the
/// core `DONT_CARE`.
pub fn attachmentStoreOp(op: StoreOp) vulkan.VkAttachmentStoreOp {
    const value: c_int = switch (op) {
        .store => vulkan.VK_ATTACHMENT_STORE_OP_STORE,
        .discard => vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .undefined_ => unreachable,
    };
    return @intCast(value);
}

/// The sample-count bit for a sample count (`vulkan/TextureVk.cpp:839-847`).
/// A count outside the supported pair is a validation failure upstream and
/// `error.SampleCountNotSupported` here.
pub fn vkSampleCount(sample_count: u32) SampleCountError!vulkan.VkSampleCountFlagBits {
    for (k_supported_sample_count) |supported| {
        if (supported != sample_count) continue;
        const value: c_int = switch (sample_count) {
            1 => vulkan.VK_SAMPLE_COUNT_1_BIT,
            4 => vulkan.VK_SAMPLE_COUNT_4_BIT,
            else => unreachable,
        };
        return @intCast(value);
    }
    return error.SampleCountNotSupported;
}

pub const SampleCountError = error{SampleCountNotSupported};

/// The layout a depth-stencil attachment is in for one pass
/// (`vulkan/TextureVk.cpp:822-837`).
///
/// The device does not enable `separateDepthStencilLayouts`. Single-aspect
/// images therefore use combined layouts too. Mixed access uses Vulkan 1.1
/// layouts, which do not require that feature.
pub fn vkImageLayoutForDepthStencilAttachment(options: DepthStencilLayout) vulkan.VkImageLayout {
    std.debug.assert(options.has_depth or options.has_stencil);
    if (options.has_depth and options.has_stencil) {
        if (options.depth_read_only) {
            return @intCast(if (options.stencil_read_only)
                vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
            else
                vulkan.VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_STENCIL_ATTACHMENT_OPTIMAL);
        }
        return @intCast(if (options.stencil_read_only)
            vulkan.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_STENCIL_READ_ONLY_OPTIMAL
        else
            vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
    }
    const read_only = if (options.has_depth)
        options.depth_read_only
    else
        options.stencil_read_only;
    return @intCast(if (read_only)
        vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
    else
        vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
}

comptime {
    // Every tag but `undefined_` maps to a Vulkan format that is not
    // `VK_FORMAT_UNDEFINED`. An arm that fell through to the undefined value
    // would otherwise compile and produce an image no driver can create, and
    // the failure would name a driver rather than this line.
    for (@typeInfo(TextureFormat).@"enum".field_values) |field_value| {
        const format: TextureFormat = @fromBackingInt(@intCast(field_value));
        if (format == .undefined_) continue;
        if (vkFormat(format) == @as(vulkan.VkFormat, @intCast(vulkan.VK_FORMAT_UNDEFINED))) {
            @compileError("a texture format maps to VK_FORMAT_UNDEFINED: " ++ @tagName(format));
        }
    }
    // The two toggle arms above are the only non-fixed mappings, so the count
    // of supported sample counts and the arms of `vkSampleCount` agree.
    if (k_supported_sample_count.len != 2) {
        @compileError("vkSampleCount names one bit per supported sample count");
    }
}

test "depth-only attachment layouts ignore absent stencil read-only state" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |stencil_read_only| {
        for ([_]bool{ false, true }) |depth_read_only| {
            const expected: vulkan.VkImageLayout = @intCast(if (depth_read_only)
                vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
            else
                vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
            try testing.expectEqual(expected, vkImageLayoutForDepthStencilAttachment(.{
                .has_depth = true,
                .has_stencil = false,
                .depth_read_only = depth_read_only,
                .stencil_read_only = stencil_read_only,
            }));
        }
    }
}

test "stencil-only attachment layouts ignore absent depth read-only state" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |depth_read_only| {
        for ([_]bool{ false, true }) |stencil_read_only| {
            const expected: vulkan.VkImageLayout = @intCast(if (stencil_read_only)
                vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
            else
                vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
            try testing.expectEqual(expected, vkImageLayoutForDepthStencilAttachment(.{
                .has_depth = false,
                .has_stencil = true,
                .depth_read_only = depth_read_only,
                .stencil_read_only = stencil_read_only,
            }));
        }
    }
}

test "combined depth stencil attachment layouts preserve matching read-only states" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |read_only| {
        const expected: vulkan.VkImageLayout = @intCast(if (read_only)
            vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
        else
            vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
        try testing.expectEqual(expected, vkImageLayoutForDepthStencilAttachment(.{
            .has_depth = true,
            .has_stencil = true,
            .depth_read_only = read_only,
            .stencil_read_only = read_only,
        }));
    }
}

test "combined depth read-only stencil writable attachment uses Vulkan 1.1 layout" {
    try std.testing.expectEqual(
        @as(vulkan.VkImageLayout, @intCast(
            vulkan.VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_STENCIL_ATTACHMENT_OPTIMAL,
        )),
        vkImageLayoutForDepthStencilAttachment(.{
            .has_depth = true,
            .has_stencil = true,
            .depth_read_only = true,
            .stencil_read_only = false,
        }),
    );
}

test "combined depth writable stencil read-only attachment uses Vulkan 1.1 layout" {
    try std.testing.expectEqual(
        @as(vulkan.VkImageLayout, @intCast(
            vulkan.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_STENCIL_READ_ONLY_OPTIMAL,
        )),
        vkImageLayoutForDepthStencilAttachment(.{
            .has_depth = true,
            .has_stencil = true,
            .depth_read_only = false,
            .stencil_read_only = true,
        }),
    );
}
