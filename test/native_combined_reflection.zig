//! Reflect the real committed hardware shader without rewriting its words.
//! Metadata checks read its declared member offsets, scalar types and matrix strides.
const std = @import("std");
const dusk = @import("dusk");
const spirv = dusk.spirv;
const definitions = dusk.engine.native_kernel_definitions;
const shader_reflect = dusk.pipeline.shader_reflect;
const layout_internal = dusk.pipeline.layout_internal;
const t = std.testing;

const metadata_offsets = [_]u32{
    0,   4,   16,  64,  96,  128, 176, 184, 192, 200,
    208, 216, 224, 232, 240, 248, 256, 264, 272,
};

// The fixture reads the production table, not emitter output generated in a test.
test "combined reflection retains the committed hardware descriptor and caller words" {
    const stage = definitions.external_ycbcr_fragment;
    const words = try t.allocator.dupe(u32, stage.words);
    defer t.allocator.free(words);
    const before = try t.allocator.dupe(u32, words);
    defer t.allocator.free(before);
    try spirv.validate(words);
    try t.expectEqual(spirv.magic_number, words[0]);
    try t.expectEqual(@as(u32, 0x00010300), words[1]);
    try t.expectEqual(@as(u32, 0), words[2]);
    try t.expect(words[3] > 1);
    try t.expectEqual(@as(u32, 0), words[4]);

    const module = try spirv.reflect(t.allocator, words);
    defer module.deinit();
    try t.expectEqual(@as(usize, 1), module.entry_points.len);
    const entry = module.findEntryPoint(stage.entry_point) orelse return error.EntryPointMissing;
    try t.expectEqual(spirv.ExecutionModel.fragment, entry.execution_model);
    try t.expectEqual(@as(usize, 3), entry.resources.len);
    try t.expect(module.words.ptr == words.ptr);
    const image = entry.resources[0];
    try t.expectEqual(spirv.ResourceKind.sampled_texture, image.kind);
    try t.expectEqual(@as(u32, 0), image.set);
    try t.expectEqual(@as(u32, 0), image.binding);
    try t.expect(image.combined_image_sampler);
    try t.expectEqual(@as(u32, 1), image.array_size);
    try t.expectEqual(spirv.Dim.two_dimensional, image.image_dimension.?);
    try t.expect(!image.image_arrayed);
    try t.expect(!image.image_multisampled);
    try t.expect(!image.image_depth);
    try t.expectEqual(@as(u32, 0), image.image_depth_mode.?);
    try t.expectEqual(@as(u32, 1), image.image_sampled.?);
    try t.expectEqual(@as(u32, 0), image.image_format.?);
    try t.expectEqual(@as(u32, 32), image.sampled_scalar.?.float);
    try t.expectEqual(spirv.ResourceKind.uniform_buffer, entry.resources[1].kind);
    try t.expectEqual(@as(u32, 0), entry.resources[1].set);
    try t.expectEqual(@as(u32, 1), entry.resources[1].binding);
    try t.expect(!entry.resources[1].combined_image_sampler);
    try t.expectEqual(spirv.ResourceKind.uniform_buffer, entry.resources[2].kind);
    try t.expectEqual(@as(u32, 0), entry.resources[2].set);
    try t.expectEqual(@as(u32, 2), entry.resources[2].binding);
    try t.expect(!entry.resources[2].combined_image_sampler);

    const layout = try shader_reflect.layoutFromResources(t.allocator, entry.resources);
    defer layout.deinit();
    try t.expectEqual(@as(usize, 3), layout.bindingCount());
    try t.expect(shader_reflect.bindingOf(layout, 0, 0).?.combined_image_sampler);
    try t.expect(shader_reflect.bindingOf(layout, 0, 3) == null);
    try t.expectEqualSlices(u32, before, words);
}

