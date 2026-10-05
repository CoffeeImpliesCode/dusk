//! The M11 shard: a texture, a view of it, and the linear texel copy.
//!
//! **What this shard asserts.** The three cases the milestone names. A 4x4
//! `rgba8unorm` texture is filled through `writeTexture` and every one of its
//! 64 bytes is asserted in the store the front end owns; the same texture is
//! then copied back out to a buffer at a 256-byte row pitch, with every pad byte
//! asserted untouched and the copy repeated at a second pitch; and a second view
//! whose `base_mip_level` is 1 is refused by name.
//!
//! **Why the pad bytes are the interesting half.** Dawn fixes the linear row
//! pitch at `src/dawn/common/Constants.h:44` and the port checks it at
//! `CommandValidation.cpp:426`, so a four-row copy of a sixteen-byte row touches
//! `pitch * 3 + 16` bytes and not the 64 the texels alone weigh. A copy that
//! filled the gap would still return the 64 right bytes, so the pad is the only
//! observable that separates an honest move from a short one.
//!
//! **Why the format is a parameter and not a table read.** `FormatInfo` is what
//! the format table of M7 hands over (`src/engine/texture.zig:99`), and a
//! texture cannot exist without one. The shard declares the four facts about
//! `rgba8unorm` it needs and passes them in, which is the shape the module asks
//! of its callers.
//!
//! **What this shard does not claim.** It does not claim a Vulkan image. The
//! front end holds no Vulkan (`AGENTS.md` §3), so the store below is the whole
//! texture as far as M11 is concerned; the image behind it is M18's. It claims
//! nothing about the sampler: the sampler rules have no reader in this
//! milestone, and a test that asserted them would be asserting presence.

const std = @import("std");
const dusk = @import("dusk");

const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const texture = dusk.engine.texture;

const FormatInfo = texture.FormatInfo;
const TexelCopyBufferLayout = texture.TexelCopyBufferLayout;
const TexelCopyTextureInfo = texture.TexelCopyTextureInfo;
const TexelCopyTextureLayout = texture.TexelCopyTextureLayout;
const TextureLimits = texture.TextureLimits;

/// The format every texture here is built in. A four-byte block over a 1 by 1
/// block grid makes one texel four bytes wide, which is what makes the row of a
/// 4-wide texture exactly 16 bytes and the whole level exactly 64
/// (`src/dawn/native/Format.cpp:461-462`, `:547`).
const rgba8unorm: FormatInfo = .{
    .format = .rgba8_unorm,
    .base_format = .rgba8_unorm,
    .block_byte_size = 4,
    .aspects = .{ .color = 1 },
};

/// The extent every texture here has: 4 by 4 by one layer.
const extent: api.Extent3D = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 };

/// The bytes one row of the store holds: four texels of four bytes each.
const row_byte_size: usize = extent.width * rgba8unorm.block_byte_size;

/// The bytes the whole level holds: four rows of sixteen. This is the 64 the
/// acceptance names.
const level_byte_size: usize = row_byte_size * extent.height;

/// The pitch Dawn fixes for a linear copy
/// (`src/dawn/common/Constants.h:44`, checked at `CommandValidation.cpp:426`).
/// A test states it as the number it passes, because the number is the rule.
const row_pitch: u32 = 256;

/// A second legal pitch, for the repeat that shows the copy honours the pitch the
/// caller names rather than the row the texture holds.
const wide_row_pitch: u32 = 512;

/// A pitch that is not a multiple of the fixed one, for the refusal that shows
/// why the two above are the shapes a caller can ask for.
const misaligned_row_pitch: u32 = 128;

/// The byte a linear side the copy must not touch starts as. Two values, one
/// per side, so a test that only filled one of them cannot pass.
const write_pad: u8 = 0xa5;
const read_pad: u8 = 0x5a;

/// One channel of one texel. Every channel carries a distinct value and red is
/// not blue, so a row that moved or a channel that transposed shows.
fn patternChannel(x: u32, y: u32, channel: usize) u8 {
    return switch (channel) {
        0 => @intCast(17 + x * 4 + y * 16),
        1 => @intCast(100 + x + y),
        2 => @intCast(200 + x),
        else => 255,
    };
}

