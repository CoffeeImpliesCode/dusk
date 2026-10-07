const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/api.zig");
const commands = @import("../command/commands.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const queue = @import("queue.zig");
const recording_context = @import("recording_context.zig");
const dispatch = @import("../vk/dispatch.zig");
const blit = @import("../command/blit_texture_to_buffer.zig");
const core = @import("../core/root.zig");
const format_mod = @import("format.zig");
const kernels = @import("native_kernels.zig");
const native_blit = @import("native_blit.zig");
const native_resources = @import("native_resources.zig");
const attachments = @import("../command/attachment_state.zig");
const attachment_store = @import("native_attachment_store.zig");
const passes = @import("render_pass_cache.zig");
const frames = @import("framebuffer_cache.zig");
const blit_common = @import("native_blit_common.zig");
const browser_copy = @import("../command/browser_copy.zig");
const external_texture = @import("external_texture.zig");

test "index replay maps both widths and rejects undefined" {
    try std.testing.expectEqual(
        @as(vulkan.VkIndexType, vulkan.VK_INDEX_TYPE_UINT16),
        try vulkanIndexType(.uint16),
    );
    try std.testing.expectEqual(
        @as(vulkan.VkIndexType, vulkan.VK_INDEX_TYPE_UINT32),
        try vulkanIndexType(.uint32),
    );
    try std.testing.expectError(error.InvalidCopy, vulkanIndexType(.undefined_));
}

test "array copy regions preserve row pitch and advance layer offsets" {
    const copy: commands.TextureCopy = .{
        .dimension = ._2d,
        .aspect = .all,
        .origin = .{ .x = 0, .y = 0, .z = 3 },
        .extent = .{ .width = 8, .height = 8, .depth_or_array_layers = 8 },
    };
    const regions = try computePerArrayLayerBufferImageCopyRegions(
        std.testing.allocator,
        .{ .offset = 16, .blocks_per_row = 64, .rows_per_image = 8 },
        copy,
        .{ .width = 8, .height = 8, .depth_or_array_layers = 2 },
        4,
        vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
    );
    defer std.testing.allocator.free(regions);
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    try std.testing.expectEqual(@as(u64, 16), regions[0].bufferOffset);
    try std.testing.expectEqual(@as(u64, 2064), regions[1].bufferOffset);
    try std.testing.expectEqual(@as(u32, 4), regions[1].imageSubresource.baseArrayLayer);
    try std.testing.expectEqual(@as(u32, 1), regions[1].imageSubresource.layerCount);
}

test "compressed edge copies detect incompatible native extents" {
    const source: commands.TextureCopy = .{
        .dimension = ._2d,
        .block_width = 4,
        .block_height = 4,
        .extent = .{ .width = 16, .height = 16, .depth_or_array_layers = 1 },
    };
    var destination = source;
    destination.extent.width = 15;
    destination.extent.height = 15;
    const size: commands.Extent3D = .{ .width = 16, .height = 16, .depth_or_array_layers = 1 };
    try std.testing.expect(!try hasSameTextureCopyExtent(source, destination, size));
    try std.testing.expectError(
        error.InvalidCopy,
        computeImageCopyRegion(source, destination, size, vulkan.VK_IMAGE_ASPECT_COLOR_BIT),
    );
}

test "image copy separates array layers from volume depth" {
    const source: commands.TextureCopy = .{
        .dimension = ._2d,
        .origin = .{ .x = 1, .y = 2, .z = 3 },
        .extent = .{ .width = 8, .height = 8, .depth_or_array_layers = 8 },
    };
    var destination = source;
    destination.dimension = ._3d;
    const region = try computeImageCopyRegion(
        source,
        destination,
        .{ .width = 4, .height = 4, .depth_or_array_layers = 2 },
        vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
    );
    try std.testing.expectEqual(@as(u32, 2), region.srcSubresource.layerCount);
    try std.testing.expectEqual(@as(u32, 1), region.dstSubresource.layerCount);
    try std.testing.expectEqual(@as(i32, 3), region.dstOffset.z);
    try std.testing.expectEqual(@as(u32, 2), region.extent.depth);
}

test "empty copy and write handlers do not inspect resources or dispatch" {
    const context: Context = undefined;
    try copyBufferToBuffer(context, .{});
    try copyBufferToTexture(context, .{});
    try copyTextureToBuffer(context, .{});
    try copyTextureToTexture(context, .{});
    try clearBuffer(context, .{});
    try writeBuffer(context, .{}, &.{});
    try recordCopyImageWithTemporaryBuffer(context, .{});
    try copyTextureForBrowser(context, .{
        .source = null,
        .destination = null,
        .source_origin = .{},
        .destination_origin = .{},
        .copy_size = .{ .width = 0, .height = 1 },
        .options = .{},
    });
    try copyExternalTextureForBrowser(context, .{
        .source = null,
        .destination = null,
        .natural_size = .{ .width = 1, .height = 1 },
        .source_origin = .{},
        .destination_origin = .{},
        .copy_size = .{ .width = 1, .height = 0 },
        .options = .{},
    });
}

test "array region allocation reports every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testArrayAllocation, .{});
}

fn testArrayAllocation(allocator: std.mem.Allocator) !void {
    const regions = try computePerArrayLayerBufferImageCopyRegions(
        allocator,
        .{ .blocks_per_row = 2, .rows_per_image = 2 },
        .{
            .dimension = ._2d,
            .extent = .{ .width = 2, .height = 2, .depth_or_array_layers = 2 },
        },
        .{ .width = 2, .height = 2, .depth_or_array_layers = 2 },
        4,
        vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
    );
    defer allocator.free(regions);
    try std.testing.expectEqual(@as(usize, 2), regions.len);
}

test "copy region rejects overflow before allocation" {
    try std.testing.expectError(
        error.CopySizeOverflow,
        computePerArrayLayerBufferImageCopyRegions(
            std.testing.allocator,
            .{ .blocks_per_row = std.math.maxInt(u64), .rows_per_image = 2 },
            .{ .dimension = ._2d },
            .{ .width = 1, .height = 1, .depth_or_array_layers = 2 },
            4,
            1,
        ),
    );
}

test "volume buffer image region keeps z offset and texel block pitch" {
    const region = try computeBufferImageCopyRegion(
        .{ .offset = 32, .blocks_per_row = 4, .rows_per_image = 3 },
        .{
            .dimension = ._3d,
            .block_width = 4,
            .block_height = 4,
            .origin = .{ .x = 0, .y = 0, .z = 2 },
            .extent = .{ .width = 15, .height = 11, .depth_or_array_layers = 8 },
        },
        .{ .width = 16, .height = 12, .depth_or_array_layers = 3 },
        1,
    );
    try std.testing.expectEqual(@as(u32, 16), region.bufferRowLength);
    try std.testing.expectEqual(@as(u32, 12), region.bufferImageHeight);
    try std.testing.expectEqual(@as(u32, 15), region.imageExtent.width);
    try std.testing.expectEqual(@as(u32, 3), region.imageExtent.depth);
    try std.testing.expectEqual(@as(i32, 2), region.imageOffset.z);
    try std.testing.expectEqual(@as(u32, 1), region.imageSubresource.layerCount);
}

test "write payload size is checked before queue access" {
    try std.testing.expectError(
        error.InvalidCopy,
        writeBuffer(undefined, .{ .size = 4 }, &.{ 1, 2 }),
    );
}

