//! Immutable Vulkan format facts and tightly packed upload geometry.
//! Format recognition does not establish device support, enabled extensions, or image limits.

const std = @import("std");
const vk = @import("vulkan");

pub const FormatError = error{TextureYCbCrFormatInvalid};

pub const Error = FormatError || error{
    TextureYCbCrExtentInvalid,
    TextureYCbCrPlaneIndexInvalid,
    TextureYCbCrSizeOverflow,
};

/// These are physical layout facts. The caller must query support for the selected image.
pub const Traits = struct {
    vk_format: vk.VkFormat,
    plane_count: u32,
    /// Largest component precision. The array preserves mixed packed component precisions.
    component_bits: u8,
    component_bits_by_channel: [4]u8,
    subsample_x: u32,
    subsample_y: u32,
    /// One for scalar texels, two for single-plane packed 422 blocks.
    packed_block_width: u32,
    /// Bytes per compatible plane texel, or per packed block. Unused entries are zero.
    plane_element_bytes: [3]u8,
    /// Unused entries are VK_FORMAT_UNDEFINED.
    plane_compatible_formats: [3]vk.VkFormat,
};

pub const PlaneOptions = struct {
    /// Full-image base extent, not an already subsampled plane extent.
    width: u32,
    height: u32,
    plane_index: u32,
};

pub const PlaneGeometry = struct {
    /// Plane copy extent in texels. Packed 422 retains the full image width.
    width: u32,
    height: u32,
    byte_size: u64,
    row_byte_size: u64,
    aspect: vk.VkImageAspectFlags,
    element_bytes: u8,
    block_width: u32,
};

