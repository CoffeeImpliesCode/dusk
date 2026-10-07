//! The finite timestamp conversion shader has no optional arithmetic capability.
const std = @import("std");

pub const entry_point: [:0]const u8 = "timestamp_convert";
pub const workgroup_size: [3]u32 = .{ 8, 1, 1 };
pub const parameter_size: u32 = 32;
const shader_bytes = @embedFile("shaders/timestamp_convert.comp.spv");
pub const words = decodeWords(shader_bytes);

fn decodeWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    if (bytes.len % 4 != 0) @compileError("timestamp SPIR-V must contain whole words");
    @setEvalBranchQuota(100_000);
    var result: [bytes.len / 4]u32 = undefined;
    for (&result, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    return result;
}

pub fn definition(comptime Types: type, key: Types.KernelKey) error{InvalidKernelKey}!*const Types.Definition {
    if (key.id != .timestamp_to_nanoseconds or key.source_format != .undefined_ or
        key.source_dimension != .undefined_ or key.source_multisampled or
        key.storage_format != .undefined_ or key.attachments != null or
        key.color_write_slots != 0 or key.stencil_write_bit != null or
        key.conversion_sampler != null)
    {
        return error.InvalidKernelKey;
    }
    const Static = struct {
        const value: Types.Definition = .{
            .slots = &.{
                .{ .buffer = .{ .access = .storage_read, .min_size = 8 } },
                .{ .buffer = .{ .access = .storage_write, .min_size = 8 } },
            },
            .parameter_size = parameter_size,
            .stages = .{ .compute = .{
                .stage = .{ .words = &words, .entry_point = entry_point },
                .workgroup_size = workgroup_size,
            } },
        };
    };
    return &Static.value;
}
