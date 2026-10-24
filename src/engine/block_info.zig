//! Typed texel/block units and exact conversions from Dawn BlockInfo.h.
//! Values own no resources. Construct with field literals and compare with `std.meta.eql`.
const std = @import("std");
const descriptors = @import("../api/descriptors.zig");
const format = @import("format.zig");

test "typed origins and extents preserve defaults and API values" {
    try std.testing.expect(std.meta.eql(TexelOrigin3D{}, TexelOrigin3D.fromOrigin3D(.{})));
    try std.testing.expect(std.meta.eql(BlockOrigin3D{}, BlockOrigin3D{
        .x = .{ .value = 0 },
        .y = .{ .value = 0 },
        .z = .{ .value = 0 },
    }));
    const extent: TexelExtent3D = .{};
    try std.testing.expectEqual(@as(u64, 0), extent.width.value);
    try std.testing.expectEqual(@as(u64, 1), extent.height.value);
    try std.testing.expectEqual(@as(u64, 1), extent.depth_or_array_layers.value);
    try std.testing.expect(extent.isEmpty());
    try std.testing.expect((BlockExtent3D{}).isEmpty());
    const origin_api: descriptors.Origin3D = .{ .x = 9, .y = 12, .z = 7 };
    try std.testing.expect(std.meta.eql(origin_api, try TexelOrigin3D.fromOrigin3D(origin_api).toOrigin3D()));
    const extent_api: descriptors.Extent3D = .{
        .width = 24,
        .height = 16,
        .depth_or_array_layers = 3,
    };
    const typed_extent = TexelExtent3D.fromExtent3D(extent_api);
    try std.testing.expect(!typed_extent.isEmpty());
    try std.testing.expect(std.meta.eql(extent_api, try typed_extent.toExtent3D()));
    inline for (.{ "width", "height", "depth_or_array_layers" }) |field| {
        var texels = typed_extent;
        @field(texels, field).value = 0;
        try std.testing.expect(texels.isEmpty());
        var blocks: BlockExtent3D = .{ .width = .{ .value = 2 } };
        @field(blocks, field).value = 0;
        try std.testing.expect(blocks.isEmpty());
    }
}

test "block conversions are exact for uncompressed and compressed shapes" {
    inline for (.{
        format.TexelBlockInfo{ .byte_size = 4, .width = 1, .height = 1 },
        format.TexelBlockInfo{ .byte_size = 16, .width = 4, .height = 4 },
        format.TexelBlockInfo{ .byte_size = 16, .width = 5, .height = 4 },
    }) |raw| {
        const info = TypedTexelBlockInfo.fromTexelBlockInfo(raw);
        try std.testing.expect(std.meta.eql(raw, try info.toTexelBlockInfo()));
        try std.testing.expectEqual(@as(u64, 3 * raw.byte_size), try info.toBytes(.{ .value = 3 }));
        try std.testing.expectEqual(@as(u64, 3), (try info.bytesToBlocks(3 * raw.byte_size)).value);
        const origin: BlockOrigin3D = .{
            .x = .{ .value = 2 },
            .y = .{ .value = 3 },
            .z = .{ .value = 7 },
        };
        const texel_origin = try info.toTexelOrigin(origin);
        try std.testing.expectEqual(@as(u64, 2 * raw.width), texel_origin.x.value);
        try std.testing.expectEqual(@as(u64, 3 * raw.height), texel_origin.y.value);
        try std.testing.expectEqual(@as(u64, 7), texel_origin.z.value);
        try std.testing.expect(std.meta.eql(origin, try info.toBlockOrigin(texel_origin)));
        const extent: BlockExtent3D = .{
            .width = .{ .value = 2 },
            .height = .{ .value = 3 },
            .depth_or_array_layers = .{ .value = 7 },
        };
        const texel_extent = try info.toTexelExtent(extent);
        try std.testing.expect(std.meta.eql(extent, try info.toBlockExtent(texel_extent)));
        try std.testing.expectEqual(@as(u64, 7), texel_extent.depth_or_array_layers.value);
        try std.testing.expectEqual(@as(u64, 0), (try info.toBlockWidth(.{ .value = 0 })).value);
    }
}

test "block conversions reject fractional counts and zero block metadata" {
    const info: TypedTexelBlockInfo = .{
        .byte_size = 16,
        .width = .{ .value = 4 },
        .height = .{ .value = 4 },
    };
    try std.testing.expectError(error.NonExactDivision, info.bytesToBlocks(17));
    try std.testing.expectError(error.NonExactDivision, info.toBlockWidth(.{ .value = 5 }));
    try std.testing.expectError(error.NonExactDivision, info.toBlockHeight(.{ .value = 5 }));
    inline for (.{ "byte_size", "width", "height" }) |field| {
        var invalid = info;
        if (comptime std.mem.eql(u8, field, "byte_size")) {
            invalid.byte_size = 0;
        } else {
            @field(invalid, field).value = 0;
        }
        try std.testing.expectError(error.InvalidBlockInfo, invalid.toBytes(.{ .value = 0 }));
        try std.testing.expectError(error.InvalidBlockInfo, invalid.bytesToBlocks(0));
        try std.testing.expectError(error.InvalidBlockInfo, invalid.toBlockWidth(.{ .value = 0 }));
        try std.testing.expectError(error.InvalidBlockInfo, invalid.toBlockHeight(.{ .value = 0 }));
        try std.testing.expectError(error.InvalidBlockInfo, invalid.toTexelWidth(.{ .value = 0 }));
        try std.testing.expectError(error.InvalidBlockInfo, invalid.toTexelHeight(.{ .value = 0 }));
    }
    try std.testing.expectEqual(std.math.maxInt(u64), info.toBlockDepth(.{ .value = std.math.maxInt(u64) }).value);
    try std.testing.expectEqual(std.math.maxInt(u64), info.toTexelDepth(.{ .value = std.math.maxInt(u64) }).value);
}

