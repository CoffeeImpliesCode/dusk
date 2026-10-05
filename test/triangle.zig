//! The M18 shard: one triangle, one 2x2 `rgba8unorm` offscreen texture, one
//! readback, sixteen asserted channel values.
//!
//! **What this shard asserts.** One `vkCmdDraw` of the three vertices in
//! `test/fixtures/triangle.vert.spv`, shaded by `triangle.frag.spv` from a
//! uniform buffer, into a 2x2 `rgba8unorm` image; one `vkCmdCopyImageToBuffer`
//! at a 256-byte row pitch; and all four pixels' four channels, read back from
//! host-visible memory. Sixteen values, each named by pixel and channel.
//!
//! **What the sixteen values are.** The checked-in vertex shader
//! (`test/fixtures/triangle.vert.wgsl`) puts the three vertices at `(0, -0.8)`,
//! `(0.8, 0.8)` and `(-0.8, 0.8)`. On a 2x2 target the pixel centres are
//! `(-0.5, 0.5)`, `(0.5, 0.5)`, `(-0.5, -0.5)` and `(0.5, -0.5)` in normalised
//! device coordinates, and the fragment module carries
//! `OpExecutionMode OriginUpperLeft`, so the positive-`y` centres are row zero.
//! Two of the four centres are inside the triangle — both of row zero — and two
//! are outside, each by 0.3 in `y`, so no fill rule decides a pixel. The clear
//! colour and the tint differ, which is what makes the two rows tellable apart:
//! a submission that drew nothing reads as sixteen bytes of clear, and one that
//! cleared nothing reads as sixteen bytes of tint.
//!
//! **What this shard does not claim.** It claims no swap chain and no surface;
//! the host is headless (`AGENTS.md` §5) and the target is an image this shard
//! creates and destroys. `src/engine/command_buffer.zig` is not on disk, so the
//! commands are recorded here rather than replayed from the front-end stream.
//! Of M18 the shard exercises the three files the repository has —
//! `src/engine/render_pass_cache.zig`, `src/engine/framebuffer_cache.zig` and
//! `src/engine/recording_context.zig` — through their public entry points. The
//! `cmd_*` calls around them are test scaffolding in the shape
//! `test/vulkan_device.zig` already sets with `createFillAllocation`: no
//! upstream row is claimed for them.
//!
//! **The memory types.** The staging buffer is allocated host-visible *and*
//! host-coherent and `vkMapMemory` is called with flags zero. That is not a
//! shortcut: the bindings this repository checks in carry `VkMemoryMapFlags` and
//! no `VK_MEMORY_MAP_READ_BIT`, so a coherent type is the only way to read a
//! copy back without an invalidation the port cannot spell.

const std = @import("std");
const dusk = @import("dusk");

const vulkan = dusk.platform.vulkan_bindings;
const dispatch = dusk.vk.dispatch;
const platform = dusk.platform;

const framebuffer_cache = dusk.engine.framebuffer_cache;
const queue = dusk.engine.queue;
const recording_context = dusk.engine.recording_context;
const render_pass_cache = dusk.engine.render_pass_cache;
const vulkan_device = dusk.engine.vulkan_device;

const BufferUsage = dusk.api.bitmask.BufferUsage;

// --- The numbers the acceptance fixes --------------------------------------

/// Two, because one pixel is too coarse to tell a covered centre from a clipped
/// one, and four is few enough to assert sixteen channel values by name.
const target_extent: u32 = 2;

/// `rgba8unorm` is four bytes per texel in red, green, blue, alpha order in
/// memory, which is the order `copyTextureToBuffer` hands back.
const bytes_per_pixel: usize = 4;

/// The WebGPU row alignment, `src/dawn/common/Constants.h:44`, and a value
/// `kOptimalBufferCopyRowPitchAlignment` may take. The copy names it, so the gap
/// between two rows is observable and the padding assertion has a floor to
/// stand on.
const bytes_per_row_alignment: usize = 256;

/// The whole staging allocation: two rows at the pitch above.
const readback_byte_count: usize = bytes_per_row_alignment * target_extent;

/// The byte every staging byte holds until a copy overwrites it. A copy that ran
/// long would leave a colour in the gap; one that underwrote the rows would
/// leave a sentinel where a colour belongs.
const untouched_fill: u8 = 0xa5;

/// The tint the fragment shader reads and returns
/// (`test/fixtures/triangle.frag.wgsl`). Red, opaque.
const tint = [4]f32{ 1.0, 0.0, 0.0, 1.0 };

/// The clear the pass starts from. Blue, and deliberately not the tint.
const clear_colour = [4]f32{ 0.0, 0.0, 1.0, 1.0 };

/// `vec4<f32>` is the whole of `Tint`, and `minUniformBufferOffsetAlignment`
/// bounds a descriptor's offset rather than its size, so sixteen bytes is a
/// legal allocation.
const uniform_byte_count: vulkan.VkDeviceSize = 16;

/// The binding `triangle.frag.wgsl` declares. It is 1 and not 0 so a set and a
/// binding cannot be confused for one index written down twice.
const tint_binding: u32 = 1;

/// The vertex shader builds its triangle from `vertex_index` alone, so the draw
/// is three vertices and no vertex buffer.
const vertex_count: u32 = 3;

/// The channel names a failed assertion prints, in memory order.
const channel_name = [_][]const u8{ "red", "green", "blue", "alpha" };

/// The two fixtures, embedded rather than read: a test that depends on the
/// process's working directory cannot be run from anywhere.
const vertex_spirv = @embedFile("fixtures/triangle.vert.spv");
const fragment_spirv = @embedFile("fixtures/triangle.frag.spv");

/// The two fixtures as SPIR-V words.
///
/// `decodeWords` runs at compile time, so these are constants rather than a
/// buffer the test allocates: both fixtures are checked in and neither changes
/// between runs, and a module borrows the words it was created over
/// (`src/pipeline/shader_module.zig:39`), so the words have to outlive the
/// `vkCreateShaderModule` call that names them.
const vertex_words = decodeWords(vertex_spirv);
const fragment_words = decodeWords(fragment_spirv);

/// The entry points the two fixtures declare.
///
/// `VkPipelineShaderStageCreateInfo.name` is the WGSL entry function's name, and
/// a fixture regenerated with a different one would otherwise fail much later at
/// `vkCreateGraphicsPipelines` with nothing to point at.
const vertex_entry_point = "vs_main";
const fragment_entry_point = "fs_main";

