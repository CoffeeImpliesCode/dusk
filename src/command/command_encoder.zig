//! The top-level command encoder: the one door a caller opens to record a
//! command buffer.
//!
//! **What this file is.** The port of `src/dawn/native/CommandEncoder.{h,cpp}`:
//! `encoding_context.Context` is the stream it records into,
//! `render_encoder_base.RenderEncoderBase` is the render half of a pass, and
//! this is the value a caller holds to open both. It records intent and holds
//! no Vulkan.
//!
//! **Why `init` is infallible.** `Context.init` is `AllocatorError!Context`
//! (`encoding_context.zig:88`), and an encoder is a value the caller keeps on
//! its own stack frame, so `init` has no error to hand back that the caller
//! could act on. `ensureContext` builds the context on the first record call
//! instead, where an allocation failure is returned to the caller that asked to
//! record something. Waiting costs nothing: the only `try` in `Context.init` is
//! `Allocator.init` (`allocator.zig:63`), and that returns a struct literal — the
//! first block comes from `appendNewBlock` (`allocator.zig:178`) on the first
//! `allocate`.
//!
//! **What this file does not claim.** It does not claim to be Dawn's
//! `CommandEncoder`. Dawn's is a refcounted object with an error sink and a
//! label; this is a value the caller owns with a declared error set, which is
//! the departure `render_encoder_base.zig:19-23` makes for the pass encoder.
//! It records render and compute passes, copies, clears, writes, queries and debug labels.

const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const allocator_mod = @import("allocator.zig");
const attachment_state = @import("attachment_state.zig");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const query = @import("query.zig");
const compute_encoder = @import("compute_encoder.zig");
const render_encoder_base = @import("render_encoder_base.zig");
const usage = @import("usage.zig");

/// Everything a call on this type can fail with: the arena's error set, which
/// is every rule this module owns plus the one allocation failure every record
/// call carries (`allocator.zig:234`), and the two descriptor-shape rules
/// `attachment_state` owns (`attachment_state.zig:234-235`).
pub const Error = allocator_mod.AllocatorError || attachment_state.AttachmentError;

/// The wire value the compressed run starts at. `dawn.json` numbers the three
/// compressed families — BC, ETC2/EAC and ASTC — contiguously after every
/// uncompressed one (`src/api/enums.zig:931-982`), so naming the run's two
/// ends names every member of it.
const first_compressed_format: u32 = @backingInt(api.TextureFormat.bc1_rgba_unorm);

/// The wire value it ends at, and its length in wire values.
const last_compressed_format: u32 = @backingInt(api.TextureFormat.astc_12x12_unorm_srgb);
const compressed_format_count: u32 = last_compressed_format - first_compressed_format + 1;

comptime {
    // The two checks are what make the run a claim and not a hope. The member
    // under it is the last uncompressed format (`src/api/enums.zig:930`), and
    // the domain holds the member count `src/api/enums.zig:986` records, so a
    // format added anywhere upstream stops the build here instead of being read
    // as uncompressed.
    if (first_compressed_format != @backingInt(api.TextureFormat.depth32_float_stencil8) + 1) {
        @compileError("a texture format appeared below the compressed run");
    }
    // 102, not upstream's 110: sixteen of Dawn's entries share a tag with an
    // earlier one and the generator drops the later of each pair, so the enum
    // has 110 - 8 = 102 fields over tags 0 to 101. Asserting the entry count
    // would fire on a correct regeneration.
    if (@typeInfo(api.TextureFormat).@"enum".field_names.len != 102) {
        @compileError("a texture format appeared; classify it before the build passes");
    }
}

/// Whether a wire format names a compressed format.
///
/// Dawn reads the format object (`CommandEncoder.cpp:415`); the port cannot
/// reach the texture, so it reads the number it recorded, which is the same
/// fact for a replay and the same field the copy rule is keyed off.
fn isCompressed(format: u32) bool {
    // Wrapping on purpose: a value below the run subtracts into a number larger
    // than the run's length, which is the answer a value above it gets too.
    return format -% first_compressed_format < compressed_format_count;
}

/// What `beginRenderPass` takes.
///
/// The colour attachments are the recorded payload's own half
/// (`commands.zig:155-168`), so a caller fills a struct the stream already
/// names and the descriptor carries no second shape to keep in step.
pub const BeginRenderPassOptions = struct {
    color_attachments: []const commands.RenderPassColorAttachmentInfo = &.{},
    depth_stencil_attachment: commands.RenderPassDepthStencilAttachmentInfo = .{},
    /// The pass's size, which Dawn reads off the attachment views
    /// (`CommandEncoder.cpp:172`).
    width: u32 = 0,
    height: u32 = 0,
    /// Dawn's `RenderPassMaxDrawCount` (`RenderPassEncoder.h:121`), which the
    /// pass checks at `end` rather than at each draw.
    max_draw_count: u64 = constants.default_max_draw_count,
    occlusion_query_set: commands.Ref = null,
    occlusion_query_count: u32 = 0,
    occlusion_query_type: query.QueryType = .occlusion,
    timestamp_writes: commands.TimestampWrites = .{},
    timestamp_query_count: u32 = 0,
    timestamp_query_type: query.QueryType = .timestamp,
};

