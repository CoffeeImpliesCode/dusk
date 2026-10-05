//! One instruction, and a cursor that walks the instruction stream.
//!
//! An instruction is self-delimiting: its first word carries the opcode in the
//! low sixteen bits and the total word count, header word included, in the high
//! sixteen. That is what lets the reader walk a module it does not fully
//! understand, and it is why an instruction the port does not model is skipped
//! rather than refused.

const error_mod = @import("error.zig");
const grammar = @import("grammar.zig");
const header = @import("header.zig");
const word = @import("word.zig");

const Error = error_mod.Error;
const Word = word.Word;

pub const Instruction = struct {
    /// Every word of the instruction, header word first.
    words: []const Word,

    pub fn opcode(self: Instruction) u16 {
        return word.opcodeOf(self.words[0]);
    }

    pub fn wordCount(self: Instruction) u16 {
        return word.wordCountOf(self.words[0]);
    }

    /// Every word after the header word.
    pub fn operands(self: Instruction) []const Word {
        return self.words[1..];
    }

    /// The opcode when the port models it, and null when the module uses one
    /// the reader has no use for.
    pub fn knownOpcode(self: Instruction) ?grammar.Opcode {
        return grammar.Opcode.fromRaw(self.opcode());
    }
};

/// The instruction that starts at `index`.
fn read(words: []const Word, index: usize) Error!Instruction {
    const count = word.wordCountOf(words[index]);
    // A word count of zero would advance the cursor nowhere, so the walk would
    // never end. A count that runs past the module would read words that are
    // not there.
    if (count == 0) return error.SpirvMalformed;
    if (@as(usize, count) > words.len - index) return error.SpirvMalformed;
    return .{ .words = words[index..][0..@as(usize, count)] };
}

/// The operands of `OpEntryPoint`, which the validator and the reflector both
/// need and neither can get any other way.
pub const EntryPointFields = struct {
    execution_model: grammar.ExecutionModel,
    id: u32,
    name: []const u8,
    interface: []const Word,
};

/// `OpEntryPoint <execution model> <id> <name> <interface>...`.
///
/// The name is a packed literal string, so the interface starts after the word
/// the terminator lands in rather than at a fixed offset.
pub fn readEntryPoint(inst: Instruction) Error!EntryPointFields {
    const operands = inst.operands();
    if (operands.len < 3) return error.SpirvMalformed;

    const execution_model = grammar.ExecutionModel.fromRaw(operands[0]) orelse
        return error.SpirvMalformed;

    const name_word_count = word.stringEnd(operands[2..]) orelse
        return error.SpirvMalformed;

    return .{
        .execution_model = execution_model,
        .id = operands[1],
        .name = try word.decodeString(operands[2..][0..name_word_count]),
        .interface = operands[2 + name_word_count ..],
    };
}

/// Walks the instructions that follow the header, in the order they appear.
pub const Cursor = struct {
    words: []const Word,
    index: usize,

    pub fn init(words: []const Word) Cursor {
        return .{ .words = words, .index = header.word_count };
    }

    pub fn next(self: *Cursor) Error!?Instruction {
        if (self.index >= self.words.len) return null;
        const inst = try read(self.words, self.index);
        self.index += inst.words.len;
        return inst;
    }
};
