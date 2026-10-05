//! `src/dawn/native/BlitBufferToTexture.cpp`: the buffer-to-texture copy.
//!
//! **What this file is.** The render-pass emulation of
//! `vkCmdCopyBufferToImage`. It holds the format allowlist at `:346-368`, the
//! support predicate at `:370-393`, the per-layer source offset ladder at
//! `:461-464`, the sixteen-byte uniform at `:470-476`, the load helpers at
//! `:71-93`, and the unpackers at `:106-212`.
//!
//! **What this file does not claim.** It does not claim a render pipeline:
//! `GenerateShaderSource` (`:214`) emits WGSL and `GetOrCreatePipeline` (`:284`)
//! compiles it, and `AGENTS.md` §3.2 forbids a WGSL front end in the library. It
//! does not claim the viewport and the draw upstream sets at `:501-505` and
//! `:509`; `AGENTS.md` §3 keeps Vulkan out of `command`, so the pass belongs to
//! `engine`.

const std = @import("std");
const enums = @import("../api/enums.zig");
const descriptors = @import("../api/descriptors.zig");

const TextureFormat = enums.TextureFormat;
const TextureDimension = enums.TextureDimension;
const TextureAspect = enums.TextureAspect;
const Extent3D = descriptors.Extent3D;
const Origin3D = descriptors.Origin3D;
const TexelCopyBufferLayout = descriptors.TexelCopyBufferLayout;

/// What the buffer-to-texture blit can refuse. Every member is named by a case
/// in `test/blit.zig`.
pub const Error = error{
    /// The source buffer cannot be bound as read-only storage, `:373-376`.
    StorageRequired,
    /// The format is not in the allowlist at `:349-367`, or it is in the list
    /// and this port does not unpack it.
    UnsupportedFormat,
    /// The destination is a 1D texture, which cannot be rendered to, `:382-385`.
    OneDimensionalTexture,
    /// The aspect is not `all`, so the copy is multiplanar, `:387-390`.
    NonColorAspect,
    /// The copy extent is empty, `:392-393`.
    EmptyExtent,
    /// `bytesPerRow % 4 != 0`, the one hard pitch rule in the family, `:408`.
    PitchNotWordAligned,
    /// The source slice is shorter than the copy needs.
    SourceTooSmall,
    /// The destination slice is shorter than the copy needs.
    DestinationTooSmall,
    /// The storage-buffer offset alignment is zero or not a power of two,
    /// `:425-426`.
    SsboAlignmentInvalid,
};

/// The uniform the fragment shader reads, byte for byte the four `u32` Dawn
/// writes at `:470-476`.
pub const Params = extern struct {
    shader_read_offset: u32,
    bytes_per_row: u32,
    dst_origin_x: u32,
    dst_origin_y: u32,
};

comptime {
    std.debug.assert(@offsetOf(Params, "shader_read_offset") == 0);
    std.debug.assert(@offsetOf(Params, "bytes_per_row") == 4);
    std.debug.assert(@offsetOf(Params, "dst_origin_x") == 8);
    std.debug.assert(@offsetOf(Params, "dst_origin_y") == 12);
    std.debug.assert(@sizeOf(Params) == 16);
}

/// The four channels one texel carries, in `[0, 1]`, the domain every unpacker
/// below returns.
pub const Texel = [4]f32;

/// Whether the buffer-to-texture family has a shader for this format.
///
/// The list is hand-maintained upstream under `TODO(348653642)` at `:347`, and
/// unlike the texture-to-buffer list it holds no depth format and no integer
/// format. `test/blit.zig` sweeps it against the whole `TextureFormat` domain,
/// because a dropped entry loses a format silently.
pub fn isFormatSupportedByBufferToTextureBlit(format: TextureFormat) bool {
    return switch (format) {
        .r8_unorm,
        .rg8_unorm,
        .rgba8_unorm,
        .bgra8_unorm,
        .rgb10_a2_unorm,
        .r16_float,
        .r16_unorm,
        .rg16_float,
        .rg16_unorm,
        .rgba16_float,
        .rgba16_unorm,
        .r32_float,
        .rg32_float,
        .rgba32_float,
        => true,
        else => false,
    };
}

