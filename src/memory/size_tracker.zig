//! A byte count that is only released when the GPU reaches the serial that used
//! it.
//!
//! **What this file is.** The port of `AllocationSizeTracker`
//! (`src/dawn/native/PooledResourceMemoryAllocator.h:71-88` and
//! `src/dawn/native/PooledResourceMemoryAllocator.cpp:79-104`). It holds a total,
//! a serial-keyed queue of pending decrements, and a mutex. Four instances exist
//! upstream — allocated, used, lazy-allocated and lazy-used, registered as serial
//! processors at `ResourceMemoryAllocatorVk.cpp:164-180` — and the WebGPU limits
//! table and the compatibility profile read all four
//! (`ResourceMemoryAllocatorVk.cpp:365-384`).
//!
//! **Why it stays ours.** VMA has `VmaBudget.usage`, which is an instantaneous
//! driver figure from `VK_EXT_memory_budget` and not a WebGPU-visible byte count
//! frozen at a serial and released when that serial completes.
//!
//! **The increment/decrement asymmetry is the design.** `Increment` adds now;
//! `Decrement` only records the size against a serial
//! (`PooledResourceMemoryAllocator.cpp:84-88`). The subtraction happens when the
//! completed serial passes, so a freed allocation keeps counting until the GPU is
//! past the work that read it. The end state is unchanged — which is what
//! `docs/40-plan.md:297-299` asserts, cycle by cycle.
//!
//! **Two defects are not copied.** `GetSize` (`.h:78`) reads `mTotalSize` with
//! no mutex while every writer takes `mMutex`, which is a data race; this port
//! takes the lock in `getSize` too. And the underflow `DAWN_ASSERT` at
//! `PooledResourceMemoryAllocator.cpp:86`
//! guards the *enqueue*, not the subtraction, so two decrements at two serials
//! can each pass the assert and together exceed the total once both drains run.
//! This port checks both.

const std = @import("std");
const serial = @import("../platform/serial.zig");

const Serial = serial.Serial;
const SerialQueue = serial.SerialQueue(u64);

