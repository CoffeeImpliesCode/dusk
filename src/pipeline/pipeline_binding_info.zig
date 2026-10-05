//! Binding counts: the fold and the limit check.
//!
//! **What this file is.** Dawn's `BindingInfo.cpp` — `IncrementBindingCounts`
//! (`src/dawn/native/BindingInfo.cpp:86`), `AccumulateBindingCounts` (`:152`)
//! and `ValidateBindingCounts` (`:174`).
//!
//! **What this file does not claim.** It does not claim the descriptor types.
//! Dawn's `BufferBindingLayout`, `TextureBindingLayout` and the rest live in
//! M12's `BindGroupLayoutEntry`, and M12 calls the two fold functions with its
//! own entries; the port's fold takes a plain `EntryKind` so both callers read
//! the same counters. It does not claim the limits either: every limit is a
//! field of `BindingLimits`, so the whole check runs with no device.

const std = @import("std");

const pipeline = @import("pipeline.zig");

pub const Stage = pipeline.Stage;
pub const PipelineError = pipeline.PipelineError;

/// The number of stages a count table has. `pipeline.Stage` has exactly these
/// three members (`src/dawn/native/PerStage.h:41`), so the table is total
/// over the stage set and not over a magic bound.
const stage_count = pipeline.stage_count;

/// What one bind group layout entry occupies. Dawn reads the variant at
/// `BindingInfo.cpp:40`-`:63` and picks the member that matches.
pub const EntryKind = enum {
    buffer_unused,
    buffer_uniform,
    buffer_storage,
    buffer_read_only_storage,
    sampler,
    sampled_texture,
    storage_texture,
    texel_buffer,
    external_texture,
    static_sampler,
    /// Dawn returns early for this one (`BindingInfo.cpp:129`-`:131`): an input
    /// attachment occupies no counted slot.
    input_attachment,
};

pub const PerStageCounts = struct {
    sampled_texture_count: u32 = 0,
    sampler_count: u32 = 0,
    storage_buffer_count: u32 = 0,
    storage_texture_count: u32 = 0,
    texel_buffer_count: u32 = 0,
    uniform_buffer_count: u32 = 0,
    external_texture_count: u32 = 0,
    static_sampler_count: u32 = 0,
};

pub const BindingCounts = struct {
    total_count: u32 = 0,
    buffer_count: u32 = 0,
    unverified_buffer_count: u32 = 0,
    dynamic_uniform_buffer_count: u32 = 0,
    dynamic_storage_buffer_count: u32 = 0,
    static_sampler_count: u32 = 0,
    per_stage: [stage_count]PerStageCounts = .{
        .{},
        .{},
        .{},
    },
};

/// One bind group layout entry, as much of it as the fold reads.
pub const Entry = struct {
    kind: EntryKind,
    /// Dawn's `bindingArraySize` (`BindingInfo.cpp:88`), clamped to one.
    array_size: u32 = 1,
    has_dynamic_offset: bool = false,
    min_binding_size: u64 = 1,
    /// Dawn's `entry->visibility` (`BindingInfo.cpp:147`).
    visibility: [stage_count]bool = .{ true, true, true },
};

/// What one external texture occupies per counted slot
/// (`src/dawn/common/Constants.h:98`-`:100`).
pub const sampled_textures_per_external_texture: u32 = 4;
pub const samplers_per_external_texture: u32 = 1;
pub const uniforms_per_external_texture: u32 = 1;

/// The subset of Dawn's `CombinedLimits` the check reads.
pub const BindingLimits = struct {
    max_dynamic_uniform_buffers_per_pipeline_layout: u32,
    max_dynamic_storage_buffers_per_pipeline_layout: u32,
    max_sampled_textures_per_shader_stage: u32,
    max_samplers_per_shader_stage: u32,
    max_uniform_buffers_per_shader_stage: u32,
    max_storage_buffers_per_shader_stage: u32,
    max_storage_textures_per_shader_stage: u32,
    /// The compatibility floors, which Dawn reads out of `limits.compat`
    /// (`BindingInfo.cpp:209`-`:214`).
    max_storage_buffers_in_vertex_stage: u32,
    max_storage_buffers_in_fragment_stage: u32,
    max_storage_textures_in_vertex_stage: u32,
    max_storage_textures_in_fragment_stage: u32,
};