/// The bytes one texel of `format` occupies, or null when the port does not
/// unpack it.
///
/// Upstream appends the value as a WGSL `const` from a switch over the same
/// fourteen formats at `:217-282`. The two four-byte unorm colour formats are
/// the ones this port unpacks: the rest either quantise through `f32` or span a
/// different number of bytes, and a host pack would have to reproduce that
/// rounding to claim them.
pub fn pixelSize(format: TextureFormat) ?u32 {
    return switch (format) {
        .r8_unorm => 1,
        .rg8_unorm, .r16_float, .r16_unorm => 2,
        .rgba8_unorm,
        .bgra8_unorm,
        .rgb10_a2_unorm,
        .rg16_float,
        .rg16_unorm,
        .r32_float,
        => 4,
        .rgba16_float, .rgba16_unorm, .rg32_float => 8,
        .rgba32_float => 16,
        else => null,
    };
}

/// What `isBufferToTextureBlitSupported` decides, as the five values it reads.
/// Upstream reads five values off three objects (`:370-393`); a predicate with
/// five object arguments is a predicate no test can call.
pub const SupportRequest = struct {
    /// `buffer->GetInternalUsage() & (kReadOnlyStorageBuffer |
    /// kInternalStorageBuffer | wgpu::BufferUsage::Storage)`, `:373-376`.
    source_has_storage_usage: bool,
    format: TextureFormat,
    dimension: TextureDimension,
    aspect: TextureAspect,
    copy_extent: Extent3D,
};

/// `IsBufferToTextureBlitSupported`, `:370-393`. The five rejections run in
/// upstream's order, so a request failing two of them fails the first.
pub fn isBufferToTextureBlitSupported(request: SupportRequest) bool {
    if (!request.source_has_storage_usage) return false;
    if (!isFormatSupportedByBufferToTextureBlit(request.format)) return false;
    if (request.dimension == ._1d) return false;
    if (request.aspect != .all) return false;
    const texel_count = @as(u64, request.copy_extent.width) *
        @as(u64, request.copy_extent.height) *
        @as(u64, request.copy_extent.depth_or_array_layers);
    return texel_count > 0;
}

/// The two bytes of a source offset the shader and the binding disagree about,
/// at `:463-464`.
///
/// `srcOffset` walks the public layout's ladder. The binding offset aligns it
/// down, because a storage buffer binding must be aligned, and the shader adds
/// the remainder back. The split is the same idea the texture-to-buffer blit has
/// at `BlitTextureToBuffer.cpp:1600-1603`, and the two ladders differ: this one
/// steps by `rowsPerImage * bytesPerRow` per layer.
pub const LayerOffsets = struct {
    /// `align_down(srcOffset, ssboAlignment)`, `:463`. The byte the buffer is
    /// bound at.
    binding_offset: u64,
    /// `srcOffset - bindingOffset`, `:464`. The byte the shader starts at
    /// inside the binding.
    read_offset: u32,
};

pub fn layerOffsets(
    source: TexelCopyBufferLayout,
    storage_buffer_offset_alignment: u32,
    layer_index: u32,
) Error!LayerOffsets {
    if (storage_buffer_offset_alignment == 0) return error.SsboAlignmentInvalid;
    if (!std.math.isPowerOfTwo(storage_buffer_offset_alignment)) {
        return error.SsboAlignmentInvalid;
    }
    const layer_stride = std.math.mul(
        u64,
        source.rows_per_image,
        source.bytes_per_row,
    ) catch return error.SourceTooSmall;
    const src_offset = std.math.add(
        u64,
        source.offset,
        std.math.mul(u64, layer_stride, layer_index) catch return error.SourceTooSmall,
    ) catch return error.SourceTooSmall;
    const binding_offset = src_offset - src_offset % storage_buffer_offset_alignment;
    const read_offset = src_offset - binding_offset;
    if (read_offset > std.math.maxInt(u32)) return error.SourceTooSmall;
    return .{
        .binding_offset = binding_offset,
        .read_offset = @intCast(read_offset),
    };
}

/// The uniform for one layer, `:470-476`.
pub fn writeParams(
    params: *Params,
    source: TexelCopyBufferLayout,
    read_offset: u32,
    destination_origin: Origin3D,
) void {
    params.* = .{
        .shader_read_offset = read_offset,
        .bytes_per_row = source.bytes_per_row,
        .dst_origin_x = destination_origin.x,
        .dst_origin_y = destination_origin.y,
    };
}

