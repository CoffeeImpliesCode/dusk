//! dusk — a pure Zig reimplementation of the Google Dawn WebGPU engine on Vulkan.
//!
//! **What this package is.** Dawn implements the WebGPU API for browsers and
//! native applications, with a Vulkan backend as one of several. This package
//! re-implements that engine in Zig, with Vulkan as the only backend. There is
//! no C++ anywhere in the build; a C dependency is allowed where one is
//! genuinely the better tool.
//!
//! **What this file is.** The module root. Everything a consumer reaches must
//! be re-exported here. Apart from the two values below it carries no
//! declarations, because the port has not started: the module layout, the
//! naming of each shard, and the order in which they land are fixed by
//! `docs/10-architecture.md` and `docs/30-port-design.md`, and the milestones
//! that add them are in `docs/40-plan.md`.
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
