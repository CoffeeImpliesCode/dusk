//! The Vulkan layout back end: a `VkDescriptorSetLayout` per bind group layout,
//! and a `VkPipelineLayout` per pipeline layout.
//!
//! **What this file is.** The port of `vulkan/BindGroupLayoutVk.{h,cpp}` and
//! `vulkan/PipelineLayoutVk.{h,cpp}` at Dawn
//! `32f77c02294310054a660c393feded4bcb3f203c`. Dawn keeps a map from a layout
//! to its `VkDescriptorSetLayout` and caches one `VkPipelineLayout` per
//! specialization (`BindGroupLayoutVk.cpp:259`-`:301`, `PipelineLayoutVk.cpp:131`-`:152`).
//!
//! **No cache here.** Dawn's caches live on the device, and M14 owns the
//! pipeline cache and the content-addressed object caches. This file builds the
//! two handles and destroys them, and the caller decides where to keep them.
//!
//! **What this file does not claim.** It does not claim the static-sampler
//! specialization map (`BindGroupLayoutVk.h:120`-`:123`), the bind-group slab
//! allocator (`:111`), or the resource table's own pool
//! (`vulkan/ResourceTableVk.cpp`).
//!
//! Native binding numbers match the caller's unchanged SPIR-V. Packed indices
//! address host metadata only; expanded array entries share one Vulkan binding.

const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("../vk/dispatch.zig");
const errors = @import("../core/errors.zig");
const layout_internal = @import("layout_internal.zig");

pub const Error = errors.UnrecoverableError || std.mem.Allocator.Error ||
    vk.Error || vk.LoadError || error{
    /// The packed layout holds an entry with no Vulkan descriptor. Dawn asserts
    /// the same domain at `BindGroupLayoutVk.cpp:177`, `:180`, `:205`, `:207`
    /// and `:211`; the port reports it rather than writing a short binding
    /// array a caller would never notice.
    UnmappedBindingType,
    /// Expanded array metadata is incomplete, interleaved, or out of bounds.
    InvalidBindingArrayLayout,
    /// Two physical descriptor bindings have the same public number.
    DuplicateBindingNumber,
    /// The per-type descriptor count cannot fit Vulkan's `u32` count.
    DescriptorCountOverflow,
    ImmutableSamplerBindingInvalid,

    /// More push constant ranges than `max_push_constant_ranges`. Dawn
    /// declares one range and points the create info at it
    /// (`PipelineLayoutVk.cpp:98`-`:105`), so a port that reached this had a
    /// count the array was not sized for.
    TooManyPushConstantRanges,
    ImmediateSizeInvalid,
    TooManyBindGroups,
};

/// The number of distinct `VkDescriptorType` values the port can produce. It
/// bounds `descriptorCountsPerType`'s scratch array; a type outside it is
/// refused there rather than indexing past the end.
pub const descriptor_type_count = 12;

/// Borrows an actual sampler handle through descriptor construction.
pub const ImmutableSamplerBinding = struct {
    binding: u32,
    sampler: vulkan.VkSampler,
};

/// The number of push constant ranges a `VkPipelineLayout` is created with.
/// Dawn keeps one range and fills it in only when the specialization has
/// immediate data (`PipelineLayoutVk.cpp:95`-`:105`), so a layout with push
/// constants has one range and a layout without has none. The array in
/// `createPipelineLayout` is this wide, and the count is checked against it.
pub const max_push_constant_ranges = 1;

