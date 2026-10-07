//! Scalar override conversion for native SPIR-V programmable stages.
//! Reflection owns declaration discovery; this module does not rewrite shader words.
//! Keep `Specialization` alive until the Vulkan pipeline creation call returns.

const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/root.zig");
const spirv = @import("../spirv/root.zig");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

/// Override validation and failure-atomic allocation errors.
pub const Error = error{
    OutOfMemory,
    UnknownConstant,
    DuplicateConstant,
    AmbiguousConstant,
    NonFiniteConstant,
    ConstantOutOfRange,
    UnsupportedConstantType,
    TooManyConstants,
};

const Converted = struct {
    spec_id: u32,
    bits: u64,
    type_tag: u8,
    width: u8,
    size: u8,

    fn lessThan(_: void, lhs: Converted, rhs: Converted) bool {
        return lhs.spec_id < rhs.spec_id;
    }
};

/// Owns `map_entries` and `payload`; `data` and `canonical_bytes` borrow `payload`.
/// Copies share storage and are not additional owners.
/// Inputs are borrowed only during `init`; no stable address for this value is required.
pub const Specialization = struct {
    /// Sorted by SpecId; offsets address the tightly packed native-endian `data`.
    map_entries: []vulkan.VkSpecializationMapEntry,
    /// One owned allocation backing both byte views; release only through `deinit`.
    payload: []u8,
    /// Native-endian Vulkan byte view, invalidated by `deinit`.
    data: []u8,
    /// Sorted records: u32 LE SpecId, u8 type, u8 width, u8 size, then size LE bits.
    /// Type tags are boolean=0, signed=1, unsigned=2, float=3. No ABI padding is encoded.
    /// Shared-ID families use their smallest (type tag, width) tuple after bits and sizes agree.
    canonical_bytes: []u8,

    const empty: Specialization = .{
        .map_entries = &.{},
        .payload = &.{},
        .data = &.{},
        .canonical_bytes = &.{},
    };

    /// Resolves canonical decimal SpecIds or unambiguous names and converts finite f64 values.
    /// Integer raw values must lie in range before truncation toward zero.
    /// Every declaration sharing the resolved SpecId must convert to equal size and raw bits;
    /// disagreement is `error.AmbiguousConstant`. Per-declaration conversion errors survive.
    /// On error, releases all partial storage. Empty overrides allocate nothing.
    pub fn init(
        allocator: std.mem.Allocator,
        metadata: []const spirv.SpecializationConstant,
        constants: []const api.ConstantEntry,
    ) Error!Specialization {
        if (constants.len == 0) return empty;
        // Both the Vulkan entry count and its byte offsets have u32 limits.
        if (constants.len > std.math.maxInt(u32) / 15) return error.TooManyConstants;
        const converted = try allocator.alloc(Converted, constants.len);
        defer allocator.free(converted);
        var data_size: usize = 0;
        for (constants, 0..) |constant, index| {
            const declaration = try resolve(metadata, constant.key);
            converted[index] = try convertFamily(metadata, declaration.spec_id, constant.value);
            data_size = std.math.add(usize, data_size, converted[index].size) catch {
                return error.TooManyConstants;
            };
        }
        std.mem.sort(Converted, converted, {}, Converted.lessThan);
        for (converted[1..], converted[0 .. converted.len - 1]) |value, previous| {
            if (value.spec_id == previous.spec_id) return error.DuplicateConstant;
        }
        const header_size = std.math.mul(usize, constants.len, 7) catch {
            return error.TooManyConstants;
        };
        const canonical_size = std.math.add(usize, data_size, header_size) catch {
            return error.TooManyConstants;
        };
        const payload_size = std.math.add(usize, data_size, canonical_size) catch {
            return error.TooManyConstants;
        };
        const map_entries = try allocator.alloc(vulkan.VkSpecializationMapEntry, constants.len);
        errdefer allocator.free(map_entries);
        const payload = try allocator.alloc(u8, payload_size);
        errdefer allocator.free(payload);
        const data = payload[0..data_size];
        const canonical_bytes = payload[data_size..];
        var data_offset: usize = 0;
        var key_offset: usize = 0;
        for (converted, map_entries) |value, *map_entry| {
            map_entry.* = .{
                .constantID = value.spec_id,
                .offset = @intCast(data_offset),
                .size = value.size,
            };
            writeBits(data[data_offset..][0..value.size], value.bits, native_endian);
            std.mem.writeInt(u32, canonical_bytes[key_offset..][0..4], value.spec_id, .little);
            canonical_bytes[key_offset + 4] = value.type_tag;
            canonical_bytes[key_offset + 5] = value.width;
            canonical_bytes[key_offset + 6] = value.size;
            writeBits(canonical_bytes[key_offset + 7 ..][0..value.size], value.bits, .little);
            data_offset += value.size;
            key_offset += 7 + @as(usize, value.size);
        }
        return .{
            .map_entries = map_entries,
            .payload = payload,
            .data = data,
            .canonical_bytes = canonical_bytes,
        };
    }

    /// Releases owned storage using the allocator passed to `init`, then invalidates this value.
    /// Slices and Vulkan views are invalidated; copies must not be released or used.
    pub fn deinit(self: *Specialization, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.map_entries);
        self.* = undefined;
    }

    /// Returns a non-owning Vulkan view, valid until `deinit`.
    /// The returned value contains no pointer to this struct.
    pub fn info(self: *const Specialization) vulkan.VkSpecializationInfo {
        return .{
            .mapEntryCount = @intCast(self.map_entries.len),
            .pMapEntries = if (self.map_entries.len == 0) null else self.map_entries.ptr,
            .dataSize = self.data.len,
            .pData = if (self.data.len == 0) null else self.data.ptr,
        };
    }
};

