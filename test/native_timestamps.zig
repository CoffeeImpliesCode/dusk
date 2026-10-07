const std = @import("std");
const dusk = @import("dusk");

const engine = dusk.engine;
const core = dusk.core;
const kernels = engine.native_kernels;
const timestamps = engine.native_timestamps;
const Buffer = engine.native_resources.Buffer;
const Encoder = dusk.command.command_encoder.CommandEncoder;
const vk = dusk.platform.vulkan_bindings;

// This oracle uses wide scalar arithmetic, not the GPU's base-65536 carry algorithm.
fn oracle(ticks: u64, period: f32, valid_bits: u32, quantize: bool) u64 {
    std.debug.assert(valid_bits >= 1 and valid_bits <= 64);
    const bits: u32 = @bitCast(period);
    std.debug.assert(bits != 0 and bits < 0x7f800000);
    const exponent = (bits >> 23) & 255;
    const fraction = bits & 0x7fffff;
    const mantissa: u128 = if (exponent == 0) fraction else fraction | 0x800000;
    const shift: i32 = if (exponent == 0) -149 else @as(i32, @intCast(exponent)) - 150;
    const tick_mask: u64 = if (valid_bits == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @as(u6, @intCast(valid_bits))) - 1;
    const product: u128 = @as(u128, ticks & tick_mask) * mantissa;
    const integer: u128 = if (shift >= 128 or shift <= -128)
        0
    else if (shift >= 0)
        product << @as(u7, @intCast(shift))
    else
        product >> @as(u7, @intCast(-shift));
    const wrapped: u64 = @truncate(integer);
    return if (quantize) wrapped & 0xffffffffffff0000 else wrapped;
}

fn modularDelta(first: u64, last: u64, valid_bits: u32) u64 {
    const mask: u64 = if (valid_bits == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @as(u6, @intCast(valid_bits))) - 1;
    return (last -% first) & mask;
}

const tick_vectors = [_]u64{
    0,                  1,                  2,                  3,                  0x7fff,         0x8000,          0xffff,             0x10000,
    0x10001,            0xffffffff,         0x100000000,        0x100000001,        0xffffffffffff, 0x1000000000000, 0x7fffffffffffffff, 0x8000000000000000,
    0xffffffffffff0000, 0xffffffffffffffff, 0x123456789abcdef0, 0xfedcba9876543210,
};

// Includes both subnormal boundaries, mantissa carries, shifts across limb/word/64-bit
// boundaries, discarded fractions, and shifts beyond the 96-bit product.
const period_bits = [_]u32{
    0x00000001, 0x007fffff, 0x00800000,
    0x20000000, 0x2b000000, 0x2f800001,
    0x30000000, 0x37000000, 0x37800000,
    0x3b000000, 0x3effffff, 0x3f000000,
    0x3f800000, 0x3f800001, 0x3fc00000,
    0x3fffffff, 0x40000000, 0x47800000,
    0x4b000000, 0x4f800001, 0x53000000,
    0x5b000000, 0x5f000000, 0x5f800000,
    0x60000000, 0x6b000000, 0x7f7fffff,
};

test "timestamp independent oracle anchors floor wrap quantization and modular delta" {
    try std.testing.expectEqual(@as(u64, 4), oracle(3, 1.5, 64, false));
    try std.testing.expectEqual(@as(u64, 0), oracle(1, @bitCast(@as(u32, 1)), 64, false));
    try std.testing.expectEqual(@as(u64, 0xfffffffffffffffe), oracle(std.math.maxInt(u64), 2, 64, false));
    try std.testing.expectEqual(@as(u64, 1), oracle(std.math.maxInt(u64), 1, 1, false));
    try std.testing.expectEqual(@as(u64, 65536), oracle(131071, 1, 64, true));
    try std.testing.expectEqual(@as(u64, 0), oracle(65535, 1, 64, true));
    try std.testing.expectEqual(@as(u64, 3), modularDelta(14, 1, 4));
    try std.testing.expectEqual(@as(u64, 3), modularDelta(std.math.maxInt(u64) - 1, 1, 64));
}

