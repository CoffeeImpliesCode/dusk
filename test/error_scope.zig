//! Exercises owned routing with deterministic acceptance and settlement order.
//! The original object mutex guards scope mutations; callbacks run after unlock.

const std = @import("std");
const core = @import("dusk").core;
const gpa = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    device: core.Device,
    uncaptured_count: u32 = 0,
    uncaptured_code: ?core.ErrorCode = null,
    message: [128]u8 = undefined,
    message_len: usize = 0,
    notify_count: u32 = 0,
    reenter: bool = false,
    delivery_refused_deinit: bool = false,
    callback_view_survived: bool = false,

    fn init(self: *Fixture, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator, .device = undefined };
        self.device = core.Device.init(allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = recordUncaptured,
        });
    }

    fn lock(self: *Fixture) core.ObjectGuard {
        return core.ObjectGuard.lockUncancelable(io, self.device.borrow().objects);
    }

    fn deinit(self: *Fixture, guard: *const core.ObjectGuard) void {
        self.device.deinit(self.allocator, guard) catch @panic("scope fixture retained ownership");
    }

    fn dispatch(self: *Fixture, guard: *core.ObjectGuard, settlement: *core.ScopeSettlement) void {
        guard.unlock(io);
        settlement.dispatch(io);
        guard.* = self.lock();
    }
};

test "owned scope error survives the worker draft and keeps the operation reference" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .{ .validation = true });
    try std.testing.expectEqual(@as(u32, 1), lease.errorQuota());
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    try std.testing.expect(!ticket.isReady(&guard));
    try std.testing.expectError(error.ScopePending, ticket.take(&guard));
    try std.testing.expectError(error.WaitIterationExhausted, ticket.wait(io, &guard, 0));

    const operation_ref = try publishWorkerError(gpa, lease.errorQuota());
    defer operation_ref.release();
    var settlement = try lease.settle(&guard, operation_ref);
    fixture.dispatch(&guard, &settlement);
    try ticket.wait(io, &guard, 1);
    var result = try ticket.take(&guard);
    defer result.deinit();
    const scope_ref = result.error_ref orelse return error.ScopeCapturedNothing;
    try std.testing.expect(scope_ref.node == operation_ref.node);
    try std.testing.expectEqualStrings("worker-owned detail", scope_ref.view().message);
    try std.testing.expectEqualStrings("worker context", scope_ref.view().context[0].text);
    try std.testing.expectEqual(core.ErrorCode{ .validation = error.EncoderAlreadyFinished }, scope_ref.view().code);
    try std.testing.expectError(error.ScopeTicketConsumed, ticket.take(&guard));
    try std.testing.expectError(error.ScopeTicketConsumed, ticket.wait(io, &guard, 0));
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
}

test "owned scope empty pop returns the concrete stack error" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try std.testing.expectError(error.ErrorScopeStackEmpty, fixture.device.popErrorScope(&guard));
}

test "popped scope remains stable while the open stack repeatedly relocates" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var original = try fixture.device.popErrorScope(&guard);
    defer original.deinit(&guard);
    for (0..128) |_| try fixture.device.pushErrorScope(gpa, &guard, .validation);
    try std.testing.expect(!original.isReady(&guard));
    const operation_ref = try publishWorkerError(gpa, lease.errorQuota());
    defer operation_ref.release();
    var settlement = try lease.settle(&guard, operation_ref);
    fixture.dispatch(&guard, &settlement);
    var result = try original.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref.?.node == operation_ref.node);
    for (0..128) |_| {
        var later = try fixture.device.popErrorScope(&guard);
        defer later.deinit(&guard);
        var empty = try later.take(&guard);
        defer empty.deinit();
        try std.testing.expect(empty.error_ref == null);
    }
}

test "nearest filtered capture keeps every outer scope pending" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    try fixture.device.pushErrorScope(gpa, &guard, .internal);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .{ .validation = true });
    var inner = try fixture.device.popErrorScope(&guard);
    defer inner.deinit(&guard);
    var middle = try fixture.device.popErrorScope(&guard);
    defer middle.deinit(&guard);
    var outer = try fixture.device.popErrorScope(&guard);
    defer outer.deinit(&guard);
    try std.testing.expect(!inner.isReady(&guard));
    try std.testing.expect(!middle.isReady(&guard));
    try std.testing.expect(!outer.isReady(&guard));
    const operation_ref = try publishWorkerError(gpa, lease.errorQuota());
    defer operation_ref.release();
    var settlement = try lease.settle(&guard, operation_ref);
    fixture.dispatch(&guard, &settlement);
    var inner_result = try inner.take(&guard);
    defer inner_result.deinit();
    var middle_result = try middle.take(&guard);
    defer middle_result.deinit();
    var outer_result = try outer.take(&guard);
    defer outer_result.deinit();
    try std.testing.expect(inner_result.error_ref.?.node == operation_ref.node);
    try std.testing.expect(middle_result.error_ref == null);
    try std.testing.expect(outer_result.error_ref == null);
}

test "capture mask excludes otherwise matching scopes but retains their blockers" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .internal);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .{ .validation = true });
    try std.testing.expectEqual(@as(u32, 1), lease.errorQuota());
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    try std.testing.expect(!ticket.isReady(&guard));
    // The prepaid routing owner remains distinct from the operation-result owner.
    const operation_ref = try makeError(gpa, .{ .device_lost = error.DeviceLost }, "excluded internal error", lease.errorQuota());
    defer operation_ref.release();
    var settlement = try lease.settle(&guard, operation_ref);
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
    fixture.dispatch(&guard, &settlement);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
    try std.testing.expectEqual(@as(u32, 1), fixture.uncaptured_count);
    try std.testing.expectEqualStrings("excluded internal error", fixture.message[0..fixture.message_len]);
    try std.testing.expectEqualStrings("excluded internal error", operation_ref.view().message);
}

