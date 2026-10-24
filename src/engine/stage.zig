//! `engine.stage`: the three shader stages and the three-slot per-stage
//! container.
//!
//! **What this is.** Dawn's `PerStage<T>` (`src/dawn/native/PerStage.h:60-88`),
//! its `SingleShaderStage` (`:41`) and the two functions over them
//! (`:54-55`, `PerStage.cpp:32-40`). A stage is one of three, and a per-stage
//! value is three slots indexed by stage ordinal.
//!
//! **What this does not claim.** It does not claim the stage bitmask itself.
//! `api.bitmask.ShaderStage` is generated from `dawn.json` and lives in
//! `src/api`; this module converts between that wire form and the ordinal, and
//! holds no third representation.
//!
//! **Why the ordinal is the index.** `PerStage` is walked by `inline for` over
//! `stages`, so a fourth stage is a compile error at every walk rather than a
//! slot nothing reads. Upstream instead hands out an `ityp::bitset` from
//! `IterateStages` (`PerStage.h:54`), whose body is a cast; a bitset walk is not
//! a Zig idiom and buys nothing over three ordinals.

const std = @import("std");

const bitmask = @import("../api/bitmask.zig");

/// The wire stage mask, generated into `src/api` from `dawn.json`.
pub const ShaderStage = bitmask.ShaderStage;

/// The number of stages, from `kNumStages` (`common/Constants.h:42`).
pub const stage_count: usize = 3;

/// One shader stage. The declaration order is the ordinal order, and both the
/// API bit and the slot index are derived from it (`PerStage.h:47-52`).
pub const SingleShaderStage = enum(u8) {
    vertex,
    fragment,
    compute,
};

/// Every stage, in ordinal order. This is the order a walk takes and the order
/// a content hash over a `PerStage` uses, so the two agree by construction.
pub const stages: [stage_count]SingleShaderStage = .{
    .vertex,
    .fragment,
    .compute,
};

comptime {
    // The first three `static_assert`s of `PerStage.h:43-45`: every ordinal
    // addresses a slot.
    for (stages) |stage| {
        std.debug.assert(@backingInt(stage) < stage_count);
    }
    // The next three, `:47-52`: the API bit for a stage is the ordinal shifted
    // once. A wire value that stopped matching the ordinal would make
    // `atByBit` and `at` disagree about which slot they mean.
    for (stages) |stage| {
        std.debug.assert(stageBit(stage).toFlags() == @as(u32, 1) << stageOrdinal(stage));
    }
}

/// The wire bit for one stage, from `StageBit` (`PerStage.h:55`,
/// `PerStage.cpp:37`).
pub inline fn stageBit(stage: SingleShaderStage) ShaderStage {
    return ShaderStage.fromFlags(@as(u32, 1) << stageOrdinal(stage));
}

/// The slot a stage addresses. The range claim upstream checks with
/// `DAWN_CHECK` at `PerStage.cpp:38` is a claim about the enum, so it is a
/// comptime one here.
pub inline fn stageOrdinal(stage: SingleShaderStage) usize {
    const ordinal: usize = @backingInt(stage);
    std.debug.assert(ordinal < stage_count);
    return ordinal;
}

/// Every stage in `mask`, in ordinal order.
///
/// `IterateStages` (`PerStage.h:54`, `PerStage.cpp:32`) upstream. It returned
/// an `ityp::bitset` built by casting the mask, so the whole C++ function is
/// this one comparison per stage.
pub fn iterateStages(mask: ShaderStage) [stage_count]bool {
    const flags = mask.toFlags();
    var set: [stage_count]bool = @splat(false);
    inline for (0..stage_count) |ordinal| {
        const bit = @as(u32, 1) << ordinal;
        set[ordinal] = (flags & bit) == bit;
    }
    return set;
}

