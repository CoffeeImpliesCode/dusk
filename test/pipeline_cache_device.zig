//! Native driver-cache admission, bounded snapshots, rollback, and device persistence.
const std = @import("std");
const dusk = @import("dusk");
const vk = @import("vulkan");
const t = std.testing;
const artifact = dusk.pipeline.cache_artifact;
const provider = dusk.pipeline.cache_provider;
const handler = dusk.pipeline.driver_cache_handler;
const dispatch = dusk.vk.dispatch;
const capabilities = dusk.engine.native_capabilities;
const gpu_consumer = @import("native_full256_immediate.zig");

const identity: artifact.Identity = .{
    .vendor_id = 0x1234,
    .device_id = 0x5678,
    .driver_version = 9,
    .pipeline_cache_uuid = @splat(0xAB),
};
const isolation_hash: [32]u8 = @splat(0xCD);

fn nativePayload() [40]u8 {
    var bytes: [40]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 32, .little);
    std.mem.writeInt(u32, bytes[4..8], 1, .little);
    std.mem.writeInt(u32, bytes[8..12], identity.vendor_id, .little);
    std.mem.writeInt(u32, bytes[12..16], identity.device_id, .little);
    @memcpy(bytes[16..32], &identity.pipeline_cache_uuid);
    @memcpy(bytes[32..40], "snapshot");
    return bytes;
}

fn encodedArtifact() ![168]u8 {
    const payload = nativePayload();
    const header = try artifact.encodeHeader(.{
        .identity = identity,
        .isolation_key_hash = isolation_hash,
        .payload = &payload,
    });
    var bytes: [168]u8 = undefined;
    @memcpy(bytes[0..128], &header);
    @memcpy(bytes[128..], &payload);
    return bytes;
}

const Storage = struct {
    bytes: ?[]const u8 = null,
    load_error: ?provider.ProviderError = null,
    store_error: ?provider.ProviderError = null,
    load_count: usize = 0,
    store_count: usize = 0,

    fn interface(self: *Storage) provider.PipelineCacheProvider {
        return .{ .context = self, .load_fn = load, .store_fn = store };
    }
    fn load(allocator: std.mem.Allocator, _: std.Io, context: *anyopaque,
        key: [32]u8, _: usize) provider.ProviderError!provider.LoadResult
    {
        const self: *Storage = @ptrCast(@alignCast(context));
        self.load_count += 1;
        std.debug.assert(std.mem.eql(u8, &key, &artifact.storageKey(identity, isolation_hash)));
        if (self.load_error) |err| return err;
        if (self.bytes) |bytes| return .{ .hit = try allocator.dupe(u8, bytes) };
        return .{ .miss = .not_found };
    }
    fn store(_: std.Io, context: *anyopaque, key: [32]u8,
        bytes: []const u8) provider.ProviderError!void
    {
        const self: *Storage = @ptrCast(@alignCast(context));
        self.store_count += 1;
        std.debug.assert(std.mem.eql(u8, &key, &artifact.storageKey(identity, isolation_hash)));
        std.debug.assert(bytes.len >= artifact.header_byte_count);
        if (self.store_error) |err| return err;
    }
};

// Device carries the injection state, so tests do not share mutable globals.
const NativeFailure = struct {
    create_result: vk.VkResult = vk.VK_SUCCESS,
    query_result: vk.VkResult = vk.VK_SUCCESS,
    query_byte_count: usize = 40,
    incomplete: bool = false,
    create_count: usize = 0,
    destroy_count: usize = 0,
    size_query_count: usize = 0,
    data_query_count: usize = 0,
    initial_byte_count: usize = 0,
    payload: [40]u8 = nativePayload(),

    fn state(device: vk.VkDevice) *NativeFailure {
        return @ptrCast(@alignCast(device.?));
    }
    fn device(self: *NativeFailure) vk.VkDevice {
        return @ptrCast(self);
    }
    fn create(device_handle: vk.VkDevice, info: [*c]const vk.VkPipelineCacheCreateInfo,
        _: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkPipelineCache)
        callconv(.c) vk.VkResult
    {
        const self = state(device_handle);
        self.create_count += 1;
        self.initial_byte_count = info[0].initialDataSize;
        if (self.create_result != vk.VK_SUCCESS) return self.create_result;
        output[0] = @ptrCast(self);
        return vk.VK_SUCCESS;
    }
    fn destroy(device_handle: vk.VkDevice, cache: vk.VkPipelineCache,
        _: [*c]const vk.VkAllocationCallbacks) callconv(.c) void
    {
        const self = state(device_handle);
        std.debug.assert(cache == @as(vk.VkPipelineCache, @ptrCast(self)));
        self.destroy_count += 1;
    }
    fn query(device_handle: vk.VkDevice, _: vk.VkPipelineCache,
        byte_count: [*c]usize, output: ?*anyopaque) callconv(.c) vk.VkResult
    {
        const self = state(device_handle);
        if (output) |pointer| {
            self.data_query_count += 1;
            if (self.incomplete) return vk.VK_INCOMPLETE;
            if (self.query_result != vk.VK_SUCCESS) return self.query_result;
            std.debug.assert(byte_count[0] >= self.payload.len);
            const bytes: [*]u8 = @ptrCast(pointer);
            @memcpy(bytes[0..self.payload.len], &self.payload);
            byte_count[0] = self.payload.len;
        } else {
            self.size_query_count += 1;
            byte_count[0] = self.query_byte_count;
        }
        return self.query_result;
    }
};

