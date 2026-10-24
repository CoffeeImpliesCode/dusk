//! Native blit pass construction and GPU-only buffer staging.
const std = @import("std");
const api = @import("../api/api.zig");
const vulkan = @import("vulkan");
const kernels = @import("native_kernels.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const attachment = @import("../command/attachment_state.zig");
const passes = @import("render_pass_cache.zig");
const frames = @import("framebuffer_cache.zig");

pub const Error = kernels.Error || passes.GetRenderPassError || frames.GetOrCreateError ||
    frames.AddAttachmentError || attachment.AttachmentError || texture.CreateError || error{
    InvalidBlitRegion,
    BlitSampleCountMismatch,
    BlitSourceTargetAlias,
    BlitFormatMismatch,
    BlitCommandLimitExceeded,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Target = struct {
    attachments: *attachment.CanonicalAttachmentState,
    colors: [8]?*texture.TextureView = @splat(null),
    depth_stencil: ?*texture.TextureView = null,
    depth_slice: u32 = 0,
    render_pass_cache: *passes.RenderPassCache,
    framebuffer_cache: *frames.FramebufferCache,
    width: u32,
    height: u32,
};

pub const Pass = struct {
    handle: vulkan.VkRenderPass,
    framebuffer: vulkan.VkFramebuffer,
};

pub fn recording(context: kernels.Context) buffer.Recording {
    std.debug.assert(context.recording.command_buffer == context.queue.commandBuffer());
    return .{
        .command_buffer = context.recording.command_buffer,
        .pending_serial = context.queue.timeline.nextSerial(),
    };
}

pub fn checkRect(target: Target, rectangle: Rect) Error!void {
    if (rectangle.x > target.width or rectangle.y > target.height or
        rectangle.width > target.width - rectangle.x or
        rectangle.height > target.height - rectangle.y)
        return error.InvalidBlitRegion;
    if (rectangle.x > std.math.maxInt(i32) or rectangle.y > std.math.maxInt(i32))
        return error.InvalidBlitRegion;
}

/// A nonempty texel interval must retain its unsigned bounds after WGSL i32 conversion.
pub fn validateSignedTexelRange(origin: u32, count: u32) Error!void {
    if (count == 0) return error.InvalidBlitRegion;
    const end = std.math.add(u64, origin, count) catch return error.InvalidBlitRegion;
    if (end - 1 > std.math.maxInt(i32)) return error.InvalidBlitRegion;
}

pub fn retainView(context: kernels.Context, view: *texture.TextureView) Error!void {
    try kernels.validateContext(context);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &view.header);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &view.texture.header);
}

/// Cube sampling has no load instruction. This real array view keeps the same subresources.
pub fn loadView(context: kernels.Context, source: *texture.TextureView) Error!*texture.TextureView {
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try retainView(context, source);
    if (source.dimension != .cube and source.dimension != .cube_array) return source;
    const aspect: api.TextureAspect = if (source.aspects.depth != 0) .depth_only else if (source.aspects.stencil != 0) .stencil_only else .all;
    return makeLoadView(context, source, aspect);
}

pub fn loadDepthView(context: kernels.Context, source: *texture.TextureView) Error!*texture.TextureView {
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try retainView(context, source);
    if (source.aspects.depth == 0) return error.BlitFormatMismatch;
    if (source.aspects.stencil == 0) return loadView(context, source);
    return makeLoadView(context, source, .depth_only);
}

fn makeLoadView(
    context: kernels.Context,
    source: *texture.TextureView,
    aspect: api.TextureAspect,
) Error!*texture.TextureView {
    const handle = try texture.Texture.createView(
        context.queue.context.allocator,
        context.io,
        context.guard,
        context.device,
        .{ .handle = @ptrCast(&source.texture.header) },
        .{
            .descriptor = .{
                .format = source.format,
                .dimension = if (source.dimension == .cube or source.dimension == .cube_array)
                    ._2d_array
                else
                    source.dimension,
                .base_mip_level = source.range.base_mip_level,
                .mip_level_count = source.range.level_count,
                .base_array_layer = source.range.base_array_layer,
                .array_layer_count = source.range.layer_count,
                .aspect = aspect,
                .usage = source.usage,
                .texture_component_swizzle_descriptor = if (source.isSwizzleIdentity(context.guard))
                    null
                else
                    .{ .swizzle = source.swizzle },
            },
            .format_info = source.format_info,
        },
    );
    const view = try texture.resolveTextureView(context.device, context.guard, handle);
    errdefer view.header.releaseUserLocked(context.guard, context.io) catch
        @panic("internal blit view creator release failed");
    try view.initializeNative(context.guard);
    try retainView(context, view);
    view.header.releaseUserLocked(context.guard, context.io) catch
        @panic("internal blit view creator release failed");
    return view;
}

