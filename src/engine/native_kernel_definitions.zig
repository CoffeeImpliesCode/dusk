const std = @import("std");
const api = @import("../api/root.zig");
const attachment_state = @import("../command/attachment_state.zig");
const sampler = @import("sampler.zig");

pub const KernelId = enum {
    sanitize_draws,
    sanitize_dispatch,
    timestamp_to_nanoseconds,
    texture_to_buffer,
    buffer_to_color,
    buffer_to_depth,
    buffer_to_stencil,
    color_to_color,
    depth_to_depth,
    clear_color,
    external_to_color,
    buffer_row_merge,
};

pub const KernelKey = struct {
    id: KernelId,
    source_format: api.TextureFormat = .undefined_,
    source_dimension: api.TextureViewDimension = .undefined_,
    source_multisampled: bool = false,
    storage_format: api.TextureFormat = .undefined_,
    attachments: ?*attachment_state.CanonicalAttachmentState = null,
    color_write_slots: u8 = 0,
    stencil_write_bit: ?u3 = null,
    conversion_sampler: ?*sampler.Sampler = null,
};

pub const BufferAccess = enum { uniform, storage_read, storage_write };
pub const Slot = union(enum) {
    buffer: struct { access: BufferAccess, min_size: u32 },
    sampled_view: struct {
        dimension: api.TextureViewDimension,
        sample_type: api.TextureSampleType,
        multisampled: bool,
        depth_view: bool = false,
    },
    storage_view: struct { format: api.TextureFormat },
    sampler: struct { comparison: bool },
    combined_y_cb_cr_view,
};
pub const Stage = struct { words: []const u32, entry_point: [:0]const u8 };
pub const ScalarKind = enum { float, sint, uint };

test "color scalar types exclude depth and compressed attachment formats" {
    try std.testing.expectEqual(ScalarKind.float, try colorScalarKind(@intFromEnum(api.TextureFormat.rgba8_unorm)));
    try std.testing.expectEqual(ScalarKind.sint, try colorScalarKind(@intFromEnum(api.TextureFormat.rgba32_sint)));
    try std.testing.expectEqual(ScalarKind.uint, try colorScalarKind(@intFromEnum(api.TextureFormat.rgb10_a2_uint)));
    try std.testing.expectError(error.InvalidKernelKey, colorScalarKind(@intFromEnum(api.TextureFormat.depth32_float)));
    try std.testing.expectError(error.InvalidKernelKey, colorScalarKind(@intFromEnum(api.TextureFormat.bc1_rgba_unorm)));
}

pub fn colorScalarKind(format_value: u32) error{InvalidKernelKey}!ScalarKind {
    const format = std.enums.fromInt(api.TextureFormat, format_value) orelse
        return error.InvalidKernelKey;
    return switch (format) {
        .r8_uint, .r16_uint, .rg8_uint, .r32_uint, .rg16_uint, .rgba8_uint, .rgb10_a2_uint, .rg32_uint, .rgba16_uint, .rgba32_uint => .uint,
        .r8_sint, .r16_sint, .rg8_sint, .r32_sint, .rg16_sint, .rgba8_sint, .rg32_sint, .rgba16_sint, .rgba32_sint => .sint,
        .r8_unorm, .r8_snorm, .r16_unorm, .r16_snorm, .r16_float, .rg8_unorm, .rg8_snorm, .r32_float, .rg16_unorm, .rg16_snorm, .rg16_float, .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_snorm, .bgra8_unorm, .bgra8_unorm_srgb, .rgb10_a2_unorm, .rg11_b10_ufloat, .rgb9_e5_ufloat, .rg32_float, .rgba16_unorm, .rgba16_snorm, .rgba16_float, .rgba32_float => .float,
        else => error.InvalidKernelKey,
    };
}
pub const FixedState = struct {
    color_scalar_kinds: [8]ScalarKind = @splat(.float),
    depth_output: bool = false,
    stencil_replace: bool = false,
};
pub const Definition = struct {
    slots: []const Slot,
    parameter_size: u32,
    depth_range_push_constants: bool = false,
    stages: union(enum) {
        compute: struct { stage: Stage, workgroup_size: [3]u32 },
        render: struct {
            vertex: Stage,
            fragment: Stage,
            fixed_state: FixedState = .{},
        },
    },
};

