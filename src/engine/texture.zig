//! The texture, the texture view, and the linear texel copy between them.
//!
//! **What this file is.** `native/Texture.{h,cpp}` and the two format rules at
//! the top of `native/TexelBufferView.cpp`: texture creation and its rules
//! (`Texture.cpp:785`), the view rules (`Texture.cpp:923`), the defaults a view
//! descriptor resolves against (`Texture.cpp:1000`), the mip and subresource
//! arithmetic (`Texture.cpp:1401`-`:1575`), and the linear copy layout rules
//! that decide how many bytes a texel copy touches and whether a row pitch is
//! legal (`src/dawn/native/CommandValidation.cpp:295`-`:473`).
//!
//! CPU-only objects keep their deterministic linear store. Native initialization
//! attaches an owned Vulkan image to that same object; command records still
//! contain implementation pointers, never Vulkan handles.
//! Native transitions reject missing storage with `TextureNativeNotInitialized`
//! before validating subresource ranges or changing synchronization state.
//!
//! **Where the texel-buffer rules live.** `formatSupportedForTexelBuffer` and
//! `validateTexelBufferFormat` are the two free functions in
//! `TexelBufferView.cpp`. They are here because this file owns the rules that
//! read them. The view object itself is created by `BufferBase::CreateTexelView`
//! (`src/dawn/native/Buffer.cpp:1242-1245`), which lands with the buffer at M10.

const std = @import("std");

const vulkan = @import("vulkan");

const api = @import("../api/api.zig");
const bitmask = api.bitmask;
const constants = api.constants;
const descriptors = api.descriptors;
const enums = api.enums;
const objects = api.objects;
const commands = @import("../command/commands.zig");
const device = @import("../core/device.zig");
const core_errors = @import("../core/errors.zig");
const handle = @import("../core/handle.zig");
const object = @import("../core/object.zig");
const dispatch = @import("../vk/dispatch.zig");
const platform = @import("../platform/root.zig");
const buffer_mod = @import("buffer.zig");
const command_replay = @import("command_buffer.zig");
const features = @import("features.zig");
const canonical_format = @import("format.zig");
const queue_mod = @import("queue.zig");
const sampler_mod = @import("sampler.zig");
const native_y_cb_cr_format = @import("native_y_cb_cr_format.zig");
const vulkan_device = @import("vulkan_device.zig");
const vulkan_format = @import("vulkan_format.zig");

pub const NativeError = dispatch.Error || dispatch.LoadError || object.ReferenceError ||
    sampler_mod.NativeError || native_y_cb_cr_format.Error ||
    std.mem.Allocator.Error || vulkan_format.SampleCountError || error{
    TextureNativeAlreadyInitialized,
    TextureNativeNotInitialized,
    TextureNativeUsageUnsupported,
    TextureNativeRangeInvalid,
    TextureNativeMemoryUnavailable,
    TextureNativeDestroyed,
    TextureNativeCPUContentsUnsupported,
    TextureNativeAllocationOverflow,
    TextureYCbCrSamplerMismatch,
    TextureNativeDeviceMismatch,
    TextureNativeCreationReturnedNull,
    TextureNativeYCbCrCopyUnsupported,
};
pub const InitializationError = NativeError || buffer_mod.Error;
pub const NativeCreateError = CreateError || NativeError;

const NativeUsageState = struct {
    layout: vulkan.VkImageLayout,
    access: vulkan.VkAccessFlags,
    stages: vulkan.VkPipelineStageFlags,
};

const NativeTexture = struct {
    allocator: std.mem.Allocator,
    context: buffer_mod.Device,
    procs: *const dispatch.DeviceProcs,
    image: vulkan.VkImage,
    memory: vulkan.VkDeviceMemory,
    states: []NativeUsageState,
    view_count: usize = 0,
    destroy_requested: bool = false,
};

pub const InternalYCbCrDescriptor = struct {
    label: []const u8 = "",
    size: api.Extent2D,
    conversion_sampler: *sampler_mod.Sampler,
};

const NativeYCbCr = struct {
    traits: native_y_cb_cr_format.Traits,
    combined_image_sampler_descriptor_count: u32,
    image_properties: vulkan.VkImageFormatProperties,
    converted_format_info: canonical_format.Format = .{
        .format = .undefined_,
        .aspects = .color,
        .component_count = 4,
        .aspect_info = .{ .{
            .base_type = .float,
            .supported_sample_types = .{ .float = true, .unfilterable_float = true },
        }, .{}, .{} },
    },
};

pub const AttachmentOptions = struct {
    depth_read_only: bool = false,
    stencil_read_only: bool = false,
};

pub const BarrierBatch = struct {
    image_barriers: std.ArrayList(vulkan.VkImageMemoryBarrier) = .empty,
    source_stages: vulkan.VkPipelineStageFlags = 0,
    destination_stages: vulkan.VkPipelineStageFlags = 0,

    pub fn deinit(self: *BarrierBatch, allocator: std.mem.Allocator) void {
        self.image_barriers.deinit(allocator);
        self.* = .{};
    }
};

const AttachmentView = struct {
    allocator: std.mem.Allocator,
    handle: vulkan.VkImageView,
    depth_slice: u32,
    next: ?*AttachmentView,
};

/// Every way creating a texture or a view can fail. The set is named so a
/// reader enumerates the obligations from the signature (`AGENTS.md` §2).
pub const CreateError = core_errors.ValidationError || object.CreateError || object.ReferenceError;

/// The row pitch every linear texel copy must use. Dawn fixes it at
/// `src/dawn/common/Constants.h:44` and checks it at `CommandValidation.cpp:426`.
/// It is the alignment a Vulkan `bufferRowLength` in texels has to honour, so it
/// is a property of the queue and not of the copy.
pub const texture_bytes_per_row_alignment: u32 = 256;

/// Dawn's internal aspect enum (`src/dawn/native/Subresource.h:39`). A texture
/// view holds a mask of these, and a subresource is one bit of the mask.
pub const Aspect = enum(u8) {
    none = 0x0,
    color = 0x1,
    depth = 0x2,
    stencil = 0x4,
    combined_depth_stencil = 0x40,
};

/// The same set as a bitfield. A packed struct with one field per bit is the
/// shape `src/api/bitmask.zig` already uses, so a mask reads the same way here
/// as it does everywhere else in the port.
pub const AspectMask = packed struct(u8) {
    color: u1 = 0,
    depth: u1 = 0,
    stencil: u1 = 0,
    plane_0: u1 = 0,
    plane_1: u1 = 0,
    plane_2: u1 = 0,
    combined_depth_stencil: u1 = 0,
    _padding: u1 = 0,

    pub inline fn toFlags(value: AspectMask) u8 {
        return @bitCast(value);
    }

    pub inline fn fromFlags(flags: u8) AspectMask {
        return @bitCast(flags);
    }

    /// Dawn's `IsSubset`. The name is the question the rules ask.
    pub fn has(self: AspectMask, other: AspectMask) bool {
        return (self.toFlags() & other.toFlags()) == other.toFlags();
    }

    pub inline fn merge(a: AspectMask, b: AspectMask) AspectMask {
        return fromFlags(a.toFlags() | b.toFlags());
    }
};

/// The four limits `ValidateTextureSize` reads (`Texture.cpp:292`-`:307`). A
/// subset of `api.Limits`, which M7 builds, because these four are the only
/// ones a texture descriptor can be above.
pub const TextureLimits = struct {
    max_texture_dimension_1d: u32,
    max_texture_dimension_2d: u32,
    max_texture_dimension_3d: u32,
    max_texture_array_layers: u32,
};

/// What `Texture.create` needs.
pub const Options = struct {
    /// The chain root, because the descriptor is extensible and its extension
    /// slots are part of the rule surface: `texture_binding_view_dimension` is
    /// read by `resolveBindingViewDimension`, and `view_formats` by the creation
    /// rules.
    descriptor: descriptors.TextureDescriptorChain,
    /// The facts about `descriptor.format`, from the format table.
    format_info: *const canonical_format.Format,
    limits: TextureLimits,
    /// Dawn reads this from the device at `Texture.cpp:657`, `:857` and `:133`.
    /// The port takes it as a parameter because the device that owns the
    /// compatibility profile lands at M16.
    compatibility_mode: bool = false,
};

/// What `Texture.createView` needs.
pub const ViewOptions = struct {
    /// The chain root, for the same reason `Options.descriptor` is one. Its
    /// swizzle slot is read by `validateComponentSwizzle`; the YCbCr slot is
    /// not read, and the M11 table row says so.
    descriptor: descriptors.TextureViewDescriptorChain,
    /// The facts about `descriptor.format`. It is the view's format, not the
    /// texture's: a view may name a format compatible with the texture's.
    format_info: *const canonical_format.Format,
    compatibility_mode: bool = false,
};

/// Dawn's `SubresourceRange` (`src/dawn/native/Subresource.h:89`), with the
/// aspects as the mask the format already holds.
pub const SubresourceRange = struct {
    aspects: AspectMask,
    base_array_layer: u32,
    layer_count: u32,
    base_mip_level: u32,
    level_count: u32,
};

/// Dawn's `wgpu::TexelCopyBufferLayout`, the wire type
/// `ApplyDefaultTexelCopyBufferLayoutOptions` takes
/// (`src/dawn/native/CommandValidation.cpp:345-347`). Dawn keeps
/// `kCopyStrideUndefined` as a sentinel in that value and the port keeps it,
/// because the default depends on the copy extent and only the validation path
/// knows the extent.
pub const TexelCopyBufferLayout = struct {
    offset: u64 = 0,
    bytes_per_row: u32 = constants.CopyStrideUndefined,
    rows_per_image: u32 = constants.CopyStrideUndefined,
};

/// Dawn's `TexelCopyTextureInfo`, forward-declared at
/// `src/dawn/native/Commands.h:49` and taken by the copy validators, without
/// the texture, which is the object the call is on.
pub const TexelCopyTextureInfo = struct {
    mip_level: u32 = 0,
    origin: descriptors.Origin3D = .{},
    aspect: enums.TextureAspect = .all,
};

/// The extent the copy resolves against. Dawn declares no matching layout at
/// this revision, so this file names the pair it holds.
pub const TexelCopyTextureLayout = struct {
    offset: descriptors.Origin3D = .{},
    size: descriptors.Extent3D,
};

/// A view descriptor with every default filled in. Dawn resolves the defaults
/// in `GetTextureViewDescriptorWithDefaults` (`Texture.cpp:1000`) into a copy,
/// so the caller's descriptor is never mutated; this is that copy.
pub const ResolvedViewDescriptor = struct {
    format: enums.TextureFormat,
    dimension: enums.TextureViewDimension,
    base_mip_level: u32,
    mip_level_count: u32,
    base_array_layer: u32,
    array_layer_count: u32,
    aspect: enums.TextureAspect,
    usage: bitmask.TextureUsage,
    swizzle: descriptors.TextureComponentSwizzle,
};