/// The 64 bytes the acceptance copies.
const pattern: [level_byte_size]u8 = blk: {
    var bytes: [level_byte_size]u8 = undefined;
    var y: u32 = 0;
    while (y < extent.height) : (y += 1) {
        var x: u32 = 0;
        while (x < extent.width) : (x += 1) {
            const texel = (y * extent.width + x) * 4;
            var channel: usize = 0;
            while (channel < 4) : (channel += 1) {
                bytes[texel + channel] = patternChannel(x, y, channel);
            }
        }
    }
    break :blk bytes;
};

/// The bytes one copy at `pitch` touches, written out here so the size the
/// shard expects is not the size the library computes
/// (`ComputeRequiredBytesInCopy`, `CommandValidation.cpp:286-291`): every row but
/// the last contributes a whole stride and the last contributes the bytes it
/// holds.
fn expectedLinearByteCount(pitch: u32) usize {
    return @as(usize, pitch) * (extent.height - 1) + row_byte_size;
}

/// The linear side of a copy at `pitch`, sized by the library's own rule so a
/// disagreement with `expectedLinearByteCount` is a failure and not a surprise.
fn linearSide(allocator: std.mem.Allocator, pitch: u32, pad: u8) ![]u8 {
    const byte_count = texture.computeRequiredBytesInCopy(
        @intCast(row_byte_size),
        pitch,
        extent.height,
        extent.depth_or_array_layers,
    );
    const bytes = try allocator.alloc(u8, @intCast(byte_count));
    @memset(bytes, pad);
    return bytes;
}

/// Lays the pattern into a linear side at `pitch`, so a write starts from a
/// buffer that already holds a byte at every pad position.
fn fillLinearSide(bytes: []u8, pitch: u32) void {
    const pitch_bytes: usize = pitch;
    var y: usize = 0;
    while (y < extent.height) : (y += 1) {
        @memcpy(
            bytes[y * pitch_bytes ..][0..row_byte_size],
            pattern[y * row_byte_size ..][0..row_byte_size],
        );
    }
}

/// Builds the side a copy at `pitch` must leave behind: the pattern in the
/// row bytes and `pad` in the gap. The byte index `expectEqualSlices` reports
/// is the offset in the linear side, so `index / pitch` is the row and
/// `index % pitch` the column, which is what the per-byte loop used to print.
fn expectedLinearSide(gpa: std.mem.Allocator, pitch: u32, pad: u8) ![]u8 {
    const bytes = try gpa.alloc(u8, expectedLinearByteCount(pitch));
    @memset(bytes, pad);
    fillLinearSide(bytes, pitch);
    return bytes;
}