test "texture replay rejects failed and retired payloads without consuming aliases" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("texture references leaked");
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    const target = try testTexture(&arena, &guard, &table[format_mod.computeFormatIndex(.rgba8_unorm).?]);
    defer target.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    try std.testing.expectError(error.TextureNativeDestroyed, getTexture(&guard, target));
    target.header.setInitializedError(&guard, error.TextureUsageMissingCopyDst);
    target.header.attach(&guard, std.testing.io);
    const context: Context = .{
        .allocator = std.testing.allocator,
        .guard = &guard,
        .queue = undefined,
        .recording = undefined,
        .kernels = undefined,
        .render_pass_cache = undefined,
        .framebuffer_cache = undefined,
    };
    const command: commands.CopyTextureToTextureCmd = .{
        .source = .{ .texture = target },
        .destination = .{ .texture = target },
        .copy_size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
    };
    var device_procs = std.mem.zeroes(dispatch.DeviceProcs);
    var linear = testBuffer(&device_procs, .{ .copy_src = true, .copy_dst = true });
    try std.testing.expect(target.header.isAlive(&guard));
    try std.testing.expectError(error.TextureNativeDestroyed, copyBufferToTexture(context, .{
        .source = .{ .buffer = &linear },
        .destination = command.destination,
        .copy_size = command.copy_size,
    }));
    try std.testing.expectError(error.TextureNativeDestroyed, copyTextureToBuffer(context, .{
        .source = command.source,
        .destination = .{ .buffer = &linear },
        .copy_size = command.copy_size,
    }));
    try std.testing.expectError(error.TextureNativeDestroyed, recordCopyImageWithTemporaryBuffer(context, command));
    try std.testing.expectError(error.TextureNativeDestroyed, copyTextureToTexture(context, command));
    try std.testing.expectEqual(@as(u32, 1), target.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), target.header.user_reference_count);
    target.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(error.TextureNativeDestroyed, copyTextureToTexture(context, command));
    try std.testing.expectEqual(@as(u64, 1), arena.objects.total_reference_count);
}

test "texture replay rejects a foreign owner before texture payload access" {
    var owner_mutex: std.Io.Mutex = .init;
    var owner = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &owner_mutex });
    var owner_guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.objectList());
    defer owner_guard.unlock(std.testing.io);
    defer owner.deinit(std.testing.allocator, &owner_guard) catch @panic("texture references leaked");
    var foreign_mutex: std.Io.Mutex = .init;
    var foreign = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &foreign_mutex });
    var foreign_guard = core.ObjectGuard.lockUncancelable(std.testing.io, foreign.objectList());
    defer foreign_guard.unlock(std.testing.io);
    defer foreign.deinit(std.testing.allocator, &foreign_guard) catch unreachable;
    var table: format_mod.FormatTable = undefined;
    format_mod.buildFormatTable(.{}, &table);
    const target = try testTexture(&owner, &owner_guard, &table[format_mod.computeFormatIndex(.rgba8_unorm).?]);
    defer target.header.releaseUserLocked(&owner_guard, std.testing.io) catch unreachable;
    target.header.setInitializedNoError(&owner_guard);
    try std.testing.expectError(error.TextureNativeDestroyed, getTexture(&owner_guard, target));
    target.header.attach(&owner_guard, std.testing.io);
    try std.testing.expectError(error.InvalidCopy, getTexture(&foreign_guard, target));
    try std.testing.expectEqual(target, try getTexture(&owner_guard, target));
    try std.testing.expectEqual(@as(u32, 1), target.header.reference_count);
}

fn testTexture(
    arena: *core.ObjectArena,
    guard: *const core.ObjectGuard,
    format_info: *const format_mod.Format,
) core.CreateError!*texture.Texture {
    const target = try arena.create(std.testing.allocator, guard, texture.Texture, .{
        .kind = .texture,
        .state = .initializing,
        .initial_reference = .user,
    });
    target.* = .{
        .header = target.header,
        .format_info = format_info,
        .dimension = ._2d,
        .binding_view_dimension = ._2d,
        .base_size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
        .mip_level_count = 1,
        .sample_count = 1,
        .usage = .{ .copy_src = true, .copy_dst = true },
        .internal_usage = .{ .copy_src = true, .copy_dst = true },
        .view_formats = &.{},
        .compatibility_mode = false,
        .bytes = &.{},
        .subresource_offsets = &.{},
        .initialized = &.{},
        .native = null,
    };
    return target;
}

test "buffer replay initializes both allocations before partial copy" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch unreachable;
    var capture: CopyCapture = .{};
    var device_procs = std.mem.zeroes(dispatch.DeviceProcs);
    device_procs.cmd_fill_buffer = CopyCapture.fill;
    device_procs.cmd_copy_buffer = CopyCapture.copy;
    device_procs.cmd_pipeline_barrier = CopyCapture.barrier;
    var source = testBuffer(&device_procs, .{ .copy_src = true });
    var destination = testBuffer(&device_procs, .{ .copy_dst = true });
    var native_queue: queue.Queue = undefined;
    native_queue.context.dispatch = .{ .global = null, .instance = null, .device = &device_procs };
    native_queue.recording_index = 0;
    native_queue.contexts[0].command_buffer = @ptrCast(&capture);
    native_queue.timeline = .{};
    var context = recording_context.CommandRecordingContext.init(std.testing.allocator);
    defer context.deinit();
    context.command_buffer = @ptrCast(&capture);
    try copyBufferToBuffer(
        .{
            .allocator = std.testing.allocator,
            .guard = &guard,
            .queue = &native_queue,
            .recording = &context,
            .kernels = undefined,
            .render_pass_cache = undefined,
            .framebuffer_cache = undefined,
        },
        .{
            .source = &source,
            .source_offset = 4,
            .destination = &destination,
            .destination_offset = 8,
            .size = 4,
        },
    );
    try std.testing.expectEqual(@as(u32, 2), capture.fill_count);
    try std.testing.expectEqual(@as(u32, 1), capture.copy_count);
    try std.testing.expectEqual(@as(u64, 4), capture.region.srcOffset);
    try std.testing.expectEqual(@as(u64, 8), capture.region.dstOffset);
    try std.testing.expectEqual(@as(u64, 4), capture.region.size);
    try std.testing.expect(source.is_data_initialized);
    try std.testing.expect(destination.is_data_initialized);
    try std.testing.expectEqual(@as(u64, 1), destination.last_usage_serial);
    try clearBuffer(
        .{
            .allocator = std.testing.allocator,
            .guard = &guard,
            .queue = &native_queue,
            .recording = &context,
            .kernels = undefined,
            .render_pass_cache = undefined,
            .framebuffer_cache = undefined,
        },
        .{ .buffer = &destination, .offset = 4, .size = 4 },
    );
    try std.testing.expectEqual(@as(u32, 3), capture.fill_count);
}

test "buffer replay rejects missing barrier dispatch before initialization" {
    var device_procs = std.mem.zeroes(dispatch.DeviceProcs);
    var source = testBuffer(&device_procs, .{ .copy_src = true });
    var destination = testBuffer(&device_procs, .{ .copy_dst = true });
    try std.testing.expectError(
        error.MissingDeviceProc,
        copyBufferToBuffer(
            undefined,
            .{ .source = &source, .destination = &destination, .size = 4 },
        ),
    );
    try std.testing.expect(!source.is_data_initialized);
    try std.testing.expect(!destination.is_data_initialized);
}

