//! Plain entry-point slices reach real Vulkan with terminated, independently owned names.
const std = @import("std");
const dusk = @import("dusk");
const compute_fixture = @import("fixtures/specialization_compute.zig");
const graphics_fixture = @import("fixtures/specialization_graphics.zig");
const engine = dusk.engine;
const core = dusk.core;
const pipeline = dusk.pipeline.pipeline;
const vk = dusk.platform.vulkan_bindings;
const t = std.testing;

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("entry-point fixture reported an uncaptured error");
}

fn release(device: *engine.Device, guard: *const core.ObjectGuard, io: std.Io, handle: core.Handle) void {
    const header = device.core.resolveReference(guard, handle) catch @panic("resolution failed");
    header.releaseUserLocked(guard, io) catch @panic("pipeline release failed");
}

test "compute and graphics factories terminate plain names and own persistent compute names" {
    const allocator = t.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter teardown failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var context_byte: u8 = 0;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &context_byte,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("device teardown failed");
    const group = try device.createBindGroupLayout(allocator, io, .{ .entries = &.{.{
        .binding_number = 0,
        .visibility = .{ .compute = true },
        .kind = .{ .buffer = .{
            .binding_type = .storage,
            .has_dynamic_offset = false,
            .min_binding_size = 0,
        } },
    }} });
    defer device.release(allocator, io, group) catch @panic("group release failed");
    const layout = try device.createPipelineLayout(allocator, io, .{ .groups = &.{group} });
    defer device.release(allocator, io, layout) catch @panic("layout release failed");
    const compute = try device.createShaderModule(allocator, io, .{ .words = &compute_fixture.words });
    defer device.release(allocator, io, compute) catch @panic("shader release failed");
    const vertex = try device.createShaderModule(allocator, io, .{ .words = &graphics_fixture.vertex_words });
    defer device.release(allocator, io, vertex) catch @panic("shader release failed");
    const fragment = try device.createShaderModule(allocator, io, .{ .words = &graphics_fixture.fragment_words });
    defer device.release(allocator, io, fragment) catch @panic("shader release failed");
    const context = device.native.?;
    var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    query.setSampleCount(1);
    query.setColor(.{
        .index = 0,
        .format = .rgba8_unorm,
        .load_op = .clear,
        .store_op = .store,
        .has_resolve_target = false,
        .render_to_single_sampled = false,
    });
    const pass = try context.render_pass_cache.getRenderPass(io, query);
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const input = try layout.input(&guard);
    // The byte after each selected slice is deliberately nonzero, including cache hits.
    var compute_name = [_]u8{ 'm', 'a', 'i', 'n', 'X', 0 };
    const compute_descriptor: pipeline.ComputePipelineDescriptor = .{
        .layout = input,
        .compute = .{
            .module = compute.native.vk_module,
            .entry_point = compute_name[0..4],
            .stage = .compute,
            .content_bytes = std.mem.sliceAsBytes(compute.words),
        },
        .limits = .{ .max_workgroup_size = .{ 256, 256, 64 }, .max_invocations = 256 },
    };
    const first = try pipeline.createComputePipelineLocked(
        allocator,
        io,
        &guard,
        &device.core,
        &context.pipeline_store.?,
        &context.pipeline_backend,
        compute_descriptor,
        .user,
    );
    defer release(&device, &guard, io, first);
    const hit = try pipeline.createComputePipelineLocked(
        allocator,
        io,
        &guard,
        &device.core,
        &context.pipeline_store.?,
        &context.pipeline_backend,
        compute_descriptor,
        .user,
    );
    defer release(&device, &guard, io, hit);
    try t.expectEqual(first.ptr, hit.ptr);
    const low = try device.core.resolve(&guard, pipeline.Pipeline, first);
    @memset(compute_name[0..4], 'Z');
    try t.expectEqualStrings("main", low.state.compute.entry_point.?);
    try t.expectEqual(@as(u8, 0), low.state.compute.entry_point.?[4]);
    const vertex_name = [_]u8{ 'm', 'a', 'i', 'n', 'X', 0 };
    const fragment_name = [_]u8{ 'm', 'a', 'i', 'n', 'Y', 0 };
    const render_descriptor: pipeline.RenderPipelineDescriptor = .{
        .compatible_render_pass = pass.render_pass,
        .layout = input,
        .vertex = .{
            .module = vertex.native.vk_module,
            .entry_point = vertex_name[0..4],
            .stage = .vertex,
            .content_bytes = std.mem.sliceAsBytes(vertex.words),
        },
        .fragment = .{
            .module = fragment.native.vk_module,
            .entry_point = fragment_name[0..4],
            .stage = .fragment,
            .content_bytes = std.mem.sliceAsBytes(fragment.words),
        },
        .color_targets = &.{.{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM }},
    };
    const render = try pipeline.createRenderPipelineLocked(
        allocator,
        io,
        &guard,
        &device.core,
        &context.pipeline_store.?,
        &context.pipeline_backend,
        render_descriptor,
        .user,
    );
    defer release(&device, &guard, io, render);
    const render_hit = try pipeline.createRenderPipelineLocked(
        allocator,
        io,
        &guard,
        &device.core,
        &context.pipeline_store.?,
        &context.pipeline_backend,
        render_descriptor,
        .user,
    );
    defer release(&device, &guard, io, render_hit);
    try t.expectEqual(render.ptr, render_hit.ptr);
    try t.expect((try device.core.resolve(&guard, pipeline.Pipeline, render)).vk_pipeline != null);
}
