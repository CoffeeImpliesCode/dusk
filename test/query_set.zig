//! The M19 shard: an occlusion query counts the samples a draw passes.
//!
//! **What the acceptance names.** `docs/40-plan.md` §1 `### M19` asks for two
//! numbers: a draw covering the whole 2x2 target counts exactly 4 samples, and
//! a draw the scissor clips away entirely counts 0. Both are rasterised by the
//! driver in this file and read back through the copy the port's resolve plans,
//! so neither number is one this file wrote down.
//!
//! **Why the fixture leaves clip space.** `test/fixtures/occlusion.vert.wgsl`
//! puts two of its three corners outside clip space, so the hypotenuse crosses
//! the target instead of stopping short of it, and a 2x2 target at one sample
//! per pixel passes one sample per pixel. The M18 triangle covers two of the
//! four pixel centres (§3.3 M18 says so) and cannot stand in here.
//!
//! **Where the Vulkan comes from.** `src/engine/vulkan_query_set.zig` and
//! `src/engine/command_buffer.zig` are not on disk, so nothing in the library
//! creates the `VkQueryPool` or records the pass yet. This file drives the
//! dispatch table itself for that half, the way `test/vulkan_device.zig` drives
//! `vkCmdFillBuffer`, and it records the commands `RecordRenderPass`
//! (`CommandBufferVk.cpp:1727`) records for `Command::BeginOcclusionQuery`
//! (`:2125-2132`) and `Command::EndOcclusionQuery` (`:2134-2142`). The front
//! end — the object, its availability bitmap and the resolve plan — is reached
//! through `@import("dusk")` and carries the other tests here.
//!
//! **What this file does not claim.** It does not claim the timestamp
//! conversion of `native/QueryHelper.{h,cpp}`: an occlusion set returns from
//! `APIResolveQuerySet` (`CommandEncoder.cpp:2334-2336`) before that path, and
//! §3.3's M19 table carries those three rows as `skip` with that reason. It
//! does not claim a count on a multisampled target: this target is one sample
//! per pixel, which is the only count the acceptance names.
//!
//! **The gate line's filter.** §1 M19 is `zig build test -- test-query-set`, and
//! the runner's positional argument is a name filter, so every test here is
//! named `test-query-set: ...` and the filter selects all of them.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const command_query = dusk.command.query;
const query_set = dusk.engine.query_set;
const vulkan_device = dusk.engine.vulkan_device;
const submission = dusk.engine.queue;
const spirv = dusk.spirv;
const dispatch = dusk.vk.dispatch;
const platform = dusk.platform;
const vulkan = dusk.platform.vulkan_bindings;

// --- The target and the two draws -------------------------------------------

/// The target is two pixels by two pixels, so a draw that covers all of it
/// passes exactly one sample per pixel at the one sample the attachment has.
const target_width: u32 = 2;
const target_height: u32 = 2;

/// The set holds one query per draw: the covered one and the clipped one.
const query_count: u32 = 2;

/// Which query the two draws write. Index zero is the covering draw because it
/// is recorded first, and a resolve reads a set in index order.
const covering_query: u32 = 0;
const clipped_query: u32 = 1;

/// The three vertices the fixture triangle has
/// (`test/fixtures/occlusion.vert.wgsl:9-13`).
const triangle_vertex_count: u32 = 3;

/// The samples the acceptance names. Both are computed, never written.
const covering_sample_count: u64 = target_width * target_height;
const clipped_sample_count: u64 = 0;

/// `kSingleQueryStorageSize` (`QuerySet.h:42`), which the port names
/// `single_query_storage_size`. The copy's stride and every destination offset
/// the plan hands out are multiples of it.
const query_storage_size: u64 = command_query.single_query_storage_size;

/// The bytes one resolve of the whole set writes.
const resolve_size: u64 = query_storage_size * query_count;

// --- The shader fixtures ----------------------------------------------------

const vertex_fixture: []const u8 = @embedFile("fixtures/occlusion.vert.spv");
const fragment_fixture: []const u8 = @embedFile("fixtures/occlusion.frag.spv");

/// The entry points `test/fixtures/occlusion.*.wgsl` declare. `pName` is a C
/// string, so these are the sentinel-typed literals the pipeline takes, and the
/// last test reflects the modules by the same names.
const vertex_entry_point = "vs_main";
const fragment_entry_point = "fs_main";

// --- The raster state the two draws share -----------------------------------

/// The whole target. The pipeline declares the viewport dynamic, so the value
/// recorded per draw is this one rather than the static default.
const full_viewport: vulkan.VkViewport = .{
    .x = 0,
    .y = 0,
    .width = @floatFromInt(target_width),
    .height = @floatFromInt(target_height),
    .minDepth = 0,
    .maxDepth = 1,
};

/// The render area, which is also the scissor of the covering draw: every pixel
/// of the target is inside it, so the draw is not clipped and each pixel passes
/// its one sample.
const render_area_rect: vulkan.VkRect2D = .{
    .offset = .{ .x = 0, .y = 0 },
    .extent = .{ .width = target_width, .height = target_height },
};

/// A rectangle of the target's own size whose offset is the target's far
/// corner, so it shares no pixel with the render area.
///
/// `vkCmdSetScissor` asks only that the offset be non-negative and the extent
/// non-negative (`VUID-vkCmdSetScissor-x-02009`, `-y-02010`); nothing requires
/// the rectangle to intersect the framebuffer. The effective scissor is the
/// intersection with the render area, which is empty here, so the draw is
/// clipped away whole and no sample passes.
const clipped_rect: vulkan.VkRect2D = .{
    .offset = .{ .x = @intCast(target_width), .y = @intCast(target_height) },
    .extent = .{ .width = target_width, .height = target_height },
};

/// The colour the pass clears to. An occlusion count does not read a colour, so
/// the value only has to be one the attachment accepts.
const clear_colour: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };

/// Dawn opens an occlusion query with no control flags
/// (`CommandBufferVk.cpp:2130`), so this file opens both queries with none
/// either. The count is still exact: the attachment has no depth or stencil
/// test for an imprecise count to over-estimate, and the fragment stage never
/// discards.
const no_query_control_flags: vulkan.VkQueryControlFlags = 0;

/// The result flags the resolve copy carries: 64-bit results, and a wait rather
/// than a not-ready status.
const query_result_flags: vulkan.VkQueryResultFlags =
    @intCast(vulkan.VK_QUERY_RESULT_64_BIT | vulkan.VK_QUERY_RESULT_WAIT_BIT);