test "block multiplication and API narrowing fail without truncation" {
    const maximum = std.math.maxInt(u64);
    const too_wide: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    const info: TypedTexelBlockInfo = .{
        .byte_size = 16,
        .width = .{ .value = 4 },
        .height = .{ .value = 4 },
    };
    try std.testing.expectError(error.Overflow, info.toBytes(.{ .value = maximum }));
    try std.testing.expectError(error.Overflow, info.toTexelWidth(.{ .value = maximum }));
    try std.testing.expectError(error.Overflow, info.toTexelHeight(.{ .value = maximum }));
    inline for (.{ "x", "y", "z" }) |field| {
        var origin: TexelOrigin3D = .{};
        @field(origin, field).value = too_wide;
        try std.testing.expectError(error.NarrowingOverflow, origin.toOrigin3D());
    }
    inline for (.{ "width", "height", "depth_or_array_layers" }) |field| {
        var extent: TexelExtent3D = .{};
        @field(extent, field).value = too_wide;
        try std.testing.expectError(error.NarrowingOverflow, extent.toExtent3D());
    }
    inline for (.{ "width", "height" }) |field| {
        var large = info;
        @field(large, field).value = too_wide;
        try std.testing.expectError(error.NarrowingOverflow, large.toTexelBlockInfo());
    }
    const boundary = TexelOrigin3D.fromOrigin3D(.{ .x = std.math.maxInt(u32) });
    try std.testing.expectEqual(std.math.maxInt(u32), (try boundary.toOrigin3D()).x);
}

pub const TexelCount = struct { value: u64 };
pub const BlockCount = struct { value: u64 };

pub const NarrowError = error{NarrowingOverflow};
pub const ConversionError = error{ InvalidBlockInfo, NonExactDivision, Overflow };

pub const TexelOrigin3D = struct {
    x: TexelCount = .{ .value = 0 },
    y: TexelCount = .{ .value = 0 },
    z: TexelCount = .{ .value = 0 },

    pub fn fromOrigin3D(origin: descriptors.Origin3D) TexelOrigin3D {
        return .{
            .x = .{ .value = origin.x },
            .y = .{ .value = origin.y },
            .z = .{ .value = origin.z },
        };
    }

    pub fn toOrigin3D(self: TexelOrigin3D) NarrowError!descriptors.Origin3D {
        return .{
            .x = try narrow(self.x.value),
            .y = try narrow(self.y.value),
            .z = try narrow(self.z.value),
        };
    }
};

pub const BlockOrigin3D = struct {
    x: BlockCount = .{ .value = 0 },
    y: BlockCount = .{ .value = 0 },
    z: BlockCount = .{ .value = 0 },
};

pub const TexelExtent3D = struct {
    width: TexelCount = .{ .value = 0 },
    height: TexelCount = .{ .value = 1 },
    depth_or_array_layers: TexelCount = .{ .value = 1 },

    pub fn fromExtent3D(extent: descriptors.Extent3D) TexelExtent3D {
        return .{
            .width = .{ .value = extent.width },
            .height = .{ .value = extent.height },
            .depth_or_array_layers = .{ .value = extent.depth_or_array_layers },
        };
    }

    pub fn toExtent3D(self: TexelExtent3D) NarrowError!descriptors.Extent3D {
        return .{
            .width = try narrow(self.width.value),
            .height = try narrow(self.height.value),
            .depth_or_array_layers = try narrow(self.depth_or_array_layers.value),
        };
    }

    pub fn isEmpty(self: TexelExtent3D) bool {
        return self.width.value == 0 or self.height.value == 0 or
            self.depth_or_array_layers.value == 0;
    }
};

pub const BlockExtent3D = struct {
    width: BlockCount = .{ .value = 0 },
    height: BlockCount = .{ .value = 1 },
    depth_or_array_layers: BlockCount = .{ .value = 1 },

    pub fn isEmpty(self: BlockExtent3D) bool {
        return self.width.value == 0 or self.height.value == 0 or
            self.depth_or_array_layers.value == 0;
    }
};

