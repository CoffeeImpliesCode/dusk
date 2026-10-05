//! The M10 shard: a 1 MiB buffer, written, copied into a readback buffer, and
//! read back byte for byte, twice.
//!
//! **What the acceptance sentence names, and what it does not.**
//! `docs/40-plan.md` §1 M10 says `test/buffer.zig` "creates a 1 MiB
//! mapped-at-creation buffer, writes a 1,048,576-byte pattern through
//! `writeBuffer`, copies the buffer into a readback buffer with
//! `copyBufferToBuffer`, maps the readback buffer and asserts all 1,048,576
//! bytes equal the pattern. It repeats the write with `mapped_at_creation`
//! false to take the `DynamicUploader` path (`Buffer.cpp:1183`) and asserts the
//! same result."
//!
//! `writeBuffer` cannot be the writer for the mapped-at-creation buffer, and the
//! reason is two rules of this port rather than an accident:
//!
//!   - `validateBufferUsageCombinations` (`src/engine/buffer.zig:359`) lets
//!     `map_write` sit beside `copy_src` and nothing else.
//!   - `validateWriteBuffer` (`src/engine/buffer.zig:1510`) refuses a buffer
//!     with no `copy_dst`, and `validateBufferDescriptor` (`:367`) requires
//!     `map_write` on a buffer mapped at creation.
//!
//! The two usages are therefore mutually exclusive on one buffer, so the
//! mapped-at-creation range is written through `getMappedRange`, which is what
//! sub-path A of `MapAtCreation` (`Buffer.cpp:714`-`:717`) exists for. The first
//! test asserts the refusal above so the writer is named rather than guessed,
//! and the second half of the acceptance — `writeBuffer` with
//! `mapped_at_creation` false, through the upload ring — is exactly the second
//! test.
//!
//! **Both paths are asserted byte for byte.** The first test writes the pattern
//! into the mapped-at-creation range; the second writes the same 1,048,576-byte
//! pattern through `writeBuffer` into a buffer that was not mapped at creation.
//! Each reads its result back through a `map_read | copy_dst` readback buffer
//! and compares every byte against the same pattern, so "the same result" is
//! asserted by two identical assertions rather than by one test comparing two
//! values.
//!
//! **Why the pattern is not a constant fill.** A zeroed or `0xA5`-filled buffer
//! would match a readback of memory nothing ever wrote. `patternByte` mixes the
//! whole index, so a copy that shifted by four bytes, a copy that ran backwards
//! and an allocation that was never written all fail.
//!
//! **What this shard does not claim.** It claims no `DynamicUploader` ring
//! wrap: a reservation is released the moment its copy is recorded, because
//! reclaiming on the serial needs the memory module's reclaim queue
//! (`src/engine/buffer.zig:1710`). It claims no host-mapped import and no texel
//! buffer view; both are M21's rows. It creates no surface, because the host is
//! headless (`AGENTS.md` §5).

const std = @import("std");
const dusk = @import("dusk");

const engine = dusk.engine;
const platform = dusk.platform;

const buffer_mod = engine.buffer;
const queue_mod = engine.queue;
const vulkan_device = engine.vulkan_device;

/// The acceptance's pattern length, as a slice length: 1 MiB, which is
/// 1,048,576 bytes.
const pattern_byte_count: usize = 1024 * 1024;

/// The same number as the `u64` that `BufferDescriptor.size`, the copy size
/// and every `u64` accessor take, so no call site restates it and no test
/// sprinkles a cast.
const pattern_size: u64 = pattern_byte_count;

