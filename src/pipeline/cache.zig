//! The two caches: the in-process object cache that decides "same pipeline or a
//! new one", and the bounded map that decides how many `VkPipelineCache`
//! handles the device keeps, together with the handle itself.
//!
//! **What this file is.** Dawn's `ContentLessObjectCache`
//! (`src/dawn/common/ContentLessObjectCache.h:134`) and its
//! `LRUCache` (`src/dawn/common/LRUCache.h:89`), the two containers the
//! pipeline path reaches, plus the value the second one holds.
//!
//! **What this file does not claim.** It does not claim Dawn's reference
//! counting. Dawn's cache holds a `WeakRef` per entry and erases the entry when
//! the object dies; the port's objects live in the device arena
//! (`src/core/object.zig:395-400`) until `Device.deinit`, so the port holds a
//! plain pointer and removes the entry from the pipeline's own `destroy` hook.
//! That is the same lifetime the caller observes, and it removes the promotion
//! step Dawn needs `mTemporaryRefs` for (`ContentLessObjectCache.h:236-242`).

const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("../vk/dispatch.zig");

const cache_key = @import("cache_key.zig");

pub const CacheKey = cache_key.CacheKey;
pub const Kind = cache_key.Kind;

/// The content-less object cache: what makes two identical descriptors the
/// same object.
///
/// Dawn keys it on the object's `ComputeContentHash()` (`CachedObject.h:62`),
/// cached by `HashFunc` (`ContentLessObjectCache.h:77-85`), and disambiguates
/// with `T::EqualityFunc` (`ContentLessObjectCache.h:87-128`). The port keys on
/// the same bytes the key is built from, so the hash picks the bucket and the
/// byte comparison is the decision — one encoding instead of two that have to
/// agree.
pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        /// One cached object and the key that found it. The key is owned, not
        /// borrowed: the caller's scratch key dies when the call returns, and
        /// the cache still has to answer "is this object still here" for a
        /// later duplicate. `insert` moves the bytes in and leaves the
        /// caller's key empty, so exactly one owner names the buffer.
        pub const Entry = struct {
            key: CacheKey,
            object: *T,
        };

        allocator: std.mem.Allocator,
        buckets: std.AutoHashMapUnmanaged(u64, std.ArrayList(Entry)) = .empty,
        entry_count: usize = 0,

        /// How many entries the map may hold before it stops caching.
        ///
        /// Dawn's container is unbounded, and so is this one. The bound exists
        /// on the `VkPipelineCache` map below, where each entry is a Vulkan
        /// object with a cost; an arena object that the device already owns has
        /// no cost to keep.
        pub const capacity_limit: usize = std.math.maxInt(usize);

        pub const Error = std.mem.Allocator.Error;

        // `find` reads liveness to stand in for Dawn's weak-ref promotion, so
        // a type that does not answer it cannot be cached at all.
        comptime {
            if (!@hasDecl(T, "isAlive")) {
                @compileError("a cached object must answer isAlive");
            }
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var bucket_iterator = self.buckets.valueIterator();
            while (bucket_iterator.next()) |bucket| {
                for (bucket.items) |*entry| entry.key.deinit(self.allocator);
                bucket.deinit(self.allocator);
            }
            self.buckets.deinit(self.allocator);
            self.entry_count = 0;
        }

        /// The object `key` names, or null.
        ///
        /// Dawn's cache holds a `WeakRef` and promotes it
        /// (`ContentLessObjectCache.h:164`), so an object that died cannot be
        /// found. The port's objects live in the arena and leave the map
        /// through nothing, because `destroy` has no `io` to take the lock
        /// with; reading liveness is what replaces the promotion.
        ///
        /// The key is borrowed for the comparison and retained by nothing, so
        /// the caller's `defer key.deinit` stays correct across this call.
        pub fn find(self: *Self, key: *const CacheKey) ?*T {
            const bucket = self.buckets.getPtr(key.contentHash()) orelse return null;
            for (bucket.items) |*entry| {
                if (!entry.object.isAlive()) continue;
                if (CacheKey.eql(&entry.key, key)) return entry.object;
            }
            return null;
        }

        /// Drops every entry whose object the arena has destroyed, and returns
        /// how many it dropped.
        ///
        /// The caller holds the lock. Dawn erases from `Uncache`
        /// (`ContentLessObjectCacheable.h:53-61`), which a cacheable calls
        /// from its `DeleteThis`; the port defers the sweep to the create
        /// call, which is the only place that already holds it.
        ///
        /// The sweep runs from the end downwards because `swapRemove` moves the
        /// last entry into the hole it leaves, and that entry's own test has
        /// already run; ascending would test it twice and free it twice. The
        /// `removed` copy is the one that names the key, because `swapRemove`
        /// took the entry out of the bucket.
        pub fn prune(self: *Self) usize {
            var dropped: usize = 0;
            var bucket_iterator = self.buckets.valueIterator();
            while (bucket_iterator.next()) |bucket| {
                var index = bucket.items.len;
                while (index > 0) {
                    index -= 1;
                    if (bucket.items[index].object.isAlive()) continue;
                    var removed = bucket.swapRemove(index);
                    removed.key.deinit(self.allocator);
                    self.entry_count -= 1;
                    dropped += 1;
                }
            }
            return dropped;
        }

        /// Records `object` under `key`. The key's bytes are moved in, so the
        /// caller keeps nothing alive for the cache.
        ///
        /// `key` is a pointer because a `CacheKey` holds an unmanaged
        /// `std.ArrayList`, and passing it by value copies the struct and
        /// leaves the buffer named twice: the entry would read bytes the
        /// caller's `defer key.deinit` had already freed. This function
        /// therefore empties the caller's key on every path, which makes that
        /// `defer` a no-op whether the call returned an entry or an error.
        /// The reset cannot be left to the deinit, because `CacheKey.deinit`
        /// leaves `bytes` undefined (`cache_key.zig:41`) and a second free
        /// would read it.
        pub fn insert(self: *Self, key: *CacheKey, object: *T) Error!void {
            const hash = key.contentHash();
            const bucket = try self.buckets.getOrPut(self.allocator, hash);
            if (!bucket.found_existing) {
                bucket.value_ptr.* = .empty;
                errdefer {
                    bucket.value_ptr.deinit(self.allocator);
                    _ = self.buckets.remove(hash);
                }
            }
            // A failed append leaves the buffer in the caller's key and in no
            // entry, so it is freed here, once, and the caller's key is left
            // empty by the reset that follows.
            errdefer {
                key.deinit(self.allocator);
                key.bytes = .empty;
            }
            try bucket.value_ptr.append(self.allocator, .{
                .key = .{ .bytes = key.bytes },
                .object = object,
            });
            // The move is done and nothing below can fail, so the caller's key
            // stops naming the buffer the entry now owns.
            key.bytes = .empty;
            self.entry_count += 1;
        }

        /// Drops the entry naming `object`.
        ///
        /// Dawn's `Erase` (`ContentLessObjectCache.h:192`) compares by pointer
        /// only, so it can never remove a different object that compares equal.
        /// The port does the same: identity, never the key.
        pub fn remove(self: *Self, object: *T) void {
            var bucket_iterator = self.buckets.valueIterator();
            while (bucket_iterator.next()) |bucket| {
                for (bucket.items, 0..) |entry, index| {
                    if (entry.object != object) continue;
                    var removed = bucket.orderedRemove(index);
                    removed.key.deinit(self.allocator);
                    self.entry_count -= 1;
                    return;
                }
            }
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.entry_count == 0;
        }

        /// The number of live objects the cache holds. This is the observable
        /// that a duplicate did not become a second object.
        pub fn queryEntryCount(self: *const Self) usize {
            return self.entry_count;
        }

        /// The byte count the cache's keys occupy, for the leak test.
        pub fn queryKeyByteCount(self: *const Self) usize {
            var total: usize = 0;
            var bucket_iterator = self.buckets.valueIterator();
            while (bucket_iterator.next()) |bucket| {
                for (bucket.items) |entry| total += entry.key.byteCount();
            }
            return total;
        }
    };
}

