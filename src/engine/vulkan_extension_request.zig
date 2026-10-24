//! The sole request/name intersection authority. Selected names own no allocation and remain
//! valid when the value moves. Enumeration buffers belong to the supplied allocator.
const std = @import("std");
const dispatch = @import("../vk/dispatch.zig");
const vulkan = @import("vulkan");

pub const ExtensionRequirement = enum { optional, required };
pub const RequestedInstanceExtension = struct {
    extension: dispatch.InstanceExt,
    requirement: ExtensionRequirement,
};
pub const RequestedDeviceExtension = struct {
    extension: dispatch.DeviceExt,
    requirement: ExtensionRequirement,
};
pub const VulkanExtensionRequest = struct {
    instance: []const RequestedInstanceExtension,
    device: []const RequestedDeviceExtension,
};
pub const instance_extension_count = @typeInfo(dispatch.InstanceExt).@"enum".field_names.len;
pub const device_extension_count = @typeInfo(dispatch.DeviceExt).@"enum".field_names.len;
pub const SelectionError = error{ ExtensionUnavailable, ExtensionDependencyUnavailable };
pub const EnumerationError = std.mem.Allocator.Error || dispatch.Error || dispatch.LoadError ||
    error{ExtensionEnumerationUnstable};
pub const enumeration_attempt_count = 3;

pub const InstanceSelection = struct {
    enabled: dispatch.EnabledInstanceExts = .{},
    names: [instance_extension_count][*:0]const u8 = undefined,
    count: usize = 0,

    pub fn namePointers(self: *const InstanceSelection) []const [*:0]const u8 {
        return self.names[0..self.count];
    }
};
pub const DeviceSelection = struct {
    enabled: dispatch.EnabledDeviceExts = .{},
    names: [device_extension_count][*:0]const u8 = undefined,
    count: usize = 0,

    pub fn namePointers(self: *const DeviceSelection) []const [*:0]const u8 {
        return self.names[0..self.count];
    }
};
pub const DeviceDependencies = struct {
    api_version: u32,
    enabled_instance: dispatch.EnabledInstanceExts,
};

fn advertised(properties: []const vulkan.VkExtensionProperties, name: []const u8) bool {
    for (properties) |*property| {
        const bytes = &property.extensionName;
        const length = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
        if (std.mem.eql(u8, bytes[0..length], name)) return true;
    }
    return false;
}

/// Duplicate requests merge; required always wins. No available but unrequested name is enabled.
pub fn selectInstance(
    requested: []const RequestedInstanceExtension,
    properties: []const vulkan.VkExtensionProperties,
) SelectionError!InstanceSelection {
    var selected: InstanceSelection = .{};
    var required: dispatch.EnabledInstanceExts = .{};
    for (requested) |row| {
        if (row.requirement == .required) required = required.with(row.extension);
        if (advertised(properties, row.extension.vkName())) {
            selected.enabled = selected.enabled.with(row.extension);
        } else if (row.requirement == .required) return error.ExtensionUnavailable;
    }
    // Removing optional dependents reaches a fixed point in at most one pass per enum member.
    for (0..instance_extension_count) |_| {
        var changed = false;
        for (std.enums.values(dispatch.InstanceExt)) |extension| {
            if (!selected.enabled.has(extension)) continue;
            const satisfied = switch (extension) {
                .xlib_surface, .wayland_surface, .android_surface => selected.enabled.has(.surface),
                .external_memory_capabilities, .external_semaphore_capabilities => selected.enabled.has(.get_physical_device_properties2),
                else => true,
            };
            if (satisfied) continue;
            if (required.has(extension)) return error.ExtensionDependencyUnavailable;
            selected.enabled.bits &= ~@backingInt(extension);
            changed = true;
        }
        if (!changed) break;
    }
    for (std.enums.values(dispatch.InstanceExt)) |extension| {
        if (!selected.enabled.has(extension)) continue;
        selected.names[selected.count] = extension.vkName().ptr;
        selected.count += 1;
    }
    return selected;
}

