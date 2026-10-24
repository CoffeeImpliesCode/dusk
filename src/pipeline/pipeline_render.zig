//! The render pipeline: the state, the descriptor rules, and the
//! `VkGraphicsPipelineCreateInfo`.
//!
//! **What this file is.** Dawn's `RenderPipelineBase`
//! (`src/dawn/native/RenderPipeline.cpp:960`) with the twelve descriptor
//! validators at `:113`-`:863` and `RenderPipeline::InitializeImpl`
//! (`src/dawn/native/vulkan/RenderPipelineVk.cpp:398`).
//!
//! **What this file does not claim.** It does not own a render pass. The caller
//! supplies a compatible traditional `VkRenderPass`, as Dawn's non-dynamic
//! path does (`vulkan/RenderPipelineVk.cpp:841-884`). M18's pass cache supplies
//! the same attachment formats and sample count for replay. It does not claim
//! the specialization map either: Dawn keeps one `VkPipeline` per distinct
//! pipeline-layout binding and per YCbCr set (`vulkan/RenderPipelineVk.h:108`),
//! and the port's dedup key already contains the layout's bytes, so one
//! descriptor is one specialization.

const std = @import("std");
const vulkan = @import("vulkan");

const pipeline = @import("pipeline.zig");
const pipeline_backend = @import("pipeline_backend.zig");

pub const Backend = pipeline_backend.Backend;
pub const BackendError = pipeline_backend.BackendError;
pub const PipelineError = pipeline.PipelineError;

/// The WebGPU vertex formats and the three facts each carries: bytes per
/// component, components, and whether the base type is signed, unsigned or
/// float. Dawn's `sVertexFormatTable` (`RenderPipeline.cpp:51`) has 43 rows and
/// `GetVertexFormatInfo` (`:105`) indexes it by the enumeration.
pub const VertexFormat = enum {
    uint8,
    uint8x2,
    uint8x4,
    sint8,
    sint8x2,
    sint8x4,
    unorm8,
    unorm8x2,
    unorm8x4,
    snorm8,
    snorm8x2,
    snorm8x4,
    uint16,
    uint16x2,
    uint16x4,
    sint16,
    sint16x2,
    sint16x4,
    unorm16,
    unorm16x2,
    unorm16x4,
    snorm16,
    snorm16x2,
    snorm16x4,
    float16,
    float16x2,
    float16x4,
    float32,
    float32x2,
    float32x3,
    float32x4,
    uint32,
    uint32x2,
    uint32x3,
    uint32x4,
    sint32,
    sint32x2,
    sint32x3,
    sint32x4,
    unorm10_10_10_2,
    unorm8x4_bgra,
    snorm10_10_10_2,
};

pub const VertexFormatBaseType = enum { uint, sint, float };

pub const VertexFormatInfo = struct {
    /// Bytes per component.
    component_byte_size: u8,
    component_count: u8,
    base_type: VertexFormatBaseType,
};

/// Dawn's `GetVertexFormatInfo` (`RenderPipeline.cpp:105`). One row per
/// enumeration member and no `else`, so a format added to the enum without a
/// row is a compile error rather than a zeroed answer.
pub fn vertexFormatInfo(format: VertexFormat) VertexFormatInfo {
    return switch (format) {
        .uint8 => .{ .component_byte_size = 1, .component_count = 1, .base_type = .uint },
        .uint8x2 => .{ .component_byte_size = 1, .component_count = 2, .base_type = .uint },
        .uint8x4 => .{ .component_byte_size = 1, .component_count = 4, .base_type = .uint },
        .sint8 => .{ .component_byte_size = 1, .component_count = 1, .base_type = .sint },
        .sint8x2 => .{ .component_byte_size = 1, .component_count = 2, .base_type = .sint },
        .sint8x4 => .{ .component_byte_size = 1, .component_count = 4, .base_type = .sint },
        .unorm8 => .{ .component_byte_size = 1, .component_count = 1, .base_type = .float },
        .unorm8x2 => .{ .component_byte_size = 1, .component_count = 2, .base_type = .float },
        .unorm8x4 => .{ .component_byte_size = 1, .component_count = 4, .base_type = .float },
        .snorm8 => .{ .component_byte_size = 1, .component_count = 1, .base_type = .float },
        .snorm8x2 => .{ .component_byte_size = 1, .component_count = 2, .base_type = .float },
        .snorm8x4 => .{ .component_byte_size = 1, .component_count = 4, .base_type = .float },
        .uint16 => .{ .component_byte_size = 2, .component_count = 1, .base_type = .uint },
        .uint16x2 => .{ .component_byte_size = 2, .component_count = 2, .base_type = .uint },
        .uint16x4 => .{ .component_byte_size = 2, .component_count = 4, .base_type = .uint },
        .sint16 => .{ .component_byte_size = 2, .component_count = 1, .base_type = .sint },
        .sint16x2 => .{ .component_byte_size = 2, .component_count = 2, .base_type = .sint },
        .sint16x4 => .{ .component_byte_size = 2, .component_count = 4, .base_type = .sint },
        .unorm16 => .{ .component_byte_size = 2, .component_count = 1, .base_type = .float },
        .unorm16x2 => .{ .component_byte_size = 2, .component_count = 2, .base_type = .float },
        .unorm16x4 => .{ .component_byte_size = 2, .component_count = 4, .base_type = .float },
        .snorm16 => .{ .component_byte_size = 2, .component_count = 1, .base_type = .float },
        .snorm16x2 => .{ .component_byte_size = 2, .component_count = 2, .base_type = .float },
        .snorm16x4 => .{ .component_byte_size = 2, .component_count = 4, .base_type = .float },
        .float16 => .{ .component_byte_size = 2, .component_count = 1, .base_type = .float },
        .float16x2 => .{ .component_byte_size = 2, .component_count = 2, .base_type = .float },
        .float16x4 => .{ .component_byte_size = 2, .component_count = 4, .base_type = .float },
        .float32 => .{ .component_byte_size = 4, .component_count = 1, .base_type = .float },
        .float32x2 => .{ .component_byte_size = 4, .component_count = 2, .base_type = .float },
        .float32x3 => .{ .component_byte_size = 4, .component_count = 3, .base_type = .float },
        .float32x4 => .{ .component_byte_size = 4, .component_count = 4, .base_type = .float },
        .uint32 => .{ .component_byte_size = 4, .component_count = 1, .base_type = .uint },
        .uint32x2 => .{ .component_byte_size = 4, .component_count = 2, .base_type = .uint },
        .uint32x3 => .{ .component_byte_size = 4, .component_count = 3, .base_type = .uint },
        .uint32x4 => .{ .component_byte_size = 4, .component_count = 4, .base_type = .uint },
        .sint32 => .{ .component_byte_size = 4, .component_count = 1, .base_type = .sint },
        .sint32x2 => .{ .component_byte_size = 4, .component_count = 2, .base_type = .sint },
        .sint32x3 => .{ .component_byte_size = 4, .component_count = 3, .base_type = .sint },
        .sint32x4 => .{ .component_byte_size = 4, .component_count = 4, .base_type = .sint },
        .unorm10_10_10_2 => .{ .component_byte_size = 4, .component_count = 4, .base_type = .float },
        .unorm8x4_bgra => .{ .component_byte_size = 1, .component_count = 4, .base_type = .float },
        .snorm10_10_10_2 => .{ .component_byte_size = 4, .component_count = 4, .base_type = .float },
    };
}

