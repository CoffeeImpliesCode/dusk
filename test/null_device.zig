//! The M8 shard: a device is created with no GPU.
//!
//! `docs/40-plan.md` §1 `### M8` fixes the acceptance: enumerate the null
//! adapter, request one device with `feature_level = .core` and one with
//! `.compatibility`, and assert the two report different values for
//! `maxStorageBuffersInVertexStage` and `maxStorageBuffersInFragmentStage`.
//!
//! **Why those two rows and no other.** They are the only two limits whose
//! compat column differs from the tier-0 column by construction, and they are
//! the rows `EnforceLimitSpecInvariants` (`Limits.cpp:426-459`) overwrites in
//! core. So they test both halves of the rule at once: the compat column the
//! table carries (0 and 4, `Limits.cpp:96` and `:95`) and the per-stage value
//! core reports instead (8 and 8, `Limits.cpp:94`).
//!
//! **The import is `@import("dusk")`.** The published module exposes `engine`
//! through `src/root.zig`, and this shard reaches the library through it like
//! every other acceptance shard.
//!
//! **What this file does not claim.** It does not claim a queue, a buffer or a
//! GPU. Every device here is a null device.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;

/// Counts the errors that no scope took. Every test here ends with a zero count,
/// so a device that reported something and swallowed it is a failure.
const ErrorRecorder = struct {
    count: u64 = 0,

    fn record(
        allocator: std.mem.Allocator,
        context: *anyopaque,
        data: *const core.ErrorData,
    ) void {
        const self: *ErrorRecorder = @ptrCast(@alignCast(context));
        self.count += 1;
        // The stack hands the callback the allocator it was built with.
        // `std.mem.Allocator` has no `==` in Zig 0.16, so identity is the pair
        // of pointers the struct carries (`std/mem/Allocator.zig:19-20`) and both
        // halves are compared; one alone would admit a borrowed half.
        std.debug.assert(allocator.ptr == std.testing.allocator.ptr);
        std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
        std.debug.assert(data.message.len > 0);
    }
};

/// One device request. The two members of `DeviceDescriptor`
/// (`src/api/descriptors.zig:73-81`) that M8 reads are the required features
/// and the required limits; the label and the callbacks are what the caller
/// supplies to the port's two uncaptured-error members. The feature level is
/// not here: Dawn fixes it on the adapter (`Adapter.cpp:57`) and the device
/// inherits it.
const Request = struct {
    features: []const api.FeatureName = &.{},
    limits: ?*const api.Limits = null,
    label: ?[]const u8 = null,
};

fn adapterOptions(level: api.FeatureLevel) api.RequestAdapterOptions {
    return .{ .feature_level = level, .power_preference = .undefined_, .backend_type = .null_ };
}

fn deviceOptions(
    adapter: *engine.Adapter,
    recorder: *ErrorRecorder,
    request: Request,
) engine.Device.CreateDeviceOptions {
    return .{
        .adapter = adapter,
        .label = request.label,
        .required_features = request.features,
        .required_limits = request.limits,
        .feature_level = adapter.getFeatureLevel(),
        .uncaptured_context = @ptrCast(recorder),
        .uncaptured_callback = ErrorRecorder.record,
    };
}

// ---------------------------------------------------------------------------
// The enumeration.
// ---------------------------------------------------------------------------

test "the null back end is one adapter that needs no driver" {
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(usize, 1), list.physical_devices.len);

    const adapter = &list.items[0];
    try std.testing.expectEqualStrings("Null backend", adapter.getName());
    try std.testing.expectEqual(
        api.BackendType.null_,
        adapter.getPhysicalDevice().getBackendType(),
    );
    try std.testing.expectEqual(api.AdapterType.unknown, adapter.getInfo().adapter_type);
    try std.testing.expectEqual(@as(u32, 0), adapter.getInfo().vendor_id);
    try std.testing.expectEqual(@as(u32, 0), adapter.getInfo().device_id);
    // The generated vendor table returns an empty string for a vendor it does
    // not know (`generator/templates/dawn/common/GPUInfo.cpp:155`), and vendor
    // zero is not in it.
    try std.testing.expectEqualStrings("", adapter.getInfo().vendor);
    try std.testing.expectEqualStrings("", adapter.getInfo().architecture);
    try std.testing.expectEqual(api.BackendType.null_, adapter.getInfo().backend_type);

    // The back end enables every feature for the convenience of tests
    // (`DeviceNull.cpp:91-96`).
    try std.testing.expect(adapter.hasFeature(.core_features_and_limits));
    try std.testing.expect(adapter.hasFeature(.texture_formats_tier2));
}

