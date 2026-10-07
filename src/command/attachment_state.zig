//! Checked API attachment shapes and their immutable canonical core payload.
//!
//! The value owns no descriptor slices or native handles. Native producers
//! validate real views and device features before interning it in their weak cache.

const std = @import("std");
const core = @import("../core/root.zig");
const constants = @import("constants.zig");

pub const ExpandResolveInfo = struct {
    attachments_to_expand_resolve: u8 = 0,
    resolve_targets_mask: u8 = 0,
};

/// Aspect bits are color=1, depth=2, stencil=4, independent of Vulkan.
pub const ViewShape = struct {
    format: u32,
    sample_count: u32,
    aspects: u8,
};

pub const ColorShape = struct {
    view: ?ViewShape,
    resolve_target: ?ViewShape,
    expands_resolve: bool,
};

pub const StorageSlot = struct { offset: u64, format: u32 };
pub const StorageLayout = struct {
    total_size: u64,
    attachments: []const StorageSlot,
};
pub const PassStorageSlot = struct { offset: u64, view: ViewShape };
pub const PassStorage = struct {
    total_size: u64,
    attachments: []const PassStorageSlot,
};
pub const PassShape = struct {
    colors: []const ColorShape,
    depth_stencil: ?ViewShape,
    pls: ?PassStorage,
};
pub const LayoutShape = struct {
    color_formats: []const u32,
    depth_stencil_format: u32,
    sample_count: u32,
    expand_resolve: ExpandResolveInfo,
    pls: ?StorageLayout,
};
pub const AttachmentLimits = struct {
    max_color_attachments: u32,
    max_storage_attachments: u32,
    max_pls_bytes: u64,
};

pub const AttachmentError = error{
    TooManyAttachments,
    NoAttachmentInRenderPass,
    InvalidAttachmentAspect,
    AttachmentSampleCountUnsupported,
    AttachmentSampleCountMismatch,
    ResolveWithoutAttachment,
    InvalidAttachmentResolve,
    InvalidExpandResolveMask,
    PixelLocalStorageSizeInvalid,
    PixelLocalStorageOffsetUnaligned,
    PixelLocalStorageAttachmentCountExceeded,
    PixelLocalStorageOffsetOutOfRange,
    PixelLocalStorageOffsetDuplicate,
    NoncanonicalAttachmentState,
};