test "two accepted tasks keep the first error and reject duplicate settlement" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var first = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var second = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    const first_ref = try makeError(gpa, .{ .validation = error.BufferSizeTooSmall }, "first accepted error", first.errorQuota());
    defer first_ref.release();
    const second_ref = try publishWorkerError(gpa, second.errorQuota());
    defer second_ref.release();
    var first_settlement = try first.settle(&guard, first_ref);
    fixture.dispatch(&guard, &first_settlement);
    try std.testing.expect(!ticket.isReady(&guard));
    try std.testing.expectError(error.ScopeLeaseAlreadySettled, first.settle(&guard, null));
    var second_settlement = try second.settle(&guard, second_ref);
    fixture.dispatch(&guard, &second_settlement);
    try std.testing.expectError(error.ScopeLeaseAlreadySettled, second.settle(&guard, null));
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref.?.node == first_ref.node);
    try std.testing.expectEqualStrings("first accepted error", result.error_ref.?.view().message);
    try std.testing.expectEqualStrings("worker-owned detail", second_ref.view().message);
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
}

test "uncaptured delivery owns the view through callback reentry and return" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    fixture.reenter = true;
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    const reference = try publishWorkerError(gpa, 0);
    var delivery = fixture.device.handleError(&guard, reference) orelse
        return error.UncapturedDeliveryMissing;
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(gpa, &guard));
    guard.unlock(io);
    delivery.dispatch(io);
    guard = fixture.lock();
    try std.testing.expectEqual(@as(u32, 1), fixture.uncaptured_count);
    try std.testing.expect(fixture.delivery_refused_deinit);
    try std.testing.expect(fixture.callback_view_survived);
    try std.testing.expectEqualStrings("worker-owned detail", fixture.message[0..fixture.message_len]);
}

test "deinit refuses live lease ticket and binding without changing their state" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(gpa, &guard));
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    try std.testing.expect(!ticket.isReady(&guard));
    var settlement = lease.deinit(&guard);
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(gpa, &guard));
    fixture.dispatch(&guard, &settlement);
    try std.testing.expect(ticket.isReady(&guard));
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(gpa, &guard));
    var binding = try ticket.bind(gpa, &guard, &fixture, recordReady);
    defer binding.deinit(&guard);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(gpa, &guard));
    guard.unlock(io);
    binding.notifyReady(io);
    guard = fixture.lock();
    try std.testing.expectEqual(@as(u32, 1), fixture.notify_count);
}

test "accepted settlement notifies ready binding only after unlock" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    var binding = try ticket.bind(gpa, &guard, &fixture, recordReady);
    defer binding.deinit(&guard);
    var reservation = try core.ErrorReservation.prepare(gpa);
    defer reservation.discard();
    try reservation.reserveReferences(lease.errorQuota());
    var settlement = try lease.settle(&guard, null);
    try std.testing.expectEqual(@as(u32, 0), fixture.notify_count);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 1), fixture.notify_count);
    try ticket.wait(io, &guard, 0);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
}

test "canceling a binding before queued notification suppresses its callback" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    var binding = try ticket.bind(gpa, &guard, &fixture, recordReady);
    var settlement = try lease.settle(&guard, null);
    binding.deinit(&guard);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 0), fixture.notify_count);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
}

test "abandoned ticket remains pinned by accepted task until settlement" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var ticket = try fixture.device.popErrorScope(&guard);
    ticket.deinit(&guard);
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(gpa, &guard));
    const operation_ref = try publishWorkerError(gpa, lease.errorQuota());
    defer operation_ref.release();
    var settlement = try lease.settle(&guard, operation_ref);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqualStrings("worker-owned detail", operation_ref.view().message);
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
}

test "accepted task without scopes prepays uncaptured routing without terminal allocation" {
    var allocations = std.testing.FailingAllocator.init(gpa, .{});
    const allocator = allocations.allocator();
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    var lease = try fixture.device.captureScopeLeaseSet(allocator, &guard, .{});
    try std.testing.expectEqual(@as(u32, 1), lease.errorQuota());
    try std.testing.expectError(error.ResourceInUse, fixture.device.deinit(allocator, &guard));
    const operation_ref = try publishWorkerError(allocator, lease.errorQuota());
    defer operation_ref.release();
    // Scopes pushed after acceptance cannot capture the accepted task's error.
    try fixture.device.pushErrorScope(allocator, &guard, .validation);
    allocations.fail_index = allocations.alloc_index;
    allocations.resize_fail_index = allocations.resize_index;
    var settlement = try lease.settle(&guard, operation_ref);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 1), fixture.uncaptured_count);
    try std.testing.expectEqualStrings("worker-owned detail", operation_ref.view().message);
    try std.testing.expectEqualStrings("worker-owned detail", fixture.message[0..fixture.message_len]);
    try std.testing.expect(!allocations.has_induced_failure);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
}

test "owned immediate routing captures through the sink and frees duplicate errors" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    const sink = fixture.device.errorSink(&guard);
    const first = try publishWorkerError(gpa, 0);
    try std.testing.expect(sink.consumeError(&guard, first) == null);
    const second = try makeError(gpa, .{ .validation = error.BufferSizeTooSmall }, "duplicate immediate error", 0);
    try std.testing.expect(fixture.device.handleError(&guard, second) == null);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref.?.node == first.node);
    try std.testing.expectEqualStrings("worker-owned detail", result.error_ref.?.view().message);
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
}

