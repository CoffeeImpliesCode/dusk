const std = @import("std");
const dusk = @import("dusk");
const request = dusk.engine.vulkan_extension_request;
const dispatch = dusk.vk.dispatch;
const vulkan = dusk.platform.vulkan_bindings;

fn property(name: []const u8) vulkan.VkExtensionProperties {
    var result: vulkan.VkExtensionProperties = std.mem.zeroes(vulkan.VkExtensionProperties);
    @memcpy(result.extensionName[0..name.len], name);
    return result;
}

test "optional missing names stay disabled and unrequested names are not enabled" {
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_surface")};
    const selected = try request.selectInstance(&.{.{
        .extension = .xlib_surface,
        .requirement = .optional,
    }}, &available);
    try std.testing.expectEqual(@as(u64, 0), selected.enabled.bits);
    try std.testing.expectEqual(@as(usize, 0), selected.count);
}

test "required missing name fails" {
    try std.testing.expectError(error.ExtensionUnavailable, request.selectInstance(&.{.{
        .extension = .surface,
        .requirement = .required,
    }}, &.{}));
}

test "duplicate requirements merge with required taking precedence" {
    const rows = [_]request.RequestedInstanceExtension{
        .{ .extension = .surface, .requirement = .optional },
        .{ .extension = .surface, .requirement = .required },
    };
    try std.testing.expectError(error.ExtensionUnavailable, request.selectInstance(&rows, &.{}));
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_surface")};
    const selected = try request.selectInstance(&rows, &available);
    try std.testing.expectEqual(@as(usize, 1), selected.count);
    try std.testing.expect(selected.enabled.has(.surface));
}

test "required dependent extension cannot enable an unrequested base" {
    const available = [_]vulkan.VkExtensionProperties{
        property("VK_KHR_external_memory_fd"), property("VK_KHR_external_memory"),
    };
    try std.testing.expectError(error.ExtensionDependencyUnavailable, request.selectDevice(
        &.{.{ .extension = .external_memory_fd, .requirement = .required }},
        &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_0, .enabled_instance = .{} },
    ));
}

test "optional unsatisfied dependency is omitted" {
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_external_memory_fd")};
    const selected = try request.selectDevice(
        &.{.{ .extension = .external_memory_fd, .requirement = .optional }},
        &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_0, .enabled_instance = .{} },
    );
    try std.testing.expectEqual(@as(usize, 0), selected.count);
}

test "core promotion satisfies base without enabling its extension name" {
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_external_memory_fd")};
    const selected = try request.selectDevice(
        &.{.{ .extension = .external_memory_fd, .requirement = .required }},
        &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_1, .enabled_instance = .{} },
    );
    try std.testing.expect(selected.enabled.has(.external_memory_fd));
    try std.testing.expect(!selected.enabled.has(.external_memory));
    try std.testing.expectEqual(@as(usize, 1), selected.count);
}

test "swapchain requires enabled instance surface" {
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_swapchain")};
    try std.testing.expectError(error.ExtensionDependencyUnavailable, request.selectDevice(
        &.{.{ .extension = .swapchain, .requirement = .required }},
        &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_1, .enabled_instance = .{} },
    ));
}

var enumeration_calls: usize = 0;
fn unstable(_: [*c]const u8, count: [*c]u32, properties: [*c]vulkan.VkExtensionProperties)
    callconv(.c) vulkan.VkResult
{
    enumeration_calls += 1;
    count.* = 1;
    if (properties == null) return vulkan.VK_SUCCESS;
    return vulkan.VK_INCOMPLETE;
}

test "unstable enumeration performs at most three complete attempts" {
    enumeration_calls = 0;
    try std.testing.expectError(error.ExtensionEnumerationUnstable,
        request.enumerateInstance(std.testing.allocator, unstable));
    try std.testing.expectEqual(@as(usize, 6), enumeration_calls);
}

fn succeedsThird(_: [*c]const u8, count: [*c]u32,
    properties: [*c]vulkan.VkExtensionProperties) callconv(.c) vulkan.VkResult
{
    enumeration_calls += 1;
    count.* = 1;
    if (properties == null) return vulkan.VK_SUCCESS;
    properties[0] = property("VK_KHR_surface");
    return if (enumeration_calls < 6) vulkan.VK_INCOMPLETE else vulkan.VK_SUCCESS;
}

test "third enumeration attempt publishes only complete results" {
    enumeration_calls = 0;
    var available = try request.enumerateInstance(std.testing.allocator, succeedsThird);
    defer available.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), available.items().len);
    try std.testing.expectEqual(@as(usize, 6), enumeration_calls);
}

test "platform defaults request WSI before compute and import dependencies by actual API" {
    var linux: request.DefaultRequest = .{};
    linux.init(.{ .platform = .linux, .api_version = vulkan.VK_API_VERSION_1_0 });
    const rows = linux.request();
    try std.testing.expectEqual(@as(usize, 6), rows.instance.len);
    var has_base = false;
    for (rows.device) |row| {
        if (row.extension == .external_memory) has_base = true;
        try std.testing.expectEqual(request.ExtensionRequirement.optional, row.requirement);
    }
    try std.testing.expect(has_base);
    var android: request.DefaultRequest = .{};
    android.init(.{ .platform = .android, .api_version = vulkan.VK_API_VERSION_1_1 });
    for (android.request().device) |row| {
        try std.testing.expect(row.extension != .external_memory_fd);
        try std.testing.expect(row.extension != .external_memory);
    }
}

