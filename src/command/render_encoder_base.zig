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
//! It does not claim the pass is a WebGPU object. A pass encoder here is a
//! value the caller owns; it has no handle, no refcount and no lifetime beyond
//! the caller's stack frame. That is the port's deliberate departure
//! (`docs/10-architecture.md`, "Object model") and it is what lets a test
//! record a whole pass with no device.

const std = @import("std");
const allocator_mod = @import("allocator.zig");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const indirect_draw = @import("indirect_draw.zig");
const programmable_encoder = @import("programmable_encoder.zig");
const state_tracker = @import("state_tracker.zig");
const usage = @import("usage.zig");

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
};

/// What a render pass encoder holds besides its `ProgrammableEncoder`.
pub const RenderEncoderBase = struct {
    programmable: programmable_encoder.ProgrammableEncoder,
    tracker: state_tracker.Tracker,
    usage: usage.RenderPassResourceUsageTracker,
    indirect: indirect_draw.IndirectDrawMetadata,
    allocator: std.mem.Allocator,

    /// The interned attachment state of the pass this encoder is in. Dawn
    /// holds it on the base (`RenderEncoderBase.h:112`).
    attachment_state: commands.Ref = null,
    draw_count: u64 = 0,
    max_draw_count: u64 = constants.default_max_draw_count,
    compatibility_mode: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *encoding_context.Context,
        compatibility_mode: bool,
    ) allocator_mod.AllocatorError!RenderEncoderBase {
        return .{
            .programmable = programmable_encoder.ProgrammableEncoder.init(allocator, context),
            .tracker = state_tracker.Tracker.init(allocator, compatibility_mode),
            .usage = usage.RenderPassResourceUsageTracker.init(allocator),
            .indirect = indirect_draw.IndirectDrawMetadata.init(allocator),
            .allocator = allocator,
            .compatibility_mode = compatibility_mode,
        };
    }

    /// Dawn's `RenderEncoderBase::DestroyImpl`
    /// (`RenderEncoderBase.cpp:72-78`): the usage tracker is reset, then the
    /// attachment-state reference is dropped so the device can uncache it. The
    /// port keeps the attachment state with the pass encoder, so its `deinit`
    /// frees the usage lists and leaves the rest to the caller.
    pub fn deinit(self: *RenderEncoderBase) void {
        self.usage.deinit();
        self.indirect.deinit();
        self.* = undefined;
    }

    /// Dawn's `RenderPassEncoder::End` (`RenderPassEncoder.cpp:157-196`): the
    /// programmable-encoder rules, the draw count, the closing tag on the pass's
    /// own encoder, then `ExitRenderPass`, which commits the block the body
    /// lives in. Dawn's occlusion-query check (`:174-177`) has no encoder here
    /// to run, and `src/command/errors.zig:166-168` keeps its rule for the day
    /// one lands.
    ///
    /// This is the pass encoder's only exit: it hands both lists the pass owns
    /// to the context and then releases the pass, so a caller that ended a pass
    /// never calls `deinit` on it. A caller that does is harmless rather than a
    /// double free, because every list this call moves out is emptied first.
    ///
    /// One set covers the body: `errors.Error` is `core.Error ||
    /// CommandValidationError || std.mem.Allocator.Error` (`errors.zig:211`) and
    /// `AllocatorError` is the last two of those (`allocator.zig:234`).
    pub fn end(self: *RenderEncoderBase) errors.Error!void {
        // `defer` and not a call at the end: the two rules above can refuse the
        // end, and a refused end still owns every list the pass built.
        defer self.deinit();

        try self.programmable.validateProgrammableEncoderEnd();
        if (self.draw_count > self.max_draw_count) return error.DrawCountExceeded;

        const context = self.programmable.context;
        const encoder = self.programmable.id;
        _ = try context.encode(commands.EndRenderPassCmd, encoder, .end_render_pass);

        // `exitRenderPass` appends the usage and then the metadata
        // (`encoding_context.zig:267-271`) before its last fallible step, so
        // both lists are reserved here: after this there is no point at which
        // the context holds one of them and the pass holds the other.
        try context.render_pass_usages.ensureUnusedCapacity(context.allocator, 1);
        try context.indirect_draws.ensureUnusedCapacity(context.allocator, 1);
        try context.exitRenderPass(
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
        _ = try self.usage.bufferUsedAs(options.buffer, 0);
    }

    /// Dawn's `APISetIndexBuffer` (`RenderEncoderBase.cpp:581-640`).
    pub fn setIndexBuffer(
        self: *RenderEncoderBase,
        options: SetIndexBufferOptions,
    ) errors.Error!void {
        const bound = options.size orelse (options.buffer_size - options.offset);
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
        _ = try self.usage.bufferUsedAs(options.buffer, 0);
    }

    /// Dawn's `APISetPipeline` (`RenderEncoderBase.cpp:544-579`), whose
    /// attachment-state comparison is the rule the port fuses into one check
    /// (`RenderEncoderBase.cpp:551-556`).
    pub fn setPipeline(
        self: *RenderEncoderBase,
        options: SetRenderPipelineOptions,
    ) errors.Error!void {
        const pipeline_state = options.requirements.attachment_state;
        if (self.attachment_state != null and pipeline_state != null) {
            if (self.attachment_state != pipeline_state) return error.AttachmentFormatMismatch;
        }
        const cmd = try self.programmable.context.encode(
            commands.SetRenderPipelineCmd,
            self.programmable.id,
            .set_render_pipeline,
        );
        cmd.* = .{ .pipeline = options.pipeline, .attachment_state = pipeline_state };
        self.tracker.setPipeline(options.pipeline, options.requirements);
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
        try RenderEncoderBase.validateIndirectBuffer(
            options.indirect_buffer_size,
            options.indirect_offset,
            constants.draw_indirect_size,
        );
        try self.tracker.validateCanDraw();
        try self.recordMultiDrawIndirect(options, false);
    }

    /// Dawn's `APIMultiDrawIndexedIndirect` (`RenderEncoderBase.cpp:434-542`).
    pub fn multiDrawIndexedIndirect(self: *RenderEncoderBase, options: MultiDrawIndirectOptions) errors.Error!void {
        try RenderEncoderBase.validateIndirectBuffer(
            options.indirect_buffer_size,
            options.indirect_offset,
            constants.draw_indexed_indirect_size,
        );
        try self.tracker.validateCanDrawIndexed();
        try self.recordMultiDrawIndirect(options, true);
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
        try self.indirect.addIndirectDraw(buffer, offset, indexed);
        self.draw_count += 1;
    }

    fn recordMultiDrawIndirect(
        self: *RenderEncoderBase,
        options: MultiDrawIndirectOptions,
        indexed: bool,
    ) errors.Error!void {
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
        try self.indirect.addMultiDrawIndirect(
            options.indirect_buffer,
            options.indirect_offset,
            indexed,
            options.max_draw_count,
            options.draw_count_buffer,
            options.draw_count_offset,
        );
        self.draw_count += options.max_draw_count;
    }
};
