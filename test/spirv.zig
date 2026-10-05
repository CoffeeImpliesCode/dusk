//! The M5 shard: parse, validate and reflect two checked-in fixtures.
//!
//! The fixtures are generated, never hand-written. `test/fixtures/*.wgsl` is
//! the source a reviewer reads, and `docs/50-verification.md` §6.2 records the
//! command line that produced each `.spv` from it.
//!
//! **What this file does not claim.** It does not claim the fixtures are the
//! only shapes a shader can take. It claims what the milestone says: both
//! fixtures read, validate and reflect, and a corrupted one is refused.

const std = @import("std");
const spirv = @import("dusk").spirv;

const Word = spirv.Word;
const Error = spirv.Error;

const vertex_fixture: []const u8 = @embedFile("fixtures/triangle.vert.spv");
const fragment_fixture: []const u8 = @embedFile("fixtures/triangle.frag.spv");

/// SPIR-V 1.0, the oldest version the reader accepts, spelled the way the header
/// spells a version so the synthetic modules below need no fixture.
const version_1_0: Word = 0x0001_0000;

/// Opcode zero is `OpNop`: one word, no operands.
const op_nop = spirv.makeInstructionWord(0, 1);

test "spirv: the vertex fixture is a whole number of words and validates clean" {
    const allocator = std.testing.allocator;
    const words = try loadFixture(allocator, vertex_fixture);
    defer allocator.free(words);

    // A pass that returns has found nothing to report, which is the port's
    // "zero diagnostics". There is no list to inspect because the port has no
    // channel to report one on; `docs/50-verification.md` §7.1 says so.
    try spirv.validate(words);
}

test "spirv: the fragment fixture is a whole number of words and validates clean" {
    const allocator = std.testing.allocator;
    const words = try loadFixture(allocator, fragment_fixture);
    defer allocator.free(words);

    try spirv.validate(words);
}

test "spirv: both fixtures carry the SPIR-V 1.4 version word" {
    const allocator = std.testing.allocator;

    const vertex_words = try loadFixture(allocator, vertex_fixture);
    defer allocator.free(vertex_words);

    const fragment_words = try loadFixture(allocator, fragment_fixture);
    defer allocator.free(fragment_words);

    // Dawn validates at `SPV_ENV_VULKAN_1_1_SPIRV_1_4`
    // (`src/dawn/native/SpirvValidation.cpp:38`) and the version word is what
    // selects that environment, so the fixtures are generated at 1.4.
    try std.testing.expectEqual(@as(Word, 0x0001_0400), vertex_words[1]);
    try std.testing.expectEqual(@as(Word, 0x0001_0400), fragment_words[1]);
}

test "spirv: reflection reads the fragment version back as 1.4" {
    const allocator = std.testing.allocator;
    const words = try loadFixture(allocator, fragment_fixture);
    defer allocator.free(words);

    const reflected = try spirv.reflect(allocator, words);
    defer reflected.deinit();

    try std.testing.expectEqual(@as(u8, 1), reflected.version.major);
    try std.testing.expectEqual(@as(u8, 4), reflected.version.minor);
}

test "spirv: the vertex entry point takes no descriptor input" {
    const allocator = std.testing.allocator;
    const words = try loadFixture(allocator, vertex_fixture);
    defer allocator.free(words);

    const reflected = try spirv.reflect(allocator, words);
    defer reflected.deinit();

    const entry_point = reflected.findEntryPoint("vs_main") orelse
        return error.MissingVertexEntryPoint;

    try std.testing.expectEqual(spirv.ExecutionModel.vertex, entry_point.execution_model);
    try std.testing.expectEqual(@as(usize, 0), entry_point.resources.len);
}

test "spirv: the fragment entry point takes one input at set 0 binding 1" {
    const allocator = std.testing.allocator;
    const words = try loadFixture(allocator, fragment_fixture);
    defer allocator.free(words);

    const reflected = try spirv.reflect(allocator, words);
    defer reflected.deinit();

    const entry_point = reflected.findEntryPoint("fs_main") orelse
        return error.MissingFragmentEntryPoint;

    try std.testing.expectEqual(spirv.ExecutionModel.fragment, entry_point.execution_model);
    try std.testing.expectEqual(@as(usize, 1), entry_point.resources.len);
    try std.testing.expectEqual(spirv.ResourceKind.uniform_buffer, entry_point.resources[0].kind);
    try std.testing.expectEqual(@as(u32, 0), entry_point.resources[0].set);
    try std.testing.expectEqual(@as(u32, 1), entry_point.resources[0].binding);
}

test "spirv: a decoration word replaced by OpNop is a malformed module" {
    const allocator = std.testing.allocator;
    const words = try loadFixture(allocator, fragment_fixture);
    defer allocator.free(words);

    const corrupted_index = try overwriteFirstDecoration(words);
    try std.testing.expectError(error.SpirvMalformed, spirv.validate(words));

    // The word written is the word the test meant to write, so a failure names
    // which of the two assertions above failed.
    try std.testing.expectEqual(op_nop, words[corrupted_index]);
}

