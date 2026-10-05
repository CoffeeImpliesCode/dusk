//! The SPIR-V grammar tables the reader needs.
//!
//! Every value here is transcribed from
//! `third_party/spirv-headers/src/include/spirv/unified1/spirv.core.grammar.json`
//! in the Dawn tree pinned at `32f77c02294310054a660c393feded4bcb3f203c`.
//!
//! **What this file does not claim.** It does not claim to carry the whole
//! specification. `Opcode` carries the twenty instructions the reader reasons
//! about and nothing else; a module may legally use any of the other eight
//! hundred, and skipping one is exact because its word count is in its header.
//! The enumerations are whole, because a closed enumeration is the only way to
//! tell a decoration a module may legally carry from a word that is not a
//! decoration at all.

const std = @import("std");

/// The instructions the reader reasons about.
///
/// A module may legally use any of the eight hundred instructions the
/// specification defines. The ones below are the ones the reader has to name:
/// every other instruction is skipped by its word count, which is exact
/// because the count is in the instruction header.
pub const Opcode = enum(u16) {
    entry_point = 15,
    type_image = 25,
    type_sampler = 26,
    type_structure = 30,
    type_pointer = 32,
    variable = 59,
    decorate = 71,
    member_decorate = 72,
    group_decorate = 74,
    decorate_string = 5632,
    member_decorate_string = 5633,

    pub fn fromRaw(raw: u16) ?Opcode {
        return std.enums.fromInt(Opcode, raw);
    }
};

pub const Decoration = enum(u32) {
    relaxed_precision = 0,
    spec_id = 1,
    block = 2,
    buffer_block = 3,
    row_major = 4,
    col_major = 5,
    array_stride = 6,
    matrix_stride = 7,
    glsl_shared = 8,
    glsl_packed = 9,
    c_packed = 10,
    built_in = 11,
    no_perspective = 13,
    flat = 14,
    patch = 15,
    centroid = 16,
    sample = 17,
    invariant = 18,
    restrict = 19,
    volatile_decoration = 21,
    constant = 22,
    coherent = 23,
    non_writable = 24,
    non_readable = 25,
    uniform = 26,
    uniform_id = 27,
    saturated_conversion = 28,
    stream = 29,
    location = 30,
    component = 31,
    index = 32,
    binding = 33,
    descriptor_set = 34,
    offset = 35,
    xfb_buffer = 36,
    xfb_stride = 37,
    func_param_attr = 38,
    fp_rounding_mode = 39,
    fp_fast_math_mode = 40,
    linkage_attributes = 41,
    no_contraction = 42,
    input_attachment_index = 43,
    alignment = 44,
    max_byte_offset = 45,
    alignment_id = 46,
    max_byte_offset_id = 47,
    saturated_to_largest_float8_normal_conversion_ext = 4216,
    no_signed_wrap = 4469,
    no_unsigned_wrap = 4470,
    weight_texture_qcom = 4487,
    block_match_texture_qcom = 4488,
    block_match_sampler_qcom = 4499,
    explicit_interp_amd = 4999,
    node_shares_payload_limits_with_amdx = 5019,
    node_max_payloads_amdx = 5020,
    track_finish_writing_amdx = 5078,
    payload_node_name_amdx = 5091,
    payload_node_base_index_amdx = 5098,
    payload_node_sparse_array_amdx = 5099,
    payload_node_array_size_amdx = 5100,
    payload_dispatch_indirect_amdx = 5105,
    array_stride_id_ext = 5124,
    offset_id_ext = 5125,
    utf_encoded_khr = 5145,
    override_coverage_nv = 5248,
    passthrough_nv = 5250,
    viewport_relative_nv = 5252,
    secondary_viewport_relative_nv = 5256,
    per_primitive_ext = 5271,
    per_view_nv = 5272,
    per_task_nv = 5273,
    per_vertex_khr = 5285,
    non_uniform = 5300,
    restrict_pointer = 5355,
    aliased_pointer = 5356,
    member_offset_nv = 5358,
    hit_object_shader_record_buffer_nv = 5386,
    hit_object_shader_record_buffer_ext = 5389,
    bank_nv = 5397,
    bindless_sampler_nv = 5398,
    bindless_image_nv = 5399,
    bound_sampler_nv = 5400,
    bound_image_nv = 5401,
    cooperative_matrix_transpose_ext = 5440,
    simt_call_intel = 5599,
    referenced_indirectly_intel = 5602,
    clobber_intel = 5607,
    side_effects_intel = 5608,
    vector_compute_variable_intel = 5624,
    func_param_io_kind_intel = 5625,
    vector_compute_function_intel = 5626,
    stack_call_intel = 5627,
    global_variable_offset_intel = 5628,
    counter_buffer = 5634,
    user_semantic = 5635,
    user_type_google = 5636,
    function_rounding_mode_intel = 5822,
    function_denorm_mode_intel = 5823,
    register_altera = 5825,
    memory_altera = 5826,
    numbanks_altera = 5827,
    bankwidth_altera = 5828,
    max_private_copies_altera = 5829,
    singlepump_altera = 5830,
    doublepump_altera = 5831,
    max_replicates_altera = 5832,
    simple_dual_port_altera = 5833,
    merge_altera = 5834,
    bank_bits_altera = 5835,
    force_pow2_depth_altera = 5836,
    stridesize_altera = 5883,
    wordsize_altera = 5884,
    true_dual_port_altera = 5885,
    burst_coalesce_altera = 5899,
    cache_size_altera = 5900,
    dont_statically_coalesce_altera = 5901,
    prefetch_altera = 5902,
    stall_enable_altera = 5905,
    fuse_loops_in_function_altera = 5907,
    math_op_dsp_mode_altera = 5909,
    alias_scope_intel = 5914,
    no_alias_intel = 5915,
    initiation_interval_altera = 5917,
    max_concurrency_altera = 5918,
    pipeline_enable_altera = 5919,
    buffer_location_altera = 5921,
    io_pipe_storage_altera = 5944,
    function_floating_point_mode_intel = 6080,
    single_element_vector_intel = 6085,
    vector_compute_callable_function_intel = 6087,
    media_block_io_intel = 6140,
    stall_free_altera = 6151,
    fp_max_error_decoration_intel = 6170,
    latency_control_label_altera = 6172,
    latency_control_constraint_altera = 6173,
    conduit_kernel_argument_altera = 6175,
    register_map_kernel_argument_altera = 6176,
    mm_host_interface_address_width_altera = 6177,
    mm_host_interface_data_width_altera = 6178,
    mm_host_interface_latency_altera = 6179,
    mm_host_interface_read_write_mode_altera = 6180,
    mm_host_interface_max_burst_altera = 6181,
    mm_host_interface_wait_request_altera = 6182,
    stable_kernel_argument_altera = 6183,
    host_access_intel = 6188,
    init_mode_altera = 6190,
    implement_in_register_map_altera = 6191,
    conditional_intel = 6247,
    cache_control_load_intel = 6442,
    cache_control_store_intel = 6443,
    intrinsic_samsung = 7040,

    pub fn fromRaw(raw: u32) ?Decoration {
        return std.enums.fromInt(Decoration, raw);
    }
};

