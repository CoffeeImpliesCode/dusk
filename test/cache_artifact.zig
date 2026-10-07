//! Wire fixtures are recorded with Python struct.pack and hashlib, not with the codec.
//! All buffers are stack values. The codec has no allocator or Io capability.
const std = @import("std");
const dusk = @import("dusk");
const artifact = dusk.pipeline.cache_artifact;
const testing = std.testing;

const identity: artifact.Identity = .{
    .vendor_id = 0x11223344,
    .device_id = 0x55667788,
    .driver_version = 0x99aabbcc,
    .pipeline_cache_uuid = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
};
const isolation_key_hash: [32]u8 = .{
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
    0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
};
const payload = [_]u8{
    0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0xde, 0xad, 0xbe, 0xef, 0x00, 0xff, 0x80, 0x01,
};
const header = [_]u8{
    0x44, 0x55, 0x53, 0x4b, 0x43, 0x43, 0x48, 0x31,
    0x01, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
    0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55,
    0xcc, 0xbb, 0xaa, 0x99, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
    0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
    0x7a, 0xdb, 0x91, 0xe0, 0x0c, 0xe6, 0x79, 0x66,
    0xb0, 0xa5, 0xb3, 0x07, 0xea, 0x9f, 0x91, 0xea,
    0xc7, 0x59, 0x97, 0x6a, 0xe2, 0xe2, 0xe1, 0xce,
    0x73, 0x23, 0x87, 0x18, 0xf3, 0x26, 0x6c, 0x9f,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const fixture = header ++ payload;
const decode_options: artifact.DecodeOptions = .{
    .expected_identity = identity,
    .isolation_key_hash = isolation_key_hash,
};

fn encodeOptions(bytes: []const u8) artifact.EncodeOptions {
    return .{ .identity = identity, .isolation_key_hash = isolation_key_hash, .payload = bytes };
}

test "artifact exact independent fixture and zero-copy roundtrip" {
    try testing.expectEqual(@as(usize, 128), header.len);
    const encoded = try artifact.encodeHeader(encodeOptions(&payload));
    try testing.expectEqualSlices(u8, &header, &encoded);
    const decoded_fixture = try artifact.decodeView(&fixture, decode_options);
    try testing.expectEqualSlices(u8, &payload, decoded_fixture);
    try testing.expect(decoded_fixture.ptr == fixture[128..].ptr);
    var roundtrip: [fixture.len]u8 = undefined;
    @memcpy(roundtrip[0..128], &encoded);
    @memcpy(roundtrip[128..], &payload);
    const decoded_roundtrip = try artifact.decodeView(&roundtrip, decode_options);
    try testing.expectEqualSlices(u8, &payload, decoded_roundtrip);
    try testing.expectEqualSlices(u8, &fixture, &roundtrip);
}

test "artifact minimum native header and borrowed opaque bytes remain unchanged" {
    const minimum_digest = [_]u8{
        0x18, 0x3b, 0x1e, 0xe9, 0x43, 0xde, 0x58, 0xb6,
        0xa0, 0x33, 0x45, 0x4a, 0x9c, 0x7d, 0x89, 0x26,
        0xac, 0x9c, 0xc8, 0x64, 0x42, 0x9c, 0xdf, 0x09,
        0x59, 0x8d, 0x66, 0x0b, 0xcb, 0x4a, 0x23, 0xba,
    };
    var minimum: [160]u8 = undefined;
    @memcpy(minimum[0..128], &header);
    minimum[16] = 32;
    @memcpy(minimum[88..120], &minimum_digest);
    @memcpy(minimum[128..], payload[0..32]);
    try artifact.validateNativeData(payload[0..32], identity);
    const decoded = try artifact.decodeView(&minimum, decode_options);
    try testing.expectEqualSlices(u8, payload[0..32], decoded);
    const encoded = try artifact.encodeHeader(encodeOptions(payload[0..32]));
    try testing.expectEqualSlices(u8, minimum[0..128], &encoded);
    var borrowed = fixture;
    const view = try artifact.decodeView(&borrowed, decode_options);
    try testing.expectEqualSlices(u8, &fixture, &borrowed);
    borrowed[borrowed.len - 1] ^= 0xff;
    try testing.expectEqual(borrowed[borrowed.len - 1], view[view.len - 1]);
}

test "artifact TruncatedArtifact covers every envelope boundary" {
    for (0..128) |length| {
        try testing.expectError(error.TruncatedArtifact, artifact.decodeView(fixture[0..length], decode_options));
    }
}

test "artifact ArtifactLengthMismatch rejects truncation and trailing bytes" {
    for (128..fixture.len) |length| {
        try testing.expectError(error.ArtifactLengthMismatch, artifact.decodeView(fixture[0..length], decode_options));
    }
    const trailing = fixture ++ [_]u8{0};
    try testing.expectError(error.ArtifactLengthMismatch, artifact.decodeView(&trailing, decode_options));
    var changed = fixture;
    for ([_]u64{ 0, 31, 32, 39, 41 }) |count| {
        std.mem.writeInt(u64, changed[16..24], count, .little);
        try testing.expectError(error.ArtifactLengthMismatch, artifact.decodeView(&changed, decode_options));
    }
}

test "artifact ArtifactTooLarge checks maximum before length and payload access" {
    var options = decode_options;
    options.maximum_payload_byte_count = payload.len - 1;
    try testing.expectError(error.ArtifactTooLarge, artifact.decodeView(&fixture, options));
    options.maximum_payload_byte_count = payload.len;
    _ = try artifact.decodeView(&fixture, options);
    var encode_options = encodeOptions(&payload);
    encode_options.maximum_payload_byte_count = payload.len - 1;
    try testing.expectError(error.ArtifactTooLarge, artifact.encodeHeader(encode_options));
    encode_options.maximum_payload_byte_count = payload.len;
    _ = try artifact.encodeHeader(encode_options);
    var declared = header;
    std.mem.writeInt(u64, declared[16..24], 16 * 1024 * 1024 + 1, .little);
    try testing.expectError(error.ArtifactTooLarge, artifact.decodeView(&declared, decode_options));
    options.maximum_payload_byte_count = 16 * 1024 * 1024;
    std.mem.writeInt(u64, declared[16..24], 16 * 1024 * 1024, .little);
    try testing.expectError(error.ArtifactLengthMismatch, artifact.decodeView(&declared, options));
}

test "artifact ArtifactTooLarge checks u64 conversion and total extent overflow" {
    var declared = header;
    var options = decode_options;
    options.maximum_payload_byte_count = std.math.maxInt(usize);
    std.mem.writeInt(u64, declared[16..24], std.math.maxInt(u64), .little);
    try testing.expectError(error.ArtifactTooLarge, artifact.decodeView(&declared, options));
    const count: u64 = std.math.maxInt(usize) - 127;
    std.mem.writeInt(u64, declared[16..24], count, .little);
    try testing.expectError(error.ArtifactTooLarge, artifact.decodeView(&declared, options));
    std.mem.writeInt(u64, declared[16..24], count - 1, .little);
    try testing.expectError(error.ArtifactLengthMismatch, artifact.decodeView(&declared, options));
    if (@sizeOf(usize) < @sizeOf(u64)) {
        std.mem.writeInt(u64, declared[16..24], @as(u64, std.math.maxInt(usize)) + 1, .little);
        try testing.expectError(error.ArtifactTooLarge, artifact.decodeView(&declared, options));
    }
}

test "artifact UnsupportedArtifactFormat rejects non-one little-endian versions" {
    for ([_]u32{ 0, 2, 0x01000000, std.math.maxInt(u32) }) |version| {
        var changed = fixture;
        std.mem.writeInt(u32, changed[8..12], version, .little);
        try testing.expectError(error.UnsupportedArtifactFormat, artifact.decodeView(&changed, decode_options));
    }
}

test "artifact InvalidArtifactHeader rejects magic header count and every reserved byte" {
    for (0..8) |offset| {
        var changed = fixture;
        changed[offset] ^= 1;
        try testing.expectError(error.InvalidArtifactHeader, artifact.decodeView(&changed, decode_options));
    }
    for ([_]u32{ 0, 127, 129, std.math.maxInt(u32) }) |count| {
        var changed = fixture;
        std.mem.writeInt(u32, changed[12..16], count, .little);
        try testing.expectError(error.InvalidArtifactHeader, artifact.decodeView(&changed, decode_options));
    }
    for ([_]usize{ 36, 37, 38, 39, 120, 121, 122, 123, 124, 125, 126, 127 }) |offset| {
        var changed = fixture;
        changed[offset] = 1;
        try testing.expectError(error.InvalidArtifactHeader, artifact.decodeView(&changed, decode_options));
    }
}

test "artifact CacheIdentityMismatch covers all envelope identity bytes" {
    for (24..36) |offset| {
        var changed = fixture;
        changed[offset] ^= 1;
        try testing.expectError(error.CacheIdentityMismatch, artifact.decodeView(&changed, decode_options));
    }
    for (40..56) |offset| {
        var changed = fixture;
        changed[offset] ^= 1;
        try testing.expectError(error.CacheIdentityMismatch, artifact.decodeView(&changed, decode_options));
    }
    var options = decode_options;
    options.expected_identity.driver_version ^= 1;
    try testing.expectError(error.CacheIdentityMismatch, artifact.decodeView(&fixture, options));
}

test "artifact CacheIsolationMismatch covers all isolation hash bytes" {
    for (56..88) |offset| {
        var changed = fixture;
        changed[offset] ^= 1;
        try testing.expectError(error.CacheIsolationMismatch, artifact.decodeView(&changed, decode_options));
    }
    var options = decode_options;
    options.isolation_key_hash[0] ^= 1;
    try testing.expectError(error.CacheIsolationMismatch, artifact.decodeView(&fixture, options));
}

test "artifact CacheIntegrityMismatch rejects digest and opaque payload corruption" {
    for (88..120) |offset| {
        var changed = fixture;
        changed[offset] ^= 1;
        try testing.expectError(error.CacheIntegrityMismatch, artifact.decodeView(&changed, decode_options));
    }
    for (160..fixture.len) |offset| {
        var changed = fixture;
        changed[offset] ^= 1;
        try testing.expectError(error.CacheIntegrityMismatch, artifact.decodeView(&changed, decode_options));
    }
}

test "artifact InvalidNativeCacheHeader covers truncation size and version" {
    for (0..32) |length| {
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.validateNativeData(payload[0..length], identity));
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.encodeHeader(encodeOptions(payload[0..length])));
    }
    for ([_]u32{ 0, 31, 33, 40, 41, std.math.maxInt(u32) }) |size| {
        var changed = payload;
        std.mem.writeInt(u32, changed[0..4], size, .little);
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.validateNativeData(&changed, identity));
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.encodeHeader(encodeOptions(&changed)));
        var envelope = fixture;
        @memcpy(envelope[128..], &changed);
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.decodeView(&envelope, decode_options));
    }
    for ([_]u32{ 0, 2, 0x01000000, std.math.maxInt(u32) }) |version| {
        var changed = payload;
        std.mem.writeInt(u32, changed[4..8], version, .little);
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.validateNativeData(&changed, identity));
        var envelope = fixture;
        @memcpy(envelope[128..], &changed);
        try testing.expectError(error.InvalidNativeCacheHeader, artifact.decodeView(&envelope, decode_options));
    }
    var short = fixture;
    short[16] = 31;
    try testing.expectError(error.InvalidNativeCacheHeader, artifact.decodeView(short[0..159], decode_options));
}

