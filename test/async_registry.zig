//! Registry behavior tests use real owned cells, owner callback gates, virtual
//! monotonic deadlines and native Io task cancellation. No generated Proc
//! wiring or native-driver stand-ins are involved.

const std = @import("std");
const dusk = @import("dusk");
const registry = dusk.engine.async_registry;
const api = dusk.api;
const t = std.testing;
const io = std.testing.io;

const Record = struct {
    delivered: usize = 0,
    disposed: usize = 0,
    destroyed: usize = 0,
    value: u32 = 0,
    reentry: bool = false,
    owner: ?*OwnerState = null,
    lock_free: bool = false,
    owner_close_refused: bool = false,
    check_reclaim: bool = false,
    reclaim_refused: bool = false,
};
const Payload = struct {
    record: *Record,
    registry: *registry.CompletionRegistry,
    future: api.Future = .{ .id = 0 },
    terminal: u32 = 0,
    spawn_record: ?*Record = null,
    callback_gate: ?*CallbackGate = null,
    loss: ?*Cell = null,
    pair_post: ?*PairPost = null,
    identity_post: ?*IdentityPost = null,
    fn invoke(self: *Payload, call_io: std.Io) void {
        self.record.delivered += 1;
        self.record.value = self.terminal;
        if (self.callback_gate) |gate| {
            gate.entered.set(call_io);
            gate.resume_event.waitUncancelable(call_io);
        }
        if (self.spawn_record) |record| {
            const child = self.registry.prepare(Payload, call_io, .{ .record = record, .registry = self.registry }, ops, .{
                .mode = .allow_process_events,
                .callback = true,
            }) catch @panic("child preparation failed");
            _ = self.registry.accept(call_io, &child.header, null) catch @panic("child acceptance failed");
            if (!self.registry.beginFinish(call_io, &child.header)) @panic("child terminal claim failed");
            child.context.terminal = 107;
            self.registry.publish(call_io, &child.header, false);
            self.registry.release(call_io, &child.header, .runner) catch @panic("child runner release failed");
        }
        if (self.record.owner) |owner| {
            const owner_free = owner.mutex.tryLock();
            if (owner_free) owner.mutex.unlock(call_io);
            const registry_free = self.registry.mutex.tryLock();
            if (registry_free) self.registry.mutex.unlock(call_io);
            self.record.lock_free = owner_free and registry_free and owner.callbacks == 1;
            const preflight = self.registry.ownerPreflight(call_io, owner.identity);
            self.record.owner_close_refused = if (preflight) |_| false else |err| err == error.ResourceInUse;
            self.registry.close(call_io) catch |err| {
                if (err != error.InstanceInUse) @panic("wrong active callback close error");
            };
        }
        if (self.record.reentry) {
            var infos = [_]api.FutureWaitInfo{.{ .future = self.future, .completed = false }};
            const result = self.registry.waitAny(call_io, &infos, 0);
            if (result) |_| @panic("self callback wait succeeded") else |err| {
                if (err != error.ReentrantWait) @panic("wrong reentrant wait error");
            }
            self.registry.processEvents(call_io) catch @panic("independent reentrant poll failed");
        }
    }
    fn dispose(self: *Payload, _: std.Io) void {
        self.record.disposed += 1;
    }
    fn shutDown(self: *Payload, _: std.Io) void {
        self.terminal = 99;
    }
    fn deinit(self: *Payload, _: std.mem.Allocator, call_io: std.Io) void {
        self.record.destroyed += 1;
        if (self.record.check_reclaim) {
            const result = self.registry.close(call_io);
            self.record.reclaim_refused = if (result) |_| false else |err| err == error.InstanceInUse;
        }
    }
};
const Cell = registry.Cell(Payload);
const ops: Cell.Operations = .{ .invoke = Payload.invoke, .dispose = Payload.dispose, .shut_down = Payload.shutDown, .deinit = Payload.deinit };
fn make(r: *registry.CompletionRegistry, record: *Record, mode: api.CallbackMode, callback: bool) !*Cell {
    return r.prepare(Payload, io, .{ .record = record, .registry = r }, ops, .{ .mode = mode, .callback = callback });
}
fn complete(r: *registry.CompletionRegistry, cell: *Cell, value: u32, resource: bool) !void {
    try t.expect(r.beginFinish(io, &cell.header));
    cell.context.terminal = value;
    r.publish(io, &cell.header, resource);
    try r.release(io, &cell.header, .runner);
}
fn rejectedPost(_: *registry.Header, _: std.Io) registry.AsyncStartError!void {
    return error.TaskQueueFull;
}

test "namespace authority is numeric distinct checked and never reused" {
    var source = registry.FutureNamespaceSource.init();
    const a = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer a.close(io) catch unreachable;
    const b = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer b.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(a, &record, .wait_any_only, false);
    const future = try a.accept(io, &cell.header, null);
    try t.expectEqual(@as(u32, 1), @as(u32, @truncate(future.id)));
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectError(error.FutureInstanceMismatch, b.waitAny(io, &infos, 0));
    infos[0].future.id = 0;
    try t.expectError(error.InvalidFutureId, a.waitAny(io, &infos, 0));
    infos[0].future.id = future.id + 1;
    try t.expectError(error.InvalidFutureId, a.waitAny(io, &infos, 0));
    try complete(a, cell, 7, false);
    infos[0].future = future;
    try t.expectEqual(api.WaitStatus.success, try a.waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expectEqual(@as(usize, 1), record.destroyed);
    source.next.store(std.math.maxInt(u32), .monotonic);
    try t.expectError(error.FutureNamespaceExhausted, source.issue());
}

test "failed posting and capacity admission consume no sequence or callback" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{ .max_live_operations = 1 });
    defer r.close(io) catch unreachable;
    var failed: Record = .{};
    const first = try make(r, &failed, .allow_spontaneous, true);
    try t.expectError(error.TaskQueueFull, r.accept(io, &first.header, rejectedPost));
    try t.expectEqual(@as(u64, 0), first.header.future.id);
    r.rollback(io, &first.header);
    try t.expectEqual(@as(usize, 0), failed.delivered);
    var a: Record = .{};
    var b: Record = .{};
    const active = try make(r, &a, .wait_any_only, false);
    const future = try r.accept(io, &active.header, null);
    const rejected = try make(r, &b, .wait_any_only, false);
    try t.expectError(error.AsyncCapacityExceeded, r.accept(io, &rejected.header, null));
    r.rollback(io, &rejected.header);
    try complete(r, active, 1, false);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    _ = try r.waitAny(io, &infos, 0);
    const next = try make(r, &b, .wait_any_only, false);
    const next_future = try r.accept(io, &next.header, null);
    try t.expectEqual(@as(u32, 2), @as(u32, @truncate(next_future.id)));
    try complete(r, next, 2, false);
    infos[0] = .{ .future = next_future, .completed = false };
    _ = try r.waitAny(io, &infos, 0);
}

test "readiness differs from delivery modes and duplicate IDs deliver exactly once" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var records = [_]Record{ .{}, .{}, .{} };
    const modes = [_]api.CallbackMode{ .wait_any_only, .allow_process_events, .allow_spontaneous };
    var futures: [3]api.Future = undefined;
    for (modes, 0..) |mode, i| {
        const cell = try make(r, &records[i], mode, true);
        futures[i] = try r.accept(io, &cell.header, null);
        try complete(r, cell, @intCast(i + 10), false);
    }
    try t.expectEqual(@as(usize, 0), records[0].delivered);
    try t.expectEqual(@as(usize, 0), records[1].delivered);
    try t.expectEqual(@as(usize, 1), records[2].delivered);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 0), records[0].delivered);
    try t.expectEqual(@as(usize, 1), records[1].delivered);
    var infos = [_]api.FutureWaitInfo{
        .{ .future = futures[0], .completed = false },
        .{ .future = futures[0], .completed = false },
    };
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
    try t.expect(infos[0].completed and infos[1].completed);
    try t.expectEqual(@as(usize, 1), records[0].delivered);
    _ = try r.waitAny(io, &infos, 0);
    try t.expectEqual(@as(usize, 1), records[0].delivered);
}