/// Recognizes the UNORM formats accepted by the native sampler conversion format mapping.
/// Recognition is independent of the API version and enabled extension set.
pub fn traitsFor(format: vk.VkFormat) FormatError!Traits {
    if (format >= vk.VK_FORMAT_G8B8G8R8_422_UNORM and
        format <= vk.VK_FORMAT_G16_B16_R16_3PLANE_444_UNORM)
    {
        const index = format - vk.VK_FORMAT_G8B8G8R8_422_UNORM;
        const bits: u8 = if (index < 7) 8 else if (index < 17) 10 else if (index < 27) 12 else 16;
        return switch (index) {
            0, 1, 10, 11, 20, 21, 27, 28 => singlePlane(format, .{
                .component_bits = .{ bits, bits, bits, 0 },
                .element_bytes = if (bits == 8) 4 else 8,
                .subsample_x = 2,
                .block_width = 2,
            }),
            2, 12, 22, 29 => multiplePlanes(format, .{
                .bits = bits,
                .plane_count = 3,
                .subsample_x = 2,
                .subsample_y = 2,
            }),
            3, 13, 23, 30 => multiplePlanes(format, .{
                .bits = bits,
                .plane_count = 2,
                .subsample_x = 2,
                .subsample_y = 2,
            }),
            4, 14, 24, 31 => multiplePlanes(format, .{
                .bits = bits,
                .plane_count = 3,
                .subsample_x = 2,
                .subsample_y = 1,
            }),
            5, 15, 25, 32 => multiplePlanes(format, .{
                .bits = bits,
                .plane_count = 2,
                .subsample_x = 2,
                .subsample_y = 1,
            }),
            6, 16, 26, 33 => multiplePlanes(format, .{
                .bits = bits,
                .plane_count = 3,
                .subsample_x = 1,
                .subsample_y = 1,
            }),
            7, 17 => singlePlane(format, .{
                .component_bits = .{ bits, 0, 0, 0 },
                .element_bytes = 2,
            }),
            8, 18 => singlePlane(format, .{
                .component_bits = .{ bits, bits, 0, 0 },
                .element_bytes = 4,
            }),
            9, 19 => singlePlane(format, .{
                .component_bits = .{ bits, bits, bits, bits },
                .element_bytes = 8,
            }),
            else => error.TextureYCbCrFormatInvalid,
        };
    }
    if (format >= vk.VK_FORMAT_G8_B8R8_2PLANE_444_UNORM and
        format <= vk.VK_FORMAT_G16_B16R16_2PLANE_444_UNORM)
    {
        const bits: u8 = switch (format - vk.VK_FORMAT_G8_B8R8_2PLANE_444_UNORM) {
            0 => 8,
            1 => 10,
            2 => 12,
            3 => 16,
            else => return error.TextureYCbCrFormatInvalid,
        };
        return multiplePlanes(format, .{
            .bits = bits,
            .plane_count = 2,
            .subsample_x = 1,
            .subsample_y = 1,
        });
    }
    return switch (format) {
        vk.VK_FORMAT_R4G4_UNORM_PACK8 => singlePlane(format, .{
            .component_bits = .{ 4, 4, 0, 0 },
            .element_bytes = 1,
        }),
        vk.VK_FORMAT_R4G4B4A4_UNORM_PACK16,
        vk.VK_FORMAT_B4G4R4A4_UNORM_PACK16,
        => singlePlane(format, .{
            .component_bits = .{ 4, 4, 4, 4 },
            .element_bytes = 2,
        }),
        vk.VK_FORMAT_R5G6B5_UNORM_PACK16,
        vk.VK_FORMAT_B5G6R5_UNORM_PACK16,
        => singlePlane(format, .{
            .component_bits = .{ 5, 6, 5, 0 },
            .element_bytes = 2,
        }),
        vk.VK_FORMAT_R5G5B5A1_UNORM_PACK16,
        vk.VK_FORMAT_B5G5R5A1_UNORM_PACK16,
        vk.VK_FORMAT_A1R5G5B5_UNORM_PACK16,
        => singlePlane(format, .{
            .component_bits = .{ 5, 5, 5, 1 },
            .element_bytes = 2,
        }),
        vk.VK_FORMAT_R8_UNORM => singlePlane(format, .{
            .component_bits = .{ 8, 0, 0, 0 },
            .element_bytes = 1,
        }),
        vk.VK_FORMAT_R8G8_UNORM => singlePlane(format, .{
            .component_bits = .{ 8, 8, 0, 0 },
            .element_bytes = 2,
        }),
        vk.VK_FORMAT_R8G8B8_UNORM,
        vk.VK_FORMAT_B8G8R8_UNORM,
        => singlePlane(format, .{
            .component_bits = .{ 8, 8, 8, 0 },
            .element_bytes = 3,
        }),
        vk.VK_FORMAT_R8G8B8A8_UNORM,
        vk.VK_FORMAT_B8G8R8A8_UNORM,
        vk.VK_FORMAT_A8B8G8R8_UNORM_PACK32,
        => singlePlane(format, .{
            .component_bits = .{ 8, 8, 8, 8 },
            .element_bytes = 4,
        }),
        vk.VK_FORMAT_A2R10G10B10_UNORM_PACK32,
        vk.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        => singlePlane(format, .{
            .component_bits = .{ 10, 10, 10, 2 },
            .element_bytes = 4,
        }),
        vk.VK_FORMAT_R16_UNORM => singlePlane(format, .{
            .component_bits = .{ 16, 0, 0, 0 },
            .element_bytes = 2,
        }),
        vk.VK_FORMAT_R16G16_UNORM => singlePlane(format, .{
            .component_bits = .{ 16, 16, 0, 0 },
            .element_bytes = 4,
        }),
        vk.VK_FORMAT_R16G16B16_UNORM => singlePlane(format, .{
            .component_bits = .{ 16, 16, 16, 0 },
            .element_bytes = 6,
        }),
        vk.VK_FORMAT_R16G16B16A16_UNORM => singlePlane(format, .{
            .component_bits = .{ 16, 16, 16, 16 },
            .element_bytes = 8,
        }),
        else => error.TextureYCbCrFormatInvalid,
    };
}

/// Computes one complete tightly packed upload plane, with no row padding or layer stride.
/// Vulkan subsampled base-image extents must be exact multiples of the subsampling factors.
pub fn planeGeometry(format: vk.VkFormat, options: PlaneOptions) Error!PlaneGeometry {
    const traits = try traitsFor(format);
    if (options.plane_index >= traits.plane_count) {
        return error.TextureYCbCrPlaneIndexInvalid;
    }
    if (options.width == 0 or options.height == 0) return error.TextureYCbCrExtentInvalid;
    if (options.width % traits.subsample_x != 0) return error.TextureYCbCrExtentInvalid;
    if (options.height % traits.subsample_y != 0) return error.TextureYCbCrExtentInvalid;
    const width = if (options.plane_index == 0)
        options.width
    else
        @divExact(options.width, traits.subsample_x);
    const height = if (options.plane_index == 0)
        options.height
    else
        @divExact(options.height, traits.subsample_y);
    const block_width = traits.packed_block_width;
    const element_bytes = traits.plane_element_bytes[options.plane_index];
    const block_count_x: u64 = @divExact(width, block_width);
    const row_byte_size = std.math.mul(u64, block_count_x, element_bytes) catch
        return error.TextureYCbCrSizeOverflow;
    const byte_size = std.math.mul(u64, row_byte_size, height) catch
        return error.TextureYCbCrSizeOverflow;
    const aspects = [_]vk.VkImageAspectFlags{
        vk.VK_IMAGE_ASPECT_PLANE_0_BIT,
        vk.VK_IMAGE_ASPECT_PLANE_1_BIT,
        vk.VK_IMAGE_ASPECT_PLANE_2_BIT,
    };
    return .{
        .width = width,
        .height = height,
        .byte_size = byte_size,
        .row_byte_size = row_byte_size,
        .aspect = if (traits.plane_count == 1)
            vk.VK_IMAGE_ASPECT_COLOR_BIT
        else
            aspects[options.plane_index],
        .element_bytes = element_bytes,
        .block_width = block_width,
    };
}