const color_attachment_usage: vulkan.VkImageUsageFlags =
    @intCast(vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
const transfer_destination_usage: vulkan.VkBufferUsageFlags =
    @intCast(vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
const device_local_memory: vulkan.VkMemoryPropertyFlags =
    @intCast(vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
const host_memory: vulkan.VkMemoryPropertyFlags = @intCast(
    vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
);
const color_aspect: vulkan.VkImageAspectFlags =
    @intCast(vulkan.VK_IMAGE_ASPECT_COLOR_BIT);
const every_channel: vulkan.VkColorComponentFlags = @intCast(
    vulkan.VK_COLOR_COMPONENT_R_BIT | vulkan.VK_COLOR_COMPONENT_G_BIT |
        vulkan.VK_COLOR_COMPONENT_B_BIT | vulkan.VK_COLOR_COMPONENT_A_BIT,
);

/// What building and running the pass can refuse.
///
/// Every library set the calls below reach is named here, so a reader
/// enumerates this shard's failure modes from one line, and the members that
/// are this file's own are named rather than folded into a driver code.
const PassError = vulkan_device.ProcError ||
    vulkan_device.Device.CreateError ||
    vulkan_device.Backend.DiscoverError ||
    vulkan_device.AdapterList.FirstError ||
    vulkan_device.MemoryTypeError ||
    submission.Queue.InitError ||
    submission.Queue.SubmitError ||
    submission.Queue.WaitError ||
    spirv.Error ||
    std.mem.Allocator.Error ||
    error{
        /// A create call succeeded and returned a null handle, which
        /// `vkCreateImage` and its siblings are allowed to do.
        HandleCreationReturnedNull,
        /// `vkCreateGraphicsPipelines` succeeded and returned no pipeline.
        PipelineCreationReturnedNull,
        /// `vkMapMemory` succeeded and returned no pointer.
        MapReturnedNull,
        /// The adapter the search took reports a version below the one
        /// `required_vulkan_version` names, which `discoverPhysicalDevices`
        /// filters on (`VulkanInfo.cpp:247`).
        VulkanVersionUnsupported,
        /// No memory type is legal for the image or the destination, so there
        /// is nothing to bind.
        NoMemoryType,
        /// The fence reported signalled for a serial it does not carry.
        FenceNotSignalled,
        /// The fence wait returned a serial below the one submitted.
        FenceWaitDidNotReachTheSubmit,
        /// The loader tier did not supply one of the entry points this shard
        /// calls. `dispatch.loadDeviceProcs` refuses with `MissingDeviceProc`
        /// for the same reason (`src/vk/dispatch.zig:1055`), and `AGENTS.md`
        /// §3.1 makes a missing entry point an error rather than a panic.
        MissingProc,
    };

/// Names the entry point the device tier did not supply, and returns the typed
/// error the caller propagates.
///
/// `error.MissingProc` carries no call, so the symbol goes to the log beside
/// it: the shard fails on the returned error either way, so the log adds the
/// name without deciding the outcome. The argument is the symbol without its
/// `vk` prefix.
fn missingProc(symbol_name: []const u8) PassError {
    std.log.err("missing entry point: vk{s}", .{symbol_name});
    return error.MissingProc;
}

/// The callable `Proc` names, with the optional the generated bindings carry.
///
/// `zig translate-c` types every `PFN_vk*` as an optional function pointer
/// (`src/vulkan.zig:5111`), and `dispatch.DeviceProcs` holds one of those, so a
/// field of that table is an optional of an optional and one `orelse` still
/// leaves an optional underneath. A struct that means to hold an entry point it
/// has already resolved names the type below that one, per entry point, because
/// the signatures differ.
fn Entry(comptime Proc: type) type {
    return @typeInfo(Proc).optional.child;
}

/// The two counts the acceptance names, indexed by query.
const Counts = struct {
    covering: u64,
    clipped: u64,

    fn of(values: [query_count]u64) Counts {
        return .{
            .covering = values[covering_query],
            .clipped = values[clipped_query],
        };
    }
};

// ---------------------------------------------------------------------------
// The acceptance: two draws, two queries, one resolve.
// ---------------------------------------------------------------------------

test "test-query-set: the covering draw counts 4 samples, the clipped draw counts 0" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var handles: vulkan_device.HandleSet = .{};
    var device_mutex: platform.DeviceMutex = .{};

    const counts = try runPass(threaded.io(), &handles, &device_mutex);

    // The two assertions the acceptance names, and nothing softer than an
    // equality: a count of 2 or 8 would also be a rasterised answer, and only
    // one of them is the whole target.
    try std.testing.expectEqual(covering_sample_count, counts.covering);
    try std.testing.expectEqual(clipped_sample_count, counts.clipped);
    try std.testing.expectEqual(@as(u64, 4), counts.covering);
    try std.testing.expectEqual(@as(u64, 0), counts.clipped);

    // Every handle the shard counted through the library's own table is gone.
    // The image, the view, the pass, the framebuffer, the two modules, the
    // layout, the pipeline and the pool are not in `HandleKind`
    // (`src/engine/vulkan_device.zig:101-109`), so they cannot be counted here; they are
    // destroyed in reverse creation order instead.
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?vulkan_device.HandleKind, null), handles.firstLeakedKind());
}

/// Records the whole pass on a real driver and reads the two counts back.
///
/// The pass is torn down by the statements at the end, not by `defer`s, because
/// `Queue::deinit`, `Device::deinit` and `Backend::deinit` report rather than
/// returning `void` (`AGENTS.md` §3.1) and a `defer` cannot hand an error back.
/// The leak assertion belongs to the caller, which reads it after this returns.
fn runPass(
    io: std.Io,
    handles: *vulkan_device.HandleSet,
    device_mutex: *platform.DeviceMutex,
) PassError!Counts {
    // Fallback adapter first, then the system ICD
    // (`vulkan_device.icd_search_order`, `BackendVk.cpp:590`-`:607`). The search
    // skips an ICD whose library will not open and an ICD that reports no
    // device, so the adapter taken may come from either entry.
    var backend = vulkan_device.Backend.init(std.testing.allocator, .{ .handles = handles });

    var adapters = try backend.discoverPhysicalDevices(.{});
    const adapter = try adapters.first();
    if (!adapter.physical.supportsRequiredVersion()) return error.VulkanVersionUnsupported;

    var device = try vulkan_device.Device.create(std.testing.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = handles,
    });

    // `Queue::Initialize` takes a pool and begins the one recording context
    // (`QueueVk.cpp:93-101`), so the pass records without a begin of its own.
    var q = try submission.Queue.init(.{
        .context = .{
            .allocator = std.testing.allocator,
            .dispatch = device.dispatchTable(),
            .vk_device = device.vk_device,
            .vk_queue = try device.fetchQueue(),
            .queue_family_index = device.queue_family_index,
            .memory_properties = device.memoryProperties(),
            .handles = handles,
        },
        .device_mutex = device_mutex,
    });
    var pass = try Pass.create(&device);

    try pass.record(&device, &q);
    try pass.submitAndRead(io, &device, &q);
    const counts = Counts.of(pass.counts);

    // Reverse of the order above: the pass, then the queue that ran its command
    // buffer, then the device, then the adapter list it points into, then the
    // backend that cached the instance.
    pass.deinit(&device);
    try q.deinit();
    try device.deinit(std.testing.allocator);
    adapters.deinit();
    try backend.deinit();
    return counts;
}

