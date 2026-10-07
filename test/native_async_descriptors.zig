const std = @import("std");
const dusk = @import("dusk");
const owned = dusk.engine.native_async_descriptors;
const handles = dusk.engine.native_async_handles;
const fixture = @import("fixtures/specialization_compute.zig");
const vk = dusk.platform.vulkan_bindings;

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: dusk.core.ErrorView) void {
    @panic("unexpected uncaptured error");
}

fn exportShader(device: *dusk.engine.Device, shader: *dusk.engine.native_resources.ShaderModule) dusk.api.ShaderModule {
    var guard = dusk.core.ObjectGuard.lockUncancelable(std.testing.io, device.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    return handles.exportResource(dusk.api.ShaderModule, device, &guard, shader, .shader_module);
}

const AllocationFailureBoundary = struct {
    failing: std.testing.FailingAllocator,
    relevant_allocations: usize = 0,

    fn beginDeviceTeardown(self: *AllocationFailureBoundary) void {
        self.relevant_allocations = self.failing.alloc_index;
        // Destruction diagnostics may recover OOM with their static fallback.
        // Keep the same allocator, but do not inject into that unrelated path.
        self.failing.fail_index = std.math.maxInt(usize);
    }
};

fn exerciseCompute(allocator: std.mem.Allocator, use_callee: bool, failure_boundary: ?*AllocationFailureBoundary) !void {
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{});
    defer instance.deinit(allocator, io) catch @panic("instance deinit failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter deinit failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var context: u8 = 0;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &context,
        .uncaptured_callback = uncaptured,
    });
    defer {
        if (failure_boundary) |boundary| boundary.beginDeviceTeardown();
        device.deinit(allocator, io) catch @panic("device deinit failed");
    }
    var callee_words: std.ArrayList(u32) = .empty;
    defer callee_words.deinit(allocator);
    if (use_callee) {
        try callee_words.appendSlice(allocator, &fixture.words);
        callee_words.items[3] = 20;
        var offset: usize = 5;
        var replaced = false;
        while (offset < callee_words.items.len) {
            const count: usize = callee_words.items[offset] >> 16;
            if (callee_words.items[offset] & 0xffff == 54) {
                // Move original work into %17. Entry %1 only calls that helper.
                callee_words.items[offset + 2] = 17;
                replaced = true;
                break;
            }
            offset += count;
        }
        if (!replaced) return error.BadFixture;
        try callee_words.appendSlice(allocator, &.{
            0x00050036, 2, 1, 0, 3, // OpFunction %void %1 None %function_type.
            0x000200f8, 18, // OpLabel %18.
            0x00040039, 2, 19, 17, // OpFunctionCall %void %19 %17.
            0x000100fd, // OpReturn.
            0x00010038, // OpFunctionEnd.
        });
    }
    const shader = try device.createShaderModule(allocator, io, .{
        .words = if (use_callee) callee_words.items else &fixture.words,
    });
    var shader_owned = true;
    defer if (shader_owned) device.release(allocator, io, shader) catch @panic("shader release failed");
    const exported = exportShader(&device, shader);
    var key = [_]u8{'7'};
    var entry = [_]u8{ 'm', 'a', 'i', 'n' };
    var constants = [_]dusk.api.descriptors.ConstantEntryChain{.{ .key = &key, .value = 4 }};
    var descriptor: dusk.api.descriptors.ComputePipelineDescriptorChain = .{
        .compute = .{ .module = exported, .entry_point = &entry, .constant_count = 1, .constants = &constants },
    };
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &descriptor);
    defer prepared.deinit(io);
    // Release caller ownership and invalidate every borrowed descriptor field.
    // The actual native pipeline must still validate the original named override.
    try device.release(allocator, io, shader);
    shader_owned = false;
    key[0] = 'x';
    @memset(&entry, 'x');
    constants[0].value = std.math.nan(f64);
    descriptor.compute.module = .{ .handle = null };
    const options = try prepared.options(allocator, io, &device);
    const pipeline = try device.createComputePipeline(allocator, io, options);
    defer device.release(allocator, io, pipeline) catch @panic("pipeline release failed");
    const output = try device.createBuffer(allocator, io, .{ .size = 4, .usage = .{ .storage = true, .copy_src = true } });
    defer device.release(allocator, io, output) catch @panic("output release failed");
    const readback = try device.createBuffer(allocator, io, .{ .size = 4, .usage = .{ .map_read = true, .copy_dst = true } });
    defer device.release(allocator, io, readback) catch @panic("readback release failed");
    const group = try device.createBindGroup(allocator, io, .{
        .layout = pipeline.layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{ .binding = 0, .buffer = output, .offset = 0, .size = 4, .kind = .storage, .stages = .{ .compute = true } } }},
    });
    defer device.release(allocator, io, group) catch @panic("group release failed");
    var encoder = dusk.command.command_encoder.CommandEncoder.init(allocator, device.core.borrow(), .{});
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{
            .pipeline = try pipeline.ref(&guard),
            .requirements = .{
                .bind_group_layout_mask = 1,
                .bind_group_layout_ids = .{ @intFromPtr(&pipeline.layout.groups[0].header), 0, 0, 0 },
            },
        });
        try pass.setBindGroup(.{
            .index = 0,
            .group = try group.ref(&guard),
            .layout_id = @intFromPtr(&pipeline.layout.groups[0].header),
            .min_binding_buffer_size = 4,
            .buffers = &.{.{ .buffer = try output.ref(&guard), .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags() }},
        });
        try pass.dispatch(.{ .x = 1, .y = 1, .z = 1 });
        try pass.end();
        try encoder.copyBufferToBuffer(.{ .source = try output.ref(&guard), .destination = try readback.ref(&guard), .size = 4 });
    }
    var finished = try encoder.finish();
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    const serial = try device.submit(allocator, io, &finished);
    try device.wait(io, serial);
    {
        var queue_lease = try device.getQueue(io);
        defer queue_lease.deinit(io);
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        _ = try readback.ref(&guard);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 4 });
        try std.testing.expectEqual(
            dusk.engine.buffer.Buffer.MapCompletion.mapped,
            try readback.native.completeMap(generation, serial),
        );
        const mapped = try readback.native.getConstMappedRange(0, 4);
        // Original override 4 and original default bias 3, not mutated NaN/key.
        try std.testing.expectEqual(@as(u32, 43), std.mem.readInt(u32, mapped[0..4], .little));
    }
    try device.unmapBuffer(io, readback);
}

