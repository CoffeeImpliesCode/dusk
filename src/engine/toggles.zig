//! The toggle table: the 183 code paths a caller can turn on, turn off,
//! or force, and the state that records what one object holds.
//!
//! Ports `src/dawn/native/Toggles.{h,cpp}` (`Toggles.h:44-315`,
//! `Toggles.cpp:49-1140`).
//!
//! **What this file does not claim.** It does not claim which toggles a
//! device turns on. Every row here is data. The defaults that choose a
//! toggle are M9, and the logger `forceSet` would use is M8.

const std = @import("std");

/// When a toggle is validated and first read. `DawnNative.h:51` names the
/// three levels `Instance`, `Adapter` and `Device`. The order is load-bearing:
/// a level reads every level above it (`Toggles.cpp:1011`).
pub const ToggleStage = enum(u3) {
    instance,
    adapter,
    device,
};

/// One code path a caller can turn on or off. 183 members in the order of
/// `Toggles.h:44-235`, and positional. The ordinal of a member is its row in
/// `infos`, which upstream asserts at `Toggles.cpp:1211` and `:1155`.
pub const Toggle = enum(u16) {
    emulate_store_and_msaa_resolve,
    nonzero_clear_resources_on_creation_for_testing,
    always_resolve_into_zero_level_and_layer,
    lazy_clear_resource_on_first_use,
    disable_lazy_clear_for_mapped_at_creation_buffer,
    turn_off_vsync,
    use_temporary_buffer_in_compressed_texture_to_texture_copy,
    use_d3d12_resource_heap_tier2,
    use_d3d12_render_pass,
    use_d3d12_residency_management,
    disable_resource_suballocation,
    skip_validation,
    vulkan_use_d32s8,
    vulkan_use_s8,
    metal_disable_sampler_compare,
    metal_use_shared_mode_for_counter_sample_buffer,
    disable_base_vertex,
    disable_base_instance,
    disable_indexed_draw_buffers,
    disable_sample_variables,
    disable_bind_group_layout_entry_array_size,
    use_d3d12_small_shader_visible_heap_for_testing,
    use_dxc,
    disable_robustness,
    metal_enable_vertex_pulling,
    allow_unsafe_ap_is,
    flush_before_client_wait_sync,
    use_temp_buffer_in_small_format_texture_to_texture_copy_from_greater_to_less_mip_level,
    emit_hlsl_debug_symbols,
    disallow_spirv,
    dump_shaders,
    dump_shaders_on_failure,
    dump_tint_ir,
    enable_tint_ir_validation_asserts,
    disable_workgroup_init,
    disable_demote_to_helper,
    vulkan_use_demote_to_helper_invocation_extension,
    disable_symbol_renaming,
    use_user_defined_labels_in_backend,
    use_placeholder_fragment_in_vertex_only_pipeline,
    fxc_optimizations,
    record_detailed_timing_in_trace_events,
    disable_timestamp_query_conversion,
    timestamp_quantization,
    clear_buffer_before_resolve_queries,
    vulkan_use_zero_initialize_workgroup_memory_extension,
    metal_render_r8rg8_unorm_small_mip_to_temp_texture,
    disable_blob_cache,
    d3d12_force_clear_copyable_depth_stencil_texture_on_creation,
    d3d12_dont_set_clear_value_on_depth_texture_creation,
    d3d12_always_use_typeless_formats_for_castable_texture,
    d3d12_allocate_extra_memory_for2d_array_color_texture,
    d3d12_use_temp_buffer_in_depth_stencil_texture_and_buffer_copy_with_non_zero_buffer_offset,
    d3d12_use_temp_buffer_in_texture_to_texture_copy_between_different_dimensions,
    apply_clear_big_integer_color_value_with_draw,
    metal_use_mock_blit_encoder_for_write_timestamp,
    metal_disable_timestamp_period_estimation,
    vulkan_split_command_buffer_on_compute_pass_after_render_pass,
    disable_sub_allocation_for2d_texture_with_copy_dst_or_render_attachment,
    metal_use_combined_depth_stencil_format_for_stencil8,
    metal_use_both_depth_and_stencil_attachments_for_combined_depth_stencil_formats,
    metal_keep_multisubresource_depth_stencil_textures_initialized,
    metal_polyfill_unpack2x16snorm,
    metal_polyfill_unpack2x16unorm,
    metal_polyfill_tanh_f16,
    vulkan_polyfill_float_negation,
    vulkan_polyfill_float_abs,
    metal_fill_empty_occlusion_queries_with_zero,
    use_blit_for_buffer_to_depth_texture_copy,
    use_blit_for_buffer_to_stencil_texture_copy,
    use_blit_for_stencil_texture_write,
    use_blit_for_depth_texture_to_texture_copy_to_nonzero_subresource,
    use_blit_for_depth16_unorm_texture_to_buffer_copy,
    use_blit_for_depth24_plus_texture_to_buffer_copy,
    use_blit_for_depth32_float_texture_to_buffer_copy,
    use_blit_for_stencil_texture_to_buffer_copy,
    use_blit_for_snorm_texture_to_buffer_copy,
    use_blit_for_bgra8_unorm_texture_to_buffer_copy,
    use_blit_for_rgb9e5_ufloat_texture_copy,
    use_blit_for_rg11b10_ufloat_texture_copy,
    use_blit_for_float16_texture_copy,
    use_blit_for_t2b,
    use_blit_for_b2t,
    use_blit_for_non_rgba_unorm_texture_to_buffer_copy,
    use_blit_for_non_rgba_float_texture_to_buffer_copy,
    use_blit_for_uint_texture_to_buffer_copy,
    use_blit_for_sint_texture_to_buffer_copy,
    vulkan_split_buffer_texture_copy_for_array_layers,
    vulkan_force_alpha_write_for_alpha_to_coverage,
    split_buffer_texture_copy_for_oversized_row,
    gl_use_array_length_from_immediate,
    d3d11_disable_cpu_upload_buffers,
    use_t2b2t_for_srgb_texture_copy,
    d3d12_replace_add_with_minus_when_dst_factor_is_zero_and_src_factor_is_dst_alpha,
    d3d12_polyfill_reflect_vec2f32,
    vulkan_clear_gen12_texture_with_ccs_ambiguate_on_creation,
    d3d12_use_root_signature_version1_1,
    vulkan_use_image_robust_access2,
    vulkan_use_buffer_robust_access2,
    d3d12_use64kb_aligned_msaa_texture,
    resolve_multiple_attachment_in_separate_passes,
    d3d12_create_not_zeroed_heap,
    d3d12_dont_use_not_zeroed_heap_flag_on_textures_as_commited_resources,
    d3d_disable_ieee_strictness,
    d3d_skip_shader_optimizations,
    poly_fill_packed4x8_dot_product,
    polyfill_pack_unpack4x8_norm,
    enable_subgroups_intel_gen9,
    d3d12_poly_fill_pack_unpack4x8,
    vulkan_polyfill_switch_with_if,
    expose_wgsl_testing_features,
    expose_wgsl_experimental_features,
    disable_polyfills_on_integer_divison_and_modulo,
    scalarize_max_min_clamp,
    saturate_as_min_max_f16,
    metal_polyfill_clamp_float,
    vulkan_sample_compare_depth_cube_array_workaround,
    vulkan_sample_compare2d_workaround,
    metal_disable_module_constant_f16,
    enable_immediate_error_handling,
    vulkan_use_storage_input_output16,
    d3d12_dont_use_shader_model66_or_higher,
    use_packed_depth24_unorm_stencil8_format,
    d3d12_force_stencil_component_replicate_swizzle,
    d3d12_expand_shader_resource_state_transitions_to_copy_source,
    gl_depth_bias_modifier,
    gl_force_es31_and_no_extensions,
    vulkan_monolithic_pipeline_cache,
    vulkan_incomplete_pipeline_cache_workaround,
    metal_serialize_timestamp_generation_and_resolution,
    d3d12_relax_min_subgroup_size_to8,
    d3d12_relax_buffer_texture_copy_pitch_and_offset_alignment,
    use_vulkan_memory_model,
    vulkan_direct_variable_access_transform_handle,
    vulkan_add_work_to_empty_resolve_pass,
    enable_integer_range_analysis_in_robustness,
    use_spirv14,
    metal_use_argument_buffers,
    enable_shader_print,
    blob_cache_hash_validation,
    d3d12_decompose_workgroup_access,
    d3d12_polyfill_f16_ceil_floor,
    collapse_subgroup_min_max,
    d3d12_force_enable_subgroup_matrix_on_buggy_intel_drivers,
    vulkan_enable_f16_on_nvidia,
    enable_render_doc_process_injection,
    vulkan_use_dynamic_rendering,
    enable_spirv_validation,
    vulkan_use_create_render_pass2,
    metal_replace_workgroup_bool_with_u32,
    vulkan_cooperative_matrix_stride_is_matrix_elements,
    vulkan_use_extended_dynamic_state,
    vulkan_use_rasterization_order_attachment_access,
    vulkan_force_static_samplers_for_external_textures,
    d3d12_use_hlsl2021,
    metal_fix_u32_div_mod,
    vulkan_sleep_after_lost_device_wait,
    use_spirv_reconvergence_mode,
    vulkan_replace_workgroup_atomic_store_with_exchange,
    vulkan_disallow_npot_depth_stencil_mipmaps,
    vulkan_replace_unsigned_compare_zero,
    vulkan_use_cooperative_matrix_robust_buffer_access,
    metal_enable_tensors,
    allow_alpha_to_coverage_not_blendable,
    wait_is_thread_safe,
    spontaneous_queue_events,
    no_workaround_sample_mask_becomes_zero_for_all_but_last_color_target,
    no_workaround_indirect_base_vertex_not_applied,
    no_workaround_dst_alpha_as_src_blend_factor_for_both_color_and_alpha_does_not_work,
    clear_color_with_draw,
    vulkan_skip_draw,
    d3d11_disable_map_on_default_buffers,
    d3d11_use_unmonitored_fence,
    d3d11_disable_fence,
    d3d11_delay_flush_to_gpu,
    d3d11_use_discard_view,
    ignore_imported_a_hardware_buffer_vulkan_image_size,
    gl_allow_context_on_multi_threads,
    gl_defer,
    disable_transient_attachment,
    auto_map_backend_buffer,
    polyfill_bool_vec_dynamic_store,
    vulkan_relax_max_inter_stage_shader_variables,
};

/// What one toggle is, in the words a caller reads. `DawnNative.h:56-61`.
pub const ToggleInfo = struct {
    name: []const u8,
    description: []const u8,
    url: []const u8,
    stage: ToggleStage,
};

