@group(0) @binding(0) var<storage, read_write> output: atomic<u32>;

@compute @workgroup_size(1)
fn main() {
    atomicAdd(&output, 1u);
}