/// What `copyTextureToBuffer` takes.
///
/// Both halves are the recorded payload's own halves (`commands.zig:293-294`),
/// so the copy is recorded as it was described and the mapping is one assignment.
pub const CopyTextureToBufferOptions = struct {
    source: commands.TextureCopy,
    destination: commands.BufferCopy,
    copy_size: commands.Extent3D,
};

pub const BeginComputePassOptions = struct {
    timestamp_writes: commands.TimestampWrites = .{},
    timestamp_query_count: u32 = 0,
    timestamp_query_type: query.QueryType = .timestamp,
    max_workgroups_per_dimension: u32 = 65535,
    label: []const u8 = "",
};

pub const WriteBufferOptions = struct {
    buffer: commands.Ref,
    offset: u64 = 0,
    data: []const u8,
};

pub const WriteTimestampOptions = struct {
    query_set: commands.Ref,
    query_index: u32,
    query_count: u32,
    query_type: query.QueryType = .timestamp,
    timestamp_query_enabled: bool = false,
};

pub const ResolveQuerySetOptions = struct {
    query_set: commands.Ref,
    query_count_of_set: u32,
    first_query: u32,
    query_count: u32,
    destination: commands.Ref,
    destination_size: u64,
    destination_usage: api.bitmask.BufferUsage,
    destination_offset: u64 = 0,
};

