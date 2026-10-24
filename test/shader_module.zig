//! The M13 shard: two checked-in fixtures through `createShaderModule`.
//!
//! **What this shard asserts.** The `VkShaderModule` handle is
//! non-null, `getCompilationInfo()` reports 0 errors and 0 warnings, the
//! reflected layout carries the one descriptor `triangle.frag.wgsl` declares,
//! and the words the module holds are the input file word for word.
//!
//! **Why comparing `module.words` compares the driver's bytes.**
//! `src/pipeline/shader_module_vk.zig:102`-`:103` builds `codeSize` and `pCode`
//! out of the slice `createShaderModule` was handed, and
//! `src/pipeline/shader_module.zig:308` hands it the same slice it then stores
//! in `ShaderModule.words`. A port that regenerated the binary through a
//! writer — what Dawn does at
//! `src/dawn/native/vulkan/ShaderModuleVk.cpp:429` — fails the word comparison
//! and no other assertion here would notice.
//!
//! **Why this shard brings a device up.** The Vulkan handle is half of what
//! the milestone claims, so the seam cannot be two null procs for these two
//! tests. That is the third test, and it asserts the failure the seam reports
//! instead. `test/vulkan_device.zig` is the M9 shard that brings the device
//! up; this one repeats its four-line sequence and asserts no more.
//!
//! **What this file does not claim.** It claims no pipeline: nothing here
//! creates one and M14 owns that. It claims no M12 bind group layout object.
//! What it claims is the layout the module *reflected*, which is what M14's
//! `ValidateCompatibilityWithPipelineLayout`
//! (`src/dawn/native/ShaderModule.cpp:1576`) compares a layout against. The
//! layout object and its `isLayoutEqual` belong to the M12 shard.
//!
//! **Every name comes from `@import("dusk")`.** The published module re-exports
//! `pipeline` (`src/root.zig:62`) and `engine` (`:60`), and `engine` re-exports
//! `vulkan_device.zig` (`src/engine/root.zig:115`), so the Vulkan device the
//! handle assertion needs is reached the same way as the module itself. The
//! shard names no Vulkan type, so it needs no `vulkan` import of its own.

const std = @import("std");
const dusk = @import("dusk");

const engine = dusk.engine;
const shader_module = dusk.pipeline.shader_module;
const shader_module_vk = dusk.pipeline.shader_module_vk;
const spirv = dusk.spirv;
const vulkan_device = engine.vulkan_device;

const Word = spirv.Word;
const MessageType = shader_module.MessageType;

/// The fixtures are generated from the checked-in `.wgsl`, never hand-written.
const vertex_fixture: []const u8 = @embedFile("fixtures/triangle.vert.spv");
const fragment_fixture: []const u8 = @embedFile("fixtures/triangle.frag.spv");

/// One descriptor the reflection is expected to have read out of the binary.
const Declared = struct {
    set: u32,
    binding: u32,
    kind: spirv.ResourceKind,
    image_dimension: ?spirv.Dim = null,
    image_depth_mode: ?u32 = null,
    sampled_scalar: ?spirv.ScalarType = null,
    image_format: ?u32 = null,
    buffer_read_only: ?bool = null,
};

/// What one fixture declares, so the assertions below read as the milestone's
/// sentence instead of as a loop over two cases with a branch in it.
const Fixture = struct {
    label: []const u8,
    bytes: []const u8,
    entry_point: []const u8,
    stage: spirv.ExecutionModel,

    /// Expected descriptor when resource layout checks are enabled.
    /// Null then expects no descriptors, as in the vertex fixture.
    declared: ?Declared,
    check_resource_layout: bool = true,
    has_specialization: bool = false,
    specialization_count: ?usize = null,
};

const vertex: Fixture = .{
    .label = "triangle.vert.spv",
    .bytes = vertex_fixture,
    .entry_point = "vs_main",
    .stage = .vertex,
    .declared = null,
};

const fragment: Fixture = .{
    .label = "triangle.frag.spv",
    .bytes = fragment_fixture,
    .entry_point = "fs_main",
    .stage = .fragment,
    .declared = .{ .set = 0, .binding = 1, .kind = .uniform_buffer },
};

// ---------------------------------------------------------------------------
// The acceptance: two fixtures, two modules.
// ---------------------------------------------------------------------------

