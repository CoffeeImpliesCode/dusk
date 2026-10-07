//! Dedicated Vulkan image imports backed by a retained Android hardware buffer.
//! The caller keeps the originating VkDevice alive and retires all image views
//! and GPU work before destroyImport. No Android lock or CPU wait is performed.
const std = @import("std");
const vulkan = @import("vulkan");
const android = @import("android_platform");
const android_vk = @import("vulkan_platform_android");
const dispatch = @import("../vk/dispatch.zig");
const android_dispatch = @import("vulkan_platform_dispatch");
const external_memory = @import("external_memory.zig");
const bitmask = @import("../api/bitmask.zig");
const usage_mapping = @import("external_texture_usage.zig");

/// Android operations use the official generated function signatures.
pub const Hooks = struct {
    describe: *const @TypeOf(android.AHardwareBuffer_describe) = &android.AHardwareBuffer_describe,
    acquire: *const @TypeOf(android.AHardwareBuffer_acquire) = &android.AHardwareBuffer_acquire,
    release: *const @TypeOf(android.AHardwareBuffer_release) = &android.AHardwareBuffer_release,
};
pub const Error = dispatch.Error || dispatch.LoadError || error{
    AndroidHardwareBufferUnsupported,
    InvalidMemoryHandle,
    InvalidHardwareBufferDescriptor,
    ProtectedHardwareBufferUnsupported,
    InvalidExternalMemoryFormat,
    InvalidMemoryType,
    NoSupportedTextureUsage,
};
pub const Description = struct {
    width: u32,
    height: u32,
    layers: u32,
    format: u32,
    usage: u64,
};
pub const Properties = struct {
    allocation_size: vulkan.VkDeviceSize,
    memory_type_bits: u32,
    format: vulkan.VkFormat,
    external_format: u64,
    format_features: vulkan.VkFormatFeatureFlags,
    components: vulkan.VkComponentMapping,
    ycbcr_model: vulkan.VkSamplerYcbcrModelConversion,
    ycbcr_range: vulkan.VkSamplerYcbcrRange,
    x_chroma_offset: vulkan.VkChromaLocation,
    y_chroma_offset: vulkan.VkChromaLocation,
    chroma_filter: vulkan.VkFilter,
    explicit_reconstruction: bool,
    explicit_reconstruction_forceable: bool,
    /// No optional reconstruction mode is forced by import.
    force_explicit_reconstruction: bool,
};
pub const ImportResult = struct {
    image: vulkan.VkImage,
    memory: vulkan.VkDeviceMemory,
    retained_handle: ?*android.AHardwareBuffer,
    description: Description,
    properties: Properties,
    api_usage: bitmask.TextureUsage,
    vk_usage: vulkan.VkImageUsageFlags,
};
pub const queue_family_index: u32 = vulkan.VK_QUEUE_FAMILY_FOREIGN_EXT;

