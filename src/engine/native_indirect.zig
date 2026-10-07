//! GPU-only indirect argument sanitization. The supplied PendingUses owns all output ranges.

const std = @import("std");
const api = @import("../api/root.zig");
const buffer = @import("buffer.zig");
const kernels = @import("native_kernels.zig");

test "storage window preserves unaligned word offsets and limits" {
    const window = try storageWindow(.{
        .offset = 260,
        .size = 20,
        .buffer_size = 1024,
        .alignment = 256,
        .capacity = 256,
    });
    try std.testing.expectEqual(@as(u64, 256), window.offset);
    try std.testing.expectEqual(@as(u64, 24), window.size);
    try std.testing.expectEqual(@as(u32, 1), window.word_offset);
    try std.testing.expectError(error.KernelRangeOverflow, storageWindow(.{
        .offset = 508,
        .size = 20,
        .buffer_size = 1024,
        .alignment = 256,
        .capacity = 256,
    }));
}

test "storage window rejects overflow and allocation overrun before narrowing" {
    try std.testing.expectError(error.KernelRangeOverflow, storageWindow(.{
        .offset = std.math.maxInt(u64) - 3,
        .size = 20,
        .buffer_size = std.math.maxInt(u64),
        .alignment = 256,
        .capacity = 256,
    }));
    try std.testing.expectError(error.KernelRangeOverflow, storageWindow(.{
        .offset = 1000,
        .size = 32,
        .buffer_size = 1024,
        .alignment = 256,
        .capacity = 1024,
    }));
}

test "metadata words encode full selected index range without host layout" {
    var bytes: [32]u8 = undefined;
    encodeMetadata(&bytes, .{
        .input_word_offset = 3,
        .output_word_offset = 5,
        .index_element_count = 0x12345678_abcdef01,
        .flags = 7,
        .count_word_offset = 11,
        .ordinal = 13,
        .max_draw_count = 17,
    });
    try std.testing.expectEqual(@as(u32, 0xabcdef01), std.mem.readInt(u32, bytes[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, bytes[12..16], .little));
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, bytes[28..32], .little));
}

test "storage windows preserve offsets beyond four GiB and exact descriptor ends" {
    const offset: u64 = 0x1_0000_0104;
    const window = try storageWindow(.{
        .offset = offset,
        .size = 252,
        .buffer_size = offset + 252,
        .alignment = 256,
        .capacity = 256,
    });
    try std.testing.expectEqual(@as(u64, 0x1_0000_0100), window.offset);
    try std.testing.expectEqual(@as(u64, 256), window.size);
    try std.testing.expectEqual(@as(u32, 1), window.word_offset);
}

test "storage windows reject nonword offsets and nonword descriptor limits" {
    try std.testing.expectError(error.KernelRangeOverflow, storageWindow(.{
        .offset = 5,
        .size = 16,
        .buffer_size = 1024,
        .alignment = 256,
        .capacity = 256,
    }));
    try std.testing.expectError(error.KernelRangeOverflow, storageWindow(.{
        .offset = 4,
        .size = 16,
        .buffer_size = 1024,
        .alignment = 6,
        .capacity = 256,
    }));
}

pub const Error = kernels.Error || error{
    IndirectMetadataMismatch,
    IndirectCommandLimitExceeded,
};

pub const DrawInput = struct {
    command_index: u32,
    arguments: kernels.BufferRange,
    indexed: bool,
    max_draw_count: u32,
    count: ?kernels.BufferRange,
    index_element_count: u64,
};

pub const DrawOutput = struct {
    arguments: kernels.BufferRange,
    draw_count: u32,
    stride_bytes: u32,
};

pub const max_draw_slots: u32 = 1 << 24;
const metadata_capacity: u32 = 256;
const indirect_usage = (api.BufferUsage{ .indirect = true }).toFlags();
const copy_destination_usage = (api.BufferUsage{ .copy_dst = true }).toFlags();

const WindowOptions = struct {
    offset: u64,
    size: u64,
    buffer_size: u64,
    alignment: u64,
    capacity: u64,
};

const Window = struct {
    offset: u64,
    size: u64,
    word_offset: u32,
};

