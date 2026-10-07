//! Occlusion queries encoded through the frontend and replayed by the engine.
//! The covering draw counts four samples, the clipped draw counts zero, and
//! an unwritten third slot replaces the destination sentinel with zero.
//! The pure tests below cover query ownership, validation and resolve plans.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const command_query = dusk.command.query;
const query_set = dusk.engine.query_set;
const vulkan_device = dusk.engine.vulkan_device;
const spirv = dusk.spirv;
const dispatch = dusk.vk.dispatch;
const platform = dusk.platform;
const vulkan = dusk.platform.vulkan_bindings;
const triangle = @import("triangle.zig");
const replay = engine.command_buffer;
const render_pass_cache = engine.render_pass_cache;
const framebuffer_cache = engine.framebuffer_cache;
const recording_context = engine.recording_context;
const command_encoder = dusk.command.command_encoder;

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

const gpu_query_count: u32 = 3;
const gpu_resolve_size: u64 = query_storage_size * gpu_query_count;

test "test-query-set: replay counts covering 4, clipped 0 and zero-fills an unavailable slot" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var handles: vulkan_device.HandleSet = .{};
    const counts = try runPass(threaded.io(), &handles);
    try std.testing.expectEqual(covering_sample_count, counts[covering_query]);
    try std.testing.expectEqual(clipped_sample_count, counts[clipped_query]);
    try std.testing.expectEqual(@as(u64, 4), counts[covering_query]);
    try std.testing.expectEqual(@as(u64, 0), counts[clipped_query]);
    try std.testing.expectEqual(@as(u64, 0), counts[2]);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?vulkan_device.HandleKind, null), handles.firstLeakedKind());
}