/// Every teardown refusal one test body has not returned yet.
///
/// `defer` cannot fail in Zig 0.16, so a teardown that can refuse cannot
/// return from the point where it refuses. It records the error here and the
/// body returns it once its own frame has unwound, which keeps every teardown
/// a `defer` and still hands the shard the loader's own words instead of a trap
/// carrying ours. `AGENTS.md` §3.1 makes a missing proc a typed error and
/// forbids the panic, so recording is the shape that leaves both standing.
/// `test/render_pipeline.zig:242-269` is the same shape.
const TeardownErrors = struct {
    first: ?Harness.TeardownError = null,

    /// Records one refusal. The first is the one that matters: a teardown that
    /// already failed left its object in a state a later teardown cannot
    /// describe, so a second report would bury the first.
    fn record(self: *TeardownErrors, err: Harness.TeardownError) void {
        if (self.first == null) self.first = err;
    }

    /// Returns the refusal the teardown recorded, or nothing when every
    /// teardown ran. A body that already returned an error has failed the
    /// shard, so a refusal from the teardown of that body adds no information
    /// and is not reported twice.
    fn report(self: *const TeardownErrors) Harness.TeardownError!void {
        if (self.first) |err| return err;
    }
};

/// Everything a buffer round trip needs: a device, its queue, and the
/// buffer-shaped view of that device `src/engine/buffer.zig` takes.
///
/// The struct is filled in place rather than returned by value because the
/// backend, the device and the queue all hold `*HandleSet`, and a returned copy
/// would leave those three pointing at a frame that is already gone. Every
/// handle a buffer creates is counted in `handles`, and `deinit` asserts the
/// count is back to zero, so a buffer that forgot a destroy is a named kind
/// rather than a silent leak.
const Harness = struct {
    // `init` writes every field below unconditionally, and the tests declare
    // the harness as `var harness: Harness = .{}` because `init` takes a
    // pointer and hands `&self.handles`, `&self.device_mutex` and the queue's
    // context to members that outlive the call. A returned harness would leave
    // those dangling.
    // SAFETY: `init` assigns `threaded` on its first statement, before any
    // read, and `errdefer` tears it down if a later step fails.
    threaded: std.Io.Threaded = undefined,
    handles: vulkan_device.HandleSet = .{},
    device_mutex: platform.DeviceMutex = .{},
    // SAFETY: `init` assigns `backend` before passing `&self.handles` to it,
    // and `deinit` reads it only after `init` returned.
    backend: vulkan_device.Backend = undefined,
    // SAFETY: `init` assigns `adapters` from `discoverPhysicalDevices` before
    // `first()` reads it; `deinit` runs only on the success path.
    adapters: vulkan_device.AdapterList = undefined,
    // SAFETY: `init` assigns `device` from `Device.create` before the queue
    // and buffer device read its fields.
    device: vulkan_device.Device = undefined,
    // SAFETY: `init` assigns `queue` from `Queue.init` before `deinit` reads
    // it, and `deinit` runs only after `init` returned.
    queue: queue_mod.Queue = undefined,
    // SAFETY: `init` assigns `buffers` in the same struct literal that the
    // ring below reads it from.
    buffers: buffer_mod.Device = undefined,
    // SAFETY: `init` assigns `ring` on its last statement; `deinit` reads it
    // first and only on the success path.
    ring: buffer_mod.UploadRing = undefined,

    /// Every way standing a device up can fail. It is the union of the four
    /// calls `init` makes, so a caller reads the whole setup cost from one
    /// declaration.
    const SetupError = buffer_mod.CreateError ||
        vulkan_device.Device.CreateError ||
        vulkan_device.Backend.DiscoverError ||
        queue_mod.Queue.InitError ||
        vulkan_device.ProcError;

    /// Every way standing the harness back down can fail. Four of the six
    /// teardowns reach a dispatch proc, and `AGENTS.md` §3.1 makes a null one
    /// a typed error rather than a panic, so `deinit` reports instead of
    /// returning `void` and a caller has to read the result. The union is the
    /// two proc error sets, plus the buffer module's own: the upload ring
    /// destroys its staging buffer on the way down and that reports
    /// `buffer_mod.Error`, which carries `Rule` and `core.ValidationError` on
    /// top of what `vulkan_device.ProcError` already has. `queue.ProcError`
    /// adds only `DeviceProcTierMissing` to the rest.
    const TeardownError = buffer_mod.Error ||
        vulkan_device.ProcError ||
        queue_mod.ProcError;

    /// The failures a `std.testing` assertion reports, one per assertion the
    /// shard makes: `expect` reports `TestUnexpectedResult` and `expectEqual`
    /// reports `TestExpectedEqual`. They are in `RunError` because a helper
    /// that asserts cannot drop them, and naming them here is better than a
    /// helper that silently stops asserting.
    const AssertionError = error{ TestUnexpectedResult, TestExpectedEqual };

    /// Every way one recorded submission can fail.
    const RunError = buffer_mod.Error ||
        queue_mod.Queue.SubmitError ||
        queue_mod.Queue.WaitError ||
        AssertionError;

    /// `teardowns` takes a refusal from the unwind path below. An `errdefer`
    /// cannot `try` and cannot `return` in Zig 0.16, so a teardown that refuses
    /// while the harness is already unwinding has nowhere to send the error
    /// except the recorder the caller reads after the frame below returns.
    fn init(self: *Harness, teardowns: *TeardownErrors) SetupError!void {
        self.threaded = .init(std.testing.allocator, .{});
        errdefer self.threaded.deinit();

        // One `VkInstance` per ICD in fallback-first order, then the first
        // physical device that reported Vulkan 1.1 or later
        // (`BackendVk.cpp:590`-`:637`).
        self.backend = vulkan_device.Backend.init(std.testing.allocator, .{
            .handles = &self.handles,
        });
        // The backend teardown reaches a global proc, and `AGENTS.md` §3.1
        // makes a null one a typed error. A backend that cannot close leaves a
        // live `VkInstance` behind, so the refusal is recorded rather than
        // discarded: the harness is already unwinding and the caller reads the
        // recorder once its own frame has returned.
        errdefer self.backend.deinit() catch |err| teardowns.record(err);
        self.adapters = try self.backend.discoverPhysicalDevices(.{});
        errdefer self.adapters.deinit();
        const adapter = try self.adapters.first();

        self.device = try vulkan_device.Device.create(std.testing.allocator, .{
            .instance = adapter.instance,
            .physical = &adapter.physical,
            .handles = &self.handles,
        });
        // Same reason as the backend teardown above.
        errdefer self.device.deinit(std.testing.allocator) catch |err| teardowns.record(err);

        self.queue = try queue_mod.Queue.init(.{
            .context = .{
                .allocator = std.testing.allocator,
                .dispatch = self.device.dispatchTable(),
                .vk_device = self.device.vk_device,
                .vk_queue = try self.device.fetchQueue(),
                .queue_family_index = self.device.queue_family_index,
                .memory_properties = self.device.memoryProperties(),
                .handles = &self.handles,
            },
            .device_mutex = &self.device_mutex,
        });
        // Same reason as the backend teardown above.
        errdefer self.queue.deinit() catch |err| teardowns.record(err);

        const limits = self.device.physicalProperties().limits;
        self.buffers = .{
            .allocator = std.testing.allocator,
            .dispatch = self.device.dispatchTable(),
            .vk_device = self.device.vk_device,
            .memory_properties = self.device.memoryProperties(),
            .non_coherent_atom_size = limits.nonCoherentAtomSize,
            // `VkPhysicalDeviceLimits` has no `maxBufferSize`: Vulkan carries
            // the limit in the Maintenance4 properties chain with the
            // Maintenance3 allocation ceiling as the fallback
            // (`PhysicalDeviceVk.cpp:940`-`:945`), and `queryMaxBufferSize`
            // already reads exactly that chain behind the extension gate.
            .max_buffer_size = self.device.maxBufferSize(),
            .handles = &self.handles,
        };
        self.ring = buffer_mod.UploadRing.init(self.buffers, .{});
    }

    /// Tears down in the order the handles were created: the ring's staging
    /// buffer, the queue's pools, then the device.
    ///
    /// It reports rather than returning `void`, because the ring, the queue,
    /// the device and the backend each reach a dispatch proc on the way down
    /// and `AGENTS.md` §3.1 makes a null one a typed error. A refusal is
    /// returned rather than caught here, so the error is never dropped on the
    /// floor; the caller reads it, and a Zig 0.16 `defer` cannot `try`, so each
    /// of the three call sites below catches and re-fails with the error named.
    fn deinit(self: *Harness) TeardownError!void {
        try self.ring.deinit();
        try self.queue.deinit();
        try self.device.deinit(std.testing.allocator);
        self.adapters.deinit();
        try self.backend.deinit();
        // Every buffer, staging buffer, command pool, fence, device and
        // instance the tests above created has to be back by now.
        std.debug.assert(self.handles.isEmpty());
        self.threaded.deinit();
        self.* = undefined;
    }

    /// The recording the next submission's commands go into.
    ///
    /// The serial is the one `submit` will take. `Timeline.submit`
    /// (`src/platform/serial.zig:228`-`:230`) increments the counter and THEN
    /// reads it, the way Dawn's `IncrementLastSubmittedCommandSerial` hands off
    /// `GetLastSubmittedCommandSerial`
    /// (`src/dawn/native/vulkan/QueueVk.cpp:365`-`:366`), so
    /// `Timeline.nextSerial` (`src/platform/serial.zig:246`-`:248`) is exactly
    /// `lastSubmittedSerial() + 1`. A buffer that records a use against this
    /// serial therefore knows which submission has to retire before its memory
    /// may be read.
    fn nextRecording(self: *Harness) buffer_mod.Recording {
        return .{
            .command_buffer = self.queue.commandBuffer(),
            .pending_serial = self.queue.timeline.lastSubmittedSerial() + 1,
        };
    }

    /// Ends the recording, submits it, and waits for the serial it carries.
    ///
    /// The returned serial is what a map may name as completed: the copy that
    /// produced the bytes has retired, so its destination memory is readable.
    fn submitAndWait(
        self: *Harness,
        io: std.Io,
        recording: buffer_mod.Recording,
    ) RunError!platform.Serial {
        const result = try self.queue.submit(.{
            .command_buffers = &.{recording.command_buffer},
        });
        try std.testing.expectEqual(recording.pending_serial, result.serial);
        // `Queue.wait` threads `io` first, so Zig does not treat it as a
        // member function and `self.queue.wait(...)` would bind `io` to the
        // queue. The qualified call is what puts `io` in the parameter the
        // signature names (`src/engine/queue.zig:367`).
        const completed = try queue_mod.Queue.wait(io, &self.queue, .{
            .serial = result.serial,
            .timeout_ns = queue_mod.fence_wait_timeout_ns,
        });
        try std.testing.expect(completed >= result.serial);
        return result.serial;
    }
};

