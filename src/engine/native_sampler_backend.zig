//! Owns Vulkan sampler and optional YCbCr conversion handles, never core headers.
//! The stable device and cleanup callback outlive every payload.
const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const api = @import("../api/api.zig");
const vulkan_device = @import("vulkan_device.zig");

pub const Error = dispatch.Error || error{
    MissingDeviceProc,
    MissingInstanceProc,
    SamplerCreationReturnedNull,
    SamplerConversionCreationReturnedNull,
    SamplerAnisotropyUnsupported,
    SamplerAnisotropyAboveLimit,
    SamplerYCbCrUnsupported,
    SamplerYCbCrDescriptorInvalid,
    SamplerYCbCrFormatUnsupported,
    SamplerYCbCrExternalFormatUnsupported,
    SamplerYCbCrImageTilingUnsupported,
    SamplerYCbCrDescriptorCountInvalid,
};

/// Full normalized value identity. Floats are finite and zero has one representation.
/// Labels and backend handles do not participate in identity.
pub const SemanticKey = struct {
    address_mode_u: api.AddressMode,
    address_mode_v: api.AddressMode,
    address_mode_w: api.AddressMode,
    mag_filter: api.FilterMode,
    min_filter: api.FilterMode,
    mipmap_filter: api.MipmapFilterMode,
    lod_min_clamp: f32,
    lod_max_clamp: f32,
    compare_function: api.CompareFunction,
    max_anisotropy: u16,
    y_cb_cr: ?api.descriptors.YCbCrVkDescriptor,

    /// Compares every semantic field, including conversion presence and all conversion fields.
    pub fn eql(self: SemanticKey, other: SemanticKey) bool {
        inline for (@typeInfo(SemanticKey).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "y_cb_cr")) {
                if ((self.y_cb_cr == null) != (other.y_cb_cr == null)) return false;
                if (self.y_cb_cr) |conversion| {
                    inline for (@typeInfo(api.descriptors.YCbCrVkDescriptor).@"struct".fields) |part| {
                        if (@field(conversion, part.name) != @field(other.y_cb_cr.?, part.name)) return false;
                    }
                }
            } else if (@field(self, field.name) != @field(other, field.name)) return false;
        }
        return true;
    }
    pub fn hash(self: SemanticKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        inline for (@typeInfo(SemanticKey).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "y_cb_cr")) {
                hashScalar(&hasher, self.y_cb_cr != null);
                if (self.y_cb_cr) |conversion| {
                    inline for (@typeInfo(api.descriptors.YCbCrVkDescriptor).@"struct".fields) |part| {
                        hashScalar(&hasher, @field(conversion, part.name));
                    }
                }
            } else hashScalar(&hasher, @field(self, field.name));
        }
        return hasher.final();
    }
};

fn hashScalar(hasher: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => {
            const integer = @intFromEnum(value);
            hasher.update(std.mem.asBytes(&integer));
        },
        .bool => {
            const integer: u8 = @intFromBool(value);
            hasher.update(&.{integer});
        },
        .float => {
            const normalized: f32 = if (value == 0) 0 else value;
            hasher.update(std.mem.asBytes(&normalized));
        },
        .int => hasher.update(std.mem.asBytes(&value)),
        else => @compileError("unsupported sampler key scalar"),
    }
}

