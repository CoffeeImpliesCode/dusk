//! The M18 shard encodes one triangle through the public pure frontend, finishes
//! its command stream, replays it through the Vulkan engine, and submits it.
//! The checked-in shaders render into a 2x2 `rgba8unorm` target. Readback uses
//! a 256-byte row pitch and asserts all sixteen channels and untouched padding.
//!
//! The vertex shader places vertices at `(0, -0.8)`, `(0.8, 0.8)`, and
//! `(-0.8, 0.8)`. With WebGPU's flipped viewport, both row-zero pixel centres
//! are inside the triangle and both row-one centres are outside. The red tint
//! and blue clear distinguish a missing draw from a missing clear.
//! A second scene enables constant-factor blending. An encoded red constant
//! combines red source and blue destination into magenta covered pixels, while
//! uncovered pixels stay blue. Both scenes check all channels and padding.
//! Vertex and fragment specialization each run five scenes with unchanged shader
//! words. Named and numeric overrides change coverage or color. Reordered aliases
//! repeat the same live pipeline and preserve clear pixels and row padding.
//!
//! Resource creation uses Vulkan dispatch, but command recording belongs only
//! to replay. This shard requires no surface or swapchain. A transfer-to-host
//! barrier, coherent readback memory, and a completed queue fence precede every
//! pixel observation.

const std = @import("std");
const dusk = @import("dusk");
const specialization_graphics = @import("fixtures/specialization_graphics.zig");

const vulkan = dusk.platform.vulkan_bindings;
const dispatch = dusk.vk.dispatch;

const recording_context = dusk.engine.recording_context;
const render_pass_cache = dusk.engine.render_pass_cache;
const vulkan_device = dusk.engine.vulkan_device;
const engine_buffer = dusk.engine.buffer;
const pipeline = dusk.pipeline.pipeline;
const bind_group = dusk.engine.bind_group;
const descriptor_sets = dusk.pipeline.bind_group_descriptor_set;
const encoder = dusk.command.command_encoder;
const commands = dusk.command.commands;

pub const ShaderFixtures = struct {
    vertex_words: []const u32,
    fragment_words: []const u32,
    vertex_entry_point: [:0]const u8,
    fragment_entry_point: [:0]const u8,
    enable_constant_blend: bool = false,
    has_tint_binding: bool = true,
};

/// Borrow native handles without transferring their destruction to the wrapper.
pub fn borrowBuffer(
    context: engine_buffer.Device,
    allocation: BufferAllocation,
    size: u64,
    buffer_usage: dusk.api.BufferUsage,
) engine_buffer.Buffer {
    return .{
        .device = context,
        .handle = allocation.buffer,
        .allocation = .{
            .memory = allocation.memory,
            .offset = 0,
            .size = allocation.allocation_size,
            .memory_type_index = allocation.memory_type_index,
        },
        .mapped = null,
        .size = size,
        .allocated_size = allocation.allocation_size,
        .usage = buffer_usage,
        .internal_usage = engine_buffer.computeInternalBufferUsages(buffer_usage),
        .state = .unmapped,
        .map_mode = .none,
        .map_offset = 0,
        .map_size = 0,
        .is_mapped_at_creation = false,
        .is_data_initialized = true,
        .staging = null,
        .last_usage_serial = 0,
        .last_write_usage = 0,
        .last_write_shader_stage = .none,
        .read_usage = 0,
        .read_shader_stages = .none,
        .host_visible = true,
        .host_coherent = true,
    };
}

fn uncapturedError(
    allocator: std.mem.Allocator,
    _: std.Io,
    context: *anyopaque,
    data: dusk.core.ErrorView,
) void {
    _ = allocator;
    _ = context;
    _ = data;
    @panic("triangle resource creation reported an uncaptured error");
}

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
pub const SetupError = dispatch.Error || std.mem.Allocator.Error || error{
    DeviceProcMissing,
    HandleCreationReturnedNull,
    MapReturnedNull,
    NoHostVisibleMemoryType,
    EntryPointNameAbsent,
};

// --- What one submission needs ---------------------------------------------

/// A `VkBuffer` and the memory bound to it, created as a pair because neither
/// is usable without the other.
pub const BufferAllocation = struct {
    buffer: vulkan.VkBuffer,
    memory: vulkan.VkDeviceMemory,
    allocation_size: u64,
    memory_type_index: u32,
};

