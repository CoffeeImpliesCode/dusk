//! Surfaces: the nine-way window-system sum type, its rules, and the negative.
//!
//! **What this file is.** The port of `src/dawn/native/Surface.{h,cpp}` and of
//! `vulkan::CreateVulkanSurface` (`src/dawn/native/vulkan/SwapChainVk.cpp:633`)
//! at Dawn revision `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`.
//!
//! **What this file does not claim.** It does not claim a window system. The
//! host has no `DISPLAY` and no `WAYLAND_DISPLAY` (`docs/50-verification.md:30-31`,
//! grade A), and no configuration on this machine carries both
//! `VK_KHR_display` and `VK_EXT_headless_surface`
//! (`docs/50-verification.md:44-82`). So the observable result of the whole
//! path is negative, and this file exists to make that negative exact: a
//! declared error, a message that names what is missing, and an out-slot that
//! provably was not written.
//!
//! **The message diverges from upstream on purpose.** Dawn's terminal error is
//! `"Unsupported surface type (%s) for Vulkan."` (`SwapChainVk.cpp:774`), which
//! names neither the display server nor the extension. Upstream expects the
//! application to have opened the display long before that line, so it has
//! nothing to say about it. The port names the environment instead, because
//! that is what the caller has to fix.
//!
//! **No handle is created, and the signature says so.** Dawn returns
//! `ResultOrError<VkSurfaceKHR>` (`SwapChainVk.h:110`) and declares the handle
//! as a function local that is returned only inside a success arm
//! (`SwapChainVk.cpp:735`, `:758`). `createVulkanSurface` here returns
//! `SurfaceError!void` and writes the null handle into the caller's out-slot
//! before any arm runs, so "no handle was created" is a fact about the return
//! type and not a claim about a value nobody got.

const std = @import("std");
const vulkan = @import("vulkan");
const x11_functions = @import("x11_functions.zig");

/// Every rule the surface path can report.
///
/// `AGENTS.md` §3 asks that the set be swept at compile time by an `inline for`
/// over `@typeInfo`, so every member is named by a test. The sweep lives in
/// `test/surface_headless.zig`.
pub const SurfaceError = error{
    /// The host has no display server, so no `VkSurfaceKHR` can be created.
    ///
    /// The port's own name. Upstream reaches `"Unsupported surface type (%s)
    /// for Vulkan."` (`SwapChainVk.cpp:774`) instead, because a caller with a
    /// display never gets that far.
    SurfaceUnavailable,

    /// `nextInChain` is null (`Surface.cpp:102-104`).
    DescriptorChainEmpty,

    /// A `SurfaceColorManagement` is in the chain (`Surface.cpp:108-109`).
    SurfaceColorManagementUnsupported,

    /// The chain names a source this build does not accept
    /// (`Surface.cpp:214-215`), or none at all.
    UnsupportedSurfaceSource,

    /// `ANativeWindow` is null (`Surface.cpp:125`).
    AndroidWindowNotSet,

    /// The layer is not a `CAMetalLayer` (`Surface.cpp:134-135`).
    LayerNotMetalLayer,

    /// The `HWND` is not a window (`Surface.cpp:143`).
    InvalidHwnd,

    /// `ICoreWindow` is null (`Surface.cpp:153-156`).
    InvalidCoreWindow,

    /// `ISwapChainPanel` is null (`Surface.cpp:164-167`).
    InvalidSwapChainPanel,

    /// `SwapChainPanel` is null (`Surface.cpp:176`).
    WinUISwapChainPanelIsNull,

    /// `wl_surface` is null while `wl_display` is not (`Surface.cpp:187`).
    WaylandSurfaceIsNull,

    /// `libX11.so.6` did not load (`Surface.cpp:200`).
    X11LibraryMissing,

    /// The X window is not valid (`Surface.cpp:210`).
    InvalidXWindow,

    /// A typed getter was called on a surface of another type.
    ///
    /// Upstream asserts (`Surface.cpp:395-457`, `DAWN_CHECK(mType == Type::…)`).
    /// The port reports it, because a library has no caller to assert at.
    WrongSurfaceType,
};

