//! Drives the error scopes: a pushed scope takes the error it matches, and an
//! error it does not match reaches the uncaptured callback.
//!
//! The observable is the captured message and the captured code, not the fact
//! that a scope exists.

const std = @import("std");
const core = @import("dusk").core;

const Uncaptured = struct {
    allocator: std.mem.Allocator,
    count: u64 = 0,
    code: ?core.ErrorCode = null,
    message: ?[]u8 = null,

    fn deinit(self: *Uncaptured) void {
        if (self.message) |message| self.allocator.free(message);
        self.* = undefined;
    }
};

test "a validation scope captures the first error with its message and its code" {
    var uncaptured: Uncaptured = .{ .allocator = std.testing.allocator };
    defer uncaptured.deinit();
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    try device.pushErrorScope(std.testing.allocator, .validation);

    const context = [_]core.ErrorContext{.{ .text = "rgba8unorm" }};
    var data = try core.ErrorData.init(
        std.testing.allocator,
        .{ .validation = error.TextureFormatNotRenderable },
        null,
        &context,
    );
    const captured = device.handleError(std.testing.allocator, &data);
    try std.testing.expect(captured);

    var scope = try device.popErrorScope();
    defer scope.deinit(std.testing.allocator);

    const held = scope.captured orelse return error.ScopeCapturedNothing;
    try std.testing.expectEqual(
        core.ErrorCode{ .validation = error.TextureFormatNotRenderable },
        held.code,
    );
    try std.testing.expectEqual(core.ErrorClass.validation, core.classOf(held.code));
    try std.testing.expectEqualStrings(
        "texture format rgba8unorm cannot be a render attachment",
        held.message,
    );
    try std.testing.expectEqual(@as(u64, 0), uncaptured.count);
}

test "an error no scope matched reaches the uncaptured callback" {
    var uncaptured: Uncaptured = .{ .allocator = std.testing.allocator };
    defer uncaptured.deinit();
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    try device.pushErrorScope(std.testing.allocator, .validation);

    // A device-lost error does not match a validation filter.
    const no_context: [0]core.ErrorContext = .{};
    var data = try core.ErrorData.init(
        std.testing.allocator,
        .{ .device_lost = error.DeviceLost },
        null,
        &no_context,
    );
    const captured = device.handleError(std.testing.allocator, &data);
    try std.testing.expect(!captured);

    try std.testing.expectEqual(@as(u64, 1), uncaptured.count);
    try std.testing.expectEqual(
        @as(?core.ErrorCode, .{ .device_lost = error.DeviceLost }),
        uncaptured.code,
    );
    const message = uncaptured.message orelse return error.UncapturedMessageMissing;
    try std.testing.expectEqualStrings(
        "the device was lost and every submitted command is gone",
        message,
    );

    var scope = try device.popErrorScope();
    defer scope.deinit(std.testing.allocator);
    try std.testing.expect(scope.captured == null);
}

test "the innermost matching scope takes the error and an outer one waits" {
    var uncaptured: Uncaptured = .{ .allocator = std.testing.allocator };
    defer uncaptured.deinit();
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    try device.pushErrorScope(std.testing.allocator, .internal);
    try device.pushErrorScope(std.testing.allocator, .validation);

    const no_context: [0]core.ErrorContext = .{};
    var data = try core.ErrorData.init(
        std.testing.allocator,
        .{ .validation = error.EncoderAlreadyFinished },
        null,
        &no_context,
    );
    const captured = device.handleError(std.testing.allocator, &data);
    try std.testing.expect(captured);

    var inner = try device.popErrorScope();
    defer inner.deinit(std.testing.allocator);
    const held = inner.captured orelse return error.ScopeCapturedNothing;
    try std.testing.expectEqualStrings(
        "the command encoder has already finished",
        held.message,
    );

    var outer = try device.popErrorScope();
    defer outer.deinit(std.testing.allocator);
    try std.testing.expect(outer.captured == null);
    try std.testing.expectEqual(@as(u64, 0), uncaptured.count);
}