/// `VulkanDescriptorType` (`vulkan/BindGroupLayoutVk.cpp:157`-`:212`).
///
/// The switch is exhaustive over `BindingLayout`, so a new kind is a compile
/// error until it is mapped. An external texture has no descriptor of its own —
/// it was expanded into sampled textures and a uniform buffer before the sort —
/// which is why Dawn's `DAWN_UNREACHABLE` at `:211` is a claim the port can
/// make too.
pub fn descriptorTypeFor(layout: layout_internal.BindingLayout) vulkan.VkDescriptorType {
    return switch (layout) {
        .buffer => |buffer| switch (buffer.binding_type) {
            .uniform => if (buffer.has_dynamic_offset)
                vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC
            else
                vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .storage, .read_only_storage, .internal_storage, .internal_read_only_storage => if (buffer.has_dynamic_offset)
                vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
            else
                vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        },
        .sampler => vulkan.VK_DESCRIPTOR_TYPE_SAMPLER,
        .static_sampler => |sampler| switch (sampler.use) {
            // A freestanding sampler is a plain sampler; a paired one becomes a
            // combined image sampler so one fetch samples.
            .freestanding => vulkan.VK_DESCRIPTOR_TYPE_SAMPLER,
            .paired_with_texture, .single_texture_ycbcr => vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        },
        .sampled_texture => vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .storage_texture => vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        // Dawn returns a storage texel buffer for read-only access as well
        // (`BindGroupLayoutVk.cpp:193`-`:208`), for bindless support.
        .texel_buffer => vulkan.VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER,
        .input_attachment => vulkan.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
        .external_texture => unreachable,
    };
}

/// Whether one layout kind reaches a Vulkan descriptor at all. The only kind
/// that does not is an external texture, which `layout_internal` already
/// expanded into sampled textures and a uniform buffer
/// (`BindGroupLayoutInternal.cpp:561`-`:574`).
pub fn isMapped(layout: layout_internal.BindingLayout) bool {
    return layout != .external_texture;
}

/// The stage mask one binding is visible from. Dawn builds the same mask in
/// `ComputeVulkanStaticBindings` (`BindGroupLayoutVk.cpp:108`).
pub fn stageFlagsFor(visibility: layout_internal.ShaderStages) vulkan.VkShaderStageFlags {
    var flags: vulkan.VkShaderStageFlags = 0;
    if (visibility.vertex) {
        flags |= @as(vulkan.VkShaderStageFlags, @intCast(vulkan.VK_SHADER_STAGE_VERTEX_BIT));
    }
    if (visibility.fragment) {
        flags |= @as(vulkan.VkShaderStageFlags, @intCast(vulkan.VK_SHADER_STAGE_FRAGMENT_BIT));
    }
    if (visibility.compute) {
        flags |= @as(vulkan.VkShaderStageFlags, @intCast(vulkan.VK_SHADER_STAGE_COMPUTE_BIT));
    }
    return flags;
}

/// The per-type descriptor counts the set allocator sizes its pools from.
/// `ComputeVulkanStaticBindings` (`BindGroupLayoutVk.cpp:56`-`:153`) produces
/// Dawn's `descriptorCountPerType`, and `DescriptorSetAllocator` divides by its
/// sum (`DescriptorSetAllocator.cpp:61`-`:73`).
///
/// The entries come out sorted by the descriptor type's numeric value, so two
/// runs of the same layout produce the same array.
pub fn descriptorCountsPerType(
    allocator: std.mem.Allocator,
    internal: *const layout_internal.Layout,
) Error![]vulkan.VkDescriptorPoolSize {
    var counts: [descriptor_type_count]u32 = @splat(0);
    const stored_count: usize = internal.entries.len;
    var binding_index: usize = 0;
    while (binding_index < stored_count) {
        const entry = internal.entries[binding_index];
        const span = try descriptorBindingSpan(internal.entries[binding_index..]);
        binding_index += span;
        if (!isMapped(entry.layout)) continue;
        const type_index: usize = @intCast(descriptorTypeFor(entry.layout));
        if (type_index >= descriptor_type_count) return error.UnmappedBindingType;
        const physical_count = try descriptorCountFor(entry);
        counts[type_index] = std.math.add(u32, counts[type_index], physical_count) catch
            return error.DescriptorCountOverflow;
    }

    var used_count: usize = 0;
    for (counts) |count| {
        if (count != 0) used_count += 1;
    }

    const out = try allocator.alloc(vulkan.VkDescriptorPoolSize, used_count);
    errdefer allocator.free(out);

    var written: usize = 0;
    for (counts, 0..) |count, type_index| {
        if (count == 0) continue;
        out[written] = .{
            .type = @intCast(type_index),
            .descriptorCount = count,
        };
        written += 1;
    }
    return out;
}

