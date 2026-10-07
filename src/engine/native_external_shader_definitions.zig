//! Fixed external-texture kernel definitions. Shader generation is offline.
//! Metadata follows Dawn 32f77c02294310054a660c393feded4bcb3f203c:
//! ExternalTexture.h:49-82 and multiplanar_external_texture.cc:381-403.
const std = @import("std");

pub const metadata_size: u32 = 288;
pub const browser_parameter_size: u32 = 160;
pub const ordinary_entry_point: [:0]const u8 = "external_ordinary";
pub const hardware_entry_point: [:0]const u8 = "external_ycbcr";

pub fn fragment(comptime Types: type, comptime hardware: bool) Types.Stage {
    const table = Table(Types);
    return if (hardware)
        table.hardware.stages.render.fragment
    else
        table.ordinary.stages.render.fragment;
}

pub fn definition(comptime Types: type, key: Types.KernelKey) error{InvalidKernelKey}!*const Types.Definition {
    if (key.id != .external_to_color) return error.InvalidKernelKey;
    if (key.source_format != .undefined_) return error.InvalidKernelKey;
    if (key.source_dimension != .undefined_) return error.InvalidKernelKey;
    if (key.source_multisampled) return error.InvalidKernelKey;
    if (key.storage_format != .undefined_) return error.InvalidKernelKey;
    if (key.attachments == null) return error.InvalidKernelKey;
    if (key.color_write_slots != 1) return error.InvalidKernelKey;
    if (key.stencil_write_bit != null) return error.InvalidKernelKey;
    if (try Types.colorScalarKind(key.attachments.?.value.color_formats[0]) != .float) {
        return error.InvalidKernelKey;
    }
    const table = Table(Types);
    return if (key.conversion_sampler == null) &table.ordinary else &table.hardware;
}

fn Table(comptime Types: type) type {
    return struct {
        const ordinary_slots = [_]Types.Slot{
            .{ .sampled_view = .{
                .dimension = ._2d,
                .sample_type = .float,
                .multisampled = false,
            } },
            .{ .sampled_view = .{
                .dimension = ._2d,
                .sample_type = .float,
                .multisampled = false,
            } },
            .{ .sampler = .{ .comparison = false } },
            .{ .buffer = .{ .access = .uniform, .min_size = metadata_size } },
        };
        const hardware_slots = [_]Types.Slot{
            .combined_y_cb_cr_view,
            .{ .buffer = .{ .access = .uniform, .min_size = metadata_size } },
        };
        const ordinary_words = decode(@embedFile("shaders/external_ordinary.frag.spv"));
        const hardware_words = decode(@embedFile("shaders/external_ycbcr.frag.spv"));
        const ordinary: Types.Definition = .{
            .slots = &ordinary_slots,
            .parameter_size = browser_parameter_size,
            .stages = .{ .render = .{
                .vertex = Types.fullscreen_vertex,
                .fragment = .{
                    .words = &ordinary_words,
                    .entry_point = ordinary_entry_point,
                },
            } },
        };
        const hardware: Types.Definition = .{
            .slots = &hardware_slots,
            .parameter_size = browser_parameter_size,
            .stages = .{ .render = .{
                .vertex = Types.fullscreen_vertex,
                .fragment = .{
                    .words = &hardware_words,
                    .entry_point = hardware_entry_point,
                },
            } },
        };
    };
}

fn decode(comptime bytes: []const u8) [bytes.len / 4]u32 {
    @setEvalBranchQuota(100_000);
    if (bytes.len % 4 != 0) @compileError("External shader byte count is not word aligned");
    var words: [bytes.len / 4]u32 = undefined;
    for (&words, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    return words;
}
