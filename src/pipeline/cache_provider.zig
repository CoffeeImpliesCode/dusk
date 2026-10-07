//! Persistence transports for complete cache_artifact envelopes. Validation belongs to the handler.
//! Contexts and borrowed directory/userdata capabilities remain valid through native device teardown.
const std = @import("std");
const codec = @import("cache_artifact.zig");
const callbacks = @import("../api/callbacks.zig");
pub const temporary_attempt_limit: usize = 8;

pub const CacheMiss = enum { not_found, invalid_artifact, identity_mismatch };
pub const ProviderError = error{ Io, OutOfMemory, ArtifactTooLarge, TemporaryFileExhausted, AtomicReplaceFailed };
pub const LoadResult = union(enum) { miss: CacheMiss, hit: []u8 };

pub const PipelineCacheProvider = struct {
    context: *anyopaque,
    load_fn: *const fn (allocator: std.mem.Allocator, io: std.Io, context: *anyopaque, key: [32]u8, max_payload_byte_count: usize) ProviderError!LoadResult,
    store_fn: *const fn (io: std.Io, context: *anyopaque, key: [32]u8, artifact: []const u8) ProviderError!void,

    /// A hit is the entire artifact, owned by allocator; the caller frees it exactly once.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, self: PipelineCacheProvider, key: [32]u8, max_payload_byte_count: usize) ProviderError!LoadResult {
        return self.load_fn(allocator, io, self.context, key, max_payload_byte_count);
    }

    pub fn store(self: PipelineCacheProvider, io: std.Io, key: [32]u8, artifact: []const u8) ProviderError!void {
        return self.store_fn(io, self.context, key, artifact);
    }
};

pub const FilesystemConfiguration = struct { root: *const std.Io.Dir };
pub const DawnCallbackConfiguration = struct {
    load: ?callbacks.DawnLoadCacheDataCallbackInfo,
    store: ?callbacks.DawnStoreCacheDataCallbackInfo,
};
pub const PipelineCacheConfiguration = union(enum) {
    filesystem: FilesystemConfiguration,
    callbacks: DawnCallbackConfiguration,
    memory_only: void,
};

pub const MemoryOnlyProvider = struct {
    pub fn provider(self: *MemoryOnlyProvider) PipelineCacheProvider {
        return .{ .context = self, .load_fn = load, .store_fn = store };
    }

    fn load(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: [32]u8, _: usize) ProviderError!LoadResult {
        return .{ .miss = .not_found };
    }

    fn store(_: std.Io, _: *anyopaque, _: [32]u8, _: []const u8) ProviderError!void {}
};

/// Exact generated callback ABI: src/api/callbacks.zig, from src/dawn/dawn.json
/// "dawn load cache data callback" (269), load info (280), store callback (287), store info (297).
/// Dawn queries with value_size=0, then fills caller-owned storage; store returns void.
pub const DawnCallbackProvider = struct {
    configuration: DawnCallbackConfiguration,
    maximum_payload_byte_count: usize = codec.default_maximum_payload_byte_count,

    pub fn provider(self: *DawnCallbackProvider) PipelineCacheProvider {
        return .{ .context = self, .load_fn = load, .store_fn = store };
    }

    fn load(allocator: std.mem.Allocator, _: std.Io, context: *anyopaque, key: [32]u8, max_payload_byte_count: usize) ProviderError!LoadResult {
        const self: *DawnCallbackProvider = @ptrCast(@alignCast(context));
        const info = self.configuration.load orelse return .{ .miss = .not_found };
        const callback = info.callback orelse return .{ .miss = .not_found };
        const maximum = try maximumArtifactByteCount(@min(self.maximum_payload_byte_count, max_payload_byte_count));
        const required = callback(info.userdata, key.len, &key, 0, &.{});
        if (required == 0) return .{ .miss = .not_found };
        if (required > maximum) return .{ .miss = .invalid_artifact };
        const bytes = try allocator.alloc(u8, required);
        errdefer allocator.free(bytes);
        const actual = callback(info.userdata, key.len, &key, bytes.len, bytes);
        if (actual != required) {
            allocator.free(bytes);
            return .{ .miss = .invalid_artifact };
        }
        return .{ .hit = bytes };
    }

    /// The exact Dawn void ABI cannot report persistence failure or filesystem durability.
    fn store(_: std.Io, context: *anyopaque, key: [32]u8, artifact: []const u8) ProviderError!void {
        const self: *DawnCallbackProvider = @ptrCast(@alignCast(context));
        if (artifact.len > try maximumArtifactByteCount(self.maximum_payload_byte_count)) return error.ArtifactTooLarge;
        const info = self.configuration.store orelse return;
        const callback = info.callback orelse return;
        callback(info.userdata, key.len, &key, artifact.len, artifact);
    }
};

