//! One worker pool, one device mutex, and the waits both of them need.
//!
//! **What this file is.** The port of the three upstream groups that M4 owns:
//! `dawn::Mutex` and `dawn::MutexProtected` with `DeviceGuard`
//! (`src/dawn/common/Mutex.h`, `src/dawn/common/MutexProtected.h`,
//! `src/dawn/native/DeviceGuard.{h,cpp}`), the system-event wait
//! (`src/dawn/native/SystemEvent.{h,cpp}`, `WaitAnySystemEvent.{h,cpp}`,
//! `WaitListEvent.{h,cpp}`), and the thread pool
//! (`src/dawn/platform/WorkerThread.{h,cpp}` with the factory at
//! `src/dawn/platform/DawnPlatform.cpp:90-97`). Dawn revision
//! `32f77c02294310054a660c393feded4bcb3f203c`.
//!
//! **What this file does not claim.** It does not claim the callback task
//! manager. `CallbackTaskManager` (`src/dawn/native/CallbackTaskManager.{h,cpp}`)
//! flushes the device's callback queue, and the device lands in M8.
//!
//! **Threads.** `docs/30-port-design.md` §9.3 records that the port runs shader
//! validation through `io.concurrent` on an `Io` with
//! `concurrent_limit = .limited(2)`. M4 also has to accept the two `Io`
//! implementations that cannot give that: `Io.Threaded.init_single_threaded`
//! (`lib/std/Io/Threaded.zig:1674`) and any consumer that brings its own
//! `Io`. Dawn's pool queues work and hands back a handle the caller joins
//! (`WorkerThread.cpp:131-162`), and the M4 acceptance test asserts that a
//! thousand queued tasks all run on pool threads and that every thread joins.
//! So the pool below owns `std.Thread`, and `io` is threaded into every call
//! that can block.

const std = @import("std");

/// The clock a deadline is measured on.
///
/// `docs/30-port-design.md` §9.4 says no module reaches for a clock and that
/// `Io.Clock` is the one exception. A deadline is not logic: it is the timeout
/// a caller already asked for, and the standard library converts it to a wait.
pub const monotonic_clock: std.Io.Clock = .awake;

/// The device-wide lock.
///
/// Ports `DeviceMutex` (`src/dawn/native/DeviceGuard.h:48`), which derives from
/// `RecursiveMutex` (`src/dawn/common/Mutex.h:140`) through `MutexBase::Lock`
/// (`:105`) and `MutexBase::Unlock` (`:121`).
///
/// The port's lock is `std.Io.Mutex`, which is not recursive. Recursion was only
/// there for `HandleError` re-entering a call that already holds the lock
/// (`docs/30-port-design.md` §9.1), and the port never holds it across such a
/// call: the tick releases it before it fires callbacks.
pub const DeviceMutex = struct {
    mutex: std.Io.Mutex = .init,

    pub const LockError = error{Canceled};

    /// Takes the lock. Every public device entry point starts here
    /// (`docs/30-port-design.md` §9.1).
    pub fn lock(io: std.Io, mutex: *DeviceMutex) LockError!void {
        mutex.mutex.lock(io) catch return error.Canceled;
    }

    /// Takes the lock if it is free, and reports whether it took it. Ports
    /// `MutexProtectedTraits::TryLock` (`MutexProtected.h:78`).
    pub fn tryLock(mutex: *DeviceMutex) bool {
        return mutex.mutex.tryLock();
    }

    pub fn unlock(io: std.Io, mutex: *DeviceMutex) void {
        mutex.mutex.unlock(io);
    }
};

