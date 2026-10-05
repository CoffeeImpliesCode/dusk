//! `src/dawn/native/BlitTextureToBuffer.cpp`: the texture-to-buffer copy.
//!
//! **What this file is.** The compute-pass emulation of
//! `vkCmdCopyImageToBuffer`. It holds the destination layout arithmetic at
//! `BlitTextureToBuffer.cpp:1584-1662`, the uniform Dawn fills at `:1740-1777`,
//! the destination address the shader computes at `:359-361`, and the two
//! `pack4x8unorm` encoders at `:229-233` and `:257-263`.
//!
//! **What this file does not claim.** It does not claim a compute pipeline.
//! `GetOrCreateTextureToBufferPipeline` (`:961`) assembles WGSL text for the
//! forty formats its switch at `:1057-1426` names, and `AGENTS.md` §3.2 forbids a
//! WGSL front end in the library. It does not claim the thirty-eight formats in
//! its own allowlist that its pack does not lay out:
//! `isFormatSupportedByTextureToBufferBlit` answers the family contract, and
//! `blitTextureToBuffer` answers for the texels it can pack, which are the two
//! four-channel unorm formats the acceptance blits.

const std = @import("std");
const enums = @import("../api/enums.zig");
const descriptors = @import("../api/descriptors.zig");

const TextureFormat = enums.TextureFormat;
const Extent3D = descriptors.Extent3D;
const Origin3D = descriptors.Origin3D;
const TexelCopyBufferLayout = descriptors.TexelCopyBufferLayout;

/// What the texture-to-buffer blit can refuse. Every member is named by a case
/// in `test/blit.zig`.
pub const Error = error{
    /// The format is not in the allowlist at `:1496-1540`, or its block size
    /// is not fixed, which is the case for the three `depth24plus` formats.
    UnsupportedFormat,
    /// The format is in the allowlist but this pack does not lay its texels
    /// out, because the upstream shader quantises through `f32` and a host
    /// pack would have to reproduce that rounding to claim the format.
    TexelPackingUnsupported,
    /// `bytesPerRow * rowsPerImage * depthOrArrayLayers` leaves the 64-bit
    /// range. Upstream writes the same guard at
    /// `src/dawn/native/CommandValidation.cpp:307-310` and calls it a check,
    /// so the port returns it rather than wrapping.
    CopySizeOverflow,
    /// The origin plus the copy extent leaves the source subresource.
    SourceExtentTooSmall,
    /// The destination slice is shorter than the copy needs.
    DestinationTooSmall,
    /// The row pitch is zero, so no row has an address, or the storage-buffer
    /// offset alignment is zero, so the shader start offset has no meaning.
    ZeroRowPitch,
};

/// The order a four-channel texel's bytes reach the buffer in.
///
/// Upstream writes the order into two shaders rather than into a table:
/// `pack4x8unorm(v)` for `rgba8unorm` (`:229-233`) and `pack4x8unorm(v.bgra)`
/// for `bgra8unorm` (`:257-263`). The port names the two so the swap is one
/// value rather than a second copy of the loop.
pub const ChannelOrder = enum {
    /// Red, green, blue, alpha in increasing address order.
    rgba,
    /// Blue, green, red, alpha in increasing address order. Red and blue are
    /// exchanged and green and alpha are not, so the order is its own inverse.
    bgra,
};

/// One texel as the shader sees it: four channels in `[0, 1]`, the domain
/// `pack4x8unorm` quantises.
pub const Texel = [4]f32;

/// The uniform the compute shader reads, byte for byte the one Dawn declares
/// at `:293-314` and mirrors in WGSL at `:319-337`.
///
/// Upstream asserts none of this layout, so a silent field shift would corrupt
/// every copy without failing a build. The comptime block below is the
/// assertion the port owes it. `math::Vec3u` is `Vector<3, uint32_t>` upstream
/// (`src/dawn/common/Algebra.h:402`) and `Vector` is `alignas(16)` (`:63`),
/// which is what the four padding arrays reproduce; WGSL spells the same thing
/// `@size(16)` at `:321` and `:324`.
pub const Params = extern struct {
    src_origin: [3]u32,
    _pad_origin: [4]u8,
    pack_texel_count: u32,
    _pad_pack_count: [12]u8,
    src_extent: [3]u32,
    _pad_extent: [4]u8,
    mip_level: u32,
    bytes_per_row: u32,
    rows_per_image: u32,
    offset: u32,
    shift: u32,
    texel_size: u32,
    num_u32_per_row_needs_writing: u32,
    read_previous_row: u32,
    is_compact_image: u32,
    _pad_level: [12]u8,
    level_size: [3]u32,
    _pad_end: [4]u8,
};

