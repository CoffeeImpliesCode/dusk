//! One SPIR-V word, the two fields an instruction header word carries, and the
//! literal string decoding the reader needs.
//!
//! **What this file does not claim.** It does not claim to accept a module in
//! both byte orders. SPIR-V fixes the magic number in a little-endian word, and
//! the caller's own words reach `vkCreateShaderModule`, so the port reads
//! little-endian and never swaps.

const std = @import("std");
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

/// The words of an operand list seen as the bytes a packed string is made of.
fn stringBytes(words: []const Word) []const u8 {
    return std.mem.bytesAsSlice(u8, std.mem.sliceAsBytes(words));
}

/// Where the NUL that ends a packed string sits in its bytes, or null when the
/// slice holds none.
///
/// SPIR-V packs a literal string into whole words in byte order and pads the
/// last word with zeros, so the terminator is the first zero byte and not the
/// first word whose low byte is zero. `inner` packs as the bytes
/// `69 6e 6e 65 72 00 00 00` and ends at byte five.
fn terminatorAt(bytes: []const u8) ?usize {
    for (bytes, 0..) |byte, index| {
        if (byte == 0) return index;
    }
    return null;
}

/// One past the word that carries the terminator of a packed literal string
/// starting at `words[0]`, or null when none of the words terminates one.
///
/// An instruction operand list can hold a string and then more operands, as
/// `OpEntryPoint` holds its name and then its interface.
pub fn stringEnd(words: []const Word) ?usize {
    const terminator = terminatorAt(stringBytes(words)) orelse return null;
    // The string holds `terminator + 1` bytes and the last word is padded, so
    // the count rounds up.
    const byte_count = terminator + 1;
    return @divFloor(byte_count + @sizeOf(Word) - 1, @sizeOf(Word));
}

/// The literal string the words hold, borrowed from them.
///
/// A SPIR-V literal string is UTF-8 with an implicit NUL at its end. Bytes
/// after that NUL are the padding that fills the last word, and words after
/// that are the operands the instruction puts behind the string.
pub fn decodeString(words: []const Word) Error![]const u8 {
    const bytes = stringBytes(words);
    const terminator = terminatorAt(bytes) orelse return error.SpirvMalformed;

    const text = bytes[0..terminator];
    if (!std.unicode.utf8ValidateSlice(text)) return error.SpirvMalformed;
    return text;
}