// --- Errors -----------------------------------------------------------------

/// What the test's own Vulkan calls can report.
///
/// `dispatch.Error` is the whole driver-code set. The rest are the ways this
/// shard's own scaffolding can be wrong: a core 1.0 entry point the loader did
/// not fill, a null handle a successful create wrote, a memory type this host
/// does not have, or a fixture that does not declare the entry point the
/// pipeline names.
const SetupError = dispatch.Error || std.mem.Allocator.Error || error{
    DeviceProcMissing,
    HandleCreationReturnedNull,
    MapReturnedNull,
    NoDeviceLocalMemoryType,
    NoHostVisibleMemoryType,
    EntryPointNameAbsent,
    TintBufferDoesNotNeedEagerTransition,
    TintBufferNotQueuedForEagerTransition,
};

// --- What one submission needs ---------------------------------------------

/// A `VkBuffer` and the memory bound to it, created as a pair because neither
/// is usable without the other.
const BufferAllocation = struct {
    buffer: vulkan.VkBuffer,
    memory: vulkan.VkDeviceMemory,
};

/// The offscreen target: the image, its memory, and the one view the framebuffer
/// attaches. The view is created here rather than by the cache because
/// `FramebufferCacheKey` stores an identity the caller mints, not the handle.
const TargetImage = struct {
    image: vulkan.VkImage,
    memory: vulkan.VkDeviceMemory,
    view: vulkan.VkImageView,
};

/// Everything one submission creates, so the teardown is one list in reverse
/// creation order rather than a dozen defers that interleave badly.
const Scene = struct {
    staging: BufferAllocation,
    uniform: BufferAllocation,
    set_layout: vulkan.VkDescriptorSetLayout,
    descriptor_pool: vulkan.VkDescriptorPool,
    descriptor_set: vulkan.VkDescriptorSet,
    pipeline_layout: vulkan.VkPipelineLayout,
    vertex_module: vulkan.VkShaderModule,
    fragment_module: vulkan.VkShaderModule,
    pipeline: vulkan.VkPipeline,
};

/// The stand-in for `FencedDeleter::DeleteWhenUnused`
/// (`FramebufferCache.cpp:87`-`:89`). Nothing is in flight by the time an
/// eviction can happen here, because the only submission has already been
/// waited on, so the eviction destroys at once.
const FramebufferDeleter = struct {
    procs: *const dispatch.DeviceProcs,
    vk_device: vulkan.VkDevice,

    fn destroy(context: *anyopaque, framebuffer: vulkan.VkFramebuffer) void {
        const self: *FramebufferDeleter = @ptrCast(@alignCast(context));
        // Core 1.0, so a null field is a loader defect and not a device that
        // lacks the call.
        (self.procs.destroy_framebuffer orelse unreachable)(
            self.vk_device,
            framebuffer,
            null,
        );
    }
};

// --- The acceptance ---------------------------------------------------------

