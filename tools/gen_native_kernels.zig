//! Fixed native-kernel generator. Run from the repository root.
//! Build: zig build-exe tools/gen_native_kernels.zig -O safe -femit-bin=gen-native-kernels
//! Run: DUSK_TINT=/absolute/path/to/tint ./gen-native-kernels --regen (or --check).

const std = @import("std");
const manifest = @import("native_kernel_manifest.zig");
const fixed_emitter = @import("native_ycbcr_spirv.zig");

test "driver accepts only one explicit mode" {
    try std.testing.expectEqual(Mode.check, try parseMode(&.{ "tool", "--check" }));
    try std.testing.expectEqual(Mode.regen, try parseMode(&.{ "tool", "--regen" }));
    try std.testing.expectError(error.InvalidArguments, parseMode(&.{"tool"}));
    try std.testing.expectError(error.InvalidArguments, parseMode(&.{ "tool", "--regen", "--check" }));
}

test "fixed emitter words become little endian bytes" {
    const bytes = try wordsToBytes(std.testing.allocator, &.{ 0x07230203, 0x01020304 });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 35, 7, 4, 3, 2, 1 }, bytes);
}

test "source hashes use SHA256 and lowercase hexadecimal" {
    const digest = hashBytes("abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &digest,
    );
}

test "inspection rejects invalid header and truncated instructions" {
    try std.testing.expectError(error.InvalidSpirv, inspect(std.testing.allocator, &.{}, test_entry));
    const malformed = try wordsToBytes(std.testing.allocator, &.{
        0x07230203, 0x00010300, 0, 16, 0, (10 << 16) | 15,
    });
    defer std.testing.allocator.free(malformed);
    try std.testing.expectError(error.InvalidSpirv, inspect(std.testing.allocator, malformed, test_entry));
}

test "inspection checks entry point stage and actual workgroup" {
    const words = testComputeWords();
    const bytes = try wordsToBytes(std.testing.allocator, &words);
    defer std.testing.allocator.free(bytes);
    try inspect(std.testing.allocator, bytes, test_entry);
    var wrong = test_entry;
    wrong.workgroup_size = .{ 8, 1, 1 };
    try std.testing.expectError(error.WorkgroupMismatch, inspect(std.testing.allocator, bytes, wrong));
    wrong = test_entry;
    wrong.stage = .fragment;
    try std.testing.expectError(error.EntryPointMismatch, inspect(std.testing.allocator, bytes, wrong));
    wrong = test_entry;
    wrong.entry_point = "other";
    try std.testing.expectError(error.EntryPointMismatch, inspect(std.testing.allocator, bytes, wrong));
    wrong = test_entry;
    wrong.bindings = &.{.{ .binding = 0, .kind = .uniform, .min_size = 4 }};
    try std.testing.expectError(error.BindingMismatch, inspect(std.testing.allocator, bytes, wrong));
    wrong = test_entry;
    wrong.private_depth_range_bytes = 8;
    try std.testing.expectError(error.PrivateDepthMismatch, inspect(std.testing.allocator, bytes, wrong));
}

test "inspection releases every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testInspectAllocation, .{});
}

const test_entry: manifest.Entry = .{
    .source = "test.wgsl",
    .output = "test.spv",
    .entry_point = "main",
    .stage = .compute,
    .workgroup_size = .{ 1, 1, 1 },
};

// Synthetic instructions test inspection only. They are not generated shader artifacts.
fn testComputeWords() [20]u32 {
    return .{
        0x07230203,     0x00010300,     0,  16,         0,
        (5 << 16) | 15, 5,              1,  0x6e69616d, 0,
        (6 << 16) | 16, 1,              17, 1,          1,
        1,              (4 << 16) | 21, 2,  32,         0,
    };
}

fn testInspectAllocation(allocator: std.mem.Allocator) !void {
    const words = testComputeWords();
    const bytes = try wordsToBytes(allocator, &words);
    defer allocator.free(bytes);
    try inspect(allocator, bytes, test_entry);
}

const Mode = enum { regen, check };
const max_file_bytes = 4 * 1024 * 1024;
const max_ids = 65536;
const max_type_depth = 32;
const max_bindings = 64;
const Error = error{
    OutOfMemory,
    WriteFailed,
    InvalidArguments,
    EmptyManifest,
    InvalidManifest,
    MissingTint,
    TintRevisionMismatch,
    SourceReadFailed,
    TintFailed,
    TemporaryDirectoryFailed,
    CleanupFailed,
    OutputWriteFailed,
    Drift,
    InvalidSpirv,
    EntryPointMismatch,
    WorkgroupMismatch,
    BindingMismatch,
    PrivateDepthMismatch,
    UnsupportedSchema,
};

fn parseMode(args: []const []const u8) Error!Mode {
    if (args.len != 2) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "--regen")) return .regen;
    if (std.mem.eql(u8, args[1], "--check")) return .check;
    return error.InvalidArguments;
}

pub fn main(init: std.process.Init) Error!void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return error.InvalidArguments;
    const mode = parseMode(args) catch |err| {
        diagnostic(init.io, "Use gen-native-kernels --regen or --check from the repository root.\n", .{});
        return err;
    };
    run(init.gpa, init.io, init.environ_map, mode) catch |err| {
        diagnostic(init.io, "Native kernel generation failed: {s}. No substitute output was generated.\n", .{@errorName(err)});
        return err;
    };
}

fn diagnostic(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    stderr.interface.print(format, args) catch |err| {
        std.debug.panic("Cannot write generator diagnostic: {s}", .{@errorName(err)});
    };
    stderr.interface.flush() catch |err| {
        std.debug.panic("Cannot flush generator diagnostic: {s}", .{@errorName(err)});
    };
}

