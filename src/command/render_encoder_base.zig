//! The render half of a pass encoder: pipelines, vertex and index buffers, and
//! the six draw forms.
//!
//! **What this file is.** The port of
//! `src/dawn/native/RenderEncoderBase.{h,cpp}`. It holds the state tracker, the
//! resource-usage tracker, the indirect-draw metadata and the draw count
//! (`RenderEncoderBase.h:105-109`), and records the twelve commands Dawn's
//! `APIDraw` family and the three setters record
//! (`RenderEncoderBase.cpp:105-706`).
//!
//! **What this file does not claim.** It does not claim to resolve
//! `kWholeSize` the way Dawn does. Dawn resolves the "whole buffer" case inside
//! the record lambda, twice — once with validation on (`RenderEncoderBase.cpp:671-672`)
//! and once without (`:682-684`) — and the port's options carry `size: ?u64`,
//! where null is the whole remaining buffer. One resolution point beats two, and
//! a recorded `size` is always concrete, which is what Dawn's comment on those
//! lines is asking for.
//!
//! A pass encoder is a single-owner value. Its usage owns one real core
//! attachment lease, and the parent context must outlive the open pass.

const std = @import("std");
const core = @import("../core/root.zig");
const attachment = @import("attachment_state.zig");
const render_bundle = @import("render_bundle.zig");
const api = @import("../api/bitmask.zig");
const allocator_mod = @import("allocator.zig");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const indirect_draw = @import("indirect_draw.zig");
const programmable_encoder = @import("programmable_encoder.zig");
const state_tracker = @import("state_tracker.zig");
const query = @import("query.zig");
const usage = @import("usage.zig");
const validation_utils = @import("validation_utils.zig");

/// The four counts of a non-indexed draw
/// (`src/api/objects.zig:768-773`, `RenderPassEncoder.DrawVertexCountOptions`).
/// This is the name the M15 acceptance criterion quotes, so the port keeps it
/// rather than a name of its own.
pub const DrawVertexCountOptions = struct {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

/// The four counts of an indexed draw (`src/api/objects.zig:778-783`).
pub const DrawIndexedIndexCountOptions = struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    first_instance: u32,
};

/// The two numbers an indirect draw names. `indirect_buffer_size` is the whole
/// buffer, recorded so the undersized check needs no engine.
pub const DrawIndirectOptions = struct {
    indirect_buffer: commands.Ref,
    indirect_buffer_size: u64,
    indirect_offset: u64,
};

/// The five numbers a multi-draw indirect names
/// (`src/api/objects.zig:794-797`, `MultiDrawIndirectIndirectOffsetOptions` plus
/// the draw-count pair).
pub const MultiDrawIndirectOptions = struct {
    indirect_buffer: commands.Ref,
    indirect_buffer_size: u64,
    indirect_offset: u64,
    max_draw_count: u32,
    draw_count_buffer: commands.Ref = null,
    draw_count_buffer_size: u64 = 0,
    draw_count_offset: u64 = 0,
};

/// A vertex buffer binding. `size: null` is the whole buffer from `offset`.
pub const SetVertexBufferOptions = struct {
    slot: u32,
    buffer: commands.Ref,
    buffer_size: u64,
    offset: u64 = 0,
    size: ?u64 = null,
};

/// An index buffer binding. `size: null` is the whole buffer from `offset`.
pub const SetIndexBufferOptions = struct {
    buffer: commands.Ref,
    buffer_size: u64,
    format: commands.IndexFormat,
    offset: u64 = 0,
    size: ?u64 = null,
};

/// A pipeline binding, plus everything the lazy validation needs from it.
pub const SetRenderPipelineOptions = struct {
    pipeline: commands.Ref,
    requirements: state_tracker.PipelineRequirements,
    attachment_state: *attachment.CanonicalAttachmentState,
};

pub const WriteTimestampOptions = struct {
    query_set: commands.Ref,
    query_index: u32,
    query_count: u32,
    query_type: query.QueryType = .timestamp,
    timestamp_query_enabled: bool = false,
};

