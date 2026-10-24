//! Native helper pixels are observed only after an accepted serial completes.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_resources;
const kernels = engine.native_kernels;
const blit = engine.native_blit;
const vk = dusk.platform.vulkan_bindings;
const sentinel: u8 = 0xa5;
const pitch: usize = 256;
const padded_size: usize = pitch * 8;

// No device, missing shaders, or missing baseline formats are test failures.
test "native blit shader padded4x4 RGBA BGRA pack unpack preserves neighbors and row padding" {
    try runOnGpu(std.testing.allocator, exerciseColorRoundTrips);
}

test "native blit drawClear mixed float signed unsigned attachments preserves inactive slots" {
    try runOnGpu(std.testing.allocator, exerciseTypedClears);
}

test "native blit depth copy preserves precision and stencil masked draws preserve depth" {
    try runOnGpu(std.testing.allocator, exerciseDepthStencil);
}

test "native blit helper then unchanged caller pipeline and bind group produces caller pixels" {
    try runOnGpu(std.testing.allocator, exerciseCallerState);
}

test "native blit failN rolls back creator aliases and never publishes an unaccepted serial" {
    try exerciseFailN();
}

test "native blit submit refusal keeps derived scratch serial zero" {
    try runOnGpu(std.testing.allocator, exerciseSubmitRefusal);
}

test "native blit frontend stencil byte offset one replay preserves neighbors depth and padding" {
    try runOnGpu(std.testing.allocator, exerciseFrontendStencil);
}

test "native blit four sample clear and shader pack read every actual sample" {
    try runOnGpu(std.testing.allocator, exerciseMultisample);
}

test "native blit invalid sample rectangle range and arithmetic fail before recording" {
    try runOnGpu(std.testing.allocator, exerciseInvalidRequests);
}

test "native blit real compute pipeline native OOM rolls back unaccepted resources" {
    try runOnGpu(std.testing.allocator, exerciseNativeFailure);
}

test "native blit depth16 offset two odd width shader roundtrip preserves every padding byte" {
    try runOnGpu(std.testing.allocator, exerciseDepth16);
}

test "native blit split typed clear failN poisons partial parameter uploads without publishing a serial" {
    try exercisePrepareClearFailN();
}

test "native browser copy submits nonlinear alpha flip and selected mip layer with exact preservation" {
    try runOnGpu(std.testing.allocator, exerciseBrowserFloat);
}

test "native browser copy preserves encoded RGBA BGRA bytes through actual sRGB attachments" {
    try runOnGpu(std.testing.allocator, exerciseBrowserSrgb);
}

test "native color blit actual linear and nearest samplers swizzle red blue into float attachments" {
    try runOnGpu(std.testing.allocator, exerciseColorFiltering);
}

test "native color blit stages original overlapping image before linear swizzled destination draws" {
    try runOnGpu(std.testing.allocator, exerciseAliasedColor);
}

test "native clear draws uint slot seven through sparse eight slot render pass without compacting" {
    try runOnGpu(std.testing.allocator, exerciseSparseClear);
}

test "native blit signed texel interval accepts last i32 coordinate and rejects empty overflow intervals" {
    const maximum: u32 = std.math.maxInt(i32);
    try std.testing.expectError(error.InvalidBlitRegion, blit.validateSignedTexelRange(0, 0));
    try blit.validateSignedTexelRange(maximum, 1);
    try std.testing.expectError(error.InvalidBlitRegion, blit.validateSignedTexelRange(maximum, 2));
    try blit.validateSignedTexelRange(0, maximum + 1);
    try std.testing.expectError(error.InvalidBlitRegion, blit.validateSignedTexelRange(maximum + 1, 1));
    try std.testing.expectError(error.InvalidBlitRegion, blit.validateSignedTexelRange(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    ));
}

test "native blit invalid signed pack endpoint on real tiny image precedes allocation roots and recording" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try runOnGpuWith(failing.allocator(), exerciseSignedPackEndpoint, &failing);
}

test "native color and depth copy invalid signed rectangles layers precede source lowering and allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try runOnGpuWith(failing.allocator(), exerciseSignedRenderEndpoints, &failing);
}

test "native multisample depth shader pack reads all four public pass cleared samples exactly" {
    try runOnGpu(std.testing.allocator, exerciseMultisampleDepth);
}

fn runOnGpu(allocator: std.mem.Allocator, comptime exercise: anytype) !void {
    try runOnGpuWith(allocator, exercise, {});
}

fn runOnGpuWith(
    allocator: std.mem.Allocator,
    comptime exercise: anytype,
    options: anytype,
) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var instance = engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("blit instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("blit adapter teardown failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var callback_context: u8 = 0;
    const required: api.Limits = .{ .max_immediate_size = 0 };
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .required_limits = &required,
        .consume_adapter = false,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("blit device teardown failed");
    try exercise(allocator, io, &device, options);
}

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("native blit reported an uncaptured error");
}

fn release(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device, resource: anytype) void {
    device.release(allocator, io, resource) catch @panic("blit alias release failed");
}

const Batch = struct {
    lease: engine.Device.QueueLease,
    recording: engine.recording_context.CommandRecordingContext,

    fn init(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device) !Batch {
        var lease = try device.getQueue(io);
        errdefer lease.deinit(io);
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const native_context = device.native orelse return error.NativeBackendRequired;
        if (native_context.recording_uses != null) return error.UnexpectedRecordingRoots;
        native_context.recording_uses = try native.PendingUses.prepareDeclaredLocked(
            allocator,
            &guard,
            &device.core,
            &.{},
        );
        var recording = engine.recording_context.CommandRecordingContext.init(allocator);
        recording.command_buffer = lease.commandBuffer();
        return .{ .lease = lease, .recording = recording };
    }

    fn context(self: *Batch, io: std.Io, guard: *const core.ObjectGuard) kernels.Context {
        const device = self.lease.device.?;
        const native_context = device.native.?;
        return .{
            .io = io,
            .guard = guard,
            .device = &device.core,
            .queue = &native_context.queue,
            .recording = &self.recording,
            .pending_uses = &native_context.recording_uses.?,
            .cache = &native_context.kernel_cache.?,
        };
    }

    fn bufferRecording(self: *const Batch) engine.buffer.Recording {
        return .{
            .command_buffer = self.recording.command_buffer,
            .pending_serial = self.lease.lastSubmittedSerial() + 1,
        };
    }

    fn submit(self: *Batch, allocator: std.mem.Allocator, io: std.Io) !dusk.platform.Serial {
        const submitted = try self.lease.submit(allocator, io, .{
            .command_buffers = &.{self.lease.commandBuffer()},
        }, &.{});
        self.lease.deinit(io);
        return submitted.serial;
    }

    fn deinit(self: *Batch, io: std.Io) void {
        self.recording.deinit();
        self.lease.deinit(io);
    }

    fn retain(self: *Batch, io: std.Io, guard: *const core.ObjectGuard, root: *core.Object) !void {
        const context_value = self.context(io, guard);
        try context_value.pending_uses.retainDerivedRootLocked(guard, context_value.device, root);
    }

    fn upload(
        self: *Batch,
        io: std.Io,
        guard: *const core.ObjectGuard,
        destination: *native.Buffer,
        bytes: []const u8,
    ) !void {
        if (bytes.len != destination.native.size or bytes.len % 4 != 0) {
            return error.InvalidFixtureUpload;
        }
        try self.retain(io, guard, &destination.header);
        const recording = self.bufferRecording();
        try destination.native.transitionUsageNow(
            recording,
            (api.BufferUsage{ .copy_dst = true }).toFlags(),
            .{},
        );
        const procs = self.lease.device.?.native.?.native_device.procs;
        const update = procs.cmd_update_buffer orelse return error.MissingDeviceProc;
        update(recording.command_buffer, destination.native.getHandle(), 0, bytes.len, bytes.ptr);
        destination.native.is_data_initialized = true;
    }

    fn fillReadback(
        self: *Batch,
        io: std.Io,
        guard: *const core.ObjectGuard,
        destination: *native.Buffer,
    ) !void {
        try self.retain(io, guard, &destination.header);
        const recording = self.bufferRecording();
        try destination.native.transitionUsageNow(
            recording,
            (api.BufferUsage{ .copy_dst = true }).toFlags(),
            .{},
        );
        const fill = self.lease.device.?.native.?.native_device.procs.cmd_fill_buffer orelse return error.MissingDeviceProc;
        fill(recording.command_buffer, destination.native.getHandle(), 0, destination.native.size, 0xa5a5a5a5);
        destination.native.is_data_initialized = true;
    }

    fn copyImage(
        self: *Batch,
        io: std.Io,
        guard: *const core.ObjectGuard,
        source: *engine.texture.TextureView,
        destination: *native.Buffer,
        bytes_per_pixel: u32,
    ) !void {
        try self.retain(io, guard, &source.header);
        try self.retain(io, guard, &source.texture.header);
        try self.retain(io, guard, &destination.header);
        const recording = self.bufferRecording();
        try source.texture.transition(guard, recording, source.range, .{ .copy_src = true }, .{});
        try destination.native.transitionUsageNow(
            recording,
            (api.BufferUsage{ .copy_dst = true }).toFlags(),
            .{},
        );
        const aspect: u32 = if (source.aspects.depth != 0) vk.VK_IMAGE_ASPECT_DEPTH_BIT else if (source.aspects.stencil != 0) vk.VK_IMAGE_ASPECT_STENCIL_BIT else vk.VK_IMAGE_ASPECT_COLOR_BIT;
        const size = source.texture.getMipLevelSingleSubresourceVirtualSize(
            guard,
            source.range.base_mip_level,
        );
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = pitch,
            .bufferRowLength = @intCast(@divExact(pitch, bytes_per_pixel)),
            .bufferImageHeight = size.height,
            .imageSubresource = .{
                .aspectMask = aspect,
                .mipLevel = source.range.base_mip_level,
                .baseArrayLayer = source.range.base_array_layer,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = size.width, .height = size.height, .depth = 1 },
        };
        const copy = self.lease.device.?.native.?.native_device.procs.cmd_copy_image_to_buffer orelse return error.MissingDeviceProc;
        copy(recording.command_buffer, try source.texture.getHandle(guard), vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, destination.native.getHandle(), 1, &region);
    }

    fn hostBarrier(self: *Batch, readback: *native.Buffer) !void {
        try readback.native.transitionUsageNow(
            self.bufferRecording(),
            (api.BufferUsage{ .map_read = true }).toFlags(),
            .{},
        );
    }
};

fn createImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    format: api.TextureFormat,
    width: u32,
    height: u32,
) !*engine.texture.Texture {
    return device.createTexture(allocator, io, .{
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = format,
        .usage = .{ .copy_src = true, .copy_dst = true, .render_attachment = true, .texture_binding = true },
    });
}

fn createView(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    image: *engine.texture.Texture,
    aspect: api.TextureAspect,
) !*engine.texture.TextureView {
    return device.createTextureView(allocator, io, .{
        .texture = image,
        .descriptor = .{
            .format = try engine.format.toApiFormat(image.format_info.format),
            .dimension = ._2d,
            .aspect = aspect,
        },
    });
}

fn createReadback(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
) !*native.Buffer {
    return device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_dst = true, .map_read = true },
    });
}

fn range(owner: *native.Buffer) kernels.BufferRange {
    return .{ .owner = owner, .offset = 0, .size = owner.native.size };
}

fn target(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    guard: *const core.ObjectGuard,
    colors: []const *engine.texture.TextureView,
    depth_stencil: ?*engine.texture.TextureView,
    width: u32,
    height: u32,
) !blit.Target {
    var value: dusk.command.attachment_state.AttachmentState = .{};
    value.sample_count = if (colors.len != 0) colors[0].texture.sample_count else if (depth_stencil) |view| view.texture.sample_count else return error.NoAttachmentInRenderPass;
    var views: [8]?*engine.texture.TextureView = @splat(null);
    for (colors, 0..) |view, index| {
        views[index] = view;
        value.color_attachments_set |= @as(u8, 1) << @intCast(index);
        value.color_formats[index] = @backingInt(view.format);
    }
    if (depth_stencil) |view| value.depth_stencil_format = @backingInt(view.format);
    const native_context = device.native.?;
    const attachment = try engine.native_attachment_store.create(
        allocator,
        io,
        guard,
        &device.core.arena,
        &native_context.resource_store.?,
        value,
    );
    return .{
        .attachments = attachment,
        .colors = views,
        .depth_stencil = depth_stencil,
        .render_pass_cache = &native_context.render_pass_cache,
        .framebuffer_cache = &native_context.framebuffer_cache,
        .width = width,
        .height = height,
    };
}

fn mapped(device: *engine.Device, io: std.Io, readback: *native.Buffer) ![]const u8 {
    try device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = padded_size });
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try std.testing.expect(readback.header.isAlive(&guard));
    return readback.native.getConstMappedRange(0, padded_size);
}

fn expectPadding(bytes: []const u8, width: usize, height: usize, bytes_per_pixel: usize) !void {
    for (bytes, 0..) |byte, index| {
        const row = index / pitch;
        const column = index % pitch;
        if (row >= 1 and row <= height and column < width * bytes_per_pixel) continue;
        try std.testing.expectEqual(sentinel, byte);
    }
}

