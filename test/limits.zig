//! The M7 shard for the limit table: 36 rows, and a compat column that is
//! never the better answer.
//!
//! `docs/40-plan.md` §M7 "The five claims the census tests read" fixes the
//! two claims this file makes: `row_count == 36`, and for every `.maximum`
//! row `compat <= tiers[0]`.
//!
//! **Why the comparison reads the row's own class.** `CheckLimit<C>::IsBetter`
//! is `lhs < rhs` for `Alignment` (`Limits.h:53-54`) and `lhs > rhs` for
//! `Maximum` (`:71-72`). One bare `compat <= tiers[0]` over all 36 rows would
//! pass the two alignment rows by accident and would test nothing about them,
//! so the direction is read from the row rather than assumed.
//!
//! **Why the eleven-row census spells the names.** "Eleven rows are strictly
//! below tier 0 in compatibility mode" is a count; the names are the contract.
//! A twelfth row, or an eleventh renamed, has to change this file, which is the
//! point of a census.
//!
//! Reification regressions cover physical bounds, explicit requests, undefined
//! sentinels, optional compatibility metadata, and deterministic refusal.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const limits = dusk.engine.limits;

test "the limits table carries exactly 36 rows" {
    try std.testing.expectEqual(@as(usize, 36), limits.row_count);
    try std.testing.expectEqual(@as(usize, 36), limits.rows.len);
    try std.testing.expectEqual(
        @as(usize, 36),
        @typeInfo(limits.Field).@"enum".fields.len,
    );

    // Row `i` carries `@enumFromInt(i)`, which is what makes `fieldOf` an index
    // and not a search. A row written out of order would make every value wrong
    // by an offset no name shows, so the ordinal is asserted here.
    for (limits.rows, 0..) |row, index| {
        try std.testing.expectEqual(@as(usize, index), @as(usize, @intFromEnum(row.field)));
    }
}

test "no compat value beats the tier-0 value it defaults to" {
    var maximum_rows: usize = 0;
    var alignment_rows: usize = 0;

    for (limits.rows) |row| {
        switch (row.class) {
            .maximum => {
                maximum_rows += 1;
                try std.testing.expect(row.compat <= row.tiers[0]);
            },
            .alignment => {
                alignment_rows += 1;
                try std.testing.expect(row.compat >= row.tiers[0]);
            },
        }
        // The same claim through the class rule the module exports, so the two
        // spellings of "better" cannot drift apart.
        try std.testing.expect(!limits.isBetter(row.class, row.compat, row.tiers[0]));
    }

    try std.testing.expectEqual(@as(usize, 34), maximum_rows);
    try std.testing.expectEqual(@as(usize, 2), alignment_rows);
}

/// One row compatibility mode is strictly below core mode on. The values are
/// the two columns of the same `X(...)` line upstream, so a table that moved
/// one without the other fails both halves.
///
/// **Why eleven and not six.** A reader who counts only the compat-scope rows
/// and the `other` group finds six. The five such a count misses are the three
/// workgroup-size rows and the two 1D and 2D dimensions, whose compat column is
/// half of tier 0 (`Limits.cpp:51-53`, `:116-117`).
const BelowTierZero = struct {
    field: limits.Field,
    compat: u64,
    tier0: u64,
};