/// What a render pass encoder holds besides its `ProgrammableEncoder`.
pub const RenderEncoderBase = struct {
    programmable: programmable_encoder.ProgrammableEncoder,
    tracker: state_tracker.Tracker,
    usage: usage.RenderPassResourceUsageTracker,
    indirect: indirect_draw.IndirectDrawMetadata,
    selected_index_offset: u64 = 0,
    allocator: std.mem.Allocator,

    draw_count: u64 = 0,
    max_draw_count: u64 = constants.default_max_draw_count,
    compatibility_mode: bool = false,
    width: u32 = std.math.maxInt(u32),
    height: u32 = std.math.maxInt(u32),
    occlusion_query_set: commands.Ref = null,
    occlusion_state: query.OcclusionQueryState = .{
        .attached = false,
        .query_count = 0,
        .active = false,
        .index = 0,
    },
    timestamp_query_enabled: bool = false,
    deinitialized: bool = false,

    /// Takes the prepared tracker by move. The caller must not clean up its copy.
    pub fn initOwned(
        allocator: std.mem.Allocator,
        context: *encoding_context.Context,
        compatibility_mode: bool,
        prepared_usage: usage.RenderPassResourceUsageTracker,
    ) RenderEncoderBase {
        std.debug.assert(prepared_usage.usage.attachment_state != null);
        std.debug.assert(
            prepared_usage.usage.attachment_state.?.header.tracking == context.device.objects,
        );
        return .{
            .programmable = programmable_encoder.ProgrammableEncoder.init(allocator, context),
            .tracker = state_tracker.Tracker.init(allocator, compatibility_mode),
            .usage = prepared_usage,
            .indirect = indirect_draw.IndirectDrawMetadata.init(allocator),
            .allocator = allocator,
            .compatibility_mode = compatibility_mode,
        };
    }

    pub fn attachmentState(self: *const RenderEncoderBase) *attachment.CanonicalAttachmentState {
        std.debug.assert(!self.deinitialized);
        return self.usage.usage.attachment_state.?;
    }

    /// Invalidate abandoned commands before their borrowed attachment loses its lease.
    pub fn deinit(self: *RenderEncoderBase, io: std.Io, guard: *const core.ObjectGuard) void {
        if (self.deinitialized) return;
        const context = self.programmable.context;
        guard.assertOwns(context.device.objects);
        if (context.status == .open and context.current_id == self.programmable.id) {
            context.status = .error_in_recording;
            context.current_id = encoding_context.no_encoder;
        }
        self.usage.deinit(io, guard);
        self.indirect.deinit();
        self.* = undefined;
        self.deinitialized = true;
    }

    /// End validates both the programmable state and the active occlusion
    /// query before committing the pass body.
    ///
    /// This is the pass encoder's only exit: it hands both lists the pass owns
    /// to the context and then releases the pass. A caller can keep its normal
    /// deferred `deinit`: the cleanup marker survives payload poisoning.
    ///
    /// One set covers the body: `errors.Error` is `core.Error ||
    /// CommandValidationError || std.mem.Allocator.Error` (`errors.zig:211`) and
    /// `AllocatorError` is the last two of those (`allocator.zig:234`).
    pub fn end(
        self: *RenderEncoderBase,
        io: std.Io,
        guard: *const core.ObjectGuard,
    ) errors.Error!void {
        if (self.deinitialized) return error.PassEnded;
        const context = self.programmable.context;
        if (guard.objects != context.device.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(context.device.objects);
        defer self.deinit(io, guard);
        errdefer {
            context.status = .error_in_recording;
            context.current_id = encoding_context.no_encoder;
        }
        try self.validateAttachment(guard, self.attachmentState());

        try self.programmable.validateProgrammableEncoderEnd();
        try self.occlusion_state.end();
        if (self.draw_count > self.max_draw_count) return error.DrawCountExceeded;
        try self.usage.sync_scope.scope.validateIndirectReadonly();

        const encoder = self.programmable.id;
        _ = try context.encode(commands.EndRenderPassCmd, encoder, .end_render_pass);

        // `exitRenderPass` appends the usage and then the metadata
        // (`encoding_context.zig:267-271`) before its last fallible step, so
        // both lists are reserved here: after this there is no point at which
        // the context holds one of them and the pass holds the other.
        try context.render_pass_usages.ensureUnusedCapacity(context.allocator, 1);
        try context.indirect_draws.ensureUnusedCapacity(context.allocator, 1);
        try context.exitRenderPass(
            io,
            guard,
            encoder,
            self.usage.acquireResourceUsage(),
            self.acquireIndirectDraws(),
        );
        self.tracker.end();
    }

    /// The indirect-draw metadata, moved out with the pass's copy left empty.
    /// Dawn's `std::move(mIndirectDrawMetadata)` (`RenderPassEncoder.cpp:187`):
    /// the context frees what it is handed, so the pass must not keep a second
    /// owner of the same lists.
    fn acquireIndirectDraws(self: *RenderEncoderBase) indirect_draw.IndirectDrawMetadata {
        const moved = self.indirect;
        self.indirect = indirect_draw.IndirectDrawMetadata.init(self.allocator);
        return moved;
    }

    /// Dawn has no `ValidateSetVertexBuffer`: the slot rule is the
    /// `slot >= kMaxVertexBuffers` check inside `RenderEncoderBase::APISetVertexBuffer`
    /// (`RenderEncoderBase.cpp:649-651`) and the range rule below is its
    /// `offset > bufferSize` check (`RenderEncoderBase.cpp:665-667`).
    pub fn validateSetVertexBuffer(options: SetVertexBufferOptions) errors.Error!void {
        if (options.slot >= constants.max_vertex_buffers) return error.VertexBufferSlotOutOfRange;
        if (options.buffer != null and options.buffer_size < options.offset) return error.DrawVertexCount;
    }

    /// Dawn's `APISetVertexBuffer` (`RenderEncoderBase.cpp:641-706`).
    pub fn setVertexBuffer(
        self: *RenderEncoderBase,
        options: SetVertexBufferOptions,
    ) errors.Error!void {
        try RenderEncoderBase.validateSetVertexBuffer(options);
        const bound = options.size orelse (options.buffer_size - options.offset);
        const cmd = try self.programmable.context.encode(
            commands.SetVertexBufferCmd,
            self.programmable.id,
            .set_vertex_buffer,
        );
        cmd.* = .{
            .slot = options.slot,
            .buffer = options.buffer,
            .buffer_size = options.buffer_size,
            .offset = options.offset,
            .size = bound,
        };
        self.tracker.setVertexBuffer(options.slot, .{ .buffer = options.buffer, .size = bound });
        _ = try self.usage.bufferUsedAs(options.buffer, (api.BufferUsage{ .vertex = true }).toFlags());
    }

    /// Dawn's `APISetIndexBuffer` (`RenderEncoderBase.cpp:581-640`).
    pub fn setIndexBuffer(
        self: *RenderEncoderBase,
        options: SetIndexBufferOptions,
    ) errors.Error!void {
        const element_size: u64 = switch (options.format) {
            .uint16 => 2,
            .uint32 => 4,
            .undefined_ => return error.MissingIndexBuffer,
        };
        if (options.offset > options.buffer_size) return error.DrawIndexCount;
        const bound = options.size orelse (options.buffer_size - options.offset);
        if (bound > options.buffer_size - options.offset or
            options.offset % element_size != 0 or bound % element_size != 0)
        {
            return error.DrawIndexCount;
        }
        const cmd = try self.programmable.context.encode(
            commands.SetIndexBufferCmd,
            self.programmable.id,
            .set_index_buffer,
        );
        cmd.* = .{
            .buffer = options.buffer,
            .buffer_size = options.buffer_size,
            .format = options.format,
            .offset = options.offset,
            .size = bound,
        };
        self.tracker.setIndexBuffer(options.buffer, bound, options.format);
        self.selected_index_offset = options.offset;
        _ = try self.usage.bufferUsedAs(options.buffer, (api.BufferUsage{ .index = true }).toFlags());
    }

    /// Dawn's `APISetPipeline` (`RenderEncoderBase.cpp:544-579`), whose
    /// attachment-state comparison is the rule the port fuses into one check
    /// (`RenderEncoderBase.cpp:551-556`).
    pub fn setPipeline(
        self: *RenderEncoderBase,
        guard: *const core.ObjectGuard,
        options: SetRenderPipelineOptions,
    ) errors.Error!void {
        if (self.deinitialized) return error.PassEnded;
        try self.programmable.context.validateCanEncodeOn(self.programmable.id, false);
        const pass_state = self.attachmentState();
        try self.validateAttachment(guard, pass_state);
        const pipeline_state = options.attachment_state;
        try self.validateAttachment(guard, pipeline_state);
        if (pass_state != pipeline_state) {
            if (pass_state.value.sample_count != pipeline_state.value.sample_count) {
                return error.AttachmentSampleCountMismatch;
            }
            return error.AttachmentFormatMismatch;
        }
        const cmd = try self.programmable.context.encode(
            commands.SetRenderPipelineCmd,
            self.programmable.id,
            .set_render_pipeline,
        );
        cmd.* = .{ .pipeline = options.pipeline, .attachment_state = pipeline_state };
        self.tracker.setPipeline(options.pipeline, options.requirements);
    }

    fn validateAttachment(
        self: *const RenderEncoderBase,
        guard: *const core.ObjectGuard,
        state: *const attachment.CanonicalAttachmentState,
    ) errors.Error!void {
        if (guard.objects != self.programmable.context.device.objects) {
            return error.ResourceDeviceMismatch;
        }
        guard.assertOwns(guard.objects);
        if (state.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        if (state.header.kind != .attachment_state) return error.HandleKindMismatch;
        if (!state.header.node.linked or state.header.state != .alive) {
            return error.ResourceDestroyed;
        }
    }

    pub fn setBindGroup(
        self: *RenderEncoderBase,
        options: programmable_encoder.SetBindGroupOptions,
    ) errors.Error!void {
        return self.programmable.setBindGroup(&self.tracker, .{ .render = &self.usage }, options);
    }

    pub fn setImmediates(
        self: *RenderEncoderBase,
        options: programmable_encoder.SetImmediatesOptions,
    ) errors.Error!void {
        return self.programmable.setImmediates(&self.tracker, options);
    }

    pub fn pushDebugGroup(self: *RenderEncoderBase, label: []const u8) errors.Error!void {
        return self.programmable.pushDebugGroup(label);
    }

    pub fn popDebugGroup(self: *RenderEncoderBase) errors.Error!void {
        return self.programmable.popDebugGroup();
    }

    pub fn insertDebugMarker(self: *RenderEncoderBase, label: []const u8) errors.Error!void {
        return self.programmable.insertDebugMarker(label);
    }

    pub fn setViewport(
        self: *RenderEncoderBase,
        viewport: commands.SetViewportCmd,
    ) errors.Error!void {
        try validation_utils.validateViewport(viewport);
        if (viewport.x < 0 or viewport.y < 0 or viewport.width < 0 or viewport.height < 0) {
            return error.InvalidViewport;
        }
        if (viewport.x + viewport.width > @as(f32, @floatFromInt(self.width)) or
            viewport.y + viewport.height > @as(f32, @floatFromInt(self.height)) or
            viewport.min_depth < 0 or viewport.max_depth > 1 or
            viewport.min_depth > viewport.max_depth)
        {
            return error.InvalidViewport;
        }
        const cmd = try self.programmable.context.encode(
            commands.SetViewportCmd,
            self.programmable.id,
            .set_viewport,
        );
        cmd.* = viewport;
    }

    pub fn setScissorRect(
        self: *RenderEncoderBase,
        rect: commands.SetScissorRectCmd,
    ) errors.Error!void {
        if (rect.x > self.width or rect.y > self.height) return error.InvalidScissorRect;
        if (rect.width > self.width - rect.x or rect.height > self.height - rect.y) {
            return error.InvalidScissorRect;
        }
        const cmd = try self.programmable.context.encode(
            commands.SetScissorRectCmd,
            self.programmable.id,
            .set_scissor_rect,
        );
        cmd.* = rect;
    }

    pub fn setBlendConstant(self: *RenderEncoderBase, color: commands.Color) errors.Error!void {
        try validation_utils.validateColor(color);
        const cmd = try self.programmable.context.encode(
            commands.SetBlendConstantCmd,
            self.programmable.id,
            .set_blend_constant,
        );
        cmd.* = .{ .color = color };
    }

    pub fn setStencilReference(self: *RenderEncoderBase, reference: u32) errors.Error!void {
        const cmd = try self.programmable.context.encode(
            commands.SetStencilReferenceCmd,
            self.programmable.id,
            .set_stencil_reference,
        );
        cmd.* = .{ .reference = reference };
    }

    pub fn executeBundles(
        self: *RenderEncoderBase,
        guard: *const core.ObjectGuard,
        bundles: []const *const render_bundle.RenderBundle,
    ) errors.Error!void {
        if (self.deinitialized) return error.PassEnded;
        const context = self.programmable.context;
        try context.validateCanEncodeOn(self.programmable.id, false);
        try self.validateAttachment(guard, self.attachmentState());
        if (bundles.len > std.math.maxInt(u32)) return error.LimitExceeded;
        var draw_count = self.draw_count;
        var validation: BundleValidation = .{};
        for (bundles) |bundle| {
            try self.validateBundleBody(guard, bundle, &validation);
            draw_count = std.math.add(u64, draw_count, bundle.draw_count) catch
                return error.DrawCountExceeded;
        }
        if (draw_count > self.max_draw_count) return error.DrawCountExceeded;
        // A failed metadata merge cannot leave a recordable half-merged pass.
        errdefer {
            context.status = .error_in_recording;
            context.current_id = encoding_context.no_encoder;
        }
        for (bundles) |bundle| {
            try self.mergeBundleUsage(&bundle.resource_usage);
            if (bundle.indirect.draws.items.len >
                indirect_draw.max_draw_count - self.indirect.next_draw_index)
            {
                return error.LimitExceeded;
            }
            try self.indirect.addBundle(&bundle.indirect);
        }
        const cmd = try context.encode(
            commands.ExecuteBundlesCmd,
            self.programmable.id,
            .execute_bundles,
        );
        cmd.* = .{ .count = @intCast(bundles.len) };
        const refs = try context.encodeData(commands.Ref, bundles.len);
        for (bundles, refs) |bundle, *ref| ref.* = try bundle.ref(guard);
        self.draw_count = draw_count;
        self.tracker = state_tracker.Tracker.init(self.allocator, self.compatibility_mode);
    }

    fn validateBundle(
        self: *const RenderEncoderBase,
        guard: *const core.ObjectGuard,
        bundle: *const render_bundle.RenderBundle,
    ) errors.Error!void {
        if (bundle.header.tracking != self.programmable.context.device.objects) {
            return error.ResourceDeviceMismatch;
        }
        guard.assertOwns(bundle.header.tracking);
        if (bundle.header.kind != .render_bundle) return error.HandleKindMismatch;
        if (!bundle.header.node.linked or bundle.header.state != .alive) {
            return error.BundleDestroyed;
        }
        const state = bundle.attachmentState();
        try self.validateAttachment(guard, state);
        if (state != self.attachmentState()) return error.AttachmentFormatMismatch;
    }

    fn resolveBundle(
        guard: *const core.ObjectGuard,
        reference: commands.Ref,
    ) errors.Error!*const render_bundle.RenderBundle {
        const pointer = reference orelse return error.InvalidBundle;
        var candidate = guard.objects.head;
        var visited: usize = 0;
        while (candidate) |header| : (visited += 1) {
            if (visited >= guard.objects.tracked_count) return error.InvalidBundle;
            if (@as(*anyopaque, @ptrCast(header)) == pointer) {
                if (header.kind != .render_bundle) return error.HandleKindMismatch;
                if (!header.node.linked or header.state != .alive) return error.BundleDestroyed;
                return @fieldParentPtr("header", header);
            }
            candidate = header.node.next;
        }
        return error.InvalidBundle;
    }

    fn validateBundleBody(
        self: *const RenderEncoderBase,
        guard: *const core.ObjectGuard,
        bundle: *const render_bundle.RenderBundle,
        validation: *BundleValidation,
    ) errors.Error!void {
        try self.validateBundle(guard, bundle);
        if (validation.depth == constants.max_bundle_depth) return error.BundleDepthExhausted;
        for (validation.stack[0..validation.depth]) |ancestor| {
            if (ancestor == bundle) return error.BundleCycle;
        }
        validation.stack[validation.depth] = bundle;
        validation.depth += 1;
        defer validation.depth -= 1;
        var cursor = bundle.iterator(guard);
        defer cursor.deinit();
        while (try cursor.nextTag()) |tag| {
            if (validation.command_count == constants.max_bundle_command_count) {
                return error.CommandCountExhausted;
            }
            validation.command_count += 1;
            switch (tag) {
                .execute_bundles => {
                    const command = try cursor.nextCommand(commands.ExecuteBundlesCmd);
                    const references = try cursor.nextData(commands.Ref, command.count);
                    if (references.len > constants.max_bundle_command_count) {
                        return error.CommandCountExhausted;
                    }
                    for (references) |reference| {
                        const nested = try resolveBundle(guard, reference);
                        try self.validateBundleBody(guard, nested, validation);
                    }
                },
                .set_render_pipeline => {
                    const command = try cursor.nextCommand(commands.SetRenderPipelineCmd);
                    if (command.attachment_state != self.attachmentState()) {
                        return error.AttachmentFormatMismatch;
                    }
                },
                .draw,
                .draw_indexed,
                .draw_indirect,
                .draw_indexed_indirect,
                .multi_draw_indirect,
                .multi_draw_indexed_indirect,
                .set_index_buffer,
                .set_vertex_buffer,
                .set_bind_group,
                .set_immediates,
                .set_resource_table,
                .set_stencil_reference,
                .insert_debug_marker,
                .pop_debug_group,
                .push_debug_group,
                => try commands.skip(&cursor.iterator, tag),
                else => return error.InvalidBundle,
            }
        }
    }

    fn mergeBundleUsage(
        self: *RenderEncoderBase,
        bundle_usage: *const usage.RenderPassResourceUsage,
    ) errors.Error!void {
        const scope = &bundle_usage.scope;
        for (scope.buffers.items, scope.buffer_sync_infos.items) |buffer, info| {
            const index = try self.usage.bufferUsedAs(buffer, info.usage);
            self.usage.sync_scope.scope.buffer_sync_infos.items[index].shader_stages |=
                info.shader_stages;
        }
        for (scope.texture_sync_infos.items) |entry| {
            try self.usage.textureRangeUsedAs(
                entry.texture,
                entry.mip_level,
                entry.array_layer,
                entry.aspect,
                entry.info,
            );
        }
        for (scope.external_textures.items) |texture| {
            var tracked = false;
            for (self.usage.sync_scope.scope.external_textures.items) |existing| {
                if (existing == texture) tracked = true;
            }
            if (!tracked) {
                try self.usage.sync_scope.scope.external_textures.append(self.allocator, texture);
            }
        }
        if (scope.resource_table != null) self.usage.setUsedResourceTable(scope.resource_table);
        if (bundle_usage.uses_framebuffer_fetch) self.usage.markFramebufferFetchUsed();
        for (bundle_usage.query_sets.items, bundle_usage.query_availabilities.items) |set, values| {
            if (values.items.len > std.math.maxInt(u32)) return error.LimitExceeded;
            for (values.items, 0..) |available, index| {
                if (available and self.queryAvailable(set, @intCast(index))) {
                    return error.QueryIndexOverwritten;
                }
            }
            try self.usage.trackQueryAvailability(set, @intCast(values.items.len));
            for (values.items, 0..) |available, index| {
                if (available) self.usage.markQueryAvailable(set, @intCast(index));
            }
        }
    }

    pub fn setResourceTable(self: *RenderEncoderBase, table: commands.Ref) errors.Error!void {
        const cmd = try self.programmable.context.encode(
            commands.SetResourceTableCmd,
            self.programmable.id,
            .set_resource_table,
        );
        cmd.* = .{ .table = table };
        self.tracker.setResourceTable(table);
        self.usage.setUsedResourceTable(table);
    }

    pub fn pixelLocalStorageBarrier(self: *RenderEncoderBase) errors.Error!void {
        try self.programmable.context.validateCanEncodeOn(self.programmable.id, false);
        return error.UnsupportedCommand;
    }

    fn queryAvailable(self: *const RenderEncoderBase, set: commands.Ref, index: u32) bool {
        for (self.usage.usage.query_sets.items, 0..) |tracked, set_index| {
            if (tracked != set) continue;
            if (set_index >= self.usage.usage.query_availabilities.items.len) return false;
            const availability = self.usage.usage.query_availabilities.items[set_index].items;
            return index < availability.len and availability[index];
        }
        return false;
    }

    pub fn beginOcclusionQuery(self: *RenderEncoderBase, index: u32) errors.Error!void {
        var next_state = self.occlusion_state;
        try next_state.beginOcclusionQuery(
            index,
            self.queryAvailable(self.occlusion_query_set, index),
        );
        try self.programmable.context.validateCanEncodeOn(self.programmable.id, false);
        const cmd = try self.programmable.context.encode(
            commands.BeginOcclusionQueryCmd,
            self.programmable.id,
            .begin_occlusion_query,
        );
        cmd.* = .{ .query_set = self.occlusion_query_set, .query_index = index };
        self.occlusion_state = next_state;
    }

    pub fn endOcclusionQuery(self: *RenderEncoderBase) errors.Error!void {
        var next_state = self.occlusion_state;
        const index = try next_state.endOcclusionQuery();
        try self.programmable.context.validateCanEncodeOn(self.programmable.id, false);
        try self.usage.trackQueryAvailability(
            self.occlusion_query_set,
            self.occlusion_state.query_count,
        );
        const cmd = try self.programmable.context.encode(
            commands.EndOcclusionQueryCmd,
            self.programmable.id,
            .end_occlusion_query,
        );
        cmd.* = .{ .query_set = self.occlusion_query_set, .query_index = index };
        self.usage.markQueryAvailable(self.occlusion_query_set, index);
        self.occlusion_state = next_state;
    }

    pub fn writeTimestamp(self: *RenderEncoderBase, options: WriteTimestampOptions) errors.Error!void {
        if (!self.timestamp_query_enabled and !options.timestamp_query_enabled) {
            return error.RequiredFeatureMissing;
        }
        if (options.query_set == null or options.query_type != .timestamp) {
            return error.QuerySetTypeMismatch;
        }
        if (options.query_index >= options.query_count) return error.TimestampIndexOutOfRange;
        if (self.queryAvailable(options.query_set, options.query_index)) {
            return error.QueryIndexOverwritten;
        }
        try self.programmable.context.validateCanEncodeOn(self.programmable.id, false);
        try self.usage.trackQueryAvailability(options.query_set, options.query_count);
        const cmd = try self.programmable.context.encode(
            commands.WriteTimestampCmd,
            self.programmable.id,
            .write_timestamp,
        );
        cmd.* = .{ .query_set = options.query_set, .query_index = options.query_index };
        self.usage.markQueryAvailable(options.query_set, options.query_index);
    }

    /// Dawn's `APIDraw` (`RenderEncoderBase.cpp:105-149`): validate, record,
    /// count. The order is Dawn's and it is the whole reason the overrun is
    /// reported rather than recorded.
    pub fn draw(self: *RenderEncoderBase, options: DrawVertexCountOptions) errors.Error!void {
        try self.tracker.validateCanDraw();
        try self.tracker.validateNoDifferentTextureViewsOnSameTexture();
        try self.tracker.validateBufferInRangeForVertexBuffer(options.vertex_count, options.first_vertex);
        try self.tracker.validateBufferInRangeForInstanceBuffer(options.instance_count, options.first_instance);
        const cmd = try self.programmable.context.encode(
            commands.DrawCmd,
            self.programmable.id,
            .draw,
        );
        cmd.* = .{
            .vertex_count = options.vertex_count,
            .instance_count = options.instance_count,
            .first_vertex = options.first_vertex,
            .first_instance = options.first_instance,
        };
        self.draw_count += 1;
    }

    /// Dawn's `APIDrawIndexed` (`RenderEncoderBase.cpp:151-202`).
    pub fn drawIndexed(
        self: *RenderEncoderBase,
        options: DrawIndexedIndexCountOptions,
        base_vertex: i32,
    ) errors.Error!void {
        try self.tracker.validateCanDrawIndexed();
        try self.tracker.validateNoDifferentTextureViewsOnSameTexture();
        try self.tracker.validateIndexBufferInRange(options.index_count, options.first_index);
        const cmd = try self.programmable.context.encode(
            commands.DrawIndexedCmd,
            self.programmable.id,
            .draw_indexed,
        );
        cmd.* = .{
            .index_count = options.index_count,
            .instance_count = options.instance_count,
            .first_index = options.first_index,
            .base_vertex = base_vertex,
            .first_instance = options.first_instance,
        };
        self.draw_count += 1;
    }

    /// Dawn's `APIDrawIndirect` (`RenderEncoderBase.cpp:203-261`).
    pub fn drawIndirect(self: *RenderEncoderBase, options: DrawIndirectOptions) errors.Error!void {
        try RenderEncoderBase.validateIndirectBuffer(
            options.indirect_buffer_size,
            options.indirect_offset,
            constants.draw_indirect_size,
        );
        try self.tracker.validateCanDraw();
        try self.recordIndirect(options.indirect_buffer, options.indirect_offset, false);
    }

    /// Dawn's `APIDrawIndexedIndirect` (`RenderEncoderBase.cpp:262-327`).
    pub fn drawIndexedIndirect(self: *RenderEncoderBase, options: DrawIndirectOptions) errors.Error!void {
        try RenderEncoderBase.validateIndirectBuffer(
            options.indirect_buffer_size,
            options.indirect_offset,
            constants.draw_indexed_indirect_size,
        );
        try self.tracker.validateCanDrawIndexed();
        try self.recordIndirect(options.indirect_buffer, options.indirect_offset, true);
    }

    /// Dawn's `APIMultiDrawIndirect` (`RenderEncoderBase.cpp:328-433`).
    pub fn multiDrawIndirect(self: *RenderEncoderBase, options: MultiDrawIndirectOptions) errors.Error!void {
        try validateMultiDrawBuffers(options, false);
        try self.tracker.validateCanDraw();
        try self.recordMultiDrawIndirect(options, false);
    }

    /// Dawn's `APIMultiDrawIndexedIndirect` (`RenderEncoderBase.cpp:434-542`).
    pub fn multiDrawIndexedIndirect(self: *RenderEncoderBase, options: MultiDrawIndirectOptions) errors.Error!void {
        try validateMultiDrawBuffers(options, true);
        try self.tracker.validateCanDrawIndexed();
        try self.recordMultiDrawIndirect(options, true);
    }

    fn validateMultiDrawBuffers(
        options: MultiDrawIndirectOptions,
        indexed: bool,
    ) errors.Error!void {
        if (options.max_draw_count > indirect_draw.max_draw_count) return error.LimitExceeded;
        const stride: u64 = if (indexed)
            constants.draw_indexed_indirect_size
        else
            constants.draw_indirect_size;
        try validateIndirectBuffer(
            options.indirect_buffer_size,
            options.indirect_offset,
            stride * options.max_draw_count,
        );
        if (options.draw_count_buffer != null) {
            try validateIndirectBuffer(
                options.draw_count_buffer_size,
                options.draw_count_offset,
                4,
            );
        }
    }

    fn selectedIndexRange(self: *const RenderEncoderBase) indirect_draw.IndexBufferRange {
        return .{
            .buffer = self.tracker.index_buffer,
            .offset = self.selected_index_offset,
            .size = self.tracker.index_buffer_size,
            .format = self.tracker.index_format,
        };
    }

    fn validateIndirectBuffer(
        buffer_size: u64,
        offset: u64,
        required_size: u64,
    ) errors.Error!void {
        return indirect_draw.IndirectDrawMetadata.validateIndirectBufferSize(buffer_size, offset, required_size);
    }

    /// Dawn records the indirect draw into the metadata after the tag
    /// (`RenderEncoderBase.cpp:225` and `:285`).
    fn recordIndirect(
        self: *RenderEncoderBase,
        buffer: commands.Ref,
        offset: u64,
        indexed: bool,
    ) errors.Error!void {
        const context = self.programmable.context;
        errdefer {
            context.status = .error_in_recording;
            context.current_id = encoding_context.no_encoder;
        }
        // Dawn's two tags share one payload struct by inheritance
        // (`Commands.h:306`), so the port has one write for both.
        const cmd = if (indexed)
            try self.programmable.context.encode(
                commands.DrawIndexedIndirectCmd,
                self.programmable.id,
                .draw_indexed_indirect,
            )
        else
            try self.programmable.context.encode(
                commands.DrawIndirectCmd,
                self.programmable.id,
                .draw_indirect,
            );
        cmd.* = .{ .indirect_buffer = buffer, .indirect_offset = offset };
        if (indexed) {
            try self.indirect.addIndexedIndirectDraw(buffer, offset, self.selectedIndexRange());
        } else {
            try self.indirect.addIndirectDraw(buffer, offset);
        }
        _ = try self.usage.bufferUsedAs(buffer, (api.BufferUsage{ .indirect = true }).toFlags());
        self.draw_count += 1;
    }

    fn recordMultiDrawIndirect(
        self: *RenderEncoderBase,
        options: MultiDrawIndirectOptions,
        indexed: bool,
    ) errors.Error!void {
        const context = self.programmable.context;
        errdefer {
            context.status = .error_in_recording;
            context.current_id = encoding_context.no_encoder;
        }
        // The same shared struct, one tag each (`Commands.h:319`).
        const cmd = if (indexed)
            try self.programmable.context.encode(
                commands.MultiDrawIndexedIndirectCmd,
                self.programmable.id,
                .multi_draw_indexed_indirect,
            )
        else
            try self.programmable.context.encode(
                commands.MultiDrawIndirectCmd,
                self.programmable.id,
                .multi_draw_indirect,
            );
        cmd.* = .{
            .indirect_buffer = options.indirect_buffer,
            .indirect_offset = options.indirect_offset,
            .max_draw_count = options.max_draw_count,
            .draw_count_buffer = options.draw_count_buffer,
            .draw_count_offset = options.draw_count_offset,
        };
        try self.indirect.addMultiDrawIndirect(.{
            .buffer = options.indirect_buffer,
            .offset = options.indirect_offset,
            .max_draw_count = options.max_draw_count,
            .draw_count_buffer = options.draw_count_buffer,
            .draw_count_offset = options.draw_count_offset,
            .index_buffer = if (indexed) self.selectedIndexRange() else null,
        });
        const indirect_usage = (api.BufferUsage{ .indirect = true }).toFlags();
        _ = try self.usage.bufferUsedAs(options.indirect_buffer, indirect_usage);
        if (options.draw_count_buffer != null) {
            _ = try self.usage.bufferUsedAs(options.draw_count_buffer, indirect_usage);
        }
        self.draw_count += options.max_draw_count;
    }
};

const BundleValidation = struct {
    command_count: usize = 0,
    depth: usize = 0,
    stack: [constants.max_bundle_depth]?*const render_bundle.RenderBundle = @splat(null),
};

const TestDevice = struct {
    mutex: std.Io.Mutex,
    device: core.Device,

    fn init(self: *TestDevice, allocator: std.mem.Allocator) void {
        self.mutex = .init;
        self.device = core.Device.init(allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("unexpected uncaptured core error");
    }
};

fn testAttachment(
    allocator: std.mem.Allocator,
    device: *core.Device,
    guard: *const core.ObjectGuard,
    sample_count: u32,
) !*attachment.CanonicalAttachmentState {
    const state = try device.create(allocator, guard, attachment.CanonicalAttachmentState, .{
        .kind = .attachment_state,
        .initial_reference = .user,
    });
    state.value = .{ .sample_count = sample_count };
    state.cache_hash = 0;
    state.cache_next = null;
    state.header.attach(guard, std.testing.io);
    return state;
}

fn testPass(
    allocator: std.mem.Allocator,
    device: *core.Device,
    context: *encoding_context.Context,
    guard: *const core.ObjectGuard,
) !RenderEncoderBase {
    const state = try testAttachment(allocator, device, guard, 1);
    defer state.header.releaseUserLocked(guard, std.testing.io) catch @panic("release failed");
    var prepared = usage.RenderPassResourceUsageTracker.init(allocator);
    try prepared.usage.retainAttachmentLocked(guard, state);
    return RenderEncoderBase.initOwned(allocator, context, false, prepared);
}

test "abandoned pass invalidates before releasing its only attachment lease" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try testAttachment(std.testing.allocator, &fixture.device, &guard, 1);
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var prepared = usage.RenderPassResourceUsageTracker.init(std.testing.allocator);
    try prepared.usage.retainAttachmentLocked(&guard, state);
    var pass = RenderEncoderBase.initOwned(std.testing.allocator, &context, false, prepared);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    try state.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    const begin = try context.encode(
        commands.BeginRenderPassCmd,
        pass.programmable.id,
        .begin_render_pass,
    );
    begin.* = .{ .attachment_state = state };
    pass.deinit(std.testing.io, &guard);
    pass.deinit(std.testing.io, &guard);
    try std.testing.expectEqual(encoding_context.Status.error_in_recording, context.status);
    try std.testing.expectEqual(encoding_context.no_encoder, context.current_id);
    try std.testing.expectEqual(@as(u32, 0), state.header.reference_count);
    try std.testing.expectError(error.EncoderInvalidated, context.finish());
}

test "render pipeline canonical mismatch and cross-device owner record nothing" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try testAttachment(std.testing.allocator, &fixture.device, &guard, 1);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    const same_value = try testAttachment(std.testing.allocator, &fixture.device, &guard, 1);
    defer same_value.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    const multisampled = try testAttachment(std.testing.allocator, &fixture.device, &guard, 4);
    defer multisampled.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    var other: TestDevice = undefined;
    other.init(std.testing.allocator);
    var other_guard = core.ObjectGuard.lockUncancelable(std.testing.io, other.device.borrow().objects);
    defer other_guard.unlock(std.testing.io);
    defer other.device.deinit(std.testing.allocator, &other_guard) catch @panic("references leaked");
    const foreign = try testAttachment(std.testing.allocator, &other.device, &other_guard, 1);
    defer foreign.header.releaseUserLocked(&other_guard, std.testing.io) catch @panic("release failed");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var prepared = usage.RenderPassResourceUsageTracker.init(std.testing.allocator);
    try prepared.usage.retainAttachmentLocked(&guard, state);
    var pass = RenderEncoderBase.initOwned(std.testing.allocator, &context, false, prepared);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    try std.testing.expectError(error.AttachmentFormatMismatch, pass.setPipeline(&guard, .{
        .pipeline = null,
        .requirements = .{},
        .attachment_state = same_value,
    }));
    try std.testing.expectError(error.AttachmentSampleCountMismatch, pass.setPipeline(&guard, .{
        .pipeline = null,
        .requirements = .{},
        .attachment_state = multisampled,
    }));
    try std.testing.expectError(error.ResourceDeviceMismatch, pass.setPipeline(&guard, .{
        .pipeline = null,
        .requirements = .{},
        .attachment_state = foreign,
    }));
    try std.testing.expectError(error.ResourceDeviceMismatch, pass.setPipeline(&other_guard, .{
        .pipeline = null,
        .requirements = .{},
        .attachment_state = state,
    }));
    same_value.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(error.ResourceDestroyed, pass.setPipeline(&guard, .{
        .pipeline = null,
        .requirements = .{},
        .attachment_state = same_value,
    }));
    state.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(error.ResourceDestroyed, pass.setPipeline(&guard, .{
        .pipeline = null,
        .requirements = .{},
        .attachment_state = state,
    }));
    var cursor = allocator_mod.Iterator.init(std.testing.allocator, context.pending.acquireBlocks());
    defer cursor.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, null), try cursor.nextTag());
}

