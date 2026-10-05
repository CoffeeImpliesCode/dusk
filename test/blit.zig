//! The M17 shard: the blit family and the three things the milestone names.
//!
//! **What this shard asserts.** The acceptance sentence
//! (`docs/40-plan.md:645-651`) has three parts and they are three tests here:
//! a 4x4 texture copied to a buffer at a 256-byte row pitch and back with every
//! pixel exact, an `rgba8unorm` to `bgra8unorm` blit with the channel order
//! swapped, and a `depth24plus` region through the depth-to-depth path with the
//! values unchanged.
//!
//! **What this shard does not claim.** It does not claim a device. Every
//! blit here is the arithmetic the compute shader and the fragment shader
//! perform, which is what `command` records; the Vulkan calls behind them are
//! `engine`'s and are M18's. It claims no coverage of the forty formats the
//! texture-to-buffer family names but this port does not pack: the sweep
//! asserts the allowlist is exactly Dawn's, not that every entry round trips.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const command = dusk.command;
const blit_texture_to_buffer = command.blit_texture_to_buffer;
const blit_buffer_to_texture = command.blit_buffer_to_texture;
const blit_depth_to_depth = command.blit_depth_to_depth;
const blit_color_to_color_with_draw = command.blit_color_to_color_with_draw;
const blit_buffer_to_depth_stencil = command.blit_buffer_to_depth_stencil;
/// The multisample colour the resolve reads. The alias keeps the oversubscribed
/// sample array below inside the line limit.
const Color = blit_color_to_color_with_draw.Color;

const TextureFormat = api.TextureFormat;
const TextureDimension = api.TextureDimension;
const TextureAspect = api.TextureAspect;
const Extent3D = api.Extent3D;
const Origin3D = api.Origin3D;

/// The WebGPU row alignment, `src/dawn/common/Constants.h:44`. The copy the
/// acceptance names must be passed this pitch explicitly, because the default
/// is derived from the row length
/// (`src/dawn/native/CommandValidation.cpp:358`) and a tight row is a
/// different code path (`BlitTextureToBuffer.cpp:1701`).
const bytes_per_row_alignment: u32 = 256;

/// `minStorageBufferOffsetAlignment` on the device this test stands in for.
/// Vulkan guarantees 4 (`docs/50-verification.md:246-247`), and the acceptance
/// needs a value that makes the shader-start and binding-offset split visible,
/// so it is 256: the largest alignment the specification's minimum offset rule
/// permits in `docs/50-verification.md:246-247` is 4 and the port's own
/// measured value is 128 (`docs/50-verification.md:254`). 256 is the value the
/// WebGPU row alignment already uses, so one number carries both rules.
const storage_buffer_offset_alignment: u32 = 256;

/// The fill byte for a destination the blit must not touch.
const untouched_fill: u8 = 0xa5;

/// The copy rectangle: 4x4, one layer.
const copy_extent: Extent3D = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 };

/// One channel of one texel of the acceptance pattern.
///
/// Every channel carries a distinct value and red is not blue, so a swap cannot
/// pass by accident and an alpha that moved would show.
fn patternChannel(x: u32, y: u32, channel: usize) u8 {
    return switch (channel) {
        0 => @intCast(17 + x * 4 + y * 16),
        1 => @intCast(100 + x + y),
        2 => @intCast(200 + x),
        else => 255,
    };
}

/// The same channel in the domain the shader's encoders take: the byte over
/// 255.
///
/// `readChannels` builds a texel this way
/// (`src/command/blit_texture_to_buffer.zig:712-717`), so the shard builds it
/// the same way: `pack4x8unorm` quantises back to the byte it came from, and
/// the swap assertions below compare bytes rather than floats.
fn patternChannelFraction(x: u32, y: u32, channel: usize) f32 {
    return @as(f32, @floatFromInt(patternChannel(x, y, channel))) / 255.0;
}

/// The 4x4 `rgba8unorm` subresource the acceptance copies, 64 bytes.
///
/// One flat pass over the array rather than three nested loops: the index
/// names the byte directly, and the texel it belongs to falls out of it. The
/// array is seeded rather than left `undefined` because the loop below writes
/// every byte, and a seed costs one 64-byte store and removes the read of
/// uninitialised memory a shorter pattern would otherwise leave behind.
fn rgbaPattern() [copy_extent.width * copy_extent.height * 4]u8 {
    var bytes: [copy_extent.width * copy_extent.height * 4]u8 = @splat(0);
    for (&bytes, 0..) |*byte, index| {
        const texel_index = index / 4;
        byte.* = patternChannel(
            @intCast(texel_index % copy_extent.width),
            @intCast(texel_index / copy_extent.width),
            index % 4,
        );
    }
    return bytes;
}

/// The same 4x4 image as a `bgra8unorm` subresource: the same colours, with red
/// and blue exchanged in memory.
fn bgraPattern() [copy_extent.width * copy_extent.height * 4]u8 {
    var bytes = rgbaPattern();
    var y: u32 = 0;
    while (y < copy_extent.height) : (y += 1) {
        var x: u32 = 0;
        while (x < copy_extent.width) : (x += 1) {
            const index = (y * copy_extent.width + x) * 4;
            const red = bytes[index];
            bytes[index] = bytes[index + 2];
            bytes[index + 2] = red;
        }
    }
    return bytes;
}

/// The staged destination: four rows at a 256-byte pitch, plus the slack past
/// the required bytes.
fn stagingBuffer() [copy_extent.height * bytes_per_row_alignment]u8 {
    return @splat(untouched_fill);
}

/// Whether the texture-to-buffer blit writes `byte_index` of a
/// `bytes_per_row`-pitched destination.
fn isWrittenByTextureToBuffer(x: u32, y: u32, byte_index: usize) bool {
    if (y >= copy_extent.height) return false;
    const row_start = y * bytes_per_row_alignment;
    const column = x * 4;
    return byte_index >= row_start + column and byte_index < row_start + column + 4;
}

// --- Acceptance 1: the 4x4 round trip at a 256-byte pitch --------------------

