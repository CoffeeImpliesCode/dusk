const std = @import("std");
const external = @import("../src/platform/external_memory_import.zig");
const vk = @import("vulkan");
const platform_dispatch = @import("vulkan_platform_dispatch");
const platform_procs: platform_dispatch.DeviceProcs = .{};

test "DMA-BUF accepts one shared FD and refuses disjoint planes before queries" {
    const planes = [_]external.DmaBufPlane{ .{ .fd = 7, .offset = 0, .stride = 16 }, .{ .fd = 8, .offset = 64, .stride = 16 } };
    const descriptor: external.DmaBufDescriptor = .{ .size = .{ .width = 4, .height = 4, .depth = 1 }, .drm_format = external.drmFourcc('A', 'B', '2', '4'), .drm_modifier = 0, .plane_count = 2, .planes = &planes };
    try std.testing.expectError(error.DisjointDmaBufUnsupported, external.validateDmaBufDescriptor(descriptor));
}

test "DMA-BUF count, extent, row pitch and arithmetic are bounded" {
    var planes = [_]external.DmaBufPlane{.{ .fd = 7, .offset = 0, .stride = 16 }};
    var descriptor: external.DmaBufDescriptor = .{ .size = .{ .width = 4, .height = 4, .depth = 1 }, .drm_format = external.drmFourcc('A', 'B', '2', '4'), .drm_modifier = 0, .plane_count = 1, .planes = &planes };
    try external.validateDmaBufDescriptor(descriptor);
    descriptor.plane_count = 5;
    try std.testing.expectError(error.InvalidDmaBufPlaneCount, external.validateDmaBufDescriptor(descriptor));
    descriptor.plane_count = 1;
    planes[0].offset = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidDmaBufLayout, external.validateDmaBufLayouts(descriptor, 4096));
    planes[0].offset = 0;
    try external.validateDmaBufLayouts(descriptor, 64);
    try std.testing.expectError(error.InvalidDmaBufLayout, external.validateDmaBufLayouts(descriptor, 63));
}

test "OpaqueFD snapshots format list without borrowing caller array" {
    var formats = [_]vk.VkFormat{vk.VK_FORMAT_R8G8B8A8_UNORM};
    var list: vk.VkImageFormatListCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO, .viewFormatCount = 1, .pViewFormats = &formats };
    var info: vk.VkImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &list, .imageType = vk.VK_IMAGE_TYPE_2D, .format = formats[0], .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT, .tiling = vk.VK_IMAGE_TILING_OPTIMAL, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED };
    var owned = try external.OwnedImageCreateInfo.init(std.testing.allocator, &info);
    defer owned.deinit(std.testing.allocator);
    formats[0] = vk.VK_FORMAT_UNDEFINED;
    const copied = owned.borrowedInfo();
    const copied_list: *const vk.VkImageFormatListCreateInfo = @ptrCast(@alignCast(copied.pNext.?));
    try std.testing.expectEqual(vk.VK_FORMAT_R8G8B8A8_UNORM, copied_list.pViewFormats[0]);
}

test "OpaqueFD rejects duplicate known pNext and invalid image extent" {
    var second: vk.VkExternalMemoryImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT };
    var first = second;
    first.pNext = &second;
    var info: vk.VkImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &first, .imageType = vk.VK_IMAGE_TYPE_2D, .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT, .tiling = vk.VK_IMAGE_TILING_OPTIMAL, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED };
    try std.testing.expectError(error.InvalidImageCreateChain, external.OwnedImageCreateInfo.init(std.testing.allocator, &info));
    info.pNext = null;
    info.extent.depth = 2;
    try std.testing.expectError(error.InvalidImageCreateInfo, external.OwnedImageCreateInfo.init(std.testing.allocator, &info));
}

test "usage masks select largest population then smallest numeric mask" {
    try std.testing.expect(external.usageMaskPrecedes(7, 11));
    try std.testing.expect(external.usageMaskPrecedes(3, 4));
    try std.testing.expect(!external.usageMaskPrecedes(4, 3));
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT), external.textureUsageFlags(5));
}

