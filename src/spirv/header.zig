//! The five words that open every module.
//!
//! The header is where a module states what it is: the magic number that says
//! the bytes are SPIR-V at all, the version, the tool that wrote it, the id
//! space it uses, and a reserved word that is zero in every version published
//! so far.

const error_mod = @import("error.zig");
const version_mod = @import("version.zig");
const word = @import("word.zig");

const Error = error_mod.Error;
const Version = version_mod.Version;
const Word = word.Word;

/// The header is five words: magic, version, generator, id bound, schema.
pub const word_count: usize = 5;

pub const Header = struct {
    version: Version,

    /// The vendor tool that wrote the module. The port records it and never
    /// tests it: which tool wrote a module does not change what it declares.
    generator_magic: u32,

    /// One past the largest id the module uses. Every id in a well-formed
    /// module is below it.
    id_bound: u32,
};

/// The header of a module, after every header rule has passed.
pub fn parse(words: []const Word) Error!Header {
    if (words.len < word_count) return error.SpirvEmpty;
    if (words[0] != word.magic_number) return error.SpirvMagicWrong;

    const module_version = try version_mod.decode(words[1]);
    if (words[4] != 0) return error.SpirvSchemaNotZero;
    if (words[3] == 0) return error.SpirvMalformed;

    return .{
        .version = module_version,
        .generator_magic = words[2],
        .id_bound = words[3],
    };
}