const Fixture = struct {
    allocator: std.mem.Allocator,
    instance: engine.Instance,
    adapters: engine.AdapterList,
    device: engine.Device,
    handle_baseline: engine.vulkan_device.HandleSet,

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("unexpected timestamp device error");
    }

    fn init(self: *Fixture, allocator: std.mem.Allocator, io: std.Io, timestamp_feature: bool, quantize: bool) !void {
        self.allocator = allocator;
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(allocator, io) catch @panic("instance rollback failed");
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback failed");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.handle_baseline = self.instance.native_context.?.handles;
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .required_features = if (timestamp_feature) &.{.timestamp_query} else &.{},
            .timestamp_quantization = quantize,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn deinit(self: *Fixture, io: std.Io) void {
        self.device.deinit(self.allocator, io) catch @panic("timestamp device teardown failed");
        self.adapters.deinit(io) catch @panic("timestamp adapters teardown failed");
        std.testing.expectEqualSlices(u32, &self.handle_baseline.counts, &self.instance.native_context.?.handles.counts) catch
            @panic("timestamp native handle leak");
        self.instance.deinit(self.allocator, io) catch @panic("timestamp instance teardown failed");
    }

    fn buffer(self: *Fixture, io: std.Io, size: u64, usage: dusk.api.bitmask.BufferUsage) !*Buffer {
        return self.device.createBuffer(self.allocator, io, .{ .size = size, .usage = usage });
    }

    fn release(self: *Fixture, io: std.Io, value: *Buffer) void {
        self.device.release(self.allocator, io, value) catch @panic("timestamp buffer release failed");
    }
};

fn contextFor(fixture: *Fixture, io: std.Io, guard: *const core.ObjectGuard, recording: *engine.recording_context.CommandRecordingContext, root: *Buffer) !kernels.Context {
    const native = fixture.device.native.?;
    try native.prepareRecordingRootLocked(fixture.allocator, guard, &fixture.device.core, &root.header);
    recording.command_buffer = native.queue.commandBuffer();
    return .{
        .io = io,
        .guard = guard,
        .device = &fixture.device.core,
        .queue = &native.queue,
        .recording = recording,
        .pending_uses = &native.recording_uses.?,
        .cache = &native.kernel_cache.?,
    };
}

fn copyRange(context: kernels.Context, source: kernels.BufferRange, destination: kernels.BufferRange) !void {
    try std.testing.expectEqual(source.size, destination.size);
    try std.testing.expect(source.owner.native.is_data_initialized);
    try kernels.copyBuffer(context, source, destination);
    try std.testing.expect(destination.owner.native.is_data_initialized);
}

fn submitLease(fixture: *Fixture, io: std.Io, lease: *engine.Device.QueueLease) !void {
    const commands = [_]vk.VkCommandBuffer{lease.commandBuffer()};
    const submitted = try lease.submit(fixture.allocator, io, .{ .command_buffers = &commands }, &.{});
    lease.deinit(io);
    try std.testing.expect(submitted.serial != 0);
    try fixture.device.wait(io, submitted.serial);
}

fn expectMapped(fixture: *Fixture, io: std.Io, readback: *Buffer, expected: []const u8) !void {
    try fixture.device.mapBuffer(io, readback, .{ .mode = .{ .read = true } });
    defer fixture.device.unmapBuffer(io, readback) catch @panic("timestamp unmap failed");
    var guard = core.ObjectGuard.lockUncancelable(io, readback.header.tracking);
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, expected.len);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

const vector_bytes = tick_vectors.len * 8;
const vector_stride = vector_bytes + 16;
const raw_proof_offset = 16 + vector_stride * 64;
const vector_buffer_size = raw_proof_offset + vector_bytes;