const fullscreen_words = words(@embedFile("shaders/fullscreen.vert.spv"));
pub const fullscreen_vertex: Stage = .{ .words = &fullscreen_words, .entry_point = "main" };
pub const external_ycbcr_fragment: Stage =
    @import("native_external_shader_definitions.zig").fragment(@This(), true);
pub const external_ordinary_fragment: Stage =
    @import("native_external_shader_definitions.zig").fragment(@This(), false);

pub fn eql(left: KernelKey, right: KernelKey) bool {
    return left.id == right.id and
        left.source_format == right.source_format and
        left.source_dimension == right.source_dimension and
        left.source_multisampled == right.source_multisampled and
        left.storage_format == right.storage_format and
        left.attachments == right.attachments and
        left.color_write_slots == right.color_write_slots and
        left.stencil_write_bit == right.stencil_write_bit and
        left.conversion_sampler == right.conversion_sampler;
}

/// Device, guard and payload liveness validation belongs to the borrowed recorder.
pub fn validateKey(key: KernelKey) error{InvalidKernelKey}!void {
    switch (key.id) {
        .sanitize_draws, .sanitize_dispatch, .timestamp_to_nanoseconds, .buffer_row_merge => {
            if (key.source_format != .undefined_ or key.source_dimension != .undefined_ or
                key.source_multisampled or key.storage_format != .undefined_ or
                key.attachments != null or key.color_write_slots != 0 or
                key.stencil_write_bit != null or key.conversion_sampler != null)
            {
                return error.InvalidKernelKey;
            }
        },
        .texture_to_buffer => {
            if (key.attachments != null or key.color_write_slots != 0 or
                key.stencil_write_bit != null or key.conversion_sampler != null or
                key.source_format == .undefined_ or key.source_dimension == .undefined_ or
                key.storage_format == .undefined_)
            {
                return error.InvalidKernelKey;
            }
        },
        else => {
            const attachments = key.attachments orelse return error.InvalidKernelKey;
            const value = &attachments.value;
            value.validateCanonical() catch return error.InvalidKernelKey;
            if (value.has_pls or value.expand_resolve.attachments_to_expand_resolve != 0)
                return error.InvalidKernelKey;
            if (key.storage_format != .undefined_ and key.id != .buffer_to_color and
                key.id != .buffer_to_depth and key.id != .buffer_to_stencil and
                key.id != .color_to_color) return error.InvalidKernelKey;
            if (key.color_write_slots & ~value.color_attachments_set != 0)
                return error.InvalidKernelKey;
            if (key.id != .external_to_color and key.conversion_sampler != null)
                return error.InvalidKernelKey;
            if (key.id != .buffer_to_stencil and key.stencil_write_bit != null)
                return error.InvalidKernelKey;
            if (key.id == .buffer_to_color or key.id == .buffer_to_depth or
                key.id == .buffer_to_stencil)
            {
                if (key.source_format != .undefined_ or
                    key.source_dimension != .undefined_ or key.source_multisampled or
                    key.storage_format == .undefined_) return error.InvalidKernelKey;
            }
            if (key.id == .color_to_color or key.id == .depth_to_depth) {
                if (key.source_format == .undefined_) return error.InvalidKernelKey;
                if (key.source_dimension == .undefined_) {
                    if (key.id != .color_to_color or key.source_multisampled or
                        (key.storage_format != .rgba32_float and
                            key.storage_format != .rgba32_uint and
                            key.storage_format != .rgba32_sint))
                        return error.InvalidKernelKey;
                } else if (key.storage_format != .undefined_) return error.InvalidKernelKey;
            }
            switch (key.id) {
                .buffer_to_depth, .depth_to_depth => {
                    if (key.color_write_slots != 0 or !hasDepth(value.depth_stencil_format))
                        return error.InvalidKernelKey;
                },
                .buffer_to_stencil => {
                    if (key.color_write_slots != 0 or key.stencil_write_bit == null or
                        !hasStencil(value.depth_stencil_format))
                        return error.InvalidKernelKey;
                },
                .buffer_to_color, .color_to_color, .clear_color => {
                    if (@popCount(key.color_write_slots) != 1)
                        return error.InvalidKernelKey;
                },
                .external_to_color => {
                    if (key.source_format != .undefined_ or
                        key.source_dimension != .undefined_ or key.source_multisampled or
                        key.color_write_slots != 1)
                    {
                        return error.InvalidKernelKey;
                    }
                },
                else => return error.InvalidKernelKey,
            }
            if (key.id == .clear_color) {
                if (key.source_format != .undefined_ or
                    key.source_dimension != .undefined_ or key.source_multisampled)
                {
                    return error.InvalidKernelKey;
                }
            }
        },
    }
}

