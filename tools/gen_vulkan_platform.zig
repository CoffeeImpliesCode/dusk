//! Host-only include-header emitter. The explicit generate graph captures stdout
//! in its cache, translates it, and publishes source only after all checks pass.
//! This tool never translates C, invokes a compiler, or writes generated Zig ABI.
const std = @import("std");

pub const Product = enum { linux_vulkan, android_vulkan, android_native };
pub const Configuration = struct {
    product: Product,
    /// Include root containing vulkan/vulkan_core.h, not the vulkan directory.
    vulkan_headers: []const u8,
    xlib_include: ?[]const u8 = null,
    /// Omitted means no Wayland. A supplied root must contain wayland-client.h.
    wayland_include: ?[]const u8 = null,
    /// NDK sysroot; official SDK headers live beneath usr/include.
    android_sysroot: ?[]const u8 = null,
};
pub const Error = error{
    InvalidArguments,
    OutOfMemory,
    MissingVulkanHeader,
    MissingPlatformHeader,
    HeaderReadFailed,
    VulkanHeaderVersionMissing,
    InvalidVulkanHeaderVersion,
    VulkanHeaderVersionMismatch,
    OutputWriteFailed,
};
pub const android_headers = [_][]const u8{
    "jni.h", "android/native_window.h", "android/hardware_buffer.h",
    "android/native_activity.h", "android/looper.h", "android/log.h",
};

pub fn parseArguments(arguments: []const []const u8) Error!Configuration {
    var product: ?Product = null;
    var headers: ?[]const u8 = null;
    var xlib: ?[]const u8 = null;
    var wayland: ?[]const u8 = null;
    var sysroot: ?[]const u8 = null;
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len or arguments[index + 1].len == 0) return error.InvalidArguments;
        const option = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, option, "--product")) {
            if (product != null) return error.InvalidArguments;
            product = if (std.mem.eql(u8, value, "linux-vulkan")) .linux_vulkan else if (std.mem.eql(u8, value, "android-vulkan")) .android_vulkan else if (std.mem.eql(u8, value, "android-native")) .android_native else return error.InvalidArguments;
        } else {
            const destination: *?[]const u8 = if (std.mem.eql(u8, option, "--vulkan-headers")) &headers else if (std.mem.eql(u8, option, "--xlib-include")) &xlib else if (std.mem.eql(u8, option, "--wayland-include")) &wayland else if (std.mem.eql(u8, option, "--android-sysroot")) &sysroot else return error.InvalidArguments;
            if (destination.* != null) return error.InvalidArguments;
            destination.* = value;
        }
    }
    const config: Configuration = .{
        .product = product orelse return error.InvalidArguments,
        .vulkan_headers = headers orelse return error.InvalidArguments,
        .xlib_include = xlib,
        .wayland_include = wayland,
        .android_sysroot = sysroot,
    };
    try validateConfiguration(config);
    return config;
}

fn validateConfiguration(config: Configuration) Error!void {
    if (config.vulkan_headers.len == 0) return error.InvalidArguments;
    switch (config.product) {
        .linux_vulkan => {
            if (config.xlib_include == null or config.android_sysroot != null) return error.InvalidArguments;
        },
        .android_vulkan, .android_native => {
            if (config.android_sysroot == null or config.xlib_include != null or config.wayland_include != null) return error.InvalidArguments;
        },
    }
    for ([_]?[]const u8{ config.xlib_include, config.wayland_include, config.android_sysroot }) |root| {
        if (root) |value| if (value.len == 0) return error.InvalidArguments;
    }
}

/// Check both the decimal patch and the official complete-version definition.
/// v1.4.365 is VK_MAKE_API_VERSION(0, 1, 4, VK_HEADER_VERSION).
pub fn validateHeaderVersion(bytes: []const u8) Error!void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var found = false;
    var complete_found = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "#")) continue;
        var words = std.mem.tokenizeAny(u8, trimmed[1..], " \t\r");
        if (!std.mem.eql(u8, words.next() orelse continue, "define")) continue;
        const name = words.next() orelse continue;
        if (std.mem.eql(u8, name, "VK_HEADER_VERSION_COMPLETE")) {
            if (complete_found) return error.InvalidVulkanHeaderVersion;
            complete_found = true;
            const start = (std.mem.indexOf(u8, trimmed, name) orelse unreachable) + name.len;
            const value = std.mem.trim(u8, trimmed[start..], " \t\r");
            const open = std.mem.indexOfScalar(u8, value, '(') orelse return error.InvalidVulkanHeaderVersion;
            if (!std.mem.eql(u8, std.mem.trim(u8, value[0..open], " \t"), "VK_MAKE_API_VERSION")) return error.InvalidVulkanHeaderVersion;
            const close = std.mem.indexOfScalarPos(u8, value, open + 1, ')') orelse return error.InvalidVulkanHeaderVersion;
            var arguments = std.mem.splitScalar(u8, value[open + 1 .. close], ',');
            for ([_][]const u8{ "0", "1", "4", "VK_HEADER_VERSION" }) |expected| {
                const actual = std.mem.trim(u8, arguments.next() orelse return error.InvalidVulkanHeaderVersion, " \t");
                if (!std.mem.eql(u8, actual, expected)) return error.VulkanHeaderVersionMismatch;
            }
            if (arguments.next() != null) return error.InvalidVulkanHeaderVersion;
            const suffix = std.mem.trim(u8, value[close + 1 ..], " \t");
            if (suffix.len != 0 and !std.mem.startsWith(u8, suffix, "//") and !std.mem.startsWith(u8, suffix, "/*")) return error.InvalidVulkanHeaderVersion;
            continue;
        }
        if (!std.mem.eql(u8, name, "VK_HEADER_VERSION")) continue;
        if (found) return error.InvalidVulkanHeaderVersion;
        found = true;
        const value = words.next() orelse return error.InvalidVulkanHeaderVersion;
        const version = std.fmt.parseInt(u32, value, 10) catch return error.InvalidVulkanHeaderVersion;
        if (words.next()) |suffix| {
            if (!std.mem.startsWith(u8, suffix, "//") and !std.mem.startsWith(u8, suffix, "/*")) return error.InvalidVulkanHeaderVersion;
        }
        if (version != 365) return error.VulkanHeaderVersionMismatch;
    }
    if (!found or !complete_found) return error.VulkanHeaderVersionMissing;
}

