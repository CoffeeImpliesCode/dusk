//! The Vulkan serialiser: one generic, one comptime field list per type.
//!
//! **What this file is.** `vulkan/StreamImplVk.cpp` upstream. It declares one `Write` specialisation
//! per Vulkan struct and every one of them writes a field list through one
//! sink. Here the field list is a comptime value and the writer is one generic,
//! so the 31 `vulkan.zig` types below are 31 instantiations of one function
//! and a new type costs a list, not a body.
//!
//! **What this file is not.** It is not a sink. `pipeline.CacheKey`
//! (`src/pipeline/cache_key.zig`) is the byte sink and M14 owns it; this file
//! only decides what order the bytes go in. Dawn's `Sink::GetSpace`
//! (`src/dawn/native/stream/Sink.h`) existed to hand a span to the templated
//! writer, and a sink that appends does not need it.
//!
//! **What it does not claim.** It does not claim byte compatibility with a Dawn
//! pipeline-cache file. Every scalar is one 64-bit word here and a Dawn
//! `size_t` or `uint32_t` upstream, so the two encodings differ from the first
//! byte; there is no Dawn cache file the port has to read. What is kept is the
//! *order*, because the order is the contract that makes two equal pipelines
//! serialise to equal bytes.

const std = @import("std");
const vulkan = @import("vulkan");
const cache_key = @import("../pipeline/cache_key.zig");

pub const CacheKey = cache_key.CacheKey;
pub const WriteError = cache_key.CacheKey.AppendError;

/// One step of a field list, in the order upstream's `StreamIn` writes it.
///
/// Naming a field the type does not have is a compile error: a renamed Vulkan
/// member cannot compile into a key that silently omits it.
pub const Step = union(enum) {
    /// The field's own bytes: an integer, a float, a bool, an enum, or a fixed
    /// C array copied raw (`stream/Stream.h:119-133`, `:316-324`).
    value: []const u8,
    /// A struct field written through its own field list. A struct never gets
    /// the `value` rule: its layout is not one blob, so the list is named.
    nested: struct { field: []const u8, steps: []const Step },
    /// A run of a struct: the count field, then that many copies of the
    /// pointee (`stream/Stream.h:379-391`).
    run: struct { count_field: []const u8, field: []const u8, element: []const Step },
    /// A run of scalars: the count field, then that many words. Separate from
    /// `run` because `@field` on a scalar has no meaning.
    scalar_run: struct { count_field: []const u8, field: []const u8 },
    /// A run of raw bytes: the count field, then that many bytes. Used only by
    /// `VkSpecializationInfo`'s `pData`, which upstream wraps in
    /// `Span<const std::byte>`.
    bytes_run: struct { count_field: []const u8, field: []const u8 },
    /// A pointer to a struct: a non-null word, then the pointee
    /// (`stream/Stream.h:231-249`).
    reference: struct { field: []const u8, pointee: []const Step },
    /// A pointer to one scalar: a non-null word, then one word. `pSampleMask`
    /// is the case upstream (`StreamImplVk.cpp:322`).
    scalar_reference: []const u8,
    /// A C string: its length then its bytes (`stream/Stream.h:517-525`). A
    /// null pointer is a zero-length string and not a null flag, because
    /// upstream wraps it in a `std::string_view` before serialising.
    string: []const u8,
};

/// One serialiser: the writer for `T` over `steps`.
///
/// `write` is the only entry point. It allocates nothing outside the sink, so
/// the caller owns every byte that reaches the key.
///
/// The 32nd specialisation upstream is `vulkan::RenderPassCacheQuery`
/// (`StreamImplVk.cpp:384`). It is not a `vulkan.zig` type and its data is
/// sparse: upstream walks `color_mask` and writes only the set bits because
/// the arrays hold uninitialised entries elsewhere. Its writer therefore lives
/// in `render_pass_cache.zig`, next to the key it describes, and the count is
/// 31 instantiations here and 32 in the milestone.
///
/// **What the upstream `pNext` machinery becomes.** `ValidatePnextImpl` (`:45`)
/// asserts each chained `sType` appears once; `SerializePnextImpl` (`:56`, `:77`)
/// and `SerializePnext` (`:96`, `:107`) write the chain. In Zig the chain is the
/// generated optional chain of `src/api/chained.zig`, so it is a set of optional
/// fields rather than a pointer walk, and this generic already emits one
/// contiguous block per struct. There is no chain to validate and no chain to
/// write; that is why those four rows merge into `Stream(T)` and add no code.
pub fn Stream(comptime T: type, comptime steps: []const Step) type {
    return struct {
        pub fn write(
            key: *CacheKey,
            allocator: std.mem.Allocator,
            value: *const T,
        ) WriteError!void {
            try writeSteps(steps, allocator, key, value);
        }
    };
}