fn pixelOffset(x: usize, y: usize, bytes_per_pixel: usize) usize {
    return pitch + y * pitch + x * bytes_per_pixel;
}

fn exerciseColorRoundTrips(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    for ([_]api.TextureFormat{ .rgba8_unorm, .bgra8_unorm }) |format| {
        try colorRoundTrip(allocator, io, device, format);
    }
}

fn colorRoundTrip(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    format: api.TextureFormat,
) !void {
    const image = try createImage(allocator, io, device, format, 6, 6);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const packed_readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, packed_readback);
    const neighbors = try createReadback(allocator, io, device);
    defer release(allocator, io, device, neighbors);
    var bytes: [padded_size]u8 = @splat(sentinel);
    for (0..4) |y| for (0..4) |x| {
        const at = pixelOffset(x, y, 4);
        bytes[at..][0..4].* = .{
            @intCast(13 + x * 31),         @intCast(29 + y * 41),
            @intCast(71 + x * 7 + y * 11), @intCast(149 + x * 9 + y * 13),
        };
    };
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{view}, null, 6, 6);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("color attachment alias release failed");
        const context = batch.context(io, &guard);
        try batch.upload(io, &guard, input, &bytes);
        try batch.fillReadback(io, &guard, packed_readback);
        try batch.fillReadback(io, &guard, neighbors);
        var values: [8]?blit.ClearValue = @splat(null);
        values[0] = .{ .float = .{ 17.0 / 255.0, 34.0 / 255.0, 51.0 / 255.0, 68.0 / 255.0 } };
        try blit.drawClear(context, .{
            .target = destination,
            .rectangle = .{ .x = 0, .y = 0, .width = 6, .height = 6 },
            .values = values,
        });
        try blit.bufferToColor(context, .{
            .source = range(input),
            .target = destination,
            .rectangle = .{ .x = 1, .y = 1, .width = 4, .height = 4 },
            .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 4 },
            .format = format,
        });
        try blit.textureToBuffer(context, .{
            .source = view,
            .destination = .{ .owner = packed_readback, .offset = pitch, .size = padded_size - pitch },
            .origin = .{ 1, 1, 0 },
            .extent = .{ 4, 4, 1 },
            .bytes_per_row = pitch,
            .rows_per_image = 4,
        });
        try batch.copyImage(io, &guard, view, neighbors, 4);
        try batch.hostBarrier(packed_readback);
        try batch.hostBarrier(neighbors);
        try expectKernel(device, .texture_to_buffer);
        try expectKernel(device, .buffer_to_color);
        try std.testing.expectEqual(@as(u64, 0), packed_readback.accepted_usage_serial);
        try std.testing.expectEqual(@as(u64, 0), input.accepted_usage_serial);
        try std.testing.expect(!input.native.getUsage().storage);
    }
    const serial = try batch.submit(allocator, io);
    try expectAcceptedRoots(device, io, serial);
    try std.testing.expect(serial != 0);
    try std.testing.expectEqual(serial, packed_readback.accepted_usage_serial);
    try std.testing.expectEqual(serial, input.accepted_usage_serial);
    try device.wait(io, serial);
    const result = try mapped(device, io, packed_readback);
    defer device.unmapBuffer(io, packed_readback) catch @panic("packed unmap failed");
    try std.testing.expectEqualSlices(u8, &bytes, result);
    const surroundings = try mapped(device, io, neighbors);
    defer device.unmapBuffer(io, neighbors) catch @panic("neighbors unmap failed");
    for (0..6) |y| for (0..6) |x| {
        const at = pixelOffset(x, y, 4);
        if (x >= 1 and x <= 4 and y >= 1 and y <= 4) {
            const source_at = pixelOffset(x - 1, y - 1, 4);
            try std.testing.expectEqualSlices(u8, bytes[source_at..][0..4], surroundings[at..][0..4]);
        } else {
            const expected: [4]u8 = if (format == .bgra8_unorm)
                .{ 51, 34, 17, 68 }
            else
                .{ 17, 34, 51, 68 };
            try std.testing.expectEqualSlices(u8, &expected, surroundings[at..][0..4]);
        }
    };
    try expectPadding(surroundings, 6, 6, 4);
}

fn expectKernel(device: *engine.Device, id: kernels.KernelId) !void {
    for (device.native.?.kernel_cache.?.entries) |entry| {
        if (entry) |value| if (value.key.id == id) {
            try std.testing.expect(value.pipeline.native.vk_pipeline != null);
            try std.testing.expect(value.pipeline.header.user_reference_count == 0);
            if (id == .buffer_to_depth or id == .depth_to_depth) {
                try std.testing.expectEqual(@as(u32, 8), value.pipeline.native.immediate_size);
                try std.testing.expectEqual(@as(u64, 3), value.pipeline.native.immediate_mask);
            }
            return;
        };
    }
    return error.ExpectedNativeKernelAbsent;
}

fn exerciseTypedClears(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const formats = [_]api.TextureFormat{ .r32_float, .r32_sint, .r32_uint, .r32_uint };
    var images: [4]*engine.texture.Texture = undefined;
    var views: [4]*engine.texture.TextureView = undefined;
    var readbacks: [4]*native.Buffer = undefined;
    var image_count: usize = 0;
    var view_count: usize = 0;
    var readback_count: usize = 0;
    defer for (images[0..image_count]) |image| release(allocator, io, device, image);
    defer for (views[0..view_count]) |view| release(allocator, io, device, view);
    defer for (readbacks[0..readback_count]) |readback| release(allocator, io, device, readback);
    for (formats, 0..) |format, index| {
        images[index] = try createImage(allocator, io, device, format, 4, 4);
        image_count += 1;
        views[index] = try createView(allocator, io, device, images[index], .all);
        view_count += 1;
        readbacks[index] = try createReadback(allocator, io, device);
        readback_count += 1;
    }
    const initial = [_]?blit.ClearValue{
        .{ .float = .{ 0.125, -0.25, 0.5, 1 } },
        .{ .sint = .{ -101, 203, -307, 409 } },
        .{ .uint = .{ 11, 13, 17, 19 } },
        .{ .uint = .{ 0xfedcba98, 0x80000001, 23, 29 } },
    };
    const changed = [_]?blit.ClearValue{
        .{ .float = .{ -3.5, 1.25, 0.03125, 7 } },
        .{ .sint = .{ -2147483000, 1234567, -7654321, 2147483000 } },
        .{ .uint = .{ 0xfffffffe, 0x80000000, 0x12345678, 0xfedcba98 } },
        null,
    };
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &views, null, 4, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("clear attachment alias release failed");
        var initial_values: [8]?blit.ClearValue = @splat(null);
        var changed_values: [8]?blit.ClearValue = @splat(null);
        @memcpy(initial_values[0..4], &initial);
        @memcpy(changed_values[0..4], &changed);
        const context = batch.context(io, &guard);
        try blit.drawClear(context, .{
            .target = destination,
            .rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .values = initial_values,
        });
        try blit.drawClear(context, .{
            .target = destination,
            .rectangle = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
            .values = changed_values,
        });
        for (views, readbacks) |view, readback| {
            try batch.fillReadback(io, &guard, readback);
            try batch.copyImage(io, &guard, view, readback, 4);
            try batch.hostBarrier(readback);
        }
        try expectKernel(device, .clear_color);
    }
    const serial = try batch.submit(allocator, io);
    try device.wait(io, serial);
    for (readbacks, 0..) |readback, index| {
        const bytes = try mapped(device, io, readback);
        defer device.unmapBuffer(io, readback) catch @panic("typed clear unmap failed");
        for (0..4) |y| for (0..4) |x| {
            const selected = if (x >= 1 and x < 3 and y >= 1 and y < 3 and changed[index] != null)
                changed[index].?
            else
                initial[index].?;
            const expected: [4]u32 = switch (selected) {
                .float => |value| .{ @bitCast(value[0]), @bitCast(value[1]), @bitCast(value[2]), @bitCast(value[3]) },
                .sint => |value| .{ @bitCast(value[0]), @bitCast(value[1]), @bitCast(value[2]), @bitCast(value[3]) },
                .uint => |value| value,
            };
            const at = pixelOffset(x, y, 4);
            try std.testing.expectEqual(expected[0], std.mem.readInt(u32, bytes[at..][0..4], .little));
        };
        try expectPadding(bytes, 4, 4, 4);
    }
}

fn exerciseDepthStencil(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    try std.testing.expectEqual(@as(u32, 0), device.limits.v1.max_immediate_size);
    const source_image = try createImage(allocator, io, device, .depth32_float, 4, 4);
    defer release(allocator, io, device, source_image);
    const source = try createView(allocator, io, device, source_image, .depth_only);
    defer release(allocator, io, device, source);
    const destination_image = try createImage(allocator, io, device, .depth24_plus_stencil8, 6, 6);
    defer release(allocator, io, device, destination_image);
    const destination = try createView(allocator, io, device, destination_image, .all);
    defer release(allocator, io, device, destination);
    const destination_depth = try createView(allocator, io, device, destination_image, .depth_only);
    defer release(allocator, io, device, destination_depth);
    const destination_stencil = try createView(allocator, io, device, destination_image, .stencil_only);
    defer release(allocator, io, device, destination_stencil);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const stencil_input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, stencil_input);
    const source_readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, source_readback);
    const depth_readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, depth_readback);
    const stencil_before = try createReadback(allocator, io, device);
    defer release(allocator, io, device, stencil_before);
    const stencil_after = try createReadback(allocator, io, device);
    defer release(allocator, io, device, stencil_after);
    const samples = [_]f32{
        0,       1,      0.00001, 0.99999, 0.12345679, 0.33333334,     0.50000006, 0.875,
        0.03125, 0.0625, 0.25,    0.75,    0.9876543,  0.000244140625, 0.49999997, 0.625,
    };
    const stencil_samples = [_]u8{
        0, 1, 2, 4, 8, 16, 32, 64, 128, 255, 0x55, 0xaa, 0x81, 0xfe, 0x7f, 0,
    };
    var depth_bytes: [padded_size]u8 = @splat(0);
    var stencil_bytes: [padded_size]u8 = @splat(0x69);
    for (0..6) |y| for (0..6) |x| {
        const at = pixelOffset(x, y, 4);
        std.mem.writeInt(u32, depth_bytes[at..][0..4], @bitCast(@as(f32, 0.625)), .little);
    };
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const source_target = try target(allocator, io, device, &guard, &.{}, source, 4, 4);
        defer source_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("source depth attachment alias release failed");
        const destination_target = try target(allocator, io, device, &guard, &.{}, destination, 6, 6);
        defer destination_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("destination depth attachment alias release failed");
        const context = batch.context(io, &guard);
        try batch.upload(io, &guard, input, &depth_bytes);
        try batch.upload(io, &guard, stencil_input, &stencil_bytes);
        try blit.bufferToDepth(context, .{
            .source = range(input),
            .target = destination_target,
            .format = .depth32_float,
            .rectangle = .{ .x = 0, .y = 0, .width = 6, .height = 6 },
            .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 6 },
        });
        try blit.bufferToStencil(context, .{
            .source = range(stencil_input),
            .target = destination_target,
            .format = .stencil8,
            .rectangle = .{ .x = 0, .y = 0, .width = 6, .height = 6 },
            .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 6 },
        });
        for (samples, 0..) |sample, index| {
            const at = pixelOffset(index % 4, index / 4, 4);
            std.mem.writeInt(u32, depth_bytes[at..][0..4], @bitCast(sample), .little);
        }
        try batch.upload(io, &guard, input, &depth_bytes);
        try blit.bufferToDepth(context, .{
            .source = range(input),
            .target = source_target,
            .format = .depth32_float,
            .rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 4 },
        });
        try blit.depthToDepth(context, .{
            .source = source,
            .target = destination_target,
            .source_rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .rectangle = .{ .x = 1, .y = 1, .width = 4, .height = 4 },
        });
        try batch.fillReadback(io, &guard, stencil_before);
        try batch.copyImage(io, &guard, destination_stencil, stencil_before, 1);
        for (stencil_samples, 0..) |sample, index| {
            stencil_bytes[pixelOffset(index % 4, index / 4, 1)] = sample;
        }
        try batch.upload(io, &guard, stencil_input, &stencil_bytes);
        try blit.bufferToStencil(context, .{
            .source = range(stencil_input),
            .target = destination_target,
            .format = .stencil8,
            .rectangle = .{ .x = 1, .y = 1, .width = 4, .height = 4 },
            .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 4 },
        });
        try batch.fillReadback(io, &guard, source_readback);
        try batch.fillReadback(io, &guard, depth_readback);
        try batch.fillReadback(io, &guard, stencil_after);
        try batch.copyImage(io, &guard, source, source_readback, 4);
        try batch.copyImage(io, &guard, destination_depth, depth_readback, 4);
        try batch.copyImage(io, &guard, destination_stencil, stencil_after, 1);
        for ([_]*native.Buffer{ source_readback, depth_readback, stencil_before, stencil_after }) |buffer| {
            try batch.hostBarrier(buffer);
        }
        try expectKernel(device, .buffer_to_depth);
        try expectKernel(device, .depth_to_depth);
        try expectStencilVariants(device);
    }
    const serial = try batch.submit(allocator, io);
    try device.wait(io, serial);
    const source_result = try mapped(device, io, source_readback);
    defer device.unmapBuffer(io, source_readback) catch @panic("depth source unmap failed");
    for (samples, 0..) |sample, index| {
        const at = pixelOffset(index % 4, index / 4, 4);
        try std.testing.expectEqual(@as(u32, @bitCast(sample)), std.mem.readInt(u32, source_result[at..][0..4], .little));
    }
    try expectPadding(source_result, 4, 4, 4);
    const depth_result = try mapped(device, io, depth_readback);
    defer device.unmapBuffer(io, depth_readback) catch @panic("depth destination unmap failed");
    const before = try mapped(device, io, stencil_before);
    defer device.unmapBuffer(io, stencil_before) catch @panic("stencil before unmap failed");
    const after = try mapped(device, io, stencil_after);
    defer device.unmapBuffer(io, stencil_after) catch @panic("stencil after unmap failed");
    for (0..6) |y| for (0..6) |x| {
        const inside = x >= 1 and x <= 4 and y >= 1 and y <= 4;
        const expected_depth: f64 = if (inside) samples[(y - 1) * 4 + x - 1] else 0.625;
        const depth_at = pixelOffset(x, y, 4);
        const depth_word = std.mem.readInt(u32, depth_result[depth_at..][0..4], .little);
        const observed = @as(f64, @floatFromInt(depth_word & 0xffffff)) / 16777215.0;
        try std.testing.expectApproxEqAbs(expected_depth, observed, 1.0 / 16777215.0);
        const stencil_at = pixelOffset(x, y, 1);
        try std.testing.expectEqual(@as(u8, 0x69), before[stencil_at]);
        const expected_stencil: u8 = if (inside) stencil_samples[(y - 1) * 4 + x - 1] else 0x69;
        try std.testing.expectEqual(expected_stencil, after[stencil_at]);
    };
    try expectPadding(depth_result, 6, 6, 4);
    try expectPadding(before, 6, 6, 1);
    try expectPadding(after, 6, 6, 1);
}

