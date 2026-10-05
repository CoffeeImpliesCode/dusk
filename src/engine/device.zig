//! The device: the features and the limits, resolved.
//!
//! Ports the part of `src/dawn/native/Device.{h,cpp}` that exists before any
//! GPU object does — 210 of the 451 rows in `docs/40-plan.md` §3.3 `#### M8`.
//! The other rows in that file belong to the milestones that own the object
//! they create, and each one names its milestone.
//!
//! **What this file does not claim.** It does not claim a queue, a tick, a
//! pipeline cache, a blob cache, a memory tracker or a device mutex. Upstream's
//! `DeviceBase` holds all of them; each row for one says where it lands.

const std = @import("std");
const adapter_mod = @import("adapter.zig");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const error_scope = @import("../core/error_scope.zig");
const features = @import("features.zig");
const instance_mod = @import("instance.zig");
const limits = @import("limits.zig");
const physical_device = @import("physical_device.zig");

pub const Adapter = adapter_mod.Adapter;
pub const FeatureLevel = api.FeatureLevel;
pub const DeviceLostReason = api.DeviceLostReason;
pub const ErrorFilter = api.ErrorFilter;

/// The wire enum and `core`'s filter are different types with different tag
/// values (`src/core/error_scope.zig:17-23`), so the boundary converts one
/// member at a time. No `else`, so a fourth upstream member is a compile error
/// here rather than a scope that silently selects the wrong set.
fn coreFilterFromApi(filter: ErrorFilter) core.ErrorFilter {
    return switch (filter) {
        .validation => .validation,
        .out_of_memory => .out_of_memory,
        .internal => .internal,
    };
}

/// The order of the three passes is the order `DeviceBase::Destroy`
/// (`Device.cpp:550-613`) runs them in.
///
/// `DeviceBase::State` (`Device.h:366-372`) names five values and the port
/// keeps four. `BeingCreated` (`Device.h:367`) is the one it drops: upstream
/// starts a device in that state (`Device.h:707`) and moves it to `Alive` at
/// the end of `Initialize` (`Device.cpp:419`), and the port's `init` is that
/// constructor and that call in one (`Device.cpp:401-452`), so no caller ever
/// holds a device that has a state but no arena.
pub const State = enum {
    alive,
    /// The device is no longer usable because the GPU timeline is draining.
    disconnecting,
    /// Nothing is on the GPU timeline and the CPU data is safe to reclaim.
    disconnected,
    destroyed,
};

/// Everything `Device.init` can refuse, plus the allocation failures the port
/// adds where Dawn's reference counting does not.
pub const InitError = std.mem.Allocator.Error || error{
    /// A device must have the compat block its limits are read through
    /// (`Limits.cpp:475-481`). Dawn can leave it null because
    /// `FillLimits` only writes a chained block the caller's chain names; the
    /// port has no chain, so a device without one cannot exist.
    LimitsCompatibilityBlockMissing,
    /// `Adapter.cpp:64` checks `SupportsFeatureLevel` in a `DAWN_CHECK`; the
    /// port reports it rather than aborting.
    FeatureLevelUnsupported,
};

