//! Native descriptor layout and pipeline compatibility regressions.
//!
//! Sparse public numbers must survive host packing, Vulkan layout creation,
//! descriptor writes, and consumption by unchanged caller SPIR-V. The high-device
//! compute test stores through binding 1 and reads the result back after submission.
//! Array tests check one physical binding, full pool counts, and malformed bounds.
//! The remaining native fixture tests layout compatibility and deferred set reuse.
//!
//! Resource tables and static-sampler specialization are outside this shard.

const std = @import("std");
const vulkan = @import("vulkan");

const dusk = @import("dusk");
const bind_group_descriptor_set = dusk.pipeline.bind_group_descriptor_set;
const bind_group_layout = dusk.pipeline.bind_group_layout;
const layout_vk = dusk.pipeline.layout_vk;
const vulkan_device = dusk.engine.vulkan_device;

/// The queue serial `DescriptorSetAllocator.deallocate` takes. It comes through
/// the published module rather than a relative path, because `src/vk` reached
/// relatively is a different Zig module than the one `dusk` holds and the two
/// sets would not be the same type.
const serial = dusk.platform;

/// The binding numbers the acceptance names.
const sampled_texture_binding_number: u32 = 0;
const storage_buffer_binding_number: u32 = 1;

/// The binding count the acceptance asserts. It is also the divisor in the
/// pool-sizing assertion below, which is what makes the two paths agree.
const expected_binding_count: u32 = 2;

/// The minimum binding size of the storage buffer. It is not zero on purpose:
/// a zero-sized buffer counts towards `mUnverifiedBufferCount`
/// (`BindGroupLayoutInternal.cpp:706`-`:708`), and a set whose only buffer
/// cannot be checked against a size would make the pool-sizing assertion a
/// claim about a layout no driver would accept.
const storage_buffer_min_binding_size: u64 = 64;

/// The index of the fragment stage inside a `BindingCounts` block.
/// `stageIndex` (`layout_internal.zig:143`) returns 1 for `.fragment`, because
/// `BindingTypeOrder`'s predecessors put vertex at 0. Dawn counts three stages
/// at `Constants.h:42`.
const fragment_stage_index: usize = 1;

/// The per-stage storage-buffer ceilings this layout is validated against. One
/// buffer in the fragment stage is inside both, so the layout builds.
/// `ValidateBindingCounts` reads them off `CombinedLimits::compat`
/// (`Limits.cpp:95`-`:96`).
const validate_options: bind_group_layout.ValidateOptions = .{
    .max_storage_buffers_in_vertex_stage = 0,
    .max_storage_buffers_in_fragment_stage = 8,
};

/// The two descriptor types the acceptance's two bindings reach, named with
/// the `VkDescriptorType` the pool-sizing switch and `descriptorTypeFor`
/// (`layout_vk.zig:60`) both speak, not the `c_int` the generated constants
/// carry (`src/vulkan.zig:3048`-`:3049`). One declaration per type is what
/// lets each `expectEqual` below see a single `T`: it is generic over one type
/// for both sides, and a `c_int` literal beside a `c_uint` result is a
/// signedness the first cannot represent.
const sampled_image_descriptor_type: vulkan.VkDescriptorType =
    vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
const storage_buffer_descriptor_type: vulkan.VkDescriptorType =
    vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;