test "dynamic render state records validated payloads" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    pass.width = 64;
    pass.height = 32;
    try pass.setViewport(.{
        .x = 2,
        .y = 3,
        .width = 16,
        .height = 8,
        .min_depth = 0,
        .max_depth = 1,
    });
    try pass.setScissorRect(.{ .x = 4, .y = 5, .width = 6, .height = 7 });
    try pass.setBlendConstant(.{ .r = 1, .g = 2, .b = 3, .a = 4 });
    try pass.setStencilReference(17);
    var iterator = allocator_mod.Iterator.init(
        std.testing.allocator,
        context.pending.acquireBlocks(),
    );
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .set_viewport), try iterator.nextTag());
    try std.testing.expectEqual(@as(f32, 16), (try iterator.nextCommand(commands.SetViewportCmd)).width);
    try std.testing.expectEqual(@as(?commands.Tag, .set_scissor_rect), try iterator.nextTag());
    try std.testing.expectEqual(@as(u32, 7), (try iterator.nextCommand(commands.SetScissorRectCmd)).height);
    try std.testing.expectEqual(@as(?commands.Tag, .set_blend_constant), try iterator.nextTag());
    try std.testing.expectEqual(@as(f32, 4), (try iterator.nextCommand(commands.SetBlendConstantCmd)).color.a);
    try std.testing.expectEqual(@as(?commands.Tag, .set_stencil_reference), try iterator.nextTag());
    try std.testing.expectEqual(@as(u32, 17), (try iterator.nextCommand(commands.SetStencilReferenceCmd)).reference);
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}