/// A bounded map with least-recently-used eviction. `docs/30-port-design.md`
/// §7.3 fixes this shape: an array of entries, an index from key to slot, and a
/// monotonic clock.
///
/// `Key` is hashed and compared by `KeyContext` and not by
/// `std.AutoHashMapUnmanaged`'s default strategy, which rejects a slice
/// outright (`std/hash_map.zig:15`). A byte slice therefore qualifies, which is
/// what the `VkPipelineCache` map needs: it keys on the pipeline's key bytes.
/// `CacheKey` does not qualify, because the context compares a struct field by
/// field, and a key that owns its own bytes would be compared by pointer.
///
/// `Key` must also own no memory, because `put` stores it by value and no
/// entry point frees it: a key with a destructor would leak on every eviction
/// and on `deinit`. That is the rule `CacheKey` fails, which is why the
/// `VkPipelineCache` map keys on bytes the caller keeps and frees
/// (`pipeline.zig:352-353`, `:370-372`).
pub fn LruCache(
    comptime Key: type,
    comptime Value: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: Key,
            value: Value,
            last_used: u64,
        };

        /// Whether `Key` is a slice, decided once so the equality below can
        /// branch without a second `switch`.
        const key_is_slice = switch (@typeInfo(Key)) {
            .pointer => |info| info.size == .slice,
            else => false,
        };

        /// Hashes and compares `Key` so a slice keys by its bytes.
        ///
        /// `std.AutoHashMapUnmanaged`'s own strategy rejects a slice outright
        /// (`std/hash_map.zig:15`) because a pointer hash is almost never the
        /// intent, and its equality compares a slice by pointer identity, so
        /// two equal byte keys at two addresses would be two entries. Both
        /// instantiations need the contents: the `VkPipelineCache` map keys
        /// on the pipeline's key bytes (`pipeline.zig:352-353`), and the
        /// framebuffer cache keys on a struct of scalars, which
        /// `std.meta.eql` already compares field by field.
        const KeyContext = struct {
            pub fn hash(_: KeyContext, key: Key) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(&hasher, key, .Deep);
                return hasher.final();
            }

            pub fn eql(_: KeyContext, left: Key, right: Key) bool {
                if (comptime key_is_slice) return std.mem.eql(u8, left, right);
                return std.meta.eql(left, right);
            }
        };

        entries: std.ArrayList(Entry) = .empty,
        // `std.HashMapUnmanaged` and not `std.AutoHashMapUnmanaged`, because
        // the key this cache takes for the `VkPipelineCache` map is a slice
        // and the auto strategy will not hash one.
        index: std.HashMapUnmanaged(
            Key,
            usize,
            KeyContext,
            std.hash_map.default_max_load_percentage,
        ) = .empty,
        clock: u64 = 0,

        pub const Error = std.mem.Allocator.Error;

        pub fn init() Self {
            return .{};
        }

        /// Frees the two containers and nothing else. No value is destroyed
        /// here, because a value's destructor belongs to whoever owns the
        /// value: `PipelineStore.deinit` walks `entries.items` and destroys the
        /// `VkPipelineCache` handles itself, and `FramebufferCache.deinit`
        /// destroys through the driver table. Upstream routed every value
        /// through the `EvictedFromCache` hook before `Clear` emptied the map
        /// (`LRUCache.h:142-149`), and that hook is what the port split in two.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.index.deinit(allocator);
        }

        /// The value `key` names, and marks it used. `null` is a miss, and a
        /// miss is not an error: Dawn's `GetOrCreate`
        /// (`src/dawn/common/LRUCache.h:95`) calls the create function on a
        /// miss, so the port hands the miss back and the caller creates.
        pub fn get(self: *Self, key: Key) ?Value {
            const slot = self.index.get(key) orelse return null;
            self.clock += 1;
            self.entries.items[slot].last_used = self.clock;
            return self.entries.items[slot].value;
        }

        /// Records `value` under `key` and returns whatever eviction displaced,
        /// so the caller can destroy the Vulkan object behind it. `null` is
        /// the answer when nothing was displaced.
        ///
        /// An existing key is updated in place and evicts nothing, and an
        /// insert below the cap evicts nothing, so the payload has to be able
        /// to say both. A full cache evicts the least recently used entry and
        /// hands that entry back.
        pub fn put(self: *Self, allocator: std.mem.Allocator, key: Key, value: Value) Error!?Value {
            self.clock += 1;
            if (self.index.get(key)) |slot| {
                self.entries.items[slot].value = value;
                self.entries.items[slot].last_used = self.clock;
                return null;
            }
            // `LRUCache.h:96`: a capacity of 0 disables the cache, so the new
            // value goes straight back out as the one that left it.
            if (capacity == 0) return value;

            try self.entries.append(allocator, .{ .key = key, .value = value, .last_used = self.clock });
            errdefer _ = self.entries.pop();
            try self.index.put(allocator, key, self.entries.items.len - 1);

            // `LRUCache.h:131` evicts after the insert, so the value that
            // leaves is always handed to a caller that can destroy it, and a
            // failed append never drops one silently. The entry just stored
            // holds the newest clock, so `evictOldest` never reaches for it
            // and this one widening from `Value` to `?Value` is the only
            // coercion the payload needs.
            if (self.entries.items.len <= capacity) return null;
            return @as(?Value, try self.evictOldest(allocator));
        }

        /// Removes the entry `key` names and returns its value, or null.
        ///
        /// The compaction is a `swapRemove` for the reason
        /// `evictOldest` gives: `orderedRemove` would shift every later entry
        /// down and leave the index naming slots that no longer hold their
        /// key.
        pub fn remove(self: *Self, allocator: std.mem.Allocator, key: Key) ?Value {
            const slot = self.index.get(key) orelse return null;
            const removed = self.entries.swapRemove(slot);
            self.reindexAfterSwap(allocator, slot);
            _ = self.index.remove(key);
            return removed.value;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.entries.items.len == 0;
        }

        pub fn queryEntryCount(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// Drops the oldest entry, hands its value back, and repairs the index
        /// the swap disturbed. Exactly one entry always leaves, which is why
        /// the value is not optional here: the optional `put` returns says
        /// that some calls displace nothing, not that this one might.
        ///
        /// The array is compacted with `swapRemove` and not `orderedRemove`,
        /// because `orderedRemove` shifts every later entry down by one and
        /// leaves the index naming slots that no longer hold their key.
        fn evictOldest(self: *Self, allocator: std.mem.Allocator) Error!Value {
            const oldest_slot = self.findOldestSlot();
            std.debug.assert(oldest_slot < self.entries.items.len);
            const oldest_key = self.entries.items[oldest_slot].key;
            const removed = self.entries.swapRemove(oldest_slot);
            self.reindexAfterSwap(allocator, oldest_slot);
            _ = self.index.remove(oldest_key);
            return removed.value;
        }

        /// A linear scan, which `docs/30-port-design.md` §7.3 records as the
        /// deliberate difference from Dawn's `std::list` splice. The map holds
        /// a few hundred entries and is touched once per pipeline creation.
        fn findOldestSlot(self: *const Self) usize {
            std.debug.assert(self.entries.items.len != 0);
            var oldest: usize = 0;
            for (self.entries.items, 0..) |entry, slot| {
                if (entry.last_used < self.entries.items[oldest].last_used) oldest = slot;
            }
            return oldest;
        }

        /// After `swapRemove(moved_from)` the entry that was last now sits at
        /// `moved_from`, so exactly one index entry is stale.
        fn reindexAfterSwap(self: *Self, allocator: std.mem.Allocator, moved_from: usize) void {
            if (moved_from >= self.entries.items.len) return;
            const moved = &self.entries.items[moved_from];
            self.index.put(allocator, moved.key, moved_from) catch {
                // The index cannot grow: it already held a slot for this key
                // and no entry was added, so `getOrPut` finds the key and
                // `put` takes its `found_existing` branch, which allocates
                // nothing. A failure here would mean the map grew past its
                // allocation for a key it already held.
                std.debug.panic("LruCache: reindexing a key the index already holds failed", .{});
            };
        }
    };
}

