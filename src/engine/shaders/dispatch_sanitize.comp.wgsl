struct Parameters {
    input_word_offset: u32,
    max_x: u32,
    max_y: u32,
    max_z: u32,
}

@group(0) @binding(0) var<storage, read> arguments: array<u32>;
@group(0) @binding(1) var<storage, read_write> output: array<u32>;
@group(0) @binding(2) var<uniform> parameters: Parameters;

@compute @workgroup_size(1, 1, 1)
fn sanitize_dispatch() {
    let x = arguments[parameters.input_word_offset];
    let y = arguments[parameters.input_word_offset + 1u];
    let z = arguments[parameters.input_word_offset + 2u];
    if (x > parameters.max_x || y > parameters.max_y || z > parameters.max_z) {
        // Clamping would run different work. One invalid axis cancels all work.
        output[0] = 0u;
        output[1] = 0u;
        output[2] = 0u;
        return;
    }
    output[0] = x;
    output[1] = y;
    output[2] = z;
}
