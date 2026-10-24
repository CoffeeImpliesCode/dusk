// Copyright 2023 The Dawn & Tint Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

//! The one finite hardware ExternalTexture fragment shader. No input shader exists.
//! Origin: Dawn 32f77c02294310054a660c393feded4bcb3f203c,
//! src/tint/lang/core/ir/transform/multiplanar_external_texture.cc:
//! 363-403 (ABI), 408-723 (color), 987-1042 (combined sampling).
//! ExternalTexture.cpp:196-205 supplies the identity-YCbCr permutation in metadata.
//! Binding 0 is one combined image sampler. Binding 1 is a 288-byte uniform.
//! Binding 2 is the independent 160-byte browser-copy coordinate/color/alpha uniform.
const std = @import("std");

pub const entry_point: [:0]const u8 = "external_ycbcr";
pub const metadata_size: u32 = 288;
pub const parameter_size: u32 = 160;
pub const Error = error{OutOfMemory};

/// The caller owns the returned SPIR-V words. Only the offline generator calls this.
pub fn generate(allocator: std.mem.Allocator) Error![]u32 {
    var builder: Builder = .{
        .words = try std.ArrayList(u32).initCapacity(allocator, word_capacity),
    };
    errdefer builder.words.deinit(allocator);
    builder.words.appendSliceAssumeCapacity(&.{ 0x07230203, 0x00010300, 0, 0, 0 });
    builder.instruction(.capability, &.{1}); // Shader, with no optional arithmetic features.
    builder.stringInstruction(.ext_inst_import, &.{id(.glsl)}, "GLSL.std.450", &.{});
    builder.instruction(.memory_model, &.{ 0, 1 }); // Logical, GLSL450.
    builder.stringInstruction(.entry_point, &.{ 4, id(.main) }, entry_point, &.{ id(.input_uv), id(.output_color) });
    builder.instruction(.execution_mode, &.{ id(.main), 7 }); // OriginUpperLeft.
    builder.stringInstruction(.name, &.{id(.metadata)}, "ExternalTextureParams", &.{});
    builder.stringInstruction(.name, &.{id(.uniform)}, "metadata", &.{});
    builder.stringInstruction(.name, &.{id(.image_variable)}, "combined_plane", &.{});
    builder.stringInstruction(.name, &.{id(.browser)}, "BrowserCopyParams", &.{});
    emitDecorations(&builder);
    emitTypes(&builder);
    emitGamma(&builder);
    emitHLG(&builder);
    emitPQ(&builder);
    emitSourceTransfer(&builder);
    emitMain(&builder);
    builder.words.items[3] = builder.next_id;
    return builder.words.toOwnedSlice(allocator);
}

const word_capacity = 8192;
const Id = enum(u32) {
    void_type = 1,
    boolean,
    uint,
    float,
    vec2,
    vec3,
    vec4,
    uvec2,
    yuv_matrix,
    gamut_matrix,
    coord_matrix,
    transfer,
    metadata,
    browser_gamma,
    browser,
    image,
    sampled_image,
    image_pointer,
    uniform_pointer,
    browser_pointer,
    input_pointer,
    output_pointer,
    main_type,
    transfer_type,
    glsl,
    uniform,
    browser_uniform,
    image_variable,
    input_uv,
    output_color,
    main,
    gamma,
    hlg,
    pq,
    source_transfer,
    zero,
    one,
    uint_zero,
    uint_one,
    uint_two,
    uint_three,
    srgb_threshold,
    srgb_divisor,
    srgb_offset,
    srgb_scale,
    srgb_exponent,
};
fn id(value: Id) u32 {
    return @backingInt(value);
}

// These opcodes are the finite instruction set used by this shader, not a parser grammar.
const Op = enum(u16) {
    name = 5,
    ext_inst_import = 11,
    ext_inst = 12,
    memory_model = 14,
    entry_point = 15,
    execution_mode = 16,
    capability = 17,
    type_void = 19,
    type_bool = 20,
    type_int = 21,
    type_float = 22,
    type_vector = 23,
    type_matrix = 24,
    type_image = 25,
    type_sampled_image = 27,
    type_struct = 30,
    type_pointer = 32,
    type_function = 33,
    constant = 43,
    function = 54,
    function_parameter = 55,
    function_end = 56,
    function_call = 57,
    variable = 59,
    load = 61,
    store = 62,
    decorate = 71,
    member_decorate = 72,
    composite_construct = 80,
    composite_extract = 81,
    image_sample_explicit_lod = 88,
    fadd = 129,
    fsub = 131,
    fmul = 133,
    fdiv = 136,
    vector_times_scalar = 142,
    vector_times_matrix = 144,
    matrix_times_vector = 145,
    dot = 148,
    logical_or = 166,
    logical_and = 167,
    logical_not = 168,
    select = 169,
    iequal = 170,
    float_not_equal = 182,
    float_less = 184,
    float_less_equal = 188,
    phi = 245,
    selection_merge = 247,
    label = 248,
    branch = 249,
    branch_conditional = 250,
    return_void = 253,
    return_value = 254,
};

