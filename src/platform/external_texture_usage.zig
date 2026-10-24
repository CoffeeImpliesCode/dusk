//! API usage candidates for AHardwareBuffer and modifier-tiled imports.
const vk = @import("vulkan");

pub fn usageMaskPrecedes(a: u32, b: u32) bool {
    const a_count = @popCount(a);
    const b_count = @popCount(b);
    return a_count > b_count or (a_count == b_count and a < b);
}

/// Zero means this API mask has no faithful native representation.
/// Storage attachment has no implemented native texture mapping; it is not
/// Vulkan INPUT_ATTACHMENT and must not be advertised as that different use.
pub fn textureUsageFlagsForFormat(mask: u32, format: vk.VkFormat) vk.VkImageUsageFlags {
    if (mask == 0 or mask & ~@as(u32, 127) != 0 or mask & 64 != 0) return 0;
    if (mask & 32 != 0 and (mask & 16 == 0 or mask & 15 != 0)) return 0;
    if (format == vk.VK_FORMAT_UNDEFINED and mask != 4) return 0;
    var flags: vk.VkImageUsageFlags = 0;
    if (mask & 1 != 0) flags |= vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (mask & 2 != 0) flags |= vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (mask & 4 != 0) flags |= vk.VK_IMAGE_USAGE_SAMPLED_BIT;
    if (mask & 8 != 0) flags |= vk.VK_IMAGE_USAGE_STORAGE_BIT;
    if (mask & 16 != 0) flags |= if (isDepthStencil(format))
        @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)
    else
        @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    if (mask & 32 != 0) flags |= vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;
    return flags;
}

pub fn textureUsageFlags(mask: u32) vk.VkImageUsageFlags {
    return textureUsageFlagsForFormat(mask, vk.VK_FORMAT_R8G8B8A8_UNORM);
}

fn isDepthStencil(format: vk.VkFormat) bool {
    return switch (format) {
        vk.VK_FORMAT_D16_UNORM, vk.VK_FORMAT_X8_D24_UNORM_PACK32, vk.VK_FORMAT_D32_SFLOAT, vk.VK_FORMAT_S8_UINT, vk.VK_FORMAT_D16_UNORM_S8_UINT, vk.VK_FORMAT_D24_UNORM_S8_UINT, vk.VK_FORMAT_D32_SFLOAT_S8_UINT => true,
        else => false,
    };
}
