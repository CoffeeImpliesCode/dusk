//! Drives the device arena: ten thousand objects in, one device destroy out.
//!
//! The observable is the child allocator the device arena takes its blocks
//! from. It reports a leak unless the device gave every block back, and it
//! answers after `Device.deinit` has poisoned the device.
//!
//! Every object here takes the two steps `src/core/object.zig:330-339` names:
//! `create` returns the object untracked, the test writes the fields after the
//! header, and `Object.attach` is what puts it in the list.

const std = @import("std");
const core = @import("dusk").core;

/// What the objects and the uncaptured sink report. Every object points at one
/// of these, so the test can tell a teardown that ran from one that did not.
const TeardownLog = struct {
    early_destroy_count: u64 = 0,
    last_reference_released_count: u64 = 0,
    uncaptured_count: u64 = 0,
    last_uncaptured_code: ?core.ErrorCode = null,
    last_uncaptured_message: ?[]u8 = null,

    fn record(self: *TeardownLog, reason: core.DestroyReason) void {
        switch (reason) {
            .early_destroy => self.early_destroy_count += 1,
            .last_reference_released => self.last_reference_released_count += 1,
        }
    }

    fn totalTeardowns(self: *const TeardownLog) u64 {
        return self.early_destroy_count + self.last_reference_released_count;
    }

    fn deinit(self: *TeardownLog, allocator: std.mem.Allocator) void {
        if (self.last_uncaptured_message) |message| allocator.free(message);
        self.* = undefined;
    }
};

const TestObject = struct {
    header: core.Object,
    index: u64,
    log: *TeardownLog,

    // The arena calls this through a comptime check inside the dusk module, so it must be
    // reachable from there; a private decl is invisible to @hasDecl on the far side.
    pub fn destroy(self: *TestObject, reason: core.DestroyReason) void {
        self.log.record(reason);
    }
};

test "ten thousand objects all come back when the device is destroyed" {
    const object_count: usize = 10_000;
    var log: TeardownLog = .{};
    defer log.deinit(std.testing.allocator);
    // The child outlives the device, so it is the ledger that can say where the
    // blocks went once `deinit` has poisoned the receiver.
    var child: std.heap.DebugAllocator(.{}) = .{};
    defer std.testing.expect(child.deinit() == .ok) catch @panic("device block leaked");
    var device = core.Device.init(child.allocator(), .{
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });

    var released_count: u64 = 0;
    for (0..object_count) |index| {
        const created = try device.create(TestObject, .{ .kind = .buffer });
        created.index = index;
        created.log = &log;
        // The attach comes after the field writes and before the `continue`
        // below: an object that skipped it would never reach the list, and
        // `queryTrackedCount` would miss it.
        created.header.attach();

        // Every third object keeps its reference. The rest release theirs, and
        // the last release destroys them.
        if (index % 3 == 0) continue;
        created.header.release();
        released_count += 1;
    }

    const kept_count: usize = object_count - @as(usize, released_count);
    try std.testing.expectEqual(kept_count, device.queryTrackedCount());
    try std.testing.expectEqual(released_count, log.last_reference_released_count);
    try std.testing.expectEqual(@as(u64, 0), log.early_destroy_count);
    try std.testing.expect(device.queryCapacity() > 0);

    device.deinit(std.testing.allocator);

    // The teardown count says every object ran and the child says every block
    // came home. Neither is a read of the device, which is poison from here on,
    // so the tracked count the teardown left is not read back anywhere.
    // `expectEqual` takes `anytype` on both sides, so nothing tells the
    // `@intCast` which width to land in. `TeardownLog` counts teardowns in
    // `u64`, and the count this compares is one object per index, so the
    // width is named here rather than left to inference.
    try std.testing.expectEqual(@as(u64, @intCast(object_count)), log.totalTeardowns());
    try std.testing.expectEqual(@as(u64, 0), log.uncaptured_count);
}