/// The byte, measured from the binding, that the shader reads a texel from,
/// at `:100`.
///
/// `i_position` is the framebuffer coordinate minus the destination origin, and
/// `src_offset` is the layer's read offset plus `x * kPixelSize` plus
/// `y * bytesPerRow`. `kPixelSize` is the format's texel size, which
/// `GenerateShaderSource` appends as a WGSL constant at `:217-282`.
pub fn shaderReadByteOffset(params: Params, pixel_size: u32, position: [2]i64) u64 {
    const x = position[0] - @as(i64, params.dst_origin_x);
    const y = position[1] - @as(i64, params.dst_origin_y);
    std.debug.assert(x >= 0);
    std.debug.assert(y >= 0);
    return @as(u64, params.shader_read_offset) +
        @as(u64, @intCast(x)) * @as(u64, pixel_size) +
        @as(u64, @intCast(y)) * @as(u64, params.bytes_per_row);
}

/// `loadU32(byteOffset)`, `:85-88`, inside the load helpers at `:71-93`: a
/// little-endian word at a four-byte-aligned offset.
pub fn loadU32(source_bytes: []const u8, byte_offset: u64) Error!u32 {
    const start: usize = @intCast(byte_offset);
    const end = std.math.add(usize, start, @sizeOf(u32)) catch return error.SourceTooSmall;
    if (end > source_bytes.len) return error.SourceTooSmall;
    return std.mem.readInt(u32, source_bytes[start..][0..@sizeOf(u32)], .little);
}

/// `unpack4x8unorm(word)`, the `rgba8unorm` unpacker at `:120-125`. Byte zero
/// becomes the red channel.
pub fn unpack4x8Unorm(word: u32) Texel {
    const inverse: f32 = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(word & 0xff)) * inverse,
        @as(f32, @floatFromInt((word >> 8) & 0xff)) * inverse,
        @as(f32, @floatFromInt((word >> 16) & 0xff)) * inverse,
        @as(f32, @floatFromInt((word >> 24) & 0xff)) * inverse,
    };
}

/// `unpack4x8unorm(loadU32(byteOffset))`, the `rgba8unorm` unpacker, read from
/// memory.
pub fn unpackRgba8Unorm(source_bytes: []const u8, byte_offset: u64) Error!Texel {
    return unpack4x8Unorm(try loadU32(source_bytes, byte_offset));
}

/// `unpack4x8unorm(loadU32(byteOffset)).bgra`, the `bgra8unorm` unpacker at
/// `:127-132`.
///
/// It inverts the `pack4x8unorm(v.bgra)` the texture-to-buffer blit encodes at
/// `BlitTextureToBuffer.cpp:257-263`, and nothing else: red and blue are
/// exchanged, green and alpha are not.
pub fn unpack4x8UnormBgra(source_bytes: []const u8, byte_offset: u64) Error!Texel {
    const byte_order = try unpackRgba8Unorm(source_bytes, byte_offset);
    return .{ byte_order[2], byte_order[1], byte_order[0], byte_order[3] };
}

/// What `blitBufferToTexture` copies.
pub const Request = struct {
    /// The source buffer's bytes from byte zero. The binding offset the shader
    /// aligns down to is computed rather than given, so the slice starts at the
    /// buffer's own byte zero and the alignment split stays observable.
    source_bytes: []const u8,
    /// The source layout. `bytes_per_row` must be a multiple of four, `:404-408`.
    source: TexelCopyBufferLayout,
    source_has_storage_usage: bool,
    destination_format: TextureFormat,
    destination_dimension: TextureDimension,
    destination_aspect: TextureAspect,
    /// The copy rectangle in texels.
    copy_extent: Extent3D,
    /// The copy origin in the destination texture, `:473-474`.
    destination_origin: Origin3D = .{},
    /// `minStorageBufferOffsetAlignment`, `:425`.
    storage_buffer_offset_alignment: u32,
};