fn testBuffer(device_procs: *dispatch.DeviceProcs, usage: api.BufferUsage) buffer.Buffer {
    // SAFETY: These copy-only tests read size, dispatch, handle, initialization, and usage tracking.
    // The assignments below initialize those fields, including allocated_size and the device handle.
    // Copy-only usage skips eager mapping. No mapping, allocation, or destruction uses this fixture.
    // Remaining owner fields stay undefined: this wrapper owns no native buffer or memory.
    var target: buffer.Buffer = undefined;
    target.device.dispatch = .{ .global = null, .instance = null, .device = device_procs };
    target.device.vk_device = null;
    target.handle = null;
    target.size = 16;
    target.allocated_size = 16;
    target.usage = usage;
    target.state = .unmapped;
    target.internal_usage = usage.toFlags();
    target.is_data_initialized = false;
    target.last_usage_serial = 0;
    target.last_write_usage = 0;
    target.last_write_shader_stage = .none;
    target.read_usage = 0;
    target.read_shader_stages = .none;
    return target;
}

const CopyCapture = struct {
    fill_count: u32 = 0,
    copy_count: u32 = 0,
    region: vulkan.VkBufferCopy = .{},

    fn fill(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkBuffer,
        _: u64,
        _: u64,
        _: u32,
    ) callconv(.c) void {
        const self: *CopyCapture = @ptrCast(@alignCast(command_buffer));
        self.fill_count += 1;
    }

    fn copy(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkBuffer,
        _: vulkan.VkBuffer,
        count: u32,
        regions: [*c]const vulkan.VkBufferCopy,
    ) callconv(.c) void {
        std.debug.assert(count == 1);
        const self: *CopyCapture = @ptrCast(@alignCast(command_buffer));
        self.copy_count += 1;
        self.region = regions[0];
    }

    fn barrier(
        _: vulkan.VkCommandBuffer,
        _: vulkan.VkPipelineStageFlags,
        _: vulkan.VkPipelineStageFlags,
        _: vulkan.VkDependencyFlags,
        _: u32,
        _: [*c]const vulkan.VkMemoryBarrier,
        _: u32,
        _: [*c]const vulkan.VkBufferMemoryBarrier,
        _: u32,
        _: [*c]const vulkan.VkImageMemoryBarrier,
    ) callconv(.c) void {}
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    /// The caller holds the original queue gate and this canonical object guard.
    /// Helpers append actual derived roots to the borrowed utility PendingUses.
    guard: *const core.ObjectGuard,
    queue: *queue.Queue,
    recording: *recording_context.CommandRecordingContext,
    /// Borrows the same utility cache, pending roots, guard, and recording as replay.
    kernels: kernels.Context,
    render_pass_cache: *passes.RenderPassCache,
    framebuffer_cache: *frames.FramebufferCache,
};

pub const Error = buffer.Error || texture.NativeError || texture.CreateError ||
    blit.Error || native_blit.Error || native_resources.Error || attachment_store.Error ||
    browser_copy.Error || external_texture.Error || error{
    InvalidCopy,
    CopySizeOverflow,
};

pub fn vulkanIndexType(format: commands.IndexFormat) Error!vulkan.VkIndexType {
    return switch (format) {
        .uint16 => vulkan.VK_INDEX_TYPE_UINT16,
        .uint32 => vulkan.VK_INDEX_TYPE_UINT32,
        .undefined_ => error.InvalidCopy,
    };
}

fn empty(size: commands.Extent3D) bool {
    return size.width == 0 or size.height == 0 or size.depth_or_array_layers == 0;
}

fn nativeExtent(copy: commands.TextureCopy, size: commands.Extent3D) Error!vulkan.VkExtent3D {
    if (copy.origin.x > copy.extent.width or copy.origin.y > copy.extent.height) {
        return error.InvalidCopy;
    }
    return .{
        .width = @min(size.width, copy.extent.width - copy.origin.x),
        .height = @min(size.height, copy.extent.height - copy.origin.y),
        .depth = if (copy.dimension == ._3d) size.depth_or_array_layers else 1,
    };
}

pub fn hasSameTextureCopyExtent(
    source: commands.TextureCopy,
    destination: commands.TextureCopy,
    size: commands.Extent3D,
) Error!bool {
    const source_extent = try nativeExtent(source, size);
    const destination_extent = try nativeExtent(destination, size);
    // Array layers and volume slices share the logical depth in Dawn's extent.
    return source_extent.width == destination_extent.width and
        source_extent.height == destination_extent.height;
}

fn imageLayers(
    copy: commands.TextureCopy,
    size: commands.Extent3D,
    aspect_mask: vulkan.VkImageAspectFlags,
) Error!vulkan.VkImageSubresourceLayers {
    return .{
        .aspectMask = aspect_mask,
        .mipLevel = copy.mip_level,
        .baseArrayLayer = switch (copy.dimension) {
            ._1d, ._3d => 0,
            ._2d => copy.origin.z,
            .undefined_ => return error.InvalidCopy,
        },
        .layerCount = if (copy.dimension == ._2d) size.depth_or_array_layers else 1,
    };
}

fn imageOffset(copy: commands.TextureCopy) Error!vulkan.VkOffset3D {
    if (copy.origin.x > std.math.maxInt(i32) or copy.origin.y > std.math.maxInt(i32) or
        copy.origin.z > std.math.maxInt(i32)) return error.InvalidCopy;
    return .{
        .x = @intCast(copy.origin.x),
        .y = @intCast(copy.origin.y),
        .z = if (copy.dimension == ._3d) @intCast(copy.origin.z) else 0,
    };
}

pub fn computeImageCopyRegion(
    source: commands.TextureCopy,
    destination: commands.TextureCopy,
    size: commands.Extent3D,
    aspect_mask: vulkan.VkImageAspectFlags,
) Error!vulkan.VkImageCopy {
    if (!try hasSameTextureCopyExtent(source, destination, size)) return error.InvalidCopy;
    var extent = try nativeExtent(destination, size);
    extent.depth = if (source.dimension == ._3d or destination.dimension == ._3d)
        size.depth_or_array_layers
    else
        1;
    return .{
        .srcSubresource = try imageLayers(source, size, aspect_mask),
        .srcOffset = try imageOffset(source),
        .dstSubresource = try imageLayers(destination, size, aspect_mask),
        .dstOffset = try imageOffset(destination),
        .extent = extent,
    };
}

pub fn computeBufferImageCopyRegion(
    linear: commands.BufferCopy,
    copy: commands.TextureCopy,
    size: commands.Extent3D,
    aspect_mask: vulkan.VkImageAspectFlags,
) Error!vulkan.VkBufferImageCopy {
    const row_length = try mul(linear.blocks_per_row, copy.block_width);
    const image_height = try mul(linear.rows_per_image, copy.block_height);
    if (row_length > std.math.maxInt(u32) or image_height > std.math.maxInt(u32)) {
        return error.CopySizeOverflow;
    }
    return .{
        .bufferOffset = linear.offset,
        .bufferRowLength = @intCast(row_length),
        .bufferImageHeight = @intCast(image_height),
        .imageSubresource = try imageLayers(copy, size, aspect_mask),
        .imageOffset = try imageOffset(copy),
        .imageExtent = try nativeExtent(copy, size),
    };
}

