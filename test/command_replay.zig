const std = @import("std");
const dusk = @import("dusk");
const vk = @import("vulkan");
const command = dusk.command;
const engine = dusk.engine;
const commands = command.commands;
const stream = command.allocator;
const Finished = command.encoding_context.Finished;
const allocator = std.testing.allocator;
const NativeKernelFixture = @import("native_kernel_fixture.zig").NativeKernelFixture;

// Vulkan callbacks have no test context parameter. One fixture owns this target at a time.
var capture_mutex: std.Io.Mutex = .init;
var active_fixture: ?*Fixture = null;

const attachment_format: engine.format.Format = blk: {
    // Match the canonical table proof's bound; even one fixture row builds the full table.
    const format_table_branch_quota = 30_000;
    @setEvalBranchQuota(format_table_branch_quota);
    // SAFETY: buildFormatTable writes every slot before it reads or specializes table entries.
    // The selected format is read only after the complete table build returns.
    var table: engine.format.FormatTable = undefined;
    engine.format.buildFormatTable(.{}, &table);
    break :blk table[engine.format.computeFormatIndex(.rgba8_unorm).?];
};

// These callbacks observe the dispatch boundary. The stream decoder, replay,
// resource trackers and both caches remain the production implementations.
const Capture = struct {
    markers: u32 = 0,
    pushes: u32 = 0,
    pops: u32 = 0,
    begins: u32 = 0,
    ends: u32 = 0,
    render_pass_creates: u32 = 0,
    render_pass_destroys: u32 = 0,
    framebuffer_creates: u32 = 0,
    framebuffer_destroys: u32 = 0,
    last_label: [64]u8 = @splat(0),
    last_label_length: usize = 0,
    viewports: [3]vk.VkViewport,
    viewport_count: usize = 0,
    images_created: u32 = 0,
    images_destroyed: u32 = 0,
    memories_allocated: u32 = 0,
    memories_freed: u32 = 0,
    views_created: u32 = 0,
    views_destroyed: u32 = 0,
    barriers: u32 = 0,
    fail_bind: bool = false,
    fail_view: bool = false,

    fn fromCommand(handle: vk.VkCommandBuffer) *Capture {
        const fixture = active_fixture orelse @panic("capture fixture is not active");
        std.debug.assert(handle == fixture.command_buffer);
        return &fixture.capture;
    }
    fn fromDevice(handle: vk.VkDevice) *Capture {
        const fixture = active_fixture orelse @panic("capture fixture is not active");
        std.debug.assert(handle == fixture.native_fixture.native_device.vk_device);
        return &fixture.capture;
    }
    fn label(self: *Capture, info: [*c]const vk.VkDebugUtilsLabelEXT) void {
        const text = std.mem.span(info[0].pLabelName);
        std.debug.assert(text.len <= self.last_label.len);
        @memcpy(self.last_label[0..text.len], text);
        self.last_label_length = text.len;
    }
    fn marker(handle: vk.VkCommandBuffer, info: [*c]const vk.VkDebugUtilsLabelEXT) callconv(.c) void {
        const self = fromCommand(handle);
        self.markers += 1;
        self.label(info);
    }
    fn push(handle: vk.VkCommandBuffer, info: [*c]const vk.VkDebugUtilsLabelEXT) callconv(.c) void {
        const self = fromCommand(handle);
        self.pushes += 1;
        self.label(info);
    }
    fn pop(handle: vk.VkCommandBuffer) callconv(.c) void {
        fromCommand(handle).pops += 1;
    }
    fn createRenderPass(
        handle: vk.VkDevice,
        info: [*c]const vk.VkRenderPassCreateInfo,
        callbacks: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkRenderPass,
    ) callconv(.c) vk.VkResult {
        const self = fromDevice(handle);
        const result = active_fixture.?.native_fixture.original_procs.create_render_pass.?(
            handle,
            info,
            callbacks,
            output,
        );
        if (result == vk.VK_SUCCESS) self.render_pass_creates += 1;
        return result;
    }
    fn destroyRenderPass(
        handle: vk.VkDevice,
        pass: vk.VkRenderPass,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(handle).render_pass_destroys += 1;
        active_fixture.?.native_fixture.original_procs.destroy_render_pass.?(handle, pass, callbacks);
    }
    fn createFramebuffer(
        handle: vk.VkDevice,
        info: [*c]const vk.VkFramebufferCreateInfo,
        callbacks: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkFramebuffer,
    ) callconv(.c) vk.VkResult {
        const self = fromDevice(handle);
        const result = active_fixture.?.native_fixture.original_procs.create_framebuffer.?(
            handle,
            info,
            callbacks,
            output,
        );
        if (result == vk.VK_SUCCESS) self.framebuffer_creates += 1;
        return result;
    }
    fn destroyFramebuffer(
        handle: vk.VkDevice,
        framebuffer: vk.VkFramebuffer,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(handle).framebuffer_destroys += 1;
        active_fixture.?.native_fixture.original_procs.destroy_framebuffer.?(
            handle,
            framebuffer,
            callbacks,
        );
    }
    fn retireFramebuffer(context: *anyopaque, framebuffer: vk.VkFramebuffer) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        std.debug.assert(self == &active_fixture.?.capture);
        destroyFramebuffer(active_fixture.?.native_fixture.native_device.vk_device, framebuffer, null);
    }
    fn granularity(
        handle: vk.VkDevice,
        pass: vk.VkRenderPass,
        extent: [*c]vk.VkExtent2D,
    ) callconv(.c) void {
        active_fixture.?.native_fixture.original_procs.get_render_area_granularity.?(
            handle,
            pass,
            extent,
        );
    }
    fn begin(
        handle: vk.VkCommandBuffer,
        _: [*c]const vk.VkRenderPassBeginInfo,
        _: vk.VkSubpassContents,
    ) callconv(.c) void {
        fromCommand(handle).begins += 1;
    }
    fn end(handle: vk.VkCommandBuffer) callconv(.c) void {
        fromCommand(handle).ends += 1;
    }
    fn viewport(handle: vk.VkCommandBuffer, first: u32, count: u32, values: [*c]const vk.VkViewport) callconv(.c) void {
        const self = fromCommand(handle);
        std.debug.assert(first == 0);
        std.debug.assert(count == 1);
        if (self.viewport_count < self.viewports.len) {
            self.viewports[self.viewport_count] = values[0];
        }
        self.viewport_count += 1;
    }
    fn scissor(_: vk.VkCommandBuffer, _: u32, _: u32, _: [*c]const vk.VkRect2D) callconv(.c) void {}
    fn blend(_: vk.VkCommandBuffer, _: [*c]const f32) callconv(.c) void {}
    fn stencil(_: vk.VkCommandBuffer, _: vk.VkStencilFaceFlags, _: u32) callconv(.c) void {}
    fn createImage(
        handle: vk.VkDevice,
        info: [*c]const vk.VkImageCreateInfo,
        callbacks: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkImage,
    ) callconv(.c) vk.VkResult {
        const self = fromDevice(handle);
        const result = active_fixture.?.native_fixture.original_procs.create_image.?(
            handle,
            info,
            callbacks,
            output,
        );
        if (result == vk.VK_SUCCESS) self.images_created += 1;
        return result;
    }
    fn destroyImage(
        handle: vk.VkDevice,
        image: vk.VkImage,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(handle).images_destroyed += 1;
        active_fixture.?.native_fixture.original_procs.destroy_image.?(handle, image, callbacks);
    }
    fn imageRequirements(
        handle: vk.VkDevice,
        image: vk.VkImage,
        output: [*c]vk.VkMemoryRequirements,
    ) callconv(.c) void {
        active_fixture.?.native_fixture.original_procs.get_image_memory_requirements.?(
            handle,
            image,
            output,
        );
    }
    fn allocateMemory(
        handle: vk.VkDevice,
        info: [*c]const vk.VkMemoryAllocateInfo,
        callbacks: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkDeviceMemory,
    ) callconv(.c) vk.VkResult {
        const self = fromDevice(handle);
        const result = active_fixture.?.native_fixture.original_procs.allocate_memory.?(
            handle,
            info,
            callbacks,
            output,
        );
        if (result == vk.VK_SUCCESS) self.memories_allocated += 1;
        return result;
    }
    fn freeMemory(
        handle: vk.VkDevice,
        memory: vk.VkDeviceMemory,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(handle).memories_freed += 1;
        active_fixture.?.native_fixture.original_procs.free_memory.?(handle, memory, callbacks);
    }
    fn bindImageMemory(
        handle: vk.VkDevice,
        image: vk.VkImage,
        memory: vk.VkDeviceMemory,
        offset: vk.VkDeviceSize,
    ) callconv(.c) vk.VkResult {
        if (fromDevice(handle).fail_bind) return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        return active_fixture.?.native_fixture.original_procs.bind_image_memory.?(
            handle,
            image,
            memory,
            offset,
        );
    }
    fn createImageView(
        handle: vk.VkDevice,
        info: [*c]const vk.VkImageViewCreateInfo,
        callbacks: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkImageView,
    ) callconv(.c) vk.VkResult {
        const self = fromDevice(handle);
        if (self.fail_view) return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        const result = active_fixture.?.native_fixture.original_procs.create_image_view.?(
            handle,
            info,
            callbacks,
            output,
        );
        if (result == vk.VK_SUCCESS) self.views_created += 1;
        return result;
    }
    fn destroyImageView(
        handle: vk.VkDevice,
        view: vk.VkImageView,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(handle).views_destroyed += 1;
        active_fixture.?.native_fixture.original_procs.destroy_image_view.?(handle, view, callbacks);
    }
    fn barrier(
        handle: vk.VkCommandBuffer,
        _: vk.VkPipelineStageFlags,
        _: vk.VkPipelineStageFlags,
        _: vk.VkDependencyFlags,
        _: u32,
        _: [*c]const vk.VkMemoryBarrier,
        _: u32,
        _: [*c]const vk.VkBufferMemoryBarrier,
        count: u32,
        _: [*c]const vk.VkImageMemoryBarrier,
    ) callconv(.c) void {
        fromCommand(handle).barriers += count;
    }
};