const SinglePlaneOptions = struct {
    component_bits: [4]u8,
    element_bytes: u8,
    subsample_x: u32 = 1,
    block_width: u32 = 1,
};

fn singlePlane(format: vk.VkFormat, options: SinglePlaneOptions) Traits {
    return .{
        .vk_format = format,
        .plane_count = 1,
        .component_bits = @max(options.component_bits[0], options.component_bits[1], options.component_bits[2], options.component_bits[3]),
        .component_bits_by_channel = options.component_bits,
        .subsample_x = options.subsample_x,
        .subsample_y = 1,
        .packed_block_width = options.block_width,
        .plane_element_bytes = .{ options.element_bytes, 0, 0 },
        .plane_compatible_formats = .{ format, vk.VK_FORMAT_UNDEFINED, vk.VK_FORMAT_UNDEFINED },
    };
}

const MultiplePlaneOptions = struct {
    bits: u8,
    plane_count: u32,
    subsample_x: u32,
    subsample_y: u32,
};

fn multiplePlanes(format: vk.VkFormat, options: MultiplePlaneOptions) Traits {
    const compatible: [2]vk.VkFormat = switch (options.bits) {
        8 => .{ vk.VK_FORMAT_R8_UNORM, vk.VK_FORMAT_R8G8_UNORM },
        10 => .{ vk.VK_FORMAT_R10X6_UNORM_PACK16, vk.VK_FORMAT_R10X6G10X6_UNORM_2PACK16 },
        12 => .{ vk.VK_FORMAT_R12X4_UNORM_PACK16, vk.VK_FORMAT_R12X4G12X4_UNORM_2PACK16 },
        16 => .{ vk.VK_FORMAT_R16_UNORM, vk.VK_FORMAT_R16G16_UNORM },
        // Only the four fixed bit depths above call this private helper.
        else => unreachable,
    };
    const scalar_bytes: u8 = if (options.bits == 8) 1 else 2;
    const two_planes = options.plane_count == 2;
    return .{
        .vk_format = format,
        .plane_count = options.plane_count,
        .component_bits = options.bits,
        .component_bits_by_channel = .{ options.bits, options.bits, options.bits, 0 },
        .subsample_x = options.subsample_x,
        .subsample_y = options.subsample_y,
        .packed_block_width = 1,
        .plane_element_bytes = .{
            scalar_bytes,
            if (two_planes) scalar_bytes * 2 else scalar_bytes,
            if (two_planes) 0 else scalar_bytes,
        },
        .plane_compatible_formats = .{
            compatible[0],
            if (two_planes) compatible[1] else compatible[0],
            if (two_planes) vk.VK_FORMAT_UNDEFINED else compatible[0],
        },
    };
}

test "NV12 4x4 upload uses 16 luma bytes and 8 chroma bytes" {
    const format = vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
    const luma = try planeGeometry(format, .{ .width = 4, .height = 4, .plane_index = 0 });
    const chroma = try planeGeometry(format, .{ .width = 4, .height = 4, .plane_index = 1 });
    try std.testing.expectEqual(@as(u64, 16), luma.byte_size);
    try std.testing.expectEqual(@as(u32, 4), luma.width);
    try std.testing.expectEqual(@as(u32, 4), luma.height);
    try std.testing.expectEqual(@as(u32, vk.VK_IMAGE_ASPECT_PLANE_0_BIT), luma.aspect);
    try std.testing.expectEqual(@as(u64, 8), chroma.byte_size);
    try std.testing.expectEqual(@as(u32, 2), chroma.width);
    try std.testing.expectEqual(@as(u32, 2), chroma.height);
    try std.testing.expectEqual(@as(u32, vk.VK_IMAGE_ASPECT_PLANE_1_BIT), chroma.aspect);
    const traits = try traitsFor(format);
    try std.testing.expectEqual(@as(u8, 1), traits.plane_element_bytes[0]);
    try std.testing.expectEqual(@as(u8, 2), traits.plane_element_bytes[1]);
    try std.testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_R8G8_UNORM), traits.plane_compatible_formats[1]);
}