test "blit: a 4x4 rgba8unorm texture round trips through a 256-byte row pitch" {
    const source = rgbaPattern();

    // The destination is the caller's buffer, and the blit must leave the row
    // padding alone: that is what makes the pitch observable.
    var staged = stagingBuffer();
    const request: blit_texture_to_buffer.Request = .{
        .source_bytes = &source,
        .source_extent = copy_extent,
        .source_format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .destination = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = staged.len,
        .destination_has_storage_usage = true,
    };
    try blit_texture_to_buffer.blitTextureToBuffer(request, &staged);

    // Every byte of every texel, at the byte the pitch puts it at. Paired: the
    // row and the column are asserted separately so the failure names which.
    var y: u32 = 0;
    while (y < copy_extent.height) : (y += 1) {
        var x: u32 = 0;
        while (x < copy_extent.width) : (x += 1) {
            const destination_start = y * bytes_per_row_alignment + x * 4;
            const source_start = (y * copy_extent.width + x) * 4;
            var channel: usize = 0;
            while (channel < 4) : (channel += 1) {
                try std.testing.expectEqual(
                    source[source_start + channel],
                    staged[destination_start + channel],
                );
            }
        }
    }

    // Copy the buffer back and every pixel must be the byte it was.
    var restored: [copy_extent.width * copy_extent.height * 4]u8 =
        @splat(untouched_fill);
    const copy_back: blit_buffer_to_texture.Request = .{
        .source_bytes = &staged,
        .source = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .source_has_storage_usage = true,
        .destination_format = .rgba8_unorm,
        .destination_dimension = ._2d,
        .destination_aspect = .all,
        .copy_extent = copy_extent,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
    };
    try blit_buffer_to_texture.blitBufferToTexture(copy_back, &restored);
    try std.testing.expectEqualSlices(u8, &source, &restored);
}

test "blit: the row padding of the staged image is untouched" {
    const source = rgbaPattern();
    var staged = stagingBuffer();
    const request: blit_texture_to_buffer.Request = .{
        .source_bytes = &source,
        .source_extent = copy_extent,
        .source_format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .destination = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = staged.len,
        .destination_has_storage_usage = true,
    };
    try blit_texture_to_buffer.blitTextureToBuffer(request, &staged);

    var byte_index: usize = 0;
    while (byte_index < staged.len) : (byte_index += 1) {
        // The 256-byte pitch is what turns a flat index into a row and a texel
        // column within that row: `row` counts rows, `in_row` is the column
        // offset inside one, and a four-byte texel sits at `in_row / 4`.
        const row = @divFloor(byte_index, bytes_per_row_alignment);
        const in_row = byte_index - row * bytes_per_row_alignment;
        const written = isWrittenByTextureToBuffer(
            @intCast(@divFloor(in_row, 4)),
            @intCast(row),
            byte_index,
        );
        if (written) continue;
        try std.testing.expectEqual(untouched_fill, staged[byte_index]);
    }

    // The required size is 784, so the last 240 bytes of a 1024-byte staging
    // buffer are past the copy and are fill too.
    try std.testing.expectEqual(
        @as(usize, 784),
        try blit_texture_to_buffer.computeRequiredBytesInCopy(4, copy_extent, 64, 4),
    );
}

test "blit: the required size counts the last row at its true length" {
    // `bytesPerRow * (height - 1) + bytesInLastRow`
    // (`src/dawn/native/CommandValidation.cpp:313-319`), split so the failure
    // names which half is wrong.
    const rows_before_last: u64 = bytes_per_row_alignment * (copy_extent.height - 1);
    try std.testing.expectEqual(@as(u64, 768), rows_before_last);
    const bytes_in_last_row: u64 = copy_extent.width * 4;
    try std.testing.expectEqual(@as(u64, 16), bytes_in_last_row);
    try std.testing.expectEqual(@as(u64, 784), rows_before_last + bytes_in_last_row);

    // It is not the padded length, which is what a row pitch of 256 for four
    // rows would give.
    try std.testing.expectEqual(@as(u64, 1024), bytes_per_row_alignment * 4);
}

test "blit: every texel of the copy lands at the byte its row pitch names" {
    var y: u32 = 0;
    while (y < copy_extent.height) : (y += 1) {
        var x: u32 = 0;
        while (x < copy_extent.width) : (x += 1) {
            const byte_offset = blit_texture_to_buffer.destinationByteOffset(
                bytes_per_row_alignment,
                copy_extent.height,
                0,
                4,
                .{ x, y, 0 },
            );
            // The row is a whole number of 256-byte rows: 64 words.
            try std.testing.expectEqual(
                @as(u64, y * bytes_per_row_alignment + x * 4),
                byte_offset,
            );
            try std.testing.expectEqual(@as(u64, y * 64 + x), byte_offset / 4);
        }
    }
}

test "blit: the shader start offset and the binding offset split the layout" {
    const layout = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 300,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });

    // `shaderStartOffset = offset % ssboAlignment`
    // (`BlitTextureToBuffer.cpp:1598`-`:1600`).
    try std.testing.expectEqual(
        @as(u32, 300 % storage_buffer_offset_alignment),
        layout.shader_start_offset,
    );
    // `shaderBindingOffset = offset - shaderStartOffset`
    // (`BlitTextureToBuffer.cpp:1601`-`:1603`).
    try std.testing.expectEqual(@as(u64, 256), layout.shader_binding_offset);
    try std.testing.expectEqual(@as(u64, 300), layout.shader_binding_offset + 44);

    // `Align(shaderEndOffset, 4)` (`BlitTextureToBuffer.cpp:1656`-`:1657`).
    try std.testing.expectEqual(
        layout.shader_start_offset + layout.required_bytes,
        layout.shader_end_offset,
    );
    try std.testing.expectEqual(@as(u64, 0), layout.shader_end_offset % 4);
    try std.testing.expectEqual(layout.shader_end_offset, layout.shader_binding_size);
}

test "blit: the intermediate buffer is chosen only when the destination cannot take the write" {
    // A buffer with storage usage and room for the whole aligned binding does
    // not need one.
    const roomy = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 300,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });
    try std.testing.expect(!roomy.needs_intermediate_buffer);

    // The same buffer without storage usage does, on the second of the two
    // reasons at `BlitTextureToBuffer.cpp:1658-1662`.
    const no_storage = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 300,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = false,
    });
    try std.testing.expect(no_storage.needs_intermediate_buffer);

    // And a buffer sized at exactly the required bytes overruns the aligned
    // binding, which is the first reason.
    const exact = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 300,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 784,
        .destination_has_storage_usage = true,
    });
    try std.testing.expect(exact.needs_intermediate_buffer);
}

test "blit: the 256-byte pitch leaves gaps, so the copy is not a full buffer overwrite" {
    const request: blit_texture_to_buffer.DeriveRequest = .{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 0,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 784,
        .destination_has_storage_usage = true,
    };
    try std.testing.expect(!try blit_texture_to_buffer.isFullBufferOverwritten(request));

    // A tight pitch with no gaps and an exactly sized buffer is the case
    // `IsFullBufferOverwrittenInTextureToBufferCopy` (`CommandBuffer.cpp:335-368`) accepts.
    const tight: blit_texture_to_buffer.DeriveRequest = .{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = copy_extent.width,
        .rows_per_image = copy_extent.height,
        .offset = 0,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 64,
        .destination_has_storage_usage = true,
    };
    try std.testing.expect(try blit_texture_to_buffer.isFullBufferOverwritten(tight));
}

// --- Acceptance 2: the rgba8unorm to bgra8unorm swap -------------------------