const Admission = struct {
    instance_procs: dispatch.InstanceProcs = std.mem.zeroes(dispatch.InstanceProcs),
    device_procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs),
    instance: capabilities.InstanceCapabilities = undefined,
    native: capabilities.NativeCapabilities = undefined,

    fn init(self: *Admission) void {
        self.device_procs.create_pipeline_cache = NativeFailure.create;
        self.device_procs.get_pipeline_cache_data = NativeFailure.query;
        self.device_procs.destroy_pipeline_cache = NativeFailure.destroy;
        self.instance = .{
            .enabled = .{},
            .procs = &self.instance_procs,
            .xlib_surface_api = false,
            .wayland_surface_api = false,
            .android_surface_api = false,
        };
        self.native = .{
            .instance = &self.instance,
            .enabled_device = .{},
            .procs = &self.device_procs,
            .swapchain = false,
            .external_memory_opaque_fd = false,
            .external_memory_dma_buf = false,
            .external_semaphore_opaque_fd = false,
            .external_semaphore_sync_fd = false,
            .external_memory_ahb = false,
            .sampler_ycbcr_conversion = false,
            .pipeline_cache = true,
        };
    }
    fn options(self: *Admission, seam: *NativeFailure, storage: *Storage)
        handler.CreateOptions
    {
        return .{
            .backend = dusk.pipeline.pipeline_backend.Backend.fromDeviceProcs(
                seam.device(), &self.device_procs),
            .capabilities = &self.native,
            .identity = identity,
            .isolation_key_hash = isolation_hash,
            .provider = storage.interface(),
        };
    }
};

test "driver cache rejects unavailable capability before provider or native calls" {
    var admission: Admission = .{};
    admission.init();
    admission.native.pipeline_cache = false;
    var seam: NativeFailure = .{};
    var storage: Storage = .{};
    try t.expectError(error.PipelineCacheUnavailable,
        handler.DriverCacheHandler.create(t.allocator, t.io, admission.options(&seam, &storage)));
    try t.expectEqual(@as(usize, 0), storage.load_count);
    try t.expectEqual(@as(usize, 0), seam.create_count);
}

test "driver cache rejects missing PFNs and device or proc disagreement" {
    inline for (.{
        .{ "create_pipeline_cache", error.CreatePipelineCacheNotLoaded },
        .{ "get_pipeline_cache_data", error.GetPipelineCacheDataNotLoaded },
        .{ "destroy_pipeline_cache", error.DestroyPipelineCacheNotLoaded },
    }) |entry|
    {
        var admission: Admission = .{};
        admission.init();
        var seam: NativeFailure = .{};
        var storage: Storage = .{};
        var options = admission.options(&seam, &storage);
        @field(options.backend, entry[0]) = null;
        try t.expectError(entry[1],
            handler.DriverCacheHandler.create(t.allocator, t.io, options));
        try t.expectEqual(@as(usize, 0), storage.load_count);
        try t.expectEqual(@as(usize, 0), seam.create_count);
        options = admission.options(&seam, &storage);
        @field(admission.device_procs, entry[0]) = null;
        try t.expectError(error.PipelineCacheDeviceMismatch,
            handler.DriverCacheHandler.create(t.allocator, t.io, options));
        try t.expectEqual(@as(usize, 0), storage.load_count);
        try t.expectEqual(@as(usize, 0), seam.create_count);
    }
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{};
    var storage: Storage = .{};
    var options = admission.options(&seam, &storage);
    options.backend.device = null;
    try t.expectError(error.PipelineCacheDeviceMismatch,
        handler.DriverCacheHandler.create(t.allocator, t.io, options));
    try t.expectEqual(@as(usize, 0), storage.load_count);
    try t.expectEqual(@as(usize, 0), seam.create_count);
}