fn expectStencilVariants(device: *engine.Device) !void {
    var bits: u8 = 0;
    for (device.native.?.kernel_cache.?.entries) |entry| {
        if (entry) |value| if (value.key.id == .buffer_to_stencil) {
            bits |= @as(u8, 1) << (value.key.stencil_write_bit orelse return error.StencilBitAbsent);
        };
    }
    try std.testing.expectEqual(@as(u8, 0xff), bits);
}

fn exerciseCallerState(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const vertex_words = comptime decodeWords(@embedFile("fixtures/triangle.vert.spv"));
    const fragment_words = comptime decodeWords(@embedFile("fixtures/triangle.frag.spv"));
    const vertex = try device.createShaderModule(allocator, io, .{ .words = &vertex_words });
    defer release(allocator, io, device, vertex);
    const fragment = try device.createShaderModule(allocator, io, .{ .words = &fragment_words });
    defer release(allocator, io, device, fragment);
    const group_layout = try device.createBindGroupLayout(allocator, io, .{
        .entries = &.{.{
            .binding_number = 1,
            .visibility = .{ .fragment = true },
            .kind = .{ .buffer = .{ .binding_type = .uniform, .has_dynamic_offset = false, .min_binding_size = 16 } },
        }},
    });
    defer release(allocator, io, device, group_layout);
    const layout = try device.createPipelineLayout(allocator, io, .{ .groups = &.{group_layout} });
    defer release(allocator, io, device, layout);
    const tint = try device.createBuffer(allocator, io, .{
        .size = 16,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    defer release(allocator, io, device, tint);
    const group = try device.createBindGroup(allocator, io, .{
        .layout = layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 1,
            .buffer = tint,
            .offset = 0,
            .size = 16,
            .kind = .uniform,
            .stages = .{ .fragment = true },
        } }},
    });
    defer release(allocator, io, device, group);
    const pipeline = try device.createRenderPipeline(allocator, io, .{
        .layout = layout,
        .vertex = .{ .module = vertex, .entry_point = "vs_main", .stage = .vertex },
        .fragment = .{ .module = fragment, .entry_point = "fs_main", .stage = .fragment },
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });
    defer release(allocator, io, device, pipeline);
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 2);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, readback);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{view}, null, 4, 2);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("caller attachment alias release failed");
        const context = batch.context(io, &guard);
        const native_context = device.native.?;
        const procs = native_context.native_device.procs;
        const tint_words = [_]u32{
            @bitCast(@as(f32, 1)), 0, 0, @bitCast(@as(f32, 1)),
        };
        try batch.upload(io, &guard, tint, std.mem.sliceAsBytes(&tint_words));
        try tint.native.transitionUsageNow(
            batch.bufferRecording(),
            (api.BufferUsage{ .uniform = true }).toFlags(),
            .{ .fragment = true },
        );
        try batch.retain(io, &guard, &pipeline.header);
        try batch.retain(io, &guard, &group.header);
        try batch.retain(io, &guard, &view.header);
        try batch.retain(io, &guard, &image.header);
        var pass_query: engine.render_pass_cache.RenderPassCacheQuery = .{};
        pass_query.setSampleCount(1);
        pass_query.setColor(.{
            .index = 0,
            .format = .rgba8_unorm,
            .load_op = .clear,
            .store_op = .store,
            .has_resolve_target = false,
            .render_to_single_sampled = false,
        });
        const pass = try native_context.render_pass_cache.getRenderPass(io, pass_query);
        var frame_query: engine.framebuffer_cache.FramebufferCacheQuery = .{};
        frame_query.key.setRenderPass(.{ .pass_id = pass.unique_id, .width = 4, .height = 2 });
        try frame_query.addAttachment(.{
            .texture_view_id = @intFromPtr(view),
            .image_view = try view.getHandle(&guard),
            .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        });
        const framebuffer = try native_context.framebuffer_cache.getOrCreate(&frame_query, pass.render_pass);
        var values: [8]?blit.ClearValue = @splat(null);
        values[0] = .{ .float = .{ 0, 1, 0, 1 } };
        const full: blit.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 };
        const prepared = try blit.prepareDrawClear(context, .{
            .target = destination,
            .rectangle = full,
            .values = values,
        }, pass.render_pass);
        try image.transitionRenderAttachment(&guard, batch.bufferRecording(), view.range, .{});
        image.setSubresourceContentInitialized(&guard, true, view.range);
        const begin_info: vk.VkRenderPassBeginInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = pass.render_pass,
            .framebuffer = framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 4, .height = 2 } },
            .clearValueCount = 1,
            .pClearValues = &frame_query.clear_values,
        };
        const begin = procs.cmd_begin_render_pass orelse return error.MissingDeviceProc;
        const end = procs.cmd_end_render_pass orelse return error.MissingDeviceProc;
        const draw = procs.cmd_draw orelse return error.MissingDeviceProc;
        const set_viewport = procs.cmd_set_viewport orelse return error.MissingDeviceProc;
        const set_scissor = procs.cmd_set_scissor orelse return error.MissingDeviceProc;
        begin(batch.recording.command_buffer, &begin_info, vk.VK_SUBPASS_CONTENTS_INLINE);
        batch.recording.active_render_pass = pass.render_pass;
        var state: engine.command_buffer.ProgrammablePassState = .{};
        try state.onSetPipeline(&guard, .render, pipeline.native);
        try state.descriptor_sets.set(&guard, 0, group.native, &.{});
        const tracker_context: @typeInfo(@TypeOf(engine.command_buffer.ProgrammablePassState.syncAndRun)).@"fn".param_types[1].? = .{
            .guard = &guard,
            .procs = procs,
            .command_buffer = batch.recording.command_buffer,
        };
        const viewport: vk.VkViewport = .{
            .x = 2,
            .y = 0,
            .width = 2,
            .height = 2,
            .minDepth = 0,
            .maxDepth = 1,
        };
        const scissor: vk.VkRect2D = .{
            .offset = .{ .x = 2, .y = 0 },
            .extent = .{ .width = 2, .height = 2 },
        };
        try state.syncAndRun(tracker_context, vk.VK_PIPELINE_BIND_POINT_GRAPHICS);
        set_viewport(batch.recording.command_buffer, 0, 1, &viewport);
        set_scissor(batch.recording.command_buffer, 0, 1, &scissor);
        draw(batch.recording.command_buffer, 3, 1, 0, 0);
        try blit.recordPreparedClear(context, prepared, pass.render_pass, destination, full);
        state.dirtyAll();
        // Do not select the pipeline or bind group again. Restore only touched raster state.
        try state.syncAndRun(tracker_context, vk.VK_PIPELINE_BIND_POINT_GRAPHICS);
        set_viewport(batch.recording.command_buffer, 0, 1, &viewport);
        set_scissor(batch.recording.command_buffer, 0, 1, &scissor);
        draw(batch.recording.command_buffer, 3, 1, 0, 0);
        end(batch.recording.command_buffer);
        batch.recording.active_render_pass = null;
        try batch.fillReadback(io, &guard, readback);
        try batch.copyImage(io, &guard, view, readback, 4);
        try batch.hostBarrier(readback);
        try std.testing.expectEqualSlices(u32, &vertex_words, vertex.words);
        try std.testing.expectEqualSlices(u32, &fragment_words, fragment.words);
    }
    const serial = try batch.submit(allocator, io);
    try device.wait(io, serial);
    const result = try mapped(device, io, readback);
    defer device.unmapBuffer(io, readback) catch @panic("caller state unmap failed");
    for (0..2) |y| for (0..4) |x| {
        const expected: [4]u8 = if (y == 1 and x >= 2) .{ 255, 0, 0, 255 } else .{ 0, 255, 0, 255 };
        const at = pixelOffset(x, y, 4);
        try std.testing.expectEqualSlices(u8, &expected, result[at..][0..4]);
    };
    try expectPadding(result, 4, 2, 4);
}

fn decodeWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    if (bytes.len % 4 != 0) @compileError("SPIR-V fixture must contain complete words");
    var words: [bytes.len / 4]u32 = undefined;
    for (&words, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    return words;
}

const FailOptions = struct {
    failing: *std.testing.FailingAllocator,
    offset: usize,
    succeeded: *bool,
};

fn exerciseFailN() !void {
    var succeeded = false;
    const allocation_limit: usize = 4096;
    for (0..allocation_limit) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        try runOnGpuWith(failing.allocator(), exerciseRollback, FailOptions{
            .failing = &failing,
            .offset = offset,
            .succeeded = &succeeded,
        });
        if (succeeded) break;
    }
    try std.testing.expect(succeeded);
}

fn exerciseRollback(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    options: FailOptions,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, readback);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    const bytes: [padded_size]u8 = @splat(0x33);
    var failed = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{view}, null, 4, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("rollback attachment alias release failed");
        try batch.upload(io, &guard, input, &bytes);
        try batch.fillReadback(io, &guard, readback);
        const users_before = guard.objects.user_reference_count;
        options.failing.fail_index = options.failing.alloc_index + options.offset;
        const attempted = recordRollbackHelpers(batch.context(io, &guard), destination, input, readback);
        options.failing.fail_index = std.math.maxInt(usize);
        if (attempted) |_| {
            if (options.failing.has_induced_failure) return error.SwallowedAllocationFailure;
            options.succeeded.* = true;
            try batch.hostBarrier(readback);
        } else |err| {
            if (err != error.OutOfMemory) return err;
            failed = true;
            try std.testing.expect(options.failing.has_induced_failure);
            try std.testing.expectEqual(users_before, guard.objects.user_reference_count);
            // The fixture owns an already-emitted batch. A refusal abandons the whole recording.
            device.native.?.queue.poisonRecording();
            try expectUnacceptedRoots(device, &guard);
        }
        try std.testing.expectEqual(@as(u64, 0), input.accepted_usage_serial);
        try std.testing.expectEqual(@as(u64, 0), readback.accepted_usage_serial);
    }
    if (failed) {
        try std.testing.expectError(error.RecordingPoisoned, batch.submit(allocator, io));
        try std.testing.expectEqual(@as(dusk.platform.Serial, 0), batch.lease.lastSubmittedSerial());
        try std.testing.expectEqual(@as(?dusk.platform.Serial, null), device.native.?.pending_uses_serial);
        try std.testing.expectEqual(@as(u64, 0), readback.accepted_usage_serial);
        return;
    }
    const serial = try batch.submit(allocator, io);
    try std.testing.expect(serial != 0);
    try std.testing.expectEqual(serial, input.accepted_usage_serial);
    try std.testing.expectEqual(serial, readback.accepted_usage_serial);
    try device.wait(io, serial);
    const observed = try mapped(device, io, readback);
    defer device.unmapBuffer(io, readback) catch @panic("rollback success unmap failed");
    for (0..4) |y| for (0..4) |x| {
        const at = pixelOffset(x, y, 4);
        try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x33, 0x33, 0x33 }, observed[at..][0..4]);
    };
    try expectPadding(observed, 4, 4, 4);
}