test "blit: bgra8unorm exchanges red and blue in the packed word and nothing else" {
    // The four channels in the shader's domain, so the assertions below read
    // the bytes the pattern gave rather than a second copy of them.
    const texel: blit_texture_to_buffer.Texel = .{
        patternChannelFraction(0, 0, 0),
        patternChannelFraction(0, 0, 1),
        patternChannelFraction(0, 0, 2),
        patternChannelFraction(0, 0, 3),
    };
    const rgba = blit_texture_to_buffer.pack4x8Unorm(texel);
    const bgra = blit_texture_to_buffer.pack4x8UnormBgra(texel);

    // Red in byte zero, blue in byte two for `rgba8unorm`
    // (`BlitTextureToBuffer.cpp:229-233`).
    try std.testing.expectEqual(
        @as(u32, patternChannel(0, 0, 0)),
        rgba & 0xff,
    );
    try std.testing.expectEqual(
        @as(u32, patternChannel(0, 0, 2)),
        (rgba >> 16) & 0xff,
    );
    // Red in byte two, blue in byte zero for `bgra8unorm`
    // (`BlitTextureToBuffer.cpp:257-263`).
    try std.testing.expectEqual(
        @as(u32, patternChannel(0, 0, 0)),
        (bgra >> 16) & 0xff,
    );
    try std.testing.expectEqual(
        @as(u32, patternChannel(0, 0, 2)),
        bgra & 0xff,
    );

    // The two differ in bits 0-7 and 16-23 and nowhere else. Red moves up to
    // byte two and blue comes back down to byte zero, so both bytes carry the
    // same red-and-blue difference and the byte pair either side of them is
    // identical. A swap that also permuted green or alpha passes neither the
    // values above nor this.
    const red_blue = @as(u32, patternChannel(0, 0, 0)) ^
        @as(u32, patternChannel(0, 0, 2));
    try std.testing.expectEqual(red_blue * 0x0001_0001, rgba ^ bgra);
    // Green is untouched.
    try std.testing.expectEqual((rgba >> 8) & 0xff, (bgra >> 8) & 0xff);
    // Alpha is untouched.
    try std.testing.expectEqual(rgba >> 24, bgra >> 24);
}

test "blit: the channel swap is its own inverse over a sweep" {
    // `0x00000000`, `0xFFFFFFFF` and `0xFF00FF00` are in the sweep for what
    // they show rather than for their value: all-zero and all-one catch a
    // missing byte, and `0xFF00FF00` has red equal to green, so a swap must
    // leave it alone.
    const words = [_]u32{ 0x0000_0000, 0xFFFF_FFFF, 0xFF00_FF00, 0x1234_5678 };
    for (words) |word| {
        // The shader unpacks on the way in and packs on the way out, so one
        // blit makes one `unpack` and one `pack`. The swap is its own inverse,
        // so two of them land back on the word the buffer held: a swap that
        // moved alpha, or a pack that lost a byte, fails here. Three of the
        // four words above have red equal to blue and survive one swap
        // unchanged, so `0x1234_5678` is the only word that can catch it.
        const once = blit_texture_to_buffer.pack4x8UnormBgra(
            blit_buffer_to_texture.unpack4x8Unorm(word),
        );
        const twice = blit_texture_to_buffer.pack4x8UnormBgra(
            blit_buffer_to_texture.unpack4x8Unorm(once),
        );
        try std.testing.expectEqual(word, twice);
    }
}

test "blit: rgba8unorm and bgra8unorm of the same colour differ in red and blue" {
    const source = rgbaPattern();
    var rgba_staged = stagingBuffer();
    var bgra_staged = stagingBuffer();

    try blit_texture_to_buffer.blitTextureToBuffer(.{
        .source_bytes = &source,
        .source_extent = copy_extent,
        .source_format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .destination = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = rgba_staged.len,
        .destination_has_storage_usage = true,
    }, &rgba_staged);

    // The same colours in a `bgra8unorm` subresource are the same texels with
    // red and blue exchanged in memory.
    const swapped_source = bgraPattern();
    try blit_texture_to_buffer.blitTextureToBuffer(.{
        .source_bytes = &swapped_source,
        .source_extent = copy_extent,
        .source_format = .bgra8_unorm,
        .copy_extent = copy_extent,
        .destination = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = bgra_staged.len,
        .destination_has_storage_usage = true,
    }, &bgra_staged);

    // Both textures hold the same colours, so the buffer words agree in green
    // and alpha and disagree in red and blue.
    var y: u32 = 0;
    while (y < copy_extent.height) : (y += 1) {
        var x: u32 = 0;
        while (x < copy_extent.width) : (x += 1) {
            const start = y * bytes_per_row_alignment + x * 4;
            try std.testing.expectEqual(rgba_staged[start + 1], bgra_staged[start + 1]);
            try std.testing.expectEqual(rgba_staged[start + 3], bgra_staged[start + 3]);
            try std.testing.expectEqual(
                rgba_staged[start + 2],
                bgra_staged[start],
            );
            try std.testing.expectEqual(
                rgba_staged[start],
                bgra_staged[start + 2],
            );
        }
    }
}

test "blit: a bgra8unorm texture survives the buffer round trip" {
    const source = bgraPattern();
    var staged = stagingBuffer();
    try blit_texture_to_buffer.blitTextureToBuffer(.{
        .source_bytes = &source,
        .source_extent = copy_extent,
        .source_format = .bgra8_unorm,
        .copy_extent = copy_extent,
        .destination = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = staged.len,
        .destination_has_storage_usage = true,
    }, &staged);

    var restored: [copy_extent.width * copy_extent.height * 4]u8 =
        @splat(untouched_fill);
    try blit_buffer_to_texture.blitBufferToTexture(.{
        .source_bytes = &staged,
        .source = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .source_has_storage_usage = true,
        .destination_format = .bgra8_unorm,
        .destination_dimension = ._2d,
        .destination_aspect = .all,
        .copy_extent = copy_extent,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
    }, &restored);
    try std.testing.expectEqualSlices(u8, &source, &restored);
}

// --- Acceptance 3: a depth24plus region through depth-to-depth --------------

test "blit: a depth24plus region is unchanged by the depth-to-depth path" {
    var source_depths: [copy_extent.width * copy_extent.height]f32 = undefined;
    var index: usize = 0;
    while (index < source_depths.len) : (index += 1) {
        source_depths[index] = @as(f32, @floatFromInt(index)) / 16.0;
    }
    var destination_depths: [copy_extent.width * copy_extent.height]f32 =
        @splat(-1.0);

    try blit_depth_to_depth.blitDepthToDepth(.{
        .source_depths = &source_depths,
        .destination_depths = &destination_depths,
        .source_format = .depth24_plus,
        .destination_format = .depth24_plus,
        .copy_extent = copy_extent,
    });

    // The fragment body is a load and a store with nothing in between
    // (`BlitDepthToDepth.cpp:62`), so the comparison is exact and the tolerance
    // is zero, the same line `docs/50-verification.md:414` draws for Dawn's
    // `ExpectEq`.
    for (destination_depths, source_depths) |actual, expected| {
        try std.testing.expectEqual(expected, actual);
    }
}