/// 183 toggles, `Toggles.h:44-235`.
pub const toggle_count: usize = 183;
/// The four `ToggleStage::Instance` rows.
pub const instance_toggle_count: usize = 4;
/// The eleven `ToggleStage::Adapter` rows.
pub const adapter_toggle_count: usize = 11;
/// The 168 `ToggleStage::Device` rows. The three counts above add up to
/// `toggle_count`.
pub const device_toggle_count: usize = 168;
/// 23 `u64` words. The 183 bits of `toggle_count` with `Toggle::EnumCount`
/// (`Toggles.h:237`) round up to 23 whole bytes, and the set is declared in
/// that unit. Three words hold every bit that is set.
pub const toggle_word_count: usize = 23;

/// The bits one word of `TogglesSet.bits` holds.
const bit_count_per_word: usize = @bitSizeOf(u64);

/// The five issue links that are not `https://`. Upstream spells them this
/// way, so the port copies the spelling and does not normalize it. Every one
/// of the five appears in `Toggles.cpp` (`src/dawn/native/Toggles.cpp`) as a
/// bare `crbug.com/...` or an `http://` link.
const url_deviations = [_][]const u8{
    "crbug.com/370343334",
    "crbug.com/446113735",
    "crbug.com/372698905",
    "crbug.com/382084196",
    "http://crbug.com/1138528",
};

/// The four instance-stage names. Asserted against the table, so a row that
/// changes stage fails to compile until this list changes with it.
const instance_toggle_names = [_][]const u8{
    "allow_unsafe_apis",
    "expose_wgsl_testing_features",
    "expose_wgsl_experimental_features",
    "vulkan_relax_max_inter_stage_shader_variables",
};

/// The eleven adapter-stage names. Asserted against the table.
const adapter_toggle_names = [_][]const u8{
    "use_dxc",
    "enable_subgroups_intel_gen9",
    "d3d12_dont_use_shader_model_66_or_higher",
    "gl_force_es_31_and_no_extensions",
    "d3d12_relax_min_subgroup_size_to_8",
    "use_vulkan_memory_model",
    "d3d12_force_enable_subgroup_matrix_on_buggy_intel_drivers",
    "vulkan_enable_f16_on_nvidia",
    "vulkan_use_dynamic_rendering",
    "vulkan_use_create_render_pass_2",
    "metal_enable_tensors",
};