/// A texture as the engine holds it.
///
/// Dawn's `TextureBase` is a `RefCountedWithExternalCount<SharedResource>` with
/// private fields (`src/dawn/native/Texture.h:293`-`:323`). The port is an arena
/// object with public fields (`docs/10-architecture.md`, Object model), and the
/// methods below are the named reads the callers use.
pub const Texture = struct {
    header: object.Object,

    format_info: *const canonical_format.Format,
    dimension: enums.TextureDimension,
    /// Resolved from the dimension and the layer count at creation, as Dawn does
    /// at `Texture.cpp:1107`.
    binding_view_dimension: enums.TextureViewDimension,
    base_size: descriptors.Extent3D,
    mip_level_count: u32,
    sample_count: u32,
    usage: bitmask.TextureUsage,
    internal_usage: bitmask.TextureUsage,
    /// The formats the caller named at creation, copied into the arena. The
    /// descriptor's slice belongs to the caller and does not outlive the call.
    view_formats: []const enums.TextureFormat,
    compatibility_mode: bool,

    /// The linear store. One subresource after another in `subresourceIndex`
    /// order, sized by `subresourceByteSize`.
    bytes: []u8,
    /// Where each subresource starts inside `bytes`, with a final sentinel. The
    /// store is addressed through this table and not through arithmetic on the
    /// mip level, because a level's size is not a product of the level's
    /// dimensions: the count halves every level.
    subresource_offsets: []const usize,
    /// Dawn's `mIsSubresourceContentInitializedAtIndex` (`Texture.h:319`):
    /// one flag per subresource.
    initialized: []bool,
    native: ?*NativeTexture = null,
    native_y_cb_cr: ?NativeYCbCr = null,

    /// Attach native storage only after the logical descriptor is validated.
    /// The caller keeps the device alive and waits for GPU use before teardown.
    /// The allocator is retained by native storage and attachment-view caches;
    /// it must remain valid until the image and its last native view are freed.
    /// Recording scratch allocators cannot own this persistent storage.
    pub fn initializeNative(
        self: *Texture,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        context: buffer_mod.Device,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        if (self.native != null) return error.TextureNativeAlreadyInitialized;
        for (self.initialized) |initialized| {
            if (initialized) return error.TextureNativeCPUContentsUnsupported;
        }
        const procs = context.dispatch.device orelse return error.MissingDeviceProc;
        const create_image = procs.create_image orelse return error.MissingDeviceProc;
        const destroy_image = procs.destroy_image orelse return error.MissingDeviceProc;
        const requirements_fn = procs.get_image_memory_requirements orelse
            return error.MissingDeviceProc;
        const allocate_memory = procs.allocate_memory orelse return error.MissingDeviceProc;
        const free_memory = procs.free_memory orelse return error.MissingDeviceProc;
        const bind_memory = procs.bind_image_memory orelse return error.MissingDeviceProc;
        var usage: vulkan.VkImageUsageFlags = vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (self.internal_usage.copy_src) usage |= vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        if (self.internal_usage.texture_binding) usage |= vulkan.VK_IMAGE_USAGE_SAMPLED_BIT;
        if (self.internal_usage.storage_binding) usage |= vulkan.VK_IMAGE_USAGE_STORAGE_BIT;
        if (self.internal_usage.render_attachment) {
            usage |= if (self.format_info.isColor())
                @as(u32, vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
            else
                @as(u32, vulkan.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
        }
        var create_info: vulkan.VkImageCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .flags = if (self.native_y_cb_cr != null) 0 else (if (self.view_formats.len != 0)
                @as(u32, vulkan.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT)
            else
                0) |
                (if (self.dimension == ._2d and self.getArrayLayers(guard) >= 6 and
                    self.base_size.width == self.base_size.height)
                    @as(u32, vulkan.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT)
                else
                    0) |
                (if (self.dimension == ._3d)
                    @as(u32, vulkan.VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT)
                else
                    0),
            .imageType = switch (self.dimension) {
                ._1d => vulkan.VK_IMAGE_TYPE_1D,
                ._2d => vulkan.VK_IMAGE_TYPE_2D,
                ._3d => vulkan.VK_IMAGE_TYPE_3D,
                .undefined_ => return error.TextureNativeUsageUnsupported,
            },
            .format = if (self.native_y_cb_cr) |*hardware|
                hardware.traits.vk_format
            else
                vulkan_format.vkFormat(self.getFormat(guard)),
            .extent = .{
                .width = self.base_size.width,
                .height = self.base_size.height,
                .depth = if (self.dimension == ._3d) self.base_size.depth_or_array_layers else 1,
            },
            .mipLevels = self.mip_level_count,
            .arrayLayers = self.getArrayLayers(guard),
            .samples = try vulkan_format.vkSampleCount(self.sample_count),
            .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
            .usage = usage,
            .sharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var internal_usage = self.internal_usage;
        var image_properties: ?vulkan.VkImageFormatProperties = null;
        if (self.native_y_cb_cr) |*hardware| {
            if (create_info.imageType != vulkan.VK_IMAGE_TYPE_2D or
                create_info.mipLevels != 1 or create_info.arrayLayers != 1 or
                create_info.samples != vulkan.VK_SAMPLE_COUNT_1_BIT or create_info.flags != 0 or
                create_info.usage !=
                    (vulkan.VK_IMAGE_USAGE_SAMPLED_BIT | vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT))
                return error.TextureYCbCrSamplerMismatch;
            try validateImageProperties(&create_info, hardware.image_properties);
            image_properties = hardware.image_properties;
        } else {
            internal_usage = try reserveHelperUsage(self, context, &create_info);
            if (context.physical_device != null)
                image_properties = try queryImageProperties(context, &create_info);
        }
        const native = try allocator.create(NativeTexture);
        errdefer allocator.destroy(native);
        const states = try allocator.alloc(NativeUsageState, self.subresourceCount(guard));
        errdefer allocator.free(states);
        @memset(states, .{
            .layout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
            .access = 0,
            .stages = vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        });
        var image: vulkan.VkImage = null;
        try dispatch.checkVkOomThenSuccess(create_image(context.vk_device, &create_info, null, &image));
        if (image == null) return error.TextureNativeCreationReturnedNull;
        errdefer destroy_image(context.vk_device, image, null);
        // SAFETY: the checked vkGetImageMemoryRequirements entry point writes the whole output struct and returns void.
        // The image was created successfully above. No requirements field is read before the call returns.
        var requirements: vulkan.VkMemoryRequirements = undefined;
        requirements_fn(context.vk_device, image, &requirements);
        if (image_properties) |properties| {
            if (requirements.size > properties.maxResourceSize)
                return error.TextureNativeRangeInvalid;
        }
        var memory_type: ?u32 = null;
        for (0..context.memory_properties.memoryTypeCount) |index| {
            if (requirements.memoryTypeBits & (@as(u32, 1) << @intCast(index)) == 0) continue;
            memory_type = @intCast(index);
            if (context.memory_properties.memoryTypes[index].propertyFlags &
                vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0) break;
        }
        const allocation_info: vulkan.VkMemoryAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type orelse return error.TextureNativeMemoryUnavailable,
        };
        var memory: vulkan.VkDeviceMemory = null;
        try dispatch.checkVkOomThenSuccess(
            allocate_memory(context.vk_device, &allocation_info, null, &memory),
        );
        if (memory == null) return error.TextureNativeCreationReturnedNull;
        errdefer free_memory(context.vk_device, memory, null);
        try dispatch.checkVkSuccess(bind_memory(context.vk_device, image, memory, 0));
        native.* = .{
            .allocator = allocator,
            .context = context,
            .procs = procs,
            .image = image,
            .memory = memory,
            .states = states,
        };
        context.handles.acquire(.image);
        context.handles.acquire(.memory);
        self.internal_usage = internal_usage;
        self.native = native;
    }

    /// Creates one private sampled-color owner with actual physical plane storage.
    pub fn createInternalYCbCr(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const object.ObjectGuard,
        arena: *object.ObjectArena,
        context: buffer_mod.Device,
        descriptor: InternalYCbCrDescriptor,
    ) NativeCreateError!*Texture {
        try arena.checkAllocator(guard, allocator);
        if (arena.objectList().marked_destroyed) return error.ResourceDestroyed;
        const payload = try validateConversionSampler(
            guard,
            arena.objectList(),
            context,
            descriptor.conversion_sampler,
        );
        try payload.backend.validateForTiling(
            descriptor.conversion_sampler.key,
            vulkan.VK_IMAGE_TILING_OPTIMAL,
        );
        const vk_format = std.math.cast(
            vulkan.VkFormat,
            descriptor.conversion_sampler.key.y_cb_cr.?.vk_format,
        ) orelse return error.TextureYCbCrFormatInvalid;
        const traits = try native_y_cb_cr_format.traitsFor(vk_format);
        for (0..traits.plane_count) |plane_index| {
            _ = try native_y_cb_cr_format.planeGeometry(vk_format, .{
                .width = descriptor.size.width,
                .height = descriptor.size.height,
                .plane_index = @intCast(plane_index),
            });
        }
        const query_info: vulkan.VkPhysicalDeviceImageFormatInfo2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
            .format = vk_format,
            .type = vulkan.VK_IMAGE_TYPE_2D,
            .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
            .usage = vulkan.VK_IMAGE_USAGE_SAMPLED_BIT | vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .flags = 0,
        };
        const descriptor_count = try payload.backend.combinedImageSamplerDescriptorCount(&query_info);
        const query = payload.backend.instance_procs.get_physical_device_image_format_properties2 orelse
            return error.MissingInstanceProc;
        var properties: vulkan.VkImageFormatProperties2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        };
        try dispatch.checkVkSuccess(query(payload.backend.physical, &query_info, &properties));
        const image_info: vulkan.VkImageCreateInfo = .{
            .imageType = vulkan.VK_IMAGE_TYPE_2D,
            .format = vk_format,
            .extent = .{
                .width = descriptor.size.width,
                .height = descriptor.size.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vulkan.VK_SAMPLE_COUNT_1_BIT,
        };
        try validateImageProperties(&image_info, properties.imageFormatProperties);
        const texture = try arena.create(allocator, guard, Texture, .{
            .kind = .texture,
            .state = .initializing,
            .label = descriptor.label,
            .initial_reference = .user,
        });
        errdefer texture.header.discardUnpublishedLocked(guard) catch
            @panic("hardware texture creator reference escaped before publication");
        const header = texture.header;
        texture.* = .{
            .header = header,
            .format_info = undefined,
            .dimension = ._2d,
            .binding_view_dimension = ._2d,
            .base_size = .{
                .width = descriptor.size.width,
                .height = descriptor.size.height,
                .depth_or_array_layers = 1,
            },
            .mip_level_count = 1,
            .sample_count = 1,
            .usage = .{ .texture_binding = true },
            .internal_usage = .{ .texture_binding = true, .copy_dst = true },
            .view_formats = &.{},
            .compatibility_mode = false,
            .bytes = &.{},
            .subresource_offsets = &.{},
            .initialized = &.{},
            .native_y_cb_cr = .{
                .traits = traits,
                .combined_image_sampler_descriptor_count = descriptor_count,
                .image_properties = properties.imageFormatProperties,
            },
        };
        texture.format_info = &texture.native_y_cb_cr.?.converted_format_info;
        texture.initialized = try arena.allocator(guard).alloc(bool, 1);
        errdefer arena.allocator(guard).free(texture.initialized);
        texture.initialized[0] = false;
        texture.header.setInitializedNoError(guard);
        try texture.initializeNative(allocator, guard, context);
        texture.header.attach(guard, io);
        return texture;
    }

    pub fn getNativeFormat(
        self: *const Texture,
        guard: *const object.ObjectGuard,
    ) NativeError!vulkan.VkFormat {
        _ = try self.getHandle(guard);
        return if (self.native_y_cb_cr) |*hardware|
            hardware.traits.vk_format
        else
            vulkan_format.vkFormat(self.getFormat(guard));
    }

    pub fn getCombinedImageSamplerDescriptorCount(
        self: *const Texture,
        guard: *const object.ObjectGuard,
    ) NativeError!u32 {
        _ = try self.getHandle(guard);
        const hardware = if (self.native_y_cb_cr) |*value| value else return error.TextureYCbCrSamplerMismatch;
        return hardware.combined_image_sampler_descriptor_count;
    }

    fn yCbCrCopyRegions(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        source_size: u64,
        plane_offsets: [3]u64,
    ) NativeError!struct { regions: [3]vulkan.VkBufferImageCopy, count: u32 } {
        guard.assertOwns(self.header.tracking);
        const hardware = if (self.native_y_cb_cr) |*value| value else return error.TextureYCbCrSamplerMismatch;
        var regions: [3]vulkan.VkBufferImageCopy = @splat(.{});
        for (0..hardware.traits.plane_count) |plane_index| {
            const plane = try native_y_cb_cr_format.planeGeometry(hardware.traits.vk_format, .{
                .width = self.base_size.width,
                .height = self.base_size.height,
                .plane_index = @intCast(plane_index),
            });
            const offset = plane_offsets[plane_index];
            if (offset % plane.element_bytes != 0 or
                offset > source_size or plane.byte_size > source_size - offset)
                return error.TextureNativeRangeInvalid;
            regions[plane_index] = .{
                .bufferOffset = offset,
                .imageSubresource = .{
                    .aspectMask = plane.aspect,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
                .imageExtent = .{ .width = plane.width, .height = plane.height, .depth = 1 },
            };
        }
        return .{ .regions = regions, .count = hardware.traits.plane_count };
    }

    pub fn uploadYCbCrPlanes(
        self: *Texture,
        guard: *const object.ObjectGuard,
        recording: buffer_mod.Recording,
        source: *buffer_mod.Buffer,
        plane_offsets: [3]u64,
    ) InitializationError!void {
        const native = try self.validateNativeRange(guard, self.getAllSubresources(guard));
        if (recording.command_buffer == null) return error.TextureNativeRangeInvalid;
        if (source.device.vk_device != native.context.vk_device or
            source.device.handles != native.context.handles or
            source.device.physical_device != native.context.physical_device)
            return error.TextureNativeDeviceMismatch;
        if (!source.usage.copy_src and
            source.internal_usage & (buffer_mod.internal_copy_src_buffer |
                (bitmask.BufferUsage{ .copy_src = true }).toFlags()) == 0)
            return error.BufferUsageMissingCopySrc;
        const copies = try self.yCbCrCopyRegions(guard, source.size, plane_offsets);
        const copy = native.procs.cmd_copy_buffer_to_image orelse return error.MissingDeviceProc;
        if (native.procs.cmd_pipeline_barrier == null) return error.MissingDeviceProc;
        const source_procs = source.device.dispatch.device orelse return error.MissingDeviceProc;
        if (source_procs.cmd_pipeline_barrier == null or
            (source.needsInitialization() and source_procs.cmd_fill_buffer == null))
            return error.MissingDeviceProc;
        try source.validateCanUseOnQueueNow();
        defer source.finishUse();
        if (source.needsInitialization())
            try source.ensureDataInitializedAsDestination(recording, 0, 0);
        try source.transitionUsageNow(
            recording,
            (bitmask.BufferUsage{ .copy_src = true }).toFlags(),
            .none,
        );
        try self.transition(
            guard,
            recording,
            self.getAllSubresources(guard),
            .{ .copy_dst = true },
            .none,
        );
        copy(
            recording.command_buffer,
            source.getHandle(),
            native.image,
            vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            copies.count,
            &copies.regions,
        );
        self.setSubresourceContentInitialized(guard, true, self.getAllSubresources(guard));
    }

    fn initializeYCbCrPlanes(
        self: *Texture,
        guard: *const object.ObjectGuard,
        queue: *queue_mod.Queue,
        recording: buffer_mod.Recording,
    ) InitializationError!void {
        const native = try self.validateNativeRange(guard, self.getAllSubresources(guard));
        if (queue.context.vk_device != native.context.vk_device or
            queue.context.handles != native.context.handles)
            return error.TextureNativeDeviceMismatch;
        if (native.procs.cmd_copy_buffer_to_image == null or
            native.procs.cmd_pipeline_barrier == null)
            return error.MissingDeviceProc;
        const hardware = &self.native_y_cb_cr.?;
        var offsets: [3]u64 = @splat(0);
        var byte_count: u64 = 0;
        for (0..hardware.traits.plane_count) |plane_index| {
            const plane = try native_y_cb_cr_format.planeGeometry(hardware.traits.vk_format, .{
                .width = self.base_size.width,
                .height = self.base_size.height,
                .plane_index = @intCast(plane_index),
            });
            const alignment: u64 = @max(4, plane.element_bytes);
            byte_count = std.math.add(u64, byte_count, alignment - 1) catch
                return error.TextureYCbCrSizeOverflow;
            byte_count = @divFloor(byte_count, alignment) * alignment;
            offsets[plane_index] = byte_count;
            byte_count = std.math.add(u64, byte_count, plane.byte_size) catch
                return error.TextureYCbCrSizeOverflow;
        }
        byte_count = std.math.add(u64, byte_count, 3) catch
            return error.TextureYCbCrSizeOverflow;
        byte_count &= ~@as(u64, 3);
        const staging = try queue.createTemporaryBuffer(queue.context.allocator, native.context, .{
            .usage = .{ .copy_src = true, .map_write = true },
            .size = byte_count,
            .mapped_at_creation = true,
        });
        std.debug.assert(staging.staging == null);
        const unmap_result = try staging.unmap(recording);
        std.debug.assert(unmap_result.staging_upload == null);
        try self.uploadYCbCrPlanes(guard, recording, staging, offsets);
    }

    pub fn sampledLayout(self: *const Texture, guard: *const object.ObjectGuard) vulkan.VkImageLayout {
        guard.assertOwns(self.header.tracking);
        if (self.format_info.hasDepthOrStencil())
            return vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
        if (self.internal_usage.storage_binding) return vulkan.VK_IMAGE_LAYOUT_GENERAL;
        return vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }

    pub fn getHandle(self: *const Texture, guard: *const object.ObjectGuard) NativeError!vulkan.VkImage {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        const native = self.native orelse return error.TextureNativeNotInitialized;
        if (native.destroy_requested) return error.TextureNativeDestroyed;
        if (native.image == null) return error.TextureNativeNotInitialized;
        return native.image;
    }

    /// Return the image owner's allocator, which stays alive through native
    /// view teardown. Recording scratch allocators do not own cached views.
    pub fn getNativeAllocator(self: *const Texture, guard: *const object.ObjectGuard) NativeError!std.mem.Allocator {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        if (self.header.state == .destroyed) return error.TextureNativeDestroyed;
        const native = self.native orelse return error.TextureNativeNotInitialized;
        if (native.destroy_requested) return error.TextureNativeDestroyed;
        return native.allocator;
    }

    /// Transition native storage; frontend-only textures return
    /// `TextureNativeNotInitialized` without recording a barrier.
    pub fn transition(
        self: *Texture,
        guard: *const object.ObjectGuard,
        recording: buffer_mod.Recording,
        range: SubresourceRange,
        usage: bitmask.TextureUsage,
        shader_stage: buffer_mod.ShaderStage,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        var next = try nativeUsageState(usage, shader_stage, self.format_info.hasDepthOrStencil());
        if (usage.texture_binding and !usage.storage_binding) next.layout = self.sampledLayout(guard);
        const native = try self.validateNativeRange(guard, range);
        try self.transitionState(guard, native, recording, range, next, null, false);
    }

    /// Validate one logical scope entry without changing native state. Scope
    /// coalescing must not let a valid peer hide an invalid aspect or usage.
    pub fn validateSyncScopeUsage(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        range: SubresourceRange,
        usage: bitmask.TextureUsage,
        shader_stage: buffer_mod.ShaderStage,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        _ = try self.validateNativeRange(guard, range);
        _ = try nativeUsageState(usage, shader_stage, self.format_info.hasDepthOrStencil());
    }

    pub fn transitionInto(
        self: *Texture,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        range: SubresourceRange,
        usage: bitmask.TextureUsage,
        shader_stage: buffer_mod.ShaderStage,
        batch: *BarrierBatch,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        const native = try self.validateNativeRange(guard, range);
        var next = try nativeUsageState(usage, shader_stage, self.format_info.hasDepthOrStencil());
        if (usage.texture_binding and !usage.storage_binding) next.layout = self.sampledLayout(guard);
        const count = @as(usize, range.level_count) * range.layer_count *
            @popCount(range.aspects.toFlags());
        try batch.image_barriers.ensureUnusedCapacity(allocator, count);
        try self.transitionState(guard, native, null, range, next, batch, false);
    }

    /// Select the attachment layout and synchronize every permitted use. A
    /// readonly depth/stencil aspect retains its prior sampled shader-read
    /// scope in both the emitted barrier and the tracked physical state.
    pub fn transitionRenderAttachment(
        self: *Texture,
        guard: *const object.ObjectGuard,
        recording: buffer_mod.Recording,
        range: SubresourceRange,
        options: AttachmentOptions,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        var next = try nativeUsageState(.{ .render_attachment = true }, .none, self.format_info.hasDepthOrStencil());
        if (self.format_info.hasDepthOrStencil()) {
            next.layout = vulkan_format.vkImageLayoutForDepthStencilAttachment(.{
                .has_depth = self.format_info.hasDepth(),
                .has_stencil = self.format_info.hasStencil(),
                .depth_read_only = options.depth_read_only,
                .stencil_read_only = options.stencil_read_only,
            });
            if ((!self.format_info.hasDepth() or options.depth_read_only) and
                (!self.format_info.hasStencil() or options.stencil_read_only))
                next.access &= ~@as(u32, vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT);
        }
        const preserve_sampled = (range.aspects.depth != 0 and options.depth_read_only) or
            (range.aspects.stencil != 0 and options.stencil_read_only);
        const native = try self.validateNativeRange(guard, range);
        try self.transitionState(guard, native, recording, range, next, null, preserve_sampled);
    }

    /// Borrow the existing native owner only after lifecycle and range checks.
    fn validateNativeRange(self: *const Texture, guard: *const object.ObjectGuard, range: SubresourceRange) NativeError!*NativeTexture {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        const native = self.native orelse return error.TextureNativeNotInitialized;
        if (native.destroy_requested) return error.TextureNativeDestroyed;
        if (native.image == null) return error.TextureNativeNotInitialized;
        if (range.level_count == 0 or range.layer_count == 0 or
            range.base_mip_level >= self.mip_level_count or
            range.level_count > self.mip_level_count - range.base_mip_level or
            range.base_array_layer >= self.getArrayLayers(guard) or
            range.layer_count > self.getArrayLayers(guard) - range.base_array_layer or
            range.aspects.toFlags() == 0 or !self.getAspects(guard).has(range.aspects))
            return error.TextureNativeRangeInvalid;
        return native;
    }

    fn transitionState(
        self: *Texture,
        guard: *const object.ObjectGuard,
        native: *NativeTexture,
        recording: ?buffer_mod.Recording,
        range: SubresourceRange,
        next: NativeUsageState,
        batch: ?*BarrierBatch,
        preserve_sampled: bool,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        const barrier_fn = native.procs.cmd_pipeline_barrier orelse return error.MissingDeviceProc;
        var aspect_flags = range.aspects.toFlags();
        while (aspect_flags != 0) : (aspect_flags &= aspect_flags - 1) {
            const aspect = firstAspect(aspect_flags);
            const coupled = self.format_info.hasDepth() and self.format_info.hasStencil();
            if (coupled and aspect == .stencil and range.aspects.depth != 0) continue;
            const state_aspect: Aspect = if (coupled) .depth else aspect;
            for (range.base_array_layer..range.base_array_layer + range.layer_count) |layer| {
                for (range.base_mip_level..range.base_mip_level + range.level_count) |level| {
                    const index = self.subresourceIndex(guard, @intCast(level), @intCast(layer), state_aspect);
                    const previous = native.states[index];
                    var destination = next;
                    if (preserve_sampled and previous.access & vulkan.VK_ACCESS_SHADER_READ_BIT != 0) {
                        // A readonly attachment aspect can still be sampled.
                        // Its layout transition must finish before those shader
                        // reads, not only before the attachment tests. Coupled
                        // state stores a conservative union for both aspects.
                        destination.access |= vulkan.VK_ACCESS_SHADER_READ_BIT;
                        destination.stages |= previous.stages & (vulkan.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT |
                            vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
                    }
                    const write_mask = vulkan.VK_ACCESS_TRANSFER_WRITE_BIT |
                        vulkan.VK_ACCESS_SHADER_WRITE_BIT | vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                        vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
                    if (std.meta.eql(previous, destination) and previous.access & write_mask == 0) continue;
                    const barrier: vulkan.VkImageMemoryBarrier = .{
                        .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                        .srcAccessMask = previous.access,
                        .dstAccessMask = destination.access,
                        .oldLayout = previous.layout,
                        .newLayout = destination.layout,
                        .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
                        .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
                        .image = native.image,
                        .subresourceRange = .{
                            .aspectMask = nativeAspectMask(if (coupled)
                                .{ .depth = 1, .stencil = 1 }
                            else
                                aspectMaskOf(aspect)),
                            .baseMipLevel = @intCast(level),
                            .levelCount = 1,
                            .baseArrayLayer = @intCast(layer),
                            .layerCount = 1,
                        },
                    };
                    if (batch) |pending| {
                        pending.image_barriers.appendAssumeCapacity(barrier);
                        pending.source_stages |= previous.stages;
                        pending.destination_stages |= destination.stages;
                    } else {
                        barrier_fn(
                            recording.?.command_buffer,
                            previous.stages,
                            destination.stages,
                            0,
                            0,
                            null,
                            0,
                            null,
                            1,
                            &barrier,
                        );
                    }
                    native.states[index] = destination;
                    if (coupled) {
                        native.states[
                            self.subresourceIndex(
                                guard,
                                @intCast(level),
                                @intCast(layer),
                                .stencil,
                            )
                        ] = destination;
                    }
                }
            }
        }
    }

    pub fn ensureSubresourceContentInitialized(
        self: *Texture,
        guard: *const object.ObjectGuard,
        queue: *queue_mod.Queue,
        recording: buffer_mod.Recording,
        range: SubresourceRange,
    ) InitializationError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        const native = self.native orelse return error.TextureNativeNotInitialized;
        if (native.destroy_requested) return error.TextureNativeDestroyed;
        if (range.base_mip_level >= self.mip_level_count or
            range.level_count == 0 or range.level_count > self.mip_level_count - range.base_mip_level or
            range.base_array_layer >= self.getArrayLayers(guard) or
            range.layer_count == 0 or range.layer_count > self.getArrayLayers(guard) - range.base_array_layer or
            range.aspects.toFlags() == 0 or !self.getAspects(guard).has(range.aspects))
            return error.TextureNativeRangeInvalid;
        if (self.isSubresourceContentInitialized(guard, range)) return;
        if (self.native_y_cb_cr != null) {
            try self.initializeYCbCrPlanes(guard, queue, recording);
            return;
        }
        if (self.format_info.is_compressed) {
            try self.initializeCompressedSubresources(queue.context.allocator, guard, queue, recording, range);
            return;
        }
        const clear_color = native.procs.cmd_clear_color_image orelse return error.MissingDeviceProc;
        const clear_depth = native.procs.cmd_clear_depth_stencil_image orelse
            return error.MissingDeviceProc;
        var aspect_flags = range.aspects.toFlags();
        while (aspect_flags != 0) : (aspect_flags &= aspect_flags - 1) {
            const aspect = firstAspect(aspect_flags);
            for (range.base_array_layer..range.base_array_layer + range.layer_count) |layer| {
                for (range.base_mip_level..range.base_mip_level + range.level_count) |level| {
                    const single: SubresourceRange = .{
                        .aspects = aspectMaskOf(aspect),
                        .base_array_layer = @intCast(layer),
                        .layer_count = 1,
                        .base_mip_level = @intCast(level),
                        .level_count = 1,
                    };
                    if (self.isSubresourceContentInitialized(guard, single)) continue;
                    try self.transition(guard, recording, single, .{ .copy_dst = true }, .none);
                    const vk_range: vulkan.VkImageSubresourceRange = .{
                        .aspectMask = nativeAspectMask(single.aspects),
                        .baseMipLevel = @intCast(level),
                        .levelCount = 1,
                        .baseArrayLayer = @intCast(layer),
                        .layerCount = 1,
                    };
                    if (aspect == .color) {
                        const clear: vulkan.VkClearColorValue = .{ .uint32 = @splat(0) };
                        clear_color(
                            recording.command_buffer,
                            native.image,
                            vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            &clear,
                            1,
                            &vk_range,
                        );
                    } else {
                        const clear: vulkan.VkClearDepthStencilValue = .{ .depth = 0, .stencil = 0 };
                        clear_depth(
                            recording.command_buffer,
                            native.image,
                            vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            &clear,
                            1,
                            &vk_range,
                        );
                    }
                    self.setSubresourceContentInitialized(guard, true, single);
                }
            }
        }
    }

    /// `allocator` is the queue owner allocator, never recording scratch:
    /// staging remains retained after recording storage is released.
    fn initializeCompressedSubresources(
        self: *Texture,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        queue: *queue_mod.Queue,
        recording: buffer_mod.Recording,
        range: SubresourceRange,
    ) InitializationError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        const native = self.native.?;
        const copy_to_image = native.procs.cmd_copy_buffer_to_image orelse
            return error.MissingDeviceProc;
        const block = self.aspectBlock(guard, .color);
        const largest = self.getMipLevelSingleSubresourcePhysicalSize(guard, range.base_mip_level);
        var byte_count = std.math.mul(
            u64,
            @divExact(largest.width, block.width),
            @divExact(largest.height, block.height),
        ) catch return error.TextureNativeAllocationOverflow;
        byte_count = std.math.mul(u64, byte_count, block.byte_size) catch
            return error.TextureNativeAllocationOverflow;
        byte_count = std.math.mul(u64, byte_count, largest.depth_or_array_layers) catch
            return error.TextureNativeAllocationOverflow;
        // Mapped-at-creation buffers zero their complete allocation. Queue owns
        // this staging resource until its submission serial has completed.
        const staging = try queue.createTemporaryBuffer(allocator, native.context, .{
            .usage = .{ .copy_src = true, .map_write = true },
            .size = byte_count,
            .mapped_at_creation = true,
        });
        std.debug.assert(staging.staging == null);
        const unmap_result = try staging.unmap(recording);
        std.debug.assert(unmap_result.staging_upload == null);
        try staging.transitionUsageNow(recording, (bitmask.BufferUsage{ .copy_src = true }).toFlags(), .none);
        for (range.base_mip_level..range.base_mip_level + range.level_count) |level| {
            const extent = self.getMipLevelSingleSubresourceVirtualSize(guard, @intCast(level));
            for (range.base_array_layer..range.base_array_layer + range.layer_count) |layer| {
                const single: SubresourceRange = .{
                    .aspects = range.aspects,
                    .base_mip_level = @intCast(level),
                    .level_count = 1,
                    .base_array_layer = @intCast(layer),
                    .layer_count = 1,
                };
                if (self.isSubresourceContentInitialized(guard, single)) continue;
                try self.transition(guard, recording, single, .{ .copy_dst = true }, .none);
                const region: vulkan.VkBufferImageCopy = .{
                    .bufferOffset = 0,
                    .bufferRowLength = 0,
                    .bufferImageHeight = 0,
                    .imageSubresource = .{
                        .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                        .mipLevel = @intCast(level),
                        .baseArrayLayer = @intCast(layer),
                        .layerCount = 1,
                    },
                    .imageExtent = .{
                        .width = extent.width,
                        .height = extent.height,
                        .depth = extent.depth_or_array_layers,
                    },
                };
                copy_to_image(
                    recording.command_buffer,
                    staging.getHandle(),
                    native.image,
                    vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    1,
                    &region,
                );
                self.setSubresourceContentInitialized(guard, true, single);
            }
        }
    }

    /// Creates one owned user alias under the device's object guard.
    /// Invalid descriptors and allocation failures leave no creator reference.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        guard: *const object.ObjectGuard,
        dev: *device.Device,
        options: Options,
    ) CreateError!objects.Texture {
        try dev.arena.checkAllocator(guard, gpa);
        const requested = options.descriptor.view_formats orelse &.{};
        if (requested.len != options.descriptor.view_format_count) {
            return error.TextureViewFormatNotInList;
        }

        try validateTextureDescriptor(options);
        const texture = try dev.create(gpa, guard, Texture, .{
            .kind = .texture,
            .state = .initializing,
            .label = options.descriptor.label orelse "",
            .initial_reference = .user,
        });
        errdefer texture.header.discardUnpublishedLocked(guard) catch
            @panic("texture creator reference escaped before publication");
        texture.native = null;
        texture.native_y_cb_cr = null;
        const arena = dev.arena.allocator(guard);

        // Every field is written before the store is sized, because the store's
        // shape is derived from them.
        texture.format_info = options.format_info;
        texture.dimension = options.descriptor.dimension;
        // The chain slot holds the extension struct, and the rule wants the
        // enum inside it, so the optional is unwrapped here the same way the
        // swizzle slot is at `resolveViewDescriptorUnchecked`.
        texture.binding_view_dimension = resolveBindingViewDimension(
            options.compatibility_mode,
            options.descriptor.dimension,
            options.descriptor.size.depth_or_array_layers,
            if (options.descriptor.texture_binding_view_dimension) |binding|
                binding.texture_binding_view_dimension
            else
                null,
        );
        texture.base_size = options.descriptor.size;
        texture.mip_level_count = options.descriptor.mip_level_count;
        texture.sample_count = options.descriptor.sample_count;
        texture.usage = options.descriptor.usage;
        texture.internal_usage = adjustInternalUsages(options.format_info, options.descriptor.usage);
        texture.compatibility_mode = options.compatibility_mode;
        texture.view_formats = try arena.dupe(enums.TextureFormat, requested);
        errdefer arena.free(texture.view_formats);
        texture.bytes = &.{};
        texture.subresource_offsets = &.{};
        texture.initialized = &.{};

        const subresource_count = texture.subresourceCount(guard);
        const offsets = try arena.alloc(usize, subresource_count + 1);
        errdefer arena.free(offsets);
        texture.subresource_offsets = offsets;
        var offset: usize = 0;
        var index: usize = 0;
        while (index < subresource_count) : (index += 1) {
            offsets[index] = offset;
            offset += texture.subresourceByteSizeOfIndex(guard, index);
        }
        offsets[subresource_count] = offset;

        texture.initialized = try arena.alloc(bool, subresource_count);
        errdefer arena.free(texture.initialized);
        @memset(texture.initialized, false);
        texture.bytes = try arena.alloc(u8, offset);
        @memset(texture.bytes, 0);

        texture.header.setInitializedNoError(guard);
        texture.header.attach(guard, io);
        const published = dev.handleFor(guard, Texture, texture, .texture);
        return .{ .handle = @ptrCast(published.ptr) };
    }

    /// Dawn's `GetDimension` (`Texture.cpp:1247`).
    pub fn getDimension(self: *const Texture, guard: *const object.ObjectGuard) enums.TextureDimension {
        guard.assertOwns(self.header.tracking);
        return self.dimension;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1257`), as the enum the caller named.
    /// The enum is kept beside the facts because the replay needs both: the
    /// replay wants the enum and the rules want the block size.
    pub fn getFormat(self: *const Texture, guard: *const object.ObjectGuard) enums.TextureFormat {
        guard.assertOwns(self.header.tracking);
        if (self.native_y_cb_cr != null) return .undefined_;
        // Creation rejects Dawn-only rows before any object can become alive.
        return canonical_format.toApiFormat(self.format_info.format) catch |err|
            std.debug.panic("Texture.getFormat: validated API format invariant failed: {s}", .{@errorName(err)});
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1257`).
    pub fn getFormatInfo(self: *const Texture, guard: *const object.ObjectGuard) *const canonical_format.Format {
        guard.assertOwns(self.header.tracking);
        return self.format_info;
    }

    pub fn getAspects(self: *const Texture, guard: *const object.ObjectGuard) AspectMask {
        guard.assertOwns(self.header.tracking);
        return formatAspects(self.format_info);
    }

    /// Requires one aspect present in this texture's validated canonical format.
    pub fn aspectBlock(self: *const Texture, guard: *const object.ObjectGuard, aspect: Aspect) canonical_format.TexelBlockInfo {
        guard.assertOwns(self.header.tracking);
        // Callers select one present aspect from the validated canonical row.
        // resolveCopy rejects user-selected missing or multiple aspects before this getter.
        return (self.format_info.getAspectInfoForAspect(
            @enumFromInt(@intFromEnum(aspect)),
        ) catch |err| std.debug.panic(
            "Texture.aspectBlock: validated single-aspect invariant failed: {s}",
            .{@errorName(err)},
        )).block;
    }

    /// Dawn's `GetCompatibilityTextureBindingViewDimension` (`:1252`).
    pub fn getBindingViewDimension(self: *const Texture, guard: *const object.ObjectGuard) enums.TextureViewDimension {
        guard.assertOwns(self.header.tracking);
        return self.binding_view_dimension;
    }

    /// Dawn's `GetBaseSize` (`Texture.cpp:1266`). For a multi-planar format this
    /// is the size of plane 0; the port rejects multi-planar creation at
    /// `Texture.cpp:830`, so no other plane ever has a size here.
    pub fn getBaseSize(self: *const Texture, guard: *const object.ObjectGuard) descriptors.Extent3D {
        guard.assertOwns(self.header.tracking);
        return self.base_size;
    }

    /// Dawn's `GetWidth` (`Texture.cpp:1316`) over `GetBaseSize`.
    pub fn getWidth(self: *const Texture, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.base_size.width;
    }

    /// Dawn's `GetHeight` (`Texture.cpp:1320`) over `GetBaseSize`.
    pub fn getHeight(self: *const Texture, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.base_size.height;
    }

    /// Dawn's `GetArrayLayers` (`Texture.cpp:1329`). A 3D texture has one layer
    /// however deep it is; the depth is a mip dimension instead.
    pub fn getArrayLayers(self: *const Texture, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        if (self.dimension == ._3d) return 1;
        return self.base_size.depth_or_array_layers;
    }

    /// Dawn's `GetNumMipLevels` (`Texture.cpp:1336`).
    pub fn getNumMipLevels(self: *const Texture, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.mip_level_count;
    }

    /// Dawn's `GetSampleCount` (`Texture.cpp:1344`).
    pub fn getSampleCount(self: *const Texture, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.sample_count;
    }

    /// Dawn's `GetSubresourceCount` (`Texture.cpp:1348`): one per mip level, per
    /// array layer, per aspect.
    pub fn subresourceCount(self: *const Texture, guard: *const object.ObjectGuard) usize {
        guard.assertOwns(self.header.tracking);
        const aspects = @popCount(@intFromEnum(self.format_info.aspects));
        return @as(usize, self.mip_level_count) *
            @as(usize, self.getArrayLayers(guard)) *
            @as(usize, aspects);
    }

    /// Dawn's `GetUsage` (`Texture.cpp:1352`): the usage the caller asked for,
    /// without the usages the engine adds for itself.
    pub fn getUsage(self: *const Texture, guard: *const object.ObjectGuard) bitmask.TextureUsage {
        guard.assertOwns(self.header.tracking);
        return self.usage;
    }

    /// Dawn's `GetInternalUsage` (`Texture.cpp:1356`). The port adds no usage a
    /// toggle does not ask for, so this differs from `getUsage` only in what
    /// `adjustInternalUsages` removes.
    pub fn getInternalUsage(self: *const Texture, guard: *const object.ObjectGuard) bitmask.TextureUsage {
        guard.assertOwns(self.header.tracking);
        return self.internal_usage;
    }

    /// Dawn's `GetAllSubresources` (`Texture.cpp:1340`).
    pub fn getAllSubresources(self: *const Texture, guard: *const object.ObjectGuard) SubresourceRange {
        guard.assertOwns(self.header.tracking);
        return .{
            .aspects = self.getAspects(guard),
            .base_array_layer = 0,
            .layer_count = self.getArrayLayers(guard),
            .base_mip_level = 0,
            .level_count = self.mip_level_count,
        };
    }

    /// Dawn's `IsMultisampledTexture` (`Texture.cpp:1475`).
    pub fn isMultisampledTexture(self: *const Texture, guard: *const object.ObjectGuard) bool {
        guard.assertOwns(self.header.tracking);
        return self.sample_count > 1;
    }

    /// Dawn's `GetAspectIndex` over the format's aspects, in the order
    /// `subresourceIndex` counts them (`Texture.cpp:1405`): the aspects in
    /// increasing bit order. An absent aspect answers one past the last present
    /// one, so two aspects cannot alias one subresource.
    pub fn aspectIndex(self: *const Texture, guard: *const object.ObjectGuard, aspect: Aspect) usize {
        guard.assertOwns(self.header.tracking);
        return aspectIndexIn(self.getAspects(guard), aspect);
    }

    /// Dawn's `GetSubresourceIndex` (`Texture.cpp:1405`): the mip level varies
    /// fastest, then the array layer, then the aspect.
    pub fn subresourceIndex(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
        array_layer: u32,
        aspect: Aspect,
    ) usize {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(aspect != .none);
        const level_stride: usize = self.mip_level_count;
        const layer_stride = level_stride * @as(usize, self.getArrayLayers(guard));
        return @as(usize, mip_level) +
            level_stride * @as(usize, array_layer) +
            layer_stride * self.aspectIndex(guard, aspect);
    }

    /// The byte offset of one subresource inside `bytes`.
    ///
    /// Dawn computes the same offset inside `TextureVk`, not in the front end;
    /// the front end needs it because the linear copy path at M11 is the front
    /// end's own store.
    pub fn subresourceByteOffset(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
        array_layer: u32,
        aspect: Aspect,
    ) usize {
        guard.assertOwns(self.header.tracking);
        return self.subresource_offsets[self.subresourceIndex(guard, mip_level, array_layer, aspect)];
    }

    /// The bytes one row of a level holds, which is the pitch of the store.
    pub fn levelRowByteSize(self: *const Texture, guard: *const object.ObjectGuard, mip_level: u32) usize {
        guard.assertOwns(self.header.tracking);
        const extent = self.getMipLevelSubresourcePhysicalSize(guard, mip_level);
        const block = primaryBlock(self.format_info);
        return @as(usize, @divExact(extent.width, block.width)) * block.byte_size;
    }

    /// The rows one level of the store holds.
    pub fn levelRowCount(self: *const Texture, guard: *const object.ObjectGuard, mip_level: u32) usize {
        guard.assertOwns(self.header.tracking);
        const extent = self.getMipLevelSubresourcePhysicalSize(guard, mip_level);
        return @divExact(extent.height, primaryBlock(self.format_info).height);
    }

    /// The bytes one image of a level holds: one array layer for a 2D texture
    /// and one depth slice for a 3D texture. Dawn counts the two the same way
    /// in `GetMipLevelSubresourcePhysicalSize` (`Texture.cpp:1559-1575`).
    pub fn imageByteSize(self: *const Texture, guard: *const object.ObjectGuard, mip_level: u32) usize {
        guard.assertOwns(self.header.tracking);
        return self.levelRowByteSize(guard, mip_level) * self.levelRowCount(guard, mip_level);
    }

    /// The bytes one subresource holds. For a 3D texture that is every depth
    /// slice; for a 2D texture it is one array layer, because an array layer is
    /// the subresource Dawn counts (`Texture.cpp:1116-1118`).
    pub fn subresourceByteSize(self: *const Texture, guard: *const object.ObjectGuard, mip_level: u32) usize {
        guard.assertOwns(self.header.tracking);
        if (self.dimension == ._3d) {
            const extent = self.getMipLevelSubresourcePhysicalSize(guard, mip_level);
            return self.imageByteSize(guard, mip_level) * extent.depth_or_array_layers;
        }
        return self.imageByteSize(guard, mip_level);
    }

    /// The bytes the subresource at `index` holds, which is what the offset
    /// table was built from.
    fn subresourceByteSizeOfIndex(self: *const Texture, guard: *const object.ObjectGuard, index: usize) usize {
        guard.assertOwns(self.header.tracking);
        const per_layer = @as(usize, self.mip_level_count) * @as(usize, self.getArrayLayers(guard));
        var remaining_aspects = self.getAspects(guard).toFlags();
        for (0..index / per_layer) |_| remaining_aspects &= remaining_aspects - 1;
        const block = self.aspectBlock(guard, firstAspect(remaining_aspects));
        const level: u32 = @intCast(index % self.mip_level_count);
        const extent = self.getMipLevelSubresourcePhysicalSize(guard, level);
        const image_byte_size = @as(usize, @divExact(extent.width, block.width)) *
            @divExact(extent.height, block.height) * block.byte_size;
        return image_byte_size * if (self.dimension == ._3d)
            @as(usize, extent.depth_or_array_layers)
        else
            1;
    }

    /// Dawn's `GetMipLevelSingleSubresourceVirtualSize` (`Texture.cpp:1501`):
    /// the size one subresource covers, without the block padding. Every
    /// dimension halves per level and stops at one.
    pub fn getMipLevelSingleSubresourceVirtualSize(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
    ) descriptors.Extent3D {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(mip_level < self.mip_level_count);
        const shift = levelShift(mip_level);
        return .{
            .width = @max(self.base_size.width >> shift, 1),
            .height = if (self.dimension == ._1d)
                1
            else
                @max(self.base_size.height >> shift, 1),
            .depth_or_array_layers = if (self.dimension == ._3d)
                @max(self.base_size.depth_or_array_layers >> shift, 1)
            else
                1,
        };
    }

    /// Dawn's `GetMipLevelSubresourceVirtualSize` (`Texture.cpp:1551`). The
    /// difference from the single-subresource size is the array layer count: a
    /// 2D texture's subresource holds every layer, and the layer count never
    /// halves with the mip level.
    pub fn getMipLevelSubresourceVirtualSize(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
    ) descriptors.Extent3D {
        guard.assertOwns(self.header.tracking);
        var extent = self.getMipLevelSingleSubresourceVirtualSize(guard, mip_level);
        if (self.dimension == ._2d) {
            extent.depth_or_array_layers = self.base_size.depth_or_array_layers;
        }
        return extent;
    }

    /// Dawn's `GetMipLevelSingleSubresourcePhysicalSize` (`Texture.cpp:1517`):
    /// the virtual size rounded up to whole blocks. A compressed format pads a
    /// level that is not a multiple of the block size.
    pub fn getMipLevelSingleSubresourcePhysicalSize(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
    ) descriptors.Extent3D {
        guard.assertOwns(self.header.tracking);
        if (self.native_y_cb_cr != null)
            return self.getMipLevelSingleSubresourceVirtualSize(guard, mip_level);
        return roundUpToBlocks(
            self.getMipLevelSingleSubresourceVirtualSize(guard, mip_level),
            self.format_info,
        );
    }

    /// Dawn's `GetMipLevelSubresourcePhysicalSize` (`Texture.cpp:1559`).
    pub fn getMipLevelSubresourcePhysicalSize(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
    ) descriptors.Extent3D {
        guard.assertOwns(self.header.tracking);
        if (self.native_y_cb_cr != null)
            return self.getMipLevelSubresourceVirtualSize(guard, mip_level);
        return roundUpToBlocks(self.getMipLevelSubresourceVirtualSize(guard, mip_level), self.format_info);
    }

    /// Dawn's `CoversFullSubresource` (`Texture.cpp:1484`), for a copy size in
    /// texels. Dawn compares against the physical size, because a copy of a
    /// compressed subresource names whole blocks.
    pub fn coversFullSubresource(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        mip_level: u32,
        size: descriptors.Extent3D,
    ) bool {
        guard.assertOwns(self.header.tracking);
        const level = self.getMipLevelSingleSubresourcePhysicalSize(guard, mip_level);
        return switch (self.dimension) {
            ._1d => size.width == level.width,
            ._2d => size.width == level.width and size.height == level.height,
            ._3d => size.width == level.width and
                size.height == level.height and
                size.depth_or_array_layers == level.depth_or_array_layers,
            .undefined_ => unreachable,
        };
    }

    /// Dawn's `IsSubresourceContentInitialized` (`Texture.cpp:1408`).
    pub fn isSubresourceContentInitialized(self: *const Texture, guard: *const object.ObjectGuard, range: SubresourceRange) bool {
        guard.assertOwns(self.header.tracking);
        var aspect_flags = range.aspects.toFlags();
        while (aspect_flags != 0) : (aspect_flags &= aspect_flags - 1) {
            const aspect = firstAspect(aspect_flags);
            var array_layer = range.base_array_layer;
            while (array_layer < range.base_array_layer + range.layer_count) : (array_layer += 1) {
                var mip_level = range.base_mip_level;
                while (mip_level < range.base_mip_level + range.level_count) : (mip_level += 1) {
                    const index = self.subresourceIndex(guard, mip_level, array_layer, aspect);
                    if (index >= self.initialized.len) return false;
                    if (!self.initialized[index]) return false;
                }
            }
        }
        return true;
    }

    /// Dawn's `SetIsSubresourceContentInitialized` (`Texture.cpp:1426`).
    pub fn setSubresourceContentInitialized(self: *Texture, guard: *const object.ObjectGuard, value: bool, range: SubresourceRange) void {
        guard.assertOwns(self.header.tracking);
        var aspect_flags = range.aspects.toFlags();
        while (aspect_flags != 0) : (aspect_flags &= aspect_flags - 1) {
            const aspect = firstAspect(aspect_flags);
            var array_layer = range.base_array_layer;
            while (array_layer < range.base_array_layer + range.layer_count) : (array_layer += 1) {
                var mip_level = range.base_mip_level;
                while (mip_level < range.base_mip_level + range.level_count) : (mip_level += 1) {
                    const index = self.subresourceIndex(guard, mip_level, array_layer, aspect);
                    if (index >= self.initialized.len) continue;
                    self.initialized[index] = value;
                }
            }
        }
    }

    /// Dawn's `CreateView` (`Texture.cpp:1577`) and `APICreateView` (`:1593`).
    /// Returns one user alias owning one internal parent lease until retirement.
    /// Failure leaves neither a creator reference nor an additional parent lease.
    pub fn createView(
        gpa: std.mem.Allocator,
        io: std.Io,
        guard: *const object.ObjectGuard,
        dev: *device.Device,
        parent: objects.Texture,
        options: ViewOptions,
    ) CreateError!objects.TextureView {
        try dev.arena.checkAllocator(guard, gpa);
        const texture = try resolveTexture(dev, guard, parent);
        try validateTextureViewDescriptor(texture, guard, options);
        const resolved = resolveViewDescriptorUnchecked(texture, guard, options.descriptor);
        const view = try dev.create(gpa, guard, TextureView, .{
            .kind = .texture_view,
            .state = .initializing,
            .label = options.descriptor.label orelse "",
            .initial_reference = .user,
        });
        errdefer view.header.discardUnpublishedLocked(guard) catch
            @panic("texture view creator reference escaped before publication");
        try texture.header.retainLeaseLocked(guard);
        errdefer texture.header.releaseLeaseLocked(guard, io);
        view.texture = texture;
        view.parent_lease_held = true;
        view.conversion_sampler = null;
        view.native_view = null;
        view.attachment_views = null;
        view.attachment_view_count = 0;

        view.format_info = options.format_info;
        view.format = resolved.format;
        view.dimension = resolved.dimension;
        view.aspects = selectFormatAspects(texture.format_info, resolved.aspect);
        view.range = .{
            .aspects = view.aspects,
            .base_array_layer = resolved.base_array_layer,
            .layer_count = resolved.array_layer_count,
            .base_mip_level = resolved.base_mip_level,
            .level_count = resolved.mip_level_count,
        };
        view.usage = resolveViewUsage(texture.usage, options.descriptor.usage);
        view.internal_usage = adjustViewInternalUsages(texture.format_info, view.usage, resolved.dimension);
        view.internal_usage = deriveViewInternalUsages(view);
        view.swizzle = resolved.swizzle;
        view.header.setInitializedNoError(guard);
        view.header.attach(guard, io);
        const published = dev.handleFor(guard, TextureView, view, .texture_view);
        return .{ .handle = @ptrCast(published.ptr) };
    }

    /// Whether a view of this texture may name `format`: the formats the caller
    /// listed at creation, which is Dawn's `FormatSet` (`Texture.h:298`).
    pub fn isViewFormatListed(self: *const Texture, guard: *const object.ObjectGuard, format: enums.TextureFormat) bool {
        guard.assertOwns(self.header.tracking);
        for (self.view_formats) |listed| {
            if (listed == format) return true;
        }
        return false;
    }

    /// Dawn's `WriteTexture` writes one subresource through the upload path. The
    /// port writes the linear store the front end owns, so the bytes are
    /// readable at once and no copy needs a device.
    ///
    /// The layout rules are `ValidateTexelCopyTextureInfo`
    /// (`CommandValidation.cpp:440`), `ValidateTexelCopyBufferInfo` (`:423`),
    /// `ValidateLinearTextureData` (`:366`) and `ComputeRequiredBytesInCopy`
    /// (`:295`), applied by `resolveCopy`.
    pub fn writeTexture(
        self: *Texture,
        guard: *const object.ObjectGuard,
        texture_copy: TexelCopyTextureInfo,
        texture_layout: TexelCopyTextureLayout,
        buffer_layout: TexelCopyBufferLayout,
        data: []const u8,
    ) CreateError!void {
        guard.assertOwns(self.header.tracking);
        if (!self.usage.has(.{ .copy_dst = true })) return error.TextureUsageMissingCopyDst;

        const copy = try resolveCopy(self, guard, texture_copy, texture_layout, buffer_layout, data.len);
        copyRows(self, guard, copy, data, true);
        self.setSubresourceContentInitialized(guard, true, .{
            .aspects = aspectMaskOf(copy.aspect),
            .base_array_layer = 0,
            .layer_count = self.getArrayLayers(guard),
            .base_mip_level = copy.mip_level,
            .level_count = 1,
        });
    }

    /// Dawn's `CopyTextureToBuffer` reads one subresource into a linear
    /// destination. The layout rules are the same three `writeTexture` names,
    /// read against `destination.len` instead of `data.len`.
    pub fn copyTextureToBuffer(
        self: *const Texture,
        guard: *const object.ObjectGuard,
        texture_copy: TexelCopyTextureInfo,
        texture_layout: TexelCopyTextureLayout,
        buffer_layout: TexelCopyBufferLayout,
        destination: []u8,
    ) CreateError!void {
        guard.assertOwns(self.header.tracking);
        if (!self.usage.has(.{ .copy_src = true })) return error.TextureUsageMissingCopySrc;

        const copy = try resolveCopy(self, guard, texture_copy, texture_layout, buffer_layout, destination.len);
        copyRows(self, guard, copy, destination, false);
    }

    /// GPU use must complete before teardown. Native views keep the image alive
    /// until their handles are released. The arena still owns the logical block
    /// and CPU store; only the native allocator releases its separate storage.
    //
    // The logical object belongs to ObjectArena, not the native allocator.
    // zbc-disable-next-line: heap-leak
    pub fn destroy(self: *Texture, guard: *const object.ObjectGuard, io: std.Io, reason: object.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = io;
        _ = reason;
        if (self.native) |native| {
            native.destroy_requested = true;
            if (native.view_count == 0) self.destroyNative(guard);
        }
        self.bytes = &.{};
        self.initialized = &.{};
        self.subresource_offsets = &.{};
        self.view_formats = &.{};
    }

    fn destroyNative(self: *Texture, guard: *const object.ObjectGuard) void {
        guard.assertOwns(self.header.tracking);
        const native = self.native orelse return;
        native.procs.destroy_image.?(native.context.vk_device, native.image, null);
        native.procs.free_memory.?(native.context.vk_device, native.memory, null);
        native.context.handles.release(.image);
        native.context.handles.release(.memory);
        native.allocator.free(native.states);
        const allocator = native.allocator;
        allocator.destroy(native);
        self.native = null;
    }
};