test "full wait validation precedes any callback and advertised count is configurable" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{ .max_wait_count = 2 });
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, true);
    const future = try r.accept(io, &cell.header, null);
    try complete(r, cell, 3, false);
    var infos = [_]api.FutureWaitInfo{ .{ .future = future, .completed = false }, .{ .future = .{ .id = 0 }, .completed = false } };
    try t.expectError(error.InvalidFutureId, r.waitAny(io, &infos, 0));
    try t.expectEqual(@as(usize, 0), record.delivered);
    try t.expectError(error.FutureCountMismatch, r.waitAnyCount(io, 1, &infos, 0));
    try t.expectError(error.FutureCountMismatch, r.waitAnyCount(io, 1, null, 0));
    var too_many = [_]api.FutureWaitInfo{ .{ .future = future, .completed = false }, .{ .future = future, .completed = false }, .{ .future = future, .completed = false } };
    try t.expectError(error.WaitCountExceeded, r.waitAny(io, &too_many, 1));
    try t.expectEqual(api.WaitStatus.success, try r.waitAnyCount(io, 0, null, 1));
    infos[1].future = future;
    _ = try r.waitAny(io, &infos, 0);
}

test "callback reentry is allowed but waiting for its own delivery is rejected" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{ .reentry = true };
    const cell = try make(r, &record, .allow_spontaneous, true);
    cell.context.future = try r.accept(io, &cell.header, null);
    try complete(r, cell, 13, false);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(usize, 1), record.destroyed);
}

test "native observer cancellation keeps accepted work and disposes late result" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    const future = try r.accept(io, &cell.header, null);
    try r.retain(io, &cell.header, .observer);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectEqual(api.WaitStatus.timed_out, try r.waitAny(io, &infos, 0));
    r.cancelObserver(io, &cell.header);
    try t.expectEqual(@as(usize, 0), record.destroyed);
    try complete(r, cell, 29, true);
    try t.expectEqual(@as(usize, 1), record.disposed);
    try t.expectEqual(@as(usize, 1), record.destroyed);
    _ = try r.waitAny(io, &infos, 0);
    try t.expect(infos[0].completed);
}

test "native take transfers one result and close refuses live references" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    _ = try r.accept(io, &cell.header, null);
    try r.retain(io, &cell.header, .observer);
    try t.expectError(error.InstanceInUse, r.close(io));
    try complete(r, cell, 47, true);
    try t.expectError(error.InstanceInUse, r.close(io));
    try t.expect(r.claimConsumer(io, &cell.header));
    try t.expect(!r.claimConsumer(io, &cell.header));
    try t.expectEqual(@as(u32, 47), cell.context.terminal);
    r.finishConsumer(io, &cell.header);
    try r.release(io, &cell.header, .observer);
    try t.expectEqual(@as(usize, 0), record.disposed);
    try t.expectEqual(@as(usize, 1), record.destroyed);
    try r.close(io);
}

test "checked reference and sequence overflow leave state unchanged" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    r.issued = std.math.maxInt(u32);
    try t.expectError(error.FutureIdExhausted, r.accept(io, &cell.header, null));
    try t.expectEqual(@as(u64, 0), cell.header.future.id);
    r.issued = 0;
    _ = try r.accept(io, &cell.header, null);
    const saved = cell.header.references;
    cell.header.references = std.math.maxInt(u32);
    try t.expectError(error.ReferenceCountOverflow, r.retain(io, &cell.header, .observer));
    try t.expectEqual(@as(u32, 0), cell.header.observers);
    cell.header.references = saved;
    try t.expectError(error.InvalidReference, r.release(io, &cell.header, .observer));
    try complete(r, cell, 0, false);
}

test "final close delivers host callbacks despite wait-only mode without overwriting terminal" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, true);
    _ = try r.accept(io, &cell.header, null);
    try complete(r, cell, 61, false);
    try r.close(io);
    try t.expectEqual(@as(u32, 61), record.value);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(usize, 1), record.destroyed);
}

const OwnerState = struct {
    mutex: std.Io.Mutex = .init,
    identity: u64 = 71,
    callbacks: u32 = 0,
    claims: u32 = 0,
    finished: u32 = 0,
    stopped: bool = false,
    lock_attempts: std.atomic.Value(u32) = .init(0),
    lock_entered: ?*std.Io.Event = null,
    fn lock(self: *OwnerState, call_io: std.Io) void {
        _ = self.lock_attempts.fetchAdd(1, .monotonic);
        if (self.lock_entered) |event| event.set(call_io);
        self.mutex.lockUncancelable(call_io);
    }
    fn unlock(self: *OwnerState, call_io: std.Io) void {
        self.mutex.unlock(call_io);
    }
    fn claim(self: *OwnerState, _: registry.CallbackClass) bool {
        if (self.stopped) return false;
        self.callbacks += 1;
        self.claims += 1;
        return true;
    }
    fn finish(self: *OwnerState, _: registry.CallbackClass) void {
        std.debug.assert(self.callbacks > 0);
        self.callbacks -= 1;
        self.finished += 1;
    }
    fn binding(self: *OwnerState) registry.OwnerBinding {
        return registry.OwnerBinding.bind(OwnerState, self.identity, self, .{
            .lock = lock,
            .unlock = unlock,
            .claim = claim,
            .end_claim = finish,
        });
    }
};

test "real owner claim holds teardown gate and releases both locks before callback" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var record: Record = .{ .owner = &owner };
    const cell = try r.prepare(Payload, io, .{ .record = &record, .registry = r }, ops, .{
        .mode = .allow_spontaneous,
        .callback = true,
        .owner = owner.binding(),
    });
    _ = try r.accept(io, &cell.header, null);
    try complete(r, cell, 73, true);
    try t.expect(record.lock_free and record.owner_close_refused);
    try t.expectEqual(@as(u32, 1), owner.claims);
    try t.expectEqual(@as(u32, 1), owner.finished);
    try t.expectEqual(@as(u32, 0), owner.callbacks);
    try r.ownerPreflight(io, owner.identity);
}

test "loss callback depends on same-owner source frames and last source return dispatches it" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var frame: registry.DispatchFrame = .{};
    try r.enterExternalDispatch(io, &frame, owner.binding(), .logging);
    var record: Record = .{};
    const cell = try r.prepare(Payload, io, .{ .record = &record, .registry = r }, ops, .{
        .mode = .allow_spontaneous,
        .callback = true,
        .owner = owner.binding(),
        .callback_class = .device_lost,
    });
    const future = try r.accept(io, &cell.header, null);
    try complete(r, cell, 79, false);
    try t.expectEqual(@as(usize, 0), record.delivered);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectError(error.ReentrantWait, r.waitAny(io, &infos, 1));
    try t.expectError(error.ResourceInUse, r.ownerPreflight(io, owner.identity));
    try t.expectError(error.InstanceInUse, r.close(io));
    try r.leaveExternalDispatch(io, &frame);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(u32, 0), owner.callbacks);
    try t.expectEqual(@as(u32, 2), owner.finished);
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
}

