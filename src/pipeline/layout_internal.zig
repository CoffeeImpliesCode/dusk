//! The packed bind group layout: one dense, sorted vector read through two
//! index spaces.
//!
//! **What this file is.** The port of `native/BindGroupLayoutInternal.{h,cpp}`
//! at Dawn `32f77c02294310054a660c393feded4bcb3f203c`. It validates one descriptor,
//! expands the entries Dawn expands, sorts what is left into one dense vector
//! and turns each kind into a range of that vector.
//!
//! **Two index spaces, and why they differ.** `ApiBindingIndex` addresses a
//! user-facing entry. `BindingIndex` addresses the whole vector, including the
//! private entries an external texture grows into
//! (`BindGroupLayoutInternal.h:100`-`:104`). The entry count is therefore two
//! numbers: `Layout.queryBindingCount()` bounds the vector, and
//! `Layout.api_binding_map` resolves stored public and private binding numbers.
//!
//! **What this file does not claim.** It does not claim Dawn's content-hash
//! dedup cache (`BindGroupLayoutInternal.cpp:835`, `:884`): M14 owns the cache,
//! and this file only computes the hash and the equality it keys on. It claims
//! no back end; `layout_vk.zig` is the Vulkan one.

const std = @import("std");
const errors = @import("../core/errors.zig");

/// `kMaxBindGroups` (`src/dawn/common/Constants.h:36`).
pub const max_bind_groups: u32 = 4;

/// The public binding namespace. External texture roles use a disjoint fixed block.
pub const max_bindings_per_bind_group: u32 = 1000;

const external_binding_role_count: u32 = 4;
const first_external_binding_number: u32 = max_bindings_per_bind_group;
const external_binding_number_end: u32 =
    first_external_binding_number + external_binding_role_count * max_bindings_per_bind_group;

comptime {
    std.debug.assert(max_bindings_per_bind_group > 0);
    std.debug.assert(external_binding_role_count == 4);
    std.debug.assert(first_external_binding_number == max_bindings_per_bind_group);
    std.debug.assert(first_external_binding_number < external_binding_number_end);
    std.debug.assert(external_binding_number_end == 5 * max_bindings_per_bind_group);
    std.debug.assert(external_binding_number_end <= std.math.maxInt(u32));
}

pub const ExternalBindingNumberOptions = struct {
    binding_number: u32,
    needs_static_sampler: bool = false,
};

pub const ExternalBindingNumbers = struct {
    plane0: u32,
    plane1: u32,
    metadata: u32,
    static_sampler: ?u32,
};

/// Allocates no state. Every public external slot has one permanent private role block.
pub fn externalBindingNumbers(
    options: ExternalBindingNumberOptions,
) error{BindingNumberAboveLimit}!ExternalBindingNumbers {
    if (options.binding_number >= max_bindings_per_bind_group) {
        return error.BindingNumberAboveLimit;
    }
    const base = first_external_binding_number +
        external_binding_role_count * options.binding_number;
    return .{
        .plane0 = base,
        .plane1 = base + 1,
        .metadata = base + 2,
        .static_sampler = if (options.needs_static_sampler) base + 3 else null,
    };
}

/// `kMaxDynamicStorageBuffersPerPipelineLayout` (`Constants.h:114`). Dawn caps
/// the per-layout dynamic storage buffer limit at it
/// (`Limits.cpp:390`-`:397`), and `BindingInfo.cpp:198`-`:199` refuses a
/// pipeline layout above the capped limit.
pub const max_dynamic_storage_buffers_per_pipeline_layout: u32 = 16;

/// Every rule this file can report. The `errors.ValidationError` members carry
/// the rules other modules own; the rest name a `DAWN_INVALID_IF` site.
pub const Error = errors.ValidationError || std.mem.Allocator.Error || error{
    /// An entry no stage can see. Dawn refuses it in `ValidateShaderStage`,
    /// which `ValidateBindGroupLayoutEntry` calls at
    /// `BindGroupLayoutInternal.cpp:108`.
    BindingVisibilityEmpty,

    /// A binding number at or above `max_bindings_per_bind_group`.
    BindingNumberAboveLimit,

    /// Two entries claim one binding number. Dawn refuses it in
    /// `ValidateBindGroupLayoutDescriptor`.
    DuplicateBindingNumber,

    /// An entry named more than one binding kind. Dawn counts the members it
    /// found and refuses a total other than one
    /// (`BindGroupLayoutInternal.cpp:114`, `:284`).
    MultipleBindingKindsInEntry,

    /// An entry named no binding kind at all. The same counter.
    NoBindingKindInEntry,

    /// `binding_array_size` above one for a kind Dawn does not expand.
    /// `BindGroupLayoutInternal.cpp:137`, `:147` and the sibling sites.
    BindingArraySizeNotOne,

    /// A read-write storage buffer visible to the vertex stage, which the
    /// vertex stage cannot order. `BindGroupLayoutInternal.cpp:129`-`:133`.
    StorageBufferInVertexStage,

    /// A multisampled sampled texture that is not 2D, or is filterable float.
    /// `BindGroupLayoutInternal.cpp:185`-`:191`.
    MultisampledTextureBindingUnsupported,

    /// A storage texture bound through a cube view.
    /// `BindGroupLayoutInternal.cpp:86`-`:103`.
    StorageTextureViewDimensionUnsupported,

    /// A static sampler naming a texture entry that does not exist, names
    /// itself, or names an entry that is not a texture.
    /// `ValidateStaticSamplersWithTextureBindings`
    /// (`BindGroupLayoutInternal.cpp:295`).
    StaticSamplerTextureBindingInvalid,

    /// More storage buffers than `maxStorageBuffersInVertexStage`
    /// (`BindingInfo.cpp:316`).
    StorageBuffersPerShaderStageInVertexStage,

    /// More storage buffers than `maxStorageBuffersInFragmentStage`
    /// (`BindingInfo.cpp:300`).
    StorageBuffersPerShaderStageInFragmentStage,
    InternalBindingNotAllowed,
    InvalidStaticSamplerBinding,
};

/// One stage named as a tag rather than as a bit. `ShaderStages` below is a
/// packed struct, so `std.meta.Tag` has no union or enum to read, and this is
/// what names a stage where the index is what the caller wants.
pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
};

/// The stages a binding is visible from. Dawn counts three at `Constants.h:42`
/// and packs them into `wgpu::ShaderStageFlags`.
pub const ShaderStages = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,

    _reserved: u29 = 0,

    /// The three stages, in the order the counters above are laid out. The
    /// count is a named constant because every loop over a per-stage counter
    /// has to state its own bound.
    pub const stage_count: usize = 3;

    pub fn bits(self: ShaderStages) u32 {
        return @bitCast(self);
    }

    pub fn contains(self: ShaderStages, other: ShaderStages) bool {
        return self.bits() & other.bits() == other.bits();
    }

    pub fn isEmpty(self: ShaderStages) bool {
        return self.bits() == 0;
    }

    /// Whether the stage at `stage_index` is visible. `bitIsSet` left packed
    /// structs in Zig 0.16, and the packed field order above is the bit order,
    /// so the predicate reads the bit itself.
    pub fn hasStage(self: ShaderStages, comptime stage_index: usize) bool {
        return self.bits() & (@as(u32, 1) << @intCast(stage_index)) != 0;
    }
};

/// The index of one stage inside a per-stage counter, which is the packed
/// field order of `ShaderStages`, computed by an exhaustive switch.
pub fn stageIndex(stage: ShaderStage) usize {
    return switch (stage) {
        .vertex => 0,
        .fragment => 1,
        .compute => 2,
    };
}

/// The order entries are stored in, which is also the order their ranges are
/// laid out in. `BindingTypeOrder` (`BindGroupLayoutInternal.h:63`-`:80`).
///
/// The value is the index space of `Layout.type_start`, so a new kind is a
/// compile error until it is placed where Dawn places it.
pub const BindingTypeOrder = enum(u32) {
    dynamic_buffer,
    regular_buffer,
    sampled_texture,
    storage_texture,
    input_attachment,
    static_sampler,
    regular_sampler,
    texel_buffer,
    external_texture,
    count,

    /// One past the last order, which is the length of `Layout.type_start`.
    pub const range_count = @typeInfo(BindingTypeOrder).@"enum".field_names.len;
};