/// Everything one recorded pass owns.
///
/// The handles are fields and not locals because the destroys in `deinit` are
/// the reverse of the creates in `create`, and a local per handle would put
/// that order in the reader's head. Every handle field starts null, so the
/// `errdefer` of `create` and the teardown in `runPass` are the same walk.
///
/// `destroys` is a field because `deinit` is reached by `errdefer` and by the
/// teardown statement, and a `defer` cannot hand an error back: `create` is
/// where the table resolves them, because it is where there is an error to
/// report.
const Pass = struct {
    image: vulkan.VkImage = null,
    image_memory: vulkan.VkDeviceMemory = null,
    view: vulkan.VkImageView = null,
    render_pass: vulkan.VkRenderPass = null,
    framebuffer: vulkan.VkFramebuffer = null,
    vertex_module: vulkan.VkShaderModule = null,
    fragment_module: vulkan.VkShaderModule = null,
    layout: vulkan.VkPipelineLayout = null,
    pipeline: vulkan.VkPipeline = null,
    pool: vulkan.VkQueryPool = null,
    destination: vulkan.VkBuffer = null,
    destination_memory: vulkan.VkDeviceMemory = null,
    /// The resolve destination, read once the fence has signalled.
    counts: [query_count]u64 = @splat(0),
    /// The destroy entry points `deinit` calls, resolved by `create`.
    destroys: DestroyProcs,

    fn create(device: *const vulkan_device.Device) PassError!Pass {
        var pass: Pass = .{ .destroys = try DestroyProcs.resolve(device.procs) };
        const attachment = try createColorAttachment(device);
        pass.image = attachment.image;
        pass.image_memory = attachment.memory;
        errdefer pass.deinit(device);

        pass.view = try createView(device, pass.image);
        pass.render_pass = try createRenderPass(device);
        pass.framebuffer = try createFramebuffer(device, pass.render_pass, pass.view);
        pass.vertex_module = try createShaderModule(device, vertex_fixture);
        pass.fragment_module = try createShaderModule(device, fragment_fixture);
        pass.layout = try createPipelineLayout(device);
        pass.pipeline = try createPipeline(
            device,
            pass.render_pass,
            pass.layout,
            pass.vertex_module,
            pass.fragment_module,
        );
        pass.pool = try createQueryPool(device);
        pass.destination = try createResolveDestination(device);
        pass.destination_memory = try attachMemory(device, pass.destination);
        return pass;
    }

    /// Destroys every handle this pass holds, in the reverse of the order
    /// `create` took them. A field that is still null was never created, which
    /// is what makes one walk correct for a partial create and a whole one.
    ///
    /// Every entry point it calls is core Vulkan 1.0, so a missing one is a
    /// broken loader and not a capability gap; `create` has already refused
    /// with `MissingProc` if there was one.
    fn deinit(self: *Pass, device: *const vulkan_device.Device) void {
        const vk_device = device.vk_device;
        const destroy_buffer = self.destroys.destroy_buffer;
        const free_memory = self.destroys.free_memory;
        const destroy_query_pool = self.destroys.destroy_query_pool;
        const destroy_pipeline = self.destroys.destroy_pipeline;
        const destroy_pipeline_layout = self.destroys.destroy_pipeline_layout;
        const destroy_shader_module = self.destroys.destroy_shader_module;
        const destroy_framebuffer = self.destroys.destroy_framebuffer;
        const destroy_render_pass = self.destroys.destroy_render_pass;
        const destroy_image_view = self.destroys.destroy_image_view;
        const destroy_image = self.destroys.destroy_image;

        if (self.destination) |buffer| {
            destroy_buffer(vk_device, buffer, null);
            device.handles.release(.buffer);
            self.destination = null;
        }
        if (self.destination_memory) |memory| {
            free_memory(vk_device, memory, null);
            device.handles.release(.memory);
            self.destination_memory = null;
        }
        if (self.pool) |pool| destroy_query_pool(vk_device, pool, null);
        if (self.pipeline) |pipeline| destroy_pipeline(vk_device, pipeline, null);
        if (self.layout) |layout| destroy_pipeline_layout(vk_device, layout, null);
        if (self.fragment_module) |module| destroy_shader_module(vk_device, module, null);
        if (self.vertex_module) |module| destroy_shader_module(vk_device, module, null);
        if (self.framebuffer) |framebuffer| {
            destroy_framebuffer(vk_device, framebuffer, null);
        }
        if (self.render_pass) |render_pass| {
            destroy_render_pass(vk_device, render_pass, null);
        }
        if (self.view) |view| destroy_image_view(vk_device, view, null);
        if (self.image) |image| destroy_image(vk_device, image, null);
        if (self.image_memory) |memory| {
            free_memory(vk_device, memory, null);
            device.handles.release(.memory);
            self.image_memory = null;
        }
        self.* = undefined;
    }

    fn record(
        self: *const Pass,
        device: *const vulkan_device.Device,
        q: *submission.Queue,
    ) PassError!void {
        const procs = device.procs;
        const cmd = q.commandBuffer();

        // Every entry point the recording below calls, resolved once and up
        // here so each record reads a field that cannot be null. All of them
        // are core Vulkan 1.0, so a missing one is a broken loader and not a
        // capability gap.
        const cmd_reset_query_pool = procs.cmd_reset_query_pool orelse
            return missingProc("CmdResetQueryPool");
        const cmd_begin_render_pass = procs.cmd_begin_render_pass orelse
            return missingProc("CmdBeginRenderPass");
        const cmd_bind_pipeline = procs.cmd_bind_pipeline orelse
            return missingProc("CmdBindPipeline");
        const cmd_begin_query = procs.cmd_begin_query orelse return missingProc("CmdBeginQuery");
        const cmd_set_viewport = procs.cmd_set_viewport orelse
            return missingProc("CmdSetViewport");
        const cmd_set_scissor = procs.cmd_set_scissor orelse return missingProc("CmdSetScissor");
        const cmd_draw = procs.cmd_draw orelse return missingProc("CmdDraw");
        const cmd_end_query = procs.cmd_end_query orelse return missingProc("CmdEndQuery");
        const cmd_end_render_pass = procs.cmd_end_render_pass orelse
            return missingProc("CmdEndRenderPass");
        const cmd_copy_query_pool_results = procs.cmd_copy_query_pool_results orelse
            return missingProc("CmdCopyQueryPoolResults");

        // The reset precedes the pass and never sits inside it
        // (`ResetUsedQuerySetsOnRenderPass`, `CommandBufferVk.cpp:544-571`,
        // called at `:1146`): a reset between two begin/end pairs in one pass
        // is invalid usage.
        cmd_reset_query_pool(cmd, self.pool, 0, query_count);

        var clear: vulkan.VkClearValue = .{ .color = .{ .float32 = clear_colour } };
        const begin: vulkan.VkRenderPassBeginInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO),
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = render_area_rect,
            .clearValueCount = 1,
            .pClearValues = &clear,
        };
        cmd_begin_render_pass(cmd, &begin, @intCast(vulkan.VK_SUBPASS_CONTENTS_INLINE));
        const bind_point: vulkan.VkPipelineBindPoint =
            @intCast(vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS);
        cmd_bind_pipeline(cmd, bind_point, self.pipeline);

        // Query zero: the scissor is the render area, so every pixel of the
        // target is inside it and the draw passes one sample per pixel.
        cmd_begin_query(cmd, self.pool, covering_query, no_query_control_flags);
        cmd_set_viewport(cmd, 0, 1, &full_viewport);
        cmd_set_scissor(cmd, 0, 1, &render_area_rect);
        cmd_draw(cmd, triangle_vertex_count, 1, 0, 0);
        cmd_end_query(cmd, self.pool, covering_query);

        // Query one: the same draw, the same pipeline and the same viewport,
        // with a scissor that shares no pixel with the render area.
        cmd_begin_query(cmd, self.pool, clipped_query, no_query_control_flags);
        cmd_set_viewport(cmd, 0, 1, &full_viewport);
        cmd_set_scissor(cmd, 0, 1, &clipped_rect);
        cmd_draw(cmd, triangle_vertex_count, 1, 0, 0);
        cmd_end_query(cmd, self.pool, clipped_query);

        cmd_end_render_pass(cmd);

        // The copy the resolve plans: both queries, the whole destination, the
        // stride `single_query_storage_size` names, and a wait so the result is
        // written before the submission ends. `VK_QUERY_RESULT_WAIT_BIT` is
        // legal only outside a render pass, which is where this sits.
        cmd_copy_query_pool_results(
            cmd,
            self.pool,
            0,
            query_count,
            self.destination,
            0,
            query_storage_size,
            query_result_flags,
        );
    }

    fn submitAndRead(
        self: *Pass,
        io: std.Io,
        device: *const vulkan_device.Device,
        q: *submission.Queue,
    ) PassError!void {
        // `submit` ends the command buffers it is handed
        // (`QueueVk.cpp:323`), which is what the recording context needs.
        const submitted = try q.submit(.{ .command_buffers = &.{q.commandBuffer()} });
        // `Queue.wait` threads `io` first, so Zig does not bind it as a member
        // and `q.wait(io, ...)` would pass the queue where `io` is named. The
        // qualified call is what puts `io` in the parameter the signature names
        // (`src/engine/queue.zig:366`).
        const completed = try submission.Queue.wait(io, q, .{
            .serial = submitted.serial,
            .timeout_ns = submission.fence_wait_timeout_ns,
        });
        if (completed < submitted.serial) return error.FenceWaitDidNotReachTheSubmit;
        // `Queue::fenceStatus` reports rather than returning the code, because it
        // reaches a dispatch proc to read it (`AGENTS.md` §3.1).
        if (try q.fenceStatus(submitted.fence) != vulkan.VK_SUCCESS) {
            return error.FenceNotSignalled;
        }

        const map_memory = device.procs.map_memory orelse return missingProc("MapMemory");
        const unmap_memory = device.procs.unmap_memory orelse return missingProc("UnmapMemory");

        var mapped: ?*anyopaque = null;
        try dispatch.checkVkSuccess(map_memory(
            device.vk_device,
            self.destination_memory,
            0,
            resolve_size,
            0,
            &mapped,
        ));
        defer unmap_memory(device.vk_device, self.destination_memory);
        const bytes: [*]const u8 = @ptrCast(mapped orelse return error.MapReturnedNull);

        // One query per slot, at the stride the copy recorded. A result is a
        // `uint64_t` in the machine's own byte order, and every target the gate
        // runs on is little-endian.
        var index: u32 = 0;
        while (index < query_count) : (index += 1) {
            const at = index * query_storage_size;
            self.counts[index] = std.mem.readInt(
                u64,
                bytes[at..][0..@sizeOf(u64)],
                .little,
            );
        }
    }
};
/// The destroy entry points `Pass.deinit` calls, with none of them optional.
///
/// `dispatch.DeviceProcs` holds every entry point as an optional because the
/// loader tier fills only what the enabled extensions carry
/// (`src/vk/dispatch.zig:1068`-`:1069`). `deinit` is reached by an `errdefer`
/// and by the teardown statement, and a `defer` cannot hand an error back, so
/// the refusal is raised here instead: once, where the table arrives.
const DestroyProcs = struct {
    destroy_buffer: Entry(vulkan.PFN_vkDestroyBuffer),
    free_memory: Entry(vulkan.PFN_vkFreeMemory),
    destroy_query_pool: Entry(vulkan.PFN_vkDestroyQueryPool),
    destroy_pipeline: Entry(vulkan.PFN_vkDestroyPipeline),
    destroy_pipeline_layout: Entry(vulkan.PFN_vkDestroyPipelineLayout),
    destroy_shader_module: Entry(vulkan.PFN_vkDestroyShaderModule),
    destroy_framebuffer: Entry(vulkan.PFN_vkDestroyFramebuffer),
    destroy_render_pass: Entry(vulkan.PFN_vkDestroyRenderPass),
    destroy_image_view: Entry(vulkan.PFN_vkDestroyImageView),
    destroy_image: Entry(vulkan.PFN_vkDestroyImage),

    fn resolve(procs: *const dispatch.DeviceProcs) PassError!DestroyProcs {
        return .{
            .destroy_buffer = procs.destroy_buffer orelse
                return missingProc("DestroyBuffer"),
            .free_memory = procs.free_memory orelse return missingProc("FreeMemory"),
            .destroy_query_pool = procs.destroy_query_pool orelse
                return missingProc("DestroyQueryPool"),
            .destroy_pipeline = procs.destroy_pipeline orelse
                return missingProc("DestroyPipeline"),
            .destroy_pipeline_layout = procs.destroy_pipeline_layout orelse
                return missingProc("DestroyPipelineLayout"),
            .destroy_shader_module = procs.destroy_shader_module orelse
                return missingProc("DestroyShaderModule"),
            .destroy_framebuffer = procs.destroy_framebuffer orelse
                return missingProc("DestroyFramebuffer"),
            .destroy_render_pass = procs.destroy_render_pass orelse
                return missingProc("DestroyRenderPass"),
            .destroy_image_view = procs.destroy_image_view orelse
                return missingProc("DestroyImageView"),
            .destroy_image = procs.destroy_image orelse return missingProc("DestroyImage"),
        };
    }
};

