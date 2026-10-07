// Original Dusk shader. No upstream shader source is copied.
// Four vec4u groups keep the uniform block exactly 64 bytes.
struct Parameters {
    byte_layout: vec4u,
    extent_origin: vec4u,
    source_format: vec4u,
    reserved: vec4u,
}

@group(0) @binding(0) var source: texture_3d<f32>;
@group(0) @binding(1) var<storage, read_write> output: array<u32>;
@group(0) @binding(2) var<uniform> parameters: Parameters;

fn componentByteCount(kind: u32) -> u32 {
    switch (kind) {
        case 1u, 2u, 3u, 4u: {
            return 1u;
        }
        case 5u, 6u, 7u, 8u, 9u: {
            return 2u;
        }
        default: {
            return 4u;
        }
    }
}

fn texelByteCount(kind: u32, channels: u32) -> u32 {
    if (kind >= 13u) {
        return 4u;
    }
    return componentByteCount(kind) * channels;
}

fn linearToSrgb(value: f32) -> f32 {
    let bounded = clamp(value, 0.0, 1.0);
    if (bounded <= 0.0031308) {
        return bounded * 12.92;
    }
    return 1.055 * pow(bounded, 1.0 / 2.4) - 0.055;
}

fn roundEven(value: f32) -> u32 {
    let lower = floor(value);
    let fraction = value - lower;
    let integer = u32(lower);
    return integer + select(0u, 1u, fraction > 0.5 ||
        (fraction == 0.5 && (integer & 1u) != 0u));
}

fn packUnsignedFloat(value: f32, mantissa_bits: u32) -> u32 {
    let infinity = 31u << mantissa_bits;
    if (value != value) {
        return infinity | (1u << (mantissa_bits - 1u));
    }
    if (value <= 0.0) {
        return 0u;
    }
    let bits = bitcast<u32>(value);
    let source_exponent = (bits >> 23u) & 255u;
    if (source_exponent == 255u) {
        return infinity;
    }
    var exponent = i32(source_exponent) - 127 + 15;
    let fraction = bits & 0x7fffffu;
    if (exponent <= 0) {
        let shift = u32(24 - i32(mantissa_bits) - exponent);
        if (shift >= 32u) {
            return 0u;
        }
        let significand = fraction | 0x800000u;
        let bias = (1u << (shift - 1u)) - 1u;
        return (significand + bias + ((significand >> shift) & 1u)) >> shift;
    }
    if (exponent >= 31) {
        return infinity;
    }
    let shift = 23u - mantissa_bits;
    let bias = (1u << (shift - 1u)) - 1u;
    var mantissa = (fraction + bias + ((fraction >> shift) & 1u)) >> shift;
    if (mantissa == (1u << mantissa_bits)) {
        mantissa = 0u;
        exponent += 1;
    }
    return (u32(exponent) << mantissa_bits) | mantissa;
}

fn sharedExponentComponent(value: f32) -> f32 {
    if (value != value) {
        return 0.0;
    }
    return clamp(value, 0.0, 65408.0);
}

fn packSharedExponent(value: vec3f) -> u32 {
    let bounded = vec3f(sharedExponentComponent(value.x),
        sharedExponentComponent(value.y), sharedExponentComponent(value.z));
    let maximum = max(max(bounded.x, bounded.y), bounded.z);
    let source_exponent = i32((bitcast<u32>(maximum) >> 23u) & 255u) - 127;
    var exponent = u32(clamp(source_exponent + 16, 0, 31));
    var scale = bitcast<f32>((151u - exponent) << 23u);
    if (roundEven(maximum * scale) == 512u && exponent < 31u) {
        exponent += 1u;
        scale *= 0.5;
    }
    let red = roundEven(bounded.x * scale);
    let green = roundEven(bounded.y * scale);
    let blue = roundEven(bounded.z * scale);
    return red | (green << 9u) | (blue << 18u) | (exponent << 27u);
}