fn recordRollbackHelpers(
    context: kernels.Context,
    destination: blit.Target,
    input: *native.Buffer,
    readback: *native.Buffer,
) !void {
    try blit.bufferToColor(context, .{
        .source = range(input),
        .target = destination,
        .format = .rgba8_unorm,
        .rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 4 },
    });
    try blit.textureToBuffer(context, .{
        .source = destination.colors[0].?,
        .destination = .{ .owner = readback, .offset = pitch, .size = padded_size - pitch },
        .extent = .{ 4, 4, 1 },
        .bytes_per_row = pitch,
        .rows_per_image = 4,
    });
}

fn expectUnacceptedRoots(device: *engine.Device, guard: *const core.ObjectGuard) !void {
    guard.assertOwns(device.core.arena.objectList());
    try std.testing.expectEqual(@as(dusk.platform.Serial, 0), device.native.?.queue.timeline.lastSubmittedSerial());
    try std.testing.expectEqual(@as(?dusk.platform.Serial, null), device.native.?.pending_uses_serial);
    var roots = device.native.?.recording_uses.?.roots.keyIterator();
    while (roots.next()) |root| {
        if (root.*.kind == .native_buffer) {
            const buffer: *native.Buffer = @fieldParentPtr("header", root.*);
            try std.testing.expectEqual(@as(u64, 0), buffer.accepted_usage_serial);
        }
    }
    for (device.native.?.queue.temporary_buffers.items) |temporary| {
        try std.testing.expectEqual(@as(dusk.platform.Serial, 0), temporary.serial);
    }
}

fn exerciseSubmitRefusal(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, readback);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{view}, null, 4, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("refused attachment alias release failed");
        const bytes: [padded_size]u8 = @splat(0x7f);
        try batch.upload(io, &guard, input, &bytes);
        try batch.fillReadback(io, &guard, readback);
        try recordRollbackHelpers(batch.context(io, &guard), destination, input, readback);
        try expectKernel(device, .buffer_to_color);
        try expectKernel(device, .texture_to_buffer);
        try expectUnacceptedRoots(device, &guard);
    }
    // The recording contains real commands, but this request omits its command buffer.
    try std.testing.expectError(error.PendingRecordingNotSubmitted, batch.lease.submit(
        allocator,
        io,
        .{ .command_buffers = &.{} },
        &.{},
    ));
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try expectUnacceptedRoots(device, &guard);
        device.native.?.queue.poisonRecording();
    }
    try std.testing.expectError(error.RecordingPoisoned, batch.submit(allocator, io));
}

// Direct Batch submission only; public Device.submit moves these owners into Queue.
fn expectAcceptedRoots(device: *engine.Device, io: std.Io, serial: dusk.platform.Serial) !void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const native_context = device.native.?;
    try std.testing.expectEqual(@as(?dusk.platform.Serial, serial), native_context.pending_uses_serial);
    const pending = if (native_context.pending_recording_uses) |*batch| batch else return error.PendingRootsAbsent;
    var roots = pending.roots.keyIterator();
    var scratch_count: usize = 0;
    while (roots.next()) |root| {
        if (root.*.kind == .native_buffer) {
            const buffer: *native.Buffer = @fieldParentPtr("header", root.*);
            try std.testing.expectEqual(serial, buffer.accepted_usage_serial);
            if (buffer.header.user_reference_count == 0) {
                scratch_count += 1;
                try std.testing.expect(buffer.queue_uses != 0);
                for (native_context.queue.temporary_buffers.items) |temporary| {
                    try std.testing.expect(buffer.native != temporary.buffer);
                }
            }
        }
    }
    try std.testing.expect(scratch_count != 0);
}

fn exerciseFrontendStencil(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .depth24_plus_stencil8, 6, 6);
    defer release(allocator, io, device, image);
    const attachment_view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, attachment_view);
    const depth_view = try createView(allocator, io, device, image, .depth_only);
    defer release(allocator, io, device, depth_view);
    const stencil_view = try createView(allocator, io, device, image, .stencil_only);
    defer release(allocator, io, device, stencil_view);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const result_buffer = try createReadback(allocator, io, device);
    defer release(allocator, io, device, result_buffer);
    const stencil_neighbors = try createReadback(allocator, io, device);
    defer release(allocator, io, device, stencil_neighbors);
    const depth_neighbors = try createReadback(allocator, io, device);
    defer release(allocator, io, device, depth_neighbors);
    const samples = [_]u8{
        0, 1, 2, 4, 8, 16, 32, 64, 128, 255, 0xaa, 0x55, 0x80, 0x7f, 0xfe, 0,
    };
    var source_bytes: [padded_size]u8 = @splat(0x5d);
    for (samples, 0..) |sample, index| {
        source_bytes[1 + (index / 4) * pitch + index % 4] = sample;
    }
    const untouched: [padded_size]u8 = @splat(sentinel);
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        allocator,
        device.core.borrow(),
        .{},
    );
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try input.ref(&guard), .data = &source_bytes });
        try encoder.writeBuffer(.{ .buffer = try result_buffer.ref(&guard), .data = &untouched });
    }
    var pass = try device.beginRenderPass(allocator, io, &encoder, .{
        .depth_stencil_attachment = .{
            .view = attachment_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .stencil_load_op = .clear,
            .stencil_store_op = .store,
            .clear_depth = 0.625,
            .clear_stencil = 0x69,
        },
        .width = 6,
        .height = 6,
    });
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        pass.deinit(io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try pass.end(io, &guard);
        const image_copy: dusk.command.commands.TextureCopy = .{
            .texture = image,
            .origin = .{ .x = 1, .y = 1, .z = 0 },
            .aspect = .stencil_only,
            .format = @backingInt(api.TextureFormat.depth24_plus_stencil8),
            .dimension = ._2d,
            .extent = .{ .width = 6, .height = 6, .depth_or_array_layers = 1 },
        };
        const copy_size: dusk.command.commands.Extent3D = .{
            .width = 4,
            .height = 4,
            .depth_or_array_layers = 1,
        };
        try encoder.copyBufferToTexture(.{
            .source = .{ .buffer = try input.ref(&guard), .offset = 1, .blocks_per_row = pitch, .rows_per_image = 4 },
            .destination = image_copy,
            .copy_size = copy_size,
        });
        try encoder.copyTextureToBuffer(.{
            .source = image_copy,
            .destination = .{ .buffer = try result_buffer.ref(&guard), .offset = 1, .blocks_per_row = pitch, .rows_per_image = 4 },
            .copy_size = copy_size,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    const first_serial = try device.submit(allocator, io, &finished);
    try std.testing.expect(first_serial != 0);
    try std.testing.expectEqual(first_serial, input.accepted_usage_serial);
    try std.testing.expectEqual(first_serial, result_buffer.accepted_usage_serial);
    try device.wait(io, first_serial);
    {
        const result = try mapped(device, io, result_buffer);
        defer device.unmapBuffer(io, result_buffer) catch @panic("frontend result unmap failed");
        for (result, 0..) |byte, index| {
            const row = index / pitch;
            const column = index % pitch;
            const expected: u8 = if (row < 4 and column >= 1 and column <= 4)
                samples[row * 4 + column - 1]
            else
                sentinel;
            try std.testing.expectEqual(expected, byte);
        }
    }
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try batch.fillReadback(io, &guard, stencil_neighbors);
        try batch.fillReadback(io, &guard, depth_neighbors);
        try batch.copyImage(io, &guard, stencil_view, stencil_neighbors, 1);
        try batch.copyImage(io, &guard, depth_view, depth_neighbors, 4);
        try batch.hostBarrier(stencil_neighbors);
        try batch.hostBarrier(depth_neighbors);
        try expectStencilVariants(device);
        try expectKernel(device, .texture_to_buffer);
        try std.testing.expect(!input.native.getUsage().storage);
        try std.testing.expect(!result_buffer.native.getUsage().storage);
    }
    const second_serial = try batch.submit(allocator, io);
    try std.testing.expect(second_serial > first_serial);
    try device.wait(io, second_serial);
    const stencil_result = try mapped(device, io, stencil_neighbors);
    defer device.unmapBuffer(io, stencil_neighbors) catch @panic("frontend stencil unmap failed");
    const depth_result = try mapped(device, io, depth_neighbors);
    defer device.unmapBuffer(io, depth_neighbors) catch @panic("frontend depth unmap failed");
    for (0..6) |y| for (0..6) |x| {
        const inside = x >= 1 and x <= 4 and y >= 1 and y <= 4;
        const expected: u8 = if (inside) samples[(y - 1) * 4 + x - 1] else 0x69;
        try std.testing.expectEqual(expected, stencil_result[pixelOffset(x, y, 1)]);
        const at = pixelOffset(x, y, 4);
        const word = std.mem.readInt(u32, depth_result[at..][0..4], .little) & 0xffffff;
        const depth = @as(f64, @floatFromInt(word)) / 16777215.0;
        try std.testing.expectApproxEqAbs(@as(f64, 0.625), depth, 1.0 / 16777215.0);
    };
    try expectPadding(stencil_result, 6, 6, 1);
    try expectPadding(depth_result, 6, 6, 4);
}

fn exerciseMultisample(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    try multisampleFormat(allocator, io, device, .rgba8_unorm, .{ .float = .{ 91.0 / 255.0, 37.0 / 255.0, 203.0 / 255.0, 1 } }, .{ 91, 37, 203, 255 });
    try multisampleFormat(allocator, io, device, .rgba8_uint, .{ .uint = .{ 7, 129, 203, 255 } }, .{ 7, 129, 203, 255 });
    try multisampleFormat(allocator, io, device, .rgba8_sint, .{ .sint = .{ -127, -31, 67, 126 } }, .{ 129, 225, 67, 126 });
}

fn multisampleFormat(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    format: api.TextureFormat,
    clear: blit.ClearValue,
    expected: [4]u8,
) !void {
    const image = try device.createTexture(allocator, io, .{
        .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
        .format = format,
        .sample_count = 4,
        .usage = .{ .render_attachment = true, .texture_binding = true },
    });
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    var outputs: [4]*native.Buffer = undefined;
    var output_count: usize = 0;
    defer for (outputs[0..output_count]) |output| release(allocator, io, device, output);
    for (&outputs) |*output| {
        output.* = try createReadback(allocator, io, device);
        output_count += 1;
    }
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{view}, null, 4, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("multisample attachment release failed");
        var values: [8]?blit.ClearValue = @splat(null);
        values[0] = clear;
        const context = batch.context(io, &guard);
        try blit.drawClear(context, .{
            .target = destination,
            .rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .values = values,
        });
        for (outputs, 0..) |output, sample| {
            try batch.fillReadback(io, &guard, output);
            try blit.textureToBuffer(context, .{
                .source = view,
                .destination = .{ .owner = output, .offset = pitch, .size = padded_size - pitch },
                .extent = .{ 4, 4, 1 },
                .sample_index = @intCast(sample),
                .bytes_per_row = pitch,
                .rows_per_image = 4,
            });
            try batch.hostBarrier(output);
        }
        var clear_variant = false;
        var pack_variant = false;
        for (device.native.?.kernel_cache.?.entries) |entry| {
            if (entry) |value| {
                if (value.key.id == .clear_color and value.key.attachments.?.value.sample_count == 4)
                    clear_variant = true;
                if (value.key.id == .texture_to_buffer and value.key.source_multisampled)
                    pack_variant = true;
            }
        }
        try std.testing.expect(clear_variant);
        try std.testing.expect(pack_variant);
    }
    const serial = try batch.submit(allocator, io);
    try expectAcceptedRoots(device, io, serial);
    try device.wait(io, serial);
    for (outputs) |output| {
        const bytes = try mapped(device, io, output);
        defer device.unmapBuffer(io, output) catch @panic("multisample output unmap failed");
        for (0..4) |y| for (0..4) |x| {
            const at = pixelOffset(x, y, 4);
            try std.testing.expectEqualSlices(u8, &expected, bytes[at..][0..4]);
        };
        try expectPadding(bytes, 4, 4, 4);
    }
}

