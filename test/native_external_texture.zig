//! Real external-texture owners, immutable metadata and native shader consumers.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const external = engine.external_texture;
const kernels = engine.native_kernels;
const definitions = engine.native_kernel_definitions;
const native = engine.native_resources;
const BrowserOptions = @FieldType(external.BrowserGeometry, "options");
const BrowserAlphaMode = @FieldType(BrowserOptions, "src_alpha_mode");
const vk = dusk.platform.vulkan_bindings;
const Encoder = dusk.command.command_encoder.CommandEncoder;
const Finished = dusk.command.encoding_context.Finished;
const t = std.testing;
const allocator = t.allocator;
const extent = 4;
const pitch = 256;
const readback_size = extent * pitch;
const sentinel = 0xa5;
const identity_transfer = [7]f32{ 1, 1, 0, 1, 0, 0, 0 };
const identity_gamut = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
const yuv_matrix = [12]f32{ 1, 0, 1.402, -0.701, 1, -0.344136, -0.714136, 0.529136, 1, 1.772, 0, -0.886 };
const color_range = engine.texture.SubresourceRange{
    .aspects = .{ .color = 1 },
    .base_array_layer = 0,
    .layer_count = 1,
    .base_mip_level = 0,
    .level_count = 1,
};

const Fixture = struct {
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    threaded: std.Io.Threaded = undefined,
    owner_allocator: std.mem.Allocator = allocator,

    fn init(self: *Fixture, owner_allocator: std.mem.Allocator) !void {
        self.owner_allocator = owner_allocator;
        self.threaded = .init(allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(owner_allocator, io) catch @panic("instance rollback");
        self.adapters = try self.instance.enumerateAdapters(owner_allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(owner_allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("external texture reported an uncaptured device error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(self.owner_allocator, io) catch @panic("external device teardown");
        const handles = &self.instance.native_context.?.handles;
        for (std.enums.values(engine.vulkan_device.HandleKind)) |kind| {
            if (kind != .instance) t.expectEqual(@as(u32, 0), handles.countOf(kind)) catch
                @panic("external native handle leaked");
        }
        self.adapters.deinit(io) catch @panic("external adapters teardown");
        self.instance.deinit(self.owner_allocator, io) catch @panic("external instance teardown");
        self.threaded.deinit();
    }

    fn release(self: *Fixture, resource: anytype) void {
        self.device.release(self.owner_allocator, self.threaded.io(), resource) catch
            @panic("external resource release");
    }

    fn deinitEncoder(self: *Fixture, encoder: *Encoder) void {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(self.owner_allocator, io, &guard);
    }

    fn deinitFinished(self: *Fixture, finished: *Finished) void {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(self.owner_allocator, io, &guard);
    }

    fn plane(self: *Fixture, format: api.TextureFormat, size: u32, bytes: []const u8) !*engine.texture.TextureView {
        const io = self.threaded.io();
        const channels: u32 = switch (format) {
            .r8_unorm => 1,
            .rg8_unorm => 2,
            .rgba8_unorm => 4,
            else => return error.InvalidFixtureFormat,
        };
        if (bytes.len != size * size * channels) return error.InvalidFixturePlaneSize;
        const image = try self.device.createTexture(self.owner_allocator, io, .{
            .format = format,
            .size = .{ .width = size, .height = size },
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        defer self.release(image);
        const view = try self.device.createTextureView(self.owner_allocator, io, .{
            .texture = image,
            .descriptor = .{ .format = format, .dimension = ._2d },
        });
        errdefer self.release(view);
        const upload = try self.device.createBuffer(self.owner_allocator, io, .{
            .size = pitch * size,
            .usage = .{ .copy_src = true },
            .mapped_at_creation = true,
        });
        defer self.release(upload);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, upload.header.tracking);
            defer guard.unlock(io);
            const mapped = try upload.native.getMappedRange(0, pitch * size);
            @memset(mapped, sentinel);
            for (0..size) |row| @memcpy(mapped[row * pitch ..][0 .. size * channels], bytes[row * size * channels ..][0 .. size * channels]);
        }
        try self.device.unmapBuffer(io, upload);
        var encoder = Encoder.init(self.owner_allocator, self.device.core.borrow(), .{});
        defer self.deinitEncoder(&encoder);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, image.header.tracking);
            defer guard.unlock(io);
            try encoder.copyBufferToTexture(.{
                .source = .{ .buffer = try upload.ref(&guard), .blocks_per_row = pitch / channels, .rows_per_image = size },
                .destination = .{ .texture = image, .format = @intFromEnum(format), .dimension = ._2d, .aspect = .all, .extent = .{ .width = size, .height = size, .depth_or_array_layers = 1 } },
                .copy_size = .{ .width = size, .height = size, .depth_or_array_layers = 1 },
            });
        }
        var finished = try encoder.finish();
        defer self.deinitFinished(&finished);
        const serial = try self.device.submit(self.owner_allocator, io, &finished);
        try self.device.wait(io, serial);
        return view;
    }

    fn options(self: *Fixture, first: *engine.texture.TextureView, second: ?*engine.texture.TextureView) external.Options {
        return .{
            .plane_0 = first,
            .plane_1 = second,
            .crop_origin = .{},
            .crop_size = .{ .width = extent, .height = extent },
            .apparent_size = .{ .width = extent, .height = extent },
            .src_transfer_function_parameters = &identity_transfer,
            .dst_transfer_function_parameters = &identity_transfer,
            .gamut_conversion_matrix = &identity_gamut,
            .enabled_features = &self.device.enabled_features,
            .limits = &self.device.limits,
        };
    }
};

const Session = struct {
    fixture: *Fixture,
    lease: engine.Device.QueueLease,
    guard: core.ObjectGuard,
    recording: engine.recording_context.CommandRecordingContext,
    open: bool,

    fn begin(self: *Session, fixture: *Fixture) !void {
        const io = fixture.threaded.io();
        const lease = try fixture.device.getQueue(io);
        self.* = .{ .fixture = fixture, .lease = lease, .guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList()), .recording = .init(fixture.owner_allocator), .open = true };
        errdefer self.deinit();
        const native_context = fixture.device.native.?;
        try fixture.device.bindObjectsLocked(&self.guard, fixture.owner_allocator);
        if (native_context.recording_uses == null) native_context.recording_uses = try native.PendingUses.prepareDeclaredLocked(
            fixture.owner_allocator,
            &self.guard,
            &fixture.device.core,
            &.{},
        );
        self.recording.command_buffer = self.lease.commandBuffer();
    }

    fn context(self: *Session) kernels.Context {
        const owner = self.fixture.device.native.?;
        return .{ .io = self.fixture.threaded.io(), .guard = &self.guard, .device = &self.fixture.device.core, .queue = &owner.queue, .recording = &self.recording, .pending_uses = &owner.recording_uses.?, .cache = &owner.kernel_cache.? };
    }

    fn nativeRecording(self: *Session) engine.buffer.Recording {
        return .{ .command_buffer = self.recording.command_buffer, .pending_serial = self.context().queue.timeline.nextSerial() };
    }

    fn submit(self: *Session) !dusk.platform.Serial {
        const io = self.fixture.threaded.io();
        self.guard.unlock(io);
        self.open = false;
        defer self.lease.deinit(io);
        const result = try self.lease.submit(self.fixture.owner_allocator, io, .{
            .command_buffers = &.{self.recording.command_buffer},
        }, &.{});
        return result.serial;
    }

    fn deinit(self: *Session) void {
        if (self.open) {
            self.guard.unlock(self.fixture.threaded.io());
            self.lease.deinit(self.fixture.threaded.io());
            self.open = false;
        }
        self.recording.deinit();
    }
};

const Scene = struct {
    target: *engine.texture.Texture,
    view: *engine.texture.TextureView,
    readback: *native.Buffer,
    encoder: Encoder,
    pass: dusk.command.render_encoder_base.RenderEncoderBase,
    format: api.TextureFormat,

    fn init(self: *Scene, fixture: *Fixture) !void {
        return self.initFormat(fixture, .rgba8_unorm);
    }

    fn initFormat(self: *Scene, fixture: *Fixture, format: api.TextureFormat) !void {
        self.format = format;
        const io = fixture.threaded.io();
        self.target = try fixture.device.createTexture(fixture.owner_allocator, io, .{
            .format = format,
            .size = .{ .width = extent, .height = extent },
            .usage = .{ .render_attachment = true, .copy_src = true },
        });
        errdefer fixture.release(self.target);
        self.view = try fixture.device.createTextureView(fixture.owner_allocator, io, .{
            .texture = self.target,
            .descriptor = .{ .format = format, .dimension = ._2d },
        });
        errdefer fixture.release(self.view);
        self.readback = try fixture.device.createBuffer(fixture.owner_allocator, io, .{
            .size = readback_size,
            .usage = .{ .copy_dst = true, .map_read = true },
        });
        errdefer fixture.release(self.readback);
        self.encoder = Encoder.init(fixture.owner_allocator, fixture.device.core.borrow(), .{});
        errdefer fixture.deinitEncoder(&self.encoder);
        self.pass = try fixture.device.beginRenderPass(fixture.owner_allocator, io, &self.encoder, .{
            .color_attachments = &.{.{ .view = self.view, .load_op = .clear, .store_op = .store }},
            .width = extent,
            .height = extent,
        });
    }

    fn deinit(self: *Scene, fixture: *Fixture) void {
        const io = fixture.threaded.io();
        {
            var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
            defer guard.unlock(io);
            self.pass.deinit(io, &guard);
        }
        fixture.deinitEncoder(&self.encoder);
        fixture.release(self.readback);
        fixture.release(self.view);
        fixture.release(self.target);
    }

    fn draw(self: *Scene, session: *Session, source: *external.ExternalTexture, sampling: *engine.sampler.Sampler) !void {
        return self.drawBrowser(session, source, sampling, null);
    }

    fn drawBrowser(self: *Scene, session: *Session, source: *external.ExternalTexture, sampling: *engine.sampler.Sampler, geometry: ?external.BrowserGeometry) !void {
        const context = session.context();
        const owner = session.fixture.device.native.?;
        const procs = owner.native_device.procs;
        var validated = if (geometry) |value| try external.validateBrowserCopy(context, source, value) else null;
        try external.prepareForUse(context, source);
        try context.pending_uses.retainDerivedRootLocked(&session.guard, context.device, &self.target.header);
        try context.pending_uses.retainDerivedRootLocked(&session.guard, context.device, &self.view.header);
        try context.pending_uses.retainDerivedRootLocked(&session.guard, context.device, &self.readback.header);
        var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
        query.setSampleCount(1);
        query.setColor(.{ .index = 0, .format = self.format, .load_op = .clear, .store_op = .store, .has_resolve_target = false, .render_to_single_sampled = false });
        const render_pass = try owner.render_pass_cache.getRenderPass(context.io, query);
        var frame: engine.framebuffer_cache.FramebufferCacheQuery = .{};
        frame.key.setRenderPass(.{ .pass_id = render_pass.unique_id, .width = extent, .height = extent });
        try frame.addAttachment(.{ .texture_view_id = @intFromPtr(self.view), .image_view = try self.view.getHandle(&session.guard) });
        const framebuffer = try owner.framebuffer_cache.getOrCreate(&frame, render_pass.render_pass);
        const metadata: kernels.Binding = .{ .buffer = .{ .owner = source.params_buffer, .offset = 0, .size = 288 } };
        const ordinary = [_]kernels.Binding{
            .{ .view = source.planes[0] }, .{ .view = source.planes[1] }, .{ .sampler = sampling }, metadata,
        };
        const hardware = [_]kernels.Binding{ .{ .view = source.planes[0] }, metadata };
        const browser = external.browserParameters(source);
        const prepared = if (validated) |*value| try external.prepareBrowserCopy(context, value, .{
            .ordinary_sampler = if (source.conversion_sampler == null) sampling else null,
            .compatible_render_pass = render_pass.render_pass,
            .attachments = self.pass.attachmentState(),
        }) else try kernels.prepareDraw(context, .{
            .key = .{ .id = .external_to_color, .attachments = self.pass.attachmentState(), .color_write_slots = 1, .conversion_sampler = source.conversion_sampler },
            .bindings = if (source.conversion_sampler != null) &hardware else &ordinary,
            .parameters = &browser,
            .compatible_render_pass = render_pass.render_pass,
        });
        try self.target.transitionRenderAttachment(&session.guard, session.nativeRecording(), color_range, .{});
        const fill = procs.cmd_fill_buffer orelse return error.MissingDeviceProc;
        try self.readback.native.transitionUsageNow(session.nativeRecording(), (api.BufferUsage{ .copy_dst = true }).toFlags(), .none);
        fill(session.recording.command_buffer, self.readback.native.getHandle(), 0, readback_size, 0xa5a5a5a5);
        self.readback.native.is_data_initialized = true;
        const begin = procs.cmd_begin_render_pass orelse return error.MissingDeviceProc;
        const end = procs.cmd_end_render_pass orelse return error.MissingDeviceProc;
        const begin_info: vk.VkRenderPassBeginInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = render_pass.render_pass,
            .framebuffer = framebuffer,
            .renderArea = .{ .extent = .{ .width = extent, .height = extent } },
            .clearValueCount = 1,
            .pClearValues = frame.clear_values[0..1].ptr,
        };
        begin(session.recording.command_buffer, &begin_info, vk.VK_SUBPASS_CONTENTS_INLINE);
        session.recording.active_render_pass = render_pass.render_pass;
        try kernels.recordDraw(context, .{
            .prepared = prepared,
            .render_pass = render_pass.render_pass,
            .attachments = self.pass.attachmentState(),
            .viewport = .{ .x = 0, .y = 0, .width = extent, .height = extent, .minDepth = 0, .maxDepth = 1 },
            .scissor = .{ .extent = .{ .width = extent, .height = extent } },
        });
        end(session.recording.command_buffer);
        session.recording.active_render_pass = null;
        session.recording.has_recorded_render_pass = true;
        try self.target.transition(&session.guard, session.nativeRecording(), color_range, .{ .copy_src = true }, .none);
        // Order the sentinel fill before the image copy's transfer write.
        try self.readback.native.transitionUsageNow(
            session.nativeRecording(),
            (api.BufferUsage{ .copy_dst = true }).toFlags(),
            .none,
        );
        const copy = procs.cmd_copy_image_to_buffer orelse return error.MissingDeviceProc;
        const region: vk.VkBufferImageCopy = .{
            .bufferRowLength = pitch / 4,
            .bufferImageHeight = extent,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
            .imageExtent = .{ .width = extent, .height = extent, .depth = 1 },
        };
        copy(session.recording.command_buffer, self.target.native.?.image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.readback.native.getHandle(), 1, &region);
        try self.readback.native.transitionUsageNow(session.nativeRecording(), (api.BufferUsage{ .map_read = true }).toFlags(), .none);
    }

    fn expectPixels(self: *Scene, fixture: *Fixture, serial: dusk.platform.Serial, expected: *const [extent * extent][4]f64, tolerance: f64) !void {
        const io = fixture.threaded.io();
        try fixture.device.wait(io, serial);
        try fixture.device.mapBuffer(io, self.readback, .{ .mode = .{ .read = true }, .size = readback_size });
        defer fixture.device.unmapBuffer(io, self.readback) catch @panic("external readback unmap");
        var guard = core.ObjectGuard.lockUncancelable(io, self.readback.header.tracking);
        defer guard.unlock(io);
        const bytes = try self.readback.native.getConstMappedRange(0, readback_size);
        for (0..extent) |row| {
            for (0..extent) |column| {
                for (0..4) |channel| {
                    const value = @as(f64, @floatFromInt(bytes[row * pitch + column * 4 + channel])) / 255;
                    try t.expectApproxEqAbs(std.math.clamp(expected[row * extent + column][channel], 0, 1), value, tolerance);
                }
            }
            for (bytes[row * pitch + extent * 4 ..][0 .. pitch - extent * 4]) |byte| try t.expectEqual(@as(u8, sentinel), byte);
        }
    }
};

