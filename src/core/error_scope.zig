//! Error scopes, the stack that owns them, and the sink every error reaches.
//!
//! **What this file is.** The port of Dawn's `ErrorScope`, `ErrorScopeStack` and
//! `ErrorSink` (`src/dawn/native/ErrorScope.h`, `src/dawn/native/ErrorSink.h`).
//!
//! **What this file does not claim.** It does not claim async completion. Dawn
//! holds an error scope open until its pending async tasks finish
//! (`src/dawn/native/ErrorScope.h:61-75`). The worker pool lands at milestone
//! M4, so a scope here is closed by `pop` and by nothing else.

const std = @import("std");
const errors = @import("errors.zig");

/// The three WebGPU filters. Dawn turns each filter into an error type at
/// `src/dawn/native/ErrorScope.cpp:39-49`.
///
/// This is `core`'s own filter, not `api.enums.ErrorFilter`. The wire enum
/// carries the upstream tags 1/2/3 (`src/api/enums.zig:295`-`:298`) because the
/// C entry point `device_push_error_scope` takes it by value
/// (`src/api/proc.zig:106`). `core` sits below `api` in
/// `docs/10-architecture.md`, so it cannot name that enum, and the two tag
/// domains must never be read as one number: an upstream filter crosses into
/// `core` as a `switch`, one member at a time.
pub const ErrorFilter = enum {
    validation,
    out_of_memory,
    internal,
};

/// The WebGPU mapping of a filter onto a code.
///
/// The three filters partition the codes. Dawn's `ErrorFilterToErrorType`
/// (`src/dawn/native/ErrorScope.cpp:39-49`) sends each filter to exactly one
/// `wgpu::ErrorType`, and `GetErrorScopeForErrorType`
/// (`src/dawn/native/ErrorScope.cpp:104-113`) captures on
/// `mMatchedErrorType == type`, so no code is reachable from two filters.
///
/// `out_of_memory` names two members and not the whole unrecoverable set,
/// because `docs/30-port-design.md` §2.1 splits Dawn's one `OutOfMemory` bit
/// into two members that mean different things; `internal` takes what is left,
/// so a memory code never matches twice. Every switch here has no `else`, so a
/// new member in any set is a compile error until this function decides where
/// it goes.
pub fn matchesFilter(filter: ErrorFilter, code: errors.ErrorCode) bool {
    return switch (filter) {
        .validation => switch (code) {
            .validation => true,
            .device_lost, .unrecoverable => false,
        },
        .out_of_memory => switch (code) {
            .validation, .device_lost => false,
            // `ErrorCode.unrecoverable` carries an `UnrecoverableError` value
            // (`src/core/errors.zig:144-148`), so each prong names an error and
            // not an enum member.
            .unrecoverable => |member| switch (member) {
                error.OutOfDeviceMemory => true,
                error.OutOfHostMemory => true,
                error.PipelineUncategorized => false,
                error.InternalInvariantViolated => false,
                error.Unimplemented => false,
            },
        },
        .internal => switch (code) {
            .validation => false,
            .device_lost => true,
            .unrecoverable => |member| switch (member) {
                // The two memory members are already `out_of_memory`. A filter
                // that also claimed them would match one code twice, which
                // Dawn's one-filter-one-`wgpu::ErrorType` map cannot do.
                error.OutOfDeviceMemory => false,
                error.OutOfHostMemory => false,
                error.PipelineUncategorized => true,
                error.InternalInvariantViolated => true,
                error.Unimplemented => true,
            },
        },
    };
}

/// One open scope. The stack owns every scope it holds.
pub const ErrorScope = struct {
    filter: ErrorFilter,
    /// The first error the scope saw. The scope owns the payload this points
    /// at, and not the `ErrorData` itself: `ErrorData.init` returns a value
    /// (`src/core/errors.zig:528-533`) and `docs/40-plan.md:2393` records that
    /// there is no heap node to make unique, so the raiser keeps the struct
    /// alive until the scope is popped.
    ///
    /// Dawn keeps the first error only (`src/dawn/native/ErrorScope.cpp:79-82`),
    /// because WebGPU reports one error per scope.
    captured: ?*errors.ErrorData = null,

    pub fn init(filter: ErrorFilter) ErrorScope {
        return .{ .filter = filter };
    }

    pub fn matches(self: *const ErrorScope, code: errors.ErrorCode) bool {
        return matchesFilter(self.filter, code);
    }

    /// Takes the error by reference. A scope that already holds one frees the
    /// payload of this one and drops the reference, so the raiser never asks
    /// whether its error was taken and never frees the struct.
    pub fn capture(
        self: *ErrorScope,
        allocator: std.mem.Allocator,
        data: *errors.ErrorData,
    ) void {
        if (self.captured != null) {
            data.deinit(allocator);
            return;
        }
        self.captured = data;
    }

    pub fn deinit(self: *ErrorScope, allocator: std.mem.Allocator) void {
        if (self.captured) |data| {
            data.deinit(allocator);
        }
        self.* = undefined;
    }
};

