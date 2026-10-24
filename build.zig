//! Build wiring for dusk.
//!
//! Publishes the `dusk` module. Generation is explicit; tests use Debug and ReleaseSafe shards.

const std = @import("std");

/// Package version. Mirrors `.version` in `build.zig.zon`.
///
/// Zig's build API exposes no manifest reader, so this is a second copy. A
/// release bumps both, and `src/root.zig` checks the shape of this value
/// because the C ABI header embeds it.
const version = "0.0.0";

/// Compiler floor, mirrored in `build.zig.zon`.
const minimum_zig_version = "0.17.0";

/// Address-space ceiling for one test shard, in kibibytes. Four gigabytes is
/// far above an honest test and far below what an unbounded allocation loop
/// reaches in a minute, so a runaway test fails quickly and visibly instead of
/// taking the machine with it.
const test_address_space_kb: u32 = 4 * 1024 * 1024;

/// Header path relative to the pinned Vulkan include tree.
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

/// Name the generator writes its output under, in the cache and in scratch.
const dispatch_name = "dispatch.zig";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const vulkan_debug = addVulkanModule(b, target, .debug);
    const vulkan_release = addVulkanModule(b, target, .safe);
    const vulkan_published = switch (optimize) {
        .debug => vulkan_debug,
        .safe => vulkan_release,
        .fast, .small => addVulkanModule(b, target, optimize),
    };

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
    // declaration covers every consumer importing the published module.
    const mod = b.addModule("dusk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "vulkan", .module = vulkan_published },
        },
    });

    // The published module follows the consumer's optimize option. Acceptance
    // graphs remain explicitly Debug and ReleaseSafe regardless of that option,
    // and each graph shares exactly one matching Vulkan module instance.
    const debug_mod = if (optimize == .debug) mod else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "vulkan", .module = vulkan_debug },
        },
    });
    const release_mod = if (optimize == .safe) mod else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "vulkan", .module = vulkan_release },
        },
    });
    const test_step = b.step(
        "test",
        "Run the library tests in Debug and ReleaseSafe, and one acceptance shard per test file",
    );
    addFetchDawnStep(b, test_step);
    addNativeKernelSteps(b, test_step);

    const debug_tests = b.addTest(.{
        .name = "test-Debug",
        .root_module = debug_mod,
    });
    test_step.dependOn(&addCeilingedRun(b, "test-Debug", debug_tests).step);

    const release_tests = b.addTest(.{
        .name = "test-ReleaseSafe",
        .root_module = release_mod,
    });
    test_step.dependOn(&addCeilingedRun(b, "test-ReleaseSafe", release_tests).step);

    // The generated dispatch table is not reachable from `src/root.zig` yet, so
    // it gets a test shard of its own in both safety modes. Checked-in
    // generated code is part of the library: without this the gate would never
    // compile it.
    const dispatch_debug = b.addTest(.{
        .name = "test-vk-dispatch-Debug",
        .root_module = addDispatchTestModule(b, target, .debug, vulkan_debug),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-vk-dispatch-Debug", dispatch_debug).step);

    const dispatch_release = b.addTest(.{
        .name = "test-vk-dispatch-ReleaseSafe",
        .root_module = addDispatchTestModule(b, target, .safe, vulkan_release),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-vk-dispatch-ReleaseSafe", dispatch_release).step);

    // The drift test regenerates the table and compares the bytes. One mode is
    // enough: byte identity does not depend on the safety mode, and the two
    // dispatch shards above already answer that question.
    const drift_options = b.addOptions();
    drift_options.addOptionPath("checked_in_path", b.path(dispatch_zig_sub_path));
    const drift_tests = b.addTest(.{
        .name = "test-gen-dispatch-drift",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dispatch_drift_test_sub_path),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "gen_dispatch", .module = addGenDispatchModule(b) },
                .{ .name = "drift_options", .module = drift_options.createModule() },
            },
        }),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-gen-dispatch-drift", drift_tests).step);

    // One Debug shard per file under `test/`, plus the core in-file regressions.
    // The two shards above run the published module in both safety modes; a shard
    // is a separate module, so one file that stops compiling
    // fails alone and names itself in the step graph. The drift test is the one
    // file with no entry here: it needs the generator and its options module
    // rather than the library, so it is declared where those are.
    const acceptance_shards = [_]struct { name: []const u8, sub_path: []const u8 }{
        .{ .name = "test-api-conformance", .sub_path = "test/api_conformance.zig" },
        .{ .name = "test-async-registry", .sub_path = "test/async_registry.zig" },
        .{ .name = "test-async-root-requests", .sub_path = "test/async_root_requests.zig" },
        .{ .name = "test-bind-group", .sub_path = "test/bind_group.zig" },
        .{ .name = "test-blit", .sub_path = "test/blit.zig" },
        .{ .name = "test-buffer", .sub_path = "test/buffer.zig" },
        .{ .name = "test-cache-artifact", .sub_path = "test/cache_artifact.zig" },
        .{ .name = "test-color-space", .sub_path = "test/color_space.zig" },
        .{ .name = "test-command-replay", .sub_path = "test/command_replay.zig" },
        .{ .name = "test-command-stream", .sub_path = "test/command_stream.zig" },
        .{ .name = "test-compute-specialization", .sub_path = "test/compute_specialization.zig" },
        .{ .name = "test-compatibility", .sub_path = "test/compatibility.zig" },
        // CoreDevice's in-file tests also root ObjectArena and error regressions.
        .{ .name = "test-core-regressions", .sub_path = "src/core/device.zig" },
        .{ .name = "test-error-scope", .sub_path = "test/error_scope.zig" },
        .{ .name = "test-error-sets", .sub_path = "test/error_sets.zig" },
        .{ .name = "test-formats", .sub_path = "test/formats.zig" },
        .{ .name = "test-limits", .sub_path = "test/limits.zig" },
        .{ .name = "test-memory", .sub_path = "test/memory.zig" },
        .{ .name = "test-null-device", .sub_path = "test/null_device.zig" },
        .{ .name = "test-native-async-descriptors", .sub_path = "test/native_async_descriptors.zig" },
        .{ .name = "test-native-async-device", .sub_path = "test/native_async_device.zig" },
        .{ .name = "test-native-async-map-queue", .sub_path = "test/native_async_map_queue.zig" },
        .{ .name = "test-native-async-pipeline", .sub_path = "test/native_async_pipeline.zig" },
        .{ .name = "test-native-async-scope-info", .sub_path = "test/native_async_scope_info.zig" },
        .{ .name = "test-native-device", .sub_path = "test/native_device.zig" },
        .{ .name = "test-native-resource-store", .sub_path = "test/native_resource_store.zig" },
        .{ .name = "test-native-sampler", .sub_path = "test/native_sampler.zig" },
        .{ .name = "test-native-attachment-state", .sub_path = "test/native_attachment_state.zig" },
        .{ .name = "test-native-full256-immediate", .sub_path = "test/native_full256_immediate.zig" },
        .{ .name = "test-native-weak-index", .sub_path = "src/native_weak_index_test.zig" },
        .{ .name = "test-native-attachment-store", .sub_path = "src/native_attachment_store_test.zig" },
        .{ .name = "test-native-render-state", .sub_path = "src/native_render_state_test.zig" },
        .{ .name = "test-object-arena", .sub_path = "test/object_arena.zig" },
        .{ .name = "test-pipeline-cache", .sub_path = "test/pipeline_cache.zig" },
        .{ .name = "test-pipeline-canonical-layout", .sub_path = "test/pipeline_canonical_layout.zig" },
        .{ .name = "test-pipeline-entry-point", .sub_path = "test/pipeline_entry_point.zig" },
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
        addAcceptanceShard(b, test_step, shard.name, shard.sub_path, target, .debug, debug_mod, vulkan_debug);
    }
    // ReleaseSafe acceptance must compile the test root, library, and bindings
    // in the same safety mode; a second step pointing at a Debug run proves
    // nothing about ReleaseSafe execution.
    const release_acceptance_shards = [_]struct { name: []const u8, sub_path: []const u8 }{
        .{
            .name = "test-async-registry-release-safe",
            .sub_path = "test/async_registry.zig",
        },
        .{
            .name = "test-async-root-requests-release-safe",
            .sub_path = "test/async_root_requests.zig",
        },
        .{
            .name = "test-cache-artifact-release-safe",
            .sub_path = "test/cache_artifact.zig",
        },
        .{
            .name = "test-core-regressions-release-safe",
            .sub_path = "src/core/device.zig",
        },
        .{
            .name = "test-error-scope-release-safe",
            .sub_path = "test/error_scope.zig",
        },
        .{
            .name = "test-object-arena-release-safe",
            .sub_path = "test/object_arena.zig",
        },
        .{
            .name = "test-compute-specialization-release-safe",
            .sub_path = "test/compute_specialization.zig",
        },
        .{
            .name = "test-render-pipeline-release-safe",
            .sub_path = "test/render_pipeline.zig",
        },
        .{
            .name = "test-triangle-release-safe",
            .sub_path = "test/triangle.zig",
        },
        .{
            .name = "test-spirv-release-safe",
            .sub_path = "test/spirv.zig",
        },
        .{
            .name = "test-pipeline-cache-release-safe",
            .sub_path = "test/pipeline_cache.zig",
        },
        .{
            .name = "test-pipeline-entry-point-release-safe",
            .sub_path = "test/pipeline_entry_point.zig",
        },
        .{
            .name = "test-api-conformance-release-safe",
            .sub_path = "test/api_conformance.zig",
        },
        .{
            .name = "test-native-async-descriptors-release-safe",
            .sub_path = "test/native_async_descriptors.zig",
        },
        .{
            .name = "test-native-async-device-release-safe",
            .sub_path = "test/native_async_device.zig",
        },
        .{
            .name = "test-native-async-map-queue-release-safe",
            .sub_path = "test/native_async_map_queue.zig",
        },
        .{
            .name = "test-native-async-pipeline-release-safe",
            .sub_path = "test/native_async_pipeline.zig",
        },
        .{
            .name = "test-native-async-scope-info-release-safe",
            .sub_path = "test/native_async_scope_info.zig",
        },
        .{
            .name = "test-native-device-release-safe",
            .sub_path = "test/native_device.zig",
        },
        .{
            .name = "test-null-device-release-safe",
            .sub_path = "test/null_device.zig",
        },
        .{
            .name = "test-limits-release-safe",
            .sub_path = "test/limits.zig",
        },
        .{
            .name = "test-worker-pool-release-safe",
            .sub_path = "test/worker_pool.zig",
        },
        .{ .name = "test-native-resource-store-release-safe", .sub_path = "test/native_resource_store.zig" },
        .{ .name = "test-native-sampler-release-safe", .sub_path = "test/native_sampler.zig" },
        .{ .name = "test-native-attachment-state-release-safe", .sub_path = "test/native_attachment_state.zig" },
        .{ .name = "test-native-full256-immediate-release-safe", .sub_path = "test/native_full256_immediate.zig" },
        .{ .name = "test-native-weak-index-release-safe", .sub_path = "src/native_weak_index_test.zig" },
        .{ .name = "test-native-attachment-store-release-safe", .sub_path = "src/native_attachment_store_test.zig" },
        .{ .name = "test-native-render-state-release-safe", .sub_path = "src/native_render_state_test.zig" },
        .{ .name = "test-pipeline-canonical-layout-release-safe", .sub_path = "test/pipeline_canonical_layout.zig" },
    };
    for (release_acceptance_shards) |shard| {
        addAcceptanceShard(
            b,
            test_step,
            shard.name,
            shard.sub_path,
            target,
            .safe,
            release_tests.root_module,
            vulkan_release,
        );
    }

    const native_utilities_debug = b.step(
        "test-native-utilities-debug",
        "Run all native utility acceptance shards in Debug",
    );
    const native_utilities_release = b.step(
        "test-native-utilities-release-safe",
        "Run all native utility acceptance shards in ReleaseSafe",
    );
    test_step.dependOn(native_utilities_debug);
    test_step.dependOn(native_utilities_release);
    const native_utility_shards = [_]struct { name: []const u8, sub_path: []const u8 }{
        .{ .name = "test-native-kernels", .sub_path = "test/native_kernels.zig" },
        .{ .name = "test-native-indirect", .sub_path = "test/native_indirect.zig" },
        .{ .name = "test-native-timestamps", .sub_path = "test/native_timestamps.zig" },
        .{ .name = "test-native-blit", .sub_path = "test/native_blit.zig" },
        .{ .name = "test-native-external-texture", .sub_path = "test/native_external_texture.zig" },
        .{ .name = "test-native-internal-buffers", .sub_path = "test/native_internal_buffers.zig" },
        .{ .name = "test-native-derived-roots", .sub_path = "test/native_derived_roots.zig" },
        .{
            .name = "test-native-internal-resources",
            .sub_path = "test/native_internal_resources.zig",
        },
        .{ .name = "test-native-utility-device", .sub_path = "test/native_utility_device.zig" },
        .{
            .name = "test-native-utility-capabilities",
            .sub_path = "test/native_utility_capabilities.zig",
        },
        .{ .name = "test-native-utility-frontend", .sub_path = "test/native_utility_frontend.zig" },
        .{
            .name = "test-native-combined-reflection",
            .sub_path = "test/native_combined_reflection.zig",
        },
    };
    for (native_utility_shards) |shard| {
        addAcceptanceShard(
            b,
            native_utilities_debug,
            shard.name,
            shard.sub_path,
            target,
            .debug,
            debug_mod,
            vulkan_debug,
        );
        addAcceptanceShard(
            b,
            native_utilities_release,
            b.fmt("{s}-release-safe", .{shard.name}),
            shard.sub_path,
            target,
            .safe,
            release_mod,
            vulkan_release,
        );
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
            .optimize = .debug,
            // An explicit Debug root keeps cross-test independent of the
            // published module's consumer-selected optimize mode.
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
    optimize: std.lang.Optimize,
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
    optimize: std.lang.Optimize,
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
        .optimize = .debug,
    });
}

