//! Shared utility ownership fixtures use the real device, factories, queue and shaders.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_resources;
const kernels = engine.native_kernels;
const buffer = engine.buffer;
const command = dusk.command;
const vk = dusk.platform.vulkan_bindings;
const DeviceProcs = dusk.vk.dispatch.DeviceProcs;
const t = std.testing;
const user_shader = @import("fixtures/specialization_compute.zig");
const copy_src = (api.BufferUsage{ .copy_src = true }).toFlags();
const copy_dst = (api.BufferUsage{ .copy_dst = true }).toFlags();
const scratch_usage = buffer.internal_storage_buffer | buffer.read_only_storage_buffer |
    copy_src | copy_dst;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    allocator: std.mem.Allocator,
    device_live: bool = false,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        self.threaded = .init(t.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(allocator, io) catch @panic("instance rollback failed");
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback failed");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
        self.device_live = true;
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("native utility reported an uncaptured error");
    }

    fn closeDevice(self: *Fixture) !void {
        if (!self.device_live) return;
        self.device.deinit(self.allocator, self.threaded.io()) catch |err| {
            if (err != error.DeviceLost or !self.device.host_deinitialized) return err;
        };
        self.device_live = false;
    }

    fn deinit(self: *Fixture) void {
        self.closeDevice() catch @panic("utility device teardown failed");
        const io = self.threaded.io();
        self.adapters.deinit(io) catch @panic("adapter teardown failed");
        self.instance.deinit(self.allocator, io) catch @panic("instance teardown failed");
        self.threaded.deinit();
    }

    fn release(self: *Fixture, object: anytype) void {
        self.device.release(self.allocator, self.threaded.io(), object) catch
            @panic("utility fixture alias release failed");
    }

    fn readback(self: *Fixture, size: u64) !*native.Buffer {
        return self.device.createBuffer(self.allocator, self.threaded.io(), .{
            .size = size,
            .usage = .{ .copy_dst = true, .map_read = true },
        });
    }

    fn expectWords(self: *Fixture, resource: *native.Buffer, expected: []const u32) !void {
        const io = self.threaded.io();
        try self.device.mapBuffer(io, resource, .{
            .mode = .{ .read = true },
            .offset = 0,
            .size = expected.len * 4,
        });
        defer self.device.unmapBuffer(io, resource) catch @panic("readback unmap failed");
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        const bytes = try resource.native.getConstMappedRange(0, expected.len * 4);
        for (expected, 0..) |word, index| {
            try t.expectEqual(word, std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little));
        }
    }
};

const Session = struct {
    fixture: *Fixture,
    lease: engine.Device.QueueLease,
    guard: core.ObjectGuard,
    recording: engine.recording_context.CommandRecordingContext,
    open: bool,

    fn begin(self: *Session, fixture: *Fixture) !void {
        const io = fixture.threaded.io();
        const lease = try fixture.device.getQueue(io);
        self.* = .{
            .fixture = fixture,
            .lease = lease,
            .guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList()),
            .recording = .init(fixture.allocator),
            .open = true,
        };
        errdefer self.deinit();
        const native_context = fixture.device.native.?;
        try fixture.device.bindObjectsLocked(&self.guard, fixture.allocator);
        if (native_context.recording_uses == null) {
            native_context.recording_uses = try native.PendingUses.prepareDeclaredLocked(
                fixture.allocator,
                &self.guard,
                &fixture.device.core,
                &.{},
            );
        }
        self.recording.command_buffer = self.lease.commandBuffer();
    }

    fn context(self: *Session) kernels.Context {
        std.debug.assert(self.open);
        const context_owner = self.fixture.device.native.?;
        return .{
            .io = self.fixture.threaded.io(),
            .guard = &self.guard,
            .device = &self.fixture.device.core,
            .queue = &context_owner.queue,
            .recording = &self.recording,
            .pending_uses = &context_owner.recording_uses.?,
            .cache = &context_owner.kernel_cache.?,
        };
    }

    fn scratch(self: *Session, size: u64) !kernels.BufferRange {
        return kernels.scratchBuffer(self.context(), .{
            .size = size,
            .native_usage = scratch_usage,
        });
    }

    fn nativeRecording(self: *Session) buffer.Recording {
        return .{
            .command_buffer = self.recording.command_buffer,
            .pending_serial = self.context().queue.timeline.nextSerial(),
        };
    }

    fn upload(self: *Session, destination: kernels.BufferRange, words: []const u32) !void {
        var bytes: [256]u8 = @splat(0);
        if (words.len > bytes.len / 4) return error.FixtureUploadTooLarge;
        for (words, 0..) |word, index| {
            std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
        }
        if (words.len * 4 > destination.size) return error.FixtureUploadTooLarge;
        try kernels.uploadParameters(self.context(), .{
            .owner = destination.owner,
            .offset = destination.offset,
            .size = words.len * 4,
        }, bytes[0 .. words.len * 4]);
    }

    fn sanitize(self: *Session, input: kernels.BufferRange, output: kernels.BufferRange) !void {
        var parameters: [16]u8 = @splat(0);
        const maximum = self.fixture.device.limits.v1.max_compute_workgroups_per_dimension;
        for (1..4) |index| std.mem.writeInt(u32, parameters[index * 4 ..][0..4], maximum, .little);
        try kernels.recordCompute(self.context(), .{
            .key = .{ .id = .sanitize_dispatch },
            .bindings = &.{ .{ .buffer = input }, .{ .buffer = output } },
            .parameters = &parameters,
            .workgroups = .{ 1, 1, 1 },
        });
    }

    fn copy(self: *Session, source: kernels.BufferRange, destination: *native.Buffer) !void {
        const context_value = self.context();
        try context_value.pending_uses.retainDerivedRootLocked(
            &self.guard,
            &self.fixture.device.core,
            &destination.header,
        );
        try source.owner.native.transitionUsageNow(self.nativeRecording(), copy_src, .none);
        try destination.native.transitionUsageNow(self.nativeRecording(), copy_dst, .none);
        const copy_buffer = self.fixture.device.native.?.native_device.procs.cmd_copy_buffer orelse
            return error.MissingDeviceProc;
        const region: vk.VkBufferCopy = .{
            .srcOffset = source.offset,
            .dstOffset = 0,
            .size = source.size,
        };
        copy_buffer(self.recording.command_buffer, source.owner.native.getHandle(), destination.native.getHandle(), 1, &region);
        destination.native.is_data_initialized = true;
    }

    fn submit(self: *Session) !dusk.platform.Serial {
        const io = self.fixture.threaded.io();
        const command_buffer = self.recording.command_buffer;
        self.guard.unlock(io);
        self.open = false;
        defer self.lease.deinit(io);
        const result = try self.lease.submit(self.fixture.allocator, io, .{
            .command_buffers = &.{command_buffer},
        }, &.{});
        return result.serial;
    }

    fn deinit(self: *Session) void {
        if (self.open) {
            const io = self.fixture.threaded.io();
            self.guard.unlock(io);
            self.lease.deinit(io);
            self.open = false;
        }
        self.recording.deinit();
    }
};

fn cachedPipeline(session: *Session, id: kernels.KernelId) !*native.Pipeline {
    for (session.context().cache.entries) |entry| {
        if (entry) |value| {
            if (value.key.id == id) return value.pipeline;
        }
    }
    return error.KernelWasNotCached;
}