fn storageWindow(options: WindowOptions) error{KernelRangeOverflow}!Window {
    if (options.alignment == 0 or options.alignment % 4 != 0) {
        return error.KernelRangeOverflow;
    }
    if (options.offset % 4 != 0 or options.size == 0 or options.size % 4 != 0) {
        return error.KernelRangeOverflow;
    }
    if (options.offset > options.buffer_size or
        options.size > options.buffer_size - options.offset)
    {
        return error.KernelRangeOverflow;
    }
    const bound_offset = options.offset - options.offset % options.alignment;
    const delta = options.offset - bound_offset;
    const size = std.math.add(u64, delta, options.size) catch return error.KernelRangeOverflow;
    if (size > options.capacity or size / 4 > std.math.maxInt(u32)) {
        return error.KernelRangeOverflow;
    }
    return .{ .offset = bound_offset, .size = size, .word_offset = @intCast(delta / 4) };
}

const Metadata = struct {
    input_word_offset: u32,
    output_word_offset: u32,
    index_element_count: u64,
    flags: u32,
    count_word_offset: u32,
    ordinal: u32,
    max_draw_count: u32,
};

fn encodeMetadata(bytes: *[32]u8, metadata: Metadata) void {
    const words = [8]u32{
        metadata.input_word_offset,
        metadata.output_word_offset,
        @truncate(metadata.index_element_count),
        @truncate(metadata.index_element_count >> 32),
        metadata.flags,
        metadata.count_word_offset,
        metadata.ordinal,
        metadata.max_draw_count,
    };
    inline for (words, 0..) |word, index| {
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
    }
}

const Caps = struct {
    storage_bytes: u64,
    buffer_bytes: u64,
    alignment: u64,
    dispatch: [3]u32,
    first_instance: bool,
};

fn actualCaps(context: kernels.Context) Error!Caps {
    const physical = context.cache.native_device.physical.properties.limits;
    const effective = context.cache.limits.v1;
    const storage_bytes = @min(
        physical.maxStorageBufferRange,
        effective.max_storage_buffer_binding_size,
    );
    const alignment = @max(
        @as(u64, 4),
        @max(physical.minStorageBufferOffsetAlignment, effective.min_storage_buffer_offset_alignment),
    );
    if (storage_bytes < 12 or alignment % 4 != 0) return error.KernelRangeOverflow;
    var dispatch: [3]u32 = undefined;
    for (&dispatch, 0..) |*value, axis| {
        value.* = @min(
            physical.maxComputeWorkGroupCount[axis],
            effective.max_compute_workgroups_per_dimension,
        );
        if (value.* == 0) return error.KernelDispatchLimitExceeded;
    }
    return .{
        .storage_bytes = storage_bytes,
        .buffer_bytes = @min(context.cache.resource_device.buffer_device.max_buffer_size, effective.max_buffer_size),
        .alignment = alignment,
        .dispatch = dispatch,
        .first_instance = context.cache.enabled_features.isEnabled(.indirect_first_instance),
    };
}

fn strideBytes(indexed: bool) u32 {
    return if (indexed) 20 else 16;
}

fn validateRange(
    context: kernels.Context,
    range: kernels.BufferRange,
    required_size: u64,
) Error!void {
    const header = &range.owner.header;
    if (header.tracking != context.guard.objects) return error.ResourceDeviceMismatch;
    context.guard.assertOwns(header.tracking);
    if (!header.node.linked or header.state != .alive) return error.ResourceDestroyed;
    if (header.kind != .native_buffer) return error.ResourceDeviceMismatch;
    if (range.offset % 4 != 0 or range.size % 4 != 0 or
        required_size > range.size or range.offset > range.owner.native.size or
        range.size > range.owner.native.size - range.offset)
    {
        return error.KernelRangeOverflow;
    }
}

fn sameGroup(left: DrawInput, right: DrawInput) bool {
    if (left.indexed != right.indexed or left.arguments.owner != right.arguments.owner) {
        return false;
    }
    if (left.count) |count| {
        return if (right.count) |other| count.owner == other.owner else false;
    }
    return right.count == null;
}