const below_tier_zero = [_]BelowTierZero{
    // `Limits.cpp:51`, `maxComputeInvocationsPerWorkgroup`.
    .{ .field = .max_compute_invocations_per_workgroup, .compat = 128, .tier0 = 256 },
    // `Limits.cpp:52`, `maxComputeWorkgroupSizeX`.
    .{ .field = .max_compute_workgroup_size_x, .compat = 128, .tier0 = 256 },
    // `Limits.cpp:53`, `maxComputeWorkgroupSizeY`.
    .{ .field = .max_compute_workgroup_size_y, .compat = 128, .tier0 = 256 },
    // `Limits.cpp:80`, `maxStorageTexturesInVertexStage`.
    .{ .field = .max_storage_textures_in_vertex_stage, .compat = 0, .tier0 = 4 },
    // `Limits.cpp:95`, `maxStorageBuffersInFragmentStage`.
    .{ .field = .max_storage_buffers_in_fragment_stage, .compat = 4, .tier0 = 8 },
    // `Limits.cpp:96`, `maxStorageBuffersInVertexStage`.
    .{ .field = .max_storage_buffers_in_vertex_stage, .compat = 0, .tier0 = 8 },
    // `Limits.cpp:109`, `maxInterStageShaderVariables`.
    .{ .field = .max_inter_stage_shader_variables, .compat = 15, .tier0 = 16 },
    // `Limits.cpp:116`, `maxTextureDimension1D`.
    .{ .field = .max_texture_dimension_1d, .compat = 4096, .tier0 = 8192 },
    // `Limits.cpp:117`, `maxTextureDimension2D`.
    .{ .field = .max_texture_dimension_2d, .compat = 4096, .tier0 = 8192 },
    // `Limits.cpp:134`, `maxUniformBufferBindingSize`.
    .{ .field = .max_uniform_buffer_binding_size, .compat = 16384, .tier0 = 65536 },
    // `Limits.cpp:140`, `maxColorAttachments`.
    .{ .field = .max_color_attachments, .compat = 4, .tier0 = 8 },
};

test "compatibility mode is strictly below core mode on exactly eleven rows" {
    var strict_rows: usize = 0;
    for (limits.rows) |row| {
        if (row.class == .maximum and row.compat < row.tiers[0]) strict_rows += 1;
    }
    try std.testing.expectEqual(below_tier_zero.len, strict_rows);
    try std.testing.expectEqual(@as(usize, 11), below_tier_zero.len);

    for (below_tier_zero) |expected| {
        const row = limits.fieldOf(expected.field);
        try std.testing.expectEqual(expected.compat, row.compat);
        try std.testing.expectEqual(expected.tier0, row.tiers[0]);
    }
}

test "the eleven groups each carry rows of one tier count" {
    try std.testing.expectEqual(@as(usize, 11), limits.group_count);
    try std.testing.expectEqual(limits.group_count, limits.groups.len);

    // `ReduceSameValue` and `StaticAssertSame` (`Limits.cpp:172-181`) reduce a
    // group's tier counts to one value and `static_assert` the reduction. A
    // group a tiering walk visits with no row, or with two shapes, is the same
    // defect from two sides, so both are checked against the same number.
    inline for (limits.groups) |group| {
        const expected = comptime limits.groupTierCount(group);
        try std.testing.expect(expected > 0);
        for (limits.rows) |row| {
            if (row.group != group) continue;
            try std.testing.expectEqual(expected, row.tiers.len);
        }
    }
}

test "every field's reported default is its own row's two columns" {
    // §3 makes an `inline for` over every enumerable domain the strongest
    // coverage substitute Zig has, and `Field` is one of them. Zig 0.16 takes
    // no enum type as a `for` operand, so the domain is named instead:
    // `std.enums.values` hands over all 36 members in declaration order, which
    // is the set the bare type used to give. `defaultValue` reaches its row
    // through the same `fieldOf` this test reads, so the comparison fails on
    // a column chosen wrong or a row read wrong, and it does so for all 36
    // fields rather than for one.
    inline for (std.enums.values(limits.Field)) |field| {
        const row = limits.fieldOf(field);
        try std.testing.expectEqual(row.tiers[0], limits.defaultValue(field, .core));
        try std.testing.expectEqual(row.compat, limits.defaultValue(field, .compatibility));
    }
}

test "the table fills every field the two descriptors declare" {
    try std.testing.expectEqual(
        @as(usize, 32),
        @typeInfo(api.Limits).@"struct".fields.len,
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        @typeInfo(api.CompatibilityModeLimits).@"struct".fields.len,
    );

    // A descriptor field with no row keeps the "not requested" sentinel in every
    // report, which is a limit no device can be asked about and one no
    // `checkLimit` call can explain.
    const defaults = limits.defaultLimits(.core);
    inline for (std.meta.fields(api.Limits)) |field| {
        try std.testing.expect(!limits.isLimitUndefined(@field(defaults.v1, field.name)));
    }
    // `defaultLimits` fills the compat block on its first statement
    // (`src/engine/limits.zig:558`) and no row clears it, so a null chain here
    // is a table defect rather than a condition to tolerate; it is named
    // instead of being unwrapped.
    const default_chain = defaults.compatibility orelse
        return error.CompatibilityChainMissing;
    inline for (std.meta.fields(api.CompatibilityModeLimits)) |field| {
        try std.testing.expect(!limits.isLimitUndefined(@field(default_chain, field.name)));
    }
}

