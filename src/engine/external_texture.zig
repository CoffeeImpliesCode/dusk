// Copyright 2021 The Dawn & Tint Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

//! Owns external-texture planes and pinned shader metadata in the original device arena.
//! Creation records no GPU commands. Preparation uses the caller's recording and PendingUses.
//! Copying a pointer does not acquire a user alias. Release owned aliases under the original guard.
//! This module neither imports Android memory nor rewrites caller shader words.

const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const texture = @import("texture.zig");
const sampler = @import("sampler.zig");
const resources = @import("native_resources.zig");
const kernels = @import("native_kernels.zig");
const features = @import("features.zig");
const limits = @import("limits.zig");
const vk = @import("vulkan");

test "external metadata preserves pinned offsets and zero padding" {
    const bytes = try encodeMetadata(.{
        .plane_sizes = .{ .{ .width = 8, .height = 4 }, .{ .width = 4, .height = 2 } },
        .plane_count = 2,
        .crop_origin = .{ .x = 2, .y = 1 },
        .crop_size = .{ .width = 4, .height = 2 },
        .apparent_size = .{ .width = 4, .height = 2 },
        .yuv_matrix = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
        .gamut_matrix = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .src_transfer = .{ -1, 1, 2, 3, 4, 5, 6 },
        .dst_transfer = .{ 1, 1, 0, 1, 0, 0, 0 },
    });
    try std.testing.expectEqual(@as(u32, 2), word(&bytes, 0));
    try std.testing.expectEqual(@as(u32, 1), word(&bytes, 64));
    try std.testing.expectEqual(@as(f32, -1), floatWord(&bytes, 92));
    try std.testing.expectEqual(@as(f32, 12), floatWord(&bytes, 60));
    try std.testing.expectEqual(@as(f32, 4), floatWord(&bytes, 144));
    try std.testing.expectEqual(@as(f32, 9), floatWord(&bytes, 168));
    for ([_]usize{ 8, 12, 140, 156, 172 }) |offset| {
        try std.testing.expectEqual(@as(u32, 0), word(&bytes, offset));
    }
    try std.testing.expectEqual(@as(f32, 0.3125), floatWord(&bytes, 224));
    try std.testing.expectEqual(@as(f32, 0.375), floatWord(&bytes, 240));
    try std.testing.expectEqual(@as(f32, 0.5), floatWord(&bytes, 264));
    try std.testing.expectEqual(@as(f32, 0.2), floatWord(&bytes, 284));
}

test "external inverse mirror precedes inverse rotation and swaps apparent bounds" {
    const bytes = try encodeMetadata(.{
        .plane_sizes = .{ .{ .width = 8, .height = 4 }, .{ .width = 1, .height = 1 } },
        .plane_count = 1,
        .crop_origin = .{ .x = 2, .y = 1 },
        .crop_size = .{ .width = 4, .height = 2 },
        .apparent_size = .{ .width = 4, .height = 2 },
        .mirrored = true,
        .rotation = .rotate_90_degrees,
    });
    try std.testing.expectEqual(@as(u32, 1), word(&bytes, 256));
    try std.testing.expectEqual(@as(u32, 3), word(&bytes, 260));
    try std.testing.expectEqual(@as(f32, 0), floatWord(&bytes, 176));
    try std.testing.expectEqual(@as(f32, 0.5), floatWord(&bytes, 180));
    try std.testing.expectEqual(@as(f32, 0.5), floatWord(&bytes, 184));
    try std.testing.expectEqual(@as(f32, 0), floatWord(&bytes, 188));
    try std.testing.expectEqual(@as(f32, 0.25), floatWord(&bytes, 192));
    try std.testing.expectEqual(@as(f32, 0.25), floatWord(&bytes, 196));
}

test "external metadata rejects unknown transfer sentinel instead of approximating gamma" {
    var input: MetadataInput = .{
        .plane_sizes = .{ .{ .width = 1, .height = 1 }, .{ .width = 1, .height = 1 } },
        .plane_count = 1,
        .crop_origin = .{},
        .crop_size = .{ .width = 1, .height = 1 },
        .apparent_size = .{ .width = 1, .height = 1 },
    };
    input.src_transfer[0] = -3;
    try std.testing.expectError(error.ExternalTextureInvalidMetadata, encodeMetadata(input));
    input.src_transfer[0] = -1.5;
    try std.testing.expectError(error.ExternalTextureInvalidMetadata, encodeMetadata(input));
    input.src_transfer[0] = 1;
    input.dst_transfer[0] = -2;
    try std.testing.expectError(error.ExternalTextureInvalidMetadata, encodeMetadata(input));
}