fn descriptorCountFor(entry: layout_internal.Binding) Error!u32 {
    const multiplier = if (entry.layout == .static_sampler)
        entry.layout.static_sampler.combined_image_sampler_descriptor_count
    else
        1;
    if (multiplier == 0) return error.ImmutableSamplerBindingInvalid;
    return std.math.mul(u32, entry.array_size, multiplier) catch
        return error.DescriptorCountOverflow;
}

pub fn combinedImageSamplerDescriptorCount(internal: *const layout_internal.Layout) Error!u32 {
    var count: u32 = 0;
    var index: usize = 0;
    while (index < internal.entries.len) {
        const entry = internal.entries[index];
        index += try descriptorBindingSpan(internal.entries[index..]);
        if (!isMapped(entry.layout)) continue;
        if (descriptorTypeFor(entry.layout) != vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
            continue;
        count = std.math.add(u32, count, try descriptorCountFor(entry)) catch
            return error.DescriptorCountOverflow;
    }
    return count;
}

/// Releases definitions and the immutable sampler arrays each definition owns.
pub fn freeDescriptorBindings(
    allocator: std.mem.Allocator,
    bindings: []const vulkan.VkDescriptorSetLayoutBinding,
) void {
    for (bindings) |binding| {
        if (binding.pImmutableSamplers != null) {
            allocator.free(binding.pImmutableSamplers[0..binding.descriptorCount]);
        }
    }
    allocator.free(bindings);
}

fn validateImmutableSamplers(
    internal: *const layout_internal.Layout,
    samplers: []const ImmutableSamplerBinding,
) Error!void {
    if (samplers.len > internal.entries.len) return error.ImmutableSamplerBindingInvalid;
    for (samplers, 0..) |sampler, index| {
        if (sampler.sampler == null) return error.ImmutableSamplerBindingInvalid;
        const entry = internal.findBindingByNumber(sampler.binding) orelse
            return error.ImmutableSamplerBindingInvalid;
        if (entry.layout != .static_sampler or entry.array_size != 1)
            return error.ImmutableSamplerBindingInvalid;
        for (samplers[0..index]) |previous| {
            if (previous.binding == sampler.binding) return error.ImmutableSamplerBindingInvalid;
        }
    }
    for (internal.entries) |entry| {
        if (entry.layout != .static_sampler or
            entry.layout.static_sampler.use != .single_texture_ycbcr) continue;
        var found = false;
        for (samplers) |sampler| {
            if (sampler.binding == entry.binding_number) {
                found = true;
                break;
            }
        }
        if (!found) return error.ImmutableSamplerBindingInvalid;
    }
}

/// Returns owned Vulkan bindings and immutable sampler arrays sorted by shader number.
/// Each packed array becomes one binding with its full descriptor count.
/// Invalid array metadata or duplicate numbers fail without a Vulkan call.
pub fn descriptorBindings(
    allocator: std.mem.Allocator,
    internal: *const layout_internal.Layout,
    immutable_samplers: []const ImmutableSamplerBinding,
) Error![]vulkan.VkDescriptorSetLayoutBinding {
    try validateImmutableSamplers(internal, immutable_samplers);
    var count: usize = 0;
    var binding_index: usize = 0;
    while (binding_index < internal.entries.len) {
        const entry = internal.entries[binding_index];
        const span = try descriptorBindingSpan(internal.entries[binding_index..]);
        binding_index += span;
        if (isMapped(entry.layout)) count += 1;
    }
    const bindings = try allocator.alloc(vulkan.VkDescriptorSetLayoutBinding, count);
    var written: usize = 0;
    errdefer {
        for (bindings[0..written]) |binding| {
            if (binding.pImmutableSamplers != null) {
                allocator.free(binding.pImmutableSamplers[0..binding.descriptorCount]);
            }
        }
        allocator.free(bindings);
    }
    var public_numbers: std.bit_set.Static(layout_internal.max_bindings_per_bind_group) = .empty;
    binding_index = 0;
    while (binding_index < internal.entries.len) {
        const entry = internal.entries[binding_index];
        binding_index += entry.array_size;
        if (!isMapped(entry.layout)) continue;
        if (entry.binding_number < layout_internal.max_bindings_per_bind_group) {
            if (public_numbers.isSet(entry.binding_number)) return error.DuplicateBindingNumber;
            public_numbers.set(entry.binding_number);
        } else {
            for (bindings[0..written]) |previous| {
                if (previous.binding == entry.binding_number) return error.DuplicateBindingNumber;
            }
        }
        bindings[written] = .{
            .binding = entry.binding_number,
            .descriptorType = descriptorTypeFor(entry.layout),
            .descriptorCount = entry.array_size,
            .stageFlags = stageFlagsFor(entry.visibility),
        };
        written += 1;
        for (immutable_samplers) |sampler| {
            if (sampler.binding != entry.binding_number) continue;
            const handles = try allocator.alloc(vulkan.VkSampler, 1);
            handles[0] = sampler.sampler;
            bindings[written - 1].pImmutableSamplers = handles.ptr;
            break;
        }
    }
    std.debug.assert(written == count);
    std.sort.insertion(
        vulkan.VkDescriptorSetLayoutBinding,
        bindings,
        {},
        descriptorBindingNumberLessThan,
    );
    return bindings;
}

fn descriptorBindingNumberLessThan(
    _: void,
    left: vulkan.VkDescriptorSetLayoutBinding,
    right: vulkan.VkDescriptorSetLayoutBinding,
) bool {
    return left.binding < right.binding;
}

fn descriptorBindingSpan(entries: []const layout_internal.Binding) Error!usize {
    const first = entries[0];
    const span: usize = first.array_size;
    if (span == 0 or span > entries.len or first.index_in_array != 0)
        return error.InvalidBindingArrayLayout;
    if (first.array_size - 1 > std.math.maxInt(u32) - first.binding_number)
        return error.InvalidBindingArrayLayout;
    for (entries[0..span], 0..) |entry, element_index| {
        if (entry.index_in_array != element_index or entry.array_size != first.array_size or
            entry.binding_number != first.binding_number + element_index or
            entry.visibility.bits() != first.visibility.bits() or
            !std.meta.eql(entry.layout, first.layout))
            return error.InvalidBindingArrayLayout;
    }
    return span;
}

/// Creates the `VkDescriptorSetLayout` for one packed layout.
/// `BindGroupLayout::Initialize` (`BindGroupLayoutVk.cpp:230`-`:257`) creates
/// the handle from the binding array `ComputeVulkanStaticBindings` produced.
///
/// The array follows public binding-number order, independent of host packing.
/// Each expanded array contributes one definition and all of its descriptors.
/// An entry with no Vulkan descriptor contributes no definition.
pub fn createDescriptorSetLayout(
    allocator: std.mem.Allocator,
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    internal: *const layout_internal.Layout,
    immutable_samplers: []const ImmutableSamplerBinding,
) Error!vulkan.VkDescriptorSetLayout {
    const bindings = try descriptorBindings(allocator, internal, immutable_samplers);
    defer freeDescriptorBindings(allocator, bindings);
    return createDescriptorSetLayoutFromBindings(procs, device, bindings);
}

/// Emits an already-owned definition without allocating another descriptor array.
pub fn createDescriptorSetLayoutFromBindings(
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    bindings: []const vulkan.VkDescriptorSetLayoutBinding,
) Error!vulkan.VkDescriptorSetLayout {
    const create_info: vulkan.VkDescriptorSetLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO),
        .bindingCount = @intCast(bindings.len),
        .pBindings = if (bindings.len == 0) null else bindings.ptr,
    };
    const create_set_layout = procs.create_descriptor_set_layout orelse
        return error.MissingDeviceProc;
    var layout_handle: vulkan.VkDescriptorSetLayout = null;
    try vk.checkVkOomThenSuccess(create_set_layout(
        device,
        &create_info,
        null,
        &layout_handle,
    ));
    return layout_handle;
}