/// The acceptance's pattern: 1,048,576 bytes, none of them equal.
fn makePattern() ![]u8 {
    const bytes = try std.testing.allocator.alloc(u8, pattern_byte_count);
    for (bytes, 0..) |*byte, index| {
        byte.* = patternByte(index);
    }
    return bytes;
}

/// The byte the pattern holds at `index`.
///
/// The value mixes the whole index rather than its low bits, so a copy that
/// shifted by four bytes, a copy that ran backwards, and an allocation nothing
/// ever wrote all read back different. A constant fill would not: it matches a
/// readback of memory the driver never touched.
fn patternByte(index: usize) u8 {
    const wide: u64 = @as(u64, @intCast(index)) *% 0x9E37_79B9_7F4A_7C15;
    return @truncate(wide >> 33);
}

/// The index of the first byte of `actual` that is not the pattern byte at the
/// same index, or the shorter of the two lengths when one runs out first.
///
/// Scanning the whole range is the assertion. A result equal to the pattern
/// length means every one of the 1,048,576 bytes read back equals the byte
/// written at that index; anything smaller names the byte that did not.
fn firstMismatch(actual: []const u8, pattern: []const u8) usize {
    const common = @min(actual.len, pattern.len);
    var index: usize = 0;
    while (index < common) : (index += 1) {
        if (actual[index] != pattern[index]) return index;
    }
    return common;
}

