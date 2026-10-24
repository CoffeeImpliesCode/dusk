//! Core owner domains and cross-arena leases; no driver or host lifetime pins.
const std = @import("std");
const dusk = @import("dusk");
const core = dusk.core;
const t = std.testing;
const io = t.io;
const Owner = core.ObjectList.Owner;

const Log = struct {
    destroyed: usize = 0,
};

const Probe = struct {
    header: core.Object,
    log: *Log,
    cross_lease: ?*core.Object,

    pub fn destroy(self: *Probe, guard: *const core.ObjectGuard, callback_io: std.Io, _: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        self.log.destroyed += 1;
        if (self.cross_lease) |target| {
            self.cross_lease = null;
            // The Device guard is already held. Take only the forward Instance guard.
            var target_guard = core.ObjectGuard.lockUncancelable(callback_io, target.tracking);
            defer target_guard.unlock(callback_io);
            target.releaseLeaseLocked(&target_guard, callback_io) catch unreachable;
        }
    }
};

// Initialize only at the final address: the heap arena captures this mutex.
const ArenaFixture = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    arena: *core.ObjectArena,

    fn init(self: *ArenaFixture, allocator: std.mem.Allocator, owner: Owner) !void {
        self.* = .{ .allocator = allocator, .arena = undefined };
        self.arena = try allocator.create(core.ObjectArena);
        self.arena.* = core.ObjectArena.init(allocator, .{ .object_mutex = &self.mutex });
        var guard = self.lock();
        defer guard.unlock(io);
        self.arena.objectList().bindOwnerLocked(&guard, owner);
    }

    fn lock(self: *ArenaFixture) core.ObjectGuard {
        return core.ObjectGuard.lockUncancelable(io, self.arena.objectList());
    }

    fn deinit(self: *ArenaFixture) void {
        var guard = self.lock();
        self.arena.deinit(self.allocator, &guard) catch @panic("owner fixture leaked references");
        guard.unlock(io);
        self.allocator.destroy(self.arena);
    }

    fn create(self: *ArenaFixture, guard: *const core.ObjectGuard, kind: core.Handle.Kind, log: *Log) !*Probe {
        const probe = try self.arena.create(self.allocator, guard, Probe, .{
            .kind = kind,
            .initial_reference = .user,
        });
        probe.log = log;
        probe.cross_lease = null;
        probe.header.attach(guard, io);
        return probe;
    }
};

fn handle(header: *core.Object) core.Handle {
    return .{ .ptr = @ptrCast(header), .kind = header.kind };
}

fn unexpectedError(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("unexpected owner fixture error");
}

fn expectCounts(header: *core.Object, guard: *const core.ObjectGuard, total: u32, users: u32) !void {
    guard.assertOwns(header.tracking);
    try t.expectEqual(total, header.reference_count);
    try t.expectEqual(users, header.user_reference_count);
}

test "owner tags distinguish standalone device and instance even at the same pointer" {
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("instance fixture close failed");
    const pointer: *anyopaque = &instance;
    const owners = [_]Owner{ .standalone, .{ .device = pointer }, .{ .instance = pointer } };
    for (owners, 0..) |owner, index| {
        var fixture: ArenaFixture = undefined;
        try fixture.init(t.allocator, owner);
        defer fixture.deinit();
        var guard = fixture.lock();
        defer guard.unlock(io);
        var log: Log = .{};
        const probe = try fixture.create(&guard, .surface, &log);
        defer probe.header.releaseUserLocked(&guard, io) catch unreachable;
        const list = fixture.arena.objectList();
        const borrow: core.CoreDeviceBorrow = .{ .objects = list };
        try t.expectEqualDeep(owner, list.owner);
        try t.expectEqualDeep(owner, borrow.highOwner());
        try t.expectEqual(&probe.header, try list.resolveHeaderLocked(&guard, handle(&probe.header), owner));
        for (owners, 0..) |other, other_index| {
            if (index == other_index) continue;
            try t.expectError(error.InvalidOwner, list.resolveHeaderLocked(&guard, handle(&probe.header), other));
        }
    }
}