test "combined metadata declares the complete 288 byte uniform ABI" {
    const words = definitions.external_ycbcr_fragment.words;
    try spirv.validate(words);
    const uniform = try descriptorVariable(words, 1);
    try t.expectEqual(@as(u32, 2), uniform[2]);
    const pointer = try declaration(words, 32, uniform[0], 0);
    try t.expectEqual(@as(u32, 2), pointer[1]);
    const structure_id = pointer[2];
    try expectDecoration(words, structure_id, 2, null);
    const structure = try declaration(words, 30, structure_id, 0);
    const members = structure[1..];
    try t.expectEqual(metadata_offsets.len, members.len);
    for (metadata_offsets, 0..) |offset, member| {
        try expectMemberDecoration(words, structure_id, @intCast(member), 35, offset);
    }
    try expectScalar(words, members[0], .uint);
    try expectScalar(words, members[1], .uint);
    try expectMatrix(words, members[2], 4);
    try expectMatrix(words, members[5], 3);
    for ([_]u32{ 2, 5 }) |member| {
        try expectMemberDecoration(words, structure_id, member, 5, null);
        try expectMemberDecoration(words, structure_id, member, 7, 16);
    }
    for (members[3..5]) |transfer_id| {
        const transfer = try declaration(words, 30, transfer_id, 0);
        try t.expectEqual(@as(usize, 9), transfer.len);
        for (transfer[1..], 0..) |member_type, member| {
            try expectMemberDecoration(words, transfer_id, @intCast(member), 35, @intCast(member * 4));
            try expectScalar(words, member_type, if (member == 0) .uint else .float);
        }
    }
    for (members[6..16]) |member_type| try expectVector(words, member_type, .float, 2);
    try expectVector(words, members[16], .uint, 2);
    try expectVector(words, members[17], .float, 2);
    try expectVector(words, members[18], .float, 4);
    try t.expectEqual(@as(u32, 288), metadata_offsets[18] + 4 * @sizeOf(f32));

    const combined = try descriptorVariable(words, 0);
    try t.expectEqual(@as(u32, 0), combined[2]);
    const combined_pointer = try declaration(words, 32, combined[0], 0);
    try t.expectEqual(@as(u32, 0), combined_pointer[1]);
    const sampled_image = try declaration(words, 27, combined_pointer[2], 0);
    try t.expectEqual(@as(usize, 2), sampled_image.len);
    const image = try declaration(words, 25, sampled_image[1], 0);
    try t.expectEqualSlices(u32, &.{ 1, 0, 0, 0, 1, 0 }, image[2..]);
    try expectScalar(words, image[1], .float);
}

test "combined browser parameters declare the complete 160 byte uniform ABI" {
    const words = definitions.external_ycbcr_fragment.words;
    try spirv.validate(words);
    const uniform = try descriptorVariable(words, 2);
    try t.expectEqual(@as(u32, 2), uniform[2]);
    const pointer = try declaration(words, 32, uniform[0], 0);
    try t.expectEqual(@as(u32, 2), pointer[1]);
    const structure_id = pointer[2];
    try expectDecoration(words, structure_id, 2, null);
    const structure = try declaration(words, 30, structure_id, 0);
    const members = structure[1..];
    const offsets = [_]u32{ 0, 8, 16, 24, 28, 32, 36, 40, 44, 48, 80, 112 };
    try t.expectEqual(offsets.len, members.len);
    for (offsets, 0..) |offset, member| {
        try expectMemberDecoration(words, structure_id, @intCast(member), 35, offset);
    }
    for (members[0..3]) |member_type| try expectVector(words, member_type, .float, 2);
    for (members[3..9]) |member_type| try expectScalar(words, member_type, .uint);
    for (members[9..11]) |gamma_id| {
        const gamma = try declaration(words, 30, gamma_id, 0);
        try t.expectEqual(@as(usize, 9), gamma.len);
        for (gamma[1..], 0..) |member_type, member| {
            try expectMemberDecoration(words, gamma_id, @intCast(member), 35, @intCast(member * 4));
            try expectScalar(words, member_type, .float);
        }
    }
    try expectMatrix(words, members[11], 3);
    try expectMemberDecoration(words, structure_id, 11, 5, null);
    try expectMemberDecoration(words, structure_id, 11, 7, 16);
    try t.expectEqual(@as(u32, 160), offsets[11] + 3 * 16);
}