test "winning terminal settlement is immutable and unsuccessful owner claim remains queued" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{ .stopped = true };
    var record: Record = .{};
    const cell = try r.prepare(Payload, io, .{ .record = &record, .registry = r }, ops, .{
        .mode = .allow_process_events,
        .callback = true,
        .owner = owner.binding(),
    });
    const future = try r.accept(io, &cell.header, null);
    try t.expect(r.beginFinish(io, &cell.header));
    try t.expect(!r.beginFinish(io, &cell.header));
    cell.context.terminal = 83;
    r.publish(io, &cell.header, true);
    try t.expect(!r.beginFinish(io, &cell.header));
    try r.release(io, &cell.header, .runner);
    const unchanged_epoch = r.epoch;
    try r.processEvents(io);
    try t.expectEqual(unchanged_epoch, r.epoch);
    try t.expectEqual(@as(u32, 0), owner.claims);
    try t.expectError(error.ResourceInUse, r.ownerPreflight(io, owner.identity));
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectEqual(api.WaitStatus.timed_out, try r.waitAny(io, &infos, 0));
    owner.stopped = false;
    try r.processEvents(io);
    try t.expectEqual(@as(u32, 83), record.value);
    try t.expectEqual(@as(usize, 1), record.delivered);
}

test "close refuses prepared cells and settles host pending cells after runner return" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, true);
    try t.expectError(error.InstanceInUse, r.close(io));
    _ = try r.accept(io, &cell.header, null);
    try r.release(io, &cell.header, .runner);
    try r.close(io);
    try t.expectEqual(@as(u32, 99), record.value);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(usize, 1), record.destroyed);
}

test "storage failures and missing authority consume no namespaces" {
    var source = registry.FutureNamespaceSource.init();
    try t.expectError(error.MissingFutureNamespaceSource, registry.CompletionRegistry.create(t.allocator, io, null, .{}));
    try t.expectError(error.InvalidAsyncCapacity, registry.CompletionRegistry.create(t.allocator, io, &source, .{ .max_live_operations = 0 }));
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, registry.CompletionRegistry.create(failing.allocator(), io, &source, .{}));
    try t.expectEqual(@as(u32, 0), source.next.load(.monotonic));
    var index_failure = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 1 });
    try t.expectError(error.OutOfMemory, registry.CompletionRegistry.create(index_failure.allocator(), io, &source, .{}));
    try t.expectEqual(@as(u32, 0), source.next.load(.monotonic));
}

const VirtualTime = struct {
    nanoseconds: std.atomic.Value(u64) = .init(0),
    sleeps: std.atomic.Value(u32) = .init(0),
    canceled: bool = false,
    fn now(context: ?*anyopaque, _: std.Io) i96 {
        const self: *VirtualTime = @ptrCast(@alignCast(context.?));
        return self.nanoseconds.load(.acquire);
    }
    fn sleep(context: ?*anyopaque, _: std.Io, deadline: i96) error{Canceled}!void {
        const self: *VirtualTime = @ptrCast(@alignCast(context.?));
        _ = self.sleeps.fetchAdd(1, .monotonic);
        if (self.canceled) return error.Canceled;
        self.nanoseconds.store(@intCast(deadline), .release);
    }
    fn capability(self: *VirtualTime) registry.Time {
        return .{ .context = self, .now = now, .sleep_until = sleep };
    }
};

test "monotonic timed condition wake cannot lose an immediate deadline publication" {
    var source = registry.FutureNamespaceSource.init();
    var clock: VirtualTime = .{};
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{ .time = clock.capability() });
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    const future = try r.accept(io, &cell.header, null);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectEqual(api.WaitStatus.timed_out, try r.waitAny(io, &infos, 50));
    try t.expectEqual(@as(u64, 50), clock.nanoseconds.load(.acquire));
    try t.expectEqual(@as(u32, 1), clock.sleeps.load(.monotonic));
    try t.expect(!infos[0].completed);
    try t.expectEqual(registry.Execution.pending, cell.header.execution);
    try t.expectEqual(@as(usize, 0), record.destroyed);
    try complete(r, cell, 89, false);
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
}

test "canceled timed capability leaves the accepted runner and numeric ID intact" {
    var source = registry.FutureNamespaceSource.init();
    var clock: VirtualTime = .{ .canceled = true };
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{ .time = clock.capability() });
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    const future = try r.accept(io, &cell.header, null);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectError(error.Canceled, r.waitAny(io, &infos, 50));
    try t.expectEqual(future.id, cell.header.future.id);
    try t.expectEqual(registry.Execution.pending, cell.header.execution);
    try t.expectEqual(@as(u32, 1), cell.header.runners);
    try complete(r, cell, 97, false);
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
}

const WaitJob = struct {
    r: *registry.CompletionRegistry,
    future: api.Future,
    entered: std.Io.Event = .unset,
    fn run(call_io: std.Io, self: *WaitJob) registry.FutureWaitError!api.WaitStatus {
        self.entered.set(call_io);
        var infos = [_]api.FutureWaitInfo{.{ .future = self.future, .completed = false }};
        return self.r.waitAny(call_io, &infos, std.math.maxInt(u64));
    }
};

test "actual Io cancellation joins only a waiter and does not withdraw accepted work" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    var job: WaitJob = .{ .r = r, .future = try r.accept(io, &cell.header, null) };
    var waiter = try io.concurrent(WaitJob.run, .{ io, &job });
    job.entered.waitUncancelable(io);
    try t.expectError(error.Canceled, waiter.cancel(io));
    try t.expectEqual(registry.Execution.pending, cell.header.execution);
    try t.expectEqual(@as(u32, 1), cell.header.runners);
    try t.expectEqual(@as(u32, 0), r.waiters);
    try complete(r, cell, 101, false);
}

test "process entry high-water excludes events created by that poll's callback" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var parent: Record = .{};
    var child: Record = .{};
    const cell = try r.prepare(Payload, io, .{ .record = &parent, .registry = r, .spawn_record = &child }, ops, .{
        .mode = .allow_process_events,
        .callback = true,
    });
    _ = try r.accept(io, &cell.header, null);
    try complete(r, cell, 103, false);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 1), parent.delivered);
    try t.expectEqual(@as(usize, 0), child.delivered);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 1), child.delivered);
    try t.expectEqual(@as(u32, 107), child.value);
}

const CallbackGate = struct {
    entered: std.Io.Event = .unset,
    resume_event: std.Io.Event = .unset,
};
const FinishJob = struct {
    r: *registry.CompletionRegistry,
    cell: *Cell,
    fn run(call_io: std.Io, self: *FinishJob) registry.ReferenceError!void {
        if (!self.r.beginFinish(call_io, &self.cell.header)) @panic("publisher lost unexpectedly");
        self.cell.context.terminal = 109;
        self.r.publish(call_io, &self.cell.header, false);
        try self.r.release(call_io, &self.cell.header, .runner);
    }
};

test "another thread's active callback is not completed and cannot be claimed twice" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    var gate: CallbackGate = .{};
    const cell = try r.prepare(Payload, io, .{ .record = &record, .registry = r, .callback_gate = &gate }, ops, .{
        .mode = .allow_spontaneous,
        .callback = true,
    });
    const future = try r.accept(io, &cell.header, null);
    var job: FinishJob = .{ .r = r, .cell = cell };
    var publisher = try io.concurrent(FinishJob.run, .{ io, &job });
    gate.entered.waitUncancelable(io);
    defer {
        gate.resume_event.set(io);
        publisher.await(io) catch {};
    }
    var infos = [_]api.FutureWaitInfo{ .{ .future = future, .completed = false }, .{ .future = future, .completed = false } };
    try t.expectEqual(api.WaitStatus.timed_out, try r.waitAny(io, &infos, 0));
    try t.expect(!infos[0].completed and !infos[1].completed);
    try r.processEvents(io);
    try t.expectError(error.InstanceInUse, r.close(io));
    gate.resume_event.set(io);
    try publisher.await(io);
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
    try t.expect(infos[0].completed and infos[1].completed);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(usize, 1), record.destroyed);
}