/// The message for each rule.
///
/// A `switch` over the whole set, so a member added to `SurfaceError` without a
/// message is a compile error rather than a runtime hole. `AGENTS.md` §2: the
/// text is the port's own, because Dawn has no message id at this revision.
pub fn message(err: SurfaceError) []const u8 {
    return switch (err) {
        error.SurfaceUnavailable => "no window system for a VkSurfaceKHR: DISPLAY and WAYLAND_DISPLAY are " ++
            "unset and no VK_KHR_display device exists, so no surface handle " ++
            "was created",
        error.DescriptorChainEmpty => "surface cannot be created with nextInChain unset",
        error.SurfaceColorManagementUnsupported => "SurfaceColorManagement is unsupported",
        error.UnsupportedSurfaceSource => "the surface descriptor names no supported source",
        error.AndroidWindowNotSet => "the Android window is not set",
        error.LayerNotMetalLayer => "the surface layer is not a CAMetalLayer",
        error.InvalidHwnd => "the HWND is not a window",
        error.InvalidCoreWindow => "the CoreWindow is not an ICoreWindow",
        error.InvalidSwapChainPanel => "the swap chain panel is not an ISwapChainPanel",
        error.WinUISwapChainPanelIsNull => "the WinUI swap chain panel is null",
        error.WaylandSurfaceIsNull => "the Wayland surface is null",
        error.X11LibraryMissing => "could not load libX11",
        error.InvalidXWindow => "the X window is not valid",
        error.WrongSurfaceType => "the surface is not of the type this accessor requires",
    };
}

/// The nine kinds of surface Dawn supports (`Surface.h:78-88`).
///
/// The member is `unspecified`, not `Undefined`, because `undefined` is a Zig
/// value and cannot be a field name. It is the same member and the same
/// ordinal position.
pub const SourceType = enum {
    /// `Surface::Type::Undefined` (`Surface.h:79`). The value an error surface
    /// carries, and the one `ValidateBranches` never returns.
    unspecified,
    /// `Surface::Type::AndroidWindow` (`Surface.h:80`).
    android_native_window,
    /// `Surface::Type::MetalLayer` (`Surface.h:81`).
    metal_layer,
    /// `Surface::Type::WaylandSurface` (`Surface.h:82`).
    wayland_surface,
    /// `Surface::Type::WindowsHWND` (`Surface.h:83`).
    windows_hwnd,
    /// `Surface::Type::WindowsCoreWindow` (`Surface.h:84`).
    windows_core_window,
    /// `Surface::Type::WindowsUWPSwapChainPanel` (`Surface.h:85`).
    windows_uwp_swap_chain_panel,
    /// `Surface::Type::WindowsWinUISwapChainPanel` (`Surface.h:86`).
    windows_winui_swap_chain_panel,
    /// `Surface::Type::XlibWindow` (`Surface.h:87`).
    xlib_window,

    /// Ports `AbslFormatConvert(Surface::Type, ...)` (`Surface.cpp:59-93`).
    ///
    /// Upstream calls `DAWN_UNREACHABLE()` for `Undefined` at `:88-89`, on the
    /// ground that a constructed surface always has a type. The port renders
    /// it anyway, because an error message that cannot name the type it found
    /// is a worse message.
    pub fn name(source_type: SourceType) [:0]const u8 {
        return switch (source_type) {
            .unspecified => "Undefined",
            .android_native_window => "AndroidWindow",
            .metal_layer => "MetalLayer",
            .wayland_surface => "WaylandSurface",
            .windows_hwnd => "WindowsHWND",
            .windows_core_window => "WindowsCoreWindow",
            .windows_uwp_swap_chain_panel => "WindowsUWPSwapChainPanel",
            .windows_winui_swap_chain_panel => "WindowsWinUISwapChainPanel",
            .xlib_window => "XlibWindow",
        };
    }

    /// The inverse of `name`, so a consumer that matched a string can come
    /// back. Upstream has no such table; `AbslFormatConvert` is one-way
    /// (`Surface.cpp:59`).
    pub fn fromName(text: []const u8) ?SourceType {
        inline for (@typeInfo(SourceType).@"enum".fields) |field| {
            const source_type: SourceType = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, source_type.name())) return source_type;
        }
        return null;
    }
};

/// The `wl_display` and `wl_surface` an XDG surface needs.
///
/// Upstream stores two raw pointers (`Surface.h:170-171`) and checks only that
/// neither is null (`Surface.cpp:186-187`), because a Wayland object cannot be
/// validated without the protocol.
pub const WaylandSource = struct {
    display: ?*anyopaque,
    surface: ?*anyopaque,
};

/// The `HINSTANCE` and `HWND` a Win32 surface needs (`Surface.h:174-175`).
pub const WindowsHwndSource = struct {
    instance: ?*anyopaque,
    hwnd: u64,
};