fn validateTimestampWrites(
    writes: commands.TimestampWrites,
    query_count: u32,
    query_type: query.QueryType,
    enabled: bool,
) errors.Error!void {
    if (writes.isEmpty()) return;
    if (!enabled) return error.RequiredFeatureMissing;
    if (query_type != .timestamp) return error.QuerySetTypeMismatch;
    const beginning = writes.beginning_of_pass_write_index;
    const end = writes.end_of_pass_write_index;
    if (beginning == commands.undefined_query_index and end == commands.undefined_query_index) {
        return error.TimestampIndexOutOfRange;
    }
    if (beginning != commands.undefined_query_index and beginning >= query_count) {
        return error.TimestampIndexOutOfRange;
    }
    if (end != commands.undefined_query_index and end >= query_count) {
        return error.TimestampIndexOutOfRange;
    }
    if (beginning != commands.undefined_query_index and beginning == end) {
        return error.QueryIndexOverwritten;
    }
}
/// The top-level encoder: owns the context and hands out passes.
pub const CommandEncoder = struct {
    /// The allocator the context is built from. The context holds its own copy
    /// and frees with it; this one is what builds it on the first record call.
    allocator: std.mem.Allocator,
    device: core.CoreDeviceBorrow,
    /// The bytes one block of the stream starts at. `Allocator.init` raises it
    /// to whatever the widest payload needs (`allocator.zig:63-71`), so this is
    /// a granularity and not a bound. A page is the one size every allocator
    /// below `command` hands back whole.
    block_size: usize,
    compatibility_mode: bool,
    timestamp_query_enabled: bool,
    /// The context, once a record call has created it. See the file header for
    /// why `init` does not build it.
    context: ?encoding_context.Context = null,
    /// Which encoder records the top-level commands. Zero until the context
    /// exists.
    top_level: encoding_context.EncoderId = encoding_context.no_encoder,

    pub const Options = struct {
        /// Dawn derives the profile from the absence of a feature
        /// (`Device.cpp:1840-1842`), and `command` cannot reach a device, so
        /// the caller passes the fact.
        compatibility_mode: bool = false,
        block_size: usize = 4096,
        timestamp_query_enabled: bool = false,
    };

    /// The caller keeps the borrowed core device alive through guarded cleanup.
    pub fn init(
        allocator: std.mem.Allocator,
        device: core.CoreDeviceBorrow,
        options: Options,
    ) CommandEncoder {
        return .{
            .allocator = allocator,
            .device = device,
            .block_size = options.block_size,
            .compatibility_mode = options.compatibility_mode,
            .timestamp_query_enabled = options.timestamp_query_enabled,
        };
    }

    /// Cleanup uses the original device guard and the allocator that created the stream.
    pub fn deinit(
        self: *CommandEncoder,
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
    ) void {
        guard.assertOwns(self.device.objectList());
        std.debug.assert(allocator.vtable == self.allocator.vtable);
        if (self.context) |*context| context.deinit(io, guard);
        self.* = undefined;
    }

    /// Dawn's `APIBeginRenderPass` (`CommandEncoder.cpp:1460`) then `BeginRenderPass`
    /// (`:1467`): commit what came before the pass, record the pass's own
    /// descriptor on the top-level encoder, then enter the pass. This is the
    /// call both acceptance shards record through.
    ///
    /// The set is `errors.Error || attachment_state.AttachmentError`, and not
    /// the module's `Error`: `encodeTopLevel` is declared `errors.Error`
    /// (`encoding_context.zig:192-197`), so a `try` on it inherits the lifecycle
    /// rules `core.Error` owns and `Error` cannot name — `EncoderAlreadyFinished`
    /// is the one only `core` has (`core/errors.zig:24`). `ensureContext` is
    /// declared `Error`, and the body raises `TooManyAttachments` of its own
    /// (`attachment_state.zig:234-235`).
    pub fn beginRenderPass(
        self: *CommandEncoder,
        io: std.Io,
        guard: *const core.ObjectGuard,
        attachment: *attachment_state.CanonicalAttachmentState,
        options: BeginRenderPassOptions,
    ) (errors.Error || attachment_state.AttachmentError)!render_encoder_base.RenderEncoderBase {
        if (guard.objects != self.device.objectList()) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.device.objectList());
        if (attachment.header.tracking != self.device.objectList()) {
            return error.ResourceDeviceMismatch;
        }
        if (self.context) |context| {
            if (context.device.objectList() != self.device.objectList()) {
                return error.ResourceDeviceMismatch;
            }
        }
        const occlusion_state = try query.OcclusionQueryState.init(.{
            .attached = options.occlusion_query_set != null,
            .query_type = options.occlusion_query_type,
            .query_count = options.occlusion_query_count,
        });
        try validateTimestampWrites(
            options.timestamp_writes,
            options.timestamp_query_count,
            options.timestamp_query_type,
            self.timestamp_query_enabled,
        );
        // `max_color_attachments` is the bound (`Constants.h:43`) and the
        // descriptor rule for naming more than it is the error, so the loop is
        // bounded rather than the caller.
        var recorded: [constants.max_color_attachments]commands.RenderPassColorAttachmentInfo = @splat(.{});
        var count: usize = 0;
        for (options.color_attachments) |color_attachment| {
            if (count == recorded.len) return error.TooManyAttachments;
            recorded[count] = color_attachment;
            count += 1;
        }

        // Prepare descriptor metadata before recording or entering the pass.
        var pass_usage = usage.RenderPassResourceUsageTracker.init(self.allocator);
        defer pass_usage.deinit(io, guard);
        try pass_usage.usage.retainAttachmentLocked(guard, attachment);
        const timestamps = options.timestamp_writes;
        if (!timestamps.isEmpty()) {
            try pass_usage.trackQueryAvailability(
                timestamps.query_set,
                options.timestamp_query_count,
            );
            if (timestamps.beginning_of_pass_write_index != commands.undefined_query_index) {
                pass_usage.markQueryAvailable(
                    timestamps.query_set,
                    timestamps.beginning_of_pass_write_index,
                );
            }
            if (timestamps.end_of_pass_write_index != commands.undefined_query_index) {
                pass_usage.markQueryAvailable(
                    timestamps.query_set,
                    timestamps.end_of_pass_write_index,
                );
            }
        }

        const context = try self.ensureContext();
        try context.validateCanEncodeOn(self.top_level, true);
        errdefer {
            context.status = .error_in_recording;
            context.current_id = context.top_level_id;
        }
        try context.willBeginRenderPass();

        const begin = try context.encodeTopLevel(
            commands.BeginRenderPassCmd,
            self.top_level,
            .begin_render_pass,
        );
        begin.* = .{
            .attachment_state = attachment,
            .color_attachments = recorded,
            .depth_stencil_attachment = options.depth_stencil_attachment,
            .width = options.width,
            .height = options.height,
            .occlusion_query_set = options.occlusion_query_set,
            // No producer tracks the union of draws and clears yet.
            .force_full_render_area = true,
            .render_area = .{ .width = options.width, .height = options.height },
            .timestamp_writes = options.timestamp_writes,
        };

        var pass = render_encoder_base.RenderEncoderBase.initOwned(
            self.allocator,
            context,
            self.compatibility_mode,
            pass_usage,
        );
        pass_usage = usage.RenderPassResourceUsageTracker.init(self.allocator);
        pass.timestamp_query_enabled = self.timestamp_query_enabled;
        pass.max_draw_count = options.max_draw_count;
        pass.occlusion_query_set = options.occlusion_query_set;
        pass.occlusion_state = occlusion_state;
        pass.width = options.width;
        pass.height = options.height;
        return pass;
    }

    /// Dawn's `APICopyTextureToBuffer` (`CommandEncoder.cpp:1956`) with the
    /// compatibility-mode format rule in front of it (`CommandEncoder.cpp:413`).
    ///
    /// The rule is keyed off the recorded wire format because that is the field
    /// a replay reads, and `command` cannot reach the texture object.
    ///
    /// The set is the one `beginRenderPass` declares above, for the same two
    /// reasons: `encodeTopLevel` brings in the half of `errors.Error` that
    /// `core.Error` owns, and `ensureContext` brings in `AttachmentError`, which
    /// this body cannot raise and inherits anyway. `CompressedTextureCopy` is
    /// already in `errors.Error` (`errors.zig:97`).
    pub fn copyTextureToBuffer(
        self: *CommandEncoder,
        options: CopyTextureToBufferOptions,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        if (self.compatibility_mode and isCompressed(options.source.format)) {
            return error.CompressedTextureCopy;
        }
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.CopyTextureToBufferCmd,
            self.top_level,
            .copy_texture_to_buffer,
        );
        cmd.* = .{
            .source = options.source,
            .destination = options.destination,
            .copy_size = options.copy_size,
        };
    }

    pub fn beginComputePass(
        self: *CommandEncoder,
        options: BeginComputePassOptions,
    ) (errors.Error || attachment_state.AttachmentError)!compute_encoder.ComputeEncoder {
        try validateTimestampWrites(
            options.timestamp_writes,
            options.timestamp_query_count,
            options.timestamp_query_type,
            self.timestamp_query_enabled,
        );
        if (options.label.len >= std.math.maxInt(u32)) return error.CopyExtentOutOfRange;
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.BeginComputePassCmd,
            self.top_level,
            .begin_compute_pass,
        );
        errdefer context.status = .error_in_recording;
        cmd.* = .{ .timestamp_writes = options.timestamp_writes };
        if (options.label.len != 0) {
            try commands.addNullTerminatedString(context.pendingAllocator(), options.label, &cmd.label_length);
        }
        return compute_encoder.ComputeEncoder.init(self.allocator, context, .{
            .max_workgroups_per_dimension = options.max_workgroups_per_dimension,
            .timestamp_query_enabled = self.timestamp_query_enabled,
        });
    }

    pub fn copyBufferToBuffer(
        self: *CommandEncoder,
        options: commands.CopyBufferToBufferCmd,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.CopyBufferToBufferCmd,
            self.top_level,
            .copy_buffer_to_buffer,
        );
        cmd.* = options;
    }

    pub fn copyBufferToTexture(
        self: *CommandEncoder,
        options: commands.CopyBufferToTextureCmd,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.CopyBufferToTextureCmd,
            self.top_level,
            .copy_buffer_to_texture,
        );
        cmd.* = options;
    }

    pub fn copyTextureToTexture(
        self: *CommandEncoder,
        options: commands.CopyTextureToTextureCmd,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.CopyTextureToTextureCmd,
            self.top_level,
            .copy_texture_to_texture,
        );
        cmd.* = options;
    }

    /// Record browser-copy intent with inline options and borrowed view references.
    /// Lifecycle or nonfinite-option errors append no command.
    pub fn copyTextureForBrowser(
        self: *CommandEncoder,
        options: commands.CopyTextureForBrowserCmd,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        try context.validateCanEncodeOn(self.top_level, true);
        try options.options.validate();
        const cmd = try context.encodeTopLevel(
            commands.CopyTextureForBrowserCmd,
            self.top_level,
            .copy_texture_for_browser,
        );
        cmd.* = options;
    }

    /// Record browser-copy intent with a borrowed external header and destination view.
    /// Lifecycle or nonfinite-option errors append no command.
    pub fn copyExternalTextureForBrowser(
        self: *CommandEncoder,
        options: commands.CopyExternalTextureForBrowserCmd,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        try context.validateCanEncodeOn(self.top_level, true);
        try options.options.validate();
        const cmd = try context.encodeTopLevel(
            commands.CopyExternalTextureForBrowserCmd,
            self.top_level,
            .copy_external_texture_for_browser,
        );
        cmd.* = options;
    }

    pub fn clearBuffer(
        self: *CommandEncoder,
        options: commands.ClearBufferCmd,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.ClearBufferCmd,
            self.top_level,
            .clear_buffer,
        );
        cmd.* = options;
    }

    /// Copy a top-level group label into the stream. Groups can surround passes.
    /// Allocation failure after recording starts invalidates the encoder.
    pub fn pushDebugGroup(
        self: *CommandEncoder,
        label: []const u8,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.PushDebugGroupCmd,
            self.top_level,
            .push_debug_group,
        );
        errdefer context.status = .error_in_recording;
        var length: u32 = 0;
        try commands.addNullTerminatedString(context.pendingAllocator(), label, &length);
        cmd.* = .{ .length = length };
        try context.pushDebugGroupLabel(label);
    }

    /// Close a top-level group. A locked encoder or empty stack records nothing.
    pub fn popDebugGroup(
        self: *CommandEncoder,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        try context.validateCanEncodeOn(self.top_level, true);
        if (context.debugGroupDepth() == 0) return error.DebugGroupUnbalanced;
        _ = try context.encodeTopLevel(commands.PopDebugGroupCmd, self.top_level, .pop_debug_group);
        try context.popDebugGroupLabel();
    }

    /// Copy a top-level marker label into the stream.
    /// Allocation failure after recording starts invalidates the encoder.
    pub fn insertDebugMarker(
        self: *CommandEncoder,
        label: []const u8,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.InsertDebugMarkerCmd,
            self.top_level,
            .insert_debug_marker,
        );
        errdefer context.status = .error_in_recording;
        var length: u32 = 0;
        try commands.addNullTerminatedString(context.pendingAllocator(), label, &length);
        cmd.* = .{ .length = length };
    }

    pub fn writeBuffer(
        self: *CommandEncoder,
        options: WriteBufferOptions,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        if (options.data.len > std.math.maxInt(u32)) return error.CopyExtentOutOfRange;
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.WriteBufferCmd,
            self.top_level,
            .write_buffer,
        );
        errdefer context.status = .error_in_recording;
        cmd.* = .{ .buffer = options.buffer, .offset = options.offset, .size = @intCast(options.data.len) };
        const data = try context.encodeData(u8, options.data.len);
        @memcpy(data, options.data);
    }

    pub fn resolveQuerySet(
        self: *CommandEncoder,
        options: ResolveQuerySetOptions,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        try query.validateResolve(options.query_count_of_set, .{
            .first_query = options.first_query,
            .query_count = options.query_count,
            .destination_offset = options.destination_offset,
        }, .{ .size = options.destination_size, .usage = options.destination_usage });
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.ResolveQuerySetCmd,
            self.top_level,
            .resolve_query_set,
        );
        cmd.* = .{
            .query_set = options.query_set,
            .first_query = options.first_query,
            .query_count = options.query_count,
            .destination = options.destination,
            .destination_offset = options.destination_offset,
        };
    }

    pub fn writeTimestamp(
        self: *CommandEncoder,
        options: WriteTimestampOptions,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        if (!self.timestamp_query_enabled and !options.timestamp_query_enabled) {
            return error.RequiredFeatureMissing;
        }
        if (options.query_type != .timestamp) return error.QuerySetTypeMismatch;
        if (options.query_index >= options.query_count) return error.TimestampIndexOutOfRange;
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.WriteTimestampCmd,
            self.top_level,
            .write_timestamp,
        );
        cmd.* = .{ .query_set = options.query_set, .query_index = options.query_index };
    }

    /// Dawn's `APIFinish` (`CommandEncoder.cpp:2406`): the blocks, the usages
    /// and the status leave together, so one door is enough. `engine` turns what
    /// comes back into a command buffer at M18.
    /// Reject an open pass or unbalanced groups before transferring ownership.
    pub fn finish(
        self: *CommandEncoder,
    ) (errors.Error || attachment_state.AttachmentError)!encoding_context.Finished {
        const context = try self.ensureContext();
        try context.validateCanEncodeOn(self.top_level, true);
        if (context.debugGroupDepth() != 0) return error.DebugGroupUnbalanced;
        return context.finish();
    }

    /// The context, built on the first record call. A record after `finish` is
    /// refused by the context's own status machine (`encoding_context.zig:151-155`),
    /// which is why this holds no finished flag of its own.
    fn ensureContext(self: *CommandEncoder) Error!*encoding_context.Context {
        if (self.context == null) {
            self.context = try encoding_context.Context.init(
                self.allocator,
                self.device,
                self.block_size,
                self.compatibility_mode,
            );
            self.top_level = self.context.?.open();
        }
        return &self.context.?;
    }
};

