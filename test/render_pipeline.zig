//! The M14 acceptance shard: one render pipeline, created twice, and one more
//! after the layout changes.
//!
//! `docs/40-plan.md` §1 M14 fixes the acceptance in three sentences: create a
//! render pipeline from the two checked-in shader modules and assert
//! `vkCreateGraphicsPipelines` returned `VK_SUCCESS` with a non-null
//! `VkPipeline`; create the identical pipeline a second time and assert the
//! cache returned the same handle rather than a new one; run the same pipeline
//! with a different `PipelineLayout` and assert a new handle. Those are the
//! three tests below, in that order.
//!
//! **This shard runs on a real device.** The milestone's claim is about what
//! `vkCreateGraphicsPipelines` and the driver's `VkPipeline` handle do, so a
//! stub would prove nothing here. `AGENTS.md` §4.1 says a run that enumerated
//! no device proves nothing, so `discoverPhysicalDevices` failing is the test
//! failing: it refuses with `error.NoPhysicalDevice` when the loader reports
//! nothing (`src/engine/vulkan_device.zig:1285`). `test/pipeline_cache.zig` is
//! the half that needs no device.
//!
//! **The two layouts are real and they differ in shape, not in a label.** The
//! fragment fixture declares one uniform buffer at set 0, binding 1
//! (`test/fixtures/triangle.frag.wgsl:8`), so the first layout is exactly that
//! one set. The second is the same set plus a second set the shader never
//! reads, which is legal and is a different pipeline layout. A pipeline layout
//! that a superset would also accept is what makes the assertion honest: the
//! only way the two descriptors differ is the layout.
//!
//! **What this file does not claim.** It does not claim the pipeline renders
//! anything. No draw and no readback happen here; the compatibility pass is
//! created through M18's native pass cache. The host is headless
//! (`AGENTS.md` §5). It does not claim the pipeline handles are
//! counted by `vulkan_device.HandleSet`: the pipeline seam takes no `HandleSet`
//! (`src/pipeline/pipeline_backend.zig:44`-`:51`), so the driver handles the
//! pipeline path creates are released by `destroy` and by the teardown below
//! rather than by a counter.
//!
//! **The build wiring this shard needs.** The shard root is this file, the
//! library is the `dusk` import, and the shard module must carry the `vulkan`
//! module import alongside `dusk`: `src/pipeline/pipeline.zig:23` and
//! `src/engine/vulkan_device.zig` resolve `@import("vulkan")` the same way
//! `src/vk/dispatch.zig` does. That is the `addDispatchTestModule` shape already
//! at `build.zig:316`-`:331`.

const std = @import("std");
const vulkan = @import("vulkan");

const dusk = @import("dusk");

const core = dusk.core;
const pipeline = dusk.pipeline.pipeline;
const pipeline_backend = dusk.pipeline.pipeline_backend;
const shader_module = dusk.pipeline.shader_module;
const shader_module_vk = dusk.pipeline.shader_module_vk;
const spirv = dusk.spirv;
const render_pass_cache = dusk.engine.render_pass_cache;

/// The Vulkan device, reached through `dusk.engine` the way
/// `test/vulkan_device.zig` reaches it. A relative import into `src/` would
/// pull a second copy of `vulkan_device.zig` into this shard's module, so the
/// shard would hold two distinct `HandleSet` and `Device` types and no build
/// could reconcile the two.
const vulkan_device = dusk.engine.vulkan_device;

/// The two fixtures the acceptance names. `test/fixtures/triangle.vert.spv` is
/// 1,008 bytes and `triangle.frag.spv` is 716; both carry the SPIR-V 1.4
/// version word `test/spirv.zig` asserts.
const vertex_fixture: []const u8 = @embedFile("fixtures/triangle.vert.spv");
const fragment_fixture: []const u8 = @embedFile("fixtures/triangle.frag.spv");

