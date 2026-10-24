//! `engine.features`: the feature domain, the set that records which features
//! one object holds, and the closure a device applies to a request.
//!
//! Ports `src/dawn/native/Features.{h,cpp}` (`Features.h:42-57`,
//! `Features.cpp:505-545`) and the closure table at
//! `src/dawn/utils/WGPUHelpers.cpp:452-463`.
//!
//! **What this file does not claim.** It does not claim the per-feature
//! description table. `kFeatureNameAndInfoList` (`Features.h:42`,
//! `Features.cpp:52-501`) is a description, a documentation link and a
//! stability state per feature, half of it generated into
//! `Features_autogen.inl`, and that file is absent from the checkout. Nothing in
//! the port reads one, so the rows would be data no caller can reach.

const std = @import("std");

const api = @import("../api/api.zig");

/// One feature the port can name.
///
/// The tags are `api.enums.FeatureName`'s (`src/api/enums.zig:446-514`), so the
/// two enumerations convert with `@enumFromInt` instead of a switch. Members
/// are declared in tag order, which puts a feature's ordinal on its tag and
/// makes `FeaturesSet` a bitset over the ordinal.
pub const Feature = enum(u32) {
    dawn_internal_usages,
    core_features_and_limits,
    depth_clip_control,
    depth32_float_stencil8,
    texture_compression_bc,
    texture_compression_bc_sliced_3d,
    texture_compression_etc2,
    texture_compression_astc,
    texture_compression_astc_sliced_3d,
    timestamp_query,
    indirect_first_instance,
    shader_f16,
    rg11b10_ufloat_renderable,
    bgra8_unorm_storage,
    float32_filterable,
    float32_blendable,
    clip_distances,
    dual_source_blending,
    subgroups,
    texture_formats_tier1,
    texture_formats_tier2,
    primitive_index,
    texture_component_swizzle,
    subgroup_size_control,
    texture_compression_unaligned,
    atomic_vec2u_min_max,
    multi_planar_format_nv24,
    multi_planar_format_p210,
    multi_planar_format_p410,
    shared_texture_memory_vk_dedicated_allocation,
    shared_texture_memory_a_hardware_buffer,
    shared_texture_memory_dma_buf,
    shared_texture_memory_opaque_fd,
    shared_texture_memory_zircon_handle,
    shared_texture_memory_dxgi_shared_handle,
    shared_texture_memory_d3d11_texture_2d,
    shared_texture_memory_io_surface,
    shared_texture_memory_egl_image,
    shared_fence_vk_semaphore_opaque_fd,
    shared_fence_sync_fd,
    shared_fence_vk_semaphore_zircon_handle,
    shared_fence_dxgi_shared_handle,
    shared_fence_mtl_shared_event,
    shared_buffer_memory_d3d12_resource,
    static_samplers,
    y_cb_cr_vulkan_samplers,
    shader_module_compilation_options,
    dawn_load_resolve_texture,
    dawn_partial_load_resolve_texture,
    multi_draw_indirect,
    dawn_texel_copy_buffer_row_alignment,
    flexible_texture_views,
    chromium_experimental_subgroup_matrix,
    shared_fence_egl_sync,
    dawn_device_allocator_control,
    adapter_properties_wgpu,
    shared_buffer_memory_from_windows_handle,
    shared_texture_memory_d3d12_resource,
    chromium_experimental_sampling_resource_table,
    unorm16_formats_for_external_texture,
    opaque_y_cb_cr_android_for_external_texture,
    unorm16_filterable,
    render_pass_render_area,
    adapter_properties_drm,
    dawn_allow_undefined_load_store_op,
    buffer_map_write_extended_usages,
    shared_buffer_memory_host_pointer,
};

/// How many features the port names. `src/api/enums.zig:446-514` is the
/// census: `dawn.json` declares 91 feature names, 24 of them reuse a tag the
/// generator had already spent (`src/api/enums.zig:422-445`), and the enum
/// keeps one name per tag.
pub const feature_count: usize = 67;

/// The bits one word of `FeaturesSet.bits` holds.
const bit_count_per_word: usize = @bitSizeOf(u64);

/// The words `FeaturesSet.bits` holds. `feature_count` bits round up to whole
/// words, so the word count cannot drift away from the domain size.
const feature_word_count: usize =
    (feature_count + bit_count_per_word - 1) / bit_count_per_word;

/// The port's feature for one API name. `FromCppAPI` (`Features.cpp:510-512`) is
/// the one-line overload of `EnableFeature`, and the comptime block below is
/// what lets it be `@enumFromInt` rather than a switch.
pub fn fromApiName(name: api.FeatureName) Feature {
    return @fromBackingInt(@intCast(@backingInt(name)));
}

/// The closure `DeviceBase::ApplyFeatures` (`Device.cpp:1734-1753`) applies to a
/// request, as data.
///
/// `kImplicitlyEnabledFeaturesMap` (`WGPUHelpers.cpp:452-463`) lists five edges.
/// The fifth, `BufferMapExtendedUsages` to `BufferMapWriteExtendedUsages`
/// (`:459-460`), has no row here: the generated `api.FeatureName` spent that
/// name's tag on another feature (`src/api/enums.zig:465`), so no caller of
/// this port can name its head. An edge no caller can start on is a row that
/// never fires.
pub const implicitly_enabled: [4][2]Feature = .{
    .{ .texture_formats_tier1, .rg11b10_ufloat_renderable },
    .{ .texture_formats_tier2, .texture_formats_tier1 },
    .{ .subgroup_size_control, .subgroups },
    .{ .chromium_experimental_subgroup_matrix, .subgroups },
};

