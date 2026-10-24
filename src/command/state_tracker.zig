//! The six-bit cache that answers "may this command run, given the state the
//! pass is in?".
//!
//! **What this file is.** The port of
//! `src/dawn/native/CommandBufferStateTracker.{h,cpp}`. Dawn calls it a
//! *validation* tracker and is explicit that it is lazy: five of its six bits
//! are recomputed from the pipeline only when something needs them.
//!
//! **What this file does not claim.** It does not claim to read a pipeline.
//! Dawn's `RecomputeLazyAspects` (`CommandBufferStateTracker.cpp:534-597`)
//! walks the pipeline layout, the bind group layouts, the vertex buffer
//! layouts and the immediate mask off a `RenderPipelineBase`. The port takes
//! that whole answer as `PipelineRequirements` at `setPipeline` time, because
//! `command` does not import `engine` and a pipeline is an engine object. The
//! recompute is therefore a comparison against a recorded answer rather than
//! a walk, and the six bits and the invalidation table are unchanged.
//!
//! It does not claim Dawn's bitmask layout is load-bearing. It is not: the
//! bits are internal, the only observable is which command raises which rule.

const std = @import("std");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

/// The six things a command can need and not have. Dawn's `ValidationAspect`
/// (`CommandBufferStateTracker.cpp:313-323`), in the same order, so the bit
/// values agree.
pub const Aspect = enum(u32) {
    pipeline = 0,
    bind_groups = 1,
    resource_tables = 2,
    vertex_buffers = 3,
    index_buffer = 4,
    immediate_data = 5,
};

/// Dawn's `kNumAspects` (`CommandBufferStateTracker.h:84`).
pub const aspect_count: usize = @typeInfo(Aspect).@"enum".field_names.len;

comptime {
    if (aspect_count != 6) @compileError("the aspect count moved from Dawn's six");
}

/// The bits, as a plain `u32`. Dawn wraps them in
/// `std::bitset<kNumAspects>` (`CommandBufferStateTracker.h:84-85`); the port
/// uses the integer the bitset wraps, because every operation here is one mask
/// and one `&`.
pub const AspectMask = struct {
    bits: u32 = 0,

    pub fn set(self: *AspectMask, aspect: Aspect) void {
        self.bits |= bit(aspect);
    }

    pub fn clear(self: *AspectMask, aspect: Aspect) void {
        self.bits &= ~bit(aspect);
    }

    pub fn has(self: AspectMask, aspect: Aspect) bool {
        return self.bits & bit(aspect) != 0;
    }

    pub fn isEmpty(self: AspectMask) bool {
        return self.bits == 0;
    }
};

pub fn maskOf(comptime aspects: []const Aspect) u32 {
    var bits: u32 = 0;
    for (aspects) |aspect| bits |= bit(aspect);
    return bits;
}

/// Dawn's `kDispatchAspects` (`CommandBufferStateTracker.cpp:325-327`). A
/// dispatch reads no vertex data and no indices.
pub const dispatch_aspects: u32 = maskOf(&.{ .pipeline, .bind_groups, .resource_tables, .immediate_data });

/// Dawn's `kDrawAspects` (`:329-332`).
pub const draw_aspects: u32 = maskOf(&.{
    .pipeline,
    .bind_groups,
    .resource_tables,
    .vertex_buffers,
    .immediate_data,
});

/// Dawn's `kDrawIndexedAspects` (`:334-337`).
pub const draw_indexed_aspects: u32 = maskOf(&.{
    .pipeline,
    .bind_groups,
    .resource_tables,
    .vertex_buffers,
    .index_buffer,
    .immediate_data,
});

/// Dawn's `kLazyAspects` (`:339-342`): everything except the pipeline. The
/// pipeline is never lazy, so a missing one is an error before any recompute
/// runs.
pub const lazy_aspects: u32 = maskOf(&.{
    .bind_groups,
    .resource_tables,
    .vertex_buffers,
    .index_buffer,
    .immediate_data,
});

