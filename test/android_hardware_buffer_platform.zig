const std = @import("std");
const ahb = @import("../src/platform/android_hardware_buffer.zig");
const android = @import("android_platform");
const avk = @import("vulkan_platform_android");
const vk = @import("vulkan");
const dispatch = @import("../src/vk/dispatch.zig");
const platform_dispatch = @import("vulkan_platform_dispatch");
const capabilities = @import("../src/engine/native_capabilities.zig");

var acquired: usize = 0;
var released: usize = 0;
var destroyed: usize = 0;
var freed: usize = 0;
var bind_fails = false;
var invalid_description = false;
var saw_external_format = false;
var query_count: usize = 0;
var external_only = false;
var property_fails = false;
var required_usage_missing = false;
var allocation_fails = false;
var create_fails = false;
var destruction_order: u32 = 0;
var single_transfer_only = false;
var odd_height_yuv_format: u32 = 0;

fn describe(_: ?*const android.AHardwareBuffer, out: [*c]android.AHardwareBuffer_Desc) callconv(.c) void {
    out.* = std.mem.zeroes(android.AHardwareBuffer_Desc);
    out.width = if (invalid_description) 0 else 32;
    out.height = if (odd_height_yuv_format != 0) 15 else 16;
    out.layers = 1;
    out.format = if (odd_height_yuv_format != 0) odd_height_yuv_format else android.AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    out.usage = android.AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | android.AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER;
}
fn acquire(_: ?*android.AHardwareBuffer) callconv(.c) void { acquired += 1; }
fn release(_: ?*android.AHardwareBuffer) callconv(.c) void {
    released += 1;
    destruction_order = destruction_order * 10 + 3;
}
fn properties(_: avk.VkDevice, _: ?*const avk.struct_AHardwareBuffer, out: [*c]avk.VkAndroidHardwareBufferPropertiesANDROID) callconv(.c) avk.VkResult {
    std.debug.assert(out.sType == avk.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID);
    const format: *avk.VkAndroidHardwareBufferFormatPropertiesANDROID = @ptrCast(@alignCast(out.pNext.?));
    std.debug.assert(format.sType == avk.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID);
    if (property_fails) return avk.VK_ERROR_OUT_OF_HOST_MEMORY;
    out.allocationSize = 4096;
    out.memoryTypeBits = 4;
    format.format = if (external_only) avk.VK_FORMAT_UNDEFINED else avk.VK_FORMAT_R8G8B8A8_UNORM;
    format.externalFormat = 91;
    format.formatFeatures = avk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | avk.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
    format.suggestedYcbcrModel = avk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY;
    format.suggestedYcbcrRange = avk.VK_SAMPLER_YCBCR_RANGE_ITU_FULL;
    format.suggestedXChromaOffset = avk.VK_CHROMA_LOCATION_COSITED_EVEN;
    format.suggestedYChromaOffset = avk.VK_CHROMA_LOCATION_MIDPOINT;
    return avk.VK_SUCCESS;
}
fn query(_: vk.VkPhysicalDevice, info: [*c]const vk.VkPhysicalDeviceImageFormatInfo2, out: [*c]vk.VkImageFormatProperties2) callconv(.c) vk.VkResult {
    query_count += 1;
    const external: *const vk.VkPhysicalDeviceExternalImageFormatInfo = @ptrCast(@alignCast(info.pNext.?));
    std.debug.assert(external.handleType == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID);
    const external_out: *vk.VkExternalImageFormatProperties = @ptrCast(@alignCast(out.pNext.?));
    external_out.externalMemoryProperties.externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT;
    external_out.externalMemoryProperties.compatibleHandleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
    const usage: *avk.VkAndroidHardwareBufferUsageANDROID = @ptrCast(@alignCast(external_out.pNext.?));
    std.debug.assert(usage.sType == avk.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_USAGE_ANDROID);
    usage.androidHardwareBufferUsage = if (required_usage_missing) android.AHARDWAREBUFFER_USAGE_GPU_CUBE_MAP else android.AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE;
    out.imageFormatProperties.maxExtent = .{ .width = 1024, .height = 1024, .depth = 1 };
    out.imageFormatProperties.maxArrayLayers = 16;
    out.imageFormatProperties.maxMipLevels = 1;
    out.imageFormatProperties.sampleCounts = vk.VK_SAMPLE_COUNT_1_BIT;
    if (single_transfer_only and info.usage != vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT and info.usage != vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT) return vk.VK_ERROR_FORMAT_NOT_SUPPORTED;
    if (info.usage & (vk.VK_IMAGE_USAGE_STORAGE_BIT | vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT) != 0) return vk.VK_ERROR_FORMAT_NOT_SUPPORTED;
    return vk.VK_SUCCESS;
}
fn create(_: vk.VkDevice, info: [*c]const vk.VkImageCreateInfo, _: [*c]const vk.VkAllocationCallbacks, out: [*c]vk.VkImage) callconv(.c) vk.VkResult {
    std.debug.assert(info.extent.width == 32 and info.extent.height == 16 and info.arrayLayers == 1);
    const external: *const vk.VkExternalMemoryImageCreateInfo = @ptrCast(@alignCast(info.pNext.?));
    std.debug.assert(external.handleTypes == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID);
    saw_external_format = external.pNext != null;
    if (saw_external_format) {
        const format: *const avk.VkExternalFormatANDROID = @ptrCast(@alignCast(external.pNext.?));
        std.debug.assert(format.externalFormat == 91);
        std.debug.assert(info.format == vk.VK_FORMAT_UNDEFINED);
    }
    if (create_fails) return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    out.* = @ptrFromInt(0x1000);
    return vk.VK_SUCCESS;
}
fn destroy(_: vk.VkDevice, _: vk.VkImage, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
    destroyed += 1;
    destruction_order = destruction_order * 10 + 1;
}
fn allocate(_: vk.VkDevice, info: [*c]const vk.VkMemoryAllocateInfo, _: [*c]const vk.VkAllocationCallbacks, out: [*c]vk.VkDeviceMemory) callconv(.c) vk.VkResult {
    std.debug.assert(info.allocationSize == 4096 and info.memoryTypeIndex == 2);
    const imported: *const avk.VkImportAndroidHardwareBufferInfoANDROID = @ptrCast(@alignCast(info.pNext.?));
    std.debug.assert(imported.sType == avk.VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID and imported.buffer != null);
    const dedicated: *const vk.VkMemoryDedicatedAllocateInfo = @ptrCast(@alignCast(imported.pNext.?));
    std.debug.assert(dedicated.sType == vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO and dedicated.image == @as(vk.VkImage, @ptrFromInt(0x1000)));
    if (allocation_fails) return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    out.* = @ptrFromInt(0x2000);
    return vk.VK_SUCCESS;
}
fn free(_: vk.VkDevice, _: vk.VkDeviceMemory, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
    freed += 1;
    destruction_order = destruction_order * 10 + 2;
}
fn bind(_: vk.VkDevice, _: vk.VkImage, _: vk.VkDeviceMemory, offset: vk.VkDeviceSize) callconv(.c) vk.VkResult {
    std.debug.assert(offset == 0);
    return if (bind_fails) vk.VK_ERROR_OUT_OF_DEVICE_MEMORY else vk.VK_SUCCESS;
}
fn memoryProperties(_: vk.VkPhysicalDevice, out: [*c]vk.VkPhysicalDeviceMemoryProperties) callconv(.c) void {
    out.* = std.mem.zeroes(vk.VkPhysicalDeviceMemoryProperties);
    out.memoryTypeCount = 3;
}
fn service() ahb.AndroidHardwareBufferService {
    acquired = 0; released = 0; destroyed = 0; freed = 0; query_count = 0;
    bind_fails = false; invalid_description = false; saw_external_format = false;
    external_only = false; property_fails = false; required_usage_missing = false;
    allocation_fails = false; create_fails = false; destruction_order = 0;
    single_transfer_only = false;
    odd_height_yuv_format = 0;
    return .initWithHooks(.{
        .physical_device = null,
        .device = null,
        .instance_procs = &instance_procs,
        .device_procs = &device_procs,
        .enabled_extensions = .{},
        .platform_device_procs = &android_procs,
        .capabilities = &caps,
    }, .{ .describe = &describe, .acquire = &acquire, .release = &release });
}
const instance_procs: dispatch.InstanceProcs = blk: {
    var p = std.mem.zeroes(dispatch.InstanceProcs);
    p.get_physical_device_image_format_properties2 = &query;
    p.get_physical_device_memory_properties = &memoryProperties;
    break :blk p;
};
const device_procs: dispatch.DeviceProcs = blk: {
    var p = std.mem.zeroes(dispatch.DeviceProcs);
    p.create_image = &create; p.destroy_image = &destroy;
    p.allocate_memory = &allocate; p.free_memory = &free; p.bind_image_memory = &bind;
    break :blk p;
};
const android_procs: platform_dispatch.DeviceProcs = .{ .get_android_hardware_buffer_properties = &properties };
const instance_caps: capabilities.InstanceCapabilities = .{
    .enabled = .{},
    .procs = &instance_procs,
};
const caps: capabilities.NativeCapabilities = .{
    .instance = &instance_caps,
    .enabled_device = .{},
    .procs = &device_procs,
    .external_memory_ahb = true,
    .sampler_ycbcr_conversion = true,
};
const handle: *android.AHardwareBuffer = @ptrFromInt(0x3000);

