const std = @import("std");
const vulkan = @import("vulkan");
const commands = @import("../command/commands.zig");
const api = @import("../api/api.zig");
const stream = @import("../command/allocator.zig");
const encoding = @import("../command/encoding_context.zig");
const usage_mod = @import("../command/usage.zig");
const command_errors = @import("../command/errors.zig");
const queue_mod = @import("queue.zig");
const recording_mod = @import("recording_context.zig");
const buffer_mod = @import("buffer.zig");
const texture_mod = @import("texture.zig");
const pipeline_mod = @import("../pipeline/pipeline.zig");
const bind_group_mod = @import("bind_group.zig");
const query_mod = @import("query_set.zig");
const query_vk = @import("vulkan_query_set.zig");
const bundle_mod = @import("../command/render_bundle.zig");
const passes = @import("render_pass_cache.zig");
const frames = @import("framebuffer_cache.zig");
const copies = @import("command_replay_copy.zig");
const trackers = @import("command_replay_state.zig");
const dispatch = @import("../vk/dispatch.zig");
const format_mod = @import("format.zig");
const indirect_mod = @import("../command/indirect_draw.zig");
const device_mod = @import("vulkan_device.zig");
const core = @import("../core/root.zig");
const attachment_mod = @import("../command/attachment_state.zig");
const native_resources = @import("native_resources.zig");
const kernels = @import("native_kernels.zig");
const native_indirect = @import("native_indirect.zig");
const native_timestamps = @import("native_timestamps.zig");
const external_texture = @import("external_texture.zig");

pub const AttachmentValidationError = native_resources.Error || texture_mod.NativeError || error{
    InvalidResourceRef,
    InvalidAttachment,
    UnsupportedResolveExpansion,
    InvalidClearValue,
};

test "replay rejects render commands at top level and mismatched pass ends" {
    try std.testing.expectError(error.InvalidCommandContext, validateContext(.top_level, .draw));
    try std.testing.expectError(
        error.InvalidCommandContext,
        validateContext(.render, .end_compute_pass),
    );
    try std.testing.expectError(
        error.InvalidCommandContext,
        validateContext(.compute, .begin_render_pass),
    );
}

test "replay context classification covers every command tag" {
    inline for (@typeInfo(commands.Tag).@"enum".field_values) |field_value| {
        const tag: commands.Tag = @fromBackingInt(@intCast(field_value));
        var accepted: bool = false;
        inline for (.{
            ContextKind.top_level,
            ContextKind.render,
            ContextKind.compute,
        }) |context| {
            if (validateContext(context, tag)) |_| {
                accepted = true;
            } else |_| {}
        }
        try std.testing.expect(accepted);
    }
}

test "render area rounds outward and clamps to target" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    const attachment = try createReplayTestAttachment(&arena, &guard, .{});
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    var begin: commands.BeginRenderPassCmd = .{
        .attachment_state = attachment,
        .width = 7,
        .height = 9,
        .render_area = .{ .x = 3, .y = 5, .width = 4, .height = 4 },
    };
    const area = try alignedRenderArea(.{ .width = 4, .height = 4 }, begin);
    try std.testing.expectEqual(@as(i32, 0), area.offset.x);
    try std.testing.expectEqual(@as(i32, 4), area.offset.y);
    try std.testing.expectEqual(@as(u32, 7), area.extent.width);
    try std.testing.expectEqual(@as(u32, 5), area.extent.height);
    begin.force_full_render_area = true;
    const full = try alignedRenderArea(.{ .width = 4, .height = 4 }, begin);
    try std.testing.expectEqual(@as(i32, 0), full.offset.y);
    try std.testing.expectEqual(@as(u32, 9), full.extent.height);
}