pub const AttachmentState = struct {
    color_attachments_set: u8 = 0,
    color_formats: [constants.max_color_attachments]u32 = @splat(0),
    depth_stencil_format: u32 = 0,
    sample_count: u32 = 1,
    expand_resolve: ExpandResolveInfo = .{},
    has_pls: bool = false,
    storage_attachment_slots: [constants.max_pls_slots]u32 = @splat(0),
    storage_attachment_slot_count: u32 = 0,

    pub fn fromRenderPass(input: PassShape, limits: AttachmentLimits) AttachmentError!AttachmentState {
        try checkColorCount(input.colors.len, limits);
        var state: AttachmentState = .{};
        var samples: ?u32 = null;
        for (input.colors, 0..) |color, index| {
            const bit = colorBit(index);
            if (color.view) |view| {
                try validateColorView(view);
                try matchSamples(&samples, view.sample_count);
                state.color_attachments_set |= bit;
                state.color_formats[index] = view.format;
                if (color.resolve_target) |target| {
                    try validateColorView(target);
                    if (view.sample_count == 1 or target.sample_count != 1 or
                        target.format != view.format)
                    {
                        return error.InvalidAttachmentResolve;
                    }
                    state.expand_resolve.resolve_targets_mask |= bit;
                }
            } else if (color.resolve_target != null) {
                return error.ResolveWithoutAttachment;
            }
            if (color.expands_resolve) {
                state.expand_resolve.attachments_to_expand_resolve |= bit;
            }
        }
        if (input.depth_stencil) |view| {
            try validateDepthStencilView(view);
            try matchSamples(&samples, view.sample_count);
            state.depth_stencil_format = view.format;
        }
        if (input.pls) |storage| {
            state.has_pls = true;
            state.storage_attachment_slot_count = try storageSlotCount(
                storage.total_size,
                storage.attachments.len,
                limits,
            );
            for (storage.attachments) |attachment| {
                try validateColorView(attachment.view);
                try matchSamples(&samples, attachment.view.sample_count);
                try state.setStorageSlot(attachment.offset, attachment.view.format);
            }
        }
        try validateExpandResolve(state.color_attachments_set, state.expand_resolve);
        state.normalizeResolveTargets();
        state.sample_count = samples orelse return error.NoAttachmentInRenderPass;
        try state.validateCanonical();
        return state;
    }

    pub fn fromRenderPipeline(
        input: LayoutShape,
        limits: AttachmentLimits,
    ) AttachmentError!AttachmentState {
        return fromLayout(input, limits);
    }

    pub fn fromRenderBundle(
        input: LayoutShape,
        limits: AttachmentLimits,
    ) AttachmentError!AttachmentState {
        return fromLayout(input, limits);
    }

    fn fromLayout(input: LayoutShape, limits: AttachmentLimits) AttachmentError!AttachmentState {
        try checkColorCount(input.color_formats.len, limits);
        try validateSamples(input.sample_count);
        var state: AttachmentState = .{
            .depth_stencil_format = input.depth_stencil_format,
            .sample_count = input.sample_count,
            .expand_resolve = input.expand_resolve,
        };
        for (input.color_formats, 0..) |format, index| {
            if (format == 0) continue;
            state.color_formats[index] = format;
            state.color_attachments_set |= colorBit(index);
        }
        try validateExpandResolve(state.color_attachments_set, state.expand_resolve);
        state.normalizeResolveTargets();
        if (input.pls) |storage| {
            state.has_pls = true;
            state.storage_attachment_slot_count = try storageSlotCount(
                storage.total_size,
                storage.attachments.len,
                limits,
            );
            for (storage.attachments) |attachment| {
                try state.setStorageSlot(attachment.offset, attachment.format);
            }
        }
        try state.validateCanonical();
        return state;
    }

    pub fn validateCanonical(self: *const AttachmentState) AttachmentError!void {
        try validateSamples(self.sample_count);
        try validateExpandResolve(self.color_attachments_set, self.expand_resolve);
        if (self.expand_resolve.attachments_to_expand_resolve == 0 and
            self.expand_resolve.resolve_targets_mask != 0)
        {
            return error.NoncanonicalAttachmentState;
        }
        for (self.color_formats, 0..) |format, index| {
            if (self.hasColorAttachment(@intCast(index)) != (format != 0)) {
                return error.NoncanonicalAttachmentState;
            }
        }
        if (self.storage_attachment_slot_count > constants.max_pls_slots) {
            return error.NoncanonicalAttachmentState;
        }
        if (!self.has_pls and self.storage_attachment_slot_count != 0) {
            return error.NoncanonicalAttachmentState;
        }
        for (self.storage_attachment_slots, 0..) |format, index| {
            if (index >= self.storage_attachment_slot_count and format != 0) {
                return error.NoncanonicalAttachmentState;
            }
        }
    }

    pub fn hasColorAttachment(self: *const AttachmentState, index: u32) bool {
        if (index >= constants.max_color_attachments) return false;
        return self.color_attachments_set & colorBit(index) != 0;
    }

    pub fn colorAttachmentFormat(self: *const AttachmentState, index: u32) u32 {
        if (!self.hasColorAttachment(index)) return 0;
        return self.color_formats[index];
    }

    pub fn hasDepthStencilAttachment(self: *const AttachmentState) bool {
        return self.depth_stencil_format != 0;
    }

    pub fn hasPixelLocalStorage(self: *const AttachmentState) bool {
        return self.has_pls;
    }

    /// Returns slot-format metadata borrowed from self, not an allocator or packing implementation.
    pub fn storageAttachmentPacking(self: *const AttachmentState) []const u32 {
        std.debug.assert(self.storage_attachment_slot_count <= constants.max_pls_slots);
        return self.storage_attachment_slots[0..self.storage_attachment_slot_count];
    }

    pub fn eql(left: *const AttachmentState, right: *const AttachmentState) bool {
        return left.color_attachments_set == right.color_attachments_set and
            std.mem.eql(u32, &left.color_formats, &right.color_formats) and
            left.depth_stencil_format == right.depth_stencil_format and
            left.sample_count == right.sample_count and
            left.expand_resolve.attachments_to_expand_resolve ==
                right.expand_resolve.attachments_to_expand_resolve and
            left.expand_resolve.resolve_targets_mask == right.expand_resolve.resolve_targets_mask and
            left.has_pls == right.has_pls and
            left.storage_attachment_slot_count == right.storage_attachment_slot_count and
            std.mem.eql(u32, &left.storage_attachment_slots, &right.storage_attachment_slots);
    }

    /// Scalar encoding excludes pointers and padding. This hash is not a serialized ABI.
    pub fn computeContentHash(self: *const AttachmentState) u64 {
        var hasher: std.hash.Wyhash = .init(0x6465_7363_0E15_0001);
        hashScalar(&hasher, self.color_attachments_set);
        for (self.color_formats) |format| hashScalar(&hasher, format);
        hashScalar(&hasher, self.depth_stencil_format);
        hashScalar(&hasher, self.sample_count);
        hashScalar(&hasher, self.expand_resolve.attachments_to_expand_resolve);
        hashScalar(&hasher, self.expand_resolve.resolve_targets_mask);
        hashScalar(&hasher, @intFromBool(self.has_pls));
        hashScalar(&hasher, self.storage_attachment_slot_count);
        for (self.storage_attachment_slots) |format| hashScalar(&hasher, format);
        return hasher.final();
    }

    fn normalizeResolveTargets(self: *AttachmentState) void {
        // Dawn AttachmentState.cpp:89-94,154-161 makes ordinary resolves compatible with pipelines.
        if (self.expand_resolve.attachments_to_expand_resolve == 0) {
            self.expand_resolve.resolve_targets_mask = 0;
        }
    }

    fn setStorageSlot(self: *AttachmentState, offset: u64, format: u32) AttachmentError!void {
        if (offset % constants.pls_slot_byte_size != 0) {
            return error.PixelLocalStorageOffsetUnaligned;
        }
        // Compare the quotient before narrowing. Adding the slot size could overflow u64.
        const slot_index = @divExact(offset, constants.pls_slot_byte_size);
        if (slot_index >= self.storage_attachment_slot_count) {
            return error.PixelLocalStorageOffsetOutOfRange;
        }
        if (format == 0) return error.NoncanonicalAttachmentState;
        const index: usize = @intCast(slot_index);
        if (self.storage_attachment_slots[index] != 0) {
            return error.PixelLocalStorageOffsetDuplicate;
        }
        self.storage_attachment_slots[index] = format;
    }
};

/// One genuine arena payload. The weak cache owns no reference to this leaf.
pub const CanonicalAttachmentState = struct {
    header: core.Object,
    value: AttachmentState,
    cache_hash: u64 = 0,
    cache_next: ?*CanonicalAttachmentState = null,

    pub fn destroy(
        self: *CanonicalAttachmentState,
        guard: *const core.ObjectGuard,
        io: std.Io,
        reason: core.DestroyReason,
    ) void {
        _ = io;
        _ = reason;
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.header.kind == .attachment_state);
        std.debug.assert(self.header.state == .destroyed);
        std.debug.assert(self.header.remove_from_cache == null);
        std.debug.assert(self.header.cache_context == null);
        std.debug.assert(self.cache_next == null);
    }
};

comptime {
    std.debug.assert(constants.max_color_attachments == @bitSizeOf(u8));
    std.debug.assert(constants.max_pls_slots == 4);
    std.debug.assert(constants.max_pls_size == 16);
}

