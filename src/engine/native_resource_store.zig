//! Per-device weak semantic indices. The original object guard serializes misses.
//! Initialize at the stable NativeDeviceContext address before any factory use.
const std = @import("std");
const core = @import("../core/root.zig");
const native = @import("native_resources.zig");
const sampler = @import("sampler.zig");
const layout = @import("../pipeline/layout_internal.zig");
const tokens = @import("../pipeline/bind_group_layout.zig");
const attachments = @import("../command/attachment_state.zig");
const WeakIndex = @import("native_weak_index.zig").WeakIndex;

pub const ResourceStore = struct {
    objects: *core.ObjectList,
    bind_group_layouts: WeakIndex(native.BindGroupLayout),
    pipeline_layouts: WeakIndex(native.PipelineLayout),
    shader_modules: WeakIndex(native.ShaderModule),
    samplers: WeakIndex(sampler.Sampler),
    attachments: WeakIndex(attachments.CanonicalAttachmentState),
    compatibility_tokens: tokens.TokenCounter = .{},

    pub fn init(allocator: std.mem.Allocator, objects: *core.ObjectList) ResourceStore {
        return .{
            .objects = objects,
            .bind_group_layouts = WeakIndex(native.BindGroupLayout).init(allocator, objects),
            .pipeline_layouts = WeakIndex(native.PipelineLayout).init(allocator, objects),
            .shader_modules = WeakIndex(native.ShaderModule).init(allocator, objects),
            .samplers = WeakIndex(sampler.Sampler).init(allocator, objects),
            .attachments = WeakIndex(attachments.CanonicalAttachmentState).init(allocator, objects),
        };
    }

    pub fn deinit(self: *ResourceStore, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.objects);
        self.bind_group_layouts.deinit(guard);
        self.pipeline_layouts.deinit(guard);
        self.shader_modules.deinit(guard);
        self.samplers.deinit(guard);
        self.attachments.deinit(guard);
        self.* = undefined;
    }

    pub fn mintCompatibilityToken(
        self: *ResourceStore,
        guard: *const core.ObjectGuard,
    ) tokens.TokenCounter.MintError!u64 {
        guard.assertOwns(self.objects);
        return self.compatibility_tokens.mint();
    }
};

pub fn shaderHash(words: []const u32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words));
}
pub fn shaderMatches(object: *const native.ShaderModule, words: []const u32) bool {
    return std.mem.eql(u32, object.words, words);
}

pub const BindGroupLayoutQuery = struct {
    internal: *const layout.Layout,
    compatibility_token: u64,
};
pub fn bindGroupLayoutHash(query: BindGroupLayoutQuery) u64 {
    var hash = std.hash.Wyhash.init(query.internal.content_hash);
    hash.update(std.mem.asBytes(&query.compatibility_token));
    return hash.final();
}
pub fn bindGroupLayoutMatches(
    object: *const native.BindGroupLayout,
    query: BindGroupLayoutQuery,
) bool {
    if (object.compatibility_token != query.compatibility_token) return false;
    if (!layout.Layout.eql(&object.internal, query.internal)) return false;
    if (!std.meta.eql(object.internal.validation_counts, query.internal.validation_counts)) return false;
    if (object.internal.unverified_buffer_count != query.internal.unverified_buffer_count) return false;
    return object.internal.dynamic_storage_buffer_count == query.internal.dynamic_storage_buffer_count;
}

pub const PipelineLayoutQuery = struct {
    groups: []const *native.BindGroupLayout,
    immediate_size: u32,
    compatibility_token: u64,
};
pub fn pipelineLayoutHash(query: PipelineLayoutQuery) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&query.immediate_size));
    hash.update(std.mem.asBytes(&query.compatibility_token));
    const count: u64 = @intCast(query.groups.len);
    hash.update(std.mem.asBytes(&count));
    for (query.groups) |group| {
        const identity = @intFromPtr(&group.header);
        hash.update(std.mem.asBytes(&identity));
    }
    return hash.final();
}
pub fn pipelineLayoutMatches(object: *const native.PipelineLayout, query: PipelineLayoutQuery) bool {
    if (object.native.immediate_size != query.immediate_size) return false;
    if (object.native.compatibility_token != query.compatibility_token) return false;
    if (object.groups.len != query.groups.len) return false;
    for (object.groups, query.groups) |existing, requested| {
        if (existing != requested) return false;
    }
    return true;
}
pub fn samplerMatches(object: *const sampler.Sampler, key: sampler.SemanticKey) bool {
    return object.key.eql(key);
}

pub fn attachmentMatches(
    object: *const attachments.CanonicalAttachmentState,
    value: attachments.AttachmentState,
) bool {
    return attachments.AttachmentState.eql(&object.value, &value);
}