fn rgbaPattern() [extent * extent * 4]u8 {
    var bytes: [extent * extent * 4]u8 = undefined;
    for (0..extent * extent) |index| {
        bytes[index * 4 ..][0..4].* = .{ @intCast(31 + index * 9), @intCast(193 - index * 7), @intCast(47 + index * 5), @intCast(63 + index * 11) };
    }
    return bytes;
}

fn transfer(value: f64, params: [7]f32) f64 {
    const p: [7]f64 = .{ params[0], params[1], params[2], params[3], params[4], params[5], params[6] };
    if (p[0] == -1) {
        return if (value <= p[4]) value * value / p[5] else (p[2] + @exp((value - p[3]) / p[1])) / p[6];
    }
    if (p[0] == -2) {
        const powered = std.math.pow(f64, std.math.clamp(value, 0, 1), 1 / p[2]);
        return std.math.pow(f64, @max(powered - p[3], 0) / (p[4] - p[5] * powered), 1 / p[1]);
    }
    const sign: f64 = if (value < 0) -1 else if (value > 0) 1 else 0;
    const magnitude = @abs(value);
    return sign * (if (magnitude < p[4]) p[3] * magnitude + p[6] else std.math.pow(f64, p[1] * magnitude + p[2], p[0]) + p[5]);
}

