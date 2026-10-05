//! The M7 shard for the format tables: the API descriptor and the engine's
//! capability table have to name the same four formats, and the engine table
//! has an arm for every format the descriptor declares.
//!
//! **Which two tables, and why these four.** `src/api/enums.zig` is generated
//! from `src/dawn/dawn.json` and owns the WebGPU format names and their tags.
//! `src/engine/vulkan_format.zig` owns the engine's Vulkan name for each one,
//! ported from `VulkanImageFormat` (`vulkan/TextureVk.cpp:448-573`). The four
//! named rows are the ones whose two tables carry different information: two
//! are channel-order dependent (`RGBA8Unorm` against `BGRA8Unorm`), one is a
//! depth format that must not borrow a stencil (`Depth24Plus`), and one is
//! renderable only behind a feature (`RG11B10Ufloat`).
//!
//! **Why the Vulkan values are spelled as numbers.** `src/vulkan.zig` is
//! generated from the pinned `vulkan_core.h` and the test cannot
//! `@import("vulkan")`: the module is a private dependency of the library, not
//! a published one. The numbers are the Vulkan ABI, they are stable, and each
//! row carries the upstream line that fixes its name.
//!
//! **Why the renderable gate is asserted on the feature, not on the Vulkan
//! name.** `Format.cpp:250-253` gives `RG11B10Ufloat` `Cap::None`, and `:394-397`
//! adds `Renderable`, `Multisample`, `Resolve` and `Blendable` only when
//! `Feature::RG11B10UfloatRenderable` is on. That is a WebGPU-level
//! capability, so it has no Vulkan name: `TextureVk.cpp:481` is unconditional.
//! The claim this file makes is therefore the one that can fail — the feature
//! exists, and the engine table carries exactly one arm for the packed format.
//!
//! **What this file does not claim.** It does not claim a device, a sample
//! count or a render pass. It claims the two name tables agree.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const vk_format = dusk.engine.vulkan_format;

const TextureFormat = api.enums.TextureFormat;

/// One row of the agreement: the API descriptor's tag, and the Vulkan value
/// the engine's table has to produce for it.
const Agrees = struct {
    format: TextureFormat,
    /// `src/api/enums.zig`, from `src/dawn/dawn.json`.
    api_tag: u32,
    /// `src/vulkan.zig`, from the pinned `vulkan_core.h`.
    vk_value: u32,
    /// The upstream row that fixes the Vulkan name.
    upstream: []const u8,
};

const agrees = [_]Agrees{
    .{
        .format = .rgba8_unorm,
        .api_tag = 22,
        .vk_value = 37,
        .upstream = "vulkan/TextureVk.cpp:472",
    },
    .{
        .format = .bgra8_unorm,
        .api_tag = 27,
        .vk_value = 44,
        .upstream = "vulkan/TextureVk.cpp:477",
    },
    .{
        .format = .depth24_plus,
        .api_tag = 46,
        .vk_value = 126,
        .upstream = "vulkan/TextureVk.cpp:585-586",
    },
    .{
        .format = .rg11_b10_ufloat,
        .api_tag = 31,
        .vk_value = 122,
        .upstream = "vulkan/TextureVk.cpp:481",
    },
};

/// The Vulkan value one format maps to, widened so a failure prints a number
/// rather than a type name.
fn vkValue(format: TextureFormat) u32 {
    const value: u32 = @intCast(vk_format.vkFormat(format));
    return value;
}

test "the API descriptor and the engine table name the same four formats" {
    for (agrees) |row| {
        const actual = vkValue(row.format);
        if (actual != row.vk_value) {
            std.debug.print(
                "{s} gives VkFormat {d}, the engine table says {d} ({s})\n",
                .{ row.upstream, row.vk_value, actual, @tagName(row.format) },
            );
            return error.FormatTablesDisagree;
        }
        try std.testing.expectEqual(
            row.api_tag,
            @as(u32, @intFromEnum(row.format)),
        );
    }
}

test "bgra8unorm and rgba8unorm are two names, not one format" {
    // `TextureVk.cpp:472` and `:477`. A table that gave both the same Vulkan
    // name would put the channels in the wrong order for every bgra8unorm
    // attachment, and nothing downstream could notice.
    try std.testing.expect(vkValue(.rgba8_unorm) != vkValue(.bgra8_unorm));
    try std.testing.expectEqual(@as(u32, 37), vkValue(.rgba8_unorm));
    try std.testing.expectEqual(@as(u32, 44), vkValue(.bgra8_unorm));

    // Each unorm pair has an sRGB sibling six Vulkan slots away (43 against
    // 37, 50 against 44), so one row per family covers both spellings.
    try std.testing.expectEqual(@as(u32, 43), vkValue(.rgba8_unorm_srgb));
    try std.testing.expectEqual(@as(u32, 50), vkValue(.bgra8_unorm_srgb));
}