pub const FilesystemProvider = struct {
    configuration: FilesystemConfiguration,
    maximum_payload_byte_count: usize = codec.default_maximum_payload_byte_count,
    mutex: std.Io.Mutex = .init,
    next_temporary_id: u64 = 0,

    pub fn provider(self: *FilesystemProvider) PipelineCacheProvider {
        return .{ .context = self, .load_fn = load, .store_fn = store };
    }

    fn load(allocator: std.mem.Allocator, io: std.Io, context: *anyopaque, key: [32]u8, max_payload_byte_count: usize) ProviderError!LoadResult {
        const self: *FilesystemProvider = @ptrCast(@alignCast(context));
        const maximum = try maximumArtifactByteCount(@min(self.maximum_payload_byte_count, max_payload_byte_count));
        const name = fileName(key);
        const file = self.configuration.root.openFile(io, &name, .{}) catch |err| switch (err) {
            error.FileNotFound => return .{ .miss = .not_found },
            else => return error.Io,
        };
        defer file.close(io);
        const stat = file.stat(io) catch return error.Io;
        if (stat.size > maximum) return error.ArtifactTooLarge;
        if (stat.kind != .file) return .{ .miss = .invalid_artifact };
        const size = std.math.cast(usize, stat.size) orelse return error.ArtifactTooLarge;
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(io, bytes, 0) catch return error.Io;
        var extra: [1]u8 = undefined;
        const extra_count = file.readPositional(io, &.{&extra}, stat.size) catch return error.Io;
        if (read != size or extra_count != 0) {
            allocator.free(bytes);
            return .{ .miss = .invalid_artifact };
        }
        return .{ .hit = bytes };
    }

    fn store(io: std.Io, context: *anyopaque, key: [32]u8, artifact: []const u8) ProviderError!void {
        const self: *FilesystemProvider = @ptrCast(@alignCast(context));
        if (artifact.len > try maximumArtifactByteCount(self.maximum_payload_byte_count)) return error.ArtifactTooLarge;
        self.mutex.lock(io) catch return error.Io;
        defer self.mutex.unlock(io);
        const root = self.configuration.root.*;
        const name = fileName(key);
        // Linux non-iterable Dir capabilities use O_PATH, which cannot be fsynced.
        // Reopen this exact directory through the caller capability, never through cwd.
        const sync_directory = root.openDir(io, ".", .{ .iterate = true }) catch return error.Io;
        defer sync_directory.close(io);
        var temporary_buffer: [128]u8 = undefined;
        var temporary_name: []const u8 = undefined;
        const temporary = for (0..temporary_attempt_limit) |_| {
            const id = self.next_temporary_id;
            self.next_temporary_id +%= 1;
            temporary_name = std.fmt.bufPrint(&temporary_buffer, "{s}.tmp.{x:0>16}.{x:0>16}", .{ name, @intFromPtr(self), id }) catch unreachable;
            const file = root.createFile(io, temporary_name, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return error.Io,
            };
            break file;
        } else return error.TemporaryFileExhausted;
        defer temporary.close(io);
        // Never delete a colliding file owned by another writer. Only our successful create is cleaned.
        var published = false;
        defer if (!published) {
            // Cleanup must remain possible even when the operation was cancelled.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            root.deleteFile(io, temporary_name) catch {};
        };
        temporary.writeStreamingAll(io, artifact) catch return error.Io;
        temporary.sync(io) catch return error.Io;
        root.rename(temporary_name, root, &name, io) catch return error.AtomicReplaceFailed;
        published = true;
        // std.Io has no Dir.sync. Borrow the syncable handle without taking ownership.
        const directory_file: std.Io.File = .{ .handle = sync_directory.handle, .flags = .{ .nonblocking = false } };
        directory_file.sync(io) catch return error.Io;
    }
};

/// Only a fixed digest becomes a path component; no caller key string is interpreted as a path.
pub fn fileName(key: [32]u8) [64]u8 {
    const digits = "0123456789abcdef";
    var name: [64]u8 = undefined;
    for (key, 0..) |byte, index| {
        name[index * 2] = digits[byte >> 4];
        name[index * 2 + 1] = digits[byte & 15];
    }
    return name;
}

fn maximumArtifactByteCount(maximum_payload_byte_count: usize) ProviderError!usize {
    if (maximum_payload_byte_count > codec.default_maximum_payload_byte_count) return error.ArtifactTooLarge;
    const result = @addWithOverflow(codec.header_byte_count, maximum_payload_byte_count);
    if (result[1] != 0) return error.ArtifactTooLarge;
    return result[0];
}