test "immediate writes reject unaligned and overflowing ranges" {
    var tracker: ImmediatesTracker = .{};
    try std.testing.expectError(error.ImmediateUnaligned, tracker.set(1, &.{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.ImmediateOutOfRange, tracker.set(256, &.{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.ImmediateUnaligned, tracker.set(0, &.{0}));
    try std.testing.expectError(
        error.ImmediateOutOfRange,
        tracker.set(std.math.maxInt(u32) - 3, &.{ 0, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.ImmediateOutOfRange,
        tracker.set(252, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
    );
    try std.testing.expectEqual(@as(u64, 0), tracker.dirty_mask);
    try tracker.set(4, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(u64, 2), tracker.dirty_mask);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, tracker.content[4..8]);
}

test "native immediate admission preserves effective device bounds" {
    try validateImmediateRange(256, 252, 4);
    try validateImmediateRange(256, 0, 256);
    try validateImmediateRange(256, 256, 0);
    try std.testing.expectError(error.ImmediateOutOfRange, validateImmediateRange(128, 128, 4));
    try std.testing.expectError(error.ImmediateOutOfRange, validateImmediateRange(256, 252, 8));
    try std.testing.expectError(error.ImmediateUnaligned, validateImmediateRange(256, 1, 4));
    try std.testing.expectError(error.ImmediateUnaligned, validateImmediateRange(256, 0, 3));
}

pub const ImmediatesTracker = trackers.ImmediatesTracker;
pub const DescriptorSetTracker = trackers.DescriptorSetTracker;
pub const ProgrammablePassState = trackers.ProgrammablePassState;
pub const ContextKind = enum { top_level, render, compute };
pub const ReplayError = command_errors.Error || queue_mod.ProcError ||
    buffer_mod.Error || texture_mod.NativeError || bind_group_mod.Error ||
    query_vk.Error || passes.GetRenderPassError || frames.GetOrCreateError ||
    frames.AddAttachmentError || copies.Error || trackers.Error || native_resources.Error ||
    native_indirect.Error || native_timestamps.Error || external_texture.Error || error{
    InvalidCommandContext,
    InvalidFinishedStatus,
    PassMetadataMismatch,
    DispatchMetadataMismatch,
    InvalidResourceRef,
    ResourceDestroyed,
    InvalidRenderArea,
    InvalidAttachment,
    UnsupportedResolveExpansion,
    UnsupportedPixelLocalStorage,
    UnsupportedResourceTable,
    UnsupportedFramebufferFetch,
    InvalidLabel,
    DebugGroupUnderflow,
    DebugGroupsUnbalanced,
    MissingPassEnd,
    CommandCountExhausted,
    BundleDepthExhausted,
    BundleCycle,
    InvalidBundle,
    ActiveQueryAtPassEnd,
    OcclusionQueryAlreadyActive,
    OcclusionQueryNotActive,
    OcclusionQueryMismatch,
    MissingIndexBuffer,
    MissingVertexBuffer,
    InvalidBufferRange,
    PipelineAttachmentMismatch,
    InvalidClearValue,
    IndirectBufferWrittenInRenderPass,
};

/// The caller pins the immutable tracking-list high owner before payload access,
/// then holds queue → ObjectGuard through CPU replay and native command encoding.
/// The guard must not cross a fence wait, join, or completion callback.
pub const RecordOptions = struct {
    io: std.Io,
    guard: *const core.ObjectGuard,
    core_device: *core.Device,
    queue: *queue_mod.Queue,
    recording: *recording_mod.CommandRecordingContext,
    render_pass_cache: *passes.RenderPassCache,
    framebuffer_cache: *frames.FramebufferCache,
    max_immediate_size: u32,
    kernels: *kernels.KernelCache,
    pending_uses: *native_resources.PendingUses,
    timestamp_quantization: bool,
};
const max_command_count = @import("../command/constants.zig").max_bundle_command_count;
const max_bundle_depth = @import("../command/constants.zig").max_bundle_depth;
const max_bind_groups = @import("../command/constants.zig").max_bind_groups;
const ExternalPlaneKey = struct {
    texture: *texture_mod.Texture,
    range: texture_mod.SubresourceRange,
};
const ExternalPlaneStages = std.AutoArrayHashMapUnmanaged(ExternalPlaneKey, buffer_mod.ShaderStage);

fn validateImmediateRange(limit: u32, offset: u32, size: u32) ReplayError!void {
    if (offset % 4 != 0 or size % 4 != 0) return error.ImmediateUnaligned;
    const effective_limit = @min(limit, 256);
    if (offset > effective_limit or size > effective_limit - offset)
        return error.ImmediateOutOfRange;
}

pub fn validateContext(context: ContextKind, tag: commands.Tag) error{InvalidCommandContext}!void {
    const valid = switch (tag) {
        .begin_compute_pass,
        .begin_render_pass,
        .clear_buffer,
        .copy_buffer_to_buffer,
        .copy_buffer_to_texture,
        .copy_texture_to_buffer,
        .copy_texture_to_texture,
        .copy_texture_for_browser,
        .copy_external_texture_for_browser,
        .resolve_query_set,
        .write_buffer,
        => context == .top_level,
        .dispatch, .dispatch_indirect, .set_compute_pipeline, .end_compute_pass => context == .compute,
        .begin_occlusion_query,
        .end_occlusion_query,
        .draw,
        .draw_indexed,
        .draw_indirect,
        .draw_indexed_indirect,
        .multi_draw_indirect,
        .multi_draw_indexed_indirect,
        .end_render_pass,
        .execute_bundles,
        .pixel_local_storage_barrier,
        .set_render_pipeline,
        .set_stencil_reference,
        .set_viewport,
        .set_scissor_rect,
        .set_blend_constant,
        .set_index_buffer,
        .set_vertex_buffer,
        => context == .render,
        .set_bind_group, .set_immediates, .set_resource_table => context != .top_level,
        .insert_debug_marker, .pop_debug_group, .push_debug_group, .write_timestamp => true,
    };
    if (!valid) return error.InvalidCommandContext;
}

pub fn alignedRenderArea(
    granularity: vulkan.VkExtent2D,
    begin: commands.BeginRenderPassCmd,
) error{InvalidRenderArea}!vulkan.VkRect2D {
    if (begin.width > std.math.maxInt(i32) or begin.height > std.math.maxInt(i32))
        return error.InvalidRenderArea;
    if (begin.force_full_render_area) return .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = begin.width, .height = begin.height },
    };
    const area = begin.render_area;
    if (area.x > begin.width or area.y > begin.height or
        area.width > begin.width - area.x or area.height > begin.height - area.y)
        return error.InvalidRenderArea;
    const gx: u64 = @max(granularity.width, 1);
    const gy: u64 = @max(granularity.height, 1);
    const left = @divFloor(@as(u64, area.x), gx) * gx;
    const top = @divFloor(@as(u64, area.y), gy) * gy;
    const right = @min(begin.width, @divFloor(@as(u64, area.x) + area.width + gx - 1, gx) * gx);
    const bottom = @min(begin.height, @divFloor(@as(u64, area.y) + area.height + gy - 1, gy) * gy);
    return .{
        .offset = .{ .x = @intCast(left), .y = @intCast(top) },
        .extent = .{ .width = @intCast(right - left), .height = @intCast(bottom - top) },
    };
}

fn resource(
    guard: *const core.ObjectGuard,
    comptime T: type,
    reference: commands.Ref,
) ReplayError!*T {
    const pointer = reference orelse return error.InvalidResourceRef;
    if (@intFromPtr(pointer) % @alignOf(T) != 0) return error.InvalidResourceRef;
    std.debug.assert(guard.held);
    if (T == texture_mod.TextureView) return resolveViewLocked(guard, reference);
    const value: *T = @ptrCast(@alignCast(pointer));
    if (@hasField(T, "header")) {
        if (value.header.tracking != guard.objects) return error.InvalidResourceRef;
        guard.assertOwns(value.header.tracking);
        if (!value.header.node.linked or value.header.reference_count == 0 or value.header.state != .alive)
            return error.ResourceDestroyed;
    }
    if (@hasField(T, "objects")) {
        if (value.objects != guard.objects) return error.InvalidResourceRef;
        guard.assertOwns(value.objects);
    }
    return value;
}

fn resolveViewLocked(
    guard: *const core.ObjectGuard,
    reference: commands.Ref,
) AttachmentValidationError!*texture_mod.TextureView {
    const pointer = reference orelse return error.InvalidResourceRef;
    std.debug.assert(guard.held);
    var current = guard.objects.head;
    for (0..guard.objects.tracked_count) |_| {
        const header = current orelse break;
        current = header.node.next;
        if (header.kind != .texture_view) continue;
        const view: *texture_mod.TextureView = @fieldParentPtr("header", header);
        if (@intFromPtr(view) != @intFromPtr(pointer)) continue;
        if (header.tracking != guard.objects or !header.node.linked)
            return error.InvalidResourceRef;
        if (header.reference_count == 0 or header.state != .alive)
            return error.ResourceDestroyed;
        const parent = &view.texture.header;
        if (parent.tracking != guard.objects or parent.kind != .texture or
            !parent.node.linked) return error.InvalidResourceRef;
        if (parent.reference_count == 0 or parent.state != .alive)
            return error.ResourceDestroyed;
        return view;
    }
    return error.InvalidResourceRef;
}

test "indirect replay compares the full selected index snapshot" {
    var arguments: u8 = 0;
    var indices: u8 = 0;
    const expected: indirect_mod.IndirectDraw = .{
        .index = 3,
        .buffer = &arguments,
        .offset = 20,
        .indexed = true,
        .index_buffer = &indices,
        .index_buffer_offset = 8,
        .index_buffer_size = 10,
        .index_format = .uint16,
        .index_element_count = 5,
    };
    try validateIndirectSnapshot(expected, expected);
    inline for (@typeInfo(indirect_mod.IndirectDraw).@"struct".field_names) |field_name| {
        var changed = expected;
        if (comptime std.mem.eql(u8, field_name, "buffer") or
            std.mem.eql(u8, field_name, "draw_count_buffer") or
            std.mem.eql(u8, field_name, "index_buffer"))
        {
            @field(changed, field_name) = if (@field(changed, field_name) == null)
                &arguments
            else
                null;
        } else if (comptime std.mem.eql(u8, field_name, "indexed") or
            std.mem.eql(u8, field_name, "multi"))
        {
            @field(changed, field_name) = !@field(changed, field_name);
        } else if (comptime std.mem.eql(u8, field_name, "index_format")) {
            @field(changed, field_name) = .uint32;
        } else {
            @field(changed, field_name) += 1;
        }
        try std.testing.expectError(error.PassMetadataMismatch, validateIndirectSnapshot(expected, changed));
    }
}

const Replay = struct {
    allocator: std.mem.Allocator,
    options: RecordOptions,
    procs: *const dispatch.DeviceProcs,
    render_index: usize = 0,
    compute_index: usize = 0,
    command_count: usize = 0,
    debug_depth: usize = 0,
    bundle_stack: [max_bundle_depth]?*bundle_mod.RenderBundle = @splat(null),
    bundle_depth: usize = 0,
    indirect_metadata: ?*const indirect_mod.IndirectDrawMetadata = null,
    indirect_index: usize = 0,
    sanitized_draws: []const native_indirect.DrawOutput = &.{},

    fn recording(self: *const Replay) buffer_mod.Recording {
        return .{
            .command_buffer = self.options.queue.commandBuffer(),
            .pending_serial = self.options.queue.timeline.nextSerial(),
        };
    }
    fn trackerContext(self: *const Replay) trackers.Context {
        return .{
            .guard = self.options.guard,
            .procs = self.procs,
            .command_buffer = self.recording().command_buffer,
        };
    }
    fn kernelContext(self: *const Replay) kernels.Context {
        return .{
            .io = self.options.io,
            .guard = self.options.guard,
            .device = self.options.core_device,
            .queue = self.options.queue,
            .recording = self.options.recording,
            .pending_uses = self.options.pending_uses,
            .cache = self.options.kernels,
        };
    }
    fn copyContext(self: *const Replay) copies.Context {
        return .{
            .allocator = self.allocator,
            .guard = self.options.guard,
            .queue = self.options.queue,
            .recording = self.options.recording,
            .kernels = self.kernelContext(),
            .render_pass_cache = self.options.render_pass_cache,
            .framebuffer_cache = self.options.framebuffer_cache,
        };
    }
    fn nextTag(self: *Replay, iterator: *stream.Iterator) ReplayError!?commands.Tag {
        if (self.command_count == max_command_count) return error.CommandCountExhausted;
        self.command_count += 1;
        const value = try iterator.nextTag();
        return value;
    }
    fn consumeIndirect(self: *Replay, command: indirect_mod.IndirectDraw, selected_index: ?commands.SetIndexBufferCmd) ReplayError!native_indirect.DrawOutput {
        const metadata = self.indirect_metadata orelse return error.PassMetadataMismatch;
        if (self.indirect_index >= metadata.draws.items.len or
            self.indirect_index >= self.sanitized_draws.len) return error.PassMetadataMismatch;
        var actual = command;
        actual.index = @intCast(self.indirect_index);
        try captureReplayIndex(&actual, selected_index);
        try validateIndirectSnapshot(metadata.draws.items[self.indirect_index], actual);
        const output = self.sanitized_draws[self.indirect_index];
        self.indirect_index += 1;
        return output;
    }
    fn prepareBindGroup(self: *Replay, reference: commands.Ref) ReplayError!void {
        if (reference == null) return;
        const owner = try native_resources.resolveBindGroupRefLocked(
            self.options.guard,
            self.options.core_device,
            reference,
        );
        for (owner.external_textures) |value|
            try external_texture.prepareForUse(self.kernelContext(), value);
    }
    fn prepareExternalGroup(
        self: *Replay,
        owner: *native_resources.BindGroup,
        stages: buffer_mod.ShaderStage,
        scope: *const usage_mod.SyncScopeResourceUsage,
        plane_stages: ?*const ExternalPlaneStages,
    ) ReplayError!void {
        if (self.options.recording.active_render_pass != null)
            return error.KernelRequiresOutsideRenderPass;
        for (owner.external_textures) |value|
            try external_texture.prepareForUse(self.kernelContext(), value);
        if (owner.external_textures.len == 0) return;
        // Expanded planes are not ordinary frontend scope entries.
        for (owner.native.bindings) |binding| {
            const view = switch (binding) {
                .texture => |value| if (!value.storage) value.view else continue,
                .combined_y_cb_cr_view => |value| value.view,
                else => continue,
            };
            const binding_stages = switch (binding) {
                .texture => |value| value.stages,
                .combined_y_cb_cr_view => |value| value.stages,
                else => unreachable,
            };
            const current_stages: buffer_mod.ShaderStage =
                @bitCast(binding_stages.toFlags() & stages.toFlags());
            if (current_stages.toFlags() == 0) continue;
            var external_plane = false;
            for (owner.external_textures) |value| {
                external_plane = external_plane or value.planes[0] == view or
                    value.planes[1] == view;
            }
            if (!external_plane) continue;
            var sampled_stages = if (plane_stages) |merged|
                merged.get(.{ .texture = view.texture, .range = view.range }) orelse
                    return error.PassMetadataMismatch
            else
                current_stages;
            for (scope.texture_sync_infos.items) |entry| {
                if (entry.texture != @as(commands.Ref, @ptrCast(view.texture)) or
                    entry.mip_level < view.range.base_mip_level or
                    entry.mip_level - view.range.base_mip_level >= view.range.level_count or
                    entry.array_layer < view.range.base_array_layer or
                    entry.array_layer - view.range.base_array_layer >= view.range.layer_count)
                    continue;
                const sampled_usage = (api.bitmask.TextureUsage{
                    .texture_binding = true,
                }).toFlags();
                if (entry.info.usage & ~sampled_usage != 0)
                    return error.TextureNativeUsageUnsupported;
                sampled_stages = @bitCast(sampled_stages.toFlags() | entry.info.shader_stages);
            }
            try view.texture.ensureSubresourceContentInitialized(
                self.options.guard,
                self.options.queue,
                self.recording(),
                view.range,
            );
            try view.texture.transition(
                self.options.guard,
                self.recording(),
                view.range,
                .{ .texture_binding = true },
                sampled_stages,
            );
        }
    }
    fn prepareDispatchExternalGroups(
        self: *Replay,
        state: *ProgrammablePassState,
        scope: *const usage_mod.SyncScopeResourceUsage,
    ) ReplayError!void {
        try state.descriptor_sets.validate(self.options.guard);
        const pipeline = state.current_pipeline orelse return error.PipelineNotSet;
        for (state.descriptor_sets.groups, 0..) |group, index| {
            if (pipeline.bind_group_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            if (group) |value| {
                const owner = try native_resources.resolveBindGroupRefLocked(
                    self.options.guard,
                    self.options.core_device,
                    @ptrCast(value),
                );
                try self.prepareExternalGroup(owner, .{ .compute = true }, scope, null);
            }
        }
    }
    fn prepareExternalReference(self: *Replay, reference: commands.Ref) ReplayError!void {
        const value = try native_resources.resolveExternalTextureRefLocked(
            self.options.guard,
            self.options.core_device,
            reference,
        );
        try external_texture.prepareForUse(self.kernelContext(), value);
    }
    fn label(
        self: *Replay,
        iterator: *stream.Iterator,
        length: u32,
        kind: enum { pass_label, push, marker },
    ) ReplayError!void {
        if (kind == .pass_label and length == 0) return;
        const bytes = try iterator.nextData(u8, length);
        if (bytes.len == 0 or bytes[bytes.len - 1] != 0 or
            std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null)
            return error.InvalidLabel;
        const info: vulkan.VkDebugUtilsLabelEXT = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEBUG_UTILS_LABEL_EXT,
            .pLabelName = @ptrCast(bytes.ptr),
            .color = .{ 0, 0, 0, 0 },
        };
        switch (kind) {
            .pass_label => {},
            .push => {
                if (self.options.queue.context.dispatch.instance) |instance|
                    if (instance.cmd_begin_debug_utils_label_ext) |proc|
                        proc(self.recording().command_buffer, &info);
                self.debug_depth += 1;
            },
            .marker => if (self.options.queue.context.dispatch.instance) |instance| {
                if (instance.cmd_insert_debug_utils_label_ext) |proc|
                    proc(self.recording().command_buffer, &info);
            },
        }
    }
    fn debugCommand(
        self: *Replay,
        iterator: *stream.Iterator,
        tag: commands.Tag,
    ) ReplayError!void {
        switch (tag) {
            .push_debug_group => try self.label(
                iterator,
                (try iterator.nextCommand(commands.PushDebugGroupCmd)).length,
                .push,
            ),
            .insert_debug_marker => try self.label(
                iterator,
                (try iterator.nextCommand(commands.InsertDebugMarkerCmd)).length,
                .marker,
            ),
            .pop_debug_group => {
                _ = try iterator.nextCommand(commands.PopDebugGroupCmd);
                if (self.debug_depth == 0) return error.DebugGroupUnderflow;
                self.debug_depth -= 1;
                if (self.options.queue.context.dispatch.instance) |instance|
                    if (instance.cmd_end_debug_utils_label_ext) |proc|
                        proc(self.recording().command_buffer);
            },
            else => return error.InvalidCommandContext,
        }
    }
    fn timestamp(self: *Replay, writes: commands.TimestampWrites, begin: bool) ReplayError!void {
        const index = if (begin)
            writes.beginning_of_pass_write_index
        else
            writes.end_of_pass_write_index;
        if (index == commands.undefined_query_index) return;
        try recordWriteTimestampCmd(
            self,
            .{ .query_set = writes.query_set, .query_index = index },
            if (begin)
                vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
            else
                vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            false,
        );
    }
    fn programmableCommand(
        self: *Replay,
        iterator: *stream.Iterator,
        tag: commands.Tag,
        state: *ProgrammablePassState,
    ) ReplayError!bool {
        switch (tag) {
            .set_bind_group => {
                const command = (try iterator.nextCommand(commands.SetBindGroupCmd)).*;
                const offsets: []const u32 = if (command.dynamic_offset_count == 0)
                    &.{}
                else
                    try iterator.nextData(u32, command.dynamic_offset_count);
                if (self.options.recording.active_render_pass == null) {
                    try self.prepareBindGroup(command.group);
                    state.dirtyAll();
                }
                const group = if (command.group == null)
                    null
                else
                    try resource(self.options.guard, bind_group_mod.BindGroup, command.group);
                try state.descriptor_sets.set(self.options.guard, command.index, group, offsets);
            },
            .set_immediates => {
                const command = (try iterator.nextCommand(commands.SetImmediatesCmd)).*;
                try validateImmediateRange(
                    self.options.max_immediate_size,
                    command.offset,
                    command.size,
                );
                try state.immediates.set(command.offset, try iterator.nextData(u8, command.size));
            },
            .set_resource_table => try state.descriptor_sets.setResourceTable(
                (try iterator.nextCommand(commands.SetResourceTableCmd)).table,
            ),
            .push_debug_group, .pop_debug_group, .insert_debug_marker => try self.debugCommand(iterator, tag),
            else => return false,
        }
        return true;
    }
    fn recordComputePass(
        self: *Replay,
        iterator: *stream.Iterator,
        begin: commands.BeginComputePassCmd,
        usage: *const usage_mod.ComputePassResourceUsage,
    ) ReplayError!void {
        const debug_depth = self.debug_depth;
        var state: ProgrammablePassState = .{};
        var dispatch_index: usize = 0;
        for (usage.referenced_external_textures.items) |reference|
            try self.prepareExternalReference(reference);
        if (usage.referenced_resource_tables.items.len != 0) return error.UnsupportedResourceTable;
        for (usage.referenced_buffers.items) |reference| {
            const buffer = try resource(self.options.guard, buffer_mod.Buffer, reference);
            try buffer.validateCanUseOnQueueNow();
            buffer.finishUse();
        }
        for (usage.referenced_textures.items) |reference|
            _ = try (try resource(self.options.guard, texture_mod.Texture, reference)).getHandle(self.options.guard);
        try resetTimestampWrites(self, begin.timestamp_writes);
        try self.timestamp(begin.timestamp_writes, true);
        while (try self.nextTag(iterator)) |tag| {
            try validateContext(.compute, tag);
            if (try self.programmableCommand(iterator, tag, &state)) continue;
            switch (tag) {
                .set_compute_pipeline => {
                    const owner = try native_resources.resolvePipelineRefLocked(
                        self.options.guard,
                        self.options.core_device,
                        (try iterator.nextCommand(commands.SetComputePipelineCmd)).pipeline,
                    );
                    if (owner.attachment != .compute) return error.PipelineKindMismatch;
                    if (owner.native.immediate_size > @min(self.options.max_immediate_size, 256))
                        return error.ImmediateOutOfRange;
                    try state.onSetPipeline(self.options.guard, .compute, owner.native);
                },
                .dispatch, .dispatch_indirect => {
                    if (dispatch_index >= usage.dispatch_usages.items.len)
                        return error.DispatchMetadataMismatch;
                    try prepareResourcesForSyncScope(
                        self,
                        &usage.dispatch_usages.items[dispatch_index],
                    );
                    dispatch_index += 1;
                    try self.prepareDispatchExternalGroups(
                        &state,
                        &usage.dispatch_usages.items[dispatch_index - 1],
                    );
                    if (tag == .dispatch) {
                        const command = (try iterator.nextCommand(commands.DispatchCmd)).*;
                        try state.syncAndRun(
                            self.trackerContext(),
                            vulkan.VK_PIPELINE_BIND_POINT_COMPUTE,
                        );
                        const proc = self.procs.cmd_dispatch orelse return error.MissingDeviceProc;
                        proc(self.recording().command_buffer, command.x, command.y, command.z);
                    } else {
                        const command = (try iterator.nextCommand(commands.DispatchIndirectCmd)).*;
                        _ = try checkedBuffer(
                            self.options.guard,
                            command.indirect_buffer,
                            command.indirect_offset,
                            12,
                            (api.bitmask.BufferUsage{ .indirect = true }).toFlags(),
                        );
                        if (command.indirect_offset % 4 != 0) return error.InvalidBufferRange;
                        const owner = try native_resources.resolveBufferRefLocked(
                            self.options.guard,
                            self.options.core_device,
                            command.indirect_buffer,
                        );
                        const proc = self.procs.cmd_dispatch_indirect orelse
                            return error.MissingDeviceProc;
                        const sanitized = try native_indirect.sanitizeDispatch(self.kernelContext(), .{
                            .owner = owner,
                            .offset = command.indirect_offset,
                            .size = 12,
                        });
                        state.dirtyAll();
                        try state.syncAndRun(
                            self.trackerContext(),
                            vulkan.VK_PIPELINE_BIND_POINT_COMPUTE,
                        );
                        proc(
                            self.recording().command_buffer,
                            sanitized.owner.native.handle,
                            sanitized.offset,
                        );
                    }
                },
                .write_timestamp => try recordWriteTimestampCmd(
                    self,
                    (try iterator.nextCommand(commands.WriteTimestampCmd)).*,
                    vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                    true,
                ),
                .end_compute_pass => {
                    _ = try iterator.nextCommand(commands.EndComputePassCmd);
                    if (dispatch_index != usage.dispatch_usages.items.len)
                        return error.DispatchMetadataMismatch;
                    if (debug_depth != self.debug_depth) return error.DebugGroupsUnbalanced;
                    try self.timestamp(begin.timestamp_writes, false);
                    return;
                },
                else => return error.InvalidCommandContext,
            }
        }
        return error.MissingPassEnd;
    }
    fn recordRenderPass(
        self: *Replay,
        iterator: *stream.Iterator,
        begin: commands.BeginRenderPassCmd,
        usage: *const usage_mod.RenderPassResourceUsage,
    ) ReplayError!void {
        const metadata = self.indirect_metadata orelse return error.PassMetadataMismatch;
        if (metadata.draws.items.len > max_command_count) return error.CommandCountExhausted;
        const outputs = try self.allocator.alloc(native_indirect.DrawOutput, metadata.draws.items.len);
        defer self.allocator.free(outputs);
        defer self.sanitized_draws = &.{};
        try prepareRenderUtilities(self, iterator, begin, usage, outputs);
        self.sanitized_draws = outputs;
        try resetUsedQuerySetsOnRenderPass(self, usage);
        try resetTimestampWrites(self, begin.timestamp_writes);
        try self.timestamp(begin.timestamp_writes, true);
        try recordBeginRenderPass(self, begin);
        self.options.recording.has_recorded_render_pass = true;
        var state: RenderState = .{
            .attachment_state = begin.attachment_state,
            .depth_read_only = begin.depth_stencil_attachment.depth_read_only,
            .depth_stencil_aspects = if (begin.depth_stencil_attachment.view) |reference|
                (try resource(self.options.guard, texture_mod.TextureView, reference)).aspects.toFlags()
            else
                0,
            .stencil_read_only = begin.depth_stencil_attachment.stencil_read_only,
        };
        state.programmable.dirtyAll();
        const viewport = toVkViewport(.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(begin.width),
            .height = @floatFromInt(begin.height),
            .min_depth = 0,
            .max_depth = 1,
        });
        const scissor: vulkan.VkRect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = begin.width, .height = begin.height },
        };
        (self.procs.cmd_set_viewport orelse return error.MissingDeviceProc)(
            self.recording().command_buffer,
            0,
            1,
            &viewport,
        );
        (self.procs.cmd_set_scissor orelse return error.MissingDeviceProc)(
            self.recording().command_buffer,
            0,
            1,
            &scissor,
        );
        (self.procs.cmd_set_blend_constants orelse return error.MissingDeviceProc)(
            self.recording().command_buffer,
            &[_]f32{ 0, 0, 0, 0 },
        );
        (self.procs.cmd_set_stencil_reference orelse return error.MissingDeviceProc)(
            self.recording().command_buffer,
            vulkan.VK_STENCIL_FACE_FRONT_AND_BACK,
            0,
        );
        const debug_depth = self.debug_depth;
        var active_query: ?commands.BeginOcclusionQueryCmd = null;
        while (try self.nextTag(iterator)) |tag| {
            try validateContext(.render, tag);
            switch (tag) {
                .end_render_pass => {
                    _ = try iterator.nextCommand(commands.EndRenderPassCmd);
                    if (active_query != null) return error.ActiveQueryAtPassEnd;
                    if (self.debug_depth != debug_depth) return error.DebugGroupsUnbalanced;
                    try recordEndRenderPass(self);
                    try finishAttachments(self.options.guard, begin);
                    try self.timestamp(begin.timestamp_writes, false);
                    return;
                },
                .begin_occlusion_query => {
                    const command = (try iterator.nextCommand(commands.BeginOcclusionQueryCmd)).*;
                    if (active_query != null) return error.OcclusionQueryAlreadyActive;
                    if (command.query_set != begin.occlusion_query_set)
                        return error.OcclusionQueryMismatch;
                    try query_vk.beginQuery(
                        self.allocator,
                        self.options.guard,
                        self.options.queue,
                        try resource(self.options.guard, query_mod.QuerySet, command.query_set),
                        command.query_index,
                    );
                    active_query = command;
                },
                .end_occlusion_query => {
                    const command = (try iterator.nextCommand(commands.EndOcclusionQueryCmd)).*;
                    const active = active_query orelse return error.OcclusionQueryNotActive;
                    if (command.query_set != active.query_set or
                        command.query_index != active.query_index)
                        return error.OcclusionQueryMismatch;
                    try query_vk.endQuery(
                        self.allocator,
                        self.options.guard,
                        self.options.queue,
                        try resource(self.options.guard, query_mod.QuerySet, command.query_set),
                        command.query_index,
                    );
                    active_query = null;
                },
                .write_timestamp => try recordWriteTimestampCmd(
                    self,
                    (try iterator.nextCommand(commands.WriteTimestampCmd)).*,
                    vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                    false,
                ),
                else => try self.encodeBundleCommand(iterator, tag, &state),
            }
        }
        return error.MissingPassEnd;
    }
    fn encodeBundleCommand(
        self: *Replay,
        iterator: *stream.Iterator,
        tag: commands.Tag,
        state: *RenderState,
    ) ReplayError!void {
        if (try self.programmableCommand(iterator, tag, &state.programmable)) return;
        const cb = self.recording().command_buffer;
        switch (tag) {
            .set_render_pipeline => {
                const command = (try iterator.nextCommand(commands.SetRenderPipelineCmd)).*;
                const owner = try native_resources.resolvePipelineRefLocked(
                    self.options.guard,
                    self.options.core_device,
                    command.pipeline,
                );
                const attachment = switch (owner.attachment) {
                    .render => |value| value,
                    .compute => return error.PipelineKindMismatch,
                };
                if (attachment != state.attachment_state or
                    command.attachment_state != attachment)
                    return error.PipelineAttachmentMismatch;
                if (owner.native.immediate_size > @min(self.options.max_immediate_size, 256))
                    return error.ImmediateOutOfRange;
                try validatePipelineDepthStencil(owner.native, state);
                try state.programmable.onSetPipeline(
                    self.options.guard,
                    .render,
                    owner.native,
                );
            },
            .set_viewport => {
                const command = (try iterator.nextCommand(commands.SetViewportCmd)).*;
                const values = [_]f32{
                    command.x,
                    command.y,
                    command.width,
                    command.height,
                    command.min_depth,
                    command.max_depth,
                };
                for (values) |value| if (!std.math.isFinite(value)) return error.InvalidRenderArea;
                if (command.width < 0 or command.height < 0 or command.min_depth < 0 or
                    command.max_depth > 1 or command.min_depth > command.max_depth)
                    return error.InvalidRenderArea;
                const viewport = toVkViewport(command);
                (self.procs.cmd_set_viewport orelse return error.MissingDeviceProc)(
                    cb,
                    0,
                    1,
                    &viewport,
                );
            },
            .set_scissor_rect => {
                const command = (try iterator.nextCommand(commands.SetScissorRectCmd)).*;
                if (command.x > std.math.maxInt(i32) or command.y > std.math.maxInt(i32))
                    return error.InvalidRenderArea;
                const scissor: vulkan.VkRect2D = .{
                    .offset = .{ .x = @intCast(command.x), .y = @intCast(command.y) },
                    .extent = .{ .width = command.width, .height = command.height },
                };
                (self.procs.cmd_set_scissor orelse return error.MissingDeviceProc)(
                    cb,
                    0,
                    1,
                    &scissor,
                );
            },
            .set_stencil_reference => (self.procs.cmd_set_stencil_reference orelse return error.MissingDeviceProc)(
                cb,
                vulkan.VK_STENCIL_FACE_FRONT_AND_BACK,
                (try iterator.nextCommand(commands.SetStencilReferenceCmd)).reference,
            ),
            .set_blend_constant => {
                const color = (try iterator.nextCommand(commands.SetBlendConstantCmd)).color;
                (self.procs.cmd_set_blend_constants orelse return error.MissingDeviceProc)(
                    cb,
                    &[_]f32{ color.r, color.g, color.b, color.a },
                );
            },
            .set_index_buffer => {
                const command = (try iterator.nextCommand(commands.SetIndexBufferCmd)).*;
                const buffer = try checkedBuffer(
                    self.options.guard,
                    command.buffer,
                    command.offset,
                    command.size,
                    (api.bitmask.BufferUsage{ .index = true }).toFlags(),
                );
                const index_type = try copies.vulkanIndexType(command.format);
                const alignment: u64 = if (command.format == .uint16) 2 else 4;
                if (command.offset % alignment != 0 or command.size % alignment != 0 or
                    command.buffer_size != buffer.size) return error.InvalidBufferRange;
                (self.procs.cmd_bind_index_buffer orelse return error.MissingDeviceProc)(
                    cb,
                    buffer.handle,
                    command.offset,
                    index_type,
                );
                state.index_buffer = true;
                state.selected_index = command;
            },
            .set_vertex_buffer => {
                const command = (try iterator.nextCommand(commands.SetVertexBufferCmd)).*;
                if (command.slot >= 16) return error.InvalidBufferRange;
                const buffer = try checkedBuffer(
                    self.options.guard,
                    command.buffer,
                    command.offset,
                    command.size,
                    (api.bitmask.BufferUsage{ .vertex = true }).toFlags(),
                );
                if (command.offset % 4 != 0 or command.buffer_size != buffer.size)
                    return error.InvalidBufferRange;
                (self.procs.cmd_bind_vertex_buffers orelse return error.MissingDeviceProc)(
                    cb,
                    command.slot,
                    1,
                    &buffer.handle,
                    &command.offset,
                );
                state.vertex_mask |= @as(u16, 1) << @intCast(command.slot);
            },
            .draw => {
                const command = (try iterator.nextCommand(commands.DrawCmd)).*;
                try self.syncRender(state, false);
                (self.procs.cmd_draw orelse return error.MissingDeviceProc)(
                    cb,
                    command.vertex_count,
                    command.instance_count,
                    command.first_vertex,
                    command.first_instance,
                );
            },
            .draw_indexed => {
                const command = (try iterator.nextCommand(commands.DrawIndexedCmd)).*;
                try self.syncRender(state, true);
                (self.procs.cmd_draw_indexed orelse return error.MissingDeviceProc)(
                    cb,
                    command.index_count,
                    command.instance_count,
                    command.first_index,
                    command.base_vertex,
                    command.first_instance,
                );
            },
            .draw_indirect, .draw_indexed_indirect => {
                const command = (try iterator.nextCommand(commands.DrawIndirectCmd)).*;
                const indexed = tag == .draw_indexed_indirect;
                const output = try self.consumeIndirect(.{
                    .buffer = command.indirect_buffer,
                    .offset = command.indirect_offset,
                    .indexed = indexed,
                }, state.selected_index);
                try self.syncRender(state, indexed);
                const proc = if (indexed)
                    self.procs.cmd_draw_indexed_indirect orelse return error.MissingDeviceProc
                else
                    self.procs.cmd_draw_indirect orelse return error.MissingDeviceProc;
                proc(cb, output.arguments.owner.native.handle, output.arguments.offset, 1, output.stride_bytes);
            },
            .multi_draw_indirect, .multi_draw_indexed_indirect => {
                const command = (try iterator.nextCommand(commands.MultiDrawIndirectCmd)).*;
                const indexed = tag == .multi_draw_indexed_indirect;
                const output = try self.consumeIndirect(.{
                    .buffer = command.indirect_buffer,
                    .offset = command.indirect_offset,
                    .indexed = indexed,
                    .multi = true,
                    .max_draw_count = command.max_draw_count,
                    .draw_count_buffer = command.draw_count_buffer,
                    .draw_count_offset = command.draw_count_offset,
                }, state.selected_index);
                try self.syncRender(state, indexed);
                const proc = if (indexed)
                    self.procs.cmd_draw_indexed_indirect orelse return error.MissingDeviceProc
                else
                    self.procs.cmd_draw_indirect orelse return error.MissingDeviceProc;
                for (0..output.draw_count) |index| {
                    const offset = output.arguments.offset +
                        @as(u64, index) * output.stride_bytes;
                    proc(cb, output.arguments.owner.native.handle, offset, 1, output.stride_bytes);
                }
            },
            .execute_bundles => try self.executeBundles(
                iterator,
                state,
                (try iterator.nextCommand(commands.ExecuteBundlesCmd)).count,
            ),
            .pixel_local_storage_barrier => return error.UnsupportedPixelLocalStorage,
            else => return error.InvalidCommandContext,
        }
    }
    fn syncRender(self: *Replay, state: *RenderState, indexed: bool) ReplayError!void {
        if (indexed and !state.index_buffer) return error.MissingIndexBuffer;
        if (state.programmable.current_pipeline) |pipeline| {
            _ = try resource(self.options.guard, pipeline_mod.Pipeline, pipeline);
            switch (pipeline.state) {
                .render => |render| for (render.vertex_buffers.items, 0..) |_, index| {
                    if (index >= 16 or state.vertex_mask & (@as(u16, 1) << @intCast(index)) == 0)
                        return error.MissingVertexBuffer;
                },
                .compute => return error.InvalidCommandContext,
            }
        }
        try state.programmable.syncAndRun(
            self.trackerContext(),
            vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS,
        );
    }
    fn executeBundles(
        self: *Replay,
        iterator: *stream.Iterator,
        state: *RenderState,
        count: u32,
    ) ReplayError!void {
        const refs = try iterator.nextData(commands.Ref, count);
        if (refs.len > max_command_count - self.command_count)
            return error.CommandCountExhausted;
        for (refs) |reference| {
            if (self.command_count == max_command_count) return error.CommandCountExhausted;
            self.command_count += 1;
            const bundle = try native_resources.resolveRenderBundleRefLocked(
                self.options.guard,
                self.options.core_device,
                reference,
            );
            if (bundle.attachmentState() != state.attachment_state)
                return error.InvalidBundle;
            if (self.bundle_depth == max_bundle_depth) return error.BundleDepthExhausted;
            for (self.bundle_stack[0..self.bundle_depth]) |ancestor|
                if (ancestor == bundle) return error.BundleCycle;
            self.bundle_stack[self.bundle_depth] = bundle;
            self.bundle_depth += 1;
            defer self.bundle_depth -= 1;
            var borrowed = bundle.iterator(self.options.guard);
            defer borrowed.deinit();
            var bundle_state: RenderState = .{
                .attachment_state = state.attachment_state,
                .depth_read_only = state.depth_read_only,
                .depth_stencil_aspects = state.depth_stencil_aspects,
                .stencil_read_only = state.stencil_read_only,
            };
            const debug_depth = self.debug_depth;
            while (try self.nextTag(&borrowed.iterator)) |tag| {
                switch (tag) {
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
                    .push_debug_group,
                    .pop_debug_group,
                    .insert_debug_marker,
                    .set_render_pipeline,
                    .execute_bundles,
                    => {},
                    else => return error.InvalidBundle,
                }
                try self.encodeBundleCommand(&borrowed.iterator, tag, &bundle_state);
            }
            if (debug_depth != self.debug_depth) return error.DebugGroupsUnbalanced;
        }
        state.programmable = .{};
        state.index_buffer = false;
        state.selected_index = null;
        state.vertex_mask = 0;
    }
};

fn validateIndirectSnapshot(expected: indirect_mod.IndirectDraw, actual: indirect_mod.IndirectDraw) ReplayError!void {
    inline for (@typeInfo(indirect_mod.IndirectDraw).@"struct".field_names) |field_name| {
        if (@field(expected, field_name) != @field(actual, field_name))
            return error.PassMetadataMismatch;
    }
}

fn captureReplayIndex(draw: *indirect_mod.IndirectDraw, selected: ?commands.SetIndexBufferCmd) ReplayError!void {
    if (!draw.indexed) return;
    const index = selected orelse return error.MissingIndexBuffer;
    const element_bytes: u64 = switch (index.format) {
        .uint16 => 2,
        .uint32 => 4,
        else => return error.InvalidBufferRange,
    };
    if (index.size % element_bytes != 0) return error.InvalidBufferRange;
    draw.index_buffer = index.buffer;
    draw.index_buffer_offset = index.offset;
    draw.index_buffer_size = index.size;
    draw.index_format = index.format;
    draw.index_element_count = @divExact(index.size, element_bytes);
}

const RenderPrepass = struct {
    replay: *Replay,
    attachment: *attachment_mod.CanonicalAttachmentState,
    metadata: *const indirect_mod.IndirectDrawMetadata,
    inputs: []native_indirect.DrawInput,
    draw_index: usize = 0,
    draw_slots: u64 = 0,
    command_count: usize = 0,
    stack: [max_bundle_depth]?*bundle_mod.RenderBundle = @splat(null),
    depth: usize = 0,
    external_groups: std.AutoArrayHashMapUnmanaged(*native_resources.BindGroup, void) = .empty,
    external_plane_stages: ExternalPlaneStages = .empty,
    writable_buffers: std.AutoArrayHashMapUnmanaged(*buffer_mod.Buffer, void) = .empty,

    fn deinit(self: *RenderPrepass) void {
        self.external_groups.deinit(self.replay.allocator);
        self.external_plane_stages.deinit(self.replay.allocator);
        self.writable_buffers.deinit(self.replay.allocator);
    }

    fn draw(self: *RenderPrepass, command: indirect_mod.IndirectDraw, selected: ?commands.SetIndexBufferCmd) ReplayError!void {
        if (self.draw_index >= self.metadata.draws.items.len) return error.PassMetadataMismatch;
        if ((command.indexed and self.replay.procs.cmd_draw_indexed_indirect == null) or
            (!command.indexed and self.replay.procs.cmd_draw_indirect == null))
            return error.MissingDeviceProc;
        var actual = command;
        actual.index = @intCast(self.draw_index);
        try captureReplayIndex(&actual, selected);
        try validateIndirectSnapshot(self.metadata.draws.items[self.draw_index], actual);
        self.draw_slots += actual.max_draw_count;
        if (self.draw_slots > max_command_count) return error.CommandCountExhausted;
        const owner = try native_resources.resolveBufferRefLocked(
            self.replay.options.guard,
            self.replay.options.core_device,
            actual.buffer,
        );
        const stride: u64 = if (actual.indexed) 20 else 16;
        const size = @as(u64, actual.max_draw_count) * stride;
        _ = try checkedBuffer(self.replay.options.guard, actual.buffer, actual.offset, size, (api.bitmask.BufferUsage{ .indirect = true }).toFlags());
        if (actual.offset % 4 != 0) return error.InvalidBufferRange;
        var count: ?kernels.BufferRange = null;
        if (actual.draw_count_buffer != null) {
            const count_owner = try native_resources.resolveBufferRefLocked(
                self.replay.options.guard,
                self.replay.options.core_device,
                actual.draw_count_buffer,
            );
            _ = try checkedBuffer(self.replay.options.guard, actual.draw_count_buffer, actual.draw_count_offset, 4, (api.bitmask.BufferUsage{ .indirect = true }).toFlags());
            if (actual.draw_count_offset % 4 != 0) return error.InvalidBufferRange;
            count = .{ .owner = count_owner, .offset = actual.draw_count_offset, .size = 4 };
        }
        self.inputs[self.draw_index] = .{
            .command_index = actual.index,
            .arguments = .{ .owner = owner, .offset = actual.offset, .size = size },
            .indexed = actual.indexed,
            .max_draw_count = actual.max_draw_count,
            .count = count,
            .index_element_count = actual.index_element_count,
        };
        self.draw_index += 1;
    }

    fn group(self: *RenderPrepass, reference: commands.Ref) ReplayError!?*native_resources.BindGroup {
        if (reference == null) return null;
        const owner = try native_resources.resolveBindGroupRefLocked(
            self.replay.options.guard,
            self.replay.options.core_device,
            reference,
        );
        for (owner.native.bindings) |binding| switch (binding) {
            .buffer => |value| if (value.kind == .storage or value.kind == .internal_storage) {
                try self.writable_buffers.put(self.replay.allocator, value.buffer, {});
            },
            else => {},
        };
        return owner;
    }

    fn usedGroups(
        self: *RenderPrepass,
        pipeline: ?*pipeline_mod.Pipeline,
        groups: [max_bind_groups]?*native_resources.BindGroup,
    ) ReplayError!void {
        const current = pipeline orelse return error.PipelineNotSet;
        for (groups, 0..) |bound_group, index| {
            if (current.bind_group_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            const owner = bound_group orelse return error.MissingBindGroup;
            if (owner.external_textures.len == 0) continue;
            const entry = try self.external_groups.getOrPut(self.replay.allocator, owner);
            if (entry.found_existing) continue;
            for (owner.native.bindings) |binding| {
                const view = switch (binding) {
                    .texture => |value| if (!value.storage) value.view else continue,
                    .combined_y_cb_cr_view => |value| value.view,
                    else => continue,
                };
                var external_plane = false;
                for (owner.external_textures) |value| {
                    external_plane = external_plane or value.planes[0] == view or
                        value.planes[1] == view;
                }
                if (!external_plane) continue;
                const binding_stages = switch (binding) {
                    .texture => |value| value.stages,
                    .combined_y_cb_cr_view => |value| value.stages,
                    else => unreachable,
                };
                const render_stages = binding_stages.toFlags() &
                    (buffer_mod.ShaderStage{ .vertex = true, .fragment = true }).toFlags();
                if (render_stages == 0) continue;
                const merged = try self.external_plane_stages.getOrPut(self.replay.allocator, .{
                    .texture = view.texture,
                    .range = view.range,
                });
                const previous: u32 = if (merged.found_existing)
                    merged.value_ptr.toFlags()
                else
                    0;
                merged.value_ptr.* = @bitCast(previous | render_stages);
            }
        }
    }
    fn walk(self: *RenderPrepass, iterator: *stream.Iterator, in_bundle: bool) ReplayError!void {
        var selected: ?commands.SetIndexBufferCmd = null;
        var pipeline: ?*pipeline_mod.Pipeline = null;
        var groups: [max_bind_groups]?*native_resources.BindGroup = @splat(null);
        while (true) {
            if (self.command_count == max_command_count) return error.CommandCountExhausted;
            const tag = try iterator.nextTag() orelse {
                if (in_bundle) return;
                return error.MissingPassEnd;
            };
            self.command_count += 1;
            try validateContext(.render, tag);
            if (in_bundle) switch (tag) {
                .draw, .draw_indexed, .draw_indirect, .draw_indexed_indirect, .multi_draw_indirect, .multi_draw_indexed_indirect, .set_index_buffer, .set_vertex_buffer, .set_bind_group, .set_immediates, .set_resource_table, .set_stencil_reference, .push_debug_group, .pop_debug_group, .insert_debug_marker, .set_render_pipeline, .execute_bundles => {},
                else => return error.InvalidBundle,
            };
            switch (tag) {
                .end_render_pass => {
                    _ = try iterator.nextCommand(commands.EndRenderPassCmd);
                    return;
                },
                .set_render_pipeline => {
                    const command = (try iterator.nextCommand(commands.SetRenderPipelineCmd)).*;
                    const owner = try native_resources.resolvePipelineRefLocked(
                        self.replay.options.guard,
                        self.replay.options.core_device,
                        command.pipeline,
                    );
                    if (owner.attachment != .render or
                        owner.attachment.render != self.attachment or
                        command.attachment_state != self.attachment)
                        return error.PipelineAttachmentMismatch;
                    pipeline = owner.native;
                },
                .draw, .draw_indexed => {
                    try self.usedGroups(pipeline, groups);
                    try commands.skip(iterator, tag);
                },
                .set_index_buffer => {
                    const command = (try iterator.nextCommand(commands.SetIndexBufferCmd)).*;
                    const owner = try native_resources.resolveBufferRefLocked(
                        self.replay.options.guard,
                        self.replay.options.core_device,
                        command.buffer,
                    );
                    const element_bytes: u64 = switch (command.format) {
                        .uint16 => 2,
                        .uint32 => 4,
                        else => return error.InvalidBufferRange,
                    };
                    _ = try checkedBuffer(self.replay.options.guard, command.buffer, command.offset, command.size, (api.bitmask.BufferUsage{ .index = true }).toFlags());
                    if (command.buffer_size != owner.native.size or
                        command.offset % element_bytes != 0 or command.size % element_bytes != 0)
                        return error.InvalidBufferRange;
                    selected = command;
                },
                .set_bind_group => {
                    const command = (try iterator.nextCommand(commands.SetBindGroupCmd)).*;
                    if (command.dynamic_offset_count != 0)
                        _ = try iterator.nextData(u32, command.dynamic_offset_count);
                    if (command.index >= groups.len) return error.BindGroupIndexOutOfRange;
                    groups[command.index] = try self.group(command.group);
                },
                .draw_indirect, .draw_indexed_indirect => {
                    const command = (try iterator.nextCommand(commands.DrawIndirectCmd)).*;
                    try self.draw(.{ .buffer = command.indirect_buffer, .offset = command.indirect_offset, .indexed = tag == .draw_indexed_indirect }, selected);
                    try self.usedGroups(pipeline, groups);
                },
                .multi_draw_indirect, .multi_draw_indexed_indirect => {
                    const command = (try iterator.nextCommand(commands.MultiDrawIndirectCmd)).*;
                    try self.draw(.{
                        .buffer = command.indirect_buffer,
                        .offset = command.indirect_offset,
                        .indexed = tag == .multi_draw_indexed_indirect,
                        .multi = true,
                        .max_draw_count = command.max_draw_count,
                        .draw_count_buffer = command.draw_count_buffer,
                        .draw_count_offset = command.draw_count_offset,
                    }, selected);
                    try self.usedGroups(pipeline, groups);
                },
                .execute_bundles => {
                    const count = (try iterator.nextCommand(commands.ExecuteBundlesCmd)).count;
                    const references = try iterator.nextData(commands.Ref, count);
                    if (references.len > max_command_count - self.command_count)
                        return error.CommandCountExhausted;
                    for (references) |reference| {
                        if (self.command_count == max_command_count)
                            return error.CommandCountExhausted;
                        self.command_count += 1;
                        const bundle = try native_resources.resolveRenderBundleRefLocked(
                            self.replay.options.guard,
                            self.replay.options.core_device,
                            reference,
                        );
                        if (bundle.attachmentState() != self.attachment) return error.InvalidBundle;
                        if (self.depth == max_bundle_depth) return error.BundleDepthExhausted;
                        for (self.stack[0..self.depth]) |ancestor|
                            if (ancestor == bundle) return error.BundleCycle;
                        self.stack[self.depth] = bundle;
                        self.depth += 1;
                        defer self.depth -= 1;
                        var cursor = bundle.iterator(self.replay.options.guard);
                        defer cursor.deinit();
                        try self.walk(&cursor.iterator, true);
                    }
                    selected = null;
                    pipeline = null;
                    groups = @splat(null);
                },
                else => try commands.skip(iterator, tag),
            }
        }
    }
};

fn prepareRenderUtilities(replay: *Replay, iterator: *const stream.Iterator, begin: commands.BeginRenderPassCmd, usage: *const usage_mod.RenderPassResourceUsage, outputs: []native_indirect.DrawOutput) ReplayError!void {
    const metadata = replay.indirect_metadata orelse return error.PassMetadataMismatch;
    if (metadata.draws.items.len > max_command_count or
        metadata.next_draw_index != metadata.draws.items.len or
        outputs.len != metadata.draws.items.len) return error.PassMetadataMismatch;
    const inputs = try replay.allocator.alloc(native_indirect.DrawInput, outputs.len);
    defer replay.allocator.free(inputs);
    var prepass: RenderPrepass = .{
        .replay = replay,
        .attachment = begin.attachment_state,
        .metadata = metadata,
        .inputs = inputs,
    };
    defer prepass.deinit();
    var cursor = iterator.*;
    try prepass.walk(&cursor, false);
    if (prepass.draw_index != inputs.len or prepass.draw_slots != metadata.draw_slot_count)
        return error.PassMetadataMismatch;
    if (usage.scope.buffers.items.len != usage.scope.buffer_sync_infos.items.len)
        return error.PassMetadataMismatch;
    const writable_usage = (api.bitmask.BufferUsage{
        .storage = true,
        .copy_dst = true,
        .map_write = true,
        .query_resolve = true,
        .texel_buffer = true,
    }).toFlags() | buffer_mod.internal_storage_buffer;
    if (usage.scope.buffers.items.len > max_command_count) return error.CommandCountExhausted;
    for (usage.scope.buffers.items, usage.scope.buffer_sync_infos.items) |reference, info| {
        if (info.usage & writable_usage == 0) continue;
        const owner = try native_resources.resolveBufferRefLocked(
            replay.options.guard,
            replay.options.core_device,
            reference,
        );
        try prepass.writable_buffers.put(replay.allocator, owner.native, {});
    }
    for (inputs) |input| {
        if (prepass.writable_buffers.contains(input.arguments.owner.native))
            return error.IndirectBufferWrittenInRenderPass;
        if (input.count) |count|
            if (prepass.writable_buffers.contains(count.owner.native))
                return error.IndirectBufferWrittenInRenderPass;
    }
    var covered: usize = 0;
    for (metadata.batches.items) |batch| {
        if (batch.first_draw != covered or batch.draw_count == 0 or
            batch.draw_count > indirect_mod.max_batch_draws or
            batch.draw_count > inputs.len - covered) return error.PassMetadataMismatch;
        for (metadata.draws.items[covered..][0..batch.draw_count]) |draw| {
            if (draw.buffer != batch.buffer or draw.draw_count_buffer != batch.draw_count_buffer)
                return error.PassMetadataMismatch;
        }
        covered += batch.draw_count;
    }
    if (covered != inputs.len) return error.PassMetadataMismatch;
    try prepareResourcesForSyncScope(replay, &usage.scope);
    for (prepass.external_groups.keys()) |owner|
        try replay.prepareExternalGroup(owner, .{ .vertex = true, .fragment = true }, &usage.scope, &prepass.external_plane_stages);
    for (metadata.batches.items) |batch| {
        const batch_inputs = inputs[batch.first_draw..][0..batch.draw_count];
        for (batch_inputs, 0..) |*input, index| input.command_index = @intCast(index);
        try native_indirect.sanitizeDraws(replay.kernelContext(), batch_inputs, outputs[batch.first_draw..][0..batch.draw_count]);
    }
}

/// Borrows Finished on every outcome; the caller owns its success consumption.
/// Uses the supplied guard without acquiring the object mutex again.
pub fn recordCommands(
    allocator: std.mem.Allocator,
    options: RecordOptions,
    finished: *const encoding.Finished,
) ReplayError!void {
    options.guard.assertOwns(options.core_device.borrow().objectList());
    errdefer options.queue.poisonRecording();
    if (finished.status != .finished) return error.InvalidFinishedStatus;
    // Borrow the block array: failure and success both leave ownership with the caller.
    if (finished.device.objectList() != options.core_device.borrow().objectList())
        return error.InvalidResourceRef;
    var iterator = stream.Iterator.init(allocator, finished.blocks);
    const procs = options.queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    if (options.queue.commandBuffer() == null) return error.InvalidResourceRef;
    options.recording.command_buffer = options.queue.commandBuffer();
    var replay: Replay = .{ .allocator = allocator, .options = options, .procs = procs };
    while (try replay.nextTag(&iterator)) |tag| {
        try validateContext(.top_level, tag);
        switch (tag) {
            .begin_render_pass => {
                const begin = (try iterator.nextCommand(commands.BeginRenderPassCmd)).*;
                try replay.label(&iterator, begin.label_length, .pass_label);
                if (replay.render_index >= finished.render_pass_usages.items.len or
                    replay.render_index >= finished.indirect_draws.items.len)
                    return error.PassMetadataMismatch;
                const usage = &finished.render_pass_usages.items[replay.render_index];
                if (usage.attachment_state != begin.attachment_state)
                    return error.PassMetadataMismatch;
                try validateBeginSemantic(options.guard, options.core_device, begin);
                replay.indirect_metadata = &finished.indirect_draws.items[replay.render_index];
                replay.indirect_index = 0;
                replay.render_index += 1;
                try replay.recordRenderPass(&iterator, begin, usage);
                if (replay.indirect_index != replay.indirect_metadata.?.draws.items.len)
                    return error.PassMetadataMismatch;
            },
            .begin_compute_pass => {
                const begin = (try iterator.nextCommand(commands.BeginComputePassCmd)).*;
                try replay.label(&iterator, begin.label_length, .pass_label);
                if (replay.compute_index >= finished.compute_pass_usages.items.len)
                    return error.PassMetadataMismatch;
                const usage = &finished.compute_pass_usages.items[replay.compute_index];
                replay.compute_index += 1;
                try replay.recordComputePass(&iterator, begin, usage);
            },
            .clear_buffer => try copies.clearBuffer(
                replay.copyContext(),
                (try iterator.nextCommand(commands.ClearBufferCmd)).*,
            ),
            .copy_buffer_to_buffer => try copies.copyBufferToBuffer(
                replay.copyContext(),
                (try iterator.nextCommand(commands.CopyBufferToBufferCmd)).*,
            ),
            .copy_buffer_to_texture => try copies.copyBufferToTexture(
                replay.copyContext(),
                (try iterator.nextCommand(commands.CopyBufferToTextureCmd)).*,
            ),
            .copy_texture_to_buffer => try copies.copyTextureToBuffer(
                replay.copyContext(),
                (try iterator.nextCommand(commands.CopyTextureToBufferCmd)).*,
            ),
            .copy_texture_to_texture => try copies.copyTextureToTexture(
                replay.copyContext(),
                (try iterator.nextCommand(commands.CopyTextureToTextureCmd)).*,
            ),
            .copy_texture_for_browser => try copies.copyTextureForBrowser(
                replay.copyContext(),
                (try iterator.nextCommand(commands.CopyTextureForBrowserCmd)).*,
            ),
            .copy_external_texture_for_browser => try copies.copyExternalTextureForBrowser(
                replay.copyContext(),
                (try iterator.nextCommand(commands.CopyExternalTextureForBrowserCmd)).*,
            ),
            .write_buffer => {
                const command = (try iterator.nextCommand(commands.WriteBufferCmd)).*;
                const bytes = try iterator.nextData(u8, command.size);
                try copies.writeBuffer(replay.copyContext(), command, bytes);
            },
            .resolve_query_set => try recordResolveQuerySetCmd(
                &replay,
                (try iterator.nextCommand(commands.ResolveQuerySetCmd)).*,
            ),
            .write_timestamp => try recordWriteTimestampCmd(
                &replay,
                (try iterator.nextCommand(commands.WriteTimestampCmd)).*,
                vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                true,
            ),
            .push_debug_group, .pop_debug_group, .insert_debug_marker => try replay.debugCommand(&iterator, tag),
            .begin_occlusion_query,
            .end_occlusion_query,
            .dispatch,
            .dispatch_indirect,
            .draw,
            .draw_indexed,
            .draw_indirect,
            .draw_indexed_indirect,
            .multi_draw_indirect,
            .multi_draw_indexed_indirect,
            .end_compute_pass,
            .end_render_pass,
            .execute_bundles,
            .pixel_local_storage_barrier,
            .set_compute_pipeline,
            .set_render_pipeline,
            .set_stencil_reference,
            .set_viewport,
            .set_scissor_rect,
            .set_blend_constant,
            .set_bind_group,
            .set_immediates,
            .set_index_buffer,
            .set_vertex_buffer,
            .set_resource_table,
            => return error.InvalidCommandContext,
        }
    }
    if (replay.render_index != finished.render_pass_usages.items.len or
        replay.render_index != finished.indirect_draws.items.len or
        replay.compute_index != finished.compute_pass_usages.items.len)
        return error.PassMetadataMismatch;
    if (replay.debug_depth != 0) return error.DebugGroupsUnbalanced;
    const eager_refs = options.recording.mappable_buffers_for_eager_transition.keys();
    if (eager_refs.len != 0) {
        if (procs.cmd_pipeline_barrier == null) return error.MissingDeviceProc;
        for (eager_refs) |reference| _ = try resource(options.guard, buffer_mod.Buffer, reference);
        // The set contains validated nonnull implementation pointers, checked above.
        const buffers: [*]const *buffer_mod.Buffer = @ptrCast(eager_refs.ptr);
        try buffer_mod.Buffer.transitionMappableBuffersEagerly(
            buffers[0..eager_refs.len],
            replay.recording(),
        );
    }
    options.recording.needs_submit = replay.command_count > 1;
}

const RenderState = struct {
    programmable: ProgrammablePassState = .{},
    attachment_state: *attachment_mod.CanonicalAttachmentState,
    depth_stencil_aspects: u8 = 0,
    depth_read_only: bool = false,
    stencil_read_only: bool = false,
    index_buffer: bool = false,
    selected_index: ?commands.SetIndexBufferCmd = null,
    vertex_mask: u16 = 0,
};

fn validatePipelineDepthStencil(value: *pipeline_mod.Pipeline, state: *const RenderState) ReplayError!void {
    const render = switch (value.state) {
        .render => |*render| render,
        .compute => return error.PipelineKindMismatch,
    };
    try validateDepthStencil(render.depth_stencil, state);
}

fn validateDepthStencil(
    descriptor: ?pipeline_mod.DepthStencilState,
    state: *const RenderState,
) ReplayError!void {
    const depth = descriptor orelse return;
    const uses_depth = depth.depth_write_enabled or depth.depth_compare != .always;
    const front = depth.stencil_front;
    const back = depth.stencil_back;
    const writes_stencil = depth.stencil_write_mask != 0 and
        (front.fail_op != .keep or front.depth_fail_op != .keep or front.pass_op != .keep or
            back.fail_op != .keep or back.depth_fail_op != .keep or back.pass_op != .keep);
    const uses_stencil = writes_stencil or front.compare != .always or back.compare != .always;
    if (uses_depth and state.depth_stencil_aspects & 2 == 0)
        return error.PipelineAttachmentMismatch;
    if (uses_stencil and state.depth_stencil_aspects & 4 == 0)
        return error.PipelineAttachmentMismatch;
    if (depth.depth_write_enabled and state.depth_read_only)
        return error.PipelineAttachmentMismatch;
    if (writes_stencil and state.stencil_read_only) return error.PipelineAttachmentMismatch;
}

fn checkedBuffer(
    guard: *const core.ObjectGuard,
    reference: commands.Ref,
    offset: u64,
    size: u64,
    required_usage: u32,
) ReplayError!*buffer_mod.Buffer {
    const buffer = try resource(guard, buffer_mod.Buffer, reference);
    if (buffer.state == .destroyed or buffer.handle == null) return error.ResourceDestroyed;
    if (offset > buffer.size or size > buffer.size - offset or
        buffer.internal_usage & required_usage == 0)
        return error.InvalidBufferRange;
    return buffer;
}

pub fn prepareResourcesForSyncScope(
    replay: *Replay,
    scope: *const usage_mod.SyncScopeResourceUsage,
) ReplayError!void {
    if (scope.resource_table != null) return error.UnsupportedResourceTable;
    for (scope.external_textures.items) |reference|
        try replay.prepareExternalReference(reference);
    if (scope.buffers.items.len != scope.buffer_sync_infos.items.len)
        return error.PassMetadataMismatch;
    if (scope.buffers.items.len != 0 and replay.procs.cmd_pipeline_barrier == null)
        return error.MissingDeviceProc;
    var barrier: recording_mod.BufferBarrier = .{};
    for (scope.buffers.items, scope.buffer_sync_infos.items) |reference, info| {
        const buffer = try checkedBuffer(replay.options.guard, reference, 0, 0, info.usage);
        try buffer.validateCanUseOnQueueNow();
        defer buffer.finishUse();
        try buffer.ensureDataInitializedAsDestination(replay.recording(), 0, 0);
        const one = buffer.trackUsageAndGetResourceBarrier(
            replay.recording(),
            info.usage,
            @bitCast(info.shader_stages),
        );
        barrier.src_stage_mask |= one.src_stage_mask;
        barrier.dst_stage_mask |= one.dst_stage_mask;
        barrier.src_access_mask |= one.src_access_mask;
        barrier.dst_access_mask |= one.dst_access_mask;
        _ = try replay.options.recording.checkBufferNeedsEagerTransition(
            reference,
            @bitCast(buffer.internal_usage),
            @bitCast(info.usage),
        );
    }
    try prepareTexturesForSyncScope(
        replay.allocator,
        replay.options.guard,
        replay.options.queue,
        replay.recording(),
        replay.procs,
        scope.texture_sync_infos.items,
    );
    if (!barrier.isEmpty()) {
        const memory: vulkan.VkMemoryBarrier = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = barrier.src_access_mask,
            .dstAccessMask = barrier.dst_access_mask,
        };
        (replay.procs.cmd_pipeline_barrier orelse return error.MissingDeviceProc)(
            replay.recording().command_buffer,
            barrier.src_stage_mask,
            barrier.dst_stage_mask,
            0,
            1,
            &memory,
            0,
            null,
            0,
            null,
        );
    }
}

const CoupledTextureKey = struct {
    texture: *texture_mod.Texture,
    mip_level: u32,
    array_layer: u32,
};

const CoupledTextureUsage = struct {
    range: texture_mod.SubresourceRange,
    info: usage_mod.TextureSyncInfo,
};

fn syncTextureRange(
    guard: *const core.ObjectGuard,
    texture: *const texture_mod.Texture,
    entry: usage_mod.TextureSubresourceSyncInfo,
) ReplayError!texture_mod.SubresourceRange {
    const aspects: texture_mod.AspectMask = switch (entry.aspect) {
        .all => texture.getAspects(guard),
        .depth_only => .{ .depth = 1 },
        .stencil_only => .{ .stencil = 1 },
        .undefined_ => return error.InvalidResourceRef,
    };
    return .{
        .aspects = aspects,
        .base_array_layer = entry.array_layer,
        .layer_count = 1,
        .base_mip_level = entry.mip_level,
        .level_count = 1,
    };
}

/// Initialization records immediate transfer barriers and clears. Finish it for
/// every logical aspect before changing state for any deferred final barrier.
/// Depth/stencil uses one physical layout per mip/layer. Merge its final usage
/// and stages once, including aliases of single-aspect formats (.all/depth_only
/// or .all/stencil_only), before that single layout transition.
fn prepareTexturesForSyncScope(
    allocator: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    recording: buffer_mod.Recording,
    procs: *const dispatch.DeviceProcs,
    entries: []const usage_mod.TextureSubresourceSyncInfo,
) ReplayError!void {
    var images: texture_mod.BarrierBatch = .{};
    defer images.deinit(allocator);
    const max_barriers = std.math.mul(usize, entries.len, 3) catch
        return error.PassMetadataMismatch;
    try images.image_barriers.ensureTotalCapacity(allocator, max_barriers);
    // This map is empty and allocates nothing for color textures. Its
    // insertion order makes final transitions deterministic; keys are bounded
    // by the scope entries, never by the texture's full subresource state.
    var coupled: std.array_hash_map.Auto(CoupledTextureKey, CoupledTextureUsage) = .empty;
    defer coupled.deinit(allocator);
    for (entries) |entry| {
        const texture = try resource(guard, texture_mod.Texture, entry.texture);
        const range = try syncTextureRange(guard, texture, entry);
        const usage: api.bitmask.TextureUsage = @bitCast(entry.info.usage);
        if (texture.format_info.hasDepthOrStencil()) {
            // Validate each original entry. A valid merged peer must not hide
            // an empty usage, invalid range, or missing sampled shader stage.
            try texture.validateSyncScopeUsage(guard, range, usage, @bitCast(entry.info.shader_stages));
            const merged = try coupled.getOrPut(allocator, .{
                .texture = texture,
                .mip_level = entry.mip_level,
                .array_layer = entry.array_layer,
            });
            if (merged.found_existing) {
                const transient =
                    (api.bitmask.TextureUsage{ .transient_attachment = true }).toFlags();
                // Differing nontransient uses need per-aspect layout
                // compatibility, which this coupled layout path cannot express.
                if ((merged.value_ptr.info.usage & ~transient) != (entry.info.usage & ~transient))
                    return error.TextureNativeUsageUnsupported;
                merged.value_ptr.range.aspects =
                    merged.value_ptr.range.aspects.merge(range.aspects);
                merged.value_ptr.info.merge(entry.info);
            } else {
                merged.value_ptr.* = .{ .range = range, .info = entry.info };
            }
        }
        if (usage.toFlags() &
            ~(api.bitmask.TextureUsage{ .render_attachment = true }).toFlags() != 0)
            try texture.ensureSubresourceContentInitialized(guard, queue, recording, range);
    }
    for (entries) |entry| {
        const texture = try resource(guard, texture_mod.Texture, entry.texture);
        if (texture.format_info.hasDepthOrStencil()) continue;
        try texture.transitionInto(
            allocator,
            guard,
            try syncTextureRange(guard, texture, entry),
            @bitCast(entry.info.usage),
            @bitCast(entry.info.shader_stages),
            &images,
        );
    }
    for (coupled.keys(), coupled.values()) |key, value| {
        try key.texture.transitionInto(
            allocator,
            guard,
            value.range,
            @bitCast(value.info.usage),
            @bitCast(value.info.shader_stages),
            &images,
        );
    }
    if (images.image_barriers.items.len != 0) {
        const image_count = std.math.cast(u32, images.image_barriers.items.len) orelse
            return error.PassMetadataMismatch;
        (procs.cmd_pipeline_barrier orelse return error.MissingDeviceProc)(
            recording.command_buffer,
            images.source_stages,
            images.destination_stages,
            0,
            0,
            null,
            0,
            null,
            image_count,
            images.image_barriers.items.ptr,
        );
    }
}

pub fn resetUsedQuerySetsOnRenderPass(
    replay: *Replay,
    usage: *const usage_mod.RenderPassResourceUsage,
) ReplayError!void {
    if (usage.uses_framebuffer_fetch) return error.UnsupportedFramebufferFetch;
    if (usage.query_sets.items.len != usage.query_availabilities.items.len)
        return error.PassMetadataMismatch;
    for (usage.query_sets.items, usage.query_availabilities.items) |reference, bitmap|
        try query_vk.resetTrackedQueries(
            replay.allocator,
            replay.options.guard,
            replay.options.queue,
            try resource(replay.options.guard, query_mod.QuerySet, reference),
            bitmap.items,
        );
}

fn resetTimestampWrites(replay: *Replay, writes: commands.TimestampWrites) ReplayError!void {
    if (writes.isEmpty()) return;
    const set = try resource(replay.options.guard, query_mod.QuerySet, writes.query_set);
    for ([_]u32{ writes.beginning_of_pass_write_index, writes.end_of_pass_write_index }) |index| {
        if (index == commands.undefined_query_index) continue;
        if (index >= set.query_count) return error.QueryIndexOutOfRange;
        try replay.options.queue.trackQuerySet(replay.options.guard, set);
        const pool = try query_vk.getPool(replay.options.guard, set);
        (replay.procs.cmd_reset_query_pool orelse return error.MissingDeviceProc)(
            replay.recording().command_buffer,
            pool,
            index,
            1,
        );
    }
}

pub fn recordWriteTimestampCmd(
    replay: *Replay,
    command: commands.WriteTimestampCmd,
    stage: vulkan.VkPipelineStageFlagBits,
    reset: bool,
) ReplayError!void {
    try query_vk.writeTimestamp(
        replay.allocator,
        replay.options.guard,
        replay.options.queue,
        try resource(replay.options.guard, query_mod.QuerySet, command.query_set),
        command.query_index,
        stage,
        reset,
    );
}

pub fn recordResolveQuerySetCmd(
    replay: *Replay,
    command: commands.ResolveQuerySetCmd,
) ReplayError!void {
    const size = @as(u64, command.query_count) * 8;
    const owner = try native_resources.resolveBufferRefLocked(
        replay.options.guard,
        replay.options.core_device,
        command.destination,
    );
    const buffer = try checkedBuffer(
        replay.options.guard,
        command.destination,
        command.destination_offset,
        size,
        (api.bitmask.BufferUsage{ .query_resolve = true }).toFlags(),
    );
    if (command.destination_offset % 256 != 0) return error.InvalidBufferRange;
    const set = try native_resources.resolveQuerySetRefLocked(
        replay.options.guard,
        replay.options.core_device,
        command.query_set,
    );
    if (set.query_type == .timestamp) {
        try native_timestamps.resolveTimestamps(replay.kernelContext(), set, command.first_query, command.query_count, .{ .owner = owner, .offset = command.destination_offset, .size = size }, replay.options.timestamp_quantization);
        return;
    }
    try buffer.validateCanUseOnQueueNow();
    defer buffer.finishUse();
    if (replay.procs.cmd_pipeline_barrier == null) return error.MissingDeviceProc;
    try buffer.ensureDataInitializedAsDestination(
        replay.recording(),
        command.destination_offset,
        size,
    );
    try buffer.transitionUsageNow(
        replay.recording(),
        (api.bitmask.BufferUsage{ .copy_dst = true }).toFlags(),
        .none,
    );
    try query_vk.resolveQueries(
        replay.allocator,
        replay.options.guard,
        replay.options.queue,
        set,
        command.first_query,
        command.query_count,
        buffer.handle,
        command.destination_offset,
    );
}

pub const ComponentType = format_mod.TextureComponentType;
pub fn toVkClearValue(
    color: commands.Color,
    component: ComponentType,
) ReplayError!vulkan.VkClearValue {
    const values = [_]f32{ color.r, color.g, color.b, color.a };
    for (values) |value| if (!std.math.isFinite(value)) return error.InvalidClearValue;
    var clear: vulkan.VkClearValue = .{ .color = std.mem.zeroes(vulkan.VkClearColorValue) };
    for (values, 0..) |value, index| {
        const wide: f64 = value;
        switch (component) {
            .float => clear.color.float32[index] = value,
            .uint => clear.color.uint32[index] = @intFromFloat(
                std.math.clamp(wide, 0, @as(f64, std.math.maxInt(u32))),
            ),
            .sint => clear.color.int32[index] = @intFromFloat(
                std.math.clamp(
                    wide,
                    @as(f64, std.math.minInt(i32)),
                    @as(f64, std.math.maxInt(i32)),
                ),
            ),
        }
    }
    return clear;
}

fn attachmentViewShape(
    guard: *const core.ObjectGuard,
    reference: commands.Ref,
    width: u32,
    height: u32,
    depth_slice: u32,
) AttachmentValidationError!attachment_mod.ViewShape {
    const view = try resolveViewLocked(guard, reference);
    const texture = view.texture;
    const aspects = view.aspects.toFlags();
    if (!view.usage.render_attachment or view.native_view == null or
        !view.format_info.caps.renderable or
        @backingInt(view.format_info.format) != @backingInt(view.format) or
        aspects == 0 or aspects & ~@as(u8, 7) != 0 or
        aspects & @backingInt(view.format_info.aspects) != aspects or
        view.range.aspects.toFlags() != aspects or
        view.range.level_count != 1 or view.range.layer_count != 1 or
        view.range.base_mip_level >= texture.mip_level_count)
        return error.InvalidAttachment;
    if (texture.sample_count > 1 and !view.format_info.caps.multisample)
        return error.InvalidAttachment;
    if (view.dimension != ._2d and view.dimension != ._3d) return error.InvalidAttachment;
    if (texture.dimension != ._3d and
        view.range.base_array_layer >= texture.getArrayLayers(guard))
        return error.InvalidAttachment;
    const extent = texture.getMipLevelSingleSubresourceVirtualSize(
        guard,
        view.range.base_mip_level,
    );
    if (extent.width != width or extent.height != height) return error.InvalidAttachment;
    if (texture.dimension == ._3d) {
        if (depth_slice >= extent.depth_or_array_layers) return error.InvalidAttachment;
    } else if (depth_slice != 0) return error.InvalidAttachment;
    return .{
        .format = @backingInt(view.format),
        .sample_count = texture.sample_count,
        .aspects = aspects,
    };
}

fn buildAttachmentValueLocked(
    guard: *const core.ObjectGuard,
    colors: []const commands.RenderPassColorAttachmentInfo,
    depth: commands.RenderPassDepthStencilAttachmentInfo,
    width: u32,
    height: u32,
) AttachmentValidationError!attachment_mod.AttachmentState {
    if (width == 0 or height == 0) return error.InvalidAttachment;
    if (colors.len > 8) return error.TooManyAttachments;
    var shapes: [8]attachment_mod.ColorShape = @splat(.{
        .view = null,
        .resolve_target = null,
        .expands_resolve = false,
    });
    for (colors, 0..) |color, index| {
        if (color.load_op == .expand_resolve_texture) return error.UnsupportedResolveExpansion;
        if (color.view == null) {
            if (color.resolve_target != null) return error.InvalidAttachment;
            continue;
        }
        if (color.load_op == .undefined_ or color.store_op == .undefined_)
            return error.InvalidAttachment;
        const source = try attachmentViewShape(guard, color.view, width, height, color.depth_slice);
        if (source.aspects != 1) return error.InvalidAttachment;
        shapes[index].view = source;
        if (color.resolve_target) |target_ref| {
            const target = try attachmentViewShape(guard, target_ref, width, height, 0);
            const target_view = try resolveViewLocked(guard, target_ref);
            const source_view = try resolveViewLocked(guard, color.view);
            if (source.sample_count == 1 or target.sample_count != 1 or
                target.format != source.format or target.aspects != 1 or
                !source_view.format_info.caps.resolve or
                target_view.texture.dimension != ._2d)
                return error.InvalidAttachment;
            shapes[index].resolve_target = target;
        }
    }
    var depth_shape: ?attachment_mod.ViewShape = null;
    if (depth.view != null) {
        if (depth.depth_load_op == .expand_resolve_texture or
            depth.stencil_load_op == .expand_resolve_texture)
            return error.UnsupportedResolveExpansion;
        const shape = try attachmentViewShape(guard, depth.view, width, height, 0);
        if (shape.aspects & 1 != 0 or shape.aspects & 6 == 0)
            return error.InvalidAttachment;
        const has_depth = shape.aspects & 2 != 0;
        const has_stencil = shape.aspects & 4 != 0;
        if ((!has_depth or depth.depth_read_only) and
            (depth.depth_load_op != .undefined_ or depth.depth_store_op != .undefined_))
            return error.InvalidAttachment;
        if (has_depth and !depth.depth_read_only and
            (depth.depth_load_op == .undefined_ or depth.depth_store_op == .undefined_))
            return error.InvalidAttachment;
        if ((!has_stencil or depth.stencil_read_only) and
            (depth.stencil_load_op != .undefined_ or depth.stencil_store_op != .undefined_))
            return error.InvalidAttachment;
        if (has_stencil and !depth.stencil_read_only and
            (depth.stencil_load_op == .undefined_ or depth.stencil_store_op == .undefined_))
            return error.InvalidAttachment;
        if (depth.depth_load_op == .clear and
            (!std.math.isFinite(depth.clear_depth) or depth.clear_depth < 0 or
                depth.clear_depth > 1)) return error.InvalidClearValue;
        depth_shape = shape;
    } else if (depth.depth_load_op != .undefined_ or depth.depth_store_op != .undefined_ or
        depth.stencil_load_op != .undefined_ or depth.stencil_store_op != .undefined_)
        return error.InvalidAttachment;
    return attachment_mod.AttachmentState.fromRenderPass(.{
        .colors = shapes[0..colors.len],
        .depth_stencil = depth_shape,
        .pls = null,
    }, .{ .max_color_attachments = 8, .max_storage_attachments = 4, .max_pls_bytes = 16 });
}

pub fn buildAttachmentStateLocked(
    guard: *const core.ObjectGuard,
    device: *core.Device,
    colors: []const commands.RenderPassColorAttachmentInfo,
    depth: commands.RenderPassDepthStencilAttachmentInfo,
    width: u32,
    height: u32,
) AttachmentValidationError!attachment_mod.AttachmentState {
    guard.assertOwns(device.borrow().objectList());
    return buildAttachmentValueLocked(guard, colors, depth, width, height);
}

fn validateBeginSemantic(
    guard: *const core.ObjectGuard,
    device: *core.Device,
    begin: commands.BeginRenderPassCmd,
) ReplayError!void {
    if (begin.msaa_render_to_single_sampled or begin.resolve_rect.hasValue())
        return error.UnsupportedResolveExpansion;
    const owner = try native_resources.resolveAttachmentRefLocked(
        guard,
        device,
        begin.attachment_state,
    );
    const actual = try buildAttachmentStateLocked(
        guard,
        device,
        &begin.color_attachments,
        begin.depth_stencil_attachment,
        begin.width,
        begin.height,
    );
    try owner.value.validateCanonical();
    if (owner.value.has_pls) return error.UnsupportedPixelLocalStorage;
    if (owner.value.expand_resolve.attachments_to_expand_resolve != 0)
        return error.UnsupportedResolveExpansion;
    if (!owner.value.eql(&actual)) return error.PipelineAttachmentMismatch;
}

pub fn buildRenderPassCacheQuery(
    guard: *const core.ObjectGuard,
    begin: commands.BeginRenderPassCmd,
) ReplayError!passes.RenderPassCacheQuery {
    if (begin.width == 0 or begin.height == 0) return error.InvalidAttachment;
    if (begin.msaa_render_to_single_sampled or begin.resolve_rect.hasValue())
        return error.UnsupportedResolveExpansion;
    var query: passes.RenderPassCacheQuery = .{};
    var samples: ?u32 = null;
    for (begin.color_attachments, 0..) |attachment, index| {
        if (attachment.view == null) continue;
        const view = try resource(guard, texture_mod.TextureView, attachment.view);
        if (attachment.load_op == .expand_resolve_texture)
            return error.UnsupportedResolveExpansion;
        if (attachment.load_op == .undefined_ or attachment.store_op == .undefined_ or
            view.range.level_count != 1 or view.range.layer_count != 1 or
            view.aspects.color != 1) return error.InvalidAttachment;
        if (samples) |count| {
            if (count != view.texture.sample_count) return error.InvalidAttachment;
        } else samples = view.texture.sample_count;
        query.setColor(.{
            .index = @intCast(index),
            .format = view.format,
            .load_op = @fromBackingInt(@intCast(@backingInt(attachment.load_op))),
            .store_op = @fromBackingInt(@intCast(@backingInt(attachment.store_op))),
            .has_resolve_target = attachment.resolve_target != null,
            .render_to_single_sampled = false,
        });
    }
    const depth = begin.depth_stencil_attachment;
    if (depth.view != null) {
        const view = try resource(guard, texture_mod.TextureView, depth.view);
        if (view.range.level_count != 1 or view.range.layer_count != 1)
            return error.InvalidAttachment;
        if (depth.depth_load_op == .expand_resolve_texture or
            depth.stencil_load_op == .expand_resolve_texture)
            return error.UnsupportedResolveExpansion;
        if (view.aspects.depth == 1 and !depth.depth_read_only and
            (depth.depth_load_op == .undefined_ or depth.depth_store_op == .undefined_))
            return error.InvalidAttachment;
        if (view.aspects.stencil == 1 and !depth.stencil_read_only and
            (depth.stencil_load_op == .undefined_ or depth.stencil_store_op == .undefined_))
            return error.InvalidAttachment;
        if (samples) |count| {
            if (count != view.texture.sample_count) return error.InvalidAttachment;
        } else samples = view.texture.sample_count;
        query.setDepthStencil(.{
            .format = view.format,
            .depth_load_op = if (depth.depth_load_op == .undefined_)
                .load
            else
                @fromBackingInt(@intCast(@backingInt(depth.depth_load_op))),
            .depth_store_op = if (depth.depth_store_op == .undefined_)
                .store
            else
                @fromBackingInt(@intCast(@backingInt(depth.depth_store_op))),
            .depth_read_only = depth.depth_read_only,
            .stencil_load_op = if (depth.stencil_load_op == .undefined_)
                .load
            else
                @fromBackingInt(@intCast(@backingInt(depth.stencil_load_op))),
            .stencil_store_op = if (depth.stencil_store_op == .undefined_)
                .store
            else
                @fromBackingInt(@intCast(@backingInt(depth.stencil_store_op))),
            .stencil_read_only = depth.stencil_read_only,
        });
    }
    query.setSampleCount(samples orelse return error.InvalidAttachment);
    return query;
}

pub fn buildFramebufferCacheQuery(
    guard: *const core.ObjectGuard,
    begin: commands.BeginRenderPassCmd,
    pass: passes.RenderPassInfo,
) ReplayError!frames.FramebufferCacheQuery {
    var query: frames.FramebufferCacheQuery = .{};
    query.key.setRenderPass(.{
        .pass_id = pass.unique_id,
        .width = begin.width,
        .height = begin.height,
    });
    // Match initializePassInfo: dense colors, depth-stencil, then resolves.
    // Attachment slots may have holes, but handles and clears use dense indices.
    for (begin.color_attachments) |attachment| {
        if (attachment.view == null) continue;
        const view = try resource(guard, texture_mod.TextureView, attachment.view);
        try query.addAttachment(.{
            .texture_view_id = @intFromPtr(view),
            .depth_slice = attachment.depth_slice,
            .image_view = try view.getAttachmentHandle(
                try view.texture.getNativeAllocator(guard),
                guard,
                attachment.depth_slice,
            ),
            .clear_value = try toVkClearValue(
                attachment.clear_color,
                view.format_info.aspect_info[0].base_type,
            ),
        });
    }
    const depth = begin.depth_stencil_attachment;
    if (depth.view != null) {
        const view = try resource(guard, texture_mod.TextureView, depth.view);
        try query.addAttachment(.{
            .texture_view_id = @intFromPtr(view),
            .image_view = try view.getAttachmentHandle(
                try view.texture.getNativeAllocator(guard),
                guard,
                0,
            ),
            .clear_value = .{
                .depthStencil = .{ .depth = depth.clear_depth, .stencil = depth.clear_stencil },
            },
        });
    }
    for (begin.color_attachments) |attachment| {
        if (attachment.resolve_target == null) continue;
        const view = try resource(guard, texture_mod.TextureView, attachment.resolve_target);
        try query.addAttachment(.{
            .texture_view_id = @intFromPtr(view),
            .image_view = try view.getAttachmentHandle(try view.texture.getNativeAllocator(guard), guard, 0),
        });
    }
    return query;
}

// Initialization tracks a whole 3D mip, not the selected attachment slice.
// A clear of one slice cannot initialize the other slices of that mip.
fn renderPassOverwritesSubresource(
    guard: *const core.ObjectGuard,
    begin: commands.BeginRenderPassCmd,
    view: *const texture_mod.TextureView,
) bool {
    guard.assertOwns(view.header.tracking);
    guard.assertOwns(view.texture.header.tracking);
    const extent = view.texture.getMipLevelSingleSubresourceVirtualSize(guard, view.range.base_mip_level);
    if (view.texture.dimension == ._3d and extent.depth_or_array_layers > 1) return false;
    if (begin.width != extent.width or begin.height != extent.height) return false;
    return begin.force_full_render_area or
        (begin.render_area.x == 0 and begin.render_area.y == 0 and
            begin.render_area.width == extent.width and begin.render_area.height == extent.height);
}

fn toVkViewport(command: commands.SetViewportCmd) vulkan.VkViewport {
    return .{
        .x = if (command.width == 0) 0 else command.x,
        .y = command.y + command.height,
        .width = if (command.width == 0) 1 else command.width,
        .height = if (command.width == 0) 0 else -command.height,
        .minDepth = command.min_depth,
        .maxDepth = command.max_depth,
    };
}

pub fn recordBeginRenderPass(
    replay: *Replay,
    begin: commands.BeginRenderPassCmd,
) ReplayError!void {
    if (replay.options.recording.active_render_pass != null) return error.InvalidCommandContext;
    try validateBeginSemantic(replay.options.guard, replay.options.core_device, begin);
    const depth = begin.depth_stencil_attachment;
    for (begin.color_attachments) |attachment| {
        if (attachment.view == null) continue;
        const view = try resource(replay.options.guard, texture_mod.TextureView, attachment.view);
        if (attachment.load_op == .load or !renderPassOverwritesSubresource(replay.options.guard, begin, view))
            try view.texture.ensureSubresourceContentInitialized(
                replay.options.guard,
                replay.options.queue,
                replay.recording(),
                view.range,
            );
        try view.texture.transition(
            replay.options.guard,
            replay.recording(),
            view.range,
            .{ .render_attachment = true },
            .none,
        );
        if (attachment.resolve_target != null) {
            const resolve = try resource(replay.options.guard, texture_mod.TextureView, attachment.resolve_target);
            if (!renderPassOverwritesSubresource(replay.options.guard, begin, resolve))
                try resolve.texture.ensureSubresourceContentInitialized(
                    replay.options.guard,
                    replay.options.queue,
                    replay.recording(),
                    resolve.range,
                );
            try resolve.texture.transition(
                replay.options.guard,
                replay.recording(),
                resolve.range,
                .{ .render_attachment = true },
                .none,
            );
        }
    }
    if (depth.view != null) {
        const view = try resource(replay.options.guard, texture_mod.TextureView, depth.view);
        if ((view.aspects.depth == 1 and
            (depth.depth_read_only or depth.depth_load_op == .load)) or
            (view.aspects.stencil == 1 and
                (depth.stencil_read_only or depth.stencil_load_op == .load)) or
            !renderPassOverwritesSubresource(replay.options.guard, begin, view))
            try view.texture.ensureSubresourceContentInitialized(
                replay.options.guard,
                replay.options.queue,
                replay.recording(),
                view.range,
            );
        try view.texture.transitionRenderAttachment(replay.options.guard, replay.recording(), view.range, .{
            .depth_read_only = begin.depth_stencil_attachment.depth_read_only,
            .stencil_read_only = begin.depth_stencil_attachment.stencil_read_only,
        });
    }
    const query = try buildRenderPassCacheQuery(replay.options.guard, begin);
    const pass = try replay.options.render_pass_cache.getRenderPass(replay.options.io, query);
    var frame_query = try buildFramebufferCacheQuery(replay.options.guard, begin, pass);
    const framebuffer = try replay.options.framebuffer_cache.getOrCreate(
        &frame_query,
        pass.render_pass,
    );
    // SAFETY: Vulkan writes both extent fields before this void output call returns.
    var granularity: vulkan.VkExtent2D = undefined;
    (replay.procs.get_render_area_granularity orelse return error.MissingDeviceProc)(
        replay.options.queue.context.vk_device,
        pass.render_pass,
        &granularity,
    );
    const info: vulkan.VkRenderPassBeginInfo = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = pass.render_pass,
        .framebuffer = framebuffer,
        .renderArea = try alignedRenderArea(granularity, begin),
        .clearValueCount = frame_query.key.attachment_count,
        .pClearValues = &frame_query.clear_values,
    };
    (replay.procs.cmd_begin_render_pass orelse return error.MissingDeviceProc)(
        replay.recording().command_buffer,
        &info,
        vulkan.VK_SUBPASS_CONTENTS_INLINE,
    );
    replay.options.recording.active_render_pass = pass.render_pass;
}