test "a core device reads the tier-0 column and a compat device the compat column" {
    const core = limits.defaultLimits(.core);
    const compatibility = limits.defaultLimits(.compatibility);
    // Same claim as the block above, read through the chain rather than
    // through the table: the two rows this test asserts differ in every digit,
    // and a projection that wrote the wrong column fails here.
    const core_chain = core.compatibility orelse
        return error.CompatibilityChainMissing;
    const compat_chain = compatibility.compatibility orelse
        return error.CompatibilityChainMissing;

    // The one row whose two columns differ in every digit, which is what makes
    // it the row a reader checks first.
    try std.testing.expectEqual(@as(u32, 8192), core.v1.max_texture_dimension_1d);
    try std.testing.expectEqual(@as(u32, 4096), compatibility.v1.max_texture_dimension_1d);

    // The four compat-scope rows, read back through the chained struct rather
    // than through the table, so a projection that wrote the wrong column
    // fails here and not only inside `limits.zig`.
    try std.testing.expectEqual(@as(u32, 0), compat_chain.max_storage_buffers_in_vertex_stage);
    try std.testing.expectEqual(@as(u32, 4), compat_chain.max_storage_buffers_in_fragment_stage);
    try std.testing.expectEqual(@as(u32, 0), compat_chain.max_storage_textures_in_vertex_stage);
    try std.testing.expectEqual(@as(u32, 4), compat_chain.max_storage_textures_in_fragment_stage);

    // Core takes the tier column for all four. `EnforceLimitSpecInvariants`
    // (`Limits.cpp:426-459`) then overwrites the two per-stage buffer rows
    // against a device's reported value, which is M8's; the table only selects
    // the column, and 8 is what tier 0 says for both rows.
    try std.testing.expectEqual(@as(u32, 8), core_chain.max_storage_buffers_in_vertex_stage);
    try std.testing.expectEqual(@as(u32, 8), core_chain.max_storage_buffers_in_fragment_stage);
    try std.testing.expectEqual(@as(u32, 4), core_chain.max_storage_textures_in_vertex_stage);
    try std.testing.expectEqual(@as(u32, 4), core_chain.max_storage_textures_in_fragment_stage);
}

test "an undefined feature level takes the core column" {
    // The ternary at `Limits.cpp:188` reads `level == Compatibility ? compat :
    // base`, so an undefined level takes `base` rather than trapping. The port
    // names the third member instead of hiding it behind a two-arm switch, and
    // this is the assertion that the third member really is the core column.
    const undefined_level = limits.defaultLimits(.undefined_);
    const core = limits.defaultLimits(.core);
    try std.testing.expectEqualDeep(core.v1, undefined_level.v1);
    // Same claim for the compat block: both chains come from the same
    // initializer, so a null one is a table defect and is named, not unwrapped.
    const core_chain = core.compatibility orelse
        return error.CompatibilityChainMissing;
    const undefined_chain = undefined_level.compatibility orelse
        return error.CompatibilityChainMissing;
    try std.testing.expectEqualDeep(core_chain, undefined_chain);
}

test "a required limit the device cannot beat is refused" {
    // `CheckLimit<C>::Validate` (`Limits.h:58`, `:76`) is the rule a
    // required-limits descriptor is refused by, and `checkLimit` is its port
    // name. It is the other half of the compat claim: a compat column that is
    // worse than tier 0 is only a useful table because asking for the tier-0
    // value in compat mode is refused.
    try std.testing.expectError(
        error.RequiredLimitIsWorseThanSupported,
        limits.checkLimit(.maximum, 128, 256),
    );
    try limits.checkLimit(.maximum, 256, 128);
    try limits.checkLimit(.alignment, 256, 256);
    // `Alignment::Validate` checks the two rules in that order
    // (`Limits.h:59`, `:62`): a required alignment lower than the supported one
    // is refused first, so 100 against 256 never reaches the power-of-two rule.
    // 300 clears the first rule and fails the second, which is the only way to
    // name `RequiredAlignmentIsNotPowerOfTwo`.
    try std.testing.expectError(
        error.RequiredAlignmentIsNotPowerOfTwo,
        limits.checkLimit(.alignment, 256, 300),
    );
    // The first rule on its own, on the class whose `IsBetter` is `lhs < rhs`
    // (`Limits.h:53-54`), where a lower required alignment is the better one.
    try std.testing.expectError(
        error.RequiredLimitIsWorseThanSupported,
        limits.checkLimit(.alignment, 256, 100),
    );
}