/// Whether one stage is in `mask`.
///
/// The second half of what `IterateStages` answered upstream, named so a
/// three-stage rule reads as three calls rather than a bitset walk.
pub inline fn stageIsSet(mask: ShaderStage, stage: SingleShaderStage) bool {
    const bit = @as(u32, 1) << stageOrdinal(stage);
    const flags = mask.toFlags();
    return (flags & bit) == bit;
}

/// Every stage, from `kAllStages` (`PerStage.h:57-58`).
pub const all_stages: ShaderStage = ShaderStage.fromFlags(
    (@as(u32, 1) << stage_count) - @as(u32, 1),
);

/// Three slots, one per stage, addressed by ordinal or by wire bit.
///
/// `PerStage<T>` (`PerStage.h:60-88`). The default is a comptime parameter
/// because Zig has no implicit member initialiser for an arbitrary `T`, and the
/// upstream `explicit PerStage(const T&)` constructor at `:64` is the same
/// value written to all three slots.
pub fn PerStage(comptime T: type, comptime default_value: T) type {
    return struct {
        const Self = @This();

        slots: [stage_count]T = .{ default_value, default_value, default_value },

        /// The value at one stage's ordinal.
        pub inline fn get(self: Self, stage: SingleShaderStage) T {
            return self.slots[stageOrdinal(stage)];
        }

        /// The slot one stage's ordinal addresses.
        pub inline fn at(self: *Self, stage: SingleShaderStage) *T {
            return &self.slots[stageOrdinal(stage)];
        }

        /// The value at one stage's wire bit.
        pub inline fn getByBit(self: Self, mask: ShaderStage) StageOfBitError!T {
            return self.get(try stageOfBit(mask));
        }

        /// The slot one stage's wire bit addresses.
        pub inline fn atByBit(self: *Self, mask: ShaderStage) StageOfBitError!*T {
            return self.at(try stageOfBit(mask));
        }
    };
}

/// The stage a single-bit mask names.
///
/// The second `operator[]` of `PerStage.h:75-84`, which asserts the mask is
/// non-zero, a power of two and within range. The assertion becomes the return
/// type: a mask that is not one stage has no answer, so the caller gets an
/// error it has to handle rather than a silent slot zero.
pub fn stageOfBit(mask: ShaderStage) StageOfBitError!SingleShaderStage {
    const flags = mask.toFlags();
    if (flags == 0) return error.EmptyStageMask;
    if (flags & (flags - @as(u32, 1)) != 0) return error.NotOneStageBit;
    const ordinal: usize = @ctz(flags);
    if (ordinal >= stage_count) return error.StageBitOutOfRange;
    return @fromBackingInt(@intCast(ordinal));
}

/// The three ways a mask can fail to name exactly one stage.
pub const StageOfBitError = error{
    EmptyStageMask,
    NotOneStageBit,
    StageBitOutOfRange,
};

test "a stage bit addresses the slot of the same ordinal" {
    inline for (stages) |stage| {
        var value: PerStage(u8, 0) = .{};
        value.at(stage).* = 7;
        try std.testing.expectEqual(@as(u8, 7), value.get(stage));
    }
}

test "a single-bit mask and an ordinal name the same slot" {
    inline for (stages) |stage| {
        const mask = stageBit(stage);
        try std.testing.expectEqual(stage, try stageOfBit(mask));
        try std.testing.expect(stageIsSet(all_stages, stage));
    }
}

test "all three stages is the only mask that holds all three" {
    try std.testing.expectEqual(@as(u32, 7), all_stages.toFlags());
    inline for (stages) |stage| {
        try std.testing.expect(stageIsSet(all_stages, stage));
    }
}

test "an empty or multi-stage mask names no single stage" {
    try std.testing.expectError(error.EmptyStageMask, stageOfBit(ShaderStage.fromFlags(0)));
    try std.testing.expectError(error.NotOneStageBit, stageOfBit(ShaderStage.fromFlags(3)));
    try std.testing.expectError(
        error.StageBitOutOfRange,
        stageOfBit(ShaderStage.fromFlags(@as(u32, 1) << stage_count)),
    );
}
