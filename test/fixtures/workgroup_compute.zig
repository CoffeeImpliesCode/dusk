//! Immutable SPIR-V compute fixtures with specialization-controlled workgroups.
//! Dispatch one workgroup after clearing the two-word storage output to zero.
//! Word 0 counts every invocation; word 1 marks local indices 0 through 31.
//! The runtime-array length guard keeps both output accesses in bounds.

pub const entry_point: [:0]const u8 = "main";
pub const x_name = "local_x";
pub const y_name = "local_y";
pub const z_name = "local_z";
pub const x_spec_id: u32 = 21;
pub const y_spec_id: u32 = 22;
pub const z_spec_id: u32 = 23;
pub const default_dimensions: [3]u32 = .{ 2, 2, 1 };
pub const output_word_count: usize = 2;
pub const default_count: u32 = 4;
pub const default_coverage: u32 = 15;
pub const default_output: [output_word_count]u32 = .{ default_count, default_coverage };

/// SPIR-V 1.0: BuiltIn WorkgroupSize needs no maintenance4 feature.
/// Uniform + BufferBlock is the storage-buffer representation for this version.
pub const words = [_]u32{
    0x07230203, 0x00010000, 0, 54, 0,
    0x00020011, 1, // OpCapability Shader
    0x0003000e, 0, 1, // OpMemoryModel Logical GLSL450
    0x0006000f, 5, 1, 0x6e69616d, 0, 17, // OpEntryPoint GLCompute %1 "main" %17
    0x00040005, 10, 0x61636f6c, 0x00785f6c, // OpName %10 "local_x"
    0x00040005, 11, 0x61636f6c, 0x00795f6c, // OpName %11 "local_y"
    0x00040005, 12, 0x61636f6c, 0x007a5f6c, // OpName %12 "local_z"
    0x00040047, 10, 1, x_spec_id, // OpDecorate %10 SpecId 21
    0x00040047, 11, 1, y_spec_id, // OpDecorate %11 SpecId 22
    0x00040047, 12, 1, z_spec_id, // OpDecorate %12 SpecId 23
    0x00040047, 18, 11, 25, // OpDecorate %18 BuiltIn WorkgroupSize
    0x00040047, 17, 11, 29, // OpDecorate %17 BuiltIn LocalInvocationIndex
    0x00040047, 7, 6, 4, // OpDecorate %7 ArrayStride 4
    0x00030047, 8, 3, // OpDecorate %8 BufferBlock
    0x00050048, 8, 0, 35, 0, // OpMemberDecorate %8 0 Offset 0
    0x00040047, 13, 34, 0, // OpDecorate %13 DescriptorSet 0
    0x00040047, 13, 33, 0, // OpDecorate %13 Binding 0
    0x00020013, 2, // %2 = OpTypeVoid
    0x00030021, 3, 2, // %3 = OpTypeFunction %2
    0x00040015, 4, 32, 0, // %4 = OpTypeInt 32 0
    0x00020014, 5, // %5 = OpTypeBool
    0x00040017, 6, 4, 3, // %6 = OpTypeVector %4 3
    0x0003001d, 7, 4, // %7 = OpTypeRuntimeArray %4
    0x0003001e, 8, 7, // %8 = OpTypeStruct %7
    0x00040020, 9, 2, 8, // %9 = OpTypePointer Uniform %8
    0x00040032, 4, 10, default_dimensions[0], // %10 = OpSpecConstant %4 2
    0x00040032, 4, 11, default_dimensions[1], // %11 = OpSpecConstant %4 2
    0x00040032, 4, 12, default_dimensions[2], // %12 = OpSpecConstant %4 1
    0x0004003b, 9, 13, 2, // %13 = OpVariable %9 Uniform
    0x00040020, 14, 2, 4, // %14 = OpTypePointer Uniform %4
    0x00040020, 15, 1, 4, // %15 = OpTypePointer Input %4
    0x0004002b, 4, 16, 0, // %16 = OpConstant %4 0
    0x0004003b, 15, 17, 1, // %17 = OpVariable %15 Input
    0x00060033, 6, 18, 10, 11, 12, // %18 = OpSpecConstantComposite %6 %10 %11 %12
    0x0004002b, 4, 19, 1, // %19 = OpConstant %4 1 (Device scope)
    0x0004002b, 4, 20, 2, // %20 = OpConstant %4 2
    0x0004002b, 4, 21, 32, // %21 = OpConstant %4 32
    0x00050036, 2, 1, 0, 3, // %1 = OpFunction %2 None %3
    0x000200f8, 40, // %40 = OpLabel
    0x00050044, 4, 41, 13, 0, // %41 = OpArrayLength %4 %13 0
    0x000500ae, 5, 42, 41, 20, // %42 = OpUGreaterThanEqual %5 %41 %20
    0x000300f7, 53, 0, // OpSelectionMerge %53 None
    0x000400fa, 42, 43, 53, // OpBranchConditional %42 %43 %53
    0x000200f8, 43, // %43 = OpLabel
    0x00060041, 14, 44, 13, 16, 16, // %44 = OpAccessChain %14 %13 %16 %16
    0x000700ea, 4, 45, 44, 19, 16, 19, // %45 = OpAtomicIAdd %4 %44 Device Relaxed %19
    0x0004003d, 4, 46, 17, // %46 = OpLoad %4 %17
    0x000500b0, 5, 47, 46, 21, // %47 = OpULessThan %5 %46 %21
    0x000300f7, 52, 0, // OpSelectionMerge %52 None
    0x000400fa, 47, 48, 52, // OpBranchConditional %47 %48 %52
    0x000200f8, 48, // %48 = OpLabel
    0x00060041, 14, 49, 13, 16, 19, // %49 = OpAccessChain %14 %13 %16 %19
    0x000500c4, 4, 50, 19, 46, // %50 = OpShiftLeftLogical %4 %19 %46
    0x000700f1, 4, 51, 49, 19, 16, 50, // %51 = OpAtomicOr %4 %49 Device Relaxed %50
    0x000200f9, 52, // OpBranch %52
    0x000200f8, 52, // %52 = OpLabel
    0x000200f9, 53, // OpBranch %53
    0x000200f8, 53, // %53 = OpLabel
    0x000100fd, // OpReturn
    0x00010038, // OpFunctionEnd
};