test "test-shader-module: the vertex fixture is a module with a handle and no diagnostics" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try expectCreatedFrom(vertex, threaded.io());
}

test "test-shader-module: the fragment fixture carries the one descriptor it declares" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try expectCreatedFrom(fragment, threaded.io());
}

// ---------------------------------------------------------------------------
// The failure half: the seam without the two core 1.0 entry points.
// ---------------------------------------------------------------------------

test "test-shader-module: a device tier without the shader-module entry points is refused" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const words = try loadFixture(std.testing.allocator, vertex_fixture);
    defer std.testing.allocator.free(words);

    // Both entry points or neither (`src/pipeline/shader_module_vk.zig:61`-
    // `:66`): a device with one of the two is a broken loader, so the seam
    // answers null rather than creating a module it could not destroy.
    const seam: shader_module.Device = .{
        .handle = null,
        .api_version = (@as(u32, 1) << 22) | (3 << 12),
        .create_shader_module = null,
        .destroy_shader_module = null,
    };

    var future = try shader_module.createShaderModule(std.testing.allocator, io, &seam, .{
        .words = words,
    });
    try std.testing.expectError(error.MissingShaderModuleProc, future.await(io));
}

test "test-shader-module: core Vulkan versions bound SPIR-V before the native call" {
    // Null procs distinguish an accepted version from rejection before dispatch.
    const cases = [_]struct { api_version: u32, max_minor: u8 }{
        .{ .api_version = (@as(u32, 1) << 22) | (1 << 12), .max_minor = 3 },
        .{ .api_version = (@as(u32, 1) << 22) | (2 << 12), .max_minor = 5 },
        .{ .api_version = (@as(u32, 1) << 22) | (3 << 12), .max_minor = 6 },
    };
    for (cases) |case| {
        const seam: shader_module.Device = .{
            .handle = null,
            .api_version = case.api_version,
            .create_shader_module = null,
            .destroy_shader_module = null,
        };
        var words = [_]Word{ spirv.magic_number, 0, 0, 1, 0 };
        for (0..7) |minor| {
            words[1] = 0x0001_0000 | (@as(u32, @intCast(minor)) << 8);
            const expected = if (minor <= case.max_minor)
                error.MissingShaderModuleProc
            else
                error.SpirvVersionUnsupported;
            try std.testing.expectError(expected, shader_module_vk.create(&seam, &words));
        }
    }
}

test "test-shader-module: Vulkan 1.1 rejects the unchanged SPIR-V 1.4 fixture" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const words = try loadFixture(std.testing.allocator, vertex_fixture);
    defer std.testing.allocator.free(words);
    try std.testing.expectEqual(@as(Word, 0x0001_0400), words[1]);
    const seam: shader_module.Device = .{
        .handle = null,
        .api_version = (@as(u32, 1) << 22) | (1 << 12),
        .create_shader_module = null,
        .destroy_shader_module = null,
    };
    try std.testing.expectError(error.SpirvVersionUnsupported, awaitModule(
        std.testing.allocator,
        threaded.io(),
        &seam,
        .{ .words = words },
    ));
}

test "test-shader-module: retained specialization metadata unwinds before driver failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        specializationDriverFailure,
        .{threaded.io()},
    );
}

fn specializationDriverFailure(allocator: std.mem.Allocator, io: std.Io) !void {
    const words = [_]Word{
        spirv.magic_number, 0x0001_0000, 0, 100,         0,
        0x0005_000f,        5,           1, 0x6e69_616d, 0,
        0x0004_0047,        3,           1, 7,           0x0004_0015,
        2,                  32,          0, 0x0004_0032, 2,
        3,                  11,
    };
    const seam: shader_module.Device = .{
        .handle = null,
        .api_version = (@as(u32, 1) << 22) | (3 << 12),
        .create_shader_module = null,
        .destroy_shader_module = null,
    };
    var module = awaitModule(allocator, io, &seam, .{ .words = &words }) catch |err| {
        if (err == error.MissingShaderModuleProc) return;
        return err;
    };
    try module.destroy(null);
    return error.ExpectedMissingShaderModuleProc;
}

// ---------------------------------------------------------------------------
// The shared body.
// ---------------------------------------------------------------------------