test "P010 4x4 components occupy 16-bit containers" {
    const format = vk.VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
    const luma = try planeGeometry(format, .{ .width = 4, .height = 4, .plane_index = 0 });
    const chroma = try planeGeometry(format, .{ .width = 4, .height = 4, .plane_index = 1 });
    try std.testing.expectEqual(@as(u64, 32), luma.byte_size);
    try std.testing.expectEqual(@as(u64, 16), chroma.byte_size);
    const traits = try traitsFor(format);
    try std.testing.expectEqual(@as(u8, 10), traits.component_bits);
    try std.testing.expectEqual(@as(u8, 2), traits.plane_element_bytes[0]);
    try std.testing.expectEqual(@as(u8, 4), traits.plane_element_bytes[1]);
    try std.testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_R10X6G10X6_UNORM_2PACK16), traits.plane_compatible_formats[1]);
}

test "packed 422 copies color texels and counts two-texel blocks" {
    const formats = [_]vk.VkFormat{
        vk.VK_FORMAT_G8B8G8R8_422_UNORM,
        vk.VK_FORMAT_B8G8R8G8_422_UNORM,
        vk.VK_FORMAT_G10X6B10X6G10X6R10X6_422_UNORM_4PACK16,
        vk.VK_FORMAT_B12X4G12X4R12X4G12X4_422_UNORM_4PACK16,
        vk.VK_FORMAT_G16B16G16R16_422_UNORM,
    };
    for (formats, 0..) |format, index| {
        const plane = try planeGeometry(format, .{ .width = 4, .height = 3, .plane_index = 0 });
        const expected_bytes: u64 = if (index < 2) 24 else 48;
        try std.testing.expectEqual(expected_bytes, plane.byte_size);
        try std.testing.expectEqual(@as(u32, 4), plane.width);
        try std.testing.expectEqual(@as(u32, 3), plane.height);
        try std.testing.expectEqual(@as(u32, 2), plane.block_width);
        try std.testing.expectEqual(@as(u32, vk.VK_IMAGE_ASPECT_COLOR_BIT), plane.aspect);
    }
}

test "three-plane 420 and 422 have separate scalar chroma planes" {
    const planar_420 = vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM;
    const cb = try planeGeometry(planar_420, .{ .width = 4, .height = 4, .plane_index = 1 });
    const cr = try planeGeometry(planar_420, .{ .width = 4, .height = 4, .plane_index = 2 });
    try std.testing.expectEqual(@as(u64, 4), cb.byte_size);
    try std.testing.expectEqual(@as(u64, 4), cr.byte_size);
    try std.testing.expectEqual(@as(u32, vk.VK_IMAGE_ASPECT_PLANE_2_BIT), cr.aspect);
    const planar_422 = vk.VK_FORMAT_G16_B16_R16_3PLANE_422_UNORM;
    const plane = try planeGeometry(planar_422, .{ .width = 4, .height = 3, .plane_index = 2 });
    try std.testing.expectEqual(@as(u32, 2), plane.width);
    try std.testing.expectEqual(@as(u32, 3), plane.height);
    try std.testing.expectEqual(@as(u64, 12), plane.byte_size);
}

test "two-plane 444 preserves odd dimensions" {
    const formats = [_]vk.VkFormat{
        vk.VK_FORMAT_G8_B8R8_2PLANE_444_UNORM,
        vk.VK_FORMAT_G10X6_B10X6R10X6_2PLANE_444_UNORM_3PACK16,
        vk.VK_FORMAT_G12X4_B12X4R12X4_2PLANE_444_UNORM_3PACK16,
        vk.VK_FORMAT_G16_B16R16_2PLANE_444_UNORM,
    };
    for (formats, 0..) |format, index| {
        const plane = try planeGeometry(format, .{ .width = 3, .height = 5, .plane_index = 1 });
        try std.testing.expectEqual(@as(u32, 3), plane.width);
        try std.testing.expectEqual(@as(u32, 5), plane.height);
        try std.testing.expectEqual(@as(u64, if (index == 0) 30 else 60), plane.byte_size);
    }
}