fn unexpectedCoreError(
    callback_allocator: std.mem.Allocator,
    _: std.Io,
    _: *anyopaque,
    data: dusk.core.ErrorView,
) void {
    std.debug.assert(callback_allocator.vtable == allocator.vtable);
    std.debug.panic("command replay fixture reported an uncaptured core error: {s}", .{data.message});
}

const Fixture = struct {
    capture: Capture,
    procs: *dusk.vk.dispatch.DeviceProcs = undefined,
    instance_procs: dusk.vk.dispatch.InstanceProcs = std.mem.zeroes(dusk.vk.dispatch.InstanceProcs),
    handles: engine.queue.HandleSet = .{},
    mutex: dusk.platform.DeviceMutex = .{},
    queue_operation_mutex: std.Io.Mutex = .init,
    queue: *engine.queue.Queue,
    // SAFETY: init assigns native ownership at this final address before any callback.
    native_fixture: NativeKernelFixture = undefined,
    command_buffer: vk.VkCommandBuffer = null,
    recording: engine.recording_context.CommandRecordingContext,
    passes: engine.render_pass_cache.RenderPassCache,
    frames: engine.framebuffer_cache.FramebufferCache,
    core_device: dusk.core.Device,
    texture: *engine.texture.Texture,
    view: *engine.texture.TextureView,
    texture_alias: ?dusk.core.Handle = null,
    view_alias: ?dusk.core.Handle = null,
    attachment: ?*command.attachment_state.CanonicalAttachmentState = null,
    const max_immediate_size: u32 = command.constants.max_immediate_data_bytes;
    const Teardown = struct {
        capture: Capture,
        handles: engine.queue.HandleSet,
    };

    // SAFETY: Callers construct this fixture at its final address.
    // Native initialization handles its own rollback. Later failures use deinit
    // after recording, caches, and empty alias optionals are ready.
    fn init(self: *Fixture, rollback: ?*Teardown) !void {
        capture_mutex.lockUncancelable(std.testing.io);
        std.debug.assert(active_fixture == null);
        self.core_device = dusk.core.Device.init(allocator, .{
            .object_mutex = &self.mutex.mutex,
            .uncaptured_context = &self.capture,
            .uncaptured_callback = unexpectedCoreError,
        });
        self.native_fixture.init(allocator, std.testing.io, &self.core_device, &self.mutex) catch |err| {
            var guard = dusk.core.ObjectGuard.lockUncancelable(
                std.testing.io,
                self.core_device.borrow().objectList(),
            );
            self.core_device.deinit(allocator, &guard) catch @panic("native fixture rollback failed");
            guard.unlock(std.testing.io);
            capture_mutex.unlock(std.testing.io);
            return err;
        };
        self.procs = self.native_fixture.native_device.procs;
        self.queue = &self.native_fixture.queue;
        self.command_buffer = self.queue.commandBuffer();
        active_fixture = self;
        self.instance_procs = self.native_fixture.native_device.instance.procs.*;
        self.instance_procs.cmd_insert_debug_utils_label_ext = Capture.marker;
        self.instance_procs.cmd_begin_debug_utils_label_ext = Capture.push;
        self.instance_procs.cmd_end_debug_utils_label_ext = Capture.pop;
        self.procs.create_render_pass = Capture.createRenderPass;
        self.procs.destroy_render_pass = Capture.destroyRenderPass;
        self.procs.create_framebuffer = Capture.createFramebuffer;
        self.procs.destroy_framebuffer = Capture.destroyFramebuffer;
        self.procs.get_render_area_granularity = Capture.granularity;
        self.procs.cmd_begin_render_pass = Capture.begin;
        self.procs.cmd_end_render_pass = Capture.end;
        self.procs.cmd_set_viewport = Capture.viewport;
        self.procs.cmd_set_scissor = Capture.scissor;
        self.procs.cmd_set_blend_constants = Capture.blend;
        self.procs.cmd_set_stencil_reference = Capture.stencil;
        self.procs.create_image = Capture.createImage;
        self.procs.destroy_image = Capture.destroyImage;
        self.procs.get_image_memory_requirements = Capture.imageRequirements;
        self.procs.allocate_memory = Capture.allocateMemory;
        self.procs.free_memory = Capture.freeMemory;
        self.procs.bind_image_memory = Capture.bindImageMemory;
        self.procs.create_image_view = Capture.createImageView;
        self.procs.destroy_image_view = Capture.destroyImageView;
        self.procs.cmd_pipeline_barrier = Capture.barrier;
        const device = self.native_fixture.native_device.vk_device;
        self.queue.context.dispatch.instance = &self.instance_procs;
        self.native_fixture.refreshPipelineBackend();
        self.recording = engine.recording_context.CommandRecordingContext.init(allocator);
        self.passes = engine.render_pass_cache.RenderPassCache.init(.{
            .allocator = allocator,
            .device = .{ .procs = self.procs, .vk_device = device },
        });
        self.frames = engine.framebuffer_cache.FramebufferCache.init(.{
            .allocator = allocator,
            .device = .{ .procs = self.procs, .vk_device = device },
            .destroy_context = &self.capture,
            .destroy_when_unused = Capture.retireFramebuffer,
        });
        errdefer {
            const observations = self.deinit();
            if (rollback) |output| output.* = observations;
        }
        var guard = dusk.core.ObjectGuard.lockUncancelable(std.testing.io, self.core_device.borrow().objectList());
        defer guard.unlock(std.testing.io);
        const texture_handle = try engine.texture.Texture.create(allocator, std.testing.io, &guard, &self.core_device, .{
            .descriptor = .{
                .usage = .{ .render_attachment = true },
                .size = .{ .width = 4, .height = 4 },
                .format = .rgba8_unorm,
            },
            .format_info = &attachment_format,
            .limits = .{
                .max_texture_dimension_1d = 4,
                .max_texture_dimension_2d = 4,
                .max_texture_dimension_3d = 4,
                .max_texture_array_layers = 1,
            },
        });
        self.texture_alias = .{ .ptr = @ptrCast(@alignCast(texture_handle.handle.?)), .kind = .texture };
        self.texture = try engine.texture.resolveTexture(&self.core_device, &guard, texture_handle);
        try self.texture.initializeNative(allocator, &guard, .{
            .allocator = allocator,
            .dispatch = self.queue.context.dispatch,
            .vk_device = device,
            .memory_properties = self.native_fixture.native_device.memoryProperties(),
            .non_coherent_atom_size = self.native_fixture.native_device.physical.properties.limits.nonCoherentAtomSize,
            .max_buffer_size = self.native_fixture.native_device.maxBufferSize(),
            .handles = &self.handles,
        });
        const view_handle = try engine.texture.Texture.createView(allocator, std.testing.io, &guard, &self.core_device, texture_handle, .{
            .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
            .format_info = &attachment_format,
        });
        self.view_alias = .{ .ptr = @ptrCast(@alignCast(view_handle.handle.?)), .kind = .texture_view };
        self.view = try engine.texture.resolveTextureView(&self.core_device, &guard, view_handle);
        try self.view.initializeNative(&guard);
        const value = try command.attachment_state.AttachmentState.fromRenderPass(.{
            .colors = &.{.{
                .view = .{
                    .format = @backingInt(self.view.format),
                    .sample_count = self.view.texture.sample_count,
                    .aspects = if (self.view.aspects.color != 0) 1 else 0,
                },
                .resolve_target = null,
                .expands_resolve = false,
            }},
            .depth_stencil = null,
            .pls = null,
        }, .{
            .max_color_attachments = command.constants.max_color_attachments,
            .max_storage_attachments = command.constants.max_pls_slots,
            .max_pls_bytes = command.constants.max_pls_size,
        });
        const attachment = try self.core_device.arena.create(
            allocator,
            &guard,
            command.attachment_state.CanonicalAttachmentState,
            .{ .kind = .attachment_state, .initial_reference = .user },
        );
        attachment.value = value;
        attachment.cache_hash = 0;
        attachment.cache_next = null;
        attachment.header.attach(&guard, std.testing.io);
        self.attachment = attachment;
    }
    fn deinit(self: *Fixture) Teardown {
        self.recording.deinit();
        self.frames.deinit();
        self.passes.deinit(std.testing.io);
        var guard = dusk.core.ObjectGuard.lockUncancelable(std.testing.io, self.core_device.borrow().objectList());
        self.native_fixture.releaseCacheRootsLocked(&guard, std.testing.io);
        if (self.view_alias) |target| {
            const header = self.core_device.resolveReference(&guard, target) catch @panic("view alias lost");
            header.releaseUserLocked(&guard, std.testing.io) catch @panic("view alias release failed");
        }
        if (self.texture_alias) |target| {
            const header = self.core_device.resolveReference(&guard, target) catch @panic("texture alias lost");
            header.releaseUserLocked(&guard, std.testing.io) catch @panic("texture alias release failed");
        }
        if (self.attachment) |attachment| {
            attachment.header.releaseUserLocked(&guard, std.testing.io) catch
                @panic("attachment alias release failed");
        }
        self.core_device.borrow().objectList().retirePayloadsLocked(
            &guard,
            std.testing.io,
            .early_destroy,
        );
        self.native_fixture.deinitStoresLocked(&guard) catch @panic("fixture stores leaked");
        guard.unlock(std.testing.io);
        // Negative admission tests mutate these borrowed slots, not native ownership.
        self.queue.context.dispatch = self.native_fixture.native_device.dispatchTable();
        self.queue.contexts[0].command_buffer = self.command_buffer;
        self.native_fixture.deinitNative(
            allocator,
            std.testing.io,
            self.core_device.borrow().objectList(),
        ) catch @panic("fixture native teardown failed");
        guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        self.core_device.deinit(allocator, &guard) catch @panic("fixture alias leaked");
        guard.unlock(std.testing.io);
        active_fixture = null;
        capture_mutex.unlock(std.testing.io);
        // Return actual cleanup observations without keeping a live owner.
        const observations: Teardown = .{ .capture = self.capture, .handles = self.handles };
        // SAFETY: Cleanup and observation capture finish before this final poison write.
        // Neither success nor rollback callers read the fixture after deinit.
        self.* = undefined;
        return observations;
    }
    fn replay(self: *Fixture, finished: *const Finished) engine.command_buffer.ReplayError!void {
        self.queue_operation_mutex.lockUncancelable(std.testing.io);
        defer self.queue_operation_mutex.unlock(std.testing.io);
        var guard = dusk.core.ObjectGuard.lockUncancelable(std.testing.io, self.core_device.borrow().objectList());
        defer guard.unlock(std.testing.io);
        var pending = try engine.native_resources.PendingUses.prepareDeclaredLocked(
            allocator,
            &guard,
            &self.core_device,
            &.{},
        );
        defer pending.releaseLocked(&guard, std.testing.io);
        return engine.command_buffer.recordCommands(allocator, .{
            .io = std.testing.io,
            .guard = &guard,
            .core_device = &self.core_device,
            .max_immediate_size = max_immediate_size,
            .queue = self.queue,
            .recording = &self.recording,
            .render_pass_cache = &self.passes,
            .framebuffer_cache = &self.frames,
            .kernels = &self.native_fixture.kernels,
            .pending_uses = &pending,
            .timestamp_quantization = self.native_fixture.timestamp_quantization,
        }, finished);
    }
    fn renderBegin(self: *Fixture) commands.BeginRenderPassCmd {
        var begin: commands.BeginRenderPassCmd = .{
            .attachment_state = self.attachment.?,
            .width = 4,
            .height = 4,
            .render_area = .{ .width = 4, .height = 4 },
        };
        begin.color_attachments[0] = .{ .view = self.view, .load_op = .clear, .store_op = .store };
        return begin;
    }
    fn deinitFinished(self: *Fixture, finished: *Finished) void {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        finished.deinit(allocator, std.testing.io, &guard);
    }
    fn deinitEncoder(self: *Fixture, encoder: *command.command_encoder.CommandEncoder) void {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        encoder.deinit(allocator, std.testing.io, &guard);
    }
    fn initBundleEncoder(self: *Fixture) !command.render_bundle.RenderBundleEncoder {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        return command.render_bundle.RenderBundleEncoder.init(
            allocator,
            std.testing.io,
            &guard,
            &self.core_device,
            self.attachment.?,
            .{},
        );
    }
    fn deinitBundleEncoder(
        self: *Fixture,
        encoder: *command.render_bundle.RenderBundleEncoder,
    ) void {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        encoder.deinit(std.testing.io, &guard);
    }
    fn finishBundle(
        self: *Fixture,
        encoder: *command.render_bundle.RenderBundleEncoder,
    ) !*command.render_bundle.RenderBundle {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        return encoder.finish(std.testing.io, &guard);
    }
    fn bundleRef(self: *Fixture, bundle: *command.render_bundle.RenderBundle) !commands.Ref {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        return bundle.ref(&guard);
    }
    fn releaseBundle(self: *Fixture, bundle: *command.render_bundle.RenderBundle) void {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        bundle.header.releaseUserLocked(&guard, std.testing.io) catch
            @panic("bundle alias release failed");
    }
};

