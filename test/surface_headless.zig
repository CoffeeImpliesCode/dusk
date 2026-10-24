//! The M20 shard: a surface request on a host with no display server.
//!
//! It asks for a surface and asserts three things: the call returns
//! `error.SurfaceUnavailable`, the message names the missing environment,
//! and no Vulkan handle was created.
//!
//! **The import is `@import("dusk")`.** The published module exposes `platform`
//! through `src/root.zig`, and this shard reaches the library through it like
//! every other acceptance shard.

const std = @import("std");

const platform = @import("dusk").platform;
const SurfaceError = platform.SurfaceError;
const Source = platform.Source;
const Surface = platform.Surface;
const SourceType = platform.SourceType;
const SurfaceRequest = platform.SurfaceRequest;

/// A Wayland surface whose two objects the caller supplied. It passes every
/// descriptor rule (`Surface.cpp:186-187` only asks that neither is null), so
/// the refusal is the Vulkan one and not a descriptor rule.
const wayland_request: SurfaceRequest = .{
    .source = .{ .wayland_surface = .{
        .display = @ptrFromInt(0x2000),
        .surface = @ptrFromInt(0x3000),
    } },
};

/// An Xlib surface with a live display, which stands in for the `Display*` and
/// `Window` an application on an X server passes (`dawn.json` "surface source
/// xlib window").
const xlib_request: SurfaceRequest = .{
    .source = .{ .xlib_window = .{ .display = @ptrFromInt(0x1000), .window = 1 } },
};

test "every member of the surface error set has a message" {
    inline for (@typeInfo(SurfaceError).error_set.error_names.?) |member| {
        const text = platform.surfaceMessage(@field(SurfaceError, member));
        try std.testing.expect(text.len > 0);
    }
}

test "the surface error set is the fourteen rules the port declares" {
    // A member added to `SurfaceError` lands here without a second edit, and
    // one removed fails. The count is the sweep's own census.
    try std.testing.expectEqual(
        @as(usize, 14),
        @typeInfo(SurfaceError).error_set.error_names.?.len,
    );
}

test "a surface request on this host returns error.SurfaceUnavailable" {
    var handle: platform.VkSurfaceHandle = platform.null_surface_handle;

    try std.testing.expectError(
        error.SurfaceUnavailable,
        platform.createSurface(wayland_request, null, &handle),
    );

    // The handle. Dawn declares it as a function local initialised to
    // `VK_NULL_HANDLE` and returns it only inside a success arm
    // (`SwapChainVk.cpp:735`, `:758`), so nothing was born and nothing was
    // destroyed. The out-slot carries the same fact, and it is what a caller
    // can observe.
    try std.testing.expectEqual(platform.null_surface_handle, handle);
}