pub fn computePerArrayLayerBufferImageCopyRegions(
    allocator: std.mem.Allocator,
    linear: commands.BufferCopy,
    copy: commands.TextureCopy,
    size: commands.Extent3D,
    block_byte_size: u32,
    aspect_mask: vulkan.VkImageAspectFlags,
) Error![]vulkan.VkBufferImageCopy {
    if (copy.dimension != ._2d) return error.InvalidCopy;
    const stride = try mul(try mul(linear.blocks_per_row, linear.rows_per_image), block_byte_size);
    const regions = try allocator.alloc(vulkan.VkBufferImageCopy, size.depth_or_array_layers);
    errdefer allocator.free(regions);
    var single_size = size;
    single_size.depth_or_array_layers = 1;
    for (regions, 0..) |*region, layer| {
        var single_copy = copy;
        single_copy.origin.z = std.math.add(u32, copy.origin.z, @intCast(layer)) catch
            return error.CopySizeOverflow;
        var single_linear = linear;
        single_linear.offset = std.math.add(u64, linear.offset, try mul(layer, stride)) catch
            return error.CopySizeOverflow;
        region.* = try computeBufferImageCopyRegion(
            single_linear,
            single_copy,
            single_size,
            aspect_mask,
        );
    }
    return regions;
}

fn mul(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch error.CopySizeOverflow;
}

fn getBuffer(reference: commands.Ref) Error!*buffer.Buffer {
    return @ptrCast(@alignCast(reference orelse return error.InvalidCopy));
}

fn getTexture(guard: *const core.ObjectGuard, reference: commands.Ref) Error!*texture.Texture {
    const header: *core.Object = @ptrCast(@alignCast(reference orelse return error.InvalidCopy));
    if (header.kind != .texture or header.tracking != guard.objects) return error.InvalidCopy;
    guard.assertOwns(header.tracking);
    if (!header.node.linked or header.reference_count == 0 or header.state != .alive)
        return error.TextureNativeDestroyed;
    const target: *texture.Texture = @ptrCast(@alignCast(header));
    if (target.native_y_cb_cr != null) return error.TextureNativeYCbCrCopyUnsupported;
    return target;
}

fn recording(context: Context) buffer.Recording {
    std.debug.assert(context.recording.command_buffer == context.queue.commandBuffer());
    return .{
        .command_buffer = context.recording.command_buffer,
        .pending_serial = context.queue.timeline.nextSerial(),
    };
}

fn procs(context: Context) Error!*const dispatch.DeviceProcs {
    return context.queue.context.dispatch.device orelse error.MissingDeviceProc;
}

fn checkBufferRange(target: *buffer.Buffer, offset: u64, size: u64) Error!void {
    if (offset > target.size or size > target.size - offset) return error.InvalidCopy;
    // Buffer's barrier emitter assumes loader-complete dispatch, including for its lazy clear.
    const device_procs = target.device.dispatch.device orelse return error.MissingDeviceProc;
    if (device_procs.cmd_pipeline_barrier == null) return error.MissingDeviceProc;
}

fn initializeBuffer(context: Context, target: *buffer.Buffer) Error!void {
    // A zero-byte destination cannot replace any contents; this requests the full lazy clear.
    try target.ensureDataInitializedAsDestination(recording(context), 0, 0);
}

fn transitionBuffer(context: Context, target: *buffer.Buffer, usage: api.BufferUsage) Error!void {
    if (target.internal_usage & buffer.mappable_buffer_usages != 0) {
        if (try context.recording.checkBufferNeedsEagerTransition(
            target,
            api.BufferUsage.fromFlags(target.internal_usage & buffer.mappable_buffer_usages),
            usage,
        )) {
            std.debug.assert(context.recording.isEagerTransitionQueued(target));
        }
    }
    try target.transitionUsageNow(recording(context), usage.toFlags(), .none);
}

fn aspects(guard: *const core.ObjectGuard, target: *texture.Texture, copy: commands.TextureCopy) Error!texture.AspectMask {
    const selected = texture.selectFormatAspects(
        target.getFormatInfo(guard),
        @enumFromInt(@intFromEnum(copy.aspect)),
    );
    if (selected.toFlags() == 0) return error.InvalidCopy;
    return selected;
}

fn vulkanAspects(selected: texture.AspectMask) vulkan.VkImageAspectFlags {
    return (if (selected.color == 1) @as(u32, vulkan.VK_IMAGE_ASPECT_COLOR_BIT) else 0) |
        (if (selected.depth == 1) @as(u32, vulkan.VK_IMAGE_ASPECT_DEPTH_BIT) else 0) |
        (if (selected.stencil == 1) @as(u32, vulkan.VK_IMAGE_ASPECT_STENCIL_BIT) else 0);
}

fn rangeFor(
    copy: commands.TextureCopy,
    size: commands.Extent3D,
    selected: texture.AspectMask,
) texture.SubresourceRange {
    return .{
        .aspects = selected,
        .base_mip_level = copy.mip_level,
        .level_count = 1,
        .base_array_layer = if (copy.dimension == ._2d) copy.origin.z else 0,
        .layer_count = if (copy.dimension == ._2d) size.depth_or_array_layers else 1,
    };
}

fn validateTextureCopy(
    guard: *const core.ObjectGuard,
    target: *texture.Texture,
    copy: commands.TextureCopy,
    size: commands.Extent3D,
) Error!void {
    const format_info = target.getFormatInfo(guard);
    if (copy.mip_level >= target.getNumMipLevels(guard) or target.getSampleCount(guard) != 1 or
        @intFromEnum(copy.dimension) != @intFromEnum(target.getDimension(guard)) or
        copy.format != @intFromEnum(target.getFormat(guard)) or
        copy.block_width != format_info.aspect_info[0].block.width or
        copy.block_height != format_info.aspect_info[0].block.height)
    {
        return error.InvalidCopy;
    }
    const level = target.getMipLevelSubresourceVirtualSize(guard, copy.mip_level);
    if (copy.extent.width != level.width or copy.extent.height != level.height or
        copy.extent.depth_or_array_layers != level.depth_or_array_layers) return error.InvalidCopy;
    const physical = target.getMipLevelSubresourcePhysicalSize(guard, copy.mip_level);
    if (copy.origin.x % copy.block_width != 0 or copy.origin.y % copy.block_height != 0 or
        @as(u64, copy.origin.x) + size.width > physical.width or
        @as(u64, copy.origin.y) + size.height > physical.height or
        @as(u64, copy.origin.z) + size.depth_or_array_layers > physical.depth_or_array_layers)
    {
        return error.InvalidCopy;
    }
}

fn initializeTexture(
    context: Context,
    target: *texture.Texture,
    copy: commands.TextureCopy,
    size: commands.Extent3D,
    destination: bool,
) Error!void {
    try validateTextureCopy(context.guard, target, copy, size);
    const range = rangeFor(copy, size, try aspects(context.guard, target, copy));
    if (destination and target.coversFullSubresource(context.guard, copy.mip_level, .{
        .width = size.width,
        .height = size.height,
        .depth_or_array_layers = size.depth_or_array_layers,
    })) {
        target.setSubresourceContentInitialized(context.guard, true, range);
    } else {
        try target.ensureSubresourceContentInitialized(context.guard, context.queue, recording(context), range);
    }
}