test "triangle: one draw into a 2x2 rgba8unorm image reads back sixteen channels" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `HandleSet` counts the seven handle kinds `vulkan_device.zig` names, and an
    // image, a view, a render pass, a framebuffer, a descriptor set and a
    // pipeline are not among them. The buffers, the memory and the fences are
    // counted, so the final `isEmpty` still catches a missed destroy.
    //
    // Nothing below is `defer`red. The teardown is explicit and last, because
    // the assertions after it read the live-handle count and a `defer` would
    // run after them; a `defer` plus an explicit call would destroy every
    // handle twice. `test/vulkan_device.zig` makes the same choice.
    var handles: vulkan_device.HandleSet = .{};
    var device_mutex: platform.DeviceMutex = .{};

    // One `VkInstance` per ICD, fallback first (`BackendVk.cpp:590`-`:610`), and
    // the first physical device that reports Vulkan 1.1 or later (`:633`-`:637`).
    var backend = vulkan_device.Backend.init(std.testing.allocator, .{
        .handles = &handles,
    });

    var adapters = try backend.discoverPhysicalDevices(.{});

    const adapter = try adapters.first();
    try std.testing.expect(adapter.physical.supportsRequiredVersion());

    var device = try vulkan_device.Device.create(std.testing.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });

    var q = try queue.Queue.init(.{
        .context = .{
            .allocator = std.testing.allocator,
            .dispatch = device.dispatchTable(),
            .vk_device = device.vk_device,
            // `fetchQueue` resolves `vkGetDeviceQueue` through the device tier
            // (`AGENTS.md` §3.1), so a loader that missed it refuses here with
            // a typed error instead of a forced unwrap.
            .vk_queue = try device.fetchQueue(),
            .queue_family_index = device.queue_family_index,
            .memory_properties = device.memoryProperties(),
            .handles = &handles,
        },
        .device_mutex = &device_mutex,
    });

    const procs = device.procs;
    const vk_device = device.vk_device;

    // --- the target and the two caches of M18 -------------------------------

    var target = try createTarget(device, &handles);

    // `RenderPassCache::GetRenderPass` (`RenderPassCache.cpp:408`). The pass
    // comes from a sparse query, and the key carries masks rather than handles,
    // so two different attachment shapes can never share one `VkRenderPass`.
    var passes = render_pass_cache.RenderPassCache.init(.{
        .allocator = std.testing.allocator,
        .device = .{ .procs = procs, .vk_device = vk_device },
    });

    var pass_query: render_pass_cache.RenderPassCacheQuery = .{};
    pass_query.setSampleCount(1);
    pass_query.setColor(.{
        .index = 0,
        .format = .rgba8_unorm,
        .load_op = .clear,
        .store_op = .store,
        .has_resolve_target = false,
        .render_to_single_sampled = false,
    });
    const pass = try passes.getRenderPass(io, pass_query);
    // The `uniqueId` is stamped inside the create (`RenderPassCache.cpp:425`),
    // so a pass that exists has an id and the first one is 1.
    try std.testing.expectEqual(@as(u64, 1), pass.unique_id);
    // One subpass, so the subpass that writes is subpass zero (`:477`).
    try std.testing.expectEqual(@as(u32, 0), pass.main_subpass);

    var deleter: FramebufferDeleter = .{ .procs = procs, .vk_device = vk_device };
    var framebuffers = framebuffer_cache.FramebufferCache.init(.{
        .allocator = std.testing.allocator,
        .device = .{ .procs = procs, .vk_device = vk_device },
        .destroy_context = &deleter,
        .destroy_when_unused = FramebufferDeleter.destroy,
    });

    // `FramebufferCacheQuery::SetRenderPass` (`FramebufferCache.cpp:43`): the
    // key holds the pass's `uniqueId` and never the `VkRenderPass`, because a
    // handle may be reused by a later create.
    var framebuffer_query: framebuffer_cache.FramebufferCacheQuery = .{};
    framebuffer_query.key.setRenderPass(.{
        .pass_id = pass.unique_id,
        .width = target_extent,
        .height = target_extent,
    });
    try framebuffer_query.addAttachment(.{
        .texture_view_id = 1,
        .depth_slice = 0,
        .image_view = target.view,
        // The clear travels with the query because
        // `CommandBufferVk.cpp:1041`-`:1042` takes it from here, not from the
        // framebuffer.
        .clear_value = .{ .color = .{ .float32 = clear_colour } },
    });
    const framebuffer = try framebuffers.getOrCreate(&framebuffer_query, pass.render_pass);
    try std.testing.expectEqual(@as(usize, 1), framebuffers.count());

    // The second call for the same key is the observable the cache exists for: a
    // hit rather than a second `vkCreateFramebuffer`.
    try std.testing.expectEqual(
        framebuffer,
        try framebuffers.getOrCreate(&framebuffer_query, pass.render_pass),
    );
    try std.testing.expectEqual(@as(usize, 1), framebuffers.count());

    // --- the rest of the submission's inputs --------------------------------

    var scene = try createScene(device, &handles, pass.render_pass);

    // The tint the fragment shader reads, written through the host and then
    // handed to the fragment stage by a memory barrier.
    try writeTint(device, scene.uniform.memory);

    // The staging buffer starts as a sentinel everywhere the copy must not go.
    const staged = try mapStaging(device, scene.staging.memory);
    @memset(staged, untouched_fill);

    // --- the recorded commands ----------------------------------------------

    // `Queue::init` began the primary command buffer
    // (`src/engine/queue.zig:239`), so recording starts here and `submit` ends
    // it.
    const command_buffer = q.commandBuffer();

    // `CommandRecordingContext::EmitBufferBarrierIfNecessary`
    // (`CommandRecordingContextVk.cpp:42`). The host wrote the tint and the
    // fragment stage reads it, which is a memory barrier with no buffer and no
    // image barrier — the whole claim of that row.
    const context: recording_context.Device = .{ .procs = procs, .vk_device = vk_device };
    recording_context.emitBufferBarrierIfNecessary(context, command_buffer, .{
        .src_stage_mask = @intCast(vulkan.VK_PIPELINE_STAGE_HOST_BIT),
        .dst_stage_mask = @intCast(vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT),
        .src_access_mask = @intCast(vulkan.VK_ACCESS_HOST_WRITE_BIT),
        .dst_access_mask = @intCast(vulkan.VK_ACCESS_SHADER_READ_BIT),
    });

    // The same context's eager-transition answer for the tint buffer
    // (`CommandRecordingContextVk.cpp:35`): the buffer's own usage is mappable
    // and the usage this submit records is not, so the buffer must leave the
    // mappable layout for the submit, and the context holds it so the way back
    // is not forgotten.
    var recording = recording_context.CommandRecordingContext.init(std.testing.allocator);
    const eager = try recording.checkBufferNeedsEagerTransition(
        &scene.uniform,
        .{ .map_write = true },
        .{ .uniform = true },
    );
    if (!eager) return error.TintBufferDoesNotNeedEagerTransition;
    if (!recording.isEagerTransitionQueued(&scene.uniform)) {
        return error.TintBufferNotQueuedForEagerTransition;
    }

    imageBarrier(
        procs,
        command_buffer,
        target.image,
        @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
        @intCast(vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
        @intCast(vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT),
        @intCast(vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT),
        0,
        @intCast(vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT),
    );

    // `CommandBuffer::RecordBeginRenderPass` (`CommandBufferVk.cpp:1041`-`:1042`)
    // takes the clear values from the framebuffer query, so the clear travels
    // with the begin info rather than with the framebuffer.
    const clear_value: vulkan.VkClearValue = .{ .color = .{ .float32 = clear_colour } };
    const begin_info: vulkan.VkRenderPassBeginInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO),
        .pNext = null,
        .renderPass = pass.render_pass,
        .framebuffer = framebuffer,
        // `GetAlignedRenderArea` (`CommandBufferVk.cpp:198`) clamps to the pass
        // size, and the pass is the whole 2x2 target.
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = target_extent, .height = target_extent },
        },
        .clearValueCount = 1,
        .pClearValues = &clear_value,
    };
    (procs.cmd_begin_render_pass orelse return error.DeviceProcMissing)(
        command_buffer,
        &begin_info,
        @intCast(vulkan.VK_SUBPASS_CONTENTS_INLINE),
    );

    // `ProgrammablePassState::SyncAndRun` (`CommandBufferVk.cpp:647`-`:653`)
    // binds the pipeline, then the descriptor sets, then runs the operation.
    (procs.cmd_bind_pipeline orelse return error.DeviceProcMissing)(
        command_buffer,
        @intCast(vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS),
        scene.pipeline,
    );
    (procs.cmd_bind_descriptor_sets orelse return error.DeviceProcMissing)(
        command_buffer,
        @intCast(vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS),
        scene.pipeline_layout,
        0,
        1,
        &scene.descriptor_set,
        0,
        null,
    );
    (procs.cmd_draw orelse return error.DeviceProcMissing)(
        command_buffer,
        vertex_count,
        1,
        0,
        0,
    );
    (procs.cmd_end_render_pass orelse return error.DeviceProcMissing)(command_buffer);

    imageBarrier(
        procs,
        command_buffer,
        target.image,
        @intCast(vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
        @intCast(vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL),
        @intCast(vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT),
        @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
        @intCast(vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT),
        @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT),
    );

    const region: vulkan.VkBufferImageCopy = .{
        .bufferOffset = 0,
        // `bufferRowLength` is in texels, not bytes, so the pitch the buffer
        // names is `bytes_per_row_alignment` over four bytes per texel. Naming
        // the target's own width instead would make the rows adjacent, which
        // is not the copy this shard claims and leaves nothing between row one
        // and row zero for a long copy to show up in.
        .bufferRowLength = bytes_per_row_alignment / bytes_per_pixel,
        // `bufferImageHeight` counts rows in a depth layer and one layer holds
        // `target_extent` of them.
        .bufferImageHeight = target_extent,
        .imageSubresource = .{
            .aspectMask = @intCast(vulkan.VK_IMAGE_ASPECT_COLOR_BIT),
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = target_extent, .height = target_extent, .depth = 1 },
    };
    (procs.cmd_copy_image_to_buffer orelse return error.DeviceProcMissing)(
        command_buffer,
        target.image,
        @intCast(vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL),
        scene.staging.buffer,
        1,
        &region,
    );

    // --- the submission, the fence and the sixteen values -------------------

    const submitted = try q.submit(.{ .command_buffers = &.{command_buffer} });
    // `Queue.wait` threads `io` first, so Zig does not treat it as a member
    // function and `q.wait(io, ...)` would bind `io` to the queue. The
    // qualified call is what puts `io` in the parameter the signature names
    // (`src/engine/queue.zig:367`).
    const completed = try queue.Queue.wait(io, &q, .{
        .serial = submitted.serial,
        .timeout_ns = queue.fence_wait_timeout_ns,
    });
    try std.testing.expect(completed >= submitted.serial);
    try std.testing.expectEqual(
        @as(vulkan.VkResult, vulkan.VK_SUCCESS),
        try q.fenceStatus(submitted.fence),
    );

    // The sixteen values. Row zero is the two covered centres and reads as the
    // tint; row one is the two uncovered centres and reads as the clear.
    try expectPixel(staged, 0, 0, rgbaBytes(tint));
    try expectPixel(staged, 1, 0, rgbaBytes(tint));
    try expectPixel(staged, 0, 1, rgbaBytes(clear_colour));
    try expectPixel(staged, 1, 1, rgbaBytes(clear_colour));

    // Nothing outside the two runs the copy wrote was written at all, so the
    // pitch is observable: a copy that ran long would leave a colour in the
    // padding or the tail.
    try expectSentinel(staged);

    // --- teardown -----------------------------------------------------------
    //
    // In the order the handles were created, and unmap before the device goes:
    // `vkUnmapMemory` on a destroyed device is a use-after-free, and the queue
    // has to have destroyed its fences before the device goes too.
    unmapStaging(device, scene.staging.memory);
    recording.deinit();
    destroyScene(device, &scene, &handles);
    destroyTarget(device, &target, &handles);
    framebuffers.deinit();
    passes.deinit(io);
    // Every teardown below reaches a dispatch proc the loader can be missing
    // (`AGENTS.md` §3.1), so each refuses with a typed error rather than
    // panicking and the shard returns them. The block is explicit rather than
    // deferred, which is what makes `try` available here at all: Zig 0.16 has
    // no `try` in a `defer`. `AdapterList.deinit` resolves no proc, so it
    // still returns nothing.
    try q.deinit();
    try device.deinit(std.testing.allocator);
    adapters.deinit();
    try backend.deinit();

    try std.testing.expect(handles.isEmpty());
    // `firstLeakedKind` answers with an optional, so the absence it reports is
    // the optional's `null` and not a member of the enumeration: the seven
    // `HandleKind` members are all handle types, because it declares no
    // `count` member (`src/engine/vulkan_device.zig:113`-`:116`), and a member
    // standing for "nothing leaked" would be acquirable and releasable like one.
    try std.testing.expect(handles.firstLeakedKind() == null);
    try std.testing.expectEqual(@as(u32, 0), handles.totalCount());
}