fn colorBit(index: usize) u8 {
    std.debug.assert(index < constants.max_color_attachments);
    return @as(u8, 1) << @intCast(index);
}

fn checkColorCount(count: usize, limits: AttachmentLimits) AttachmentError!void {
    if (count > @min(constants.max_color_attachments, limits.max_color_attachments)) {
        return error.TooManyAttachments;
    }
}

fn validateSamples(samples: u32) AttachmentError!void {
    if (samples != 1 and samples != 4) return error.AttachmentSampleCountUnsupported;
}

fn matchSamples(common: *?u32, samples: u32) AttachmentError!void {
    try validateSamples(samples);
    if (common.*) |expected| {
        if (expected != samples) return error.AttachmentSampleCountMismatch;
    } else {
        common.* = samples;
    }
}

fn validateColorView(view: ViewShape) AttachmentError!void {
    if (view.aspects != 1) return error.InvalidAttachmentAspect;
    if (view.format == 0) return error.NoncanonicalAttachmentState;
}

fn validateDepthStencilView(view: ViewShape) AttachmentError!void {
    if (view.aspects == 0 or view.aspects & ~@as(u8, 6) != 0) {
        return error.InvalidAttachmentAspect;
    }
    if (view.format == 0) return error.NoncanonicalAttachmentState;
}

fn validateExpandResolve(colors: u8, expand: ExpandResolveInfo) AttachmentError!void {
    if (expand.resolve_targets_mask & ~colors != 0 or
        expand.attachments_to_expand_resolve & ~expand.resolve_targets_mask != 0)
    {
        return error.InvalidExpandResolveMask;
    }
}

fn storageSlotCount(
    total_size: u64,
    attachment_count: usize,
    limits: AttachmentLimits,
) AttachmentError!u32 {
    if (total_size % constants.pls_slot_byte_size != 0 or
        total_size > @min(limits.max_pls_bytes, constants.max_pls_size))
    {
        return error.PixelLocalStorageSizeInvalid;
    }
    const slot_count = @divExact(total_size, constants.pls_slot_byte_size);
    if (slot_count > constants.max_pls_slots) return error.PixelLocalStorageSizeInvalid;
    if (attachment_count > slot_count or
        attachment_count > @min(limits.max_storage_attachments, constants.max_pls_slots))
    {
        return error.PixelLocalStorageAttachmentCountExceeded;
    }
    return @intCast(slot_count);
}

fn hashScalar(hasher: *std.hash.Wyhash, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

const test_limits: AttachmentLimits = .{
    .max_color_attachments = 8,
    .max_storage_attachments = 4,
    .max_pls_bytes = 16,
};

fn testColor(format: u32, sample_count: u32) ViewShape {
    return .{ .format = format, .sample_count = sample_count, .aspects = 1 };
}

fn testLayout() LayoutShape {
    return .{
        .color_formats = &.{ 11, 0, 22 },
        .depth_stencil_format = 33,
        .sample_count = 4,
        .expand_resolve = .{},
        .pls = null,
    };
}

test "pass samples come from the first present source and preserve color holes" {
    const colors = [_]ColorShape{
        .{ .view = null, .resolve_target = null, .expands_resolve = false },
        .{ .view = testColor(11, 4), .resolve_target = null, .expands_resolve = false },
        .{ .view = null, .resolve_target = null, .expands_resolve = false },
    };
    const state = try AttachmentState.fromRenderPass(.{
        .colors = &colors,
        .depth_stencil = null,
        .pls = null,
    }, test_limits);
    try std.testing.expectEqual(@as(u32, 4), state.sample_count);
    try std.testing.expectEqual(@as(u8, 2), state.color_attachments_set);
    try std.testing.expectEqual(@as(u32, 11), state.colorAttachmentFormat(1));
    try std.testing.expectEqual(@as(u32, 0), state.colorAttachmentFormat(0));
    try std.testing.expectEqual(@as(u32, 0), state.colorAttachmentFormat(8));
    try std.testing.expect(!state.hasColorAttachment(8));
    for (state.color_formats[2..]) |format| try std.testing.expectEqual(@as(u32, 0), format);
    try state.validateCanonical();
}

test "depth-only and storage-only passes infer four samples" {
    inline for (.{ @as(u8, 2), @as(u8, 4), @as(u8, 6) }) |aspects| {
        const depth = try AttachmentState.fromRenderPass(.{
            .colors = &.{},
            .depth_stencil = .{ .format = 33, .sample_count = 4, .aspects = aspects },
            .pls = null,
        }, test_limits);
        try std.testing.expectEqual(@as(u32, 4), depth.sample_count);
        try std.testing.expect(depth.hasDepthStencilAttachment());
    }
    const storage = try AttachmentState.fromRenderPass(.{
        .colors = &.{},
        .depth_stencil = null,
        .pls = .{ .total_size = 16, .attachments = &.{
            .{ .offset = 12, .view = testColor(44, 4) },
        } },
    }, test_limits);
    try std.testing.expectEqual(@as(u32, 4), storage.sample_count);
    try std.testing.expectEqual(@as(u32, 4), storage.storage_attachment_slot_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 44 }, storage.storageAttachmentPacking());
}

test "empty pass fails even when storage slots are present without views" {
    inline for (.{ @as(?PassStorage, null), @as(?PassStorage, .{
        .total_size = 0,
        .attachments = &.{},
    }), @as(?PassStorage, .{
        .total_size = 16,
        .attachments = &.{},
    }) }) |pls| {
        try std.testing.expectError(error.NoAttachmentInRenderPass, AttachmentState.fromRenderPass(.{
            .colors = &.{},
            .depth_stencil = null,
            .pls = pls,
        }, test_limits));
    }
}