test "required limits are reified with maximum and alignment directions" {
    var offered = limits.defaultLimits(.core);
    offered.v1.max_compute_invocations_per_workgroup = 1024;
    offered.v1.min_uniform_buffer_offset_alignment = 64;
    const required: limits.CombinedLimits = .{ .v1 = .{
        .max_compute_invocations_per_workgroup = 512,
        .min_uniform_buffer_offset_alignment = 128,
    } };
    const effective = try limits.reify(offered, .core, required);
    try std.testing.expectEqual(@as(u32, 512), effective.v1.max_compute_invocations_per_workgroup);
    try std.testing.expectEqual(@as(u32, 128), effective.v1.min_uniform_buffer_offset_alignment);
    try std.testing.expectEqual(offered.compatibility, effective.compatibility);
}

test "undefined requests retain physically bounded defaults" {
    var offered = limits.defaultLimits(.core);
    offered.v1.max_compute_workgroup_size_x = 64;
    offered.v1.min_storage_buffer_offset_alignment = 512;
    offered.compatibility = null;
    const effective = try limits.reify(offered, .core, .{ .v1 = .{} });
    try std.testing.expectEqual(@as(u32, 64), effective.v1.max_compute_workgroup_size_x);
    try std.testing.expectEqual(@as(u32, 512), effective.v1.min_storage_buffer_offset_alignment);
    try std.testing.expectEqual(@as(?api.CompatibilityModeLimits, null), effective.compatibility);
}

test "required limits refuse unsupported directions and invalid alignment deterministically" {
    const offered = limits.defaultLimits(.core);
    try std.testing.expectError(error.RequiredLimitIsWorseThanSupported, limits.reify(offered, .core, .{
        .v1 = .{ .max_compute_invocations_per_workgroup = 257 },
    }));
    try std.testing.expectError(error.RequiredLimitIsWorseThanSupported, limits.reify(offered, .core, .{
        .v1 = .{ .min_uniform_buffer_offset_alignment = 128 },
    }));
    try std.testing.expectError(error.RequiredAlignmentIsNotPowerOfTwo, limits.reify(offered, .core, .{
        .v1 = .{ .min_uniform_buffer_offset_alignment = 300 },
    }));
    var no_compatibility = offered;
    no_compatibility.compatibility = null;
    try std.testing.expectError(error.CompatibilityLimitsUnsupported, limits.reify(no_compatibility, .core, .{
        .v1 = .{},
        .compatibility = .{ .max_storage_buffers_in_vertex_stage = 1 },
    }));
}

test "every accepted required field survives device limit reification" {
    inline for (limits.rows) |row| {
        const name = @tagName(row.field);
        var offered = limits.defaultLimits(.core);
        var required: limits.CombinedLimits = .{ .v1 = .{}, .compatibility = .{} };
        const value = limits.defaultValue(row.field, .core) + 1;
        switch (row.scope) {
            .v1 => {
                const requested = if (row.class == .alignment) 512 else value;
                @field(offered.v1, name) = @intCast(if (row.class == .alignment) 256 else value + 1);
                @field(required.v1, name) = @intCast(requested);
                const effective = try limits.reify(offered, .core, required);
                try std.testing.expectEqual(@field(required.v1, name), @field(effective.v1, name));
            },
            .compat => {
                @field(offered.compatibility.?, name) = @intCast(value + 1);
                @field(required.compatibility.?, name) = @intCast(value);
                const effective = try limits.reify(offered, .core, required);
                try std.testing.expectEqual(
                    @field(required.compatibility.?, name),
                    @field(effective.compatibility.?, name),
                );
            },
        }
    }
}