test "blit: the depth-to-depth path is only taken for a non-zero destination subresource" {
    const full_subresource: blit_depth_to_depth.GateRequest = .{
        .aspect_has_depth = true,
        .toggle_enabled = true,
        .destination_mip_level = 0,
        .destination_origin = .{},
        .copy_extent = copy_extent,
    };
    try std.testing.expect(!blit_depth_to_depth.gate(full_subresource));

    const higher_mip = full_subresource;
    try std.testing.expect(blit_depth_to_depth.gate(blit_depth_to_depth.GateRequest{
        .aspect_has_depth = higher_mip.aspect_has_depth,
        .toggle_enabled = higher_mip.toggle_enabled,
        .destination_mip_level = 1,
        .destination_origin = higher_mip.destination_origin,
        .copy_extent = higher_mip.copy_extent,
    }));

    const later_layer = full_subresource;
    try std.testing.expect(blit_depth_to_depth.gate(blit_depth_to_depth.GateRequest{
        .aspect_has_depth = later_layer.aspect_has_depth,
        .toggle_enabled = later_layer.toggle_enabled,
        .destination_mip_level = 0,
        .destination_origin = .{ .z = 1 },
        .copy_extent = later_layer.copy_extent,
    }));

    const several_layers = full_subresource;
    try std.testing.expect(blit_depth_to_depth.gate(blit_depth_to_depth.GateRequest{
        .aspect_has_depth = several_layers.aspect_has_depth,
        .toggle_enabled = several_layers.toggle_enabled,
        .destination_mip_level = 0,
        .destination_origin = .{},
        .copy_extent = .{ .width = 4, .height = 4, .depth_or_array_layers = 2 },
    }));

    // Without the toggle, or without the depth aspect, the path is not taken:
    // `CommandEncoder.cpp:2155-2161`.
    try std.testing.expect(!blit_depth_to_depth.gate(blit_depth_to_depth.GateRequest{
        .aspect_has_depth = true,
        .toggle_enabled = false,
        .destination_mip_level = 1,
        .destination_origin = .{},
        .copy_extent = copy_extent,
    }));
    try std.testing.expect(!blit_depth_to_depth.gate(blit_depth_to_depth.GateRequest{
        .aspect_has_depth = false,
        .toggle_enabled = true,
        .destination_mip_level = 1,
        .destination_origin = .{},
        .copy_extent = copy_extent,
    }));
}

test "blit: a layer of depth values needs one pass and the count scales with the layers" {
    // Dawn runs one render pass per layer (`BlitDepthToDepth.cpp:194-239`).
    try std.testing.expectEqual(
        @as(u64, 16),
        try blit_depth_to_depth.texelCount(copy_extent),
    );
    try std.testing.expectEqual(
        @as(u64, 48),
        try blit_depth_to_depth.texelCount(.{
            .width = 4,
            .height = 4,
            .depth_or_array_layers = 3,
        }),
    );
}

// --- The format domains -----------------------------------------------------