/// The image and the memory behind it.
const Attachment = struct {
    image: vulkan.VkImage,
    memory: vulkan.VkDeviceMemory,
};

fn createColorAttachment(device: *const vulkan_device.Device) PassError!Attachment {
    const procs = device.procs;
    const vk_device = device.vk_device;

    // Every entry point this helper calls, resolved once and up here so each
    // call below reads a field that cannot be null. All of them are core
    // Vulkan 1.0.
    const create_image = procs.create_image orelse return missingProc("CreateImage");
    const destroy_image = procs.destroy_image orelse return missingProc("DestroyImage");
    const get_image_memory_requirements = procs.get_image_memory_requirements orelse
        return missingProc("GetImageMemoryRequirements");
    const free_memory = procs.free_memory orelse return missingProc("FreeMemory");
    const bind_image_memory = procs.bind_image_memory orelse
        return missingProc("BindImageMemory");

    const info: vulkan.VkImageCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO),
        .format = @intCast(vulkan.VK_FORMAT_R8G8B8A8_UNORM),
        .imageType = @intCast(vulkan.VK_IMAGE_TYPE_2D),
        .extent = .{ .width = target_width, .height = target_height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
        .tiling = @intCast(vulkan.VK_IMAGE_TILING_OPTIMAL),
        .usage = color_attachment_usage,
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
        // The pass clears from undefined, so the first draw needs no barrier
        // and no staging copy in front of it.
        .initialLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
    };
    var image: vulkan.VkImage = null;
    try dispatch.checkVkSuccess(create_image(vk_device, &info, null, &image));
    if (image == null) return error.HandleCreationReturnedNull;
    errdefer destroy_image(vk_device, image, null);

    // SAFETY: `vkGetImageMemoryRequirements` is an out-parameter call: the
    // driver writes every field before the statement returns, and the `if`
    // below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    get_image_memory_requirements(vk_device, image, &requirements);
    if (requirements.memoryTypeBits == 0) return error.NoMemoryType;

    const memory = try allocateMemory(device, requirements, device_local_memory);
    errdefer device.handles.release(.memory);
    errdefer free_memory(vk_device, memory, null);
    try dispatch.checkVkSuccess(bind_image_memory(vk_device, image, memory, 0));
    return .{ .image = image, .memory = memory };
}

fn createView(
    device: *const vulkan_device.Device,
    image: vulkan.VkImage,
) PassError!vulkan.VkImageView {
    const create_image_view = device.procs.create_image_view orelse
        return missingProc("CreateImageView");
    const info: vulkan.VkImageViewCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO),
        .image = image,
        .viewType = @intCast(vulkan.VK_IMAGE_VIEW_TYPE_2D),
        .format = @intCast(vulkan.VK_FORMAT_R8G8B8A8_UNORM),
        .subresourceRange = .{
            .aspectMask = color_aspect,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var view: vulkan.VkImageView = null;
    try dispatch.checkVkSuccess(create_image_view(
        device.vk_device,
        &info,
        null,
        &view,
    ));
    if (view == null) return error.HandleCreationReturnedNull;
    return view;
}

fn createRenderPass(device: *const vulkan_device.Device) PassError!vulkan.VkRenderPass {
    const create_render_pass = device.procs.create_render_pass orelse
        return missingProc("CreateRenderPass");
    // Core 1.0 structs, not the `2` variants. `device.procs` is
    // `dispatch.DeviceProcs`, the core 1.0 table, and `vkCreateRenderPass` is
    // the only render-pass create call on it. `vkCreateRenderPass2` lives in
    // the promoted block behind `VK_KHR_create_renderpass2`
    // (`src/vk/dispatch.zig:266`), which this shard never enables. Both
    // spellings describe the same one-colour subpass.
    const attachment: vulkan.VkAttachmentDescription = .{
        .format = @intCast(vulkan.VK_FORMAT_R8G8B8A8_UNORM),
        .samples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
        .loadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR),
        .storeOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_STORE),
        .stencilLoadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
        .stencilStoreOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE),
        .initialLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
        // Nothing reads the target back, so the final layout is one every
        // access is legal in rather than a transition the test does not make.
        .finalLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_GENERAL),
    };
    const color: vulkan.VkAttachmentReference = .{
        .attachment = 0,
        .layout = @intCast(vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
    };
    const subpass: vulkan.VkSubpassDescription = .{
        .pipelineBindPoint = @intCast(vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS),
        .colorAttachmentCount = 1,
        .pColorAttachments = &color,
    };
    const info: vulkan.VkRenderPassCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO),
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
    };
    var render_pass: vulkan.VkRenderPass = null;
    try dispatch.checkVkSuccess(create_render_pass(
        device.vk_device,
        &info,
        null,
        &render_pass,
    ));
    if (render_pass == null) return error.HandleCreationReturnedNull;
    return render_pass;
}

fn createFramebuffer(
    device: *const vulkan_device.Device,
    render_pass: vulkan.VkRenderPass,
    view: vulkan.VkImageView,
) PassError!vulkan.VkFramebuffer {
    const create_framebuffer = device.procs.create_framebuffer orelse
        return missingProc("CreateFramebuffer");
    const attachments = [1]vulkan.VkImageView{view};
    const info: vulkan.VkFramebufferCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO),
        .renderPass = render_pass,
        .attachmentCount = 1,
        .pAttachments = &attachments,
        .width = target_width,
        .height = target_height,
        .layers = 1,
    };
    var framebuffer: vulkan.VkFramebuffer = null;
    try dispatch.checkVkSuccess(create_framebuffer(
        device.vk_device,
        &info,
        null,
        &framebuffer,
    ));
    if (framebuffer == null) return error.HandleCreationReturnedNull;
    return framebuffer;
}

