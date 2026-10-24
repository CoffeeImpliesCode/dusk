//! The M14 cache shard: the key, and the store's "same pipeline or a new one".
//!
//!
//! **What the Vulkan seam is here.** Two counters and two handles. The seam is
//! six injected function pointers (`src/pipeline/pipeline_backend.zig:46-51`), so a
//! test supplies its own, and the assertions are about how many times the create
//! call is reached and what the store hands back. Nothing in this file claims a
//! driver, a compiled pipeline or a shader; `test/render_pipeline.zig` runs the
//! same three calls against a real device and reads a real `VkPipeline`.
//!
//!
//! **What this file does not claim.** It does not claim that the key equals a
//! Dawn digest. `src/pipeline/cache_key.zig:9-16` records that neither side
//! publishes a seed, so the port hashes the whole key with a fixed-seed Wyhash
//! and decides on the bytes. The property under test is the one the cache needs:
//! equal descriptors agree and different descriptors differ.
//!
//! **The build wiring this shard needs.** The shard root is this file, the
//! library is the `dusk` import, and the shard module must carry the `vulkan`
//! module import alongside `dusk`. `src/pipeline/pipeline.zig:23` resolves
//! `@import("vulkan")` the same way `src/vk/dispatch.zig` does, so this is the
//! `addDispatchTestModule` shape already at `build.zig:316`-`:331`.

const std = @import("std");
const builtin = @import("builtin");
const vulkan = @import("vulkan");

const dusk = @import("dusk");

const cache_key = dusk.pipeline.cache_key;
const core = dusk.core;
const pipeline = dusk.pipeline.pipeline;

fn spirvBytes(comptime words: []const u32) [words.len * 4]u8 {
    var bytes: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
    }
    return bytes;
}

const specialization_bytes = spirvBytes(&specialization_words);

/// The two entry point names the synthetic stages carry. A key records them
/// (`src/dawn/native/Pipeline.cpp:390`), so a descriptor that changed only this
/// must miss. Dawn reads them out of the module; the port takes them as plain
/// values because it has no Tint program to read them from
/// (`src/pipeline/pipeline.zig:768`).
const vertex_entry_point = "vertex_main";
const fragment_entry_point = "fragment_main";

/// The bytes that stand in for each module's SPIR-V. The key records the
/// module's content hash (`src/dawn/native/Pipeline.cpp:389`), so these are the
/// bytes a changed fixture changes. The seam never reads them, so a fixed run
/// carries the property without a `.spv` fixture.
const vertex_words = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0x00, 0x01, 0x00, 0x00 };
const fragment_words = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0x00, 0x01, 0x00, 0x01 };

/// A second fragment module, one word apart from `fragment_words`. That is the
/// smallest change a different shader can make and the key must notice it.
const other_fragment_words = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0x00, 0x01, 0x00, 0x02 };

/// Distinct raw layout definitions must select distinct complete pipeline keys.
const first_layout_bytes = [_]u8{ 's', 'e', 't', '0', 'b', 'i', 'n', 'd' };
const second_layout_bytes = [_]u8{ 's', 'e', 't', '1', 'b', 'n', 'd', 'X' };

/// The colour target the fixture triangle renders into. The seam ignores it; the
/// key records it (`src/dawn/native/RenderPipeline.cpp:1329`-`:1360`).
const color_format = vulkan.VK_FORMAT_R8G8B8A8_UNORM;

/// What the seam saw. Two create handles, one destroy handle, and the layout the
/// last create was handed, so a descriptor that silently lost its layout cannot
/// pass the last test.
const Seam = struct {
    create_count: u32 = 0,
    destroy_count: u32 = 0,
    issued: u32 = 0,
    last_layout: vulkan.VkPipelineLayout = null,
    specialization_counts: [3]u32 = @splat(0),
    specialization_ids: [3][2]u32 = @splat(@splat(0)),
    specialization_values: [3][2]u32 = @splat(@splat(0)),

    fn captureStage(self: *Seam, stage: vulkan.VkPipelineShaderStageCreateInfo) void {
        const index: usize = switch (stage.stage) {
            vulkan.VK_SHADER_STAGE_VERTEX_BIT => 0,
            vulkan.VK_SHADER_STAGE_FRAGMENT_BIT => 1,
            vulkan.VK_SHADER_STAGE_COMPUTE_BIT => 2,
            else => unreachable,
        };
        const info = stage.pSpecializationInfo;
        if (info == null) {
            self.specialization_counts[index] = 0;
            return;
        }
        std.debug.assert(info.*.mapEntryCount <= 2);
        self.specialization_counts[index] = info.*.mapEntryCount;
        const data: [*]const u8 = @ptrCast(info.*.pData);
        for (0..info.*.mapEntryCount) |entry_index| {
            const entry = info.*.pMapEntries[entry_index];
            std.debug.assert(entry.size == 4);
            std.debug.assert(entry.offset + entry.size <= info.*.dataSize);
            self.specialization_ids[index][entry_index] = entry.constantID;
            self.specialization_values[index][entry_index] =
                std.mem.readInt(u32, data[entry.offset..][0..4], builtin.cpu.arch.endian());
        }
    }

    /// One handle per create, so two pipelines are two values. The handle is an
    /// address inside the `Seam` value itself: distinct, never null, and never
    /// dereferenced, because the only code that reads it is this file's own
    /// comparison.
    fn nextHandle(self: *Seam) vulkan.VkPipeline {
        self.issued += 1;
        return @ptrFromInt(@intFromPtr(self) + self.issued * 64);
    }
};

/// The one failure the seam's own recovery can report. `Backend` carries no
/// context field (`src/pipeline/pipeline_backend.zig:45-52`), so the device handle
/// is the context and a backend built without one cannot be called.
const SeamError = error{SeamDeviceWasNull};

fn seamFromDevice(device: vulkan.VkDevice) SeamError!*Seam {
    const handle = device orelse return error.SeamDeviceWasNull;
    // `VkDevice` is `?*struct_VkDevice_T` (`src/vulkan.zig:482`), and an opaque
    // pointer does not coerce to `*anyopaque` the way a void pointer does, so
    // `@alignCast` alone leaves the element type the bindings declared and the
    // assignment fails on the element type rather than on the alignment.
    // `@ptrCast` is what changes it. The container holds `*const anyopaque`:
    // the device handle is the context this file reads (`:18`-`:22`) and
    // nothing writes through the handle itself.
    const aligned: *const anyopaque = @ptrCast(@alignCast(handle));
    // The const comes off here and not one line earlier: this is the one step
    // where a Vulkan device handle becomes a mutable pointer to this file's own
    // struct, and `stubBackend` put it there (`:176`). The `Seam` is a real
    // aligned value of this file rather than a fabricated address
    // (`:88`-`:102`), so the alignment asserted on the way out is a claim about
    // that value and not a guess.
    return @ptrCast(@alignCast(@constCast(aligned)));
}

fn seamCreateGraphicsPipelines(
    device: vulkan.VkDevice,
    _: vulkan.VkPipelineCache,
    create_info_count: u32,
    create_infos: [*c]const vulkan.VkGraphicsPipelineCreateInfo,
    allocator: [*c]const vulkan.VkAllocationCallbacks,
    out_pipelines: [*c]vulkan.VkPipeline,
) callconv(.c) vulkan.VkResult {
    // The arguments a driver would have refused the call over. Asserting them
    // here is what stops the stub from proving anything: a create count that
    // rose because the call was malformed would be a count, not a pipeline.
    std.debug.assert(allocator == null);
    std.debug.assert(create_info_count == 1);
    std.debug.assert(create_infos[0].layout != null);
    std.debug.assert(create_infos[0].renderPass != null);
    std.debug.assert(create_infos[0].pNext == null);

    // A backend built without a device never gets called, so the null handle
    // means the seam answered a call its own `stubBackend` did not wire up.
    // The create entry point has a `VkResult` to return, so it reports it
    // rather than trapping.
    const seam = seamFromDevice(device) catch return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    seam.create_count += 1;
    seam.last_layout = create_infos[0].layout;
    for (0..create_infos[0].stageCount) |index| seam.captureStage(create_infos[0].pStages[index]);
    out_pipelines[0] = seam.nextHandle();
    return vulkan.VK_SUCCESS;
}

