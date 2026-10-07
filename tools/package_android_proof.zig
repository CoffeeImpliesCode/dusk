const std = @import("std");

const Error = error{ InvalidArguments, OutOfMemory, FileSystemFailed, CommandFailed, EntropyFailed, MissingEntryLibrary };
const Library = struct { abi: []const u8, path: []const u8, basename: []const u8 };
const entry_library = "libdusk_android_proof.so";
const usage =
    \\Usage: package_android_proof SDK_ROOT BUILD_TOOLS_VERSION PLATFORM_API JDK_BIN DEBUG_KEYSTORE OUTPUT_APK ABI=LIBRARY...
    \\Example: package_android_proof /sdk 37.0.0 36 /jdk/bin /tmp/dusk-proof.jks /tmp/dusk-proof.apk x86_64=/tmp/libdusk_android_proof.so
    \\Requires SDK aapt2/zipalign/apksigner and JDK jar/keytool. ABI: arm64-v8a, armeabi-v7a, x86, x86_64.
    \\Each ABI must include libdusk_android_proof.so; repeat ABI=LIBRARY for native dependencies.
    \\Creates only the explicitly named debug keystore if absent (alias androiddebugkey, password android).
    \\OUTPUT_APK must not exist. Its parent directory and the keystore parent must exist.
    \\
;

pub fn main(init: std.process.Init) Error!void {
    const allocator = init.arena.allocator();
    const args = init.minimal.args.toSlice(allocator) catch return error.OutOfMemory;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        std.Io.File.stdout().writeStreamingAll(init.io, usage) catch return error.FileSystemFailed;
        return;
    }
    if (args.len < 8) {
        std.Io.File.stderr().writeStreamingAll(init.io, usage) catch {};
        return error.InvalidArguments;
    }
    try package(allocator, init.io, args[1..]);
}

fn parseLibrary(spec: []const u8) Error!Library {
    const separator = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidArguments;
    const abi = spec[0..separator];
    const path = spec[separator + 1 ..];
    const supported = [_][]const u8{ "arm64-v8a", "armeabi-v7a", "x86", "x86_64" };
    var valid = false;
    for (supported) |candidate| valid = valid or std.mem.eql(u8, abi, candidate);
    const basename = std.fs.path.basename(path);
    if (!valid or path.len == 0 or !std.mem.startsWith(u8, basename, "lib") or
        !std.mem.endsWith(u8, basename, ".so") or basename.len <= 6)
        return error.InvalidArguments;
    return .{ .abi = abi, .path = path, .basename = basename };
}

fn join(allocator: std.mem.Allocator, parts: []const []const u8) Error![]u8 {
    return std.fs.path.join(allocator, parts) catch return error.OutOfMemory;
}

fn exists(io: std.Io, path: []const u8) Error!bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return error.FileSystemFailed;
    };
    return true;
}

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) Error!void {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        std.log.err("cannot execute {s}: {s}", .{ argv[0], @errorName(err) });
        return if (err == error.OutOfMemory) error.OutOfMemory else error.CommandFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.log.err("{s} failed: {s}\n{s}", .{ argv[0], result.stdout, result.stderr });
    return error.CommandFailed;
}