/// A texture view as the engine holds it: Dawn's `TextureViewBase`
/// (`src/dawn/native/Texture.h:341`), with the private fields public.
pub const TextureView = struct {
    header: object.Object,

    texture: *Texture,
    /// Exactly one internal parent lease, consumed by payload retirement.
    parent_lease_held: bool = false,
    /// The real conversion owner survives the native view.
    conversion_sampler: ?*sampler_mod.Sampler = null,
    format_info: *const canonical_format.Format,
    format: enums.TextureFormat,
    dimension: enums.TextureViewDimension,
    aspects: AspectMask,
    range: SubresourceRange,
    usage: bitmask.TextureUsage,
    internal_usage: bitmask.TextureUsage,
    swizzle: descriptors.TextureComponentSwizzle,
    native_view: vulkan.VkImageView = null,
    attachment_views: ?*AttachmentView = null,
    attachment_view_count: usize = 0,

    pub fn initializeNative(self: *TextureView, guard: *const object.ObjectGuard) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        guard.assertOwns(self.texture.header.tracking);
        if (self.texture.header.state != .alive) return error.TextureNativeDestroyed;
        if (self.native_view != null) return error.TextureNativeAlreadyInitialized;
        const native = self.texture.native orelse return error.TextureNativeNotInitialized;
        if (native.destroy_requested) return error.TextureNativeDestroyed;
        const create_view = native.procs.create_image_view orelse return error.MissingDeviceProc;
        if (native.procs.destroy_image_view == null) return error.MissingDeviceProc;
        if (native.view_count == std.math.maxInt(usize)) return error.ReferenceCountOverflow;
        const internal_usage = deriveViewInternalUsages(self);
        var conversion_info: vulkan.VkSamplerYcbcrConversionInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
        };
        var native_format = if (self.texture.native_y_cb_cr) |*hardware|
            hardware.traits.vk_format
        else
            vulkan_format.vkFormat(self.format);
        if (self.texture.native_y_cb_cr) |*hardware| {
            const conversion_sampler = self.conversion_sampler orelse
                return error.TextureYCbCrSamplerMismatch;
            const payload = try validateConversionSampler(
                guard,
                self.header.tracking,
                native.context,
                conversion_sampler,
            );
            try payload.backend.validateForTiling(
                conversion_sampler.key,
                vulkan.VK_IMAGE_TILING_OPTIMAL,
            );
            const selected_format = std.math.cast(
                vulkan.VkFormat,
                conversion_sampler.key.y_cb_cr.?.vk_format,
            ) orelse return error.TextureYCbCrSamplerMismatch;
            if (selected_format != hardware.traits.vk_format or self.dimension != ._2d or
                self.format != .undefined_ or
                self.aspects.toFlags() != (AspectMask{ .color = 1 }).toFlags() or
                self.range.aspects.toFlags() != self.aspects.toFlags() or
                self.range.base_mip_level != 0 or self.range.level_count != 1 or
                self.range.base_array_layer != 0 or self.range.layer_count != 1 or
                !self.isSwizzleIdentity(guard) or !internal_usage.texture_binding or
                internal_usage.storage_binding or internal_usage.render_attachment)
                return error.TextureYCbCrSamplerMismatch;
            conversion_info.conversion = payload.conversion;
            native_format = selected_format;
        } else if (self.conversion_sampler != null) {
            return error.TextureYCbCrSamplerMismatch;
        }
        self.attachment_views = null;
        self.attachment_view_count = 0;
        var usage: vulkan.VkImageUsageFlags = 0;
        if (internal_usage.texture_binding) usage |= vulkan.VK_IMAGE_USAGE_SAMPLED_BIT;
        if (internal_usage.storage_binding) usage |= vulkan.VK_IMAGE_USAGE_STORAGE_BIT;
        if (internal_usage.render_attachment) usage |= if (self.aspects.color != 0)
            @as(u32, vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
        else
            @as(u32, vulkan.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
        if (usage == 0) return error.TextureNativeUsageUnsupported;
        const usage_info: vulkan.VkImageViewUsageCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO,
            .pNext = if (conversion_info.conversion != null) &conversion_info else null,
            .usage = usage,
        };
        const info: vulkan.VkImageViewCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = &usage_info,
            .image = native.image,
            .viewType = switch (self.dimension) {
                ._1d => vulkan.VK_IMAGE_VIEW_TYPE_1D,
                ._2d => vulkan.VK_IMAGE_VIEW_TYPE_2D,
                ._2d_array => vulkan.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
                .cube => vulkan.VK_IMAGE_VIEW_TYPE_CUBE,
                .cube_array => vulkan.VK_IMAGE_VIEW_TYPE_CUBE_ARRAY,
                ._3d => vulkan.VK_IMAGE_VIEW_TYPE_3D,
                .undefined_ => return error.TextureNativeUsageUnsupported,
            },
            .format = native_format,
            .components = if (self.isSwizzleIdentity(guard)) .{} else .{
                .r = nativeSwizzle(self.swizzle.r),
                .g = nativeSwizzle(self.swizzle.g),
                .b = nativeSwizzle(self.swizzle.b),
                .a = nativeSwizzle(self.swizzle.a),
            },
            .subresourceRange = .{
                .aspectMask = nativeAspectMask(self.aspects),
                .baseMipLevel = self.range.base_mip_level,
                .levelCount = self.range.level_count,
                .baseArrayLayer = self.range.base_array_layer,
                .layerCount = self.range.layer_count,
            },
        };
        var view: vulkan.VkImageView = null;
        try dispatch.checkVkOomThenSuccess(
            create_view(native.context.vk_device, &info, null, &view),
        );
        if (view == null) return error.TextureNativeCreationReturnedNull;
        self.internal_usage = internal_usage;
        self.native_view = view;
        native.view_count += 1;
        native.context.handles.acquire(.image_view);
    }

    pub fn getHandle(self: *const TextureView, guard: *const object.ObjectGuard) NativeError!vulkan.VkImageView {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        if (self.texture.header.tracking != self.header.tracking)
            return error.TextureNativeDeviceMismatch;
        if (self.texture.header.state != .alive) return error.TextureNativeDestroyed;
        if (self.native_view == null) return error.TextureNativeNotInitialized;
        _ = try self.texture.getHandle(guard);
        return self.native_view;
    }

    /// Cache 3D slice views until this view is destroyed. The supplied allocator
    /// must cover that lifetime; callers use Texture.getNativeAllocator(), not
    /// recording scratch. Each cache node stores its owner for teardown.
    pub fn getAttachmentHandle(
        self: *TextureView,
        allocator: std.mem.Allocator,
        guard: *const object.ObjectGuard,
        depth_slice: u32,
    ) NativeError!vulkan.VkImageView {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive) return error.TextureNativeDestroyed;
        const primary = try self.getHandle(guard);
        if (!self.internal_usage.render_attachment or !self.isSwizzleIdentity(guard))
            return error.TextureNativeUsageUnsupported;
        if (self.dimension != ._3d) return primary;
        if (self.range.level_count != 1) return error.TextureNativeRangeInvalid;
        const extent = self.texture.getMipLevelSingleSubresourceVirtualSize(guard, self.range.base_mip_level);
        if (depth_slice >= extent.depth_or_array_layers) return error.TextureNativeRangeInvalid;
        var cursor = self.attachment_views;
        for (0..self.attachment_view_count) |_| {
            const entry = cursor.?;
            if (entry.depth_slice == depth_slice) return entry.handle;
            cursor = entry.next;
        }
        const native = self.texture.native orelse return error.TextureNativeNotInitialized;
        if (native.destroy_requested) return error.TextureNativeDestroyed;
        const create_view = native.procs.create_image_view orelse return error.MissingDeviceProc;
        const entry = try allocator.create(AttachmentView);
        errdefer allocator.destroy(entry);
        const usage_info: vulkan.VkImageViewUsageCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO,
            .usage = vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        };
        const info: vulkan.VkImageViewCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = &usage_info,
            .image = native.image,
            .viewType = vulkan.VK_IMAGE_VIEW_TYPE_2D,
            .format = vulkan_format.vkFormat(self.format),
            .subresourceRange = .{
                .aspectMask = nativeAspectMask(self.aspects),
                .baseMipLevel = self.range.base_mip_level,
                .levelCount = 1,
                .baseArrayLayer = depth_slice,
                .layerCount = 1,
            },
        };
        var view: vulkan.VkImageView = null;
        try dispatch.checkVkOomThenSuccess(
            create_view(native.context.vk_device, &info, null, &view),
        );
        entry.* = .{
            .allocator = allocator,
            .handle = view,
            .depth_slice = depth_slice,
            .next = self.attachment_views,
        };
        self.attachment_views = entry;
        self.attachment_view_count += 1;
        native.context.handles.acquire(.image_view);
        return view;
    }

    /// Dawn's `GetTexture` (`Texture.cpp:1857`).
    pub fn getTexture(self: *const TextureView, guard: *const object.ObjectGuard) *Texture {
        guard.assertOwns(self.header.tracking);
        return self.texture;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1867`).
    pub fn getFormat(self: *const TextureView, guard: *const object.ObjectGuard) enums.TextureFormat {
        guard.assertOwns(self.header.tracking);
        return self.format;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1867`).
    pub fn getFormatInfo(self: *const TextureView, guard: *const object.ObjectGuard) *const canonical_format.Format {
        guard.assertOwns(self.header.tracking);
        return self.format_info;
    }

    /// Dawn's `GetDimension` (`Texture.cpp:1872`).
    pub fn getDimension(self: *const TextureView, guard: *const object.ObjectGuard) enums.TextureViewDimension {
        guard.assertOwns(self.header.tracking);
        return self.dimension;
    }

    /// Dawn's `GetAspects` (`Texture.cpp:1862`).
    pub fn getAspects(self: *const TextureView, guard: *const object.ObjectGuard) AspectMask {
        guard.assertOwns(self.header.tracking);
        return self.aspects;
    }

    /// Dawn's `GetBaseMipLevel` (`Texture.cpp:1877`).
    pub fn getBaseMipLevel(self: *const TextureView, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.range.base_mip_level;
    }

    /// Dawn's `GetLevelCount` (`Texture.cpp:1882`).
    pub fn getLevelCount(self: *const TextureView, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.range.level_count;
    }

    /// Dawn's `GetBaseArrayLayer` (`Texture.cpp:1887`).
    pub fn getBaseArrayLayer(self: *const TextureView, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.range.base_array_layer;
    }

    /// Dawn's `GetLayerCount` (`Texture.cpp:1892`).
    pub fn getLayerCount(self: *const TextureView, guard: *const object.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.range.layer_count;
    }

    /// Dawn's `GetSubresourceRange` (`Texture.cpp:1897`).
    pub fn getSubresourceRange(self: *const TextureView, guard: *const object.ObjectGuard) SubresourceRange {
        guard.assertOwns(self.header.tracking);
        return self.range;
    }

    /// Dawn's `GetUsage` (`Texture.cpp:1907`).
    pub fn getUsage(self: *const TextureView, guard: *const object.ObjectGuard) bitmask.TextureUsage {
        guard.assertOwns(self.header.tracking);
        return self.usage;
    }

    /// Dawn's `GetInternalUsage` (`Texture.cpp:1912`).
    pub fn getInternalUsage(self: *const TextureView, guard: *const object.ObjectGuard) bitmask.TextureUsage {
        guard.assertOwns(self.header.tracking);
        return self.internal_usage;
    }

    /// Dawn's `GetSwizzle` (`Texture.cpp:1917`).
    pub fn getSwizzle(self: *const TextureView, guard: *const object.ObjectGuard) descriptors.TextureComponentSwizzle {
        guard.assertOwns(self.header.tracking);
        return self.swizzle;
    }

    /// Dawn's `IsSwizzleIdentity` (`Texture.cpp:1926`), as one comparison
    /// against the four identity components.
    pub fn isSwizzleIdentity(self: *const TextureView, guard: *const object.ObjectGuard) bool {
        guard.assertOwns(self.header.tracking);
        return std.meta.eql(self.swizzle, identitySwizzle());
    }

    /// Release native view handles before the texture reference. The caller
    /// waits for GPU use; the native image owner survives every remaining view.
    pub fn destroy(self: *TextureView, guard: *const object.ObjectGuard, io: std.Io, reason: object.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        if (self.native_view != null) {
            const native = self.texture.native.?;
            var cursor = self.attachment_views;
            for (0..self.attachment_view_count) |_| {
                const entry = cursor.?;
                cursor = entry.next;
                native.procs.destroy_image_view.?(native.context.vk_device, entry.handle, null);
                native.context.handles.release(.image_view);
                entry.allocator.destroy(entry);
            }
            self.attachment_views = null;
            self.attachment_view_count = 0;
            native.procs.destroy_image_view.?(native.context.vk_device, self.native_view, null);
            native.context.handles.release(.image_view);
            native.view_count -= 1;
            self.native_view = null;
            if (native.destroy_requested and native.view_count == 0) self.texture.destroyNative(guard);
        }
        if (self.conversion_sampler) |conversion_sampler| {
            self.conversion_sampler = null;
            conversion_sampler.header.releaseLeaseLocked(guard, io);
        }
        if (self.parent_lease_held) {
            self.parent_lease_held = false;
            self.texture.header.releaseLeaseLocked(guard, io);
        }
    }

    pub fn createInternalYCbCr(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const object.ObjectGuard,
        arena: *object.ObjectArena,
        parent: *Texture,
        conversion_sampler: *sampler_mod.Sampler,
    ) NativeCreateError!*TextureView {
        try arena.checkAllocator(guard, allocator);
        if (parent.header.tracking != arena.objectList()) return error.TextureNativeDeviceMismatch;
        const native = try parent.validateNativeRange(guard, parent.getAllSubresources(guard));
        const hardware = if (parent.native_y_cb_cr) |*value| value else return error.TextureYCbCrSamplerMismatch;
        _ = try validateConversionSampler(guard, arena.objectList(), native.context, conversion_sampler);
        const selected_format = std.math.cast(
            vulkan.VkFormat,
            conversion_sampler.key.y_cb_cr.?.vk_format,
        ) orelse return error.TextureYCbCrSamplerMismatch;
        if (selected_format != hardware.traits.vk_format)
            return error.TextureYCbCrSamplerMismatch;
        const view = try arena.create(allocator, guard, TextureView, .{
            .kind = .texture_view,
            .state = .initializing,
            .initial_reference = .user,
        });
        errdefer view.header.discardUnpublishedLocked(guard) catch
            @panic("hardware view creator reference escaped before publication");
        try parent.header.retainLeaseLocked(guard);
        errdefer parent.header.releaseLeaseLocked(guard, io);
        try conversion_sampler.header.retainLeaseLocked(guard);
        errdefer conversion_sampler.header.releaseLeaseLocked(guard, io);
        const header = view.header;
        view.* = .{
            .header = header,
            .texture = parent,
            .parent_lease_held = true,
            .format_info = parent.format_info,
            .format = .undefined_,
            .dimension = ._2d,
            .aspects = .{ .color = 1 },
            .range = parent.getAllSubresources(guard),
            .usage = .{ .texture_binding = true },
            .internal_usage = .{ .texture_binding = true },
            .swizzle = identitySwizzle(),
            .conversion_sampler = conversion_sampler,
        };
        view.header.setInitializedNoError(guard);
        try view.initializeNative(guard);
        view.header.attach(guard, io);
        return view;
    }

    /// Checks immutable selected metadata without another physical-format query.
    pub fn validateYCbCr(
        self: *const TextureView,
        guard: *const object.ObjectGuard,
        conversion_sampler: *sampler_mod.Sampler,
    ) NativeError!void {
        guard.assertOwns(self.header.tracking);
        if (self.header.state != .alive or !self.header.isAlive(guard))
            return error.TextureNativeDestroyed;
        if (self.texture.header.tracking != self.header.tracking)
            return error.TextureNativeDeviceMismatch;
        const native = try self.texture.validateNativeRange(guard, self.range);
        const hardware = if (self.texture.native_y_cb_cr) |*value| value else return error.TextureYCbCrSamplerMismatch;
        if (self.conversion_sampler != conversion_sampler or self.native_view == null or
            self.format != .undefined_ or self.format_info != self.texture.format_info or
            self.dimension != ._2d or self.texture.dimension != ._2d or
            self.texture.sample_count != 1 or
            self.aspects.toFlags() != (AspectMask{ .color = 1 }).toFlags() or
            self.range.aspects.toFlags() != self.aspects.toFlags() or
            self.range.base_mip_level != 0 or self.range.level_count != 1 or
            self.range.base_array_layer != 0 or self.range.layer_count != 1 or
            !self.isSwizzleIdentity(guard) or !self.internal_usage.texture_binding)
            return error.TextureYCbCrSamplerMismatch;
        _ = try validateConversionSampler(
            guard,
            self.header.tracking,
            native.context,
            conversion_sampler,
        );
        const vk_format = std.math.cast(
            vulkan.VkFormat,
            conversion_sampler.key.y_cb_cr.?.vk_format,
        ) orelse return error.TextureYCbCrSamplerMismatch;
        if (vk_format != hardware.traits.vk_format)
            return error.TextureYCbCrSamplerMismatch;
    }
};