fn deviceDependencySatisfied(
    extension: dispatch.DeviceExt,
    enabled: dispatch.EnabledDeviceExts,
    dependencies: DeviceDependencies,
) bool {
    const core11 = dependencies.api_version >= vulkan.VK_API_VERSION_1_1;
    const core12 = dependencies.api_version >= vulkan.VK_API_VERSION_1_2;
    return switch (extension) {
        .swapchain => dependencies.enabled_instance.has(.surface),
        .external_memory => core11 or
            dependencies.enabled_instance.has(.external_memory_capabilities),
        .external_semaphore => core11 or
            dependencies.enabled_instance.has(.external_semaphore_capabilities),
        .external_memory_fd, .external_memory_host => core11 or enabled.has(.external_memory),
        .external_memory_dma_buf => enabled.has(.external_memory_fd),
        .external_semaphore_fd => core11 or enabled.has(.external_semaphore),
        .dedicated_allocation => core11 or enabled.has(.get_memory_requirements2),
        .get_memory_requirements2, .bind_memory2, .maintenance1, .image_format_list => true,
        .sampler_ycbcr_conversion => core11 or
            (enabled.has(.maintenance1) and enabled.has(.bind_memory2) and
                enabled.has(.get_memory_requirements2) and
                dependencies.enabled_instance.has(.get_physical_device_properties2)),
        .image_drm_format_modifier => (core11 or enabled.has(.bind_memory2)) and
            (core12 or enabled.has(.image_format_list)) and
            (core11 or enabled.has(.sampler_ycbcr_conversion)) and
            (core11 or dependencies.enabled_instance.has(.get_physical_device_properties2)),
        .external_memory_android_hardware_buffer => enabled.has(.queue_family_foreign) and
            (core11 or enabled.has(.external_memory)) and
            (core11 or enabled.has(.sampler_ycbcr_conversion)) and
            (core11 or enabled.has(.dedicated_allocation)) and
            (core11 or enabled.has(.get_memory_requirements2)) and
            (core11 or dependencies.enabled_instance.has(.get_physical_device_properties2)),
        .maintenance6 => core11,
        else => true,
    };
}

fn devicePromoted(extension: dispatch.DeviceExt, api_version: u32) bool {
    return switch (extension) {
        .external_memory, .external_semaphore, .sampler_ycbcr_conversion, .dedicated_allocation, .get_memory_requirements2, .bind_memory2, .maintenance1 => api_version >= vulkan.VK_API_VERSION_1_1,
        .image_format_list, .draw_indirect_count, .create_renderpass2 => api_version >= vulkan.VK_API_VERSION_1_2,
        .dynamic_rendering, .maintenance4 => api_version >= vulkan.VK_API_VERSION_1_3,
        .maintenance6 => api_version >= vulkan.VK_API_VERSION_1_4,
        else => false,
    };
}

/// Dependencies use the negotiated instance/physical-device API version, never the Zig target.
/// Missing optional dependencies omit the dependent; required ones fail before vkCreateDevice.
pub fn selectDevice(
    requested: []const RequestedDeviceExtension,
    properties: []const vulkan.VkExtensionProperties,
    dependencies: DeviceDependencies,
) SelectionError!DeviceSelection {
    var selected: DeviceSelection = .{};
    var required: dispatch.EnabledDeviceExts = .{};
    for (requested) |row| {
        if (devicePromoted(row.extension, dependencies.api_version)) continue;
        if (row.requirement == .required) required = required.with(row.extension);
        if (advertised(properties, row.extension.vkName())) {
            selected.enabled = selected.enabled.with(row.extension);
        } else if (row.requirement == .required) return error.ExtensionUnavailable;
    }
    for (0..device_extension_count) |_| {
        var changed = false;
        for (std.enums.values(dispatch.DeviceExt)) |extension| {
            if (!selected.enabled.has(extension)) continue;
            if (deviceDependencySatisfied(extension, selected.enabled, dependencies)) continue;
            if (required.has(extension)) return error.ExtensionDependencyUnavailable;
            selected.enabled.bits &= ~@backingInt(extension);
            changed = true;
        }
        if (!changed) break;
    }
    for (std.enums.values(dispatch.DeviceExt)) |extension| {
        if (!selected.enabled.has(extension)) continue;
        selected.names[selected.count] = extension.vkName().ptr;
        selected.count += 1;
    }
    return selected;
}

pub const Platform = enum { linux, android, other };