test "scope overflow preflight leaves every earlier record unchanged" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    for (0..3) |_| try fixture.device.pushErrorScope(gpa, &guard, .validation);
    const stack = &fixture.device.error_scopes;
    for (0..3) |index| {
        const record = stack.scopes.items[index];
        {
            record.references = std.math.maxInt(u64);
            defer record.references = 1;
            try std.testing.expectError(error.ScopeReferenceCountOverflow, fixture.device.captureScopeLeaseSet(gpa, &guard, .all));
            for (stack.scopes.items, 0..) |unchanged, other_index| {
                const expected: u64 = if (other_index == index) std.math.maxInt(u64) else 1;
                try std.testing.expectEqual(expected, unchanged.references);
                try std.testing.expectEqual(@as(u64, 0), unchanged.pending);
            }
            try std.testing.expectEqual(@as(u64, 0), stack.lease_sets);
        }
        {
            record.pending = std.math.maxInt(u64);
            defer record.pending = 0;
            try std.testing.expectError(error.ScopeReferenceCountOverflow, fixture.device.captureScopeLeaseSet(gpa, &guard, .all));
            for (stack.scopes.items, 0..) |unchanged, other_index| {
                const expected: u64 = if (other_index == index) std.math.maxInt(u64) else 0;
                try std.testing.expectEqual(@as(u64, 1), unchanged.references);
                try std.testing.expectEqual(expected, unchanged.pending);
            }
            try std.testing.expectEqual(@as(u64, 0), stack.lease_sets);
        }
    }
    {
        stack.lease_sets = std.math.maxInt(u64);
        defer stack.lease_sets = 0;
        try std.testing.expectError(error.ScopeReferenceCountOverflow, fixture.device.captureScopeLeaseSet(gpa, &guard, .all));
        try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), stack.lease_sets);
        for (stack.scopes.items) |record| {
            try std.testing.expectEqual(@as(u64, 1), record.references);
            try std.testing.expectEqual(@as(u64, 0), record.pending);
        }
    }
    {
        stack.live_records = std.math.maxInt(u64);
        defer stack.live_records = 3;
        try std.testing.expectError(error.ScopeReferenceCountOverflow, fixture.device.pushErrorScope(gpa, &guard, .internal));
        try std.testing.expectEqual(@as(usize, 3), stack.scopes.items.len);
    }
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    {
        const record = ticket.record.?;
        record.references = std.math.maxInt(u64);
        defer record.references = 1;
        try std.testing.expectError(error.ScopeReferenceCountOverflow, ticket.bind(gpa, &guard, &fixture, recordReady));
        try std.testing.expect(record.binding == null);
    }
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
    try drainReadyScopes(&fixture, &guard, 2);
}

test "allocator mismatch and duplicate binding refuse before allocation or mutation" {
    var source = std.testing.FailingAllocator.init(gpa, .{});
    var foreign = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const allocator = source.allocator();
    const wrong_allocator = foreign.allocator();
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(allocator, &guard, .validation);
    try std.testing.expectError(error.AllocatorMismatch, fixture.device.pushErrorScope(wrong_allocator, &guard, .internal));
    try std.testing.expectError(error.AllocatorMismatch, fixture.device.captureScopeLeaseSet(wrong_allocator, &guard, .all));
    try std.testing.expectEqual(@as(usize, 1), fixture.device.error_scopes.scopes.items.len);
    try std.testing.expectEqual(@as(u64, 0), fixture.device.error_scopes.lease_sets);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    try std.testing.expectError(error.AllocatorMismatch, ticket.bind(wrong_allocator, &guard, &fixture, recordReady));
    try std.testing.expectEqual(@as(u64, 1), ticket.record.?.references);
    try std.testing.expect(ticket.record.?.binding == null);
    try std.testing.expect(!foreign.has_induced_failure);
    var binding = try ticket.bind(allocator, &guard, &fixture, recordReady);
    defer binding.deinit(&guard);
    const bound_node = ticket.record.?.binding;
    source.fail_index = source.alloc_index;
    source.resize_fail_index = source.resize_index;
    try std.testing.expectError(error.ScopeBindingExists, ticket.bind(allocator, &guard, &fixture, recordReady));
    try std.testing.expect(!source.has_induced_failure);
    try std.testing.expect(ticket.record.?.binding == bound_node);
    try std.testing.expectEqual(@as(u64, 2), ticket.record.?.references);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
}

test "active ready callback cancels its binding and consumes ticket while pin remains" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    var binding: core.ScopeBinding = undefined;
    var callback: SelfCancelReady = .{
        .fixture = &fixture,
        .ticket = &ticket,
        .binding = &binding,
    };
    binding = try ticket.bind(gpa, &guard, &callback, SelfCancelReady.notify);
    defer binding.deinit(&guard);
    var settlement = try lease.settle(&guard, null);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 1), callback.calls);
    try std.testing.expect(callback.pin_refused_deinit);
    try std.testing.expect(binding.node == null);
    try std.testing.expectError(error.ScopeTicketConsumed, ticket.take(&guard));
    try std.testing.expectEqual(@as(u64, 0), fixture.device.error_scopes.live_records);
}

test "real concurrent accepted tasks settle first error under the original guard" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var first_lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    defer if (first_lease.entries != null) {
        var settlement = first_lease.deinit(&guard);
        fixture.dispatch(&guard, &settlement);
    };
    var second_lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    defer if (second_lease.entries != null) {
        var settlement = second_lease.deinit(&guard);
        fixture.dispatch(&guard, &settlement);
    };
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    const first_ref = try makeError(gpa, .{ .validation = error.BufferSizeTooSmall }, "concurrent first error", first_lease.errorQuota());
    var first_owned = true;
    defer if (first_owned) first_ref.releaseMany(2);
    const second_ref = try publishWorkerError(gpa, second_lease.errorQuota());
    var second_owned = true;
    defer if (second_owned) second_ref.releaseMany(2);
    var gate: ConcurrentGate = .{};
    var first: ConcurrentTask = .{
        .fixture = &fixture,
        .gate = &gate,
        .lease = &first_lease,
        .reference = first_ref,
        .first = true,
    };
    var second: ConcurrentTask = .{
        .fixture = &fixture,
        .gate = &gate,
        .lease = &second_lease,
        .reference = second_ref,
        .first = false,
    };
    guard.unlock(io);
    {
        defer guard = fixture.lock();
        const first_thread = try std.Thread.spawn(.{}, ConcurrentTask.run, .{&first});
        first_owned = false;
        const second_thread = std.Thread.spawn(.{}, ConcurrentTask.run, .{&second}) catch |err| {
            gate.mutex.lockUncancelable(io);
            gate.start = true;
            gate.condition.broadcast(io);
            gate.mutex.unlock(io);
            first_thread.join();
            return err;
        };
        second_owned = false;
        gate.mutex.lockUncancelable(io);
        for (0..64) |_| {
            if (gate.arrived == 2) break;
            gate.condition.wait(io, &gate.mutex) catch @panic("thread arrival canceled");
        }
        std.debug.assert(gate.arrived == 2);
        gate.start = true;
        gate.condition.broadcast(io);
        gate.mutex.unlock(io);
        first_thread.join();
        second_thread.join();
    }
    try std.testing.expect(first.duplicate_rejected);
    try std.testing.expect(second.duplicate_rejected);
    try ticket.wait(io, &guard, 0);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref.?.node == first_ref.node);
    try std.testing.expectEqualStrings("concurrent first error", result.error_ref.?.view().message);
    try std.testing.expectEqual(@as(u32, 0), fixture.uncaptured_count);
}