/// Public and private buffer permissions remain distinct canonical kinds.
pub const BufferBindingType = enum {
    uniform,
    storage,
    read_only_storage,
    internal_storage,
    internal_read_only_storage,
};

/// `wgpu::SamplerBindingType`.
pub const SamplerBindingType = enum {
    filtering,
    non_filtering,
    comparison,
};

/// `wgpu::TextureSampleType`, minus the internal resolve-attachment sample
/// type at `BindGroupLayoutInternal.cpp:155`.
pub const TextureSampleType = enum {
    float_filterable,
    float_unfilterable,
    sint,
    uint,
    depth,
};

/// `wgpu::TextureViewDimension`.
pub const TextureViewDimension = enum {
    one_d,
    two_d,
    two_d_array,
    cube,
    cube_array,
    three_d,
};

/// `wgpu::StorageTextureAccess`.
pub const StorageTextureAccess = enum {
    write_only,
    read_only,
    read_write,
};

/// `wgpu::TexelBufferAccess`.
pub const TexelBufferAccess = enum {
    read_only,
    read_write,
};

/// `StaticSamplerUse`. `freestanding` becomes `VK_DESCRIPTOR_TYPE_SAMPLER` and
/// the other two become `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`
/// (`vulkan/BindGroupLayoutVk.cpp:183`-`:189`).
pub const StaticSamplerUse = enum {
    freestanding,
    paired_with_texture,
    single_texture_ycbcr,
};

pub const BufferBinding = struct {
    binding_type: BufferBindingType,
    /// `BufferBindingInfo::hasDynamicOffset`. Dawn gives a dynamic buffer its
    /// own order (`BindGroupLayoutInternal.cpp:492`), and Vulkan reads the flag
    /// as the `_DYNAMIC` descriptor type
    /// (`vulkan/BindGroupLayoutVk.cpp:163`-`:174`).
    has_dynamic_offset: bool,
    min_binding_size: u64,
};

pub const SamplerBinding = struct {
    binding_type: SamplerBindingType,
};

pub const StaticSamplerBinding = struct {
    use: StaticSamplerUse,
    /// The binding number of the sampled texture this sampler pairs with, or
    /// null for a freestanding one. Dawn rewrites the field into an index
    /// after the sort (`BindGroupLayoutInternal.cpp:643`-`:647`).
    sampled_texture_binding: ?u32,
    /// The actual retained sampler header address, never a native handle.
    sampler_identity: usize = 0,
    combined_image_sampler_descriptor_count: u32 = 1,
};

pub const SampledTextureBinding = struct {
    sample_type: TextureSampleType,
    view_dimension: TextureViewDimension,
    multisampled: bool,
    internal: bool = false,
    /// Private float-image ABI for a view whose actual format is depth.
    depth_view: bool = false,
};

pub const StorageTextureBinding = struct {
    access: StorageTextureAccess,
    view_dimension: TextureViewDimension,
    internal: bool = false,
};

pub const TexelBufferBinding = struct {
    access: TexelBufferAccess,
};

pub const InputAttachmentBinding = struct {
    sample_type: TextureSampleType,
};

/// The private entries one external texture grows into
/// (`BindGroupLayoutInternal.cpp:538`-`:543`). The fields are indices into the
/// sorted vector, filled after the sort at `:628`-`:640`.
pub const ExternalTextureBinding = struct {
    plane0: BindingIndex,
    plane1: BindingIndex,
    metadata: BindingIndex,
    static_sampler: ?BindingIndex,
};

/// The kinds one entry can name. The tag is its own type rather than an
/// anonymous `enum`, so the comptime sweep over the domain below has a name to
/// sweep.
pub const EntryKindTag = enum {
    buffer,
    sampler,
    static_sampler,
    sampled_texture,
    storage_texture,
    texel_buffer,
    input_attachment,
    external_texture,
};

/// What a caller writes on one entry. `BindGroupLayoutEntry`, with Dawn's chain
/// of optional members turned into one tagged union of optional members, so a
/// caller can still name two kinds and be refused.
///
/// No field carries a default. Zig reads a `= ...` on a tagged-union field as a
/// tag value and not as a payload default, and only an inferred `enum(uN)` tag
/// takes one; a named tag type refuses it outright. An optional payload already
/// reads as null and a `bool` as false, so the defaults are the ones the field
/// types already give, and `Entry.kind` names its first tag instead of asking
/// for `.{}`.
pub const EntryKind = union(EntryKindTag) {
    buffer: ?BufferBinding,
    sampler: ?SamplerBinding,
    static_sampler: ?StaticSamplerBinding,
    sampled_texture: ?SampledTextureBinding,
    storage_texture: ?StorageTextureBinding,
    texel_buffer: ?TexelBufferBinding,
    input_attachment: ?InputAttachmentBinding,
    external_texture: bool,
};

/// One entry as a caller writes it. Dawn generates `BindGroupLayoutEntry` from
/// `webgpu.json`, so the pinned tree names the type but declares it nowhere;
/// `ValidateBindGroupLayoutEntry` takes one at
/// `BindGroupLayoutInternal.cpp:105`-`:106`.
pub const Entry = struct {
    binding_number: u32,
    visibility: ShaderStages,
    /// Dawn clamps zero to one at `BindGroupLayoutInternal.cpp:110`.
    array_size: u32 = 1,
    /// A union initializer names one field, so an entry that names no kind
    /// says `.buffer` and not `.{}`.
    kind: EntryKind = .{ .buffer = null },
};

/// What a caller writes. `BindGroupLayoutDescriptor`, validated by
/// `ValidateBindGroupLayoutDescriptor` (`BindGroupLayoutInternal.cpp:338`).
pub const Descriptor = struct {
    entries: []const Entry,
    label: []const u8 = "",
};

/// One stored binding. `BindingInfo` (`BindingInfo.h`), with Dawn's `arraySize`
/// and `indexInArray` kept because the expansion writes them.
pub const Binding = struct {
    binding_number: u32,
    visibility: ShaderStages,
    array_size: u32,
    index_in_array: u32,
    layout: BindingLayout,

    /// Private expansion roles stay outside the public binding namespace.
    pub fn isUserFacing(self: Binding) bool {
        return self.binding_number < max_bindings_per_bind_group;
    }
};

/// Dawn's `BindingInfo::bindingLayout`
/// (`BindGroupLayoutInternal.cpp:447`-`:479`). The union is the closed domain,
/// so a new kind is a compile error until every switch over it names it.
pub const BindingLayout = union(enum) {
    buffer: BufferBinding,
    sampler: SamplerBinding,
    static_sampler: StaticSamplerBinding,
    sampled_texture: SampledTextureBinding,
    storage_texture: StorageTextureBinding,
    texel_buffer: TexelBufferBinding,
    input_attachment: InputAttachmentBinding,
    external_texture: ExternalTextureBinding,

    /// The order this binding is stored in. The lambda at
    /// `BindGroupLayoutInternal.cpp:488`-`:502`, which is the sort key.
    pub fn typeOrder(self: BindingLayout) BindingTypeOrder {
        return switch (self) {
            .buffer => |buffer| if (buffer.has_dynamic_offset)
                .dynamic_buffer
            else
                .regular_buffer,
            .sampled_texture => .sampled_texture,
            .storage_texture => .storage_texture,
            .sampler => .regular_sampler,
            .static_sampler => .static_sampler,
            .texel_buffer => .texel_buffer,
            .input_attachment => .input_attachment,
            .external_texture => .external_texture,
        };
    }
};

/// An index into the whole sorted vector, private entries included.
pub const BindingIndex = enum(u32) {
    _,

    pub fn toInt(self: BindingIndex) u32 {
        return @backingInt(self);
    }

    pub fn fromInt(value: u32) BindingIndex {
        return @fromBackingInt(@intCast(value));
    }
};