fn transitionTexture(
    context: Context,
    target: *texture.Texture,
    copy: commands.TextureCopy,
    size: commands.Extent3D,
    destination: bool,
) Error!void {
    try target.transition(
        context.guard,
        recording(context),
        rangeFor(copy, size, try aspects(context.guard, target, copy)),
        if (destination) .{ .copy_dst = true } else .{ .copy_src = true },
        .none,
    );
}

fn blockBytes(guard: *const core.ObjectGuard, target: *texture.Texture, copy: commands.TextureCopy) Error!u32 {
    const info = target.getFormatInfo(guard).getAspectInfo(@enumFromInt(@intFromEnum(copy.aspect))) catch
        return error.InvalidCopy;
    if (info.block.byte_size == 0) return error.InvalidCopy;
    return info.block.byte_size;
}

fn requiredBytes(
    guard: *const core.ObjectGuard,
    target: *texture.Texture,
    linear: commands.BufferCopy,
    copy: commands.TextureCopy,
    size: commands.Extent3D,
) Error!u64 {
    if (copy.block_width == 0 or copy.block_height == 0 or
        linear.blocks_per_row > std.math.maxInt(u32) or
        linear.rows_per_image > std.math.maxInt(u32)) return error.InvalidCopy;
    const width = std.math.divCeil(u32, size.width, copy.block_width) catch
        return error.InvalidCopy;
    const height = std.math.divCeil(u32, size.height, copy.block_height) catch
        return error.InvalidCopy;
    if (linear.blocks_per_row < width or linear.rows_per_image < height) return error.InvalidCopy;
    return blit.computeRequiredBytesInCopy(
        try blockBytes(guard, target, copy),
        .{
            .width = width,
            .height = height,
            .depth_or_array_layers = size.depth_or_array_layers,
        },
        @intCast(linear.blocks_per_row),
        @intCast(linear.rows_per_image),
    );
}

// Depth/stencil transfer offsets require four-byte alignment even for one-byte stencil.
// Color transfers on this graphics queue require only their actual texel block alignment.
fn needsBufferImageBlit(selected: texture.AspectMask, offset: u64) bool {
    return (selected.depth != 0 or selected.stencil != 0) and offset % 4 != 0;
}

test "buffer image selection preserves exact color transfers and handles narrow aspects" {
    try std.testing.expect(!needsBufferImageBlit(.{ .color = 1 }, 1));
    try std.testing.expect(!needsBufferImageBlit(.{ .depth = 1 }, 4));
    try std.testing.expect(needsBufferImageBlit(.{ .depth = 1 }, 2));
    try std.testing.expect(needsBufferImageBlit(.{ .stencil = 1 }, 1));
}

fn utilityContext(context: Context) Error!kernels.Context {
    const utility = context.kernels;
    if (utility.guard != context.guard or utility.queue != context.queue or
        utility.recording != context.recording) return error.InvalidCopy;
    try kernels.validateContext(utility);
    if (utility.recording.active_render_pass != null)
        return error.KernelRequiresOutsideRenderPass;
    try utility.device.arena.checkAllocator(context.guard, context.allocator);
    return utility;
}

fn createCopyView(
    context: Context,
    target: *texture.Texture,
    copy: commands.TextureCopy,
    layer_count: u32,
    aspect: api.TextureAspect,
) Error!*texture.TextureView {
    const utility = try utilityContext(context);
    const handle = try texture.Texture.createView(
        context.allocator,
        utility.io,
        context.guard,
        utility.device,
        .{ .handle = @ptrCast(target) },
        .{
            .descriptor = .{
                .format = target.getFormat(context.guard),
                .dimension = switch (copy.dimension) {
                    ._1d => ._1d,
                    ._2d => if (layer_count == 1) ._2d else ._2d_array,
                    ._3d => ._3d,
                    .undefined_ => return error.InvalidCopy,
                },
                .aspect = aspect,
                .base_mip_level = copy.mip_level,
                .mip_level_count = 1,
                .base_array_layer = if (copy.dimension == ._2d) copy.origin.z else 0,
                .array_layer_count = if (copy.dimension == ._2d) layer_count else 1,
            },
            .format_info = target.getFormatInfo(context.guard),
            .compatibility_mode = target.compatibility_mode,
        },
    );
    const view = try texture.resolveTextureView(utility.device, context.guard, handle);
    errdefer view.header.releaseUserLocked(context.guard, utility.io) catch unreachable;
    try view.initializeNative(context.guard);
    return view;
}

fn copyTarget(
    context: Context,
    view: *texture.TextureView,
    depth_slice: u32,
) Error!native_blit.Target {
    const utility = try utilityContext(context);
    const shape: attachments.ViewShape = .{
        .format = @intFromEnum(view.format),
        .sample_count = view.texture.sample_count,
        .aspects = view.aspects.toFlags(),
    };
    const color = [_]attachments.ColorShape{.{
        .view = shape,
        .resolve_target = null,
        .expands_resolve = false,
    }};
    const value = try attachments.AttachmentState.fromRenderPass(.{
        .colors = if (view.aspects.color != 0) &color else &.{},
        .depth_stencil = if (view.aspects.color == 0) shape else null,
        .pls = null,
    }, .{
        .max_color_attachments = @min(8, utility.cache.limits.v1.max_color_attachments),
        .max_storage_attachments = 4,
        .max_pls_bytes = 16,
    });
    const store = utility.cache.resource_device.resource_store orelse
        return error.ResourceDeviceMismatch;
    const canonical = try attachment_store.create(
        context.allocator,
        utility.io,
        context.guard,
        &utility.device.arena,
        store,
        value,
    );
    defer canonical.header.releaseUserLocked(context.guard, utility.io) catch unreachable;
    try utility.pending_uses.retainDerivedRootLocked(
        context.guard,
        utility.device,
        &canonical.header,
    );
    const extent = view.texture.getMipLevelSingleSubresourceVirtualSize(
        context.guard,
        view.range.base_mip_level,
    );
    var result: native_blit.Target = .{
        .attachments = canonical,
        .render_pass_cache = context.render_pass_cache,
        .framebuffer_cache = context.framebuffer_cache,
        .width = extent.width,
        .height = extent.height,
        .depth_slice = depth_slice,
    };
    if (view.aspects.color != 0) result.colors[0] = view else result.depth_stencil = view;
    return result;
}