fn emit(comptime tag: commands.Tag, arena: *stream.Allocator, value: commands.Payload(tag)) !void {
    (try arena.allocateCommand(commands.Payload(tag), @backingInt(tag))).* = value;
}
fn bytes(arena: *stream.Allocator, value: []const u8) !void {
    @memcpy(try arena.allocateData(u8, value.len), value);
}
fn finishRaw(arena: *stream.Allocator, device: dusk.core.CoreDeviceBorrow) Finished {
    return .{
        .device = device,
        .blocks = arena.acquireBlocks(),
        .render_pass_usages = .empty,
        .compute_pass_usages = .empty,
        .indirect_draws = .empty,
        .status = .finished,
    };
}
fn computeMetadata(finished: *Finished) !void {
    try finished.compute_pass_usages.append(allocator, command.usage.ComputePassResourceUsage.init(allocator));
}
fn renderUsage(fixture: *Fixture, finished: *Finished) !void {
    var guard = dusk.core.ObjectGuard.lockUncancelable(
        std.testing.io,
        fixture.core_device.borrow().objectList(),
    );
    defer guard.unlock(std.testing.io);
    var usage = command.usage.RenderPassResourceUsage.init(allocator);
    errdefer usage.deinit(std.testing.io, &guard);
    try usage.retainAttachmentLocked(&guard, fixture.attachment.?);
    try finished.render_pass_usages.append(allocator, usage);
}
fn renderMetadata(fixture: *Fixture, finished: *Finished) !void {
    try renderUsage(fixture, finished);
    try finished.indirect_draws.append(
        allocator,
        command.indirect_draw.IndirectDrawMetadata.init(allocator),
    );
}
fn expectBorrowed(finished: *const Finished, before: Finished) !void {
    try std.testing.expectEqual(before.status, finished.status);
    try std.testing.expectEqual(before.device.objects, finished.device.objects);
    inline for (.{ "blocks", "render_pass_usages", "compute_pass_usages", "indirect_draws" }) |field| {
        const original = @field(before, field);
        const current = @field(finished.*, field);
        try std.testing.expectEqual(@intFromPtr(original.items.ptr), @intFromPtr(current.items.ptr));
        try std.testing.expectEqual(original.items.len, current.items.len);
        try std.testing.expectEqual(original.capacity, current.capacity);
    }
}
fn expectFailure(fixture: *Fixture, finished: *Finished, expected: engine.command_buffer.ReplayError) !void {
    const before = finished.*;
    try std.testing.expectError(expected, fixture.replay(finished));
    try std.testing.expect(fixture.queue.recording_poisoned);
    try expectBorrowed(finished, before);
}