test "a forced fallback adapter finds nothing in the null back end" {
    var instance = engine.Instance.init(.{});
    var options = adapterOptions(.core);
    options.force_fallback_adapter = true;

    var list = try instance.enumerateAdapters(std.testing.allocator, options);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.physical_devices.len);
}

test "a back end this build does not have is refused by name" {
    var instance = engine.Instance.init(.{});
    const options: api.RequestAdapterOptions = .{
        .feature_level = .core,
        .power_preference = .undefined_,
        .backend_type = .d3d12,
    };

    try std.testing.expectError(
        error.BackendNotCompiledIn,
        instance.enumerateAdapters(std.testing.allocator, options),
    );
}

test "an undefined feature level is refused" {
    var instance = engine.Instance.init(.{});
    const options: api.RequestAdapterOptions = .{
        .feature_level = .undefined_,
        .power_preference = .undefined_,
        .backend_type = .null_,
    };

    try std.testing.expectError(
        error.FeatureLevelUnsupported,
        instance.enumerateAdapters(std.testing.allocator, options),
    );
}

// ---------------------------------------------------------------------------
// The acceptance: two levels, two limit sets.
// ---------------------------------------------------------------------------

test "the core and compatibility devices disagree on the storage-buffer limits" {
    var instance = engine.Instance.init(.{});
    var core_list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer core_list.deinit();
    var compat_list = try instance
        .enumerateAdapters(std.testing.allocator, adapterOptions(.compatibility));
    defer compat_list.deinit();

    var recorder: ErrorRecorder = .{};
    var core_device = try core_list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&core_list.items[0], &recorder, .{}),
    );
    defer core_device.deinit(std.testing.allocator);
    var compat_device = try compat_list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&compat_list.items[0], &recorder, .{}),
    );
    defer compat_device.deinit(std.testing.allocator);

    const core_limits = core_device.getLimits();
    const compat_limits = compat_device.getLimits();
    const core_compat = core_limits.compatibility orelse
        return error.CoreDeviceHasNoCompatibilityBlock;
    const compat_compat = compat_limits.compatibility orelse
        return error.CompatibilityDeviceHasNoCompatibilityBlock;

    // The two rows the acceptance names. The compat column is 0 and 4
    // (`Limits.cpp:96` and `:95`); core reports the per-stage value, which is 8
    // (`Limits.cpp:94`).
    try std.testing.expectEqual(@as(u32, 0), compat_compat.max_storage_buffers_in_vertex_stage);
    try std.testing.expect(core_compat.max_storage_buffers_in_vertex_stage >= 4);
    try std.testing.expectEqual(@as(u32, 4), compat_compat.max_storage_buffers_in_fragment_stage);
    try std.testing.expect(core_compat.max_storage_buffers_in_fragment_stage >= 8);

    // The two devices differ, which is the property the two rules above buy.
    try std.testing.expect(
        core_compat.max_storage_buffers_in_vertex_stage !=
            compat_compat.max_storage_buffers_in_vertex_stage,
    );
    try std.testing.expect(
        core_compat.max_storage_buffers_in_fragment_stage !=
            compat_compat.max_storage_buffers_in_fragment_stage,
    );

    // The per-stage value is the same on both: the compat column never raises
    // it, so the invariant rule at `Limits.cpp:433-435` has nothing to do.
    try std.testing.expectEqual(
        core_limits.v1.max_storage_buffers_per_shader_stage,
        compat_limits.v1.max_storage_buffers_per_shader_stage,
    );

    // One rule drives both (`docs/10-architecture.md` "Compatibility mode"):
    // the core feature is present in core and absent in compatibility
    // (`Device.cpp:1840-1842`).
    try std.testing.expect(core_device.hasFeature(.core_features_and_limits));
    try std.testing.expect(!compat_device.hasFeature(.core_features_and_limits));
    try std.testing.expect(!core_device.isCompatibilityMode());
    try std.testing.expect(compat_device.isCompatibilityMode());

    try std.testing.expectEqual(api.FeatureLevel.core, core_device.getFeatureLevel());
    try std.testing.expectEqual(
        api.FeatureLevel.compatibility,
        compat_device.getFeatureLevel(),
    );

    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "the storage-texture rows follow the same two rules as the buffer rows" {
    var instance = engine.Instance.init(.{});
    var core_list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer core_list.deinit();
    var compat_list = try instance
        .enumerateAdapters(std.testing.allocator, adapterOptions(.compatibility));
    defer compat_list.deinit();

    var recorder: ErrorRecorder = .{};
    var core_device = try core_list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&core_list.items[0], &recorder, .{}),
    );
    defer core_device.deinit(std.testing.allocator);
    var compat_device = try compat_list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&compat_list.items[0], &recorder, .{}),
    );
    defer compat_device.deinit(std.testing.allocator);

    const core_limits = core_device.getLimits();
    const compat_limits = compat_device.getLimits();
    // `Device.init` refuses a null compat block
    // (`src/engine/limits.zig:461`), so a device that reports one is a port
    // defect; it is named rather than unwrapped into a panic.
    const core_compat = core_limits.compatibility orelse
        return error.CompatibilityChainMissing;
    const compat_compat = compat_limits.compatibility orelse
        return error.CompatibilityChainMissing;
    try std.testing.expectEqual(@as(u32, 0), compat_compat.max_storage_textures_in_vertex_stage);
    try std.testing.expect(core_compat.max_storage_textures_in_vertex_stage >= 4);
    try std.testing.expectEqual(@as(u32, 4), compat_compat.max_storage_textures_in_fragment_stage);

    // The fragment row is 4 on both devices, and the 8 of the buffer rows is not
    // this table's number. `maxStorageTexturesPerShaderStage` is 4 in compat
    // and 4 at tier 0 (`Limits.cpp:78`), so the value core reports is the
    // per-stage 4; the 8 and 8 the buffer rows report are `Limits.cpp:94` and
    // belong to the buffer table. It is the vertex row that tells the two
    // devices apart.
    try std.testing.expect(core_compat.max_storage_textures_in_fragment_stage >= 4);
    try std.testing.expect(
        core_compat.max_storage_textures_in_vertex_stage !=
            compat_compat.max_storage_textures_in_vertex_stage,
    );

    // The second rule the buffer rows carry, on this table. Core overwrites the
    // compat fragment row with the per-stage value (`Limits.cpp:452-453`), and
    // the per-stage row is raised to the max of itself and the two stage rows
    // first (`Limits.cpp:437-438`), so a compat device reports the same
    // per-stage number a core device does.
    try std.testing.expectEqual(
        core_limits.v1.max_storage_textures_per_shader_stage,
        core_compat.max_storage_textures_in_fragment_stage,
    );
    try std.testing.expectEqual(
        core_limits.v1.max_storage_textures_per_shader_stage,
        compat_limits.v1.max_storage_textures_per_shader_stage,
    );
}