comptime {
    std.debug.assert(@offsetOf(Params, "src_origin") == 0);
    std.debug.assert(@offsetOf(Params, "pack_texel_count") == 16);
    std.debug.assert(@offsetOf(Params, "src_extent") == 32);
    std.debug.assert(@offsetOf(Params, "mip_level") == 48);
    std.debug.assert(@offsetOf(Params, "bytes_per_row") == 52);
    std.debug.assert(@offsetOf(Params, "rows_per_image") == 56);
    std.debug.assert(@offsetOf(Params, "offset") == 60);
    std.debug.assert(@offsetOf(Params, "shift") == 64);
    std.debug.assert(@offsetOf(Params, "texel_size") == 68);
    std.debug.assert(@offsetOf(Params, "num_u32_per_row_needs_writing") == 72);
    std.debug.assert(@offsetOf(Params, "read_previous_row") == 76);
    std.debug.assert(@offsetOf(Params, "is_compact_image") == 80);
    std.debug.assert(@offsetOf(Params, "level_size") == 96);
    std.debug.assert(@sizeOf(Params) == 112);
}

/// The workgroup edge the dispatch rounds up to. Upstream holds it in
/// `kWorkgroupSizeX` (`:58`).
pub const workgroup_size_x: u32 = 8;

/// The workgroup height. Upstream forces it to one for a 1D view at
/// `:1475-1476`; the port has no 1D view and keeps the general case.
pub const workgroup_size_y: u32 = 8;

/// Whether the texture-to-buffer family has a shader for this format.
///
/// The list is hand-maintained upstream under `TODO(348654098)` at `:1494`, so
/// the port keeps it exactly and `test/blit.zig` sweeps it against the whole
/// `TextureFormat` domain. A dropped entry loses a format silently; the sweep
/// is what turns that into a compile error.
pub fn isFormatSupportedByTextureToBufferBlit(format: TextureFormat) bool {
    return switch (format) {
        .r8_snorm,
        .r8_unorm,
        .rg8_snorm,
        .rg8_unorm,
        .rgba8_snorm,
        .rgba8_unorm,
        .bgra8_unorm,
        .rgb9_e5_ufloat,
        .rg11_b10_ufloat,
        .r16_float,
        .rg16_float,
        .rgba16_float,
        .r32_float,
        .rg32_float,
        .rgba32_float,
        .r8_uint,
        .r8_sint,
        .rg8_uint,
        .rg8_sint,
        .rgba8_uint,
        .rgba8_sint,
        .r16_uint,
        .r16_sint,
        .rg16_uint,
        .rg16_sint,
        .rgba16_uint,
        .rgba16_sint,
        .r32_uint,
        .r32_sint,
        .rg32_uint,
        .rg32_sint,
        .rgba32_uint,
        .rgba32_sint,
        .rgb10_a2_uint,
        .depth16_unorm,
        .depth24_plus,
        .depth32_float,
        .stencil8,
        .depth24_plus_stencil8,
        .depth32_float_stencil8,
        => true,
        else => false,
    };
}

/// The order a format's four-channel texels reach the buffer in, or null when
/// this pack does not lay them out.
pub fn channelOrderFor(format: TextureFormat) ?ChannelOrder {
    return switch (format) {
        .rgba8_unorm => .rgba,
        .bgra8_unorm => .bgra,
        else => null,
    };
}

/// The byte size of one block of `format`, or null when it has none.
///
/// Upstream takes the value from `TypedTexelBlockInfo::byteSize` rather than
/// from the format (`:1590`), because a compressed format's block spans several
/// texels. The allowlist at `:1496-1540` holds no compressed format, so for
/// every format that list accepts the two agree.
///
/// The three null cases are the `depth24plus` family. Upstream copies the depth
/// aspect as `f32` because `depth24plus` is not copyable in WebGPU directly
/// (`:1353-1354`), and `depth32float-stencil8` has two aspects, so the port
/// refuses them rather than guess a layout it cannot reproduce.
pub fn bytesPerBlock(format: TextureFormat) ?u32 {
    return switch (format) {
        .r8_snorm, .r8_unorm, .r8_uint, .r8_sint => 1,
        .rg8_snorm,
        .rg8_unorm,
        .rg8_uint,
        .rg8_sint,
        .r16_float,
        .r16_uint,
        .r16_sint,
        .stencil8,
        => 2,
        .rgba8_snorm,
        .rgba8_unorm,
        .rgba8_uint,
        .rgba8_sint,
        .bgra8_unorm,
        .rgb10_a2_uint,
        .rgb9_e5_ufloat,
        .rg11_b10_ufloat,
        .r32_float,
        .r32_uint,
        .r32_sint,
        .rg16_float,
        .rg16_uint,
        .rg16_sint,
        .rg32_float,
        .rg32_uint,
        .rg32_sint,
        .depth16_unorm,
        => 4,
        .rgba16_float, .rgba16_uint, .rgba16_sint => 8,
        .rgba32_float, .rgba32_uint, .rgba32_sint => 16,
        .depth32_float => 4,
        .depth24_plus, .depth24_plus_stencil8, .depth32_float_stencil8 => null,
        else => null,
    };
}

