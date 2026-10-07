//! Keeps API format identity separate from physical Vulkan format conversion.
const std = @import("std");
const native = @import("native_render_state.zig");
const api = @import("../api/api.zig");
const vulkan = @import("vulkan");

test "native depth conversion preserves distinct declared semantic formats" {
    const logical: native.DepthStencilState = .{ .format = .depth24_plus };
    const physical: native.DepthStencilState = .{ .format = .depth32_float };
    try std.testing.expect(logical.format != physical.format);
    try std.testing.expectEqual(logical.toNative().format, physical.toNative().format);
    try std.testing.expectEqual(api.TextureFormat.depth24_plus, logical.format);
}

test "native color conversion preserves absent slots and every blend field" {
    const hole: native.ColorTargetState = .{ .format = .undefined_, .write_mask = 0 };
    try std.testing.expectEqual(@as(vulkan.VkFormat, vulkan.VK_FORMAT_UNDEFINED), hole.toNative().format);
    const source: native.ColorTargetState = .{
        .format = .rgba8_unorm,
        .write_mask = 5,
        .blend = .{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
            .alpha = .{ .src_factor = .one, .dst_factor = .zero, .operation = .max },
        },
    };
    const result = source.toNative();
    try std.testing.expectEqual(source.write_mask, result.write_mask);
    try std.testing.expectEqual(source.blend, result.blend);
}
