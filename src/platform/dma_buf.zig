//! Same-FD, non-disjoint DMA-BUF image import. The source FD remains caller-owned.
const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const fd = @import("external_memory_import.zig");
const usage_mapping = @import("external_texture_usage.zig");
const api = @import("../api/bitmask.zig");

pub const DmaBufPlane = struct { fd: c_int, offset: u64, stride: u32 };
pub const DmaBufDescriptor = struct {
    size: vk.VkExtent3D,
    drm_format: u32,
    drm_modifier: u64,
    plane_count: usize,
    planes: ?[]const DmaBufPlane,
};
pub const DeviceOptions = @import("external_memory.zig").DeviceOptions;
pub const DmaBufFormatQuery = struct {
    format: vk.VkFormat,
    drm_format: u32,
    modifier: u64,
    /// Zero asks for the driver's actual modifier plane count.
    plane_count: u32 = 0,
    usage: vk.VkImageUsageFlags,
    flags: vk.VkImageCreateFlags = 0,
};
pub const DmaBufQueryError = std.mem.Allocator.Error || dispatch.Error || dispatch.LoadError || error{
    ModifierPropertiesUnstable,
    InvalidDmaBufPlaneCount,
    InvalidDmaBufLayout,
    InvalidMemoryHandle,
    DisjointDmaBufUnsupported,
    InvalidExternalMemoryFormat,
    NoSupportedTextureUsage,
};
pub const DmaBufImportError = DmaBufQueryError || error{
    UnsupportedDmaBufModifier,
    InvalidImageCreateInfo,
    InvalidMemoryType,
    DuplicateFailed,
};
pub const SelectedUsage = struct { usage: vk.VkImageUsageFlags, api_usage: api.TextureUsage };
pub const DmaBufImportResult = struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    requirements: vk.VkMemoryRequirements,
    format: vk.VkFormat,
    usage: vk.VkImageUsageFlags,
    api_usage: api.TextureUsage,
};
pub const queue_family_index: u32 = vk.VK_QUEUE_FAMILY_EXTERNAL;

pub fn drmFourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}
pub fn formatForFourcc(format: u32) error{InvalidExternalMemoryFormat}!vk.VkFormat {
    return switch (format) {
        drmFourcc('A', 'B', '2', '4'), drmFourcc('X', 'B', '2', '4') => vk.VK_FORMAT_R8G8B8A8_UNORM,
        drmFourcc('A', 'R', '2', '4'), drmFourcc('X', 'R', '2', '4') => vk.VK_FORMAT_B8G8R8A8_UNORM,
        drmFourcc('R', '8', ' ', ' ') => vk.VK_FORMAT_R8_UNORM,
        drmFourcc('G', 'R', '8', '8') => vk.VK_FORMAT_R8G8_UNORM,
        drmFourcc('R', 'G', '1', '6') => vk.VK_FORMAT_R5G6B5_UNORM_PACK16,
        drmFourcc('A', 'B', '3', '0'), drmFourcc('X', 'B', '3', '0') => vk.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        drmFourcc('A', 'R', '3', '0'), drmFourcc('X', 'R', '3', '0') => vk.VK_FORMAT_A2R10G10B10_UNORM_PACK32,
        drmFourcc('N', 'V', '1', '2') => vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        drmFourcc('P', '0', '1', '0') => vk.VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16,
        drmFourcc('Y', 'U', '1', '2') => vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM,
        else => error.InvalidExternalMemoryFormat,
    };
}
pub fn validateDmaBufDescriptor(descriptor: DmaBufDescriptor) DmaBufQueryError!void {
    if (descriptor.plane_count == 0 or descriptor.plane_count > 4) return error.InvalidDmaBufPlaneCount;
    const planes = descriptor.planes orelse return error.InvalidDmaBufPlaneCount;
    if (planes.len != descriptor.plane_count) return error.InvalidDmaBufPlaneCount;
    if (descriptor.size.width == 0 or descriptor.size.height == 0 or descriptor.size.depth != 1) return error.InvalidDmaBufLayout;
    for (planes) |plane| {
        if (plane.fd < 0) return error.InvalidMemoryHandle;
        if (plane.fd != planes[0].fd) return error.DisjointDmaBufUnsupported;
        if (plane.stride == 0) return error.InvalidDmaBufLayout;
    }
    _ = try formatForFourcc(descriptor.drm_format);
}
const PlaneShape = struct { rows: u64, row_bytes: u64 };
fn planeShape(descriptor: DmaBufDescriptor, index: usize) PlaneShape {
    const width: u64 = descriptor.size.width;
    const height: u64 = descriptor.size.height;
    return switch (descriptor.drm_format) {
        drmFourcc('N', 'V', '1', '2') => if (index == 0) .{ .rows = height, .row_bytes = width } else if (index == 1) .{ .rows = (height + 1) / 2, .row_bytes = ((width + 1) / 2) * 2 } else .{ .rows = height, .row_bytes = 1 },
        drmFourcc('P', '0', '1', '0') => if (index == 0) .{ .rows = height, .row_bytes = width * 2 } else if (index == 1) .{ .rows = (height + 1) / 2, .row_bytes = ((width + 1) / 2) * 4 } else .{ .rows = height, .row_bytes = 1 },
        drmFourcc('Y', 'U', '1', '2') => if (index == 0) .{ .rows = height, .row_bytes = width } else if (index < 3) .{ .rows = (height + 1) / 2, .row_bytes = (width + 1) / 2 } else .{ .rows = height, .row_bytes = 1 },
        drmFourcc('R', '8', ' ', ' ') => .{ .rows = height, .row_bytes = if (index == 0) width else 1 },
        drmFourcc('G', 'R', '8', '8'), drmFourcc('R', 'G', '1', '6') => .{ .rows = height, .row_bytes = if (index == 0) width * 2 else 1 },
        else => .{ .rows = height, .row_bytes = if (index == 0) width * 4 else 1 },
    };
}
pub fn validateDmaBufLayouts(descriptor: DmaBufDescriptor, allocation_size: vk.VkDeviceSize) DmaBufQueryError!void {
    try validateDmaBufDescriptor(descriptor);
    for (descriptor.planes.?, 0..) |plane, index| {
        const shape = planeShape(descriptor, index);
        if (plane.stride < shape.row_bytes) return error.InvalidDmaBufLayout;
        const bytes = std.math.mul(u64, plane.stride, shape.rows) catch return error.InvalidDmaBufLayout;
        const end = std.math.add(u64, plane.offset, bytes) catch return error.InvalidDmaBufLayout;
        if (end > allocation_size) return error.InvalidDmaBufLayout;
    }
}