fn colorOracle(rgb: [3]f64, alpha: f64, options: external.Options) [4]f64 {
    if (options.do_yuv_to_rgb_conversion_only) return .{ rgb[0], rgb[1], rgb[2], alpha };
    const src = options.src_transfer_function_parameters.?[0..7].*;
    const dst = options.dst_transfer_function_parameters.?[0..7].*;
    const gamut = options.gamut_conversion_matrix.?;
    var decoded: [3]f64 = undefined;
    for (0..3) |channel| decoded[channel] = transfer(rgb[channel], src);
    if (src[0] == -1) {
        const luminance = decoded[0] * 0.2627 + decoded[1] * 0.6780 + decoded[2] * 0.0593;
        const factor = std.math.pow(f64, @abs(luminance), 0.2) * (if (luminance < 0) @as(f64, -1) else @as(f64, 1));
        for (&decoded) |*value| value.* *= factor;
    }
    var result: [4]f64 = .{ 0, 0, 0, alpha };
    for (0..3) |channel| {
        var linear: f64 = 0;
        for (0..3) |component| linear += gamut[component * 3 + channel] * decoded[component];
        result[channel] = transfer(linear, dst);
    }
    return result;
}

fn expectedOnePlane(bytes: []const u8, options: external.Options) [extent * extent][4]f64 {
    var expected: [extent * extent][4]f64 = undefined;
    for (0..extent) |row| for (0..extent) |column| {
        var u = (@as(f64, @floatFromInt(column)) + 0.5) / extent - 0.5;
        const v = (@as(f64, @floatFromInt(row)) + 0.5) / extent - 0.5;
        if (options.mirrored) u = -u;
        const rotated: [2]f64 = switch (options.rotation) {
            .rotate_0_degrees => .{ u, v },
            .rotate_90_degrees => .{ v, -u },
            .rotate_180_degrees => .{ -u, -v },
            .rotate_270_degrees => .{ -v, u },
        };
        const x: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(options.crop_origin.x)) + (rotated[0] + 0.5) * @as(f64, @floatFromInt(options.crop_size.width))));
        const y: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(options.crop_origin.y)) + (rotated[1] + 0.5) * @as(f64, @floatFromInt(options.crop_size.height))));
        const index = (y * extent + x) * 4;
        expected[row * extent + column] = colorOracle(.{ @as(f64, @floatFromInt(bytes[index])) / 255, @as(f64, @floatFromInt(bytes[index + 1])) / 255, @as(f64, @floatFromInt(bytes[index + 2])) / 255 }, @as(f64, @floatFromInt(bytes[index + 3])) / 255, options);
    };
    return expected;
}

test "external one-plane GPU crop mirror every rotation alpha and untouched padding after source release" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    for ([_]api.ExternalTextureRotation{ .rotate_0_degrees, .rotate_90_degrees, .rotate_180_degrees, .rotate_270_degrees }) |rotation| {
        for ([_]bool{ false, true }) |mirrored| {
            const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
            var options = fixture.options(plane, null);
            options.crop_origin = .{ .x = 1, .y = 1 };
            options.crop_size = .{ .width = 2, .height = 2 };
            options.rotation = rotation;
            options.mirrored = mirrored;
            const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
            defer fixture.release(source);
            fixture.release(plane);
            try t.expectEqual(@as(u32, 0), plane.header.user_reference_count);
            try t.expect(source.planes[0] == source.planes[1]);
            const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
            defer fixture.release(sampling);
            var scene: Scene = undefined;
            try scene.init(&fixture);
            defer scene.deinit(&fixture);
            var session: Session = undefined;
            try session.begin(&fixture);
            defer session.deinit();
            try scene.draw(&session, source, sampling);
            const serial = try session.submit();
            const expected = expectedOnePlane(&pixels, options);
            try scene.expectPixels(&fixture, serial, &expected, 1.0 / 255.0);
        }
    }
}

test "external two-plane native sampling consumes Y UV matrix gamma gamut HLG OOTF and PQ" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const y = [_]u8{153} ** 16;
    const uv = [_]u8{ 117, 139 } ** 4;
    const gamma = [7]f32{ 2.2, 1, 0, 1, 0, 0, 0 };
    const destination = [7]f32{ 0.45454545, 1, 0, 1, 0, 0, 0 };
    const gamut = [9]f32{ 0.75, 0.05, 0.1, 0.1, 0.8, 0.05, 0.05, 0.1, 0.7 };
    const hlg = [7]f32{ -1, 0.17883277, 0.28466892, 0.55991073, 0.5, 3, 12 };
    const pq = [7]f32{ -2, 2610.0 / 16384.0, 2523.0 / 32.0, 3424.0 / 4096.0, 2413.0 / 128.0, 2392.0 / 128.0, 0 };
    const modes = [_][7]f32{ identity_transfer, gamma, hlg, pq };
    for (modes) |source_transfer| {
        const first = try fixture.plane(.r8_unorm, extent, &y);
        const second = try fixture.plane(.rg8_unorm, 2, &uv);
        var options = fixture.options(first, second);
        options.yuv_to_rgb_conversion_matrix = &yuv_matrix;
        options.src_transfer_function_parameters = &source_transfer;
        options.dst_transfer_function_parameters = &destination;
        options.gamut_conversion_matrix = &gamut;
        const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
        defer fixture.release(source);
        fixture.release(first);
        fixture.release(second);
        const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
        defer fixture.release(sampling);
        var scene: Scene = undefined;
        try scene.init(&fixture);
        defer scene.deinit(&fixture);
        var session: Session = undefined;
        try session.begin(&fixture);
        defer session.deinit();
        try scene.draw(&session, source, sampling);
        const serial = try session.submit();
        var rgb: [3]f64 = undefined;
        for (0..3) |channel| rgb[channel] = @as(f64, yuv_matrix[channel * 4]) * 153.0 / 255 +
            @as(f64, yuv_matrix[channel * 4 + 1]) * 117.0 / 255 +
            @as(f64, yuv_matrix[channel * 4 + 2]) * 139.0 / 255 + yuv_matrix[channel * 4 + 3];
        const expected = [_][4]f64{colorOracle(rgb, 1, options)} ** 16;
        try scene.expectPixels(&fixture, serial, &expected, 2.0 / 255.0);
    }
}

fn word(bytes: *const [288]u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn floatWord(bytes: *const [288]u8, offset: usize) f32 {
    return @bitCast(word(bytes, offset));
}

test "external metadata is exactly 288 bytes with pinned offsets zero padding and immutable refresh" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    defer fixture.release(plane);
    var options = fixture.options(plane, null);
    options.crop_origin = .{ .x = 1, .y = 1 };
    options.crop_size = .{ .width = 2, .height = 2 };
    const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
    defer fixture.release(source);
    try t.expectEqual(@as(usize, 288), source.params.len);
    try t.expectEqual(@as(u64, 288), source.params_buffer.native.size);
    try t.expect(!source.params_buffer.native.is_data_initialized);
    try t.expectEqual(@as(u32, 1), word(&source.params, 0));
    try t.expectEqual(@as(u32, 0), word(&source.params, 4));
    for (source.params[8..16]) |byte| try t.expectEqual(@as(u8, 0), byte);
    for ([_]usize{ 140, 156, 172 }) |offset| try t.expectEqual(@as(u32, 0), word(&source.params, offset));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 16));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 36));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 56));
    try t.expectEqual(@as(u32, 0), word(&source.params, 64));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 68));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 92));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 128));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 148));
    try t.expectEqual(@as(f32, 1), floatWord(&source.params, 168));
    try t.expectEqual(@as(f32, 0.5), floatWord(&source.params, 176));
    try t.expectEqual(@as(f32, 0.5), floatWord(&source.params, 188));
    try t.expectEqual(@as(f32, 0.25), floatWord(&source.params, 192));
    try t.expectEqual(@as(f32, 0.25), floatWord(&source.params, 196));
    try t.expectEqual(@as(f32, 0.375), floatWord(&source.params, 224));
    try t.expectEqual(@as(f32, 0.625), floatWord(&source.params, 232));
    try t.expectEqual(@as(u32, 3), word(&source.params, 256));
    try t.expectEqual(@as(u32, 3), word(&source.params, 260));
    for (source.params[272..288]) |byte| try t.expectEqual(@as(u8, 0), byte);
    const before = source.params;
    const io = fixture.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, source.header.tracking);
    defer guard.unlock(io);
    try source.expireLocked(&guard);
    try t.expectError(error.ExternalTextureExpired, source.validateSubmitLocked(&guard));
    try t.expectError(error.ExternalTextureExpired, source.expireLocked(&guard));
    try source.refreshLocked(&guard);
    try source.validateSubmitLocked(&guard);
    try source.refreshLocked(&guard);
    try t.expectEqualSlices(u8, &before, &source.params);
}

