//! Bounded native external-image import. No API handles or reference ledger.
const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const legacy = @import("external_memory.zig");
const usage_helpers = @import("external_texture_usage.zig");
pub const dma_buf = @import("dma_buf.zig");
pub const DmaBufPlane = dma_buf.DmaBufPlane;
pub const DmaBufDescriptor = dma_buf.DmaBufDescriptor;
pub const validateDmaBufDescriptor = dma_buf.validateDmaBufDescriptor;
pub const validateDmaBufLayouts = dma_buf.validateDmaBufLayouts;
pub const drmFourcc = dma_buf.drmFourcc;
pub const usageMaskPrecedes = usage_helpers.usageMaskPrecedes;
pub const textureUsageFlags = usage_helpers.textureUsageFlags;
pub const NeedsDedicatedAllocation = legacy.NeedsDedicatedAllocation;
pub const Error = legacy.Error || std.mem.Allocator.Error || error{
    InvalidImageCreateInfo, InvalidImageCreateChain, InvalidExternalMemoryFormat,
    DuplicateFailed, MemoryBindFailed, UnsupportedExternalMemory,
};

pub const OwnedImageCreateInfo = struct {
    info: vk.VkImageCreateInfo,
    external: ?vk.VkExternalMemoryImageCreateInfo = null,
    list: ?vk.VkImageFormatListCreateInfo = null,
    stencil: ?vk.VkImageStencilUsageCreateInfo = null,
    formats: []vk.VkFormat = &.{},

    pub fn init(allocator: std.mem.Allocator, input: *const vk.VkImageCreateInfo) Error!OwnedImageCreateInfo {
        if (@intFromPtr(input) % @alignOf(vk.VkImageCreateInfo) != 0) return error.InvalidImageCreateInfo;
        try validateImageInfo(input.*);
        var owned: OwnedImageCreateInfo = .{ .info = input.* };
        errdefer owned.deinit(allocator);
        owned.info.pNext = null;
        var next = input.pNext;
        var count: u32 = 0;
        while (next) |pointer| {
            if (count == 3 or @intFromPtr(pointer) % @alignOf(vk.VkBaseInStructure) != 0) return error.InvalidImageCreateChain;
            count += 1;
            const node: *const vk.VkBaseInStructure = @ptrCast(@alignCast(pointer));
            switch (node.sType) {
                vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO => {
                    if (owned.external != null) return error.InvalidImageCreateChain;
                    const external: *const vk.VkExternalMemoryImageCreateInfo = @ptrCast(@alignCast(pointer));
                    if (external.handleTypes != vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT) return error.InvalidExternalMemoryFormat;
                    owned.external = external.*;
                    owned.external.?.pNext = null;
                },
                vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO => {
                    if (owned.list != null) return error.InvalidImageCreateChain;
                    const list: *const vk.VkImageFormatListCreateInfo = @ptrCast(@alignCast(pointer));
                    if (list.viewFormatCount > 64 or (list.viewFormatCount != 0 and list.pViewFormats == null)) return error.InvalidImageCreateChain;
                    if (list.viewFormatCount != 0) {
                        if (@intFromPtr(list.pViewFormats) % @alignOf(vk.VkFormat) != 0) return error.InvalidImageCreateChain;
                        owned.formats = try allocator.dupe(vk.VkFormat, list.pViewFormats[0..list.viewFormatCount]);
                        for (owned.formats) |format| if (format == vk.VK_FORMAT_UNDEFINED) return error.InvalidImageCreateChain;
                    }
                    owned.list = list.*;
                    owned.list.?.pNext = null;
                    owned.list.?.pViewFormats = if (owned.formats.len == 0) null else owned.formats.ptr;
                },
                vk.VK_STRUCTURE_TYPE_IMAGE_STENCIL_USAGE_CREATE_INFO => {
                    if (owned.stencil != null) return error.InvalidImageCreateChain;
                    const stencil: *const vk.VkImageStencilUsageCreateInfo = @ptrCast(@alignCast(pointer));
                    if (stencil.stencilUsage == 0) return error.InvalidImageCreateChain;
                    owned.stencil = stencil.*;
                    owned.stencil.?.pNext = null;
                },
                else => return error.InvalidImageCreateChain,
            }
            next = if (node.pNext) |p| @ptrCast(p) else null;
        }
        return owned;
    }

    pub fn borrowedInfo(self: *OwnedImageCreateInfo) vk.VkImageCreateInfo {
        var next: ?*const anyopaque = null;
        if (self.stencil) |*stencil| { stencil.pNext = next; next = stencil; }
        if (self.list) |*list| { list.pNext = next; next = list; }
        if (self.external) |*external| { external.pNext = next; next = external; }
        var info = self.info;
        info.pNext = next;
        return info;
    }

    pub fn deinit(self: *OwnedImageCreateInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.formats);
        self.* = undefined;
    }
};