test "owned compute survives descriptor mutation and caller shader release with real auto layout" {
    try exerciseCompute(std.testing.allocator, false, null);
}

test "all descriptor and GPU allocation refusals unwind leases and real auto layout" {
    var baseline: AllocationFailureBoundary = .{
        .failing = std.testing.FailingAllocator.init(std.testing.allocator, .{}),
    };
    try exerciseCompute(baseline.failing.allocator(), false, &baseline);
    const allocation_count = baseline.relevant_allocations;
    for (0..allocation_count) |fail_index| {
        var attempt: AllocationFailureBoundary = .{
            .failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
            }),
        };
        if (exerciseCompute(attempt.failing.allocator(), false, &attempt)) |_| {
            if (attempt.failing.has_induced_failure) {
                return error.SwallowedOutOfMemoryError;
            }
            return error.NondeterministicMemoryUsage;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            try std.testing.expectEqual(attempt.failing.allocated_bytes, attempt.failing.freed_bytes);
        }
    }
}

test "stencil masks distinguish native pipeline content keys" {
    const allocator = std.testing.allocator;
    const render = dusk.pipeline.pipeline_render;
    var first: dusk.pipeline.pipeline.CacheKey = .{};
    defer first.deinit(allocator);
    var second: dusk.pipeline.pipeline.CacheKey = .{};
    defer second.deinit(allocator);
    try render.appendDepthStencilKey(allocator, &first, .{ .format = vk.VK_FORMAT_D24_UNORM_S8_UINT, .stencil_read_mask = 0x12, .stencil_write_mask = 0x34 });
    try render.appendDepthStencilKey(allocator, &second, .{ .format = vk.VK_FORMAT_D24_UNORM_S8_UINT, .stencil_read_mask = 0x13, .stencil_write_mask = 0x34 });
    try std.testing.expect(!std.mem.eql(u8, first.bytes.items, second.bytes.items));
}

const ComputeCase = enum { count, null_count, allocator, missing_entry, unique_entry, wrong_stage, foreign_owner, ambiguous, explicit_layout };

