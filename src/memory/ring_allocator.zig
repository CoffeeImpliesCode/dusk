const std = @import("std");
const serial = @import("../platform/serial.zig");

/// Dawn RingBufferAllocator.cpp:59-149, with transactional queue insertion.
/// Owns its queues: keep one owner and pass it by pointer after initialization.
pub const RingAllocator = struct {
    /// Metadata remains bounded even when requests consume no ring bytes.
    pub const max_pending_request_count: usize = 4096;
    const Request = struct {
        end_offset_byte_count: u64,
        consumed_size_byte_count: u64,
        start_offset_byte_count: u64,
        previous_end_offset_byte_count: u64,
        reservation_id: u64,
    };
    const RequestQueue = serial.SerialQueue(Request);

    max_block_size_byte_count: u64 = 0,
    used_size_byte_count: u64 = 0,
    used_start_offset_byte_count: u64 = 0,
    used_end_offset_byte_count: u64 = 0,
    next_reservation_id: u64 = 1,
    inflight: RequestQueue = .{},
    drained: std.ArrayList(RequestQueue.Entry) = .empty,

    pub const AllocateOptions = struct {
        byte_count: u64,
        at_serial: serial.Serial,
        alignment_byte_count: u64 = 1,
    };
    pub const AllocateError = RequestQueue.EnqueueError || error{
        RingBufferFull,
        InvalidAlignment,
        ReservationIdExhausted,
        ReservationLimitExceeded,
    };
    pub const Reservation = struct {
        offset_byte_count: u64,
        reservation_id: u64,
    };
    pub const CancelError = error{ReservationNotLast};

    pub fn init(max_size_byte_count: u64) RingAllocator {
        return .{ .max_block_size_byte_count = max_size_byte_count };
    }

    pub fn deinit(self: *RingAllocator, allocator: std.mem.Allocator) void {
        self.inflight.deinit(allocator);
        self.drained.deinit(allocator);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const RingAllocator) bool {
        return self.inflight.isEmpty();
    }

    pub fn allocate(
        allocator: std.mem.Allocator,
        self: *RingAllocator,
        options: AllocateOptions,
    ) AllocateError!Reservation {
        if (self.inflight.lastSerial()) |last_serial| {
            if (options.at_serial < last_serial) return error.SerialOrderViolation;
        }
        const alignment = options.alignment_byte_count;
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
            return error.InvalidAlignment;
        }
        if (self.next_reservation_id == 0) return error.ReservationIdExhausted;
        if (self.inflight.count() >= max_pending_request_count) {
            return error.ReservationLimitExceeded;
        }
        if (self.used_size_byte_count >= self.max_block_size_byte_count) {
            return error.RingBufferFull;
        }
        const remaining = self.max_block_size_byte_count - self.used_size_byte_count;
        if (options.byte_count > remaining) return error.RingBufferFull;

        // Empty queues have no live address constraints, even at a nonzero cursor.
        // Keep normalization local until enqueue succeeds.
        const was_empty = self.isEmpty();
        const used_start = if (was_empty) 0 else self.used_start_offset_byte_count;
        const used_end = if (was_empty) 0 else self.used_end_offset_byte_count;
        const padding = (0 -% used_end) & (alignment - 1);
        const end_limit = if (used_start <= used_end)
            self.max_block_size_byte_count
        else
            used_start;
        const end_space = end_limit - used_end;
        const placement: struct {
            start_offset_byte_count: u64,
            consumed_size_byte_count: u64,
        } = if (padding <= end_space and options.byte_count <= end_space - padding) .{
            .start_offset_byte_count = used_end + padding,
            .consumed_size_byte_count = padding + options.byte_count,
        } else if (used_start <= used_end and options.byte_count <= used_start) .{
            .start_offset_byte_count = 0,
            .consumed_size_byte_count = (self.max_block_size_byte_count - used_end) +
                options.byte_count,
        } else return error.RingBufferFull;
        std.debug.assert(placement.consumed_size_byte_count <= remaining);
        const end = placement.start_offset_byte_count + options.byte_count;
        try self.inflight.enqueueMonotonic(allocator, .{
            .serial = options.at_serial,
            .value = .{
                .end_offset_byte_count = end,
                .consumed_size_byte_count = placement.consumed_size_byte_count,
                .start_offset_byte_count = placement.start_offset_byte_count,
                .previous_end_offset_byte_count = used_end,
                .reservation_id = self.next_reservation_id,
            },
        });
        if (was_empty) self.used_start_offset_byte_count = 0;
        self.used_end_offset_byte_count = end;
        self.used_size_byte_count += placement.consumed_size_byte_count;
        const reservation: Reservation = .{
            .offset_byte_count = placement.start_offset_byte_count,
            .reservation_id = self.next_reservation_id,
        };
        // Zero denotes exhaustion, so cancellation can never make an ID reusable.
        self.next_reservation_id +%= 1;
        return reservation;
    }

    /// Only the latest reservation can be undone; no completed serial is invented.
    pub fn cancelLast(self: *RingAllocator, reservation: Reservation) CancelError!void {
        const entries = &self.inflight.entries;
        if (entries.items.len == 0) return error.ReservationNotLast;
        const entry = entries.items[entries.items.len - 1];
        if (entry.value.reservation_id != reservation.reservation_id or
            entry.value.start_offset_byte_count != reservation.offset_byte_count)
        {
            return error.ReservationNotLast;
        }
        self.used_end_offset_byte_count = entry.value.previous_end_offset_byte_count;
        self.used_size_byte_count -= entry.value.consumed_size_byte_count;
        entries.items.len -= 1;
        if (self.isEmpty()) {
            self.used_start_offset_byte_count = 0;
            self.used_end_offset_byte_count = 0;
        }
    }

    /// Inclusive FIFO reclamation. Repeated or stale completion values do not rewind state.
    pub fn deallocate(
        allocator: std.mem.Allocator,
        self: *RingAllocator,
        completed_serial: serial.Serial,
    ) std.mem.Allocator.Error!void {
        self.drained.clearRetainingCapacity();
        try self.inflight.drainUpToInSubmissionOrder(
            allocator,
            completed_serial,
            &self.drained,
        );
        for (self.drained.items) |entry| {
            self.used_start_offset_byte_count = entry.value.end_offset_byte_count;
            self.used_size_byte_count -= entry.value.consumed_size_byte_count;
        }
        self.drained.clearRetainingCapacity();
    }
};