test "top-level debug groups preserve pass boundaries and reject invalid lifecycle" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectError(error.DebugGroupUnbalanced, encoder.popDebugGroup());
    var label = [_]u8{ 't', 'o', 'p' };
    try encoder.pushDebugGroup(&label);
    label[0] = 'x';
    try std.testing.expectError(error.DebugGroupUnbalanced, encoder.finish());
    var pass = try encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{
        .width = 7,
        .height = 5,
    });
    try std.testing.expectError(error.PassLocked, encoder.insertDebugMarker("locked"));
    try std.testing.expectError(error.PassLocked, encoder.finish());
    try std.testing.expectError(error.DebugGroupUnbalanced, pass.popDebugGroup());
    try pass.pushDebugGroup("pass");
    try pass.popDebugGroup();
    try pass.end(std.testing.io, &guard);
    try encoder.insertDebugMarker("after");
    try encoder.popDebugGroup();
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectError(error.EncoderAlreadyFinished, encoder.insertDebugMarker("late"));
    try std.testing.expectError(error.EncoderAlreadyFinished, encoder.finish());
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .push_debug_group), try iterator.nextTag());
    const push = try iterator.nextCommand(commands.PushDebugGroupCmd);
    try std.testing.expectEqualStrings(
        "top",
        try commands.nextNullTerminatedString(&iterator.iterator, push.length),
    );
    try std.testing.expectEqual(@as(?commands.Tag, .begin_render_pass), try iterator.nextTag());
    const begin = try iterator.nextCommand(commands.BeginRenderPassCmd);
    try std.testing.expect(begin.force_full_render_area);
    try std.testing.expectEqual(@as(u32, 7), begin.render_area.width);
    try std.testing.expectEqual(@as(u32, 5), begin.render_area.height);
    const expected = [_]commands.Tag{
        .push_debug_group, .pop_debug_group,
        .end_render_pass,  .insert_debug_marker,
        .pop_debug_group,
    };
    for (expected) |tag| {
        try std.testing.expectEqual(@as(?commands.Tag, tag), try iterator.nextTag());
        try commands.skip(&iterator.iterator, tag);
    }
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}