/// Whether `name` is in `names`. Bound: the slice the caller passes.
fn namesContain(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Whether `url` is a link this table carries. An empty link is one row,
/// `d3d12_polyfill_f16_ceil_floor` (`Toggles.cpp:780`-`:784`).
fn urlIsExpected(url: []const u8) bool {
    if (url.len == 0) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    for (url_deviations) |deviation| {
        if (std.mem.eql(u8, url, deviation)) return true;
    }
    return false;
}

/// The toggle table, positional. Row `i` is `@enumFromInt(i)`, the invariant
/// upstream asserts twice: at `Toggles.cpp:1210-1213` when it builds the
/// name map, and at `:1154-1155` when it names a toggle.
///
/// `name` is the wire string a `DawnTogglesDescriptor` carries, not the
/// member name. Forty-one rows spell it another way, `spirv_polyfill_float_abs`
/// beside `vulkan_polyfill_float_abs` among them, so it is data and is never
/// derived from the member.
pub const infos: [toggle_count]ToggleInfo = .{
    .{
        .name = "emulate_store_and_msaa_resolve",
        .description =
        \\Emulate storing into multisampled color attachments and doing MSAA resolve 
        \\simultaneously. This workaround is enabled by default on the Metal drivers that do not 
        \\support MTLStoreActionStoreAndMultisampleResolve. To support StoreOp::Store on those 
        \\platforms, we should do MSAA resolve in another render pass after ending the previous 
        \\one.
        ,
        .url = "https://crbug.com/dawn/56",
        .stage = .device,
    },
    .{
        .name = "nonzero_clear_resources_on_creation_for_testing",
        .description =
        \\Clears texture to full 1 bits as soon as they are created, but doesn't update the 
        \\tracking state of the texture. This way we can test the logic of clearing textures that 
        \\use recycled memory.
        ,
        .url = "https://crbug.com/dawn/145",
        .stage = .device,
    },
    .{
        .name = "always_resolve_into_zero_level_and_layer",
        .description =
        \\When the resolve target is a texture view that is created on the non-zero level or 
        \\layer of a texture, we first resolve into a temporarily 2D texture with only one mipmap 
        \\level and one array layer, and copy the result of MSAA resolve into the true resolve 
        \\target. This workaround is enabled by default on the Metal drivers that have bugs when 
        \\setting non-zero resolveLevel or resolveSlice. It is also enabled by default on 
        \\Qualcomm Vulkan drivers, which have similar bugs.
        ,
        .url = "https://crbug.com/dawn/56",
        .stage = .device,
    },
    .{
        .name = "lazy_clear_resource_on_first_use",
        .description =
        \\Clears resource to zero on first usage. This initializes the resource so that no dirty 
        \\bits from recycled memory is present in the new resource.
        ,
        .url = "https://crbug.com/dawn/145",
        .stage = .device,
    },
    .{
        .name = "disable_lazy_clear_for_mapped_at_creation_buffer",
        .description =
        \\Disable clearing buffers to zero for buffers which are mapped at creation.
        ,
        .url = "https://crbug.com/dawn/145",
        .stage = .device,
    },
    .{
        .name = "turn_off_vsync",
        .description =
        \\Turn off vsync when rendering. In order to do performance test or run perf tests, turn 
        \\off vsync so that the fps can exceed 60.
        ,
        .url = "https://crbug.com/dawn/237",
        .stage = .device,
    },
    .{
        .name = "use_temporary_buffer_in_texture_to_texture_copy",
        .description =
        \\Split texture-to-texture copy into two copies: copy from source texture into a 
        \\temporary buffer, and copy from the temporary buffer into the destination texture when 
        \\copying between compressed textures that don't have block-aligned sizes. This 
        \\workaround is enabled by default on all Vulkan drivers to solve an issue in the Vulkan 
        \\SPEC about the texture-to-texture copies with compressed formats. See #1005 
        \\(https://github.com/KhronosGroup/Vulkan-Docs/issues/1005) for more details.
        ,
        .url = "https://crbug.com/dawn/42",
        .stage = .device,
    },
    .{
        .name = "use_d3d12_resource_heap_tier2",
        .description =
        \\Enable support for resource heap tier 2. Resource heap tier 2 allows mixing of texture 
        \\and buffers in the same heap. This allows better heap re-use and reduces fragmentation.
        ,
        .url = "https://crbug.com/dawn/27",
        .stage = .device,
    },
    .{
        .name = "use_d3d12_render_pass",
        .description =
        \\Use the D3D12 render pass API introduced in Windows build 1809 by default. On versions 
        \\of Windows prior to build 1809, or when this toggle is turned off, Dawn will emulate a 
        \\render pass.
        ,
        .url = "https://crbug.com/dawn/36",
        .stage = .device,
    },
    .{
        .name = "use_d3d12_residency_management",
        .description =
        \\Enable residency management. This allows page-in and page-out of resource heaps in GPU 
        \\memory. This component improves overcommitted performance by keeping the most recently 
        \\used resources local to the GPU. Turning this component off can cause allocation 
        \\failures when application memory exceeds physical device memory.
        ,
        .url = "https://crbug.com/dawn/193",
        .stage = .device,
    },
    .{
        .name = "disable_resource_suballocation",
        .description =
        \\Force the backends to not perform resource suballocation. This may expose allocation 
        \\patterns which would otherwise only occur with large or specific types of resources.
        ,
        .url = "https://crbug.com/1313172",
        .stage = .device,
    },
    .{
        .name = "skip_validation",
        .description = "Skip expensive validation of Dawn commands.",
        .url = "https://crbug.com/dawn/271",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_d32s8",
        .description =
        \\Vulkan mandates support of either D32_FLOAT_S8 or D24_UNORM_S8. When available the 
        \\backend will use D32S8 (toggle to on) but setting the toggle to off will make it use 
        \\the D24S8 format when possible.
        ,
        .url = "https://crbug.com/dawn/286",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_s8",
        .description =
        \\Vulkan has a pure stencil8 format but it is not universally available. When this toggle 
        \\is on, the backend will use S8 for the stencil8 format, otherwise it will fallback to 
        \\D32S8 or D24S8.
        ,
        .url = "https://crbug.com/dawn/666",
        .stage = .device,
    },
    .{
        .name = "metal_disable_sampler_compare",
        .description =
        \\Disables the use of sampler compare on Metal. This is unsupported before A9 processors.
        ,
        .url = "https://crbug.com/dawn/342",
        .stage = .device,
    },
    .{
        .name = "metal_use_shared_mode_for_counter_sample_buffer",
        .description =
        \\The query set on Metal need to create MTLCounterSampleBuffer which storage mode must be 
        \\either MTLStorageModeShared or MTLStorageModePrivate. But the private mode does not 
        \\work properly on Intel platforms. The workaround is use shared mode instead.
        ,
        .url = "https://crbug.com/dawn/434",
        .stage = .device,
    },
    .{
        .name = "disable_base_vertex",
        .description =
        \\Disables the use of non-zero base vertex which is unsupported on some platforms.
        ,
        .url = "https://crbug.com/dawn/343",
        .stage = .device,
    },
    .{
        .name = "disable_base_instance",
        .description =
        \\Disables the use of non-zero base instance which is unsupported on some platforms.
        ,
        .url = "https://crbug.com/dawn/343",
        .stage = .device,
    },
    .{
        .name = "disable_indexed_draw_buffers",
        .description =
        \\Disables the use of indexed draw buffer state which is unsupported on some platforms.
        ,
        .url = "https://crbug.com/dawn/582",
        .stage = .device,
    },
    .{
        .name = "disable_sample_variables",
        .description =
        \\Disables gl_SampleMask and related functionality which is unsupported on some platforms.
        ,
        .url = "https://crbug.com/dawn/673",
        .stage = .device,
    },
    .{
        .name = "disable_bind_group_layout_entry_array_size",
        .description = "Disable uses of BindGroupLayoutEntry.bindingArraySize > 0.",
        .url = "https://issues.chromium.org/393558555",
        .stage = .device,
    },
    .{
        .name = "use_d3d12_small_shader_visible_heap",
        .description =
        \\Enable use of a small D3D12 shader visible heap, instead of using a large one by 
        \\default. This setting is used to test bindgroup encoding.
        ,
        .url = "https://crbug.com/dawn/155",
        .stage = .device,
    },
    .{
        .name = "use_dxc",
        .description =
        \\Use DXC instead of FXC for compiling HLSL when dxcompiler.dll is available.
        ,
        .url = "https://crbug.com/dawn/402",
        .stage = .adapter,
    },
    .{
        .name = "disable_robustness",
        .description = "Disable robust buffer access",
        .url = "https://crbug.com/dawn/480",
        .stage = .device,
    },
    .{
        .name = "metal_enable_vertex_pulling",
        .description = "Uses vertex pulling to protect out-of-bounds reads on Metal",
        .url = "https://crbug.com/dawn/480",
        .stage = .device,
    },
    .{
        .name = "allow_unsafe_apis",
        .description =
        \\Suppresses validation errors on API entry points or parameter combinations that aren't 
        \\considered secure yet.
        ,
        .url = "http://crbug.com/1138528",
        .stage = .instance,
    },
    .{
        .name = "flush_before_client_wait_sync",
        .description = "Call glFlush before glClientWaitSync to work around bugs in the latter",
        .url = "https://crbug.com/dawn/633",
        .stage = .device,
    },
    .{
        .name = "use_temp_buffer_in_small_format_texture_to_texture_copy_from_greater_to" ++ "_less_mip_level",
        .description =
        \\Split texture-to-texture copy into two copies: copy from source texture into a 
        \\temporary buffer, and copy from the temporary buffer into the destination texture under 
        \\specific situations. This workaround is by default enabled on some Intel GPUs which 
        \\have a driver bug in the execution of CopyTextureRegion() when we copy with the formats 
        \\whose texel block sizes are less than 4 bytes from a greater mip level to a smaller mip 
        \\level on D3D12 backends.
        ,
        .url = "https://crbug.com/1161355",
        .stage = .device,
    },
    .{
        .name = "emit_hlsl_debug_symbols",
        .description =
        \\Sets the D3DCOMPILE_SKIP_OPTIMIZATION and D3DCOMPILE_DEBUG compilation flags when 
        \\compiling HLSL code. Enables better shader debugging with external graphics debugging 
        \\tools.
        ,
        .url = "https://crbug.com/dawn/776",
        .stage = .device,
    },
    .{
        .name = "disallow_spirv",
        .description =
        \\Disallow usage of SPIR-V completely so that only WGSL is used for shader modules. This 
        \\is useful to prevent a Chromium renderer process from successfully sending SPIR-V code 
        \\to be compiled in the GPU process.
        ,
        .url = "https://crbug.com/1214923",
        .stage = .device,
    },
    .{
        .name = "dump_shaders",
        .description =
        \\Dump shaders for debugging purposes. Dumped shaders will be log via EmitLog, thus 
        \\printed in Chrome console or consumed by user-defined callback function.
        ,
        .url = "https://crbug.com/dawn/792",
        .stage = .device,
    },
    .{
        .name = "dump_shaders_on_failure",
        .description =
        \\Dump shaders only on failure. Used for logging purposes. Dumped shaders will be log via 
        \\EmitLog, thus printed in Chrome console or consumed by user-defined callback function.
        ,
        .url = "https://crbug.com/dawn/792",
        .stage = .device,
    },
    .{
        .name = "dump_tint_ir",
        .description = "Dump Tint IR for debugging.",
        .url = "https://crbug.com/496709352",
        .stage = .device,
    },
    .{
        .name = "enable_tint_ir_validation_asserts",
        .description = "Enable Tint IR validation assertions.",
        .url = "https://crbug.com/467330780",
        .stage = .device,
    },
    .{
        .name = "disable_workgroup_init",
        .description = "Disables the workgroup memory zero-initialization for compute shaders.",
        .url = "https://crbug.com/tint/1003",
        .stage = .device,
    },
    .{
        .name = "disable_demote_to_helper",
        .description =
        \\Disables the conversion of discard to demote to helper thread in the IR transform
        ,
        .url = "https://crbug.com/42250787",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_demote_to_helper_invocation_extension",
        .description = "Sets the use of the vulkan demote to helper extension",
        .url = "https://crbug.com/42250787",
        .stage = .device,
    },
    .{
        .name = "disable_symbol_renaming",
        .description = "Disables the WGSL symbol renaming so that names are preserved.",
        .url = "https://crbug.com/dawn/1016",
        .stage = .device,
    },
    .{
        .name = "use_user_defined_labels_in_backend",
        .description =
        \\Enables setting labels on backend-specific APIs that label objects. The labels used 
        \\will be those of the corresponding frontend objects if non-empty and default labels 
        \\otherwise. Defaults to false unless backend validation is enabled in which case it 
        \\defaults to true. NOTE: On Vulkan, backend labels are required to map errors back to 
        \\the device with which the backend objects included in the error are associated.
        ,
        .url = "https://crbug.com/dawn/840",
        .stage = .device,
    },
    .{
        .name = "use_placeholder_fragment_in_vertex_only_pipeline",
        .description =
        \\Use a placeholder empty fragment shader in vertex only render pipeline. This toggle 
        \\must be enabled for OpenGL ES backend, the Vulkan Backend, and serves as a workaround 
        \\by default enabled on some Metal devices with Intel GPU to ensure the depth result is 
        \\correct.
        ,
        .url = "https://crbug.com/dawn/136",
        .stage = .device,
    },
    .{
        .name = "fxc_optimizations",
        .description =
        \\Enable optimizations when compiling with FXC. Disabled by default because FXC 
        \\miscompiles in many cases when optimizations are enabled.
        ,
        .url = "https://crbug.com/dawn/1203",
        .stage = .device,
    },
    .{
        .name = "record_detailed_timing_in_trace_events",
        .description =
        \\Record detailed timing information in trace events at certain point. Currently the 
        \\timing information is recorded right before calling ExecuteCommandLists on a D3D12 
        \\command queue, and the information includes system time, CPU timestamp, GPU timestamp, 
        \\and their frequency.
        ,
        .url = "https://crbug.com/dawn/1264",
        .stage = .device,
    },
    .{
        .name = "disable_timestamp_query_conversion",
        .description = "Resolve timestamp queries into ticks instead of nanoseconds.",
        .url = "https://crbug.com/dawn/1305",
        .stage = .device,
    },
    .{
        .name = "timestamp_quantization",
        .description =
        \\Enable timestamp queries quantization to reduce the precision of timers that can be 
        \\created with timestamp queries.
        ,
        .url = "https://crbug.com/dawn/1800",
        .stage = .device,
    },
    .{
        .name = "clear_buffer_before_resolve_queries",
        .description =
        \\clear destination buffer to zero before resolving queries. This toggle is enabled on 
        \\Intel Gen12 GPUs due to driver issue.
        ,
        .url = "https://crbug.com/dawn/1823",
        .stage = .device,
    },
    .{
        .name = "use_vulkan_zero_initialize_workgroup_memory_extension",
        .description =
        \\Initialize workgroup memory with OpConstantNull on Vulkan when the Vulkan extension 
        \\VK_KHR_zero_initialize_workgroup_memory is supported.
        ,
        .url = "https://crbug.com/dawn/1302",
        .stage = .device,
    },
    .{
        .name = "metal_render_r8_rg8_unorm_small_mip_to_temp_texture",
        .description =
        \\Metal Intel devices have issues with r8unorm and rg8unorm textures where rendering to 
        \\small mips (level >= 2) doesn't work correctly. Workaround this issue by detecting this 
        \\case and rendering to a temporary texture instead (with copies before and after if 
        \\needed).
        ,
        .url = "https://crbug.com/dawn/1071",
        .stage = .device,
    },
    .{
        .name = "disable_blob_cache",
        .description =
        \\Disables usage of the blob cache (backed by the platform cache if set/passed). Prevents 
        \\any persistent caching capabilities, i.e. pipeline caching.
        ,
        .url = "https://crbug.com/dawn/549",
        .stage = .device,
    },
    .{
        .name = "d3d12_force_clear_copyable_depth_stencil_texture_on_creation",
        .description =
        \\Always clearing copyable depth stencil textures when creating them instead of skipping 
        \\the initialization when the entire subresource is the copy destination as a workaround 
        \\on Intel D3D12 drivers.
        ,
        .url = "https://crbug.com/dawn/1487",
        .stage = .device,
    },
    .{
        .name = "d3d12_dont_set_clear_value_on_depth_texture_creation",
        .description =
        \\Don't set D3D12_CLEAR_VALUE when creating depth textures with CreatePlacedResource() or 
        \\CreateCommittedResource() as a workaround on Intel Gen12 D3D12 drivers.
        ,
        .url = "https://crbug.com/dawn/1487",
        .stage = .device,
    },
    .{
        .name = "d3d12_always_use_typeless_formats_for_castable_texture",
        .description =
        \\Always use the typeless DXGI format when we create a texture with valid viewFormat. 
        \\This Toggle is enabled by default on the D3D12 platforms where 
        \\CastingFullyTypedFormatSupported is false.
        ,
        .url = "https://crbug.com/dawn/1276",
        .stage = .device,
    },
    .{
        .name = "d3d12_allocate_extra_memory_for_2d_array_color_texture",
        .description =
        \\Memory allocation for 2D array color texture may be smaller than it should be on D3D12 
        \\on some Intel devices. So texture access can be out-of-bound, which may cause critical 
        \\security issue. We can workaround this security issue via allocating extra memory and 
        \\limiting its access in itself.
        ,
        .url = "https://crbug.com/dawn/949",
        .stage = .device,
    },
    .{
        .name = "d3d12_use_temp_buffer_in_depth_stencil_texture_and_buffer_copy_with_non" ++ "_zero_buffer_offset",
        .description =
        \\Split buffer-texture copy into two copies: do first copy with a temporary buffer at 
        \\offset 0, then copy from the temporary buffer to the destination. Now this toggle must 
        \\be enabled on the D3D12 platforms where programmable MSAA is not supported.
        ,
        .url = "https://crbug.com/dawn/727",
        .stage = .device,
    },
    .{
        .name = "d3d12_use_temp_buffer_in_texture_to_texture_copy_between_different_dimensions",
        .description =
        \\Use an intermediate temporary buffer when copying between textures of different 
        \\dimensions. Force-enabled on D3D12 when the driver does not have the 
        \\TextureCopyBetweenDimensionsSupported feature.
        ,
        .url = "https://crbug.com/dawn/1216",
        .stage = .device,
    },
    .{
        .name = "apply_clear_big_integer_color_value_with_draw",
        .description =
        \\Apply the clear value of the color attachment with a draw call when load op is 'clear'. 
        \\This toggle is enabled by default on D3D12 backends when we set large integer values (> 
        \\2^24 or < -2^24 for signed integer formats) as the clear value of a color attachment 
        \\with 32-bit integer or unsigned integer formats because D3D12 APIs only support using 
        \\float numbers as clear values, while a float number cannot always precisely represent 
        \\an integer that is greater than 2^24 or smaller than -2^24). This toggle is also 
        \\enabled on Intel GPUs on Metal backend due to a driver issue on Intel Metal driver.
        ,
        .url = "https://crbug.com/dawn/537",
        .stage = .device,
    },
    .{
        .name = "metal_use_mock_blit_encoder_for_write_timestamp",
        .description =
        \\Add mock blit command to blit encoder when encoding writeTimestamp as workaround on 
        \\Metal.This toggle is enabled by default on Metal backend where GPU counters cannot be 
        \\stored tosampleBufferAttachments on empty blit encoder.
        ,
        .url = "https://crbug.com/dawn/1473",
        .stage = .device,
    },
    .{
        .name = "metal_disable_timestamp_period_estimation",
        .description =
        \\Calling sampleTimestamps:gpuTimestamp: from MTLDevice to estimate timestamp period 
        \\leads to GPU overheating on some specific Intel GPUs due to driver issue, such as Intel 
        \\Iris Plus Graphics 655. Enable this workaround to skip timestamp period estimation and 
        \\use a default value instead on the specific GPUs.
        ,
        .url = "https://crbug.com/342701242",
        .stage = .device,
    },
    .{
        .name = "vulkan_split_command_buffer_on_compute_pass_after_render_pass",
        .description =
        \\Splits any command buffer where a compute pass is recorded after a render pass. This 
        \\toggle is enabled by default on Qualcomm GPUs, which have been observed experiencing a 
        \\driver crash in this situation.
        ,
        .url = "https://crbug.com/dawn/1564",
        .stage = .device,
    },
    .{
        .name = "disable_sub_allocation_for_2d_texture_with_copy_dst_or_render_attachment",
        .description =
        \\Disable resource sub-allocation for the 2D texture with CopyDst or RenderAttachment 
        \\usage. Due to driver issues, this toggle is enabled by default on D3D12 backends using 
        \\Intel Gen9.5 or Gen11 GPUs, on Vulkan backends using Intel Gen12 GPUs, and D3D12 
        \\backends using AMD GPUs.
        ,
        .url = "https://crbug.com/1237175",
        .stage = .device,
    },
    .{
        .name = "metal_use_combined_depth_stencil_format_for_stencil8",
        .description =
        \\Use a combined depth stencil format instead of stencil8. Works around an issue where 
        \\the stencil8 format alone does not work correctly. This toggle also causes depth 
        \\stencil attachments using a stencil8 format to also set the depth attachment in the 
        \\Metal render pass. This works around another issue where Metal fails to set the stencil 
        \\attachment correctly for a combined depth stencil format if the depth attachment is not 
        \\also set.
        ,
        .url = "https://crbug.com/dawn/1389",
        .stage = .device,
    },
    .{
        .name = "metal_use_both_depth_and_stencil_attachments_for_combined_depth_stencil_formats",
        .description =
        \\In Metal, depth and stencil attachments are set separately. Setting just one without 
        \\the other does not work correctly for combined depth stencil formats on some Metal 
        \\drivers. This workarounds ensures that both are set. This situation arises during lazy 
        \\clears, or for stencil8 formats if metal_use_combined_depth_stencil_format_for_stencil8 
        \\is also enabled.
        ,
        .url = "https://crbug.com/dawn/1389",
        .stage = .device,
    },
    .{
        .name = "metal_keep_multisubresource_depth_stencil_textures_initialized",
        .description =
        \\Some platforms have bugs where the wrong depth stencil subresource is read/written. To 
        \\avoid reads of uninitialized data, ensure that depth stencil textures with more than 
        \\one subresource are completely initialized, and StoreOp::Discard is always translated 
        \\as a Store.
        ,
        .url = "https://crbug.com/dawn/838",
        .stage = .device,
    },
    .{
        .name = "metal_polyfill_unpack_2x16_snorm",
        .description =
        \\Polyfill unpack2x16snorm for MSL due to CTS failures on Mac AMD and M3+ devices.
        ,
        .url = "https://crbug.com/407109055",
        .stage = .device,
    },
    .{
        .name = "metal_polyfill_unpack_2x16_unorm",
        .description = "Polyfill unpack2x16unorm for MSL due to CTS failures on Mac M3+ devices.",
        .url = "https://crbug.com/449576833",
        .stage = .device,
    },
    .{
        .name = "metal_polyfill_tanh_f16",
        .description = "Polyfill tanh with an f16 value for MSL.",
        .url = "https://crbug.com/42251267",
        .stage = .device,
    },
    .{
        .name = "spirv_polyfill_float_negation",
        .description = "Polyfill f32 and f16 negation.",
        .url = "https://crbug.com/448294721",
        .stage = .device,
    },
    .{
        .name = "spirv_polyfill_float_abs",
        .description = "Polyfill f32 and f16 abs.",
        .url = "https://crbug.com/448294721",
        .stage = .device,
    },
    .{
        .name = "metal_fill_empty_occlusion_queries_with_zero",
        .description =
        \\Apple GPUs leave stale results in the visibility result buffer instead of writing zero 
        \\if an occlusion query is empty. Workaround this by explicitly filling it with zero if 
        \\there are no draw calls.
        ,
        .url = "https://crbug.com/dawn/1707",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_buffer_to_depth_texture_copy",
        .description =
        \\Use a blit instead of a copy command to copy buffer data to the depth aspect of a 
        \\texture. Works around an issue where depth writes by copy commands are not visible to a 
        \\render or compute pass.
        ,
        .url = "https://crbug.com/dawn/1389",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_buffer_to_stencil_texture_copy",
        .description =
        \\Use a blit instead of a copy command to copy buffer data to the stencil aspect of a 
        \\texture. Works around an issue where stencil writes by copy commands are not visible to 
        \\a render or compute pass.
        ,
        .url = "https://crbug.com/dawn/1389",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_stencil_texture_write",
        .description =
        \\Use a blit instead of a write texture command to upload data to the stencil aspect of a 
        \\texture. Works around for OpenGLES when glTexSubImage doesn't support GL_STENCIL_INDEX, 
        \\and when the texture format is depth-stencil-combined.
        ,
        .url = "https://crbug.com/dawn/2391",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_depth_texture_to_texture_copy_to_nonzero_subresource",
        .description =
        \\Use a blit to copy from a depth texture to the nonzero subresource of a depth texture. 
        \\Works around an issue where nonzero layers are not written.
        ,
        .url = "https://crbug.com/dawn/1083",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_depth16unorm_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy depth aspect of a texture to a 
        \\buffer.Workaround for OpenGL and OpenGLES.
        ,
        .url = "https://crbug.com/dawn/1782",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_depth24plus_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy depth aspect of a texture to a buffer. 
        \\Note that it copies depth24 as float. This is a workaround for Capture and Replay to be 
        \\able to capture depth24plus textures. It should only be enabled in the inner device of 
        \\the WebGPU backed as it allows depth24 T2B to pass validation.
        ,
        .url = "https://crbug.com/dawn/1782",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_depth32float_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy depth aspect of a texture to a 
        \\buffer.Workaround for OpenGLES.
        ,
        .url = "https://crbug.com/dawn/1782",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_stencil_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy stencil aspect of a texture to a 
        \\buffer.Workaround for OpenGLES.
        ,
        .url = "https://crbug.com/dawn/1782",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_snorm_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy snorm texture to a buffer.Workaround for 
        \\OpenGLES.
        ,
        .url = "https://crbug.com/dawn/1781",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_bgra8unorm_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy bgra8unorm texture to a buffer.Workaround 
        \\for OpenGLES.
        ,
        .url = "https://crbug.com/dawn/1393",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_rgb9e5ufloat_texture_copy",
        .description =
        \\Use a blit instead of a copy command to copy rgb9e5ufloat texture to a texture or a 
        \\buffer.Workaround for OpenGLES.
        ,
        .url = "https://crbug.com/dawn/2079",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_rg11b10ufloat_texture_copy",
        .description =
        \\Use a blit instead of a copy command to copy rg11b10ufloat texture to a texture or a 
        \\buffer.Workaround for OpenGLES.
        ,
        .url = "https://crbug.com/381214487",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_float_16_texture_copy",
        .description =
        \\Use a blit instead of a copy command to copy float16 texture to a texture or a 
        \\buffer.Workaround for OpenGLES.
        ,
        .url = "https://crbug.com/381214487",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_t2b",
        .description =
        \\Use a compute based blit instead of a copy command to copy texture with supported 
        \\format to a buffer.
        ,
        .url = "https://crbug.com/dawn/348654098",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_b2t",
        .description =
        \\Use a shader based blit instead of a copy command to copy a buffer to a texture with 
        \\supported format.
        ,
        .url = "https://crbug.com/dawn/348653642",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_non_rgba_unorm_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy non-RGBA unorm textures to a buffer. 
        \\Workaround for OpenGLES.
        ,
        .url = "https://issues.chromium.org/issues/556959073",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_non_rgba_float_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy non-RGBA float textures to a buffer. 
        \\Workaround for OpenGLES.
        ,
        .url = "https://issues.chromium.org/issues/556959073",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_uint_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy uint textures to a buffer. Workaround for 
        \\OpenGLES.
        ,
        .url = "https://issues.chromium.org/issues/556959073",
        .stage = .device,
    },
    .{
        .name = "use_blit_for_sint_texture_to_buffer_copy",
        .description =
        \\Use a blit instead of a copy command to copy sint textures to a buffer. Workaround for 
        \\OpenGLES.
        ,
        .url = "https://issues.chromium.org/issues/556959073",
        .stage = .device,
    },
    .{
        .name = "vulkan_split_buffer_texture_copy_for_array_layers",
        .description =
        \\Split a multi-layer buffer-to-texture / texture-to-buffer copy into one vkCmdCopy*Image 
        \\region per array layer / depth slice, each with an explicit per-layer buffer offset, 
        \\instead of a single region with layerCount > 1. Workaround for Huawei Maleoon GPUs, 
        \\whose drivers mis-stride the buffer between layers when bufferImageHeight is padded, 
        \\corrupting every layer after the first.
        ,
        .url = "https://issues.chromium.org/issues/520126486",
        .stage = .device,
    },
    .{
        .name = "vulkan_force_alpha_write_for_alpha_to_coverage",
        .description =
        \\When alpha-to-coverage is enabled and the alpha channel of color attachment 0 is masked 
        \\off, force the alpha write bit on and set the alpha blend to (src * ZERO + dst * ONE) 
        \\so the value stored is the destination alpha. Workaround for Huawei Maleoon GPUs, whose 
        \\drivers drop the alpha-to-coverage computation when the fragment alpha is not written, 
        \\counting every sample as covered. The destination-preserving blend leaves the 
        \\attachment's alpha channel unchanged, so the workaround is not observable to the 
        \\application. Skipped for non-blendable formats.
        ,
        .url = "https://issues.chromium.org/issues/525294804",
        .stage = .device,
    },
    .{
        .name = "split_buffer_texture_copy_for_oversized_row",
        .description =
        \\Split a buffer-to-texture or texture-to-buffer copy into one copy command per row so 
        \\its row pitch (bytes) and row width (texels) never overflow the 18-bit and 14-bit 
        \\hardware register fields. Workaround for an Intel GPU hardware limitation.
        ,
        .url = "https://crbug.com/481934465",
        .stage = .device,
    },
    .{
        .name = "gl_use_array_length_from_immediate",
        .description =
        \\Use immediate data to replace arrayLength() function calls of dynamic storage buffers. 
        \\This toggle is only used for workarounds on certain devices. It has no impact on 
        \\backends which need this transform universally (metal, d3d12)
        ,
        .url = "https://crbug.com/dawn/379805731",
        .stage = .device,
    },
    .{
        .name = "d3d11_disable_cpu_buffers",
        .description = "Force disabling the usages of CPU upload buffers in the D3D11 backend.",
        .url = "https://crbug.com/dawn/348653642",
        .stage = .device,
    },
    .{
        .name = "use_t2b2t_for_srgb_texture_copy",
        .description =
        \\Use T2B and B2T copies to emulate a T2T copy between sRGB and non-sRGB 
        \\textures.Workaround for OpenGLES.
        ,
        .url = "https://crbug.com/dawn/2362",
        .stage = .device,
    },
    .{
        .name = "d3d12_replace_add_with_minus_when_dst_factor_is_zero_and_src_factor_is" ++ "_dst_alpha",
        .description =
        \\Replace the blending operation 'Add' with 'Minus' when dstBlendFactor is 'Zero' and 
        \\srcBlendFactor is 'DstAlpha'. Works around an Intel D3D12 driver issue about alpha 
        \\blending.
        ,
        .url = "https://crbug.com/dawn/1579",
        .stage = .device,
    },
    .{
        .name = "d3d12_polyfill_reflect_vec2_f32",
        .description =
        \\Polyfill the reflect builtin for vec2<f32> for D3D12. This toggle is enabled by default 
        \\on D3D12 backends using FXC on Intel GPUs due to a driver issue on Intel D3D12 driver.
        ,
        .url = "https://crbug.com/tint/1798",
        .stage = .device,
    },
    .{
        .name = "vulkan_clear_gen12_texture_with_ccs_ambiguate_on_creation",
        .description =
        \\Clears some R8-like textures to full 0 bits as soon as they are created. This Toggle is 
        \\enabled on Intel Gen12 GPUs due to a Mesa driver issue.
        ,
        .url = "https://crbug.com/chromium/1361662",
        .stage = .device,
    },
    .{
        .name = "d3d12_use_root_signature_version_1_1",
        .description =
        \\Use D3D12 Root Signature Version 1.1 to make additional guarantees about the 
        \\descriptors in a descriptor heap and the data pointed to by the descriptors so that the 
        \\drivers can make better optimizations on them.
        ,
        .url = "https://crbug.com/tint/1890",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_image_robust_access_2",
        .description =
        \\Disable Tint robustness transform on textures when VK_EXT_robustness2 is supported and 
        \\robustImageAccess2 == VK_TRUE.
        ,
        .url = "https://crbug.com/tint/1890",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_buffer_robust_access_2",
        .description =
        \\Disable index clamping on the runtime-sized arrays on buffers in Tint robustness 
        \\transform when VK_EXT_robustness2 is supported and robustBufferAccess2 == VK_TRUE.
        ,
        .url = "https://crbug.com/tint/1890",
        .stage = .device,
    },
    .{
        .name = "d3d12_use_64kb_alignment_msaa_texture",
        .description =
        \\Create MSAA textures with 64KB (D3D12_SMALL_MSAA_RESOURCE_PLACEMENT_ALIGNMENT) 
        \\alignment.
        ,
        .url = "https://crbug.com/dawn/282",
        .stage = .device,
    },
    .{
        .name = "resolve_multiple_attachments_in_separate_passes",
        .description =
        \\When multiple MSAA attachments are used in a render pass, splits any resolve steps into 
        \\a separate render pass per resolve target. This workaround is enabled by default on ARM 
        \\Mali drivers.
        ,
        .url = "https://crbug.com/dawn/1550",
        .stage = .device,
    },
    .{
        .name = "d3d12_create_not_zeroed_heap",
        .description =
        \\Create D3D12 heap with D3D12_HEAP_FLAG_CREATE_NOT_ZEROED when it is supported. It is 
        \\safe because in Dawn we always clear the resources manually when needed.
        ,
        .url = "https://crbug.com/dawn/484",
        .stage = .device,
    },
    .{
        .name = "d3d12_dont_use_not_zeroed_heap_flag_on_textures_as_commited_resources",
        .description =
        \\Don't set the heap flag D3D12_HEAP_FLAG_CREATE_NOT_ZEROED on the D3D12 textures created 
        \\with CreateCommittedResource() as a workaround of some driver issues on Intel Gen9 and 
        \\Gen11 GPUs.
        ,
        .url = "https://crbug.com/dawn/484",
        .stage = .device,
    },
    .{
        .name = "d3d_disable_ieee_strictness",
        .description =
        \\Disable IEEE strictness when compiling shaders. It is otherwise enabled by default to 
        \\workaround issues where FXC can miscompile code that depends on special float values 
        \\(NaN, INF, etc).
        ,
        .url = "https://crbug.com/tint/976",
        .stage = .device,
    },
    .{
        .name = "d3d_skip_shader_optimizations",
        .description =
        \\Sets the D3DCOMPILE_SKIP_OPTIMIZATION compilation flag when compiling HLSL code.
        ,
        .url = "https://crbug.com/439845637",
        .stage = .device,
    },
    .{
        .name = "polyfill_packed_4x8_dot_product",
        .description = "Always use the polyfill version of dot4I8Packed() and dot4U8Packed().",
        .url = "https://crbug.com/tint/1497",
        .stage = .device,
    },
    .{
        .name = "polyfill_pack_unpack_4x8_norm",
        .description =
        \\Always use the polyfill version of pack4x8snorm, pack4x8unorm, unpack4x8snorm, 
        \\unpack4x8unorm.
        ,
        .url = "https://crbug.com/379551588",
        .stage = .device,
    },
    .{
        .name = "enable_subgroups_intel_gen9",
        .description = "Enables subgroups on Intel Gen9 by polyfilling subgroupBroadcast(f16).",
        .url = "https://crbug.com/42251286",
        .stage = .adapter,
    },
    .{
        .name = "d3d12_polyfill_pack_unpack_4x8",
        .description =
        \\Always use the polyfill version of pack4xI8(), pack4xU8(), pack4xI8Clamp(), 
        \\unpack4xI8() and unpack4xU8() on D3D12 backends. Note that these functions are always 
        \\polyfilled on all other backends right now.
        ,
        .url = "https://crbug.com/tint/1497",
        .stage = .device,
    },
    .{
        .name = "vulkan_polyfill_switch_with_if",
        .description = "Polyfill switch statements with if/else statements on Vulkan.",
        .url = "https://crbug.com/443906252",
        .stage = .device,
    },
    .{
        .name = "expose_wgsl_testing_features",
        .description =
        \\Make the Instance expose the ChromiumTesting* features for testing of 
        \\wgslLanguageFeatures functionality.
        ,
        .url = "https://crbug.com/dawn/2260",
        .stage = .instance,
    },
    .{
        .name = "expose_wgsl_experimental_features",
        .description =
        \\Make the Instance expose the experimental features but not the unsafe ones, so that 
        \\safe experimental features can be used without the need for allow_unsafe_apis
        ,
        .url = "https://crbug.com/dawn/2260",
        .stage = .instance,
    },
    .{
        .name = "disable_polyfills_on_integer_div_and_mod",
        .description = "Disable the Tint polyfills on integer division and modulo.",
        .url = "https://crbug.com/tint/2128",
        .stage = .device,
    },
    .{
        .name = "scalarize_max_min_clamp",
        .description = "Scalarize max, min, and clamp builtins.",
        .url = "https://crbug.com/422144514",
        .stage = .device,
    },
    .{
        .name = "saturate_as_min_max_f16",
        .description = "Polyfill saturate as min and max for f16.",
        .url = "https://crbug.com/448873316",
        .stage = .device,
    },
    .{
        .name = "metal_polyfill_clamp_float",
        .description = "Polyfill clamp function for floating point (metal).",
        .url = "https://crbug.com/407109056",
        .stage = .device,
    },
    .{
        .name = "vulkan_sample_compare_depth_cube_array_workaround",
        .description = "Polyfill specific case of textureSampleCompare(Level) with workaround.",
        .url = "https://crbug.com/465179684",
        .stage = .device,
    },
    .{
        .name = "vulkan_sample_compare_2d_workaround",
        .description =
        \\Polyfill specific case of textureSampleCompare(Level) with bilinear interpolation of 
        \\textureGatherCompare.
        ,
        .url = "https://crbug.com/469328925",
        .stage = .device,
    },
    .{
        .name = "metal_disable_module_constant_f16",
        .description = "Disable module constant hoisting for values that contain f16 types.",
        .url = "https://crbug.com/419804339",
        .stage = .device,
    },
    .{
        .name = "enable_immediate_error_handling",
        .description =
        \\Have the uncaptured error callback invoked immediately when an error occurs, rather 
        \\than waiting for the next Tick. This enables using the stack trace in which the 
        \\uncaptured error occurred when breaking into the uncaptured error callback.
        ,
        .url = "https://crbug.com/dawn/1789",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_storage_input_output_16",
        .description =
        \\Use the StorageInputOutput16 SPIR-V capability for f16 shader IO types when the device 
        \\supports it.
        ,
        .url = "https://crbug.com/tint/2161",
        .stage = .device,
    },
    .{
        .name = "d3d12_dont_use_shader_model_66_or_higher",
        .description =
        \\Only use shader model 6.5 or less for D3D12 backend, to workaround issues on some Intel 
        \\devices.
        ,
        .url = "https://crbug.com/dawn/2470",
        .stage = .adapter,
    },
    .{
        .name = "use_packed_depth24_unorm_stencil8_format",
        .description =
        \\Use a packed depth24_unorm_stencil8 format like DXGI_FORMAT_D24_UNORM_STENCIL8_UINT on 
        \\D3D for wgpu::TextureFormat::Depth24PlusStencil8.
        ,
        .url = "https://crbug.com/341254292",
        .stage = .device,
    },
    .{
        .name = "d3d12_force_stencil_component_replicate_swizzle",
        .description =
        \\Force a replicate swizzle for the stencil component i.e. (ssss) instead of (s001) to 
        \\workaround issues on certain Nvidia drivers on D3D12 with depth24_unorm_stencil8 format.
        ,
        .url = "https://crbug.com/341254292",
        .stage = .device,
    },
    .{
        .name = "d3d12_expand_shader_resource_state_transitions_to_copy_source",
        .description =
        \\When transitioning to any shader resource states PIXEL or NON_PIXEL_SHADER_RESOURCE 
        \\include COPY_SOURCE too on Nvidia since the shader resource states seem to miss 
        \\flushing all caches and layout transitions causing rendering corruption.
        ,
        .url = "https://crbug.com/356905061",
        .stage = .device,
    },
    .{
        .name = "gl_depth_bias_modifier",
        .description =
        \\Empirically some GL drivers select n+1 when a depth value lies between 2^n and 2^(n+1), 
        \\while the WebGPU CTS is expecting n. Scale the depth bias value by multiple 0.5 on 
        \\certain backends to achieve conformant result.
        ,
        .url = "https://crbug.com/42241017",
        .stage = .device,
    },
    .{
        .name = "gl_force_es_31_and_no_extensions",
        .description =
        \\Force EGLContext creation with the minimal ES version and no extensions required by the 
        \\Compat spec, which for OpenGLES is version 3.1 with no extensions. This toggle is used 
        \\by end2end testing.
        ,
        .url = "crbug.com/382084196",
        .stage = .adapter,
    },
    .{
        .name = "vulkan_monolithic_pipeline_cache",
        .description =
        \\Use a monolithic VkPipelineCache per device. The embedder is responsible for calling 
        \\PerformIdleTasks() on the device to serialize VkPipelineCache to BlobCache if needed.
        ,
        .url = "crbug.com/370343334",
        .stage = .device,
    },
    .{
        .name = "vulkan_incomplete_pipeline_cache_workaround",
        .description =
        \\Some drivers encounter corruption when serializing VkPipelineCache data. If 
        \\VK_INCOMPLETEis returned ignore it and skip serializing the pipeline cache again.
        ,
        .url = "crbug.com/446113735",
        .stage = .device,
    },
    .{
        .name = "metal_serialize_timestamp_generation_and_resolution",
        .description =
        \\Newer Apple GPUs can race on query set resolution with timestamp writing from earlier 
        \\compute passes. This can be worked around by signaling and waiting for a shared event 
        \\in between timestamp generation and resolution.
        ,
        .url = "crbug.com/372698905",
        .stage = .device,
    },
    .{
        .name = "d3d12_relax_min_subgroup_size_to_8",
        .description =
        \\Relax the adapters and devices' subgroupMinSize to the minimium of D3D12 reported 
        \\minWaveLaneCount and 8. Some D3D12 drivers is possible to run fragment shader with wave 
        \\count 8 while reporting minWaveLaneCount 16.
        ,
        .url = "https://crbug.com/381969450",
        .stage = .adapter,
    },
    .{
        .name = "d3d12_relax_buffer_texture_copy_pitch_and_offset_alignment",
        .description =
        \\Don't require the alignments of D3D12_TEXTURE_DATA_PITCH_ALIGNMENT (256) for row pitch 
        \\and D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT (512) for offset in buffer-texture copies.
        ,
        .url = "https://crbug.com/381000081",
        .stage = .device,
    },
    .{
        .name = "use_vulkan_memory_model",
        .description = "Use the Vulkan Memory Model if available.",
        .url = "https://crbug.com/392606604",
        .stage = .adapter,
    },
    .{
        .name = "vulkan_direct_variable_access_transform_handle",
        .description = "Transform handles using direct variable access.",
        .url = "https://crbug.com/387000529",
        .stage = .device,
    },
    .{
        .name = "vulkan_add_work_to_empty_resolve_pass",
        .description =
        \\Adds a small amount of work to empty render passes which perform a resolve. This toggle 
        \\is enabled by default on Qualcomm GPUs, where it is needed to force the resolve to 
        \\complete.
        ,
        .url = "https://crbug.com/411656647",
        .stage = .device,
    },
    .{
        .name = "enable_integer_range_analysis_in_robustness",
        .description =
        \\Compute the range of the index with Integer Range Analysis in the robustness transform 
        \\and skip doing index clamping when the out of bound access cannot happen.
        ,
        .url = "https://crbug.com/348701956",
        .stage = .device,
    },
    .{
        .name = "use_spirv_1_4",
        .description = "Use SPIR-V 1.4 if available",
        .url = "https://crbug.com/422421915",
        .stage = .device,
    },
    .{
        .name = "metal_use_argument_buffers",
        .description = "Enables the use of Argument Buffers on Metal.",
        .url = "https://crbug.com/dawn/363031535",
        .stage = .device,
    },
    .{
        .name = "enable_shader_print",
        .description = "Enable print functions to produce output on supported devices.",
        .url = "https://crbug.com/433534277",
        .stage = .device,
    },
    .{
        .name = "blob_cache_hash_validation",
        .description = "Enable hash validation when loading/storing from/to the blob cache",
        .url = "https://crbug.com/429938352",
        .stage = .device,
    },
    .{
        .name = "d3d12_decompose_workgroup_access",
        .description =
        \\Decompose workgroup memory variables into flat scalar arrays and rewrite accesses as 
        \\element-wise loads/stores with bitcasts on selected Intel GPUs on D3D12
        ,
        .url = "https://crbug.com/341991439",
        .stage = .device,
    },
    .{
        .name = "d3d12_polyfill_f16_ceil_floor",
        .description =
        \\Polyfill f16 ceil and floor operations on selected Intel GPUs using DXC to avoid 
        \\incorrect results for values that underflow to zero.
        ,
        .url = "",
        .stage = .device,
    },
    .{
        .name = "collapse_subgroup_min_max",
        .description =
        \\Collapse redundant subgroup min and max operations (e.g., subgroupMin(subgroupMin(x))) 
        \\into a single operation. This works around a driver crash on some AMD GPUs.
        ,
        .url = "https://crbug.com/508265321",
        .stage = .device,
    },
    .{
        .name = "d3d12_force_enable_subgroup_matrix_on_buggy_intel_drivers",
        .description =
        \\Force-enable subgroup matrix support on Intel D3D12 drivers through version 101.8992, 
        \\which may produce incorrect results.
        ,
        .url = "https://crbug.com/558362033",
        .stage = .adapter,
    },
    .{
        .name = "vulkan_enable_f16_on_nvidia",
        .description = "Enables F16 on Nvidia GPUs with Vulkan",
        .url = "https://crbug.com/42251215",
        .stage = .adapter,
    },
    .{
        .name = "enable_renderdoc_process_injection",
        .description =
        \\Enables RenderDoc process injection. If RenderDoc is used to inject into the GPU 
        \\process, send RenderDoc frame capture info.
        ,
        .url = "https://crbug.com/449708316",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_dynamic_rendering",
        .description = "Makes use of VK_KHR_dynamic_rendering to implement WebGPU RenderPass.",
        .url = "https://crbug.com/dawn/463893794",
        .stage = .adapter,
    },
    .{
        .name = "enable_spirv_validation",
        .description = "Enable validation of SPIR-V generated by Tint.",
        .url = "https://crbug.com/473526415",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_create_render_pass_2",
        .description =
        \\Makes use of VK_KHR_create_renderpass2 when creating VkRenderPass objects. Ignored when 
        \\vulkan_use_dynamic_rendering is enabled.
        ,
        .url = "https://crbug.com/chromium/463893793",
        .stage = .adapter,
    },
    .{
        .name = "metal_replace_workgroup_bool_with_u32",
        .description =
        \\Replace workgroup bool with u32 for MSL due to CTS failures on Mac AMD and Intel
        ,
        .url = "https://crbug.com/42241269",
        .stage = .device,
    },
    .{
        .name = "vulkan_cooperative_matrix_stride_is_matrix_elements",
        .description =
        \\Treat the stride operand for cooperative matrix load and store instructions as matrix 
        \\elements instead of a source/dest pointee elements.
        ,
        .url = "https://crbug.com/460209126",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_extended_dynamic_state",
        .description = "Makes use of VK_EXT_extended_dynamic_state to improve pipeline caching.",
        .url = "https://crbug.com/chromium/463893793",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_rasterization_order_attachment_access",
        .description = "Use VK_EXT_rasterization_order_attachment_access when it is available.",
        .url = "https://crbug.com/42241389",
        .stage = .device,
    },
    .{
        .name = "vulkan_force_static_samplers_for_external_textures",
        .description =
        \\Enables the code path to take static samplers for external textures. While static YCbCr 
        \\samplers are only require to sample YCbCr AHB on Android, this is useful for testing on 
        \\other devices.
        ,
        .url = "https://crbug.com/468988322",
        .stage = .device,
    },
    .{
        .name = "d3d12_use_hlsl_2021",
        .description = "Use HLSL 2021 when targeting DXC.",
        .url = "https://crbug.com/508342536",
        .stage = .device,
    },
    .{
        .name = "metal_fix_u32_div_mod",
        .description =
        \\Workaround a driver bug on Apple Silicon with u32 div and mod operations.
        ,
        .url = "https://crbug.com/517225032",
        .stage = .device,
    },
    .{
        .name = "vulkan_sleep_after_lost_device_wait",
        .description = "Insert an arbitrary sleep after WaitIdle functions on device loss.",
        .url = "https://crbug.com/500417361",
        .stage = .device,
    },
    .{
        .name = "use_spirv_reconvergence_mode",
        .description = "Use SPIR-V reconvergence execution mode if supported by the device.",
        .url = "https://crbug.com/379673383",
        .stage = .device,
    },
    .{
        .name = "vulkan_replace_workgroup_atomic_store_with_exchange",
        .description = "Workaround for a driver bug that implements atomic store incorrectly.",
        .url = "https://crbug.com/487773864",
        .stage = .device,
    },
    .{
        .name = "vulkan_disallow_npot_depth_stencil_mipmaps",
        .description =
        \\Reject NPOT depth/stencil textures with mipLevelCount > 1. Workaround for mip level 
        \\miscomputation in PowerVR proprietary driver.
        ,
        .url = "https://crbug.com/540087398",
        .stage = .device,
    },
    .{
        .name = "vulkan_rewrite_unsigned_compare_zero",
        .description =
        \\Workaround for a driver bug where unsigned equality comparisons with zero trigger a 
        \\buggy peephole optimization on Samsung Xclipse GPUs.
        ,
        .url = "https://crbug.com/543420711",
        .stage = .device,
    },
    .{
        .name = "vulkan_use_cooperative_matrix_robust_access",
        .description =
        \\Disable clamping of subgroupMatrixLoad/Store on storage buffers if 
        \\cooperativeMatrixRobustBufferAccess == VK_TRUE
        ,
        .url = "https://crbug.com/548005877",
        .stage = .device,
    },
    .{
        .name = "metal_enable_tensors",
        .description = "Enable the use of Metal 4 Tensor Operations for subgroup matrix.",
        .url = "https://crbug.com/550350271",
        .stage = .adapter,
    },
    .{
        .name = "allow_alpha_to_coverage_not_blendable",
        .description =
        \\Killswitch for a fix to the validation where non-blendable formats where allowed for 
        \\alphaToCoverageEnabled
        ,
        .url = "https://crbug.com/550350271",
        .stage = .device,
    },
    .{
        .name = "wait_is_thread_safe",
        .description =
        \\WaitFor* functions are thread-safe and can be called without the device-lock if 
        \\implicit synchronization is enabled.
        ,
        .url = "https://crbug.com/412761228",
        .stage = .device,
    },
    .{
        .name = "spontaneous_queue_events",
        .description =
        \\Queue events spontaneously complete, either via a dedicated Dawn owned thread, or 
        \\backend specific implementations.
        ,
        .url = "https://crbug.com/412761228",
        .stage = .device,
    },
    .{
        .name = "no_workaround_sample_mask_becomes_zero_for_all_but_last_color_target",
        .description =
        \\MacOS 12.0+ Intel has a bug where the sample mask is only applied for the last color 
        \\target. If there are multiple color targets, all but the last one will use a sample 
        \\mask of zero.
        ,
        .url = "https://crbug.com/dawn/1462",
        .stage = .device,
    },
    .{
        .name = "no_workaround_indirect_base_vertex_not_applied",
        .description =
        \\MacOS Intel < Gen9 has a bug where indirect base vertex is not applied for 
        \\drawIndexedIndirect. Draws are done as if it is always zero.
        ,
        .url = "https://crbug.com/dawn/966",
        .stage = .device,
    },
    .{
        .name = "no_workaround_dst_alpha_as_src_blend_factor_for_both_color_and_alpha" ++ "_does_not_work",
        .description =
        \\Using D3D12_BLEND_DEST_ALPHA as source blend factor for both color and alpha blending 
        \\doesn't work correctly on the D3D12 backend using Intel Gen9 or Gen9.5 GPUs.
        ,
        .url = "https://crbug.com/dawn/1579",
        .stage = .device,
    },
    .{
        .name = "clear_color_with_draw",
        .description =
        \\Use Draw instead of ClearRenderTargetView() to clear color attachments. On D3D11, 
        \\ClearRenderTargetView() does not always clear texture correctly.
        ,
        .url = "https://crbug.com/chromium/329702368",
        .stage = .device,
    },
    .{
        .name = "vulkan_skip_draw",
        .description =
        \\Some chrome tests run with swiftshader, they don't care about the pixel output. This 
        \\toggle allows skipping expensive draw operations for them.
        ,
        .url = "https://crbug.com/chromium/331688266",
        .stage = .device,
    },
    .{
        .name = "d3d11_disable_map_on_default_buffers",
        .description =
        \\Disable the D3D11 MapOnDefaultBuffers path even when the device supports it.
        ,
        .url = "https://crbug.com/chromium/479047477",
        .stage = .device,
    },
    .{
        .name = "d3d11_use_unmonitored_fence",
        .description = "Use d3d11 unmonitored fence.",
        .url = "https://crbug.com/chromium/335553337",
        .stage = .device,
    },
    .{
        .name = "d3d11_disable_fence",
        .description =
        \\Disable d3d11 fence. Fences are not always available on every D3D11 device.
        ,
        .url = "https://crbug.com/chromium/390441217",
        .stage = .device,
    },
    .{
        .name = "d3d11_delay_flush_to_gpu",
        .description =
        \\When this toggle is enabled, Queue::Submit() might not flush the commands to GPU 
        \\immediately. A flush will happen when IDXGISwapChain::Present() is called or 
        \\applications use Instance.WaitAny() to wait for a GPU operation to finish. This toggle 
        \\is intended to reduce the fixed overhead associated with each flushing.
        ,
        .url = "https://crbug.com/chromium/377716220",
        .stage = .device,
    },
    .{
        .name = "d3d11_use_discard_view",
        .description =
        \\Use D3D11's DiscardView for discarding render pass' attachments having StoreOp::Discard
        ,
        .url = "https://crbug.com/479416037",
        .stage = .device,
    },
    .{
        .name = "ignore_imported_ahardwarebuffer_vulkan_image_size",
        .description =
        \\Don't validate the required VkImage size against the size of the AHardwareBuffer on 
        \\import. Some drivers report the wrong size.
        ,
        .url = "https://crbug.com/333424893",
        .stage = .device,
    },
    .{
        .name = "gl_allow_context_on_multi_threads",
        .description =
        \\Allows GL backend to use GL context on multiple threads. This will add certain 
        \\synchronizations' overheads.
        ,
        .url = "https://crbug.com/dawn/451928481",
        .stage = .device,
    },
    .{
        .name = "gl_defer",
        .description =
        \\Allows the GL backend to defer GL commands until Queue::Submit is called. This includes 
        \\backend resource creations which will also be deferred.
        ,
        .url = "https://crbug.com/dawn/451928481",
        .stage = .device,
    },
    .{
        .name = "disable_transient_attachment",
        .description = "Disable TextureUsage TransientAttachment usage.",
        .url = "https://crbug.com/dawn/462620664",
        .stage = .device,
    },
    .{
        .name = "auto_map_backend_buffer",
        .description =
        \\Backend will automatically map the buffer when it's not in use by GPU, to allow 
        \\front-end's MapAsync and Unmap calls to become cheap without acquiring any lock 
        \\internally.
        ,
        .url = "https://crbug.com/dawn/481158754",
        .stage = .device,
    },
    .{
        .name = "polyfill_bool_vec_dynamic_store",
        .description =
        \\Workaround a driver bug on some Intel GPUs where dynamic component stores on boolean 
        \\vectors fail.
        ,
        .url = "https://crbug.com/540789158",
        .stage = .device,
    },
    .{
        .name = "vulkan_relax_max_inter_stage_shader_variables",
        .description =
        \\Relax the maxInterStageShaderVariables floor for ImgTec (PowerVR) devices on Vulkan. 
        \\Some ImgTec drivers only report 64, which is below the WebGPU requirement. Enabling 
        \\this toggle accepts the limit of 64 instead of rejecting the adapter entirely.
        ,
        .url = "https://g-issues.chromium.org/issues/559589664",
        .stage = .instance,
    },
};

/// The wire name of a toggle. `ToggleEnumToName` (`Toggles.cpp:1150-1157`).
/// The string is data, so this reads it and never spells it out.
pub fn toggleName(toggle: Toggle) []const u8 {
    const ordinal: usize = @backingInt(toggle);
    std.debug.assert(ordinal < toggle_count);
    return infos[ordinal].name;
}

/// The toggle a wire name names, or `null` when the table carries no such
/// name. `TogglesInfo::ToggleNameToEnum` (`Toggles.cpp:1192-1202`).
///
/// Dawn builds a `const char*` to `Toggle` map on first use inside a
/// `TogglesInfo` that each caller builds and drops (`Toggles.cpp:1204`). The
/// table here is comptime, so the scan replaces the map, and the map, its
/// boolean guard and its destructor go away with it.
pub fn toggleFromName(name: []const u8) ?Toggle {
    // Bound: `infos`, the `toggle_count` rows. No other bound is possible.
    for (infos, 0..) |info, ordinal| {
        if (std.mem.eql(u8, info.name, name)) return @fromBackingInt(@intCast(ordinal));
    }
    return null;
}

/// The row of one toggle. `TogglesInfo::GetToggleInfo(Toggle)`
/// (`Toggles.cpp:1186-1190`).
pub fn toggleInfo(toggle: Toggle) ToggleInfo {
    const ordinal: usize = @backingInt(toggle);
    std.debug.assert(ordinal < toggle_count);
    return infos[ordinal];
}

/// Which toggles one piece of state holds. `TogglesSet` (`Toggles.h:245-257`)
/// is an `ityp::bitset` upstream, which is a word array and a few reads here.
pub const TogglesSet = struct {
    bits: [toggle_word_count]u64 = @splat(0),

    /// Marks a toggle present. `TogglesSet::Set` (`Toggles.cpp:978-982`).
    /// Dawn takes a value and can clear a bit. This set records presence
    /// only, and `TogglesState` holds the value in `enabled`. Nothing in the
    /// port clears one toggle, because `Default` (`:1058`), `ForceSet`
    /// (`:1068`) and `SetForTesting` (`:1082`) only add bits.
    pub fn set(self: *TogglesSet, toggle: Toggle) void {
        const ordinal: usize = @intCast(toggle);
        const word_index = ordinal / bit_count_per_word;
        const bit_index: u6 = @intCast(ordinal % bit_count_per_word);
        self.bits[word_index] |= @as(u64, 1) << bit_index;
    }

    /// Whether the toggle is present. `TogglesSet::Has`
    /// (`Toggles.cpp:984-988`).
    pub fn has(self: TogglesSet, toggle: Toggle) bool {
        const ordinal: usize = @intCast(toggle);
        const word_index = ordinal / bit_count_per_word;
        const bit_index: u6 = @intCast(ordinal % bit_count_per_word);
        return self.bits[word_index] & (@as(u64, 1) << bit_index) != 0;
    }

    /// How many toggles are present. `TogglesSet::Count`
    /// (`Toggles.cpp:990-992`).
    pub fn count(self: TogglesSet) usize {
        var total: usize = 0;
        // Bound: the word array, `toggle_word_count` words.
        for (self.bits) |word| total += @as(usize, @popCount(word));
        return total;
    }

    /// Drops every toggle. Dawn has no such call. A state is built with
    /// `init` (`Toggles.cpp:994`) and a test rebuilds it with `init` too, so
    /// no caller mutates a state in place.
    pub fn clear(self: *TogglesSet) void {
        self.bits = @splat(0);
    }

    /// The walk over the set toggles in ascending ordinal order. It replaces
    /// `TogglesSet::begin` and `::end` (`Toggles.h:251`, `:254`), which
    /// `InheritFrom` (`Toggles.cpp:1040`) and both name getters walk upstream.
    pub fn iterator(self: TogglesSet) Iterator {
        return .{ .set_bits = self, .next_ordinal = 0 };
    }

    /// The state of one walk. A Zig iterator holds the cursor, where
    /// `ityp::bitset` returns a pair of iterators by value.
    pub const Iterator = struct {
        set_bits: TogglesSet,
        next_ordinal: usize,

        /// The next toggle that is present, or `null` at the end. Bound:
        /// the `toggle_count` ordinals, each visited at most once.
        pub fn next(self: *Iterator) ?Toggle {
            var ordinal = self.next_ordinal;
            while (ordinal < toggle_count) : (ordinal += 1) {
                if (self.set_bits.has(@fromBackingInt(@intCast(ordinal)))) {
                    self.next_ordinal = ordinal + 1;
                    return @fromBackingInt(@intCast(ordinal));
                }
            }
            self.next_ordinal = toggle_count;
            return null;
        }
    };
};

/// What one level holds: which toggles are set, which of them are enabled,
/// and which of them are forced. `TogglesState` (`Toggles.h:272-316`).
///
/// The field is `stage_value`, not `stage`, because `stage` is the accessor
/// upstream `GetStage` (`Toggles.cpp:1104`) becomes, and a Zig struct keeps
/// one name for a field and a function.
pub const TogglesState = struct {
    stage_value: ToggleStage,
    set: TogglesSet = .{},
    enabled: TogglesSet = .{},
    forced: TogglesSet = .{},

    /// An empty state for one level. `TogglesState::TogglesState`
    /// (`Toggles.cpp:994`). Nothing is set, nothing is enabled, nothing is
    /// forced.
    pub fn init(stage_value: ToggleStage) TogglesState {
        return .{ .stage_value = stage_value };
    }

    /// Walks the enabled names of a `DawnTogglesDescriptor` into this state.
    /// `TogglesState::CreateFromTogglesDescriptor` (`Toggles.cpp:996-1031`).
    /// Dawn walks `enabledToggles` (`:1005`) and then `disabledToggles`
    /// (`:1017`) with the same two rules in each loop. The enabled walk is
    /// this call. The disabled walk is `default(toggle, false)`, which writes
    /// the same two set bits and keeps the toggle unforced.
    ///
    /// A name the table does not carry is dropped without a diagnostic
    /// (`:1007`, `:1019`). A toggle from a later stage is dropped (`:1011`,
    /// `:1023`) because only the current stage and the earlier ones are taken,
    /// so an override there can still be inherited (`:1009`). Both
    /// asymmetries are deliberate upstream and stay here.
    pub fn createFromDescriptor(
        self: *TogglesState,
        names: []const []const u8,
        required_stage: ToggleStage,
    ) void {
        std.debug.assert(self.stage_value == required_stage);
        // Bound: the name slice the caller passes. No other bound is
        // possible.
        for (names) |name| {
            const toggle = toggleFromName(name) orelse continue;
            if (toggleInfo(toggle).stage > required_stage) continue;
            self.set.set(toggle);
            self.enabled.set(toggle);
        }
    }

    /// Takes from an earlier level. `TogglesState::InheritFrom`
    /// (`Toggles.cpp:1033-1055`). The earlier state must be an earlier level,
    /// an instance into an adapter or a device and an adapter into a device
    /// (`:1034`).
    ///
    /// A toggle this state already holds wins, and the one exception is a
    /// toggle the earlier level forced, because a force carries to every
    /// later level (`:1045-1050`).
    pub fn inheritFrom(self: *TogglesState, earlier: TogglesState) void {
        std.debug.assert(@backingInt(earlier.stage_value) < @backingInt(self.stage_value));
        var walk = earlier.set.iterator();
        while (walk.next()) |toggle| {
            std.debug.assert(toggleInfo(toggle).stage < self.stage_value);
            const is_enabled = earlier.enabled.has(toggle);
            const is_forced = earlier.forced.has(toggle);
            if (!self.set.has(toggle) or is_forced) {
                self.set.set(toggle);
                if (is_enabled) self.enabled.set(toggle);
                if (is_forced) self.forced.set(toggle);
            }
        }
    }

    /// Sets a toggle of this level, and only when the caller has not set it
    /// already. `TogglesState::Default` (`Toggles.cpp:1058-1066`). A back end
    /// calls this for the toggles it needs, so a caller's own requirement in
    /// the state wins (`:1061`).
    pub fn default(self: *TogglesState, toggle: Toggle, value: bool) void {
        std.debug.assert(toggleInfo(toggle).stage == self.stage_value);
        if (self.isSet(toggle)) return;
        self.set.set(toggle);
        if (value) self.enabled.set(toggle);
    }

    /// Forces a toggle of this level and marks it forced, so every later
    /// level inherits it as forced. `TogglesState::ForceSet`
    /// (`Toggles.cpp:1068-1080`).
    ///
    /// Dawn logs a warning when the value it forces is not the value the
    /// toggle holds (`:1073-1075`). A logger is M8's, so this returns
    /// whether the force flipped a set value and the caller logs it.
    pub fn forceSet(self: *TogglesState, toggle: Toggle, value: bool) bool {
        std.debug.assert(toggleInfo(toggle).stage == self.stage_value);
        // Dawn checks that a toggle is force-set at most once (`:1072`).
        std.debug.assert(!self.forced.has(toggle));
        var flipped = false;
        if (self.set.has(toggle)) flipped = self.enabled.has(toggle) != value;
        self.set.set(toggle);
        if (value) self.enabled.set(toggle);
        self.forced.set(toggle);
        return flipped;
    }

    /// Sets a toggle of any level for a test. `TogglesState::SetForTesting`
    /// (`Toggles.cpp:1082-1089`).
    ///
    /// The stage check is skipped on purpose, because a test drives a toggle
    /// from a level that does not own it. Dawn's third argument marks the
    /// toggle forced, and this port has `forceSet` for that.
    pub fn setForTesting(self: *TogglesState, toggle: Toggle, value: bool) void {
        self.set.set(toggle);
        if (value) self.enabled.set(toggle);
    }

    /// Whether the toggle is set, forced or not. `TogglesState::IsSet`
    /// (`Toggles.cpp:1091-1095`). A toggle is never read before its own
    /// level (`:1093`), so this traps on an earlier read.
    pub fn isSet(self: TogglesState, toggle: Toggle) bool {
        std.debug.assert(toggleInfo(toggle).stage <= self.stage_value);
        return self.set.has(toggle);
    }

    /// Whether the toggle is set to true. `TogglesState::IsEnabled`
    /// (`Toggles.cpp:1098-1102`). A toggle is never read before its own
    /// level (`:1100`).
    pub fn isEnabled(self: TogglesState, toggle: Toggle) bool {
        std.debug.assert(toggleInfo(toggle).stage <= self.stage_value);
        return self.enabled.has(toggle);
    }

    /// Which level this state holds. `TogglesState::GetStage`
    /// (`Toggles.cpp:1104-1106`).
    pub fn stage(self: TogglesState) ToggleStage {
        return self.stage_value;
    }

    /// The names of the toggles that are set and enabled.
    /// `TogglesState::GetEnabledToggleNames` (`Toggles.cpp:1108-1122`). Dawn
    /// returns a vector. This writes into `out` and returns the prefix it
    /// filled, so the caller owns the storage.
    pub fn getEnabledToggleNames(
        self: TogglesState,
        out: *[toggle_count][]const u8,
    ) []const []const u8 {
        var name_count: usize = 0;
        var walk = self.enabled.iterator();
        while (walk.next()) |toggle| {
            // Every enabled toggle is also set (`Toggles.cpp:1115`).
            std.debug.assert(self.set.has(toggle));
            out[name_count] = toggleName(toggle);
            name_count += 1;
        }
        std.debug.assert(name_count == self.enabled.count());
        return out[0..name_count];
    }

    /// The names of the toggles that are set and not enabled.
    /// `TogglesState::GetDisabledToggleNames` (`Toggles.cpp:1124-1139`).
    /// Dawn sizes the vector as `set.Count() - enabled.Count()` (`:1125`).
    /// This counts while it walks, and the count is the same, because the
    /// two lists together cover the set.
    pub fn getDisabledToggleNames(
        self: TogglesState,
        out: *[toggle_count][]const u8,
    ) []const []const u8 {
        var name_count: usize = 0;
        var walk = self.set.iterator();
        while (walk.next()) |toggle| {
            if (self.enabled.has(toggle)) continue;
            out[name_count] = toggleName(toggle);
            name_count += 1;
        }
        std.debug.assert(name_count == self.set.count() - self.enabled.count());
        return out[0..name_count];
    }
};

/// How many backwards branches the table's comptime walk may take.
///
/// The walk reads `infos` once per row for the stage and link rows and once
/// per ordered pair for the uniqueness sweep, so it is quadratic in the 183
/// rows and costs far more than a thousand backwards branches. What it walks is
/// fixed by the table rather than by anything the walk decides, so the budget
/// names what this table needs and still stops a walk that grows without
/// bound.
const table_walk_branch_budget: u32 = 1_000_000;

/// Runs the checks the table has to pass: the three counts agree with the
/// enumeration, every row carries a stage its name list holds, every link is
/// one this table ships, and no two rows share a name.
///
/// The walk lives in a function because `@setEvalBranchQuota` has a function
/// to attach to and a container-level `comptime` block does not.
fn assertTableIsWellFormed() void {
    @setEvalBranchQuota(table_walk_branch_budget);
    comptime {
        std.debug.assert(infos.len == toggle_count);
        std.debug.assert(instance_toggle_count + adapter_toggle_count + device_toggle_count ==
            toggle_count);
        var enum_field_count: usize = 0;
        for (@typeInfo(Toggle).@"enum".field_names) |_| enum_field_count += 1;
        std.debug.assert(enum_field_count == toggle_count);

        var instance_rows: usize = 0;
        var adapter_rows: usize = 0;
        var device_rows: usize = 0;
        for (infos) |info| {
            std.debug.assert(info.name.len > 0);
            std.debug.assert(info.description.len > 0);
            std.debug.assert(urlIsExpected(info.url));
            switch (info.stage) {
                .instance => {
                    instance_rows += 1;
                    std.debug.assert(namesContain(&instance_toggle_names, info.name));
                },
                .adapter => {
                    adapter_rows += 1;
                    std.debug.assert(namesContain(&adapter_toggle_names, info.name));
                },
                .device => device_rows += 1,
            }
        }
        std.debug.assert(instance_rows == instance_toggle_count);
        std.debug.assert(adapter_rows == adapter_toggle_count);
        std.debug.assert(device_rows == device_toggle_count);

        // The walk is not unrolled: 183 squared compares is a compile-time
        // cost with nothing to gain over the table itself.
        for (infos, 0..) |info, ordinal| {
            for (infos, 0..) |other, other_ordinal| {
                if (ordinal != other_ordinal) {
                    std.debug.assert(!std.mem.eql(u8, info.name, other.name));
                }
            }
        }
    }
}

comptime {
    assertTableIsWellFormed();
}