/// A predicate wait with a caller-supplied deadline.
///
/// Ports `WaitListEvent::WaitAny` (`src/dawn/native/WaitListEvent.h:75`) with
/// its POSIX body, and `WaitAnySystemEvent`
/// (`src/dawn/native/WaitAnySystemEvent.cpp:46`) with its POSIX `poll` body.
/// Dawn blocks on a descriptor; the port blocks on a condition variable, which
/// is what `SystemEvent::GetOrCreateSystemEventReceiver`
/// (`SystemEvent.cpp:158`) builds on POSIX anyway.
///
/// Takes `options.mutex` on entry and releases it before it returns, so a caller
/// that blocks here never holds a device lock while it waits.
pub fn waitUntil(io: std.Io, options: WaitUntilOptions) WaitError!void {
    const deadline_ns = deadlineAfter(io, options.timeout_ns);

    // The timer is a task on the same `io`, so the wait wakes on the caller's
    // deadline without a poll loop. It broadcasts rather than signals, because
    // `CompletionEvent::waitTimeout` and `WorkerPool::waitForAllTasks` share
    // this function and a `signal` from the wrong predicate is the one wake a
    // `Condition` cannot re-issue. A timer that fires before the first wait is a
    // lost broadcast, which costs one turn of the loop.
    var group: std.Io.Group = .init;
    group.async(io, broadcastAtDeadline, .{ io, options.condition, deadline_ns });

    options.mutex.lock(io) catch {
        group.cancel(io);
        return error.Canceled;
    };

    var failure: ?WaitError = null;
    while (failure == null and !options.satisfied_callback(options.context)) {
        if (deadlinePassed(io, deadline_ns)) {
            failure = error.TimedOut;
            break;
        }
        options.condition.wait(io, options.mutex) catch |cancel_err| {
            failure = cancel_err;
            break;
        };
    }

    // The timer is canceled with the lock released. It sleeps on the `io`, and a
    // caller that returns late must not hold a device lock while the `io` unwinds
    // it.
    options.mutex.unlock(io);
    group.cancel(io);
    return failure orelse {};
}

pub const WaitUntilOptions = struct {
    /// Guards the state `satisfied_callback` reads. `waitUntil` takes it on
    /// entry and releases it on exit.
    mutex: *std.Io.Mutex,

    /// Woken by whoever changes the state. The caller must broadcast it.
    condition: *std.Io.Condition,

    /// Nanoseconds from the call. Zero returns as soon as the predicate is false
    /// and the deadline is already past.
    timeout_ns: u64,

    /// Passed to `satisfied_callback`.
    context: *anyopaque,

    /// Reads the predicate. It runs with `mutex` held, so the state it reads is
    /// the state the signal guarded.
    satisfied_callback: *const fn (context: *anyopaque) bool,
};

pub const WaitError = error{
    /// The predicate was still false at the deadline. Upstream reports this by
    /// returning false from `WaitAnySystemEvent` (`WaitAnySystemEvent.cpp:60-62`).
    TimedOut,

    /// The `Io` asked the wait to stop.
    Canceled,
};

fn deadlineAfter(io: std.Io, timeout_ns: u64) i96 {
    const now_ns = std.Io.Timestamp.now(io, monotonic_clock).nanoseconds;
    return now_ns + @as(i96, @intCast(timeout_ns));
}

fn deadlinePassed(io: std.Io, deadline_ns: i96) bool {
    return std.Io.Timestamp.now(io, monotonic_clock).nanoseconds >= deadline_ns;
}

fn broadcastAtDeadline(io: std.Io, condition: *std.Io.Condition, deadline_ns: i96) void {
    const now_ns = std.Io.Timestamp.now(io, monotonic_clock).nanoseconds;
    const remaining_ns = @max(deadline_ns - now_ns, 0);
    std.Io.sleep(io, .{ .nanoseconds = remaining_ns }, monotonic_clock) catch return;
    condition.broadcast(io);
}

