const std = @import("std");
const dusk = @import("dusk");
const vk = @import("vulkan");
const t = std.testing;
const native = dusk.engine.vulkan_device;
const capabilities = dusk.engine.native_capabilities;

fn physicalRecord(families: []vk.VkQueueFamilyProperties) native.PhysicalDevice {
    var result: native.PhysicalDevice = .{
        .handle = null,
        .properties = std.mem.zeroes(vk.VkPhysicalDeviceProperties),
        .features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures),
        .memory_properties = std.mem.zeroes(vk.VkPhysicalDeviceMemoryProperties),
        .max_buffer_size = 1024,
        .queue_families = families,
    };
    result.properties.limits.timestampComputeAndGraphics = vk.VK_TRUE;
    result.properties.limits.timestampPeriod = 1.0;
    result.properties.limits.maxPushConstantsSize = 128;
    return result;
}

fn universalFamily(valid_bits: u32) vk.VkQueueFamilyProperties {
    return .{
        .queueFlags = vk.VK_QUEUE_GRAPHICS_BIT | vk.VK_QUEUE_COMPUTE_BIT,
        .queueCount = 1,
        .timestampValidBits = valid_bits,
        .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 },
    };
}

test "native indirect first instance advertisement follows the physical feature" {
    var families = [_]vk.VkQueueFamilyProperties{universalFamily(64)};
    var physical = physicalRecord(&families);
    try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.indirect_first_instance));
    physical.features.drawIndirectFirstInstance = vk.VK_TRUE;
    try t.expect(capabilities.fromNative(&physical).supported_features.isEnabled(.indirect_first_instance));
    physical.features.drawIndirectFirstInstance = vk.VK_FALSE;
    try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.indirect_first_instance));
}