/// Everything this shard's own setup can report.
///
/// The library sets are merged in rather than listed, so a rule a new call site
/// can report reaches the test's signature with the call. The three members at
/// the end are this file's own.
const TestError = vulkan_device.Backend.DiscoverError ||
    vulkan_device.Device.CreateError ||
    vulkan_device.AdapterList.FirstError ||
    layout_vk.Error ||
    bind_group_descriptor_set.Error ||
    bind_group_layout.Error ||
    // The failures a `std.testing` assertion can report: `expect` and
    // `expectEqual` report `TestUnexpectedResult` and `TestExpectedEqual`,
    // `expectError` reports `TestExpectedError` and `TestUnexpectedError`.
    // A helper in this file asserts and cannot drop them, so naming them
    // here beats a helper that silently stops asserting.
    error{ TestUnexpectedResult, TestExpectedEqual, TestExpectedError, TestUnexpectedError } ||
    error{
        /// `findBindingByNumber` found nothing at the number the acceptance
        /// names, which a sort that dropped an entry would produce.
        NamedBindingMissing,
        /// `vkCreateDescriptorSetLayout` returned success and a null handle.
        DescriptorSetLayoutReturnedNull,
        /// `vkCreatePipelineLayout` returned success and a null handle.
        PipelineLayoutReturnedNull,
        /// The pool sizing named a descriptor type this shard did not write,
        /// which means the mapping in `layout_vk` produced a third kind for a
        /// two-binding layout.
        UnexpectedDescriptorType,
    };

/// Every teardown refusal one test body has not returned yet.
///
const TeardownError = layout_vk.Error || bind_group_descriptor_set.Error;

const TeardownErrors = struct {
    first: ?TeardownError = null,

    /// Records one refusal. The first is the one that matters: a teardown that
    /// already failed left its handle in a state a later teardown cannot
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

test "native layout preserves sparse public bindings across descriptor permutations" {
    const entries = [_]bind_group_layout.Entry{
        .{
            .binding_number = 17,
            .visibility = .{ .compute = true },
            .kind = .{ .sampler = .{ .binding_type = .filtering } },
        },
        .{
            .binding_number = 1,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = 4,
            } },
        },
    };
    const reversed = [_]bind_group_layout.Entry{ entries[1], entries[0] };
    for ([_][]const bind_group_layout.Entry{ &entries, &reversed }) |descriptor_entries| {
        var layout = try bind_group_layout.BindGroupLayout.init(
            std.testing.allocator,
            .{ .entries = descriptor_entries },
            bind_group_layout.explicit_compatibility_token,
            validate_options,
        );
        defer layout.deinit(std.testing.allocator);
        const bindings = try layout_vk.descriptorBindings(std.testing.allocator, &layout.internal, &.{});
        defer layout_vk.freeDescriptorBindings(std.testing.allocator, bindings);
        try std.testing.expectEqual(@as(usize, 2), bindings.len);
        for (bindings) |binding| switch (binding.binding) {
            1 => try std.testing.expectEqual(storage_buffer_descriptor_type, binding.descriptorType),
            17 => try std.testing.expectEqual(
                @as(vulkan.VkDescriptorType, vulkan.VK_DESCRIPTOR_TYPE_SAMPLER),
                binding.descriptorType,
            ),
            else => return error.TestUnexpectedResult,
        };
        layout.internal.entries[1].binding_number = layout.internal.entries[0].binding_number;
        try std.testing.expectError(
            error.DuplicateBindingNumber,
            layout_vk.descriptorBindings(std.testing.allocator, &layout.internal, &.{}),
        );
    }
}

