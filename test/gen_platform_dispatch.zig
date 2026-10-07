const std = @import("std");
const gen_platform_dispatch = @import("../tools/gen_platform_dispatch.zig");

const targets = [_]gen_platform_dispatch.Target{
    .{ .linux = .{} },
    .{ .linux = .{ .wayland = true } },
    .android,
};

test "platform dispatch renderer propagates output failure" {
    for (targets) |target| {
        var buffer: [0]u8 = .{};
        var writer = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.WriteFailed, gen_platform_dispatch.render(&writer, target));
    }
}
