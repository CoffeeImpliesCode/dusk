//! The M5 shard: parse, validate and reflect two checked-in fixtures.
//!
//! The fixtures are generated, never hand-written. `test/fixtures/*.wgsl` is
//! the source a reviewer reads.
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
    // channel to report one on.
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

test "spirv: literal names preserve byte order and interface offsets" {
    const cases = [_]struct { words: []const Word, text: []const u8 }{
        .{ .words = &.{0}, .text = "" },
        .{ .words = &.{0x0000_0061}, .text = "a" },
        .{ .words = &.{0x0000_6261}, .text = "ab" },
        .{ .words = &.{0x0063_6261}, .text = "abc" },
        .{ .words = &.{ 0x6463_6261, 0 }, .text = "abcd" },
        .{ .words = &.{ 0x6463_6261, 0x0000_0065 }, .text = "abcde" },
        .{ .words = &.{ 0xc362_a1c3, 0x0000_00a9 }, .text = "ábé" },
        .{ .words = &.{ 0xf063_6261, 0x0080_989f }, .text = "abc😀" },
    };
    for (cases) |case| {
        var words: std.ArrayList(Word) = .empty;
        defer words.deinit(std.testing.allocator);
        try words.appendSlice(std.testing.allocator, &.{
            spirv.magic_number, version_1_0, 0, 8, 0,
            spirv.makeInstructionWord(15, @intCast(4 + case.words.len)),
            5, 1,
        });
        try words.appendSlice(std.testing.allocator, case.words);
        try words.append(std.testing.allocator, 7);
        try spirv.validate(words.items);
        const module = try spirv.reflect(std.testing.allocator, words.items);
        defer module.deinit();
        try std.testing.expectEqualStrings(case.text, module.entry_points[0].name);
        if (@import("builtin").target.cpu.arch.endian() == .little) {
            const borrowed = std.mem.sliceAsBytes(words.items[8..]);
            try std.testing.expectEqual(borrowed.ptr, module.entry_points[0].name.ptr);
        }
    }
}

test "spirv: packed names reject invalid UTF-8 across word boundaries" {
    for ([_][2]Word{
        .{ 0xc363_6261, 0x0000_0028 },
        .{ 0xf463_6261, 0x0080_8090 },
        .{ 0xc363_6261, 0 },
        .{ 0x6463_6261, 0x6867_6665 },
    }) |name| {
        const words = [_]Word{
            spirv.magic_number, version_1_0, 0, 8, 0,
            spirv.makeInstructionWord(15, 5), 5, 1,
            name[0], name[1],
        };
        try std.testing.expectError(error.SpirvMalformed, spirv.validate(&words));
        try std.testing.expectError(error.SpirvMalformed, spirv.reflect(std.testing.allocator, &words));
    }
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
    try sweepAllocationFailures(allocateWordsOnly, fragment_fixture);
    try sweepAllocationFailures(allocateReflection, fragment_fixture);
}