/// Rewrites bindings and dispatch using Vulkan-Headers v1.4.365.
/// Supply the include tree through `-Dheader-dir` or `DUSK_VULKAN_HEADERS`.
fn addGenerateStep(b: *std.Build) void {
    const generate_step = b.step(
        "generate",
        "Rewrite src/vulkan.zig and src/vk/dispatch.zig from the pinned inputs",
    );

    // The header tree can be outside the package.
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

    // The header is freestanding and does not need libc.
    const translate_c = b.addSystemCommand(&.{ b.graph.zig_exe, "translate-c" });
    translate_c.setCwd(.{ .cwd_relative = header_dir });
    translate_c.addArgs(&.{ "-I", ".", vulkan_header_sub_path });
    const bindings = translate_c.captureStdOut(.{ .basename = vulkan_name });
    const pin_check = std.Build.Step.CheckFile.create(b, bindings, .{
        .expected_matches = &.{pinned_header_version_line},
    });

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
    // Gate publication of both files on the pin check. Aggregate siblings can
    // run independently, so a failed check alone cannot prevent source writes.
    update.step.dependOn(&pin_check.step);
    update.addCopyFileToSource(bindings, vulkan_zig_sub_path);
    update.addCopyFileToSource(rendered, dispatch_zig_sub_path);
    generate_step.dependOn(&update.step);
}