pub fn nativeAspectMask(aspects: AspectMask) vulkan.VkImageAspectFlags {
    var flags: vulkan.VkImageAspectFlags = 0;
    if (aspects.color != 0) flags |= vulkan.VK_IMAGE_ASPECT_COLOR_BIT;
    if (aspects.depth != 0 or aspects.combined_depth_stencil != 0)
        flags |= vulkan.VK_IMAGE_ASPECT_DEPTH_BIT;
    if (aspects.stencil != 0 or aspects.combined_depth_stencil != 0)
        flags |= vulkan.VK_IMAGE_ASPECT_STENCIL_BIT;
    return flags;
}

fn nativeSwizzle(component: enums.ComponentSwizzle) vulkan.VkComponentSwizzle {
    return switch (component) {
        .r => vulkan.VK_COMPONENT_SWIZZLE_R,
        .g => vulkan.VK_COMPONENT_SWIZZLE_G,
        .b => vulkan.VK_COMPONENT_SWIZZLE_B,
        .a => vulkan.VK_COMPONENT_SWIZZLE_A,
        .zero => vulkan.VK_COMPONENT_SWIZZLE_ZERO,
        .one => vulkan.VK_COMPONENT_SWIZZLE_ONE,
        .undefined_ => vulkan.VK_COMPONENT_SWIZZLE_IDENTITY,
    };
}

fn nativeUsageState(
    usage: bitmask.TextureUsage,
    shader_stage: buffer_mod.ShaderStage,
    depth_stencil: bool,
) NativeError!NativeUsageState {
    if (usage.toFlags() == 0 or usage.storage_attachment or usage._padding != 0)
        return error.TextureNativeUsageUnsupported;
    var result: NativeUsageState = .{ .layout = vulkan.VK_IMAGE_LAYOUT_GENERAL, .access = 0, .stages = 0 };
    if (usage.copy_src) {
        result.access |= vulkan.VK_ACCESS_TRANSFER_READ_BIT;
        result.stages |= vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT;
    }
    if (usage.copy_dst) {
        result.access |= vulkan.VK_ACCESS_TRANSFER_WRITE_BIT;
        result.stages |= vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT;
    }
    if (usage.texture_binding or usage.storage_binding) {
        result.access |= vulkan.VK_ACCESS_SHADER_READ_BIT;
        if (usage.storage_binding) result.access |= vulkan.VK_ACCESS_SHADER_WRITE_BIT;
        if (shader_stage.vertex) result.stages |= vulkan.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT;
        if (shader_stage.fragment) result.stages |= vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        if (shader_stage.compute) result.stages |= vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
        if (shader_stage.toFlags() == 0) return error.TextureNativeUsageUnsupported;
    }
    if (usage.render_attachment) {
        if (depth_stencil) {
            result.access |= vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            result.stages |= vulkan.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
                vulkan.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        } else {
            result.access |= vulkan.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            result.stages |= vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        }
    }
    const flags = usage.toFlags() & ~@as(u32, 32);
    if (@popCount(flags) == 1) {
        if (usage.copy_src) result.layout = vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        if (usage.copy_dst) result.layout = vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        if (usage.texture_binding) result.layout = vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        if (usage.render_attachment) result.layout = if (depth_stencil)
            @as(vulkan.VkImageLayout, vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
        else
            @as(vulkan.VkImageLayout, vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    }
    if (result.stages == 0) return error.TextureNativeUsageUnsupported;
    return result;
}

/// The four components a swizzle that changes nothing names. Dawn calls it
/// `kRGBASwizzle` (`Texture.h:85`).
pub fn identitySwizzle() descriptors.TextureComponentSwizzle {
    return .{ .r = .r, .g = .g, .b = .b, .a = .a };
}

/// The texture the handle names, or the rule that rejects the handle.
///
/// **This is where the alignment comes back.** `src/api/objects.zig` is
/// generated and types every `handle` field `?*anyopaque`, so the guarantee
/// `core.Handle.ptr` carries is lost at the API boundary. It is asserted once
/// here, where the loss happens, rather than at every read of the handle. The
/// only writer of that field is `create`, which returns `@ptrCast` of an arena
/// object, so the assertion cannot fail for a handle this module produced.
pub fn resolveTexture(
    dev: *device.Device,
    guard: *const object.ObjectGuard,
    target: objects.Texture,
) device.HandleError!*Texture {
    const wrapped: handle.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .texture,
    };
    return dev.resolve(guard, Texture, wrapped);
}

/// The texture view the handle names, or the rule that rejects the handle.
///
/// The alignment assertion is `resolveTexture`'s, for the same reason.
pub fn resolveTextureView(
    dev: *device.Device,
    guard: *const object.ObjectGuard,
    target: objects.TextureView,
) device.HandleError!*TextureView {
    const wrapped: handle.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .texture_view,
    };
    return dev.resolve(guard, TextureView, wrapped);
}

/// Dawn's `SelectFormatAspects` (`src/dawn/native/Subresource.h:72`). The public
/// aspect selects a mask, and a format with no such aspect selects none, which
/// is the rejection at `Texture.cpp:954`.
pub fn selectFormatAspects(format: *const canonical_format.Format, aspect: enums.TextureAspect) AspectMask {
    return switch (aspect) {
        .all => formatAspects(format),
        .depth_only => if (format.hasDepth()) .{ .depth = 1 } else .{},
        .stencil_only => if (format.hasStencil()) .{ .stencil = 1 } else .{},
        .undefined_ => .{},
    };
}

pub fn formatAspects(format: *const canonical_format.Format) AspectMask {
    return AspectMask.fromFlags(@intFromEnum(format.aspects));
}

fn primaryBlock(format: *const canonical_format.Format) canonical_format.TexelBlockInfo {
    // Validated canonical rows have at least one aspect. firstAspect selects one present bit.
    return (format.getAspectInfoForAspect(
        @enumFromInt(@intFromEnum(firstAspect(@intFromEnum(format.aspects)))),
    ) catch |err| std.debug.panic(
        "primaryBlock: canonical format aspect invariant failed: {s}",
        .{@errorName(err)},
    )).block;
}

/// Dawn's `IsValidSampleCount` (`Texture.cpp:1079`). WebGPU has two.
pub fn isValidSampleCount(sample_count: u32) bool {
    return sample_count == 1 or sample_count == 4;
}

/// Dawn's `IsFormatSupportedForTexelBuffer` (`TexelBufferView.cpp:39`): the
/// twelve formats the texel buffer proposal names.
pub fn formatSupportedForTexelBuffer(format: enums.TextureFormat) bool {
    return switch (format) {
        .rgba8_unorm,
        .rgba8_uint,
        .rgba8_sint,
        .rgba16_uint,
        .rgba16_sint,
        .rgba16_float,
        .r32_uint,
        .r32_sint,
        .r32_float,
        .rgba32_uint,
        .rgba32_sint,
        .rgba32_float,
        => true,
        else => false,
    };
}

/// Dawn's `ValidateTexelBufferFormat` (`TexelBufferView.cpp:59`).
pub fn validateTexelBufferFormat(format: enums.TextureFormat) core_errors.ValidationError!void {
    if (format == .undefined_) return error.TexelBufferFormatUndefined;
    if (!formatSupportedForTexelBuffer(format)) return error.TexelBufferFormatUnsupported;
}

/// `ValidateTextureDescriptor` (`Texture.cpp:785-921`).
///
/// The order is the order upstream checks in, so a descriptor that breaks two
/// rules reports the rule upstream reports first.
pub fn validateTextureDescriptor(options: Options) core_errors.ValidationError!void {
    const descriptor = options.descriptor;
    const format = options.format_info;

    // The caller's list, unwrapped once and named: `(descriptor.view_formats
    // orelse &.{}).len` does not resolve, because a parenthesized `orelse`
    // whose result is immediately field-accessed gives the peer type of the
    // `else` branch nothing to infer from. Line 253 of this file unwraps the
    // same optional the same way.
    const view_formats = descriptor.view_formats orelse &.{};

    if (descriptor.format == .undefined_) return error.TextureViewFormatUndefined;
    if (descriptor.dimension == .undefined_) return error.TextureViewDimensionUndefined;
    if (format.format != canonical_format.fromApiFormat(descriptor.format))
        return error.TextureFormatMetadataMismatch;
    if (!format.isSupported()) return error.TextureFormatUnsupported;
    if (format.isMultiPlanar()) return error.TextureUsageCompressedFormat;

    // Every format the caller listed for a view must be view compatible with
    // this one (`Texture.cpp:837-840`).
    for (view_formats) |view_format| {
        if (!format.viewCompatibleWithApi(view_format)) {
            return error.TextureViewFormatIncompatible;
        }
    }

    if (descriptor.usage.toFlags() == 0) return error.TextureUsageMissing;
    try validateTextureUsageConstraints(
        options.compatibility_mode,
        descriptor.dimension,
        descriptor.usage,
        format,
    );

    if (descriptor.usage.has(.{ .transient_attachment = true })) {
        // Dawn's transient rule at `Texture.cpp:847-854`: one layer, one level
        // and no view formats, because the attachment is a constraint and not
        // an expansion of the usage.
        if (descriptor.size.depth_or_array_layers != 1 or descriptor.mip_level_count != 1) {
            return error.TextureSizeEmpty;
        }
        if (view_formats.len != 0) {
            return error.TextureUsageTransientAttachmentMixed;
        }
    }

    try validateSampleCount(descriptor, format);

    if (descriptor.size.width == 0 or
        descriptor.size.height == 0 or
        descriptor.size.depth_or_array_layers == 0 or
        descriptor.mip_level_count == 0)
    {
        return error.TextureSizeEmpty;
    }

    if (format.is_compressed) {
        if (descriptor.dimension == ._1d) return error.CompressedFormatNot1D;
        // Dawn has one branch per compression family, because sliced 3D is a
        // feature for BC and for ASTC (`Texture.cpp:884-900`) and the feature
        // table lands at M7. A compressed 3D texture is rejected here, and M7
        // removes this rule when it adds the two features.
        if (descriptor.dimension == ._3d) return error.CompressedFormatNot3D;
    }

    // Depth and stencil formats are two-dimensional only, on Metal and on D3D12
    // alike (`Texture.cpp:903-908`).
    if (descriptor.dimension != ._2d and format.hasDepthOrStencil()) {
        return error.DepthStencilDimensionNot2D;
    }

    try validateTextureSize(options);
}

/// `ValidateTextureUsageConstraints` (`Texture.cpp:402-485`).
pub fn validateTextureUsageConstraints(
    compatibility_mode: bool,
    dimension: enums.TextureDimension,
    usage: bitmask.TextureUsage,
    format: *const canonical_format.Format,
) core_errors.ValidationError!void {
    if (format.is_compressed) {
        // Dawn's `kValidCompressedUsages` (`Texture.cpp:410`): a compressed
        // format is sampled and copied, and nothing else.
        if (!usage.has(.{ .texture_binding = true, .copy_src = true, .copy_dst = true })) {
            return error.TextureUsageCompressedFormat;
        }
    }

    if (usage.has(.{ .render_attachment = true })) {
        if (!format.caps.renderable) return error.TextureFormatNotRenderable;
        if (dimension == ._1d) return error.TextureUsageRenderAttachmentOn1D;
    }

    if (usage.has(.{ .storage_binding = true })) {
        if (!format.caps.storage_read_only and !format.caps.storage_write_only and
            !format.caps.storage_read_write)
        {
            return error.TextureUsageStorageBindingUnsupported;
        }
    }

    if (usage.has(.{ .storage_attachment = true }) and !format.caps.storage_attachment) {
        return error.TextureUsageStorageAttachmentUnsupported;
    }

    if (usage.has(.{ .transient_attachment = true })) {
        // Dawn's `Toggle::DisableTransientAttachment` (`Texture.cpp:443`) is a
        // toggle, so the rule has no value to read at M11 and is not ported;
        // the M11 table row says so.
        _ = compatibility_mode;
        const transient_only: bitmask.TextureUsage = .{ .transient_attachment = true };
        if (usage.toFlags() == transient_only.toFlags()) {
            return error.TextureUsageTransientAttachmentAlone;
        }
        const attachment_usages: bitmask.TextureUsage = .{
            .transient_attachment = true,
            .render_attachment = true,
            .storage_attachment = true,
        };
        if (!usage.has(attachment_usages)) return error.TextureUsageTransientAttachmentMixed;
        if (dimension != ._2d) return error.TextureUsageTransientAttachmentNot2D;
    }
}

/// `ValidateSampleCount` (`Texture.cpp:193-235`).
pub fn validateSampleCount(
    descriptor: descriptors.TextureDescriptorChain,
    format: *const canonical_format.Format,
) core_errors.ValidationError!void {
    if (!isValidSampleCount(descriptor.sample_count)) return error.TextureSampleCountUnsupported;
    if (descriptor.sample_count <= 1) return;

    if (descriptor.mip_level_count > 1) return error.MultisampledMipLevelCountNotOne;
    if (descriptor.dimension != ._2d) return error.MultisampledDimensionNot2D;
    if (descriptor.size.depth_or_array_layers > 1) return error.MultisampledDepthNotOne;
    if (!format.caps.multisample) return error.MultisampledFormatUnsupported;
    if (descriptor.usage.has(.{ .storage_binding = true })) return error.MultisampledStorageBinding;
    if (descriptor.usage.has(.{ .storage_attachment = true })) return error.MultisampledStorageAttachment;
    if (!descriptor.usage.has(.{ .render_attachment = true })) {
        return error.MultisampledUsageMissingRenderAttachment;
    }
}

/// `ValidateTextureSize` (`Texture.cpp:287-400`).
pub fn validateTextureSize(options: Options) core_errors.ValidationError!void {
    const descriptor = options.descriptor;
    const format = options.format_info;

    const max_extent = maxExtentFor(descriptor.dimension, options.limits);
    if (descriptor.size.width > max_extent.width or
        descriptor.size.height > max_extent.height or
        descriptor.size.depth_or_array_layers > max_extent.depth_or_array_layers)
    {
        return error.TextureSizeAboveLimit;
    }

    // Dawn's `Log2(maxMippedDimension) + 1` at `Texture.cpp:369-371`: the number
    // of levels a size carries, which is ceil(log2(largest dimension)) + 1.
    const mip_level_limit = switch (descriptor.dimension) {
        ._1d => 1,
        ._2d => ceilLog2(@max(descriptor.size.width, descriptor.size.height)) + 1,
        ._3d => ceilLog2(@max(
            descriptor.size.width,
            @max(descriptor.size.height, descriptor.size.depth_or_array_layers),
        )) + 1,
        .undefined_ => unreachable,
    };
    if (descriptor.mip_level_count > mip_level_limit) return error.MipLevelCountAboveLimit;

    // Dawn's unaligned-compression feature gate (`Texture.cpp:387`) is a
    // feature, so the rule the port keeps is the one that holds without it.
    const block = format.aspect_info[0].block;
    if (format.is_compressed and block.width > 1) {
        if (descriptor.size.width % block.width != 0 or
            descriptor.size.height % block.height != 0)
        {
            return error.TextureCompressedBlockAlignment;
        }
    }
}

/// `ValidateTextureViewDescriptor` (`Texture.cpp:923-998`).
///
/// The rules run in upstream's order, and each is the rule upstream runs there:
/// the three undefined enums (`:930-932`), the view usage (`:951`), the aspect
/// (`:954`), the zero counts (`:958`), the array layer range (`:962`), the mip
/// range (`:969`), `ValidateCanViewTextureAs` (`:993`),
/// `ValidateTextureViewDimensionCompatibility` (`:994`), and the swizzle
/// (`:995`). The mip range is the one that bites most: a view whose
/// `base_mip_level + mip_level_count` is above the texture's level count names
/// a level that does not exist, and the descriptor is rejected.
///
/// Every count below comes from `resolved`, because that is the descriptor
/// upstream reads. Its `descriptor` is not the caller's: Dawn fills the
/// defaults into a local copy (`Device.cpp:2408`) and validates that copy
/// (`Device.cpp:2417-2418`), so the sentinel `constants.MipLevelCountUndefined`
/// is already a real count by the time `Texture.cpp:962-974` reads it.
/// `resolveViewDescriptorUnchecked` is the same defaulting.
pub fn validateTextureViewDescriptor(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    options: ViewOptions,
) core_errors.ValidationError!void {
    guard.assertOwns(texture.header.tracking);
    const descriptor = options.descriptor;
    if (texture.native_y_cb_cr != null or descriptor.y_cb_cr_vk_descriptor != null)
        return error.TextureFormatUnsupported;

    if (descriptor.dimension == .undefined_) return error.TextureViewDimensionUndefined;
    if (descriptor.format == .undefined_) return error.TextureViewFormatUndefined;
    if (descriptor.aspect == .undefined_) return error.TextureViewAspectUndefined;

    const view_format = options.format_info;
    if (view_format.format != canonical_format.fromApiFormat(descriptor.format))
        return error.TextureFormatMetadataMismatch;
    if (!view_format.isSupported()) return error.TextureFormatUnsupported;
    try validateTextureViewUsage(texture, guard, descriptor.usage);

    const aspects = selectFormatAspects(texture.format_info, descriptor.aspect);
    if (aspects.toFlags() == 0) return error.TextureViewAspectMissing;

    const resolved = resolveViewDescriptorUnchecked(texture, guard, descriptor);
    // The zero counts, which is `Texture.cpp:958-960` read over the defaulted
    // descriptor. `resolved` is zero exactly when the defaults produce no
    // level and no layer: a one-level texture with `base_mip_level = 1` and no
    // explicit count resolves to `1 - 1 = 0`. A texture with more than one
    // level resolves the same base to a real count and names a legal view, so
    // the rule is about the defaults, not about the base level.
    if (resolved.mip_level_count == 0 or resolved.array_layer_count == 0) {
        return error.TextureViewLayerCountZero;
    }

    // Upstream's order puts these two ahead of the dimension rules
    // (`Texture.cpp:962-974` before `:994`), and the values are the defaulted
    // ones: the caller's chain still carries
    // `constants.MipLevelCountUndefined`, so a whole-texture view would compute
    // `0 + 4294967295` and be refused for a range it lies inside.
    if (@as(u64, resolved.base_array_layer) + @as(u64, resolved.array_layer_count) >
        @as(u64, texture.getArrayLayers(guard)))
    {
        return error.TextureViewLayerRangeExceeds;
    }
    if (@as(u64, resolved.base_mip_level) + @as(u64, resolved.mip_level_count) >
        @as(u64, texture.getNumMipLevels(guard)))
    {
        return error.TextureViewMipRangeExceeds;
    }

    try validateCanViewTextureAs(texture, guard, view_format, descriptor.aspect);
    try validateTextureViewDimensionCompatibility(texture, guard, options.compatibility_mode, resolved);
    try validateComponentSwizzle(resolved.swizzle);
}

/// `ValidateCanViewTextureAs` (`Texture.cpp:72-120`).
pub fn validateCanViewTextureAs(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    view_format: *const canonical_format.Format,
    aspect: enums.TextureAspect,
) core_errors.ValidationError!void {
    guard.assertOwns(texture.header.tracking);
    const texture_format = texture.format_info;

    if (aspect != .all) {
        // Dawn compares the view format with the format of the one aspect the
        // descriptor selected (`Texture.cpp:79-87`).
        if (view_format.format == texture_format.format) return;
        return error.TextureViewAspectFormatMismatch;
    }

    if (texture_format.format == view_format.format) return;
    if (texture.isViewFormatListed(guard, canonical_format.toApiFormat(view_format.format) catch
        return error.TextureViewFormatIncompatible)) return;

    if (!texture_format.viewCompatibleWith(view_format)) {
        return error.TextureViewFormatIncompatible;
    }
    return error.TextureViewFormatNotInList;
}