test "ring: exact capacity and zero-size queue entries" {
    var ring = RingAllocator.init(7);
    defer ring.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 0, .at_serial = 1 },
    )).offset_byte_count);
    try std.testing.expect(!ring.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), ring.used_size_byte_count);
    try std.testing.expectEqual(@as(u64, 0), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 7, .at_serial = 1 },
    )).offset_byte_count);
    try std.testing.expectError(error.RingBufferFull, RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 1, .at_serial = 2 },
    ));
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), ring.used_size_byte_count);
}

test "ring: padding wrap waste and split-space allocation reclaim FIFO" {
    var ring = RingAllocator.init(16);
    defer ring.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 6, .at_serial = 1 },
    )).offset_byte_count);
    try std.testing.expectEqual(@as(u64, 8), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 5, .at_serial = 2, .alignment_byte_count = 4 },
    )).offset_byte_count);
    try std.testing.expectEqual(@as(u64, 13), ring.used_size_byte_count);
    try RingAllocator.deallocate(std.testing.allocator, &ring, 0);
    try std.testing.expectEqual(@as(u64, 13), ring.used_size_byte_count);
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    try std.testing.expectEqual(@as(u64, 7), ring.used_size_byte_count);
    try std.testing.expectEqual(@as(u64, 0), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 4, .at_serial = 3 },
    )).offset_byte_count);
    try std.testing.expectEqual(@as(u64, 14), ring.used_size_byte_count);
    try std.testing.expectEqual(@as(u64, 4), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 2, .at_serial = 3 },
    )).offset_byte_count);
    try std.testing.expectEqual(@as(u64, 16), ring.used_size_byte_count);
    try std.testing.expectError(error.SerialOrderViolation, RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 0, .at_serial = 2 },
    ));
    try RingAllocator.deallocate(std.testing.allocator, &ring, 2);
    try std.testing.expectEqual(@as(u64, 9), ring.used_size_byte_count);
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    try std.testing.expectEqual(@as(u64, 9), ring.used_size_byte_count);
    try RingAllocator.deallocate(std.testing.allocator, &ring, 3);
    try std.testing.expect(ring.isEmpty());
}