fn runPass(
    io: std.Io,
    handles: *vulkan_device.HandleSet,
) ![gpu_query_count]u64 {
    const allocator = std.testing.allocator;
    var recorder: ErrorRecorder = .{};
    // SAFETY: initBackend writes every owner before success and rolls back on failure.
    var front: FrontEnd = undefined;
    try front.initBackend(io, &recorder, .vulkan);
    defer front.deinit(io);
    const context = front.device.native orelse return error.NativeBackendRequired;
    const device = context.native_device;
    const core_device = front.coreDevice();
    const q = &context.queue;
    // SAFETY: cleanup reads scene only after createSceneWithShaders succeeds.
    var scene: triangle.Scene = undefined;
    var scene_created = false;
    defer if (scene_created) triangle.destroyScene(device, &scene, handles);
    var guard = try core.ObjectGuard.lock(io, core_device.borrow().objectList());
    defer guard.unlock(io);
    try front.device.bindObjectsLocked(&guard, allocator);
    const resource_device: engine.buffer.Device = .{
        .allocator = allocator,
        .dispatch = device.dispatchTable(),
        .vk_device = device.vk_device,
        .memory_properties = device.memoryProperties(),
        .non_coherent_atom_size = 1,
        .max_buffer_size = std.math.maxInt(u64),
        .handles = handles,
    };
    const target = created: {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        break :created try front.device.createTexture(allocator, io, .{
            .usage = .{ .render_attachment = true },
            .size = .{ .width = target_width, .height = target_height },
            .format = .rgba8_unorm,
        });
    };
    defer target.header.releaseUserLocked(&guard, io) catch
        @panic("query target release failed");
    const view = created: {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        break :created try front.device.createTextureView(allocator, io, .{
            .texture = target,
            .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
        });
    };
    defer view.header.releaseUserLocked(&guard, io) catch
        @panic("query target view release failed");
    var passes = render_pass_cache.RenderPassCache.init(.{
        .allocator = allocator,
        .device = .{ .procs = device.procs, .vk_device = device.vk_device },
    });
    defer passes.deinit(io);
    var deleter: FramebufferDeleter = .{
        .procs = device.procs,
        .vk_device = device.vk_device,
    };
    var framebuffers = framebuffer_cache.FramebufferCache.init(.{
        .allocator = allocator,
        .device = .{ .procs = device.procs, .vk_device = device.vk_device },
        .destroy_context = &deleter,
        .destroy_when_unused = FramebufferDeleter.destroy,
    });
    defer framebuffers.deinit();
    const vertex_words = try spirv.wordsFromBytes(allocator, vertex_fixture);
    defer allocator.free(vertex_words);
    const fragment_words = try spirv.wordsFromBytes(allocator, fragment_fixture);
    defer allocator.free(fragment_words);
    scene = try triangle.createSceneWithShaders(device, handles, .{
        .vertex_words = vertex_words,
        .fragment_words = fragment_words,
        .vertex_entry_point = vertex_entry_point,
        .fragment_entry_point = fragment_entry_point,
        .has_tint_binding = false,
    });
    scene_created = true;
    const pipeline = created: {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        break :created try scene.typedPipeline(allocator, io, &front.device);
    };
    defer pipeline.header.releaseUserLocked(&guard, io) catch @panic("query pipeline release failed");
    try std.testing.expect(pipeline.header.state == .alive);
    const pipeline_options = try pipeline.renderOptions(&guard);
    try std.testing.expectEqual(@as(u32, 0), pipeline_options.requirements.bind_group_layout_mask);
    try std.testing.expectEqual(
        @as(usize, 1),
        context.pipeline_store.?.queryPipelineCount(&guard),
    );
    var destination = triangle.borrowBuffer(
        resource_device,
        scene.staging,
        gpu_resolve_size,
        .{ .query_resolve = true, .copy_dst = true },
    );
    const created = try front.createQuerySet(io, &guard, .occlusion, gpu_query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("GPU query release failed");
    try engine.vulkan_query_set.createPool(&guard, q, created.set);
    try std.testing.expect(try engine.vulkan_query_set.getPool(&guard, created.set) != null);
    try std.testing.expect(!created.set.isQueryAvailable(&guard, 2));

    const map_memory = device.procs.map_memory orelse return error.MissingDeviceProc;
    const unmap_memory = device.procs.unmap_memory orelse return error.MissingDeviceProc;
    var mapped: ?*anyopaque = null;
    try dispatch.checkVkSuccess(map_memory(device.vk_device, scene.staging.memory, 0, gpu_resolve_size, 0, &mapped));
    defer unmap_memory(device.vk_device, scene.staging.memory);
    const bytes: [*]u8 = @ptrCast(mapped orelse return error.MapReturnedNull);
    @memset(bytes[0..gpu_resolve_size], 0xa5);

    var encoder = command_encoder.CommandEncoder.init(allocator, core_device.borrow(), .{});
    defer encoder.deinit(allocator, io, &guard);
    var pass = begun: {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        break :begun try front.device.beginRenderPass(allocator, io, &encoder, .{
            .color_attachments = &.{.{
                .view = view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            }},
            .width = target_width,
            .height = target_height,
            .occlusion_query_set = created.set,
            .occlusion_query_count = gpu_query_count,
        });
    };
    defer pass.deinit(io, &guard);
    try pass.setPipeline(&guard, pipeline_options);
    try pass.setViewport(.{
        .width = @floatFromInt(target_width),
        .height = @floatFromInt(target_height),
        .min_depth = 0,
        .max_depth = 1,
    });
    try pass.setScissorRect(.{ .width = target_width, .height = target_height });
    try pass.beginOcclusionQuery(covering_query);
    try pass.draw(.{
        .vertex_count = triangle_vertex_count,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try pass.endOcclusionQuery();
    // A zero-area scissor at the far corner is valid frontend input and
    // intersects no sample of the render target.
    try pass.setScissorRect(.{ .x = target_width, .y = target_height, .width = 0, .height = 0 });
    try pass.beginOcclusionQuery(clipped_query);
    try pass.draw(.{
        .vertex_count = triangle_vertex_count,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try pass.endOcclusionQuery();
    try pass.end(io, &guard);
    try encoder.resolveQuerySet(.{
        .query_set = created.set,
        .query_count_of_set = gpu_query_count,
        .first_query = 0,
        .query_count = gpu_query_count,
        .destination = &destination,
        .destination_size = gpu_resolve_size,
        .destination_usage = .{ .query_resolve = true, .copy_dst = true },
    });
    var finished = try encoder.finish();
    defer finished.deinit(allocator, io, &guard);
    // Replay borrows the finished stream; the caller releases it after GPU completion.
    var recording = recording_context.CommandRecordingContext.init(allocator);
    defer recording.deinit();
    defer {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        dispatch.checkVkSuccess(
            (device.procs.device_wait_idle orelse unreachable)(device.vk_device),
        ) catch @panic("query GPU completion failed");
    }
    var lease = acquired: {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        break :acquired try front.device.getQueue(io);
    };
    defer {
        guard.unlock(io);
        lease.deinit(io);
        guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
    }
    if (context.recording_uses == null) {
        context.recording_uses = try engine.native_resources.PendingUses.prepareDeclaredLocked(
            allocator,
            &guard,
            core_device,
            &.{},
        );
    }
    try replay.recordCommands(allocator, .{
        .io = io,
        .guard = &guard,
        .core_device = core_device,
        .queue = q,
        .recording = &recording,
        .render_pass_cache = &passes,
        .framebuffer_cache = &framebuffers,
        .max_immediate_size = front.device.getLimits().v1.max_immediate_size,
        .kernels = &context.kernel_cache.?,
        .pending_uses = &context.recording_uses.?,
        .timestamp_quantization = front.device.timestamp_quantization,
    }, &finished);
    guard.unlock(io);
    const submitted = submit: {
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        break :submit try lease.submit(allocator, io, .{
            .command_buffers = &.{q.commandBuffer()},
        }, &.{ &pipeline.header, &target.header, &view.header, &created.set.header });
    };
    {
        guard.unlock(io);
        defer guard = core.ObjectGuard.lockUncancelable(io, core_device.borrow().objectList());
        lease.deinit(io);
        try front.device.wait(io, submitted.serial);
    }
    try std.testing.expect(platform.Timeline.completedSerial(io, &q.timeline) >= submitted.serial);
    try std.testing.expectEqual(@as(vulkan.VkResult, vulkan.VK_SUCCESS), try q.fenceStatus(submitted.fence));
    // Submission and waiting must not change the frontend's borrowed owners.
    try std.testing.expect(front.adapters.items[0].getInstance() == &front.instance);
    try std.testing.expect(front.device.adapter == &front.adapters.items[0]);
    try std.testing.expect(front.coreDevice() == &front.device.core);
    try std.testing.expectEqual(@as(u64, 1), front.instance.queryDeviceCount(io));
    try std.testing.expect(created.set.isQueryAvailable(&guard, covering_query));
    try std.testing.expect(created.set.isQueryAvailable(&guard, clipped_query));
    try std.testing.expect(!created.set.isQueryAvailable(&guard, 2));
    var counts: [gpu_query_count]u64 = undefined;
    for (&counts, 0..) |*count, index| {
        count.* = std.mem.readInt(u64, bytes[index * query_storage_size ..][0..8], .little);
    }
    return counts;
}

const FramebufferDeleter = struct {
    procs: *const dispatch.DeviceProcs,
    vk_device: vulkan.VkDevice,

    fn destroy(context: *anyopaque, framebuffer: vulkan.VkFramebuffer) void {
        const self: *FramebufferDeleter = @ptrCast(@alignCast(context));
        (self.procs.destroy_framebuffer orelse unreachable)(self.vk_device, framebuffer, null);
    }
};

fn releaseResource(
    device: *core.Device,
    guard: *const core.ObjectGuard,
    io: std.Io,
    handle: core.Handle,
) (core.HandleError || core.ReferenceError)!void {
    const header = try device.resolveReference(guard, handle);
    try header.releaseUserLocked(guard, io);
}

// ---------------------------------------------------------------------------
// The front end: the object, its availability and the plan one resolve makes.
// ---------------------------------------------------------------------------

/// Device creation and query validation errors for either selected back end.
const FrontEndError = engine.DeviceError ||
    engine.AdapterError ||
    engine.InstanceError ||
    query_set.QuerySet.CreateError ||
    core.HandleError ||
    spirv.Error ||
    std.mem.Allocator.Error ||
    error{
        /// The null back end enumerated no adapter, so `items[0]` names
        /// nothing. M8's own shard asserts the one adapter exists.
        NoNullAdapter,
        NoPhysicalDevice,
    };

/// Counts the errors that no scope took. Every front-end test below ends with a
/// zero count, because the query rules return a rule to their caller and never
/// push one through the device's sink.
const ErrorRecorder = struct {
    count: u64 = 0,

    fn record(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: *anyopaque,
        view: core.ErrorView,
    ) void {
        _ = io;
        const self: *ErrorRecorder = @ptrCast(@alignCast(context));
        // Field by field because Zig 0.16.0 has no `==` for a struct. `ptr`
        // alone would not identify an allocator: a stateless allocator may
        // carry `undefined` there, so the vtable is the half that names it.
        std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
        std.debug.assert(view.message.len > 0);
        self.count += 1;
    }
};

/// A handle and the object behind it.
const Created = struct {
    handle: api.QuerySet,
    set: *query_set.QuerySet,
};

/// A stable device owner. Pure tests select null; GPU replay selects Vulkan.
const FrontEnd = struct {
    instance: engine.Instance,
    adapters: engine.AdapterList,
    device: engine.Device,
    object_mutex: platform.DeviceMutex,
    native_handle_baseline: ?vulkan_device.HandleSet,

    /// Initialize in the caller's storage. Do not move or copy the owner after
    /// this call: adapters borrow its instance and query objects borrow its
    /// core device. The recorder must also outlive the owner.
    fn init(self: *FrontEnd, io: std.Io, recorder: *ErrorRecorder) FrontEndError!void {
        return self.initBackend(io, recorder, .null_);
    }

    fn initBackend(
        self: *FrontEnd,
        io: std.Io,
        recorder: *ErrorRecorder,
        backend_type: api.BackendType,
    ) FrontEndError!void {
        // SAFETY: rollback runs after adapters.deinit when enumeration succeeded.
        // No device exists on an init error. The caller's try prevents later reads or deinit.
        errdefer self.* = undefined;
        // Initialize this owner in place, never through a by-value FrontEnd return.
        // Adapters retain &self.instance, the device retains its adapter, and query
        // objects retain &self.device.core. The callback retains the external recorder.
        // Publish coreDevice only after all three fields have been initialized.
        self.object_mutex = .{};
        self.native_handle_baseline = null;
        self.instance = engine.Instance.init(.{ .backend_type = backend_type });
        errdefer self.instance.deinit(std.testing.allocator, io) catch @panic("query instance rollback failed");
        self.adapters = try self.instance.enumerateAdapters(std.testing.allocator, io, .{
            .feature_level = .core,
            .power_preference = .undefined_,
            .backend_type = backend_type,
        });
        errdefer self.adapters.deinit(io) catch @panic("query adapter rollback failed");
        if (self.adapters.items.len == 0) {
            return if (backend_type == .null_) error.NoNullAdapter else error.NoPhysicalDevice;
        }
        if (self.instance.native_context) |native_context| {
            self.native_handle_baseline = native_context.handles;
        }

        // Adapter creation registers the device with this instance. Keep both
        // owners in place until device teardown removes that registration.
        self.device = try self.adapters.items[0].createDevice(std.testing.allocator, io, .{
            .adapter = &self.adapters.items[0],
            .label = "query-set front end",
            .feature_level = self.adapters.items[0].getFeatureLevel(),
            .uncaptured_context = @ptrCast(recorder),
            .uncaptured_callback = ErrorRecorder.record,
            .object_mutex = &self.object_mutex.mutex,
        });
    }

    fn deinit(self: *FrontEnd, io: std.Io) void {
        self.device.deinit(std.testing.allocator, io) catch @panic("query front-end device teardown failed");
        self.adapters.deinit(io) catch @panic("query front-end adapter teardown failed");
        if (self.native_handle_baseline) |baseline| {
            const native_context = self.instance.native_context orelse
                @panic("query native instance context missing");
            std.testing.expectEqualSlices(
                u32,
                &baseline.counts,
                &native_context.handles.counts,
            ) catch @panic("query native resource handle leaked");
        }
        self.instance.deinit(std.testing.allocator, io) catch @panic("query front-end instance teardown failed");
        // SAFETY: all user aliases were released before guarded device teardown.
        // Adapter teardown finishes all remaining borrows before this terminal poison.
        // Callers neither read nor deinit this owner again.
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
        io: std.Io,
        guard: *const core.ObjectGuard,
        query_type: api.QueryType,
        count: u32,
    ) FrontEndError!Created {
        const handle = try query_set.QuerySet.create(std.testing.allocator, io, guard, self.coreDevice(), .{
            .label = "occlusion",
            .type_ = query_type,
            .count = count,
        }, .{ .timestamp_query_enabled = true });
        errdefer self.releaseQuerySet(guard, io, handle) catch @panic("query resolve rollback failed");
        return .{
            .handle = handle,
            .set = try query_set.resolveQuerySet(self.coreDevice(), guard, handle),
        };
    }

    fn releaseQuerySet(
        self: *FrontEnd,
        guard: *const core.ObjectGuard,
        io: std.Io,
        handle: api.QuerySet,
    ) (core.HandleError || core.ReferenceError)!void {
        try releaseResource(self.coreDevice(), guard, io, .{
            .ptr = @alignCast(handle.handle orelse return error.HandleKindMismatch),
            .kind = .query_set,
        });
    }
};

test "test-query-set: a fresh occlusion set reports its type and count and holds no result" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    // SAFETY: in-place init fills every field before success. Its rollback handles errors,
    // and try exits before any partial-owner read or deferred deinit.
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);
    try std.testing.expect(front.adapters.items[0].getInstance() == &front.instance);
    try std.testing.expect(front.device.adapter == &front.adapters.items[0]);
    try std.testing.expect(front.coreDevice() == &front.device.core);

    const created = try front.createQuerySet(io, &guard, .occlusion, query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    const set = created.set;

    // The object answers the front-end `QueryType`, which is the command
    // module's own enum and not `api.QueryType`: `QuerySet.h:50` returns
    // `wgpu::QueryType` through the command struct.
    try std.testing.expectEqual(command_query.QueryType.occlusion, set.apiGetType(&guard));
    try std.testing.expectEqual(query_count, set.apiGetCount(&guard));
    try std.testing.expectEqual(@as(usize, 1), front.coreDevice().queryTrackedCount(&guard));
    // A successful device construction retains its instance until teardown.
    try std.testing.expectEqual(@as(u64, 1), front.instance.queryDeviceCount(io));

    // A fresh vector is all false (`QuerySet.cpp:86`), which is the answer that
    // separates a query nobody wrote from one that closed on zero samples.
    try std.testing.expectEqual(@as(usize, query_count), set.availability.len);
    var index: u32 = 0;
    while (index < query_count) : (index += 1) {
        try std.testing.expect(!set.isQueryAvailable(&guard, index));
    }
    try std.testing.expect(!set.areAllQueriesAvailable(&guard, 0, query_count));
    try set.validateCanUseInSubmit(&guard);
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a set of no queries is legal and holds no result" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    // SAFETY: in-place init fills every field before success. Its rollback handles errors,
    // and try exits before any partial-owner read or deferred deinit.
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    // Dawn compares the count against a maximum and not against a minimum
    // (`QuerySet.cpp:55-57`), so zero is a set that answers every question.
    const created = try front.createQuerySet(io, &guard, .occlusion, 0);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");

    try std.testing.expectEqual(@as(u32, 0), created.set.apiGetCount(&guard));
    try std.testing.expectEqual(@as(usize, 0), created.set.availability.len);
    try std.testing.expect(created.set.areAllQueriesAvailable(&guard, 0, 0));
    try created.set.validateCanUseInSubmit(&guard);
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: the maximum count is accepted and one more is refused" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    // SAFETY: in-place init fills every field before success. Its rollback handles errors,
    // and try exits before any partial-owner read or deferred deinit.
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    // `kMaxQueryCount` (`Constants.h:94`), which the port names as a rule
    // because it is not a device limit.
    try std.testing.expectEqual(@as(u32, 4096), command_query.max_query_count);
    const created = try front.createQuerySet(io, &guard, .occlusion, command_query.max_query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    try std.testing.expectEqual(command_query.max_query_count, created.set.apiGetCount(&guard));

    try std.testing.expectError(error.QueryCountAboveMaximum, query_set.QuerySet.create(
        std.testing.allocator,
        io,
        &guard,
        front.coreDevice(),
        .{ .label = "too many", .type_ = .occlusion, .count = command_query.max_query_count + 1 },
        .{},
    ));
    // A refused descriptor publishes no handle and leaves no creator reference.
    try std.testing.expectEqual(@as(usize, 1), front.coreDevice().queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a timestamp set needs the feature and an occlusion set does not" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    // SAFETY: in-place init fills every field before success. Its rollback handles errors,
    // and try exits before any partial-owner read or deferred deinit.
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

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

    // `create` runs the same rule before it allocates or publishes an owner.
    try std.testing.expectError(error.RequiredFeatureMissing, query_set.QuerySet.create(
        std.testing.allocator,
        io,
        &guard,
        front.coreDevice(),
        .{ .label = "timestamp", .type_ = .timestamp, .count = query_count },
        .{ .timestamp_query_enabled = false },
    ));
    try std.testing.expectEqual(@as(usize, 0), front.coreDevice().queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: a destroyed set is refused at submit time" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    // SAFETY: in-place init fills every field before success. Its rollback handles errors,
    // and try exits before any partial-owner read or deferred deinit.
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    const created = try front.createQuerySet(io, &guard, .occlusion, query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("retired query release failed");

    // `createQuerySet` returns the object it made, so the handle names one; a
    // null handle would leave nothing for `destroy` to name, which is the
    // precondition this call states rather than a driver answer to read.
    const object = created.handle.handle orelse return error.NoQuerySetObject;
    try front.coreDevice().destroy(&guard, io, .{
        .ptr = @alignCast(object),
        .kind = .query_set,
    });

    // `ValidateCanUseInSubmitNow` (`QuerySet.cpp:148-152`) is what catches a
    // set destroyed between `finish` and `submit`
    // (`QueryValidationTests.cpp:167-187`).
    try std.testing.expectEqual(query_set.State.destroyed, created.set.state);
    try std.testing.expect(!created.set.header.isAlive(&guard));
    try std.testing.expectError(error.QuerySetDestroyed, created.set.validateCanUseInSubmit(&guard));
    const retired_header = try front.coreDevice().resolveReference(&guard, .{
        .ptr = @alignCast(object),
        .kind = .query_set,
    });
    try std.testing.expect(retired_header == &created.set.header);

    // API destroy releases the returned user alias. With no other alias it
    // retires the payload, while the arena keeps its host storage until deinit.
    const released = try front.createQuerySet(io, &guard, .occlusion, query_count);
    {
        errdefer front.releaseQuerySet(&guard, io, released.handle) catch
            @panic("query API release rollback failed");
        try released.set.apiDestroy(&guard, io);
    }
    try std.testing.expect(!released.set.header.isAlive(&guard));
    try std.testing.expectError(error.QuerySetDestroyed, released.set.validateCanUseInSubmit(&guard));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: availability is monotonic and a query that closed on zero is written" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    // SAFETY: in-place init fills every field before success. Its rollback handles errors,
    // and try exits before any partial-owner read or deferred deinit.
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    const created = try front.createQuerySet(io, &guard, .occlusion, query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    const set = created.set;

    // The replay marks the index at the end of every occlusion query, whatever
    // the query counted (`CommandBufferVk.cpp:2141` calls the helper at
    // `CommandBuffer.cpp:394`), and nothing clears it.
    set.markQueryAvailable(&guard, covering_query);
    try std.testing.expect(set.isQueryAvailable(&guard, covering_query));
    try std.testing.expect(!set.isQueryAvailable(&guard, clipped_query));
    try std.testing.expect(!set.areAllQueriesAvailable(&guard, 0, query_count));

    set.markQueryAvailable(&guard, covering_query);
    try std.testing.expect(set.isQueryAvailable(&guard, covering_query));
    set.markQueryAvailable(&guard, clipped_query);
    try std.testing.expect(set.isQueryAvailable(&guard, clipped_query));
    try std.testing.expect(set.areAllQueriesAvailable(&guard, 0, query_count));
    try std.testing.expect(set.areAllQueriesAvailable(&guard, clipped_query, 1));
    try std.testing.expectEqual(@as(u64, 0), recorder.count);
}

test "test-query-set: two written queries resolve as one run of two at offset zero" {
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    const created = try front.createQuerySet(io, &guard, .occlusion, query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    const set = created.set;
    set.markQueryAvailable(&guard, covering_query);
    set.markQueryAvailable(&guard, clipped_query);

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
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    const created = try front.createQuerySet(io, &guard, .occlusion, query_count);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    const set = created.set;

    // Only the second index of the range was written, so the first slot holds
    // no pool value and the copy has to skip it.
    set.markQueryAvailable(&guard, clipped_query);
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
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    const created = try front.createQuerySet(io, &guard, .occlusion, 3);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    const set = created.set;
    set.markQueryAvailable(&guard, 2);

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
    const io = std.testing.io;
    var recorder: ErrorRecorder = .{};
    var front: FrontEnd = undefined;
    try front.init(io, &recorder);
    defer front.deinit(io);
    var guard = try core.ObjectGuard.lock(io, front.coreDevice().borrow().objectList());
    defer guard.unlock(io);
    front.coreDevice().bindTrackingOwner(&guard, &front.device);

    const created = try front.createQuerySet(io, &guard, .occlusion, 3);
    defer front.releaseQuerySet(&guard, io, created.handle) catch @panic("query release failed");
    const set = created.set;
    set.markQueryAvailable(&guard, 1);

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
