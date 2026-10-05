//! The adapter: one physical device at one feature level, and the only object
//! that creates a device.
//!
//! Ports `src/dawn/native/Adapter.{h,cpp}`. `docs/40-plan.md` §3.3 `#### M8`
//! holds the row table.
//!
//! **What this file does not claim.** It does not claim a queue. Upstream's
//! `AdapterBase::CreateDeviceInternal` builds none: it calls the physical
//! device's `CreateDevice` (`Adapter.cpp:308-309`), and the back end is what
//! creates the descriptor's default queue (`vulkan/DeviceVk.cpp:152`) and
//! hands it to `DeviceBase::Initialize` (`Device.cpp:401-403`,
//! `vulkan/DeviceVk.cpp:205`). That queue lands at M9.

const std = @import("std");
const constants = @import("../api/constants.zig");
const api = @import("../api/api.zig");
const device_mod = @import("device.zig");
const features = @import("features.zig");
const instance_mod = @import("instance.zig");
const limits = @import("limits.zig");
const physical_device = @import("physical_device.zig");

pub const FeatureLevel = api.FeatureLevel;
pub const PowerPreference = api.PowerPreference;

/// Everything `AdapterBase::CreateDeviceInternal` (`Adapter.cpp:238-322`) can
/// refuse, plus the allocation failures the port adds where Dawn's reference
/// counting does not.
pub const Error = std.mem.Allocator.Error || error{
    /// `Adapter.cpp:64` checks `SupportsFeatureLevel` in a `DAWN_CHECK`, so
    /// upstream asserts where the port reports. A back end answers the check,
    /// and one of them refuses an undefined level by trapping
    /// (`d3d11/PhysicalDeviceD3D11.cpp:65-75`).
    FeatureLevelUnsupported,
    /// `Adapter.cpp:280-285`: a required feature the physical device does not
    /// have in its supported set.
    RequiredFeatureUnsupported,
    /// `Adapter.cpp:293`: a required limit above what this adapter offers.
    RequiredLimitAboveAdapterLimit,
    /// `Adapter.cpp:305-306`: this adapter already built a device, and
    /// `:313-316` closes the latch unless the instance allows more than one
    /// device per adapter or the descriptor asks for it.
    AdapterConsumed,
    /// No upstream row. Dawn copies a compatibility block only when the chain
    /// carries one (`Limits.cpp:228-231`) and refuses nothing when it does
    /// not, so `Device.init` is where the port refuses. The adapter cannot
    /// pre-check it either: it holds the same `CombinedLimits` the device
    /// resolves from, and the device is where the resolution happens.
    LimitsCompatibilityBlockMissing,
};