test "identity hardware metadata maps actual Cr Y Cb sample through pinned three-cycle matrix" {
    var input: MetadataInput = .{
        .plane_sizes = .{ .{ .width = 2, .height = 2 }, .{ .width = 1, .height = 1 } },
        .plane_count = 1,
        .crop_origin = .{},
        .crop_size = .{ .width = 2, .height = 2 },
        .apparent_size = .{ .width = 2, .height = 2 },
        .identity_ycbcr = true,
        .yuv_matrix = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    };
    const bytes = try encodeMetadata(input);
    // Pinned U*yMat, not the contradictory component-order comment in Dawn.
    const expected_weights = [_]f32{ 3, 1, 2, 4, 7, 5, 6, 8, 11, 9, 10, 12 };
    for (expected_weights, 0..) |weight, index| {
        try std.testing.expectEqual(weight, floatWord(&bytes, 16 + index * 4));
    }
    // Vulkan YCbCr identity samples expose Cr,Y,Cb after range expansion.
    const sampled = [_]f32{ 0.25, 0.7, -0.125, 1 };
    const expected_rgb = [_]f32{ 5.2, 12.5, 19.8 };
    for (expected_rgb, 0..) |expected, column| {
        var actual: f32 = 0;
        for (sampled, 0..) |component, row| {
            actual += component * floatWord(&bytes, 16 + column * 16 + row * 4);
        }
        try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
    }
    input.src_transfer[3] = std.math.inf(f32);
    try std.testing.expectError(error.ExternalTextureInvalidMetadata, encodeMetadata(input));
}

test "browser parameters keep both nonlinear color transforms separate" {
    const bytes = try encodeBrowser(.{
        .source_size = .{ .width = 8, .height = 4 },
        .source_origin = .{ .x = 2, .y = 1 },
        .copy_size = .{ .width = 4, .height = 2 },
        .options = .{
            .flip_y = true,
            .needs_color_space_conversion = true,
            .src_alpha_mode = .premultiplied,
            .dst_alpha_mode = .unpremultiplied,
            .src_transfer_function_parameters = .{ 2, 1, 0, 1, 0.5, 0, 0 },
            .dst_transfer_function_parameters = .{ 0.5, 1, 0, 1, 0.5, 0, 0 },
            .conversion_matrix = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        },
    });
    try std.testing.expectEqual(@as(f32, 2), readBrowserFloat(&bytes, 0));
    try std.testing.expectEqual(@as(f32, 8), readBrowserFloat(&bytes, 16));
    try std.testing.expectEqual(@as(u32, 1), readBrowserWord(&bytes, 24));
    try std.testing.expectEqual(@as(u32, 2), readBrowserWord(&bytes, 32));
    try std.testing.expectEqual(@as(f32, 2), readBrowserFloat(&bytes, 48));
    try std.testing.expectEqual(@as(f32, 0.5), readBrowserFloat(&bytes, 80));
    try std.testing.expectEqual(@as(f32, 4), readBrowserFloat(&bytes, 128));
    for ([_]usize{ 40, 44, 76, 108, 124, 140, 156 }) |offset| {
        try std.testing.expectEqual(@as(u32, 0), readBrowserWord(&bytes, offset));
    }
}

test "browser external geometry rejects overflow without clamping the requested region" {
    var input: BrowserInput = .{
        .source_size = .{ .width = 4, .height = 4 },
        .source_origin = .{},
        .copy_size = .{ .width = 4, .height = 4 },
        .options = .{},
    };
    input.source_origin.x = std.math.maxInt(u32);
    try std.testing.expectError(error.ExternalTextureInvalidBrowserCopy, encodeBrowser(input));
    input.source_origin.x = 0;
    input.copy_size.width = 5;
    try std.testing.expectError(error.ExternalTextureInvalidBrowserCopy, encodeBrowser(input));
    input.copy_size.width = 0;
    const empty = try encodeBrowser(input);
    try std.testing.expectEqual(@as(f32, 0), readBrowserFloat(&empty, 8));
}

pub const parameter_size = 288;
pub const ValidationError = error{
    ExternalTextureExpired,
    ExternalTextureDestroyed,
    ExternalTextureInvalidPlane,
    ExternalTextureInvalidMetadata,
    ExternalTextureInvalidCrop,
    ExternalTextureInvalidApparentSize,
    ExternalTextureConversionMismatch,
    ExternalTextureFormatUnsupported,
    ExternalTextureExternalMemoryUnavailable,
    ExternalTextureInvalidBrowserCopy,
};
pub const ResourceError = resources.Error || texture.NativeError ||
    @import("../command/browser_copy.zig").Error || ValidationError;
pub const Error = ResourceError || kernels.Error;