const Builder = struct {
    words: std.ArrayList(u32),
    next_id: u32 = id(.srgb_exponent) + 1,

    fn fresh(self: *Builder) u32 {
        const result_id = self.next_id;
        self.next_id += 1;
        return result_id;
    }

    fn instruction(self: *Builder, opcode: Op, operands: []const u32) void {
        std.debug.assert(self.words.items.len + operands.len + 1 <= word_capacity);
        self.words.appendAssumeCapacity((@as(u32, @intCast(operands.len + 1)) << 16) |
            @backingInt(opcode));
        self.words.appendSliceAssumeCapacity(operands);
    }

    fn result(self: *Builder, opcode: Op, result_type: u32, operands: []const u32) u32 {
        const result_id = self.fresh();
        std.debug.assert(self.words.items.len + operands.len + 3 <= word_capacity);
        self.words.appendAssumeCapacity((@as(u32, @intCast(operands.len + 3)) << 16) |
            @backingInt(opcode));
        self.words.appendSliceAssumeCapacity(&.{ result_type, result_id });
        self.words.appendSliceAssumeCapacity(operands);
        return result_id;
    }

    fn stringInstruction(self: *Builder, opcode: Op, prefix: []const u32, comptime text: []const u8, suffix: []const u32) void {
        const text_word_count = (text.len + 1 + 3) / 4;
        var text_words: [text_word_count]u32 = @splat(0);
        for (text, 0..) |byte, index| {
            text_words[index / 4] |= @as(u32, byte) << @as(u5, @intCast(index % 4 * 8));
        }
        const count = 1 + prefix.len + text_word_count + suffix.len;
        std.debug.assert(self.words.items.len + count <= word_capacity);
        self.words.appendAssumeCapacity((@as(u32, @intCast(count)) << 16) |
            @backingInt(opcode));
        self.words.appendSliceAssumeCapacity(prefix);
        self.words.appendSliceAssumeCapacity(&text_words);
        self.words.appendSliceAssumeCapacity(suffix);
    }

    fn extract(self: *Builder, result_type: Id, composite: u32, member: u32) u32 {
        return self.result(.composite_extract, id(result_type), &.{ composite, member });
    }

    fn binary(self: *Builder, opcode: Op, left: u32, right: u32) u32 {
        return self.result(opcode, id(.float), &.{ left, right });
    }

    fn math(self: *Builder, operation: u32, operands: []const u32) u32 {
        var arguments: [5]u32 = undefined;
        std.debug.assert(operands.len <= 3);
        arguments[0] = id(.glsl);
        arguments[1] = operation;
        @memcpy(arguments[2..][0..operands.len], operands);
        return self.result(.ext_inst, id(.float), arguments[0 .. operands.len + 2]);
    }

    fn beginTransfer(self: *Builder, function_id: Id) struct { value: u32, params: u32 } {
        self.instruction(.function, &.{ id(.float), id(function_id), 0, id(.transfer_type) });
        const value = self.result(.function_parameter, id(.float), &.{});
        const params = self.result(.function_parameter, id(.transfer), &.{});
        self.instruction(.label, &.{self.fresh()});
        return .{ .value = value, .params = params };
    }

    fn callTransfer(self: *Builder, function_id: Id, value: u32, params: u32) u32 {
        return self.result(.function_call, id(.float), &.{ id(function_id), value, params });
    }

    fn transferRGB(self: *Builder, function_id: Id, rgb: u32, params: u32) u32 {
        var channels: [3]u32 = undefined;
        for (&channels, 0..) |*channel, index| {
            const value = self.extract(.float, rgb, @intCast(index));
            channel.* = self.callTransfer(function_id, value, params);
        }
        return self.result(.composite_construct, id(.vec3), &channels);
    }
};