/// The entry points the two fixtures declare. `makeStage` hands `pName` the
/// descriptor's slice (`src/pipeline/pipeline_render.zig:653`-`:660`), so the
/// name has to be the one `OpEntryPoint` carries and nothing else.
const vertex_entry_point = "vs_main";
const fragment_entry_point = "fs_main";

/// The one binding the fragment fixture declares, at set 0. `bindGroupLayout`
/// is binding 0 precisely so a test can tell the set from the binding
/// (`test/fixtures/triangle.frag.wgsl:1`-`:3`).
const tint_set_binding: u32 = 1;

/// The second layout's extra set. The shader never reads it, which is legal and
/// is the point: the two layouts differ in shape and the pipeline still builds.
const extra_set_binding: u32 = 0;

/// The attachment the one colour target names.
const color_format: vulkan.VkFormat = vulkan.VK_FORMAT_R8G8B8A8_UNORM;

/// What the test scaffolding below this can report on top of the library's own
/// errors. Every member is a defect in the setup, never in the milestone.
const SetupError = error{
    /// The device tier did not load `vkCreateDescriptorSetLayout` or
    /// `vkCreatePipelineLayout`. Both are core 1.0 entry points
    /// (`src/vk/dispatch.zig`), so a tier that missed one is a broken loader.
    MissingLayoutProc,
    /// The layout create call reported something other than `VK_SUCCESS`.
    LayoutCreationFailed,
    /// The layout create call reported `VK_SUCCESS` and wrote no handle, which
    /// Dawn asserts against at `vulkan/BindGroupLayoutVk.cpp`.
    LayoutCreationReturnedNull,
};

/// Names the entry point the device tier did not supply, for a teardown that
/// has no error to return.
///
/// `dispatch.loadDeviceProcs` fills every core entry point or refuses with
/// `MissingDeviceProc` (`src/vk/dispatch.zig:1055`), so a forced unwrap would
/// replace that named refusal with a panic. A teardown with no error to return
/// traps, because there is nowhere left to report to. The symbol goes into the
/// panic message itself rather than into a separate print, so one message
/// names both the fault and the entry point; the argument is the symbol
/// without its `vk` prefix.
fn lostProc(symbol_name: []const u8) noreturn {
    std.debug.panic(
        "a teardown reached the entry point the loader did not supply: vk{s}",
        .{symbol_name},
    );
}

/// Whether two allocators are the same allocator.
///
/// `mem.Allocator` is a `{ ptr, vtable }` pair of opaque pointers and has no
/// `==` in 0.16, so identity is the pair. Both halves are read: `.ptr` alone
/// would let a different allocator that wraps the same context pass.
fn sameAllocator(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

/// Counts the errors that no scope took, so a device that reported something and
/// swallowed it is a failure.
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
        std.debug.assert(sameAllocator(allocator, std.testing.allocator));
        std.debug.assert(data.message.len > 0);
    }
};

/// One `VkDescriptorSetLayout` declaring a single fragment-visible uniform
/// buffer at `binding`.
///
/// Built here rather than through `src/pipeline/layout_vk.zig` because that
/// file takes M12's packed `layout_internal.Layout`, and the fixture declares
/// exactly one binding, which is three lines of create-info. The call goes
/// through the loaded tier, so the missing-proc rule still applies.
fn createSetLayout(
    device: *const vulkan_device.Device,
    binding: u32,
) SetupError!vulkan.VkDescriptorSetLayout {
    const create = device.procs.create_descriptor_set_layout orelse
        return error.MissingLayoutProc;

    const bindings = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = binding,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = @intCast(vulkan.VK_SHADER_STAGE_FRAGMENT_BIT),
    }};
    const create_info: vulkan.VkDescriptorSetLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO),
        .bindingCount = @intCast(bindings.len),
        .pBindings = &bindings,
    };

    var handle: vulkan.VkDescriptorSetLayout = null;
    if (create(device.vk_device, &create_info, null, &handle) != vulkan.VK_SUCCESS) {
        return error.LayoutCreationFailed;
    }
    if (handle == null) return error.LayoutCreationReturnedNull;
    return handle;
}