pub const StorageClass = enum(u32) {
    uniform_constant = 0,
    input = 1,
    uniform = 2,
    output = 3,
    workgroup = 4,
    cross_workgroup = 5,
    private = 6,
    function = 7,
    generic = 8,
    push_constant = 9,
    atomic_counter = 10,
    image = 11,
    storage_buffer = 12,
    tile_image_ext = 4172,
    tile_attachment_qcom = 4491,
    node_payload_amdx = 5068,
    callable_data_khr = 5328,
    incoming_callable_data_khr = 5329,
    ray_payload_khr = 5338,
    hit_attribute_khr = 5339,
    incoming_ray_payload_khr = 5342,
    shader_record_buffer_khr = 5343,
    physical_storage_buffer = 5349,
    hit_object_attribute_nv = 5385,
    task_payload_workgroup_ext = 5402,
    hit_object_attribute_ext = 5411,
    code_section_intel = 5605,
    device_only_altera = 5936,
    host_only_altera = 5937,

    pub fn fromRaw(raw: u32) ?StorageClass {
        return std.enums.fromInt(StorageClass, raw);
    }
};

pub const ExecutionModel = enum(u32) {
    vertex = 0,
    tessellation_control = 1,
    tessellation_evaluation = 2,
    geometry = 3,
    fragment = 4,
    gl_compute = 5,
    kernel = 6,
    task_nv = 5267,
    mesh_nv = 5268,
    ray_generation_khr = 5313,
    intersection_khr = 5314,
    any_hit_khr = 5315,
    closest_hit_khr = 5316,
    miss_khr = 5317,
    callable_khr = 5318,
    task_ext = 5364,
    mesh_ext = 5365,

    pub fn fromRaw(raw: u32) ?ExecutionModel {
        return std.enums.fromInt(ExecutionModel, raw);
    }
};

pub const Dim = enum(u32) {
    one_dimensional = 0,
    two_dimensional = 1,
    three_dimensional = 2,
    cube = 3,
    rectangle = 4,
    buffer = 5,
    subpass_data = 6,
    tile_image_data_ext = 4173,

    pub fn fromRaw(raw: u32) ?Dim {
        return std.enums.fromInt(Dim, raw);
    }
};