/// One `VkPipelineCache`, and the device and the table that made it. The value
/// the `VkPipelineCache` map above holds.
///
/// Dawn's `PipelineCacheVk` (`vulkan/PipelineCacheVk.h:40`) keeps the handle
/// beside the device because `vkDestroyPipelineCache` takes the device that
/// created the cache, and a pair a caller cannot make must not be stored apart.
///
/// **What this file does not claim.** It does not claim Dawn's blob cache.
/// Dawn seeds the handle with a blob (`PipelineCacheVk.cpp:123-148`), reads
/// it from a device-owned `BlobCache` (`PipelineCache.cpp:37-51`, made at
/// `Device.cpp:333-334`) and hands the serialized bytes back to that store
/// (`PipelineCacheVk.cpp:76-121`, `PipelineCache.cpp:58-68`). The port has
/// no such store: the render path hands `null` to `vkCreateGraphicsPipelines`
/// (`pipeline_render.zig:971`) and the compute path a handle its caller leaves
/// `null` (`pipeline_compute.zig:63-70`, `pipeline.zig:542`), so nothing seeds
/// or serializes a cache and the map stays empty. The handle and its destroy
/// are what `PipelineStore` needs today.
pub const PipelineCache = struct {
    /// Dawn's `mHandle` (`vulkan/PipelineCacheVk.h:60`). Null is the value a
    /// cache that never reached the driver keeps.
    handle: vulkan.VkPipelineCache = null,
    /// Dawn's `mDevice` (`vulkan/PipelineCacheVk.h:57`). The device that
    /// produced `handle`.
    device: vulkan.VkDevice,
    /// The device tier that produced `handle`. Destroying through another table
    /// would destroy a handle from another loader
    /// (`pipeline_backend.zig:46-51`, `:56-65`).
    procs: *const vk.DeviceProcs,

    /// What `destroy` reports. `dispatch.LoadError` is joined in whole, as
    /// `src/engine/buffer.zig:194` joins it, because `destroy` reads one
    /// device dispatch field and `AGENTS.md` §3.1 makes a missing one a typed
    /// error. Its four members are declared at `src/vk/dispatch.zig:319-324`,
    /// so the count this set carries is the count that file declares.
    pub const DestroyError = vk.LoadError;

    /// `PipelineCache::~PipelineCache` (`PipelineCacheVk.cpp:64`-`:70`), which
    /// is everything Dawn's destructor does.
    ///
    /// A null handle destroys nothing, so a cache that never reached the driver
    /// costs one branch and not a call.
    pub fn destroy(self: *const PipelineCache) DestroyError!void {
        if (self.handle == null) return;
        const destroy_pipeline_cache = self.procs.destroy_pipeline_cache orelse
            return error.MissingDeviceProc;
        destroy_pipeline_cache(self.device, self.handle, null);
    }
};