test "driver cache corrupt and foreign identity artifacts become cold loads" {
    inline for (.{ @as(usize, 88), @as(usize, 24), @as(usize, 56), @as(usize, 128) }) |offset| {
        var bytes = try encodedArtifact();
        bytes[offset] ^= 1;
        var admission: Admission = .{};
        admission.init();
        var seam: NativeFailure = .{};
        var storage: Storage = .{ .bytes = &bytes };
        var cache = try handler.DriverCacheHandler.create(t.allocator, t.io,
            admission.options(&seam, &storage));
        cache.destroy();
        try t.expectEqual(@as(usize, 0), seam.initial_byte_count);
        try t.expectEqual(@as(usize, 1), seam.create_count);
        try t.expectEqual(@as(usize, 1), seam.destroy_count);
    }
}

test "driver cache native failure never publishes or destroys an absent handle" {
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{ .create_result = vk.VK_ERROR_OUT_OF_DEVICE_MEMORY };
    var storage: Storage = .{};
    try t.expectError(error.OutOfDeviceMemory,
        handler.DriverCacheHandler.create(t.allocator, t.io, admission.options(&seam, &storage)));
    try t.expectEqual(@as(usize, 1), seam.create_count);
    try t.expectEqual(@as(usize, 0), seam.destroy_count);
}

test "driver cache native snapshot stops after three incomplete attempts" {
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{ .incomplete = true };
    var storage: Storage = .{};
    var cache = try handler.DriverCacheHandler.create(t.allocator, t.io,
        admission.options(&seam, &storage));
    defer cache.destroy();
    try t.expectError(error.PipelineCacheDataUnstable,
        handler.DriverCacheHandler.collectArtifact(t.allocator, &cache));
    try t.expectEqual(@as(usize, 3), seam.data_query_count);
    try t.expectEqual(@as(usize, 0), storage.store_count);
}

test "driver cache rejects oversized native query before allocation" {
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{
        .query_byte_count = artifact.default_maximum_payload_byte_count + 1,
    };
    var storage: Storage = .{};
    var cache = try handler.DriverCacheHandler.create(t.allocator, t.io,
        admission.options(&seam, &storage));
    defer cache.destroy();
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.ArtifactTooLarge,
        handler.DriverCacheHandler.collectArtifact(failing.allocator(), &cache));
    try t.expectEqual(@as(usize, 0), failing.alloc_index);
    try t.expectEqual(@as(usize, 0), seam.data_query_count);
}

test "driver cache provider failure propagates without creating a native cache" {
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{};
    var storage: Storage = .{ .load_error = error.Io };
    try t.expectError(error.Io,
        handler.DriverCacheHandler.create(t.allocator, t.io, admission.options(&seam, &storage)));
    try t.expectEqual(@as(usize, 0), seam.create_count);
    try t.expectEqual(@as(usize, 0), seam.destroy_count);
}