test "native sampled texture arrays use one public binding and all descriptors" {
    const entries = [_]bind_group_layout.Entry{
        .{
            .binding_number = 7,
            .visibility = .{ .fragment = true },
            .array_size = 3,
            .kind = .{ .sampled_texture = .{
                .sample_type = .float_filterable,
                .view_dimension = .two_d,
                .multisampled = false,
            } },
        },
    };
    var layout = try bind_group_layout.BindGroupLayout.init(
        std.testing.allocator,
        .{ .entries = &entries },
        bind_group_layout.explicit_compatibility_token,
        validate_options,
    );
    defer layout.deinit(std.testing.allocator);
    const bindings = try layout_vk.descriptorBindings(std.testing.allocator, &layout.internal, &.{});
    defer layout_vk.freeDescriptorBindings(std.testing.allocator, bindings);
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqual(@as(u32, 7), bindings[0].binding);
    try std.testing.expectEqual(@as(u32, 3), bindings[0].descriptorCount);
    const pool_sizes = try layout_vk.descriptorCountsPerType(std.testing.allocator, &layout.internal);
    defer std.testing.allocator.free(pool_sizes);
    try std.testing.expectEqual(@as(usize, 1), pool_sizes.len);
    try std.testing.expectEqual(sampled_image_descriptor_type, pool_sizes[0].type);
    try std.testing.expectEqual(@as(u32, 3), pool_sizes[0].descriptorCount);

    layout.internal.entries[0].array_size = 4;
    try std.testing.expectError(
        error.InvalidBindingArrayLayout,
        layout_vk.descriptorBindings(std.testing.allocator, &layout.internal, &.{}),
    );
    layout.internal.entries[0].array_size = 3;
    layout.internal.entries[1].index_in_array = 0;
    try std.testing.expectError(
        error.InvalidBindingArrayLayout,
        layout_vk.descriptorBindings(std.testing.allocator, &layout.internal, &.{}),
    );
    try std.testing.expectError(
        error.InvalidBindingArrayLayout,
        layout_vk.descriptorCountsPerType(std.testing.allocator, &layout.internal),
    );
}

// One invocation writes 42 to a storage buffer declared at set 0, binding 1.
// These are the original fixture words, not a remapped binding-0 module.
const sparse_storage_words = [_]u32{
    0x07230203, 0x00010000, 0,          13,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0005000f, 5,          1,          0x6e69616d, 0,
    0x00060010, 1,          17,         1,          1,
    1,          0x00030047, 5,          3,          0x00050048,
    5,          0,          35,         0,          0x00040047,
    7,          34,         0,          0x00040047, 7,
    33,         1,          0x00020013, 2,          0x00030021,
    3,          2,          0x00040015, 4,          32,
    0,          0x0003001e, 5,          4,          0x00040020,
    6,          2,          5,          0x0004003b, 6,
    7,          2,          0x00040020, 8,          2,
    4,          0x0004002b, 4,          9,          0,
    0x0004002b, 4,          10,         42,         0x00050036,
    2,          1,          0,          3,          0x000200f8,
    11,         0x00050041, 8,          12,         7,
    9,          0x0003003e, 12,         10,         0x000100fd,
    0x00010038,
};

fn sparseUncapturedError(
    _: std.mem.Allocator,
    _: std.Io,
    _: *anyopaque,
    _: dusk.core.ErrorView,
) void {
    @panic("unexpected sparse binding device error");
}