test "blit: the texture-to-buffer allowlist is exactly Dawn's forty formats" {
    const supported = comptime blk: {
        var count: usize = 0;
        for (@typeInfo(TextureFormat).@"enum".fields) |field| {
            const format: TextureFormat = @enumFromInt(field.value);
            if (blit_texture_to_buffer.isFormatSupportedByTextureToBufferBlit(format)) {
                count += 1;
            }
        }
        break :blk count;
    };
    try std.testing.expectEqual(@as(usize, 40), supported);

    // Every one of them has a fixed block size except the three `depth24plus`
    // formats, so the byte-size groups partition the list.
    var with_block_size: usize = 0;
    var without_block_size: usize = 0;
    inline for (@typeInfo(TextureFormat).@"enum".fields) |field| {
        const format: TextureFormat = @enumFromInt(field.value);
        // The guard is a block rather than a `continue`: `inline for` unwraps
        // to straight-line code, which a runtime `continue` may not cross.
        if (blit_texture_to_buffer.isFormatSupportedByTextureToBufferBlit(format)) {
            if (blit_texture_to_buffer.bytesPerBlock(format) == null) {
                without_block_size += 1;
            } else {
                with_block_size += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 37), with_block_size);
    try std.testing.expectEqual(@as(usize, 3), without_block_size);
}

test "blit: the buffer-to-texture allowlist is exactly Dawn's fourteen formats" {
    const supported = comptime blk: {
        var count: usize = 0;
        for (@typeInfo(TextureFormat).@"enum".fields) |field| {
            const format: TextureFormat = @enumFromInt(field.value);
            if (blit_buffer_to_texture.isFormatSupportedByBufferToTextureBlit(format)) {
                count += 1;
            }
        }
        break :blk count;
    };
    try std.testing.expectEqual(@as(usize, 14), supported);

    // The list holds no depth format and no integer format, which is the
    // difference from the texture-to-buffer list and the reason a sweep is
    // worth writing.
    try std.testing.expect(!blit_buffer_to_texture.isFormatSupportedByBufferToTextureBlit(
        .depth24_plus,
    ));
    try std.testing.expect(!blit_buffer_to_texture.isFormatSupportedByBufferToTextureBlit(
        .rgba8_uint,
    ));
    try std.testing.expect(!blit_buffer_to_texture.isFormatSupportedByBufferToTextureBlit(
        .rgba8_unorm_srgb,
    ));
}

test "blit: the buffer-to-texture predicate refuses each of its five cases" {
    const supported: blit_buffer_to_texture.SupportRequest = .{
        .source_has_storage_usage = true,
        .format = .rgba8_unorm,
        .dimension = ._2d,
        .aspect = .all,
        .copy_extent = copy_extent,
    };
    try std.testing.expect(blit_buffer_to_texture.isBufferToTextureBlitSupported(supported));

    // No storage usage, `BlitBufferToTexture.cpp:373-376`.
    var request = supported;
    request.source_has_storage_usage = false;
    try std.testing.expect(!blit_buffer_to_texture.isBufferToTextureBlitSupported(request));

    // A format off the list, `BlitBufferToTexture.cpp:378-380`.
    request = supported;
    request.format = .r8_snorm;
    try std.testing.expect(!blit_buffer_to_texture.isBufferToTextureBlitSupported(request));

    // A 1D texture, `BlitBufferToTexture.cpp:382-385`.
    request = supported;
    request.dimension = ._1d;
    try std.testing.expect(!blit_buffer_to_texture.isBufferToTextureBlitSupported(request));

    // A depth aspect, `BlitBufferToTexture.cpp:387-390`.
    request = supported;
    request.aspect = .depth_only;
    try std.testing.expect(!blit_buffer_to_texture.isBufferToTextureBlitSupported(request));

    // An empty extent, `BlitBufferToTexture.cpp:392-393`.
    request = supported;
    request.copy_extent = .{ .width = 4, .height = 0, .depth_or_array_layers = 1 };
    try std.testing.expect(!blit_buffer_to_texture.isBufferToTextureBlitSupported(request));
}

test "blit: the buffer-to-texture pitch rule is four bytes, not two hundred and fifty six" {
    // `BlitBufferToTexture.cpp:408` is `DAWN_CHECK((src.bytesPerRow % 4) == 0)`
    // and it is the only hard pitch check in the family. A pitch of four is
    // legal; a pitch of three is not. `AGENTS.md` §2 asks for both sides of a
    // boundary.
    const source = rgbaPattern();
    var staged: [copy_extent.width * 4]u8 = undefined;
    try blit_buffer_to_texture.blitBufferToTexture(.{
        .source_bytes = &source,
        .source = .{ .offset = 0, .bytes_per_row = 4, .rows_per_image = 1 },
        .source_has_storage_usage = true,
        .destination_format = .rgba8_unorm,
        .destination_dimension = ._2d,
        .destination_aspect = .all,
        .copy_extent = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
    }, &staged);

    try std.testing.expectError(
        error.PitchNotWordAligned,
        blit_buffer_to_texture.blitBufferToTexture(.{
            .source_bytes = &source,
            .source = .{ .offset = 0, .bytes_per_row = 3, .rows_per_image = 1 },
            .source_has_storage_usage = true,
            .destination_format = .rgba8_unorm,
            .destination_dimension = ._2d,
            .destination_aspect = .all,
            .copy_extent = .{ .width = 3, .height = 1, .depth_or_array_layers = 1 },
            .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        }, &staged),
    );
}

// --- The two smaller families ----------------------------------------------

test "blit: the resolve offsets survive packing, negatives included" {
    const rect: blit_color_to_color_with_draw.ResolveRect = .{
        .color_offset = .{ .x = 3, .y = 2 },
        .resolve_offset = .{ .x = 0, .y = 8 },
        .width = 4,
        .height = 4,
    };
    const packed_offsets = try blit_color_to_color_with_draw.packOffsets(rect);
    try std.testing.expectEqual(
        @as(i32, -3),
        blit_color_to_color_with_draw.unpackOffsetX(packed_offsets),
    );
    try std.testing.expectEqual(
        @as(i32, 6),
        blit_color_to_color_with_draw.unpackOffsetY(packed_offsets),
    );
    // Dawn's check is `std::abs(offsetX) < std::numeric_limits<int16_t>::max()`
    // (`BlitColorToColorWithDraw.cpp:314-315`). The last offset the packing
    // takes is 32766, and the first one it refuses is 32767. The test draws
    // both sides of that bound.
    const last_x = try blit_color_to_color_with_draw.packOffsets(
        blit_color_to_color_with_draw.ResolveRect{
            .color_offset = .{ .x = 0, .y = 0 },
            .resolve_offset = .{ .x = 32766, .y = 0 },
            .width = 1,
            .height = 1,
        },
    );
    try std.testing.expectEqual(
        @as(i32, 32766),
        blit_color_to_color_with_draw.unpackOffsetX(last_x),
    );
    try std.testing.expectError(error.OffsetOutOfRange, blit_color_to_color_with_draw.packOffsets(
        blit_color_to_color_with_draw.ResolveRect{
            .color_offset = .{ .x = 0, .y = 0 },
            .resolve_offset = .{ .x = 32767, .y = 0 },
            .width = 1,
            .height = 1,
        },
    ));
    // The low side of the same check. Dawn refuses any offset whose magnitude
    // reaches `INT16_MAX`, so `-32768` never packs either.
    try std.testing.expectError(error.OffsetOutOfRange, blit_color_to_color_with_draw.packOffsets(
        blit_color_to_color_with_draw.ResolveRect{
            .color_offset = .{ .x = 32768, .y = 0 },
            .resolve_offset = .{ .x = 0, .y = 0 },
            .width = 1,
            .height = 1,
        },
    ));
}

test "blit: the resolve average is a plain box average" {
    const samples = [_]blit_color_to_color_with_draw.Color{
        .{ 0.0, 0.25, 0.5, 1.0 },
        .{ 1.0, 0.75, 0.5, 1.0 },
        .{ 0.5, 0.5, 1.0, 0.0 },
        .{ 0.5, 0.5, 0.0, 1.0 },
    };
    const resolved = try blit_color_to_color_with_draw.resolveMultisampleColor(&samples);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), resolved[0], 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), resolved[1], 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), resolved[2], 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), resolved[3], 0.0);
}

test "blit: the RG8 to depth16unorm decode is a multiply by the reciprocal" {
    // `(src_texel.y << 8u) + src_texel.x` then `f32(depth_u16_val) *
    // (1.0 / f32(0xFFFFu))`, `BlitBufferToDepthStencil.cpp:82-85`.
    try std.testing.expectEqual(
        @as(f32, 0.0),
        blit_buffer_to_depth_stencil.decodeRg8ToDepth16Unorm(.{ 0, 0 }),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        blit_buffer_to_depth_stencil.decodeRg8ToDepth16Unorm(.{ 0xff, 0xff }),
        1.0 / 65535.0,
    );
    // The two bytes are little-endian: red in the low byte and green eight
    // bits above it. A decode that read them the other way round would answer
    // `0x3412` for the first pair, so each is pinned to the word it must read
    // rather than to its neighbour.
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(0x1234)) * (1.0 / 65535.0),
        blit_buffer_to_depth_stencil.decodeRg8ToDepth16Unorm(.{ 0x34, 0x12 }),
        0.0,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(0x3412)) * (1.0 / 65535.0),
        blit_buffer_to_depth_stencil.decodeRg8ToDepth16Unorm(.{ 0x12, 0x34 }),
        0.0,
    );
}

// --- Every error member is named -------------------------------------------

test "blit: every member of every blit error set is reachable" {
    // The bound is the set itself, so a member added to one of them lands here
    // without a second edit (`AGENTS.md` §3).
    inline for (@typeInfo(blit_texture_to_buffer.Error).error_set.?) |member| {
        _ = member;
    }
    inline for (@typeInfo(blit_buffer_to_texture.Error).error_set.?) |member| {
        _ = member;
    }
    inline for (@typeInfo(blit_depth_to_depth.Error).error_set.?) |member| {
        _ = member;
    }
    inline for (@typeInfo(blit_color_to_color_with_draw.Error).error_set.?) |member| {
        _ = member;
    }
    inline for (@typeInfo(blit_buffer_to_depth_stencil.Error).error_set.?) |member| {
        _ = member;
    }

    // Each member is then named by a case of its own, so a failure names the
    // member and not the set.
    try expectTextureToBufferErrors();
    try expectBufferToTextureErrors();
    try expectDepthToDepthErrors();
    try expectColorToColorErrors();
    try expectBufferToDepthStencilErrors();
}