fn validateTarget(context: kernels.Context, target: Target) Error!void {
    if (target.width == 0 or target.height == 0) return error.InvalidBlitRegion;
    try context.pending_uses.retainDerivedRootLocked(
        context.guard,
        context.device,
        &target.attachments.header,
    );
    var shapes: [8]attachment.ColorShape = @splat(.{ .view = null, .resolve_target = null, .expands_resolve = false });
    var color_count: usize = 0;
    for (target.colors, 0..) |maybe_view, slot| {
        const view = maybe_view orelse continue;
        color_count = slot + 1;
        try validateAttachmentView(context, target, view);
        if (view.aspects.color == 0) return error.BlitFormatMismatch;
        shapes[slot].view = .{
            .format = @backingInt(view.format),
            .sample_count = view.texture.sample_count,
            .aspects = view.aspects.toFlags(),
        };
    }
    var depth_shape: ?attachment.ViewShape = null;
    if (target.depth_stencil) |view| {
        try validateAttachmentView(context, target, view);
        if (view.aspects.depth == 0 and view.aspects.stencil == 0) return error.BlitFormatMismatch;
        depth_shape = .{
            .format = @backingInt(view.format),
            .sample_count = view.texture.sample_count,
            .aspects = view.aspects.toFlags(),
        };
    }
    const actual = try attachment.AttachmentState.fromRenderPass(.{
        .colors = shapes[0..color_count],
        .depth_stencil = depth_shape,
        .pls = null,
    }, .{
        .max_color_attachments = @min(8, context.cache.limits.v1.max_color_attachments),
        .max_storage_attachments = 4,
        .max_pls_bytes = 16,
    });
    if (!attachment.AttachmentState.eql(&actual, &target.attachments.value))
        return error.KernelAttachmentMismatch;
}

fn validateAttachmentView(context: kernels.Context, target: Target, view: *texture.TextureView) Error!void {
    try retainView(context, view);
    if (view.range.level_count != 1 or view.range.layer_count != 1 or
        (view.dimension != ._2d and view.dimension != ._3d) or
        !view.internal_usage.render_attachment)
        return error.TextureNativeUsageUnsupported;
    const extent = view.texture.getMipLevelSingleSubresourceVirtualSize(context.guard, view.range.base_mip_level);
    if (target.width > extent.width or target.height > extent.height)
        return error.InvalidBlitRegion;
    if ((view.dimension == ._3d and target.depth_slice >= extent.depth_or_array_layers) or
        (view.dimension != ._3d and target.depth_slice != 0))
        return error.InvalidBlitRegion;
    _ = try view.getHandle(context.guard);
}

pub fn createPass(context: kernels.Context, target: Target) Error!Pass {
    try kernels.validateContext(context);
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try validateTarget(context, target);
    var pass_query: passes.RenderPassCacheQuery = .{};
    pass_query.setSampleCount(target.attachments.value.sample_count);
    for (target.colors, 0..) |maybe_view, slot| {
        const view = maybe_view orelse continue;
        pass_query.setColor(.{
            .index = @intCast(slot),
            .format = view.format,
            .load_op = .load,
            .store_op = .store,
            .has_resolve_target = false,
            .render_to_single_sampled = false,
        });
    }
    if (target.depth_stencil) |view| {
        pass_query.setDepthStencil(.{
            .format = view.format,
            .depth_load_op = .load,
            .depth_store_op = .store,
            .depth_read_only = false,
            .stencil_load_op = .load,
            .stencil_store_op = .store,
            .stencil_read_only = false,
        });
    }
    const pass = try target.render_pass_cache.getRenderPass(context.io, pass_query);
    var frame_query: frames.FramebufferCacheQuery = .{};
    frame_query.key.setRenderPass(.{
        .pass_id = pass.unique_id,
        .width = target.width,
        .height = target.height,
    });
    for (target.colors) |maybe_view| {
        const view = maybe_view orelse continue;
        try frame_query.addAttachment(.{
            .texture_view_id = @intFromPtr(view),
            .depth_slice = target.depth_slice,
            .image_view = try view.getAttachmentHandle(
                try view.texture.getNativeAllocator(context.guard),
                context.guard,
                target.depth_slice,
            ),
        });
    }
    if (target.depth_stencil) |view| {
        try frame_query.addAttachment(.{
            .texture_view_id = @intFromPtr(view),
            .depth_slice = target.depth_slice,
            .image_view = try view.getAttachmentHandle(
                try view.texture.getNativeAllocator(context.guard),
                context.guard,
                target.depth_slice,
            ),
        });
    }
    const framebuffer = try target.framebuffer_cache.getOrCreate(&frame_query, pass.render_pass);
    const procs = context.queue.context.dispatch.device orelse return error.MissingDeviceProc;
    if (procs.cmd_begin_render_pass == null or procs.cmd_end_render_pass == null)
        return error.MissingDeviceProc;
    errdefer context.queue.poisonRecording();
    for (target.colors) |maybe_view| {
        const view = maybe_view orelse continue;
        try view.texture.ensureSubresourceContentInitialized(
            context.guard,
            context.queue,
            recording(context),
            view.range,
        );
        try view.texture.transition(context.guard, recording(context), view.range, .{ .render_attachment = true }, .none);
    }
    if (target.depth_stencil) |view| {
        try view.texture.ensureSubresourceContentInitialized(
            context.guard,
            context.queue,
            recording(context),
            view.range,
        );
        try view.texture.transitionRenderAttachment(context.guard, recording(context), view.range, .{
            .depth_read_only = false,
            .stencil_read_only = false,
        });
    }
    return .{ .handle = pass.render_pass, .framebuffer = framebuffer };
}