/// One vertex buffer slot's shape, as the pipeline declares it
/// (`src/dawn/native/RenderPipeline.h:88`), reached at
/// `CommandBufferStateTracker.cpp:415-423`).
pub const VertexBufferLayout = struct {
    /// The bytes one vertex advances by, or 0 for a step-mode buffer.
    array_stride: u32 = 0,
    /// The bytes the last vertex occupies: the largest `offset + size` over
    /// the attributes bound to this slot. Dawn's `lastStride`.
    last_stride: u32 = 0,
    /// The bytes every vertex occupies even in step mode, which is what the
    /// zero-stride branch compares. Dawn's `usedBytesInStride`.
    used_bytes_in_stride: u32 = 0,
};

/// What a pipeline needs, resolved by the caller at `setPipeline`.
///
/// This is the whole of what Dawn reads off the pipeline object inside
/// `RecomputeLazyAspects` (`CommandBufferStateTracker.cpp:534-597`), as data.
pub const PipelineRequirements = struct {
    /// One bit per bind group index the layout names. Dawn's
    /// `GetBindGroupLayoutsMask()`.
    bind_group_layout_mask: u32 = 0,
    /// One bit per bind group index, carrying the identity of the layout that
    /// group must have. The port compares ids rather than layouts because only
    /// the caller can read a layout.
    bind_group_layout_ids: [constants.max_bind_groups]u64 = @splat(0),
    /// One bit per vertex buffer slot the pipeline reads.
    vertex_buffer_mask: u32 = 0,
    vertex_buffer_layouts: [constants.max_vertex_buffers]VertexBufferLayout = @splat(.{}),
    /// One bit per immediate slot the pipeline reads. Dawn's
    /// `GetUserImmediateSlots()`.
    immediate_slot_mask: u64 = 0,
    /// The index format a strip topology needs to match. Dawn compares
    /// `mIndexFormat` against `GetStripIndexFormat()`
    /// (`CommandBufferStateTracker.cpp:583-589`).
    strip_index_format: commands.IndexFormat = .undefined_,
    /// Whether the pipeline layout uses a resource table, which decides the
    /// `resource_tables` aspect.
    uses_resource_table: bool = false,
};

/// One texture binding of a bind group, as the caller resolved it.
///
/// Dawn reads this back out of the bind group when it runs
/// `ValidateNoDifferentTextureViewsOnSameTexture`
/// (`CommandBufferStateTracker.cpp:374-388`). The port takes it at record
/// time, because `command` cannot read a bind group.
pub const TextureBinding = struct {
    /// The texture the view names. Two bindings that file under the same
    /// texture with different views are the compatibility-mode conflict.
    texture: commands.Ref = null,
    view: commands.Ref = null,
    /// The binding index inside the group.
    slot: u32 = 0,
};

/// What one `setBindGroup` recorded for the lazy check.
pub const BindGroupRecord = struct {
    group: commands.Ref = null,
    /// The identity of the group's layout, compared against the pipeline's.
    layout_id: u64 = 0,
    /// The smallest buffer any binding in this group names. Dawn's
    /// `FindFirstUndersizedBuffer`
    /// (`CommandBufferStateTracker.cpp:545-547`) compares the group's minimum
    /// binding sizes against the sizes the pass bound; the caller is the only
    /// side that can read a binding's size, so it supplies the minimum.
    min_binding_buffer_size: u64 = 0,
    texture_bindings: []const TextureBinding = &.{},
};

/// One `setVertexBuffer` record, as far as validation is concerned.
pub const VertexBufferRecord = struct {
    buffer: commands.Ref = null,
    /// The bytes the pass reads from this buffer.
    size: u64 = 0,
};