pub fn validateImageInfo(info: vk.VkImageCreateInfo) Error!void {
    if (info.sType != vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO or info.imageType != vk.VK_IMAGE_TYPE_2D or
        info.extent.width == 0 or info.extent.height == 0 or info.extent.depth != 1 or info.mipLevels == 0 or
        info.mipLevels > 32 - @clz(@max(info.extent.width, info.extent.height)) or info.arrayLayers == 0 or
        info.samples != vk.VK_SAMPLE_COUNT_1_BIT or info.sharingMode != vk.VK_SHARING_MODE_EXCLUSIVE or
        info.queueFamilyIndexCount != 0 or info.pQueueFamilyIndices != null or info.usage == 0 or
        info.format == vk.VK_FORMAT_UNDEFINED or info.flags &
            (vk.VK_IMAGE_CREATE_DISJOINT_BIT | vk.VK_IMAGE_CREATE_SPARSE_BINDING_BIT |
            vk.VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT | vk.VK_IMAGE_CREATE_SPARSE_ALIASED_BIT |
            vk.VK_IMAGE_CREATE_PROTECTED_BIT) != 0 or
        (info.tiling != vk.VK_IMAGE_TILING_OPTIMAL and info.tiling != vk.VK_IMAGE_TILING_LINEAR) or
        (info.initialLayout != vk.VK_IMAGE_LAYOUT_UNDEFINED and
            !(info.initialLayout == vk.VK_IMAGE_LAYOUT_PREINITIALIZED and info.tiling == vk.VK_IMAGE_TILING_LINEAR))) return error.InvalidImageCreateInfo;
}

pub fn duplicateMemoryFd(io: std.Io, fd: std.posix.fd_t) error{DuplicateFailed}!std.posix.fd_t {
    _ = io;
    if (fd < 0) return error.DuplicateFailed;
    const result = std.os.linux.dup(fd);
    if (std.os.linux.errno(result) != .SUCCESS) return error.DuplicateFailed;
    return @intCast(result);
}
pub fn closeMemoryFd(io: std.Io, fd: std.posix.fd_t) void {
    std.debug.assert(fd >= 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(io);
}

pub const OpaqueFdDescriptor = struct {
    image_info: *const vk.VkImageCreateInfo,
    fd: std.posix.fd_t,
    allocation_size: vk.VkDeviceSize,
    memory_type_index: u32,
    dedicated_allocation: NeedsDedicatedAllocation = .detect,
};
pub const ImportedTexture = struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    format: vk.VkFormat,
    size: vk.VkExtent3D,
    usage: vk.VkImageUsageFlags,
    mip_levels: u32,
    array_layers: u32,
    sample_count: vk.VkSampleCountFlagBits,
    initial_layout: vk.VkImageLayout,
    external_queue_family: u32 = vk.VK_QUEUE_FAMILY_EXTERNAL,
};
/// The existing leaf remains the only options authority.
pub const DeviceOptions = legacy.DeviceOptions;

