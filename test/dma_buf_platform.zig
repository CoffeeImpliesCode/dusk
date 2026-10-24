const std = @import("std");
const dma = @import("../src/platform/dma_buf.zig");
const vk = @import("vulkan");
const dispatch = @import("../src/vk/dispatch.zig");
const native = @import("../src/engine/native_capabilities.zig");
const platform_device_procs: @import("vulkan_platform_dispatch").DeviceProcs = .{};

fn descriptor(planes: []const dma.DmaBufPlane) dma.DmaBufDescriptor {
    return .{ .size = .{ .width = 4, .height = 4, .depth = 1 }, .drm_format = dma.drmFourcc('A', 'B', '2', '4'), .drm_modifier = 0, .plane_count = planes.len, .planes = planes };
}

test "DMA-BUF validates count extent FD and non-disjoint preflight" {
    var planes = [_]dma.DmaBufPlane{ .{ .fd = 7, .offset = 0, .stride = 16 }, .{ .fd = 8, .offset = 64, .stride = 16 } };
    var desc = descriptor(&planes);
    try std.testing.expectError(error.DisjointDmaBufUnsupported, dma.validateDmaBufDescriptor(desc));
    desc.plane_count = 0;
    try std.testing.expectError(error.InvalidDmaBufPlaneCount, dma.validateDmaBufDescriptor(desc));
    desc.plane_count = 5;
    try std.testing.expectError(error.InvalidDmaBufPlaneCount, dma.validateDmaBufDescriptor(desc));
    desc.plane_count = 1;
    try std.testing.expectError(error.InvalidDmaBufPlaneCount, dma.validateDmaBufDescriptor(desc));
    desc.planes = planes[0..1];
    try dma.validateDmaBufDescriptor(desc);
    planes[0].fd = -1;
    try std.testing.expectError(error.InvalidMemoryHandle, dma.validateDmaBufDescriptor(desc));
    planes[0].fd = 7;
    desc.size.depth = 2;
    try std.testing.expectError(error.InvalidDmaBufLayout, dma.validateDmaBufDescriptor(desc));
}

test "DMA-BUF checked plane bounds use real memory size" {
    var planes = [_]dma.DmaBufPlane{.{ .fd = 7, .offset = 0, .stride = 16 }};
    const desc = descriptor(&planes);
    try dma.validateDmaBufLayouts(desc, 64);
    try std.testing.expectError(error.InvalidDmaBufLayout, dma.validateDmaBufLayouts(desc, 63));
    planes[0].offset = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidDmaBufLayout, dma.validateDmaBufLayouts(desc, std.math.maxInt(u64)));
    planes[0].offset = 0;
    planes[0].stride = 15;
    try std.testing.expectError(error.InvalidDmaBufLayout, dma.validateDmaBufLayouts(desc, 4096));
}

test "DMA-BUF FourCC maps exact channel order and chroma rows" {
    try std.testing.expectEqual(vk.VK_FORMAT_R8G8B8A8_UNORM, try dma.formatForFourcc(dma.drmFourcc('A', 'B', '2', '4')));
    try std.testing.expectEqual(vk.VK_FORMAT_B8G8R8A8_UNORM, try dma.formatForFourcc(dma.drmFourcc('A', 'R', '2', '4')));
    try std.testing.expectError(error.InvalidExternalMemoryFormat, dma.formatForFourcc(0));
    const planes = [_]dma.DmaBufPlane{ .{ .fd = 7, .offset = 0, .stride = 4 }, .{ .fd = 7, .offset = 12, .stride = 4 } };
    var desc = descriptor(&planes);
    desc.size.height = 3;
    desc.drm_format = dma.drmFourcc('N', 'V', '1', '2');
    try dma.validateDmaBufLayouts(desc, 20);
    try std.testing.expectError(error.InvalidDmaBufLayout, dma.validateDmaBufLayouts(desc, 19));
}