/// One device: an arena, a scope stack, a resolved feature set and a resolved
/// limit set.
///
/// Dawn's `DeviceBase` is a hub with 54 virtuals. The port does not carry the
/// virtual layer (`docs/30-port-design.md` §10.3), so what is here is the state
/// those virtuals guard, and the readers that state answers.
pub const Device = struct {
    /// The M3 device: the arena every handle names and the error-scope stack
    /// every error passes through. M11, M12 and M14 take this pointer.
    core: core.Device,
    adapter: *const Adapter,
    feature_level: FeatureLevel,
    /// `mEnabledFeatures`, filled by `ApplyFeatures` (`Device.cpp:1723-1762`).
    enabled_features: features.FeaturesSet,
    /// The device's own limits: `GetDefaultLimits` (`Device.cpp:340`) at the
    /// effective level, then `EnforceLimitSpecInvariants`
    /// (`Device.cpp:351`, `Limits.cpp:426-459`), which `DeviceBase`'s
    /// constructor calls. Not the adapter's block, which is fixed for the
    /// physical device's best level (`PhysicalDevice.cpp:139-144`).
    limits: limits.CombinedLimits,
    label: []const u8,
    state: State = .alive,
    lost_reason: ?DeviceLostReason = null,
    lost_message: []const u8 = "",

    /// One `RequestDevice` call: what the caller asks for plus the two facts
    /// the adapter already knows. `Adapter.createDevice` checks the request
    /// against the adapter and hands what survives to `init`, so both
    /// boundaries take this one type.
    pub const CreateDeviceOptions = struct {
        adapter: *const Adapter,
        label: ?[]const u8 = null,
        required_features: []const api.FeatureName = &.{},
        /// `DeviceDescriptor.requiredLimits` (`src/api/descriptors.zig:76`).
        /// `Adapter.cpp:293` validates it against the adapter's own limits
        /// before any device exists, and `init` reads it not at all: the other
        /// arm of `Device.cpp:336-341` is `UnpackLimitsIn` plus
        /// `ReifyDefaultLimits`, and `src/engine/limits.zig:9-14` places both
        /// at M8. So the limits below are always the no-request branch.
        required_limits: ?*const api.Limits = null,
        feature_level: FeatureLevel,
        uncaptured_context: *anyopaque,
        uncaptured_callback: error_scope.UncapturedErrorCallback,
    };

    /// `DeviceBase::DeviceBase` (`Device.cpp:275-393`) and
    /// `DeviceBase::Initialize` (`Device.cpp:401-452`), which upstream splits
    /// across a constructor and a second call only because the back end has to
    /// build the queue in between. The port has no queue yet, so the two are
    /// one function.
    pub fn init(allocator: std.mem.Allocator, options: CreateDeviceOptions) InitError!Device {
        const source = options.adapter.physical_device;
        if (!source.supportsFeatureLevel(options.feature_level)) {
            return error.FeatureLevelUnsupported;
        }

        // The compat block is read by every compatibility check
        // (`docs/10-architecture.md` "Compatibility mode"), so a device without
        // one cannot exist and this is where that is said out loud. It is the
        // ADAPTER's block that is refused: the device's own block is rebuilt
        // from the table below (`Device.cpp:339-341`), and `defaultLimits`
        // (`src/engine/limits.zig:558`) always writes one.
        if (options.adapter.limits.compatibility == null) {
            return error.LimitsCompatibilityBlockMissing;
        }

        // `Device.cpp:292-296`: the features are applied first and the
        // effective level is then read off them, because a caller that
        // requires `core_features_and_limits` on a compatibility adapter
        // turns the core feature on for a compatibility-level device
        // (`Device.cpp:1730-1732`). The level the caller cannot see is not
        // the level the limits are fixed up for.
        const enabled = applyFeatures(
            options.feature_level,
            options.required_features,
        );
        const effective_feature_level: FeatureLevel =
            if (enabled.isEnabled(.core_features_and_limits)) .core else .compatibility;

        // `Device.cpp:339-341`: with no `requiredLimits` the device takes the
        // table defaults at the EFFECTIVE level. The adapter's block was filled
        // for the best level the physical device serves
        // (`PhysicalDevice.cpp:139-144`), so copying it would hand a
        // compatibility device the core compat columns, and
        // `GetDefaultLimits` (`Limits.cpp:185-191`) rewrites every field anyway.
        var resolved = limits.defaultLimits(effective_feature_level);
        // `Device.cpp:351` hands `effectiveFeatureLevel` to
        // `EnforceLimitSpecInvariants` (`Limits.cpp:426-459`), not the adapter's.
        enforceLimitSpecInvariants(&resolved, effective_feature_level);

        var created: Device = .{
            .core = core.Device.init(allocator, .{
                .uncaptured_context = options.uncaptured_context,
                .uncaptured_callback = options.uncaptured_callback,
            }),
            .adapter = options.adapter,
            .feature_level = options.feature_level,
            .enabled_features = enabled,
            .limits = resolved,
            .label = options.label orelse "",
            .state = .alive,
        };
        // Write then read back: the three values a caller reads first.
        std.debug.assert(created.getFeatureLevel() == created.feature_level);
        std.debug.assert(created.limits.compatibility != null);
        // `Device.cpp:1755-1759` turns the core feature on for every core
        // device, so a core device is never in compatibility mode. The
        // converse is not an invariant and no adapter-side rule covers it: a
        // compatibility-level device whose caller required the core feature
        // is out of compatibility mode (`Device.cpp:294-296`), and the adapter
        // never saw the request.
        std.debug.assert(options.feature_level != .core or !created.isCompatibilityMode());
        return created;
    }

    /// Frees everything the device allocated. After this the adapter pointer
    /// and every handle taken before it dangle, and the receiver is poison.
    pub fn deinit(self: *Device, allocator: std.mem.Allocator) void {
        self.releaseEverything(allocator);
        self.* = undefined;
    }

    /// `DeviceBase::Destroy` (`Device.cpp:550-613`) and the two functions it
    /// calls: `SetDisconnectingIfAlive` (`:921-924`) and `Disconnect`
    /// (`:926-951`). Upstream runs `DestroyObjects` (`:500`) between them, which
    /// tears down the object lists; the port's arena goes with
    /// `releaseEverything`.
    ///
    /// The receiver stays readable, because the state it reached is the
    /// observation `test/null_device.zig:464` makes. The arena capacity is not
    /// one: `releaseEverything` runs `core.Device.deinit`, which poisons the
    /// core device, so there is no receiver left to ask.
    pub fn destroy(self: *Device, allocator: std.mem.Allocator) void {
        self.setDisconnectingIfAlive();
        self.disconnect();
        self.releaseEverything(allocator);
        self.state = .destroyed;
    }

    /// The teardown `deinit` and `destroy` share.
    fn releaseEverything(self: *Device, allocator: std.mem.Allocator) void {
        self.core.deinit(allocator);
        // `InstanceBase::RemoveDevice` (`Instance.cpp:640-642`), called from
        // `DeviceBase::WillDropLastExternalRef` upstream (`:493`).
        self.adapter.getInstance().removeDevice();
    }

    /// `DeviceBase::SetDisconnectingIfAlive` (`:921-924`). The exchange is a
    /// compare-and-swap upstream and a guard here, because M8 has no device
    /// mutex; M9 takes the lock (`Device.cpp:2652`).
    pub fn setDisconnectingIfAlive(self: *Device) void {
        if (self.state == .alive) self.state = .disconnecting;
    }

    /// `DeviceBase::Disconnect` (`:926-951`). The queue wait and the tick at
    /// `:942-948` land at M9 with the queue; what remains is the transition.
    pub fn disconnect(self: *Device) void {
        switch (self.state) {
            .disconnected, .destroyed => return,
            // `Device.cpp:931` calls this unreachable, and so does the port:
            // a destroyed device is already disconnected.
            .alive, .disconnecting => self.state = .disconnected,
        }
    }

    /// `DeviceBase::GetState` (`:909-912`).
    pub fn getState(self: *const Device) State {
        return self.state;
    }

    /// `DeviceBase::IsLost` (`:914-919`), which upstream answers from the state
    /// and which the port answers from the recorded reason, because a device
    /// can be lost while still alive.
    pub fn isLost(self: *const Device) bool {
        return self.lost_reason != null;
    }

    /// `DeviceBase::HandleDeviceLost` (`:619-623`).
    pub fn handleDeviceLost(
        self: *Device,
        reason: DeviceLostReason,
        message: []const u8,
    ) void {
        if (self.lost_reason != null) return;
        self.lost_reason = reason;
        self.lost_message = message;
        self.setDisconnectingIfAlive();
    }

    pub fn getInstance(self: *const Device) *const instance_mod.Instance {
        return self.adapter.getInstance();
    }

    /// `DeviceBase::GetAdapter` (`:965-967`) and `APIGetAdapter` (`:1628-1631`).
    pub fn getAdapter(self: *const Device) *const Adapter {
        return self.adapter;
    }

    /// `DeviceBase::GetPhysicalDevice` (`:969-971`).
    pub fn getPhysicalDevice(self: *const Device) *const physical_device.PhysicalDevice {
        return self.adapter.getPhysicalDevice();
    }

    pub fn getFeatureLevel(self: *const Device) FeatureLevel {
        return self.feature_level;
    }

    /// `DeviceBase::GetQueue` (`:1994-1996`) is M9. `coreDevice` is the seam
    /// every object creator above `engine` takes instead: M11, M12 and M14 pass
    /// this pointer where upstream passes `DeviceBase*`.
    pub fn coreDevice(self: *Device) *core.Device {
        return &self.core;
    }

    /// `DeviceBase::GetLimits` (`:2506-2508`) and `APIGetLimits` (`:1920-1925`).
    pub fn getLimits(self: *const Device) limits.CombinedLimits {
        return self.limits;
    }

    /// `DeviceBase::HasFeature` (`:1764-1766`) and `APIHasFeature`
    /// (`:1927-1929`).
    pub fn hasFeature(self: *const Device, name: api.FeatureName) bool {
        return self.enabled_features.isEnabled(features.fromApiName(name));
    }

    /// `DeviceBase::APIGetFeatures` (`:1931-1937`).
    pub fn getFeatures(
        self: *const Device,
        out: *[features.feature_count]api.FeatureName,
    ) []const api.FeatureName {
        return self.enabled_features.toSupportedFeatures(out);
    }

    /// `DeviceBase::IsCompatibilityMode` (`Device.cpp:1840-1842`): a device is in
    /// compatibility mode when the core feature is absent from the ENABLED set.
    /// That is not a question about the adapter. `Device.cpp:1730-1732` enables
    /// the same feature for any caller that requires it, whatever level the
    /// adapter was enumerated at, and `Device.cpp:294-296` reads the effective
    /// level back off this feature rather than off the adapter. The one rule
    /// drives limit selection (`docs/10-architecture.md` "Compatibility mode"),
    /// and `init` fixes the limits up under the level this returns.
    pub fn isCompatibilityMode(self: *const Device) bool {
        return !self.hasFeature(.core_features_and_limits);
    }

    /// `DeviceBase::APISetLabel` (`:2534-2539`) and `SetLabelImpl` (`:2539`),
    /// which has an empty body upstream because the arena owns the string.
    pub fn setLabel(self: *Device, label: []const u8) void {
        self.label = label;
    }

    /// `DeviceBase::GetLabel` (`:2530-2532`).
    pub fn getLabel(self: *const Device) []const u8 {
        return self.label;
    }

    /// `DeviceBase::GetErrorScopeStack` (`:733-748`) and the three error entry
    /// points below it. M3 put the stack and the sink on `core.Device`, so these
    /// forward rather than hold a second stack.
    pub fn pushErrorScope(
        self: *Device,
        allocator: std.mem.Allocator,
        filter: ErrorFilter,
    ) std.mem.Allocator.Error!void {
        return self.core.pushErrorScope(allocator, coreFilterFromApi(filter));
    }

    /// `DeviceBase::APIPopErrorScope` (`:758-766`) without the event and the
    /// future: M4 owns the event queue that turns this into a callback.
    pub fn popErrorScope(self: *Device) error_scope.PopError!error_scope.ErrorScope {
        return self.core.popErrorScope();
    }

    /// `DeviceBase::HandleError` (`:625-683`) as `M3` left it.
    pub fn handleError(
        self: *Device,
        allocator: std.mem.Allocator,
        data: *core.ErrorData,
    ) bool {
        return self.core.handleError(allocator, data);
    }

    /// The device as an error sink, so a caller hands it an error without
    /// knowing the device holds a scope stack.
    pub fn errorSink(self: *Device) error_scope.ErrorSink {
        return self.core.errorSink();
    }

    /// `null::Device::GetOptimalBytesPerRowAlignment`
    /// (`DeviceNull.cpp:594-596`). M17 is the first reader.
    pub fn getOptimalBytesPerRowAlignment(_: *const Device) u32 {
        return 1;
    }

    /// `null::Device::GetOptimalBufferToTextureCopyOffsetAlignment`
    /// (`DeviceNull.cpp:598-600`).
    pub fn getOptimalBufferToTextureCopyOffsetAlignment(_: *const Device) u64 {
        return 1;
    }

    /// `null::Device::GetTimestampPeriodInNS` (`DeviceNull.cpp:602-604`). M19 is
    /// the first reader.
    pub fn getTimestampPeriodInNanoseconds(_: *const Device) f32 {
        return 1.0;
    }

    /// `null::Device::CanTextureLoadResolveTargetInTheSameRenderpass`
    /// (`DeviceNull.cpp:606-608`).
    pub fn canLoadAndResolveInSameRenderPass(_: *const Device) bool {
        return true;
    }
};

