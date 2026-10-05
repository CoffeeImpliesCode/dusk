//! The M14 cache shard: the key, and the store's "same pipeline or a new one".
//!
//! `docs/40-plan.md` §1 M14 puts the milestone's acceptance in
//! `test/render_pipeline.zig`, which runs it against a real Vulkan device and a
//! real driver. This file is the half that must not need one: the bytes the
//! cache decides on, and the bookkeeping that turns a hit into the same object
//! and a miss into a new one. `AGENTS.md` §3 makes that split the point of the
//! `command`/`pipeline` versus `engine` boundary, so a key defect is caught on
//! a host with no GPU and not only where one exists.
//!
//! **What the Vulkan seam is here.** Two counters and two handles. The seam is
//! six injected function pointers (`src/pipeline/pipeline_backend.zig:46-51`), so a
//! test supplies its own, and the assertions are about how many times the create
//! call is reached and what the store hands back. Nothing in this file claims a
//! driver, a compiled pipeline or a shader; `test/render_pipeline.zig` runs the
//! same three calls against a real device and reads a real `VkPipeline`.
//!
//! **The seam's counters live behind the device handle.** `Backend` has no
//! user-data field and `AGENTS.md` §2 forbids a file-scope counter, so the
//! `Seam` value is the `VkDevice` the two entry points are handed. One line of
//! pointer recovery buys an observable call count, which is the assertion that
//! proves a cache hit never reached the driver.
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
const vulkan = @import("vulkan");

const dusk = @import("dusk");

const cache_key = dusk.pipeline.cache_key;
const core = dusk.core;
const pipeline = dusk.pipeline.pipeline;

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

/// The two layout byte runs. Same length on purpose: the key is the kind word, a
/// length-prefixed layout run, and then the stage mask, so equal lengths leave
/// the stage mask at one index in both keys and the divergence this file
/// measures belongs to the layout alone.
const first_layout_bytes = [_]u8{ 's', 'e', 't', '0', 'b', 'i', 'n', 'd' };
const second_layout_bytes = [_]u8{ 's', 'e', 't', '1', 'b', 'n', 'd', 'X' };

/// Where the layout's run starts: one word for the kind
/// (`src/pipeline/cache_key.zig:104`) and one word for the length prefix
/// (`src/pipeline/cache_key.zig:58`).
const layout_run_start: usize = 2 * @sizeOf(u64);

/// The first byte at which the two runs disagree: `'0'` against `'1'`. The
/// runs share `set` by construction, so an index both fixtures hold is an
/// index at which a key that recorded the layout faithfully could not differ.
const layout_first_difference: usize = 3;

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
    pipeline_cache: vulkan.VkPipelineCache,
    create_info_count: u32,
    create_infos: [*c]const vulkan.VkGraphicsPipelineCreateInfo,
    allocator: [*c]const vulkan.VkAllocationCallbacks,
    out_pipelines: [*c]vulkan.VkPipeline,
) callconv(.c) vulkan.VkResult {
    // The arguments a driver would have refused the call over. Asserting them
    // here is what stops the stub from proving anything: a create count that
    // rose because the call was malformed would be a count, not a pipeline.
    std.debug.assert(pipeline_cache == null);
    std.debug.assert(allocator == null);
    std.debug.assert(create_info_count == 1);
    std.debug.assert(create_infos[0].layout != null);

    // A backend built without a device never gets called, so the null handle
    // means the seam answered a call its own `stubBackend` did not wire up.
    // The create entry point has a `VkResult` to return, so it reports it
    // rather than trapping.
    const seam = seamFromDevice(device) catch return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    seam.create_count += 1;
    seam.last_layout = create_infos[0].layout;
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
        .create_compute_pipelines = null,
        .create_pipeline_cache = null,
        .get_pipeline_cache_data = null,
        .destroy_pipeline = seamDestroyPipeline,
        .destroy_pipeline_cache = null,
    };
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
        context: *anyopaque,
        data: *const core.ErrorData,
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

