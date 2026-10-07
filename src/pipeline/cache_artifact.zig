//! Allocation-free envelope for opaque Vulkan pipeline-cache data.
//! SHA-256 detects corruption; it does not authenticate the producer or prove a driver cache hit.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const header_byte_count: usize = 128;
pub const format_version: u32 = 1;
pub const default_maximum_payload_byte_count: usize = 16 * 1024 * 1024;
const magic = "DUSKCCH1";
const native_header_byte_count: usize = 32;
const storage_key_domain = "dusk:vk-pipeline-cache:1\x00";

pub const Identity = struct {
    vendor_id: u32,
    device_id: u32,
    driver_version: u32,
    pipeline_cache_uuid: [16]u8,
};

pub const Error = error{
    TruncatedArtifact,
    UnsupportedArtifactFormat,
    InvalidArtifactHeader,
    ArtifactLengthMismatch,
    ArtifactTooLarge,
    CacheIdentityMismatch,
    CacheIsolationMismatch,
    CacheIntegrityMismatch,
    InvalidNativeCacheHeader,
};

pub const EncodeOptions = struct {
    identity: Identity,
    isolation_key_hash: [32]u8,
    payload: []const u8,
    maximum_payload_byte_count: usize = default_maximum_payload_byte_count,
};

pub const DecodeOptions = struct {
    expected_identity: Identity,
    isolation_key_hash: [32]u8,
    maximum_payload_byte_count: usize = default_maximum_payload_byte_count,
};

/// Returns only the fixed envelope. A provider writes it followed by the original payload span.
/// The payload is validated and hashed without allocation, copying, or modification.
/// The caller must keep it unchanged through the provider's subsequent write.
pub fn encodeHeader(options: EncodeOptions) Error![header_byte_count]u8 {
    const payload_byte_count = std.math.cast(u64, options.payload.len) orelse
        return error.ArtifactTooLarge;
    _ = try checkedPayloadByteCount(payload_byte_count, options.maximum_payload_byte_count);
    try validateNativeData(options.payload, options.identity);

    var header: [header_byte_count]u8 = @splat(0);
    @memcpy(header[0..8], magic);
    std.mem.writeInt(u32, header[8..12], format_version, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(header_byte_count), .little);
    std.mem.writeInt(u64, header[16..24], payload_byte_count, .little);
    std.mem.writeInt(u32, header[24..28], options.identity.vendor_id, .little);
    std.mem.writeInt(u32, header[28..32], options.identity.device_id, .little);
    std.mem.writeInt(u32, header[32..36], options.identity.driver_version, .little);
    @memcpy(header[40..56], &options.identity.pipeline_cache_uuid);
    @memcpy(header[56..88], &options.isolation_key_hash);
    Sha256.hash(options.payload, header[88..120], .{});
    return header;
}

/// Returns a borrowed, read-only payload slice into bytes; no payload copy is made.
/// bytes must remain alive and unchanged for the entire use of the returned slice.
/// Extent, maximum, identity, and native header checks precede payload hashing.
pub fn decodeView(bytes: []const u8, options: DecodeOptions) Error![]const u8 {
    if (bytes.len < header_byte_count) return error.TruncatedArtifact;
    const header = bytes[0..header_byte_count];
    if (!std.mem.eql(u8, header[0..8], magic)) return error.InvalidArtifactHeader;
    if (std.mem.readInt(u32, header[8..12], .little) != format_version) {
        return error.UnsupportedArtifactFormat;
    }
    if (std.mem.readInt(u32, header[12..16], .little) != header_byte_count) {
        return error.InvalidArtifactHeader;
    }
    for (header[36..40]) |byte| {
        if (byte != 0) return error.InvalidArtifactHeader;
    }
    for (header[120..128]) |byte| {
        if (byte != 0) return error.InvalidArtifactHeader;
    }
    const payload_byte_count = try checkedPayloadByteCount(
        std.mem.readInt(u64, header[16..24], .little),
        options.maximum_payload_byte_count,
    );
    if (bytes.len - header_byte_count != payload_byte_count) {
        return error.ArtifactLengthMismatch;
    }
    if (std.mem.readInt(u32, header[24..28], .little) != options.expected_identity.vendor_id) {
        return error.CacheIdentityMismatch;
    }
    if (std.mem.readInt(u32, header[28..32], .little) != options.expected_identity.device_id) {
        return error.CacheIdentityMismatch;
    }
    if (std.mem.readInt(u32, header[32..36], .little) != options.expected_identity.driver_version) {
        return error.CacheIdentityMismatch;
    }
    if (!std.mem.eql(u8, header[40..56], &options.expected_identity.pipeline_cache_uuid)) {
        return error.CacheIdentityMismatch;
    }
    if (!std.mem.eql(u8, header[56..88], &options.isolation_key_hash)) {
        return error.CacheIsolationMismatch;
    }

    const payload = bytes[header_byte_count..];
    try validateNativeData(payload, options.expected_identity);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    if (!std.mem.eql(u8, header[88..120], &digest)) return error.CacheIntegrityMismatch;
    return payload;
}

/// Validates VkPipelineCacheHeaderVersionOne without interpreting or modifying its opaque tail.
/// Vulkan specifies little-endian fields on every host and an exact 32-byte version-one header.
/// driver_version is an envelope identity field; the native header contains no driver version.
pub fn validateNativeData(bytes: []const u8, identity: Identity) Error!void {
    if (bytes.len < native_header_byte_count) return error.InvalidNativeCacheHeader;
    if (std.mem.readInt(u32, bytes[0..4], .little) != native_header_byte_count) {
        return error.InvalidNativeCacheHeader;
    }
    if (std.mem.readInt(u32, bytes[4..8], .little) != 1) {
        return error.InvalidNativeCacheHeader;
    }
    if (std.mem.readInt(u32, bytes[8..12], .little) != identity.vendor_id) {
        return error.CacheIdentityMismatch;
    }
    if (std.mem.readInt(u32, bytes[12..16], .little) != identity.device_id) {
        return error.CacheIdentityMismatch;
    }
    if (!std.mem.eql(u8, bytes[16..32], &identity.pipeline_cache_uuid)) {
        return error.CacheIdentityMismatch;
    }
}

/// SHA-256 of the fixed domain/version, LE identity fields, UUID, and isolation hash.
/// A file provider can hex-encode this fixed digest; no caller string becomes a path component.
pub fn storageKey(identity: Identity, isolation_key_hash: [32]u8) [32]u8 {
    var identity_fields: [12]u8 = undefined;
    std.mem.writeInt(u32, identity_fields[0..4], identity.vendor_id, .little);
    std.mem.writeInt(u32, identity_fields[4..8], identity.device_id, .little);
    std.mem.writeInt(u32, identity_fields[8..12], identity.driver_version, .little);
    var hash = Sha256.init(.{});
    hash.update(storage_key_domain);
    hash.update(&identity_fields);
    hash.update(&identity.pipeline_cache_uuid);
    hash.update(&isolation_key_hash);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn checkedPayloadByteCount(count: u64, maximum: usize) Error!usize {
    const payload_byte_count = std.math.cast(usize, count) orelse return error.ArtifactTooLarge;
    if (payload_byte_count > maximum) return error.ArtifactTooLarge;
    const extent = @addWithOverflow(header_byte_count, payload_byte_count);
    if (extent[1] != 0) return error.ArtifactTooLarge;
    return payload_byte_count;
}