/// `max(bytesPerBlock, 4)`, `:1474`. A format narrower than a word still has
/// its texels packed into whole `u32` elements, so the unit is never below
/// four.
pub fn outputUnitSize(bytes_per_block: u32) u32 {
    return @max(bytes_per_block, 4);
}

/// `max(1, 4 / bytesPerBlock)`, `:1747`: how many texels one thread packs.
pub fn packTexelCount(bytes_per_block: u32) u32 {
    return @max(1, 4 / bytes_per_block);
}

/// `(shaderStartOffset % 4) / bytesPerBlock`, `:1760`. Only the sub-word path
/// reads it, and this pack lays out none of that, so it stays the arithmetic
/// and not a parameter.
pub fn shiftFor(shader_start_offset: u32, bytes_per_block: u32) u32 {
    return (shader_start_offset % 4) / bytes_per_block;
}

/// `(bytesInRow + extraBytes + 3) / 4`, `:1621-1622`, rounded up to whole
/// words.
///
/// The comment at `:1616-1620` gives the case: a 256-texel `R8Snorm` row needs
/// 64 words at offset zero and 65 at offset one, because the first and the
/// last word each hold a byte the blit does not own.
pub fn numU32PerRowNeedsWritingRoundedUp(bytes_in_row: u32, extra_bytes: u32) u32 {
    return @divFloor(bytes_in_row + extra_bytes + 3, 4);
}

/// The byte the copy writes at, given the shader's own address arithmetic at
/// `:359-361`.
///
/// The shader works in `array<u32>` elements, so the offset it computes is an
/// element index and the byte is four times it. `dstOffset` is
/// `indicesOffset + id.x + id.y * indicesPerRow + id.z * indicesPerRow *
/// rowsPerImage`, and `id.x` is a texel index once `packTexelCount` is one,
/// which is the case for every format of four bytes or more.
pub fn destinationByteOffset(
    bytes_per_row: u32,
    rows_per_image: u32,
    shader_start_offset: u32,
    output_unit: u32,
    global_id: [3]u32,
) u64 {
    const indices_per_row = bytes_per_row / output_unit;
    const indices_offset = shader_start_offset / output_unit;
    const element_index = @as(u64, indices_offset) +
        @as(u64, global_id[0]) +
        @as(u64, global_id[1]) * @as(u64, indices_per_row) +
        @as(u64, global_id[2]) * @as(u64, indices_per_row) * @as(u64, rows_per_image);
    return element_index * @sizeOf(u32);
}

/// `ComputeRequiredBytesInCopy`
/// (`src/dawn/native/CommandValidation.cpp:295-320`) for the uncompressed case,
/// where one block is one texel.
///
/// The last row contributes its true length and not its padded one. For a 4x4
/// `rgba8unorm` at a 256-byte pitch that is `256 * 3 + 16`, which
/// `docs/50-verification.md:281-282` states for the staging size.
pub fn computeRequiredBytesInCopy(
    bytes_per_block: u32,
    copy_extent: Extent3D,
    blocks_per_row: u32,
    rows_per_image: u32,
) Error!u64 {
    if (copy_extent.depth_or_array_layers == 0) return 0;

    const blocks_per_image = std.math.mul(
        u64,
        blocks_per_row,
        rows_per_image,
    ) catch return error.CopySizeOverflow;
    const bytes_per_image = std.math.mul(
        u64,
        blocks_per_image,
        bytes_per_block,
    ) catch return error.CopySizeOverflow;
    const bytes_to_copy = std.math.mul(
        u64,
        bytes_per_image,
        copy_extent.depth_or_array_layers - 1,
    ) catch return error.CopySizeOverflow;

    var required_bytes: u64 = bytes_to_copy;
    if (copy_extent.height > 0) {
        const blocks_in_last_image = std.math.add(
            u64,
            std.math.mul(u64, blocks_per_row, copy_extent.height - 1) catch
                return error.CopySizeOverflow,
            copy_extent.width,
        ) catch return error.CopySizeOverflow;
        required_bytes = std.math.add(
            u64,
            required_bytes,
            std.math.mul(u64, blocks_in_last_image, bytes_per_block) catch
                return error.CopySizeOverflow,
        ) catch return error.CopySizeOverflow;
    }
    return required_bytes;
}