/// Writes one list against one value. Shared by `Stream.write`, by every nested
/// list and by every element list, so the recursion is one function rather
/// than one per instantiation.
fn writeSteps(
    comptime steps: []const Step,
    allocator: std.mem.Allocator,
    key: *CacheKey,
    value: anytype,
) WriteError!void {
    inline for (steps) |step| {
        switch (step) {
            .value => |field| try writeScalar(allocator, key, @field(value, field)),
            .string => |field| try writeString(allocator, key, @field(value, field)),
            .nested => |spec| try writeSteps(
                spec.steps,
                allocator,
                key,
                &@field(value, spec.field),
            ),
            .bytes_run => |spec| try writeBytesRun(spec, allocator, key, value),
            .run => |spec| try writeRun(spec, allocator, key, value),
            .scalar_run => |spec| try writeScalarRun(spec, allocator, key, value),
            .reference => |spec| try writeReference(spec, allocator, key, value),
            .scalar_reference => |field| try writeScalarReference(allocator, key, @field(value, field)),
        }
    }
}

const RunSpec = @FieldType(Step, "run");
const ScalarRunSpec = @FieldType(Step, "scalar_run");
const BytesRunSpec = @FieldType(Step, "bytes_run");
const ReferenceSpec = @FieldType(Step, "reference");

fn writeRun(
    comptime spec: RunSpec,
    allocator: std.mem.Allocator,
    key: *CacheKey,
    value: anytype,
) WriteError!void {
    const Element = @typeInfo(@TypeOf(@field(value, spec.field))).pointer.child;
    const items: [*c]const Element = @field(value, spec.field);
    const count: usize = @intCast(@field(value, spec.count_field));

    try writeWord(allocator, key, count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const element: *const Element = &items[index];
        try writeSteps(spec.element, allocator, key, element);
    }
}

fn writeScalarRun(
    comptime spec: ScalarRunSpec,
    allocator: std.mem.Allocator,
    key: *CacheKey,
    value: anytype,
) WriteError!void {
    const Element = @typeInfo(@TypeOf(@field(value, spec.field))).pointer.child;
    const items: [*c]const Element = @field(value, spec.field);
    const count: usize = @intCast(@field(value, spec.count_field));

    try writeWord(allocator, key, count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        try writeScalar(allocator, key, items[index]);
    }
}

fn writeBytesRun(
    comptime spec: BytesRunSpec,
    allocator: std.mem.Allocator,
    key: *CacheKey,
    value: anytype,
) WriteError!void {
    const count: usize = @intCast(@field(value, spec.count_field));
    try writeWord(allocator, key, count);

    const raw: ?*const anyopaque = @field(value, spec.field);
    if (raw == null) {
        // A null `pData` with a zero `dataSize` is the empty specialisation and
        // is the only null that upstream's span cannot describe. A null with a
        // non-zero size would be a read of nothing, so the run stops here and
        // the count the key already carries is the observable.
        std.debug.assert(count == 0);
        return;
    }
    const bytes: [*c]const u8 = @ptrCast(raw.?);
    try key.appendBytes(allocator, bytes[0..count]);
}

fn writeReference(
    comptime spec: ReferenceSpec,
    allocator: std.mem.Allocator,
    key: *CacheKey,
    value: anytype,
) WriteError!void {
    const pointee = nonNullPointee(@field(value, spec.field)) orelse return;

    try writeWord(allocator, key, 1);
    try writeSteps(spec.pointee, allocator, key, pointee);
}

