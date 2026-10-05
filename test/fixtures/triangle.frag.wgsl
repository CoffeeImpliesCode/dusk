// The fragment colour comes from one uniform buffer. The binding is 1, not 0,
// so a test can tell the set apart from the binding instead of matching one
// index in two places.
struct Tint {
    color: vec4f,
}

@group(0) @binding(1) var<uniform> tint: Tint;

@fragment
fn fs_main() -> @location(0) vec4f {
    return tint.color;
}