fn resolve(
    metadata: []const spirv.SpecializationConstant,
    key: []const u8,
) Error!spirv.SpecializationConstant {
    const numeric = canonicalId(key);
    var found: ?spirv.SpecializationConstant = null;
    for (metadata) |declaration| {
        const matches = if (numeric) |id|
            declaration.spec_id == id
        else
            declaration.name.len != 0 and std.mem.eql(u8, declaration.name, key);
        if (matches) {
            if (found) |previous| {
                if (previous.spec_id != declaration.spec_id) return error.AmbiguousConstant;
            } else {
                found = declaration;
            }
        }
    }
    return found orelse error.UnknownConstant;
}

fn convertFamily(
    metadata: []const spirv.SpecializationConstant,
    spec_id: u32,
    value: f64,
) Error!Converted {
    var result: ?Converted = null;
    var ambiguous = false;
    for (metadata) |declaration| {
        if (declaration.spec_id != spec_id) continue;
        const converted = try convert(declaration.scalar_type, value);
        if (result) |*previous| {
            if (previous.size != converted.size or previous.bits != converted.bits) {
                ambiguous = true;
            }
            // Canonical type identity cannot depend on which alias or declaration came first.
            if (converted.type_tag < previous.type_tag or
                (converted.type_tag == previous.type_tag and converted.width < previous.width))
            {
                previous.type_tag = converted.type_tag;
                previous.width = converted.width;
            }
        } else {
            result = converted;
        }
    }
    if (ambiguous) return error.AmbiguousConstant;
    // `resolve` established at least one declaration with this SpecId.
    var normalized = result orelse return error.UnknownConstant;
    normalized.spec_id = spec_id;
    return normalized;
}

fn canonicalId(key: []const u8) ?u32 {
    if (key.len == 0 or key.len > 10) return null;
    if (key.len > 1 and key[0] == '0') return null;
    var id: u32 = 0;
    for (key) |byte| {
        if (byte < '0' or byte > '9') return null;
        const product = @mulWithOverflow(id, 10);
        if (product[1] != 0) return null;
        const sum = @addWithOverflow(product[0], @as(u32, byte - '0'));
        if (sum[1] != 0) return null;
        id = sum[0];
    }
    return id;
}