/// Copy `request.source_bytes` into `destination_bytes`, the way Dawn's
/// fullscreen draw does.
///
/// `destination_bytes` holds the destination subresource's texels in row-major
/// order with no row padding, which is what a texture subresource is. The
/// source is pitched, so this is the inverse of `blitTextureToBuffer` at a
/// 256-byte pitch and not a byte-for-byte transpose.
pub fn blitBufferToTexture(request: Request, destination_bytes: []u8) Error!void {
    if (!request.source_has_storage_usage) return error.StorageRequired;
    if (!isFormatSupportedByBufferToTextureBlit(request.destination_format)) {
        return error.UnsupportedFormat;
    }
    if (request.destination_dimension == ._1d) return error.OneDimensionalTexture;
    if (request.destination_aspect != .all) return error.NonColorAspect;
    const texel_count = @as(u64, request.copy_extent.width) *
        @as(u64, request.copy_extent.height) *
        @as(u64, request.copy_extent.depth_or_array_layers);
    if (texel_count == 0) return error.EmptyExtent;
    if (request.source.bytes_per_row % 4 != 0) return error.PitchNotWordAligned;
    const pixel_size = pixelSize(request.destination_format) orelse
        return error.UnsupportedFormat;

    const wanted_byte_count = std.math.mul(
        u64,
        texel_count,
        pixel_size,
    ) catch return error.DestinationTooSmall;
    if (wanted_byte_count > destination_bytes.len) return error.DestinationTooSmall;

    // Dawn runs one render pass per layer (`:449-512`), each with the viewport
    // set to the copy rectangle (`:501-505`) and one three-vertex draw.
    var layer_index: u32 = 0;
    while (layer_index < request.copy_extent.depth_or_array_layers) : (layer_index += 1) {
        const offsets = try layerOffsets(
            request.source,
            request.storage_buffer_offset_alignment,
            layer_index,
        );
        // SAFETY: `writeParams` below assigns all four fields of this
        // `extern struct` before the first read, which is
        // `shaderReadByteOffset` in the next loop iteration.
        var params: Params = undefined;
        writeParams(
            &params,
            request.source,
            offsets.read_offset,
            request.destination_origin,
        );

        var y: u32 = 0;
        while (y < request.copy_extent.height) : (y += 1) {
            var x: u32 = 0;
            while (x < request.copy_extent.width) : (x += 1) {
                // Upstream sets the viewport to the copy rectangle at
                // `:501-505`, so the first fragment's `position.xy` is the
                // destination origin and not zero. The shader subtracts that
                // origin back out at `:98`.
                const position: [2]i64 = .{
                    @as(i64, request.destination_origin.x) + @as(i64, x),
                    @as(i64, request.destination_origin.y) + @as(i64, y),
                };
                const from_binding = shaderReadByteOffset(params, pixel_size, position);
                const read_offset = std.math.add(
                    u64,
                    offsets.binding_offset,
                    from_binding,
                ) catch return error.SourceTooSmall;
                const texel = switch (request.destination_format) {
                    .rgba8_unorm => try unpackRgba8Unorm(request.source_bytes, read_offset),
                    .bgra8_unorm => try unpack4x8UnormBgra(request.source_bytes, read_offset),
                    else => return error.UnsupportedFormat,
                };
                try writeTexel(request, destination_bytes, layer_index, x, y, texel);
            }
        }
    }
}

/// Quantise `texel` into the four bytes the destination subresource holds, in
/// the format's own channel order, at the texel's row-major index.
fn writeTexel(
    request: Request,
    destination_bytes: []u8,
    layer_index: u32,
    x: u32,
    y: u32,
    texel: Texel,
) Error!void {
    const ordered: [4]u8 = switch (request.destination_format) {
        .bgra8_unorm => .{
            quantizeUnorm8(texel[2]),
            quantizeUnorm8(texel[1]),
            quantizeUnorm8(texel[0]),
            quantizeUnorm8(texel[3]),
        },
        else => .{
            quantizeUnorm8(texel[0]),
            quantizeUnorm8(texel[1]),
            quantizeUnorm8(texel[2]),
            quantizeUnorm8(texel[3]),
        },
    };
    const layer_stride = @as(usize, request.copy_extent.width) *
        @as(usize, request.copy_extent.height);
    const texel_index = @as(usize, layer_index) * layer_stride +
        @as(usize, y) * @as(usize, request.copy_extent.width) +
        @as(usize, x);
    const start = std.math.mul(usize, texel_index, ordered.len) catch
        return error.DestinationTooSmall;
    const end = std.math.add(usize, start, ordered.len) catch
        return error.DestinationTooSmall;
    if (end > destination_bytes.len) return error.DestinationTooSmall;
    var channel: usize = 0;
    while (channel < ordered.len) : (channel += 1) {
        destination_bytes[start + channel] = ordered[channel];
    }
}

/// `round(255 * clamp(value, 0, 1))`, the quantisation WGSL's `pack4x8unorm`
/// applies and its `unpack4x8unorm` inverts.
pub fn quantizeUnorm8(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}
