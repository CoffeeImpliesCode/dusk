const std = @import("std");
const dusk = @import("dusk");
const provider = dusk.pipeline.cache_provider;
const codec = dusk.pipeline.cache_artifact;
const testing = std.testing;
const key: [32]u8 = @splat(0xab);
const identity: codec.Identity = .{ .vendor_id = 7, .device_id = 9, .driver_version = 11, .pipeline_cache_uuid = @splat(3) };

fn fixture() ![160]u8 {
    var bytes: [160]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[128..132], 32, .little);
    std.mem.writeInt(u32, bytes[132..136], 1, .little);
    std.mem.writeInt(u32, bytes[136..140], identity.vendor_id, .little);
    std.mem.writeInt(u32, bytes[140..144], identity.device_id, .little);
    @memcpy(bytes[144..160], &identity.pipeline_cache_uuid);
    const header = try codec.encodeHeader(.{ .identity = identity, .isolation_key_hash = key, .payload = bytes[128..] });
    @memcpy(bytes[0..128], &header);
    return bytes;
}

fn expectMiss(result: provider.LoadResult, expected: provider.CacheMiss) !void {
    switch (result) {
        .miss => |miss| try testing.expectEqual(expected, miss),
        .hit => |bytes| { testing.allocator.free(bytes); return error.TestUnexpectedResult; },
    }
}

const CallbackState = struct {
    bytes: []const u8,
    query_length: ?usize = null,
    second_length: ?usize = null,
    loads: usize = 0,
    stores: usize = 0,
    key_valid: bool = true,
    stored: [160]u8 = undefined,

    fn load(context: ?*anyopaque, key_size: usize, supplied_key: ?[]const u8, value_size: usize, value: []u8) usize {
        const self: *CallbackState = @ptrCast(@alignCast(context.?));
        self.loads += 1;
        self.key_valid = self.key_valid and key_size == 32 and supplied_key != null and std.mem.eql(u8, supplied_key.?, &key);
        if (value_size == 0) {
            self.key_valid = self.key_valid and value.len == 0;
            return self.query_length orelse self.bytes.len;
        }
        self.key_valid = self.key_valid and value_size == value.len;
        @memcpy(value[0..@min(value.len, self.bytes.len)], self.bytes[0..@min(value.len, self.bytes.len)]);
        return self.second_length orelse self.bytes.len;
    }

    fn store(context: ?*anyopaque, key_size: usize, supplied_key: ?[]const u8, value_size: usize, value: ?[]const u8) void {
        const self: *CallbackState = @ptrCast(@alignCast(context.?));
        self.stores += 1;
        self.key_valid = self.key_valid and key_size == 32 and std.mem.eql(u8, supplied_key.?, &key) and value_size == value.?.len;
        @memcpy(self.stored[0..value_size], value.?);
    }

    fn configuration(self: *CallbackState) provider.DawnCallbackConfiguration {
        return .{ .load = .{ .callback = load, .userdata = self }, .store = .{ .callback = store, .userdata = self } };
    }
};

test "memory-only intentionally never persists" {
    var context: provider.MemoryOnlyProvider = .{};
    const p = context.provider();
    const bytes = try fixture();
    try p.store(testing.io, key, &bytes);
    try expectMiss(try provider.PipelineCacheProvider.load(testing.allocator, testing.io, p, key, 32), .not_found);
}

test "Dawn exact ABI returns an independent complete owned artifact" {
    var bytes = try fixture();
    var state: CallbackState = .{ .bytes = &bytes };
    var context: provider.DawnCallbackProvider = .{ .configuration = state.configuration() };
    const p = context.provider();
    const result = try provider.PipelineCacheProvider.load(testing.allocator, testing.io, p, key, 32);
    const owned = result.hit;
    defer testing.allocator.free(owned);
    try testing.expectEqualSlices(u8, &bytes, owned);
    bytes[159] ^= 1;
    try testing.expect(owned[159] != bytes[159]);
    try testing.expectEqual(@as(usize, 2), state.loads);
    try testing.expect(state.key_valid);
    try p.store(testing.io, key, owned);
    try testing.expectEqual(@as(usize, 1), state.stores);
    try testing.expectEqualSlices(u8, owned, &state.stored);
}