pub fn recordEndRenderPass(replay: *Replay) ReplayError!void {
    if (replay.options.recording.active_render_pass == null) return error.InvalidCommandContext;
    (replay.procs.cmd_end_render_pass orelse return error.MissingDeviceProc)(
        replay.recording().command_buffer,
    );
    replay.options.recording.active_render_pass = null;
}

fn finishAttachments(guard: *const core.ObjectGuard, begin: commands.BeginRenderPassCmd) ReplayError!void {
    for (begin.color_attachments) |attachment| {
        if (attachment.view == null) continue;
        const view = try resource(guard, texture_mod.TextureView, attachment.view);
        view.texture.setSubresourceContentInitialized(guard, attachment.store_op == .store, view.range);
        if (attachment.resolve_target != null) {
            const resolve = try resource(guard, texture_mod.TextureView, attachment.resolve_target);
            resolve.texture.setSubresourceContentInitialized(guard, true, resolve.range);
        }
    }
    const depth = begin.depth_stencil_attachment;
    if (depth.view != null) {
        const view = try resource(guard, texture_mod.TextureView, depth.view);
        var range = view.range;
        if (range.aspects.depth == 1) {
            range.aspects = .{ .depth = 1 };
            view.texture.setSubresourceContentInitialized(
                guard,
                depth.depth_read_only or depth.depth_store_op == .store,
                range,
            );
        }
        if (view.range.aspects.stencil == 1) {
            range.aspects = .{ .stencil = 1 };
            view.texture.setSubresourceContentInitialized(
                guard,
                depth.stencil_read_only or depth.stencil_store_op == .store,
                range,
            );
        }
    }
}