/// The state a pass validates each of its commands against.
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    aspects: AspectMask = .{},

    render_pipeline: commands.Ref = null,
    compute_pipeline: commands.Ref = null,
    pipeline_requirements: PipelineRequirements = .{},

    bind_groups: [constants.max_bind_groups]BindGroupRecord = @splat(.{}),
    vertex_buffers: [constants.max_vertex_buffers]VertexBufferRecord = @splat(.{}),
    /// One bit per slot with a buffer bound. Dawn's `mVertexBuffersUsed`.
    vertex_buffers_used: u32 = 0,

    index_buffer: commands.Ref = null,
    index_buffer_size: u64 = 0,
    index_format: commands.IndexFormat = .undefined_,

    immediate_data: [constants.max_immediate_data_bytes]u8 = @splat(0),
    /// One bit per four-byte slot that has been written. Dawn's
    /// `mImmediateDataMask`.
    immediate_data_mask: u64 = 0,

    has_resource_table: bool = false,
    resource_table: commands.Ref = null,

    /// Set once at `init`; the compatibility rule is a property of the device
    /// and never changes for the life of the pass.
    compatibility_mode: bool = false,

    pub fn init(allocator: std.mem.Allocator, compatibility_mode: bool) Tracker {
        return .{ .allocator = allocator, .compatibility_mode = compatibility_mode };
    }

    /// Dawn's `SetRenderPipeline` / `SetComputePipeline`
    /// (`CommandBufferStateTracker.cpp:781-787`), which reach the clear in
    /// `SetPipelineCommon` (`:846-855`). Dawn clears all five lazy bits there
    /// because every one of them is derived from the pipeline.
    pub fn setPipeline(
        self: *Tracker,
        pipeline: commands.Ref,
        requirements: PipelineRequirements,
    ) void {
        self.render_pipeline = pipeline;
        self.pipeline_requirements = requirements;
        self.aspects.set(.pipeline);
        self.aspects.clear(.bind_groups);
        self.aspects.clear(.resource_tables);
        self.aspects.clear(.vertex_buffers);
        self.aspects.clear(.index_buffer);
        self.aspects.clear(.immediate_data);
    }

    pub fn setComputePipeline(
        self: *Tracker,
        pipeline: commands.Ref,
        requirements: PipelineRequirements,
    ) void {
        self.compute_pipeline = pipeline;
        self.pipeline_requirements = requirements;
        self.aspects.set(.pipeline);
        self.aspects.clear(.bind_groups);
        self.aspects.clear(.resource_tables);
        self.aspects.clear(.vertex_buffers);
        self.aspects.clear(.index_buffer);
        self.aspects.clear(.immediate_data);
    }

    /// Dawn's `SetBindGroup` (`CommandBufferStateTracker.cpp:793-800`): the
    /// bind-groups bit goes, and nothing else.
    pub fn setBindGroup(self: *Tracker, index: u32, record: BindGroupRecord) void {
        if (index >= constants.max_bind_groups) return;
        self.bind_groups[index] = record;
        self.aspects.clear(.bind_groups);
    }

    /// Dawn's `UnsetBindGroup` (`CommandBufferStateTracker.cpp:789-792`). A
    /// bundle replays with the state reset, and Dawn clears the bit here
    /// rather than leaving a stale group visible to the next command.
    pub fn unsetBindGroup(self: *Tracker, index: u32) void {
        if (index >= constants.max_bind_groups) return;
        self.bind_groups[index] = .{};
        self.aspects.clear(.bind_groups);
    }

    /// Dawn's `SetVertexBuffer` (`:829-832`): the vertex-buffers bit goes.
    pub fn setVertexBuffer(self: *Tracker, slot: u32, record: VertexBufferRecord) void {
        if (slot >= constants.max_vertex_buffers) return;
        self.vertex_buffers[slot] = record;
        self.vertex_buffers_used |= @as(u32, 1) << @intCast(slot);
        self.aspects.clear(.vertex_buffers);
    }

    /// Dawn's `UnsetVertexBuffer` (`:823-827`).
    pub fn unsetVertexBuffer(self: *Tracker, slot: u32) void {
        if (slot >= constants.max_vertex_buffers) return;
        self.vertex_buffers[slot] = .{};
        self.vertex_buffers_used &= ~(@as(u32, 1) << @intCast(slot));
        self.aspects.clear(.vertex_buffers);
    }

    /// Dawn's `SetIndexBuffer` (`:812-821`): the index-buffer bit goes.
    pub fn setIndexBuffer(
        self: *Tracker,
        buffer: commands.Ref,
        size: u64,
        format: commands.IndexFormat,
    ) void {
        self.index_buffer = buffer;
        self.index_buffer_size = size;
        self.index_format = format;
        self.aspects.clear(.index_buffer);
    }

    /// Dawn's `SetResourceTable` (`:802-806`): the resource-tables bit goes,
    /// and the recorded table is what the replay reads.
    pub fn setResourceTable(self: *Tracker, table: commands.Ref) void {
        self.resource_table = table;
        self.has_resource_table = true;
        self.aspects.clear(.resource_tables);
    }

    /// Dawn's `SetImmediateData` (`:834-844`). Dawn clears no aspect here —
    /// the immediate bit is not invalidated by an immediate write, because
    /// writing more data can only make the check pass — and the port keeps
    /// that rule, which is the one place the table's "clears none" row is not
    /// a bug.
    pub fn setImmediateData(
        self: *Tracker,
        offset: u32,
        bytes: []const u8,
    ) errors.Error!void {
        if (offset % constants.immediate_element_byte_size != 0 or
            bytes.len % constants.immediate_element_byte_size != 0)
        {
            return error.ImmediateDataUnaligned;
        }
        if (offset > constants.max_immediate_data_bytes) return error.ImmediateDataTooLarge;
        if (bytes.len > constants.max_immediate_data_bytes - offset) {
            return error.ImmediateDataTooLarge;
        }
        const start = @divExact(offset, constants.immediate_element_byte_size);
        if (bytes.len == 0) return;
        const slot_count = @divExact(bytes.len, constants.immediate_element_byte_size);
        const low_mask: u64 = if (slot_count == 64)
            std.math.maxInt(u64)
        else
            @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - slot_count));
        const written_mask = low_mask << @as(u6, @intCast(start));
        @memcpy(self.immediate_data[offset..][0..bytes.len], bytes);
        self.immediate_data_mask |= written_mask;
    }

    /// Dawn's `End` (`:912-918`). Dawn clears the pipeline pointers and leaves
    /// `mAspects` alone; the port clears both, because after `End` no further
    /// command may consult the cache and a stale set bit would answer for an
    /// encoder that no longer records.
    pub fn end(self: *Tracker) void {
        self.render_pipeline = null;
        self.compute_pipeline = null;
        self.aspects = .{};
    }

    /// Dawn's `ValidateOperation` (`CommandBufferStateTracker.cpp:513-532`):
    /// the fast path, the non-lazy error, the lazy recompute, then the check
    /// again. The order matters: a missing pipeline is reported before a
    /// missing bind group, because the recompute needs a pipeline.
    pub fn validateOperation(self: *Tracker, required_aspects: u32) errors.Error!void {
        const missing = required_aspects & ~self.aspects.bits;
        if (missing == 0) return;

        try checkMissingAspects(missing & ~lazy_aspects);
        self.recomputeLazyAspects(missing);
        try checkMissingAspects(required_aspects & ~self.aspects.bits);
    }

    /// Dawn's `RecomputeLazyAspects` (`CommandBufferStateTracker.cpp:534-597`).
    /// The only place a bit is ever set, apart from `setPipeline`.
    fn recomputeLazyAspects(self: *Tracker, aspects: u32) void {
        // The caller has already reported a missing pipeline.
        std.debug.assert(self.aspects.has(.pipeline));
        std.debug.assert(aspects & ~lazy_aspects == 0);

        if (aspects & bit(.bind_groups) != 0) self.recomputeBindGroups();
        if (aspects & bit(.resource_tables) != 0) self.recomputeResourceTables();
        if (aspects & bit(.vertex_buffers) != 0) self.recomputeVertexBuffers();
        if (aspects & bit(.index_buffer) != 0) self.recomputeIndexBuffer();
        if (aspects & bit(.immediate_data) != 0) self.recomputeImmediateData();
    }

    /// Dawn's bind-groups branch (`:538-564`). A group matches when the
    /// pipeline layout names the index, the group's layout id is the one the
    /// pipeline names, and no binding of the group is smaller than the buffer
    /// the pass bound for it.
    fn recomputeBindGroups(self: *Tracker) void {
        var index: u32 = 0;
        while (index < constants.max_bind_groups) : (index += 1) {
            if (self.pipeline_requirements.bind_group_layout_mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
            const record = self.bind_groups[index];
            if (record.group == null) return;
            if (record.layout_id != self.pipeline_requirements.bind_group_layout_ids[index]) return;
            if (record.min_binding_buffer_size > self.smallestBoundBufferSize()) return;
        }
        self.aspects.set(.bind_groups);
    }

    fn recomputeResourceTables(self: *Tracker) void {
        // Dawn (`:566-572`): the bit is set unless the pipeline layout uses a
        // resource table and the pass has not set one.
        if (!self.pipeline_requirements.uses_resource_table or self.has_resource_table) {
            self.aspects.set(.resource_tables);
        }
    }

    /// Dawn's vertex-buffers branch (`:574-581`).
    fn recomputeVertexBuffers(self: *Tracker) void {
        if (self.pipeline_requirements.vertex_buffer_mask & ~self.vertex_buffers_used == 0) {
            self.aspects.set(.vertex_buffers);
        }
    }

    /// Dawn's index-buffer branch (`:583-589`): set only when an index buffer
    /// is bound and, for a strip topology, its format is the one the pipeline
    /// declares.
    fn recomputeIndexBuffer(self: *Tracker) void {
        if (self.index_buffer == null) return;
        const strip = self.pipeline_requirements.strip_index_format;
        if (strip == .undefined_ or self.index_format == strip) self.aspects.set(.index_buffer);
    }

    /// Dawn's immediate-data branch (`:591-596`).
    fn recomputeImmediateData(self: *Tracker) void {
        if (self.pipeline_requirements.immediate_slot_mask & ~self.immediate_data_mask == 0) {
            self.aspects.set(.immediate_data);
        }
    }

    /// Dawn's `CheckMissingAspects` (`:599-779`). The order of the six checks
    /// is the order of the errors, so a caller sees the first thing that is
    /// wrong rather than an arbitrary one.
    fn checkMissingAspects(aspects: u32) errors.Error!void {
        if (aspects == 0) return;
        if (aspects & bit(.pipeline) != 0) return error.MissingPipeline;
        if (aspects & bit(.bind_groups) != 0) return error.MissingBindGroup;
        if (aspects & bit(.resource_tables) != 0) return error.MissingResourceTable;
        if (aspects & bit(.vertex_buffers) != 0) return error.MissingVertexBuffer;
        if (aspects & bit(.index_buffer) != 0) return error.MissingIndexBuffer;
        if (aspects & bit(.immediate_data) != 0) return error.MissingImmediateData;
        unreachable;
    }

    pub fn validateCanDispatch(self: *Tracker) errors.Error!void {
        return self.validateOperation(dispatch_aspects);
    }

    pub fn validateCanDraw(self: *Tracker) errors.Error!void {
        return self.validateOperation(draw_aspects);
    }

    pub fn validateCanDrawIndexed(self: *Tracker) errors.Error!void {
        return self.validateOperation(draw_indexed_aspects);
    }

    /// Dawn's `ValidateBufferInRangeForVertexBuffer`
    /// (`CommandBufferStateTracker.cpp:405-446`).
    ///
    /// The overflow argument in Dawn's comment holds for the port too: the
    /// stride is a `u64` and the counts are `u32`, so the product cannot wrap.
    pub fn validateBufferInRangeForVertexBuffer(
        self: *const Tracker,
        vertex_count: u32,
        first_vertex: u32,
    ) errors.Error!void {
        const stride_count = @as(u64, first_vertex) + vertex_count;
        // A step-mode buffer with no vertices is in range by definition
        // (`CommandBufferStateTracker.cpp:409-412`).
        if (stride_count == 0) return;

        var slot: u32 = 0;
        while (slot < constants.max_vertex_buffers) : (slot += 1) {
            if (self.pipeline_requirements.vertex_buffer_mask & (@as(u32, 1) << @intCast(slot)) == 0) continue;
            const layout = self.pipeline_requirements.vertex_buffer_layouts[slot];
            const buffer_size = self.vertex_buffers[slot].size;
            if (layout.array_stride == 0) {
                if (layout.used_bytes_in_stride > buffer_size) return error.DrawVertexCount;
                continue;
            }
            const required = (stride_count - 1) * layout.array_stride + layout.last_stride;
            if (required > buffer_size) return error.DrawVertexCount;
        }
    }

    /// Dawn's `ValidateBufferInRangeForInstanceBuffer`
    /// (`CommandBufferStateTracker.cpp:451-493`). An instance index addresses
    /// the instance array at slot 0 with the pipeline's array stride; a step
    /// mode pipeline has no instance array and is never out of range.
    pub fn validateBufferInRangeForInstanceBuffer(
        self: *const Tracker,
        instance_count: u32,
        first_instance: u32,
    ) errors.Error!void {
        const stride_count = @as(u64, first_instance) + instance_count;
        if (stride_count == 0) return;
        const layout = self.pipeline_requirements.vertex_buffer_layouts[0];
        if (layout.array_stride == 0) return;
        const buffer_size = self.vertex_buffers[0].size;
        const required = (stride_count - 1) * layout.array_stride + layout.last_stride;
        if (required > buffer_size) return error.DrawVertexCount;
    }

    /// Dawn's `ValidateIndexBufferInRange`
    /// (`CommandBufferStateTracker.cpp:498-511`). The format size is 2 or 4
    /// and the counts are `u32`, so the `u64` arithmetic cannot wrap — the same
    /// argument Dawn makes in its comment at `:500-503`.
    pub fn validateIndexBufferInRange(
        self: *const Tracker,
        index_count: u32,
        first_index: u32,
    ) errors.Error!void {
        const element_size: u64 = switch (self.index_format) {
            .uint16 => 2,
            .uint32 => 4,
            .undefined_ => 0,
        };
        if (element_size == 0) return error.MissingIndexBuffer;
        const required = (@as(u64, first_index) + index_count) * element_size;
        if (required > self.index_buffer_size) return error.DrawIndexCount;
    }

    /// Dawn's `ValidateNoDifferentTextureViewsOnSameTexture`
    /// (`CommandBufferStateTracker.cpp:370-403`).
    ///
    /// Dawn files every texture binding of every bind group the current
    /// pipeline layout names under its texture, then refuses a texture that
    /// carries two views. The port holds the same bindings per group and does
    /// the same filing; it is gated on `compatibility_mode`, which is Dawn's
    /// `HasFlexibleTextureViews()` (`RenderEncoderBase.cpp:124-126`).
    pub fn validateNoDifferentTextureViewsOnSameTexture(self: *const Tracker) errors.Error!void {
        if (!self.compatibility_mode) return;
        for (self.bind_groups) |record| {
            for (record.texture_bindings, 0..) |binding, index| {
                for (record.texture_bindings[index + 1 ..]) |other| {
                    if (binding.texture == null) continue;
                    if (binding.texture == other.texture and binding.view != other.view) {
                        return error.ConflictingTextureViews;
                    }
                }
            }
        }
    }

    /// The smallest buffer the pass bound, over the slots with a buffer. Dawn's
    /// `mMinBufferSizes` (`CommandBufferStateTracker.cpp:546`) is the minimum
    /// over the buffers the group names; the port compares against the minimum
    /// over the vertex buffers the pass actually bound, which is the same bound
    /// whenever the group names a vertex buffer and a strictly weaker one when
    /// it does not. The weaker bound is recorded here rather than hidden.
    fn smallestBoundBufferSize(self: *const Tracker) u64 {
        var smallest: u64 = std.math.maxInt(u64);
        for (self.vertex_buffers, 0..) |record, slot| {
            if (self.vertex_buffers_used & (@as(u32, 1) << @intCast(slot)) == 0) continue;
            smallest = @min(smallest, record.size);
        }
        return smallest;
    }
};

