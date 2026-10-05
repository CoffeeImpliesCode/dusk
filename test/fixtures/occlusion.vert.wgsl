// A triangle that covers every pixel of the target, so one draw at one sample
// per pixel passes exactly four samples. The M18 triangle is small on purpose:
// an occlusion query counts rasterised samples, so this stage is chosen for the
// coverage it produces and not for how it looks. The two corners sit outside
// clip space on purpose, which is what makes the hypotenuse cross the target
// rather than stop short of it.
@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
    const positions = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f(3.0, -1.0),
        vec2f(-1.0, 3.0),
    );
    return vec4f(positions[vertex_index], 0.0, 1.0);
}