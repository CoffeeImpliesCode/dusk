// The triangle's three positions, indexed by `vertex_index`. This stage binds
// nothing, so reflection must report zero descriptor inputs.
@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
    const positions = array<vec2f, 3>(
        vec2f(0.0, -0.8),
        vec2f(0.8, 0.8),
        vec2f(-0.8, 0.8),
    );
    return vec4f(positions[vertex_index], 0.0, 1.0);
}