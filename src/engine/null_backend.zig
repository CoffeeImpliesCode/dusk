//! The null back end: one device that is created without a GPU.
//!
//! Ports `src/dawn/native/null/{DeviceNull.h,DeviceNull.cpp}`.
//!
//! **What this file does not claim.** It does not claim a queue, a buffer, a
//! texture, a bind group, a pipeline or a swap chain. Upstream's `null::Device`
//! answers sixteen `DeviceBase` pure virtuals for objects whose milestones
//! have not landed; each of those rows names the milestone that owns it. What
//! is here is the part that makes every later front-end test possible: a
//! physical device that needs no driver.
//!
//! **No virtual base.** Upstream reaches a back end through `BackendConnection`,
//! an abstract class with one pure virtual (`BackendConnection.h:44-57`).
//! `docs/30-port-design.md` §10.3 refuses that layer, so a back end is a module
//! and `Instance` names it in a `switch`.

const std = @import("std");
const api = @import("../api/api.zig");
const features = @import("features.zig");
const limits = @import("limits.zig");
const physical_device = @import("physical_device.zig");

pub const PhysicalDevice = physical_device.PhysicalDevice;

/// Everything `Backend::DiscoverPhysicalDevices` can report.
pub const DiscoverError = std.mem.Allocator.Error || error{
    /// Dawn's `DiscoverPhysicalDevices` returns a vector and cannot fail
    /// (`BackendConnection.h:55-56`). The port allocates a list, so it can.
    TooManyPhysicalDevices,
};

/// The name upstream gives this device (`DeviceNull.cpp:62`).
pub const device_name = "Null backend";

/// `PhysicalDevice::Create` (`DeviceNull.cpp:52-57`) and its constructor
/// (`DeviceNull.cpp:59-64`).
///
/// The order `PhysicalDeviceBase::Initialize` fixes (`PhysicalDevice.cpp:51-75`)
/// runs in `Instance.initializePhysicalDevice`; this function only fills what
/// the back end owns. `InitializeSupportedFeaturesImpl`
/// (`DeviceNull.cpp:91-96`) enables *every* feature for the convenience of
/// tests, which is a `comptime` sweep over the whole domain.
pub fn createPhysicalDevice() PhysicalDevice {
    var device: PhysicalDevice = .{
        .backend_type = .null_,
        // `SupportsFeatureLevel` (`DeviceNull.cpp:72-74`) answers true for
        // every level, so this one device serves both.
        .feature_levels = .{ .compatibility = true, .core = true },
        // The constructor sets both ids to zero (`DeviceNull.cpp:60-61`), which
        // is why the generated vendor and architecture names are empty.
        .vendor_id = 0,
        .device_id = 0,
        .name = device_name,
        .vendor_name = "",
        .architecture_name = "",
        .adapter_type = .unknown,
        .subgroup_min_size = 0,
        .subgroup_max_size = 0,
        // `SupportsExternalImages` (`DeviceNull.cpp:68-70`) is false.
        .supports_external_images = false,
        .supported_features = .{},
        // `GetDefaultLimitsForSupportedFeatureLevel` (`DeviceNull.cpp:98-102`)
        // with the core defaults, because this device serves core. Its only
        // override is `max_immediate_size = 64` (`DeviceNull.cpp:100`), and the
        // table already carries 64 in both columns (`Limits.cpp:123-124`).
        .limits = limits.defaultLimits(.core),
    };

    // `InitializeSupportedFeaturesImpl` (`DeviceNull.cpp:91-96`). The bound is
    // the domain itself: every member, once.
    inline for (@typeInfo(features.Feature).@"enum".field_names) |field_name| {
        device.enableFeature(@field(features.Feature, field_name));
    }
    return device;
}

/// `Backend::DiscoverPhysicalDevices` (`DeviceNull.cpp:147-158`).
///
/// Returns an empty list when the caller forced a fallback adapter, and one
/// device otherwise. There is always exactly one, because the back end is
/// purely CPU based and does not read the system (`DeviceNull.cpp:152-153`).
pub fn discoverPhysicalDevices(
    allocator: std.mem.Allocator,
    options: api.RequestAdapterOptions,
) DiscoverError!std.ArrayList(PhysicalDevice) {
    if (options.force_fallback_adapter) return .empty;
    var out: std.ArrayList(PhysicalDevice) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, createPhysicalDevice());
    return out;
}

/// `PhysicalDevice::PopulateBackendProperties` (`DeviceNull.cpp:118-134`)
/// without the chains. The memory-heap and D3D blocks are chained structs
/// (`AdapterPropertiesMemoryHeaps` is one, `src/api/descriptors.zig:2215-2218`),
/// and a chained block is only written when the caller's chain names it
/// (`Limits.cpp:475-481` is the same rule). `api.AdapterInfo`
/// (`src/api/descriptors.zig:57-68`) carries none of them, so the port returns
/// the plain record and the chains land with the chain-walking API.
pub fn adapterInfo(device: *const PhysicalDevice) api.AdapterInfo {
    return .{
        .vendor = device.vendor_name,
        .architecture = device.architecture_name,
        .device = device.name,
        .description = "",
        .backend_type = device.backend_type,
        .adapter_type = device.adapter_type,
        .vendor_id = device.vendor_id,
        .device_id = device.device_id,
        .subgroup_min_size = device.subgroup_min_size,
        .subgroup_max_size = device.subgroup_max_size,
    };
}
