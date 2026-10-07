struct Parameters {
    row_layout: vec4u,
    offsets: vec4u,
}

@group(0) @binding(0) var<storage, read> source: array<u32>;
@group(0) @binding(1) var<storage, read> destination: array<u32>;
@group(0) @binding(2) var<storage, read_write> output: array<u32>;
@group(0) @binding(3) var<uniform> parameters: Parameters;

fn readSourceByte(byte_index: u32) -> u32 {
    return (source[byte_index >> 2u] >> ((byte_index & 3u) * 8u)) & 255u;
}

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) invocation: vec3u) {
    let word_index = invocation.x;
    if (word_index >= parameters.offsets.z) {
        return;
    }
    var merged = destination[word_index];
    for (var lane = 0u; lane < 4u; lane += 1u) {
        let destination_byte = word_index * 4u + lane;
        if (destination_byte >= parameters.offsets.y) {
            let relative = destination_byte - parameters.offsets.y;
            let row = relative / parameters.row_layout.y;
            let column = relative % parameters.row_layout.y;
            if (row < parameters.row_layout.w && column < parameters.row_layout.z) {
                let source_byte = parameters.offsets.x + row * parameters.row_layout.x + column;
                let shift = lane * 8u;
                merged = (merged & ~(255u << shift)) | (readSourceByte(source_byte) << shift);
            }
        }
    }
    output[word_index] = merged;
}
