//! Power-of-two and alignment arithmetic the memory module needs.
//!
//! **What this file is.** The port of the two helpers
//! `src/dawn/common/Math.h` gives the allocator stack:
//! `NextPowerOfTwo` at `Math.h:85` and `IsPowerOfTwo` at `Math.h:53`. Dawn's
//! `Log2` at `Math.h:51-52` has no row here because `@clz` replaces it.
//!
//! **Why these are local and not a dependency.** `Math.h` is M7 — the milestone
//! that lands `Format.h`, `Limits.h` and `Toggles.h` — and it is 309 lines
//! across a `.h` and a `.cpp`. The memory module needs three integer helpers out
//! of it. The standard library covers all three: `@clz` for the log, `std.math.isPowerOfTwo`
//! for the test, and `std.mem.alignForward` for the alignment.
//! `docs/30-port-design.md` §7.1 already routes `Slab` through the same three
//! operations, so when M7 lands this file and that section's copy merge in the
//! same commit and both rows point at `src/math.zig`.

const std = @import("std");

/// Ports `IsPowerOfTwo` (`src/dawn/common/Math.h:53-56`).
///
/// Zero is not a power of two here. Dawn's `Align` (`Math.h:98-101`)
/// release-assumes a non-zero power-of-two alignment, so `offsetAlignment == 0`
/// is undefined behaviour upstream; the port reports it instead.
pub fn isPowerOfTwo(value_byte_count: u64) bool {
    if (value_byte_count == 0) return false;
    return std.math.isPowerOfTwo(value_byte_count);
}

/// The base-2 logarithm of a power of two, as an unsigned 6-bit count.
///
/// Ports `Log2` (`src/dawn/common/Math.h:51-52`), which is `@bitSizeOf(u64) - 1
/// - @clz(value)`. Only correct for a power of two, which is the same condition
/// upstream's is; `levelFromBlockSize` checks it first and returns an error.
pub fn log2PowerOfTwo(value_byte_count: u64) LogError!u6 {
    if (!isPowerOfTwo(value_byte_count)) return error.NotPowerOfTwo;
    return @intCast(@bitSizeOf(u64) - 1 - @clz(value_byte_count));
}

/// `error.NotPowerOfTwo`. Named once so every helper that rejects a
/// non-power-of-two reports the same member.
pub const LogError = error{NotPowerOfTwo};

/// The next power of two at or above `value_byte_count`. Ports
/// `NextPowerOfTwo` (`src/dawn/common/Math.h:85`).
///
/// Dawn's shifts by `Log2(n - 1) + 1` (`Math.cpp:50-56`), so a value past the
/// top of the word is undefined, and `BuddyMemoryAllocator.cpp:67-70` checks
/// the raw size *before* calling it precisely so a huge value cannot reach it.
/// The port returns the error instead, so the order of the two checks is a
/// property of the code rather than a comment.
pub fn nextPowerOfTwo(value_byte_count: u64) OverflowError!u64 {
    return std.math.ceilPowerOfTwo(u64, value_byte_count);
}

/// `error.Overflow`. `std.math.ceilPowerOfTwo` reports a value wider than `u64`.
pub const OverflowError = error{Overflow};

/// `value_byte_count` rounded up to a multiple of `alignment_byte_count`.
///
/// Ports `Align` (`src/dawn/common/Math.h:98-101`). Dawn's release-assumes a
/// non-zero power-of-two alignment; this returns `error.AlignmentNotPowerOfTwo`
/// instead, which is what lets `RingAllocator.allocate` reject the alignment a
/// caller built by dividing a block size rather than naming one.
pub fn alignForwardByteCount(value_byte_count: u64, alignment_byte_count: u64) AlignmentError!u64 {
    if (!isPowerOfTwo(alignment_byte_count)) return error.AlignmentNotPowerOfTwo;
    return std.mem.alignForward(u64, value_byte_count, alignment_byte_count);
}

/// `error.AlignmentNotPowerOfTwo`.
pub const AlignmentError = error{AlignmentNotPowerOfTwo};

comptime {
    // These are the same operations on the same domain, so a disagreement
    // between them is a bug in one of them and not a caller mistake. Zig 0.16
    // compares an error union against one of its members but not against its
    // payload, so a success row unwraps first and a failure row compares
    // against the error value. `catch 0` is a payload no success row below
    // expects, so a call that fails fails its own row with its own message.
    //
    // One block and not a nested one: a container evaluates each `comptime`
    // block once, and sibling blocks share no ordering, so a second block could
    // only repeat a check this one already makes.
    if (isPowerOfTwo(1) != true) @compileError("one is a power of two");
    if (isPowerOfTwo(0) != false) @compileError("zero is not a power of two");
    if (isPowerOfTwo(6) != false) @compileError("six is not a power of two");
    if (log2PowerOfTwo(64) catch 0 != 6) @compileError("log2 of 64 is 6");
    if (nextPowerOfTwo(64) catch 0 != 64) @compileError("64 is already a power of two");
    if (nextPowerOfTwo(65) catch 0 != 128) @compileError("65 rounds up to 128");
    if (alignForwardByteCount(1, 16) catch 0 != 16) @compileError("1 aligns up to 16");
    if (alignForwardByteCount(16, 16) catch 0 != 16) @compileError("16 is already aligned");
    if (log2PowerOfTwo(63) != error.NotPowerOfTwo) {
        @compileError("63 is not a power of two");
    }
    if (alignForwardByteCount(1, 3) != error.AlignmentNotPowerOfTwo) {
        @compileError("3 is not an alignment");
    }
}