test "final cell destructor and prepared rollback keep registry alive through cleanup" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    var ready: Record = .{ .check_reclaim = true };
    const cell = try make(r, &ready, .wait_any_only, false);
    _ = try r.accept(io, &cell.header, null);
    try complete(r, cell, 113, false);
    try t.expect(ready.reclaim_refused);
    var staged: Record = .{ .check_reclaim = true };
    const prepared = try make(r, &staged, .wait_any_only, true);
    r.rollback(io, &prepared.header);
    try t.expect(staged.reclaim_refused);
    try r.close(io);
}

test "owner detachment reserves host metadata before native pointers can be cleared" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var record: Record = .{ .owner = &owner };
    const cell = try r.prepare(Payload, io, .{ .record = &record, .registry = r }, ops, .{
        .mode = .allow_process_events,
        .callback = true,
        .owner = owner.binding(),
    });
    const future = try r.accept(io, &cell.header, null);
    try r.retain(io, &cell.header, .candidate);
    try t.expectError(error.ResourceInUse, r.beginOwnerDetach(io, &cell.header));
    try complete(r, cell, 127, false);
    owner.lock(io);
    try r.beginOwnerDetach(io, &cell.header);
    owner.unlock(io);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 0), record.delivered);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectEqual(api.WaitStatus.timed_out, try r.waitAny(io, &infos, 0));
    owner.lock(io);
    record.owner = null; // typed host-only context no longer borrows high owner
    r.detachOwner(io, &cell.header);
    owner.unlock(io);
    try r.release(io, &cell.header, .candidate);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(u32, 0), owner.claims);
}

test "poll reference exhaustion reports a finite error without callback or ID residue" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .allow_process_events, true);
    const future = try r.accept(io, &cell.header, null);
    try complete(r, cell, 131, false);
    const references = cell.header.references;
    cell.header.references = std.math.maxInt(u32);
    try t.expectError(error.ReferenceCountOverflow, r.processEvents(io));
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectError(error.ReferenceCountOverflow, r.waitAny(io, &infos, 0));
    try t.expectEqual(@as(usize, 0), record.delivered);
    try t.expectEqual(@as(u32, 0), cell.header.candidates);
    try t.expectEqual(@as(u32, 0), r.processors);
    cell.header.references = references;
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 1), record.delivered);
}

test "pre-reserved observer survives immediate runner publication and consumes readiness once" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    try r.retain(io, &cell.header, .observer);
    _ = try r.accept(io, &cell.header, null);
    try complete(r, cell, 137, true);
    try r.waitReady(io, &cell.header);
    try t.expectEqual(@as(usize, 0), record.disposed);
    try t.expectEqual(@as(usize, 0), record.destroyed);
    try t.expect(r.claimConsumer(io, &cell.header));
    try t.expectEqual(@as(u32, 137), cell.context.terminal);
    r.finishConsumer(io, &cell.header);
    try r.release(io, &cell.header, .observer);
    try t.expectEqual(@as(usize, 1), record.destroyed);
}

test "failed admission can join and release a staging observer before rollback" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var record: Record = .{};
    const cell = try make(r, &record, .wait_any_only, false);
    try r.retain(io, &cell.header, .observer);
    try t.expectError(error.TaskQueueFull, r.accept(io, &cell.header, rejectedPost));
    try r.release(io, &cell.header, .observer);
    r.rollback(io, &cell.header);
    try t.expectEqual(@as(u32, 0), r.issued);
    try t.expectEqual(@as(usize, 0), record.delivered);
    try t.expectEqual(@as(usize, 1), record.destroyed);
}

test "cell allocation failure leaves typed input with caller and consumes no accepted ID" {
    var source = registry.FutureNamespaceSource.init();
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 2 });
    const r = try registry.CompletionRegistry.create(failing.allocator(), io, &source, .{});
    var record: Record = .{};
    try t.expectError(error.OutOfMemory, r.prepare(Payload, io, .{ .record = &record, .registry = r }, ops, .{
        .mode = .allow_spontaneous,
        .callback = true,
    }));
    try t.expectEqual(@as(u32, 0), r.issued);
    try t.expectEqual(@as(u32, 0), r.prepared_cells);
    try t.expectEqual(@as(usize, 0), record.destroyed);
    try t.expectEqual(@as(usize, 0), record.delivered);
    try r.close(io);
}

test "invalid external owner and reused dispatch frame fail before owner claim" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var frame: registry.DispatchFrame = .{};
    var invalid = owner.binding();
    invalid.identity = 0;
    try t.expectError(error.InvalidOwner, r.enterExternalDispatch(io, &frame, invalid, .uncaptured_error));
    try t.expectEqual(@as(u32, 0), owner.claims);
    try r.enterExternalDispatch(io, &frame, owner.binding(), .uncaptured_error);
    try t.expectError(error.InvalidRequest, r.enterExternalDispatch(io, &frame, owner.binding(), .uncaptured_error));
    try t.expectEqual(@as(u32, 1), owner.claims);
    try r.leaveExternalDispatch(io, &frame);
    try t.expectEqual(@as(u32, 1), owner.finished);
}

const PairPost = struct {
    calls: u32 = 0,
    failure: ?registry.AsyncStartError = null,
    worker: ?*PairWorker = null,
    task: ?std.Io.Future(void) = null,
    fn submit(header: *registry.Header, call_io: std.Io) registry.AsyncStartError!void {
        const cell: *Cell = @fieldParentPtr("header", header);
        const self = cell.context.pair_post.?;
        self.calls += 1;
        if (self.failure) |failure| return failure;
        if (self.worker) |worker| {
            self.task = call_io.concurrent(PairWorker.run, .{ call_io, worker }) catch
                return error.ConcurrencyUnavailable;
            worker.entered.waitUncancelable(call_io);
        }
    }
};

const PairWorker = struct {
    request: *Cell,
    entered: std.Io.Event = .unset,
    committed: bool = false,
    fn run(call_io: std.Io, self: *PairWorker) void {
        self.entered.set(call_io);
        const r = self.request.header.registry;
        const loss = self.request.context.loss.?;
        r.mutex.lockUncancelable(call_io);
        self.committed = self.request.header.execution == .pending and
            loss.header.execution == .pending and
            self.request.header.future.id != 0 and
            loss.header.future.id == self.request.header.future.id + 1 and
            self.request.header.runners == 1 and loss.header.runners == 1;
        r.mutex.unlock(call_io);
        if (!self.committed) @panic("worker observed incomplete pair admission");
        for ([_]*Cell{ self.request, loss }, 0..) |cell, index| {
            if (!r.beginFinish(call_io, &cell.header)) @panic("pair completion lost");
            cell.context.terminal = @intCast(151 + index);
            r.publish(call_io, &cell.header, true);
            r.release(call_io, &cell.header, .runner) catch @panic("pair runner release");
        }
    }
};

fn pairHeaders(request: *Cell, loss: *Cell) registry.HeaderPair {
    return .{ .request = &request.header, .loss = &loss.header };
}