fn convert(scalar_type: spirv.ScalarType, value: f64) Error!Converted {
    if (!std.math.isFinite(value)) return error.NonFiniteConstant;
    switch (scalar_type) {
        .boolean => return .{
            .spec_id = 0,
            .bits = @intFromBool(value != 0),
            .type_tag = 0,
            .width = 32,
            .size = 4,
        },
        .signed_integer => |width| switch (width) {
            8 => return convertInteger(i8, value),
            16 => return convertInteger(i16, value),
            32 => return convertInteger(i32, value),
            64 => return convertInteger(i64, value),
            else => return error.UnsupportedConstantType,
        },
        .unsigned_integer => |width| switch (width) {
            8 => return convertInteger(u8, value),
            16 => return convertInteger(u16, value),
            32 => return convertInteger(u32, value),
            64 => return convertInteger(u64, value),
            else => return error.UnsupportedConstantType,
        },
        .float => |width| switch (width) {
            16 => return convertFloat(f16, value),
            32 => return convertFloat(f32, value),
            64 => return convertFloat(f64, value),
            else => return error.UnsupportedConstantType,
        },
    }
}

fn convertInteger(comptime T: type, value: f64) Error!Converted {
    const signed = @typeInfo(T).int.signedness == .signed;
    const minimum: f64 = @floatFromInt(std.math.minInt(T));
    if (value < minimum) return error.ConstantOutOfRange;
    if (@bitSizeOf(T) == 64) {
        // f64 rounds maxInt(i64/u64) up to the first non-representable integer.
        const exclusive_maximum: f64 = if (signed) 0x1p63 else 0x1p64;
        if (value >= exclusive_maximum) return error.ConstantOutOfRange;
    } else {
        const maximum: f64 = @floatFromInt(std.math.maxInt(T));
        if (value > maximum) return error.ConstantOutOfRange;
    }
    const integer: T = @intFromFloat(value);
    const bits: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(integer);
    return .{
        .spec_id = 0,
        .bits = bits,
        .type_tag = if (signed) 1 else 2,
        .width = @bitSizeOf(T),
        .size = @sizeOf(T),
    };
}

fn convertFloat(comptime T: type, value: f64) Error!Converted {
    const maximum: f64 = std.math.floatMax(T);
    if (@abs(value) > maximum) return error.ConstantOutOfRange;
    const rounded: T = @floatCast(value);
    const bits: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(rounded);
    return .{
        .spec_id = 0,
        .bits = bits,
        .type_tag = 3,
        .width = @bitSizeOf(T),
        .size = @sizeOf(T),
    };
}

fn writeBits(bytes: []u8, bits: u64, endian: std.builtin.Endian) void {
    for (bytes, 0..) |*byte, index| {
        const significance = if (endian == .little) index else bytes.len - 1 - index;
        byte.* = @truncate(bits >> @as(u6, @intCast(significance * 8)));
    }
}

const test_metadata = [_]spirv.SpecializationConstant{
    .{ .result_id = 10, .spec_id = 7, .name = "count", .scalar_type = .{ .unsigned_integer = 32 } },
    .{ .result_id = 11, .spec_id = 2, .name = "enabled", .scalar_type = .boolean },
    .{ .result_id = 12, .spec_id = 9, .name = "half", .scalar_type = .{ .float = 16 } },
};

test "specialization resolves aliases and sorts actual Vulkan payload offsets" {
    var first = try Specialization.init(std.testing.allocator, &test_metadata, &.{
        .{ .key = "count", .value = 3.9 },
        .{ .key = "enabled", .value = -2 },
        .{ .key = "half", .value = 1 },
    });
    defer first.deinit(std.testing.allocator);
    var second = try Specialization.init(std.testing.allocator, &test_metadata, &.{
        .{ .key = "9", .value = 1 },
        .{ .key = "2", .value = 1 },
        .{ .key = "7", .value = 3 },
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.data, second.data);
    try std.testing.expectEqualSlices(u8, first.canonical_bytes, second.canonical_bytes);
    try std.testing.expectEqual(@as(u32, 2), first.map_entries[0].constantID);
    try std.testing.expectEqual(@as(u32, 0), first.map_entries[0].offset);
    try std.testing.expectEqual(@as(usize, 4), first.map_entries[0].size);
    try std.testing.expectEqual(@as(u32, 4), first.map_entries[1].offset);
    try std.testing.expectEqual(@as(u32, 8), first.map_entries[2].offset);
    try std.testing.expectEqual(@as(usize, 10), first.data.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, first.data[0..4], native_endian));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, first.data[4..8], native_endian));
    try std.testing.expectEqual(
        @as(u16, 0x3c00),
        std.mem.readInt(u16, first.data[8..10], native_endian),
    );
    const info = first.info();
    try std.testing.expectEqual(first.data.ptr, @as([*]const u8, @ptrCast(info.pData.?)));
    try std.testing.expect(first.map_entries.ptr == info.pMapEntries);
    try std.testing.expectEqual(@as(u32, 3), info.mapEntryCount);
}