// ---------------------------------------------------------------------------
// The feature rules.
// ---------------------------------------------------------------------------

test "a required feature reaches the device and its implicit closure follows" {
    // Two devices from one adapter, so the instance has to allow it
    // (`Adapter.cpp:314-316`); the latch itself is the test below's subject.
    var instance = engine.Instance.init(
        .{ .required_features = &.{.multiple_devices_per_adapter} },
    );
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    // `Device.cpp:1735-1752` and the edge list at `WGPUHelpers.cpp:454-460`.
    var formats_device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{ .features = &.{.texture_formats_tier2} }),
    );
    defer formats_device.deinit(std.testing.allocator);

    try std.testing.expect(formats_device.hasFeature(.texture_formats_tier2));
    try std.testing.expect(formats_device.hasFeature(.texture_formats_tier1));
    try std.testing.expect(formats_device.hasFeature(.rg11b10_ufloat_renderable));

    var map_device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(
            &list.items[0],
            &recorder,
            .{ .features = &.{.buffer_map_write_extended_usages} },
        ),
    );
    defer map_device.deinit(std.testing.allocator);
    try std.testing.expect(map_device.hasFeature(.buffer_map_write_extended_usages));
}

test "the enabled features come back ascending and agree with hasFeature" {
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{}),
    );
    defer device.deinit(std.testing.allocator);

    var out: [engine.features.feature_count]api.FeatureName = undefined;
    const reported = device.getFeatures(&out);
    try std.testing.expectEqual(@as(usize, 1), reported.len);
    try std.testing.expectEqual(
        api.FeatureName.core_features_and_limits,
        reported[0],
    );

    var adapter_out: [engine.features.feature_count]api.FeatureName = undefined;
    const adapter_reported = list.items[0].getFeatures(&adapter_out);
    // The null adapter enables every member (`DeviceNull.cpp:91-96`, swept at
    // `src/engine/null_backend.zig:72-74`), so it reports one per domain tag.
    try std.testing.expectEqual(engine.features.feature_count, adapter_reported.len);
}