/// Writes every output slot. Caller arguments and counts remain GPU-only inputs.
pub fn sanitizeDraws(
    context: kernels.Context,
    inputs: []const DrawInput,
    outputs: []DrawOutput,
) Error!void {
    if (inputs.len != outputs.len) return error.IndirectMetadataMismatch;
    if (inputs.len > max_draw_slots) return error.IndirectCommandLimitExceeded;
    if (inputs.len == 0) return;
    const caps = try actualCaps(context);
    var total_slots: u64 = 0;
    for (inputs, 0..) |input, index| {
        if (input.command_index != index) return error.IndirectMetadataMismatch;
        total_slots = std.math.add(u64, total_slots, input.max_draw_count) catch
            return error.IndirectCommandLimitExceeded;
        if (total_slots > max_draw_slots) return error.IndirectCommandLimitExceeded;
        const size = @as(u64, input.max_draw_count) * strideBytes(input.indexed);
        try validateRange(context, input.arguments, size);
        if (size > caps.buffer_bytes) return error.KernelRangeOverflow;
        if (input.count) |count| {
            if (count.size != 4) return error.KernelRangeOverflow;
            try validateRange(context, count, 4);
        }
    }
    const allocator = context.queue.context.allocator;
    const prepared = try allocator.alloc(DrawOutput, inputs.len);
    defer allocator.free(prepared);
    var emitted = false;
    errdefer if (emitted) context.queue.poisonRecording();
    var first: usize = 0;
    while (first < inputs.len) {
        const stride = strideBytes(inputs[first].indexed);
        var end = first;
        var size: u64 = 0;
        while (end < inputs.len and sameGroup(inputs[first], inputs[end])) : (end += 1) {
            const next_size = size + @as(u64, inputs[end].max_draw_count) * stride;
            if (next_size > caps.buffer_bytes) break;
            size = next_size;
        }
        std.debug.assert(end > first);
        const output = try kernels.scratchBuffer(context, .{
            .size = @max(size, stride),
            .native_usage = buffer.internal_storage_buffer | indirect_usage |
                buffer.internal_copy_src_buffer | copy_destination_usage,
        });
        var offset: u64 = 0;
        for (inputs[first..end], prepared[first..end]) |input, *result| {
            const byte_count = @as(u64, input.max_draw_count) * stride;
            result.* = .{
                .arguments = .{ .owner = output.owner, .offset = offset, .size = byte_count },
                .draw_count = input.max_draw_count,
                .stride_bytes = stride,
            };
            offset += byte_count;
        }
        if (size != 0) {
            try recordGroup(context, caps, inputs[first..end], prepared[first..end], &emitted);
            try kernels.transitionBuffer(context, output, indirect_usage);
        }
        first = end;
    }
    @memcpy(outputs, prepared);
}

fn rangeWindow(
    range: kernels.BufferRange,
    offset: u64,
    size: u64,
    caps: Caps,
) error{KernelRangeOverflow}!Window {
    return storageWindow(.{
        .offset = offset,
        .size = size,
        .buffer_size = range.owner.native.size,
        .alignment = caps.alignment,
        .capacity = caps.storage_bytes,
    });
}

fn extendWindow(window: *Window, offset: u64, size: u64, caps: Caps) bool {
    if (offset < window.offset) return false;
    const delta = offset - window.offset;
    if (delta > caps.storage_bytes or size > caps.storage_bytes - delta) return false;
    window.size = @max(window.size, delta + size);
    return true;
}

fn boundRange(owner: kernels.BufferRange, window: Window) kernels.BufferRange {
    return .{ .owner = owner.owner, .offset = window.offset, .size = window.size };
}

