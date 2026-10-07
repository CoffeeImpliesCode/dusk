struct Params {
    source_origin_mip: vec4u,
    source_extent_sample: vec4u,
    destination_rectangle: vec4u,
    flags_layer: vec4u,
    affine: vec4u,
    padding: vec4u,
}

@group(0) @binding(0) var source_texture: texture_multisampled_2d<u32>;
@group(0) @binding(1) var<uniform> params: Params;

fn localRatio(position: vec4f) -> vec2f {
    var ratio = (position.xy - vec2f(params.destination_rectangle.xy)) /
        vec2f(params.destination_rectangle.zw);
    if ((params.flags_layer.x & 1u) != 0u) {
        ratio.y = 1.0 - ratio.y;
    }
    return ratio;
}

fn sourceCoordinates(position: vec4f) -> vec2i {
    let relative = vec2u(floor(localRatio(position) *
        vec2f(params.source_extent_sample.xy)));
    return vec2i(params.source_origin_mip.xy + relative);
}

@fragment
fn main(@builtin(position) position: vec4f) -> @location(1) vec4u {
    let coordinates = sourceCoordinates(position);
    var color = textureLoad(source_texture, coordinates, i32(params.source_extent_sample.z));
    if ((params.flags_layer.x & 2u) != 0u) {
        color = color.bgra;
    }
    return color;
}