pub fn vertexFormatByteSize(format: VertexFormat) u32 {
    const info = vertexFormatInfo(format);
    return @as(u32, info.component_byte_size) * info.component_count;
}

/// The Vulkan format for a vertex format. Dawn's `VulkanVertexFormat`
/// (`vulkan/RenderPipelineVk.cpp:64`) is this table.
pub fn vertexFormatToVk(format: VertexFormat) vulkan.VkFormat {
    return switch (format) {
        .uint8 => vulkan.VK_FORMAT_R8_UINT,
        .uint8x2 => vulkan.VK_FORMAT_R8G8_UINT,
        .uint8x4 => vulkan.VK_FORMAT_R8G8B8A8_UINT,
        .sint8 => vulkan.VK_FORMAT_R8_SINT,
        .sint8x2 => vulkan.VK_FORMAT_R8G8_SINT,
        .sint8x4 => vulkan.VK_FORMAT_R8G8B8A8_SINT,
        .unorm8 => vulkan.VK_FORMAT_R8_UNORM,
        .unorm8x2 => vulkan.VK_FORMAT_R8G8_UNORM,
        .unorm8x4 => vulkan.VK_FORMAT_R8G8B8A8_UNORM,
        .snorm8 => vulkan.VK_FORMAT_R8_SNORM,
        .snorm8x2 => vulkan.VK_FORMAT_R8G8_SNORM,
        .snorm8x4 => vulkan.VK_FORMAT_R8G8B8A8_SNORM,
        .uint16 => vulkan.VK_FORMAT_R16_UINT,
        .uint16x2 => vulkan.VK_FORMAT_R16G16_UINT,
        .uint16x4 => vulkan.VK_FORMAT_R16G16B16A16_UINT,
        .sint16 => vulkan.VK_FORMAT_R16_SINT,
        .sint16x2 => vulkan.VK_FORMAT_R16G16_SINT,
        .sint16x4 => vulkan.VK_FORMAT_R16G16B16A16_SINT,
        .unorm16 => vulkan.VK_FORMAT_R16_UNORM,
        .unorm16x2 => vulkan.VK_FORMAT_R16G16_UNORM,
        .unorm16x4 => vulkan.VK_FORMAT_R16G16B16A16_UNORM,
        .snorm16 => vulkan.VK_FORMAT_R16_SNORM,
        .snorm16x2 => vulkan.VK_FORMAT_R16G16_SNORM,
        .snorm16x4 => vulkan.VK_FORMAT_R16G16B16A16_SNORM,
        .float16 => vulkan.VK_FORMAT_R16_SFLOAT,
        .float16x2 => vulkan.VK_FORMAT_R16G16_SFLOAT,
        .float16x4 => vulkan.VK_FORMAT_R16G16B16A16_SFLOAT,
        .float32 => vulkan.VK_FORMAT_R32_SFLOAT,
        .float32x2 => vulkan.VK_FORMAT_R32G32_SFLOAT,
        .float32x3 => vulkan.VK_FORMAT_R32G32B32_SFLOAT,
        .float32x4 => vulkan.VK_FORMAT_R32G32B32A32_SFLOAT,
        .uint32 => vulkan.VK_FORMAT_R32_UINT,
        .uint32x2 => vulkan.VK_FORMAT_R32G32_UINT,
        .uint32x3 => vulkan.VK_FORMAT_R32G32B32_UINT,
        .uint32x4 => vulkan.VK_FORMAT_R32G32B32A32_UINT,
        .sint32 => vulkan.VK_FORMAT_R32_SINT,
        .sint32x2 => vulkan.VK_FORMAT_R32G32_SINT,
        .sint32x3 => vulkan.VK_FORMAT_R32G32B32_SINT,
        .sint32x4 => vulkan.VK_FORMAT_R32G32B32A32_SINT,
        .unorm10_10_10_2 => vulkan.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        .unorm8x4_bgra => vulkan.VK_FORMAT_A8B8G8R8_UNORM_PACK32,
        .snorm10_10_10_2 => vulkan.VK_FORMAT_A2B10G10R10_SNORM_PACK32,
    };
}