/// The index of the first byte that is not zero, or `bytes.len` when every byte
/// is zero. It is how a shard reads "the clear covered the whole range" without
/// asserting on a value a driver is free to choose.
fn firstNonZero(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != 0) return index;
    }
    return bytes.len;
}

/// Destroys a buffer, recording a refused destroy in `teardowns`.
/// `destroy` releases the mapping, the `VkBuffer`, the `VkDeviceMemory` and
/// then the struct itself, in that order.
///
/// It records because `destroy` releases the `VkBuffer` and the
/// `VkDeviceMemory` through dispatch procs and `AGENTS.md` §3.1 makes a null
/// one a typed error. A Zig 0.16 `defer` cannot `try`, so each of the deferred
/// call sites below records the failure instead of dropping it: a buffer whose
/// teardown refused has leaked a device allocation, and the `handles.isEmpty`
/// assert in `Harness.deinit` would never see the handle.
fn destroyBuffer(subject: *buffer_mod.Buffer, teardowns: *TeardownErrors) void {
    subject.destroy(std.testing.allocator) catch |err| teardowns.record(err);
}

/// Creates the buffer both tests copy out of: a `map_read | copy_dst` readback
/// buffer of exactly the pattern length, which is the only usage combination
/// that can both receive a copy and be mapped for reading
/// (`validateBufferUsageCombinations`, `src/engine/buffer.zig:356`).
fn createReadback(harness: *Harness) buffer_mod.CreateError!*buffer_mod.Buffer {
    return buffer_mod.Buffer.create(std.testing.allocator, harness.buffers, .{
        .label = "M10_readback",
        .usage = .{ .map_read = true, .copy_dst = true },
        .size = pattern_size,
        .mapped_at_creation = false,
    });
}