/// Everything one submission creates, so the teardown is one list in reverse
/// creation order rather than a dozen defers that interleave badly.
pub const Scene = struct {
    staging: BufferAllocation,
    uniform: BufferAllocation,
    fixtures: ShaderFixtures,

    /// Uses actual high factories. The returned pipeline owns its canonical dependencies.
    pub fn typedPipeline(
        self: *const Scene,
        gpa: std.mem.Allocator,
        io: std.Io,
        device: *dusk.engine.Device,
    ) !*dusk.engine.native_resources.Pipeline {
        return self.typedPipelineWithConstants(gpa, io, device, &.{}, &.{});
    }

    fn typedPipelineWithConstants(
        self: *const Scene,
        gpa: std.mem.Allocator,
        io: std.Io,
        device: *dusk.engine.Device,
        vertex_constants: []const dusk.api.ConstantEntry,
        fragment_constants: []const dusk.api.ConstantEntry,
    ) !*dusk.engine.native_resources.Pipeline {
        try checkEntryPoint(self.fixtures.vertex_words, self.fixtures.vertex_entry_point);
        try checkEntryPoint(self.fixtures.fragment_words, self.fixtures.fragment_entry_point);
        const entries = [_]dusk.pipeline.layout_internal.Entry{.{
            .binding_number = tint_binding,
            .visibility = .{ .fragment = true },
            .kind = .{ .buffer = .{
                .binding_type = .uniform,
                .has_dynamic_offset = false,
                .min_binding_size = uniform_byte_count,
            } },
        }};
        const group = try device.createBindGroupLayout(gpa, io, .{
            .entries = if (self.fixtures.has_tint_binding) &entries else &.{},
        });
        defer device.release(gpa, io, group) catch @panic("triangle group layout release failed");
        const layout = try device.createPipelineLayout(gpa, io, .{ .groups = &.{group} });
        defer device.release(gpa, io, layout) catch @panic("triangle layout release failed");
        const vertex = try device.createShaderModule(gpa, io, .{
            .words = self.fixtures.vertex_words,
        });
        defer device.release(gpa, io, vertex) catch @panic("triangle vertex release failed");
        const fragment = try device.createShaderModule(gpa, io, .{
            .words = self.fixtures.fragment_words,
        });
        defer device.release(gpa, io, fragment) catch @panic("triangle fragment release failed");
        return device.createRenderPipeline(gpa, io, .{
            .layout = layout,
            .vertex = .{
                .module = vertex,
                .entry_point = self.fixtures.vertex_entry_point,
                .stage = .vertex,
                .constants = vertex_constants,
            },
            .fragment = .{
                .module = fragment,
                .entry_point = self.fixtures.fragment_entry_point,
                .stage = .fragment,
                .constants = fragment_constants,
            },
            .color_targets = &.{.{
                .format = .rgba8_unorm,
                .blend = if (self.fixtures.enable_constant_blend) .{
                    .color = .{ .src_factor = .constant, .dst_factor = .one_minus_constant, .operation = .add },
                    .alpha = .{ .src_factor = .constant, .dst_factor = .one_minus_constant, .operation = .add },
                } else null,
            }},
        });
    }
};

/// The stand-in for `FencedDeleter::DeleteWhenUnused`
/// (`FramebufferCache.cpp:87`-`:89`). Nothing is in flight by the time an
/// eviction can happen here, because the only submission has already been
/// waited on, so the eviction destroys at once.
pub const FramebufferDeleter = struct {
    procs: *const dispatch.DeviceProcs,
    vk_device: vulkan.VkDevice,

    pub fn destroy(context: *anyopaque, framebuffer: vulkan.VkFramebuffer) void {
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
    try runTriangle(null, rgbaBytes(tint));
}

test "triangle: replayed blend constant changes covered pixels and preserves clear and padding" {
    // Red * constant red + blue * (one minus constant blue) gives magenta.
    // Alpha is 1 * 1 + 1 * (1 - 1), so it remains opaque.
    try runTriangle(.{ .r = 1, .g = 0, .b = 0, .a = 1 }, .{ 255, 0, 255, 255 });
}

test "triangle: vertex specialization changes coverage and canonical overrides reuse live pipelines" {
    try runSpecializedTriangle(.vertex);
}

test "triangle: fragment specialization changes color and canonical overrides reuse live pipelines" {
    try runSpecializedTriangle(.fragment);
}

test "triangle: graphics fixture specialization key allocation rolls back at every fail-N" {
    const allocation_limit = 256;
    for (0..allocation_limit) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        graphicsKeyAllocation(failing.allocator()) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        };
        return;
    }
    return error.GraphicsAllocationSweepExhausted;
}