/// Asserts that `bytes` holds the pattern one row per `pitch` and that every
/// other byte is still `pad`. Both halves are checked byte by byte: a move that
/// copies the 64 texels and fills the gap passes the first half alone.
fn expectLinearSide(gpa: std.mem.Allocator, bytes: []const u8, pitch: u32, pad: u8) !void {
    const expected = try expectedLinearSide(gpa, pitch, pad);
    defer gpa.free(expected);

    try std.testing.expectEqual(expected.len, bytes.len);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

/// The copy both legs use: the whole level, from its own origin, on the color
/// aspect.
const copy_whole_level: TexelCopyTextureInfo = .{
    .mip_level = 0,
    .origin = .{},
    .aspect = .all,
};

/// The whole level as a texture-side extent.
fn wholeLevelLayout() TexelCopyTextureLayout {
    return .{ .offset = .{}, .size = extent };
}

/// The linear side both legs use at `pitch`, with the offset at the head of the
/// buffer.
fn linearLayout(pitch: u32) TexelCopyBufferLayout {
    return .{ .offset = 0, .bytes_per_row = pitch, .rows_per_image = extent.height };
}

/// Whether two allocators are the same allocator.
///
/// `mem.Allocator` is a `{ ptr, vtable }` pair of opaque pointers and has no
/// `==` in 0.16, so identity is the pair. Both halves are read: `.ptr` alone
/// would let a different allocator that wraps the same context pass.
fn sameAllocator(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

/// Counts the errors that no scope took. Every test here ends with a zero count,
/// so a rule that reported something and swallowed it is a failure.
const ErrorRecorder = struct {
    count: u64 = 0,

    fn record(
        allocator: std.mem.Allocator,
        context: *anyopaque,
        data: *const core.ErrorData,
    ) void {
        const self: *ErrorRecorder = @ptrCast(@alignCast(context));
        self.count += 1;
        std.debug.assert(sameAllocator(allocator, std.testing.allocator));
        std.debug.assert(data.message.len > 0);
    }
};

/// The handle the view rules are handed. The object is not the handle; the
/// handle is the one word the arena gave it.
fn handleOf(tex: *texture.Texture) api.objects.Texture {
    return .{ .handle = @ptrCast(tex) };
}

/// A null device to hang the textures off. The null back end is the one M8
/// builds and it needs no driver (`DeviceNull.cpp:152-153`), which is what lets
/// the texture rules be tested with no GPU at all.
const Fixture = struct {
    /// On the heap because every adapter and every device holds a pointer into
    /// it. An instance by value would leave those pointers aimed at a stack slot
    /// this struct does not own.
    instance: *engine.Instance,
    /// On the heap for the same reason: the device keeps the pointer as its
    /// error sink, so a copy on the stack would be a dangling context.
    recorder: *ErrorRecorder,
    adapters: engine.AdapterList,
    device: engine.Device,

    fn init() !Fixture {
        const instance = try std.testing.allocator.create(engine.Instance);
        errdefer std.testing.allocator.destroy(instance);
        instance.* = engine.Instance.init(.{});

        var adapters = try instance.enumerateAdapters(
            std.testing.allocator,
            .{
                .feature_level = .core,
                .power_preference = .undefined_,
                .backend_type = .null_,
            },
        );
        errdefer adapters.deinit();
        if (adapters.items.len != 1) return error.NullAdapterCountChanged;

        const recorder = try std.testing.allocator.create(ErrorRecorder);
        errdefer std.testing.allocator.destroy(recorder);
        recorder.* = .{};

        const adapter = &adapters.items[0];
        const device = try adapter.createDevice(std.testing.allocator, .{
            .adapter = adapter,
            .required_features = &.{},
            .feature_level = adapter.getFeatureLevel(),
            .uncaptured_context = @ptrCast(recorder),
            .uncaptured_callback = ErrorRecorder.record,
        });
        return .{
            .instance = instance,
            .recorder = recorder,
            .adapters = adapters,
            .device = device,
        };
    }

    fn deinit(self: *Fixture) void {
        // The device drops its instance registration first (`Device.cpp:493`),
        // then the adapters go, then the two blocks behind the pointers the
        // device still holds.
        self.device.deinit(std.testing.allocator);
        self.adapters.deinit();
        std.testing.allocator.destroy(self.recorder);
        std.testing.allocator.destroy(self.instance);
        self.* = undefined;
    }

    /// The arena every handle above `engine` names. `Texture.create` takes it
    /// rather than the device, which is the seam `DeviceBase*` becomes
    /// (`src/engine/device.zig:277-279`).
    fn coreDevice(self: *Fixture) *core.Device {
        return self.device.coreDevice();
    }

    /// The four limits a texture descriptor can be above. They are read from the
    /// device rather than written here, so a texture in this shard is checked
    /// against the same table the device reports.
    fn textureLimits(self: *const Fixture) TextureLimits {
        const v1 = self.device.getLimits().v1;
        return .{
            .max_texture_dimension_1d = v1.max_texture_dimension_1d,
            .max_texture_dimension_2d = v1.max_texture_dimension_2d,
            .max_texture_dimension_3d = v1.max_texture_dimension_3d,
            .max_texture_array_layers = v1.max_texture_array_layers,
        };
    }

    /// A 4x4 `rgba8unorm` texture, one level, one layer, one sample, with the
    /// usages the caller names.
    fn createTextureWithUsage(self: *Fixture, usage: api.TextureUsage) !*texture.Texture {
        const created = try texture.Texture.create(self.coreDevice(), .{
            .descriptor = .{
                .usage = usage,
                .dimension = ._2d,
                .size = extent,
                .format = .rgba8_unorm,
                .mip_level_count = 1,
                .sample_count = 1,
            },
            .format_info = &rgba8unorm,
            .limits = self.textureLimits(),
        });
        return texture.resolveTexture(self.coreDevice(), created);
    }

    fn createTexture(self: *Fixture) !*texture.Texture {
        return self.createTextureWithUsage(.{ .copy_src = true, .copy_dst = true });
    }

    /// A view named by the descriptor the caller gives, over the same format.
    /// `format` and `dimension` are the two members the chain does not default
    /// (`dawn.json:4529-4530`).
    fn createView(
        self: *Fixture,
        parent: api.objects.Texture,
        descriptor: api.descriptors.TextureViewDescriptorChain,
    ) !*texture.TextureView {
        const created = try texture.Texture.createView(self.coreDevice(), parent, .{
            .descriptor = descriptor,
            .format_info = &rgba8unorm,
        });
        return texture.resolveTextureView(self.coreDevice(), created);
    }

    fn createWholeView(self: *Fixture, parent: api.objects.Texture) !*texture.TextureView {
        return self.createView(parent, .{ .format = .rgba8_unorm, .dimension = ._2d });
    }
};

// ---------------------------------------------------------------------------
// Case one: a write lands all 64 bytes.
// ---------------------------------------------------------------------------

test "a 4x4 rgba8unorm texture holds every texel a linear write delivered" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const tex = try fixture.createTexture();

    // The shape the creation rules resolved, read back before anything is
    // written. A texture that reported a different extent would make the byte
    // assertions below pass or fail for the wrong reason.
    try std.testing.expectEqual(api.TextureDimension._2d, tex.getDimension());
    try std.testing.expectEqual(api.TextureFormat.rgba8_unorm, tex.getFormat());
    try std.testing.expectEqual(extent, tex.getBaseSize());
    try std.testing.expectEqual(extent.width, tex.getWidth());
    try std.testing.expectEqual(extent.height, tex.getHeight());
    try std.testing.expectEqual(@as(u32, 1), tex.getArrayLayers());
    try std.testing.expectEqual(@as(u32, 1), tex.getNumMipLevels());
    try std.testing.expectEqual(@as(u32, 1), tex.getSampleCount());
    try std.testing.expectEqual(@as(usize, 1), tex.subresourceCount());
    try std.testing.expect(!tex.isMultisampledTexture());
    try std.testing.expect(!tex.isSubresourceContentInitialized(tex.getAllSubresources()));

    // One subresource, because one level times one layer times one aspect.
    const all_subresources = tex.getAllSubresources();
    try std.testing.expectEqual(@as(u32, 0), all_subresources.base_mip_level);
    try std.testing.expectEqual(@as(u32, 1), all_subresources.level_count);
    try std.testing.expectEqual(@as(u32, 0), all_subresources.base_array_layer);
    try std.testing.expectEqual(@as(u32, 1), all_subresources.layer_count);
    try std.testing.expectEqual(@as(usize, 0), tex.aspectIndex(.color));
    try std.testing.expectEqual(extent, tex.getMipLevelSubresourcePhysicalSize(0));
    try std.testing.expectEqual(row_byte_size, tex.levelRowByteSize(0));
    try std.testing.expectEqual(@as(usize, extent.height), tex.levelRowCount(0));
    try std.testing.expectEqual(level_byte_size, tex.imageByteSize(0));
    try std.testing.expectEqual(@as(usize, 0), tex.subresourceByteOffset(0, 0, .color));

    // The write: the whole level at the fixed pitch. The linear side is
    // `256 * 3 + 16` bytes, so every row carries 240 pad bytes the copy must
    // step over.
    const source = try linearSide(std.testing.allocator, row_pitch, write_pad);
    defer std.testing.allocator.free(source);
    fillLinearSide(source, row_pitch);

    try tex.writeTexture(copy_whole_level, wholeLevelLayout(), linearLayout(row_pitch), source);

    // The 64 bytes, in the store, one by one. A write that dropped the 64 at
    // the head of the store instead of four rows of sixteen fails at row one.
    try std.testing.expectEqual(level_byte_size, tex.bytes.len);
    var index: usize = 0;
    while (index < level_byte_size) : (index += 1) {
        if (tex.bytes[index] != pattern[index]) {
            std.debug.print("store byte {d}\n", .{index});
            return error.StoreByteWrong;
        }
    }

    // The rule the write claims to have satisfied, read back.
    try std.testing.expect(tex.isSubresourceContentInitialized(tex.getAllSubresources()));
    try std.testing.expectEqual(@as(usize, 1), tex.initialized.len);

    // A texture without the destination usage refuses the write, and one
    // without the source usage refuses the read. Both refusals come before any
    // of the layout rules, so neither needs a legal pitch to reach.
    const read_only = try fixture.createTextureWithUsage(.{ .copy_src = true });
    try std.testing.expectError(
        error.TextureUsageMissingCopyDst,
        read_only.writeTexture(
            copy_whole_level,
            wholeLevelLayout(),
            linearLayout(row_pitch),
            source,
        ),
    );

    const write_only = try fixture.createTextureWithUsage(.{ .copy_dst = true });
    const unreadable = try linearSide(std.testing.allocator, row_pitch, read_pad);
    defer std.testing.allocator.free(unreadable);
    try std.testing.expectError(
        error.TextureUsageMissingCopySrc,
        write_only.copyTextureToBuffer(
            copy_whole_level,
            wholeLevelLayout(),
            linearLayout(row_pitch),
            unreadable,
        ),
    );

    try std.testing.expectEqual(@as(u64, 0), fixture.recorder.count);
}

// ---------------------------------------------------------------------------
// Case two: the copy back out, at the fixed pitch and at another.
// ---------------------------------------------------------------------------

test "a texture copied to a buffer returns all 64 texels at a 256-byte row pitch" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const tex = try fixture.createTexture();

    // The size the rule computes, asserted before the copy so a failure names
    // the arithmetic and not the bytes. 784 is `256 * 3 + 16`; 64 is what the
    // texels alone weigh, and the difference is the pad the copy must skip.
    try std.testing.expectEqual(@as(usize, 784), expectedLinearByteCount(row_pitch));
    try std.testing.expectEqual(@as(usize, 1552), expectedLinearByteCount(wide_row_pitch));
    const tight_bytes = texture.computeRequiredBytesInCopy(
        @intCast(row_byte_size),
        @intCast(row_byte_size),
        extent.height,
        extent.depth_or_array_layers,
    );
    try std.testing.expectEqual(level_byte_size, @as(usize, @intCast(tight_bytes)));

    const source = try linearSide(std.testing.allocator, row_pitch, write_pad);
    defer std.testing.allocator.free(source);
    fillLinearSide(source, row_pitch);
    try tex.writeTexture(copy_whole_level, wholeLevelLayout(), linearLayout(row_pitch), source);

    // The read side starts full of a byte the copy must not write, so a copy
    // that returns fewer bytes than it must is visible.
    const destination = try linearSide(std.testing.allocator, row_pitch, read_pad);
    defer std.testing.allocator.free(destination);
    try std.testing.expectEqual(read_pad, destination[0]);
    const last_index = expectedLinearByteCount(row_pitch) - 1;
    try std.testing.expectEqual(read_pad, destination[last_index]);

    try tex.copyTextureToBuffer(
        copy_whole_level,
        wholeLevelLayout(),
        linearLayout(row_pitch),
        destination,
    );

    // Every one of the 64 texels, at the head of its own row, and every one of
    // the 720 pad bytes still holding the byte it started with.
    try expectLinearSide(std.testing.allocator, destination, row_pitch, read_pad);

    // The repeat: the same texture and the same 64 texels at a second legal
    // pitch. A copy that derived the pitch from the row instead of taking the
    // caller's would land the texels sixteen bytes apart and fail here.
    const wide_destination = try linearSide(std.testing.allocator, wide_row_pitch, read_pad);
    defer std.testing.allocator.free(wide_destination);
    try tex.copyTextureToBuffer(
        copy_whole_level,
        wholeLevelLayout(),
        linearLayout(wide_row_pitch),
        wide_destination,
    );
    try expectLinearSide(std.testing.allocator, wide_destination, wide_row_pitch, read_pad);

    // And a pitch that is not a multiple of the fixed one is refused by name,
    // which is the rule that leaves the two pitches above as the shapes a caller
    // can ask for.
    const misaligned = try linearSide(std.testing.allocator, row_pitch, read_pad);
    defer std.testing.allocator.free(misaligned);
    try std.testing.expectError(
        error.CopyBytesPerRowNotAligned,
        tex.copyTextureToBuffer(
            copy_whole_level,
            wholeLevelLayout(),
            linearLayout(misaligned_row_pitch),
            misaligned,
        ),
    );

    try std.testing.expectEqual(@as(u64, 0), fixture.recorder.count);
}