fn expectPrivateRoots(session: *Session) !void {
    const pending = session.context().pending_uses;
    var roots = pending.roots.keyIterator();
    for (0..pending.roots.count()) |_| {
        const root = roots.next() orelse return error.PendingRootIterationMismatch;
        if (root.*.kind == .native_pipeline or root.*.kind == .bind_group) {
            try t.expectEqual(@as(u32, 0), root.*.user_reference_count);
            try t.expect(root.*.isAlive(&session.guard));
        }
    }
}

test "native kernels equal semantic requests reuse the ordinary pipeline and GPU result" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const first_readback = try f.readback(12);
    defer f.release(first_readback);
    const second_readback = try f.readback(12);
    defer f.release(second_readback);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const input = try session.scratch(12);
    const first = try session.scratch(12);
    try session.upload(input, &.{ 2, 3, 4 });
    try session.sanitize(input, first);
    const original = try cachedPipeline(&session, .sanitize_dispatch);
    const second = try session.scratch(12);
    try session.sanitize(input, second);
    try t.expect(original == try cachedPipeline(&session, .sanitize_dispatch));
    try t.expect(original.native.vk_pipeline != null);
    try t.expectEqual(@as(u32, 0), original.header.user_reference_count);
    try expectPrivateRoots(&session);
    try session.copy(first, first_readback);
    try session.copy(second, second_readback);
    const serial = try session.submit();
    try f.device.wait(f.threaded.io(), serial);
    try f.expectWords(first_readback, &.{ 2, 3, 4 });
    try f.expectWords(second_readback, &.{ 2, 3, 4 });
}

test "native kernels helper-only Device deinit consumes cache and scratch leases" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const readback = try f.readback(12);
    var readback_owned = true;
    defer if (readback_owned) f.release(readback);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const input = try session.scratch(12);
    const output = try session.scratch(12);
    try session.upload(input, &.{ 5, 1, 2 });
    try session.sanitize(input, output);
    try session.copy(output, readback);
    const serial = try session.submit();
    try f.device.wait(f.threaded.io(), serial);
    try f.expectWords(readback, &.{ 5, 1, 2 });
    f.release(readback);
    readback_owned = false;
    {
        const io = f.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(@as(u64, 0), guard.objects.user_reference_count);
        try t.expect(guard.objects.total_reference_count != 0);
    }
    try f.closeDevice();
    try t.expect(f.device.host_deinitialized);
}

test "native kernels scratch roots reject provenance mapping and overflow without mutation" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var foreign: Fixture = undefined;
    try foreign.init(t.allocator);
    defer foreign.deinit();
    const foreign_buffer = try foreign.readback(16);
    defer foreign.release(foreign_buffer);
    const mapped = try f.device.createBuffer(f.allocator, f.threaded.io(), .{
        .size = 16,
        .usage = .{ .copy_dst = true },
        .mapped_at_creation = true,
    });
    defer f.release(mapped);
    const pending_map = try f.readback(16);
    defer f.release(pending_map);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const context_value = session.context();
    const pending = context_value.pending_uses;
    try t.expectError(error.ResourceDeviceMismatch, pending.retainDerivedRootLocked(
        &session.guard,
        &f.device.core,
        &foreign_buffer.header,
    ));
    try t.expect(!pending.roots.contains(&foreign_buffer.header));
    try t.expectError(error.BufferUseWhileMapped, pending.retainDerivedRootLocked(
        &session.guard,
        &f.device.core,
        &mapped.header,
    ));
    try t.expect(!pending.roots.contains(&mapped.header));
    const generation = try pending_map.native.beginMap(.{ .mode = .{ .read = true } });
    try t.expectError(error.BufferUseWhilePendingMap, pending.retainDerivedRootLocked(
        &session.guard,
        &f.device.core,
        &pending_map.header,
    ));
    try t.expect(!pending.roots.contains(&pending_map.header));
    try t.expectEqual(buffer.Buffer.MapCompletion.mapped, try pending_map.native.completeMap(generation, 0));
    _ = try pending_map.native.unmap(.{ .command_buffer = null, .pending_serial = 0 });
    const root = try session.scratch(16);
    const references = root.owner.header.reference_count;
    const queue_uses = root.owner.queue_uses;
    const root_count = pending.roots.count();
    try pending.retainDerivedRootLocked(&session.guard, &f.device.core, &root.owner.header);
    try t.expectEqual(references, root.owner.header.reference_count);
    try t.expectEqual(queue_uses, root.owner.queue_uses);
    try t.expectEqual(root_count, pending.roots.count());
    const overflow = try native.createInternalBufferLocked(f.allocator, f.threaded.io(), &session.guard, &f.device.core.arena, f.device.native.?.resourceDevice(), .{
        .size = 16,
        .native_usage = scratch_usage,
    });
    defer overflow.header.releaseUserLocked(&session.guard, f.threaded.io()) catch
        @panic("overflow fixture alias release failed");
    const actual_references = overflow.header.reference_count;
    {
        overflow.header.reference_count = std.math.maxInt(u32);
        defer overflow.header.reference_count = actual_references;
        try t.expectError(error.ReferenceCountOverflow, pending.retainDerivedRootLocked(
            &session.guard,
            &f.device.core,
            &overflow.header,
        ));
        try t.expect(!pending.roots.contains(&overflow.header));
    }
    {
        const aggregate = pending.objects.total_reference_count;
        pending.objects.total_reference_count = std.math.maxInt(u64);
        defer pending.objects.total_reference_count = aggregate;
        try t.expectError(error.ReferenceCountOverflow, pending.retainDerivedRootLocked(
            &session.guard,
            &f.device.core,
            &overflow.header,
        ));
        try t.expect(!pending.roots.contains(&overflow.header));
    }
    try pending.retainDerivedRootLocked(&session.guard, &f.device.core, &overflow.header);
    try t.expectEqual(actual_references + 1, overflow.header.reference_count);
    try t.expectEqual(@as(u32, 1), overflow.queue_uses);
}

