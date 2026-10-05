//! Build wiring for dusk.
//!
//! **What this build publishes.** One module, `dusk`, rooted at
//! `src/root.zig`. A dependent package reaches it as `dep.module("dusk")`.
//! No executable and no C artifact exist yet, so `dep.artifact("dusk")` is
//! unsupported and `zig-out/bin` stays empty. `docs/40-plan.md` names the
//! milestone that adds each; neither is declared before it exists.
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // The published values reach source through an options module, so a
    // consumer reads them from `@import("dusk")` rather than parsing the
    // manifest.
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "minimum_zig_version", minimum_zig_version);

    // The published module. Consumers import `@import("dusk")`.
    const mod = b.addModule("dusk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    // Library tests, once per safety mode. Both modes belong to the gate
    // because the house gate runs a plain `zig build test` with no
    // `-Doptimize`, so an optimized-only failure cannot slip past a Debug-only
    // run. The Debug shard is the published module itself, so a change that
    // breaks `dep.module("dusk")` breaks the gate. A module's mode is fixed at
    // creation, so ReleaseSafe needs a private equivalent.
    const test_step = b.step("test", "Run the library tests in Debug and ReleaseSafe");

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
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-ReleaseSafe", release_tests).step);

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
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    const cross_run = b.addRunArtifact(cross_tests);
    // A cached run executes no tests and cannot prove execution coverage.
    cross_run.has_side_effects = true;
    cross_test_step.dependOn(&cross_run.step);
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