test "subsampled image creation rejects odd full-image extents" {
    const planar_420 = vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
    try std.testing.expectError(error.TextureYCbCrExtentInvalid, planeGeometry(planar_420, .{ .width = 3, .height = 4, .plane_index = 0 }));
    try std.testing.expectError(error.TextureYCbCrExtentInvalid, planeGeometry(planar_420, .{ .width = 4, .height = 3, .plane_index = 1 }));
    try std.testing.expectError(error.TextureYCbCrExtentInvalid, planeGeometry(vk.VK_FORMAT_G8B8G8R8_422_UNORM, .{ .width = 3, .height = 3, .plane_index = 0 }));
    try std.testing.expectError(error.TextureYCbCrExtentInvalid, planeGeometry(planar_420, .{ .width = 0, .height = 4, .plane_index = 0 }));
    try std.testing.expectError(error.TextureYCbCrExtentInvalid, planeGeometry(planar_420, .{ .width = 4, .height = 0, .plane_index = 0 }));
}

test "geometry rejects invalid format and plane indices" {
    try std.testing.expectError(error.TextureYCbCrFormatInvalid, traitsFor(vk.VK_FORMAT_UNDEFINED));
    try std.testing.expectError(error.TextureYCbCrFormatInvalid, traitsFor(vk.VK_FORMAT_R8_UINT));
    try std.testing.expectError(error.TextureYCbCrFormatInvalid, planeGeometry(vk.VK_FORMAT_UNDEFINED, .{ .width = 4, .height = 4, .plane_index = 0 }));
    try std.testing.expectError(error.TextureYCbCrPlaneIndexInvalid, planeGeometry(vk.VK_FORMAT_R8_UNORM, .{ .width = 4, .height = 4, .plane_index = 1 }));
    try std.testing.expectError(error.TextureYCbCrPlaneIndexInvalid, planeGeometry(vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, .{ .width = 4, .height = 4, .plane_index = 2 }));
    try std.testing.expectError(error.TextureYCbCrPlaneIndexInvalid, planeGeometry(vk.VK_FORMAT_G8_B8_R8_3PLANE_444_UNORM, .{ .width = 4, .height = 4, .plane_index = std.math.maxInt(u32) }));
}

test "geometry detects byte-size overflow without narrowing arithmetic" {
    try std.testing.expectError(error.TextureYCbCrSizeOverflow, planeGeometry(vk.VK_FORMAT_R16G16B16A16_UNORM, .{
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
        .plane_index = 0,
    }));
    const plane = try planeGeometry(vk.VK_FORMAT_R8_UNORM, .{
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
        .plane_index = 0,
    });
    try std.testing.expectEqual(@as(u64, 18446744065119617025), plane.byte_size);
}