fn package(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) Error!void {
    const cwd = std.Io.Dir.cwd();
    const api = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArguments;
    if (api < 36 or args[4].len == 0 or args[5].len == 0) return error.InvalidArguments;
    // Resolve each SDK/JDK tool explicitly; never select a different installed version.
    const build_tools = try join(allocator, &.{ args[0], "build-tools", args[1] });
    const aapt2 = try join(allocator, &.{ build_tools, "aapt2" });
    const zipalign = try join(allocator, &.{ build_tools, "zipalign" });
    const apksigner = try join(allocator, &.{ build_tools, "apksigner" });
    const keytool = try join(allocator, &.{ args[3], "keytool" });
    const jar = try join(allocator, &.{ args[3], "jar" });
    const platform = std.fmt.allocPrint(allocator, "android-{d}", .{api}) catch return error.OutOfMemory;
    const android_jar = try join(allocator, &.{ args[0], "platforms", platform, "android.jar" });
    const keystore = args[4];
    const output = args[5];
    if (try exists(io, output)) return error.InvalidArguments;

    const libraries = allocator.alloc(Library, args.len - 6) catch return error.OutOfMemory;
    for (args[6..], 0..) |spec, index| {
        libraries[index] = try parseLibrary(spec);
        for (libraries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.abi, libraries[index].abi) and
                std.mem.eql(u8, previous.basename, libraries[index].basename))
                return error.InvalidArguments;
        }
    }
    for (libraries) |library| {
        var found = false;
        for (libraries) |candidate| {
            found = found or (std.mem.eql(u8, candidate.abi, library.abi) and
                std.mem.eql(u8, candidate.basename, entry_library));
        }
        if (!found) return error.MissingEntryLibrary;
    }

    var entropy: [16]u8 = undefined;
    std.Io.randomSecure(io, &entropy) catch return error.EntropyFailed;
    const staging = std.fmt.allocPrint(allocator, "{s}.package-{s}", .{ output, std.fmt.bytesToHex(entropy, .lower) }) catch return error.OutOfMemory;
    cwd.createDir(io, staging, .default_dir) catch return error.FileSystemFailed;
    defer cwd.deleteTree(io, staging) catch |err| {
        std.log.warn("cannot remove task staging directory {s}: {s}", .{ staging, @errorName(err) });
    };
    const manifest = try join(allocator, &.{ staging, "AndroidManifest.xml" });
    const manifest_file = cwd.createFile(io, manifest, .{}) catch return error.FileSystemFailed;
    defer manifest_file.close(io);
    manifest_file.writeStreamingAll(io, @embedFile("android/AndroidManifest.xml")) catch return error.FileSystemFailed;
    for (libraries) |library| {
        const directory = try join(allocator, &.{ staging, "lib", library.abi });
        cwd.createDirPath(io, directory) catch return error.FileSystemFailed;
        const destination = try join(allocator, &.{ directory, library.basename });
        cwd.copyFile(library.path, cwd, destination, io, .{}) catch return error.FileSystemFailed;
    }
    const unsigned = try join(allocator, &.{ staging, "unsigned.apk" });
    const aligned = try join(allocator, &.{ staging, "aligned.apk" });
    const signed = try join(allocator, &.{ staging, "signed.apk" });
    try run(allocator, io, &.{ aapt2, "link", "-I", android_jar, "--manifest", manifest, "-o", unsigned });
    // jar updates the existing aapt2 ZIP; libraries can be compressed because the
    // manifest requests extraction. No Java code or dex compiler is needed.
    try run(allocator, io, &.{ jar, "--update", "--file", unsigned, "-C", staging, "lib" });
    try run(allocator, io, &.{ zipalign, "-P", "16", "4", unsigned, aligned });
    if (!try exists(io, keystore)) {
        try run(allocator, io, &.{
            keytool, "-genkeypair", "-noprompt", "-keystore", keystore,
            "-storetype", "JKS", "-storepass", "android", "-keypass", "android",
            "-alias", "androiddebugkey", "-dname", "CN=Dusk Native Proof,O=Dusk,C=US",
            "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
        });
    }
    try run(allocator, io, &.{
        apksigner, "sign", "--ks", keystore, "--ks-key-alias", "androiddebugkey",
        "--ks-pass", "pass:android", "--key-pass", "pass:android",
        "--v4-signing-enabled", "false", "--out", signed, aligned,
    });
    try run(allocator, io, &.{ apksigner, "verify", "--verbose", signed });
    try run(allocator, io, &.{ zipalign, "-c", "-P", "16", "4", signed });
    cwd.renamePreserve(signed, cwd, output, io) catch return error.FileSystemFailed;
    std.log.info("signed NativeActivity proof APK: {s}", .{output});
}

test "native library entries retain Android ABI and basename" {
    const lib = try parseLibrary("x86_64=/tmp/libdusk_android_proof.so");
    try std.testing.expectEqualStrings("x86_64", lib.abi);
    try std.testing.expectEqualStrings("/tmp/libdusk_android_proof.so", lib.path);
    try std.testing.expectEqualStrings("libdusk_android_proof.so", lib.basename);
}

test "native library entries reject unsupported ABI and non-library paths" {
    try std.testing.expectError(error.InvalidArguments, parseLibrary("x86=/tmp/runner"));
    try std.testing.expectError(error.InvalidArguments, parseLibrary("host=/tmp/libproof.so"));
    try std.testing.expectError(error.InvalidArguments, parseLibrary("x86_64="));
    try std.testing.expectError(error.InvalidArguments, parseLibrary("/tmp/libproof.so"));
}