fn graphicsKeyAllocation(allocator: std.mem.Allocator) !void {
    var key = try pipeline.buildRenderPipelineKey(allocator, .{
        .compatible_render_pass = null,
        .vertex = .{
            .stage = .vertex,
            .entry_point = specialization_graphics.entry_point,
            .content_bytes = std.mem.sliceAsBytes(&specialization_graphics.vertex_words),
            .constants = &.{
                .{ .key = "shift_x", .value = 0 },
                .{ .key = "shift_y", .value = -1 },
            },
        },
        .fragment = .{
            .stage = .fragment,
            .entry_point = specialization_graphics.entry_point,
            .content_bytes = std.mem.sliceAsBytes(&specialization_graphics.fragment_words),
            .constants = &.{
                .{ .key = "green", .value = 1 },
                .{ .key = "red", .value = 0 },
            },
        },
        .color_targets = &.{.{ .format = vulkan.VK_FORMAT_R8G8B8A8_UNORM }},
    });
    defer key.deinit(allocator);
    try std.testing.expect(key.bytes.items.len != 0);
}

fn runTriangle(blend_constant: ?commands.Color, covered_pixel: [4]u8) !void {
    const covered = [_][4]u8{ covered_pixel, covered_pixel };
    try runTriangleCases(.{
        .vertex_words = &vertex_words,
        .fragment_words = &fragment_words,
        .vertex_entry_point = vertex_entry_point,
        .fragment_entry_point = fragment_entry_point,
        .enable_constant_blend = blend_constant != null,
    }, blend_constant, &.{.{ .pixels = .{
        covered[0], covered[1], rgbaBytes(clear_colour), rgbaBytes(clear_colour),
    } }});
}

const GraphicsCase = struct {
    vertex_constants: []const dusk.api.ConstantEntry = &.{},
    fragment_constants: []const dusk.api.ConstantEntry = &.{},
    pixels: [4][4]u8,
    identity_index: usize = 0,
    unique_count: usize = 1,
};

fn runSpecializedTriangle(stage: pipeline.Stage) !void {
    const red = [4]u8{ 255, 0, 0, 255 };
    const green = [4]u8{ 0, 255, 0, 255 };
    const yellow = [4]u8{ 255, 255, 0, 255 };
    const blue = rgbaBytes(clear_colour);
    const default_pixels = [4][4]u8{ red, red, blue, blue };
    const first_pixels = if (stage == .vertex)
        [4][4]u8{ blue, blue, red, red }
    else
        [4][4]u8{ green, green, blue, blue };
    const second_pixels = if (stage == .vertex)
        [4][4]u8{ blue, red, blue, blue }
    else
        [4][4]u8{ yellow, yellow, blue, blue };
    const named_first = [_]dusk.api.ConstantEntry{
        .{ .key = if (stage == .vertex) "shift_x" else "red", .value = 0 },
        .{ .key = if (stage == .vertex) "shift_y" else "green", .value = if (stage == .vertex) -1 else 1 },
    };
    const numeric_second = [_]dusk.api.ConstantEntry{
        .{ .key = "7", .value = 1 },
        .{ .key = "9", .value = if (stage == .vertex) 0 else 1 },
    };
    const reversed_numeric_first = [_]dusk.api.ConstantEntry{
        .{ .key = "9", .value = if (stage == .vertex) -1 else 1 },
        .{ .key = "7", .value = 0 },
    };
    const reversed_named_second = [_]dusk.api.ConstantEntry{
        .{ .key = if (stage == .vertex) "shift_y" else "green", .value = if (stage == .vertex) 0 else 1 },
        .{ .key = if (stage == .vertex) "shift_x" else "red", .value = 1 },
    };
    var cases = [_]GraphicsCase{
        .{ .pixels = default_pixels },
        .{ .pixels = first_pixels, .identity_index = 1, .unique_count = 2 },
        .{ .pixels = second_pixels, .identity_index = 2, .unique_count = 3 },
        .{ .pixels = first_pixels, .identity_index = 1, .unique_count = 3 },
        .{ .pixels = second_pixels, .identity_index = 2, .unique_count = 3 },
    };
    const overrides = [_][]const dusk.api.ConstantEntry{
        &.{}, &named_first, &numeric_second, &reversed_numeric_first, &reversed_named_second,
    };
    for (&cases, overrides) |*case, constants| {
        if (stage == .vertex) case.vertex_constants = constants else case.fragment_constants = constants;
    }
    try runTriangleCases(.{
        .vertex_words = &specialization_graphics.vertex_words,
        .fragment_words = &specialization_graphics.fragment_words,
        .vertex_entry_point = specialization_graphics.entry_point,
        .fragment_entry_point = specialization_graphics.entry_point,
    }, null, &cases);
}