test "unchanged SPIRV binding 1 reaches high native bind group storage readback" {
    try expectNoLayersForced(std.testing.allocator);
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = dusk.engine.Instance.init(.{});
    defer instance.deinit(allocator, io) catch @panic("sparse instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("sparse adapters teardown failed");
    try std.testing.expect(adapters.items.len != 0);
    var context: u8 = 0;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = adapters.items[0].getFeatureLevel(),
        .uncaptured_context = &context,
        .uncaptured_callback = sparseUncapturedError,
    });
    defer device.deinit(allocator, io) catch @panic("sparse device teardown failed");
    const group_layout = try device.createBindGroupLayout(allocator, io, .{
        .entries = &.{.{
            .binding_number = 1,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = 4,
            } },
        }},
    });
    defer device.release(allocator, io, group_layout) catch @panic("sparse layout release failed");
    const pipeline_layout = try device.createPipelineLayout(allocator, io, .{
        .groups = &.{group_layout},
    });
    defer device.release(allocator, io, pipeline_layout) catch
        @panic("sparse pipeline layout release failed");
    const shader = try device.createShaderModule(allocator, io, .{ .words = &sparse_storage_words });
    defer device.release(allocator, io, shader) catch @panic("sparse shader release failed");
    try std.testing.expectEqualSlices(u32, &sparse_storage_words, shader.words);
    const output = try device.createBuffer(allocator, io, .{
        .size = 4,
        .usage = .{ .storage = true, .copy_src = true },
    });
    defer device.release(allocator, io, output) catch @panic("sparse output release failed");
    const readback = try device.createBuffer(allocator, io, .{
        .size = 4,
        .usage = .{ .copy_dst = true, .map_read = true },
    });
    defer device.release(allocator, io, readback) catch @panic("sparse readback release failed");
    const group = try device.createBindGroup(allocator, io, .{
        .layout = pipeline_layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 1,
            .buffer = output,
            .offset = 0,
            .size = 4,
            .kind = .storage,
            .stages = .{ .compute = true },
        } }},
    });
    defer device.release(allocator, io, group) catch @panic("sparse group release failed");
    const compute = try device.createComputePipeline(allocator, io, .{
        .layout = pipeline_layout,
        .compute = .{ .module = shader, .entry_point = "main", .stage = .compute },
    });
    defer device.release(allocator, io, compute) catch @panic("sparse pipeline release failed");
    var encoder = dusk.command.command_encoder.CommandEncoder.init(allocator, device.core.borrow(), .{});
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    {
        try device.acquireOperation(io);
        defer device.releaseOperation(io);
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{
            .pipeline = try compute.ref(&guard),
            .requirements = .{
                .bind_group_layout_mask = 1,
                .bind_group_layout_ids = .{ @intFromPtr(&group_layout.header), 0, 0, 0 },
            },
        });
        try pass.setBindGroup(.{
            .index = 0,
            .group = try group.ref(&guard),
            .layout_id = @intFromPtr(&group_layout.header),
            .min_binding_buffer_size = 4,
            .buffers = &.{.{
                .buffer = try output.ref(&guard),
                .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags(),
            }},
        });
        try pass.dispatch(.{ .x = 1, .y = 1, .z = 1 });
        try pass.end();
        try encoder.copyBufferToBuffer(.{
            .source = try output.ref(&guard),
            .destination = try readback.ref(&guard),
            .size = 4,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    const submitted = try device.submit(allocator, io, &finished);
    try device.wait(io, submitted);
    {
        var lease = try device.getQueue(io);
        defer lease.deinit(io);
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 4 });
        try std.testing.expectEqual(
            dusk.engine.buffer.Buffer.MapCompletion.mapped,
            try readback.native.completeMap(generation, submitted),
        );
        const bytes = try readback.native.getConstMappedRange(0, 4);
        try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, bytes[0..4], .little));
    }
    try device.unmapBuffer(io, readback);
}

test "test-bind-group" {
    try expectNoLayersForced(std.testing.allocator);

    var handles: vulkan_device.HandleSet = .{};
    var teardowns: TeardownErrors = .{};

    // The device, on the first physical device that survived M9's filters.
    // `discoverPhysicalDevices` already refused anything below the Vulkan 1.1
    // floor (`VulkanInfo.cpp:247`).
    var backend = vulkan_device.Backend.init(std.testing.allocator, .{ .handles = &handles });

    var adapters = try backend.discoverPhysicalDevices(.{});

    const adapter = try adapters.first();
    var device = try vulkan_device.Device.create(std.testing.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });

    try testLayoutAndSet(std.testing.allocator, &device, &teardowns);
    try testPipelineCompatibility(std.testing.allocator, &device, &teardowns);

    // Teardown, in the order the handles were created, spelled out rather than
    // left to a `defer`: the two assertions below read the device and the
    // instance this releases (`Device::deinit` releases `.device`,
    // `VulkanInstance::deinit` releases `.instance`), and a `defer` runs after
    // them. The three calls in this order are what
    // `test/vulkan_device.zig:196`-`:198` makes.
    //
    try device.deinit(std.testing.allocator);
    adapters.deinit();
    try backend.deinit();
    // The live-handle count is the assertion that no destroy was missed, and the
    // same one `test/vulkan_device.zig:200`-`:202` makes.
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?vulkan_device.HandleKind, null), handles.firstLeakedKind());
    try std.testing.expectEqual(@as(u32, 0), handles.totalCount());
    // Last, so a refusal the two helpers recorded cannot cut the teardown
    // sequence above short and leave the device live.
    try teardowns.report();
}

