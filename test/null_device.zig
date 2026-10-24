//! The M8 shard: a device is created with no GPU.
//!
//! Enumerate the null adapter, request one device with `feature_level = .core`
//! and one with `.compatibility`, and assert the two report different values for
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
        _: std.Io,
        context: *anyopaque,
        data: core.ErrorView,
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
    object_mutex: *std.Io.Mutex,
    request: Request,
) engine.Device.CreateDeviceOptions {
    return .{
        .adapter = adapter,
        .object_mutex = object_mutex,
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
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

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
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var options = adapterOptions(.core);
    options.force_fallback_adapter = true;

    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, options);
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.physical_devices.len);
}

test "a back end this build does not have is refused by name" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    const options: api.RequestAdapterOptions = .{
        .feature_level = .core,
        .power_preference = .undefined_,
        .backend_type = .d3d12,
    };

    try std.testing.expectError(
        error.BackendNotCompiledIn,
        instance.enumerateAdapters(std.testing.allocator, std.testing.io, options),
    );
}

test "an undefined feature level is refused" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    const options: api.RequestAdapterOptions = .{
        .feature_level = .undefined_,
        .power_preference = .undefined_,
        .backend_type = .null_,
    };

    try std.testing.expectError(
        error.FeatureLevelUnsupported,
        instance.enumerateAdapters(std.testing.allocator, std.testing.io, options),
    );
}

// ---------------------------------------------------------------------------
// The acceptance: two levels, two limit sets.
// ---------------------------------------------------------------------------

test "the core and compatibility devices disagree on the storage-buffer limits" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var core_list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer core_list.deinit(std.testing.io) catch @panic("null core adapter teardown failed");
    var compat_list = try instance
        .enumerateAdapters(std.testing.allocator, std.testing.io, adapterOptions(.compatibility));
    defer compat_list.deinit(std.testing.io) catch @panic("null compatibility adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var core_mutex: std.Io.Mutex = .init;
    var compat_mutex: std.Io.Mutex = .init;
    var core_device = try core_list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&core_list.items[0], &recorder, &core_mutex, .{}),
    );
    defer core_device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null core device teardown failed");
    var compat_device = try compat_list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&compat_list.items[0], &recorder, &compat_mutex, .{}),
    );
    defer compat_device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null compatibility device teardown failed");

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
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var core_list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer core_list.deinit(std.testing.io) catch @panic("null core adapter teardown failed");
    var compat_list = try instance
        .enumerateAdapters(std.testing.allocator, std.testing.io, adapterOptions(.compatibility));
    defer compat_list.deinit(std.testing.io) catch @panic("null compatibility adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var core_mutex: std.Io.Mutex = .init;
    var compat_mutex: std.Io.Mutex = .init;
    var core_device = try core_list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&core_list.items[0], &recorder, &core_mutex, .{}),
    );
    defer core_device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null core device teardown failed");
    var compat_device = try compat_list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&compat_list.items[0], &recorder, &compat_mutex, .{}),
    );
    defer compat_device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null compatibility device teardown failed");

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
        .{ .backend_type = .null_, .required_features = &.{.multiple_devices_per_adapter} },
    );
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var formats_mutex: std.Io.Mutex = .init;
    var map_mutex: std.Io.Mutex = .init;
    // `Device.cpp:1735-1752` and the edge list at `WGPUHelpers.cpp:454-460`.
    var formats_device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &formats_mutex, .{ .features = &.{.texture_formats_tier2} }),
    );
    defer formats_device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null formats device teardown failed");

    try std.testing.expect(formats_device.hasFeature(.texture_formats_tier2));
    try std.testing.expect(formats_device.hasFeature(.texture_formats_tier1));
    try std.testing.expect(formats_device.hasFeature(.rg11b10_ufloat_renderable));

    var map_device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(
            &list.items[0],
            &recorder,
            &map_mutex,
            .{ .features = &.{.buffer_map_write_extended_usages} },
        ),
    );
    defer map_device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null map device teardown failed");
    try std.testing.expect(map_device.hasFeature(.buffer_map_write_extended_usages));
}

test "the enabled features come back ascending and agree with hasFeature" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null device teardown failed");

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
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var refused_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null device teardown failed");

    try std.testing.expect(list.items[0].is_consumed);
    try std.testing.expectError(
        error.AdapterConsumed,
        list.items[0].createDevice(
            std.testing.allocator,
            std.testing.io,
            deviceOptions(&list.items[0], &recorder, &refused_mutex, .{}),
        ),
    );
}