fn seamCreateComputePipelines(
    device: vulkan.VkDevice,
    _: vulkan.VkPipelineCache,
    create_info_count: u32,
    create_infos: [*c]const vulkan.VkComputePipelineCreateInfo,
    allocator: [*c]const vulkan.VkAllocationCallbacks,
    out_pipelines: [*c]vulkan.VkPipeline,
) callconv(.c) vulkan.VkResult {
    std.debug.assert(allocator == null);
    std.debug.assert(create_info_count == 1);
    std.debug.assert(create_infos[0].layout != null);
    const seam = seamFromDevice(device) catch return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    seam.create_count += 1;
    seam.last_layout = create_infos[0].layout;
    seam.captureStage(create_infos[0].stage);
    out_pipelines[0] = seam.nextHandle();
    return vulkan.VK_SUCCESS;
}

fn seamDestroyPipeline(
    device: vulkan.VkDevice,
    destroyed: vulkan.VkPipeline,
    allocator: [*c]const vulkan.VkAllocationCallbacks,
) callconv(.c) void {
    std.debug.assert(allocator == null);
    std.debug.assert(destroyed != null);
    // `destroy_pipeline` returns `void`, so there is no result to report the
    // failure through. `stubBackend` is the only builder of this seam and it
    // always stores a non-null device, so a null handle here is a broken seam
    // and a trap is the report.
    const seam = seamFromDevice(device) catch
        std.debug.panic("pipeline_cache: destroy_pipeline reached with a null VkDevice", .{});
    seam.destroy_count += 1;
}

/// The backend the seam answers for. Six fields, four of them null: those four
/// are the entry points a render pipeline never reaches
/// (`src/pipeline/pipeline_backend.zig:47-52`).
fn stubBackend(seam: *Seam) pipeline.Backend {
    return .{
        .device = @ptrCast(seam),
        .create_graphics_pipelines = seamCreateGraphicsPipelines,
        .create_compute_pipelines = seamCreateComputePipelines,
        .create_pipeline_cache = null,
        .get_pipeline_cache_data = null,
        .destroy_pipeline = seamDestroyPipeline,
        .destroy_pipeline_cache = null,
    };
}

fn releasePipelineUser(device: *core.Device, guard: *const core.ObjectGuard, io: std.Io, handle: core.Handle) void {
    const header = device.resolveReference(guard, handle) catch @panic("owned pipeline identity was lost");
    header.releaseUserLocked(guard, io) catch @panic("owned pipeline user reference was lost");
}

/// A descriptor with no state a second descriptor could disagree about, so the
/// only thing each test changes is the one field under test.
fn descriptor(
    layout_bytes: []const u8,
    entry_point: []const u8,
    fragment: []const u8,
) pipeline.RenderPipelineDescriptor {
    return .{
        .label = "cache shard",
        .compatible_render_pass = @ptrFromInt(80),
        .layout = .{
            .handle = @ptrFromInt(@intFromPtr(layout_bytes.ptr)),
            .content_bytes = layout_bytes,
        },
        .vertex = .{
            .stage = .vertex,
            .entry_point = entry_point,
            .content_bytes = &vertex_words,
        },
        .fragment = .{
            .stage = .fragment,
            .entry_point = fragment_entry_point,
            .content_bytes = fragment,
        },
        .color_targets = &.{.{ .format = color_format }},
    };
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
        // Field by field because Zig 0.16.0 has no `==` for a struct. `ptr`
        // alone would not identify an allocator: a stateless allocator may
        // carry `undefined` there, so the vtable is the half that names it.
        std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
        std.debug.assert(data.message.len > 0);
    }
};

// ---------------------------------------------------------------------------
// The key.
// ---------------------------------------------------------------------------

test "different raw layout definitions select different pipeline keys" {
    const allocator = std.testing.allocator;

    var first = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words),
    );
    defer first.deinit(allocator);
    var second = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&second_layout_bytes, vertex_entry_point, &fragment_words),
    );
    defer second.deinit(allocator);

    // Two descriptors that differ only in the layout must not compare equal.
    // `src/dawn/native/Pipeline.cpp:385` records the layout first and `:400`
    // compares it first, and §M14's acceptance is that this is what makes a new
    // layout a new pipeline.
    try std.testing.expect(!pipeline.CacheKey.eql(&first, &second));
}

test "a descriptor that differs only in its shader is a different pipeline" {
    const allocator = std.testing.allocator;

    var unchanged = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words),
    );
    defer unchanged.deinit(allocator);
    var rebuilt = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, vertex_entry_point, &other_fragment_words),
    );
    defer rebuilt.deinit(allocator);
    var moved_entry_point = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, "other_vertex_main", &fragment_words),
    );
    defer moved_entry_point.deinit(allocator);
    var same = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words),
    );
    defer same.deinit(allocator);

    // The same descriptor twice: equal bytes, equal length and an equal hash,
    // because the hash is what picks the bucket and the bytes are what decide
    // (`src/pipeline/cache_key.zig:113-116`).
    try std.testing.expect(pipeline.CacheKey.eql(&unchanged, &same));
    try std.testing.expectEqual(unchanged.byteCount(), same.byteCount());
    try std.testing.expectEqual(unchanged.contentHash(), same.contentHash());

    // A different fragment module, `src/dawn/native/Pipeline.cpp:389`.
    try std.testing.expect(!pipeline.CacheKey.eql(&unchanged, &rebuilt));
    // A different entry point, `src/dawn/native/Pipeline.cpp:390`.
    try std.testing.expect(!pipeline.CacheKey.eql(&unchanged, &moved_entry_point));
    // The fragment move keeps the length, so it is a difference no length
    // prefix could have hidden. The entry-point move is length-prefixed, so a
    // longer name is a longer key by exactly the name's difference.
    try std.testing.expectEqual(unchanged.byteCount(), rebuilt.byteCount());
    try std.testing.expectEqual(
        "other_vertex_main".len - vertex_entry_point.len,
        moved_entry_point.byteCount() - unchanged.byteCount(),
    );
}

test "render scratch uses the explicit compatible render pass without a pNext chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const render = dusk.pipeline.pipeline_render;
    var desc = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    desc.compatible_render_pass = @ptrFromInt(96);
    var state: pipeline.State = undefined;
    var scratch: render.Scratch = .{};
    defer scratch.deinit(allocator);

    try render.buildRenderState(allocator, desc, &state, &scratch);
    try std.testing.expectEqual(desc.compatible_render_pass, scratch.create_info.renderPass);
    try std.testing.expect(scratch.create_info.pNext == null);
    try std.testing.expectEqual(@as(u32, 0), scratch.create_info.subpass);
}

test "a render key and a compute key never compare equal" {
    const allocator = std.testing.allocator;

    var render = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words),
    );
    defer render.deinit(allocator);
    var compute = try pipeline.buildComputePipelineKey(allocator, .{
        .label = "cache shard",
        .limits = .{ .max_workgroup_size = .{ 1, 1, 1 }, .max_invocations = 1 },
        .layout = .{
            // The layout bytes are an array, so the identity is the address of
            // the array and not a slice header's `ptr`. It is the value
            // `descriptor` hands the render key above, so both keys use the
            // same layout identity and content.
            .handle = @ptrFromInt(@intFromPtr(&first_layout_bytes)),
            .content_bytes = &first_layout_bytes,
        },
        .compute = .{
            .stage = .compute,
            .entry_point = "main",
            .content_bytes = &specialization_bytes,
        },
    });
    defer compute.deinit(allocator);

    // The leading discriminator (`src/dawn/native/CacheKey.h:42`) is the whole
    // reason two keys over one layout are still two pipelines.
    try std.testing.expect(!pipeline.CacheKey.eql(&render, &compute));
    try std.testing.expectEqual(
        @as(u8, @backingInt(cache_key.Kind.render_pipeline)),
        render.bytes.items[0],
    );
    try std.testing.expectEqual(
        @as(u8, @backingInt(cache_key.Kind.compute_pipeline)),
        compute.bytes.items[0],
    );
}