test "pair requires two live slots and leaves the next single sequence available" {
    for ([_]u32{ 1, 2 }) |capacity| {
        var source = registry.FutureNamespaceSource.init();
        const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{
            .max_live_operations = capacity,
        });
        defer r.close(io) catch unreachable;
        var records = [_]Record{ .{}, .{}, .{} };
        var active: ?*Cell = null;
        if (capacity == 2) {
            active = try make(r, &records[2], .wait_any_only, false);
            _ = try r.accept(io, &active.?.header, null);
        }
        const request = try make(r, &records[0], .wait_any_only, false);
        const loss = try make(r, &records[1], .wait_any_only, false);
        var post: PairPost = .{};
        request.context.pair_post = &post;
        try t.expectError(error.AsyncCapacityExceeded, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
        try t.expectEqual(@as(u32, 0), post.calls);
        try t.expectEqual(@as(u64, 0), request.header.future.id);
        try t.expectEqual(@as(u64, 0), loss.header.future.id);
        r.rollback(io, &request.header);
        r.rollback(io, &loss.header);
        if (active) |cell| try complete(r, cell, 1, false);
        const single = try make(r, &records[0], .wait_any_only, false);
        const future = try r.accept(io, &single.header, null);
        try t.expectEqual(capacity, @as(u32, @truncate(future.id)));
        try complete(r, single, 2, false);
    }
}