fn blitBufferToTexture(
    context: Context,
    command: commands.CopyBufferToTextureCmd,
    destination: *texture.Texture,
    byte_count: u64,
    selected: texture.AspectMask,
) Error!void {
    const utility = try utilityContext(context);
    const source = try native_resources.resolveBufferRefLocked(
        context.guard,
        utility.device,
        command.source.buffer,
    );
    const bytes_per_row = try mul(
        command.source.blocks_per_row,
        try blockBytes(context.guard, destination, command.destination),
    );
    if (bytes_per_row > std.math.maxInt(u32)) return error.CopySizeOverflow;
    const image_stride = try mul(bytes_per_row, command.source.rows_per_image);
    const aspect_info = destination.getFormatInfo(context.guard).getAspectInfo(
        @enumFromInt(@intFromEnum(command.destination.aspect)),
    ) catch return error.InvalidCopy;
    const input_format = format_mod.toApiFormat(aspect_info.format) catch return error.InvalidCopy;
    if (command.copy_size.depth_or_array_layers > (1 << 24))
        return error.BlitCommandLimitExceeded;
    errdefer context.queue.poisonRecording();
    for (0..command.copy_size.depth_or_array_layers) |layer| {
        var single_copy = command.destination;
        if (single_copy.dimension == ._2d) {
            single_copy.origin.z = std.math.add(u32, single_copy.origin.z, @intCast(layer)) catch
                return error.CopySizeOverflow;
        }
        const view = try createCopyView(context, destination, single_copy, 1, .all);
        defer view.header.releaseUserLocked(context.guard, utility.io) catch unreachable;
        const target = try copyTarget(context, view, if (single_copy.dimension == ._3d)
            single_copy.origin.z + @as(u32, @intCast(layer))
        else
            0);
        const options: native_blit.BufferCopyOptions = .{
            .source = .{ .owner = source, .offset = command.source.offset, .size = byte_count },
            .target = target,
            .rectangle = .{
                .x = single_copy.origin.x,
                .y = single_copy.origin.y,
                .width = command.copy_size.width,
                .height = command.copy_size.height,
            },
            .layout = .{
                .offset_bytes = try mul(layer, image_stride),
                .bytes_per_row = @intCast(bytes_per_row),
                .rows_per_image = @intCast(command.source.rows_per_image),
            },
            .format = input_format,
        };
        if (selected.stencil != 0) {
            try native_blit.bufferToStencil(utility, options);
        } else if (selected.depth != 0) {
            try native_blit.bufferToDepth(utility, options);
        } else {
            try native_blit.bufferToColor(utility, options);
        }
    }
}

fn blitTextureToBuffer(
    context: Context,
    command: commands.CopyTextureToBufferCmd,
    source: *texture.Texture,
    byte_count: u64,
) Error!void {
    const utility = try utilityContext(context);
    const destination = try native_resources.resolveBufferRefLocked(
        context.guard,
        utility.device,
        command.destination.buffer,
    );
    const view = try createCopyView(
        context,
        source,
        command.source,
        command.copy_size.depth_or_array_layers,
        @enumFromInt(@intFromEnum(command.source.aspect)),
    );
    defer view.header.releaseUserLocked(context.guard, utility.io) catch unreachable;
    errdefer context.queue.poisonRecording();
    try native_blit.textureToBuffer(utility, .{
        .source = view,
        .destination = .{
            .owner = destination,
            .offset = command.destination.offset,
            .size = byte_count,
        },
        .origin = .{
            command.source.origin.x,
            command.source.origin.y,
            if (command.source.dimension == ._3d) command.source.origin.z else 0,
        },
        .extent = .{
            command.copy_size.width,
            command.copy_size.height,
            command.copy_size.depth_or_array_layers,
        },
        .bytes_per_row = try mul(
            command.destination.blocks_per_row,
            try blockBytes(context.guard, source, command.source),
        ),
        .rows_per_image = command.destination.rows_per_image,
    });
}

pub fn copyBufferToBuffer(context: Context, command: commands.CopyBufferToBufferCmd) Error!void {
    if (command.size == 0) return;
    const source = try getBuffer(command.source);
    const destination = try getBuffer(command.destination);
    try checkBufferRange(source, command.source_offset, command.size);
    try checkBufferRange(destination, command.destination_offset, command.size);
    if (source == destination or command.source_offset % 4 != 0 or
        command.destination_offset % 4 != 0 or command.size % 4 != 0) return error.InvalidCopy;
    if (!source.usage.copy_src or !destination.usage.copy_dst) return error.InvalidCopy;
    try source.validateCanUseOnQueueNow();
    defer source.finishUse();
    try destination.validateCanUseOnQueueNow();
    defer destination.finishUse();
    errdefer context.queue.poisonRecording();
    try initializeBuffer(context, source);
    try destination.ensureDataInitializedAsDestination(
        recording(context),
        command.destination_offset,
        command.size,
    );
    try transitionBuffer(context, source, .{ .copy_src = true });
    try transitionBuffer(context, destination, .{ .copy_dst = true });
    const region: vulkan.VkBufferCopy = .{
        .srcOffset = command.source_offset,
        .dstOffset = command.destination_offset,
        .size = command.size,
    };
    const copy = (try procs(context)).cmd_copy_buffer orelse return error.MissingDeviceProc;
    copy(
        context.recording.command_buffer,
        source.getHandle(),
        destination.getHandle(),
        1,
        &region,
    );
}

pub fn copyBufferToTexture(context: Context, command: commands.CopyBufferToTextureCmd) Error!void {
    if (empty(command.copy_size)) return;
    const source = try getBuffer(command.source.buffer);
    const destination = try getTexture(context.guard, command.destination.texture);
    if (!source.usage.copy_src or !destination.getUsage(context.guard).copy_dst) return error.InvalidCopy;
    const byte_count = try requiredBytes(
        context.guard,
        destination,
        command.source,
        command.destination,
        command.copy_size,
    );
    try checkBufferRange(source, command.source.offset, byte_count);
    try validateTextureCopy(context.guard, destination, command.destination, command.copy_size);
    if (command.source.offset % try blockBytes(context.guard, destination, command.destination) != 0)
        return error.InvalidCopy;
    const selected = try aspects(context.guard, destination, command.destination);
    if (needsBufferImageBlit(selected, command.source.offset)) {
        return blitBufferToTexture(context, command, destination, byte_count, selected);
    }
    const region = try computeBufferImageCopyRegion(
        command.source,
        command.destination,
        command.copy_size,
        vulkanAspects(try aspects(context.guard, destination, command.destination)),
    );
    try source.validateCanUseOnQueueNow();
    defer source.finishUse();
    errdefer context.queue.poisonRecording();
    try initializeBuffer(context, source);
    try initializeTexture(context, destination, command.destination, command.copy_size, true);
    try transitionBuffer(context, source, .{ .copy_src = true });
    try transitionTexture(context, destination, command.destination, command.copy_size, true);
    const copy = (try procs(context)).cmd_copy_buffer_to_image orelse
        return error.MissingDeviceProc;
    copy(
        context.recording.command_buffer,
        source.getHandle(),
        try destination.getHandle(context.guard),
        vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );
}

