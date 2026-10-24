//! The libX11 loader: four symbols behind two `dlopen` calls.
//!
//! **What this file is.** The port of `src/dawn/native/X11Functions.{h,cpp}` at
//! Dawn revision `32f77c02294310054a660c393feded4bcb3f203c`. It opens `libX11.so.6` and
//! `libX11-xcb.so.1` and resolves four function pointers.
//!
//! **What this file does not claim.** It does not claim an X11 binding. Dawn
//! stores four typed pointers (`X11Functions.h:50-57`) and calls them
//! (`Surface.cpp:202-208`). `tools/gen_dispatch.zig:40-44` records that this
//! project vendors no X11 header, so `Display`, `Window` and `XErrorEvent` do
//! not exist in the port. Every slot here is therefore `?*const anyopaque`, and
//! nothing in the port calls through one.
//!
//! **What the loader is not.** It is not a gate. Both libraries are present in
//! `/usr/lib64` on this host, so `isX11Loaded` is true and upstream's
//! `Surface.cpp:200` rule ("Couldn't load libX11.") is the one that does not
//! fire here. The headless failure is elsewhere.

const std = @import("std");
const loader_mod = @import("loader.zig");

/// The rules a load can break.
///
/// Dawn has no error here: `X11Functions::X11Functions` (`X11Functions.cpp:37`)
/// closes the library and leaves `IsX11Loaded()` false, and every caller asks
/// that predicate instead. The three ways the load can fail are named.
pub const X11Error = error{
    /// `libX11.so.6` did not open, or one of its three symbols did not resolve
    /// (`X11Functions.cpp:37-43`).
    LibraryMissing,

    /// `libX11-xcb.so.1` did not open, or `XGetXCBConnection` did not resolve
    /// (`X11Functions.cpp:44-46`). Dawn treats this as independent: the XCB
    /// surface fallback at `SwapChainVk.cpp:748` needs both, and a host with
    /// libX11 but no x11-xcb takes the Xlib path only.
    XcbLibraryMissing,

    /// The library opened and the symbol did not. `Loader.open` uses
    /// `RTLD_LAZY` (`src/platform/loader.zig:18-24`), so Dawn's `RTLD_NOW`
    /// failure at `DynamicLib.cpp:104` surfaces here, at the lookup.
    SymbolMissing,
};