test "external refresh permits GPU admission but expiry never cancels accepted pending pixels" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const options = fixture.options(plane, null);
    const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
    defer fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    var scene: Scene = undefined;
    try scene.init(&fixture);
    defer scene.deinit(&fixture);
    var session: Session = undefined;
    try session.begin(&fixture);
    defer session.deinit();
    try source.expireLocked(&session.guard);
    try t.expectError(error.ExternalTextureExpired, external.prepareForUse(session.context(), source));
    try source.refreshLocked(&session.guard);
    try scene.draw(&session, source, sampling);
    const serial = try session.submit();
    {
        const io = fixture.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, source.header.tracking);
        defer guard.unlock(io);
        try source.expireLocked(&guard);
        try t.expectError(error.ExternalTextureExpired, source.validateSubmitLocked(&guard));
        try t.expect(fixture.device.native.?.pending_recording_uses != null);
    }
    const expected = expectedOnePlane(&pixels, options);
    try scene.expectPixels(&fixture, serial, &expected, 1.0 / 255.0);
}

test "external explicit destruction drops edges only after pending child roots preserve descriptors" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const options = fixture.options(plane, null);
    const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
    var source_user = true;
    defer if (source_user) fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    var scene: Scene = undefined;
    try scene.init(&fixture);
    defer scene.deinit(&fixture);
    var session: Session = undefined;
    try session.begin(&fixture);
    defer session.deinit();
    try scene.draw(&session, source, sampling);
    const metadata = source.params_buffer;
    const plane_image = plane.texture;
    const serial = try session.submit();
    {
        const io = fixture.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, source.header.tracking);
        defer guard.unlock(io);
        source.header.retirePayloadLocked(&guard, io, .early_destroy);
        try t.expectError(error.ExternalTextureDestroyed, source.validateSubmitLocked(&guard));
        try t.expectError(error.ExternalTextureDestroyed, source.refreshLocked(&guard));
        try t.expectError(error.ExternalTextureDestroyed, source.expireLocked(&guard));
        try t.expect(plane.header.isAlive(&guard));
        try t.expect(plane_image.header.isAlive(&guard));
        try t.expect(metadata.header.isAlive(&guard));
        try t.expectEqual(serial, metadata.accepted_usage_serial);
    }
    fixture.release(source);
    source_user = false;
    const expected = expectedOnePlane(&pixels, options);
    try scene.expectPixels(&fixture, serial, &expected, 1.0 / 255.0);
    const io = fixture.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, plane.header.tracking);
    defer guard.unlock(io);
    try t.expect(!plane.header.isAlive(&guard));
    try t.expect(!plane_image.header.isAlive(&guard));
    try t.expect(!metadata.header.isAlive(&guard));
}

test "external descriptors reject cross-device planes malformed color metadata and crop before allocation" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    var foreign: Fixture = .{};
    try foreign.init(allocator);
    defer foreign.deinit();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    defer fixture.release(plane);
    const foreign_plane = try foreign.plane(.rgba8_unorm, extent, &pixels);
    defer foreign.release(foreign_plane);
    const io = fixture.threaded.io();
    const before = fixture.device.native.?.native_device.handles.totalCount();
    var options = fixture.options(plane, foreign_plane);
    try t.expectError(error.ResourceDeviceMismatch, fixture.device.createExternalTexture(allocator, io, options));
    options.plane_1 = null;
    options.crop_origin = .{ .x = std.math.maxInt(u32), .y = 0 };
    try t.expectError(error.ExternalTextureInvalidCrop, fixture.device.createExternalTexture(allocator, io, options));
    options.crop_origin = .{};
    options.crop_size.width = 0;
    try t.expectError(error.ExternalTextureInvalidCrop, fixture.device.createExternalTexture(allocator, io, options));
    options.crop_size.width = extent;
    options.apparent_size.height = 0;
    try t.expectError(error.ExternalTextureInvalidApparentSize, fixture.device.createExternalTexture(allocator, io, options));
    options.apparent_size.height = extent;
    options.yuv_to_rgb_conversion_matrix = &.{ 1, 2 };
    try t.expectError(error.ExternalTextureInvalidMetadata, fixture.device.createExternalTexture(allocator, io, options));
    options.yuv_to_rgb_conversion_matrix = null;
    options.src_transfer_function_parameters = &.{ 1, 1, 0, 1, 0, 0, std.math.nan(f32) };
    try t.expectError(error.ExternalTextureInvalidMetadata, fixture.device.createExternalTexture(allocator, io, options));
    options.src_transfer_function_parameters = &.{ -3, 1, 0, 1, 0, 0, 0 };
    try t.expectError(error.ExternalTextureInvalidMetadata, fixture.device.createExternalTexture(allocator, io, options));
    options.src_transfer_function_parameters = &identity_transfer;
    options.dst_transfer_function_parameters = &.{ -1, 1, 0, 1, 0, 0, 0 };
    try t.expectError(error.ExternalTextureInvalidMetadata, fixture.device.createExternalTexture(allocator, io, options));
    try t.expectEqual(before, fixture.device.native.?.native_device.handles.totalCount());
}

test "external create fail-N restores plane leases metadata native handles and final device deinit" {
    var reached_success = false;
    for (0..128) |failure_offset| {
        var failing = t.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
        const owner_allocator = failing.allocator();
        var fixture: Fixture = .{};
        try fixture.init(owner_allocator);
        defer fixture.deinit();
        const pixels = rgbaPattern();
        const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
        defer fixture.release(plane);
        const references = plane.header.reference_count;
        const image_references = plane.texture.header.reference_count;
        const before = fixture.device.native.?.native_device.handles.totalCount();
        failing.fail_index = failing.alloc_index + failure_offset;
        const created = fixture.device.createExternalTexture(owner_allocator, fixture.threaded.io(), fixture.options(plane, null));
        failing.fail_index = std.math.maxInt(usize);
        if (created) |source| {
            fixture.release(source);
            reached_success = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
        }
        try t.expectEqual(references, plane.header.reference_count);
        try t.expectEqual(image_references, plane.texture.header.reference_count);
        try t.expectEqual(before, fixture.device.native.?.native_device.handles.totalCount());
        if (reached_success) break;
    }
    try t.expect(reached_success);
}

const max_fixture_word_count: usize = @max(
    @divExact(@embedFile("fixtures/external_expanded_probe.comp.spv").len, 4),
    @max(
        definitions.fullscreen_vertex.words.len,
        definitions.external_ordinary_fragment.words.len,
    ),
);
const scalar_word_decode_branch_cost = 8;
const fixture_decode_branch_quota = 1000 + max_fixture_word_count * scalar_word_decode_branch_cost;

const probe_words = decodeWords(@embedFile("fixtures/external_expanded_probe.comp.spv"));

fn decodeWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    if (bytes.len % 4 != 0) @compileError("SPIR-V fixture must contain complete words");
    if (bytes.len / 4 > max_fixture_word_count) @compileError("SPIR-V exceeds the fixture word bound");
    @setEvalBranchQuota(fixture_decode_branch_quota);
    var result: [bytes.len / 4]u32 = undefined;
    for (&result, 0..) |*value, index| value.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    return result;
}

test "external logical bind group expands actual planes and metadata in unchanged consuming SPIR-V" {
    try expandedProbe(false);
}

test "external expired finished stream cannot advance submission serial or upload metadata" {
    try expandedProbe(true);
}