/// One layout's fold. Ports `IncrementBindingCounts` (`BindingInfo.cpp:86`).
pub fn incrementBindingCounts(counts: *BindingCounts, entry: Entry) void {
    const array_size = @max(1, entry.array_size);
    counts.total_count += array_size;

    switch (entry.kind) {
        .buffer_unused, .input_attachment => return,
        .buffer_uniform, .buffer_storage, .buffer_read_only_storage => {
            counts.buffer_count += array_size;
            if (entry.min_binding_size == 0) counts.unverified_buffer_count += array_size;
            if (entry.has_dynamic_offset) {
                switch (entry.kind) {
                    .buffer_uniform => counts.dynamic_uniform_buffer_count += array_size,
                    .buffer_storage => counts.dynamic_storage_buffer_count += array_size,
                    else => {},
                }
            }
        },
        .static_sampler => counts.static_sampler_count += array_size,
        else => {},
    }

    var stage: usize = 0;
    while (stage < stage_count) : (stage += 1) {
        if (!entry.visibility[stage]) continue;
        addPerStageCounts(&counts.per_stage[stage], oneForKind(entry.kind, array_size));
    }
}

/// Field-wise fold of one entry's per-stage increment. Zig has no `+=` for a
/// struct, and Dawn adds through a pointer-to-member at `BindingInfo.cpp:148`,
/// so the port names every member instead. Both folds come through here, so
/// the eight members are written once.
fn addPerStageCounts(target: *PerStageCounts, addend: PerStageCounts) void {
    target.sampled_texture_count += addend.sampled_texture_count;
    target.sampler_count += addend.sampler_count;
    target.storage_buffer_count += addend.storage_buffer_count;
    target.storage_texture_count += addend.storage_texture_count;
    target.texel_buffer_count += addend.texel_buffer_count;
    target.uniform_buffer_count += addend.uniform_buffer_count;
    target.external_texture_count += addend.external_texture_count;
    target.static_sampler_count += addend.static_sampler_count;
}

/// The per-stage increment for one entry kind. Dawn picks a pointer-to-member
/// at `BindingInfo.cpp:107`-`:143` and adds through it at `:148`; the port
/// names the member, which is the same decision with the pointer arithmetic
/// removed.
fn oneForKind(kind: EntryKind, array_size: u32) PerStageCounts {
    return switch (kind) {
        .sampler => .{ .sampler_count = array_size },
        .sampled_texture => .{ .sampled_texture_count = array_size },
        .storage_texture => .{ .storage_texture_count = array_size },
        .texel_buffer => .{ .texel_buffer_count = array_size },
        .external_texture => .{ .external_texture_count = array_size },
        .static_sampler => .{ .static_sampler_count = array_size },
        .buffer_uniform => .{ .uniform_buffer_count = array_size },
        .buffer_storage, .buffer_read_only_storage => .{ .storage_buffer_count = array_size },
        .buffer_unused, .input_attachment => .{},
    };
}

/// Ports `AccumulateBindingCounts` (`BindingInfo.cpp:152`).
pub fn accumulateBindingCounts(counts: *BindingCounts, other: BindingCounts) void {
    counts.total_count += other.total_count;
    counts.buffer_count += other.buffer_count;
    counts.unverified_buffer_count += other.unverified_buffer_count;
    counts.dynamic_uniform_buffer_count += other.dynamic_uniform_buffer_count;
    counts.dynamic_storage_buffer_count += other.dynamic_storage_buffer_count;
    counts.static_sampler_count += other.static_sampler_count;
    var stage: usize = 0;
    while (stage < stage_count) : (stage += 1) {
        addPerStageCounts(&counts.per_stage[stage], other.per_stage[stage]);
    }
}

/// Ports `ValidateBindingCounts` (`BindingInfo.cpp:174`), in Dawn's order: the
/// static-sampler rule, the two per-pipeline-layout rules, the per-stage rules,
/// then the four compatibility floors.
///
/// Both arguments are values, so the whole check runs with no device.
pub fn validateBindingCounts(
    limits: BindingLimits,
    counts: BindingCounts,
) PipelineError!void {
    var stage: usize = 0;
    while (stage < stage_count) : (stage += 1) {
        if (counts.per_stage[stage].static_sampler_count != 0 and
            counts.per_stage[stage].external_texture_count != 0)
        {
            return error.StaticSamplerAndExternalTextureInSamePipeline;
        }
    }

    const dynamic_uniform = counts.dynamic_uniform_buffer_count;
    if (dynamic_uniform > limits.max_dynamic_uniform_buffers_per_pipeline_layout) {
        return error.DynamicUniformBuffersAboveLimit;
    }
    const dynamic_storage = counts.dynamic_storage_buffer_count;
    if (dynamic_storage > limits.max_dynamic_storage_buffers_per_pipeline_layout) {
        return error.DynamicStorageBuffersAboveLimit;
    }

    stage = 0;
    while (stage < stage_count) : (stage += 1) {
        try validateStageCounts(limits, counts.per_stage[stage]);
    }
    return validateCompatibilityFloors(limits, counts);
}