/// Borrowed real dispatch, enabled features, and queried physical limits.
pub const Backend = struct {
    procs: *const dispatch.DeviceProcs,
    handle: vk.VkDevice,
    api_version: u32,
    instance_procs: *const dispatch.InstanceProcs,
    physical: vk.VkPhysicalDevice,
    anisotropy_enabled: bool,
    max_anisotropy: f32,
    y_cb_cr_enabled: bool,
    handles: *vulkan_device.HandleSet,
    sampler_allocation_count: *u32,
    max_sampler_allocation_count: u32,
    cleanup_context: ?*anyopaque = null,
    /// Runs under the original object guard. Must not reenter it.
    record_cleanup_error: ?*const fn (*anyopaque, Error) void = null,

    pub fn fromDevice(device: *vulkan_device.Device) Backend {
        return .{
            .procs = device.procs,
            .handle = device.vk_device,
            .api_version = device.api_version,
            .instance_procs = device.instance.procs,
            .physical = device.physical.handle,
            .anisotropy_enabled = device.enabled_features.samplerAnisotropy == vk.VK_TRUE,
            .max_anisotropy = device.physical.properties.limits.maxSamplerAnisotropy,
            .y_cb_cr_enabled = device.sampler_y_cb_cr_enabled,
            .handles = device.handles,
            .sampler_allocation_count = &device.sampler_allocation_count,
            .max_sampler_allocation_count = device.physical.properties.limits.maxSamplerAllocationCount,
        };
    }
    pub fn recordCleanup(self: Backend, err: Error) void {
        if (self.record_cleanup_error) |callback| callback(self.cleanup_context.?, err);
    }

    /// Rejects unsupported features before allocation or handle creation.
    pub fn validate(self: Backend, key: SemanticKey) Error!void {
        return self.validateWithTiling(key, null);
    }

    /// Validates conversion sampling against the actual image tiling, not potential features.
    /// Only ordinary linear and optimal tiling are supported by this backend.
    pub fn validateForTiling(self: Backend, key: SemanticKey, tiling: vk.VkImageTiling) Error!void {
        switch (tiling) {
            vk.VK_IMAGE_TILING_LINEAR, vk.VK_IMAGE_TILING_OPTIMAL => {},
            else => return error.SamplerYCbCrImageTilingUnsupported,
        }
        return self.validateWithTiling(key, tiling);
    }

    /// Queries the exact image format/type/tiling/usage/flags supplied by the caller.
    /// No fallback count is invented. Native query errors and invalid output remain failures.
    pub fn combinedImageSamplerDescriptorCount(
        self: Backend,
        info: *const vk.VkPhysicalDeviceImageFormatInfo2,
    ) Error!u32 {
        if (!self.y_cb_cr_enabled or self.api_version < vk.VK_API_VERSION_1_1) {
            return error.SamplerYCbCrUnsupported;
        }
        const query = self.instance_procs.get_physical_device_image_format_properties2 orelse
            return error.MissingInstanceProc;
        const format_code = std.math.cast(u32, info.format) orelse
            return error.SamplerYCbCrFormatUnsupported;
        const format = conversionFormat(format_code, self.api_version) orelse
            return error.SamplerYCbCrFormatUnsupported;
        var conversion: vk.VkSamplerYcbcrConversionImageFormatProperties = .{
            .sType = @intCast(vk.VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_IMAGE_FORMAT_PROPERTIES),
            .pNext = null,
            .combinedImageSamplerDescriptorCount = 0,
        };
        var properties: vk.VkImageFormatProperties2 = .{
            .sType = @intCast(vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2),
            .pNext = @ptrCast(&conversion),
            .imageFormatProperties = std.mem.zeroes(vk.VkImageFormatProperties),
        };
        try dispatch.checkVkSuccess(query(self.physical, info, &properties));
        const count = conversion.combinedImageSamplerDescriptorCount;
        if (count == 0 or count > format.plane_count) return error.SamplerYCbCrDescriptorCountInvalid;
        return count;
    }

    fn validateWithTiling(self: Backend, key: SemanticKey, tiling: ?vk.VkImageTiling) Error!void {
        if (key.max_anisotropy > 1) {
            if (!self.anisotropy_enabled) return error.SamplerAnisotropyUnsupported;
            if (@as(f32, @floatFromInt(key.max_anisotropy)) > self.max_anisotropy) return error.SamplerAnisotropyAboveLimit;
        }
        if (key.y_cb_cr) |conversion| {
            if (!self.y_cb_cr_enabled) return error.SamplerYCbCrUnsupported;
            if (conversion.external_format != 0) return error.SamplerYCbCrExternalFormatUnsupported;
            const format = conversionFormat(conversion.vk_format, self.api_version) orelse
                return error.SamplerYCbCrFormatUnsupported;
            if (conversion.vk_format == vk.VK_FORMAT_UNDEFINED or
                conversion.vk_y_cb_cr_model > vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_2020 or
                conversion.vk_y_cb_cr_range > vk.VK_SAMPLER_YCBCR_RANGE_ITU_NARROW or
                conversion.vk_component_swizzle_red > vk.VK_COMPONENT_SWIZZLE_A or
                conversion.vk_component_swizzle_green > vk.VK_COMPONENT_SWIZZLE_A or
                conversion.vk_component_swizzle_blue > vk.VK_COMPONENT_SWIZZLE_A or
                conversion.vk_component_swizzle_alpha > vk.VK_COMPONENT_SWIZZLE_A or
                conversion.vk_x_chroma_offset > vk.VK_CHROMA_LOCATION_MIDPOINT or
                conversion.vk_y_chroma_offset > vk.VK_CHROMA_LOCATION_MIDPOINT or
                conversion.vk_chroma_filter == .undefined_ or key.max_anisotropy != 1 or
                key.compare_function != .undefined_ or key.address_mode_u != .clamp_to_edge or
                key.address_mode_v != .clamp_to_edge or key.address_mode_w != .clamp_to_edge)
            {
                return error.SamplerYCbCrDescriptorInvalid;
            }
            try validateComponents(conversion, format);
            const query = self.instance_procs.get_physical_device_format_properties orelse return error.MissingInstanceProc;
            var properties: vk.VkFormatProperties = undefined;
            query(self.physical, @intCast(conversion.vk_format), &properties);
            const flags = if (tiling) |selected| switch (selected) {
                vk.VK_IMAGE_TILING_LINEAR => properties.linearTilingFeatures,
                vk.VK_IMAGE_TILING_OPTIMAL => properties.optimalTilingFeatures,
                else => unreachable,
            } else properties.linearTilingFeatures | properties.optimalTilingFeatures;
            try validateConversionFeatures(conversion, format, flags, .{
                .min = key.min_filter,
                .mag = key.mag_filter,
            });
        }
    }
};