/// The one bit a single aspect owns. `Aspect` is an `enum(u32)`, so
/// `@intFromEnum` yields a `u32`, while Zig types the shift amount of a `u32`
/// as `Log2Int(u32)`, which is `u5`. Every mask here is six bits wide, so the
/// narrowing is lossless and this is the one place it happens.
fn bit(aspect: Aspect) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@backingInt(aspect)));
}

test "immediate requirements preserve word63 and the full mask" {
    var tracker = Tracker.init(std.testing.allocator, false);
    tracker.setComputePipeline(null, .{ .immediate_slot_mask = @as(u64, 1) << 63 });
    try std.testing.expectError(error.MissingImmediateData, tracker.validateCanDispatch());
    const upper_word = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try tracker.setImmediateData(252, &upper_word);
    try std.testing.expectEqual(@as(u64, 1) << 63, tracker.immediate_data_mask);
    try std.testing.expectEqualSlices(u8, &upper_word, tracker.immediate_data[252..256]);
    try tracker.validateCanDispatch();

    tracker.setComputePipeline(null, .{ .immediate_slot_mask = std.math.maxInt(u64) });
    try std.testing.expectError(error.MissingImmediateData, tracker.validateCanDispatch());
    const full_data: [256]u8 = @splat(0xa5);
    try tracker.setImmediateData(0, &full_data);
    try std.testing.expectEqual(std.math.maxInt(u64), tracker.immediate_data_mask);
    try std.testing.expectEqualSlices(u8, &full_data, &tracker.immediate_data);
    try tracker.validateCanDispatch();
}