// --- The sixteen values -----------------------------------------------------

/// The four bytes a colour becomes in `rgba8unorm` memory.
///
/// Every component of both colours is exactly 0.0 or exactly 1.0, so the
/// multiply is exact and the truncation is not a rounding decision. Anything
/// else would need a rounding rule, and a test whose expected value is a
/// judgement is a test that can be argued with. The clamp is what makes that
/// claim a fact rather than a promise: a component outside the unit interval
/// saturates instead of trapping inside `@intFromFloat`.
fn rgbaBytes(colour: [4]f32) [4]u8 {
    var bytes: [4]u8 = @splat(0);
    for (&bytes, 0..) |*byte, channel| {
        const scaled: f32 = std.math.clamp(colour[channel] * 255.0, 0.0, 255.0);
        byte.* = @intFromFloat(scaled);
    }
    return bytes;
}

/// Asserts one pixel's four channels and names the position on failure.
///
/// `expectEqual` alone reports two bytes and nothing about where they came from,
/// and sixteen assertions spread over a 256-byte pitch need the position more
/// than they need the number.
fn expectPixel(staged: []const u8, x: u32, y: u32, want: [4]u8) !void {
    const at: usize = y * bytes_per_row_alignment + x * bytes_per_pixel;
    var channel: usize = 0;
    while (channel < want.len) : (channel += 1) {
        const got = staged[at + channel];
        std.testing.expectEqual(want[channel], got) catch |err| {
            // `expectEqual` names the two bytes and nothing else, so the
            // position and the channel go out through the log on the way to
            // the caller. This runs only after `expectEqual` has already
            // failed, so the logged error never turns a passing shard red.
            std.log.err(
                "pixel ({d}, {d}) {s}: read {d}, want {d}",
                .{ x, y, channel_name[channel], got, want[channel] },
            );
            return err;
        };
    }
}

/// Asserts that every staging byte the copy did not write still holds the
/// sentinel the shard wrote before the submit.
///
/// The copy names a `bytes_per_row_alignment` row pitch, so it wrote two runs
/// of `target_extent` texels and left everything else alone: the padding
/// between the two runs and the tail after the second. Asserting the whole
/// buffer outside those two runs is what makes the pitch observable, because
/// a copy that ran long lands in one of the two.
fn expectSentinel(staged: []const u8) !void {
    for (staged, 0..) |byte, at| {
        if (inCopiedRun(at)) continue;
        std.testing.expectEqual(untouched_fill, byte) catch |err| {
            // As in `expectPixel` above: `expectEqual` names the two bytes,
            // so the offset that located the byte goes out with them. Only a
            // shard that already failed reaches this line.
            std.log.err(
                "staging byte {d}, outside every run the copy wrote: read {d}, want {d}",
                .{ at, byte, untouched_fill },
            );
            return err;
        };
    }
}

