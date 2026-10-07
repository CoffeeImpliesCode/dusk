//! Immutable SPIR-V 1.0 graphics fixtures. No runtime shader rewriting.
//! Vertex offsets change coverage. Fragment red and green change color.
//! Both stages deliberately use SpecIds 7 and 9 to test stage isolation.

pub const entry_point: [:0]const u8 = "main";

pub const vertex_words = [_]u32{
    0x07230203, 0x00010000, 0, 35, 0,
    0x00020011, 1, // OpCapability Shader
    0x0003000e, 0, 1, // OpMemoryModel Logical GLSL450
    0x0007000f, 0, 1, 0x6e69616d, 0, 10, 11, // Vertex main: index, position
    0x00040005, 18, 0x66696873, 0x00785f74, // OpName shift_x
    0x00040005, 19, 0x66696873, 0x00795f74, // OpName shift_y
    0x00040047, 18, 1, 7, // SpecId 7
    0x00040047, 19, 1, 9, // SpecId 9
    0x00040047, 10, 11, 42, // BuiltIn VertexIndex
    0x00040047, 11, 11, 0, // BuiltIn Position
    0x00020013, 2, // void
    0x00030021, 3, 2, // function void
    0x00020014, 4, // bool
    0x00040015, 5, 32, 1, // i32
    0x00030016, 6, 32, // f32
    0x00040017, 7, 6, 4, // vec4<f32>
    0x00040020, 8, 1, 5, // pointer Input i32
    0x00040020, 9, 3, 7, // pointer Output vec4
    0x0004003b, 8, 10, 1, // index
    0x0004003b, 9, 11, 3, // position
    0x0004002b, 5, 12, 0, // i32 zero
    0x0004002b, 5, 13, 1, // i32 one
    0x0004002b, 6, 14, 0, // f32 zero
    0x0004002b, 6, 15, 0x3f800000, // f32 one
    0x0004002b, 6, 16, 0x3f4ccccd, // f32 0.8
    0x0004002b, 6, 17, 0xbf4ccccd, // f32 -0.8
    0x00040032, 6, 18, 0, // shift_x defaults to zero
    0x00040032, 6, 19, 0, // shift_y defaults to zero
    0x00050036, 2, 1, 0, 3, // function main
    0x000200f8, 20, // label
    0x0004003d, 5, 21, 10, // load index
    0x000500aa, 4, 22, 21, 12, // index == 0
    0x000500aa, 4, 23, 21, 13, // index == 1
    0x000600a9, 6, 24, 23, 16, 17, // index == 1 ? 0.8 : -0.8
    0x000600a9, 6, 25, 22, 14, 24, // index == 0 ? 0 : x
    0x000600a9, 6, 26, 22, 17, 16, // index == 0 ? -0.8 : 0.8
    0x00050081, 6, 27, 25, 18, // x + shift_x
    0x00050081, 6, 28, 26, 19, // y + shift_y
    0x00070050, 7, 29, 27, 28, 14, 15, // position (x, y, 0, 1)
    0x0003003e, 11, 29, // store position
    0x000100fd, // return
    0x00010038, // function end
};

pub const fragment_words = [_]u32{
    0x07230203, 0x00010000, 0, 15, 0,
    0x00020011, 1, // OpCapability Shader
    0x0003000e, 0, 1, // OpMemoryModel Logical GLSL450
    0x0006000f, 4, 1, 0x6e69616d, 0, 7, // Fragment main: color
    0x00030010, 1, 7, // OriginUpperLeft
    0x00030005, 10, 0x00646572, // OpName red
    0x00040005, 11, 0x65657267, 0x0000006e, // OpName green
    0x00040047, 10, 1, 7, // SpecId 7
    0x00040047, 11, 1, 9, // SpecId 9
    0x00040047, 7, 30, 0, // Location 0
    0x00020013, 2, // void
    0x00030021, 3, 2, // function void
    0x00030016, 4, 32, // f32
    0x00040017, 5, 4, 4, // vec4<f32>
    0x00040020, 6, 3, 5, // pointer Output vec4
    0x0004003b, 6, 7, 3, // color
    0x0004002b, 4, 8, 0, // zero
    0x0004002b, 4, 9, 0x3f800000, // one
    0x00040032, 4, 10, 0x3f800000, // red defaults to one
    0x00040032, 4, 11, 0, // green defaults to zero
    0x00050036, 2, 1, 0, 3, // function main
    0x000200f8, 12, // label
    0x00070050, 5, 13, 10, 11, 8, 9, // color (red, green, 0, 1)
    0x0003003e, 7, 13, // store color
    0x000100fd, // return
    0x00010038, // function end
};
