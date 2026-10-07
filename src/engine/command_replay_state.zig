//! Vulkan replay trackers borrow payloads under the caller's object guard.
//! The caller keeps the guard and all replay resource leases alive through recording.

const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const core = @import("../core/root.zig");
const descriptor = @import("../pipeline/bind_group_descriptor_set.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const bind_group = @import("bind_group.zig");
const buffer_mod = @import("buffer.zig");
const constants = @import("../command/constants.zig");

// The recorder observes the Vulkan seam, not a replacement state machine.
test "immediate ranges preserve sparse byte offsets and skip unchanged values" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.cmd_push_constants = TestRecorder.pushConstants;
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    var tracker: ImmediatesTracker = .{};
    try tracker.set(8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try tracker.set(24, &.{ 9, 10, 11, 12 });
    try tracker.apply(context, @ptrFromInt(1), 0b1001101);
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    try std.testing.expectEqual(@as(u32, 8), recorder.push_offsets[0]);
    try std.testing.expectEqual(@as(u32, 8), recorder.push_sizes[0]);
    try std.testing.expectEqual(@as(u32, 24), recorder.push_offsets[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, recorder.push_data[0][0..8]);
    try tracker.set(8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try tracker.apply(context, @ptrFromInt(1), 0b1001101);
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    tracker.dirtyAll();
    try tracker.apply(context, @ptrFromInt(1), 0b1001101);
    try std.testing.expectEqual(@as(u32, 5), recorder.push_count);
}

test "immediate writes cover all 256 bytes and dirty word 63 independently" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.cmd_push_constants = TestRecorder.pushConstants;
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    var tracker: ImmediatesTracker = .{};
    var data: [256]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @intCast(index % 251 + 1);
    try tracker.set(0, &data);
    try std.testing.expectEqual(std.math.maxInt(u64), tracker.dirty_mask);
    try std.testing.expectEqualSlices(u8, &data, &tracker.content);
    try tracker.apply(context, @ptrFromInt(1), std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u32, 1), recorder.push_count);
    try std.testing.expectEqual(@as(u32, 0), recorder.push_offsets[0]);
    try std.testing.expectEqual(@as(u32, 256), recorder.push_sizes[0]);
    try std.testing.expectEqualSlices(u8, &data, &recorder.push_data[0]);
    try std.testing.expectEqual(@as(u64, 0), tracker.dirty_mask);
    try tracker.set(252, &.{ 255, 254, 253, 252 });
    try std.testing.expectEqual(@as(u64, 1) << 63, tracker.dirty_mask);
    try tracker.apply(context, @ptrFromInt(1), std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    try std.testing.expectEqual(@as(u32, 252), recorder.push_offsets[1]);
    try std.testing.expectEqual(@as(u32, 4), recorder.push_sizes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 254, 253, 252 }, recorder.push_data[1][0..4]);
    try std.testing.expectEqualSlices(u8, data[0..252], tracker.content[0..252]);
    try std.testing.expectEqual(@as(u64, 0), tracker.dirty_mask);
    try tracker.set(252, &.{ 255, 254, 253, 252 });
    try std.testing.expectEqual(@as(u64, 0), tracker.dirty_mask);
}

test "immediate write errors preserve bytes dirty bits and shader stages" {
    var tracker: ImmediatesTracker = .{ .stages = vulkan.VK_SHADER_STAGE_COMPUTE_BIT };
    try tracker.set(64, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try tracker.set(252, &.{ 9, 10, 11, 12 });
    const previous = tracker;
    const cases = [_]struct { offset: u32, data: []const u8, expected: Error }{
        .{ .offset = 1, .data = &.{ 0, 0, 0, 0 }, .expected = error.ImmediateUnaligned },
        .{ .offset = 0, .data = &.{0}, .expected = error.ImmediateUnaligned },
        .{ .offset = 252, .data = &.{ 0, 0, 0 }, .expected = error.ImmediateUnaligned },
        .{ .offset = 256, .data = &.{ 0, 0, 0, 0 }, .expected = error.ImmediateOutOfRange },
        .{
            .offset = 252,
            .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .expected = error.ImmediateOutOfRange,
        },
        .{ .offset = 260, .data = &.{}, .expected = error.ImmediateOutOfRange },
        .{
            .offset = std.math.maxInt(u32) - 3,
            .data = &.{ 0, 0, 0, 0 },
            .expected = error.ImmediateOutOfRange,
        },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, tracker.set(case.offset, case.data));
        try std.testing.expectEqualSlices(u8, &previous.content, &tracker.content);
        try std.testing.expectEqual(previous.dirty_mask, tracker.dirty_mask);
        try std.testing.expectEqual(previous.stages, tracker.stages);
    }
    try tracker.set(256, &.{});
    try std.testing.expectEqualSlices(u8, &previous.content, &tracker.content);
    try std.testing.expectEqual(previous.dirty_mask, tracker.dirty_mask);
    try std.testing.expectEqual(previous.stages, tracker.stages);
}

test "immediate replay emits zero-filled untouched words only within the pipeline mask" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.cmd_push_constants = TestRecorder.pushConstants;
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    var tracker: ImmediatesTracker = .{};
    const zeros: [256]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zeros, &tracker.content);
    try tracker.set(252, zeros[0..4]);
    try std.testing.expectEqual(@as(u64, 0), tracker.dirty_mask);
    tracker.dirtyAll();
    try tracker.apply(context, @ptrFromInt(1), (@as(u64, 1) << 16) | (@as(u64, 1) << 63));
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    try std.testing.expectEqual(@as(u32, 64), recorder.push_offsets[0]);
    try std.testing.expectEqual(@as(u32, 252), recorder.push_offsets[1]);
    for (0..2) |index| {
        try std.testing.expectEqual(@as(u32, 4), recorder.push_sizes[index]);
        try std.testing.expectEqualSlices(u8, zeros[0..4], recorder.push_data[index][0..4]);
    }
    try std.testing.expectEqual(@as(u64, 0), tracker.dirty_mask);
}