test "clear conversion clamps integer channels and rejects nonfinite stream values" {
    const uint_clear = try toVkClearValue(.{ .r = -1, .g = 42, .b = 1e20, .a = 0 }, .uint);
    try std.testing.expectEqual(@as(u32, 0), uint_clear.color.uint32[0]);
    try std.testing.expectEqual(@as(u32, 42), uint_clear.color.uint32[1]);
    try std.testing.expectEqual(std.math.maxInt(u32), uint_clear.color.uint32[2]);
    try std.testing.expectError(
        error.InvalidClearValue,
        toVkClearValue(.{ .r = std.math.nan(f32), .g = 0, .b = 0, .a = 0 }, .float),
    );
}

fn createReplayTestTexture(
    arena: *core.ObjectArena,
    guard: *const core.ObjectGuard,
    format_info: *const format_mod.Format,
) core.CreateError!*texture_mod.Texture {
    const texture = try arena.create(std.testing.allocator, guard, texture_mod.Texture, .{
        .kind = .texture,
        .initial_reference = .user,
    });
    texture.* = .{
        .header = texture.header,
        .format_info = format_info,
        .dimension = ._2d,
        .binding_view_dimension = ._2d,
        .base_size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
        .mip_level_count = 1,
        .sample_count = 1,
        .usage = .{ .render_attachment = true },
        .internal_usage = .{ .render_attachment = true },
        .view_formats = &.{},
        .compatibility_mode = false,
        .bytes = &.{},
        .subresource_offsets = &.{},
        .initialized = &.{},
        .native = null,
    };
    texture.header.attach(guard, std.testing.io);
    return texture;
}

