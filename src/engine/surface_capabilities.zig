//! Native surface queries. Handles and procs must come from the same live instance.
const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const api = @import("../api/api.zig");
const formats = @import("vulkan_format.zig");

pub const QueryBackend = struct {
    physical_device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
    instance_procs: *const dispatch.InstanceProcs,
};
pub const QueryError = std.mem.Allocator.Error || dispatch.Error || dispatch.LoadError || error{
    SurfaceCapabilitiesUnstable,
    NoRepresentableSurfaceFormats,
    NoRepresentablePresentModes,
    NoRepresentableCompositeAlpha,
    InvalidOutput,
    InvalidSurfaceExtent,
    UnsupportedSurfaceUsage,
    UnsupportedSurfaceFormat,
    UnsupportedPresentMode,
    UnsupportedCompositeAlpha,
    UnsupportedViewFormat,
    InvalidSurfaceImageCount,
};
pub const OwnedCapabilities = struct {
    native: vk.VkSurfaceCapabilitiesKHR,
    native_formats: []vk.VkSurfaceFormatKHR,
    capabilities: api.SurfaceCapabilities,
    pub fn deinit(self: *OwnedCapabilities, allocator: std.mem.Allocator) void {
        allocator.free(self.native_formats);
        freeCapabilities(allocator, &self.capabilities);
        self.* = undefined;
    }
};
pub const ValidatedConfiguration = struct {
    create_info: vk.VkSwapchainCreateInfoKHR,
};

const surface_formats = [_]api.TextureFormat{ .bgra8_unorm, .rgba8_unorm, .bgra8_unorm_srgb, .rgba8_unorm_srgb, .rgb10_a2_unorm, .rgba16_float };
const present_modes = [_]api.PresentMode{ .fifo, .fifo_relaxed, .immediate, .mailbox };
const alpha_modes = [_]api.CompositeAlphaMode{ .opaque_, .premultiplied, .unpremultiplied, .inherit };

pub fn freeCapabilities(allocator: std.mem.Allocator, out: *api.SurfaceCapabilities) void {
    if (out.formats) |slice| allocator.free(slice);
    if (out.present_modes) |slice| allocator.free(slice);
    if (out.alpha_modes) |slice| allocator.free(slice);
    out.* = .{ .usages = .{}, .format_count = 0, .present_mode_count = 0, .alpha_mode_count = 0 };
}

fn enumerate(comptime T: type, allocator: std.mem.Allocator, backend: QueryBackend, proc: std.meta.Child(if (T == vk.VkSurfaceFormatKHR) vk.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR else vk.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR)) QueryError![]T {
    for (0..3) |_| {
        var count: u32 = 0;
        const counted = proc(backend.physical_device, backend.surface, &count, null);
        if (counted != vk.VK_SUCCESS and counted != vk.VK_INCOMPLETE) try dispatch.checkVkSuccess(counted);
        if (count == 0) {
            if (counted == vk.VK_INCOMPLETE) continue;
            return allocator.alloc(T, 0);
        }
        const storage = try allocator.alloc(T, count);
        errdefer allocator.free(storage);
        var written = count;
        const result = proc(backend.physical_device, backend.surface, &written, storage.ptr);
        if (result == vk.VK_INCOMPLETE or (result == vk.VK_SUCCESS and written > count)) {
            allocator.free(storage);
            continue;
        }
        try dispatch.checkVkSuccess(result);
        if (written == count) return storage;
        const exact = try allocator.dupe(T, storage[0..written]);
        allocator.free(storage);
        return exact;
    }
    return error.SurfaceCapabilitiesUnstable;
}

