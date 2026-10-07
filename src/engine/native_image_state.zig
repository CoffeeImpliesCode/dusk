//! One Vulkan subresource state shared by aliases of the same native image.
const vulkan = @import("vulkan");

pub const NativeUsageState = struct {
    layout: vulkan.VkImageLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
    access: vulkan.VkAccessFlags = 0,
    stages: vulkan.VkPipelineStageFlags = vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
};
