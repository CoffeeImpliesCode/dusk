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

fn runTask(context: *anyopaque) void {
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
