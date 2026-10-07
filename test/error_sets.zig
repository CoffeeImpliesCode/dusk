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

test "a reserved error owns a worker-local draft after its source frame returns" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var payloads = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const reference = try publishWorkerError(headers.allocator(), payloads.allocator());
    defer reference.release();

    const view = reference.view();
    try std.testing.expectEqualStrings(
        "texture format rgba8unorm cannot be a render attachment",
        view.message,
    );
    try std.testing.expectEqualStrings("rgba8unorm", view.context[0].text);
    try std.testing.expectEqualStrings("worker creation", view.context[1].text);
    try std.testing.expectEqualStrings("TextureFormatNotRenderable", core.nameOf(view.code));
    try std.testing.expect(view.backtrace == null);
}

test "retaining a sealed error survives the original reference release" {
    var reservation = try core.ErrorReservation.prepare(std.testing.allocator);
    defer reservation.discard();
    var draft = try core.ErrorDraft.initMessage(
        std.testing.allocator,
        .{ .device_lost = error.DeviceLost },
        "first native loss",
        &.{},
    );
    defer draft.discard();
    const first = reservation.seal(&draft);
    const retained = try first.retain();
    first.release();
    defer retained.release();
    try std.testing.expectEqualStrings("first native loss", retained.view().message);
}

test "the last error release uses distinct header and payload source allocators" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var payloads = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reservation = try core.ErrorReservation.prepare(headers.allocator());
    defer reservation.discard();
    try reservation.reserveReferences(1);
    var draft = try core.ErrorDraft.initMessage(
        payloads.allocator(),
        .{ .device_lost = error.DeviceDestroyed },
        "owned loss",
        &.{.{ .text = "destroyDevice" }},
    );
    defer draft.discard();
    const reference = reservation.seal(&draft);
    // This alias consumes the second reference prepaid before publication.
    const scope_reference = reference;
    reference.release();
    try std.testing.expectEqual(@as(usize, 0), headers.deallocations);
    try std.testing.expectEqual(@as(usize, 0), payloads.deallocations);
    try std.testing.expectEqualStrings("owned loss", scope_reference.view().message);
    scope_reference.release();
    try std.testing.expectEqual(headers.allocated_bytes, headers.freed_bytes);
    try std.testing.expectEqual(payloads.allocated_bytes, payloads.freed_bytes);
    try std.testing.expectEqual(headers.allocations, headers.deallocations);
    try std.testing.expectEqual(payloads.allocations, payloads.deallocations);
}

test "losing drafts and unused reservations dispose exactly once" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var payloads = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reservation = try core.ErrorReservation.prepare(headers.allocator());
    try reservation.reserveReferences(7);
    var losing = try core.ErrorDraft.initMessage(
        payloads.allocator(),
        .{ .unrecoverable = error.PipelineUncategorized },
        "late worker failure",
        &.{.{ .text = "late worker" }},
    );
    losing.discard();
    losing.discard();
    reservation.discard();
    reservation.discard();
    try std.testing.expectEqual(headers.allocations, headers.deallocations);
    try std.testing.expectEqual(payloads.allocations, payloads.deallocations);
    try std.testing.expectEqual(headers.allocated_bytes, headers.freed_bytes);
    try std.testing.expectEqual(payloads.allocated_bytes, payloads.freed_bytes);
}

test "every reserved error and multi-context draft allocation rolls back without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildReservedError, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, abandonReservedError, .{});
}

test "sealing owned error storage does not allocate even when both allocators now fail" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var payloads = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reservation = try core.ErrorReservation.prepare(headers.allocator());
    defer reservation.discard();
    var draft = try core.ErrorDraft.initMessage(
        payloads.allocator(),
        .{ .device_lost = error.DeviceLost },
        "native loss detail",
        &.{.{ .text = "queue wait" }},
    );
    defer draft.discard();
    const message_pointer = draft.data.?.message.ptr;
    headers.fail_index = headers.alloc_index;
    payloads.fail_index = payloads.alloc_index;
    const reference = reservation.seal(&draft);
    defer reference.release();
    try std.testing.expectEqual(@as([*]const u8, message_pointer), reference.view().message.ptr);
    try std.testing.expect(draft.data == null);
    try std.testing.expect(!headers.has_induced_failure);
    try std.testing.expect(!payloads.has_induced_failure);
}