test "core Device binding selects the device owner domain" {
    var mutex: std.Io.Mutex = .init;
    var device: core.Device = undefined;
    device = core.Device.init(t.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &device,
        .uncaptured_callback = unexpectedError,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer guard.unlock(io);
    defer device.deinit(t.allocator, &guard) catch @panic("core device fixture close failed");
    try t.expectEqualDeep(@as(Owner, .standalone), device.borrow().highOwner());
    device.bindTrackingOwner(&guard, &device);
    device.bindTrackingOwner(&guard, &device);
    try t.expectEqualDeep(Owner{ .device = &device }, device.borrow().highOwner());
}

test "resolver checks original list owner kind and live payload" {
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("instance fixture close failed");
    var other_instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer other_instance.deinit(t.allocator, io) catch @panic("other instance fixture close failed");
    const owner: Owner = .{ .instance = &instance };
    var fixture: ArenaFixture = undefined;
    try fixture.init(t.allocator, owner);
    defer fixture.deinit();
    var foreign: ArenaFixture = undefined;
    try foreign.init(t.allocator, owner);
    defer foreign.deinit();
    var guard = fixture.lock();
    defer guard.unlock(io);
    var log: Log = .{};
    const surface = try fixture.create(&guard, .surface, &log);
    defer surface.header.releaseUserLocked(&guard, io) catch unreachable;
    const native = try fixture.create(&guard, .native_surface, &log);
    defer native.header.releaseUserLocked(&guard, io) catch unreachable;
    const list = fixture.arena.objectList();
    try t.expectEqual(&surface.header, try list.resolveHeaderLocked(&guard, handle(&surface.header), owner));
    try t.expectEqual(&native.header, try list.resolveHeaderLocked(&guard, handle(&native.header), owner));
    var wrong_kind = handle(&surface.header);
    wrong_kind.kind = .native_surface;
    try t.expectError(error.HandleKindMismatch, list.resolveHeaderLocked(&guard, wrong_kind, owner));
    wrong_kind = handle(&native.header);
    wrong_kind.kind = .surface;
    try t.expectError(error.HandleKindMismatch, list.resolveHeaderLocked(&guard, wrong_kind, owner));
    try t.expectError(error.InvalidOwner, list.resolveHeaderLocked(&guard, handle(&surface.header), .{ .instance = &other_instance }));
    {
        var foreign_guard = foreign.lock();
        defer foreign_guard.unlock(io);
        try t.expectError(error.StaleHandle, foreign.arena.objectList().resolveHeaderLocked(&foreign_guard, handle(&surface.header), owner));
    }
    surface.header.retirePayloadLocked(&guard, io, .early_destroy);
    try t.expectEqual(@as(usize, 1), log.destroyed);
    try t.expectError(error.StaleHandle, list.resolveHeaderLocked(&guard, handle(&surface.header), owner));
    try expectCounts(&surface.header, &guard, 1, 1);
}

test "an Instance arena lease survives the final user alias" {
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("instance fixture close failed");
    const owner: Owner = .{ .instance = &instance };
    var fixture: ArenaFixture = undefined;
    try fixture.init(t.allocator, owner);
    defer fixture.deinit();
    var guard = fixture.lock();
    defer guard.unlock(io);
    var log: Log = .{};
    const probe = try fixture.create(&guard, .surface, &log);
    try probe.header.retainLeaseLocked(&guard);
    var lease_held = true;
    defer if (lease_held) probe.header.releaseLeaseLocked(&guard, io);
    try probe.header.releaseUserLocked(&guard, io);
    try expectCounts(&probe.header, &guard, 1, 0);
    try t.expectEqual(@as(usize, 0), log.destroyed);
    try t.expectEqual(&probe.header, try fixture.arena.objectList().resolveHeaderLocked(&guard, handle(&probe.header), owner));
    try t.expectError(error.ResourceInUse, fixture.arena.objectList().preflightDeinitLocked(&guard));
    probe.header.releaseLeaseLocked(&guard, io);
    lease_held = false;
    try expectCounts(&probe.header, &guard, 0, 0);
    try t.expectEqual(@as(usize, 1), log.destroyed);
    try t.expectError(error.StaleHandle, fixture.arena.objectList().resolveHeaderLocked(&guard, handle(&probe.header), owner));
    try fixture.arena.objectList().preflightDeinitLocked(&guard);
}

test "retiring rejects every retain and resolution then restores the same ledger" {
    var fixture: ArenaFixture = undefined;
    try fixture.init(t.allocator, .standalone);
    defer fixture.deinit();
    var guard = fixture.lock();
    defer guard.unlock(io);
    var log: Log = .{};
    const probe = try fixture.create(&guard, .surface, &log);
    defer probe.header.releaseUserLocked(&guard, io) catch unreachable;
    try probe.header.retainLeaseLocked(&guard);
    defer probe.header.releaseLeaseLocked(&guard, io);
    const list = fixture.arena.objectList();
    const before_total = list.total_reference_count;
    const before_users = list.user_reference_count;
    try probe.header.beginRetiringLocked(&guard);
    try t.expectEqual(core.ObjectState.retiring, probe.header.state);
    try t.expect(!probe.header.isAlive(&guard));
    try t.expectError(error.ResourceDestroyed, probe.header.beginRetiringLocked(&guard));
    try t.expectError(error.ResourceDestroyed, probe.header.retainUserLocked(&guard));
    try t.expectError(error.ResourceDestroyed, probe.header.acquireUserLocked(&guard));
    try t.expectError(error.ResourceDestroyed, probe.header.retainLeaseLocked(&guard));
    try t.expectError(error.StaleHandle, list.resolveHeaderLocked(&guard, handle(&probe.header), .standalone));
    try expectCounts(&probe.header, &guard, 2, 1);
    try t.expectEqual(before_total, list.total_reference_count);
    try t.expectEqual(before_users, list.user_reference_count);
    try t.expectEqual(@as(usize, 0), log.destroyed);
    probe.header.restoreAliveLocked(&guard);
    try t.expectEqual(core.ObjectState.alive, probe.header.state);
    try expectCounts(&probe.header, &guard, 2, 1);
    try t.expectEqual(before_total, list.total_reference_count);
    try t.expectEqual(before_users, list.user_reference_count);
    try t.expectEqual(&probe.header, try list.resolveHeaderLocked(&guard, handle(&probe.header), .standalone));
    try probe.header.retainUserLocked(&guard);
    try probe.header.releaseUserLocked(&guard, io);
    try expectCounts(&probe.header, &guard, 2, 1);
}

test "Device destructor releases its exact NativeSurface lease under forward Instance lock" {
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(t.allocator, io) catch @panic("instance fixture close failed");
    var target: ArenaFixture = undefined;
    try target.init(t.allocator, .{ .instance = &instance });
    defer target.deinit();
    var mutex: std.Io.Mutex = .init;
    var device: core.Device = undefined;
    device = core.Device.init(t.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &device,
        .uncaptured_callback = unexpectedError,
    });
    var source_guard = core.ObjectGuard.lockUncancelable(io, device.borrow().objectList());
    defer source_guard.unlock(io);
    defer device.deinit(t.allocator, &source_guard) catch @panic("device fixture retained references");
    device.bindTrackingOwner(&source_guard, &device);
    var source_log: Log = .{};
    var target_log: Log = .{};
    const source = try device.create(t.allocator, &source_guard, Probe, .{ .kind = .swapchain, .initial_reference = .user });
    source.log = &source_log;
    source.cross_lease = null;
    var source_user_held = true;
    defer if (source_user_held) source.header.releaseUserLocked(&source_guard, io) catch unreachable;
    source.header.attach(&source_guard, io);
    const native = blk: {
        var target_guard = target.lock();
        defer target_guard.unlock(io);
        const native = try target.create(&target_guard, .native_surface, &target_log);
        try native.header.retainLeaseLocked(&target_guard);
        source.cross_lease = &native.header;
        try native.header.releaseUserLocked(&target_guard, io);
        break :blk native;
    };
    try t.expectError(error.ResourceInUse, device.borrow().objects.preflightDeinitLocked(&source_guard));
    {
        var target_guard = target.lock();
        defer target_guard.unlock(io);
        try expectCounts(&native.header, &target_guard, 1, 0);
        try t.expect(native.header.isAlive(&target_guard));
        try t.expectEqual(@as(usize, 0), target_log.destroyed);
        try t.expectError(error.ResourceInUse, target.arena.objectList().preflightDeinitLocked(&target_guard));
    }
    try source.header.releaseUserLocked(&source_guard, io);
    source_user_held = false;
    // Both ledgers are empty before the source guard is released.
    try expectCounts(&source.header, &source_guard, 0, 0);
    try t.expect(!source.header.node.linked);
    try t.expectEqual(@as(usize, 0), device.arena.queryTrackedCount(&source_guard));
    try t.expectEqual(@as(u64, 0), device.borrow().objects.total_reference_count);
    try device.borrow().objects.preflightDeinitLocked(&source_guard);
    try t.expectEqual(@as(usize, 1), source_log.destroyed);
    source.header.retirePayloadLocked(&source_guard, io, .early_destroy);
    try t.expectEqual(@as(usize, 1), source_log.destroyed);
    {
        var target_guard = target.lock();
        defer target_guard.unlock(io);
        try expectCounts(&native.header, &target_guard, 0, 0);
        try t.expect(!native.header.node.linked);
        try t.expectEqual(@as(usize, 1), target_log.destroyed);
        try target.arena.objectList().preflightDeinitLocked(&target_guard);
    }
}