pub fn beginPass(context: kernels.Context, target: Target, pass: Pass) Error!void {
    try kernels.validateContext(context);
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    const procs = context.queue.context.dispatch.device orelse return error.MissingDeviceProc;
    const begin = procs.cmd_begin_render_pass orelse return error.MissingDeviceProc;
    if (procs.cmd_end_render_pass == null) return error.MissingDeviceProc;
    const info: vulkan.VkRenderPassBeginInfo = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = pass.handle,
        .framebuffer = pass.framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = target.width, .height = target.height } },
        .clearValueCount = 0,
        .pClearValues = null,
    };
    begin(context.recording.command_buffer, &info, vulkan.VK_SUBPASS_CONTENTS_INLINE);
    context.recording.active_render_pass = pass.handle;
    context.recording.has_recorded_render_pass = true;
    context.recording.needs_submit = true;
}

pub fn endPass(context: kernels.Context, target: Target) Error!void {
    try kernels.validateContext(context);
    if (context.recording.active_render_pass == null) return error.KernelAttachmentMismatch;
    const procs = context.queue.context.dispatch.device orelse return error.MissingDeviceProc;
    const end = procs.cmd_end_render_pass orelse return error.MissingDeviceProc;
    end(context.recording.command_buffer);
    context.recording.active_render_pass = null;
    for (target.colors) |maybe_view| {
        const view = maybe_view orelse continue;
        view.texture.setSubresourceContentInitialized(context.guard, true, view.range);
    }
    if (target.depth_stencil) |view| view.texture.setSubresourceContentInitialized(context.guard, true, view.range);
}

pub fn checkRange(range: kernels.BufferRange) Error!void {
    if (range.offset > range.owner.native.size or range.size > range.owner.native.size - range.offset)
        return error.KernelRangeOverflow;
}

pub fn copyBuffer(context: kernels.Context, source: kernels.BufferRange, destination: kernels.BufferRange) Error!void {
    try kernels.validateContext(context);
    if (source.size != destination.size or source.offset % 4 != 0 or
        destination.offset % 4 != 0 or source.size % 4 != 0 or source.owner == destination.owner)
        return error.InvalidBlitRegion;
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    if (source.offset > source.owner.native.allocated_size or
        source.size > source.owner.native.allocated_size - source.offset or
        destination.offset > destination.owner.native.allocated_size or
        destination.size > destination.owner.native.allocated_size - destination.offset)
        return error.KernelRangeOverflow;
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &source.owner.header);
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, &destination.owner.header);
    const procs = context.queue.context.dispatch.device orelse return error.MissingDeviceProc;
    const copy = procs.cmd_copy_buffer orelse return error.MissingDeviceProc;
    errdefer context.queue.poisonRecording();
    if (source.owner.native.needsInitialization())
        try source.owner.native.ensureDataInitializedAsDestination(recording(context), 0, 0);
    try destination.owner.native.ensureDataInitializedAsDestination(recording(context), destination.offset, destination.size);
    try source.owner.native.transitionUsageNow(recording(context), (api.BufferUsage{ .copy_src = true }).toFlags(), .none);
    try destination.owner.native.transitionUsageNow(recording(context), (api.BufferUsage{ .copy_dst = true }).toFlags(), .none);
    const region: vulkan.VkBufferCopy = .{
        .srcOffset = source.offset,
        .dstOffset = destination.offset,
        .size = source.size,
    };
    copy(context.recording.command_buffer, source.owner.native.getHandle(), destination.owner.native.getHandle(), 1, &region);
    context.recording.needs_submit = true;
}

pub fn stageInput(context: kernels.Context, input: kernels.BufferRange) Error!kernels.BufferRange {
    try kernels.validateContext(context);
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try checkRange(input);
    if (input.size == 0) return error.InvalidBlitRegion;
    if (!input.owner.native.usage.copy_src and
        input.owner.native.internal_usage & buffer.internal_copy_src_buffer == 0)
        return error.BufferUsageMissingCopySrc;
    const aligned_offset = input.offset & ~@as(u64, 3);
    const delta = input.offset - aligned_offset;
    const byte_count = try align4(try add(input.size, delta));
    const scratch = try kernels.scratchBuffer(context, .{
        .size = byte_count,
        .native_usage = buffer.read_only_storage_buffer |
            (api.BufferUsage{ .copy_src = true, .copy_dst = true }).toFlags(),
    });
    try copyBuffer(context, .{ .owner = input.owner, .offset = aligned_offset, .size = byte_count }, scratch);
    return .{ .owner = scratch.owner, .offset = delta, .size = input.size };
}

pub fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.KernelRangeOverflow;
}

pub fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.KernelRangeOverflow;
}

pub fn align4(value: u64) Error!u64 {
    return (try add(value, 3)) & ~@as(u64, 3);
}

pub fn putWord(bytes: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
}
