//! M4 acceptance: a thousand queued tasks all run on pool threads, and every
//! thread joins.
//!
//! **What this test does not claim.** It does not claim a throughput figure. It
//! does not claim that both pool threads ran: `docs/10-architecture.md` fixes the
//! worker count at two, and a scheduler is free to put both on one core, so the
//! test asserts the number of distinct runner threads is at least one and never
//! more than the pool owns.

const std = @import("std");
const dusk = @import("dusk");

const platform = dusk.platform;

/// The task count `docs/40-plan.md` §1 M4 names.
const task_count = 1_000;

/// How long a wait may block before the test calls it a failure.
const wait_timeout_ns: u64 = 60 * std.time.ns_per_s;

/// What one pool task carries. It is not `platform.Task`: that is the pair the
/// pool stores, and this is the test's own state the task reads and writes.
const TaskSlot = struct {
    record: *Record,
    index: usize,
};

const Record = struct {
    /// One entry per task, written by exactly one thread each.
    runner_thread_ids: [task_count]std.Thread.Id,
    completed_count: std.atomic.Value(usize) = .init(0),
};

fn runTask(_: std.Io, context: *anyopaque) void {
    const slot: *TaskSlot = @ptrCast(@alignCast(context));

    slot.record.runner_thread_ids[slot.index] = std.Thread.getCurrentId();
    _ = slot.record.completed_count.fetchAdd(1, .monotonic);
}

test "test-worker-pool" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // SAFETY: `runTask` writes `runner_thread_ids[task.index]` from the task
    // that owns slot `task.index`, and the loop below posts exactly one task
    // per index before it reads the array.
    var record: Record = .{
        .runner_thread_ids = undefined,
        .completed_count = .init(0),
    };

    // Every `WorkerPool` call takes `io` first, so Zig binds none of them as a
    // member function (`src/platform/threads.zig:389`). Each call below names
    // the type to put `io` in the parameter the signature names.
    var pool: platform.WorkerPool = undefined;
    try platform.WorkerPool.init(io, &pool, .{});

    // A test that fails before the shutdown leaves threads with no owner, so the
    // shutdown runs once and on every path.
    var joined = false;
    defer if (!joined) platform.WorkerPool.deinit(io, &pool);

    const submitting_thread_id = std.Thread.getCurrentId();

    var task_slots: [task_count]TaskSlot = undefined;
    for (&task_slots, 0..) |*slot, index| {
        slot.* = .{ .record = &record, .index = index };
        try platform.WorkerPool.postTask(io, &pool, .{ .run = runTask, .context = slot });
    }

    try platform.WorkerPool.waitForAllTasks(io, &pool, wait_timeout_ns);

    try std.testing.expectEqual(@as(usize, task_count), record.completed_count.load(.acquire));

    const counts = platform.WorkerPool.counts(io, &pool);
    try std.testing.expectEqual(@as(usize, task_count), counts.posted_task_count);
    try std.testing.expectEqual(@as(usize, task_count), counts.completed_task_count);

    var runner_thread_ids: [platform.WorkerPool.max_worker_count]std.Thread.Id = undefined;
    var runner_thread_count: usize = 0;
    for (record.runner_thread_ids) |runner_thread_id| {
        try std.testing.expect(runner_thread_id != submitting_thread_id);

        var known = false;
        for (runner_thread_ids[0..runner_thread_count]) |known_thread_id| {
            if (known_thread_id == runner_thread_id) {
                known = true;
                break;
            }
        }
        if (known) continue;

        try std.testing.expect(runner_thread_count < runner_thread_ids.len);
        runner_thread_ids[runner_thread_count] = runner_thread_id;
        runner_thread_count += 1;
    }

    try std.testing.expect(runner_thread_count >= 1);
    try std.testing.expect(runner_thread_count <= platform.WorkerPool.max_worker_count);

    // `join` returns once every `std.Thread` it started has been joined. Posting
    // after it is the observable proof that the pool took its shutdown flag.
    platform.WorkerPool.deinit(io, &pool);
    joined = true;

    try std.testing.expectError(
        error.PoolShutDown,
        platform.WorkerPool.postTask(io, &pool, .{ .run = runTask, .context = &task_slots[0] }),
    );
}

const ShutdownTask = struct {
    runs: usize = 0,

    fn run(_: std.Io, context: *anyopaque) void {
        const task: *ShutdownTask = @ptrCast(@alignCast(context));
        task.runs += 1;
    }
};

const ShutdownBlocker = struct {
    started: platform.CompletionEvent = .{},
    release: platform.CompletionEvent = .{},
    runs: usize = 0,

    fn run(io: std.Io, context: *anyopaque) void {
        const blocker: *ShutdownBlocker = @ptrCast(@alignCast(context));
        blocker.runs += 1;
        platform.CompletionEvent.signal(io, &blocker.started);
        platform.CompletionEvent.wait(io, &blocker.release) catch
            @panic("shutdown blocker wait canceled");
    }
};