const Generated = struct {
    bytes: []u8,
    source_hash: [64]u8,
    output_hash: [64]u8,
};

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    mode: Mode,
) Error!void {
    try validateManifest(manifest.entries);
    const tint = try requireTint(allocator, io, environment);
    const scratch = try makeScratch(allocator, io);
    defer allocator.free(scratch);
    var cleaned = false;
    defer if (!cleaned) {
        std.Io.Dir.cwd().deleteTree(io, scratch) catch |err| {
            diagnostic(io, "Remove temporary directory {s}: {s}.\n", .{ scratch, @errorName(err) });
        };
    };

    var generated: std.ArrayList(Generated) = .empty;
    defer {
        for (generated.items) |item| allocator.free(item.bytes);
        generated.deinit(allocator);
    }
    try generated.ensureTotalCapacity(allocator, manifest.entries.len);
    for (manifest.entries, 0..) |entry, index| {
        const source = try readSource(allocator, io, entry.source);
        defer allocator.free(source);
        const bytes = try generate(allocator, io, environment, .{
            .entry = entry,
            .index = index,
            .scratch = scratch,
            .tint = tint,
        });
        errdefer allocator.free(bytes);
        inspect(allocator, bytes, entry) catch |err| {
            diagnostic(io, "{s}: generated SPIR-V does not match its manifest ABI ({s}).\n", .{ entry.output, @errorName(err) });
            return err;
        };
        generated.appendAssumeCapacity(.{
            .bytes = bytes,
            .source_hash = hashBytes(source),
            .output_hash = hashBytes(bytes),
        });
    }
    const provenance = try renderProvenance(allocator, io, generated.items);
    defer allocator.free(provenance);

    // Complete generation and validation before any committed output changes.
    std.Io.Dir.cwd().deleteTree(io, scratch) catch |err| {
        diagnostic(io, "Cannot remove temporary directory {s}: {s}.\n", .{ scratch, @errorName(err) });
        return error.CleanupFailed;
    };
    cleaned = true;
    switch (mode) {
        .check => {
            var drift = false;
            for (manifest.entries, generated.items) |entry, item| {
                if (!try matchesFile(allocator, io, .cwd(), entry.output, item.bytes)) drift = true;
            }
            if (!try matchesFile(allocator, io, .cwd(), manifest.provenance_path, provenance)) drift = true;
            if (drift) {
                diagnostic(io, "Rebuild the generator, then run gen-native-kernels --regen with the pinned DUSK_TINT.\n", .{});
                return error.Drift;
            }
        },
        .regen => {
            for (manifest.entries, generated.items) |entry, item| {
                try replaceFile(io, entry.output, item.bytes);
            }
            try replaceFile(io, manifest.provenance_path, provenance);
        },
    }
}

fn validateManifest(entries: []const manifest.Entry) Error!void {
    if (entries.len == 0) return error.EmptyManifest;
    for (entries, 0..) |entry, index| {
        if (entry.source.len == 0 or entry.output.len == 0 or entry.entry_point.len == 0)
            return error.InvalidManifest;
        if (entry.private_depth_range_bytes != 0 and entry.private_depth_range_bytes != 8)
            return error.InvalidManifest;
        if (entry.stage == .compute) {
            for (entry.workgroup_size) |size| if (size == 0) return error.InvalidManifest;
        } else if (!std.mem.eql(u32, &entry.workgroup_size, &.{ 0, 0, 0 })) {
            return error.InvalidManifest;
        }
        if (std.mem.eql(u8, entry.source, entry.output) or
            std.mem.eql(u8, entry.output, manifest.provenance_path)) return error.InvalidManifest;
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, entry.output, previous.output) or
                std.mem.eql(u8, entry.source, previous.source) or
                std.mem.eql(u8, entry.output, previous.source) or
                std.mem.eql(u8, entry.source, previous.output)) return error.InvalidManifest;
        }
        if (entry.bindings.len > max_bindings) return error.InvalidManifest;
        for (entry.bindings, 0..) |binding, binding_index| {
            for (entry.bindings[0..binding_index]) |previous| {
                if (binding.binding == previous.binding) return error.InvalidManifest;
            }
        }
    }
}

fn readSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| {
        diagnostic(io, "Cannot read {s}: {s}.\n", .{ path, @errorName(err) });
        return if (err == error.OutOfMemory) error.OutOfMemory else error.SourceReadFailed;
    };
}

fn requireTint(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) Error!?[]const u8 {
    var needed = false;
    for (manifest.entries) |entry| if (entry.origin == .tint_wgsl) {
        needed = true;
    };
    if (!needed) return null;
    const tint = environment.get("DUSK_TINT") orelse {
        diagnostic(io, "Set DUSK_TINT to the Tint executable for Dawn revision {s}.\n", .{manifest.pin.revision});
        return error.MissingTint;
    };
    if (tint.len == 0) return error.MissingTint;
    const sidecar = try std.fmt.allocPrint(allocator, "{s}.revision", .{tint});
    defer allocator.free(sidecar);
    try requireRevision(allocator, io, .cwd(), sidecar);
    return tint;
}

fn makeScratch(allocator: std.mem.Allocator, io: std.Io) Error![]u8 {
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        std.Io.randomSecure(io, &random) catch return error.TemporaryDirectoryFailed;
        const path = try std.fmt.allocPrint(allocator, ".native-kernels-{s}", .{std.fmt.bytesToHex(random, .lower)});
        std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700)) catch |err| {
            allocator.free(path);
            if (err == error.PathAlreadyExists) continue;
            diagnostic(io, "Cannot create private generator directory: {s}.\n", .{@errorName(err)});
            return error.TemporaryDirectoryFailed;
        };
        return path;
    }
    return error.TemporaryDirectoryFailed;
}

const GenerateOptions = struct {
    entry: manifest.Entry,
    index: usize,
    scratch: []const u8,
    tint: ?[]const u8,
};

fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: GenerateOptions,
) Error![]u8 {
    if (options.entry.origin == .fixed_zig_spirv) {
        const words = try fixed_emitter.generate(allocator);
        defer allocator.free(words);
        return wordsToBytes(allocator, words);
    }
    const output = try std.fmt.allocPrint(allocator, "{s}/{d}.spv", .{ options.scratch, options.index });
    defer allocator.free(output);
    const result = std.process.run(allocator, io, .{
        .argv = &.{
            options.tint orelse return error.MissingTint,
            options.entry.source,
            "--format=spirv",
            "--ep",
            options.entry.entry_point,
            "-o",
            output,
        },
        .environ_map = environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        diagnostic(io, "Cannot run DUSK_TINT for {s}: {s}.\n", .{ options.entry.source, @errorName(err) });
        return if (err == error.OutOfMemory) error.OutOfMemory else error.TintFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) {
        diagnostic(io, "DUSK_TINT failed for {s}:\n{s}\n{s}\n", .{ options.entry.source, result.stderr, result.stdout });
        return error.TintFailed;
    }
    return readSource(allocator, io, output);
}

fn wordsToBytes(allocator: std.mem.Allocator, words: []const u32) Error![]u8 {
    if (words.len > max_file_bytes / 4) return error.InvalidSpirv;
    const bytes = try allocator.alloc(u8, words.len * 4);
    for (words, 0..) |word, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
    return bytes;
}

fn hashBytes(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn renderProvenance(
    allocator: std.mem.Allocator,
    io: std.Io,
    generated: []const Generated,
) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(@as(u32, 1));
    try json.objectField("pin");
    try json.write(.{ .url = manifest.pin.url, .revision = manifest.pin.revision });
    try json.objectField("generator_inputs");
    try json.beginArray();
    for ([_][]const u8{
        "tools/gen_native_kernels.zig",
        "tools/native_kernel_manifest.zig",
        "tools/native_kernel_sources.zig",
        "tools/native_ycbcr_spirv.zig",
        "tools/dawn_pin.zon",
    }) |path| {
        const source = try readSource(allocator, io, path);
        defer allocator.free(source);
        const hash = hashBytes(source);
        try json.write(.{ .source = path, .sha256 = hash[0..] });
    }
    try json.endArray();
    try json.objectField("kernels");
    try json.beginArray();
    for (manifest.entries, generated) |entry, item| {
        try json.write(.{
            .source = entry.source,
            .source_sha256 = item.source_hash[0..],
            .output = entry.output,
            .output_sha256 = item.output_hash[0..],
            .entry_point = entry.entry_point,
            .stage = entry.stage,
            .origin = entry.origin,
            .bindings = entry.bindings,
            .parameter_size = entry.parameter_size,
            .workgroup_size = entry.workgroup_size,
            .private_depth_range_bytes = entry.private_depth_range_bytes,
            .fixed_stencil_mask = entry.fixed_stencil_mask,
        });
    }
    try json.endArray();
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn matchesFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    expected: []const u8,
) Error!bool {
    const actual = directory.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) {
            diagnostic(io, "{s}: committed output is missing.\n", .{path});
            return false;
        }
        diagnostic(io, "Cannot compare {s}: {s}.\n", .{ path, @errorName(err) });
        return error.SourceReadFailed;
    };
    defer allocator.free(actual);
    if (std.mem.eql(u8, actual, expected)) return true;
    diagnostic(io, "{s}: committed bytes differ from generated bytes.\n", .{path});
    return false;
}

fn replaceFile(io: std.Io, path: []const u8, bytes: []const u8) Error!void {
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch |err| {
        diagnostic(io, "Cannot stage {s}: {s}.\n", .{ path, @errorName(err) });
        return error.OutputWriteFailed;
    };
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, bytes) catch return error.OutputWriteFailed;
    atomic.replace(io) catch |err| {
        diagnostic(io, "Cannot replace {s}: {s}.\n", .{ path, @errorName(err) });
        return error.OutputWriteFailed;
    };
}

const Node = struct {
    opcode: u16 = 0,
    operands: []const u32 = &.{},
    binding: ?u32 = null,
    group: ?u32 = null,
    stride: ?u32 = null,
    block: bool = false,
    buffer_block: bool = false,
    readonly: bool = false,
};

const Module = struct {
    words: []const u32,
    nodes: []Node,

    fn node(self: Module, id: u32) Error!*const Node {
        if (id == 0 or id >= self.nodes.len) return error.InvalidSpirv;
        return &self.nodes[id];
    }

    fn memberDecoration(self: Module, target: u32, member: u32, kind: u32) Error!?u32 {
        var result: ?u32 = null;
        var cursor: usize = 5;
        while (cursor < self.words.len) {
            const count: usize = self.words[cursor] >> 16;
            const opcode: u16 = @truncate(self.words[cursor]);
            const operands = self.words[cursor + 1 .. cursor + count];
            if (opcode == 72 and operands[0] == target and operands[1] == member and
                operands[2] == kind)
            {
                if (result != null) return error.InvalidSpirv;
                result = if (operands.len == 4) operands[3] else 1;
            }
            cursor += count;
        }
        return result;
    }
};

