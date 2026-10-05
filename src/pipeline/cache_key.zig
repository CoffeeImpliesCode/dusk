//! The cache key: an append-only byte vector, and the hash that indexes it.
//!
//! **What this file is.** Dawn's `CacheKey` (`src/dawn/native/CacheKey.h:38`)
//! is a `stream::ByteVectorSink`, so the key *is* the accumulated bytes, and
//! `stream::Stream<CacheKey>::Write` (`CacheKey.cpp:33`) flattens a nested key
//! with no length prefix of its own. The port keeps that: one growable buffer,
//! written once, compared by value.
//!
//! **What this file does not claim.** It does not claim Dawn's hash function.
//! `ObjectContentHasher` folds values with `HashCombine`
//! (`src/dawn/common/HashUtils.h:69`) over `std::hash`, and neither the fold nor
//! `std::hash` publishes a seed, so a digest computed here would not equal a
//! digest computed there and claiming it would be false. The property the cache
//! needs is that equal keys agree and unequal keys differ, so the port hashes
//! the whole key once with a fixed-seed Wyhash and compares the bytes for
//! equality. A hash collision costs one extra byte comparison and nothing else.

const std = @import("std");

/// What a key is for. Dawn's `CacheKey::Type`
/// (`src/dawn/native/CacheKey.h:42`) is the leading discriminator every caller
/// streams in, so a render-pipeline key and a compute-pipeline key can never
/// compare equal even when the rest of their bytes agree.
pub const Kind = enum {
    compute_pipeline,
    render_pipeline,
};

/// One cache key: the bytes, and nothing else.
pub const CacheKey = struct {
    bytes: std.ArrayList(u8) = .empty,

    /// Every write can need to grow the buffer, so every write names its
    /// allocator. `AGENTS.md` §2: an allocator is a parameter, never a global.
    pub const AppendError = std.mem.Allocator.Error;

    pub fn init() CacheKey {
        return .{};
    }

    pub fn deinit(self: *CacheKey, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    /// Appends a length-prefixed run of bytes.
    ///
    /// Dawn's `stream::Stream` gives every container a length prefix and every
    /// fundamental a fixed width (`src/dawn/native/stream/Stream.h:353` for the
    /// vector case), which is what stops `["ab", "c"]` and `["a", "bc"]` from
    /// producing the same key. The port does the same: a slice is length-
    /// prefixed, a scalar is a fixed eight bytes.
    pub fn appendBytes(
        self: *CacheKey,
        allocator: std.mem.Allocator,
        data: []const u8,
    ) AppendError!void {
        try self.appendWord(allocator, @intCast(data.len));
        try self.bytes.appendSlice(allocator, data);
    }

    /// Appends one scalar as eight little-endian bytes. Little endian because a
    /// key written on one machine is compared on the same machine, and one
    /// width is what keeps the encoding unambiguous.
    pub fn appendWord(
        self: *CacheKey,
        allocator: std.mem.Allocator,
        value: u64,
    ) AppendError!void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, value, .little);
        try self.bytes.appendSlice(allocator, &buffer);
    }

    /// Appends an enumeration as its ordinal. A table reorder changes the
    /// ordinal and so changes every key that used the member, which is the safe
    /// direction: a stale key misses, it never matches the wrong object.
    ///
    /// The parameter is an enumeration and not `anytype` on purpose. An
    /// optional reaches this as a union, and `@intFromEnum` then reports a
    /// builtin error rather than the rule, so the contract is stated here: a
    /// caller with an absent case encodes the absence as its own word, the
    /// way `buildRenderPipelineKey` encodes an absent blend
    /// (`pipeline.zig:658`-`:663`).
    pub fn appendEnum(
        self: *CacheKey,
        allocator: std.mem.Allocator,
        value: anytype,
    ) AppendError!void {
        if (@typeInfo(@TypeOf(value)) != .@"enum") {
            @compileError("appendEnum takes an enumeration, not a union or an integer");
        }
        try self.appendWord(allocator, @intCast(@intFromEnum(value)));
    }

    /// The leading discriminator. Written first by every key builder so a
    /// compute-pipeline key and a render-pipeline key differ before any state
    /// field is read.
    pub fn appendKind(
        self: *CacheKey,
        allocator: std.mem.Allocator,
        kind: Kind,
    ) AppendError!void {
        try self.appendWord(allocator, @intFromEnum(kind));
    }

    /// The bucket index. Two keys with equal bytes always agree here; two keys
    /// with unequal bytes may agree, which costs one byte comparison.
    pub fn contentHash(self: *const CacheKey) u64 {
        return std.hash.Wyhash.hash(0, self.bytes.items);
    }

    /// The decision. Bytes, not the hash: the hash only chose the bucket.
    pub fn eql(left: *const CacheKey, right: *const CacheKey) bool {
        return std.mem.eql(u8, left.bytes.items, right.bytes.items);
    }

    pub fn byteCount(self: *const CacheKey) usize {
        return self.bytes.items.len;
    }
};

/// The leak check a test's `defer` cannot propagate, the house form from
/// `src/pipeline/cache.zig:460`-`:468`.
///
/// `std.heap.DebugAllocator.deinit` prints every leaked block with the stack
/// trace that allocated it and only then answers `.leak`, so asserting that
/// answer is what turns the report into a failed test. A `defer` has no way to
/// `try` the result, and `AGENTS.md` §2 forbids dropping it.
fn assertNoLeak(state: *std.heap.DebugAllocator(.{})) void {
    std.debug.assert(state.deinit() == .ok);
}

test "a key that separates two runs cannot be written as one run" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    var split = CacheKey.init();
    defer split.deinit(allocator);
    try split.appendBytes(allocator, "ab");
    try split.appendBytes(allocator, "c");

    var joined = CacheKey.init();
    defer joined.deinit(allocator);
    try joined.appendBytes(allocator, "a");
    try joined.appendBytes(allocator, "bc");

    try std.testing.expect(!CacheKey.eql(&split, &joined));
}

test "the same writes produce the same key and the same hash" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    var first = CacheKey.init();
    defer first.deinit(allocator);
    try first.appendKind(allocator, .render_pipeline);
    try first.appendWord(allocator, 7);
    try first.appendBytes(allocator, "triangle");

    var second = CacheKey.init();
    defer second.deinit(allocator);
    try second.appendKind(allocator, .render_pipeline);
    try second.appendWord(allocator, 7);
    try second.appendBytes(allocator, "triangle");

    try std.testing.expectEqual(first.byteCount(), second.byteCount());
    try std.testing.expect(CacheKey.eql(&first, &second));
    try std.testing.expectEqual(first.contentHash(), second.contentHash());
}

test "the kind is the leading discriminator" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    var render = CacheKey.init();
    defer render.deinit(allocator);
    try render.appendKind(allocator, .render_pipeline);
    try render.appendWord(allocator, 1);

    var compute = CacheKey.init();
    defer compute.deinit(allocator);
    try compute.appendKind(allocator, .compute_pipeline);
    try compute.appendWord(allocator, 1);

    // 16 and not 9: `appendKind` writes the kind through `appendWord`
    // (`:99`-`:105`), which appends a fixed eight-byte word (`:65`-`:73`), so
    // the discriminator and the value behind it are two words. This is the
    // only assertion in the file that names a byte count, so it is what stops
    // the word width moving silently: a narrower word aliases every count
    // above 255.
    try std.testing.expectEqual(@as(usize, 16), render.byteCount());
    try std.testing.expect(!CacheKey.eql(&render, &compute));
}