/// Owns both native handles. Copying does not make a second owner.
pub const Payload = struct {
    backend: Backend,
    sampler: vk.VkSampler = null,
    conversion: vk.VkSamplerYcbcrConversion = null,

    /// Creates from a validated normalized sampler key under the original object guard.
    /// On error no handle escapes. Cleanup failures reach the backend's reporting callback.
    /// Destroy the returned owner once, before its borrowed device is released.
    pub fn create(backend: Backend, key: SemanticKey) Error!Payload {
        try backend.validate(key);
        if (backend.sampler_allocation_count.* >= backend.max_sampler_allocation_count) {
            return error.TooManyObjects;
        }
        const create_sampler = backend.procs.create_sampler orelse return error.MissingDeviceProc;
        if (backend.procs.destroy_sampler == null) return error.MissingDeviceProc;
        var self: Payload = .{ .backend = backend };
        errdefer self.destroy() catch |err| backend.recordCleanup(err);
        var conversion_info: vk.VkSamplerYcbcrConversionInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
        };
        if (key.y_cb_cr) |descriptor| {
            const create_conversion = backend.procs.create_sampler_ycbcr_conversion orelse return error.MissingDeviceProc;
            if (backend.procs.destroy_sampler_ycbcr_conversion == null) return error.MissingDeviceProc;
            const info: vk.VkSamplerYcbcrConversionCreateInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO,
                .format = @intCast(descriptor.vk_format),
                .ycbcrModel = @intCast(descriptor.vk_y_cb_cr_model),
                .ycbcrRange = @intCast(descriptor.vk_y_cb_cr_range),
                .components = .{ .r = @intCast(descriptor.vk_component_swizzle_red), .g = @intCast(descriptor.vk_component_swizzle_green), .b = @intCast(descriptor.vk_component_swizzle_blue), .a = @intCast(descriptor.vk_component_swizzle_alpha) },
                .xChromaOffset = @intCast(descriptor.vk_x_chroma_offset),
                .yChromaOffset = @intCast(descriptor.vk_y_chroma_offset),
                .chromaFilter = filter(descriptor.vk_chroma_filter),
                .forceExplicitReconstruction = @intFromBool(descriptor.force_explicit_reconstruction),
            };
            var created_conversion: vk.VkSamplerYcbcrConversion = null;
            try dispatch.checkVkSuccess(create_conversion(
                backend.handle,
                &info,
                null,
                &created_conversion,
            ));
            if (created_conversion == null) return error.SamplerConversionCreationReturnedNull;
            backend.handles.acquire(.sampler_y_cb_cr_conversion);
            self.conversion = created_conversion;
            conversion_info.conversion = self.conversion;
        }
        const info: vk.VkSamplerCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = if (self.conversion != null) @ptrCast(&conversion_info) else null,
            .magFilter = filter(key.mag_filter),
            .minFilter = filter(key.min_filter),
            .mipmapMode = if (key.mipmap_filter == .linear) vk.VK_SAMPLER_MIPMAP_MODE_LINEAR else vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = address(key.address_mode_u),
            .addressModeV = address(key.address_mode_v),
            .addressModeW = address(key.address_mode_w),
            .anisotropyEnable = @intFromBool(key.max_anisotropy > 1),
            .maxAnisotropy = @floatFromInt(key.max_anisotropy),
            .compareEnable = @intFromBool(key.compare_function != .undefined_),
            .compareOp = compare(key.compare_function),
            .minLod = key.lod_min_clamp,
            .maxLod = key.lod_max_clamp,
            .borderColor = vk.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        };
        var created_sampler: vk.VkSampler = null;
        try dispatch.checkVkSuccess(create_sampler(backend.handle, &info, null, &created_sampler));
        if (created_sampler == null) return error.SamplerCreationReturnedNull;
        backend.handles.acquire(.sampler);
        backend.sampler_allocation_count.* += 1;
        self.sampler = created_sampler;
        return self;
    }

    /// Destroys sampler before conversion. Missing dispatch preserves handles for reporting.
    pub fn destroy(self: *Payload) Error!void {
        if (self.sampler != null) {
            const destroy_sampler = self.backend.procs.destroy_sampler orelse return error.MissingDeviceProc;
            destroy_sampler(self.backend.handle, self.sampler, null);
            self.sampler = null;
            self.backend.handles.release(.sampler);
            std.debug.assert(self.backend.sampler_allocation_count.* != 0);
            self.backend.sampler_allocation_count.* -= 1;
        }
        if (self.conversion != null) {
            const destroy_conversion = self.backend.procs.destroy_sampler_ycbcr_conversion orelse return error.MissingDeviceProc;
            destroy_conversion(self.backend.handle, self.conversion, null);
            self.conversion = null;
            self.backend.handles.release(.sampler_y_cb_cr_conversion);
        }
    }
};
fn filter(mode: api.FilterMode) vk.VkFilter {
    return if (mode == .linear) vk.VK_FILTER_LINEAR else vk.VK_FILTER_NEAREST;
}
fn address(mode: api.AddressMode) vk.VkSamplerAddressMode {
    return switch (mode) {
        .clamp_to_edge => vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .repeat => vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirror_repeat => vk.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .undefined_ => unreachable,
    };
}
fn compare(mode: api.CompareFunction) vk.VkCompareOp {
    return switch (mode) {
        .undefined_, .never => vk.VK_COMPARE_OP_NEVER,
        .less => vk.VK_COMPARE_OP_LESS,
        .equal => vk.VK_COMPARE_OP_EQUAL,
        .less_equal => vk.VK_COMPARE_OP_LESS_OR_EQUAL,
        .greater => vk.VK_COMPARE_OP_GREATER,
        .not_equal => vk.VK_COMPARE_OP_NOT_EQUAL,
        .greater_equal => vk.VK_COMPARE_OP_GREATER_OR_EQUAL,
        .always => vk.VK_COMPARE_OP_ALWAYS,
    };
}