fn runTriangleCases(
    fixtures: ShaderFixtures,
    blend_constant: ?commands.Color,
    cases: []const GraphicsCase,
) !void {
    const vertex_digest = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(fixtures.vertex_words));
    const fragment_digest = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(fixtures.fragment_words));
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var handle_baseline: vulkan_device.HandleSet = .{};
    {
        const allocator = std.testing.allocator;
        var instance = dusk.engine.Instance.init(.{ .backend_type = .vulkan });
        defer {
            if (instance.native_context) |native_context| {
                std.testing.expectEqualSlices(
                    u32,
                    &handle_baseline.counts,
                    &native_context.handles.counts,
                ) catch @panic("triangle native resource handle leaked");
            }
            instance.deinit(allocator, io) catch @panic("triangle instance teardown failed");
        }
        var adapters = try instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        defer adapters.deinit(io) catch @panic("triangle adapters teardown failed");
        handle_baseline = instance.native_context.?.handles;
        if (adapters.items.len == 0) return error.NoPhysicalDevice;
        var high_device = try adapters.items[0].createDevice(allocator, io, .{
            .adapter = &adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = &handle_baseline,
            .uncaptured_callback = uncapturedError,
        });
        defer high_device.deinit(allocator, io) catch @panic("triangle device teardown failed");
        const context = high_device.native.?;
        const device = context.native_device;
        const handles = &instance.native_context.?.handles;
        const q = &context.queue;
        const core_device = &high_device.core;

        const procs = device.procs;
        const vk_device = device.vk_device;

        // SAFETY: createSceneWithShaders writes every field before success. Until then,
        // scene_created stays false, so deferred cleanup cannot read this storage.
        // All other scene reads follow the successful assignment and flag update.
        var scene: Scene = undefined;
        var scene_created = false;
        defer if (scene_created) destroyScene(device, &scene, handles);
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
        defer guard.unlock(io);
        try high_device.bindObjectsLocked(&guard, allocator);
        const pipeline_store = &context.pipeline_store.?;
        // Each successful factory call owns an alias, even when it hits the cache.
        var pipeline_aliases: [5]?*dusk.engine.native_resources.Pipeline = @splat(null);
        defer for (pipeline_aliases) |alias| {
            if (alias) |object| {
                object.header.releaseUserLocked(&guard, io) catch
                    @panic("triangle pipeline reference release failed");
            }
        };
        const resource_device: engine_buffer.Device = .{
            .allocator = std.testing.allocator,
            .dispatch = device.dispatchTable(),
            .vk_device = vk_device,
            .memory_properties = device.memoryProperties(),
            .non_coherent_atom_size = 1,
            .max_buffer_size = std.math.maxInt(u64),
            .handles = handles,
        };
        const target = created: {
            guard.unlock(io);
            defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            break :created try high_device.createTexture(allocator, io, .{
                .usage = .{ .render_attachment = true, .copy_src = true },
                .size = .{ .width = target_extent, .height = target_extent },
                .format = .rgba8_unorm,
            });
        };
        defer target.header.releaseUserLocked(&guard, io) catch
            @panic("triangle texture reference release failed");
        const target_view = created: {
            guard.unlock(io);
            defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            break :created try high_device.createTextureView(allocator, io, .{
                .texture = target,
                .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
            });
        };
        defer target_view.header.releaseUserLocked(&guard, io) catch
            @panic("triangle view reference release failed");

        // `RenderPassCache::GetRenderPass` (`RenderPassCache.cpp:408`). The pass
        // comes from a sparse query, and the key carries masks rather than handles,
        // so two different attachment shapes can never share one `VkRenderPass`.
        const passes = &context.render_pass_cache;

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

        const framebuffers = &context.framebuffer_cache;

        // --- the rest of the submission's inputs --------------------------------

        scene = try createSceneWithShaders(device, handles, fixtures);
        scene_created = true;

        // The tint the fragment shader reads, written through the host and then
        // handed to the fragment stage by a memory barrier.
        try writeTint(device, scene.uniform.memory);

        // The staging buffer starts as a sentinel everywhere the copy must not go.
        const staged = try mapStaging(device, scene.staging.memory);
        defer unmapStaging(device, scene.staging.memory);

        // The wrappers borrow the scene's native allocations. Scene teardown owns
        // the handles, and all wrappers remain live until the queue wait completes.
        var uniform = borrowBuffer(resource_device, scene.uniform, uniform_byte_count, .{
            .uniform = true,
        });
        uniform.last_write_usage = (dusk.api.BufferUsage{ .map_write = true }).toFlags();
        var readback = borrowBuffer(resource_device, scene.staging, readback_byte_count, .{
            .copy_dst = true,
            .map_read = true,
        });
        if (cases.len == 0 or cases.len > 5) return error.InvalidGraphicsCaseCount;
        var identities: [3]?*pipeline.Pipeline = @splat(null);
        for (cases, 0..) |case, case_index| {
            if (case.identity_index >= identities.len) return error.InvalidGraphicsIdentity;
            @memset(staged, untouched_fill);
            const render_pipeline = created: {
                guard.unlock(io);
                defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
                break :created try scene.typedPipelineWithConstants(
                    allocator,
                    io,
                    &high_device,
                    case.vertex_constants,
                    case.fragment_constants,
                );
            };
            pipeline_aliases[case_index] = render_pipeline;
            try std.testing.expect(render_pipeline.header.isAlive(&guard));
            try std.testing.expectEqual(@as(u8, 1), render_pipeline.native.bind_group_mask);
            try std.testing.expectEqual(
                case.unique_count,
                pipeline_store.queryPipelineCount(&guard),
            );
            if (identities[case.identity_index]) |previous| {
                try std.testing.expect(render_pipeline.native == previous);
                try std.testing.expect(previous.isAlive(&guard));
            } else {
                for (identities) |previous| {
                    if (previous) |other| try std.testing.expect(render_pipeline.native != other);
                }
                identities[case.identity_index] = render_pipeline.native;
            }
            try std.testing.expect(case.identity_index <= case_index);
            var descriptor_allocator = try descriptor_sets.DescriptorSetAllocator.init(
                std.testing.allocator,
                procs,
                vk_device,
                render_pipeline.layout.groups[0].native.handle,
                &.{.{
                    .type = @intCast(vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
                    .descriptorCount = 1,
                }},
            );
            defer descriptor_allocator.deinit() catch @panic("triangle descriptor allocator teardown failed");
            const tint_group = try bind_group.BindGroup.create(std.testing.allocator, io, &guard, .{
                .objects = core_device.borrow().objects,
                .descriptor_allocator = &descriptor_allocator,
                .pipeline_layout = render_pipeline.layout.native.handle,
                .group_index = 0,
                .group_layout = render_pipeline.native.group_layouts[0],
                .buffer_limits = bind_group.BufferLimits.fromPhysicalDeviceLimits(&device.physicalProperties().limits),
                .bindings = &.{.{ .buffer = .{
                    .binding = tint_binding,
                    .buffer = &uniform,
                    .offset = 0,
                    .size = uniform_byte_count,
                    .kind = .uniform,
                    .stages = .{ .fragment = true },
                } }},
            });
            defer {
                tint_group.destroy(
                    std.testing.allocator,
                    io,
                    &guard,
                    q.timeline.lastSubmittedSerial(),
                ) catch @panic("triangle bind group teardown failed");
                descriptor_allocator.finishDeallocation(
                    q.timeline.lastSubmittedSerial(),
                ) catch @panic("triangle descriptor retirement failed");
            }

            var frontend = encoder.CommandEncoder.init(allocator, core_device.borrow(), .{});
            defer frontend.deinit(allocator, io, &guard);
            var render = begun: {
                guard.unlock(io);
                defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
                break :begun try high_device.beginRenderPass(allocator, io, &frontend, .{
                    .color_attachments = &.{.{
                        .view = @ptrCast(target_view),
                        .load_op = .clear,
                        .store_op = .store,
                        .clear_color = .{ .r = 0, .g = 0, .b = 1, .a = 1 },
                    }},
                    .width = target_extent,
                    .height = target_extent,
                });
            };
            defer render.deinit(io, &guard);
            try render.setPipeline(&guard, try render_pipeline.renderOptions(&guard));
            try render.setBindGroup(.{
                .index = 0,
                .group = @ptrCast(tint_group),
                .layout_id = @intFromPtr(&render_pipeline.layout.groups[0].header),
                .min_binding_buffer_size = uniform_byte_count,
                .buffers = &.{.{
                    .buffer = @ptrCast(&uniform),
                    .usage = (dusk.api.BufferUsage{ .uniform = true }).toFlags(),
                }},
            });
            if (blend_constant) |color| try render.setBlendConstant(color);
            try render.draw(.{
                .vertex_count = vertex_count,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = 0,
            });
            try render.end(io, &guard);
            try frontend.copyTextureToBuffer(.{
                .source = .{
                    .texture = @ptrCast(target),
                    .format = @intFromEnum(dusk.api.enums.TextureFormat.rgba8_unorm),
                    .dimension = ._2d,
                    .aspect = .all,
                    .extent = .{
                        .width = target_extent,
                        .height = target_extent,
                        .depth_or_array_layers = 1,
                    },
                },
                .destination = .{
                    .buffer = @ptrCast(&readback),
                    .blocks_per_row = @divExact(bytes_per_row_alignment, bytes_per_pixel),
                    .rows_per_image = target_extent,
                },
                .copy_size = .{
                    .width = target_extent,
                    .height = target_extent,
                    .depth_or_array_layers = 1,
                },
            });
            var finished = try frontend.finish();
            defer finished.deinit(allocator, io, &guard);
            var recording = recording_context.CommandRecordingContext.init(std.testing.allocator);
            defer recording.deinit();
            defer {
                guard.unlock(io);
                dispatch.checkVkSuccess(
                    (procs.device_wait_idle orelse unreachable)(vk_device),
                ) catch @panic("triangle GPU completion failed");
                guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            }
            var lease = acquired: {
                guard.unlock(io);
                defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
                break :acquired try high_device.getQueue(io);
            };
            defer {
                guard.unlock(io);
                lease.deinit(io);
                guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            }
            if (context.recording_uses == null) {
                context.recording_uses = try dusk.engine.native_resources.PendingUses.prepareDeclaredLocked(
                    allocator,
                    &guard,
                    core_device,
                    &.{},
                );
            }
            try dusk.engine.command_buffer.recordCommands(std.testing.allocator, .{
                .io = io,
                .guard = &guard,
                .core_device = core_device,
                .queue = q,
                .recording = &recording,
                .render_pass_cache = passes,
                .framebuffer_cache = framebuffers,
                .max_immediate_size = high_device.limits.v1.max_immediate_size,
                .kernels = &context.kernel_cache.?,
                .pending_uses = &context.recording_uses.?,
                .timestamp_quantization = high_device.timestamp_quantization,
            }, &finished);
            try std.testing.expectEqual(@as(usize, 1), framebuffers.count());
            const command_buffer = q.commandBuffer();
            // Coherent memory still needs a transfer-write to host-read dependency.
            const host_barrier: vulkan.VkBufferMemoryBarrier = .{
                .sType = vulkan.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                .srcAccessMask = vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
                .dstAccessMask = vulkan.VK_ACCESS_HOST_READ_BIT,
                .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
                .buffer = scene.staging.buffer,
                .offset = 0,
                .size = readback_byte_count,
            };
            (procs.cmd_pipeline_barrier orelse return error.DeviceProcMissing)(
                command_buffer,
                vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
                vulkan.VK_PIPELINE_STAGE_HOST_BIT,
                0,
                0,
                null,
                1,
                &host_barrier,
                0,
                null,
            );

            // --- the submission, the fence and the sixteen values -------------------

            const submitted = submitted: {
                guard.unlock(io);
                defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
                break :submitted try lease.submit(allocator, io, .{
                    .command_buffers = &.{command_buffer},
                }, &.{ &render_pipeline.header, &target.header, &target_view.header });
            };
            {
                guard.unlock(io);
                defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
                lease.deinit(io);
                try high_device.wait(io, submitted.serial);
            }
            try std.testing.expect(dusk.platform.Timeline.completedSerial(io, &q.timeline) >= submitted.serial);
            try std.testing.expectEqual(
                @as(vulkan.VkResult, vulkan.VK_SUCCESS),
                try q.fenceStatus(submitted.fence),
            );

            try expectPixel(staged, 0, 0, case.pixels[0]);
            try expectPixel(staged, 1, 0, case.pixels[1]);
            try expectPixel(staged, 0, 1, case.pixels[2]);
            try expectPixel(staged, 1, 1, case.pixels[3]);

            // Nothing outside the two runs the copy wrote was written at all, so the
            // pitch is observable: a copy that ran long would leave a colour in the
            // padding or the tail.
            try expectSentinel(staged);
        }
    }
    try std.testing.expectEqual(
        vertex_digest,
        std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(fixtures.vertex_words)),
    );
    try std.testing.expectEqual(
        fragment_digest,
        std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(fixtures.fragment_words)),
    );
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