fn createShaderModule(
    device: *const vulkan_device.Device,
    fixture: []const u8,
) PassError!vulkan.VkShaderModule {
    const create_shader_module = device.procs.create_shader_module orelse
        return missingProc("CreateShaderModule");
    const words = try spirv.wordsFromBytes(std.testing.allocator, fixture);
    defer std.testing.allocator.free(words);

    // The port validates the caller's words before the driver sees them, and
    // `vkCreateShaderModule` copies them, so the buffer is dead after this.
    try spirv.validate(words);

    const info: vulkan.VkShaderModuleCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO),
        .codeSize = words.len * @sizeOf(u32),
        .pCode = words.ptr,
    };
    var module: vulkan.VkShaderModule = null;
    try dispatch.checkVkSuccess(create_shader_module(
        device.vk_device,
        &info,
        null,
        &module,
    ));
    if (module == null) return error.HandleCreationReturnedNull;
    return module;
}

fn createPipelineLayout(device: *const vulkan_device.Device) PassError!vulkan.VkPipelineLayout {
    const create_pipeline_layout = device.procs.create_pipeline_layout orelse
        return missingProc("CreatePipelineLayout");
    // The fixture fragment stage binds nothing
    // (`test/fixtures/occlusion.frag.wgsl:6`), so the layout is empty and
    // `pSetLayouts` stays null.
    const info: vulkan.VkPipelineLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO),
    };
    var layout: vulkan.VkPipelineLayout = null;
    try dispatch.checkVkSuccess(create_pipeline_layout(
        device.vk_device,
        &info,
        null,
        &layout,
    ));
    if (layout == null) return error.HandleCreationReturnedNull;
    return layout;
}

fn createPipeline(
    device: *const vulkan_device.Device,
    render_pass: vulkan.VkRenderPass,
    layout: vulkan.VkPipelineLayout,
    vertex_module: vulkan.VkShaderModule,
    fragment_module: vulkan.VkShaderModule,
) PassError!vulkan.VkPipeline {
    const create_graphics_pipelines = device.procs.create_graphics_pipelines orelse
        return missingProc("CreateGraphicsPipelines");
    const stages = [2]vulkan.VkPipelineShaderStageCreateInfo{
        .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO),
            .stage = @intCast(vulkan.VK_SHADER_STAGE_VERTEX_BIT),
            .module = vertex_module,
            .pName = vertex_entry_point,
        },
        .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO),
            .stage = @intCast(vulkan.VK_SHADER_STAGE_FRAGMENT_BIT),
            .module = fragment_module,
            .pName = fragment_entry_point,
        },
    };

    // The fixture vertex stage takes `@builtin(vertex_index)` and no vertex
    // buffer, so the binding and attribute counts are both zero.
    const vertex_input: vulkan.VkPipelineVertexInputStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO),
    };
    const input_assembly: vulkan.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO),
        .topology = @intCast(vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST),
    };

    // The viewport and the scissor are dynamic, so the two draws share one
    // pipeline and differ in the rectangle each one sets. The static values are
    // the render area: a driver reads neither, and a static count below one
    // would be invalid usage.
    const viewports = [1]vulkan.VkViewport{full_viewport};
    const scissors = [1]vulkan.VkRect2D{render_area_rect};
    const viewport_state: vulkan.VkPipelineViewportStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO),
        .viewportCount = viewports.len,
        .pViewports = &viewports,
        .scissorCount = scissors.len,
        .pScissors = &scissors,
    };
    const dynamic_states = [2]vulkan.VkDynamicState{
        @intCast(vulkan.VK_DYNAMIC_STATE_VIEWPORT),
        @intCast(vulkan.VK_DYNAMIC_STATE_SCISSOR),
    };
    const dynamic_state: vulkan.VkPipelineDynamicStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO),
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const rasterization: vulkan.VkPipelineRasterizationStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO),
        .polygonMode = @intCast(vulkan.VK_POLYGON_MODE_FILL),
        // The fixture triangle winds once across the whole target; culling it
        // would change the count for a reason that has nothing to do with the
        // query.
        .cullMode = @intCast(vulkan.VK_CULL_MODE_NONE),
        .frontFace = @intCast(vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE),
        .lineWidth = 1.0,
    };
    const multisample: vulkan.VkPipelineMultisampleStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO),
        .rasterizationSamples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
    };
    const blend_attachment: vulkan.VkPipelineColorBlendAttachmentState = .{
        .colorWriteMask = every_channel,
    };
    const color_blend: vulkan.VkPipelineColorBlendStateCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO),
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };

    // No depth-stencil attachment and no tessellation stage, so both states are
    // null rather than zeroed: a driver that reads one of them finds a state
    // that matches the pass.
    const info: vulkan.VkGraphicsPipelineCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO),
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic_state,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
    };
    var pipeline: vulkan.VkPipeline = null;
    try dispatch.checkVkSuccess(create_graphics_pipelines(
        device.vk_device,
        null,
        1,
        &info,
        null,
        &pipeline,
    ));
    if (pipeline == null) return error.PipelineCreationReturnedNull;
    return pipeline;
}

fn createQueryPool(device: *const vulkan_device.Device) PassError!vulkan.VkQueryPool {
    const create_query_pool = device.procs.create_query_pool orelse
        return missingProc("CreateQueryPool");
    // `VulkanQueryType` (`QuerySetVk.cpp:42-50`) maps the two `wgpu` query
    // types onto the two Vulkan ones; the occlusion type is the only one this
    // set has, and the pool takes no `std::max` on the count because
    // `QuerySet.cpp:55-57` refuses a count above the maximum before a set
    // reaches the back end.
    const info: vulkan.VkQueryPoolCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO),
        .queryType = @intCast(vulkan.VK_QUERY_TYPE_OCCLUSION),
        .queryCount = query_count,
    };
    var pool: vulkan.VkQueryPool = null;
    try dispatch.checkVkSuccess(create_query_pool(
        device.vk_device,
        &info,
        null,
        &pool,
    ));
    if (pool == null) return error.HandleCreationReturnedNull;
    return pool;
}

fn createResolveDestination(device: *const vulkan_device.Device) PassError!vulkan.VkBuffer {
    const create_buffer = device.procs.create_buffer orelse return missingProc("CreateBuffer");
    const destroy_buffer = device.procs.destroy_buffer orelse return missingProc("DestroyBuffer");
    const info: vulkan.VkBufferCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO),
        // The destination holds both results at the stride a resolve uses, so
        // it is exactly `ToQueryStorageSize` of the count (`QuerySet.cpp:77`).
        .size = resolve_size,
        .usage = transfer_destination_usage,
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
    };
    var buffer: vulkan.VkBuffer = null;
    try dispatch.checkVkSuccess(create_buffer(
        device.vk_device,
        &info,
        null,
        &buffer,
    ));
    if (buffer == null) return error.HandleCreationReturnedNull;
    device.handles.acquire(.buffer);
    errdefer device.handles.release(.buffer);
    errdefer destroy_buffer(device.vk_device, buffer, null);
    return buffer;
}

fn attachMemory(
    device: *const vulkan_device.Device,
    buffer: vulkan.VkBuffer,
) PassError!vulkan.VkDeviceMemory {
    const get_buffer_memory_requirements = device.procs.get_buffer_memory_requirements orelse
        return missingProc("GetBufferMemoryRequirements");
    const free_memory = device.procs.free_memory orelse return missingProc("FreeMemory");
    const bind_buffer_memory = device.procs.bind_buffer_memory orelse
        return missingProc("BindBufferMemory");
    // SAFETY: `vkGetBufferMemoryRequirements` is an out-parameter call: the
    // driver writes every field before the statement returns, and the
    // `findMemoryTypeIndex` call below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    get_buffer_memory_requirements(device.vk_device, buffer, &requirements);

    // Host-visible and host-coherent, because the counts are read back from a
    // mapped pointer with no flush: a coherent allocation needs none, and
    // `vkFlushMappedMemoryRanges` is only for a non-coherent one.
    const memory = try allocateMemory(device, requirements, host_memory);
    errdefer device.handles.release(.memory);
    errdefer free_memory(device.vk_device, memory, null);
    try dispatch.checkVkSuccess(bind_buffer_memory(
        device.vk_device,
        buffer,
        memory,
        0,
    ));
    return memory;
}