fn firstHeapArenaAllocation(allocator: std.mem.Allocator) !void {
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("failure fixture instance close failed");
    var fixture: ArenaFixture = undefined;
    try fixture.init(allocator, .{ .instance = &instance });
    defer fixture.deinit();
    var guard = fixture.lock();
    defer guard.unlock(io);
    var log: Log = .{};
    const label: [8192]u8 = @splat('x');
    const probe = fixture.arena.create(allocator, &guard, Probe, .{
        .kind = .native_surface,
        .initial_reference = .user,
        .label = &label,
    }) catch |err| {
        try t.expectEqual(@as(u64, 0), fixture.arena.objectList().total_reference_count);
        try t.expectEqual(@as(u64, 0), fixture.arena.objectList().user_reference_count);
        try t.expectEqual(@as(usize, 0), fixture.arena.queryTrackedCount(&guard));
        try t.expectEqual(@as(usize, 0), log.destroyed);
        try fixture.arena.objectList().preflightDeinitLocked(&guard);
        return err;
    };
    probe.log = &log;
    probe.cross_lease = null;
    probe.header.attach(&guard, io);
    try t.expectEqualStrings(&label, probe.header.label);
    try probe.header.releaseUserLocked(&guard, io);
    try t.expectEqual(@as(usize, 1), log.destroyed);
    try fixture.arena.objectList().preflightDeinitLocked(&guard);
}

test "fail-N first genuine heap arena construction leaves no published reference" {
    try t.checkAllAllocationFailures(t.allocator, firstHeapArenaAllocation, .{});
}