test "top-level producers record copy clear and owned write bytes" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    try encoder.copyBufferToBuffer(.{ .source_offset = 4, .destination_offset = 8, .size = 12 });
    try encoder.copyBufferToTexture(.{});
    try encoder.copyTextureToTexture(.{});
    try encoder.clearBuffer(.{ .offset = 4, .size = 8 });
    var bytes = [_]u8{ 1, 2, 3, 4 };
    try encoder.writeBuffer(.{ .buffer = null, .offset = 4, .data = &bytes });
    bytes[0] = 9;
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &guard);
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .copy_buffer_to_buffer), try iterator.nextTag());
    const copy = try iterator.nextCommand(commands.CopyBufferToBufferCmd);
    try std.testing.expectEqual(@as(u64, 12), copy.size);
    try std.testing.expectEqual(@as(?commands.Tag, .copy_buffer_to_texture), try iterator.nextTag());
    _ = try iterator.nextCommand(commands.CopyBufferToTextureCmd);
    try std.testing.expectEqual(@as(?commands.Tag, .copy_texture_to_texture), try iterator.nextTag());
    _ = try iterator.nextCommand(commands.CopyTextureToTextureCmd);
    try std.testing.expectEqual(@as(?commands.Tag, .clear_buffer), try iterator.nextTag());
    _ = try iterator.nextCommand(commands.ClearBufferCmd);
    try std.testing.expectEqual(@as(?commands.Tag, .write_buffer), try iterator.nextTag());
    const write = try iterator.nextCommand(commands.WriteBufferCmd);
    try std.testing.expectEqual(@as(u32, 4), write.size);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, try iterator.nextData(u8, 4));
}

