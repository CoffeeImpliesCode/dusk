//! Native specialization reaches Vulkan through frontend compute command replay.
const std = @import("std");
const dusk = @import("dusk");
const fixture = @import("fixtures/specialization_compute.zig");
const workgroup_fixture = @import("fixtures/workgroup_compute.zig");
const triangle = @import("triangle.zig");
const vk = dusk.platform.vulkan_bindings;
const dispatch = dusk.vk.dispatch;
const native = dusk.engine.vulkan_device;
const pipeline = dusk.pipeline.pipeline;

fn uncapturedError(
    _: std.mem.Allocator,
    _: std.Io,
    _: *anyopaque,
    _: dusk.core.ErrorView,
) void {
    @panic("compute specialization reported an uncaptured device error");
}

test "compute specialization: defaults overrides and canonical cache hits reach storage readback" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var handles: native.HandleSet = .{};
    try runCases(threaded.io(), &handles, .scalar);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?native.HandleKind, null), handles.firstLeakedKind());
}

test "compute specialization: one SpecId overrides both result IDs through either name" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var handles: native.HandleSet = .{};
    try runCases(threaded.io(), &handles, .scalar_shared);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?native.HandleKind, null), handles.firstLeakedKind());
}

const FixtureKind = enum { scalar, scalar_shared, workgroup, workgroup_shared };

test "compute workgroup specialization changes executed invocation count and coverage" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var handles: native.HandleSet = .{};
    try runCases(threaded.io(), &handles, .workgroup);
    try runCases(threaded.io(), &handles, .workgroup_shared);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?native.HandleKind, null), handles.firstLeakedKind());
}