fn hasDepth(format: u32) bool {
    return format == @intFromEnum(api.TextureFormat.depth16_unorm) or
        format == @intFromEnum(api.TextureFormat.depth24_plus) or
        format == @intFromEnum(api.TextureFormat.depth32_float) or
        format == @intFromEnum(api.TextureFormat.depth24_plus_stencil8) or
        format == @intFromEnum(api.TextureFormat.depth32_float_stencil8);
}

fn hasStencil(format: u32) bool {
    return format == @intFromEnum(api.TextureFormat.stencil8) or
        format == @intFromEnum(api.TextureFormat.depth24_plus_stencil8) or
        format == @intFromEnum(api.TextureFormat.depth32_float_stencil8);
}

pub fn definition(key: KernelKey) error{InvalidKernelKey}!*const Definition {
    try validateKey(key);
    return switch (key.id) {
        .sanitize_draws, .sanitize_dispatch => @import("native_indirect_shader_definition.zig").definition(@This(), key),
        .timestamp_to_nanoseconds => @import("native_timestamp_shader_definition.zig").definition(@This(), key),
        .external_to_color => @import("native_external_shader_definitions.zig").definition(@This(), key),
        .texture_to_buffer, .buffer_to_color, .buffer_to_depth, .buffer_to_stencil, .color_to_color, .depth_to_depth, .clear_color, .buffer_row_merge => @import("native_blit_shader_definitions.zig").definition(@This(), key),
    };
}

pub fn words(comptime bytes: []const u8) [bytes.len / 4]u32 {
    @setEvalBranchQuota(bytes.len * 8 + 1000);
    if (bytes.len % 4 != 0) @compileError("Native SPIR-V bytes must contain whole words");
    var result: [bytes.len / 4]u32 = undefined;
    for (&result, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    return result;
}

test "private depth range requires the exact two-word raw unsigned array ABI" {
    const fixture = [_]u32{
        0x07230203, 0x00010000, 0,          7,          0,
        0x00040015, 1,          32,         0,          0x0004002b,
        1,          2,          2,          0x0004001c, 3,
        1,          2,          0x0003001e, 4,          3,
        0x00040020, 5,          9,          4,          0x0004003b,
        5,          6,          9,          0x00030047, 4,
        2,          0x00040047, 3,          6,          4,
        0x00050048, 4,          0,          35,         0,
    };
    try std.testing.expect(privateDepthRangeVerified(&fixture));
    var wrong_offset = fixture;
    wrong_offset[39] = 4;
    try std.testing.expect(!privateDepthRangeVerified(&wrong_offset));
    var wrong_stride = fixture;
    wrong_stride[34] = 8;
    try std.testing.expect(!privateDepthRangeVerified(&wrong_stride));
    var wrong_length = fixture;
    wrong_length[12] = 3;
    try std.testing.expect(!privateDepthRangeVerified(&wrong_length));
    var signed_type = fixture;
    signed_type[8] = 1;
    try std.testing.expect(!privateDepthRangeVerified(&signed_type));
    var wrong_width = fixture;
    wrong_width[7] = 64;
    try std.testing.expect(!privateDepthRangeVerified(&wrong_width));
    try std.testing.expect(!privateDepthRangeVerified(fixture[0 .. fixture.len - 1]));
    const false_float_structure = [_]u32{
        0x07230203, 0x00010000, 0,          6,          0,
        0x00030016, 1,          32,         0x0004001e, 2,
        1,          1,          0x00040020, 3,          9,
        2,          0x0004003b, 3,          4,          9,
        0x00030047, 2,          2,          0x00050048, 2,
        0,          35,         0,          0x00050048, 2,
        1,          35,         4,
    };
    try std.testing.expect(!privateDepthRangeVerified(&false_float_structure));
}

pub fn depthWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    @setEvalBranchQuota(bytes.len * 32 + 1000);
    const result = words(bytes);
    if (!privateDepthRangeVerified(&result)) {
        @compileError("Native depth shader must expose an offset-zero u32[2] block with stride 4");
    }
    return result;
}