/// The memory allocation `requirements` describes, in a type that carries
/// `required_flags` and none of the device-local types.
///
/// `vulkan_device.findMemoryTypeIndex` (`src/engine/vulkan_device.zig:660`-`:677`) is
/// port's rule for choosing, and it takes the forbidden set as its last
/// argument, so a caller that needs host memory forbids the device-local types
/// and a caller that needs device memory forbids nothing it asked for.
fn allocateMemory(
    device: *const vulkan_device.Device,
    requirements: vulkan.VkMemoryRequirements,
    required_flags: vulkan.VkMemoryPropertyFlags,
) PassError!vulkan.VkDeviceMemory {
    const allocate_memory = device.procs.allocate_memory orelse
        return missingProc("AllocateMemory");
    const free_memory = device.procs.free_memory orelse return missingProc("FreeMemory");
    // Device-local is forbidden for the allocation that did not ask for it. The
    // resolve destination has to be host memory the test can read back and the
    // attachment is device-local by request, so one fixed forbidden set cannot
    // serve both: a type carrying a flag in `required_flags` and in
    // `forbidden_flags` matches nothing (`src/engine/vulkan_device.zig:672`-`:673`), and
    // asking for device-local while forbidding it refuses the attachment on
    // every driver. `src/engine/buffer.zig:676`-`:694` is the library's own form
    // of the same rule.
    const forbidden_flags: vulkan.VkMemoryPropertyFlags =
        device_local_memory & ~required_flags;
    const type_index = try vulkan_device.findMemoryTypeIndex(
        device.memoryProperties(),
        requirements.memoryTypeBits,
        required_flags,
        forbidden_flags,
    );
    const info: vulkan.VkMemoryAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO),
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: vulkan.VkDeviceMemory = null;
    try dispatch.checkVkSuccess(allocate_memory(
        device.vk_device,
        &info,
        null,
        &memory,
    ));
    if (memory == null) return error.HandleCreationReturnedNull;
    device.handles.acquire(.memory);
    errdefer device.handles.release(.memory);
    errdefer free_memory(device.vk_device, memory, null);
    return memory;
}

// ---------------------------------------------------------------------------
// The front end: the object, its availability and the plan one resolve makes.
// ---------------------------------------------------------------------------

/// What a front-end device can refuse. The device is M8's null back end, which
/// needs no driver, so the set is the engine's own plus the query rules'.
const FrontEndError = engine.DeviceError ||
    engine.AdapterError ||
    engine.InstanceError ||
    query_set.QuerySet.CreateError ||
    spirv.Error ||
    std.mem.Allocator.Error ||
    error{
        /// The null back end enumerated no adapter, so `items[0]` names
        /// nothing. M8's own shard asserts the one adapter exists.
        NoNullAdapter,
    };

/// Counts the errors that no scope took. Every front-end test below ends with a
/// zero count, because the query rules return a rule to their caller and never
/// push one through the device's sink.
const ErrorRecorder = struct {
    count: u64 = 0,

    fn record(
        allocator: std.mem.Allocator,
        context: *anyopaque,
        data: *const core.ErrorData,
    ) void {
        const self: *ErrorRecorder = @ptrCast(@alignCast(context));
        // Field by field because Zig 0.16.0 has no `==` for a struct. `ptr`
        // alone would not identify an allocator: a stateless allocator may
        // carry `undefined` there, so the vtable is the half that names it.
        std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
        std.debug.assert(data.message.len > 0);
        self.count += 1;
    }
};

/// A handle and the object behind it.
const Created = struct {
    handle: api.QuerySet,
    set: *query_set.QuerySet,
};

/// A device with an arena and no GPU.
///
/// `QuerySet.create` takes a `*core.Device` (`QuerySet.cpp:81`, `Device.cpp:2172`),
/// and what it makes of it is the type, the count and the availability vector:
/// none of the three is a driver fact. The null back end (M8) is the cheapest
/// device that owns an arena, so the front-end tests below need no ICD.
const FrontEnd = struct {
    instance: engine.Instance,
    adapters: engine.AdapterList,
    device: engine.Device,

    /// The recorder is the caller's because the device keeps the pointer for
    /// its whole life, which outlives the value `create` returns.
    fn create(recorder: *ErrorRecorder) FrontEndError!FrontEnd {
        var instance = engine.Instance.init(.{});
        var adapters = try instance.enumerateAdapters(std.testing.allocator, .{
            .feature_level = .core,
            .power_preference = .undefined_,
            .backend_type = .null_,
        });
        errdefer adapters.deinit();
        if (adapters.items.len == 0) return error.NoNullAdapter;

        // Through `Adapter.createDevice`, not `Device.init`: the instance
        // counts its devices (`Instance.addDevice`, `adapter.zig:200`, the row
        // at `docs/40-plan.md:3838`) and `Device.deinit` decrements that count
        // (`src/engine/device.zig:214`), so a device built without the adapter is one the
        // instance never counted and the teardown assertion fires.
        const device = try adapters.items[0].createDevice(std.testing.allocator, .{
            .adapter = &adapters.items[0],
            .label = "query-set front end",
            .feature_level = adapters.items[0].getFeatureLevel(),
            .uncaptured_context = @ptrCast(recorder),
            .uncaptured_callback = ErrorRecorder.record,
        });
        return .{ .instance = instance, .adapters = adapters, .device = device };
    }

    fn deinit(self: *FrontEnd) void {
        self.device.deinit(std.testing.allocator);
        self.adapters.deinit();
        self.* = undefined;
    }

    fn coreDevice(self: *FrontEnd) *core.Device {
        return self.device.coreDevice();
    }

    /// Creates a set of `count` queries and the object its handle names.
    ///
    /// `timestamp_query_enabled` is on, so a timestamp descriptor reaches the
    /// one rule that needs the feature, and the rules this shard sweeps are the
    /// count rule and the chained-struct rule.
    fn createQuerySet(
        self: *FrontEnd,
        query_type: api.QueryType,
        count: u32,
    ) FrontEndError!Created {
        const handle = try query_set.QuerySet.create(self.coreDevice(), .{
            .label = "occlusion",
            .type_ = query_type,
            .count = count,
        }, .{ .timestamp_query_enabled = true });
        return .{
            .handle = handle,
            .set = try query_set.resolveQuerySet(self.coreDevice(), handle),
        };
    }
};

