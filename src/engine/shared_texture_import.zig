//! Descriptor translation only. The native leaves own OS transfer and Vulkan import.
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const api = @import("../api/api.zig");
const device_mod = @import("device.zig");
const shared = @import("shared_texture_memory.zig");
const leaf = @import("../platform/external_memory_import.zig");
const dma = @import("../platform/dma_buf.zig");
const formats = @import("vulkan_format.zig");
const usage_mapping = @import("../platform/external_texture_usage.zig");
const is_android = builtin.abi == .android;
const android_leaf = if (is_android) @import("../platform/android_hardware_buffer.zig") else struct {
    pub const Error = error{};
};

pub const ImportError = leaf.Error || dma.DmaBufImportError || android_leaf.Error ||
    device_mod.AdmissionError || error{
    DescriptorChainEmpty,
    MultipleMemoryHandleArms,
    UnsupportedMemoryHandleType,
    InvalidAHardwareBuffer,
    AHardwareBufferUnavailable,
    NativeBackendUnavailable,
};
pub const Arm = enum { opaque_fd, dma_buf, android_hardware_buffer };

pub fn validateDescriptor(descriptor: *const api.descriptors.SharedTextureMemoryDescriptorChain) ImportError!Arm {
    const arm_count: usize = @intFromBool(descriptor.shared_texture_memory_opaque_fd_descriptor != null) +
        @as(usize, @intFromBool(descriptor.shared_texture_memory_dma_buf_descriptor != null)) +
        @as(usize, @intFromBool(descriptor.shared_texture_memory_a_hardware_buffer_descriptor != null)) +
        @as(usize, @intFromBool(descriptor.shared_texture_memory_zircon_handle_descriptor != null)) +
        @as(usize, @intFromBool(descriptor.shared_texture_memory_dxgi_shared_handle_descriptor != null)) +
        @as(usize, @intFromBool(descriptor.shared_texture_memory_io_surface_descriptor != null)) +
        @as(usize, @intFromBool(descriptor.shared_texture_memory_egl_image_descriptor != null));
    if (arm_count == 0) return error.DescriptorChainEmpty;
    if (arm_count != 1) return error.MultipleMemoryHandleArms;
    if (descriptor.shared_texture_memory_opaque_fd_descriptor) |opaque_fd| {
        const pointer = opaque_fd.vk_image_create_info orelse return error.InvalidImageCreateInfo;
        if (@intFromPtr(pointer) % @alignOf(vk.VkImageCreateInfo) != 0)
            return error.InvalidImageCreateInfo;
        if (opaque_fd.memory_fd < 0) return error.InvalidMemoryHandle;
        if (descriptor.shared_texture_memory_vk_dedicated_allocation_descriptor) |dedicated| {
            if (dedicated.dedicated_allocation != opaque_fd.dedicated_allocation)
                return error.InvalidImageCreateInfo;
        }
        return .opaque_fd;
    }
    if (descriptor.shared_texture_memory_vk_dedicated_allocation_descriptor != null)
        return error.InvalidImageCreateInfo;
    if (descriptor.shared_texture_memory_dma_buf_descriptor) |buffer| {
        var planes: [4]dma.DmaBufPlane = undefined;
        try dma.validateDmaBufDescriptor(try dmaDescriptor(buffer, &planes));
        return .dma_buf;
    }
    if (descriptor.shared_texture_memory_a_hardware_buffer_descriptor) |buffer| {
        if (buffer.handle == null) return error.InvalidAHardwareBuffer;
        return .android_hardware_buffer;
    }
    return error.UnsupportedMemoryHandleType;
}

/// Invert the existing format authority. Prefer the precise depth format over its API alias.
pub fn apiFormat(format: vk.VkFormat) error{InvalidExternalMemoryFormat}!api.enums.TextureFormat {
    if (format == vk.VK_FORMAT_D32_SFLOAT) return .depth32_float;
    inline for (@typeInfo(api.enums.TextureFormat).@"enum".field_values) |field_value| {
        const candidate: api.enums.TextureFormat = @fromBackingInt(@intCast(field_value));
        if (comptime candidate != .undefined_) {
            if (formats.vkFormat(candidate) == format) return candidate;
        }
    }
    return error.InvalidExternalMemoryFormat;
}