test "selected replay rejects resource tables and requires a specialization pipeline" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var descriptors: DescriptorSetTracker = .{};
    try std.testing.expectError(error.UnsupportedResourceTable, descriptors.setResourceTable(null));
    try std.testing.expectError(
        error.BindGroupIndexOutOfRange,
        descriptors.set(&guard, 8, null, &.{}),
    );
    var state: ProgrammablePassState = .{};
    try std.testing.expectError(error.PipelineNotSet, state.computeSpecialization(&guard));
    var recorder: TestRecorder = .{};
    const procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    try std.testing.expectError(error.PipelineNotSet, state.runWithSpecialization(
        context,
        vulkan.VK_PIPELINE_BIND_POINT_COMPUTE,
        .{ .external_texture_inputs = true },
    ));
}

test "programmable replay binds once then dirties all state for empty specialization" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.cmd_bind_pipeline = TestRecorder.bindPipeline;
    procs.cmd_push_constants = TestRecorder.pushConstants;
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    const backend = testBackend(&recorder);
    const value = try createTestPipeline(&arena, &guard, &backend, .{
        .immediate_mask = 1,
        .immediate_size = 4,
        .immediate_stages = immediate_shader_stages,
    });
    defer value.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    var state: ProgrammablePassState = .{};
    try state.onSetPipeline(&guard, .compute, value);
    try state.immediates.set(0, &.{ 1, 2, 3, 4 });
    try state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 1), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 1), recorder.push_count);
    const specialization = try state.computeSpecialization(&guard);
    try state.runWithSpecialization(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE, specialization);
    try std.testing.expectEqual(@as(u32, 2), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    try std.testing.expect(state.last_applied_pipeline == null);
    try state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 3), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 3), recorder.push_count);
    try std.testing.expectError(
        error.PipelineKindMismatch,
        state.onSetPipeline(&guard, .render, value),
    );
    value.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(
        error.PipelineDestroyed,
        state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE),
    );
    try std.testing.expectEqual(@as(u32, 3), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 3), recorder.push_count);
    try std.testing.expectEqual(@as(u32, 1), recorder.destroy_count);
}

test "programmable reset requires pipeline selection and restores its shader stages" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.cmd_bind_pipeline = TestRecorder.bindPipeline;
    procs.cmd_push_constants = TestRecorder.pushConstants;
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    const backend = testBackend(&recorder);
    const compute = try createTestPipeline(&arena, &guard, &backend, .{
        .immediate_mask = 1,
        .immediate_size = 4,
        .immediate_stages = vulkan.VK_SHADER_STAGE_COMPUTE_BIT,
    });
    defer compute.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    const render_stages = vulkan.VK_SHADER_STAGE_VERTEX_BIT | vulkan.VK_SHADER_STAGE_FRAGMENT_BIT;
    const render = try createTestPipeline(&arena, &guard, &backend, .{
        .kind = .render,
        .vk_pipeline = @ptrFromInt(3),
        .vk_layout = @ptrFromInt(4),
        .immediate_mask = 1,
        .immediate_size = 4,
        .immediate_stages = render_stages,
    });
    defer render.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    var state: ProgrammablePassState = .{};
    try state.onSetPipeline(&guard, .compute, compute);
    try state.immediates.set(0, &.{ 1, 2, 3, 4 });
    try state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 1), recorder.push_count);
    try std.testing.expectEqual(compute.immediate_stages, recorder.push_stages[0]);
    state = .{};
    try std.testing.expectError(
        error.PipelineNotSet,
        state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS),
    );
    try std.testing.expectError(error.PipelineNotSet, state.computeSpecialization(&guard));
    try std.testing.expectEqual(@as(u32, 1), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 1), recorder.push_count);
    try state.onSetPipeline(&guard, .render, render);
    try std.testing.expectEqual(render.immediate_stages, state.immediates.stages);
    try state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS);
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    try std.testing.expectEqual(render.immediate_stages, recorder.push_stages[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, recorder.push_data[1][0..4]);
    state.immediates.stages = compute.immediate_stages;
    try state.onSetPipeline(&guard, .render, render);
    try std.testing.expectEqual(render.immediate_stages, state.immediates.stages);
    state = .{};
    try std.testing.expectError(
        error.PipelineNotSet,
        state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE),
    );
    try std.testing.expectEqual(@as(u32, 2), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 2), recorder.push_count);
    try state.onSetPipeline(&guard, .compute, compute);
    try state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 3), recorder.pipeline_count);
    try std.testing.expectEqual(@as(u32, 3), recorder.push_count);
    try std.testing.expectEqual(compute.immediate_stages, recorder.push_stages[2]);
}