test "test-query-set: a fresh occlusion set reports its type and count and holds no result" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, query_count);
    const set = created.set;

    // The object answers the front-end `QueryType`, which is the command
    // module's own enum and not `api.QueryType`: `QuerySet.h:50` returns
    // `wgpu::QueryType` through the command struct.
    try std.testing.expectEqual(command_query.QueryType.occlusion, set.apiGetType());
    try std.testing.expectEqual(query_count, set.apiGetCount());
    try std.testing.expectEqual(@as(usize, 1), front.coreDevice().queryTrackedCount());
    // The instance counts the device the adapter built (`adapter.zig:200`).
    // This is the assertion that fails if a caller reaches `Device.init`
    // directly: the device exists, every query rule runs against it, and the
    // count is still zero, which is what `Device.deinit` (`src/engine/device.zig:214`)
    // then underflows on.
    try std.testing.expectEqual(@as(u64, 1), front.instance.queryDeviceCount());

    // A fresh vector is all false (`QuerySet.cpp:86`), which is the answer that
    // separates a query nobody wrote from one that closed on zero samples.
    try std.testing.expectEqual(@as(usize, query_count), set.availability.len);
    var index: u32 = 0;
    while (index < query_count) : (index += 1) {
        try std.testing.expect(!set.isQueryAvailable(index));
    }
    try std.testing.expect(!set.areAllQueriesAvailable(0, query_count));
    try set.validateCanUseInSubmit();
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a set of no queries is legal and holds no result" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    // Dawn compares the count against a maximum and not against a minimum
    // (`QuerySet.cpp:55-57`), so zero is a set that answers every question.
    const created = try front.createQuerySet(.occlusion, 0);

    try std.testing.expectEqual(@as(u32, 0), created.set.apiGetCount());
    try std.testing.expectEqual(@as(usize, 0), created.set.availability.len);
    try std.testing.expect(created.set.areAllQueriesAvailable(0, 0));
    try created.set.validateCanUseInSubmit();
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: the maximum count is accepted and one more is refused" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    // `kMaxQueryCount` (`Constants.h:94`), which the port names as a rule
    // because it is not a device limit.
    try std.testing.expectEqual(@as(u32, 4096), command_query.max_query_count);
    const created = try front.createQuerySet(.occlusion, command_query.max_query_count);
    try std.testing.expectEqual(command_query.max_query_count, created.set.apiGetCount());

    try std.testing.expectError(error.QueryCountAboveMaximum, query_set.QuerySet.create(
        front.coreDevice(),
        .{ .label = "too many", .type_ = .occlusion, .count = command_query.max_query_count + 1 },
        .{},
    ));
    // The refused descriptor leaves an object behind, exactly as upstream does
    // (`QuerySet.cpp:114-117`), so the arena holds two sets and not one.
    try std.testing.expectEqual(@as(usize, 2), front.coreDevice().queryTrackedCount());
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a timestamp set needs the feature and an occlusion set does not" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    // `QuerySet.cpp:64-66`: the timestamp rule is a missing feature, so the
    // rule reads the feature and answers `RequiredFeatureMissing`.
    try std.testing.expectError(error.RequiredFeatureMissing, command_query.validateDescriptor(
        .{ .type_ = .timestamp, .count = query_count },
        .{ .timestamp_query_enabled = false },
    ));
    try command_query.validateDescriptor(
        .{ .type_ = .timestamp, .count = query_count },
        .{ .timestamp_query_enabled = true },
    );
    try command_query.validateDescriptor(
        .{ .type_ = .occlusion, .count = query_count },
        .{ .timestamp_query_enabled = false },
    );

    // `create` runs the same rule, so the descriptor that cannot have a set
    // still leaves one tracked object: the error set.
    try std.testing.expectError(error.RequiredFeatureMissing, query_set.QuerySet.create(
        front.coreDevice(),
        .{ .label = "timestamp", .type_ = .timestamp, .count = query_count },
        .{ .timestamp_query_enabled = false },
    ));
    try std.testing.expectEqual(@as(usize, 1), front.coreDevice().queryTrackedCount());
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a destroyed set is refused at submit time" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, query_count);

    // `createQuerySet` returns the object it made, so the handle names one; a
    // null handle would leave nothing for `destroy` to name, which is the
    // precondition this call states rather than a driver answer to read.
    const object = created.handle.handle orelse return error.NoQuerySetObject;
    try front.coreDevice().destroy(.{
        .ptr = @alignCast(object),
        .kind = .query_set,
    });

    // `ValidateCanUseInSubmitNow` (`QuerySet.cpp:148-152`) is what catches a
    // set destroyed between `finish` and `submit`
    // (`QueryValidationTests.cpp:167-187`).
    try std.testing.expectEqual(query_set.State.destroyed, created.set.state);
    try std.testing.expect(!created.set.header.isAlive());
    try std.testing.expectError(error.QuerySetDestroyed, created.set.validateCanUseInSubmit());

    // The API destroy is the same transition from the other side
    // (`QuerySet.cpp:154-156`).
    const released = try front.createQuerySet(.occlusion, query_count);
    released.set.apiDestroy();
    try std.testing.expect(!released.set.header.isAlive());
    try std.testing.expectError(error.QuerySetDestroyed, released.set.validateCanUseInSubmit());
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: availability is monotonic and a query that closed on zero is written" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, query_count);
    const set = created.set;

    // The replay marks the index at the end of every occlusion query, whatever
    // the query counted (`CommandBufferVk.cpp:2141` calls the helper at
    // `CommandBuffer.cpp:394`), and nothing clears it.
    set.markQueryAvailable(covering_query);
    try std.testing.expect(set.isQueryAvailable(covering_query));
    try std.testing.expect(!set.isQueryAvailable(clipped_query));
    try std.testing.expect(!set.areAllQueriesAvailable(0, query_count));

    set.markQueryAvailable(covering_query);
    try std.testing.expect(set.isQueryAvailable(covering_query));
    set.markQueryAvailable(clipped_query);
    try std.testing.expect(set.isQueryAvailable(clipped_query));
    try std.testing.expect(set.areAllQueriesAvailable(0, query_count));
    try std.testing.expect(set.areAllQueriesAvailable(clipped_query, 1));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: two written queries resolve as one run of two at offset zero" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, query_count);
    const set = created.set;
    set.markQueryAvailable(covering_query);
    set.markQueryAvailable(clipped_query);

    var runs: [2]query_set.CopyRun = undefined;
    const plan = try query_set.planResolve(set.availability, .{
        .first_query = 0,
        .query_count = query_count,
        .destination_offset = 0,
    }, runs[0..]);

    // The plan is what the copy the acceptance recorded is built from: one
    // call, both queries, the destination from zero.
    try std.testing.expectEqual(@as(usize, 1), plan.run_count);
    try std.testing.expectEqual(@as(u32, 0), runs[0].first);
    try std.testing.expectEqual(query_count, runs[0].count);
    try std.testing.expectEqual(@as(u64, 0), runs[0].destination_offset);
    try std.testing.expect(!plan.needs_zero_fill);
    try std.testing.expectEqual(resolve_size, plan.zero_fill_size);

    // The stride the run's second slot sits at is the one `ToQueryStorageSize`
    // names (`QuerySet.cpp:77`), and it is the stride the copy recorded.
    try std.testing.expectEqual(@as(u64, 8), query_storage_size);
    try std.testing.expectEqual(query_storage_size, command_query.queryStorageSize(1));
    try std.testing.expectEqual(resolve_size, command_query.queryStorageSize(query_count));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a range with a hole is one run reindexed to the slot it fills" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, query_count);
    const set = created.set;

    // Only the second index of the range was written, so the first slot holds
    // no pool value and the copy has to skip it.
    set.markQueryAvailable(clipped_query);
    var runs: [2]query_set.CopyRun = undefined;
    const plan = try query_set.planResolve(set.availability, .{
        .first_query = 0,
        .query_count = query_count,
        .destination_offset = 0,
    }, runs[0..]);

    try std.testing.expectEqual(@as(usize, 1), plan.run_count);
    // Pool index one is the range's first index plus one, so it belongs at
    // destination offset eight and not at zero.
    try std.testing.expectEqual(clipped_query, runs[0].first);
    try std.testing.expectEqual(@as(u32, 1), runs[0].count);
    try std.testing.expectEqual(query_storage_size, runs[0].destination_offset);
    // One index was never written, so the destination needs the zero fill the
    // resolve would otherwise leave holding the caller's bytes.
    try std.testing.expect(plan.needs_zero_fill);
    try std.testing.expectEqual(resolve_size, plan.zero_fill_size);
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a resolve that starts at query two puts it at the caller's offset" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, 3);
    const set = created.set;
    set.markQueryAvailable(2);

    var runs: [2]query_set.CopyRun = undefined;
    const plan = try query_set.planResolve(set.availability, .{
        .first_query = 2,
        .query_count = 1,
        .destination_offset = query_storage_size * 2,
    }, runs[0..]);

    // The range names one query and it is the only one written, so the run is
    // the whole range and its destination offset is the caller's plus the
    // range's own first index less the range's first query.
    try std.testing.expectEqual(@as(usize, 1), plan.run_count);
    try std.testing.expectEqual(@as(u32, 2), runs[0].first);
    try std.testing.expectEqual(@as(u32, 1), runs[0].count);
    try std.testing.expectEqual(query_storage_size * 2, runs[0].destination_offset);
    try std.testing.expect(!plan.needs_zero_fill);
    try std.testing.expectEqual(query_storage_size, plan.zero_fill_size);
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: the walk skips an unwritten index and the run bound says how many" {
    var recorder: ErrorRecorder = .{};
    var front = try FrontEnd.create(&recorder);
    defer front.deinit();

    const created = try front.createQuerySet(.occlusion, 3);
    const set = created.set;
    set.markQueryAvailable(1);

    var walk = query_set.AvailableRangeWalk.init(set.availability, 0, 3);
    // One index of the range is written, so the walk has one run to hand back;
    // an empty one would make every assertion below a claim about nothing.
    const first = walk.next() orelse return error.NoAvailableRun;
    try std.testing.expectEqual(@as(u32, 1), first.first);
    try std.testing.expectEqual(@as(u32, 1), first.count);
    try std.testing.expect(walk.next() == null);

    // `maxRunCount` is the bound the resolve buffer is sized with: a run needs
    // an index of its own and a gap before the next one, so `n` indices yield
    // at most `ceil(n / 2)`.
    try std.testing.expectEqual(@as(usize, 1), query_set.maxRunCount(1));
    try std.testing.expectEqual(@as(usize, 1), query_set.maxRunCount(2));
    try std.testing.expectEqual(@as(usize, 2), query_set.maxRunCount(3));
    try std.testing.expectEqual(@as(usize, 2), query_set.maxRunCount(4));

    // A runs slice one too small is an error and not a truncation, because a
    // truncated plan leaves the destination holding whatever it held before.
    var runs: [2]query_set.CopyRun = undefined;
    try std.testing.expectError(error.ResolveRunBufferTooSmall, query_set.planResolve(
        set.availability,
        .{ .first_query = 0, .query_count = 3, .destination_offset = 0 },
        runs[0..0],
    ));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a resolve is refused for every way its range or destination is wrong" {
    const destination: command_query.DestinationParams = .{
        .size = resolve_size,
        .usage = command_query.resolve_usage,
    };
    const range: command_query.ResolveParams = .{
        .first_query = 0,
        .query_count = query_count,
        .destination_offset = 0,
    };
    try command_query.validateResolve(query_count, range, destination);

    // `ValidateQuerySetResolve` (`CommandEncoder.cpp:1091-1119`) plus the usage
    // rule of `APIResolveQuerySet` (`:2320`), one at a time.
    try std.testing.expectError(error.ResolveFirstQueryAboveCount, command_query.validateResolve(
        query_count,
        .{ .first_query = query_count, .query_count = 1, .destination_offset = 0 },
        destination,
    ));
    try std.testing.expectError(
        error.ResolveQueryCountAboveRemaining,
        command_query.validateResolve(
            query_count,
            .{ .first_query = 1, .query_count = query_count, .destination_offset = 0 },
            destination,
        ),
    );
    // The offset rule is `kQueryResolveAlignment` (`Constants.h:45`), which is
    // 256, so an eight-byte stride does not make a one-byte offset legal.
    try std.testing.expectEqual(@as(u64, 256), command_query.query_resolve_alignment);
    try std.testing.expectError(
        error.ResolveDestinationOffsetUnaligned,
        command_query.validateResolve(
            query_count,
            .{ .first_query = 0, .query_count = 1, .destination_offset = 1 },
            destination,
        ),
    );
    // The size rule is the span from the offset, in the two arms
    // `CommandEncoder.cpp:1113`-`:1115` spells: the offset inside the buffer
    // and the span that does not fit. Both offsets below are multiples of
    // `kQueryResolveAlignment`, because Dawn refuses an unaligned offset first
    // (`:1106`) and an unaligned offset never reaches the size rule at all —
    // a 16-byte offset into a 16-byte destination trips the alignment rule, so
    // naming `ResolveDestinationTooSmall` there would assert the wrong error.
    try std.testing.expectError(
        error.ResolveDestinationTooSmall,
        command_query.validateResolve(
            query_count,
            .{
                .first_query = 0,
                .query_count = query_count,
                .destination_offset = command_query.query_resolve_alignment,
            },
            destination,
        ),
    );
    try std.testing.expectError(
        error.ResolveDestinationTooSmall,
        command_query.validateResolve(
            query_count,
            .{
                .first_query = 0,
                .query_count = query_count,
                .destination_offset = command_query.query_resolve_alignment,
            },
            .{
                // One query short of the two the range asks for, so the offset
                // is inside the buffer and only the span fails.
                .size = command_query.query_resolve_alignment + query_storage_size,
                .usage = command_query.resolve_usage,
            },
        ),
    );
    try std.testing.expectError(
        error.ResolveDestinationUsageMissing,
        command_query.validateResolve(
            query_count,
            range,
            .{ .size = resolve_size, .usage = .{ .copy_dst = true } },
        ),
    );

    // An aligned offset with room for the whole range is legal, so the rule is
    // the span and not the offset alone.
    const aligned: command_query.ResolveParams = .{
        .first_query = 0,
        .query_count = query_count,
        .destination_offset = command_query.query_resolve_alignment,
    };
    try command_query.validateResolve(query_count, aligned, .{
        .size = command_query.query_resolve_alignment + resolve_size,
        .usage = command_query.resolve_usage,
    });
}