test "specialization rejects unknown duplicate and ambiguous keys" {
    try std.testing.expectError(
        error.UnknownConstant,
        Specialization.init(std.testing.allocator, &test_metadata, &.{
            .{ .key = "missing", .value = 1 },
        }),
    );
    try std.testing.expectError(
        error.UnknownConstant,
        Specialization.init(std.testing.allocator, &test_metadata, &.{
            .{ .key = "07", .value = 1 },
        }),
    );
    try std.testing.expectError(
        error.DuplicateConstant,
        Specialization.init(std.testing.allocator, &test_metadata, &.{
            .{ .key = "7", .value = 1 }, .{ .key = "count", .value = 1 },
        }),
    );
    const ambiguous = [_]spirv.SpecializationConstant{
        .{ .result_id = 1, .spec_id = 1, .name = "same", .scalar_type = .boolean },
        .{ .result_id = 2, .spec_id = 2, .name = "same", .scalar_type = .boolean },
    };
    try std.testing.expectError(
        error.AmbiguousConstant,
        Specialization.init(std.testing.allocator, &ambiguous, &.{
            .{ .key = "same", .value = 1 },
        }),
    );
}

fn expectScalar(scalar_type: spirv.ScalarType, value: f64, bits: u64) !void {
    const metadata = [_]spirv.SpecializationConstant{
        .{ .result_id = 1, .spec_id = 1, .name = "", .scalar_type = scalar_type },
    };
    var result = try Specialization.init(
        std.testing.allocator,
        &metadata,
        &.{.{ .key = "1", .value = value }},
    );
    defer result.deinit(std.testing.allocator);
    var actual: u64 = 0;
    for (result.canonical_bytes[7..], 0..) |byte, index| {
        actual |= @as(u64, byte) << @as(u6, @intCast(index * 8));
    }
    try std.testing.expectEqual(bits, actual);
}

fn expectScalarError(expected: Error, scalar_type: spirv.ScalarType, value: f64) !void {
    const metadata = [_]spirv.SpecializationConstant{
        .{ .result_id = 1, .spec_id = 1, .name = "", .scalar_type = scalar_type },
    };
    try std.testing.expectError(
        expected,
        Specialization.init(std.testing.allocator, &metadata, &.{
            .{ .key = "1", .value = value },
        }),
    );
}

test "specialization checks raw integer bounds before truncation at every width" {
    inline for (.{ 8, 16, 32, 64 }) |width| {
        const Signed = @Int(.signed, width);
        const Unsigned = @Int(.unsigned, width);
        const minimum: f64 = @floatFromInt(std.math.minInt(Signed));
        const signed_upper: f64 = -minimum;
        const unsigned_upper: f64 = signed_upper * 2;
        try expectScalar(
            .{ .signed_integer = width },
            minimum,
            @as(Unsigned, @bitCast(@as(Signed, std.math.minInt(Signed)))),
        );
        try expectScalar(.{ .signed_integer = width }, -1.9, std.math.maxInt(Unsigned));
        try expectScalar(.{ .unsigned_integer = width }, 1.9, 1);
        try expectScalarError(error.ConstantOutOfRange, .{ .unsigned_integer = width }, -0.1);
        try expectScalarError(
            error.ConstantOutOfRange,
            .{ .unsigned_integer = width },
            unsigned_upper,
        );
        try expectScalarError(error.ConstantOutOfRange, .{ .signed_integer = width }, signed_upper);
        try expectScalarError(error.ConstantOutOfRange, .{ .signed_integer = width }, minimum * 2);
        if (width < 64) {
            const signed_max: f64 = @floatFromInt(std.math.maxInt(Signed));
            const unsigned_max: f64 = @floatFromInt(std.math.maxInt(Unsigned));
            try expectScalar(
                .{ .signed_integer = width },
                signed_max,
                @intCast(std.math.maxInt(Signed)),
            );
            try expectScalar(
                .{ .unsigned_integer = width },
                unsigned_max,
                std.math.maxInt(Unsigned),
            );
            try expectScalarError(
                error.ConstantOutOfRange,
                .{ .signed_integer = width },
                signed_max + 0.5,
            );
            try expectScalarError(
                error.ConstantOutOfRange,
                .{ .unsigned_integer = width },
                unsigned_max + 0.5,
            );
        }
    }
    try expectScalar(.{ .signed_integer = 64 }, 9223372036854774784.0, 9223372036854774784);
    try expectScalar(.{ .unsigned_integer = 64 }, 18446744073709549568.0, 18446744073709549568);
}

