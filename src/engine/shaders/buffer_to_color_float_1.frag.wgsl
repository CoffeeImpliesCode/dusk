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

fn signedByte(value: u32) -> i32 {
    return bitcast<i32>(value << 24u) >> 24u;
}

fn signedHalf(value: u32) -> i32 {
    return bitcast<i32>(value << 16u) >> 16u;
}

fn floatComponent(kind: u32, byte_address: u32) -> f32 {
    switch (kind) {
        case 1u: { return f32(readByte(byte_address)) / 255.0; }
        case 2u: { return max(f32(signedByte(readByte(byte_address))) / 127.0, -1.0); }
        case 3u: { return f32(readByte(byte_address)); }
        case 4u: { return f32(signedByte(readByte(byte_address))); }
        case 5u: { return f32(readHalf(byte_address)) / 65535.0; }
        case 6u: { return max(f32(signedHalf(readHalf(byte_address))) / 32767.0, -1.0); }
        case 7u: { return f32(readHalf(byte_address)); }
        case 8u: { return f32(signedHalf(readHalf(byte_address))); }
        case 9u: { return unpack2x16float(readHalf(byte_address)).x; }
        case 10u: { return f32(readWord(byte_address)); }
        case 11u: { return f32(bitcast<i32>(readWord(byte_address))); }
        case 12u: { return bitcast<f32>(readWord(byte_address)); }
        default: { return 0.0; }
    }
}

fn unsignedFloat(value: u32, mantissa_bits: u32) -> f32 {
    let exponent = value >> mantissa_bits;
    let mantissa = value & ((1u << mantissa_bits) - 1u);
    if (exponent == 0u) {
        return f32(mantissa) * exp2(-14.0 - f32(mantissa_bits));
    }
    if (exponent == 31u) {
        return bitcast<f32>(0x7f800000u | (mantissa << (23u - mantissa_bits)));
    }
    return bitcast<f32>(((exponent + 112u) << 23u) |
        (mantissa << (23u - mantissa_bits)));
}

fn srgbToLinear(value: f32) -> f32 {
    if (value <= 0.04045) {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

fn decodeColor(position: vec4f) -> vec4f {
    let format_code = parameters.words2.w;
    let kind = format_code & 255u;
    let channel_count = (format_code >> 8u) & 15u;
    let byte_address = sourceByteAddress(position, pixelByteCount(kind, channel_count));
    var color = vec4f(0.0, 0.0, 0.0, 1.0);
    if (kind == 13u || kind == 14u) {
        let packed = readWord(byte_address);
        color = vec4f(f32(packed & 1023u), f32((packed >> 10u) & 1023u),
            f32((packed >> 20u) & 1023u), f32(packed >> 30u));
        if (kind == 13u) {
            color /= vec4f(1023.0, 1023.0, 1023.0, 3.0);
        }
    } else if (kind == 15u) {
        let packed = readWord(byte_address);
        color = vec4f(unsignedFloat(packed & 2047u, 6u),
            unsignedFloat((packed >> 11u) & 2047u, 6u),
            unsignedFloat(packed >> 22u, 5u), 1.0);
    } else if (kind == 16u) {
        let packed = readWord(byte_address);
        let scale = exp2(f32(packed >> 27u) - 24.0);
        color = vec4f(vec3f(f32(packed & 511u), f32((packed >> 9u) & 511u),
            f32((packed >> 18u) & 511u)) * scale, 1.0);
    } else {
        let component_byte_count = pixelByteCount(kind, 1u);
        for (var channel = 0u; channel < 4u; channel += 1u) {
            if (channel < channel_count) {
                color[channel] = floatComponent(kind,
                    byte_address + channel * component_byte_count);
            }
        }
    }
    if ((format_code & 4096u) != 0u) {
        color = color.bgra;
    }
    // An sRGB attachment encodes linear fragment output during the color write.
    if ((format_code & 8192u) != 0u) {
        color = vec4f(srgbToLinear(color.r), srgbToLinear(color.g),
            srgbToLinear(color.b), color.a);
    }
    return color;
}

@fragment
fn main(@builtin(position) position: vec4f) -> @location(1) vec4f {
    return decodeColor(position);
}