const ConversionFormat = struct {
    component_bits: [4]u8,
    subsampled_x: bool = false,
    subsampled_y: bool = false,
    plane_count: u32 = 1,
};

fn conversionFormat(format: u32, api_version: u32) ?ConversionFormat {
    if (format >= vk.VK_FORMAT_G8B8G8R8_422_UNORM and
        format <= vk.VK_FORMAT_G16_B16_R16_3PLANE_444_UNORM)
    {
        const index = format - vk.VK_FORMAT_G8B8G8R8_422_UNORM;
        const bits: u8 = if (index < 7) 8 else if (index < 17) 10 else if (index < 27) 12 else 16;
        var result: ConversionFormat = .{ .component_bits = .{ bits, bits, bits, 0 } };
        switch (index) {
            0, 1, 4, 5, 10, 11, 14, 15, 20, 21, 24, 25, 27, 28, 31, 32 => {
                result.subsampled_x = true;
            },
            2, 3, 12, 13, 22, 23, 29, 30 => {
                result.subsampled_x = true;
                result.subsampled_y = true;
            },
            6, 16, 26, 33 => {},
            7, 17 => result.component_bits = .{ bits, 0, 0, 0 },
            8, 18 => result.component_bits = .{ bits, bits, 0, 0 },
            9, 19 => result.component_bits = .{ bits, bits, bits, bits },
            else => unreachable,
        }
        result.plane_count = switch (index) {
            2, 4, 6, 12, 14, 16, 22, 24, 26, 29, 31, 33 => 3,
            3, 5, 13, 15, 23, 25, 30, 32 => 2,
            else => 1,
        };
        return result;
    }
    if (api_version >= vk.VK_API_VERSION_1_3 and
        format >= vk.VK_FORMAT_G8_B8R8_2PLANE_444_UNORM and
        format <= vk.VK_FORMAT_G16_B16R16_2PLANE_444_UNORM)
    {
        const bits: u8 = switch (format - vk.VK_FORMAT_G8_B8R8_2PLANE_444_UNORM) {
            0 => 8,
            1 => 10,
            2 => 12,
            3 => 16,
            else => unreachable,
        };
        return .{ .component_bits = .{ bits, bits, bits, 0 }, .plane_count = 2 };
    }
    return switch (format) {
        vk.VK_FORMAT_R4G4_UNORM_PACK8 => .{ .component_bits = .{ 4, 4, 0, 0 } },
        vk.VK_FORMAT_R4G4B4A4_UNORM_PACK16, vk.VK_FORMAT_B4G4R4A4_UNORM_PACK16 => .{ .component_bits = .{ 4, 4, 4, 4 } },
        vk.VK_FORMAT_R5G6B5_UNORM_PACK16, vk.VK_FORMAT_B5G6R5_UNORM_PACK16 => .{ .component_bits = .{ 5, 6, 5, 0 } },
        vk.VK_FORMAT_R5G5B5A1_UNORM_PACK16, vk.VK_FORMAT_B5G5R5A1_UNORM_PACK16, vk.VK_FORMAT_A1R5G5B5_UNORM_PACK16 => .{ .component_bits = .{ 5, 5, 5, 1 } },
        vk.VK_FORMAT_R8_UNORM => .{ .component_bits = .{ 8, 0, 0, 0 } },
        vk.VK_FORMAT_R8G8_UNORM => .{ .component_bits = .{ 8, 8, 0, 0 } },
        vk.VK_FORMAT_R8G8B8_UNORM, vk.VK_FORMAT_B8G8R8_UNORM => .{ .component_bits = .{ 8, 8, 8, 0 } },
        vk.VK_FORMAT_R8G8B8A8_UNORM, vk.VK_FORMAT_B8G8R8A8_UNORM, vk.VK_FORMAT_A8B8G8R8_UNORM_PACK32 => .{ .component_bits = .{ 8, 8, 8, 8 } },
        vk.VK_FORMAT_A2R10G10B10_UNORM_PACK32, vk.VK_FORMAT_A2B10G10R10_UNORM_PACK32 => .{ .component_bits = .{ 10, 10, 10, 2 } },
        vk.VK_FORMAT_R16_UNORM => .{ .component_bits = .{ 16, 0, 0, 0 } },
        vk.VK_FORMAT_R16G16_UNORM => .{ .component_bits = .{ 16, 16, 0, 0 } },
        vk.VK_FORMAT_R16G16B16_UNORM => .{ .component_bits = .{ 16, 16, 16, 0 } },
        vk.VK_FORMAT_R16G16B16A16_UNORM => .{ .component_bits = .{ 16, 16, 16, 16 } },
        else => null,
    };
}