pub const AndroidHardwareBufferService = struct {
    options: external_memory.DeviceOptions,
    hooks: Hooks = .{},

    pub fn init(options: external_memory.DeviceOptions) AndroidHardwareBufferService {
        return .{ .options = options };
    }
    pub fn initWithHooks(
        options: external_memory.DeviceOptions,
        hooks: Hooks,
    ) AndroidHardwareBufferService {
        return .{ .options = options, .hooks = hooks };
    }
    pub fn isSupported(self: AndroidHardwareBufferService) bool {
        return self.options.capabilities.external_memory_ahb;
    }
    pub fn describe(self: AndroidHardwareBufferService, handle: ?*android.AHardwareBuffer) Error!Description {
        const buffer = handle orelse return error.InvalidMemoryHandle;
        if (!self.isSupported()) return error.AndroidHardwareBufferUnsupported;
        var desc = std.mem.zeroes(android.AHardwareBuffer_Desc);
        self.hooks.describe(buffer, &desc);
        if (desc.width == 0 or desc.height == 0 or desc.layers == 0 or
            desc.format == android.AHARDWAREBUFFER_FORMAT_BLOB or
            desc.usage & (android.AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | android.AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER) == 0)
            return error.InvalidHardwareBufferDescriptor;
        if (desc.usage & android.AHARDWAREBUFFER_USAGE_PROTECTED_CONTENT != 0)
            return error.ProtectedHardwareBufferUnsupported;
        if (desc.format == android.AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420 or
            desc.format == android.AHARDWAREBUFFER_FORMAT_YCbCr_P010 or
            desc.format == android.AHARDWAREBUFFER_FORMAT_YCbCr_P210)
        {
            const height_must_be_even = desc.format != android.AHARDWAREBUFFER_FORMAT_YCbCr_P210;
            if (desc.width % 2 != 0 or (height_must_be_even and desc.height % 2 != 0) or desc.layers != 1)
                return error.InvalidHardwareBufferDescriptor;
        }
        return .{ .width = desc.width, .height = desc.height, .layers = desc.layers, .format = desc.format, .usage = desc.usage };
    }
    pub fn getProperties(self: AndroidHardwareBufferService, handle: ?*android.AHardwareBuffer) Error!Properties {
        const buffer = handle orelse return error.InvalidMemoryHandle;
        if (!self.isSupported()) return error.AndroidHardwareBufferUnsupported;
        var format = std.mem.zeroes(android_vk.VkAndroidHardwareBufferFormatPropertiesANDROID);
        format.sType = android_vk.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;
        var props = std.mem.zeroes(android_vk.VkAndroidHardwareBufferPropertiesANDROID);
        props.sType = android_vk.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
        props.pNext = &format;
        try dispatch.checkVkSuccess(try self.options.platform_device_procs
            .getAndroidHardwareBufferProperties(self.options.device, buffer, &props));
        if (props.allocationSize == 0 or props.memoryTypeBits == 0) return error.InvalidMemoryType;
        if (format.format == android_vk.VK_FORMAT_UNDEFINED and
            (format.externalFormat == 0 or !self.options.capabilities.sampler_ycbcr_conversion))
            return error.InvalidExternalMemoryFormat;
        return .{
            .allocation_size = props.allocationSize,
            .memory_type_bits = props.memoryTypeBits,
            .format = format.format,
            .external_format = format.externalFormat,
            .format_features = format.formatFeatures,
            .components = .{ .r = format.samplerYcbcrConversionComponents.r, .g = format.samplerYcbcrConversionComponents.g, .b = format.samplerYcbcrConversionComponents.b, .a = format.samplerYcbcrConversionComponents.a },
            .ycbcr_model = format.suggestedYcbcrModel,
            .ycbcr_range = format.suggestedYcbcrRange,
            .x_chroma_offset = format.suggestedXChromaOffset,
            .y_chroma_offset = format.suggestedYChromaOffset,
            .chroma_filter = if (format.formatFeatures & vulkan.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER_BIT != 0) vulkan.VK_FILTER_LINEAR else vulkan.VK_FILTER_NEAREST,
            .explicit_reconstruction = format.formatFeatures & vulkan.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_CHROMA_RECONSTRUCTION_EXPLICIT_BIT != 0,
            .explicit_reconstruction_forceable = format.formatFeatures & vulkan.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_CHROMA_RECONSTRUCTION_EXPLICIT_FORCEABLE_BIT != 0,
            .force_explicit_reconstruction = false,
        };
    }

    /// Tests all seven-bit combinations. Equal-size supported sets choose the
    /// smaller API mask; unsupported driver formats are not driver failures.
    pub fn selectUsage(self: AndroidHardwareBufferService, desc: Description, props: Properties) Error!bitmask.TextureUsage {
        var best: u32 = 0;
        var mask: u32 = 1;
        while (mask < 128) : (mask += 1) {
            if (try self.supportsUsage(desc, props, mask)) {
                if (best == 0 or usage_mapping.usageMaskPrecedes(mask, best)) best = mask;
            }
        }
        if (best == 0) return error.NoSupportedTextureUsage;
        return bitmask.TextureUsage.fromFlags(best);
    }
    fn supportsUsage(self: AndroidHardwareBufferService, desc: Description, props: Properties, mask: u32) Error!bool {
        const flags = usage_mapping.textureUsageFlagsForFormat(mask, props.format);
        if (flags == 0) return false;
        if (mask & 4 != 0 and desc.usage & android.AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE == 0) return false;
        if (mask & (16 | 32) != 0 and desc.usage & android.AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER == 0) return false;
        if (props.format == vulkan.VK_FORMAT_UNDEFINED) {
            // VkPhysicalDeviceImageFormatInfo2 cannot query VK_FORMAT_UNDEFINED.
            // For opaque Android external formats the AHB property query is the
            // authority: Vulkan permits only sampled usage and optimal tiling.
            return mask == 4 and desc.layers == 1 and
                props.format_features & vulkan.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT != 0;
        }
        const query = self.options.instance_procs.get_physical_device_image_format_properties2 orelse return error.MissingInstanceProc;
        var external: vulkan.VkPhysicalDeviceExternalImageFormatInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
            .handleType = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID,
        };
        var info: vulkan.VkPhysicalDeviceImageFormatInfo2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
            .pNext = &external,
            .format = props.format,
            .type = vulkan.VK_IMAGE_TYPE_2D,
            .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
            .usage = flags,
        };
        var android_usage = std.mem.zeroes(android_vk.VkAndroidHardwareBufferUsageANDROID);
        android_usage.sType = android_vk.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_USAGE_ANDROID;
        var external_props: vulkan.VkExternalImageFormatProperties = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
            .pNext = &android_usage,
        };
        var image_props: vulkan.VkImageFormatProperties2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
            .pNext = &external_props,
        };
        const result = query(self.options.physical_device, &info, &image_props);
        if (result == vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED) return false;
        try dispatch.checkVkSuccess(result);
        const required_usage = android_usage.androidHardwareBufferUsage & ~@as(u64, android.AHARDWAREBUFFER_USAGE_CPU_READ_MASK | android.AHARDWAREBUFFER_USAGE_CPU_WRITE_MASK);
        const memory = external_props.externalMemoryProperties;
        const limits = image_props.imageFormatProperties;
        return memory.externalMemoryFeatures & vulkan.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT != 0 and
            memory.compatibleHandleTypes & vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID != 0 and
            required_usage & ~desc.usage == 0 and
            desc.width <= limits.maxExtent.width and desc.height <= limits.maxExtent.height and
            desc.layers <= limits.maxArrayLayers and limits.maxMipLevels >= 1 and
            limits.sampleCounts & vulkan.VK_SAMPLE_COUNT_1_BIT != 0;
    }

    pub fn importImage(self: AndroidHardwareBufferService, handle: ?*android.AHardwareBuffer) Error!ImportResult {
        const desc = try self.describe(handle);
        const buffer = handle.?;
        // Resolve cleanup hooks before acquiring resources so rollback cannot fail.
        const create = self.options.device_procs.create_image orelse return error.MissingDeviceProc;
        const destroy = self.options.device_procs.destroy_image orelse return error.MissingDeviceProc;
        const allocate = self.options.device_procs.allocate_memory orelse return error.MissingDeviceProc;
        const free = self.options.device_procs.free_memory orelse return error.MissingDeviceProc;
        const bind = self.options.device_procs.bind_image_memory orelse return error.MissingDeviceProc;
        const memory_properties = self.options.instance_procs.get_physical_device_memory_properties orelse return error.MissingInstanceProc;
        self.hooks.acquire(buffer);
        errdefer self.hooks.release(buffer);
        const props = try self.getProperties(buffer);
        const api_usage = try self.selectUsage(desc, props);
        const vk_usage = usage_mapping.textureUsageFlagsForFormat(api_usage.toFlags(), props.format);
        var types: vulkan.VkPhysicalDeviceMemoryProperties = undefined;
        memory_properties(self.options.physical_device, &types);
        if (types.memoryTypeCount == 0 or types.memoryTypeCount > 32) return error.InvalidMemoryType;
        const valid_bits = if (types.memoryTypeCount == 32) props.memory_type_bits else props.memory_type_bits & ((@as(u32, 1) << @intCast(types.memoryTypeCount)) - 1);
        if (valid_bits == 0) return error.InvalidMemoryType;
        var external_format = std.mem.zeroes(android_vk.VkExternalFormatANDROID);
        external_format.sType = android_vk.VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID;
        external_format.externalFormat = props.external_format;
        var external: vulkan.VkExternalMemoryImageCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = if (props.format == vulkan.VK_FORMAT_UNDEFINED) &external_format else null,
            .handleTypes = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID,
        };
        var info: vulkan.VkImageCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external,
            .imageType = vulkan.VK_IMAGE_TYPE_2D,
            .format = props.format,
            .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = desc.layers,
            .samples = vulkan.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk_usage,
            .sharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: vulkan.VkImage = null;
        try dispatch.checkVkSuccess(create(self.options.device, &info, null, &image));
        // The image must be destroyed before imported memory even on bind failure.
        var memory: vulkan.VkDeviceMemory = null;
        errdefer {
            destroy(self.options.device, image, null);
            if (memory != null) free(self.options.device, memory, null);
        }
        var dedicated: vulkan.VkMemoryDedicatedAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = image,
        };
        var imported = std.mem.zeroes(android_vk.VkImportAndroidHardwareBufferInfoANDROID);
        imported.sType = android_vk.VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID;
        imported.pNext = &dedicated;
        imported.buffer = android_dispatch.ahbForVulkan(buffer);
        var allocation: vulkan.VkMemoryAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &imported,
            .allocationSize = props.allocation_size,
            .memoryTypeIndex = @ctz(valid_bits),
        };
        // AHB memory requirements cannot be queried before bind. Use the exact
        // allocation size and memoryTypeBits returned by the Android query.
        try dispatch.checkVkSuccess(allocate(self.options.device, &allocation, null, &memory));
        try dispatch.checkVkSuccess(bind(self.options.device, image, memory, 0));
        return .{ .image = image, .memory = memory, .retained_handle = buffer, .description = desc, .properties = props, .api_usage = api_usage, .vk_usage = vk_usage };
    }
    pub fn destroyImport(self: AndroidHardwareBufferService, imported: *ImportResult) void {
        const buffer = imported.retained_handle orelse return;
        self.options.device_procs.destroy_image.?(self.options.device, imported.image, null);
        self.options.device_procs.free_memory.?(self.options.device, imported.memory, null);
        self.hooks.release(buffer);
        imported.image = null;
        imported.memory = null;
        imported.retained_handle = null;
    }
};