test "AHB properties preserve queried format and YCbCr traits without retaining" {
    const s = service();
    const p = try s.getProperties(handle);
    try std.testing.expectEqual(@as(u64, 91), p.external_format);
    try std.testing.expectEqual(vk.VK_FORMAT_R8G8B8A8_UNORM, p.format);
    try std.testing.expectEqual(vk.VK_CHROMA_LOCATION_MIDPOINT, p.y_chroma_offset);
    try std.testing.expectEqual(@as(usize, 0), acquired);
    try std.testing.expectEqual(@as(usize, 0), released);
}
test "AHB import keeps exactly one retain until image then memory destruction" {
    const s = service();
    var result = try s.importImage(handle);
    try std.testing.expectEqual(@as(usize, 1), acquired);
    try std.testing.expectEqual(@as(usize, 0), released);
    try std.testing.expectEqual(@as(u32, 23), result.api_usage.toFlags());
    try std.testing.expect(!saw_external_format); // Defined VkFormat must not use externalFormat.
    // Thirty-one non-transient masks and one faithful transient mask; bit 64
    // and incompatible transient combinations have no native representation.
    try std.testing.expectEqual(@as(usize, 32), query_count);
    s.destroyImport(&result);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(@as(usize, 1), released);
    s.destroyImport(&result);
    try std.testing.expectEqual(@as(usize, 1), released);
}
test "AHB bind failure rolls back image memory and acquired reference" {
    const s = service();
    bind_fails = true;
    _ = s.importImage(handle) catch {
        try std.testing.expectEqual(@as(usize, 1), destroyed);
        try std.testing.expectEqual(@as(usize, 1), freed);
        try std.testing.expectEqual(@as(usize, 1), acquired);
        try std.testing.expectEqual(@as(usize, 1), released);
        return;
    };
    return error.TestExpectedError;
}
test "invalid described dimensions fail before acquiring AHB reference" {
    const s = service();
    invalid_description = true;
    try std.testing.expectError(error.InvalidHardwareBufferDescriptor, s.importImage(handle));
    try std.testing.expectEqual(@as(usize, 0), acquired);
    try std.testing.expectEqual(@as(usize, 0), released);
}