fn runCases(io: std.Io, handles: *native.HandleSet, kind: FixtureKind) !void {
    const workgroup = kind == .workgroup or kind == .workgroup_shared;
    const shared_id = kind == .scalar_shared or kind == .workgroup_shared;
    const module_words: []const u32 = switch (kind) {
        .scalar => &fixture.words,
        .scalar_shared => &fixture.shared_id_words,
        .workgroup => &workgroup_fixture.words,
        .workgroup_shared => &workgroup_fixture.shared_id_words,
    };
    const allocator = std.testing.allocator;
    var instance = dusk.engine.Instance.init(.{});
    defer instance.deinit(allocator, io) catch @panic("specialization instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("specialization adapter teardown failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var high_device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = handles,
        .uncaptured_callback = uncapturedError,
    });
    defer {
        high_device.deinit(allocator, io) catch
            @panic("specialization device teardown failed");
        const native_handles = &instance.native_context.?.handles;
        for (std.enums.values(native.HandleKind)) |handle_kind| {
            if (handle_kind != .instance) {
                std.testing.expectEqual(@as(u32, 0), native_handles.countOf(handle_kind)) catch
                    @panic("specialization native handle leaked");
            }
        }
    }
    const context = high_device.native.?;
    const device = &context.native_device;
    const core_device = &high_device.core;
    const q = &context.queue;
    const procs = device.procs;
    const target = device.vk_device;
    const output = try createOutput(device, handles);
    defer destroyOutput(device, handles, output);
    const shader = try high_device.createShaderModule(allocator, io, .{ .words = module_words });
    defer high_device.release(allocator, io, shader) catch
        @panic("specialization shader teardown failed");
    const bind_group_layout = try high_device.createBindGroupLayout(allocator, io, .{
        .entries = &.{.{
            .binding_number = 0,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = 8,
            } },
        }},
    });
    defer high_device.release(allocator, io, bind_group_layout) catch
        @panic("specialization bind group layout teardown failed");
    const layout = try high_device.createPipelineLayout(allocator, io, .{
        .groups = &.{bind_group_layout},
    });
    defer high_device.release(allocator, io, layout) catch
        @panic("specialization pipeline layout teardown failed");
    const group_layout = bind_group_layout.native;
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
    defer guard.unlock(io);
    try high_device.bindObjectsLocked(&guard, allocator);
    // Keep every high user alias, including wrappers which share a cached low pipeline.
    var pipeline_aliases: [5]?*dusk.engine.native_resources.Pipeline = @splat(null);
    defer for (pipeline_aliases) |alias| {
        if (alias) |object| {
            object.header.releaseUserLocked(&guard, io) catch
                @panic("specialization pipeline reference release failed");
        }
    };
    const resource_device: dusk.engine.buffer.Device = .{
        .allocator = allocator,
        .dispatch = device.dispatchTable(),
        .vk_device = target,
        .memory_properties = device.memoryProperties(),
        .non_coherent_atom_size = 1,
        .max_buffer_size = std.math.maxInt(u64),
        .handles = handles,
    };
    var output_buffer = triangle.borrowBuffer(resource_device, output, 8, .{ .storage = true });
    const descriptor_sets = dusk.pipeline.bind_group_descriptor_set;
    var descriptor_allocator = try descriptor_sets.DescriptorSetAllocator.init(
        allocator,
        procs,
        target,
        group_layout.handle,
        &.{.{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 }},
    );
    defer descriptor_allocator.deinit() catch @panic("specialization descriptor teardown failed");
    const group = try dusk.engine.bind_group.BindGroup.create(allocator, io, &guard, .{
        .objects = core_device.borrow().objects,
        .descriptor_allocator = &descriptor_allocator,
        .pipeline_layout = layout.native.handle,
        .group_index = 0,
        .group_layout = group_layout,
        .buffer_limits = dusk.engine.bind_group.BufferLimits.fromPhysicalDeviceLimits(
            &device.physicalProperties().limits,
        ),
        .bindings = &.{.{ .buffer = .{
            .binding = 0,
            .buffer = &output_buffer,
            .offset = 0,
            .size = 8,
            .kind = .storage,
            .stages = .{ .compute = true },
        } }},
    });
    defer {
        group.destroy(allocator, io, &guard, q.timeline.lastSubmittedSerial()) catch
            @panic("specialization bind group teardown failed");
        descriptor_allocator.finishDeallocation(q.timeline.lastSubmittedSerial()) catch
            @panic("specialization descriptor retirement failed");
    }
    const passes = &context.render_pass_cache;
    const frames = &context.framebuffer_cache;
    var mapped: ?*anyopaque = null;
    try dispatch.checkVkSuccess((procs.map_memory orelse
        return error.DeviceProcMissing)(target, output.memory, 0, 8, 0, &mapped));
    defer (procs.unmap_memory orelse unreachable)(target, output.memory);
    const result: *[2]u32 = @ptrCast(@alignCast(mapped orelse return error.MapReturnedNull));
    // On any later failure, finish GPU use before any resource is destroyed.
    defer {
        guard.unlock(io);
        dispatch.checkVkSuccess((procs.device_wait_idle orelse unreachable)(target)) catch
            @panic("specialization GPU completion failed");
        guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
    }
    const Case = struct {
        constants: []const dusk.api.ConstantEntry,
        expected: u32,
        unique_count: usize,
        expected_coverage: ?u32 = null,
    };
    const distinct_cases = [_]Case{
        .{ .constants = &.{}, .expected = fixture.default_output, .unique_count = 1 },
        .{
            .constants = &.{
                .{ .key = "value", .value = 2 },
                .{ .key = "bias", .value = 5 },
            },
            .expected = 25,
            .unique_count = 2,
        },
        .{
            .constants = &.{
                .{ .key = "7", .value = 3 },
                .{ .key = "9", .value = 5 },
            },
            .expected = 35,
            .unique_count = 3,
        },
        .{
            .constants = &.{
                .{ .key = "9", .value = 5 },
                .{ .key = "7", .value = 2 },
            },
            .expected = 25,
            .unique_count = 3,
        },
        .{
            .constants = &.{
                .{ .key = "bias", .value = 5 },
                .{ .key = "value", .value = 3 },
            },
            .expected = 35,
            .unique_count = 3,
        },
    };
    const shared_cases = [_]Case{
        .{ .constants = &.{}, .expected = fixture.shared_id_default_output, .unique_count = 1 },
        .{ .constants = &.{.{ .key = "value", .value = 4 }}, .expected = 44, .unique_count = 2 },
        .{ .constants = &.{.{ .key = "7", .value = 5 }}, .expected = 55, .unique_count = 3 },
        .{ .constants = &.{.{ .key = "bias", .value = 4 }}, .expected = 44, .unique_count = 3 },
        .{ .constants = &.{.{ .key = "value", .value = 5 }}, .expected = 55, .unique_count = 3 },
    };
    const workgroup_cases = [_]Case{
        .{ .constants = &.{}, .expected = 4, .expected_coverage = 15, .unique_count = 1 },
        .{
            .constants = &.{
                .{ .key = "local_x", .value = 3 },
            },
            .expected = 6,
            .expected_coverage = 63,
            .unique_count = 2,
        },
        .{
            .constants = &.{
                .{ .key = "21", .value = 4 },
            },
            .expected = 8,
            .expected_coverage = 255,
            .unique_count = 3,
        },
        .{
            .constants = &.{
                .{ .key = "21", .value = 3 },
            },
            .expected = 6,
            .expected_coverage = 63,
            .unique_count = 3,
        },
        .{
            .constants = &.{
                .{ .key = "local_x", .value = 4 },
            },
            .expected = 8,
            .expected_coverage = 255,
            .unique_count = 3,
        },
    };
    const workgroup_shared_cases = [_]Case{
        .{ .constants = &.{}, .expected = 4, .expected_coverage = 15, .unique_count = 1 },
        .{
            .constants = &.{
                .{ .key = "local_x", .value = 3 },
            },
            .expected = 9,
            .expected_coverage = 511,
            .unique_count = 2,
        },
        .{
            .constants = &.{
                .{ .key = "21", .value = 4 },
            },
            .expected = 16,
            .expected_coverage = 65535,
            .unique_count = 3,
        },
        .{
            .constants = &.{
                .{ .key = "local_y", .value = 3 },
            },
            .expected = 9,
            .expected_coverage = 511,
            .unique_count = 3,
        },
        .{
            .constants = &.{
                .{ .key = "local_x", .value = 4 },
            },
            .expected = 16,
            .expected_coverage = 65535,
            .unique_count = 3,
        },
    };
    const cases = if (workgroup)
        (if (shared_id) workgroup_shared_cases else workgroup_cases)
    else
        (if (shared_id) shared_cases else distinct_cases);
    var first_override: ?*pipeline.Pipeline = null;
    var second_override: ?*pipeline.Pipeline = null;
    const layout_id: u64 = @intFromPtr(&bind_group_layout.header);
    for (cases, 0..) |case, index| {
        const object = created: {
            guard.unlock(io);
            defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            break :created try high_device.createComputePipeline(allocator, io, .{
                .layout = layout,
                .compute = .{
                    .module = shader,
                    .entry_point = if (workgroup)
                        workgroup_fixture.entry_point
                    else
                        fixture.entry_point,
                    .stage = .compute,
                    .constants = case.constants,
                },
            });
        };
        pipeline_aliases[index] = object;
        try std.testing.expectEqual(
            case.unique_count,
            context.pipeline_store.?.queryPipelineCount(&guard),
        );
        if (index == 1) first_override = object.native;
        if (index == 2) second_override = object.native;
        if (index == 3) try std.testing.expect(object.native == first_override.?);
        if (index == 4) try std.testing.expect(object.native == second_override.?);
        result.* = if (workgroup) .{ 0, 0 } else .{ 0xa5a5a5a5, 0xa5a5a5a5 };
        var encoder = dusk.command.command_encoder.CommandEncoder.init(
            allocator,
            core_device.borrow(),
            .{},
        );
        defer encoder.deinit(allocator, io, &guard);
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{
            .pipeline = &object.header,
            .requirements = .{
                .bind_group_layout_mask = 1,
                .bind_group_layout_ids = .{ layout_id, 0, 0, 0 },
            },
        });
        try pass.setBindGroup(.{
            .index = 0,
            .group = group,
            .layout_id = layout_id,
            .min_binding_buffer_size = 8,
            .buffers = &.{.{
                .buffer = &output_buffer,
                .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags(),
            }},
        });
        try pass.dispatch(.{ .x = 1, .y = 1, .z = 1 });
        try pass.end();
        var finished = try encoder.finish();
        defer finished.deinit(allocator, io, &guard);
        var recording = dusk.engine.recording_context.CommandRecordingContext.init(allocator);
        defer recording.deinit();
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
        try dusk.engine.command_buffer.recordCommands(allocator, .{
            .io = io,
            .guard = &guard,
            .core_device = core_device,
            .queue = q,
            .recording = &recording,
            .render_pass_cache = passes,
            .framebuffer_cache = frames,
            .max_immediate_size = high_device.limits.v1.max_immediate_size,
            .kernels = &context.kernel_cache.?,
            .pending_uses = &context.recording_uses.?,
            .timestamp_quantization = high_device.timestamp_quantization,
        }, &finished);
        // Coherence removes cache management, not the shader-to-host dependency.
        // Replay owns dispatch; this native handoff makes its result visible to the CPU.
        const host_barrier: vk.VkBufferMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .buffer = output.buffer,
            .offset = 0,
            .size = 8,
        };
        (procs.cmd_pipeline_barrier orelse return error.DeviceProcMissing)(
            q.commandBuffer(),
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_HOST_BIT,
            0,
            0,
            null,
            1,
            &host_barrier,
            0,
            null,
        );
        const submitted = submitted: {
            guard.unlock(io);
            defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            break :submitted try lease.submit(allocator, io, .{
                .command_buffers = &.{q.commandBuffer()},
            }, &.{&object.header});
        };
        {
            guard.unlock(io);
            defer guard = dusk.core.ObjectGuard.lockUncancelable(io, core_device.borrow().objects);
            lease.deinit(io);
            try high_device.wait(io, submitted.serial);
        }
        try std.testing.expect(dusk.platform.Timeline.completedSerial(io, &q.timeline) >= submitted.serial);
        try std.testing.expectEqual(case.expected, result[0]);
        if (case.expected_coverage) |coverage| {
            try std.testing.expectEqual(coverage, result[1]);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), frames.count());
}