test "compute pipeline keys distinguish specialization constant values for the same stage" {
    const allocator = std.testing.allocator;
    // A compute entry point using uint SpecId 7, whose module default is 1.
    // Both descriptors borrow the same words; only the requested value changes.
    const words = [_]u32{
        0x07230203, 0x00010000, 0, 8, 0,
        0x00020011, 1, // OpCapability Shader.
        0x0003000e, 0, 1, // OpMemoryModel Logical GLSL450.
        0x0005000f, 5, 5, 0x6e69616d, 0, // OpEntryPoint GLCompute %5 "main".
        0x00060010, 5, 17, 1, 1, 1, // OpExecutionMode %5 LocalSize 1 1 1.
        0x00040047, 4, 1, 7, // OpDecorate %4 SpecId 7.
        0x00020013, 1, // OpTypeVoid %1.
        0x00030021, 2, 1, // OpTypeFunction %2 %1.
        0x00040015, 3, 32, 0, // OpTypeInt %3 32 unsigned.
        0x00040032, 3, 4, 1, // OpSpecConstant %3 %4 1.
        0x00050036, 1, 5, 0, 2, // OpFunction %1 %5 None %2.
        0x000200f8, 6, // OpLabel %6.
        0x00050080, 3, 7, 4, 4, // OpIAdd %3 %7 %4 %4.
        0x000100fd, // OpReturn.
        0x00010038, // OpFunctionEnd.
    };
    const module_bytes = spirvBytes(&words);
    const first_constants = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "7", .value = 2 }};
    const second_constants = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "7", .value = 3 }};
    var first_descriptor: pipeline.ComputePipelineDescriptor = .{
        .limits = .{ .max_workgroup_size = .{ 1, 1, 1 }, .max_invocations = 1 },
        .layout = .{
            .handle = @ptrFromInt(@intFromPtr(&first_layout_bytes)),
            .content_bytes = &first_layout_bytes,
        },
        .compute = .{
            .stage = .compute,
            .entry_point = "main",
            .content_bytes = &module_bytes,
            .constants = &first_constants,
        },
    };
    var first = try pipeline.buildComputePipelineKey(allocator, first_descriptor);
    defer first.deinit(allocator);
    first_descriptor.compute.constants = &second_constants;
    var second = try pipeline.buildComputePipelineKey(allocator, first_descriptor);
    defer second.deinit(allocator);

    try std.testing.expect(!pipeline.CacheKey.eql(&first, &second));
}

// ---------------------------------------------------------------------------
// The store.
// ---------------------------------------------------------------------------

test "one descriptor is one pipeline and a changed layout is a second" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seam: Seam = .{};
    const backend = stubBackend(&seam);

    var recorder: ErrorRecorder = .{};
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");

    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const relaid = descriptor(&second_layout_bytes, vertex_entry_point, &fragment_words);

    const first = try pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, io, first);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(pipeline.Kind.render, try pipeline.queryKind(&guard, &device, first));
    try std.testing.expect(try pipeline.vkPipeline(&guard, &device, first) != null);
    try std.testing.expectEqual(base.layout.handle, try pipeline.vkLayout(&guard, &device, first));

    const state = try pipeline.renderState(&guard, &device, first);
    try std.testing.expect(state.fragment_stage_present);
    try std.testing.expectEqual(@as(usize, 1), state.color_formats.items.len);

    // The cache hit. Dawn looks before it builds
    // (`src/dawn/native/Device.cpp:2216`-`:2219`) and returns what it found
    // without touching the driver, so the create count must not move.
    const hit = try pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, io, hit);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(first.ptr, hit.ptr);
    try std.testing.expectEqual(
        try pipeline.vkPipeline(&guard, &device, first),
        try pipeline.vkPipeline(&guard, &device, hit),
    );

    // The miss the acceptance names. Same shaders, same state, one different
    // layout, and the driver is reached a second time.
    const miss = try pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, relaid, .user);
    defer releasePipelineUser(&device, &guard, io, miss);
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(usize, 2), store.queryPipelineCount(&guard));
    try std.testing.expect(first.ptr != miss.ptr);
    try std.testing.expect(
        try pipeline.vkPipeline(&guard, &device, miss) != try pipeline.vkPipeline(&guard, &device, first),
    );

    // The seam saw the layout the descriptor asked for, so the miss is a layout
    // miss and not a difference hiding somewhere else in the descriptor.
    try std.testing.expectEqual(relaid.layout.handle, seam.last_layout);

    // The key the next descriptor is compared against is the one the cache kept
    // (`src/pipeline/pipeline.zig:473-475`), so a key rebuilt from the same
    // descriptor finds this object and not a second one.
    var rebuilt = try pipeline.buildRenderPipelineKey(std.testing.allocator, base);
    defer rebuilt.deinit(std.testing.allocator);
    const object = try device.resolve(&guard, pipeline.Pipeline, first);
    try std.testing.expectEqual(object, store.pipelines.find(&guard, &rebuilt).?);

    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "compatible render pass handle identity changes neither the semantic key nor a cache hit" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    var compatible = base;
    compatible.compatible_render_pass = @ptrFromInt(96);
    try std.testing.expect(base.compatible_render_pass != compatible.compatible_render_pass);
    var base_key = try pipeline.buildRenderPipelineKey(allocator, base);
    defer base_key.deinit(allocator);
    var compatible_key = try pipeline.buildRenderPipelineKey(allocator, compatible);
    defer compatible_key.deinit(allocator);
    try std.testing.expect(pipeline.CacheKey.eql(&base_key, &compatible_key));
    try std.testing.expectEqual(base_key.contentHash(), compatible_key.contentHash());

    const first = try pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), first);
    const hit = try pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, compatible, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), hit);
    try std.testing.expectEqual(first.ptr, hit.ptr);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
}

test "render pipeline creation rejects a missing compatible render pass even on a cache hit" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    var desc = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    desc.compatible_render_pass = null;
    try std.testing.expectError(
        error.CompatibleRenderPassMissing,
        pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user),
    );
    try std.testing.expectEqual(@as(u32, 0), seam.create_count);
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const owned = try pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), owned);
    try std.testing.expectError(
        error.CompatibleRenderPassMissing,
        pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user),
    );
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
}

test "render cache hits own references until the final consumer releases" {
    try cachedConsumerReferences(.render);
}

test "compute cache hits own references until the final consumer releases" {
    try cachedConsumerReferences(.compute);
}

fn cachedConsumerReferences(kind: pipeline.Kind) !void {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var recorder: ErrorRecorder = .{};
    const gpa = allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch |err| std.debug.panic(
        "pipeline cache consumer cleanup failed: {s}",
        .{@errorName(err)},
    );

    const render = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const compute = specializedCompute(&canonical_constants);
    const first = try switch (kind) {
        .render => pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, render, .user),
        .compute => pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, compute, .user),
    };
    var first_owned = true;
    defer if (first_owned) releasePipelineUser(&device, &guard, io, first);
    const native = try pipeline.vkPipeline(&guard, &device, first);
    const alias = try switch (kind) {
        .render => pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, render, .user),
        .compute => pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, compute, .user),
    };
    var alias_owned = true;
    defer if (alias_owned) releasePipelineUser(&device, &guard, io, alias);
    try std.testing.expectEqual(first.ptr, alias.ptr);
    try std.testing.expectEqual(kind, try pipeline.queryKind(&guard, &device, alias));
    try std.testing.expectEqual(native, try pipeline.vkPipeline(&guard, &device, alias));
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));

    // A wrapper that cannot complete hands back only the reference its hit acquired.
    const alias_object = try device.resolve(&guard, pipeline.Pipeline, alias);
    try alias_object.header.releaseUserLocked(&guard, io);
    alias_owned = false;
    const remaining = try device.resolve(&guard, pipeline.Pipeline, first);
    try std.testing.expect(remaining.header.isAlive(&guard));
    try std.testing.expectEqual(kind, remaining.queryKind(&guard));
    try std.testing.expectEqual(native, try pipeline.vkPipeline(&guard, &device, first));
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u32, 0), seam.destroy_count);

    try remaining.header.releaseUserLocked(&guard, io);
    first_owned = false;
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(u32, 1), seam.destroy_count);
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, pipeline.Pipeline, first));
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, pipeline.Pipeline, alias));

    // The weak cache entry must not resurrect the object whose final reference left.
    const rebuilt = try switch (kind) {
        .render => pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, render, .user),
        .compute => pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, compute, .user),
    };
    var rebuilt_owned = true;
    defer if (rebuilt_owned) releasePipelineUser(&device, &guard, io, rebuilt);
    try std.testing.expect(first.ptr != rebuilt.ptr);
    try std.testing.expect(native != try pipeline.vkPipeline(&guard, &device, rebuilt));
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(u32, 1), seam.destroy_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    const rebuilt_object = try device.resolve(&guard, pipeline.Pipeline, rebuilt);
    try rebuilt_object.header.releaseUserLocked(&guard, io);
    rebuilt_owned = false;
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(u32, 2), seam.destroy_count);
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "a destroyed pipeline is not what the cache hands back" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seam: Seam = .{};
    const backend = stubBackend(&seam);

    var recorder: ErrorRecorder = .{};
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");

    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const original = try pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, io, original);
    const original_pipeline = try pipeline.vkPipeline(&guard, &device, original);
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    const alias = try pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, io, alias);
    try std.testing.expectEqual(original.ptr, alias.ptr);

    try device.destroy(&guard, io, original);
    try std.testing.expectEqual(@as(u32, 1), seam.destroy_count);
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    const retired_header = try device.resolveReference(&guard, original);
    try std.testing.expectEqual(retired_header, try device.resolveReference(&guard, alias));
    try retired_header.retainUserLocked(&guard);
    try retired_header.releaseUserLocked(&guard, io);
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, pipeline.Pipeline, original));
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, pipeline.Pipeline, alias));

    // Explicit retirement evicts the weak key immediately but keeps both owned aliases.
    const rebuilt = try pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, base, .user);
    defer releasePipelineUser(&device, &guard, io, rebuilt);
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try std.testing.expect(original.ptr != rebuilt.ptr);
    try std.testing.expect(try pipeline.vkPipeline(&guard, &device, rebuilt) != original_pipeline);

    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}
