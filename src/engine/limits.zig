//! `engine.limits`: the 36-row tiered limit table and the compat-column
//! selection.
//!
//! **What this is.** Dawn's `Limits.cpp` X-macro ladder (`:43-168`), the
//! `LimitClass` templates of `Limits.h:42-98`, `CombinedLimits` (`:103-108`)
//! and `Limits.cpp:185-191`'s `GetDefaultLimits`. The ladder is 36 rows in
//! eleven groups; every row carries one compat column and one column per tier.
//!
//! Required limits are validated and reified against queried physical bounds.
//! Defaults are bounded by those same values; compatibility metadata is retained.
//!
//! **Why a comptime table.** §1's goal for M7 is that a compat check is a field
//! read. The table is a comptime array, so `defaultLimits` is a projection and a
//! wrong row is a compile error rather than a value a device reports.

const std = @import("std");

const api = @import("../api/api.zig");

/// Byte counts stay named because the tier columns read as byte counts.
pub const mebibyte: u64 = 1 << 20;
pub const gibibyte: u64 = 1 << 30;

/// Which struct a row lands in, from the first argument of the upstream `X(...)`
/// macro. `CompatibilityModeLimits` is a chained struct upstream and a nested
/// optional here, because the port has no chain pointers.
pub const Scope = enum { v1, compat };

/// Which direction counts as better, from the second argument of `X(...)`.
/// `Maximum` is better when larger (`Limits.h:71-72`); `Alignment` is better
/// when smaller (`:53-54`). The two directions are the reason the compat
/// comparison inverts for an alignment row.
pub const Class = enum { alignment, maximum };

/// The eleven tier groups, in `LIMITS_EACH_GROUP` order (`Limits.cpp:144-155`).
/// The order is load-bearing: tiering walks group by group, and every row of a
/// group must declare the same number of tiers.
pub const Group = enum {
    workgroup_storage_size,
    workgroup_size,
    storage_buffer_binding_size,
    max_buffer_size,
    resource_bindings,
    storage_buffer_bindings,
    attachments,
    inter_stage_shader_variables,
    texture_dimensions,
    immediate_size,
    other,
};

pub const group_count: usize = @typeInfo(Group).@"enum".fields.len;

/// One limit row: `X(scope, class, name, compat, base, tiers...)` from
/// `Limits.cpp:43-140`.
///
/// `tiers[0]` is the `base` argument, which is the core-mode default; `compat`
/// is the compatibility-mode default. Both are kept as `u64` so one row type
/// serves the three `u64` descriptor fields and the rest, and `@intCast` into
/// the descriptor is the narrowing check.
pub const Row = struct {
    group: Group,
    scope: Scope,
    class: Class,
    field: Field,
    compat: u64,
    tiers: []const u64,
};

/// The 36 limit fields, spelled exactly as `api.Limits` and
/// `api.CompatibilityModeLimits` spell them, and declared in table order so row
/// `i` carries `@enumFromInt(i)`.
pub const Field = enum {
    max_compute_workgroup_storage_size,
    max_compute_invocations_per_workgroup,
    max_compute_workgroup_size_x,
    max_compute_workgroup_size_y,
    max_compute_workgroup_size_z,
    max_compute_workgroups_per_dimension,
    max_storage_buffer_binding_size,
    max_buffer_size,
    max_dynamic_uniform_buffers_per_pipeline_layout,
    max_dynamic_storage_buffers_per_pipeline_layout,
    max_sampled_textures_per_shader_stage,
    max_samplers_per_shader_stage,
    max_storage_textures_per_shader_stage,
    max_storage_textures_in_fragment_stage,
    max_storage_textures_in_vertex_stage,
    max_uniform_buffers_per_shader_stage,
    max_storage_buffers_per_shader_stage,
    max_storage_buffers_in_fragment_stage,
    max_storage_buffers_in_vertex_stage,
    max_color_attachment_bytes_per_sample,
    max_inter_stage_shader_variables,
    max_texture_dimension_1d,
    max_texture_dimension_2d,
    max_texture_dimension_3d,
    max_texture_array_layers,
    max_immediate_size,
    max_bind_groups,
    max_bind_groups_plus_vertex_buffers,
    max_bindings_per_bind_group,
    max_uniform_buffer_binding_size,
    min_uniform_buffer_offset_alignment,
    min_storage_buffer_offset_alignment,
    max_vertex_buffers,
    max_vertex_attributes,
    max_vertex_buffer_array_stride,
    max_color_attachments,
};