test "fail N allocations preserve scope records and stack growth transactionally" {
    try std.testing.checkAllAllocationFailures(gpa, failScopeRecords, .{});
}

test "fail N allocations preserve lease arrays and pending blockers transactionally" {
    try std.testing.checkAllAllocationFailures(gpa, failLeaseArrays, .{});
}

test "fail N allocations preserve ticket bindings transactionally" {
    try std.testing.checkAllAllocationFailures(gpa, failBindings, .{});
}

test "reference quota refusal aborts admission without stranding scope blockers" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    var reservation = try core.ErrorReservation.prepare(gpa);
    defer reservation.discard();
    try reservation.reserveReferences(std.math.maxInt(u32) - 1);
    try std.testing.expectError(error.ErrorReferenceCountOverflow, reservation.reserveReferences(lease.errorQuota()));
    var settlement = lease.deinit(&guard);
    fixture.dispatch(&guard, &settlement);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    try std.testing.expect(ticket.isReady(&guard));
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
}

test "all capture classes route to their nearest filter on the same immutable node" {
    const cases = [_]struct { filter: core.ErrorFilter, code: core.ErrorCode }{
        .{ .filter = .validation, .code = .{ .validation = error.EncoderAlreadyFinished } },
        .{ .filter = .out_of_memory, .code = .{ .unrecoverable = error.OutOfHostMemory } },
        .{ .filter = .internal, .code = .{ .device_lost = error.DeviceLost } },
    };
    for (cases) |case| {
        var fixture: Fixture = undefined;
        fixture.init(gpa);
        var guard = fixture.lock();
        defer guard.unlock(io);
        defer fixture.deinit(&guard);
        try fixture.device.pushErrorScope(gpa, &guard, case.filter);
        try fixture.device.pushErrorScope(gpa, &guard, case.filter);
        var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
        var inner = try fixture.device.popErrorScope(&guard);
        defer inner.deinit(&guard);
        var outer = try fixture.device.popErrorScope(&guard);
        defer outer.deinit(&guard);
        const operation_ref = try makeError(gpa, case.code, "class detail", lease.errorQuota());
        defer operation_ref.release();
        var settlement = try lease.settle(&guard, operation_ref);
        fixture.dispatch(&guard, &settlement);
        var inner_result = try inner.take(&guard);
        defer inner_result.deinit();
        var outer_result = try outer.take(&guard);
        defer outer_result.deinit();
        try std.testing.expect(inner_result.error_ref.?.node == operation_ref.node);
        try std.testing.expectEqual(case.code, inner_result.error_ref.?.view().code);
        try std.testing.expect(outer_result.error_ref == null);
    }
}

test "every code matches exactly the filters WebGPU gives it" {
    inline for (@typeInfo(core.ValidationError).error_set.error_names.?) |entry| {
        const code: core.ErrorCode = .{ .validation = @field(core.ValidationError, entry) };
        try expectFilter(code, .validation, true);
        try expectFilter(code, .out_of_memory, false);
        try expectFilter(code, .internal, false);
    }
    inline for (@typeInfo(core.DeviceLostError).error_set.error_names.?) |entry| {
        const code: core.ErrorCode = .{ .device_lost = @field(core.DeviceLostError, entry) };
        try expectFilter(code, .validation, false);
        try expectFilter(code, .out_of_memory, false);
        try expectFilter(code, .internal, true);
    }
    inline for (@typeInfo(core.UnrecoverableError).error_set.error_names.?) |entry| {
        const member = @field(core.UnrecoverableError, entry);
        const code: core.ErrorCode = .{ .unrecoverable = member };
        const is_memory = member == error.OutOfDeviceMemory or member == error.OutOfHostMemory;
        try expectFilter(code, .validation, false);
        try expectFilter(code, .out_of_memory, is_memory);
        try expectFilter(code, .internal, !is_memory);
    }
}

test "prepared binding OOM leaves the captured open scope available to its consumer" {
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    const allocator = failing.allocator();
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(allocator, &guard, .validation);
    const diagnostic = try makeError(allocator, .{ .validation = error.BufferSizeTooSmall }, "kept before admission", 0);
    try std.testing.expect(fixture.device.handleError(&guard, diagnostic) == null);
    const record = fixture.device.error_scopes.scopes.items[0];
    var probe: OwnedBindingProbe = .{ .fixture = &fixture };
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    guard.unlock(io);
    const prepared = core.prepareBinding(allocator, probe.options());
    guard = fixture.lock();
    try std.testing.expectError(error.OutOfMemory, prepared);
    try std.testing.expectEqual(@as(u32, 0), probe.release_count);
    try std.testing.expect(fixture.device.error_scopes.scopes.items[0] == record);
    try std.testing.expectEqual(@as(u64, 1), record.references);
    var ticket = try fixture.device.popErrorScope(&guard);
    defer ticket.deinit(&guard);
    var result = try ticket.take(&guard);
    defer result.deinit();
    try std.testing.expectEqualStrings("kept before admission", result.error_ref.?.view().message);
}

