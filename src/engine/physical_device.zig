//! The physical device: what one adapter's hardware is, before a feature level
//! is chosen.
//!
//! Ports `src/dawn/native/PhysicalDevice.{h,cpp}`.
//!
//! Native capability mapping lives in `native_capabilities.zig`; this record
//! retains the backend identity needed to create the corresponding native device.

const api = @import("../api/api.zig");
const features = @import("features.zig");
const limits = @import("limits.zig");
const native = @import("vulkan_device.zig");

/// The back end a physical device came from. Dawn reaches it through
/// `BackendConnection::GetType` (`BackendConnection.cpp:37-39`); the port
/// keeps the generated enumeration, so the accessor is a field read.
pub const BackendType = api.BackendType;
pub const AdapterType = api.AdapterType;
pub const FeatureLevel = api.FeatureLevel;

/// Which feature levels one physical device can serve. Dawn answers the
/// question one level at a time through `PhysicalDeviceBase::SupportsFeatureLevel`
/// (`PhysicalDevice.h:107-109`) and the null back end answers true for both
/// (`DeviceNull.cpp:72-74`), so the port records the pair as one value.
pub const FeatureLevelSupport = struct {
    compatibility: bool = false,
    core: bool = false,

    /// `undefined_` names "the caller asked for no level", which is what
    /// `Adapter.cpp:64` refuses. It is not a level a device can serve.
    pub fn contains(self: FeatureLevelSupport, level: FeatureLevel) bool {
        return switch (level) {
            .compatibility => self.compatibility,
            .core => self.core,
            .undefined_ => false,
        };
    }
};

/// The outcome of validating one requested feature. Dawn's
/// `FeatureValidationResult` (`PhysicalDevice.h:59-67`) is a flag plus a
/// message, and the message is what the validation error carries, so the two
/// stay together here.
pub const FeatureValidationResult = struct {
    supported: bool = true,
    error_message: []const u8 = "",
};

/// One piece of hardware, as a back end describes it.
///
/// `PhysicalDeviceBase::Initialize` (`PhysicalDevice.cpp:51-75`) fixes the
/// order this record is filled in: the back end's own initialization, the
/// vendor and architecture names, the core-feature gate, five unconditional
/// features, the back end's supported set, then the defaults for the best
/// supported level. `Instance.initializePhysicalDevice` keeps that order.
pub const PhysicalDevice = struct {
    backend_type: BackendType,
    feature_levels: FeatureLevelSupport,
    vendor_id: u32,
    device_id: u32,
    name: []const u8,
    /// Both names come from `gpu_info::GetVendorName` and
    /// `gpu_info::GetArchitectureName` (`PhysicalDevice.cpp:85-88`), which are
    /// generated from `src/dawn/gpu_info.json`. The generator returns an empty
    /// string for a vendor it does not know
    /// (`generator/templates/dawn/common/GPUInfo.cpp:155,162`), which is what a
    /// back end that reports vendor zero gets.
    vendor_name: []const u8,
    architecture_name: []const u8,
    adapter_type: AdapterType,
    subgroup_min_size: u32,
    subgroup_max_size: u32,
    supports_external_images: bool,
    supported_features: features.FeaturesSet,
    /// The defaults for the best level this device serves, which is
    /// `GetDefaultLimitsForSupportedFeatureLevel` (`PhysicalDevice.cpp:139-144`).
    limits: limits.CombinedLimits,
    /// Borrows the Instance backend, including cached queue-family storage.
    /// Null physical devices have no native payload.
    native_adapter: ?native.Adapter = null,
    maintenance4_supported: bool = false,
    maintenance4_extension: bool = false,
    /// Devices retaining this physical row, including standalone Adapter users.
    live_device_count: u64 = 0,

    pub fn getBackendType(self: *const PhysicalDevice) BackendType {
        return self.backend_type;
    }

    pub fn getVendorId(self: *const PhysicalDevice) u32 {
        return self.vendor_id;
    }

    pub fn getDeviceId(self: *const PhysicalDevice) u32 {
        return self.device_id;
    }

    pub fn getVendorName(self: *const PhysicalDevice) []const u8 {
        return self.vendor_name;
    }

    pub fn getArchitectureName(self: *const PhysicalDevice) []const u8 {
        return self.architecture_name;
    }

    pub fn getName(self: *const PhysicalDevice) []const u8 {
        return self.name;
    }

    pub fn getAdapterType(self: *const PhysicalDevice) AdapterType {
        return self.adapter_type;
    }

    pub fn getSubgroupMinSize(self: *const PhysicalDevice) u32 {
        return self.subgroup_min_size;
    }

    pub fn getSubgroupMaxSize(self: *const PhysicalDevice) u32 {
        return self.subgroup_max_size;
    }

    pub fn getLimits(self: *const PhysicalDevice) limits.CombinedLimits {
        return self.limits;
    }

    /// Adds one feature to the supported set. Dawn's `EnableFeature`
    /// (`PhysicalDevice.cpp:173-175`) has no validation, because only
    /// `Initialize` calls it and only with a feature the back end chose.
    pub fn enableFeature(self: *PhysicalDevice, feature: features.Feature) void {
        self.supported_features.enable(feature);
    }

    pub fn isFeatureEnabled(self: *const PhysicalDevice, feature: features.Feature) bool {
        return self.supported_features.isEnabled(feature);
    }

    /// Whether this device serves `level`. Dawn asks the back end
    /// (`PhysicalDevice.cpp:141`); the port reads the recorded pair.
    pub fn supportsFeatureLevel(self: *const PhysicalDevice, level: FeatureLevel) bool {
        return self.feature_levels.contains(level);
    }

    /// `ValidateFeatureSupportedWithToggles` (`PhysicalDevice.cpp:177-202`)
    /// without the toggle argument: the `allow_unsafe_apis` gate is a call on
    /// the toggle table M7 owns, and the back-end hook below is the tail of the
    /// same function.
    pub fn validateFeatureSupported(
        self: *const PhysicalDevice,
        feature: features.Feature,
    ) FeatureValidationResult {
        if (!self.supported_features.isEnabled(feature)) return .{
            .supported = false,
            .error_message = "the requested feature is not supported",
        };
        return .{};
    }

    /// `SupportsAllRequiredFeatures` (`PhysicalDevice.cpp:158-167`): every
    /// name the caller asked for must be in the set, and the first one that is
    /// not is the failure.
    pub fn supportsAllRequiredFeatures(
        self: *const PhysicalDevice,
        required: []const api.FeatureName,
    ) FeatureValidationResult {
        // Bound: the slice the caller passed. No other bound is possible.
        for (required) |name| {
            const result = self.validateFeatureSupported(features.fromApiName(name));
            if (!result.supported) return .{
                .supported = false,
                // `api.FeatureName` is a plain enumeration
                // (`src/api/enums.zig:446-514`) with no `name` method, so the
                // tag is read the way Zig spells it. The port names the API
                // name here because that is what a caller passed in.
                .error_message = @tagName(name),
            };
        }
        return .{};
    }
};
