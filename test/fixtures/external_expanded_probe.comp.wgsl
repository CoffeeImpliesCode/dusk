// External-texture consumer with the native layout's unchanged private bindings.
// The uniform is observed as 72 words, so this fixture checks all 288 bytes,
// including the padding which an ordinary typed shader cannot name.
@group(0) @binding(1000u) var plane0: texture_2d<f32>;
@group(0) @binding(1001u) var plane1: texture_2d<f32>;
@group(0) @binding(1002u) var<uniform> metadata: array<vec4u, 18>;
@group(0) @binding(2) var sampling: sampler;
@group(0) @binding(4) var<storage, read_write> result: array<u32>;

fn word(index: u32) -> u32 {
    return metadata[index / 4u][index % 4u];
}

fn scalar(index: u32) -> f32 {
    return bitcast<f32>(word(index));
}

@compute @workgroup_size(1)
fn external_expanded_probe() {
    for (var row = 0u; row < 4u; row++) {
        for (var column = 0u; column < 4u; column++) {
            let uv = (vec2f(f32(column), f32(row)) + vec2f(0.5)) / 4.0;
            let coordinates = vec2f(scalar(44u), scalar(45u)) * uv.x +
                vec2f(scalar(46u), scalar(47u)) * uv.y +
                vec2f(scalar(48u), scalar(49u));
            let first = clamp(coordinates, vec2f(scalar(56u), scalar(57u)),
                vec2f(scalar(58u), scalar(59u)));
            var color: vec4f;
            if (word(0u) == 1u) {
                color = textureSampleLevel(plane0, sampling, first, 0.0);
            } else {
                let second = clamp(coordinates, vec2f(scalar(60u), scalar(61u)),
                    vec2f(scalar(62u), scalar(63u)));
                color = vec4f(textureSampleLevel(plane0, sampling, first, 0.0).r,
                    textureSampleLevel(plane1, sampling, second, 0.0).rg, 1.0);
            }
            let offset = (row * 4u + column) * 4u;
            result[offset] = bitcast<u32>(color.r);
            result[offset + 1u] = bitcast<u32>(color.g);
            result[offset + 2u] = bitcast<u32>(color.b);
            result[offset + 3u] = bitcast<u32>(color.a);
        }
    }
    for (var index = 0u; index < 72u; index++) {
        result[64u + index] = word(index);
    }
}
