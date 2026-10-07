//! The M2 shard: the generated `src/api` still agrees with `dawn.json`.
//!
//! `tools/gen_api.zig` reads `dawn.json` and writes `src/api`. This file is
//! the other half of that claim: it names the three counts `docs/40-plan.md`
//! section M2 fixes and sweeps every enumerable domain the generator emits.
//! A new upstream entry, method or member moves a count and fails here.
//!
//! **What this file does not claim.** It does not claim a `dawn.json` was
//! read. The generator read it; this file checks what the generator wrote
//! against the numbers the plan recorded when it read the same revision.
//!
//! **The import is `@import("dusk")`.** The published module exposes `api`
//! through `src/root.zig`, and this shard reaches the library through it like
//! every other acceptance shard.

const std = @import("std");

const api = @import("dusk").api;
const bitmask = api.bitmask;
const enums = api.enums;
const handled = api.handled;

/// The census `docs/30-port-design.md` section 8.1 records for the pinned
/// Dawn revision, and the row budget `docs/40-plan.md` section M2 fixes.
const object_count = 347;
const method_count = 205;
const member_count = 571;

// The counts are comptime, so a drifted tree is a compile error and not a
// runtime failure nobody runs.
comptime {
    if (handled.entry_count != object_count) @compileError("dawn.json object count moved");
    if (handled.method_count != method_count) @compileError("dawn.json method count moved");
    if (handled.member_count != member_count) @compileError("dawn.json member count moved");
}

test "the census is 347 objects, 205 methods and 571 members" {
    try std.testing.expectEqual(object_count, handled.entry_count);
    try std.testing.expectEqual(method_count, handled.method_count);
    try std.testing.expectEqual(member_count, handled.member_count);
    try std.testing.expectEqual(object_count, @typeInfo(handled.Entry).@"enum".fields.len);
    try std.testing.expectEqual(method_count, @typeInfo(api.proc.ProcTable).@"struct".fields.len);
}

test "the generated domains are the ones the plan records" {
    try std.testing.expectEqual(65, handled.enum_count);
    try std.testing.expectEqual(88, handled.chained_count);
    try std.testing.expectEqual(6, handled.bitmask_count);
}

test "every API entry is ported" {
    inline for (@typeInfo(handled.Entry).@"enum".fields) |field| {
        const entry: handled.Entry = @enumFromInt(field.value);
        try std.testing.expectEqual(handled.Coverage.ported, handled.coverage(entry));
    }
}

test "the per-entry table sums to the totals" {
    var methods: usize = 0;
    var members: usize = 0;
    inline for (@typeInfo(handled.Entry).@"enum".fields) |field| {
        const entry: handled.Entry = @enumFromInt(field.value);
        const counts = handled.record(entry);
        methods += counts.methods;
        members += counts.members;
    }
    try std.testing.expectEqual(method_count, methods);
    try std.testing.expectEqual(member_count, members);
}

test "a chained struct belongs to a root and an extension to none" {
    inline for (@typeInfo(handled.Entry).@"enum".fields) |field| {
        const entry: handled.Entry = @enumFromInt(field.value);
        const counts = handled.record(entry);
        try std.testing.expectEqual(counts.chain_members, counts.extension_slots);
    }
}

test "every enum tag round-trips through @intFromEnum" {
    // One function instantiation per enum kind, each analysed on its own: the
    // tag type is a `type`, which exists only at comptime, so the sweep needs a
    // comptime-known `kind`. Unrolling all 65 kinds into a single block also
    // multiplies every tag into one body and exceeds the branch quota, while
    // 65 single-kind instantiations stay under it.
    inline for (@typeInfo(enums.Enum).@"enum".fields) |kind| {
        try roundTripEnum(@enumFromInt(kind.value));
    }
}