fn emitDecorations(builder: *Builder) void {
    builder.instruction(.decorate, &.{ id(.metadata), 2 }); // Block.
    builder.instruction(.decorate, &.{ id(.uniform), 34, 0 });
    builder.instruction(.decorate, &.{ id(.uniform), 33, 1 });
    builder.instruction(.decorate, &.{ id(.image_variable), 34, 0 });
    builder.instruction(.decorate, &.{ id(.image_variable), 33, 0 });
    builder.instruction(.decorate, &.{ id(.input_uv), 30, 0 });
    builder.instruction(.decorate, &.{ id(.output_color), 30, 0 });
    builder.instruction(.decorate, &.{ id(.browser), 2 });
    builder.instruction(.decorate, &.{ id(.browser_uniform), 34, 0 });
    builder.instruction(.decorate, &.{ id(.browser_uniform), 33, 2 });
    const browser_offsets = [_]u32{ 0, 8, 16, 24, 28, 32, 36, 40, 44, 48, 80, 112 };
    for (browser_offsets, 0..) |offset, member| {
        builder.instruction(.member_decorate, &.{ id(.browser), @intCast(member), 35, offset });
    }
    builder.instruction(.member_decorate, &.{ id(.browser), 11, 5 });
    builder.instruction(.member_decorate, &.{ id(.browser), 11, 7, 16 });
    for (0..8) |member| {
        builder.instruction(.member_decorate, &.{ id(.browser_gamma), @intCast(member), 35, @intCast(member * 4) });
    }
    // Matrix columns are flat vec2 members. Nested structs would round their size to 32.
    const offsets = [_]u32{ 0, 4, 16, 64, 96, 128, 176, 184, 192, 200, 208, 216, 224, 232, 240, 248, 256, 264, 272 };
    for (offsets, 0..) |offset, member| {
        builder.instruction(.member_decorate, &.{ id(.metadata), @intCast(member), 35, offset });
    }
    for ([_]u32{ 2, 5 }) |member| {
        builder.instruction(.member_decorate, &.{ id(.metadata), member, 5 }); // ColMajor.
        builder.instruction(.member_decorate, &.{ id(.metadata), member, 7, 16 });
    }
    for (0..8) |member| {
        builder.instruction(.member_decorate, &.{ id(.transfer), @intCast(member), 35, @intCast(member * 4) });
    }
}

fn emitTypes(builder: *Builder) void {
    builder.instruction(.type_void, &.{id(.void_type)});
    builder.instruction(.type_bool, &.{id(.boolean)});
    builder.instruction(.type_int, &.{ id(.uint), 32, 0 });
    builder.instruction(.type_float, &.{ id(.float), 32 });
    builder.instruction(.type_vector, &.{ id(.vec2), id(.float), 2 });
    builder.instruction(.type_vector, &.{ id(.vec3), id(.float), 3 });
    builder.instruction(.type_vector, &.{ id(.vec4), id(.float), 4 });
    builder.instruction(.type_vector, &.{ id(.uvec2), id(.uint), 2 });
    builder.instruction(.type_matrix, &.{ id(.yuv_matrix), id(.vec4), 3 });
    builder.instruction(.type_matrix, &.{ id(.gamut_matrix), id(.vec3), 3 });
    builder.instruction(.type_matrix, &.{ id(.coord_matrix), id(.vec2), 3 });
    builder.instruction(.type_struct, &.{ id(.transfer), id(.uint), id(.float), id(.float), id(.float), id(.float), id(.float), id(.float), id(.float) });
    builder.instruction(.type_struct, &.{ id(.metadata), id(.uint), id(.uint), id(.yuv_matrix), id(.transfer), id(.transfer), id(.gamut_matrix), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.vec2), id(.uvec2), id(.vec2), id(.vec4) });
    builder.instruction(.type_struct, &.{ id(.browser_gamma), id(.float), id(.float), id(.float), id(.float), id(.float), id(.float), id(.float), id(.float) });
    builder.instruction(.type_struct, &.{ id(.browser), id(.vec2), id(.vec2), id(.vec2), id(.uint), id(.uint), id(.uint), id(.uint), id(.uint), id(.uint), id(.browser_gamma), id(.browser_gamma), id(.gamut_matrix) });
    builder.instruction(.type_image, &.{ id(.image), id(.float), 1, 0, 0, 0, 1, 0 });
    builder.instruction(.type_sampled_image, &.{ id(.sampled_image), id(.image) });
    builder.instruction(.type_pointer, &.{ id(.image_pointer), 0, id(.sampled_image) });
    builder.instruction(.type_pointer, &.{ id(.uniform_pointer), 2, id(.metadata) });
    builder.instruction(.type_pointer, &.{ id(.browser_pointer), 2, id(.browser) });
    builder.instruction(.type_pointer, &.{ id(.input_pointer), 1, id(.vec2) });
    builder.instruction(.type_pointer, &.{ id(.output_pointer), 3, id(.vec4) });
    builder.instruction(.type_function, &.{ id(.main_type), id(.void_type) });
    builder.instruction(.type_function, &.{ id(.transfer_type), id(.float), id(.float), id(.transfer) });
    builder.instruction(.constant, &.{ id(.float), id(.zero), 0 });
    builder.instruction(.constant, &.{ id(.float), id(.one), 0x3f800000 });
    builder.instruction(.constant, &.{ id(.uint), id(.uint_zero), 0 });
    builder.instruction(.constant, &.{ id(.uint), id(.uint_one), 1 });
    builder.instruction(.constant, &.{ id(.uint), id(.uint_two), 2 });
    builder.instruction(.constant, &.{ id(.uint), id(.uint_three), 3 });
    builder.instruction(.constant, &.{ id(.float), id(.srgb_threshold), @as(u32, @bitCast(@as(f32, 0.04045))) });
    builder.instruction(.constant, &.{ id(.float), id(.srgb_divisor), @as(u32, @bitCast(@as(f32, 12.92))) });
    builder.instruction(.constant, &.{ id(.float), id(.srgb_offset), @as(u32, @bitCast(@as(f32, 0.055))) });
    builder.instruction(.constant, &.{ id(.float), id(.srgb_scale), @as(u32, @bitCast(@as(f32, 1.055))) });
    builder.instruction(.constant, &.{ id(.float), id(.srgb_exponent), @as(u32, @bitCast(@as(f32, 2.4))) });
    builder.instruction(.variable, &.{ id(.image_pointer), id(.image_variable), 0 });
    builder.instruction(.variable, &.{ id(.uniform_pointer), id(.uniform), 2 });
    builder.instruction(.variable, &.{ id(.browser_pointer), id(.browser_uniform), 2 });
    builder.instruction(.variable, &.{ id(.input_pointer), id(.input_uv), 1 });
    builder.instruction(.variable, &.{ id(.output_pointer), id(.output_color), 3 });
}