test "render attachment fixture rolls back native storage when binding or view creation fails" {
    for ([_]bool{ false, true }) |fail_view| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        fixture.capture.fail_bind = !fail_view;
        fixture.capture.fail_view = fail_view;
        // SAFETY: Both injected failures run init's errdefer, which writes observations before reads.
        var observations: Fixture.Teardown = undefined;
        try std.testing.expectError(error.OutOfDeviceMemory, fixture.init(&observations));
        try std.testing.expect(observations.handles.isEmpty());
        try std.testing.expectEqual(
            observations.capture.images_created,
            observations.capture.images_destroyed,
        );
        try std.testing.expectEqual(
            observations.capture.memories_allocated,
            observations.capture.memories_freed,
        );
        try std.testing.expectEqual(
            observations.capture.views_created,
            observations.capture.views_destroyed,
        );
    }
}

test "render attachment fixture owns initialized native storage through replay and teardown" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    var live = true;
    defer {
        if (live) _ = fixture.deinit();
    }
    {
        var guard = dusk.core.ObjectGuard.lockUncancelable(std.testing.io, fixture.core_device.borrow().objectList());
        defer guard.unlock(std.testing.io);
        try std.testing.expect(fixture.texture.header.isAlive(&guard));
        try std.testing.expect(fixture.texture.native != null);
        try std.testing.expectEqual(@as(usize, 1), fixture.texture.native.?.states.len);
        try std.testing.expect(fixture.view.native_view != null);
    }
    var arena = try stream.Allocator.init(allocator, 1024);
    defer arena.deinit();
    try emit(.begin_render_pass, &arena, fixture.renderBegin());
    try emit(.end_render_pass, &arena, .{});
    var finished = finishRaw(&arena, fixture.core_device.borrow());
    var finished_live = true;
    defer if (finished_live) fixture.deinitFinished(&finished);
    try renderMetadata(&fixture, &finished);
    const before_replay = finished;
    try fixture.replay(&finished);
    try expectBorrowed(&finished, before_replay);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.begins);
    try std.testing.expect(fixture.capture.barriers != 0);
    fixture.deinitFinished(&finished);
    finished_live = false;
    const observations = fixture.deinit();
    live = false;
    try std.testing.expect(observations.handles.isEmpty());
    try std.testing.expectEqual(
        observations.capture.images_created,
        observations.capture.images_destroyed,
    );
    try std.testing.expectEqual(
        observations.capture.memories_allocated,
        observations.capture.memories_freed,
    );
    try std.testing.expectEqual(
        observations.capture.views_created,
        observations.capture.views_destroyed,
    );
    try std.testing.expectEqual(
        observations.capture.render_pass_creates,
        observations.capture.render_pass_destroys,
    );
    try std.testing.expectEqual(
        observations.capture.framebuffer_creates,
        observations.capture.framebuffer_destroys,
    );
}

