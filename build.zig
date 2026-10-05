//! Build wiring for dusk.
//!
//! **What this build publishes.** One module, `dusk`, rooted at
//! `src/root.zig`. A dependent package reaches it as `dep.module("dusk")`.
//! No executable and no C artifact exist yet, so `dep.artifact("dusk")` is
//! unsupported and `zig-out/bin` stays empty. `docs/40-plan.md` names the
//! milestone that adds each; neither is declared before it exists.
//!
//! **The two generated files.** `src/vulkan.zig` is `zig translate-c` over the
//! pinned `vulkan_core.h`, and `src/vk/dispatch.zig` is the output of
//! `tools/gen_dispatch.zig`. Both are checked in, so a consumer needs no C
//! toolchain and no Vulkan SDK headers. `zig build generate` rewrites them from
//! the pinned inputs, and that step is outside the default graph on purpose: a
//! build must never mutate a checked-in file without being asked.
//! `test/gen_dispatch_drift.zig` fails when the two disagree.
//!
//! **What the `test` step runs.** The published module in Debug and in
//! ReleaseSafe, the generated dispatch table in both modes, the drift test, and
//! one acceptance shard per file under `test/`. A test file is its own module
//! with the library as an import, so a file that stops compiling fails alone
//! and its step name says which file it was.
//!
//! **How the library's own tests get in.** The two shards that root
//! `src/root.zig` are also what runs every `test` block under `src/`: the test
//! block at the end of `src/root.zig` calls `std.testing.refAllDecls` on each
//! of the nine module namespaces, which references every name they publish and
//! so puts every file behind them into the compilation. A `pub const`
//! re-export on its own is only a name, and a file that is never imported
//! never contributes its tests; measured before that block existed, the
//! published-module shard ran 2 tests against 78 `test` blocks in the tree.
//! The generated table's own four tests are in that 78 by way of the `vk`
//! namespace, and the dedicated dispatch shards below still add what a module
//! root adds: the file as the root, its own safety mode, and `link_libc` on a
//! compilation that has no other reason to set it.
//!
//! **Compiler.** `build.zig.zon` declares `.minimum_zig_version = "0.16.0"`.
//! That is a lower bound, not the supported compiler. Zig 0.16.0 is the line
//! this project intends. On this host `zig` is an anyzig shim that reads the
//! same field to select the toolchain, so the manifest is the single version
//! authority for the project and for every tool the gate runs.

const std = @import("std");

/// Package version. Mirrors `.version` in `build.zig.zon`.
///
/// Zig's build API exposes no manifest reader, so this is a second copy. A
/// release bumps both, and `src/root.zig` checks the shape of this value
/// because the C ABI header embeds it.
const version = "0.0.0";

/// Compiler floor. Mirrors `.minimum_zig_version` in `build.zig.zon`, which is
/// the authority and also selects the toolchain through the anyzig shim.
/// `src/root.zig` checks it against the running compiler.
const minimum_zig_version = "0.16.0";

/// Address-space ceiling for one test shard, in kibibytes. Four gigabytes is
/// far above an honest test and far below what an unbounded allocation loop
/// reaches in a minute, so a runaway test fails quickly and visibly instead of
/// taking the machine with it.
const test_address_space_kb: u32 = 4 * 1024 * 1024;

/// The header `zig translate-c` reads, relative to the header tree's root.
/// `docs/20-dependencies.md` "Vulkan bindings" owns the pin and the reason the
/// standard library cannot cover the slot.
const vulkan_header_sub_path = "vulkan/vulkan_core.h";

/// The line `zig translate-c` emits for the pinned header version. It is the
/// pin check: a tree from another Vulkan release cannot pass it.
const pinned_header_version_line = "pub const VK_HEADER_VERSION = @as(c_int, 365);";

/// Name the translation is captured under in the cache.
const vulkan_name = "vulkan.zig";

/// Where `zig build generate` writes. `zig translate-c` names its output after
/// the header it read, so the step renames the result to the path the module
/// graph imports.
const vulkan_zig_sub_path = "src/vulkan.zig";
const dispatch_zig_sub_path = "src/vk/dispatch.zig";

