//! One SPIR-V word, the two fields an instruction header word carries, and the
//! literal string decoding the reader needs.
//!
//! **What this file does not claim.** It does not claim to accept a module in
//! both byte orders. SPIR-V fixes the magic number in a little-endian word, and
//! the caller's own words reach `vkCreateShaderModule`, so the port reads
//! little-endian and never swaps.

const std = @import("std");
const builtin = @import("builtin");
const error_mod = @import("error.zig");

const Error = error_mod.Error;
const ErrorOrOutOfMemory = error_mod.ErrorOrOutOfMemory;

/// A SPIR-V word. Every word in a module is four bytes, and Vulkan takes the
/// module as `const uint32_t*`, so this is the type that crosses the seam.
pub const Word = u32;

/// Word zero of every module.
pub const magic_number: Word = 0x0723_0203;

/// The magic number with its bytes swapped. A module in this form is rejected
/// rather than repaired, because repairing it would mean rewriting the words
/// the caller handed over.
pub const swapped_magic_number: Word = 0x0302_2307;

/// The low sixteen bits of an instruction header word.
pub fn opcodeOf(instruction_word: Word) u16 {
    return @truncate(instruction_word);
}

/// The high sixteen bits of an instruction header word. It counts the header
/// word itself, so an instruction always spans at least one word.
pub fn wordCountOf(instruction_word: Word) u16 {
    return @truncate(instruction_word >> 16);
}

/// The header word an opcode and its total word count make.
pub fn makeInstructionWord(opcode: u16, word_count: u16) Word {
    return (@as(Word, word_count) << 16) | opcode;
}

/// The words a byte slice holds, read little-endian.
///
/// This copies. The copy is what the reader walks; the caller's bytes stay
/// untouched and are what reach Vulkan.
pub fn wordsFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ErrorOrOutOfMemory![]Word {
    if (bytes.len % @sizeOf(Word) != 0) return error.SpirvMalformed;
    const words = try allocator.alloc(Word, bytes.len / @sizeOf(Word));
    for (words, 0..) |*destination, index| {
        const start = index * @sizeOf(Word);
        destination.* = std.mem.readInt(Word, bytes[start..][0..@sizeOf(Word)], .little);
    }
    return words;
}

/// A literal byte is packed from the least-significant end of each word,
/// independent of the host's memory byte order.
fn stringByte(words: []const Word, index: usize) u8 {
    return @truncate(words[index / 4] >> @as(u5, @intCast((index % 4) * 8)));
}

fn terminatorAt(words: []const Word) ?usize {
    if (builtin.target.cpu.arch.endian() == .little)
        return std.mem.indexOfScalar(u8, std.mem.sliceAsBytes(words), 0);
    for (words, 0..) |value, index| {
        inline for (0..4) |byte| {
            if (@as(u8, @truncate(value >> (byte * 8))) == 0)
                return index * 4 + byte;
        }
    }
    return null;
}

/// One past the word that carries the terminator of a packed literal string
/// starting at `words[0]`, or null when none of the words terminates one.
///
/// An instruction operand list can hold a string and then more operands, as
/// `OpEntryPoint` holds its name and then its interface.
pub fn stringEnd(words: []const Word) ?usize {
    const terminator = terminatorAt(words) orelse return null;
    // The string holds `terminator + 1` bytes and the last word is padded, so
    // the count rounds up.
    const byte_count = terminator + 1;
    return @divFloor(byte_count + @sizeOf(Word) - 1, @sizeOf(Word));
}

/// Check a packed name without allocating, including on big-endian hosts.
pub fn validateString(words: []const Word) Error!void {
    const len = terminatorAt(words) orelse return error.SpirvMalformed;
    if (builtin.target.cpu.arch.endian() == .little) {
        if (!std.unicode.utf8ValidateSlice(std.mem.sliceAsBytes(words)[0..len]))
            return error.SpirvMalformed;
        return;
    }
    var index: usize = 0;
    while (index < len) {
        var sequence: [4]u8 = undefined;
        sequence[0] = stringByte(words, index);
        const count = std.unicode.utf8ByteSequenceLength(sequence[0]) catch
            return error.SpirvMalformed;
        if (count > len - index) return error.SpirvMalformed;
        for (1..count) |offset| sequence[offset] = stringByte(words, index + offset);
        _ = std.unicode.utf8Decode(sequence[0..count]) catch return error.SpirvMalformed;
        index += count;
    }
}

/// Decode a NUL-terminated UTF-8 literal, excluding padding and later operands.
/// Little-endian hosts borrow the words. Big-endian hosts allocate from `arena`;
/// the returned text remains valid until that arena is released.
pub fn decodeString(arena: std.mem.Allocator, words: []const Word) ErrorOrOutOfMemory![]const u8 {
    const len = terminatorAt(words) orelse return error.SpirvMalformed;
    const text = if (builtin.target.cpu.arch.endian() == .little)
        std.mem.sliceAsBytes(words)[0..len]
    else text: {
        const bytes = try arena.alloc(u8, len);
        for (bytes, 0..) |*byte, index| byte.* = stringByte(words, index);
        break :text bytes;
    };
    errdefer if (builtin.target.cpu.arch.endian() == .big) arena.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) return error.SpirvMalformed;
    return text;
}