test "public cache hits acquire a user alias from a live lease-only pipeline" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var recorder: ErrorRecorder = .{};
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(gpa, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(gpa, device.borrow().objectList());
    defer store.deinit(&guard) catch @panic("pipeline store still has live entries");
    const desc = specializedCompute(&canonical_constants);
    const first = try pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, desc, .user);
    var first_owned = true;
    defer if (first_owned) releasePipelineUser(&device, &guard, io, first);
    const header = try device.resolveReference(&guard, first);
    try header.retainLeaseLocked(&guard);
    defer header.releaseLeaseLocked(&guard, io);
    try header.releaseUserLocked(&guard, io);
    first_owned = false;
    try std.testing.expectEqual(@as(u64, 0), device.borrow().objectList().user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    const hit = try pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, desc, .user);
    defer releasePipelineUser(&device, &guard, io, hit);
    try std.testing.expectEqual(first.ptr, hit.ptr);
    try std.testing.expectEqual(@as(u64, 1), device.borrow().objectList().user_reference_count);
    try std.testing.expectEqual(@as(u64, 2), device.borrow().objectList().total_reference_count);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(u32, 0), seam.destroy_count);
}
test "cache hit allocation failures preserve the existing owner and use one stable allocator" {
    for ([_]pipeline.Kind{ .compute, .render }) |kind| {
        var reached_success = false;
        var saw_allocation_failure = false;
        for (0..64) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const gpa = failing.allocator();
            const io = std.testing.io;
            var seam: Seam = .{};
            const backend = stubBackend(&seam);
            var recorder: ErrorRecorder = .{};
            var object_mutex: std.Io.Mutex = .init;
            var device = core.Device.init(gpa, .{
                .object_mutex = &object_mutex,
                .uncaptured_context = @ptrCast(&recorder),
                .uncaptured_callback = ErrorRecorder.record,
            });
            var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
            defer guard.unlock(io);
            defer device.deinit(gpa, &guard) catch @panic("cache fault left a core reference");
            var store = pipeline.PipelineStore.init(gpa, device.borrow().objectList());
            defer store.deinit(&guard) catch @panic("cache fault left a weak entry");
            const compute = specializedCompute(&canonical_constants);
            var render = descriptor(&first_layout_bytes, "main", &specialization_bytes);
            render.vertex.content_bytes = &specialization_bytes;
            render.vertex.constants = &canonical_constants;
            render.fragment.?.constants = &equivalent_constants;
            const first = try switch (kind) {
                .compute => pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, compute, .user),
                .render => pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, render, .user),
            };
            defer releasePipelineUser(&device, &guard, io, first);
            // Arm the existing allocator after publication; no second allocator identity.
            failing.fail_index = failing.alloc_index + fail_index;
            if (fail_index == 0) {
                const allocations_before_mismatch = failing.alloc_index;
                try std.testing.expectError(error.AllocatorMismatch, switch (kind) {
                    .compute => pipeline.createComputePipelineLocked(std.testing.allocator, io, &guard, &device, &store, &backend, compute, .user),
                    .render => pipeline.createRenderPipelineLocked(std.testing.allocator, io, &guard, &device, &store, &backend, render, .user),
                });
                try std.testing.expectEqual(allocations_before_mismatch, failing.alloc_index);
                try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
                try std.testing.expectEqual(@as(u64, 1), device.borrow().objectList().user_reference_count);
                try std.testing.expectEqual(@as(u32, 1), seam.create_count);
            }
            const result = switch (kind) {
                .compute => pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, compute, .user),
                .render => pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, render, .user),
            };
            const hit = result catch |err| switch (err) {
                error.OutOfMemory => {
                    saw_allocation_failure = true;
                    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
                    try std.testing.expectEqual(@as(u64, 1), device.borrow().objectList().total_reference_count);
                    try std.testing.expectEqual(@as(u64, 1), device.borrow().objectList().user_reference_count);
                    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
                    try std.testing.expectEqual(@as(u32, 0), seam.destroy_count);
                    try std.testing.expect(try pipeline.vkPipeline(&guard, &device, first) != null);
                    continue;
                },
                else => return err,
            };
            defer releasePipelineUser(&device, &guard, io, hit);
            try std.testing.expectEqual(first.ptr, hit.ptr);
            try std.testing.expectEqual(@as(u64, 2), device.borrow().objectList().user_reference_count);
            try std.testing.expectEqual(@as(u32, 1), seam.create_count);
            reached_success = true;
            break;
        }
        try std.testing.expect(saw_allocation_failure);
        try std.testing.expect(reached_success);
    }
}

// Replay must use descriptor contents, not driver handle identity.
test "layout replay metadata covers constants and descriptor prefix compatibility" {
    const binding: vulkan.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
    };
    const groups = [_]pipeline.GroupLayout{
        .{ .handle = @ptrFromInt(16), .bindings = &.{binding} },
        .{ .handle = @ptrFromInt(32), .bindings = &.{} },
        .{ .handle = @ptrFromInt(48), .bindings = &.{binding} },
    };
    const input: pipeline.LayoutInput = .{ .groups = &groups, .immediate_size = 256 };
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try input.immediateMask());
    try std.testing.expectEqual(@as(u8, 0b101), try input.bindGroupMask());
    try std.testing.expectEqual(@as(u64, 0), try (pipeline.LayoutInput{}).immediateMask());
    const unaligned: pipeline.LayoutInput = .{ .immediate_size = 3 };
    try std.testing.expectError(error.ImmediateSizeInvalid, unaligned.immediateMask());
    const oversized: pipeline.LayoutInput = .{ .immediate_size = 260 };
    try std.testing.expectError(error.ImmediateSizeInvalid, oversized.immediateMask());

    const allocator = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &object_mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(allocator, &guard) catch @panic("metadata arena still has references");
    const left = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
    defer left.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
    left.group_layouts = &groups;
    left.immediate_size = 16;
    left.immediate_stages = vulkan.VK_SHADER_STAGE_ALL;
    var other_groups = groups;
    other_groups[0].handle = @ptrFromInt(64);
    const right = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
    defer right.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
    right.group_layouts = &other_groups;
    right.immediate_size = left.immediate_size;
    right.immediate_stages = left.immediate_stages;
    try std.testing.expect(left.compatibleForGroup(&guard, right, 2));
    var changed_binding = binding;
    changed_binding.stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT;
    other_groups[0].bindings = &.{changed_binding};
    try std.testing.expect(!left.compatibleForGroup(&guard, right, 2));
    other_groups[0].bindings = &.{binding};
    right.immediate_size = 20;
    try std.testing.expect(!left.compatibleForGroup(&guard, right, 0));
    right.immediate_size = 16;
    right.immediate_stages = vulkan.VK_SHADER_STAGE_COMPUTE_BIT;
    try std.testing.expect(!left.compatibleForGroup(&guard, right, 0));
}

fn createUnpublishedMetadataPipeline(
    gpa: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
) core.CreateError!*pipeline.Pipeline {
    const object = try arena.create(gpa, guard, pipeline.Pipeline, .{
        .kind = .pipeline,
        .initial_reference = .user,
    });
    object.* = .{ .header = object.header, .allocator = gpa };
    return object;
}