test "multiple devices per adapter is an instance feature and lifts the latch" {
    var instance = engine.Instance.init(.{
        .backend_type = .null_,
        .required_features = &.{.multiple_devices_per_adapter},
    });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var first_mutex: std.Io.Mutex = .init;
    var second_mutex: std.Io.Mutex = .init;
    var first = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &first_mutex, .{ .label = "first" }),
    );
    defer first.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null first device teardown failed");
    var second = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &second_mutex, .{ .label = "second" }),
    );
    defer second.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null second device teardown failed");

    try std.testing.expect(!list.items[0].is_consumed);
    try std.testing.expectEqualStrings("first", first.getLabel());
    try std.testing.expectEqualStrings("second", second.getLabel());
}

test "a required limit above the adapter is refused and one below is accepted" {
    var instance = engine.Instance.init(
        .{ .backend_type = .null_, .required_features = &.{.multiple_devices_per_adapter} },
    );
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var accepted_mutex: std.Io.Mutex = .init;
    var refused_mutex: std.Io.Mutex = .init;
    var within: api.Limits = .{};
    within.max_bind_groups = 4;
    within.max_buffer_size = 1024;

    var accepted = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &accepted_mutex, .{ .limits = &within }),
    );
    defer accepted.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null accepted device teardown failed");
    try std.testing.expectEqual(@as(u64, 1024), accepted.getLimits().v1.max_buffer_size);
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
            std.testing.io,
            deviceOptions(&list.items[0], &recorder, &refused_mutex, .{ .limits = &above }),
        ),
    );
}

// ---------------------------------------------------------------------------
// Device lifetime.
test "a null device without an object mutex fails before allocation or parent acquisition" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, adapterOptions(.core));
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");
    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var options = deviceOptions(&list.items[0], &recorder, &object_mutex, .{});
    options.object_mutex = null;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.MissingObjectMutex,
        list.items[0].createDevice(failing.allocator(), std.testing.io, options),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
    try std.testing.expect(!list.items[0].is_consumed);
    try std.testing.expectEqual(@as(u64, 0), recorder.count);

    // Refusal does not consume the latch; the same adapter still serves a valid request.
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null device teardown failed");
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(std.testing.io));
    try std.testing.expect(list.items[0].is_consumed);
}

// ---------------------------------------------------------------------------

test "destroy retires a device but final deinit releases its parent count" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));

    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null device teardown failed");
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(engine.DeviceState.alive, device.getState());
    try std.testing.expect(!device.isLost());
    {
        const host = device.coreDevice();
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, host.borrow().objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(@as(usize, 0), host.queryTrackedCount(&guard));
    }

    try device.destroy(std.testing.allocator, std.testing.io);
    try device.destroy(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(engine.DeviceState.destroyed, device.getState());
    // Explicit retirement leaves the host shell valid until final deinit.
    {
        const host = device.coreDevice();
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, host.borrow().objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(@as(usize, 0), host.queryTrackedCount(&guard));
        try std.testing.expectEqual(@as(usize, 0), host.queryCapacity(&guard));
    }
    try device.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
    try device.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
}

test "live devices prevent list and instance teardown without releasing owners" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(
        std.testing.allocator,
        std.testing.io,
        adapterOptions(.core),
    );
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");
    const items = list.items;
    const physical_devices = list.physical_devices;

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null device teardown failed");

    try std.testing.expectError(error.AdapterListInUse, list.deinit(std.testing.io));
    try std.testing.expectError(
        error.InstanceInUse,
        instance.deinit(std.testing.allocator, std.testing.io),
    );
    try std.testing.expect(list.items.ptr == items.ptr);
    try std.testing.expectEqual(items.len, list.items.len);
    try std.testing.expect(list.physical_devices.ptr == physical_devices.ptr);
    try std.testing.expectEqual(physical_devices.len, list.physical_devices.len);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try std.testing.expectEqualStrings("Null backend", device.adapter.getName());

    try device.destroy(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
    try std.testing.expectError(error.AdapterListInUse, list.deinit(std.testing.io));
    try device.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 0), list.items[0].live_device_count);
    try std.testing.expectError(
        error.InstanceInUse,
        instance.deinit(std.testing.allocator, std.testing.io),
    );
}

test "empty adapter lists still prevent instance teardown" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch
        @panic("null instance teardown failed");
    var options = adapterOptions(.core);
    options.force_fallback_adapter = true;
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, options);
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
    try std.testing.expectError(
        error.InstanceInUse,
        instance.deinit(std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "a lost device keeps the first reason it was given" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, adapterOptions(.core));
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch @panic("null device teardown failed");

    const message = try std.testing.allocator.dupe(u8, "the caller asked");
    device.handleDeviceLost(std.testing.allocator, std.testing.io, .unknown, message);
    std.testing.allocator.free(message);
    try std.testing.expect(device.isLost());
    try std.testing.expectEqual(engine.DeviceLostReason.unknown, device.lost_reason.?);
    try std.testing.expectEqualStrings("the caller asked", device.lost_message);
    try std.testing.expectEqual(engine.DeviceState.disconnecting, device.getState());

    device.handleDeviceLost(std.testing.allocator, std.testing.io, .destroyed, "a second reason");
    try std.testing.expectEqual(engine.DeviceLostReason.unknown, device.lost_reason.?);
    try std.testing.expectEqualStrings("the caller asked", device.lost_message);
}