test "specialization IEEE conversion preserves rounding underflow and negative zero" {
    try expectScalar(.{ .float = 16 }, 1.00048828125, 0x3c00);
    try expectScalar(.{ .float = 16 }, 1.0009765625, 0x3c01);
    try expectScalar(.{ .float = 16 }, 0x1p-24, 1);
    try expectScalar(.{ .float = 16 }, 0x1p-25, 0);
    try expectScalar(.{ .float = 16 }, -0.0, 0x8000);
    try expectScalar(.{ .float = 32 }, 1.000000059604644775390625, 0x3f800000);
    try expectScalar(.{ .float = 32 }, 0x1p-149, 1);
    try expectScalar(.{ .float = 32 }, 0x1p-150, 0);
    try expectScalar(.{ .float = 32 }, -0.0, 0x80000000);
    try expectScalar(.{ .float = 64 }, -0.0, 0x8000000000000000);
    try expectScalar(.boolean, -0.0, 0);
    try expectScalar(.boolean, 0x1p-1000, 1);
    inline for (.{ 16, 32, 64 }) |width| {
        try expectScalarError(error.NonFiniteConstant, .{ .float = width }, std.math.nan(f64));
        try expectScalarError(error.NonFiniteConstant, .{ .float = width }, std.math.inf(f64));
        try expectScalarError(error.NonFiniteConstant, .{ .float = width }, -std.math.inf(f64));
    }
    try expectScalarError(error.NonFiniteConstant, .boolean, std.math.nan(f64));
    try expectScalarError(error.NonFiniteConstant, .{ .signed_integer = 32 }, std.math.inf(f64));
    try expectScalarError(error.NonFiniteConstant, .{ .unsigned_integer = 32 }, -std.math.inf(f64));
    try expectScalarError(error.ConstantOutOfRange, .{ .float = 16 }, 65504.5);
    try expectScalarError(error.ConstantOutOfRange, .{ .float = 32 }, 0x1p128);
    try expectScalarError(error.UnsupportedConstantType, .{ .float = 8 }, 1);
    try expectScalarError(error.UnsupportedConstantType, .{ .signed_integer = 24 }, 1);
    try expectScalarError(error.UnsupportedConstantType, .{ .unsigned_integer = 0 }, 1);
}

fn allocationFailureTest(allocator: std.mem.Allocator) !void {
    var result = try Specialization.init(
        allocator,
        &test_metadata,
        &.{.{ .key = "count", .value = 12 }},
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.data.len);
}

test "specialization cleans every allocation failure and empty init allocates nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureTest, .{});
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var empty = try Specialization.init(failing.allocator(), &.{}, &.{});
    defer empty.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), empty.data.len);
    try std.testing.expectEqual(@as(u32, 0), empty.info().mapEntryCount);
    try std.testing.expectEqual(@as(?*const anyopaque, null), empty.info().pData);
}