test "native kernels reject malformed bindings parameters ranges dispatch and active passes" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const readback = try f.readback(12);
    defer f.release(readback);
    const sampler = try f.device.createSampler(f.allocator, f.threaded.io(), .{
        .compare = .undefined_,
    });
    defer f.release(sampler);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const input = try session.scratch(12);
    const output = try session.scratch(12);
    const parameters: [16]u8 = @splat(0);
    const compute: kernels.Compute = .{
        .key = .{ .id = .sanitize_dispatch },
        .bindings = &.{ .{ .buffer = input }, .{ .buffer = output } },
        .parameters = &parameters,
        .workgroups = .{ 1, 1, 1 },
    };
    var invalid = compute;
    invalid.bindings = &.{};
    try t.expectError(error.KernelBindingCountMismatch, kernels.recordCompute(session.context(), invalid));
    invalid = compute;
    invalid.parameters = parameters[0..12];
    try t.expectError(error.KernelParameterSizeMismatch, kernels.recordCompute(session.context(), invalid));
    invalid = compute;
    invalid.bindings = &.{ .{ .sampler = sampler }, .{ .buffer = output } };
    try t.expectError(error.KernelBindingTypeMismatch, kernels.recordCompute(session.context(), invalid));
    invalid = compute;
    invalid.key.color_write_slots = 1;
    try t.expectError(error.InvalidKernelKey, kernels.recordCompute(session.context(), invalid));
    invalid = compute;
    invalid.bindings = &.{ .{ .buffer = .{
        .owner = input.owner,
        .offset = std.math.maxInt(u64),
        .size = 12,
    } }, .{ .buffer = output } };
    try t.expectError(error.BindingRangeOutsideBuffer, kernels.recordCompute(session.context(), invalid));
    invalid = compute;
    invalid.workgroups[0] = f.device.limits.v1.max_compute_workgroups_per_dimension + 1;
    try t.expectError(error.KernelDispatchLimitExceeded, kernels.recordCompute(session.context(), invalid));
    var pass_query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    pass_query.setSampleCount(1);
    pass_query.setColor(.{
        .index = 0,
        .format = .rgba8_unorm,
        .load_op = .load,
        .store_op = .store,
        .has_resolve_target = false,
        .render_to_single_sampled = false,
    });
    const pass = try f.device.native.?.render_pass_cache.getRenderPass(
        f.threaded.io(),
        pass_query,
    );
    session.recording.active_render_pass = pass.render_pass;
    {
        defer session.recording.active_render_pass = null;
        try t.expectError(error.KernelRequiresOutsideRenderPass, kernels.recordCompute(session.context(), compute));
    }
    try t.expect(!f.device.native.?.queue.recording_poisoned);
    try t.expectEqual(@as(u32, 0), output.owner.header.user_reference_count);
    try session.upload(input, &.{ 1, 2, 3 });
    try session.sanitize(input, output);
    try session.copy(output, readback);
    const serial = try session.submit();
    try f.device.wait(f.threaded.io(), serial);
    try f.expectWords(readback, &.{ 1, 2, 3 });
}

test "native kernels internal usage permits Indirect reads without public Storage permission" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const input = try f.device.createBuffer(f.allocator, io, .{
        .size = 12,
        .usage = .{ .indirect = true, .copy_dst = true, .copy_src = true },
    });
    defer f.release(input);
    const readback = try f.readback(12);
    defer f.release(readback);
    const public_group = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &.{.{
            .binding_number = 0,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .read_only_storage,
                .has_dynamic_offset = false,
                .min_binding_size = 12,
            } },
        }},
    });
    defer f.release(public_group);
    const public_layout = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{public_group},
    });
    defer f.release(public_layout);
    try t.expectError(error.BindingUsageInvalid, f.device.createBindGroup(f.allocator, io, .{
        .layout = public_layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 0,
            .buffer = input,
            .offset = 0,
            .size = 12,
            .kind = .read_only_storage,
            .stages = .{ .compute = true },
        } }},
    }));
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    try t.expect(!input.native.usage.storage);
    try t.expect(input.native.internal_usage & buffer.read_only_storage_buffer != 0);
    try session.context().pending_uses.retainDerivedRootLocked(&session.guard, &f.device.core, &input.header);
    const input_range: kernels.BufferRange = .{ .owner = input, .offset = 0, .size = 12 };
    const output = try session.scratch(12);
    try t.expectEqual(@as(u32, 0), output.owner.native.usage.toFlags());
    try t.expect(output.owner.native.internal_usage & buffer.internal_storage_buffer != 0);
    try session.upload(input_range, &.{ 3, 2, 1 });
    try session.sanitize(input_range, output);
    try session.copy(output, readback);
    const serial = try session.submit();
    try f.device.wait(io, serial);
    try f.expectWords(readback, &.{ 3, 2, 1 });
}

const ClearPipeline = struct {
    prepared: kernels.PreparedDraw,
    attachment: *command.attachment_state.CanonicalAttachmentState,
};

fn prepareClear(session: *Session, variant: u32, samples: u32) !ClearPipeline {
    const formats = [_]api.TextureFormat{
        .rgba8_unorm, .bgra8_unorm, .rgba16_float, .r32_float,
    };
    var colors: [4]u32 = .{ @backingInt(api.TextureFormat.rgba8_unorm), 0, 0, 0 };
    var pass_query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    pass_query.setSampleCount(samples);
    for (&colors, 0..) |*color, index| {
        const selected = if (index == 0) api.TextureFormat.rgba8_unorm else formats[(variant >> @intCast((index - 1) * 2)) & 3];
        color.* = @backingInt(selected);
        pass_query.setColor(.{
            .index = @intCast(index),
            .format = selected,
            .load_op = .load,
            .store_op = .store,
            .has_resolve_target = false,
            .render_to_single_sampled = false,
        });
    }
    const f = session.fixture;
    const value = try command.attachment_state.AttachmentState.fromRenderPipeline(.{
        .color_formats = &colors,
        .depth_stencil_format = 0,
        .sample_count = samples,
        .expand_resolve = .{},
        .pls = null,
    }, .{
        .max_color_attachments = f.device.limits.v1.max_color_attachments,
        .max_storage_attachments = command.constants.max_pls_slots,
        .max_pls_bytes = command.constants.max_pls_size,
    });
    const attachment = try engine.native_attachment_store.create(
        f.allocator,
        f.threaded.io(),
        &session.guard,
        &f.device.core.arena,
        &f.device.native.?.resource_store.?,
        value,
    );
    defer attachment.header.releaseUserLocked(&session.guard, f.threaded.io()) catch
        @panic("clear attachment alias release failed");
    const pass = try f.device.native.?.render_pass_cache.getRenderPass(
        f.threaded.io(),
        pass_query,
    );
    const parameters: [128]u8 = @splat(0);
    return .{
        .attachment = attachment,
        .prepared = try kernels.prepareDraw(session.context(), .{
            .key = .{ .id = .clear_color, .attachments = attachment, .color_write_slots = 1 },
            .bindings = &.{},
            .parameters = &parameters,
            .compatible_render_pass = pass.render_pass,
        }),
    };
}

test "native kernels real attachment format and sample keys do not collide" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const original = try prepareClear(&session, 0, 1);
    const alias = try prepareClear(&session, 0, 1);
    try t.expect(original.attachment == alias.attachment);
    try t.expect(original.prepared.pipeline == alias.prepared.pipeline);
    const format_variant = try prepareClear(&session, 1, 1);
    try t.expect(original.attachment != format_variant.attachment);
    try t.expect(original.prepared.pipeline != format_variant.prepared.pipeline);
    const sample_variant = try prepareClear(&session, 0, 4);
    try t.expect(original.attachment != sample_variant.attachment);
    try t.expect(original.prepared.pipeline != sample_variant.prepared.pipeline);
    try t.expectEqual(@as(u32, 0), original.attachment.header.user_reference_count);
    try t.expect(original.attachment.header.isAlive(&session.guard));
    const serial = try session.submit();
    try f.device.wait(f.threaded.io(), serial);
}