fn emitGamma(builder: *Builder) void {
    const input = builder.beginTransfer(.gamma);
    var params: [7]u32 = undefined;
    for (&params, 0..) |*param, index| {
        param.* = builder.extract(.float, input.params, @intCast(index + 1));
    }
    const absolute = builder.math(4, &.{input.value}); // FAbs.
    const sign = builder.math(6, &.{input.value}); // FSign.
    const linear = builder.binary(.fadd, builder.binary(.fmul, params[2], absolute), params[5]);
    const base = builder.binary(.fadd, builder.binary(.fmul, params[0], absolute), params[1]);
    const nonlinear = builder.binary(.fadd, builder.math(26, &.{ base, params[6] }), params[4]);
    const condition = builder.result(.float_less, id(.boolean), &.{ absolute, params[3] });
    const selected = builder.result(.select, id(.float), &.{ condition, linear, nonlinear });
    builder.instruction(.return_value, &.{builder.binary(.fmul, sign, selected)});
    builder.instruction(.function_end, &.{});
}

fn emitHLG(builder: *Builder) void {
    const input = builder.beginTransfer(.hlg);
    var params: [6]u32 = undefined;
    for (&params, 0..) |*param, index| {
        param.* = builder.extract(.float, input.params, @intCast(index + 1));
    }
    const lower = builder.fresh();
    const upper = builder.fresh();
    const merge = builder.fresh();
    const condition = builder.result(.float_less_equal, id(.boolean), &.{ input.value, params[3] });
    builder.instruction(.selection_merge, &.{ merge, 0 });
    builder.instruction(.branch_conditional, &.{ condition, lower, upper });
    builder.instruction(.label, &.{lower});
    const squared = builder.binary(.fmul, input.value, input.value);
    const lower_result = builder.binary(.fdiv, squared, params[4]);
    builder.instruction(.branch, &.{merge});
    builder.instruction(.label, &.{upper});
    const exponent = builder.binary(.fdiv, builder.binary(.fsub, input.value, params[2]), params[0]);
    const numerator = builder.binary(.fadd, params[1], builder.math(27, &.{exponent})); // Exp.
    const upper_result = builder.binary(.fdiv, numerator, params[5]);
    builder.instruction(.branch, &.{merge});
    builder.instruction(.label, &.{merge});
    const result = builder.result(.phi, id(.float), &.{ lower_result, lower, upper_result, upper });
    builder.instruction(.return_value, &.{result});
    builder.instruction(.function_end, &.{});
}