/// OpaqueFD supplies native usage, not API-only usage promises.
pub fn apiUsage(flags: vk.VkImageUsageFlags, format: vk.VkFormat) error{InvalidImageCreateInfo}!api.bitmask.TextureUsage {
    if (flags == 0) return error.InvalidImageCreateInfo;
    var mask: u32 = 1;
    while (mask < 128) : (mask += 1) {
        if (usage_mapping.textureUsageFlagsForFormat(mask, format) == flags)
            return api.bitmask.TextureUsage.fromFlags(mask);
    }
    return error.InvalidImageCreateInfo;
}

fn dmaDescriptor(buffer: api.descriptors.SharedTextureMemoryDmaBufDescriptor, storage: *[4]dma.DmaBufPlane) ImportError!dma.DmaBufDescriptor {
    if (buffer.plane_count == 0 or buffer.plane_count > storage.len)
        return error.InvalidDmaBufPlaneCount;
    const planes = buffer.planes orelse return error.InvalidDmaBufPlaneCount;
    if (planes.len != buffer.plane_count) return error.InvalidDmaBufPlaneCount;
    for (planes, 0..) |plane, index| {
        storage[index] = .{ .fd = plane.fd, .offset = plane.offset, .stride = plane.stride };
    }
    return .{ .size = .{ .width = buffer.size.width, .height = buffer.size.height, .depth = buffer.size.depth_or_array_layers }, .drm_format = buffer.drm_format, .drm_modifier = buffer.drm_modifier, .plane_count = buffer.plane_count, .planes = storage[0..buffer.plane_count] };
}

fn aspectMask(format: api.enums.TextureFormat) vk.VkImageAspectFlags {
    return switch (format) {
        .depth16_unorm, .depth24_plus, .depth32_float => vk.VK_IMAGE_ASPECT_DEPTH_BIT,
        .depth24_plus_stencil8, .depth32_float_stencil8 => vk.VK_IMAGE_ASPECT_DEPTH_BIT | vk.VK_IMAGE_ASPECT_STENCIL_BIT,
        .stencil8 => vk.VK_IMAGE_ASPECT_STENCIL_BIT,
        else => vk.VK_IMAGE_ASPECT_COLOR_BIT,
    };
}

pub fn importImage(allocator: std.mem.Allocator, io: std.Io, device: *device_mod.Device, descriptor: *const api.descriptors.SharedTextureMemoryDescriptorChain) ImportError!shared.ImportedImage {
    const arm = try validateDescriptor(descriptor);
    const options = try device.externalMemoryOptions();
    switch (arm) {
        .opaque_fd => {
            const opaque_fd = descriptor.shared_texture_memory_opaque_fd_descriptor.?;
            const info: *const vk.VkImageCreateInfo = @ptrCast(@alignCast(opaque_fd.vk_image_create_info.?));
            // All API projections are checked before the native allocation/FD boundary.
            const format = try apiFormat(info.format);
            const usage = try apiUsage(info.usage, info.format);
            const imported = try leaf.importOpaqueFd(allocator, io, options, .{
                .image_info = info,
                .fd = opaque_fd.memory_fd,
                .allocation_size = opaque_fd.allocation_size,
                .memory_type_index = opaque_fd.memory_type_index,
                .dedicated_allocation = if (opaque_fd.dedicated_allocation) .yes else .no,
            });
            return .{ .device = options.device, .procs = options.device_procs, .image = imported.image, .memory = imported.memory, .format = imported.format, .properties = .{ .format = format, .usage = usage, .size = .{ .width = imported.size.width, .height = imported.size.height, .depth_or_array_layers = imported.array_layers } }, .mip_levels = imported.mip_levels, .array_layers = imported.array_layers, .sample_count = imported.sample_count, .aspect_mask = aspectMask(format), .external_queue_family = imported.external_queue_family, .initial_layout = imported.initial_layout, .provenance = .opaque_fd };
        },
        .dma_buf => {
            var planes: [4]dma.DmaBufPlane = undefined;
            const buffer = try dmaDescriptor(descriptor.shared_texture_memory_dma_buf_descriptor.?, &planes);
            const native_format = try dma.formatForFourcc(buffer.drm_format);
            const format = try apiFormat(native_format);
            const info: vk.VkImageCreateInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .imageType = vk.VK_IMAGE_TYPE_2D,
                .format = native_format,
                .extent = buffer.size,
                .mipLevels = 1,
                .arrayLayers = 1,
                .samples = vk.VK_SAMPLE_COUNT_1_BIT,
                .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
                .usage = 0,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
                .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            const imported = try dma.importDmaBuf(allocator, io, options, buffer, info);
            return .{ .device = options.device, .procs = options.device_procs, .image = imported.image, .memory = imported.memory, .format = imported.format, .properties = .{ .format = format, .usage = imported.api_usage, .size = .{ .width = buffer.size.width, .height = buffer.size.height, .depth_or_array_layers = 1 } }, .mip_levels = 1, .array_layers = 1, .aspect_mask = aspectMask(format), .external_queue_family = vk.VK_QUEUE_FAMILY_EXTERNAL, .initial_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED, .provenance = .dma_buf };
        },
        .android_hardware_buffer => {
            if (comptime !is_android) return error.AHardwareBufferUnavailable;
            return importAndroid(device, descriptor);
        },
    }
}

