// Original Dusk shader. No upstream shader source is copied.
// Four vec4u groups keep the uniform block exactly 64 bytes.
struct Parameters {
    byte_layout: vec4u,
    extent_origin: vec4u,
    source_format: vec4u,
    reserved: vec4u,
}

@group(0) @binding(0) var source: texture_3d<i32>;
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

fn packTexel(input_value: vec4i, kind: u32, channels: u32) -> vec4u {
    var value = bitcast<vec4u>(input_value);
    if ((parameters.source_format.w & 4096u) != 0u) {
        value = value.zyxw;
    }
    let component_bits = componentByteCount(kind) * 8u;
    var mask = 0xffffffffu;
    if (component_bits < 32u) {
        mask = (1u << component_bits) - 1u;
    }
    var words = vec4u(0u);
    for (var channel = 0u; channel < 4u; channel += 1u) {
        if (channel < channels) {
            let bit_offset = channel * component_bits;
            words[bit_offset >> 5u] |= (value[channel] & mask) << (bit_offset & 31u);
        }
    }
    return words;
}

fn loadTexel(x: u32, y: u32, layer: u32) -> vec4i {
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