/// Where an error goes when no scope took it.
pub const UncapturedErrorCallback = *const fn (
    allocator: std.mem.Allocator,
    context: *anyopaque,
    data: *const errors.ErrorData,
) void;

/// Popping a stack that holds no scope.
pub const PopError = error{ErrorScopeStackEmpty};

/// The scopes of one device, innermost last.
///
/// Dawn's `ErrorScopeStack` (`src/dawn/native/ErrorScope.h:78-107`).
pub const ErrorScopeStack = struct {
    scopes: std.ArrayList(ErrorScope) = .empty,
    uncaptured_context: *anyopaque,
    uncaptured_callback: UncapturedErrorCallback,

    pub const InitOptions = struct {
        uncaptured_context: *anyopaque,
        uncaptured_callback: UncapturedErrorCallback,
    };

    /// The stack allocates nothing here. Dawn's stack only forwards an error no
    /// scope took to an uncaptured callback it does not own
    /// (`src/dawn/native/ErrorScope.h:92-95`); the port takes the callback at
    /// creation, so no stack is ever without a sink.
    pub fn init(options: InitOptions) ErrorScopeStack {
        return .{
            .scopes = .empty,
            .uncaptured_context = options.uncaptured_context,
            .uncaptured_callback = options.uncaptured_callback,
        };
    }

    pub fn deinit(self: *ErrorScopeStack, allocator: std.mem.Allocator) void {
        const scope_count = self.scopes.items.len;
        for (self.scopes.items[0..scope_count]) |*scope| scope.deinit(allocator);
        self.scopes.deinit(allocator);
        // `std.ArrayList.deinit` poisons `self.*` instead of emptying the
        // list, so there is nothing left to reset and this one write ends the
        // receiver's life.
        self.* = undefined;
    }

    pub fn empty(self: *const ErrorScopeStack) bool {
        return self.scopes.items.len == 0;
    }

    pub fn push(
        self: *ErrorScopeStack,
        allocator: std.mem.Allocator,
        filter: ErrorFilter,
    ) std.mem.Allocator.Error!void {
        try self.scopes.append(allocator, ErrorScope.init(filter));
    }

    /// Removes the innermost scope and hands it to the caller, which then owns
    /// the error the scope captured.
    pub fn pop(self: *ErrorScopeStack) PopError!ErrorScope {
        return self.scopes.pop() orelse error.ErrorScopeStackEmpty;
    }

    /// The innermost scope whose filter takes `code`, or null when no scope
    /// takes it. Dawn walks the scopes back to front
    /// (`src/dawn/native/ErrorScope.cpp:104-113`).
    pub fn scopeForCode(self: *ErrorScopeStack, code: errors.ErrorCode) ?*ErrorScope {
        const scope_count = self.scopes.items.len;
        var index = scope_count;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].matches(code)) return &self.scopes.items[index];
        }
        return null;
    }

    /// Hands the error to the innermost scope that takes it.
    ///
    /// The stack frees the payload in every case: a matching scope keeps the
    /// error and frees it at `deinit`, and an unmatched one goes to the
    /// uncaptured callback and is freed here. The `ErrorData` struct stays the
    /// raiser's, because `docs/40-plan.md:2393` records that there is no heap
    /// node to make unique. The result says whether a scope took it, which is
    /// Dawn's `HandleError` result
    /// (`src/dawn/native/ErrorScope.cpp:115-123`).
    pub fn handleError(
        self: *ErrorScopeStack,
        allocator: std.mem.Allocator,
        data: *errors.ErrorData,
    ) bool {
        const scope = self.scopeForCode(data.code) orelse {
            self.uncaptured_callback(allocator, self.uncaptured_context, data);
            data.deinit(allocator);
            return false;
        };
        scope.capture(allocator, data);
        return true;
    }
};

/// Where one object or one module sends its errors.
///
/// Dawn's `ErrorSink` (`src/dawn/native/ErrorSink.h:39`) is a virtual base
/// class with two pure virtual `ConsumeError` overloads (`:138-143`). The port
/// is a pair of words, so any module can hold one and no module needs a base
/// class.
pub const ErrorSink = struct {
    context: *anyopaque,
    consume_error_callback: *const fn (
        allocator: std.mem.Allocator,
        context: *anyopaque,
        data: *errors.ErrorData,
    ) void,

    pub fn init(
        context: *anyopaque,
        consume_error_callback: *const fn (
            allocator: std.mem.Allocator,
            context: *anyopaque,
            data: *errors.ErrorData,
        ) void,
    ) ErrorSink {
        return .{
            .context = context,
            .consume_error_callback = consume_error_callback,
        };
    }

    /// Hands the error to the sink, which takes the payload.
    ///
    /// Dawn's `ConsumeError` (`src/dawn/native/ErrorSink.h:138-143`) is the
    /// same step over a `unique_ptr`. The port passes a pointer to a value the
    /// raiser owns (`docs/40-plan.md:2393`), so the payload is what changes
    /// hands and not the struct.
    pub fn consumeError(
        self: *const ErrorSink,
        allocator: std.mem.Allocator,
        data: *errors.ErrorData,
    ) void {
        self.consume_error_callback(allocator, self.context, data);
    }
};