test "color slot bounds reject a ninth slot instead of converting it to storage" {
    const absent: ColorShape = .{
        .view = null,
        .resolve_target = null,
        .expands_resolve = false,
    };
    const nine = [_]ColorShape{absent} ** 9;
    try std.testing.expectError(error.TooManyAttachments, AttachmentState.fromRenderPass(.{
        .colors = &nine,
        .depth_stencil = null,
        .pls = null,
    }, test_limits));
    var limits = test_limits;
    limits.max_color_attachments = 2;
    try std.testing.expectError(error.TooManyAttachments, AttachmentState.fromRenderPipeline(
        testLayout(),
        limits,
    ));
    var layout = testLayout();
    layout.color_formats = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 11 };
    try std.testing.expectError(
        error.TooManyAttachments,
        AttachmentState.fromRenderBundle(layout, test_limits),
    );
    layout.color_formats = &.{ 0, 0, 0, 0, 0, 0, 0, 11 };
    const boundary = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expectEqual(@as(u8, 128), boundary.color_attachments_set);
}

test "only API sample counts one and four are supported" {
    inline for (.{ @as(u32, 0), @as(u32, 2), @as(u32, 8), std.math.maxInt(u32) }) |samples| {
        var layout = testLayout();
        layout.sample_count = samples;
        try std.testing.expectError(
            error.AttachmentSampleCountUnsupported,
            AttachmentState.fromRenderPipeline(layout, test_limits),
        );
        try std.testing.expectError(
            error.AttachmentSampleCountUnsupported,
            AttachmentState.fromRenderBundle(layout, test_limits),
        );
        try std.testing.expectError(error.AttachmentSampleCountUnsupported, AttachmentState.fromRenderPass(.{
            .colors = &.{.{
                .view = testColor(11, samples),
                .resolve_target = null,
                .expands_resolve = false,
            }},
            .depth_stencil = null,
            .pls = null,
        }, test_limits));
    }
    inline for (.{ @as(u32, 1), @as(u32, 4) }) |samples| {
        var layout = testLayout();
        layout.color_formats = &.{};
        layout.depth_stencil_format = 0;
        layout.sample_count = samples;
        const state = try AttachmentState.fromRenderBundle(layout, test_limits);
        try std.testing.expectEqual(samples, state.sample_count);
        try std.testing.expectEqual(@as(u8, 0), state.color_attachments_set);
    }
}

test "every non-resolve source must match the pass sample count" {
    const color: ColorShape = .{
        .view = testColor(11, 4),
        .resolve_target = null,
        .expands_resolve = false,
    };
    try std.testing.expectError(error.AttachmentSampleCountMismatch, AttachmentState.fromRenderPass(.{
        .colors = &.{ color, .{
            .view = testColor(22, 1),
            .resolve_target = null,
            .expands_resolve = false,
        } },
        .depth_stencil = null,
        .pls = null,
    }, test_limits));
    try std.testing.expectError(error.AttachmentSampleCountMismatch, AttachmentState.fromRenderPass(.{
        .colors = &.{color},
        .depth_stencil = .{ .format = 33, .sample_count = 1, .aspects = 2 },
        .pls = null,
    }, test_limits));
    try std.testing.expectError(error.AttachmentSampleCountMismatch, AttachmentState.fromRenderPass(.{
        .colors = &.{color},
        .depth_stencil = null,
        .pls = .{ .total_size = 4, .attachments = &.{
            .{ .offset = 0, .view = testColor(44, 1) },
        } },
    }, test_limits));
}

test "aspect masks enforce color and depth-stencil roles" {
    inline for (.{ @as(u8, 0), @as(u8, 2), @as(u8, 3), @as(u8, 4), @as(u8, 8) }) |aspects| {
        try std.testing.expectError(error.InvalidAttachmentAspect, AttachmentState.fromRenderPass(.{
            .colors = &.{.{
                .view = .{ .format = 11, .sample_count = 1, .aspects = aspects },
                .resolve_target = null,
                .expands_resolve = false,
            }},
            .depth_stencil = null,
            .pls = null,
        }, test_limits));
    }
    inline for (.{ @as(u8, 0), @as(u8, 1), @as(u8, 3), @as(u8, 7), @as(u8, 8) }) |aspects| {
        try std.testing.expectError(error.InvalidAttachmentAspect, AttachmentState.fromRenderPass(.{
            .colors = &.{},
            .depth_stencil = .{ .format = 33, .sample_count = 1, .aspects = aspects },
            .pls = null,
        }, test_limits));
    }
    try std.testing.expectError(error.NoncanonicalAttachmentState, AttachmentState.fromRenderPass(.{
        .colors = &.{.{
            .view = testColor(0, 1),
            .resolve_target = null,
            .expands_resolve = false,
        }},
        .depth_stencil = null,
        .pls = null,
    }, test_limits));
}

test "resolve source and target shapes are checked before normalization" {
    try std.testing.expectError(error.ResolveWithoutAttachment, AttachmentState.fromRenderPass(.{
        .colors = &.{.{
            .view = null,
            .resolve_target = testColor(11, 1),
            .expands_resolve = false,
        }},
        .depth_stencil = null,
        .pls = null,
    }, test_limits));
    const invalid = [_]ColorShape{
        .{ .view = testColor(11, 1), .resolve_target = testColor(11, 1), .expands_resolve = false },
        .{ .view = testColor(11, 4), .resolve_target = testColor(11, 4), .expands_resolve = false },
        .{ .view = testColor(11, 4), .resolve_target = testColor(22, 1), .expands_resolve = false },
    };
    for (invalid) |color| {
        try std.testing.expectError(error.InvalidAttachmentResolve, AttachmentState.fromRenderPass(.{
            .colors = &.{color},
            .depth_stencil = null,
            .pls = null,
        }, test_limits));
    }
    try std.testing.expectError(error.InvalidAttachmentAspect, AttachmentState.fromRenderPass(.{
        .colors = &.{.{
            .view = testColor(11, 4),
            .resolve_target = .{ .format = 11, .sample_count = 1, .aspects = 2 },
            .expands_resolve = false,
        }},
        .depth_stencil = null,
        .pls = null,
    }, test_limits));
}