fn validateComponents(descriptor: api.descriptors.YCbCrVkDescriptor, format: ConversionFormat) Error!void {
    const red = descriptor.vk_component_swizzle_red;
    const green = descriptor.vk_component_swizzle_green;
    const blue = descriptor.vk_component_swizzle_blue;
    const alpha = descriptor.vk_component_swizzle_alpha;
    if (format.subsampled_x) {
        const red_identity = red == vk.VK_COMPONENT_SWIZZLE_IDENTITY or red == vk.VK_COMPONENT_SWIZZLE_R;
        const blue_identity = blue == vk.VK_COMPONENT_SWIZZLE_IDENTITY or blue == vk.VK_COMPONENT_SWIZZLE_B;
        if (green != vk.VK_COMPONENT_SWIZZLE_IDENTITY and green != vk.VK_COMPONENT_SWIZZLE_G) return error.SamplerYCbCrDescriptorInvalid;
        if (alpha != vk.VK_COMPONENT_SWIZZLE_IDENTITY and alpha != vk.VK_COMPONENT_SWIZZLE_A and
            alpha != vk.VK_COMPONENT_SWIZZLE_ZERO and alpha != vk.VK_COMPONENT_SWIZZLE_ONE)
        {
            return error.SamplerYCbCrDescriptorInvalid;
        }
        if (red_identity != blue_identity) return error.SamplerYCbCrDescriptorInvalid;
        if (!red_identity and (red != vk.VK_COMPONENT_SWIZZLE_B or blue != vk.VK_COMPONENT_SWIZZLE_R)) {
            return error.SamplerYCbCrDescriptorInvalid;
        }
    }
    const swizzles = [_]u32{ red, green, blue };
    for (swizzles, 0..) |swizzle, identity| {
        const component: ?usize = switch (swizzle) {
            vk.VK_COMPONENT_SWIZZLE_IDENTITY => identity,
            vk.VK_COMPONENT_SWIZZLE_R => 0,
            vk.VK_COMPONENT_SWIZZLE_G => 1,
            vk.VK_COMPONENT_SWIZZLE_B => 2,
            vk.VK_COMPONENT_SWIZZLE_A => 3,
            vk.VK_COMPONENT_SWIZZLE_ZERO, vk.VK_COMPONENT_SWIZZLE_ONE => null,
            else => return error.SamplerYCbCrDescriptorInvalid,
        };
        const bits: u8 = if (component) |index| format.component_bits[index] else 0;
        if (descriptor.vk_y_cb_cr_model != vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY and bits == 0) {
            return error.SamplerYCbCrDescriptorInvalid;
        }
        if (descriptor.vk_y_cb_cr_range == vk.VK_SAMPLER_YCBCR_RANGE_ITU_NARROW and bits < 8) {
            return error.SamplerYCbCrDescriptorInvalid;
        }
    }
}

