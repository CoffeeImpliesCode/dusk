@fragment
fn main(@location(0) @interpolate(flat) instance: u32) -> @location(0) vec4f {
    if (instance == 0u) {
        return vec4f(1.0, 0.0, 0.0, 1.0);
    }
    return vec4f(0.0, 1.0, 0.0, 1.0);
}