fn createReplayTestView(
    arena: *core.ObjectArena,
    guard: *const core.ObjectGuard,
    texture: *texture_mod.Texture,
) (core.CreateError || core.ReferenceError)!*texture_mod.TextureView {
    const view = try arena.create(std.testing.allocator, guard, texture_mod.TextureView, .{
        .kind = .texture_view,
        .initial_reference = .user,
    });
    texture.header.retainLeaseLocked(guard) catch |err| {
        view.header.discardUnpublishedLocked(guard) catch unreachable;
        return err;
    };
    const usage = texture_mod.resolveViewUsage(texture.usage, .{});
    view.* = .{
        .header = view.header,
        .texture = texture,
        .parent_lease_held = true,
        .format = .rgba8_unorm,
        .format_info = texture.format_info,
        .dimension = ._2d,
        .aspects = .{ .color = 1 },
        .range = .{
            .aspects = .{ .color = 1 },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .usage = usage,
        .internal_usage = texture_mod.adjustViewInternalUsages(texture.format_info, usage, ._2d),
        .swizzle = .{ .r = .r, .g = .g, .b = .b, .a = .a },
    };
    view.header.attach(guard, std.testing.io);
    return view;
}

fn createReplayTestAttachment(
    arena: *core.ObjectArena,
    guard: *const core.ObjectGuard,
    value: attachment_mod.AttachmentState,
) core.CreateError!*attachment_mod.CanonicalAttachmentState {
    const state = try arena.create(
        std.testing.allocator,
        guard,
        attachment_mod.CanonicalAttachmentState,
        .{ .kind = .attachment_state, .initial_reference = .user },
    );
    state.* = .{ .header = state.header, .value = value };
    state.header.attach(guard, std.testing.io);
    return state;
}

test "begin semantic rebuild uses actual view formats holes samples and read only aspects" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    const texture = try createReplayTestTexture(
        &arena,
        &guard,
        &table[format_mod.computeFormatIndex(.rgba8_unorm).?],
    );
    defer texture.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    texture.sample_count = 4;
    const view = try createReplayTestView(&arena, &guard, texture);
    defer view.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    try std.testing.expectError(error.InvalidResourceRef, resource(
        &guard,
        texture_mod.TextureView,
        texture,
    ));
    view.native_view = @ptrFromInt(0x3000);
    defer view.native_view = null;
    var colors: [3]commands.RenderPassColorAttachmentInfo = @splat(.{});
    colors[2] = .{ .view = view, .load_op = .clear, .store_op = .store };
    const color_value = try buildAttachmentValueLocked(&guard, &colors, .{}, 4, 4);
    try std.testing.expectEqual(@as(u8, 4), color_value.color_attachments_set);
    try std.testing.expectEqual(@as(u32, 4), color_value.sample_count);
    try std.testing.expectEqual(@backingInt(view.format), color_value.color_formats[2]);
    colors[2].resolve_target = view;
    try std.testing.expectError(
        error.InvalidAttachment,
        buildAttachmentValueLocked(&guard, &colors, .{}, 4, 4),
    );
    colors[2].resolve_target = null;
    try std.testing.expectError(
        error.InvalidAttachment,
        buildAttachmentValueLocked(&guard, &colors, .{}, 5, 4),
    );
    view.format = .depth24_plus;
    view.format_info = &table[format_mod.computeFormatIndex(view.format).?];
    view.aspects = .{ .depth = 1 };
    view.range.aspects = view.aspects;
    var depth: commands.RenderPassDepthStencilAttachmentInfo = .{
        .view = view,
        .depth_read_only = true,
    };
    const depth_value = try buildAttachmentValueLocked(&guard, &.{}, depth, 4, 4);
    try std.testing.expectEqual(@as(u32, 4), depth_value.sample_count);
    try std.testing.expectEqual(@backingInt(view.format), depth_value.depth_stencil_format);
    view.format = .depth32_float;
    view.format_info = &table[format_mod.computeFormatIndex(view.format).?];
    const other = try buildAttachmentValueLocked(&guard, &.{}, depth, 4, 4);
    try std.testing.expect(!depth_value.eql(&other));
    depth.depth_load_op = .clear;
    try std.testing.expectError(
        error.InvalidAttachment,
        buildAttachmentValueLocked(&guard, &.{}, depth, 4, 4),
    );
    depth.depth_load_op = .undefined_;
    depth.stencil_load_op = .clear;
    try std.testing.expectError(
        error.InvalidAttachment,
        buildAttachmentValueLocked(&guard, &.{}, depth, 4, 4),
    );
    depth.stencil_load_op = .undefined_;
    view.native_view = null;
    view.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(
        error.ResourceDestroyed,
        buildAttachmentValueLocked(&guard, &.{}, depth, 4, 4),
    );
}

