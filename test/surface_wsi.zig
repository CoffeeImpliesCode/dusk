const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const wsi = dusk.engine.surface_capabilities;
const vk = @import("vulkan");
const dispatch = dusk.vk;

const Fixture = struct {
    var format_calls: usize = 0;
    var unstable: bool = false;
    var fail_modes: bool = false;
    var format_value: vk.VkFormat = vk.VK_FORMAT_B8G8R8A8_UNORM;
    var mode_value: vk.VkPresentModeKHR = vk.VK_PRESENT_MODE_FIFO_KHR;
    var native: vk.VkSurfaceCapabilitiesKHR = undefined;
    fn reset() void {
        format_calls = 0;
        unstable = false;
        fail_modes = false;
        format_value = vk.VK_FORMAT_B8G8R8A8_UNORM;
        mode_value = vk.VK_PRESENT_MODE_FIFO_KHR;
        native = std.mem.zeroes(vk.VkSurfaceCapabilitiesKHR);
        native.minImageCount = 2;
        native.maxImageCount = 4;
        native.maxImageArrayLayers = 1;
        native.currentExtent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };
        native.minImageExtent = .{ .width = 1, .height = 1 };
        native.maxImageExtent = .{ .width = 4096, .height = 4096 };
        native.currentTransform = vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        native.supportedTransforms = vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        native.supportedCompositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        native.supportedUsageFlags = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    }
    fn caps(p: vk.VkPhysicalDevice, s: vk.VkSurfaceKHR, out: [*c]vk.VkSurfaceCapabilitiesKHR) callconv(.c) vk.VkResult {
        std.debug.assert(p == @as(vk.VkPhysicalDevice, @ptrFromInt(0x1230)));
        std.debug.assert(s == @as(vk.VkSurfaceKHR, @ptrFromInt(0x4560)));
        out.* = native;
        return vk.VK_SUCCESS;
    }
    fn formats(_: vk.VkPhysicalDevice, _: vk.VkSurfaceKHR, count: [*c]u32, out: [*c]vk.VkSurfaceFormatKHR) callconv(.c) vk.VkResult {
        format_calls += 1;
        count.* = 1;
        if (out == null) return vk.VK_SUCCESS;
        out[0] = .{ .format = format_value, .colorSpace = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR };
        return if (unstable) vk.VK_INCOMPLETE else vk.VK_SUCCESS;
    }
    fn modes(_: vk.VkPhysicalDevice, _: vk.VkSurfaceKHR, count: [*c]u32, out: [*c]vk.VkPresentModeKHR) callconv(.c) vk.VkResult {
        if (fail_modes) return vk.VK_ERROR_SURFACE_LOST_KHR;
        count.* = 1;
        if (out != null) out[0] = mode_value;
        return vk.VK_SUCCESS;
    }
    fn procs() dispatch.InstanceProcs {
        var result = std.mem.zeroes(dispatch.InstanceProcs);
        result.get_physical_device_surface_capabilities_khr = caps;
        result.get_physical_device_surface_formats_khr = formats;
        result.get_physical_device_surface_present_modes_khr = modes;
        return result;
    }
    fn backend(p: *const dispatch.InstanceProcs) wsi.QueryBackend {
        return .{ .physical_device = @ptrFromInt(0x1230), .surface = @ptrFromInt(0x4560), .instance_procs = p };
    }
    fn config() api.descriptors.SurfaceConfigurationChain {
        return .{ .device = undefined, .format = .bgra8_unorm, .width = 640, .height = 480 };
    }
};

test "surface capabilities query maps driver values and owns published slices" {
    Fixture.reset();
    const p = Fixture.procs();
    var out: api.SurfaceCapabilities = .{ .usages = .{}, .format_count = 0, .present_mode_count = 0, .alpha_mode_count = 0 };
    try std.testing.expectEqual(api.Status.success, try wsi.publish(std.testing.allocator, Fixture.backend(&p), &out));
    defer wsi.freeCapabilities(std.testing.allocator, &out);
    try std.testing.expectEqualSlices(api.TextureFormat, &.{.bgra8_unorm}, out.formats.?);
    try std.testing.expectEqualSlices(api.PresentMode, &.{.fifo}, out.present_modes.?);
    try std.testing.expectEqualSlices(api.CompositeAlphaMode, &.{.opaque_}, out.alpha_modes.?);
    try std.testing.expect(out.usages.render_attachment and out.usages.copy_src);
}