test "a destroyed handle is rejected and its bytes are still readable" {
    var log: TeardownLog = .{};
    defer log.deinit(std.testing.allocator);
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    const created = try device.create(TestObject, .{ .kind = .buffer, .label = "one" });
    created.index = 7;
    created.log = &log;
    created.header.attach();
    const target = device.handleFor(TestObject, created, .buffer);

    try std.testing.expectEqualStrings("one", created.header.label);
    try std.testing.expect(created.header.isAlive());
    try std.testing.expectEqual(core.ObjectState.alive, created.header.state);

    try device.destroy(target);

    try std.testing.expect(!created.header.isAlive());
    try std.testing.expectEqual(core.ObjectState.destroyed, created.header.state);
    try std.testing.expectEqual(@as(u64, 7), created.index);
    try std.testing.expectEqual(@as(u64, 1), log.early_destroy_count);

    try std.testing.expectError(error.StaleHandle, device.destroy(target));
    try std.testing.expectError(error.StaleHandle, device.resolve(TestObject, target));
    try std.testing.expectEqual(@as(u64, 1), log.early_destroy_count);
}

test "a handle of the wrong kind is rejected" {
    var log: TeardownLog = .{};
    defer log.deinit(std.testing.allocator);
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    const created = try device.create(TestObject, .{ .kind = .buffer });
    created.index = 0;
    created.log = &log;
    created.header.attach();

    // The same bytes under a different kind byte. The boundary check rejects it
    // with a message and not with a crash.
    const mislabelled: core.Handle = .{
        .ptr = @as(core.ObjectPtr, created),
        .kind = .texture,
    };
    try std.testing.expectError(error.HandleKindMismatch, device.resolve(TestObject, mislabelled));
    try std.testing.expect(created.header.isAlive());
    try std.testing.expectEqual(@as(u64, 0), log.uncaptured_count);
}

test "an earlier release does not destroy and the last one does" {
    var log: TeardownLog = .{};
    defer log.deinit(std.testing.allocator);
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    const created = try device.create(TestObject, .{ .kind = .buffer });
    created.index = 0;
    created.log = &log;
    created.header.attach();

    created.header.retain();
    created.header.release();
    try std.testing.expect(created.header.isAlive());
    try std.testing.expectEqual(@as(u64, 0), log.totalTeardowns());

    created.header.release();
    try std.testing.expect(!created.header.isAlive());
    try std.testing.expectEqual(@as(u64, 1), log.totalTeardowns());
    try std.testing.expectEqual(@as(u64, 1), log.last_reference_released_count);
}

test "a call that failed names its rule on the object" {
    var log: TeardownLog = .{};
    defer log.deinit(std.testing.allocator);
    var device = core.Device.init(std.testing.allocator, .{
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    defer device.deinit(std.testing.allocator);

    const failed = try device.create(TestObject, .{
        .kind = .buffer,
        .state = .initializing,
    });
    failed.index = 0;
    failed.log = &log;
    failed.header.attach();

    try std.testing.expect(!failed.header.isInitialized());

    // Zig 0.16.0 dropped the coercion from a bare enum literal to an error
    // set, so a value of `core.ValidationError` (`src/core/errors.zig:19`) is
    // spelled `error.Name`. The read-back below is the same value and the same
    // spelling.
    failed.header.setInitializedError(error.BufferSizeTooSmall);
    try std.testing.expect(failed.header.isInitialized());
    try std.testing.expect(failed.header.isFailed());
    try std.testing.expectEqual(
        @as(?core.ValidationError, error.BufferSizeTooSmall),
        failed.header.last_error,
    );

    const plain = try device.create(TestObject, .{
        .kind = .buffer,
        .state = .initializing,
    });
    plain.index = 1;
    plain.log = &log;
    plain.header.attach();

    plain.header.setInitializedNoError();
    try std.testing.expect(plain.header.isInitialized());
    try std.testing.expect(!plain.header.isFailed());
    try std.testing.expectEqual(core.ObjectState.alive, plain.header.state);
    try std.testing.expectEqual(@as(?core.ValidationError, null), plain.header.last_error);
}

fn recordUncaptured(
    allocator: std.mem.Allocator,
    context: *anyopaque,
    data: *const core.ErrorData,
) void {
    const log: *TeardownLog = @ptrCast(@alignCast(context));
    log.uncaptured_count += 1;
    log.last_uncaptured_code = data.code;
    // The device frees the payload as soon as this call returns, so the log
    // takes its own copy of the text now.
    log.last_uncaptured_message = allocator.dupe(u8, data.message) catch {
        std.debug.panic("the test could not copy the uncaptured message", .{});
    };
}