test "ordinary committed external shader keeps separate image and sampler descriptors" {
    const stage = definitions.external_ordinary_fragment;
    const before = try t.allocator.dupe(u32, stage.words);
    defer t.allocator.free(before);
    try spirv.validate(stage.words);
    const module = try spirv.reflect(t.allocator, stage.words);
    defer module.deinit();
    const entry = module.findEntryPoint(stage.entry_point) orelse return error.EntryPointMissing;
    try t.expectEqual(@as(usize, 5), entry.resources.len);
    const expected_kinds = [_]spirv.ResourceKind{
        .sampled_texture, .sampled_texture, .sampler, .uniform_buffer, .uniform_buffer,
    };
    for (entry.resources, expected_kinds, 0..) |resource, kind, binding| {
        try t.expectEqual(kind, resource.kind);
        try t.expectEqual(@as(u32, 0), resource.set);
        try t.expectEqual(@as(u32, @intCast(binding)), resource.binding);
        try t.expect(!resource.combined_image_sampler);
    }
    try t.expectEqualSlices(u32, before, stage.words);
}

test "actual combined declaration refuses an incompatible separate sampled layout" {
    const stage = definitions.external_ycbcr_fragment;
    const before = try t.allocator.dupe(u32, stage.words);
    defer t.allocator.free(before);
    const module = try spirv.reflect(t.allocator, stage.words);
    defer module.deinit();
    const entry = module.findEntryPoint(stage.entry_point) orelse return error.EntryPointMissing;
    var layout = try layout_internal.Layout.init(t.allocator, .{ .entries = &.{.{
        .binding_number = 0,
        .visibility = .{ .fragment = true },
        .kind = .{ .sampled_texture = .{
            .sample_type = .float_filterable,
            .view_dimension = .two_d,
            .multisampled = false,
        } },
    }} }, .{
        .max_storage_buffers_in_vertex_stage = 0,
        .max_storage_buffers_in_fragment_stage = 0,
    });
    defer layout.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), layout.entries.len);
    const descriptors = try dusk.pipeline.layout_vk.descriptorBindings(t.allocator, &layout, &.{});
    defer dusk.pipeline.layout_vk.freeDescriptorBindings(t.allocator, descriptors);
    try t.expectEqual(@as(usize, 1), descriptors.len);
    try t.expectEqual(@as(u32, 0), descriptors[0].binding);
    try t.expectEqual(
        @as(@TypeOf(descriptors[0].descriptorType), dusk.platform.vulkan_bindings.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE),
        descriptors[0].descriptorType,
    );
    try t.expect(descriptors[0].pImmutableSamplers == null);
    try t.expectError(error.ShaderBindingMismatch, shader_reflect.validateBinding(entry.resources[0], layout.entries[0], .{ .fragment = true }));
    try t.expectEqualSlices(u32, before, stage.words);
}

test "combined shader reflection unwinds every refused allocation" {
    try t.checkAllAllocationFailures(t.allocator, allocateReflection, .{});
}

fn allocateReflection(allocator: std.mem.Allocator) !void {
    const module = try spirv.reflect(allocator, definitions.external_ycbcr_fragment.words);
    defer module.deinit();
    try t.expectEqual(@as(usize, 3), module.entry_points[0].resources.len);
    try t.expect(module.entry_points[0].resources[0].combined_image_sampler);
    const layout = try shader_reflect.layoutFromResources(allocator, module.entry_points[0].resources);
    defer layout.deinit();
    try t.expect(shader_reflect.bindingOf(layout, 0, 0).?.combined_image_sampler);
}