// --- The scene --------------------------------------------------------------

/// Create native scene resources with rollback at each acquisition. Pipeline
/// creation belongs to `typedPipeline` and ownership belongs to the core device.
pub fn createSceneWithShaders(
    device: vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
    fixtures: ShaderFixtures,
) SetupError!Scene {
    var scene: Scene = .{
        // SAFETY: createHostBuffer fills staging before its errdefer or any caller reads it.
        // Failure returns without exposing the partial scene.
        .staging = undefined,
        // SAFETY: uniform acquisition follows staging and fills uniform before its errdefer.
        // Failure cleans staging only. Success returns both initialized allocations.
        .uniform = undefined,
        .fixtures = fixtures,
    };

    scene.staging = try createHostBuffer(device, handles, readback_byte_count, @intCast(
        vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    ));
    errdefer destroyHostBuffer(device, handles, scene.staging);
    scene.uniform = try createHostBuffer(device, handles, uniform_byte_count, @intCast(
        vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    ));

    return scene;
}

/// Releases the scene's direct native buffers after GPU completion.
pub fn destroyScene(
    device: vulkan_device.Device,
    scene: *Scene,
    handles: *vulkan_device.HandleSet,
) void {
    destroyHostBuffer(device, handles, scene.uniform);
    destroyHostBuffer(device, handles, scene.staging);

    // SAFETY: cleanup releases all owned handles before this terminal poison.
    // The caller drops the scene without another read or destroyScene call.
    scene.* = undefined;
}

fn destroyHostBuffer(
    device: vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
    allocation: BufferAllocation,
) void {
    (device.procs.destroy_buffer orelse unreachable)(device.vk_device, allocation.buffer, null);
    (device.procs.free_memory orelse unreachable)(device.vk_device, allocation.memory, null);
    handles.release(.buffer);
    handles.release(.memory);
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
    errdefer {
        (procs.destroy_buffer orelse unreachable)(vk_device, buffer, null);
        handles.release(.buffer);
    }

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
        .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    }, &memory);
    errdefer {
        (procs.free_memory orelse unreachable)(vk_device, memory, null);
        handles.release(.memory);
    }
    // Offset zero is aligned for every `VkMemoryRequirements`, so the alignment
    // rule needs no arithmetic here.
    try dispatch.checkVkSuccess((procs.bind_buffer_memory orelse
        return error.DeviceProcMissing)(vk_device, buffer, memory, 0));

    return .{
        .buffer = buffer,
        .memory = memory,
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    };
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