test "descriptor replay requires groups and binds framebuffer reserved set before groups" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.cmd_bind_descriptor_sets = TestRecorder.bindDescriptors;
    procs.create_descriptor_pool = TestRecorder.createDescriptorPool;
    procs.destroy_descriptor_pool = TestRecorder.destroyDescriptorPool;
    procs.allocate_descriptor_sets = TestRecorder.allocateDescriptorSets;
    procs.update_descriptor_sets = TestRecorder.updateDescriptorSets;
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    const layouts = [_]pipeline.GroupLayout{.{ .handle = @ptrFromInt(3), .bindings = &.{} }};
    const backend = testBackend(&recorder);
    const value = try createTestPipeline(&arena, &guard, &backend, .{
        .bind_group_mask = 1,
        .group_layouts = &layouts,
    });
    defer value.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    var descriptor_allocator = try testDescriptorAllocator(
        &procs,
        &recorder,
        layouts[0].handle,
        vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    );
    defer deinitTestDescriptorAllocator(&descriptor_allocator, &recorder) catch
        @panic("descriptor allocator cleanup failed");
    const group = try bind_group.BindGroup.create(std.testing.allocator, std.testing.io, &guard, .{
        .objects = arena.objectList(),
        .descriptor_allocator = &descriptor_allocator,
        .pipeline_layout = value.vk_layout,
        .group_index = 0,
        .group_layout = layouts[0],
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
        .bindings = &.{},
    });
    defer group.destroy(std.testing.allocator, std.testing.io, &guard, 1) catch
        @panic("bind group cleanup failed");
    var tracker: DescriptorSetTracker = .{};
    try tracker.onSetPipeline(&guard, value);
    try std.testing.expectError(
        error.MissingBindGroup,
        tracker.apply(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.descriptor_count);
    try std.testing.expectEqual(@as(u32, 1), value.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), value.header.user_reference_count);
    try std.testing.expectEqual(@as(u64, 1), arena.objectList().total_reference_count);
    try std.testing.expectEqual(@as(u64, 1), arena.objectList().user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), arena.objectList().tracked_count);
    try std.testing.expectEqual(@as(u32, 1), descriptor_allocator.queryPoolCount());
    try std.testing.expectEqual(@as(u32, 1), recorder.descriptor_updates);
    try tracker.set(&guard, 0, group, &.{});
    tracker.setFramebufferFetchDescriptorSet(@ptrFromInt(5));
    try tracker.apply(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 2), recorder.descriptor_count);
    try std.testing.expectEqual(@as(u32, 0), recorder.descriptor_indices[0]);
    try std.testing.expectEqual(@as(u32, 1), recorder.descriptor_indices[1]);
    try std.testing.expectEqual(@as(vulkan.VkDescriptorSet, @ptrFromInt(5)), recorder.descriptor_sets[0]);
    try std.testing.expectEqual(try group.getHandle(&guard), recorder.descriptor_sets[1]);
    try tracker.apply(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 2), recorder.descriptor_count);
    tracker.dirtyAll();
    try tracker.apply(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
    try std.testing.expectEqual(@as(u32, 4), recorder.descriptor_count);
}

test "specialization preserves truthful external texture metadata" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    const backend = testBackend(&recorder);
    const layouts = [_]pipeline.GroupLayout{.{
        .handle = @ptrFromInt(3),
        .bindings = &.{},
        .has_external_texture = true,
    }};
    const value = try createTestPipeline(&arena, &guard, &backend, .{
        .group_layouts = &layouts,
    });
    defer value.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    const state: ProgrammablePassState = .{ .current_pipeline = value };
    const selected = try state.computeSpecialization(&guard);
    try std.testing.expect(selected.external_texture_inputs);
}

test "descriptor offsets are copied and invalid updates preserve the previous binding" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    var procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_descriptor_pool = TestRecorder.createDescriptorPool;
    procs.destroy_descriptor_pool = TestRecorder.destroyDescriptorPool;
    procs.allocate_descriptor_sets = TestRecorder.allocateDescriptorSets;
    procs.update_descriptor_sets = TestRecorder.updateDescriptorSets;
    var descriptor_allocator = try testDescriptorAllocator(
        &procs,
        &recorder,
        @ptrFromInt(3),
        vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    );
    defer deinitTestDescriptorAllocator(&descriptor_allocator, &recorder) catch
        @panic("descriptor allocator cleanup failed");
    // BindGroup borrows this buffer and reads only the four fields set below.
    var buffer: buffer_mod.Buffer = undefined;
    buffer.handle = @ptrFromInt(8);
    buffer.state = .unmapped;
    buffer.size = 1024;
    buffer.usage = .{ .uniform = true };
    const bindings = [_]bind_group.Binding{.{ .buffer = .{
        .binding = 0,
        .buffer = &buffer,
        .offset = 0,
        .size = 256,
        .kind = .uniform,
        .dynamic = true,
        .alignment = 256,
        .stages = .none,
    } }};
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .descriptorCount = 1,
        .stageFlags = 0,
    }};
    const group = try bind_group.BindGroup.create(std.testing.allocator, std.testing.io, &guard, .{
        .objects = arena.objectList(),
        .descriptor_allocator = &descriptor_allocator,
        .pipeline_layout = @ptrFromInt(2),
        .group_index = 0,
        .group_layout = .{ .handle = descriptor_allocator.set_layout, .bindings = &schema },
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
        .bindings = &bindings,
    });
    defer group.destroy(std.testing.allocator, std.testing.io, &guard, 1) catch
        @panic("bind group cleanup failed");
    var offsets = [_]u32{256};
    var tracker: DescriptorSetTracker = .{};
    try tracker.set(&guard, 0, group, &offsets);
    offsets[0] = 512;
    try std.testing.expectEqual(@as(u32, 256), tracker.offsets[0][0]);
    try std.testing.expectError(
        error.DynamicOffsetUnaligned,
        tracker.set(&guard, 0, group, &.{1}),
    );
    try std.testing.expectEqual(@as(u32, 256), tracker.offsets[0][0]);
    try std.testing.expectEqual(@as(u32, 1), tracker.offset_counts[0]);
    try std.testing.expectEqual(group, tracker.groups[0].?);
    try std.testing.expectEqual(@as(u8, 1), tracker.dirty_mask);
    try std.testing.expectEqual(@as(u32, 1), descriptor_allocator.queryPoolCount());
    try std.testing.expectEqual(@as(u32, 1), recorder.descriptor_updates);
    try std.testing.expectEqual(@as(u64, 0), arena.objectList().total_reference_count);
    try std.testing.expectEqual(@as(u64, 0), arena.objectList().user_reference_count);
    try std.testing.expectEqual(@as(usize, 0), arena.objectList().tracked_count);
    try tracker.set(&guard, 0, null, &.{});
    try std.testing.expect(tracker.groups[0] == null);
    try std.testing.expectEqual(@as(u32, 0), tracker.offset_counts[0]);
}