/// The generator, and the test that catches a generator change nobody ran.
/// A generator is a Zig program under `tools/`: never a shell script, never
/// Python.
const gen_dispatch_sub_path = "tools/gen_dispatch.zig";
const dispatch_drift_test_sub_path = "test/gen_dispatch_drift.zig";

/// Directory under the build cache for the bytes the drift test generates. It
/// is scratch, so it is cached rather than committed.
const drift_scratch_dir = "gen_dispatch_drift";

/// Name the generator writes its output under, in the cache and in scratch.
const dispatch_name = "dispatch.zig";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // The published values reach source through an options module, so a
    // consumer reads them from `@import("dusk")` rather than parsing the
    // manifest.
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "minimum_zig_version", minimum_zig_version);

    addGenerateStep(b);

    // The bindings, one module instance per safety mode, shared by every
    // module that imports them. Two instances rooted at `src/vulkan.zig` inside
    // one compilation is a hard error, not a duplicate definition: the compiler
    // names the second `vulkan0` and rejects the file for belonging to two
    // modules. A module's optimize mode is fixed at creation, so one instance
    // cannot serve both modes, and there must be exactly one per mode.
    const vulkan_debug = addVulkanModule(b, target, .Debug);
    const vulkan_release = addVulkanModule(b, target, .ReleaseSafe);

    // The published module. Consumers import `@import("dusk")`. The `vulkan`
    // import is what lets `src/vk/dispatch.zig` reach the bindings without a
    // global and without a path through some other module.
    //
    // `link_libc` is the one setting here that is about the host rather than
    // about Zig. `platform/loader.zig` opens a library through `std.DynLib`,
    // which on Linux is `ElfDynLib` without libc and `DlDynLib` with it
    // (`lib/std/dynamic_library.zig:16-19`); `ElfDynLib` resolves a bare name
    // through `/lib` and `/usr/lib` alone
    // (`lib/std/dynamic_library.zig:217-220`), and `platform/x11_functions.zig`
    // asks for `libX11.so.6`, which is in `/usr/lib64` on this host. Dawn's
    // `src/dawn/common/DynamicLib.cpp:104` hands a bare name to `dlopen` and
    // inherits the system loader path, so the flag restores upstream's
    // behaviour rather than inventing one. It reaches every compilation that
    // includes this Module (`lib/std/Build/Step/Compile.zig:1055`), so this one
    // declaration covers the Debug shard and every shard importing `dusk`.
    const mod = b.addModule("dusk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "vulkan", .module = vulkan_debug },
        },
    });

    // Library tests, once per safety mode. Both modes belong to the gate
    // because the house gate runs a plain `zig build test` with no
    // `-Doptimize`, so an optimized-only failure cannot slip past a Debug-only
    // run. The Debug shard is the published module itself, so a change that
    // breaks `dep.module("dusk")` breaks the gate. A module's mode is fixed at
    // creation, so ReleaseSafe needs a private equivalent. That is a different
    // Module object from the published one and imports only `vulkan`, so the
    // published Module's `link_libc` never reaches this compilation; this one
    // roots `src/root.zig` and so needs the flag in its own right.
    const test_step = b.step(
        "test",
        "Run the library tests in Debug and ReleaseSafe, and one acceptance shard per test file",
    );

    const debug_tests = b.addTest(.{
        .name = "test-Debug",
        .root_module = mod,
    });
    test_step.dependOn(&addCeilingedRun(b, "test-Debug", debug_tests).step);

    const release_tests = b.addTest(.{
        .name = "test-ReleaseSafe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "vulkan", .module = vulkan_release },
            },
        }),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-ReleaseSafe", release_tests).step);

    // The generated dispatch table is not reachable from `src/root.zig` yet, so
    // it gets a test shard of its own in both safety modes. Checked-in
    // generated code is part of the library: without this the gate would never
    // compile it.
    const dispatch_debug = b.addTest(.{
        .name = "test-vk-dispatch-Debug",
        .root_module = addDispatchTestModule(b, target, .Debug, vulkan_debug),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-vk-dispatch-Debug", dispatch_debug).step);

    const dispatch_release = b.addTest(.{
        .name = "test-vk-dispatch-ReleaseSafe",
        .root_module = addDispatchTestModule(b, target, .ReleaseSafe, vulkan_release),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-vk-dispatch-ReleaseSafe", dispatch_release).step);

    // The drift test regenerates the table and compares the bytes. One mode is
    // enough: byte identity does not depend on the safety mode, and the two
    // dispatch shards above already answer that question.
    const drift_options = b.addOptions();
    drift_options.addOption([]const u8, "checked_in_path", b.pathFromRoot(dispatch_zig_sub_path));
    drift_options.addOption([]const u8, "scratch_path", b.pathJoin(&.{
        b.cache_root.path orelse ".",
        drift_scratch_dir,
        dispatch_name,
    }));
    const drift_tests = b.addTest(.{
        .name = "test-gen-dispatch-drift",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dispatch_drift_test_sub_path),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "gen_dispatch", .module = addGenDispatchModule(b) },
                .{ .name = "drift_options", .module = drift_options.createModule() },
            },
        }),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-gen-dispatch-drift", drift_tests).step);

    // One shard per file under `test/`, one safety mode each. The two shards
    // above already run the published module in Debug and ReleaseSafe; an
    // acceptance shard is a separate module, so one file that stops compiling
    // fails alone and names itself in the step graph. The drift test is the one
    // file with no entry here: it needs the generator and its options module
    // rather than the library, so it is declared where those are.
    const acceptance_shards = [_]struct { name: []const u8, sub_path: []const u8 }{
        .{ .name = "test-api-conformance", .sub_path = "test/api_conformance.zig" },
        .{ .name = "test-bind-group", .sub_path = "test/bind_group.zig" },
        .{ .name = "test-blit", .sub_path = "test/blit.zig" },
        .{ .name = "test-buffer", .sub_path = "test/buffer.zig" },
        .{ .name = "test-color-space", .sub_path = "test/color_space.zig" },
        .{ .name = "test-command-stream", .sub_path = "test/command_stream.zig" },
        .{ .name = "test-compatibility", .sub_path = "test/compatibility.zig" },
        .{ .name = "test-error-scope", .sub_path = "test/error_scope.zig" },
        .{ .name = "test-error-sets", .sub_path = "test/error_sets.zig" },
        .{ .name = "test-formats", .sub_path = "test/formats.zig" },
        .{ .name = "test-limits", .sub_path = "test/limits.zig" },
        .{ .name = "test-memory", .sub_path = "test/memory.zig" },
        .{ .name = "test-null-device", .sub_path = "test/null_device.zig" },
        .{ .name = "test-object-arena", .sub_path = "test/object_arena.zig" },
        .{ .name = "test-pipeline-cache", .sub_path = "test/pipeline_cache.zig" },
        .{ .name = "test-query-set", .sub_path = "test/query_set.zig" },
        .{ .name = "test-render-pipeline", .sub_path = "test/render_pipeline.zig" },
        .{ .name = "test-serial-timeline", .sub_path = "test/serial_timeline.zig" },
        .{ .name = "test-shared-memory", .sub_path = "test/shared_memory.zig" },
        .{ .name = "test-shader-module", .sub_path = "test/shader_module.zig" },
        .{ .name = "test-spirv", .sub_path = "test/spirv.zig" },
        .{ .name = "test-surface-headless", .sub_path = "test/surface_headless.zig" },
        .{ .name = "test-texture", .sub_path = "test/texture.zig" },
        .{ .name = "test-triangle", .sub_path = "test/triangle.zig" },
        .{ .name = "test-vulkan-device", .sub_path = "test/vulkan_device.zig" },
        .{ .name = "test-worker-pool", .sub_path = "test/worker_pool.zig" },
    };
    for (acceptance_shards) |shard| {
        addAcceptanceShard(b, test_step, shard.name, shard.sub_path, target, mod, vulkan_debug);
    }

    // The foreign matrix. This step runs the Debug shard through the build
    // system's own runner selection, which is native for the host and
    // qemu_user for a foreign target, so `./cross-test.profile.sh` needs no
    // launcher of its own. Deliberately one mode: the native `test` step above
    // already covers both safety modes, and a foreign run is about execution,
    // not about optimisation.
    //
    // No address-space ceiling here. The ceiling is applied by a shell
    // launcher, and a shell launcher does not report counted results to
    // cross-test; worse, under qemu_user the limit would bound the emulator
    // rather than the guest.
    const cross_test_step = b.step(
        "cross-test",
        "Run the Debug shard in foreign targets through the build system's runner",
    );
    const cross_tests = b.addTest(.{
        .name = "cross-test-Debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
            // The same private root as the ReleaseSafe shard above, for the
            // same reason: it roots `src/root.zig` instead of importing the
            // published Module, so it declares `link_libc` itself.
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "vulkan", .module = vulkan_debug },
            },
        }),
    });
    const cross_run = b.addRunArtifact(cross_tests);
    // A cached run executes no tests and cannot prove execution coverage.
    cross_run.has_side_effects = true;
    cross_test_step.dependOn(&cross_run.step);
}

