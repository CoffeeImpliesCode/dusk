//! The serial timeline: one monotonic counter and the completion order it fixes.
//!
//! **What this file is.** The port of the serial half of `ExecutionQueueBase`
//! (`src/dawn/native/ExecutionQueue.h:73`, `src/dawn/native/ExecutionQueue.cpp`)
//! and of the containers it drains into (`src/dawn/common/SerialStorage.h`,
//! `src/dawn/common/SerialQueue.h`, `src/dawn/common/SerialMap.h`). Dawn
//! revision `32f77c02294310054a660c393feded4bcb3f203c`.
//!
//! **What this file does not claim.** It does not claim the queue back end. Every
//! `SubmitPendingCommandsImpl` (`ExecutionQueue.h:182`),
//! `CheckAndUpdateCompletedSerials` (`:167`) and
//! `ForceEventualFlushOfCommands` (`:115`) is a pure virtual that `QueueVk`
//! answers (`QueueVk.cpp:298`, `:132`, `:163`), and `QueueVk` lands in M9.
//!
//! **`io` is a parameter, not a field.** `docs/30-port-design.md` §7.2 shows the
//! timeline holding its `Io`. The port takes `io` as a parameter of every call
//! that can block, because a test that builds
//! its own `Io` is the only way to drive a wait deterministically.

const std = @import("std");
const threads = @import("threads.zig");

/// A point in the queue's serial order.
///
/// Dawn types it (`src/dawn/native/IntegerTypes.h:131`:
/// `using ExecutionSerial = TypedInteger<struct QueueSerialT, uint64_t>`). The
/// port uses `u64`, as `docs/30-port-design.md` §7.2 says.
pub const Serial = u64;

/// The context `std.sort.insertion` hands to the comparison. It is a named
/// zero-sized struct, not `{}`, because the sort asks for a concrete function
/// type and `{}` is an anonymous struct. The call site passes `NoSortContext{}`
/// and never the type, because the sort declares the parameter
/// `fn (@TypeOf(context), lhs: T, rhs: T) bool`: handing it the type makes
/// `@TypeOf(context)` the type `type`, which is a generic function type and
/// takes no non-generic comparison.
const NoSortContext = struct {};