/// An index into the user-facing entries alone. `APIBindingIndex`
/// (`BindGroupLayoutInternal.h:100`-`:102`).
pub const ApiBindingIndex = enum(u32) {
    _,

    pub fn toInt(self: ApiBindingIndex) u32 {
        return @backingInt(self);
    }

    pub fn fromInt(value: u32) ApiBindingIndex {
        return @fromBackingInt(@intCast(value));
    }
};

/// The numbers `ValidateBindingCounts` (`BindingInfo.cpp:174`) walks: one
/// counter per stage and per kind.
pub const BindingCounts = struct {
    uniform_buffers_per_stage: [ShaderStages.stage_count]u32 = @splat(0),
    storage_buffers_per_stage: [ShaderStages.stage_count]u32 = @splat(0),
    sampled_textures_per_stage: [ShaderStages.stage_count]u32 = @splat(0),
    storage_textures_per_stage: [ShaderStages.stage_count]u32 = @splat(0),
    samplers_per_stage: [ShaderStages.stage_count]u32 = @splat(0),
    texel_buffers_per_stage: [ShaderStages.stage_count]u32 = @splat(0),
    input_attachments_per_stage: [ShaderStages.stage_count]u32 = @splat(0),

    /// Adds one entry's counts. `IncrementBindingCounts` (`BindingInfo.h:264`),
    /// which the pipeline layout also calls at `PipelineLayout.cpp:101`.
    pub fn add(self: *BindingCounts, binding: Binding) void {
        // Bound: the three stages Dawn counts at `Constants.h:42`. An
        // `inline for` body cannot `continue` on a runtime condition, so the
        // stage test is the body and the count is inside it, not a skip past
        // it.
        inline for (0..ShaderStages.stage_count) |stage_index| {
            if (binding.visibility.hasStage(stage_index)) {
                switch (binding.layout) {
                    .buffer => |buffer| switch (buffer.binding_type) {
                        .uniform => self.uniform_buffers_per_stage[stage_index] += 1,
                        .storage, .read_only_storage, .internal_storage, .internal_read_only_storage => {
                            self.storage_buffers_per_stage[stage_index] += 1;
                        },
                    },
                    .sampled_texture => self.sampled_textures_per_stage[stage_index] += 1,
                    .storage_texture => self.storage_textures_per_stage[stage_index] += 1,
                    .sampler => self.samplers_per_stage[stage_index] += 1,
                    .static_sampler => |sampler| {
                        const count = sampler.combined_image_sampler_descriptor_count;
                        self.samplers_per_stage[stage_index] += count;
                        if (sampler.use == .single_texture_ycbcr) {
                            self.sampled_textures_per_stage[stage_index] += count;
                        }
                    },
                    .texel_buffer => self.texel_buffers_per_stage[stage_index] += 1,
                    .input_attachment => self.input_attachments_per_stage[stage_index] += 1,
                    // One external texture is two sampled textures and one
                    // uniform buffer (`BindGroupLayoutInternal.cpp:561`-`:574`).
                    .external_texture => {
                        self.sampled_textures_per_stage[stage_index] += 2;
                        self.uniform_buffers_per_stage[stage_index] += 1;
                    },
                }
            }
        }
    }
};

/// What the device decides about the two storage-buffer limits. Dawn reads them
/// off `CombinedLimits::compat` (`Limits.cpp:95`-`:96`); the port takes them as
/// a parameter so a caller with no device can still reach the rules.
pub const ValidateOptions = struct {
    max_storage_buffers_in_vertex_stage: u32,
    max_storage_buffers_in_fragment_stage: u32,

    /// Dawn adds the static sampler for an external texture only when the
    /// device says the placeholder sampler will not do
    /// (`BindGroupLayoutInternal.cpp:579`).
    needs_static_sampler_for_external_texture: bool = false,
    allow_internal_bindings: bool = false,
};