test "replay rejects malformed command slots without consuming ownership" {
    for ([_]usize{ 0, 1, 3, 4, 7, 8 }) |length| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        if (length == 0) {
            _ = try arena.allocate(0x12345678, 0);
        } else {
            try emit(.insert_debug_marker, &arena, .{ .length = 2 });
        }
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        if (length != 0) finished.blocks.items[0].len = length;
        try expectFailure(
            &fixture,
            &finished,
            if (length == 0) error.InvalidCommandTag else error.CommandStreamTruncated,
        );
    }
}

test "replay rejects missing wrong and short additional runs before issuing a marker" {
    for (0..3) |kind| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        try emit(.insert_debug_marker, &arena, .{ .length = 17 });
        switch (kind) {
            0 => {},
            1 => try emit(.pop_debug_group, &arena, .{}),
            2 => try bytes(&arena, "short\x00"),
            else => unreachable,
        }
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        try expectFailure(&fixture, &finished, error.CommandStreamTruncated);
        try std.testing.expectEqual(@as(u32, 0), fixture.capture.markers);
    }
}

test "replay rejects malformed label terminators and embedded nulls" {
    for ([_][]const u8{ "bad", "a\x00b\x00" }) |text| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        try emit(.push_debug_group, &arena, .{ .length = @intCast(text.len) });
        try bytes(&arena, text);
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        try expectFailure(&fixture, &finished, error.InvalidLabel);
        try std.testing.expectEqual(@as(u32, 0), fixture.capture.pushes);
    }
}

test "replay refuses wrong contexts and missing compute and render pass ends" {
    for (0..5) |kind| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        switch (kind) {
            0 => try emit(.draw, &arena, .{}),
            1, 2 => {
                try emit(.begin_compute_pass, &arena, .{});
                if (kind == 1) try emit(.end_render_pass, &arena, .{});
            },
            3, 4 => {
                try emit(.begin_render_pass, &arena, fixture.renderBegin());
                if (kind == 3) try emit(.end_compute_pass, &arena, .{});
            },
            else => unreachable,
        }
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        if (kind == 1 or kind == 2) try computeMetadata(&finished);
        if (kind == 3 or kind == 4) try renderMetadata(&fixture, &finished);
        try expectFailure(
            &fixture,
            &finished,
            if (kind == 2 or kind == 4) error.MissingPassEnd else error.InvalidCommandContext,
        );
        try std.testing.expectEqual(@as(u32, 0), fixture.capture.ends);
    }
}