/// One `VkPipelineLayout` over the given set layouts. Dawn orders the sets
/// framebuffer-fetch, resource table, bind group layouts
/// (`vulkan/PipelineLayoutVk.cpp:58`-`:87`); the first two land with the
/// milestones that own them, so the test passes its own order
/// (`src/pipeline/layout_vk.zig:231`-`:234`).
fn createLayout(
    device: *const vulkan_device.Device,
    set_layouts: []const vulkan.VkDescriptorSetLayout,
) SetupError!vulkan.VkPipelineLayout {
    const create = device.procs.create_pipeline_layout orelse
        return error.MissingLayoutProc;

    const create_info: vulkan.VkPipelineLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO),
        .setLayoutCount = @intCast(set_layouts.len),
        .pSetLayouts = set_layouts.ptr,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    var handle: vulkan.VkPipelineLayout = null;
    if (create(device.vk_device, &create_info, null, &handle) != vulkan.VK_SUCCESS) {
        return error.LayoutCreationFailed;
    }
    if (handle == null) return error.LayoutCreationReturnedNull;
    return handle;
}

fn destroySetLayout(
    device: *const vulkan_device.Device,
    handle: vulkan.VkDescriptorSetLayout,
) void {
    const destroy = device.procs.destroy_descriptor_set_layout orelse
        lostProc("DestroyDescriptorSetLayout");
    destroy(device.vk_device, handle, null);
}

fn destroyLayout(device: *const vulkan_device.Device, handle: vulkan.VkPipelineLayout) void {
    const destroy = device.procs.destroy_pipeline_layout orelse lostProc("DestroyPipelineLayout");
    destroy(device.vk_device, handle, null);
}

/// One module built from `words` and waited for.
///
/// `Io.Future.await` takes `*Future` (`std/Io.zig:1199`) because it nulls the
/// future out as it consumes it, so the future has to be a `var` a caller can
/// address: awaiting the `Io.Future` a call returned is awaiting a const
/// temporary. `test/shader_module.zig:134`-`:136` binds it for the same
/// reason.
fn createModule(
    io: std.Io,
    device: *const shader_module_vk.Device,
    label: []const u8,
    words: []const spirv.Word,
) (std.Io.ConcurrentError || shader_module.CreateError)!shader_module.ShaderModule {
    var future = try shader_module.createShaderModule(
        std.testing.allocator,
        io,
        device,
        .{ .label = label, .words = words },
    );
    return future.await(io);
}

/// Every teardown refusal one test body has not returned yet.
///
/// `defer` cannot fail in Zig 0.16, so a teardown that can refuse cannot
/// return from the point where it refuses. It records the error here and the
/// body returns it once its own frame has unwound, which keeps every teardown
/// a `defer` and still hands the shard the loader's own words instead of a
/// trap carrying ours. `AGENTS.md` §3.1 makes a missing proc a typed error and
/// forbids the panic, so recording is the shape that leaves both standing.
const TeardownError = vulkan_device.ProcError || shader_module_vk.CreateError ||
    core.LifetimeError || core.ReferenceError || core.HandleError ||
    error{ResourceInUse};

const TeardownErrors = struct {
    first: ?TeardownError = null,

    /// Records one refusal. The first is the one that matters: a teardown that
    /// already failed left its object in a state a later teardown cannot
    /// describe, so a second report would bury the first.
    fn record(self: *TeardownErrors, err: TeardownError) void {
        if (self.first == null) self.first = err;
    }

    /// Returns the refusal the teardown recorded, or nothing when every
    /// teardown ran. A body that already returned an error has failed the
    /// shard, so a refusal from the teardown of that body adds no information
    /// and is not reported twice.
    fn report(self: *const TeardownErrors) TeardownError!void {
        if (self.first) |err| return err;
    }
};