test "native kernels FIFO eviction preserves an accepted pending pipeline until completion" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const readback = try f.readback(12);
    defer f.release(readback);
    var first: Session = undefined;
    try first.begin(&f);
    defer first.deinit();
    const input = try first.scratch(12);
    const output = try first.scratch(12);
    try first.upload(input, &.{ 7, 8, 9 });
    try first.sanitize(input, output);
    const original = try cachedPipeline(&first, .sanitize_dispatch);
    const original_layout = original.layout;
    const original_shader = original.shaders[0];
    try first.copy(output, readback);
    const accepted = try first.submit();
    var eviction: Session = undefined;
    try eviction.begin(&f);
    defer eviction.deinit();
    for (0..kernels.KernelCache.capacity + 1) |variant| {
        const prepared = try prepareClear(&eviction, @intCast(variant), 1);
        try t.expect(prepared.prepared.pipeline.header.isAlive(&eviction.guard));
    }
    for (eviction.context().cache.entries) |entry| {
        if (entry) |value| try t.expect(value.pipeline != original);
    }
    try t.expect(original.header.isAlive(&eviction.guard));
    try t.expect(original_layout.header.isAlive(&eviction.guard));
    try t.expect(original_shader.header.isAlive(&eviction.guard));
    try t.expect(f.device.native.?.pending_recording_uses.?.roots.contains(&original.header));
    try t.expectEqual(@as(?dusk.platform.Serial, accepted), f.device.native.?.pending_uses_serial);
    const next = try eviction.submit();
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(core.ObjectState.destroyed, original.header.state);
        try t.expectEqual(@as(u32, 0), original.header.reference_count);
        try t.expectEqual(core.ObjectState.destroyed, original_layout.header.state);
        try t.expectEqual(core.ObjectState.destroyed, original_shader.header.state);
    }
    try f.device.wait(io, next);
    try f.expectWords(readback, &.{ 7, 8, 9 });
}

const HandleKind = enum { buffer, memory, shader, group_layout, layout, pipeline, pool };
const CreationFault = enum {
    buffer,
    memory,
    shader,
    group_layout,
    layout,
    pipeline,
    pool,
    descriptor_set,
};
var installed_driver_probe: ?*DriverProbe = null;

// The probe wraps the real dispatch table in place. Successful calls reach the driver.
const DriverProbe = struct {
    original: DeviceProcs,
    table: *DeviceProcs,
    original_backend: dusk.pipeline.pipeline.Backend,
    backend: *dusk.pipeline.pipeline.Backend,
    device: vk.VkDevice,
    live: [7][256]u64 = @splat(@splat(0)),
    rejected_kind: ?CreationFault = null,
    rejection_seen: bool = false,
    update_calls: usize = 0,
    submit_result: vk.VkResult = vk.VK_SUCCESS,
    wait_result: vk.VkResult = vk.VK_SUCCESS,
    idle_result: vk.VkResult = vk.VK_SUCCESS,

    fn attach(self: *DriverProbe, f: *Fixture) void {
        std.debug.assert(installed_driver_probe == null);
        const device = &f.device.native.?.native_device;
        const backend = &f.device.native.?.pipeline_backend;
        self.* = .{
            .original = device.procs.*,
            .table = device.procs,
            .original_backend = backend.*,
            .backend = backend,
            .device = device.vk_device,
        };
        installed_driver_probe = self;
        self.table.create_buffer = createBuffer;
        self.table.destroy_buffer = destroyBuffer;
        self.table.allocate_memory = allocateMemory;
        self.table.free_memory = freeMemory;
        self.table.create_shader_module = createShader;
        self.table.destroy_shader_module = destroyShader;
        self.table.create_descriptor_set_layout = createGroupLayout;
        self.table.destroy_descriptor_set_layout = destroyGroupLayout;
        self.table.create_pipeline_layout = createLayout;
        self.table.destroy_pipeline_layout = destroyLayout;
        self.table.create_compute_pipelines = createCompute;
        self.table.destroy_pipeline = destroyPipeline;
        self.backend.create_compute_pipelines = createCompute;
        self.backend.destroy_pipeline = destroyPipeline;
        self.table.create_descriptor_pool = createPool;
        self.table.destroy_descriptor_pool = destroyPool;
        self.table.allocate_descriptor_sets = allocateDescriptorSets;
        self.table.queue_submit = submit;
        self.table.wait_for_fences = wait;
        self.table.device_wait_idle = idle;
        self.table.cmd_update_buffer = updateParameters;
    }

    fn detach(self: *DriverProbe, f: *Fixture) void {
        if (f.device_live) {
            self.table.* = self.original;
            self.backend.* = self.original_backend;
        }
        std.debug.assert(installed_driver_probe == self);
        installed_driver_probe = null;
    }

    fn get(device: vk.VkDevice) *DriverProbe {
        const self = installed_driver_probe orelse @panic("missing utility driver probe");
        std.debug.assert(self.device == device);
        return self;
    }

    fn bits(handle: anytype) u64 {
        return switch (@typeInfo(@TypeOf(handle))) {
            .pointer, .optional => @intFromPtr(handle),
            .int => @intCast(handle),
            else => @compileError("unexpected Vulkan handle type"),
        };
    }

    fn created(self: *DriverProbe, kind: HandleKind, handle: anytype) void {
        const value = bits(handle);
        std.debug.assert(value != 0);
        const bucket = &self.live[@backingInt(kind)];
        for (bucket) |*slot| {
            if (slot.* == 0) {
                slot.* = value;
                return;
            }
        }
        @panic("utility native handle probe exhausted");
    }

    fn destroyed(self: *DriverProbe, kind: HandleKind, handle: anytype) void {
        const value = bits(handle);
        if (value == 0) return;
        for (&self.live[@backingInt(kind)]) |*slot| {
            if (slot.* == value) {
                slot.* = 0;
                return;
            }
        }
        @panic("utility destroyed an unowned or already destroyed native handle");
    }

    fn reject(self: *DriverProbe, kind: CreationFault) bool {
        if (self.rejected_kind != kind) return false;
        self.rejection_seen = true;
        return true;
    }

    fn expectEmpty(self: *const DriverProbe) !void {
        for (self.live) |bucket| for (bucket) |handle| try t.expectEqual(@as(u64, 0), handle);
    }

    fn createBuffer(device: vk.VkDevice, info: [*c]const vk.VkBufferCreateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkBuffer) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.buffer)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.create_buffer.?(device, info, callbacks, output);
        if (result == vk.VK_SUCCESS) self.created(.buffer, output[0]);
        return result;
    }

    fn destroyBuffer(device: vk.VkDevice, handle: vk.VkBuffer, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.buffer, handle);
        self.original.destroy_buffer.?(device, handle, callbacks);
    }

    fn allocateMemory(device: vk.VkDevice, info: [*c]const vk.VkMemoryAllocateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkDeviceMemory) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.memory)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.allocate_memory.?(device, info, callbacks, output);
        if (result == vk.VK_SUCCESS) self.created(.memory, output[0]);
        return result;
    }

    fn freeMemory(device: vk.VkDevice, handle: vk.VkDeviceMemory, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.memory, handle);
        self.original.free_memory.?(device, handle, callbacks);
    }

    fn createShader(device: vk.VkDevice, info: [*c]const vk.VkShaderModuleCreateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkShaderModule) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.shader)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.create_shader_module.?(device, info, callbacks, output);
        if (result == vk.VK_SUCCESS) self.created(.shader, output[0]);
        return result;
    }

    fn destroyShader(device: vk.VkDevice, handle: vk.VkShaderModule, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.shader, handle);
        self.original.destroy_shader_module.?(device, handle, callbacks);
    }

    fn createGroupLayout(device: vk.VkDevice, info: [*c]const vk.VkDescriptorSetLayoutCreateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkDescriptorSetLayout) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.group_layout)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.create_descriptor_set_layout.?(device, info, callbacks, output);
        if (result == vk.VK_SUCCESS) self.created(.group_layout, output[0]);
        return result;
    }

    fn destroyGroupLayout(device: vk.VkDevice, handle: vk.VkDescriptorSetLayout, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.group_layout, handle);
        self.original.destroy_descriptor_set_layout.?(device, handle, callbacks);
    }

    fn createLayout(device: vk.VkDevice, info: [*c]const vk.VkPipelineLayoutCreateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkPipelineLayout) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.layout)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.create_pipeline_layout.?(device, info, callbacks, output);
        if (result == vk.VK_SUCCESS) self.created(.layout, output[0]);
        return result;
    }

    fn destroyLayout(device: vk.VkDevice, handle: vk.VkPipelineLayout, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.layout, handle);
        self.original.destroy_pipeline_layout.?(device, handle, callbacks);
    }

    fn createCompute(device: vk.VkDevice, cache: vk.VkPipelineCache, count: u32, info: [*c]const vk.VkComputePipelineCreateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkPipeline) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.pipeline)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.create_compute_pipelines.?(device, cache, count, info, callbacks, output);
        for (0..count) |index| {
            if (output[index] != null) self.created(.pipeline, output[index]);
        }
        return result;
    }

    fn destroyPipeline(device: vk.VkDevice, handle: vk.VkPipeline, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.pipeline, handle);
        self.original.destroy_pipeline.?(device, handle, callbacks);
    }

    fn createPool(device: vk.VkDevice, info: [*c]const vk.VkDescriptorPoolCreateInfo, callbacks: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkDescriptorPool) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.pool)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        const result = self.original.create_descriptor_pool.?(device, info, callbacks, output);
        if (result == vk.VK_SUCCESS) self.created(.pool, output[0]);
        return result;
    }

    fn destroyPool(device: vk.VkDevice, handle: vk.VkDescriptorPool, callbacks: [*c]const vk.VkAllocationCallbacks) callconv(.c) void {
        const self = get(device);
        self.destroyed(.pool, handle);
        self.original.destroy_descriptor_pool.?(device, handle, callbacks);
    }

    fn allocateDescriptorSets(device: vk.VkDevice, info: [*c]const vk.VkDescriptorSetAllocateInfo, output: [*c]vk.VkDescriptorSet) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.reject(.descriptor_set)) return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        return self.original.allocate_descriptor_sets.?(device, info, output);
    }

    fn updateParameters(command_buffer: vk.VkCommandBuffer, destination: vk.VkBuffer, offset: vk.VkDeviceSize, size: vk.VkDeviceSize, data: ?*const anyopaque) callconv(.c) void {
        const self = installed_driver_probe orelse @panic("missing upload probe");
        self.update_calls += 1;
        self.original.cmd_update_buffer.?(command_buffer, destination, offset, size, data);
    }

    fn submit(queue: vk.VkQueue, count: u32, info: [*c]const vk.VkSubmitInfo, fence: vk.VkFence) callconv(.c) vk.VkResult {
        const self = installed_driver_probe orelse @panic("missing submit probe");
        if (self.submit_result != vk.VK_SUCCESS) return self.submit_result;
        return self.original.queue_submit.?(queue, count, info, fence);
    }

    fn wait(device: vk.VkDevice, count: u32, fences: [*c]const vk.VkFence, wait_all: vk.VkBool32, timeout_ns: u64) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.wait_result != vk.VK_SUCCESS) return self.wait_result;
        return self.original.wait_for_fences.?(device, count, fences, wait_all, timeout_ns);
    }

    fn idle(device: vk.VkDevice) callconv(.c) vk.VkResult {
        const self = get(device);
        if (self.idle_result != vk.VK_SUCCESS) return self.idle_result;
        return self.original.device_wait_idle.?(device);
    }
};