/// `DeviceBase::ApplyFeatures` (`Device.cpp:1723-1762`).
///
/// Three rules in order: the caller's required features, the implicit closure
/// `WGPUHelpers.cpp:454-460` publishes, then the core feature when the level is
/// core. The closure is a fixed point, so it is bounded by the edge list.
pub fn applyFeatures(
    level: FeatureLevel,
    required: []const api.FeatureName,
) features.FeaturesSet {
    var enabled: features.FeaturesSet = .{};
    // Bound: the slice the caller passed.
    for (required) |name| {
        enabled.enable(features.fromApiName(name));
    }

    // `max_pass_count` is one more than the number of edges, because the
    // upstream list is acyclic: one pass per edge suffices to reach the fixed
    // point and the extra pass is the one that finds nothing left to do.
    const max_pass_count = features.implicitly_enabled.len + 1;
    var pass_count: usize = 0;
    var changed = true;
    while (changed and pass_count < max_pass_count) : (pass_count += 1) {
        changed = false;
        inline for (features.implicitly_enabled) |edge| {
            if (enabled.isEnabled(edge[0]) and !enabled.isEnabled(edge[1])) {
                enabled.enable(edge[1]);
                changed = true;
            }
        }
    }
    // Leaving the loop with `changed` still set would mean the edge list gained
    // a cycle. Upstream makes no such check; `WGPUHelpers.cpp:462` only marks
    // where more rules go.
    std.debug.assert(!changed);

    // `Device.cpp:1755-1759`: a core adapter always supports the core feature
    // and the device enables it without the caller asking.
    if (level == .core) enabled.enable(.core_features_and_limits);

    return enabled;
}