test "Dawn zero query is not found and oversize query allocates nothing" {
    const bytes = try fixture();
    var state: CallbackState = .{ .bytes = &bytes, .query_length = 0 };
    var context: provider.DawnCallbackProvider = .{ .configuration = state.configuration() };
    var empty: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&empty);
    try expectMiss(try provider.PipelineCacheProvider.load(allocator.allocator(), testing.io, context.provider(), key, 32), .not_found);
    state.query_length = 161;
    try expectMiss(try provider.PipelineCacheProvider.load(allocator.allocator(), testing.io, context.provider(), key, 32), .invalid_artifact);
    try testing.expectEqual(@as(usize, 2), state.loads);
}

test "Dawn changed callback lengths free the partial buffer" {
    const bytes = try fixture();
    for ([_]usize{ 0, 159, 161 }) |length| {
        var state: CallbackState = .{ .bytes = &bytes, .second_length = length };
        var context: provider.DawnCallbackProvider = .{ .configuration = state.configuration() };
        try expectMiss(try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32), .invalid_artifact);
        try testing.expectEqual(@as(usize, 2), state.loads);
    }
}

test "Dawn absent callbacks miss and discard; allocation errors remain errors" {
    var absent: provider.DawnCallbackProvider = .{ .configuration = .{ .load = null, .store = null } };
    const bytes = try fixture();
    try expectMiss(try provider.PipelineCacheProvider.load(testing.allocator, testing.io, absent.provider(), key, 32), .not_found);
    try absent.provider().store(testing.io, key, &bytes);
    var state: CallbackState = .{ .bytes = &bytes };
    var context: provider.DawnCallbackProvider = .{ .configuration = state.configuration() };
    var empty: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&empty);
    try testing.expectError(error.OutOfMemory, provider.PipelineCacheProvider.load(allocator.allocator(), testing.io, context.provider(), key, 32));
    try testing.expectEqual(@as(usize, 1), state.loads);
}

test "provider raw hit leaves integrity validation to the handler" {
    var bytes = try fixture();
    bytes[100] ^= 1;
    var state: CallbackState = .{ .bytes = &bytes };
    var context: provider.DawnCallbackProvider = .{ .configuration = state.configuration() };
    const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
    defer testing.allocator.free(owned);
    try testing.expectError(error.CacheIntegrityMismatch, codec.decodeView(owned, .{ .expected_identity = identity, .isolation_key_hash = key }));
}

test "filesystem commits and replaces full artifacts within explicit directory" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const p = context.provider();
    try expectMiss(try provider.PipelineCacheProvider.load(testing.allocator, testing.io, p, key, 32), .not_found);
    var bytes = try fixture();
    try p.store(testing.io, key, &bytes);
    const first = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, p, key, 32)).hit;
    defer testing.allocator.free(first);
    try testing.expectEqualSlices(u8, &bytes, first);
    bytes[100] ^= 1;
    try p.store(testing.io, key, &bytes);
    const second = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, p, key, 32)).hit;
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, &bytes, second);
    try testing.expect(first[100] != second[100]);
}

test "filesystem checks extent before allocation and store does not replace on bounds error" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir }, .maximum_payload_byte_count = 32 };
    const bytes = try fixture();
    try context.provider().store(testing.io, key, &bytes);
    var empty: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&empty);
    try testing.expectError(error.ArtifactTooLarge, provider.PipelineCacheProvider.load(allocator.allocator(), testing.io, context.provider(), key, 31));
    const oversized: [161]u8 = @splat(0);
    try testing.expectError(error.ArtifactTooLarge, context.provider().store(testing.io, key, &oversized));
    const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
    defer testing.allocator.free(owned);
    try testing.expectEqualSlices(u8, &bytes, owned);
}