// Layout metadata must survive mutation or release of descriptor scratch arrays.
test "pipeline layout metadata owns descriptor contents and derives required masks" {
    const allocator = std.testing.allocator;
    var bindings = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 2,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_COMPUTE_BIT,
    }};
    const groups = [_]pipeline.GroupLayout{.{
        .handle = @ptrFromInt(16),
        .bindings = &bindings,
    }};
    var object_mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &object_mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(allocator, &guard) catch @panic("metadata arena still has references");
    const object = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
    defer object.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
    try object.initLayout(&guard, .{ .groups = &groups, .immediate_size = 12 });
    defer {
        for (object.group_layouts) |group| {
            var owned = group;
            owned.deinit(allocator);
        }
        allocator.free(object.group_layouts);
    }
    try std.testing.expectEqual(@as(u64, 0b111), object.immediate_mask);
    try std.testing.expectEqual(@as(u32, 12), object.immediate_size);
    try std.testing.expectEqual(@as(u8, 1), object.bind_group_mask);
    try std.testing.expectEqual(@as(vulkan.VkShaderStageFlags, vulkan.VK_SHADER_STAGE_ALL), object.immediate_stages);
    bindings[0].binding = 9;
    try std.testing.expectEqual(@as(u32, 2), object.group_layouts[0].bindings[0].binding);
}

test "pipeline refuses unsupported external texture layout metadata" {
    const allocator = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &object_mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(allocator, &guard) catch @panic("metadata arena still has references");
    const object = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
    defer object.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
    const groups = [_]pipeline.GroupLayout{.{
        .handle = null,
        .bindings = &.{},
        .has_external_texture = true,
    }};
    try std.testing.expectError(error.ExternalTexturePipelineUnsupported, object.initLayout(&guard, .{ .groups = &groups }));
    try std.testing.expectEqual(@as(usize, 0), object.group_layouts.len);
}

test "pipeline layouts accept the replay group limit and reject the next group before allocation or native creation" {
    const limit = dusk.command.constants.max_bind_groups;
    const binding: vulkan.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
    };
    const groups: [limit + 1]pipeline.GroupLayout = @splat(.{
        .handle = null,
        .bindings = &.{binding},
    });
    const valid: pipeline.LayoutInput = .{ .groups = groups[0..limit] };
    const invalid: pipeline.LayoutInput = .{ .groups = &groups };
    try std.testing.expectEqual(@as(u8, (1 << limit) - 1), try valid.bindGroupMask());
    try std.testing.expectError(error.BindGroupCountAboveLimit, invalid.bindGroupMask());

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var object_mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &object_mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(allocator, &guard) catch @panic("metadata arena still has references");
    const object = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
    defer object.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
    try object.initLayout(&guard, valid);
    defer {
        for (object.group_layouts) |group| {
            var owned = group;
            owned.deinit(allocator);
        }
        allocator.free(object.group_layouts);
    }
    try std.testing.expectEqual(@as(usize, limit), object.group_layouts.len);
    try std.testing.expectEqual(try valid.bindGroupMask(), object.bind_group_mask);

    const rejected = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
    defer rejected.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.BindGroupCountAboveLimit, rejected.initLayout(&guard, invalid));
    try std.testing.expectEqual(@as(usize, 0), rejected.group_layouts.len);
    const procs = std.mem.zeroes(dusk.vk.dispatch.DeviceProcs);
    try std.testing.expectError(error.MissingDeviceProc, pipeline.LayoutInput.create(&procs, null, valid.groups, 0));
    try std.testing.expectError(error.TooManyBindGroups, pipeline.LayoutInput.create(&procs, null, &groups, 0));
}

// Fail every owned metadata allocation, including immutable sampler copies.
test "layout metadata allocation rollback releases partial descriptor definitions" {
    const samplers = [_]vulkan.VkSampler{@ptrFromInt(64)};
    const bindings = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = &samplers,
    }};
    const groups = [_]pipeline.GroupLayout{.{ .handle = null, .bindings = &bindings }};
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{},
        );
        const allocator = failing.allocator();
        var object_mutex: std.Io.Mutex = .init;
        var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &object_mutex });
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
        defer guard.unlock(std.testing.io);
        defer arena.deinit(allocator, &guard) catch @panic("metadata arena still has references");
        const object = try createUnpublishedMetadataPipeline(allocator, &guard, &arena);
        defer object.header.discardUnpublishedLocked(&guard) catch @panic("metadata creator escaped");
        failing.fail_index = failing.alloc_index + fail_index;
        if (fail_index < 3) {
            try std.testing.expectError(error.OutOfMemory, object.initLayout(&guard, .{ .groups = &groups }));
            try std.testing.expectEqual(@as(usize, 0), object.group_layouts.len);
        } else {
            try object.initLayout(&guard, .{ .groups = &groups });
            defer {
                for (object.group_layouts) |group| {
                    var owned = group;
                    owned.deinit(allocator);
                }
                allocator.free(object.group_layouts);
            }
            try std.testing.expect(object.group_layouts[0].compatible(groups[0]));
            try std.testing.expect(
                object.group_layouts[0].bindings[0].pImmutableSamplers != bindings[0].pImmutableSamplers,
            );
        }
    }
}

test "pipeline cache key includes native group definitions and immediate range" {
    const allocator = std.testing.allocator;
    var original = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    var baseline = try pipeline.buildRenderPipelineKey(allocator, original);
    defer baseline.deinit(allocator);
    original.layout.immediate_size = 4;
    var constants = try pipeline.buildRenderPipelineKey(allocator, original);
    defer constants.deinit(allocator);
    try std.testing.expect(!cache_key.CacheKey.eql(&baseline, &constants));
    original.layout.immediate_size = 0;
    original.layout.groups = &.{.{ .handle = null, .bindings = &.{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
    }} }};
    var descriptors = try pipeline.buildRenderPipelineKey(allocator, original);
    defer descriptors.deinit(allocator);
    try std.testing.expect(!cache_key.CacheKey.eql(&baseline, &descriptors));
}

// A compare-only stencil test still depends on the replayed reference value.
test "compare-only stencil state enables stencil testing" {
    const render = dusk.pipeline.pipeline_render;
    const state: pipeline.DepthStencilState = .{
        .format = vulkan.VK_FORMAT_D24_UNORM_S8_UINT,
        .stencil_front = .{ .compare = .equal },
    };
    try std.testing.expect(render.usesStencil(state));
    var back_only = state;
    back_only.stencil_front.compare = .always;
    back_only.stencil_back.compare = .not_equal;
    try std.testing.expect(render.usesStencil(back_only));
    back_only.stencil_back.compare = .always;
    try std.testing.expect(!render.usesStencil(back_only));
}

test "constant blend factors validate in color and alpha components" {
    const render = dusk.pipeline.pipeline_render;
    for ([_]render.BlendFactor{ .constant, .one_minus_constant }) |factor| {
        const component: render.BlendComponent = .{
            .src_factor = factor,
            .dst_factor = factor,
            .operation = .add,
        };
        var desc = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
        desc.color_targets = &.{.{
            .format = color_format,
            .blend = .{ .color = component, .alpha = component },
        }};
        try render.validateRenderPipelineDescriptor(desc);
    }
}

test "color write masks accept no writes and reject bits outside color components" {
    const render = dusk.pipeline.pipeline_render;
    var desc = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    var targets = [_]pipeline.ColorTargetState{.{ .format = color_format }};
    desc.color_targets = &targets;
    for (0..16) |mask| {
        targets[0].write_mask = @intCast(mask);
        try render.validateRenderPipelineDescriptor(desc);
    }
    targets[0].write_mask = 0x10;
    try std.testing.expectError(
        error.ColorWriteMaskInvalid,
        render.validateRenderPipelineDescriptor(desc),
    );
}