test "driver cache storage failure does not prevent mandatory native destroy" {
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{};
    var storage: Storage = .{ .store_error = error.AtomicReplaceFailed };
    var cache = try handler.DriverCacheHandler.create(t.allocator, t.io,
        admission.options(&seam, &storage));
    const bytes = try handler.DriverCacheHandler.collectArtifact(t.allocator, &cache);
    defer t.allocator.free(bytes);
    try t.expectError(error.AtomicReplaceFailed,
        handler.DriverCacheHandler.persist(t.io, &cache, bytes));
    cache.destroy();
    try t.expectEqual(@as(usize, 1), storage.store_count);
    try t.expectEqual(@as(usize, 1), seam.destroy_count);
    try t.expect(cache.native_cache == null);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    const bytes = try encodedArtifact();
    var admission: Admission = .{};
    admission.init();
    var seam: NativeFailure = .{};
    var storage: Storage = .{ .bytes = &bytes };
    var cache = handler.DriverCacheHandler.create(allocator, t.io,
        admission.options(&seam, &storage)) catch |err| {
        try t.expectEqual(@as(usize, 0), seam.destroy_count);
        try t.expectEqual(@as(usize, 0), seam.create_count);
        return err;
    };
    defer {
        cache.destroy();
        t.expectEqual(@as(usize, 1), seam.destroy_count) catch @panic("native cache leak");
    }
    try t.expectEqual(@as(usize, 40), seam.initial_byte_count);
    const collected = try handler.DriverCacheHandler.collectArtifact(allocator, &cache);
    defer allocator.free(collected);
    try t.expectEqualSlices(u8, &bytes, collected);
    try handler.DriverCacheHandler.persist(t.io, &cache, collected);
}

test "driver cache fail-N allocator frees load and snapshot buffers and retires cache" {
    try t.checkAllAllocationFailures(t.allocator, allocationLifecycle, .{});
}

const CallbackStorage = struct {
    bytes: ?[]u8 = null,
    key: ?[32]u8 = null,
    load_count: usize = 0,
    store_count: usize = 0,
    copied_load_count: usize = 0,
    expected_reload: ?[]const u8 = null,
    delivered_bytes: ?[]u8 = null,

    fn deinit(self: *CallbackStorage) void {
        if (self.bytes) |bytes| t.allocator.free(bytes);
        if (self.delivered_bytes) |bytes| t.allocator.free(bytes);
    }
    fn load(userdata: ?*anyopaque, key_byte_count: usize, key: ?[]const u8,
        capacity: usize, output: []u8) usize
    {
        const self: *CallbackStorage = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(key_byte_count == 32);
        if (self.key) |stored_key| {
            std.debug.assert(std.mem.eql(u8, &stored_key, key.?));
        }
        self.load_count += 1;
        const bytes = self.bytes orelse return 0;
        if (capacity == 0) return bytes.len;
        std.debug.assert(capacity == bytes.len);
        std.debug.assert(output.len >= bytes.len);
        @memcpy(output[0..bytes.len], bytes);
        if (self.expected_reload) |expected| {
            std.debug.assert(std.mem.eql(u8, expected, output[0..bytes.len]));
        }
        if (self.delivered_bytes) |previous| t.allocator.free(previous);
        self.delivered_bytes = t.allocator.dupe(u8, output[0..bytes.len]) catch
            @panic("callback reload capture allocation");
        self.copied_load_count += 1;
        return bytes.len;
    }
    fn store(userdata: ?*anyopaque, key_byte_count: usize, key: ?[]const u8,
        value_byte_count: usize, value: ?[]const u8) void
    {
        const self: *CallbackStorage = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(key_byte_count == 32);
        std.debug.assert(value_byte_count == value.?.len);
        var stored_key: [32]u8 = undefined;
        @memcpy(&stored_key, key.?);
        if (self.key) |previous| std.debug.assert(std.mem.eql(u8, &previous, &stored_key));
        const copied = t.allocator.dupe(u8, value.?) catch @panic("callback fixture allocation");
        if (self.bytes) |previous| t.allocator.free(previous);
        self.bytes = copied;
        self.key = stored_key;
        self.store_count += 1;
    }
};

const NativeIdentity = struct {
    driver: artifact.Identity,
    isolation: [32]u8,
};

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: dusk.core.ErrorView) void {
    @panic("native cache fixture reported an uncaptured error");
}