fn supportsFormat(native: []const vk.VkSurfaceFormatKHR, format: api.TextureFormat) bool {
    for (native) |entry| {
        if (entry.colorSpace != vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) continue;
        if (entry.format == formats.vkFormat(format) or (native.len == 1 and entry.format == vk.VK_FORMAT_UNDEFINED)) return true;
    }
    return false;
}
pub fn vkPresentMode(mode: api.PresentMode) QueryError!vk.VkPresentModeKHR {
    return switch (mode) {
        .fifo => vk.VK_PRESENT_MODE_FIFO_KHR,
        .fifo_relaxed => vk.VK_PRESENT_MODE_FIFO_RELAXED_KHR,
        .immediate => vk.VK_PRESENT_MODE_IMMEDIATE_KHR,
        .mailbox => vk.VK_PRESENT_MODE_MAILBOX_KHR,
        .undefined_ => error.UnsupportedPresentMode,
    };
}
pub fn vkCompositeAlpha(mode: api.CompositeAlphaMode) QueryError!vk.VkCompositeAlphaFlagBitsKHR {
    return switch (mode) {
        .opaque_ => vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .premultiplied => vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        .unpremultiplied => vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        .inherit => vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        .auto => error.UnsupportedCompositeAlpha,
    };
}
pub fn vkUsage(usage: api.TextureUsage) QueryError!vk.VkImageUsageFlags {
    if (usage.toFlags() == 0 or usage._padding != 0 or usage.transient_attachment or usage.storage_attachment) return error.UnsupportedSurfaceUsage;
    var result: vk.VkImageUsageFlags = 0;
    if (usage.copy_src) result |= vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (usage.copy_dst) result |= vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (usage.texture_binding) result |= vk.VK_IMAGE_USAGE_SAMPLED_BIT;
    if (usage.storage_binding) result |= vk.VK_IMAGE_USAGE_STORAGE_BIT;
    if (usage.render_attachment) result |= vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    return result;
}
fn apiUsage(flags: vk.VkImageUsageFlags) api.TextureUsage {
    return .{
        .copy_src = flags & vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT != 0,
        .copy_dst = flags & vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT != 0,
        .texture_binding = flags & vk.VK_IMAGE_USAGE_SAMPLED_BIT != 0,
        .storage_binding = flags & vk.VK_IMAGE_USAGE_STORAGE_BIT != 0,
        .render_attachment = flags & vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0,
    };
}

pub fn query(allocator: std.mem.Allocator, backend: QueryBackend) QueryError!OwnedCapabilities {
    const caps_proc = backend.instance_procs.get_physical_device_surface_capabilities_khr orelse return error.MissingInstanceProc;
    const format_proc = backend.instance_procs.get_physical_device_surface_formats_khr orelse return error.MissingInstanceProc;
    const mode_proc = backend.instance_procs.get_physical_device_surface_present_modes_khr orelse return error.MissingInstanceProc;
    var native: vk.VkSurfaceCapabilitiesKHR = undefined;
    try dispatch.checkVkSuccess(caps_proc(backend.physical_device, backend.surface, &native));
    const native_formats = try enumerate(vk.VkSurfaceFormatKHR, allocator, backend, format_proc);
    errdefer allocator.free(native_formats);
    const native_modes = try enumerate(vk.VkPresentModeKHR, allocator, backend, mode_proc);
    defer allocator.free(native_modes);
    var format_buffer: [surface_formats.len]api.TextureFormat = undefined;
    var format_count: usize = 0;
    for (surface_formats) |format| if (supportsFormat(native_formats, format)) {
        format_buffer[format_count] = format;
        format_count += 1;
    };
    if (format_count == 0) return error.NoRepresentableSurfaceFormats;
    var mode_buffer: [present_modes.len]api.PresentMode = undefined;
    var mode_count: usize = 0;
    for (present_modes) |mode| {
        if (std.mem.indexOfScalar(vk.VkPresentModeKHR, native_modes, try vkPresentMode(mode)) != null) {
            mode_buffer[mode_count] = mode;
            mode_count += 1;
        }
    }
    if (mode_count == 0) return error.NoRepresentablePresentModes;
    var alpha_buffer: [alpha_modes.len]api.CompositeAlphaMode = undefined;
    var alpha_count: usize = 0;
    for (alpha_modes) |alpha| if (native.supportedCompositeAlpha & try vkCompositeAlpha(alpha) != 0) {
        alpha_buffer[alpha_count] = alpha;
        alpha_count += 1;
    };
    if (alpha_count == 0) return error.NoRepresentableCompositeAlpha;
    const owned_formats = try allocator.dupe(api.TextureFormat, format_buffer[0..format_count]);
    errdefer allocator.free(owned_formats);
    const owned_modes = try allocator.dupe(api.PresentMode, mode_buffer[0..mode_count]);
    errdefer allocator.free(owned_modes);
    const owned_alpha = try allocator.dupe(api.CompositeAlphaMode, alpha_buffer[0..alpha_count]);
    return .{ .native = native, .native_formats = native_formats, .capabilities = .{
        .usages = apiUsage(native.supportedUsageFlags),
        .format_count = format_count,
        .formats = owned_formats,
        .present_mode_count = mode_count,
        .present_modes = owned_modes,
        .alpha_mode_count = alpha_count,
        .alpha_modes = owned_alpha,
    } };
}