/// The leak check a test's `defer` cannot propagate.
///
/// `std.heap.DebugAllocator.deinit` prints every leaked block with the stack
/// trace that allocated it and only then answers `.leak`, so asserting that
/// answer is what turns the report into a failed test. A `defer` has no way
/// to `try` the result and `AGENTS.md` §2 forbids dropping the value.
fn assertNoLeak(state: *std.heap.DebugAllocator(.{})) void {
    std.debug.assert(state.deinit() == .ok);
}

test "a duplicate returns the object the first call recorded" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    const Probe = struct {
        const Self = @This();

        value: u64 = 0,
        alive: bool = true,
        pub fn isAlive(self: *const Self) bool {
            return self.alive;
        }
    };
    var cache = Cache(Probe).init(allocator);
    defer cache.deinit();

    var first: Probe = .{ .value = 1 };
    var second: Probe = .{ .value = 2 };

    var stored = CacheKey.init();
    try stored.appendKind(allocator, .render_pipeline);
    try stored.appendBytes(allocator, "layout");

    var rebuilt = CacheKey.init();
    defer rebuilt.deinit(allocator);
    try rebuilt.appendKind(allocator, .render_pipeline);
    try rebuilt.appendBytes(allocator, "layout");

    try std.testing.expect(cache.find(&rebuilt) == null);
    try cache.insert(&stored, &first);
    try std.testing.expectEqual(&first, cache.find(&rebuilt).?);
    try std.testing.expectEqual(@as(usize, 1), cache.queryEntryCount());

    var other = CacheKey.init();
    defer other.deinit(allocator);
    try other.appendKind(allocator, .render_pipeline);
    try other.appendBytes(allocator, "other layout");
    try std.testing.expect(cache.find(&other) == null);
    try std.testing.expect(!cache.isEmpty());
    try std.testing.expect(cache.queryKeyByteCount() > 0);

    // A destroyed object is invisible to a later lookup, and the next prune
    // drops the entry. That is the port's stand-in for Dawn's failed
    // `WeakRef` promotion.
    first.alive = false;
    try std.testing.expect(cache.find(&rebuilt) == null);
    try std.testing.expectEqual(@as(usize, 1), cache.prune());
    try std.testing.expectEqual(@as(usize, 0), cache.queryEntryCount());

    // A second insert under the same key is what a duplicate descriptor would
    // do if the caller had not found the first one; the lookup still answers
    // with the first live entry.
    var duplicate = CacheKey.init();
    defer duplicate.deinit(allocator);
    try duplicate.appendKind(allocator, .render_pipeline);
    try duplicate.appendBytes(allocator, "layout");
    try cache.insert(&duplicate, &second);
    try std.testing.expectEqual(@as(usize, 1), cache.queryEntryCount());
    try std.testing.expectEqual(&second, cache.find(&rebuilt).?);
}