/// The type a pointer field points at. A step that names a field which is not a
/// pointer reaches no return type, so the mistake is a compile error and not a
/// misread.
fn Pointee(pointer: anytype) type {
    return @typeInfo(@TypeOf(pointer)).pointer.child;
}

/// The pointee of a pointer field, or null when the field is null.
///
/// The deref sits behind the null test, because a null pointer writes the flag
/// and nothing else: taking the pointee first would already have formed the
/// reference the flag says does not exist (`stream/Stream.h:231`-`:249`).
/// `[0]` is the deref for both C pointer sizes, `[*c]T` and `*T`, so one line
/// carries the two shapes a Vulkan field can have.
fn nonNullPointee(pointer: anytype) ?*const Pointee(pointer) {
    if (pointer == null) return null;
    return &pointer[0];
}

fn writeScalarReference(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    pointer: anytype,
) WriteError!void {
    const pointee = nonNullPointee(pointer);
    // The flag is one word either way, so a null pointer writes `0` and the
    // deref behind it runs only where the flag says the reference exists.
    try writeWord(allocator, key, if (pointee == null) 0 else 1);
    const scalar = pointee orelse return;
    try writeScalar(allocator, key, scalar.*);
}

fn writeString(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    pointer: [*c]const u8,
) WriteError!void {
    const text = if (pointer == null) &[_]u8{} else std.mem.span(pointer);
    try key.appendBytes(allocator, text);
}

/// One scalar as one word. Every width collapse is deliberate and the byte
/// order is M14's (`CacheKey.appendWord`, eight little-endian bytes).
fn writeScalar(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    item: anytype,
) WriteError!void {
    switch (@typeInfo(@TypeOf(item))) {
        .int => |info| {
            if (info.bits > 64) @compileError("a key holds 64-bit scalars");
            const wide: i64 = @intCast(item);
            try writeWord(allocator, key, @bitCast(wide));
        },
        .bool => try writeWord(allocator, key, if (item) 1 else 0),
        .@"enum" => try writeWord(allocator, key, @backingInt(item)),
        .float => |info| {
            if (info.bits == 32) {
                try writeWord(allocator, key, @as(u32, @bitCast(@as(f32, item))));
            } else if (info.bits == 64) {
                try writeWord(allocator, key, @as(u64, @bitCast(@as(f64, item))));
            } else {
                @compileError("a key holds f32 and f64 only");
            }
        },
        .array => try key.appendBytes(allocator, std.mem.sliceAsBytes(&item)),
        else => @compileError("no key encoding for " ++ @typeName(@TypeOf(item))),
    }
}

fn writeWord(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    value: u64,
) WriteError!void {
    try key.appendWord(allocator, value);
}

// The 31 field lists. Each is the field order at the cited upstream line, and
// the order is the contract: a pipeline that differs only in a later field
// produces different bytes only because the list puts it later.

const descriptor_set_layout_binding_steps = [_]Step{
    .{ .value = "binding" },
    .{ .value = "descriptorType" },
    .{ .value = "descriptorCount" },
    .{ .value = "stageFlags" },
};

const descriptor_set_layout_binding_flags_steps = [_]Step{
    // Only the flags run: the count belongs to the parent struct, which writes
    // its own `bindingCount` and would otherwise write it twice.
    .{ .scalar_run = .{ .count_field = "bindingCount", .field = "pBindingFlags" } },
};

const descriptor_set_layout_steps = [_]Step{
    .{ .value = "flags" },
    .{ .run = .{
        .count_field = "bindingCount",
        .field = "pBindings",
        .element = &descriptor_set_layout_binding_steps,
    } },
};

const push_constant_range_steps = [_]Step{
    .{ .value = "stageFlags" },
    .{ .value = "offset" },
    .{ .value = "size" },
};

const pipeline_layout_steps = [_]Step{
    .{ .value = "flags" },
    .{ .run = .{
        .count_field = "pushConstantRangeCount",
        .field = "pPushConstantRanges",
        .element = &push_constant_range_steps,
    } },
};

const specialization_map_entry_steps = [_]Step{
    .{ .value = "constantID" },
    .{ .value = "offset" },
    .{ .value = "size" },
};

