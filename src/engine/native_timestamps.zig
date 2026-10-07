//! Timestamp query output uses exact physical f32 constants and GPU u32 arithmetic.
const std = @import("std");
const vulkan = @import("vulkan");
const kernels = @import("native_kernels.zig");
const buffer = @import("buffer.zig");
const query = @import("query_set.zig");
const native_query = @import("vulkan_query_set.zig");

pub const Error = kernels.Error || native_query.Error || error{
    TimestampCapabilityUnavailable,
    TimestampPeriodInvalid,
    TimestampValidBitsInvalid,
    TimestampConstantsInvalid,
    TimestampRangeInvalid,
};

pub const quantization_mask: u32 = 0xffff0000;
const copy_source_usage: u32 = 4;
const copy_destination_usage: u32 = 8;
const query_resolve_usage: u32 = 512;
const max_conversion_count: u32 = 1 << 24;

pub const Constants = struct {
    mantissa: u32,
    binary_shift: i32,
    tick_mask: [2]u32,
    quantization_mask: u32,

    pub fn encode(self: Constants, count: u32) [32]u8 {
        const words = [_]u32{ count, self.tick_mask[0], self.tick_mask[1], self.mantissa, @bitCast(self.binary_shift), self.quantization_mask, 0, 0 };
        var bytes: [32]u8 = undefined;
        for (words, 0..) |word, index| {
            std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
        }
        return bytes;
    }

    fn validate(self: Constants) Error!void {
        if (self.mantissa == 0 or self.mantissa > 0xffffff or
            self.binary_shift < -149 or self.binary_shift > 104 or
            (self.quantization_mask != 0xffffffff and
                self.quantization_mask != quantization_mask))
        {
            return error.TimestampConstantsInvalid;
        }
        const mask = @as(u64, self.tick_mask[0]) |
            (@as(u64, self.tick_mask[1]) << 32);
        if (mask == 0 or (mask & (mask +% 1)) != 0) {
            return error.TimestampConstantsInvalid;
        }
    }
};

/// Only the immutable physical period is decoded on the CPU.
pub fn decodePeriod(period: f32, valid_bits: u32, quantize: bool) Error!Constants {
    if (valid_bits == 0 or valid_bits > 64) return error.TimestampValidBitsInvalid;
    const bits: u32 = @bitCast(period);
    const exponent = (bits >> 23) & 0xff;
    const fraction = bits & 0x7fffff;
    if ((bits >> 31) != 0 or exponent == 0xff or (exponent == 0 and fraction == 0)) {
        return error.TimestampPeriodInvalid;
    }
    return .{
        .mantissa = if (exponent == 0) fraction else 0x800000 | fraction,
        .binary_shift = if (exponent == 0) -149 else @as(i32, @intCast(exponent)) - 150,
        .tick_mask = .{
            if (valid_bits >= 32) 0xffffffff else (@as(u32, 1) << @as(u5, @intCast(valid_bits))) - 1,
            if (valid_bits == 64) 0xffffffff else if (valid_bits <= 32) 0 else (@as(u32, 1) << @as(u5, @intCast(valid_bits - 32))) - 1,
        },
        .quantization_mask = if (quantize) quantization_mask else 0xffffffff,
    };
}

fn validateRange(context: kernels.Context, range: kernels.BufferRange, size: u64) Error!void {
    if (range.owner.header.tracking != context.guard.objects) {
        return error.ResourceDeviceMismatch;
    }
    if (!range.owner.header.node.linked or range.owner.header.state != .alive or
        range.owner.header.reference_count == 0)
    {
        return error.ResourceDestroyed;
    }
    if (range.offset % 8 != 0 or size > range.size or
        range.offset > range.owner.native.size or
        range.size > range.owner.native.size - range.offset)
    {
        return error.TimestampRangeInvalid;
    }
}