const dispatch = @import("../src/vk/dispatch.zig");
const native_caps = @import("../src/engine/native_capabilities.zig");
var native_failure: enum { none, allocate, bind } = .none;
var created: usize = 0;
var destroyed: usize = 0;
var freed: usize = 0;
var seen_fd: std.posix.fd_t = -1;

fn imageProperties(_: vk.VkPhysicalDevice, info: [*c]const vk.VkPhysicalDeviceImageFormatInfo2, out: [*c]vk.VkImageFormatProperties2) callconv(.c) vk.VkResult {
    const handle: *const vk.VkPhysicalDeviceExternalImageFormatInfo = @ptrCast(@alignCast(info.*.pNext.?));
    std.debug.assert(handle.handleType == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT);
    const properties: *vk.VkExternalImageFormatProperties = @ptrCast(@alignCast(out.*.pNext.?));
    properties.externalMemoryProperties = .{ .externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT, .compatibleHandleTypes = handle.handleType };
    out.*.imageFormatProperties = .{ .maxExtent = .{ .width = 1024, .height = 1024, .depth = 1 }, .maxMipLevels = 11, .maxArrayLayers = 16, .sampleCounts = vk.VK_SAMPLE_COUNT_1_BIT };
    return vk.VK_SUCCESS;
}
fn createImage(_: vk.VkDevice, info: [*c]const vk.VkImageCreateInfo, _: [*c]const vk.VkAllocationCallbacks, out: [*c]vk.VkImage) callconv(.c) vk.VkResult {
    const handle: *const vk.VkExternalMemoryImageCreateInfo = @ptrCast(@alignCast(info.*.pNext.?));
    std.debug.assert(handle.handleTypes == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT);
    created += 1;
    out.* = @ptrFromInt(0x1000);
    return vk.VK_SUCCESS;
}
fn destroyImage(_: vk.VkDevice, _: vk.VkImage, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
    destroyed += 1;
}
fn imageRequirements(_: vk.VkDevice, _: [*c]const vk.VkImageMemoryRequirementsInfo2, out: [*c]vk.VkMemoryRequirements2) callconv(.c) void {
    out.*.memoryRequirements = .{ .size = 64, .alignment = 16, .memoryTypeBits = 1 };
    const dedicated: *vk.VkMemoryDedicatedRequirements = @ptrCast(@alignCast(out.*.pNext.?));
    dedicated.requiresDedicatedAllocation = vk.VK_TRUE;
}
fn allocateMemory(_: vk.VkDevice, info: [*c]const vk.VkMemoryAllocateInfo, _: [*c]const vk.VkAllocationCallbacks, out: [*c]vk.VkDeviceMemory) callconv(.c) vk.VkResult {
    const import: *const vk.VkImportMemoryFdInfoKHR = @ptrCast(@alignCast(info.*.pNext.?));
    std.debug.assert(import.handleType == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT);
    const dedicated: *const vk.VkMemoryDedicatedAllocateInfo = @ptrCast(@alignCast(import.pNext.?));
    std.debug.assert(dedicated.image == @as(vk.VkImage, @ptrFromInt(0x1000)));
    seen_fd = import.fd;
    if (native_failure == .allocate) return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    external.closeMemoryFd(std.testing.io, import.fd);
    out.* = @ptrFromInt(0x2000);
    return vk.VK_SUCCESS;
}
fn freeMemory(_: vk.VkDevice, _: vk.VkDeviceMemory, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
    freed += 1;
}
fn bindMemory(_: vk.VkDevice, _: vk.VkImage, _: vk.VkDeviceMemory, _: vk.VkDeviceSize) callconv(.c) vk.VkResult {
    return if (native_failure == .bind) vk.VK_ERROR_DEVICE_LOST else vk.VK_SUCCESS;
}