fn inspect(allocator: std.mem.Allocator, bytes: []const u8, entry: manifest.Entry) Error!void {
    if (bytes.len < 20 or bytes.len > max_file_bytes or bytes.len % 4 != 0)
        return error.InvalidSpirv;
    const words = try allocator.alloc(u32, bytes.len / 4);
    defer allocator.free(words);
    for (words, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    if (words[0] != 0x07230203 or words[1] < 0x00010000 or
        words[1] > 0x00010600 or words[1] & 0xff != 0 or words[4] != 0 or
        words[3] == 0 or words[3] > max_ids)
    {
        return error.InvalidSpirv;
    }
    const nodes = try allocator.alloc(Node, words[3]);
    defer allocator.free(nodes);
    @memset(nodes, .{});
    const module: Module = .{ .words = words, .nodes = nodes };
    var cursor: usize = 5;
    var entry_id: ?u32 = null;
    while (cursor < words.len) {
        const count: usize = words[cursor] >> 16;
        const opcode: u16 = @truncate(words[cursor]);
        if (count == 0 or count > words.len - cursor) return error.InvalidSpirv;
        const operands = words[cursor + 1 .. cursor + count];
        switch (opcode) {
            15 => {
                if (operands.len < 3 or entry_id != null) return error.EntryPointMismatch;
                const model: u32 = switch (entry.stage) {
                    .vertex => 0,
                    .fragment => 4,
                    .compute => 5,
                };
                if (operands[0] != model or !try nameMatches(operands[2..], entry.entry_point))
                    return error.EntryPointMismatch;
                if (operands[1] == 0 or operands[1] >= nodes.len) return error.InvalidSpirv;
                entry_id = operands[1];
            },
            16, 331 => if (operands.len < 2) return error.InvalidSpirv,
            17 => {
                if (operands.len != 1) return error.InvalidSpirv;
                if (std.mem.eql(u8, entry.entry_point, "timestamp_convert") and
                    (operands[0] == 10 or operands[0] == 11)) return error.UnsupportedSchema;
            },
            19...33, 43, 59 => {
                const result_index: usize = if (opcode == 43 or opcode == 59) 1 else 0;
                if (operands.len <= result_index) return error.InvalidSpirv;
                const id = operands[result_index];
                if (id == 0 or id >= nodes.len or nodes[id].opcode != 0)
                    return error.InvalidSpirv;
                nodes[id].opcode = opcode;
                nodes[id].operands = operands;
            },
            71 => try decorate(nodes, operands),
            72 => {
                if (operands.len < 3 or operands.len > 4) return error.InvalidSpirv;
                if (operands[0] == 0 or operands[0] >= nodes.len) return error.InvalidSpirv;
                if ((operands[2] == 35 or operands[2] == 7) and operands.len != 4)
                    return error.InvalidSpirv;
            },
            // Decoration groups are not used by these generators. Do not silently skip their ABI.
            73...75 => return error.UnsupportedSchema,
            else => {},
        }
        cursor += count;
    }
    const selected = entry_id orelse return error.EntryPointMismatch;
    try checkWorkgroup(module, selected, entry);
    try checkBindings(module, entry);
    try checkPrivateDepth(module, entry.private_depth_range_bytes);
}

fn nameMatches(words: []const u32, expected: []const u8) Error!bool {
    var index: usize = 0;
    for (words) |word| {
        for (0..4) |byte_index| {
            const byte: u8 = @truncate(word >> @as(u5, @intCast(byte_index * 8)));
            if (byte == 0) {
                const trailing_mask: u32 = if (byte_index == 3)
                    0
                else
                    @as(u32, std.math.maxInt(u32)) << @as(u5, @intCast((byte_index + 1) * 8));
                if (word & trailing_mask != 0) return error.InvalidSpirv;
                return index == expected.len;
            }
            if (index >= expected.len or expected[index] != byte) return false;
            index += 1;
        }
    }
    return error.InvalidSpirv;
}

fn decorate(nodes: []Node, operands: []const u32) Error!void {
    if (operands.len < 2 or operands[0] == 0 or operands[0] >= nodes.len)
        return error.InvalidSpirv;
    const target = &nodes[operands[0]];
    switch (operands[1]) {
        2 => target.block = true,
        3 => target.buffer_block = true,
        24 => target.readonly = true,
        6, 33, 34 => {
            if (operands.len != 3) return error.InvalidSpirv;
            const slot = switch (operands[1]) {
                6 => &target.stride,
                33 => &target.binding,
                34 => &target.group,
                else => return error.InvalidSpirv,
            };
            if (slot.* != null) return error.InvalidSpirv;
            slot.* = operands[2];
        },
        else => {},
    }
}

fn scalarConstant(module: Module, id: u32) Error!u32 {
    const value = try module.node(id);
    if (value.opcode != 43 or value.operands.len != 3) return error.UnsupportedSchema;
    const scalar = try module.node(value.operands[0]);
    if (scalar.opcode != 21 or scalar.operands.len != 3 or scalar.operands[1] != 32)
        return error.UnsupportedSchema;
    return value.operands[2];
}

fn checkWorkgroup(module: Module, selected: u32, entry: manifest.Entry) Error!void {
    var found = false;
    var cursor: usize = 5;
    while (cursor < module.words.len) {
        const count: usize = module.words[cursor] >> 16;
        const opcode: u16 = @truncate(module.words[cursor]);
        const operands = module.words[cursor + 1 .. cursor + count];
        if ((opcode == 16 or opcode == 331) and operands[0] == selected and
            (operands[1] == 17 or operands[1] == 38))
        {
            if (found or operands.len != 5 or entry.stage != .compute)
                return error.WorkgroupMismatch;
            if ((opcode == 16 and operands[1] != 17) or
                (opcode == 331 and operands[1] != 38)) return error.UnsupportedSchema;
            var actual: [3]u32 = undefined;
            for (&actual, operands[2..]) |*value, operand| {
                value.* = if (opcode == 331) try scalarConstant(module, operand) else operand;
            }
            if (!std.mem.eql(u32, &actual, &entry.workgroup_size))
                return error.WorkgroupMismatch;
            found = true;
        }
        cursor += count;
    }
    if ((entry.stage == .compute) != found) return error.WorkgroupMismatch;
}

fn pointee(module: Module, variable: Node) Error!*const Node {
    if (variable.operands.len < 3) return error.InvalidSpirv;
    const pointer = try module.node(variable.operands[0]);
    if (pointer.opcode != 32 or pointer.operands.len != 3 or
        pointer.operands[1] != variable.operands[2]) return error.InvalidSpirv;
    return module.node(pointer.operands[2]);
}

fn checkBindings(module: Module, entry: manifest.Entry) Error!void {
    if (entry.bindings.len > max_bindings) return error.BindingMismatch;
    var found_count: usize = 0;
    var seen: [max_bindings]bool = @splat(false);
    for (module.nodes) |variable| {
        if (variable.opcode != 59) {
            if (variable.binding != null or variable.group != null) return error.BindingMismatch;
            continue;
        }
        if (variable.operands.len < 3) return error.InvalidSpirv;
        const storage = variable.operands[2];
        const descriptor = storage == 0 or storage == 2 or storage == 12;
        if (!descriptor) {
            if (variable.binding != null or variable.group != null) return error.BindingMismatch;
            continue;
        }
        const binding = variable.binding orelse return error.BindingMismatch;
        const group = variable.group orelse return error.BindingMismatch;
        if (group != 0) return error.BindingMismatch;
        const binding_index = for (entry.bindings, 0..) |expected, index| {
            if (expected.binding == binding) break index;
        } else return error.BindingMismatch;
        if (seen[binding_index]) return error.BindingMismatch;
        seen[binding_index] = true;
        const actual = try bindingSchema(module, variable);
        const expected = entry.bindings[binding_index];
        if (actual.kind != expected.kind)
            return error.BindingMismatch;
        const target = try pointee(module, variable);
        const runtime_array = try hasRuntimeArray(module, target.operands[0], 0);
        const minimum_matches = if (runtime_array and actual.kind != .uniform)
            expected.min_size >= actual.min_size
        else
            expected.min_size == actual.min_size;
        if (!minimum_matches or
            actual.dimension != expected.dimension or actual.multisampled != expected.multisampled)
            return error.BindingMismatch;
        if (expected.uniform_words.len != 0) {
            if (actual.kind != .uniform) return error.BindingMismatch;
            try checkUniformWords(module, target.operands[0], expected.uniform_words);
        }
        found_count += 1;
    }
    if (found_count != entry.bindings.len) return error.BindingMismatch;
}

fn bindingSchema(module: Module, variable: Node) Error!manifest.Binding {
    const target = try pointee(module, variable);
    var result: manifest.Binding = .{ .binding = variable.binding.?, .kind = .uniform };
    const storage = variable.operands[2];
    if (storage == 2 or storage == 12) {
        if (target.opcode != 30 or (!target.block and !target.buffer_block))
            return error.UnsupportedSchema;
        const is_storage = storage == 12 or target.buffer_block;
        var readonly = variable.readonly or target.readonly;
        if (!readonly and is_storage) {
            readonly = target.operands.len > 1;
            for (target.operands[1..], 0..) |_, index| {
                if (try module.memberDecoration(target.operands[0], @intCast(index), 24) == null)
                    readonly = false;
            }
        }
        result.kind = if (!is_storage) .uniform else if (readonly) .storage_read else .storage_write;
        result.min_size = try typeSize(module, target.operands[0], .{});
        return result;
    }
    if (target.opcode == 26) {
        if (target.operands.len != 1) return error.InvalidSpirv;
        result.kind = .sampler;
        return result;
    }
    var image = target;
    const combined = target.opcode == 27;
    if (combined) {
        if (target.operands.len != 2) return error.InvalidSpirv;
        image = try module.node(target.operands[1]);
    }
    if (image.opcode != 25 or image.operands.len < 8) return error.UnsupportedSchema;
    const operands = image.operands;
    if (operands[6] != 1 or operands[3] > 1 or operands[4] > 1 or operands[5] > 1)
        return error.UnsupportedSchema;
    const scalar = try module.node(operands[1]);
    if (scalar.operands.len < 2 or scalar.operands[1] != 32) return error.UnsupportedSchema;
    result.kind = switch (scalar.opcode) {
        22 => if (operands[3] == 1) .sampled_depth else .sampled_float,
        21 => if (scalar.operands.len != 3) return error.InvalidSpirv else if (scalar.operands[2] == 1) .sampled_sint else .sampled_uint,
        else => return error.UnsupportedSchema,
    };
    result.dimension = switch (operands[2]) {
        0 => if (operands[4] == 0) .d1 else return error.UnsupportedSchema,
        1 => if (operands[4] == 1) .d2_array else .d2,
        2 => if (operands[4] == 0) .d3 else return error.UnsupportedSchema,
        else => return error.UnsupportedSchema,
    };
    result.multisampled = operands[5] == 1;
    if (combined) {
        if (result.kind != .sampled_float or result.dimension != .d2 or result.multisampled)
            return error.UnsupportedSchema;
        result.kind = .combined_y_cb_cr;
    }
    return result;
}

const SizeOptions = struct {
    depth: usize = 0,
    matrix_stride: ?u32 = null,
};

fn checkedProduct(a: u32, b: u32) Error!u32 {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0 or result[0] > max_file_bytes) return error.UnsupportedSchema;
    return result[0];
}