/// The per-stage rules at `BindingInfo.cpp:218`-`:295`. Every one of them is
/// the raw count or the count plus the external-texture weight
/// (`Constants.h:98`), so the pair is checked together.
fn validateStageCounts(
    limits: BindingLimits,
    per_stage: PerStageCounts,
) PipelineError!void {
    const external = per_stage.external_texture_count;

    if (per_stage.sampled_texture_count > limits.max_sampled_textures_per_shader_stage) {
        return error.SampledTexturesPerShaderStageAboveLimit;
    }
    const sampled_with_external = per_stage.sampled_texture_count +
        external * sampled_textures_per_external_texture;
    if (sampled_with_external > limits.max_sampled_textures_per_shader_stage) {
        return error.SampledTexturesPerShaderStageAboveLimit;
    }

    if (per_stage.sampler_count > limits.max_samplers_per_shader_stage) {
        return error.SamplersPerShaderStageAboveLimit;
    }
    const samplers_with_external = per_stage.sampler_count +
        external * samplers_per_external_texture;
    if (samplers_with_external > limits.max_samplers_per_shader_stage) {
        return error.SamplersPerShaderStageAboveLimit;
    }

    if (per_stage.storage_buffer_count > limits.max_storage_buffers_per_shader_stage) {
        return error.StorageBuffersPerShaderStageAboveLimit;
    }
    if (per_stage.storage_texture_count > limits.max_storage_textures_per_shader_stage) {
        return error.StorageTexturesPerShaderStageAboveLimit;
    }
    if (per_stage.uniform_buffer_count > limits.max_uniform_buffers_per_shader_stage) {
        return error.UniformBuffersPerShaderStageAboveLimit;
    }
    const uniforms_with_external = per_stage.uniform_buffer_count +
        external * uniforms_per_external_texture;
    if (uniforms_with_external > limits.max_uniform_buffers_per_shader_stage) {
        return error.UniformBuffersPerShaderStageAboveLimit;
    }
}

/// The four `limits.compat` rules at `BindingInfo.cpp:299`-`:331`. They exist
/// for the vertex and the fragment stage only, which is why this names the two
/// rather than looping.
fn validateCompatibilityFloors(
    limits: BindingLimits,
    counts: BindingCounts,
) PipelineError!void {
    const vertex = counts.per_stage[@intFromEnum(Stage.vertex)];
    const fragment = counts.per_stage[@intFromEnum(Stage.fragment)];
    if (vertex.storage_buffer_count > limits.max_storage_buffers_in_vertex_stage) {
        return error.StorageBuffersInVertexStageAboveLimit;
    }
    if (fragment.storage_buffer_count > limits.max_storage_buffers_in_fragment_stage) {
        return error.StorageBuffersInFragmentStageAboveLimit;
    }
    if (vertex.storage_texture_count > limits.max_storage_textures_in_vertex_stage) {
        return error.StorageTexturesInVertexStageAboveLimit;
    }
    if (fragment.storage_texture_count > limits.max_storage_textures_in_fragment_stage) {
        return error.StorageTexturesInFragmentStageAboveLimit;
    }
}

test "the compatibility floor rejects what the WebGPU limit allows" {
    const limits: BindingLimits = .{
        .max_dynamic_uniform_buffers_per_pipeline_layout = 8,
        .max_dynamic_storage_buffers_per_pipeline_layout = 4,
        .max_sampled_textures_per_shader_stage = 16,
        .max_samplers_per_shader_stage = 16,
        .max_uniform_buffers_per_shader_stage = 12,
        .max_storage_buffers_per_shader_stage = 8,
        .max_storage_textures_per_shader_stage = 4,
        .max_storage_buffers_in_vertex_stage = 0,
        .max_storage_buffers_in_fragment_stage = 4,
        .max_storage_textures_in_vertex_stage = 4,
        .max_storage_textures_in_fragment_stage = 4,
    };

    var counts: BindingCounts = .{};
    incrementBindingCounts(&counts, .{
        .kind = .buffer_storage,
        .visibility = .{ true, false, false },
    });
    try std.testing.expectEqual(@as(u32, 1), counts.per_stage[0].storage_buffer_count);
    try std.testing.expectEqual(@as(u32, 0), counts.per_stage[1].storage_buffer_count);
    try std.testing.expectEqual(@as(u32, 1), counts.buffer_count);

    try std.testing.expectError(
        error.StorageBuffersInVertexStageAboveLimit,
        validateBindingCounts(limits, counts),
    );
}