/// This checks only the finite internal artifact ABI. It does not transform words.
pub fn privateDepthRangeVerified(shader_words: []const u32) bool {
    if (shader_words.len < 5 or shader_words[0] != 0x07230203) return false;
    var pointer_id: u32 = 0;
    var variable_count: u32 = 0;
    var offset: usize = 5;
    for (0..shader_words.len) |_| {
        if (offset == shader_words.len) break;
        const count = shader_words[offset] >> 16;
        if (count == 0 or count > shader_words.len - offset) return false;
        const instruction = shader_words[offset..][0..count];
        if (instruction[0] & 0xffff == 59 and count >= 4 and instruction[3] == 9) {
            pointer_id = instruction[1];
            variable_count += 1;
        }
        offset += count;
    }
    if (offset != shader_words.len or variable_count != 1) return false;
    const pointer = findInstruction(shader_words, 32, pointer_id) orelse return false;
    if (pointer.len != 4 or pointer[2] != 9) return false;
    const structure_id = pointer[3];
    const structure = findInstruction(shader_words, 30, structure_id) orelse return false;
    if (structure.len != 3) return false;
    const array_id = structure[2];
    const array = findInstruction(shader_words, 28, array_id) orelse return false;
    if (array.len != 4) return false;
    const unsigned_type = findInstruction(shader_words, 21, array[2]) orelse return false;
    if (unsigned_type.len != 4 or unsigned_type[2] != 32 or unsigned_type[3] != 0)
        return false;
    const length = findConstant(shader_words, array[3]) orelse return false;
    if (length.len != 4 or length[1] != array[2] or length[3] != 2) return false;
    var block: bool = false;
    var member_offset: ?u32 = null;
    var array_stride: ?u32 = null;
    offset = 5;
    for (0..shader_words.len) |_| {
        if (offset == shader_words.len) break;
        const count = shader_words[offset] >> 16;
        const instruction = shader_words[offset..][0..count];
        const opcode = instruction[0] & 0xffff;
        if (opcode == 71 and count == 3 and instruction[1] == structure_id and
            instruction[2] == 2)
        {
            if (block) return false;
            block = true;
        }
        if (opcode == 71 and count == 4 and instruction[1] == array_id and
            instruction[2] == 6)
        {
            if (array_stride != null) return false;
            array_stride = instruction[3];
        }
        if (opcode == 72 and count == 5 and instruction[1] == structure_id and
            instruction[3] == 35)
        {
            if (instruction[2] != 0 or member_offset != null) return false;
            member_offset = instruction[4];
        }
        offset += count;
    }
    return block and member_offset == 0 and array_stride == 4;
}