fn temporaryName(context: *provider.FilesystemProvider, index: u64, buffer: *[128]u8) []const u8 {
    const name = provider.fileName(key);
    return std.fmt.bufPrint(buffer, "{s}.tmp.{x:0>16}.{x:0>16}", .{ name, @intFromPtr(context), index }) catch unreachable;
}

test "filesystem exclusive eight collisions preserve final and stale temporary files" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const bytes = try fixture();
    try context.provider().store(testing.io, key, &bytes);
    const start = context.next_temporary_id;
    for (0..provider.temporary_attempt_limit) |offset| {
        var buffer: [128]u8 = undefined;
        const file = try directory.dir.createFile(testing.io, temporaryName(&context, start + offset, &buffer), .{ .exclusive = true });
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "stale");
    }
    try testing.expectError(error.TemporaryFileExhausted, context.provider().store(testing.io, key, &bytes));
    const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
    defer testing.allocator.free(owned);
    try testing.expectEqualSlices(u8, &bytes, owned);
    var buffer: [128]u8 = undefined;
    const stale = try directory.dir.readFileAlloc(testing.io, temporaryName(&context, start, &buffer), testing.allocator, .limited(5));
    defer testing.allocator.free(stale);
    try testing.expectEqualStrings("stale", stale);
}

test "filesystem rename failure removes only its owned temporary" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const name = provider.fileName(key);
    try directory.dir.createDir(testing.io, &name, .default_dir);
    const bytes = try fixture();
    try testing.expectError(error.AtomicReplaceFailed, context.provider().store(testing.io, key, &bytes));
    var buffer: [128]u8 = undefined;
    try testing.expectError(error.FileNotFound, directory.dir.openFile(testing.io, temporaryName(&context, 0, &buffer), .{}));
}

// Keep the real Io backend and native handles. Only the selected operation is faulted.
const Fault = enum { none, short_writes, write_failure, temp_sync, directory_sync };
threadlocal var fault: Fault = .none;
threadlocal var write_calls: usize = 0;
threadlocal var sync_calls: usize = 0;

fn faultOperate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    if (operation == .file_write_streaming) {
        write_calls += 1;
        if (fault == .write_failure) return .{ .file_write_streaming = error.InputOutput };
        if (fault == .short_writes) {
            const write = operation.file_write_streaming;
            const short = write.data[0][0..@min(write.data[0].len, 7)];
            return testing.io.vtable.operate(userdata, .{ .file_write_streaming = .{
                .file = write.file, .header = write.header, .data = &.{short}, .splat = 1,
            } });
        }
    }
    return testing.io.vtable.operate(userdata, operation);
}

fn faultSync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    sync_calls += 1;
    if ((fault == .temp_sync and sync_calls == 1) or
        (fault == .directory_sync and sync_calls == 2)) return error.InputOutput;
    return testing.io.vtable.fileSync(userdata, file);
}

test "filesystem full write loop handles short native writes and syncs both handles" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const bytes = try fixture();
    var vtable = testing.io.vtable.*;
    vtable.operate = faultOperate;
    vtable.fileSync = faultSync;
    var io = testing.io;
    io.vtable = &vtable;
    fault = .short_writes;
    defer fault = .none;
    write_calls = 0;
    sync_calls = 0;
    try context.provider().store(io, key, &bytes);
    try testing.expect(write_calls > 1);
    try testing.expectEqual(@as(usize, 2), sync_calls);
    const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
    defer testing.allocator.free(owned);
    try testing.expectEqualSlices(u8, &bytes, owned);
}

test "filesystem precommit failures preserve old artifact and remove own temporary" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const old = try fixture();
    try context.provider().store(testing.io, key, &old);
    var replacement = old;
    replacement[100] ^= 1;
    var vtable = testing.io.vtable.*;
    vtable.operate = faultOperate;
    vtable.fileSync = faultSync;
    var io = testing.io;
    io.vtable = &vtable;
    defer fault = .none;
    for ([_]Fault{ .write_failure, .temp_sync }) |selected| {
        const temporary_id = context.next_temporary_id;
        fault = selected;
        sync_calls = 0;
        try testing.expectError(error.Io, context.provider().store(io, key, &replacement));
        var buffer: [128]u8 = undefined;
        try testing.expectError(error.FileNotFound, directory.dir.openFile(testing.io, temporaryName(&context, temporary_id, &buffer), .{}));
        const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
        defer testing.allocator.free(owned);
        try testing.expectEqualSlices(u8, &old, owned);
    }
}