/// Whether `at` is inside one of the two runs `vkCmdCopyImageToBuffer` wrote.
///
/// Row zero starts at `bufferOffset`, which is zero, and row one starts one
/// `bufferRowLength` of texels later, which is `bytes_per_row_alignment`
/// (`VkBufferImageCopy`, the destination offset formula). Each run is
/// `target_extent` texels wide.
fn inCopiedRun(at: usize) bool {
    const row_byte_count: usize = target_extent * bytes_per_pixel;
    return at < row_byte_count or
        (at >= bytes_per_row_alignment and at < bytes_per_row_alignment + row_byte_count);
}

// --- The target -------------------------------------------------------------

/// The 2x2 `rgba8unorm` offscreen target, its memory, and its one view.
///
/// `initialLayout` is `VK_IMAGE_LAYOUT_UNDEFINED`: nothing has been written to
/// the image, so its contents are undefined until the first barrier, which is
/// why the load op then gets to discard for free.
fn createTarget(
    device: vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
) SetupError!TargetImage {
    const procs = device.procs;
    const vk_device = device.vk_device;

    const image_info: vulkan.VkImageCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .imageType = @intCast(vulkan.VK_IMAGE_TYPE_2D),
        .format = @intCast(vulkan.VK_FORMAT_R8G8B8A8_UNORM),
        .extent = .{ .width = target_extent, .height = target_extent, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
        .tiling = @intCast(vulkan.VK_IMAGE_TILING_OPTIMAL),
        .usage = @intCast(
            vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        ),
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
    };

    var image: vulkan.VkImage = null;
    try dispatch.checkVkSuccess((procs.create_image orelse
        return error.DeviceProcMissing)(vk_device, &image_info, null, &image));
    if (image == null) return error.HandleCreationReturnedNull;

    // SAFETY: `vkGetImageMemoryRequirements` is an out-parameter call: the
    // driver writes every field of the struct before the statement returns, and
    // the `memoryTypeBits` read below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    (procs.get_image_memory_requirements orelse
        return error.DeviceProcMissing)(vk_device, image, &requirements);
    if (requirements.memoryTypeBits == 0) return error.NoDeviceLocalMemoryType;

    const type_index = vulkan_device.findMemoryTypeIndex(
        device.memoryProperties(),
        requirements.memoryTypeBits,
        0,
        vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) catch return error.NoDeviceLocalMemoryType;

    var memory: vulkan.VkDeviceMemory = null;
    try allocateMemory(device, handles, .{
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    }, &memory);
    try dispatch.checkVkSuccess((procs.bind_image_memory orelse
        return error.DeviceProcMissing)(vk_device, image, memory, 0));

    const view_info: vulkan.VkImageViewCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = @intCast(vulkan.VK_IMAGE_VIEW_TYPE_2D),
        .format = @intCast(vulkan.VK_FORMAT_R8G8B8A8_UNORM),
        .components = .{
            .r = @intCast(vulkan.VK_COMPONENT_SWIZZLE_IDENTITY),
            .g = @intCast(vulkan.VK_COMPONENT_SWIZZLE_IDENTITY),
            .b = @intCast(vulkan.VK_COMPONENT_SWIZZLE_IDENTITY),
            .a = @intCast(vulkan.VK_COMPONENT_SWIZZLE_IDENTITY),
        },
        .subresourceRange = .{
            .aspectMask = @intCast(vulkan.VK_IMAGE_ASPECT_COLOR_BIT),
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var view: vulkan.VkImageView = null;
    try dispatch.checkVkSuccess((procs.create_image_view orelse
        return error.DeviceProcMissing)(vk_device, &view_info, null, &view));
    if (view == null) return error.HandleCreationReturnedNull;

    return .{ .image = image, .memory = memory, .view = view };
}

/// Destroys the target, newest first: the view before the image it was made
/// from, and the image before the memory it is bound to. That order is the one
/// the Vulkan specification requires (`FencedDeleter.h:46`-`:47`).
fn destroyTarget(
    device: vulkan_device.Device,
    target: *TargetImage,
    handles: *vulkan_device.HandleSet,
) void {
    const procs = device.procs;
    const vk_device = device.vk_device;

    (procs.destroy_image_view orelse unreachable)(vk_device, target.view, null);
    (procs.destroy_image orelse unreachable)(vk_device, target.image, null);
    (procs.free_memory orelse unreachable)(vk_device, target.memory, null);
    handles.release(.memory);

    // SAFETY: the three destroys above read every field, and the caller drops
    // `target` with the rest of the test's locals, so nothing reads this again.
    target.* = undefined;
}

// --- The scene --------------------------------------------------------------