/// A byte count released by serial.
pub const SizeTracker = struct {
    /// `mMutex` (`PooledResourceMemoryAllocator.h:85`). `std.Io.Mutex` because
    /// that is what `AGENTS.md` §3 and `src/platform/threads.zig:50` use; there
    /// is no non-`Io` mutex in Zig 0.16.
    mutex: std.Io.Mutex = .init,

    /// `mTotalSize` (`PooledResourceMemoryAllocator.h:87`). Guarded by `mutex`
    /// on every read and every write, including `getSize`.
    total_byte_count: u64 = 0,

    /// `mMemoryToDecrement` (`PooledResourceMemoryAllocator.h:86`), a serial
    /// queue of the sizes still to subtract.
    ///
    /// `= .{}` and not `= .empty`: `SerialQueue` declares no `empty`. It is
    /// `std.ArrayList` that has one, at `src/platform/serial.zig:61`'s field
    /// type; the empty queue is the `entries` field default.
    pending: SerialQueue = .{},

    /// Reused across drains so `drainUpToInSubmissionOrder` allocates once in
    /// the life of the tracker rather than once per tick.
    drained: std.ArrayList(SerialQueue.Entry) = .empty,

    /// The lock could not be taken. The device's `Io` was shutting down, which
    /// `src/platform/threads.zig:57` reports the same way.
    pub const LockError = error{Canceled};

    /// The total would go below zero.
    ///
    /// Upstream asserts `mTotalSize >= decrementSize` at
    /// `PooledResourceMemoryAllocator.cpp:86`. The port returns the error at the
    /// enqueue *and* at the subtraction, because either alone misses the two-serial
    /// case named in the header comment.
    pub const Error = error{SizeTrackerUnderflow};

    /// Everything a caller can see.
    pub const OperationError = LockError || Error || std.mem.Allocator.Error ||
        SerialQueue.EnqueueError;

    pub fn init() SizeTracker {
        return .{};
    }

    /// Frees the serial queue and the drain scratch. Both grow only through
    /// `decrement`, so after this the tracker holds nothing.
    pub fn deinit(self: *SizeTracker, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        self.drained.deinit(allocator);
        self.* = undefined;
    }

    /// Adds `byte_count` to the total now. Ports `Increment`
    /// (`PooledResourceMemoryAllocator.cpp:79-82`), including its lock at `:80`.
    pub fn increment(io: std.Io, self: *SizeTracker, byte_count: u64) LockError!void {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        self.total_byte_count += byte_count;
    }

    /// Records `byte_count` against `at_serial` and does **not** subtract it.
    /// Ports `Decrement` (`PooledResourceMemoryAllocator.cpp:84-88`).
    ///
    /// The enqueue-time underflow check is upstream's `:86`. It is kept and it
    /// is not sufficient; `updateCompletedSerialTo` checks again.
    pub fn decrement(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *SizeTracker,
        at_serial: Serial,
        byte_count: u64,
    ) OperationError!void {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);

        if (self.total_byte_count < byte_count) return error.SizeTrackerUnderflow;
        try self.pending.enqueueMonotonic(allocator, .{
            .serial = at_serial,
            .value = byte_count,
        });
    }

    /// Subtracts every decrement at or below `completed_serial` and drops it.
    /// Ports `UpdateCompletedSerialTo` (`PooledResourceMemoryAllocator.cpp:90-96`).
    ///
    /// The drain is inclusive of its serial, which is why
    /// `drainUpToInSubmissionOrder` is the right call: it is a prefix scan over
    /// entries `enqueueMonotonic` kept in serial order.
    pub fn updateCompletedSerialTo(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *SizeTracker,
        completed_serial: Serial,
    ) OperationError!void {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        try self.drainLocked(allocator, completed_serial);
    }

    /// Subtracts every pending decrement and empties the queue. Ports
    /// `AssumeCommandsComplete` (`PooledResourceMemoryAllocator.cpp:98-104`),
    /// which is what device loss reaches through `Device.cpp:946` and
    /// `ExecutionQueue.cpp:376`.
    pub fn assumeCommandsComplete(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *SizeTracker,
    ) OperationError!void {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        try self.drainLocked(allocator, std.math.maxInt(Serial));
    }

    /// The tracked byte count. Ports `GetSize`
    /// (`PooledResourceMemoryAllocator.h:78`), with the lock upstream omits.
    pub fn getSize(io: std.Io, self: *SizeTracker) LockError!u64 {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        return self.total_byte_count;
    }

    /// The number of decrements still waiting for their serial. Not upstream: the
    /// port needs it to assert that a drain emptied the queue rather than
    /// asserting on a byte count alone.
    pub fn pendingCount(io: std.Io, self: *SizeTracker) LockError!usize {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        return self.pending.count();
    }

    /// The body both drains share. The caller holds the lock.
    fn drainLocked(
        self: *SizeTracker,
        allocator: std.mem.Allocator,
        completed_serial: Serial,
    ) OperationError!void {
        self.drained.clearRetainingCapacity();
        try self.pending.drainUpToInSubmissionOrder(allocator, completed_serial, &self.drained);

        // Subtract one entry at a time rather than summing first, so an
        // intermediate state that would go negative is reported against the
        // entry that caused it instead of against the total.
        for (self.drained.items) |entry| {
            if (self.total_byte_count < entry.value) return error.SizeTrackerUnderflow;
            self.total_byte_count -= entry.value;
        }
    }
};

comptime {
    // Four members: `error.Canceled` from the lock,
    // `error.SizeTrackerUnderflow` from the two underflow checks,
    // `error.OutOfMemory` from the injected allocator, and
    // `error.SerialOrderViolation` from
    // `SerialQueue.enqueueMonotonic` (`src/platform/serial.zig:110`).
    // `test/memory.zig` sweeps the set and names each one.
    if (@typeInfo(SizeTracker.OperationError).error_set.?.len != 4) {
        @compileError("a SizeTracker error member is unnamed in src/memory/size_tracker.zig");
    }
}