test "prepared pop preflights references and ticket capacity without consuming either owner" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var probe: OwnedBindingProbe = .{ .fixture = &fixture };
    var prepared = try core.prepareBinding(gpa, probe.options());
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    const stack = &fixture.device.error_scopes;
    const record = stack.scopes.items[0];
    const node = prepared.node;
    const capacity = stack.scopes.capacity;
    {
        record.references = std.math.maxInt(u64);
        defer record.references = 1;
        try std.testing.expectError(error.ScopeReferenceCountOverflow, fixture.device.popBoundErrorScope(&guard, &prepared));
        try std.testing.expectEqual(std.math.maxInt(u64), record.references);
        try std.testing.expectEqual(@as(u64, 0), stack.tickets);
    }
    {
        stack.tickets = std.math.maxInt(u64);
        defer stack.tickets = 0;
        try std.testing.expectError(error.ScopeReferenceCountOverflow, fixture.device.popBoundErrorScope(&guard, &prepared));
        try std.testing.expectEqual(@as(u64, 1), record.references);
        try std.testing.expectEqual(std.math.maxInt(u64), stack.tickets);
    }
    try std.testing.expect(prepared.node == node);
    try std.testing.expect(record.binding == null);
    try std.testing.expectEqual(@as(usize, 1), stack.scopes.items.len);
    try std.testing.expectEqual(capacity, stack.scopes.capacity);
    try std.testing.expectEqual(@as(u32, 0), probe.release_count);
    var popped = try fixture.device.popBoundErrorScope(&guard, &prepared);
    try std.testing.expect(prepared.node == null);
    popped.ticket.deinit(&guard);
    var cleanup = popped.binding.deinit(&guard);
    try std.testing.expectEqual(@as(u32, 0), probe.release_count);
    dispatchBindingRelease(&fixture, &guard, &cleanup);
    try std.testing.expectEqual(@as(u32, 1), probe.release_count);
}

test "prepared binding allocator mismatch preserves ownership and destroys its node exactly once" {
    var source = std.testing.FailingAllocator.init(gpa, .{});
    var foreign = std.testing.FailingAllocator.init(gpa, .{});
    const allocator = source.allocator();
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var probe: OwnedBindingProbe = .{ .fixture = &fixture, .allocation_owner = &foreign };
    var prepared = try core.prepareBinding(foreign.allocator(), probe.options());
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    try fixture.device.pushErrorScope(allocator, &guard, .internal);
    const record = fixture.device.error_scopes.scopes.items[0];
    const node = prepared.node;
    const allocations = source.alloc_index;
    try std.testing.expectError(error.AllocatorMismatch, fixture.device.popBoundErrorScope(&guard, &prepared));
    try std.testing.expect(prepared.node == node);
    try std.testing.expect(fixture.device.error_scopes.scopes.items[0] == record);
    try std.testing.expectEqual(@as(u64, 1), record.references);
    try std.testing.expectEqual(allocations, source.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), foreign.deallocations);
    abortPrepared(&fixture, &guard, &prepared);
    abortPrepared(&fixture, &guard, &prepared);
    try std.testing.expectEqual(@as(u32, 1), probe.release_count);
    try std.testing.expect(probe.node_freed_before_release);
    try std.testing.expectEqual(foreign.allocations, foreign.deallocations);
    try std.testing.expectEqual(foreign.allocated_bytes, foreign.freed_bytes);
}

test "accepted empty prepared pop keeps its reservation until explicit outside lock abort" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var probe: OwnedBindingProbe = .{ .fixture = &fixture };
    var prepared = try core.prepareBinding(gpa, probe.options());
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    const node = prepared.node;
    try std.testing.expectError(error.ErrorScopeStackEmpty, fixture.device.popBoundErrorScope(&guard, &prepared));
    try std.testing.expect(prepared.node == node);
    try std.testing.expectEqual(@as(u32, 0), probe.release_count);
    abortPrepared(&fixture, &guard, &prepared);
    try std.testing.expectEqual(@as(u32, 1), probe.release_count);
    try std.testing.expectEqual(@as(u32, 0), probe.notify_count);
}

test "preparation does not select a scope across a real concurrent push and capture" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var probe: OwnedBindingProbe = .{ .fixture = &fixture };
    var prepared = try core.prepareBinding(gpa, probe.options());
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    const outer_record = fixture.device.error_scopes.scopes.items[0];
    var worker: PreparedPushWorker = .{ .fixture = &fixture };
    guard.unlock(io);
    {
        defer guard = fixture.lock();
        const thread = try std.Thread.spawn(.{}, PreparedPushWorker.run, .{&worker});
        thread.join();
    }
    var lease = worker.lease.?;
    defer if (lease.entries != null) {
        var settlement = lease.deinit(&guard);
        fixture.dispatch(&guard, &settlement);
    };
    var popped = try fixture.device.popBoundErrorScope(&guard, &prepared);
    defer popped.ticket.deinit(&guard);
    defer cancelOwnedBinding(&fixture, &guard, &popped.binding);
    try std.testing.expectEqual(core.ErrorFilter.internal, popped.ticket.record.?.filter);
    try std.testing.expect(fixture.device.error_scopes.scopes.items[0] == outer_record);
    var outer = try fixture.device.popErrorScope(&guard);
    defer outer.deinit(&guard);
    try std.testing.expect(!popped.ticket.isReady(&guard));
    try std.testing.expect(!outer.isReady(&guard));
    guard.unlock(io);
    popped.binding.notifyReady(io);
    guard = fixture.lock();
    var settlement = try lease.settle(&guard, null);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 1), probe.notify_count);
    var inner_result = try popped.ticket.take(&guard);
    defer inner_result.deinit();
    var outer_result = try outer.take(&guard);
    defer outer_result.deinit();
    try std.testing.expect(inner_result.error_ref == null);
    try std.testing.expect(outer_result.error_ref == null);
}

test "owned pop stays dormant through settlement until explicit activation without allocating" {
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    const allocator = failing.allocator();
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var probe: OwnedBindingProbe = .{ .fixture = &fixture };
    var prepared = try core.prepareBinding(allocator, probe.options());
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    try fixture.device.pushErrorScope(allocator, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(allocator, &guard, .all);
    defer if (lease.entries != null) {
        var aborted = lease.deinit(&guard);
        fixture.dispatch(&guard, &aborted);
    };
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var popped = try fixture.device.popBoundErrorScope(&guard, &prepared);
    defer popped.ticket.deinit(&guard);
    defer cancelOwnedBinding(&fixture, &guard, &popped.binding);
    var settlement = try lease.settle(&guard, null);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 0), probe.notify_count);
    guard.unlock(io);
    popped.binding.notifyReady(io);
    popped.binding.notifyReady(io);
    guard = fixture.lock();
    try std.testing.expectEqual(@as(u32, 1), probe.notify_count);
    try std.testing.expect(!failing.has_induced_failure);
    popped.ticket.deinit(&guard);
}