/// A zero default is unset metadata. Arithmetic rejects any zero block field.
/// Depth conversions are identities because blocks are two-dimensional.
pub const TypedTexelBlockInfo = struct {
    byte_size: u32 = 0,
    width: TexelCount = .{ .value = 0 },
    height: TexelCount = .{ .value = 0 },

    pub fn fromTexelBlockInfo(info: format.TexelBlockInfo) TypedTexelBlockInfo {
        return .{
            .byte_size = info.byte_size,
            .width = .{ .value = info.width },
            .height = .{ .value = info.height },
        };
    }

    pub fn toTexelBlockInfo(self: TypedTexelBlockInfo) NarrowError!format.TexelBlockInfo {
        return .{
            .byte_size = self.byte_size,
            .width = try narrow(self.width.value),
            .height = try narrow(self.height.value),
        };
    }

    pub fn toBytes(self: TypedTexelBlockInfo, value: BlockCount) ConversionError!u64 {
        try self.validate();
        return multiply(value.value, self.byte_size);
    }

    pub fn bytesToBlocks(self: TypedTexelBlockInfo, byte_count: u64) ConversionError!BlockCount {
        try self.validate();
        return .{ .value = try divideExact(byte_count, self.byte_size) };
    }

    pub fn toBlockHeight(self: TypedTexelBlockInfo, value: TexelCount) ConversionError!BlockCount {
        try self.validate();
        return .{ .value = try divideExact(value.value, self.height.value) };
    }

    pub fn toBlockWidth(self: TypedTexelBlockInfo, value: TexelCount) ConversionError!BlockCount {
        try self.validate();
        return .{ .value = try divideExact(value.value, self.width.value) };
    }

    pub fn toBlockDepth(_: TypedTexelBlockInfo, value: TexelCount) BlockCount {
        return .{ .value = value.value };
    }

    pub fn toTexelWidth(self: TypedTexelBlockInfo, value: BlockCount) ConversionError!TexelCount {
        try self.validate();
        return .{ .value = try multiply(value.value, self.width.value) };
    }

    pub fn toTexelHeight(self: TypedTexelBlockInfo, value: BlockCount) ConversionError!TexelCount {
        try self.validate();
        return .{ .value = try multiply(value.value, self.height.value) };
    }

    pub fn toTexelDepth(_: TypedTexelBlockInfo, value: BlockCount) TexelCount {
        return .{ .value = value.value };
    }

    pub fn toBlockOrigin(
        self: TypedTexelBlockInfo,
        origin: TexelOrigin3D,
    ) ConversionError!BlockOrigin3D {
        return .{
            .x = try self.toBlockWidth(origin.x),
            .y = try self.toBlockHeight(origin.y),
            .z = self.toBlockDepth(origin.z),
        };
    }

    pub fn toBlockExtent(
        self: TypedTexelBlockInfo,
        extent: TexelExtent3D,
    ) ConversionError!BlockExtent3D {
        return .{
            .width = try self.toBlockWidth(extent.width),
            .height = try self.toBlockHeight(extent.height),
            .depth_or_array_layers = self.toBlockDepth(extent.depth_or_array_layers),
        };
    }

    pub fn toTexelOrigin(
        self: TypedTexelBlockInfo,
        origin: BlockOrigin3D,
    ) ConversionError!TexelOrigin3D {
        return .{
            .x = try self.toTexelWidth(origin.x),
            .y = try self.toTexelHeight(origin.y),
            .z = self.toTexelDepth(origin.z),
        };
    }

    pub fn toTexelExtent(
        self: TypedTexelBlockInfo,
        extent: BlockExtent3D,
    ) ConversionError!TexelExtent3D {
        return .{
            .width = try self.toTexelWidth(extent.width),
            .height = try self.toTexelHeight(extent.height),
            .depth_or_array_layers = self.toTexelDepth(extent.depth_or_array_layers),
        };
    }

    fn validate(self: TypedTexelBlockInfo) ConversionError!void {
        if (self.byte_size == 0) return error.InvalidBlockInfo;
        if (self.width.value == 0) return error.InvalidBlockInfo;
        if (self.height.value == 0) return error.InvalidBlockInfo;
    }
};

fn narrow(value: u64) NarrowError!u32 {
    return std.math.cast(u32, value) orelse error.NarrowingOverflow;
}

fn multiply(value: u64, factor: u64) ConversionError!u64 {
    const product = @mulWithOverflow(value, factor);
    if (product[1] != 0) return error.Overflow;
    return product[0];
}

fn divideExact(value: u64, divisor: u64) ConversionError!u64 {
    if (divisor == 0) return error.InvalidBlockInfo;
    if (value % divisor != 0) return error.NonExactDivision;
    return @divExact(value, divisor);
}

test "aggregate equality compares every typed coordinate" {
    inline for (.{ TexelOrigin3D, BlockOrigin3D, TexelExtent3D, BlockExtent3D }) |T| {
        const original: T = .{};
        try std.testing.expect(std.meta.eql(original, original));
        inline for (@typeInfo(T).@"struct".field_names) |field_name| {
            var changed = original;
            @field(changed, field_name).value += 1;
            try std.testing.expect(!std.meta.eql(original, changed));
        }
    }
}