/// `ValidateTextureViewUsage` (`Texture.cpp:513-531`) over
/// `GetTextureViewUsage` (`:487`).
pub fn validateTextureViewUsage(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    usage: bitmask.TextureUsage,
) core_errors.ValidationError!void {
    guard.assertOwns(texture.header.tracking);
    const inherited = resolveViewUsage(texture.usage, usage);
    if (!texture.usage.has(inherited)) return error.TextureViewUsageNotSubset;

    // Dawn refuses a subset on a transient attachment at `Texture.cpp:523-527`,
    // because a transient attachment is a constraint and not an expansion.
    if (texture.usage.has(.{ .transient_attachment = true }) and
        inherited.toFlags() != texture.usage.toFlags())
    {
        return error.TextureViewUsageNotSubset;
    }
}

/// `ValidateTextureViewDimensionCompatibility` (`Texture.cpp:237-285`) with
/// `IsArrayLayerValidForTextureViewDimension` (`:172`) and
/// `IsTextureViewDimensionCompatibleWithTextureDimension` (`:122`).
///
/// The check at `Texture.cpp:247-252` refuses a cube-array view in
/// compatibility mode before the switch is ever reached, because
/// `IsTextureViewDimensionCompatibleWithTextureDimension` returns false for
/// `CubeArray` under that mode (`:132-134`). The `Texture.cpp:269` rejection
/// below the switch is therefore unreachable, here and upstream alike, and the
/// error a compatibility device reports for a cube-array view is
/// `TextureViewDimensionNotCompatible`.
pub fn validateTextureViewDimensionCompatibility(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    compatibility_mode: bool,
    resolved: ResolvedViewDescriptor,
) core_errors.ValidationError!void {
    guard.assertOwns(texture.header.tracking);
    if (!isArrayLayerValidForViewDimension(resolved.dimension, resolved.array_layer_count)) {
        return error.TextureViewLayerCountNotValid;
    }

    if (!isViewDimensionCompatibleWithTextureDimension(
        compatibility_mode,
        resolved.dimension,
        texture.dimension,
    )) {
        return error.TextureViewDimensionNotCompatible;
    }

    if (texture.isMultisampledTexture(guard) and resolved.dimension != ._2d) {
        return error.TextureViewDimensionNotCompatible;
    }

    switch (resolved.dimension) {
        .cube, .cube_array => {
            const size = texture.getBaseSize(guard);
            if (size.width != size.height) return error.TextureViewCubeNotSquare;
            // Dawn's compatibility-mode cube-array rejection at `Texture.cpp:269`.
            // Unreachable in compatibility mode, as it is upstream, because the
            // check at `Texture.cpp:247` refuses that view first.
            if (resolved.dimension == .cube_array and compatibility_mode) {
                return error.TextureViewCubeArrayCompatibility;
            }
        },
        ._1d, ._2d, ._2d_array, ._3d => {},
        .undefined_ => unreachable,
    }
}

/// `IsArrayLayerValidForTextureViewDimension` (`Texture.cpp:172-191`).
pub fn isArrayLayerValidForViewDimension(dimension: enums.TextureViewDimension, layer_count: u32) bool {
    return switch (dimension) {
        ._2d, ._3d, ._1d => layer_count == 1,
        ._2d_array => true,
        .cube => layer_count == 6,
        .cube_array => layer_count % 6 == 0,
        .undefined_ => unreachable,
    };
}

/// `IsTextureViewDimensionCompatibleWithTextureDimension` (`Texture.cpp:122-146`).
pub fn isViewDimensionCompatibleWithTextureDimension(
    compatibility_mode: bool,
    view_dimension: enums.TextureViewDimension,
    texture_dimension: enums.TextureDimension,
) bool {
    return switch (view_dimension) {
        ._2d, ._2d_array, .cube => texture_dimension == ._2d,
        // Dawn's compatibility-mode branch at `Texture.cpp:133`.
        .cube_array => !compatibility_mode and texture_dimension == ._2d,
        ._3d => texture_dimension == ._3d,
        ._1d => texture_dimension == ._1d,
        .undefined_ => unreachable,
    };
}

/// Dawn's four `ValidateComponentSwizzle` calls, one per component
/// (`Texture.cpp:504-507`). The port has no feature table at M11, so the
/// `TextureComponentSwizzle` feature gate at `Texture.cpp:499` is not ported
/// and the M11 table row says so.
pub fn validateComponentSwizzle(
    swizzle: descriptors.TextureComponentSwizzle,
) core_errors.ValidationError!void {
    if (swizzle.r == .undefined_) return error.ComponentSwizzleUndefined;
    if (swizzle.g == .undefined_) return error.ComponentSwizzleUndefined;
    if (swizzle.b == .undefined_) return error.ComponentSwizzleUndefined;
    if (swizzle.a == .undefined_) return error.ComponentSwizzleUndefined;
}

/// `ResolveDefaultCompatiblityTextureBindingViewDimension` (`Texture.cpp:680`)
/// over its `_Impl` (`:650`). Dawn keeps its spelling of "compatibility" in the
/// name; the port does not, because `AGENTS.md` §2 names things for what they
/// are.
pub fn resolveBindingViewDimension(
    compatibility_mode: bool,
    dimension: enums.TextureDimension,
    depth_or_array_layers: u32,
    requested: ?enums.TextureViewDimension,
) enums.TextureViewDimension {
    // Dawn returns undefined when the device has flexible texture views
    // (`Texture.cpp:657`), because the value is then unused.
    if (!compatibility_mode) return .undefined_;

    if (requested) |value| {
        if (value != .undefined_) return value;
    }

    return switch (dimension) {
        ._1d => ._1d,
        ._2d => if (depth_or_array_layers == 1) ._2d else ._2d_array,
        ._3d => ._3d,
        .undefined_ => .undefined_,
    };
}

/// `GetTextureViewDescriptorWithDefaults` (`Texture.cpp:1000-1075`).
///
/// The caller's descriptor is not mutated, as upstream: this returns a copy.
pub fn resolveViewDescriptor(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    options: ViewOptions,
) ResolvedViewDescriptor {
    guard.assertOwns(texture.header.tracking);
    return resolveViewDescriptorUnchecked(texture, guard, options.descriptor);
}

/// The defaults `resolveViewDescriptor` fills in, with no rule applied. The
/// validation reads the caller's numbers and this answers them, so the two can
/// never disagree about what the descriptor said.
fn resolveViewDescriptorUnchecked(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    descriptor: descriptors.TextureViewDescriptorChain,
) ResolvedViewDescriptor {
    guard.assertOwns(texture.header.tracking);
    var resolved: ResolvedViewDescriptor = .{
        .format = descriptor.format,
        .dimension = descriptor.dimension,
        .base_mip_level = descriptor.base_mip_level,
        .mip_level_count = descriptor.mip_level_count,
        .base_array_layer = descriptor.base_array_layer,
        .array_layer_count = descriptor.array_layer_count,
        .aspect = descriptor.aspect,
        .usage = descriptor.usage,
        .swizzle = if (descriptor.texture_component_swizzle_descriptor) |swizzle|
            swizzle.swizzle
        else
            identitySwizzle(),
    };

    // The dimension default depends on the texture's layer count
    // (`Texture.cpp:1012-1033`).
    if (resolved.dimension == .undefined_) {
        resolved.dimension = switch (texture.dimension) {
            ._1d => ._1d,
            ._2d => if (texture.getArrayLayers(guard) == 1) ._2d else ._2d_array,
            ._3d => ._3d,
            .undefined_ => unreachable,
        };
    }

    if (resolved.format == .undefined_) resolved.format = texture.getFormat(guard);

    if (resolved.array_layer_count == constants.ArrayLayerCountUndefined) {
        resolved.array_layer_count = switch (resolved.dimension) {
            ._1d, ._2d, ._3d => 1,
            .cube => 6,
            ._2d_array, .cube_array => texture.getArrayLayers(guard) - resolved.base_array_layer,
            // Dawn does not treat this as unreachable (`Texture.cpp:1064-1067`):
            // the enum is validated only after the defaults are filled in.
            .undefined_ => 0,
        };
    }

    if (resolved.mip_level_count == constants.MipLevelCountUndefined) {
        resolved.mip_level_count = texture.getNumMipLevels(guard) - resolved.base_mip_level;
    }

    return resolved;
}

/// `GetTextureViewUsage` (`Texture.cpp:487-492`): a view that names no usage
/// inherits the texture's.
pub fn resolveViewUsage(
    texture_usage: bitmask.TextureUsage,
    requested: bitmask.TextureUsage,
) bitmask.TextureUsage {
    if (requested.toFlags() != 0) return requested;
    return texture_usage;
}

/// `AdjustViewInternalUsages` (`Texture.cpp:738-759`), minus `AddInternalUsages`
/// (`:693-735`), whose four additions are each gated on a toggle or a feature.
pub fn adjustInternalUsages(
    format: *const canonical_format.Format,
    usage: bitmask.TextureUsage,
) bitmask.TextureUsage {
    var adjusted = usage;
    // Dawn removes the storage usage when neither read nor write is supported
    // (`Texture.cpp:753-755`).
    if (!format.caps.storage_read_only and !format.caps.storage_write_only and
        !format.caps.storage_read_write)
    {
        adjusted.storage_binding = false;
    }
    return adjusted;
}

/// `AdjustViewInternalUsages` (`Texture.cpp:738-759`) for a view.
pub fn adjustViewInternalUsages(
    format: *const canonical_format.Format,
    usage: bitmask.TextureUsage,
    dimension: enums.TextureViewDimension,
) bitmask.TextureUsage {
    var adjusted = adjustInternalUsages(format, usage);
    // A one-dimensional view is never a render attachment (`Texture.cpp:748-750`).
    if (dimension == ._1d) adjusted.render_attachment = false;
    return adjusted;
}

/// `ApplyDefaultTexelCopyBufferLayoutOptions` (`CommandValidation.cpp:345-364`).
///
/// Dawn aligns the default pitch to 256 (`CommandValidation.cpp:358`), which is
/// why a copy of a four-row sixteen-byte texture with no explicit pitch touches
/// 784 bytes and not 64.
pub fn applyDefaultLayout(
    layout: TexelCopyBufferLayout,
    copy_extent: descriptors.Extent3D,
    format: *const canonical_format.Format,
) TexelCopyBufferLayout {
    return applyDefaultBlockLayout(layout, copy_extent, primaryBlock(format));
}

fn applyDefaultBlockLayout(
    layout: TexelCopyBufferLayout,
    copy_extent: descriptors.Extent3D,
    block: canonical_format.TexelBlockInfo,
) TexelCopyBufferLayout {
    var resolved = layout;
    const blocks_across = @divExact(copy_extent.width, block.width);
    const blocks_down = @divExact(copy_extent.height, block.height);
    const bytes_in_last_row = blocks_across * block.byte_size;

    if (resolved.bytes_per_row == constants.CopyStrideUndefined) {
        // Dawn asserts the same two preconditions at `CommandValidation.cpp:357`.
        std.debug.assert(blocks_down <= 1);
        std.debug.assert(copy_extent.depth_or_array_layers <= 1);
        resolved.bytes_per_row = alignForward(bytes_in_last_row, texture_bytes_per_row_alignment);
    }
    if (resolved.rows_per_image == constants.CopyStrideUndefined) {
        std.debug.assert(copy_extent.depth_or_array_layers <= 1);
        resolved.rows_per_image = blocks_down;
    }
    return resolved;
}

/// `ComputeRequiredBytesInCopy` (`CommandValidation.cpp:295-320`): every image
/// but the last contributes a whole stride, and the last contributes the bytes
/// its last row actually holds.
pub fn computeRequiredBytesInCopy(
    bytes_in_row: u32,
    bytes_per_row: u32,
    rows_per_image: u32,
    image_count: u32,
) u64 {
    if (image_count == 0) return 0;
    const full_images = @as(u64, bytes_per_row) *
        @as(u64, rows_per_image) *
        @as(u64, image_count - 1);
    const last_image = @as(u64, bytes_per_row) * @as(u64, rows_per_image - 1) +
        @as(u64, bytes_in_row);
    return full_images + last_image;
}

/// A copy with every default resolved: the region to move, the pitch of the
/// linear side, and the shape of the subresource it reads and writes.
const ResolvedCopy = struct {
    /// Where the copy starts inside the linear side.
    offset: usize,
    /// The pitch of the linear side.
    bytes_per_row: u32,
    /// The width of one row in bytes, which is what a copy moves per row.
    bytes_in_row: u32,
    /// The origin inside the subresource: blocks across, rows down, images in.
    origin_x_block: u32,
    origin_y: u32,
    origin_z: u32,
    /// The number of images the copy spans, which is the copy's depth.
    image_count: u32,
    /// The rows one image spans on the linear side.
    rows_per_image: u32,
    mip_level: u32,
    aspect: Aspect,
    /// The level's physical size, so every store index below is derived from the
    /// texture and not from the caller.
    extent: descriptors.Extent3D,
};

/// `ValidateTexelCopyTextureInfo` (`CommandValidation.cpp:440-473`),
/// `ValidateTexelCopyBufferInfo` (`:423-438`), `ValidateLinearTextureData`
/// (`:366-421`) and `ComputeRequiredBytesInCopy` (`:295-320`), over
/// `ApplyDefaultTexelCopyBufferLayoutOptions` (`:345-364`).
fn resolveCopy(
    texture: *const Texture,
    guard: *const object.ObjectGuard,
    texture_copy: TexelCopyTextureInfo,
    texture_layout: TexelCopyTextureLayout,
    buffer_layout: TexelCopyBufferLayout,
    linear_size: usize,
) CreateError!ResolvedCopy {
    guard.assertOwns(texture.header.tracking);
    if (texture.native_y_cb_cr != null) return error.TextureFormatUnsupported;
    const format = texture.format_info;
    if (texture_copy.mip_level >= texture.getNumMipLevels(guard)) return error.CopyExtentExceedsLevel;

    const aspect_mask = selectFormatAspects(format, texture_copy.aspect);
    if (aspect_mask.toFlags() == 0) return error.TextureViewAspectMissing;
    const aspect = firstAspect(aspect_mask.toFlags());
    if (@popCount(aspect_mask.toFlags()) != 1) return error.TextureViewAspectMissing;

    const level = texture.getMipLevelSubresourcePhysicalSize(guard, texture_copy.mip_level);
    try validateCopyOrigin(level, texture_layout);

    const layout = applyDefaultBlockLayout(buffer_layout, level, texture.aspectBlock(guard, aspect));
    if (layout.bytes_per_row % texture_bytes_per_row_alignment != 0) {
        return error.CopyBytesPerRowNotAligned;
    }

    const block = texture.aspectBlock(guard, aspect);
    const blocks_across = @divExact(texture_layout.size.width, block.width);
    const rows_in_blocks = @divExact(texture_layout.size.height, block.height);
    const bytes_in_row = blocks_across * block.byte_size;

    if (texture_layout.size.depth_or_array_layers > 1 and
        (layout.bytes_per_row == constants.CopyStrideUndefined or
            layout.rows_per_image == constants.CopyStrideUndefined))
    {
        return error.CopyStrideUndefined;
    }
    if (rows_in_blocks > 1 and layout.bytes_per_row == constants.CopyStrideUndefined) {
        return error.CopyStrideUndefined;
    }
    if (bytes_in_row > layout.bytes_per_row) return error.CopyBytesPerRowBelowRowSize;
    if (rows_in_blocks > layout.rows_per_image) return error.CopyRowsPerImageBelowHeight;

    const required_bytes = computeRequiredBytesInCopy(
        bytes_in_row,
        layout.bytes_per_row,
        layout.rows_per_image,
        texture_layout.size.depth_or_array_layers,
    );
    if (layout.offset > linear_size or required_bytes > linear_size - layout.offset) {
        return error.CopyDataTooSmall;
    }

    return .{
        .offset = @intCast(layout.offset),
        .bytes_per_row = layout.bytes_per_row,
        .bytes_in_row = bytes_in_row,
        .origin_x_block = @divExact(texture_layout.offset.x, block.width),
        .origin_y = texture_layout.offset.y,
        .origin_z = texture_layout.offset.z,
        .image_count = texture_layout.size.depth_or_array_layers,
        .rows_per_image = layout.rows_per_image,
        .mip_level = texture_copy.mip_level,
        .aspect = aspect,
        .extent = level,
    };
}

/// The origin-plus-extent check at `CommandValidation.cpp:494-504`. A copy that
/// starts outside the level, or that runs past its far edge, names a region the
/// level does not have.
pub fn validateCopyOrigin(
    level: descriptors.Extent3D,
    layout: TexelCopyTextureLayout,
) core_errors.ValidationError!void {
    if (@as(u64, layout.offset.x) + @as(u64, layout.size.width) > @as(u64, level.width)) {
        return error.CopyExtentExceedsLevel;
    }
    if (@as(u64, layout.offset.y) + @as(u64, layout.size.height) > @as(u64, level.height)) {
        return error.CopyExtentExceedsLevel;
    }
    if (@as(u64, layout.offset.z) + @as(u64, layout.size.depth_or_array_layers) >
        @as(u64, level.depth_or_array_layers))
    {
        return error.CopyExtentExceedsLevel;
    }
}

/// The move itself. Both sides use the pitch the caller named, which is what
/// makes the 256-byte row path differ from the 16-byte one.
///
/// The loop bounds are the level's own rows and images. `validateCopyOrigin` has
/// already refused a copy that runs past either, so the loops cannot outrun the
/// store, and both slices are re-checked per row because the caller supplies the
/// linear side.
fn copyRows(texture: *const Texture, guard: *const object.ObjectGuard, copy: ResolvedCopy, linear: []const u8, into: bool) void {
    guard.assertOwns(texture.header.tracking);
    const block = texture.aspectBlock(guard, copy.aspect);
    const extent = texture.getMipLevelSubresourcePhysicalSize(guard, copy.mip_level);
    const row_byte_size = @as(usize, @divExact(extent.width, block.width)) * block.byte_size;
    const rows_in_level = @divExact(extent.height, block.height);
    const image_byte_size = row_byte_size * rows_in_level;
    const x_byte_offset = @as(usize, copy.origin_x_block) * block.byte_size;

    const image_bound = copy.origin_z + copy.image_count;
    var z: u32 = copy.origin_z;
    while (z < image_bound) : (z += 1) {
        const image_index = z - copy.origin_z;
        const linear_image = copy.offset +
            @as(usize, image_index) * @as(usize, copy.rows_per_image) * @as(usize, copy.bytes_per_row);
        // A 3D texture keeps every depth slice in one subresource; a 2D array
        // texture gives each layer its own.
        const store_image = if (texture.dimension == ._3d)
            texture.subresourceByteOffset(guard, copy.mip_level, 0, copy.aspect) +
                @as(usize, image_index) * image_byte_size
        else
            texture.subresourceByteOffset(guard, copy.mip_level, z, copy.aspect);

        const row_bound = copy.origin_y + copy.rows_per_image;
        // The row loop is bounded by the level's own rows.
        // `validateCopyOrigin` has already refused a copy that runs past them.
        std.debug.assert(@as(usize, row_bound) <= rows_in_level);
        var y: u32 = copy.origin_y;
        while (y < row_bound) : (y += 1) {
            const linear_row = linear_image +
                @as(usize, y - copy.origin_y) * @as(usize, copy.bytes_per_row);
            const store_row = store_image + @as(usize, y) * row_byte_size;
            const store_start = store_row + x_byte_offset;

            if (store_start + copy.bytes_in_row > store_image + image_byte_size) return;
            if (store_start + copy.bytes_in_row > texture.bytes.len) return;
            if (linear_row + copy.bytes_in_row > linear.len) return;

            if (into) {
                @memcpy(
                    texture.bytes[store_start .. store_start + copy.bytes_in_row],
                    linear[linear_row .. linear_row + copy.bytes_in_row],
                );
            } else {
                // The destination side is the caller's buffer, which
                // `copyTextureToBuffer` owns mutably; the const parameter above
                // is the one that forced this cast.
                @memcpy(
                    @constCast(linear[linear_row .. linear_row + copy.bytes_in_row]),
                    texture.bytes[store_start .. store_start + copy.bytes_in_row],
                );
            }
        }
    }
}

/// The extent `ValidateTextureSize` compares a descriptor against
/// (`Texture.cpp:294-308`).
fn maxExtentFor(dimension: enums.TextureDimension, limits: TextureLimits) descriptors.Extent3D {
    return switch (dimension) {
        ._1d => .{
            .width = limits.max_texture_dimension_1d,
            .height = 1,
            .depth_or_array_layers = 1,
        },
        ._2d => .{
            .width = limits.max_texture_dimension_2d,
            .height = limits.max_texture_dimension_2d,
            .depth_or_array_layers = limits.max_texture_array_layers,
        },
        ._3d => .{
            .width = limits.max_texture_dimension_3d,
            .height = limits.max_texture_dimension_3d,
            .depth_or_array_layers = limits.max_texture_dimension_3d,
        },
        .undefined_ => unreachable,
    };
}

/// Dawn's `Log2` for a positive integer: the number of halvings that reach one.
fn ceilLog2(value: u32) u32 {
    if (value <= 1) return 0;
    return 32 - @clz(value - 1);
}

/// The shift for a mip level. A `u32` is 32 bits wide, so a level above 31
/// shifts every dimension out and the answer is one either way; the clamp keeps
/// the shift inside its own width.
fn levelShift(mip_level: u32) u5 {
    return @intCast(@min(mip_level, 31));
}

/// The block padding of `GetMipLevelSubresourcePhysicalSize` (`:1564-1572`).
fn roundUpToBlocks(extent: descriptors.Extent3D, format: *const canonical_format.Format) descriptors.Extent3D {
    const block = primaryBlock(format);
    std.debug.assert(block.width > 0);
    std.debug.assert(block.height > 0);
    if (block.width == 1 and block.height == 1) return extent;
    return .{
        .width = divCeil(extent.width, block.width) * block.width,
        .height = divCeil(extent.height, block.height) * block.height,
        .depth_or_array_layers = extent.depth_or_array_layers,
    };
}

/// The position of `aspect` among the set bits of `mask`, counting from zero.
/// Dawn's `GetAspectIndex` (`src/dawn/native/Subresource.h`) answers the same
/// question. The mask has seven named bits and no more, so the walk below is
/// bounded by the mask and not by the caller's data.
fn aspectIndexIn(mask: AspectMask, aspect: Aspect) usize {
    const wanted: u3 = @intCast(@ctz(@as(u8, @intFromEnum(aspect))));
    var index: usize = 0;
    var flags = mask.toFlags();
    while (flags != 0) : (flags &= flags - 1) {
        if (@as(u8, @intCast(@ctz(flags))) == wanted) return index;
        index += 1;
    }
    // One past the last bit, so an absent aspect cannot alias a present one.
    return index;
}

/// The lowest set bit of a mask, as the aspect it names.
fn firstAspect(flags: u8) Aspect {
    return aspectOfBit(@intCast(@ctz(flags)));
}

/// The aspect the bit at `index` names, with index zero the lowest bit.
///
/// The arms are indices and not the `Aspect` words: `aspectOfBit` is handed
/// `@ctz` of a mask, and `combined_depth_stencil` is word `0x40` but sits at
/// index six. The mask names seven bits, so `u3` holds every index and the
/// answer is total.
fn aspectOfBit(index: u3) Aspect {
    return switch (index) {
        0 => .color,
        1 => .depth,
        2 => .stencil,
        6 => .combined_depth_stencil,
        else => .none,
    };
}

/// The mask that names one aspect.
fn aspectMaskOf(aspect: Aspect) AspectMask {
    return AspectMask.fromFlags(@intFromEnum(aspect));
}

/// `value` rounded up to a multiple of `alignment`, named so the rule reads at
/// the call site (`AGENTS.md` §2, "make division explicit").
fn alignForward(value: u32, alignment: u32) u32 {
    return divCeil(value, alignment) * alignment;
}

/// Integer division rounded up, written out because `AGENTS.md` §2 asks for the
/// rounding rule to be visible.
fn divCeil(numerator: u32, denominator: u32) u32 {
    return @divTrunc(numerator, denominator) + @intFromBool(numerator % denominator != 0);
}