test "external format import creates its exact external-format pNext" {
    const s = service();
    external_only = true;
    var imported = try s.importImage(handle);
    try std.testing.expect(saw_external_format);
    try std.testing.expectEqual(@as(u32, 4), imported.api_usage.toFlags());
    try std.testing.expectEqual(@as(usize, 0), query_count);
    s.destroyImport(&imported);
    try std.testing.expectEqual(@as(u32, 123), destruction_order);
}

test "AHB driver-required allocation usage rejects every otherwise supported mask" {
    const s = service();
    required_usage_missing = true;
    try std.testing.expectError(error.NoSupportedTextureUsage, s.importImage(handle));
    try std.testing.expectEqual(@as(usize, 1), acquired);
    try std.testing.expectEqual(@as(usize, 1), released);
    try std.testing.expectEqual(@as(usize, 0), destroyed);
}

test "AHB property failure releases retain without creating image" {
    const s = service();
    property_fails = true;
    _ = s.importImage(handle) catch {
        try std.testing.expectEqual(@as(usize, 1), released);
        try std.testing.expectEqual(@as(usize, 0), destroyed);
        return;
    };
    return error.TestExpectedError;
}

test "AHB allocation failure destroys image before releasing retain" {
    const s = service();
    allocation_fails = true;
    _ = s.importImage(handle) catch {
        try std.testing.expectEqual(@as(usize, 1), destroyed);
        try std.testing.expectEqual(@as(usize, 0), freed);
        try std.testing.expectEqual(@as(u32, 13), destruction_order);
        return;
    };
    return error.TestExpectedError;
}

test "AHB create failure releases retain without destroying absent image" {
    const s = service();
    create_fails = true;
    _ = s.importImage(handle) catch {
        try std.testing.expectEqual(@as(usize, 1), released);
        try std.testing.expectEqual(@as(usize, 0), destroyed);
        try std.testing.expectEqual(@as(usize, 0), freed);
        return;
    };
    return error.TestExpectedError;
}

test "AHB usage selection chooses minimum API mask on equal popcount" {
    const s = service();
    single_transfer_only = true;
    var imported = try s.importImage(handle);
    try std.testing.expectEqual(@as(u32, 1), imported.api_usage.toFlags());
    s.destroyImport(&imported);
}

test "AHB 4:2:2 P210 accepts odd height but 4:2:0 P010 does not" {
    const s = service();
    odd_height_yuv_format = android.AHARDWAREBUFFER_FORMAT_YCbCr_P210;
    const desc = try s.describe(handle);
    try std.testing.expectEqual(@as(u32, 15), desc.height);
    odd_height_yuv_format = android.AHARDWAREBUFFER_FORMAT_YCbCr_P010;
    try std.testing.expectError(error.InvalidHardwareBufferDescriptor, s.describe(handle));
    try std.testing.expectEqual(@as(usize, 0), acquired);
}
