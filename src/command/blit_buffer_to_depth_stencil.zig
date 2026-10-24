//! `src/dawn/native/BlitBufferToDepthStencil.cpp`: the buffer-to-depth and
//! buffer-to-stencil blits.
//!
//! **What this file is.** The two depth and stencil stages upstream emulates
//! with a draw. It holds the RG8-to-depth16unorm decode at `:79-85`, the
//! uniform at `:52-54`, and the per-layer pass at `:294-368`.
//!
//! **What this file does not claim.** It does not claim
//! `BlitR8ToStencil` (`:374`). Its content is a scissor rect and nine draws per
//! layer (`:499-518`), which are `command` and `engine` work and need the nine
//! pipelines `GetOrCreateR8ToStencilPipelines` (`:197`) builds.
//!
//! It does not claim a shader. `kBlitRG8ToDepthShaders` (`:56`),
//! `kBlitStencilShaderCommon` (`:111`) and both pipeline factories (`:161`,
//! `:197`) emit and compile WGSL, which this library does not accept.
//! Neither `BlitBufferToDepth` (`:563`) nor
//! `BlitBufferToStencil` (`:627`) lands with it either: each creates an
//! intermediate `RG8Uint` or `R8Uint` texture, and a texture is an `engine`
//! object. `BlitStagingBufferToDepth` (`:525`) and
//! `BlitStagingBufferToStencil` (`:593`) finish a command encoder and submit,
//! which is the queue's work.

const std = @import("std");
const enums = @import("../api/enums.zig");
const descriptors = @import("../api/descriptors.zig");

const TextureFormat = enums.TextureFormat;
const Extent3D = descriptors.Extent3D;
const Origin2D = descriptors.Origin2D;

/// What the buffer-to-depth blit can refuse. Every member is named by a case in
/// `test/blit.zig`.
pub const Error = error{
    /// The destination is not `depth16unorm`, `:281`.
    DestinationFormatUnsupported,
    /// The source is not the `RG8Uint` intermediate this decode reads, `:282`.
    SourceFormatUnsupported,
    /// The copy extent is empty.
    EmptyExtent,
    /// The source holds fewer texels than the extent asks for.
    SourceTooSmall,
    /// The destination holds fewer values than the extent asks for.
    DestinationTooSmall,
};

/// `BlitRG8ToDepthParams`, `:52-54`, byte for byte the two `u32` the WGSL
/// struct at `:68-70` declares. Upstream asserts nothing about it.
pub const Params = extern struct {
    origin: [2]u32,
};

comptime {
    std.debug.assert(@offsetOf(Params, "origin") == 0);
    std.debug.assert(@sizeOf(Params) == 8);
}

/// `BlitStencilParams`, `:106-109`, byte for byte the three `u32` the WGSL
/// struct at `:113-116` declares. The port keeps the layout assertion because
/// the bind group layout's `min_binding_size` at `:408` is four `u32`, which is
/// larger than the struct, and a reader needs to see which of the two it is.
pub const StencilParams = extern struct {
    origin: [2]u32,
    layer: u32,
};

comptime {
    std.debug.assert(@offsetOf(StencilParams, "origin") == 0);
    std.debug.assert(@offsetOf(StencilParams, "layer") == 8);
    std.debug.assert(@sizeOf(StencilParams) == 12);
    // `min_binding_size = 4 * sizeof(uint32_t)`, `:408`.
    std.debug.assert(4 * @sizeOf(u32) == 16);
}

/// The uniform for one pass, `:316-330`.
///
/// The scissor starts at the copy origin (`:359-361`) and the fragment
/// subtracts that same origin from its framebuffer position (`:79-80`), so the
/// first fragment reads texel zero. The uniform is what carries the origin
/// between the two.
pub fn writeParams(params: *Params, origin: Origin2D) void {
    params.origin = .{ origin.x, origin.y };
}

/// `f32(depth_u16_val) * (1.0 / 0xFFFFu)`, `:84-85`.
///
/// The two source bytes are an unsigned sixteen-bit value in little-endian
/// order, red in the low byte and green in the high one, and the decode is a
/// multiply by the reciprocal rather than a divide. It is the only arithmetic
/// between the load and the store, which is why the result is a normalised real
/// number and not a word.
pub fn decodeRg8ToDepth16Unorm(texel: [2]u8) f32 {
    const depth_u16: u16 = @as(u16, texel[1]) << 8 | @as(u16, texel[0]);
    const one_over_max: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 0xffff)));
    return @as(f32, @floatFromInt(depth_u16)) * one_over_max;
}

/// What `blitRg8ToDepth16Unorm` converts.
pub const Request = struct {
    /// The `RG8Uint` intermediate's texels, in row-major order with no row
    /// padding, two bytes per texel.
    source_bytes: []const u8,
    /// The destination's depth values, which the blit writes in place.
    destination_depths: []f32,
    source_format: TextureFormat,
    destination_format: TextureFormat,
    /// The copy rectangle in texels.
    copy_extent: Extent3D,
    /// The copy origin, which the scissor and the uniform both carry, `:359-361`
    /// and `:316-330`.
    destination_origin: Origin2D = .{},
};

/// Convert the `RG8Uint` intermediate into `depth16unorm` values, the way
/// Dawn's fullscreen draw does.
///
/// The fragment loads at `vec2u(position.xy) - params.origin` (`:79-80`), so the
/// coordinate the shader uses is the framebuffer position minus the copy
/// origin, and the port reads the same texel.
pub fn blitRg8ToDepth16Unorm(request: Request) Error!void {
    if (request.destination_format != .depth16_unorm) {
        return error.DestinationFormatUnsupported;
    }
    if (request.source_format != .rg8_uint) return error.SourceFormatUnsupported;
    if (request.copy_extent.width == 0 or request.copy_extent.height == 0 or
        request.copy_extent.depth_or_array_layers == 0)
    {
        return error.EmptyExtent;
    }

    const layer_count = std.math.mul(
        u64,
        request.copy_extent.width,
        request.copy_extent.height,
    ) catch return error.SourceTooSmall;
    const texel_count = std.math.mul(
        u64,
        layer_count,
        request.copy_extent.depth_or_array_layers,
    ) catch return error.SourceTooSmall;
    const wanted_byte_count = std.math.mul(u64, texel_count, 2) catch
        return error.SourceTooSmall;
    if (wanted_byte_count > request.source_bytes.len) return error.SourceTooSmall;
    if (texel_count > request.destination_depths.len) return error.DestinationTooSmall;

    const index_count: usize = @intCast(texel_count);
    var index: usize = 0;
    while (index < index_count) : (index += 1) {
        const start = index * 2;
        request.destination_depths[index] = decodeRg8ToDepth16Unorm(.{
            request.source_bytes[start],
            request.source_bytes[start + 1],
        });
    }
}