/// Copies `source` into `readback`, retires the copy, and maps the readback for
/// reading. The map is the last step, so the bytes are already retired by then.
///
/// The map is requested against the completed serial on purpose: `mapAsync`
/// refuses a buffer whose last recorded use is newer than the serial the caller
/// claims to have waited for (`src/engine/buffer.zig:1438`), so a map that
/// ignored the wait could read a buffer the GPU is still writing.
fn readbackThrough(
    harness: *Harness,
    io: std.Io,
    readback: *buffer_mod.Buffer,
    // Mutable because `recordCopyBuffer` transitions the source's usage on
    // the recorded command buffer (`src/engine/buffer.zig:1668`), so the
    // source is written by the call, not only read from.
    source: *buffer_mod.Buffer,
    recording: buffer_mod.Recording,
) Harness.RunError!void {
    try readback.recordCopyBuffer(recording, source, 0, 0, pattern_size);
    // The copy is recorded against the submission that will carry it, not
    // performed: both sides of the copy now wait for that serial before their
    // memory may be read from the host.
    try std.testing.expectEqual(recording.pending_serial, source.getLastUsageSerial());
    try std.testing.expectEqual(recording.pending_serial, readback.getLastUsageSerial());

    const serial = try harness.submitAndWait(io, recording);
    try readback.mapAsync(.{
        .mode = .{ .read = true },
        .completed_serial = serial,
    });
    try std.testing.expectEqual(buffer_mod.State.mapped, readback.getState());
    try std.testing.expectEqual(pattern_size, readback.getMapSize());
}

// ---------------------------------------------------------------------------
// Path A: the buffer is mapped at creation.
// ---------------------------------------------------------------------------

test "buffer: a 1 MiB mapped-at-creation buffer round trips every byte" {
    var harness: Harness = .{};
    var teardowns: TeardownErrors = .{};
    // The body runs in a frame of its own so that every `defer` inside it has
    // fired by the time the refusal it recorded is returned
    // (`test/render_pipeline.zig:319-327` is the same reason).
    try mappedAtCreationRoundTrip(&harness, &teardowns);
    try teardowns.report();
}

