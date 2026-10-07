// Metadata addresses checked descriptor windows, not full allocation offsets.
struct DrawMetadata {
    input_word_offset: u32,
    output_word_offset: u32,
    index_count_low: u32,
    index_count_high: u32,
    flags: u32,
    count_word_offset: u32,
    draw_ordinal: u32,
    max_draw_count: u32,
}

struct Parameters {
    record_count: u32,
    reserved0: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
    reserved4: u32,
    reserved5: u32,
    reserved6: u32,
}

@group(0) @binding(0) var<storage, read> arguments: array<u32>;
@group(0) @binding(1) var<storage, read> counts: array<u32>;
@group(0) @binding(2) var<storage, read> metadata: array<DrawMetadata>;
@group(0) @binding(3) var<storage, read_write> output: array<u32>;
@group(0) @binding(4) var<uniform> parameters: Parameters;

@compute @workgroup_size(64, 1, 1)
fn sanitize_draws(@builtin(global_invocation_id) invocation: vec3<u32>) {
    if (invocation.x >= parameters.record_count) {
        return;
    }
    let record = metadata[invocation.x];
    let indexed = (record.flags & 1u) != 0u;
    let word_count = select(4u, 5u, indexed);

    // Masked slots must be initialized even when no argument words are read.
    for (var word = 0u; word < word_count; word += 1u) {
        output[record.output_word_offset + word] = 0u;
    }
    var draw_count = record.max_draw_count;
    if ((record.flags & 2u) != 0u) {
        draw_count = min(counts[record.count_word_offset], draw_count);
    }
    if (record.draw_ordinal >= draw_count) {
        return;
    }
    let first_instance_word = record.input_word_offset + select(3u, 4u, indexed);
    if ((record.flags & 4u) == 0u && arguments[first_instance_word] != 0u) {
        return;
    }
    if (indexed) {
        let first_index = arguments[record.input_word_offset + 2u];
        let index_count = arguments[record.input_word_offset];
        let end_low = first_index + index_count;
        let end_high = select(0u, 1u, end_low < first_index);
        if (end_high > record.index_count_high ||
            (end_high == record.index_count_high && end_low > record.index_count_low)) {
            return;
        }
    }
    // Copy u32 words so signed baseVertex and every valid argument stay exact.
    for (var word = 0u; word < word_count; word += 1u) {
        output[record.output_word_offset + word] = arguments[record.input_word_offset + word];
    }
}