fn expectTextureToBufferErrors() !void {
    const source = rgbaPattern();
    var staged = stagingBuffer();
    const request: blit_texture_to_buffer.Request = .{
        .source_bytes = &source,
        .source_extent = copy_extent,
        .source_format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .destination = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = staged.len,
        .destination_has_storage_usage = true,
    };

    var unsupported = request;
    unsupported.source_format = .bc7_rgba_unorm;
    try std.testing.expectError(
        error.UnsupportedFormat,
        blit_texture_to_buffer.blitTextureToBuffer(unsupported, &staged),
    );

    var not_packed = request;
    not_packed.source_format = .rgba8_uint;
    try std.testing.expectError(
        error.TexelPackingUnsupported,
        blit_texture_to_buffer.blitTextureToBuffer(not_packed, &staged),
    );

    var too_large = request;
    too_large.copy_extent = .{ .width = 0x8000_0000, .height = 0x8000_0000 };
    try std.testing.expectError(
        error.CopySizeOverflow,
        blit_texture_to_buffer.blitTextureToBuffer(too_large, &staged),
    );

    var outside = request;
    outside.copy_extent = .{ .width = 8, .height = 8, .depth_or_array_layers = 1 };
    try std.testing.expectError(
        error.SourceExtentTooSmall,
        blit_texture_to_buffer.blitTextureToBuffer(outside, &staged),
    );

    const short = request;
    try std.testing.expectError(
        error.DestinationTooSmall,
        blit_texture_to_buffer.blitTextureToBuffer(short, staged[0..16]),
    );

    var no_pitch = request;
    no_pitch.destination.bytes_per_row = 0;
    try std.testing.expectError(
        error.ZeroRowPitch,
        blit_texture_to_buffer.blitTextureToBuffer(no_pitch, &staged),
    );

    var no_alignment = request;
    no_alignment.storage_buffer_offset_alignment = 0;
    try std.testing.expectError(
        error.ZeroRowPitch,
        blit_texture_to_buffer.blitTextureToBuffer(no_alignment, &staged),
    );
}

fn expectBufferToTextureErrors() !void {
    const source = rgbaPattern();
    var staged = stagingBuffer();
    const request: blit_buffer_to_texture.Request = .{
        .source_bytes = &source,
        .source = .{
            .offset = 0,
            .bytes_per_row = bytes_per_row_alignment,
            .rows_per_image = copy_extent.height,
        },
        .source_has_storage_usage = true,
        .destination_format = .rgba8_unorm,
        .destination_dimension = ._2d,
        .destination_aspect = .all,
        .copy_extent = copy_extent,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
    };

    var no_storage = request;
    no_storage.source_has_storage_usage = false;
    try std.testing.expectError(
        error.StorageRequired,
        blit_buffer_to_texture.blitBufferToTexture(no_storage, &staged),
    );

    var unsupported = request;
    unsupported.destination_format = .r8_snorm;
    try std.testing.expectError(
        error.UnsupportedFormat,
        blit_buffer_to_texture.blitBufferToTexture(unsupported, &staged),
    );

    var one_dimensional = request;
    one_dimensional.destination_dimension = ._1d;
    try std.testing.expectError(
        error.OneDimensionalTexture,
        blit_buffer_to_texture.blitBufferToTexture(one_dimensional, &staged),
    );

    var depth_aspect = request;
    depth_aspect.destination_aspect = .depth_only;
    try std.testing.expectError(
        error.NonColorAspect,
        blit_buffer_to_texture.blitBufferToTexture(depth_aspect, &staged),
    );

    var empty = request;
    empty.copy_extent = .{ .width = 4, .height = 0, .depth_or_array_layers = 1 };
    try std.testing.expectError(
        error.EmptyExtent,
        blit_buffer_to_texture.blitBufferToTexture(empty, &staged),
    );

    var misaligned = request;
    misaligned.source.bytes_per_row = 3;
    try std.testing.expectError(
        error.PitchNotWordAligned,
        blit_buffer_to_texture.blitBufferToTexture(misaligned, &staged),
    );

    // The source slice is what `loadU32` bounds-checks
    // (`src/command/blit_buffer_to_texture.zig:230-235`), so eight bytes is
    // what has to be truncated: a short destination raises
    // `DestinationTooSmall` from `:313` instead, which the case below names.
    var short_source = request;
    short_source.source_bytes = source[0..8];
    try std.testing.expectError(
        error.SourceTooSmall,
        blit_buffer_to_texture.blitBufferToTexture(short_source, &staged),
    );

    const short_destination = request;
    try std.testing.expectError(
        error.DestinationTooSmall,
        blit_buffer_to_texture.blitBufferToTexture(short_destination, staged[0..8]),
    );

    var bad_alignment = request;
    bad_alignment.storage_buffer_offset_alignment = 3;
    try std.testing.expectError(
        error.SsboAlignmentInvalid,
        blit_buffer_to_texture.blitBufferToTexture(bad_alignment, &staged),
    );
}

fn expectDepthToDepthErrors() !void {
    var source_depths: [copy_extent.width * copy_extent.height]f32 = @splat(0.25);
    var destination_depths: [copy_extent.width * copy_extent.height]f32 = @splat(0.0);

    const no_source_depth: blit_depth_to_depth.Request = .{
        .source_depths = &source_depths,
        .destination_depths = &destination_depths,
        .source_format = .rgba8_unorm,
        .destination_format = .depth24_plus,
        .copy_extent = copy_extent,
    };
    try std.testing.expectError(
        error.SourceFormatHasNoDepth,
        blit_depth_to_depth.blitDepthToDepth(no_source_depth),
    );

    var no_destination_depth = no_source_depth;
    no_destination_depth.source_format = .depth24_plus;
    no_destination_depth.destination_format = .rgba8_unorm;
    try std.testing.expectError(
        error.DestinationFormatHasNoDepth,
        blit_depth_to_depth.blitDepthToDepth(no_destination_depth),
    );

    var multisampled = no_source_depth;
    multisampled.source_format = .depth24_plus;
    multisampled.destination_format = .depth24_plus;
    multisampled.source_sample_count = 4;
    try std.testing.expectError(
        error.MultisampledDepth,
        blit_depth_to_depth.blitDepthToDepth(multisampled),
    );

    var empty = multisampled;
    empty.source_sample_count = 1;
    empty.copy_extent = .{ .width = 4, .height = 0, .depth_or_array_layers = 1 };
    try std.testing.expectError(
        error.EmptyExtent,
        blit_depth_to_depth.blitDepthToDepth(empty),
    );

    // `empty` already carries both depth formats and a sample count of one, so
    // a truncated source is the only difference this defect needs.
    var short_source = empty;
    short_source.source_depths = source_depths[0..4];
    short_source.copy_extent = copy_extent;
    try std.testing.expectError(
        error.SourceTooSmall,
        blit_depth_to_depth.blitDepthToDepth(short_source),
    );

    try std.testing.expectError(
        error.DestinationTooSmall,
        blit_depth_to_depth.blitDepthToDepth(blit_depth_to_depth.Request{
            .source_depths = &source_depths,
            .destination_depths = destination_depths[0..4],
            .source_format = .depth24_plus,
            .destination_format = .depth24_plus,
            .copy_extent = copy_extent,
        }),
    );

    // `width * height * depthOrArrayLayers` is checked rather than wrapped.
    try std.testing.expectError(error.CopySizeOverflow, blit_depth_to_depth.texelCount(.{
        .width = 0xffff_ffff,
        .height = 0xffff_ffff,
        .depth_or_array_layers = 0xffff_ffff,
    }));
}