fn expandedProbe(expire_before_submit: bool) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const options = fixture.options(plane, null);
    const source = try fixture.device.createExternalTexture(allocator, io, options);
    var source_user = true;
    defer if (source_user) fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(allocator, io, .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    const output = try fixture.device.createBuffer(allocator, io, .{
        .size = 544,
        .usage = .{ .storage = true, .copy_src = true },
    });
    defer fixture.release(output);
    const readback = try fixture.device.createBuffer(allocator, io, .{
        .size = 640,
        .usage = .{ .copy_dst = true, .map_read = true },
    });
    defer fixture.release(readback);
    const caller_digest = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&probe_words));
    const module = try fixture.device.createShaderModule(allocator, io, .{ .words = &probe_words });
    defer fixture.release(module);
    const digest = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(module.words));
    try t.expectEqual(caller_digest, digest);
    try t.expectEqualSlices(u32, &probe_words, module.words);
    const group_layout = try fixture.device.createBindGroupLayout(allocator, io, .{
        .entries = &.{
            .{ .binding_number = 0, .visibility = .{ .compute = true }, .kind = .{ .external_texture = true } },
            .{ .binding_number = 2, .visibility = .{ .compute = true }, .kind = .{ .sampler = .{ .binding_type = .filtering } } },
            .{ .binding_number = 4, .visibility = .{ .compute = true }, .kind = .{ .buffer = .{ .binding_type = .storage, .has_dynamic_offset = false, .min_binding_size = 544 } } },
        },
    });
    defer fixture.release(group_layout);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, group_layout.header.tracking);
        defer guard.unlock(io);
        const expected = try dusk.pipeline.layout_internal.externalBindingNumbers(.{
            .binding_number = 0,
            .needs_static_sampler = false,
        });
        try t.expectEqual(@as(u32, 1000), expected.plane0);
        try t.expectEqual(@as(u32, 1001), expected.plane1);
        try t.expectEqual(@as(u32, 1002), expected.metadata);
        try t.expectEqual(@as(?u32, null), expected.static_sampler);
        const actual = try group_layout.queryExternalBindingNumbers(&guard, 0);
        try t.expect(std.meta.eql(expected, actual));
        const stored = group_layout.internal.queryExternalBindingNumbers(0) orelse return error.TestUnexpectedResult;
        try t.expect(std.meta.eql(actual, stored));
        try t.expectEqual(@as(usize, 5), group_layout.native.bindings.len);
        for ([_]u32{ 2, 4, actual.plane0, actual.plane1, actual.metadata }) |binding_number| {
            const binding = for (group_layout.native.bindings) |candidate| {
                if (candidate.binding == binding_number) break candidate;
            } else return error.TestUnexpectedResult;
            const descriptor_type: vk.VkDescriptorType = switch (binding_number) {
                2 => vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                4 => vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                1002 => vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                else => vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            };
            try t.expectEqual(descriptor_type, binding.descriptorType);
            try t.expectEqual(@as(u32, 1), binding.descriptorCount);
            try t.expectEqual(@as(vk.VkShaderStageFlags, vk.VK_SHADER_STAGE_COMPUTE_BIT), binding.stageFlags);
        }
    }
    const layout = try fixture.device.createPipelineLayout(allocator, io, .{ .groups = &.{group_layout} });
    defer fixture.release(layout);
    const pipeline = try fixture.device.createComputePipeline(allocator, io, .{
        .layout = layout,
        .compute = .{ .module = module, .entry_point = "external_expanded_probe", .stage = .compute },
    });
    defer fixture.release(pipeline);
    try t.expectEqual(caller_digest, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&probe_words)));
    try t.expectEqual(digest, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(module.words)));
    try t.expectEqualSlices(u32, &probe_words, module.words);
    const group = try fixture.device.createBindGroup(allocator, io, .{
        .layout = layout,
        .group_index = 0,
        .bindings = &.{
            .{ .external_texture = .{ .binding = 0, .texture = source, .stages = .{ .compute = true } } },
            .{ .sampler = .{ .binding = 2, .sampler = sampling } },
            .{ .buffer = .{ .binding = 4, .buffer = output, .offset = 0, .size = 544, .kind = .storage, .stages = .{ .compute = true } } },
        },
    });
    defer fixture.release(group);
    var encoder = Encoder.init(allocator, fixture.device.core.borrow(), .{});
    defer fixture.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, source.header.tracking);
        defer guard.unlock(io);
        const padding = [_]u8{sentinel} ** 640;
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        const layout_id = @intFromPtr(&group_layout.header);
        try pass.setPipeline(.{ .pipeline = try pipeline.ref(&guard), .requirements = .{
            .bind_group_layout_mask = 1,
            .bind_group_layout_ids = .{ layout_id, 0, 0, 0 },
        } });
        try pass.setBindGroup(.{
            .index = 0,
            .group = try group.ref(&guard),
            .layout_id = layout_id,
            .min_binding_buffer_size = 544,
            .buffers = &.{.{ .buffer = try output.ref(&guard), .usage = (api.BufferUsage{ .storage = true }).toFlags() }},
            .external_textures = &.{try source.ref(&guard)},
        });
        try pass.dispatch(.{});
        try pass.end();
        try encoder.copyBufferToBuffer(.{
            .source = try output.ref(&guard),
            .destination = try readback.ref(&guard),
            .size = 544,
        });
    }
    var finished = try encoder.finish();
    defer fixture.deinitFinished(&finished);
    if (expire_before_submit) {
        var guard = core.ObjectGuard.lockUncancelable(io, source.header.tracking);
        try source.expireLocked(&guard);
        guard.unlock(io);
        const before = fixture.device.native.?.queue.timeline.lastSubmittedSerial();
        try t.expectError(error.ExternalTextureExpired, fixture.device.submit(allocator, io, &finished));
        try t.expectEqual(before, fixture.device.native.?.queue.timeline.lastSubmittedSerial());
        try t.expectEqual(@as(dusk.platform.Serial, 0), source.params_buffer.accepted_usage_serial);
        try t.expect(!source.params_buffer.native.is_data_initialized);
        return;
    }
    const metadata = source.params;
    const serial = try fixture.device.submit(allocator, io, &finished);
    fixture.release(source);
    source_user = false;
    try fixture.device.wait(io, serial);
    try fixture.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 640 });
    defer fixture.device.unmapBuffer(io, readback) catch @panic("external probe unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, readback.header.tracking);
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 640);
    for (0..16) |pixel| for (0..4) |channel| {
        const actual: f32 = @bitCast(std.mem.readInt(u32, bytes[(pixel * 4 + channel) * 4 ..][0..4], .little));
        try t.expectApproxEqAbs(@as(f32, @floatFromInt(pixels[pixel * 4 + channel])) / 255, actual, 0.00001);
    };
    try t.expectEqualSlices(u8, &metadata, bytes[256..544]);
    for (bytes[544..640]) |byte| try t.expectEqual(@as(u8, sentinel), byte);
    try t.expectEqual(digest, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(module.words)));
    try t.expectEqualSlices(u32, &probe_words, module.words);
}

test "external one-plane gamma branches and HLG dark light decoding preserve alpha on GPU" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    const cases = [_]struct { source: [7]f32, destination: [7]f32 = identity_transfer, sampled_f32_boundary: bool = false }{
        // Retain equality at green 102/255: sampling rounds RGB to f32 before the strict < D.
        .{ .source = .{ 2, 0.8, 0.05, 0.5, 0.4, 0.01, 0.02 }, .sampled_f32_boundary = true },
        // Keep D exact in f32 and off the byte grid for an independent f64 branch oracle.
        .{ .source = .{ 2, 0.8, 0.05, 0.5, 0.40625, 0.01, 0.02 } },
        // Exercise both destination branches independently with identity source decoding.
        .{ .source = identity_transfer, .destination = .{ 2, 0.8, 0.05, 0.5, 0.40625, 0.01, 0.02 } },
        .{ .source = .{ -1, 0.17883277, 0.28466892, 0.55991073, 0.5, 3, 12 } },
    };
    for (cases) |case| {
        const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
        var options = fixture.options(plane, null);
        options.src_transfer_function_parameters = &case.source;
        options.dst_transfer_function_parameters = &case.destination;
        const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
        defer fixture.release(source);
        fixture.release(plane);
        const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
        defer fixture.release(sampling);
        var scene: Scene = undefined;
        try scene.init(&fixture);
        defer scene.deinit(&fixture);
        var session: Session = undefined;
        try session.begin(&fixture);
        defer session.deinit();
        try scene.draw(&session, source, sampling);
        const serial = try session.submit();
        var expected = expectedOnePlane(&pixels, options);
        if (case.sampled_f32_boundary) {
            // This full-grid identity draw samples each source texel once. Only input
            // decode uses f32; transfer, gamut and OOTF remain independent f64 math.
            for (&expected, 0..) |*pixel, index| {
                var rgb: [3]f64 = undefined;
                for (&rgb, 0..) |*value, channel| {
                    const sampled: f32 = @as(f32, @floatFromInt(pixels[index * 4 + channel])) / 255;
                    value.* = sampled;
                }
                pixel.* = colorOracle(rgb, pixel[3], options);
            }
        }
        try scene.expectPixels(&fixture, serial, &expected, 2.0 / 255.0);
    }
}