fn typeSize(module: Module, id: u32, options: SizeOptions) Error!u32 {
    if (options.depth >= max_type_depth) return error.UnsupportedSchema;
    const target = try module.node(id);
    const operands = target.operands;
    const next: SizeOptions = .{ .depth = options.depth + 1 };
    switch (target.opcode) {
        21, 22 => {
            if (operands.len < 2 or operands[1] != 32) return error.UnsupportedSchema;
            return 4;
        },
        23 => {
            if (operands.len != 3) return error.InvalidSpirv;
            return checkedProduct(try typeSize(module, operands[1], next), operands[2]);
        },
        24 => {
            if (operands.len != 3) return error.InvalidSpirv;
            const stride = options.matrix_stride orelse return error.UnsupportedSchema;
            const column_bytes = try typeSize(module, operands[1], next);
            if (stride < column_bytes) return error.UnsupportedSchema;
            return checkedProduct(stride, operands[2]);
        },
        28, 29 => {
            if (operands.len != (if (target.opcode == 28) @as(usize, 3) else 2))
                return error.InvalidSpirv;
            const stride = target.stride orelse return error.UnsupportedSchema;
            const element_bytes = try typeSize(module, operands[1], .{
                .depth = next.depth,
                .matrix_stride = options.matrix_stride,
            });
            if (stride < element_bytes) return error.UnsupportedSchema;
            const length = if (target.opcode == 28) try scalarConstant(module, operands[2]) else 1;
            if (length == 0) return error.UnsupportedSchema;
            // Runtime arrays require at least one element in WebGPU minimum binding size.
            return checkedProduct(stride, length);
        },
        30 => {
            if (operands.len > 65) return error.UnsupportedSchema;
            var end: u32 = 0;
            for (operands[1..], 0..) |member, index| {
                const offset = try module.memberDecoration(id, @intCast(index), 35) orelse
                    return error.UnsupportedSchema;
                if (try module.memberDecoration(id, @intCast(index), 4) != null)
                    return error.UnsupportedSchema;
                const member_size = try typeSize(module, member, .{
                    .depth = next.depth,
                    .matrix_stride = try module.memberDecoration(id, @intCast(index), 7),
                });
                if (offset < end or offset > max_file_bytes - member_size)
                    return error.UnsupportedSchema;
                end = offset + member_size;
            }
            return end;
        },
        else => return error.UnsupportedSchema,
    }
}