/// The bindings module, one instance per safety mode. A module's optimize mode
/// is fixed when it is created, and every consumer of that mode shares this
/// single instance: two roots on `src/vulkan.zig` in one compilation is the
/// compiler error `file exists in modules 'vulkan' and 'vulkan0'`.
fn addVulkanModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(vulkan_zig_sub_path),
        .target = target,
        .optimize = optimize,
    });
}

/// The test shard root for the generated dispatch table. `vulkan` is the
/// already-created bindings instance for `optimize`, passed in rather than
/// built here, so the shard and the library never put two roots on
/// `src/vulkan.zig` in one compilation.
///
/// The shard roots `src/vk/dispatch.zig`, whose `loadGlobalProcs` takes a
/// `*std.DynLib` and looks entry points up in it, so it declares `link_libc`
/// for the same reason the published module does. The bindings instance is a
/// pure translation of a freestanding header and cannot reach a `std.DynLib`,
/// so the shard cannot inherit the flag from it.
fn addDispatchTestModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(dispatch_zig_sub_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vulkan", .module = vulkan },
        },
    });
}

/// The generator module. Host-targeted and unoptimized: it emits text, and the
/// only thing that must run it is this machine's `zig build generate`.
fn addGenDispatchModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(gen_dispatch_sub_path),
        .target = b.graph.host,
        .optimize = .Debug,
    });
}