pub fn copyTextureToBuffer(context: Context, command: commands.CopyTextureToBufferCmd) Error!void {
    if (empty(command.copy_size)) return;
    const source = try getTexture(context.guard, command.source.texture);
    const destination = try getBuffer(command.destination.buffer);
    if (!source.getUsage(context.guard).copy_src or !destination.usage.copy_dst) return error.InvalidCopy;
    const byte_count = try requiredBytes(
        context.guard,
        source,
        command.destination,
        command.source,
        command.copy_size,
    );
    try checkBufferRange(destination, command.destination.offset, byte_count);
    try validateTextureCopy(context.guard, source, command.source, command.copy_size);
    if (command.destination.offset % try blockBytes(context.guard, source, command.source) != 0)
        return error.InvalidCopy;
    if (needsBufferImageBlit(
        try aspects(context.guard, source, command.source),
        command.destination.offset,
    )) return blitTextureToBuffer(context, command, source, byte_count);
    const region = try computeBufferImageCopyRegion(
        command.destination,
        command.source,
        command.copy_size,
        vulkanAspects(try aspects(context.guard, source, command.source)),
    );
    try destination.validateCanUseOnQueueNow();
    defer destination.finishUse();
    errdefer context.queue.poisonRecording();
    // Padded rows are not overwritten. Clear unless every byte is in tightly packed rows.
    const row_blocks = std.math.divCeil(
        u32,
        command.copy_size.width,
        command.source.block_width,
    ) catch return error.InvalidCopy;
    const image_rows = std.math.divCeil(
        u32,
        command.copy_size.height,
        command.source.block_height,
    ) catch return error.InvalidCopy;
    const packed_rows = command.destination.blocks_per_row == row_blocks;
    const packed_images = command.destination.rows_per_image == image_rows;
    if (packed_rows and packed_images) {
        try destination.ensureDataInitializedAsDestination(
            recording(context),
            command.destination.offset,
            byte_count,
        );
    } else {
        try initializeBuffer(context, destination);
    }
    try initializeTexture(context, source, command.source, command.copy_size, false);
    try transitionTexture(context, source, command.source, command.copy_size, false);
    try transitionBuffer(context, destination, .{ .copy_dst = true });
    const copy = (try procs(context)).cmd_copy_image_to_buffer orelse
        return error.MissingDeviceProc;
    copy(
        context.recording.command_buffer,
        try source.getHandle(context.guard),
        vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        destination.getHandle(),
        1,
        &region,
    );
}

pub fn recordCopyImageWithTemporaryBuffer(
    context: Context,
    command: commands.CopyTextureToTextureCmd,
) Error!void {
    if (empty(command.copy_size)) return;
    const source = try getTexture(context.guard, command.source.texture);
    const width = std.math.divCeil(u32, command.copy_size.width, command.source.block_width) catch
        return error.InvalidCopy;
    const height = std.math.divCeil(
        u32,
        command.copy_size.height,
        command.source.block_height,
    ) catch return error.InvalidCopy;
    const size = try mul(
        try mul(try mul(width, height), command.copy_size.depth_or_array_layers),
        try blockBytes(context.guard, source, command.source),
    );
    _ = try source.getHandle(context.guard);
    const native = source.native.?;
    const temporary = try context.queue.createTemporaryBuffer(
        context.queue.context.allocator,
        native.context,
        .{ .size = size, .usage = .{ .copy_src = true, .copy_dst = true } },
    );
    const linear: commands.BufferCopy = .{
        .buffer = temporary,
        .blocks_per_row = width,
        .rows_per_image = height,
    };
    errdefer context.queue.poisonRecording();
    try copyTextureToBuffer(context, .{
        .source = command.source,
        .destination = linear,
        .copy_size = command.copy_size,
    });
    try copyBufferToTexture(context, .{
        .source = linear,
        .destination = command.destination,
        .copy_size = command.copy_size,
    });
    std.debug.assert(temporary.last_usage_serial == recording(context).pending_serial);
}

pub fn copyTextureToTexture(
    context: Context,
    command: commands.CopyTextureToTextureCmd,
) Error!void {
    if (empty(command.copy_size)) return;
    const source = try getTexture(context.guard, command.source.texture);
    const destination = try getTexture(context.guard, command.destination.texture);
    if (!source.getUsage(context.guard).copy_src or !destination.getUsage(context.guard).copy_dst)
        return error.InvalidCopy;
    if (source.getFormatInfo(context.guard).base_format != destination.getFormatInfo(context.guard).base_format) {
        return error.InvalidCopy;
    }
    const selected = try aspects(context.guard, source, command.source);
    if (selected.toFlags() != (try aspects(context.guard, destination, command.destination)).toFlags()) {
        return error.InvalidCopy;
    }
    if (source == destination and command.source.mip_level == command.destination.mip_level) {
        const source_end = @as(u64, command.source.origin.z) +
            command.copy_size.depth_or_array_layers;
        const destination_end = @as(u64, command.destination.origin.z) +
            command.copy_size.depth_or_array_layers;
        if (source.getDimension(context.guard) != ._2d or
            (command.source.origin.z < destination_end and
                command.destination.origin.z < source_end))
        {
            return error.InvalidCopy;
        }
    }
    if (!try hasSameTextureCopyExtent(command.source, command.destination, command.copy_size)) {
        return recordCopyImageWithTemporaryBuffer(context, command);
    }
    errdefer context.queue.poisonRecording();
    try initializeTexture(context, source, command.source, command.copy_size, false);
    try initializeTexture(context, destination, command.destination, command.copy_size, true);
    try transitionTexture(context, source, command.source, command.copy_size, false);
    try transitionTexture(context, destination, command.destination, command.copy_size, true);
    const copy = (try procs(context)).cmd_copy_image orelse return error.MissingDeviceProc;
    inline for (.{
        texture.AspectMask{ .color = 1 },
        texture.AspectMask{ .depth = 1 },
        texture.AspectMask{ .stencil = 1 },
    }) |aspect| {
        if (selected.has(aspect)) {
            const region = try computeImageCopyRegion(
                command.source,
                command.destination,
                command.copy_size,
                vulkanAspects(aspect),
            );
            copy(
                context.recording.command_buffer,
                try source.getHandle(context.guard),
                vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                try destination.getHandle(context.guard),
                vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1,
                &region,
            );
        }
    }
}

const BrowserAlpha = struct {
    unpremultiply: bool,
    premultiply: bool,
    source_opaque: bool,
};

fn browserAlpha(options: *const browser_copy.Options) BrowserAlpha {
    return .{
        .unpremultiply = options.src_alpha_mode == .premultiplied and
            (options.needs_color_space_conversion or options.dst_alpha_mode == .unpremultiplied),
        .premultiply = options.dst_alpha_mode == .premultiplied and
            (options.needs_color_space_conversion or options.src_alpha_mode == .unpremultiplied),
        .source_opaque = options.src_alpha_mode == .opaque_,
    };
}

test "browser conversion unpremultiplies before color math and premultiplies afterward" {
    const converting = browserAlpha(&.{
        .src_alpha_mode = .premultiplied,
        .dst_alpha_mode = .premultiplied,
        .needs_color_space_conversion = true,
    });
    try std.testing.expect(converting.unpremultiply);
    try std.testing.expect(converting.premultiply);
    const unchanged = browserAlpha(&.{
        .src_alpha_mode = .premultiplied,
        .dst_alpha_mode = .premultiplied,
    });
    try std.testing.expect(!unchanged.unpremultiply);
    try std.testing.expect(!unchanged.premultiply);
    try std.testing.expect(browserAlpha(&.{ .src_alpha_mode = .opaque_ }).source_opaque);
}

fn validateBrowserView(context: Context, view: *texture.TextureView, destination: bool) Error!void {
    if (view.texture.native_y_cb_cr != null) return error.TextureNativeYCbCrCopyUnsupported;
    if (view.range.level_count != 1 or view.range.layer_count != 1 or
        (view.dimension != ._2d and view.dimension != ._2d_array) or
        view.texture.sample_count != 1 or view.aspects.color == 0 or view.format_info.is_compressed)
        return error.InvalidCopy;
    const usage = view.texture.getUsage(context.guard);
    if (destination) {
        if (!usage.copy_dst) return error.InvalidCopy;
    } else {
        if (!usage.copy_src) return error.InvalidCopy;
    }
}