// Explicit queried records keep these tests independent of the WebGPU defaults.
fn queriedNativeCaps() dusk.engine.vulkan_device.PhysicalDevice {
    var device: dusk.engine.vulkan_device.PhysicalDevice = .{
        .handle = null,
        .properties = std.mem.zeroes(@FieldType(dusk.engine.vulkan_device.PhysicalDevice, "properties")),
        .features = std.mem.zeroes(@FieldType(dusk.engine.vulkan_device.PhysicalDevice, "features")),
        .memory_properties = std.mem.zeroes(@FieldType(dusk.engine.vulkan_device.PhysicalDevice, "memory_properties")),
        .max_buffer_size = 1024 * 1024 * 1024,
        .queue_families = &.{},
        .max_per_set_descriptors = 4096,
    };
    device.features.robustBufferAccess = 1;
    device.features.imageCubeArray = 1;
    device.features.independentBlend = 1;
    device.features.depthBiasClamp = 1;
    device.features.fullDrawIndexUint32 = 1;
    device.features.fragmentStoresAndAtomics = 1;
    device.features.vertexPipelineStoresAndAtomics = 1;
    device.features.sampleRateShading = 1;
    device.features.shaderUniformBufferArrayDynamicIndexing = 1;
    device.features.shaderStorageBufferArrayDynamicIndexing = 1;
    device.features.shaderSampledImageArrayDynamicIndexing = 1;
    device.features.shaderStorageImageArrayDynamicIndexing = 1;
    device.features.textureCompressionBC = 1;
    const queried = &device.properties.limits;
    queried.maxComputeSharedMemorySize = 32768;
    queried.maxComputeWorkGroupInvocations = 1024;
    queried.maxComputeWorkGroupSize = .{ 1024, 1024, 64 };
    queried.maxComputeWorkGroupCount = .{ 65535, 65535, 65535 };
    queried.maxStorageBufferRange = 256 * 1024 * 1024;
    queried.maxUniformBufferRange = 65536;
    queried.maxDescriptorSetUniformBuffersDynamic = 16;
    queried.maxDescriptorSetStorageBuffersDynamic = 8;
    queried.maxPerStageDescriptorSampledImages = 64;
    queried.maxPerStageDescriptorSamplers = 64;
    queried.maxPerStageDescriptorUniformBuffers = 64;
    queried.maxPerStageDescriptorStorageBuffers = 64;
    queried.maxPerStageDescriptorStorageImages = 64;
    queried.maxDescriptorSetSampledImages = 192;
    queried.maxDescriptorSetSamplers = 192;
    queried.maxDescriptorSetUniformBuffers = 192;
    queried.maxDescriptorSetStorageBuffers = 192;
    queried.maxDescriptorSetStorageImages = 192;
    queried.maxPerStageResources = 1024;
    queried.maxFragmentCombinedOutputResources = 1024;
    queried.maxColorAttachments = 8;
    queried.maxFragmentOutputAttachments = 8;
    queried.maxVertexOutputComponents = 128;
    queried.maxFragmentInputComponents = 128;
    queried.maxImageDimension1D = 16384;
    queried.maxImageDimension2D = 16384;
    queried.maxImageDimension3D = 4096;
    queried.maxImageArrayLayers = 2048;
    queried.maxFramebufferWidth = 16384;
    queried.maxFramebufferHeight = 16384;
    queried.maxPushConstantsSize = 512;
    queried.maxBoundDescriptorSets = 8;
    queried.minUniformBufferOffsetAlignment = 64;
    queried.minStorageBufferOffsetAlignment = 64;
    queried.maxVertexInputBindings = 32;
    queried.maxVertexInputAttributes = 32;
    queried.maxVertexInputBindingStride = 4096;
    return device;
}

