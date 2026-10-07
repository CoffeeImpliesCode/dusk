//! Static native indirect sanitizer definitions. No device state lives here.

// The registry supplies its types to avoid a registry-to-leaf import cycle.
pub fn definition(
    comptime Types: type,
    key: Types.KernelKey,
) error{InvalidKernelKey}!*const Types.Definition {
    const Static = struct {
        const draw_words = Types.words(@embedFile("shaders/indirect_sanitize.comp.spv"));
        const dispatch_words = Types.words(@embedFile("shaders/dispatch_sanitize.comp.spv"));
        const draws: Types.Definition = .{
            .slots = &.{
                .{ .buffer = .{ .access = .storage_read, .min_size = 16 } },
                .{ .buffer = .{ .access = .storage_read, .min_size = 4 } },
                .{ .buffer = .{ .access = .storage_read, .min_size = 32 } },
                .{ .buffer = .{ .access = .storage_write, .min_size = 16 } },
            },
            .parameter_size = 32,
            .stages = .{ .compute = .{
                .stage = .{ .words = &draw_words, .entry_point = "sanitize_draws" },
                .workgroup_size = .{ 64, 1, 1 },
            } },
        };
        const dispatch: Types.Definition = .{
            .slots = &.{
                .{ .buffer = .{ .access = .storage_read, .min_size = 12 } },
                .{ .buffer = .{ .access = .storage_write, .min_size = 12 } },
            },
            .parameter_size = 16,
            .stages = .{ .compute = .{
                .stage = .{ .words = &dispatch_words, .entry_point = "sanitize_dispatch" },
                .workgroup_size = .{ 1, 1, 1 },
            } },
        };
    };
    return switch (key.id) {
        .sanitize_draws => &Static.draws,
        .sanitize_dispatch => &Static.dispatch,
        else => error.InvalidKernelKey,
    };
}