test "test-query-set: the occlusion state machine refuses every broken order" {
    // A pass with no occlusion set has nothing for a query to write.
    var detached = try command_query.OcclusionQueryState.init(.{ .attached = false });
    try std.testing.expectError(
        error.OcclusionQuerySetAbsent,
        detached.beginOcclusionQuery(covering_query, false),
    );
    try std.testing.expectError(error.OcclusionQueryNotActive, detached.endOcclusionQuery());
    try detached.end();

    // A timestamp set in the occlusion slot is refused at pass begin, before any
    // pass object exists (`CommandEncoder.cpp:983-990`).
    try std.testing.expectError(
        error.QuerySetTypeMismatch,
        command_query.OcclusionQueryState.init(.{
            .attached = true,
            .query_type = .timestamp,
            .query_count = query_count,
        }),
    );

    var attached = try command_query.OcclusionQueryState.init(.{
        .attached = true,
        .query_count = query_count,
    });
    try std.testing.expect(!attached.active);
    try std.testing.expectEqual(@as(u32, 0), attached.index);

    try std.testing.expectError(
        error.QueryIndexAboveCount,
        attached.beginOcclusionQuery(query_count, false),
    );
    try attached.beginOcclusionQuery(covering_query, false);
    try std.testing.expect(attached.active);
    try std.testing.expectEqual(covering_query, attached.index);
    try std.testing.expectError(
        error.OcclusionQueryAlreadyActive,
        attached.beginOcclusionQuery(clipped_query, false),
    );
    // Ending a pass with a query open leaves the pool holding a query that never
    // closed (`RenderPassEncoder.cpp:174-177`).
    try std.testing.expectError(error.OcclusionQueryUnterminated, attached.end());

    try std.testing.expectEqual(covering_query, try attached.endOcclusionQuery());
    try std.testing.expect(!attached.active);
    try attached.end();

    // The same index twice in one pass is the caller's per-pass map, which M15
    // owns and this passes in (`RenderPassEncoder.cpp:56-64`).
    try std.testing.expectError(
        error.QueryIndexOverwritten,
        attached.beginOcclusionQuery(covering_query, true),
    );
}

test "test-query-set: the fixtures are valid modules with the entry points the pipeline names" {
    try expectFixtureEntryPoint(vertex_fixture, spirv.ExecutionModel.vertex, vertex_entry_point);
    try expectFixtureEntryPoint(
        fragment_fixture,
        spirv.ExecutionModel.fragment,
        fragment_entry_point,
    );
}

/// Checks that `fixture` validates and carries `entry_point` for `model`.
///
/// The pipeline names the entry point by string, so a fixture compiled from a
/// renamed WGSL function would fail at `vkCreateGraphicsPipelines` in driver
/// wording. This assertion says which name was expected. The return type is
/// inferred because `std.testing` reports its own failure error, which no
/// declared set here would name.
fn expectFixtureEntryPoint(
    fixture: []const u8,
    model: spirv.ExecutionModel,
    entry_point: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const words = try spirv.wordsFromBytes(allocator, fixture);
    defer allocator.free(words);
    try std.testing.expectEqual(words.len * @sizeOf(u32), fixture.len);
    try spirv.validate(words);

    const reflected = try spirv.reflect(allocator, words);
    defer reflected.deinit();
    const found = reflected.findEntryPoint(entry_point) orelse
        return error.NoSuchEntryPoint;
    try std.testing.expectEqual(model, found.execution_model);
    // Both stages bind nothing, which is what lets the pipeline layout above be
    // empty and lets the draw run with no descriptor sets.
    try std.testing.expectEqual(@as(usize, 0), found.resources.len);
}
