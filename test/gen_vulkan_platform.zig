const std = @import("std");
const generator = @import("gen_vulkan_platform");

const complete = "#define VK_HEADER_VERSION_COMPLETE VK_MAKE_API_VERSION(0, 1, 4, VK_HEADER_VERSION)\n";
const core = "#define VK_HEADER_VERSION 365\n" ++ complete;

fn fixture(directory: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try directory.createDirPath(std.testing.io, parent);
    try directory.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
}

fn vulkanFixture(directory: std.Io.Dir) !void {
    try fixture(directory, "vk/vulkan/vulkan_core.h", core);
    for ([_][]const u8{ "vk_platform.h", "vulkan_xlib.h", "vulkan_wayland.h", "vulkan_android.h" }) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "vk/vulkan/{s}", .{name});
        defer std.testing.allocator.free(path);
        try fixture(directory, path, "/* prerequisite fixture, not an ABI */\n");
    }
}

fn render(product: generator.Product, wayland: bool) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try generator.render(&writer.writer, product, wayland);
    return std.testing.allocator.dupe(u8, writer.written());
}

test "header pin accepts only the official version macro" {
    try generator.validateHeaderVersion(core);
    try generator.validateHeaderVersion("/* VK_HEADER_VERSION 12 */\n# define VK_HEADER_VERSION\t365 // pin\n" ++ complete);
    try std.testing.expectError(error.VulkanHeaderVersionMismatch, generator.validateHeaderVersion("#define VK_HEADER_VERSION 364\n"));
    try std.testing.expectError(error.VulkanHeaderVersionMissing, generator.validateHeaderVersion("/* #define VK_HEADER_VERSION 365 */\n"));
    try std.testing.expectError(error.InvalidVulkanHeaderVersion, generator.validateHeaderVersion("#define VK_HEADER_VERSION 365x\n"));
    try std.testing.expectError(error.InvalidVulkanHeaderVersion, generator.validateHeaderVersion(core ++ core));
    try std.testing.expectError(error.VulkanHeaderVersionMissing, generator.validateHeaderVersion("#define VK_HEADER_VERSION 365\n"));
    try std.testing.expectError(error.VulkanHeaderVersionMismatch, generator.validateHeaderVersion("#define VK_HEADER_VERSION 365\n#define VK_HEADER_VERSION_COMPLETE VK_MAKE_API_VERSION(0, 2, 4, VK_HEADER_VERSION)\n"));
    try std.testing.expectError(error.VulkanHeaderVersionMismatch, generator.validateHeaderVersion("#define VK_HEADER_VERSION 365\n#define VK_HEADER_VERSION_COMPLETE VK_MAKE_API_VERSION(0, 1, 3, VK_HEADER_VERSION)\n"));
    try std.testing.expectError(error.InvalidVulkanHeaderVersion, generator.validateHeaderVersion(core ++ complete));
}

test "linux emission contains only official includes and platform macros" {
    const bytes = try render(.linux_vulkan, false);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("#define VK_USE_PLATFORM_XLIB_KHR 1\n#include <X11/Xlib.h>\n#include <vulkan/vulkan_core.h>\n#include <vulkan/vulkan_xlib.h>\n", bytes);
    const wayland = try render(.linux_vulkan, true);
    defer std.testing.allocator.free(wayland);
    try std.testing.expect(std.mem.indexOf(u8, wayland, "#define VK_USE_PLATFORM_WAYLAND_KHR 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wayland, "#include <wayland-client.h>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wayland, "#include <vulkan/vulkan_wayland.h>\n") != null);
}

test "android outputs include the official Vulkan and NativeActivity SDK" {
    const vk = try render(.android_vulkan, false);
    defer std.testing.allocator.free(vk);
    try std.testing.expectEqualStrings("#define VK_USE_PLATFORM_ANDROID_KHR 1\n#include <android/native_window.h>\n#include <android/hardware_buffer.h>\n#include <vulkan/vulkan_core.h>\n#include <vulkan/vulkan_android.h>\n", vk);
    const native = try render(.android_native, false);
    defer std.testing.allocator.free(native);
    try std.testing.expectEqualStrings("#include <jni.h>\n#include <android/native_window.h>\n#include <android/hardware_buffer.h>\n#include <android/native_activity.h>\n#include <android/looper.h>\n#include <android/log.h>\n", native);
}

test "Linux validates required Xlib and optional requested Wayland before emission" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try vulkanFixture(temporary.dir);
    var config: generator.Configuration = .{ .product = .linux_vulkan, .vulkan_headers = "vk", .xlib_include = "x11" };
    try std.testing.expectError(error.MissingPlatformHeader, generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
    try fixture(temporary.dir, "x11/X11/Xlib.h", "/* fixture */\n");
    try std.testing.expect(!try generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
    config.wayland_include = "wayland";
    try std.testing.expectError(error.MissingPlatformHeader, generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
    try fixture(temporary.dir, "wayland/wayland-client.h", "/* fixture */\n");
    try std.testing.expect(try generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
    try fixture(temporary.dir, "vk/vulkan/vulkan_core.h", "#define VK_HEADER_VERSION 364\n");
    try std.testing.expectError(error.VulkanHeaderVersionMismatch, generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
}

test "Android refuses an incomplete NDK sysroot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try vulkanFixture(temporary.dir);
    const config: generator.Configuration = .{ .product = .android_native, .vulkan_headers = "vk", .android_sysroot = "ndk" };
    try std.testing.expectError(error.MissingPlatformHeader, generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
    for (generator.android_headers) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "ndk/usr/include/{s}", .{name});
        defer std.testing.allocator.free(path);
        try fixture(temporary.dir, path, "/* fixture */\n");
    }
    try std.testing.expect(!try generator.validate(std.testing.allocator, std.testing.io, temporary.dir, config));
}

test "CLI rejects duplicate unknown and incompatible options" {
    const valid = try generator.parseArguments(&.{ "generator", "--product", "linux-vulkan", "--vulkan-headers", "vk", "--xlib-include", "x11" });
    try std.testing.expectEqual(generator.Product.linux_vulkan, valid.product);
    try std.testing.expectError(error.InvalidArguments, generator.parseArguments(&.{ "generator", "--product", "linux-vulkan", "--vulkan-headers", "vk" }));
    try std.testing.expectError(error.InvalidArguments, generator.parseArguments(&.{ "generator", "--product", "android-native", "--vulkan-headers", "vk", "--android-sysroot", "ndk", "--xlib-include", "x11" }));
    try std.testing.expectError(error.InvalidArguments, generator.parseArguments(&.{ "generator", "--product", "linux-vulkan", "--product", "linux-vulkan" }));
    try std.testing.expectError(error.InvalidArguments, generator.parseArguments(&.{ "generator", "--unknown", "value" }));
}