fn recordGroup(
    context: kernels.Context,
    caps: Caps,
    inputs: []const DrawInput,
    outputs: []const DrawOutput,
    emitted: *bool,
) Error!void {
    const slot_capacity: u32 = @intCast(@min(
        metadata_capacity,
        @min(@min(caps.storage_bytes, caps.buffer_bytes) / 32, @as(u64, caps.dispatch[0]) * 64),
    ));
    if (slot_capacity == 0) return error.KernelRangeOverflow;
    const metadata_range = try kernels.scratchBuffer(context, .{
        .size = @as(u64, slot_capacity) * 32,
        .native_usage = buffer.read_only_storage_buffer | copy_destination_usage,
    });
    var metadata_bytes: [metadata_capacity * 32]u8 = undefined;
    var input_index: usize = 0;
    var ordinal: u32 = 0;
    const stride = strideBytes(inputs[0].indexed);
    while (input_index < inputs.len) {
        if (ordinal == inputs[input_index].max_draw_count) {
            input_index += 1;
            ordinal = 0;
            continue;
        }
        const first_input = inputs[input_index];
        const argument_offset = first_input.arguments.offset + @as(u64, ordinal) * stride;
        const output_offset = outputs[input_index].arguments.offset + @as(u64, ordinal) * stride;
        const arguments_candidate: ?Window =
            rangeWindow(first_input.arguments, argument_offset, stride, caps) catch null;
        const output_candidate: ?Window =
            rangeWindow(outputs[input_index].arguments, output_offset, stride, caps) catch null;
        const count_candidate: ?Window = if (first_input.count) |count|
            rangeWindow(count, count.offset, 4, caps) catch null
        else
            arguments_candidate;
        if (arguments_candidate == null or output_candidate == null or count_candidate == null) {
            emitted.* = true;
            ordinal += try recordStagedDraws(context, caps, .{
                .input = first_input,
                .output = outputs[input_index],
                .ordinal = ordinal,
                .slot_capacity = slot_capacity,
            }, metadata_range, &metadata_bytes);
            continue;
        }
        var argument_window = arguments_candidate.?;
        var output_window = output_candidate.?;
        var count_window = count_candidate.?;
        var record_count: u32 = 0;
        while (input_index < inputs.len and record_count < slot_capacity) {
            const input = inputs[input_index];
            if (ordinal == input.max_draw_count) {
                input_index += 1;
                ordinal = 0;
                continue;
            }
            const source_offset = input.arguments.offset + @as(u64, ordinal) * stride;
            const destination_offset = outputs[input_index].arguments.offset +
                @as(u64, ordinal) * stride;
            var candidate_arguments = argument_window;
            var candidate_output = output_window;
            var candidate_count = count_window;
            if (!extendWindow(&candidate_arguments, source_offset, stride, caps) or
                !extendWindow(&candidate_output, destination_offset, stride, caps))
            {
                break;
            }
            if (input.count) |count| {
                if (!extendWindow(&candidate_count, count.offset, 4, caps)) break;
            }
            argument_window = candidate_arguments;
            output_window = candidate_output;
            count_window = candidate_count;
            const flags: u32 = @as(u32, @intFromBool(input.indexed)) |
                (@as(u32, @intFromBool(input.count != null)) << 1) |
                (@as(u32, @intFromBool(caps.first_instance)) << 2);
            encodeMetadata(metadata_bytes[record_count * 32 ..][0..32], .{
                .input_word_offset = @intCast((source_offset - argument_window.offset) / 4),
                .output_word_offset = @intCast((destination_offset - output_window.offset) / 4),
                .index_element_count = input.index_element_count,
                .flags = flags,
                .count_word_offset = if (input.count) |count|
                    @intCast((count.offset - count_window.offset) / 4)
                else
                    0,
                .ordinal = ordinal,
                .max_draw_count = input.max_draw_count,
            });
            record_count += 1;
            ordinal += 1;
        }
        std.debug.assert(record_count != 0);
        emitted.* = true;
        try kernels.uploadParameters(context, .{
            .owner = metadata_range.owner,
            .offset = 0,
            .size = @as(u64, record_count) * 32,
        }, metadata_bytes[0 .. record_count * 32]);
        var parameters: [32]u8 = @splat(0);
        std.mem.writeInt(u32, parameters[0..4], record_count, .little);
        const arguments = boundRange(first_input.arguments, argument_window);
        const counts = if (first_input.count) |count|
            boundRange(count, count_window)
        else
            arguments;
        const bindings = [_]kernels.Binding{
            .{ .buffer = arguments },
            .{ .buffer = counts },
            .{ .buffer = metadata_range },
            .{ .buffer = boundRange(outputs[0].arguments, output_window) },
        };
        try kernels.recordCompute(context, .{
            .key = .{ .id = .sanitize_draws },
            .bindings = &bindings,
            .parameters = &parameters,
            .workgroups = .{ std.math.divCeil(u32, record_count, 64) catch
                return error.KernelRangeOverflow, 1, 1 },
        });
    }
}

/// Runs at the dispatch command position, after any earlier caller storage writes.
pub fn sanitizeDispatch(
    context: kernels.Context,
    arguments: kernels.BufferRange,
) Error!kernels.BufferRange {
    try validateRange(context, arguments, 12);
    const caps = try actualCaps(context);
    errdefer context.queue.poisonRecording();
    const source = try readableWindow(context, caps, .{
        .owner = arguments.owner,
        .offset = arguments.offset,
        .size = 12,
    });
    const output = try kernels.scratchBuffer(context, .{
        .size = 12,
        .native_usage = buffer.internal_storage_buffer | indirect_usage |
            buffer.internal_copy_src_buffer,
    });
    var parameters: [16]u8 = undefined;
    std.mem.writeInt(u32, parameters[0..4], source.word_offset, .little);
    inline for (0..3) |axis| {
        std.mem.writeInt(u32, parameters[4 + axis * 4 ..][0..4], caps.dispatch[axis], .little);
    }
    const bindings = [_]kernels.Binding{
        .{ .buffer = source.range },
        .{ .buffer = output },
    };
    try kernels.recordCompute(context, .{
        .key = .{ .id = .sanitize_dispatch },
        .bindings = &bindings,
        .parameters = &parameters,
        .workgroups = .{ 1, 1, 1 },
    });
    try kernels.transitionBuffer(context, output, indirect_usage);
    return output;
}