test "invalid dynamic render state records nothing" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    pass.width = 8;
    pass.height = 8;
    try std.testing.expectError(error.NonFiniteFloat, pass.setViewport(.{ .width = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidViewport, pass.setViewport(.{ .width = 9 }));
    try std.testing.expectError(
        error.InvalidScissorRect,
        pass.setScissorRect(.{ .x = 7, .width = std.math.maxInt(u32) }),
    );
    try std.testing.expectError(
        error.NonFiniteFloat,
        pass.setBlendConstant(.{ .r = 0, .g = 0, .b = 0, .a = std.math.inf(f32) }),
    );
    var iterator = allocator_mod.Iterator.init(
        std.testing.allocator,
        context.pending.acquireBlocks(),
    );
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}

test "occlusion queries mark availability only when ended and refuse reuse" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    pass.occlusion_query_set = &token;
    pass.occlusion_state = try query.OcclusionQueryState.init(.{
        .attached = true,
        .query_count = 2,
    });
    try pass.beginOcclusionQuery(1);
    try std.testing.expect(!pass.queryAvailable(&token, 1));
    try std.testing.expectError(error.OcclusionQueryAlreadyActive, pass.beginOcclusionQuery(0));
    try std.testing.expectError(error.OcclusionQueryUnterminated, pass.occlusion_state.end());
    try pass.endOcclusionQuery();
    try std.testing.expect(pass.queryAvailable(&token, 1));
    try std.testing.expectError(error.QueryIndexOverwritten, pass.beginOcclusionQuery(1));
    try std.testing.expectError(error.OcclusionQueryNotActive, pass.endOcclusionQuery());
    var iterator = allocator_mod.Iterator.init(
        std.testing.allocator,
        context.pending.acquireBlocks(),
    );
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .begin_occlusion_query), try iterator.nextTag());
    const begin = try iterator.nextCommand(commands.BeginOcclusionQueryCmd);
    try std.testing.expectEqual(pass.occlusion_query_set, begin.query_set);
    try std.testing.expectEqual(@as(u32, 1), begin.query_index);
    try std.testing.expectEqual(@as(?commands.Tag, .end_occlusion_query), try iterator.nextTag());
    try std.testing.expectEqual(@as(u32, 1), (try iterator.nextCommand(commands.EndOcclusionQueryCmd)).query_index);
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}

