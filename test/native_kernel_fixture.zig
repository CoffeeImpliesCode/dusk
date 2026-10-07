//! Native utility fixtures borrow the caller's only core device and object mutex.
//! Initialize at the final address. Release cache roots, retire core payloads,
//! release the stores, unlock the guard, then release native owners.
const std = @import("std");
const dusk = @import("dusk");
const engine = dusk.engine;
const core = dusk.core;
const pipeline = dusk.pipeline.pipeline;
const resources = engine.native_resources;
const native = engine.vulkan_device;
const kernels = engine.native_kernels;

pub const InitError = engine.InstanceError || native.Device.CreateError ||
    native.ProcError || engine.queue.Queue.InitError || engine.limits.ReifyError || error{
    Canceled,
    NoPhysicalDevice,
    NativeBackendRequired,
    ResourceDeviceMismatch,
    AllocatorMismatch,
    LimitsCompatibilityBlockMissing,
};
pub const StoreDeinitError = dusk.pipeline.cache.PipelineCache.DestroyError ||
    error{ResourceInUse};
pub const NativeDeinitError = engine.queue.Queue.CleanupError || native.ProcError ||
    engine.AdapterList.DeinitError || engine.Instance.DeinitError;

/// Owns native owners and ordinary stores, but never owns the borrowed core device.
/// Do not copy or move this fixture after init. Serialize use and proc-table edits.
/// Keep the allocator, core device, and mutex alive through native cleanup.
pub const NativeKernelFixture = struct {
    instance: engine.Instance,
    adapters: engine.AdapterList,
    native_device: native.Device,
    queue: engine.queue.Queue,
    core_device: *core.Device,
    mutex: *dusk.platform.DeviceMutex,
    resource_store: engine.native_resource_store.ResourceStore,
    pipeline_store: pipeline.PipelineStore,
    pipeline_backend: pipeline.Backend,
    kernels: kernels.KernelCache,
    enabled_features: engine.features.FeaturesSet,
    limits: engine.limits.CombinedLimits,
    formats: engine.format.FormatTable,
    timestamp_quantization: bool,
    /// Saved values, not a replacement dispatch allocation or device owner.
    original_procs: dusk.vk.dispatch.DeviceProcs,

    /// Creates a real device and a queue with an allocated recording command buffer.
    /// Uses the discovered adapter's default feature policy and bounded effective limits.
    /// On error, no fixture stores or native owners remain. Do not deinit after an error.
    pub fn init(
        self: *NativeKernelFixture,
        allocator: std.mem.Allocator,
        io: std.Io,
        core_device: *core.Device,
        mutex: *dusk.platform.DeviceMutex,
    ) InitError!void {
        const objects = core_device.borrow().objectList();
        if (objects.mutex != &mutex.mutex) return error.ResourceDeviceMismatch;
        {
            var guard = try core.ObjectGuard.lock(io, objects);
            defer guard.unlock(io);
            try core_device.arena.checkAllocator(&guard, allocator);
        }
        self.core_device = core_device;
        self.mutex = mutex;
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(allocator, io) catch |err| {
            std.log.err("native fixture instance rollback: {s}", .{@errorName(err)});
        };
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch |err| {
            std.log.err("native fixture adapter rollback: {s}", .{@errorName(err)});
        };
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        const adapter = &self.adapters.items[0];
        const selected = adapter.physical_device.native_adapter orelse
            return error.NativeBackendRequired;
        if (adapter.limits.compatibility == null)
            return error.LimitsCompatibilityBlockMissing;
        self.enabled_features = engine.applyFeatures(adapter.feature_level, &.{});
        const effective_level: engine.FeatureLevel =
            if (self.enabled_features.isEnabled(.core_features_and_limits))
                .core
            else
                .compatibility;
        self.limits = try engine.limits.reify(adapter.limits, effective_level, null);
        engine.enforceLimitSpecInvariants(&self.limits, effective_level);
        self.timestamp_quantization = true;
        engine.format.buildFormatTable(self.enabled_features, &self.formats);
        self.native_device = try native.Device.create(allocator, .{
            .instance = selected.instance,
            .physical = &selected.physical,
            .handles = &self.instance.native_context.?.handles,
            .required_features = &.{},
        });
        errdefer self.native_device.deinit(allocator) catch |err| {
            std.log.err("native fixture device rollback: {s}", .{@errorName(err)});
        };
        self.original_procs = self.native_device.procs.*;
        self.queue = try engine.queue.Queue.init(.{
            .device_mutex = mutex,
            .context = .{
                .allocator = allocator,
                .dispatch = self.native_device.dispatchTable(),
                .vk_device = self.native_device.vk_device,
                .vk_queue = try self.native_device.fetchQueue(),
                .queue_family_index = self.native_device.queue_family_index,
                .memory_properties = self.native_device.memoryProperties(),
                .handles = self.native_device.handles,
            },
        });
        errdefer self.queue.deinitUnpublished() catch |err| {
            std.log.err("native fixture queue rollback: {s}", .{@errorName(err)});
        };
        {
            var guard = try core.ObjectGuard.lock(io, objects);
            defer guard.unlock(io);
            self.resource_store = engine.native_resource_store.ResourceStore.init(
                allocator,
                objects,
            );
            self.pipeline_store = pipeline.PipelineStore.init(allocator, objects);
            self.pipeline_backend = pipeline.Backend.fromDeviceProcs(
                self.native_device.vk_device,
                self.native_device.procs,
            );
            self.kernels = kernels.KernelCache.init(.{
                .objects = objects,
                .native_device = &self.native_device,
                .enabled_features = &self.enabled_features,
                .limits = &self.limits,
                .formats = &self.formats,
                .resource_device = self.resourceDevice(),
                .pipeline_store = &self.pipeline_store,
                .pipeline_backend = &self.pipeline_backend,
            });
        }
        std.debug.assert(self.queue.commandBuffer() != null);
        std.debug.assert(self.queue.context.dispatch.device == self.native_device.procs);
        std.debug.assert(self.kernels.objects == objects);
    }

    /// Borrows this device's actual allocation limits, dispatch, and handle set.
    pub fn bufferDevice(self: *const NativeKernelFixture) engine.buffer.Device {
        return .{
            .allocator = self.queue.context.allocator,
            .dispatch = self.native_device.dispatchTable(),
            .vk_device = self.native_device.vk_device,
            .memory_properties = self.native_device.memoryProperties(),
            .non_coherent_atom_size = self.native_device.physical.properties.limits.nonCoherentAtomSize,
            .max_buffer_size = self.native_device.maxBufferSize(),
            .handles = self.native_device.handles,
        };
    }

    /// Borrows ordinary stores and the same actual device used by the queue and kernels.
    pub fn resourceDevice(self: *NativeKernelFixture) resources.NativeDevice {
        return .{
            .procs = self.native_device.procs,
            .handle = self.native_device.vk_device,
            .api_version = self.native_device.api_version,
            .buffer_limits = engine.bind_group.BufferLimits.fromPhysicalDeviceLimits(
                &self.native_device.physical.properties.limits,
            ),
            .buffer_device = self.bufferDevice(),
            .resource_store = &self.resource_store,
        };
    }

    /// Refreshes the pipeline seam after serialized, in-place edits to native_device.procs.*.
    /// The backend address remains stable for all existing pipeline payloads.
    pub fn refreshPipelineBackend(self: *NativeKernelFixture) void {
        self.pipeline_backend = pipeline.Backend.fromDeviceProcs(
            self.native_device.vk_device,
            self.native_device.procs,
        );
    }

    /// Restores the owned dispatch allocation in place. No helper keeps a second table pointer.
    pub fn restoreDeviceProcs(self: *NativeKernelFixture) void {
        self.native_device.procs.* = self.original_procs;
        self.refreshPipelineBackend();
    }

    /// Releases cache leases under the original guard before caller-owned payload retirement.
    pub fn releaseCacheRootsLocked(
        self: *NativeKernelFixture,
        guard: *const core.ObjectGuard,
        io: std.Io,
    ) void {
        guard.assertOwns(self.core_device.borrow().objectList());
        self.kernels.releaseRootsLocked(guard, io);
    }

    /// Releases weak stores only after all their payload removal hooks have run.
    /// Live entries refuse cleanup unchanged. Call once after successful payload retirement.
    pub fn deinitStoresLocked(
        self: *NativeKernelFixture,
        guard: *const core.ObjectGuard,
    ) StoreDeinitError!void {
        guard.assertOwns(self.core_device.borrow().objectList());
        const store = &self.resource_store;
        if (!store.bind_group_layouts.isEmpty(guard) or
            !store.pipeline_layouts.isEmpty(guard) or
            !store.shader_modules.isEmpty(guard) or
            !store.samplers.isEmpty(guard) or
            !store.attachments.isEmpty(guard)) return error.ResourceInUse;
        try self.pipeline_store.deinit(guard);
        self.resource_store.deinit(guard);
    }

    /// Call without an object guard after store cleanup. The original object list stays alive.
    /// Restores dispatch before queue cleanup, then releases device, adapters, and instance.
    /// Call once. A native cleanup error is terminal for this fixture.
    pub fn deinitNative(
        self: *NativeKernelFixture,
        allocator: std.mem.Allocator,
        io: std.Io,
        objects: *core.ObjectList,
    ) NativeDeinitError!void {
        std.debug.assert(objects == self.core_device.borrow().objectList());
        std.debug.assert(objects.mutex == &self.mutex.mutex);
        self.restoreDeviceProcs();
        try self.queue.deinit(io, objects);
        try self.native_device.deinit(allocator);
        try self.adapters.deinit(io);
        try self.instance.deinit(allocator, io);
        self.* = undefined;
    }
};