/// Creates everything one submission needs beyond its target and its pass, in
/// the order `destroyScene` undoes.
fn createScene(
    device: vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
    render_pass: vulkan.VkRenderPass,
) SetupError!Scene {
    const procs = device.procs;
    const vk_device = device.vk_device;

    // The literal names no value because each field is written by the statement
    // that creates it, below, and nothing reads a field before that statement
    // runs. A step that fails returns its error, so `destroyScene` is reached
    // only for a scene that reached the `return` at the end of this function,
    // and by then every field holds what its own creating call wrote.
    var scene: Scene = .{
        // SAFETY: `createHostBuffer` writes it on the first statement below,
        // and the first read is `scene.staging.memory` in the test body.
        .staging = undefined,
        // SAFETY: `createHostBuffer` writes it on the second statement below,
        // and the first read is `scene.uniform.memory` in the test body.
        .uniform = undefined,
        // SAFETY: `vkCreateDescriptorSetLayout` writes it through the pointer
        // below, and the null check on the next line is the first read.
        .set_layout = undefined,
        // SAFETY: `vkCreateDescriptorPool` writes it through the pointer
        // below, and the null check on the next line is the first read.
        .descriptor_pool = undefined,
        // SAFETY: `vkAllocateDescriptorSets` writes it through the pointer
        // below, and the null check on the next line is the first read.
        .descriptor_set = undefined,
        // SAFETY: `vkCreatePipelineLayout` writes it through the pointer
        // below, and the null check on the next line is the first read.
        .pipeline_layout = undefined,
        // SAFETY: `createShaderModule` writes it on the statement below, and
        // the first read is `scene.vertex_module` in `createGraphicsPipeline`.
        .vertex_module = undefined,
        // SAFETY: `createShaderModule` writes it on the statement below, and
        // the first read is `scene.fragment_module` in `createGraphicsPipeline`.
        .fragment_module = undefined,
        // SAFETY: `createGraphicsPipeline` writes it on the last statement
        // below, and the first read is `scene.pipeline` in the test body.
        .pipeline = undefined,
    };

    scene.staging = try createHostBuffer(device, handles, readback_byte_count, @intCast(
        vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    ));
    scene.uniform = try createHostBuffer(device, handles, uniform_byte_count, @intCast(
        vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    ));

    // One binding, the one `triangle.frag.wgsl` declares: a uniform buffer in
    // the fragment stage.
    const binding: vulkan.VkDescriptorSetLayoutBinding = .{
        .binding = tint_binding,
        .descriptorType = @intCast(vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
        .descriptorCount = 1,
        .stageFlags = @intCast(vulkan.VK_SHADER_STAGE_FRAGMENT_BIT),
    };
    const set_layout_info: vulkan.VkDescriptorSetLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    try dispatch.checkVkSuccess((procs.create_descriptor_set_layout orelse
        return error.DeviceProcMissing)(vk_device, &set_layout_info, null, &scene.set_layout));
    if (scene.set_layout == null) return error.HandleCreationReturnedNull;

    const pool_size: vulkan.VkDescriptorPoolSize = .{
        .type = @intCast(vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
        .descriptorCount = 1,
    };
    const pool_info: vulkan.VkDescriptorPoolCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    try dispatch.checkVkSuccess((procs.create_descriptor_pool orelse
        return error.DeviceProcMissing)(vk_device, &pool_info, null, &scene.descriptor_pool));
    if (scene.descriptor_pool == null) return error.HandleCreationReturnedNull;

    const allocate_info: vulkan.VkDescriptorSetAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO),
        .pNext = null,
        .descriptorPool = scene.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &scene.set_layout,
    };
    try dispatch.checkVkSuccess((procs.allocate_descriptor_sets orelse
        return error.DeviceProcMissing)(vk_device, &allocate_info, &scene.descriptor_set));
    if (scene.descriptor_set == null) return error.HandleCreationReturnedNull;

    const buffer_info: vulkan.VkDescriptorBufferInfo = .{
        .buffer = scene.uniform.buffer,
        .offset = 0,
        .range = uniform_byte_count,
    };
    const write: vulkan.VkWriteDescriptorSet = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET),
        .pNext = null,
        .dstSet = scene.descriptor_set,
        .dstBinding = tint_binding,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = @intCast(vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
        .pImageInfo = null,
        .pBufferInfo = &buffer_info,
        .pTexelBufferView = null,
    };
    (procs.update_descriptor_sets orelse return error.DeviceProcMissing)(
        vk_device,
        1,
        &write,
        0,
        null,
    );

    const layout_info: vulkan.VkPipelineLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &scene.set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    try dispatch.checkVkSuccess((procs.create_pipeline_layout orelse
        return error.DeviceProcMissing)(vk_device, &layout_info, null, &scene.pipeline_layout));
    if (scene.pipeline_layout == null) return error.HandleCreationReturnedNull;

    scene.vertex_module = try createShaderModule(device, &vertex_words, vertex_entry_point);
    scene.fragment_module = try createShaderModule(device, &fragment_words, fragment_entry_point);
    scene.pipeline = try createGraphicsPipeline(device, scene, render_pass);

    return scene;
}

/// Destroys everything `createScene` created, newest first.
///
/// The order is the reverse of creation and also the order the specification
/// requires: the pipeline before the layout and the modules it names, the
/// modules before the pipeline, the buffers before the memory they are bound to.
fn destroyScene(
    device: vulkan_device.Device,
    scene: *Scene,
    handles: *vulkan_device.HandleSet,
) void {
    const procs = device.procs;
    const vk_device = device.vk_device;

    (procs.destroy_pipeline orelse unreachable)(vk_device, scene.pipeline, null);
    (procs.destroy_shader_module orelse unreachable)(vk_device, scene.fragment_module, null);
    (procs.destroy_shader_module orelse unreachable)(vk_device, scene.vertex_module, null);
    (procs.destroy_pipeline_layout orelse unreachable)(vk_device, scene.pipeline_layout, null);
    // The set is freed with its pool, which is what
    // `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT` would otherwise turn
    // into a separate `vkFreeDescriptorSets`.
    (procs.destroy_descriptor_pool orelse unreachable)(vk_device, scene.descriptor_pool, null);
    (procs.destroy_descriptor_set_layout orelse unreachable)(vk_device, scene.set_layout, null);

    (procs.destroy_buffer orelse unreachable)(vk_device, scene.uniform.buffer, null);
    (procs.free_memory orelse unreachable)(vk_device, scene.uniform.memory, null);
    handles.release(.buffer);
    handles.release(.memory);

    (procs.destroy_buffer orelse unreachable)(vk_device, scene.staging.buffer, null);
    (procs.free_memory orelse unreachable)(vk_device, scene.staging.memory, null);
    handles.release(.buffer);
    handles.release(.memory);

    // SAFETY: the destroys above read every field, and the caller drops
    // `scene` with the rest of the test's locals, so nothing reads this again.
    scene.* = undefined;
}

/// One host-visible, host-coherent buffer and the memory bound to it.
///
/// Host coherence is required rather than asked for: the checked-in bindings
/// carry no `VK_MEMORY_MAP_READ_BIT`, so a non-coherent allocation could not be
/// invalidated and its contents would be whatever the driver's write buffer
/// happened to hold.
fn createHostBuffer(
    device: vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
    size: vulkan.VkDeviceSize,
    usage: vulkan.VkBufferUsageFlags,
) SetupError!BufferAllocation {
    const procs = device.procs;
    const vk_device = device.vk_device;

    const buffer_info: vulkan.VkBufferCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = usage,
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    var buffer: vulkan.VkBuffer = null;
    try dispatch.checkVkSuccess((procs.create_buffer orelse
        return error.DeviceProcMissing)(vk_device, &buffer_info, null, &buffer));
    if (buffer == null) return error.HandleCreationReturnedNull;
    handles.acquire(.buffer);

    // SAFETY: `vkGetBufferMemoryRequirements` is an out-parameter call: the
    // driver writes every field of the struct before the statement returns, and
    // the `memoryTypeBits` read below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    (procs.get_buffer_memory_requirements orelse
        return error.DeviceProcMissing)(vk_device, buffer, &requirements);
    if (requirements.memoryTypeBits == 0) return error.NoHostVisibleMemoryType;

    const required: vulkan.VkMemoryPropertyFlags = @intCast(
        vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    const type_index = vulkan_device.findMemoryTypeIndex(
        device.memoryProperties(),
        requirements.memoryTypeBits,
        required,
        0,
    ) catch return error.NoHostVisibleMemoryType;

    var memory: vulkan.VkDeviceMemory = null;
    try allocateMemory(device, handles, .{
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    }, &memory);
    // Offset zero is aligned for every `VkMemoryRequirements`, so the alignment
    // rule needs no arithmetic here.
    try dispatch.checkVkSuccess((procs.bind_buffer_memory orelse
        return error.DeviceProcMissing)(vk_device, buffer, memory, 0));

    return .{ .buffer = buffer, .memory = memory };
}