fn bilinearPlane(bytes: []const u8, size: usize, channels: usize, channel: usize, u: f64, v: f64) f64 {
    const x = std.math.clamp(u * @as(f64, @floatFromInt(size)) - 0.5, 0, @as(f64, @floatFromInt(size - 1)));
    const y = std.math.clamp(v * @as(f64, @floatFromInt(size)) - 0.5, 0, @as(f64, @floatFromInt(size - 1)));
    const left: usize = @intFromFloat(@floor(x));
    const top: usize = @intFromFloat(@floor(y));
    const right = @min(left + 1, size - 1);
    const bottom = @min(top + 1, size - 1);
    const fraction_x = x - @as(f64, @floatFromInt(left));
    const fraction_y = y - @as(f64, @floatFromInt(top));
    const upper = @as(f64, @floatFromInt(bytes[(top * size + left) * channels + channel])) * (1 - fraction_x) +
        @as(f64, @floatFromInt(bytes[(top * size + right) * channels + channel])) * fraction_x;
    const lower = @as(f64, @floatFromInt(bytes[(bottom * size + left) * channels + channel])) * (1 - fraction_x) +
        @as(f64, @floatFromInt(bytes[(bottom * size + right) * channels + channel])) * fraction_x;
    return (upper * (1 - fraction_y) + lower * fraction_y) / 255;
}

test "external two-plane half-texel clamps use each real plane size and conversion-only bypass" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    var luma: [16]u8 = undefined;
    for (&luma, 0..) |*value, index| value.* = @intCast(32 + index * 12);
    const chroma = [8]u8{ 32, 80, 224, 112, 80, 192, 160, 240 };
    const identity_yuv = [12]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const nonidentity_transfer = [7]f32{ 2, 1, 0, 1, 0, 0, 0 };
    for ([_]u32{ 0, 1 }) |origin| {
        const first = try fixture.plane(.r8_unorm, extent, &luma);
        const second = try fixture.plane(.rg8_unorm, 2, &chroma);
        var options = fixture.options(first, second);
        options.crop_origin = .{ .x = origin, .y = origin };
        options.crop_size = .{ .width = extent - origin * 2, .height = extent - origin * 2 };
        options.do_yuv_to_rgb_conversion_only = true;
        options.yuv_to_rgb_conversion_matrix = &identity_yuv;
        options.src_transfer_function_parameters = &nonidentity_transfer;
        const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
        defer fixture.release(source);
        fixture.release(first);
        fixture.release(second);
        const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{
            .compare = .undefined_,
            .min_filter = .linear,
            .mag_filter = .linear,
        });
        defer fixture.release(sampling);
        var scene: Scene = undefined;
        try scene.init(&fixture);
        defer scene.deinit(&fixture);
        var session: Session = undefined;
        try session.begin(&fixture);
        defer session.deinit();
        try scene.draw(&session, source, sampling);
        const serial = try session.submit();
        var expected: [16][4]f64 = undefined;
        const minimum = @as(f64, @floatFromInt(origin)) / extent;
        const maximum = 1 - minimum;
        for (0..extent) |row| for (0..extent) |column| {
            const u = minimum + (@as(f64, @floatFromInt(column)) + 0.5) / extent * (maximum - minimum);
            const v = minimum + (@as(f64, @floatFromInt(row)) + 0.5) / extent * (maximum - minimum);
            expected[row * extent + column] = .{
                bilinearPlane(&luma, 4, 1, 0, std.math.clamp(u, minimum + 0.125, maximum - 0.125), std.math.clamp(v, minimum + 0.125, maximum - 0.125)),
                bilinearPlane(&chroma, 2, 2, 0, std.math.clamp(u, minimum + 0.25, maximum - 0.25), std.math.clamp(v, minimum + 0.25, maximum - 0.25)),
                bilinearPlane(&chroma, 2, 2, 1, std.math.clamp(u, minimum + 0.25, maximum - 0.25), std.math.clamp(v, minimum + 0.25, maximum - 0.25)),
                1,
            };
        };
        try scene.expectPixels(&fixture, serial, &expected, 2.0 / 255.0);
    }
}

test "external hardware unequal Y Cb Cr full narrow identity and 601 consume immutable combined descriptors" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const device = &fixture.device.native.?.native_device;
    const backend = engine.sampler.NativeBackend.fromDevice(device);
    const format = vk.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
    if (!device.sampler_y_cb_cr_enabled) {
        try t.expect(!device.physical.sampler_y_cb_cr_supported or device.api_version < vk.VK_API_VERSION_1_1);
        std.debug.print("external hardware unavailable: samplerYcbcrConversion supported={} enabled={} api=0x{x} VkFormat={d} tiling=OPTIMAL\n", .{
            device.physical.sampler_y_cb_cr_supported, device.sampler_y_cb_cr_enabled, device.api_version, format,
        });
        return error.SkipZigTest;
    }
    var properties: vk.VkFormatProperties = std.mem.zeroes(vk.VkFormatProperties);
    const get_properties = device.instance.procs.get_physical_device_format_properties orelse return error.MissingInstanceProc;
    get_properties(device.physical.handle, format, &properties);
    const image_info: vk.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .format = format,
        .type = vk.VK_IMAGE_TYPE_2D,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    };
    const descriptor_count = backend.combinedImageSamplerDescriptorCount(&image_info) catch |err| switch (err) {
        error.FormatNotSupported => {
            std.debug.print("external hardware unavailable: VkFormat={d} tiling=OPTIMAL usage=SAMPLED|TRANSFER_DST features=0x{x} exact image query=VK_ERROR_FORMAT_NOT_SUPPORTED\n", .{ format, properties.optimalTilingFeatures });
            return error.SkipZigTest;
        },
        else => return err,
    };
    try t.expect(descriptor_count > 0);
    for ([_]u32{ vk.VK_SAMPLER_YCBCR_RANGE_ITU_FULL, vk.VK_SAMPLER_YCBCR_RANGE_ITU_NARROW }) |range| {
        for ([_]u32{ vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_IDENTITY, vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_601 }) |model| {
            var selected: ?api.descriptors.SamplerDescriptorChain = null;
            for ([_]u32{ vk.VK_CHROMA_LOCATION_COSITED_EVEN, vk.VK_CHROMA_LOCATION_MIDPOINT }) |location| {
                const descriptor: api.descriptors.SamplerDescriptorChain = .{
                    .compare = .undefined_,
                    .y_cb_cr_vk_descriptor = .{
                        .vk_format = format,
                        .vk_y_cb_cr_model = model,
                        .vk_y_cb_cr_range = range,
                        .vk_x_chroma_offset = location,
                        .vk_y_chroma_offset = location,
                    },
                };
                backend.validateForTiling(try engine.sampler.semanticKey(descriptor), vk.VK_IMAGE_TILING_OPTIMAL) catch |err| switch (err) {
                    error.SamplerYCbCrFormatUnsupported => continue,
                    else => return err,
                };
                selected = descriptor;
                break;
            }
            const descriptor = selected orelse {
                std.debug.print("external hardware unavailable: VkFormat={d} tiling=OPTIMAL model={d} range={d} chroma=COSITED/MIDPOINT nearest features=0x{x}\n", .{ format, model, range, properties.optimalTilingFeatures });
                return error.SkipZigTest;
            };
            try hardwareScene(&fixture, descriptor, descriptor_count, .{ .y = 153, .cb = 128, .cr = 128 });
            try hardwareScene(&fixture, descriptor, descriptor_count, .{ .y = 128, .cb = 64, .cr = 192 });
        }
    }
}

const HardwareVector = struct { y: u8, cb: u8, cr: u8 };