pub const StepMode = enum { vertex, instance };
pub const Topology = enum { point_list, line_list, line_strip, triangle_list, triangle_strip };
pub const FrontFace = enum { counter_clockwise, clockwise };
pub const CullMode = enum { none, front, back };
pub const IndexFormat = enum { uint16, uint32 };
pub const CompareFunction = enum {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};
pub const StencilOperation = enum {
    keep,
    zero,
    replace,
    increment_and_clamp,
    decrement_and_clamp,
    invert,
    increment_and_wrap,
    decrement_and_wrap,
};
pub const BlendFactor = enum {
    zero,
    one,
    src,
    one_minus_src,
    src_alpha,
    one_minus_src_alpha,
    dst,
    one_minus_dst,
    dst_alpha,
    one_minus_dst_alpha,
    constant,
    one_minus_constant,
    src_alpha_saturate,
    src1,
    one_minus_src1,
    src1_alpha,
    one_minus_src1_alpha,
};
pub const BlendOperation = enum { add, subtract, reverse_subtract, min, max };

pub const VertexBufferLayout = struct {
    array_stride: u32,
    step_mode: StepMode = .vertex,
};

pub const VertexAttributeLayout = struct {
    /// `Location` in the WebGPU descriptor.
    shader_location: u32,
    /// The vertex buffer slot the attribute reads.
    input_slot: u32,
    offset: u32,
    format: VertexFormat,
};

pub const PrimitiveState = struct {
    topology: Topology = .triangle_list,
    strip_index_format: ?IndexFormat = null,
    front_face: FrontFace = .counter_clockwise,
    cull_mode: CullMode = .none,
    unclipped_depth: bool = false,
};

pub const StencilFaceState = struct {
    compare: CompareFunction = .always,
    fail_op: StencilOperation = .keep,
    depth_fail_op: StencilOperation = .keep,
    pass_op: StencilOperation = .keep,
};

pub const DepthStencilState = struct {
    format: vulkan.VkFormat,
    depth_write_enabled: bool = false,
    depth_compare: CompareFunction = .always,
    stencil_front: StencilFaceState = .{},
    stencil_back: StencilFaceState = .{},
    stencil_read_mask: u32 = std.math.maxInt(u32),
    stencil_write_mask: u32 = std.math.maxInt(u32),
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
};

pub const BlendComponent = struct {
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
    operation: BlendOperation,
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

pub const ColorTargetState = struct {
    /// Undefined preserves a genuine absent attachment slot. Its mask and blend are ignored.
    format: vulkan.VkFormat,
    /// The four `VK_COLOR_COMPONENT_*` bits, as Dawn's `ColorTargetState`
    /// stores it and `ValidateColorWriteMask` checks (`RenderPipeline.cpp:521`).
    write_mask: u32 = 0xF,
    blend: ?BlendState = null,
};

pub const MultisampleState = struct {
    count: u32 = 1,
    mask: u32 = 0xFFFFFFFF,
    alpha_to_coverage: bool = false,
};

/// The Vulkan-facing state, built once and pointed at by the create info.
///
/// Dawn keeps the equivalent as stack temporaries plus one
/// `PipelineVertexInputStateCreateInfoTemporaryAllocations`
/// (`vulkan/RenderPipelineVk.h:93`); the port keeps them in one struct the
/// caller owns, so no function returns a pointer into its own frame.
pub const Scratch = struct {
    // SAFETY: `buildRenderState` writes `stages[0]` unconditionally and
    // `stages[1]` only when the descriptor carries a fragment stage, then
    // stores the count it wrote in `stage_count`. Every read is through
    // `pStages` paired with that same `stageCount`, which is what the Vulkan
    // spec requires: a driver may read no further than the count. The second
    // slot is written before any `pStages` read whenever it is reachable.
    stages: [2]vulkan.VkPipelineShaderStageCreateInfo = undefined,
    stage_count: u32 = 0,
    /// Owns native C names through pipeline creation, including partial builds.
    stage_names: [2]?[:0]u8 = .{ null, null },
    bindings: std.ArrayList(vulkan.VkVertexInputBindingDescription) = .empty,
    attributes: std.ArrayList(vulkan.VkVertexInputAttributeDescription) = .empty,
    blend_states: std.ArrayList(vulkan.VkPipelineColorBlendAttachmentState) = .empty,
    dynamic_states: [4]vulkan.VkDynamicState = .{
        vulkan.VK_DYNAMIC_STATE_VIEWPORT,
        vulkan.VK_DYNAMIC_STATE_SCISSOR,
        vulkan.VK_DYNAMIC_STATE_STENCIL_REFERENCE,
        vulkan.VK_DYNAMIC_STATE_BLEND_CONSTANTS,
    },
    vertex_input: vulkan.VkPipelineVertexInputStateCreateInfo = .{},
    input_assembly: vulkan.VkPipelineInputAssemblyStateCreateInfo = .{},
    viewport: vulkan.VkPipelineViewportStateCreateInfo = .{},
    rasterization: vulkan.VkPipelineRasterizationStateCreateInfo = .{},
    multisample: vulkan.VkPipelineMultisampleStateCreateInfo = .{},
    depth_stencil: vulkan.VkPipelineDepthStencilStateCreateInfo = .{},
    color_blend: vulkan.VkPipelineColorBlendStateCreateInfo = .{},
    dynamic: vulkan.VkPipelineDynamicStateCreateInfo = .{},
    create_info: vulkan.VkGraphicsPipelineCreateInfo = .{},

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        for (self.stage_names) |name| {
            if (name) |owned| allocator.free(owned);
        }
        self.bindings.deinit(allocator);
        self.attributes.deinit(allocator);
        self.blend_states.deinit(allocator);
        self.* = undefined;
    }
};