fn exerciseInvalidRequests(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, readback);
    var foreign_callback_context: u8 = 0;
    var foreign_device = try device.adapter.createDevice(allocator, io, .{
        .adapter = device.adapter,
        .feature_level = .core,
        .uncaptured_context = &foreign_callback_context,
        .uncaptured_callback = uncaptured,
    });
    defer foreign_device.deinit(allocator, io) catch @panic("foreign device teardown failed");
    const foreign_image = try createImage(allocator, io, &foreign_device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, &foreign_device, foreign_image);
    const foreign_view = try createView(allocator, io, &foreign_device, foreign_image, .all);
    defer release(allocator, io, &foreign_device, foreign_view);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const context = batch.context(io, &guard);
    try batch.retain(io, &guard, &view.header);
    try batch.retain(io, &guard, &image.header);
    const roots_before = context.pending_uses.roots.count();
    const users_before = guard.objects.user_reference_count;
    const handles_before = device.native.?.native_device.handles.counts;
    const base: blit.TextureToBuffer = .{
        .source = view,
        .destination = range(readback),
        .extent = .{ 4, 4, 1 },
        .bytes_per_row = pitch,
        .rows_per_image = 4,
    };
    var invalid = base;
    invalid.sample_index = 1;
    try std.testing.expectError(error.BlitSampleCountMismatch, blit.textureToBuffer(context, invalid));
    invalid = base;
    invalid.origin = .{ 1, 0, 0 };
    try std.testing.expectError(error.InvalidBlitRegion, blit.textureToBuffer(context, invalid));
    invalid = base;
    invalid.destination.size = 3;
    try std.testing.expectError(error.KernelRangeOverflow, blit.textureToBuffer(context, invalid));
    invalid = base;
    invalid.destination.offset = std.math.maxInt(u64);
    try std.testing.expectError(error.KernelRangeOverflow, blit.textureToBuffer(context, invalid));
    invalid = base;
    invalid.bytes_per_row = std.math.maxInt(u64);
    try std.testing.expectError(error.KernelRangeOverflow, blit.textureToBuffer(context, invalid));
    invalid = base;
    invalid.source = foreign_view;
    try std.testing.expectError(error.ResourceDeviceMismatch, blit.textureToBuffer(context, invalid));
    try std.testing.expectEqual(users_before, guard.objects.user_reference_count);
    try std.testing.expectEqualSlices(u32, &handles_before, &device.native.?.native_device.handles.counts);
    try std.testing.expectEqual(roots_before, context.pending_uses.roots.count());
    try std.testing.expect(!context.queue.recording_poisoned);
    try std.testing.expect(!batch.recording.needs_submit);
    try expectUnacceptedRoots(device, &guard);
}

const NativeCreateFault = struct {
    device: vk.VkDevice,
    original: std.meta.Child(vk.PFN_vkCreateComputePipelines),
    calls: u32 = 0,
    failures: u32 = 0,

    fn create(
        device: vk.VkDevice,
        cache: vk.VkPipelineCache,
        count: u32,
        infos: [*c]const vk.VkComputePipelineCreateInfo,
        allocation_callbacks: [*c]const vk.VkAllocationCallbacks,
        outputs: [*c]vk.VkPipeline,
    ) callconv(.c) vk.VkResult {
        const self = current_native_fault orelse @panic("native failure boundary absent");
        if (device != self.device) @panic("native failure boundary used another device");
        self.calls += 1;
        if (self.failures == 0) {
            self.failures += 1;
            return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        }
        return self.original(device, cache, count, infos, allocation_callbacks, outputs);
    }
};

threadlocal var current_native_fault: ?*NativeCreateFault = null;

fn exerciseNativeFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const readback = try createReadback(allocator, io, device);
    defer release(allocator, io, device, readback);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    const native_context = device.native.?;
    var cloned_procs = native_context.native_device.procs.*;
    var fault: NativeCreateFault = .{
        .device = native_context.native_device.vk_device,
        .original = cloned_procs.create_compute_pipelines orelse return error.MissingDeviceProc,
    };
    const original_backend = native_context.pipeline_backend;
    cloned_procs.create_compute_pipelines = NativeCreateFault.create;
    native_context.pipeline_backend = dusk.pipeline.pipeline.Backend.fromDeviceProcs(
        native_context.native_device.vk_device,
        &cloned_procs,
    );
    defer native_context.pipeline_backend = original_backend;
    if (current_native_fault != null) return error.NestedNativeFailureBoundary;
    current_native_fault = &fault;
    defer current_native_fault = null;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try batch.fillReadback(io, &guard, readback);
        const users_before = guard.objects.user_reference_count;
        const handles_before = native_context.native_device.handles.counts;
        const store = &native_context.resource_store.?;
        const shaders_before = store.shader_modules.member_count;
        const layouts_before = store.pipeline_layouts.member_count;
        const groups_before = store.bind_group_layouts.member_count;
        const pipelines_before = native_context.pipeline_store.?.queryPipelineCount(&guard);
        try std.testing.expectError(error.OutOfDeviceMemory, blit.textureToBuffer(
            batch.context(io, &guard),
            .{
                .source = view,
                .destination = .{ .owner = readback, .offset = pitch, .size = padded_size - pitch },
                .extent = .{ 4, 4, 1 },
                .bytes_per_row = pitch,
                .rows_per_image = 4,
            },
        ));
        try std.testing.expectEqual(@as(u32, 1), fault.calls);
        try std.testing.expectEqual(@as(u32, 1), fault.failures);
        try std.testing.expectEqual(users_before, guard.objects.user_reference_count);
        try std.testing.expectEqual(shaders_before, store.shader_modules.member_count);
        try std.testing.expectEqual(layouts_before, store.pipeline_layouts.member_count);
        try std.testing.expectEqual(groups_before, store.bind_group_layouts.member_count);
        try std.testing.expectEqual(pipelines_before, native_context.pipeline_store.?.queryPipelineCount(&guard));
        try expectUnacceptedRoots(device, &guard);
        try std.testing.expect(native_context.queue.recording_poisoned);
        var scratch_count: u32 = 0;
        var roots = native_context.recording_uses.?.roots.keyIterator();
        while (roots.next()) |root| {
            if (root.*.kind == .native_buffer and root.*.user_reference_count == 0) scratch_count += 1;
        }
        for (std.enums.values(engine.vulkan_device.HandleKind), 0..) |kind, index| {
            const expected = handles_before[index] +
                if (kind == .buffer or kind == .memory) scratch_count else @as(u32, 0);
            try std.testing.expectEqual(expected, native_context.native_device.handles.counts[index]);
        }
        try std.testing.expect(scratch_count != 0);
    }
    try std.testing.expectError(error.RecordingPoisoned, batch.submit(allocator, io));
    try std.testing.expectEqual(@as(dusk.platform.Serial, 0), batch.lease.lastSubmittedSerial());
}

fn exerciseDepth16(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .depth16_unorm, 3, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .depth_only);
    defer release(allocator, io, device, view);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const output = try createReadback(allocator, io, device);
    defer release(allocator, io, device, output);
    const samples = [_]u16{
        0, 1, 2, 32767, 32768, 65534, 65535, 12345, 54321, 21845, 43690, 32769,
    };
    var input_bytes: [padded_size]u8 = @splat(0xa5);
    for (samples, 0..) |sample, index| {
        const at = 2 + (index / 3) * pitch + (index % 3) * 2;
        std.mem.writeInt(u16, input_bytes[at..][0..2], sample, .little);
    }
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{}, view, 3, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("depth16 attachment release failed");
        try batch.upload(io, &guard, input, &input_bytes);
        try batch.fillReadback(io, &guard, output);
        const context = batch.context(io, &guard);
        try blit.bufferToDepth(context, .{
            .source = range(input),
            .target = destination,
            .format = .depth16_unorm,
            .rectangle = .{ .x = 0, .y = 0, .width = 3, .height = 4 },
            .layout = .{ .offset_bytes = 2, .bytes_per_row = pitch, .rows_per_image = 4 },
        });
        try blit.textureToBuffer(context, .{
            .source = view,
            .destination = .{ .owner = output, .offset = pitch + 2, .size = padded_size - pitch - 2 },
            .extent = .{ 3, 4, 1 },
            .bytes_per_row = pitch,
            .rows_per_image = 4,
        });
        try batch.hostBarrier(output);
        try expectKernel(device, .buffer_to_depth);
        try expectKernel(device, .texture_to_buffer);
        try std.testing.expect(!input.native.getUsage().storage);
        try std.testing.expect(!output.native.getUsage().copy_src);
        try std.testing.expect(!output.native.getUsage().storage);
    }
    const serial = try batch.submit(allocator, io);
    try expectAcceptedRoots(device, io, serial);
    try device.wait(io, serial);
    const bytes = try mapped(device, io, output);
    defer device.unmapBuffer(io, output) catch @panic("depth16 output unmap failed");
    for (samples, 0..) |sample, index| {
        const at = pitch + 2 + (index / 3) * pitch + (index % 3) * 2;
        const observed = std.mem.readInt(u16, bytes[at..][0..2], .little);
        const difference = @as(i32, observed) - @as(i32, sample);
        try std.testing.expect(@abs(difference) <= 1);
        if (sample == 0 or sample == 65535) try std.testing.expectEqual(sample, observed);
    }
    for (bytes, 0..) |byte, index| {
        const row = index / pitch;
        const column = index % pitch;
        if (row >= 1 and row <= 4 and column >= 2 and column < 8) continue;
        try std.testing.expectEqual(sentinel, byte);
    }
}

const ClearFailOptions = struct {
    base: FailOptions,
    saw_partial_upload_failure: *bool,
};

fn exercisePrepareClearFailN() !void {
    var succeeded = false;
    var saw_partial_upload_failure = false;
    const allocation_limit: usize = 4096;
    for (0..allocation_limit) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        try runOnGpuWith(failing.allocator(), exercisePrepareClearRollback, ClearFailOptions{
            .base = .{ .failing = &failing, .offset = offset, .succeeded = &succeeded },
            .saw_partial_upload_failure = &saw_partial_upload_failure,
        });
        if (succeeded) break;
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(saw_partial_upload_failure);
}

fn exercisePrepareClearRollback(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    options: ClearFailOptions,
) !void {
    var images: [2]*engine.texture.Texture = undefined;
    var views: [2]*engine.texture.TextureView = undefined;
    var outputs: [2]*native.Buffer = undefined;
    var image_count: usize = 0;
    var view_count: usize = 0;
    var output_count: usize = 0;
    defer for (images[0..image_count]) |image| release(allocator, io, device, image);
    defer for (views[0..view_count]) |view| release(allocator, io, device, view);
    defer for (outputs[0..output_count]) |output| release(allocator, io, device, output);
    for ([_]api.TextureFormat{ .rgba8_unorm, .rgba8_uint }, 0..) |format, index| {
        images[index] = try createImage(allocator, io, device, format, 4, 4);
        image_count += 1;
        views[index] = try createView(allocator, io, device, images[index], .all);
        view_count += 1;
        outputs[index] = try createReadback(allocator, io, device);
        output_count += 1;
    }
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    var failed = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &views, null, 4, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("split clear attachment release failed");
        var pass_query: engine.render_pass_cache.RenderPassCacheQuery = .{};
        pass_query.setSampleCount(1);
        for (views, 0..) |view, slot| {
            pass_query.setColor(.{
                .index = @intCast(slot),
                .format = view.format,
                .load_op = .clear,
                .store_op = .store,
                .has_resolve_target = false,
                .render_to_single_sampled = false,
            });
        }
        const native_context = device.native.?;
        const pass = try native_context.render_pass_cache.getRenderPass(io, pass_query);
        var frame_query: engine.framebuffer_cache.FramebufferCacheQuery = .{};
        frame_query.key.setRenderPass(.{ .pass_id = pass.unique_id, .width = 4, .height = 4 });
        for (views) |view| {
            try frame_query.addAttachment(.{
                .texture_view_id = @intFromPtr(view),
                .image_view = try view.getHandle(&guard),
            });
        }
        const framebuffer = try native_context.framebuffer_cache.getOrCreate(&frame_query, pass.render_pass);
        var values: [8]?blit.ClearValue = @splat(null);
        values[0] = .{ .float = .{ 31.0 / 255.0, 63.0 / 255.0, 127.0 / 255.0, 1 } };
        values[1] = .{ .uint = .{ 7, 129, 203, 255 } };
        const rectangle: blit.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
        const context = batch.context(io, &guard);
        const users_before = guard.objects.user_reference_count;
        options.base.failing.fail_index = options.base.failing.alloc_index + options.base.offset;
        const attempted = blit.prepareDrawClear(context, .{
            .target = destination,
            .rectangle = rectangle,
            .values = values,
        }, pass.render_pass);
        options.base.failing.fail_index = std.math.maxInt(usize);
        if (attempted) |prepared| {
            if (options.base.failing.has_induced_failure) return error.SwallowedAllocationFailure;
            try std.testing.expect(prepared.draws[0] != null);
            try std.testing.expect(prepared.draws[1] != null);
            try std.testing.expect(prepared.draws[0].?.bind_group == prepared.draws[1].?.bind_group);
            options.base.succeeded.* = true;
            for (views) |view| {
                try view.texture.transitionRenderAttachment(&guard, batch.bufferRecording(), view.range, .{});
                view.texture.setSubresourceContentInitialized(&guard, true, view.range);
            }
            const procs = native_context.native_device.procs;
            const begin = procs.cmd_begin_render_pass orelse return error.MissingDeviceProc;
            const end = procs.cmd_end_render_pass orelse return error.MissingDeviceProc;
            const begin_info: vk.VkRenderPassBeginInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext = null,
                .renderPass = pass.render_pass,
                .framebuffer = framebuffer,
                .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 4, .height = 4 } },
                .clearValueCount = 2,
                .pClearValues = &frame_query.clear_values,
            };
            begin(batch.recording.command_buffer, &begin_info, vk.VK_SUBPASS_CONTENTS_INLINE);
            batch.recording.active_render_pass = pass.render_pass;
            try blit.recordPreparedClear(context, prepared, pass.render_pass, destination, rectangle);
            end(batch.recording.command_buffer);
            batch.recording.active_render_pass = null;
            for (views, outputs) |view, output| {
                try batch.fillReadback(io, &guard, output);
                try batch.copyImage(io, &guard, view, output, 4);
                try batch.hostBarrier(output);
            }
        } else |err| {
            if (err != error.OutOfMemory) return err;
            failed = true;
            try std.testing.expect(options.base.failing.has_induced_failure);
            try std.testing.expectEqual(users_before, guard.objects.user_reference_count);
            // This assertion tests the helper's own poison path. The fixture never poisons it.
            try std.testing.expect(native_context.queue.recording_poisoned);
            try expectUnacceptedRoots(device, &guard);
            var roots = context.pending_uses.roots.keyIterator();
            while (roots.next()) |root| {
                if (root.*.kind == .native_buffer and root.*.user_reference_count == 0) {
                    const buffer: *native.Buffer = @fieldParentPtr("header", root.*);
                    if (buffer.native.is_data_initialized and buffer.native.size == 128 and
                        buffer.native.internal_usage & (api.BufferUsage{ .uniform = true }).toFlags() != 0)
                    {
                        options.saw_partial_upload_failure.* = true;
                    }
                }
            }
        }
    }
    if (failed) return;
    const serial = try batch.submit(allocator, io);
    try expectAcceptedRoots(device, io, serial);
    try device.wait(io, serial);
    const expected = [_][4]u8{ .{ 31, 63, 127, 255 }, .{ 7, 129, 203, 255 } };
    for (outputs, expected) |output, pixel| {
        const bytes = try mapped(device, io, output);
        defer device.unmapBuffer(io, output) catch @panic("split clear output unmap failed");
        for (0..4) |y| for (0..4) |x| {
            const at = pixelOffset(x, y, 4);
            try std.testing.expectEqualSlices(u8, &pixel, bytes[at..][0..4]);
        };
        try expectPadding(bytes, 4, 4, 4);
    }
}