fn importAndroid(device: *device_mod.Device, descriptor: *const api.descriptors.SharedTextureMemoryDescriptorChain) ImportError!shared.ImportedImage {
    if (comptime !is_android) return error.AHardwareBufferUnavailable;
    const options = try device.externalMemoryOptions();
    const service = android_leaf.AndroidHardwareBufferService.init(options);
    var native = try service.importImage(@ptrCast(@alignCast(descriptor.shared_texture_memory_a_hardware_buffer_descriptor.?.handle.?)));
    errdefer service.destroyImport(&native);
    const properties = native.properties;
    const format: api.enums.TextureFormat = if (properties.format == vk.VK_FORMAT_UNDEFINED and
        properties.external_format != 0) .undefined_ else try apiFormat(properties.format);
    const ycbcr: api.descriptors.YCbCrVkDescriptor = .{
        .vk_format = properties.format,
        .external_format = properties.external_format,
        .vk_y_cb_cr_model = properties.ycbcr_model,
        .vk_y_cb_cr_range = properties.ycbcr_range,
        .vk_component_swizzle_red = properties.components.r,
        .vk_component_swizzle_green = properties.components.g,
        .vk_component_swizzle_blue = properties.components.b,
        .vk_component_swizzle_alpha = properties.components.a,
        .vk_x_chroma_offset = properties.x_chroma_offset,
        .vk_y_chroma_offset = properties.y_chroma_offset,
        .vk_chroma_filter = if (properties.chroma_filter == vk.VK_FILTER_LINEAR) .linear else .nearest,
        .force_explicit_reconstruction = properties.force_explicit_reconstruction,
    };
    return .{ .device = options.device, .procs = options.device_procs, .image = native.image, .memory = native.memory, .format = properties.format, .properties = .{ .format = format, .usage = native.api_usage, .size = .{ .width = native.description.width, .height = native.description.height, .depth_or_array_layers = native.description.layers } }, .mip_levels = 1, .array_layers = native.description.layers, .aspect_mask = aspectMask(format), .external_queue_family = vk.VK_QUEUE_FAMILY_FOREIGN_EXT, .initial_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED, .provenance = .android_hardware_buffer, .platform_retain = native.retained_handle, .release_platform_retain = releaseAndroid, .ycbcr = if (properties.external_format != 0) ycbcr else null };
}

fn releaseAndroid(pointer: *anyopaque) void {
    if (comptime is_android) {
        const android = @import("android_platform");
        android.AHardwareBuffer_release(@ptrCast(@alignCast(pointer)));
    }
}

pub fn destroyImported(imported: *shared.ImportedImage) void {
    if (imported.image != null) imported.procs.destroy_image.?(imported.device, imported.image, null);
    if (imported.memory != null) imported.procs.free_memory.?(imported.device, imported.memory, null);
    if (imported.platform_retain) |retain| imported.release_platform_retain.?(retain);
    imported.image = null;
    imported.memory = null;
    imported.platform_retain = null;
    imported.release_platform_retain = null;
}