test "ring: overflow before alignment and alignment overflow can wrap" {
    var ring = RingAllocator.init(std.math.maxInt(u64));
    defer ring.deinit(std.testing.allocator);
    const large = std.math.maxInt(u64) - 2;
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = large, .at_serial = 1 });
    try std.testing.expectError(error.RingBufferFull, RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 3, .at_serial = 2, .alignment_byte_count = 8 },
    ));
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    try std.testing.expectEqual(@as(u64, 0), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 1, .at_serial = 2, .alignment_byte_count = 8 },
    )).offset_byte_count);
    try std.testing.expectEqual(@as(u64, 1), ring.used_size_byte_count);
    try std.testing.expectError(error.InvalidAlignment, RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 1, .at_serial = 2, .alignment_byte_count = 3 },
    ));
}

test "ring: alignment overflow wraps only into reclaimed front space" {
    var ring = RingAllocator.init(std.math.maxInt(u64));
    defer ring.deinit(std.testing.allocator);
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 8, .at_serial = 1 });
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{
        .byte_count = std.math.maxInt(u64) - 10,
        .at_serial = 2,
    });
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    const wrapped = try RingAllocator.allocate(std.testing.allocator, &ring, .{
        .byte_count = 1,
        .at_serial = 3,
        .alignment_byte_count = 8,
    });
    try std.testing.expectEqual(@as(u64, 0), wrapped.offset_byte_count);
    try std.testing.expectEqual(std.math.maxInt(u64) - 7, ring.used_size_byte_count);
}

test "ring: failed enqueue and drain leave accounting unchanged" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFailures, .{});
}

fn exerciseFailures(allocator: std.mem.Allocator) !void {
    var ring = RingAllocator.init(128);
    defer ring.deinit(allocator);
    for (0..20) |index| {
        const before_used = ring.used_size_byte_count;
        const before_end = ring.used_end_offset_byte_count;
        const before_count = ring.inflight.count();
        _ = RingAllocator.allocate(allocator, &ring, .{
            .byte_count = 1,
            .at_serial = 1,
            .alignment_byte_count = 4,
        }) catch |err| {
            try std.testing.expectEqual(before_count, ring.inflight.count());
            try std.testing.expectEqual(before_used, ring.used_size_byte_count);
            try std.testing.expectEqual(before_end, ring.used_end_offset_byte_count);
            return err;
        };
        try std.testing.expectEqual(@as(u64, @intCast(index * 4)), before_end +
            ((0 -% before_end) & 3));
    }
    const before_used = ring.used_size_byte_count;
    RingAllocator.deallocate(allocator, &ring, 1) catch |err| {
        try std.testing.expectEqual(@as(usize, 20), ring.inflight.count());
        try std.testing.expectEqual(before_used, ring.used_size_byte_count);
        try std.testing.expectEqual(@as(u64, 0), ring.used_start_offset_byte_count);
        return err;
    };
    try std.testing.expect(ring.isEmpty());
}

test "ring: tail cancellation restores wrap padding and preserves earlier requests" {
    var ring = RingAllocator.init(16);
    defer ring.deinit(std.testing.allocator);
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 6, .at_serial = 1 });
    const earlier = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 7, .at_serial = 2 });
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    const wrapped = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 4, .at_serial = 3 });
    try std.testing.expectError(error.ReservationNotLast, ring.cancelLast(earlier));
    try ring.cancelLast(wrapped);
    try std.testing.expectEqual(@as(u64, 7), ring.used_size_byte_count);
    try std.testing.expectEqual(@as(u64, 13), ring.used_end_offset_byte_count);
    try std.testing.expectEqual(@as(u64, 0), (try RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 4, .at_serial = 3 },
    )).offset_byte_count);
}