/// Releases a shader module, recording a refused release for `teardowns`.
///
/// The destroy can only fail on a missing proc, which the create already
/// required, so a refusal here is a loader defect. `AGENTS.md` §3.1 makes that
/// a typed error and forbids the panic, so the error goes to `teardowns` and
/// the test returns it.
fn destroyModule(
    module: *shader_module.ShaderModule,
    device: *const shader_module_vk.Device,
    teardowns: *TeardownErrors,
) void {
    module.destroy(device) catch |err| teardowns.record(err);
}

/// The descriptor the acceptance builds, over one layout and two fixtures.
///
/// The vertex stage declares no vertex buffer and no attribute: the fixture
/// reads `vertex_index` and nothing else
/// (`test/fixtures/triangle.vert.wgsl:4`), so there is nothing to bind.
fn triangleDescriptor(
    compatible_render_pass: vulkan.VkRenderPass,
    layout_handle: vulkan.VkPipelineLayout,
    layout_bytes: []const u8,
    vertex_module: shader_module.ShaderModule,
    fragment_module: shader_module.ShaderModule,
) pipeline.RenderPipelineDescriptor {
    return .{
        .compatible_render_pass = compatible_render_pass,
        .label = "triangle",
        .layout = .{ .handle = layout_handle, .content_bytes = layout_bytes },
        .vertex = .{
            .stage = .vertex,
            .module = vertex_module.vk_module,
            .entry_point = vertex_entry_point,
            .content_bytes = std.mem.sliceAsBytes(vertex_module.words),
        },
        .fragment = .{
            .stage = .fragment,
            .module = fragment_module.vk_module,
            .entry_point = fragment_entry_point,
            .content_bytes = std.mem.sliceAsBytes(fragment_module.words),
        },
        .color_targets = &.{.{ .format = color_format }},
    };
}

// ---------------------------------------------------------------------------
// The acceptance.
// ---------------------------------------------------------------------------

test "a render pipeline is built once, the cache returns it, and a new layout makes a new one" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var teardowns: TeardownErrors = .{};
    // The body runs in a frame of its own so that every `defer` inside it has
    // fired by the time the refusal it recorded is returned. A `defer` in this
    // frame would run after the `try` below, and the refusal would never reach
    // the shard.
    try pipelineAcceptance(threaded.io(), &teardowns);
    try teardowns.report();
}