fn emitPQ(builder: *Builder) void {
    const input = builder.beginTransfer(.pq);
    var params: [5]u32 = undefined;
    for (&params, 0..) |*param, index| {
        param.* = builder.extract(.float, input.params, @intCast(index + 1));
    }
    const clamped = builder.math(43, &.{ input.value, id(.zero), id(.one) }); // FClamp.
    const inverse_m2 = builder.binary(.fdiv, id(.one), params[1]);
    const power = builder.math(26, &.{ clamped, inverse_m2 });
    const numerator = builder.math(40, &.{ builder.binary(.fsub, power, params[2]), id(.zero) });
    const denominator = builder.binary(.fsub, params[3], builder.binary(.fmul, params[4], power));
    const ratio = builder.binary(.fdiv, numerator, denominator);
    const inverse_m1 = builder.binary(.fdiv, id(.one), params[0]);
    builder.instruction(.return_value, &.{builder.math(26, &.{ ratio, inverse_m1 })});
    builder.instruction(.function_end, &.{});
}

fn emitSourceTransfer(builder: *Builder) void {
    const input = builder.beginTransfer(.source_transfer);
    const mode = builder.extract(.uint, input.params, 0);
    const gamma_block = builder.fresh();
    const hdr_block = builder.fresh();
    const outer_merge = builder.fresh();
    const gamma_condition = builder.result(.iequal, id(.boolean), &.{ mode, id(.uint_zero) });
    builder.instruction(.selection_merge, &.{ outer_merge, 0 });
    builder.instruction(.branch_conditional, &.{ gamma_condition, gamma_block, hdr_block });
    builder.instruction(.label, &.{gamma_block});
    const gamma_result = builder.callTransfer(.gamma, input.value, input.params);
    builder.instruction(.branch, &.{outer_merge});
    builder.instruction(.label, &.{hdr_block});
    const hlg_block = builder.fresh();
    const pq_block = builder.fresh();
    const hdr_merge = builder.fresh();
    const hlg_condition = builder.result(.iequal, id(.boolean), &.{ mode, id(.uint_one) });
    builder.instruction(.selection_merge, &.{ hdr_merge, 0 });
    builder.instruction(.branch_conditional, &.{ hlg_condition, hlg_block, pq_block });
    builder.instruction(.label, &.{hlg_block});
    const hlg_result = builder.callTransfer(.hlg, input.value, input.params);
    builder.instruction(.branch, &.{hdr_merge});
    builder.instruction(.label, &.{pq_block});
    const pq_result = builder.callTransfer(.pq, input.value, input.params);
    builder.instruction(.branch, &.{hdr_merge});
    builder.instruction(.label, &.{hdr_merge});
    const hdr_result = builder.result(.phi, id(.float), &.{ hlg_result, hlg_block, pq_result, pq_block });
    builder.instruction(.branch, &.{outer_merge});
    builder.instruction(.label, &.{outer_merge});
    const result = builder.result(.phi, id(.float), &.{ gamma_result, gamma_block, hdr_result, hdr_merge });
    builder.instruction(.return_value, &.{result});
    builder.instruction(.function_end, &.{});
}