test "spirv: one synthetic module per failure the reader reports" {
    // The comptime block below is what makes this exhaustive: a member of
    // `Error` with no case here is a compile error.
    for (rejected_modules) |rejected| {
        try std.testing.expectError(rejected.failure, spirv.validate(rejected.words));
    }
}

test "spirv: every allocating path releases what it built when an allocation fails" {
    // `AGENTS.md` §3 asks for this sweep: refusing allocation N from zero up to
    // the first run that succeeds runs every `error.OutOfMemory` path and every
    // `errdefer` at least once. `std.testing.allocator` is the back end, so a
    // path that leaks on the way out fails the test.
    try sweepAllocationFailures(allocateWordsOnly, fragment_fixture);
    try sweepAllocationFailures(allocateReflection, fragment_fixture);
}

comptime {
    // `AGENTS.md` §3: sweep the error set at compile time so no member escapes
    // a test. `rejected_modules` is the sweep, and a member it does not name is
    // a compile error rather than a silent gap.
    for (@typeInfo(Error).error_set.?) |member| {
        if (member.name.len == 0) continue;

        var named = false;
        for (rejected_modules) |rejected| {
            if (std.mem.eql(u8, member.name, @errorName(rejected.failure))) named = true;
        }
        if (!named) @compileError("no case in rejected_modules names " ++ member.name);
    }
}

/// One word slice per failure the reader can report. Five of them are a header
/// with one field wrong; the other two are about the instruction stream.
const rejected_modules = [_]struct { failure: Error, words: []const Word }{
    .{ .failure = error.SpirvEmpty, .words = &.{} },
    .{ .failure = error.SpirvMagicWrong, .words = &.{ 0, version_1_0, 0, 4, 0 } },
    .{
        .failure = error.SpirvVersionMalformed,
        .words = &.{ spirv.magic_number, 0x0000_0101, 0, 4, 0 },
    },
    .{
        .failure = error.SpirvVersionUnsupported,
        .words = &.{ spirv.magic_number, 0x0001_0900, 0, 4, 0 },
    },
    .{
        .failure = error.SpirvSchemaNotZero,
        .words = &.{ spirv.magic_number, version_1_0, 0, 4, 1 },
    },
    // An `OpEntryPoint` that claims two words and has one is a module whose
    // instruction stream runs off the end.
    .{
        .failure = error.SpirvMalformed,
        .words = &.{ spirv.magic_number, version_1_0, 0, 4, 0, 0x0002_000f },
    },
    .{
        .failure = error.SpirvNoEntryPoint,
        .words = &.{ spirv.magic_number, version_1_0, 0, 4, 0 },
    },
};

/// The words of a fixture, with the file size divided by four checked against
/// what came back. A `.spv` file is a word stream, so a size that is not a whole
/// number of words is a truncated fixture rather than a module.
fn loadFixture(allocator: std.mem.Allocator, bytes: []const u8) ![]Word {
    const words = try spirv.wordsFromBytes(allocator, bytes);
    errdefer allocator.free(words);

    try std.testing.expectEqual(bytes.len / @sizeOf(Word), words.len);
    return words;
}

/// Overwrites the decoration word of the module's first `OpDecorate` with the
/// encoding of `OpNop` and returns the index it wrote.
///
/// The walk is the reader's own: an instruction is skipped by the word count in
/// its header, so the first `OpDecorate` is found without decoding anything
/// else. The module stays aligned afterwards, because `OpNop` is one word and so
/// is the operand slot it replaces; the only thing wrong with the result is the
/// word that used to name a decoration, and a decoration is a closed
/// enumeration.
fn overwriteFirstDecoration(words: []Word) !usize {
    var index: usize = spirv.header_word_count;
    while (index < words.len) {
        // The count is a `u16` and the index arithmetic is `usize`, so this is
        // a widening cast and not a coercion: the binding carries the type.
        const word_count: usize = @intCast(spirv.wordCountOf(words[index]));
        if (word_count == 0 or word_count > words.len - index) return error.TruncatedModule;

        const opcode = spirv.opcodeOf(words[index]);
        if (opcode == @intFromEnum(spirv.Opcode.decorate)) {
            if (word_count < 3) return error.TruncatedDecoration;
            words[index + 2] = op_nop;
            return index + 2;
        }
        index += word_count;
    }
    return error.NoDecoration;
}

fn sweepAllocationFailures(
    comptime body: fn (std.mem.Allocator, []const u8) anyerror!void,
    fixture: []const u8,
) !void {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        if (body(failing.allocator(), fixture)) |_| {
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
        }
    }
}

fn allocateWordsOnly(allocator: std.mem.Allocator, fixture: []const u8) !void {
    const words = try spirv.wordsFromBytes(allocator, fixture);
    allocator.free(words);
}

fn allocateReflection(allocator: std.mem.Allocator, fixture: []const u8) !void {
    const words = try spirv.wordsFromBytes(allocator, fixture);
    defer allocator.free(words);

    const reflected = try spirv.reflect(allocator, words);
    reflected.deinit();
}
