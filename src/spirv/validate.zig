//! The pass that decides whether a module may reach `vkCreateShaderModule`.
//!
//! `docs/10-architecture.md` "Shaders" puts this between the caller's bytes and
//! Vulkan, and `AGENTS.md` §3.2 fixes the two halves of the contract: the port
//! validates and reflects, and the caller's own words reach Vulkan. This file
//! only reads.
//!
//! **What this file does not claim.** It does not claim the port accepts
//! exactly what SPIRV-Tools accepts. `docs/50-verification.md` §7.1 calls the
//! two separate implementations of one specification, and the port checks the
//! shape, the id space and the closed enumerations, not the type system: a
//! module that type-checks wrongly can still pass here.

const error_mod = @import("error.zig");
const grammar = @import("grammar.zig");
const header = @import("header.zig");
const instruction = @import("instruction.zig");
const word = @import("word.zig");

const Error = error_mod.Error;
const Word = word.Word;

/// Whether a module is fit to hand to Vulkan.
///
/// A pass that returns has found nothing to report, and that is the port's
/// "zero diagnostics". Dawn installs a SPIRV-Tools message consumer and
/// forwards every message to a log emitter
/// (`src/dawn/native/SpirvValidation.cpp:39-63`); the port has no channel to
/// forward to, so the first rule that fails is the error and the rest are not
/// searched for.
pub fn validate(words: []const Word) Error!void {
    const module_header = try header.parse(words);

    var cursor: instruction.Cursor = instruction.Cursor.init(words);
    var entry_point_count: u32 = 0;
    while (try cursor.next()) |inst| {
        // An opcode the reader does not model is an instruction this pass has
        // no use for, not a malformed module: a module may legally carry
        // hundreds of them, and each declares its own word count, so skipping
        // one leaves the walk exact. `Decoration` is the opposite case — that
        // enumeration is whole, so a word outside it is malformed.
        const opcode = inst.knownOpcode() orelse continue;
        switch (opcode) {
            .entry_point => {
                entry_point_count += 1;
                try checkEntryPoint(inst, module_header.id_bound);
            },
            .decorate, .decorate_string => try checkDecorate(inst, module_header.id_bound),
            .member_decorate, .member_decorate_string => {
                try checkMemberDecorate(inst, module_header.id_bound);
            },
            else => {},
        }
    }

    if (entry_point_count == 0) return error.SpirvNoEntryPoint;
}

/// Every id in an `OpEntryPoint` must be one the module declared, and the name
/// must be a well-formed literal string.
fn checkEntryPoint(inst: instruction.Instruction, id_bound: u32) Error!void {
    const fields = try instruction.readEntryPoint(inst);
    try checkId(fields.id, id_bound);
    for (fields.interface) |interface_id| try checkId(interface_id, id_bound);
}

/// `OpDecorate <target> <decoration> [literal...]`.
///
/// `Decoration` is a closed enumeration, so a word outside it is not a
/// decoration a later specification added but a malformed module. That is the
/// rule a fixture corrupted by writing `OpNop` over a decoration trips.
fn checkDecorate(inst: instruction.Instruction, id_bound: u32) Error!void {
    const operands = inst.operands();
    if (operands.len < 2) return error.SpirvMalformed;

    try checkId(operands[0], id_bound);
    if (grammar.Decoration.fromRaw(operands[1]) == null) return error.SpirvMalformed;
}

/// `OpMemberDecorate <structure type> <member> <decoration> [literal...]`. The
/// member is a literal index rather than an id, which is why the decoration
/// sits one word further along than in `OpDecorate`.
fn checkMemberDecorate(inst: instruction.Instruction, id_bound: u32) Error!void {
    const operands = inst.operands();
    if (operands.len < 3) return error.SpirvMalformed;

    try checkId(operands[0], id_bound);
    if (grammar.Decoration.fromRaw(operands[2]) == null) return error.SpirvMalformed;
}

/// An id is below the bound the header declares, and zero is never an id.
fn checkId(id: u32, id_bound: u32) Error!void {
    if (id == 0) return error.SpirvMalformed;
    if (id >= id_bound) return error.SpirvMalformed;
}