test "stencil faces accept valid enums only when the format has a stencil aspect" {
    const render = dusk.pipeline.pipeline_render;
    const stencil_formats = [_]vulkan.VkFormat{
        vulkan.VK_FORMAT_S8_UINT,
        vulkan.VK_FORMAT_D16_UNORM_S8_UINT,
        vulkan.VK_FORMAT_D24_UNORM_S8_UINT,
        vulkan.VK_FORMAT_D32_SFLOAT_S8_UINT,
    };
    const depth_formats = [_]vulkan.VkFormat{
        vulkan.VK_FORMAT_D16_UNORM,
        vulkan.VK_FORMAT_X8_D24_UNORM_PACK32,
        vulkan.VK_FORMAT_D32_SFLOAT,
    };
    inline for (.{ "stencil_front", "stencil_back" }) |face_name| {
        inline for (.{ "compare", "fail_op", "depth_fail_op", "pass_op" }) |field_name| {
            const Field = @FieldType(render.StencilFaceState, field_name);
            inline for (std.meta.tags(Field)) |value| {
                for (stencil_formats) |format| {
                    var state: pipeline.DepthStencilState = .{ .format = format };
                    @field(@field(state, face_name), field_name) = value;
                    try render.validateDepthStencil(state, format, false);
                }
                for (depth_formats) |format| {
                    var state: pipeline.DepthStencilState = .{ .format = format };
                    try render.validateDepthStencil(state, format, false);
                    @field(@field(state, face_name), field_name) = value;
                    const unused = if (comptime std.mem.eql(u8, field_name, "compare"))
                        value == .always
                    else
                        value == .keep;
                    if (unused) {
                        try render.validateDepthStencil(state, format, false);
                    } else {
                        try std.testing.expectError(
                            error.StencilStateWithoutStencilAspect,
                            render.validateDepthStencil(state, format, false),
                        );
                    }
                }
            }
        }
    }
}

// Module-scope overrides do not depend on which entry point uses them.
const specialization_words = [_]u32{
    0x07230203, 0x00010000, 0,          10,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0005000f, 5,          5,          0x6e69616d, 0,
    0x00060010, 5,          17,         1,          1,
    1,
    0x00040005, 4,          0x756c6176, 0x65, // OpName %4 "value".
    0x00040047, 4,          1,          7,
    0x00040047, 9,          1,          9,
    0x00020013, 1,          0x00030021, 2,
    1,          0x00040015, 3,          32,
    0,          0x00040032, 3,          4,
    1,          0x00030016, 8,          32,
    0x00040032, 8,          9,          0x3f800000,
    0x00050036, 1,          5,          0,
    2,          0x000200f8, 6,          0x00050080,
    3,          7,          4,          4,
    0x000100fd, 0x00010038,
};

fn specializedCompute(
    constants: []const dusk.api.descriptors.ConstantEntry,
) pipeline.ComputePipelineDescriptor {
    return .{
        .limits = .{ .max_workgroup_size = .{ 1, 1, 1 }, .max_invocations = 1 },
        .layout = .{ .handle = @ptrFromInt(16), .content_bytes = &first_layout_bytes },
        .compute = .{
            .stage = .compute,
            .entry_point = "main",
            .content_bytes = &specialization_bytes,
            .constants = constants,
        },
    };
}

const canonical_constants = [_]dusk.api.descriptors.ConstantEntry{
    .{ .key = "7", .value = 2 },
    .{ .key = "9", .value = 1 },
};
const equivalent_constants = [_]dusk.api.descriptors.ConstantEntry{
    .{ .key = "9", .value = 1.00000001 },
    .{ .key = "value", .value = 2.75 },
};

test "override keys canonicalize aliases order and converted scalar bits" {
    const allocator = std.testing.allocator;
    var first = try pipeline.buildComputePipelineKey(
        allocator,
        specializedCompute(&canonical_constants),
    );
    defer first.deinit(allocator);
    var same = try pipeline.buildComputePipelineKey(
        allocator,
        specializedCompute(&equivalent_constants),
    );
    defer same.deinit(allocator);
    try std.testing.expect(pipeline.CacheKey.eql(&first, &same));
    var render = descriptor(&first_layout_bytes, "main", &fragment_words);
    render.vertex.content_bytes = &specialization_bytes;
    render.vertex.constants = &canonical_constants;
    var render_first = try pipeline.buildRenderPipelineKey(allocator, render);
    defer render_first.deinit(allocator);
    render.vertex.constants = &equivalent_constants;
    var render_same = try pipeline.buildRenderPipelineKey(allocator, render);
    defer render_same.deinit(allocator);
    try std.testing.expect(pipeline.CacheKey.eql(&render_first, &render_same));
}

test "native compute overrides reach Vulkan and invalid cached requests are refused" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    const first = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, specializedCompute(&canonical_constants), .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), first);
    try std.testing.expectEqual(@as(u32, 2), seam.specialization_counts[2]);
    try std.testing.expectEqual([2]u32{ 7, 9 }, seam.specialization_ids[2]);
    try std.testing.expectEqual([2]u32{ 2, 0x3f800000 }, seam.specialization_values[2]);
    const same = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, specializedCompute(&equivalent_constants), .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), same);
    try std.testing.expectEqual(first.ptr, same.ptr);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    const invalid = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "7", .value = -1 }};
    try std.testing.expectError(
        error.ConstantOutOfRange,
        pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, specializedCompute(&invalid), .user),
    );
    const duplicate = [_]dusk.api.descriptors.ConstantEntry{
        .{ .key = "7", .value = 2 }, .{ .key = "value", .value = 2 },
    };
    try std.testing.expectError(
        error.DuplicateConstant,
        pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, specializedCompute(&duplicate), .user),
    );
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    const changed = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "7", .value = 3 }};
    const other = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, specializedCompute(&changed), .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), other);
    try std.testing.expect(other.ptr != first.ptr);
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(u32, 3), seam.specialization_values[2][0]);
}

test "native graphics applies both vertex and fragment specialization payloads" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var render = descriptor(&first_layout_bytes, "main", &specialization_bytes);
    render.vertex.content_bytes = &specialization_bytes;
    render.vertex.constants = &canonical_constants;
    render.fragment.?.constants = &equivalent_constants;
    const first = try pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, render, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), first);
    for (0..2) |stage| {
        try std.testing.expectEqual(@as(u32, 2), seam.specialization_counts[stage]);
        try std.testing.expectEqual([2]u32{ 7, 9 }, seam.specialization_ids[stage]);
        try std.testing.expectEqual([2]u32{ 2, 0x3f800000 }, seam.specialization_values[stage]);
    }
    render.vertex.constants = &equivalent_constants;
    render.fragment.?.constants = &canonical_constants;
    const same = try pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, render, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), same);
    try std.testing.expectEqual(first.ptr, same.ptr);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    const invalid = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "missing", .value = 1 }};
    render.fragment.?.constants = &invalid;
    try std.testing.expectError(
        error.UnknownConstant,
        pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, render, .user),
    );
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    const changed = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "7", .value = 4 }};
    render.fragment.?.constants = &changed;
    const other = try pipeline.createRenderPipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, render, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), other);
    try std.testing.expect(other.ptr != first.ptr);
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(u32, 4), seam.specialization_values[1][0]);
}

test "override byte sources handle unaligned input and reject malformed word counts" {
    const allocator = std.testing.allocator;
    var bytes: [@sizeOf(@TypeOf(specialization_words)) + 1]u8 align(4) = undefined;
    @memcpy(bytes[1..], &specialization_bytes);
    var compute = specializedCompute(&canonical_constants);
    compute.compute.content_bytes = bytes[1..];
    var key = try pipeline.buildComputePipelineKey(allocator, compute);
    defer key.deinit(allocator);
    compute.compute.content_bytes = bytes[1 .. bytes.len - 1];
    try std.testing.expectError(
        error.SpirvMalformed,
        pipeline.buildComputePipelineKey(allocator, compute),
    );
    compute.compute.content_bytes = &.{};
    try std.testing.expectError(
        error.ComputeStageMissing,
        pipeline.buildComputePipelineKey(allocator, compute),
    );
    var malformed_bytes = specialization_bytes;
    std.mem.writeInt(u32, malformed_bytes[4..][0..4], 0x00010700, .little);
    compute.compute.content_bytes = &malformed_bytes;
    try std.testing.expectError(
        error.SpirvVersionUnsupported,
        pipeline.buildComputePipelineKey(allocator, compute),
    );
    malformed_bytes = specialization_bytes;
    std.mem.writeInt(u32, malformed_bytes[20..][0..4], 0, .little);
    try std.testing.expectError(
        error.SpirvMalformed,
        pipeline.buildComputePipelineKey(allocator, compute),
    );
}

test "specialized key preparation frees every fail-N allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, specializedKeyAllocation, .{});
}