/// The body of the first test. The frame of its own is what lets the caller
/// return a teardown refusal: the buffers and the harness below are released by
/// `defer` on the way out, so their refusals are recorded before the caller
/// looks for one.
fn mappedAtCreationRoundTrip(harness: *Harness, teardowns: *TeardownErrors) !void {
    try harness.init(teardowns);
    // `deinit` reaches three dispatch procs, so it reports rather than
    // returning `void`, and the recorder the caller holds is where a refusal
    // goes.
    defer harness.deinit() catch |err| teardowns.record(err);
    const io = harness.threaded.io();

    const pattern = try makePattern();
    defer std.testing.allocator.free(pattern);

    var subject = try buffer_mod.Buffer.create(std.testing.allocator, harness.buffers, .{
        .label = "M10_mapped_at_creation",
        .usage = .{ .map_write = true, .copy_src = true },
        .size = pattern_size,
        .mapped_at_creation = true,
    });
    defer destroyBuffer(subject, teardowns);

    // The state the second test turns off is asserted before anything writes to
    // the buffer, so a later assertion cannot be what made it true.
    try std.testing.expectEqual(buffer_mod.State.mapped_at_creation, subject.getState());
    try std.testing.expectEqual(pattern_size, subject.getSize());
    try std.testing.expectEqual(pattern_size, subject.getAllocatedSize());
    try std.testing.expectEqual(pattern_size, subject.getMapSize());
    try std.testing.expectEqual(@as(u64, 0), subject.getMapOffset());
    try std.testing.expect(subject.getMapMode().write);
    try std.testing.expect(subject.isCpuWritableAtCreation());
    // Sub-path A of `MapAtCreation` (`Buffer.cpp:714`-`:717`): no staging buffer
    // was needed, because the caller's own mapping is writable.
    try std.testing.expect(subject.staging == null);

    // The whole allocated range is zeroed at creation, so a byte the write
    // below misses reads back as a zero rather than as whatever the driver left.
    try std.testing.expectEqual(
        pattern_byte_count,
        firstNonZero(subject.mappedSpan()[0..pattern_byte_count]),
    );

    // `writeBuffer` is refused here, and the refusal is the rule, not an
    // accident: `map_write` may sit beside `copy_src` and nothing else
    // (`src/engine/buffer.zig:359`), `validateWriteBuffer` needs `copy_dst`
    // (`:1510`), and a buffer mapped at creation must carry `map_write`
    // (`:367`). Asserted so the acceptance's writer is named, not guessed.
    try std.testing.expectError(
        buffer_mod.Rule.BufferUsageMissingCopyDst,
        subject.writeBuffer(&harness.ring, harness.nextRecording(), .{ .data = pattern }),
    );

    // Sub-path A's writer: the caller writes the whole allocation directly, and
    // no copy is recorded to get the bytes there.
    @memcpy(try subject.getMappedRange(0, pattern_size), pattern);

    const recording = harness.nextRecording();
    try subject.unmap(recording);
    try std.testing.expectEqual(buffer_mod.State.unmapped, subject.getState());

    var readback = try createReadback(harness);
    defer destroyBuffer(readback, teardowns);
    try readbackThrough(harness, io, readback, subject, recording);

    // The readback buffer is mapped read-only, so this is upstream's
    // `APIGetConstMappedRange` (`Buffer.cpp:873`), not `APIGetMappedRange`
    // (`:869`): the writable accessor refuses a read-only mapping
    // (`Buffer.cpp:1121`).
    const read = try readback.getConstMappedRange(0, pattern_size);
    try std.testing.expectEqual(pattern_byte_count, read.len);
    try std.testing.expectEqual(pattern_byte_count, firstMismatch(read, pattern));

    try readback.unmap(harness.nextRecording());
    try std.testing.expectEqual(buffer_mod.State.unmapped, readback.getState());
}

// ---------------------------------------------------------------------------
// Path B: the same write with mapped_at_creation false.
// ---------------------------------------------------------------------------