/// The `comptime` parameter is the split: Zig instantiates this body once per
/// kind, so each instantiation names one tag type and unrolls one tag list.
fn roundTripEnum(comptime kind: enums.Enum) !void {
    const tag_type = comptime enums.tagType(kind);
    inline for (@typeInfo(tag_type).@"enum".fields) |tag| {
        const value: tag_type = @enumFromInt(tag.value);
        try std.testing.expectEqual(tag.value, @intFromEnum(value));
        try std.testing.expectEqualStrings(tag.name, @tagName(value));
    }
}

/// One bitmask's wire values, and the type they belong to. The six
/// declarations are named rather than swept, because a generated enum domain
/// for the bitmasks does not exist and adding one would be a second ledger.
const Bitmask = struct {
    name: []const u8,
    count: usize,
    flags: []const u32,
    T: type,
};

const bitmasks = [_]Bitmask{
    .{
        .name = "buffer usage",
        .count = 12,
        .flags = bitmask.BufferUsage_flag_values,
        .T = bitmask.BufferUsage,
    },
    .{
        .name = "color write mask",
        .count = 6,
        .flags = bitmask.ColorWriteMask_flag_values,
        .T = bitmask.ColorWriteMask,
    },
    .{
        .name = "map mode",
        .count = 3,
        .flags = bitmask.MapMode_flag_values,
        .T = bitmask.MapMode,
    },
    .{
        .name = "shader stage",
        .count = 4,
        .flags = bitmask.ShaderStage_flag_values,
        .T = bitmask.ShaderStage,
    },
    .{
        .name = "texture usage",
        .count = 8,
        .flags = bitmask.TextureUsage_flag_values,
        .T = bitmask.TextureUsage,
    },
    .{
        .name = "heap property",
        .count = 6,
        .flags = bitmask.HeapProperty_flag_values,
        .T = bitmask.HeapProperty,
    },
};

test "every bitmask value round-trips through @bitCast" {
    // One function instantiation per declaration, for the same reason as the
    // enum sweep: `Bitmask.T` is a `type`, so each body has to name its own
    // mask type at comptime rather than iterate one array at runtime.
    inline for (bitmasks) |one| {
        try roundTripBitmask(one);
    }
}

fn roundTripBitmask(comptime one: Bitmask) !void {
    try std.testing.expectEqual(one.count, one.flags.len);
    for (one.flags) |value| {
        const mask: one.T = one.T.fromFlags(value);
        try std.testing.expectEqual(value, mask.toFlags());
    }
}

test "every bitmask has a flag set, and the empty mask has none" {
    // The same split as the round trip above: `Bitmask.T` is a `type`, so the
    // empty mask is spelled per declaration at comptime and the array is a
    // comptime sweep rather than a runtime loop.
    inline for (bitmasks) |one| {
        try emptyMaskHasNoFlag(one);
    }
}

/// `has` is subset containment, `(ours & theirs) == theirs`
/// (`src/api/bitmask.zig:37-41`). So `has` on the empty flag set is true for
/// every mask, the empty one included, because the empty set is a subset of
/// every set. "The empty mask has no flag set" is the other half of that same
/// definition: it contains no wire value that names a bit.
fn emptyMaskHasNoFlag(comptime one: Bitmask) !void {
    const empty: one.T = .{};
    try std.testing.expect(empty.has(.{}));
    for (one.flags) |value| {
        // The table's zero entry is the `none` wire value, which names no bit
        // and so is the one value the empty mask may hold.
        if (value == 0) continue;
        try std.testing.expect(!empty.has(one.T.fromFlags(value)));
    }
    try std.testing.expectEqual(@as(u32, 0), empty.toFlags());
}

test "every API declaration is reachable from the module root" {
    std.testing.refAllDecls(api);
}

// These are consumer signatures, not generator text checks. Exact pointer
// types check the calling convention, argument projection, and error channel.
test "procedure table accepts native void and slice contracts" {
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_destroy") ==
        *const fn (api.objects.Buffer) void);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_set_label") ==
        *const fn (api.objects.Buffer, []const u8) void);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "adapter_get_features") ==
        *const fn (api.objects.Adapter, *api.descriptors.SupportedFeatures) void);
}