test "ring: reclaimed capacity and cancelled empty ring can serve a full request" {
    var ring = RingAllocator.init(16);
    defer ring.deinit(std.testing.allocator);
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 8, .at_serial = 1 });
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    const full = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 16, .at_serial = 2 });
    try std.testing.expectEqual(@as(u64, 0), full.offset_byte_count);
    try ring.cancelLast(full);
    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), ring.used_start_offset_byte_count);
    try std.testing.expectEqual(@as(u64, 0), ring.used_end_offset_byte_count);
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 16, .at_serial = 2 });
}

test "ring: identical offsets and serials cannot cancel a different reservation" {
    var ring = RingAllocator.init(16);
    defer ring.deinit(std.testing.allocator);
    const first = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 0, .at_serial = 1 });
    const second = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 8, .at_serial = 1 });
    try std.testing.expectEqual(first.offset_byte_count, second.offset_byte_count);
    try std.testing.expect(first.reservation_id != second.reservation_id);
    try std.testing.expectError(error.ReservationNotLast, ring.cancelLast(first));
    try std.testing.expectEqual(@as(u64, 8), ring.used_size_byte_count);
    try ring.cancelLast(second);
    try std.testing.expect(!ring.isEmpty());
    try ring.cancelLast(first);
    const replacement = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 8, .at_serial = 1 });
    try std.testing.expectError(error.ReservationNotLast, ring.cancelLast(first));
    try std.testing.expect(replacement.reservation_id > second.reservation_id);
}

test "ring: reservation identity exhaustion cannot modify accounting" {
    var ring = RingAllocator.init(16);
    defer ring.deinit(std.testing.allocator);
    ring.next_reservation_id = std.math.maxInt(u64);
    const last = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 1, .at_serial = 1 });
    try std.testing.expectEqual(std.math.maxInt(u64), last.reservation_id);
    try ring.cancelLast(last);
    try std.testing.expectError(error.ReservationIdExhausted, RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 1, .at_serial = 1 },
    ));
    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), ring.used_size_byte_count);
}

test "ring: empty cursor normalization is not committed when enqueue fails" {
    var ring = RingAllocator.init(16);
    defer ring.deinit(std.testing.allocator);
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 8, .at_serial = 1 });
    try RingAllocator.deallocate(std.testing.allocator, &ring, 1);
    ring.inflight.entries.clearAndFree(std.testing.allocator);
    const previous_id = ring.next_reservation_id;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, RingAllocator.allocate(
        failing.allocator(),
        &ring,
        .{ .byte_count = 16, .at_serial = 2 },
    ));
    try std.testing.expectEqual(@as(u64, 8), ring.used_start_offset_byte_count);
    try std.testing.expectEqual(@as(u64, 8), ring.used_end_offset_byte_count);
    try std.testing.expectEqual(previous_id, ring.next_reservation_id);
    try std.testing.expect(ring.isEmpty());
    const retry = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 16, .at_serial = 2 });
    try std.testing.expectEqual(@as(u64, 0), retry.offset_byte_count);
}

test "ring: zero-byte metadata has a bounded pending request count" {
    var ring = RingAllocator.init(7);
    defer ring.deinit(std.testing.allocator);
    var last: RingAllocator.Reservation = undefined;
    for (0..RingAllocator.max_pending_request_count) |_| {
        last = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 0, .at_serial = 1 });
    }
    const previous_id = ring.next_reservation_id;
    try std.testing.expectError(error.ReservationLimitExceeded, RingAllocator.allocate(
        std.testing.allocator,
        &ring,
        .{ .byte_count = 0, .at_serial = 1 },
    ));
    try std.testing.expectEqual(RingAllocator.max_pending_request_count, ring.inflight.count());
    try std.testing.expectEqual(previous_id, ring.next_reservation_id);
    try std.testing.expectEqual(@as(u64, 0), ring.used_size_byte_count);
    try std.testing.expect(!ring.isEmpty());
    try ring.cancelLast(last);
    _ = try RingAllocator.allocate(std.testing.allocator, &ring, .{ .byte_count = 0, .at_serial = 1 });
}