fn browserTargetView(context: Context, view: *texture.TextureView) Error!*texture.TextureView {
    if (view.dimension == ._2d) return view;
    const utility = try utilityContext(context);
    const handle = try texture.Texture.createView(
        context.allocator,
        utility.io,
        context.guard,
        utility.device,
        .{ .handle = @ptrCast(view.texture) },
        .{
            .descriptor = .{
                .format = view.format,
                .dimension = ._2d,
                .aspect = .all,
                .base_mip_level = view.range.base_mip_level,
                .mip_level_count = 1,
                .base_array_layer = view.range.base_array_layer,
                .array_layer_count = 1,
                .usage = view.usage,
            },
            .format_info = view.format_info,
            .compatibility_mode = view.texture.compatibility_mode,
        },
    );
    const target = try texture.resolveTextureView(utility.device, context.guard, handle);
    defer target.header.releaseUserLocked(context.guard, utility.io) catch unreachable;
    try target.initializeNative(context.guard);
    try blit_common.retainView(utility, target);
    return target;
}

fn browserRectangle(origin: browser_copy.Origin2D, size: browser_copy.Extent2D) native_blit.Rect {
    return .{ .x = origin.x, .y = origin.y, .width = size.width, .height = size.height };
}

pub fn copyTextureForBrowser(
    context: Context,
    command: commands.CopyTextureForBrowserCmd,
) Error!void {
    if (command.copy_size.width == 0 or command.copy_size.height == 0) return;
    const utility = try utilityContext(context);
    try command.options.validate();
    const source = try native_resources.resolveTextureViewRefLocked(
        context.guard,
        utility.device,
        command.source,
    );
    const destination = try native_resources.resolveTextureViewRefLocked(
        context.guard,
        utility.device,
        command.destination,
    );
    try validateBrowserView(context, source, false);
    try validateBrowserView(context, destination, true);
    const target = try copyTarget(context, try browserTargetView(context, destination), 0);
    const alpha = browserAlpha(&command.options);
    errdefer context.queue.poisonRecording();
    try native_blit.colorToColor(utility, .{
        .source = source,
        .target = target,
        .source_rectangle = browserRectangle(command.source_origin, command.copy_size),
        .rectangle = browserRectangle(command.destination_origin, command.copy_size),
        .filter = .nearest,
        .flip_y = command.options.flip_y,
        .premultiply_alpha = alpha.premultiply,
        .unpremultiply_alpha = alpha.unpremultiply,
        .source_opaque = alpha.source_opaque,
        .decode_destination_srgb = destination.format == .rgba8_unorm_srgb or
            destination.format == .bgra8_unorm_srgb,
        .color_transform = if (command.options.needs_color_space_conversion) .{
            .source_transfer = command.options.src_transfer_function_parameters,
            .destination_transfer = command.options.dst_transfer_function_parameters,
            .matrix = command.options.conversion_matrix,
        } else null,
    });
}

pub fn copyExternalTextureForBrowser(
    context: Context,
    command: commands.CopyExternalTextureForBrowserCmd,
) Error!void {
    if (command.copy_size.width == 0 or command.copy_size.height == 0) return;
    const utility = try utilityContext(context);
    try command.options.validate();
    const source = try native_resources.resolveExternalTextureRefLocked(
        context.guard,
        utility.device,
        command.source,
    );
    const destination = try native_resources.resolveTextureViewRefLocked(
        context.guard,
        utility.device,
        command.destination,
    );
    try validateBrowserView(context, destination, true);
    var validated = try external_texture.validateBrowserCopy(utility, source, .{
        .natural_size = .{
            .width = command.natural_size.width,
            .height = command.natural_size.height,
        },
        .source_origin = .{ .x = command.source_origin.x, .y = command.source_origin.y },
        .copy_size = .{ .width = command.copy_size.width, .height = command.copy_size.height },
        .options = command.options,
    });
    for (source.planes[0..source.plane_count]) |plane| {
        if (plane.texture == destination.texture and
            plane.range.base_mip_level == destination.range.base_mip_level and
            plane.range.base_array_layer == destination.range.base_array_layer)
            return error.BlitSourceTargetAlias;
    }
    const target = try copyTarget(context, try browserTargetView(context, destination), 0);
    const rectangle = browserRectangle(command.destination_origin, command.copy_size);
    try blit_common.checkRect(target, rectangle);
    errdefer context.queue.poisonRecording();
    const pass = try blit_common.createPass(utility, target);
    const prepared = try external_texture.prepareBrowserCopy(utility, &validated, .{
        .compatible_render_pass = pass.handle,
        .attachments = target.attachments,
    });
    try blit_common.beginPass(utility, target, pass);
    try kernels.recordDraw(utility, .{
        .prepared = prepared,
        .render_pass = pass.handle,
        .attachments = target.attachments,
        .viewport = .{
            .x = @floatFromInt(rectangle.x),
            .y = @floatFromInt(rectangle.y),
            .width = @floatFromInt(rectangle.width),
            .height = @floatFromInt(rectangle.height),
            .minDepth = 0,
            .maxDepth = 1,
        },
        .scissor = .{
            .offset = .{ .x = @intCast(rectangle.x), .y = @intCast(rectangle.y) },
            .extent = .{ .width = rectangle.width, .height = rectangle.height },
        },
    });
    try blit_common.endPass(utility, target);
}

pub fn clearBuffer(context: Context, command: commands.ClearBufferCmd) Error!void {
    if (command.size == 0) return;
    const destination = try getBuffer(command.buffer);
    try checkBufferRange(destination, command.offset, command.size);
    if (!destination.usage.copy_dst or command.offset % 4 != 0 or command.size % 4 != 0) {
        return error.InvalidCopy;
    }
    try destination.validateCanUseOnQueueNow();
    defer destination.finishUse();
    errdefer context.queue.poisonRecording();
    const lazy_clear = destination.needsInitialization() and
        !destination.isFullBufferRange(command.offset, command.size);
    try destination.ensureDataInitializedAsDestination(
        recording(context),
        command.offset,
        command.size,
    );
    try transitionBuffer(context, destination, .{ .copy_dst = true });
    if (lazy_clear) return;
    const fill = (try procs(context)).cmd_fill_buffer orelse return error.MissingDeviceProc;
    fill(
        context.recording.command_buffer,
        destination.getHandle(),
        command.offset,
        command.size,
        0,
    );
}

pub fn writeBuffer(
    context: Context,
    command: commands.WriteBufferCmd,
    data: []const u8,
) Error!void {
    if (data.len != command.size) return error.InvalidCopy;
    if (data.len == 0) return;
    const destination = try getBuffer(command.buffer);
    try destination.validateWriteBuffer(.{ .buffer_offset = command.offset, .data = data });
    const temporary = try context.queue.createTemporaryBuffer(
        context.queue.context.allocator,
        destination.device,
        .{
            .size = data.len,
            .usage = .{ .map_write = true, .copy_src = true },
            .mapped_at_creation = true,
        },
    );
    const mapped = temporary.mapped orelse return error.BufferHostVisibleExpected;
    @memcpy(mapped[0..data.len], data);
    temporary.is_data_initialized = true;
    errdefer context.queue.poisonRecording();
    const unmapped = try temporary.unmap(recording(context));
    // This queue-owned, host-visible upload has no secondary staging buffer.
    std.debug.assert(unmapped.staging_upload == null);
    try copyBufferToBuffer(context, .{
        .source = temporary,
        .source_offset = 0,
        .destination = destination,
        .destination_offset = command.offset,
        .size = data.len,
    });
}
