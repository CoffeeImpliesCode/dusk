//! What one entry point declares at which descriptor slot, in the shape a bind
//! group layout declares.
//!
//! `AGENTS.md` §3.2 makes reflection the port's own: Dawn reads it out of a
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
//! **What this file does not claim.** It does not claim to check a shader
//! against a layout, and it does not claim that a reflection result is
//! complete. It reads what `spirv.reflect` found, which for the committed
//! fixtures is the whole of what they declare
//! (`test/fixtures/triangle.frag.wgsl` declares one uniform buffer and nothing
//! else).

const std = @import("std");
const spirv = @import("../spirv/root.zig");

const ErrorOrOutOfMemory = spirv.ErrorOrOutOfMemory;

/// What a bind group layout entry is called. The port takes M5's
/// enumeration rather than opening a new one: Dawn reaches the seven
/// alternatives of `ShaderBindingInfoVariant`
/// (`ShaderModule.h:188-194`) through a Tint type switch that begins at
/// `ShaderModule.cpp:75`.
pub const ResourceKind = spirv.ResourceKind;

/// One descriptor the shader declares.
pub const Binding = struct {
    set: u32,
    binding: u32,
    kind: spirv.ResourceKind,
};

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
    for (bindings, resources) |*binding, resource| {
        binding.* = .{
            .set = resource.set,
            .binding = resource.binding,
            .kind = resource.kind,
        };
    }
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