test "two keys that differ in their layout bytes name different entries" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    const Probe = struct {
        const Self = @This();

        value: u64 = 0,
        pub fn isAlive(_: *const Self) bool {
            return true;
        }
    };
    var cache = Cache(Probe).init(allocator);
    defer cache.deinit();

    var first: Probe = .{ .value = 1 };
    var second: Probe = .{ .value = 2 };

    for ([_][]const u8{ "set0 binding0", "set0 binding1" }) |layout_bytes| {
        var key = CacheKey.init();
        errdefer key.deinit(allocator);
        try key.appendKind(allocator, .render_pipeline);
        try key.appendBytes(allocator, layout_bytes);
        // Byte 12 is the binding ordinal and the only byte where "set0
        // binding0" and "set0 binding1" differ; byte 3 is the set ordinal and
        // byte 7 is 'n' in both, so neither separates the two keys.
        try cache.insert(&key, if (layout_bytes[12] == '0') &first else &second);
    }

    try std.testing.expectEqual(@as(usize, 2), cache.queryEntryCount());

    var found_first: ?*Probe = null;
    var found_second: ?*Probe = null;
    for ([_][]const u8{ "set0 binding0", "set0 binding1" }) |layout_bytes| {
        var key = CacheKey.init();
        defer key.deinit(allocator);
        try key.appendKind(allocator, .render_pipeline);
        try key.appendBytes(allocator, layout_bytes);
        const hit = cache.find(&key) orelse return error.CacheMissedItsOwnEntry;
        if (layout_bytes[12] == '0') found_first = hit else found_second = hit;
    }

    try std.testing.expectEqual(@as(u64, 1), found_first.?.value);
    try std.testing.expectEqual(@as(u64, 2), found_second.?.value);

    cache.remove(&first);
    try std.testing.expectEqual(@as(usize, 1), cache.queryEntryCount());
}