fn createOutput(
    device: *const native.Device,
    handles: *native.HandleSet,
) !triangle.BufferAllocation {
    const procs = device.procs;
    const target = device.vk_device;
    const info: vk.VkBufferCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = 8,
        .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
    };
    var buffer: vk.VkBuffer = null;
    try dispatch.checkVkSuccess((procs.create_buffer orelse
        return error.DeviceProcMissing)(target, &info, null, &buffer));
    if (buffer == null) return error.HandleCreationReturnedNull;
    handles.acquire(.buffer);
    errdefer {
        (procs.destroy_buffer orelse unreachable)(target, buffer, null);
        handles.release(.buffer);
    }
    // SAFETY: Vulkan initializes the complete output structure before its first read.
    var requirements: vk.VkMemoryRequirements = undefined;
    (procs.get_buffer_memory_requirements orelse
        return error.DeviceProcMissing)(target, buffer, &requirements);
    const type_index = try native.findMemoryTypeIndex(
        device.memoryProperties(),
        requirements.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        0,
    );
    const memory_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: vk.VkDeviceMemory = null;
    try dispatch.checkVkSuccess((procs.allocate_memory orelse
        return error.DeviceProcMissing)(target, &memory_info, null, &memory));
    if (memory == null) return error.HandleCreationReturnedNull;
    handles.acquire(.memory);
    errdefer {
        (procs.free_memory orelse unreachable)(target, memory, null);
        handles.release(.memory);
    }
    try dispatch.checkVkSuccess((procs.bind_buffer_memory orelse
        return error.DeviceProcMissing)(target, buffer, memory, 0));
    return .{
        .buffer = buffer,
        .memory = memory,
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    };
}

fn destroyOutput(
    device: *const native.Device,
    handles: *native.HandleSet,
    output: triangle.BufferAllocation,
) void {
    (device.procs.destroy_buffer orelse unreachable)(device.vk_device, output.buffer, null);
    (device.procs.free_memory orelse unreachable)(device.vk_device, output.memory, null);
    handles.release(.buffer);
    handles.release(.memory);
}