test "descriptor compatibility uses structure instead of Vulkan layout handles" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    const backend = testBackend(&recorder);
    const first_layouts = [_]pipeline.GroupLayout{.{ .handle = @ptrFromInt(3), .bindings = &.{} }};
    const next_layouts = [_]pipeline.GroupLayout{.{ .handle = @ptrFromInt(4), .bindings = &.{} }};
    const first = try createTestPipeline(&arena, &guard, &backend, .{
        .bind_group_mask = 1,
        .group_layouts = &first_layouts,
    });
    defer first.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    const next = try createTestPipeline(&arena, &guard, &backend, .{
        .vk_pipeline = @ptrFromInt(5),
        .vk_layout = @ptrFromInt(6),
        .bind_group_mask = 1,
        .group_layouts = &next_layouts,
    });
    defer next.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    const tracker: DescriptorSetTracker = .{
        .current_pipeline = next,
        .last_applied_pipeline = first,
    };
    try std.testing.expect(tracker.areLayoutsCompatible(&guard));
    next.immediate_size = 4;
    next.immediate_mask = 1;
    try std.testing.expect(!tracker.areLayoutsCompatible(&guard));
    next.immediate_size = 0;
    next.immediate_mask = 0;
    first.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expect(!tracker.areLayoutsCompatible(&guard));
}

test "replay rejects failed pipelines before inspecting their native payload" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var recorder: TestRecorder = .{};
    const backend = testBackend(&recorder);
    const value = try createTestPipeline(&arena, &guard, &backend, .{
        .initialization_error = error.BufferSizeTooSmall,
        .vk_pipeline = null,
        .vk_layout = null,
    });
    defer value.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("pipeline reference leaked");
    try std.testing.expect(value.header.isAlive(&guard));
    var state: ProgrammablePassState = .{};
    try std.testing.expectError(
        error.PipelineDestroyed,
        state.onSetPipeline(&guard, .compute, value),
    );
    state.current_pipeline = value;
    try std.testing.expectError(error.PipelineDestroyed, state.computeSpecialization(&guard));
    const procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    const context: Context = .{
        .guard = &guard,
        .procs = &procs,
        .command_buffer = @ptrCast(&recorder),
    };
    try std.testing.expectError(
        error.PipelineDestroyed,
        state.syncAndRun(context, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.pipeline_count);
}

const TestPipelineOptions = struct {
    kind: pipeline.Kind = .compute,
    vk_pipeline: vulkan.VkPipeline = @ptrFromInt(1),
    vk_layout: vulkan.VkPipelineLayout = @ptrFromInt(2),
    immediate_mask: u64 = 0,
    immediate_size: u32 = 0,
    immediate_stages: vulkan.VkShaderStageFlags = 0,
    bind_group_mask: u8 = 0,
    group_layouts: []const pipeline.GroupLayout = &.{},
    initialization_error: ?core.ValidationError = null,
};

fn createTestPipeline(
    arena: *core.ObjectArena,
    guard: *const core.ObjectGuard,
    backend: *const pipeline.Backend,
    options: TestPipelineOptions,
) !*pipeline.Pipeline {
    const allocator = std.testing.allocator;
    const groups = try allocator.alloc(pipeline.GroupLayout, options.group_layouts.len);
    var copied: usize = 0;
    errdefer {
        for (groups[0..copied]) |*group| group.deinit(allocator);
        allocator.free(groups);
    }
    for (options.group_layouts, groups) |source, *target| {
        target.* = try source.clone(allocator);
        copied += 1;
    }
    const value = try arena.create(allocator, guard, pipeline.Pipeline, .{
        .kind = .pipeline,
        .initial_reference = .user,
        .state = .initializing,
    });
    value.* = .{
        .header = value.header,
        .backend = backend,
        .destroy_pipeline = TestRecorder.destroyPipeline,
        .allocator = allocator,
        .vk_pipeline = options.vk_pipeline,
        .vk_layout = options.vk_layout,
        .state = switch (options.kind) {
            .compute => .{ .compute = .{} },
            .render => .{ .render = .{} },
        },
        .immediate_mask = options.immediate_mask,
        .immediate_size = options.immediate_size,
        .immediate_stages = options.immediate_stages,
        .bind_group_mask = options.bind_group_mask,
        .group_layouts = groups,
    };
    if (options.initialization_error) |rule| {
        value.header.setInitializedError(guard, rule);
    } else {
        value.header.setInitializedNoError(guard);
    }
    value.header.attach(guard, std.testing.io);
    return value;
}

fn testBackend(recorder: *TestRecorder) pipeline.Backend {
    return .{
        .device = @ptrCast(recorder),
        .create_graphics_pipelines = null,
        .create_compute_pipelines = null,
        .create_pipeline_cache = null,
        .get_pipeline_cache_data = null,
        .destroy_pipeline = TestRecorder.destroyPipeline,
        .destroy_pipeline_cache = null,
    };
}

fn testDescriptorAllocator(
    procs: *const dispatch.DeviceProcs,
    recorder: *TestRecorder,
    layout: vulkan.VkDescriptorSetLayout,
    descriptor_type: vulkan.VkDescriptorType,
) !descriptor.DescriptorSetAllocator {
    return descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        procs,
        @ptrCast(recorder),
        layout,
        &.{.{ .type = descriptor_type, .descriptorCount = 1 }},
    );
}

