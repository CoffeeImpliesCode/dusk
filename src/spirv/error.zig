//! The failures the SPIR-V reader reports.
//!
//! `docs/30-port-design.md` §2.1 fixes the shape: a rejection is a member of a
//! declared set, not a formatted message. Dawn reaches for SPIRV-Tools and
//! forwards its text to a log emitter
//! (`src/dawn/native/SpirvValidation.cpp:39-63`); the port links no validator
//! and owns no log emitter, so a rule fires as an error.
//!
//! **What this file does not claim.** It does not claim the port rejects every
//! module SPIRV-Tools rejects; the two are separate implementations.
//! Every member below is raised by a rule in
//! `validate.zig` and is named by a test in `test/spirv.zig`.

const std = @import("std");

/// What is wrong with a module. `validate` returns the first rule that failed.
pub const Error = error{
    /// The word slice is shorter than the five-word module header.
    SpirvEmpty,
    /// Word zero is not the SPIR-V magic number.
    SpirvMagicWrong,
    /// The version word does not encode `major << 16 | minor << 8`.
    SpirvVersionMalformed,
    /// The version is outside the range the port reads.
    SpirvVersionUnsupported,
    /// The reserved schema word is not zero.
    SpirvSchemaNotZero,
    /// A structural rule failed: a word count, an id, an id bound, a
    /// decoration, a specialization declaration, or a literal string.
    SpirvMalformed,
    /// The module declares no entry point, so it has nothing to run.
    SpirvNoEntryPoint,
};

/// `Error` plus the one allocation failure, for the functions that take an
/// allocator. A caller that only reads a module gets `Error` alone.
pub const ErrorOrOutOfMemory = Error || std.mem.Allocator.Error;