// ---------------------------------------------------------------------------
// The adapter consumption latch and the limit check.
// ---------------------------------------------------------------------------

test "an adapter is consumed by the device it created" {
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{}),
    );
    defer device.deinit(std.testing.allocator);

    try std.testing.expect(list.items[0].is_consumed);
    try std.testing.expectError(
        error.AdapterConsumed,
        list.items[0].createDevice(
            std.testing.allocator,
            deviceOptions(&list.items[0], &recorder, .{}),
        ),
    );
}

test "multiple devices per adapter is an instance feature and lifts the latch" {
    var instance = engine.Instance.init(.{
        .required_features = &.{.multiple_devices_per_adapter},
    });
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    var first = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{ .label = "first" }),
    );
    defer first.deinit(std.testing.allocator);
    var second = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{ .label = "second" }),
    );
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(!list.items[0].is_consumed);
    try std.testing.expectEqualStrings("first", first.getLabel());
    try std.testing.expectEqualStrings("second", second.getLabel());
}

test "a required limit above the adapter is refused and one below is accepted" {
    var instance = engine.Instance.init(
        .{ .required_features = &.{.multiple_devices_per_adapter} },
    );
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    var within: api.Limits = .{};
    within.max_bind_groups = 4;
    within.max_buffer_size = 1024;

    var accepted = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{ .limits = &within }),
    );
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 4), accepted.getLimits().v1.max_bind_groups);

    // `LimitU32Undefined` is `UINT32_MAX` (`src/api/constants.zig:21`-`:24`) and
    // a limit at that value reads as unset rather than as a request for the
    // maximum, which is the value `validateRequiredLimits` skips
    // (`src/engine/adapter.zig:235`, and Dawn skips it at `Limits.cpp:268`).
    // A request one below the sentinel is a request no adapter can meet, and
    // asserting the sentinel here is what names that row as deliberate.
    try std.testing.expectEqual(std.math.maxInt(u32), api.LimitU32Undefined);
    var above: api.Limits = .{};
    above.max_bind_groups = std.math.maxInt(u32) - 1;
    try std.testing.expectError(
        error.RequiredLimitAboveAdapterLimit,
        list.items[0].createDevice(
            std.testing.allocator,
            deviceOptions(&list.items[0], &recorder, .{ .limits = &above }),
        ),
    );
}

// ---------------------------------------------------------------------------
// Device lifetime.
// ---------------------------------------------------------------------------

test "a device that is destroyed is gone and the instance says so" {
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount());

    var device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{}),
    );
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount());
    try std.testing.expectEqual(engine.DeviceState.alive, device.getState());
    try std.testing.expect(!device.isLost());
    try std.testing.expectEqual(@as(usize, 0), device.coreDevice().queryTrackedCount());

    device.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount());
    try std.testing.expectEqual(engine.DeviceState.destroyed, device.getState());
    // The arena capacity is not read here. `destroy` runs `core.Device.deinit`,
    // which poisons the core device, and this test created no object, so the
    // capacity was already zero before the teardown ran. `test/object_arena.zig`
    // is the shard that proves blocks come back to the allocator.
}

test "a lost device keeps the first reason it was given" {
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{}),
    );
    defer device.deinit(std.testing.allocator);

    device.handleDeviceLost(.destroyed, "the caller asked");
    try std.testing.expect(device.isLost());
    try std.testing.expectEqual(engine.DeviceLostReason.destroyed, device.lost_reason.?);
    try std.testing.expectEqualStrings("the caller asked", device.lost_message);
    try std.testing.expectEqual(engine.DeviceState.disconnecting, device.getState());

    device.handleDeviceLost(.unknown, "a second reason");
    try std.testing.expectEqual(engine.DeviceLostReason.destroyed, device.lost_reason.?);
    try std.testing.expectEqualStrings("the caller asked", device.lost_message);
}