fn addFetchDawnStep(b: *std.Build, aggregate_tests: *std.Build.Step) void {
    const step = b.step("fetch-dawn", "Fetch the pinned Dawn source reference (explicit network step)");
    const destination = b.option(
        []const u8,
        "dawn-dir",
        "Destination for the pinned Dawn source checkout",
    ) orelse blk: {
        if (b.graph.environ_map.get("DUSK_DAWN_SRC")) |source| {
            if (source.len != 0) break :blk source;
        }
        const home = b.graph.environ_map.get("HOME") orelse {
            const missing = std.Build.Step.Fail.create(
                b,
                "fetch-dawn requires HOME or an explicit -Ddawn-dir=<destination>",
            );
            step.dependOn(&missing.step);
            return;
        };
        break :blk b.pathJoin(&.{ home, ".cache", "dusk-research", "research", "dawn" });
    };
    const module = b.createModule(.{
        .root_source_file = b.path("tools/fetch_dawn.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const executable = b.addExecutable(.{ .name = "fetch-dawn", .root_module = module });
    const run = b.addRunArtifact(executable);
    run.addArg(destination);
    run.has_side_effects = true;
    step.dependOn(&run.step);

    const tests = b.addTest(.{ .name = "test-dawn-pin", .root_module = module });
    const test_step = b.step("test-dawn-pin", "Test Dawn pin and checkout safety validation");
    const test_run = addCeilingedRun(b, "test-dawn-pin", tests);
    test_step.dependOn(&test_run.step);
    aggregate_tests.dependOn(&test_run.step);
}

fn addNativeKernelSteps(b: *std.Build, aggregate_tests: *std.Build.Step) void {
    const tint_path = b.option(
        []const u8,
        "tint-path",
        "External pinned Tint executable (overrides DUSK_TINT for explicit kernel steps)",
    );
    const debug_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_native_kernels.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const release_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_native_kernels.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const tool_test_shards = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "test-gen-native-kernels", .module = debug_module },
        .{ .name = "test-gen-native-kernels-release-safe", .module = release_module },
    };
    for (tool_test_shards) |shard| {
        const tests = b.addTest(.{ .name = shard.name, .root_module = shard.module });
        const run = addCeilingedRun(b, shard.name, tests);
        run.setCwd(b.path("."));
        const step = b.step(shard.name, "Test the std-only native kernel generator");
        step.dependOn(&run.step);
        aggregate_tests.dependOn(&run.step);
    }

    // Only explicit source steps can invoke Tint or replace committed artifacts.
    const executable = b.addExecutable(.{
        .name = "gen-native-kernels",
        .root_module = release_module,
    });
    const source_steps = [_]struct {
        name: []const u8,
        description: []const u8,
        argument: []const u8,
    }{
        .{
            .name = "generate-native-kernels",
            .description = "Regenerate committed native kernels with external pinned Tint",
            .argument = "--regen",
        },
        .{
            .name = "check-native-kernels",
            .description = "Check committed native kernels with external pinned Tint",
            .argument = "--check",
        },
    };
    for (source_steps) |source_step| {
        const run = b.addRunArtifact(executable);
        run.addArg(source_step.argument);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        if (tint_path) |path| run.setEnvironmentVariable("DUSK_TINT", path);
        const step = b.step(source_step.name, source_step.description);
        step.dependOn(&run.step);
    }
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
/// the import. Its named step and the aggregate `test` step share one runner.
/// `zig build test-memory` selects only that shard. A failure names its file.
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
    optimize: std.lang.Optimize,
    library: *std.Build.Module,
    vulkan: *std.Build.Module,
) void {
    const compile = b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(sub_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dusk", .module = library },
                .{ .name = "vulkan", .module = vulkan },
            },
        }),
    });
    const run = addCeilingedRun(b, name, compile);
    test_step.dependOn(&run.step);
    const shard_step = b.step(name, b.fmt("Run acceptance shard {s}", .{sub_path}));
    shard_step.dependOn(&run.step);
}
