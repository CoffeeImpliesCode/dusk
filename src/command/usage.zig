//! Which resources a pass touches and how, so a back end can raise barriers
//! without re-deriving it.
//!
//! **What this file is.** The port of `src/dawn/native/PassResourceUsage.{h,cpp}`
//! and `src/dawn/native/PassResourceUsageTracker.{h,cpp}`. The encoders build
//! these while they record; a finished command buffer carries them, and M18
//! turns them into barriers.
//!
//! **What this file does not claim.** It does not claim Dawn's container
//! choices. Dawn reaches for `absl::flat_hash_map`
//! (`src/dawn/native/PassResourceUsageTracker.h:84-86`) and
//! `absl::flat_hash_set`, and marks a set hot twice
//! (`src/dawn/native/PassResourceUsage.h:94-95`, `:124-125`; and again at
//! `src/dawn/native/CommandEncoder.h:141-143`). The port uses ordered arrays
//! and a linear scan: a pass holds single-digit numbers of resources and of
//! bind groups, a linear scan is allocation-free and has no hash seed, and
//! "determinism is a feature" (`AGENTS.md` §3) is the reason the hash is not
//! there.
//!
//! It does not claim the WebGPU hazard-tracking rules are complete. Dawn's
//! `SyncScopeUsageTracker` merges usages per sync scope; the port does the
//! same merge and stops there, because the second half of the job — deciding
//! which merge produces a barrier — belongs to the back end.

const std = @import("std");
const commands = @import("commands.zig");
const core_errors = @import("../core/errors.zig");

/// How one buffer is used and by which stages
/// (`src/dawn/native/PassResourceUsage.h:54-57`). The two fields are the
/// `dawn.json` bitmask wire values.
pub const BufferSyncInfo = struct {
    usage: u32 = 0,
    shader_stages: u32 = 0,

    pub fn merge(left: *BufferSyncInfo, right: BufferSyncInfo) void {
        left.usage |= right.usage;
        left.shader_stages |= right.shader_stages;
    }
};

/// How one texture is used and by which stages
/// (`src/dawn/native/PassResourceUsage.h:59-64`).
pub const TextureSyncInfo = struct {
    usage: u32 = 0,
    shader_stages: u32 = 0,

    pub fn merge(left: *TextureSyncInfo, right: TextureSyncInfo) void {
        left.usage |= right.usage;
        left.shader_stages |= right.shader_stages;
    }
};

/// Texture usage inside a pass is tracked per subresource, so one field of the
/// struct below is the storage Dawn gets from
/// `SubresourceStorage<TextureSyncInfo>` (`PassResourceUsage.h:67-68`). A
/// subresource is a mip level, one array layer and one aspect
/// (`src/dawn/native/Subresource.h`).
pub const TextureSubresourceSyncInfo = struct {
    mip_level: u32 = 0,
    array_layer: u32 = 0,
    aspect: commands.TextureAspect = .undefined_,
    info: TextureSyncInfo = .{},

    pub fn subresourceMatches(
        self: TextureSubresourceSyncInfo,
        mip_level: u32,
        array_layer: u32,
        aspect: commands.TextureAspect,
    ) bool {
        return self.mip_level == mip_level and self.array_layer == array_layer and
            self.aspect == aspect;
    }
};

/// One synchronisation scope: everything a dispatch or a whole pass touches
/// (`PassResourceUsage.h:73-82`).
pub const SyncScopeResourceUsage = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayList(commands.Ref) = .empty,
    buffer_sync_infos: std.ArrayList(BufferSyncInfo) = .empty,
    textures: std.ArrayList(commands.Ref) = .empty,
    texture_sync_infos: std.ArrayList(TextureSubresourceSyncInfo) = .empty,
    external_textures: std.ArrayList(commands.Ref) = .empty,
    resource_table: commands.Ref = null,

    pub fn init(allocator: std.mem.Allocator) SyncScopeResourceUsage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SyncScopeResourceUsage) void {
        self.external_textures.deinit(self.allocator);
        self.texture_sync_infos.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.buffer_sync_infos.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Moves every list into `out` and empties this one. Dawn's
    /// `AcquireSyncScopeUsage` drains its own lists the same way
    /// (`PassResourceUsageTracker.cpp:234-264`), and the caller must not touch
    /// this scope afterwards.
    pub fn moveInto(self: *SyncScopeResourceUsage, out: *SyncScopeResourceUsage) void {
        out.buffers = self.buffers;
        out.buffer_sync_infos = self.buffer_sync_infos;
        out.textures = self.textures;
        out.texture_sync_infos = self.texture_sync_infos;
        out.external_textures = self.external_textures;
        out.resource_table = self.resource_table;
        self.* = .{ .allocator = self.allocator };
    }
};