fn windowCapacity(context: kernels.Context) Error!u32 {
    const physical = context.cache.native_device.physical.properties.limits;
    const effective = context.cache.limits.v1;
    const maximum_bytes = @min(
        @min(@as(u64, physical.maxStorageBufferRange), effective.max_storage_buffer_binding_size),
        @min(context.cache.resource_device.buffer_device.max_buffer_size, effective.max_buffer_size),
    );
    const workgroups = @min(physical.maxComputeWorkGroupCount[0], effective.max_compute_workgroups_per_dimension);
    const count = @min(@divFloor(maximum_bytes, 8), @as(u64, workgroups) * 8);
    if (count == 0 or physical.maxComputeWorkGroupInvocations < 8 or
        physical.maxComputeWorkGroupSize[0] < 8 or
        effective.max_compute_invocations_per_workgroup < 8 or
        effective.max_compute_workgroup_size_x < 8)
    {
        return error.KernelDispatchLimitExceeded;
    }
    return @intCast(@min(count, max_conversion_count));
}

fn preflight(context: kernels.Context) Error!void {
    try kernels.validateContext(context);
    if (context.recording.active_render_pass != null) {
        return error.KernelRequiresOutsideRenderPass;
    }
    const procs = context.cache.native_device.procs;
    if (procs.cmd_copy_buffer == null or procs.cmd_pipeline_barrier == null or
        procs.cmd_fill_buffer == null)
    {
        return error.MissingDeviceProc;
    }
}

fn copyOutput(
    context: kernels.Context,
    source: kernels.BufferRange,
    destination: kernels.BufferRange,
) Error!void {
    try destination.owner.native.ensureDataInitializedAsDestination(.{
        .command_buffer = context.recording.command_buffer,
        .pending_serial = context.queue.timeline.nextSerial(),
    }, destination.offset, source.size);
    try kernels.transitionBuffer(context, source, copy_source_usage);
    const destination_usage = if (destination.owner.native.internal_usage &
        query_resolve_usage != 0) query_resolve_usage else copy_destination_usage;
    try kernels.transitionBuffer(context, destination, destination_usage);
    const region: vulkan.VkBufferCopy = .{
        .srcOffset = source.offset,
        .dstOffset = destination.offset,
        .size = source.size,
    };
    const copy = context.cache.native_device.procs.cmd_copy_buffer orelse
        return error.MissingDeviceProc;
    copy(context.recording.command_buffer, source.owner.native.handle, destination.owner.native.handle, 1, &region);
    context.recording.needs_submit = true;
}

fn convertWindow(
    context: kernels.Context,
    raw: kernels.BufferRange,
    count: u32,
    destination: kernels.BufferRange,
    constants: Constants,
) Error!void {
    const output = try kernels.scratchBuffer(context, .{
        .size = @as(u64, count) * 8,
        .native_usage = buffer.internal_storage_buffer |
            copy_source_usage | copy_destination_usage,
    });
    const bindings = [_]kernels.Binding{ .{ .buffer = raw }, .{ .buffer = output } };
    const parameters = constants.encode(count);
    try kernels.recordCompute(context, .{
        .key = .{ .id = .timestamp_to_nanoseconds },
        .bindings = &bindings,
        .parameters = &parameters,
        .workgroups = .{ @divFloor(count + 7, 8), 1, 1 },
    });
    try copyOutput(context, output, destination);
}