test "pipeline selected aspects reject writes to read only depth and stencil" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    const attachment = try createReplayTestAttachment(&arena, &guard, .{});
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    var state: RenderState = .{
        .attachment_state = attachment,
        .depth_stencil_aspects = 6,
        .depth_read_only = true,
        .stencil_read_only = true,
    };
    var depth: pipeline_mod.DepthStencilState = .{
        .format = pipeline_mod.depth_format,
        .depth_write_enabled = true,
    };
    try std.testing.expectError(
        error.PipelineAttachmentMismatch,
        validateDepthStencil(depth, &state),
    );
    depth.depth_write_enabled = false;
    depth.stencil_front.pass_op = .replace;
    try std.testing.expectError(
        error.PipelineAttachmentMismatch,
        validateDepthStencil(depth, &state),
    );
    state.stencil_read_only = false;
    try validateDepthStencil(depth, &state);
    state.depth_stencil_aspects = 2;
    try std.testing.expectError(
        error.PipelineAttachmentMismatch,
        validateDepthStencil(depth, &state),
    );
    depth.stencil_front.pass_op = .keep;
    depth.depth_compare = .less;
    state.depth_stencil_aspects = 4;
    try std.testing.expectError(
        error.PipelineAttachmentMismatch,
        validateDepthStencil(depth, &state),
    );
}