test "timestamp writes require feature and track query reuse" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    var options: WriteTimestampOptions = .{
        .query_set = &token,
        .query_count = 2,
        .query_index = 1,
    };
    try std.testing.expectError(error.RequiredFeatureMissing, pass.writeTimestamp(options));
    options.timestamp_query_enabled = true;
    try pass.writeTimestamp(options);
    try std.testing.expect(pass.queryAvailable(&token, 1));
    try std.testing.expectError(error.QueryIndexOverwritten, pass.writeTimestamp(options));
    options.query_index = 2;
    try std.testing.expectError(error.TimestampIndexOutOfRange, pass.writeTimestamp(options));
}

test "resource table updates pass tracking and pixel local storage fails explicitly" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    try pass.setResourceTable(&token);
    try std.testing.expectEqual(@as(commands.Ref, &token), pass.tracker.resource_table);
    try std.testing.expectEqual(@as(commands.Ref, &token), pass.usage.sync_scope.scope.resource_table);
    try std.testing.expectError(error.UnsupportedCommand, pass.pixelLocalStorageBarrier());
}

test "render pass end rejects an open occlusion query" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    pass.occlusion_query_set = &token;
    pass.occlusion_state = try query.OcclusionQueryState.init(.{
        .attached = true,
        .query_count = 1,
    });
    try pass.beginOcclusionQuery(0);
    try std.testing.expectError(
        error.OcclusionQueryUnterminated,
        pass.end(std.testing.io, &guard),
    );
    try std.testing.expectEqual(encoding_context.Status.error_in_recording, context.status);
}