fn specializedKeyAllocation(allocator: std.mem.Allocator) !void {
    var compute = try pipeline.buildComputePipelineKey(
        allocator,
        specializedCompute(&canonical_constants),
    );
    defer compute.deinit(allocator);
    var render = descriptor(&first_layout_bytes, "main", &specialization_bytes);
    render.vertex.content_bytes = &specialization_bytes;
    render.vertex.constants = &canonical_constants;
    render.fragment.?.constants = &equivalent_constants;
    var graphics = try pipeline.buildRenderPipelineKey(allocator, render);
    defer graphics.deinit(allocator);
}

test "specialized factories roll back native objects and store entries at every allocation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        specializedFactoryAllocation,
        .{ threaded.io(), false, false },
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        specializedFactoryAllocation,
        .{ threaded.io(), true, false },
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        specializedFactoryAllocation,
        .{ threaded.io(), false, true },
    );
}

fn specializedFactoryAllocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    graphics: bool,
    defaults: bool,
) !void {
    var recorder: ErrorRecorder = .{};
    const gpa = allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch @panic("specialized pipeline store cleanup failed");
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    const result = if (graphics) result: {
        var render = descriptor(&first_layout_bytes, "main", &specialization_bytes);
        render.vertex.content_bytes = &specialization_bytes;
        render.vertex.constants = &canonical_constants;
        render.fragment.?.constants = &equivalent_constants;
        break :result pipeline.createRenderPipelineLocked(gpa, io, &guard, &device, &store, &backend, render, .user);
    } else pipeline.createComputePipelineLocked(gpa, io, &guard, &device, &store, &backend, specializedCompute(if (defaults) &.{} else &canonical_constants), .user);
    const handle = result catch |err| {
        try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
        try std.testing.expectEqual(@as(u64, 0), device.borrow().objectList().total_reference_count);
        try std.testing.expectEqual(@as(u64, 0), device.borrow().objectList().user_reference_count);
        try std.testing.expectEqual(seam.create_count, seam.destroy_count);
        return err;
    };
    defer releasePipelineUser(&device, &guard, io, handle);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    try device.destroy(&guard, io, handle);
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(seam.create_count, seam.destroy_count);
}

test "compute workgroup limits include exact axes and checked invocation product" {
    const compute = dusk.pipeline.pipeline_compute;
    const limits: pipeline.ComputeLimits = .{
        .max_workgroup_size = .{ 4, 3, 2 },
        .max_invocations = 24,
    };
    try compute.validateWorkgroupSize(.{ 4, 3, 2 }, limits);
    for (0..3) |axis| {
        var size = limits.max_workgroup_size;
        size[axis] += 1;
        try std.testing.expectError(
            error.WorkgroupAxisAboveLimit,
            compute.validateWorkgroupSize(size, limits),
        );
        size = limits.max_workgroup_size;
        size[axis] = 0;
        try std.testing.expectError(
            error.WorkgroupAxisZero,
            compute.validateWorkgroupSize(size, limits),
        );
    }
    try std.testing.expectError(
        error.WorkgroupInvocationsAboveLimit,
        compute.validateWorkgroupSize(.{ 4, 3, 2 }, .{
            .max_workgroup_size = limits.max_workgroup_size,
            .max_invocations = 23,
        }),
    );
    const maximum = std.math.maxInt(u32);
    try std.testing.expectError(
        error.WorkgroupProductOverflow,
        compute.validateWorkgroupSize(.{ maximum, maximum, maximum }, .{
            .max_workgroup_size = .{ maximum, maximum, maximum },
            .max_invocations = maximum,
        }),
    );
}

test "compute cached defaults still validate selected limits and authoritative entry point" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var desc = specializedCompute(&.{});
    const handle = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), handle);
    desc.limits.max_invocations = 0;
    try std.testing.expectError(error.WorkgroupInvocationsAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc = specializedCompute(&.{});
    desc.compute.entry_point = "absent";
    try std.testing.expectError(error.StageMissingForEntryPoint, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc.compute.entry_point = "main";
    desc.compute.content_bytes = &.{};
    try std.testing.expectError(error.ComputeStageMissing, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
}

const workgroup_id_words = [_]u32{
    0x07230203, 0x00010300, 0,          12,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0005000f, 5,          5,          0x6e69616d, 0,
    0x0006014b, 5,          38,         4,          9,
    10,
    0x00040005, 4, 0x74646977, 0x68, // "width".
    0x00030005, 11,         0x37, // Numeric name "7" must not shadow SpecId 7.
    0x00040047, 4,          1,
    7,          0x00040047, 9,
    1,          7,          0x00040047,
    11,         1,          8,
    0x00020013, 1,          0x00030021,
    2,          1,          0x00040015,
    3,          32,         0,
    0x00040032, 3,          4,
    2,          0x00040032, 3,
    9,          2,          0x0004002b,
    3,          10,         1,
    0x00040032, 3,          11,
    99,         0x00050036, 1,
    5,          0,          2,
    0x000200f8, 6,          0x000100fd,
    0x00010038,
};
const workgroup_id_bytes = spirvBytes(&workgroup_id_words);

fn workgroupCompute(
    constants: []const dusk.api.descriptors.ConstantEntry,
) pipeline.ComputePipelineDescriptor {
    var desc = specializedCompute(constants);
    desc.compute.content_bytes = &workgroup_id_bytes;
    desc.local_size_id_supported = true;
    desc.limits = .{ .max_workgroup_size = .{ 3, 3, 1 }, .max_invocations = 9 };
    return desc;
}

test "compute workgroup defaults overrides shared IDs numeric names and feature gate" {
    const allocator = std.testing.allocator;
    var defaults = try pipeline.buildComputePipelineKey(allocator, workgroupCompute(&.{}));
    defer defaults.deinit(allocator);
    const named = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "width", .value = 3 }};
    const numbered = [_]dusk.api.descriptors.ConstantEntry{.{ .key = "7", .value = 3 }};
    var first = try pipeline.buildComputePipelineKey(allocator, workgroupCompute(&named));
    defer first.deinit(allocator);
    var same = try pipeline.buildComputePipelineKey(allocator, workgroupCompute(&numbered));
    defer same.deinit(allocator);
    try std.testing.expect(pipeline.CacheKey.eql(&first, &same));
    try std.testing.expect(!pipeline.CacheKey.eql(&first, &defaults));
    var desc = workgroupCompute(&named);
    desc.limits.max_invocations = 8;
    try std.testing.expectError(
        error.WorkgroupInvocationsAboveLimit,
        pipeline.buildComputePipelineKey(allocator, desc),
    );
    desc = workgroupCompute(&named);
    desc.limits.max_workgroup_size[0] = 2;
    try std.testing.expectError(
        error.WorkgroupAxisAboveLimit,
        pipeline.buildComputePipelineKey(allocator, desc),
    );
    desc = workgroupCompute(&.{.{ .key = "7", .value = 0 }});
    try std.testing.expectError(
        error.WorkgroupAxisZero,
        pipeline.buildComputePipelineKey(allocator, desc),
    );
    desc = workgroupCompute(&.{});
    desc.local_size_id_supported = false;
    try std.testing.expectError(
        error.LocalSizeIdUnsupported,
        pipeline.buildComputePipelineKey(allocator, desc),
    );
}

test "compute workgroup default and specialized keys clean every allocation failure" {
    // SafeAllocator remaps depend on its current bucket fill. Force the
    // allocate-copy-free path so every fail-N pass has the same allocation count.
    const backing = std.testing.allocator;
    const allocator: std.mem.Allocator = .{
        .ptr = backing.ptr,
        .vtable = &.{
            .alloc = backing.vtable.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = backing.vtable.free,
        },
    };
    try std.testing.checkAllAllocationFailures(
        allocator,
        workgroupKeyAllocation,
        .{},
    );
}

fn workgroupKeyAllocation(allocator: std.mem.Allocator) !void {
    var defaults = try pipeline.buildComputePipelineKey(allocator, workgroupCompute(&.{}));
    defer defaults.deinit(allocator);
    var specialized = try pipeline.buildComputePipelineKey(
        allocator,
        workgroupCompute(&.{.{ .key = "7", .value = 3 }}),
    );
    defer specialized.deinit(allocator);
}