test "procedure table returns handles and scalar values through native errors" {
    try std.testing.expect(@FieldType(api.proc.ProcTable, "adapter_get_instance") ==
        *const fn (api.objects.Adapter) api.errors.Error!api.objects.Instance);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "adapter_has_feature") ==
        *const fn (api.objects.Adapter, enums.FeatureName) api.errors.Error!bool);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_get_size") ==
        *const fn (api.objects.Buffer) api.errors.Error!u64);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_get_usage") ==
        *const fn (api.objects.Buffer) api.errors.Error!bitmask.BufferUsage);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_get_map_state") ==
        *const fn (api.objects.Buffer) api.errors.Error!enums.BufferMapState);
}

test "nullable buffer returns preserve object and procedure success null and error" {
    try std.testing.expect(api.objects.Device.createBuffer ==
        fn (
            api.objects.Device,
            *const api.descriptors.BufferDescriptorChain,
        ) api.errors.Error!?api.objects.Buffer);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "device_create_buffer") ==
        *const api.objects.Device.createBuffer);

    var token: u8 = 0;
    const buffer: api.objects.Buffer = .{ .handle = &token };
    inline for (.{
        @typeInfo(api.objects.Device.createBuffer).@"fn".return_type.?,
        @typeInfo(
            @typeInfo(
                @FieldType(api.proc.ProcTable, "device_create_buffer"),
            ).pointer.child,
        ).@"fn".return_type.?,
    }) |return_type| {
        const success: return_type = buffer;
        try std.testing.expectEqual(buffer.handle, (try success).?.handle);
        const absent: return_type = null;
        try std.testing.expect((try absent) == null);
        const failure: return_type = error.OutOfMemory;
        try std.testing.expectError(error.OutOfMemory, failure);
    }
}

test "procedure table preserves output parameters and native descriptor chains" {
    try std.testing.expect(@FieldType(api.proc.ProcTable, "adapter_get_limits") ==
        *const fn (
            api.objects.Adapter,
            *api.descriptors.Limits,
        ) api.errors.Error!enums.Status);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "adapter_create_device") ==
        *const fn (
            api.objects.Adapter,
            ?*const api.descriptors.DeviceDescriptorChain,
        ) api.errors.Error!api.objects.Device);
}

test "procedure table returns nullable mapped pointers" {
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_get_mapped_range") ==
        *const fn (
            api.objects.Buffer,
            usize,
            usize,
        ) api.errors.Error!?*anyopaque);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_get_const_mapped_range") ==
        *const fn (
            api.objects.Buffer,
            usize,
            usize,
        ) api.errors.Error!?*const anyopaque);
    try std.testing.expect(@typeInfo(api.objects.Buffer.getMappedRange).@"fn".return_type.? ==
        api.errors.Error!?*anyopaque);
    try std.testing.expect(@typeInfo(api.objects.Buffer.getConstMappedRange).@"fn".return_type.? ==
        api.errors.Error!?*const anyopaque);
}

test "only proc retrieval returns the generic Proc contract" {
    try std.testing.expect(api.proc.getProcAddress ==
        fn ([]const u8) api.errors.Error!api.callbacks.Proc);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_destroy") ==
        *const api.objects.Buffer.destroy);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "adapter_get_instance") ==
        *const api.objects.Adapter.getInstance);
}