test "render state and query producers release every failed allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordRenderStateAndQueries,
        .{},
    );
}

fn recordRenderStateAndQueries(allocator: std.mem.Allocator) !void {
    var fixture: TestDevice = undefined;
    fixture.init(allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(allocator, fixture.device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var occlusion_token: u8 = 0;
    var timestamp_token: u8 = 0;
    pass.occlusion_query_set = &occlusion_token;
    pass.occlusion_state = try query.OcclusionQueryState.init(.{
        .attached = true,
        .query_count = 2,
    });
    try pass.setViewport(.{ .width = 1, .height = 1, .max_depth = 1 });
    try pass.setScissorRect(.{ .width = 1, .height = 1 });
    try pass.setBlendConstant(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try pass.setStencilReference(1);
    try pass.setResourceTable(&occlusion_token);
    try pass.beginOcclusionQuery(1);
    try pass.endOcclusionQuery();
    try pass.writeTimestamp(.{
        .query_set = &timestamp_token,
        .query_count = 2,
        .query_index = 0,
        .timestamp_query_enabled = true,
    });
}

test "executing bundles records references and merges draw metadata" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    var encoder = try render_bundle.RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &fixture.device,
        pass.attachmentState(),
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.setPipeline(&guard, .{
        .pipeline = &token,
        .requirements = .{},
        .attachment_state = pass.attachmentState(),
    });
    try encoder.setBindGroup(.{
        .index = 0,
        .group = &token,
        .buffers = &.{.{ .buffer = &token, .usage = 2 }},
        .textures = &.{.{
            .texture = &token,
            .mip_level = 1,
            .array_layer = 2,
            .aspect = .all,
            .usage = 8,
            .shader_stages = 16,
        }},
    });
    try encoder.draw(.{
        .vertex_count = 1,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try encoder.draw(.{
        .vertex_count = 1,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try encoder.drawIndirect(.{
        .indirect_buffer = &token,
        .indirect_buffer_size = 32,
        .indirect_offset = 16,
    });
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    _ = try pass.usage.bufferUsedAs(&token, 1);
    try pass.executeBundles(&guard, &.{bundle});
    try std.testing.expectEqual(@as(u64, 3), pass.draw_count);
    try std.testing.expectEqual(@as(usize, 1), pass.indirect.draws.items.len);
    try std.testing.expectEqual(@as(u64, 16), pass.indirect.draws.items[0].offset);
    try std.testing.expectEqual(@as(u32, 259), pass.usage.sync_scope.scope.buffer_sync_infos.items[0].usage);
    const texture_info = pass.usage.sync_scope.scope.texture_sync_infos.items[0];
    try std.testing.expectEqual(@as(commands.Ref, &token), texture_info.texture);
    try std.testing.expectEqual(@as(u32, 8), texture_info.info.usage);
    try std.testing.expectEqual(@as(u32, 16), texture_info.info.shader_stages);
    var iterator = allocator_mod.Iterator.init(
        std.testing.allocator,
        context.pending.acquireBlocks(),
    );
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .execute_bundles), try iterator.nextTag());
    try std.testing.expectEqual(@as(u32, 1), (try iterator.nextCommand(commands.ExecuteBundlesCmd)).count);
    const refs = try iterator.nextData(commands.Ref, 1);
    try std.testing.expectEqual(@as(commands.Ref, @ptrCast(&bundle.header)), refs[0]);
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
    try std.testing.expectError(error.MissingPipeline, pass.tracker.validateCanDraw());
    try pass.setPipeline(&guard, .{
        .pipeline = &token,
        .requirements = .{},
        .attachment_state = pass.attachmentState(),
    });
    try pass.tracker.validateCanDraw();
}

test "bundle attachment mismatch records nothing" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    const state = try testAttachment(std.testing.allocator, &fixture.device, &guard, 1);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    var encoder = try render_bundle.RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &fixture.device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    const bundle = try encoder.finish(std.testing.io, &guard);
    try std.testing.expectError(
        error.AttachmentFormatMismatch,
        pass.executeBundles(&guard, &.{bundle}),
    );
    try bundle.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectError(error.BundleDestroyed, pass.executeBundles(&guard, &.{bundle}));
    var other: TestDevice = undefined;
    other.init(std.testing.allocator);
    var other_guard = core.ObjectGuard.lockUncancelable(std.testing.io, other.device.borrow().objects);
    defer other_guard.unlock(std.testing.io);
    defer other.device.deinit(std.testing.allocator, &other_guard) catch @panic("references leaked");
    const foreign_state = try testAttachment(std.testing.allocator, &other.device, &other_guard, 1);
    defer foreign_state.header.releaseUserLocked(&other_guard, std.testing.io) catch
        @panic("release failed");
    var foreign_encoder = try render_bundle.RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &other_guard,
        &other.device,
        foreign_state,
        .{},
    );
    defer foreign_encoder.deinit(std.testing.io, &other_guard);
    const foreign_bundle = try foreign_encoder.finish(std.testing.io, &other_guard);
    defer foreign_bundle.header.releaseUserLocked(&other_guard, std.testing.io) catch
        @panic("release failed");
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        pass.executeBundles(&guard, &.{foreign_bundle}),
    );
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        pass.executeBundles(&other_guard, &.{}),
    );
    try std.testing.expectEqual(@as(u64, 0), pass.draw_count);
    var iterator = allocator_mod.Iterator.init(
        std.testing.allocator,
        context.pending.acquireBlocks(),
    );
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}