/// Borrowed creation inputs. Coordinates and extents are in source-plane texels.
/// Creation copies all coefficients. The high Device supplies its actual features and limits.
pub const Options = struct {
    label: []const u8 = "",
    plane_0: *texture.TextureView,
    /// Null selects one RGBA plane, or the genuine combined hardware conversion path.
    plane_1: ?*texture.TextureView = null,
    crop_origin: api.descriptors.Origin2D,
    crop_size: api.descriptors.Extent2D,
    apparent_size: api.descriptors.Extent2D,
    do_yuv_to_rgb_conversion_only: bool = false,
    /// Null selects identity. Two ordinary Y+UV planes require exactly twelve values.
    yuv_to_rgb_conversion_matrix: ?[]const f32 = null,
    /// Required seven values in G,A,B,C,D,E,F order. Source G=-1 selects HLG and G=-2 selects PQ.
    src_transfer_function_parameters: ?[]const f32 = null,
    /// Required seven gamma values in G,A,B,C,D,E,F order. Negative mode sentinels are invalid.
    dst_transfer_function_parameters: ?[]const f32 = null,
    /// Required nine column-major values. Metadata pads each vec3 column to sixteen bytes.
    gamut_conversion_matrix: ?[]const f32 = null,
    mirrored: bool = false,
    rotation: api.ExternalTextureRotation = .rotate_0_degrees,
    /// Null selects ordinary sampled planes. Otherwise this is the view's actual conversion owner.
    conversion_sampler: ?*sampler.Sampler = null,
    enabled_features: *const features.FeaturesSet,
    limits: *const limits.CombinedLimits,
};

/// Owns immutable source views and metadata. Accepted batches own independent child roots.
/// Payload fields are not caller-mutable. Plane entries each own one lease, including duplicates.
/// Arena storage and native dependencies remain borrowed from the original device until final release.
pub const ExternalTexture = struct {
    header: core.Object,
    state: enum { active, expired, destroyed },
    planes: [2]*texture.TextureView,
    plane_count: u32,
    params: [parameter_size]u8,
    params_buffer: *resources.Buffer,
    conversion_sampler: ?*sampler.Sampler,

    /// Checks active state and live same-device dependencies without acquiring roots or recording work.
    pub fn validateSubmitLocked(self: *const ExternalTexture, guard: *const core.ObjectGuard) ResourceError!void {
        if (self.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.header.tracking);
        if (self.state == .destroyed) return error.ExternalTextureDestroyed;
        try checkHeader(guard, &self.header, .external_texture);
        switch (self.state) {
            .active => {},
            .expired => return error.ExternalTextureExpired,
            .destroyed => return error.ExternalTextureDestroyed,
        }
        for (self.planes) |plane| {
            try checkHeader(guard, &plane.header, .texture_view);
            try checkHeader(guard, &plane.texture.header, .texture);
            if (plane.native_view == null) return error.TextureNativeNotInitialized;
        }
        try checkHeader(guard, &self.params_buffer.header, .native_buffer);
        switch (self.params_buffer.native.state) {
            .unmapped => {},
            .in_use => return error.BufferUseWhileInUse,
            .mapped, .mapped_at_creation => return error.BufferUseWhileMapped,
            .pending_map => return error.BufferUseWhilePendingMap,
            .shared_memory_no_access => return error.BufferUseWithoutSharedMemoryAccess,
            .destroyed => return error.BufferUseWhileDestroyed,
        }
        if (self.conversion_sampler) |conversion| {
            try checkHeader(guard, &conversion.header, .sampler);
            const native = conversion.native orelse return error.ExternalTextureConversionMismatch;
            if (native.conversion == null or native.sampler == null) return error.ExternalTextureConversionMismatch;
        }
    }

    /// Borrows this exact header for native admission. The source owner must survive admission.
    pub fn ref(self: *ExternalTexture, guard: *const core.ObjectGuard) ResourceError!@import("../command/commands.zig").Ref {
        try self.validateSubmitLocked(guard);
        return &self.header;
    }

    /// Changes active to expired. Existing accepted batches keep their independent child roots.
    pub fn expireLocked(self: *ExternalTexture, guard: *const core.ObjectGuard) ResourceError!void {
        if (self.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.header.tracking);
        if (self.state == .destroyed) return error.ExternalTextureDestroyed;
        try checkHeader(guard, &self.header, .external_texture);
        if (self.state == .expired) return error.ExternalTextureExpired;
        self.state = .expired;
    }

    /// Reactivates active or expired metadata. Destroyed objects remain terminal.
    pub fn refreshLocked(self: *ExternalTexture, guard: *const core.ObjectGuard) ResourceError!void {
        if (self.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.header.tracking);
        if (self.state == .destroyed) return error.ExternalTextureDestroyed;
        try checkHeader(guard, &self.header, .external_texture);
        self.state = .active;
    }

    /// Core retirement callback only. Releases each owned edge once under the original guard.
    pub fn destroy(self: *ExternalTexture, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        std.debug.assert(self.state != .destroyed);
        self.state = .destroyed;
        // The duplicate one-plane edge is a second real lease, not a placeholder.
        for (self.planes) |plane| plane.header.releaseLeaseLocked(guard, io);
        self.params_buffer.header.releaseLeaseLocked(guard, io);
        if (self.conversion_sampler) |conversion| conversion.header.releaseLeaseLocked(guard, io);
    }
};