/// Rewrites the two generated files from the pinned inputs.
///
/// The step writes into the source tree, and only when it is asked to:
/// `std.Build.Step.UpdateSourceFiles` exists for that case, and it is the only
/// step here that is not part of the default graph.
///
/// **Where the header comes from.** `-Dheader-dir`, or `DUSK_VULKAN_HEADERS`,
/// which `devenv.nix` sets. `docs/20-dependencies.md` "Vulkan bindings" owns
/// the pin, commit `8249cb829eb402c65cb7e3778c51b0f8edc4a4b6` at Vulkan-Headers
/// v1.4.365, and it is not a `build.zig.zon` dependency. That was measured, not
/// inferred: with the entry present, `zig build` compiles the dependency's own
/// build script and fails in `toolbox` 2.2.5, which needs the `Build.root` that
/// Zig 0.16 removed and a one-argument `findProgram`
/// (`zig-pkg/toolbox-2.2.5-*/build.zig:819`). A `.paths` filter does not save
/// it, and it could not: `translate-c` reads `vulkan_core.h` together with
/// `vk_platform.h` and the eleven `vk_video` headers, so the input is a header
/// tree. What the step does check is the version, through the generated file
/// itself, so a tree from another Vulkan release cannot be mistaken for the
/// pin.
fn addGenerateStep(b: *std.Build) void {
    const generate_step = b.step(
        "generate",
        "Rewrite src/vulkan.zig and src/vk/dispatch.zig from the pinned inputs",
    );

    // The bindings. `AGENTS.md` §3.1: `src/vulkan.zig` is generated and never
    // hand-edited, so the header tree is its only input. The run is a plain
    // child process rather than `std.Build.Step.TranslateC` because the tree
    // is outside the package, and a `LazyPath` cannot name it.
    const header_dir = b.option([]const u8, "header-dir", "Directory holding vulkan/vulkan_core.h") orelse
        b.graph.environ_map.get("DUSK_VULKAN_HEADERS") orelse {
        const missing_header = std.Build.Step.Fail.create(
            b,
            "no Vulkan header tree: set DUSK_VULKAN_HEADERS (devenv.nix sets it)" ++
                " or pass -Dheader-dir=<dir> holding vulkan/vulkan_core.h",
        );
        generate_step.dependOn(&missing_header.step);
        return;
    };

    // No `-lc`: the header is freestanding C and the bindings declare no libc
    // type, so linking libc into the translation only adds the platform's
    // `int_least64_t` aliases to a file that must stay a pure translation of
    // the header. `docs/20-dependencies.md` records the same command.
    const translate_c = b.addSystemCommand(&.{ b.graph.zig_exe, "translate-c" });
    translate_c.addArg("-I");
    translate_c.addArg(header_dir);
    translate_c.addArg(b.pathJoin(&.{ header_dir, vulkan_header_sub_path }));
    const bindings = translate_c.captureStdOut(.{ .basename = vulkan_name });
    generate_step.dependOn(&std.Build.Step.CheckFile.create(b, bindings, .{
        .expected_matches = &.{pinned_header_version_line},
    }).step);

    // The dispatch table. The generator prints the file on standard output and
    // the step captures it, so the same bytes reach the source tree here and
    // the drift test's scratch file.
    const gen_dispatch = b.addExecutable(.{
        .name = "gen_dispatch",
        .root_module = addGenDispatchModule(b),
    });
    const rendered = b.addRunArtifact(gen_dispatch).captureStdOut(.{
        .basename = dispatch_name,
    });

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(bindings, vulkan_zig_sub_path);
    update.addCopyFileToSource(rendered, dispatch_zig_sub_path);
    generate_step.dependOn(&update.step);
}