test "executing bundles releases every failed allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordBundles,
        .{},
    );
}

fn recordBundles(allocator: std.mem.Allocator) !void {
    var fixture: TestDevice = undefined;
    fixture.init(allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(allocator, fixture.device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    var encoder = try render_bundle.RenderBundleEncoder.init(
        allocator,
        std.testing.io,
        &guard,
        &fixture.device,
        pass.attachmentState(),
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.setPipeline(&guard, .{
        .pipeline = &token,
        .requirements = .{},
        .attachment_state = pass.attachmentState(),
    });
    try encoder.setBindGroup(.{
        .index = 0,
        .group = &token,
        .buffers = &.{.{ .buffer = &token, .usage = 1 }},
    });
    try encoder.drawIndirect(.{
        .indirect_buffer = &token,
        .indirect_buffer_size = 16,
        .indirect_offset = 0,
    });
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    try pass.executeBundles(&guard, &.{ bundle, bundle });
    try std.testing.expectEqual(@as(u64, 2), pass.draw_count);
    try std.testing.expectEqual(@as(usize, 2), pass.indirect.draws.items.len);
    try std.testing.expectEqual(@as(u32, 0), pass.indirect.draws.items[0].index);
    try std.testing.expectEqual(@as(u32, 1), pass.indirect.draws.items[1].index);
}

fn testRawBundle(
    device: *core.Device,
    guard: *const core.ObjectGuard,
    state: *attachment.CanonicalAttachmentState,
    stream: *allocator_mod.Allocator,
) !*render_bundle.RenderBundle {
    const bundle = try device.create(std.testing.allocator, guard, render_bundle.RenderBundle, .{
        .kind = .render_bundle,
        .initial_reference = .user,
    });
    errdefer bundle.header.discardUnpublishedLocked(guard) catch @panic("rollback failed");
    var owned_usage = usage.RenderPassResourceUsage.init(std.testing.allocator);
    try owned_usage.retainAttachmentLocked(guard, state);
    bundle.allocator = std.testing.allocator;
    bundle.blocks = stream.acquireBlocks();
    bundle.draw_count = 0;
    bundle.resource_usage = owned_usage;
    bundle.indirect = indirect_draw.IndirectDrawMetadata.init(std.testing.allocator);
    bundle.header.attach(guard, std.testing.io);
    return bundle;
}

test "real bundle bodies reject cycles depth exhaustion and malformed data before emission" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var stream = try allocator_mod.Allocator.init(std.testing.allocator, 4096);
    defer stream.deinit();
    const nested = try stream.allocateCommand(
        commands.ExecuteBundlesCmd,
        @backingInt(commands.Tag.execute_bundles),
    );
    nested.* = .{ .count = 1 };
    const references = try stream.allocateData(commands.Ref, 1);
    references[0] = null;
    const cyclic = try testRawBundle(&fixture.device, &guard, pass.attachmentState(), &stream);
    defer cyclic.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    references[0] = try cyclic.ref(&guard);
    try std.testing.expectError(error.BundleCycle, pass.executeBundles(&guard, &.{cyclic}));
    references[0] = &pass.attachmentState().header;
    try std.testing.expectError(error.HandleKindMismatch, pass.executeBundles(&guard, &.{cyclic}));
    references[0] = null;
    try std.testing.expectError(error.InvalidBundle, pass.executeBundles(&guard, &.{cyclic}));
    var chain: [constants.max_bundle_depth + 1]*render_bundle.RenderBundle = undefined;
    var count: usize = 0;
    defer for (chain[0..count]) |bundle| {
        bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    };
    for (&chain) |*slot| {
        if (count != 0) {
            const command = try stream.allocateCommand(
                commands.ExecuteBundlesCmd,
                @backingInt(commands.Tag.execute_bundles),
            );
            command.* = .{ .count = 1 };
            (try stream.allocateData(commands.Ref, 1))[0] = try chain[count - 1].ref(&guard);
        }
        slot.* = try testRawBundle(&fixture.device, &guard, pass.attachmentState(), &stream);
        count += 1;
    }
    try pass.executeBundles(&guard, &.{chain[constants.max_bundle_depth - 1]});
    try std.testing.expectError(
        error.BundleDepthExhausted,
        pass.executeBundles(&guard, &.{chain[constants.max_bundle_depth]}),
    );
    _ = try stream.allocateCommand(
        commands.ExecuteBundlesCmd,
        @backingInt(commands.Tag.execute_bundles),
    );
    const malformed = try testRawBundle(&fixture.device, &guard, pass.attachmentState(), &stream);
    defer malformed.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    var malformed_cursor = malformed.iterator(&guard);
    defer malformed_cursor.deinit();
    _ = try malformed_cursor.nextTag();
    (try malformed_cursor.nextCommand(commands.ExecuteBundlesCmd)).count = 1;
    try std.testing.expectError(
        error.CommandStreamTruncated,
        pass.executeBundles(&guard, &.{malformed}),
    );
    var cursor = allocator_mod.Iterator.init(std.testing.allocator, context.pending.acquireBlocks());
    defer cursor.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .execute_bundles), try cursor.nextTag());
    try commands.skip(&cursor, .execute_bundles);
    try std.testing.expectEqual(@as(?commands.Tag, null), try cursor.nextTag());
}