/// The packed layout. `BindGroupLayoutInternalBase`
/// (`BindGroupLayoutInternal.h:109`), with the arena the device owns upstream
/// replaced by the caller's allocator.
pub const Layout = struct {
    /// The sorted vector. Index it with `BindingIndex`, never with a binding
    /// number.
    entries: []Binding,
    /// The start of each order's range, and one past the last. The prefix sum
    /// Dawn builds at `BindGroupLayoutInternal.cpp:751`-`:756`, so the range of
    /// one order is `[type_start[order], type_start[order + 1])`.
    type_start: [BindingTypeOrder.range_count]u32,
    /// Resolves every stored public and private binding number to its packed index.
    api_binding_map: std.AutoHashMapUnmanaged(u32, BindingIndex),
    /// The counts `ValidatePipelineLayoutDescriptor` reads at
    /// `PipelineLayout.cpp:127`-`:128`. Computed from the descriptor, not from
    /// the expansion, for the reason in the comment at
    /// `BindGroupLayoutInternal.cpp:758`-`:759`.
    validation_counts: BindingCounts,
    /// Buffers whose minimum size is zero, which a bind group cannot check a
    /// size against (`BindGroupLayoutInternal.cpp:706`-`:708`).
    unverified_buffer_count: u32,
    /// `mDynamicStorageBufferCount`, counted over the expanded entries at
    /// `BindGroupLayoutInternal.cpp:716`. The pipeline layout refuses the
    /// descriptor count at `BindingInfo.cpp:198`-`:199`.
    dynamic_storage_buffer_count: u32,
    label: []const u8,
    /// `ComputeContentHash` (`BindGroupLayoutInternal.cpp:835`), which keys the
    /// dedup cache M14 owns.
    content_hash: u64,

    /// Validates, expands, sorts and packs one descriptor.
    ///
    /// Ports `BindGroupLayoutInternalBase::BindGroupLayoutInternalBase`
    /// (`:689`-`:764`) with `ConvertAndExpandBGLEntries` (`:524`-`:665`) in
    /// front of it.
    pub fn init(
        allocator: std.mem.Allocator,
        descriptor: Descriptor,
        options: ValidateOptions,
    ) Error!Layout {
        try validateDescriptor(allocator, descriptor, options);

        var expanded = std.ArrayList(Binding).empty;
        defer expanded.deinit(allocator);

        var expansions = std.ArrayList(ExternalExpansion).empty;
        defer expansions.deinit(allocator);
        var sampler_links = std.ArrayList(SamplerLink).empty;
        defer sampler_links.deinit(allocator);

        const max_entry_count = descriptor.entries.len;
        var entry_index: usize = 0;
        while (entry_index < max_entry_count) : (entry_index += 1) {
            const entry = descriptor.entries[entry_index];
            var entry_binding = try convertToBinding(entry);

            if (entry_binding.layout == .external_texture) {
                const roles = try externalBindingNumbers(.{
                    .binding_number = entry.binding_number,
                    .needs_static_sampler = options.needs_static_sampler_for_external_texture,
                });
                const plane0_number = roles.plane0;
                const plane1_number = roles.plane1;
                const metadata_number = roles.metadata;

                // Dawn pushes the private entries before the external texture
                // itself (`BindGroupLayoutInternal.cpp:561`-`:596`), and the
                // sort puts them back into type order afterwards.
                try expanded.append(allocator, .{
                    .binding_number = plane0_number,
                    .visibility = entry_binding.visibility,
                    .array_size = 1,
                    .index_in_array = 0,
                    .layout = .{ .sampled_texture = .{
                        .sample_type = .float_filterable,
                        .view_dimension = .two_d,
                        .multisampled = false,
                    } },
                });
                try expanded.append(allocator, .{
                    .binding_number = plane1_number,
                    .visibility = entry_binding.visibility,
                    .array_size = 1,
                    .index_in_array = 0,
                    .layout = .{ .sampled_texture = .{
                        .sample_type = .float_filterable,
                        .view_dimension = .two_d,
                        .multisampled = false,
                    } },
                });
                try expanded.append(allocator, .{
                    .binding_number = metadata_number,
                    .visibility = entry_binding.visibility,
                    .array_size = 1,
                    .index_in_array = 0,
                    .layout = .{ .buffer = .{
                        .binding_type = .uniform,
                        .has_dynamic_offset = false,
                        .min_binding_size = 0,
                    } },
                });

                const static_sampler_number = roles.static_sampler;
                if (static_sampler_number != null) {
                    try expanded.append(allocator, .{
                        .binding_number = static_sampler_number.?,
                        .visibility = entry_binding.visibility,
                        .array_size = 1,
                        .index_in_array = 0,
                        .layout = .{ .static_sampler = .{
                            .use = .paired_with_texture,
                            .sampled_texture_binding = plane0_number,
                        } },
                    });
                    try sampler_links.append(allocator, .{
                        .sampler_binding = static_sampler_number.?,
                        .texture_binding = plane0_number,
                    });
                }

                try expansions.append(allocator, .{
                    .external_texture_binding = entry_binding.binding_number,
                    .plane0 = plane0_number,
                    .plane1 = plane1_number,
                    .metadata = metadata_number,
                    .static_sampler = static_sampler_number,
                });
            }

            if (entry_binding.layout == .static_sampler) {
                if (entry_binding.layout.static_sampler.sampled_texture_binding) |texture_number| {
                    try sampler_links.append(allocator, .{
                        .sampler_binding = entry_binding.binding_number,
                        .texture_binding = texture_number,
                    });
                }
            }

            // One stored entry per array element, each taking the next
            // consecutive binding number (`BindGroupLayoutInternal.cpp:611`-`:615`).
            var element_index: u32 = 0;
            while (element_index < entry_binding.array_size) : (element_index += 1) {
                entry_binding.index_in_array = element_index;
                entry_binding.binding_number += element_index;
                try expanded.append(allocator, entry_binding);
                entry_binding.binding_number -= element_index;
            }
        }

        // Dawn sorts with `std::sort` at `BindGroupLayoutInternal.cpp:619`. The
        // port uses an insertion sort, which `src/platform/serial.zig` uses for
        // the same reason: the vector holds at most `max_bindings_per_bind_group`
        // user entries, and a merge sort would allocate.
        std.sort.insertion(Binding, expanded.items, NoSortContext{}, lessBindingFirst);

        var binding_map = std.AutoHashMapUnmanaged(u32, BindingIndex).empty;
        errdefer binding_map.deinit(allocator);

        const stored_count: u32 = @intCast(expanded.items.len);
        var stored_index: u32 = 0;
        while (stored_index < stored_count) : (stored_index += 1) {
            const stored = expanded.items[stored_index];
            const result = try binding_map.getOrPut(allocator, stored.binding_number);
            if (result.found_existing) return error.DuplicateBindingNumber;
            result.value_ptr.* = .fromInt(stored_index);
        }

        // Dawn points each external texture at its private entries after the
        // sort (`BindGroupLayoutInternal.cpp:628`-`:640`), because only the
        // sorted positions are known then.
        const expansion_count = expansions.items.len;
        var expansion_index: usize = 0;
        while (expansion_index < expansion_count) : (expansion_index += 1) {
            const expansion = expansions.items[expansion_index];
            const target = lookupIndex(&binding_map, expansion.external_texture_binding);
            expanded.items[target.toInt()].layout = .{ .external_texture = .{
                .plane0 = lookupIndex(&binding_map, expansion.plane0),
                .plane1 = lookupIndex(&binding_map, expansion.plane1),
                .metadata = lookupIndex(&binding_map, expansion.metadata),
                .static_sampler = if (expansion.static_sampler) |number|
                    lookupIndex(&binding_map, number)
                else
                    null,
            } };
        }

        const link_count = sampler_links.items.len;
        var link_index: usize = 0;
        while (link_index < link_count) : (link_index += 1) {
            const link = sampler_links.items[link_index];
            const sampler = lookupIndex(&binding_map, link.sampler_binding);
            expanded.items[sampler.toInt()].layout.static_sampler.sampled_texture_binding =
                link.texture_binding;
        }

        var counts: [BindingTypeOrder.range_count]u32 = @splat(0);
        var unverified_buffer_count: u32 = 0;
        var dynamic_storage_buffer_count: u32 = 0;
        var walk_index: u32 = 0;
        while (walk_index < stored_count) : (walk_index += 1) {
            const expanded_binding = expanded.items[walk_index];
            counts[@backingInt(expanded_binding.layout.typeOrder())] += 1;
            switch (expanded_binding.layout) {
                .buffer => |buffer| {
                    if (buffer.min_binding_size == 0) unverified_buffer_count += 1;
                    if (buffer.has_dynamic_offset and buffer.binding_type != .uniform) {
                        dynamic_storage_buffer_count += 1;
                    }
                },
                else => {},
            }
        }

        var type_start: [BindingTypeOrder.range_count]u32 = @splat(0);
        var sum: u32 = 0;
        inline for (0..BindingTypeOrder.range_count) |order_index| {
            type_start[order_index] = sum;
            sum += counts[order_index];
        }
        // The prefix sum covers the whole vector, so its last value is the
        // stored count. A kind added to the order without a range fails here.
        std.debug.assert(sum == stored_count);

        var validation_counts: BindingCounts = .{};
        for (descriptor.entries) |entry| {
            validation_counts.add(try convertToBinding(entry));
        }

        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&stored_count));
        for (expanded.items) |expanded_binding| {
            hash.update(std.mem.asBytes(&expanded_binding.binding_number));
            hash.update(std.mem.asBytes(&expanded_binding.index_in_array));
            hash.update(std.mem.asBytes(&expanded_binding.visibility.bits()));
            hash.update(std.mem.asBytes(&@backingInt(expanded_binding.layout.typeOrder())));
            hashBindingLayout(&hash, expanded_binding.layout);
        }

        return .{
            .entries = try expanded.toOwnedSlice(allocator),
            .type_start = type_start,
            .api_binding_map = binding_map,
            .validation_counts = validation_counts,
            .unverified_buffer_count = unverified_buffer_count,
            .dynamic_storage_buffer_count = dynamic_storage_buffer_count,
            .label = descriptor.label,
            .content_hash = hash.final(),
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        self.api_binding_map.deinit(allocator);
        // `toOwnedSlice` hands back a static empty slice for a list that never
        // grew, and a static slice is not the allocator's to free.
        if (self.entries.len != 0) {
            allocator.free(self.entries);
        }
        self.* = undefined;
    }

    /// The whole vector, private entries included. `GetBindingDataSize`
    /// (`BindGroupLayoutInternal.cpp:1016`) sizes the allocation from it.
    pub fn queryBindingCount(self: *const Layout) u32 {
        return @intCast(self.entries.len);
    }

    /// Whether a layout declares nothing, which decides whether a pipeline
    /// layout sets a group bit (`PipelineLayout.cpp:179`).
    pub fn isEmpty(self: *const Layout) bool {
        return self.entries.len == 0;
    }

    /// The entry at a whole-vector index.
    pub fn binding(self: *const Layout, index: BindingIndex) *const Binding {
        const value = index.toInt();
        std.debug.assert(value < self.entries.len);
        return &self.entries[value];
    }

    /// The entry at a user-facing index, or null for a private one. The
    /// distinction is what `BindGroupLayoutInternal.h:100`-`:104` exists for.
    pub fn apiBinding(self: *const Layout, index: ApiBindingIndex) ?*const Binding {
        const value = index.toInt();
        if (value >= self.queryBindingCount()) return null;
        const candidate = &self.entries[value];
        if (!candidate.isUserFacing()) return null;
        return candidate;
    }

    /// The user-facing entry a caller wrote at one binding number, or null.
    pub fn findBindingByNumber(
        self: *const Layout,
        binding_number: u32,
    ) ?*const Binding {
        const index = self.api_binding_map.get(binding_number) orelse return null;
        return self.binding(index);
    }

    /// Reads actual stored role indices, not a second expansion calculation.
    pub fn queryExternalBindingNumbers(
        self: *const Layout,
        binding_number: u32,
    ) ?ExternalBindingNumbers {
        const entry = self.findBindingByNumber(binding_number) orelse return null;
        if (entry.layout != .external_texture) return null;
        const external = entry.layout.external_texture;
        return .{
            .plane0 = self.binding(external.plane0).binding_number,
            .plane1 = self.binding(external.plane1).binding_number,
            .metadata = self.binding(external.metadata).binding_number,
            .static_sampler = if (external.static_sampler) |index|
                self.binding(index).binding_number
            else
                null,
        };
    }

    /// Every entry of one order, which is the slice the prefix sum at
    /// `BindGroupLayoutInternal.cpp:751`-`:756` carves out.
    pub fn bindingsOfType(self: *const Layout, order: BindingTypeOrder) []const Binding {
        const order_index = @backingInt(order);
        // `count` is the sentinel, not an order, so it has no range of its own.
        std.debug.assert(order_index < @backingInt(BindingTypeOrder.count));
        const start = self.type_start[order_index];
        const end = self.type_start[order_index + 1];
        return self.entries[start..end];
    }

    /// The byte identity of the packed layout. Dawn's `EqualityFunc`
    /// (`BindGroupLayoutInternal.cpp:884`), which the dedup cache keys on.
    pub fn eql(left: *const Layout, right: *const Layout) bool {
        if (left.content_hash != right.content_hash) return false;
        if (left.entries.len != right.entries.len) return false;
        for (left.entries, right.entries) |left_binding, right_binding| {
            if (!eqlBinding(left_binding, right_binding)) return false;
        }
        return true;
    }
};