/// Every rule the render descriptor can break, in Dawn's order.
///
/// Dawn's entry point is `ValidateRenderPipelineDescriptor`
/// (`RenderPipeline.cpp:884`), which runs the vertex, primitive,
/// depth-stencil, multisample, colour-target and fragment rules in that order
/// and names the first that fails. The port does the same, so the error a
/// caller sees is the error Dawn would have raised.
pub fn validateRenderPipelineDescriptor(
    descriptor: pipeline.RenderPipelineDescriptor,
) PipelineError!void {
    if (descriptor.vertex.stage != .vertex) return error.StageMismatch;
    if (descriptor.fragment) |fragment| {
        if (fragment.stage != .fragment) return error.StageMismatch;
    }
    try validateVertexAttributes(descriptor.vertex_attributes);
    try validateVertexBuffers(descriptor.vertex_buffers, descriptor.vertex_attributes);
    try validatePrimitiveState(descriptor.primitive);
    try validateDepthStencil(descriptor.depth_stencil, attachmentFormat(descriptor), false);
    try validateMultisampleState(descriptor.multisample);
    try validateColorTargetStates(descriptor.color_targets);
}

/// Dawn's `ValidateVertexAttribute` (`RenderPipeline.cpp:113`) and
/// `ValidateVertexBufferLayout` (`:170`), fused because both answer "does this
/// slot exist and does this attribute fit in it".
fn validateVertexAttributes(attributes: []const VertexAttributeLayout) PipelineError!void {
    for (attributes) |attribute| {
        if (attribute.shader_location >= max_vertex_attributes) {
            return error.VertexAttributeSlotAboveLimit;
        }
        if (vertexFormatByteSize(attribute.format) == 0) {
            return error.VertexAttributeFormatUnsupported;
        }
    }
}

fn validateVertexBuffers(
    buffers: []const VertexBufferLayout,
    attributes: []const VertexAttributeLayout,
) PipelineError!void {
    if (buffers.len > max_vertex_buffers) return error.VertexBufferSlotAboveLimit;
    for (attributes) |attribute| {
        if (attribute.input_slot >= buffers.len) return error.VertexBufferSlotAboveLimit;
        const buffer = buffers[attribute.input_slot];
        const end = @as(u64, attribute.offset) + vertexFormatByteSize(attribute.format);
        if (end > buffer.array_stride) return error.VertexBufferStrideTooSmall;
    }
}

fn validatePrimitiveState(primitive: PrimitiveState) PipelineError!void {
    if (isStripTopology(primitive.topology)) {
        if (primitive.strip_index_format == null) {
            return error.StripIndexFormatNotSetForStripTopology;
        }
    } else if (primitive.strip_index_format != null) {
        return error.StripIndexFormatSetForNonStripTopology;
    }
}

/// Dawn's `IsStripPrimitiveTopology` (`RenderPipeline.cpp:879`).
pub fn isStripTopology(topology: Topology) bool {
    return topology == .line_strip or topology == .triangle_strip;
}

/// Dawn's `ValidateDepthStencilState` (`RenderPipeline.cpp:314`), including
/// the compatibility clamp rule at `:345`.
///
/// `attachment_format` is `VK_FORMAT_UNDEFINED` when the descriptor has no
/// depth-stencil attachment.
pub fn validateDepthStencil(
    depth_stencil: ?DepthStencilState,
    attachment_format: vulkan.VkFormat,
    compatibility: bool,
) PipelineError!void {
    if (depth_stencil == null) {
        if (attachment_format != vulkan.VK_FORMAT_UNDEFINED) {
            return error.DepthStencilFormatSetWithoutState;
        }
        return;
    }
    const state = depth_stencil.?;
    if (attachment_format == vulkan.VK_FORMAT_UNDEFINED) {
        return error.DepthStencilFormatUndefinedWithDepthStencilState;
    }
    const has_stencil = switch (state.format) {
        vulkan.VK_FORMAT_S8_UINT,
        vulkan.VK_FORMAT_D16_UNORM_S8_UINT,
        vulkan.VK_FORMAT_D24_UNORM_S8_UINT,
        vulkan.VK_FORMAT_D32_SFLOAT_S8_UINT,
        => true,
        else => false,
    };
    // Dawn checks unused faces only without stencil (`RenderPipeline.cpp:379-387`).
    if (!has_stencil) {
        try validateStencilFaceUnused(state.stencil_front);
        try validateStencilFaceUnused(state.stencil_back);
    }
    if (compatibility and state.depth_bias_clamp != 0) {
        return error.CompatibilityDepthBiasClampNonZero;
    }
}

/// Dawn's `ValidateStencilFaceUnused` (`RenderPipeline.cpp:294-311`).
/// The low-level enums contain no undefined values. The API boundary handles those.
fn validateStencilFaceUnused(face: StencilFaceState) PipelineError!void {
    if (face.compare != .always or
        face.fail_op != .keep or
        face.depth_fail_op != .keep or
        face.pass_op != .keep)
    {
        return error.StencilStateWithoutStencilAspect;
    }
}

fn validateMultisampleState(state: MultisampleState) PipelineError!void {
    if (state.count == 0 or !isSupportedSampleCount(state.count)) {
        return error.MultisampleCountUnsupported;
    }
    if (state.count != 1 and state.alpha_to_coverage) {
        return error.AlphaToCoverageWithSampleCountNotOne;
    }
    if (state.count != 1 and state.mask != 0xFFFFFFFF) {
        return error.SampleMaskNotOne;
    }
}

/// Dawn's `ValidateMultisampleState` (`RenderPipeline.cpp:411-417`) accepts only
/// 1 and 4, the counts `IsValidSampleCount` names (`Texture.cpp:1079-1088`); the
/// port accepts every count the `VK_SAMPLE_COUNT_*` bits name.
fn isSupportedSampleCount(count: u32) bool {
    return count == 1 or count == 2 or count == 4 or count == 8 or
        count == 16 or count == 32 or count == 64;
}