pub fn supportsDmaBuf(allocator: std.mem.Allocator, options: DeviceOptions, query: DmaBufFormatQuery) DmaBufQueryError!bool {
    if (query.plane_count > 4) return error.InvalidDmaBufPlaneCount;
    if (query.format != try formatForFourcc(query.drm_format)) return error.InvalidExternalMemoryFormat;
    if (query.flags & vk.VK_IMAGE_CREATE_DISJOINT_BIT != 0) return error.DisjointDmaBufUnsupported;
    if (!options.capabilities.external_memory_dma_buf) return false;
    const modifier = try modifierProperties(allocator, options, query) orelse return false;
    return queryImageSupport(options, query, modifier);
}

fn modifierProperties(allocator: std.mem.Allocator, options: DeviceOptions, query: DmaBufFormatQuery) DmaBufQueryError!?vk.VkDrmFormatModifierPropertiesEXT {
    const get_format = options.instance_procs.get_physical_device_format_properties2 orelse return error.MissingInstanceProc;
    var found: ?vk.VkDrmFormatModifierPropertiesEXT = null;
    for (0..3) |_| {
        var list: vk.VkDrmFormatModifierPropertiesListEXT = .{ .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT };
        var properties: vk.VkFormatProperties2 = .{ .sType = vk.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, .pNext = &list };
        get_format(options.physical_device, query.format, &properties);
        const count = list.drmFormatModifierCount;
        if (count == 0) return null;
        const entries = try allocator.alloc(vk.VkDrmFormatModifierPropertiesEXT, count);
        defer allocator.free(entries);
        list.pDrmFormatModifierProperties = entries.ptr;
        get_format(options.physical_device, query.format, &properties);
        if (list.drmFormatModifierCount != count) continue;
        var recount: vk.VkDrmFormatModifierPropertiesListEXT = .{ .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT };
        properties.pNext = &recount;
        get_format(options.physical_device, query.format, &properties);
        if (recount.drmFormatModifierCount != count) continue;
        for (entries) |entry| {
            if (entry.drmFormatModifier == query.modifier and entry.drmFormatModifierPlaneCount >= 1 and entry.drmFormatModifierPlaneCount <= 4 and (query.plane_count == 0 or entry.drmFormatModifierPlaneCount == query.plane_count)) {
                found = entry;
                break;
            }
        }
        break;
    } else return error.ModifierPropertiesUnstable;
    return found;
}