/// `BindGroupLayout::DestroyImpl` (`BindGroupLayoutVk.cpp:311`), which drops
/// every handle it holds at once.
///
/// Dawn's own comment says a descriptor set layout is never used by execution
/// and is destroyed immediately rather than going on the fenced deleter
/// (`BindGroupLayoutVk.cpp:321`-`:322`). The port destroys it here and returns
/// the refusal as a typed error rather than a trap.
pub fn destroyDescriptorSetLayout(
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    set_layout: vulkan.VkDescriptorSetLayout,
) Error!void {
    const destroy_set_layout = procs.destroy_descriptor_set_layout orelse
        return error.MissingDeviceProc;
    destroy_set_layout(device, set_layout, null);
}

/// Creates the `VkPipelineLayout`. `CreateVkPipelineLayout`
/// (`PipelineLayoutVk.cpp:53`-`:113`) orders the sets framebuffer-fetch first,
/// then the resource table, then the bind group layouts.
///
/// The port takes the ordered slice rather than a pipeline layout, because the
/// two leading sets land with the milestones that own them. The order is then
/// visible in the argument instead of hidden in a branch here, and a caller that
/// wants Dawn's order builds the slice in it.
pub fn createPipelineLayout(
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    set_layouts: []const vulkan.VkDescriptorSetLayout,
    push_constant_byte_count: u32,
) Error!vulkan.VkPipelineLayout {
    if (push_constant_byte_count > 256 or push_constant_byte_count % 4 != 0)
        return error.ImmediateSizeInvalid;
    var push_constant_ranges: [max_push_constant_ranges]vulkan.VkPushConstantRange = @splat(.{});
    var push_constant_range_count: u32 = 0;
    if (push_constant_byte_count != 0) {
        // Dawn uses one range covering every stage it has immediate data for
        // (`PipelineLayoutVk.cpp:98`-`:105`). The bound is named above, and a
        // count past it is reported rather than indexed past the end.
        if (push_constant_range_count >= push_constant_ranges.len) {
            return error.TooManyPushConstantRanges;
        }
        push_constant_ranges[push_constant_range_count] = .{
            .stageFlags = @intCast(vulkan.VK_SHADER_STAGE_ALL),
            .offset = 0,
            .size = push_constant_byte_count,
        };
        push_constant_range_count += 1;
    }

    const create_info: vulkan.VkPipelineLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO),
        .setLayoutCount = @intCast(set_layouts.len),
        .pSetLayouts = set_layouts.ptr,
        // Dawn leaves both null and only fills them together
        // (`PipelineLayoutVk.cpp:95`-`:96` against `:103`-`:104`).
        .pushConstantRangeCount = @intCast(push_constant_range_count),
        .pPushConstantRanges = if (push_constant_range_count == 0)
            null
        else
            &push_constant_ranges,
    };
    const create_pipeline_layout = procs.create_pipeline_layout orelse
        return error.MissingDeviceProc;
    var pipeline_layout: vulkan.VkPipelineLayout = null;
    try vk.checkVkOomThenSuccess(create_pipeline_layout(
        device,
        &create_info,
        null,
        &pipeline_layout,
    ));
    return pipeline_layout;
}