test "surface count instability stops at three attempts and publication is atomic" {
    Fixture.reset();
    Fixture.unstable = true;
    const p = Fixture.procs();
    var out: api.SurfaceCapabilities = .{ .usages = .{ .copy_dst = true }, .format_count = 0, .present_mode_count = 0, .alpha_mode_count = 0 };
    try std.testing.expectError(error.SurfaceCapabilitiesUnstable, wsi.publish(std.testing.allocator, Fixture.backend(&p), &out));
    try std.testing.expectEqual(@as(usize, 6), Fixture.format_calls);
    try std.testing.expect(out.usages.copy_dst and out.formats == null);
}

test "surface later query failure leaves output unchanged and frees temporary arrays" {
    Fixture.reset();
    Fixture.fail_modes = true;
    const p = Fixture.procs();
    var out: api.SurfaceCapabilities = .{ .usages = .{}, .format_count = 0, .present_mode_count = 0, .alpha_mode_count = 0 };
    try std.testing.expectError(error.SurfaceLost, wsi.publish(std.testing.allocator, Fixture.backend(&p), &out));
    try std.testing.expect(out.formats == null and out.format_count == 0);
}

test "surface configuration validates extent usage exact view formats and bounded image count" {
    Fixture.reset();
    const p = Fixture.procs();
    var c = Fixture.config();
    const validated = try wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c);
    try std.testing.expectEqual(@as(u32, 3), validated.create_info.minImageCount);
    try std.testing.expectEqual(@as(u32, 640), validated.create_info.imageExtent.width);
    c.usage = .{ .storage_binding = true };
    try std.testing.expectError(error.UnsupportedSurfaceUsage, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c = Fixture.config();
    c.view_formats = &.{.bgra8_unorm_srgb};
    c.view_format_count = 1;
    try std.testing.expectError(error.UnsupportedViewFormat, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c = Fixture.config();
    Fixture.native.minImageCount = 9;
    try std.testing.expectError(error.InvalidSurfaceImageCount, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
}

test "surface publication rejects live output without overwriting caller memory" {
    Fixture.reset();
    const p = Fixture.procs();
    const existing = [_]api.TextureFormat{.rgba8_unorm};
    var out: api.SurfaceCapabilities = .{ .usages = .{}, .format_count = 1, .formats = &existing, .present_mode_count = 0, .alpha_mode_count = 0 };
    try std.testing.expectError(error.InvalidOutput, wsi.publish(std.testing.allocator, Fixture.backend(&p), &out));
    try std.testing.expect(out.formats.?.ptr == &existing);
    try std.testing.expectEqual(@as(usize, 0), Fixture.format_calls);
}

test "surface allocation failure and missing procedure preserve empty output" {
    Fixture.reset();
    var p = Fixture.procs();
    var storage: [0]u8 = .{};
    var buffer = std.heap.FixedBufferAllocator.init(&storage);
    var out: api.SurfaceCapabilities = .{ .usages = .{ .copy_src = true }, .format_count = 0, .present_mode_count = 0, .alpha_mode_count = 0 };
    try std.testing.expectError(error.OutOfMemory, wsi.publish(buffer.allocator(), Fixture.backend(&p), &out));
    try std.testing.expect(out.formats == null and out.usages.copy_src);
    p.get_physical_device_surface_formats_khr = null;
    try std.testing.expectError(error.MissingInstanceProc, wsi.publish(std.testing.allocator, Fixture.backend(&p), &out));
    try std.testing.expect(out.formats == null and out.usages.copy_src);
}

test "surface validation rejects unsupported modes alpha formats and malformed view count" {
    Fixture.reset();
    const p = Fixture.procs();
    var c = Fixture.config();
    c.present_mode = .mailbox;
    try std.testing.expectError(error.UnsupportedPresentMode, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c = Fixture.config();
    c.alpha_mode = .premultiplied;
    try std.testing.expectError(error.UnsupportedCompositeAlpha, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c = Fixture.config();
    c.format = .rgba8_unorm;
    try std.testing.expectError(error.UnsupportedSurfaceFormat, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c = Fixture.config();
    c.view_format_count = 1;
    try std.testing.expectError(error.UnsupportedViewFormat, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c.view_formats = &.{.bgra8_unorm};
    _ = try wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c);
}

test "surface fixed extent current transform and unbounded maximum are honored" {
    Fixture.reset();
    const p = Fixture.procs();
    var c = Fixture.config();
    Fixture.native.currentExtent = .{ .width = 320, .height = 240 };
    try std.testing.expectError(error.InvalidSurfaceExtent, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
    c.width = 320;
    c.height = 240;
    Fixture.native.currentTransform = vk.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR;
    Fixture.native.supportedTransforms = vk.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR;
    Fixture.native.minImageCount = 8;
    Fixture.native.maxImageCount = 0;
    const result = try wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c);
    try std.testing.expectEqual(@as(u32, 8), result.create_info.minImageCount);
    try std.testing.expectEqual(@as(vk.VkSurfaceTransformFlagBitsKHR, vk.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR), result.create_info.preTransform);
    try std.testing.expect(result.create_info.pNext == null);
    c.width = 0;
    try std.testing.expectError(error.InvalidSurfaceExtent, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &c));
}

test "surface unrepresentable driver sets return typed errors" {
    Fixture.reset();
    const p = Fixture.procs();
    Fixture.format_value = vk.VK_FORMAT_D32_SFLOAT;
    try std.testing.expectError(error.NoRepresentableSurfaceFormats, wsi.query(std.testing.allocator, Fixture.backend(&p)));
    Fixture.format_value = vk.VK_FORMAT_B8G8R8A8_UNORM;
    Fixture.mode_value = std.math.maxInt(vk.VkPresentModeKHR);
    try std.testing.expectError(error.NoRepresentablePresentModes, wsi.query(std.testing.allocator, Fixture.backend(&p)));
    Fixture.mode_value = vk.VK_PRESENT_MODE_FIFO_KHR;
    Fixture.native.supportedCompositeAlpha = 0;
    try std.testing.expectError(error.NoRepresentableCompositeAlpha, wsi.query(std.testing.allocator, Fixture.backend(&p)));
}

test "surface undefined driver format expands representable choices" {
    Fixture.reset();
    const p = Fixture.procs();
    Fixture.format_value = vk.VK_FORMAT_UNDEFINED;
    var owned = try wsi.query(std.testing.allocator, Fixture.backend(&p));
    defer owned.deinit(std.testing.allocator);
    try std.testing.expect(owned.capabilities.format_count > 1);
    try std.testing.expect(std.mem.indexOfScalar(api.TextureFormat, owned.capabilities.formats.?, .rgba8_unorm) != null);
    var config = Fixture.config();
    config.format = .rgba8_unorm;
    const validated = try wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &config);
    try std.testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_R8G8B8A8_UNORM), validated.create_info.imageFormat);
    try std.testing.expectEqual(@as(vk.VkColorSpaceKHR, vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR), validated.create_info.imageColorSpace);
}

test "surface usage mapping rejects unsupported API-only attachment bits" {
    try std.testing.expectError(error.UnsupportedSurfaceUsage, wsi.vkUsage(.{ .transient_attachment = true }));
    try std.testing.expectError(error.UnsupportedSurfaceUsage, wsi.vkUsage(.{ .storage_attachment = true }));
    try std.testing.expectError(error.UnsupportedSurfaceUsage, wsi.vkUsage(.{}));
    const mapped = try wsi.vkUsage(.{ .copy_src = true, .copy_dst = true, .texture_binding = true, .storage_binding = true, .render_attachment = true });
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_STORAGE_BIT | vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT), mapped);
}