comptime {
    for (@typeInfo(Error).error_set.error_names.?) |member| {
        if (member.len == 0) continue;

        var named = false;
        for (rejected_modules) |rejected| {
            if (std.mem.eql(u8, member, @errorName(rejected.failure))) named = true;
        }
        if (!named) @compileError("no case in rejected_modules names " ++ member);
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
        if (opcode == @backingInt(spirv.Opcode.decorate)) {
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

// Numeric instruction fixtures keep default bits visible and require no compiler.
const specialization_words = [_]Word{
    spirv.magic_number, version_1_0, 0,           1000000,     0,
    0x0005_000f,        5,           100,         0x6e69_616d, 0,
    0x0004_0047,        900,         1,           7,           0x0004_0005,
    900,                0x756c_6176, 0x0000_0065, 0x0004_0015, 800,
    32,                 0,           0x0004_0032, 800,         900,
    11,                 0x0002_0014, 801,         0x0003_0030, 801,
    901,                0x0004_0047, 901,         1,           9,
    0x0003_0016,        802,         16,          0x0004_0032, 802,
    902,                0x3c00,      0x0002_0049, 700,         0x0004_0047,
    700,                1,           13,          0x0003_004a, 700,
    902,
    // Derived constants without SpecId do not become public override keys.
                   0x0006_0034, 800,         903,         128,
    900,                900,         0x0004_0017, 804,         800,
    2,                  0x0005_0033, 804,         904,         900,
    900,
};

test "spirv: specialization metadata retains sparse ids names types and default words" {
    const before = specialization_words;
    const reflected = try spirv.reflect(std.testing.allocator, &specialization_words);
    defer reflected.deinit();
    try std.testing.expectEqual(@as(usize, 3), reflected.specialization_constants.len);
    const integer = reflected.specialization_constants[0];
    try std.testing.expectEqual(@as(u32, 900), integer.result_id);
    try std.testing.expectEqual(@as(u32, 7), integer.spec_id);
    try std.testing.expectEqualStrings("value", integer.name);
    try std.testing.expectEqual(@as(u32, 32), integer.scalar_type.unsigned_integer);
    try std.testing.expect(reflected.specialization_constants[1].scalar_type == .boolean);
    try std.testing.expectEqual(
        @as(u32, 16),
        reflected.specialization_constants[2].scalar_type.float,
    );
    try std.testing.expectEqual(@as(u32, 13), reflected.specialization_constants[2].spec_id);
    try std.testing.expectEqualSlices(Word, &before, &specialization_words);
}

test "spirv: malformed specialization declarations are explicit decoder errors" {
    const tails = [_][]const Word{
        &.{ 0x0004_0047, 777, 1, 9 }, // Unknown target.
        &.{ 0x0004_0047, 100, 1, 9 }, // Entry point is not a constant.
        &.{ 0x0004_0047, 902, 1, 7 }, // Duplicate SpecId through a group.
        &.{ 0x0004_0032, 999, 950, 1, 0x0004_0047, 950, 1, 15 },
        &.{ 0x0003_0016, 810, 7, 0x0004_0032, 810, 950, 1, 0x0004_0047, 950, 1, 15 },
        &.{ 0x0003_0032, 800, 950, 0x0004_0047, 950, 1, 15 },
        &.{ 0x0003_0005, 900, 0xffff_ffff }, // Unterminated name.
        &.{ 0x0004_0047, 903, 1, 15 }, // Derived expression is not external linkage.
        &.{ 0x0004_0047, 0, 1, 15 },
        &.{ 0x0004_0047, 1000000, 1, 15 },
        &.{ 0x0005_0047, 950, 1, 15, 99 },
        &.{ 0x0005_0036, 800, 100, 0, 800, 0x0004_0032, 800, 950, 1 },
        &.{ 0x0004_0047, 904, 1, 15 }, // Composite is not a scalar.
        &.{ 0x0005_0048, 800, 0, 1, 15 },
        &.{ 0x0004_1600, 900, 1, 15 }, // OpDecorateString cannot carry SpecId.
    };
    for (tails) |tail| {
        const words = try std.testing.allocator.alloc(Word, specialization_words.len + tail.len);
        defer std.testing.allocator.free(words);
        @memcpy(words[0..specialization_words.len], &specialization_words);
        @memcpy(words[specialization_words.len..], tail);
        try std.testing.expectError(
            error.SpirvMalformed,
            spirv.reflect(std.testing.allocator, words),
        );
    }
}

test "spirv: specialization reflection releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocateSpecializationReflection,
        .{},
    );
}

fn allocateSpecializationReflection(allocator: std.mem.Allocator) !void {
    const reflected = try spirv.reflect(allocator, &specialization_words);
    defer reflected.deinit();
}

test "spirv: specialization metadata models all standard scalar widths" {
    for ([_]u32{ 8, 16, 32, 64 }) |width| {
        for ([_]u32{ 0, 1 }) |signedness| {
            const spec_opcode: Word = if (width == 64) 0x0005_0032 else 0x0004_0032;
            const padding: Word = if (width == 64) 0 else 0x0001_0000;
            const words = [_]Word{
                spirv.magic_number, version_1_0, 0,     100,         0,
                0x0005_000f,        5,           1,     0x6e69_616d, 0,
                0x0004_0015,        2,           width, signedness,  spec_opcode,
                2,                  3,           11,    padding,     0x0004_0047,
                3,                  1,           7,
            };
            const reflected = try spirv.reflect(std.testing.allocator, &words);
            defer reflected.deinit();
            const scalar = reflected.specialization_constants[0].scalar_type;
            try std.testing.expectEqual(width, if (signedness == 0)
                scalar.unsigned_integer
            else
                scalar.signed_integer);
        }
    }
    for ([_]u32{ 16, 32, 64 }) |width| {
        const spec_opcode: Word = if (width == 64) 0x0005_0032 else 0x0004_0032;
        const padding: Word = if (width == 64) 0 else 0x0001_0000;
        const words = [_]Word{
            spirv.magic_number, version_1_0, 0,       100,         0,
            0x0005_000f,        5,           1,       0x6e69_616d, 0,
            0x0003_0016,        2,           width,   spec_opcode, 2,
            3,                  0,           padding, 0x0004_0047, 3,
            1,                  7,
        };
        const reflected = try spirv.reflect(std.testing.allocator, &words);
        defer reflected.deinit();
        try std.testing.expectEqual(width, reflected.specialization_constants[0].scalar_type.float);
    }
}

test "spirv: specialization group declaration order and duplicate names preserve aliases" {
    const words = [_]Word{
        spirv.magic_number, version_1_0, 0,           100,         0,
        0x0005_000f,        5,           1,           0x6e69_616d, 0,
        0x0003_004a,        8,           3,           0x0004_0047, 8,
        1,                  7,           0x0002_0049, 8,           0x0004_0047,
        4,                  1,           9,           0x0003_0005, 3,
        0x0000_0078,        0x0003_0005, 4,           0x0000_0078, 0x0002_0014,
        2,                  0x0003_0031, 2,           3,           0x0003_0030,
        2,                  4,
    };
    const reflected = try spirv.reflect(std.testing.allocator, &words);
    defer reflected.deinit();
    try std.testing.expectEqual(@as(usize, 2), reflected.specialization_constants.len);
    for (reflected.specialization_constants) |constant| {
        try std.testing.expectEqualStrings("x", constant.name);
        try std.testing.expect(constant.scalar_type == .boolean);
    }
}

test "spirv: scalar declarations sharing SpecId retain aliases and independent defaults" {
    for ([_]u32{ 11, 12 }) |second_default| {
        const words = [_]Word{
            spirv.magic_number, version_1_0, 0,           100,         0,
            0x0005_000f,        5,           1,           0x6e69_616d, 0,
            0x0004_0015,        2,           32,          0,           0x0004_0047,
            3,                  1,           7,           0x0004_0047, 4,
            1,                  7,           0x0003_0005, 3,           0x0000_0078,
            0x0003_0005,        4,           0x0000_0079, 0x0004_0032, 2,
            3,                  11,          0x0004_0032, 2,           4,
            second_default,
        };
        const original = words;
        const reflected = try spirv.reflect(std.testing.allocator, &words);
        defer reflected.deinit();
        try std.testing.expectEqual(@as(usize, 2), reflected.specialization_constants.len);
        try std.testing.expectEqualStrings("x", reflected.specialization_constants[0].name);
        try std.testing.expectEqualStrings("y", reflected.specialization_constants[1].name);
        for (reflected.specialization_constants) |constant| {
            try std.testing.expectEqual(@as(u32, 7), constant.spec_id);
            try std.testing.expectEqual(@as(u32, 32), constant.scalar_type.unsigned_integer);
        }
        try std.testing.expectEqualSlices(Word, &original, &words);
    }
}

const workgroup_words = [_]Word{
    spirv.magic_number, version_1_0, 0,           100,         0,
    0x0005_000f,        5,           1,           0x6e69_616d, 0,
    0x0005_000f,        5,           9,           0x7265_6874, 0,
    0x0006_0010,        9,           17,          2,           3,
    4,                  0x0006_014b, 1,           38,          3,
    4,                  5,           0x0004_0015, 2,           32,
    0,                  0x0004_0032, 2,           3,           8,
    0x0004_0032,        2,           4,           2,           0x0004_002b,
    2,                  5,           1,           0x0004_0047, 3,
    1,                  7,           0x0004_0047, 4,           1,
    7,
};

test "spirv: per-entry workgroup defaults and canonical shared overrides preserve words" {
    const original = workgroup_words;
    const module = try spirv.reflect(std.testing.allocator, &workgroup_words);
    defer module.deinit();
    try std.testing.expectEqual([3]u32{ 8, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
    try std.testing.expectEqual([3]u32{ 2, 3, 4 }, try module.resolveWorkgroupSize(9, &.{}));
    try std.testing.expectEqual([3]u32{ 16, 16, 1 }, try module.resolveWorkgroupSize(
        1,
        &.{.{ .spec_id = 7, .size = 4, .bits = 16 }},
    ));
    try std.testing.expectEqual([3]u32{ 0, 0, 1 }, try module.resolveWorkgroupSize(
        1,
        &.{.{ .spec_id = 7, .size = 4, .bits = 0 }},
    ));
    try std.testing.expectEqualSlices(Word, &original, &workgroup_words);
    try std.testing.expectError(error.SpirvWorkgroupEntryPoint, module.resolveWorkgroupSize(8, &.{}));
    try std.testing.expectError(error.SpirvWorkgroupOverride, module.resolveWorkgroupSize(
        1,
        &.{.{ .spec_id = 7, .size = 8, .bits = 16 }},
    ));
}

test "spirv: specialization zero defaults remain available to compute validation" {
    var words = workgroup_words;
    words[34] = 0;
    const original = words;
    const module = try spirv.reflect(std.testing.allocator, &words);
    defer module.deinit();
    try std.testing.expectEqual([3]u32{ 0, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
    try std.testing.expectEqualSlices(Word, &original, &words);
}

test "spirv: workgroup metadata allocation failure releases partial reflection" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocateWorkgroupReflection,
        .{},
    );
}

fn allocateWorkgroupReflection(allocator: std.mem.Allocator) !void {
    const module = try spirv.reflect(allocator, &workgroup_words);
    defer module.deinit();
    try std.testing.expectEqual([3]u32{ 8, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
}

const workgroup_base = [_]Word{
    spirv.magic_number, version_1_0, 0,           100,         0,
    0x0005_000f,        5,           1,           0x6e69_616d, 0,
    0x0004_0015,        2,           32,          0,           0x0004_0032,
    2,                  3,           8,           0x0004_002b, 2,
    4,                  2,           0x0004_002b, 2,           5,
    1,                  0x0004_0047, 3,           1,           7,
};

fn workgroupModule(allocator: std.mem.Allocator, tail: []const Word) ![]Word {
    const words = try allocator.alloc(Word, workgroup_base.len + tail.len);
    @memcpy(words[0..workgroup_base.len], &workgroup_base);
    @memcpy(words[workgroup_base.len..], tail);
    return words;
}

test "spirv: workgroup expressions apply canonical overrides through dependencies" {
    const cases = [_]struct { operation: u32, expected: u32, overridden: u32 }{
        .{ .operation = 128, .expected = 10, .overridden = 18 },
        .{ .operation = 130, .expected = 6, .overridden = 14 },
        .{ .operation = 132, .expected = 16, .overridden = 32 },
        .{ .operation = 134, .expected = 4, .overridden = 8 },
        .{ .operation = 137, .expected = 0, .overridden = 0 },
        .{ .operation = 194, .expected = 2, .overridden = 4 },
        .{ .operation = 196, .expected = 32, .overridden = 64 },
        .{ .operation = 197, .expected = 10, .overridden = 18 },
        .{ .operation = 198, .expected = 10, .overridden = 18 },
        .{ .operation = 199, .expected = 0, .overridden = 0 },
    };
    for (cases) |case| {
        // Add one after each expression so zero intermediate values remain valid.
        const tail = [_]Word{
            0x0006_0034, 2, 6,  case.operation, 3, 4,
            0x0006_0034, 2, 7,  128,            6, 5,
            0x0006_014b, 1, 38, 7,              4, 5,
        };
        const words = try workgroupModule(std.testing.allocator, &tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectEqual([3]u32{ case.expected + 1, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
        try std.testing.expectEqual(
            [3]u32{ case.overridden + 1, 2, 1 },
            try module.resolveWorkgroupSize(
                1,
                &.{
                    .{
                        .spec_id = 7,
                        .size = 4,
                        .bits = 16,
                    },
                },
            ),
        );
    }
}

test "spirv: WorkgroupSize builtin overrides literal mode and resolves composites" {
    for ([_]Word{ 0x0006_002c, 0x0006_0033 }) |opcode| {
        const tail = [_]Word{
            0x0006_0010, 1,  17, 99, 99,          99,
            0x0004_0017, 6,  2,  3,  opcode,      6,
            7,           3,  4,  5,  0x0004_0047, 7,
            11,          25,
        };
        const words = try workgroupModule(std.testing.allocator, &tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expect(module.entry_points[0].workgroup_size == .builtin);
        try std.testing.expectEqual([3]u32{ 8, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
        try std.testing.expectEqual(
            [3]u32{ 16, 2, 1 },
            try module.resolveWorkgroupSize(
                1,
                &.{
                    .{
                        .spec_id = 7,
                        .size = 4,
                        .bits = 16,
                    },
                },
            ),
        );
    }
}

test "spirv: CompositeExtract workgroup dependency retains its scalar type" {
    const tail = [_]Word{
        0x0004_0017, 6,  2,           3,
        0x0006_0033, 6,  7,           3,
        4,           5,  0x0006_0034, 2,
        8,           81, 7,           0,
        0x0006_014b, 1,  38,          8,
        4,           5,
    };
    const words = try workgroupModule(std.testing.allocator, &tail);
    defer std.testing.allocator.free(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expectEqual(
        [3]u32{ 16, 2, 1 },
        try module.resolveWorkgroupSize(
            1,
            &.{
                .{
                    .spec_id = 7,
                    .size = 4,
                    .bits = 16,
                },
            },
        ),
    );
}

test "spirv: malformed workgroup modes reject wrong counts targets and duplicates" {
    const tails = [_][]const Word{
        &.{ 0x0005_0010, 1, 17, 1, 1 },
        &.{ 0x0006_0010, 1, 17, 0, 1, 1 },
        &.{ 0x0006_0010, 99, 17, 1, 1, 1 },
        &.{ 0x0006_0010, 1, 38, 3, 4, 5 },
        &.{ 0x0006_014b, 1, 17, 1, 1, 1 },
        &.{ 0x0006_014b, 1, 38, 0, 4, 5 },
        &.{ 0x0006_0010, 1, 17, 1, 1, 1, 0x0006_0010, 1, 17, 1, 1, 1 },
        &.{ 0x0006_0010, 1, 17, 1, 1, 1, 0x0006_014b, 1, 38, 3, 4, 5 },
    };
    for (tails) |tail| {
        const words = try workgroupModule(std.testing.allocator, tail);
        defer std.testing.allocator.free(words);
        try std.testing.expectError(error.SpirvMalformed, spirv.reflect(std.testing.allocator, words));
    }
}

test "spirv: workgroup resolution distinguishes missing unsupported cycles and malformed" {
    const cases = [_]struct { tail: []const Word, expected: spirv.Module.WorkgroupError }{
        .{ .tail = &.{}, .expected = error.SpirvWorkgroupMissing },
        .{ .tail = &.{ 0x0006_014b, 1, 38, 99, 4, 5 }, .expected = error.SpirvMalformed },
        .{
            .tail = &.{
                0x0006_0034, 2, 6,  999, 3, 4,
                0x0006_014b, 1, 38, 6,   4, 5,
            },
            .expected = error.SpirvWorkgroupUnsupported,
        },
        .{
            .tail = &.{
                0x0006_0034, 2, 6,  128, 6, 4,
                0x0006_014b, 1, 38, 6,   4, 5,
            },
            .expected = error.SpirvWorkgroupCycle,
        },
        .{
            .tail = &.{
                0x0004_002b, 2, 6,           32,
                0x0006_0034, 2, 7,           196,
                3,           6, 0x0006_014b, 1,
                38,          7, 4,           5,
            },
            .expected = error.SpirvMalformed,
        },
        .{
            .tail = &.{
                0x0005_0034, 2, 6,  128, 3,
                0x0006_014b, 1, 38, 6,   4,
                5,
            },
            .expected = error.SpirvMalformed,
        },
        .{
            .tail = &.{
                0x0003_0016, 6,           32,
                0x0004_002b, 6,           7,
                1,           0x0006_014b, 1,
                38,          7,           4,
                5,
            },
            .expected = error.SpirvMalformed,
        },
        .{
            .tail = &.{
                0x0004_002b, 2, 6,           0,
                0x0006_0034, 2, 7,           134,
                3,           6, 0x0006_014b, 1,
                38,          7, 4,           5,
            },
            .expected = error.SpirvMalformed,
        },
    };
    for (cases) |case| {
        const words = try workgroupModule(std.testing.allocator, case.tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectError(case.expected, module.resolveWorkgroupSize(1, &.{}));
    }
}

test "spirv: workgroup dependency depth exhaustion is an explicit bounded error" {
    var tail: [65 * 6 + 6]Word = undefined;
    for (0..65) |index| {
        const id: u32 = @intCast(10 + index);
        const child: u32 = if (index == 64) 3 else id + 1;
        @memcpy(tail[index * 6 ..][0..6], &[_]Word{ 0x0006_0034, 2, id, 128, child, 5 });
    }
    @memcpy(tail[65 * 6 ..][0..6], &[_]Word{ 0x0006_014b, 1, 38, 10, 4, 5 });
    const words = try workgroupModule(std.testing.allocator, &tail);
    defer std.testing.allocator.free(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expectError(error.SpirvWorkgroupLimit, module.resolveWorkgroupSize(1, &.{}));
}

test "spirv: workgroup group SpecId aliases resolve without names or result-id override keys" {
    const tail = [_]Word{
        0x0004_0032, 2,           6,           3,
        0x0003_0005, 3,           0x0000_0078, 0x0003_0005,
        6,           0x0000_0078, 0x0002_0049, 8,
        0x0004_0047, 8,           1,           7,
        0x0003_004a, 8,           6,           0x0006_014b,
        1,           38,          3,           6,
        5,
    };
    const words = try workgroupModule(std.testing.allocator, &tail);
    defer std.testing.allocator.free(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expectEqual([3]u32{ 8, 3, 1 }, try module.resolveWorkgroupSize(1, &.{}));
    try std.testing.expectEqual(
        [3]u32{ 12, 12, 1 },
        try module.resolveWorkgroupSize(
            1,
            &.{
                .{
                    .spec_id = 7,
                    .size = 4,
                    .bits = 12,
                },
            },
        ),
    );
    try std.testing.expectError(
        error.SpirvWorkgroupOverride,
        module.resolveWorkgroupSize(
            1,
            &.{
                .{
                    .spec_id = 3,
                    .size = 4,
                    .bits = 12,
                },
            },
        ),
    );
    try std.testing.expectError(error.SpirvWorkgroupOverride, module.resolveWorkgroupSize(1, &.{
        .{ .spec_id = 7, .size = 4, .bits = 12 },
        .{ .spec_id = 7, .size = 4, .bits = 12 },
    }));
}

test "spirv: non-compute entry rejects workgroup modes and resolution" {
    var words = workgroup_base;
    words[6] = 0;
    const module = try spirv.reflect(std.testing.allocator, &words);
    defer module.deinit();
    try std.testing.expectError(error.SpirvWorkgroupEntryPoint, module.resolveWorkgroupSize(1, &.{}));
    const combined = try std.testing.allocator.alloc(Word, words.len + 6);
    defer std.testing.allocator.free(combined);
    @memcpy(combined[0..words.len], &words);
    @memcpy(combined[words.len..], &[_]Word{ 0x0006_0010, 1, 17, 1, 1, 1 });
    try std.testing.expectError(error.SpirvMalformed, spirv.reflect(std.testing.allocator, combined));
}

test "spirv: repeated dependency evaluation has a bounded operation budget" {
    var tail: [12 * 6 + 6]Word = undefined;
    for (0..12) |index| {
        const id: u32 = @intCast(10 + index);
        const child: u32 = if (index == 11) 3 else id + 1;
        @memcpy(tail[index * 6 ..][0..6], &[_]Word{ 0x0006_0034, 2, id, 197, child, child });
    }
    @memcpy(tail[12 * 6 ..][0..6], &[_]Word{ 0x0006_014b, 1, 38, 10, 4, 5 });
    const words = try workgroupModule(std.testing.allocator, &tail);
    defer std.testing.allocator.free(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expectError(error.SpirvWorkgroupLimit, module.resolveWorkgroupSize(1, &.{}));
}

test "spirv: canonical byte view resolves identical normalized workgroup overrides" {
    const module = try spirv.reflect(std.testing.allocator, &workgroup_words);
    defer module.deinit();
    const canonical = [_]u8{ 7, 0, 0, 0, 2, 32, 4, 16, 0, 0, 0 };
    try std.testing.expectEqual([3]u32{ 16, 16, 1 }, try module.resolveWorkgroupSizeCanonical(1, &canonical));
    try std.testing.expectEqual([3]u32{ 8, 2, 1 }, try module.resolveWorkgroupSizeCanonical(1, &.{}));
    for (0..canonical.len) |length| {
        if (length == 0) continue;
        try std.testing.expectError(
            error.SpirvWorkgroupOverride,
            module.resolveWorkgroupSizeCanonical(1, canonical[0..length]),
        );
    }
    const duplicate = canonical ++ canonical;
    try std.testing.expectError(error.SpirvWorkgroupOverride, module.resolveWorkgroupSizeCanonical(1, &duplicate));
    var invalid = canonical;
    invalid[6] = 3;
    try std.testing.expectError(error.SpirvWorkgroupOverride, module.resolveWorkgroupSizeCanonical(1, &invalid));
}

test "spirv: malformed composite constituents and indices reject effective workgroup resolution" {
    const tails = [_][]const Word{
        &.{ 0x0004_0017, 6, 2, 3, 0x0005_0033, 6, 7, 3, 4, 0x0004_0047, 7, 11, 25 },
        &.{ 0x0004_0017, 6, 2, 3, 0x0006_0033, 6, 7, 3, 4, 99, 0x0004_0047, 7, 11, 25 },
        &.{
            0x0004_0017, 6,  2,           3,
            0x0006_0033, 6,  7,           3,
            4,           5,  0x0006_0034, 2,
            8,           81, 7,           3,
            0x0006_014b, 1,  38,          8,
            4,           5,
        },
        &.{
            0x0003_0016, 9,           32,
            0x0004_002b, 9,           10,
            1,           0x0004_0017, 6,
            2,           3,           0x0006_0033,
            6,           7,           3,
            4,           10,          0x0004_0047,
            7,           11,          25,
        },
    };
    for (tails) |tail| {
        const words = try workgroupModule(std.testing.allocator, tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectError(error.SpirvMalformed, module.resolveWorkgroupSize(1, &.{}));
    }
}

test "spirv: integer workgroup expressions retain low 32 bits" {
    const cases = [_]struct { operation: u32, left: u32, right: u32, expected: u32 }{
        .{ .operation = 128, .left = 0xffff_ffff, .right = 2, .expected = 1 },
        .{ .operation = 130, .left = 0, .right = 1, .expected = 3 },
        .{ .operation = 132, .left = 0x8000_0001, .right = 2, .expected = 2 },
        .{ .operation = 196, .left = 0x8000_0001, .right = 1, .expected = 2 },
    };
    for (cases) |case| {
        const tail = [_]Word{
            0x0004_002b, 2,   6,           case.left,
            0x0004_002b, 2,   7,           case.right,
            0x0006_0034, 2,   8,           case.operation,
            6,           7,   0x0004_002b, 2,
            10,          3,   0x0006_0034, 2,
            11,          199, 8,           10,
            0x0006_014b, 1,   38,          11,
            4,           5,
        };
        const words = try workgroupModule(std.testing.allocator, &tail);
        defer std.testing.allocator.free(words);
        const original = try std.testing.allocator.dupe(Word, words);
        defer std.testing.allocator.free(original);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectEqual([3]u32{ case.expected, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
        try std.testing.expectEqualSlices(Word, original, words);
    }
}

test "spirv: signed specialization defaults and overrides preserve bit patterns" {
    const tail = [_]Word{
        0x0004_0015, 6, 32,          1,
        0x0004_0032, 6, 7,           0xffff_ffff,
        0x0004_0047, 7, 1,           9,
        0x0006_0034, 6, 8,           199,
        7,           5, 0x0006_014b, 1,
        38,          8, 4,           5,
    };
    const words = try workgroupModule(std.testing.allocator, &tail);
    defer std.testing.allocator.free(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expectEqual([3]u32{ 1, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
    try std.testing.expectEqual([3]u32{ 1, 2, 1 }, try module.resolveWorkgroupSize(
        1,
        &.{.{ .spec_id = 9, .size = 4, .bits = 0xffff_ffff }},
    ));
    const canonical = [_]u8{ 9, 0, 0, 0, 1, 32, 4, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectEqual([3]u32{ 1, 2, 1 }, try module.resolveWorkgroupSizeCanonical(1, &canonical));
}

test "spirv: arithmetic bitwise and shifts accept compatible distinct integer types" {
    for ([_]u32{ 128, 130, 132, 194, 196, 197, 198, 199 }) |operation| {
        const tail = [_]Word{
            0x0004_0015, 6,  32,          1,
            0x0004_0015, 7,  32,          0,
            0x0004_002b, 6,  8,           4,
            0x0004_002b, 7,  10,          1,
            0x0006_0034, 2,  11,          operation,
            8,           10, 0x0006_014b, 1,
            38,          11, 4,           5,
        };
        const words = try workgroupModule(std.testing.allocator, &tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        const expected: u32 = switch (operation) {
            128, 197, 198 => 5,
            130 => 3,
            132 => 4,
            194 => 2,
            196 => 8,
            199 => 0,
            else => unreachable,
        };
        try std.testing.expectEqual([3]u32{ expected, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
    }
}

test "spirv: unsigned division and modulo require unsigned result and exact operand types" {
    for ([_]u32{ 134, 137 }) |operation| {
        for ([_]u32{ 0, 1 }) |signedness| {
            const tail = [_]Word{
                0x0004_0015, 6,                                        32,          signedness,
                0x0004_002b, 6,                                        7,           4,
                0x0004_002b, 6,                                        8,           2,
                0x0006_0034, if (signedness == 1) @as(Word, 6) else 2, 10,          operation,
                7,           8,                                        0x0006_014b, 1,
                38,          10,                                       4,           5,
            };
            const words = try workgroupModule(std.testing.allocator, &tail);
            defer std.testing.allocator.free(words);
            const module = try spirv.reflect(std.testing.allocator, words);
            defer module.deinit();
            try std.testing.expectError(error.SpirvMalformed, module.resolveWorkgroupSize(1, &.{}));
        }
    }
}

test "spirv: LocalSizeId presence is per entry and survives builtin precedence" {
    const tail = [_]Word{
        0x0005_000f, 5,           9,  0x7265_6874, 0,
        0x0006_014b, 1,           38, 3,           4,
        5,           0x0004_0017, 6,  2,           3,
        0x0006_0033, 6,           7,  3,           4,
        5,           0x0004_0047, 7,  11,          25,
    };
    const words = try workgroupModule(std.testing.allocator, &tail);
    defer std.testing.allocator.free(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expect(module.entry_points[0].has_local_size_id);
    try std.testing.expect(!module.entry_points[1].has_local_size_id);
    for (module.entry_points) |entry| try std.testing.expect(entry.workgroup_size == .builtin);
}

test "spirv: shift amounts evaluate supported expressions at their own integer width" {
    const cases = [_]struct { operation: u32, amount: u32 }{
        .{ .operation = 128, .amount = 6 },
        .{ .operation = 130, .amount = 2 },
        .{ .operation = 132, .amount = 8 },
        .{ .operation = 134, .amount = 2 },
        .{ .operation = 137, .amount = 0 },
        .{ .operation = 194, .amount = 1 },
        .{ .operation = 196, .amount = 16 },
        .{ .operation = 197, .amount = 6 },
        .{ .operation = 198, .amount = 6 },
        .{ .operation = 199, .amount = 0 },
    };
    for ([_]u32{ 8, 16, 64 }) |width| {
        for (cases) |case| {
            const opcode: Word = if (width == 64) 0x0005_0032 else 0x0004_0032;
            const constant_opcode: Word = if (width == 64) 0x0005_002b else 0x0004_002b;
            const padding: Word = if (width == 64) 0 else op_nop;
            const tail = [_]Word{
                0x0004_0015, 6,               width,       0,
                opcode,      6,               7,           4,
                padding,     0x0004_0047,     7,           1,
                9,           constant_opcode, 6,           8,
                2,           padding,         0x0006_0034, 6,
                10,          case.operation,  7,           8,
                0x0006_0034, 2,               11,          196,
                3,           10,              0x0006_0034, 2,
                12,          194,             3,           10,
                0x0006_014b, 1,               38,          11,
                12,          5,
            };
            const words = try workgroupModule(std.testing.allocator, &tail);
            defer std.testing.allocator.free(words);
            const module = try spirv.reflect(std.testing.allocator, words);
            defer module.deinit();
            const shift: u5 = @intCast(case.amount);
            const expected = [3]u32{ @as(u32, 8) << shift, @as(u32, 8) >> shift, 1 };
            try std.testing.expectEqual(expected, try module.resolveWorkgroupSize(1, &.{}));
            try std.testing.expectEqual(expected, try module.resolveWorkgroupSize(
                1,
                &.{.{ .spec_id = 9, .size = @intCast(width / 8), .bits = 4 }},
            ));
        }
    }
}

test "spirv: shift expression wrapping uses its component width before range validation" {
    for ([_]u32{ 8, 16, 64 }) |width| {
        const opcode: Word = if (width == 64) 0x0005_0032 else 0x0004_0032;
        const constant_opcode: Word = if (width == 64) 0x0005_002b else 0x0004_002b;
        const high: Word = if (width == 64) 0xffff_ffff else op_nop;
        const padding: Word = if (width == 64) 0 else op_nop;
        const low: Word = switch (width) {
            8 => 0xff,
            16 => 0xffff,
            64 => 0xffff_ffff,
            else => unreachable,
        };
        const tail = [_]Word{
            0x0004_0015, 6,               width,       1,
            opcode,      6,               7,           low,
            high,        0x0004_0047,     7,           1,
            9,           constant_opcode, 6,           8,
            2,           padding,         0x0006_0034, 6,
            10,          128,             7,           8,
            0x0006_0034, 2,               11,          196,
            3,           10,              0x0006_014b, 1,
            38,          11,              4,           5,
        };
        const words = try workgroupModule(std.testing.allocator, &tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectEqual([3]u32{ 16, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
        const bits: u64 = if (width == 64) 0xffff_ffff_ffff_ffff else low;
        try std.testing.expectEqual([3]u32{ 16, 2, 1 }, try module.resolveWorkgroupSize(
            1,
            &.{.{ .spec_id = 9, .size = @intCast(width / 8), .bits = bits }},
        ));
    }
}

test "spirv: malformed operand widths signed shift counts and wide axes remain rejected" {
    const tails = [_][]const Word{
        // Add/bitwise operands must match result width.
        &.{ 0x0004_0015, 6, 16, 0, 0x0004_002b, 6, 7, 1, 0x0006_0034, 2, 8, 128, 3, 7, 0x0006_014b, 1, 38, 8, 4, 5 },
        &.{ 0x0004_0015, 6, 16, 0, 0x0004_002b, 6, 7, 1, 0x0006_0034, 2, 8, 199, 3, 7, 0x0006_014b, 1, 38, 8, 4, 5 },
        // A shift base must match result width.
        &.{ 0x0004_0015, 6, 16, 0, 0x0004_002b, 6, 7, 1, 0x0006_0034, 2, 8, 196, 7, 5, 0x0006_014b, 1, 38, 8, 4, 5 },
        // Signed shift counts are consumed as unsigned bit patterns.
        &.{
            0x0004_0015, 6, 32,          1,
            0x0004_002b, 6, 7,           0xffff_ffff,
            0x0006_0034, 2, 8,           194,
            3,           7, 0x0006_014b, 1,
            38,          8, 4,           5,
        },
        // Do not truncate a wide count before the undefined-shift check.
        &.{ 0x0004_0015, 6, 64, 0, 0x0005_002b, 6, 7, 1, 1, 0x0006_0034, 2, 8, 196, 3, 7, 0x0006_014b, 1, 38, 8, 4, 5 },
        // Workgroup axes themselves are still 32-bit.
        &.{ 0x0004_0015, 6, 16, 0, 0x0004_002b, 6, 7, 1, 0x0006_014b, 1, 38, 7, 4, 5 },
    };
    for (tails) |tail| {
        const words = try workgroupModule(std.testing.allocator, tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectError(error.SpirvMalformed, module.resolveWorkgroupSize(1, &.{}));
    }
}

test "spirv: signed arithmetic intermediates keep negative result bits" {
    const cases = [_]struct { operation: u32, left: u32, right: u32 }{
        .{ .operation = 128, .left = 0x7fff_ffff, .right = 2 },
        .{ .operation = 130, .left = 0, .right = 0x7fff_ffff },
        .{ .operation = 132, .left = 0x8000_0001, .right = 1 },
        .{ .operation = 196, .left = 0x4000_0000, .right = 1 },
    };
    for (cases) |case| {
        const tail = [_]Word{
            0x0004_0015, 6,           32,          1,
            0x0004_002b, 6,           7,           case.left,
            0x0004_002b, 6,           8,           case.right,
            0x0006_0034, 6,           10,          case.operation,
            7,           8,           0x0004_002b, 2,
            11,          0x8000_0000, 0x0006_0034, 2,
            12,          199,         10,          11,
            0x0006_0034, 2,           13,          194,
            12,          14,          0x0004_002b, 2,
            14,          31,          0x0006_014b, 1,
            38,          13,          4,           5,
        };
        const words = try workgroupModule(std.testing.allocator, &tail);
        defer std.testing.allocator.free(words);
        const module = try spirv.reflect(std.testing.allocator, words);
        defer module.deinit();
        try std.testing.expectEqual([3]u32{ 1, 2, 1 }, try module.resolveWorkgroupSize(1, &.{}));
    }
}

test "spirv: pre14 compute descriptors are reflected outside the entry interface" {
    const fixture = @import("fixtures/workgroup_compute.zig");
    const before = fixture.words;
    try spirv.validate(&fixture.words);
    const module = try spirv.reflect(std.testing.allocator, &fixture.words);
    defer module.deinit();
    const entry = module.findEntryPoint("main") orelse return error.MissingComputeEntryPoint;
    try std.testing.expectEqual(@as(usize, 1), entry.resources.len);
    try std.testing.expectEqual(spirv.ResourceKind.storage_buffer, entry.resources[0].kind);
    try std.testing.expectEqual(@as(u32, 0), entry.resources[0].set);
    try std.testing.expectEqual(@as(u32, 0), entry.resources[0].binding);
    try std.testing.expectEqualSlices(Word, &before, &fixture.words);
    try std.testing.expectEqual(@intFromPtr(&fixture.words), @intFromPtr(module.words.ptr));
}

// Three entries isolate direct use, transitive use, and a resource passed as an argument.
const resource_use_words = [_]Word{
    spirv.magic_number, version_1_0, 0,           1000, 0,
    0x0002_0011,        1,           0x0003_000e, 0,    1,
    0x0005_000f, 5, 20, 0x6572_6964, 0x0000_7463, // "direct"
    0x0005_000f, 5, 21, 0x6c6c_6163, 0x0000_7265, // "caller"
    0x0004_000f, 5,  22,          0x0067_7261, // "arg"
    0x0006_0010, 20, 17,          1,
    1,           1,  0x0006_0010, 21,
    17,          1,  1,           1,
    0x0006_0010, 22, 17,          1,
    1,           1,
    0x0003_0007, 9, 0x0000_0078, // OpString "x"
    0x0003_0047, 4,           3, // BufferBlock
    0x0005_0048, 4,           0,
    35,          0,           0x0004_0047,
    10,          34,          0,
    0x0004_0047, 10,          33,
    0,           0x0004_0047, 11,
    34,          2,           0x0004_0047,
    11,          33,          7,
    0x0004_0047, 12,          34,
    3,           0x0004_0047, 12,
    33,          9,
    0x0002_0013, 1, // void
    0x0003_0021, 2,           1, // void()
    0x0004_0015, 3,           32,
    0,           0x0003_001e, 4,
    3,
    0x0004_0020, 5, 2, 4, // Uniform struct pointer
    0x0004_0020, 6, 2, 3, // Uniform scalar pointer
    0x0004_002b, 3, 7, 0,
    0x0004_0021, 8,           1,  5, // void(Uniform struct pointer)
    0x0004_003b, 5,           10, 2,
    0x0004_003b, 5,           11, 2,
    0x0004_003b, 5,           12, 2,
    0x0005_0036, 1,           20, 0,
    2,           0x0002_00f8, 40,
    0x0004_0008, 9,           12,          1, // OpLine literal 12 is not a descriptor use.
    0x0005_0041, 6,           41,          10,
    7,           0x0004_003d, 3,           42,
    41,          0x0001_00fd, 0x0001_0038, 0x0005_0036,
    1,           21,          0,           2,
    0x0002_00f8, 43,          0x0004_0039, 1,
    44,          30,          0x0004_0039, 1,
    45,          30,          0x0005_0039, 1,
    46,          32,          11,          0x0001_00fd,
    0x0001_0038, 0x0005_0036, 1,           22,
    0,           2,           0x0002_00f8, 56,
    0x0005_0039, 1,           57,          32,
    12,          0x0001_00fd, 0x0001_0038, 0x0005_0036,
    1,           30,          0,           2,
    0x0002_00f8, 47,          0x0004_0039, 1,
    48,          31,          0x0001_00fd, 0x0001_0038,
    0x0005_0036, 1,           31,          0,
    2,           0x0002_00f8, 49,          0x0005_0041,
    6,           50,          11,          7,
    0x0004_003d, 3,           51,          50,
    0x0001_00fd, 0x0001_0038, 0x0005_0036, 1,
    32,          0,           8,           0x0003_0037,
    5,           52,          0x0002_00f8, 53,
    0x0005_0041, 6,           54,          52,
    7,           0x0004_003d, 3,           55,
    54,          0x0001_00fd, 0x0001_0038,
};

test "spirv: static resource use follows entry call trees without literal or global leakage" {
    try spirv.validate(&resource_use_words);
    const before = resource_use_words;
    const module = try spirv.reflect(std.testing.allocator, &resource_use_words);
    defer module.deinit();
    const direct = module.findEntryPoint("direct") orelse return error.MissingDirectEntry;
    const caller = module.findEntryPoint("caller") orelse return error.MissingCallerEntry;
    const argument = module.findEntryPoint("arg") orelse return error.MissingArgumentEntry;
    try std.testing.expectEqual(@as(usize, 1), direct.resources.len);
    try std.testing.expectEqual(@as(u32, 0), direct.resources[0].set);
    try std.testing.expectEqual(@as(u32, 0), direct.resources[0].binding);
    try std.testing.expectEqual(@as(usize, 1), caller.resources.len);
    try std.testing.expectEqual(@as(u32, 2), caller.resources[0].set);
    try std.testing.expectEqual(@as(u32, 7), caller.resources[0].binding);
    try std.testing.expectEqual(@as(usize, 1), argument.resources.len);
    try std.testing.expectEqual(@as(u32, 3), argument.resources[0].set);
    try std.testing.expectEqual(@as(u32, 9), argument.resources[0].binding);
    try std.testing.expectEqualSlices(Word, &before, &resource_use_words);
}

test "spirv: static resource call graph allocations release every partial result" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocateResourceUseReflection,
        .{},
    );
}

fn allocateResourceUseReflection(allocator: std.mem.Allocator) !void {
    const module = try spirv.reflect(allocator, &resource_use_words);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.entry_points[1].resources.len);
}

const resource_metadata_words = [_]Word{
    spirv.magic_number, 0x0001_0400, 0, 100, 0,
    0x0002_0011,        1,
    0x0002_0011, 48, // ImageMSArray.
    0x0003_000e, 0,
    1,           0x0009_000f,
    5,           30,
    0x6e69_616d, 0,
    20,          21,
    22,          23,
    0x0006_0010, 30,
    17,          1,
    1,           1,
    0x0004_0047, 20,
    34,          0,
    0x0004_0047, 20,
    33,          0,
    0x0004_0047, 21,
    34,          0,
    0x0004_0047, 21,
    33,          1,
    0x0003_0047, 21,          25, // NonReadable storage image.
    0x0004_0047, 22,          34,
    0,           0x0004_0047, 22,
    33,          2,
    0x0003_0047, 10,          2, // Block.
    0x0005_0048, 10,          0,
    35,          0,           0x0005_0048,
    10,          1,           35,
    4,           0x0004_0048, 10,
    0,           24,
    0x0004_0048, 10, 1,  24, // Every struct member NonWritable.
    0x0004_0047, 23, 34, 0,
    0x0004_0047, 23, 33, 3,
    0x0003_0047, 23, 24, // Variable NonWritable remains independent of member coverage.
    0x0002_0013, 1,  0x0003_0021,
    2,           1,  0x0003_0016,
    3,           32,
    0x0009_0019, 4, 3,  1, 0, 1, 1, 1, 0, // float 2D array multisampled.
    0x0004_0015, 6, 32, 1,
    0x0009_0019, 5, 6,  2, 0,           0, 0, 2, 24, // sint 3D storage R32i.
    0x0004_0015, 9, 32, 0, 0x0004_002b, 9, 8, 2,
    0x0004_001c, 7,           4,  8, // Descriptor array count 2.
    0x0004_001e, 10,          9,  9,
    0x0004_0020, 11,          0,  7,
    0x0004_0020, 12,          0,  5,
    0x0004_0020, 13,          12, 10,
    0x0004_003b, 11,          20, 0,
    0x0004_003b, 12,          21, 0,
    0x0004_003b, 13,          22, 12,
    0x0004_003b, 13,          23, 12,
    0x0005_0036, 1,           30, 0,
    2,           0x0002_00f8, 31, 0x0001_00fd,
    0x0001_0038,
};

test "spirv: 14 declared interfaces preserve descriptor image array and access metadata" {
    try spirv.validate(&resource_metadata_words);
    const module = try spirv.reflect(std.testing.allocator, &resource_metadata_words);
    defer module.deinit();
    const resources = module.entry_points[0].resources;
    try std.testing.expectEqual(@as(usize, 4), resources.len);
    try std.testing.expectEqual(@as(u32, 2), resources[0].array_size);
    try std.testing.expectEqual(spirv.Dim.two_dimensional, resources[0].image_dimension.?);
    try std.testing.expect(resources[0].image_arrayed);
    try std.testing.expect(resources[0].image_multisampled);
    try std.testing.expectEqual(@as(u32, 32), resources[0].sampled_scalar.?.float);
    try std.testing.expectEqual(spirv.Dim.three_dimensional, resources[1].image_dimension.?);
    try std.testing.expectEqual(@as(u32, 24), resources[1].image_format.?);
    try std.testing.expectEqual(@as(u32, 32), resources[1].sampled_scalar.?.signed_integer);
    try std.testing.expect(resources[1].storage_write_only);
    try std.testing.expect(!resources[1].storage_read_only);
    try std.testing.expect(resources[2].buffer_read_only);
    try std.testing.expect(resources[3].buffer_read_only);
}

test "spirv: one readonly member does not make the whole storage buffer readonly" {
    var words = resource_metadata_words;
    var offset: usize = spirv.header_word_count;
    while (offset < words.len) {
        const count = spirv.wordCountOf(words[offset]);
        if (spirv.opcodeOf(words[offset]) == 72 and words[offset + 1] == 10 and
            words[offset + 2] == 1 and words[offset + 3] == 24)
        {
            words[offset + 3] = 0; // RelaxedPrecision, not NonWritable.
        }
        offset += count;
    }
    try spirv.validate(&words);
    const module = try spirv.reflect(std.testing.allocator, &words);
    defer module.deinit();
    try std.testing.expect(!module.entry_points[0].resources[2].buffer_read_only);
    try std.testing.expect(module.entry_points[0].resources[3].buffer_read_only);
}

test "spirv: image declarations preserve unknown depth sampled use and format" {
    var words = resource_metadata_words;
    var offset: usize = spirv.header_word_count;
    while (offset < words.len) {
        const count = spirv.wordCountOf(words[offset]);
        if (spirv.opcodeOf(words[offset]) == 25 and words[offset + 1] == 4) {
            words[offset + 4] = 2;
            words[offset + 7] = 0;
        }
        if (spirv.opcodeOf(words[offset]) == 25 and words[offset + 1] == 5)
            words[offset + 8] = 0;
        offset += count;
    }
    try spirv.validate(&words);
    const module = try spirv.reflect(std.testing.allocator, &words);
    defer module.deinit();
    try std.testing.expectEqual(@as(u32, 2), module.entry_points[0].resources[0].image_depth_mode.?);
    try std.testing.expectEqual(@as(u32, 0), module.entry_points[0].resources[0].image_sampled.?);
    try std.testing.expect(!module.entry_points[0].resources[0].image_depth);
    try std.testing.expectEqual(@as(u32, 0), module.entry_points[0].resources[1].image_format.?);
}

test "spirv: resource metadata allocation failures release declaration and member tables" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocateResourceMetadata,
        .{},
    );
}

fn allocateResourceMetadata(allocator: std.mem.Allocator) !void {
    const module = try spirv.reflect(allocator, &resource_metadata_words);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 4), module.entry_points[0].resources.len);
}

fn longResourceCallTree(allocator: std.mem.Allocator) ![]Word {
    const depth = 70;
    const words = try allocator.alloc(Word, resource_use_words.len + depth * 13);
    errdefer allocator.free(words);
    @memcpy(words[0..resource_use_words.len], &resource_use_words);
    var offset: usize = spirv.header_word_count;
    var current_function: u32 = 0;
    while (offset < resource_use_words.len) {
        const opcode = spirv.opcodeOf(words[offset]);
        const count = spirv.wordCountOf(words[offset]);
        if (opcode == 54) current_function = words[offset + 2];
        if (opcode == 57 and current_function == 21 and words[offset + 3] == 30)
            words[offset + 3] = 100;
        offset += count;
    }
    for (0..depth) |index| {
        const id: u32 = @intCast(100 + index);
        const callee: u32 = if (index + 1 == depth) 30 else id + 1;
        const label: u32 = @intCast(400 + index);
        const result: u32 = @intCast(300 + index);
        @memcpy(words[resource_use_words.len + index * 13 ..][0..13], &[_]Word{
            0x0005_0036, 1,           id,          0, 2,
            0x0002_00f8, label,       0x0004_0039, 1, result,
            callee,      0x0001_00fd, 0x0001_0038,
        });
    }
    return words;
}

test "spirv: reachable resource functions have no arbitrary recursion depth limit" {
    const words = try longResourceCallTree(std.testing.allocator);
    defer std.testing.allocator.free(words);
    try spirv.validate(words);
    const module = try spirv.reflect(std.testing.allocator, words);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.entry_points[1].resources.len);
    try std.testing.expectEqual(@as(u32, 2), module.entry_points[1].resources[0].set);
    try std.testing.expectEqual(@as(u32, 7), module.entry_points[1].resources[0].binding);
}

test "spirv: unvalidated cyclic call graphs terminate and deduplicate resources" {
    // Recursion is not a valid Vulkan shader. Reflection must still terminate before validation.
    var words: std.ArrayList(Word) = .empty;
    defer words.deinit(std.testing.allocator);
    try words.appendSlice(std.testing.allocator, resource_use_words[0..spirv.header_word_count]);
    var offset: usize = spirv.header_word_count;
    var current_function: u32 = 0;
    while (offset < resource_use_words.len) {
        const opcode = spirv.opcodeOf(resource_use_words[offset]);
        const count = spirv.wordCountOf(resource_use_words[offset]);
        if (opcode == 54) current_function = resource_use_words[offset + 2];
        if (opcode == 253 and current_function == 31) {
            try words.appendSlice(std.testing.allocator, &.{ 0x0004_0039, 1, 60, 30 });
        }
        try words.appendSlice(std.testing.allocator, resource_use_words[offset..][0..count]);
        offset += count;
    }
    const module = try spirv.reflect(std.testing.allocator, words.items);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.entry_points[1].resources.len);
    try std.testing.expectEqual(@as(u32, 7), module.entry_points[1].resources[0].binding);
}

test "spirv: resource call graph rejects out-of-bound function references without changing words" {
    var words = resource_use_words;
    var offset: usize = spirv.header_word_count;
    while (offset < words.len) {
        const count = spirv.wordCountOf(words[offset]);
        if (spirv.opcodeOf(words[offset]) == 57) {
            words[offset + 3] = words[3];
            break;
        }
        offset += count;
    }
    const before = words;
    try std.testing.expectError(error.SpirvMalformed, spirv.reflect(std.testing.allocator, &words));
    try std.testing.expectEqualSlices(Word, &before, &words);
    // The validator owns truncated instruction rejection, not an invented valid-module marker.
    try std.testing.expectError(
        error.SpirvMalformed,
        spirv.validate(resource_use_words[0 .. resource_use_words.len - 3]),
    );
}

test "spirv: group member access decorations contribute to whole-buffer readonly metadata" {
    try groupMemberResourceMetadata(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        groupMemberResourceMetadata,
        .{},
    );
}

fn groupMemberResourceMetadata(allocator: std.mem.Allocator) !void {
    var words: std.ArrayList(Word) = .empty;
    defer words.deinit(allocator);
    try words.appendSlice(allocator, resource_metadata_words[0..spirv.header_word_count]);
    var offset: usize = spirv.header_word_count;
    while (offset < resource_metadata_words.len) {
        const opcode = spirv.opcodeOf(resource_metadata_words[offset]);
        const count = spirv.wordCountOf(resource_metadata_words[offset]);
        if (opcode == 19) {
            try words.appendSlice(allocator, &.{
                0x0002_0049, 40,
                0x0003_0047, 40,
                24,          0x0004_004b,
                40,          10,
                1,
            });
        }
        const grouped_member = opcode == 72 and resource_metadata_words[offset + 1] == 10 and
            resource_metadata_words[offset + 2] == 1 and
            resource_metadata_words[offset + 3] == 24;
        if (!grouped_member) {
            try words.appendSlice(allocator, resource_metadata_words[offset..][0..count]);
        }
        offset += count;
    }
    try spirv.validate(words.items);
    const module = try spirv.reflect(allocator, words.items);
    defer module.deinit();
    try std.testing.expect(module.entry_points[0].resources[2].buffer_read_only);
    try std.testing.expectEqual(@as(u32, 2), module.entry_points[0].resources[0].array_size);
}