test "native offered frontend capacities bound accepted explicit requests" {
    var device = queriedNativeCaps();
    const capacities = dusk.engine.native_capabilities;
    const offered = capacities.offeredLimits(&device);
    try std.testing.expectEqual(@as(u32, 4), offered.v1.max_bind_groups);
    try std.testing.expectEqual(@as(u32, 256), offered.v1.max_immediate_size);
    try std.testing.expectEqual(@as(u32, 1000), offered.v1.max_bindings_per_bind_group);
    try std.testing.expectEqual(@as(u32, 36), offered.v1.max_bind_groups_plus_vertex_buffers);
    const effective = try limits.reify(offered, .core, .{ .v1 = .{
        .max_bind_groups = 4,
        .max_immediate_size = 256,
        .max_bindings_per_bind_group = 1000,
    } });
    try std.testing.expectEqual(@as(u32, 4), effective.v1.max_bind_groups);
    try std.testing.expectEqual(@as(u32, 256), effective.v1.max_immediate_size);
    try std.testing.expectEqual(@as(u32, 1000), effective.v1.max_bindings_per_bind_group);
    inline for (.{
        .{ "max_bind_groups", 5 },
        .{ "max_immediate_size", 257 },
        .{ "max_bindings_per_bind_group", 1001 },
    }) |request| {
        var required: limits.CombinedLimits = .{ .v1 = .{} };
        @field(required.v1, request[0]) = request[1];
        try std.testing.expectError(
            error.RequiredLimitIsWorseThanSupported,
            limits.reify(offered, .core, required),
        );
    }
    device.properties.limits.maxBoundDescriptorSets = 3;
    device.properties.limits.maxPushConstantsSize = 128;
    device.max_per_set_descriptors = 999;
    const smaller = capacities.offeredLimits(&device);
    try std.testing.expectEqual(@as(u32, 3), smaller.v1.max_bind_groups);
    try std.testing.expectEqual(@as(u32, 128), smaller.v1.max_immediate_size);
    try std.testing.expectEqual(@as(u32, 999), smaller.v1.max_bindings_per_bind_group);
    try std.testing.expectEqual(@as(u32, 35), smaller.v1.max_bind_groups_plus_vertex_buffers);
}

test "native per-stage descriptor offers fit three independent visibility budgets" {
    inline for (.{
        .{
            "max_sampled_textures_per_shader_stage",
            "maxDescriptorSetSampledImages",
            "maxPerStageDescriptorSampledImages",
        },
        .{ "max_samplers_per_shader_stage", "maxDescriptorSetSamplers", "maxPerStageDescriptorSamplers" },
        .{
            "max_uniform_buffers_per_shader_stage",
            "maxDescriptorSetUniformBuffers",
            "maxPerStageDescriptorUniformBuffers",
        },
        .{
            "max_storage_buffers_per_shader_stage",
            "maxDescriptorSetStorageBuffers",
            "maxPerStageDescriptorStorageBuffers",
        },
        .{
            "max_storage_textures_per_shader_stage",
            "maxDescriptorSetStorageImages",
            "maxPerStageDescriptorStorageImages",
        },
    }) |category| {
        var device = queriedNativeCaps();
        @field(device.properties.limits, category[1]) = 98;
        const offered = dusk.engine.native_capabilities.offeredLimits(&device);
        const count = @field(offered.v1, category[0]);
        try std.testing.expectEqual(@as(u32, 32), count);
        // Vertex, fragment, and compute can each expose distinct bindings.
        try std.testing.expect(count * 3 <= @field(device.properties.limits, category[1]));
        var required: limits.CombinedLimits = .{ .v1 = .{} };
        @field(required.v1, category[0]) = count;
        const effective = try limits.reify(offered, .core, required);
        try std.testing.expectEqual(count, @field(effective.v1, category[0]));
        @field(required.v1, category[0]) = count + 1;
        try std.testing.expectError(
            error.RequiredLimitIsWorseThanSupported,
            limits.reify(offered, .core, required),
        );
        @field(device.properties.limits, category[2]) = 17;
        const stage_limited = dusk.engine.native_capabilities.offeredLimits(&device);
        try std.testing.expectEqual(@as(u32, 17), @field(stage_limited.v1, category[0]));
        @field(device.properties.limits, category[1]) = 2;
        const exhausted = dusk.engine.native_capabilities.offeredLimits(&device);
        try std.testing.expectEqual(@as(u32, 0), @field(exhausted.v1, category[0]));
    }
}

