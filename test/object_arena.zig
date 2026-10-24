//! Exercises guarded arena ownership, handle validation, and payload retirement.
//! The child allocator outlives the device and detects leaked arena blocks.

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
    pub fn destroy(self: *TestObject, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = io;
        self.log.record(reason);
    }
};

test "ten thousand owned aliases release after device payload retirement" {
    const object_count: usize = 10_000;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(std.testing.allocator);
    var child: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(child.deinit() == 0) catch @panic("device block leaked");
    const gpa = child.allocator();
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    var kept: [object_count]?*TestObject = @splat(null);
    var live = true;
    defer {
        if (live) {
            for (kept) |entry| {
                if (entry) |created| created.header.releaseUserLocked(&guard, io) catch @panic("owned alias release failed");
            }
            device.deinit(gpa, &guard) catch @panic("owned alias leaked");
        }
    }
    var released_count: u64 = 0;
    for (0..object_count) |index| {
        const created = try device.create(gpa, &guard, TestObject, .{
            .kind = .buffer,
            .initial_reference = .user,
        });
        created.index = index;
        created.log = &log;
        created.header.attach(&guard, io);
        if (index % 3 == 0) {
            kept[index] = created;
        } else {
            try created.header.releaseUserLocked(&guard, io);
            released_count += 1;
        }
    }

    const kept_count: usize = object_count - @as(usize, @intCast(released_count));
    try std.testing.expectEqual(kept_count, device.queryTrackedCount(&guard));
    try std.testing.expectEqual(released_count, log.last_reference_released_count);
    try std.testing.expectEqual(@as(u64, 0), log.early_destroy_count);
    const capacity = device.queryCapacity(&guard);
    try std.testing.expect(capacity > 0);
    try std.testing.expectError(error.ResourceInUse, device.deinit(gpa, &guard));
    try std.testing.expectError(error.AllocatorMismatch, device.deinit(std.testing.allocator, &guard));
    try std.testing.expect(kept[0].?.header.isAlive(&guard));
    try std.testing.expectEqual(kept_count, device.queryTrackedCount(&guard));
    try std.testing.expectEqual(capacity, device.queryCapacity(&guard));
    try std.testing.expectEqual(released_count, log.totalTeardowns());

    device.retirePayloadsLocked(&guard, io, .early_destroy);
    try std.testing.expectEqual(kept_count, device.queryTrackedCount(&guard));
    for (&kept) |*entry| {
        if (entry.*) |created| {
            try std.testing.expect(!created.header.isAlive(&guard));
            try created.header.releaseUserLocked(&guard, io);
            entry.* = null;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
    try device.deinit(gpa, &guard);
    live = false;
    try std.testing.expectEqual(@as(u64, object_count), log.totalTeardowns());
    try std.testing.expectEqual(@as(u64, 0), log.uncaptured_count);
}

test "payload retirement rejects resolve but permits owned alias release" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("owned alias leaked");

    var label = [_]u8{ 'o', 'n', 'e' };
    const created = try device.create(gpa, &guard, TestObject, .{
        .kind = .buffer,
        .initial_reference = .user,
        .label = &label,
    });
    created.index = 7;
    created.log = &log;
    created.header.attach(&guard, io);
    const target = device.handleFor(&guard, TestObject, created, .buffer);
    defer {
        const header = device.resolveReference(&guard, target) catch @panic("owned alias lost");
        header.releaseUserLocked(&guard, io) catch @panic("owned alias release failed");
    }
    label[0] = 'x';
    try std.testing.expectEqualStrings("one", created.header.label);
    try std.testing.expect(created.header.isAlive(&guard));
    try device.destroy(&guard, io, target);
    try std.testing.expect(!created.header.isAlive(&guard));
    try std.testing.expectEqual(core.ObjectState.destroyed, created.header.state);
    try std.testing.expectEqual(@as(u64, 1), log.early_destroy_count);
    try std.testing.expectError(error.StaleHandle, device.destroy(&guard, io, target));
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, TestObject, target));
    const retained_header = try device.resolveReference(&guard, target);
    try retained_header.retainUserLocked(&guard);
    try retained_header.releaseUserLocked(&guard, io);
    try std.testing.expectError(error.ResourceInUse, device.deinit(gpa, &guard));
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 1), log.totalTeardowns());
}