test "ordinary resolves normalize to the full pipeline identity" {
    var layout = testLayout();
    layout.depth_stencil_format = 0;
    const pipeline = try AttachmentState.fromRenderPipeline(layout, test_limits);
    const pass = try AttachmentState.fromRenderPass(.{
        .colors = &.{
            .{ .view = testColor(11, 4), .resolve_target = testColor(11, 1), .expands_resolve = false },
            .{ .view = null, .resolve_target = null, .expands_resolve = false },
            .{ .view = testColor(22, 4), .resolve_target = testColor(22, 1), .expands_resolve = false },
        },
        .depth_stencil = null,
        .pls = null,
    }, test_limits);
    try std.testing.expect(AttachmentState.eql(&pass, &pipeline));
    try std.testing.expectEqual(pass.computeContentHash(), pipeline.computeContentHash());
    try std.testing.expectEqual(@as(u8, 0), pass.expand_resolve.resolve_targets_mask);
    layout.expand_resolve.resolve_targets_mask = 5;
    const disabled_extension = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expect(AttachmentState.eql(&disabled_extension, &pipeline));
}

test "expansion preserves all resolve targets including non-expanding targets" {
    const pass = try AttachmentState.fromRenderPass(.{
        .colors = &.{
            .{ .view = testColor(11, 4), .resolve_target = testColor(11, 1), .expands_resolve = true },
            .{ .view = null, .resolve_target = null, .expands_resolve = false },
            .{ .view = testColor(22, 4), .resolve_target = testColor(22, 1), .expands_resolve = false },
        },
        .depth_stencil = null,
        .pls = null,
    }, test_limits);
    try std.testing.expectEqual(@as(u8, 1), pass.expand_resolve.attachments_to_expand_resolve);
    try std.testing.expectEqual(@as(u8, 5), pass.expand_resolve.resolve_targets_mask);
    var layout = testLayout();
    layout.depth_stencil_format = 0;
    layout.expand_resolve = .{
        .attachments_to_expand_resolve = 1,
        .resolve_targets_mask = 5,
    };
    const pipeline = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expect(AttachmentState.eql(&pass, &pipeline));
    try std.testing.expectEqual(pass.computeContentHash(), pipeline.computeContentHash());
    layout.expand_resolve.resolve_targets_mask = 1;
    const different_targets = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expect(!AttachmentState.eql(&pass, &different_targets));
}

test "expansion masks cannot name absent colors or missing resolve targets" {
    inline for (.{ ExpandResolveInfo{
        .attachments_to_expand_resolve = 1,
        .resolve_targets_mask = 0,
    }, ExpandResolveInfo{
        .attachments_to_expand_resolve = 2,
        .resolve_targets_mask = 2,
    }, ExpandResolveInfo{
        .attachments_to_expand_resolve = 0,
        .resolve_targets_mask = 2,
    } }) |expand| {
        var layout = testLayout();
        layout.expand_resolve = expand;
        try std.testing.expectError(error.InvalidExpandResolveMask, AttachmentState.fromRenderPipeline(layout, test_limits));
    }
    inline for (.{ @as(?ViewShape, null), @as(?ViewShape, testColor(11, 4)) }) |view| {
        try std.testing.expectError(error.InvalidExpandResolveMask, AttachmentState.fromRenderPass(.{
            .colors = &.{.{
                .view = view,
                .resolve_target = null,
                .expands_resolve = true,
            }},
            .depth_stencil = null,
            .pls = null,
        }, test_limits));
    }
}

test "storage size includes holes and zero-size presence differs from absence" {
    var layout = testLayout();
    const absent = try AttachmentState.fromRenderPipeline(layout, test_limits);
    layout.pls = .{ .total_size = 0, .attachments = &.{} };
    const zero_size = try AttachmentState.fromRenderBundle(layout, test_limits);
    try std.testing.expect(zero_size.hasPixelLocalStorage());
    try std.testing.expectEqual(@as(usize, 0), zero_size.storageAttachmentPacking().len);
    try std.testing.expect(!AttachmentState.eql(&absent, &zero_size));
    layout.pls = .{ .total_size = 16, .attachments = &.{
        .{ .offset = 12, .format = 44 }, .{ .offset = 4, .format = 55 },
    } };
    const holes = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expectEqualSlices(u32, &.{ 0, 55, 0, 44 }, holes.storageAttachmentPacking());
    try std.testing.expect(
        holes.storageAttachmentPacking().ptr == holes.storage_attachment_slots[0..].ptr,
    );
    layout.pls = .{ .total_size = 16, .attachments = &.{
        .{ .offset = 4, .format = 55 }, .{ .offset = 12, .format = 44 },
    } };
    const reordered = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expect(AttachmentState.eql(&holes, &reordered));
    try std.testing.expectEqual(holes.computeContentHash(), reordered.computeContentHash());
}

test "storage size respects alignment fixed capacity and effective byte limits" {
    inline for (.{ @as(u64, 1), @as(u64, 17), @as(u64, 20), std.math.maxInt(u64) }) |size| {
        var layout = testLayout();
        layout.pls = .{ .total_size = size, .attachments = &.{} };
        try std.testing.expectError(error.PixelLocalStorageSizeInvalid, AttachmentState.fromRenderPipeline(layout, test_limits));
    }
    var limits = test_limits;
    limits.max_pls_bytes = 12;
    var layout = testLayout();
    layout.pls = .{ .total_size = 16, .attachments = &.{} };
    try std.testing.expectError(error.PixelLocalStorageSizeInvalid, AttachmentState.fromRenderPipeline(layout, limits));
    limits.max_pls_bytes = std.math.maxInt(u64);
    layout.pls = .{ .total_size = 20, .attachments = &.{} };
    try std.testing.expectError(error.PixelLocalStorageSizeInvalid, AttachmentState.fromRenderPipeline(layout, limits));
}

