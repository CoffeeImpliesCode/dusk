struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) @interpolate(flat) instance: u32,
}

@vertex
fn main(@builtin(vertex_index) vertex: u32, @builtin(instance_index) instance: u32) -> VertexOutput {
    let positions = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var result: VertexOutput;
    result.position = vec4f(positions[vertex % 3u], 0.0, 1.0);
    result.instance = instance;
    return result;
}
