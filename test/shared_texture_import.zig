const std = @import("std");
const vk = @import("vulkan");
const api = @import("../src/api/api.zig");
const translator = @import("../src/engine/shared_texture_import.zig");
const leaf = @import("../src/platform/external_memory_import.zig");

test "memory import requires exactly one supported arm before native access" {
    try std.testing.expectError(error.DescriptorChainEmpty, translator.validateDescriptor(&.{}));
    const opaque: api.descriptors.SharedTextureMemoryOpaqueFDDescriptor = .{
        .memory_fd = 3, .memory_type_index = 0, .allocation_size = 4096,
        .dedicated_allocation = true,
    };
    try std.testing.expectError(error.MultipleMemoryHandleArms, translator.validateDescriptor(&.{
        .shared_texture_memory_opaque_fd_descriptor = opaque,
        .shared_texture_memory_a_hardware_buffer_descriptor = .{},
    }));
    try std.testing.expectError(error.UnsupportedMemoryHandleType, translator.validateDescriptor(&.{
        .shared_texture_memory_zircon_handle_descriptor = .{ .memory_fd = 1 },
    }));
    try std.testing.expectError(error.InvalidImageCreateInfo, translator.validateDescriptor(&.{
        .shared_texture_memory_opaque_fd_descriptor = opaque,
    }));
    try std.testing.expectError(error.InvalidAHardwareBuffer, translator.validateDescriptor(&.{
        .shared_texture_memory_a_hardware_buffer_descriptor = .{},
    }));
}

test "format projection preserves actual Vulkan format and rejects unknown formats" {
    try std.testing.expectEqual(api.enums.TextureFormat.bgra8_unorm,
        try translator.apiFormat(vk.VK_FORMAT_B8G8R8A8_UNORM));
    try std.testing.expectEqual(api.enums.TextureFormat.depth32_float,
        try translator.apiFormat(vk.VK_FORMAT_D32_SFLOAT));
    try std.testing.expectError(error.InvalidExternalMemoryFormat,
        translator.apiFormat(vk.VK_FORMAT_UNDEFINED));
    try std.testing.expectError(error.InvalidExternalMemoryFormat,
        translator.apiFormat(vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM));
}

test "image chain snapshot owns format arrays and rejects cycles" {
    var formats = [_]vk.VkFormat{vk.VK_FORMAT_R8G8B8A8_UNORM};
    var list: vk.VkImageFormatListCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
        .viewFormatCount = 1, .pViewFormats = &formats,
    };
    var info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &list,
        .imageType = vk.VK_IMAGE_TYPE_2D, .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .extent = .{ .width = 8, .height = 8, .depth = 1 }, .mipLevels = 1,
        .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var snapshot = try leaf.OwnedImageCreateInfo.init(std.testing.allocator, &info);
    defer snapshot.deinit(std.testing.allocator);
    formats[0] = vk.VK_FORMAT_B8G8R8A8_UNORM;
    try std.testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_R8G8B8A8_UNORM), snapshot.formats[0]);
    list.pNext = &list;
    try std.testing.expectError(error.InvalidImageCreateChain,
        leaf.OwnedImageCreateInfo.init(std.testing.allocator, &info));
}

test "usage projection does not claim unsupported attachment or storage bits" {
    const usage = try translator.apiUsage(vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        vk.VK_FORMAT_R8G8B8A8_UNORM);
    try std.testing.expectEqual(@as(u32, 5), usage.toFlags());
    try std.testing.expectError(error.InvalidImageCreateInfo,
        translator.apiUsage(vk.VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT, vk.VK_FORMAT_R8G8B8A8_UNORM));
}

const Retirement = struct {
    step: u32 = 0,
    fn destroyImage(device: vk.VkDevice, image: vk.VkImage,
        callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self: *Retirement = @ptrCast(@alignCast(device.?));
        std.debug.assert(self.step == 0);
        std.debug.assert(image != null);
        std.debug.assert(callbacks == null);
        self.step = 1;
    }
    fn freeMemory(device: vk.VkDevice, memory: vk.VkDeviceMemory,
        callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self: *Retirement = @ptrCast(@alignCast(device.?));
        std.debug.assert(self.step == 1);
        std.debug.assert(memory != null);
        std.debug.assert(callbacks == null);
        self.step = 2;
    }
    fn releaseBuffer(pointer: *anyopaque) void {
        const self: *Retirement = @ptrCast(@alignCast(pointer));
        std.debug.assert(self.step == 2);
        self.step = 3;
    }
};

test "publication rollback destroys image before memory before AHB retain exactly once" {
    const dispatch = @import("../src/vk/dispatch.zig");
    const shared = @import("../src/engine/shared_texture_memory.zig");
    var state: Retirement = .{};
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.destroy_image = Retirement.destroyImage;
    procs.free_memory = Retirement.freeMemory;
    var imported: shared.ImportedImage = .{
        .device = @ptrCast(&state), .procs = &procs,
        .image = @ptrFromInt(16), .memory = @ptrFromInt(32),
        .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .properties = .{ .format = .rgba8_unorm,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .usage = api.bitmask.TextureUsage.fromFlags(4) },
        .mip_levels = 1, .array_layers = 1, .aspect_mask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
        .external_queue_family = vk.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .initial_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED, .provenance = .android_hardware_buffer,
        .platform_retain = &state, .release_platform_retain = Retirement.releaseBuffer,
    };
    translator.destroyImported(&imported);
    try std.testing.expectEqual(@as(u32, 3), state.step);
    try std.testing.expect(imported.image == null);
    try std.testing.expect(imported.memory == null);
    try std.testing.expect(imported.platform_retain == null);
    translator.destroyImported(&imported);
    try std.testing.expectEqual(@as(u32, 3), state.step);
}

fn snapshotAllocationFailure(allocator: std.mem.Allocator) !void {
    const formats = [_]vk.VkFormat{vk.VK_FORMAT_R8G8B8A8_UNORM};
    var list: vk.VkImageFormatListCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
        .viewFormatCount = 1, .pViewFormats = &formats,
    };
    const info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &list,
        .imageType = vk.VK_IMAGE_TYPE_2D, .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .extent = .{ .width = 8, .height = 8, .depth = 1 },
        .mipLevels = 1, .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var owned = try leaf.OwnedImageCreateInfo.init(allocator, &info);
    defer owned.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), owned.formats.len);
}

test "copied format list allocation failure leaves no partial snapshot allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotAllocationFailure, .{});
}

test "DMA descriptor preflight rejects disjoint plane handles before native import" {
    const planes = [_]api.descriptors.SharedTextureMemoryDmaBufPlane{
        .{ .fd = 3, .offset = 0, .stride = 8 },
        .{ .fd = 4, .offset = 64, .stride = 8 },
    };
    const dma = @import("../src/platform/dma_buf.zig");
    try std.testing.expectError(error.DisjointDmaBufUnsupported,
        translator.validateDescriptor(&.{
            .shared_texture_memory_dma_buf_descriptor = .{
                .size = .{ .width = 8, .height = 8, .depth_or_array_layers = 1 },
                .drm_format = dma.drmFourcc('N', 'V', '1', '2'),
                .drm_modifier = 0, .plane_count = 2, .planes = &planes,
            },
        }));
}

test "native transient usage projects only its real render attachment combination" {
    const flags = vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT |
        vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    const usage = try translator.apiUsage(flags, vk.VK_FORMAT_R8G8B8A8_UNORM);
    try std.testing.expectEqual(@as(u32, 48), usage.toFlags());
}