const specialization_info_steps = [_]Step{
    .{ .run = .{
        .count_field = "mapEntryCount",
        .field = "pMapEntries",
        .element = &specialization_map_entry_steps,
    } },
    .{ .bytes_run = .{ .count_field = "dataSize", .field = "pData" } },
};

const required_subgroup_size_steps = [_]Step{.{
    .value = "requiredSubgroupSize",
}};

const shader_stage_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "stage" },
    .{ .string = "pName" },
    .{ .reference = .{ .field = "pSpecializationInfo", .pointee = &specialization_info_steps } },
};

const compute_pipeline_steps = [_]Step{
    .{ .value = "flags" },
    .{ .nested = .{ .field = "stage", .steps = &shader_stage_steps } },
};

const vertex_input_binding_steps = [_]Step{
    .{ .value = "binding" },
    .{ .value = "stride" },
    .{ .value = "inputRate" },
};

const vertex_input_attribute_steps = [_]Step{
    .{ .value = "location" },
    .{ .value = "binding" },
    .{ .value = "format" },
    .{ .value = "offset" },
};

const pipeline_vertex_input_steps = [_]Step{
    .{ .value = "flags" },
    .{ .run = .{
        .count_field = "vertexBindingDescriptionCount",
        .field = "pVertexBindingDescriptions",
        .element = &vertex_input_binding_steps,
    } },
    .{ .run = .{
        .count_field = "vertexAttributeDescriptionCount",
        .field = "pVertexAttributeDescriptions",
        .element = &vertex_input_attribute_steps,
    } },
};

const pipeline_input_assembly_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "topology" },
    .{ .value = "primitiveRestartEnable" },
};

const pipeline_tessellation_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "patchControlPoints" },
};

const offset2d_steps = [_]Step{
    .{ .value = "x" },
    .{ .value = "y" },
};

const extent2d_steps = [_]Step{
    .{ .value = "width" },
    .{ .value = "height" },
};

const rect2d_steps = [_]Step{
    .{ .nested = .{ .field = "offset", .steps = &offset2d_steps } },
    .{ .nested = .{ .field = "extent", .steps = &extent2d_steps } },
};

const viewport_steps = [_]Step{
    .{ .value = "x" },
    .{ .value = "y" },
    .{ .value = "width" },
    .{ .value = "height" },
    .{ .value = "minDepth" },
    .{ .value = "maxDepth" },
};

const pipeline_viewport_steps = [_]Step{
    .{ .value = "flags" },
    .{ .run = .{
        .count_field = "viewportCount",
        .field = "pViewports",
        .element = &viewport_steps,
    } },
    .{ .run = .{ .count_field = "scissorCount", .field = "pScissors", .element = &rect2d_steps } },
};

const depth_clip_state_steps = [_]Step{
    // Upstream writes `depthClipEnable` then `flags` (`StreamImplVk.cpp:174`),
    // which is the reverse of the struct's own order.
    .{ .value = "depthClipEnable" },
    .{ .value = "flags" },
};

const pipeline_rasterization_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "depthClampEnable" },
    .{ .value = "rasterizerDiscardEnable" },
    .{ .value = "polygonMode" },
    .{ .value = "cullMode" },
    .{ .value = "frontFace" },
    .{ .value = "depthBiasEnable" },
    .{ .value = "depthBiasConstantFactor" },
    .{ .value = "depthBiasClamp" },
    .{ .value = "depthBiasSlopeFactor" },
    .{ .value = "lineWidth" },
};

const pipeline_multisample_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "rasterizationSamples" },
    .{ .value = "sampleShadingEnable" },
    .{ .value = "minSampleShading" },
    // A plain pointer upstream (`StreamImplVk.cpp:322`), not a span, so it is
    // the pointer rule: a non-null word then one `u32`. The render pipeline
    // always sets it, so the width is fixed.
    .{ .scalar_reference = "pSampleMask" },
    .{ .value = "alphaToCoverageEnable" },
    .{ .value = "alphaToOneEnable" },
};

const stencil_op_state_steps = [_]Step{
    .{ .value = "failOp" },
    .{ .value = "passOp" },
    .{ .value = "depthFailOp" },
    .{ .value = "compareOp" },
    .{ .value = "compareMask" },
    .{ .value = "writeMask" },
    .{ .value = "reference" },
};