/// Allocates one `VkDeviceMemory` and counts it.
///
/// The bind is left to the caller because a `VkBuffer` and a `VkImage` are both
/// opaque handles and the two entry points that bind them are different.
fn allocateMemory(
    device: vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
    info: vulkan.VkMemoryAllocateInfo,
    memory: *vulkan.VkDeviceMemory,
) SetupError!void {
    try dispatch.checkVkSuccess((device.procs.allocate_memory orelse
        return error.DeviceProcMissing)(device.vk_device, &info, null, memory));
    if (memory.* == null) return error.HandleCreationReturnedNull;
    handles.acquire(.memory);
}

/// Creates the `VkShaderModule` over a checked-in fixture.
///
/// `entry_point` is checked against the module's own words before the call: a
/// fixture regenerated with a different entry point would otherwise fail at
/// `vkCreateShaderModule` with a diagnostic that names neither the file nor the
/// name the pipeline asked for.
fn createShaderModule(
    device: vulkan_device.Device,
    words: []const u32,
    entry_point: []const u8,
) SetupError!vulkan.VkShaderModule {
    try checkEntryPoint(words, entry_point);

    // Dawn points `codeSize` and `pCode` at Tint's regenerated words
    // (`ShaderModuleVk.cpp:500`-`:501`); the port has the caller's words at
    // creation, so the same two fields carry them. The words are the caller's
    // and stay the caller's: nothing here rewrites them and nothing here owns
    // them, so a module this function returns borrows a slice that was already
    // there (`src/pipeline/shader_module.zig:39`).
    const info: vulkan.VkShaderModuleCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .codeSize = words.len * @sizeOf(u32),
        .pCode = words.ptr,
    };

    var module: vulkan.VkShaderModule = null;
    try dispatch.checkVkSuccess((device.procs.create_shader_module orelse
        return error.DeviceProcMissing)(device.vk_device, &info, null, &module));
    if (module == null) return error.HandleCreationReturnedNull;
    return module;
}

/// Builds the graphics pipeline the draw needs.
///
/// There is no vertex input state with anything in it, because
/// `triangle.vert.wgsl` reads `vertex_index` and no attribute; no depth-stencil
/// state, because the target has no depth attachment; and no dynamic state,
/// because the pass is 2x2 and the pipeline is built once for it.
fn createGraphicsPipeline(
    device: vulkan_device.Device,
    scene: Scene,
    render_pass: vulkan.VkRenderPass,
) SetupError!vulkan.VkPipeline {
    const procs = device.procs;
    const vk_device = device.vk_device;

    var stages = [_]vulkan.VkPipelineShaderStageCreateInfo{
        .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO),
            .pNext = null,
            .flags = 0,
            .stage = @intCast(vulkan.VK_SHADER_STAGE_VERTEX_BIT),
            .module = scene.vertex_module,
            .pName = vertex_entry_point,
            .pSpecializationInfo = null,
        },
        .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO),
            .pNext = null,
            .flags = 0,
            .stage = @intCast(vulkan.VK_SHADER_STAGE_FRAGMENT_BIT),
            .module = scene.fragment_module,
            .pName = fragment_entry_point,
            .pSpecializationInfo = null,
        },
    };

    const vertex_input: vulkan.VkPipelineVertexInputStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    const input_assembly: vulkan.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .topology = @intCast(vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST),
        .primitiveRestartEnable = 0,
    };

    // The flip is not a style choice. Vulkan's framebuffer origin is the top
    // left while normalised device coordinates put +y up, so an unflipped
    // viewport sends ndc +y to the *last* row. WebGPU sends it to row zero,
    // and `CommandBuffer::RecordRenderPass` gets there the way this does
    // (`CommandBufferVk.cpp:1776`-`:1778`): the viewport starts at the pass
    // height with a negative height, which maps ndc +y to framebuffer row zero.
    // The coverage argument in the module comment is stated against that.
    const viewport: vulkan.VkViewport = .{
        .x = 0,
        .y = @floatFromInt(target_extent),
        .width = @floatFromInt(target_extent),
        .height = -@as(f32, @floatFromInt(target_extent)),
        .minDepth = 0,
        .maxDepth = 1,
    };
    // The scissor is not flipped: `RecordRenderPass` passes the render area
    // through as an offset and an extent (`CommandBufferVk.cpp:1783`-`:1787`).
    const scissor: vulkan.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = target_extent, .height = target_extent },
    };
    const viewport_state: vulkan.VkPipelineViewportStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    const rasterization: vulkan.VkPipelineRasterizationStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .depthClampEnable = 0,
        .rasterizerDiscardEnable = 0,
        .polygonMode = @intCast(vulkan.VK_POLYGON_MODE_FILL),
        // No culling, so the coverage argument in the module comment depends on
        // the fixture's vertex order alone and not on a winding convention.
        .cullMode = @intCast(vulkan.VK_CULL_MODE_NONE),
        .frontFace = @intCast(vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE),
        .depthBiasEnable = 0,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1,
    };

    const multisample: vulkan.VkPipelineMultisampleStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
        .sampleShadingEnable = 0,
        .minSampleShading = 0,
        .pSampleMask = null,
        .alphaToCoverageEnable = 0,
        .alphaToOneEnable = 0,
    };

    const write_mask: vulkan.VkColorComponentFlags = @intCast(
        vulkan.VK_COLOR_COMPONENT_R_BIT | vulkan.VK_COLOR_COMPONENT_G_BIT |
            vulkan.VK_COLOR_COMPONENT_B_BIT | vulkan.VK_COLOR_COMPONENT_A_BIT,
    );
    // Blending off, so a covered pixel is the fragment's own value and not a
    // combination with the clear.
    const blend_attachment: vulkan.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = 0,
        .srcColorBlendFactor = @intCast(vulkan.VK_BLEND_FACTOR_ONE),
        .dstColorBlendFactor = @intCast(vulkan.VK_BLEND_FACTOR_ZERO),
        .colorBlendOp = @intCast(vulkan.VK_BLEND_OP_ADD),
        .srcAlphaBlendFactor = @intCast(vulkan.VK_BLEND_FACTOR_ONE),
        .dstAlphaBlendFactor = @intCast(vulkan.VK_BLEND_FACTOR_ZERO),
        .alphaBlendOp = @intCast(vulkan.VK_BLEND_OP_ADD),
        .colorWriteMask = write_mask,
    };
    const color_blend: vulkan.VkPipelineColorBlendStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .logicOpEnable = 0,
        .logicOp = @intCast(vulkan.VK_LOGIC_OP_COPY),
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };

    const create_info: vulkan.VkGraphicsPipelineCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blend,
        .pDynamicState = null,
        .layout = scene.pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var pipeline: vulkan.VkPipeline = null;
    try dispatch.checkVkSuccess((procs.create_graphics_pipelines orelse
        return error.DeviceProcMissing)(vk_device, null, 1, &create_info, null, &pipeline));
    if (pipeline == null) return error.HandleCreationReturnedNull;
    return pipeline;
}

