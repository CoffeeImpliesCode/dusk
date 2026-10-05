//! M4 acceptance: ten thousand serials complete in increasing serial order under
//! the device mutex.
//!
//! **What this test does not claim.** It does not claim anything about a fence.
//! The timeline is a counter, so the test completes serials directly and reads
//! back the order they drained in.
//! **The counter is one-based for submissions.** `mLastSubmittedSerial` starts
//! at `kBeginningOfGPUTime` (`src/dawn/native/ExecutionQueue.h:193`) and is
//! incremented before it is read (`src/dawn/native/vulkan/QueueVk.cpp:364-367`),
//! so the first submission carries 1. Only a timeline that has submitted
//! nothing reads 0.

const std = @import("std");
const dusk = @import("dusk");

const platform = dusk.platform;

/// The serial count `docs/40-plan.md` §1 M4 names.
const serial_count = 10_000;

/// How many times the test completes the timeline. Dawn's tick drains on every
/// call (`src/dawn/native/vulkan/DeviceVk.cpp:366-383`), so the test drains in
/// chunks instead of once.
const drain_chunk_count = 100;

/// The stride of the submission order. It is coprime with `serial_count`, so
/// multiplying by it visits every serial exactly once, and the queue receives its
/// entries out of serial order without a seed and without a clock.
///
/// The caller adds 1 to land the shuffled serial in the range the timeline
/// hands out. That shifts the permutation without changing it: the residues are
/// still 0 to `serial_count - 1`, each visited once.
const submission_stride = 4093;

/// How long the negative wait may block. Short, because nothing signals it.
const short_timeout_ns: u64 = std.time.ns_per_ms;