/// A one-shot signal that a caller can wait on.
///
/// Ports `SystemEvent` (`src/dawn/native/SystemEvent.h:107`) and
/// `AsyncTaskHandleImpl` (`src/dawn/platform/WorkerThread.h:46`). On POSIX,
/// `SystemEvent` is a pipe that `SystemEventPipeSender::Signal`
/// (`SystemEvent.cpp:83-103`) writes one byte into, and
/// `AsyncTaskHandleImpl::Complete` (`WorkerThread.cpp:79-83`) sets an atomic and
/// notifies. A condition variable is both, without a descriptor.
pub const CompletionEvent = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    signaled: bool = false,

    /// Ports `SystemEvent::IsSignaled` (`SystemEvent.cpp:141`) and
    /// `AsyncTaskHandleImpl::IsComplete` (`WorkerThread.cpp:75`). Safe without
    /// the lock, because `signaled` only moves from false to true.
    pub fn isSignaled(event: *const CompletionEvent) bool {
        return event.signaled;
    }

    /// Ports `SystemEvent::Signal` (`SystemEvent.cpp:145`) and
    /// `AsyncTaskHandleImpl::Complete` (`WorkerThread.cpp:79`).
    ///
    /// Dawn signals once, guarded by `mSignaled.exchange`. The port holds the
    /// lock across the test and the store, so a waiter cannot see the wake before
    /// the state that justifies it.
    pub fn signal(io: std.Io, event: *CompletionEvent) void {
        // The lock is taken uncancelable. An event that cannot be signaled is a
        // wait that never ends, so a canceled `Io` must not stop the signal.
        event.mutex.lockUncancelable(io);
        defer event.mutex.unlock(io);
        event.signaled = true;
        event.condition.broadcast(io);
    }

    /// Blocks until the event is signaled. Ports
    /// `AsyncTaskHandleImpl::Wait` (`WorkerThread.cpp:71`) without a deadline.
    pub fn wait(io: std.Io, event: *CompletionEvent) WaitError!void {
        event.mutex.lock(io) catch return error.Canceled;
        defer event.mutex.unlock(io);
        while (!event.signaled) {
            event.condition.wait(io, &event.mutex) catch return error.Canceled;
        }
    }

    /// Blocks until the event is signaled or `timeout_ns` has passed.
    pub fn waitTimeout(io: std.Io, event: *CompletionEvent, timeout_ns: u64) WaitError!void {
        return waitUntil(io, .{
            .mutex = &event.mutex,
            .condition = &event.condition,
            .timeout_ns = timeout_ns,
            .context = event,
            .satisfied_callback = isSignaledCallback,
        });
    }
};

fn isSignaledCallback(context: *anyopaque) bool {
    const event: *CompletionEvent = @ptrCast(@alignCast(context));
    return event.signaled;
}

/// What `waitAny` observed.
pub const WaitAnyResult = union(enum) {
    /// The index in `WaitAnyOptions.events` of a signaled event. When more than
    /// one is signaled, the lowest index wins. Dawn's `WaitListEvent::WaitAny`
    /// sorts the events by address to take its locks in one order and then sets
    /// `isReady` on every event it finds signaled
    /// (`src/dawn/native/WaitListEvent.h:104-106`, `:136-141`), so it names no
    /// index and the lowest-wins rule is this port's own.
    ready: usize,

    /// No event was signaled before the deadline.
    timed_out: void,

    /// The `Io` asked the wait to stop, or it canceled a task that had already
    /// been woken.
    canceled: void,
};

pub const WaitAnyOptions = struct {
    events: []const *CompletionEvent,
    timeout_ns: u64,
};

/// Waits until one of `options.events` is signaled, or the deadline passes.
///
/// The outcome buffer is on the stack, so the caller owns that cost, and a
/// stack array's length has to be comptime-known. The caller's own bound on
/// the event count is therefore a parameter rather than
/// `options.events.len`. Dawn's `WaitAnySystemEvent` takes a `Span` of the
/// same shape (`WaitAnySystemEvent.h:66`) and caps it at
/// `MAXIMUM_WAIT_OBJECTS` (`WaitAnySystemEvent.cpp:57`); the port's wait costs
/// a task and not a handle, so it carries no cap of Dawn's, and a caller that
/// declares a `capacity` below its event count trips the assert instead of
/// overrunning the buffer.
pub fn waitAny(comptime capacity: usize, io: std.Io, options: WaitAnyOptions) WaitAnyResult {
    std.debug.assert(options.events.len <= capacity);

    const Outcome = union(enum) {
        event_index: ?usize,
        deadline: void,
    };

    var outcomes: [capacity + 1]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, outcomes[0 .. options.events.len + 1]);
    defer select.cancelDiscard(io);

    for (options.events, 0..) |event, event_index| {
        select.async(.event_index, awaitEvent, .{ io, event, event_index });
    }
    select.async(.deadline, awaitDeadline, .{ io, options.timeout_ns });

    const outcome = select.await() catch return .{ .canceled = {} };
    return switch (outcome) {
        .event_index => |event_index| switch (event_index) {
            null => .canceled,
            else => |ready| .{ .ready = ready },
        },
        .deadline => .{ .timed_out = {} },
    };
}

