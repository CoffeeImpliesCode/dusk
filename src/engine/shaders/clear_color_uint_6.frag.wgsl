struct Params128 {
    color_0: vec4u,
    color_1: vec4u,
    color_2: vec4u,
    color_3: vec4u,
    color_4: vec4u,
    color_5: vec4u,
    color_6: vec4u,
    color_7: vec4u,
}

@group(0) @binding(0) var<uniform> params: Params128;

@fragment
fn main() -> @location(6) vec4u {
    return params.color_6;
}