/// Dawn's `ValidateColorTargetState` (`RenderPipeline.cpp:495`).
fn validateColorTargetStates(targets: []const ColorTargetState) PipelineError!void {
    if (targets.len > max_color_attachments) return error.ColorTargetCountAboveLimit;
    for (targets) |target| {
        if (target.format == vulkan.VK_FORMAT_UNDEFINED) continue;
        // None is legal. Only bits outside RGBA are invalid (`dawn.json:840-848`).
        if (target.write_mask & ~@as(u32, 0xF) != 0) return error.ColorWriteMaskInvalid;
        if (target.blend) |blend| {
            try validateBlendComponent(blend.color);
            try validateBlendComponent(blend.alpha);
        }
    }
}

/// Dawn's `ValidateBlendComponent` (`RenderPipeline.cpp:423`).
fn validateBlendComponent(component: BlendComponent) PipelineError!void {
    switch (component.src_factor) {
        .zero,
        .one,
        .src,
        .one_minus_src,
        .src_alpha,
        .one_minus_src_alpha,
        .dst,
        .one_minus_dst,
        .dst_alpha,
        .one_minus_dst_alpha,
        .constant,
        .one_minus_constant,
        .src_alpha_saturate,
        .src1,
        .one_minus_src1,
        .src1_alpha,
        .one_minus_src1_alpha,
        => {},
    }
    switch (component.dst_factor) {
        .zero,
        .one,
        .src,
        .one_minus_src,
        .src_alpha,
        .one_minus_src_alpha,
        .dst,
        .one_minus_dst,
        .dst_alpha,
        .one_minus_dst_alpha,
        .constant,
        .one_minus_constant,
        .src_alpha_saturate,
        .src1,
        .one_minus_src1,
        .src1_alpha,
        .one_minus_src1_alpha,
        => {},
    }
    switch (component.operation) {
        .add, .subtract, .reverse_subtract, .min, .max => {},
    }
}

/// `maxVertexBuffers` in the WebGPU limits Dawn's table checks against
/// (`RenderPipeline.cpp:200-206`).
pub const max_vertex_buffers = 8;

/// `maxVertexAttributes` in the WebGPU limits (`RenderPipeline.cpp:121-126`).
pub const max_vertex_attributes = 16;

/// `maxColorAttachments` in the WebGPU limits (`RenderPipeline.cpp:663-669`).
pub const max_color_attachments = 8;

/// The depth-stencil format the descriptor's attachment state carries, or
/// `VK_FORMAT_UNDEFINED` when it has none.
fn attachmentFormat(descriptor: pipeline.RenderPipelineDescriptor) vulkan.VkFormat {
    if (descriptor.depth_stencil) |state| return state.format;
    return vulkan.VK_FORMAT_UNDEFINED;
}

/// Writes the bytes the render content hash records for the depth-stencil
/// block. `RenderPipeline.cpp:1351-1360` is the same list.
pub fn appendDepthStencilKey(
    allocator: std.mem.Allocator,
    key: *pipeline.CacheKey,
    state: DepthStencilState,
) std.mem.Allocator.Error!void {
    // `VkFormat` is a `c_uint` at this pin (`src/vulkan.zig:2866`), not an
    // enumeration, so the number itself is what the key records.
    try key.appendWord(allocator, state.format);
    try key.appendWord(allocator, @intFromBool(state.depth_write_enabled));
    try key.appendEnum(allocator, state.depth_compare);
    try appendStencilFaceKey(allocator, key, state.stencil_front);
    try appendStencilFaceKey(allocator, key, state.stencil_back);
    try key.appendWord(allocator, state.stencil_read_mask);
    try key.appendWord(allocator, state.stencil_write_mask);
    // The three bias values are 32-bit, and a word is eight bytes, so each is
    // reinterpreted at its own width and then widened. The widening is what
    // keeps two keys apart: `-1` and `0xFFFFFFFF` are the same bits and must
    // read back as the same key, and a sign-extended word would not.
    try key.appendWord(allocator, @as(u32, @bitCast(state.depth_bias)));
    try key.appendWord(allocator, @as(u32, @bitCast(state.depth_bias_slope_scale)));
    try key.appendWord(allocator, @as(u32, @bitCast(state.depth_bias_clamp)));
}

fn appendStencilFaceKey(
    allocator: std.mem.Allocator,
    key: *pipeline.CacheKey,
    face: StencilFaceState,
) std.mem.Allocator.Error!void {
    try key.appendEnum(allocator, face.compare);
    try key.appendEnum(allocator, face.fail_op);
    try key.appendEnum(allocator, face.depth_fail_op);
    try key.appendEnum(allocator, face.pass_op);
}

/// Copies the immutable state the replay path and the key read, and fills the
/// Vulkan create-info scratch.
pub fn buildRenderState(
    allocator: std.mem.Allocator,
    descriptor: pipeline.RenderPipelineDescriptor,
    state: *pipeline.State,
    scratch: *Scratch,
) std.mem.Allocator.Error!void {
    state.* = .{ .render = .{} };
    const render = switch (state.*) {
        .render => |*render| render,
        .compute => unreachable,
    };
    render.fragment_stage_present = descriptor.fragment != null;

    try copySlice(VertexBufferLayout, allocator, &render.vertex_buffers, descriptor.vertex_buffers);
    try copySlice(
        VertexAttributeLayout,
        allocator,
        &render.vertex_attributes,
        descriptor.vertex_attributes,
    );
    try copySlice(vulkan.VkFormat, allocator, &render.color_formats, &.{});
    try copySlice(u32, allocator, &render.color_write_masks, &.{});
    try copySlice(bool, allocator, &render.blend_enabled, &.{});
    render.primitive = descriptor.primitive;
    render.depth_stencil = descriptor.depth_stencil;
    render.multisample = descriptor.multisample;

    try appendColorTargets(allocator, render, descriptor.color_targets);
    try fillStages(allocator, scratch, descriptor);
    try fillScratch(allocator, scratch, descriptor);
}