fn validateChromaOffset(flags: vk.VkFormatFeatureFlags, offset: u32) Error!void {
    const required: vk.VkFormatFeatureFlags = if (offset == vk.VK_CHROMA_LOCATION_MIDPOINT)
        vk.VK_FORMAT_FEATURE_MIDPOINT_CHROMA_SAMPLES_BIT
    else
        vk.VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT;
    if (flags & required == 0) return error.SamplerYCbCrFormatUnsupported;
}

fn validateConversionFeatures(
    descriptor: api.descriptors.YCbCrVkDescriptor,
    format: ConversionFormat,
    flags: vk.VkFormatFeatureFlags,
    filters: struct { min: api.FilterMode, mag: api.FilterMode },
) Error!void {
    if (flags & vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT == 0) return error.SamplerYCbCrFormatUnsupported;
    if (flags & (vk.VK_FORMAT_FEATURE_MIDPOINT_CHROMA_SAMPLES_BIT |
        vk.VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT) == 0)
    {
        return error.SamplerYCbCrFormatUnsupported;
    }
    if (format.subsampled_x) try validateChromaOffset(flags, descriptor.vk_x_chroma_offset);
    if (format.subsampled_y) try validateChromaOffset(flags, descriptor.vk_y_chroma_offset);
    if (descriptor.vk_chroma_filter == .linear and
        flags & vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER_BIT == 0)
    {
        return error.SamplerYCbCrFormatUnsupported;
    }
    if (descriptor.force_explicit_reconstruction and flags &
        vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_CHROMA_RECONSTRUCTION_EXPLICIT_FORCEABLE_BIT == 0)
    {
        return error.SamplerYCbCrFormatUnsupported;
    }
    if (flags & vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_SEPARATE_RECONSTRUCTION_FILTER_BIT == 0) {
        if (filters.min != descriptor.vk_chroma_filter or filters.mag != descriptor.vk_chroma_filter) {
            return error.SamplerYCbCrDescriptorInvalid;
        }
    }
    if ((filters.min == .linear or filters.mag == .linear) and
        flags & vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT == 0)
    {
        return error.SamplerYCbCrFormatUnsupported;
    }
}

test "YCbCr swizzles enforce native subsampling model and narrow-range rules" {
    const t = std.testing;
    const format = conversionFormat(vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, vk.VK_API_VERSION_1_1).?;
    var descriptor: api.descriptors.YCbCrVkDescriptor = .{};
    try validateComponents(descriptor, format);
    descriptor.vk_component_swizzle_green = vk.VK_COMPONENT_SWIZZLE_R;
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, validateComponents(descriptor, format));
    descriptor.vk_component_swizzle_green = vk.VK_COMPONENT_SWIZZLE_G;
    descriptor.vk_component_swizzle_red = vk.VK_COMPONENT_SWIZZLE_B;
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, validateComponents(descriptor, format));
    descriptor.vk_component_swizzle_blue = vk.VK_COMPONENT_SWIZZLE_R;
    try validateComponents(descriptor, format);
    descriptor.vk_component_swizzle_alpha = vk.VK_COMPONENT_SWIZZLE_G;
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, validateComponents(descriptor, format));
    const full = conversionFormat(vk.VK_FORMAT_G8_B8_R8_3PLANE_444_UNORM, vk.VK_API_VERSION_1_1).?;
    descriptor = .{ .vk_y_cb_cr_model = vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_IDENTITY, .vk_component_swizzle_red = vk.VK_COMPONENT_SWIZZLE_A };
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, validateComponents(descriptor, full));
    descriptor.vk_component_swizzle_red = vk.VK_COMPONENT_SWIZZLE_ZERO;
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, validateComponents(descriptor, full));
    descriptor = .{ .vk_y_cb_cr_range = vk.VK_SAMPLER_YCBCR_RANGE_ITU_NARROW };
    const low_depth = conversionFormat(vk.VK_FORMAT_R4G4B4A4_UNORM_PACK16, vk.VK_API_VERSION_1_1).?;
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, validateComponents(descriptor, low_depth));
}