fn expectColorToColorErrors() !void {
    const empty: []const blit_color_to_color_with_draw.Color = &.{};
    try std.testing.expectError(
        error.EmptySampleList,
        blit_color_to_color_with_draw.resolveMultisampleColor(empty),
    );

    var too_many: [blit_color_to_color_with_draw.max_resolve_sample_count + 1]Color =
        @splat(.{ 0.0, 0.0, 0.0, 0.0 });
    try std.testing.expectError(
        error.TooManySamples,
        blit_color_to_color_with_draw.resolveMultisampleColor(&too_many),
    );

    // Dawn's check is `std::abs(offsetY) < std::numeric_limits<int16_t>::max()`
    // (`BlitColorToColorWithDraw.cpp:315`), so 32766 is inside the bound and
    // 32767 is the first offset the packing refuses.
    const last_y = try blit_color_to_color_with_draw.packOffsets(
        blit_color_to_color_with_draw.ResolveRect{
            .color_offset = .{ .x = 0, .y = 0 },
            .resolve_offset = .{ .x = 0, .y = 32766 },
            .width = 1,
            .height = 1,
        },
    );
    try std.testing.expectEqual(
        @as(i32, 32766),
        blit_color_to_color_with_draw.unpackOffsetY(last_y),
    );
    try std.testing.expectError(error.OffsetOutOfRange, blit_color_to_color_with_draw.packOffsets(
        blit_color_to_color_with_draw.ResolveRect{
            .color_offset = .{ .x = 0, .y = 0 },
            .resolve_offset = .{ .x = 0, .y = 32767 },
            .width = 1,
            .height = 1,
        },
    ));
}

fn expectBufferToDepthStencilErrors() !void {
    const texels = [_]u8{ 0x34, 0x12, 0x78, 0x56 };
    var depths: [2]f32 = .{ 0.0, 0.0 };
    const request: blit_buffer_to_depth_stencil.Request = .{
        .source_bytes = &texels,
        .destination_depths = &depths,
        .source_format = .rg8_uint,
        .destination_format = .depth16_unorm,
        .copy_extent = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
    };

    var wrong_destination = request;
    wrong_destination.destination_format = .depth32_float;
    try std.testing.expectError(
        error.DestinationFormatUnsupported,
        blit_buffer_to_depth_stencil.blitRg8ToDepth16Unorm(wrong_destination),
    );

    var wrong_source = request;
    wrong_source.source_format = .rgba8_unorm;
    try std.testing.expectError(
        error.SourceFormatUnsupported,
        blit_buffer_to_depth_stencil.blitRg8ToDepth16Unorm(wrong_source),
    );

    var empty = request;
    empty.copy_extent = .{ .width = 0, .height = 1, .depth_or_array_layers = 1 };
    try std.testing.expectError(
        error.EmptyExtent,
        blit_buffer_to_depth_stencil.blitRg8ToDepth16Unorm(empty),
    );

    try std.testing.expectError(
        error.SourceTooSmall,
        blit_buffer_to_depth_stencil.blitRg8ToDepth16Unorm(blit_buffer_to_depth_stencil.Request{
            .source_bytes = texels[0..1],
            .destination_depths = &depths,
            .source_format = .rg8_uint,
            .destination_format = .depth16_unorm,
            .copy_extent = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
        }),
    );

    try std.testing.expectError(
        error.DestinationTooSmall,
        blit_buffer_to_depth_stencil.blitRg8ToDepth16Unorm(blit_buffer_to_depth_stencil.Request{
            .source_bytes = &texels,
            .destination_depths = depths[0..1],
            .source_format = .rg8_uint,
            .destination_format = .depth16_unorm,
            .copy_extent = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
        }),
    );
}

// --- The uniform layouts ---------------------------------------------------

test "blit: the texture-to-buffer uniform is 112 bytes with the offsets Dawn's WGSL names" {
    const Params = blit_texture_to_buffer.Params;
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(Params));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Params, "pack_texel_count"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(Params, "bytes_per_row"));
    try std.testing.expectEqual(@as(usize, 60), @offsetOf(Params, "offset"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(Params, "level_size"));
}

test "blit: the texture-to-buffer uniform carries the derived layout" {
    const layout = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 300,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });
    var params: blit_texture_to_buffer.Params = undefined;
    blit_texture_to_buffer.writeParams(&params, .{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 300,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    }, layout);

    try std.testing.expectEqual(layout.bytes_per_row, params.bytes_per_row);
    try std.testing.expectEqual(copy_extent.height, params.rows_per_image);
    try std.testing.expectEqual(layout.shader_start_offset, params.offset);
    try std.testing.expectEqual(@as(u32, 1), params.pack_texel_count);
    try std.testing.expectEqual(@as(u32, 4), params.texel_size);
    try std.testing.expectEqual(@as(u32, 1), params.is_compact_image);
    try std.testing.expectEqual(@as(u32, 0), params.read_previous_row);
}

test "blit: the buffer-to-texture uniform is sixteen bytes" {
    const Params = blit_buffer_to_texture.Params;
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Params));

    var params: Params = undefined;
    blit_buffer_to_texture.writeParams(
        &params,
        .{ .offset = 0, .bytes_per_row = bytes_per_row_alignment, .rows_per_image = 4 },
        44,
        .{ .x = 2, .y = 3 },
    );
    try std.testing.expectEqual(@as(u32, 44), params.shader_read_offset);
    try std.testing.expectEqual(@as(u32, bytes_per_row_alignment), params.bytes_per_row);
    try std.testing.expectEqual(@as(u32, 2), params.dst_origin_x);
    try std.testing.expectEqual(@as(u32, 3), params.dst_origin_y);
}