fn findInstruction(shader_words: []const u32, opcode: u16, result_id: u32) ?[]const u32 {
    var offset: usize = 5;
    for (0..shader_words.len) |_| {
        if (offset == shader_words.len) return null;
        const count = shader_words[offset] >> 16;
        if (count == 0 or count > shader_words.len - offset) return null;
        const instruction = shader_words[offset..][0..count];
        if (count >= 2 and instruction[0] & 0xffff == opcode and
            instruction[1] == result_id) return instruction;
        offset += count;
    }
    return null;
}

fn findConstant(shader_words: []const u32, result_id: u32) ?[]const u32 {
    var offset: usize = 5;
    for (0..shader_words.len) |_| {
        if (offset == shader_words.len) return null;
        const count = shader_words[offset] >> 16;
        if (count == 0 or count > shader_words.len - offset) return null;
        const instruction = shader_words[offset..][0..count];
        if (count == 4 and instruction[0] & 0xffff == 43 and
            instruction[2] == result_id) return instruction;
        offset += count;
    }
    return null;
}

// The tests name the finite key contract before any shader is generated.
test "compute keys reject every unused semantic field" {
    const canonical: KernelKey = .{ .id = .sanitize_draws };
    try validateKey(canonical);
    var key = canonical;
    key.source_format = .rgba8_unorm;
    try std.testing.expectError(error.InvalidKernelKey, validateKey(key));
    key = canonical;
    key.source_dimension = ._2d;
    try std.testing.expectError(error.InvalidKernelKey, validateKey(key));
    key = canonical;
    key.source_multisampled = true;
    try std.testing.expectError(error.InvalidKernelKey, validateKey(key));
    key = canonical;
    key.storage_format = .rgba8_unorm;
    try std.testing.expectError(error.InvalidKernelKey, validateKey(key));
    key = canonical;
    key.color_write_slots = 1;
    try std.testing.expectError(error.InvalidKernelKey, validateKey(key));
    key = canonical;
    key.stencil_write_bit = 0;
    try std.testing.expectError(error.InvalidKernelKey, validateKey(key));
}

test "render definitions require an actual attachment owner" {
    inline for (.{ KernelId.buffer_to_color, .buffer_to_depth, .buffer_to_stencil, .color_to_color, .depth_to_depth, .clear_color, .external_to_color }) |id| {
        try std.testing.expectError(error.InvalidKernelKey, validateKey(.{ .id = id }));
    }
}

test "key equality compares named values without padding" {
    const canonical: KernelKey = .{ .id = .sanitize_draws };
    try std.testing.expect(eql(canonical, canonical));
    var key = canonical;
    key.id = .sanitize_dispatch;
    try std.testing.expect(!eql(canonical, key));
    key = canonical;
    key.source_format = .rgba8_unorm;
    try std.testing.expect(!eql(canonical, key));
    key = canonical;
    key.source_dimension = ._2d;
    try std.testing.expect(!eql(canonical, key));
    key = canonical;
    key.source_multisampled = true;
    try std.testing.expect(!eql(canonical, key));
    key = canonical;
    key.storage_format = .rgba8_unorm;
    try std.testing.expect(!eql(canonical, key));
    key = canonical;
    key.color_write_slots = 1;
    try std.testing.expect(!eql(canonical, key));
    key = canonical;
    key.stencil_write_bit = 1;
    try std.testing.expect(!eql(canonical, key));
}

test "static SPIRV decode preserves little endian words and alignment" {
    const decoded = comptime words(&.{ 3, 2, 35, 7, 4, 3, 2, 1 });
    try std.testing.expectEqual(@as(u32, 0x07230203), decoded[0]);
    try std.testing.expectEqual(@as(u32, 0x01020304), decoded[1]);
    try std.testing.expect(@alignOf(@TypeOf(decoded)) >= @alignOf(u32));
}