// ---------------------------------------------------------------------------
// Case three: a view that names a level the texture does not have.
// ---------------------------------------------------------------------------

test "a second view whose base mip level is 1 is rejected" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const tex = try fixture.createTexture();
    const parent = handleOf(tex);

    // The first view names level 0 and is accepted, so the rejection below is
    // about the base level and not about the descriptor as a whole.
    const view = try fixture.createWholeView(parent);
    try std.testing.expectEqual(@as(u32, 0), view.getBaseMipLevel());
    try std.testing.expectEqual(@as(u32, 1), view.getLevelCount());
    try std.testing.expectEqual(@as(u32, 0), view.getBaseArrayLayer());
    try std.testing.expectEqual(@as(u32, 1), view.getLayerCount());
    try std.testing.expectEqual(api.TextureFormat.rgba8_unorm, view.getFormat());
    try std.testing.expectEqual(api.TextureViewDimension._2d, view.getDimension());
    try std.testing.expect(tex == view.getTexture());
    try std.testing.expect(view.isSwizzleIdentity());
    try std.testing.expectEqual(@as(u1, 1), view.getAspects().color);
    try std.testing.expectEqual(@as(u1, 0), view.getAspects().depth);
    try std.testing.expect(tex.getUsage().has(view.getUsage()));
    try std.testing.expectEqual(view.getUsage().toFlags(), view.getInternalUsage().toFlags());

    // A one-level texture has no level 1. The descriptor that says so with a
    // count of one is refused by the mip-range rule, which compares
    // `baseMipLevel + mipLevelCount` with the level count (`Texture.cpp:969`).
    try std.testing.expectError(
        error.TextureViewMipRangeExceeds,
        fixture.createView(parent, .{
            .format = .rgba8_unorm,
            .dimension = ._2d,
            .base_mip_level = 1,
            .mip_level_count = 1,
        }),
    );

    // The same descriptor with the count left at its sentinel resolves to
    // `1 - 1 = 0` levels, and a view of no levels is refused by the rule above
    // the mip range. The two names are the two halves of one rejection, and the
    // shard asserts both so a port that moved either rule is caught.
    try std.testing.expectError(
        error.TextureViewLayerCountZero,
        fixture.createView(parent, .{
            .format = .rgba8_unorm,
            .dimension = ._2d,
            .base_mip_level = 1,
        }),
    );

    // A view that names level 0 with an explicit count of one is accepted, so
    // the rule above is about the base level and not about the count.
    const named = try fixture.createView(parent, .{
        .format = .rgba8_unorm,
        .dimension = ._2d,
        .base_mip_level = 0,
        .mip_level_count = 1,
    });
    try std.testing.expectEqual(@as(u32, 0), named.getBaseMipLevel());
    try std.testing.expectEqual(@as(u32, 1), named.getLevelCount());

    try std.testing.expectEqual(@as(u64, 0), fixture.recorder.count);
}