test "claimed owned notification preserves real heap context through self cancellation and rebind" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var state: OwnedClaimState = .{};
    const context = try gpa.create(OwnedClaimContext);
    context.* = .{ .fixture = &fixture, .state = &state };
    var prepared = core.prepareBinding(gpa, .{
        .context = context,
        .notify_callback = OwnedClaimContext.notify,
        .release_context_callback = OwnedClaimContext.release,
    }) catch |err| {
        gpa.destroy(context);
        return err;
    };
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    try fixture.device.pushErrorScope(gpa, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    defer if (lease.entries != null) {
        var aborted = lease.deinit(&guard);
        fixture.dispatch(&guard, &aborted);
    };
    const diagnostic = try makeError(gpa, .{ .validation = error.BufferSizeTooSmall }, "claimed owned result", lease.errorQuota());
    defer diagnostic.release();
    var popped = try fixture.device.popBoundErrorScope(&guard, &prepared);
    defer popped.ticket.deinit(&guard);
    defer cancelOwnedBinding(&fixture, &guard, &popped.binding);
    context.ticket = &popped.ticket;
    context.binding = &popped.binding;
    guard.unlock(io);
    popped.binding.notifyReady(io);
    guard = fixture.lock();
    var settlement = try lease.settle(&guard, diagnostic);
    fixture.dispatch(&guard, &settlement);
    try std.testing.expectEqual(@as(u32, 1), state.notify_count);
    try std.testing.expectEqual(@as(u32, 1), state.release_count);
    try std.testing.expect(state.context_survived_self_cancel);
    try std.testing.expect(state.record_pinned_during_claim);
    try std.testing.expect(state.release_after_return);
    try std.testing.expect(state.release_after_core_refs);
    try std.testing.expectEqual(@as(u32, 1), fixture.notify_count);
    try std.testing.expectError(error.ScopeTicketConsumed, popped.ticket.take(&guard));
}

test "owned context release reacquires the original guard after a real scope condition wait" {
    var fixture: Fixture = undefined;
    fixture.init(gpa);
    var probe: OwnedBindingProbe = .{ .fixture = &fixture };
    var prepared = try core.prepareBinding(gpa, probe.options());
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    defer abortPrepared(&fixture, &guard, &prepared);
    try fixture.device.pushErrorScope(gpa, &guard, .internal);
    var lease = try fixture.device.captureScopeLeaseSet(gpa, &guard, .all);
    defer if (lease.entries != null) {
        var aborted = lease.deinit(&guard);
        fixture.dispatch(&guard, &aborted);
    };
    var popped = try fixture.device.popBoundErrorScope(&guard, &prepared);
    defer popped.ticket.deinit(&guard);
    defer cancelOwnedBinding(&fixture, &guard, &popped.binding);
    guard.unlock(io);
    popped.binding.notifyReady(io);
    guard = fixture.lock();
    var worker: PreparedSettleWorker = .{ .fixture = &fixture, .lease = &lease };
    const thread = try std.Thread.spawn(.{}, PreparedSettleWorker.run, .{&worker});
    {
        defer {
            guard.unlock(io);
            thread.join();
            guard = fixture.lock();
        }
        try std.testing.expect(guard.mutex == &fixture.mutex);
        try std.testing.expect(!popped.ticket.isReady(&guard));
        try popped.ticket.wait(io, &guard, 64);
        var result = try popped.ticket.take(&guard);
        defer result.deinit();
        try std.testing.expect(result.error_ref == null);
    }
    try std.testing.expectEqual(@as(u32, 1), probe.notify_count);
    var cleanup = popped.binding.deinit(&guard);
    try std.testing.expectEqual(@as(u32, 0), probe.release_count);
    dispatchBindingRelease(&fixture, &guard, &cleanup);
    dispatchBindingRelease(&fixture, &guard, &cleanup);
    try std.testing.expectEqual(@as(u32, 1), probe.release_count);
    try std.testing.expect(probe.core_refs_clear_at_release);
}

fn abortPrepared(fixture: *Fixture, guard: *core.ObjectGuard, prepared: *core.PreparedScopeBinding) void {
    guard.unlock(io);
    prepared.deinit(io);
    guard.* = fixture.lock();
}

fn dispatchBindingRelease(fixture: *Fixture, guard: *core.ObjectGuard, cleanup: *core.ScopeBindingRelease) void {
    guard.unlock(io);
    cleanup.dispatch(io);
    guard.* = fixture.lock();
}

fn cancelOwnedBinding(fixture: *Fixture, guard: *core.ObjectGuard, binding: *core.OwnedScopeBinding) void {
    var cleanup = binding.deinit(guard);
    dispatchBindingRelease(fixture, guard, &cleanup);
}

const OwnedBindingProbe = struct {
    fixture: *Fixture,
    allocation_owner: ?*std.testing.FailingAllocator = null,
    notify_count: u32 = 0,
    release_count: u32 = 0,
    node_freed_before_release: bool = false,
    core_refs_clear_at_release: bool = false,

    fn options(self: *OwnedBindingProbe) core.ScopeBindingOptions {
        return .{ .context = self, .notify_callback = notify, .release_context_callback = release };
    }

    fn notify(callback_io: std.Io, opaque_context: *anyopaque) void {
        const self: *OwnedBindingProbe = @ptrCast(@alignCast(opaque_context));
        var guard = core.ObjectGuard.lockUncancelable(callback_io, self.fixture.device.borrow().objects);
        defer guard.unlock(callback_io);
        self.notify_count += 1;
    }

    fn release(callback_io: std.Io, opaque_context: *anyopaque) void {
        const self: *OwnedBindingProbe = @ptrCast(@alignCast(opaque_context));
        var guard = core.ObjectGuard.lockUncancelable(callback_io, self.fixture.device.borrow().objects);
        defer guard.unlock(callback_io);
        self.release_count += 1;
        const stack = &self.fixture.device.error_scopes;
        self.core_refs_clear_at_release = stack.live_records == 0 and stack.lease_sets == 0 and stack.tickets == 0;
        if (self.allocation_owner) |allocator| {
            self.node_freed_before_release = allocator.allocations == allocator.deallocations;
        }
    }
};