const browser_pixels = [4][4]f32{
    .{ -0.125, 0.2, 0.6, 0.5 }, .{ 0.04, 0.1, 0.3, 0.25 },
    .{ 0.19, -0.08, 0.32, 0 },  .{ 0.9, 0.4, 0.1, 1 },
};
const browser_background = [4]f32{ 0.125, 0.25, 0.375, 0.5 };
const browser_source_curve = [7]f32{ 2, 0.5, 0.1, 0.25, 0.3, 0.02, 0.01 };
const browser_destination_curve = [7]f32{ 0.5, 0.6, 0.05, 0.4, 0.2, 0.03, 0.02 };
const browser_matrix = [9]f32{ 0.8, 0.1, 0, -0.2, 0.9, 0.1, 0.05, -0.1, 1.1 };
const BrowserFloatCase = enum { nonlinear, unpremultiply, premultiply, source_opaque, destination_opaque };

fn exerciseBrowserFloat(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    inline for (std.meta.tags(BrowserFloatCase)) |variant| {
        try browserFloatCase(allocator, io, device, variant);
    }
}

fn browserFloatCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    variant: BrowserFloatCase,
) !void {
    const descriptor: api.descriptors.TextureDescriptorChain = .{
        .size = .{ .width = 6, .height = 6, .depth_or_array_layers = 2 },
        .mip_level_count = 2,
        .format = .rgba32_float,
        .usage = .{ .copy_src = true, .copy_dst = true, .render_attachment = true, .texture_binding = true },
    };
    const source_image = try device.createTexture(allocator, io, descriptor);
    var source_image_live = true;
    defer if (source_image_live) release(allocator, io, device, source_image);
    const destination_image = try device.createTexture(allocator, io, descriptor);
    defer release(allocator, io, device, destination_image);
    const source = try device.createTextureView(allocator, io, .{
        .texture = source_image,
        .descriptor = .{
            .format = .rgba32_float,
            .dimension = ._2d_array,
            .base_mip_level = 1,
            .mip_level_count = 1,
            .base_array_layer = 1,
            .array_layer_count = 1,
        },
    });
    var source_live = true;
    defer if (source_live) release(allocator, io, device, source);
    const source_attachment = try device.createTextureView(allocator, io, .{
        .texture = source_image,
        .descriptor = .{
            .format = .rgba32_float,
            .dimension = ._2d,
            .base_mip_level = 1,
            .mip_level_count = 1,
            .base_array_layer = 1,
            .array_layer_count = 1,
        },
    });
    var source_attachment_live = true;
    defer if (source_attachment_live) release(allocator, io, device, source_attachment);
    var destinations: [4]*engine.texture.TextureView = undefined;
    var outputs: [4]*native.Buffer = undefined;
    var view_count: usize = 0;
    var output_count: usize = 0;
    defer for (destinations[0..view_count]) |view| release(allocator, io, device, view);
    defer for (outputs[0..output_count]) |output| release(allocator, io, device, output);
    for (0..4) |index| {
        destinations[index] = try device.createTextureView(allocator, io, .{
            .texture = destination_image,
            .descriptor = .{
                .format = .rgba32_float,
                .dimension = ._2d,
                .base_mip_level = @intCast(index % 2),
                .mip_level_count = 1,
                .base_array_layer = @intCast(index / 2),
                .array_layer_count = 1,
            },
        });
        view_count += 1;
        outputs[index] = try createReadback(allocator, io, device);
        output_count += 1;
    }
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    var bytes: [padded_size]u8 = @splat(0x51);
    for (browser_pixels, 0..) |pixel, index| for (pixel, 0..) |channel, component| {
        const at = pitch + (index / 2) * pitch + (index % 2) * 16 + component * 4;
        std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(channel), .little);
    };
    {
        var batch = try Batch.init(allocator, io, device);
        defer batch.deinit(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try batch.upload(io, &guard, input, &bytes);
            const source_target = try target(allocator, io, device, &guard, &.{source_attachment}, null, 3, 3);
            defer source_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("browser source attachment release failed");
            var clear: [8]?blit.ClearValue = @splat(null);
            clear[0] = .{ .float = browser_background };
            try blit.drawClear(batch.context(io, &guard), .{
                .target = source_target,
                .rectangle = .{ .x = 0, .y = 0, .width = 3, .height = 3 },
                .values = clear,
            });
            try blit.bufferToColor(batch.context(io, &guard), .{
                .source = range(input),
                .target = source_target,
                .rectangle = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
                .layout = .{ .offset_bytes = pitch, .bytes_per_row = pitch, .rows_per_image = 2 },
                .format = .rgba32_float,
            });
            for (destinations, 0..) |view, index| {
                const size: u32 = if (index % 2 == 0) 6 else 3;
                const destination = try target(allocator, io, device, &guard, &.{view}, null, size, size);
                defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("browser destination attachment release failed");
                try blit.drawClear(batch.context(io, &guard), .{
                    .target = destination,
                    .rectangle = .{ .x = 0, .y = 0, .width = size, .height = size },
                    .values = clear,
                });
            }
        }
        const serial = try batch.submit(allocator, io);
        try expectAcceptedRoots(device, io, serial);
        try device.wait(io, serial);
    }
    var encoder = dusk.command.command_encoder.CommandEncoder.init(allocator, device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    var source_curve = browser_source_curve;
    var destination_curve = browser_destination_curve;
    var matrix = browser_matrix;
    try device.copyTextureForBrowser(allocator, io, &encoder, .{
        .source = source,
        .destination = destinations[3],
        .source_origin = .{ .x = 1, .y = 1 },
        .destination_origin = .{ .x = 1, .y = 1 },
        .copy_size = .{ .width = 2, .height = 2 },
        .browser = .{
            .flip_y = variant == .nonlinear or variant == .premultiply,
            .needs_color_space_conversion = variant == .nonlinear,
            .src_alpha_mode = switch (variant) {
                .nonlinear, .unpremultiply, .destination_opaque => .premultiplied,
                .premultiply => .unpremultiplied,
                .source_opaque => .opaque_,
            },
            .dst_alpha_mode = switch (variant) {
                .unpremultiply => .unpremultiplied,
                .destination_opaque => .opaque_,
                else => .premultiplied,
            },
            .src_transfer_function_parameters = if (variant == .nonlinear) &source_curve else null,
            .dst_transfer_function_parameters = if (variant == .nonlinear) &destination_curve else null,
            .conversion_matrix = if (variant == .nonlinear) &matrix else null,
        },
    });
    // Public recording must own the finite coefficient vectors, not these caller slices.
    source_curve = @splat(9);
    destination_curve = @splat(9);
    matrix = @splat(9);
    var finished = try encoder.finish();
    var finished_live = true;
    defer {
        if (finished_live) {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            finished.deinit(allocator, io, &guard);
        }
    }
    const serial = try device.submit(allocator, io, &finished);
    try std.testing.expect(serial != 0);
    // Accepted queue owners must preserve the source without caller or Finished owners.
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    finished_live = false;
    release(allocator, io, device, source);
    source_live = false;
    release(allocator, io, device, source_attachment);
    source_attachment_live = false;
    release(allocator, io, device, source_image);
    source_image_live = false;
    try device.wait(io, serial);
    {
        var batch = try Batch.init(allocator, io, device);
        defer batch.deinit(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try expectKernel(device, .color_to_color);
            for (destinations, outputs) |view, output| {
                try batch.fillReadback(io, &guard, output);
                try batch.copyImage(io, &guard, view, output, 16);
                try batch.hostBarrier(output);
            }
        }
        const read_serial = try batch.submit(allocator, io);
        try device.wait(io, read_serial);
    }
    for (outputs, 0..) |output, index| {
        const result = try mapped(device, io, output);
        defer device.unmapBuffer(io, output) catch @panic("browser float output unmap failed");
        const size: usize = if (index % 2 == 0) 6 else 3;
        for (0..size) |y| for (0..size) |x| {
            const expected = if (index == 3 and x >= 1 and y >= 1)
                browserExpected(variant, (y - 1) * 2 + x - 1)
            else
                browser_background;
            try expectFloatPixel(result, x, y, expected, 0.00002);
        };
        try expectPadding(result, size, size, 16);
    }
}

// Independent double-precision oracle for this finite fixture, never used to produce GPU output.
fn fixtureTransfer(value: f64, coefficients: *const [7]f32) f64 {
    if (value == 0) return 0;
    const magnitude = @abs(value);
    const transformed = if (magnitude < coefficients[4])
        @as(f64, coefficients[3]) * magnitude + coefficients[6]
    else
        std.math.pow(f64, @as(f64, coefficients[1]) * magnitude + coefficients[2], coefficients[0]) +
            coefficients[5];
    return if (value < 0) -transformed else transformed;
}

fn browserExpected(variant: BrowserFloatCase, index: usize) [4]f32 {
    const selected = if (variant == .nonlinear or variant == .premultiply)
        (1 - index / 2) * 2 + index % 2
    else
        index;
    const source = browser_pixels[selected];
    var rgb = [3]f64{ source[0], source[1], source[2] };
    if ((variant == .nonlinear or variant == .unpremultiply) and source[3] != 0) {
        for (&rgb) |*channel| channel.* /= source[3];
    }
    if (variant == .nonlinear) {
        for (&rgb) |*channel| channel.* = fixtureTransfer(channel.*, &browser_source_curve);
        const transformed = [3]f64{
            rgb[0] * browser_matrix[0] + rgb[1] * browser_matrix[3] + rgb[2] * browser_matrix[6],
            rgb[0] * browser_matrix[1] + rgb[1] * browser_matrix[4] + rgb[2] * browser_matrix[7],
            rgb[0] * browser_matrix[2] + rgb[1] * browser_matrix[5] + rgb[2] * browser_matrix[8],
        };
        for (&rgb, transformed) |*channel, value| channel.* = fixtureTransfer(value, &browser_destination_curve);
    }
    if (variant == .nonlinear or variant == .premultiply) {
        for (&rgb) |*channel| channel.* *= source[3];
    }
    return .{ @floatCast(rgb[0]), @floatCast(rgb[1]), @floatCast(rgb[2]), if (variant == .source_opaque) 1 else source[3] };
}

fn expectFloatPixel(bytes: []const u8, x: usize, y: usize, expected: [4]f32, tolerance: f32) !void {
    const at = pixelOffset(x, y, 16);
    for (expected, 0..) |value, component| {
        const observed: f32 = @bitCast(std.mem.readInt(u32, bytes[at + component * 4 ..][0..4], .little));
        try std.testing.expectApproxEqAbs(value, observed, tolerance);
    }
}

fn exerciseBrowserSrgb(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    for ([_]api.TextureFormat{ .rgba8_unorm_srgb, .bgra8_unorm_srgb }) |format| {
        try browserSrgbCase(allocator, io, device, format);
    }
}

