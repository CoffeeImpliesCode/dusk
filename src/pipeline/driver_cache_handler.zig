//! One native pipeline cache per actual VkDevice, with bounded persistence snapshots.
//! Device teardown owns queue drain and its first-error consumed receipt. This module never
//! calls a provider while holding a GPU lock; create/persist callers must enforce that boundary.
//! Dawn mapping: PipelineCacheVk.cpp:123-148 (initialize), :76-121 (serialize), and
//! PipelineCache.cpp:37-68 (load/store), at 32f77c02294310054a660c393feded4bcb3f203c.
const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const pipeline_backend = @import("pipeline_backend.zig");
const codec = @import("cache_artifact.zig");
const providers = @import("cache_provider.zig");
const native_capabilities = @import("../engine/native_capabilities.zig");

pub const Error = providers.ProviderError || codec.Error || pipeline_backend.BackendError || error{
    PipelineCacheUnavailable,
    PipelineCacheDataUnstable,
    PipelineCacheDeviceMismatch,
};
pub const snapshot_attempt_limit: usize = 3;

pub const CreateOptions = struct {
    backend: pipeline_backend.Backend,
    capabilities: *const native_capabilities.NativeCapabilities,
    identity: codec.Identity,
    isolation_key_hash: [32]u8,
    provider: providers.PipelineCacheProvider,
    maximum_payload_byte_count: usize = codec.default_maximum_payload_byte_count,
};

