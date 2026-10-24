//! The SPIR-V version carried in the second word of the module header.
//!
//! `src/dawn/native/SpirvValidation.cpp:38` picks the SPIRV-Tools environment
//! from a `bool`: `SPV_ENV_VULKAN_1_1_SPIRV_1_4` or `SPV_ENV_VULKAN_1_1`. The
//! port reads the version out of the module instead of taking a flag, because
//! the words it validates are the words the caller handed over and they say
//! which version they are.

const error_mod = @import("error.zig");
const word = @import("word.zig");

const Error = error_mod.Error;
const Word = word.Word;

pub const Version = struct {
    major: u8,
    minor: u8,

    /// SPIR-V 1.0, the first published version.
    pub const first: Version = .{ .major = 1, .minor = 0 };

    /// SPIR-V 1.6, the highest version supported here.
    pub const last: Version = .{ .major = 1, .minor = 6 };

    pub fn eql(left: Version, right: Version) bool {
        return left.major == right.major and left.minor == right.minor;
    }

    pub fn isAccepted(version: Version) bool {
        if (version.major != first.major) return false;
        return version.minor >= first.minor and version.minor <= last.minor;
    }
};

/// The version word is `0x00MMmm00`: two version bytes and two bytes the
/// specification reserves, which must therefore be zero.
pub fn decode(version_word: Word) Error!Version {
    if (version_word & 0xff00_00ff != 0) return error.SpirvVersionMalformed;

    const version: Version = .{
        .major = @truncate(version_word >> 16),
        .minor = @truncate(version_word >> 8),
    };
    if (version.major == 0) return error.SpirvVersionMalformed;
    // `isAccepted` takes the version as its only parameter and has no `self`,
    // so it is reached through the type. `version.isAccepted(version)` would
    // pass the version as a receiver and one argument too many.
    if (!Version.isAccepted(version)) return error.SpirvVersionUnsupported;
    return version;
}

/// The word this version encodes as.
pub fn encode(version: Version) Word {
    return (@as(Word, version.major) << 16) | (@as(Word, version.minor) << 8);
}