/// Copies one descriptor list into the render state. The element type is a
/// parameter because the five lists `buildRenderState` copies are five
/// different types and none of them earns a function of its own.
fn copySlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(T),
    items: []const T,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, items);
}

/// The per-target facts the cache key and the replay path both read, in one
/// pass, so the two can never disagree about the list length.
fn appendColorTargets(
    allocator: std.mem.Allocator,
    render: *pipeline.RenderState,
    targets: []const ColorTargetState,
) std.mem.Allocator.Error!void {
    try render.color_formats.ensureTotalCapacity(allocator, targets.len);
    try render.color_write_masks.ensureTotalCapacity(allocator, targets.len);
    try render.blend_enabled.ensureTotalCapacity(allocator, targets.len);
    for (targets) |target| {
        render.color_formats.appendAssumeCapacity(target.format);
        const present = target.format != vulkan.VK_FORMAT_UNDEFINED;
        render.color_write_masks.appendAssumeCapacity(if (present) target.write_mask else 0);
        render.blend_enabled.appendAssumeCapacity(present and target.blend != null);
    }
}

/// Dawn's stage list, `GetRenderStagesAndSetPlaceholderShader`
/// (`RenderPipeline.cpp:938`). The port has no placeholder shader to set,
/// because a descriptor with no fragment stage is legal and Vulkan takes the
/// stage count it is given.
fn fillStages(
    allocator: std.mem.Allocator,
    scratch: *Scratch,
    descriptor: pipeline.RenderPipelineDescriptor,
) std.mem.Allocator.Error!void {
    std.debug.assert(scratch.stage_count == 0);
    std.debug.assert(scratch.stage_names[0] == null);
    std.debug.assert(scratch.stage_names[1] == null);
    const vertex_name = try allocator.dupeSentinel(u8, descriptor.vertex.entry_point, 0);
    scratch.stage_names[0] = vertex_name;
    scratch.stages[0] = makeStage(&descriptor.vertex, vertex_name);
    scratch.stage_count = 1;
    if (descriptor.fragment) |fragment| {
        const fragment_name = try allocator.dupeSentinel(u8, fragment.entry_point, 0);
        scratch.stage_names[1] = fragment_name;
        scratch.stages[1] = makeStage(&fragment, fragment_name);
        scratch.stage_count = 2;
    }
}

fn makeStage(
    input: *const pipeline.StageInput,
    entry_point: [:0]const u8,
) vulkan.VkPipelineShaderStageCreateInfo {
    return .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = stageFlagBits(input.stage),
        .module = input.module,
        .pName = entry_point.ptr,
    };
}

/// The `VkShaderStageFlagBits` for a stage. No `else`, so a stage added without
/// a Vulkan bit is a compile error.
pub fn stageFlagBits(stage: pipeline.Stage) vulkan.VkShaderStageFlagBits {
    return switch (stage) {
        .vertex => vulkan.VK_SHADER_STAGE_VERTEX_BIT,
        .fragment => vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
        .compute => vulkan.VK_SHADER_STAGE_COMPUTE_BIT,
    };
}

fn fillScratch(
    allocator: std.mem.Allocator,
    scratch: *Scratch,
    descriptor: pipeline.RenderPipelineDescriptor,
) std.mem.Allocator.Error!void {
    try scratch.bindings.ensureTotalCapacity(allocator, descriptor.vertex_buffers.len);
    for (descriptor.vertex_buffers, 0..) |buffer, slot| {
        scratch.bindings.appendAssumeCapacity(.{
            .binding = @intCast(slot),
            .stride = buffer.array_stride,
            .inputRate = stepModeToVk(buffer.step_mode),
        });
    }
    try scratch.attributes.ensureTotalCapacity(allocator, descriptor.vertex_attributes.len);
    for (descriptor.vertex_attributes) |attribute| {
        scratch.attributes.appendAssumeCapacity(.{
            .location = attribute.shader_location,
            .binding = attribute.input_slot,
            .format = vertexFormatToVk(attribute.format),
            .offset = attribute.offset,
        });
    }
    try scratch.blend_states.ensureTotalCapacity(allocator, descriptor.color_targets.len);
    for (descriptor.color_targets) |target| {
        scratch.blend_states.appendAssumeCapacity(makeBlendState(target));
    }

    scratch.vertex_input = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = @intCast(scratch.bindings.items.len),
        .pVertexBindingDescriptions = scratch.bindings.items.ptr,
        .vertexAttributeDescriptionCount = @intCast(scratch.attributes.items.len),
        .pVertexAttributeDescriptions = scratch.attributes.items.ptr,
    };
    scratch.input_assembly = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = topologyToVk(descriptor.primitive.topology),
        .primitiveRestartEnable = shouldEnablePrimitiveRestart(
            descriptor.primitive.topology,
        ),
    };
    // Dawn makes viewport and scissor dynamic: the Vulkan backend writes them
    // per pass at `vulkan/CommandBufferVk.cpp:1781` and `:1788`, so the
    // descriptor carries neither and the count is one.
    scratch.viewport = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    scratch.rasterization = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = @intFromBool(descriptor.primitive.unclipped_depth),
        .polygonMode = vulkan.VK_POLYGON_MODE_FILL,
        .cullMode = cullModeToVk(descriptor.primitive.cull_mode),
        .frontFace = frontFaceToVk(descriptor.primitive.front_face),
        .depthBiasEnable = @intFromBool(isDepthBiasEnabled(descriptor.depth_stencil)),
        .depthBiasConstantFactor = @floatFromInt(depthBias(descriptor.depth_stencil)),
        .depthBiasClamp = depthBiasClamp(descriptor.depth_stencil),
        .depthBiasSlopeFactor = depthBiasSlopeScale(descriptor.depth_stencil),
        .lineWidth = 1.0,
    };
    scratch.multisample = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = @intCast(descriptor.multisample.count),
        .alphaToCoverageEnable = @intFromBool(descriptor.multisample.alpha_to_coverage),
        .pSampleMask = null,
    };
    scratch.depth_stencil = makeDepthStencil(descriptor.depth_stencil);
    scratch.color_blend = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = @intCast(scratch.blend_states.items.len),
        .pAttachments = scratch.blend_states.items.ptr,
    };
    scratch.dynamic = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = scratch.dynamic_states.len,
        .pDynamicStates = &scratch.dynamic_states,
    };
    scratch.create_info = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .stageCount = scratch.stage_count,
        .pStages = &scratch.stages,
        .pVertexInputState = &scratch.vertex_input,
        .pInputAssemblyState = &scratch.input_assembly,
        .pViewportState = &scratch.viewport,
        .pRasterizationState = &scratch.rasterization,
        .pMultisampleState = &scratch.multisample,
        .pDepthStencilState = if (descriptor.depth_stencil == null) null else &scratch.depth_stencil,
        .pColorBlendState = &scratch.color_blend,
        .pDynamicState = &scratch.dynamic,
        .layout = descriptor.layout.handle,
        .renderPass = descriptor.compatible_render_pass,
        .subpass = 0,
    };
}

