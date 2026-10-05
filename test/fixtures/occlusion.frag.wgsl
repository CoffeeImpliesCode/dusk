// A constant colour. An occlusion count does not read a colour, so this stage
// exists to give the pipeline a fragment stage with rasterisation on, and it
// binds nothing, which is what lets the test build a pipeline with an empty
// layout.
@fragment
fn fs_main() -> @location(0) vec4f {
    return vec4f(1.0, 1.0, 1.0, 1.0);
}