fn awaitEvent(io: std.Io, event: *CompletionEvent, event_index: usize) ?usize {
    event.wait(io) catch return null;
    return event_index;
}

fn awaitDeadline(io: std.Io, timeout_ns: u64) void {
    std.Io.sleep(io, .{ .nanoseconds = @intCast(timeout_ns) }, monotonic_clock) catch return;
}

/// One unit of pool work.
///
/// Ports `PostWorkerTaskCallback` with its `void* userdata`
/// (`src/dawn/platform/WorkerThread.h:94-95`). Dawn passes the pair through
/// `std::function`; the port passes a plain function pointer and a context
/// pointer, so a task costs no allocation.
pub const Task = struct {
    /// Runs on a pool thread with the exact `Io` supplied to `postTask`.
    /// It never runs on the submitting thread or under the pool lock.
    run: *const fn (io: std.Io, context: *anyopaque) void,

    /// Passed to `run`. The submitter owns it and keeps it alive until the task
    /// returns. A successful post borrows it; a failed post does not. `join`
    /// returns only after every accepted task has returned.
    context: *anyopaque,
};

/// Accepted input owns the `Io` value, not its backend state or task context.
const QueuedTask = struct {
    io: std.Io,
    task: Task,
};

/// A fixed set of worker threads and a bounded queue in front of them.
///
/// Ports `AsyncWorkerThreadPool` (`src/dawn/platform/WorkerThread.h:87`) with
/// `AsyncJobHandleImpl` (`:65`), `AsyncWorkerThreadPool::PostWorkerTask`
/// (`WorkerThread.cpp:131`), `PostWorkerJob` (`:164`) and
/// `TaskHandlingJobLoop` (`:171`). The two anonymous-namespace adapters at
/// `WorkerThread.cpp:39` and `:50` have no rows: a `Task` and the handle Dawn
/// hands back are one Zig struct here, so there is nothing left for an adapter
/// to forward.
pub const WorkerPool = struct {
    mutex: std.Io.Mutex = .init,

    /// Workers block here. `postTask` signals it once per task, as Dawn's
    /// `NotifyType::One` does (`WorkerThread.cpp:136`).
    work_available: std.Io.Condition = .init,

    /// Callers of `waitForAllTasks` block here. The worker that empties the
    /// outstanding count broadcasts it.
    all_tasks_completed: std.Io.Condition = .init,

    tasks: [max_queued_task_count]QueuedTask,

    /// Entries live in `tasks` from `next_task_index` forward.
    next_task_index: usize = 0,
    queued_task_count: usize = 0,

    posted_task_count: usize = 0,
    completed_task_count: usize = 0,

    worker_threads: [max_worker_count]std.Thread,
    worker_count: usize,

    shutting_down: bool = false,
    worker_exhausted: bool = false,

    /// `AsyncWorkerThreadPool::kDefaultTaskHandlingJobCount` (`WorkerThread.h:89`).
    pub const default_worker_count = 2;

    /// The pool is a device resource, not a machine resource. Two is Dawn's
    /// default and `docs/10-architecture.md` fixes the count at two.
    pub const max_worker_count = 8;

    /// `max_queued_task_count` names the bound on `tasks`. A full queue is
    /// `error.TaskQueueFull`, not a block and not an allocation.
    pub const max_queued_task_count = 4096;

    /// `max_worker_iteration_count` names the bound on one worker's loop. It is
    /// a runaway guard, not a quota: no honest pool reaches it. A worker that
    /// does sets `worker_exhausted`, and `postTask` then returns
    /// `error.WorkerExhausted`. Workers drain the accepted queue before exiting,
    /// with at most `max_queued_task_count` additional iterations each.
    pub const max_worker_iteration_count = 1 << 24;

    pub const InitOptions = struct {
        worker_count: usize = default_worker_count,
    };

    pub const InitError = error{
        /// `worker_count` was zero or above `max_worker_count`.
        InvalidWorkerCount,
        /// The operating system refused a thread.
        WorkerSpawnFailed,
    };

    pub const PostError = error{
        /// `join` has run. A shut-down pool takes no more work.
        PoolShutDown,

        /// `tasks` is full. The bound is `max_queued_task_count`.
        TaskQueueFull,

        /// A worker hit `max_worker_iteration_count`.
        WorkerExhausted,

        /// The `Io` asked the post to stop.
        Canceled,
    };

    /// Starts `options.worker_count` threads with `io` for worker synchronization.
    /// Its backend state must remain valid until `join` returns.
    pub fn init(io: std.Io, pool: *WorkerPool, options: InitOptions) InitError!void {
        if (options.worker_count == 0 or options.worker_count > max_worker_count) {
            return error.InvalidWorkerCount;
        }

        pool.* = .{
            // SAFETY: a slot is read by a worker only after `postTask`
            // wrote it under the lock, and `queued_task_count` is what
            // bounds that read. The array is never read whole.
            .tasks = undefined,
            // SAFETY: only the `worker_count` entries `init` spawns below
            // are read, and only after the spawn wrote them. `join` walks
            // the same `worker_count` prefix.
            .worker_threads = undefined,
            .worker_count = options.worker_count,
        };

        var started_count: usize = 0;
        errdefer {
            pool.shutting_down = true;
            pool.work_available.broadcast(io);
            while (started_count > 0) {
                started_count -= 1;
                pool.worker_threads[started_count].join();
            }
        }
        while (started_count < pool.worker_count) : (started_count += 1) {
            pool.worker_threads[started_count] = std.Thread.spawn(
                .{},
                runWorker,
                .{ io, pool },
            ) catch return error.WorkerSpawnFailed;
        }
    }

    /// Stops accepting tasks, drains accepted work, and joins every thread.
    /// Ports `AsyncWorkerThreadPool::~AsyncWorkerThreadPool`
    /// (`WorkerThread.cpp:119-129`), with drain rather than job cancellation
    /// because task contexts are borrowed and have no cancellation disposer.
    pub fn deinit(io: std.Io, pool: *WorkerPool) void {
        WorkerPool.join(io, pool);
    }

    /// Stops accepting tasks, drains accepted work, and joins every thread.
    /// Ports `AsyncJobHandleImpl::Cancel` (`WorkerThread.cpp:94`) and
    /// `AsyncJobHandleImpl::Join` (`:98`) for all workers at once.
    ///
    /// Every accepted task has returned when this returns. Contexts remain
    /// caller-owned; shutdown neither frees them nor abandons queued tasks.
    /// Synchronization is uncancelable so canceled `Io` cannot prevent this
    /// guarantee or leave a thread running with no owner.
    pub fn join(io: std.Io, pool: *WorkerPool) void {
        pool.mutex.lockUncancelable(io);
        pool.shutting_down = true;
        pool.work_available.broadcast(io);
        pool.all_tasks_completed.broadcast(io);
        pool.mutex.unlock(io);

        const worker_count = pool.worker_count;
        var joined_count: usize = 0;
        while (joined_count < worker_count) : (joined_count += 1) {
            pool.worker_threads[joined_count].join();
        }
    }

    /// Queues `task`. Ports `AsyncWorkerThreadPool::PostWorkerTask`
    /// (`WorkerThread.cpp:131-162`).
    /// Acceptance copies `io` into the queue and borrows `task.context`.
    /// Keep its backend state and context alive until `task.run` returns.
    /// Failure creates neither borrow and leaves both task counters unchanged.
    pub fn postTask(io: std.Io, pool: *WorkerPool, task: Task) PostError!void {
        pool.mutex.lock(io) catch return error.Canceled;
        defer pool.mutex.unlock(io);

        if (pool.shutting_down) return error.PoolShutDown;
        if (pool.worker_exhausted) return error.WorkerExhausted;
        if (pool.queued_task_count == max_queued_task_count) return error.TaskQueueFull;

        const write_index = (pool.next_task_index + pool.queued_task_count) % max_queued_task_count;
        pool.tasks[write_index] = .{ .io = io, .task = task };
        pool.queued_task_count += 1;
        pool.posted_task_count += 1;
        pool.work_available.signal(io);
    }

    /// Blocks until every posted task has run. Ports
    /// `AsyncTaskHandleImpl::Wait` (`WorkerThread.cpp:71`) for the whole pool.
    pub fn waitForAllTasks(io: std.Io, pool: *WorkerPool, timeout_ns: u64) WaitError!void {
        return waitUntil(io, .{
            .mutex = &pool.mutex,
            .condition = &pool.all_tasks_completed,
            .timeout_ns = timeout_ns,
            .context = pool,
            .satisfied_callback = allTasksCompletedCallback,
        });
    }

    /// Reads the counters under the lock, so a caller can report progress
    /// without waiting.
    pub fn counts(io: std.Io, pool: *WorkerPool) Counts {
        pool.mutex.lock(io) catch return .{
            .posted_task_count = pool.posted_task_count,
            .completed_task_count = pool.completed_task_count,
        };
        defer pool.mutex.unlock(io);
        return .{
            .posted_task_count = pool.posted_task_count,
            .completed_task_count = pool.completed_task_count,
        };
    }

    pub const Counts = struct {
        posted_task_count: usize,
        completed_task_count: usize,
    };
};