fn deinitTestDescriptorAllocator(
    allocator: *descriptor.DescriptorSetAllocator,
    recorder: *TestRecorder,
) !void {
    defer {
        allocator.deinit() catch @panic("descriptor allocator cleanup failed");
        std.testing.expectEqual(
            recorder.descriptor_pools_created,
            recorder.descriptor_pools_destroyed,
        ) catch @panic("descriptor pools were not destroyed exactly once");
    }
    // The group defer runs first. Serial completion returns its token before pool destruction.
    try allocator.finishDeallocation(1);
    try std.testing.expect(allocator.pending_deallocations.isEmpty());
    try std.testing.expectEqual(
        recorder.descriptor_pools_created * descriptor.max_descriptors_per_pool,
        recorder.descriptor_sets_allocated,
    );
    for (allocator.pools.items) |pool| {
        try std.testing.expectEqual(pool.sets.items.len, pool.free_set_indices.items.len);
    }
}

const TestRecorder = struct {
    pipeline_count: u32 = 0,
    destroy_count: u32 = 0,
    descriptor_count: u32 = 0,
    descriptor_indices: [16]u32 = @splat(0),
    descriptor_sets: [16]vulkan.VkDescriptorSet = @splat(null),
    descriptor_pools_created: u32 = 0,
    descriptor_pools_destroyed: u32 = 0,
    descriptor_sets_allocated: u32 = 0,
    descriptor_updates: u32 = 0,
    push_count: u32 = 0,
    push_offsets: [16]u32 = @splat(0),
    push_sizes: [16]u32 = @splat(0),
    push_stages: [16]vulkan.VkShaderStageFlags = @splat(0),
    push_data: [16][256]u8 = @splat(@splat(0)),

    fn createDescriptorPool(
        device: vulkan.VkDevice,
        info: [*c]const vulkan.VkDescriptorPoolCreateInfo,
        allocation_callbacks: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkDescriptorPool,
    ) callconv(.c) vulkan.VkResult {
        const self: *TestRecorder = @ptrCast(@alignCast(device.?));
        std.debug.assert(info.*.sType == vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO);
        std.debug.assert(info.*.maxSets == descriptor.max_descriptors_per_pool);
        std.debug.assert(info.*.poolSizeCount == 1);
        std.debug.assert(info.*.pPoolSizes[0].descriptorCount == info.*.maxSets);
        std.debug.assert(allocation_callbacks == null);
        std.debug.assert(self.descriptor_pools_created == 0);
        self.descriptor_pools_created += 1;
        out.* = @ptrFromInt(7);
        return vulkan.VK_SUCCESS;
    }

    fn destroyDescriptorPool(
        device: vulkan.VkDevice,
        handle: vulkan.VkDescriptorPool,
        allocation_callbacks: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *TestRecorder = @ptrCast(@alignCast(device.?));
        std.debug.assert(handle == @as(vulkan.VkDescriptorPool, @ptrFromInt(7)));
        std.debug.assert(allocation_callbacks == null);
        std.debug.assert(self.descriptor_pools_created == 1);
        std.debug.assert(self.descriptor_pools_destroyed == 0);
        self.descriptor_pools_destroyed += 1;
    }

    fn allocateDescriptorSets(
        device: vulkan.VkDevice,
        info: [*c]const vulkan.VkDescriptorSetAllocateInfo,
        out: [*c]vulkan.VkDescriptorSet,
    ) callconv(.c) vulkan.VkResult {
        const self: *TestRecorder = @ptrCast(@alignCast(device.?));
        std.debug.assert(info.*.sType == vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO);
        std.debug.assert(info.*.descriptorPool == @as(vulkan.VkDescriptorPool, @ptrFromInt(7)));
        std.debug.assert(info.*.descriptorSetCount == descriptor.max_descriptors_per_pool);
        for (0..info.*.descriptorSetCount) |index| {
            std.debug.assert(info.*.pSetLayouts[index] == @as(
                vulkan.VkDescriptorSetLayout,
                @ptrFromInt(3),
            ));
            out[index] = @ptrFromInt(index + 4);
        }
        self.descriptor_sets_allocated += info.*.descriptorSetCount;
        return vulkan.VK_SUCCESS;
    }

    fn updateDescriptorSets(
        device: vulkan.VkDevice,
        count: u32,
        writes: [*c]const vulkan.VkWriteDescriptorSet,
        copy_count: u32,
        copies: [*c]const vulkan.VkCopyDescriptorSet,
    ) callconv(.c) void {
        const self: *TestRecorder = @ptrCast(@alignCast(device.?));
        std.debug.assert(count <= 1);
        std.debug.assert(copy_count == 0);
        std.debug.assert(copies == null);
        if (count == 1) {
            std.debug.assert(writes[0].dstSet == @as(vulkan.VkDescriptorSet, @ptrFromInt(4)));
            std.debug.assert(writes[0].dstBinding == 0);
            std.debug.assert(writes[0].descriptorCount == 1);
            std.debug.assert(writes[0].descriptorType == vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC);
            std.debug.assert(writes[0].pBufferInfo[0].buffer == @as(vulkan.VkBuffer, @ptrFromInt(8)));
            std.debug.assert(writes[0].pBufferInfo[0].offset == 0);
            std.debug.assert(writes[0].pBufferInfo[0].range == 256);
        }
        self.descriptor_updates += 1;
    }

    fn destroyPipeline(
        device: vulkan.VkDevice,
        handle: vulkan.VkPipeline,
        allocation_callbacks: ?*const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        std.debug.assert(handle != null);
        std.debug.assert(allocation_callbacks == null);
        const self: *TestRecorder = @ptrCast(@alignCast(device.?));
        self.destroy_count += 1;
    }

    fn bindPipeline(
        command_buffer: vulkan.VkCommandBuffer,
        bind_point: vulkan.VkPipelineBindPoint,
        handle: vulkan.VkPipeline,
    ) callconv(.c) void {
        std.debug.assert(bind_point == vulkan.VK_PIPELINE_BIND_POINT_COMPUTE or
            bind_point == vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS);
        std.debug.assert(handle != null);
        const self: *TestRecorder = @ptrCast(@alignCast(command_buffer.?));
        self.pipeline_count += 1;
    }

    fn bindDescriptors(
        command_buffer: vulkan.VkCommandBuffer,
        bind_point: vulkan.VkPipelineBindPoint,
        layout: vulkan.VkPipelineLayout,
        first_set: u32,
        set_count: u32,
        sets: [*c]const vulkan.VkDescriptorSet,
        offset_count: u32,
        offsets: [*c]const u32,
    ) callconv(.c) void {
        std.debug.assert(bind_point == vulkan.VK_PIPELINE_BIND_POINT_COMPUTE);
        std.debug.assert(layout != null);
        std.debug.assert(set_count == 1);
        std.debug.assert(sets[0] != null);
        std.debug.assert(offset_count == 0);
        std.debug.assert(offsets == null);
        const self: *TestRecorder = @ptrCast(@alignCast(command_buffer.?));
        std.debug.assert(self.descriptor_count < self.descriptor_indices.len);
        self.descriptor_indices[self.descriptor_count] = first_set;
        self.descriptor_sets[self.descriptor_count] = sets[0];
        self.descriptor_count += 1;
    }

    fn pushConstants(
        command_buffer: vulkan.VkCommandBuffer,
        layout: vulkan.VkPipelineLayout,
        stages: vulkan.VkShaderStageFlags,
        offset: u32,
        size: u32,
        data: ?*const anyopaque,
    ) callconv(.c) void {
        _ = layout;
        const self: *TestRecorder = @ptrCast(@alignCast(command_buffer.?));
        std.debug.assert(self.push_count < self.push_offsets.len);
        self.push_offsets[self.push_count] = offset;
        self.push_sizes[self.push_count] = size;
        self.push_stages[self.push_count] = stages;
        const bytes: [*]const u8 = @ptrCast(data.?);
        @memcpy(self.push_data[self.push_count][0..size], bytes[0..size]);
        self.push_count += 1;
    }
};