/// The body of the first test. The frame of its own is what lets the caller
/// return a teardown refusal: the modules below are released by `defer` on the
/// way out, so their refusals are recorded before the caller looks for one.
fn pipelineAcceptance(io: std.Io, teardowns: *TeardownErrors) !void {
    var handles: vulkan_device.HandleSet = .{};
    var backend = vulkan_device.Backend.init(std.testing.allocator, .{ .handles = &handles });
    defer backend.deinit() catch |err| teardowns.record(err);

    // `AGENTS.md` §4.1: this call reports nothing found as an error, so the test
    // cannot pass by finding no device.
    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();
    const adapter = try adapters.first();
    try std.testing.expect(adapter.physical.supportsRequiredVersion());

    // Registered first, so it runs last: every Vulkan object below has to be
    // gone before the device that owns them is.
    var device = try vulkan_device.Device.create(std.testing.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });
    defer device.deinit(std.testing.allocator) catch |err| teardowns.record(err);
    try std.testing.expectEqual(@as(u32, 1), handles.countOf(.device));

    const pipeline_seam = pipeline_backend.Backend.fromDeviceProcs(device.vk_device, device.procs);
    const module_device = shader_module_vk.Device.init(
        device.procs,
        device.vk_device,
        device.api_version,
    );

    var passes = render_pass_cache.RenderPassCache.init(.{
        .allocator = std.testing.allocator,
        .device = .{ .procs = device.procs, .vk_device = device.vk_device },
    });
    defer passes.deinit(io);
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
    try std.testing.expect(pass.render_pass != null);
    try std.testing.expectEqual(@as(u32, 0), pass.main_subpass);

    // The two shader modules, from the two checked-in fixtures. The words are
    // the caller's and the module borrows them
    // (`src/pipeline/shader_module.zig:43`-`:49`), so they outlive the modules.
    const vertex_words = try spirv.wordsFromBytes(std.testing.allocator, vertex_fixture);
    defer std.testing.allocator.free(vertex_words);
    const fragment_words = try spirv.wordsFromBytes(std.testing.allocator, fragment_fixture);
    defer std.testing.allocator.free(fragment_words);

    var vertex_module = try createModule(
        io,
        &module_device,
        "triangle.vert.spv",
        vertex_words,
    );
    defer destroyModule(&vertex_module, &module_device, teardowns);
    var fragment_module = try createModule(
        io,
        &module_device,
        "triangle.frag.spv",
        fragment_words,
    );
    defer destroyModule(&fragment_module, &module_device, teardowns);

    // The handles reached Vulkan and the entry points the descriptor names are
    // the ones the fixtures declare. Without both, `vkCreateGraphicsPipelines`
    // would fail below for a reason this test could not read back.
    try std.testing.expect(vertex_module.vk_module != null);
    try std.testing.expect(fragment_module.vk_module != null);
    try std.testing.expect(vertex_module.findEntryPoint(vertex_entry_point) != null);
    try std.testing.expect(fragment_module.findEntryPoint(fragment_entry_point) != null);
    try std.testing.expectEqual(@as(usize, 1), fragment_module.entry_points.len);
    try std.testing.expectEqual(@as(usize, 1), vertex_module.entry_points.len);

    // The two layouts. The first declares exactly what the fragment fixture
    // reads; the second adds a set the shader never touches.
    const tint_set_layout = try createSetLayout(&device, tint_set_binding);
    defer destroySetLayout(&device, tint_set_layout);
    const extra_set_layout = try createSetLayout(&device, extra_set_binding);
    defer destroySetLayout(&device, extra_set_layout);

    const first_layout = try createLayout(&device, &.{tint_set_layout});
    defer destroyLayout(&device, first_layout);
    const second_layout = try createLayout(&device, &.{ tint_set_layout, extra_set_layout });
    defer destroyLayout(&device, second_layout);

    // The key bytes the layout contributes. Dawn streams the descriptor set
    // layout create infos and the resource-table and immediate-data flags
    // (`vulkan/PipelineLayoutVk.cpp:127`); the port records the shape the
    // caller built, and the test records the shape it created.
    var first_layout_key = pipeline.CacheKey.init();
    defer first_layout_key.deinit(std.testing.allocator);
    try first_layout_key.appendWord(std.testing.allocator, @intFromPtr(tint_set_layout));
    var second_layout_key = pipeline.CacheKey.init();
    defer second_layout_key.deinit(std.testing.allocator);
    try second_layout_key.appendWord(std.testing.allocator, @intFromPtr(tint_set_layout));
    try second_layout_key.appendWord(std.testing.allocator, @intFromPtr(extra_set_layout));

    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var core_device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
    defer guard.unlock(io);
    defer core_device.deinit(std.testing.allocator, &guard) catch |err| teardowns.record(err);

    var store = pipeline.PipelineStore.init(std.testing.allocator, core_device.borrow().objects);
    defer store.deinit(&guard) catch |err| teardowns.record(err);

    const base = triangleDescriptor(
        pass.render_pass,
        first_layout,
        first_layout_key.bytes.items,
        vertex_module,
        fragment_module,
    );

    // The first sentence of the acceptance: `vkCreateGraphicsPipelines`
    // returned `VK_SUCCESS` (the call returned without an error) and wrote a
    // non-null `VkPipeline`.
    const first = try pipeline.createRenderPipelineLocked(
        std.testing.allocator,
        io,
        &guard,
        &core_device,
        &store,
        &pipeline_seam,
        base,
        .user,
    );
    defer {
        if (core_device.resolveReference(&guard, first)) |header| {
            header.releaseUserLocked(&guard, io) catch |err| teardowns.record(err);
        } else |err| teardowns.record(err);
    }
    const first_vk = try pipeline.vkPipeline(&guard, &core_device, first);
    try std.testing.expect(first_vk != null);
    try std.testing.expectEqual(first_layout, try pipeline.vkLayout(&guard, &core_device, first));
    try std.testing.expectEqual(
        pipeline.Kind.render,
        try pipeline.queryKind(&guard, &core_device, first),
    );
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(usize, 1), core_device.queryTrackedCount(&guard));

    const state = try pipeline.renderState(&guard, &core_device, first);
    try std.testing.expect(state.fragment_stage_present);
    try std.testing.expectEqual(@as(usize, 1), state.color_formats.items.len);
    try std.testing.expectEqual(color_format, state.color_formats.items[0]);

    // A pass with different load/store operations is compatible. Its raw
    // handle must not split the semantic pipeline cache.
    var compatible_query = pass_query;
    compatible_query.setColor(.{
        .index = 0,
        .format = .rgba8_unorm,
        .load_op = .load,
        .store_op = .store,
        .has_resolve_target = false,
        .render_to_single_sampled = false,
    });
    const compatible_pass = try passes.getRenderPass(io, compatible_query);
    try std.testing.expect(compatible_pass.render_pass != pass.render_pass);
    var compatible_descriptor = base;
    compatible_descriptor.compatible_render_pass = compatible_pass.render_pass;
    const hit = try pipeline.createRenderPipelineLocked(
        std.testing.allocator,
        io,
        &guard,
        &core_device,
        &store,
        &pipeline_seam,
        compatible_descriptor,
        .user,
    );
    defer {
        if (core_device.resolveReference(&guard, hit)) |header| {
            header.releaseUserLocked(&guard, io) catch |err| teardowns.record(err);
        } else |err| teardowns.record(err);
    }
    try std.testing.expectEqual(first.ptr, hit.ptr);
    try std.testing.expectEqual(first_vk, try pipeline.vkPipeline(&guard, &core_device, hit));
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(usize, 1), core_device.queryTrackedCount(&guard));

    // The third sentence: the same pipeline with a different `PipelineLayout`
    // reaches a new handle. This is what proves the cache key carries the
    // layout, because nothing else in the two descriptors differs.
    const relaid = triangleDescriptor(
        pass.render_pass,
        second_layout,
        second_layout_key.bytes.items,
        vertex_module,
        fragment_module,
    );
    // The two descriptors differ in the key, and the difference is the layout's
    // bytes: the second layout declared a second set, so its run is longer.
    var base_key = try pipeline.buildRenderPipelineKey(std.testing.allocator, base);
    defer base_key.deinit(std.testing.allocator);
    var relaid_key = try pipeline.buildRenderPipelineKey(std.testing.allocator, relaid);
    defer relaid_key.deinit(std.testing.allocator);
    try std.testing.expect(!pipeline.CacheKey.eql(&base_key, &relaid_key));
    try std.testing.expect(base_key.bytes.items.len < relaid_key.bytes.items.len);
    const miss = try pipeline.createRenderPipelineLocked(
        std.testing.allocator,
        io,
        &guard,
        &core_device,
        &store,
        &pipeline_seam,
        relaid,
        .user,
    );
    defer {
        if (core_device.resolveReference(&guard, miss)) |header| {
            header.releaseUserLocked(&guard, io) catch |err| teardowns.record(err);
        } else |err| teardowns.record(err);
    }
    try std.testing.expect(first.ptr != miss.ptr);
    try std.testing.expect(try pipeline.vkPipeline(&guard, &core_device, miss) != first_vk);
    try std.testing.expectEqual(second_layout, try pipeline.vkLayout(&guard, &core_device, miss));
    try std.testing.expectEqual(@as(usize, 2), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(usize, 2), core_device.queryTrackedCount(&guard));

    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "the two fixtures hand Vulkan the words the files hold" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var teardowns: TeardownErrors = .{};
    // The frame of its own, for the reason `pipelineAcceptance` names: the
    // module destroys below have to have run before the refusal is returned.
    try fixturesReachVulkanUnchanged(threaded.io(), &teardowns);
    try teardowns.report();
}