/// One physical device at one feature level.
///
/// Dawn's `AdapterBase` caches the physical device's supported features and its
/// limits in its constructor (`Adapter.cpp:68-71`) and refuses to be built for
/// a level its physical device does not serve (`Adapter.cpp:64`).
pub const Adapter = struct {
    instance: *instance_mod.Instance,
    /// Points into the instance's own slice, so it never moves. Upstream holds
    /// a `Ref<PhysicalDeviceBase>` for the same reason (`Adapter.h:111`).
    physical_device: *const physical_device.PhysicalDevice,
    /// The level this adapter defaults to (`Adapter.h:89-90`). It is not the
    /// device's compatibility mode: a device is in compatibility mode when the
    /// core feature is absent from its enabled set (`Device.cpp:1840-1842`),
    /// and a caller can require that feature on a compatibility-level adapter
    /// (`Device.cpp:1730-1732`). Upstream `AdapterBase` has no compatibility
    /// predicate, because no adapter state answers that question. `Device.init`
    /// owns the rule.
    feature_level: FeatureLevel,
    power_preference: PowerPreference,
    supported_features: features.FeaturesSet,
    /// The adapter's limits. `UpdateLimits` (`Adapter.cpp:100-107`) copies the
    /// physical device's and would then apply tiers; tiers land with M7's
    /// pipeline, so the copy is the whole of it.
    limits: limits.CombinedLimits,
    is_consumed: bool = false,

    pub const InitOptions = struct {
        feature_level: FeatureLevel,
        power_preference: PowerPreference,
    };

    /// `AdapterBase::AdapterBase` (`Adapter.cpp:54-72`) with the two
    /// `DAWN_CHECK`s turned into the error the port reports.
    pub fn init(
        instance: *instance_mod.Instance,
        device: *const physical_device.PhysicalDevice,
        options: InitOptions,
    ) Error!Adapter {
        if (!device.supportsFeatureLevel(options.feature_level)) {
            return error.FeatureLevelUnsupported;
        }
        const created: Adapter = .{
            .instance = instance,
            .physical_device = device,
            .feature_level = options.feature_level,
            .power_preference = options.power_preference,
            // `Adapter.cpp:68` caches the physical device's set. M8 has no
            // toggle state, so the cached set is the supported set.
            .supported_features = device.supported_features,
            .limits = device.limits,
        };
        // Write then read back: the level and the limits a caller reads first
        // are the ones the constructor just cached.
        std.debug.assert(created.getFeatureLevel() == created.feature_level);
        std.debug.assert(created.getLimits().v1.max_bind_groups ==
            created.limits.v1.max_bind_groups);
        return created;
    }

    pub fn getInstance(self: *const Adapter) *instance_mod.Instance {
        return self.instance;
    }

    pub fn getPhysicalDevice(self: *const Adapter) *const physical_device.PhysicalDevice {
        return self.physical_device;
    }

    /// `AdapterBase::GetFeatureLevel` (`Adapter.cpp:444-446`).
    pub fn getFeatureLevel(self: *const Adapter) FeatureLevel {
        return self.feature_level;
    }

    /// `AdapterBase::GetName` (`Adapter.cpp:448-450`).
    pub fn getName(self: *const Adapter) []const u8 {
        return self.physical_device.name;
    }

    /// `AdapterBase::GetLimits` (`Adapter.cpp:109-111`) and `APIGetLimits`
    /// (`Adapter.cpp:113-118`).
    pub fn getLimits(self: *const Adapter) limits.CombinedLimits {
        return self.limits;
    }

    /// `AdapterBase::APIGetInfo` (`Adapter.cpp:120-158`). The null back end
    /// answers through `PopulateBackendProperties` (`DeviceNull.cpp:118-134`);
    /// the Vulkan one will answer the same fields from
    /// `vkGetPhysicalDeviceProperties` at M9.
    pub fn getInfo(self: *const Adapter) api.AdapterInfo {
        return .{
            .vendor = self.physical_device.vendor_name,
            .architecture = self.physical_device.architecture_name,
            .device = self.physical_device.name,
            .description = "",
            .backend_type = self.physical_device.backend_type,
            .adapter_type = self.physical_device.adapter_type,
            .vendor_id = self.physical_device.vendor_id,
            .device_id = self.physical_device.device_id,
            .subgroup_min_size = self.physical_device.subgroup_min_size,
            .subgroup_max_size = self.physical_device.subgroup_max_size,
        };
    }

    /// `AdapterBase::APIGetFeatures` (`Adapter.cpp:211-217`). The slice is
    /// `out[0..count]`, ascending by tag, so two runs agree.
    pub fn getFeatures(
        self: *const Adapter,
        out: *[features.feature_count]api.FeatureName,
    ) []const api.FeatureName {
        return self.supported_features.toSupportedFeatures(out);
    }

    /// `AdapterBase::APIHasFeature` (`Adapter.cpp:207-209`).
    pub fn hasFeature(self: *const Adapter, name: api.FeatureName) bool {
        return self.supported_features.isEnabled(features.fromApiName(name));
    }

    /// `AdapterBase::CreateDeviceInternal` (`Adapter.cpp:238-322`).
    ///
    /// The three refusals it makes before it calls the physical device are the
    /// three this function reports besides allocation. The consumption latch at
    /// `:305` is read here and set at `:318`, so the latch closes on success
    /// and not on failure, exactly as upstream does.
    pub fn createDevice(
        self: *Adapter,
        allocator: std.mem.Allocator,
        options: device_mod.Device.CreateDeviceOptions,
    ) Error!device_mod.Device {
        // `SupportsAllRequiredFeatures` (`PhysicalDevice.cpp:158-167`) returns
        // a bool and not an error, so it is read and not `try`-ed; the port
        // widens that bool to a struct that names the first missing feature.
        // `Adapter.cpp:280-285` refuses the same set as
        // `RequiredFeatureUnsupported`.
        const validated = self.physical_device.supportsAllRequiredFeatures(
            options.required_features,
        );
        if (!validated.supported) return error.RequiredFeatureUnsupported;
        if (options.required_limits) |required| {
            try self.validateRequiredLimits(required);
        }
        // `Adapter.cpp:305-306`: the latch is read before the build at
        // `:308-309`, because a failed build must not close it.
        const consume_on_success = !self.instance.hasFeature(.multiple_devices_per_adapter);
        if (self.is_consumed and consume_on_success) return error.AdapterConsumed;

        // `DeviceBase::DeviceBase` and `DeviceBase::Initialize`
        // (`Device.cpp:275-393`, `:401-452`) are members of `DeviceBase`, not
        // file-level functions, so the port's call names its own `Device`.
        var created = try device_mod.Device.init(allocator, .{
            .adapter = self,
            .label = options.label,
            .required_features = options.required_features,
            .feature_level = self.feature_level,
            .uncaptured_context = options.uncaptured_context,
            .uncaptured_callback = options.uncaptured_callback,
        });
        if (consume_on_success) self.is_consumed = true;
        self.instance.addDevice();
        // Write then read back: the device's level is the adapter's. Its
        // compatibility mode is not read back here, because no adapter state
        // decides it: `Device.cpp:1730-1732` turns the core feature on for a
        // caller that requires it, whatever this adapter's level was, and the
        // request belongs to this adapter's caller, not to this adapter.
        std.debug.assert(created.getFeatureLevel() == self.feature_level);
        return created;
    }

    /// `Adapter.cpp:293` calls `ValidateLimits`, which is a `Limits.cpp` row and
    /// lands with M7's pipeline. The check itself is a field-by-field
    /// comparison, and the field list is the generated `api.Limits`, so the
    /// sweep below is the whole of it: a field left undefined asks for
    /// nothing, and every other field must be at or below the adapter's value.
    fn validateRequiredLimits(self: *const Adapter, required: *const api.Limits) Error!void {
        const offered = &self.limits.v1;
        // `inline for` and not `for`: `std.meta.fields` yields a
        // `StructField`, whose `type` is a type and so does not exist at
        // runtime. The skip below is written as a nested `if` rather than as
        // `continue`, because `continue` in an inline loop is comptime control
        // flow and the decision to skip is a runtime comparison; Zig rejects
        // the two in one statement.
        inline for (std.meta.fields(api.Limits)) |field| {
            const Field = @FieldType(api.Limits, field.name);
            const asked: Field = @field(required, field.name);
            const have: Field = @field(offered, field.name);
            if (asked != undefinedLimit(Field)) {
                if (asked > have) return error.RequiredLimitAboveAdapterLimit;
            }
        }
    }
};

/// `LimitU32Undefined` and `LimitU64Undefined` (`src/api/constants.zig:24,29`)
/// are what an unset limit reads as. The width comes from the field's own type,
/// so one function serves both.
pub fn undefinedLimit(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.bits == 32)
            constants.LimitU32Undefined
        else
            constants.LimitU64Undefined,
        else => @compileError("an api.Limits field must be an integer"),
    };
}