test "the message names the missing environment" {
    const text = platform.surfaceMessage(error.SurfaceUnavailable);
    try std.testing.expect(std.mem.indexOf(u8, text, "DISPLAY") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WAYLAND_DISPLAY") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "VK_KHR_display") != null);
}

test "the message does not blame an extension the host may have" {
    const text = platform.surfaceMessage(error.SurfaceUnavailable);
    try std.testing.expect(std.mem.indexOf(u8, text, "VK_EXT_headless_surface") == null);
}

test "the message does not blame libX11, and that rule has its own name" {
    // `X11Functions.cpp:37` loads `libX11.so.6`, and upstream's
    // `"Couldn't load libX11."` (`Surface.cpp:200`) is the rule that does not
    // fire on a host where the library is installed. It still exists.
    const text = platform.surfaceMessage(error.SurfaceUnavailable);
    try std.testing.expect(std.mem.indexOf(u8, text, "libX11") == null);
    try std.testing.expectEqualStrings(
        "could not load libX11",
        platform.surfaceMessage(error.X11LibraryMissing),
    );
}

test "every source type but the xlib one reaches the one terminal and leaves the slot null" {
    // Dawn's switch (`SwapChainVk.cpp:643-770`) has five `#if`-guarded arms
    // and a `default: break`, and every arm that does not take its gate ends
    // at the one error at `:774`. The port has nine arms and the same one
    // terminal, and this row says so for eight of the nine at once rather
    // than for the one a caller happened to name.
    //
    // The ninth is the Xlib arm, and it is out of this sweep because it is
    // the only arm with a live precondition: with no loaded table it stops at
    // `error.X11LibraryMissing` and never reaches the terminal
    // (`src/platform/surface.zig:426-428`). `X11Functions.init` cannot supply
    // that table here: nothing in this build links libc, so `std.DynLib` is
    // the libc-less one and resolves a bare name through `/lib` and `/usr/lib`
    // (`lib/std/dynamic_library.zig:217-220`), while libX11 is in `/usr/lib64`
    // on this host. Keeping the arm and demanding the table would be red for
    // a fact about the host and not about the port; dropping it to stay green
    // would leave the row naming nine and sweeping eight. So the row names
    // eight, and the arm keeps the two rows that own it: `an xlib request
    // without libX11 names the library` and `with libX11 loaded, the same
    // xlib request is still unavailable`, which between them name both
    // outcomes of `:426-428`.
    const sources = [_]Source{
        .{ .wayland_surface = .{
            .display = @ptrFromInt(0x2000),
            .surface = @ptrFromInt(0x3000),
        } },
        .{ .android_native_window = @ptrFromInt(0x4000) },
        .{ .metal_layer = @ptrFromInt(0x5000) },
        .{ .windows_hwnd = .{ .instance = @ptrFromInt(0x6000), .hwnd = 7 } },
        .{ .windows_core_window = @ptrFromInt(0x7000) },
        .{ .windows_uwp_swap_chain_panel = @ptrFromInt(0x8000) },
        .{ .windows_winui_swap_chain_panel = @ptrFromInt(0x9000) },
        .unspecified,
    };

    for (sources) |source| {
        var handle: platform.VkSurfaceHandle = platform.null_surface_handle;
        const subject: Surface = .{ .source = source };
        try std.testing.expectError(
            error.SurfaceUnavailable,
            platform.createVulkanSurface(&subject, null, &handle),
        );
        try std.testing.expectEqual(platform.null_surface_handle, handle);
    }
}

test "a source with no display server is refused before any Vulkan call" {
    // The two arms whose payload can be null, so the descriptor rules at
    // `Surface.cpp:186-187` and the Xlib arm both fire.
    try std.testing.expectError(error.SurfaceUnavailable, platform.validateSurfaceDescriptor(.{
        .source = .{ .xlib_window = .{ .display = null, .window = 1 } },
    }));
    try std.testing.expectError(error.SurfaceUnavailable, platform.validateSurfaceDescriptor(.{
        .source = .{ .wayland_surface = .{ .display = null, .surface = null } },
    }));
}

test "a null compositor with a live display is a missing surface, not a missing display" {
    // `Surface.cpp:186` and `:187` are two rules, and only the first is about
    // the environment. A wayland source with a display and no surface is a
    // malformed descriptor, not a headless host.
    try std.testing.expectError(error.WaylandSurfaceIsNull, platform.validateSurfaceDescriptor(.{
        .source = .{ .wayland_surface = .{ .display = @ptrFromInt(0x2000), .surface = null } },
    }));
}

test "an empty chain and a colour management chain are refused" {
    try std.testing.expectError(error.DescriptorChainEmpty, platform.validateSurfaceDescriptor(.{
        .source = null,
    }));
    try std.testing.expectError(
        error.SurfaceColorManagementUnsupported,
        platform.validateSurfaceDescriptor(.{
            .source = wayland_request.source,
            .color_management = true,
        }),
    );
}

test "the out-slot is untouched by a request that fails validation" {
    // `createSurface` writes the null handle before it validates, so a caller
    // can read the slot after any outcome. In Dawn the descriptor is checked
    // first (`Surface.cpp:102`) and no Vulkan slot exists at that point.
    var handle: platform.VkSurfaceHandle = platform.null_surface_handle;
    try std.testing.expectError(error.DescriptorChainEmpty, platform.createSurface(.{
        .source = null,
    }, null, &handle));
    try std.testing.expectEqual(platform.null_surface_handle, handle);
}

test "an xlib request without libX11 names the library" {
    // Upstream's `"Couldn't load libX11."` (`Surface.cpp:200`), reached through
    // `Surface.cpp:199`. The libraries are installed here, so this row passes
    // null to reach the rule; it is the one arm of `createVulkanSurface` whose
    // precondition the port can still ask about, because libX11 is the only
    // window-system dependency Dawn loads as a shared library
    // (`X11Functions.cpp:37`).
    var handle: platform.VkSurfaceHandle = platform.null_surface_handle;
    try std.testing.expectError(
        error.X11LibraryMissing,
        platform.createSurface(xlib_request, null, &handle),
    );
    try std.testing.expectEqual(platform.null_surface_handle, handle);
}

test "with libX11 loaded, the same xlib request is still unavailable" {
    // Whether `libX11.so.6` is installed is a host fact, so both arms of the
    // pair are asserted and neither is skipped. A host without the library
    // gets `X11LibraryMissing`; a host with it gets `SurfaceUnavailable`.
    // There is no third outcome and there is no pass-by-skip.
    var x11: platform.X11Functions = undefined;
    platform.X11Functions.init(std.testing.allocator, &x11) catch |err| switch (err) {
        error.LibraryMissing, error.XcbLibraryMissing, error.SymbolMissing => {
            var handle: platform.VkSurfaceHandle = platform.null_surface_handle;
            try std.testing.expectError(
                error.X11LibraryMissing,
                platform.createSurface(xlib_request, &x11, &handle),
            );
            return;
        },
    };
    defer x11.deinit();

    try std.testing.expect(x11.isX11Loaded());
    try std.testing.expect(x11.isX11XcbLoaded());

    var handle: platform.VkSurfaceHandle = platform.null_surface_handle;
    try std.testing.expectError(
        error.SurfaceUnavailable,
        platform.createSurface(xlib_request, &x11, &handle),
    );
    try std.testing.expectEqual(platform.null_surface_handle, handle);
}

test "the nine source types have nine names and every name round-trips" {
    // `AbslFormatConvert` (`Surface.cpp:59-93`) is the only formatter upstream
    // has for the sum type, and a collision would make `fromName` return the
    // wrong type.
    inline for (@typeInfo(SourceType).@"enum".field_values) |field_value| {
        const source_type: SourceType = @fromBackingInt(@intCast(field_value));
        try std.testing.expectEqual(source_type, SourceType.fromName(source_type.name()).?);
    }
    try std.testing.expectEqual(@as(?SourceType, null), SourceType.fromName("NoSuchSurface"));
}

test "a typed accessor refuses a surface of another type" {
    // Upstream asserts (`Surface.cpp:395-457`, `DAWN_CHECK(mType == Type::…)`).
    // The port reports, because a library has no caller to assert at.
    const surface: Surface = .{ .source = .{ .xlib_window = .{
        .display = @ptrFromInt(0x1000),
        .window = 7,
    } } };

    try std.testing.expectEqual(@as(u64, 7), try surface.getXWindow());
    try std.testing.expectError(error.WrongSurfaceType, surface.getWaylandDisplay());
    try std.testing.expectError(error.WrongSurfaceType, surface.getMetalLayer());
    try std.testing.expectError(error.WrongSurfaceType, surface.getHInstance());
    try std.testing.expectError(error.WrongSurfaceType, surface.getCoreWindow());
}

test "the xlib accessors read the caller's display and window" {
    const display: *anyopaque = @ptrFromInt(0x1000);
    const surface: Surface = .{ .source = .{ .xlib_window = .{
        .display = display,
        .window = 4242,
    } } };

    try std.testing.expectEqual(display, try surface.getXDisplay());
    try std.testing.expectEqual(@as(u64, 4242), try surface.getXWindow());
    try std.testing.expectEqual(SourceType.xlib_window, surface.sourceType());
}

test "a zero X window is invalid and a null display is unavailable" {
    // `Surface.cpp:210` is `"Invalid X Window"`, reached when the display is
    // live and the window is not. The port cannot call `xGetWindowAttributes`
    // to prove it (`tools/gen_dispatch.zig:40-44` records that no X11 header
    // is vendored), so a zero window is the whole of the check.
    try std.testing.expectError(error.InvalidXWindow, platform.validateSurfaceDescriptor(.{
        .source = .{ .xlib_window = .{ .display = @ptrFromInt(0x1000), .window = 0 } },
    }));
}

test "the windows and android rules refuse an empty payload" {
    // `Surface.cpp:125`, `:143`, `:153-156`, `:164-167` and `:176`.
    try std.testing.expectError(
        error.AndroidWindowNotSet,
        platform.validateSurfaceDescriptor(.{ .source = .{ .android_native_window = null } }),
    );
    try std.testing.expectError(
        error.LayerNotMetalLayer,
        platform.validateSurfaceDescriptor(.{ .source = .{ .metal_layer = null } }),
    );
    try std.testing.expectError(
        error.InvalidHwnd,
        platform.validateSurfaceDescriptor(.{ .source = .{ .windows_hwnd = .{
            .instance = null,
            .hwnd = 0,
        } } }),
    );
    try std.testing.expectError(
        error.InvalidCoreWindow,
        platform.validateSurfaceDescriptor(.{ .source = .{ .windows_core_window = null } }),
    );
    try std.testing.expectError(
        error.InvalidSwapChainPanel,
        platform.validateSurfaceDescriptor(.{ .source = .{ .windows_uwp_swap_chain_panel = null } }),
    );
    try std.testing.expectError(
        error.WinUISwapChainPanelIsNull,
        platform.validateSurfaceDescriptor(.{
            .source = .{ .windows_winui_swap_chain_panel = null },
        }),
    );
}

test "a descriptor with no source names no supported source" {
    // Upstream's `default:` arm (`Surface.cpp:214-215`) reports
    // `"Unsupported sType (%s)"`. The port's `unspecified` arm is the same
    // place, and `ValidateBranches` never returns it upstream.
    try std.testing.expectError(
        error.UnsupportedSurfaceSource,
        platform.validateSurfaceDescriptor(.{ .source = .unspecified }),
    );
}
