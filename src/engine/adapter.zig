//! The adapter: one physical device at one feature level, and the only object
//! that creates a device.
//!
//! Ports `src/dawn/native/Adapter.{h,cpp}`.
//!
//! Native queue construction belongs to `native_device_context.zig`. The adapter
//! validates requests and preserves Dawn's successful-creation consumption latch.

const std = @import("std");
const constants = @import("../api/constants.zig");
const api = @import("../api/api.zig");
const device_mod = @import("device.zig");
const features = @import("features.zig");
const instance_mod = @import("instance.zig");
const limits = @import("limits.zig");
const physical_device = @import("physical_device.zig");
const root = @import("async_root_requests.zig");

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
    /// Borrows physical storage from its owning list. The row and this adapter
    /// must stay at their final addresses while a Device borrows them.
    physical_device: *physical_device.PhysicalDevice,
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
    /// Successful devices borrowing this adapter and its owning list.
    live_device_count: u64 = 0,
    /// Request pins and successful child counts share the Instance lifecycle gate.
    active_root_requests: usize = 0,
    root_record: root.RootRecord = .{ .kind = .adapter },

    pub const InitOptions = struct {
        feature_level: FeatureLevel,
        power_preference: PowerPreference,
    };

    /// `AdapterBase::AdapterBase` (`Adapter.cpp:54-72`) with the two
    /// `DAWN_CHECK`s turned into the error the port reports.
    pub fn init(
        instance: *instance_mod.Instance,
        device: *physical_device.PhysicalDevice,
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

    /// `AdapterBase::APIGetInfo` (`Adapter.cpp:120-158`), populated from the
    /// selected backend's physical capability record.
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

    /// Validates and creates under one parent-pinned, serialized transaction.
    /// Failure leaves the latch and parent counts unchanged and releases every creation pin.
    pub fn createDevice(
        self: *Adapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: device_mod.Device.CreateDeviceOptions,
    ) (Error || device_mod.Device.InitError || root.RootWorkError)!device_mod.Device {
        var permit = try self.instance.beginDeviceCreation(io, self, options.consume_adapter);
        defer permit.deinit(io);
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

        // `DeviceBase::DeviceBase` and `DeviceBase::Initialize`
        // (`Device.cpp:275-393`, `:401-452`) are members of `DeviceBase`, not
        // file-level functions, so the port's call names its own `Device`.
        var created = try device_mod.Device.init(allocator, io, .{
            .adapter = self,
            .label = options.label,
            .default_queue_label = options.default_queue_label,
            .required_features = options.required_features,
            .timestamp_quantization = options.timestamp_quantization,
            .feature_level = self.feature_level,
            .required_limits = options.required_limits,
            .object_mutex = options.object_mutex,
            .uncaptured_context = options.uncaptured_context,
            .uncaptured_callback = options.uncaptured_callback,
        }, &permit);
        // Write then read back: the device's level is the adapter's. Its
        // compatibility mode is not read back here, because no adapter state
        // decides it: `Device.cpp:1730-1732` turns the core feature on for a
        // caller that requires it, whatever this adapter's level was, and the
        // request belongs to this adapter's caller, not to this adapter.
        std.debug.assert(created.getFeatureLevel() == self.feature_level);
        return created;
    }

    /// Native observation of the same owned high Device used by generated requests.
    /// Consume a successful result once. Cancellation abandons only observation.
    pub fn requestDeviceAsync(
        self: *Adapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: ?*const api.descriptors.DeviceDescriptorChain,
    ) api.AsyncStartError!std.Io.Future(root.RootOutcome(*root.OwnedDevice)) {
        return root.requestDeviceAsync(self, allocator, io, descriptor);
    }

    /// `Adapter.cpp:293` calls `ValidateLimits`, which is a `Limits.cpp` row and
    /// lands with M7's pipeline. The check itself is a field-by-field
    /// comparison, and the field list is the generated `api.Limits`, so the
    /// sweep below is the whole of it: a field left undefined asks for
    /// nothing, and every other field must be at or below the adapter's value.
    fn validateRequiredLimits(self: *const Adapter, required: *const api.Limits) Error!void {
        const offered = &self.limits.v1;
        // Field types are comptime-only. The skip below is a nested `if` rather
        // than `continue`, because the comparison is evaluated at runtime.
        const info = @typeInfo(api.Limits).@"struct";
        inline for (info.field_names, info.field_types) |field_name, Field| {
            const asked: Field = @field(required, field_name);
            const have: Field = @field(offered, field_name);
            if (asked != undefinedLimit(Field)) {
                const minimum = comptime std.mem.startsWith(u8, field_name, "min_");
                if (minimum) {
                    if (asked < have) return error.RequiredLimitAboveAdapterLimit;
                } else {
                    if (asked > have) return error.RequiredLimitAboveAdapterLimit;
                }
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
