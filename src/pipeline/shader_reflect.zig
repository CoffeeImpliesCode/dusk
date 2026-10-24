//! What one entry point declares at which descriptor slot, in the shape a bind
//! group layout declares.
//!
//! Reflection is the port's own: Dawn reads it out of a
//! `tint::Program` (`ShaderModule.cpp:1314`, `:795`) and the port reads it out
//! of the SPIR-V binary `src/spirv` already read. The upstream record
//! (`ShaderModule.h:201` `ShaderBindingInfo`, `:204-205`
//! `BindingGroupInfoMap`/`BindingInfoArray`, and the `bindings` member of
//! `EntryPointMetadata` at `:277`) is a seven-way variant plus a hash map per
//! bind group, and the port collapses it to one flat slice because
//! `spirv.Resource` (`src/spirv/reflect.zig:46`) already names the kind.
//!
//! **What this file is not.** It is not the layout. M12 owns the object that
//! validates a layout, allocates a descriptor set and counts descriptors; this
//! file answers what the shader asks for, and the comparison between the two
//! is M14's `ValidateCompatibilityWithPipelineLayout`
//! (`ShaderModule.cpp:1576`, called at `Pipeline.cpp:135`).
//!
//! Canonical descriptor metadata comes from `spirv.reflect`. This file retains
//! every field and groups the descriptors without reading SPIR-V a second time.

const std = @import("std");
const spirv = @import("../spirv/root.zig");
const layout_internal = @import("layout_internal.zig");

const ErrorOrOutOfMemory = spirv.ErrorOrOutOfMemory;

/// What a bind group layout entry is called. The port takes M5's
/// enumeration rather than opening a new one: Dawn reaches the seven
/// alternatives of `ShaderBindingInfoVariant`
/// (`ShaderModule.h:188-194`) through a Tint type switch that begins at
/// `ShaderModule.cpp:75`.
pub const ResourceKind = spirv.ResourceKind;

/// The canonical descriptor record, also used by auto-layout consumers.
pub const Binding = spirv.Resource;

/// A native shader declaration disagrees with its canonical private binding.
pub const ShaderBindingError = error{ShaderBindingMismatch};

/// Checks combined and private native bindings against unchanged shader declarations.
/// Ordinary public separate bindings retain their existing validation path.
/// This does not acquire owners or replace feature and lifetime checks.
pub fn validateBinding(
    resource: Binding,
    layout_binding: layout_internal.Binding,
    stages: layout_internal.ShaderStages,
) ShaderBindingError!void {
    const combined_layout = switch (layout_binding.layout) {
        .static_sampler => |sampler| sampler.use == .single_texture_ycbcr,
        else => false,
    };
    const depth_view = switch (layout_binding.layout) {
        .sampled_texture => |texture| texture.depth_view,
        else => false,
    };
    const external_private = !layout_binding.isUserFacing();
    if (!resource.combined_image_sampler and !combined_layout and
        !depth_view and !external_private) return;
    if (resource.binding != layout_binding.binding_number or
        resource.array_size != layout_binding.array_size or
        layout_binding.index_in_array != 0) return error.ShaderBindingMismatch;
    if (stages.bits() == 0 or
        layout_binding.visibility.bits() & stages.bits() != stages.bits())
        return error.ShaderBindingMismatch;

    if (resource.combined_image_sampler or combined_layout) {
        if (!resource.combined_image_sampler or !combined_layout)
            return error.ShaderBindingMismatch;
        const sampler = layout_binding.layout.static_sampler;
        if (sampler.sampled_texture_binding != null or sampler.sampler_identity == 0 or
            sampler.combined_image_sampler_descriptor_count == 0)
            return error.ShaderBindingMismatch;
        if (resource.array_size != 1) return error.ShaderBindingMismatch;
        try validateSampledBinding(resource, .{
            .sample_type = .float_filterable,
            .view_dimension = .two_d,
            .multisampled = false,
        });
        return;
    }
    switch (layout_binding.layout) {
        .sampled_texture => |texture| try validateSampledBinding(resource, texture),
        .buffer => |buffer| {
            if (resource.kind != .uniform_buffer or buffer.binding_type != .uniform or
                resource.array_size != 1) return error.ShaderBindingMismatch;
        },
        .static_sampler, .sampler => {
            if (resource.kind != .sampler or resource.array_size != 1)
                return error.ShaderBindingMismatch;
        },
        else => return error.ShaderBindingMismatch,
    }
}