/// The context `std.sort.insertion` hands back. A named zero-sized struct,
/// because the sort asks for a concrete function type and `{}` is anonymous.
const NoSortContext = struct {};

/// `SortBindingsCompare` (`BindGroupLayoutInternal.cpp:481`): the type order
/// first, then the binding number. The second key is not cosmetic — dynamic
/// buffers are applied in increasing binding number, and binding-array elements
/// must stay contiguous for a back end (`:510`-`:513`).
fn lessBindingFirst(_: NoSortContext, left: Binding, right: Binding) bool {
    const left_order = @backingInt(left.layout.typeOrder());
    const right_order = @backingInt(right.layout.typeOrder());
    if (left_order != right_order) return left_order < right_order;
    return left.binding_number < right.binding_number;
}

fn lookupIndex(
    map: *const std.AutoHashMapUnmanaged(u32, BindingIndex),
    binding_number: u32,
) BindingIndex {
    // Dawn asserts the insert succeeded at `BindGroupLayoutInternal.cpp:624`.
    // The port cannot return an error from a switch arm, so it asserts too.
    // The result is the index type, not a bare number, because most callers
    // store it in an `ExternalTextureBinding` and only two index a slice with
    // it; those two say `.toInt()` themselves.
    return map.get(binding_number) orelse unreachable;
}

fn eqlBinding(left: Binding, right: Binding) bool {
    if (left.binding_number != right.binding_number) return false;
    if (left.index_in_array != right.index_in_array) return false;
    if (left.visibility != right.visibility) return false;
    if (@backingInt(left.layout.typeOrder()) != @backingInt(right.layout.typeOrder())) {
        return false;
    }
    return switch (left.layout) {
        .buffer => |buffer| buffer.binding_type == right.layout.buffer.binding_type and
            buffer.has_dynamic_offset == right.layout.buffer.has_dynamic_offset and
            buffer.min_binding_size == right.layout.buffer.min_binding_size,
        .sampler => |sampler| sampler.binding_type == right.layout.sampler.binding_type,
        .static_sampler => |sampler| sampler.use == right.layout.static_sampler.use and
            sampler.sampled_texture_binding == right.layout.static_sampler.sampled_texture_binding and
            sampler.sampler_identity == right.layout.static_sampler.sampler_identity and
            sampler.combined_image_sampler_descriptor_count ==
                right.layout.static_sampler.combined_image_sampler_descriptor_count,
        .sampled_texture => |texture| texture.sample_type == right.layout.sampled_texture.sample_type and
            texture.view_dimension == right.layout.sampled_texture.view_dimension and
            texture.multisampled == right.layout.sampled_texture.multisampled and
            texture.internal == right.layout.sampled_texture.internal and
            texture.depth_view == right.layout.sampled_texture.depth_view,
        .storage_texture => |texture| texture.access == right.layout.storage_texture.access and
            texture.view_dimension == right.layout.storage_texture.view_dimension and
            texture.internal == right.layout.storage_texture.internal,
        .texel_buffer => |texel| texel.access == right.layout.texel_buffer.access,
        .input_attachment => |attachment| attachment.sample_type ==
            right.layout.input_attachment.sample_type,
        .external_texture => |external| external.plane0.toInt() == right.layout.external_texture.plane0.toInt() and
            external.plane1.toInt() == right.layout.external_texture.plane1.toInt() and
            external.metadata.toInt() == right.layout.external_texture.metadata.toInt() and
            optionalIndexEql(external.static_sampler, right.layout.external_texture.static_sampler),
    };
}

fn optionalIndexEql(left: ?BindingIndex, right: ?BindingIndex) bool {
    if (left) |left_value| {
        if (right) |right_value| return left_value.toInt() == right_value.toInt();
        return false;
    }
    return right == null;
}

/// One external texture's private entries, held by binding number until the
/// sort turns them into indices. `ExternalTextureExpansion`
/// (`BindGroupLayoutInternal.cpp:538`-`:543`).
const ExternalExpansion = struct {
    external_texture_binding: u32,
    plane0: u32,
    plane1: u32,
    metadata: u32,
    static_sampler: ?u32,
};

/// One static sampler's pairing, held by binding number until the sort turns it
/// into an index. `staticSamplerToSingleTextureBinding`
/// (`BindGroupLayoutInternal.cpp:548`).
const SamplerLink = struct {
    sampler_binding: u32,
    texture_binding: u32,
};

fn hashBindingLayout(hash: *std.hash.Wyhash, layout: BindingLayout) void {
    switch (layout) {
        .buffer => |buffer| {
            hash.update(std.mem.asBytes(&@backingInt(buffer.binding_type)));
            hash.update(std.mem.asBytes(&buffer.has_dynamic_offset));
            hash.update(std.mem.asBytes(&buffer.min_binding_size));
        },
        .sampler => |sampler| hash.update(std.mem.asBytes(&@backingInt(sampler.binding_type))),
        .static_sampler => |sampler| {
            hash.update(std.mem.asBytes(&@backingInt(sampler.use)));
            hash.update(std.mem.asBytes(&@as(bool, sampler.sampled_texture_binding != null)));
            if (sampler.sampled_texture_binding) |number| hash.update(std.mem.asBytes(&number));
            hash.update(std.mem.asBytes(&sampler.sampler_identity));
            hash.update(std.mem.asBytes(&sampler.combined_image_sampler_descriptor_count));
        },
        .sampled_texture => |texture| {
            hash.update(std.mem.asBytes(&@backingInt(texture.sample_type)));
            hash.update(std.mem.asBytes(&@backingInt(texture.view_dimension)));
            hash.update(std.mem.asBytes(&texture.multisampled));
            hash.update(std.mem.asBytes(&texture.internal));
            hash.update(std.mem.asBytes(&texture.depth_view));
        },
        .storage_texture => |texture| {
            hash.update(std.mem.asBytes(&@backingInt(texture.access)));
            hash.update(std.mem.asBytes(&@backingInt(texture.view_dimension)));
            hash.update(std.mem.asBytes(&texture.internal));
        },
        .texel_buffer => |texel| hash.update(std.mem.asBytes(&@backingInt(texel.access))),
        .input_attachment => |attachment| hash.update(
            std.mem.asBytes(&@backingInt(attachment.sample_type)),
        ),
        .external_texture => |external| {
            hash.update(std.mem.asBytes(&external.plane0.toInt()));
            hash.update(std.mem.asBytes(&external.plane1.toInt()));
            hash.update(std.mem.asBytes(&external.metadata.toInt()));
        },
    }
}