fn makeBlendState(target: ColorTargetState) vulkan.VkPipelineColorBlendAttachmentState {
    if (target.format == vulkan.VK_FORMAT_UNDEFINED)
        return .{ .blendEnable = 0, .colorWriteMask = 0 };
    const blend = target.blend orelse return .{
        .blendEnable = 0,
        .colorWriteMask = target.write_mask,
    };
    return .{
        .blendEnable = 1,
        .srcColorBlendFactor = blendFactorToVk(blend.color.src_factor),
        .dstColorBlendFactor = blendFactorToVk(blend.color.dst_factor),
        .colorBlendOp = blendOperationToVk(blend.color.operation),
        .srcAlphaBlendFactor = blendFactorToVk(blend.alpha.src_factor),
        .dstAlphaBlendFactor = blendFactorToVk(blend.alpha.dst_factor),
        .alphaBlendOp = blendOperationToVk(blend.alpha.operation),
        .colorWriteMask = target.write_mask,
    };
}

fn makeDepthStencil(state: ?DepthStencilState) vulkan.VkPipelineDepthStencilStateCreateInfo {
    const depth_stencil = state orelse return .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    };
    return .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = 1,
        .depthWriteEnable = @intFromBool(depth_stencil.depth_write_enabled),
        .depthCompareOp = compareFunctionToVk(depth_stencil.depth_compare),
        .stencilTestEnable = @intFromBool(usesStencil(depth_stencil)),
        .front = makeStencilOpState(
            depth_stencil.stencil_front,
            depth_stencil.stencil_read_mask,
            depth_stencil.stencil_write_mask,
        ),
        .back = makeStencilOpState(
            depth_stencil.stencil_back,
            depth_stencil.stencil_read_mask,
            depth_stencil.stencil_write_mask,
        ),
    };
}

fn makeStencilOpState(
    face: StencilFaceState,
    read_mask: u32,
    write_mask: u32,
) vulkan.VkStencilOpState {
    return .{
        .failOp = stencilOperationToVk(face.fail_op),
        .depthFailOp = stencilOperationToVk(face.depth_fail_op),
        .passOp = stencilOperationToVk(face.pass_op),
        .compareOp = compareFunctionToVk(face.compare),
        .compareMask = read_mask,
        .writeMask = write_mask,
    };
}

/// Comparison-only stencil state must remain enabled: it reads the dynamic
/// reference even when every stencil operation keeps the stored value.
pub fn usesStencil(state: DepthStencilState) bool {
    return state.stencil_front.compare != .always or
        state.stencil_back.compare != .always or
        state.stencil_front.fail_op != .keep or
        state.stencil_front.depth_fail_op != .keep or
        state.stencil_front.pass_op != .keep or
        state.stencil_back.fail_op != .keep or
        state.stencil_back.depth_fail_op != .keep or
        state.stencil_back.pass_op != .keep;
}

/// Dawn's `IsDepthBiasEnabled` (`RenderPipeline.cpp:1217`).
pub fn isDepthBiasEnabled(state: ?DepthStencilState) bool {
    const depth_stencil = state orelse return false;
    return depth_stencil.depth_bias != 0 or
        depth_stencil.depth_bias_slope_scale != 0 or
        depth_stencil.depth_bias_clamp != 0;
}

pub fn depthBias(state: ?DepthStencilState) i32 {
    const depth_stencil = state orelse return 0;
    return depth_stencil.depth_bias;
}

pub fn depthBiasSlopeScale(state: ?DepthStencilState) f32 {
    const depth_stencil = state orelse return 0;
    return depth_stencil.depth_bias_slope_scale;
}

pub fn depthBiasClamp(state: ?DepthStencilState) f32 {
    const depth_stencil = state orelse return 0;
    return depth_stencil.depth_bias_clamp;
}

pub fn stepModeToVk(mode: StepMode) vulkan.VkVertexInputRate {
    return switch (mode) {
        .vertex => vulkan.VK_VERTEX_INPUT_RATE_VERTEX,
        .instance => vulkan.VK_VERTEX_INPUT_RATE_INSTANCE,
    };
}