/// Publishes only to an empty output. On error every output field is unchanged.
pub fn publish(allocator: std.mem.Allocator, backend: QueryBackend, out: *api.SurfaceCapabilities) QueryError!api.Status {
    if (out.formats != null or out.present_modes != null or out.alpha_modes != null or out.format_count != 0 or out.present_mode_count != 0 or out.alpha_mode_count != 0) return error.InvalidOutput;
    const owned = try query(allocator, backend);
    allocator.free(owned.native_formats);
    out.* = owned.capabilities;
    return .success;
}

pub fn validateConfiguration(allocator: std.mem.Allocator, backend: QueryBackend, config: *const api.descriptors.SurfaceConfigurationChain) QueryError!ValidatedConfiguration {
    var owned = try query(allocator, backend);
    defer owned.deinit(allocator);
    const native = owned.native;
    const caps = owned.capabilities;
    if (std.mem.indexOfScalar(api.TextureFormat, caps.formats.?, config.format) == null) return error.UnsupportedSurfaceFormat;
    if (std.mem.indexOfScalar(api.PresentMode, caps.present_modes.?, config.present_mode) == null) return error.UnsupportedPresentMode;
    const alpha = if (config.alpha_mode == .auto) caps.alpha_modes.?[0] else config.alpha_mode;
    if (std.mem.indexOfScalar(api.CompositeAlphaMode, caps.alpha_modes.?, alpha) == null) return error.UnsupportedCompositeAlpha;
    var usage = try vkUsage(config.usage);
    if (usage & native.supportedUsageFlags != usage) return error.UnsupportedSurfaceUsage;
    // Internal first-present initialization must use a genuinely supported clear path.
    // This native permission does not alter the public configuration or texture usage.
    const clear_usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (usage & clear_usage == 0) {
        if (native.supportedUsageFlags & vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT != 0) {
            usage |= vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        } else if (native.supportedUsageFlags & vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0) {
            usage |= vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        } else {
            return error.UnsupportedSurfaceUsage;
        }
    }
    const views = config.view_formats orelse &.{};
    if (views.len != config.view_format_count) return error.UnsupportedViewFormat;
    for (views) |view| if (view != config.format) return error.UnsupportedViewFormat;
    if (config.width == 0 or config.height == 0 or config.width < native.minImageExtent.width or config.height < native.minImageExtent.height or config.width > native.maxImageExtent.width or config.height > native.maxImageExtent.height) return error.InvalidSurfaceExtent;
    if (native.currentExtent.width != std.math.maxInt(u32) and (config.width != native.currentExtent.width or config.height != native.currentExtent.height)) return error.InvalidSurfaceExtent;
    if (native.currentTransform == 0 or native.currentTransform & native.supportedTransforms != native.currentTransform) return error.InvalidSurfaceExtent;
    if (native.minImageCount == 0 or native.minImageCount > 8 or (native.maxImageCount != 0 and native.maxImageCount < native.minImageCount) or native.maxImageArrayLayers < 1) return error.InvalidSurfaceImageCount;
    const desired = @min(native.minImageCount + 1, 8);
    const count = if (native.maxImageCount == 0) desired else @min(desired, native.maxImageCount);
    var info = std.mem.zeroes(vk.VkSwapchainCreateInfoKHR);
    info.sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    info.surface = backend.surface;
    info.minImageCount = count;
    info.imageFormat = formats.vkFormat(config.format);
    info.imageColorSpace = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    info.imageExtent = .{ .width = config.width, .height = config.height };
    info.imageArrayLayers = 1;
    info.imageUsage = usage;
    info.imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = native.currentTransform;
    info.compositeAlpha = try vkCompositeAlpha(alpha);
    info.presentMode = try vkPresentMode(config.present_mode);
    info.clipped = vk.VK_TRUE;
    return .{ .create_info = info };
}