test "a handle of the wrong kind is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("owned alias leaked");

    const created = try device.create(gpa, &guard, TestObject, .{ .kind = .buffer, .initial_reference = .user });
    created.index = 0;
    created.log = &log;
    created.header.attach(&guard, io);
    defer created.header.releaseUserLocked(&guard, io) catch @panic("owned alias release failed");
    const mislabelled: core.Handle = .{
        .ptr = @as(core.ObjectPtr, created),
        .kind = .texture,
    };
    try std.testing.expectError(error.HandleKindMismatch, device.resolve(&guard, TestObject, mislabelled));
    try std.testing.expectError(error.HandleKindMismatch, device.resolveReference(&guard, mislabelled));
    try std.testing.expect(created.header.isAlive(&guard));
    try std.testing.expectEqual(@as(u64, 0), log.uncaptured_count);
}

test "an earlier user release does not destroy and the last one does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("owned alias leaked");

    const created = try device.create(gpa, &guard, TestObject, .{ .kind = .buffer, .initial_reference = .user });
    created.index = 0;
    created.log = &log;
    created.header.attach(&guard, io);
    const target = device.handleFor(&guard, TestObject, created, .buffer);
    try created.header.retainUserLocked(&guard);
    try created.header.releaseUserLocked(&guard, io);
    try std.testing.expect(created.header.isAlive(&guard));
    try std.testing.expectEqual(@as(u64, 0), log.totalTeardowns());
    try created.header.releaseUserLocked(&guard, io);
    try std.testing.expect(!created.header.isAlive(&guard));
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, TestObject, target));
    try std.testing.expectError(error.StaleHandle, device.resolveReference(&guard, target));
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 1), log.last_reference_released_count);
}

