//! The Vulkan layout back end: a `VkDescriptorSetLayout` per bind group layout,
//! and a `VkPipelineLayout` per pipeline layout.
//!
//! **What this file is.** The port of `vulkan/BindGroupLayoutVk.{h,cpp}` and
//! `vulkan/PipelineLayoutVk.{h,cpp}` at Dawn
//! `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. Dawn keeps a map from a layout
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

    /// More push constant ranges than `max_push_constant_ranges`. Dawn
    /// declares one range and points the create info at it
    /// (`PipelineLayoutVk.cpp:98`-`:105`), so a port that reached this had a
    /// count the array was not sized for.
    TooManyPushConstantRanges,
};

/// The number of distinct `VkDescriptorType` values the port can produce. It
/// bounds `descriptorCountsPerType`'s scratch array; a type outside it is
/// refused there rather than indexing past the end.
pub const descriptor_type_count = 12;

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
            .storage, .read_only_storage => if (buffer.has_dynamic_offset)
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
    while (binding_index < stored_count) : (binding_index += 1) {
        const layout = internal.entries[binding_index].layout;
        if (!isMapped(layout)) continue;
        const type_index: usize = @intCast(descriptorTypeFor(layout));
        if (type_index >= descriptor_type_count) return error.UnmappedBindingType;
        counts[type_index] += 1;
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

/// Creates the `VkDescriptorSetLayout` for one packed layout.
/// `BindGroupLayout::Initialize` (`BindGroupLayoutVk.cpp:230`-`:257`) creates
/// the handle from the binding array `ComputeVulkanStaticBindings` produced.
///
/// The array is written in the packed layout's own order, so two equal layouts
/// produce the same array, which is what makes Dawn's cached handle comparable
/// at all. An entry with no Vulkan descriptor contributes no binding, so the
/// count is what was written and not the stored count.
pub fn createDescriptorSetLayout(
    allocator: std.mem.Allocator,
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    internal: *const layout_internal.Layout,
) Error!vulkan.VkDescriptorSetLayout {
    const stored_count: usize = internal.entries.len;
    const bindings = try allocator.alloc(vulkan.VkDescriptorSetLayoutBinding, stored_count);
    defer allocator.free(bindings);

    var written: usize = 0;
    var binding_index: usize = 0;
    while (binding_index < stored_count) : (binding_index += 1) {
        const stored_binding = internal.entries[binding_index];
        if (!isMapped(stored_binding.layout)) continue;
        // The Vulkan binding number is the packed index, and not the API
        // binding number `stored_binding.binding_number` carries
        // (`BindGroupLayoutVk.cpp:105`). `WriteDescriptorSet` is written
        // against the same packed index (`BindGroupVk.cpp:117`), so the two
        // cannot use different numbers for one binding.
        bindings[written] = .{
            .binding = @intCast(binding_index),
            .descriptorType = descriptorTypeFor(stored_binding.layout),
            .descriptorCount = 1,
            .stageFlags = stageFlagsFor(stored_binding.visibility),
        };
        written += 1;
    }

    const create_info: vulkan.VkDescriptorSetLayoutCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO),
        .bindingCount = @intCast(written),
        // An empty layout is legal; Vulkan refuses a null pointer with a
        // non-zero count, not the other way round.
        .pBindings = if (written == 0) null else bindings.ptr,
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
/// the refusal, because `AGENTS.md` §3.1 makes a missing proc a typed error
/// rather than a trap.
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
/// The refusal is typed for the same reason as
/// `destroyDescriptorSetLayout`'s: `AGENTS.md` §3.1.
pub fn destroyPipelineLayout(
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    pipeline_layout: vulkan.VkPipelineLayout,
) Error!void {
    const destroy_pipeline_layout = procs.destroy_pipeline_layout orelse
        return error.MissingDeviceProc;
    destroy_pipeline_layout(device, pipeline_layout, null);
}