/// `ConvertToBindingInfo` (`BindGroupLayoutInternal.cpp:447`): the one place a
/// caller's entry becomes a stored binding, so the kind count is checked once
/// and every caller of it gets a union.
fn convertToBinding(entry: Entry) Error!Binding {
    const array_size = @max(1, entry.array_size);
    const kind_count = countKinds(entry.kind);
    if (kind_count == 0) return error.NoBindingKindInEntry;
    if (kind_count > 1) return error.MultipleBindingKindsInEntry;

    const layout: BindingLayout = switch (entry.kind) {
        .buffer => |buffer| if (buffer) |value| .{ .buffer = value } else unreachable,
        .sampler => |sampler| if (sampler) |value| .{ .sampler = value } else unreachable,
        .static_sampler => |sampler| if (sampler) |value| .{ .static_sampler = value } else unreachable,
        .sampled_texture => |texture| if (texture) |value| .{ .sampled_texture = value } else unreachable,
        .storage_texture => |texture| if (texture) |value| .{ .storage_texture = value } else unreachable,
        .texel_buffer => |texel| if (texel) |value| .{ .texel_buffer = value } else unreachable,
        .input_attachment => |attachment| if (attachment) |value| .{ .input_attachment = value } else unreachable,
        .external_texture => if (entry.kind.external_texture) .{
            .external_texture = .{
                .plane0 = .fromInt(0),
                .plane1 = .fromInt(0),
                .metadata = .fromInt(0),
                .static_sampler = null,
            },
        } else unreachable,
    };

    return .{
        .binding_number = entry.binding_number,
        .visibility = entry.visibility,
        .array_size = array_size,
        .index_in_array = 0,
        .layout = layout,
    };
}

/// How many binding kinds one entry named. Dawn counts them one `if` at a time
/// (`BindGroupLayoutInternal.cpp:114`, `:142`, `:152`, `:194`, `:229`, `:248`,
/// `:272`) and refuses a total other than one at `:284`.
fn countKinds(kind: EntryKind) u32 {
    // One prong per tag. A kind added to `EntryKindTag` without a union field,
    // or a union field without a prong, is a compile error here.
    // The switch reads only the member the tag names.
    return switch (kind) {
        .buffer => @intFromBool(kind.buffer != null),
        .sampler => @intFromBool(kind.sampler != null),
        .static_sampler => @intFromBool(kind.static_sampler != null),
        .sampled_texture => @intFromBool(kind.sampled_texture != null),
        .storage_texture => @intFromBool(kind.storage_texture != null),
        .texel_buffer => @intFromBool(kind.texel_buffer != null),
        .input_attachment => @intFromBool(kind.input_attachment != null),
        // The flag rather than a payload, so it is asked rather than null-tested.
        .external_texture => @intFromBool(kind.external_texture),
    };
}

/// `ValidateBindGroupLayoutDescriptor` (`BindGroupLayoutInternal.cpp:338`):
/// every entry, then the binding numbers, then the per-stage counts.
fn validateDescriptor(
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    options: ValidateOptions,
) Error!void {
    const max_entry_count = descriptor.entries.len;
    var entry_index: usize = 0;
    while (entry_index < max_entry_count) : (entry_index += 1) {
        try validateEntry(descriptor.entries[entry_index], options);
    }

    // The binding numbers must be distinct across the whole descriptor, and
    // the expansion runs afterwards, so this is checked before it.
    var sampler_texture_numbers = std.ArrayList(u32).empty;
    defer sampler_texture_numbers.deinit(allocator);
    var public_numbers: std.bit_set.Static(max_bindings_per_bind_group) = .empty;
    entry_index = 0;
    while (entry_index < max_entry_count) : (entry_index += 1) {
        const entry = descriptor.entries[entry_index];
        if (entry.binding_number >= max_bindings_per_bind_group) {
            return error.BindingNumberAboveLimit;
        }
        const array_size = @max(1, entry.array_size);
        if (array_size > max_bindings_per_bind_group - entry.binding_number) {
            return error.BindingNumberAboveLimit;
        }
        var element_index: u32 = 0;
        while (element_index < array_size) : (element_index += 1) {
            const number = entry.binding_number + element_index;
            if (public_numbers.isSet(number)) return error.DuplicateBindingNumber;
            public_numbers.set(number);
        }
        switch (entry.kind) {
            .static_sampler => |sampler| {
                const value = sampler orelse continue;
                if (value.sampled_texture_binding) |texture_number| {
                    try sampler_texture_numbers.append(allocator, texture_number);
                }
            },
            else => {},
        }
    }

    var storage_buffer_count_by_stage = std.ArrayList(u32).empty;
    defer storage_buffer_count_by_stage.deinit(allocator);
    try storage_buffer_count_by_stage.appendNTimes(allocator, 0, ShaderStages.stage_count);
    entry_index = 0;
    while (entry_index < max_entry_count) : (entry_index += 1) {
        const entry = descriptor.entries[entry_index];
        switch (entry.kind) {
            .buffer => |buffer| {
                const value = buffer orelse continue;
                if (value.binding_type == .uniform) continue;
                inline for (0..ShaderStages.stage_count) |stage_index| {
                    if (entry.visibility.hasStage(stage_index)) {
                        storage_buffer_count_by_stage.items[stage_index] += 1;
                    }
                }
            },
            else => {},
        }
    }

    // `ValidateStaticSamplersWithTextureBindings` (`BindGroupLayoutInternal.cpp:295`):
    // each sampler names a distinct entry that is a texture and not a storage
    // texture.
    const sampler_count = sampler_texture_numbers.items.len;
    var sampler_index: usize = 0;
    while (sampler_index < sampler_count) : (sampler_index += 1) {
        const texture_number = sampler_texture_numbers.items[sampler_index];
        var found: ?Entry = null;
        entry_index = 0;
        while (entry_index < max_entry_count) : (entry_index += 1) {
            const entry = descriptor.entries[entry_index];
            if (entry.binding_number == texture_number) {
                found = entry;
                break;
            }
        }
        const paired = found orelse return error.StaticSamplerTextureBindingInvalid;
        if (paired.binding_number == descriptor.entries[sampler_index].binding_number) {
            return error.StaticSamplerTextureBindingInvalid;
        }
        if (paired.kind.sampled_texture == null and
            paired.kind.static_sampler == null)
        {
            return error.StaticSamplerTextureBindingInvalid;
        }
        if (paired.kind.storage_texture != null) {
            return error.StaticSamplerTextureBindingInvalid;
        }
    }

    // `ValidateBindingCounts` (`BindingInfo.cpp:216`-`:333`) walks the stages
    // and applies the two compatibility-mode limits inside its switch. The port
    // keeps those two rules because the plan's M12 acceptance names those two,
    // and M7 owns the table the rest of the limits come from.
    const counts = storage_buffer_count_by_stage.items;
    if (counts[stageIndex(.vertex)] > options.max_storage_buffers_in_vertex_stage) {
        return error.StorageBuffersPerShaderStageInVertexStage;
    }
    if (counts[stageIndex(.fragment)] > options.max_storage_buffers_in_fragment_stage) {
        return error.StorageBuffersPerShaderStageInFragmentStage;
    }
}