test "failed core objects stay live until retirement and late user release" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = @ptrCast(&log),
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("owned alias leaked");

    const failed = try device.create(gpa, &guard, TestObject, .{
        .kind = .buffer,
        .initial_reference = .user,
        .state = .initializing,
    });
    failed.index = 0;
    failed.log = &log;
    try std.testing.expect(!failed.header.isInitialized(&guard));
    failed.header.setInitializedError(&guard, error.BufferSizeTooSmall);
    failed.header.attach(&guard, io);
    try std.testing.expect(failed.header.isInitialized(&guard));
    try std.testing.expect(failed.header.isFailed(&guard));
    try std.testing.expect(failed.header.isAlive(&guard));
    try std.testing.expectEqual(@as(?core.ValidationError, error.BufferSizeTooSmall), failed.header.last_error);
    const target = device.handleFor(&guard, TestObject, failed, .buffer);
    var failed_user_count: u2 = 1;
    defer {
        for (0..failed_user_count) |_| {
            const header = device.resolveReference(&guard, target) catch @panic("failed alias lost");
            header.releaseUserLocked(&guard, io) catch @panic("failed alias release failed");
        }
    }
    try std.testing.expectEqual(failed, try device.resolve(&guard, TestObject, target));
    try failed.header.retainUserLocked(&guard);
    failed_user_count += 1;
    try std.testing.expectEqual(@as(u32, 2), failed.header.reference_count);
    try std.testing.expectEqual(@as(u32, 2), failed.header.user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectError(error.ResourceInUse, device.deinit(gpa, &guard));
    try std.testing.expect(failed.header.isFailed(&guard));
    try std.testing.expectEqual(@as(u64, 0), log.totalTeardowns());

    const plain = try device.create(gpa, &guard, TestObject, .{
        .kind = .buffer,
        .initial_reference = .user,
        .state = .initializing,
    });
    plain.index = 1;
    plain.log = &log;
    defer plain.header.releaseUserLocked(&guard, io) catch @panic("owned alias release failed");
    plain.header.setInitializedNoError(&guard);
    plain.header.attach(&guard, io);
    try std.testing.expect(plain.header.isInitialized(&guard));
    try std.testing.expect(!plain.header.isFailed(&guard));
    try std.testing.expectEqual(core.ObjectState.alive, plain.header.state);
    try std.testing.expectEqual(@as(?core.ValidationError, null), plain.header.last_error);
    try device.destroy(&guard, io, target);
    try std.testing.expectError(error.StaleHandle, device.resolve(&guard, TestObject, target));
    try std.testing.expectEqual(@as(u64, 1), log.early_destroy_count);
    try std.testing.expectError(error.StaleHandle, device.destroy(&guard, io, target));
    try std.testing.expectEqual(@as(u32, 2), failed.header.reference_count);
    try std.testing.expectEqual(@as(u32, 2), failed.header.user_reference_count);
    try std.testing.expectEqual(@as(usize, 2), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(&failed.header, try device.resolveReference(&guard, target));
    try failed.header.releaseUserLocked(&guard, io);
    failed_user_count -= 1;
    try std.testing.expectEqual(@as(u32, 1), failed.header.reference_count);
    try std.testing.expectEqual(&failed.header, try device.resolveReference(&guard, target));
    try failed.header.releaseUserLocked(&guard, io);
    failed_user_count -= 1;
    try std.testing.expectEqual(@as(u32, 0), failed.header.reference_count);
    try std.testing.expectEqual(@as(u32, 0), failed.header.user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expectError(error.StaleHandle, device.resolveReference(&guard, target));
    try std.testing.expectEqual(@as(u64, 1), log.totalTeardowns());
    try std.testing.expectEqual(@as(u64, 0), log.last_reference_released_count);
}

test "another device rejects live and retired handles" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var first_mutex: std.Io.Mutex = .init;
    var second_mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var first = core.Device.init(gpa, .{
        .object_mutex = &first_mutex,
        .uncaptured_context = &log,
        .uncaptured_callback = recordUncaptured,
    });
    var second = core.Device.init(gpa, .{
        .object_mutex = &second_mutex,
        .uncaptured_context = &log,
        .uncaptured_callback = recordUncaptured,
    });
    var first_guard = core.ObjectGuard.lockUncancelable(io, first.borrow().objectList());
    defer first_guard.unlock(io);
    defer first.deinit(gpa, &first_guard) catch @panic("first alias leaked");
    var second_guard = core.ObjectGuard.lockUncancelable(io, second.borrow().objectList());
    defer second_guard.unlock(io);
    defer second.deinit(gpa, &second_guard) catch @panic("second alias leaked");
    const created = try first.create(gpa, &first_guard, TestObject, .{ .kind = .buffer, .initial_reference = .user });
    created.index = 0;
    created.log = &log;
    created.header.attach(&first_guard, io);
    const target = first.handleFor(&first_guard, TestObject, created, .buffer);
    defer created.header.releaseUserLocked(&first_guard, io) catch @panic("owned alias release failed");
    try std.testing.expectError(error.StaleHandle, second.resolve(&second_guard, TestObject, target));
    try std.testing.expectError(error.StaleHandle, second.resolveReference(&second_guard, target));
    try first.destroy(&first_guard, io, target);
    try std.testing.expectError(error.StaleHandle, second.resolveReference(&second_guard, target));
    try std.testing.expectEqual(@as(usize, 0), second.queryTrackedCount(&second_guard));
    try std.testing.expectEqual(@as(u64, 1), log.early_destroy_count);
}

const DependentObject = struct {
    header: core.Object,
    dependency: *core.Object,
    log: *TeardownLog,

    pub fn destroy(self: *DependentObject, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        self.log.record(reason);
        self.dependency.releaseLeaseLocked(guard, io);
    }
};

test "final deinit refuses an internal lease without retiring payloads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &log,
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("lease leaked");
    const dependency = try device.create(gpa, &guard, TestObject, .{ .kind = .buffer, .initial_reference = .user });
    dependency.index = 0;
    dependency.log = &log;
    dependency.header.attach(&guard, io);
    const owner = try device.create(gpa, &guard, DependentObject, .{ .kind = .texture, .initial_reference = .lease });
    owner.dependency = &dependency.header;
    owner.log = &log;
    try dependency.header.retainLeaseLocked(&guard);
    owner.header.attach(&guard, io);
    var owner_lease_held = true;
    defer if (owner_lease_held) owner.header.releaseLeaseLocked(&guard, io);
    try dependency.header.releaseUserLocked(&guard, io);
    try std.testing.expectError(error.ResourceInUse, device.deinit(gpa, &guard));
    try std.testing.expect(dependency.header.isAlive(&guard));
    try std.testing.expect(owner.header.isAlive(&guard));
    try std.testing.expectEqual(@as(usize, 2), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 0), log.totalTeardowns());
    try std.testing.expectEqual(@as(u32, 1), dependency.header.reference_count);
    try std.testing.expectEqual(@as(u32, 0), dependency.header.user_reference_count);
    try std.testing.expectEqual(@as(u32, 1), owner.header.reference_count);
    try std.testing.expectEqual(@as(u32, 0), owner.header.user_reference_count);
    device.retirePayloadsLocked(&guard, io, .early_destroy);
    try std.testing.expectEqual(@as(u64, 2), log.totalTeardowns());
    try std.testing.expectEqual(@as(usize, 1), device.queryTrackedCount(&guard));
    try std.testing.expect(!owner.header.isAlive(&guard));
    try std.testing.expectEqual(core.ObjectState.destroyed, dependency.header.state);
    try std.testing.expectEqual(core.ObjectState.destroyed, owner.header.state);
    try std.testing.expectEqual(@as(u32, 0), dependency.header.reference_count);
    try std.testing.expect(!dependency.header.node.linked);
    try std.testing.expectEqual(@as(u32, 1), owner.header.reference_count);
    try std.testing.expect(owner.header.node.linked);
    owner.header.releaseLeaseLocked(&guard, io);
    owner_lease_held = false;
    try std.testing.expectEqual(@as(u32, 0), owner.header.reference_count);
    try std.testing.expect(!owner.header.node.linked);
    try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
    try std.testing.expectEqual(@as(u64, 2), log.totalTeardowns());
}

test "owned labels unwind every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createOwnedLabel, .{});
}

fn createOwnedLabel(gpa: std.mem.Allocator) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var log: TeardownLog = .{};
    defer log.deinit(gpa);
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &log,
        .uncaptured_callback = recordUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("failed allocation retained an owner");
    var label: [4096]u8 = @splat('a');
    const created = device.create(gpa, &guard, TestObject, .{
        .kind = .buffer,
        .initial_reference = .user,
        .label = &label,
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), device.queryTrackedCount(&guard));
        try std.testing.expectEqual(@as(u64, 0), log.totalTeardowns());
        return err;
    };
    created.index = 0;
    created.log = &log;
    created.header.attach(&guard, io);
    defer created.header.releaseUserLocked(&guard, io) catch @panic("label alias release failed");
    label[0] = 'b';
    try std.testing.expectEqual(@as(u8, 'a'), created.header.label[0]);
    try std.testing.expectEqual(label.len, created.header.label.len);
}

fn recordUncaptured(
    allocator: std.mem.Allocator,
    _: std.Io,
    context: *anyopaque,
    data: core.ErrorView,
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