/// Recording borrows the caller-held guard; tracker methods never acquire another lock.
pub const Context = struct {
    guard: *const core.ObjectGuard,
    procs: *const dispatch.DeviceProcs,
    command_buffer: vulkan.VkCommandBuffer,
};

pub const Error = bind_group.Error || error{
    BindGroupIndexOutOfRange,
    TooManyDynamicOffsets,
    MissingBindGroup,
    BindGroupLayoutMismatch,
    DescriptorSetMissing,
    PipelineNotSet,
    PipelineDestroyed,
    PipelineHandleMissing,
    PipelineKindMismatch,
    PipelineMetadataInvalid,
    CommandBufferMissing,
    BindDescriptorSetsNotLoaded,
    BindPipelineNotLoaded,
    PushConstantsNotLoaded,
    ImmediateUnaligned,
    ImmediateOutOfRange,
    UnsupportedResourceTable,
    UnsupportedSpecialization,
};

const immediate_shader_stages = vulkan.VK_SHADER_STAGE_VERTEX_BIT |
    vulkan.VK_SHADER_STAGE_FRAGMENT_BIT | vulkan.VK_SHADER_STAGE_COMPUTE_BIT;
const max_bind_groups = constants.max_bind_groups;
const max_dynamic_offsets = 32;
const immediate_bytes = 256;

