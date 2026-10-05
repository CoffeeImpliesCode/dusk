//! dusk — a pure Zig reimplementation of the Google Dawn WebGPU engine on Vulkan.
//!
//! **What this package is.** Dawn implements the WebGPU API for browsers and
//! native applications, with a Vulkan backend as one of several. This package
//! re-implements that engine in Zig, with Vulkan as the only backend. There is
//! no C++ anywhere in the build; a C dependency is allowed where one is
//! genuinely the better tool.
//!
//! **What this file is.** The module root. Everything a consumer reaches must
//! be re-exported here, and nothing else: each line below names one module of
//! `docs/10-architecture.md` and points at that module's own root. The module
//! layout is fixed by `docs/10-architecture.md` and `docs/30-port-design.md`,
//! and the milestones that fill each module in are in `docs/40-plan.md`.
//!
//! **Read first.** `docs/02-dawn-design.md` is the upstream surface being
//! ported, mapped at a pinned Dawn revision. `docs/20-dependencies.md` is the
//! dependency ladder and the C-library questions. `AGENTS.md` holds the house
//! rules this code is written under.

const std = @import("std");
const builtin = @import("builtin");

/// Package version, mirrored from `.version` in `build.zig.zon` through the
/// `build_options` module.
///
/// Zig's build API exposes no manifest reader, so `build.zig` holds a second
/// copy. A release bumps both.
///
/// The C ABI needs it at the milestone that adds the shared library, for its
/// version symbol and the version macro in the header. `docs/30-port-design.md`
/// owns that.
pub const version = @import("build_options").version;

/// Compiler floor the package declares, mirrored from
/// `.minimum_zig_version` in `build.zig.zon`. It is a floor, so building with a
/// later compiler is allowed; building with an earlier one is not, and would
/// ship a package whose documented compiler does not build it.
pub const minimum_zig_version = @import("build_options").minimum_zig_version;

comptime {
    // The anyzig shim on this host reads `.minimum_zig_version` to select the
    // toolchain, so a mismatch between the manifest and the running compiler
    // means a stale toolchain is building the package. The test below bounds
    // the floor; this rejects an exact disagreement, which is a different
    // defect: a toolchain the project never declared.
    if (!std.mem.eql(u8, minimum_zig_version, builtin.zig_version_string)) {
        @compileError("the running compiler is not the one build.zig.zon declares: run through direnv");
    }
}

/// The nine modules, each a namespace only. A consumer reaches a name through
/// the module that owns it: `dusk.pipeline.BindingCounts` and
/// `dusk.command.commands.Tag`, never through this file. `api` is the one
/// module whose root is a separate file from the generated tree it fronts,
/// because `src/api/api.zig` is generated and a generated file carries no hand
/// edit.
pub const api = @import("api/root.zig");
pub const command = @import("command/root.zig");
pub const core = @import("core/root.zig");
pub const engine = @import("engine/root.zig");
pub const memory = @import("memory/root.zig");
pub const pipeline = @import("pipeline/root.zig");
pub const platform = @import("platform/root.zig");
pub const spirv = @import("spirv/root.zig");
pub const vk = @import("vk/root.zig");

test "every published module is analysed, so its in-file tests run" {
    // A `pub const` re-export is a name, not a reference. The compiler leaves
    // the namespace unresolved, so it never imports the file behind it and
    // never collects that file's test blocks. Measured on this tree: the two
    // tests below were the only ones `zig test src/root.zig` ran, against 78
    // `test` blocks under `src/`.
    //
    // `refAllDecls` on a module namespace references every name that module
    // publishes. A file that is imported is in the compilation, and a file in
    // the compilation carries its tests. Applying it to the nine namespaces
    // rather than to this file is the part that matters: the module roots
    // re-export their own files' contents, so a reference to any published
    // name resolves the private imports those roots hold (`api/root.zig`'s
    // `generated`, for one) and reaches the file behind them.
    //
    // Nothing new enters the published module's dependency graph. Every type
    // referenced below is already a `pub const` above, so a non-test build of
    // the package resolves nothing this block does not.
    //
    // `refAllDeclsRecursive` is not the mechanism and is not available:
    // Zig 0.16.0's `lib/std/testing.zig` has no such function.
    inline for (.{
        api,
        command,
        core,
        engine,
        memory,
        pipeline,
        platform,
        spirv,
        vk,
    }) |module| std.testing.refAllDecls(module);
}

test "the running compiler is at least the declared floor" {
    // A floor raised above the compiler the gate runs would leave the gate
    // green and every consumer on the documented floor unable to build. That
    // is the defect this guards.
    const running = builtin.zig_version;

    var parts = std.mem.splitScalar(u8, minimum_zig_version, '.');
    const want: std.SemanticVersion = .{
        .major = try std.fmt.parseInt(usize, parts.next() orelse return error.BadFloor, 10),
        .minor = try std.fmt.parseInt(usize, parts.next() orelse return error.BadFloor, 10),
        .patch = try std.fmt.parseInt(usize, parts.next() orelse return error.BadFloor, 10),
    };
    if (parts.next() != null) return error.BadFloor;

    try std.testing.expect(running.order(want) != .lt);
}

test "the published version is three numeric components" {
    // `version` becomes a C header macro and a shared library version symbol at
    // the ABI milestone, both of which take `major.minor.patch`. A malformed
    // bump would produce a header that does not compile for a C consumer.
    var parts = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        _ = try std.fmt.parseInt(u32, part, 10);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