const ShutdownJoiner = struct {
    pool: *platform.WorkerPool,
    started: platform.CompletionEvent = .{},

    fn run(io: std.Io, joiner: *ShutdownJoiner) void {
        platform.CompletionEvent.signal(io, &joiner.started);
        platform.WorkerPool.join(io, joiner.pool);
    }
};

test "worker shutdown drains every accepted borrowed context" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // All contexts outlive both pool shutdown and the joiner thread.
    var blocker: ShutdownBlocker = .{};
    var sentinel: ShutdownTask = .{};
    var probes: [platform.WorkerPool.max_queued_task_count - 1]ShutdownTask =
        @splat(.{});
    var rejected: ShutdownTask = .{};
    var pool: platform.WorkerPool = undefined;
    try platform.WorkerPool.init(io, &pool, .{ .worker_count = 1 });
    var joined = false;
    defer if (!joined) platform.WorkerPool.deinit(io, &pool);
    defer platform.CompletionEvent.signal(io, &blocker.release);

    try platform.WorkerPool.postTask(io, &pool, .{
        .run = ShutdownBlocker.run,
        .context = &blocker,
    });
    try platform.CompletionEvent.waitTimeout(io, &blocker.started, wait_timeout_ns);
    try platform.WorkerPool.postTask(io, &pool, .{
        .run = ShutdownTask.run,
        .context = &sentinel,
    });

    var joiner: ShutdownJoiner = .{ .pool = &pool };
    const joiner_thread = try std.Thread.spawn(.{}, ShutdownJoiner.run, .{ io, &joiner });
    defer if (!joined) {
        platform.CompletionEvent.signal(io, &blocker.release);
        joiner_thread.join();
        joined = true;
    };
    try platform.CompletionEvent.waitTimeout(io, &joiner.started, wait_timeout_ns);

    // A started joiner does not prove shutdown took the pool lock. Only a
    // rejected post proves that; keep every accepted probe in a stable slot.
    // A full queue is retried within the bound, never treated as shutdown.
    var accepted_probe_count: usize = 0;
    var saw_shutdown = false;
    const max_post_probes = 1 << 24;
    for (0..max_post_probes) |_| {
        const context = if (accepted_probe_count < probes.len)
            &probes[accepted_probe_count]
        else
            &rejected;
        platform.WorkerPool.postTask(io, &pool, .{
            .run = ShutdownTask.run,
            .context = context,
        }) catch |err| {
            switch (err) {
                error.PoolShutDown => {
                    saw_shutdown = true;
                    break;
                },
                error.TaskQueueFull => {},
                else => return err,
            }
            std.atomic.spinLoopHint();
            continue;
        };
        // The blocked sole worker leaves room for precisely probes.len tasks.
        std.debug.assert(accepted_probe_count < probes.len);
        accepted_probe_count += 1;
    }

    // Release even on a failed probe assertion, then inspect only after join.
    platform.CompletionEvent.signal(io, &blocker.release);
    joiner_thread.join();
    joined = true;
    try std.testing.expect(saw_shutdown);
    try std.testing.expectEqual(@as(usize, 1), blocker.runs);
    try std.testing.expectEqual(@as(usize, 1), sentinel.runs);
    for (probes[0..accepted_probe_count]) |probe| {
        try std.testing.expectEqual(@as(usize, 1), probe.runs);
    }
    for (probes[accepted_probe_count..]) |probe| {
        try std.testing.expectEqual(@as(usize, 0), probe.runs);
    }
    try std.testing.expectEqual(@as(usize, 0), rejected.runs);

    const counts = platform.WorkerPool.counts(io, &pool);
    try std.testing.expectEqual(2 + accepted_probe_count, counts.posted_task_count);
    try std.testing.expectEqual(counts.posted_task_count, counts.completed_task_count);
    try std.testing.expectError(error.PoolShutDown, platform.WorkerPool.postTask(io, &pool, .{
        .run = ShutdownTask.run,
        .context = &rejected,
    }));
    // Rejection retains caller ownership: the caller may still run its context.
    try std.testing.expectEqual(@as(usize, 0), rejected.runs);
    ShutdownTask.run(io, &rejected);
    try std.testing.expectEqual(@as(usize, 1), rejected.runs);
    const after_rejection = platform.WorkerPool.counts(io, &pool);
    try std.testing.expectEqual(counts.posted_task_count, after_rejection.posted_task_count);
    try std.testing.expectEqual(counts.completed_task_count, after_rejection.completed_task_count);
}