test "pair consumes exactly the final two sequences but cannot consume the last single" {
    for ([_]u32{ 1, 2 }) |remaining| {
        var source = registry.FutureNamespaceSource.init();
        const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
        defer r.close(io) catch unreachable;
        r.issued = std.math.maxInt(u32) - remaining;
        var records = [_]Record{ .{}, .{}, .{} };
        const request = try make(r, &records[0], .wait_any_only, false);
        const loss = try make(r, &records[1], .wait_any_only, false);
        var post: PairPost = .{};
        request.context.pair_post = &post;
        if (remaining == 1) {
            try t.expectError(error.FutureIdExhausted, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
            try t.expectEqual(@as(u32, 0), post.calls);
            r.rollback(io, &request.header);
            r.rollback(io, &loss.header);
            const single = try make(r, &records[2], .wait_any_only, false);
            const future = try r.accept(io, &single.header, null);
            try t.expectEqual(std.math.maxInt(u32), @as(u32, @truncate(future.id)));
            try complete(r, single, 3, false);
        } else {
            const futures = try r.acceptPair(io, pairHeaders(request, loss), PairPost.submit);
            try t.expectEqual(std.math.maxInt(u32) - 1, @as(u32, @truncate(futures.request.id)));
            try t.expectEqual(std.math.maxInt(u32), @as(u32, @truncate(futures.loss.id)));
            try t.expectEqual(@as(u32, 1), post.calls);
            try complete(r, request, 4, false);
            try complete(r, loss, 5, false);
        }
        const exhausted = try make(r, &records[2], .wait_any_only, false);
        try t.expectError(error.FutureIdExhausted, r.accept(io, &exhausted.header, null));
        r.rollback(io, &exhausted.header);
    }
}

test "every post error leaves both prepared observers and IDs unchanged without sequence holes" {
    const failures = [_]registry.AsyncStartError{
        error.TaskQueueFull,          error.PoolShutDown, error.WorkerExhausted,
        error.ConcurrencyUnavailable, error.Canceled,
    };
    for (failures) |failure| {
        var source = registry.FutureNamespaceSource.init();
        const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
        defer r.close(io) catch unreachable;
        var records = [_]Record{ .{}, .{} };
        const request = try make(r, &records[0], .wait_any_only, false);
        const loss = try make(r, &records[1], .wait_any_only, false);
        try r.retain(io, &request.header, .observer);
        try r.retain(io, &loss.header, .observer);
        var post: PairPost = .{ .failure = failure };
        request.context.pair_post = &post;
        try t.expectError(failure, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
        try t.expectEqual(@as(u32, 1), post.calls);
        for ([_]*Cell{ request, loss }) |cell| {
            try t.expectEqual(@as(u64, 0), cell.header.future.id);
            try t.expectEqual(registry.Execution.staging, cell.header.execution);
            try t.expectEqual(@as(u32, 2), cell.header.references);
            try t.expectEqual(@as(u32, 1), cell.header.observers);
            try t.expectEqual(@as(u32, 0), cell.header.runners);
        }
        post.failure = null;
        const futures = try r.acceptPair(io, pairHeaders(request, loss), PairPost.submit);
        try t.expectEqual(@as(u32, 1), @as(u32, @truncate(futures.request.id)));
        try t.expectEqual(@as(u32, 2), @as(u32, @truncate(futures.loss.id)));
        for ([_]*Cell{ request, loss }, 0..) |cell, index| {
            try t.expectEqual(@as(u32, 3), cell.header.references);
            try complete(r, cell, @intCast(index), true);
            try r.waitReady(io, &cell.header);
            try t.expect(r.claimConsumer(io, &cell.header));
            r.finishConsumer(io, &cell.header);
            try r.release(io, &cell.header, .observer);
            try t.expectEqual(@as(usize, 0), records[index].disposed);
            try t.expectEqual(@as(usize, 1), records[index].destroyed);
        }
    }
}

test "either pair reference overflow refuses before post and permits retry" {
    for (0..2) |overflow_index| {
        var source = registry.FutureNamespaceSource.init();
        const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
        defer r.close(io) catch unreachable;
        var records = [_]Record{ .{}, .{} };
        const request = try make(r, &records[0], .wait_any_only, false);
        const loss = try make(r, &records[1], .wait_any_only, false);
        const cells = [_]*Cell{ request, loss };
        var post: PairPost = .{};
        request.context.pair_post = &post;
        for ([_]u32{ std.math.maxInt(u32), std.math.maxInt(u32) - 1 }) |references| {
            cells[overflow_index].header.references = references;
            cells[overflow_index].header.observers = references - 1;
            try t.expectError(error.ReferenceCountOverflow, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
            try t.expectEqual(@as(u32, 0), post.calls);
            cells[overflow_index].header.references = 1;
            cells[overflow_index].header.observers = 0;
        }
        const futures = try r.acceptPair(io, pairHeaders(request, loss), PairPost.submit);
        try t.expectEqual(@as(u32, 1), @as(u32, @truncate(futures.request.id)));
        try complete(r, request, 6, false);
        try complete(r, loss, 7, false);
    }
}

test "immediate posted worker observes both committed IDs and separate runner rights" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var records = [_]Record{ .{}, .{} };
    const request = try make(r, &records[0], .wait_any_only, false);
    const loss = try make(r, &records[1], .wait_any_only, false);
    try r.retain(io, &request.header, .observer);
    try r.retain(io, &loss.header, .observer);
    request.context.loss = loss;
    var worker: PairWorker = .{ .request = request };
    var post: PairPost = .{ .worker = &worker };
    request.context.pair_post = &post;
    const futures = try r.acceptPair(io, pairHeaders(request, loss), PairPost.submit);
    post.task.?.await(io);
    try t.expect(worker.committed);
    try t.expectEqual(@as(u32, 1), post.calls);
    try t.expectEqual(futures.request.id + 1, futures.loss.id);
    for ([_]*Cell{ request, loss }, 0..) |cell, index| {
        try t.expect(r.claimConsumer(io, &cell.header));
        try t.expectEqual(@as(u32, @intCast(151 + index)), cell.context.terminal);
        r.finishConsumer(io, &cell.header);
        try r.release(io, &cell.header, .observer);
        try t.expectEqual(@as(usize, 1), records[index].destroyed);
    }
}

test "pair preflight rejects duplicate foreign and corrupt staging rights before post" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    const foreign = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer foreign.close(io) catch unreachable;
    var records = [_]Record{ .{}, .{}, .{} };
    var owner: OwnerState = .{};
    const request = try r.prepare(Payload, io, .{ .record = &records[0], .registry = r }, ops, .{ .mode = .wait_any_only, .callback = false, .owner = owner.binding() });
    const loss = try r.prepare(Payload, io, .{ .record = &records[1], .registry = r }, ops, .{ .mode = .wait_any_only, .callback = false, .owner = owner.binding() });
    const other = try make(foreign, &records[2], .wait_any_only, false);
    var post: PairPost = .{};
    request.context.pair_post = &post;
    try t.expectError(error.InvalidRequest, r.acceptPair(io, pairHeaders(request, request), PairPost.submit));
    try t.expectError(error.InvalidRequest, r.acceptPair(io, pairHeaders(request, other), PairPost.submit));
    loss.header.runners = 1;
    try t.expectError(error.InvalidRequest, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
    loss.header.runners = 0;
    loss.header.delivery = .claimed;
    try t.expectError(error.InvalidRequest, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
    loss.header.delivery = .unclaimed;
    loss.header.references = 2;
    try t.expectError(error.InvalidRequest, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
    loss.header.references = 1;
    loss.header.owner_identity += 1;
    try t.expectError(error.InvalidOwner, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
    loss.header.owner_identity = owner.identity;
    const prepared = r.prepared_cells;
    r.prepared_cells = 1;
    try t.expectError(error.InvalidRequest, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
    r.prepared_cells = prepared;
    try t.expectEqual(@as(u32, 0), post.calls);
    r.rollback(io, &request.header);
    r.rollback(io, &loss.header);
    foreign.rollback(io, &other.header);
    try t.expectEqual(@as(usize, 0), records[0].delivered);
    const next = try make(r, &records[0], .wait_any_only, false);
    const future = try r.accept(io, &next.header, null);
    try t.expectEqual(@as(u32, 1), @as(u32, @truncate(future.id)));
    try complete(r, next, 8, false);
}

test "pair retarget refuses either shutdown claim without changing callback ownership" {
    for (0..2) |claimed_index| {
        var source = registry.FutureNamespaceSource.init();
        const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
        defer r.close(io) catch unreachable;
        var old: OwnerState = .{};
        var replacement: OwnerState = .{ .identity = 72 };
        var records = [_]Record{ .{ .owner = &old }, .{ .owner = &old } };
        const request = try r.prepare(Payload, io, .{ .record = &records[0], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = old.binding() });
        const loss = try r.prepare(Payload, io, .{ .record = &records[1], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = old.binding() });
        var post: PairPost = .{};
        request.context.pair_post = &post;
        const pair = pairHeaders(request, loss);
        const futures = try r.acceptPair(io, pair, PairPost.submit);
        const cells = [_]*Cell{ request, loss };
        old.mutex.lockUncancelable(io);
        replacement.mutex.lockUncancelable(io);
        const won = r.beginFinish(io, &cells[claimed_index].header);
        const adopted = r.retargetPendingPair(io, pair, old.identity, replacement.binding());
        replacement.mutex.unlock(io);
        old.mutex.unlock(io);
        try t.expect(won);
        try t.expect(!adopted);
        cells[claimed_index].context.terminal = 99;
        r.publish(io, &cells[claimed_index].header, false);
        try r.release(io, &cells[claimed_index].header, .runner);
        try complete(r, cells[1 - claimed_index], 99, false);
        try r.processEvents(io);
        try t.expectEqual(@as(u32, 2), old.claims);
        try t.expectEqual(@as(u32, 0), replacement.claims);
        for (records) |record| {
            try t.expectEqual(@as(u32, 99), record.value);
            try t.expect(record.owner_close_refused);
        }
        var infos = [_]api.FutureWaitInfo{
            .{ .future = futures.request, .completed = false },
            .{ .future = futures.loss, .completed = false },
        };
        try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
        try t.expect(infos[0].completed);
        try t.expect(infos[1].completed);
    }
}

const PollJob = struct {
    r: *registry.CompletionRegistry,
    fn run(call_io: std.Io, self: *PollJob) registry.ProcessEventsError!void {
        try self.r.processEvents(call_io);
    }
};

test "pending scans and retargeted terminal dispatch never capture the old owner gate" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var old: OwnerState = .{};
    var entered: std.Io.Event = .unset;
    var replacement: OwnerState = .{ .identity = 72, .lock_entered = &entered };
    var records = [_]Record{ .{ .owner = &replacement }, .{ .owner = &replacement } };
    const request = try r.prepare(Payload, io, .{ .record = &records[0], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = old.binding() });
    const loss = try r.prepare(Payload, io, .{ .record = &records[1], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = old.binding() });
    var post: PairPost = .{};
    request.context.pair_post = &post;
    const pair = pairHeaders(request, loss);
    const futures = try r.acceptPair(io, pair, PairPost.submit);
    old.mutex.lockUncancelable(io);
    replacement.mutex.lockUncancelable(io);
    var job: PollJob = .{ .r = r };
    var pending_scan = try io.concurrent(PollJob.run, .{ io, &job });
    try pending_scan.await(io);
    const adopted = r.retargetPendingPair(io, pair, old.identity, replacement.binding());
    const won = r.beginFinish(io, &request.header);
    replacement.mutex.unlock(io);
    old.mutex.unlock(io);
    try t.expect(adopted);
    try t.expect(won);
    request.context.terminal = 157;
    r.publish(io, &request.header, true);
    old.mutex.lockUncancelable(io);
    replacement.mutex.lockUncancelable(io);
    var terminal_scan = try io.concurrent(PollJob.run, .{ io, &job });
    entered.waitUncancelable(io);
    const readoption = r.retargetPendingPair(io, pair, replacement.identity, old.binding());
    replacement.mutex.unlock(io);
    old.mutex.unlock(io);
    try terminal_scan.await(io);
    try r.release(io, &request.header, .runner);
    try t.expect(!readoption);
    try t.expectEqual(@as(u32, 0), old.lock_attempts.load(.monotonic));
    try t.expectEqual(@as(u32, 0), old.claims);
    try t.expectEqual(@as(u32, 1), replacement.claims);
    try t.expect(records[0].lock_free);
    try t.expect(records[0].owner_close_refused);
    try complete(r, loss, 163, false);
    try r.processEvents(io);
    try t.expectEqual(@as(u32, 2), replacement.claims);
    try t.expectEqual(@as(u32, 2), replacement.finished);
    try t.expectEqual(@as(u32, 0), replacement.callbacks);
    var infos = [_]api.FutureWaitInfo{
        .{ .future = futures.request, .completed = false },
        .{ .future = futures.loss, .completed = false },
    };
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
    try t.expect(infos[0].completed);
    try t.expect(infos[1].completed);
}

const OtherPayload = struct {
    marker: u64 = 0xfade_cafe_1234_5678,
    record: *Record,
    fn invoke(self: *OtherPayload, _: std.Io) void {
        std.debug.assert(self.marker == 0xfade_cafe_1234_5678);
        self.record.delivered += 1;
        self.record.value = 173;
    }
    fn dispose(self: *OtherPayload, _: std.Io) void {
        std.debug.assert(self.marker == 0xfade_cafe_1234_5678);
        self.record.disposed += 1;
    }
    fn shutdown(_: *OtherPayload, _: std.Io) void {}
    fn deinit(self: *OtherPayload, _: std.mem.Allocator, _: std.Io) void {
        std.debug.assert(self.marker == 0xfade_cafe_1234_5678);
        self.record.destroyed += 1;
    }
};
const OtherCell = registry.Cell(OtherPayload);
const other_ops: OtherCell.Operations = .{
    .invoke = OtherPayload.invoke,
    .dispose = OtherPayload.dispose,
    .shut_down = OtherPayload.shutdown,
    .deinit = OtherPayload.deinit,
};

test "owner candidate pins numeric first cell and excludes wrong typed host disposal" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var records = [_]Record{ .{ .owner = &owner }, .{} };
    const cell = try r.prepare(Payload, io, .{ .record = &records[0], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = owner.binding() });
    const other = try r.prepare(OtherPayload, io, .{ .record = &records[1] }, other_ops, .{ .mode = .allow_process_events, .callback = true, .owner = owner.binding() });
    _ = try r.accept(io, &cell.header, null);
    _ = try r.accept(io, &other.header, null);
    try complete(r, cell, 167, false);
    try t.expect(r.beginFinish(io, &other.header));
    r.publish(io, &other.header, false);
    try r.release(io, &other.header, .runner);
    owner.mutex.lockUncancelable(io);
    const candidate = (try r.retainOwnerCandidate(io, owner.identity)).?;
    const typed = Cell.matchesOperations(candidate, ops);
    if (typed) {
        const selected: *Cell = @fieldParentPtr("header", candidate);
        try r.beginOwnerDetach(io, candidate);
        selected.context.record.owner = null;
        r.detachOwner(io, candidate);
    }
    owner.mutex.unlock(io);
    try t.expect(typed);
    try r.release(io, candidate, .candidate);
    owner.mutex.lockUncancelable(io);
    const unknown = (try r.retainOwnerCandidate(io, owner.identity)).?;
    const wrong_type = Cell.matchesOperations(unknown, ops);
    const correct_type = OtherCell.matchesOperations(unknown, other_ops);
    owner.mutex.unlock(io);
    try t.expect(!wrong_type);
    try t.expect(correct_type);
    try r.release(io, unknown, .candidate);
    try r.processEvents(io);
    try t.expectEqual(@as(u32, 167), records[0].value);
    try t.expectEqual(@as(u32, 173), records[1].value);
    try t.expectEqual(@as(usize, 0), records[1].disposed);
    try t.expectEqual(@as(usize, 1), records[1].destroyed);
    try t.expectEqual(@as(u32, 1), owner.claims);
    owner.mutex.lockUncancelable(io);
    const absent = try r.retainOwnerCandidate(io, owner.identity);
    owner.mutex.unlock(io);
    try t.expect(absent == null);
}

test "owner candidate overflow and an active callback refuse detach without losing ownership" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var record: Record = .{};
    var gate: CallbackGate = .{};
    const cell = try r.prepare(Payload, io, .{
        .record = &record,
        .registry = r,
        .callback_gate = &gate,
    }, ops, .{ .mode = .allow_spontaneous, .callback = true, .owner = owner.binding() });
    _ = try r.accept(io, &cell.header, null);
    const references = cell.header.references;
    owner.mutex.lockUncancelable(io);
    r.mutex.lockUncancelable(io);
    cell.header.references = std.math.maxInt(u32);
    r.mutex.unlock(io);
    const overflow = r.retainOwnerCandidate(io, owner.identity);
    r.mutex.lockUncancelable(io);
    const candidates = cell.header.candidates;
    cell.header.references = references;
    r.mutex.unlock(io);
    owner.mutex.unlock(io);
    try t.expectError(error.ReferenceCountOverflow, overflow);
    try t.expectEqual(@as(u32, 0), candidates);
    var job: FinishJob = .{ .r = r, .cell = cell };
    var publisher = try io.concurrent(FinishJob.run, .{ io, &job });
    gate.entered.waitUncancelable(io);
    owner.mutex.lockUncancelable(io);
    const candidate = (try r.retainOwnerCandidate(io, owner.identity)).?;
    const detach = r.beginOwnerDetach(io, candidate);
    owner.mutex.unlock(io);
    gate.resume_event.set(io);
    try publisher.await(io);
    try t.expectError(error.ResourceInUse, detach);
    try t.expectEqual(@as(usize, 1), record.delivered);
    try t.expectEqual(@as(usize, 0), record.destroyed);
    try r.release(io, candidate, .candidate);
    try t.expectEqual(@as(usize, 1), record.destroyed);
    try t.expectEqual(@as(u32, 1), owner.finished);
}

test "pair needs no postcommit allocation and request release leaves loss runner live" {
    var source = registry.FutureNamespaceSource.init();
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 4 });
    const r = try registry.CompletionRegistry.create(failing.allocator(), io, &source, .{});
    defer r.close(io) catch unreachable;
    var records = [_]Record{ .{}, .{} };
    const request = try make(r, &records[0], .allow_process_events, true);
    const loss = try make(r, &records[1], .wait_any_only, false);
    var post: PairPost = .{};
    request.context.pair_post = &post;
    const futures = try r.acceptPair(io, pairHeaders(request, loss), PairPost.submit);
    try complete(r, request, 179, false);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 1), records[0].destroyed);
    var infos = [_]api.FutureWaitInfo{.{ .future = futures.loss, .completed = false }};
    try t.expectEqual(api.WaitStatus.timed_out, try r.waitAny(io, &infos, 0));
    try t.expect(!infos[0].completed);
    try t.expectEqual(@as(u32, 1), loss.header.runners);
    try t.expectEqual(@as(usize, 0), records[1].destroyed);
    try complete(r, loss, 181, false);
    try t.expectEqual(@as(usize, 1), records[1].disposed);
    try t.expectEqual(@as(usize, 1), records[1].destroyed);
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
}