fn assertOnlyReadbackAlias(session: *Session) !void {
    try t.expectEqual(@as(u64, 1), session.guard.objects.user_reference_count);
    var current = session.guard.objects.head;
    for (0..session.guard.objects.tracked_count) |_| {
        const header = current orelse return error.ObjectListShorterThanTrackedCount;
        current = header.node.next;
        if (header.kind != .native_buffer) try t.expectEqual(@as(u32, 0), header.user_reference_count);
    }
    try t.expect(current == null);
}

test "native kernels fail N construction and recording leave no private aliases or native leaks" {
    const allocation_limit = 512;
    var saw_failure = false;
    var reached_success = false;
    for (0..allocation_limit) |offset| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var f: Fixture = undefined;
        try f.init(failing.allocator());
        defer f.deinit();
        var probe: DriverProbe = undefined;
        probe.attach(&f);
        defer probe.detach(&f);
        const readback = try f.readback(12);
        var readback_owned = true;
        defer if (readback_owned) f.release(readback);
        failing.fail_index = failing.alloc_index + offset;
        const result = recordFailureExercise(&f, readback);
        failing.fail_index = std.math.maxInt(usize);
        if (result) |serial| {
            reached_success = true;
            try f.device.wait(f.threaded.io(), serial);
            try f.expectWords(readback, &.{ 1, 2, 3 });
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
        }
        {
            var session: Session = undefined;
            try session.begin(&f);
            defer session.deinit();
            try assertOnlyReadbackAlias(&session);
        }
        f.release(readback);
        readback_owned = false;
        try f.closeDevice();
        try probe.expectEmpty();
        if (reached_success) break;
    }
    try t.expect(saw_failure);
    try t.expect(reached_success);
}

fn recordFailureExercise(f: *Fixture, readback: *native.Buffer) !dusk.platform.Serial {
    var session: Session = undefined;
    try session.begin(f);
    defer session.deinit();
    const input = try session.scratch(12);
    const output = try session.scratch(12);
    try session.upload(input, &.{ 1, 2, 3 });
    try session.sanitize(input, output);
    try session.copy(output, readback);
    return session.submit();
}

test "native kernels driver creation refusals unwind initialized handles and actual aliases" {
    inline for (std.meta.tags(CreationFault)) |kind| {
        var f: Fixture = undefined;
        try f.init(t.allocator);
        defer f.deinit();
        var probe: DriverProbe = undefined;
        probe.attach(&f);
        defer probe.detach(&f);
        const readback = try f.readback(12);
        var readback_owned = true;
        defer if (readback_owned) f.release(readback);
        {
            probe.rejected_kind = kind;
            defer probe.rejected_kind = null;
            try t.expectError(error.OutOfHostMemory, recordFailureExercise(&f, readback));
            try t.expect(probe.rejection_seen);
        }
        {
            var session: Session = undefined;
            try session.begin(&f);
            defer session.deinit();
            try assertOnlyReadbackAlias(&session);
            try t.expectEqual(@as(dusk.platform.Serial, 0), f.device.native.?.queue.timeline.lastSubmittedSerial());
            if (f.device.native.?.recording_uses) |*pending| {
                var roots = pending.roots.keyIterator();
                for (0..pending.roots.count()) |_| {
                    const root = roots.next() orelse return error.PendingRootIterationMismatch;
                    if (root.*.kind == .native_buffer) {
                        const owner: *native.Buffer = @fieldParentPtr("header", root.*);
                        try t.expectEqual(@as(dusk.platform.Serial, 0), owner.accepted_usage_serial);
                    }
                }
            }
        }
        f.release(readback);
        readback_owned = false;
        try f.closeDevice();
        try probe.expectEmpty();
    }
}