/// Native runs retain the address-space ceiling that bounds a runaway test.
/// argv is `[bash, -c, script, bin]`, so the binary is `$0` to the script and
/// the ceiling applies before it ever starts.
fn addCeilingedRun(
    b: *std.Build,
    name: []const u8,
    compile: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "bash", "-c" });
    run.addArg(b.fmt("ulimit -v {d}; exec \"$0\"", .{test_address_space_kb}));
    run.addFileArg(compile.getEmittedBin());
    run.setName(name);
    return run;
}

/// One acceptance shard: the test file is the module root and the library is
/// the import. The name is the step name, so `zig build test -- --list` and a
/// failure report both name the file.
///
/// **Why both imports.** They answer two ways a shard can reach the library, and
/// the difference is a module boundary rather than a preference. A shard that
/// writes `@import("dusk")` resolves `@import("vulkan")` through `dusk`'s own
/// imports. A shard that reaches `src/` by relative path —
/// `test/vulkan_device.zig` is the one today — becomes part of its own module,
/// and its `@import("vulkan")` has to resolve from that module. Declaring both
/// names on every shard lets a test file use either style; a file that mixes
/// them gets two copies of `src/vk/dispatch.zig` and two distinct
/// `dispatch.DeviceProcs` types, which is a defect in the test and not
/// something the build can reconcile.
///
/// **One bindings instance.** The shard's own `vulkan` import and the one
/// `dusk` carries are the same module object. Two objects rooted at
/// `src/vulkan.zig` in one compilation is the compiler error `file exists in
/// modules 'vulkan' and 'vulkan0'`, so `vulkan` arrives as a parameter instead
/// of being created here.
///
/// **libc.** The shard can open a library. `dusk` carries `link_libc`, and a
/// shard that reaches `src/` by relative path gets `platform/loader.zig` inside
/// its own Module, which the graph walk covers too. The root declares it as
/// well so a shard does not depend on which of the two imports the file happens
/// to use; `lib/std/Build/Step/Compile.zig:1055` turns the field into a single
/// `-lc` for the compilation, so the repeated declaration costs nothing.
fn addAcceptanceShard(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    sub_path: []const u8,
    target: std.Build.ResolvedTarget,
    library: *std.Build.Module,
    vulkan: *std.Build.Module,
) void {
    const compile = b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(sub_path),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dusk", .module = library },
                .{ .name = "vulkan", .module = vulkan },
            },
        }),
    });
    test_step.dependOn(&addCeilingedRun(b, name, compile).step);
}