test "storage offsets reject misalignment range overflow duplicates and undefined formats" {
    const cases = [_]struct { offset: u64, expected: AttachmentError }{
        .{ .offset = 1, .expected = error.PixelLocalStorageOffsetUnaligned },
        .{ .offset = 16, .expected = error.PixelLocalStorageOffsetOutOfRange },
        .{ .offset = std.math.maxInt(u64) - 3, .expected = error.PixelLocalStorageOffsetOutOfRange },
    };
    for (cases) |case| {
        var layout = testLayout();
        layout.pls = .{ .total_size = 16, .attachments = &.{
            .{ .offset = case.offset, .format = 44 },
        } };
        try std.testing.expectError(case.expected, AttachmentState.fromRenderPipeline(layout, test_limits));
    }
    var layout = testLayout();
    layout.pls = .{ .total_size = 8, .attachments = &.{
        .{ .offset = 0, .format = 44 }, .{ .offset = 0, .format = 55 },
    } };
    try std.testing.expectError(error.PixelLocalStorageOffsetDuplicate, AttachmentState.fromRenderPipeline(layout, test_limits));
    layout.pls = .{ .total_size = 4, .attachments = &.{.{ .offset = 0, .format = 0 }} };
    try std.testing.expectError(error.NoncanonicalAttachmentState, AttachmentState.fromRenderPipeline(layout, test_limits));
}

test "storage declaration counts obey effective count and total slot count" {
    var layout = testLayout();
    const slots = [_]StorageSlot{
        .{ .offset = 0, .format = 44 }, .{ .offset = 4, .format = 55 },
    };
    layout.pls = .{ .total_size = 16, .attachments = &slots };
    var limits = test_limits;
    limits.max_storage_attachments = 1;
    try std.testing.expectError(error.PixelLocalStorageAttachmentCountExceeded, AttachmentState.fromRenderPipeline(layout, limits));
    layout.pls = .{ .total_size = 4, .attachments = &slots };
    try std.testing.expectError(error.PixelLocalStorageAttachmentCountExceeded, AttachmentState.fromRenderPipeline(layout, test_limits));
    layout.pls = .{ .total_size = 0, .attachments = slots[0..1] };
    try std.testing.expectError(error.PixelLocalStorageAttachmentCountExceeded, AttachmentState.fromRenderBundle(layout, test_limits));
    layout.pls = .{ .total_size = 16, .attachments = &.{
        .{ .offset = 0, .format = 11 }, .{ .offset = 4, .format = 22 },
        .{ .offset = 8, .format = 33 }, .{ .offset = 12, .format = 44 },
    } };
    const full = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expectEqualSlices(u32, &.{ 11, 22, 33, 44 }, full.storageAttachmentPacking());
}

test "canonical validation rejects malformed values without repairing them" {
    const valid = try AttachmentState.fromRenderPipeline(testLayout(), test_limits);
    const cases = [_]AttachmentState{
        blk: {
            var value = valid;
            value.color_formats[1] = 99;
            break :blk value;
        },
        blk: {
            var value = valid;
            value.color_formats[0] = 0;
            break :blk value;
        },
        blk: {
            var value = valid;
            value.storage_attachment_slot_count = 1;
            break :blk value;
        },
        blk: {
            var value = valid;
            value.storage_attachment_slots[3] = 99;
            break :blk value;
        },
        blk: {
            var value = valid;
            value.has_pls = true;
            value.storage_attachment_slot_count = 5;
            break :blk value;
        },
        blk: {
            var value = valid;
            value.has_pls = true;
            value.storage_attachment_slot_count = 1;
            value.storage_attachment_slots[1] = 99;
            break :blk value;
        },
        blk: {
            var value = valid;
            value.expand_resolve.resolve_targets_mask = 1;
            break :blk value;
        },
    };
    for (cases) |case| {
        const value = case;
        const before_hash = value.computeContentHash();
        try std.testing.expectError(error.NoncanonicalAttachmentState, value.validateCanonical());
        try std.testing.expect(AttachmentState.eql(&case, &value));
        try std.testing.expectEqual(before_hash, value.computeContentHash());
    }
    var masks = valid;
    masks.expand_resolve = .{ .attachments_to_expand_resolve = 2, .resolve_targets_mask = 2 };
    try std.testing.expectError(error.InvalidExpandResolveMask, masks.validateCanonical());
    masks.expand_resolve = .{ .attachments_to_expand_resolve = 1, .resolve_targets_mask = 0 };
    try std.testing.expectError(error.InvalidExpandResolveMask, masks.validateCanonical());
    var samples = valid;
    samples.sample_count = 2;
    try std.testing.expectError(error.AttachmentSampleCountUnsupported, samples.validateCanonical());
}

test "API formats selected aspects and all canonical semantic fields define equality" {
    const base = try AttachmentState.fromRenderPipeline(testLayout(), test_limits);
    var same_layout = testLayout();
    same_layout.color_formats = &.{ 11, 0, 22, 0, 0, 0, 0, 0 };
    const trailing = try AttachmentState.fromRenderBundle(same_layout, test_limits);
    try std.testing.expect(AttachmentState.eql(&base, &trailing));
    try std.testing.expectEqual(base.computeContentHash(), trailing.computeContentHash());
    const variants = [_]AttachmentState{
        blk: {
            var state = base;
            state.color_attachments_set ^= 1;
            break :blk state;
        },
        blk: {
            var state = base;
            state.color_formats[0] += 1;
            break :blk state;
        },
        blk: {
            var state = base;
            state.depth_stencil_format += 1;
            break :blk state;
        },
        blk: {
            var state = base;
            state.sample_count = 1;
            break :blk state;
        },
        blk: {
            var state = base;
            state.has_pls = true;
            break :blk state;
        },
        blk: {
            var state = base;
            state.has_pls = true;
            state.storage_attachment_slot_count = 1;
            break :blk state;
        },
        blk: {
            var state = base;
            state.has_pls = true;
            state.storage_attachment_slot_count = 1;
            state.storage_attachment_slots[0] = 44;
            break :blk state;
        },
        blk: {
            var state = base;
            state.expand_resolve = .{
                .attachments_to_expand_resolve = 1,
                .resolve_targets_mask = 1,
            };
            break :blk state;
        },
    };
    for (variants) |variant| {
        try std.testing.expect(!AttachmentState.eql(&base, &variant));
    }
    var depth_states: [3]AttachmentState = undefined;
    for ([_]u8{ 2, 4, 6 }, &depth_states) |aspects, *state| {
        state.* = try AttachmentState.fromRenderPass(.{
            .colors = &.{},
            .depth_stencil = .{ .format = 33, .sample_count = 4, .aspects = aspects },
            .pls = null,
        }, test_limits);
    }
    for (depth_states[1..]) |*state| {
        try std.testing.expect(AttachmentState.eql(&depth_states[0], state));
        try std.testing.expectEqual(depth_states[0].computeContentHash(), state.computeContentHash());
    }
}