test "buffer: the same 1 MiB write without mapped_at_creation goes through the ring" {
    var harness: Harness = .{};
    var teardowns: TeardownErrors = .{};
    // The frame of its own, for the reason the path-A test names.
    try ringUploadRoundTrip(&harness, &teardowns);
    try teardowns.report();
}

/// The body of the second test, which is the first one with the flag the
/// acceptance flips.
fn ringUploadRoundTrip(harness: *Harness, teardowns: *TeardownErrors) !void {
    try harness.init(teardowns);
    // Same reason as the path-A teardown above.
    defer harness.deinit() catch |err| teardowns.record(err);
    const io = harness.threaded.io();

    const pattern = try makePattern();
    defer std.testing.allocator.free(pattern);

    // The one flag the acceptance flips. `copy_dst | copy_src` carries no map
    // usage, so `memoryKindFor` (`src/engine/buffer.zig:460`) asks for no host
    // access and `allocateMemory` takes no mapping.
    var subject = try buffer_mod.Buffer.create(std.testing.allocator, harness.buffers, .{
        .label = "M10_ring_upload",
        .usage = .{ .copy_dst = true, .copy_src = true },
        .size = pattern_size,
        .mapped_at_creation = false,
    });
    defer destroyBuffer(subject, teardowns);

    try std.testing.expectEqual(buffer_mod.State.unmapped, subject.getState());
    try std.testing.expectEqual(pattern_size, subject.getSize());
    // The precondition `uploadData` branches on (`src/engine/buffer.zig:1562`):
    // the destination's own memory is not host visible, so the CPU has no
    // mapping to write into and the ring is the only path left.
    try std.testing.expect(!subject.isCpuWritableAtCreation());
    try std.testing.expectEqual(@as(u64, 0), harness.ring.pendingByteCount());

    const recording = harness.nextRecording();
    try subject.writeBuffer(&harness.ring, recording, .{ .data = pattern });

    // The write was recorded, not performed. The bytes are in the ring and
    // reach the destination through a `vkCmdCopyBuffer` nobody has submitted.
    try std.testing.expectEqual(recording.pending_serial, subject.getLastUsageSerial());
    try std.testing.expectEqual(buffer_mod.State.unmapped, subject.getState());
    // The copy covered the whole buffer, so the lazy clear is finished and no
    // later clear may overwrite what the write delivered
    // (`src/engine/buffer.zig:1144`).
    try std.testing.expect(!subject.needsInitialization());

    // The observables that say the ring carried the bytes: it built its staging
    // buffer, that buffer is a different buffer from the destination, and the
    // reservation was released once the copy that reads it was recorded.
    // The error is the shard's, not the library's: no call above reports it, and
    // it names the one precondition this assertion cannot read any other way.
    const staging = harness.ring.staging orelse
        return error.UploadRingStagingBufferMissing;
    try std.testing.expect(staging.getHandle() != subject.getHandle());
    try std.testing.expect(staging.getUsage().copy_src);
    try std.testing.expectEqual(@as(u64, 0), harness.ring.pendingByteCount());

    var readback = try createReadback(harness);
    defer destroyBuffer(readback, teardowns);
    try readbackThrough(harness, io, readback, subject, recording);

    const read = try readback.getConstMappedRange(0, pattern_size);
    try std.testing.expectEqual(pattern_byte_count, read.len);
    try std.testing.expectEqual(pattern_byte_count, firstMismatch(read, pattern));

    try readback.unmap(harness.nextRecording());
    try std.testing.expectEqual(buffer_mod.State.unmapped, readback.getState());
}

// ---------------------------------------------------------------------------
// The bound that says the write above went through the ring.
// ---------------------------------------------------------------------------

test "buffer: a write larger than the ring is refused and stages nothing" {
    var harness: Harness = .{};
    var teardowns: TeardownErrors = .{};
    // The frame of its own, for the reason the path-A test names.
    try oversizedWriteStagesNothing(&harness, &teardowns);
    try teardowns.report();
}