test "a scope keeps the first error and frees the ones after it" {
    var uncaptured: Uncaptured = .{ .allocator = std.testing.allocator };
    defer uncaptured.deinit();
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    try device.pushErrorScope(std.testing.allocator, .validation);

    const first_context = [_]core.ErrorContext{.{ .text = "2", .offset = 2 }};
    var first = try core.ErrorData.init(
        std.testing.allocator,
        .{ .validation = error.BufferSizeTooSmall },
        null,
        &first_context,
    );
    try std.testing.expect(device.handleError(std.testing.allocator, &first));

    const no_context: [0]core.ErrorContext = .{};
    var second = try core.ErrorData.init(
        std.testing.allocator,
        .{ .validation = error.EncoderAlreadyFinished },
        null,
        &no_context,
    );
    try std.testing.expect(device.handleError(std.testing.allocator, &second));

    var scope = try device.popErrorScope();
    defer scope.deinit(std.testing.allocator);

    const held = scope.captured orelse return error.ScopeCapturedNothing;
    try std.testing.expectEqual(
        core.ErrorCode{ .validation = error.BufferSizeTooSmall },
        held.code,
    );
    try std.testing.expectEqualStrings(
        "buffer size 2 is smaller than the four bytes a u32 needs",
        held.message,
    );
}

test "popping a stack with no scope is its own error" {
    var uncaptured: Uncaptured = .{ .allocator = std.testing.allocator };
    defer uncaptured.deinit();
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    try std.testing.expectError(error.ErrorScopeStackEmpty, device.popErrorScope());
}

test "every code matches exactly the filters WebGPU gives it" {
    // The bound is each set itself, so a new member is checked without a
    // second edit. Reflection hands back each member's name rather than a
    // value, so `@field` is what turns a swept member into the value a filter
    // matches on (`test/buffer.zig:652-655` sweeps a set the same way).
    inline for (@typeInfo(core.ValidationError).error_set.?) |entry| {
        const code: core.ErrorCode = .{ .validation = @field(core.ValidationError, entry.name) };
        try expectFilter(code, .validation, true);
        try expectFilter(code, .out_of_memory, false);
        try expectFilter(code, .internal, false);
    }
    inline for (@typeInfo(core.DeviceLostError).error_set.?) |entry| {
        const code: core.ErrorCode = .{ .device_lost = @field(core.DeviceLostError, entry.name) };
        try expectFilter(code, .validation, false);
        try expectFilter(code, .out_of_memory, false);
        try expectFilter(code, .internal, true);
    }
    inline for (@typeInfo(core.UnrecoverableError).error_set.?) |entry| {
        const member = @field(core.UnrecoverableError, entry.name);
        const code: core.ErrorCode = .{ .unrecoverable = member };
        const is_memory = member == error.OutOfDeviceMemory or member == error.OutOfHostMemory;
        try expectFilter(code, .validation, false);
        try expectFilter(code, .out_of_memory, is_memory);
        try expectFilter(code, .internal, !is_memory);
    }
}

test "pushing and popping a scope survives a failing allocator" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pushAndPop, .{});
}

fn pushAndPop(allocator: std.mem.Allocator) !void {
    var uncaptured: Uncaptured = .{ .allocator = allocator };
    defer uncaptured.deinit();
    var device = core.Device.init(allocator, .{
        .uncaptured_context = @ptrCast(&uncaptured),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(allocator);

    try device.pushErrorScope(allocator, .validation);
    var scope = try device.popErrorScope();
    scope.deinit(allocator);
}

fn expectFilter(code: core.ErrorCode, filter: core.ErrorFilter, want: bool) !void {
    try std.testing.expectEqual(want, core.matchesFilter(filter, code));
}

fn recordUncaptured(
    allocator: std.mem.Allocator,
    context: *anyopaque,
    data: *const core.ErrorData,
) void {
    const uncaptured: *Uncaptured = @ptrCast(@alignCast(context));
    uncaptured.count += 1;
    uncaptured.code = data.code;
    // The device frees the payload as soon as this call returns, so the sink
    // takes its own copy of the text now.
    uncaptured.message = allocator.dupe(u8, data.message) catch {
        std.debug.panic("the test could not copy the uncaptured message", .{});
    };
}
