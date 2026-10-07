//! SPIR-V 1.0 compute fixture, written as immutable instruction words.
//! One invocation stores `value * 10 + bias` in set 0, binding 0.
//! Uniform + BufferBlock is the SPIR-V 1.0 storage-buffer representation.

pub const entry_point: [:0]const u8 = "main";
pub const default_value: u32 = 11;
pub const default_bias: u32 = 3;
pub const default_output: u32 = default_value * 10 + default_bias;

pub const words = [_]u32{
    0x07230203, 0x00010000, 0, 17, 0,
    0x00020011, 1, // OpCapability Shader
    0x0003000e, 0, 1, // OpMemoryModel Logical GLSL450
    0x0005000f, 5, 1, 0x6e69616d, 0, // OpEntryPoint GLCompute %1 "main"
    0x00060010, 1, 17, 1, 1, 1, // OpExecutionMode %1 LocalSize 1 1 1
    0x00040005, 10, 0x756c6176, 0x00000065, // OpName %10 "value"
    0x00040005, 11, 0x73616962, 0, // OpName %11 "bias"
    0x00040047, 10, 1, 7, // OpDecorate %10 SpecId 7
    0x00040047, 11, 1, 9, // OpDecorate %11 SpecId 9
    0x00030047, 5, 3, // OpDecorate %5 BufferBlock
    0x00050048, 5, 0, 35, 0, // OpMemberDecorate %5 0 Offset 0
    0x00040047, 7, 34, 0, // OpDecorate %7 DescriptorSet 0
    0x00040047, 7, 33, 0, // OpDecorate %7 Binding 0
    0x00020013, 2, // %2 = OpTypeVoid
    0x00030021, 3, 2, // %3 = OpTypeFunction %2
    0x00040015, 4, 32, 0, // %4 = OpTypeInt 32 0
    0x0003001e, 5, 4, // %5 = OpTypeStruct %4
    0x00040020, 6, 2, 5, // %6 = OpTypePointer Uniform %5
    0x0004003b, 6, 7, 2, // %7 = OpVariable %6 Uniform
    0x00040020, 8, 2, 4, // %8 = OpTypePointer Uniform %4
    0x0004002b, 4, 9, 0, // %9 = OpConstant %4 0
    0x00040032, 4, 10, default_value, // %10 = OpSpecConstant %4 11
    0x00040032, 4, 11, default_bias, // %11 = OpSpecConstant %4 3
    0x0004002b, 4, 12, 10, // %12 = OpConstant %4 10
    0x00050036, 2, 1, 0, 3, // %1 = OpFunction %2 None %3
    0x000200f8, 13, // %13 = OpLabel
    0x00050084, 4, 14, 10, 12, // %14 = OpIMul %4 %10 %12
    0x00050080, 4, 15, 14, 11, // %15 = OpIAdd %4 %14 %11
    0x00050041, 8, 16, 7, 9, // %16 = OpAccessChain %8 %7 %9
    0x0003003e, 16, 15, // OpStore %16 %15
    0x000100fd, // OpReturn
    0x00010038, // OpFunctionEnd
};

/// Both result IDs use one specialization ID, as permitted by SPIR-V.
/// This is a second immutable module, derived only at compile time.
pub const shared_id_words = blk: {
    var variant = words;
    var offset: usize = 5;
    var changes: usize = 0;
    for (0..words.len) |_| {
        if (offset == words.len) break;
        const instruction = words[offset];
        const count = instruction >> 16;
        const opcode = instruction & 0xffff;
        if (count == 0 or offset + count > words.len) @compileError("invalid fixture instruction");
        if (opcode == 71 and count == 4 and words[offset + 1] == 11 and
            words[offset + 2] == 1)
        {
            variant[offset + 3] = 7;
            changes += 1;
        }
        if (opcode == 50 and count == 4 and words[offset + 2] == 11) {
            variant[offset + 3] = default_value;
            changes += 1;
        }
        offset += count;
    }
    if (offset != words.len) @compileError("fixture instruction walk exhausted");
    if (changes != 2) @compileError("shared-ID fixture must change ID and default exactly once");
    break :blk variant;
};

pub const shared_id_default_output: u32 = default_value * 11;