fn checkPrivateDepth(module: Module, expected_bytes: u32) Error!void {
    var count: usize = 0;
    for (module.nodes) |variable| {
        if (variable.opcode != 59) continue;
        if (variable.operands.len < 3) return error.InvalidSpirv;
        if (variable.operands[2] != 9) continue;
        count += 1;
        if (count > 1 or expected_bytes != 8) return error.PrivateDepthMismatch;
        const target = try pointee(module, variable);
        if (target.opcode != 30 or target.operands.len != 2 or
            !target.block or target.buffer_block) return error.PrivateDepthMismatch;
        const offset = try module.memberDecoration(target.operands[0], 0, 35);
        if (offset == null or offset.? != 0) return error.PrivateDepthMismatch;
        const words = try module.node(target.operands[1]);
        if (words.opcode != 28 or words.operands.len != 3 or words.stride != 4)
            return error.PrivateDepthMismatch;
        const scalar = try module.node(words.operands[1]);
        if (scalar.opcode != 21 or scalar.operands.len != 3 or
            scalar.operands[1] != 32 or scalar.operands[2] != 0)
            return error.PrivateDepthMismatch;
        const length = try module.node(words.operands[2]);
        if (length.opcode != 43 or length.operands.len != 3 or
            length.operands[0] != words.operands[1] or length.operands[2] != 2)
            return error.PrivateDepthMismatch;
        if (try typeSize(module, target.operands[0], .{}) != 8)
            return error.PrivateDepthMismatch;
    }
    if ((expected_bytes == 8) != (count == 1)) return error.PrivateDepthMismatch;
}

test "uniform schema verifies each scalar lane, not only buffer size" {
    const words = testComputeWords() ++ [_]u32{
        (3 << 16) | 71, 4,              2,
        (4 << 16) | 71, 6,              33,
        0,              (4 << 16) | 71, 6,
        34,             0,              (5 << 16) | 72,
        4,              0,              35,
        0,              (5 << 16) | 72, 4,
        1,              35,             4,
        (3 << 16) | 22, 3,              32,
        (4 << 16) | 30, 4,              2,
        3,              (4 << 16) | 32, 5,
        2,              4,              (4 << 16) | 59,
        5,              6,              2,
    };
    const bytes = try wordsToBytes(std.testing.allocator, &words);
    defer std.testing.allocator.free(bytes);
    var entry = test_entry;
    entry.bindings = &.{.{
        .binding = 0,
        .kind = .uniform,
        .min_size = 8,
        .uniform_words = &.{ .u32, .f32 },
    }};
    try inspect(std.testing.allocator, bytes, entry);
    entry.bindings = &.{.{
        .binding = 0,
        .kind = .uniform,
        .min_size = 8,
        .uniform_words = &.{ .f32, .u32 },
    }};
    try std.testing.expectError(error.BindingMismatch, inspect(std.testing.allocator, bytes, entry));
}

test "private depth rejects the obsolete direct two f32 member shape" {
    const words = testComputeWords() ++ [_]u32{
        (3 << 16) | 71, 4,              2,
        (5 << 16) | 72, 4,              0,
        35,             0,              (5 << 16) | 72,
        4,              1,              35,
        4,              (3 << 16) | 22, 3,
        32,             (4 << 16) | 30, 4,
        3,              3,              (4 << 16) | 32,
        5,              9,              4,
        (4 << 16) | 59, 5,              6,
        9,
    };
    var entry = test_entry;
    entry.private_depth_range_bytes = 8;
    const bytes = try wordsToBytes(std.testing.allocator, &words);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.PrivateDepthMismatch, inspect(std.testing.allocator, bytes, entry));
}

const UniformWord = std.meta.Child(@TypeOf(@as(manifest.Binding, undefined).uniform_words));

fn hasRuntimeArray(module: Module, id: u32, depth: usize) Error!bool {
    if (depth >= max_type_depth) return error.UnsupportedSchema;
    const target = try module.node(id);
    if (target.opcode == 29) return true;
    if (target.opcode == 28) {
        if (target.operands.len != 3) return error.InvalidSpirv;
        return hasRuntimeArray(module, target.operands[1], depth + 1);
    }
    if (target.opcode == 30) {
        for (target.operands[1..]) |member| {
            if (try hasRuntimeArray(module, member, depth + 1)) return true;
        }
    }
    return false;
}

fn checkUniformWords(module: Module, id: u32, expected: []const UniformWord) Error!void {
    const max_uniform_words = 1024;
    if (expected.len > max_uniform_words) return error.UnsupportedSchema;
    var buffer: [max_uniform_words]UniformWord = @splat(.padding);
    const actual = buffer[0..expected.len];
    try scalarFootprint(module, id, actual, .{});
    if (!std.mem.eql(UniformWord, actual, expected)) return error.BindingMismatch;
}

const FootprintOptions = struct {
    offset: u32 = 0,
    depth: usize = 0,
    matrix_stride: ?u32 = null,
};

fn scalarFootprint(
    module: Module,
    id: u32,
    actual: []UniformWord,
    options: FootprintOptions,
) Error!void {
    if (options.depth >= max_type_depth) return error.UnsupportedSchema;
    const target = try module.node(id);
    const operands = target.operands;
    var next: FootprintOptions = .{
        .offset = options.offset,
        .depth = options.depth + 1,
        .matrix_stride = options.matrix_stride,
    };
    switch (target.opcode) {
        21, 22 => {
            if (operands.len < 2 or operands[1] != 32 or options.offset % 4 != 0)
                return error.UnsupportedSchema;
            const index = options.offset / 4;
            if (index >= actual.len or actual[index] != .padding) return error.BindingMismatch;
            if (target.opcode == 21 and (operands.len != 3 or operands[2] != 0))
                return error.UnsupportedSchema;
            actual[index] = if (target.opcode == 22) .f32 else .u32;
        },
        23, 24, 28 => {
            if (operands.len != 3) return error.InvalidSpirv;
            const length = if (target.opcode == 28)
                try scalarConstant(module, operands[2])
            else
                operands[2];
            const stride = switch (target.opcode) {
                23 => try typeSize(module, operands[1], .{}),
                24 => options.matrix_stride orelse return error.UnsupportedSchema,
                28 => target.stride orelse return error.UnsupportedSchema,
                else => return error.UnsupportedSchema,
            };
            if (length > actual.len) return error.UnsupportedSchema;
            for (0..length) |index| {
                const displacement = try checkedProduct(@intCast(index), stride);
                if (options.offset > max_file_bytes - displacement) return error.UnsupportedSchema;
                next.offset = options.offset + displacement;
                try scalarFootprint(module, operands[1], actual, next);
            }
        },
        30 => {
            if (operands.len > 65) return error.UnsupportedSchema;
            for (operands[1..], 0..) |member, index| {
                const offset = try module.memberDecoration(id, @intCast(index), 35) orelse
                    return error.UnsupportedSchema;
                if (offset > max_file_bytes or options.offset > max_file_bytes - offset)
                    return error.UnsupportedSchema;
                next.offset = options.offset + offset;
                next.matrix_stride = try module.memberDecoration(id, @intCast(index), 7);
                try scalarFootprint(module, member, actual, next);
            }
        },
        else => return error.UnsupportedSchema,
    }
}

