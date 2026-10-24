//! `src/dawn/native/BlitColorToColorWithDraw.cpp`: the colour draw blits.
//!
//! **What this file is.** The two colour operations upstream emulates with a
//! draw. It holds the offset packing at `:309-317`, the unpacker at `:65-80`,
//! the multisample average at `:129-151`, and the scissor at `:487-488`.
//!
//! **What this file does not claim.** It does not claim
//! `ExpandResolveTextureWithDraw` (`:319`). Upstream reaches it only when
//! `DeviceBase::CanTextureLoadResolveTargetInTheSameRenderpass()` is true
//! (`src/dawn/native/Device.cpp:2593-2595`), which D3D11, D3D12, Metal and Null
//! override and Vulkan does not; Vulkan re-implements the same pass in
//! `src/dawn/native/vulkan/ResolveTextureLoadingUtilsVk.cpp:179`. A Vulkan-only
//! port would carry it as dead weight.
//!
//! It does not claim a shader. `GenerateBlitToColorVS` (`:62`),
//! `GenerateExpandFS` (`:99`) and `GenerateResolveFS` (`:131`) emit WGSL.
//! The library has no WGSL front end. The two pipeline
//! factories at `:153` and `:254` and the four hash and equality functors at
//! `:419`, `:436`, `:501` and `:511` go with them: a cache key whose cache is
//! not ported has no reader.

const std = @import("std");
const descriptors = @import("../api/descriptors.zig");

const Origin2D = descriptors.Origin2D;

/// What the colour draw blits can refuse. Every member is named by a case in
/// `test/blit.zig`.
pub const Error = error{
    /// A packed offset is not below `INT16_MAX`, so it does not fit the
    /// sign-extended half-word the packing gives it, `:314-315`.
    OffsetOutOfRange,
    /// The sample list is empty, so the average would divide by zero,
    /// `:142-144`.
    EmptySampleList,
    /// The sample list is longer than the bound the port accepts.
    TooManySamples,
};

/// The resolve rectangle Dawn carries in `RenderPassDescriptorResolveRect`.
/// The four offsets are what `PackOffsets` differences and what the shader's
/// `unpack_offsets` gives back.
pub const ResolveRect = struct {
    color_offset: Origin2D,
    resolve_offset: Origin2D,
    width: u32,
    height: u32,
};

/// The largest sample count the average below accepts.
///
/// Vulkan requires a queue family that supports two or four samples to support
/// eight, so eight is the largest count a resolve meets in practice on this
/// back end. A longer list is refused rather than averaged, so an out-of-range
/// count cannot pass silently.
pub const max_resolve_sample_count: usize = 8;

/// `PackOffsets`, `:309-317`.
///
/// The comment at `:306-308` gives the reason the packing exists: a texture
/// dimension never exceeds sixteen bits, so two signed sixteen-bit offsets fit
/// one `u32` and the blit needs no uniform buffer. The two halves are the low
/// word and the high word, and the shader sign-extends both
/// (`unpack_offsets`, `:65-80`).
pub fn packOffsets(rect: ResolveRect) Error!u32 {
    const offset_x = @as(i64, rect.resolve_offset.x) - @as(i64, rect.color_offset.x);
    const offset_y = @as(i64, rect.resolve_offset.y) - @as(i64, rect.color_offset.y);
    if (offset_x >= std.math.maxInt(i16) or offset_x <= std.math.minInt(i16)) {
        return error.OffsetOutOfRange;
    }
    if (offset_y >= std.math.maxInt(i16) or offset_y <= std.math.minInt(i16)) {
        return error.OffsetOutOfRange;
    }
    // Dawn's two casts (`BlitColorToColorWithDraw.cpp:316`): `offsetX & 0xffff`
    // is the low half-word and `offsetY << 16` the high one, so each signed
    // offset is cast to its own `u16` and placed in its own half of the `u32`.
    // One `@bitCast` cannot carry both halves: it needs the source and the
    // destination to be the same size, and a half-word is not a word.
    const low: u16 = @bitCast(@as(i16, @intCast(offset_x)));
    const high: u16 = @bitCast(@as(i16, @intCast(offset_y)));
    return @as(u32, low) | (@as(u32, high) << 16);
}

/// `unpack_offsets(packed).x`, `:65-80`. The sign bit of the low half-word
/// sets the upper sixteen bits, so the value is negative rather than a large
/// positive one.
pub fn unpackOffsetX(packed_offsets: u32) i32 {
    const low: u16 = @truncate(packed_offsets);
    return @as(i16, @bitCast(low));
}

/// `unpack_offsets(packed).y`, `:65-80`.
pub fn unpackOffsetY(packed_offsets: u32) i32 {
    const high: u16 = @truncate(packed_offsets >> 16);
    return @as(i16, @bitCast(high));
}

/// One colour texel, the `vec4f` the resolve fragment shader returns.
pub const Color = [4]f32;

/// The multisample average `GenerateResolveFS` computes, `:129-151`.
///
/// The fragment shader sums the samples at one texel and divides by the sample
/// count. It is a plain box average and not a weighted one, and the port keeps
/// that: `sum / f32(sampleCount)` with the count written into the shader text
/// at `:145`, so the count is the shader's and not a uniform.
pub fn resolveMultisampleColor(samples: []const Color) Error!Color {
    if (samples.len == 0) return error.EmptySampleList;
    if (samples.len > max_resolve_sample_count) return error.TooManySamples;

    var sum: Color = .{ 0.0, 0.0, 0.0, 0.0 };
    for (samples) |sample| {
        var channel: usize = 0;
        while (channel < sum.len) : (channel += 1) {
            sum[channel] += sample[channel];
        }
    }
    const divisor: f32 = @floatFromInt(samples.len);
    // Seeded rather than `undefined`: the loop below writes every channel, and a
    // seed costs four words and removes the read of uninitialised memory that
    // a shorter `Color` would otherwise leave behind.
    var resolved: Color = @splat(0.0);
    var channel: usize = 0;
    while (channel < resolved.len) : (channel += 1) {
        resolved[channel] = sum[channel] / divisor;
    }
    return resolved;
}

/// The texel `ResolveMultisampleWithDraw` samples, from the scissor and the
/// packed offsets, at `:487-495` and the shader's `offsetPos` at `:140`.
///
/// The resolve rectangle sits at `resolve_offset` in the colour texture and the
/// samples sit at the same position, so the position the fragment arrives at is
/// the resolve rectangle's origin and the packed offsets are what carry the
/// difference between it and the colour attachment's origin.
pub fn samplePosition(resolve_offset: Origin2D, packed_offsets: u32) [2]i32 {
    const offset_x = unpackOffsetX(packed_offsets);
    const offset_y = unpackOffsetY(packed_offsets);
    return .{
        @as(i32, @intCast(resolve_offset.x)) - offset_x,
        @as(i32, @intCast(resolve_offset.y)) - offset_y,
    };
}