var format_calls: usize = 0;
var image_queries: usize = 0;
var unstable = false;
var importable = true;
var supported_usage: vk.VkImageUsageFlags = vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT;
var modifier_features: vk.VkFormatFeatureFlags = vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | vk.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
var creates: usize = 0;
var destroys: usize = 0;
var frees: usize = 0;
var allocated_fd: c_int = -1;
var failure: enum { none, allocate, bind } = .none;

fn queryFormat(_: vk.VkPhysicalDevice, _: vk.VkFormat, out: [*c]vk.VkFormatProperties2) callconv(.c) void {
    format_calls += 1;
    const list: *vk.VkDrmFormatModifierPropertiesListEXT = @ptrCast(@alignCast(out.*.pNext.?));
    if (list.pDrmFormatModifierProperties == null) {
        list.drmFormatModifierCount = 1;
    } else if (unstable) {
        list.drmFormatModifierCount = 2;
    } else {
        list.pDrmFormatModifierProperties[0] = .{ .drmFormatModifier = 0, .drmFormatModifierPlaneCount = 1, .drmFormatModifierTilingFeatures = modifier_features };
        list.drmFormatModifierCount = 1;
    }
    // Optimal features must not rescue an unsupported modifier.
    out.*.formatProperties.optimalTilingFeatures = std.math.maxInt(vk.VkFormatFeatureFlags);
}
fn queryImage(_: vk.VkPhysicalDevice, input: [*c]const vk.VkPhysicalDeviceImageFormatInfo2, output: [*c]vk.VkImageFormatProperties2) callconv(.c) vk.VkResult {
    image_queries += 1;
    std.debug.assert(input.*.tiling == vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT);
    const external: *const vk.VkPhysicalDeviceExternalImageFormatInfo = @ptrCast(@alignCast(input.*.pNext.?));
    std.debug.assert(external.handleType == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
    const modifier: *const vk.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = @ptrCast(@alignCast(external.pNext.?));
    std.debug.assert(modifier.drmFormatModifier == 0);
    if (input.*.usage & ~supported_usage != 0) return vk.VK_ERROR_FORMAT_NOT_SUPPORTED;
    const properties: *vk.VkExternalImageFormatProperties = @ptrCast(@alignCast(output.*.pNext.?));
    properties.externalMemoryProperties.externalMemoryFeatures = if (importable) vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT else 0;
    return vk.VK_SUCCESS;
}
fn createImage(_: vk.VkDevice, input: [*c]const vk.VkImageCreateInfo, _: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkImage) callconv(.c) vk.VkResult {
    creates += 1;
    std.debug.assert(input.*.tiling == vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT);
    const external: *const vk.VkExternalMemoryImageCreateInfo = @ptrCast(@alignCast(input.*.pNext.?));
    std.debug.assert(external.handleTypes == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
    const modifier: *const vk.VkImageDrmFormatModifierExplicitCreateInfoEXT = @ptrCast(@alignCast(external.pNext.?));
    std.debug.assert(modifier.drmFormatModifierPlaneCount == 1);
    std.debug.assert(modifier.pPlaneLayouts[0].offset == 0 and modifier.pPlaneLayouts[0].rowPitch == 16);
    output.* = @ptrFromInt(0x1000);
    return vk.VK_SUCCESS;
}
fn destroyImage(_: vk.VkDevice, _: vk.VkImage, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
    destroys += 1;
}
fn requirements(_: vk.VkDevice, _: vk.VkImage, out: [*c]vk.VkMemoryRequirements) callconv(.c) void {
    out.* = .{ .size = 64, .alignment = 16, .memoryTypeBits = 6 };
}
fn fdProperties(_: vk.VkDevice, handle: vk.VkExternalMemoryHandleTypeFlagBits, _: c_int, out: [*c]vk.VkMemoryFdPropertiesKHR) callconv(.c) vk.VkResult {
    std.debug.assert(handle == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
    out.*.memoryTypeBits = 12;
    return vk.VK_SUCCESS;
}
fn allocateMemory(_: vk.VkDevice, input: [*c]const vk.VkMemoryAllocateInfo, _: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkDeviceMemory) callconv(.c) vk.VkResult {
    std.debug.assert(input.*.allocationSize == 64 and input.*.memoryTypeIndex == 2);
    const imported: *const vk.VkImportMemoryFdInfoKHR = @ptrCast(@alignCast(input.*.pNext.?));
    std.debug.assert(imported.handleType == vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
    const dedicated: *const vk.VkMemoryDedicatedAllocateInfo = @ptrCast(@alignCast(imported.pNext.?));
    std.debug.assert(dedicated.image == @as(vk.VkImage, @ptrFromInt(0x1000)));
    allocated_fd = imported.fd;
    if (failure == .allocate) return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    @import("../src/platform/external_memory_import.zig").closeMemoryFd(std.testing.io, imported.fd);
    output.* = @ptrFromInt(0x2000);
    return vk.VK_SUCCESS;
}
fn freeMemory(_: vk.VkDevice, _: vk.VkDeviceMemory, _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
    frees += 1;
}
fn bindImage(_: vk.VkDevice, _: vk.VkImage, _: vk.VkDeviceMemory, offset: vk.VkDeviceSize) callconv(.c) vk.VkResult {
    std.debug.assert(offset == 0);
    return if (failure == .bind) vk.VK_ERROR_OUT_OF_DEVICE_MEMORY else vk.VK_SUCCESS;
}
const Fixture = struct {
    instance: dispatch.InstanceProcs,
    device: dispatch.DeviceProcs,
    caps: native.NativeCapabilities,
    fn init() Fixture {
        var result: Fixture = .{ .instance = std.mem.zeroes(dispatch.InstanceProcs), .device = std.mem.zeroes(dispatch.DeviceProcs), .caps = undefined };
        result.instance.get_physical_device_format_properties2 = queryFormat;
        result.instance.get_physical_device_image_format_properties2 = queryImage;
        result.device.create_image = createImage;
        result.device.destroy_image = destroyImage;
        result.device.get_image_memory_requirements = requirements;
        result.device.get_memory_fd_properties_khr = fdProperties;
        result.device.allocate_memory = allocateMemory;
        result.device.free_memory = freeMemory;
        result.device.bind_image_memory = bindImage;
        result.caps.external_memory_dma_buf = true;
        return result;
    }
    fn service(self: *const Fixture) TestCalls {
        // Only core dispatch and the DMA capability bit are read by this fixture.
        return .{ .options = .{ .physical_device = null, .device = null, .instance_procs = &self.instance, .device_procs = &self.device, .enabled_extensions = .{}, .capabilities = &self.caps, .platform_device_procs = &platform_device_procs } };
    }
};
const TestCalls = struct {
    options: dma.DeviceOptions,
    fn supportsDmaBuf(self: TestCalls, allocator: std.mem.Allocator, value: dma.DmaBufFormatQuery) dma.DmaBufQueryError!bool {
        return dma.supportsDmaBuf(allocator, self.options, value);
    }
    fn selectDmaBufUsage(self: TestCalls, allocator: std.mem.Allocator, value: dma.DmaBufDescriptor) dma.DmaBufQueryError!dma.SelectedUsage {
        return dma.selectDmaBufUsage(allocator, self.options, value);
    }
    fn importDmaBuf(self: TestCalls, allocator: std.mem.Allocator, io: std.Io, value: dma.DmaBufDescriptor, info: vk.VkImageCreateInfo) dma.DmaBufImportError!dma.DmaBufImportResult {
        return dma.importDmaBuf(allocator, io, self.options, value, info);
    }
};
fn reset() void {
    format_calls = 0;
    image_queries = 0;
    unstable = false;
    importable = true;
    modifier_features = vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | vk.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
    creates = 0;
    destroys = 0;
    frees = 0;
    allocated_fd = -1;
    failure = .none;
}
fn query() dma.DmaBufFormatQuery {
    return .{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .drm_format = dma.drmFourcc('A', 'B', '2', '4'), .modifier = 0, .plane_count = 1, .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT };
}

test "DMA-BUF queries exact modifier chain and requires importable properties" {
    reset();
    var fixture = Fixture.init();
    try std.testing.expect(try fixture.service().supportsDmaBuf(std.testing.allocator, query()));
    try std.testing.expectEqual(@as(usize, 3), format_calls);
    importable = false;
    try std.testing.expect(!try fixture.service().supportsDmaBuf(std.testing.allocator, query()));
    var absent = query();
    absent.modifier = 99;
    const before = image_queries;
    try std.testing.expect(!try fixture.service().supportsDmaBuf(std.testing.allocator, absent));
    try std.testing.expectEqual(before, image_queries);
    fixture.caps.external_memory_dma_buf = false;
    try std.testing.expect(!try fixture.service().supportsDmaBuf(std.testing.allocator, query()));
}
test "DMA-BUF modifier count changes retry exactly three times" {
    reset();
    const fixture = Fixture.init();
    unstable = true;
    try std.testing.expectError(error.ModifierPropertiesUnstable, fixture.service().supportsDmaBuf(std.testing.allocator, query()));
    try std.testing.expectEqual(@as(usize, 6), format_calls);
    try std.testing.expectEqual(@as(usize, 0), image_queries);
}
test "DMA-BUF query allocation errors propagate before image query" {
    reset();
    const fixture = Fixture.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, fixture.service().supportsDmaBuf(failing.allocator(), query()));
    try std.testing.expectEqual(@as(usize, 0), image_queries);
}
test "DMA-BUF usage selection reports only the largest exact supported mask" {
    reset();
    const fixture = Fixture.init();
    const planes = [_]dma.DmaBufPlane{.{ .fd = 7, .offset = 0, .stride = 16 }};
    const selected = try fixture.service().selectDmaBufUsage(std.testing.allocator, descriptor(&planes));
    try std.testing.expectEqual(@as(u32, 5), selected.api_usage.toFlags());
    try std.testing.expectEqual(supported_usage, selected.usage);
    try std.testing.expectEqual(@as(usize, 3), format_calls);
    importable = false;
    try std.testing.expectError(error.NoSupportedTextureUsage, fixture.service().selectDmaBufUsage(std.testing.allocator, descriptor(&planes)));
}
fn imageInfo() vk.VkImageCreateInfo {
    return .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = vk.VK_IMAGE_TYPE_2D, .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = vk.VK_SAMPLE_COUNT_1_BIT, .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, .usage = supported_usage, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED };
}
test "DMA-BUF allocate transfers one duplicate and bind failure rolls back native resources" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const source = try temp.dir.createFile(std.testing.io, "dma-source", .{});
    defer source.close(std.testing.io);
    const fixture = Fixture.init();
    const planes = [_]dma.DmaBufPlane{.{ .fd = source.handle, .offset = 0, .stride = 16 }};
    for ([_]@TypeOf(failure){ .allocate, .bind, .none }) |boundary| {
        reset();
        failure = boundary;
        if (boundary == .none) {
            const imported = try fixture.service().importDmaBuf(std.testing.allocator, std.testing.io, descriptor(&planes), imageInfo());
            try std.testing.expectEqual(@as(vk.VkDeviceSize, 64), imported.requirements.size);
            destroyImage(null, imported.image, null);
            freeMemory(null, imported.memory, null);
        } else {
            try std.testing.expectError(error.OutOfDeviceMemory, fixture.service().importDmaBuf(std.testing.allocator, std.testing.io, descriptor(&planes), imageInfo()));
        }
        try std.testing.expectEqual(@as(usize, 1), creates);
        try std.testing.expectEqual(@as(usize, 1), destroys);
        try std.testing.expectEqual(@as(usize, if (boundary == .allocate) 0 else 1), frees);
        try std.testing.expect(allocated_fd >= 0 and allocated_fd != source.handle);
        try std.testing.expect(std.os.linux.errno(std.os.linux.fcntl(allocated_fd, std.os.linux.F.GETFD, 0)) == .BADF);
        _ = try source.stat(std.testing.io);
    }
}

test "DMA-BUF disjoint flags and wrong official plane count do not query image properties" {
    reset();
    const fixture = Fixture.init();
    var value = query();
    value.flags = vk.VK_IMAGE_CREATE_DISJOINT_BIT;
    try std.testing.expectError(error.DisjointDmaBufUnsupported, fixture.service().supportsDmaBuf(std.testing.allocator, value));
    try std.testing.expectEqual(@as(usize, 0), format_calls);
    value.flags = 0;
    value.plane_count = 2;
    try std.testing.expect(!try fixture.service().supportsDmaBuf(std.testing.allocator, value));
    try std.testing.expectEqual(@as(usize, 0), image_queries);
}
test "DMA-BUF unsupported modifier import leaves all resources untouched" {
    reset();
    const fixture = Fixture.init();
    const planes = [_]dma.DmaBufPlane{.{ .fd = 7, .offset = 0, .stride = 16 }};
    var desc = descriptor(&planes);
    desc.drm_modifier = 99;
    try std.testing.expectError(error.UnsupportedDmaBufModifier, fixture.service().importDmaBuf(std.testing.allocator, std.testing.io, desc, imageInfo()));
    try std.testing.expectEqual(@as(usize, 0), creates);
    try std.testing.expectEqual(@as(c_int, -1), allocated_fd);
}
test "DMA-BUF null plane slice is rejected before capability access" {
    var desc = descriptor(&.{});
    desc.plane_count = 1;
    desc.planes = null;
    try std.testing.expectError(error.InvalidDmaBufPlaneCount, dma.validateDmaBufDescriptor(desc));
}

test "DMA-BUF optimal features never rescue missing modifier features" {
    reset();
    const fixture = Fixture.init();
    modifier_features = 0;
    try std.testing.expect(!try fixture.service().supportsDmaBuf(std.testing.allocator, query()));
    try std.testing.expectEqual(@as(usize, 0), image_queries);
}

test "DMA-BUF import owns usage selection rather than trusting caller usage" {
    reset();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const source = try temp.dir.createFile(std.testing.io, "usage-source", .{});
    defer source.close(std.testing.io);
    const fixture = Fixture.init();
    const planes = [_]dma.DmaBufPlane{.{ .fd = source.handle, .offset = 0, .stride = 16 }};
    var info = imageInfo();
    info.usage = 0;
    const imported = try fixture.service().importDmaBuf(std.testing.allocator, std.testing.io, descriptor(&planes), info);
    defer freeMemory(null, imported.memory, null);
    defer destroyImage(null, imported.image, null);
    try std.testing.expectEqual(@as(u32, 5), imported.api_usage.toFlags());
    try std.testing.expectEqual(supported_usage, imported.usage);
    try std.testing.expectEqual(@as(usize, 3), format_calls);
}

test "DMA-BUF capability query validates FourCC and permits unknown plane count" {
    reset();
    const fixture = Fixture.init();
    var value = query();
    value.plane_count = 0;
    try std.testing.expect(try fixture.service().supportsDmaBuf(std.testing.allocator, value));
    value.format = vk.VK_FORMAT_B8G8R8A8_UNORM;
    const before = format_calls;
    try std.testing.expectError(error.InvalidExternalMemoryFormat, fixture.service().supportsDmaBuf(std.testing.allocator, value));
    try std.testing.expectEqual(before, format_calls);
}