fn browserSrgbCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    format: api.TextureFormat,
) !void {
    const source_image = try createImage(allocator, io, device, .rgba8_unorm, 2, 2);
    var source_image_live = true;
    defer if (source_image_live) release(allocator, io, device, source_image);
    const source = try createView(allocator, io, device, source_image, .all);
    var source_live = true;
    defer if (source_live) release(allocator, io, device, source);
    const destination_image = try createImage(allocator, io, device, format, 4, 4);
    defer release(allocator, io, device, destination_image);
    const destination = try createView(allocator, io, device, destination_image, .all);
    defer release(allocator, io, device, destination);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const output = try createReadback(allocator, io, device);
    defer release(allocator, io, device, output);
    const pixels = [4][4]u8{
        .{ 17, 68, 153, 255 }, .{ 32, 128, 224, 129 },
        .{ 240, 96, 48, 0 },   .{ 192, 64, 128, 203 },
    };
    var bytes: [padded_size]u8 = @splat(0x71);
    for (pixels, 0..) |pixel, index| {
        @memcpy(bytes[(index / 2) * pitch + (index % 2) * 4 ..][0..4], &pixel);
    }
    {
        var batch = try Batch.init(allocator, io, device);
        defer batch.deinit(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try batch.upload(io, &guard, input, &bytes);
            const source_target = try target(allocator, io, device, &guard, &.{source}, null, 2, 2);
            defer source_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("sRGB source attachment release failed");
            try blit.bufferToColor(batch.context(io, &guard), .{
                .source = range(input),
                .target = source_target,
                .rectangle = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
                .layout = .{ .bytes_per_row = pitch, .rows_per_image = 2 },
                .format = .rgba8_unorm,
            });
            const destination_target = try target(allocator, io, device, &guard, &.{destination}, null, 4, 4);
            defer destination_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("sRGB destination attachment release failed");
            var clear: [8]?blit.ClearValue = @splat(null);
            clear[0] = .{ .float = .{ 0, 0, 0, 1 } };
            try blit.drawClear(batch.context(io, &guard), .{
                .target = destination_target,
                .rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
                .values = clear,
            });
        }
        const serial = try batch.submit(allocator, io);
        try device.wait(io, serial);
    }
    var encoder = dusk.command.command_encoder.CommandEncoder.init(allocator, device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    try device.copyTextureForBrowser(allocator, io, &encoder, .{
        .source = source,
        .destination = destination,
        .source_origin = .{ .x = 0, .y = 0 },
        .destination_origin = .{ .x = 1, .y = 1 },
        .copy_size = .{ .width = 2, .height = 2 },
        .browser = .{ .flip_y = true },
    });
    var finished = try encoder.finish();
    var finished_live = true;
    defer {
        if (finished_live) {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            finished.deinit(allocator, io, &guard);
        }
    }
    const serial = try device.submit(allocator, io, &finished);
    try std.testing.expect(serial != 0);
    // Accepted queue owners must preserve the source without caller or Finished owners.
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    finished_live = false;
    release(allocator, io, device, source);
    source_live = false;
    release(allocator, io, device, source_image);
    source_image_live = false;
    try device.wait(io, serial);
    {
        var batch = try Batch.init(allocator, io, device);
        defer batch.deinit(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try expectKernel(device, .color_to_color);
            try batch.fillReadback(io, &guard, output);
            try batch.copyImage(io, &guard, destination, output, 4);
            try batch.hostBarrier(output);
        }
        const read_serial = try batch.submit(allocator, io);
        try device.wait(io, read_serial);
    }
    const result = try mapped(device, io, output);
    defer device.unmapBuffer(io, output) catch @panic("sRGB browser output unmap failed");
    for (0..4) |y| for (0..4) |x| {
        var expected: [4]u8 = .{ 0, 0, 0, 255 };
        if (x >= 1 and x <= 2 and y >= 1 and y <= 2) {
            expected = pixels[(2 - y) * 2 + x - 1];
            if (format == .bgra8_unorm_srgb) std.mem.swap(u8, &expected[0], &expected[2]);
        }
        const at = pixelOffset(x, y, 4);
        try std.testing.expectEqualSlices(u8, &expected, result[at..][0..4]);
    };
    try expectPadding(result, 4, 4, 4);
}

fn exerciseColorFiltering(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const source_image = try createImage(allocator, io, device, .rgba8_unorm, 2, 2);
    defer release(allocator, io, device, source_image);
    const source = try createView(allocator, io, device, source_image, .all);
    defer release(allocator, io, device, source);
    const destination_image = try createImage(allocator, io, device, .rgba32_float, 3, 3);
    defer release(allocator, io, device, destination_image);
    const destination = try createView(allocator, io, device, destination_image, .all);
    defer release(allocator, io, device, destination);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const pixels = [4][4]u8{
        .{ 255, 0, 32, 255 }, .{ 64, 128, 0, 128 },
        .{ 0, 64, 192, 64 },  .{ 128, 255, 64, 0 },
    };
    const nonconstant_channels = comptime channels: {
        var varying: [4]bool = @splat(false);
        // Destination R/B are source B/R because the requested blit swizzles them.
        for ([_]usize{ 2, 1, 0, 3 }, 0..) |source_component, destination_component| {
            for (pixels[1..]) |pixel| {
                varying[destination_component] = varying[destination_component] or
                    pixel[source_component] != pixels[0][source_component];
            }
        }
        break :channels varying;
    };
    var bytes: [padded_size]u8 = @splat(0x61);
    for (pixels, 0..) |pixel, index| {
        @memcpy(bytes[(index / 2) * pitch + (index % 2) * 4 ..][0..4], &pixel);
    }
    for ([_]api.FilterMode{ .linear, .nearest }) |filter| {
        const output = try createReadback(allocator, io, device);
        defer release(allocator, io, device, output);
        var batch = try Batch.init(allocator, io, device);
        defer batch.deinit(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            const source_target = try target(allocator, io, device, &guard, &.{source}, null, 2, 2);
            defer source_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("filter source attachment release failed");
            const destination_target = try target(allocator, io, device, &guard, &.{destination}, null, 3, 3);
            defer destination_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("filter destination attachment release failed");
            try batch.upload(io, &guard, input, &bytes);
            try blit.bufferToColor(batch.context(io, &guard), .{
                .source = range(input),
                .target = source_target,
                .rectangle = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
                .layout = .{ .bytes_per_row = pitch, .rows_per_image = 2 },
                .format = .rgba8_unorm,
            });
            var clear: [8]?blit.ClearValue = @splat(null);
            clear[0] = .{ .float = browser_background };
            try blit.drawClear(batch.context(io, &guard), .{
                .target = destination_target,
                .rectangle = .{ .x = 0, .y = 0, .width = 3, .height = 3 },
                .values = clear,
            });
            try blit.colorToColor(batch.context(io, &guard), .{
                .source = source,
                .target = destination_target,
                .source_rectangle = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
                .rectangle = .{ .x = 1, .y = 1, .width = 1, .height = 1 },
                .filter = filter,
                .swizzle_red_blue = true,
            });
            try batch.fillReadback(io, &guard, output);
            try batch.copyImage(io, &guard, destination, output, 16);
            try batch.hostBarrier(output);
            try expectKernel(device, .color_to_color);
        }
        const serial = try batch.submit(allocator, io);
        try expectAcceptedRoots(device, io, serial);
        try device.wait(io, serial);
        const result = try mapped(device, io, output);
        defer device.unmapBuffer(io, output) catch @panic("filtered color output unmap failed");
        const filtered_tolerance: f32 = if (filter == .linear) tolerance: {
            const fraction_bits = device.native.?.native_device.physical.properties.limits.subTexelPrecisionBits;
            try std.testing.expect(fraction_bits >= 4);
            // The exact center fractions 0.5 lie on every conformant p-bit grid:
            // https://github.com/KhronosGroup/Vulkan-Docs/blob/v1.4.313/chapters/limits.adoc#L505-L511
            // Coordinate quantization therefore contributes zero for this fixture.
            // Reuse native_sampler.zig's one-source-quantum acceptance budget.
            // Texel-format-limited precision is permitted; this is a test-quality
            // budget, not a mandated post-filter rounding rule or maximum error:
            // https://github.com/KhronosGroup/Vulkan-Docs/blob/v1.4.313/chapters/fundamentals.adoc#L1507-L1544
            break :tolerance 1.0 / 255.0 + 0.00002;
        } else 0.00002;
        const filtered: [4]f32 = if (filter == .linear)
            .{ 72.0 / 255.0, 111.75 / 255.0, 111.75 / 255.0, 111.75 / 255.0 }
        else
            .{ 64.0 / 255.0, 1, 128.0 / 255.0, 0 };
        for (0..3) |y| for (0..3) |x| {
            if (x == 1 and y == 1) {
                const at = pixelOffset(x, y, 16);
                for (filtered, 0..) |expected, component| {
                    const observed: f32 = @bitCast(std.mem.readInt(u32, result[at + component * 4 ..][0..4], .little));
                    try std.testing.expectApproxEqAbs(expected, observed, if (nonconstant_channels[component]) filtered_tolerance else 0.00002);
                }
            } else {
                try expectFloatPixel(result, x, y, browser_background, 0.00002);
            }
        };
        try expectPadding(result, 3, 3, 16);
    }
}

fn exerciseAliasedColor(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const input = try device.createBuffer(allocator, io, .{
        .size = padded_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer release(allocator, io, device, input);
    const output = try createReadback(allocator, io, device);
    defer release(allocator, io, device, output);
    var original: [16][4]u8 = undefined;
    var source_bytes: [padded_size]u8 = @splat(0x61);
    for (0..4) |y| for (0..4) |x| {
        original[y * 4 + x] = .{
            @intCast(16 + x * 32 + y * 24), @intCast(32 + x * 16 + y * 40),
            @intCast(48 + x * 40 + y * 8),  @intCast(64 + x * 16 + y * 16),
        };
        @memcpy(source_bytes[y * pitch + x * 4 ..][0..4], &original[y * 4 + x]);
    };
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const destination = try target(allocator, io, device, &guard, &.{view}, null, 4, 4);
        defer destination.attachments.header.releaseUserLocked(&guard, io) catch @panic("aliased color attachment release failed");
        const context = batch.context(io, &guard);
        try batch.upload(io, &guard, input, &source_bytes);
        try blit.bufferToColor(context, .{
            .source = range(input),
            .target = destination,
            .rectangle = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .layout = .{ .bytes_per_row = pitch, .rows_per_image = 4 },
            .format = .rgba8_unorm,
        });
        try blit.colorToColor(context, .{
            .source = view,
            .target = destination,
            .source_rectangle = .{ .x = 0, .y = 0, .width = 3, .height = 3 },
            .rectangle = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
            .filter = .linear,
            .swizzle_red_blue = true,
        });
        var staged_pipeline_found = false;
        for (device.native.?.kernel_cache.?.entries) |entry| {
            if (entry) |value| {
                if (value.key.id == .color_to_color and value.key.source_dimension == .undefined_ and
                    value.key.storage_format == .rgba32_float)
                {
                    try std.testing.expect(value.pipeline.native.vk_pipeline != null);
                    staged_pipeline_found = true;
                }
            }
        }
        try std.testing.expect(staged_pipeline_found);
        try expectKernel(device, .texture_to_buffer);
        try batch.fillReadback(io, &guard, output);
        try batch.copyImage(io, &guard, view, output, 4);
        try batch.hostBarrier(output);
    }
    const serial = try batch.submit(allocator, io);
    try expectAcceptedRoots(device, io, serial);
    try device.wait(io, serial);
    const result = try mapped(device, io, output);
    defer device.unmapBuffer(io, output) catch @panic("aliased color output unmap failed");
    for (0..4) |y| for (0..4) |x| {
        var expected = original[y * 4 + x];
        if (x >= 1 and x <= 2 and y >= 1 and y <= 2) {
            // 3-to-2 scaling samples original texel-space positions 0.25 and 1.75.
            const sx: f64 = if (x == 1) 0.25 else 1.75;
            const sy: f64 = if (y == 1) 0.25 else 1.75;
            expected = originalBilinear(&original, sx, sy);
            std.mem.swap(u8, &expected[0], &expected[2]);
        }
        const at = pixelOffset(x, y, 4);
        try std.testing.expectEqualSlices(u8, &expected, result[at..][0..4]);
    };
    try expectPadding(result, 4, 4, 4);
}

fn originalBilinear(original: *const [16][4]u8, x: f64, y: f64) [4]u8 {
    const left: usize = @intFromFloat(@floor(x));
    const top: usize = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    var result: [4]u8 = undefined;
    for (0..4) |component| {
        const upper = @as(f64, @floatFromInt(original[top * 4 + left][component])) * (1 - fx) +
            @as(f64, @floatFromInt(original[top * 4 + left + 1][component])) * fx;
        const lower = @as(f64, @floatFromInt(original[(top + 1) * 4 + left][component])) * (1 - fx) +
            @as(f64, @floatFromInt(original[(top + 1) * 4 + left + 1][component])) * fx;
        result[component] = @intFromFloat(@round(upper * (1 - fy) + lower * fy));
    }
    return result;
}

fn exerciseSparseClear(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_uint, 3, 3);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    const output = try createReadback(allocator, io, device);
    defer release(allocator, io, device, output);
    const pixel: [4]u8 = .{ 7, 129, 203, 255 };
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        var value: dusk.command.attachment_state.AttachmentState = .{};
        value.sample_count = 1;
        value.color_attachments_set = @as(u8, 1) << 7;
        value.color_formats[7] = @backingInt(api.TextureFormat.rgba8_uint);
        const native_context = device.native.?;
        const attachments = try engine.native_attachment_store.create(
            allocator,
            io,
            &guard,
            &device.core.arena,
            &native_context.resource_store.?,
            value,
        );
        defer attachments.header.releaseUserLocked(&guard, io) catch @panic("sparse attachment release failed");
        var colors: [8]?*engine.texture.TextureView = @splat(null);
        colors[7] = view;
        const destination: blit.Target = .{
            .attachments = attachments,
            .colors = colors,
            .render_pass_cache = &native_context.render_pass_cache,
            .framebuffer_cache = &native_context.framebuffer_cache,
            .width = 3,
            .height = 3,
        };
        var values: [8]?blit.ClearValue = @splat(null);
        values[7] = .{ .uint = .{ pixel[0], pixel[1], pixel[2], pixel[3] } };
        try blit.drawClear(batch.context(io, &guard), .{
            .target = destination,
            .rectangle = .{ .x = 0, .y = 0, .width = 3, .height = 3 },
            .values = values,
        });
        var slot_seven_found = false;
        for (native_context.kernel_cache.?.entries) |entry| {
            if (entry) |cached| {
                if (cached.key.id == .clear_color and cached.key.color_write_slots == 128) {
                    try std.testing.expect(cached.pipeline.native.vk_pipeline != null);
                    try std.testing.expectEqual(@as(u8, 128), cached.key.attachments.?.value.color_attachments_set);
                    for (cached.key.attachments.?.value.color_formats[0..7]) |format| {
                        try std.testing.expectEqual(@backingInt(api.TextureFormat.undefined_), format);
                    }
                    slot_seven_found = true;
                }
            }
        }
        try std.testing.expect(slot_seven_found);
        try batch.fillReadback(io, &guard, output);
        try batch.copyImage(io, &guard, view, output, 4);
        try batch.hostBarrier(output);
    }
    const serial = try batch.submit(allocator, io);
    try expectAcceptedRoots(device, io, serial);
    try device.wait(io, serial);
    const result = try mapped(device, io, output);
    defer device.unmapBuffer(io, output) catch @panic("sparse clear output unmap failed");
    for (0..3) |y| for (0..3) |x| {
        const at = pixelOffset(x, y, 4);
        try std.testing.expectEqualSlices(u8, &pixel, result[at..][0..4]);
    };
    try expectPadding(result, 3, 3, 4);
}

fn exerciseSignedPackEndpoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    failing: *std.testing.FailingAllocator,
) !void {
    const image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .all);
    defer release(allocator, io, device, view);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const context = batch.context(io, &guard);
    const request: blit.PackTexture = .{
        .source = view,
        .origin = .{ std.math.maxInt(i32), 0, 0 },
        .extent = .{ 2, 1, 1 },
    };
    const allocations_before = failing.alloc_index;
    const roots_before = context.pending_uses.roots.count();
    const users_before = guard.objects.user_reference_count;
    const handles_before = device.native.?.native_device.handles.counts;
    const temporary_count = device.native.?.queue.temporary_buffers.items.len;
    const command_buffer_before = batch.recording.command_buffer;
    const needs_submit_before = batch.recording.needs_submit;
    const active_pass_before = batch.recording.active_render_pass;
    const poisoned_before = device.native.?.queue.recording_poisoned;
    // Neither consumer may allocate or lower/retain the real source before rejecting its endpoint.
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidBlitRegion, blit.validatePack(context, request));
    try std.testing.expectError(error.InvalidBlitRegion, blit.packTexture(context, request));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(allocations_before, failing.alloc_index);
    try std.testing.expectEqual(roots_before, context.pending_uses.roots.count());
    try std.testing.expectEqual(users_before, guard.objects.user_reference_count);
    try std.testing.expectEqualDeep(handles_before, device.native.?.native_device.handles.counts);
    try std.testing.expectEqual(temporary_count, device.native.?.queue.temporary_buffers.items.len);
    try std.testing.expectEqual(command_buffer_before, batch.recording.command_buffer);
    try std.testing.expectEqual(needs_submit_before, batch.recording.needs_submit);
    try std.testing.expectEqual(active_pass_before, batch.recording.active_render_pass);
    try std.testing.expectEqual(poisoned_before, device.native.?.queue.recording_poisoned);
    for (device.native.?.kernel_cache.?.entries) |entry| try std.testing.expect(entry == null);
    try expectUnacceptedRoots(device, &guard);
}

fn exerciseSignedRenderEndpoints(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    failing: *std.testing.FailingAllocator,
) !void {
    const color_image = try createImage(allocator, io, device, .rgba8_unorm, 4, 4);
    defer release(allocator, io, device, color_image);
    const color_view = try createView(allocator, io, device, color_image, .all);
    defer release(allocator, io, device, color_view);
    const depth_image = try createImage(allocator, io, device, .depth32_float, 4, 4);
    defer release(allocator, io, device, depth_image);
    const depth_view = try createView(allocator, io, device, depth_image, .depth_only);
    defer release(allocator, io, device, depth_view);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const color_target = try target(allocator, io, device, &guard, &.{color_view}, null, 4, 4);
    defer color_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("signed color attachment release failed");
    const depth_target = try target(allocator, io, device, &guard, &.{}, depth_view, 4, 4);
    defer depth_target.attachments.header.releaseUserLocked(&guard, io) catch @panic("signed depth attachment release failed");
    const context = batch.context(io, &guard);
    const invalid_rectangle: blit.Rect = .{
        .x = std.math.maxInt(i32),
        .y = 0,
        .width = 2,
        .height = 1,
    };
    const small_rectangle: blit.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const invalid_layer: u32 = @as(u32, std.math.maxInt(i32)) + 1;
    var color: blit.ColorCopyOptions = .{
        .source = color_view,
        .target = color_target,
        .source_rectangle = invalid_rectangle,
        .rectangle = small_rectangle,
    };
    var depth: blit.DepthCopyOptions = .{
        .source = depth_view,
        .target = depth_target,
        .source_rectangle = invalid_rectangle,
        .rectangle = small_rectangle,
    };
    const allocations_before = failing.alloc_index;
    const roots_before = context.pending_uses.roots.count();
    const users_before = guard.objects.user_reference_count;
    const handles_before = device.native.?.native_device.handles.counts;
    const temporary_count = device.native.?.queue.temporary_buffers.items.len;
    const command_buffer_before = batch.recording.command_buffer;
    const needs_submit_before = batch.recording.needs_submit;
    const active_pass_before = batch.recording.active_render_pass;
    const poisoned_before = device.native.?.queue.recording_poisoned;
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidBlitRegion, blit.colorToColor(context, color));
    try std.testing.expectError(error.InvalidBlitRegion, blit.depthToDepth(context, depth));
    color.source_rectangle = small_rectangle;
    color.source_layer = invalid_layer;
    depth.source_rectangle = small_rectangle;
    depth.source_layer = invalid_layer;
    try std.testing.expectError(error.InvalidBlitRegion, blit.colorToColor(context, color));
    try std.testing.expectError(error.InvalidBlitRegion, blit.depthToDepth(context, depth));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(allocations_before, failing.alloc_index);
    try std.testing.expectEqual(roots_before, context.pending_uses.roots.count());
    try std.testing.expectEqual(users_before, guard.objects.user_reference_count);
    try std.testing.expectEqualDeep(handles_before, device.native.?.native_device.handles.counts);
    try std.testing.expectEqual(temporary_count, device.native.?.queue.temporary_buffers.items.len);
    try std.testing.expectEqual(command_buffer_before, batch.recording.command_buffer);
    try std.testing.expectEqual(needs_submit_before, batch.recording.needs_submit);
    try std.testing.expectEqual(active_pass_before, batch.recording.active_render_pass);
    try std.testing.expectEqual(poisoned_before, device.native.?.queue.recording_poisoned);
    for (device.native.?.kernel_cache.?.entries) |entry| try std.testing.expect(entry == null);
    try expectUnacceptedRoots(device, &guard);
}

fn exerciseMultisampleDepth(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *engine.Device,
    _: void,
) !void {
    const native_device = device.native.?.native_device;
    const query = native_device.instance.procs.get_physical_device_image_format_properties orelse return error.MissingInstanceProc;
    // Query the exact D32 format, optimal tiling, usage and flags used by native creation.
    // Only actual physical format/sample unavailability can skip this optional combination.
    var properties: vk.VkImageFormatProperties = undefined;
    const result = query(native_device.physical.handle, vk.VK_FORMAT_D32_SFLOAT, vk.VK_IMAGE_TYPE_2D, vk.VK_IMAGE_TILING_OPTIMAL, vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, 0, &properties);
    if (result == vk.VK_ERROR_FORMAT_NOT_SUPPORTED) return error.SkipZigTest;
    try std.testing.expectEqual(vk.VK_SUCCESS, result);
    if (properties.sampleCounts & vk.VK_SAMPLE_COUNT_4_BIT == 0) return error.SkipZigTest;
    try std.testing.expect(properties.maxExtent.width >= 4 and properties.maxExtent.height >= 4);
    try std.testing.expect(properties.maxMipLevels >= 1 and properties.maxArrayLayers >= 1);
    const image = try device.createTexture(allocator, io, .{
        .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
        .sample_count = 4,
        .format = .depth32_float,
        .usage = .{ .texture_binding = true, .render_attachment = true },
    });
    defer release(allocator, io, device, image);
    const view = try createView(allocator, io, device, image, .depth_only);
    defer release(allocator, io, device, view);
    var outputs: [4]*native.Buffer = undefined;
    var output_count: usize = 0;
    defer for (outputs[0..output_count]) |output| release(allocator, io, device, output);
    for (&outputs) |*output| {
        output.* = try createReadback(allocator, io, device);
        output_count += 1;
    }
    // Load-op CLEAR initializes every real sample. Buffer-to-depth stays strictly single-sample.
    var encoder = dusk.command.command_encoder.CommandEncoder.init(allocator, device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }
    var pass = try device.beginRenderPass(allocator, io, &encoder, .{
        .depth_stencil_attachment = .{
            .view = view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .clear_depth = 0.625,
        },
        .width = 4,
        .height = 4,
    });
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        pass.deinit(io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try pass.end(io, &guard);
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }
    const clear_serial = try device.submit(allocator, io, &finished);
    try std.testing.expect(clear_serial != 0);
    try device.wait(io, clear_serial);
    var batch = try Batch.init(allocator, io, device);
    defer batch.deinit(io);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        const context = batch.context(io, &guard);
        for (outputs, 0..) |output, sample_index| {
            try batch.fillReadback(io, &guard, output);
            try blit.textureToBuffer(context, .{
                .source = view,
                .destination = .{
                    .owner = output,
                    .offset = pitch,
                    .size = padded_size - pitch,
                },
                .extent = .{ 4, 4, 1 },
                .sample_index = @intCast(sample_index),
                .bytes_per_row = pitch,
                .rows_per_image = 4,
            });
            try batch.hostBarrier(output);
        }
        var depth_ms_pipeline_found = false;
        for (device.native.?.kernel_cache.?.entries) |entry| {
            if (entry) |cached| {
                if (cached.key.id == .texture_to_buffer and cached.key.source_format == .depth32_float and
                    cached.key.source_multisampled and cached.key.source_dimension == ._2d)
                {
                    try std.testing.expect(cached.pipeline.native.vk_pipeline != null);
                    try std.testing.expect(cached.pipeline.layout.groups.len != 0);
                    var depth_slot_found = false;
                    for (cached.pipeline.layout.groups[0].internal.entries) |binding| {
                        if (binding.layout == .sampled_texture) {
                            const slot = binding.layout.sampled_texture;
                            try std.testing.expect(slot.internal and slot.depth_view and slot.multisampled);
                            try std.testing.expect(slot.sample_type == .float_unfilterable);
                            try std.testing.expect(slot.view_dimension == .two_d);
                            depth_slot_found = true;
                        }
                    }
                    try std.testing.expect(depth_slot_found);
                    depth_ms_pipeline_found = true;
                }
            }
        }
        try std.testing.expect(depth_ms_pipeline_found);
    }
    const pack_serial = try batch.submit(allocator, io);
    try std.testing.expect(pack_serial > clear_serial);
    try expectAcceptedRoots(device, io, pack_serial);
    try device.wait(io, pack_serial);
    const expected: u32 = @bitCast(@as(f32, 0.625));
    for (outputs) |output| {
        const bytes = try mapped(device, io, output);
        defer device.unmapBuffer(io, output) catch @panic("multisample depth output unmap failed");
        for (0..4) |y| for (0..4) |x| {
            const at = pixelOffset(x, y, 4);
            try std.testing.expectEqual(expected, std.mem.readInt(u32, bytes[at..][0..4], .little));
        };
        try expectPadding(bytes, 4, 4, 4);
    }
}
