struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    let corner = vec2f(f32((vertex_index << 1u) & 2u), f32(vertex_index & 2u));
    var output: VertexOutput;
    output.position = vec4f(corner * 2.0 - vec2f(1.0), 0.0, 1.0);
    output.uv = corner;
    return output;
}