test "filesystem directory sync failure reports durability error after complete rename" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const bytes = try fixture();
    var vtable = testing.io.vtable.*;
    vtable.fileSync = faultSync;
    var io = testing.io;
    io.vtable = &vtable;
    fault = .directory_sync;
    defer fault = .none;
    sync_calls = 0;
    try testing.expectError(error.Io, context.provider().store(io, key, &bytes));
    try testing.expectEqual(@as(usize, 2), sync_calls);
    const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
    defer testing.allocator.free(owned);
    try testing.expectEqualSlices(u8, &bytes, owned);
}

test "Dawn store bounds prevent callback invocation" {
    const bytes = try fixture();
    var state: CallbackState = .{ .bytes = &bytes };
    var context: provider.DawnCallbackProvider = .{
        .configuration = state.configuration(), .maximum_payload_byte_count = 31,
    };
    try testing.expectError(error.ArtifactTooLarge, context.provider().store(testing.io, key, &bytes));
    try testing.expectEqual(@as(usize, 0), state.stores);
}

test "digest filenames are fixed lowercase hex with no path components" {
    const name = provider.fileName(key);
    try testing.expectEqualStrings("abababababababababababababababababababababababababababababababab", &name);
    const zero = provider.fileName(@splat(0));
    try testing.expectEqual(@as(usize, 64), zero.len);
    for (zero) |byte| try testing.expectEqual(@as(u8, '0'), byte);
}

test "filesystem raw artifacts are not decoded by transport" {
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const malformed = "not a valid cache artifact";
    try context.provider().store(testing.io, key, malformed);
    const owned = (try provider.PipelineCacheProvider.load(testing.allocator, testing.io, context.provider(), key, 32)).hit;
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings(malformed, owned);
    try testing.expectError(error.TruncatedArtifact, codec.decodeView(owned, .{ .expected_identity = identity, .isolation_key_hash = key }));
}

const concurrent_write_count: usize = 24;
const concurrent_read_count: usize = concurrent_write_count * 8;
const concurrent_payload_byte_count: usize = 256 * 1024;

const ConcurrentWriter = struct {
    transport: provider.PipelineCacheProvider,
    artifact: []const u8,
    start: *std.Io.Event,
    entered: std.Io.Event = .unset,

    fn run(io: std.Io, self: *ConcurrentWriter) provider.ProviderError!void {
        self.entered.set(io);
        self.start.waitUncancelable(io);
        for (0..concurrent_write_count) |_| try self.transport.store(io, key, self.artifact);
    }
};

fn largeArtifact(allocator: std.mem.Allocator, marker: u8) ![]u8 {
    const bytes = try allocator.alloc(u8, codec.header_byte_count + concurrent_payload_byte_count);
    errdefer allocator.free(bytes);
    @memset(bytes, marker);
    const base = try fixture();
    @memcpy(bytes[codec.header_byte_count..][0..32], base[codec.header_byte_count..]);
    const header = try codec.encodeHeader(.{
        .identity = identity, .isolation_key_hash = key, .payload = bytes[codec.header_byte_count..],
    });
    @memcpy(bytes[0..codec.header_byte_count], &header);
    return bytes;
}