/// Values that are waiting for their serial to complete.
///
/// Ports `SerialQueue` (`src/dawn/common/SerialQueue.h:56`) over `SerialStorage`
/// (`src/dawn/common/SerialStorage.h:44`) and `SerialMap`
/// (`src/dawn/common/SerialMap.h:57`). Dawn keeps two containers: `SerialQueue`
/// asserts a non-decreasing serial and stores contiguous per-serial vectors
/// (`SerialQueue.h:51-54`), and `SerialMap` keys a `std::map` so its iterator is
/// already in serial order (`SerialMap.h:47-48`). One Zig type with two enqueue
/// checks and two drains covers both, because `docs/30-port-design.md` §7.2
/// already replaces the X-macro that paired them with a comptime table. A second
/// container type would be a second convention.
pub fn SerialQueue(comptime Value: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            serial: Serial,
            value: Value,
        };

        entries: std.ArrayList(Entry) = .empty,

        pub const EnqueueError = std.mem.Allocator.Error || error{
            /// The serial is below the last one enqueued.
            ///
            /// Dawn checks the same condition only in a release build, through
            /// `DAWN_RELEASE_ASSUME` at `SerialQueue.h:69`. The port returns the
            /// error, so a submitter that breaks the order finds out at the call
            /// site instead of quietly corrupting a drain.
            SerialOrderViolation,
        };

        pub fn deinit(queue: *Self, allocator: std.mem.Allocator) void {
            queue.entries.deinit(allocator);
            queue.* = undefined;
        }

        pub fn isEmpty(queue: *const Self) bool {
            return queue.entries.items.len == 0;
        }

        pub fn count(queue: *const Self) usize {
            return queue.entries.items.len;
        }

        pub fn firstSerial(queue: *const Self) ?Serial {
            if (queue.entries.items.len == 0) return null;
            return queue.entries.items[0].serial;
        }

        pub fn lastSerial(queue: *const Self) ?Serial {
            if (queue.entries.items.len == 0) return null;
            return queue.entries.items[queue.entries.items.len - 1].serial;
        }

        /// Accepts any serial. Ports `SerialMap::Enqueue`
        /// (`src/dawn/common/SerialMap.h:70-93`), which has no order
        /// requirement because its storage is keyed by serial.
        pub fn enqueue(
            queue: *Self,
            allocator: std.mem.Allocator,
            entry: Entry,
        ) std.mem.Allocator.Error!void {
            try queue.entries.append(allocator, entry);
        }

        /// Requires a serial at or above every serial already in the queue. Ports
        /// `SerialQueue::Enqueue` (`SerialQueue.h:68-99`), whose four overloads
        /// collapse into one check and one append.
        pub fn enqueueMonotonic(
            queue: *Self,
            allocator: std.mem.Allocator,
            entry: Entry,
        ) EnqueueError!void {
            if (queue.lastSerial()) |last_serial| {
                if (entry.serial < last_serial) return error.SerialOrderViolation;
            }
            try queue.entries.append(allocator, entry);
        }

        /// Takes every entry at or below `serial`, in submission order. Ports
        /// `SerialStorage::IterateUpTo` (`SerialStorage.h:161`) followed by
        /// `SerialStorage::ClearUpTo` (`:171`). It is a prefix scan only because
        /// `enqueueMonotonic` kept the entries ordered.
        pub fn drainUpToInSubmissionOrder(
            queue: *Self,
            allocator: std.mem.Allocator,
            serial: Serial,
            out: *std.ArrayList(Entry),
        ) std.mem.Allocator.Error!void {
            const max_entry_count = queue.entries.items.len;
            var drained_count: usize = 0;
            while (drained_count < max_entry_count and
                queue.entries.items[drained_count].serial <= serial) : (drained_count += 1)
            {}

            try out.appendSlice(allocator, queue.entries.items[0..drained_count]);

            const retained_count = max_entry_count - drained_count;
            std.mem.copyForwards(
                Entry,
                queue.entries.items[0..retained_count],
                queue.entries.items[drained_count..max_entry_count],
            );
            queue.entries.items.len = retained_count;
        }

        /// Takes every entry at or below `serial`, in increasing serial order.
        ///
        /// Ports `SerialMap`'s iterator (`SerialMap.h:52-55`) over a queue that took
        /// its entries in any order. Two entries at one serial keep their
        /// submission order, because the sort is stable, so the result is a total
        /// order and not a set.
        pub fn drainUpToInSerialOrder(
            queue: *Self,
            allocator: std.mem.Allocator,
            serial: Serial,
            out: *std.ArrayList(Entry),
        ) std.mem.Allocator.Error!void {
            const max_entry_count = queue.entries.items.len;
            const tail_index = out.items.len;

            var index: usize = 0;
            while (index < max_entry_count) : (index += 1) {
                if (queue.entries.items[index].serial > serial) continue;
                try out.append(allocator, queue.entries.items[index]);
            }
            std.sort.insertion(
                Entry,
                out.items[tail_index..],
                NoSortContext{},
                lessThanBySerial,
            );

            var retained_count: usize = 0;
            index = 0;
            // The entries at or below `serial` left with `out`, so the queue
            // keeps the ones above it. This is the retention
            // `drainUpToInSubmissionOrder` does over its prefix, and it is what
            // makes the queue empty once the last serial drains.
            while (index < max_entry_count) : (index += 1) {
                if (queue.entries.items[index].serial <= serial) continue;
                queue.entries.items[retained_count] = queue.entries.items[index];
                retained_count += 1;
            }
            queue.entries.items.len = retained_count;
        }

        fn lessThanBySerial(_: NoSortContext, lhs: Entry, rhs: Entry) bool {
            return lhs.serial < rhs.serial;
        }
    };
}