fn validateSampledBinding(
    resource: Binding,
    texture: layout_internal.SampledTextureBinding,
) ShaderBindingError!void {
    if (resource.kind != .sampled_texture or resource.image_sampled != 1 or
        resource.image_format != 0 or resource.image_multisampled != texture.multisampled)
        return error.ShaderBindingMismatch;
    const expected_dimension: spirv.Dim = switch (texture.view_dimension) {
        .one_d => .one_dimensional,
        .two_d, .two_d_array => .two_dimensional,
        .cube, .cube_array => .cube,
        .three_d => .three_dimensional,
    };
    const expected_arrayed = texture.view_dimension == .two_d_array or
        texture.view_dimension == .cube_array;
    if (resource.image_dimension != expected_dimension or
        resource.image_arrayed != expected_arrayed) return error.ShaderBindingMismatch;
    const scalar = resource.sampled_scalar orelse return error.ShaderBindingMismatch;
    if (texture.depth_view and
        (!texture.internal or texture.sample_type != .float_unfilterable))
        return error.ShaderBindingMismatch;
    switch (texture.sample_type) {
        .float_filterable, .float_unfilterable => {
            if (scalar != .float or scalar.float != 32 or resource.image_depth or
                resource.image_depth_mode != 0) return error.ShaderBindingMismatch;
        },
        .depth => {
            if (scalar != .float or scalar.float != 32 or !resource.image_depth or
                resource.image_depth_mode != 1) return error.ShaderBindingMismatch;
        },
        .sint => {
            if (scalar != .signed_integer or scalar.signed_integer != 32 or
                resource.image_depth_mode != 0) return error.ShaderBindingMismatch;
        },
        .uint => {
            if (scalar != .unsigned_integer or scalar.unsigned_integer != 32 or
                resource.image_depth_mode != 0) return error.ShaderBindingMismatch;
        },
    }
}

/// The descriptors at one set, as a window into `Layout.bindings`.
pub const GroupRange = struct {
    set: u32,
    /// Ordered by binding number. Empty when the shader declares no descriptor
    /// at `set`, which is why `findGroup` returns null rather than an empty
    /// window for a set the shader never mentions.
    bindings: []const Binding,
};

/// The whole reflected layout of one entry point.
///
/// One allocation holds every binding. Dawn keeps one hash map per bind group
/// (`ShaderModule.h:204-205`) because its keys are `BindingNumber` and its
/// entries are a `ShaderBindingInfo` by value; a sorted flat slice is enough
/// here and makes two runs of the reflector comparable with `std.mem.eql`.
pub const Layout = struct {
    allocator: std.mem.Allocator,

    /// Ordered by set and then by binding number, so `std.mem.eql` compares
    /// two layouts.
    bindings: []const Binding,

    pub fn deinit(self: Layout) void {
        self.allocator.free(self.bindings);
    }

    /// The descriptors at `set`, or null when the shader declares none there.
    /// The scan is bounded by the slice the reflector allocated, and a set
    /// number is not a bound: a module may declare any set it likes.
    pub fn findGroup(self: Layout, set: u32) ?GroupRange {
        const first = firstIndexOfSet(self.bindings, set) orelse return null;
        return .{ .set = set, .bindings = self.bindings[first..endIndexOfSet(self.bindings, first)] };
    }

    /// How many sets the shader declares a descriptor at. A module that
    /// declares nothing reports zero, which is the vertex fixture's shape.
    pub fn groupCount(self: Layout) usize {
        // Bound: the slice, walked once per binding.
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.bindings.len) : (index += endIndexOfSet(self.bindings, index)) {
            count += 1;
        }
        return count;
    }

    pub fn bindingCount(self: Layout) usize {
        return self.bindings.len;
    }
};

/// The layout `resources` describes.
///
/// `resources` is copied and sorted here rather than trusted to arrive in
/// order: the caller is `spirv.Module.entry_points`, which M5 already sorts
/// (`src/spirv/reflect.zig:177`), and this function is public.
pub fn layoutFromResources(
    allocator: std.mem.Allocator,
    resources: []const spirv.Resource,
) ErrorOrOutOfMemory!Layout {
    const bindings = try allocator.alloc(Binding, resources.len);
    @memcpy(bindings, resources);
    std.mem.sort(Binding, bindings, NoContext{}, lessBySetThenBinding);

    return .{ .allocator = allocator, .bindings = bindings };
}

/// Ports `ShaderModule.h:201` `ShaderBindingInfo`, whose `bindingInfo`
/// variant (`:188-194`) is the `kind` here.
pub fn bindingOf(layout: Layout, set: u32, binding: u32) ?Binding {
    const group = layout.findGroup(set) orelse return null;
    for (group.bindings) |candidate| {
        if (candidate.binding == binding) return candidate;
    }
    return null;
}

const NoContext = struct {};

fn lessBySetThenBinding(_: NoContext, left: Binding, right: Binding) bool {
    if (left.set != right.set) return left.set < right.set;
    return left.binding < right.binding;
}

/// The index of the first binding at `set`, or null when there is none.
fn firstIndexOfSet(bindings: []const Binding, set: u32) ?usize {
    // Bound: the slice.
    for (bindings, 0..) |binding, index| {
        if (binding.set == set) return index;
        if (binding.set > set) break;
    }
    return null;
}

/// One past the last binding at the set `first` names.
fn endIndexOfSet(bindings: []const Binding, first: usize) usize {
    // Bound: from `first` to the end of the slice.
    var index = first + 1;
    while (index < bindings.len and bindings[index].set == bindings[first].set) : (index += 1) {}
    return index;
}