/// Everything `BlitTextureToBuffer()` derives before it can dispatch, at
/// `:1590-1662`.
///
/// The port exposes it because every field is observable without a device, and
/// because each is wrong in exactly one way: a pitch off by a row, an offset
/// that is not storage-buffer aligned, a last row counted at its padded length.
pub const Layout = struct {
    /// `blockInfo.byteSize`, `:1590`.
    bytes_per_block: u32,
    /// `ToBytes(blocksPerRow)`, `:1755`. This is the pitch the uniform carries
    /// and the only place the block-to-byte conversion happens.
    bytes_per_row: u32,
    /// `max(1, 4 / bytesPerBlock)`, `:1747`.
    pack_texel_count: u32,
    /// `max(bytesPerBlock, 4)`, the size of one `array<u32>` element the
    /// shader writes, `:1474`.
    output_unit_size: u32,
    /// `offset % ssboAlignment`, the byte the shader starts at, `:1600`.
    shader_start_offset: u32,
    /// `offset - shaderStartOffset`, the aligned byte the buffer is bound at,
    /// `:1603`.
    shader_binding_offset: u64,
    /// `(bytesInRow + extraBytes + 3) / 4`, `:1621-1622`. Zero for every
    /// format of four bytes or more, which is the only case this pack has.
    num_u32_per_row_needs_writing: u32,
    /// `bytesInRow + extraBytes > bytesPerRow`, `:1611-1612`.
    read_previous_row: bool,
    /// `rowsPerImage == copyHeight`, `:1765`.
    is_compact_image: bool,
    /// The dispatch shape, `:1591-1595` and `:1623-1643`.
    workgroup_count: [3]u32,
    /// `ComputeRequiredBytesInCopy`, `:1654-1655`.
    required_bytes: u64,
    /// `shaderStartOffset + requiredBytes`, `:1656`.
    shader_end_offset: u64,
    /// `Align(shaderEndOffset, 4)`, `:1657`.
    shader_binding_size: u64,
    /// The two reasons at `:1658-1662`: the aligned binding runs past the end
    /// of the destination, or the destination cannot be bound as storage.
    needs_intermediate_buffer: bool,
};

/// What `deriveLayout` needs: the internal copy layout plus the two
/// destination-buffer facts the intermediate decision reads at `:1658-1661`.
pub const DeriveRequest = struct {
    format: TextureFormat,
    /// The copy rectangle in blocks. For the forty formats this blit supports
    /// a block is a texel, so the two extents are the same value.
    copy_extent: Extent3D,
    /// `BufferCopy::blocksPerRow` (`src/dawn/native/Commands.h:208-217`), which
    /// the front end derives as `BytesToBlocks(bytesPerRow)` at
    /// `CommandEncoder.cpp:2022`.
    blocks_per_row: u32,
    rows_per_image: u32,
    /// The public layout's `offset`, `TexelCopyBufferLayout.offset`.
    offset: u64,
    /// `limits.v1.minStorageBufferOffsetAlignment`, `:1598`.
    storage_buffer_offset_alignment: u32,
    /// The destination buffer's size in bytes.
    destination_byte_count: u64,
    /// Whether the destination buffer may be bound as storage.
    destination_has_storage_usage: bool,
};