/// One serial timeline.
///
/// Ports the counters in `ExecutionQueueBase`: `mLastSubmittedSerial` and
/// `mCompletedSerial` (`src/dawn/native/ExecutionQueue.h:192-193`), both
/// starting at `kBeginningOfGPUTime`.
pub const Timeline = struct {
    last_submitted: std.atomic.Value(Serial) = .init(beginning_of_gpu_time),

    /// Guarded by `mutex`. Never read without it.
    completed: Serial = beginning_of_gpu_time,

    completed_cond: std.Io.Condition = .init,
    mutex: std.Io.Mutex = .init,

    pub const beginning_of_gpu_time: Serial = 0;

    pub const UpdateError = error{Canceled};

    /// Moves the counter on by one and returns the serial this submission
    /// carries.
    ///
    /// Ports `ExecutionQueueBase::IncrementLastSubmittedCommandSerial`
    /// (`ExecutionQueue.cpp:380-382`), a `fetch_add(1, release)` that returns
    /// `void`, and the `GetLastSubmittedCommandSerial` load Dawn performs after
    /// it at `QueueVk.cpp:365`-`:366`. The port merges the two because it has
    /// the one call site Dawn splits, and because the acquire load is what
    /// pairs with the release store.
    ///
    /// The counter holds the LAST SUBMITTED serial
    /// (`ExecutionQueue.h:189`), so the first submit hands out
    /// `beginning_of_gpu_time + 1` and never `beginning_of_gpu_time` itself.
    /// The sentinel comes from the initial value (`ExecutionQueue.h:193`), not
    /// from a special case here.
    pub fn submit(self: *Timeline) Serial {
        _ = self.last_submitted.fetchAdd(1, .release);
        return self.lastSubmittedSerial();
    }

    /// The serial of the most recent submission. Ports
    /// `ExecutionQueueBase::GetLastSubmittedCommandSerial`
    /// (`ExecutionQueue.cpp:67-69`): a raw acquire load, with no subtraction,
    /// no saturation and no special case. A timeline that has submitted
    /// nothing answers `beginning_of_gpu_time`, which is the value Dawn's
    /// counter holds until the first increment.
    pub fn lastSubmittedSerial(self: *const Timeline) Serial {
        return self.last_submitted.load(.acquire);
    }

    /// The serial the next `submit` will take. Ports
    /// `ExecutionQueueBase::GetPendingCommandSerial`
    /// (`ExecutionQueue.cpp:63-65`), which is one more than the last submitted.
    pub fn nextSerial(self: *const Timeline) Serial {
        return self.last_submitted.load(.acquire) + 1;
    }

    /// Reads the completed serial. The caller must not hold the device mutex,
    /// because this takes the timeline lock itself.
    pub fn completedSerial(io: std.Io, self: *Timeline) Serial {
        self.mutex.lock(io) catch return self.completed;
        defer self.mutex.unlock(io);
        return self.completed;
    }

    /// Moves the completed serial to `serial` and wakes every waiter.
    ///
    /// Ports `ExecutionQueueBase::UpdateCompletedSerialTo`
    /// (`ExecutionQueue.cpp:267-270`) with its body
    /// `UpdateCompletedSerialToInternal` (`:272`).
    ///
    /// It takes `device_mutex` because `docs/30-port-design.md` §9.1 says every
    /// public device entry point does, and because Dawn asserts the same for the
    /// adjacent wait (`ExecutionQueue.cpp:162-163`). The lock is not recursive,
    /// so a caller inside a callback it registered must not already hold it.
    ///
    /// A serial at or below the current one changes nothing. Dawn takes
    /// `std::max` at `ExecutionQueue.cpp:316`, so a fence that reports work the
    /// timeline has already passed moves the serial by zero.
    pub fn updateCompletedTo(
        io: std.Io,
        device_mutex: *threads.DeviceMutex,
        self: *Timeline,
        serial: Serial,
    ) UpdateError!void {
        threads.DeviceMutex.lock(io, device_mutex) catch return error.Canceled;
        defer threads.DeviceMutex.unlock(io, device_mutex);

        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);

        if (serial <= self.completed) return;
        self.completed = serial;
        self.completed_cond.broadcast(io);
    }

    /// Blocks until the completed serial reaches `serial`.
    ///
    /// Ports `ExecutionQueueBase::WaitForQueueSerial` (`ExecutionQueue.cpp:88`).
    ///
    /// It does not take the device mutex: a waiter that held it would stop every
    /// producer that has to reach the fence. Dawn guards this wait with
    /// `mCompletedSerial` alone (`ExecutionQueue.cpp:79`).
    pub fn waitCompletedTo(
        io: std.Io,
        self: *Timeline,
        serial: Serial,
        timeout_ns: u64,
    ) threads.WaitError!void {
        var target: WaitTarget = .{ .timeline = self, .serial = serial };
        return threads.waitUntil(io, .{
            .mutex = &self.mutex,
            .condition = &self.completed_cond,
            .timeout_ns = timeout_ns,
            .context = &target,
            .satisfied_callback = completedReachedCallback,
        });
    }
};

/// The predicate and its argument. `waitUntil` takes one context pointer, and
/// this wait needs both the timeline and the serial it is waiting for.
const WaitTarget = struct {
    timeline: *Timeline,
    serial: Serial,
};

fn completedReachedCallback(context: *anyopaque) bool {
    const target: *WaitTarget = @ptrCast(@alignCast(context));
    return target.timeline.completed >= target.serial;
}