/// Every refusal this fixture's teardown has not handed back yet.
///
const TeardownError = vulkan_device.ProcError || shader_module_vk.CreateError;

const TeardownErrors = struct {
    first: ?TeardownError = null,

    /// Records one refusal. The first is the one that matters: a teardown that
    /// already failed left its object in a state a later teardown cannot
    /// describe, so a second report would bury the first.
    fn record(self: *TeardownErrors, err: TeardownError) void {
        if (self.first == null) self.first = err;
    }

    /// Returns the refusal the teardown recorded, or nothing when every
    /// teardown ran.
    fn report(self: *const TeardownErrors) TeardownError!void {
        if (self.first) |err| return err;
    }
};

/// Runs `want` through the whole create path on a real device and asserts what
/// the milestone says about the result.
///
/// The frame of its own, so that the teardown refusals `createdFromOnDevice`
/// records have all been made by the time `report` looks for one.
fn expectCreatedFrom(want: Fixture, io: std.Io) !void {
    var teardowns: TeardownErrors = .{};
    try createdFromOnDevice(want, io, &teardowns);
    try teardowns.report();
}

/// Creates the module `descriptor` names and waits for it.
///
/// `createShaderModule` hands back a `std.Io.Future`, which is not a
/// refcounted handle: the only thing it owns is the task `io.concurrent`
/// started, and `await` joins that task and then clears `any_future`
/// (`lib/std/Io.zig:1199`-`:1203`), so the await is the release. Awaiting
/// inside this helper puts that release on the only path out of the frame the
/// future was born in. `Future.await` takes `*Future` because it consumes the
/// future, so the future needs a name and a `var`
/// (`test/render_pipeline.zig:222`-`:224` says the same for its own copy).
fn awaitModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    seam: *const shader_module.Device,
    descriptor: shader_module.Descriptor,
) (std.Io.ConcurrentError || shader_module.CreateError)!shader_module.ShaderModule {
    var future = try shader_module.createShaderModule(allocator, io, seam, descriptor);
    return future.await(io);
}