test "required promoted base uses core without requiring an advertised extension" {
    const selected = try request.selectDevice(
        &.{.{ .extension = .external_memory, .requirement = .required }},
        &.{},
        .{ .api_version = vulkan.VK_API_VERSION_1_1, .enabled_instance = .{} },
    );
    try std.testing.expectEqual(@as(usize, 0), selected.count);
    try std.testing.expectEqual(@as(u64, 0), selected.enabled.bits);
}

test "optional dependency removal cascades and required dependents still fail" {
    const available = [_]vulkan.VkExtensionProperties{
        property("VK_KHR_external_memory_fd"), property("VK_EXT_external_memory_dma_buf"),
    };
    const rows = [_]request.RequestedDeviceExtension{
        .{ .extension = .external_memory_fd, .requirement = .optional },
        .{ .extension = .external_memory_dma_buf, .requirement = .required },
    };
    try std.testing.expectError(error.ExtensionDependencyUnavailable, request.selectDevice(
        &rows, &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_0, .enabled_instance = .{} },
    ));
}

test "missing enumeration proc is a typed load failure" {
    try std.testing.expectError(error.MissingGlobalProc,
        request.enumerateInstance(std.testing.allocator, null));
    try std.testing.expectError(error.MissingInstanceProc,
        request.enumerateDevice(std.testing.allocator, null, null));
}

fn unstableCount(_: [*c]const u8, _: [*c]u32,
    _: [*c]vulkan.VkExtensionProperties) callconv(.c) vulkan.VkResult
{
    enumeration_calls += 1;
    return vulkan.VK_INCOMPLETE;
}

test "count enumeration incomplete exhausts after exactly three calls" {
    enumeration_calls = 0;
    try std.testing.expectError(error.ExtensionEnumerationUnstable,
        request.enumerateInstance(std.testing.allocator, unstableCount));
    try std.testing.expectEqual(@as(usize, 3), enumeration_calls);
}

test "core promotion never substitutes the exact FD import extension" {
    try std.testing.expectError(error.ExtensionUnavailable, request.selectDevice(
        &.{.{ .extension = .external_memory_fd, .requirement = .required }},
        &.{},
        .{ .api_version = vulkan.VK_API_VERSION_1_3, .enabled_instance = .{} },
    ));
}

test "instance WSI dependency absence remains optional or fails when required" {
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_xlib_surface")};
    const selected = try request.selectInstance(
        &.{.{ .extension = .xlib_surface, .requirement = .optional }}, &available,
    );
    try std.testing.expectEqual(@as(usize, 0), selected.count);
    try std.testing.expectError(error.ExtensionDependencyUnavailable, request.selectInstance(
        &.{.{ .extension = .xlib_surface, .requirement = .required }}, &available,
    ));
}

test "Android defaults request maintenance6 optionally" {
    var defaults: request.DefaultRequest = .{};
    defaults.init(.{ .platform = .android, .api_version = vulkan.VK_API_VERSION_1_1 });
    var found = false;
    for (defaults.request().device) |row| {
        if (row.extension != .maintenance6) continue;
        found = true;
        try std.testing.expectEqual(request.ExtensionRequirement.optional, row.requirement);
    }
    try std.testing.expect(found);
}

test "maintenance6 requires actual Vulkan1.1 and cannot use extension bases on1.0" {
    const available = [_]vulkan.VkExtensionProperties{property("VK_KHR_maintenance6")};
    const selected = try request.selectDevice(
        &.{.{ .extension = .maintenance6, .requirement = .optional }}, &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_0, .enabled_instance = .{} },
    );
    try std.testing.expectEqual(@as(usize, 0), selected.count);
    try std.testing.expectError(error.ExtensionDependencyUnavailable, request.selectDevice(
        &.{.{ .extension = .maintenance6, .requirement = .required }}, &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_0, .enabled_instance = .{} },
    ));
    const supported = try request.selectDevice(
        &.{.{ .extension = .maintenance6, .requirement = .required }}, &available,
        .{ .api_version = vulkan.VK_API_VERSION_1_1, .enabled_instance = .{} },
    );
    try std.testing.expect(supported.enabled.has(.maintenance6));
}

test "maintenance6 is core Vulkan1.4 without extension advertisement" {
    const selected = try request.selectDevice(
        &.{.{ .extension = .maintenance6, .requirement = .required }}, &.{},
        .{ .api_version = vulkan.VK_API_VERSION_1_4, .enabled_instance = .{} },
    );
    try std.testing.expectEqual(@as(usize, 0), selected.count);
    try std.testing.expect(!selected.enabled.has(.maintenance6));
}

test "Linux without generated Wayland bindings requests only Xlib WSI" {
    var defaults: request.DefaultRequest = .{};
    defaults.init(.{
        .platform = .linux,
        .api_version = vulkan.VK_API_VERSION_1_1,
        .wayland_bindings = false,
    });
    const rows = defaults.request();
    try std.testing.expectEqual(@as(usize, 2), rows.instance.len);
    try std.testing.expectEqual(dispatch.InstanceExt.surface, rows.instance[0].extension);
    try std.testing.expectEqual(dispatch.InstanceExt.xlib_surface, rows.instance[1].extension);
}