test "canonical attachment is a real arena payload and lease prevents final reclamation" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("attachment references leaked");
    const canonical = try arena.create(std.testing.allocator, &guard, CanonicalAttachmentState, .{
        .kind = .attachment_state,
        .initial_reference = .user,
    });
    canonical.value = try AttachmentState.fromRenderPipeline(testLayout(), test_limits);
    canonical.cache_hash = 0;
    canonical.cache_next = null;
    canonical.header.attach(&guard, std.testing.io);
    try std.testing.expectEqual(core.Handle.Kind.attachment_state, canonical.header.kind);
    try std.testing.expect(canonical.header.isAlive(&guard));
    try canonical.header.retainLeaseLocked(&guard);
    try canonical.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), canonical.header.user_reference_count);
    try std.testing.expect(canonical.header.isAlive(&guard));
    try std.testing.expectError(error.ResourceInUse, arena.objects.preflightDeinitLocked(&guard));
    try canonical.header.acquireUserLocked(&guard);
    try std.testing.expectEqual(@as(u32, 1), canonical.header.user_reference_count);
    try canonical.header.releaseUserLocked(&guard, std.testing.io);
    canonical.header.releaseLeaseLocked(&guard, std.testing.io);
    try std.testing.expectEqual(core.ObjectState.destroyed, canonical.header.state);
    try std.testing.expect(!canonical.header.node.linked);
    try std.testing.expectEqual(@as(u64, 0), arena.objects.total_reference_count);
}

test "API depth formats remain distinct even if a backend maps them to one native format" {
    const api = @import("../api/enums.zig");
    var layout = testLayout();
    layout.color_formats = &.{};
    layout.depth_stencil_format = @intFromEnum(api.TextureFormat.depth24_plus);
    const depth24 = try AttachmentState.fromRenderPipeline(layout, test_limits);
    layout.depth_stencil_format = @intFromEnum(api.TextureFormat.depth32_float);
    const depth32 = try AttachmentState.fromRenderPipeline(layout, test_limits);
    try std.testing.expect(!AttachmentState.eql(&depth24, &depth32));
    try std.testing.expectEqual(@intFromEnum(api.TextureFormat.depth24_plus), depth24.depth_stencil_format);
    try std.testing.expectEqual(@intFromEnum(api.TextureFormat.depth32_float), depth32.depth_stencil_format);
}

test "pass storage shares checked offset size and declaration bounds with layouts" {
    const cases = [_]struct {
        total_size: u64,
        attachments: []const PassStorageSlot,
        limits: AttachmentLimits = test_limits,
        expected: AttachmentError,
    }{
        .{ .total_size = 3, .attachments = &.{}, .expected = error.PixelLocalStorageSizeInvalid },
        .{ .total_size = 20, .attachments = &.{}, .expected = error.PixelLocalStorageSizeInvalid },
        .{ .total_size = 4, .attachments = &.{
            .{ .offset = 1, .view = testColor(11, 1) },
        }, .expected = error.PixelLocalStorageOffsetUnaligned },
        .{ .total_size = 4, .attachments = &.{
            .{ .offset = 4, .view = testColor(11, 1) },
        }, .expected = error.PixelLocalStorageOffsetOutOfRange },
        .{ .total_size = 16, .attachments = &.{
            .{ .offset = std.math.maxInt(u64) - 3, .view = testColor(11, 1) },
        }, .expected = error.PixelLocalStorageOffsetOutOfRange },
        .{ .total_size = 8, .attachments = &.{
            .{ .offset = 0, .view = testColor(11, 1) },
            .{ .offset = 0, .view = testColor(22, 1) },
        }, .expected = error.PixelLocalStorageOffsetDuplicate },
        .{ .total_size = 4, .attachments = &.{
            .{ .offset = 0, .view = testColor(0, 1) },
        }, .expected = error.NoncanonicalAttachmentState },
        .{ .total_size = 4, .attachments = &.{
            .{ .offset = 0, .view = .{ .format = 11, .sample_count = 1, .aspects = 8 } },
        }, .expected = error.InvalidAttachmentAspect },
        .{ .total_size = 4, .attachments = &.{
            .{ .offset = 0, .view = testColor(11, 2) },
        }, .expected = error.AttachmentSampleCountUnsupported },
        .{ .total_size = 0, .attachments = &.{
            .{ .offset = 0, .view = testColor(11, 1) },
        }, .expected = error.PixelLocalStorageAttachmentCountExceeded },
        .{ .total_size = 8, .attachments = &.{
            .{ .offset = 0, .view = testColor(11, 1) },
            .{ .offset = 4, .view = testColor(22, 1) },
        }, .limits = .{
            .max_color_attachments = 8,
            .max_storage_attachments = 1,
            .max_pls_bytes = 16,
        }, .expected = error.PixelLocalStorageAttachmentCountExceeded },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, AttachmentState.fromRenderPass(.{
            .colors = &.{},
            .depth_stencil = null,
            .pls = .{ .total_size = case.total_size, .attachments = case.attachments },
        }, case.limits));
    }
}

