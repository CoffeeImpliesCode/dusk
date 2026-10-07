@group(0) @binding(0) var image: texture_2d<f32>;
@group(0) @binding(1) var image_sampler: sampler;
@group(0) @binding(2) var<storage, read_write> output: vec4<f32>;

@compute @workgroup_size(1)
fn main() {
    let color = textureSampleLevel(image, image_sampler, vec2<f32>(0.5, 0.5), 0.0);
    output = color;
}