test "static emergency errors survive the source frame without payload allocation" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const oom = try publishStaticError(headers.allocator(), .oom);
    const native = try publishStaticError(headers.allocator(), .native);
    const loss = try publishStaticError(headers.allocator(), .loss);
    try std.testing.expectEqualStrings("Out of memory", oom.view().message);
    try std.testing.expectEqualStrings("FenceWaitTimedOut", native.view().message);
    try std.testing.expectEqualStrings("Device lost", loss.view().message);
    try std.testing.expectEqualStrings("OutOfHostMemory", core.nameOf(oom.view().code));
    try std.testing.expectEqualStrings("PipelineUncategorized", core.nameOf(native.view().code));
    try std.testing.expectEqualStrings("DeviceDestroyed", core.nameOf(loss.view().code));
    try std.testing.expectEqual(@as(usize, 0), native.view().context.len);
    try std.testing.expect(native.view().backtrace == null);
    oom.release();
    native.release();
    loss.release();
    try std.testing.expectEqual(@as(usize, 3), headers.allocations);
    try std.testing.expectEqual(headers.allocations, headers.deallocations);
}

test "unused prepaid slots can be released while the delivered reference stays live" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reservation = try core.ErrorReservation.prepare(headers.allocator());
    defer reservation.discard();
    try reservation.reserveReferences(4);
    const reference = reservation.sealOutOfMemory();
    reference.releaseMany(4);
    try std.testing.expectEqualStrings("Out of memory", reference.view().message);
    try std.testing.expectEqual(@as(usize, 0), headers.deallocations);
    reference.release();
    try std.testing.expectEqual(headers.allocations, headers.deallocations);
}

test "reference reservation rejects overflow without changing its previous quota" {
    var reservation = try core.ErrorReservation.prepare(std.testing.allocator);
    defer reservation.discard();
    try std.testing.expectError(
        error.ErrorReferenceCountOverflow,
        reservation.reserveReferences(std.math.maxInt(u32)),
    );
    const reference = reservation.sealOutOfMemory();
    reference.release();
}

test "sealed error retain rejects checked reference count overflow" {
    var headers = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reservation = try core.ErrorReservation.prepare(headers.allocator());
    defer reservation.discard();
    try reservation.reserveReferences(std.math.maxInt(u32) - 1);
    const reference = reservation.sealOutOfMemory();
    try std.testing.expectError(error.ErrorReferenceCountOverflow, reference.retain());
    // Every prepaid reference is consumed. This test does not loop billions of times.
    reference.releaseMany(std.math.maxInt(u32));
    try std.testing.expectEqual(headers.allocations, headers.deallocations);
}

fn publishWorkerError(
    header_allocator: std.mem.Allocator,
    payload_allocator: std.mem.Allocator,
) !core.ErrorRef {
    var reservation = try core.ErrorReservation.prepare(header_allocator);
    defer reservation.discard();
    var source_text = "rgba8unorm".*;
    var trace_addresses = [_]usize{0x1234};
    var trace: std.builtin.StackTrace = .{
        .index = 1,
        .instruction_addresses = &trace_addresses,
    };
    var data = try core.ErrorData.init(
        payload_allocator,
        .{ .validation = error.TextureFormatNotRenderable },
        &trace,
        &.{.{ .text = &source_text }},
    );
    var draft = core.ErrorDraft.fromOwned(payload_allocator, &data);
    defer draft.discard();
    try draft.appendContext(.{ .text = "worker creation" });
    @memset(&source_text, 'x');
    const reference = reservation.seal(&draft);
    // The moved draft's deferred disposal must not free the sealed payload.
    return reference;
}

fn buildReservedError(allocator: std.mem.Allocator) !void {
    var reservation = try core.ErrorReservation.prepare(allocator);
    defer reservation.discard();
    var draft = try core.ErrorDraft.init(
        allocator,
        .{ .validation = error.TextureFormatNotRenderable },
        &.{ .{ .text = "rgba8unorm" }, .{ .text = "createTexture" } },
    );
    defer draft.discard();
    try draft.appendContext(.{ .text = "worker frame" });
    const reference = reservation.seal(&draft);
    defer reference.release();
    try std.testing.expectEqual(@as(usize, 3), reference.view().context.len);
}

fn abandonReservedError(allocator: std.mem.Allocator) !void {
    var reservation = try core.ErrorReservation.prepare(allocator);
    defer reservation.discard();
    var draft = try core.ErrorDraft.initMessage(
        allocator,
        .{ .unrecoverable = error.PipelineUncategorized },
        "losing outcome",
        &.{ .{ .text = "createPipeline" }, .{ .text = "worker result" } },
    );
    defer draft.discard();
}

fn publishStaticError(
    allocator: std.mem.Allocator,
    kind: enum { oom, native, loss },
) !core.ErrorRef {
    var reservation = try core.ErrorReservation.prepare(allocator);
    defer reservation.discard();
    return switch (kind) {
        .oom => reservation.sealOutOfMemory(),
        .native => reservation.sealNativeError(
            .{ .unrecoverable = error.PipelineUncategorized },
            @as(error{FenceWaitTimedOut}, error.FenceWaitTimedOut),
        ),
        .loss => reservation.sealDeviceLostFallback(error.DeviceDestroyed),
    };
}