test "replay rejects missing and surplus pass and indirect metadata" {
    for (0..6) |kind| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        if (kind == 0) try emit(.begin_compute_pass, &arena, .{});
        if (kind == 1 or kind == 2) try emit(.begin_render_pass, &arena, fixture.renderBegin());
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        switch (kind) {
            0, 1 => {},
            2, 4 => try renderUsage(&fixture, &finished),
            3 => try computeMetadata(&finished),
            5 => try finished.indirect_draws.append(
                allocator,
                command.indirect_draw.IndirectDrawMetadata.init(allocator),
            ),
            else => unreachable,
        }
        try expectFailure(&fixture, &finished, error.PassMetadataMismatch);
        try std.testing.expectEqual(@as(u32, 0), fixture.capture.begins);
    }
}

test "replay rejects missing and surplus dispatch scopes before dispatching" {
    for ([_]bool{ false, true }) |surplus| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        try emit(.begin_compute_pass, &arena, .{});
        if (!surplus) try emit(.dispatch, &arena, .{});
        try emit(.end_compute_pass, &arena, .{});
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        try computeMetadata(&finished);
        if (surplus) try finished.compute_pass_usages.items[0].dispatch_usages.append(
            allocator,
            command.usage.SyncScopeResourceUsage.init(allocator),
        );
        try expectFailure(&fixture, &finished, error.DispatchMetadataMismatch);
    }
}

test "frontend debug labels zero dynamic offsets immediates and empty writes replay in order" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    var encoder = command.command_encoder.CommandEncoder.init(allocator, fixture.core_device.borrow(), .{});
    defer fixture.deinitEncoder(&encoder);
    try encoder.pushDebugGroup("top");
    try encoder.insertDebugMarker("before");
    try encoder.writeBuffer(.{ .buffer = null, .data = &.{} });
    var pass = try encoder.beginComputePass(.{ .label = "compute" });
    defer pass.deinit();
    try pass.setBindGroup(.{ .index = 0, .group = null });
    try pass.setImmediates(.{ .offset = 0, .data = &.{} });
    try pass.setImmediates(.{ .offset = 0, .data = &.{ 1, 2, 3, 4 } });
    try pass.insertDebugMarker("compute marker");
    try pass.end();
    try encoder.popDebugGroup();
    var finished = try encoder.finish();
    defer fixture.deinitFinished(&finished);
    const before_replay = finished;
    try fixture.replay(&finished);
    try std.testing.expect(!fixture.queue.recording_poisoned);
    try std.testing.expect(fixture.recording.needs_submit);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.pushes);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.pops);
    try std.testing.expectEqual(@as(u32, 2), fixture.capture.markers);
    try std.testing.expectEqualStrings(
        "compute marker",
        fixture.capture.last_label[0..fixture.capture.last_label_length],
    );
    try expectBorrowed(&finished, before_replay);
}

test "replay decodes nonzero offset runs and preserves the following command" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    const group = created: {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            fixture.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        const resources = engine.native_resources;
        const device = fixture.native_fixture.resourceDevice();
        const arena = &fixture.core_device.arena;
        const buffer = try resources.createBuffer(allocator, std.testing.io, &guard, arena, device, .{
            .size = 1024,
            .usage = .{ .uniform = true },
        });
        defer buffer.header.releaseUserLocked(&guard, std.testing.io) catch
            @panic("offset buffer release failed");
        const group_layout = try resources.createBindGroupLayout(
            allocator,
            std.testing.io,
            &guard,
            arena,
            device,
            .{
                .descriptor = .{ .entries = &.{.{
                    .binding_number = 0,
                    .visibility = .{ .compute = true },
                    .kind = .{ .buffer = .{
                        .binding_type = .uniform,
                        .has_dynamic_offset = true,
                        .min_binding_size = 256,
                    } },
                }} },
                .validation = .{
                    .max_storage_buffers_in_vertex_stage = 0,
                    .max_storage_buffers_in_fragment_stage = 0,
                },
            },
        );
        defer group_layout.header.releaseUserLocked(&guard, std.testing.io) catch
            @panic("offset group layout release failed");
        const layout = try resources.createPipelineLayout(allocator, std.testing.io, &guard, arena, device, .{
            .groups = &.{group_layout},
        });
        defer layout.header.releaseUserLocked(&guard, std.testing.io) catch
            @panic("offset pipeline layout release failed");
        break :created try resources.createBindGroup(allocator, std.testing.io, &guard, arena, device, .{
            .layout = layout,
            .group_index = 0,
            .bindings = &.{.{ .buffer = .{
                .binding = 0,
                .buffer = buffer,
                .offset = 0,
                .size = 256,
                .kind = .uniform,
                .dynamic = true,
                .alignment = 256,
                .stages = .{ .compute = true },
            } }},
        });
    };
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            fixture.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        group.header.releaseUserLocked(&guard, std.testing.io) catch
            @panic("offset group release failed");
    }
    const group_ref = reference: {
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            fixture.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        break :reference try group.ref(&guard);
    };
    var encoder = command.command_encoder.CommandEncoder.init(allocator, fixture.core_device.borrow(), .{});
    defer fixture.deinitEncoder(&encoder);
    var pass = try encoder.beginComputePass(.{});
    defer pass.deinit();
    try pass.setBindGroup(.{ .index = 0, .group = group_ref, .dynamic_offset_count = 1, .dynamic_offsets = &.{256} });
    try pass.insertDebugMarker("after offsets");
    try pass.end();
    var finished = try encoder.finish();
    defer fixture.deinitFinished(&finished);
    const before_replay = finished;
    try fixture.replay(&finished);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.markers);
    try std.testing.expectEqualStrings(
        "after offsets",
        fixture.capture.last_label[0..fixture.capture.last_label_length],
    );
    try expectBorrowed(&finished, before_replay);
}