pub const DriverCacheHandler = struct {
    device: vulkan.VkDevice,
    native_cache: vulkan.VkPipelineCache,
    backend: pipeline_backend.Backend,
    capabilities: *const native_capabilities.NativeCapabilities,
    identity: codec.Identity,
    isolation_key_hash: [32]u8,
    maximum_payload_byte_count: usize,
    provider: providers.PipelineCacheProvider,

    /// Borrows exact live device capabilities and a stable provider context through destroy.
    /// Provider allocation is freed after the synchronous native create, including native failure.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: CreateOptions) Error!DriverCacheHandler {
        try validateOptions(options);
        const key = codec.storageKey(options.identity, options.isolation_key_hash);
        const loaded = try options.provider.load_fn(
            allocator,
            io,
            options.provider.context,
            key,
            options.maximum_payload_byte_count,
        );
        defer switch (loaded) {
            .hit => |bytes| allocator.free(bytes),
            .miss => {},
        };
        const payload: []const u8 = switch (loaded) {
            .miss => &.{},
            .hit => |bytes| codec.decodeView(bytes, .{
                .expected_identity = options.identity,
                .isolation_key_hash = options.isolation_key_hash,
                .maximum_payload_byte_count = options.maximum_payload_byte_count,
            }) catch &.{},
        };
        const info: vulkan.VkPipelineCacheCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .initialDataSize = payload.len,
            .pInitialData = if (payload.len == 0) null else payload.ptr,
        };
        var handle: vulkan.VkPipelineCache = null;
        const create_native = options.backend.create_pipeline_cache.?;
        try dispatch.checkVkSuccess(create_native(options.backend.device, &info, null, &handle));
        if (handle == null) return error.InitializationFailed;
        return .{
            .device = options.backend.device,
            .native_cache = handle,
            .backend = options.backend,
            .capabilities = options.capabilities,
            .identity = options.identity,
            .isolation_key_hash = options.isolation_key_hash,
            .maximum_payload_byte_count = options.maximum_payload_byte_count,
            .provider = options.provider,
        };
    }

    /// Call only after accepted work has drained, while the queue gate excludes pipeline creation.
    /// Returns a single allocator-owned artifact. No provider or user callback is invoked here.
    pub fn collectArtifact(allocator: std.mem.Allocator, self: *const DriverCacheHandler) Error![]u8 {
        std.debug.assert(self.native_cache != null);
        const get_data = self.backend.get_pipeline_cache_data.?;
        for (0..snapshot_attempt_limit) |_| {
            var payload_byte_count: usize = 0;
            const count_result = get_data(self.device, self.native_cache, &payload_byte_count, null);
            if (count_result != vulkan.VK_SUCCESS and count_result != vulkan.VK_INCOMPLETE) {
                try dispatch.checkVkSuccess(count_result);
            }
            const artifact_byte_count = try self.artifactByteCount(payload_byte_count);
            var artifact = try allocator.alloc(u8, artifact_byte_count);
            errdefer allocator.free(artifact);
            var written_byte_count = payload_byte_count;
            const data_result = get_data(
                self.device,
                self.native_cache,
                &written_byte_count,
                if (payload_byte_count == 0) null else artifact[codec.header_byte_count..].ptr,
            );
            if (written_byte_count > payload_byte_count) {
                if (written_byte_count > self.maximum_payload_byte_count) return error.ArtifactTooLarge;
                allocator.free(artifact);
                continue;
            }
            if (data_result == vulkan.VK_INCOMPLETE) {
                allocator.free(artifact);
                continue;
            }
            try dispatch.checkVkSuccess(data_result);
            const actual_byte_count = try self.artifactByteCount(written_byte_count);
            const header = try codec.encodeHeader(.{
                .identity = self.identity,
                .isolation_key_hash = self.isolation_key_hash,
                .payload = artifact[codec.header_byte_count..actual_byte_count],
                .maximum_payload_byte_count = self.maximum_payload_byte_count,
            });
            @memcpy(artifact[0..codec.header_byte_count], &header);
            if (artifact.len != actual_byte_count) artifact = try allocator.realloc(artifact, actual_byte_count);
            return artifact;
        }
        return error.PipelineCacheDataUnstable;
    }

    /// Call after releasing all queue, Device, ObjectGuard and lifecycle locks.
    /// Callback return means invocation, not filesystem durability. Artifact remains caller-owned.
    pub fn persist(io: std.Io, self: *const DriverCacheHandler, artifact: []const u8) providers.ProviderError!void {
        return self.provider.store_fn(
            io,
            self.provider.context,
            codec.storageKey(self.identity, self.isolation_key_hash),
            artifact,
        );
    }

    /// Must run before destroying VkDevice, even when collection or persistence fails.
    pub fn destroy(self: *DriverCacheHandler) void {
        if (self.native_cache == null) return;
        self.backend.destroy_pipeline_cache.?(self.device, self.native_cache, null);
        self.native_cache = null;
        std.debug.assert(self.native_cache == null);
    }

    fn artifactByteCount(self: *const DriverCacheHandler, payload_byte_count: usize) Error!usize {
        if (payload_byte_count > self.maximum_payload_byte_count) return error.ArtifactTooLarge;
        return std.math.add(usize, codec.header_byte_count, payload_byte_count) catch error.ArtifactTooLarge;
    }
};

fn validateOptions(options: CreateOptions) Error!void {
    if (!options.capabilities.pipeline_cache) return error.PipelineCacheUnavailable;
    if (options.maximum_payload_byte_count > codec.default_maximum_payload_byte_count) {
        return error.ArtifactTooLarge;
    }
    if (options.backend.device == null) return error.PipelineCacheDeviceMismatch;
    const procs = options.capabilities.procs;
    if (options.backend.create_pipeline_cache == null) return error.CreatePipelineCacheNotLoaded;
    if (options.backend.get_pipeline_cache_data == null) return error.GetPipelineCacheDataNotLoaded;
    if (options.backend.destroy_pipeline_cache == null) return error.DestroyPipelineCacheNotLoaded;
    if (options.backend.create_pipeline_cache != procs.create_pipeline_cache or
        options.backend.get_pipeline_cache_data != procs.get_pipeline_cache_data or
        options.backend.destroy_pipeline_cache != procs.destroy_pipeline_cache)
    {
        return error.PipelineCacheDeviceMismatch;
    }
}