/// The first acceptance half: the layout, the `VkDescriptorSetLayout`, and the
/// descriptor set cut from it.
fn testLayoutAndSet(
    gpa: std.mem.Allocator,
    device: *const vulkan_device.Device,
    teardowns: *TeardownErrors,
) TestError!void {
    var layout = try makeLayout(gpa);
    defer layout.deinit(gpa);

    // Packing order is private. Look up resources by the caller's binding number.
    try std.testing.expectEqual(expected_binding_count, layout.queryBindingCount());
    try std.testing.expect(!layout.isEmpty());

    const texture = layout.findBindingByNumber(sampled_texture_binding_number) orelse
        return error.NamedBindingMissing;
    try std.testing.expect(texture.layout == .sampled_texture);

    const buffer = layout.findBindingByNumber(storage_buffer_binding_number) orelse
        return error.NamedBindingMissing;
    try std.testing.expect(buffer.layout == .buffer);
    try std.testing.expectEqual(
        storage_buffer_min_binding_size,
        buffer.layout.buffer.min_binding_size,
    );

    // The counts `ValidatePipelineLayoutDescriptor` accumulates
    // (`PipelineLayout.cpp:127`-`:128`), which is where the two kinds are told
    // apart without touching Vulkan.
    const counts = layout.validationCounts();
    try std.testing.expectEqual(
        @as(u32, 1),
        counts.sampled_textures_per_stage[fragment_stage_index],
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        counts.storage_buffers_per_stage[fragment_stage_index],
    );
    try std.testing.expectEqual(@as(u32, 0), layout.dynamicStorageBufferCount());
    try std.testing.expectEqual(@as(u32, 0), layout.unverifiedBufferCount());

    // The pool sizing `ComputeVulkanStaticBindings` produced, which is what the
    // descriptor-set layout is built from one step later and what the set
    // allocator sizes its pools from.
    const pool_sizes = try layout_vk.descriptorCountsPerType(gpa, &layout.internal);
    defer gpa.free(pool_sizes);
    try expectOneDescriptorOfEachType(pool_sizes, &layout);

    // The handle itself. `createDescriptorSetLayout` writes one binding per
    // mapped stored entry, so the driver was handed two.
    const set_layout = try layout_vk.createDescriptorSetLayout(
        gpa,
        device.procs,
        device.vk_device,
        &layout.internal,
        &.{},
    );
    if (set_layout == null) return error.DescriptorSetLayoutReturnedNull;
    defer destroySetLayout(device, set_layout, teardowns);

    // The bind group. The allocator sizes its pools from the same per-type
    // counts, so a set cut from this pool is a set over this set layout
    // (`DescriptorSetAllocator.h:70`-`:74`).
    var allocator = try bind_group_descriptor_set.DescriptorSetAllocator.init(
        gpa,
        device.procs,
        device.vk_device,
        set_layout,
        pool_sizes,
    );
    defer destroySetAllocator(&allocator, teardowns);

    var first = try allocator.allocate();
    try std.testing.expect(first.set != null);
    try std.testing.expectEqual(@as(u32, 1), allocator.queryPoolCount());

    // One batch per pool. The pool was cut for
    // `max_descriptors_per_pool` descriptors and this layout needs two, so one
    // pool holds `512 / 2` sets, and `allocateDescriptorPool` cut all of them
    // at once (`DescriptorSetAllocator.cpp:179`-`:192`).
    try std.testing.expectEqual(
        bind_group_descriptor_set.max_descriptors_per_pool / expected_binding_count,
        allocator.queryMaxSetsPerPool(),
    );

    const first_set = first.set;

    // The set is not reusable at once. `vkCmdBindDescriptorSets` lets a driver
    // consume the set any time between the host execution of the command and
    // the end of the draw (`DescriptorSetAllocator.cpp:125`-`:129`), so the
    // port queues the deallocation against the queue's pending serial and
    // returns the set only once the timeline reports that serial completed.
    //
    // Nothing here submits, so the serial is the literal the queue is asked to
    // drain at, not one a submit produced.
    const pending_serial: serial.Serial = 1;
    try allocator.deallocate(&first, pending_serial);

    // The cleared allocation is the assertion: a bind group that outlives its
    // deallocation must read a null set, not a recycled one
    // (`DescriptorSetAllocator.cpp:140`).
    try std.testing.expect(first.set == null);

    // A second set before the serial completes comes from the same pool, which
    // is the assertion that no pool was cut for a set the GPU still holds.
    var second = try allocator.allocate();
    try std.testing.expect(second.set != null);
    try std.testing.expect(second.set != first_set);
    try std.testing.expectEqual(@as(u32, 1), allocator.queryPoolCount());

    // Completing the serial makes the retired first set available again.
    try allocator.finishDeallocation(1);

    // A serial below the last one enqueued is refused rather than corrupting a
    // drain (`SerialQueue.h:69`, a release-build assume upstream). The guard
    // reads the last entry the queue still holds and short-circuits on
    // `Empty()`, so it says nothing at all while the queue is empty. The drain
    // above emptied it, which is why `second` has to enqueue before any serial
    // can be below what the queue holds.
    const second_set = second.set;
    try allocator.deallocate(&second, pending_serial);
    try std.testing.expect(second.set == null);

    // The second set remains unavailable until its retirement serial completes.
    var third = try allocator.allocate();
    try std.testing.expect(third.set != null);
    try std.testing.expect(third.set != second_set);
    try std.testing.expectEqual(@as(u32, 1), allocator.queryPoolCount());

    // One below `pending_serial` is `beginning_of_gpu_time`, the serial no submit
    // hands out (`ExecutionQueue.h:193`, the counter's initial value, which the
    // port names `Timeline.beginning_of_gpu_time`), so it is below the entry the
    // queue holds and the enqueue is refused.
    try std.testing.expectError(
        error.SerialOrderViolation,
        allocator.deallocate(&third, pending_serial - 1),
    );

    // The refused deallocation left the third set allocated, so the pool count
    // and the free list are what they were before it.
    try std.testing.expect(third.set != null);
    try std.testing.expectEqual(@as(u32, 1), allocator.queryPoolCount());

    // The rejected deallocation cannot make the still-live third set reusable.
    try allocator.finishDeallocation(pending_serial);

    const fourth = try allocator.allocate();
    try std.testing.expect(fourth.set != null);
    try std.testing.expect(fourth.set != third.set);
    try std.testing.expectEqual(@as(u32, 1), allocator.queryPoolCount());
}