comptime {
    // Every rule this file raises must be a member of the port's validation set
    // (`docs/30-port-design.md` §2.3). A name that is not a member is a typo,
    // and the compile error names it.
    const raised = [_][]const u8{
        "TextureUsageMissing",
        "TextureSizeEmpty",
        "TextureUsageCompressedFormat",
        "TextureUsageRenderAttachmentOn1D",
        "TextureUsageStorageBindingUnsupported",
        "TextureUsageStorageAttachmentUnsupported",
        "TextureUsageTransientAttachmentAlone",
        "TextureUsageTransientAttachmentMixed",
        "TextureUsageTransientAttachmentNot2D",
        "TextureUsageMissingCopyDst",
        "TextureUsageMissingCopySrc",
        "TextureSampleCountUnsupported",
        "MultisampledMipLevelCountNotOne",
        "MultisampledDimensionNot2D",
        "MultisampledDepthNotOne",
        "MultisampledFormatUnsupported",
        "MultisampledStorageBinding",
        "MultisampledStorageAttachment",
        "MultisampledUsageMissingRenderAttachment",
        "TextureSizeAboveLimit",
        "MipLevelCountAboveLimit",
        "TextureCompressedBlockAlignment",
        "DepthStencilDimensionNot2D",
        "CompressedFormatNot1D",
        "CompressedFormatNot3D",
        "TextureViewFormatIncompatible",
        "TextureViewFormatNotInList",
        "TextureViewDimensionUndefined",
        "TextureViewFormatUndefined",
        "TextureViewAspectUndefined",
        "TextureViewAspectMissing",
        "TextureViewAspectFormatMismatch",
        "TextureViewLayerCountZero",
        "TextureViewLayerRangeExceeds",
        "TextureViewMipRangeExceeds",
        "TextureViewDimensionNotCompatible",
        "TextureViewLayerCountNotValid",
        "TextureViewCubeNotSquare",
        "TextureViewCubeArrayCompatibility",
        "TextureViewUsageNotSubset",
        "ComponentSwizzleUndefined",
        "CopyStrideUndefined",
        "CopyBytesPerRowNotAligned",
        "CopyBytesPerRowBelowRowSize",
        "CopyRowsPerImageBelowHeight",
        "CopyDataTooSmall",
        "CopyExtentExceedsLevel",
        "TexelBufferFormatUndefined",
        "TexelBufferFormatUnsupported",
    };
    // `ValidationError` is an error set, not an enum, so membership is a walk
    // of the set's member names (`src/engine/buffer.zig:1854-1856` records the
    // same fact for `Rule`): reflection hands back a name and no error value,
    // Zig has no builtin that turns a name back into an error value. The walk
    // compares every name against every member, so it raises the branch budget
    // the way `src/engine/vulkan_device.zig:183` does for the same shape.
    @setEvalBranchQuota(100_000);
    // The set is walked as the expression itself and not through a binding,
    // for the reason `src/engine/buffer.zig:1847-1850` records.
    for (raised) |name| {
        var held = false;
        for (@typeInfo(core_errors.ValidationError).error_set.?) |member| {
            if (std.mem.eql(u8, member.name, name)) held = true;
        }
        if (!held) @compileError("a texture rule names a missing error: " ++ name);
    }
}

test "native texture synchronization distinguishes transfer and attachment writes" {
    const transfer = try nativeUsageState(.{ .copy_dst = true }, .none, false);
    try std.testing.expect(transfer.layout == vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    try std.testing.expect(transfer.access & vulkan.VK_ACCESS_TRANSFER_WRITE_BIT != 0);
    const attachment = try nativeUsageState(.{ .render_attachment = true }, .none, false);
    try std.testing.expect(attachment.layout == vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    try std.testing.expect(attachment.access & vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT != 0);
}

test "native texture rejects empty synchronization usage" {
    try std.testing.expectError(error.TextureNativeUsageUnsupported, nativeUsageState(.{}, .none, false));
}

test "native image binding failure releases image and memory" {
    var fixture: NativeFixture = .{};
    fixture.fail_bind = true;
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    const context = fixture.context(&procs, &handles);
    try std.testing.expectError(error.OutOfDeviceMemory, texture.initializeNative(std.testing.allocator, guard, context));
    try std.testing.expectEqual(@as(u32, 1), fixture.images_created);
    try std.testing.expectEqual(fixture.images_created, fixture.images_destroyed);
    try std.testing.expectEqual(fixture.memories_allocated, fixture.memories_freed);
    try std.testing.expect(texture.native == null);
    try std.testing.expect(handles.isEmpty());
}

test "native image allocation failure paths leave no native owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, nativeAllocationRoundTrip, .{});
}

test "frontend texture transition entry paths reject missing native storage before side effects" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var bytes: [20]u8 = @splat(0x55);
    const offsets = [_]usize{ 0, 16, 20 };
    var initialized = [_]bool{ false, false };
    texture.bytes = &bytes;
    texture.subresource_offsets = &offsets;
    texture.initialized = &initialized;
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    const valid = texture.getAllSubresources(guard);
    var invalid = valid;
    invalid.base_mip_level = texture.mip_level_count;
    var batch: BarrierBatch = .{};
    defer batch.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    // Native availability precedes range validation for every shared entry path.
    for ([_]SubresourceRange{ valid, invalid }) |range| {
        try std.testing.expectError(error.TextureNativeNotInitialized, texture.transition(
            guard,
            recording,
            range,
            .{ .copy_src = true },
            .none,
        ));
        try std.testing.expectError(error.TextureNativeNotInitialized, texture.transitionInto(
            failing.allocator(),
            guard,
            range,
            .{ .copy_src = true },
            .none,
            &batch,
        ));
        try std.testing.expectError(error.TextureNativeNotInitialized, texture.transitionRenderAttachment(
            guard,
            recording,
            range,
            .{},
        ));
        try std.testing.expectError(error.TextureNativeNotInitialized, texture.validateSyncScopeUsage(
            guard,
            range,
            .{ .copy_src = true },
            .none,
        ));
        try std.testing.expect(texture.native == null);
        try std.testing.expectEqualSlices(bool, &.{ false, false }, &initialized);
        try std.testing.expectEqualSlices(u8, &(@as([20]u8, @splat(0x55))), &bytes);
        try std.testing.expectEqual(@as(u32, 0), fixture.barriers_recorded);
        try std.testing.expectEqual(@as(u32, 0), fixture.clears_recorded);
        try std.testing.expectEqual(@as(u32, 0), fixture.buffer_image_copies);
        try std.testing.expectEqual(@as(usize, 0), batch.image_barriers.items.len);
        try std.testing.expectEqual(@as(usize, 0), batch.image_barriers.capacity);
        try std.testing.expectEqual(@as(u32, 0), batch.source_stages);
        try std.testing.expectEqual(@as(u32, 0), batch.destination_stages);
    }
}

test "native texture transition entry paths reject invalid ranges before state changes" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var initialized = [_]bool{ false, false };
    texture.initialized = &initialized;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    const before = [_]NativeUsageState{ texture.native.?.states[0], texture.native.?.states[1] };
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    var range = texture.getAllSubresources(guard);
    range.base_mip_level = texture.mip_level_count;
    var batch: BarrierBatch = .{};
    defer batch.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.TextureNativeRangeInvalid, texture.transition(
        guard,
        recording,
        range,
        .{ .copy_src = true },
        .none,
    ));
    try std.testing.expectError(error.TextureNativeRangeInvalid, texture.transitionInto(
        failing.allocator(),
        guard,
        range,
        .{ .copy_src = true },
        .none,
        &batch,
    ));
    try std.testing.expectError(error.TextureNativeRangeInvalid, texture.transitionRenderAttachment(
        guard,
        recording,
        range,
        .{},
    ));
    try std.testing.expectError(error.TextureNativeRangeInvalid, texture.validateSyncScopeUsage(
        guard,
        range,
        .{ .copy_src = true },
        .none,
    ));
    for (before, texture.native.?.states) |expected, actual|
        try std.testing.expect(std.meta.eql(expected, actual));
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &initialized);
    try std.testing.expectEqual(@as(u32, 0), fixture.barriers_recorded);
    try std.testing.expectEqual(@as(u32, 0), fixture.clears_recorded);
    try std.testing.expectEqual(@as(u32, 0), fixture.buffer_image_copies);
    try std.testing.expectEqual(@as(usize, 0), batch.image_barriers.items.len);
    try std.testing.expectEqual(@as(usize, 0), batch.image_barriers.capacity);
    try std.testing.expectEqual(@as(u32, 0), batch.source_stages);
    try std.testing.expectEqual(@as(u32, 0), batch.destination_stages);
}

test "native transitions track independent mip layouts and preserve write barriers" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    const range: SubresourceRange = .{
        .aspects = .{ .color = 1 },
        .base_array_layer = 0,
        .layer_count = 1,
        .base_mip_level = 0,
        .level_count = 1,
    };
    try texture.transition(guard, recording, range, .{ .copy_dst = true }, .none);
    try texture.transition(guard, recording, range, .{ .copy_dst = true }, .none);
    try std.testing.expectEqual(@as(u32, 2), fixture.barriers_recorded);
    try std.testing.expect(fixture.old_layout == vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    try std.testing.expect(texture.native.?.states[1].layout == vulkan.VK_IMAGE_LAYOUT_UNDEFINED);
    try texture.transition(guard, recording, range, .{ .copy_src = true }, .none);
    try texture.transition(guard, recording, range, .{ .copy_src = true }, .none);
    try std.testing.expectEqual(@as(u32, 3), fixture.barriers_recorded);
}

// Match the bounded budget of the canonical format table's compile-time proof.
const native_fixture_format_branch_quota = 30_000;
const native_fixture_format: canonical_format.Format = blk: {
    @setEvalBranchQuota(native_fixture_format_branch_quota);
    // SAFETY: buildFormatTable writes all 109 canonical rows before the rgba8_unorm row is copied.
    var table: canonical_format.FormatTable = undefined;
    canonical_format.buildFormatTable(.{}, &table);
    break :blk table[canonical_format.computeFormatIndex(.rgba8_unorm).?];
};

fn nativeFixtureHeader(
    comptime T: type,
    target: *T,
    kind: handle.Handle.Kind,
    guard: *const object.ObjectGuard,
) object.Object {
    const objects_list = guard.objects;
    guard.assertOwns(objects_list);
    objects_list.total_reference_count += 1;
    objects_list.user_reference_count += 1;
    return .{
        .kind = kind,
        .state = .alive,
        .reference_count = 1,
        .user_reference_count = 1,
        .last_error = null,
        .label = "",
        .tracking = objects_list,
        .context = target,
        .destroy_callback = struct {
            fn destroy(context: *anyopaque, held: *const object.ObjectGuard, io: std.Io, reason: object.DestroyReason) void {
                const resource: *T = @ptrCast(@alignCast(context));
                resource.destroy(held, io, reason);
            }
        }.destroy,
    };
}

fn nativeFixtureTexture(texture: *Texture, guard: *const object.ObjectGuard, io: std.Io) void {
    texture.* = .{
        .header = nativeFixtureHeader(Texture, texture, .texture, guard),
        .format_info = &native_fixture_format,
        .dimension = ._2d,
        .binding_view_dimension = ._2d,
        .base_size = .{ .width = 2, .height = 2, .depth_or_array_layers = 1 },
        .mip_level_count = 2,
        .sample_count = 1,
        .internal_usage = .{ .render_attachment = true, .copy_src = true },
        .usage = .{ .render_attachment = true, .copy_src = true },
        .compatibility_mode = false,
        .bytes = &.{},
        .subresource_offsets = &.{},
        .view_formats = &.{},
        .initialized = &.{},
        .native = null,
    };
    texture.header.attach(guard, io);
}

fn nativeFixtureView(view: *TextureView, texture: *Texture, dimension: enums.TextureViewDimension, guard: *const object.ObjectGuard, io: std.Io) !void {
    try texture.header.retainLeaseLocked(guard);
    view.* = .{
        .header = nativeFixtureHeader(TextureView, view, .texture_view, guard),
        .texture = texture,
        .parent_lease_held = true,
        .format_info = texture.format_info,
        .format = .rgba8_unorm,
        .dimension = dimension,
        .aspects = .{ .color = 1 },
        .range = .{
            .aspects = .{ .color = 1 },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .usage = .{ .render_attachment = true },
        .internal_usage = .{ .render_attachment = true },
        .swizzle = identitySwizzle(),
        .native_view = null,
        .attachment_views = null,
        .attachment_view_count = 0,
    };
    view.header.attach(guard, io);
}

fn nativeAllocationRoundTrip(allocator: std.mem.Allocator) !void {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    texture.initializeNative(allocator, guard, fixture.context(&procs, &handles)) catch |err| {
        try std.testing.expect(texture.native == null);
        try std.testing.expect(handles.isEmpty());
        try std.testing.expectEqual(fixture.images_created, fixture.images_destroyed);
        try std.testing.expectEqual(fixture.memories_allocated, fixture.memories_freed);
        return err;
    };
    texture.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(fixture.images_created, fixture.images_destroyed);
    try std.testing.expectEqual(fixture.memories_allocated, fixture.memories_freed);
}

const NativeFixture = struct {
    fail_bind: bool = false,
    fail_view: bool = false,
    images_created: u32 = 0,
    images_destroyed: u32 = 0,
    memories_allocated: u32 = 0,
    memories_freed: u32 = 0,
    barriers_recorded: u32 = 0,
    views_destroyed: u32 = 0,
    views_created: u32 = 0,
    last_view_type: vulkan.VkImageViewType = vulkan.VK_IMAGE_VIEW_TYPE_3D,
    last_view_conversion: vulkan.VkSamplerYcbcrConversion = null,
    last_copy_regions: [3]vulkan.VkBufferImageCopy = @splat(.{}),
    image_usage: vulkan.VkImageUsageFlags = 0,
    image_query_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    image_max_extent: u32 = 4096,
    image_max_resource_size: u64 = 1 << 30,
    format_features: vulkan.VkFormatFeatureFlags =
        vulkan.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
        vulkan.VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT |
        vulkan.VK_FORMAT_FEATURE_MIDPOINT_CHROMA_SAMPLES_BIT |
        vulkan.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
        vulkan.VK_FORMAT_FEATURE_TRANSFER_DST_BIT,
    permit_sampled_image: bool = true,
    permit_attachment_image: bool = true,
    clears_recorded: u32 = 0,
    old_layout: vulkan.VkImageLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
    new_layout: vulkan.VkImageLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
    src_stages: vulkan.VkPipelineStageFlags = 0,
    dst_stages: vulkan.VkPipelineStageFlags = 0,
    src_access: vulkan.VkAccessFlags = 0,
    dst_access: vulkan.VkAccessFlags = 0,
    aspect_mask: vulkan.VkImageAspectFlags = 0,
    buffer_image_copies: u32 = 0,
    staging_bytes: [4096]u8 = @splat(0x55),
    memory_properties: vulkan.VkPhysicalDeviceMemoryProperties = .{
        .memoryTypeCount = 2,
        .memoryTypes = [_]vulkan.VkMemoryType{
            .{ .propertyFlags = vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT },
            .{ .propertyFlags = vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT },
        } ++ ([_]vulkan.VkMemoryType{.{}} ** 30),
    },

    fn context(
        self: *NativeFixture,
        procs: *dispatch.DeviceProcs,
        handles: *vulkan_device.HandleSet,
    ) buffer_mod.Device {
        return .{
            .allocator = std.testing.allocator,
            .dispatch = .{ .global = null, .instance = null, .device = procs },
            .vk_device = @ptrCast(self),
            .memory_properties = &self.memory_properties,
            .non_coherent_atom_size = 1,
            .max_buffer_size = 4096,
            .handles = handles,
        };
    }

    fn fromDevice(target: vulkan.VkDevice) *NativeFixture {
        return @ptrCast(@alignCast(target.?));
    }

    fn createImage(
        target: vulkan.VkDevice,
        info: [*c]const vulkan.VkImageCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkImage,
    ) callconv(.c) vulkan.VkResult {
        fromDevice(target).images_created += 1;
        fromDevice(target).image_usage = info.*.usage;
        out.* = @ptrFromInt(1);
        return vulkan.VK_SUCCESS;
    }

    fn destroyImage(
        target: vulkan.VkDevice,
        _: vulkan.VkImage,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(target).images_destroyed += 1;
    }

    fn requirements(
        _: vulkan.VkDevice,
        _: vulkan.VkImage,
        out: [*c]vulkan.VkMemoryRequirements,
    ) callconv(.c) void {
        out.* = .{ .size = 64, .alignment = 1, .memoryTypeBits = 1 };
    }

    fn allocateMemory(
        target: vulkan.VkDevice,
        _: [*c]const vulkan.VkMemoryAllocateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkDeviceMemory,
    ) callconv(.c) vulkan.VkResult {
        fromDevice(target).memories_allocated += 1;
        out.* = @ptrFromInt(2);
        return vulkan.VK_SUCCESS;
    }

    fn freeMemory(
        target: vulkan.VkDevice,
        _: vulkan.VkDeviceMemory,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(target).memories_freed += 1;
    }

    fn bindMemory(
        target: vulkan.VkDevice,
        _: vulkan.VkImage,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
    ) callconv(.c) vulkan.VkResult {
        return if (fromDevice(target).fail_bind)
            vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY
        else
            vulkan.VK_SUCCESS;
    }

    fn barrier(
        command_buffer: vulkan.VkCommandBuffer,
        src_stages: vulkan.VkPipelineStageFlags,
        dst_stages: vulkan.VkPipelineStageFlags,
        _: vulkan.VkDependencyFlags,
        _: u32,
        _: [*c]const vulkan.VkMemoryBarrier,
        _: u32,
        _: [*c]const vulkan.VkBufferMemoryBarrier,
        image_count: u32,
        images: [*c]const vulkan.VkImageMemoryBarrier,
    ) callconv(.c) void {
        const self: *NativeFixture = @ptrCast(@alignCast(command_buffer.?));
        if (image_count != 0) {
            std.debug.assert(image_count == 1);
            self.barriers_recorded += 1;
            self.old_layout = images[0].oldLayout;
            self.new_layout = images[0].newLayout;
            self.src_stages = src_stages;
            self.dst_stages = dst_stages;
            self.src_access = images[0].srcAccessMask;
            self.dst_access = images[0].dstAccessMask;
            self.aspect_mask = images[0].subresourceRange.aspectMask;
        }
    }

    fn createView(
        target: vulkan.VkDevice,
        info: [*c]const vulkan.VkImageViewCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkImageView,
    ) callconv(.c) vulkan.VkResult {
        const fixture = fromDevice(target);
        fixture.views_created += 1;
        fixture.last_view_type = info.*.viewType;
        fixture.last_view_conversion = null;
        var next: ?*const vulkan.VkBaseInStructure = @ptrCast(@alignCast(info.*.pNext));
        for (0..4) |_| {
            const chain = next orelse break;
            if (chain.sType == vulkan.VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO) {
                const conversion: *const vulkan.VkSamplerYcbcrConversionInfo = @ptrCast(chain);
                fixture.last_view_conversion = conversion.conversion;
            }
            next = chain.pNext;
        }
        out.* = @ptrFromInt(3 + fixture.views_created);
        return if (fixture.fail_view) vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY else vulkan.VK_SUCCESS;
    }

    fn destroyView(
        target: vulkan.VkDevice,
        _: vulkan.VkImageView,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(target).views_destroyed += 1;
    }

    fn clearColor(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkImage,
        _: vulkan.VkImageLayout,
        _: [*c]const vulkan.VkClearColorValue,
        _: u32,
        _: [*c]const vulkan.VkImageSubresourceRange,
    ) callconv(.c) void {
        const self: *NativeFixture = @ptrCast(@alignCast(command_buffer.?));
        self.clears_recorded += 1;
    }

    fn clearDepth(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkImage,
        _: vulkan.VkImageLayout,
        _: [*c]const vulkan.VkClearDepthStencilValue,
        _: u32,
        _: [*c]const vulkan.VkImageSubresourceRange,
    ) callconv(.c) void {
        const self: *NativeFixture = @ptrCast(@alignCast(command_buffer.?));
        self.clears_recorded += 1;
    }

    fn createBuffer(
        _: vulkan.VkDevice,
        _: [*c]const vulkan.VkBufferCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkBuffer,
    ) callconv(.c) vulkan.VkResult {
        out.* = @ptrFromInt(7);
        return vulkan.VK_SUCCESS;
    }

    fn destroyBuffer(
        _: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}

    fn bufferRequirements(
        _: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        out: [*c]vulkan.VkMemoryRequirements,
    ) callconv(.c) void {
        out.* = .{ .size = 256, .alignment = 1, .memoryTypeBits = 2 };
    }

    fn bindBufferMemory(
        _: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
    ) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }

    fn mapMemory(
        target: vulkan.VkDevice,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
        _: vulkan.VkDeviceSize,
        _: vulkan.VkMemoryMapFlags,
        out: [*c]?*anyopaque,
    ) callconv(.c) vulkan.VkResult {
        out.* = &fromDevice(target).staging_bytes;
        return vulkan.VK_SUCCESS;
    }

    fn unmapMemory(_: vulkan.VkDevice, _: vulkan.VkDeviceMemory) callconv(.c) void {}

    fn copyBufferToImage(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkBuffer,
        _: vulkan.VkImage,
        layout: vulkan.VkImageLayout,
        count: u32,
        regions: [*c]const vulkan.VkBufferImageCopy,
    ) callconv(.c) void {
        const self: *NativeFixture = @ptrCast(@alignCast(command_buffer.?));
        std.debug.assert(count == 1);
        std.debug.assert(layout == vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        std.debug.assert(regions[0].bufferOffset == 0);
        std.debug.assert(regions[0].bufferRowLength == 0);
        std.debug.assert(regions[0].imageExtent.width ==
            (@as(u32, 4) >> @intCast(regions[0].imageSubresource.mipLevel)));
        std.debug.assert(regions[0].imageExtent.height == regions[0].imageExtent.width);
        std.debug.assert(regions[0].imageExtent.depth == 1);
        self.buffer_image_copies += 1;
    }

    fn waitIdle(_: vulkan.VkDevice) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }

    fn destroyFence(
        _: vulkan.VkDevice,
        _: vulkan.VkFence,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}
};

fn fixtureProcs() dispatch.DeviceProcs {
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_image = &NativeFixture.createImage;
    procs.destroy_image = &NativeFixture.destroyImage;
    procs.get_image_memory_requirements = &NativeFixture.requirements;
    procs.allocate_memory = &NativeFixture.allocateMemory;
    procs.free_memory = &NativeFixture.freeMemory;
    procs.bind_image_memory = &NativeFixture.bindMemory;
    procs.cmd_pipeline_barrier = &NativeFixture.barrier;
    procs.create_image_view = &NativeFixture.createView;
    procs.destroy_image_view = &NativeFixture.destroyView;
    procs.cmd_clear_color_image = &NativeFixture.clearColor;
    procs.cmd_clear_depth_stencil_image = &NativeFixture.clearDepth;
    procs.create_buffer = &NativeFixture.createBuffer;
    procs.destroy_buffer = &NativeFixture.destroyBuffer;
    procs.get_buffer_memory_requirements = &NativeFixture.bufferRequirements;
    procs.bind_buffer_memory = &NativeFixture.bindBufferMemory;
    procs.map_memory = &NativeFixture.mapMemory;
    procs.unmap_memory = &NativeFixture.unmapMemory;
    procs.cmd_copy_buffer_to_image = &NativeFixture.copyBufferToImage;
    procs.device_wait_idle = &NativeFixture.waitIdle;
    procs.destroy_fence = &NativeFixture.destroyFence;
    procs.create_sampler = &HardwareFixtureProcs.createSampler;
    procs.destroy_sampler = &HardwareFixtureProcs.destroySampler;
    procs.create_sampler_ycbcr_conversion = &HardwareFixtureProcs.createConversion;
    procs.destroy_sampler_ycbcr_conversion = &HardwareFixtureProcs.destroyConversion;
    return procs;
}

test "native image stays owned until its last native view is destroyed" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    var view: TextureView = undefined;
    try nativeFixtureView(&view, &texture, ._2d, guard, callback_io);
    defer view.header.releaseUserLocked(guard, callback_io) catch unreachable;
    try std.testing.expectEqual(@as(u32, 2), texture.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), texture.header.user_reference_count);
    try std.testing.expectEqual(@as(u64, 3), object_list.total_reference_count);
    try std.testing.expectEqual(@as(u64, 2), object_list.user_reference_count);
    try view.initializeNative(guard);
    texture.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    try std.testing.expectEqual(@as(u32, 0), fixture.images_destroyed);
    view.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    try std.testing.expect(!view.parent_lease_held);
    try std.testing.expectEqual(@as(u32, 1), texture.header.reference_count);
    view.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    texture.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    try std.testing.expectEqual(@as(u64, 2), object_list.total_reference_count);
    try std.testing.expectEqual(@as(u64, 2), object_list.user_reference_count);
    try std.testing.expectEqual(@as(u32, 1), fixture.views_destroyed);
    try std.testing.expectEqual(@as(u32, 1), fixture.images_destroyed);
    try std.testing.expect(handles.isEmpty());
}

test "native lazy clear does not clear an initialized subresource twice" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var initialized = [_]bool{ false, false };
    texture.initialized = &initialized;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    const range: SubresourceRange = .{
        .aspects = .{ .color = 1 },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    try texture.ensureSubresourceContentInitialized(guard, undefined, recording, range);
    try texture.ensureSubresourceContentInitialized(guard, undefined, recording, range);
    try std.testing.expectEqual(@as(u32, 1), fixture.clears_recorded);
    try std.testing.expect(initialized[0]);
    try std.testing.expect(!initialized[1]);
}

test "canonical asymmetric compressed blocks size rows in block units" {
    var table: canonical_format.FormatTable = undefined;
    canonical_format.buildFormatTable(.{}, &table);
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    texture.format_info = &table[canonical_format.computeFormatIndex(.astc_5x4_unorm).?];
    texture.base_size = .{ .width = 10, .height = 8, .depth_or_array_layers = 1 };
    try std.testing.expectEqual(@as(usize, 32), texture.levelRowByteSize(guard, 0));
    try std.testing.expectEqual(@as(usize, 2), texture.levelRowCount(guard, 0));
    try std.testing.expectEqual(@as(usize, 64), texture.imageByteSize(guard, 0));
}

test "texture barrier batch allocation fails before native state changes" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    var batch: BarrierBatch = .{};
    defer batch.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, texture.transitionInto(
        failing.allocator(),
        guard,
        texture.getAllSubresources(guard),
        .{ .copy_dst = true },
        .none,
        &batch,
    ));
    try std.testing.expectEqual(@as(usize, 0), batch.image_barriers.items.len);
    try std.testing.expect(texture.native.?.states[0].layout == vulkan.VK_IMAGE_LAYOUT_UNDEFINED);
    try texture.transitionInto(
        std.testing.allocator,
        guard,
        texture.getAllSubresources(guard),
        .{ .copy_dst = true },
        .none,
        &batch,
    );
    try std.testing.expectEqual(@as(usize, 2), batch.image_barriers.items.len);
    try std.testing.expectEqual(@as(u32, 0), fixture.barriers_recorded);
}