/// `PipelineLayout::DestroyImpl` (`PipelineLayoutVk.cpp:156`).
///
/// A missing entry point is reported as a typed error.
pub fn destroyPipelineLayout(
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    pipeline_layout: vulkan.VkPipelineLayout,
) Error!void {
    const destroy_pipeline_layout = procs.destroy_pipeline_layout orelse
        return error.MissingDeviceProc;
    destroy_pipeline_layout(device, pipeline_layout, null);
}

test "immutable conversion uses one shader binding and its physical pool cost" {
    const entries = [_]layout_internal.Entry{
        .{
            .binding_number = 0,
            .visibility = .{ .fragment = true },
            .kind = .{ .static_sampler = .{
                .use = .single_texture_ycbcr,
                .sampled_texture_binding = null,
                .sampler_identity = 1,
                .combined_image_sampler_descriptor_count = 3,
            } },
        },
        .{
            .binding_number = 1,
            .visibility = .{ .fragment = true },
            .kind = .{ .buffer = .{
                .binding_type = .uniform,
                .has_dynamic_offset = false,
                .min_binding_size = 16,
            } },
        },
    };
    var internal = try layout_internal.Layout.init(std.testing.allocator, .{
        .entries = &entries,
    }, .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
        .allow_internal_bindings = true,
    });
    defer internal.deinit(std.testing.allocator);
    const samplers = [_]ImmutableSamplerBinding{.{
        .binding = 0,
        .sampler = @ptrFromInt(0x1000),
    }};
    const bindings = try descriptorBindings(std.testing.allocator, &internal, &samplers);
    defer freeDescriptorBindings(std.testing.allocator, bindings);
    try std.testing.expectEqual(@as(usize, 2), bindings.len);
    try std.testing.expectEqual(@as(u32, 0), bindings[0].binding);
    try std.testing.expectEqual(
        @as(vulkan.VkDescriptorType, vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER),
        bindings[0].descriptorType,
    );
    try std.testing.expectEqual(@as(u32, 1), bindings[0].descriptorCount);
    try std.testing.expect(bindings[0].pImmutableSamplers != null);
    try std.testing.expectEqual(samplers[0].sampler, bindings[0].pImmutableSamplers[0]);
    try std.testing.expect(bindings[0].pImmutableSamplers != &samplers[0].sampler);
    try std.testing.expectEqual(@as(u32, 1), bindings[1].binding);
    const counts = try descriptorCountsPerType(std.testing.allocator, &internal);
    defer std.testing.allocator.free(counts);
    try std.testing.expectEqual(@as(usize, 2), counts.len);
    try std.testing.expectEqual(@as(u32, 3), counts[0].descriptorCount);
    try std.testing.expectEqual(@as(u32, 1), counts[1].descriptorCount);
    try std.testing.expectEqual(@as(u32, 3), try combinedImageSamplerDescriptorCount(&internal));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        immutableBindingsAllocationRoundTrip,
        .{ &internal, @as([]const ImmutableSamplerBinding, &samplers) },
    );
    try std.testing.expectError(error.ImmutableSamplerBindingInvalid, descriptorBindings(
        std.testing.allocator,
        &internal,
        &.{},
    ));
    const duplicate = [_]ImmutableSamplerBinding{ samplers[0], samplers[0] };
    try std.testing.expectError(error.ImmutableSamplerBindingInvalid, descriptorBindings(
        std.testing.allocator,
        &internal,
        &duplicate,
    ));
    const null_sampler = [_]ImmutableSamplerBinding{.{ .binding = 0, .sampler = null }};
    try std.testing.expectError(error.ImmutableSamplerBindingInvalid, descriptorBindings(
        std.testing.allocator,
        &internal,
        &null_sampler,
    ));
    const unknown_sampler = [_]ImmutableSamplerBinding{.{
        .binding = 2,
        .sampler = samplers[0].sampler,
    }};
    try std.testing.expectError(error.ImmutableSamplerBindingInvalid, descriptorBindings(
        std.testing.allocator,
        &internal,
        &unknown_sampler,
    ));
}

fn immutableBindingsAllocationRoundTrip(
    allocator: std.mem.Allocator,
    internal: *const layout_internal.Layout,
    samplers: []const ImmutableSamplerBinding,
) !void {
    const bindings = try descriptorBindings(allocator, internal, samplers);
    defer freeDescriptorBindings(allocator, bindings);
    try std.testing.expect(bindings[0].pImmutableSamplers != null);
}

test "physical combined descriptor multiplication reports overflow" {
    const entry: layout_internal.Binding = .{
        .binding_number = 0,
        .visibility = .{ .fragment = true },
        .array_size = 2,
        .index_in_array = 0,
        .layout = .{ .static_sampler = .{
            .use = .single_texture_ycbcr,
            .sampled_texture_binding = null,
            .sampler_identity = 1,
            .combined_image_sampler_descriptor_count = std.math.maxInt(u32),
        } },
    };
    try std.testing.expectError(error.DescriptorCountOverflow, descriptorCountFor(entry));
}
