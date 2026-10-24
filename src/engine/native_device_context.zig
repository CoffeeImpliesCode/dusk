//! Stable native storage. Allocate before initialization; never move this owner.
//! Core objects attach only after the high Device reaches its final address.
const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");
const dispatch = @import("../vk/dispatch.zig");
const native = @import("vulkan_device.zig");
const queues = @import("queue.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const pipeline_cache = @import("../pipeline/cache.zig");
const shader_vk = @import("../pipeline/shader_module_vk.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const passes = @import("render_pass_cache.zig");
const frames = @import("framebuffer_cache.zig");
const recording = @import("recording_context.zig");
const replay = @import("command_buffer.zig");
const encoding = @import("../command/encoding_context.zig");
const resources = @import("native_resources.zig");
const bind_group = @import("bind_group.zig");
const vk_format = @import("vulkan_format.zig");
const resource_store = @import("native_resource_store.zig");
const sampler = @import("sampler.zig");
const kernels = @import("native_kernels.zig");

pub const CleanupError = native.ProcError || queues.Queue.WaitError || buffer.Error ||
    pipeline_cache.PipelineCache.DestroyError || resources.Error;
pub const Error = native.Device.CreateError || queues.Queue.InitError ||
    queues.Queue.SubmitError || CleanupError || replay.ReplayError ||
    buffer.CreateError || texture.NativeError || pipeline.PipelineError ||
    vk_format.SampleCountError || error{NativeDeviceStopped};
pub const CreateError = native.Device.CreateError || queues.Queue.InitError || native.ProcError;

pub const NativeDeviceContext = struct {
    native_device: native.Device,
    device_mutex: platform.DeviceMutex = .{},
    /// Serializes command recording, submission and every fence retirement path.
    /// Acquire this before DeviceMutex, never while blocking with DeviceMutex held.
    queue_operation_mutex: std.Io.Mutex = .init,
    queue: queues.Queue,
    pipeline_backend: pipeline.Backend,
    pipeline_store: ?pipeline.PipelineStore = null,
    resource_store: ?resource_store.ResourceStore = null,
    kernel_cache: ?kernels.KernelCache = null,
    sampler_backend: ?sampler.NativeBackend = null,
    objects: ?*core.ObjectList = null,
    pending_uses: ?resources.PendingUses = null,
    pending_uses_serial: ?platform.Serial = null,
    recording_uses: ?resources.PendingUses = null,
    pending_recording_uses: ?resources.PendingUses = null,
    native_payloads_retired: bool = false,
    cleanup_error: ?resources.Error = null,
    retirement_error: ?CleanupError = null,
    render_pass_cache: passes.RenderPassCache,
    framebuffer_cache: frames.FramebufferCache,
    deferred_framebuffers: std.ArrayList(vulkan.VkFramebuffer) = .empty,
    accepting_operations: bool = true,
    caches_live: bool = true,
    /// Successful GPU completion and terminal-safe device loss are different outcomes.
    /// Loss permits child destruction, but never publishes a successful queue serial.
    gpu_completion_established: bool = true,
    terminal_loss: bool = false,

    pub const CreateOptions = struct {
        adapter: native.Adapter,
        handles: *native.HandleSet,
        required_features: []const api.FeatureName = &.{},
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: CreateOptions,
    ) CreateError!*NativeDeviceContext {
        const self = try allocator.create(NativeDeviceContext);
        errdefer allocator.destroy(self);
        // Every borrowed field is initialized at its final heap address.
        self.native_device = try native.Device.create(allocator, .{
            .instance = options.adapter.instance,
            .physical = &options.adapter.physical,
            .handles = options.handles,
            .required_features = options.required_features,
        });
        errdefer self.native_device.deinit(allocator) catch |err| {
            std.log.err("native initialization cleanup: {s}", .{@errorName(err)});
        };
        self.device_mutex = .{};
        self.queue_operation_mutex = .init;
        self.queue = try queues.Queue.init(.{
            .device_mutex = &self.device_mutex,
            .context = .{
                .allocator = allocator,
                .dispatch = self.native_device.dispatchTable(),
                .vk_device = self.native_device.vk_device,
                .vk_queue = try self.native_device.fetchQueue(),
                .queue_family_index = self.native_device.queue_family_index,
                .memory_properties = self.native_device.memoryProperties(),
                .handles = options.handles,
            },
        });
        errdefer self.queue.deinitUnpublished() catch |err| {
            std.log.err("queue initialization cleanup: {s}", .{@errorName(err)});
        };
        // Cache teardown is infallible only after these destroy procs exist.
        const procs = self.native_device.procs;
        if (procs.destroy_render_pass == null or procs.destroy_framebuffer == null)
            return error.MissingDeviceProc;
        self.pipeline_backend = pipeline.Backend.fromDeviceProcs(self.native_device.vk_device, procs);
        self.pipeline_store = null;
        self.resource_store = null;
        self.kernel_cache = null;
        self.sampler_backend = self.samplerBackend();
        self.objects = null;
        self.pending_uses = null;
        self.pending_uses_serial = null;
        self.recording_uses = null;
        self.pending_recording_uses = null;
        self.native_payloads_retired = false;
        self.cleanup_error = null;
        self.retirement_error = null;
        self.render_pass_cache = passes.RenderPassCache.init(.{
            .allocator = allocator,
            .device = .{ .procs = procs, .vk_device = self.native_device.vk_device },
        });
        self.framebuffer_cache = frames.FramebufferCache.init(.{
            .allocator = allocator,
            .device = .{ .procs = procs, .vk_device = self.native_device.vk_device },
            .destroy_context = self,
            .destroy_when_unused = deferFramebuffer,
        });
        self.deferred_framebuffers = .empty;
        self.accepting_operations = true;
        self.caches_live = true;
        self.gpu_completion_established = true;
        self.terminal_loss = false;
        // Initialization performs no wait, but I/O remains explicit in the owner API.
        _ = io;
        return self;
    }

    pub fn bufferDevice(self: *const NativeDeviceContext) buffer.Device {
        return .{
            .allocator = self.queue.context.allocator,
            .dispatch = self.native_device.dispatchTable(),
            .vk_device = self.native_device.vk_device,
            .physical_device = self.native_device.physical.handle,
            .memory_properties = self.native_device.memoryProperties(),
            .non_coherent_atom_size = self.native_device.physical.properties.limits.nonCoherentAtomSize,
            .max_buffer_size = self.native_device.maxBufferSize(),
            .handles = self.native_device.handles,
        };
    }

    pub fn textureLimits(self: *const NativeDeviceContext) texture.TextureLimits {
        const limits = self.native_device.physical.properties.limits;
        return .{
            .max_texture_dimension_1d = limits.maxImageDimension1D,
            .max_texture_dimension_2d = limits.maxImageDimension2D,
            .max_texture_dimension_3d = limits.maxImageDimension3D,
            .max_texture_array_layers = limits.maxImageArrayLayers,
        };
    }

    pub fn shaderVk(self: *const NativeDeviceContext) shader_vk.Device {
        return shader_vk.Device.init(
            self.native_device.procs,
            self.native_device.vk_device,
            self.native_device.api_version,
        );
    }

    pub fn resourceDevice(self: *NativeDeviceContext) resources.NativeDevice {
        return .{
            .procs = self.native_device.procs,
            .handle = self.native_device.vk_device,
            .api_version = self.native_device.api_version,
            .buffer_limits = bind_group.BufferLimits.fromPhysicalDeviceLimits(
                &self.native_device.physical.properties.limits,
            ),
            .buffer_device = self.bufferDevice(),
            .resource_store = if (self.resource_store) |*store| store else null,
            .sampler_backend = if (self.sampler_backend) |*backend| backend else null,
            .cleanup_context = self,
            .record_cleanup_error = recordCleanupError,
        };
    }

    fn recordCleanupError(context: *anyopaque, err: resources.Error) void {
        const self: *NativeDeviceContext = @ptrCast(@alignCast(context));
        if (self.cleanup_error == null) self.cleanup_error = err;
        if (self.retirement_error == null) self.retirement_error = err;
    }

    pub fn samplerBackend(self: *NativeDeviceContext) sampler.NativeBackend {
        var backend = sampler.NativeBackend.fromDevice(&self.native_device);
        backend.cleanup_context = self;
        backend.record_cleanup_error = recordSamplerCleanupError;
        return backend;
    }

    fn recordSamplerCleanupError(context: *anyopaque, err: sampler.NativeError) void {
        recordCleanupError(context, err);
    }

    pub fn compatibleRenderPass(
        self: *NativeDeviceContext,
        io: std.Io,
        descriptor: resources.RenderPipelineDescriptor,
    ) Error!vulkan.VkRenderPass {
        if (!self.accepting_operations) return error.NativeDeviceStopped;
        if (descriptor.color_targets.len > passes.k_max_color_attachments)
            return error.ColorTargetCountAboveLimit;
        var query: passes.RenderPassCacheQuery = .{};
        query.setSampleCount(descriptor.multisample.count);
        for (descriptor.color_targets, 0..) |target, index| {
            if (target.format == .undefined_) continue;
            query.setColor(.{
                .index = @intCast(index),
                .format = target.format,
                .load_op = .load,
                .store_op = .store,
                .has_resolve_target = false,
                .render_to_single_sampled = false,
            });
        }
        if (descriptor.depth_stencil) |depth| {
            query.setDepthStencil(.{
                .format = depth.format,
                .depth_load_op = .load,
                .depth_store_op = .store,
                .depth_read_only = false,
                .stencil_load_op = .load,
                .stencil_store_op = .store,
                .stencil_read_only = false,
            });
        }
        const info = try self.render_pass_cache.getRenderPass(io, query);
        return info.render_pass;
    }

    pub fn initializeTexture(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        guard: *const core.ObjectGuard,
        object: *texture.Texture,
    ) Error!void {
        try self.checkObjectLocked(guard, &object.header);
        if (!self.accepting_operations) return error.NativeDeviceStopped;
        const procs = self.native_device.instance.procs;
        const query = procs.get_physical_device_image_format_properties orelse {
            return error.MissingInstanceProc;
        };
        var usage: vulkan.VkImageUsageFlags =
            vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (object.internal_usage.texture_binding) usage |= vulkan.VK_IMAGE_USAGE_SAMPLED_BIT;
        if (object.internal_usage.storage_binding) usage |= vulkan.VK_IMAGE_USAGE_STORAGE_BIT;
        if (object.internal_usage.render_attachment) usage |= if (object.format_info.isColor())
            @as(u32, vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
        else
            @as(u32, vulkan.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
        const image_type: vulkan.VkImageType = switch (object.dimension) {
            ._1d => vulkan.VK_IMAGE_TYPE_1D,
            ._2d => vulkan.VK_IMAGE_TYPE_2D,
            ._3d => vulkan.VK_IMAGE_TYPE_3D,
            .undefined_ => return error.TextureNativeUsageUnsupported,
        };
        var flags: vulkan.VkImageCreateFlags = 0;
        if (object.view_formats.len != 0) flags |= vulkan.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
        if (object.dimension == ._2d and object.getArrayLayers(guard) >= 6 and
            object.base_size.width == object.base_size.height)
        {
            flags |= vulkan.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT;
        }
        if (object.dimension == ._3d) flags |= vulkan.VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT;
        // SAFETY: a successful query writes the whole VkImageFormatProperties.
        // checkVkSuccess returns an error before any properties read on failure.
        var properties: vulkan.VkImageFormatProperties = undefined;
        try dispatch.checkVkSuccess(query(
            self.native_device.physical.handle,
            vk_format.vkFormat(object.getFormat(guard)),
            image_type,
            vulkan.VK_IMAGE_TILING_OPTIMAL,
            usage,
            flags,
            &properties,
        ));
        const depth = if (object.dimension == ._3d) object.base_size.depth_or_array_layers else 1;
        if (object.base_size.width > properties.maxExtent.width or
            object.base_size.height > properties.maxExtent.height or
            depth > properties.maxExtent.depth or object.mip_level_count > properties.maxMipLevels or
            object.getArrayLayers(guard) > properties.maxArrayLayers or
            (properties.sampleCounts & try vk_format.vkSampleCount(object.sample_count)) == 0)
        {
            return error.TextureNativeUsageUnsupported;
        }
        try object.initializeNative(allocator, guard, self.bufferDevice());
    }

    pub fn initializeTextureView(
        self: *NativeDeviceContext,
        guard: *const core.ObjectGuard,
        object: *texture.TextureView,
    ) Error!void {
        try self.checkObjectLocked(guard, &object.header);
        if (!self.accepting_operations) return error.NativeDeviceStopped;
        try object.initializeNative(guard);
    }

    fn checkObjectLocked(
        self: *NativeDeviceContext,
        guard: *const core.ObjectGuard,
        header: *const core.Object,
    ) Error!void {
        const objects = self.objects.?;
        guard.assertOwns(objects);
        std.debug.assert(objects.mutex == &self.device_mutex.mutex);
        if (header.tracking != objects) return error.ResourceDeviceMismatch;
        if (!header.node.linked or header.state != .alive) return error.ResourceDestroyed;
    }

    /// The queue gate and ObjectGuard are held before recording a staged upload.
    pub fn prepareRecordingRootLocked(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        guard: *const core.ObjectGuard,
        device: *core.Device,
        root: *core.Object,
    ) Error!void {
        try device.arena.checkAllocator(guard, allocator);
        try self.checkObjectLocked(guard, root);
        if (!self.accepting_operations) return error.NativeDeviceStopped;
        if (self.recording_uses == null) {
            self.recording_uses = try resources.PendingUses.prepareDeclaredLocked(
                allocator,
                guard,
                device,
                &.{},
            );
        }
        const batch = &self.recording_uses.?;
        try batch.retainRecordingRootLocked(guard, device, root);
    }

    fn deduplicateRecordingUsesLocked(
        self: *NativeDeviceContext,
        guard: *const core.ObjectGuard,
        io: std.Io,
        prepared: *resources.PendingUses,
    ) void {
        guard.assertOwns(self.objects.?);
        if (self.recording_uses) |*recorded| {
            var keys = recorded.roots.keyIterator();
            while (keys.next()) |key| {
                prepared.removeRootLocked(guard, io, key.*);
            }
        }
    }

    fn preflightAllocatorLocked(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *core.Device,
    ) Error!void {
        var guard = try core.ObjectGuard.lock(io, self.objects.?);
        defer guard.unlock(io);
        guard.assertOwns(device.arena.objectList());
        std.debug.assert(guard.mutex == &self.device_mutex.mutex);
        try device.arena.checkAllocator(&guard, allocator);
    }

    /// Preflight borrows Finished; replay consumes it even if native encoding fails.
    pub fn submit(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *core.Device,
        finished: *encoding.Finished,
        max_immediate_size: u32,
        timestamp_quantization: bool,
    ) Error!platform.Serial {
        try self.queue_operation_mutex.lock(io);
        defer self.queue_operation_mutex.unlock(io);
        return self.submitLocked(allocator, io, device, finished, max_immediate_size, timestamp_quantization) catch |err| {
            if (err == error.DeviceLost) self.markTerminalLossLocked(io);
            return err;
        };
    }

    fn submitLocked(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *core.Device,
        finished: *encoding.Finished,
        max_immediate_size: u32,
        timestamp_quantization: bool,
    ) Error!platform.Serial {
        if (!self.accepting_operations) return error.NativeDeviceStopped;
        try self.preflightAllocatorLocked(allocator, io, device);
        try self.waitLocked(io);
        var prepared: ?resources.PendingUses = null;
        errdefer if (prepared) |*batch| self.releasePreparedUsesLocked(io, batch);
        {
            var guard = try core.ObjectGuard.lock(io, self.objects.?);
            defer guard.unlock(io);
            guard.assertOwns(device.arena.objectList());
            std.debug.assert(guard.mutex == &self.device_mutex.mutex);
            try device.arena.checkAllocator(&guard, allocator);
            if (self.recording_uses) |*recorded| try recorded.validateGpuRootsLocked(&guard, device);
            // The framebuffer eviction callback cannot allocate during replay.
            try self.deferred_framebuffers.ensureUnusedCapacity(
                self.queue.context.allocator,
                finished.render_pass_usages.items.len,
            );
            prepared = try resources.PendingUses.prepareFinishedLocked(
                allocator,
                &guard,
                device,
                finished,
                max_immediate_size,
            );
            self.deduplicateRecordingUsesLocked(&guard, io, &prepared.?);
            var context = recording.CommandRecordingContext.init(allocator);
            defer context.deinit();
            defer finished.deinit(allocator, io, &guard);
            try replay.recordCommands(allocator, .{
                .io = io,
                .guard = &guard,
                .core_device = device,
                .max_immediate_size = max_immediate_size,
                .timestamp_quantization = timestamp_quantization,
                .kernels = &self.kernel_cache.?,
                .pending_uses = &prepared.?,
                .queue = &self.queue,
                .recording = &context,
                .render_pass_cache = &self.render_pass_cache,
                .framebuffer_cache = &self.framebuffer_cache,
            }, finished);
        }
        const commands = [_]vulkan.VkCommandBuffer{self.queue.commandBuffer()};
        const submitted = try self.queue.submit(
            io,
            self.objects.?,
            .{ .command_buffers = &commands },
        );
        self.commitUsesLocked(io, &prepared, submitted.serial);
        return submitted.serial;
    }

    /// The caller's QueueLease owns the queue gate and pins the high device.
    pub fn submitDeclaredLocked(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *core.Device,
        options: queues.Queue.SubmitOptions,
        roots: []const *core.Object,
    ) Error!queues.Queue.SubmitResult {
        return self.submitDeclaredLockedInner(allocator, io, device, options, roots) catch |err| {
            if (err == error.DeviceLost) self.markTerminalLossLocked(io);
            return err;
        };
    }

    fn submitDeclaredLockedInner(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *core.Device,
        options: queues.Queue.SubmitOptions,
        roots: []const *core.Object,
    ) Error!queues.Queue.SubmitResult {
        if (!self.accepting_operations) return error.NativeDeviceStopped;
        try self.preflightAllocatorLocked(allocator, io, device);
        if (self.recording_uses != null) {
            const recording_buffer = self.queue.commandBuffer();
            var includes_recording = false;
            for (options.command_buffers) |command_buffer| {
                if (command_buffer == recording_buffer) {
                    includes_recording = true;
                    break;
                }
            }
            if (!includes_recording) return error.PendingRecordingNotSubmitted;
        }
        try self.waitLocked(io);
        var prepared: ?resources.PendingUses = null;
        errdefer if (prepared) |*batch| self.releasePreparedUsesLocked(io, batch);
        {
            var guard = try core.ObjectGuard.lock(io, self.objects.?);
            defer guard.unlock(io);
            guard.assertOwns(device.arena.objectList());
            std.debug.assert(guard.mutex == &self.device_mutex.mutex);
            try device.arena.checkAllocator(&guard, allocator);
            if (self.recording_uses) |*recorded| try recorded.validateGpuRootsLocked(&guard, device);
            prepared = try resources.PendingUses.prepareDeclaredLocked(
                allocator,
                &guard,
                device,
                roots,
            );
            self.deduplicateRecordingUsesLocked(&guard, io, &prepared.?);
        }
        const submitted = try self.queue.submit(io, self.objects.?, options);
        self.commitUsesLocked(io, &prepared, submitted.serial);
        return submitted;
    }

    fn commitUsesLocked(
        self: *NativeDeviceContext,
        io: std.Io,
        prepared: *?resources.PendingUses,
        serial: platform.Serial,
    ) void {
        std.debug.assert(self.pending_uses == null);
        std.debug.assert(self.pending_uses_serial == null);
        std.debug.assert(self.pending_recording_uses == null);
        std.debug.assert(prepared.* != null);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
            defer guard.unlock(io);
            prepared.*.?.markSubmittedLocked(&guard, serial);
            if (self.recording_uses) |*recorded| recorded.markSubmittedLocked(&guard, serial);
        }
        self.pending_uses = prepared.*;
        self.pending_uses_serial = serial;
        self.pending_recording_uses = self.recording_uses;
        self.recording_uses = null;
        prepared.* = null;
        self.gpu_completion_established = false;
    }

    fn releasePreparedUsesLocked(
        self: *NativeDeviceContext,
        io: std.Io,
        batch: *resources.PendingUses,
    ) void {
        var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
        defer guard.unlock(io);
        batch.releaseLocked(&guard, io);
    }

    fn releasePendingUsesLocked(self: *NativeDeviceContext, io: std.Io) void {
        if (self.pending_uses) |*batch| {
            std.debug.assert(self.pending_uses_serial != null);
            self.releasePreparedUsesLocked(io, batch);
            if (self.pending_recording_uses) |*recorded| {
                self.releasePreparedUsesLocked(io, recorded);
                self.pending_recording_uses = null;
            }
            self.pending_uses = null;
            self.pending_uses_serial = null;
        } else {
            std.debug.assert(self.pending_uses_serial == null);
            std.debug.assert(self.pending_recording_uses == null);
        }
    }

    fn releaseRecordingUsesLocked(self: *NativeDeviceContext, io: std.Io) void {
        if (self.recording_uses) |*batch| {
            self.releasePreparedUsesLocked(io, batch);
            self.recording_uses = null;
        }
    }

    /// Waits for one real serial under the queue gate. The caller pins this owner.
    /// Device loss is an error, not successful completion or valid readback.
    pub fn waitSerial(
        self: *NativeDeviceContext,
        io: std.Io,
        serial: platform.Serial,
    ) CleanupError!platform.Serial {
        try self.queue_operation_mutex.lock(io);
        defer self.queue_operation_mutex.unlock(io);
        return self.waitSerialLocked(io, serial);
    }

    /// One bounded real-fence observation. Timeout retains all queue-owned GPU roots.
    /// Caller pins this native owner. No ObjectGuard or high lifecycle lock is held.
    pub fn waitSerialObservation(
        self: *NativeDeviceContext,
        io: std.Io,
        serial: platform.Serial,
        timeout_ns: u64,
    ) CleanupError!platform.Serial {
        try self.queue_operation_mutex.lock(io);
        defer self.queue_operation_mutex.unlock(io);
        if (self.terminal_loss) return error.DeviceLost;
        const completed = self.completedSerial(io);
        // This is a snapshot observation, not a cleanup pass over later work.
        // A later in-flight fence must not extend a target already retired by
        // an actual earlier wait. Its resources remain owned by the queue.
        if (completed >= serial) return completed;
        return self.waitSerialOptionsLocked(io, serial, timeout_ns);
    }

    /// Synchronous mapping composes the real pending generation and real fence wait.
    /// The caller holds a high Device operation pin through return.
    pub fn mapBuffer(
        self: *NativeDeviceContext,
        io: std.Io,
        resource: *resources.Buffer,
        options: buffer.Buffer.MapBeginOptions,
    ) Error!void {
        try self.queue_operation_mutex.lock(io);
        var generation: u64 = undefined;
        var serial: platform.Serial = undefined;
        {
            defer self.queue_operation_mutex.unlock(io);
            var guard = try core.ObjectGuard.lock(io, self.objects.?);
            defer guard.unlock(io);
            try self.checkObjectLocked(&guard, &resource.header);
            if (!self.accepting_operations) return error.NativeDeviceStopped;
            try resource.header.retainLeaseLocked(&guard);
            errdefer resource.header.releaseLeaseLocked(&guard, io);
            serial = resource.accepted_usage_serial;
            var accepted_options = options;
            accepted_options.submitted_usage_serial = serial;
            generation = try resource.native.beginMap(accepted_options);
        }
        defer {
            var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
            defer guard.unlock(io);
            if (resource.header.state == .alive) _ = resource.native.cancelMap(generation);
            resource.header.releaseLeaseLocked(&guard, io);
        }
        const completed = try self.waitSerial(io, serial);
        var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
        defer guard.unlock(io);
        if (resource.header.state != .alive) return error.BufferMapAborted;
        if (try resource.native.completeMap(generation, completed) == .aborted)
            return error.BufferMapAborted;
    }

    fn completedSerial(self: *NativeDeviceContext, io: std.Io) platform.Serial {
        self.queue.timeline.mutex.lockUncancelable(io);
        defer self.queue.timeline.mutex.unlock(io);
        return self.queue.timeline.completed;
    }

    fn waitSerialLocked(
        self: *NativeDeviceContext,
        io: std.Io,
        serial: platform.Serial,
    ) CleanupError!platform.Serial {
        return self.waitSerialOptionsLocked(io, serial, queues.fence_wait_timeout_ns);
    }

    fn waitSerialOptionsLocked(
        self: *NativeDeviceContext,
        io: std.Io,
        serial: platform.Serial,
        timeout_ns: u64,
    ) CleanupError!platform.Serial {
        if (self.terminal_loss) return error.DeviceLost;
        const already_completed = self.completedSerial(io);
        var first: ?CleanupError = null;
        // The no-fence path retries native cleanup without publishing the same serial twice.
        const target_serial = @max(serial, already_completed);
        const completed = queues.Queue.wait(
            io,
            &self.queue,
            self.objects.?,
            .{ .serial = target_serial, .timeout_ns = timeout_ns },
        ) catch |err| blk: {
            if (err == error.DeviceLost) {
                self.markTerminalLossLocked(io);
                return err;
            }
            const published = self.completedSerial(io);
            if (published < target_serial) return err;
            first = err;
            break :blk published;
        };
        if (completed < serial) return error.FenceStatusFailed;
        var released_pending = false;
        if (self.pending_uses_serial) |pending_serial| {
            if (completed >= pending_serial) {
                self.releasePendingUsesLocked(io);
                released_pending = true;
            }
        }
        self.gpu_completion_established = completed >= self.queue.timeline.lastSubmittedSerial();
        if (released_pending) {
            // An abandoned query now owns only its registration lease and can retire.
            var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
            defer guard.unlock(io);
            self.queue.collectQueryPools(&guard, io) catch |err| return first orelse err;
        }
        if (self.gpu_completion_established) self.destroyDeferredFramebuffers();
        if (first) |err| return err;
        return completed;
    }

    /// Settles submitted work for teardown, preserving the first typed failure.
    /// A failed idle without device loss leaves every GPU-referenced owner live.
    pub fn wait(self: *NativeDeviceContext, io: std.Io) CleanupError!void {
        try self.queue_operation_mutex.lock(io);
        defer self.queue_operation_mutex.unlock(io);
        try self.waitLocked(io);
    }

    fn waitLocked(self: *NativeDeviceContext, io: std.Io) CleanupError!void {
        if (self.terminal_loss) return error.DeviceLost;
        const serial = self.queue.timeline.lastSubmittedSerial();
        var first: ?CleanupError = null;
        const completed = self.waitSerialLocked(io, serial) catch |err| blk: {
            first = err;
            break :blk self.completedSerial(io);
        };
        if (self.terminal_loss) return first.?;
        // Retirement can fail after all fences signaled, but before host publication.
        // An empty in-flight list proves those submitted fences already retired.
        self.gpu_completion_established = completed >= serial or
            self.queue.fences_in_flight_count == 0;
        if (!self.gpu_completion_established) {
            const idle = self.native_device.procs.device_wait_idle orelse
                return first orelse error.MissingDeviceProc;
            dispatch.checkVkSuccess(idle(self.native_device.vk_device)) catch |err| {
                if (err == error.DeviceLost) self.markTerminalLossLocked(io);
                return first orelse err;
            };
            self.gpu_completion_established = true;
        }
        self.releasePendingUsesLocked(io);
        self.destroyDeferredFramebuffers();
        if (first) |err| return err;
    }

    fn stopOperationsLocked(self: *NativeDeviceContext, io: std.Io) void {
        self.device_mutex.mutex.lockUncancelable(io);
        self.accepting_operations = false;
        self.device_mutex.mutex.unlock(io);
    }

    fn markTerminalLossLocked(self: *NativeDeviceContext, io: std.Io) void {
        // Vulkan's lost-device rule treats DeviceLost as success only for pending
        // command buffers and resource in-use lifetime, not for work or readback.
        // https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html#devsandqueues-lost-device
        self.terminal_loss = true;
        self.gpu_completion_established = false;
        self.stopOperationsLocked(io);
        self.releasePendingUsesLocked(io);
        self.releaseRecordingUsesLocked(io);
    }

    fn deferFramebuffer(context: *anyopaque, framebuffer: vulkan.VkFramebuffer) void {
        const self: *NativeDeviceContext = @ptrCast(@alignCast(context));
        self.deferred_framebuffers.appendAssumeCapacity(framebuffer);
    }

    fn destroyDeferredFramebuffers(self: *NativeDeviceContext) void {
        const destroy = self.native_device.procs.destroy_framebuffer.?;
        for (self.deferred_framebuffers.items) |handle|
            destroy(self.native_device.vk_device, handle, null);
        self.deferred_framebuffers.clearRetainingCapacity();
    }

    /// Retires payloads but keeps this allocation and its original mutex alive.
    /// Nonterminal failed completion preserves every owner and backing map.
    pub fn retirePayloads(
        self: *NativeDeviceContext,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *core.Device,
    ) CleanupError!void {
        self.queue_operation_mutex.lockUncancelable(io);
        defer self.queue_operation_mutex.unlock(io);
        if (self.native_payloads_retired) return;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
            defer guard.unlock(io);
            guard.assertOwns(device.arena.objectList());
            std.debug.assert(guard.mutex == &self.device_mutex.mutex);
            try device.arena.checkAllocator(&guard, allocator);
            self.takeQueueCleanupErrorLocked(&guard);
            self.accepting_operations = false;
            if (self.native_device.instance.procs.destroy_device == null) {
                self.rememberRetirementError(error.MissingInstanceProc);
                return self.retirement_error.?;
            }
        }
        var wait_error: ?CleanupError = null;
        self.waitLocked(io) catch |err| {
            wait_error = err;
        };
        // waitLocked leaves completion unresolved only when it returns an error.
        if (!self.gpu_completion_established and !self.terminal_loss)
            return self.retirement_error orelse wait_error.?;
        // A refused wait is transient until completion or terminal loss permits teardown.
        if (wait_error) |err| self.rememberRetirementError(err);
        self.releasePendingUsesLocked(io);
        self.releaseRecordingUsesLocked(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, self.objects.?);
            defer guard.unlock(io);
            self.takeQueueCleanupErrorLocked(&guard);
            if (self.kernel_cache) |*cache| cache.releaseRootsLocked(&guard, io);
            // Weak cache hooks must see their original live maps and backend.
            device.retirePayloadsLocked(&guard, io, .early_destroy);
            self.takeQueueCleanupErrorLocked(&guard);
            self.retireQueueResources(&guard, io);
            if (self.queue.query_set_count != 0 or self.queue.query_sets != null or
                self.queue.temporary_buffers.items.len != 0)
            {
                return self.retirement_error orelse error.MissingDeviceProc;
            }
            if (!self.destroyQueue())
                return self.retirement_error orelse error.MissingDeviceProc;
            if (self.pipeline_store) |*store| {
                // A failed driver-cache destroy must not skip independent owners.
                std.debug.assert(store.pipelines.isEmpty(&guard));
                var index = store.pipeline_caches.entries.items.len;
                while (index != 0) {
                    index -= 1;
                    const entry = store.pipeline_caches.entries.items[index];
                    entry.value.destroy() catch |err| {
                        self.rememberRetirementError(err);
                        continue;
                    };
                    const removed = store.pipeline_caches.remove(store.allocator, entry.key);
                    std.debug.assert(removed != null);
                    store.allocator.free(entry.key);
                }
                if (store.pipeline_caches.entries.items.len != 0)
                    return self.retirement_error orelse error.MissingDeviceProc;
                store.pipeline_caches.deinit(store.allocator);
                store.pipelines.deinit(&guard);
                self.pipeline_store = null;
            }
            if (self.resource_store) |*store| {
                store.deinit(&guard);
                self.resource_store = null;
            }
            self.kernel_cache = null;
            self.destroyDeferredFramebuffers();
            self.framebuffer_cache.deinit();
            self.render_pass_cache.deinit(io);
            self.deferred_framebuffers.deinit(self.queue.context.allocator);
            self.deferred_framebuffers = .empty;
            self.caches_live = false;
            self.native_device.deinit(allocator) catch |err|
                self.rememberRetirementError(err);
            self.native_payloads_retired = true;
        }
        if (self.retirement_error) |err| return err;
    }

    fn rememberRetirementError(self: *NativeDeviceContext, err: CleanupError) void {
        if (self.retirement_error == null) self.retirement_error = err;
    }

    fn takeQueueCleanupErrorLocked(
        self: *NativeDeviceContext,
        guard: *const core.ObjectGuard,
    ) void {
        guard.assertOwns(self.objects.?);
        if (self.queue.deferred_cleanup_error) |err| {
            self.rememberRetirementError(err);
            self.queue.deferred_cleanup_error = null;
        }
    }

    fn retireQueueResources(
        self: *NativeDeviceContext,
        guard: *const core.ObjectGuard,
        io: std.Io,
    ) void {
        guard.assertOwns(self.objects.?);
        const procs = self.native_device.procs;
        const handle = self.native_device.vk_device;
        const handles = self.native_device.handles;
        // Native wait errors must not skip the remaining independent owners.
        var current = self.queue.query_sets;
        var visited: usize = 0;
        const count = self.queue.query_set_count;
        while (visited < count) : (visited += 1) {
            const set = current orelse break;
            if (set.header.tracking != self.objects.?) {
                self.rememberRetirementError(error.ResourceDeviceMismatch);
                break;
            }
            guard.assertOwns(set.header.tracking);
            current = set.backend_next;
            if (set.pool) |pool| {
                if (procs.destroy_query_pool) |destroy| {
                    destroy(handle, pool, null);
                    handles.release(.query_pool);
                } else {
                    self.rememberRetirementError(error.MissingDeviceProc);
                    // The registration lease keeps this retired header and pool retryable.
                    continue;
                }
                set.pool = null;
            }
            self.queue.removeQuerySet(guard, io, set);
        }
        var index = self.queue.temporary_buffers.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.queue.temporary_buffers.items[index];
            entry.buffer.destroy(entry.allocator) catch |err| {
                self.rememberRetirementError(err);
                // Partial native cleanup retains its original host owner for retry.
                continue;
            };
            _ = self.queue.temporary_buffers.swapRemove(index);
        }
        if (self.queue.temporary_buffers.items.len == 0) {
            self.queue.temporary_buffers.deinit(self.queue.context.allocator);
            self.queue.temporary_buffers = .empty;
        }
    }

    fn destroyQueue(self: *NativeDeviceContext) bool {
        const procs = self.native_device.procs;
        const handle = self.native_device.vk_device;
        const handles = self.native_device.handles;
        var contexts_retired = true;
        for (self.queue.contexts[0..self.queue.context_count]) |*slot| {
            if (slot.pool == null) continue;
            if (slot.command_buffer != null) {
                if (procs.free_command_buffers) |free| {
                    // Some drivers leak command-buffer memory if the pool is freed first.
                    free(handle, slot.pool, 1, &slot.command_buffer);
                    handles.release(.command_buffer);
                    slot.command_buffer = null;
                } else {
                    self.rememberRetirementError(error.MissingDeviceProc);
                    contexts_retired = false;
                    continue;
                }
            }
            if (procs.destroy_command_pool) |destroy| {
                destroy(handle, slot.pool, null);
                handles.release(.command_pool);
                slot.pool = null;
            } else {
                self.rememberRetirementError(error.MissingDeviceProc);
                contexts_retired = false;
            }
        }
        if (procs.destroy_fence) |destroy| {
            for (self.queue.fences_in_flight[0..self.queue.fences_in_flight_count]) |entry| {
                destroy(handle, entry.fence, null);
                handles.release(.fence);
            }
            for (self.queue.unused_fences[0..self.queue.unused_fence_count]) |fence| {
                destroy(handle, fence, null);
                handles.release(.fence);
            }
            self.queue.fences_in_flight_count = 0;
            self.queue.unused_fence_count = 0;
        } else if (self.queue.fences_in_flight_count != 0 or
            self.queue.unused_fence_count != 0)
        {
            self.rememberRetirementError(error.MissingDeviceProc);
        }
        if (contexts_retired) self.queue.context_count = 0;
        return contexts_retired and self.queue.fences_in_flight_count == 0 and
            self.queue.unused_fence_count == 0;
    }
};