test "the key records the layout, and the layout run is the only thing that moved" {
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

    // The prefix is the whole claim. The kind word and the length prefix agree,
    // which is the length prefix being honest, and the run's bytes from
    // `layout_first_difference` on are the ones that moved. A key that put the
    // layout last, or that hashed it into the digest instead of the bytes,
    // fails here.
    try std.testing.expect(first.bytes.items.len >= layout_run_start);
    try std.testing.expect(second.bytes.items.len >= layout_run_start);
    try std.testing.expectEqualSlices(
        u8,
        first.bytes.items[0..layout_run_start],
        second.bytes.items[0..layout_run_start],
    );
    // Paired rather than one `!=`, so a failure names the side that moved.
    try std.testing.expectEqual(
        @as(u8, '0'),
        first.bytes.items[layout_run_start + layout_first_difference],
    );
    try std.testing.expectEqual(
        @as(u8, '1'),
        second.bytes.items[layout_run_start + layout_first_difference],
    );

    // The run the key records is the run the caller supplied, byte for byte.
    try std.testing.expectEqualSlices(
        u8,
        &first_layout_bytes,
        first.bytes.items[layout_run_start .. layout_run_start + first_layout_bytes.len],
    );
    try std.testing.expectEqualSlices(
        u8,
        &second_layout_bytes,
        second.bytes.items[layout_run_start .. layout_run_start + second_layout_bytes.len],
    );
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

test "a render key and a compute key never compare equal" {
    const allocator = std.testing.allocator;

    var render = try pipeline.buildRenderPipelineKey(
        allocator,
        descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words),
    );
    defer render.deinit(allocator);
    var compute = try pipeline.buildComputePipelineKey(allocator, .{
        .label = "cache shard",
        .layout = .{
            // The layout bytes are an array, so the identity is the address of
            // the array and not a slice header's `ptr`. It is the value
            // `descriptor` hands the render key above, so the two keys differ
            // only where the test says they do.
            .handle = @ptrFromInt(@intFromPtr(&first_layout_bytes)),
            .content_bytes = &first_layout_bytes,
        },
        .compute = .{
            .stage = .compute,
            .entry_point = vertex_entry_point,
            .content_bytes = &vertex_words,
        },
    });
    defer compute.deinit(allocator);

    // The leading discriminator (`src/dawn/native/CacheKey.h:42`) is the whole
    // reason two keys over one layout are still two pipelines.
    try std.testing.expect(!pipeline.CacheKey.eql(&render, &compute));
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(cache_key.Kind.render_pipeline)),
        render.bytes.items[0],
    );
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(cache_key.Kind.compute_pipeline)),
        compute.bytes.items[0],
    );
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
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    defer device.deinit(std.testing.allocator);

    var store = pipeline.PipelineStore.init(std.testing.allocator);
    // Nothing here seeds a `VkPipelineCache` (the render path hands Vulkan a
    // null cache, `src/pipeline/pipeline_render.zig:972`), so the teardown
    // reaches no proc. A refusal is a loader defect and is named, not
    // dropped: `AGENTS.md` §3.1 makes a missing proc a value.
    defer store.deinit() catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const relaid = descriptor(&second_layout_bytes, vertex_entry_point, &fragment_words);

    const first = try pipeline.createRenderPipeline(io, &device, &store, &backend, base);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount());
    try std.testing.expectEqual(pipeline.Kind.render, try pipeline.queryKind(&device, first));
    try std.testing.expect(try pipeline.vkPipeline(&device, first) != null);
    try std.testing.expectEqual(base.layout.handle, try pipeline.vkLayout(&device, first));

    const state = try pipeline.renderState(&device, first);
    try std.testing.expect(state.fragment_stage_present);
    try std.testing.expectEqual(@as(usize, 1), state.color_formats.items.len);

    // The cache hit. Dawn looks before it builds
    // (`src/dawn/native/Device.cpp:2216`-`:2219`) and returns what it found
    // without touching the driver, so the create count must not move.
    const hit = try pipeline.createRenderPipeline(io, &device, &store, &backend, base);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount());
    try std.testing.expectEqual(first.ptr, hit.ptr);
    try std.testing.expectEqual(
        try pipeline.vkPipeline(&device, first),
        try pipeline.vkPipeline(&device, hit),
    );

    // The miss the acceptance names. Same shaders, same state, one different
    // layout, and the driver is reached a second time.
    const miss = try pipeline.createRenderPipeline(io, &device, &store, &backend, relaid);
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(usize, 2), store.queryPipelineCount());
    try std.testing.expect(first.ptr != miss.ptr);
    try std.testing.expect(
        try pipeline.vkPipeline(&device, miss) != try pipeline.vkPipeline(&device, first),
    );

    // The seam saw the layout the descriptor asked for, so the miss is a layout
    // miss and not a difference hiding somewhere else in the descriptor.
    try std.testing.expectEqual(relaid.layout.handle, seam.last_layout);

    // The key the next descriptor is compared against is the one the cache kept
    // (`src/pipeline/pipeline.zig:473-475`), so a key rebuilt from the same
    // descriptor finds this object and not a second one.
    var rebuilt = try pipeline.buildRenderPipelineKey(std.testing.allocator, base);
    defer rebuilt.deinit(std.testing.allocator);
    const object = try device.resolve(pipeline.Pipeline, first);
    try std.testing.expectEqual(object, store.pipelines.find(&rebuilt).?);

    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "a destroyed pipeline is not what the cache hands back" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seam: Seam = .{};
    const backend = stubBackend(&seam);

    var recorder: ErrorRecorder = .{};
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    defer device.deinit(std.testing.allocator);

    var store = pipeline.PipelineStore.init(std.testing.allocator);
    // Same reason as the teardown above: the map is empty, so a refusal can
    // only be a loader defect and is named rather than dropped.
    defer store.deinit() catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const original = try pipeline.createRenderPipeline(io, &device, &store, &backend, base);
    const original_pipeline = try pipeline.vkPipeline(&device, original);
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount());

    try device.destroy(original);
    try std.testing.expectEqual(@as(u32, 1), seam.destroy_count);
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount());

    // The entry is still in the map. Dawn's entry dies with the object
    // (`src/dawn/common/ContentLessObjectCacheable.h:55`) and the port's entry
    // dies with the arena block, so the create call prunes it first
    // (`src/pipeline/pipeline.zig:409`). The count is one again rather than
    // two, and the object is new rather than the dead one.
    const rebuilt = try pipeline.createRenderPipeline(io, &device, &store, &backend, base);
    try std.testing.expectEqual(@as(u32, 2), seam.create_count);
    try std.testing.expectEqual(@as(usize, 1), store.queryPipelineCount());
    try std.testing.expect(original.ptr != rebuilt.ptr);
    try std.testing.expect(try pipeline.vkPipeline(&device, rebuilt) != original_pipeline);

    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "the render path creates no VkPipelineCache and the map is bounded" {
    // The bound is the one difference from Dawn, which creates a cache per
    // pipeline key and never bounds the set
    // (`src/dawn/native/vulkan/DeviceVk.cpp:275`-`:295`). Each entry is a driver
    // allocation, so the port keeps at most `pipeline_cache_capacity` of them
    // (`src/pipeline/pipeline.zig:343`-`:347`).
    try std.testing.expectEqual(
        @as(usize, 32),
        pipeline.PipelineStore.pipeline_cache_capacity,
    );

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seam: Seam = .{};
    const backend = stubBackend(&seam);

    var recorder: ErrorRecorder = .{};
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&recorder),
        .uncaptured_callback = ErrorRecorder.record,
    });
    defer device.deinit(std.testing.allocator);

    var store = pipeline.PipelineStore.init(std.testing.allocator);
    // Same reason as the teardown above: the map is empty, so a refusal can
    // only be a loader defect and is named rather than dropped.
    defer store.deinit() catch |err| std.debug.panic(
        "M14: the store refused to stand down: {s}",
        .{@errorName(err)},
    );

    // The render path hands Vulkan a null cache
    // (`src/pipeline/pipeline_render.zig:972`), so nothing has created
    // one and the map is empty. That is the observable that M14 does not quietly
    // make a driver allocation per pipeline.
    try std.testing.expect(store.pipeline_caches.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), store.pipeline_caches.queryEntryCount());

    const base = descriptor(&first_layout_bytes, vertex_entry_point, &fragment_words);
    const created = try pipeline.createRenderPipeline(io, &device, &store, &backend, base);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expect(store.pipeline_caches.isEmpty());

    const hit = try pipeline.createRenderPipeline(io, &device, &store, &backend, base);
    try std.testing.expectEqual(created.ptr, hit.ptr);
    try std.testing.expectEqual(@as(u32, 1), seam.create_count);
    try std.testing.expectEqual(@as(u32, 0), seam.destroy_count);
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}