const pipeline_depth_stencil_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "depthTestEnable" },
    .{ .value = "depthWriteEnable" },
    .{ .value = "depthCompareOp" },
    .{ .value = "depthBoundsTestEnable" },
    .{ .value = "stencilTestEnable" },
    .{ .nested = .{ .field = "front", .steps = &stencil_op_state_steps } },
    .{ .nested = .{ .field = "back", .steps = &stencil_op_state_steps } },
    .{ .value = "minDepthBounds" },
    .{ .value = "maxDepthBounds" },
};

const color_blend_attachment_steps = [_]Step{
    .{ .value = "blendEnable" },
    .{ .value = "srcColorBlendFactor" },
    .{ .value = "dstColorBlendFactor" },
    .{ .value = "colorBlendOp" },
    .{ .value = "srcAlphaBlendFactor" },
    .{ .value = "dstAlphaBlendFactor" },
    .{ .value = "alphaBlendOp" },
    .{ .value = "colorWriteMask" },
};

const pipeline_color_blend_steps = [_]Step{
    .{ .value = "flags" },
    .{ .value = "logicOpEnable" },
    .{ .value = "logicOp" },
    .{ .run = .{
        .count_field = "attachmentCount",
        .field = "pAttachments",
        .element = &color_blend_attachment_steps,
    } },
    .{ .value = "blendConstants" },
};

const pipeline_dynamic_state_steps = [_]Step{
    .{ .value = "flags" },
    .{ .scalar_run = .{ .count_field = "dynamicStateCount", .field = "pDynamicStates" } },
};

const pipeline_robustness_steps = [_]Step{
    .{ .value = "vertexInputs" },
    .{ .value = "images" },
    .{ .value = "storageBuffers" },
    .{ .value = "uniformBuffers" },
};

const pipeline_rendering_steps = [_]Step{
    .{ .value = "viewMask" },
    .{ .scalar_run = .{
        .count_field = "colorAttachmentCount",
        .field = "pColorAttachmentFormats",
    } },
    .{ .value = "depthAttachmentFormat" },
    .{ .value = "stencilAttachmentFormat" },
};

const graphics_pipeline_steps = [_]Step{
    .{ .value = "flags" },
    .{ .run = .{ .count_field = "stageCount", .field = "pStages", .element = &shader_stage_steps } },
    .{ .reference = .{ .field = "pVertexInputState", .pointee = &pipeline_vertex_input_steps } },
    .{ .reference = .{ .field = "pInputAssemblyState", .pointee = &pipeline_input_assembly_steps } },
    .{ .reference = .{ .field = "pTessellationState", .pointee = &pipeline_tessellation_steps } },
    .{ .reference = .{ .field = "pViewportState", .pointee = &pipeline_viewport_steps } },
    .{ .reference = .{ .field = "pRasterizationState", .pointee = &pipeline_rasterization_steps } },
    .{ .reference = .{ .field = "pMultisampleState", .pointee = &pipeline_multisample_steps } },
    .{ .reference = .{ .field = "pDepthStencilState", .pointee = &pipeline_depth_stencil_steps } },
    .{ .reference = .{ .field = "pColorBlendState", .pointee = &pipeline_color_blend_steps } },
    .{ .reference = .{ .field = "pDynamicState", .pointee = &pipeline_dynamic_state_steps } },
    .{ .value = "subpass" },
};

/// The 31 instantiations. Each name is the upstream `Stream<T>` in snake_case,
/// and the `vulkan.` reference beside it keeps the C spelling the Vulkan
/// headers use. Three names spell the extension suffix the house way, `_ext`
/// and `_khr`, where the header spells it `EXT` and `KHR`.
pub const descriptor_set_layout_binding =
    Stream(vulkan.VkDescriptorSetLayoutBinding, &descriptor_set_layout_binding_steps);
pub const descriptor_set_layout_binding_flags_create_info =
    Stream(vulkan.VkDescriptorSetLayoutBindingFlagsCreateInfo, &descriptor_set_layout_binding_flags_steps);