test "pin sidecar must exist and match the exact revision" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.expectError(error.TintRevisionMismatch, requireRevision(std.testing.allocator, std.testing.io, temporary.dir, "tint.revision"));
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "tint.revision",
        .data = "wrong-revision\n",
    });
    try std.testing.expectError(error.TintRevisionMismatch, requireRevision(std.testing.allocator, std.testing.io, temporary.dir, "tint.revision"));
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "tint.revision",
        .data = manifest.pin.revision ++ "\n",
    });
    try requireRevision(std.testing.allocator, std.testing.io, temporary.dir, "tint.revision");
}

test "manifest rejects duplicate outputs and source output aliasing" {
    try std.testing.expectError(error.InvalidManifest, validateManifest(&.{ test_entry, test_entry }));
    var alias = test_entry;
    alias.output = alias.source;
    try std.testing.expectError(error.InvalidManifest, validateManifest(&.{alias}));
    try validateManifest(manifest.entries);
}

test "check comparison detects drift without replacing or creating files" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "committed",
        .data = "committed bytes",
    });
    try std.testing.expect(!try matchesFile(std.testing.allocator, std.testing.io, temporary.dir, "committed", "generated bytes"));
    const actual = try temporary.dir.readFileAlloc(std.testing.io, "committed", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("committed bytes", actual);
    try std.testing.expect(!try matchesFile(std.testing.allocator, std.testing.io, temporary.dir, "missing", "generated bytes"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.openFile(std.testing.io, "missing", .{}));
}

test "source and output drift change provenance even when ABI stays fixed" {
    const allocator = std.testing.allocator;
    const records = try allocator.alloc(Generated, manifest.entries.len);
    defer allocator.free(records);
    for (records) |*record| record.* = .{
        .bytes = &.{},
        .source_hash = hashBytes("source"),
        .output_hash = hashBytes("output"),
    };
    const baseline = try renderProvenance(allocator, std.testing.io, records);
    defer allocator.free(baseline);
    const repeated = try renderProvenance(allocator, std.testing.io, records);
    defer allocator.free(repeated);
    try std.testing.expectEqualSlices(u8, baseline, repeated);
    records[0].source_hash = hashBytes("changed source");
    const changed_source = try renderProvenance(allocator, std.testing.io, records);
    defer allocator.free(changed_source);
    try std.testing.expect(!std.mem.eql(u8, baseline, changed_source));
    records[0].source_hash = hashBytes("source");
    records[0].output_hash = hashBytes("changed output");
    const changed_output = try renderProvenance(allocator, std.testing.io, records);
    defer allocator.free(changed_output);
    try std.testing.expect(!std.mem.eql(u8, baseline, changed_output));
}

test "actual committed artifacts match every manifest ABI" {
    for (manifest.entries) |entry| {
        const bytes = try readSource(std.testing.allocator, std.testing.io, entry.output);
        defer std.testing.allocator.free(bytes);
        try inspect(std.testing.allocator, bytes, entry);
        if (std.mem.eql(u8, entry.entry_point, "timestamp_convert"))
            try rejectWideCapabilities(bytes);
    }
}

fn requireRevision(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) Error!void {
    const revision = directory.readFileAlloc(io, path, allocator, .limited(1024)) catch |err| {
        diagnostic(io, "Cannot read {s}: {s}. Supply the pinned Tint revision sidecar.\n", .{ path, @errorName(err) });
        return if (err == error.OutOfMemory) error.OutOfMemory else error.TintRevisionMismatch;
    };
    defer allocator.free(revision);
    if (!std.mem.eql(u8, std.mem.trim(u8, revision, " \t\r\n"), manifest.pin.revision)) {
        diagnostic(io, "{s} must contain exactly Dawn revision {s}.\n", .{ path, manifest.pin.revision });
        return error.TintRevisionMismatch;
    }
}

fn rejectWideCapabilities(bytes: []const u8) Error!void {
    var cursor: usize = 20;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 4) return error.InvalidSpirv;
        const instruction = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        const count: usize = instruction >> 16;
        if (count == 0 or count > (bytes.len - cursor) / 4) return error.InvalidSpirv;
        if (@as(u16, @truncate(instruction)) == 17) {
            if (count != 2) return error.InvalidSpirv;
            const capability = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
            if (capability == 10 or capability == 11) return error.UnsupportedSchema;
        }
        cursor += count * 4;
    }
}

test "fixed manifest rejects duplicate sources with different output names" {
    var duplicate_source = test_entry;
    duplicate_source.output = "other.spv";
    try std.testing.expectError(error.InvalidManifest, validateManifest(&.{ test_entry, duplicate_source }));
}