const PreparedObserver = struct {
    r: *registry.CompletionRegistry,
    cell: *Cell,
    entered: std.Io.Event = .unset,
    fn run(call_io: std.Io, self: *PreparedObserver) registry.ObserverWaitError!void {
        self.entered.set(call_io);
        try self.r.waitReady(call_io, &self.cell.header);
    }
};

test "pair post failure lets both real prepared observer tasks cancel join and roll back" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var records = [_]Record{ .{}, .{} };
    const request = try make(r, &records[0], .wait_any_only, false);
    const loss = try make(r, &records[1], .wait_any_only, false);
    try r.retain(io, &request.header, .observer);
    try r.retain(io, &loss.header, .observer);
    var observers = [_]PreparedObserver{
        .{ .r = r, .cell = request }, .{ .r = r, .cell = loss },
    };
    var first = try io.concurrent(PreparedObserver.run, .{ io, &observers[0] });
    var second = try io.concurrent(PreparedObserver.run, .{ io, &observers[1] });
    observers[0].entered.waitUncancelable(io);
    observers[1].entered.waitUncancelable(io);
    var post: PairPost = .{ .failure = error.TaskQueueFull };
    request.context.pair_post = &post;
    try t.expectError(error.TaskQueueFull, r.acceptPair(io, pairHeaders(request, loss), PairPost.submit));
    try t.expectError(error.Canceled, first.cancel(io));
    try t.expectError(error.Canceled, second.cancel(io));
    for ([_]*Cell{ request, loss }) |cell| {
        try r.release(io, &cell.header, .observer);
        r.rollback(io, &cell.header);
    }
    try t.expectEqual(@as(u32, 0), r.issued);
    try t.expectEqual(@as(u32, 0), r.waiters);
    for (records) |record| {
        try t.expectEqual(@as(usize, 0), record.delivered);
        try t.expectEqual(@as(usize, 1), record.destroyed);
    }
}

