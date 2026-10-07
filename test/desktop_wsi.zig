//! Owned Xlib window: frontend render clears, accepted native submits, present and resize.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const command = dusk.command;
const surface_api = engine.surface;
const xlib = @import("vulkan_platform_linux");
const Encoder = command.command_encoder.CommandEncoder;
const Finished = command.encoding_context.Finished;

const Xlib = struct {
    library: dusk.platform.Loader = .{ .lib = undefined, .needs_close = false },
    open_display: *const @TypeOf(xlib.XOpenDisplay),
    default_screen: *const @TypeOf(xlib.XDefaultScreen),
    root_window: *const @TypeOf(xlib.XRootWindow),
    create_window: *const @TypeOf(xlib.XCreateSimpleWindow),
    store_name: *const @TypeOf(xlib.XStoreName),
    map_window: *const @TypeOf(xlib.XMapWindow),
    sync: *const @TypeOf(xlib.XSync),
    resize_window: *const @TypeOf(xlib.XResizeWindow),
    attributes: *const @TypeOf(xlib.XGetWindowAttributes),
    destroy_window: *const @TypeOf(xlib.XDestroyWindow),
    close_display: *const @TypeOf(xlib.XCloseDisplay),

    fn load(allocator: std.mem.Allocator) !Xlib {
        var library: dusk.platform.Loader = .{ .lib = undefined, .needs_close = false };
        try library.open(allocator, .{ .path = "libX11.so.6" });
        errdefer library.close();
        return .{
            .library = library,
            .open_display = try symbol(&library, "XOpenDisplay"),
            .default_screen = try symbol(&library, "XDefaultScreen"),
            .root_window = try symbol(&library, "XRootWindow"),
            .create_window = try symbol(&library, "XCreateSimpleWindow"),
            .store_name = try symbol(&library, "XStoreName"),
            .map_window = try symbol(&library, "XMapWindow"),
            .sync = try symbol(&library, "XSync"),
            .resize_window = try symbol(&library, "XResizeWindow"),
            .attributes = try symbol(&library, "XGetWindowAttributes"),
            .destroy_window = try symbol(&library, "XDestroyWindow"),
            .close_display = try symbol(&library, "XCloseDisplay"),
        };
    }

    fn symbol(library: *dusk.platform.Loader, comptime name: [:0]const u8) !*const @TypeOf(@field(xlib, name)) {
        return @ptrCast(library.lookup(name) orelse return error.XlibSymbolMissing);
    }
};

const Frame = struct {
    texture: *engine.texture.Texture,
    view: *engine.texture.TextureView,
    serial: u64,

    fn release(self: Frame, allocator: std.mem.Allocator, io: std.Io, device: *engine.Device) void {
        device.release(allocator, io, self.view) catch @panic("WSI view release failed");
        device.release(allocator, io, self.texture) catch @panic("WSI texture release failed");
    }
};

fn deinitEncoder(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device, encoder: *Encoder) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    encoder.deinit(allocator, io, &guard);
}

fn deinitFinished(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device, finished: *Finished) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    finished.deinit(allocator, io, &guard);
}