fn createdFromOnDevice(want: Fixture, io: std.Io, teardowns: *TeardownErrors) !void {
    const allocator = std.testing.allocator;

    var handles: vulkan_device.HandleSet = .{};
    var backend = vulkan_device.Backend.init(allocator, .{ .handles = &handles });
    // A teardown refusal goes to `teardowns` for the reason the type's own
    // doc comment gives; nothing here prints and nothing here panics.
    defer backend.deinit() catch |err| teardowns.record(err);
    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();

    // `discoverPhysicalDevices` already refused a device below the floor
    // (`src/engine/vulkan_device.zig:1270`-`:1276`), so the first adapter is one
    // that survived the filter.
    const adapter = try adapters.first();
    var device = try vulkan_device.Device.create(allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });
    defer device.deinit(allocator) catch |err| teardowns.record(err);
    try std.testing.expectEqual(@as(u32, 1), handles.countOf(.device));

    // The seam is the device tier's two shader-module entry points and the
    // handle they run on (`src/pipeline/shader_module_vk.zig:50`-`:56`).
    const seam: shader_module.Device = .init(device.procs, device.vk_device, device.api_version);

    const words = try loadFixture(allocator, want.bytes);
    defer allocator.free(words);

    var module = try awaitModule(allocator, io, &seam, .{
        .label = want.label,
        .words = words,
    });
    errdefer module.destroy(&seam) catch |err| teardowns.record(err);

    // The two outcomes are exclusive, exactly as Dawn asserts them
    // (`src/dawn/native/ShaderModule.cpp:1561`): a module that reached Vulkan
    // has a handle and no message, and a failed module has the other two.
    try std.testing.expect(!module.failed);
    try std.testing.expect(module.vk_module != null);

    const info = shader_module.getCompilationInfo(&module);
    try std.testing.expectEqual(@as(usize, 0), info.countOf(MessageType.error_));
    try std.testing.expectEqual(@as(usize, 0), info.countOf(MessageType.warning));
    try std.testing.expect(!info.hasWarningsOrErrors());

    // Dawn answers the empty string for a module with no warning and no error
    // (`src/dawn/native/ShaderModule.cpp:2114`-`:2116`).
    const log = try shader_module.getCompilationLog(allocator, &module);
    defer allocator.free(log);
    try std.testing.expectEqualStrings("", log);

    // The assertion the milestone exists for, word for word. The first
    // comparison is against the slice this test built; the second is against
    // the fixture's own bytes, so the two together pin the file to the module
    // rather than pinning the reader to itself.
    try std.testing.expect(std.mem.eql(Word, module.words, words));
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(module.words), want.bytes));
    try std.testing.expectEqual(shader_module.contentHash(words), module.hash);
    try std.testing.expectEqualStrings(want.label, module.label);

    // Reflection read the entry points out of the binary. Dawn reads them out
    // of Tint (`src/dawn/native/ShaderModule.cpp:795`, `:1314`); the port reads
    // them out of the caller's own words.
    try std.testing.expectEqual(@as(usize, 1), module.entry_points.len);
    if (want.specialization_count) |count| {
        try std.testing.expectEqual(count, module.specialization_constants.len);
    } else if (want.has_specialization) {
        try std.testing.expectEqual(@as(usize, 2), module.specialization_constants.len);
        const value = module.specialization_constants[0];
        const bias = module.specialization_constants[1];
        try std.testing.expectEqual(@as(u32, 7), value.spec_id);
        try std.testing.expectEqual(@as(u32, 9), bias.spec_id);
        try std.testing.expectEqualStrings("value", value.name);
        try std.testing.expectEqualStrings("bias", bias.name);
        try std.testing.expectEqual(@as(u32, 32), value.scalar_type.unsigned_integer);
        try std.testing.expectEqual(@as(u32, 32), bias.scalar_type.unsigned_integer);
    } else {
        try std.testing.expectEqual(@as(usize, 0), module.specialization_constants.len);
    }
    try std.testing.expectEqual(@as(usize, 1), module.countEntryPoints(want.stage));
    const entry = module.findEntryPoint(want.entry_point) orelse
        return error.EntryPointNotReflected;
    try std.testing.expectEqualStrings(want.entry_point, entry.name);
    try std.testing.expectEqual(want.stage, entry.execution_model);

    // The reflected layout is what M14's
    // `ValidateCompatibilityWithPipelineLayout`
    // (`src/dawn/native/ShaderModule.cpp:1576`) compares a bind group layout
    // against, so the count and the slot are the observable here, not the M12
    // object itself.
    if (want.check_resource_layout) {
        const expected_bindings: usize = if (want.declared == null) 0 else 1;
        try std.testing.expectEqual(expected_bindings, entry.layout.bindingCount());
        try std.testing.expectEqual(expected_bindings, entry.layout.groupCount());
    }

    if (want.declared) |declared| {
        const group = entry.layout.findGroup(declared.set) orelse
            return error.DeclaredSetNotReflected;
        try std.testing.expectEqual(@as(u32, declared.binding), group.bindings[0].binding);
        try std.testing.expectEqual(declared.kind, group.bindings[0].kind);
        const binding = group.bindings[0];
        if (declared.image_dimension) |dimension|
            try std.testing.expectEqual(dimension, binding.image_dimension.?);
        if (declared.image_depth_mode) |depth|
            try std.testing.expectEqual(depth, binding.image_depth_mode.?);
        if (declared.sampled_scalar) |scalar|
            try std.testing.expectEqualDeep(scalar, binding.sampled_scalar.?);
        if (declared.image_format) |format|
            try std.testing.expectEqual(format, binding.image_format.?);
        if (declared.buffer_read_only) |read_only|
            try std.testing.expectEqual(read_only, binding.buffer_read_only);
    } else if (want.check_resource_layout) {
        // A shader that declares no descriptor mentions no set at all, which is
        // why `findGroup` answers null rather than an empty window.
        try std.testing.expect(entry.layout.findGroup(0) == null);
    }

    // The handle goes back on the way out. `destroy` reads the pair
    // `(vk_module == null) == (device == null)` rather than inferring it
    // (`src/pipeline/shader_module.zig:169`), so this is the assertion that
    // the module and its seam were the two the create pass wrote.
    try module.destroy(&seam);
}