test "pair retarget identity detachment and delivery boundaries leave both bindings unchanged" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var old: OwnerState = .{};
    var replacement: OwnerState = .{ .identity = 72 };
    var records = [_]Record{ .{ .owner = &old }, .{ .owner = &old } };
    const request = try r.prepare(Payload, io, .{ .record = &records[0], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = old.binding() });
    const loss = try r.prepare(Payload, io, .{ .record = &records[1], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = old.binding() });
    var post: PairPost = .{};
    request.context.pair_post = &post;
    const pair = pairHeaders(request, loss);
    _ = try r.acceptPair(io, pair, PairPost.submit);
    old.mutex.lockUncancelable(io);
    replacement.mutex.lockUncancelable(io);
    const wrong_identity = r.retargetPendingPair(io, pair, 73, replacement.binding());
    r.mutex.lockUncancelable(io);
    loss.header.owner_detaching = true;
    r.mutex.unlock(io);
    const detaching = r.retargetPendingPair(io, pair, old.identity, replacement.binding());
    r.mutex.lockUncancelable(io);
    loss.header.owner_detaching = false;
    request.header.delivery = .claimed;
    r.mutex.unlock(io);
    const claimed = r.retargetPendingPair(io, pair, old.identity, replacement.binding());
    r.mutex.lockUncancelable(io);
    request.header.delivery = .unclaimed;
    r.mutex.unlock(io);
    replacement.mutex.unlock(io);
    old.mutex.unlock(io);
    try t.expect(!wrong_identity);
    try t.expect(!detaching);
    try t.expect(!claimed);
    try complete(r, request, 191, false);
    try complete(r, loss, 193, false);
    try r.processEvents(io);
    try t.expectEqual(@as(u32, 2), old.claims);
    try t.expectEqual(@as(u32, 0), replacement.claims);
    try t.expect(records[0].lock_free);
    try t.expect(records[1].lock_free);
}

const IdentityPost = struct {
    entered: std.Io.Event = .unset,
    task: ?std.Io.Future(void) = null,
    committed: bool = false,
    fn submit(header: *registry.Header, call_io: std.Io) registry.AsyncStartError!void {
        const cell: *Cell = @fieldParentPtr("header", header);
        const self = cell.context.identity_post.?;
        self.task = call_io.concurrent(run, .{ call_io, cell }) catch
            return error.ConcurrencyUnavailable;
        self.entered.waitUncancelable(call_io);
    }
    fn run(call_io: std.Io, cell: *Cell) void {
        const self = cell.context.identity_post.?;
        self.entered.set(call_io);
        const r = cell.header.registry;
        r.mutex.lockUncancelable(call_io);
        self.committed = cell.header.future.id != 0 and
            cell.header.owner_identity == cell.header.future.id and
            cell.header.owner.?.identity == cell.header.future.id;
        r.mutex.unlock(call_io);
        if (!self.committed) @panic("worker saw uncommitted loss identity");
        if (!r.beginFinish(call_io, &cell.header)) @panic("identity finisher lost");
        cell.context.terminal = 197;
        r.publish(call_io, &cell.header, false);
        r.release(call_io, &cell.header, .runner) catch @panic("identity runner release");
    }
};

test "identity admission commits Future authority before worker and real owner callback claim" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{ .identity = @as(u64, r.namespace) << 32 };
    var record: Record = .{ .owner = &owner };
    var post: IdentityPost = .{};
    const cell = try r.prepare(Payload, io, .{
        .record = &record,
        .registry = r,
        .identity_post = &post,
    }, ops, .{
        .mode = .allow_spontaneous,
        .callback = true,
        .owner = owner.binding(),
        .callback_class = .device_lost,
    });
    owner.mutex.lockUncancelable(io);
    const future = try r.acceptIdentityFromFuture(io, &cell.header, IdentityPost.submit);
    owner.identity = future.id;
    owner.mutex.unlock(io);
    post.task.?.await(io);
    try t.expect(post.committed);
    try t.expectEqual(@as(u32, 197), record.value);
    try t.expect(record.lock_free);
    try t.expect(record.owner_close_refused);
    try t.expectEqual(@as(u32, 1), owner.claims);
    try t.expectEqual(@as(u32, 1), owner.finished);
    var infos = [_]api.FutureWaitInfo{.{ .future = future, .completed = false }};
    try t.expectEqual(api.WaitStatus.success, try r.waitAny(io, &infos, 0));
}

test "identity admission rejects unbound owner and failed post preserves original binding and ID" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{});
    defer r.close(io) catch unreachable;
    var records = [_]Record{ .{}, .{} };
    const unbound = try make(r, &records[0], .wait_any_only, false);
    try t.expectError(error.InvalidOwner, r.acceptIdentityFromFuture(io, &unbound.header, null));
    r.rollback(io, &unbound.header);
    var owner: OwnerState = .{};
    const bound = try r.prepare(Payload, io, .{ .record = &records[1], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = owner.binding() });
    try t.expectError(error.TaskQueueFull, r.acceptIdentityFromFuture(io, &bound.header, rejectedPost));
    try t.expectEqual(@as(u64, 0), bound.header.future.id);
    try t.expectEqual(owner.identity, bound.header.owner_identity);
    try t.expectEqual(owner.identity, bound.header.owner.?.identity);
    try t.expectEqual(@as(u32, 0), bound.header.runners);
    const future = try r.acceptIdentityFromFuture(io, &bound.header, null);
    try t.expectEqual(@as(u32, 1), @as(u32, @truncate(future.id)));
    try t.expectEqual(future.id, bound.header.owner_identity);
    try t.expectEqual(future.id, bound.header.owner.?.identity);
    owner.identity = future.id;
    try complete(r, bound, 199, false);
    try r.processEvents(io);
    try t.expectEqual(@as(usize, 1), records[1].delivered);
    const ordinary = try r.prepare(Payload, io, .{ .record = &records[0], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = owner.binding() });
    _ = try r.accept(io, &ordinary.header, null);
    try t.expectEqual(owner.identity, ordinary.header.owner_identity);
    try t.expectEqual(owner.identity, ordinary.header.owner.?.identity);
    try complete(r, ordinary, 211, false);
    try r.processEvents(io);
}

test "identity admission capacity sequence references and binding refusal preserve authority" {
    var source = registry.FutureNamespaceSource.init();
    const r = try registry.CompletionRegistry.create(t.allocator, io, &source, .{
        .max_live_operations = 1,
    });
    defer r.close(io) catch unreachable;
    var owner: OwnerState = .{};
    var records = [_]Record{ .{}, .{} };
    const active = try make(r, &records[0], .wait_any_only, false);
    _ = try r.accept(io, &active.header, null);
    const cell = try r.prepare(Payload, io, .{ .record = &records[1], .registry = r }, ops, .{ .mode = .allow_process_events, .callback = true, .owner = owner.binding() });
    try t.expectError(error.AsyncCapacityExceeded, r.acceptIdentityFromFuture(io, &cell.header, null));
    try complete(r, active, 223, false);
    const issued = r.issued;
    r.issued = std.math.maxInt(u32);
    try t.expectError(error.FutureIdExhausted, r.acceptIdentityFromFuture(io, &cell.header, null));
    r.issued = issued;
    cell.header.references = std.math.maxInt(u32);
    try t.expectError(error.ReferenceCountOverflow, r.acceptIdentityFromFuture(io, &cell.header, null));
    cell.header.references = 1;
    cell.header.owner_identity += 1;
    try t.expectError(error.InvalidOwner, r.acceptIdentityFromFuture(io, &cell.header, null));
    cell.header.owner_identity = owner.identity;
    try t.expectEqual(@as(u64, 0), cell.header.future.id);
    try t.expectEqual(owner.identity, cell.header.owner.?.identity);
    const future = try r.acceptIdentityFromFuture(io, &cell.header, null);
    try t.expectEqual(@as(u32, 2), @as(u32, @truncate(future.id)));
    try t.expectEqual(future.id, cell.header.owner_identity);
    owner.identity = future.id;
    try complete(r, cell, 227, false);
    try r.processEvents(io);
    try t.expectEqual(@as(u32, 227), records[1].value);
}