const PreparedPushWorker = struct {
    fixture: *Fixture,
    lease: ?core.ScopeLeaseSet = null,

    fn run(self: *PreparedPushWorker) void {
        var guard = self.fixture.lock();
        defer guard.unlock(io);
        self.fixture.device.pushErrorScope(self.fixture.allocator, &guard, .internal) catch @panic("concurrent push failed");
        self.lease = self.fixture.device.captureScopeLeaseSet(self.fixture.allocator, &guard, .all) catch @panic("concurrent capture failed");
    }
};

const PreparedSettleWorker = struct {
    fixture: *Fixture,
    lease: *core.ScopeLeaseSet,

    fn run(self: *PreparedSettleWorker) void {
        var guard = self.fixture.lock();
        var settlement = self.lease.settle(&guard, null) catch @panic("condition settlement failed");
        guard.unlock(io);
        settlement.dispatch(io);
    }
};

const OwnedClaimState = struct {
    notify_count: u32 = 0,
    release_count: u32 = 0,
    context_survived_self_cancel: bool = false,
    record_pinned_during_claim: bool = false,
    notify_returned: bool = false,
    release_after_return: bool = false,
    release_after_core_refs: bool = false,
};

const OwnedClaimContext = struct {
    fixture: *Fixture,
    state: *OwnedClaimState,
    ticket: *core.ScopeTicket = undefined,
    binding: *core.OwnedScopeBinding = undefined,

    fn notify(callback_io: std.Io, opaque_context: *anyopaque) void {
        const self: *OwnedClaimContext = @ptrCast(@alignCast(opaque_context));
        var guard = core.ObjectGuard.lockUncancelable(callback_io, self.fixture.device.borrow().objects);
        self.state.notify_count += 1;
        var cleanup = self.binding.deinit(&guard);
        var rebound = self.ticket.bind(self.fixture.allocator, &guard, self.fixture, recordReady) catch @panic("claimed rebind failed");
        var result = self.ticket.take(&guard) catch @panic("claimed ticket unavailable");
        std.debug.assert(std.mem.eql(u8, "claimed owned result", result.error_ref.?.view().message));
        result.deinit();
        self.fixture.device.deinit(self.fixture.allocator, &guard) catch |err| {
            std.debug.assert(err == error.ResourceInUse);
            self.state.record_pinned_during_claim = true;
        };
        guard.unlock(callback_io);
        cleanup.dispatch(callback_io);
        std.debug.assert(self.state.release_count == 0);
        rebound.notifyReady(callback_io);
        guard = self.fixture.lock();
        rebound.deinit(&guard);
        guard.unlock(callback_io);
        self.state.context_survived_self_cancel = self.state.release_count == 0;
        self.state.notify_returned = true;
    }

    fn release(callback_io: std.Io, opaque_context: *anyopaque) void {
        const self: *OwnedClaimContext = @ptrCast(@alignCast(opaque_context));
        var guard = core.ObjectGuard.lockUncancelable(callback_io, self.fixture.device.borrow().objects);
        self.state.release_count += 1;
        self.state.release_after_return = self.state.notify_returned;
        const stack = &self.fixture.device.error_scopes;
        self.state.release_after_core_refs = stack.live_records == 0 and stack.lease_sets == 0 and stack.tickets == 0;
        guard.unlock(callback_io);
        gpa.destroy(self);
    }
};

fn makeError(
    allocator: std.mem.Allocator,
    code: core.ErrorCode,
    message: []const u8,
    additional: u32,
) !core.ErrorRef {
    var reservation = try core.ErrorReservation.prepare(allocator);
    defer reservation.discard();
    try reservation.reserveReferences(additional);
    var draft = try core.ErrorDraft.initMessage(allocator, code, message, &.{});
    defer draft.discard();
    return reservation.seal(&draft);
}

fn drainReadyScopes(fixture: *Fixture, guard: *core.ObjectGuard, count: usize) !void {
    for (0..count) |_| {
        var ticket = try fixture.device.popErrorScope(guard);
        defer ticket.deinit(guard);
        try std.testing.expect(ticket.isReady(guard));
        var result = try ticket.take(guard);
        defer result.deinit();
        try std.testing.expect(result.error_ref == null);
    }
    try std.testing.expectError(error.ErrorScopeStackEmpty, fixture.device.popErrorScope(guard));
}

fn failScopeRecords(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    for (0..40) |index| {
        fixture.device.pushErrorScope(allocator, &guard, .validation) catch |err| {
            // A refused push must neither add a record nor consume earlier records.
            try drainReadyScopes(&fixture, &guard, index);
            return err;
        };
    }
    try drainReadyScopes(&fixture, &guard, 40);
}

fn failLeaseArrays(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    for (0..40) |_| try fixture.device.pushErrorScope(allocator, &guard, .validation);
    var lease = fixture.device.captureScopeLeaseSet(allocator, &guard, .all) catch |err| {
        // Every pending increment and record pin must roll back on refusal.
        try drainReadyScopes(&fixture, &guard, 40);
        return err;
    };
    var settlement = lease.deinit(&guard);
    fixture.dispatch(&guard, &settlement);
    try drainReadyScopes(&fixture, &guard, 40);
}

fn failBindings(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    fixture.init(allocator);
    var guard = fixture.lock();
    defer guard.unlock(io);
    defer fixture.deinit(&guard);
    try fixture.device.pushErrorScope(allocator, &guard, .validation);
    var lease = try fixture.device.captureScopeLeaseSet(allocator, &guard, .all);
    defer {
        var settlement = lease.deinit(&guard);
        fixture.dispatch(&guard, &settlement);
        std.debug.assert(fixture.notify_count == 0);
    }
    var pending = try fixture.device.popErrorScope(&guard);
    defer pending.deinit(&guard);
    var pending_binding = pending.bind(allocator, &guard, &fixture, recordReady) catch |err| {
        try std.testing.expect(!pending.isReady(&guard));
        try std.testing.expectError(error.ScopePending, pending.take(&guard));
        return err;
    };
    defer pending_binding.deinit(&guard);
    try fixture.device.pushErrorScope(allocator, &guard, .internal);
    var ready = try fixture.device.popErrorScope(&guard);
    defer ready.deinit(&guard);
    var ready_binding = ready.bind(allocator, &guard, &fixture, recordReady) catch |err| {
        // Binding allocation refusal does not consume the ticket result.
        try std.testing.expect(ready.isReady(&guard));
        var result = try ready.take(&guard);
        defer result.deinit();
        try std.testing.expect(result.error_ref == null);
        return err;
    };
    defer ready_binding.deinit(&guard);
    var result = try ready.take(&guard);
    defer result.deinit();
    try std.testing.expect(result.error_ref == null);
}