test "replay borrows bundle runs across repeated execution and never frees bundle storage" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    var bundle_encoder = try fixture.initBundleEncoder();
    defer fixture.deinitBundleEncoder(&bundle_encoder);
    try bundle_encoder.pushDebugGroup("bundle");
    try bundle_encoder.setBindGroup(.{ .index = 0, .group = null });
    try bundle_encoder.setImmediates(.{ .offset = 0, .data = &.{ 5, 6, 7, 8 } });
    try bundle_encoder.insertDebugMarker("bundle marker");
    try bundle_encoder.popDebugGroup();
    const bundle = try fixture.finishBundle(&bundle_encoder);
    defer fixture.releaseBundle(bundle);
    fixture.deinitBundleEncoder(&bundle_encoder);
    for (0..2) |_| {
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        try emit(.begin_render_pass, &arena, fixture.renderBegin());
        try emit(.execute_bundles, &arena, .{ .count = 0 });
        _ = try arena.allocateData(commands.Ref, 0);
        try emit(.execute_bundles, &arena, .{ .count = 1 });
        (try arena.allocateData(commands.Ref, 1))[0] = try fixture.bundleRef(bundle);
        try emit(.end_render_pass, &arena, .{});
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        try renderMetadata(&fixture, &finished);
        const before_replay = finished;
        try fixture.replay(&finished);
        try expectBorrowed(&finished, before_replay);
        var guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            fixture.core_device.borrow().objectList(),
        );
        defer guard.unlock(std.testing.io);
        try std.testing.expect(bundle.header.isAlive(&guard));
        var borrowed = bundle.iterator(&guard);
        defer borrowed.deinit();
        try std.testing.expectEqual(commands.Tag.push_debug_group, (try borrowed.nextTag()).?);
    }
    try std.testing.expectEqual(@as(u32, 2), fixture.capture.markers);
    try std.testing.expectEqual(@as(u32, 2), fixture.capture.begins);
    try std.testing.expectEqual(@as(u32, 2), fixture.capture.ends);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.render_pass_creates);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.framebuffer_creates);
}
test "render replay dispatches flipped default explicit and zero-width viewports" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    var arena = try stream.Allocator.init(allocator, 1024);
    defer arena.deinit();
    try emit(.begin_render_pass, &arena, fixture.renderBegin());
    try emit(.set_viewport, &arena, .{
        .x = 3,
        .y = 5,
        .width = 7,
        .height = 9,
        .min_depth = 0.25,
        .max_depth = 0.75,
    });
    try emit(.set_viewport, &arena, .{
        .x = 3,
        .y = 5,
        .width = 0,
        .height = 9,
        .min_depth = 0,
        .max_depth = 1,
    });
    try emit(.end_render_pass, &arena, .{});
    var finished = finishRaw(&arena, fixture.core_device.borrow());
    defer fixture.deinitFinished(&finished);
    try renderMetadata(&fixture, &finished);
    const before_replay = finished;
    try fixture.replay(&finished);
    try std.testing.expectEqual(@as(usize, 3), fixture.capture.viewport_count);
    const expected = [_]vk.VkViewport{
        .{ .x = 0, .y = 4, .width = 4, .height = -4, .minDepth = 0, .maxDepth = 1 },
        .{ .x = 3, .y = 14, .width = 7, .height = -9, .minDepth = 0.25, .maxDepth = 0.75 },
        .{ .x = 0, .y = 14, .width = 1, .height = 0, .minDepth = 0, .maxDepth = 1 },
    };
    // SAFETY: The successful count check proves all three array entries were written before reads.
    for (expected, fixture.capture.viewports) |want, actual| {
        try std.testing.expectEqual(want.x, actual.x);
        try std.testing.expectEqual(want.y, actual.y);
        try std.testing.expectEqual(want.width, actual.width);
        try std.testing.expectEqual(want.height, actual.height);
        try std.testing.expectEqual(want.minDepth, actual.minDepth);
        try std.testing.expectEqual(want.maxDepth, actual.maxDepth);
    }
    try expectBorrowed(&finished, before_replay);
}

test "write byte run is decoded before resource validation and malformed runs poison recording" {
    for ([_]bool{ false, true }) |truncated| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        try emit(.write_buffer, &arena, .{ .size = 4 });
        if (!truncated) try bytes(&arena, &.{ 1, 2, 3, 4 });
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        try expectFailure(&fixture, &finished, if (truncated) error.CommandStreamTruncated else error.InvalidCopy);
    }
}

test "invalid finished status and absent dispatch tier preserve owned allocations" {
    for ([_]bool{ false, true }) |absent_tier| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        try emit(.insert_debug_marker, &arena, .{ .length = 6 });
        try bytes(&arena, "owned\x00");
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        try computeMetadata(&finished);
        try renderMetadata(&fixture, &finished);
        if (absent_tier) fixture.queue.context.dispatch.device = null else finished.status = .error_in_recording;
        try expectFailure(
            &fixture,
            &finished,
            if (absent_tier) error.DeviceProcTierMissing else error.InvalidFinishedStatus,
        );
    }
}

test "each of the six trailing run forms refuses missing wrong and truncated framing" {
    inline for ([_]commands.Tag{
        .insert_debug_marker, .push_debug_group, .set_bind_group,
        .set_immediates,      .execute_bundles,  .write_buffer,
    }) |tag| {
        for (0..3) |kind| {
            // SAFETY: Init writes owned fields before use at this stable stack address.
            // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
            var fixture: Fixture = .{
                .capture = .{ .viewports = undefined },
                .queue = undefined,
                .recording = undefined,
                .passes = undefined,
                .frames = undefined,
                .core_device = undefined,
                .texture = undefined,
                .view = undefined,
            };
            try fixture.init(null);
            defer _ = fixture.deinit();
            var arena = try stream.Allocator.init(allocator, 1024);
            defer arena.deinit();
            const compute = tag == .set_bind_group or tag == .set_immediates;
            const render = tag == .execute_bundles;
            if (compute) try emit(.begin_compute_pass, &arena, .{});
            if (render) try emit(.begin_render_pass, &arena, fixture.renderBegin());
            switch (tag) {
                .insert_debug_marker, .push_debug_group => try emit(tag, &arena, .{ .length = 17 }),
                .set_bind_group => try emit(tag, &arena, .{ .dynamic_offset_count = 5 }),
                .set_immediates, .write_buffer => try emit(tag, &arena, .{ .size = 20 }),
                .execute_bundles => try emit(tag, &arena, .{ .count = 3 }),
                else => unreachable,
            }
            switch (kind) {
                0 => {},
                1 => try emit(.pop_debug_group, &arena, .{}),
                2 => {
                    const element = commands.DataElement(tag);
                    const data = try arena.allocateData(element, 1);
                    data[0] = std.mem.zeroes(element);
                },
                else => unreachable,
            }
            var finished = finishRaw(&arena, fixture.core_device.borrow());
            defer fixture.deinitFinished(&finished);
            if (compute) try computeMetadata(&finished);
            if (render) try renderMetadata(&fixture, &finished);
            try expectFailure(&fixture, &finished, error.CommandStreamTruncated);
            try std.testing.expectEqual(@as(u32, 0), fixture.capture.markers);
            try std.testing.expectEqual(@as(u32, 0), fixture.capture.pushes);
        }
    }
}