// --- Helpers ----------------------------------------------------------------

/// The checked-in fixture's bytes as SPIR-V words.
///
/// `@embedFile` yields a byte array whose alignment is one and a
/// `VkShaderModule` wants `u32` words, so the words are assembled a byte at a
/// time. An `@alignCast` would be a claim about the linker's layout that nothing
/// in this repository has measured.
///
/// The parameter is `comptime` because both fixtures are compile-time
/// constants, and the length of a stack array is not: a `[bytes.len / 4]u32`
/// written at run time asks for a frame-sized allocation out of a value the
/// compiler cannot know. Decoding at compile time removes the question — the
/// result is a constant with `u32` alignment that outlives every module naming
/// it — and it is where a fixture whose length is not a whole number of words
/// is caught instead of having its trailing bytes dropped by the division.
fn decodeWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    if (bytes.len % 4 != 0) @compileError("a SPIR-V fixture is a whole number of words");

    var words: [bytes.len / 4]u32 = undefined;
    for (&words, 0..) |*word, index| {
        const at = index * 4;
        word.* = @as(u32, bytes[at]) |
            (@as(u32, bytes[at + 1]) << 8) |
            (@as(u32, bytes[at + 2]) << 16) |
            (@as(u32, bytes[at + 3]) << 24);
    }
    return words;
}

/// Asserts that a module's own words carry the entry point the pipeline names.
///
/// An `OpEntryPoint` literal string is four bytes per word inside the same word
/// stream as the code, so the name is found as plain bytes. This is a check on
/// the fixture, not a parser: it does not need to be right about anything but
/// presence, because the driver's own validation is what has to be satisfied.
fn checkEntryPoint(words: []const u32, entry_point: []const u8) SetupError!void {
    if (std.mem.indexOf(u8, std.mem.sliceAsBytes(words), entry_point) == null) {
        return error.EntryPointNameAbsent;
    }
}

/// Writes the tint into the uniform buffer through a host mapping.
fn writeTint(device: vulkan_device.Device, memory: vulkan.VkDeviceMemory) SetupError!void {
    const procs = device.procs;
    const bytes = try mapMemory(device, memory, uniform_byte_count);
    defer (procs.unmap_memory orelse unreachable)(device.vk_device, memory);

    @memcpy(bytes[0..@intCast(uniform_byte_count)], std.mem.asBytes(&tint));
}

/// Maps the staging allocation for the whole submission.
///
/// The mapping outlives the wait, so the copy never has to be invalidated: the
/// allocation is coherent and the fence the shard waited on is the fence that
/// submission signalled.
fn mapStaging(
    device: vulkan_device.Device,
    memory: vulkan.VkDeviceMemory,
) SetupError![]u8 {
    const bytes = try mapMemory(device, memory, readback_byte_count);
    return bytes[0..readback_byte_count];
}

/// Unmaps what `mapStaging` mapped.
fn unmapStaging(device: vulkan_device.Device, memory: vulkan.VkDeviceMemory) void {
    (device.procs.unmap_memory orelse unreachable)(device.vk_device, memory);
}

/// Maps the first `size` bytes of an allocation.
///
/// The flags are zero rather than `VK_MEMORY_MAP_READ_BIT`, because the
/// allocation this shard maps is coherent and the checked-in bindings carry no
/// such constant to name.
fn mapMemory(
    device: vulkan_device.Device,
    memory: vulkan.VkDeviceMemory,
    size: vulkan.VkDeviceSize,
) SetupError![*]u8 {
    var mapped: ?*anyopaque = null;
    try dispatch.checkVkSuccess((device.procs.map_memory orelse
        return error.DeviceProcMissing)(device.vk_device, memory, 0, size, 0, &mapped));
    return @ptrCast(mapped orelse return error.MapReturnedNull);
}

/// One whole-image layout transition.
///
/// One `vkCmdPipelineBarrier` with one image barrier and no memory barrier and
/// no buffer barrier, the mirror of what `emitBufferBarrierIfNecessary` does for
/// the host-to-fragment barrier.
fn imageBarrier(
    procs: *const dispatch.DeviceProcs,
    command_buffer: vulkan.VkCommandBuffer,
    image: vulkan.VkImage,
    old_layout: vulkan.VkImageLayout,
    new_layout: vulkan.VkImageLayout,
    src_stage: vulkan.VkPipelineStageFlags,
    dst_stage: vulkan.VkPipelineStageFlags,
    src_access: vulkan.VkAccessFlags,
    dst_access: vulkan.VkAccessFlags,
) void {
    const barrier: vulkan.VkImageMemoryBarrier = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER),
        .pNext = null,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        // The image never changes owner, so both families are ignored rather
        // than named as the exclusive family.
        .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = @intCast(vulkan.VK_IMAGE_ASPECT_COLOR_BIT),
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    (procs.cmd_pipeline_barrier orelse unreachable)(
        command_buffer,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

// Keep the bitmask type named here rather than reached through a chain, so a
// reader can see which usage words the eager-transition assertion compares.
comptime {
    if (@TypeOf(BufferUsage) != type) @compileError("the usage bitmask is a type");
}