fn queryImageSupport(options: DeviceOptions, query: DmaBufFormatQuery, properties: vk.VkDrmFormatModifierPropertiesEXT) DmaBufQueryError!bool {
    var required: vk.VkFormatFeatureFlags = 0;
    if (query.usage & vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT != 0) required |= vk.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
    if (query.usage & vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT != 0) required |= vk.VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    if (query.usage & vk.VK_IMAGE_USAGE_SAMPLED_BIT != 0) required |= vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
    if (query.usage & vk.VK_IMAGE_USAGE_STORAGE_BIT != 0) required |= vk.VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT;
    if (query.usage & vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0) required |= vk.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
    if (query.usage & vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT != 0) required |= vk.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    if (properties.drmFormatModifierTilingFeatures & required != required) return false;
    const get_image = options.instance_procs.get_physical_device_image_format_properties2 orelse return error.MissingInstanceProc;
    var modifier: vk.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT, .drmFormatModifier = query.modifier, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE };
    var external: vk.VkPhysicalDeviceExternalImageFormatInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO, .pNext = &modifier, .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    var input: vk.VkPhysicalDeviceImageFormatInfo2 = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .pNext = &external, .format = query.format, .type = vk.VK_IMAGE_TYPE_2D, .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, .usage = query.usage, .flags = query.flags };
    var external_properties: vk.VkExternalImageFormatProperties = .{ .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES };
    var output: vk.VkImageFormatProperties2 = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &external_properties };
    const result = get_image(options.physical_device, &input, &output);
    if (result == vk.VK_ERROR_FORMAT_NOT_SUPPORTED) return false;
    try dispatch.checkVkSuccess(result);
    return external_properties.externalMemoryProperties.externalMemoryFeatures & vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT != 0;
}

pub fn selectDmaBufUsage(allocator: std.mem.Allocator, options: DeviceOptions, descriptor: DmaBufDescriptor) DmaBufQueryError!SelectedUsage {
    try validateDmaBufDescriptor(descriptor);
    const format = try formatForFourcc(descriptor.drm_format);
    if (!options.capabilities.external_memory_dma_buf) return error.NoSupportedTextureUsage;
    const modifier = try modifierProperties(allocator, options, .{ .format = format, .drm_format = descriptor.drm_format, .modifier = descriptor.drm_modifier, .plane_count = @intCast(descriptor.plane_count), .usage = 0 }) orelse return error.NoSupportedTextureUsage;
    return selectSupportedUsage(options, descriptor, format, 0, modifier);
}

fn selectSupportedUsage(options: DeviceOptions, descriptor: DmaBufDescriptor, format: vk.VkFormat, image_flags: vk.VkImageCreateFlags, modifier: vk.VkDrmFormatModifierPropertiesEXT) DmaBufQueryError!SelectedUsage {
    var selected: u32 = 0;
    var flags: vk.VkImageUsageFlags = 0;
    for (1..128) |candidate| {
        const mask: u32 = @intCast(candidate);
        const candidate_flags = usage_mapping.textureUsageFlagsForFormat(mask, format);
        if (candidate_flags == 0) continue;
        if (try queryImageSupport(options, .{ .format = format, .drm_format = descriptor.drm_format, .modifier = descriptor.drm_modifier, .plane_count = @intCast(descriptor.plane_count), .usage = candidate_flags, .flags = image_flags }, modifier)) {
            if (selected == 0 or usage_mapping.usageMaskPrecedes(mask, selected)) {
                selected = mask;
                flags = candidate_flags;
            }
        }
    }
    if (selected == 0) return error.NoSupportedTextureUsage;
    return .{ .usage = flags, .api_usage = api.TextureUsage.fromFlags(selected) };
}