test "3D attachment slices own cached 2D views and roll back allocation failure" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    texture.dimension = ._3d;
    texture.base_size.depth_or_array_layers = 3;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    var view: TextureView = undefined;
    try nativeFixtureView(&view, &texture, ._3d, guard, callback_io);
    defer view.header.releaseUserLocked(guard, callback_io) catch unreachable;
    try view.initializeNative(guard);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, view.getAttachmentHandle(failing.allocator(), guard, 1));
    try std.testing.expectEqual(@as(u32, 1), fixture.views_created);
    const slice = try view.getAttachmentHandle(try texture.getNativeAllocator(guard), guard, 1);
    try std.testing.expect(fixture.last_view_type == vulkan.VK_IMAGE_VIEW_TYPE_2D);
    try std.testing.expectEqual(@as(u32, 2), fixture.views_created);
    try std.testing.expectEqual(
        slice,
        try view.getAttachmentHandle(try texture.getNativeAllocator(guard), guard, 1),
    );
    try std.testing.expectEqual(@as(u32, 2), fixture.views_created);
    try std.testing.expectError(
        error.TextureNativeRangeInvalid,
        view.getAttachmentHandle(try texture.getNativeAllocator(guard), guard, 3),
    );
}

test "3D attachment cache survives replay scratch teardown" {
    const attachment = @import("../command/attachment_state.zig");
    const attachment_constants = @import("../command/constants.zig");
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var arena = object.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &test_device_mutex.mutex });
    var held = object.ObjectGuard.lockUncancelable(callback_io, arena.objectList());
    const guard = &held;
    defer held.unlock(callback_io);
    defer arena.deinit(std.testing.allocator, guard) catch @panic("texture attachment fixture references leaked");
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    texture.dimension = ._3d;
    texture.base_size.depth_or_array_layers = 3;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try std.testing.expectError(error.TextureNativeNotInitialized, texture.getNativeAllocator(guard));
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    var view: TextureView = undefined;
    try nativeFixtureView(&view, &texture, ._3d, guard, callback_io);
    defer view.header.releaseUserLocked(guard, callback_io) catch unreachable;
    try view.initializeNative(guard);
    const attachment_value = try attachment.AttachmentState.fromRenderPass(.{
        .colors = &.{.{
            .view = .{
                .format = @intFromEnum(view.getFormat(guard)),
                .sample_count = texture.getSampleCount(guard),
                .aspects = view.getAspects(guard).toFlags(),
            },
            .resolve_target = null,
            .expands_resolve = false,
        }},
        .depth_stencil = null,
        .pls = null,
    }, .{
        .max_color_attachments = attachment_constants.max_color_attachments,
        .max_storage_attachments = attachment_constants.max_pls_slots,
        .max_pls_bytes = attachment_constants.max_pls_size,
    });
    const attachment_state = try arena.create(std.testing.allocator, guard, attachment.CanonicalAttachmentState, .{
        .kind = .attachment_state,
        .initial_reference = .user,
    });
    attachment_state.* = .{ .header = attachment_state.header, .value = attachment_value };
    attachment_state.header.attach(guard, callback_io);
    defer attachment_state.header.releaseUserLocked(guard, callback_io) catch unreachable;

    var replay_scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    var scratch_destroyed = false;
    defer if (!scratch_destroyed) replay_scratch.deinit();
    const begin = try replay_scratch.allocator().create(commands.BeginRenderPassCmd);
    begin.* = .{
        .width = texture.base_size.width,
        .height = texture.base_size.height,
        .attachment_state = attachment_state,
    };
    begin.color_attachments[0] = .{
        .view = &view,
        .depth_slice = 1,
        .load_op = .clear,
        .store_op = .store,
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    const frame = try command_replay.buildFramebufferCacheQuery(
        guard,
        begin.*,
        .{ .unique_id = 1 },
    );
    const slice = frame.attachments[0];
    const owner = try texture.getNativeAllocator(guard);
    try std.testing.expectEqual(@as(u32, 2), fixture.views_created);
    replay_scratch.deinit();
    scratch_destroyed = true;
    try std.testing.expectEqual(slice, try view.getAttachmentHandle(owner, guard, 1));
    try std.testing.expectEqual(@as(u32, 2), fixture.views_created);
    const other_slice = try view.getAttachmentHandle(owner, guard, 2);
    try std.testing.expect(other_slice != slice);
    try std.testing.expectEqual(@as(u32, 3), fixture.views_created);

    texture.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    try std.testing.expectError(error.TextureNativeDestroyed, texture.getNativeAllocator(guard));
    try std.testing.expectEqual(@as(u32, 0), fixture.images_destroyed);
    view.header.retirePayloadLocked(guard, callback_io, .early_destroy);
    try std.testing.expectEqual(@as(u32, 3), fixture.views_destroyed);
    try std.testing.expectEqual(@as(u32, 1), fixture.images_destroyed);
    try std.testing.expectEqual(@as(u32, 1), fixture.memories_freed);
    try std.testing.expect(handles.isEmpty());
}

test "texture rejects a feature-disabled canonical format row" {
    var table: canonical_format.FormatTable = undefined;
    canonical_format.buildFormatTable(.{}, &table);
    try std.testing.expectError(error.TextureFormatUnsupported, validateTextureDescriptor(.{
        .descriptor = .{
            .usage = .{ .texture_binding = true },
            .format = .bc1_rgba_unorm,
            .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
        },
        .format_info = &table[canonical_format.computeFormatIndex(.bc1_rgba_unorm).?],
        .limits = .{
            .max_texture_dimension_1d = 8192,
            .max_texture_dimension_2d = 8192,
            .max_texture_dimension_3d = 2048,
            .max_texture_array_layers = 256,
        },
    }));
}

test "texture rejects a canonical row that does not match its descriptor" {
    var table: canonical_format.FormatTable = undefined;
    canonical_format.buildFormatTable(.{}, &table);
    try std.testing.expectError(error.TextureFormatMetadataMismatch, validateTextureDescriptor(.{
        .descriptor = .{
            .usage = .{ .texture_binding = true },
            .format = .rgba8_unorm,
            .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
        },
        .format_info = &table[canonical_format.computeFormatIndex(.bgra8_unorm).?],
        .limits = .{
            .max_texture_dimension_1d = 8192,
            .max_texture_dimension_2d = 8192,
            .max_texture_dimension_3d = 2048,
            .max_texture_array_layers = 256,
        },
    }));
}

test "failed native view creation cannot publish an undefined driver output" {
    var fixture: NativeFixture = .{ .fail_view = true };
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    var view: TextureView = undefined;
    try nativeFixtureView(&view, &texture, ._2d, guard, callback_io);
    defer view.header.releaseUserLocked(guard, callback_io) catch unreachable;
    try std.testing.expectError(error.OutOfDeviceMemory, view.initializeNative(guard));
    try std.testing.expect(view.native_view == null);
    try std.testing.expectEqual(@as(usize, 0), texture.native.?.view_count);
    try std.testing.expectEqual(@as(u32, 0), handles.countOf(.image_view));
}

test "multisampled native color images clear without a single-sample restriction" {
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    texture.sample_count = 4;
    texture.mip_level_count = 1;
    var initialized = [_]bool{false};
    texture.initialized = &initialized;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    try texture.ensureSubresourceContentInitialized(guard, undefined, .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    }, texture.getAllSubresources(guard));
    try std.testing.expectEqual(@as(u32, 1), fixture.clears_recorded);
    try std.testing.expect(initialized[0]);
}

test "compressed native lazy initialization uses queue-owned zero staging" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compressedInitializationRoundTrip,
        .{},
    );
}

test "compressed initialization staging survives recording scratch teardown" {
    try compressedInitializationRoundTrip(std.testing.allocator);
}

fn compressedInitializationRoundTrip(allocator: std.mem.Allocator) !void {
    // SAFETY: buildFormatTable writes all 109 canonical rows before the enabled bc1 row is selected.
    var table: canonical_format.FormatTable = undefined;
    var enabled: features.FeaturesSet = .{};
    enabled.enable(.texture_compression_bc);
    canonical_format.buildFormatTable(enabled, &table);
    var fixture: NativeFixture = .{};
    const callback_io = std.testing.io;
    var test_device_mutex: platform.DeviceMutex = .{};
    var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    const guard = &held;
    defer held.unlock(callback_io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, callback_io);
    defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
    texture.format_info = &table[canonical_format.computeFormatIndex(.bc1_rgba_unorm).?];
    texture.internal_usage = .{ .texture_binding = true, .copy_src = true };
    texture.base_size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 };
    var initialized = [_]bool{ false, false };
    texture.initialized = &initialized;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    const context = fixture.context(&procs, &handles);
    try texture.initializeNative(std.testing.allocator, guard, context);
    var queue: queue_mod.Queue = .{
        .context = .{
            .allocator = allocator,
            .dispatch = context.dispatch,
            .vk_device = context.vk_device,
            .vk_queue = null,
            .queue_family_index = 0,
            .memory_properties = context.memory_properties,
            .handles = &handles,
        },
        .device_mutex = &test_device_mutex,
        .timeline = .{},
    };
    var queue_live = true;
    defer if (queue_live) {
        held.unlock(callback_io);
        queue.deinit(callback_io, &object_list) catch @panic("texture staging fixture teardown failed");
        held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    };
    {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        const recording = try scratch.allocator().create(buffer_mod.Recording);
        recording.* = .{
            .command_buffer = @ptrCast(&fixture),
            .pending_serial = 1,
        };
        texture.ensureSubresourceContentInitialized(
            guard,
            &queue,
            recording.*,
            texture.getAllSubresources(guard),
        ) catch |err| {
            try std.testing.expect(!initialized[0]);
            try std.testing.expect(!initialized[1]);
            return err;
        };
        const retained = queue.temporary_buffers.items[0];
        try std.testing.expect(retained.allocator.ptr == allocator.ptr);
        try std.testing.expect(retained.allocator.vtable == allocator.vtable);
        try std.testing.expect(retained.buffer.device.allocator.ptr == allocator.ptr);
        try std.testing.expect(retained.buffer.device.allocator.vtable == allocator.vtable);
        try std.testing.expectEqual(@as(u64, 0), retained.serial);
        try std.testing.expect(scratch.reset(.free_all));
    }
    // Queue retention and teardown must remain safe after scratch is gone.
    try std.testing.expect(initialized[0]);
    try std.testing.expect(initialized[1]);
    try std.testing.expectEqual(@as(u32, 2), fixture.buffer_image_copies);
    try std.testing.expectEqual(@as(u32, 0), fixture.clears_recorded);
    try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
    const staging = queue.temporary_buffers.items[0].buffer;
    for (staging.mapped.?[0..@intCast(staging.size)]) |byte|
        try std.testing.expectEqual(@as(u8, 0), byte);
    try texture.ensureSubresourceContentInitialized(
        guard,
        &queue,
        .{ .command_buffer = @ptrCast(&fixture), .pending_serial = 1 },
        texture.getAllSubresources(guard),
    );
    try std.testing.expectEqual(@as(u32, 2), fixture.buffer_image_copies);
    try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
    try std.testing.expectEqual(@as(u32, 1), handles.countOf(.buffer));
    try std.testing.expectEqual(@as(u32, 0), fixture.memories_freed);
    held.unlock(callback_io);
    const cleanup_result = queue.deinit(callback_io, &object_list);
    held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
    try cleanup_result;
    queue_live = false;
    try std.testing.expectEqual(@as(u32, 0), handles.countOf(.buffer));
    try std.testing.expectEqual(@as(u32, 1), fixture.memories_freed);
}

test "mixed depth stencil attachments preserve sampled read-only aspect scopes" {
    const cases = [_]struct {
        sampled_depth: bool,
        shader_stage: buffer_mod.ShaderStage,
        shader_stage_mask: vulkan.VkPipelineStageFlags,
        layout: vulkan.VkImageLayout,
    }{
        .{
            .sampled_depth = true,
            .shader_stage = .{ .vertex = true },
            .shader_stage_mask = vulkan.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,
            .layout = vulkan.VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_STENCIL_ATTACHMENT_OPTIMAL,
        },
        .{
            .sampled_depth = false,
            .shader_stage = .{ .fragment = true },
            .shader_stage_mask = vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .layout = vulkan.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_STENCIL_READ_ONLY_OPTIMAL,
        },
    };
    for (cases) |case| {
        var table: canonical_format.FormatTable = undefined;
        canonical_format.buildFormatTable(.{}, &table);
        var fixture: NativeFixture = .{};
        const callback_io = std.testing.io;
        var test_device_mutex: platform.DeviceMutex = .{};
        var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
        var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
        const guard = &held;
        defer held.unlock(callback_io);
        var texture: Texture = undefined;
        nativeFixtureTexture(&texture, guard, callback_io);
        defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
        texture.format_info = &table[canonical_format.computeFormatIndex(.depth24_plus_stencil8).?];
        texture.mip_level_count = 1;
        texture.internal_usage.texture_binding = true;
        var handles: vulkan_device.HandleSet = .{};
        var procs = fixtureProcs();
        try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
        const recording: buffer_mod.Recording = .{
            .command_buffer = @ptrCast(&fixture),
            .pending_serial = 1,
        };
        const whole = texture.getAllSubresources(guard);
        var sampled = whole;
        sampled.aspects = if (case.sampled_depth) .{ .depth = 1 } else .{ .stencil = 1 };
        try texture.transition(guard, recording, sampled, .{ .texture_binding = true }, case.shader_stage);
        const before_attachment = fixture.barriers_recorded;
        try texture.transitionRenderAttachment(guard, recording, whole, .{
            .depth_read_only = case.sampled_depth,
            .stencil_read_only = !case.sampled_depth,
        });
        const stages: vulkan.VkPipelineStageFlags = case.shader_stage_mask |
            vulkan.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
            vulkan.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        const access: vulkan.VkAccessFlags = vulkan.VK_ACCESS_SHADER_READ_BIT |
            vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
            vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        const aspects: vulkan.VkImageAspectFlags = vulkan.VK_IMAGE_ASPECT_DEPTH_BIT |
            vulkan.VK_IMAGE_ASPECT_STENCIL_BIT;
        try std.testing.expectEqual(before_attachment + 1, fixture.barriers_recorded);
        try std.testing.expectEqual(case.layout, fixture.new_layout);
        try std.testing.expectEqual(aspects, fixture.aspect_mask);
        try std.testing.expectEqual(stages, fixture.dst_stages);
        try std.testing.expectEqual(access, fixture.dst_access);
        try texture.transition(guard, recording, whole, .{ .copy_src = true }, .none);
        try std.testing.expectEqual(before_attachment + 2, fixture.barriers_recorded);
        try std.testing.expectEqual(case.layout, fixture.old_layout);
        try std.testing.expectEqual(aspects, fixture.aspect_mask);
        try std.testing.expectEqual(stages, fixture.src_stages);
        try std.testing.expectEqual(access, fixture.src_access);
    }
}

test "writable depth stencil attachments discard prior sampled destination scopes" {
    const cases = [_]struct {
        sampled_depth: bool,
        absent_read_only: bool,
    }{
        .{ .sampled_depth = true, .absent_read_only = false },
        .{ .sampled_depth = false, .absent_read_only = false },
        .{ .sampled_depth = true, .absent_read_only = true },
        .{ .sampled_depth = false, .absent_read_only = true },
    };
    for (cases) |case| {
        const sampled_depth = case.sampled_depth;
        var table: canonical_format.FormatTable = undefined;
        canonical_format.buildFormatTable(.{}, &table);
        var fixture: NativeFixture = .{};
        const callback_io = std.testing.io;
        var test_device_mutex: platform.DeviceMutex = .{};
        var object_list: object.ObjectList = .{ .mutex = &test_device_mutex.mutex };
        var held = object.ObjectGuard.lockUncancelable(callback_io, &object_list);
        const guard = &held;
        defer held.unlock(callback_io);
        var texture: Texture = undefined;
        nativeFixtureTexture(&texture, guard, callback_io);
        defer texture.header.releaseUserLocked(guard, callback_io) catch unreachable;
        texture.format_info = &table[canonical_format.computeFormatIndex(.depth24_plus_stencil8).?];
        texture.mip_level_count = 1;
        texture.internal_usage.texture_binding = true;
        var handles: vulkan_device.HandleSet = .{};
        var procs = fixtureProcs();
        try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
        const recording: buffer_mod.Recording = .{
            .command_buffer = @ptrCast(&fixture),
            .pending_serial = 1,
        };
        const whole = texture.getAllSubresources(guard);
        var sampled = whole;
        sampled.aspects = if (sampled_depth) .{ .depth = 1 } else .{ .stencil = 1 };
        const shader_stage: buffer_mod.ShaderStage = if (sampled_depth)
            .{ .vertex = true }
        else
            .{ .fragment = true };
        try texture.transition(guard, recording, sampled, .{ .texture_binding = true }, shader_stage);
        const before_attachment = fixture.barriers_recorded;
        const attachment_range = if (case.absent_read_only) sampled else whole;
        try texture.transitionRenderAttachment(guard, recording, attachment_range, .{
            .depth_read_only = case.absent_read_only and !sampled_depth,
            .stencil_read_only = case.absent_read_only and sampled_depth,
        });
        const stages: vulkan.VkPipelineStageFlags = vulkan.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
            vulkan.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        const access: vulkan.VkAccessFlags = vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
            vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        const aspects: vulkan.VkImageAspectFlags = vulkan.VK_IMAGE_ASPECT_DEPTH_BIT |
            vulkan.VK_IMAGE_ASPECT_STENCIL_BIT;
        try std.testing.expectEqual(before_attachment + 1, fixture.barriers_recorded);
        const layout: vulkan.VkImageLayout = if (!case.absent_read_only)
            vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        else if (sampled_depth)
            vulkan.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_STENCIL_READ_ONLY_OPTIMAL
        else
            vulkan.VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_STENCIL_ATTACHMENT_OPTIMAL;
        try std.testing.expectEqual(layout, fixture.new_layout);
        try std.testing.expectEqual(aspects, fixture.aspect_mask);
        try std.testing.expectEqual(stages, fixture.dst_stages);
        try std.testing.expectEqual(access, fixture.dst_access);
        try texture.transition(guard, recording, whole, .{ .copy_src = true }, .none);
        try std.testing.expectEqual(before_attachment + 2, fixture.barriers_recorded);
        try std.testing.expectEqual(stages, fixture.src_stages);
        try std.testing.expectEqual(access, fixture.src_access);
    }
}

test "texture factories retain the parent until view retirement and roll back allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        textureFactoryLifetimeRoundTrip,
        .{},
    );
}

fn textureFactoryLifetimeRoundTrip(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var dev = device.Device.init(allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = struct {
            fn unexpected(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core_errors.ErrorView) void {
                @panic("texture factory fixture received an uncaptured error");
            }
        }.unexpected,
    });
    const object_list = dev.arena.objectList();
    var held = object.ObjectGuard.lockUncancelable(io, object_list);
    const guard = &held;
    defer held.unlock(io);
    defer dev.deinit(allocator, guard) catch @panic("texture factory fixture retained a reference");

    const parent_handle = Texture.create(allocator, io, guard, &dev, .{
        .descriptor = .{
            .usage = .{ .texture_binding = true, .render_attachment = true },
            .format = .rgba8_unorm,
            .size = .{ .width = 64, .height = 64, .depth_or_array_layers = 1 },
        },
        .format_info = &native_fixture_format,
        .limits = .{
            .max_texture_dimension_1d = 8192,
            .max_texture_dimension_2d = 8192,
            .max_texture_dimension_3d = 2048,
            .max_texture_array_layers = 256,
        },
    }) catch |err| {
        try std.testing.expectEqual(@as(u64, 0), object_list.total_reference_count);
        try std.testing.expectEqual(@as(u64, 0), object_list.user_reference_count);
        try std.testing.expectEqual(@as(usize, 0), object_list.tracked_count);
        return err;
    };
    const parent = try resolveTexture(&dev, guard, parent_handle);
    var parent_user_held = true;
    defer if (parent_user_held) parent.header.releaseUserLocked(guard, io) catch unreachable;
    const view_label: [4096]u8 = @splat('v');
    const view_handle = Texture.createView(allocator, io, guard, &dev, parent_handle, .{
        .descriptor = .{
            .label = &view_label,
            .format = .rgba8_unorm,
            .dimension = ._2d,
        },
        .format_info = &native_fixture_format,
    }) catch |err| {
        try std.testing.expectEqual(@as(u32, 1), parent.header.reference_count);
        try std.testing.expectEqual(@as(u32, 1), parent.header.user_reference_count);
        try std.testing.expectEqual(@as(u64, 1), object_list.total_reference_count);
        try std.testing.expectEqual(@as(u64, 1), object_list.user_reference_count);
        try std.testing.expectEqual(@as(usize, 1), object_list.tracked_count);
        return err;
    };
    const view = try resolveTextureView(&dev, guard, view_handle);
    defer view.header.releaseUserLocked(guard, io) catch unreachable;
    try std.testing.expect(view.parent_lease_held);
    try std.testing.expectEqual(@as(u32, 2), parent.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), parent.header.user_reference_count);
    try std.testing.expectEqual(@as(u64, 3), object_list.total_reference_count);
    try std.testing.expectEqual(@as(u64, 2), object_list.user_reference_count);
    try std.testing.expectEqual(@as(usize, 2), object_list.tracked_count);

    try parent.header.releaseUserLocked(guard, io);
    parent_user_held = false;
    try std.testing.expect(parent.header.isAlive(guard));
    try std.testing.expectEqual(@as(u32, 1), parent.header.reference_count);
    try std.testing.expectEqual(@as(u32, 0), parent.header.user_reference_count);
    view.header.retirePayloadLocked(guard, io, .early_destroy);
    view.header.retirePayloadLocked(guard, io, .early_destroy);
    try std.testing.expect(!view.parent_lease_held);
    try std.testing.expect(parent.header.state == .destroyed);
    try std.testing.expectEqual(@as(u32, 0), parent.header.reference_count);
    try std.testing.expectEqual(@as(u64, 1), object_list.total_reference_count);
    try std.testing.expectEqual(@as(u64, 1), object_list.user_reference_count);
    try std.testing.expectEqual(@as(usize, 1), object_list.tracked_count);
}

fn hardwareFixtureBackend(
    fixture: *NativeFixture,
    procs: *const dispatch.DeviceProcs,
    instance_procs: *const dispatch.InstanceProcs,
    handles: *vulkan_device.HandleSet,
    count: *u32,
) sampler_mod.NativeBackend {
    return .{
        .procs = procs,
        .handle = @ptrCast(fixture),
        .api_version = vulkan.VK_API_VERSION_1_3,
        .instance_procs = instance_procs,
        .physical = @ptrCast(fixture),
        .anisotropy_enabled = false,
        .max_anisotropy = 1,
        .y_cb_cr_enabled = true,
        .handles = handles,
        .sampler_allocation_count = count,
        .max_sampler_allocation_count = 16,
    };
}

fn hardwareFixtureInstanceProcs() dispatch.InstanceProcs {
    var procs = std.mem.zeroes(dispatch.InstanceProcs);
    procs.get_physical_device_format_properties = &HardwareFixtureProcs.formatProperties;
    procs.get_physical_device_image_format_properties = &HardwareFixtureProcs.imageProperties;
    procs.get_physical_device_image_format_properties2 = &HardwareFixtureProcs.imageProperties2;
    return procs;
}