fn computeCase(case: ComputeCase) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{});
    defer instance.deinit(allocator, io) catch @panic("instance deinit failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter deinit failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var context: u8 = 0;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &context,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("device deinit failed");
    const module = try device.createShaderModule(allocator, io, .{ .words = &fixture.words });
    defer device.release(allocator, io, module) catch @panic("shader release failed");
    var chain: dusk.api.descriptors.ComputePipelineDescriptorChain = .{ .compute = .{ .module = exportShader(&device, module) } };
    switch (case) {
        .count => {
            const constants = [_]dusk.api.descriptors.ConstantEntryChain{.{ .key = "7", .value = 1 }};
            chain.compute.constant_count = 2;
            chain.compute.constants = &constants;
            try std.testing.expectError(error.InvalidRequest, owned.OwnedCompute.prepare(allocator, io, &device, &chain));
        },
        .null_count => {
            chain.compute.constant_count = std.math.maxInt(usize);
            try std.testing.expectError(error.InvalidRequest, owned.OwnedCompute.prepare(allocator, io, &device, &chain));
        },
        .allocator => {
            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
            try std.testing.expectError(error.InvalidRequest, owned.OwnedCompute.prepare(failing.allocator(), io, &device, &chain));
        },
        .missing_entry => {
            chain.compute.entry_point = "absent";
            var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            try std.testing.expectError(error.EntryPointMissing, prepared.options(allocator, io, &device));
        },
        .unique_entry => {
            var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            const result = try device.createComputePipeline(allocator, io, try prepared.options(allocator, io, &device));
            defer device.release(allocator, io, result) catch @panic("pipeline release failed");
            var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try std.testing.expect(result.native.vk_pipeline != null);
        },
        .wrong_stage => {
            const words = try dusk.spirv.wordsFromBytes(allocator, @embedFile("fixtures/triangle.vert.spv"));
            defer allocator.free(words);
            const vertex = try device.createShaderModule(allocator, io, .{ .words = words });
            defer device.release(allocator, io, vertex) catch @panic("vertex release failed");
            chain.compute = .{ .module = exportShader(&device, vertex), .entry_point = "vs_main" };
            var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            try std.testing.expectError(error.EntryPointStageMismatch, prepared.options(allocator, io, &device));
        },
        .ambiguous => {
            var words: std.ArrayList(u32) = .empty;
            defer words.deinit(allocator);
            try words.appendSlice(allocator, fixture.words[0..15]);
            try words.appendSlice(allocator, &.{ 0x0005000f, 5, 1, 0x65726f6d, 0 });
            try words.appendSlice(allocator, fixture.words[15..]);
            const ambiguous = try device.createShaderModule(allocator, io, .{ .words = words.items });
            defer device.release(allocator, io, ambiguous) catch @panic("ambiguous release failed");
            chain.compute.module = exportShader(&device, ambiguous);
            var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            try std.testing.expectError(error.EntryPointAmbiguous, prepared.options(allocator, io, &device));
        },
        .explicit_layout => {
            const group = try device.createBindGroupLayout(allocator, io, .{ .entries = &.{.{
                .binding_number = 0,
                .visibility = .{ .compute = true },
                .kind = .{ .buffer = .{ .binding_type = .storage, .has_dynamic_offset = false, .min_binding_size = 0 } },
            }} });
            defer device.release(allocator, io, group) catch @panic("group release failed");
            const pipeline_layout = try device.createPipelineLayout(allocator, io, .{ .groups = &.{group} });
            var layout_owned = true;
            defer if (layout_owned) device.release(allocator, io, pipeline_layout) catch @panic("layout release failed");
            {
                var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
                defer guard.unlock(io);
                chain.layout = handles.exportResource(dusk.api.PipelineLayout, &device, &guard, pipeline_layout, .pipeline_layout);
            }
            var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            try device.release(allocator, io, pipeline_layout);
            layout_owned = false;
            chain.layout = null;
            const result = try device.createComputePipeline(allocator, io, try prepared.options(allocator, io, &device));
            defer device.release(allocator, io, result) catch @panic("pipeline release failed");
        },
        .foreign_owner => {
            var second_adapters = try instance.enumerateAdapters(allocator, io, .{
                .backend_type = .vulkan,
                .feature_level = .core,
                .power_preference = .undefined_,
            });
            defer second_adapters.deinit(io) catch @panic("second adapter list deinit failed");
            if (second_adapters.items.len == 0) return error.NoPhysicalDevice;
            var second = try second_adapters.items[0].createDevice(allocator, io, .{
                .adapter = &second_adapters.items[0],
                .feature_level = .core,
                .uncaptured_context = &context,
                .uncaptured_callback = uncaptured,
            });
            defer second.deinit(allocator, io) catch @panic("second deinit failed");
            try std.testing.expectError(error.InvalidOwner, owned.OwnedCompute.prepare(allocator, io, &second, &chain));
            // Refusal must not consume the original owner or shader.
            var prepared = try owned.OwnedCompute.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            const result = try device.createComputePipeline(allocator, io, try prepared.options(allocator, io, &device));
            defer device.release(allocator, io, result) catch @panic("pipeline release failed");
        },
    }
}