fn packFloatComponent(value: f32, kind: u32) -> u32 {
    switch (kind) {
        case 1u: {
            return u32(floor(clamp(value, 0.0, 1.0) * 255.0 + 0.5));
        }
        case 2u: {
            return bitcast<u32>(i32(round(clamp(value, -1.0, 1.0) * 127.0))) & 255u;
        }
        case 5u: {
            return u32(floor(clamp(value, 0.0, 1.0) * 65535.0 + 0.5));
        }
        case 6u: {
            return bitcast<u32>(i32(round(clamp(value, -1.0, 1.0) * 32767.0))) & 65535u;
        }
        case 9u: {
            return pack2x16float(vec2f(value, 0.0)) & 65535u;
        }
        default: {
            return bitcast<u32>(value);
        }
    }
}

fn packTexel(input_value: vec4f, kind: u32, channels: u32) -> vec4u {
    var value = input_value;
    if ((parameters.source_format.w & 8192u) != 0u) {
        value = vec4f(linearToSrgb(value.x), linearToSrgb(value.y),
            linearToSrgb(value.z), value.w);
    }
    if ((parameters.source_format.w & 4096u) != 0u) {
        value = value.zyxw;
    }
    if (kind == 13u) {
        let bounded = clamp(value, vec4f(0.0), vec4f(1.0));
        let packed = vec4u(floor(bounded * vec4f(1023.0, 1023.0, 1023.0, 3.0) + 0.5));
        return vec4u(packed.x | (packed.y << 10u) | (packed.z << 20u) |
            (packed.w << 30u), 0u, 0u, 0u);
    }
    if (kind == 15u) {
        return vec4u(packUnsignedFloat(value.x, 6u) |
            (packUnsignedFloat(value.y, 6u) << 11u) |
            (packUnsignedFloat(value.z, 5u) << 22u), 0u, 0u, 0u);
    }
    if (kind == 16u) {
        return vec4u(packSharedExponent(value.xyz), 0u, 0u, 0u);
    }
    let component_bits = componentByteCount(kind) * 8u;
    var words = vec4u(0u);
    for (var channel = 0u; channel < 4u; channel += 1u) {
        if (channel < channels) {
            let bit_offset = channel * component_bits;
            words[bit_offset >> 5u] |=
                packFloatComponent(value[channel], kind) << (bit_offset & 31u);
        }
    }
    return words;
}

fn loadTexel(x: u32, y: u32, layer: u32) -> vec4f {
    return textureLoad(source, vec3i(vec3u(parameters.extent_origin.z + x,
        parameters.extent_origin.w + y, parameters.source_format.x + layer)),
        i32(parameters.source_format.y));
}

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) invocation: vec3u) {
    let word_index = invocation.x;
    let words_per_row = parameters.byte_layout.y >> 2u;
    let total_words = words_per_row * parameters.byte_layout.z * parameters.extent_origin.y;
    if (word_index >= total_words) {
        return;
    }
    let output_index = (parameters.byte_layout.x >> 2u) + word_index;
    let row_index = word_index / words_per_row;
    let y = row_index % parameters.byte_layout.z;
    let layer = row_index / parameters.byte_layout.z;
    var result = 0u;
    if (y < parameters.extent_origin.x) {
        let kind = parameters.source_format.w & 255u;
        let channels = (parameters.source_format.w >> 8u) & 15u;
        let texel_bytes = texelByteCount(kind, channels);
        let first_byte = (word_index % words_per_row) * 4u;
        var cached_x = 0xffffffffu;
        var packed_texel = vec4u(0u);
        for (var lane = 0u; lane < 4u; lane += 1u) {
            let byte_column = first_byte + lane;
            let x = byte_column / texel_bytes;
            if (x < parameters.byte_layout.w) {
                if (cached_x != x) {
                    packed_texel = packTexel(loadTexel(x, y, layer), kind, channels);
                    cached_x = x;
                }
                let texel_byte = byte_column % texel_bytes;
                let byte_value = (packed_texel[texel_byte >> 2u] >>
                    ((texel_byte & 3u) * 8u)) & 255u;
                result |= byte_value << (lane * 8u);
            }
        }
    }
    // One invocation writes the whole word, including row and final-word padding.
    output[output_index] = result;
}