/// Derive everything the dispatch needs, at `:1590-1662`.
pub fn deriveLayout(request: DeriveRequest) Error!Layout {
    if (!isFormatSupportedByTextureToBufferBlit(request.format)) {
        return error.UnsupportedFormat;
    }
    const bytes_per_block = bytesPerBlock(request.format) orelse
        return error.UnsupportedFormat;
    if (request.blocks_per_row == 0) return error.ZeroRowPitch;
    if (request.storage_buffer_offset_alignment == 0) return error.ZeroRowPitch;

    const bytes_per_row = std.math.mul(
        u32,
        request.blocks_per_row,
        bytes_per_block,
    ) catch return error.CopySizeOverflow;

    // `shaderStartOffset` is the offset to start writing in shader (`:1600`)
    // and `shaderBindingOffset` is the aligned offset the buffer is bound at
    // (`:1603`). The binding must be aligned and the shader adds the remainder
    // back, so the two are different numbers and the difference is the caller's
    // `offset`. This pair is the most error-prone place in the file.
    const shader_start_offset: u32 = @intCast(request.offset %
        request.storage_buffer_offset_alignment);
    const shader_binding_offset = request.offset - shader_start_offset;

    const bytes_in_row = std.math.mul(
        u32,
        request.copy_extent.width,
        bytes_per_block,
    ) catch return error.CopySizeOverflow;
    // `shaderStartOffset % 4`, `:1607-1608`. It only reaches the row-crossing
    // test for a format narrower than a word.
    const extra_bytes = shader_start_offset % 4;
    const read_previous_row = bytes_in_row + extra_bytes > bytes_per_row;

    // The sub-word branch at `:1606-1623` never runs for a format of four
    // bytes or more, so `numU32PerRowNeedsWriting` keeps its `:1597` zero and
    // `shift` is the arithmetic rather than a parameter.
    const num_u32_per_row_needs_writing: u32 = 0;

    const workgroup_count: [3]u32 = .{
        @divFloor(request.copy_extent.width + workgroup_size_x - 1, workgroup_size_x),
        @divFloor(request.copy_extent.height + workgroup_size_y - 1, workgroup_size_y),
        request.copy_extent.depth_or_array_layers,
    };

    const required_bytes = try computeRequiredBytesInCopy(
        bytes_per_block,
        request.copy_extent,
        request.blocks_per_row,
        request.rows_per_image,
    );
    const shader_end_offset = std.math.add(
        u64,
        shader_start_offset,
        required_bytes,
    ) catch return error.CopySizeOverflow;
    const shader_binding_size = @divFloor(shader_end_offset + 3, 4) * 4;

    // `:1658-1662`. The aligned binding overruns the buffer, or the buffer
    // cannot be bound as storage, so Dawn copies through an intermediate.
    const binding_end = std.math.add(
        u64,
        shader_binding_offset,
        shader_binding_size,
    ) catch return error.CopySizeOverflow;
    const needs_intermediate_buffer = binding_end > request.destination_byte_count or
        !request.destination_has_storage_usage;

    return .{
        .bytes_per_block = bytes_per_block,
        .bytes_per_row = bytes_per_row,
        .pack_texel_count = packTexelCount(bytes_per_block),
        .output_unit_size = outputUnitSize(bytes_per_block),
        .shader_start_offset = shader_start_offset,
        .shader_binding_offset = shader_binding_offset,
        .num_u32_per_row_needs_writing = num_u32_per_row_needs_writing,
        .read_previous_row = read_previous_row,
        .is_compact_image = request.rows_per_image == request.copy_extent.height,
        .workgroup_count = workgroup_count,
        .required_bytes = required_bytes,
        .shader_end_offset = shader_end_offset,
        .shader_binding_size = shader_binding_size,
        .needs_intermediate_buffer = needs_intermediate_buffer,
    };
}

/// `IsFullBufferOverwrittenInTextureToBufferCopy`
/// (`src/dawn/native/CommandBuffer.cpp:335-368`): whether every byte the blit
/// writes is a byte the copy owns, so the prefix and the tail around it need no
/// preservation copy.
///
/// The blit takes the intermediate path when this is false, which is what the
/// 256-byte-pitch acceptance copy hits: a 4x4 `rgba8unorm` has
/// `blocks_per_row` of 64 against a width of 4, so the rows leave gaps.
pub fn isFullBufferOverwritten(request: DeriveRequest) Error!bool {
    if (request.offset > 0) return false;

    const multi_slice = request.copy_extent.depth_or_array_layers > 1;
    const multi_row = multi_slice or request.copy_extent.height > 1;

    if (multi_slice and request.rows_per_image > request.copy_extent.height) return false;
    if (multi_row and request.blocks_per_row > request.copy_extent.width) return false;

    const bytes_per_block = bytesPerBlock(request.format) orelse
        return error.UnsupportedFormat;
    const written_bytes = try computeRequiredBytesInCopy(
        bytes_per_block,
        request.copy_extent,
        request.blocks_per_row,
        request.rows_per_image,
    );
    return request.offset + written_bytes == request.destination_byte_count;
}