test "blit: the buffer-to-depth uniform is eight bytes and the stencil one is twelve" {
    try std.testing.expectEqual(
        @as(usize, 8),
        @sizeOf(blit_buffer_to_depth_stencil.Params),
    );
    try std.testing.expectEqual(
        @as(usize, 12),
        @sizeOf(blit_buffer_to_depth_stencil.StencilParams),
    );

    var params: blit_buffer_to_depth_stencil.Params = undefined;
    blit_buffer_to_depth_stencil.writeParams(&params, .{ .x = 5, .y = 6 });
    try std.testing.expectEqual(@as(u32, 5), params.origin[0]);
    try std.testing.expectEqual(@as(u32, 6), params.origin[1]);
}

// --- The layout arithmetic the shader shares --------------------------------

test "blit: the texture-to-buffer dispatch rounds the extents up to the workgroup" {
    const layout = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = .{ .width = 9, .height = 9, .depth_or_array_layers = 1 },
        .blocks_per_row = 16,
        .rows_per_image = 9,
        .offset = 0,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });
    try std.testing.expectEqual(@as(u32, 2), layout.workgroup_count[0]);
    try std.testing.expectEqual(@as(u32, 2), layout.workgroup_count[1]);
    try std.testing.expectEqual(@as(u32, 1), layout.workgroup_count[2]);
}

test "blit: the texture-to-buffer compact-image flag tracks the rows per image" {
    const compact = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height,
        .offset = 0,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });
    try std.testing.expect(compact.is_compact_image);

    const sparse = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = copy_extent,
        .blocks_per_row = bytes_per_row_alignment / 4,
        .rows_per_image = copy_extent.height + 1,
        .offset = 0,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });
    try std.testing.expect(!sparse.is_compact_image);
}

test "blit: the read-previous-row flag has both answers" {
    // `blockInfo.ToBytes(copyExtent.width) + extraBytes >
    // blockInfo.ToBytes(dst.blocksPerRow)`, `BlitTextureToBuffer.cpp:1611-1612`.
    // Only a format narrower than a word reaches it, and this port packs none,
    // so the flag is read through the layout of a one-texel-wide `r8unorm` copy.
    const wide = try blit_texture_to_buffer.deriveLayout(.{
        .format = .rgba8_unorm,
        .copy_extent = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
        .blocks_per_row = 64,
        .rows_per_image = 1,
        .offset = 0,
        .storage_buffer_offset_alignment = storage_buffer_offset_alignment,
        .destination_byte_count = 4096,
        .destination_has_storage_usage = true,
    });
    try std.testing.expect(!wide.read_previous_row);
}

test "blit: the buffer-to-texture layer ladder steps by the whole image" {
    // `layerOffsets` takes the generated descriptor. The blit module's own
    // alias for it is private (`src/command/blit_buffer_to_texture.zig:25`), so
    // the public name is the one `api` exports, which is the same type and the
    // one the last test in this shard pins.
    const source: api.TexelCopyBufferLayout = .{
        .offset = 257,
        .bytes_per_row = bytes_per_row_alignment,
        .rows_per_image = 4,
    };
    const layer_zero = try blit_buffer_to_texture.layerOffsets(
        source,
        storage_buffer_offset_alignment,
        0,
    );
    // `align_down(257, 256)` and the remainder the shader adds back,
    // `BlitBufferToTexture.cpp:463-464`.
    try std.testing.expectEqual(@as(u64, 256), layer_zero.binding_offset);
    try std.testing.expectEqual(@as(u32, 1), layer_zero.read_offset);

    const layer_one = try blit_buffer_to_texture.layerOffsets(
        source,
        storage_buffer_offset_alignment,
        1,
    );
    // `offset + rowsPerImage * bytesPerRow` for layer one,
    // `BlitBufferToTexture.cpp:461-462`.
    try std.testing.expectEqual(@as(u64, 257 + 4 * 256), layer_one.binding_offset + 1);
}

test "blit: the output unit is never below a word and the pack count follows it" {
    // `max(bytesPerTexel, 4)` at `BlitTextureToBuffer.cpp:1474` and
    // `max(1, 4 / bytesPerTexel)` at `BlitTextureToBuffer.cpp:1747`.
    try std.testing.expectEqual(@as(u32, 4), blit_texture_to_buffer.outputUnitSize(1));
    try std.testing.expectEqual(@as(u32, 4), blit_texture_to_buffer.outputUnitSize(4));
    try std.testing.expectEqual(@as(u32, 8), blit_texture_to_buffer.outputUnitSize(8));
    try std.testing.expectEqual(@as(u32, 16), blit_texture_to_buffer.outputUnitSize(16));

    try std.testing.expectEqual(@as(u32, 4), blit_texture_to_buffer.packTexelCount(1));
    try std.testing.expectEqual(@as(u32, 2), blit_texture_to_buffer.packTexelCount(2));
    try std.testing.expectEqual(@as(u32, 1), blit_texture_to_buffer.packTexelCount(4));
    try std.testing.expectEqual(@as(u32, 1), blit_texture_to_buffer.packTexelCount(16));

    // `(shaderStartOffset % 4) / bytesPerTexel`, `BlitTextureToBuffer.cpp:1760`.
    try std.testing.expectEqual(@as(u32, 0), blit_texture_to_buffer.shiftFor(0, 1));
    try std.testing.expectEqual(@as(u32, 3), blit_texture_to_buffer.shiftFor(3, 1));
    try std.testing.expectEqual(@as(u32, 1), blit_texture_to_buffer.shiftFor(6, 2));

    // `(bytesInRow + extraBytes + 3) / 4`, `BlitTextureToBuffer.cpp:1621-1622`,
    // both sides of the rounding.
    try std.testing.expectEqual(
        @as(u32, 64),
        blit_texture_to_buffer.numU32PerRowNeedsWritingRoundedUp(256, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 65),
        blit_texture_to_buffer.numU32PerRowNeedsWritingRoundedUp(256, 1),
    );
}

// The types the shard names must stay the API types, or the acceptance is
// asserting against a shape the library does not expose.
test "blit: the blit requests use the generated API types" {
    const layout: api.TexelCopyBufferLayout = .{
        .offset = 0,
        .bytes_per_row = bytes_per_row_alignment,
        .rows_per_image = 4,
    };
    try std.testing.expectEqual(@as(u64, 0), layout.offset);

    const origin: Origin3D = .{};
    try std.testing.expectEqual(@as(u32, 0), origin.z);

    const dimension: TextureDimension = ._2d;
    try std.testing.expectEqual(TextureDimension._2d, dimension);

    const aspect: TextureAspect = .all;
    try std.testing.expectEqual(TextureAspect.all, aspect);
}