test "async object and procedure contracts require explicit effects and finite errors" {
    const contracts = .{
        .{ api.objects.Adapter.requestDevice, "adapter_request_device", fn (api.objects.Adapter, std.mem.Allocator, std.Io, ?*const api.descriptors.DeviceDescriptorChain, api.callbacks.RequestDeviceCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
        .{ api.objects.Device.createComputePipelineAsync, "device_create_compute_pipeline_async", fn (api.objects.Device, std.mem.Allocator, std.Io, *const api.descriptors.ComputePipelineDescriptorChain, api.callbacks.CreateComputePipelineAsyncCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
        .{ api.objects.Device.createRenderPipelineAsync, "device_create_render_pipeline_async", fn (api.objects.Device, std.mem.Allocator, std.Io, *const api.descriptors.RenderPipelineDescriptorChain, api.callbacks.CreateRenderPipelineAsyncCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
        .{ api.objects.Device.setLoggingCallback, "device_set_logging_callback", fn (api.objects.Device, std.Io, api.callbacks.LoggingCallbackInfo) api.errors.CallbackControlError!void },
        .{ api.objects.Device.getLostFuture, "device_get_lost_future", fn (api.objects.Device, std.Io) api.errors.CallbackControlError!api.descriptors.Future },
        .{ api.objects.Device.popErrorScope, "device_pop_error_scope", fn (api.objects.Device, std.mem.Allocator, std.Io, api.callbacks.PopErrorScopeCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
        .{ api.objects.Instance.requestAdapter, "instance_request_adapter", fn (api.objects.Instance, std.mem.Allocator, std.Io, ?*const api.descriptors.RequestAdapterOptionsChain, api.callbacks.RequestAdapterCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
        .{ api.objects.Instance.processEvents, "instance_process_events", fn (api.objects.Instance, std.Io) api.errors.ProcessEventsError!void },
        .{ api.objects.Instance.waitAny, "instance_wait_any", fn (api.objects.Instance, std.Io, usize, ?[]api.descriptors.FutureWaitInfo, u64) api.errors.FutureWaitError!enums.WaitStatus },
        .{ api.objects.Queue.onSubmittedWorkDone, "queue_on_submitted_work_done", fn (api.objects.Queue, std.mem.Allocator, std.Io, api.callbacks.QueueWorkDoneCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
        .{ api.objects.ShaderModule.getCompilationInfo, "shader_module_get_compilation_info", fn (api.objects.ShaderModule, std.mem.Allocator, std.Io, api.callbacks.CompilationInfoCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future },
    };
    inline for (contracts) |contract| {
        try std.testing.expect(contract[0] == contract[2]);
        try std.testing.expect(@FieldType(api.proc.ProcTable, contract[1]) == *const contract[2]);
    }
    try std.testing.expect(api.objects.Buffer.mapAsync ==
        fn (api.objects.Buffer, std.mem.Allocator, std.Io, bitmask.MapMode, api.objects.Buffer.MapAsyncOffsetOptions, api.callbacks.BufferMapCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future);
    try std.testing.expect(@FieldType(api.proc.ProcTable, "buffer_map_async") ==
        *const fn (api.objects.Buffer, std.mem.Allocator, std.Io, bitmask.MapMode, usize, usize, api.callbacks.BufferMapCallbackInfo) api.errors.AsyncStartError!api.descriptors.Future);
}

test "native support errors are finite public API contracts" {
    try std.testing.expect(api.AsyncStartError == api.errors.AsyncStartError);
    try std.testing.expect(api.FutureWaitError == api.errors.FutureWaitError);
    try std.testing.expect(api.CallbackControlError == api.errors.CallbackControlError);
    try std.testing.expect(api.ProcessEventsError == api.errors.ProcessEventsError);
    try std.testing.expect(api.errors.AsyncStartError == error{
        OutOfMemory,
        Canceled,
        MissingFutureNamespaceSource,
        FutureNamespaceExhausted,
        FutureNamespaceContention,
        FutureIdExhausted,
        AsyncCapacityExceeded,
        InvalidAsyncCapacity,
        InvalidCallbackMode,
        InvalidOwner,
        OwnerStopped,
        InstanceShutDown,
        TaskQueueFull,
        PoolShutDown,
        WorkerExhausted,
        ConcurrencyUnavailable,
        InvalidRequest,
        ReferenceCountOverflow,
    });
    try std.testing.expect(api.errors.FutureWaitError == error{
        Canceled,
        MissingFutureNamespaceSource,
        InvalidFutureId,
        FutureInstanceMismatch,
        FutureCountMismatch,
        WaitCountExceeded,
        ReentrantWait,
        InstanceShutDown,
        TimedWaitUnavailable,
        WaitIterationExhausted,
        WaitEpochExhausted,
        ReferenceCountOverflow,
    });
    try std.testing.expect(api.errors.CallbackControlError ==
        error{ Canceled, MissingFutureNamespaceSource, DeviceNotAlive, InvalidOwner });
    try std.testing.expect(api.errors.ProcessEventsError ==
        error{ InstanceShutDown, ReferenceCountOverflow });
}

test "descriptor contracts retain named callback-info records" {
    inline for (.{ api.descriptors.DeviceDescriptor, api.descriptors.DeviceDescriptorChain }) |Descriptor| {
        try std.testing.expect(@FieldType(Descriptor, "device_lost_callback_info") == api.callbacks.DeviceLostCallbackInfo);
        try std.testing.expect(@FieldType(Descriptor, "uncaptured_error_callback_info") == api.callbacks.UncapturedErrorCallbackInfo);
    }
    try std.testing.expect(@FieldType(api.descriptors.DawnCacheDeviceDescriptor, "dawn_load_cache_data_callback_info") == api.callbacks.DawnLoadCacheDataCallbackInfo);
    try std.testing.expect(@FieldType(api.descriptors.DawnCacheDeviceDescriptor, "dawn_store_cache_data_callback_info") == api.callbacks.DawnStoreCacheDataCallbackInfo);
    try std.testing.expect(@FieldType(api.descriptors.SharedBufferMemoryHostPointerDescriptor, "dispose_callback_info") == api.callbacks.DisposeCallbackInfo);
}

test "callback-info records expose schema modes and per-request userdata" {
    inline for (.{
        api.callbacks.RequestAdapterCallbackInfo,
        api.callbacks.RequestDeviceCallbackInfo,
        api.callbacks.BufferMapCallbackInfo,
        api.callbacks.CompilationInfoCallbackInfo,
        api.callbacks.CreateComputePipelineAsyncCallbackInfo,
        api.callbacks.CreateRenderPipelineAsyncCallbackInfo,
        api.callbacks.DeviceLostCallbackInfo,
        api.callbacks.PopErrorScopeCallbackInfo,
        api.callbacks.DisposeCallbackInfo,
        api.callbacks.QueueWorkDoneCallbackInfo,
    }) |Info| {
        try std.testing.expect(@FieldType(Info, "mode") == enums.CallbackMode);
        try std.testing.expect(@FieldType(Info, "userdata") == ?*anyopaque);
    }
    inline for (.{
        .{ api.callbacks.DawnLoadCacheDataCallbackInfo, api.callbacks.DawnLoadCacheDataCallback },
        .{ api.callbacks.DawnStoreCacheDataCallbackInfo, api.callbacks.DawnStoreCacheDataCallback },
        .{ api.callbacks.UncapturedErrorCallbackInfo, api.callbacks.UncapturedErrorCallback },
        .{ api.callbacks.LoggingCallbackInfo, api.callbacks.LoggingCallback },
    }) |contract| {
        try std.testing.expect(@FieldType(contract[0], "callback") == ?contract[1]);
        try std.testing.expect(@FieldType(contract[0], "userdata") == ?*anyopaque);
        const info: contract[0] = .{};
        try std.testing.expect(info.callback == null);
    }
    const lost: api.callbacks.DeviceLostCallbackInfo = .{ .mode = .wait_any_only };
    const dispose: api.callbacks.DisposeCallbackInfo = .{ .mode = .wait_any_only };
    try std.testing.expect(lost.callback == null);
    try std.testing.expect(dispose.callback == null);
}