test "native kernels scratch is stamped only with an accepted serial and failed submit stays poisoned" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var probe: DriverProbe = undefined;
    probe.attach(&f);
    defer probe.detach(&f);
    const readback = try f.readback(12);
    var readback_owned = true;
    defer if (readback_owned) f.release(readback);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const input = try session.scratch(12);
    const output = try session.scratch(12);
    try session.upload(input, &.{ 4, 5, 6 });
    try session.sanitize(input, output);
    try session.copy(output, readback);
    try t.expectEqual(@as(dusk.platform.Serial, 0), output.owner.accepted_usage_serial);
    probe.submit_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    try t.expectError(error.OutOfHostMemory, session.submit());
    probe.submit_result = vk.VK_SUCCESS;
    {
        var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
        defer guard.unlock(f.threaded.io());
        try t.expectEqual(@as(dusk.platform.Serial, 0), output.owner.accepted_usage_serial);
        try t.expectEqual(@as(dusk.platform.Serial, 0), readback.accepted_usage_serial);
        try t.expectEqual(@as(dusk.platform.Serial, 0), f.device.native.?.queue.timeline.lastSubmittedSerial());
        try t.expect(f.device.native.?.queue.recording_poisoned);
        try t.expectEqual(@as(?dusk.platform.Serial, null), f.device.native.?.pending_uses_serial);
    }
    {
        var lease = try f.device.getQueue(f.threaded.io());
        defer lease.deinit(f.threaded.io());
        try t.expectError(error.RecordingPoisoned, lease.submit(f.allocator, f.threaded.io(), .{ .command_buffers = &.{lease.commandBuffer()} }, &.{}));
    }
    f.release(readback);
    readback_owned = false;
    try f.closeDevice();
    try probe.expectEmpty();
}

test "native kernels nonterminal completion failure retains real payloads and accepted serial" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var probe: DriverProbe = undefined;
    probe.attach(&f);
    defer probe.detach(&f);
    const readback = try f.readback(12);
    var readback_owned = true;
    defer if (readback_owned) f.release(readback);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const input = try session.scratch(12);
    const output = try session.scratch(12);
    try session.upload(input, &.{ 9, 8, 7 });
    try session.sanitize(input, output);
    const pipeline = try cachedPipeline(&session, .sanitize_dispatch);
    try session.copy(output, readback);
    const serial = try session.submit();
    probe.wait_result = vk.VK_TIMEOUT;
    probe.idle_result = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
    defer {
        probe.wait_result = vk.VK_SUCCESS;
        probe.idle_result = vk.VK_SUCCESS;
    }
    try t.expectError(error.FenceWaitTimedOut, f.device.wait(f.threaded.io(), serial));
    {
        var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
        defer guard.unlock(f.threaded.io());
        try t.expect(output.owner.header.isAlive(&guard));
        try t.expect(pipeline.header.isAlive(&guard));
        try t.expectEqual(serial, output.owner.accepted_usage_serial);
        try t.expectEqual(@as(?dusk.platform.Serial, serial), f.device.native.?.pending_uses_serial);
        try t.expect(!f.device.native.?.gpu_completion_established);
        try t.expect(output.owner.native.getHandle() != null);
    }
    probe.wait_result = vk.VK_SUCCESS;
    probe.idle_result = vk.VK_SUCCESS;
    try f.device.wait(f.threaded.io(), serial);
    try f.expectWords(readback, &.{ 9, 8, 7 });
    {
        var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
        defer guard.unlock(f.threaded.io());
        try t.expectEqual(core.ObjectState.destroyed, output.owner.header.state);
    }
    f.release(readback);
    readback_owned = false;
    try f.closeDevice();
    try probe.expectEmpty();
}

test "native kernels terminal completion loss cleans retained payloads without valid output" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var probe: DriverProbe = undefined;
    probe.attach(&f);
    defer probe.detach(&f);
    const readback = try f.readback(12);
    var readback_owned = true;
    defer if (readback_owned) f.release(readback);
    const serial = try recordFailureExercise(&f, readback);
    // Quiesce the real GPU before the injected terminal-loss response.
    // Do not advance the engine timeline or publish readback as successful.
    try dusk.vk.dispatch.checkVkSuccess(probe.original.device_wait_idle.?(probe.device));
    probe.wait_result = vk.VK_ERROR_DEVICE_LOST;
    probe.idle_result = vk.VK_ERROR_DEVICE_LOST;
    try t.expectError(error.DeviceLost, f.device.wait(f.threaded.io(), serial));
    try t.expect(f.device.native.?.terminal_loss);
    try t.expect(f.device.native.?.queue.timeline.completed < serial);
    f.release(readback);
    readback_owned = false;
    try f.closeDevice();
    try probe.expectEmpty();
}

test "native kernels derived scratch OOM leaves no root and preserves earlier append" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var f: Fixture = undefined;
    try f.init(failing.allocator());
    defer f.deinit();
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const io = f.threaded.io();
    const owner = try native.createInternalBufferLocked(f.allocator, io, &session.guard, &f.device.core.arena, f.device.native.?.resourceDevice(), .{
        .size = 12,
        .native_usage = scratch_usage,
    });
    defer owner.header.releaseUserLocked(&session.guard, io) catch
        @panic("scratch refusal alias release failed");
    const pending = session.context().pending_uses;
    const references = owner.header.reference_count;
    const aggregate = pending.objects.total_reference_count;
    {
        failing.fail_index = failing.alloc_index;
        defer failing.fail_index = std.math.maxInt(usize);
        try t.expectError(error.OutOfMemory, pending.retainDerivedRootLocked(
            &session.guard,
            &f.device.core,
            &owner.header,
        ));
    }
    try t.expect(!pending.roots.contains(&owner.header));
    try t.expectEqual(references, owner.header.reference_count);
    try t.expectEqual(aggregate, pending.objects.total_reference_count);
    try t.expectEqual(@as(u32, 0), owner.queue_uses);
    try pending.retainDerivedRootLocked(&session.guard, &f.device.core, &owner.header);
    try t.expect(owner.header.isAlive(&session.guard));
    try t.expectEqual(references + 1, owner.header.reference_count);
    const retained_count = pending.roots.count();
    const scratch = try session.scratch(12);
    try t.expect(pending.roots.contains(&owner.header));
    try t.expect(pending.roots.contains(&scratch.owner.header));
    try t.expectEqual(retained_count + 1, pending.roots.count());
    try t.expectEqual(@as(u32, 0), scratch.owner.header.user_reference_count);
}