test "artifact native CacheIdentityMismatch precedes digest and ignores opaque tail" {
    for (8..32) |offset| {
        var changed = payload;
        changed[offset] ^= 1;
        try testing.expectError(error.CacheIdentityMismatch, artifact.validateNativeData(&changed, identity));
        try testing.expectError(error.CacheIdentityMismatch, artifact.encodeHeader(encodeOptions(&changed)));
        var envelope = fixture;
        @memcpy(envelope[128..], &changed);
        try testing.expectError(error.CacheIdentityMismatch, artifact.decodeView(&envelope, decode_options));
    }
    var opaque_tail = payload;
    @memset(opaque_tail[32..], 0xff);
    try artifact.validateNativeData(&opaque_tail, identity);
    var other_driver = identity;
    other_driver.driver_version ^= 1;
    try artifact.validateNativeData(&payload, other_driver);
}

test "artifact storageKey exact independent domain-separated SHA256 fixture" {
    const expected = [_]u8{
        0x41, 0x91, 0x54, 0x83, 0x2f, 0x6f, 0xaa, 0x6c,
        0xa8, 0x70, 0xf3, 0x56, 0x29, 0x0f, 0x54, 0xe4,
        0xbd, 0xd8, 0x9b, 0x36, 0xdf, 0xa4, 0x69, 0xf4,
        0xcf, 0xd7, 0x59, 0x9d, 0x5a, 0x47, 0xcf, 0x60,
    };
    const key = artifact.storageKey(identity, isolation_key_hash);
    try testing.expectEqualSlices(u8, &expected, &key);
    inline for (.{ "vendor_id", "device_id", "driver_version" }) |field| {
        var changed = identity;
        @field(changed, field) ^= 1;
        const other = artifact.storageKey(changed, isolation_key_hash);
        try testing.expect(!std.mem.eql(u8, &key, &other));
    }
    for (0..16) |offset| {
        var changed = identity;
        changed.pipeline_cache_uuid[offset] ^= 1;
        const other = artifact.storageKey(changed, isolation_key_hash);
        try testing.expect(!std.mem.eql(u8, &key, &other));
    }
    for (0..32) |offset| {
        var changed = isolation_key_hash;
        changed[offset] ^= 1;
        const other = artifact.storageKey(identity, changed);
        try testing.expect(!std.mem.eql(u8, &key, &other));
    }
}