fn publishWorkerError(allocator: std.mem.Allocator, additional: u32) !core.ErrorRef {
    var reservation = try core.ErrorReservation.prepare(allocator);
    defer reservation.discard();
    try reservation.reserveReferences(additional);
    var message = "worker-owned detail".*;
    var context = "worker context".*;
    var draft = try core.ErrorDraft.initMessage(allocator, .{ .validation = error.EncoderAlreadyFinished }, &message, &.{.{ .text = &context }});
    defer draft.discard();
    @memset(&message, 'x');
    @memset(&context, 'y');
    return reservation.seal(&draft);
}

fn expectFilter(code: core.ErrorCode, filter: core.ErrorFilter, want: bool) !void {
    try std.testing.expectEqual(want, core.matchesFilter(filter, code));
}

fn recordUncaptured(
    allocator: std.mem.Allocator,
    callback_io: std.Io,
    context: *anyopaque,
    view: core.ErrorView,
) void {
    _ = allocator;
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.uncaptured_count += 1;
    fixture.uncaptured_code = view.code;
    std.debug.assert(view.message.len <= fixture.message.len);
    fixture.message_len = view.message.len;
    @memcpy(fixture.message[0..view.message.len], view.message);
    if (fixture.reenter) {
        var guard = core.ObjectGuard.lockUncancelable(callback_io, fixture.device.borrow().objects);
        defer guard.unlock(callback_io);
        fixture.device.deinit(fixture.allocator, &guard) catch |err| {
            std.debug.assert(err == error.ResourceInUse);
            fixture.delivery_refused_deinit = true;
        };
        fixture.device.pushErrorScope(fixture.allocator, &guard, .validation) catch
            @panic("callback reentry push failed");
        var ticket = fixture.device.popErrorScope(&guard) catch @panic("callback reentry pop failed");
        defer ticket.deinit(&guard);
        var result = ticket.take(&guard) catch @panic("callback reentry scope pending");
        defer result.deinit();
        std.debug.assert(result.error_ref == null);
    }
    fixture.callback_view_survived = std.mem.eql(u8, fixture.message[0..fixture.message_len], view.message);
}

fn recordReady(callback_io: std.Io, context: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    var guard = core.ObjectGuard.lockUncancelable(callback_io, fixture.device.borrow().objects);
    defer guard.unlock(callback_io);
    fixture.notify_count += 1;
}

const SelfCancelReady = struct {
    fixture: *Fixture,
    ticket: *core.ScopeTicket,
    binding: *core.ScopeBinding,
    calls: u32 = 0,
    pin_refused_deinit: bool = false,

    fn notify(callback_io: std.Io, context: *anyopaque) void {
        const self: *SelfCancelReady = @ptrCast(@alignCast(context));
        var guard = core.ObjectGuard.lockUncancelable(callback_io, self.fixture.device.borrow().objects);
        defer guard.unlock(callback_io);
        self.calls += 1;
        self.binding.deinit(&guard);
        var result = self.ticket.take(&guard) catch @panic("ready callback ticket unavailable");
        defer result.deinit();
        std.debug.assert(result.error_ref == null);
        self.fixture.device.deinit(self.fixture.allocator, &guard) catch |err| {
            std.debug.assert(err == error.ResourceInUse);
            self.pin_refused_deinit = true;
        };
        self.fixture.device.pushErrorScope(self.fixture.allocator, &guard, .internal) catch
            @panic("ready callback reentry push failed");
        var reentered = self.fixture.device.popErrorScope(&guard) catch
            @panic("ready callback reentry pop failed");
        defer reentered.deinit(&guard);
        var empty = reentered.take(&guard) catch @panic("ready callback reentry pending");
        defer empty.deinit();
        std.debug.assert(empty.error_ref == null);
    }
};

const ConcurrentGate = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    arrived: u32 = 0,
    start: bool = false,
    first_settled: bool = false,
};

const ConcurrentTask = struct {
    fixture: *Fixture,
    gate: *ConcurrentGate,
    lease: *core.ScopeLeaseSet,
    reference: core.ErrorRef,
    first: bool,
    duplicate_rejected: bool = false,

    fn run(self: *ConcurrentTask) void {
        defer self.reference.release();
        const gate = self.gate;
        gate.mutex.lockUncancelable(io);
        gate.arrived += 1;
        gate.condition.broadcast(io);
        for (0..64) |_| {
            if (gate.start) break;
            gate.condition.wait(io, &gate.mutex) catch @panic("thread start canceled");
        }
        std.debug.assert(gate.start);
        if (!self.first) {
            for (0..64) |_| {
                if (gate.first_settled) break;
                gate.condition.wait(io, &gate.mutex) catch @panic("first settlement canceled");
            }
            std.debug.assert(gate.first_settled);
        }
        gate.mutex.unlock(io);
        var guard = self.fixture.lock();
        var settlement = self.lease.settle(&guard, self.reference) catch
            @panic("accepted thread could not settle");
        if (self.lease.settle(&guard, null)) |_| {
            @panic("duplicate thread settlement accepted");
        } else |err| {
            std.debug.assert(err == error.ScopeLeaseAlreadySettled);
            self.duplicate_rejected = true;
        }
        guard.unlock(io);
        if (self.first) {
            gate.mutex.lockUncancelable(io);
            gate.first_settled = true;
            gate.condition.broadcast(io);
            gate.mutex.unlock(io);
        }
        settlement.dispatch(io);
    }
};