/// `EnforceLimitSpecInvariants` (`Limits.cpp:426-459`), which `DeviceBase`'s
/// constructor calls. Two rules: the per-stage value is raised to the larger of
/// the two in-stage compat values, and outside compatibility mode the four
/// in-stage values become the per-stage values.
///
/// **The level is the effective one, not the adapter's.** `Device.cpp:294-296`
/// derives it from the enabled features and `Device.cpp:351` passes that
/// result here, so a compatibility-level device whose caller required the core
/// feature is fixed up as a core device.
///
/// **Why the core value is not the compat value.** In core, the compat columns
/// are still what the table carries — zero storage buffers in the vertex stage
/// (`Limits.cpp:96`) and four in the fragment stage (`:95`) — and this function
/// is what replaces them with the per-stage value of eight. That difference is
/// what `test/null_device.zig` asserts.
pub fn enforceLimitSpecInvariants(
    combined: *limits.CombinedLimits,
    level: FeatureLevel,
) void {
    // The caller has already refused a null block (`Device.init`), so this is a
    // statement about a value that exists.
    var compat = combined.compatibility orelse return;

    const storage_buffer_per_stage = @max(
        combined.v1.max_storage_buffers_per_shader_stage,
        @max(
            compat.max_storage_buffers_in_vertex_stage,
            compat.max_storage_buffers_in_fragment_stage,
        ),
    );
    const storage_texture_per_stage = @max(
        combined.v1.max_storage_textures_per_shader_stage,
        @max(
            compat.max_storage_textures_in_vertex_stage,
            compat.max_storage_textures_in_fragment_stage,
        ),
    );
    combined.v1.max_storage_buffers_per_shader_stage = storage_buffer_per_stage;
    combined.v1.max_storage_textures_per_shader_stage = storage_texture_per_stage;

    if (level != .compatibility) {
        compat.max_storage_buffers_in_fragment_stage = storage_buffer_per_stage;
        compat.max_storage_textures_in_fragment_stage = storage_texture_per_stage;
        compat.max_storage_buffers_in_vertex_stage = storage_buffer_per_stage;
        compat.max_storage_textures_in_vertex_stage = storage_texture_per_stage;
    }
    combined.compatibility = compat;
}