test "specialization canonical records include type width and little endian bits" {
    const metadata = [_]spirv.SpecializationConstant{
        .{
            .result_id = 1,
            .spec_id = 0x1020304,
            .name = "x",
            .scalar_type = .{ .unsigned_integer = 16 },
        },
    };
    var result = try Specialization.init(
        std.testing.allocator,
        &metadata,
        &.{.{ .key = "x", .value = 0x1234 }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 4, 3, 2, 1, 2, 16, 2, 0x34, 0x12 },
        result.canonical_bytes,
    );
    var signed_metadata = metadata;
    signed_metadata[0].scalar_type = .{ .signed_integer = 16 };
    var signed_result = try Specialization.init(
        std.testing.allocator,
        &signed_metadata,
        &.{.{ .key = "x", .value = 0x1234 }},
    );
    defer signed_result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, result.data, signed_result.data);
    try std.testing.expect(!std.mem.eql(u8, result.canonical_bytes, signed_result.canonical_bytes));
}

test "specialization validates float extrema and nonfinite inputs at every scalar width" {
    try expectScalar(.{ .float = 16 }, 65504, 0x7bff);
    try expectScalar(.{ .float = 16 }, -65504, 0xfbff);
    try expectScalarError(error.ConstantOutOfRange, .{ .float = 16 }, -65504.5);
    try expectScalar(.{ .float = 32 }, std.math.floatMax(f32), 0x7f7fffff);
    try expectScalar(.{ .float = 32 }, -std.math.floatMax(f32), 0xff7fffff);
    try expectScalarError(error.ConstantOutOfRange, .{ .float = 32 }, -0x1p128);
    try expectScalar(.{ .float = 64 }, std.math.floatMax(f64), 0x7fefffffffffffff);
    try expectScalar(.{ .float = 64 }, -std.math.floatMax(f64), 0xffefffffffffffff);
    inline for (.{ 8, 16, 32, 64 }) |width| {
        try expectScalarError(
            error.NonFiniteConstant,
            .{ .signed_integer = width },
            std.math.nan(f64),
        );
        try expectScalarError(
            error.NonFiniteConstant,
            .{ .unsigned_integer = width },
            std.math.nan(f64),
        );
    }
    try expectScalarError(error.NonFiniteConstant, .boolean, std.math.inf(f64));
    try expectScalarError(error.NonFiniteConstant, .boolean, -std.math.inf(f64));
    try expectScalarError(error.ConstantOutOfRange, .{ .signed_integer = 8 }, -128.1);
    try expectScalarError(error.ConstantOutOfRange, .{ .signed_integer = 16 }, -32768.1);
    try expectScalarError(error.ConstantOutOfRange, .{ .signed_integer = 32 }, -2147483648.1);
}

test "specialization rejects counts beyond byte offset bounds before accessing entries" {
    // The count is checked before dereferencing this intentionally inaccessible range.
    const count = @as(usize, std.math.maxInt(u32)) / 15 + 1;
    if (count > std.math.maxInt(usize) / @sizeOf(api.ConstantEntry)) return error.SkipZigTest;
    const pointer: [*]const api.ConstantEntry = @ptrFromInt(@alignOf(api.ConstantEntry));
    const constants = pointer[0..count];
    try std.testing.expectError(
        error.TooManyConstants,
        Specialization.init(std.testing.allocator, &.{}, constants),
    );
}

test "specialization unifies compatible declarations sharing a SpecId" {
    const aliases = [_]spirv.SpecializationConstant{
        .{
            .result_id = 1,
            .spec_id = 7,
            .name = "shared",
            .scalar_type = .{ .unsigned_integer = 32 },
        },
        .{
            .result_id = 2,
            .spec_id = 7,
            .name = "shared",
            .scalar_type = .{ .unsigned_integer = 32 },
        },
        .{
            .result_id = 3,
            .spec_id = 7,
            .name = "other",
            .scalar_type = .{ .unsigned_integer = 32 },
        },
    };
    var numeric = try Specialization.init(
        std.testing.allocator,
        &aliases,
        &.{.{ .key = "7", .value = 4 }},
    );
    defer numeric.deinit(std.testing.allocator);
    var named = try Specialization.init(
        std.testing.allocator,
        &aliases,
        &.{.{ .key = "shared", .value = 4 }},
    );
    defer named.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), numeric.map_entries.len);
    try std.testing.expectEqualSlices(u8, numeric.canonical_bytes, named.canonical_bytes);
    try std.testing.expectError(
        error.DuplicateConstant,
        Specialization.init(std.testing.allocator, &aliases, &.{
            .{ .key = "shared", .value = 4 }, .{ .key = "other", .value = 4 },
        }),
    );
    var incompatible = aliases;
    incompatible[2].scalar_type = .{ .float = 32 };
    try std.testing.expectError(
        error.AmbiguousConstant,
        Specialization.init(std.testing.allocator, &incompatible, &.{
            .{ .key = "shared", .value = 4 },
        }),
    );
    try std.testing.expectError(
        error.AmbiguousConstant,
        Specialization.init(std.testing.allocator, &incompatible, &.{
            .{ .key = "7", .value = 4 },
        }),
    );
}