pub fn topologyToVk(topology: Topology) vulkan.VkPrimitiveTopology {
    return switch (topology) {
        .point_list => vulkan.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        .line_list => vulkan.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        .line_strip => vulkan.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        .triangle_list => vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .triangle_strip => vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
}

/// Dawn's `ShouldEnablePrimitiveRestart` (`vulkan/RenderPipelineVk.cpp:173`):
/// a strip index format is what makes restart meaningful.
pub fn shouldEnablePrimitiveRestart(topology: Topology) vulkan.VkBool32 {
    return @intFromBool(topology == .line_strip or topology == .triangle_strip);
}

pub fn frontFaceToVk(front_face: FrontFace) vulkan.VkFrontFace {
    return switch (front_face) {
        .counter_clockwise => vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .clockwise => vulkan.VK_FRONT_FACE_CLOCKWISE,
    };
}

pub fn cullModeToVk(cull_mode: CullMode) vulkan.VkCullModeFlags {
    return switch (cull_mode) {
        .none => vulkan.VK_CULL_MODE_NONE,
        .front => vulkan.VK_CULL_MODE_FRONT_BIT,
        .back => vulkan.VK_CULL_MODE_BACK_BIT,
    };
}

pub fn compareFunctionToVk(compare: CompareFunction) vulkan.VkCompareOp {
    return switch (compare) {
        .never => vulkan.VK_COMPARE_OP_NEVER,
        .less => vulkan.VK_COMPARE_OP_LESS,
        .equal => vulkan.VK_COMPARE_OP_EQUAL,
        .less_equal => vulkan.VK_COMPARE_OP_LESS_OR_EQUAL,
        .greater => vulkan.VK_COMPARE_OP_GREATER,
        .not_equal => vulkan.VK_COMPARE_OP_NOT_EQUAL,
        .greater_equal => vulkan.VK_COMPARE_OP_GREATER_OR_EQUAL,
        .always => vulkan.VK_COMPARE_OP_ALWAYS,
    };
}

pub fn stencilOperationToVk(operation: StencilOperation) vulkan.VkStencilOp {
    return switch (operation) {
        .keep => vulkan.VK_STENCIL_OP_KEEP,
        .zero => vulkan.VK_STENCIL_OP_ZERO,
        .replace => vulkan.VK_STENCIL_OP_REPLACE,
        .increment_and_clamp => vulkan.VK_STENCIL_OP_INCREMENT_AND_CLAMP,
        .decrement_and_clamp => vulkan.VK_STENCIL_OP_DECREMENT_AND_CLAMP,
        .invert => vulkan.VK_STENCIL_OP_INVERT,
        .increment_and_wrap => vulkan.VK_STENCIL_OP_INCREMENT_AND_WRAP,
        .decrement_and_wrap => vulkan.VK_STENCIL_OP_DECREMENT_AND_WRAP,
    };
}

pub fn blendFactorToVk(factor: BlendFactor) vulkan.VkBlendFactor {
    return switch (factor) {
        .zero => vulkan.VK_BLEND_FACTOR_ZERO,
        .one => vulkan.VK_BLEND_FACTOR_ONE,
        .src => vulkan.VK_BLEND_FACTOR_SRC_COLOR,
        .one_minus_src => vulkan.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
        .src_alpha => vulkan.VK_BLEND_FACTOR_SRC_ALPHA,
        .one_minus_src_alpha => vulkan.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .dst => vulkan.VK_BLEND_FACTOR_DST_COLOR,
        .one_minus_dst => vulkan.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
        .dst_alpha => vulkan.VK_BLEND_FACTOR_DST_ALPHA,
        .one_minus_dst_alpha => vulkan.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        .constant => vulkan.VK_BLEND_FACTOR_CONSTANT_COLOR,
        .one_minus_constant => vulkan.VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR,
        .src_alpha_saturate => vulkan.VK_BLEND_FACTOR_SRC_ALPHA_SATURATE,
        .src1 => vulkan.VK_BLEND_FACTOR_SRC1_COLOR,
        .one_minus_src1 => vulkan.VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR,
        .src1_alpha => vulkan.VK_BLEND_FACTOR_SRC1_ALPHA,
        .one_minus_src1_alpha => vulkan.VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
    };
}

pub fn blendOperationToVk(operation: BlendOperation) vulkan.VkBlendOp {
    return switch (operation) {
        .add => vulkan.VK_BLEND_OP_ADD,
        .subtract => vulkan.VK_BLEND_OP_SUBTRACT,
        .reverse_subtract => vulkan.VK_BLEND_OP_REVERSE_SUBTRACT,
        .min => vulkan.VK_BLEND_OP_MIN,
        .max => vulkan.VK_BLEND_OP_MAX,
    };
}

/// Creates the `VkPipeline` and nothing else. Dawn's `InitializeImpl`
/// (`vulkan/RenderPipelineVk.cpp:398`) ends at the same call
/// (`vulkan/RenderPipelineVk.cpp:933`), with a `VkPipelineCache` Dawn asks the
/// device for; the port passes `null`, which Vulkan defines as "no cache", and
/// M18's replay reuses the compiled pipeline across passes.
pub fn createGraphicsPipeline(
    backend: *const Backend,
    scratch: *const Scratch,
) (BackendError || error{CompatibleRenderPassMissing})!vulkan.VkPipeline {
    if (scratch.create_info.renderPass == null) return error.CompatibleRenderPassMissing;
    const create = backend.create_graphics_pipelines orelse
        return error.CreateGraphicsPipelinesNotLoaded;
    var handle: vulkan.VkPipeline = null;
    try vkCheck(create(backend.device, null, 1, &scratch.create_info, null, &handle));
    return handle;
}

const vk = @import("../vk/dispatch.zig");

fn vkCheck(code: vulkan.VkResult) BackendError!void {
    return vk.checkVkSuccess(code);
}