pub const descriptor_set_layout_create_info =
    Stream(vulkan.VkDescriptorSetLayoutCreateInfo, &descriptor_set_layout_steps);
pub const push_constant_range =
    Stream(vulkan.VkPushConstantRange, &push_constant_range_steps);
pub const pipeline_layout_create_info =
    Stream(vulkan.VkPipelineLayoutCreateInfo, &pipeline_layout_steps);
pub const pipeline_shader_stage_required_subgroup_size_create_info_ext =
    Stream(vulkan.VkPipelineShaderStageRequiredSubgroupSizeCreateInfoEXT, &required_subgroup_size_steps);
pub const pipeline_rasterization_depth_clip_state_create_info_ext =
    Stream(vulkan.VkPipelineRasterizationDepthClipStateCreateInfoEXT, &depth_clip_state_steps);
pub const specialization_map_entry =
    Stream(vulkan.VkSpecializationMapEntry, &specialization_map_entry_steps);
pub const specialization_info =
    Stream(vulkan.VkSpecializationInfo, &specialization_info_steps);
pub const pipeline_shader_stage_create_info =
    Stream(vulkan.VkPipelineShaderStageCreateInfo, &shader_stage_steps);
pub const compute_pipeline_create_info =
    Stream(vulkan.VkComputePipelineCreateInfo, &compute_pipeline_steps);
pub const vertex_input_binding_description =
    Stream(vulkan.VkVertexInputBindingDescription, &vertex_input_binding_steps);
pub const vertex_input_attribute_description =
    Stream(vulkan.VkVertexInputAttributeDescription, &vertex_input_attribute_steps);
pub const pipeline_vertex_input_state_create_info =
    Stream(vulkan.VkPipelineVertexInputStateCreateInfo, &pipeline_vertex_input_steps);
pub const pipeline_input_assembly_state_create_info =
    Stream(vulkan.VkPipelineInputAssemblyStateCreateInfo, &pipeline_input_assembly_steps);
pub const pipeline_tessellation_state_create_info =
    Stream(vulkan.VkPipelineTessellationStateCreateInfo, &pipeline_tessellation_steps);
pub const viewport = Stream(vulkan.VkViewport, &viewport_steps);
pub const offset2d = Stream(vulkan.VkOffset2D, &offset2d_steps);
pub const extent2d = Stream(vulkan.VkExtent2D, &extent2d_steps);
pub const rect2d = Stream(vulkan.VkRect2D, &rect2d_steps);
pub const pipeline_viewport_state_create_info =
    Stream(vulkan.VkPipelineViewportStateCreateInfo, &pipeline_viewport_steps);
pub const pipeline_rasterization_state_create_info =
    Stream(vulkan.VkPipelineRasterizationStateCreateInfo, &pipeline_rasterization_steps);
pub const pipeline_multisample_state_create_info =
    Stream(vulkan.VkPipelineMultisampleStateCreateInfo, &pipeline_multisample_steps);
pub const stencil_op_state = Stream(vulkan.VkStencilOpState, &stencil_op_state_steps);
pub const pipeline_depth_stencil_state_create_info =
    Stream(vulkan.VkPipelineDepthStencilStateCreateInfo, &pipeline_depth_stencil_steps);
pub const pipeline_color_blend_attachment_state =
    Stream(vulkan.VkPipelineColorBlendAttachmentState, &color_blend_attachment_steps);
pub const pipeline_color_blend_state_create_info =
    Stream(vulkan.VkPipelineColorBlendStateCreateInfo, &pipeline_color_blend_steps);
pub const pipeline_dynamic_state_create_info =
    Stream(vulkan.VkPipelineDynamicStateCreateInfo, &pipeline_dynamic_state_steps);
pub const pipeline_robustness_create_info =
    Stream(vulkan.VkPipelineRobustnessCreateInfo, &pipeline_robustness_steps);
pub const graphics_pipeline_create_info =
    Stream(vulkan.VkGraphicsPipelineCreateInfo, &graphics_pipeline_steps);
pub const pipeline_rendering_create_info_khr =
    Stream(vulkan.VkPipelineRenderingCreateInfoKHR, &pipeline_rendering_steps);
