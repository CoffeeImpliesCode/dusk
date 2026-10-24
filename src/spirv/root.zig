//! dusk's SPIR-V reader: a parser, a validator and a reflection pass.
//!
//! **What this module is.** `docs/10-architecture.md` "Shaders" names the flow
//! it implements: SPIR-V bytes go in, `validate` decides whether the module may
//! be used, `reflect` says what it declares, and the caller's own words reach
//! `vkCreateShaderModule`. Nothing here writes to a caller's words.
//! `wordsFromBytes` makes a copy to read, and the copy is what leaves the
//! module.
//!
//! **What this module is not.** It holds no Vulkan type.
//! `docs/10-architecture.md` "Module boundaries" gives that to `vk`, and a
//! reflection result has to be readable without a device. It also parses no
//! WGSL: the input is a SPIR-V binary.
//!
//! **What it does not claim.** It does not claim to accept exactly what
//! SPIRV-Tools accepts; these are separate implementations.
//! It does not claim a type checker: `validate` reads the shape, the id space
//! and the closed enumerations, and stops there.

const error_mod = @import("error.zig");
const grammar = @import("grammar.zig");
const header = @import("header.zig");
const reflect_mod = @import("reflect.zig");
const validate_mod = @import("validate.zig");
const version_mod = @import("version.zig");
const word = @import("word.zig");

pub const Decoration = grammar.Decoration;
pub const Dim = grammar.Dim;
pub const EntryPoint = reflect_mod.EntryPoint;
pub const Error = error_mod.Error;
pub const ErrorOrOutOfMemory = error_mod.ErrorOrOutOfMemory;
pub const ExecutionModel = grammar.ExecutionModel;
pub const Header = header.Header;
pub const Module = reflect_mod.Module;
pub const Opcode = grammar.Opcode;
pub const Resource = reflect_mod.Resource;
pub const ResourceKind = reflect_mod.ResourceKind;
pub const ScalarType = reflect_mod.ScalarType;
pub const SpecializationConstant = reflect_mod.SpecializationConstant;
pub const StorageClass = grammar.StorageClass;
pub const Version = version_mod.Version;
pub const Word = word.Word;

/// The words that open a module: magic, version, generator, id bound, schema.
pub const header_word_count = header.word_count;

pub const magic_number = word.magic_number;
pub const swapped_magic_number = word.swapped_magic_number;
pub const makeInstructionWord = word.makeInstructionWord;
pub const opcodeOf = word.opcodeOf;
pub const wordCountOf = word.wordCountOf;
pub const reflect = reflect_mod.reflect;
pub const validate = validate_mod.validate;
pub const wordsFromBytes = word.wordsFromBytes;