test "specialization mixed signedness families validate every alias and canonicalize order" {
    const declarations = [_]spirv.SpecializationConstant{
        .{
            .result_id = 1,
            .spec_id = 7,
            .name = "signed",
            .scalar_type = .{ .signed_integer = 32 },
        },
        .{
            .result_id = 2,
            .spec_id = 7,
            .name = "unsigned",
            .scalar_type = .{ .unsigned_integer = 32 },
        },
    };
    const reversed = [_]spirv.SpecializationConstant{ declarations[1], declarations[0] };
    var reference = try Specialization.init(
        std.testing.allocator,
        &declarations,
        &.{.{ .key = "7", .value = 2.9 }},
    );
    defer reference.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), reference.map_entries.len);
    try std.testing.expectEqual(
        @as(u32, 2),
        std.mem.readInt(u32, reference.data[0..4], native_endian),
    );
    try std.testing.expectEqual(@as(u8, 1), reference.canonical_bytes[4]);
    for ([_][]const u8{ "7", "signed", "unsigned" }) |key| {
        var actual = try Specialization.init(
            std.testing.allocator,
            &reversed,
            &.{.{ .key = key, .value = 2.9 }},
        );
        defer actual.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, reference.data, actual.data);
        try std.testing.expectEqualSlices(u8, reference.canonical_bytes, actual.canonical_bytes);
        try std.testing.expectError(
            error.ConstantOutOfRange,
            Specialization.init(std.testing.allocator, &declarations, &.{
                .{ .key = key, .value = -1 },
            }),
        );
    }
    try std.testing.expectError(
        error.DuplicateConstant,
        Specialization.init(std.testing.allocator, &declarations, &.{
            .{ .key = "signed", .value = 2 }, .{ .key = "unsigned", .value = 2 },
        }),
    );
}

test "specialization mixed scalar families require matching converted size and bits" {
    const declarations = [_]spirv.SpecializationConstant{
        .{
            .result_id = 1,
            .spec_id = 7,
            .name = "integer",
            .scalar_type = .{ .signed_integer = 32 },
        },
        .{ .result_id = 2, .spec_id = 7, .name = "float", .scalar_type = .{ .float = 32 } },
    };
    var reference = try Specialization.init(
        std.testing.allocator,
        &declarations,
        &.{.{ .key = "7", .value = 0 }},
    );
    defer reference.deinit(std.testing.allocator);
    for ([_][]const u8{ "7", "integer", "float" }) |key| {
        var actual = try Specialization.init(
            std.testing.allocator,
            &declarations,
            &.{.{ .key = key, .value = 0 }},
        );
        defer actual.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, reference.canonical_bytes, actual.canonical_bytes);
        try std.testing.expectError(
            error.AmbiguousConstant,
            Specialization.init(std.testing.allocator, &declarations, &.{
                .{ .key = key, .value = 2 },
            }),
        );
        try std.testing.expectError(
            error.AmbiguousConstant,
            Specialization.init(std.testing.allocator, &declarations, &.{
                .{ .key = key, .value = -0.0 },
            }),
        );
    }
    var widths = declarations;
    widths[1].scalar_type = .{ .signed_integer = 16 };
    try std.testing.expectError(
        error.AmbiguousConstant,
        Specialization.init(std.testing.allocator, &widths, &.{
            .{ .key = "integer", .value = 0 },
        }),
    );
    try std.testing.expectError(
        error.AmbiguousConstant,
        Specialization.init(std.testing.allocator, &widths, &.{
            .{ .key = "7", .value = 0 },
        }),
    );
}