test "YCbCr chroma offset support applies only to subsampled axes" {
    const t = std.testing;
    const flags = vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | vk.VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT;
    const descriptor: api.descriptors.YCbCrVkDescriptor = .{ .vk_y_chroma_offset = vk.VK_CHROMA_LOCATION_MIDPOINT };
    const format_422 = conversionFormat(vk.VK_FORMAT_G8_B8R8_2PLANE_422_UNORM, vk.VK_API_VERSION_1_1).?;
    const format_420 = conversionFormat(vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, vk.VK_API_VERSION_1_1).?;
    try validateConversionFeatures(descriptor, format_422, flags, .{ .min = .nearest, .mag = .nearest });
    try t.expectError(error.SamplerYCbCrFormatUnsupported, validateConversionFeatures(descriptor, format_420, flags, .{ .min = .nearest, .mag = .nearest }));
}

const ImageQueryTest = struct {
    fn formatProperties(
        _: vk.VkPhysicalDevice,
        format: vk.VkFormat,
        properties: [*c]vk.VkFormatProperties,
    ) callconv(.c) void {
        properties[0] = std.mem.zeroes(vk.VkFormatProperties);
        if (format == vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM) {
            properties[0].linearTilingFeatures = vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                vk.VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT;
        }
    }

    fn imageProperties(
        _: vk.VkPhysicalDevice,
        info: [*c]const vk.VkPhysicalDeviceImageFormatInfo2,
        properties: [*c]vk.VkImageFormatProperties2,
    ) callconv(.c) vk.VkResult {
        const conversion: *vk.VkSamplerYcbcrConversionImageFormatProperties =
            @ptrCast(@alignCast(properties[0].pNext.?));
        if (properties[0].sType != vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 or
            conversion.sType != vk.VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_IMAGE_FORMAT_PROPERTIES)
        {
            return vk.VK_ERROR_UNKNOWN;
        }
        if (info[0].format != vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM or
            info[0].type != vk.VK_IMAGE_TYPE_2D or
            info[0].tiling != vk.VK_IMAGE_TILING_OPTIMAL or
            info[0].usage != vk.VK_IMAGE_USAGE_SAMPLED_BIT)
        {
            conversion.combinedImageSamplerDescriptorCount = 3;
            return vk.VK_ERROR_FORMAT_NOT_SUPPORTED;
        }
        conversion.combinedImageSamplerDescriptorCount = switch (info[0].flags) {
            0 => 3,
            vk.VK_IMAGE_CREATE_DISJOINT_BIT => 0,
            vk.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT => 4,
            else => return vk.VK_ERROR_FORMAT_NOT_SUPPORTED,
        };
        properties[0].imageFormatProperties = std.mem.zeroes(vk.VkImageFormatProperties);
        return vk.VK_SUCCESS;
    }

    fn backend(
        instance_procs: *const dispatch.InstanceProcs,
        device_procs: *const dispatch.DeviceProcs,
        handles: *vulkan_device.HandleSet,
        count: *u32,
    ) Backend {
        return .{
            .procs = device_procs,
            .handle = null,
            .api_version = vk.VK_API_VERSION_1_3,
            .instance_procs = instance_procs,
            .physical = null,
            .anisotropy_enabled = false,
            .max_anisotropy = 1,
            .y_cb_cr_enabled = true,
            .handles = handles,
            .sampler_allocation_count = count,
            .max_sampler_allocation_count = 16,
        };
    }

    fn key() SemanticKey {
        return .{
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
            .lod_min_clamp = 0,
            .lod_max_clamp = 32,
            .compare_function = .undefined_,
            .max_anisotropy = 1,
            .y_cb_cr = .{ .vk_format = vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM },
        };
    }
};