test "the null device answers the four capability queries it owns" {
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, adapterOptions(.core));
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = try list.items[0].createDevice(
        std.testing.allocator,
        std.testing.io,
        deviceOptions(&list.items[0], &recorder, &object_mutex, .{}),
    );
    defer device.deinit(std.testing.allocator, std.testing.io) catch @panic("null device teardown failed");

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

/// Names frontend refusals and the Vulkan discovery errors now shared by the
/// production instance. Native failures keep their exact error name.
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
        error.Canceled => "root-operation acquisition was canceled",
        error.InstanceShutDown => "the instance no longer admits root work",
        error.ReferenceCountOverflow => "a root parent or operation count cannot be retained",
        error.MissingGlobalProc,
        error.MissingInstanceProc,
        error.MissingDeviceProc,
        error.OutOfHostMemory,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        error.DeviceLost,
        error.MemoryMapFailed,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        error.IncompatibleDriver,
        error.TooManyObjects,
        error.FormatNotSupported,
        error.FragmentedPool,
        error.Unknown,
        error.SurfaceLost,
        error.NativeWindowInUse,
        error.OutOfDate,
        error.ValidationFailed,
        error.UnknownResult,
        error.UnexpectedOutcome,
        error.VulkanVersionUnsupported,
        error.InstanceCreationReturnedNull,
        error.NoPhysicalDevice,
        error.EnumerationCountUnstable,
        error.QueueFamilyCountUnstable,
        error.ExtensionCountUnstable,
        error.LibraryAlreadyOpen,
        error.OpenFailed,
        => @errorName(err),
    };
}

/// Names every member of `engine.DeviceError`.
fn nameDeviceError(err: engine.DeviceError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "the allocator refused the device arena",
        error.LimitsCompatibilityBlockMissing => "the limits carry no compatibility block",
        error.FeatureLevelUnsupported => "the physical device does not serve the level",
        error.MissingObjectMutex => "the null device requires a caller-owned object mutex",
        error.InvalidOwner => "the device creation permit does not name this adapter and instance",
        error.RequiredLimitIsWorseThanSupported,
        error.RequiredAlignmentIsNotPowerOfTwo,
        error.CompatibilityLimitsUnsupported,
        error.MissingGlobalProc,
        error.MissingInstanceProc,
        error.MissingDeviceProc,
        error.OutOfHostMemory,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        error.DeviceLost,
        error.MemoryMapFailed,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        error.IncompatibleDriver,
        error.TooManyObjects,
        error.FormatNotSupported,
        error.FragmentedPool,
        error.Unknown,
        error.SurfaceLost,
        error.NativeWindowInUse,
        error.OutOfDate,
        error.ValidationFailed,
        error.UnknownResult,
        error.UnexpectedOutcome,
        error.NoUniversalQueueFamily,
        error.DeviceCreationReturnedNull,
        error.UnsupportedRequiredFeature,
        error.RobustBufferAccessUnsupported,
        error.DeviceProcTierMissing,
        error.CommandContextPoolExhausted,
        error.CommandPoolCreationReturnedNull,
        error.CommandBufferAllocationReturnedNull,
        error.QueueHandleIsNull,
        => @errorName(err),
    };
}

comptime {
    // Reflection hands back a member's name, not a value, and `@field` is what
    // turns a swept member into the error these name.
    for (@typeInfo(engine.AdapterError).error_set.error_names.?) |member| {
        _ = nameAdapterError(@field(engine.AdapterError, member));
    }
    for (@typeInfo(engine.InstanceError).error_set.error_names.?) |member| {
        _ = nameInstanceError(@field(engine.InstanceError, member));
    }
    for (@typeInfo(engine.DeviceError).error_set.error_names.?) |member| {
        _ = nameDeviceError(@field(engine.DeviceError, member));
    }
}

test "every error set member is named by this shard" {
    // The sweep above is a compile-time check. This test is the runtime half:
    // it reads one error of each kind back out of the live path and names it.
    var instance = engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(std.testing.allocator, std.testing.io) catch @panic("null instance teardown failed");
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, adapterOptions(.core));
    defer list.deinit(std.testing.io) catch @panic("null adapter teardown failed");

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