test "test-serial-timeline" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var device_mutex: platform.DeviceMutex = .{};
    var timeline: platform.Timeline = .{};

    // The sentinel, and only the sentinel, before the first submit.
    // `kBeginningOfGPUTime` is `ExecutionSerial(0u)`
    // (`src/dawn/native/IntegerTypes.h:133`), and `mLastSubmittedSerial` is
    // initialised to it (`src/dawn/native/ExecutionQueue.h:193`). If the first
    // submit also returned 0, then a read of 0 would mean "nothing submitted
    // yet" or "one submission in flight", and the sentinel would name two states
    // at once. This is the assertion the old zero-based form could not pass.
    try std.testing.expectEqual(@as(platform.Serial, 0), timeline.lastSubmittedSerial());

    // Ten thousand serials, taken in order, handed to the queue out of order.
    var queue: platform.SerialQueue(platform.Serial) = .{};
    defer queue.deinit(std.testing.allocator);

    var submit_index: usize = 0;
    while (submit_index < serial_count) : (submit_index += 1) {
        const submitted_serial = timeline.submit();
        // Dawn increments, THEN reads. `IncrementLastSubmittedCommandSerial` is a
        // `fetch_add(1, release)` that returns `void`, so the pre-increment value
        // is discarded (`src/dawn/native/ExecutionQueue.cpp:380-382`), and the
        // fence is tagged from a read taken after it
        // (`src/dawn/native/vulkan/QueueVk.cpp:364-367`). The first submission
        // therefore carries 1, never the 0 the counter held before it.
        const expected_serial: platform.Serial = @intCast(submit_index + 1);
        try std.testing.expectEqual(expected_serial, submitted_serial);

        const shuffled_serial: platform.Serial = @intCast(
            (submit_index * submission_stride) % serial_count + 1,
        );
        try queue.enqueue(std.testing.allocator, .{
            .serial = shuffled_serial,
            .value = shuffled_serial,
        });
    }

    const last_serial = timeline.lastSubmittedSerial();
    // A raw acquire load, with no subtraction and no clamp
    // (`src/dawn/native/ExecutionQueue.cpp:67-69`), so `serial_count` submits
    // leave the counter at `serial_count`.
    try std.testing.expectEqual(@as(platform.Serial, serial_count), last_serial);
    try std.testing.expectEqual(serial_count, queue.count());

    var completion_log: std.ArrayList(platform.SerialQueue(platform.Serial).Entry) = .empty;
    defer completion_log.deinit(std.testing.allocator);

    // Complete under the device mutex, in chunks, the way the tick does.
    const chunk_serial_count = serial_count / drain_chunk_count;
    var chunk_index: usize = 0;
    while (chunk_index < drain_chunk_count) : (chunk_index += 1) {
        const chunk_last_serial: platform.Serial = @intCast(
            @min((chunk_index + 1) * chunk_serial_count, serial_count),
        );
        try platform.Timeline.updateCompletedTo(
            io,
            &device_mutex,
            &timeline,
            chunk_last_serial,
        );
        try queue.drainUpToInSerialOrder(std.testing.allocator, chunk_last_serial, &completion_log);
    }

    // Serials 1 to `serial_count` were enqueued, so the queue can only be empty
    // once the last chunk completed and drained the last SUBMITTED serial.
    // Cap that chunk one lower and the final submission stays queued, and the
    // emptiness below fails on a stale entry instead of on a real drain.
    try std.testing.expectEqual(serial_count, completion_log.items.len);
    try std.testing.expect(queue.isEmpty());

    // The completion order is the serial order, whatever order they arrived in.
    // Serials run 1 to `serial_count`, so index 0 holds serial 1.
    for (completion_log.items, 0..) |entry, index| {
        try std.testing.expectEqual(@as(platform.Serial, @intCast(index + 1)), entry.serial);
        try std.testing.expectEqual(entry.serial, entry.value);
    }

    try std.testing.expectEqual(last_serial, platform.Timeline.completedSerial(io, &timeline));

    // A serial below the completed one moves nothing. Dawn ignores a fence report
    // for work the timeline has already passed.
    try platform.Timeline.updateCompletedTo(io, &device_mutex, &timeline, 0);
    try std.testing.expectEqual(last_serial, platform.Timeline.completedSerial(io, &timeline));

    // The negative space: a wait for a serial nothing will reach times out, and a
    // wait for one that is already reached returns at once.
    var beyond_last: platform.Timeline = .{};
    try std.testing.expectError(
        error.TimedOut,
        platform.Timeline.waitCompletedTo(io, &beyond_last, 1, short_timeout_ns),
    );
    try platform.Timeline.updateCompletedTo(io, &device_mutex, &beyond_last, 1);
    try platform.Timeline.waitCompletedTo(io, &beyond_last, 1, short_timeout_ns);

    // The monotonic queue rejects a serial below the last one. Dawn checks the
    // same condition only in a release build, at
    // `src/dawn/common/SerialQueue.h:69`. The port returns the error.
    var monotonic: platform.SerialQueue(usize) = .{};
    defer monotonic.deinit(std.testing.allocator);

    try monotonic.enqueueMonotonic(std.testing.allocator, .{ .serial = 4, .value = 40 });
    try std.testing.expectError(
        error.SerialOrderViolation,
        monotonic.enqueueMonotonic(std.testing.allocator, .{ .serial = 3, .value = 30 }),
    );
    try monotonic.enqueueMonotonic(std.testing.allocator, .{ .serial = 4, .value = 41 });

    var monotonic_log: std.ArrayList(platform.SerialQueue(usize).Entry) = .empty;
    defer monotonic_log.deinit(std.testing.allocator);

    try monotonic.drainUpToInSubmissionOrder(std.testing.allocator, 4, &monotonic_log);
    try std.testing.expectEqual(@as(usize, 2), monotonic_log.items.len);
    try std.testing.expectEqual(@as(usize, 40), monotonic_log.items[0].value);
    try std.testing.expectEqual(@as(usize, 41), monotonic_log.items[1].value);
    try std.testing.expect(monotonic.isEmpty());
}