/// The uniform Dawn fills at `:1740-1777`, as this port fills it.
///
/// `srcOrigin` is the copy origin (`:1742-1746`), `srcExtent` the copy extent
/// (`:1748-1752`), `levelSize` the cube sample's mip virtual size
/// (`:1769-1775`). This port has no cube view and no mip level, so those two
/// are zero and the fields are here because the layout assertion covers them.
pub fn writeParams(params: *Params, request: DeriveRequest, layout: Layout) void {
    params.* = .{
        .src_origin = .{ 0, 0, 0 },
        ._pad_origin = @splat(0),
        .pack_texel_count = layout.pack_texel_count,
        ._pad_pack_count = @splat(0),
        .src_extent = .{
            request.copy_extent.width,
            request.copy_extent.height,
            request.copy_extent.depth_or_array_layers,
        },
        ._pad_extent = @splat(0),
        .mip_level = 0,
        .bytes_per_row = layout.bytes_per_row,
        .rows_per_image = request.rows_per_image,
        .offset = layout.shader_start_offset,
        .shift = shiftFor(layout.shader_start_offset, layout.bytes_per_block),
        .texel_size = layout.bytes_per_block,
        .num_u32_per_row_needs_writing = layout.num_u32_per_row_needs_writing,
        .read_previous_row = @intFromBool(layout.read_previous_row),
        .is_compact_image = @intFromBool(layout.is_compact_image),
        ._pad_level = @splat(0),
        .level_size = .{ 0, 0, 0 },
        ._pad_end = @splat(0),
    };
}

/// `round(255 * clamp(value, 0, 1))`, the quantisation WGSL's `pack4x8unorm`
/// applies to each channel.
pub fn quantizeUnorm8(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}

/// `pack4x8unorm(texel)`, the `rgba8unorm` encoder at `:229-233`. Byte zero is
/// the red channel.
pub fn pack4x8Unorm(texel: Texel) u32 {
    return @as(u32, quantizeUnorm8(texel[0])) |
        (@as(u32, quantizeUnorm8(texel[1])) << 8) |
        (@as(u32, quantizeUnorm8(texel[2])) << 16) |
        (@as(u32, quantizeUnorm8(texel[3])) << 24);
}

/// `pack4x8unorm(texel.bgra)`, the `bgra8unorm` encoder at `:257-263`. Red and
/// blue are exchanged and green and alpha are not, so the word differs from
/// `pack4x8Unorm` in bits 0-7 and 16-23 and nowhere else.
pub fn pack4x8UnormBgra(texel: Texel) u32 {
    return @as(u32, quantizeUnorm8(texel[2])) |
        (@as(u32, quantizeUnorm8(texel[1])) << 8) |
        (@as(u32, quantizeUnorm8(texel[0])) << 16) |
        (@as(u32, quantizeUnorm8(texel[3])) << 24);
}

/// What `blitTextureToBuffer` copies.
pub const Request = struct {
    /// The source subresource's texels, in row-major order with no row
    /// padding, which is what a texture subresource is.
    source_bytes: []const u8,
    /// The source subresource's extent. A copy rectangle's rows are the
    /// subresource's rows, so the stride needs the subresource width and not
    /// the copy width.
    source_extent: Extent3D,
    source_format: TextureFormat,
    /// The copy origin inside the subresource, `:1742-1746`.
    source_origin: Origin3D = .{},
    /// The copy rectangle in texels, `:1584-1589`.
    copy_extent: Extent3D,
    /// The destination layout in the buffer. `bytes_per_row` is the public
    /// byte pitch; `deriveLayout` takes its block form.
    destination: TexelCopyBufferLayout,
    /// `minStorageBufferOffsetAlignment`, `:1598`.
    storage_buffer_offset_alignment: u32,
    /// The destination buffer's size.
    destination_byte_count: u64,
    /// Whether the destination buffer may be bound as storage, `:1660-1661`.
    destination_has_storage_usage: bool,
};

/// The derive request `Request` describes.
///
/// The public layout carries bytes and the internal one carries blocks
/// (`CommandEncoder.cpp:2022`), so the conversion happens once, here, and not
/// inside the arithmetic where it would be done twice.
pub fn deriveRequestFor(request: Request) Error!DeriveRequest {
    const bytes_per_block = bytesPerBlock(request.source_format) orelse
        return error.UnsupportedFormat;
    if (request.destination.bytes_per_row == 0) return error.ZeroRowPitch;
    if (request.destination.bytes_per_row % bytes_per_block != 0) {
        return error.ZeroRowPitch;
    }
    return .{
        .format = request.source_format,
        .copy_extent = request.copy_extent,
        .blocks_per_row = request.destination.bytes_per_row / bytes_per_block,
        .rows_per_image = request.destination.rows_per_image,
        .offset = request.destination.offset,
        .storage_buffer_offset_alignment = request.storage_buffer_offset_alignment,
        .destination_byte_count = request.destination_byte_count,
        .destination_has_storage_usage = request.destination_has_storage_usage,
    };
}