test "descriptor count beyond slice is refused before walking" {
    try computeCase(.count);
}
test "descriptor nonzero null count and size overflow are refused" {
    try computeCase(.null_count);
}
test "descriptor allocator identity is checked before allocation" {
    try computeCase(.allocator);
}
test "missing entry is accepted descriptor validation rather than startup refusal" {
    try computeCase(.missing_entry);
}
test "omitted unique reflected entry creates real native compute pipeline" {
    try computeCase(.unique_entry);
}
test "entry from the wrong SPIRV stage cannot create a pipeline" {
    try computeCase(.wrong_stage);
}
test "foreign module refusal preserves the true owner" {
    try computeCase(.foreign_owner);
}
test "ambiguous omitted entry is a native descriptor validation failure" {
    try computeCase(.ambiguous);
}
test "explicit layout remains usable after caller releases its last user reference" {
    try computeCase(.explicit_layout);
}

const RenderCase = enum { mutate, stride, offset, buffer_count, attribute_count, target_count, extension, stencil_defaults, depth_compare_default, dual_source };

fn renderCase(case: RenderCase) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var instance = dusk.engine.Instance.init(.{});
    defer instance.deinit(allocator, io) catch @panic("instance deinit failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter deinit failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var context: u8 = 0;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &context,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("device deinit failed");
    const vertex_words = try dusk.spirv.wordsFromBytes(allocator, @embedFile("fixtures/triangle.vert.spv"));
    defer allocator.free(vertex_words);
    const fragment_words = try dusk.spirv.wordsFromBytes(allocator, @embedFile("fixtures/triangle.frag.spv"));
    defer allocator.free(fragment_words);
    const vertex = try device.createShaderModule(allocator, io, .{ .words = vertex_words });
    defer device.release(allocator, io, vertex) catch @panic("vertex release failed");
    const fragment = try device.createShaderModule(allocator, io, .{ .words = fragment_words });
    defer device.release(allocator, io, fragment) catch @panic("fragment release failed");
    // Both names are exact-length, non-sentinel arrays. Adjacent owned stage
    // storage must not become part of either Vulkan C entry-point string.
    var vertex_entry = [_]u8{ 'v', 's', '_', 'm', 'a', 'i', 'n' };
    var fragment_entry = [_]u8{ 'f', 's', '_', 'm', 'a', 'i', 'n' };
    var blend: dusk.api.BlendState = .{ .color = .{}, .alpha = .{} };
    var targets = [_]dusk.api.descriptors.ColorTargetStateChain{.{ .format = .rgba8_unorm, .blend = &blend }};
    var fragment_state: dusk.api.descriptors.FragmentStateChain = .{
        .module = exportShader(&device, fragment),
        .entry_point = &fragment_entry,
        .target_count = 1,
        .targets = &targets,
    };
    var depth: dusk.api.descriptors.DepthStencilStateChain = .{
        .format = .depth24_plus_stencil8,
        .depth_write_enabled = .false_,
        .depth_compare = .always,
        .stencil_front = .{ .compare = .equal, .pass_op = .replace },
        .stencil_back = .{},
        .stencil_read_mask = 0x12,
        .stencil_write_mask = 0x34,
    };
    var chain: dusk.api.descriptors.RenderPipelineDescriptorChain = .{
        .vertex = .{ .module = exportShader(&device, vertex), .entry_point = &vertex_entry },
        .primitive = .{ .strip_index_format = .undefined_ },
        .multisample = .{},
        .depth_stencil = &depth,
        .fragment = &fragment_state,
    };
    var attributes = [_]dusk.api.descriptors.VertexAttributeChain{.{ .format = .float32, .offset = 0, .shader_location = 0 }};
    var buffers = [_]dusk.api.descriptors.VertexBufferLayoutChain{.{ .step_mode = .vertex, .array_stride = 4, .attribute_count = 1, .attributes = &attributes }};
    switch (case) {
        .mutate => {},
        .dual_source => {
            blend.color.src_factor = .src1_alpha;
            var prepared = try owned.OwnedRender.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            try std.testing.expectError(error.DualSourceBlendingNotEnabled, prepared.options(allocator, io, &device));
            return;
        },
        .stencil_defaults, .depth_compare_default => {
            if (case == .stencil_defaults) {
                depth.format = .stencil8;
                depth.depth_write_enabled = .undefined_;
            }
            depth.depth_compare = .undefined_;
            var prepared = try owned.OwnedRender.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            const result = try device.createRenderPipeline(allocator, io, try prepared.options(allocator, io, &device));
            defer device.release(allocator, io, result) catch @panic("pipeline release failed");
            var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try std.testing.expect(result.native.vk_pipeline != null);
            return;
        },
        .stride, .offset => {
            chain.vertex.buffer_count = 1;
            chain.vertex.buffers = &buffers;
            if (case == .stride) buffers[0].array_stride = @as(u64, std.math.maxInt(u32)) + 1 else attributes[0].offset = @as(u64, std.math.maxInt(u32)) + 1;
            var prepared = try owned.OwnedRender.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            if (case == .stride) try std.testing.expectError(error.VertexStrideOutOfRange, prepared.options(allocator, io, &device)) else try std.testing.expectError(error.VertexOffsetOutOfRange, prepared.options(allocator, io, &device));
            return;
        },
        .buffer_count => {
            chain.vertex.buffer_count = 1;
            try std.testing.expectError(error.InvalidRequest, owned.OwnedRender.prepare(allocator, io, &device, &chain));
            return;
        },
        .attribute_count => {
            chain.vertex.buffer_count = 1;
            chain.vertex.buffers = &buffers;
            buffers[0].attribute_count = 2;
            try std.testing.expectError(error.InvalidRequest, owned.OwnedRender.prepare(allocator, io, &device, &chain));
            return;
        },
        .target_count => {
            fragment_state.target_count = 2;
            try std.testing.expectError(error.InvalidRequest, owned.OwnedRender.prepare(allocator, io, &device, &chain));
            return;
        },
        .extension => {
            targets[0].color_target_state_expand_resolve_texture_dawn = .{ .enabled = false };
            var prepared = try owned.OwnedRender.prepare(allocator, io, &device, &chain);
            defer prepared.deinit(io);
            try std.testing.expectError(error.UnsupportedExtension, prepared.options(allocator, io, &device));
            return;
        },
    }
    var first = try owned.OwnedRender.prepare(allocator, io, &device, &chain);
    defer first.deinit(io);
    depth.stencil_write_mask = 0x35;
    var second = try owned.OwnedRender.prepare(allocator, io, &device, &chain);
    defer second.deinit(io);
    @memset(&vertex_entry, 'x');
    @memset(&fragment_entry, 'x');
    blend.color.operation = .undefined_;
    targets[0].format = .depth32_float;
    depth.depth_compare = .undefined_;
    fragment_state.module = .{ .handle = null };
    chain.vertex.module = .{ .handle = null };
    const first_options = try first.options(allocator, io, &device);
    const first_pipeline = try device.createRenderPipeline(allocator, io, first_options);
    defer device.release(allocator, io, first_pipeline) catch @panic("first release failed");
    const cached = try device.createRenderPipeline(allocator, io, first_options);
    defer device.release(allocator, io, cached) catch @panic("cached release failed");
    const different = try device.createRenderPipeline(allocator, io, try second.options(allocator, io, &device));
    defer device.release(allocator, io, different) catch @panic("different release failed");
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try std.testing.expect(first_pipeline.native.vk_pipeline != null);
    try std.testing.expectEqual(first_pipeline.native.vk_pipeline, cached.native.vk_pipeline);
    try std.testing.expect(first_pipeline.native.vk_pipeline != different.native.vk_pipeline);
}

test "owned render mutation survives native construction and nondefault stencil masks split cache" {
    try renderCase(.mutate);
}
test "render stride checked narrowing reaches accepted validation" {
    try renderCase(.stride);
}
test "render attribute offset checked narrowing reaches accepted validation" {
    try renderCase(.offset);
}
test "render buffer null count is refused before walking" {
    try renderCase(.buffer_count);
}
test "render attribute count beyond input slice is refused" {
    try renderCase(.attribute_count);
}
test "render target count beyond input slice is refused" {
    try renderCase(.target_count);
}
test "present unsupported target extension is rejected even when disabled" {
    try renderCase(.extension);
}
test "stencil only format resolves omitted depth fields for native construction" {
    try renderCase(.stencil_defaults);
}
test "disabled depth writes resolve omitted compare to always" {
    try renderCase(.depth_compare_default);
}
test "dual source factors require actual enabled native and high features" {
    try renderCase(.dual_source);
}
test "auto layout executes pre1.4 resources used only by a reachable callee" {
    try exerciseCompute(std.testing.allocator, true, null);
}