test "the lru cache evicts the least recently used entry and keeps its index" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    var cache = LruCache([]const u8, u32, 2).init();
    defer cache.deinit(allocator);

    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect((try cache.put(allocator, "a", 1)) == null);
    try std.testing.expect((try cache.put(allocator, "b", 2)) == null);
    // Touching "a" makes "b" the oldest.
    try std.testing.expectEqual(@as(?u32, 1), cache.get("a"));

    const evicted = try cache.put(allocator, "c", 3);
    try std.testing.expectEqual(@as(?u32, 2), evicted);
    try std.testing.expectEqual(@as(usize, 2), cache.queryEntryCount());
    try std.testing.expect(cache.get("b") == null);
    try std.testing.expectEqual(@as(?u32, 3), cache.get("c"));
    try std.testing.expectEqual(@as(?u32, 1), cache.get("a"));
}

test "an lru removal leaves every remaining key reachable" {
    var allocator_state: std.heap.DebugAllocator(.{}) = .{};
    defer assertNoLeak(&allocator_state);
    const allocator = allocator_state.allocator();

    var cache = LruCache([]const u8, u32, 4).init();
    defer cache.deinit(allocator);

    // Three inserts into a four-slot cache displace nothing, which is the
    // answer the optional payload carries; `LRUCache.h:131` evicts only once
    // the list has outgrown the capacity.
    try std.testing.expect((try cache.put(allocator, "a", 1)) == null);
    try std.testing.expect((try cache.put(allocator, "b", 2)) == null);
    try std.testing.expect((try cache.put(allocator, "c", 3)) == null);

    try std.testing.expectEqual(@as(?u32, 1), cache.remove(allocator, "a"));
    try std.testing.expectEqual(@as(usize, 2), cache.queryEntryCount());
    try std.testing.expectEqual(@as(?u32, 2), cache.get("b"));
    try std.testing.expectEqual(@as(?u32, 3), cache.get("c"));
    try std.testing.expect(cache.remove(allocator, "missing") == null);
}