test "the null device answers the four capability queries it owns" {
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    var recorder: ErrorRecorder = .{};
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        deviceOptions(&list.items[0], &recorder, .{}),
    );
    defer device.deinit(std.testing.allocator);

    // `DeviceNull.cpp:594-608`.
    try std.testing.expectEqual(@as(u32, 1), device.getOptimalBytesPerRowAlignment());
    try std.testing.expectEqual(
        @as(u64, 1),
        device.getOptimalBufferToTextureCopyOffsetAlignment(),
    );
    try std.testing.expectEqual(@as(f32, 1.0), device.getTimestampPeriodInNanoseconds());
    try std.testing.expect(device.canLoadAndResolveInSameRenderPass());
}

// ---------------------------------------------------------------------------
// The error sets are swept, so a new member is a compile error.
// ---------------------------------------------------------------------------

/// Names every member of `engine.AdapterError` with where it comes from. The
/// `switch` has no `else`, so a member added upstream and not here does not
/// compile.
fn nameAdapterError(err: engine.AdapterError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "the allocator refused the adapter or the device",
        error.FeatureLevelUnsupported => "the physical device does not serve the level",
        error.RequiredFeatureUnsupported => "the physical device does not have the feature",
        error.RequiredLimitAboveAdapterLimit => "the limit is above what the adapter offers",
        error.AdapterConsumed => "the adapter already built a device",
        error.LimitsCompatibilityBlockMissing => "the adapter carries no compatibility block",
    };
}

/// Names every member of `engine.InstanceError`. The set is the union of the
/// adapter set, the connect set, the allocator failure and the enumeration
/// bound (`src/engine/instance.zig:42-45`), so every adapter member is a member
/// here too.
fn nameInstanceError(err: engine.InstanceError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "the allocator refused the physical devices or the adapters",
        error.BackendNotCompiledIn => "the back end is not in this build",
        error.TooManyPhysicalDevices => "the back end reported more devices than the bound",
        error.FeatureLevelUnsupported => "the physical device does not serve the level",
        error.RequiredFeatureUnsupported => "the physical device does not have the feature",
        error.RequiredLimitAboveAdapterLimit => "the limit is above what the adapter offers",
        error.AdapterConsumed => "the adapter already built a device",
        error.LimitsCompatibilityBlockMissing => "the adapter carries no compatibility block",
    };
}

/// Names every member of `engine.DeviceError`.
fn nameDeviceError(err: engine.DeviceError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "the allocator refused the device arena",
        error.LimitsCompatibilityBlockMissing => "the limits carry no compatibility block",
        error.FeatureLevelUnsupported => "the physical device does not serve the level",
    };
}

comptime {
    // Reflection hands back a member's name, not a value, and `@field` is what
    // turns a swept member into the error these name.
    for (@typeInfo(engine.AdapterError).error_set.?) |member| {
        _ = nameAdapterError(@field(engine.AdapterError, member.name));
    }
    for (@typeInfo(engine.InstanceError).error_set.?) |member| {
        _ = nameInstanceError(@field(engine.InstanceError, member.name));
    }
    for (@typeInfo(engine.DeviceError).error_set.?) |member| {
        _ = nameDeviceError(@field(engine.DeviceError, member.name));
    }
}

test "every error set member is named by this shard" {
    // The sweep above is a compile-time check. This test is the runtime half:
    // it reads one error of each kind back out of the live path and names it.
    var instance = engine.Instance.init(.{});
    var list = try instance.enumerateAdapters(std.testing.allocator, adapterOptions(.core));
    defer list.deinit();

    try std.testing.expectEqualStrings(
        "the physical device does not serve the level",
        nameAdapterError(error.FeatureLevelUnsupported),
    );
    try std.testing.expectEqualStrings(
        "the back end is not in this build",
        nameInstanceError(error.BackendNotCompiledIn),
    );
    try std.testing.expectEqualStrings(
        "the limits carry no compatibility block",
        nameDeviceError(error.LimitsCompatibilityBlockMissing),
    );
}

test "the engine module declares no queue and no unused adapter storage" {
    // The M8 module surface is exactly what `docs/40-plan.md` §1 `### M8` names.
    // A queue added early would make M9's table a duplicate of M8's.
    std.testing.refAllDecls(engine);
}
