//! Dynamic library loading: one `dlopen` call behind a declared error set.
//!
//! **What this file is.** The port of `src/dawn/common/DynamicLib.cpp` at Dawn
//! revision `32f77c02294310054a660c393feded4bcb3f203c`. It holds `open`, `lookup`,
//! `close` and `isOpen`.
//!
//! **What this file does not claim.** It does not claim the Windows behaviour.
//! `DynamicLib::OpenSystemLibrary` (`DynamicLib.cpp:68`) has no row because its
//! only callers are `d3d/PlatformFunctions.cpp:85` and
//! `d3d12/PlatformFunctionsD3D12.cpp:65`, and both back ends are skipped.
//! `DynamicLib::OpenLoaded` (`DynamicLib.cpp:118`) has no row because its only
//! caller is `native/utils/RenderDoc.cpp:60`, which is skipped. It does not
//! return the `dlerror()` text that `DynamicLib.cpp:106-108` copies into an
//! out-parameter. A member of the declared error set replaces it.
//!
//! **One difference from upstream, named.** Dawn opens with `RTLD_NOW`
//! (`DynamicLib.cpp:104`), so a missing symbol fails the open.
//! `std.DynLib` opens with `RTLD_LAZY` (`lib/std/dynamic_library.zig:576`), so a
//! missing symbol faults at the call. The Vulkan loader tier tolerates that,
//! because `loadInstanceProcs` and `loadDeviceProcs` already treat a null proc as
//! a missing entry point (`VulkanFunctions.cpp:120`),
//! and the tier never calls a proc it did not load.

const std = @import("std");