test "effective color limit applies to pass holes and zero storage limit allows undeclared slots" {
    var limits = test_limits;
    limits.max_color_attachments = 1;
    try std.testing.expectError(error.TooManyAttachments, AttachmentState.fromRenderPass(.{
        .colors = &.{
            .{ .view = testColor(11, 1), .resolve_target = null, .expands_resolve = false },
            .{ .view = null, .resolve_target = null, .expands_resolve = false },
        },
        .depth_stencil = null,
        .pls = null,
    }, limits));
    limits.max_storage_attachments = 0;
    var layout = testLayout();
    layout.color_formats = &.{};
    layout.pls = .{ .total_size = 16, .attachments = &.{} };
    const holes = try AttachmentState.fromRenderPipeline(layout, limits);
    try std.testing.expectEqual(@as(u32, 4), holes.storage_attachment_slot_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, holes.storageAttachmentPacking());
    layout.pls = .{ .total_size = 4, .attachments = &.{.{ .offset = 0, .format = 11 }} };
    try std.testing.expectError(error.PixelLocalStorageAttachmentCountExceeded, AttachmentState.fromRenderBundle(layout, limits));
}

test "pass and bundle storage metadata share the same complete canonical identity" {
    var layout = testLayout();
    layout.pls = .{ .total_size = 16, .attachments = &.{
        .{ .offset = 4, .format = 44 }, .{ .offset = 12, .format = 55 },
    } };
    const bundle = try AttachmentState.fromRenderBundle(layout, test_limits);
    const pass = try AttachmentState.fromRenderPass(.{
        .colors = &.{
            .{ .view = testColor(11, 4), .resolve_target = null, .expands_resolve = false },
            .{ .view = null, .resolve_target = null, .expands_resolve = false },
            .{ .view = testColor(22, 4), .resolve_target = null, .expands_resolve = false },
        },
        .depth_stencil = .{ .format = 33, .sample_count = 4, .aspects = 2 },
        .pls = .{ .total_size = 16, .attachments = &.{
            .{ .offset = 12, .view = testColor(55, 4) },
            .{ .offset = 4, .view = testColor(44, 4) },
        } },
    }, test_limits);
    try std.testing.expect(AttachmentState.eql(&pass, &bundle));
    try std.testing.expectEqual(pass.computeContentHash(), bundle.computeContentHash());
}

test "canonical early retirement preserves real alias identity until the final release" {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    defer guard.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, &guard) catch @panic("attachment references leaked");
    const canonical = try arena.create(std.testing.allocator, &guard, CanonicalAttachmentState, .{
        .kind = .attachment_state,
        .initial_reference = .user,
    });
    canonical.value = try AttachmentState.fromRenderPipeline(testLayout(), test_limits);
    canonical.cache_hash = 0;
    canonical.cache_next = null;
    canonical.header.attach(&guard, std.testing.io);
    try canonical.header.retainLeaseLocked(&guard);
    canonical.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expect(!canonical.header.isAlive(&guard));
    try std.testing.expect(canonical.header.node.linked);
    try std.testing.expectEqual(@as(u32, 2), canonical.header.reference_count);
    try std.testing.expectError(error.ResourceDestroyed, canonical.header.acquireUserLocked(&guard));
    try std.testing.expectEqual(@as(u32, 2), canonical.header.reference_count);
    try canonical.header.releaseUserLocked(&guard, std.testing.io);
    canonical.header.releaseLeaseLocked(&guard, std.testing.io);
    try std.testing.expect(!canonical.header.node.linked);
    try std.testing.expectEqual(@as(u64, 0), arena.objects.total_reference_count);
}

test "resolve targets never supply or widen the source sample count" {
    inline for (.{ @as(u32, 0), @as(u32, 2), @as(u32, 8) }) |samples| {
        try std.testing.expectError(error.InvalidAttachmentResolve, AttachmentState.fromRenderPass(.{
            .colors = &.{.{
                .view = testColor(11, 4),
                .resolve_target = testColor(11, samples),
                .expands_resolve = false,
            }},
            .depth_stencil = null,
            .pls = null,
        }, test_limits));
    }
}

test "canonical builders own values rather than borrowed descriptor storage" {
    var formats = [_]u32{ 11, 0, 22 };
    var slots = [_]StorageSlot{.{ .offset = 12, .format = 44 }};
    var layout = testLayout();
    layout.color_formats = &formats;
    layout.pls = .{ .total_size = 16, .attachments = &slots };
    const state = try AttachmentState.fromRenderPipeline(layout, test_limits);
    const hash = state.computeContentHash();
    formats[0] = 99;
    slots[0].format = 55;
    slots[0].offset = 0;
    try std.testing.expectEqual(@as(u32, 11), state.colorAttachmentFormat(0));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 44 }, state.storageAttachmentPacking());
    try std.testing.expectEqual(hash, state.computeContentHash());
}

test "canonical hash encodes each semantic scalar without aggregate padding" {
    var layout = testLayout();
    layout.expand_resolve = .{
        .attachments_to_expand_resolve = 1,
        .resolve_targets_mask = 5,
    };
    layout.pls = .{ .total_size = 16, .attachments = &.{
        .{ .offset = 12, .format = 44 },
    } };
    const state = try AttachmentState.fromRenderPipeline(layout, test_limits);
    const scalars = [_]u32{
        5,
        11,
        0,
        22,
        0,
        0,
        0,
        0,
        0,
        33,
        4,
        1,
        5,
        1,
        4,
        0,
        0,
        0,
        44,
    };
    var bytes: [scalars.len * 4]u8 = undefined;
    for (scalars, 0..) |scalar, index| {
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], scalar, .little);
    }
    try std.testing.expectEqual(
        std.hash.Wyhash.hash(0x6465_7363_0E15_0001, &bytes),
        state.computeContentHash(),
    );
}