fn readHeader(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, root: []const u8, relative: []const u8, comptime missing: Error) Error![]u8 {
    const path = std.fs.path.join(allocator, &.{ root, relative }) catch return error.OutOfMemory;
    defer allocator.free(path);
    return directory.readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| {
        diagnostic(io, "Cannot read prerequisite {s}: {s}. Supply the official Vulkan v1.4.365/platform SDK include root.\n", .{ path, @errorName(err) });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound, error.NotDir => missing,
            else => error.HeaderReadFailed,
        };
    };
}

fn requireHeader(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, root: []const u8, relative: []const u8, comptime missing: Error) Error!void {
    const bytes = try readHeader(allocator, io, directory, root, relative, missing);
    defer allocator.free(bytes);
}

/// Validate every requested direct header before writing any output. Returns
/// whether the validated Linux input includes Wayland. Transitive C includes
/// remain the official headers' responsibility and are checked by translate-c.
pub fn validate(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, config: Configuration) Error!bool {
    try validateConfiguration(config);
    const core = try readHeader(allocator, io, directory, config.vulkan_headers, "vulkan/vulkan_core.h", error.MissingVulkanHeader);
    defer allocator.free(core);
    validateHeaderVersion(core) catch |err| {
        diagnostic(io, "{s}/vulkan/vulkan_core.h must define VK_HEADER_VERSION 365 (official Vulkan-Headers v1.4.365): {s}.\n", .{ config.vulkan_headers, @errorName(err) });
        return err;
    };
    try requireHeader(allocator, io, directory, config.vulkan_headers, "vulkan/vk_platform.h", error.MissingVulkanHeader);
    switch (config.product) {
        .linux_vulkan => {
            try requireHeader(allocator, io, directory, config.vulkan_headers, "vulkan/vulkan_xlib.h", error.MissingVulkanHeader);
            try requireHeader(allocator, io, directory, config.xlib_include.?, "X11/Xlib.h", error.MissingPlatformHeader);
            if (config.wayland_include) |root| {
                try requireHeader(allocator, io, directory, root, "wayland-client.h", error.MissingPlatformHeader);
                try requireHeader(allocator, io, directory, config.vulkan_headers, "vulkan/vulkan_wayland.h", error.MissingVulkanHeader);
                return true;
            }
        },
        .android_vulkan, .android_native => {
            try requireHeader(allocator, io, directory, config.vulkan_headers, "vulkan/vulkan_android.h", error.MissingVulkanHeader);
            const include = std.fs.path.join(allocator, &.{ config.android_sysroot.?, "usr/include" }) catch return error.OutOfMemory;
            defer allocator.free(include);
            for (android_headers) |header| try requireHeader(allocator, io, directory, include, header, error.MissingPlatformHeader);
        },
    }
    return false;
}

pub fn render(writer: *std.Io.Writer, product: Product, wayland: bool) std.Io.Writer.Error!void {
    switch (product) {
        .linux_vulkan => {
            try writer.writeAll("#define VK_USE_PLATFORM_XLIB_KHR 1\n#include <X11/Xlib.h>\n");
            if (wayland) try writer.writeAll("#define VK_USE_PLATFORM_WAYLAND_KHR 1\n#include <wayland-client.h>\n");
            try writer.writeAll("#include <vulkan/vulkan_core.h>\n#include <vulkan/vulkan_xlib.h>\n");
            if (wayland) try writer.writeAll("#include <vulkan/vulkan_wayland.h>\n");
        },
        .android_vulkan => try writer.writeAll("#define VK_USE_PLATFORM_ANDROID_KHR 1\n#include <android/native_window.h>\n#include <android/hardware_buffer.h>\n#include <vulkan/vulkan_core.h>\n#include <vulkan/vulkan_android.h>\n"),
        .android_native => for (android_headers) |header| try writer.print("#include <{s}>\n", .{header}),
    }
}

fn diagnostic(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    stderr.interface.print(format, args) catch return;
    stderr.interface.flush() catch return;
}

pub fn main(init: std.process.Init) Error!void {
    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch return error.OutOfMemory;
    const config = parseArguments(arguments) catch |err| {
        diagnostic(init.io, "Use gen_vulkan_platform --product linux-vulkan|android-vulkan|android-native --vulkan-headers <include-root> [--xlib-include <root>] [--wayland-include <root>] [--android-sysroot <NDK-sysroot>].\n", .{});
        return err;
    };
    const wayland = try validate(init.gpa, init.io, .cwd(), config);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    render(&stdout.interface, config.product, wayland) catch return error.OutputWriteFailed;
    stdout.interface.flush() catch return error.OutputWriteFailed;
}
