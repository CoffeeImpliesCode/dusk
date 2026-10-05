//! What every pass encoder can do: the debug-group stack, bind groups, and
//! immediates.
//!
//! **What this file is.** The port of
//! `src/dawn/native/ProgrammableEncoder.{h,cpp}`. It is the shared half of
//! `RenderPassEncoder` and `ComputePassEncoder` — Dawn's
//! `ProgrammableEncoder` (`ProgrammableEncoder.h:47`) — and it holds the two
//! places Dawn splits validation from recording explicitly
//! (`ProgrammableEncoder.cpp:226-242` and `:244-259`).
//!
//! **What this file does not claim.** It does not claim the pass encoders
//! share a base class at run time. Zig has no inheritance, so
//! `RenderEncoderBase` and `ComputePassEncoder` each hold a `ProgrammableEncoder`
//! as a field and forward; that is the same shape as Dawn's with the virtual
//! call replaced by a field read.
//!
//! It does not claim `setImmediates` keeps Dawn's three-argument form. Dawn
//! takes `(offset, data, size)` where `size` counts four-byte elements and
//! `data` may be a longer scratch buffer (`dawn.json` "render pass encoder"
//! "set immediates", generated at `src/api/objects.zig:884`). The port takes
//! the exact bytes to write, because the caller here is `engine` and not a C
//! ABI, and a third argument the port ignores would be a parameter a reader
//! has to prove unused.
const commands = @import("commands.zig");
const std = @import("std");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const state_tracker = @import("state_tracker.zig");
const usage = @import("usage.zig");

/// What `setBindGroup` takes. Every field beyond the group itself is something
/// only the caller can read, recorded at set time so no rule has to reach into
/// the group later.
pub const SetBindGroupOptions = struct {
    index: u32,
    group: commands.Ref,
    /// The dynamic offsets, copied into the stream behind the payload. Dawn
    /// writes them only when the count is above zero
    /// (`src/dawn/native/ProgrammableEncoder.cpp:236-238`).
    dynamic_offset_count: u32 = 0,
    dynamic_offsets: []const u32 = &.{},
    /// The identity of the group's layout, compared against the pipeline's.
    layout_id: u64 = 0,
    /// The smallest buffer any binding in this group names, for the undersized
    /// binding rule (`CommandBufferStateTracker.cpp:545-547`).
    min_binding_buffer_size: u64 = 0,
    /// The texture bindings, for the compatibility-mode view rule.
    texture_bindings: []const state_tracker.TextureBinding = &.{},
    buffers: []const usage.BindGroupBuffer = &.{},
    textures: []const usage.BindGroupTexture = &.{},
    external_textures: []const commands.Ref = &.{},
    resource_table: commands.Ref = null,
};

/// What `setImmediates` takes. See the file header on Dawn's third argument.
pub const SetImmediatesOptions = struct {
    offset: u32,
    data: []const u8,
};

/// Where the resources a bind group names are recorded. Dawn's two trackers are
/// distinct types with a shared base (`PassResourceUsageTracker.h:51-138`); the
/// port holds one of the two rather than a virtual base, and a caller that
/// names neither records nothing — which is what a bundle does, because a
/// bundle's usages are merged into the executing pass's
/// (`PassResourceUsage.h:104-106`).
pub const UsageSink = struct {
    render: ?*usage.RenderPassResourceUsageTracker = null,
    compute: ?*usage.ComputePassResourceUsageTracker = null,

    pub fn addBindGroup(
        self: UsageSink,
        resources: usage.BindGroupResources,
    ) std.mem.Allocator.Error!void {
        if (self.render) |render| {
            try render.addBindGroupResources(resources);
            return;
        }
        if (self.compute) |compute| {
            for (resources.buffers) |entry| {
                try compute.addReferencedBuffer(entry.buffer);
            }
            for (resources.textures) |entry| {
                try compute.addReferencedTexture(entry.texture);
            }
            for (resources.external_textures) |texture| {
                try compute.addReferencedExternalTexture(texture);
            }
            if (resources.resource_table != null) {
                try compute.addReferencedResourceTable(resources.resource_table);
            }
        }
    }
};