/// Fills `out` with the distinct textures `scope` writes, in first-write
/// order. This is the port's shape of Dawn's `GatherWritableTextures`
/// (`PassResourceUsage.cpp:34-55`).
///
/// Dawn returns a hash set, which is unordered; the port fills a caller's list
/// because the barrier order is then a function of the record order alone and
/// two runs of the same stream produce the same barriers.
pub fn writableTexturesInto(
    allocator: std.mem.Allocator,
    scope: *const SyncScopeResourceUsage,
    out: *std.ArrayList(commands.Ref),
) std.mem.Allocator.Error!void {
    // The length is taken once and the slice is re-read each step, so the
    // `out.append` below cannot hand the loop a slice it is walking: `out` and
    // `scope.textures` are separate lists, and a caller that passed the same
    // list twice would still see each texture once because the bound is fixed
    // before the first append.
    const texture_count = scope.textures.items.len;
    var texture_index: usize = 0;
    while (texture_index < texture_count) : (texture_index += 1) {
        const texture = scope.textures.items[texture_index];
        var writable = false;
        for (scope.texture_sync_infos.items) |subresource| {
            if (subresource.info.usage & writable_texture_usage_bit != 0) writable = true;
            break;
        }
        if (!writable) continue;
        var seen = false;
        for (out.items) |existing| {
            if (existing == texture) seen = true;
        }
        if (seen) continue;
        try out.append(allocator, texture);
    }
}

/// The one `TextureUsage` bit that means "this pass writes the subresource".
/// `dawn.json` "texture usage" puts it after the five read bits, so a store
/// attachment or a resolve target sets it.
const writable_texture_usage_bit: u32 = 1 << 7;