const missing_workgroup_words = specialization_words[0..15].* ++ specialization_words[21..].*;
const missing_workgroup_bytes = spirvBytes(&missing_workgroup_words);
const vertex_stage_bytes = @embedFile("fixtures/triangle.vert.spv");
const zero_workgroup_words = words: {
    var words = workgroup_id_words;
    words[52] = 0;
    break :words words;
};
const zero_workgroup_bytes = spirvBytes(&zero_workgroup_words);
const overflow_workgroup_words = words: {
    var words = specialization_words;
    words[18] = std.math.maxInt(u32);
    words[19] = std.math.maxInt(u32);
    words[20] = std.math.maxInt(u32);
    break :words words;
};
const overflow_workgroup_bytes = spirvBytes(&overflow_workgroup_words);

test "compute metadata and reflected stage reject before native creation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var desc = specializedCompute(&.{});
    desc.compute.content_bytes = &missing_workgroup_bytes;
    try std.testing.expectError(error.SpirvWorkgroupMissing, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc.compute.content_bytes = vertex_stage_bytes;
    desc.compute.entry_point = "vs_main";
    try std.testing.expectError(error.StageMismatch, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc = workgroupCompute(&.{.{ .key = "7", .value = 4 }});
    try std.testing.expectError(error.WorkgroupAxisAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc = workgroupCompute(&.{.{ .key = "7", .value = 0 }});
    try std.testing.expectError(error.WorkgroupAxisZero, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc = workgroupCompute(&.{});
    desc.local_size_id_supported = false;
    try std.testing.expectError(error.LocalSizeIdUnsupported, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc = workgroupCompute(&.{});
    desc.compute.content_bytes = &zero_workgroup_bytes;
    try std.testing.expectError(error.WorkgroupAxisZero, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc = specializedCompute(&.{});
    desc.compute.content_bytes = &overflow_workgroup_bytes;
    desc.limits = .{
        .max_workgroup_size = .{
            std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32),
        },
        .max_invocations = std.math.maxInt(u32),
    };
    try std.testing.expectError(error.WorkgroupProductOverflow, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    try std.testing.expectEqual(@as(u32, 0), seam.create_count);
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
}

test "cached workgroup overrides reject tighter axes and total limits without native creation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var desc = workgroupCompute(&.{.{ .key = "7", .value = 3 }});
    const handle = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), handle);
    desc.limits.max_workgroup_size[1] = 2;
    try std.testing.expectError(error.WorkgroupAxisAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc.limits.max_workgroup_size[1] = 3;
    desc.limits.max_invocations = 8;
    try std.testing.expectError(error.WorkgroupInvocationsAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
}

// Distinct functions share a name across models. The vertex function writes
// Position; this is a valid two-stage module, not a duplicate-entry fixture.
const shared_name_prefix = [_]u32{
    0x07230203, 0x00010300, 0,          16, 0,
    0x00020011, 1,          0x0003000e, 0,  1,
};
const shared_name_vertex_entry = [_]u32{ 0x0006000f, 0, 13, 0x6e69616d, 0, 10 };
const shared_name_compute_entry = [_]u32{ 0x0005000f, 5, 12, 0x6e69616d, 0 };
const shared_name_body = [_]u32{
    0x00060010, 12, 17, 1, 1, 1, // LocalSize.
    0x00040047, 10,         11,         0, // BuiltIn Position.
    0x00020013, 1,          0x00030021, 2,
    1,          0x00040015, 3,          32,
    0,          0x00030016, 4,          32,
    0x00040017, 5,          4,          4,
    0x00040020, 6,          3,          5,
    0x0004002b, 4,          7,          0,
    0x0004002b, 4,          8,          0x3f800000,
    0x0007002c, 5,          9,          7,
    7,          7,          8,          0x0004003b,
    6,          10,         3,          0x00050036,
    1,          12,         0,          2,
    0x000200f8, 14,         0x000100fd, 0x00010038,
    0x00050036, 1,          13,         0,
    2,          0x000200f8, 15,         0x0003003e,
    10,         9,          0x000100fd, 0x00010038,
};
const vertex_first_words = shared_name_prefix ++ shared_name_vertex_entry ++
    shared_name_compute_entry ++ shared_name_body;
const compute_first_words = shared_name_prefix ++ shared_name_compute_entry ++
    shared_name_vertex_entry ++ shared_name_body;
const vertex_first_bytes = spirvBytes(&vertex_first_words);
const compute_first_bytes = spirvBytes(&compute_first_words);

test "compute selects same-name model pair in either declaration order before cache lookup" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var owned_handles: [4]core.Handle = undefined;
    var owned_count: usize = 0;
    defer for (owned_handles[0..owned_count]) |handle| releasePipelineUser(&device, &guard, threaded.io(), handle);
    for ([_][]const u8{ &vertex_first_bytes, &compute_first_bytes }, 0..) |bytes, index| {
        var desc = specializedCompute(&.{});
        desc.compute.content_bytes = bytes;
        const first = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user);
        owned_handles[owned_count] = first;
        owned_count += 1;
        const same = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user);
        owned_handles[owned_count] = same;
        owned_count += 1;
        try std.testing.expectEqual(first.ptr, same.ptr);
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), seam.create_count);
        try std.testing.expectEqual(index + 1, store.queryPipelineCount(&guard));
        desc.limits.max_invocations = 0;
        try std.testing.expectError(error.WorkgroupInvocationsAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), seam.create_count);
        try std.testing.expectEqual(index + 1, store.queryPipelineCount(&guard));
    }
}

// WorkgroupSize = (2,1,1), but LocalSizeId = (1,1,1). The builtin
// controls the resolved size; the execution mode still requires maintenance4.
const builtin_local_size_id_words = [_]u32{
    0x07230203, 0x00010300, 0,          10,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0005000f, 5,          8,          0x6e69616d, 0,
    0x0006014b, 8,          38,         5,          5,
    5,
    0x00040047, 7,          11,         25, // BuiltIn WorkgroupSize.
    0x00020013, 1,          0x00030021, 2,
    1,          0x00040015, 3,          32,
    0,          0x0004002b, 3,          4,
    2,          0x0004002b, 3,          5,
    1,          0x00040017, 6,          3,
    3,          0x0006002c, 6,          7,
    4,          5,          5,          0x00050036,
    1,          8,          0,          2,
    0x000200f8, 9,          0x000100fd, 0x00010038,
};
const builtin_local_size_id_bytes = spirvBytes(&builtin_local_size_id_words);

test "builtin precedence preserves LocalSizeId feature gate on native miss and cache hit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder: ErrorRecorder = .{};
    defer std.testing.expectEqual(@as(u64, 0), recorder.count) catch
        @panic("pipeline fixture reported an uncaptured core error");
    const gpa = std.testing.allocator;
    var object_mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &object_mutex,
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    var guard = core.ObjectGuard.lockUncancelable(threaded.io(), device.borrow().objectList());
    defer guard.unlock(threaded.io());
    defer device.deinit(gpa, &guard) catch @panic("pipeline core owner still has references");
    var store = pipeline.PipelineStore.init(std.testing.allocator, device.borrow().objectList());
    defer store.deinit(&guard) catch unreachable;
    var seam: Seam = .{};
    const backend = stubBackend(&seam);
    var desc = specializedCompute(&.{});
    desc.compute.content_bytes = &builtin_local_size_id_bytes;
    desc.limits = .{ .max_workgroup_size = .{ 2, 1, 1 }, .max_invocations = 2 };
    try std.testing.expectError(error.LocalSizeIdUnsupported, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    try std.testing.expectEqual(@as(u32, 0), seam.create_count);
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    desc.local_size_id_supported = true;
    desc.limits.max_workgroup_size[0] = 1;
    try std.testing.expectError(error.WorkgroupAxisAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    try std.testing.expectEqual(@as(u32, 0), seam.create_count);
    try std.testing.expectEqual(@as(usize, 0), store.queryPipelineCount(&guard));
    desc.limits.max_workgroup_size[0] = 2;
    const first = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), first);
    const same = try pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user);
    defer releasePipelineUser(&device, &guard, threaded.io(), same);
    try std.testing.expectEqual(first.ptr, same.ptr);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
    desc.local_size_id_supported = false;
    try std.testing.expectError(error.LocalSizeIdUnsupported, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc.local_size_id_supported = true;
    desc.limits.max_workgroup_size[0] = 1;
    try std.testing.expectError(error.WorkgroupAxisAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    desc.limits.max_workgroup_size[0] = 2;
    desc.limits.max_invocations = 1;
    try std.testing.expectError(error.WorkgroupInvocationsAboveLimit, pipeline.createComputePipelineLocked(gpa, threaded.io(), &guard, &device, &store, &backend, desc, .user));
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount(&guard));
}