fn concurrentWriters(shared_context: bool) !void {
    const io = testing.io;
    var directory = testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    var first_context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    var second_context: provider.FilesystemProvider = .{ .configuration = .{ .root = &directory.dir } };
    const first_artifact = try largeArtifact(testing.allocator, 0x3c);
    defer testing.allocator.free(first_artifact);
    const second_artifact = try largeArtifact(testing.allocator, 0xc3);
    defer testing.allocator.free(second_artifact);
    const first = first_context.provider();
    const second = if (shared_context) first else second_context.provider();
    try first.store(io, key, first_artifact);
    var start: std.Io.Event = .unset;
    var writers = [_]ConcurrentWriter{
        .{ .transport = first, .artifact = first_artifact, .start = &start },
        .{ .transport = second, .artifact = second_artifact, .start = &start },
    };
    var first_task = try io.concurrent(ConcurrentWriter.run, .{ io, &writers[0] });
    var first_joined = false;
    defer if (!first_joined) {
        start.set(io);
        first_task.await(io) catch {};
    };
    var second_task = try io.concurrent(ConcurrentWriter.run, .{ io, &writers[1] });
    var second_joined = false;
    defer if (!second_joined) {
        start.set(io);
        second_task.await(io) catch {};
    };
    writers[0].entered.waitUncancelable(io);
    writers[1].entered.waitUncancelable(io);
    start.set(io);
    for (0..concurrent_read_count) |_| {
        const loaded = try provider.PipelineCacheProvider.load(testing.allocator, io, first, key, concurrent_payload_byte_count);
        const bytes = switch (loaded) {
            .hit => |hit| hit,
            .miss => return error.TestUnexpectedResult,
        };
        defer testing.allocator.free(bytes);
        try testing.expect(std.mem.eql(u8, bytes, first_artifact) or std.mem.eql(u8, bytes, second_artifact));
        _ = try codec.decodeView(bytes, .{ .expected_identity = identity, .isolation_key_hash = key });
    }
    const first_result = first_task.await(io);
    first_joined = true;
    const second_result = second_task.await(io);
    second_joined = true;
    try first_result;
    try second_result;
    try testing.expectEqual(
        @as(u64, 1 + if (shared_context) concurrent_write_count * 2 else concurrent_write_count),
        first_context.next_temporary_id,
    );
    if (!shared_context) try testing.expectEqual(@as(u64, concurrent_write_count), second_context.next_temporary_id);
    const committed_name = provider.fileName(key);
    var entries = directory.dir.iterate();
    var committed_count: usize = 0;
    while (try entries.next(io)) |entry| {
        // All successful writers clean their own sibling; exactly the final digest remains.
        try testing.expectEqualStrings(&committed_name, entry.name);
        committed_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), committed_count);
}

test "filesystem same provider serializes concurrent same-key writers" {
    try concurrentWriters(true);
}

test "filesystem separate providers atomically race same-key writers" {
    try concurrentWriters(false);
}

test "providers reject a payload bound above the absolute codec maximum without allocation" {
    const bytes = try fixture();
    const above_limit = codec.default_maximum_payload_byte_count + 1;
    var state: CallbackState = .{ .bytes = &bytes };
    var callbacks_context: provider.DawnCallbackProvider = .{
        .configuration = state.configuration(), .maximum_payload_byte_count = above_limit,
    };
    var empty: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&empty);
    try testing.expectError(error.ArtifactTooLarge, provider.PipelineCacheProvider.load(
        allocator.allocator(), testing.io, callbacks_context.provider(), key, above_limit,
    ));
    try testing.expectError(error.ArtifactTooLarge, callbacks_context.provider().store(testing.io, key, &bytes));
    try testing.expectEqual(@as(usize, 0), state.loads);
    try testing.expectEqual(@as(usize, 0), state.stores);
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    var filesystem_context: provider.FilesystemProvider = .{
        .configuration = .{ .root = &directory.dir }, .maximum_payload_byte_count = above_limit,
    };
    try testing.expectError(error.ArtifactTooLarge, provider.PipelineCacheProvider.load(
        allocator.allocator(), testing.io, filesystem_context.provider(), key, above_limit,
    ));
    try testing.expectError(error.ArtifactTooLarge, filesystem_context.provider().store(testing.io, key, &bytes));
    try testing.expectEqual(@as(u64, 0), filesystem_context.next_temporary_id);
}