/// The body of the third test. The frame of its own is what lets the caller
/// return a teardown refusal, for the reason the path-A body names.
fn oversizedWriteStagesNothing(harness: *Harness, teardowns: *TeardownErrors) !void {
    try harness.init(teardowns);
    // Same reason as the path-A teardown above.
    defer harness.deinit() catch |err| teardowns.record(err);

    const pattern = try makePattern();
    defer std.testing.allocator.free(pattern);

    var subject = try buffer_mod.Buffer.create(std.testing.allocator, harness.buffers, .{
        .label = "M10_oversized_upload",
        .usage = .{ .copy_dst = true, .copy_src = true },
        .size = pattern_size,
        .mapped_at_creation = false,
    });
    defer destroyBuffer(subject, teardowns);

    // One byte less than the write, so the acceptance's 1,048,576-byte request
    // is the first one this ring cannot take. Nothing else a buffer write can
    // go through has a size limit, so this bound is what makes the ring the
    // path the test above took rather than a guess.
    var ring = buffer_mod.UploadRing.init(harness.buffers, .{
        .ring_size = pattern_size - 1,
    });
    // `UploadRing.deinit` destroys the staging buffer through dispatch procs
    // and reports, and a Zig 0.16 `defer` cannot `try`, so a refusal is
    // recorded rather than dropped. This ring stages nothing, so the teardown
    // is expected to succeed; a failure means the bound above was wrong.
    defer ring.deinit() catch |err| teardowns.record(err);

    try std.testing.expectError(
        buffer_mod.Rule.UploadRingRequestTooLarge,
        subject.writeBuffer(&ring, harness.nextRecording(), .{ .data = pattern }),
    );

    // `reserve` refuses before it creates the staging buffer
    // (`src/engine/buffer.zig:1761`), so a refused write leaves no allocation
    // and no reservation behind.
    try std.testing.expect(ring.staging == null);
    try std.testing.expectEqual(@as(u64, 0), ring.pendingByteCount());
    // The refusal released the use scope `writeBuffer` opened, so the buffer is
    // still usable and its data is still uninitialized: no copy was recorded.
    try std.testing.expectEqual(buffer_mod.State.unmapped, subject.getState());
    try std.testing.expect(subject.needsInitialization());
    try std.testing.expectEqual(@as(u64, 0), subject.getLastUsageSerial());
}

// ---------------------------------------------------------------------------
// The two closed domains `src/engine/buffer.zig` owns.
// ---------------------------------------------------------------------------

test "buffer: every rule and every state has a name" {
    // The module's own comptime block (`src/engine/buffer.zig:1842`) already
    // makes a member without a name a compile error. This is the runtime half:
    // it sweeps both domains and asserts the names are not empty, so a name that
    // reaches an error message cannot be an empty string.
    const rule_info = @typeInfo(buffer_mod.Rule);
    try std.testing.expect(rule_info.error_set.?.len != 0);
    // `inline for` because both domains are comptime-known and `ruleName` takes
    // its rule by value: folding here is what makes a member with no branch a
    // compile error in this shard too, not only in the module. Reflection hands
    // back each member's name rather than a `Rule` value, so `@field` is what
    // turns a swept member back into the value `ruleName` takes.
    inline for (rule_info.error_set.?) |rule| {
        const member = @field(buffer_mod.Rule, rule.name);
        try std.testing.expect(buffer_mod.ruleName(member).len != 0);
    }

    const states = @typeInfo(buffer_mod.State).@"enum".fields;
    try std.testing.expect(states.len != 0);
    inline for (states) |field| {
        try std.testing.expect(buffer_mod.stateName(@enumFromInt(field.value)).len != 0);
    }

    // The one state `isMappedState` answers for is the pair the acceptance
    // walks through: `mapped_at_creation` on the way in, `mapped` on the way
    // out of the readback.
    try std.testing.expect(buffer_mod.isMappedState(.mapped));
    try std.testing.expect(buffer_mod.isMappedState(.mapped_at_creation));
    try std.testing.expect(!buffer_mod.isMappedState(.unmapped));
}
