//! NativeActivity proof. All host windows come from Android callbacks; no offscreen substitute.
const std = @import("std");
const dusk = @import("dusk");
const ndk = @import("android_platform");
const ahb = @import("android_ahb_roundtrip.zig");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const surface_api = engine.surface;
const handles = engine.native_async_handles;
const Encoder = dusk.command.command_encoder.CommandEncoder;
const Finished = dusk.command.encoding_context.Finished;
const allocator = std.heap.page_allocator;

const Color = enum { red, blue };

// Android invokes these callbacks on its main thread. Nothing can retain a window
// after onNativeWindowDestroyed returns: teardown drains presentation first.
const Activity = struct {
    threaded: std.Io.Threaded,
    session: ?*Session = null,
    ahb_complete: bool = false,
};

const Session = struct {
    instance: engine.Instance,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    surface: api.Surface = .{ .handle = null },
    window: *ndk.ANativeWindow,
    format: api.TextureFormat = .undefined_,
    alpha: api.CompositeAlphaMode = .auto,
    width: u32 = 0,
    height: u32 = 0,
    color: Color = .red,

    fn init(self: *Session, io: std.Io, window: *ndk.ANativeWindow) !void {
        self.* = .{ .instance = .init(.{ .backend_type = .vulkan }), .window = window };
        errdefer self.instance.deinit(allocator, io) catch @panic("Android instance rollback failed");
        self.surface = try surface_api.create(allocator, io, &self.instance, &.{
            .label = "Android NativeActivity WSI",
            .surface_source_android_native_window = .{ .window = @ptrCast(window) },
        });
        errdefer surface_api.release(io, &self.instance, self.surface) catch @panic("Android surface rollback failed");
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .power_preference = .undefined_,
            .compatible_surface = self.surface,
        });
        errdefer self.adapters.deinit(io) catch @panic("Android adapter rollback failed");
        if (self.adapters.items.len == 0) return error.NoPresentableAndroidAdapter;
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
        errdefer self.device.deinit(allocator, io) catch @panic("Android device rollback failed");
        var caps: api.SurfaceCapabilities = .{
            .usages = .{},
            .format_count = 0,
            .present_mode_count = 0,
            .alpha_mode_count = 0,
        };
        _ = try surface_api.getCapabilities(allocator, io, &self.instance, self.surface, &self.adapters.items[0], &caps);
        defer {
            if (caps.formats) |values| allocator.free(values);
            if (caps.present_modes) |values| allocator.free(values);
            if (caps.alpha_modes) |values| allocator.free(values);
        }
        if (!caps.usages.render_attachment) return error.AndroidRenderAttachmentUnsupported;
        const formats = caps.formats orelse return error.NoAndroidSurfaceFormat;
        if (formats.len == 0) return error.NoAndroidSurfaceFormat;
        self.format = formats[0];
        const alpha_modes = caps.alpha_modes orelse return error.NoAndroidAlphaMode;
        if (alpha_modes.len == 0) return error.NoAndroidAlphaMode;
        self.alpha = alpha_modes[0];
        try self.resize(io);
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("Android WSI reported an uncaptured GPU error");
    }

    fn resize(self: *Session, io: std.Io) !void {
        const width = ndk.ANativeWindow_getWidth(self.window);
        const height = ndk.ANativeWindow_getHeight(self.window);
        if (width <= 0 or height <= 0) return error.InvalidAndroidWindowExtent;
        try surface_api.configure(allocator, io, &self.instance, self.surface, &.{
            .device = handles.exportDevice(&self.device),
            .format = self.format,
            .width = @intCast(width),
            .height = @intCast(height),
            .alpha_mode = self.alpha,
            .present_mode = .fifo,
        });
        self.width = @intCast(width);
        self.height = @intCast(height);
    }

    fn deinitEncoder(self: *Session, io: std.Io, encoder: *Encoder) void {
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(allocator, io, &guard);
    }

    fn deinitFinished(self: *Session, io: std.Io, finished: *Finished) void {
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(allocator, io, &guard);
    }

    fn draw(self: *Session, io: std.Io, color: Color) !void {
        var current: api.SurfaceTexture = .{ .texture = .{ .handle = null }, .status = .error_ };
        try surface_api.getCurrentTexture(allocator, io, &self.instance, self.surface, &current);
        if (current.status != .success_optimal and current.status != .success_suboptimal)
            return error.AndroidSurfaceAcquireFailed;
        const texture: *engine.texture.Texture = blk: {
            var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
            defer guard.unlock(io);
            break :blk try engine.texture.resolveTexture(&self.device.core, &guard, current.texture);
        };
        defer self.device.release(allocator, io, texture) catch @panic("Android acquired texture release failed");
        const view = try self.device.createTextureView(allocator, io, .{
            .texture = texture,
            .descriptor = .{ .format = self.format, .dimension = ._2d },
        });
        defer self.device.release(allocator, io, view) catch @panic("Android acquired view release failed");
        var encoder = Encoder.init(allocator, self.device.core.borrow(), .{});
        defer self.deinitEncoder(io, &encoder);
        var pass = try self.device.beginRenderPass(allocator, io, &encoder, .{
            .color_attachments = &.{.{
                .view = view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = switch (color) {
                    .red => .{ .r = 1, .g = 0, .b = 0, .a = 1 },
                    .blue => .{ .r = 0, .g = 0, .b = 1, .a = 1 },
                },
            }},
            .depth_stencil_attachment = .{},
            .width = self.width,
            .height = self.height,
        });
        {
            var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
            defer guard.unlock(io);
            defer pass.deinit(io, &guard);
            try pass.end(io, &guard);
        }
        var finished = try encoder.finish();
        defer self.deinitFinished(io, &finished);
        const serial = try self.device.submit(allocator, io, &finished);
        if (try surface_api.present(io, &self.instance, self.surface) != .success)
            return error.AndroidPresentFailed;
        try self.device.wait(io, serial);
        self.color = color;
        marker(switch (color) {
            .red => "WSI_PRESENT_RED",
            .blue => "WSI_PRESENT_BLUE",
        });
    }

    fn deinit(self: *Session, io: std.Io) !void {
        // unconfigure includes submit-serial drain and present-queue idle.
        try surface_api.unconfigure(io, &self.instance, self.surface);
        try surface_api.release(io, &self.instance, self.surface);
        try self.device.deinit(allocator, io);
        try self.adapters.deinit(io);
        try self.instance.deinit(allocator, io);
        marker("WSI_DRAIN_DESTROY_COMPLETE");
    }
};