/// Whether the copy rectangle is inside the source subresource.
///
/// Upstream checks the copy range over the whole request and not one texel at a
/// time (`src/dawn/native/CommandEncoder.cpp:1980`), so the port refuses a
/// rectangle that leaves the subresource before it measures the destination,
/// which that file's own comment at `:1976-1979` asks for. `sourceByteOffset`
/// keeps the same three tests because that is the read that needs them.
fn sourceExtentFits(request: Request) Error!void {
    const width = std.math.add(u64, request.source_origin.x, request.copy_extent.width) catch
        return error.SourceExtentTooSmall;
    const height = std.math.add(u64, request.source_origin.y, request.copy_extent.height) catch
        return error.SourceExtentTooSmall;
    const depth = std.math.add(
        u64,
        request.source_origin.z,
        request.copy_extent.depth_or_array_layers,
    ) catch return error.SourceExtentTooSmall;

    if (width > request.source_extent.width) return error.SourceExtentTooSmall;
    if (height > request.source_extent.height) return error.SourceExtentTooSmall;
    if (depth > request.source_extent.depth_or_array_layers) {
        return error.SourceExtentTooSmall;
    }
}

/// The byte a source texel sits at inside `source_bytes`.
///
/// The blit reads the source as a texture view, which spans the whole
/// subresource (`:1796-1808`), so a texel's address is a row-major index into
/// that subresource and not into the copy rectangle.
pub fn sourceByteOffset(request: Request, texel: [3]u32) Error!u64 {
    const width = std.math.add(u64, request.source_origin.x, request.copy_extent.width) catch
        return error.SourceExtentTooSmall;
    const height = std.math.add(u64, request.source_origin.y, request.copy_extent.height) catch
        return error.SourceExtentTooSmall;
    const depth = std.math.add(
        u64,
        request.source_origin.z,
        request.copy_extent.depth_or_array_layers,
    ) catch return error.SourceExtentTooSmall;
    if (width > request.source_extent.width) return error.SourceExtentTooSmall;
    if (height > request.source_extent.height) return error.SourceExtentTooSmall;
    if (depth > request.source_extent.depth_or_array_layers) {
        return error.SourceExtentTooSmall;
    }

    const column = @as(u64, request.source_origin.x) + texel[0];
    const row = @as(u64, request.source_origin.y) + texel[1];
    const layer = @as(u64, request.source_origin.z) + texel[2];
    const texel_index = layer * @as(u64, request.source_extent.height) *
        @as(u64, request.source_extent.width) +
        row * @as(u64, request.source_extent.width) +
        column;
    return std.math.mul(u64, texel_index, @as(u64, bytesPerBlock(request.source_format) orelse
        return error.UnsupportedFormat)) catch return error.SourceExtentTooSmall;
}

/// The four channels of one source texel as the shader's `textureLoad` returns
/// them: logical red, green, blue, alpha, in `[0, 1]`.
///
/// A texture view is a `texture_2d<f32>`, so the driver has already
/// un-swizzled the texel by the time the shader sees it, which is why
/// upstream's `bgra8unorm` encoder has to put the swap back with `.bgra`
/// (`BlitTextureToBuffer.cpp:257-263`). The port applies the same order on the
/// way in, so the encoder below stays upstream's expression and needs no extra
/// knowledge of the format.
fn readChannels(request: Request, texel: [3]u32) Error!Texel {
    const byte_offset = try sourceByteOffset(request, texel);
    const start: usize = @intCast(byte_offset);
    const end = std.math.add(usize, start, 4) catch return error.SourceExtentTooSmall;
    if (end > request.source_bytes.len) return error.SourceExtentTooSmall;
    const in_byte_order: [4]u8 = .{
        request.source_bytes[start],
        request.source_bytes[start + 1],
        request.source_bytes[start + 2],
        request.source_bytes[start + 3],
    };
    const logical: [4]u8 = switch (channelOrderFor(request.source_format) orelse
        return error.TexelPackingUnsupported) {
        .rgba => in_byte_order,
        .bgra => .{
            in_byte_order[2],
            in_byte_order[1],
            in_byte_order[0],
            in_byte_order[3],
        },
    };
    return .{
        @as(f32, @floatFromInt(logical[0])) / 255.0,
        @as(f32, @floatFromInt(logical[1])) / 255.0,
        @as(f32, @floatFromInt(logical[2])) / 255.0,
        @as(f32, @floatFromInt(logical[3])) / 255.0,
    };
}