test "every baseline compute definition has its exact finite parameter ABI" {
    const Case = struct {
        id: KernelId,
        slots: usize,
        parameter_size: u32,
        workgroup_x: u32,
    };
    const cases = [_]Case{
        .{ .id = .sanitize_draws, .slots = 4, .parameter_size = 32, .workgroup_x = 64 },
        .{ .id = .sanitize_dispatch, .slots = 2, .parameter_size = 16, .workgroup_x = 1 },
        .{ .id = .timestamp_to_nanoseconds, .slots = 2, .parameter_size = 32, .workgroup_x = 8 },
        .{ .id = .buffer_row_merge, .slots = 3, .parameter_size = 32, .workgroup_x = 64 },
    };
    for (cases) |case| {
        const selected = try definition(.{ .id = case.id });
        try std.testing.expectEqual(case.slots, selected.slots.len);
        try std.testing.expectEqual(case.parameter_size, selected.parameter_size);
        try std.testing.expect(!selected.depth_range_push_constants);
        try std.testing.expectEqual(case.workgroup_x, selected.stages.compute.workgroup_size[0]);
        try std.testing.expectEqual(@as(u32, 1), selected.stages.compute.workgroup_size[1]);
        try std.testing.expectEqual(@as(u32, 1), selected.stages.compute.workgroup_size[2]);
        try std.testing.expectEqual(@as(u32, 0x07230203), selected.stages.compute.stage.words[0]);
    }
}

test "committed timestamp shader requires neither Int64 nor Float64" {
    const selected = try definition(.{ .id = .timestamp_to_nanoseconds });
    const shader_words = selected.stages.compute.stage.words;
    var offset: usize = 5;
    for (0..shader_words.len) |_| {
        if (offset == shader_words.len) break;
        const count = shader_words[offset] >> 16;
        try std.testing.expect(count != 0);
        try std.testing.expect(count <= shader_words.len - offset);
        if (shader_words[offset] & 0xffff == 17) {
            try std.testing.expectEqual(@as(u32, 2), count);
            const capability = shader_words[offset + 1];
            try std.testing.expect(capability != 10);
            try std.testing.expect(capability != 11);
        }
        offset += count;
    }
    try std.testing.expectEqual(shader_words.len, offset);
}

test "depth load definitions keep logical depth role separate from physical float ABI" {
    const Case = struct { dimension: api.TextureViewDimension, multisampled: bool };
    const cases = [_]Case{
        .{ .dimension = ._2d, .multisampled = false },
        .{ .dimension = ._2d_array, .multisampled = false },
        .{ .dimension = ._2d, .multisampled = true },
    };
    for (cases) |case| {
        const selected = try definition(.{
            .id = .texture_to_buffer,
            .source_format = .depth32_float,
            .source_dimension = case.dimension,
            .source_multisampled = case.multisampled,
            .storage_format = .r32_float,
        });
        const source_slot = selected.slots[0].sampled_view;
        try std.testing.expect(source_slot.depth_view);
        try std.testing.expectEqual(api.TextureSampleType.unfilterable_float, source_slot.sample_type);
        try std.testing.expectEqual(case.dimension, source_slot.dimension);
        try std.testing.expectEqual(case.multisampled, source_slot.multisampled);
        const shader_words = selected.stages.compute.stage.words;
        var images: usize = 0;
        var offset: usize = 5;
        for (0..shader_words.len) |_| {
            if (offset == shader_words.len) break;
            const count = shader_words[offset] >> 16;
            try std.testing.expect(count != 0);
            try std.testing.expect(count <= shader_words.len - offset);
            if (shader_words[offset] & 0xffff == 25) {
                images += 1;
                try std.testing.expect(count >= 9);
                try std.testing.expectEqual(@as(u32, 0), shader_words[offset + 4]);
                const sampled_type = findInstruction(shader_words, 22, shader_words[offset + 2]) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 3), sampled_type.len);
                try std.testing.expectEqual(@as(u32, 32), sampled_type[2]);
            }
            offset += count;
        }
        try std.testing.expectEqual(@as(usize, 1), images);
        try std.testing.expectEqual(shader_words.len, offset);
    }
}