fn hardwareScene(fixture: *Fixture, descriptor: api.descriptors.SamplerDescriptorChain, expected_descriptor_count: u32, vector: HardwareVector) !void {
    const io = fixture.threaded.io();
    const conversion = try fixture.device.createSampler(fixture.owner_allocator, io, descriptor);
    var conversion_user = true;
    defer if (conversion_user) fixture.release(conversion);
    const image = try fixture.device.createInternalYCbCrTexture(fixture.owner_allocator, io, .{
        .size = .{ .width = extent, .height = extent },
        .conversion_sampler = conversion,
    });
    var image_user = true;
    defer if (image_user) fixture.release(image);
    const view = try fixture.device.createInternalYCbCrTextureView(fixture.owner_allocator, io, .{
        .texture = image,
        .conversion_sampler = conversion,
    });
    var view_user = true;
    defer if (view_user) fixture.release(view);
    try t.expect(view.conversion_sampler == conversion);
    try t.expect(conversion.native.?.conversion != null);
    try t.expect(conversion.native.?.sampler != null);
    const upload = try fixture.device.createBuffer(fixture.owner_allocator, io, .{
        .size = 24,
        .usage = .{ .copy_src = true },
        .mapped_at_creation = true,
    });
    defer fixture.release(upload);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, upload.header.tracking);
        defer guard.unlock(io);
        const bytes = try upload.native.getMappedRange(0, 24);
        @memset(bytes[0..16], vector.y);
        for (0..4) |index| {
            bytes[16 + index * 2] = vector.cb;
            bytes[17 + index * 2] = vector.cr;
        }
        try t.expectEqual(@as(vk.VkFormat, @intCast(descriptor.y_cb_cr_vk_descriptor.?.vk_format)), try image.getNativeFormat(&guard));
        try t.expectEqual(expected_descriptor_count, try image.getCombinedImageSamplerDescriptorCount(&guard));
    }
    try fixture.device.unmapBuffer(io, upload);
    var options = fixture.options(view, null);
    options.conversion_sampler = conversion;
    options.do_yuv_to_rgb_conversion_only = true;
    const identity_model = descriptor.y_cb_cr_vk_descriptor.?.vk_y_cb_cr_model == vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_IDENTITY;
    const range_restoration = [12]f32{ 1, 0, 0, 0, 0, 1, 0, 0.5, 0, 0, 1, 0.5 };
    if (identity_model) options.yuv_to_rgb_conversion_matrix = &range_restoration;
    const source = try fixture.device.createExternalTexture(fixture.owner_allocator, io, options);
    var source_user = true;
    defer if (source_user) fixture.release(source);
    fixture.release(view);
    view_user = false;
    fixture.release(image);
    image_user = false;
    fixture.release(conversion);
    conversion_user = false;
    var scene: Scene = undefined;
    try scene.init(fixture);
    defer scene.deinit(fixture);
    var session: Session = undefined;
    try session.begin(fixture);
    defer session.deinit();
    try session.context().pending_uses.retainDerivedRootLocked(&session.guard, &fixture.device.core, &upload.header);
    try image.uploadYCbCrPlanes(&session.guard, session.nativeRecording(), upload.native, .{ 0, 16, 0 });
    try scene.draw(&session, source, conversion);
    var found_combined = false;
    var combined_layout: ?*native.PipelineLayout = null;
    for (session.context().cache.entries) |entry| if (entry) |cached| {
        if (cached.key.conversion_sampler == conversion) {
            try t.expect(cached.pipeline.layout.groups[0].immutable_samplers.len != 0);
            try t.expect(cached.pipeline.layout.groups[0].immutable_samplers[0].sampler == conversion);
            found_combined = true;
            combined_layout = cached.pipeline.layout;
        }
    };
    try t.expect(found_combined);
    const serial = try session.submit();
    try rejectSeparateShaderOnCombinedLayout(fixture, combined_layout.?);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, source.header.tracking);
        defer guard.unlock(io);
        source.header.retirePayloadLocked(&guard, io, .early_destroy);
        try t.expect(view.header.isAlive(&guard));
        try t.expect(conversion.header.isAlive(&guard));
    }
    fixture.release(source);
    source_user = false;
    const expected = [_][4]f64{hardwareColorOracle(vector, descriptor.y_cb_cr_vk_descriptor.?)} ** 16;
    try scene.expectPixels(fixture, serial, &expected, 1.0 / 255.0);
}

fn hardwareColorOracle(vector: HardwareVector, descriptor: api.descriptors.YCbCrVkDescriptor) [4]f64 {
    const narrow = descriptor.vk_y_cb_cr_range == vk.VK_SAMPLER_YCBCR_RANGE_ITU_NARROW;
    // Vulkan range expansion uses the component midpoint 128, not 127.5.
    const y = (@as(f64, @floatFromInt(vector.y)) - (if (narrow) @as(f64, 16) else 0)) /
        (if (narrow) @as(f64, 219) else 255);
    const cb = (@as(f64, @floatFromInt(vector.cb)) - 128) /
        (if (narrow) @as(f64, 224) else 255);
    const cr = (@as(f64, @floatFromInt(vector.cr)) - 128) /
        (if (narrow) @as(f64, 224) else 255);
    if (descriptor.vk_y_cb_cr_model == vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_IDENTITY) {
        return .{ y, cb + 0.5, cr + 0.5, 1 };
    }
    std.debug.assert(descriptor.vk_y_cb_cr_model == vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_601);
    // The metadata is identity here. Vulkan alone applies the 601 matrix.
    return .{ y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb, 1 };
}

fn rejectSeparateShaderOnCombinedLayout(fixture: *Fixture, layout: *native.PipelineLayout) !void {
    const io = fixture.threaded.io();
    const vertex_words = definitions.fullscreen_vertex.words;
    const separate_words = definitions.external_ordinary_fragment.words;
    const vertex = try fixture.device.createShaderModule(fixture.owner_allocator, io, .{ .words = vertex_words });
    defer fixture.release(vertex);
    const fragment = try fixture.device.createShaderModule(fixture.owner_allocator, io, .{ .words = separate_words });
    defer fixture.release(fragment);
    const before_handles = fixture.device.native.?.native_device.handles.totalCount();
    const before_pipelines = countPipelines(fixture);
    try t.expectError(error.ShaderBindingMismatch, fixture.device.createRenderPipeline(fixture.owner_allocator, io, .{
        .layout = layout,
        .vertex = .{ .module = vertex, .entry_point = "main", .stage = .vertex },
        .fragment = .{ .module = fragment, .entry_point = "external_ordinary", .stage = .fragment },
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    }));
    try t.expectEqual(before_handles, fixture.device.native.?.native_device.handles.totalCount());
    try t.expectEqual(before_pipelines, countPipelines(fixture));
    try t.expectEqualSlices(u32, separate_words, fragment.words);
}

fn countPipelines(fixture: *Fixture) usize {
    const io = fixture.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    return fixture.device.native.?.pipeline_store.?.queryPipelineCount(&guard);
}

test "external metadata native allocation refusal destroys the real buffer and restores child edges" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    defer fixture.release(plane);
    const before_handles = fixture.device.native.?.native_device.handles.totalCount();
    const before_references = plane.header.reference_count;
    const device = &fixture.device.native.?.native_device;
    const original = device.procs;
    var procs = original.*;
    const Failure = struct {
        fn allocate(_: vk.VkDevice, _: [*c]const vk.VkMemoryAllocateInfo, _: [*c]const vk.VkAllocationCallbacks, _: [*c]vk.VkDeviceMemory) callconv(.c) vk.VkResult {
            return vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        }
    };
    procs.allocate_memory = Failure.allocate;
    device.procs = &procs;
    defer device.procs = original;
    try t.expectError(error.OutOfDeviceMemory, fixture.device.createExternalTexture(allocator, fixture.threaded.io(), fixture.options(plane, null)));
    try t.expectEqual(before_handles, device.handles.totalCount());
    try t.expectEqual(before_references, plane.header.reference_count);
    try t.expectEqual(@as(u32, 1), plane.header.user_reference_count);
}

