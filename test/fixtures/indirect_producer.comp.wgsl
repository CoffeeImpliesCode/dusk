@group(0) @binding(0) var<storage, read_write> arguments: array<u32>;

@compute @workgroup_size(1)
fn main() {
    arguments[2] = 2u;
    arguments[3] = 3u;
    arguments[4] = 4u;
}