test "conversion view admission uses selected tiling rather than potential union" {
    const t = std.testing;
    var procs = std.mem.zeroes(dispatch.InstanceProcs);
    procs.get_physical_device_format_properties = ImageQueryTest.formatProperties;
    const device_procs = std.mem.zeroes(dispatch.DeviceProcs);
    var handles: vulkan_device.HandleSet = .{};
    var count: u32 = 0;
    const backend = ImageQueryTest.backend(&procs, &device_procs, &handles, &count);
    const key = ImageQueryTest.key();
    try backend.validate(key);
    try backend.validateForTiling(key, vk.VK_IMAGE_TILING_LINEAR);
    try t.expectError(error.SamplerYCbCrFormatUnsupported, backend.validateForTiling(key, vk.VK_IMAGE_TILING_OPTIMAL));
    try t.expectError(error.SamplerYCbCrImageTilingUnsupported, backend.validateForTiling(key, vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT));
    var wrong_format = key;
    wrong_format.y_cb_cr.?.vk_format = vk.VK_FORMAT_R8G8B8A8_UNORM;
    try t.expectError(error.SamplerYCbCrFormatUnsupported, backend.validateForTiling(wrong_format, vk.VK_IMAGE_TILING_LINEAR));
    var wrong_filter = key;
    wrong_filter.min_filter = .linear;
    try t.expectError(error.SamplerYCbCrDescriptorInvalid, backend.validateForTiling(wrong_filter, vk.VK_IMAGE_TILING_LINEAR));
}

test "conversion descriptor count preserves exact image query native errors and invalid counts" {
    const t = std.testing;
    var procs = std.mem.zeroes(dispatch.InstanceProcs);
    procs.get_physical_device_image_format_properties2 = ImageQueryTest.imageProperties;
    const device_procs = std.mem.zeroes(dispatch.DeviceProcs);
    var handles: vulkan_device.HandleSet = .{};
    var count: u32 = 0;
    var backend = ImageQueryTest.backend(&procs, &device_procs, &handles, &count);
    var info: vk.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = @intCast(vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2),
        .pNext = null,
        .format = vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM,
        .type = vk.VK_IMAGE_TYPE_2D,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        .flags = 0,
    };
    try t.expectEqual(@as(u32, 3), try backend.combinedImageSamplerDescriptorCount(&info));
    inline for (.{
        .{ "format", @as(vk.VkFormat, vk.VK_FORMAT_R8G8B8A8_UNORM) },
        .{ "type", @as(vk.VkImageType, vk.VK_IMAGE_TYPE_3D) },
        .{ "tiling", @as(vk.VkImageTiling, vk.VK_IMAGE_TILING_LINEAR) },
        .{ "usage", @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) },
        .{ "flags", @as(vk.VkImageCreateFlags, vk.VK_IMAGE_CREATE_ALIAS_BIT) },
    }) |change| {
        var unsupported = info;
        @field(unsupported, change[0]) = change[1];
        try t.expectError(error.FormatNotSupported, backend.combinedImageSamplerDescriptorCount(&unsupported));
    }
    info.flags = vk.VK_IMAGE_CREATE_DISJOINT_BIT;
    try t.expectError(error.SamplerYCbCrDescriptorCountInvalid, backend.combinedImageSamplerDescriptorCount(&info));
    info.flags = vk.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
    try t.expectError(error.SamplerYCbCrDescriptorCountInvalid, backend.combinedImageSamplerDescriptorCount(&info));
    backend.y_cb_cr_enabled = false;
    try t.expectError(error.SamplerYCbCrUnsupported, backend.combinedImageSamplerDescriptorCount(&info));
    backend.y_cb_cr_enabled = true;
    procs.get_physical_device_image_format_properties2 = null;
    try t.expectError(error.MissingInstanceProc, backend.combinedImageSamplerDescriptorCount(&info));
}

test "conversion image admission requires ordinary and chroma linear filter support separately" {
    const t = std.testing;
    const format = conversionFormat(vk.VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM, vk.VK_API_VERSION_1_1).?;
    var descriptor: api.descriptors.YCbCrVkDescriptor = .{};
    const flags = vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
        vk.VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT |
        vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_SEPARATE_RECONSTRUCTION_FILTER_BIT;
    try t.expectError(error.SamplerYCbCrFormatUnsupported, validateConversionFeatures(descriptor, format, flags, .{ .min = .linear, .mag = .nearest }));
    const ordinary_linear = flags | vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    try validateConversionFeatures(descriptor, format, ordinary_linear, .{ .min = .linear, .mag = .nearest });
    descriptor.vk_chroma_filter = .linear;
    try t.expectError(error.SamplerYCbCrFormatUnsupported, validateConversionFeatures(descriptor, format, ordinary_linear, .{ .min = .linear, .mag = .linear }));
    try validateConversionFeatures(descriptor, format, ordinary_linear | vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER_BIT, .{ .min = .linear, .mag = .linear });
}