test "external browser copy applies independent gamma gamut flip origin and alpha conversion on GPU" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    var pixels: [64]u8 = undefined;
    for (0..16) |index| pixels[index * 4 ..][0..4].* = .{
        @intCast(16 + index * 4), @intCast(32 + index * 3),
        @intCast(48 + index * 2), @intCast(128 + index * 5),
    };
    pixels[13 * 4 ..][0..4].* = .{ 0, 0, 0, 0 };
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const options = fixture.options(plane, null);
    const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
    defer fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    const alpha_modes = [_]BrowserAlphaMode{ .premultiplied, .unpremultiplied };
    for (alpha_modes) |destination_alpha| {
        const browser: BrowserOptions = .{
            .flip_y = true,
            .needs_color_space_conversion = true,
            .src_alpha_mode = .premultiplied,
            .dst_alpha_mode = destination_alpha,
            .src_transfer_function_parameters = .{ 2, 1, 0, 1, 0, 0, 0 },
            .conversion_matrix = .{ 0.8, 0.1, 0.05, 0.15, 0.7, 0.1, 0.05, 0.15, 0.9 },
            .dst_transfer_function_parameters = identity_transfer,
        };
        var scene: Scene = undefined;
        try scene.init(&fixture);
        defer scene.deinit(&fixture);
        var session: Session = undefined;
        try session.begin(&fixture);
        defer session.deinit();
        try scene.drawBrowser(&session, source, sampling, .{
            .natural_size = .{ .width = extent, .height = extent },
            .source_origin = .{ .x = 1, .y = 0 },
            .copy_size = .{ .width = 2, .height = extent },
            .options = browser,
        });
        const serial = try session.submit();
        var expected: [16][4]f64 = undefined;
        for (0..extent) |row| for (0..extent) |column| {
            const source_pixel = ((extent - 1 - row) * extent + 1 + column / 2) * 4;
            const alpha = @as(f64, @floatFromInt(pixels[source_pixel + 3])) / 255;
            var decoded: [3]f64 = undefined;
            for (0..3) |channel| {
                var value = @as(f64, @floatFromInt(pixels[source_pixel + channel])) / 255;
                if (alpha != 0) value /= alpha;
                decoded[channel] = transfer(value, browser.src_transfer_function_parameters);
            }
            var result: [4]f64 = .{ 0, 0, 0, alpha };
            for (0..3) |channel| {
                var value: f64 = 0;
                for (0..3) |component| value += decoded[component] * browser.conversion_matrix[component * 3 + channel];
                result[channel] = transfer(value, browser.dst_transfer_function_parameters);
                if (destination_alpha == .premultiplied) result[channel] *= alpha;
            }
            expected[row * extent + column] = result;
        };
        try scene.expectPixels(&fixture, serial, &expected, 2.0 / 255.0);
    }
}

test "external browser copy preserves encoded bytes through a real sRGB render attachment" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const options = fixture.options(plane, null);
    const source = try fixture.device.createExternalTexture(allocator, fixture.threaded.io(), options);
    defer fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(allocator, fixture.threaded.io(), .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    var scene: Scene = undefined;
    try scene.initFormat(&fixture, .rgba8_unorm_srgb);
    defer scene.deinit(&fixture);
    var session: Session = undefined;
    try session.begin(&fixture);
    defer session.deinit();
    try scene.drawBrowser(&session, source, sampling, .{
        .natural_size = .{ .width = extent, .height = extent },
        .source_origin = .{},
        .copy_size = .{ .width = extent, .height = extent },
        .options = .{},
    });
    const serial = try session.submit();
    const expected = expectedOnePlane(&pixels, options);
    try scene.expectPixels(&fixture, serial, &expected, 2.0 / 255.0);
}

test "external prepare failure after real metadata emission poisons unaccepted recording" {
    var reached_emitted_failure = false;
    for (0..256) |failure_offset| {
        if (try externalPreparationFailure(failure_offset)) {
            reached_emitted_failure = true;
            break;
        }
    }
    try t.expect(reached_emitted_failure);
}

fn externalPreparationFailure(failure_offset: usize) !bool {
    var failing = t.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    var fixture: Fixture = .{};
    try fixture.init(failing.allocator());
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const source = try fixture.device.createExternalTexture(fixture.owner_allocator, io, fixture.options(plane, null));
    defer fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(fixture.owner_allocator, io, .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    var scene: Scene = undefined;
    try scene.init(&fixture);
    defer scene.deinit(&fixture);
    var session: Session = undefined;
    try session.begin(&fixture);
    defer session.deinit();
    const context = session.context();
    var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    query.setSampleCount(1);
    query.setColor(.{ .index = 0, .format = .rgba8_unorm, .load_op = .clear, .store_op = .store, .has_resolve_target = false, .render_to_single_sampled = false });
    const render_pass = try fixture.device.native.?.render_pass_cache.getRenderPass(io, query);
    var validated = try external.validateBrowserCopy(context, source, .{
        .natural_size = .{ .width = extent, .height = extent },
        .source_origin = .{},
        .copy_size = .{ .width = extent, .height = extent },
        .options = .{},
    });
    try t.expect(!source.params_buffer.native.is_data_initialized);
    try t.expect(!session.recording.needs_submit);
    const before_serial = context.queue.timeline.lastSubmittedSerial();
    failing.fail_index = failing.alloc_index + failure_offset;
    const prepared = external.prepareBrowserCopy(context, &validated, .{
        .ordinary_sampler = sampling,
        .compatible_render_pass = render_pass.render_pass,
        .attachments = scene.pass.attachmentState(),
    });
    failing.fail_index = std.math.maxInt(usize);
    if (prepared) |_| return false else |err| {
        try t.expectEqual(error.OutOfMemory, err);
        if (!session.recording.needs_submit or source.params_buffer.native.needsInitialization()) return false;
        // This is recorded initialization state, not proof of completed GPU output.
        try t.expect(!source.params_buffer.native.needsInitialization());
        try t.expect(context.queue.recording_poisoned);
        try t.expectEqual(@as(dusk.platform.Serial, 0), source.params_buffer.accepted_usage_serial);
        try t.expectEqual(before_serial, context.queue.timeline.lastSubmittedSerial());
        try t.expectError(error.RecordingPoisoned, session.submit());
        try t.expectEqual(before_serial, fixture.device.native.?.queue.timeline.lastSubmittedSerial());
        try t.expectEqual(@as(dusk.platform.Serial, 0), source.params_buffer.accepted_usage_serial);
        return true;
    }
}

test "external failure before its own metadata upload does not poison earlier real transfer work" {
    var fixture: Fixture = .{};
    try fixture.init(allocator);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const pixels = rgbaPattern();
    const plane = try fixture.plane(.rgba8_unorm, extent, &pixels);
    const source = try fixture.device.createExternalTexture(allocator, io, fixture.options(plane, null));
    defer fixture.release(source);
    fixture.release(plane);
    const sampling = try fixture.device.createSampler(allocator, io, .{ .compare = .undefined_ });
    defer fixture.release(sampling);
    var scene: Scene = undefined;
    try scene.init(&fixture);
    defer scene.deinit(&fixture);
    var session: Session = undefined;
    try session.begin(&fixture);
    defer session.deinit();
    const context = session.context();
    try context.pending_uses.retainDerivedRootLocked(&session.guard, context.device, &scene.readback.header);
    try scene.readback.native.transitionUsageNow(session.nativeRecording(), (api.BufferUsage{ .copy_dst = true }).toFlags(), .none);
    const fill = fixture.device.native.?.native_device.procs.cmd_fill_buffer orelse return error.MissingDeviceProc;
    fill(session.recording.command_buffer, scene.readback.native.getHandle(), 0, readback_size, 0x4e7b2d93);
    scene.readback.native.is_data_initialized = true;
    session.recording.needs_submit = true;
    try scene.readback.native.transitionUsageNow(session.nativeRecording(), (api.BufferUsage{ .map_read = true }).toFlags(), .none);
    var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    query.setSampleCount(1);
    query.setColor(.{ .index = 0, .format = .rgba8_unorm, .load_op = .clear, .store_op = .store, .has_resolve_target = false, .render_to_single_sampled = false });
    const render_pass = try fixture.device.native.?.render_pass_cache.getRenderPass(io, query);
    var validated = try external.validateBrowserCopy(context, source, .{
        .natural_size = .{ .width = extent, .height = extent },
        .source_origin = .{},
        .copy_size = .{ .width = extent, .height = extent },
        .options = .{},
    });
    try t.expect(source.params_buffer.native.needsInitialization());
    const device_procs = fixture.device.native.?.native_device.procs;
    const original_update_buffer = device_procs.cmd_update_buffer;
    defer device_procs.cmd_update_buffer = original_update_buffer;
    device_procs.cmd_update_buffer = null;
    try t.expectError(error.MissingDeviceProc, external.prepareBrowserCopy(context, &validated, .{
        .ordinary_sampler = sampling,
        .compatible_render_pass = render_pass.render_pass,
        .attachments = scene.pass.attachmentState(),
    }));
    device_procs.cmd_update_buffer = original_update_buffer;
    try t.expect(source.params_buffer.native.needsInitialization());
    try t.expect(session.recording.needs_submit);
    try t.expect(!context.queue.recording_poisoned);
    const serial = try session.submit();
    try fixture.device.wait(io, serial);
    try fixture.device.mapBuffer(io, scene.readback, .{ .mode = .{ .read = true }, .size = readback_size });
    defer fixture.device.unmapBuffer(io, scene.readback) catch @panic("earlier transfer unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, scene.readback.header.tracking);
    defer guard.unlock(io);
    const bytes = try scene.readback.native.getConstMappedRange(0, readback_size);
    for (0..readback_size / 4) |index| {
        try t.expectEqual(@as(u32, 0x4e7b2d93), std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little));
    }
}