/// One open shared library.
///
/// Ports `dawn::DynamicLib` (`src/dawn/common/DynamicLib.h:48`). A `Loader`
/// holds the handle until `close` or `deinit`. It has no destructor, so the
/// owner names the moment the library leaves the process.
pub const Loader = struct {
    lib: std.DynLib,

    /// The open flag and the `dlclose` permission, in one field.
    ///
    /// `DynamicLib::Valid` (`DynamicLib.cpp:63-65`) reads `mHandle != nullptr`,
    /// which a Zig struct cannot express, so this field carries the state
    /// instead. It is `mNeedsClose` (`DynamicLib.h:95`), which `Close` reads at
    /// `DynamicLib.cpp:160` before it calls `dlclose`. One field rather than
    /// two, because `OpenLoaded` is skipped, so no successful open ever leaves
    /// the library unowned.
    needs_close: bool,

    pub const OpenError = std.mem.Allocator.Error || error{
        /// A `Loader` already holds an open library. Upstream asserts instead
        /// (`DynamicLib.cpp:84`). The port returns the error, so a second open
        /// cannot overwrite a handle the owner still needs.
        LibraryAlreadyOpen,

        /// Every candidate path failed. The names in `options.search_paths` are
        /// a fixed, ordered list, so one error covers all of them.
        OpenFailed,
    };

    pub const OpenOptions = struct {
        /// The library name or path, exactly as `dlopen` takes it.
        path: []const u8,

        /// Directory prefixes, tried in order after `path`.
        ///
        /// Dawn concatenates each prefix with the name
        /// (`DynamicLib.cpp:145-151`). The port tries `path` on its own first,
        /// because `dlopen` of a bare name already searches the loader path. A
        /// caller that wants Dawn's prefix-only order passes an empty string as
        /// the first prefix.
        search_paths: []const []const u8 = &.{},
    };

    /// Opens the library named by `options` and stores the handle in `loader`.
    ///
    /// Ports the two `DynamicLib::Open` overloads (`DynamicLib.cpp:83`, `:142`),
    /// one function because they differ only in the prefixes they try. The
    /// receiver is first, so a caller writes `loader.open(allocator, options)`.
    pub fn open(
        loader: *Loader,
        allocator: std.mem.Allocator,
        options: OpenOptions,
    ) OpenError!void {
        if (loader.isOpen()) return error.LibraryAlreadyOpen;

        // Bound: the bare name plus one candidate per search path.
        const max_candidate_count = options.search_paths.len + 1;
        var candidate_index: usize = 0;
        while (candidate_index < max_candidate_count) : (candidate_index += 1) {
            // `dlopen` has read the joined name by the time the loop moves on,
            // so the candidate owns it and frees it; `options.path` is the
            // caller's and outlives the loop.
            const joined: ?[]u8 = switch (candidate_index) {
                0 => null,
                else => try std.mem.concat(allocator, u8, &.{
                    options.search_paths[candidate_index - 1],
                    options.path,
                }),
            };
            defer if (joined) |name| allocator.free(name);
            // A refusal moves to the next candidate, so no `std.DynLib.Error`
            // member reaches `OpenError` above. `dlerror()` explains a refusal,
            // and Dawn copied that text into a string (`DynamicLib.cpp:106-108`)
            // which `error.OpenFailed` below replaces.
            loader.lib = std.DynLib.open(joined orelse options.path) catch continue;
            loader.needs_close = true;
            return;
        }
        return error.OpenFailed;
    }

    /// Ports `DynamicLib::Valid` (`DynamicLib.cpp:63`).
    pub fn isOpen(loader: *const Loader) bool {
        return loader.needs_close;
    }

    /// Returns the address of `symbol_name`, or null when the library does not
    /// export it.
    ///
    /// `symbol_name` is sentinel-terminated because `dlsym` needs a C string and
    /// `std.DynLib.lookup` (`lib/std/dynamic_library.zig:54`) takes that type.
    /// Every Vulkan entry point name is a compile-time constant, so no caller
    /// builds one at run time. The caller casts the address with `@ptrCast`,
    /// which is what the `DynamicLib::GetProc<T>` overload
    /// (`DynamicLib.h:75`) does in place.
    pub fn lookup(loader: *Loader, symbol_name: [:0]const u8) ?*const anyopaque {
        if (!loader.isOpen()) return null;
        return loader.lib.lookup(*const anyopaque, symbol_name);
    }

    /// Releases the library. A second call does nothing, as at
    /// `DynamicLib.cpp:155-157`.
    pub fn close(loader: *Loader) void {
        if (!loader.needs_close) return;
        loader.lib.close();
        loader.needs_close = false;
    }

    /// `close` under the name a Zig owner calls. Ports
    /// `DynamicLib::~DynamicLib` (`DynamicLib.cpp:48`).
    ///
    /// Unlike `close`, this destroys the value. `std.DynLib` spells an open
    /// library only (`lib/std/dynamic_library.zig:14-27`), so there is no
    /// closed `DynLib` to leave behind, and the handle inside it dangles once
    /// `dlclose` has run. An owner that wants a second release, or a value it
    /// can still ask `isOpen` about, calls `close` instead.
    pub fn deinit(loader: *Loader) void {
        loader.close();
        loader.* = undefined;
    }

    /// A loader that holds no library, which is what every caller wants before
    /// it opens one.
    ///
    /// `std.DynLib` spells an open library only
    /// (`lib/std/dynamic_library.zig:14-27`), so there is no closed value to
    /// name. Every reader of a `Loader` goes through `isOpen`, `lookup` or
    /// `close`, and the first two gate on `needs_close`, so the `lib` bytes
    /// are never read while this flag is false.
    pub fn closed() Loader {
        return .{
            // SAFETY: `isOpen`, `lookup` and `close` all read `needs_close`
            // first, and `needs_close` is false here, so no path reads these
            // bytes. The first `open` that succeeds overwrites them.
            .lib = undefined,
            .needs_close = false,
        };
    }
};

test "a refused path leaves the loader closed" {
    var loader: Loader = .closed();

    try std.testing.expect(!loader.isOpen());

    try std.testing.expectError(error.OpenFailed, loader.open(std.testing.allocator, .{
        .path = "libdusk-this-library-does-not-exist.so",
    }));

    try std.testing.expect(!loader.isOpen());
}

test "every candidate path failing reports one error" {
    var loader: Loader = .closed();

    const search_paths = [_][]const u8{ "/nonexistent-a/", "/nonexistent-b/" };
    try std.testing.expectError(error.OpenFailed, loader.open(std.testing.allocator, .{
        .path = "libdusk-this-library-does-not-exist.so",
        .search_paths = &search_paths,
    }));

    try std.testing.expect(!loader.isOpen());
}

test "a closed loader looks up nothing" {
    var loader: Loader = .closed();

    try std.testing.expectEqual(@as(?*const anyopaque, null), loader.lookup("vkGetInstanceProcAddr"));

    loader.close();

    try std.testing.expectEqual(@as(?*const anyopaque, null), loader.lookup("vkGetInstanceProcAddr"));
}
