//! Drift check for the generated dispatch table.
//!
//! `tools/gen_dispatch.zig` is the only thing that may write
//! `src/vk/dispatch.zig`, and the file is checked in so a consumer needs no C
//! toolchain and no Vulkan SDK. That leaves one thing to guard: a generator
//! change nobody ran. This test renders the table again, writes the bytes to a
//! scratch file in the build cache, and compares them with the checked-in file
//! byte for byte (`docs/40-plan.md` §4.2).
//!
//! `io` is built here rather than taken from `std.testing.io`, because
//! `AGENTS.md` §3 says no module reaches for a global one, and a test that
//! reads the file system is exactly where that rule is easy to break.

const std = @import("std");
const gen_dispatch = @import("gen_dispatch");
const options = @import("drift_options");

/// Ceiling on either file, in bytes. The generated table is about 70 KiB, so an
/// order of magnitude above it turns a generator that wrote something else into
/// `error.StreamTooLong` rather than into a byte comparison.
const max_file_bytes = 1024 * 1024;

/// The reading and rendering helpers declare their own error sets, because Zig
/// 0.16 gives a `test` body an inferred one and `AGENTS.md` §2 asks for a
/// declared one.
const FileError = std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.WriteFileError ||
    std.Io.Dir.CreateDirPathOpenError ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error;

/// Where the generator's bytes go. `zig build generate` names both halves, so a
/// path without one of them means the build graph changed.
const ScratchError = error{
    MissingScratchDir,
};

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
fn renderToScratch(allocator: std.mem.Allocator, io: std.Io) (FileError || ScratchError)![]u8 {
    const scratch_dir = std.fs.path.dirname(options.scratch_path) orelse
        return error.MissingScratchDir;
    const scratch_name = std.fs.path.basename(options.scratch_path);

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try gen_dispatch.render(&rendered.writer);

    const scratch = try std.Io.Dir.cwd().createDirPathOpen(io, scratch_dir, .{});
    defer scratch.close(io);
    try scratch.writeFile(io, .{
        .sub_path = scratch_name,
        .data = rendered.written(),
    });

    return scratch.readFileAlloc(io, scratch_name, allocator, .limited(max_file_bytes));
}