test "OpaqueFD allocate transfer and bind rollback preserve caller FD" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "memory", .{});
    defer file.close(io);
    var ip = std.mem.zeroes(dispatch.InstanceProcs);
    ip.get_physical_device_image_format_properties2 = imageProperties;
    var dp = std.mem.zeroes(dispatch.DeviceProcs);
    dp.create_image = createImage;
    dp.destroy_image = destroyImage;
    dp.get_image_memory_requirements2 = imageRequirements;
    dp.allocate_memory = allocateMemory;
    dp.free_memory = freeMemory;
    dp.bind_image_memory = bindMemory;
    const instance_caps: native_caps.InstanceCapabilities = .{ .enabled = .{}, .procs = &ip };
    const caps: native_caps.NativeCapabilities = .{ .instance = &instance_caps, .enabled_device = .{}, .procs = &dp, .external_memory_opaque_fd = true };
    const options: external.DeviceOptions = .{ .physical_device = null, .device = null, .instance_procs = &ip, .device_procs = &dp, .enabled_extensions = .{}, .capabilities = &caps, .platform_device_procs = &platform_procs };
    const info: vk.VkImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = vk.VK_IMAGE_TYPE_2D, .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT, .tiling = vk.VK_IMAGE_TILING_OPTIMAL, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED };
    const descriptor: external.OpaqueFdDescriptor = .{ .image_info = &info, .fd = file.handle, .allocation_size = 64, .memory_type_index = 0 };
    created = 0;
    destroyed = 0;
    freed = 0;
    native_failure = .allocate;
    try std.testing.expectError(error.OutOfDeviceMemory, external.importOpaqueFd(std.testing.allocator, io, options, descriptor));
    try std.testing.expect(seen_fd != file.handle);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqual(@as(usize, 0), freed);
    native_failure = .bind;
    try std.testing.expectError(error.DeviceLost, external.importOpaqueFd(std.testing.allocator, io, options, descriptor));
    try std.testing.expectEqual(@as(usize, 2), destroyed);
    try std.testing.expectEqual(@as(usize, 1), freed);
    native_failure = .none;
    const imported = try external.importOpaqueFd(std.testing.allocator, io, options, descriptor);
    destroyImage(null, imported.image, null);
    freeMemory(null, imported.memory, null);
    const surviving = try external.duplicateMemoryFd(io, file.handle);
    external.closeMemoryFd(io, surviving);
    try std.testing.expectEqual(@as(usize, 3), created);
    try std.testing.expectEqual(@as(usize, 3), destroyed);
    try std.testing.expectEqual(@as(usize, 2), freed);
}

fn snapshotWithAllocationFailure(allocator: std.mem.Allocator) !void {
    const formats = [_]vk.VkFormat{ vk.VK_FORMAT_R8G8B8A8_UNORM, vk.VK_FORMAT_R8G8B8A8_SRGB };
    const list: vk.VkImageFormatListCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO, .viewFormatCount = formats.len, .pViewFormats = &formats };
    const info: vk.VkImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &list, .flags = vk.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, .imageType = vk.VK_IMAGE_TYPE_2D, .format = formats[0], .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT, .tiling = vk.VK_IMAGE_TILING_OPTIMAL, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED };
    var owned = try external.OwnedImageCreateInfo.init(allocator, &info);
    defer owned.deinit(allocator);
    const copy = owned.borrowedInfo();
    try std.testing.expectEqual(info.format, copy.format);
}

test "OpaqueFD format-array fail-N frees every partial copy" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotWithAllocationFailure, .{});
}

test "usage candidates never invent storage attachment and preserve native depth usage" {
    const usage = @import("../src/platform/external_texture_usage.zig");
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, 0), usage.textureUsageFlagsForFormat(127, vk.VK_FORMAT_R8G8B8A8_UNORM));
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT), usage.textureUsageFlagsForFormat(16, vk.VK_FORMAT_D32_SFLOAT));
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, 0), usage.textureUsageFlagsForFormat(33, vk.VK_FORMAT_R8G8B8A8_UNORM));
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT), usage.textureUsageFlagsForFormat(48, vk.VK_FORMAT_R8G8B8A8_UNORM));
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_SAMPLED_BIT), usage.textureUsageFlagsForFormat(4, vk.VK_FORMAT_UNDEFINED));
}