test "actual depth load artifact uses strict physical float image ABI" {
    const output_path = "src/engine/shaders/texture_to_buffer_depth_2d.comp.spv";
    var entry = for (manifest.entries) |candidate| {
        if (std.mem.eql(u8, candidate.output, output_path)) break candidate;
    } else return error.InvalidManifest;
    const bytes = try readSource(std.testing.allocator, std.testing.io, output_path);
    defer std.testing.allocator.free(bytes);
    try inspect(std.testing.allocator, bytes, entry);
    const binding_index = for (entry.bindings, 0..) |binding, index| {
        if (binding.binding == 0) break index;
    } else return error.InvalidManifest;
    const original = entry.bindings[binding_index];
    try std.testing.expectEqual(manifest.BindingKind.sampled_float, original.kind);
    try std.testing.expect(original.dimension == .d2);
    try std.testing.expect(!original.multisampled);
    const bindings = try std.testing.allocator.dupe(manifest.Binding, entry.bindings);
    defer std.testing.allocator.free(bindings);
    entry.bindings = bindings;

    bindings[binding_index].kind = .sampled_depth;
    try std.testing.expectError(error.BindingMismatch, inspect(std.testing.allocator, bytes, entry));
    bindings[binding_index] = original;
    bindings[binding_index].kind = .sampled_uint;
    try std.testing.expectError(error.BindingMismatch, inspect(std.testing.allocator, bytes, entry));
    bindings[binding_index] = original;
    bindings[binding_index].dimension = .d2_array;
    try std.testing.expectError(error.BindingMismatch, inspect(std.testing.allocator, bytes, entry));
    bindings[binding_index] = original;
    bindings[binding_index].multisampled = true;
    try std.testing.expectError(error.BindingMismatch, inspect(std.testing.allocator, bytes, entry));
}

test "private depth accepts only the pinned eight byte raw word ABI" {
    // Decoder fixture follows the captured Tint block shape, not an emitted shader.
    const words = testComputeWords() ++ [_]u32{
        (3 << 16) | 71, 4,              2,
        (5 << 16) | 72, 4,              0,
        35,             0,              (4 << 16) | 71,
        3,              6,              4,
        (4 << 16) | 43, 2,              5,
        2,              (4 << 16) | 28, 3,
        2,              5,              (3 << 16) | 30,
        4,              3,              (4 << 16) | 32,
        6,              9,              4,
        (4 << 16) | 59, 6,              7,
        9,
    };
    var entry = test_entry;
    entry.private_depth_range_bytes = 8;
    const bytes = try wordsToBytes(std.testing.allocator, &words);
    defer std.testing.allocator.free(bytes);
    try inspect(std.testing.allocator, bytes, entry);

    const Mutate = struct { index: usize, value: u32 };
    for ([_]Mutate{
        .{ .index = 27, .value = 4 }, // Root member offset.
        .{ .index = 31, .value = 8 }, // Array stride.
        .{ .index = 35, .value = 1 }, // Array length.
        .{ .index = 35, .value = 3 },
        .{ .index = 19, .value = 1 }, // Signed rather than unsigned scalar.
    }) |mutation| {
        var wrong_words = words;
        wrong_words[mutation.index] = mutation.value;
        const wrong_bytes = try wordsToBytes(std.testing.allocator, &wrong_words);
        defer std.testing.allocator.free(wrong_bytes);
        try std.testing.expectError(error.PrivateDepthMismatch, inspect(std.testing.allocator, wrong_bytes, entry));
    }
    var floating_words = words ++ [_]u32{ (3 << 16) | 22, 8, 32 };
    floating_words[38] = 8;
    const floating_bytes = try wordsToBytes(std.testing.allocator, &floating_words);
    defer std.testing.allocator.free(floating_bytes);
    try std.testing.expectError(error.PrivateDepthMismatch, inspect(std.testing.allocator, floating_bytes, entry));
}

test "actual buffer to depth artifact requires the eight byte private range" {
    const output_path = "src/engine/shaders/buffer_to_depth.frag.spv";
    var entry = for (manifest.entries) |candidate| {
        if (std.mem.eql(u8, candidate.output, output_path)) break candidate;
    } else return error.InvalidManifest;
    try std.testing.expectEqual(@as(u32, 8), entry.private_depth_range_bytes);
    const bytes = try readSource(std.testing.allocator, std.testing.io, output_path);
    defer std.testing.allocator.free(bytes);
    try inspect(std.testing.allocator, bytes, entry);
    for ([_]u32{ 0, 4, 12 }) |wrong_bytes| {
        entry.private_depth_range_bytes = wrong_bytes;
        try std.testing.expectError(error.PrivateDepthMismatch, inspect(std.testing.allocator, bytes, entry));
    }
}

test "actual ordinary external artifact requires exact unsigned uniform transport lanes" {
    const allocator = std.testing.allocator;
    const output_path = "src/engine/shaders/external_ordinary.frag.spv";
    var entry = for (manifest.entries) |candidate| {
        if (std.mem.eql(u8, candidate.output, output_path)) break candidate;
    } else return error.InvalidManifest;
    const bytes = try readSource(allocator, std.testing.io, output_path);
    defer allocator.free(bytes);
    try inspect(allocator, bytes, entry);
    const bindings = try allocator.dupe(manifest.Binding, entry.bindings);
    defer allocator.free(bindings);
    entry.bindings = bindings;

    const ExpectedTransport = struct {
        binding: u32,
        word_count: usize,
        min_size: u32,
        first_mismatched_lane: usize,
    };
    for ([_]ExpectedTransport{
        .{ .binding = 3, .word_count = 72, .min_size = 288, .first_mismatched_lane = 2 },
        .{ .binding = 4, .word_count = 40, .min_size = 160, .first_mismatched_lane = 0 },
    }) |transport| {
        const binding_index = for (bindings, 0..) |binding, index| {
            if (binding.binding == transport.binding) break index;
        } else return error.InvalidManifest;
        const original = bindings[binding_index];
        try std.testing.expectEqual(manifest.BindingKind.uniform, original.kind);
        try std.testing.expectEqual(transport.min_size, original.min_size);
        try std.testing.expectEqual(transport.word_count, original.uniform_words.len);
        for (original.uniform_words) |word| try std.testing.expect(word == .u32);

        const expected_words = try allocator.dupe(UniformWord, original.uniform_words);
        defer allocator.free(expected_words);
        bindings[binding_index].uniform_words = expected_words;
        for ([_]UniformWord{ .f32, .padding }) |wrong_scalar| {
            expected_words[transport.first_mismatched_lane] = wrong_scalar;
            try std.testing.expectError(error.BindingMismatch, inspect(allocator, bytes, entry));
        }
        bindings[binding_index] = original;
    }
}