/// The second acceptance half: the token, which is what makes two layouts
/// interchangeable in a pipeline layout.
fn testPipelineCompatibility(
    gpa: std.mem.Allocator,
    device: *const vulkan_device.Device,
    teardowns: *TeardownErrors,
) TestError!void {
    var written = try makeLayout(gpa);
    defer written.deinit(gpa);

    // A caller-written layout carries `kExplicitPCT` (`Device.h:204`,
    // `IntegerTypes.h:139`-`:140`).
    try std.testing.expectEqual(
        bind_group_layout.explicit_compatibility_token,
        written.pipelineCompatibilityToken(),
    );

    // The same descriptor with the same token is the same layout, which is what
    // `IsLayoutEqual` (`BindGroupLayout.cpp:67`) decides and what lets the
    // pipeline layout cache one handle per layout.
    var same = try makeLayout(gpa);
    defer same.deinit(gpa);
    try std.testing.expect(written.isLayoutEqual(&same, false));
    try std.testing.expectEqual(written.contentHash(), same.contentHash());

    // The pipeline layout itself, created from the bind group layout's
    // `VkDescriptorSetLayout`. Upstream builds one per specialization
    // (`PipelineLayoutVk.cpp:116`-`:152`); the port builds the handle and the
    // caller decides where to keep it, so this asks only that the set layout
    // the compatibility below is proved against is the one this layout was
    // created from.
    const set_layout = try layout_vk.createDescriptorSetLayout(
        gpa,
        device.procs,
        device.vk_device,
        &written.internal,
        &.{},
    );
    if (set_layout == null) return error.DescriptorSetLayoutReturnedNull;
    defer destroySetLayout(device, set_layout, teardowns);

    const pipeline_layout = try layout_vk.createPipelineLayout(
        device.procs,
        device.vk_device,
        &.{set_layout},
        // No immediate data, so Dawn's one all-stage push-constant range
        // (`PipelineLayoutVk.cpp:93`-`:102`) is not requested.
        0,
    );
    if (pipeline_layout == null) return error.PipelineLayoutReturnedNull;
    defer destroyPipelineLayout(device, pipeline_layout, teardowns);

    // A layout deduced from a pipeline's shader carries a non-zero token, and
    // `ValidatePipelineLayoutDescriptor` refuses to mix the two
    // (`PipelineLayout.cpp:122`-`:125`). The token is therefore the whole of the
    // compatibility rule: same descriptor, different token, not interchangeable.
    var counter: bind_group_layout.TokenCounter = .{};
    const deduced_token = try counter.mint();
    try std.testing.expect(deduced_token != bind_group_layout.explicit_compatibility_token);

    var deduced = try makeLayoutWithToken(gpa, deduced_token);
    defer deduced.deinit(gpa);
    try std.testing.expectEqual(deduced_token, deduced.pipelineCompatibilityToken());
    try std.testing.expect(!written.isLayoutEqual(&deduced, false));

    // The implicit-layout cache is the one caller that must see through the
    // token, because a pipeline may reach its own deduced layout through a
    // different one (`Device.cpp:2152`).
    try std.testing.expect(written.isLayoutEqual(&deduced, true));
    try std.testing.expectEqual(written.contentHash(), deduced.contentHash());

    // Two deduced tokens differ from each other too, which is what keeps one
    // pipeline's layout out of another pipeline's pipeline layout. The counter
    // starts at one so the first token is never the explicit one
    // (`Device.cpp:283`), and a silent wrap is an error rather than a reuse.
    const second_token = try counter.mint();
    try std.testing.expect(second_token != deduced_token);
    try std.testing.expectEqual(deduced_token + 1, second_token);
    try std.testing.expectEqual(@as(u64, 3), counter.next_token);
}