/// Both x and y use SpecId 21 with equal type and equal default value.
/// Either name or numeric key "21" overrides both dimensions together.
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
            variant[offset + 3] = x_spec_id;
            changes += 1;
        }
        offset += count;
    }
    if (offset != words.len or changes != 1) @compileError("invalid shared-ID workgroup fixture");
    break :blk variant;
};

/// SPIR-V 1.2 LocalSizeId variant: Vulkan 1.3 with maintenance4 enabled, or
/// VK_KHR_maintenance4 with its maintenance4 feature enabled, is required.
/// This module is assembled only at compile time, never rewritten at runtime.
pub const local_size_id_words = blk: {
    var variant: [words.len + 2]u32 = undefined;
    @memcpy(variant[0..5], words[0..5]);
    variant[1] = 0x00010200;
    var input_offset: usize = 5;
    var output_offset: usize = 5;
    var changes: usize = 0;
    for (0..words.len) |_| {
        if (input_offset == words.len) break;
        const instruction = words[input_offset];
        const count = instruction >> 16;
        const opcode = instruction & 0xffff;
        if (count == 0 or input_offset + count > words.len) @compileError("invalid fixture instruction");
        if (opcode == 71 and count == 4 and words[input_offset + 1] == 18 and
            words[input_offset + 2] == 11 and words[input_offset + 3] == 25)
        {
            changes += 1;
        } else {
            @memcpy(variant[output_offset..][0..count], words[input_offset..][0..count]);
            output_offset += count;
            if (opcode == 15) {
                // OpExecutionModeId %1 LocalSizeId %10 %11 %12
                @memcpy(variant[output_offset..][0..6], &[_]u32{ 0x0006014b, 1, 38, 10, 11, 12 });
                output_offset += 6;
                changes += 1;
            }
        }
        input_offset += count;
    }
    if (input_offset != words.len or output_offset != variant.len or changes != 2)
        @compileError("invalid LocalSizeId workgroup fixture");
    break :blk variant;
};