const ReadableWindow = struct {
    range: kernels.BufferRange,
    word_offset: u32,
};

fn readableWindow(
    context: kernels.Context,
    caps: Caps,
    source: kernels.BufferRange,
) Error!ReadableWindow {
    if (rangeWindow(source, source.offset, source.size, caps)) |window| {
        return .{ .range = boundRange(source, window), .word_offset = window.word_offset };
    } else |_| {
        if (source.size > caps.storage_bytes or source.size > caps.buffer_bytes) {
            return error.KernelRangeOverflow;
        }
        const staged = try kernels.scratchBuffer(context, .{
            .size = source.size,
            .native_usage = buffer.read_only_storage_buffer | copy_destination_usage,
        });
        try kernels.copyBuffer(context, source, staged);
        return .{ .range = staged, .word_offset = 0 };
    }
}

const StagedDraws = struct {
    input: DrawInput,
    output: DrawOutput,
    ordinal: u32,
    slot_capacity: u32,
};

// A native transfer gathers records whose words cannot share one aligned descriptor window.
fn recordStagedDraws(
    context: kernels.Context,
    caps: Caps,
    command: StagedDraws,
    metadata_range: kernels.BufferRange,
    metadata_bytes: *[metadata_capacity * 32]u8,
) Error!u32 {
    const stride = strideBytes(command.input.indexed);
    const record_count = @min(command.slot_capacity, command.input.max_draw_count - command.ordinal);
    const size = @as(u64, record_count) * stride;
    if (size > caps.storage_bytes or size > caps.buffer_bytes) return error.KernelRangeOverflow;
    const staged_input = try kernels.scratchBuffer(context, .{
        .size = size,
        .native_usage = buffer.read_only_storage_buffer | copy_destination_usage,
    });
    const staged_output = try kernels.scratchBuffer(context, .{
        .size = size,
        .native_usage = buffer.internal_storage_buffer | buffer.internal_copy_src_buffer,
    });
    try kernels.copyBuffer(context, .{
        .owner = command.input.arguments.owner,
        .offset = command.input.arguments.offset + @as(u64, command.ordinal) * stride,
        .size = size,
    }, staged_input);
    const count = if (command.input.count) |range|
        try readableWindow(context, caps, range)
    else
        ReadableWindow{ .range = staged_input, .word_offset = 0 };
    const flags: u32 = @as(u32, @intFromBool(command.input.indexed)) |
        (@as(u32, @intFromBool(command.input.count != null)) << 1) |
        (@as(u32, @intFromBool(caps.first_instance)) << 2);
    for (0..record_count) |index| {
        encodeMetadata(metadata_bytes[index * 32 ..][0..32], .{
            .input_word_offset = @intCast(index * @divExact(stride, 4)),
            .output_word_offset = @intCast(index * @divExact(stride, 4)),
            .index_element_count = command.input.index_element_count,
            .flags = flags,
            .count_word_offset = count.word_offset,
            .ordinal = command.ordinal + @as(u32, @intCast(index)),
            .max_draw_count = command.input.max_draw_count,
        });
    }
    try kernels.uploadParameters(context, .{
        .owner = metadata_range.owner,
        .offset = 0,
        .size = @as(u64, record_count) * 32,
    }, metadata_bytes[0 .. record_count * 32]);
    var parameters: [32]u8 = @splat(0);
    std.mem.writeInt(u32, parameters[0..4], record_count, .little);
    const bindings = [_]kernels.Binding{
        .{ .buffer = staged_input },
        .{ .buffer = count.range },
        .{ .buffer = metadata_range },
        .{ .buffer = staged_output },
    };
    try kernels.recordCompute(context, .{
        .key = .{ .id = .sanitize_draws },
        .bindings = &bindings,
        .parameters = &parameters,
        .workgroups = .{ std.math.divCeil(u32, record_count, 64) catch
            return error.KernelRangeOverflow, 1, 1 },
    });
    try kernels.copyBuffer(context, staged_output, .{
        .owner = command.output.arguments.owner,
        .offset = command.output.arguments.offset + @as(u64, command.ordinal) * stride,
        .size = size,
    });
    return record_count;
}