test "native combined stage budget reserves fragment color attachments" {
    var device = queriedNativeCaps();
    const queried = &device.properties.limits;
    queried.maxPerStageResources = 49;
    const offered = dusk.engine.native_capabilities.offeredLimits(&device);
    const resources = offered.v1.max_sampled_textures_per_shader_stage +
        offered.v1.max_uniform_buffers_per_shader_stage +
        offered.v1.max_storage_buffers_per_shader_stage +
        offered.v1.max_storage_textures_per_shader_stage;
    try std.testing.expect(resources + offered.v1.max_color_attachments <= 49);
    try std.testing.expectEqual(@as(u32, 16), offered.v1.max_sampled_textures_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 12), offered.v1.max_uniform_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 8), offered.v1.max_storage_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 4), offered.v1.max_storage_textures_per_shader_stage);
    // Standalone samplers do not count toward maxPerStageResources.
    try std.testing.expectEqual(@as(u32, 64), offered.v1.max_samplers_per_shader_stage);
    try std.testing.expectEqual(
        offered.v1.max_storage_buffers_per_shader_stage,
        offered.compatibility.?.max_storage_buffers_in_vertex_stage,
    );
    try std.testing.expectEqual(
        offered.v1.max_storage_textures_per_shader_stage,
        offered.compatibility.?.max_storage_textures_in_fragment_stage,
    );
    queried.maxPerStageResources = 48;
    var mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(mapped.feature_levels.core);
    try std.testing.expect(mapped.feature_levels.compatibility);
    queried.maxPerStageResources = 47;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expectEqual(@as(u32, 15), mapped.limits.v1.max_sampled_textures_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 11), mapped.limits.v1.max_uniform_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 7), mapped.limits.v1.max_storage_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 3), mapped.limits.v1.max_storage_textures_per_shader_stage);
    try std.testing.expect(!mapped.feature_levels.core);
    try std.testing.expect(!mapped.feature_levels.compatibility);
    queried.maxPerStageResources = 8;
    const exhausted = dusk.engine.native_capabilities.offeredLimits(&device);
    try std.testing.expectEqual(@as(u32, 0), exhausted.v1.max_sampled_textures_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 0), exhausted.v1.max_uniform_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 0), exhausted.v1.max_storage_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 0), exhausted.v1.max_storage_textures_per_shader_stage);
}

test "native core feature level requires queried cube arrays and robustness" {
    var device = queriedNativeCaps();
    var mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(mapped.feature_levels.core);
    try std.testing.expect(mapped.feature_levels.compatibility);
    try std.testing.expect(mapped.supported_features.isEnabled(.core_features_and_limits));
    device.features.imageCubeArray = 0;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(!mapped.feature_levels.core);
    try std.testing.expect(mapped.feature_levels.compatibility);
    try std.testing.expect(!mapped.supported_features.isEnabled(.core_features_and_limits));
    device.features.imageCubeArray = 1;
    device.features.robustBufferAccess = 0;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(!mapped.feature_levels.core);
    try std.testing.expect(!mapped.feature_levels.compatibility);
    device.features.robustBufferAccess = 1;
    device.properties.limits.maxDescriptorSetSampledImages = 47;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(!mapped.feature_levels.core);
    try std.testing.expect(!mapped.feature_levels.compatibility);
}

test "native combined descriptor arithmetic handles queried u32 maxima" {
    var device = queriedNativeCaps();
    const queried = &device.properties.limits;
    queried.maxPerStageDescriptorSampledImages = std.math.maxInt(u32);
    queried.maxPerStageDescriptorUniformBuffers = std.math.maxInt(u32);
    queried.maxPerStageDescriptorStorageBuffers = std.math.maxInt(u32);
    queried.maxPerStageDescriptorStorageImages = std.math.maxInt(u32);
    queried.maxDescriptorSetSampledImages = std.math.maxInt(u32);
    queried.maxDescriptorSetUniformBuffers = std.math.maxInt(u32);
    queried.maxDescriptorSetStorageBuffers = std.math.maxInt(u32);
    queried.maxDescriptorSetStorageImages = std.math.maxInt(u32);
    queried.maxPerStageResources = std.math.maxInt(u32);
    const offered = dusk.engine.native_capabilities.offeredLimits(&device);
    const count = @as(u64, offered.v1.max_sampled_textures_per_shader_stage) +
        offered.v1.max_uniform_buffers_per_shader_stage +
        offered.v1.max_storage_buffers_per_shader_stage +
        offered.v1.max_storage_textures_per_shader_stage +
        offered.v1.max_color_attachments;
    try std.testing.expect(count <= std.math.maxInt(u32));
    inline for (.{
        "max_sampled_textures_per_shader_stage",
        "max_uniform_buffers_per_shader_stage",
        "max_storage_buffers_per_shader_stage",
        "max_storage_textures_per_shader_stage",
    }) |field| {
        try std.testing.expect(@as(u64, @field(offered.v1, field)) * 3 <= std.math.maxInt(u32));
    }
}