test "native kernels accepted scratch has one serial owner and no raw temporary registration" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const readback = try f.readback(12);
    defer f.release(readback);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const input = try session.scratch(12);
    const output = try session.scratch(12);
    try session.upload(input, &.{ 6, 5, 4 });
    try session.sanitize(input, output);
    try session.copy(output, readback);
    try t.expectEqual(@as(dusk.platform.Serial, 0), output.owner.accepted_usage_serial);
    for (session.context().queue.temporary_buffers.items) |temporary| {
        try t.expect(temporary.buffer != output.owner.native);
        try t.expect(temporary.buffer != input.owner.native);
    }
    const serial = try session.submit();
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(serial, output.owner.accepted_usage_serial);
        try t.expectEqual(serial, input.owner.accepted_usage_serial);
        try t.expectEqual(serial, readback.accepted_usage_serial);
        try t.expectEqual(@as(?dusk.platform.Serial, serial), f.device.native.?.pending_uses_serial);
        try t.expect(f.device.native.?.pending_recording_uses.?.roots.contains(&output.owner.header));
        try t.expect(output.owner.header.isAlive(&guard));
    }
    try f.device.wait(io, serial);
    try f.expectWords(readback, &.{ 6, 5, 4 });
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(core.ObjectState.destroyed, output.owner.header.state);
        try t.expectEqual(@as(u32, 0), output.owner.queue_uses);
        try t.expectEqual(@as(?dusk.platform.Serial, null), f.device.native.?.pending_uses_serial);
    }
}

test "native kernels helper dispatch restores an unchanged user pipeline and bind group on GPU" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const output = try f.device.createBuffer(f.allocator, io, .{
        .size = 4,
        .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
    });
    defer f.release(output);
    const readback = try f.readback(4);
    defer f.release(readback);
    const arguments = try f.device.createBuffer(f.allocator, io, .{
        .size = 12,
        .usage = .{ .indirect = true, .copy_dst = true, .copy_src = true },
    });
    defer f.release(arguments);
    const argument_readback = try f.readback(12);
    defer f.release(argument_readback);
    const group_layout = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &.{.{
            .binding_number = 0,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = 4,
            } },
        }},
    });
    defer f.release(group_layout);
    const layout = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{group_layout},
    });
    defer f.release(layout);
    const words_before = user_shader.words;
    const shader = try f.device.createShaderModule(f.allocator, io, .{
        .words = &user_shader.words,
    });
    defer f.release(shader);
    const pipeline = try f.device.createComputePipeline(f.allocator, io, .{
        .layout = layout,
        .compute = .{ .module = shader, .entry_point = user_shader.entry_point, .stage = .compute },
    });
    defer f.release(pipeline);
    const group = try f.device.createBindGroup(f.allocator, io, .{
        .layout = layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 0,
            .buffer = output,
            .offset = 0,
            .size = 4,
            .kind = .storage,
            .stages = .{ .compute = true },
        } }},
    });
    defer f.release(group);
    var encoder = command.command_encoder.CommandEncoder.init(f.allocator, f.device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(f.allocator, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const argument_words = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &argument_words });
        try encoder.writeBuffer(.{ .buffer = try output.ref(&guard), .data = &.{ 0, 0, 0, 0 } });
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{
            .pipeline = try pipeline.ref(&guard),
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
                .usage = (api.BufferUsage{ .storage = true }).toFlags(),
            }},
        });
        // This binds caller state without producing the expected output.
        // The helper must restore that unchanged state before its indirect consumer.
        try pass.dispatch(.{ .x = 0, .y = 1, .z = 1 });
        try pass.dispatchIndirect(.{
            .buffer = try arguments.ref(&guard),
            .buffer_size = arguments.native.size,
            .usage = arguments.native.usage.toFlags(),
        });
        try pass.end();
        try encoder.copyBufferToBuffer(.{
            .source = try output.ref(&guard),
            .destination = try readback.ref(&guard),
            .size = 4,
        });
        try encoder.copyBufferToBuffer(.{
            .source = try arguments.ref(&guard),
            .destination = try argument_readback.ref(&guard),
            .size = 12,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(f.allocator, io, &guard);
    }
    const serial = try f.device.submit(f.allocator, io, &finished);
    try f.device.wait(io, serial);
    try f.expectWords(readback, &.{user_shader.default_output});
    try f.expectWords(argument_readback, &.{ 1, 1, 1 });
    try t.expectEqualSlices(u32, &words_before, &user_shader.words);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        var found_helper = false;
        for (f.device.native.?.kernel_cache.?.entries) |entry| {
            if (entry) |value| {
                if (value.key.id == .sanitize_dispatch) found_helper = true;
            }
        }
        try t.expect(found_helper);
    }
}

test "native kernels scratch refuses invalid usage size and reference saturation before publication" {
    var allocations = t.FailingAllocator.init(t.allocator, .{});
    var f: Fixture = undefined;
    try f.init(allocations.allocator());
    defer f.deinit();
    var probe: DriverProbe = undefined;
    probe.attach(&f);
    defer probe.detach(&f);
    var session: Session = undefined;
    try session.begin(&f);
    var session_live = true;
    defer if (session_live) session.deinit();
    const context_value = session.context();
    const before_users = session.guard.objects.user_reference_count;
    try t.expectError(error.InternalBufferUsageInvalid, kernels.scratchBuffer(context_value, .{
        .size = 16,
        .native_usage = (api.BufferUsage{ .map_read = true }).toFlags(),
    }));
    try t.expectError(error.BufferSizeAboveLimit, kernels.scratchBuffer(context_value, .{
        .size = std.math.maxInt(u64),
        .native_usage = scratch_usage,
    }));
    try t.expectEqual(before_users, session.guard.objects.user_reference_count);
    try t.expectEqual(@as(u32, 0), context_value.pending_uses.roots.count());
    const allocation_count = allocations.alloc_index;
    {
        const total = session.guard.objects.total_reference_count;
        session.guard.objects.total_reference_count = std.math.maxInt(u64);
        defer session.guard.objects.total_reference_count = total;
        try t.expectError(error.ReferenceCountOverflow, session.scratch(16));
    }
    try t.expectEqual(allocation_count, allocations.alloc_index);
    {
        const users = session.guard.objects.user_reference_count;
        session.guard.objects.user_reference_count = std.math.maxInt(u64);
        defer session.guard.objects.user_reference_count = users;
        try t.expectError(error.ReferenceCountOverflow, session.scratch(16));
    }
    try t.expectEqual(allocation_count, allocations.alloc_index);
    try t.expectEqual(@as(u32, 0), context_value.pending_uses.roots.count());
    try probe.expectEmpty();
    const valid = try session.scratch(16);
    try t.expectEqual(@as(u32, 0), valid.owner.header.user_reference_count);
    try t.expect(valid.owner.header.isAlive(&session.guard));
    session.deinit();
    session_live = false;
    try f.closeDevice();
    try probe.expectEmpty();
}