fn emitMain(builder: *Builder) void {
    builder.instruction(.function, &.{ id(.void_type), id(.main), 0, id(.main_type) });
    builder.instruction(.label, &.{builder.fresh()});
    const metadata = builder.result(.load, id(.metadata), &.{id(.uniform)});
    const browser = builder.result(.load, id(.browser), &.{id(.browser_uniform)});
    const input_uv = builder.result(.load, id(.vec2), &.{id(.input_uv)});
    const uv = emitBrowserCoordinates(builder, browser, input_uv);
    const uv_x = builder.extract(.float, uv, 0);
    const uv_y = builder.extract(.float, uv, 1);
    const homogeneous = builder.result(.composite_construct, id(.vec3), &.{ uv_x, uv_y, id(.one) });
    var coords: [3]u32 = undefined;
    for (&coords, 0..) |*column, index| {
        column.* = builder.extract(.vec2, metadata, @intCast(index + 6));
    }
    const transform = builder.result(.composite_construct, id(.coord_matrix), &coords);
    const modified = builder.result(.matrix_times_vector, id(.vec2), &.{ transform, homogeneous });
    const minimum = builder.extract(.vec2, metadata, 12);
    const maximum = builder.extract(.vec2, metadata, 13);
    const clamped = builder.result(.ext_inst, id(.vec2), &.{ id(.glsl), 43, modified, minimum, maximum });
    const sampled_image = builder.result(.load, id(.sampled_image), &.{id(.image_variable)});
    const texel = builder.result(.image_sample_explicit_lod, id(.vec4), &.{ sampled_image, clamped, 2, id(.zero) }); // Lod = 0.
    const red = builder.extract(.float, texel, 0);
    const green = builder.extract(.float, texel, 1);
    const blue = builder.extract(.float, texel, 2);
    const alpha = builder.extract(.float, texel, 3);
    const sample_vector = builder.result(.composite_construct, id(.vec4), &.{ red, green, blue, id(.one) });
    const yuv_matrix = builder.extract(.yuv_matrix, metadata, 2);
    // The metadata matrix acts on Vulkan's converted RGB, not on unconverted YUV again.
    const rgb = builder.result(.vector_times_matrix, id(.vec3), &.{ sample_vector, yuv_matrix });
    const conversion_only = builder.extract(.uint, metadata, 1);
    const convert = builder.result(.iequal, id(.boolean), &.{ conversion_only, id(.uint_zero) });
    const color_block = builder.fresh();
    const bypass_block = builder.fresh();
    const final_merge = builder.fresh();
    builder.instruction(.selection_merge, &.{ final_merge, 0 });
    builder.instruction(.branch_conditional, &.{ convert, color_block, bypass_block });
    builder.instruction(.label, &.{color_block});
    const source = builder.extract(.transfer, metadata, 3);
    const decoded = builder.transferRGB(.source_transfer, rgb, source);
    const ootf = builder.extract(.vec4, metadata, 18);
    const exponent = builder.extract(.float, ootf, 3);
    const apply_ootf = builder.result(.float_not_equal, id(.boolean), &.{ exponent, id(.zero) });
    const ootf_block = builder.fresh();
    const no_ootf_block = builder.fresh();
    const ootf_merge = builder.fresh();
    builder.instruction(.selection_merge, &.{ ootf_merge, 0 });
    builder.instruction(.branch_conditional, &.{ apply_ootf, ootf_block, no_ootf_block });
    builder.instruction(.label, &.{ootf_block});
    const weight_r = builder.extract(.float, ootf, 0);
    const weight_g = builder.extract(.float, ootf, 1);
    const weight_b = builder.extract(.float, ootf, 2);
    const weights = builder.result(.composite_construct, id(.vec3), &.{ weight_r, weight_g, weight_b });
    const luminance = builder.result(.dot, id(.float), &.{ weights, decoded });
    const absolute = builder.math(4, &.{luminance});
    const power = builder.math(26, &.{ absolute, exponent });
    const sign = builder.math(6, &.{luminance});
    const multiplier = builder.binary(.fmul, sign, power);
    const adjusted = builder.result(.vector_times_scalar, id(.vec3), &.{ decoded, multiplier });
    builder.instruction(.branch, &.{ootf_merge});
    builder.instruction(.label, &.{no_ootf_block});
    builder.instruction(.branch, &.{ootf_merge});
    builder.instruction(.label, &.{ootf_merge});
    const ootf_result = builder.result(.phi, id(.vec3), &.{ adjusted, ootf_block, decoded, no_ootf_block });
    const gamut = builder.extract(.gamut_matrix, metadata, 5);
    const converted = builder.result(.matrix_times_vector, id(.vec3), &.{ gamut, ootf_result });
    const destination = builder.extract(.transfer, metadata, 4);
    const encoded = builder.transferRGB(.gamma, converted, destination);
    builder.instruction(.branch, &.{final_merge});
    builder.instruction(.label, &.{bypass_block});
    builder.instruction(.branch, &.{final_merge});
    builder.instruction(.label, &.{final_merge});
    const final_rgb = builder.result(.phi, id(.vec3), &.{ encoded, ootf_merge, rgb, bypass_block });
    const browser_color = emitBrowserColor(builder, browser, final_rgb, alpha);
    const final_r = builder.extract(.float, browser_color.rgb, 0);
    const final_g = builder.extract(.float, browser_color.rgb, 1);
    const final_b = builder.extract(.float, browser_color.rgb, 2);
    const final_color = builder.result(.composite_construct, id(.vec4), &.{ final_r, final_g, final_b, browser_color.alpha });
    builder.instruction(.store, &.{ id(.output_color), final_color });
    builder.instruction(.return_void, &.{});
    builder.instruction(.function_end, &.{});
}