/// Stack-owned defaults. request() borrows this value; keep it live through selection only.
pub const DefaultRequest = struct {
    instance: [instance_extension_count]RequestedInstanceExtension = undefined,
    device: [device_extension_count]RequestedDeviceExtension = undefined,
    instance_count: usize = 0,
    device_count: usize = 0,

    pub const Options = struct {
        platform: Platform,
        api_version: u32,
        /// Set from the actual generated platform dispatch, not the target OS.
        wayland_bindings: bool = true,
    };

    pub fn init(self: *DefaultRequest, options: Options) void {
        const platform = options.platform;
        const api_version = options.api_version;
        self.instance_count = 0;
        self.device_count = 0;
        switch (platform) {
            .linux => {
                self.addInstance(.surface);
                self.addInstance(.xlib_surface);
                if (options.wayland_bindings) self.addInstance(.wayland_surface);
            },
            .android => {
                self.addInstance(.surface);
                self.addInstance(.android_surface);
            },
            .other => {},
        }
        self.addDevice(.swapchain);
        if (platform != .other) {
            self.addDevice(.external_semaphore_fd);
            if (platform == .linux) {
                self.addDevice(.external_memory_fd);
                self.addDevice(.external_memory_dma_buf);
                self.addDevice(.image_drm_format_modifier);
                if (api_version < vulkan.VK_API_VERSION_1_2) self.addDevice(.image_format_list);
            } else {
                self.addDevice(.external_memory_android_hardware_buffer);
                self.addDevice(.queue_family_foreign);
                self.addDevice(.maintenance6);
            }
            if (api_version < vulkan.VK_API_VERSION_1_1) {
                self.addInstance(.get_physical_device_properties2);
                self.addInstance(.external_memory_capabilities);
                self.addInstance(.external_semaphore_capabilities);
                self.addDevice(.external_memory);
                self.addDevice(.external_semaphore);
                self.addDevice(.sampler_ycbcr_conversion);
                self.addDevice(.get_memory_requirements2);
                self.addDevice(.dedicated_allocation);
                self.addDevice(.bind_memory2);
                self.addDevice(.maintenance1);
            }
        }
    }

    pub fn request(self: *const DefaultRequest) VulkanExtensionRequest {
        return .{
            .instance = self.instance[0..self.instance_count],
            .device = self.device[0..self.device_count],
        };
    }

    fn addInstance(self: *DefaultRequest, extension: dispatch.InstanceExt) void {
        std.debug.assert(self.instance_count < self.instance.len);
        self.instance[self.instance_count] = .{ .extension = extension, .requirement = .optional };
        self.instance_count += 1;
    }

    fn addDevice(self: *DefaultRequest, extension: dispatch.DeviceExt) void {
        std.debug.assert(self.device_count < self.device.len);
        self.device[self.device_count] = .{ .extension = extension, .requirement = .optional };
        self.device_count += 1;
    }
};

pub const AvailableExtensions = struct {
    allocation: []vulkan.VkExtensionProperties,
    count: usize,

    pub fn items(self: *const AvailableExtensions) []const vulkan.VkExtensionProperties {
        return self.allocation[0..self.count];
    }

    pub fn deinit(self: *AvailableExtensions, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
        self.* = undefined;
    }
};

/// Vulkan enumeration is synchronous and has no Io operation or cancellable wait.
pub fn enumerateInstance(
    allocator: std.mem.Allocator,
    enumerate: vulkan.PFN_vkEnumerateInstanceExtensionProperties,
) EnumerationError!AvailableExtensions {
    return enumerateProperties(allocator, .{
        .instance = enumerate orelse return error.MissingGlobalProc,
    });
}

pub fn enumerateDevice(
    allocator: std.mem.Allocator,
    physical_device: vulkan.VkPhysicalDevice,
    enumerate: vulkan.PFN_vkEnumerateDeviceExtensionProperties,
) EnumerationError!AvailableExtensions {
    return enumerateProperties(allocator, .{ .device = .{
        .physical_device = physical_device,
        .enumerate = enumerate orelse return error.MissingInstanceProc,
    } });
}

const Enumerator = union(enum) {
    instance: @typeInfo(vulkan.PFN_vkEnumerateInstanceExtensionProperties).optional.child,
    device: struct {
        physical_device: vulkan.VkPhysicalDevice,
        enumerate: @typeInfo(vulkan.PFN_vkEnumerateDeviceExtensionProperties).optional.child,
    },

    fn call(self: Enumerator, count: *u32, properties: ?[*]vulkan.VkExtensionProperties) vulkan.VkResult {
        return switch (self) {
            .instance => |enumerate| enumerate(null, count, properties),
            .device => |device| device.enumerate(device.physical_device, null, count, properties),
        };
    }
};

fn enumerateProperties(
    allocator: std.mem.Allocator,
    enumerate: Enumerator,
) EnumerationError!AvailableExtensions {
    for (0..enumeration_attempt_count) |_| {
        var count: u32 = 0;
        const count_result = enumerate.call(&count, null);
        if (count_result == vulkan.VK_INCOMPLETE) continue;
        try dispatch.checkVkSuccess(count_result);
        if (count == 0) return .{ .allocation = &.{}, .count = 0 };
        const properties = try allocator.alloc(vulkan.VkExtensionProperties, count);
        errdefer allocator.free(properties);
        const data_result = enumerate.call(&count, properties.ptr);
        if (data_result == vulkan.VK_INCOMPLETE) {
            allocator.free(properties);
            continue;
        }
        try dispatch.checkVkSuccess(data_result);
        if (count > properties.len) {
            allocator.free(properties);
            continue;
        }
        return .{ .allocation = properties, .count = count };
    }
    return error.ExtensionEnumerationUnstable;
}
