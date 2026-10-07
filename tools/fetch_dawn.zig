//! Explicit, source-only Dawn checkout. Never runs from the default build graph.
const std = @import("std");
const pin = @import("dawn_pin.zon");

pub const FetchError = error{
    InvalidArguments,
    FilesystemFailed,
    NotStandaloneCheckout,
    DirtyCheckout,
    WrongRemote,
    WrongRevision,
    WrongSparseSet,
    GitFailed,
    TooManyArguments,
    OutOfMemory,
};

const output_limit_bytes = 1024 * 1024;
const argument_limit = 20;

pub fn main(init: std.process.Init) FetchError!void {
    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        return error.OutOfMemory;
    };
    if (arguments.len != 2 or arguments[1].len == 0) {
        std.log.err("usage: fetch-dawn <destination>", .{});
        return error.InvalidArguments;
    }
    try fetch(init.gpa, init.io, arguments[1]);
}

fn fetch(allocator: std.mem.Allocator, io: std.Io, destination: []const u8) FetchError!void {
    const existing: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, destination, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return error.FilesystemFailed,
    };
    if (existing) |directory| {
        defer directory.close(io);
        const metadata = directory.openDir(io, ".git", .{}) catch {
            std.log.err("destination must be a standalone Git checkout: {s}", .{destination});
            return error.NotStandaloneCheckout;
        };
        metadata.close(io);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = directory.realPath(io, &path_buffer) catch {
            return error.FilesystemFailed;
        };
        const root = try git(allocator, io, .{
            .destination = destination,
            .arguments = &.{ "rev-parse", "--show-toplevel" },
        });
        defer allocator.free(root);
        if (!std.mem.eql(u8, trim(root), path_buffer[0..path_length])) {
            return error.NotStandaloneCheckout;
        }
        const status = try git(allocator, io, .{
            .destination = destination,
            .arguments = &.{ "status", "--porcelain=v1", "--untracked-files=all", "--ignored" },
        });
        defer allocator.free(status);
        requireClean(status) catch |err| {
            std.log.err("checkout has local files or changes; refusing to change {s}", .{destination});
            return err;
        };
        const remote = try git(allocator, io, .{
            .destination = destination,
            .arguments = &.{ "remote", "get-url", "origin" },
        });
        defer allocator.free(remote);
        if (!std.mem.eql(u8, trim(remote), pin.url)) return error.WrongRemote;
    } else {
        const initialized = try git(allocator, io, .{
            .arguments = &.{ "init", "--", destination },
        });
        allocator.free(initialized);
        try gitDiscard(allocator, io, .{
            .destination = destination,
            .arguments = &.{ "remote", "add", "origin", pin.url },
        });
    }

    try gitDiscard(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "fetch", "--no-tags", "--depth=1", "origin", pin.revision },
    });
    try gitDiscard(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "sparse-checkout", "set", "--cone", "--", pin.sparse_paths[0], pin.sparse_paths[1] },
    });
    try gitDiscard(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "checkout", "--detach", pin.revision },
    });
    try verify(allocator, io, destination);
}

fn verify(allocator: std.mem.Allocator, io: std.Io, destination: []const u8) FetchError!void {
    const revision = try git(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "rev-parse", "HEAD" },
    });
    defer allocator.free(revision);
    if (!revisionMatches(revision)) return error.WrongRevision;
    const sparse = try git(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "sparse-checkout", "list" },
    });
    defer allocator.free(sparse);
    if (!sparseMatches(sparse)) return error.WrongSparseSet;
    const cone = try git(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "config", "--get", "core.sparseCheckoutCone" },
    });
    defer allocator.free(cone);
    if (!std.mem.eql(u8, trim(cone), "true")) return error.WrongSparseSet;
    const shallow = try git(allocator, io, .{
        .destination = destination,
        .arguments = &.{ "rev-parse", "--is-shallow-repository" },
    });
    defer allocator.free(shallow);
    std.log.info("Dawn source at {s}: HEAD={s}, sparse=src,include, shallow={s}", .{
        destination, trim(revision), trim(shallow),
    });
}

const GitOptions = struct {
    destination: ?[]const u8 = null,
    arguments: []const []const u8,
};

fn git(allocator: std.mem.Allocator, io: std.Io, options: GitOptions) FetchError![]u8 {
    var arguments: [argument_limit][]const u8 = undefined;
    const prefix: []const []const u8 = if (options.destination) |destination|
        &.{ "git", "-c", "core.hooksPath=/dev/null", "-C", destination }
    else
        &.{ "git", "-c", "core.hooksPath=/dev/null" };
    const count = prefix.len + options.arguments.len;
    if (count > argument_limit) return error.TooManyArguments;
    @memcpy(arguments[0..prefix.len], prefix);
    @memcpy(arguments[prefix.len..count], options.arguments);
    const result = std.process.run(allocator, io, .{
        .argv = arguments[0..count],
        .stdout_limit = .limited(output_limit_bytes),
        .stderr_limit = .limited(output_limit_bytes),
    }) catch |err| {
        std.log.err("cannot run git: {s}", .{@errorName(err)});
        return if (err == error.OutOfMemory) error.OutOfMemory else error.GitFailed;
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("git failed ({d}): {s}", .{ code, result.stderr });
            return error.GitFailed;
        },
        else => return error.GitFailed,
    }
    return result.stdout;
}

fn gitDiscard(allocator: std.mem.Allocator, io: std.Io, options: GitOptions) FetchError!void {
    const output = try git(allocator, io, options);
    allocator.free(output);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, "\r\n");
}

fn requireClean(status: []const u8) FetchError!void {
    if (status.len != 0) return error.DirtyCheckout;
}

fn revisionMatches(value: []const u8) bool {
    return std.mem.eql(u8, trim(value), pin.revision);
}

fn sparseMatches(value: []const u8) bool {
    var lines = std.mem.splitScalar(u8, trim(value), '\n');
    var found = [_]bool{ false, false };
    for (0..pin.sparse_paths.len) |_| {
        const line = trim(lines.next() orelse return false);
        var matched = false;
        inline for (pin.sparse_paths, 0..) |path, index| {
            if (std.mem.eql(u8, line, path)) {
                if (found[index]) return false;
                found[index] = true;
                matched = true;
            }
        }
        if (!matched) return false;
    }
    return lines.next() == null;
}

test "sparse set accepts either order and rejects extra or missing paths" {
    try std.testing.expect(sparseMatches("src\ninclude\n"));
    try std.testing.expect(sparseMatches("include\nsrc\n"));
    try std.testing.expect(!sparseMatches("src\n"));
    try std.testing.expect(!sparseMatches("src\ninclude\nthird_party\n"));
    try std.testing.expect(!sparseMatches("src\nsrc\n"));
}

test "dirty checkout includes staged untracked and ignored files" {
    try std.testing.expectError(error.DirtyCheckout, requireClean(" M src/file\n"));
    try std.testing.expectError(error.DirtyCheckout, requireClean("M  src/file\n"));
    try std.testing.expectError(error.DirtyCheckout, requireClean("?? local\n"));
    try std.testing.expectError(error.DirtyCheckout, requireClean("!! ignored\n"));
    try requireClean("");
}

test "revision check requires the complete pinned hash" {
    try std.testing.expect(revisionMatches(pin.revision ++ "\n"));
    try std.testing.expect(!revisionMatches(pin.revision[0..12]));
    try std.testing.expect(!revisionMatches("0000000000000000000000000000000000000000\n"));
}