fn gpuVectors(fixture: *Fixture, io: std.Io, period: f32, quantize: bool) !void {
    const destination = try fixture.buffer(io, vector_buffer_size, .{ .query_resolve = true, .copy_src = true, .copy_dst = true });
    defer fixture.release(io, destination);
    const readback = try fixture.buffer(io, vector_buffer_size, .{ .map_read = true, .copy_dst = true });
    defer fixture.release(io, readback);
    var expected: [vector_buffer_size]u8 = @splat(0xa5);
    var input_bytes: [vector_bytes]u8 = undefined;
    for (tick_vectors, 0..) |tick, index| {
        std.mem.writeInt(u64, input_bytes[index * 8 ..][0..8], tick, .little);
    }
    var recording = engine.recording_context.CommandRecordingContext.init(fixture.allocator);
    defer recording.deinit();
    var lease = try fixture.device.getQueue(io);
    defer lease.deinit(io);
    {
        var guard = try core.ObjectGuard.lock(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        const context = try contextFor(fixture, io, &guard, &recording, destination);
        const saved_workgroups = fixture.device.limits.v1.max_compute_workgroups_per_dimension;
        fixture.device.limits.v1.max_compute_workgroups_per_dimension = 1;
        defer fixture.device.limits.v1.max_compute_workgroups_per_dimension = saved_workgroups;
        errdefer context.queue.poisonRecording();
        try std.testing.expect(!destination.native.usage.storage);
        try std.testing.expect(!destination.native.usage.map_read);
        try kernels.uploadParameters(context, .{ .owner = destination, .offset = 0, .size = 8192 }, expected[0..8192]);
        try kernels.uploadParameters(context, .{ .owner = destination, .offset = 8192, .size = vector_buffer_size - 8192 }, expected[8192..]);
        const input = try kernels.scratchBuffer(context, .{ .size = vector_bytes, .native_usage = 4 | 8 });
        try std.testing.expectEqual(@as(u32, 0), input.owner.header.user_reference_count);
        try std.testing.expect(input.owner.header.reference_count > 0);
        try kernels.uploadParameters(context, input, &input_bytes);
        for (1..65) |bits| {
            const valid_bits: u32 = @intCast(bits);
            const offset = 16 + (bits - 1) * vector_stride;
            for (tick_vectors, 0..) |tick, index| {
                std.mem.writeInt(u64, expected[offset + index * 8 ..][0..8], oracle(tick, period, valid_bits, quantize), .little);
            }
            try timestamps.convertTicks(context, input, tick_vectors.len, .{
                .owner = destination,
                .offset = offset,
                .size = vector_bytes,
            }, try timestamps.decodePeriod(period, valid_bits, quantize));
        }
        try copyRange(context, .{ .owner = destination, .offset = 0, .size = vector_buffer_size }, .{ .owner = readback, .offset = 0, .size = vector_buffer_size });
        try copyRange(context, input, .{ .owner = readback, .offset = raw_proof_offset, .size = vector_bytes });
        @memcpy(expected[raw_proof_offset..], &input_bytes);
    }
    try submitLease(fixture, io, &lease);
    try expectMapped(fixture, io, readback, &expected);
}

test "timestamp GPU u32 limbs match independent u128 oracle for all valid bits and exact masks" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, io, false, false);
    defer fixture.deinit(io);
    var cached: ?*engine.native_resources.Pipeline = null;
    for (period_bits) |bits| {
        const period: f32 = @bitCast(bits);
        try gpuVectors(&fixture, io, period, false);
        try gpuVectors(&fixture, io, period, true);
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        const payload = try timestampPipeline(&fixture, &guard);
        if (cached) |prior| {
            try std.testing.expect(prior == payload);
        } else {
            cached = payload;
        }
        try std.testing.expectEqual(@as(u32, 0), payload.header.user_reference_count);
        try std.testing.expectEqual(@as(u32, 1), payload.header.reference_count);
    }
    var lease = try fixture.device.getQueue(io);
    defer lease.deinit(io);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    const payload = cached orelse return error.TimestampPipelineMissing;
    fixture.device.native.?.kernel_cache.?.releaseRootsLocked(&guard, io);
    try std.testing.expectEqual(@as(u32, 0), payload.header.reference_count);
    try std.testing.expect(payload.header.state == .destroyed);
    const total = guard.objects.total_reference_count;
    fixture.device.native.?.kernel_cache.?.releaseRootsLocked(&guard, io);
    try std.testing.expectEqual(total, guard.objects.total_reference_count);
}