/// Copy `request.source_bytes` into `destination_bytes` at the request's row
/// pitch, the way Dawn's compute dispatch does.
///
/// The destination is the caller's buffer and not an allocation: `AGENTS.md` §2
/// forbids a hidden allocation, and the acceptance needs the row padding left
/// untouched, which a freshly allocated buffer would hide.
///
/// The loop walks the copy rectangle, so every texel is bounded by
/// `copy_extent`. The destination address is `destinationByteOffset`, the
/// shader's own arithmetic at `:359-361`, which makes the row stride
/// `bytesPerRow / gOutputUnitSize` elements and the image stride `rowsPerImage`
/// rows.
pub fn blitTextureToBuffer(request: Request, destination_bytes: []u8) Error!void {
    // The allowlist is read first, the way upstream reads it twice: the route
    // check `ShouldUseTextureToBufferBlit` calls
    // `IsFormatSupportedByTextureToBufferBlit` to choose the path
    // (`src/dawn/native/CommandEncoder.cpp:1264-1265`, called from `:2008`), and
    // the blit then builds that format's pipeline (`:1579-1580`) before it reads
    // the block info at `:1582`. A format off the list is refused before any of
    // it, and the channel table below cannot answer for it, because it is
    // non-null for two formats only. `deriveLayout` repeats the test because it
    // is public and takes the format on its own.
    if (!isFormatSupportedByTextureToBufferBlit(request.source_format)) {
        return error.UnsupportedFormat;
    }

    // `deriveRequestFor` reads `blockInfo.byteSize` (`:1590`) and the pitch rules
    // `ValidateLinearTextureCopyOffset` and `ValidateLinearTextureData` apply
    // before the blit is reached (`src/dawn/native/CommandEncoder.cpp:1989-1994`).
    // Its block-size half is the only place the three `depth24plus` formats are
    // refused, so it runs before the channel order, which would otherwise name
    // them `TexelPackingUnsupported` and leave `UnsupportedFormat` to the
    // allowlist alone.
    const derive_request = try deriveRequestFor(request);

    // The channel order stands in for the WGSL that
    // `GetOrCreateTextureToBufferPipeline` assembles per format (`:961`, `:1057`).
    // Upstream cannot reach past that call without a pipeline, so a format the
    // list admits but this table does not answer for is refused here rather than
    // later, where one texel would already have been packed by guesswork.
    const channel_order = channelOrderFor(request.source_format) orelse
        return error.TexelPackingUnsupported;
    const layout = try deriveLayout(derive_request);

    // Dawn's shader returns before its first store when the coordinate leaves
    // the copy boundary (`:354-357`), so an empty extent writes nothing. The
    // layout arithmetic above still has to hold, which is why it runs first.
    if (request.copy_extent.width == 0 or request.copy_extent.height == 0 or
        request.copy_extent.depth_or_array_layers == 0)
    {
        return;
    }

    // The rectangle is measured against the source subresource before the
    // destination is measured against the slice: upstream validates the copy
    // range at `src/dawn/native/CommandEncoder.cpp:1980` ahead of the linear
    // layout data at `:1992-1994`, and the layout data is what asks whether the
    // copy fits in the buffer. A rectangle that leaves the subresource is
    // refused whichever rule the destination breaks too.
    try sourceExtentFits(request);

    const end_offset = std.math.add(
        u64,
        request.destination.offset,
        layout.required_bytes,
    ) catch return error.CopySizeOverflow;
    if (end_offset > destination_bytes.len) return error.DestinationTooSmall;

    var z: u32 = 0;
    while (z < request.copy_extent.depth_or_array_layers) : (z += 1) {
        var y: u32 = 0;
        while (y < request.copy_extent.height) : (y += 1) {
            var x: u32 = 0;
            while (x < request.copy_extent.width) : (x += 1) {
                const texel = try readChannels(request, .{ x, y, z });
                const word = switch (channel_order) {
                    .rgba => pack4x8Unorm(texel),
                    .bgra => pack4x8UnormBgra(texel),
                };
                const byte_offset = destinationByteOffset(
                    request.destination.bytes_per_row,
                    request.destination.rows_per_image,
                    layout.shader_start_offset,
                    layout.output_unit_size,
                    .{ x, y, z },
                );
                const start: usize = @intCast(byte_offset);
                const end = std.math.add(usize, start, @sizeOf(u32)) catch
                    return error.DestinationTooSmall;
                if (end > destination_bytes.len) return error.DestinationTooSmall;
                std.mem.writeInt(
                    u32,
                    destination_bytes[start..][0..@sizeOf(u32)],
                    word,
                    .little,
                );
            }
        }
    }
}