test "the same layout in the fragment stage is under the floor" {
    const limits: BindingLimits = .{
        .max_dynamic_uniform_buffers_per_pipeline_layout = 8,
        .max_dynamic_storage_buffers_per_pipeline_layout = 4,
        .max_sampled_textures_per_shader_stage = 16,
        .max_samplers_per_shader_stage = 16,
        .max_uniform_buffers_per_shader_stage = 12,
        .max_storage_buffers_per_shader_stage = 8,
        .max_storage_textures_per_shader_stage = 4,
        .max_storage_buffers_in_vertex_stage = 0,
        .max_storage_buffers_in_fragment_stage = 4,
        .max_storage_textures_in_vertex_stage = 4,
        .max_storage_textures_in_fragment_stage = 4,
    };

    var counts: BindingCounts = .{};
    incrementBindingCounts(&counts, .{
        .kind = .buffer_storage,
        .visibility = .{ false, true, false },
    });
    try validateBindingCounts(limits, counts);
}

test "a fold accumulates across layouts" {
    var first: BindingCounts = .{};
    incrementBindingCounts(&first, .{ .kind = .sampler, .array_size = 2 });
    var second: BindingCounts = .{};
    incrementBindingCounts(&second, .{
        .kind = .buffer_uniform,
        .has_dynamic_offset = true,
        .visibility = .{ false, true, true },
    });

    var total = first;
    accumulateBindingCounts(&total, second);

    try std.testing.expectEqual(@as(u32, 3), total.total_count);
    try std.testing.expectEqual(@as(u32, 2), total.per_stage[0].sampler_count);
    try std.testing.expectEqual(@as(u32, 1), total.per_stage[1].uniform_buffer_count);
    try std.testing.expectEqual(@as(u32, 1), total.dynamic_uniform_buffer_count);
}

test "an input attachment counts once and names no stage" {
    // Dawn returns before it picks a per-stage member
    // (`BindingInfo.cpp:129`-`:131`), so the entry reaches the total and no
    // stage. A fold that counted it as a sampled texture would refuse a
    // layout upstream accepts.
    var counts: BindingCounts = .{};
    incrementBindingCounts(&counts, .{ .kind = .input_attachment });

    try std.testing.expectEqual(@as(u32, 1), counts.total_count);
    try std.testing.expectEqual(@as(u32, 0), counts.per_stage[0].sampled_texture_count);
    try std.testing.expectEqual(@as(u32, 0), counts.per_stage[2].sampled_texture_count);
}

test "a buffer with no declared size is counted as unverified" {
    // Dawn counts a zero `minBindingSize` (`BindingInfo.cpp:98`-`:100`), so a
    // layout that under-binds is caught against the size limit rather than
    // accepted on the caller's word.
    var unverified: BindingCounts = .{};
    incrementBindingCounts(&unverified, .{
        .kind = .buffer_uniform,
        .min_binding_size = 0,
    });
    try std.testing.expectEqual(@as(u32, 1), unverified.unverified_buffer_count);

    var declared: BindingCounts = .{};
    incrementBindingCounts(&declared, .{
        .kind = .buffer_uniform,
        .min_binding_size = 1,
    });
    try std.testing.expectEqual(@as(u32, 0), declared.unverified_buffer_count);
}

test "a binding array never occupies zero slots" {
    // `std::max(1u, entry->bindingArraySize)` (`BindingInfo.cpp:88`). A fold
    // that let a zero through would let a layout pass every limit check
    // while binding nothing.
    var counts: BindingCounts = .{};
    incrementBindingCounts(&counts, .{ .kind = .sampler, .array_size = 0 });

    try std.testing.expectEqual(@as(u32, 1), counts.total_count);
    try std.testing.expectEqual(@as(u32, 1), counts.per_stage[0].sampler_count);
}