/// Internal GPU conversion also serves deterministic physical-constant fixtures.
/// Input bytes stay on the GPU. Constants never contain a timestamp value.
pub fn convertTicks(
    context: kernels.Context,
    raw: kernels.BufferRange,
    count: u32,
    destination: kernels.BufferRange,
    constants: Constants,
) Error!void {
    try constants.validate();
    if (count > max_conversion_count) return error.TimestampRangeInvalid;
    const size = @as(u64, count) * 8;
    try validateRange(context, raw, size);
    try validateRange(context, destination, size);
    if (raw.owner == destination.owner and count != 0 and
        raw.offset < destination.offset + size and destination.offset < raw.offset + size)
    {
        return error.TimestampRangeInvalid;
    }
    if (count == 0) return;
    try preflight(context);
    if (raw.owner.native.internal_usage & copy_source_usage == 0 or
        destination.owner.native.internal_usage &
            (copy_destination_usage | query_resolve_usage) == 0)
    {
        return error.InternalBufferUsageInvalid;
    }
    const capacity = try windowCapacity(context);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &raw.owner.header);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &destination.owner.header);
    errdefer context.queue.poisonRecording();
    try raw.owner.native.ensureDataInitializedAsDestination(.{
        .command_buffer = context.recording.command_buffer,
        .pending_serial = context.queue.timeline.nextSerial(),
    }, 0, 0);
    var completed: u32 = 0;
    while (completed < count) {
        const window_count = @min(capacity, count - completed);
        const window_bytes = @as(u64, window_count) * 8;
        const input = try kernels.scratchBuffer(context, .{
            .size = window_bytes,
            .native_usage = buffer.read_only_storage_buffer | copy_destination_usage,
        });
        try kernels.transitionBuffer(context, raw, copy_source_usage);
        try kernels.transitionBuffer(context, input, copy_destination_usage);
        const region: vulkan.VkBufferCopy = .{
            .srcOffset = raw.offset + @as(u64, completed) * 8,
            .dstOffset = input.offset,
            .size = window_bytes,
        };
        context.cache.native_device.procs.cmd_copy_buffer.?(context.recording.command_buffer, raw.owner.native.handle, input.owner.native.handle, 1, &region);
        input.owner.native.is_data_initialized = true;
        try convertWindow(context, input, window_count, .{
            .owner = destination.owner,
            .offset = destination.offset + @as(u64, completed) * 8,
            .size = window_bytes,
        }, constants);
        completed += window_count;
    }
}

/// The replay caller derives quantization from its actual device policy.
pub fn resolveTimestamps(
    context: kernels.Context,
    set: *query.QuerySet,
    first_query: u32,
    query_count: u32,
    destination: kernels.BufferRange,
    quantize: bool,
) Error!void {
    const device = context.cache.native_device;
    if (!context.cache.enabled_features.isEnabled(.timestamp_query) or
        device.timestamp_valid_bits == 0)
    {
        return error.TimestampCapabilityUnavailable;
    }
    const constants = try decodePeriod(device.timestamp_period, device.timestamp_valid_bits, quantize);
    if (set.header.tracking != context.guard.objects) return error.ResourceDeviceMismatch;
    if (!set.header.node.linked or set.header.state != .alive or
        set.header.reference_count == 0)
    {
        return error.QuerySetDestroyed;
    }
    try set.validateCanUseInSubmit(context.guard);
    if (set.query_type != .timestamp) return error.QueryTypeMismatch;
    if (first_query > set.query_count or query_count > set.query_count - first_query) {
        return error.QueryIndexOutOfRange;
    }
    if (query_count > max_conversion_count) return error.TimestampRangeInvalid;
    try validateRange(context, destination, @as(u64, query_count) * 8);
    if (destination.offset % 256 != 0) return error.QueryResolveOffsetInvalid;
    if (!destination.owner.native.usage.query_resolve) {
        return error.InternalBufferUsageInvalid;
    }
    if (query_count == 0) return;
    try preflight(context);
    _ = try native_query.getPool(context.guard, set);
    const capacity = try windowCapacity(context);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &set.header);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &destination.owner.header);
    errdefer context.queue.poisonRecording();
    var completed: u32 = 0;
    while (completed < query_count) {
        const window_count = @min(capacity, query_count - completed);
        const window_bytes = @as(u64, window_count) * 8;
        const raw = try kernels.scratchBuffer(context, .{
            .size = window_bytes,
            .native_usage = buffer.read_only_storage_buffer | copy_destination_usage,
        });
        try kernels.transitionBuffer(context, raw, copy_destination_usage);
        try native_query.resolveQueries(context.recording.allocator, context.guard, context.queue, set, first_query + completed, window_count, raw.owner.native.handle, raw.offset);
        raw.owner.native.is_data_initialized = true;
        try convertWindow(context, raw, window_count, .{
            .owner = destination.owner,
            .offset = destination.offset + @as(u64, completed) * 8,
            .size = window_bytes,
        }, constants);
        completed += window_count;
    }
}
test "physical period decode preserves normal fractional and subnormal constants" {
    const unit = try decodePeriod(1.0, 64, false);
    try std.testing.expectEqual(@as(u32, 0x800000), unit.mantissa);
    try std.testing.expectEqual(@as(i32, -23), unit.binary_shift);
    try std.testing.expectEqualSlices(u32, &.{ 0xffffffff, 0xffffffff }, &unit.tick_mask);
    const fraction = try decodePeriod(1.5, 33, true);
    try std.testing.expectEqual(@as(u32, 0xc00000), fraction.mantissa);
    try std.testing.expectEqualSlices(u32, &.{ 0xffffffff, 1 }, &fraction.tick_mask);
    try std.testing.expectEqual(@as(u32, 0xffff0000), fraction.quantization_mask);
    const subnormal = try decodePeriod(@bitCast(@as(u32, 1)), 1, false);
    try std.testing.expectEqual(@as(u32, 1), subnormal.mantissa);
    try std.testing.expectEqual(@as(i32, -149), subnormal.binary_shift);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, &subnormal.tick_mask);
}