const Recorder = struct {
    stack: *ErrorScopeStack,
    sink: ErrorSink,
    consumed: u64 = 0,

    fn consume(allocator: std.mem.Allocator, context: *anyopaque, data: *errors.ErrorData) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.consumed += 1;
        // The sink is `void`, so the test counts what it received rather than
        // what a scope took, which `countUncaptured` already observes.
        _ = self.stack.handleError(allocator, data);
    }
};

test "a scope takes the first error that matches its filter" {
    var uncaptured_count: u64 = 0;
    var stack: ErrorScopeStack = .init(.{
        .uncaptured_context = @ptrCast(&uncaptured_count),
        .uncaptured_callback = countUncaptured,
    });
    defer stack.deinit(std.testing.allocator);

    try std.testing.expect(stack.empty());
    try stack.push(std.testing.allocator, .validation);
    try std.testing.expect(!stack.empty());

    var data = try errors.initValidation(
        std.testing.allocator,
        error.BufferUsageMissingCopyDst,
        &.{.{ .text = "4", .offset = 4 }},
    );
    try std.testing.expect(stack.handleError(std.testing.allocator, &data));

    var scope = try stack.pop();
    defer scope.deinit(std.testing.allocator);
    const held = scope.captured orelse return error.ScopeCapturedNothing;
    try std.testing.expectEqualStrings(
        "buffer usage 4 is missing the usage a copy destination needs",
        held.message,
    );
    try std.testing.expectEqual(@as(u64, 0), uncaptured_count);
    try std.testing.expect(stack.empty());
}

test "an unmatched error goes to the uncaptured callback and is freed" {
    var uncaptured_count: u64 = 0;
    var stack: ErrorScopeStack = .init(.{
        .uncaptured_context = @ptrCast(&uncaptured_count),
        .uncaptured_callback = countUncaptured,
    });
    defer stack.deinit(std.testing.allocator);

    const no_context: [0]errors.ErrorContext = .{};
    try stack.push(std.testing.allocator, .validation);
    var data = try errors.ErrorData.init(
        std.testing.allocator,
        .{ .unrecoverable = error.OutOfDeviceMemory },
        null,
        &no_context,
    );
    try std.testing.expect(!stack.handleError(std.testing.allocator, &data));
    try std.testing.expectEqual(@as(u64, 1), uncaptured_count);

    var scope = try stack.pop();
    defer scope.deinit(std.testing.allocator);
    try std.testing.expect(scope.captured == null);
}

test "a sink hands the payload on and the stack takes it" {
    var uncaptured_count: u64 = 0;
    var stack: ErrorScopeStack = .init(.{
        .uncaptured_context = @ptrCast(&uncaptured_count),
        .uncaptured_callback = countUncaptured,
    });
    defer stack.deinit(std.testing.allocator);

    var recorder: Recorder = .{ .stack = &stack, .sink = undefined };
    recorder.sink = ErrorSink.init(&recorder, Recorder.consume);

    const no_context: [0]errors.ErrorContext = .{};
    try stack.push(std.testing.allocator, .out_of_memory);
    var data = try errors.ErrorData.init(
        std.testing.allocator,
        .{ .unrecoverable = error.OutOfHostMemory },
        null,
        &no_context,
    );
    recorder.sink.consumeError(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u64, 1), recorder.consumed);

    var scope = try stack.pop();
    defer scope.deinit(std.testing.allocator);
    const held = scope.captured orelse return error.ScopeCapturedNothing;
    try std.testing.expectEqualStrings("the host ran out of memory", held.message);
}

fn countUncaptured(
    allocator: std.mem.Allocator,
    context: *anyopaque,
    data: *const errors.ErrorData,
) void {
    const count: *u64 = @ptrCast(@alignCast(context));
    count.* += 1;
    // `Allocator` has no `==`, and its `ptr` may be `undefined`
    // (`lib/std/mem/Allocator.zig:16-19`). The vtable is the one field that
    // names the implementation, and `std.testing.allocator` is a comptime
    // const, so both sides carry the same address.
    std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
    std.debug.assert(data.message.len > 0);
}