fn emitBrowserCoordinates(builder: *Builder, browser: u32, input_uv: u32) u32 {
    const origin = builder.extract(.vec2, browser, 0);
    const extent = builder.extract(.vec2, browser, 1);
    const apparent = builder.extract(.vec2, browser, 2);
    const flip = builder.extract(.uint, browser, 3);
    const no_flip = builder.result(.iequal, id(.boolean), &.{ flip, id(.uint_zero) });
    const uv_x = builder.extract(.float, input_uv, 0);
    const uv_y = builder.extract(.float, input_uv, 1);
    const flipped_y = builder.binary(.fsub, id(.one), uv_y);
    const selected_y = builder.result(.select, id(.float), &.{ no_flip, uv_y, flipped_y });
    const selected_uv = builder.result(.composite_construct, id(.vec2), &.{ uv_x, selected_y });
    const scaled = builder.result(.fmul, id(.vec2), &.{ selected_uv, extent });
    const positioned = builder.result(.fadd, id(.vec2), &.{ origin, scaled });
    return builder.result(.fdiv, id(.vec2), &.{ positioned, apparent });
}

fn browserGamma(builder: *Builder, browser: u32, member: u32) u32 {
    const gamma_fields = builder.extract(.browser_gamma, browser, member);
    var fields: [8]u32 = undefined;
    fields[0] = id(.uint_zero);
    // Browser gamma is packed G,A,B,C,D,E,F. The external helper takes mode,A..G.
    for (1..7) |index| {
        fields[index] = builder.extract(.float, gamma_fields, @intCast(index));
    }
    fields[7] = builder.extract(.float, gamma_fields, 0);
    return builder.result(.composite_construct, id(.transfer), &fields);
}

fn emitBrowserColor(builder: *Builder, browser: u32, rgb: u32, alpha: u32) struct { rgb: u32, alpha: u32 } {
    const conversion_flag = builder.extract(.uint, browser, 4);
    const source_mode = builder.extract(.uint, browser, 5);
    const destination_mode = builder.extract(.uint, browser, 6);
    const no_conversion = builder.result(.iequal, id(.boolean), &.{ conversion_flag, id(.uint_zero) });
    const conversion = builder.result(.logical_not, id(.boolean), &.{no_conversion});
    const source_premultiplied = builder.result(.iequal, id(.boolean), &.{ source_mode, id(.uint_two) });
    const destination_unpremultiplied = builder.result(.iequal, id(.boolean), &.{ destination_mode, id(.uint_three) });
    const unpremultiply_needed = builder.result(.logical_or, id(.boolean), &.{ conversion, destination_unpremultiplied });
    const source_unpremultiply = builder.result(.logical_and, id(.boolean), &.{ source_premultiplied, unpremultiply_needed });
    const nonzero_alpha = builder.result(.float_not_equal, id(.boolean), &.{ alpha, id(.zero) });
    const unpremultiply = builder.result(.logical_and, id(.boolean), &.{ source_unpremultiply, nonzero_alpha });
    const unpremultiply_block = builder.fresh();
    const preserve_block = builder.fresh();
    const unpremultiply_merge = builder.fresh();
    builder.instruction(.selection_merge, &.{ unpremultiply_merge, 0 });
    builder.instruction(.branch_conditional, &.{ unpremultiply, unpremultiply_block, preserve_block });
    builder.instruction(.label, &.{unpremultiply_block});
    const alpha_vector = builder.result(.composite_construct, id(.vec3), &.{ alpha, alpha, alpha });
    const straight_rgb = builder.result(.fdiv, id(.vec3), &.{ rgb, alpha_vector });
    builder.instruction(.branch, &.{unpremultiply_merge});
    builder.instruction(.label, &.{preserve_block});
    builder.instruction(.branch, &.{unpremultiply_merge});
    builder.instruction(.label, &.{unpremultiply_merge});
    const prepared_rgb = builder.result(.phi, id(.vec3), &.{ straight_rgb, unpremultiply_block, rgb, preserve_block });
    const conversion_block = builder.fresh();
    const identity_block = builder.fresh();
    const conversion_merge = builder.fresh();
    builder.instruction(.selection_merge, &.{ conversion_merge, 0 });
    builder.instruction(.branch_conditional, &.{ conversion, conversion_block, identity_block });
    builder.instruction(.label, &.{conversion_block});
    const source_gamma = browserGamma(builder, browser, 9);
    const decoded = builder.transferRGB(.gamma, prepared_rgb, source_gamma);
    const gamut = builder.extract(.gamut_matrix, browser, 11);
    const gamut_rgb = builder.result(.matrix_times_vector, id(.vec3), &.{ gamut, decoded });
    const destination_gamma = browserGamma(builder, browser, 10);
    const encoded = builder.transferRGB(.gamma, gamut_rgb, destination_gamma);
    builder.instruction(.branch, &.{conversion_merge});
    builder.instruction(.label, &.{identity_block});
    builder.instruction(.branch, &.{conversion_merge});
    builder.instruction(.label, &.{conversion_merge});
    const converted = builder.result(.phi, id(.vec3), &.{ encoded, conversion_block, prepared_rgb, identity_block });
    const destination_premultiplied = builder.result(.iequal, id(.boolean), &.{ destination_mode, id(.uint_two) });
    const source_unpremultiplied = builder.result(.iequal, id(.boolean), &.{ source_mode, id(.uint_three) });
    const premultiply_needed = builder.result(.logical_or, id(.boolean), &.{ conversion, source_unpremultiplied });
    const premultiply = builder.result(.logical_and, id(.boolean), &.{ destination_premultiplied, premultiply_needed });
    const factor = builder.result(.select, id(.float), &.{ premultiply, alpha, id(.one) });
    const premultiplied = builder.result(.vector_times_scalar, id(.vec3), &.{ converted, factor });
    const final_rgb = emitDestinationSRGB(builder, browser, premultiplied);
    const source_opaque = builder.result(.iequal, id(.boolean), &.{ source_mode, id(.uint_one) });
    const final_alpha = builder.result(.select, id(.float), &.{ source_opaque, id(.one), alpha });
    return .{ .rgb = final_rgb, .alpha = final_alpha };
}