/// The words of a fixture, with the file size divided by four checked against
/// what came back. A `.spv` file is a word stream, so a size that is not a whole
/// number of words is a truncated fixture rather than a module.
fn loadFixture(allocator: std.mem.Allocator, bytes: []const u8) ![]Word {
    const words = try spirv.wordsFromBytes(allocator, bytes);
    errdefer allocator.free(words);

    try std.testing.expectEqual(bytes.len / @sizeOf(Word), words.len);
    return words;
}

test "test-shader-module: owned specialization metadata survives reflection cleanup" {
    const fixture = @import("fixtures/specialization_compute.zig");
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try expectCreatedFrom(.{
        .label = "specialization compute",
        .bytes = std.mem.sliceAsBytes(&fixture.words),
        .entry_point = fixture.entry_point,
        .stage = .gl_compute,
        .declared = null,
        .check_resource_layout = false,
        .has_specialization = true,
    }, threaded.io());
}

const compilation_messages = dusk.pipeline.shader_compilation_messages;
const CompilationMessage = compilation_messages.Message;

const snapshot_expected = [_]CompilationMessage{
    .{
        .text = "bad\x00\xc3\xa9",
        .type_ = .error_,
        .line_num = 17,
        .line_pos_in_bytes = 23,
        .offset_in_bytes = 31,
        .length_in_bytes = 41,
        .line_pos_in_utf16 = 47,
        .offset_in_utf16 = 53,
        .length_in_utf16 = 61,
    },
    .{
        .text = "",
        .type_ = .warning,
        .line_num = 67,
        .line_pos_in_bytes = 71,
        .offset_in_bytes = 73,
        .length_in_bytes = 79,
        .line_pos_in_utf16 = 83,
        .offset_in_utf16 = 89,
        .length_in_utf16 = 97,
    },
    .{
        .text = "note",
        .type_ = .info,
        .line_num = 101,
        .line_pos_in_bytes = 103,
        .offset_in_bytes = 107,
        .length_in_bytes = 109,
        .line_pos_in_utf16 = 113,
        .offset_in_utf16 = 127,
        .length_in_utf16 = 131,
    },
};

test "test-shader-module: snapshot survives source destruction and text overwrite" {
    // Separate allocators expose a borrowed array or text after the source owner leaves.
    try snapshotSourceLifetime(std.testing.allocator);
}

test "test-shader-module: snapshot unwinds every refused allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        snapshotSourceLifetime,
        .{},
    );
}

fn snapshotSourceLifetime(allocator: std.mem.Allocator) !void {
    const snapshot = blk: {
        const text = try std.testing.allocator.dupe(u8, "bad\x00\xc3\xa9note");
        defer std.testing.allocator.free(text);
        const items = try std.testing.allocator.dupe(CompilationMessage, &snapshot_expected);
        var source_live = true;
        const source: compilation_messages.Messages = .{
            .allocator = std.testing.allocator,
            .items = items,
        };
        defer if (source_live) source.deinit();
        items[0].text = text[0..6];
        items[1].text = text[6..6];
        items[2].text = text[6..];
        const owned = try compilation_messages.snapshot(allocator, source.items);
        source.deinit();
        source_live = false;
        @memset(text, 'x');
        break :blk owned;
    };
    defer snapshot.deinit();
    try std.testing.expectEqualDeep(
        @as([]const CompilationMessage, &snapshot_expected),
        snapshot.items,
    );
}

test "test-shader-module: clone survives the original owned diagnostics" {
    try cloneSourceLifetime(std.testing.allocator);
}

test "test-shader-module: clone unwinds every refused allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneSourceLifetime,
        .{},
    );
}

fn cloneSourceLifetime(allocator: std.mem.Allocator) !void {
    const cloned = blk: {
        const source = try compilation_messages.snapshot(std.testing.allocator, &snapshot_expected);
        defer source.deinit();
        break :blk try compilation_messages.Messages.clone(allocator, source);
    };
    defer cloned.deinit();
    try std.testing.expectEqualDeep(
        @as([]const CompilationMessage, &snapshot_expected),
        cloned.items,
    );
}

test "test-shader-module: borrowed builder never frees caller text" {
    const text = try std.testing.allocator.dupe(u8, "caller owned");
    defer std.testing.allocator.free(text);
    const source = try compilation_messages.one(
        std.testing.allocator,
        CompilationMessage.unanchored(text, .error_),
    );
    source.deinit();
    @memset(text, 'x');
    try std.testing.expectEqualStrings("xxxxxxxxxxxx", text);
}