test "surface native usage enables only supported internal initialization without public permissions" {
    Fixture.reset();
    const p = Fixture.procs();
    var config = Fixture.config();
    config.usage = .{ .copy_src = true };
    Fixture.native.supportedUsageFlags = vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const transfer = try wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &config);
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT), transfer.create_info.imageUsage);
    try std.testing.expect(!config.usage.copy_dst and !config.usage.render_attachment);
    Fixture.native.supportedUsageFlags = vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    const render = try wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &config);
    try std.testing.expectEqual(@as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT), render.create_info.imageUsage);
    try std.testing.expect(!config.usage.copy_dst and !config.usage.render_attachment);
    Fixture.native.supportedUsageFlags = vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    try std.testing.expectError(error.UnsupportedSurfaceUsage, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &config));
    var owned = try wsi.query(std.testing.allocator, Fixture.backend(&p));
    defer owned.deinit(std.testing.allocator);
    try std.testing.expect(owned.capabilities.usages.copy_src);
    try std.testing.expect(!owned.capabilities.usages.copy_dst and !owned.capabilities.usages.render_attachment);
    config.usage = .{ .copy_dst = true };
    try std.testing.expectError(error.UnsupportedSurfaceUsage, wsi.validateConfiguration(std.testing.allocator, Fixture.backend(&p), &config));
}