test "native timestamp advertisement requires the selected universal queue capability" {
    var families = [_]vk.VkQueueFamilyProperties{ universalFamily(0), universalFamily(64) };
    var physical = physicalRecord(&families);
    try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
    for ([_]u32{ 1, 32, 63, 64 }) |bits| {
        families[0].timestampValidBits = bits;
        try t.expect(capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
    }
    families[0].timestampValidBits = 65;
    try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
    families[0].queueCount = 0;
    try t.expect(capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
    families[1].queueFlags = vk.VK_QUEUE_COMPUTE_BIT;
    try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
}

test "native timestamp advertisement requires graphics compute support and a usable period" {
    var families = [_]vk.VkQueueFamilyProperties{universalFamily(64)};
    var physical = physicalRecord(&families);
    for ([_]f32{ 0.0, -1.0, std.math.inf(f32), std.math.nan(f32) }) |period| {
        physical.properties.limits.timestampPeriod = period;
        try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
    }
    physical.properties.limits.timestampPeriod = @bitCast(@as(u32, 1));
    try t.expect(capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
    physical.properties.limits.timestampComputeAndGraphics = vk.VK_FALSE;
    try t.expect(!capabilities.fromNative(&physical).supported_features.isEnabled(.timestamp_query));
}

fn nullDevice(
    _: vk.VkPhysicalDevice,
    _: [*c]const vk.VkDeviceCreateInfo,
    _: [*c]const vk.VkAllocationCallbacks,
    result: [*c]vk.VkDevice,
) callconv(.c) vk.VkResult {
    result.* = null;
    return vk.VK_SUCCESS;
}

fn missingDeviceProc(_: vk.VkDevice, _: [*c]const u8) callconv(.c) vk.PFN_vkVoidFunction {
    return null;
}

test "native utility feature admission refuses unsupported physical requests" {
    var handles: native.HandleSet = .{};
    var backend = native.Backend.init(t.allocator, .{ .handles = &handles });
    defer backend.deinit() catch @panic("backend teardown failed");
    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();
    try t.expect(adapters.items.len != 0);
    const adapter = try adapters.first();
    var physical = adapter.physical;
    physical.features.drawIndirectFirstInstance = vk.VK_FALSE;
    try t.expectError(error.UnsupportedRequiredFeature, native.Device.create(t.allocator, .{
        .instance = adapter.instance,
        .physical = &physical,
        .handles = &handles,
        .required_features = &.{.indirect_first_instance},
    }));
    physical.properties.limits.timestampComputeAndGraphics = vk.VK_FALSE;
    try t.expectError(error.UnsupportedRequiredFeature, native.Device.create(t.allocator, .{
        .instance = adapter.instance,
        .physical = &physical,
        .handles = &handles,
        .required_features = &.{.timestamp_query},
    }));
    physical.properties.limits.timestampComputeAndGraphics = vk.VK_TRUE;
    for ([_]f32{ 0.0, -1.0, std.math.inf(f32), std.math.nan(f32) }) |period| {
        physical.properties.limits.timestampPeriod = period;
        try t.expectError(error.UnsupportedRequiredFeature, native.Device.create(t.allocator, .{
            .instance = adapter.instance,
            .physical = &physical,
            .handles = &handles,
            .required_features = &.{.timestamp_query},
        }));
    }
    physical.properties.limits.timestampPeriod = 1.0;
    var families = [_]vk.VkQueueFamilyProperties{universalFamily(0)};
    physical.queue_families = &families;
    for ([_]u32{ 0, 65 }) |bits| {
        families[0].timestampValidBits = bits;
        try t.expectError(error.UnsupportedRequiredFeature, native.Device.create(t.allocator, .{
            .instance = adapter.instance,
            .physical = &physical,
            .handles = &handles,
            .required_features = &.{.timestamp_query},
        }));
    }
    try t.expectEqual(@as(u32, 0), handles.countOf(.device));
}

test "native utility device creation refuses missing procedures and null devices" {
    var handles: native.HandleSet = .{};
    var backend = native.Backend.init(t.allocator, .{ .handles = &handles });
    defer backend.deinit() catch @panic("backend teardown failed");
    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();
    try t.expect(adapters.items.len != 0);
    const adapter = try adapters.first();
    var instance = adapter.instance.*;
    var procs = adapter.instance.procs.*;
    instance.procs = &procs;
    const options: native.Device.CreateOptions = .{
        .instance = &instance,
        .physical = &adapter.physical,
        .handles = &handles,
    };
    inline for (.{ "create_device", "destroy_device", "get_device_proc_addr" }) |field| {
        procs = adapter.instance.procs.*;
        @field(procs, field) = null;
        try t.expectError(error.MissingInstanceProc, native.Device.create(t.allocator, options));
        try t.expectEqual(@as(u32, 0), handles.countOf(.device));
    }
    procs = adapter.instance.procs.*;
    procs.create_device = nullDevice;
    try t.expectError(error.DeviceCreationReturnedNull, native.Device.create(t.allocator, options));
    try t.expectEqual(@as(u32, 0), handles.countOf(.device));
    procs = adapter.instance.procs.*;
    procs.get_device_proc_addr = missingDeviceProc;
    try t.expectError(error.MissingDeviceProc, native.Device.create(t.allocator, options));
    try t.expectEqual(@as(u32, 0), handles.countOf(.device));
}

test "native utility requested features enable only their supported native requirements" {
    var handles: native.HandleSet = .{};
    var backend = native.Backend.init(t.allocator, .{ .handles = &handles });
    defer backend.deinit() catch @panic("backend teardown failed");
    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();
    try t.expect(adapters.items.len != 0);
    const adapter = try adapters.first();
    var plain = try native.Device.create(t.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });
    defer plain.deinit(t.allocator) catch @panic("device teardown failed");
    try t.expectEqual(vk.VK_FALSE, plain.enabled_features.drawIndirectFirstInstance);
    try t.expectEqual(vk.VK_FALSE, plain.enabled_features.shaderInt64);
    try t.expectEqual(vk.VK_FALSE, plain.enabled_features.shaderFloat64);
    try t.expectEqual(adapter.physical.properties.limits.maxPushConstantsSize, plain.physical.properties.limits.maxPushConstantsSize);
    try t.expectEqual(adapter.physical.properties.limits.timestampPeriod, plain.timestamp_period);
    try t.expectEqual(adapter.physical.queue_families[plain.queue_family_index].timestampValidBits, plain.timestamp_valid_bits);
    const offered = capabilities.fromNative(&adapter.physical).supported_features;
    var required: [2]dusk.api.FeatureName = undefined;
    var count: usize = 0;
    if (offered.isEnabled(.indirect_first_instance)) {
        required[count] = .indirect_first_instance;
        count += 1;
    }
    if (offered.isEnabled(.timestamp_query)) {
        required[count] = .timestamp_query;
        count += 1;
    }
    var requested = try native.Device.create(t.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
        .required_features = required[0..count],
    });
    defer requested.deinit(t.allocator) catch @panic("device teardown failed");
    try t.expectEqual(@as(vk.VkBool32, @intFromBool(offered.isEnabled(.indirect_first_instance))), requested.enabled_features.drawIndirectFirstInstance);
    try t.expectEqual(vk.VK_FALSE, requested.enabled_features.shaderInt64);
    try t.expectEqual(vk.VK_FALSE, requested.enabled_features.shaderFloat64);
    if (offered.isEnabled(.timestamp_query)) {
        try t.expect(requested.timestamp_valid_bits >= 1);
        try t.expect(requested.timestamp_valid_bits <= 64);
        try t.expect(std.math.isFinite(requested.timestamp_period));
        try t.expect(requested.timestamp_period > 0);
    }
}
