//! Drift check for the generated dispatch table.
//!
//! Renders the table to a temporary file and compares it with the checked-in file.

const std = @import("std");
const gen_dispatch = @import("gen_dispatch");
const options = @import("drift_options");

/// Ceiling on either file, in bytes. The generated table is about 70 KiB, so an
/// order of magnitude above it turns a generator that wrote something else into
/// `error.StreamTooLong` rather than into a byte comparison.
const max_file_bytes = 1024 * 1024;

const FileError = std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.WriteFileError ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error;

test "the checked-in dispatch table is what the generator emits" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const checked_in = try readCheckedIn(allocator, io);
    defer allocator.free(checked_in);

    const regenerated = try renderToScratch(allocator, io);
    defer allocator.free(regenerated);

    try std.testing.expectEqualSlices(u8, checked_in, regenerated);
}

fn readCheckedIn(allocator: std.mem.Allocator, io: std.Io) FileError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        options.checked_in_path,
        allocator,
        .limited(max_file_bytes),
    );
}

/// Renders the table and writes it to the scratch file, then reads that file
/// back. The round trip is the point: the comparison is between two files on
/// disk, so a generator that produced a partial file fails here instead of
/// passing against an equally partial tree.
fn renderToScratch(allocator: std.mem.Allocator, io: std.Io) FileError![]u8 {
    const scratch_name = "dispatch.zig";
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try gen_dispatch.render(&rendered.writer);

    try scratch.dir.writeFile(io, .{
        .sub_path = scratch_name,
        .data = rendered.written(),
    });

    return scratch.dir.readFileAlloc(io, scratch_name, allocator, .limited(max_file_bytes));
}
