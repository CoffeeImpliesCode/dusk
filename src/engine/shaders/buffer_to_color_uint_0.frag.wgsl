struct Parameters {
    words0: vec4u,
    words1: vec4u,
    words2: vec4u,
    words3: vec4u,
}

@group(0) @binding(0) var<storage, read> source: array<u32>;
@group(0) @binding(1) var<uniform> parameters: Parameters;

fn readByte(byte_address: u32) -> u32 {
    return (source[byte_address >> 2u] >> ((byte_address & 3u) * 8u)) & 255u;
}

fn readHalf(byte_address: u32) -> u32 {
    let shift_bits = (byte_address & 3u) * 8u;
    let word_index = byte_address >> 2u;
    if (shift_bits <= 16u) {
        return (source[word_index] >> shift_bits) & 65535u;
    }
    return (source[word_index] >> 24u) | ((source[word_index + 1u] & 255u) << 8u);
}

fn readWord(byte_address: u32) -> u32 {
    let shift_bits = (byte_address & 3u) * 8u;
    let word_index = byte_address >> 2u;
    if (shift_bits == 0u) {
        return source[word_index];
    }
    return (source[word_index] >> shift_bits) |
        (source[word_index + 1u] << (32u - shift_bits));
}

fn pixelByteCount(kind: u32, channel_count: u32) -> u32 {
    if (kind <= 4u) {
        return channel_count;
    }
    if (kind <= 9u) {
        return channel_count * 2u;
    }
    if (kind <= 12u) {
        return channel_count * 4u;
    }
    return 4u;
}

fn sourceByteAddress(position: vec4f, pixel_byte_count: u32) -> u32 {
    let pixel = vec2u(position.xy) - parameters.words1.zw;
    return parameters.words0.x +
        parameters.words2.x * parameters.words0.z * parameters.words0.y +
        pixel.y * parameters.words0.y + pixel.x * pixel_byte_count;
}

fn unsignedComponent(kind: u32, byte_address: u32) -> u32 {
    if (kind == 3u) {
        return readByte(byte_address);
    }
    if (kind == 7u) {
        return readHalf(byte_address);
    }
    return readWord(byte_address);
}

fn decodeColor(position: vec4f) -> vec4u {
    let format_code = parameters.words2.w;
    let kind = format_code & 255u;
    let channel_count = (format_code >> 8u) & 15u;
    let byte_address = sourceByteAddress(position, pixelByteCount(kind, channel_count));
    var color = vec4u(0u, 0u, 0u, 1u);
    if (kind == 14u) {
        let packed = readWord(byte_address);
        color = vec4u(packed & 1023u, (packed >> 10u) & 1023u,
            (packed >> 20u) & 1023u, packed >> 30u);
    } else {
        let component_byte_count = pixelByteCount(kind, 1u);
        for (var channel = 0u; channel < 4u; channel += 1u) {
            if (channel < channel_count) {
                color[channel] = unsignedComponent(kind,
                    byte_address + channel * component_byte_count);
            }
        }
    }
    if ((format_code & 4096u) != 0u) {
        color = color.bgra;
    }
    return color;
}

@fragment
fn main(@builtin(position) position: vec4f) -> @location(0) vec4u {
    return decodeColor(position);
}