/// The 36 rows, in `Limits.cpp` file order.
///
/// Row `i` carries `@enumFromInt(i)`, so `rows[@intFromEnum(row.field)]` is the
/// same row read back. The table asserts that, which is what lets `fieldOf` be
/// an index rather than a search.
pub const rows: [36]Row = .{
    // LIMITS_WORKGROUP_STORAGE_SIZE (Limits.cpp:43-44).
    .{
        .group = .workgroup_storage_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_compute_workgroup_storage_size,
        .compat = 16384,
        .tiers = &.{ 16384, 32768, 49152, 65536 },
    },
    // LIMITS_WORKGROUP_SIZE (Limits.cpp:50-55).
    .{
        .group = .workgroup_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_compute_invocations_per_workgroup,
        .compat = 128,
        .tiers = &.{ 256, 1024 },
    },
    .{
        .group = .workgroup_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_compute_workgroup_size_x,
        .compat = 128,
        .tiers = &.{ 256, 1024 },
    },
    .{
        .group = .workgroup_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_compute_workgroup_size_y,
        .compat = 128,
        .tiers = &.{ 256, 1024 },
    },
    .{
        .group = .workgroup_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_compute_workgroup_size_z,
        .compat = 64,
        .tiers = &.{ 64, 64 },
    },
    .{
        .group = .workgroup_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_compute_workgroups_per_dimension,
        .compat = 65535,
        .tiers = &.{ 65535, 65535 },
    },
    // LIMITS_STORAGE_BUFFER_BINDING_SIZE (Limits.cpp:61-62).
    .{
        .group = .storage_buffer_binding_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_storage_buffer_binding_size,
        .compat = 128 * mebibyte,
        .tiers = &.{
            128 * mebibyte,
            256 * mebibyte,
            512 * mebibyte,
            gibibyte,
            2 * gibibyte - 4,
            4 * gibibyte - 4,
        },
    },
    // LIMITS_MAX_BUFFER_SIZE (Limits.cpp:65-66).
    .{
        .group = .max_buffer_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_buffer_size,
        .compat = 256 * mebibyte,
        .tiers = &.{ 256 * mebibyte, gibibyte, 2 * gibibyte, 4 * gibibyte - 4 },
    },
    // LIMITS_RESOURCE_BINDINGS (Limits.cpp:73-81).
    .{
        .group = .resource_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_dynamic_uniform_buffers_per_pipeline_layout,
        .compat = 8,
        .tiers = &.{ 8, 10, 10 },
    },
    .{
        .group = .resource_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_dynamic_storage_buffers_per_pipeline_layout,
        .compat = 4,
        .tiers = &.{ 4, 8, 8 },
    },
    .{
        .group = .resource_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_sampled_textures_per_shader_stage,
        .compat = 16,
        .tiers = &.{ 16, 16, 48 },
    },
    .{
        .group = .resource_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_samplers_per_shader_stage,
        .compat = 16,
        .tiers = &.{ 16, 16, 16 },
    },
    .{
        .group = .resource_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_storage_textures_per_shader_stage,
        .compat = 4,
        .tiers = &.{ 4, 8, 8 },
    },
    .{
        .group = .resource_bindings,
        .scope = .compat,
        .class = .maximum,
        .field = .max_storage_textures_in_fragment_stage,
        .compat = 4,
        .tiers = &.{ 4, 8, 8 },
    },
    .{
        .group = .resource_bindings,
        .scope = .compat,
        .class = .maximum,
        .field = .max_storage_textures_in_vertex_stage,
        // `Limits.cpp:80`. The plan's M8 acceptance at `docs/40-plan.md:363`
        // and the compatibility table at `docs/40-plan.md:621` cite this line
        // for `maxStorageBuffersInVertexStage`, which is `Limits.cpp:96`. The
        // value is 0 in both rows, so no assertion moves; the citation is wrong.
        .compat = 0,
        .tiers = &.{ 4, 8, 8 },
    },
    .{
        .group = .resource_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_uniform_buffers_per_shader_stage,
        .compat = 12,
        .tiers = &.{ 12, 12, 12 },
    },
    // LIMITS_STORAGE_BUFFER_BINDINGS (Limits.cpp:93-96).
    .{
        .group = .storage_buffer_bindings,
        .scope = .v1,
        .class = .maximum,
        .field = .max_storage_buffers_per_shader_stage,
        .compat = 8,
        .tiers = &.{ 8, 10, 16 },
    },
    .{
        .group = .storage_buffer_bindings,
        .scope = .compat,
        .class = .maximum,
        .field = .max_storage_buffers_in_fragment_stage,
        // `Limits.cpp:95`, the value `docs/40-plan.md:364` names.
        .compat = 4,
        .tiers = &.{ 8, 10, 16 },
    },
    .{
        .group = .storage_buffer_bindings,
        .scope = .compat,
        .class = .maximum,
        .field = .max_storage_buffers_in_vertex_stage,
        .compat = 0,
        .tiers = &.{ 8, 10, 16 },
    },
    // LIMITS_ATTACHMENTS (Limits.cpp:103-104).
    .{
        .group = .attachments,
        .scope = .v1,
        .class = .maximum,
        .field = .max_color_attachment_bytes_per_sample,
        .compat = 32,
        .tiers = &.{ 32, 64, 128 },
    },
    // LIMITS_INTER_STAGE_SHADER_VARIABLES (Limits.cpp:108-109).
    .{
        .group = .inter_stage_shader_variables,
        .scope = .v1,
        .class = .maximum,
        .field = .max_inter_stage_shader_variables,
        .compat = 15,
        .tiers = &.{ 16, 28 },
    },
    // LIMITS_TEXTURE_DIMENSIONS (Limits.cpp:115-119).
    .{
        .group = .texture_dimensions,
        .scope = .v1,
        .class = .maximum,
        .field = .max_texture_dimension_1d,
        .compat = 4096,
        .tiers = &.{ 8192, 16384 },
    },
    .{
        .group = .texture_dimensions,
        .scope = .v1,
        .class = .maximum,
        .field = .max_texture_dimension_2d,
        .compat = 4096,
        .tiers = &.{ 8192, 16384 },
    },
    .{
        .group = .texture_dimensions,
        .scope = .v1,
        .class = .maximum,
        .field = .max_texture_dimension_3d,
        .compat = 2048,
        .tiers = &.{ 2048, 2048 },
    },
    .{
        .group = .texture_dimensions,
        .scope = .v1,
        .class = .maximum,
        .field = .max_texture_array_layers,
        .compat = 256,
        .tiers = &.{ 256, 2048 },
    },
    // LIMITS_IMMEDIATE_SIZE (Limits.cpp:123-124). The tier-0 column is the
    // symbolic `kMaxImmediateDataBytes` upstream, which is 64.
    .{
        .group = .immediate_size,
        .scope = .v1,
        .class = .maximum,
        .field = .max_immediate_size,
        .compat = 64,
        .tiers = &.{64},
    },
    // LIMITS_OTHER (Limits.cpp:130-140).
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_bind_groups,
        .compat = 4,
        .tiers = &.{ 4, 4 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_bind_groups_plus_vertex_buffers,
        .compat = 24,
        .tiers = &.{ 24, 24 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_bindings_per_bind_group,
        .compat = 1000,
        .tiers = &.{ 1000, 1000 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_uniform_buffer_binding_size,
        .compat = 16384,
        .tiers = &.{ 65536, 65536 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .alignment,
        .field = .min_uniform_buffer_offset_alignment,
        .compat = 256,
        .tiers = &.{ 256, 256 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .alignment,
        .field = .min_storage_buffer_offset_alignment,
        .compat = 256,
        .tiers = &.{ 256, 256 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_vertex_buffers,
        .compat = 8,
        .tiers = &.{ 8, 8 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_vertex_attributes,
        .compat = 16,
        .tiers = &.{ 16, 30 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_vertex_buffer_array_stride,
        .compat = 2048,
        .tiers = &.{ 2048, 2048 },
    },
    .{
        .group = .other,
        .scope = .v1,
        .class = .maximum,
        .field = .max_color_attachments,
        .compat = 4,
        .tiers = &.{ 8, 8 },
    },
};

pub const row_count: usize = rows.len;

/// The groups, in `LIMITS_EACH_GROUP` order. A group that no row carried would
/// be a name a tiering walk visits and finds nothing in.
pub const groups: [group_count]Group = .{
    .workgroup_storage_size,
    .workgroup_size,
    .storage_buffer_binding_size,
    .max_buffer_size,
    .resource_bindings,
    .storage_buffer_bindings,
    .attachments,
    .inter_stage_shader_variables,
    .texture_dimensions,
    .immediate_size,
    .other,
};

/// The two limit structs this milestone fills, plus the two feature-gated
/// extension structs `CombinedLimits` carries upstream (`Limits.h:104-107`).
/// Those two need `DawnTexelCopyBufferRowAlignmentLimits` and
/// `DawnHostMappedPointerLimits`, which only `FillLimits` (`Limits.cpp:484-506`)
/// reads, so they do not land here.
///
/// `compatibility` is optional because a device that is not in compatibility
/// mode has no chained block to report, and `Device.init` refuses a null one.
pub const CombinedLimits = struct {
    v1: api.Limits,
    compatibility: ?api.CompatibilityModeLimits = null,
};

/// Whether `lhs` is the better value for a class, from the two `IsBetter`
/// specialisations of `Limits.h:53-54` and `:71-72`.
pub inline fn isBetter(class: Class, lhs: u64, rhs: u64) bool {
    return switch (class) {
        .maximum => lhs > rhs,
        .alignment => lhs < rhs,
    };
}

/// The two ways a required limit can be refused, from the two `Validate`
/// specialisations of `Limits.h:58-65` and `:76-81`.
pub const LimitCheckError = error{
    RequiredLimitIsWorseThanSupported,
    RequiredAlignmentIsNotPowerOfTwo,
};

/// Whether `required` is one a device supporting `supported` can be asked for.
///
/// `CheckLimit<C>::Validate` (`Limits.h:58`, `:76`). Upstream builds the
/// message at the call site; the two rules are separate errors here so the
/// failure names one of them.
pub fn checkLimit(class: Class, supported: u64, required: u64) LimitCheckError!void {
    if (isBetter(class, required, supported)) {
        return error.RequiredLimitIsWorseThanSupported;
    }
    if (class == .alignment and !std.math.isPowerOfTwo(required)) {
        return error.RequiredAlignmentIsNotPowerOfTwo;
    }
}

/// Whether a limit carries the "not requested" sentinel.
///
/// `IsLimitUndefined<T>` (`Limits.h:84-98`). Upstream's primary template is a
/// `static_assert` that no other width exists; the `else` branch here is that
/// assertion, so a fourth width is a compile error.
pub fn isLimitUndefined(value: anytype) bool {
    const Width = @TypeOf(value);
    if (Width == u32) return value == api.constants.LimitU32Undefined;
    if (Width == u64) return value == api.constants.LimitU64Undefined;
    @compileError("isLimitUndefined is not implemented for " ++ @typeName(Width));
}

/// The row for one field. Every `Field` member has exactly one row, and the
/// table asserts it, so this indexes rather than searches.
pub inline fn fieldOf(field: Field) Row {
    const index = @intFromEnum(field);
    std.debug.assert(index < row_count);
    return rows[index];
}

/// How many tiers one group's rows declare.
///
/// `ReduceSameValue` and `StaticAssertSame` (`Limits.cpp:172-181`) reduce a
/// group's tier counts to one value and `static_assert` the reduction. Reading
/// the first row and asserting the rest is the same claim with a name a
/// failure can quote.
pub fn groupTierCount(comptime group: Group) usize {
    inline for (rows) |row| {
        if (row.group == group) return row.tiers.len;
    }
    // Every `Group` member has a row, which the block below asserts. A member
    // that lost its rows is the only way to arrive here.
    unreachable;
}

/// The default for one field at one feature level.
///
/// The single ternary of `GetDefaultLimits` (`Limits.cpp:188`):
/// `featureLevel == Compatibility ? compat : base`. `FeatureLevel::Undefined`
/// takes the core column, which is what the C++ ternary does too; the port
/// keeps the branch and names the third member rather than hiding it behind a
/// two-arm switch.
pub fn defaultValue(field: Field, level: FeatureLevel) u64 {
    const row = fieldOf(field);
    return switch (level) {
        .compatibility => row.compat,
        .core, .undefined_ => row.tiers[0],
    };
}

/// The feature level a limit default is chosen for.
pub const FeatureLevel = api.FeatureLevel;

/// `GetDefaultLimits` (`Limits.cpp:185-191`), as a pure function.
///
/// Every field is written: the table has a row for all 36, and the loop is an
/// `inline for` over a comptime array so each `@field` names a field that
/// exists. `@intCast` narrows into the three `u64` descriptor fields from the
/// row's `u64`, and a row that outgrew a field width is a trap rather than a
/// truncation.
pub fn defaultLimits(level: FeatureLevel) CombinedLimits {
    var combined: CombinedLimits = .{ .v1 = .{}, .compatibility = .{} };
    // The initializer above fills `compatibility`, and nothing between here and
    // the write clears it, so the pointer is taken once rather than unwrapped
    // at each row.
    const compatibility = &combined.compatibility.?;
    inline for (rows) |row| {
        const value = defaultValue(row.field, level);
        switch (row.scope) {
            .v1 => @field(combined.v1, @tagName(row.field)) = @intCast(value),
            .compat => {
                @field(compatibility.*, @tagName(row.field)) = @intCast(value);
            },
        }
    }
    return combined;
}

pub const ReifyError = LimitCheckError || error{CompatibilityLimitsUnsupported};

/// Resolve every requested field. Maximum limits are upper bounds; alignment
/// limits are lower bounds. Undefined fields keep the bounded level default.
pub fn reify(offered: CombinedLimits, level: FeatureLevel, required: ?CombinedLimits) ReifyError!CombinedLimits {
    var effective = defaultLimits(level);
    if (offered.compatibility == null) effective.compatibility = null;
    inline for (rows) |row| {
        const name = @tagName(row.field);
        switch (row.scope) {
            .v1 => {
                const supported = @field(offered.v1, name);
                const baseline = @field(effective.v1, name);
                @field(effective.v1, name) = if (row.class == .maximum)
                    @min(baseline, supported)
                else
                    @max(baseline, supported);
                if (required) |request| {
                    const value = @field(request.v1, name);
                    if (!isLimitUndefined(value)) {
                        try checkLimit(row.class, supported, value);
                        @field(effective.v1, name) = value;
                    }
                }
            },
            .compat => {
                if (offered.compatibility) |supported_block| {
                    const supported = @field(supported_block, name);
                    const baseline = @field(effective.compatibility.?, name);
                    @field(effective.compatibility.?, name) = @min(baseline, supported);
                    if (required) |request| {
                        if (request.compatibility) |requested_block| {
                            const value = @field(requested_block, name);
                            if (!isLimitUndefined(value)) {
                                try checkLimit(row.class, supported, value);
                                @field(effective.compatibility.?, name) = value;
                            }
                        }
                    }
                } else if (required) |request| {
                    if (request.compatibility) |block| {
                        if (!isLimitUndefined(@field(block, name))) return error.CompatibilityLimitsUnsupported;
                    }
                }
            },
        }
    }
    return effective;
}

comptime {
    if (row_count != 36) @compileError("the limit table must carry exactly 36 rows");
    if (@typeInfo(Field).@"enum".fields.len != row_count) {
        @compileError("every Field member must have exactly one row");
    }
    if (@typeInfo(api.Limits).@"struct".fields.len != 32) {
        @compileError("api.Limits must carry exactly 32 fields");
    }
    if (@typeInfo(api.CompatibilityModeLimits).@"struct".fields.len != 4) {
        @compileError("api.CompatibilityModeLimits must carry exactly 4 fields");
    }

    // Row `i` carries `@enumFromInt(i)`. Without this, `fieldOf` would read a
    // neighbouring row and every value would be wrong by an offset no name
    // would show.
    for (rows, 0..) |row, index| {
        std.debug.assert(@intFromEnum(row.field) == index);
    }

    // The two descriptor structs and the table are the same sets of fields. A
    // descriptor field with no row would default to the undefined sentinel in
    // every report; a row with no descriptor field would not compile.
    var v1_count: usize = 0;
    var compat_count: usize = 0;
    var maximum_count: usize = 0;
    var alignment_count: usize = 0;
    for (rows) |row| {
        const name = @tagName(row.field);
        switch (row.scope) {
            .v1 => {
                v1_count += 1;
                if (!@hasField(api.Limits, name)) {
                    @compileError("a v1 row names a field api.Limits does not have: " ++ name);
                }
                if (@hasField(api.CompatibilityModeLimits, name)) {
                    @compileError("a v1 row names a compatibility field: " ++ name);
                }
            },
            .compat => {
                compat_count += 1;
                if (!@hasField(api.CompatibilityModeLimits, name)) {
                    @compileError("a compat row names a field the chain does not have: " ++ name);
                }
                if (@hasField(api.Limits, name)) {
                    @compileError("a compat row names a v1 field: " ++ name);
                }
            },
        }
        switch (row.class) {
            .maximum => maximum_count += 1,
            .alignment => alignment_count += 1,
        }
    }
    if (v1_count != 32) @compileError("the table must carry 32 v1 rows");
    if (compat_count != 4) @compileError("the table must carry 4 compat rows");
    if (maximum_count != 34) @compileError("the table must carry 34 maximum rows");
    if (alignment_count != 2) @compileError("the table must carry 2 alignment rows");

    for (std.meta.fields(api.Limits)) |field| {
        if (!@hasField(Field, field.name)) {
            @compileError("api.Limits has a field the table does not: " ++ field.name);
        }
    }
    for (std.meta.fields(api.CompatibilityModeLimits)) |field| {
        if (!@hasField(Field, field.name)) {
            @compileError("the compat chain has a field the table does not: " ++ field.name);
        }
    }

    // The two walks that read every row are one call each, and the first of
    // them is one pass rather than one pass per group. Comptime has a single
    // branch counter for the whole evaluation, not one per block, so eleven
    // passes over the table cost the table eleven times over and leave the
    // last claim below outside the compiler's budget of 1000
    // (`@setEvalBranchQuota`). Two passes fit, and a claim kept in the
    // compiler is one a test cannot be skipped out of.
    checkGroupTierCounts();
    checkTierColumns();
}

/// Every group declares the same tier count across its rows, and every group
/// in `LIMITS_EACH_GROUP` order has at least one row.
///
/// **Why one pass and not one per group.** `groupTierCount` is the reader this
/// claim would otherwise call eleven times, and each call is a walk down the
/// table. The tally below answers the same two questions — what tier count
/// the group's first row declared, and whether the group has a row at all —
/// from one visit per row, and `groupTierCount` stays the reader a caller
/// outside this file uses.
fn checkGroupTierCounts() void {
    var carried = [_]bool{false} ** group_count;
    var tier_counts = [_]usize{0} ** group_count;
    for (rows) |row| {
        const ordinal = @intFromEnum(row.group);
        if (carried[ordinal]) {
            std.debug.assert(row.tiers.len == tier_counts[ordinal]);
        } else {
            carried[ordinal] = true;
            tier_counts[ordinal] = row.tiers.len;
        }
    }
    for (groups) |group| {
        const ordinal = @intFromEnum(group);
        std.debug.assert(carried[ordinal]);
        std.debug.assert(tier_counts[ordinal] > 0);
    }
}

/// The compat column is never better than tier 0, and the tiers never get worse
/// as the tier index rises.
///
/// Both comparisons go through `isBetter`, whose direction is the row's own
/// class (`Limits.h:53-54` for an alignment, `:71-72` for a maximum), so the
/// compat claim inverts for an alignment row and does not for a maximum one.
/// Both alignment rows are 256 in every column, so the claim holds in both
/// directions and the direction the row carries is the direction checked.
///
/// Upstream asserts the reduction exists, not the ordering (`ReduceSameValue`
/// and `StaticAssertSame`, `Limits.cpp:172-181`); the ordering is what makes a
/// tier walk terminate on the first column that is not better.
fn checkTierColumns() void {
    for (rows) |row| {
        std.debug.assert(!isBetter(row.class, row.compat, row.tiers[0]));
        for (row.tiers, 1..) |tier, index| {
            std.debug.assert(!isBetter(row.class, row.tiers[index - 1], tier));
        }
    }
}

test "the compat column is never better than tier zero" {
    for (rows) |row| {
        switch (row.class) {
            .maximum => try std.testing.expect(row.compat <= row.tiers[0]),
            .alignment => try std.testing.expect(row.compat >= row.tiers[0]),
        }
    }
}

test "a field's row is the row at its own ordinal" {
    for (rows) |row| {
        try std.testing.expectEqual(row.field, fieldOf(row.field).field);
        try std.testing.expectEqual(row.compat, fieldOf(row.field).compat);
    }
}

test "the core and compatibility defaults differ on eleven rows" {
    var differing: usize = 0;
    // Why eleven and not six. A count that reads only the compat-scope rows
    // and the `other` rows that differ finds six: the storage-texture and
    // storage-buffer in-stage rows, `max_inter_stage_shader_variables`,
    // `max_uniform_buffer_binding_size` and `max_color_attachments`. The five
    // it misses are the three workgroup-size rows and the 1D and 2D texture
    // dimensions, whose compat column is half of tier 0 (`Limits.cpp:51-53`,
    // `:116-117`).
    for (rows) |row| {
        const core = defaultValue(row.field, .core);
        const compatibility = defaultValue(row.field, .compatibility);
        if (core != compatibility) differing += 1;
    }
    try std.testing.expectEqual(@as(usize, 11), differing);
}

test "the four compatibility rows carry zero or four where M8 reads them" {
    // `defaultLimits` initializes the block and every compat row writes into
    // it, so the combined set it returns cannot carry a null block.
    const vertex_buffers = defaultLimits(.compatibility).compatibility orelse
        unreachable;
    try std.testing.expectEqual(
        @as(u32, 0),
        vertex_buffers.max_storage_buffers_in_vertex_stage,
    );
    try std.testing.expectEqual(
        @as(u32, 4),
        vertex_buffers.max_storage_buffers_in_fragment_stage,
    );
    const core = defaultLimits(.core).compatibility orelse unreachable;
    try std.testing.expectEqual(@as(u32, 8), core.max_storage_buffers_in_vertex_stage);
    try std.testing.expectEqual(@as(u32, 8), core.max_storage_buffers_in_fragment_stage);
}

test "a required alignment must be a power of two" {
    try checkLimit(.alignment, 256, 512);
    // `checkLimit` takes (supported, required) and tests `isBetter(required,
    // supported)` FIRST (`Limits.h:59` before `:62`), so a required value that
    // is worse than supported is refused before the power-of-two rule can see
    // it. 300 is not a power of two and is not better than 256, so it reaches
    // the second rule; a value that IS worse is refused by the first.
    try std.testing.expectError(
        error.RequiredAlignmentIsNotPowerOfTwo,
        checkLimit(.alignment, 256, 300),
    );
    // 300 is worse than 256 and not a power of two, so the first rule wins.
    try std.testing.expectError(
        error.RequiredLimitIsWorseThanSupported,
        checkLimit(.maximum, 256, 300),
    );
    try std.testing.expectError(
        error.RequiredLimitIsWorseThanSupported,
        checkLimit(.maximum, 128, 256),
    );
}