/// The four entry points Dawn resolves, and the two libraries holding them.
///
/// All-or-nothing per library, as at `X11Functions.cpp:37-47`: one failure
/// closes that library, which is what makes `isX11Loaded` false.
pub const X11Functions = struct {
    x11: loader_mod.Loader,
    x11_xcb: loader_mod.Loader,
    x_set_error_handler: ?*const anyopaque,
    x_get_window_attributes: ?*const anyopaque,
    x_synchronize: ?*const anyopaque,
    x_get_xcb_connection: ?*const anyopaque,

    /// The symbol names, comptime, because `dlsym` takes a C string
    /// (`src/platform/loader.zig:116-120`).
    const symbol_x_set_error_handler = "XSetErrorHandler";
    const symbol_x_get_window_attributes = "XGetWindowAttributes";
    const symbol_x_synchronize = "XSynchronize";
    const symbol_x_get_xcb_connection = "XGetXCBConnection";

    const x11_library = "libX11.so.6";
    const x11_xcb_library = "libX11-xcb.so.1";

    /// Ports `X11Functions::X11Functions` (`X11Functions.cpp:37`).
    ///
    /// The allocator is the second parameter `Loader.open` takes
    /// (`src/platform/loader.zig:77`). No path prefix is passed, so the open
    /// itself does not allocate; the caller still supplies one.
    pub fn init(allocator: std.mem.Allocator, x11: *X11Functions) X11Error!void {
        x11.* = .{
            .x11 = .closed(),
            .x11_xcb = .closed(),
            .x_set_error_handler = null,
            .x_get_window_attributes = null,
            .x_synchronize = null,
            .x_get_xcb_connection = null,
        };
        x11.x11.open(allocator, .{ .path = x11_library }) catch
            return x11.fail(error.LibraryMissing);

        x11.x_set_error_handler = x11.x11.lookup(symbol_x_set_error_handler) orelse
            return x11.fail(error.SymbolMissing);
        x11.x_get_window_attributes = x11.x11.lookup(symbol_x_get_window_attributes) orelse
            return x11.fail(error.SymbolMissing);
        x11.x_synchronize = x11.x11.lookup(symbol_x_synchronize) orelse
            return x11.fail(error.SymbolMissing);
        x11.x11_xcb.open(allocator, .{ .path = x11_xcb_library }) catch
            return x11.fail(error.XcbLibraryMissing);

        x11.x_get_xcb_connection = x11.x11_xcb.lookup(symbol_x_get_xcb_connection) orelse
            return x11.fail(error.XcbLibraryMissing);
    }

    /// Ports `X11Functions::IsX11Loaded` (`X11Functions.cpp:51`).
    pub fn isX11Loaded(x11: *const X11Functions) bool {
        return x11.x11.isOpen();
    }

    /// Ports `X11Functions::IsX11XcbLoaded` (`X11Functions.cpp:55`).
    pub fn isX11XcbLoaded(x11: *const X11Functions) bool {
        return x11.x11_xcb.isOpen();
    }

    /// Releases both libraries and destroys the struct. Ports
    /// `X11Functions::~X11Functions` (`X11Functions.cpp:49`), spelled `deinit`
    /// here because an owner calls it by name.
    ///
    /// The four slots point into the two libraries `dlclose` just released,
    /// so nothing may read them afterwards and the whole value goes.
    pub fn deinit(x11: *X11Functions) void {
        x11.x11_xcb.deinit();
        x11.x11.deinit();
        x11.* = undefined;
    }

    /// Closes both libraries, clears the four slots and reports `err`. Dawn's
    /// constructor closes the failing library (`X11Functions.cpp:41`, `:46`)
    /// and leaves the corresponding `Is*Loaded()` false, and a caller asks
    /// that predicate rather than the error (`Surface.cpp:200`), so a failed
    /// `init` has to leave the struct readable. That is the whole difference
    /// from `deinit`: this is the constructor's failure path, so it closes
    /// the two `Loader`s and leaves them, and their own `deinit` runs once.
    fn fail(x11: *X11Functions, comptime err: X11Error) X11Error {
        x11.x11_xcb.close();
        x11.x11.close();
        x11.x_set_error_handler = null;
        x11.x_get_window_attributes = null;
        x11.x_synchronize = null;
        x11.x_get_xcb_connection = null;
        return err;
    }
};

test "a successful load resolves all four slots and a failed one resolves none" {
    // Whether `libX11.so.6` is installed is a fact about the host, not a
    // property of the loader, so the assertions below are the pair that holds
    // either way. Dawn's two predicates are independent
    // (`X11Functions.cpp:51-57`); the second one is checked inside the first.
    var x11: X11Functions = undefined;
    X11Functions.init(std.testing.allocator, &x11) catch |err| switch (err) {
        error.LibraryMissing => {
            try std.testing.expect(!x11.isX11Loaded());
            try std.testing.expect(!x11.isX11XcbLoaded());
            return;
        },
        error.XcbLibraryMissing => {
            try std.testing.expect(x11.isX11Loaded());
            try std.testing.expect(!x11.isX11XcbLoaded());
            return;
        },
        error.SymbolMissing => return error.SymbolMissing,
    };
    defer x11.deinit();

    try std.testing.expect(x11.isX11Loaded());
    try std.testing.expect(x11.isX11XcbLoaded());
    try std.testing.expect(x11.x_set_error_handler != null);
    try std.testing.expect(x11.x_get_window_attributes != null);
    try std.testing.expect(x11.x_synchronize != null);
    try std.testing.expect(x11.x_get_xcb_connection != null);
}

test "an unopened loader resolves nothing" {
    const closed: X11Functions = .{
        .x11 = .closed(),
        .x11_xcb = .closed(),
        .x_set_error_handler = null,
        .x_get_window_attributes = null,
        .x_synchronize = null,
        .x_get_xcb_connection = null,
    };

    try std.testing.expect(!closed.isX11Loaded());
    try std.testing.expect(!closed.isX11XcbLoaded());
}

test "every error member has a message" {
    // Compare reflected names with the message table.
    inline for (@typeInfo(X11Error).error_set.error_names.?) |member_name| {
        const text = if (std.mem.eql(u8, member_name, "LibraryMissing"))
            "libX11.so.6 is not installed"
        else if (std.mem.eql(u8, member_name, "XcbLibraryMissing"))
            "libX11-xcb.so.1 is not installed"
        else if (std.mem.eql(u8, member_name, "SymbolMissing"))
            "libX11 does not export the symbol"
        else
            "";
        try std.testing.expect(text.len > 0);
    }
}