test "a malformed command after an issued Vulkan call poisons the partial recording" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    var arena = try stream.Allocator.init(allocator, 1024);
    defer arena.deinit();
    try emit(.insert_debug_marker, &arena, .{ .length = 8 });
    try bytes(&arena, "issued!\x00");
    _ = try arena.allocate(0x12345678, 0);
    var finished = finishRaw(&arena, fixture.core_device.borrow());
    defer fixture.deinitFinished(&finished);
    try expectFailure(&fixture, &finished, error.InvalidCommandTag);
    try std.testing.expectEqual(@as(u32, 1), fixture.capture.markers);
    try std.testing.expectEqualStrings("issued!", fixture.capture.last_label[0..fixture.capture.last_label_length]);
}

test "bundle failure leaves parent and borrowed bundle storage owned and readable" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    var bundle_encoder = try fixture.initBundleEncoder();
    defer fixture.deinitBundleEncoder(&bundle_encoder);
    try bundle_encoder.insertDebugMarker("borrowed");
    const bundle = try fixture.finishBundle(&bundle_encoder);
    defer fixture.releaseBundle(bundle);
    var arena = try stream.Allocator.init(allocator, 1024);
    defer arena.deinit();
    try emit(.begin_render_pass, &arena, fixture.renderBegin());
    try emit(.execute_bundles, &arena, .{ .count = 2 });
    const refs = try arena.allocateData(commands.Ref, 2);
    refs[0] = try fixture.bundleRef(bundle);
    refs[1] = null;
    try emit(.end_render_pass, &arena, .{});
    var finished = finishRaw(&arena, fixture.core_device.borrow());
    defer fixture.deinitFinished(&finished);
    try renderMetadata(&fixture, &finished);
    try expectFailure(&fixture, &finished, error.InvalidResourceRef);
    var guard = dusk.core.ObjectGuard.lockUncancelable(
        std.testing.io,
        fixture.core_device.borrow().objectList(),
    );
    defer guard.unlock(std.testing.io);
    try std.testing.expect(bundle.header.isAlive(&guard));
    // The render prepass admits every bundle before starting native execution.
    try std.testing.expectEqual(@as(u32, 0), fixture.capture.markers);
    try std.testing.expectEqual(@as(u32, 0), fixture.capture.begins);
    try std.testing.expectEqual(@as(u32, 0), fixture.capture.ends);
    var borrowed = bundle.iterator(&guard);
    defer borrowed.deinit();
    try std.testing.expectEqual(commands.Tag.insert_debug_marker, (try borrowed.nextTag()).?);
}

test "pass label runs refuse truncated data without consuming pass metadata" {
    for ([_]bool{ false, true }) |render| {
        // SAFETY: Init writes owned fields before use at this stable stack address.
        // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
        var fixture: Fixture = .{
            .capture = .{ .viewports = undefined },
            .queue = undefined,
            .recording = undefined,
            .passes = undefined,
            .frames = undefined,
            .core_device = undefined,
            .texture = undefined,
            .view = undefined,
        };
        try fixture.init(null);
        defer _ = fixture.deinit();
        var arena = try stream.Allocator.init(allocator, 1024);
        defer arena.deinit();
        if (render) {
            var begin = fixture.renderBegin();
            begin.label_length = 17;
            try emit(.begin_render_pass, &arena, begin);
        } else {
            try emit(.begin_compute_pass, &arena, .{ .label_length = 17 });
        }
        try bytes(&arena, "short\x00");
        var finished = finishRaw(&arena, fixture.core_device.borrow());
        defer fixture.deinitFinished(&finished);
        if (render) try renderMetadata(&fixture, &finished) else try computeMetadata(&finished);
        try expectFailure(&fixture, &finished, error.CommandStreamTruncated);
        try std.testing.expectEqual(@as(u32, 0), fixture.capture.begins);
    }
}

test "empty replay preserves ownership without requiring a submit" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    var arena = try stream.Allocator.init(allocator, 1024);
    defer arena.deinit();
    var finished = finishRaw(&arena, fixture.core_device.borrow());
    defer fixture.deinitFinished(&finished);
    const before_replay = finished;
    try fixture.replay(&finished);
    try expectBorrowed(&finished, before_replay);
    try std.testing.expect(!fixture.queue.recording_poisoned);
    try std.testing.expect(!fixture.recording.needs_submit);
}

test "a missing command buffer preserves the finished stream and poisons recording" {
    // SAFETY: Init writes owned fields before use at this stable stack address.
    // viewport_count starts at zero. The viewport callback writes each observed prefix entry.
    var fixture: Fixture = .{
        .capture = .{ .viewports = undefined },
        .queue = undefined,
        .recording = undefined,
        .passes = undefined,
        .frames = undefined,
        .core_device = undefined,
        .texture = undefined,
        .view = undefined,
    };
    try fixture.init(null);
    defer _ = fixture.deinit();
    fixture.queue.contexts[0].command_buffer = null;
    var arena = try stream.Allocator.init(allocator, 1024);
    defer arena.deinit();
    try emit(.insert_debug_marker, &arena, .{ .length = 6 });
    try bytes(&arena, "owned\x00");
    var finished = finishRaw(&arena, fixture.core_device.borrow());
    defer fixture.deinitFinished(&finished);
    try expectFailure(&fixture, &finished, error.InvalidResourceRef);
    try std.testing.expectEqual(@as(u32, 0), fixture.capture.markers);
}