test "canonical begin recheck rejects live actual metadata changes and dead state" {
    var mutex: std.Io.Mutex = .init;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &mutex,
        .uncaptured_callback = struct {
            fn unexpected(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
                @panic("unexpected uncaptured error in canonical replay fixture");
            }
        }.unexpected,
    });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch unreachable;
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    const texture = try createReplayTestTexture(
        &device.arena,
        &guard,
        &table[format_mod.computeFormatIndex(.rgba8_unorm).?],
    );
    defer texture.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    const view = try createReplayTestView(&device.arena, &guard, texture);
    defer view.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    view.native_view = @ptrFromInt(0x3000);
    defer view.native_view = null;
    const colors = [_]commands.RenderPassColorAttachmentInfo{
        .{ .view = view, .load_op = .clear, .store_op = .store },
    };
    const value = try buildAttachmentStateLocked(&guard, &device, &colors, .{}, 4, 4);
    const attachment = try createReplayTestAttachment(&device.arena, &guard, value);
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    var begin: commands.BeginRenderPassCmd = .{
        .attachment_state = attachment,
        .width = 4,
        .height = 4,
    };
    begin.color_attachments[0] = colors[0];
    try validateBeginSemantic(&guard, &device, begin);
    texture.sample_count = 4;
    try std.testing.expectError(
        error.PipelineAttachmentMismatch,
        validateBeginSemantic(&guard, &device, begin),
    );
    texture.sample_count = 1;
    attachment.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(
        error.ResourceDestroyed,
        validateBeginSemantic(&guard, &device, begin),
    );
}

test "MSAA framebuffer images and clears follow native subpass references with color holes" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    const multisample = try createReplayTestTexture(&arena, &guard, &table[format_mod.computeFormatIndex(.rgba8_unorm).?]);
    defer multisample.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    multisample.sample_count = 4;
    const single_sample = try createReplayTestTexture(&arena, &guard, &table[format_mod.computeFormatIndex(.rgba8_unorm).?]);
    defer single_sample.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    single_sample.sample_count = 1;
    // These 2D handles are synthetic; only the native allocator owner is read.
    var image_owner: std.meta.Child(std.meta.Child(@TypeOf(multisample.native))) = undefined;
    image_owner.allocator = std.testing.allocator;
    image_owner.destroy_requested = false;
    multisample.native = &image_owner;
    single_sample.native = &image_owner;
    defer {
        multisample.native = null;
        single_sample.native = null;
    }
    var views: [3]*texture_mod.TextureView = undefined;
    var created_views: usize = 0;
    defer for (views[0..created_views]) |view| {
        view.native_view = null;
        view.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    };
    for (&views, 0..) |*slot, index| {
        const view = try createReplayTestView(&arena, &guard, if (index == 2) single_sample else multisample);
        slot.* = view;
        created_views += 1;
        view.format = if (index == 1) .depth24_plus_stencil8 else .rgba8_unorm;
        view.format_info = &table[format_mod.computeFormatIndex(view.format).?];
        view.dimension = ._2d;
        view.aspects = if (index == 1) .{ .depth = 1, .stencil = 1 } else .{ .color = 1 };
        view.range = .{
            .aspects = view.aspects,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        view.usage = .{ .render_attachment = true };
        view.swizzle = .{ .r = .r, .g = .g, .b = .b, .a = .a };
        view.native_view = @ptrFromInt(0x3000 + index * 0x1000);
    }
    const attachment = try createReplayTestAttachment(&arena, &guard, .{
        .color_attachments_set = 4,
        .color_formats = .{ 0, 0, @backingInt(views[0].format), 0, 0, 0, 0, 0 },
        .depth_stencil_format = @backingInt(views[1].format),
        .sample_count = 4,
    });
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    var begin: commands.BeginRenderPassCmd = .{
        .attachment_state = attachment,
        .width = 4,
        .height = 4,
    };
    begin.color_attachments[2] = .{
        .view = views[0],
        .resolve_target = views[2],
        .load_op = .clear,
        .store_op = .store,
        .clear_color = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 },
    };
    begin.depth_stencil_attachment = .{
        .view = views[1],
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .stencil_load_op = .clear,
        .stencil_store_op = .store,
        .clear_depth = 0.625,
        .clear_stencil = 37,
    };
    var native = passes.RenderPassCreateInfo.init();
    try passes.initializePassInfo(&native, try buildRenderPassCacheQuery(&guard, begin));
    const frame = try buildFramebufferCacheQuery(&guard, begin, .{ .unique_id = 17 });
    const subpass = native.subpass_descs[0];
    try std.testing.expectEqual(native.create_info.attachmentCount, frame.key.attachment_count);
    try std.testing.expectEqual(@as(u32, 3), frame.key.attachment_count);
    try std.testing.expectEqual(
        @as(u32, vulkan.VK_ATTACHMENT_UNUSED),
        subpass.pColorAttachments[0].attachment,
    );
    try std.testing.expectEqual(
        @as(u32, vulkan.VK_ATTACHMENT_UNUSED),
        subpass.pColorAttachments[1].attachment,
    );
    const color_index = subpass.pColorAttachments[2].attachment;
    const depth_index = subpass.pDepthStencilAttachment[0].attachment;
    const resolve_index = subpass.pResolveAttachments[2].attachment;
    try std.testing.expectEqual(views[0].native_view, frame.attachments[color_index]);
    try std.testing.expectEqual(views[1].native_view, frame.attachments[depth_index]);
    try std.testing.expectEqual(views[2].native_view, frame.attachments[resolve_index]);
    try std.testing.expectEqual(@as(f32, 0.25), frame.clear_values[color_index].color.float32[0]);
    try std.testing.expectEqual(
        @as(f32, 0.625),
        frame.clear_values[depth_index].depthStencil.depth,
    );
    try std.testing.expectEqual(
        @as(u32, 37),
        frame.clear_values[depth_index].depthStencil.stencil,
    );
}

test "render clears cover tracked mip extents rather than framebuffer or 3D slice extents" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    const texture = try createReplayTestTexture(&arena, &guard, &table[format_mod.computeFormatIndex(.rgba8_unorm).?]);
    defer texture.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    texture.dimension = ._3d;
    texture.base_size = .{ .width = 4, .height = 4, .depth_or_array_layers = 2 };
    texture.mip_level_count = 2;
    const view = try createReplayTestView(&arena, &guard, texture);
    defer view.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    view.range.base_mip_level = 0;
    const attachment = try createReplayTestAttachment(&arena, &guard, .{});
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    var begin: commands.BeginRenderPassCmd = .{
        .attachment_state = attachment,
        .width = 4,
        .height = 4,
        .force_full_render_area = true,
    };
    try std.testing.expectEqual(@as(u32, 1), texture.getArrayLayers(&guard));
    try std.testing.expect(!renderPassOverwritesSubresource(&guard, begin, view));
    texture.dimension = ._2d;
    try std.testing.expect(renderPassOverwritesSubresource(&guard, begin, view));
    begin.width = 2;
    begin.height = 2;
    try std.testing.expect(!renderPassOverwritesSubresource(&guard, begin, view));
    // The 2x2 framebuffer covers mip 1, but not mip 0 of the same texture.
    view.range.base_mip_level = 1;
    try std.testing.expect(renderPassOverwritesSubresource(&guard, begin, view));
    begin.force_full_render_area = false;
    begin.render_area = .{ .x = 1, .y = 0, .width = 1, .height = 2 };
    try std.testing.expect(!renderPassOverwritesSubresource(&guard, begin, view));
    begin.render_area = .{ .width = 2, .height = 2 };
    try std.testing.expect(renderPassOverwritesSubresource(&guard, begin, view));
}