test "timestamp masks never shift by word width and invalid constants refuse" {
    for (1..65) |valid_bits| {
        const constants = try decodePeriod(1.0, @intCast(valid_bits), false);
        const expected: u64 = if (valid_bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(valid_bits))) - 1;
        const actual = @as(u64, constants.tick_mask[0]) |
            (@as(u64, constants.tick_mask[1]) << 32);
        try std.testing.expectEqual(expected, actual);
    }
    try std.testing.expectError(error.TimestampValidBitsInvalid, decodePeriod(1, 0, false));
    try std.testing.expectError(error.TimestampValidBitsInvalid, decodePeriod(1, 65, false));
    for ([_]u32{ 0, 0x80000000, 0xbf800000, 0x7f800000, 0x7fc00001 }) |bits| {
        try std.testing.expectError(error.TimestampPeriodInvalid, decodePeriod(@bitCast(bits), 64, false));
    }
}

test "timestamp parameter ABI encodes every word and zero padding" {
    const constants = try decodePeriod(1.5, 48, true);
    const encoded = constants.encode(17);
    const expected = [_]u32{ 17, 0xffffffff, 0xffff, 0xc00000, @bitCast(@as(i32, -23)), 0xffff0000, 0, 0 };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, std.mem.readInt(u32, encoded[index * 4 ..][0..4], .little));
    }
}

test "internal conversion constants reject malformed GPU uniform inputs" {
    const valid = try decodePeriod(1.0, 64, true);
    try valid.validate();
    var malformed = valid;
    malformed.mantissa = 0;
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    malformed = valid;
    malformed.mantissa = 0x1000000;
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    malformed = valid;
    malformed.binary_shift = -150;
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    malformed = valid;
    malformed.binary_shift = 105;
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    malformed = valid;
    malformed.tick_mask = .{ 0, 0 };
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    malformed = valid;
    malformed.tick_mask = .{ 0xfffffffd, 0 };
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    malformed = valid;
    malformed.quantization_mask = 0xfffffff0;
    try std.testing.expectError(error.TimestampConstantsInvalid, malformed.validate());
    for ([_]u32{ 0x007fffff, 0x00800000, 0x7f7fffff }) |bits| {
        const boundary = try decodePeriod(@bitCast(bits), 64, false);
        try boundary.validate();
    }
}