/// `ValidateBindGroupLayoutEntry` (`BindGroupLayoutInternal.cpp:105`): the one
/// entry, after the kind count has already been refused elsewhere.
fn validateEntry(entry: Entry, options: ValidateOptions) Error!void {
    if (entry.visibility.isEmpty()) return error.BindingVisibilityEmpty;
    const array_size = @max(1, entry.array_size);

    switch (entry.kind) {
        .buffer => |buffer| {
            const value = buffer orelse return error.NoBindingKindInEntry;
            const internal = value.binding_type == .internal_storage or
                value.binding_type == .internal_read_only_storage;
            if (internal and !options.allow_internal_bindings) {
                return error.InternalBindingNotAllowed;
            }
            if ((value.binding_type == .storage or value.binding_type == .internal_storage) and
                entry.visibility.vertex)
            {
                return error.StorageBufferInVertexStage;
            }
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
        .sampler => {
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
        .static_sampler => |sampler| {
            const value = sampler orelse return error.NoBindingKindInEntry;
            if (value.use == .single_texture_ycbcr) {
                if (!options.allow_internal_bindings) return error.InternalBindingNotAllowed;
                if (value.sampler_identity == 0 or
                    value.combined_image_sampler_descriptor_count == 0 or
                    value.combined_image_sampler_descriptor_count > 3 or
                    value.sampled_texture_binding != null)
                {
                    return error.InvalidStaticSamplerBinding;
                }
            } else if (value.combined_image_sampler_descriptor_count != 1) {
                return error.InvalidStaticSamplerBinding;
            }
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
        .sampled_texture => |texture| {
            const value = texture orelse return error.NoBindingKindInEntry;
            if ((value.internal and !options.allow_internal_bindings) or
                (value.depth_view and !value.internal))
            {
                return error.InternalBindingNotAllowed;
            }
            if (value.depth_view and
                value.sample_type != .float_unfilterable)
            {
                return error.MultisampledTextureBindingUnsupported;
            }
            if (!value.multisampled) return;
            if (value.view_dimension != .two_d) {
                return error.MultisampledTextureBindingUnsupported;
            }
            if (value.sample_type == .float_filterable) {
                return error.MultisampledTextureBindingUnsupported;
            }
        },
        .storage_texture => |texture| {
            const value = texture orelse return error.NoBindingKindInEntry;
            if (value.internal and !options.allow_internal_bindings) {
                return error.InternalBindingNotAllowed;
            }
            if (value.view_dimension == .cube or value.view_dimension == .cube_array) {
                return error.StorageTextureViewDimensionUnsupported;
            }
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
        .texel_buffer => {
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
        .input_attachment => {
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
        .external_texture => {
            // Dawn asserts `bindingArraySize <= 1` for an external texture
            // (`BindGroupLayoutInternal.cpp:559`): one external texture cannot
            // take more than one metadata buffer.
            if (array_size > 1) return error.BindingArraySizeNotOne;
        },
    }
}

test "private layout kinds require explicit internal admission" {
    const options: ValidateOptions = .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
    };
    const kinds = [_]EntryKind{
        .{ .buffer = .{
            .binding_type = .internal_storage,
            .has_dynamic_offset = false,
            .min_binding_size = 4,
        } },
        .{ .buffer = .{
            .binding_type = .internal_read_only_storage,
            .has_dynamic_offset = false,
            .min_binding_size = 4,
        } },
        .{ .sampled_texture = .{
            .sample_type = .float_unfilterable,
            .view_dimension = .two_d,
            .multisampled = false,
            .internal = true,
        } },
        .{ .storage_texture = .{
            .access = .write_only,
            .view_dimension = .two_d,
            .internal = true,
        } },
    };
    for (kinds) |kind| {
        const entries = [_]Entry{.{
            .binding_number = 0,
            .visibility = .{ .compute = true },
            .kind = kind,
        }};
        try std.testing.expectError(error.InternalBindingNotAllowed, Layout.init(
            std.testing.allocator,
            .{ .entries = &entries },
            options,
        ));
        var internal_options = options;
        internal_options.allow_internal_bindings = true;
        var accepted = try Layout.init(
            std.testing.allocator,
            .{ .entries = &entries },
            internal_options,
        );
        accepted.deinit(std.testing.allocator);
    }
}

test "combined conversion identity and physical cost remain semantic" {
    var owner_identity: u8 = 0;
    var other_identity: u8 = 0;
    const entries = [_]Entry{.{
        .binding_number = 0,
        .visibility = .{ .fragment = true },
        .kind = .{ .static_sampler = .{
            .use = .single_texture_ycbcr,
            .sampled_texture_binding = null,
            .sampler_identity = @intFromPtr(&owner_identity),
            .combined_image_sampler_descriptor_count = 3,
        } },
    }};
    const options: ValidateOptions = .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
        .allow_internal_bindings = true,
    };
    var public_options = options;
    public_options.allow_internal_bindings = false;
    try std.testing.expectError(error.InternalBindingNotAllowed, Layout.init(
        std.testing.allocator,
        .{ .entries = &entries },
        public_options,
    ));
    var first = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), first.queryBindingCount());
    try std.testing.expectEqual(@as(u32, 3), first.validation_counts.samplers_per_stage[1]);
    try std.testing.expectEqual(@as(u32, 3), first.validation_counts.sampled_textures_per_stage[1]);
    var changed = entries;
    changed[0].kind.static_sampler.?.sampler_identity = @intFromPtr(&other_identity);
    var second = try Layout.init(std.testing.allocator, .{ .entries = &changed }, options);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!Layout.eql(&first, &second));
    changed = entries;
    changed[0].kind.static_sampler.?.combined_image_sampler_descriptor_count = 2;
    var third = try Layout.init(std.testing.allocator, .{ .entries = &changed }, options);
    defer third.deinit(std.testing.allocator);
    try std.testing.expect(!Layout.eql(&first, &third));
    changed = entries;
    changed[0].kind.static_sampler.?.sampler_identity = 0;
    try std.testing.expectError(error.InvalidStaticSamplerBinding, Layout.init(
        std.testing.allocator,
        .{ .entries = &changed },
        options,
    ));
    changed = entries;
    changed[0].kind.static_sampler.?.combined_image_sampler_descriptor_count = 0;
    try std.testing.expectError(error.InvalidStaticSamplerBinding, Layout.init(
        std.testing.allocator,
        .{ .entries = &changed },
        options,
    ));
    changed = entries;
    changed[0].kind.static_sampler.?.sampled_texture_binding = 1;
    try std.testing.expectError(error.InvalidStaticSamplerBinding, Layout.init(
        std.testing.allocator,
        .{ .entries = &changed },
        options,
    ));
    changed = entries;
    changed[0].kind.static_sampler.?.combined_image_sampler_descriptor_count = 4;
    try std.testing.expectError(error.InvalidStaticSamplerBinding, Layout.init(
        std.testing.allocator,
        .{ .entries = &changed },
        options,
    ));
    changed[0].kind.static_sampler.?.combined_image_sampler_descriptor_count =
        std.math.maxInt(u32);
    var oversized = [_]Entry{ changed[0], changed[0] };
    oversized[1].binding_number = 1;
    try std.testing.expectError(error.InvalidStaticSamplerBinding, Layout.init(
        std.testing.allocator,
        .{ .entries = &oversized },
        options,
    ));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        combinedLayoutAllocationRoundTrip,
        .{ @as([]const Entry, &entries), options },
    );
}

test "private texture permission and depth view change logical identity" {
    var entries = [_]Entry{.{
        .binding_number = 0,
        .visibility = .{ .compute = true },
        .kind = .{ .sampled_texture = .{
            .sample_type = .float_unfilterable,
            .view_dimension = .two_d,
            .multisampled = false,
        } },
    }};
    const options: ValidateOptions = .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
        .allow_internal_bindings = true,
    };
    var public = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
    defer public.deinit(std.testing.allocator);
    entries[0].kind.sampled_texture.?.internal = true;
    var private = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
    defer private.deinit(std.testing.allocator);
    try std.testing.expect(!Layout.eql(&public, &private));
    entries[0].kind.sampled_texture.?.depth_view = true;
    var depth = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
    defer depth.deinit(std.testing.allocator);
    try std.testing.expect(!Layout.eql(&private, &depth));
    entries[0].kind.sampled_texture.?.internal = false;
    try std.testing.expectError(error.InternalBindingNotAllowed, Layout.init(
        std.testing.allocator,
        .{ .entries = &entries },
        options,
    ));
}

fn combinedLayoutAllocationRoundTrip(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    options: ValidateOptions,
) !void {
    var internal = try Layout.init(allocator, .{ .entries = entries }, options);
    defer internal.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), internal.queryBindingCount());
}

