//! Sweeps the three error sets of `core`.
//!
//! `AGENTS.md` §3 asks that every member of an error set be named by a test.
//! Each member below gets its own assertion, so a failure names the member and
//! not the set.

const std = @import("std");
const core = @import("dusk").core;

test "every member of every set has a message and a class" {
    try sweep(core.ValidationError, .validation);
    try sweep(core.DeviceLostError, .device_lost);
    try sweep(core.UnrecoverableError, .unrecoverable);
}

test "the merged set holds every member of the three sets" {
    // The bound is the merged set itself, so a member added to any set lands
    // here without a second edit.
    inline for (@typeInfo(core.Error).error_set.?) |entry| {
        // Reflection hands back a member's name rather than a value, so
        // `@field` is what turns a swept member into the one `codeFromError`
        // takes (`test/buffer.zig:652-655` sweeps a set the same way).
        const member = @field(core.Error, entry.name);
        const code = core.codeFromError(member);
        try std.testing.expectEqualStrings(@errorName(member), core.nameOf(code));
    }

    const merged_count = @typeInfo(core.Error).error_set.?.len;
    const validation_count = @typeInfo(core.ValidationError).error_set.?.len;
    const device_lost_count = @typeInfo(core.DeviceLostError).error_set.?.len;
    const unrecoverable_count = @typeInfo(core.UnrecoverableError).error_set.?.len;
    try std.testing.expectEqual(
        validation_count + device_lost_count + unrecoverable_count,
        merged_count,
    );
}

test "a validation code renders its table message with the raiser's context" {
    const context = [_]core.ErrorContext{.{ .text = "rgba8unorm" }};
    var data = try core.ErrorData.init(
        std.testing.allocator,
        .{ .validation = error.TextureFormatNotRenderable },
        null,
        &context,
    );
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "texture format rgba8unorm cannot be a render attachment",
        data.message,
    );

    try data.appendContext(std.testing.allocator, .{ .text = "createTexture" });
    const report = try data.report(std.testing.allocator);
    defer std.testing.allocator.free(report);

    // `init` copies the raiser's own context, so the report carries the line
    // the raiser wrote as well as the one `appendContext` added.
    try std.testing.expectEqualStrings(
        "texture format rgba8unorm cannot be a render attachment\n" ++
            " - While rgba8unorm\n - While createTexture",
        report,
    );
}

test "a rule that needs a value the raiser did not supply is its own error" {
    // `TextureFormatNotRenderable` names the format. A raiser that does not
    // know the format has a defect, so the port says so instead of printing
    // half a sentence.
    const no_context: [0]core.ErrorContext = .{};
    const result = core.ErrorData.init(
        std.testing.allocator,
        .{ .validation = error.TextureFormatNotRenderable },
        null,
        &no_context,
    );
    try std.testing.expectError(error.MissingContext, result);
}

test "every allocation the payload makes fails on its own" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildPayload, .{});
}

fn buildPayload(allocator: std.mem.Allocator) !void {
    const context = [_]core.ErrorContext{.{ .text = "rgba8unorm" }};
    var data = try core.ErrorData.init(
        allocator,
        .{ .validation = error.TextureFormatNotRenderable },
        null,
        &context,
    );
    defer data.deinit(allocator);

    try std.testing.expectEqualStrings(
        "texture format rgba8unorm cannot be a render attachment",
        data.message,
    );
}

fn sweep(
    comptime ErrorSet: type,
    comptime tag: std.meta.Tag(core.ErrorCode),
) !void {
    const member_count = @typeInfo(ErrorSet).error_set.?.len;
    try std.testing.expect(member_count > 0);

    // The bound is the set itself: every member is checked once. Reflection
    // hands back a member's name rather than a value, so `@field` is what
    // turns a swept member into the one `tag` names.
    inline for (@typeInfo(ErrorSet).error_set.?) |entry| {
        const member = @field(ErrorSet, entry.name);
        const code: core.ErrorCode = @unionInit(core.ErrorCode, @tagName(tag), member);
        try expectMessageFor(entry.name);
        try std.testing.expectEqualStrings(@tagName(tag), @tagName(core.classOf(code)));
    }
}

/// One assertion per member, so the failure names the member that has no text.
///
/// Both operands carry the member's name, so a failure reports which rule the
/// table is missing rather than a bare `false`.
fn expectMessageFor(comptime member_name: []const u8) !void {
    const found = comptime std.fmt.comptimePrint("{s}: has a message", .{member_name});
    const missing = comptime std.fmt.comptimePrint("{s}: has no message", .{member_name});
    try std.testing.expectEqualStrings(
        found,
        if (core.message_table.get(member_name) != null) found else missing,
    );
}