test "test-shader-module: error diagnostics outlive caller text and module destruction" {
    try errorModuleDiagnosticsLifetime(std.testing.allocator);
}

test "test-shader-module: error module and snapshot unwind every refused allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        errorModuleDiagnosticsLifetime,
        .{},
    );
}

fn errorModuleDiagnosticsLifetime(allocator: std.mem.Allocator) !void {
    const snapshot = blk: {
        var module = blk_module: {
            const text = try std.testing.allocator.dupe(u8, "InvalidMagicNumber");
            defer std.testing.allocator.free(text);
            const created = try shader_module.createErrorShaderModule(allocator, .{
                .message = text,
            });
            @memset(text, 'x');
            break :blk_module created;
        };
        // A failed module has no Vulkan handle, so its host cleanup cannot fail.
        defer module.destroy(null) catch @panic("host-only module cleanup failed");
        const borrowed = shader_module.getCompilationInfo(&module);
        try std.testing.expectEqualStrings("InvalidMagicNumber", borrowed.items[0].text);
        break :blk try shader_module.snapshotCompilationInfo(allocator, &module);
    };
    defer snapshot.deinit();
    try std.testing.expectEqualDeep(
        CompilationMessage.unanchored("InvalidMagicNumber", .error_),
        snapshot.items[0],
    );
}

test "test-shader-module: pre14 compute retains the statically used canonical storage layout" {
    const fixture = @import("fixtures/workgroup_compute.zig");
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try expectCreatedFrom(.{
        .label = "pre14 storage compute",
        .bytes = std.mem.sliceAsBytes(&fixture.words),
        .entry_point = fixture.entry_point,
        .stage = .gl_compute,
        .declared = .{
            .set = 0,
            .binding = 0,
            .kind = .storage_buffer,
            .buffer_read_only = false,
        },
        .specialization_count = 3,
    }, threaded.io());
}

const image_metadata_words = [_]Word{
    spirv.magic_number, 0x0001_0400, 0,           20,          0,
    0x0002_0011,        1,           0x0003_000e, 0,           1,
    0x0006_000f,        5,           10,          0x6e69_616d, 0,
    6,                  0x0006_0010, 10,          17,          1,
    1,                  1,           0x0004_0047, 6,           34,
    0,                  0x0004_0047, 6,           33,          3,
    0x0002_0013,        1,           0x0003_0021, 2,           1,
    0x0003_0016,        3,           32,          0x0009_0019, 4,
    3,                  1,           2,           0,           0,
    1,                  0,           0x0004_0020, 5,           0,
    4,                  0x0004_003b, 5,           6,           0,
    0x0005_0036,        1,           10,          0,           2,
    0x0002_00f8,        11,          0x0004_003d, 4,           12,
    6,                  0x0001_00fd, 0x0001_0038,
};

test "test-shader-module: canonical image metadata survives reflection cleanup in entry layouts" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try expectCreatedFrom(.{
        .label = "canonical image metadata",
        .bytes = std.mem.sliceAsBytes(&image_metadata_words),
        .entry_point = "main",
        .stage = .gl_compute,
        .declared = .{
            .set = 0,
            .binding = 3,
            .kind = .sampled_texture,
            .image_dimension = .two_dimensional,
            .image_depth_mode = 2,
            .sampled_scalar = .{ .float = 32 },
            .image_format = 0,
        },
    }, threaded.io());
}

test "test-shader-module: canonical descriptor layout allocation failures unwind before dispatch" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        imageMetadataDriverFailure,
        .{threaded.io()},
    );
}

fn imageMetadataDriverFailure(allocator: std.mem.Allocator, io: std.Io) !void {
    const seam: shader_module.Device = .{
        .handle = null,
        .api_version = (@as(u32, 1) << 22) | (3 << 12),
        .create_shader_module = null,
        .destroy_shader_module = null,
    };
    var module = awaitModule(allocator, io, &seam, .{ .words = &image_metadata_words }) catch |err| {
        if (err == error.MissingShaderModuleProc) return;
        return err;
    };
    try module.destroy(null);
    return error.ExpectedMissingShaderModuleProc;
}