test "query producers reject invalid ranges before recording" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{
        .timestamp_query_enabled = true,
    });
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectError(error.TimestampIndexOutOfRange, encoder.writeTimestamp(.{
        .query_set = null,
        .query_index = 2,
        .query_count = 2,
    }));
    try std.testing.expectError(error.ResolveQueryCountAboveRemaining, encoder.resolveQuerySet(.{
        .query_set = null,
        .query_count_of_set = 2,
        .first_query = 1,
        .query_count = 2,
        .destination = null,
        .destination_size = 16,
        .destination_usage = .{ .query_resolve = true },
    }));
    try std.testing.expect(encoder.context == null);
}

test "pass descriptors reject timestamp set in occlusion slot" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    var object: u8 = 0;
    try std.testing.expectError(error.QuerySetTypeMismatch, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        .{
            .occlusion_query_set = &object,
            .occlusion_query_type = .timestamp,
        },
    ));
    try std.testing.expect(encoder.context == null);
}

test "query producers preserve resolve and timestamp payloads" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{
        .timestamp_query_enabled = true,
    });
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    try encoder.resolveQuerySet(.{
        .query_set = null,
        .query_count_of_set = 4,
        .first_query = 1,
        .query_count = 2,
        .destination = null,
        .destination_size = 272,
        .destination_offset = 256,
        .destination_usage = .{ .query_resolve = true },
    });
    try encoder.writeTimestamp(.{ .query_set = null, .query_index = 3, .query_count = 4 });
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &guard);
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .resolve_query_set), try iterator.nextTag());
    const resolve = try iterator.nextCommand(commands.ResolveQuerySetCmd);
    try std.testing.expectEqual(@as(u32, 1), resolve.first_query);
    try std.testing.expectEqual(@as(u32, 2), resolve.query_count);
    try std.testing.expectEqual(@as(u64, 256), resolve.destination_offset);
    try std.testing.expectEqual(@as(?commands.Tag, .write_timestamp), try iterator.nextTag());
    const timestamp = try iterator.nextCommand(commands.WriteTimestampCmd);
    try std.testing.expectEqual(@as(u32, 3), timestamp.query_index);
}

test "compute pass records timestamp descriptor and owns label" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{
        .timestamp_query_enabled = true,
    });
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    var query_object: u8 = 0;
    var label = [_]u8{ 'p', 'a', 's', 's' };
    var pass = try encoder.beginComputePass(.{
        .timestamp_writes = .{
            .query_set = &query_object,
            .beginning_of_pass_write_index = 0,
            .end_of_pass_write_index = 1,
        },
        .timestamp_query_count = 2,
        .label = &label,
    });
    defer pass.deinit();
    label[0] = 'x';
    try pass.end();
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &guard);
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .begin_compute_pass), try iterator.nextTag());
    const begin = try iterator.nextCommand(commands.BeginComputePassCmd);
    try std.testing.expectEqual(@as(u32, 0), begin.timestamp_writes.beginning_of_pass_write_index);
    try std.testing.expectEqual(@as(u32, 1), begin.timestamp_writes.end_of_pass_write_index);
    try std.testing.expectEqualSlices(u8, "pass\x00", try iterator.nextData(u8, begin.label_length));
    try std.testing.expectEqual(@as(?commands.Tag, .end_compute_pass), try iterator.nextTag());
    _ = try iterator.nextCommand(commands.EndComputePassCmd);
}

test "render pass receives query state and attachment dimensions" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    var query_object: u8 = 0;
    var pass = try encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{
        .occlusion_query_set = &query_object,
        .occlusion_query_count = 4,
        .width = 64,
        .height = 32,
    });
    try std.testing.expect(pass.occlusion_state.attached);
    try std.testing.expectEqual(@as(u32, 4), pass.occlusion_state.query_count);
    try std.testing.expectEqual(@as(u32, 64), pass.width);
    try std.testing.expectEqual(@as(u32, 32), pass.height);
    try pass.end(std.testing.io, &guard);
}