pub fn importOpaqueFd(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DeviceOptions,
    descriptor: OpaqueFdDescriptor,
) Error!ImportedTexture {
        if (!options.capabilities.external_memory_opaque_fd) return error.UnsupportedExternalMemory;
        if (descriptor.fd < 0) return error.InvalidMemoryHandle;
        var owned = try OwnedImageCreateInfo.init(allocator, descriptor.image_info);
        defer owned.deinit(allocator);
        var info = owned.borrowedInfo();
        const query = options.instance_procs.get_physical_device_image_format_properties2 orelse return error.MissingInstanceProc;
        var external_query: vk.VkPhysicalDeviceExternalImageFormatInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO, .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT };
        // Query the same known view-format and stencil usage constraints as creation.
        var query_list = owned.list;
        var query_stencil = owned.stencil;
        if (query_stencil) |*stencil| { stencil.pNext = null; external_query.pNext = stencil; }
        if (query_list) |*list| { list.pNext = external_query.pNext; external_query.pNext = list; }
        var format_query: vk.VkPhysicalDeviceImageFormatInfo2 = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .pNext = &external_query, .format = info.format, .type = info.imageType, .tiling = info.tiling, .usage = info.usage, .flags = info.flags };
        var external_properties: vk.VkExternalImageFormatProperties = .{ .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES };
        var properties: vk.VkImageFormatProperties2 = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &external_properties };
        const query_result = query(options.physical_device, &format_query, &properties);
        if (query_result == vk.VK_ERROR_FORMAT_NOT_SUPPORTED) return error.InvalidExternalMemoryFormat;
        try dispatch.checkVkSuccess(query_result);
        const external = external_properties.externalMemoryProperties;
        if (external.externalMemoryFeatures & vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT == 0 or
            external.compatibleHandleTypes & vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT == 0 or
            info.extent.width > properties.imageFormatProperties.maxExtent.width or info.extent.height > properties.imageFormatProperties.maxExtent.height or
            info.mipLevels > properties.imageFormatProperties.maxMipLevels or info.arrayLayers > properties.imageFormatProperties.maxArrayLayers or
            properties.imageFormatProperties.sampleCounts & info.samples == 0) return error.InvalidExternalMemoryFormat;
        const create = options.device_procs.create_image orelse return error.MissingDeviceProc;
        const destroy = options.device_procs.destroy_image orelse return error.MissingDeviceProc;
        const allocate = options.device_procs.allocate_memory orelse return error.MissingDeviceProc;
        const free = options.device_procs.free_memory orelse return error.MissingDeviceProc;
        const bind = options.device_procs.bind_image_memory orelse return error.MissingDeviceProc;
        const requirements_proc = options.device_procs.get_image_memory_requirements2 orelse return error.MissingDeviceProc;
        var external_create: vk.VkExternalMemoryImageCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT };
        if (owned.external == null) { external_create.pNext = info.pNext; info.pNext = &external_create; }
        var image: vk.VkImage = null;
        try dispatch.checkVkSuccess(create(options.device, &info, null, &image));
        errdefer destroy(options.device, image, null);
        var dedicated: vk.VkMemoryDedicatedRequirements = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS };
        var requirements: vk.VkMemoryRequirements2 = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2, .pNext = &dedicated };
        const requirements_info: vk.VkImageMemoryRequirementsInfo2 = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2, .image = image };
        requirements_proc(options.device, &requirements_info, &requirements);
        if (descriptor.allocation_size < requirements.memoryRequirements.size) return error.AllocationTooSmall;
        if (descriptor.memory_type_index >= 32 or requirements.memoryRequirements.memoryTypeBits & (@as(u32, 1) << @intCast(descriptor.memory_type_index)) == 0) return error.InvalidMemoryType;
        const dedicated_required = dedicated.requiresDedicatedAllocation != 0 or external.externalMemoryFeatures & vk.VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT != 0;
        if (descriptor.dedicated_allocation == .no and dedicated_required) return error.InvalidImageCreateInfo;
        const use_dedicated = descriptor.dedicated_allocation == .yes or dedicated_required or
            (descriptor.dedicated_allocation == .detect and dedicated.prefersDedicatedAllocation != 0);
        const fd = try duplicateMemoryFd(io, descriptor.fd);
        var consumed = false;
        defer if (!consumed) closeMemoryFd(io, fd);
        var dedicated_info: vk.VkMemoryDedicatedAllocateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = image };
        var import_info: vk.VkImportMemoryFdInfoKHR = .{ .sType = vk.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .pNext = if (use_dedicated) &dedicated_info else null, .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT, .fd = fd };
        const allocate_info: vk.VkMemoryAllocateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &import_info, .allocationSize = descriptor.allocation_size, .memoryTypeIndex = descriptor.memory_type_index };
        var memory: vk.VkDeviceMemory = null;
        try dispatch.checkVkSuccess(allocate(options.device, &allocate_info, null, &memory));
        consumed = true;
        errdefer free(options.device, memory, null);
        try dispatch.checkVkSuccess(bind(options.device, image, memory, 0));
        return .{ .image = image, .memory = memory, .format = info.format, .size = info.extent, .usage = info.usage,
            .mip_levels = info.mipLevels, .array_layers = info.arrayLayers, .sample_count = info.samples, .initial_layout = info.initialLayout };
    }