pub fn importDmaBuf(allocator: std.mem.Allocator, io: std.Io, options: DeviceOptions, descriptor: DmaBufDescriptor, image_info: vk.VkImageCreateInfo) DmaBufImportError!DmaBufImportResult {
    try validateDmaBufDescriptor(descriptor);
    if (image_info.flags & vk.VK_IMAGE_CREATE_DISJOINT_BIT != 0) return error.DisjointDmaBufUnsupported;
    const format = try formatForFourcc(descriptor.drm_format);
    if (image_info.sType != vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO or image_info.pNext != null or image_info.imageType != vk.VK_IMAGE_TYPE_2D or image_info.format != format or image_info.extent.width != descriptor.size.width or image_info.extent.height != descriptor.size.height or image_info.extent.depth != 1 or image_info.mipLevels != 1 or image_info.arrayLayers != 1 or image_info.samples != vk.VK_SAMPLE_COUNT_1_BIT or image_info.sharingMode != vk.VK_SHARING_MODE_EXCLUSIVE or image_info.initialLayout != vk.VK_IMAGE_LAYOUT_UNDEFINED) return error.InvalidImageCreateInfo;
    if (!options.capabilities.external_memory_dma_buf) return error.UnsupportedDmaBufModifier;
    const modifier_properties = try modifierProperties(allocator, options, .{ .format = format, .drm_format = descriptor.drm_format, .modifier = descriptor.drm_modifier, .plane_count = @intCast(descriptor.plane_count), .usage = 0 }) orelse return error.UnsupportedDmaBufModifier;
    const selected = try selectSupportedUsage(options, descriptor, format, image_info.flags, modifier_properties);
    const procs = options.device_procs;
    const create = procs.create_image orelse return error.MissingDeviceProc;
    const destroy = procs.destroy_image orelse return error.MissingDeviceProc;
    const requirements_proc = procs.get_image_memory_requirements orelse return error.MissingDeviceProc;
    const fd_properties_proc = procs.get_memory_fd_properties_khr orelse return error.MissingDeviceProc;
    const allocate = procs.allocate_memory orelse return error.MissingDeviceProc;
    const free = procs.free_memory orelse return error.MissingDeviceProc;
    const bind = procs.bind_image_memory orelse return error.MissingDeviceProc;
    var layouts: [4]vk.VkSubresourceLayout = undefined;
    for (descriptor.planes.?, 0..) |plane, index| layouts[index] = .{ .offset = plane.offset, .size = 0, .rowPitch = plane.stride, .arrayPitch = 0, .depthPitch = 0 };
    var modifier: vk.VkImageDrmFormatModifierExplicitCreateInfoEXT = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT, .drmFormatModifier = descriptor.drm_modifier, .drmFormatModifierPlaneCount = @intCast(descriptor.plane_count), .pPlaneLayouts = &layouts };
    var external: vk.VkExternalMemoryImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .pNext = &modifier, .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    var info = image_info;
    info.pNext = &external;
    info.tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    info.usage = selected.usage;
    var image: vk.VkImage = null;
    try dispatch.checkVkSuccess(create(options.device, &info, null, &image));
    errdefer destroy(options.device, image, null);
    var requirements: vk.VkMemoryRequirements = undefined;
    requirements_proc(options.device, image, &requirements);
    try validateDmaBufLayouts(descriptor, requirements.size);
    var fd_properties: vk.VkMemoryFdPropertiesKHR = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR };
    try dispatch.checkVkSuccess(fd_properties_proc(options.device, vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, descriptor.planes.?[0].fd, &fd_properties));
    const bits = fd_properties.memoryTypeBits & requirements.memoryTypeBits;
    if (bits == 0) return error.InvalidMemoryType;
    const duplicate = try fd.duplicateMemoryFd(io, descriptor.planes.?[0].fd);
    var transferred = false;
    defer if (!transferred) fd.closeMemoryFd(io, duplicate);
    var dedicated: vk.VkMemoryDedicatedAllocateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = image };
    var import_info: vk.VkImportMemoryFdInfoKHR = .{ .sType = vk.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .pNext = &dedicated, .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = duplicate };
    var allocation: vk.VkMemoryAllocateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &import_info, .allocationSize = requirements.size, .memoryTypeIndex = @intCast(@ctz(bits)) };
    var memory: vk.VkDeviceMemory = null;
    try dispatch.checkVkSuccess(allocate(options.device, &allocation, null, &memory));
    transferred = true;
    errdefer free(options.device, memory, null);
    try dispatch.checkVkSuccess(bind(options.device, image, memory, 0));
    return .{ .image = image, .memory = memory, .requirements = requirements, .format = format, .usage = selected.usage, .api_usage = selected.api_usage };
}