test "every core YCbCr format has exact 4x4 plane sizes" {
    const expected = [_]struct { count: u32, bytes: [3]u64 }{
        .{ .count = 1, .bytes = .{ 32, 0, 0 } },
        .{ .count = 1, .bytes = .{ 32, 0, 0 } },
        .{ .count = 3, .bytes = .{ 16, 4, 4 } },
        .{ .count = 2, .bytes = .{ 16, 8, 0 } },
        .{ .count = 3, .bytes = .{ 16, 8, 8 } },
        .{ .count = 2, .bytes = .{ 16, 16, 0 } },
        .{ .count = 3, .bytes = .{ 16, 16, 16 } },
        .{ .count = 1, .bytes = .{ 32, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 1, .bytes = .{ 128, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 3, .bytes = .{ 32, 8, 8 } },
        .{ .count = 2, .bytes = .{ 32, 16, 0 } },
        .{ .count = 3, .bytes = .{ 32, 16, 16 } },
        .{ .count = 2, .bytes = .{ 32, 32, 0 } },
        .{ .count = 3, .bytes = .{ 32, 32, 32 } },
        .{ .count = 1, .bytes = .{ 32, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 1, .bytes = .{ 128, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 3, .bytes = .{ 32, 8, 8 } },
        .{ .count = 2, .bytes = .{ 32, 16, 0 } },
        .{ .count = 3, .bytes = .{ 32, 16, 16 } },
        .{ .count = 2, .bytes = .{ 32, 32, 0 } },
        .{ .count = 3, .bytes = .{ 32, 32, 32 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 1, .bytes = .{ 64, 0, 0 } },
        .{ .count = 3, .bytes = .{ 32, 8, 8 } },
        .{ .count = 2, .bytes = .{ 32, 16, 0 } },
        .{ .count = 3, .bytes = .{ 32, 16, 16 } },
        .{ .count = 2, .bytes = .{ 32, 32, 0 } },
        .{ .count = 3, .bytes = .{ 32, 32, 32 } },
    };
    for (expected, 0..) |entry, index| {
        const format: vk.VkFormat = vk.VK_FORMAT_G8B8G8R8_422_UNORM + @as(u32, @intCast(index));
        const traits = try traitsFor(format);
        try std.testing.expectEqual(entry.count, traits.plane_count);
        for (0..3) |plane_index| {
            if (plane_index >= entry.count) continue;
            const plane = try planeGeometry(format, .{
                .width = 4,
                .height = 4,
                .plane_index = @intCast(plane_index),
            });
            try std.testing.expectEqual(entry.bytes[plane_index], plane.byte_size);
        }
    }
}

test "ordinary conversion formats retain exact color element sizes" {
    const cases = [_]struct { format: vk.VkFormat, bytes: u8 }{
        .{ .format = vk.VK_FORMAT_R4G4_UNORM_PACK8, .bytes = 1 },
        .{ .format = vk.VK_FORMAT_R4G4B4A4_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_B4G4R4A4_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_R5G6B5_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_B5G6R5_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_R5G5B5A1_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_B5G5R5A1_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_A1R5G5B5_UNORM_PACK16, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_R8_UNORM, .bytes = 1 },
        .{ .format = vk.VK_FORMAT_R8G8_UNORM, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_R8G8B8_UNORM, .bytes = 3 },
        .{ .format = vk.VK_FORMAT_B8G8R8_UNORM, .bytes = 3 },
        .{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .bytes = 4 },
        .{ .format = vk.VK_FORMAT_B8G8R8A8_UNORM, .bytes = 4 },
        .{ .format = vk.VK_FORMAT_A8B8G8R8_UNORM_PACK32, .bytes = 4 },
        .{ .format = vk.VK_FORMAT_A2R10G10B10_UNORM_PACK32, .bytes = 4 },
        .{ .format = vk.VK_FORMAT_A2B10G10R10_UNORM_PACK32, .bytes = 4 },
        .{ .format = vk.VK_FORMAT_R16_UNORM, .bytes = 2 },
        .{ .format = vk.VK_FORMAT_R16G16_UNORM, .bytes = 4 },
        .{ .format = vk.VK_FORMAT_R16G16B16_UNORM, .bytes = 6 },
        .{ .format = vk.VK_FORMAT_R16G16B16A16_UNORM, .bytes = 8 },
    };
    for (cases) |entry| {
        const traits = try traitsFor(entry.format);
        const plane = try planeGeometry(entry.format, .{
            .width = 3,
            .height = 5,
            .plane_index = 0,
        });
        try std.testing.expectEqual(@as(u32, 1), traits.plane_count);
        try std.testing.expectEqual(@as(u32, 1), traits.packed_block_width);
        try std.testing.expectEqual(entry.bytes, traits.plane_element_bytes[0]);
        try std.testing.expectEqual(entry.format, traits.plane_compatible_formats[0]);
        try std.testing.expectEqual(@as(u64, entry.bytes) * 15, plane.byte_size);
        try std.testing.expectEqual(@as(u32, vk.VK_IMAGE_ASPECT_COLOR_BIT), plane.aspect);
    }
}

test "planar 422 rejects odd width but accepts odd height" {
    const format = vk.VK_FORMAT_G8_B8R8_2PLANE_422_UNORM;
    try std.testing.expectError(error.TextureYCbCrExtentInvalid, planeGeometry(format, .{ .width = 3, .height = 3, .plane_index = 1 }));
    const plane = try planeGeometry(format, .{ .width = 4, .height = 3, .plane_index = 1 });
    try std.testing.expectEqual(@as(u32, 2), plane.width);
    try std.testing.expectEqual(@as(u32, 3), plane.height);
    try std.testing.expectEqual(@as(u64, 4), plane.row_byte_size);
    try std.testing.expectEqual(@as(u64, 12), plane.byte_size);
}