/// Every resource usage a compute pass carries (`PassResourceUsage.h:90-100`).
pub const ComputePassResourceUsage = struct {
    allocator: std.mem.Allocator,
    /// One entry per dispatch, because the specification makes every dispatch
    /// its own synchronisation scope.
    dispatch_usages: std.ArrayList(SyncScopeResourceUsage) = .empty,
    /// Resources a bind group names but no dispatch reads. Dawn keeps four hash
    /// sets for them because `Queue::Submit` validates them anyway
    /// (`PassResourceUsage.h:93-99`).
    referenced_buffers: std.ArrayList(commands.Ref) = .empty,
    referenced_textures: std.ArrayList(commands.Ref) = .empty,
    referenced_external_textures: std.ArrayList(commands.Ref) = .empty,
    referenced_resource_tables: std.ArrayList(commands.Ref) = .empty,

    pub fn init(allocator: std.mem.Allocator) ComputePassResourceUsage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ComputePassResourceUsage) void {
        for (self.dispatch_usages.items) |*scope| scope.deinit();
        self.dispatch_usages.deinit(self.allocator);
        self.referenced_resource_tables.deinit(self.allocator);
        self.referenced_external_textures.deinit(self.allocator);
        self.referenced_textures.deinit(self.allocator);
        self.referenced_buffers.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Every resource usage a render pass carries (`PassResourceUsage.h:107-112`).
///
/// The scope fields are inlined rather than inherited: Zig has no struct
/// inheritance, and Dawn's `RenderPassResourceUsage : SyncScopeResourceUsage`
/// exists only so a bundle can hand one scope to a pass's list
/// (`PassResourceUsage.h:107`, `:114`). The port's tracker merges the two field
/// sets directly.
pub const RenderPassResourceUsage = struct {
    scope: SyncScopeResourceUsage,
    allocator: std.mem.Allocator,
    query_sets: std.ArrayList(commands.Ref) = .empty,
    /// One entry per query set: whether each of its queries is available.
    query_availabilities: std.ArrayList(std.ArrayList(bool)) = .empty,
    uses_framebuffer_fetch: bool = false,

    pub fn init(allocator: std.mem.Allocator) RenderPassResourceUsage {
        return .{
            .scope = SyncScopeResourceUsage.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderPassResourceUsage) void {
        for (self.query_availabilities.items) |*availability| {
            availability.deinit(self.allocator);
        }
        self.query_availabilities.deinit(self.allocator);
        self.query_sets.deinit(self.allocator);
        self.scope.deinit();
        self.* = undefined;
    }
};

/// The usage tree a finished command buffer carries
/// (`PassResourceUsage.h:119-129`).
pub const CommandBufferResourceUsage = struct {
    allocator: std.mem.Allocator,
    render_passes: std.ArrayList(RenderPassResourceUsage) = .empty,
    compute_passes: std.ArrayList(ComputePassResourceUsage) = .empty,
    top_level_buffers: std.ArrayList(commands.Ref) = .empty,
    top_level_textures: std.ArrayList(commands.Ref) = .empty,
    used_query_sets: std.ArrayList(commands.Ref) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandBufferResourceUsage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandBufferResourceUsage) void {
        for (self.render_passes.items) |*usage| usage.deinit();
        self.render_passes.deinit(self.allocator);
        for (self.compute_passes.items) |*usage| usage.deinit();
        self.compute_passes.deinit(self.allocator);
        self.top_level_textures.deinit(self.allocator);
        self.top_level_buffers.deinit(self.allocator);
        self.used_query_sets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addRenderPass(self: *CommandBufferResourceUsage) std.mem.Allocator.Error!void {
        try self.render_passes.append(self.allocator, RenderPassResourceUsage.init(self.allocator));
    }

    pub fn addComputePass(self: *CommandBufferResourceUsage) std.mem.Allocator.Error!void {
        try self.compute_passes.append(self.allocator, ComputePassResourceUsage.init(self.allocator));
    }
};

/// The sync-scope half of a tracker (`PassResourceUsageTracker.h:51-89`).
///
/// It is embedded by the two pass trackers rather than inherited: Dawn inherits
/// it (`PassResourceUsageTracker.h:112`), and the port's answer to that is a
/// field.
pub const SyncScopeUsageTracker = struct {
    allocator: std.mem.Allocator,
    scope: SyncScopeResourceUsage,

    pub fn init(allocator: std.mem.Allocator) SyncScopeUsageTracker {
        return .{ .allocator = allocator, .scope = SyncScopeResourceUsage.init(allocator) };
    }

    pub fn deinit(self: *SyncScopeUsageTracker) void {
        self.scope.deinit();
        self.* = undefined;
    }

    /// Dawn's `BufferUsedAs` (`PassResourceUsageTracker.cpp:52-61`): find the
    /// buffer's entry, or add one. Returning the index is what lets the caller
    /// merge into it without a second search.
    pub fn bufferUsedAs(self: *SyncScopeUsageTracker, buffer: commands.Ref, usage: u32) std.mem.Allocator.Error!usize {
        for (self.scope.buffers.items, 0..) |existing, index| {
            if (existing == buffer) {
                self.scope.buffer_sync_infos.items[index].usage |= usage;
                return index;
            }
        }
        try self.scope.buffers.append(self.allocator, buffer);
        try self.scope.buffer_sync_infos.append(self.allocator, .{ .usage = usage });
        return self.scope.buffers.items.len - 1;
    }

    /// Dawn's `TextureViewUsedAs` (`PassResourceUsageTracker.cpp:63-67`): a
    /// view names its texture and is used across every subresource the view
    /// spans, so the port records one entry per subresource the caller gives.
    pub fn textureRangeUsedAs(
        self: *SyncScopeUsageTracker,
        texture: commands.Ref,
        mip_level: u32,
        array_layer: u32,
        aspect: commands.TextureAspect,
        info: TextureSyncInfo,
    ) std.mem.Allocator.Error!void {
        if (texture == null) return;
        var known = false;
        for (self.scope.textures.items) |existing| {
            if (existing == texture) known = true;
        }
        if (!known) try self.scope.textures.append(self.allocator, texture);
        for (self.scope.texture_sync_infos.items) |*entry| {
            if (entry.subresourceMatches(mip_level, array_layer, aspect)) {
                entry.info.merge(info);
                return;
            }
        }
        try self.scope.texture_sync_infos.append(self.allocator, .{
            .mip_level = mip_level,
            .array_layer = array_layer,
            .aspect = aspect,
            .info = info,
        });
    }

    /// Dawn's `MergeTextureUsage` (`PassResourceUsageTracker.cpp:88-105`).
    pub fn mergeTextureUsage(
        self: *SyncScopeUsageTracker,
        mip_level: u32,
        array_layer: u32,
        aspect: commands.TextureAspect,
        info: TextureSyncInfo,
    ) std.mem.Allocator.Error!void {
        for (self.scope.texture_sync_infos.items) |*entry| {
            if (entry.subresourceMatches(mip_level, array_layer, aspect)) {
                entry.info.merge(info);
                return;
            }
        }
        try self.scope.texture_sync_infos.append(self.allocator, .{
            .mip_level = mip_level,
            .array_layer = array_layer,
            .aspect = aspect,
            .info = info,
        });
    }

    /// Dawn's `SetUsedResourceTable` (`PassResourceUsageTracker.cpp:229-232`).
    pub fn setUsedResourceTable(self: *SyncScopeUsageTracker, table: commands.Ref) void {
        self.scope.resource_table = table;
    }

    /// Dawn's `AcquireSyncScopeUsage` (`PassResourceUsageTracker.cpp:234-264`):
    /// move the lists out and start empty. The port has no second copy of the
    /// scope, because a value type that copies six lists is worse than one that
    /// empties itself.
    pub fn acquireSyncScopeUsage(self: *SyncScopeUsageTracker) SyncScopeResourceUsage {
        var out = SyncScopeResourceUsage.init(self.allocator);
        self.scope.moveInto(&out);
        return out;
    }
};

/// Dawn's `ComputePassResourceUsageTracker` (`PassResourceUsageTracker.h:92-110`).
pub const ComputePassResourceUsageTracker = struct {
    allocator: std.mem.Allocator,
    usage: ComputePassResourceUsage,

    pub fn init(allocator: std.mem.Allocator) ComputePassResourceUsageTracker {
        return .{ .allocator = allocator, .usage = ComputePassResourceUsage.init(allocator) };
    }

    pub fn deinit(self: *ComputePassResourceUsageTracker) void {
        self.usage.deinit();
        self.* = undefined;
    }

    /// Dawn's `AddDispatch` (`PassResourceUsageTracker.cpp:276-278`): every
    /// dispatch is its own scope, so the list grows by one.
    pub fn addDispatch(
        self: *ComputePassResourceUsageTracker,
        scope: SyncScopeResourceUsage,
    ) std.mem.Allocator.Error!void {
        try self.usage.dispatch_usages.append(self.allocator, scope);
    }

    /// Dawn's `AddReferencedBuffer` (`PassResourceUsageTracker.cpp:280-282`)
    /// and its three siblings. The sets are sets: a resource named twice is
    /// named once.
    pub fn addReferencedBuffer(
        self: *ComputePassResourceUsageTracker,
        buffer: commands.Ref,
    ) std.mem.Allocator.Error!void {
        try appendUnique(self.allocator, &self.usage.referenced_buffers, buffer);
    }

    pub fn addReferencedTexture(
        self: *ComputePassResourceUsageTracker,
        texture: commands.Ref,
    ) std.mem.Allocator.Error!void {
        try appendUnique(self.allocator, &self.usage.referenced_textures, texture);
    }

    pub fn addReferencedExternalTexture(
        self: *ComputePassResourceUsageTracker,
        texture: commands.Ref,
    ) std.mem.Allocator.Error!void {
        try appendUnique(self.allocator, &self.usage.referenced_external_textures, texture);
    }

    pub fn addReferencedResourceTable(
        self: *ComputePassResourceUsageTracker,
        table: commands.Ref,
    ) std.mem.Allocator.Error!void {
        try appendUnique(self.allocator, &self.usage.referenced_resource_tables, table);
    }

    /// Dawn's `AcquireResourceUsage` (`PassResourceUsageTracker.cpp:311-313`).
    pub fn acquireResourceUsage(self: *ComputePassResourceUsageTracker) ComputePassResourceUsage {
        var out = ComputePassResourceUsage.init(self.allocator);
        out.dispatch_usages = self.usage.dispatch_usages;
        self.usage.dispatch_usages = .empty;
        return out;
    }
};

/// Dawn's `RenderPassResourceUsageTracker` (`PassResourceUsageTracker.h:112-136`).
/// Dawn hides the inherited `AcquireSyncScopeUsage` so the only public drain is
/// `AcquireResourceUsage` (`PassResourceUsageTracker.h:130`); the port does the
/// same by not exposing the field.
pub const RenderPassResourceUsageTracker = struct {
    allocator: std.mem.Allocator,
    sync_scope: SyncScopeUsageTracker,
    usage: RenderPassResourceUsage,

    pub fn init(allocator: std.mem.Allocator) RenderPassResourceUsageTracker {
        return .{
            .allocator = allocator,
            .sync_scope = SyncScopeUsageTracker.init(allocator),
            .usage = RenderPassResourceUsage.init(allocator),
        };
    }

    pub fn deinit(self: *RenderPassResourceUsageTracker) void {
        self.sync_scope.deinit();
        self.usage.deinit();
        self.* = undefined;
    }

    pub fn bufferUsedAs(
        self: *RenderPassResourceUsageTracker,
        buffer: commands.Ref,
        usage: u32,
    ) std.mem.Allocator.Error!usize {
        return self.sync_scope.bufferUsedAs(buffer, usage);
    }

    pub fn textureRangeUsedAs(
        self: *RenderPassResourceUsageTracker,
        texture: commands.Ref,
        mip_level: u32,
        array_layer: u32,
        aspect: commands.TextureAspect,
        info: TextureSyncInfo,
    ) std.mem.Allocator.Error!void {
        return self.sync_scope.textureRangeUsedAs(texture, mip_level, array_layer, aspect, info);
    }

    pub fn mergeTextureUsage(
        self: *RenderPassResourceUsageTracker,
        mip_level: u32,
        array_layer: u32,
        aspect: commands.TextureAspect,
        info: TextureSyncInfo,
    ) std.mem.Allocator.Error!void {
        return self.sync_scope.mergeTextureUsage(mip_level, array_layer, aspect, info);
    }

    pub fn setUsedResourceTable(self: *RenderPassResourceUsageTracker, table: commands.Ref) void {
        self.sync_scope.setUsedResourceTable(table);
    }

    /// Dawn's `MarkFramebufferFetchUsed` (`PassResourceUsageTracker.cpp:325-327`).
    pub fn markFramebufferFetchUsed(self: *RenderPassResourceUsageTracker) void {
        self.usage.uses_framebuffer_fetch = true;
    }

    /// Dawn's `AddBindGroup` (`PassResourceUsageTracker.cpp:124-227`). The port
    /// takes the four binding kinds already resolved, because the caller is the
    /// one that knows what a bind group holds — `command` cannot read it.
    pub fn addBindGroupResources(
        self: *RenderPassResourceUsageTracker,
        options: BindGroupResources,
    ) std.mem.Allocator.Error!void {
        for (options.buffers) |entry| {
            _ = try self.bufferUsedAs(entry.buffer, entry.usage);
        }
        for (options.textures) |entry| {
            try self.textureRangeUsedAs(
                entry.texture,
                entry.mip_level,
                entry.array_layer,
                entry.aspect,
                .{ .usage = entry.usage, .shader_stages = entry.shader_stages },
            );
        }
        for (options.external_textures) |texture| {
            _ = texture;
        }
        if (options.resource_table != null) self.sync_scope.setUsedResourceTable(options.resource_table);
    }

    /// Dawn's `TrackQueryAvailability` (`PassResourceUsageTracker.cpp:348-358`)
    /// and `GetQueryAvailabilityMap` (`:360-362`). Dawn records one bit per
    /// query; the port records one `bool` per query, which is the same
    /// information at eight times the size and is only correct because a pass
    /// holds at most `Limits` queries. The port's own budget note is that
    /// `Limits` bounds this list, not the pass's draw count.
    ///
    /// The declared set names the two sets the body draws on and nothing
    /// more. The bound reports `LimitExceeded`, which is a member of
    /// `core.ValidationError` (`core/errors.zig:29`), and the three appends
    /// fail with `std.mem.Allocator.Error`; `core.Error` would swallow the
    /// device-lost members the body cannot return.
    pub fn trackQueryAvailability(
        self: *RenderPassResourceUsageTracker,
        query_set: commands.Ref,
        query_count: u32,
    ) (core_errors.ValidationError || std.mem.Allocator.Error)!void {
        if (query_count > max_tracked_query_count) return error.LimitExceeded;
        var existing: ?*std.ArrayList(bool) = null;
        for (self.usage.query_sets.items, 0..) |set, index| {
            if (set == query_set) existing = &self.usage.query_availabilities.items[index];
        }
        if (existing == null) {
            try self.usage.query_sets.append(self.allocator, query_set);
            try self.usage.query_availabilities.append(self.allocator, .empty);
            existing = &self.usage.query_availabilities.items[self.usage.query_availabilities.items.len - 1];
        }
        var target = existing.?;
        while (target.items.len < query_count) {
            try target.append(self.allocator, false);
        }
    }

    pub fn markQueryAvailable(self: *RenderPassResourceUsageTracker, query_set: commands.Ref, index: u32) void {
        for (self.usage.query_sets.items, 0..) |set, set_index| {
            if (set != query_set) continue;
            const availability = self.usage.query_availabilities.items[set_index];
            if (index >= availability.items.len) return;
            self.usage.query_availabilities.items[set_index].items[index] = true;
        }
    }

    /// Dawn's `AcquireResourceUsage` (`PassResourceUsageTracker.cpp:329-346`):
    /// move every list into a fresh usage. Dawn copies `usesFramebufferFetch`
    /// (`:343`) and leaves its own flag set; the port replaces the struct, so
    /// the flag clears.
    pub fn acquireResourceUsage(self: *RenderPassResourceUsageTracker) RenderPassResourceUsage {
        var out = RenderPassResourceUsage.init(self.allocator);
        self.sync_scope.scope.moveInto(&out.scope);
        out.query_sets = self.usage.query_sets;
        out.query_availabilities = self.usage.query_availabilities;
        out.uses_framebuffer_fetch = self.usage.uses_framebuffer_fetch;
        // The two query lists moved into `out`, so the source empties them
        // before its own `deinit`. That call then releases the old scope and
        // two empty arrays, and touches nothing `out` now owns.
        self.usage.query_sets = .empty;
        self.usage.query_availabilities = .empty;
        self.usage.deinit();
        self.usage = RenderPassResourceUsage.init(self.allocator);
        return out;
    }
};

/// One buffer binding of a bind group, as the caller resolved it. Dawn reads
/// these back out of the group (`PassResourceUsageTracker.cpp:124-227`).
pub const BindGroupBuffer = struct {
    buffer: commands.Ref,
    usage: u32,
};

/// One texture binding of a bind group, as the caller resolved it.
pub const BindGroupTexture = struct {
    texture: commands.Ref,
    mip_level: u32,
    array_layer: u32,
    aspect: commands.TextureAspect,
    usage: u32,
    shader_stages: u32,
};

/// The four binding kinds of one bind group, as the caller resolved them. The
/// element types are named, not inline, because `setBindGroup` carries the
/// same two lists before the record reaches a tracker: one type, one name,
/// both callers (`programmable_encoder.SetBindGroupOptions` and
/// `addBindGroupResources`).
pub const BindGroupResources = struct {
    buffers: []const BindGroupBuffer = &.{},
    textures: []const BindGroupTexture = &.{},
    external_textures: []const commands.Ref = &.{},
    resource_table: commands.Ref = null,
};

/// The largest query set the port tracks a per-query availability for. Dawn's
/// `kMaxQueryCount` is 4096 (`src/dawn/common/Constants.h:94`); the port's bound
/// is the one below because a `bool` per query costs a byte and the limit is a
/// device limit, not a spec constant.
pub const max_tracked_query_count: u32 = 4096;

fn appendUnique(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(commands.Ref),
    value: commands.Ref,
) std.mem.Allocator.Error!void {
    for (list.items) |existing| {
        if (existing == value) return;
    }
    try list.append(allocator, value);
}