test "native fragment storage offers reserve the combined color output budget" {
    var device = queriedNativeCaps();
    device.properties.limits.maxFragmentCombinedOutputResources = 20;
    var mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expectEqual(@as(u32, 8), mapped.limits.v1.max_storage_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 4), mapped.limits.v1.max_storage_textures_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 8), mapped.limits.v1.max_color_attachments);
    try std.testing.expect(mapped.feature_levels.core);
    device.properties.limits.maxFragmentCombinedOutputResources = 19;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expectEqual(@as(u32, 7), mapped.limits.v1.max_storage_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 3), mapped.limits.v1.max_storage_textures_per_shader_stage);
    try std.testing.expect(!mapped.feature_levels.core);
    try std.testing.expect(!mapped.feature_levels.compatibility);
    device.properties.limits.maxFragmentCombinedOutputResources = 7;
    const exhausted = dusk.engine.native_capabilities.offeredLimits(&device);
    try std.testing.expectEqual(@as(u32, 0), exhausted.v1.max_storage_buffers_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 0), exhausted.v1.max_storage_textures_per_shader_stage);
    try std.testing.expectEqual(@as(u32, 7), exhausted.v1.max_color_attachments);
}

test "native core admission refuses each missing required hardware feature" {
    inline for (.{
        "robustBufferAccess",
        "imageCubeArray",
        "independentBlend",
        "depthBiasClamp",
        "fullDrawIndexUint32",
        "sampleRateShading",
        "fragmentStoresAndAtomics",
        "vertexPipelineStoresAndAtomics",
        "shaderUniformBufferArrayDynamicIndexing",
        "shaderStorageBufferArrayDynamicIndexing",
        "shaderSampledImageArrayDynamicIndexing",
        "shaderStorageImageArrayDynamicIndexing",
    }) |field| {
        var device = queriedNativeCaps();
        var mapped = dusk.engine.native_capabilities.fromNative(&device);
        try std.testing.expect(mapped.feature_levels.core);
        try std.testing.expect(mapped.supported_features.isEnabled(.core_features_and_limits));
        @field(device.features, field) = 0;
        mapped = dusk.engine.native_capabilities.fromNative(&device);
        try std.testing.expect(!mapped.feature_levels.core);
        try std.testing.expect(!mapped.supported_features.isEnabled(.core_features_and_limits));
        @field(device.features, field) = 1;
        mapped = dusk.engine.native_capabilities.fromNative(&device);
        try std.testing.expect(mapped.feature_levels.core);
        try std.testing.expect(mapped.supported_features.isEnabled(.core_features_and_limits));
    }
}

test "native core compression baseline requires BC or both ETC2 and ASTC" {
    var device = queriedNativeCaps();
    var mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(mapped.feature_levels.core);
    try std.testing.expect(!mapped.supported_features.isEnabled(.texture_compression_bc));
    device.features.textureCompressionBC = 0;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(!mapped.feature_levels.core);
    device.features.textureCompressionETC2 = 1;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(!mapped.feature_levels.core);
    device.features.textureCompressionASTC_LDR = 1;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(mapped.feature_levels.core);
    try std.testing.expect(!mapped.supported_features.isEnabled(.texture_compression_etc2));
    try std.testing.expect(!mapped.supported_features.isEnabled(.texture_compression_astc));
    device.features.textureCompressionETC2 = 0;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(!mapped.feature_levels.core);
    device.features.textureCompressionASTC_LDR = 0;
    device.features.textureCompressionBC = 1;
    mapped = dusk.engine.native_capabilities.fromNative(&device);
    try std.testing.expect(mapped.feature_levels.core);
    try std.testing.expect(!mapped.supported_features.isEnabled(.texture_compression_bc));
}