test "render descriptor timestamps validate before entering a pass" {
    var object: u8 = 0;
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{
        .timestamp_query_enabled = true,
    });
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    var options: BeginRenderPassOptions = .{
        .timestamp_writes = .{
            .query_set = &object,
            .beginning_of_pass_write_index = 0,
            .end_of_pass_write_index = 1,
        },
        .timestamp_query_count = 2,
    };
    options.timestamp_query_type = .occlusion;
    try std.testing.expectError(error.QuerySetTypeMismatch, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        options,
    ));
    options.timestamp_query_type = .timestamp;
    options.timestamp_query_count = 1;
    try std.testing.expectError(error.TimestampIndexOutOfRange, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        options,
    ));
    options.timestamp_query_count = 2;
    options.timestamp_writes.end_of_pass_write_index = 0;
    try std.testing.expectError(error.QueryIndexOverwritten, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        options,
    ));
    options.timestamp_writes.beginning_of_pass_write_index = commands.undefined_query_index;
    options.timestamp_writes.end_of_pass_write_index = commands.undefined_query_index;
    try std.testing.expectError(error.TimestampIndexOutOfRange, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        options,
    ));
    options.timestamp_writes.beginning_of_pass_write_index = 0;
    encoder.timestamp_query_enabled = false;
    try std.testing.expectError(error.RequiredFeatureMissing, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        options,
    ));
    try std.testing.expect(encoder.context == null);
}

test "render timestamp writes inherit parent feature enablement" {
    for ([_]bool{ false, true }) |enabled| {
        var fixture: CoreFixture = .{};
        try fixture.init(std.testing.allocator);
        var guard = core.ObjectGuard.lockUncancelable(
            std.testing.io,
            fixture.device.arena.objectList(),
        );
        defer guard.unlock(std.testing.io);
        defer fixture.deinit(&guard);
        var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{
            .timestamp_query_enabled = enabled,
        });
        defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
        var object: u8 = 0;
        var pass = try encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{});
        const options: render_encoder_base.WriteTimestampOptions = .{
            .query_set = &object,
            .query_count = 2,
            .query_index = 0,
        };
        if (enabled) {
            try pass.writeTimestamp(options);
        } else {
            try std.testing.expectError(error.RequiredFeatureMissing, pass.writeTimestamp(options));
        }
        try pass.end(std.testing.io, &guard);
    }
}

test "render descriptor timestamps reserve both indices and export reset bitmap" {
    for ([_][2]u32{
        .{ 0, 3 },
        .{ 0, commands.undefined_query_index },
        .{ commands.undefined_query_index, 3 },
    }) |indices| {
        try recordRenderDescriptorTimestamps(std.testing.allocator, indices);
    }
}

test "render descriptor timestamp allocation failures leave no active pass" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordRenderDescriptorTimestamps,
        .{[2]u32{ 0, 3 }},
    );
}

fn recordRenderDescriptorTimestamps(allocator: std.mem.Allocator, indices: [2]u32) !void {
    var fixture: CoreFixture = .{};
    try fixture.init(allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(allocator, fixture.device.borrow(), .{
        .timestamp_query_enabled = true,
    });
    defer encoder.deinit(allocator, std.testing.io, &guard);
    var object: u8 = 0;
    var pass = encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{
        .timestamp_writes = .{
            .query_set = &object,
            .beginning_of_pass_write_index = indices[0],
            .end_of_pass_write_index = indices[1],
        },
        .timestamp_query_count = 4,
    }) catch |err| {
        if (encoder.context) |context| {
            try std.testing.expectEqual(context.top_level_id, context.current_id);
        }
        return err;
    };
    var live = true;
    defer if (live) pass.deinit(std.testing.io, &guard);
    for (indices) |index| {
        if (index == commands.undefined_query_index) continue;
        try std.testing.expectError(error.QueryIndexOverwritten, pass.writeTimestamp(.{
            .query_set = &object,
            .query_count = 4,
            .query_index = index,
        }));
    }
    live = false;
    try pass.end(std.testing.io, &guard);
    var finished = try encoder.finish();
    defer finished.deinit(allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(usize, 1), finished.render_pass_usages.items.len);
    const tracked = finished.render_pass_usages.items[0];
    try std.testing.expectEqual(@as(usize, 1), tracked.query_sets.items.len);
    try std.testing.expectEqual(@as(commands.Ref, &object), tracked.query_sets.items[0]);
    try std.testing.expectEqualSlices(bool, &.{
        indices[0] == 0, false, false, indices[1] == 3,
    }, tracked.query_availabilities.items[0].items);
}

test "producer allocations release all ownership on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, recordProducerAllocations, .{});
}