const Instruction = struct { opcode: u16, operands: []const u32 };
const Cursor = struct {
    words: []const u32,
    index: usize = spirv.header_word_count,

    fn next(self: *Cursor) spirv.Error!?Instruction {
        if (self.index == self.words.len) return null;
        if (self.index > self.words.len) return error.SpirvMalformed;
        const count: usize = spirv.wordCountOf(self.words[self.index]);
        if (count == 0 or count > self.words.len - self.index) return error.SpirvMalformed;
        const instruction: Instruction = .{
            .opcode = spirv.opcodeOf(self.words[self.index]),
            .operands = self.words[self.index + 1 .. self.index + count],
        };
        self.index += count;
        return instruction;
    }
};

fn declaration(words: []const u32, opcode: u16, id: u32, id_operand: usize) ![]const u32 {
    var cursor: Cursor = .{ .words = words };
    while (try cursor.next()) |instruction| {
        if (instruction.opcode != opcode) continue;
        if (instruction.operands.len <= id_operand) return error.SpirvMalformed;
        if (instruction.operands[id_operand] == id) return instruction.operands;
    }
    return error.DeclarationMissing;
}

fn descriptorVariable(words: []const u32, binding: u32) ![]const u32 {
    var cursor: Cursor = .{ .words = words };
    while (try cursor.next()) |instruction| {
        if (instruction.opcode != 71 or instruction.operands.len != 3) continue;
        const operands = instruction.operands;
        if (operands[1] != 33 or operands[2] != binding) continue;
        try expectDecoration(words, operands[0], 34, 0);
        return declaration(words, 59, operands[0], 1);
    }
    return error.DescriptorMissing;
}

fn expectDecoration(words: []const u32, target: u32, decoration: u32, value: ?u32) !void {
    var cursor: Cursor = .{ .words = words };
    var matches: usize = 0;
    while (try cursor.next()) |instruction| {
        if (instruction.opcode != 71 or instruction.operands.len < 2) continue;
        const operands = instruction.operands;
        if (operands[0] != target or operands[1] != decoration) continue;
        try t.expectEqual(@as(usize, if (value != null) 3 else 2), operands.len);
        if (value) |expected| try t.expectEqual(expected, operands[2]);
        matches += 1;
    }
    try t.expectEqual(@as(usize, 1), matches);
}

fn expectMemberDecoration(words: []const u32, target: u32, member: u32, decoration: u32, value: ?u32) !void {
    var cursor: Cursor = .{ .words = words };
    var matches: usize = 0;
    while (try cursor.next()) |instruction| {
        if (instruction.opcode != 72 or instruction.operands.len < 3) continue;
        const operands = instruction.operands;
        if (operands[0] != target or operands[1] != member or operands[2] != decoration) continue;
        try t.expectEqual(@as(usize, if (value != null) 4 else 3), operands.len);
        if (value) |expected| try t.expectEqual(expected, operands[3]);
        matches += 1;
    }
    try t.expectEqual(@as(usize, 1), matches);
}

const Scalar = enum { float, uint };
fn expectScalar(words: []const u32, id: u32, scalar: Scalar) !void {
    const operands = try declaration(words, if (scalar == .float) 22 else 21, id, 0);
    try t.expectEqual(@as(usize, if (scalar == .float) 2 else 3), operands.len);
    try t.expectEqual(@as(u32, 32), operands[1]);
    if (scalar == .uint) try t.expectEqual(@as(u32, 0), operands[2]);
}

fn expectVector(words: []const u32, id: u32, scalar: Scalar, length: u32) !void {
    const operands = try declaration(words, 23, id, 0);
    try t.expectEqual(@as(usize, 3), operands.len);
    try t.expectEqual(length, operands[2]);
    try expectScalar(words, operands[1], scalar);
}

fn expectMatrix(words: []const u32, id: u32, row_count: u32) !void {
    const operands = try declaration(words, 24, id, 0);
    try t.expectEqual(@as(usize, 3), operands.len);
    try t.expectEqual(@as(u32, 3), operands[2]);
    try expectVector(words, operands[1], .float, row_count);
}