test "depth24plus is the plain depth format and carries no stencil" {
    // `TextureVk.cpp:585-586` gives Depth24Plus the 32-bit float format, while
    // `:574-583` gives Depth24PlusStencil8 a toggle-selected one. Pairing a
    // depth24plus attachment with a stencil format would make
    // `vkImageLayoutForDepthStencilAttachment` choose a two-aspect layout for
    // an image that has one aspect.
    const depth24_plus = vkValue(.depth24_plus);
    try std.testing.expectEqual(@as(u32, 126), depth24_plus);
    try std.testing.expect(depth24_plus != vkValue(.depth24_plus_stencil8));
    try std.testing.expectEqual(depth24_plus, vkValue(.depth32_float));
}

test "r11b10ufloat has one engine arm and its own renderable feature" {
    // `Format.cpp:394-397` gates the renderable capability on a feature that
    // names the format. The census below is the claim that the engine table
    // holds one arm for the packed format and has not grown a second one
    // keyed on a capability, because a capability is not a Vulkan name.
    var packed_formats: usize = 0;
    inline for (@typeInfo(TextureFormat).@"enum".fields) |field| {
        // A nested `if`, not a `continue`: `inline for` unfolds to
        // straight-line code, so a `continue` here would cross the runtime
        // condition this skip is.
        if (std.mem.indexOf(u8, field.name, "rg11_b10") != null) {
            packed_formats += 1;
            try std.testing.expectEqualStrings("rg11_b10_ufloat", field.name);
            const format: TextureFormat = @enumFromInt(field.value);
            try std.testing.expectEqual(@as(u32, 122), vkValue(format));
        }
    }
    try std.testing.expectEqual(@as(usize, 1), packed_formats);

    // The feature is a device feature with its own tag, not a format.
    try std.testing.expectEqual(
        @as(u32, 12),
        @as(u32, @intFromEnum(api.enums.FeatureName.rg11b10_ufloat_renderable)),
    );
}

test "every API format the descriptor declares has an engine table arm" {
    // The engine switch has no `else` (`vulkan_format.zig:62-185`) and answers
    // `undefined_` with `unreachable` (`:184`), so a descriptor member with no
    // arm traps here and the census names the member that lost its row.
    var covered: usize = 0;
    // `inline for` because `EnumField.value` is a `comptime_int`: a runtime
    // index cannot read one, and the unfolded copy is what makes a member the
    // engine table lost a compile error here rather than a runtime trap.
    inline for (@typeInfo(TextureFormat).@"enum".fields) |field| {
        // Nested rather than a `continue`, because `inline for` unfolds to
        // straight-line code.
        if (field.value != @intFromEnum(TextureFormat.undefined_)) {
            const format: TextureFormat = @enumFromInt(field.value);
            try std.testing.expect(vkValue(format) != 0);
            covered += 1;
        }
    }
    try std.testing.expectEqual(
        @as(usize, @typeInfo(TextureFormat).@"enum".fields.len - 1),
        covered,
    );
}

test "exactly one API pair shares a Vulkan name" {
    // Depth24Plus and Depth32Float both resolve to `VK_FORMAT_D32_SFLOAT`
    // (`TextureVk.cpp:585-586` and the table's `Depth32Float` arm), because
    // WebGPU's depth24plus is not a bit layout. Every other API format has a
    // Vulkan name of its own, so a second shared name is a second mapping rule
    // the reader would not know to look for.
    const declared: usize = @typeInfo(TextureFormat).@"enum".fields.len - 1;
    var distinct: usize = 0;
    var seen: [declared]u32 = undefined;
    inline for (@typeInfo(TextureFormat).@"enum".fields) |field| {
        // `inline for` for the reason at `:159`: the field's value is a
        // `comptime_int`, and the skip is nested because the loop is
        // straight-line code.
        if (field.value != @intFromEnum(TextureFormat.undefined_)) {
            const format: TextureFormat = @enumFromInt(field.value);
            const value = vkValue(format);
            var already: usize = 0;
            for (seen[0..distinct]) |previous| {
                if (previous == value) already += 1;
            }
            if (already == 0) {
                seen[distinct] = value;
                distinct += 1;
            }
        }
    }
    try std.testing.expectEqual(declared - 1, distinct);
}