fn draw(
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: *engine.Instance,
    device: *engine.Device,
    surface: api.Surface,
    config: api.descriptors.SurfaceConfigurationChain,
    color: api.Color,
) !Frame {
    var acquired: api.SurfaceTexture = .{ .texture = .{}, .status = .timeout };
    try surface_api.getCurrentTexture(allocator, io, instance, surface, &acquired);
    switch (acquired.status) {
        .success_optimal, .success_suboptimal => {},
        .timeout => return error.SurfaceAcquireTimeout,
        .outdated => return error.SurfaceOutdated,
        .lost => return error.SurfaceLost,
        else => return error.SurfaceAcquireFailed,
    }
    const texture = blk: {
        var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
        defer guard.unlock(io);
        break :blk try engine.texture.resolveTexture(&device.core, &guard, acquired.texture);
    };
    errdefer device.release(allocator, io, texture) catch @panic("acquired texture rollback failed");
    const view = try device.createTextureView(allocator, io, .{
        .texture = texture,
        .descriptor = .{ .format = config.format, .dimension = ._2d },
    });
    errdefer device.release(allocator, io, view) catch @panic("acquired view rollback failed");
    var encoder = Encoder.init(allocator, device.core.borrow(), .{});
    defer deinitEncoder(allocator, io, device, &encoder);
    var pass = try device.beginRenderPass(allocator, io, &encoder, .{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = color,
        }},
        .depth_stencil_attachment = .{},
        .width = config.width,
        .height = config.height,
    });
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        defer pass.deinit(io, &guard);
        try pass.end(io, &guard);
    }
    const row_bytes = std.mem.alignForward(u64, @as(u64, config.width) * 4, 256);
    const readback_size = row_bytes * config.height;
    const readback = try device.createBuffer(allocator, io, .{
        .size = readback_size,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer device.release(allocator, io, readback) catch @panic("WSI readback release failed");
    {
        var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        // Readonly GPU evidence: this copy never paints or replaces the swapchain image.
        try encoder.copyTextureToBuffer(.{
            .source = .{
                .texture = texture,
                .format = @intFromEnum(config.format),
                .dimension = ._2d,
                .aspect = .all,
                .extent = .{ .width = config.width, .height = config.height, .depth_or_array_layers = 1 },
            },
            .destination = .{
                .buffer = try readback.ref(&guard),
                .blocks_per_row = @intCast(row_bytes / 4),
                .rows_per_image = config.height,
            },
            .copy_size = .{ .width = config.width, .height = config.height, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer deinitFinished(allocator, io, device, &finished);
    // Device.submit replays Finished through the real native context and Queue.submit.
    const serial = try device.submit(allocator, io, &finished);
    if (serial == 0) return error.SubmissionNotAccepted;
    if (try surface_api.present(io, instance, surface) != .success) return error.PresentFailed;
    try device.wait(io, serial);
    try verifyPixels(io, device, readback, serial, config, color, row_bytes, readback_size);
    return .{ .texture = texture, .view = view, .serial = serial };
}

fn verifyPixels(
    io: std.Io,
    device: *engine.Device,
    readback: *engine.native_resources.Buffer,
    serial: u64,
    config: api.descriptors.SurfaceConfigurationChain,
    color: api.Color,
    row_bytes: u64,
    readback_size: u64,
) !void {
    defer device.unmapBuffer(io, readback) catch @panic("WSI readback unmap failed");
    const context = device.native.?;
    context.queue_operation_mutex.lockUncancelable(io);
    defer context.queue_operation_mutex.unlock(io);
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = readback_size });
    if (try readback.native.completeMap(generation, serial) != .mapped) return error.ReadbackMapFailed;
    const bytes = try readback.native.getConstMappedRange(0, readback_size);
    const rgba: [4]u8 = .{
        @intFromFloat(color.r * 255), @intFromFloat(color.g * 255),
        @intFromFloat(color.b * 255), @intFromFloat(color.a * 255),
    };
    const expected: [4]u8 = switch (config.format) {
        .rgba8_unorm, .rgba8_unorm_srgb => rgba,
        .bgra8_unorm, .bgra8_unorm_srgb => .{ rgba[2], rgba[1], rgba[0], rgba[3] },
        else => return error.SurfaceReadbackFormatUnsupported,
    };
    for (0..config.height) |y| {
        for (0..config.width) |x| {
            const offset: usize = @intCast(y * row_bytes + x * 4);
            if (!std.mem.eql(u8, &expected, bytes[offset..][0..4])) return error.SurfaceReadbackPixelMismatch;
        }
    }
}

fn awaitExtent(io: std.Io, x: *const Xlib, display: *xlib.Display, window: xlib.Window, width: u32, height: u32) !void {
    // XSync processes our resize request; bounded polling also observes WM-managed resize.
    for (0..100) |_| {
        _ = x.sync(display, 0);
        var attributes: xlib.XWindowAttributes = undefined;
        if (x.attributes(display, window, &attributes) == 0) return error.XlibWindowUnavailable;
        if (attributes.width == @as(c_int, @intCast(width)) and
            attributes.height == @as(c_int, @intCast(height)) and
            attributes.map_state == xlib.IsViewable) return;
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    return error.XlibWindowResizeTimeout;
}

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("desktop WSI reported an uncaptured error");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var x = try Xlib.load(allocator);
    defer x.library.close();
    const display = x.open_display(null) orelse return error.XlibDisplayUnavailable;
    defer _ = x.close_display(display);
    const screen = x.default_screen(display);
    const window = x.create_window(display, x.root_window(display, screen), 0, 0, 640, 480, 0, 0, 0);
    if (window == 0) return error.XlibWindowCreateFailed;
    // These host objects outlive every Surface, native surface, swapchain and image-view alias.
    defer _ = x.destroy_window(display, window);
    _ = x.store_name(display, window, "Dusk native WSI proof");
    _ = x.map_window(display, window);
    try awaitExtent(io, &x, display, window, 640, 480);

    var instance = engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("WSI instance teardown failed");
    const surface = try surface_api.create(allocator, io, &instance, &.{
        .label = "Dusk native WSI proof",
        .surface_source_xlib_window = .{ .display = @ptrCast(display), .window = @intCast(window) },
    });
    var surface_live = true;
    defer if (surface_live) surface_api.release(io, &instance, surface) catch @panic("WSI surface teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .compatible_surface = surface,
    });
    defer adapters.deinit(io) catch @panic("WSI adapter teardown failed");
    if (adapters.items.len == 0) return error.NoPresentableAdapter;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &instance,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("WSI device teardown failed");
    // Error cleanup must detach the Surface before Device's final preflight.
    defer if (surface_live) surface_api.unconfigure(io, &instance, surface) catch @panic("WSI unconfigure failed");
    var caps: api.SurfaceCapabilities = .{
        .usages = .{}, .format_count = 0, .present_mode_count = 0, .alpha_mode_count = 0,
    };
    if (try surface_api.getCapabilities(allocator, io, &instance, surface, &adapters.items[0], &caps) != .success)
        return error.SurfaceCapabilitiesFailed;
    defer if (caps.formats) |formats| allocator.free(formats);
    defer if (caps.present_modes) |modes| allocator.free(modes);
    defer if (caps.alpha_modes) |modes| allocator.free(modes);
    const formats = caps.formats orelse return error.NoSurfaceFormats;
    const alpha_modes = caps.alpha_modes orelse return error.NoSurfaceAlphaModes;
    if (formats.len == 0 or alpha_modes.len == 0) return error.NoSurfaceFormats;
    if (!caps.usages.render_attachment or !caps.usages.copy_src) return error.SurfaceReadbackUsageUnsupported;
    const format = blk: {
        for (formats) |candidate| {
            switch (candidate) {
                .rgba8_unorm, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb => break :blk candidate,
                else => {},
            }
        }
        return error.SurfaceReadbackFormatUnsupported;
    };
    var config: api.descriptors.SurfaceConfigurationChain = .{
        .device = engine.native_async_handles.exportDevice(&device),
        .format = format,
        .usage = .{ .render_attachment = true, .copy_src = true },
        .width = 640,
        .height = 480,
        .alpha_mode = alpha_modes[0],
        .present_mode = .fifo,
    };
    try surface_api.configure(allocator, io, &instance, surface, &config);
    const red = try draw(allocator, io, &instance, &device, surface, config, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    var red_live = true;
    defer if (red_live) red.release(allocator, io, &device);
    std.log.info("native WSI red presented: accepted serial {d}", .{red.serial});
    try std.Io.sleep(io, .fromMilliseconds(5000), .awake);
    const blue = try draw(allocator, io, &instance, &device, surface, config, .{ .r = 0, .g = 0, .b = 1, .a = 1 });
    var blue_live = true;
    defer if (blue_live) blue.release(allocator, io, &device);
    if (blue.serial <= red.serial) return error.SubmissionSerialNotIncreasing;
    std.log.info("native WSI blue presented: accepted serial {d}", .{blue.serial});
    try std.Io.sleep(io, .fromMilliseconds(5000), .awake);

    _ = x.resize_window(display, window, 800, 600);
    try awaitExtent(io, &x, display, window, 800, 600);
    config.width = 800;
    config.height = 600;
    // Old public texture/view aliases remain live while the new generation is configured.
    try surface_api.configure(allocator, io, &instance, surface, &config);
    const resized = try draw(allocator, io, &instance, &device, surface, config, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    var resized_live = true;
    defer if (resized_live) resized.release(allocator, io, &device);
    if (resized.serial <= blue.serial) return error.SubmissionSerialNotIncreasing;
    std.log.info("native WSI resized red presented: 800x600, accepted serial {d}", .{resized.serial});
    red.release(allocator, io, &device);
    red_live = false;
    try std.Io.sleep(io, .fromMilliseconds(5000), .awake);
    resized.release(allocator, io, &device);
    resized_live = false;
    blue.release(allocator, io, &device);
    blue_live = false;
    try surface_api.unconfigure(io, &instance, surface);
    try surface_api.release(io, &instance, surface);
    surface_live = false;
}