fn nativeDeviceLifetime(adapter: *dusk.engine.Adapter, storage: *CallbackStorage,
    configuration: provider.PipelineCacheConfiguration, isolation: []const u8) !NativeIdentity
{
    const required: dusk.api.Limits = .{ .max_immediate_size = 256 };
    var device = try adapter.createDevice(t.allocator, t.io, .{
        .adapter = adapter,
        .feature_level = .core,
        .required_limits = &required,
        .uncaptured_context = storage,
        .uncaptured_callback = uncaptured,
        .pipeline_cache_isolation_key = isolation,
        .pipeline_cache_configuration = configuration,
    });
    var device_alive = true;
    defer if (device_alive) device.deinit(t.allocator, t.io) catch @panic("device rollback");
    const driver_cache = &device.native.?.driver_cache.?;
    try t.expect(driver_cache.native_cache != null);
    const expected: NativeIdentity = .{
        .driver = driver_cache.identity,
        .isolation = driver_cache.isolation_key_hash,
    };
    const properties = device.native.?.native_device.physical.properties;
    try t.expectEqual(properties.vendorID, expected.driver.vendor_id);
    try t.expectEqual(properties.deviceID, expected.driver.device_id);
    try t.expectEqual(properties.driverVersion, expected.driver.driver_version);
    try t.expectEqualSlices(u8, &properties.pipelineCacheUUID,
        &expected.driver.pipeline_cache_uuid);
    try gpu_consumer.exercise(t.allocator, t.io, &device);
    const snapshot = try handler.DriverCacheHandler.collectArtifact(t.allocator, driver_cache);
    defer t.allocator.free(snapshot);
    const payload = try artifact.decodeView(snapshot, .{
        .expected_identity = expected.driver,
        .isolation_key_hash = expected.isolation,
    });
    try t.expect(payload.len >= 32);
    // Teardown, not the test helper, must invoke persistence after resource retirement.
    device_alive = false;
    try device.deinit(t.allocator, t.io);
    return expected;
}