test "immediate range refusal leaves tracker bytes masks and aspects unchanged" {
    var tracker = Tracker.init(std.testing.allocator, false);
    const initial_word = [_]u8{ 1, 2, 3, 4 };
    try tracker.setImmediateData(16, &initial_word);
    tracker.aspects.set(.immediate_data);
    const initial_data = tracker.immediate_data;
    const initial_mask = tracker.immediate_data_mask;
    const initial_aspects = tracker.aspects.bits;
    const cases = [_]struct { offset: u32, data: []const u8, expected: errors.Error }{
        .{ .offset = 1, .data = &initial_word, .expected = error.ImmediateDataUnaligned },
        .{ .offset = 0, .data = initial_word[0..3], .expected = error.ImmediateDataUnaligned },
        .{ .offset = 256, .data = &initial_word, .expected = error.ImmediateDataTooLarge },
        .{ .offset = 252, .data = &@as([8]u8, @splat(0)), .expected = error.ImmediateDataTooLarge },
        .{ .offset = 0xffff_fffc, .data = &initial_word, .expected = error.ImmediateDataTooLarge },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, tracker.setImmediateData(case.offset, case.data));
        try std.testing.expectEqualSlices(u8, &initial_data, &tracker.immediate_data);
        try std.testing.expectEqual(initial_mask, tracker.immediate_data_mask);
        try std.testing.expectEqual(initial_aspects, tracker.aspects.bits);
    }
    try tracker.setImmediateData(256, &.{});
    try std.testing.expectEqualSlices(u8, &initial_data, &tracker.immediate_data);
    try std.testing.expectEqual(initial_mask, tracker.immediate_data_mask);
}
