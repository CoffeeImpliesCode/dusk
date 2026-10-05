//! The M13 shard: two checked-in fixtures through `createShaderModule`.
//!
//! **What the milestone claims.** `docs/40-plan.md` §1 `### M13` names four
//! assertions and this shard makes all four: the `VkShaderModule` handle is
//! non-null, `getCompilationInfo()` reports 0 errors and 0 warnings, the
//! reflected layout carries the one descriptor `triangle.frag.wgsl` declares,
//! and the words the module holds are the input file word for word. The last
//! one is why the milestone exists: Dawn cannot pass caller SPIR-V through
//! (`docs/02-dawn-design.md` §4.9) and the port's claim is that it does.
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

/// The fixtures are generated from the checked-in `.wgsl`, never hand-written;
/// `test/spirv.zig:3`-`:5` and `docs/50-verification.md` §6.2 record the
/// command line that produced each `.spv` from it.
const vertex_fixture: []const u8 = @embedFile("fixtures/triangle.vert.spv");
const fragment_fixture: []const u8 = @embedFile("fixtures/triangle.frag.spv");

/// One descriptor the reflection is expected to have read out of the binary.
const Declared = struct {
    set: u32,
    binding: u32,
    kind: spirv.ResourceKind,
};

/// What one fixture declares, so the assertions below read as the milestone's
/// sentence instead of as a loop over two cases with a branch in it.
const Fixture = struct {
    label: []const u8,
    bytes: []const u8,
    entry_point: []const u8,
    stage: spirv.ExecutionModel,

    /// The one descriptor the fixture declares, or null when it declares none.
    /// `test/fixtures/triangle.vert.wgsl` declares nothing;
    /// `triangle.frag.wgsl` declares the uniform buffer at set 0 binding 1,
    /// which is the shape `src/pipeline/shader_reflect.zig:38`-`:43` names.
    declared: ?Declared,
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
        .create_shader_module = null,
        .destroy_shader_module = null,
    };

    var future = try shader_module.createShaderModule(std.testing.allocator, io, &seam, .{
        .words = words,
    });
    try std.testing.expectError(error.MissingShaderModuleProc, future.await(io));
}

// ---------------------------------------------------------------------------
// The shared body.
// ---------------------------------------------------------------------------

/// Every refusal this fixture's teardown has not handed back yet.
///
/// Zig 0.16 `defer` cannot fail, so `Backend.deinit`, `Device.deinit` and
/// `ShaderModule.destroy` — which release through the global, instance and
/// device procs the loader can be missing — cannot return from where they
/// refuse. `AGENTS.md` §3.1 makes that a typed error and forbids the panic, so
/// they record it here and `expectCreatedFrom` returns it once their `defer`s
/// have run.
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
    const seam: shader_module.Device = .init(device.procs, device.vk_device);

    const words = try loadFixture(allocator, want.bytes);
    defer allocator.free(words);

    var module = try awaitModule(allocator, io, &seam, .{
        .label = want.label,
        .words = words,
    });
    // A failed assertion must still give the Vulkan handle back, so the
    // cleanup is an `errdefer` and the happy path destroys once more at the
    // bottom. A refusal from that cleanup is recorded rather than discarded
    // (`AGENTS.md` §2): the body is already returning the assertion that armed
    // this, and `report` reads the recording only on the path where it did not.
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
    const expected_bindings: usize = if (want.declared == null) 0 else 1;
    try std.testing.expectEqual(expected_bindings, entry.layout.bindingCount());
    try std.testing.expectEqual(expected_bindings, entry.layout.groupCount());

    if (want.declared) |declared| {
        const group = entry.layout.findGroup(declared.set) orelse
            return error.DeclaredSetNotReflected;
        try std.testing.expectEqual(@as(u32, declared.binding), group.bindings[0].binding);
        try std.testing.expectEqual(declared.kind, group.bindings[0].kind);
    } else {
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
