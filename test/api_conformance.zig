//! The M2 shard: the generated `src/api` still agrees with `dawn.json`.
//!
//! `tools/gen_api.zig` reads `dawn.json` and writes `src/api`. This file is
//! the other half of that claim: it names the three counts `docs/40-plan.md`
//! section M2 fixes and sweeps every enumerable domain the generator emits.
//! A new upstream entry, method or member moves a count and fails here.
//!
//! **What this file does not claim.** It does not claim a `dawn.json` was
//! read. The generator read it; this file checks what the generator wrote
//! against the numbers the plan recorded when it read the same revision.
//!
//! **The import is `@import("dusk")`.** The published module exposes `api`
//! through `src/root.zig`, and this shard reaches the library through it like
//! every other acceptance shard.

const std = @import("std");

const api = @import("dusk").api;
const bitmask = api.bitmask;
const enums = api.enums;
const handled = api.handled;

/// The census `docs/30-port-design.md` section 8.1 records for the pinned
/// Dawn revision, and the row budget `docs/40-plan.md` section M2 fixes.
const object_count = 347;
const method_count = 205;
const member_count = 571;

// The counts are comptime, so a drifted tree is a compile error and not a
// runtime failure nobody runs.
comptime {
    if (handled.entry_count != object_count) @compileError("dawn.json object count moved");
    if (handled.method_count != method_count) @compileError("dawn.json method count moved");
    if (handled.member_count != member_count) @compileError("dawn.json member count moved");
}

test "the census is 347 objects, 205 methods and 571 members" {
    try std.testing.expectEqual(object_count, handled.entry_count);
    try std.testing.expectEqual(method_count, handled.method_count);
    try std.testing.expectEqual(member_count, handled.member_count);
}

test "the generated domains are the ones the plan records" {
    try std.testing.expectEqual(65, handled.enum_count);
    try std.testing.expectEqual(88, handled.chained_count);
    try std.testing.expectEqual(6, handled.bitmask_count);
}

test "every API entry is ported" {
    inline for (@typeInfo(handled.Entry).@"enum".fields) |field| {
        const entry: handled.Entry = @enumFromInt(field.value);
        try std.testing.expectEqual(handled.Coverage.ported, handled.coverage(entry));
    }
}

test "the per-entry table sums to the totals" {
    var methods: usize = 0;
    var members: usize = 0;
    inline for (@typeInfo(handled.Entry).@"enum".fields) |field| {
        const entry: handled.Entry = @enumFromInt(field.value);
        const counts = handled.record(entry);
        methods += counts.methods;
        members += counts.members;
    }
    try std.testing.expectEqual(method_count, methods);
    try std.testing.expectEqual(member_count, members);
}

test "a chained struct belongs to a root and an extension to none" {
    inline for (@typeInfo(handled.Entry).@"enum".fields) |field| {
        const entry: handled.Entry = @enumFromInt(field.value);
        const counts = handled.record(entry);
        try std.testing.expectEqual(counts.chain_members, counts.extension_slots);
    }
}

test "every enum tag round-trips through @intFromEnum" {
    // One function instantiation per enum kind, each analysed on its own: the
    // tag type is a `type`, which exists only at comptime, so the sweep needs a
    // comptime-known `kind`. Unrolling all 65 kinds into a single block also
    // multiplies every tag into one body and exceeds the branch quota, while
    // 65 single-kind instantiations stay under it.
    inline for (@typeInfo(enums.Enum).@"enum".fields) |kind| {
        try roundTripEnum(@enumFromInt(kind.value));
    }
}

/// The `comptime` parameter is the split: Zig instantiates this body once per
/// kind, so each instantiation names one tag type and unrolls one tag list.
fn roundTripEnum(comptime kind: enums.Enum) !void {
    const tag_type = comptime enums.tagType(kind);
    inline for (@typeInfo(tag_type).@"enum".fields) |tag| {
        const value: tag_type = @enumFromInt(tag.value);
        try std.testing.expectEqual(tag.value, @intFromEnum(value));
        try std.testing.expectEqualStrings(tag.name, @tagName(value));
    }
}

/// One bitmask's wire values, and the type they belong to. The six
/// declarations are named rather than swept, because a generated enum domain
/// for the bitmasks does not exist and adding one would be a second ledger.
const Bitmask = struct {
    name: []const u8,
    count: usize,
    flags: []const u32,
    T: type,
};

const bitmasks = [_]Bitmask{
    .{
        .name = "buffer usage",
        .count = 12,
        .flags = bitmask.BufferUsage_flag_values,
        .T = bitmask.BufferUsage,
    },
    .{
        .name = "color write mask",
        .count = 6,
        .flags = bitmask.ColorWriteMask_flag_values,
        .T = bitmask.ColorWriteMask,
    },
    .{
        .name = "map mode",
        .count = 3,
        .flags = bitmask.MapMode_flag_values,
        .T = bitmask.MapMode,
    },
    .{
        .name = "shader stage",
        .count = 4,
        .flags = bitmask.ShaderStage_flag_values,
        .T = bitmask.ShaderStage,
    },
    .{
        .name = "texture usage",
        .count = 8,
        .flags = bitmask.TextureUsage_flag_values,
        .T = bitmask.TextureUsage,
    },
    .{
        .name = "heap property",
        .count = 6,
        .flags = bitmask.HeapProperty_flag_values,
        .T = bitmask.HeapProperty,
    },
};

test "every bitmask value round-trips through @bitCast" {
    // One function instantiation per declaration, for the same reason as the
    // enum sweep: `Bitmask.T` is a `type`, so each body has to name its own
    // mask type at comptime rather than iterate one array at runtime.
    inline for (bitmasks) |one| {
        try roundTripBitmask(one);
    }
}

fn roundTripBitmask(comptime one: Bitmask) !void {
    try std.testing.expectEqual(one.count, one.flags.len);
    for (one.flags) |value| {
        const mask: one.T = one.T.fromFlags(value);
        try std.testing.expectEqual(value, mask.toFlags());
    }
}

test "every bitmask has a flag set, and the empty mask has none" {
    // The same split as the round trip above: `Bitmask.T` is a `type`, so the
    // empty mask is spelled per declaration at comptime and the array is a
    // comptime sweep rather than a runtime loop.
    inline for (bitmasks) |one| {
        try emptyMaskHasNoFlag(one);
    }
}

/// `has` is subset containment, `(ours & theirs) == theirs`
/// (`src/api/bitmask.zig:37-41`). So `has` on the empty flag set is true for
/// every mask, the empty one included, because the empty set is a subset of
/// every set. "The empty mask has no flag set" is the other half of that same
/// definition: it contains no wire value that names a bit.
fn emptyMaskHasNoFlag(comptime one: Bitmask) !void {
    const empty: one.T = .{};
    try std.testing.expect(empty.has(.{}));
    for (one.flags) |value| {
        // The table's zero entry is the `none` wire value, which names no bit
        // and so is the one value the empty mask may hold.
        if (value == 0) continue;
        try std.testing.expect(!empty.has(one.T.fromFlags(value)));
    }
    try std.testing.expectEqual(@as(u32, 0), empty.toFlags());
}

test "every API declaration is reachable from the module root" {
    std.testing.refAllDecls(api);
}