fn allTasksCompletedCallback(context: *anyopaque) bool {
    const pool: *WorkerPool = @ptrCast(@alignCast(context));
    return pool.completed_task_count == pool.posted_task_count;
}

fn runWorker(worker_synchronization_io: std.Io, pool: *WorkerPool) void {
    // At the normal limit, stop further acceptance before draining the tail.
    // The shared queue then contains at most max_queued_task_count tasks, so
    // that many extra iterations suffice even if this worker drains it alone.
    const max_worker_total_iteration_count =
        WorkerPool.max_worker_iteration_count + WorkerPool.max_queued_task_count;
    var iteration_count: usize = 0;
    while (iteration_count < max_worker_total_iteration_count) : (iteration_count += 1) {
        // Accepted contexts must reach run and completion, even on canceled Io.
        pool.mutex.lockUncancelable(worker_synchronization_io);
        if (iteration_count == WorkerPool.max_worker_iteration_count) {
            pool.worker_exhausted = true;
            pool.all_tasks_completed.broadcast(worker_synchronization_io);
            pool.work_available.broadcast(worker_synchronization_io);
        }

        while (pool.queued_task_count == 0 and !pool.shutting_down and !pool.worker_exhausted) {
            pool.work_available.waitUncancelable(worker_synchronization_io, &pool.mutex);
        }
        // Both terminal flags stop acceptance, not previously accepted work.
        if (pool.queued_task_count == 0) {
            pool.mutex.unlock(worker_synchronization_io);
            return;
        }
        const queued_task = pool.tasks[pool.next_task_index];
        pool.next_task_index = (pool.next_task_index + 1) % WorkerPool.max_queued_task_count;
        pool.queued_task_count -= 1;
        pool.mutex.unlock(worker_synchronization_io);

        queued_task.task.run(queued_task.io, queued_task.task.context);

        pool.mutex.lockUncancelable(worker_synchronization_io);
        pool.completed_task_count += 1;
        if (pool.completed_task_count == pool.posted_task_count) {
            pool.all_tasks_completed.broadcast(worker_synchronization_io);
        }
        pool.mutex.unlock(worker_synchronization_io);
    }
}