test "two actual Vulkan device lifetimes persist and reload compute and render cache payload" {
    var storage: CallbackStorage = .{};
    defer storage.deinit();
    var instance = dusk.engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(t.allocator, t.io) catch @panic("instance teardown");
    var adapters = try instance.enumerateAdapters(t.allocator, t.io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(t.io) catch @panic("adapter teardown");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    const configuration: provider.PipelineCacheConfiguration = .{ .callbacks = .{
        .load = .{ .callback = CallbackStorage.load, .userdata = &storage },
        .store = .{ .callback = CallbackStorage.store, .userdata = &storage },
    } };
    const first = try nativeDeviceLifetime(&adapters.items[0], &storage, configuration,
        "pipeline-cache-device-fixture");
    try t.expectEqual(@as(usize, 1), storage.store_count);
    try t.expectEqual(@as(usize, 1), storage.load_count);
    try t.expectEqual(@as(usize, 0), storage.copied_load_count);
    const committed = try t.allocator.dupe(u8,
        storage.bytes orelse return error.TestUnexpectedResult);
    defer t.allocator.free(committed);
    storage.expected_reload = committed;
    const first_payload = try artifact.decodeView(committed, .{
        .expected_identity = first.driver,
        .isolation_key_hash = first.isolation,
    });
    try t.expect(first_payload.len >= 32);
    const second = try nativeDeviceLifetime(&adapters.items[0], &storage, configuration,
        "pipeline-cache-device-fixture");
    try t.expectEqualSlices(u8, committed,
        storage.delivered_bytes orelse return error.TestUnexpectedResult);
    try t.expectEqual(first.driver.vendor_id, second.driver.vendor_id);
    try t.expectEqual(first.driver.device_id, second.driver.device_id);
    try t.expectEqual(first.driver.driver_version, second.driver.driver_version);
    try t.expectEqualSlices(u8, &first.driver.pipeline_cache_uuid, &second.driver.pipeline_cache_uuid);
    try t.expectEqualSlices(u8, &first.isolation, &second.isolation);
    try t.expectEqual(@as(usize, 2), storage.store_count);
    try t.expectEqual(@as(usize, 3), storage.load_count);
    try t.expectEqual(@as(usize, 1), storage.copied_load_count);
    const second_payload = try artifact.decodeView(storage.bytes.?, .{
        .expected_identity = second.driver,
        .isolation_key_hash = second.isolation,
    });
    try t.expect(second_payload.len >= 32);
}

test "actual Vulkan persistence failure consumes device and still destroys native ownership" {
    var root = t.tmpDir(.{});
    defer root.cleanup();
    var context_byte: u8 = 0;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(t.allocator, t.io) catch @panic("instance teardown");
    var adapters = try instance.enumerateAdapters(t.allocator, t.io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(t.io) catch @panic("adapter teardown");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var device = try adapters.items[0].createDevice(t.allocator, t.io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &context_byte,
        .uncaptured_callback = uncaptured,
        .pipeline_cache_configuration = .{ .filesystem = .{ .root = &root.dir } },
    });
    var device_alive = true;
    defer if (device_alive) device.deinit(t.allocator, t.io) catch @panic("device rollback");
    const cache = &device.native.?.driver_cache.?;
    const key = artifact.storageKey(cache.identity, cache.isolation_key_hash);
    const name = provider.fileName(key);
    try root.dir.createDir(t.io, &name, .default_dir);
    device_alive = false;
    try t.expectError(error.AtomicReplaceFailed, device.deinit(t.allocator, t.io));
    try t.expect(device.native == null);
    try t.expect(device.host_deinitialized);
    // A consumed teardown must not retry store or destroy native handles twice.
    try device.deinit(t.allocator, t.io);
}

fn loadCommitted(filesystem: *provider.FilesystemProvider, expected: NativeIdentity) ![]u8 {
    const key = artifact.storageKey(expected.driver, expected.isolation);
    return switch (try provider.PipelineCacheProvider.load(t.allocator, t.io,
        filesystem.provider(), key, artifact.default_maximum_payload_byte_count))
    {
        .hit => |bytes| bytes,
        .miss => return error.TestUnexpectedResult,
    };
}

fn expectCommitted(filesystem: *provider.FilesystemProvider, expected: NativeIdentity) !void {
    const bytes = try loadCommitted(filesystem, expected);
    defer t.allocator.free(bytes);
    const key = artifact.storageKey(expected.driver, expected.isolation);
    const name = provider.fileName(key);
    const raw = try filesystem.configuration.root.readFileAlloc(t.io, &name, t.allocator,
        .limited(artifact.header_byte_count + artifact.default_maximum_payload_byte_count));
    defer t.allocator.free(raw);
    try t.expectEqualSlices(u8, raw, bytes);
    const payload = try artifact.decodeView(bytes, .{
        .expected_identity = expected.driver,
        .isolation_key_hash = expected.isolation,
    });
    try t.expect(payload.len >= 32);
}

test "actual filesystem device cache cold warm malformed and isolation lifetimes" {
    var root = t.tmpDir(.{});
    defer root.cleanup();
    var filesystem: provider.FilesystemProvider = .{ .configuration = .{ .root = &root.dir } };
    const configuration: provider.PipelineCacheConfiguration = .{
        .filesystem = .{ .root = &root.dir },
    };
    var context: CallbackStorage = .{};
    defer context.deinit();
    var instance = dusk.engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(t.allocator, t.io) catch @panic("instance teardown");
    var adapters = try instance.enumerateAdapters(t.allocator, t.io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(t.io) catch @panic("adapter teardown");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    const cold = try nativeDeviceLifetime(&adapters.items[0], &context, configuration, "first");
    try expectCommitted(&filesystem, cold);
    const warm = try nativeDeviceLifetime(&adapters.items[0], &context, configuration, "first");
    try t.expectEqualSlices(u8, &cold.isolation, &warm.isolation);
    try t.expectEqualSlices(u8, &cold.driver.pipeline_cache_uuid, &warm.driver.pipeline_cache_uuid);
    try expectCommitted(&filesystem, warm);

    const corrupted = try loadCommitted(&filesystem, warm);
    defer t.allocator.free(corrupted);
    corrupted[88] ^= 1;
    const first_key = artifact.storageKey(warm.driver, warm.isolation);
    try filesystem.provider().store(t.io, first_key, corrupted);
    try t.expectError(error.CacheIntegrityMismatch, artifact.decodeView(corrupted, .{
        .expected_identity = warm.driver,
        .isolation_key_hash = warm.isolation,
    }));
    const recovered = try nativeDeviceLifetime(&adapters.items[0], &context,
        configuration, "first");
    try expectCommitted(&filesystem, recovered);

    const before_isolation = try loadCommitted(&filesystem, recovered);
    defer t.allocator.free(before_isolation);
    const isolated = try nativeDeviceLifetime(&adapters.items[0], &context,
        configuration, "second");
    try t.expect(!std.mem.eql(u8, &recovered.isolation, &isolated.isolation));
    const isolated_key = artifact.storageKey(isolated.driver, isolated.isolation);
    try t.expect(!std.mem.eql(u8, &first_key, &isolated_key));
    try expectCommitted(&filesystem, isolated);
    const after_isolation = try loadCommitted(&filesystem, recovered);
    defer t.allocator.free(after_isolation);
    try t.expectEqualSlices(u8, before_isolation, after_isolation);
}
