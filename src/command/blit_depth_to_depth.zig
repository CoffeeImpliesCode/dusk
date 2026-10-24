//! `src/dawn/native/BlitDepthToDepth.cpp`: the depth-to-depth texture copy.
//!
//! **What this file is.** The render-pass emulation of a depth texture copy
//! into a non-zero destination subresource. It holds the fragment body at
//! `BlitDepthToDepth.cpp:61`-`:62` (`textureLoad` returned straight back as
//! `frag_depth`), the preconditions at `:115`-`:119`, the per-layer pass at
//! `:195`-`:239`, and the caller's gate at
//! `src/dawn/native/CommandEncoder.cpp:2157-2183`.
//!
//! **What this file does not claim.** It does not claim a render pipeline:
//! `GetOrCreateDepthBlitPipeline` (`BlitDepthToDepth.cpp:66`) compiles the WGSL
//! at `:47`-`:64`; the library has no WGSL front end.
//! It does not claim the single-layer intermediate texture each layer
//! above zero is copied into first (`:135`-`:192`); that is a
//! `CopyTextureToTexture` and belongs to the command stream.
//!
//! It does not claim a copy rectangle inside a subresource either. The shader
//! uses the raw framebuffer coordinate as the texture coordinate (`:62`) and
//! the blit sets no viewport and no scissor, so a sub-rectangle copy would read
//! the wrong texel rather than fail. That is why Dawn copies depth
//! subresources whole (`BlitDepthToDepth.cpp:121-122`) and why `gate` below is
//! the contract this file exports.

const std = @import("std");
const enums = @import("../api/enums.zig");
const descriptors = @import("../api/descriptors.zig");

const TextureFormat = enums.TextureFormat;
const Extent3D = descriptors.Extent3D;
const Origin3D = descriptors.Origin3D;

/// What the depth-to-depth blit can refuse. Every member is named by a case in
/// `test/blit.zig`.
pub const Error = error{
    /// The source format has no depth aspect, `BlitDepthToDepth.cpp:115`.
    SourceFormatHasNoDepth,
    /// The destination format has no depth aspect, `:116`.
    DestinationFormatHasNoDepth,
    /// A sample count other than one on either side, `:117`-`:118`.
    MultisampledDepth,
    /// The copy extent is empty, `:119`.
    EmptyExtent,
    /// `width * height * depthOrArrayLayers` leaves the 64-bit range.
    CopySizeOverflow,
    /// The source holds fewer values than the extent asks for.
    SourceTooSmall,
    /// The destination holds fewer values than the extent asks for.
    DestinationTooSmall,
};

/// Whether `format` carries a depth aspect, the two `HasDepth()` checks at
/// `BlitDepthToDepth.cpp:115-116`.
pub fn hasDepth(format: TextureFormat) bool {
    return switch (format) {
        .depth16_unorm,
        .depth24_plus,
        .depth24_plus_stencil8,
        .depth32_float,
        .depth32_float_stencil8,
        => true,
        else => false,
    };
}

/// What `BlitDepthToDepth()` needs to decide whether it can run.
pub const GateRequest = struct {
    /// `(aspect & Aspect::Depth) && toggle && depthOrArrayLayers > 0`,
    /// `CommandEncoder.cpp:2157-2161` minus the toggle, which is a device
    /// setting and not a property of the copy.
    aspect_has_depth: bool,
    /// `UseBlitForDepthTextureToTextureCopyToNonzeroSubresource` is on.
    toggle_enabled: bool,
    destination_mip_level: u32,
    destination_origin: Origin3D,
    copy_extent: Extent3D,
};

/// Whether a texture-to-texture copy takes this path,
/// `CommandEncoder.cpp:2157-2163`.
///
/// The path exists for a destination subresource the driver will not copy
/// directly, so a full subresource at mip zero and layer zero never reaches it.
/// When the aspect carries stencil as well the caller still emits a plain copy
/// command for the stencil half (`:2166-2172`), which is why the aspect is a
/// predicate here and not a rejection.
pub fn gate(request: GateRequest) bool {
    if (!request.aspect_has_depth) return false;
    if (!request.toggle_enabled) return false;
    if (request.copy_extent.depth_or_array_layers == 0) return false;
    return request.destination_mip_level > 0 or
        request.destination_origin.z > 0 or
        request.copy_extent.depth_or_array_layers > 1;
}

/// What `blitDepthToDepth` copies.
///
/// The depth values are the normalised `f32` the shader carries, which is what
/// `texture_2d<f32>` sampling yields and what `frag_depth` stores
/// (`BlitDepthToDepth.cpp:61-62`). Dawn says nothing about `depth24plus`
/// precision in its low bits; it says the format is not copyable in WebGPU
/// directly and copies it as `f32` (`BlitTextureToBuffer.cpp:1353-1354`), so a
/// value compared against this domain is compared as a real number.
pub const Request = struct {
    source_depths: []const f32,
    destination_depths: []f32,
    source_format: TextureFormat,
    destination_format: TextureFormat,
    source_sample_count: u32 = 1,
    destination_sample_count: u32 = 1,
    /// The copy rectangle in texels. Dawn only reaches this path for a whole
    /// subresource, so this is the source subresource's extent.
    copy_extent: Extent3D,
};

/// The number of depth values the extent covers.
///
/// The multiply is checked rather than wrapping, because a wrapped count is
/// smaller than the copy and the loop would stop early having reported nothing.
pub fn texelCount(copy_extent: Extent3D) Error!u64 {
    const layer = std.math.mul(
        u64,
        copy_extent.width,
        copy_extent.height,
    ) catch return error.CopySizeOverflow;
    return std.math.mul(
        u64,
        layer,
        copy_extent.depth_or_array_layers,
    ) catch return error.CopySizeOverflow;
}

/// Copy every depth value from the source to the destination, the way
/// Dawn's fullscreen draw does.
///
/// The fragment body is a load and a store with nothing in between
/// (`BlitDepthToDepth.cpp:61-62`), so every destination value is bit-identical to
/// the source value it was read from. Dawn's `ExpectEq` takes a tolerance that
/// defaults to zero, and a copy is the case where zero is right.
///
/// Dawn runs one render pass per layer (`:195-239`), each drawing three
/// vertices, so this walks the same layers in the same order.
pub fn blitDepthToDepth(request: Request) Error!void {
    if (!hasDepth(request.source_format)) return error.SourceFormatHasNoDepth;
    if (!hasDepth(request.destination_format)) return error.DestinationFormatHasNoDepth;
    if (request.source_sample_count != 1 or request.destination_sample_count != 1) {
        return error.MultisampledDepth;
    }
    if (request.copy_extent.width == 0 or request.copy_extent.height == 0 or
        request.copy_extent.depth_or_array_layers == 0)
    {
        return error.EmptyExtent;
    }

    const texel_count = try texelCount(request.copy_extent);
    if (texel_count > request.source_depths.len) return error.SourceTooSmall;
    if (texel_count > request.destination_depths.len) return error.DestinationTooSmall;

    const index_count: usize = @intCast(texel_count);
    var index: usize = 0;
    while (index < index_count) : (index += 1) {
        request.destination_depths[index] = request.source_depths[index];
    }
}