/// The `Display*` and `Window` an Xlib surface needs (`Surface.h:189-190`).
///
/// Dawn calls `xGetWindowAttributes` to prove the window is live
/// (`Surface.cpp:206-207`). `tools/gen_dispatch.zig:40-44` records that no X11
/// header is vendored, so the port cannot ask, and the window number is the
/// only part it can check.
pub const XlibSource = struct {
    display: ?*anyopaque,
    window: u64,
};

/// The window-system sum type (`Surface.h:71`, `:78-88`).
///
/// One field per type, so the tag is the type and the payload is the object the
/// caller supplied. `Surface.cpp:312-370` stores the same payload in one field
/// per platform.
pub const Source = union(SourceType) {
    unspecified: void,
    android_native_window: ?*anyopaque,
    metal_layer: ?*anyopaque,
    wayland_surface: WaylandSource,
    windows_hwnd: WindowsHwndSource,
    windows_core_window: ?*anyopaque,
    windows_uwp_swap_chain_panel: ?*anyopaque,
    windows_winui_swap_chain_panel: ?*anyopaque,
    xlib_window: XlibSource,
};

/// A surface: the source it was made from and nothing else.
///
/// Dawn's `Surface` also holds an instance, a label, a device, two swap chains
/// and a capability cache (`Surface.h:146-161`). Every one of those belongs to
/// a milestone that has not landed: the label is the M2 API binding
/// (`Surface.cpp:675`), the device and the swap chains are M9, and the cache is
/// the adapter query at M9. Their rows are in the M20 table of
/// `docs/40-plan.md` with the milestone that lands them named.
pub const Surface = struct {
    source: Source,

    /// Ports `Surface::GetType` (`Surface.cpp:390`).
    pub fn sourceType(surface: *const Surface) SourceType {
        return surface.source;
    }

    /// Ports `Surface::GetAndroidNativeWindow` (`Surface.cpp:395`).
    pub fn getAndroidNativeWindow(surface: *const Surface) SurfaceError!*anyopaque {
        return switch (surface.source) {
            .android_native_window => |window| window orelse return error.AndroidWindowNotSet,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetMetalLayer` (`Surface.cpp:401`).
    pub fn getMetalLayer(surface: *const Surface) SurfaceError!*anyopaque {
        return switch (surface.source) {
            .metal_layer => |layer| layer orelse return error.LayerNotMetalLayer,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetWaylandDisplay` (`Surface.cpp:407`).
    pub fn getWaylandDisplay(surface: *const Surface) SurfaceError!*anyopaque {
        return switch (surface.source) {
            .wayland_surface => |wayland| wayland.display orelse return error.SurfaceUnavailable,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetWaylandSurface` (`Surface.cpp:412`).
    pub fn getWaylandSurface(surface: *const Surface) SurfaceError!*anyopaque {
        return switch (surface.source) {
            .wayland_surface => |wayland| wayland.surface orelse return error.WaylandSurfaceIsNull,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetHInstance` (`Surface.cpp:417`).
    pub fn getHInstance(surface: *const Surface) SurfaceError!*anyopaque {
        return switch (surface.source) {
            .windows_hwnd => |hwnd| hwnd.instance orelse return error.InvalidHwnd,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetHWND` (`Surface.cpp:422`).
    pub fn getHwnd(surface: *const Surface) SurfaceError!u64 {
        return switch (surface.source) {
            .windows_hwnd => |hwnd| hwnd.hwnd,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetCoreWindow` (`Surface.cpp:428`).
    ///
    /// Upstream builds the `ComPtr<ICoreWindow>` under
    /// `DAWN_USE_WINDOWS_UI` and returns null on every other build
    /// (`Surface.cpp:431-436`). The port has one build and one nullability, so
    /// the null is the port's.
    pub fn getCoreWindow(surface: *const Surface) SurfaceError!?*anyopaque {
        return switch (surface.source) {
            .windows_core_window => |core_window| core_window orelse
                return error.InvalidCoreWindow,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetUWPSwapChainPanel` (`Surface.cpp:438`).
    pub fn getUwpSwapChainPanel(surface: *const Surface) SurfaceError!?*anyopaque {
        return switch (surface.source) {
            .windows_uwp_swap_chain_panel => |panel| panel orelse
                return error.InvalidSwapChainPanel,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetWinUISwapChainPanel` (`Surface.cpp:448`).
    pub fn getWinUiSwapChainPanel(surface: *const Surface) SurfaceError!?*anyopaque {
        return switch (surface.source) {
            .windows_winui_swap_chain_panel => |panel| panel orelse
                return error.WinUISwapChainPanelIsNull,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetXDisplay` (`Surface.cpp:458`).
    pub fn getXDisplay(surface: *const Surface) SurfaceError!*anyopaque {
        return switch (surface.source) {
            .xlib_window => |xlib| xlib.display orelse return error.SurfaceUnavailable,
            else => error.WrongSurfaceType,
        };
    }

    /// Ports `Surface::GetXWindow` (`Surface.cpp:463`).
    pub fn getXWindow(surface: *const Surface) SurfaceError!u64 {
        return switch (surface.source) {
            .xlib_window => |xlib| xlib.window,
            else => error.WrongSurfaceType,
        };
    }
};

/// What `Instance::createSurface` receives (`dawn.json` "surface descriptor").
pub const Request = struct {
    /// `SurfaceDescriptor::nextInChain` (`Surface.cpp:102`). Null is the empty
    /// chain, which upstream rejects before it looks at anything else.
    source: ?Source = null,

    /// A `SurfaceColorManagement` is in the chain (`Surface.cpp:108`).
    /// Unsupported at this revision, so the port has to be told.
    color_management: bool = false,
};

/// Ports `ValidateSurfaceDescriptor` (`Surface.cpp:99-217`).
///
/// Dawn checks the chain, rejects colour management, then switches on the
/// `SType` with a `#if` per platform and a `default` that reports
/// `"Unsupported sType (%s)"` (`:214-215`). The port's switch has no `#if`: it
/// is over the nine-member `SourceType`, so every arm is visible whether or not
/// this target compiles it, and `AGENTS.md` §2's "no unused parameter" has
/// nothing to spare.
pub fn validateSurfaceDescriptor(request: Request) SurfaceError!void {
    const source = request.source orelse return error.DescriptorChainEmpty;
    if (request.color_management) return error.SurfaceColorManagementUnsupported;

    switch (source) {
        .unspecified => return error.UnsupportedSurfaceSource,
        .android_native_window => |window| {
            if (window == null) return error.AndroidWindowNotSet;
        },
        // Upstream also calls `InheritsFromCAMetalLayer`
        // (`Surface.cpp:134`), which is declared at `:96` under
        // `DAWN_ENABLE_BACKEND_METAL` and defined in the Objective-C file.
        .metal_layer => |layer| {
            if (layer == null) return error.LayerNotMetalLayer;
        },
        .wayland_surface => |wayland| {
            // Upstream's rule is `"Wayland display is nullptr."` (`:186`). The
            // port reports `SurfaceUnavailable` instead, because a caller with
            // no `wl_display` on this host has no compositor either, and the
            // message then names the environment the caller has to provide.
            if (wayland.display == null) return error.SurfaceUnavailable;
            if (wayland.surface == null) return error.WaylandSurfaceIsNull;
        },
        // Upstream calls `IsWindow` (`:143`), which is Win32-only.
        .windows_hwnd => |hwnd| {
            if (hwnd.hwnd == 0) return error.InvalidHwnd;
        },
        .windows_core_window => |core_window| {
            if (core_window == null) return error.InvalidCoreWindow;
        },
        .windows_uwp_swap_chain_panel => |panel| {
            if (panel == null) return error.InvalidSwapChainPanel;
        },
        .windows_winui_swap_chain_panel => |panel| {
            if (panel == null) return error.WinUISwapChainPanelIsNull;
        },
        // Upstream proves the window is live by calling `xGetWindowAttributes`
        // under a temporary error handler (`:202-210`). The port has no X11 to
        // call, so a caller with no `Display*` gets `SurfaceUnavailable` and a
        // caller with one and a zero window gets `InvalidXWindow`.
        .xlib_window => |xlib| {
            if (xlib.display == null) return error.SurfaceUnavailable;
            if (xlib.window == 0) return error.InvalidXWindow;
        },
    }
}

/// Ports `vulkan::CreateVulkanSurface` (`SwapChainVk.cpp:633`).
///
/// Dawn's switch reads the global info, the function table and the
/// `VkInstance` once (`:636-641`), then walks five `#if`-guarded arms, each
/// gated on `info.HasExt(InstanceExt::…)`. Every arm that does not take its
/// gate `break`s to `default: break` (`:768-769`) and the function returns the
/// terminal error at `:774`.
pub fn createVulkanSurface(
    surface: *const Surface,
    x11: ?*const x11_functions.X11Functions,
    out_vk_surface: *vulkan.VkSurfaceKHR,
) SurfaceError!void {
    // Dawn's handle is a function local initialised to `VK_NULL_HANDLE` and
    // returned only inside a success arm (`SwapChainVk.cpp:735`, `:758`), so
    // nothing leaks: the null handle is written before any arm runs, which is
    // what `test/surface_headless.zig` reads. The cast is named because the
    // macro is `?*anyopaque` (`src/vulkan.zig:20767`) and the slot is not (`:8311`).
    out_vk_surface.* = @as(vulkan.VkSurfaceKHR, @ptrCast(vulkan.VK_NULL_HANDLE));

    switch (surface.source) {
        .xlib_window => {
            // The Xlib arm is the one arm whose precondition this port can
            // still ask about, because libX11 is the only window-system
            // dependency Dawn loads as a shared library
            // (`X11Functions.cpp:37`). Upstream asks it at `Surface.cpp:200`,
            // and again at `SwapChainVk.cpp:748` for the XCB fallback.
            const functions = x11 orelse return error.X11LibraryMissing;
            if (!functions.isX11Loaded()) return error.X11LibraryMissing;
        },
        // Metal (`SwapChainVk.cpp:645`), Win32 (`:663`), Android (`:682`),
        // Wayland (`:706`), the XCB fallback (`:748`) and the `default` arm
        // (`:768`). Each is gated on a `create_*_surface_*` entry point, and
        // `src/vk/dispatch.zig:540-558` binds `destroy_surface_khr` plus four
        // queries and no creator, so no arm has a call to make.
        // `tools/gen_dispatch.zig:35-44` records why: the creators are declared
        // in `vulkan_xlib.h`, `vulkan_xcb.h`, `vulkan_wayland.h`,
        // `vulkan_win32.h` and `vulkan_android.h`, which `vulkan_core.h` reaches
        // only behind `VK_USE_PLATFORM_*`, and those headers need platform
        // SDKs this project does not vendor.
        .android_native_window,
        .metal_layer,
        .wayland_surface,
        .windows_hwnd,
        .windows_core_window,
        .windows_uwp_swap_chain_panel,
        .windows_winui_swap_chain_panel,
        .unspecified,
        => {},
    }

    // Dawn's terminal, and the only outcome every arm above reaches. The text
    // is the port's; `SwapChainVk.cpp:774` names neither the display server
    // nor the extension, because upstream assumes the application supplied a
    // display before this line.
    return error.SurfaceUnavailable;
}

/// Ports `InstanceBase::APICreateSurface` (`Instance.cpp:733`) chained into
/// `vulkan::CreateVulkanSurface` (`SwapChainVk.cpp:633`).
///
/// Dawn returns an error object rather than an error value
/// (`Surface.cpp:290`, `MakeError`), so a failed request still yields a
/// `Surface` whose `mType` is `Undefined` (`Surface.h:147`). The port returns
/// the error, so a caller cannot hold a surface that was never made, and the
/// out-slot is the only place a handle would have appeared.
pub fn createSurface(
    request: Request,
    x11: ?*const x11_functions.X11Functions,
    out_vk_surface: *vulkan.VkSurfaceKHR,
) SurfaceError!Surface {
    out_vk_surface.* = @as(vulkan.VkSurfaceKHR, @ptrCast(vulkan.VK_NULL_HANDLE));
    const source = request.source orelse return error.DescriptorChainEmpty;
    try validateSurfaceDescriptor(request);

    const surface: Surface = .{ .source = source };
    try createVulkanSurface(&surface, x11, out_vk_surface);
    return surface;
}

comptime {
    // `AbslFormatConvert` (`Surface.cpp:59-93`) is one-way, so nothing upstream
    // checks that the nine names are distinct. A collision would make
    // `fromName` return the wrong type, and the string is what a consumer
    // matches on, so it is a compile-time claim here.
    for (@typeInfo(SourceType).@"enum".fields, 0..) |left, left_index| {
        const left_type: SourceType = @enumFromInt(left.value);
        for (@typeInfo(SourceType).@"enum".fields, 0..) |right, right_index| {
            if (left_index == right_index) continue;
            const right_type: SourceType = @enumFromInt(right.value);
            if (!std.mem.eql(u8, left_type.name(), right_type.name())) continue;
            @compileError("two surface types share a name");
        }
    }
}