const CoupledScopeFixture = struct {
    const Event = enum { barrier, depth_clear, stencil_clear };
    const Barrier = struct {
        image: vulkan.VkImageMemoryBarrier,
        source: vulkan.VkPipelineStageFlags,
        destination: vulkan.VkPipelineStageFlags,
    };

    texture: *texture_mod.Texture,
    guard: *const core.ObjectGuard,
    expected_aspects: vulkan.VkImageAspectFlags =
        vulkan.VK_IMAGE_ASPECT_DEPTH_BIT | vulkan.VK_IMAGE_ASPECT_STENCIL_BIT,
    emitted_layout: vulkan.VkImageLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
    stream_valid: bool = true,
    barriers: [8]Barrier,
    barrier_count: usize = 0,
    events: [12]Event,
    event_count: usize = 0,
    clear_count: usize = 0,
    initialized_at_clear: [2][2]bool,
    memory_properties: vulkan.VkPhysicalDeviceMemoryProperties = .{
        .memoryTypeCount = 1,
        .memoryTypes = [_]vulkan.VkMemoryType{
            .{ .propertyFlags = vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT },
        } ++ @as([31]vulkan.VkMemoryType, @splat(.{})),
    },

    fn procs() dispatch.DeviceProcs {
        var result = std.mem.zeroes(dispatch.DeviceProcs);
        result.create_image = &createImage;
        result.destroy_image = &destroyImage;
        result.get_image_memory_requirements = &requirements;
        result.allocate_memory = &allocateMemory;
        result.free_memory = &freeMemory;
        result.bind_image_memory = &bindMemory;
        result.cmd_pipeline_barrier = &barrier;
        result.cmd_clear_color_image = &clearColor;
        result.cmd_clear_depth_stencil_image = &clearDepthStencil;
        return result;
    }

    fn createImage(
        _: vulkan.VkDevice,
        _: [*c]const vulkan.VkImageCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkImage,
    ) callconv(.c) vulkan.VkResult {
        out.* = @ptrFromInt(1);
        return vulkan.VK_SUCCESS;
    }

    fn destroyImage(
        _: vulkan.VkDevice,
        _: vulkan.VkImage,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}

    fn requirements(
        _: vulkan.VkDevice,
        _: vulkan.VkImage,
        out: [*c]vulkan.VkMemoryRequirements,
    ) callconv(.c) void {
        out.* = .{ .size = 256, .alignment = 1, .memoryTypeBits = 1 };
    }

    fn allocateMemory(
        _: vulkan.VkDevice,
        _: [*c]const vulkan.VkMemoryAllocateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkDeviceMemory,
    ) callconv(.c) vulkan.VkResult {
        out.* = @ptrFromInt(2);
        return vulkan.VK_SUCCESS;
    }

    fn freeMemory(
        _: vulkan.VkDevice,
        _: vulkan.VkDeviceMemory,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}

    fn bindMemory(
        _: vulkan.VkDevice,
        _: vulkan.VkImage,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
    ) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }

    fn barrier(
        command_buffer: vulkan.VkCommandBuffer,
        source: vulkan.VkPipelineStageFlags,
        destination: vulkan.VkPipelineStageFlags,
        _: vulkan.VkDependencyFlags,
        _: u32,
        _: [*c]const vulkan.VkMemoryBarrier,
        _: u32,
        _: [*c]const vulkan.VkBufferMemoryBarrier,
        count: u32,
        images: [*c]const vulkan.VkImageMemoryBarrier,
    ) callconv(.c) void {
        const self: *CoupledScopeFixture = @ptrCast(@alignCast(command_buffer.?));
        for (0..count) |index| {
            const image = images[index];
            // Track the layout from emitted commands, not Texture's speculative state.
            self.stream_valid = self.stream_valid and image.oldLayout == self.emitted_layout and
                image.image == @as(vulkan.VkImage, @ptrFromInt(1)) and
                image.subresourceRange.aspectMask == self.expected_aspects and
                image.subresourceRange.baseMipLevel == 1 and
                image.subresourceRange.levelCount == 1 and
                image.subresourceRange.baseArrayLayer == 1 and
                image.subresourceRange.layerCount == 1;
            self.emitted_layout = image.newLayout;
            self.barriers[self.barrier_count] = .{
                .image = image,
                .source = source,
                .destination = destination,
            };
            self.barrier_count += 1;
            self.events[self.event_count] = .barrier;
            self.event_count += 1;
        }
    }

    fn clearColor(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkImage,
        _: vulkan.VkImageLayout,
        _: [*c]const vulkan.VkClearColorValue,
        _: u32,
        _: [*c]const vulkan.VkImageSubresourceRange,
    ) callconv(.c) void {
        const self: *CoupledScopeFixture = @ptrCast(@alignCast(command_buffer.?));
        self.stream_valid = false;
    }

    fn clearDepthStencil(
        command_buffer: vulkan.VkCommandBuffer,
        image: vulkan.VkImage,
        layout: vulkan.VkImageLayout,
        value: [*c]const vulkan.VkClearDepthStencilValue,
        count: u32,
        ranges: [*c]const vulkan.VkImageSubresourceRange,
    ) callconv(.c) void {
        const self: *CoupledScopeFixture = @ptrCast(@alignCast(command_buffer.?));
        self.stream_valid = self.stream_valid and image == @as(vulkan.VkImage, @ptrFromInt(1)) and
            layout == self.emitted_layout and
            layout == vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and
            value[0].depth == 0 and value[0].stencil == 0 and count == 1;
        const range = ranges[0];
        self.stream_valid = self.stream_valid and
            range.baseMipLevel == 1 and range.levelCount == 1 and
            range.baseArrayLayer == 1 and range.layerCount == 1;
        const event: Event = if (range.aspectMask == vulkan.VK_IMAGE_ASPECT_DEPTH_BIT)
            .depth_clear
        else if (range.aspectMask == vulkan.VK_IMAGE_ASPECT_STENCIL_BIT)
            .stencil_clear
        else blk: {
            self.stream_valid = false;
            break :blk .depth_clear;
        };
        self.initialized_at_clear[self.clear_count] = .{
            if (self.texture.format_info.hasDepth())
                self.texture.initialized[self.texture.subresourceIndex(self.guard, 1, 1, .depth)]
            else
                false,
            if (self.texture.format_info.hasStencil())
                self.texture.initialized[self.texture.subresourceIndex(self.guard, 1, 1, .stencil)]
            else
                false,
        };
        self.clear_count += 1;
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

test "scope initializes coupled depth stencil before one union-stage sampled barrier" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    var initialized: [8]bool = @splat(false);
    const texture = try createReplayTestTexture(&arena, &guard, &table[format_mod.computeFormatIndex(.depth24_plus_stencil8).?]);
    defer texture.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    texture.dimension = ._2d;
    texture.base_size = .{ .width = 4, .height = 4, .depth_or_array_layers = 2 };
    texture.mip_level_count = 2;
    texture.sample_count = 1;
    texture.internal_usage = .{ .texture_binding = true };
    texture.view_formats = &.{};
    texture.initialized = &initialized;
    texture.native = null;
    // SAFETY: All three counts start at zero. Callbacks write each entry before advancing its count.
    // Tests read only the counted prefixes, after checking the required barrier and clear counts.
    var fixture: CoupledScopeFixture = .{
        .texture = texture,
        .guard = &guard,
        .barriers = undefined,
        .events = undefined,
        .initialized_at_clear = undefined,
    };
    var procs = CoupledScopeFixture.procs();
    var handles: device_mod.HandleSet = .{};
    const context: buffer_mod.Device = .{
        .allocator = std.testing.allocator,
        .dispatch = .{ .global = null, .instance = null, .device = &procs },
        .vk_device = @ptrCast(&fixture),
        .memory_properties = &fixture.memory_properties,
        .non_coherent_atom_size = 1,
        .max_buffer_size = 4096,
        .handles = &handles,
    };
    try texture.initializeNative(std.testing.allocator, &guard, context);
    // Uncompressed lazy clears need no queue submission or temporary buffers.
    var queue: queue_mod.Queue = undefined;
    queue.context = .{
        .allocator = context.allocator,
        .dispatch = context.dispatch,
        .vk_device = context.vk_device,
        .vk_queue = @ptrCast(&fixture),
        .queue_family_index = 0,
        .memory_properties = context.memory_properties,
        .handles = &handles,
    };
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    var entries = [_]usage_mod.TextureSubresourceSyncInfo{
        .{
            .texture = texture,
            .mip_level = 1,
            .array_layer = 1,
            .aspect = .depth_only,
            .info = .{
                .usage = (api.bitmask.TextureUsage{ .texture_binding = true }).toFlags(),
                .shader_stages = (buffer_mod.ShaderStage{ .fragment = true }).toFlags(),
            },
        },
        .{
            .texture = texture,
            .mip_level = 1,
            .array_layer = 1,
            .aspect = .stencil_only,
            .info = .{
                .usage = (api.bitmask.TextureUsage{ .texture_binding = true }).toFlags(),
                .shader_stages = (buffer_mod.ShaderStage{ .vertex = true }).toFlags(),
            },
        },
    };
    try prepareTexturesForSyncScope(std.testing.allocator, &guard, &queue, recording, &procs, &entries);
    try std.testing.expect(fixture.stream_valid);
    try std.testing.expectEqual(@as(usize, 2), fixture.clear_count);
    try std.testing.expectEqualSlices(CoupledScopeFixture.Event, &.{
        .barrier, .depth_clear, .barrier, .stencil_clear, .barrier,
    }, fixture.events[0..fixture.event_count]);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &fixture.initialized_at_clear[0]);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &fixture.initialized_at_clear[1]);
    // Only mip 1, layer 1 is initialized, independently for each aspect.
    try std.testing.expectEqualSlices(
        bool,
        &.{ false, false, false, true, false, false, false, true },
        &initialized,
    );
    try std.testing.expectEqual(@as(usize, 3), fixture.barrier_count);
    const final = fixture.barriers[2];
    try std.testing.expectEqual(
        @as(vulkan.VkImageLayout, vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL),
        final.image.oldLayout,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkImageLayout, vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL),
        final.image.newLayout,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, vulkan.VK_ACCESS_TRANSFER_WRITE_BIT),
        final.image.srcAccessMask,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, vulkan.VK_ACCESS_SHADER_READ_BIT),
        final.image.dstAccessMask,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkPipelineStageFlags, vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
        final.source,
    );
    try std.testing.expectEqual(
        @as(
            vulkan.VkPipelineStageFlags,
            vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                vulkan.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,
        ),
        final.destination,
    );
    try prepareTexturesForSyncScope(std.testing.allocator, &guard, &queue, recording, &procs, &entries);
    try std.testing.expectEqual(@as(usize, 2), fixture.clear_count);
    try std.testing.expectEqual(@as(usize, 3), fixture.barrier_count);
    try std.testing.expectEqual(@as(usize, 5), fixture.event_count);
    // A valid sibling entry must not hide an invalid stageless sampled entry.
    entries[0].info.shader_stages = 0;
    try std.testing.expectError(
        error.TextureNativeUsageUnsupported,
        prepareTexturesForSyncScope(std.testing.allocator, &guard, &queue, recording, &procs, &entries),
    );
    try std.testing.expectEqual(@as(usize, 5), fixture.event_count);
    entries[0].info.shader_stages = (buffer_mod.ShaderStage{ .fragment = true }).toFlags();
    entries[1].info = .{ .usage = (api.bitmask.TextureUsage{ .copy_src = true }).toFlags() };
    try std.testing.expectError(
        error.TextureNativeUsageUnsupported,
        prepareTexturesForSyncScope(std.testing.allocator, &guard, &queue, recording, &procs, &entries),
    );
    try std.testing.expectEqual(@as(usize, 5), fixture.event_count);
    // Empty usage must also fail independently of its valid sampled sibling.
    entries[1].info.usage = 0;
    try std.testing.expectError(
        error.TextureNativeUsageUnsupported,
        prepareTexturesForSyncScope(std.testing.allocator, &guard, &queue, recording, &procs, &entries),
    );
    try std.testing.expectEqual(@as(usize, 5), fixture.event_count);
}

test "single-aspect depth stencil scope aliases share initialization and union shader stages" {
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    inline for (.{
        .{
            api.enums.TextureFormat.depth32_float,
            commands.TextureAspect.depth_only,
            vulkan.VK_IMAGE_ASPECT_DEPTH_BIT,
            CoupledScopeFixture.Event.depth_clear,
        },
        .{
            api.enums.TextureFormat.stencil8,
            commands.TextureAspect.stencil_only,
            vulkan.VK_IMAGE_ASPECT_STENCIL_BIT,
            CoupledScopeFixture.Event.stencil_clear,
        },
    }) |case| {
        var mutex: std.Io.Mutex = .init;
        var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
        defer guard.unlock(std.testing.io);
        defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
        var initialized: [4]bool = @splat(false);
        const texture = try createReplayTestTexture(&arena, &guard, &table[format_mod.computeFormatIndex(case[0]).?]);
        defer texture.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
        texture.dimension = ._2d;
        texture.base_size = .{ .width = 4, .height = 4, .depth_or_array_layers = 2 };
        texture.mip_level_count = 2;
        texture.sample_count = 1;
        texture.internal_usage = .{ .texture_binding = true };
        texture.view_formats = &.{};
        texture.initialized = &initialized;
        texture.native = null;
        // SAFETY: All three counts start at zero. Callbacks write entries before advancing each count.
        // Tests check the counts before reading the corresponding initialized prefixes.
        var fixture: CoupledScopeFixture = .{
            .texture = texture,
            .guard = &guard,
            .expected_aspects = case[2],
            .barriers = undefined,
            .events = undefined,
            .initialized_at_clear = undefined,
        };
        var procs = CoupledScopeFixture.procs();
        var handles: device_mod.HandleSet = .{};
        const context: buffer_mod.Device = .{
            .allocator = std.testing.allocator,
            .dispatch = .{ .global = null, .instance = null, .device = &procs },
            .vk_device = @ptrCast(&fixture),
            .memory_properties = &fixture.memory_properties,
            .non_coherent_atom_size = 1,
            .max_buffer_size = 4096,
            .handles = &handles,
        };
        try texture.initializeNative(std.testing.allocator, &guard, context);
        var queue: queue_mod.Queue = undefined;
        queue.context = .{
            .allocator = context.allocator,
            .dispatch = context.dispatch,
            .vk_device = context.vk_device,
            .vk_queue = @ptrCast(&fixture),
            .queue_family_index = 0,
            .memory_properties = context.memory_properties,
            .handles = &handles,
        };
        const recording: buffer_mod.Recording = .{
            .command_buffer = @ptrCast(&fixture),
            .pending_serial = 1,
        };
        const entries = [_]usage_mod.TextureSubresourceSyncInfo{
            .{
                .texture = texture,
                .mip_level = 1,
                .array_layer = 1,
                .aspect = .all,
                .info = .{
                    .usage = (api.bitmask.TextureUsage{ .texture_binding = true }).toFlags(),
                    .shader_stages = (buffer_mod.ShaderStage{ .fragment = true }).toFlags(),
                },
            },
            .{
                .texture = texture,
                .mip_level = 1,
                .array_layer = 1,
                .aspect = case[1],
                .info = .{
                    .usage = (api.bitmask.TextureUsage{ .texture_binding = true }).toFlags(),
                    .shader_stages = (buffer_mod.ShaderStage{ .vertex = true }).toFlags(),
                },
            },
        };
        try prepareTexturesForSyncScope(
            std.testing.allocator,
            &guard,
            &queue,
            recording,
            &procs,
            &entries,
        );
        try std.testing.expect(fixture.stream_valid);
        try std.testing.expectEqual(@as(usize, 1), fixture.clear_count);
        try std.testing.expectEqual(@as(usize, 2), fixture.barrier_count);
        try std.testing.expectEqualSlices(
            CoupledScopeFixture.Event,
            &.{ .barrier, case[3], .barrier },
            fixture.events[0..fixture.event_count],
        );
        try std.testing.expectEqualSlices(
            bool,
            &.{ false, false },
            &fixture.initialized_at_clear[0],
        );
        try std.testing.expectEqualSlices(bool, &.{ false, false, false, true }, &initialized);
        const final = fixture.barriers[1];
        try std.testing.expectEqual(
            @as(vulkan.VkImageLayout, vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL),
            final.image.oldLayout,
        );
        try std.testing.expectEqual(
            @as(vulkan.VkImageLayout, vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL),
            final.image.newLayout,
        );
        try std.testing.expectEqual(
            @as(vulkan.VkAccessFlags, vulkan.VK_ACCESS_TRANSFER_WRITE_BIT),
            final.image.srcAccessMask,
        );
        try std.testing.expectEqual(
            @as(vulkan.VkAccessFlags, vulkan.VK_ACCESS_SHADER_READ_BIT),
            final.image.dstAccessMask,
        );
        try std.testing.expectEqual(
            @as(vulkan.VkPipelineStageFlags, vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
            final.source,
        );
        try std.testing.expectEqual(
            @as(
                vulkan.VkPipelineStageFlags,
                vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                    vulkan.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,
            ),
            final.destination,
        );
        try prepareTexturesForSyncScope(
            std.testing.allocator,
            &guard,
            &queue,
            recording,
            &procs,
            &entries,
        );
        try std.testing.expectEqual(@as(usize, 1), fixture.clear_count);
        try std.testing.expectEqual(@as(usize, 2), fixture.barrier_count);
        try std.testing.expectEqual(@as(usize, 3), fixture.event_count);
    }
}