test "bundle command budget counts repeated actual bodies exactly" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var stream = try allocator_mod.Allocator.init(std.testing.allocator, 4096);
    defer stream.deinit();
    const command = try stream.allocateCommand(
        commands.SetStencilReferenceCmd,
        @backingInt(commands.Tag.set_stencil_reference),
    );
    command.* = .{ .reference = 1 };
    const bundle = try testRawBundle(&fixture.device, &guard, pass.attachmentState(), &stream);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("release failed");
    var budget: BundleValidation = .{ .command_count = constants.max_bundle_command_count - 1 };
    try pass.validateBundleBody(&guard, bundle, &budget);
    try std.testing.expectEqual(constants.max_bundle_command_count, budget.command_count);
    try std.testing.expectError(
        error.CommandCountExhausted,
        pass.validateBundleBody(&guard, bundle, &budget),
    );
    try std.testing.expectEqual(constants.max_bundle_command_count, budget.command_count);
}

test "successful pass end moves exactly one lease and deferred cleanup is harmless" {
    try recordPassLifetime(std.testing.allocator);
}

test "pass ownership transition cleans every failed allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordPassLifetime,
        .{},
    );
}

fn recordPassLifetime(allocator: std.mem.Allocator) !void {
    var fixture: TestDevice = undefined;
    fixture.init(allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(allocator, fixture.device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    const state = pass.attachmentState();
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    pass.end(std.testing.io, &guard) catch |err| {
        try std.testing.expectEqual(encoding_context.Status.error_in_recording, context.status);
        try std.testing.expectEqual(encoding_context.no_encoder, context.current_id);
        return err;
    };
    pass.deinit(std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    try std.testing.expectEqual(state, context.render_pass_usages.items[0].attachment_state.?);
    var finished = try context.finish();
    defer finished.deinit(allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    try std.testing.expectEqual(state, finished.render_pass_usages.items[0].attachment_state.?);
    finished.deinit(allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 0), state.header.reference_count);
}

test "indexed indirect encoding snapshots validated selected range before rebinding" {
    var fixture: TestDevice = undefined;
    fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer fixture.device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(
        std.testing.allocator,
        fixture.device.borrow(),
        4096,
        false,
    );
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var pass = try testPass(std.testing.allocator, &fixture.device, &context, &guard);
    defer pass.deinit(std.testing.io, &guard);
    pass.programmable.id = context.enterPass();
    var token: u8 = 0;
    try pass.setPipeline(&guard, .{
        .pipeline = &token,
        .requirements = .{},
        .attachment_state = pass.attachmentState(),
    });
    try pass.setIndexBuffer(.{
        .buffer = &token,
        .buffer_size = 1024,
        .offset = 100,
        .size = 10,
        .format = .uint16,
    });
    try pass.drawIndexedIndirect(.{
        .indirect_buffer = &token,
        .indirect_buffer_size = 64,
        .indirect_offset = 0,
    });
    try pass.setIndexBuffer(.{
        .buffer = &token,
        .buffer_size = 1024,
        .offset = 200,
        .size = 12,
        .format = .uint32,
    });
    try pass.multiDrawIndexedIndirect(.{
        .indirect_buffer = &token,
        .indirect_buffer_size = 64,
        .indirect_offset = 20,
        .max_draw_count = 2,
    });
    const first = pass.indirect.draws.items[0];
    try std.testing.expectEqual(@as(u64, 100), first.index_buffer_offset);
    try std.testing.expectEqual(@as(u64, 10), first.index_buffer_size);
    try std.testing.expectEqual(@as(u64, 5), first.index_element_count);
    const second = pass.indirect.draws.items[1];
    try std.testing.expectEqual(@as(u64, 200), second.index_buffer_offset);
    try std.testing.expectEqual(@as(u64, 12), second.index_buffer_size);
    try std.testing.expectEqual(@as(u64, 3), second.index_element_count);
    try std.testing.expectError(error.DrawIndexCount, pass.setIndexBuffer(.{
        .buffer = &token,
        .buffer_size = 8,
        .offset = 12,
        .format = .uint16,
    }));
    try std.testing.expectError(error.IndirectBufferTooSmall, pass.multiDrawIndirect(.{
        .indirect_buffer = &token,
        .indirect_buffer_size = 16,
        .indirect_offset = 0,
        .max_draw_count = 2,
    }));
    try std.testing.expectError(error.IndirectBufferTooSmall, pass.multiDrawIndirect(.{
        .indirect_buffer = &token,
        .indirect_buffer_size = 64,
        .indirect_offset = 0,
        .max_draw_count = 2,
        .draw_count_buffer = &token,
        .draw_count_buffer_size = 4,
        .draw_count_offset = 4,
    }));
    try std.testing.expectEqual(@as(usize, 2), pass.indirect.drawCount());
}