/// Returns one user alias after complete descriptor validation. Failure publishes no partial owner.
/// The metadata buffer is uninitialized. No queue commands or hidden Io escape creation.
pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: resources.NativeDevice,
    options: Options,
) ResourceError!*ExternalTexture {
    try arena.checkAllocator(guard, allocator);
    if (arena.objectList().marked_destroyed) return error.ResourceDestroyed;
    const metadata = try validateDescriptor(guard, options);
    const encoded = try encodeMetadata(metadata);
    const self = try arena.create(allocator, guard, ExternalTexture, .{
        .kind = .external_texture,
        .initial_reference = .user,
        .label = options.label,
    });
    errdefer self.header.discardUnpublishedLocked(guard) catch unreachable;
    const planes = [2]*texture.TextureView{ options.plane_0, options.plane_1 orelse options.plane_0 };
    try planes[0].header.retainLeaseLocked(guard);
    errdefer planes[0].header.releaseLeaseLocked(guard, io);
    try planes[1].header.retainLeaseLocked(guard);
    errdefer planes[1].header.releaseLeaseLocked(guard, io);
    if (options.conversion_sampler) |conversion| try conversion.header.retainLeaseLocked(guard);
    errdefer if (options.conversion_sampler) |conversion| conversion.header.releaseLeaseLocked(guard, io);
    const params_buffer = try resources.createBuffer(allocator, io, guard, arena, device, .{
        .size = parameter_size,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    errdefer params_buffer.header.releaseUserLocked(guard, io) catch unreachable;
    try params_buffer.header.retainLeaseLocked(guard);
    params_buffer.header.releaseUserLocked(guard, io) catch unreachable;
    self.state = .active;
    self.planes = planes;
    self.plane_count = metadata.plane_count;
    self.params = encoded;
    self.params_buffer = params_buffer;
    self.conversion_sampler = options.conversion_sampler;
    self.header.attach(guard, io);
    return self;
}

pub fn prepareForUse(context: kernels.Context, self: *ExternalTexture) Error!void {
    try self.validateSubmitLocked(context.guard);
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    try retainRootsLocked(context.pending_uses, context.guard, context.device, self);
    if (self.params_buffer.native.needsInitialization()) {
        try kernels.uploadParameters(context, .{
            .owner = self.params_buffer,
            .offset = 0,
            .size = parameter_size,
        }, &self.params);
    }
}

/// Admission captures children separately before explicit destruction can release owner edges.
pub fn retainRootsLocked(
    pending: *resources.PendingUses,
    guard: *const core.ObjectGuard,
    device: *core.Device,
    self: *ExternalTexture,
) ResourceError!void {
    try self.validateSubmitLocked(guard);
    try pending.retainDerivedRootLocked(guard, device, &self.header);
    for (self.planes) |plane| {
        try pending.retainDerivedRootLocked(guard, device, &plane.header);
        try pending.retainDerivedRootLocked(guard, device, &plane.texture.header);
    }
    try pending.retainDerivedRootLocked(guard, device, &self.params_buffer.header);
    if (self.conversion_sampler) |conversion| {
        try pending.retainDerivedRootLocked(guard, device, &conversion.header);
    }
}

fn checkHeader(guard: *const core.ObjectGuard, header: *const core.Object, kind: core.Handle.Kind) ResourceError!void {
    if (header.tracking != guard.objects) return error.ResourceDeviceMismatch;
    guard.assertOwns(header.tracking);
    if (header.kind != kind) return error.HandleKindMismatch;
    if (!header.node.linked or header.state != .alive) return error.ResourceDestroyed;
}

fn validatePlane(guard: *const core.ObjectGuard, plane: *texture.TextureView) ResourceError!api.descriptors.Extent2D {
    try checkHeader(guard, &plane.header, .texture_view);
    try checkHeader(guard, &plane.texture.header, .texture);
    if (plane.dimension != ._2d or plane.range.level_count != 1 or
        plane.range.layer_count != 1 or plane.texture.sample_count != 1 or
        !plane.usage.texture_binding)
    {
        return error.ExternalTextureInvalidPlane;
    }
    if (plane.native_view == null) return error.TextureNativeNotInitialized;
    const size = plane.texture.getMipLevelSingleSubresourceVirtualSize(guard, plane.range.base_mip_level);
    return .{ .width = size.width, .height = size.height };
}

fn validateComponents(plane: *const texture.TextureView, count: u8) ValidationError!void {
    if (!plane.format_info.isColor() or plane.aspects.toFlags() != 1 or
        !plane.format_info.isSupported() or plane.format_info.component_count != count or
        !plane.format_info.aspect_info[0].supported_sample_types.float)
    {
        return error.ExternalTextureFormatUnsupported;
    }
}

fn validateDescriptor(guard: *const core.ObjectGuard, options: Options) ResourceError!MetadataInput {
    const plane_0_size = try validatePlane(guard, options.plane_0);
    var plane_1_size: api.descriptors.Extent2D = .{ .width = 1, .height = 1 };
    if (options.plane_1) |plane| {
        if (options.conversion_sampler != null) return error.ExternalTextureConversionMismatch;
        plane_1_size = try validatePlane(guard, plane);
        try validateComponents(options.plane_0, 1);
        try validateComponents(plane, 2);
        if (options.yuv_to_rgb_conversion_matrix == null) return error.ExternalTextureInvalidMetadata;
    } else if (options.conversion_sampler) |conversion| {
        try checkHeader(guard, &conversion.header, .sampler);
        const conversion_descriptor = conversion.key.y_cb_cr orelse return error.ExternalTextureConversionMismatch;
        if (conversion_descriptor.external_format != 0) return error.ExternalTextureExternalMemoryUnavailable;
        if (options.plane_0.conversion_sampler != conversion) return error.ExternalTextureConversionMismatch;
        try options.plane_0.validateYCbCr(guard, conversion);
        const native = conversion.native orelse return error.ExternalTextureConversionMismatch;
        if (native.conversion == null or native.sampler == null) return error.ExternalTextureConversionMismatch;
    } else {
        if (options.plane_0.conversion_sampler != null) return error.ExternalTextureConversionMismatch;
        try validateComponents(options.plane_0, 4);
    }
    if (options.crop_size.width == 0 or options.crop_size.height == 0 or
        options.crop_size.width > plane_0_size.width or options.crop_size.height > plane_0_size.height)
    {
        return error.ExternalTextureInvalidCrop;
    }
    if (options.crop_origin.x > plane_0_size.width - options.crop_size.width or
        options.crop_origin.y > plane_0_size.height - options.crop_size.height)
    {
        return error.ExternalTextureInvalidCrop;
    }
    if (options.apparent_size.width == 0 or options.apparent_size.height == 0 or
        options.apparent_size.width > options.limits.v1.max_texture_dimension_2d or
        options.apparent_size.height > options.limits.v1.max_texture_dimension_2d)
    {
        return error.ExternalTextureInvalidApparentSize;
    }
    var metadata: MetadataInput = .{
        .plane_sizes = .{ plane_0_size, plane_1_size },
        .plane_count = if (options.plane_1 != null) 2 else 1,
        .crop_origin = options.crop_origin,
        .crop_size = options.crop_size,
        .apparent_size = options.apparent_size,
        .mirrored = options.mirrored,
        .rotation = options.rotation,
        .conversion_only = options.do_yuv_to_rgb_conversion_only,
    };
    if (options.yuv_to_rgb_conversion_matrix) |matrix| {
        if (matrix.len != 12) return error.ExternalTextureInvalidMetadata;
        @memcpy(&metadata.yuv_matrix, matrix);
    }
    const source = options.src_transfer_function_parameters orelse return error.ExternalTextureInvalidMetadata;
    const destination = options.dst_transfer_function_parameters orelse return error.ExternalTextureInvalidMetadata;
    const gamut = options.gamut_conversion_matrix orelse return error.ExternalTextureInvalidMetadata;
    if (source.len != 7 or destination.len != 7 or gamut.len != 9) return error.ExternalTextureInvalidMetadata;
    @memcpy(&metadata.src_transfer, source);
    @memcpy(&metadata.dst_transfer, destination);
    @memcpy(&metadata.gamut_matrix, gamut);
    if (options.conversion_sampler) |conversion| {
        metadata.identity_ycbcr = conversion.key.y_cb_cr.?.vk_y_cb_cr_model ==
            vk.VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_IDENTITY;
    }
    return metadata;
}

const MetadataInput = struct {
    plane_sizes: [2]api.descriptors.Extent2D,
    plane_count: u32,
    crop_origin: api.descriptors.Origin2D,
    crop_size: api.descriptors.Extent2D,
    apparent_size: api.descriptors.Extent2D,
    conversion_only: bool = false,
    mirrored: bool = false,
    rotation: api.ExternalTextureRotation = .rotate_0_degrees,
    identity_ycbcr: bool = false,
    yuv_matrix: [12]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 },
    gamut_matrix: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    src_transfer: [7]f32 = .{ 1, 1, 0, 1, 0, 0, 0 },
    dst_transfer: [7]f32 = .{ 1, 1, 0, 1, 0, 0, 0 },
};

/// Dawn pin 32f77c0, ExternalTexture.cpp:165-365. Encode WGSL layout, not host ABI.
fn encodeMetadata(input: MetadataInput) ValidationError![parameter_size]u8 {
    try validateFinite(&input.yuv_matrix);
    try validateFinite(&input.gamut_matrix);
    const source_mode = try transferMode(input.src_transfer, true);
    const destination_mode = try transferMode(input.dst_transfer, false);
    var bytes: [parameter_size]u8 = @splat(0);
    putWord(&bytes, 0, input.plane_count);
    putWord(&bytes, 4, @intFromBool(input.conversion_only));
    for (0..3) |column| {
        const base = column * 4;
        for (0..4) |row| {
            // U*yMat from the pinned body: Vulkan's identity sample is Cr,Y,Cb,1.
            const selected: usize = if (input.identity_ycbcr) switch (row) {
                0 => 2,
                1 => 0,
                2 => 1,
                else => 3,
            } else row;
            putFloat(&bytes, 16 + (base + row) * 4, input.yuv_matrix[base + selected]);
        }
    }
    encodeTransfer(&bytes, 64, source_mode, input.src_transfer);
    encodeTransfer(&bytes, 96, destination_mode, input.dst_transfer);
    for (0..3) |column| {
        for (0..3) |row| putFloat(&bytes, 128 + column * 16 + row * 4, input.gamut_matrix[column * 3 + row]);
    }
    var bounds = [2]u32{ input.apparent_size.width - 1, input.apparent_size.height - 1 };
    const mirror: f32 = if (input.mirrored) -1 else 1;
    const rotation: [4]f32 = switch (input.rotation) {
        .rotate_0_degrees => .{ 1, 0, 0, 1 },
        .rotate_90_degrees => rotation: {
            std.mem.swap(u32, &bounds[0], &bounds[1]);
            break :rotation .{ 0, -1, 1, 0 };
        },
        .rotate_180_degrees => .{ -1, 0, 0, -1 },
        .rotate_270_degrees => rotation: {
            std.mem.swap(u32, &bounds[0], &bounds[1]);
            break :rotation .{ 0, 1, -1, 0 };
        },
    };
    const sizes = [2][2]f32{
        .{ @floatFromInt(input.plane_sizes[0].width), @floatFromInt(input.plane_sizes[0].height) },
        .{ @floatFromInt(input.plane_sizes[1].width), @floatFromInt(input.plane_sizes[1].height) },
    };
    const scale = [2]f32{
        @as(f32, @floatFromInt(input.crop_size.width)) / sizes[0][0],
        @as(f32, @floatFromInt(input.crop_size.height)) / sizes[0][1],
    };
    const offset = [2]f32{
        @as(f32, @floatFromInt(input.crop_origin.x)) / sizes[0][0],
        @as(f32, @floatFromInt(input.crop_origin.y)) / sizes[0][1],
    };
    // Column-major affine matrix: inverse mirror, inverse rotation, crop.
    const transform = [6]f32{
        scale[0] * rotation[0] * mirror,
        scale[1] * rotation[1] * mirror,
        scale[0] * rotation[2],
        scale[1] * rotation[3],
        offset[0] + scale[0] * (0.5 - 0.5 * (rotation[0] * mirror + rotation[2])),
        offset[1] + scale[1] * (0.5 - 0.5 * (rotation[1] * mirror + rotation[3])),
    };
    for (transform, 0..) |value, index| putFloat(&bytes, 176 + index * 4, value);
    for (0..3) |column| {
        for (0..2) |row| {
            const normalized = if (column == 2) @as(f32, 1) else @as(f32, @floatFromInt(@max(bounds[column], 1)));
            putFloat(&bytes, 200 + (column * 2 + row) * 4, (sizes[0][row] - 1) * transform[column * 2 + row] / normalized);
        }
    }
    for (0..2) |plane| {
        for (0..2) |axis| {
            const half_texel = 0.5 / sizes[plane][axis];
            putFloat(&bytes, 224 + plane * 16 + axis * 4, offset[axis] + half_texel);
            putFloat(&bytes, 232 + plane * 16 + axis * 4, offset[axis] + scale[axis] - half_texel);
        }
    }
    for (0..2) |axis| {
        putWord(&bytes, 256 + axis * 4, bounds[axis]);
        putFloat(&bytes, 264 + axis * 4, sizes[1][axis] / sizes[0][axis]);
    }
    if (source_mode == 1) {
        // Rec2020 luminance from the inverse pinned YCbCr matrix, not a YUV value.
        putFloat(&bytes, 272, 0.2627);
        putFloat(&bytes, 276, 0.678);
        putFloat(&bytes, 280, 0.0593);
        putFloat(&bytes, 284, 0.2);
    }
    return bytes;
}

fn validateFinite(values: []const f32) ValidationError!void {
    for (values) |value| if (!std.math.isFinite(value)) return error.ExternalTextureInvalidMetadata;
}

fn transferMode(values: [7]f32, source: bool) ValidationError!u32 {
    try validateFinite(&values);
    if (values[0] >= 0) return 0;
    if (source and values[0] == -1) return 1;
    if (source and values[0] == -2) return 2;
    return error.ExternalTextureInvalidMetadata;
}

fn encodeTransfer(bytes: *[parameter_size]u8, offset: usize, mode: u32, values: [7]f32) void {
    putWord(bytes, offset, mode);
    for (values[1..], 0..) |value, index| putFloat(bytes, offset + 4 + index * 4, value);
    putFloat(bytes, offset + 28, values[0]);
}

fn putWord(bytes: *[parameter_size]u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn putFloat(bytes: *[parameter_size]u8, offset: usize, value: f32) void {
    putWord(bytes, offset, @bitCast(value));
}

fn word(bytes: *const [parameter_size]u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn floatWord(bytes: *const [parameter_size]u8, offset: usize) f32 {
    return @bitCast(word(bytes, offset));
}

pub const browser_parameter_size = 160;
const browser_copy = @import("../command/browser_copy.zig");
const attachments = @import("../command/attachment_state.zig");

/// Caller image-copy geometry. Natural size is independent of rotated external metadata bounds.
pub const BrowserGeometry = struct {
    natural_size: api.descriptors.Extent2D,
    source_origin: api.descriptors.Origin2D,
    copy_size: api.descriptors.Extent2D,
    options: browser_copy.Options,
};

/// Borrows the validated source while owning only encoded inline parameters, not a resource lease.
/// The source and original guard must remain live through preparation.
pub const ValidatedBrowserCopy = struct {
    source: *ExternalTexture,
    parameters: [browser_parameter_size]u8,
};

/// Borrowed destination compatibility for outside-pass preparation, never a pass ownership transfer.
pub const BrowserPreparation = struct {
    /// Null creates the canonical nearest ordinary sampler. Hardware copies require null.
    ordinary_sampler: ?*sampler.Sampler = null,
    compatible_render_pass: vk.VkRenderPass,
    attachments: *attachments.CanonicalAttachmentState,
};

/// Runs before destination transitions or pass creation. It allocates and records nothing.
pub fn validateBrowserCopy(
    context: kernels.Context,
    source: *ExternalTexture,
    geometry: BrowserGeometry,
) ResourceError!ValidatedBrowserCopy {
    try source.validateSubmitLocked(context.guard);
    if (context.recording.active_render_pass != null) return error.ExternalTextureInvalidBrowserCopy;
    return .{
        .source = source,
        .parameters = try encodeBrowserParameters(source, geometry),
    };
}

/// The pass owner begins and ends the pass. This operation only prepares outside-pass work.
pub fn prepareBrowserCopy(
    context: kernels.Context,
    validated: *ValidatedBrowserCopy,
    options: BrowserPreparation,
) Error!kernels.PreparedDraw {
    const source = validated.source;
    try source.validateSubmitLocked(context.guard);
    try checkHeader(context.guard, &options.attachments.header, .attachment_state);
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
    if (source.conversion_sampler != null and options.ordinary_sampler != null) {
        return error.ExternalTextureConversionMismatch;
    }
    if (options.attachments.value.color_attachments_set & 1 == 0) {
        return error.ExternalTextureInvalidBrowserCopy;
    }
    const target_format = options.attachments.value.color_formats[0];
    const decode_destination_srgb =
        target_format == @intFromEnum(api.TextureFormat.rgba8_unorm_srgb) or
        target_format == @intFromEnum(api.TextureFormat.bgra8_unorm_srgb);
    putBrowserWord(&validated.parameters, 40, @intFromBool(decode_destination_srgb));
    var bindings: [4]kernels.Binding = undefined;
    const binding_count: usize = if (source.conversion_sampler != null) 2 else 4;
    if (source.conversion_sampler == null) {
        const ordinary = options.ordinary_sampler orelse try kernels.sampler(context, .{ .compare = .undefined_ });
        try checkHeader(context.guard, &ordinary.header, .sampler);
        if (ordinary.key.y_cb_cr != null or ordinary.compare_function != .undefined_) {
            return error.ExternalTextureConversionMismatch;
        }
        bindings[0] = .{ .view = source.planes[0] };
        bindings[1] = .{ .view = source.planes[1] };
        bindings[2] = .{ .sampler = ordinary };
        bindings[3] = .{ .buffer = .{
            .owner = source.params_buffer,
            .offset = 0,
            .size = parameter_size,
        } };
    } else {
        bindings[0] = .{ .view = source.planes[0] };
        bindings[1] = .{ .buffer = .{
            .owner = source.params_buffer,
            .offset = 0,
            .size = parameter_size,
        } };
    }
    const needs_metadata_upload = source.params_buffer.native.needsInitialization();
    try prepareForUse(context, source);
    // Successful preparation emits this immutable buffer only when it was uninitialized.
    errdefer if (needs_metadata_upload) context.queue.poisonRecording();
    return kernels.prepareDraw(context, .{
        .key = .{
            .id = .external_to_color,
            .attachments = options.attachments,
            .color_write_slots = 1,
            .conversion_sampler = source.conversion_sampler,
        },
        .bindings = bindings[0..binding_count],
        .parameters = &validated.parameters,
        .compatible_render_pass = options.compatible_render_pass,
    });
}

/// Identity browser processing for an already-normalized full external-texture draw.
pub fn browserParameters(source: *const ExternalTexture) [browser_parameter_size]u8 {
    const size: api.descriptors.Extent2D = .{
        .width = word(&source.params, 256) + 1,
        .height = word(&source.params, 260) + 1,
    };
    return encodeBrowser(.{
        .source_size = size,
        .source_origin = .{},
        .copy_size = size,
        .options = .{},
    }) catch unreachable; // Published metadata has nonzero bounded extents and identity coefficients.
}

/// Encodes checked browser geometry and its separate color stage without altering source metadata.
/// The source must be a live immutable borrow. Empty in-bounds rectangles encode without allocation.
pub fn encodeBrowserParameters(
    source: *const ExternalTexture,
    geometry: BrowserGeometry,
) ResourceError![browser_parameter_size]u8 {
    // Keep the source borrow explicit. Its natural size is caller image-copy metadata.
    std.debug.assert(source.plane_count == 1 or source.plane_count == 2);
    return encodeBrowser(.{
        .source_size = geometry.natural_size,
        .source_origin = geometry.source_origin,
        .copy_size = geometry.copy_size,
        .options = geometry.options,
    });
}

const BrowserInput = struct {
    source_size: api.descriptors.Extent2D,
    source_origin: api.descriptors.Origin2D,
    copy_size: api.descriptors.Extent2D,
    options: browser_copy.Options,
};

fn encodeBrowser(input: BrowserInput) ResourceError![browser_parameter_size]u8 {
    try input.options.validate();
    if (input.source_size.width == 0 or input.source_size.height == 0 or
        input.copy_size.width > input.source_size.width or
        input.copy_size.height > input.source_size.height)
    {
        return error.ExternalTextureInvalidBrowserCopy;
    }
    if (input.source_origin.x > input.source_size.width - input.copy_size.width or
        input.source_origin.y > input.source_size.height - input.copy_size.height)
    {
        return error.ExternalTextureInvalidBrowserCopy;
    }
    var bytes: [browser_parameter_size]u8 = @splat(0);
    putBrowserFloat(&bytes, 0, @floatFromInt(input.source_origin.x));
    putBrowserFloat(&bytes, 4, @floatFromInt(input.source_origin.y));
    putBrowserFloat(&bytes, 8, @floatFromInt(input.copy_size.width));
    putBrowserFloat(&bytes, 12, @floatFromInt(input.copy_size.height));
    putBrowserFloat(&bytes, 16, @floatFromInt(input.source_size.width));
    putBrowserFloat(&bytes, 20, @floatFromInt(input.source_size.height));
    putBrowserWord(&bytes, 24, @intFromBool(input.options.flip_y));
    putBrowserWord(&bytes, 28, @intFromBool(input.options.needs_color_space_conversion));
    putBrowserWord(&bytes, 32, @intFromEnum(input.options.src_alpha_mode));
    putBrowserWord(&bytes, 36, @intFromEnum(input.options.dst_alpha_mode));
    for (input.options.src_transfer_function_parameters, 0..) |value, index| {
        putBrowserFloat(&bytes, 48 + index * 4, value);
    }
    for (input.options.dst_transfer_function_parameters, 0..) |value, index| {
        putBrowserFloat(&bytes, 80 + index * 4, value);
    }
    for (0..3) |column| {
        for (0..3) |row| {
            putBrowserFloat(&bytes, 112 + column * 16 + row * 4, input.options.conversion_matrix[column * 3 + row]);
        }
    }
    return bytes;
}

fn putBrowserWord(bytes: *[browser_parameter_size]u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn putBrowserFloat(bytes: *[browser_parameter_size]u8, offset: usize, value: f32) void {
    putBrowserWord(bytes, offset, @bitCast(value));
}

fn readBrowserWord(bytes: *const [browser_parameter_size]u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readBrowserFloat(bytes: *const [browser_parameter_size]u8, offset: usize) f32 {
    return @bitCast(readBrowserWord(bytes, offset));
}