/// The shared half of every pass encoder.
pub const ProgrammableEncoder = struct {
    context: *encoding_context.Context,
    /// Which encoder this is, for the identity check. Dawn compares the
    /// `ApiObjectBase*` (`EncodingContext.h:150`); see the file header for why
    /// the port issues an id instead.
    id: encoding_context.EncoderId,
    allocator: std.mem.Allocator,
    /// Dawn's `mEnded` (`ProgrammableEncoder.h:86`).
    ended: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *encoding_context.Context,
    ) ProgrammableEncoder {
        return .{ .context = context, .id = context.enterPass(), .allocator = allocator };
    }

    /// Dawn's `ValidateProgrammableEncoderEnd`
    /// (`ProgrammableEncoder.cpp:74-79`): a debug group left open is a
    /// validation error at `end`, not at `finish`. Dawn reports it through the
    /// error sink; the port returns it, because the caller is `engine` and
    /// owns the sink.
    pub fn validateProgrammableEncoderEnd(self: *const ProgrammableEncoder) errors.Error!void {
        if (self.context.debugGroupDepth() != 0) return error.DebugGroupUnbalanced;
    }

    /// Dawn's `ValidateSetBindGroup` (`ProgrammableEncoder.cpp:146-224`). The
    /// receiver is `_` because every rule here reads the options alone.
    pub fn validateSetBindGroup(
        _: *const ProgrammableEncoder,
        options: SetBindGroupOptions,
    ) errors.Error!void {
        if (options.index >= constants.max_bind_groups) return error.BindGroupIndexOutOfRange;
        if (options.dynamic_offset_count != options.dynamic_offsets.len) {
            return error.SliceLengthMismatch;
        }
    }

    /// Dawn's `RecordSetBindGroup` (`ProgrammableEncoder.cpp:226-242`). Dawn
    /// writes no dynamic-offset run at all when the count is zero, so `skip`
    /// must not look for one; `commands.skip` reads the count off the payload.
    ///
    /// `errors.Error` is what `encode` declares (`encoding_context.zig:182`): a
    /// lifecycle rule of `core.Error`'s, or `OutOfMemory` (`allocator.zig:184`).
    pub fn recordSetBindGroup(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        sink: UsageSink,
        options: SetBindGroupOptions,
    ) errors.Error!void {
        const cmd = try self.context.encode(
            commands.SetBindGroupCmd,
            self.id,
            .set_bind_group,
        );
        cmd.* = .{ .index = options.index, .group = options.group };
        cmd.dynamic_offset_count = @intCast(options.dynamic_offsets.len);
        // Dawn guards the same call with a zero-count test (ProgrammableEncoder.cpp:236-241):
        // the counted run is written only above zero, so a bind group with no dynamic
        // offsets leaves nothing behind for `commands.skip` to consume.
        if (options.dynamic_offsets.len != 0) {
            const out = try self.context.encodeData(u32, options.dynamic_offsets.len);
            @memcpy(out, options.dynamic_offsets);
        }
        tracker.setBindGroup(options.index, .{
            .group = options.group,
            .layout_id = options.layout_id,
            .min_binding_buffer_size = options.min_binding_buffer_size,
            .texture_bindings = options.texture_bindings,
        });
        try sink.addBindGroup(.{
            .buffers = options.buffers,
            .textures = options.textures,
            .external_textures = options.external_textures,
            .resource_table = options.resource_table,
        });
    }

    /// `setBindGroup` is validate-then-record in one call, because Dawn's
    /// `APISetBindGroup` is (`ComputePassEncoder.cpp:544-568`).
    pub fn setBindGroup(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        sink: UsageSink,
        options: SetBindGroupOptions,
    ) errors.Error!void {
        try self.validateSetBindGroup(options);
        try self.recordSetBindGroup(tracker, sink, options);
    }

    /// Dawn's `ValidateSetImmediates` (`ProgrammableEncoder.cpp:130-144`). The
    /// receiver is `_` because every rule here reads the options alone.
    pub fn validateSetImmediates(
        _: *const ProgrammableEncoder,
        options: SetImmediatesOptions,
    ) errors.Error!void {
        if (options.offset % constants.immediate_element_byte_size != 0) {
            return error.ImmediateDataUnaligned;
        }
        const end = @as(u64, options.offset) + options.data.len;
        if (end > constants.max_immediate_data_bytes) return error.ImmediateDataTooLarge;
    }

    /// Dawn's `RecordSetImmediates` (`ProgrammableEncoder.cpp:244-259`). Dawn
    /// records nothing for an empty payload (`ProgrammableEncoder.cpp:248-250`)
    /// and the port keeps that: a zero-length run behind a tag is a tag a
    /// reader would have to special-case. The set is `errors.Error`, which is
    /// what `encode` declares (`encoding_context.zig:182`); the append adds no
    /// more.
    pub fn recordSetImmediates(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        options: SetImmediatesOptions,
    ) errors.Error!void {
        tracker.setImmediateData(options.offset, options.data);
        if (options.data.len == 0) return;
        const cmd = try self.context.encode(
            commands.SetImmediatesCmd,
            self.id,
            .set_immediates,
        );
        cmd.* = .{ .offset = options.offset, .size = @intCast(options.data.len) };
        const out = try self.context.encodeData(u8, options.data.len);
        @memcpy(out, options.data);
    }

    pub fn setImmediates(
        self: *ProgrammableEncoder,
        tracker: *state_tracker.Tracker,
        options: SetImmediatesOptions,
    ) errors.Error!void {
        try self.validateSetImmediates(options);
        try self.recordSetImmediates(tracker, options);
    }

    /// Dawn's `APIPushDebugGroup` (`ProgrammableEncoder.cpp:112-128`).
    pub fn pushDebugGroup(self: *ProgrammableEncoder, label: []const u8) errors.Error!void {
        const cmd = try self.context.encode(
            commands.PushDebugGroupCmd,
            self.id,
            .push_debug_group,
        );
        var length: u32 = 0;
        try commands.addNullTerminatedString(self.context.pendingAllocator(), label, &length);
        cmd.* = .{ .length = length };
        try self.context.pushDebugGroupLabel(label);
    }

    /// Dawn's `APIPopDebugGroup` (`ProgrammableEncoder.cpp:95-110`).
    pub fn popDebugGroup(self: *ProgrammableEncoder) errors.Error!void {
        _ = try self.context.encode(commands.PopDebugGroupCmd, self.id, .pop_debug_group);
        try self.context.popDebugGroupLabel();
    }

    /// Dawn's `APIInsertDebugMarker` (`ProgrammableEncoder.cpp:81-93`).
    pub fn insertDebugMarker(self: *ProgrammableEncoder, label: []const u8) errors.Error!void {
        const cmd = try self.context.encode(
            commands.InsertDebugMarkerCmd,
            self.id,
            .insert_debug_marker,
        );
        var length: u32 = 0;
        try commands.addNullTerminatedString(self.context.pendingAllocator(), label, &length);
        cmd.* = .{ .length = length };
    }
};