fn marker(text: [:0]const u8) void {
    _ = ndk.__android_log_write(ndk.ANDROID_LOG_INFO, "DuskNativeProof", text.ptr);
}

fn state(activity: [*c]ndk.ANativeActivity) *Activity {
    return @ptrCast(@alignCast(activity.*.instance.?));
}

fn failed(activity: [*c]ndk.ANativeActivity, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buffer, "NATIVE_PROOF_FAILED {s}", .{@errorName(err)}, 0) catch unreachable;
    _ = ndk.__android_log_write(ndk.ANDROID_LOG_ERROR, "DuskNativeProof", message.ptr);
    ndk.ANativeActivity_finish(activity);
}

fn windowCreated(activity: [*c]ndk.ANativeActivity, window: ?*ndk.ANativeWindow) callconv(.c) void {
    const app = state(activity);
    const native_window = window orelse return failed(activity, error.NullNativeWindow);
    if (app.session != null) @panic("Android delivered overlapping native windows");
    const session = allocator.create(Session) catch |err| return failed(activity, err);
    session.init(app.threaded.io(), native_window) catch |err| {
        allocator.destroy(session);
        return failed(activity, err);
    };
    app.session = session;
    session.draw(app.threaded.io(), .red) catch |err| return failed(activity, err);
    if (!app.ahb_complete) {
        ahb.run(allocator, app.threaded.io()) catch |err| return failed(activity, err);
        app.ahb_complete = true;
        marker("AHB_ROUNDTRIP_COMPLETE");
    }
}

fn windowResized(activity: [*c]ndk.ANativeActivity, window: ?*ndk.ANativeWindow) callconv(.c) void {
    const app = state(activity);
    const session = app.session orelse return;
    if (window != session.window) @panic("Android resize window identity mismatch");
    session.resize(app.threaded.io()) catch |err| return failed(activity, err);
    session.draw(app.threaded.io(), .blue) catch |err| return failed(activity, err);
    marker("WSI_RESIZE_RECONFIGURE_COMPLETE");
}

fn windowRedraw(activity: [*c]ndk.ANativeActivity, window: ?*ndk.ANativeWindow) callconv(.c) void {
    const app = state(activity);
    const session = app.session orelse return;
    if (window != session.window) @panic("Android redraw window identity mismatch");
    session.draw(app.threaded.io(), session.color) catch |err| return failed(activity, err);
}

fn windowDestroyed(activity: [*c]ndk.ANativeActivity, window: ?*ndk.ANativeWindow) callconv(.c) void {
    const app = state(activity);
    const session = app.session orelse return;
    if (window != session.window) @panic("Android destroy window identity mismatch");
    session.deinit(app.threaded.io()) catch @panic("Android native window drain failed");
    allocator.destroy(session);
    app.session = null;
}

fn destroyed(activity: [*c]ndk.ANativeActivity) callconv(.c) void {
    const app = state(activity);
    if (app.session != null) @panic("Android Activity destroyed before its native window");
    app.threaded.deinit();
    activity.*.instance = null;
    allocator.destroy(app);
}

pub export fn ANativeActivity_onCreate(activity: [*c]ndk.ANativeActivity, saved_state: ?*anyopaque, saved_state_size: usize) callconv(.c) void {
    _ = saved_state;
    _ = saved_state_size;
    if (activity == null or activity.*.callbacks == null) @panic("Invalid Android NativeActivity");
    const app = allocator.create(Activity) catch |err| return failed(activity, err);
    app.* = .{ .threaded = .init(allocator, .{}) };
    activity.*.instance = app;
    const callbacks = activity.*.callbacks;
    callbacks.*.onNativeWindowCreated = windowCreated;
    callbacks.*.onNativeWindowResized = windowResized;
    callbacks.*.onNativeWindowRedrawNeeded = windowRedraw;
    callbacks.*.onNativeWindowDestroyed = windowDestroyed;
    callbacks.*.onDestroy = destroyed;
    marker("NATIVE_ACTIVITY_CREATED");
}