pub const DescriptorSetTracker = struct {
    groups: [max_bind_groups]?*bind_group.BindGroup = @splat(null),
    offsets: [max_bind_groups][max_dynamic_offsets]u32 = @splat(@splat(0)),
    offset_counts: [max_bind_groups]u32 = @splat(0),
    dirty_mask: u8 = 0,
    current_pipeline: ?*pipeline.Pipeline = null,
    last_applied_pipeline: ?*pipeline.Pipeline = null,
    framebuffer_fetch_set: vulkan.VkDescriptorSet = null,
    framebuffer_fetch_dirty: bool = false,

    /// Copies validated offsets without changing the previous binding on error.
    /// `guard` belongs to the native resources' owner and stays held during recording.
    pub fn set(
        self: *DescriptorSetTracker,
        guard: *const core.ObjectGuard,
        index: u32,
        group: ?*bind_group.BindGroup,
        dynamic_offsets: []const u32,
    ) Error!void {
        guard.assertOwns(guard.objects);
        if (index >= max_bind_groups) return error.BindGroupIndexOutOfRange;
        if (dynamic_offsets.len > max_dynamic_offsets) return error.TooManyDynamicOffsets;
        if (group) |value| {
            guard.assertOwns(value.objects);
            try value.validateDynamicOffsets(guard, dynamic_offsets);
        } else if (dynamic_offsets.len != 0) {
            return error.DynamicOffsetCountMismatch;
        }
        const changed = self.groups[index] != group or
            !std.mem.eql(u32, self.offsets[index][0..self.offset_counts[index]], dynamic_offsets);
        self.groups[index] = group;
        @memcpy(self.offsets[index][0..dynamic_offsets.len], dynamic_offsets);
        self.offset_counts[index] = @intCast(dynamic_offsets.len);
        if (changed) self.dirty_mask |= @as(u8, 1) << @intCast(index);
    }

    /// Selects an alive pipeline owned by `guard`; does not retain the borrowed pointer.
    pub fn onSetPipeline(
        self: *DescriptorSetTracker,
        guard: *const core.ObjectGuard,
        value: *pipeline.Pipeline,
    ) Error!void {
        try validatePipeline(guard, value);
        self.current_pipeline = value;
        if (!self.areLayoutsCompatible(guard)) self.dirtyAll();
    }

    /// Retired or unusable pipelines are incompatible without reading their payloads.
    pub fn areLayoutsCompatible(
        self: *const DescriptorSetTracker,
        guard: *const core.ObjectGuard,
    ) bool {
        const current = self.current_pipeline orelse return false;
        const previous = self.last_applied_pipeline orelse return false;
        validatePipeline(guard, current) catch return false;
        validatePipeline(guard, previous) catch return false;
        var index: u32 = 0;
        while (index < max_bind_groups) : (index += 1) {
            if (current.bind_group_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            if (!current.compatibleForGroup(guard, previous, index)) return false;
        }
        return current.immediate_size == previous.immediate_size and
            current.immediate_stages == previous.immediate_stages;
    }

    pub fn dirtyAll(self: *DescriptorSetTracker) void {
        self.dirty_mask = std.math.maxInt(u8);
        self.framebuffer_fetch_dirty = self.framebuffer_fetch_set != null;
        self.last_applied_pipeline = null;
    }

    pub fn setFramebufferFetchDescriptorSet(
        self: *DescriptorSetTracker,
        set_handle: vulkan.VkDescriptorSet,
    ) void {
        if (self.framebuffer_fetch_set != set_handle) {
            self.framebuffer_fetch_set = set_handle;
            self.dirtyAll();
        }
    }

    pub fn setResourceTable(self: *DescriptorSetTracker, table: ?*anyopaque) Error!void {
        _ = self;
        _ = table;
        return error.UnsupportedResourceTable;
    }

    /// Checks required groups and alive pipeline metadata under the caller-held guard.
    pub fn validate(
        self: *const DescriptorSetTracker,
        guard: *const core.ObjectGuard,
    ) Error!void {
        const current = self.current_pipeline orelse return error.PipelineNotSet;
        try validatePipeline(guard, current);
        var index: u32 = 0;
        while (index < max_bind_groups) : (index += 1) {
            if (current.bind_group_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            const group = self.groups[index] orelse return error.MissingBindGroup;
            guard.assertOwns(group.objects);
            if (index >= current.group_layouts.len) return error.PipelineMetadataInvalid;
            if (!group.group_layout.compatible(current.group_layouts[index])) {
                return error.BindGroupLayoutMismatch;
            }
            try group.validateDynamicOffsets(
                guard,
                self.offsets[index][0..self.offset_counts[index]],
            );
            const handle = try group.getHandle(guard);
            if (handle == null) return error.DescriptorSetMissing;
        }
    }

    pub fn apply(
        self: *DescriptorSetTracker,
        context: Context,
        bind_point: vulkan.VkPipelineBindPoint,
    ) Error!void {
        try self.validate(context.guard);
        if (context.command_buffer == null) return error.CommandBufferMissing;
        const current = self.current_pipeline.?;
        const dirty = self.dirty_mask & current.bind_group_mask;
        if (dirty != 0 or self.framebuffer_fetch_dirty) {
            const bind = context.procs.cmd_bind_descriptor_sets orelse
                return error.BindDescriptorSetsNotLoaded;
            if (self.framebuffer_fetch_dirty) {
                const set_handle = self.framebuffer_fetch_set;
                bind(context.command_buffer, bind_point, current.vk_layout, 0, 1, &set_handle, 0, null);
            }
            const first_group: u32 = if (self.framebuffer_fetch_set != null) 1 else 0;
            var index: u32 = 0;
            while (index < max_bind_groups) : (index += 1) {
                if (dirty & (@as(u8, 1) << @intCast(index)) == 0) continue;
                const set_handle = try self.groups[index].?.getHandle(context.guard);
                const count = self.offset_counts[index];
                bind(
                    context.command_buffer,
                    bind_point,
                    current.vk_layout,
                    index + first_group,
                    1,
                    &set_handle,
                    count,
                    if (count == 0) null else &self.offsets[index],
                );
            }
        }
        self.dirty_mask &= ~current.bind_group_mask;
        self.framebuffer_fetch_dirty = false;
        self.last_applied_pipeline = current;
    }
};

pub const ImmediatesTracker = struct {
    content: [immediate_bytes]u8 = @splat(0),
    dirty_mask: u64 = 0,
    stages: vulkan.VkShaderStageFlags = immediate_shader_stages,

    /// Writes aligned user immediates in [0, 256). Errors leave the tracker unchanged.
    /// Rejects misalignment with `ImmediateUnaligned` and bounds with `ImmediateOutOfRange`.
    pub fn set(self: *ImmediatesTracker, offset: u32, data: []const u8) Error!void {
        if (offset % 4 != 0 or data.len % 4 != 0) return error.ImmediateUnaligned;
        if (offset > immediate_bytes) return error.ImmediateOutOfRange;
        if (data.len > immediate_bytes - offset) return error.ImmediateOutOfRange;
        self.update(offset, data);
    }

    fn update(self: *ImmediatesTracker, offset: u32, data: []const u8) void {
        var byte_index: u32 = 0;
        while (byte_index < data.len) : (byte_index += 4) {
            const destination = self.content[offset + byte_index ..][0..4];
            const source = data[byte_index..][0..4];
            if (std.mem.eql(u8, destination, source)) continue;
            @memcpy(destination, source);
            self.dirty_mask |= @as(u64, 1) << @intCast(@divExact(offset + byte_index, 4));
        }
    }

    pub fn dirtyAll(self: *ImmediatesTracker) void {
        self.dirty_mask = std.math.maxInt(u64);
    }

    pub fn apply(
        self: *ImmediatesTracker,
        context: Context,
        layout: vulkan.VkPipelineLayout,
        mask: u64,
    ) Error!void {
        const dirty = self.dirty_mask & mask;
        if (dirty != 0) {
            if (context.command_buffer == null) return error.CommandBufferMissing;
            if (layout == null) return error.PipelineHandleMissing;
            const push = context.procs.cmd_push_constants orelse return error.PushConstantsNotLoaded;
            var index: u32 = 0;
            while (index < 64) {
                if (dirty & (@as(u64, 1) << @intCast(index)) == 0) {
                    index += 1;
                    continue;
                }
                const start = index;
                index += 1;
                while (index < 64) : (index += 1) {
                    if (dirty & (@as(u64, 1) << @intCast(index)) == 0) break;
                }
                push(
                    context.command_buffer,
                    layout,
                    self.stages,
                    start * 4,
                    (index - start) * 4,
                    &self.content[start * 4],
                );
            }
        }
        self.dirty_mask = 0;
    }
};

pub const Specialization = struct {
    external_texture_inputs: bool = false,
};

pub const ProgrammablePassState = struct {
    descriptor_sets: DescriptorSetTracker = .{},
    immediates: ImmediatesTracker = .{},
    current_pipeline: ?*pipeline.Pipeline = null,
    last_applied_pipeline: ?*pipeline.Pipeline = null,

    /// Selects a borrowed alive pipeline; errors leave the programmable state unchanged.
    pub fn onSetPipeline(
        self: *ProgrammablePassState,
        guard: *const core.ObjectGuard,
        kind: pipeline.Kind,
        value: *pipeline.Pipeline,
    ) Error!void {
        try validatePipeline(guard, value);
        if (value.queryKind(guard) != kind) return error.PipelineKindMismatch;
        try self.descriptor_sets.onSetPipeline(guard, value);
        if (self.current_pipeline != value) self.immediates.dirtyAll();
        self.immediates.stages = value.immediate_stages;
        self.current_pipeline = value;
    }

    pub fn syncAndRun(
        self: *ProgrammablePassState,
        context: Context,
        bind_point: vulkan.VkPipelineBindPoint,
    ) Error!void {
        const current = self.current_pipeline orelse return error.PipelineNotSet;
        try validatePipeline(context.guard, current);
        const expected: vulkan.VkPipelineBindPoint = switch (current.queryKind(context.guard)) {
            .compute => vulkan.VK_PIPELINE_BIND_POINT_COMPUTE,
            .render => vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS,
        };
        if (bind_point != expected) return error.PipelineKindMismatch;
        if (context.command_buffer == null) return error.CommandBufferMissing;
        try self.descriptor_sets.validate(context.guard);
        if (self.last_applied_pipeline != current) {
            const bind = context.procs.cmd_bind_pipeline orelse return error.BindPipelineNotLoaded;
            bind(context.command_buffer, bind_point, current.vk_pipeline);
            self.last_applied_pipeline = current;
        }
        try self.descriptor_sets.apply(context, bind_point);
        try self.immediates.apply(context, current.vk_layout, current.immediate_mask);
    }

    pub fn dirtyAll(self: *ProgrammablePassState) void {
        self.descriptor_sets.dirtyAll();
        self.immediates.dirtyAll();
        self.last_applied_pipeline = null;
    }

    /// Reads alive pipeline and guarded expanded-descriptor metadata.
    pub fn computeSpecialization(
        self: *const ProgrammablePassState,
        guard: *const core.ObjectGuard,
    ) Error!Specialization {
        const current = self.current_pipeline orelse return error.PipelineNotSet;
        try validatePipeline(guard, current);
        var result: Specialization = .{};
        for (current.group_layouts) |layout| {
            result.external_texture_inputs = result.external_texture_inputs or
                layout.has_external_texture;
        }
        var index: u32 = 0;
        while (index < max_bind_groups) : (index += 1) {
            if (current.bind_group_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            if (self.descriptor_sets.groups[index]) |group| {
                guard.assertOwns(group.objects);
                result.external_texture_inputs = result.external_texture_inputs or
                    group.group_layout.has_external_texture;
            }
        }
        return result;
    }

    pub fn runWithSpecialization(
        self: *ProgrammablePassState,
        context: Context,
        bind_point: vulkan.VkPipelineBindPoint,
        specialization: Specialization,
    ) Error!void {
        const selected = try self.computeSpecialization(context.guard);
        if (selected.external_texture_inputs != specialization.external_texture_inputs)
            return error.UnsupportedSpecialization;
        self.dirtyAll();
        defer self.dirtyAll();
        try self.syncAndRun(context, bind_point);
    }
};

fn validatePipeline(guard: *const core.ObjectGuard, value: *const pipeline.Pipeline) Error!void {
    guard.assertOwns(value.header.tracking);
    if (!value.header.node.linked or value.header.reference_count == 0 or
        value.header.state != .alive) return error.PipelineDestroyed;
    if (value.vk_pipeline == null or value.vk_layout == null) return error.PipelineHandleMissing;
    if (value.bind_group_mask & ~@as(u8, (1 << max_bind_groups) - 1) != 0) {
        return error.PipelineMetadataInvalid;
    }
    if (value.group_layouts.len > max_bind_groups) return error.PipelineMetadataInvalid;
    if (value.immediate_size != @as(u32, @intCast(@popCount(value.immediate_mask))) * 4) {
        return error.PipelineMetadataInvalid;
    }
}