test "private storage texture permission remains a separate logical key" {
    var entries = [_]Entry{.{
        .binding_number = 0,
        .visibility = .{ .compute = true },
        .kind = .{ .storage_texture = .{
            .access = .write_only,
            .view_dimension = .two_d,
        } },
    }};
    const options: ValidateOptions = .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
        .allow_internal_bindings = true,
    };
    var public = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
    defer public.deinit(std.testing.allocator);
    entries[0].kind.storage_texture.?.internal = true;
    var private = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
    defer private.deinit(std.testing.allocator);
    try std.testing.expect(!Layout.eql(&public, &private));
}

test "private depth image ABI supports matching multisampled views" {
    const entries = [_]Entry{.{
        .binding_number = 0,
        .visibility = .{ .fragment = true },
        .kind = .{ .sampled_texture = .{
            .sample_type = .float_unfilterable,
            .view_dimension = .two_d,
            .multisampled = true,
            .internal = true,
            .depth_view = true,
        } },
    }};
    var internal = try Layout.init(std.testing.allocator, .{ .entries = &entries }, .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
        .allow_internal_bindings = true,
    });
    defer internal.deinit(std.testing.allocator);
    try std.testing.expect(internal.entries[0].layout.sampled_texture.depth_view);
    try std.testing.expect(internal.entries[0].layout.sampled_texture.multisampled);
}

test "external binding blocks cover the bounded private namespace" {
    var occupied: std.bit_set.Static(5 * max_bindings_per_bind_group) = .empty;
    for (0..max_bindings_per_bind_group) |number| {
        const binding_number: u32 = @intCast(number);
        const roles = try externalBindingNumbers(.{
            .binding_number = binding_number,
            .needs_static_sampler = true,
        });
        const without_sampler = try externalBindingNumbers(.{ .binding_number = binding_number });
        try std.testing.expectEqual(1000 + 4 * binding_number, roles.plane0);
        try std.testing.expectEqual(roles.plane0 + 1, roles.plane1);
        try std.testing.expectEqual(roles.plane0 + 2, roles.metadata);
        try std.testing.expectEqual(roles.plane0 + 3, roles.static_sampler.?);
        try std.testing.expectEqual(roles.plane0, without_sampler.plane0);
        try std.testing.expectEqual(roles.plane1, without_sampler.plane1);
        try std.testing.expectEqual(roles.metadata, without_sampler.metadata);
        try std.testing.expect(without_sampler.static_sampler == null);
        for ([_]u32{ roles.plane0, roles.plane1, roles.metadata, roles.static_sampler.? }) |role| {
            try std.testing.expect(role >= max_bindings_per_bind_group);
            try std.testing.expect(role < 5 * max_bindings_per_bind_group);
            try std.testing.expect(!occupied.isSet(role));
            occupied.set(role);
        }
    }
    try std.testing.expectEqual(@as(usize, 4000), occupied.count());
    try std.testing.expectError(error.BindingNumberAboveLimit, externalBindingNumbers(.{
        .binding_number = max_bindings_per_bind_group,
    }));
    try std.testing.expectError(error.BindingNumberAboveLimit, externalBindingNumbers(.{
        .binding_number = std.math.maxInt(u32),
    }));
}

test "external expansion identity and actual roles are independent of descriptor order" {
    const entries = [_]Entry{
        .{
            .binding_number = 999,
            .visibility = .{ .fragment = true },
            .kind = .{ .external_texture = true },
        },
        .{
            .binding_number = 217,
            .visibility = .{ .fragment = true },
            .kind = .{ .buffer = .{
                .binding_type = .uniform,
                .has_dynamic_offset = false,
                .min_binding_size = 16,
            } },
        },
        .{
            .binding_number = 0,
            .visibility = .{ .fragment = true },
            .kind = .{ .external_texture = true },
        },
    };
    const reversed = [_]Entry{ entries[2], entries[1], entries[0] };
    for ([_]bool{ false, true }) |needs_sampler| {
        const options: ValidateOptions = .{
            .max_storage_buffers_in_vertex_stage = 8,
            .max_storage_buffers_in_fragment_stage = 8,
            .needs_static_sampler_for_external_texture = needs_sampler,
        };
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            externalExpansionAllocationRoundTrip,
            .{ @as([]const Entry, &entries), options },
        );
        var first = try Layout.init(std.testing.allocator, .{ .entries = &entries }, options);
        defer first.deinit(std.testing.allocator);
        var second = try Layout.init(std.testing.allocator, .{ .entries = &reversed }, options);
        defer second.deinit(std.testing.allocator);
        try std.testing.expectEqual(first.content_hash, second.content_hash);
        try std.testing.expect(Layout.eql(&first, &second));
        try std.testing.expectEqual(@as(u32, 217), first.findBindingByNumber(217).?.binding_number);
        try std.testing.expect(first.queryExternalBindingNumbers(217) == null);
        try std.testing.expect(first.queryExternalBindingNumbers(218) == null);
        for ([_]u32{ 0, 999 }) |number| {
            const expected = try externalBindingNumbers(.{
                .binding_number = number,
                .needs_static_sampler = needs_sampler,
            });
            const actual = first.queryExternalBindingNumbers(number).?;
            const other = second.queryExternalBindingNumbers(number).?;
            try std.testing.expect(std.meta.eql(expected, actual));
            try std.testing.expect(std.meta.eql(actual, other));
            const external = first.findBindingByNumber(number).?.layout.external_texture;
            try std.testing.expectEqual(actual.plane0, first.binding(external.plane0).binding_number);
            try std.testing.expectEqual(actual.plane1, first.binding(external.plane1).binding_number);
            try std.testing.expectEqual(actual.metadata, first.binding(external.metadata).binding_number);
            if (external.static_sampler) |index| {
                try std.testing.expectEqual(actual.static_sampler.?, first.binding(index).binding_number);
            } else {
                try std.testing.expect(actual.static_sampler == null);
            }
        }
    }
}

test "duplicate public and overlapping physical entries fail before publication" {
    const options: ValidateOptions = .{
        .max_storage_buffers_in_vertex_stage = 8,
        .max_storage_buffers_in_fragment_stage = 8,
    };
    const external: Entry = .{
        .binding_number = 0,
        .visibility = .{ .fragment = true },
        .kind = .{ .external_texture = true },
    };
    const duplicate = [_]Entry{ external, external };
    try std.testing.expectError(error.DuplicateBindingNumber, Layout.init(
        std.testing.allocator,
        .{ .entries = &duplicate },
        options,
    ));
    const sampled: Entry = .{
        .binding_number = 10,
        .visibility = .{ .fragment = true },
        .array_size = 2,
        .kind = .{ .sampled_texture = .{
            .sample_type = .float_filterable,
            .view_dimension = .two_d,
            .multisampled = false,
        } },
    };
    var overlapping = [_]Entry{ sampled, sampled };
    overlapping[1].binding_number = 11;
    overlapping[1].array_size = 1;
    try std.testing.expectError(error.DuplicateBindingNumber, Layout.init(
        std.testing.allocator,
        .{ .entries = &overlapping },
        options,
    ));
    overlapping[1].binding_number = 12;
    var valid = try Layout.init(std.testing.allocator, .{ .entries = &overlapping }, options);
    defer valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), valid.findBindingByNumber(10).?.array_size);
    try std.testing.expectEqual(@as(u32, 1), valid.findBindingByNumber(11).?.index_in_array);
    overlapping[0].binding_number = 999;
    try std.testing.expectError(error.BindingNumberAboveLimit, Layout.init(
        std.testing.allocator,
        .{ .entries = &overlapping },
        options,
    ));
}

fn externalExpansionAllocationRoundTrip(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    options: ValidateOptions,
) !void {
    var internal = try Layout.init(allocator, .{ .entries = entries }, options);
    defer internal.deinit(allocator);
    try std.testing.expect(internal.queryExternalBindingNumbers(0) != null);
    try std.testing.expect(internal.queryExternalBindingNumbers(999) != null);
}