test "native kernels stencil write bits select distinct actual fixed-mask pipelines" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const io = f.threaded.io();
    const value = try command.attachment_state.AttachmentState.fromRenderPipeline(.{
        .color_formats = &.{},
        .depth_stencil_format = @backingInt(api.TextureFormat.depth24_plus_stencil8),
        .sample_count = 1,
        .expand_resolve = .{},
        .pls = null,
    }, .{
        .max_color_attachments = f.device.limits.v1.max_color_attachments,
        .max_storage_attachments = command.constants.max_pls_slots,
        .max_pls_bytes = command.constants.max_pls_size,
    });
    const attachment = try engine.native_attachment_store.create(
        f.allocator,
        io,
        &session.guard,
        &f.device.core.arena,
        &f.device.native.?.resource_store.?,
        value,
    );
    var attachment_owned = true;
    defer if (attachment_owned) attachment.header.releaseUserLocked(&session.guard, io) catch
        @panic("stencil attachment alias release failed");
    var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    query.setSampleCount(1);
    query.setDepthStencil(.{
        .format = .depth24_plus_stencil8,
        .depth_load_op = .load,
        .depth_store_op = .store,
        .depth_read_only = false,
        .stencil_load_op = .load,
        .stencil_store_op = .store,
        .stencil_read_only = false,
    });
    const pass = try f.device.native.?.render_pass_cache.getRenderPass(io, query);
    const input = try session.scratch(4);
    try session.upload(input, &.{255});
    const parameters: [64]u8 = @splat(0);
    var pipelines: [8]*native.Pipeline = undefined;
    for (&pipelines, 0..) |*owner, bit| {
        const prepared = try kernels.prepareDraw(session.context(), .{
            .key = .{
                .id = .buffer_to_stencil,
                .storage_format = .stencil8,
                .attachments = attachment,
                .stencil_write_bit = @intCast(bit),
            },
            .bindings = &.{.{ .buffer = input }},
            .parameters = &parameters,
            .compatible_render_pass = pass.render_pass,
        });
        owner.* = prepared.pipeline;
        try t.expectEqual(@as(u32, 1) << @as(u3, @intCast(bit)), owner.*.native.state.render.depth_stencil.?.stencil_write_mask);
        try t.expect(owner.*.attachment.render == attachment);
        try t.expect(owner.*.header.isAlive(&session.guard));
        for (pipelines[0..bit]) |earlier| {
            try t.expect(earlier != owner.*);
            try t.expect(earlier.native.vk_pipeline != owner.*.native.vk_pipeline);
        }
    }
    const alias = try kernels.prepareDraw(session.context(), .{
        .key = .{
            .id = .buffer_to_stencil,
            .storage_format = .stencil8,
            .attachments = attachment,
            .stencil_write_bit = 3,
        },
        .bindings = &.{.{ .buffer = input }},
        .parameters = &parameters,
        .compatible_render_pass = pass.render_pass,
    });
    try t.expect(alias.pipeline == pipelines[3]);
    // Drop the factory alias before releasing the guard for submission.
    try attachment.header.releaseUserLocked(&session.guard, io);
    attachment_owned = false;
    const serial = try session.submit();
    try f.device.wait(io, serial);
}

test "native kernels oversized parameter upload refuses before allocation roots or recording mutation" {
    var allocations = t.FailingAllocator.init(t.allocator, .{});
    var f: Fixture = undefined;
    try f.init(allocations.allocator());
    defer f.deinit();
    var probe: DriverProbe = undefined;
    probe.attach(&f);
    defer probe.detach(&f);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const io = f.threaded.io();
    const parameter_cap_bytes = 8192;
    const owner = try native.createInternalBufferLocked(f.allocator, io, &session.guard, &f.device.core.arena, f.device.native.?.resourceDevice(), .{
        .size = parameter_cap_bytes + 4,
        .native_usage = scratch_usage,
    });
    defer owner.header.releaseUserLocked(&session.guard, io) catch
        @panic("oversized parameter fixture alias release failed");
    const pending = session.context().pending_uses;
    const allocation_count = allocations.alloc_index;
    const root_count = pending.roots.count();
    const references = owner.header.reference_count;
    const total_references = session.guard.objects.total_reference_count;
    const users = session.guard.objects.user_reference_count;
    const queue_uses = owner.queue_uses;
    const temporary_count = session.context().queue.temporary_buffers.items.len;
    const accepted_serial = owner.accepted_usage_serial;
    const submission_serial = session.context().queue.timeline.lastSubmittedSerial();
    const bytes: [parameter_cap_bytes + 4]u8 = @splat(0x5a);
    try t.expect(!owner.native.is_data_initialized);
    try t.expect(!session.recording.needs_submit);
    try t.expectEqual(@as(usize, 0), probe.update_calls);
    {
        allocations.fail_index = allocations.alloc_index;
        defer allocations.fail_index = std.math.maxInt(usize);
        try t.expectError(error.KernelParameterUploadTooLarge, kernels.uploadParameters(session.context(), .{
            .owner = owner,
            .offset = 0,
            .size = bytes.len,
        }, &bytes));
    }
    try t.expectEqual(allocation_count, allocations.alloc_index);
    try t.expectEqual(root_count, pending.roots.count());
    try t.expect(!pending.roots.contains(&owner.header));
    try t.expectEqual(references, owner.header.reference_count);
    try t.expectEqual(total_references, session.guard.objects.total_reference_count);
    try t.expectEqual(users, session.guard.objects.user_reference_count);
    try t.expectEqual(queue_uses, owner.queue_uses);
    try t.expectEqual(temporary_count, session.context().queue.temporary_buffers.items.len);
    try t.expectEqual(accepted_serial, owner.accepted_usage_serial);
    try t.expectEqual(submission_serial, session.context().queue.timeline.lastSubmittedSerial());
    try t.expectEqual(@as(u32, 0), owner.native.last_write_usage);
    try t.expectEqual(@as(u32, 0), owner.native.read_usage);
    try t.expect(!owner.native.is_data_initialized);
    try t.expect(!session.recording.needs_submit);
    try t.expect(!session.context().queue.recording_poisoned);
    try t.expectEqual(@as(usize, 0), probe.update_calls);
}

test "native kernels exact 8192 byte parameter upload reaches canonical GPU buffer and readback" {
    const parameter_cap_bytes = 8192;
    const word_count = parameter_cap_bytes / @sizeOf(u32);
    var expected: [word_count]u32 = undefined;
    var bytes: [parameter_cap_bytes]u8 = undefined;
    for (&expected, 0..) |*word, index| {
        word.* = (@as(u32, @intCast(index)) * 17) ^ 0xa53c71e9;
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word.*, .little);
    }
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    var probe: DriverProbe = undefined;
    probe.attach(&f);
    defer probe.detach(&f);
    const io = f.threaded.io();
    const readback = try f.readback(parameter_cap_bytes);
    var readback_owned = true;
    defer if (readback_owned) f.release(readback);
    var session: Session = undefined;
    try session.begin(&f);
    defer session.deinit();
    const destination = try session.scratch(parameter_cap_bytes);
    try kernels.uploadParameters(session.context(), destination, &bytes);
    try t.expectEqual(@as(usize, 1), probe.update_calls);
    try t.expect(destination.owner.native.is_data_initialized);
    try t.expect(session.recording.needs_submit);
    try t.expect(session.context().pending_uses.roots.contains(&destination.owner.header));
    try t.expectEqual(@as(u32, 0), destination.owner.header.user_reference_count);
    for (session.context().queue.temporary_buffers.items) |temporary| {
        try t.expect(temporary.buffer != destination.owner.native);
    }
    try session.copy(destination, readback);
    const serial = try session.submit();
    try f.device.wait(io, serial);
    try f.expectWords(readback, &expected);
    f.release(readback);
    readback_owned = false;
    try f.closeDevice();
    try probe.expectEmpty();
}