/// Which features one object holds. `FeaturesBitSet` (`Features.h:49`) is an
/// `ityp::bitset` upstream, which is a word array and three reads here.
pub const FeaturesSet = struct {
    bits: [feature_word_count]u64 = @splat(0),

    /// Marks a feature present. `FeaturesSet::EnableFeature`
    /// (`Features.cpp:505-508`). Upstream asserts the argument is not
    /// `Feature::InvalidEnum`; the parameter here is this file's `enum`, which
    /// has no such member, so the assertion is the type.
    pub fn enable(self: *FeaturesSet, feature: Feature) void {
        const index: usize = @intCast(@backingInt(feature));
        std.debug.assert(index < feature_count);
        self.bits[index / bit_count_per_word] |=
            @as(u64, 1) << @as(u6, @intCast(index % bit_count_per_word));
    }

    /// Whether a feature is present. `FeaturesSet::IsEnabled`
    /// (`Features.cpp:514-517`).
    pub fn isEnabled(self: FeaturesSet, feature: Feature) bool {
        const index: usize = @intCast(@backingInt(feature));
        std.debug.assert(index < feature_count);
        return self.bits[index / bit_count_per_word] &
            (@as(u64, 1) << @as(u6, @intCast(index % bit_count_per_word))) != 0;
    }

    /// The features in the set, ascending by tag. `ToSupportedFeatures`
    /// (`Features.cpp:524-545`).
    ///
    /// Upstream allocates a `HeapArray`; the port writes into a caller-owned
    /// array and returns the slice of it that was filled. The `index == count` assertion
    /// at `Features.cpp:542` survives as the read-back below.
    pub fn toSupportedFeatures(
        self: FeaturesSet,
        out: *[feature_count]api.FeatureName,
    ) []const api.FeatureName {
        var written: usize = 0;
        // Bound: the tag domain, `feature_count` tags, each visited once. The
        // tags are dense, so `@enumFromInt` traps on none of them.
        for (0..feature_count) |tag| {
            if (!self.isEnabled(@fromBackingInt(@intCast(tag)))) continue;
            out[written] = @fromBackingInt(@intCast(tag));
            written += 1;
        }
        std.debug.assert(written == self.count());
        return out[0..written];
    }

    /// How many features are present. `ToSupportedFeatures` (`Features.cpp:529`)
    /// sizes its allocation with it, so the port reads the same number back out
    /// of the bits instead of trusting the write loop.
    fn count(self: FeaturesSet) usize {
        var total: usize = 0;
        // Bound: the word array, `feature_word_count` words.
        for (self.bits) |word| total += @as(usize, @popCount(word));
        return total;
    }
};

comptime {
    // The two enumerations name one feature per tag, and the same feature on
    // each tag. Without this, `fromApiName` answers a neighbouring feature the
    // day `src/api/enums.zig` gains, drops or renames a name, and nothing else
    // in the port would say so.
    if (@typeInfo(api.FeatureName).@"enum".field_names.len != feature_count) {
        @compileError("every api.FeatureName member must have exactly one Feature");
    }
    for (@typeInfo(Feature).@"enum".field_values) |field_value| {
        const mine: Feature = @fromBackingInt(@intCast(field_value));
        const theirs: api.FeatureName = @fromBackingInt(@intCast(field_value));
        if (@tagName(mine) != @tagName(theirs)) {
            @compileError("a feature tag names two features: " ++ @tagName(mine));
        }
    }
}

test "the two enumerations name the same feature on the same tag" {
    // The comptime block above proves the tags; this proves the conversion, so
    // a `fromApiName` that stopped being `@enumFromInt` fails here.
    inline for (@typeInfo(api.FeatureName).@"enum".field_values) |field_value| {
        const name: api.FeatureName = @fromBackingInt(@intCast(field_value));
        try std.testing.expectEqual(field_value, @backingInt(fromApiName(name)));
    }
}

test "a set comes back ascending by tag and as long as its bits" {
    var set: FeaturesSet = .{};
    set.enable(.subgroups);
    set.enable(.dawn_internal_usages);
    set.enable(.core_features_and_limits);
    set.enable(.subgroups);

    var out: [feature_count]api.FeatureName = undefined;
    const reported = set.toSupportedFeatures(&out);

    try std.testing.expectEqual(@as(usize, 3), reported.len);
    try std.testing.expectEqual(api.FeatureName.dawn_internal_usages, reported[0]);
    try std.testing.expectEqual(api.FeatureName.core_features_and_limits, reported[1]);
    try std.testing.expectEqual(api.FeatureName.subgroups, reported[2]);
}

test "no implicit edge points at a feature that walks back to it" {
    // `applyFeatures` (`src/engine/device.zig:401-415`) runs one pass per edge
    // and asserts the set stopped changing. That assertion holds only while the
    // edge list has no cycle, and the claim is about the whole list, so the
    // list is walked from every head and each walk must terminate inside the
    // bound `applyFeatures` uses.
    for (implicitly_enabled) |edge| {
        var reached: FeaturesSet = .{};
        reached.enable(edge[0]);
        var pass_count: usize = 0;
        var changed = true;
        // Bound: `implicitly_enabled.len` passes plus the one that finds nothing
        // left to do. A cyclic list exhausts it with `changed` still set.
        while (changed and pass_count < implicitly_enabled.len + 1) : (pass_count += 1) {
            changed = false;
            for (implicitly_enabled) |step| {
                if (!reached.isEnabled(step[0])) continue;
                if (reached.isEnabled(step[1])) continue;
                reached.enable(step[1]);
                changed = true;
            }
        }
        try std.testing.expect(!changed);
    }
}