/// The body of the second test. Its frame of its own is what lets the caller
/// return a teardown refusal, exactly as in `pipelineAcceptance`.
fn fixturesReachVulkanUnchanged(io: std.Io, teardowns: *TeardownErrors) !void {
    var handles: vulkan_device.HandleSet = .{};
    var backend = vulkan_device.Backend.init(std.testing.allocator, .{ .handles = &handles });
    defer backend.deinit() catch |err| teardowns.record(err);

    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();
    const adapter = try adapters.first();

    var device = try vulkan_device.Device.create(std.testing.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });
    defer device.deinit(std.testing.allocator) catch |err| teardowns.record(err);

    const module_device = shader_module_vk.Device.init(
        device.procs,
        device.vk_device,
        device.api_version,
    );

    const vertex_words = try spirv.wordsFromBytes(std.testing.allocator, vertex_fixture);
    defer std.testing.allocator.free(vertex_words);
    const fragment_words = try spirv.wordsFromBytes(std.testing.allocator, fragment_fixture);
    defer std.testing.allocator.free(fragment_words);

    // A `.spv` file is a word stream, so a size that is not a whole number of
    // words is a truncated fixture rather than a module.
    try std.testing.expectEqual(
        vertex_fixture.len / @sizeOf(u32),
        vertex_words.len,
    );
    try std.testing.expectEqual(
        fragment_fixture.len / @sizeOf(u32),
        fragment_words.len,
    );

    var vertex_module = try createModule(
        io,
        &module_device,
        "triangle.vert.spv",
        vertex_words,
    );
    defer destroyModule(&vertex_module, &module_device, teardowns);
    var fragment_module = try createModule(
        io,
        &module_device,
        "triangle.frag.spv",
        fragment_words,
    );
    defer destroyModule(&fragment_module, &module_device, teardowns);

    // The one claim M13 makes and this milestone leans on: nothing between the
    // descriptor and `pCode` rewrites the words
    // (`src/pipeline/shader_module_vk.zig:93`-`:104`).
    try std.testing.expectEqualSlices(spirv.Word, vertex_words, vertex_module.words);
    try std.testing.expectEqualSlices(spirv.Word, fragment_words, fragment_module.words);
    try std.testing.expect(vertex_module.vk_module != null);
    try std.testing.expect(fragment_module.vk_module != null);

    // Reflection found the one binding the fragment fixture declares
    // (`test/fixtures/triangle.frag.wgsl:8`) and nothing on the vertex stage
    // (`test/fixtures/triangle.vert.wgsl:2`). A fixture built from a renamed
    // WGSL function would not carry the name the pipeline passes below, so a
    // module without it names itself rather than reaching a null record.
    const vertex_record = vertex_module.findEntryPoint(vertex_entry_point) orelse
        return error.NoSuchEntryPoint;
    try std.testing.expectEqual(@as(usize, 0), vertex_record.layout.bindingCount());
    try std.testing.expectEqual(@as(usize, 0), vertex_record.layout.groupCount());

    const fragment_record = fragment_module.findEntryPoint(fragment_entry_point) orelse
        return error.NoSuchEntryPoint;
    try std.testing.expectEqual(@as(usize, 1), fragment_record.layout.bindingCount());
    try std.testing.expectEqual(@as(usize, 1), fragment_record.layout.groupCount());
    try std.testing.expectEqual(@as(u32, 0), fragment_record.layout.bindings[0].set);
    try std.testing.expectEqual(tint_set_binding, fragment_record.layout.bindings[0].binding);
}