/// Releases a descriptor set layout, recording a refused release for
/// `teardowns`.
///
fn destroySetLayout(
    device: *const vulkan_device.Device,
    set_layout: vulkan.VkDescriptorSetLayout,
    teardowns: *TeardownErrors,
) void {
    layout_vk.destroyDescriptorSetLayout(device.procs, device.vk_device, set_layout) catch |err|
        teardowns.record(err);
}

/// Releases the set allocator, recording a refused release for `teardowns`. As
/// `destroySetLayout`, the only member the release can report is a proc the
/// allocations beside it already required.
fn destroySetAllocator(
    allocator: *bind_group_descriptor_set.DescriptorSetAllocator,
    teardowns: *TeardownErrors,
) void {
    allocator.deinit() catch |err| teardowns.record(err);
}

/// Releases a pipeline layout, recording a refused release for `teardowns`. As
/// `destroySetLayout`, the only member the destroy can report is the absent
/// proc.
fn destroyPipelineLayout(
    device: *const vulkan_device.Device,
    pipeline_layout: vulkan.VkPipelineLayout,
    teardowns: *TeardownErrors,
) void {
    layout_vk.destroyPipelineLayout(device.procs, device.vk_device, pipeline_layout) catch |err|
        teardowns.record(err);
}

/// The layout the acceptance names: a sampled texture at binding 0 and a
/// storage buffer at binding 1.
fn makeLayout(gpa: std.mem.Allocator) bind_group_layout.Error!bind_group_layout.BindGroupLayout {
    return makeLayoutWithToken(gpa, bind_group_layout.explicit_compatibility_token);
}

