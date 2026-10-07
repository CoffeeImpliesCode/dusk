struct Params {
    origins: vec4u,
    extents: vec4u,
    destination_rectangle: vec4u,
    flags_layer: vec4u,
    affine: vec4u,
    padding: vec4u,
}

struct Source {
    words: array<u32>,
}

@group(0) @binding(0) var<storage, read> source_buffer: Source;
@group(0) @binding(1) var<uniform> params: Params;

fn localRatio(position: vec4f) -> vec2f {
    var ratio = (position.xy - vec2f(params.origins.zw)) /
        vec2f(params.extents.zw);
    if ((params.flags_layer.x & 1u) != 0u) {
        ratio.y = 1.0 - ratio.y;
    }
    return ratio;
}

fn sourcePixel(position: vec4f) -> vec2f {
    let affine = bitcast<vec4f>(params.affine);
    return localRatio(position) * affine.xy + affine.zw - vec2f(params.origins.xy);
}

fn loadColor(coordinates: vec2i) -> vec4u {
    let dimensions = params.extents.xy;
    let clamped = vec2u(clamp(coordinates, vec2i(0), vec2i(dimensions) - vec2i(1)));
    let pixel = (params.flags_layer.y * dimensions.y + clamped.y) * dimensions.x + clamped.x;
    let word = pixel * 4u;
    let words = vec4u(source_buffer.words[word], source_buffer.words[word + 1u],
        source_buffer.words[word + 2u], source_buffer.words[word + 3u]);
    return words;
}

@fragment
fn main(@builtin(position) position: vec4f) -> @location(1) vec4u {
    let texel = sourcePixel(position);
    var color = loadColor(vec2i(floor(texel)));
    if ((params.flags_layer.x & 2u) != 0u) {
        color = color.bgra;
    }
    return color;
}