fn recordProducerAllocations(allocator: std.mem.Allocator) !void {
    var fixture: CoreFixture = .{};
    try fixture.init(allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(allocator, std.testing.io, &guard);
    try encoder.writeBuffer(.{ .buffer = null, .data = &.{ 1, 2, 3, 4 } });
    var pipeline_object: u8 = 0;
    var buffer_object: u8 = 0;
    var render = try encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{
        .width = 16,
        .height = 16,
    });
    var render_live = true;
    defer if (render_live) render.deinit(std.testing.io, &guard);
    try render.setPipeline(&guard, .{
        .pipeline = &pipeline_object,
        .requirements = .{},
        .attachment_state = fixture.attachment,
    });
    try render.drawIndirect(.{
        .indirect_buffer = &buffer_object,
        .indirect_buffer_size = constants.draw_indirect_size,
        .indirect_offset = 0,
    });
    render_live = false;
    try render.end(std.testing.io, &guard);
    var pass = try encoder.beginComputePass(.{ .label = "compute" });
    defer pass.deinit();
    try pass.setPipeline(.{ .pipeline = &pipeline_object });
    try pass.dispatchIndirect(.{
        .buffer = &buffer_object,
        .buffer_size = 12,
        .usage = 1 << 8,
    });
    try pass.end();
    var finished = try encoder.finish();
    defer finished.deinit(allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(usize, 1), finished.render_pass_usages.items.len);
    try std.testing.expectEqual(@as(usize, 1), finished.compute_pass_usages.items.len);
    try std.testing.expectEqual(@as(usize, 1), finished.indirect_draws.items.len);
    var iterator = finished.iterator(allocator);
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .write_buffer), try iterator.nextTag());
    const write = try iterator.nextCommand(commands.WriteBufferCmd);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, try iterator.nextData(u8, write.size));
}

const CoreFixture = struct {
    mutex: std.Io.Mutex = .init,
    device: @import("../core/root.zig").Device = undefined,
    attachment: *attachment_state.CanonicalAttachmentState = undefined,
    allocator: std.mem.Allocator = undefined,

    fn init(self: *CoreFixture, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.device = core.Device.init(allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, self.device.arena.objectList());
        defer guard.unlock(std.testing.io);
        errdefer self.device.deinit(allocator, &guard) catch @panic("fixture references leaked");
        const value = try attachment_state.AttachmentState.fromRenderPipeline(.{
            .color_formats = &.{1},
            .depth_stencil_format = 0,
            .sample_count = 1,
            .expand_resolve = .{},
            .pls = null,
        }, .{ .max_color_attachments = 8, .max_storage_attachments = 4, .max_pls_bytes = 16 });
        self.attachment = try self.device.create(
            allocator,
            &guard,
            attachment_state.CanonicalAttachmentState,
            .{ .kind = .attachment_state, .state = .alive, .initial_reference = .user },
        );
        self.attachment.value = value;
        self.attachment.cache_hash = 0;
        self.attachment.cache_next = null;
        self.attachment.header.attach(&guard, std.testing.io);
    }

    fn deinit(self: *CoreFixture, guard: *const @import("../core/root.zig").ObjectGuard) void {
        self.attachment.header.releaseUserLocked(guard, std.testing.io) catch
            @panic("fixture alias missing");
        self.device.deinit(self.allocator, guard) catch @panic("fixture references leaked");
    }

    fn uncaptured(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: *anyopaque,
        data: core.ErrorView,
    ) void {
        _ = allocator;
        _ = io;
        _ = context;
        _ = data;
        @panic("unexpected fixture error");
    }
};

test "render attachment lease moves to finished and abandoned pass invalidates recording" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    var pass = try encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{});
    try std.testing.expectEqual(@as(u32, 2), fixture.attachment.header.reference_count);
    try pass.end(std.testing.io, &guard);
    pass.deinit(std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 2), fixture.attachment.header.reference_count);
    var finished = try encoder.finish();
    finished.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 1), fixture.attachment.header.reference_count);

    var abandoned = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer abandoned.deinit(std.testing.allocator, std.testing.io, &guard);
    var open = try abandoned.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{});
    open.deinit(std.testing.io, &guard);
    try std.testing.expectError(error.EncoderInvalidated, abandoned.finish());
    try std.testing.expectEqual(@as(u32, 1), fixture.attachment.header.reference_count);
}

test "render begin refuses foreign retired and saturated attachment owners without recording" {
    var fixture: CoreFixture = .{};
    try fixture.init(std.testing.allocator);
    var foreign: CoreFixture = .{};
    try foreign.init(std.testing.allocator);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, fixture.device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer fixture.deinit(&guard);
    var foreign_guard = core.ObjectGuard.lockUncancelable(
        std.testing.io,
        foreign.device.arena.objectList(),
    );
    defer foreign_guard.unlock(std.testing.io);
    defer foreign.deinit(&foreign_guard);
    var encoder = CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectError(error.ResourceDeviceMismatch, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        foreign.attachment,
        .{},
    ));
    try std.testing.expectError(error.ResourceDeviceMismatch, encoder.beginRenderPass(
        std.testing.io,
        &foreign_guard,
        fixture.attachment,
        .{},
    ));
    try std.testing.expect(encoder.context == null);
    try std.testing.expectEqual(@as(u32, 1), fixture.attachment.header.reference_count);

    fixture.attachment.header.reference_count = std.math.maxInt(u32);
    const refusal = encoder.beginRenderPass(std.testing.io, &guard, fixture.attachment, .{});
    fixture.attachment.header.reference_count = 1;
    try std.testing.expectError(error.ReferenceCountOverflow, refusal);
    try std.testing.expect(encoder.context == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.device.arena.objects.total_reference_count);

    fixture.attachment.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(error.ResourceDestroyed, encoder.beginRenderPass(
        std.testing.io,
        &guard,
        fixture.attachment,
        .{},
    ));
    try std.testing.expect(encoder.context == null);
    try std.testing.expectEqual(@as(u32, 1), fixture.attachment.header.reference_count);
}