fn emitDestinationSRGB(builder: *Builder, browser: u32, rgb: u32) u32 {
    // Vulkan encodes an sRGB attachment. Decode the finished browser RGB to cancel that step.
    const flag = builder.extract(.uint, browser, 7);
    const preserve = builder.result(.iequal, id(.boolean), &.{ flag, id(.uint_zero) });
    const preserve_block = builder.fresh();
    const decode_block = builder.fresh();
    const merge = builder.fresh();
    builder.instruction(.selection_merge, &.{ merge, 0 });
    builder.instruction(.branch_conditional, &.{ preserve, preserve_block, decode_block });
    builder.instruction(.label, &.{preserve_block});
    builder.instruction(.branch, &.{merge});
    builder.instruction(.label, &.{decode_block});
    var channels: [3]u32 = undefined;
    var decoded_exit = decode_block;
    for (&channels, 0..) |*channel, index| {
        const value = builder.extract(.float, rgb, @intCast(index));
        const decoded = emitSRGBChannel(builder, value);
        channel.* = decoded.value;
        decoded_exit = decoded.exit_block;
    }
    const decoded_rgb = builder.result(.composite_construct, id(.vec3), &channels);
    builder.instruction(.branch, &.{merge});
    builder.instruction(.label, &.{merge});
    return builder.result(.phi, id(.vec3), &.{ rgb, preserve_block, decoded_rgb, decoded_exit });
}

fn emitSRGBChannel(builder: *Builder, value: u32) struct { value: u32, exit_block: u32 } {
    const lower = builder.fresh();
    const upper = builder.fresh();
    const merge = builder.fresh();
    const condition = builder.result(.float_less_equal, id(.boolean), &.{ value, id(.srgb_threshold) });
    builder.instruction(.selection_merge, &.{ merge, 0 });
    builder.instruction(.branch_conditional, &.{ condition, lower, upper });
    builder.instruction(.label, &.{lower});
    const linear = builder.binary(.fdiv, value, id(.srgb_divisor));
    builder.instruction(.branch, &.{merge});
    builder.instruction(.label, &.{upper});
    const shifted = builder.binary(.fadd, value, id(.srgb_offset));
    const base = builder.binary(.fdiv, shifted, id(.srgb_scale));
    const nonlinear = builder.math(26, &.{ base, id(.srgb_exponent) });
    builder.instruction(.branch, &.{merge});
    builder.instruction(.label, &.{merge});
    const result = builder.result(.phi, id(.float), &.{ linear, lower, nonlinear, upper });
    return .{ .value = result, .exit_block = merge };
}