fn makeLayoutWithToken(
    gpa: std.mem.Allocator,
    token: bind_group_layout.PipelineCompatibilityToken,
) bind_group_layout.Error!bind_group_layout.BindGroupLayout {
    // The fragment stage sees both. The storage buffer is a read-write one, so
    // it must not be vertex-visible (`BindGroupLayoutInternal.cpp:129`-`:133`),
    // which is why both entries name fragment and neither names vertex.
    const fragment: bind_group_layout.ShaderStages = .{ .fragment = true };

    const entries = [_]bind_group_layout.Entry{
        .{
            .binding_number = sampled_texture_binding_number,
            .visibility = fragment,
            .kind = .{ .sampled_texture = .{
                .sample_type = .float_filterable,
                .view_dimension = .two_d,
                .multisampled = false,
            } },
        },
        .{
            .binding_number = storage_buffer_binding_number,
            .visibility = fragment,
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = storage_buffer_min_binding_size,
            } },
        },
    };

    return bind_group_layout.BindGroupLayout.init(gpa, .{
        .entries = &entries,
        .label = "m12-bind-group",
    }, token, validate_options);
}

/// Asserts the two bindings reached two distinct descriptor types, one each.
///
/// `descriptorCountsPerType` writes the array in ascending numeric type order,
/// so the position of each entry is the port's and not the driver's. Each entry
/// is therefore looked up by type rather than by position, and a reordering is
/// not a failure.
fn expectOneDescriptorOfEachType(
    pool_sizes: []const vulkan.VkDescriptorPoolSize,
    layout: *const bind_group_layout.BindGroupLayout,
) TestError!void {
    try std.testing.expectEqual(@as(usize, 2), pool_sizes.len);

    var sampled_image_count: u32 = 0;
    var storage_buffer_count: u32 = 0;
    for (pool_sizes) |pool_size| {
        switch (pool_size.type) {
            sampled_image_descriptor_type => {
                sampled_image_count = pool_size.descriptorCount;
            },
            storage_buffer_descriptor_type => {
                storage_buffer_count = pool_size.descriptorCount;
            },
            else => return error.UnexpectedDescriptorType,
        }
    }
    try std.testing.expectEqual(@as(u32, 1), sampled_image_count);
    try std.testing.expectEqual(@as(u32, 1), storage_buffer_count);

    const buffer = layout.findBindingByNumber(storage_buffer_binding_number) orelse
        return error.NamedBindingMissing;
    const texture = layout.findBindingByNumber(sampled_texture_binding_number) orelse
        return error.NamedBindingMissing;
    try std.testing.expectEqual(
        storage_buffer_descriptor_type,
        layout_vk.descriptorTypeFor(buffer.layout),
    );
    try std.testing.expectEqual(
        sampled_image_descriptor_type,
        layout_vk.descriptorTypeFor(texture.layout),
    );
    try std.testing.expect(layout_vk.isMapped(buffer.layout));
}

/// Asserts the gate line's no-layer environment when the variable is present.
///
fn expectNoLayersForced(gpa: std.mem.Allocator) !void {
    // 0.16 removed `std.process.getEnvVarOwned`: the process environment now
    // reaches a test through `std.testing.environ`, which the test runner
    // fills from the environment the process was started with, and `getAlloc`
    // is the owned read that replaced it. A variable that is not set reports
    // `error.EnvironmentVariableMissing` rather than an empty optional, so
    // the absence is still not a failure.
    const value = std.testing.environ.getAlloc(
        gpa,
        "VK_LOADER_LAYERS_DISABLE",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => |other| return other,
    };
    defer gpa.free(value);
    try std.testing.expectEqualStrings("*", value);
}