test "timestamp period validation rejects zero negative nonfinite and invalid valid bit counts" {
    for ([_]u32{ 0, 0x80000000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000 }) |bits| {
        try std.testing.expectError(error.TimestampPeriodInvalid, timestamps.decodePeriod(@bitCast(bits), 64, false));
    }
    for ([_]u32{ 0, 65, std.math.maxInt(u32) }) |bits| {
        try std.testing.expectError(error.TimestampValidBitsInvalid, timestamps.decodePeriod(1, bits, false));
    }
}

fn createQuery(fixture: *Fixture, io: std.Io, count: u32) !*engine.query_set.QuerySet {
    var guard = try core.ObjectGuard.lock(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    try fixture.device.bindObjectsLocked(&guard, fixture.allocator);
    const handle = try engine.query_set.QuerySet.create(fixture.allocator, io, &guard, &fixture.device.core, .{ .type_ = .timestamp, .count = count }, .{ .timestamp_query_enabled = fixture.device.enabled_features.isEnabled(.timestamp_query) });
    return engine.query_set.resolveQuerySet(&fixture.device.core, &guard, handle);
}

fn releaseQuery(fixture: *Fixture, io: std.Io, set: *engine.query_set.QuerySet) void {
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    set.header.releaseUserLocked(&guard, io) catch @panic("timestamp query release failed");
}

fn mappedBytes(fixture: *Fixture, io: std.Io, buffer: *Buffer, output: []u8) !void {
    try fixture.device.mapBuffer(io, buffer, .{ .mode = .{ .read = true } });
    defer fixture.device.unmapBuffer(io, buffer) catch @panic("timestamp unmap failed");
    var guard = core.ObjectGuard.lockUncancelable(io, buffer.header.tracking);
    defer guard.unlock(io);
    @memcpy(output, try buffer.native.getConstMappedRange(0, output.len));
}

fn hardwareTimestamps(quantize: bool) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, io, true, quantize);
    defer fixture.deinit(io);
    try std.testing.expect(fixture.device.timestamp_quantization == quantize);
    const native = fixture.device.native.?;
    const period = native.native_device.timestamp_period;
    const valid_bits = native.native_device.timestamp_valid_bits;
    try std.testing.expect(valid_bits >= 1 and valid_bits <= 64);
    const constants = try timestamps.decodePeriod(period, valid_bits, quantize);
    const set = try createQuery(&fixture, io, 3);
    defer releaseQuery(&fixture, io, set);
    const destination = try fixture.buffer(io, 1024, .{ .query_resolve = true, .copy_src = true, .copy_dst = true });
    defer fixture.release(io, destination);
    const readback = try fixture.buffer(io, 1024, .{ .map_read = true, .copy_dst = true });
    defer fixture.release(io, readback);
    const work = try fixture.buffer(io, 65536, .{ .copy_dst = true });
    defer fixture.release(io, work);
    var encoder = Encoder.init(allocator, fixture.device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    var expected: [1024]u8 = @splat(0xa5);
    const work_bytes: [65536]u8 = @splat(0x71);
    {
        var guard = try core.ObjectGuard.lock(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        try std.testing.expect(!destination.native.usage.storage);
        try encoder.writeBuffer(.{ .buffer = try destination.ref(&guard), .data = &expected });
        try encoder.writeTimestamp(.{
            .query_set = set,
            .query_index = 0,
            .query_count = 3,
            .timestamp_query_enabled = fixture.device.enabled_features.isEnabled(.timestamp_query),
        });
        try encoder.writeBuffer(.{ .buffer = try work.ref(&guard), .data = &work_bytes });
        try encoder.writeTimestamp(.{
            .query_set = set,
            .query_index = 1,
            .query_count = 3,
            .timestamp_query_enabled = fixture.device.enabled_features.isEnabled(.timestamp_query),
        });
        try encoder.resolveQuerySet(.{
            .query_set = set,
            .query_count_of_set = 3,
            .first_query = 0,
            .query_count = 3,
            .destination = try destination.ref(&guard),
            .destination_size = 1024,
            .destination_usage = destination.native.usage,
            .destination_offset = 256,
        });
        try encoder.copyBufferToBuffer(.{
            .source = try destination.ref(&guard),
            .source_offset = 0,
            .destination = try readback.ref(&guard),
            .destination_offset = 0,
            .size = 1024,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    const serial = try fixture.device.submit(allocator, io, &finished);
    try std.testing.expect(serial != 0);
    try fixture.device.wait(io, serial);
    var actual: [1024]u8 = undefined;
    try mappedBytes(&fixture, io, readback, &actual);

    // Test-only raw resolve captures the SAME hardware query slots, never substitutes
    // raw output for the preceding frontend GPU conversion.
    const raw_readback = try fixture.buffer(io, 24, .{ .map_read = true, .copy_dst = true });
    defer fixture.release(io, raw_readback);
    var recording = engine.recording_context.CommandRecordingContext.init(allocator);
    defer recording.deinit();
    var lease = try fixture.device.getQueue(io);
    defer lease.deinit(io);
    {
        var guard = try core.ObjectGuard.lock(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        const context = try contextFor(&fixture, io, &guard, &recording, raw_readback);
        errdefer context.queue.poisonRecording();
        try std.testing.expect(set.isQueryAvailable(&guard, 0));
        try std.testing.expect(set.isQueryAvailable(&guard, 1));
        try std.testing.expect(!set.isQueryAvailable(&guard, 2));
        try context.pending_uses.retainDerivedRootLocked(&guard, context.device, &set.header);
        const raw = try kernels.scratchBuffer(context, .{ .size = 24, .native_usage = 4 | 8 });
        try kernels.transitionBuffer(context, raw, 8);
        try raw.owner.native.ensureDataInitializedAsDestination(.{
            .command_buffer = context.recording.command_buffer,
            .pending_serial = context.queue.timeline.nextSerial(),
        }, raw.offset, raw.size);
        try engine.vulkan_query_set.resolveQueries(allocator, &guard, context.queue, set, 0, 3, raw.owner.native.handle, raw.offset);
        try copyRange(context, raw, .{ .owner = raw_readback, .offset = 0, .size = 24 });
    }
    try submitLease(&fixture, io, &lease);
    var raw_bytes: [24]u8 = undefined;
    try mappedBytes(&fixture, io, raw_readback, &raw_bytes);
    const first = std.mem.readInt(u64, raw_bytes[0..8], .little);
    const last = std.mem.readInt(u64, raw_bytes[8..16], .little);
    const unavailable = std.mem.readInt(u64, raw_bytes[16..24], .little);
    try std.testing.expectEqual(@as(u64, 0), unavailable);
    const delta_ticks = modularDelta(first, last, valid_bits);
    for ([_]u64{ first, last, unavailable }, 0..) |ticks, index| {
        std.mem.writeInt(u64, expected[256 + index * 8 ..][0..8], oracle(ticks, period, valid_bits, quantize), .little);
        if (quantize) {
            try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, actual[256 + index * 8 ..][0..8], .little) & 65535);
        }
    }
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    std.debug.print("timestamp physical proof period_bits=0x{x:0>8} valid_bits={d} " ++
        "mantissa={d} binary_shift={d} quantize={} mask=0x{x:0>8} delta_ticks={d}\n", .{ @as(u32, @bitCast(period)), valid_bits, constants.mantissa, constants.binary_shift, quantize, constants.quantization_mask, delta_ticks });
}

test "hardware timestampWrite frontend replay GPU conversion copy map unquantized physical proof" {
    try hardwareTimestamps(false);
}

test "hardware timestampWrite frontend replay GPU conversion copy map quantized physical proof" {
    try hardwareTimestamps(true);
}

fn timestampPipeline(fixture: *Fixture, guard: *const core.ObjectGuard) !*engine.native_resources.Pipeline {
    guard.assertOwns(fixture.device.core.arena.objectList());
    var found: ?*engine.native_resources.Pipeline = null;
    for (fixture.device.native.?.kernel_cache.?.entries) |slot| {
        const entry = slot orelse continue;
        if (entry.key.id != .timestamp_to_nanoseconds) continue;
        try std.testing.expect(found == null);
        found = entry.pipeline;
    }
    return found orelse error.TimestampPipelineMissing;
}

test "timestamp zero count validation dead query and rejected ranges emit no conversion" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, io, true, false);
    defer fixture.deinit(io);
    const set = try createQuery(&fixture, io, 3);
    defer releaseQuery(&fixture, io, set);
    const raw = try fixture.buffer(io, 24, .{ .copy_src = true, .copy_dst = true });
    defer fixture.release(io, raw);
    const destination = try fixture.buffer(io, 1024, .{ .query_resolve = true, .copy_src = true, .copy_dst = true });
    defer fixture.release(io, destination);
    var recording = engine.recording_context.CommandRecordingContext.init(fixture.allocator);
    defer recording.deinit();
    var lease = try fixture.device.getQueue(io);
    defer lease.deinit(io);
    var guard = try core.ObjectGuard.lock(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    const context = try contextFor(&fixture, io, &guard, &recording, destination);
    const constants = try timestamps.decodePeriod(1, 64, false);
    const raw_range: kernels.BufferRange = .{ .owner = raw, .offset = 0, .size = 24 };
    const output: kernels.BufferRange = .{ .owner = destination, .offset = 256, .size = 24 };
    const tracked = fixture.device.core.arena.queryTrackedCount(&guard);
    const total = guard.objects.total_reference_count;
    const roots = context.pending_uses.roots.count();
    try timestamps.convertTicks(context, raw_range, 0, output, constants);
    try timestamps.resolveTimestamps(context, set, 3, 0, output, false);
    try std.testing.expectEqual(tracked, fixture.device.core.arena.queryTrackedCount(&guard));
    try std.testing.expectEqual(total, guard.objects.total_reference_count);
    try std.testing.expectEqual(roots, context.pending_uses.roots.count());
    for (context.cache.entries) |entry| try std.testing.expect(entry == null);
    try std.testing.expectError(error.TimestampRangeInvalid, timestamps.convertTicks(context, raw_range, 4, output, constants));
    try std.testing.expectError(error.TimestampRangeInvalid, timestamps.convertTicks(context, raw_range, 1, .{ .owner = destination, .offset = 257, .size = 8 }, constants));
    try std.testing.expectError(error.TimestampRangeInvalid, timestamps.convertTicks(context, raw_range, 1, .{ .owner = destination, .offset = std.math.maxInt(u64) - 7, .size = 8 }, constants));
    try std.testing.expectError(error.TimestampRangeInvalid, timestamps.convertTicks(context, raw_range, 2, .{ .owner = raw, .offset = 8, .size = 16 }, constants));
    var invalid = constants;
    invalid.quantization_mask = 0xfffffff0;
    try std.testing.expectError(error.TimestampConstantsInvalid, timestamps.convertTicks(context, raw_range, 1, output, invalid));
    try std.testing.expectError(error.QueryIndexOutOfRange, timestamps.resolveTimestamps(context, set, 2, 2, output, false));
    try std.testing.expectError(error.QueryResolveOffsetInvalid, timestamps.resolveTimestamps(context, set, 0, 1, .{ .owner = destination, .offset = 8, .size = 8 }, false));
    set.header.retirePayloadLocked(&guard, io, .early_destroy);
    try std.testing.expectError(error.QuerySetDestroyed, timestamps.resolveTimestamps(context, set, 0, 1, output, false));
    raw.header.retirePayloadLocked(&guard, io, .early_destroy);
    try std.testing.expectError(error.ResourceDestroyed, timestamps.convertTicks(context, raw_range, 1, output, constants));
    try std.testing.expectEqual(@as(dusk.platform.Serial, 0), destination.accepted_usage_serial);
    try std.testing.expectEqual(total, guard.objects.total_reference_count);
    try std.testing.expect(!context.queue.recording_poisoned);
}

fn allocationAttempt(fail_after: usize) !bool {
    const io = std.testing.io;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture: Fixture = undefined;
    try fixture.init(failing.allocator(), io, false, false);
    defer fixture.deinit(io);
    const destination = try fixture.buffer(io, 64, .{ .query_resolve = true, .copy_src = true, .copy_dst = true });
    defer fixture.release(io, destination);
    const readback = try fixture.buffer(io, 64, .{ .map_read = true, .copy_dst = true });
    defer fixture.release(io, readback);
    var recording = engine.recording_context.CommandRecordingContext.init(fixture.allocator);
    defer recording.deinit();
    var lease = try fixture.device.getQueue(io);
    defer lease.deinit(io);
    var expected: [64]u8 = @splat(0xa5);
    var input_bytes: [24]u8 = undefined;
    const ticks = [_]u64{ 0xffff, 0x100000001, 0xffffffffffffffff };
    for (ticks, 0..) |tick, index| {
        std.mem.writeInt(u64, input_bytes[index * 8 ..][0..8], tick, .little);
    }
    {
        var guard = try core.ObjectGuard.lock(io, fixture.device.core.arena.objectList());
        defer guard.unlock(io);
        const context = try contextFor(&fixture, io, &guard, &recording, destination);
        errdefer context.queue.poisonRecording();
        const input = try kernels.scratchBuffer(context, .{ .size = 24, .native_usage = 4 | 8 });
        try kernels.uploadParameters(context, input, &input_bytes);
        try kernels.uploadParameters(context, .{ .owner = destination, .offset = 0, .size = 64 }, &expected);
        const user_references = guard.objects.user_reference_count;
        const constants = try timestamps.decodePeriod(1.5, 64, false);
        failing.fail_index = failing.alloc_index + fail_after;
        const attempted = timestamps.convertTicks(context, input, 3, .{ .owner = destination, .offset = 8, .size = 24 }, constants);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(user_references, guard.objects.user_reference_count);
        try std.testing.expectEqual(@as(dusk.platform.Serial, 0), destination.accepted_usage_serial);
        try std.testing.expectEqual(@as(dusk.platform.Serial, 0), input.owner.accepted_usage_serial);
        try std.testing.expectEqual(@as(dusk.platform.Serial, 0), lease.lastSubmittedSerial());
        if (attempted) |_| {
            for (ticks, 0..) |tick, index| {
                std.mem.writeInt(u64, expected[8 + index * 8 ..][0..8], oracle(tick, 1.5, 64, false), .little);
            }
            try copyRange(context, .{ .owner = destination, .offset = 0, .size = 64 }, .{ .owner = readback, .offset = 0, .size = 64 });
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expect(context.queue.recording_poisoned);
            return false;
        }
    }
    try submitLease(&fixture, io, &lease);
    try expectMapped(&fixture, io, readback, &expected);
    return true;
}

test "timestamp fail N releases aliases and handles without unaccepted scratch serial" {
    var succeeded = false;
    for (0..256) |fail_after| {
        if (try allocationAttempt(fail_after)) {
            succeeded = true;
            break;
        }
    }
    try std.testing.expect(succeeded);
}

test "timestamp committed SPIR-V reflection has exact u32 compute descriptor ABI" {
    const definition = try engine.native_kernel_definitions.definition(.{ .id = .timestamp_to_nanoseconds });
    try std.testing.expectEqual(@as(u32, 32), definition.parameter_size);
    const compute = definition.stages.compute;
    try std.testing.expectEqualSlices(u32, &.{ 8, 1, 1 }, &compute.workgroup_size);
    const words = compute.stage.words;
    try dusk.spirv.validate(words);
    const reflected = try dusk.spirv.reflect(std.testing.allocator, words);
    defer reflected.deinit();
    const entry = reflected.findEntryPoint(compute.stage.entry_point) orelse
        return error.TimestampShaderEntryPointMissing;
    try std.testing.expectEqual(dusk.spirv.ExecutionModel.gl_compute, entry.execution_model);
    try std.testing.expectEqual(@as(usize, 3), entry.resources.len);
    var binding_mask: u32 = 0;
    for (entry.resources) |resource| {
        try std.testing.expectEqual(@as(u32, 0), resource.set);
        try std.testing.expect(resource.binding < 3);
        binding_mask |= @as(u32, 1) << @as(u5, @intCast(resource.binding));
        try std.testing.expectEqual(if (resource.binding == 2) dusk.spirv.ResourceKind.uniform_buffer else dusk.spirv.ResourceKind.storage_buffer, resource.kind);
        if (resource.binding == 0) try std.testing.expect(resource.buffer_read_only);
    }
    try std.testing.expectEqual(@as(u32, 7), binding_mask);
    // Decode actual binary instructions. Optional 64-bit scalar declarations and
    // capabilities would defeat the baseline-device promise even with u32 WGSL.
    var offset: usize = dusk.spirv.header_word_count;
    var actual_workgroup = false;
    while (offset < words.len) {
        const length: usize = words[offset] >> 16;
        const opcode: u16 = @truncate(words[offset]);
        try std.testing.expect(length != 0 and length <= words.len - offset);
        if (opcode == 17) {
            try std.testing.expect(length == 2);
            try std.testing.expect(words[offset + 1] != 10); // Float64
            try std.testing.expect(words[offset + 1] != 11); // Int64
        } else if (opcode == 16 and length == 6 and
            words[offset + 1] == entry.id and words[offset + 2] == 17)
        {
            try std.testing.expectEqualSlices(u32, &.{ 8, 1, 1 }, words[offset + 3 ..][0..3]);
            actual_workgroup = true;
        } else if (opcode == 21 or opcode == 22) {
            try std.testing.expect(length >= 3);
            try std.testing.expect(words[offset + 2] != 64);
        }
        offset += length;
    }
    try std.testing.expectEqual(words.len, offset);
    try std.testing.expect(actual_workgroup);
}

test "timestamp GPU conversion accepts public CopySrc only input without public Storage" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator, io, false, false);
    defer fixture.deinit(io);
    const source = try fixture.device.createBuffer(fixture.allocator, io, .{
        .size = vector_bytes,
        .usage = .{ .copy_src = true },
        .mapped_at_creation = true,
    });
    defer fixture.release(io, source);
    var input_bytes: [vector_bytes]u8 = undefined;
    for (tick_vectors, 0..) |tick, index| {
        std.mem.writeInt(u64, input_bytes[index * 8 ..][0..8], tick, .little);
    }
    {
        var guard = try core.ObjectGuard.lock(io, source.header.tracking);
        defer guard.unlock(io);
        try std.testing.expect(!source.native.usage.storage);
        try std.testing.expect(!source.native.usage.copy_dst);
        @memcpy(try source.native.getMappedRange(0, vector_bytes), &input_bytes);
    }
    try fixture.device.unmapBuffer(io, source);
    const output_size = vector_bytes * 2 + 32;
    const destination = try fixture.buffer(io, output_size, .{ .query_resolve = true, .copy_src = true, .copy_dst = true });
    defer fixture.release(io, destination);
    const readback = try fixture.buffer(io, output_size, .{ .map_read = true, .copy_dst = true });
    defer fixture.release(io, readback);
    var expected: [output_size]u8 = @splat(0xa5);
    var recording = engine.recording_context.CommandRecordingContext.init(fixture.allocator);
    defer recording.deinit();
    var lease = try fixture.device.getQueue(io);
    defer lease.deinit(io);
    {
        var guard = try core.ObjectGuard.lock(io, source.header.tracking);
        defer guard.unlock(io);
        const context = try contextFor(&fixture, io, &guard, &recording, destination);
        errdefer context.queue.poisonRecording();
        try kernels.uploadParameters(context, .{ .owner = destination, .offset = 0, .size = output_size }, &expected);
        const input: kernels.BufferRange = .{ .owner = source, .offset = 0, .size = vector_bytes };
        try timestamps.convertTicks(context, input, tick_vectors.len, .{ .owner = destination, .offset = 16, .size = vector_bytes }, try timestamps.decodePeriod(1.5, 64, false));
        try copyRange(context, .{ .owner = destination, .offset = 0, .size = output_size }, .{ .owner = readback, .offset = 0, .size = output_size });
        try copyRange(context, input, .{ .owner = readback, .offset = vector_bytes + 32, .size = vector_bytes });
        for (tick_vectors, 0..) |tick, index| {
            std.mem.writeInt(u64, expected[16 + index * 8 ..][0..8], oracle(tick, 1.5, 64, false), .little);
        }
        @memcpy(expected[vector_bytes + 32 ..], &input_bytes);
    }
    try submitLease(&fixture, io, &lease);
    try expectMapped(&fixture, io, readback, &expected);
}