const HardwareFixtureProcs = struct {
    fn formatProperties(
        physical: vulkan.VkPhysicalDevice,
        _: vulkan.VkFormat,
        out: [*c]vulkan.VkFormatProperties,
    ) callconv(.c) void {
        const fixture: *NativeFixture = @ptrCast(@alignCast(physical.?));
        out.* = .{ .optimalTilingFeatures = fixture.format_features };
    }

    fn imageProperties(
        physical: vulkan.VkPhysicalDevice,
        _: vulkan.VkFormat,
        _: vulkan.VkImageType,
        tiling: vulkan.VkImageTiling,
        usage: vulkan.VkImageUsageFlags,
        _: vulkan.VkImageCreateFlags,
        out: [*c]vulkan.VkImageFormatProperties,
    ) callconv(.c) vulkan.VkResult {
        const fixture: *NativeFixture = @ptrCast(@alignCast(physical.?));
        std.debug.assert(tiling == vulkan.VK_IMAGE_TILING_OPTIMAL);
        if (fixture.image_query_result != vulkan.VK_SUCCESS) return fixture.image_query_result;
        if ((!fixture.permit_sampled_image and
            usage & vulkan.VK_IMAGE_USAGE_SAMPLED_BIT != 0) or
            (!fixture.permit_attachment_image and
                usage & vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0))
            return vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED;
        out.* = .{
            .maxExtent = .{
                .width = fixture.image_max_extent,
                .height = fixture.image_max_extent,
                .depth = fixture.image_max_extent,
            },
            .maxMipLevels = 16,
            .maxArrayLayers = 2048,
            .sampleCounts = vulkan.VK_SAMPLE_COUNT_1_BIT | vulkan.VK_SAMPLE_COUNT_4_BIT,
            .maxResourceSize = fixture.image_max_resource_size,
        };
        return vulkan.VK_SUCCESS;
    }

    fn imageProperties2(
        physical: vulkan.VkPhysicalDevice,
        info: [*c]const vulkan.VkPhysicalDeviceImageFormatInfo2,
        out: [*c]vulkan.VkImageFormatProperties2,
    ) callconv(.c) vulkan.VkResult {
        const result = imageProperties(
            physical,
            info.*.format,
            info.*.type,
            info.*.tiling,
            info.*.usage,
            info.*.flags,
            &out.*.imageFormatProperties,
        );
        if (result != vulkan.VK_SUCCESS) return result;
        if (out.*.pNext) |next| {
            const conversion: *vulkan.VkSamplerYcbcrConversionImageFormatProperties =
                @ptrCast(@alignCast(next));
            conversion.combinedImageSamplerDescriptorCount =
                (native_y_cb_cr_format.traitsFor(info.*.format) catch unreachable).plane_count;
        }
        return vulkan.VK_SUCCESS;
    }

    fn createSampler(
        _: vulkan.VkDevice,
        _: [*c]const vulkan.VkSamplerCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkSampler,
    ) callconv(.c) vulkan.VkResult {
        out.* = @ptrFromInt(11);
        return vulkan.VK_SUCCESS;
    }

    fn destroySampler(
        _: vulkan.VkDevice,
        _: vulkan.VkSampler,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}

    fn createConversion(
        _: vulkan.VkDevice,
        _: [*c]const vulkan.VkSamplerYcbcrConversionCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkSamplerYcbcrConversion,
    ) callconv(.c) vulkan.VkResult {
        out.* = @ptrFromInt(12);
        return vulkan.VK_SUCCESS;
    }

    fn destroyConversion(
        _: vulkan.VkDevice,
        _: vulkan.VkSamplerYcbcrConversion,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}

    fn copyBufferToImage(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkBuffer,
        _: vulkan.VkImage,
        layout: vulkan.VkImageLayout,
        count: u32,
        regions: [*c]const vulkan.VkBufferImageCopy,
    ) callconv(.c) void {
        const fixture: *NativeFixture = @ptrCast(@alignCast(command_buffer.?));
        std.debug.assert(layout == vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        std.debug.assert(count <= 3);
        fixture.buffer_image_copies += count;
        for (0..count) |index| fixture.last_copy_regions[index] = regions[index];
    }
};

test "hardware YCbCr views own the actual parent and conversion sampler" {
    var fixture: NativeFixture = .{};
    var mutex: platform.DeviceMutex = .{};
    var arena = object.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex.mutex });
    var held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    const guard = &held;
    defer held.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, guard) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    var instance_procs = hardwareFixtureInstanceProcs();
    var sampler_count: u32 = 0;
    const backend = hardwareFixtureBackend(
        &fixture,
        &procs,
        &instance_procs,
        &handles,
        &sampler_count,
    );
    const conversion_sampler = try sampler_mod.Sampler.createNative(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        backend,
        .{ .y_cb_cr_vk_descriptor = .{
            .vk_format = vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        } },
    );
    var context = fixture.context(&procs, &handles);
    context.physical_device = backend.physical;
    context.dispatch.instance = &instance_procs;
    const parent = try Texture.createInternalYCbCr(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        context,
        .{ .size = .{ .width = 4, .height = 4 }, .conversion_sampler = conversion_sampler },
    );
    try std.testing.expectEqual(enums.TextureFormat.undefined_, parent.getFormat(guard));
    try std.testing.expectEqual(
        @as(vulkan.VkFormat, vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM),
        try parent.getNativeFormat(guard),
    );
    try std.testing.expectEqual(@as(u32, 2), try parent.getCombinedImageSamplerDescriptorCount(guard));
    try std.testing.expectEqual(@as(u32, 0), parent.format_info.aspect_info[0].block.byte_size);
    const view = try TextureView.createInternalYCbCr(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        parent,
        conversion_sampler,
    );
    try view.validateYCbCr(guard, conversion_sampler);
    instance_procs.get_physical_device_format_properties = null;
    instance_procs.get_physical_device_image_format_properties2 = null;
    try view.validateYCbCr(guard, conversion_sampler);
    try std.testing.expect(view.conversion_sampler == conversion_sampler);
    try std.testing.expectEqual(conversion_sampler.native.?.conversion, fixture.last_view_conversion);
    try std.testing.expectEqual(@as(u32, 2), conversion_sampler.header.reference_count);
    try std.testing.expectEqual(@as(u32, 2), parent.header.reference_count);
    try conversion_sampler.header.releaseUserLocked(guard, std.testing.io);
    try parent.header.releaseUserLocked(guard, std.testing.io);
    try std.testing.expect(try view.getHandle(guard) != null);
    try view.header.releaseUserLocked(guard, std.testing.io);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), sampler_count);
    try std.testing.expectEqual(@as(u64, 0), arena.objectList().total_reference_count);
}

test "hardware upload checks every plane before recording a copy" {
    var fixture: NativeFixture = .{};
    var mutex: platform.DeviceMutex = .{};
    var arena = object.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex.mutex });
    var held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    const guard = &held;
    defer held.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, guard) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    procs.cmd_copy_buffer_to_image = &HardwareFixtureProcs.copyBufferToImage;
    var instance_procs = hardwareFixtureInstanceProcs();
    var sampler_count: u32 = 0;
    const backend = hardwareFixtureBackend(
        &fixture,
        &procs,
        &instance_procs,
        &handles,
        &sampler_count,
    );
    const conversion_sampler = try sampler_mod.Sampler.createNative(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        backend,
        .{ .y_cb_cr_vk_descriptor = .{
            .vk_format = vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        } },
    );
    defer conversion_sampler.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    var context = fixture.context(&procs, &handles);
    context.physical_device = backend.physical;
    context.dispatch.instance = &instance_procs;
    const parent = try Texture.createInternalYCbCr(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        context,
        .{ .size = .{ .width = 4, .height = 4 }, .conversion_sampler = conversion_sampler },
    );
    defer parent.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    const source = try buffer_mod.Buffer.create(std.testing.allocator, context, .{
        .size = 24,
        .usage = .{ .copy_src = true },
    });
    defer source.destroy(std.testing.allocator) catch unreachable;
    source.is_data_initialized = true;
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    try std.testing.expectError(
        error.TextureNativeRangeInvalid,
        parent.uploadYCbCrPlanes(guard, recording, source, .{ 0, 20, 0 }),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.buffer_image_copies);
    try std.testing.expectEqual(@as(u32, 0), fixture.barriers_recorded);
    try std.testing.expect(!parent.initialized[0]);
    try parent.uploadYCbCrPlanes(guard, recording, source, .{ 0, 16, 0 });
    try std.testing.expect(parent.initialized[0]);
    try std.testing.expectEqual(@as(u32, 2), fixture.buffer_image_copies);
    try std.testing.expectEqual(
        @as(vulkan.VkImageAspectFlags, vulkan.VK_IMAGE_ASPECT_PLANE_0_BIT),
        fixture.last_copy_regions[0].imageSubresource.aspectMask,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkImageAspectFlags, vulkan.VK_IMAGE_ASPECT_PLANE_1_BIT),
        fixture.last_copy_regions[1].imageSubresource.aspectMask,
    );
    try std.testing.expectEqual(@as(u32, 2), fixture.last_copy_regions[1].imageExtent.width);
    try std.testing.expectEqual(@as(u32, 2), fixture.last_copy_regions[1].imageExtent.height);
    try parent.uploadYCbCrPlanes(guard, recording, source, .{ 1, 16, 0 });
    try std.testing.expectEqual(@as(u64, 1), fixture.last_copy_regions[0].bufferOffset);
    try std.testing.expectEqual(@as(u32, 0), fixture.clears_recorded);
}

fn hardwareAllocationRoundTrip(allocator: std.mem.Allocator) !void {
    var fixture: NativeFixture = .{};
    var mutex: platform.DeviceMutex = .{};
    var arena = object.ObjectArena.init(allocator, .{ .object_mutex = &mutex.mutex });
    var held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    const guard = &held;
    defer held.unlock(std.testing.io);
    defer arena.deinit(allocator, guard) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    defer std.debug.assert(handles.isEmpty());
    var procs = fixtureProcs();
    var instance_procs = hardwareFixtureInstanceProcs();
    var sampler_count: u32 = 0;
    const backend = hardwareFixtureBackend(
        &fixture,
        &procs,
        &instance_procs,
        &handles,
        &sampler_count,
    );
    const conversion_sampler = try sampler_mod.Sampler.createNative(
        allocator,
        std.testing.io,
        guard,
        &arena,
        backend,
        .{ .y_cb_cr_vk_descriptor = .{
            .vk_format = vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        } },
    );
    defer conversion_sampler.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    var context = fixture.context(&procs, &handles);
    context.allocator = allocator;
    context.physical_device = backend.physical;
    context.dispatch.instance = &instance_procs;
    const parent = Texture.createInternalYCbCr(
        allocator,
        std.testing.io,
        guard,
        &arena,
        context,
        .{ .size = .{ .width = 4, .height = 4 }, .conversion_sampler = conversion_sampler },
    ) catch |err| {
        try std.testing.expectEqual(@as(u64, 1), arena.objectList().total_reference_count);
        try std.testing.expectEqual(@as(u32, 0), handles.countOf(.image));
        try std.testing.expectEqual(@as(u32, 0), handles.countOf(.memory));
        try std.testing.expectEqual(fixture.images_created, fixture.images_destroyed);
        try std.testing.expectEqual(fixture.memories_allocated, fixture.memories_freed);
        return err;
    };
    defer parent.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    const view = TextureView.createInternalYCbCr(
        allocator,
        std.testing.io,
        guard,
        &arena,
        parent,
        conversion_sampler,
    ) catch |err| {
        try std.testing.expectEqual(@as(u64, 2), arena.objectList().total_reference_count);
        try std.testing.expectEqual(@as(u32, 1), parent.header.reference_count);
        try std.testing.expectEqual(@as(u32, 1), conversion_sampler.header.reference_count);
        return err;
    };
    defer view.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    try view.validateYCbCr(guard, conversion_sampler);
}

test "hardware texture and view fail-N rollback preserves real reference counts" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        hardwareAllocationRoundTrip,
        .{},
    );
}

test "hardware lazy initialization zeroes physical planes through queue staging" {
    var fixture: NativeFixture = .{};
    var mutex: platform.DeviceMutex = .{};
    var arena = object.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex.mutex });
    var held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    const guard = &held;
    defer held.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, guard) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    procs.cmd_copy_buffer_to_image = &HardwareFixtureProcs.copyBufferToImage;
    var instance_procs = hardwareFixtureInstanceProcs();
    var sampler_count: u32 = 0;
    const backend = hardwareFixtureBackend(
        &fixture,
        &procs,
        &instance_procs,
        &handles,
        &sampler_count,
    );
    const conversion_sampler = try sampler_mod.Sampler.createNative(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        backend,
        .{ .y_cb_cr_vk_descriptor = .{
            .vk_format = vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        } },
    );
    defer conversion_sampler.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    var context = fixture.context(&procs, &handles);
    context.physical_device = backend.physical;
    context.dispatch.instance = &instance_procs;
    const parent = try Texture.createInternalYCbCr(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        context,
        .{ .size = .{ .width = 4, .height = 4 }, .conversion_sampler = conversion_sampler },
    );
    defer parent.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    var queue: queue_mod.Queue = .{
        .context = .{
            .allocator = std.testing.allocator,
            .dispatch = context.dispatch,
            .vk_device = context.vk_device,
            .vk_queue = null,
            .queue_family_index = 0,
            .memory_properties = context.memory_properties,
            .handles = &handles,
        },
        .device_mutex = &mutex,
        .timeline = .{},
    };
    defer {
        held.unlock(std.testing.io);
        queue.deinit(std.testing.io, arena.objectList()) catch unreachable;
        held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    }
    const recording: buffer_mod.Recording = .{
        .command_buffer = @ptrCast(&fixture),
        .pending_serial = 1,
    };
    try parent.ensureSubresourceContentInitialized(
        guard,
        &queue,
        recording,
        parent.getAllSubresources(guard),
    );
    try std.testing.expect(parent.initialized[0]);
    try std.testing.expectEqual(@as(u32, 0), fixture.clears_recorded);
    try std.testing.expectEqual(@as(u32, 2), fixture.buffer_image_copies);
    try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
    const retained = queue.temporary_buffers.items[0];
    try std.testing.expectEqual(@as(u64, 0), retained.serial);
    try std.testing.expectEqual(@as(u64, 24), retained.buffer.size);
    for (fixture.staging_bytes[0..24]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try parent.ensureSubresourceContentInitialized(
        guard,
        &queue,
        recording,
        parent.getAllSubresources(guard),
    );
    try std.testing.expectEqual(@as(u32, 2), fixture.buffer_image_copies);
    try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
}

fn validateConversionSampler(
    guard: *const object.ObjectGuard,
    objects_list: *object.ObjectList,
    context: buffer_mod.Device,
    conversion_sampler: *sampler_mod.Sampler,
) NativeError!*const sampler_mod.NativePayload {
    if (conversion_sampler.header.tracking != objects_list)
        return error.TextureNativeDeviceMismatch;
    guard.assertOwns(objects_list);
    if (conversion_sampler.header.state != .alive or !conversion_sampler.header.isAlive(guard))
        return error.ResourceDestroyed;
    const payload = if (conversion_sampler.native) |*native| native else return error.TextureYCbCrSamplerMismatch;
    if (payload.sampler == null or payload.conversion == null)
        return error.TextureYCbCrSamplerMismatch;
    const conversion = conversion_sampler.key.y_cb_cr orelse return error.TextureYCbCrSamplerMismatch;
    if (conversion.external_format != 0) return error.SamplerYCbCrExternalFormatUnsupported;
    if (!payload.backend.y_cb_cr_enabled) return error.SamplerYCbCrUnsupported;
    if (context.vk_device != payload.backend.handle or
        context.physical_device != payload.backend.physical or
        context.handles != payload.backend.handles or
        context.dispatch.device != payload.backend.procs or
        context.dispatch.instance != payload.backend.instance_procs)
        return error.TextureNativeDeviceMismatch;
    return payload;
}

fn validateImageProperties(
    info: *const vulkan.VkImageCreateInfo,
    properties: vulkan.VkImageFormatProperties,
) NativeError!void {
    if (info.extent.width == 0 or info.extent.height == 0 or info.extent.depth == 0 or
        info.extent.width > properties.maxExtent.width or
        info.extent.height > properties.maxExtent.height or
        info.extent.depth > properties.maxExtent.depth or
        info.mipLevels == 0 or info.mipLevels > properties.maxMipLevels or
        info.arrayLayers == 0 or info.arrayLayers > properties.maxArrayLayers or
        properties.sampleCounts & info.samples == 0 or properties.maxResourceSize == 0)
        return error.TextureNativeRangeInvalid;
}

fn queryImageProperties(
    context: buffer_mod.Device,
    info: *const vulkan.VkImageCreateInfo,
) NativeError!vulkan.VkImageFormatProperties {
    const instance_procs = context.dispatch.instance orelse return error.MissingInstanceProc;
    const query = instance_procs.get_physical_device_image_format_properties orelse
        return error.MissingInstanceProc;
    var properties: vulkan.VkImageFormatProperties = .{};
    try dispatch.checkVkSuccess(query(
        context.physical_device,
        info.format,
        info.imageType,
        info.tiling,
        info.usage,
        info.flags,
        &properties,
    ));
    try validateImageProperties(info, properties);
    return properties;
}

fn reserveHelperUsage(
    self: *const Texture,
    context: buffer_mod.Device,
    info: *vulkan.VkImageCreateInfo,
) NativeError!bitmask.TextureUsage {
    var internal_usage = self.internal_usage;
    if (context.physical_device == null) return internal_usage;
    const instance_procs = context.dispatch.instance orelse return error.MissingInstanceProc;
    const query = instance_procs.get_physical_device_format_properties orelse
        return error.MissingInstanceProc;
    var properties: vulkan.VkFormatProperties = .{};
    query(context.physical_device, info.format, &properties);
    if (self.usage.copy_src and !internal_usage.texture_binding and
        properties.optimalTilingFeatures & vulkan.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT != 0)
    {
        var candidate = info.*;
        candidate.usage |= vulkan.VK_IMAGE_USAGE_SAMPLED_BIT;
        if (try helperImageSupported(context, &candidate)) {
            info.* = candidate;
            internal_usage.texture_binding = true;
        }
    }
    const attachment_feature: vulkan.VkFormatFeatureFlags = if (self.format_info.isColor())
        vulkan.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT
    else
        vulkan.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    if (self.usage.copy_dst and !internal_usage.render_attachment and self.dimension != ._1d and
        self.format_info.caps.renderable and
        properties.optimalTilingFeatures & attachment_feature != 0)
    {
        var candidate = info.*;
        candidate.usage |= if (self.format_info.isColor())
            @as(u32, vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
        else
            @as(u32, vulkan.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
        if (try helperImageSupported(context, &candidate)) {
            info.* = candidate;
            internal_usage.render_attachment = true;
        }
    }
    return internal_usage;
}

fn helperImageSupported(
    context: buffer_mod.Device,
    info: *const vulkan.VkImageCreateInfo,
) NativeError!bool {
    _ = queryImageProperties(context, info) catch |err| switch (err) {
        error.FormatNotSupported, error.TextureNativeRangeInvalid => return false,
        else => return err,
    };
    return true;
}

fn deriveViewInternalUsages(view: *const TextureView) bitmask.TextureUsage {
    const parent = view.texture;
    var usage = view.internal_usage;
    if (parent.internal_usage.texture_binding) usage.texture_binding = true;
    if (parent.internal_usage.render_attachment and view.dimension != ._1d and
        view.format_info.caps.renderable)
        usage.render_attachment = true;
    return usage;
}

test "copy-only textures reserve only supported native helper capabilities" {
    const cases = [_]struct { sampled: bool, attachment: bool }{
        .{ .sampled = true, .attachment = true },
        .{ .sampled = false, .attachment = true },
        .{ .sampled = true, .attachment = false },
    };
    for (cases) |case| {
        var fixture: NativeFixture = .{
            .permit_sampled_image = case.sampled,
            .permit_attachment_image = case.attachment,
        };
        var mutex: platform.DeviceMutex = .{};
        var objects_list: object.ObjectList = .{ .mutex = &mutex.mutex };
        var held = object.ObjectGuard.lockUncancelable(std.testing.io, &objects_list);
        const guard = &held;
        defer held.unlock(std.testing.io);
        var texture: Texture = undefined;
        nativeFixtureTexture(&texture, guard, std.testing.io);
        defer texture.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
        texture.usage = .{ .copy_src = true, .copy_dst = true };
        texture.internal_usage = texture.usage;
        var handles: vulkan_device.HandleSet = .{};
        var procs = fixtureProcs();
        var instance_procs = hardwareFixtureInstanceProcs();
        var context = fixture.context(&procs, &handles);
        context.physical_device = @ptrCast(&fixture);
        context.dispatch.instance = &instance_procs;
        try texture.initializeNative(std.testing.allocator, guard, context);
        try std.testing.expect(!texture.usage.texture_binding);
        try std.testing.expect(!texture.usage.render_attachment);
        try std.testing.expectEqual(case.sampled, texture.internal_usage.texture_binding);
        try std.testing.expectEqual(case.attachment, texture.internal_usage.render_attachment);
        try std.testing.expectEqual(
            case.sampled,
            fixture.image_usage & vulkan.VK_IMAGE_USAGE_SAMPLED_BIT != 0,
        );
        try std.testing.expectEqual(
            case.attachment,
            fixture.image_usage & vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0,
        );
        if (case.sampled or case.attachment) {
            var view: TextureView = undefined;
            try nativeFixtureView(&view, &texture, ._2d, guard, std.testing.io);
            defer view.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
            view.usage = .{};
            view.internal_usage = .{};
            try view.initializeNative(guard);
            try std.testing.expectEqual(case.sampled, view.internal_usage.texture_binding);
            try std.testing.expectEqual(case.attachment, view.internal_usage.render_attachment);
        }
    }
}

test "private view capabilities survive narrower public view permissions" {
    var fixture: NativeFixture = .{};
    var mutex: platform.DeviceMutex = .{};
    var objects_list: object.ObjectList = .{ .mutex = &mutex.mutex };
    var held = object.ObjectGuard.lockUncancelable(std.testing.io, &objects_list);
    const guard = &held;
    defer held.unlock(std.testing.io);
    var texture: Texture = undefined;
    nativeFixtureTexture(&texture, guard, std.testing.io);
    defer texture.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    texture.usage = .{
        .texture_binding = true,
        .render_attachment = true,
        .copy_dst = true,
    };
    texture.internal_usage = texture.usage;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    try texture.initializeNative(std.testing.allocator, guard, fixture.context(&procs, &handles));
    var view: TextureView = undefined;
    try nativeFixtureView(&view, &texture, ._2d, guard, std.testing.io);
    defer view.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    view.usage = .{ .texture_binding = true };
    view.internal_usage = view.usage;
    try view.initializeNative(guard);
    try std.testing.expect(!view.usage.render_attachment);
    try std.testing.expect(view.internal_usage.render_attachment);
    _ = try view.getAttachmentHandle(std.testing.allocator, guard, 0);
}

test "hardware queries and native creation failures roll back original owners" {
    const cases = [_]struct {
        query_result: vulkan.VkResult = vulkan.VK_SUCCESS,
        max_extent: u32 = 4096,
        max_resource_size: u64 = 1 << 30,
        fail_bind: bool = false,
        expected: NativeCreateError,
        created_images: u32 = 0,
    }{
        .{ .query_result = vulkan.VK_ERROR_DEVICE_LOST, .expected = error.DeviceLost },
        .{ .query_result = vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED, .expected = error.FormatNotSupported },
        .{ .max_extent = 2, .expected = error.TextureNativeRangeInvalid },
        .{
            .max_resource_size = 32,
            .expected = error.TextureNativeRangeInvalid,
            .created_images = 1,
        },
        .{
            .fail_bind = true,
            .expected = error.OutOfDeviceMemory,
            .created_images = 1,
        },
    };
    for (cases) |case| {
        var fixture: NativeFixture = .{
            .image_query_result = case.query_result,
            .image_max_extent = case.max_extent,
            .image_max_resource_size = case.max_resource_size,
            .fail_bind = case.fail_bind,
        };
        var mutex: platform.DeviceMutex = .{};
        var arena = object.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex.mutex });
        var held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
        const guard = &held;
        defer held.unlock(std.testing.io);
        defer arena.deinit(std.testing.allocator, guard) catch unreachable;
        var handles: vulkan_device.HandleSet = .{};
        var procs = fixtureProcs();
        var instance_procs = hardwareFixtureInstanceProcs();
        var sampler_count: u32 = 0;
        const backend = hardwareFixtureBackend(
            &fixture,
            &procs,
            &instance_procs,
            &handles,
            &sampler_count,
        );
        const conversion_sampler = try sampler_mod.Sampler.createNative(
            std.testing.allocator,
            std.testing.io,
            guard,
            &arena,
            backend,
            .{ .y_cb_cr_vk_descriptor = .{
                .vk_format = vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
            } },
        );
        defer conversion_sampler.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
        var context = fixture.context(&procs, &handles);
        context.physical_device = backend.physical;
        context.dispatch.instance = &instance_procs;
        try std.testing.expectError(
            case.expected,
            Texture.createInternalYCbCr(
                std.testing.allocator,
                std.testing.io,
                guard,
                &arena,
                context,
                .{
                    .size = .{ .width = 4, .height = 4 },
                    .conversion_sampler = conversion_sampler,
                },
            ),
        );
        try std.testing.expectEqual(@as(u64, 1), arena.objectList().total_reference_count);
        try std.testing.expectEqual(@as(u32, 1), conversion_sampler.header.reference_count);
        try std.testing.expectEqual(@as(u32, 0), handles.countOf(.image));
        try std.testing.expectEqual(@as(u32, 0), handles.countOf(.memory));
        try std.testing.expectEqual(case.created_images, fixture.images_created);
        try std.testing.expectEqual(fixture.images_created, fixture.images_destroyed);
        try std.testing.expectEqual(fixture.memories_allocated, fixture.memories_freed);
    }
}

test "failed hardware view creation releases both real constructor leases" {
    var fixture: NativeFixture = .{ .fail_view = true };
    var mutex: platform.DeviceMutex = .{};
    var arena = object.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &mutex.mutex });
    var held = object.ObjectGuard.lockUncancelable(std.testing.io, arena.objectList());
    const guard = &held;
    defer held.unlock(std.testing.io);
    defer arena.deinit(std.testing.allocator, guard) catch unreachable;
    var handles: vulkan_device.HandleSet = .{};
    var procs = fixtureProcs();
    var instance_procs = hardwareFixtureInstanceProcs();
    var sampler_count: u32 = 0;
    const backend = hardwareFixtureBackend(
        &fixture,
        &procs,
        &instance_procs,
        &handles,
        &sampler_count,
    );
    const conversion_sampler = try sampler_mod.Sampler.createNative(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        backend,
        .{ .y_cb_cr_vk_descriptor = .{
            .vk_format = vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        } },
    );
    defer conversion_sampler.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    var context = fixture.context(&procs, &handles);
    context.physical_device = backend.physical;
    context.dispatch.instance = &instance_procs;
    const parent = try Texture.createInternalYCbCr(
        std.testing.allocator,
        std.testing.io,
        guard,
        &arena,
        context,
        .{ .size = .{ .width = 4, .height = 4 }, .conversion_sampler = conversion_sampler },
    );
    defer parent.header.releaseUserLocked(guard, std.testing.io) catch unreachable;
    try std.testing.expectError(
        error.OutOfDeviceMemory,
        TextureView.createInternalYCbCr(
            std.testing.allocator,
            std.testing.io,
            guard,
            &arena,
            parent,
            conversion_sampler,
        ),
    );
    try std.testing.expectEqual(@as(u64, 2), arena.objectList().total_reference_count);
    try std.testing.expectEqual(@as(u32, 1), conversion_sampler.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), parent.header.reference_count);
    try std.testing.expectEqual(@as(u32, 0), handles.countOf(.image_view));
    try std.testing.expectEqual(@as(usize, 0), parent.native.?.view_count);
}
