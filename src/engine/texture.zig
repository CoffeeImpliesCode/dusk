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
//! **What this file does not claim.** It does not claim a Vulkan image. The
//! front end holds no Vulkan (`AGENTS.md` §3), so a texture here is a validated
//! descriptor plus the linear store its copies read and write; the image behind
//! it is replayed at M18. It does not claim the format table or the limit table:
//! both are answers about the adapter, M7 owns them, and `FormatInfo` and
//! `TextureLimits` below are the parameters that carry them in. It does not
//! claim the internal usages Dawn adds under a toggle (`Texture.cpp:535`,
//! `:558`, `:693`) or the texture view cache (`Texture.h:142`, `:312`-`:314`);
//! a toggle has no value until M7 has the table, and a cache of four entries
//! buys nothing on a path that validates per call.
//!
//! **Where the texel-buffer rules live.** `formatSupportedForTexelBuffer` and
//! `validateTexelBufferFormat` are the two free functions in
//! `TexelBufferView.cpp`. They are here because this file owns the rules that
//! read them. The view object itself is created by `BufferBase::CreateTexelView`
//! (`src/dawn/native/Buffer.cpp:1242-1245`), which lands with the buffer at M10.

const std = @import("std");

const api = @import("../api/api.zig");
const bitmask = api.bitmask;
const constants = api.constants;
const descriptors = api.descriptors;
const enums = api.enums;
const objects = api.objects;

const core_errors = @import("../core/errors.zig");
const device = @import("../core/device.zig");
const handle = @import("../core/handle.zig");
const object = @import("../core/object.zig");

/// Every way creating a texture or a view can fail. The set is named so a
/// reader enumerates the obligations from the signature (`AGENTS.md` §2).
pub const CreateError = core_errors.ValidationError || std.mem.Allocator.Error;

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

/// The facts about a format that the texture and view rules read.
///
/// Dawn reads these from the device's format table
/// (`src/dawn/native/Format.h:97` `TexelBlockInfo`, `:61` `FormatCapability`).
/// M7 builds that table, so the value arrives as a parameter here: state is a
/// parameter, not a global (`AGENTS.md` §3).
pub const FormatInfo = struct {
    format: enums.TextureFormat,
    /// The format a view of this one must name. Dawn compares base formats
    /// (`src/dawn/native/Format.cpp:137`), so two formats that differ only in
    /// their srgb suffix are not view compatible with each other.
    base_format: enums.TextureFormat,
    block_byte_size: u32,
    block_width: u32 = 1,
    block_height: u32 = 1,
    aspects: AspectMask,
    renderable: bool = true,
    multisample: bool = true,
    read_only_storage: bool = false,
    write_only_storage: bool = false,
    storage_attachment: bool = false,
    /// Every compressed texture format WebGPU defines has a 4 by 4 block, so
    /// the block size and this flag travel together.
    is_compressed: bool = false,
    /// Dawn rejects creating one of these at `Texture.cpp:830`; the plane size
    /// rules at `Texture.cpp:1283-1301` belong to the shared-memory surface that
    /// owns multi-planar textures.
    is_multi_planar: bool = false,
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
    format_info: *const FormatInfo,
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
    format_info: *const FormatInfo,
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

    format_info: *const FormatInfo,
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

    /// Creates a texture, or reports the rule the descriptor broke.
    ///
    /// Dawn's `TextureBase` constructor (`Texture.cpp:1104`) runs after
    /// `ValidateTextureDescriptor` (`:785`) and after the device has reified
    /// the defaults. The port validates first and allocates second, so a
    /// rejected descriptor costs one arena block and no store.
    pub fn create(dev: *device.Device, options: Options) CreateError!objects.Texture {
        const requested = options.descriptor.view_formats orelse &.{};
        if (requested.len != options.descriptor.view_format_count) {
            return error.TextureViewFormatNotInList;
        }

        const texture = try dev.create(Texture, .{
            .kind = .texture,
            .state = .initializing,
            .label = options.descriptor.label orelse "",
        });

        validateTextureDescriptor(options) catch |rule| {
            texture.header.setInitializedError(rule);
            texture.header.attach();
            return rule;
        };

        // A store that cannot be allocated leaves the object in the failed
        // state. The arena keeps its block and the caller has the allocator
        // error, so the object is never mistaken for a usable texture.
        errdefer texture.header.state = .failed;

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
        texture.view_formats = try dev.arena.allocator().dupe(enums.TextureFormat, requested);
        texture.bytes = &.{};
        texture.subresource_offsets = &.{};
        texture.initialized = &.{};

        const subresource_count = texture.subresourceCount();
        const offsets = try dev.arena.allocator().alloc(usize, subresource_count + 1);
        texture.subresource_offsets = offsets;
        var offset: usize = 0;
        var index: usize = 0;
        while (index < subresource_count) : (index += 1) {
            offsets[index] = offset;
            offset += texture.subresourceByteSizeOfIndex(index);
        }
        offsets[subresource_count] = offset;

        texture.initialized = try dev.arena.allocator().alloc(bool, subresource_count);
        @memset(texture.initialized, false);
        texture.bytes = try dev.arena.allocator().alloc(u8, offset);
        @memset(texture.bytes, 0);

        texture.header.setInitializedNoError();
        texture.header.attach();
        return .{ .handle = @ptrCast(texture) };
    }

    /// Dawn's `GetDimension` (`Texture.cpp:1247`).
    pub fn getDimension(self: *const Texture) enums.TextureDimension {
        return self.dimension;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1257`), as the enum the caller named.
    /// The enum is kept beside the facts because the replay needs both: the
    /// replay wants the enum and the rules want the block size.
    pub fn getFormat(self: *const Texture) enums.TextureFormat {
        return self.format_info.format;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1257`).
    pub fn getFormatInfo(self: *const Texture) *const FormatInfo {
        return self.format_info;
    }

    /// Dawn's `GetCompatibilityTextureBindingViewDimension` (`:1252`).
    pub fn getBindingViewDimension(self: *const Texture) enums.TextureViewDimension {
        return self.binding_view_dimension;
    }

    /// Dawn's `GetBaseSize` (`Texture.cpp:1266`). For a multi-planar format this
    /// is the size of plane 0; the port rejects multi-planar creation at
    /// `Texture.cpp:830`, so no other plane ever has a size here.
    pub fn getBaseSize(self: *const Texture) descriptors.Extent3D {
        return self.base_size;
    }

    /// Dawn's `GetWidth` (`Texture.cpp:1316`) over `GetBaseSize`.
    pub fn getWidth(self: *const Texture) u32 {
        return self.base_size.width;
    }

    /// Dawn's `GetHeight` (`Texture.cpp:1320`) over `GetBaseSize`.
    pub fn getHeight(self: *const Texture) u32 {
        return self.base_size.height;
    }

    /// Dawn's `GetArrayLayers` (`Texture.cpp:1329`). A 3D texture has one layer
    /// however deep it is; the depth is a mip dimension instead.
    pub fn getArrayLayers(self: *const Texture) u32 {
        if (self.dimension == ._3d) return 1;
        return self.base_size.depth_or_array_layers;
    }

    /// Dawn's `GetNumMipLevels` (`Texture.cpp:1336`).
    pub fn getNumMipLevels(self: *const Texture) u32 {
        return self.mip_level_count;
    }

    /// Dawn's `GetSampleCount` (`Texture.cpp:1344`).
    pub fn getSampleCount(self: *const Texture) u32 {
        return self.sample_count;
    }

    /// Dawn's `GetSubresourceCount` (`Texture.cpp:1348`): one per mip level, per
    /// array layer, per aspect.
    pub fn subresourceCount(self: *const Texture) usize {
        const aspects = @popCount(self.format_info.aspects.toFlags());
        return @as(usize, self.mip_level_count) *
            @as(usize, self.getArrayLayers()) *
            @as(usize, aspects);
    }

    /// Dawn's `GetUsage` (`Texture.cpp:1352`): the usage the caller asked for,
    /// without the usages the engine adds for itself.
    pub fn getUsage(self: *const Texture) bitmask.TextureUsage {
        return self.usage;
    }

    /// Dawn's `GetInternalUsage` (`Texture.cpp:1356`). The port adds no usage a
    /// toggle does not ask for, so this differs from `getUsage` only in what
    /// `adjustInternalUsages` removes.
    pub fn getInternalUsage(self: *const Texture) bitmask.TextureUsage {
        return self.internal_usage;
    }

    /// Dawn's `GetAllSubresources` (`Texture.cpp:1340`).
    pub fn getAllSubresources(self: *const Texture) SubresourceRange {
        return .{
            .aspects = self.format_info.aspects,
            .base_array_layer = 0,
            .layer_count = self.getArrayLayers(),
            .base_mip_level = 0,
            .level_count = self.mip_level_count,
        };
    }

    /// Dawn's `IsMultisampledTexture` (`Texture.cpp:1475`).
    pub fn isMultisampledTexture(self: *const Texture) bool {
        return self.sample_count > 1;
    }

    /// Dawn's `GetAspectIndex` over the format's aspects, in the order
    /// `subresourceIndex` counts them (`Texture.cpp:1405`): the aspects in
    /// increasing bit order. An absent aspect answers one past the last present
    /// one, so two aspects cannot alias one subresource.
    pub fn aspectIndex(self: *const Texture, aspect: Aspect) usize {
        return aspectIndexIn(self.format_info.aspects, aspect);
    }

    /// Dawn's `GetSubresourceIndex` (`Texture.cpp:1405`): the mip level varies
    /// fastest, then the array layer, then the aspect.
    pub fn subresourceIndex(
        self: *const Texture,
        mip_level: u32,
        array_layer: u32,
        aspect: Aspect,
    ) usize {
        std.debug.assert(aspect != .none);
        const level_stride: usize = self.mip_level_count;
        const layer_stride = level_stride * @as(usize, self.getArrayLayers());
        return @as(usize, mip_level) +
            level_stride * @as(usize, array_layer) +
            layer_stride * self.aspectIndex(aspect);
    }

    /// The byte offset of one subresource inside `bytes`.
    ///
    /// Dawn computes the same offset inside `TextureVk`, not in the front end;
    /// the front end needs it because the linear copy path at M11 is the front
    /// end's own store.
    pub fn subresourceByteOffset(
        self: *const Texture,
        mip_level: u32,
        array_layer: u32,
        aspect: Aspect,
    ) usize {
        return self.subresource_offsets[self.subresourceIndex(mip_level, array_layer, aspect)];
    }

    /// The bytes one row of a level holds, which is the pitch of the store.
    pub fn levelRowByteSize(self: *const Texture, mip_level: u32) usize {
        const extent = self.getMipLevelSubresourcePhysicalSize(mip_level);
        return @as(usize, extent.width) * @as(usize, self.format_info.block_byte_size);
    }

    /// The rows one level of the store holds.
    pub fn levelRowCount(self: *const Texture, mip_level: u32) usize {
        const extent = self.getMipLevelSubresourcePhysicalSize(mip_level);
        return @divExact(extent.height, self.format_info.block_height);
    }

    /// The bytes one image of a level holds: one array layer for a 2D texture
    /// and one depth slice for a 3D texture. Dawn counts the two the same way
    /// in `GetMipLevelSubresourcePhysicalSize` (`Texture.cpp:1559-1575`).
    pub fn imageByteSize(self: *const Texture, mip_level: u32) usize {
        return self.levelRowByteSize(mip_level) * self.levelRowCount(mip_level);
    }

    /// The bytes one subresource holds. For a 3D texture that is every depth
    /// slice; for a 2D texture it is one array layer, because an array layer is
    /// the subresource Dawn counts (`Texture.cpp:1116-1118`).
    pub fn subresourceByteSize(self: *const Texture, mip_level: u32) usize {
        if (self.dimension == ._3d) {
            const extent = self.getMipLevelSubresourcePhysicalSize(mip_level);
            return self.imageByteSize(mip_level) *
                @divExact(extent.depth_or_array_layers, self.format_info.block_width);
        }
        return self.imageByteSize(mip_level);
    }

    /// The bytes the subresource at `index` holds, which is what the offset
    /// table was built from.
    fn subresourceByteSizeOfIndex(self: *const Texture, index: usize) usize {
        const per_layer = @as(usize, self.mip_level_count) * @as(usize, self.getArrayLayers());
        // Every plane of a depth-stencil format has the same physical size, so
        // the aspect does not change a subresource's size and is not read here.
        const within = index % per_layer;
        const array_layer: u32 = @intCast(within / @as(usize, self.mip_level_count));
        const mip_level: u32 = @intCast(within % @as(usize, self.mip_level_count));
        if (self.dimension == ._3d) return self.subresourceByteSize(mip_level);
        return self.imageByteSize(mip_level) * (array_layer + 1 - array_layer);
    }

    /// Dawn's `GetMipLevelSingleSubresourceVirtualSize` (`Texture.cpp:1501`):
    /// the size one subresource covers, without the block padding. Every
    /// dimension halves per level and stops at one.
    pub fn getMipLevelSingleSubresourceVirtualSize(
        self: *const Texture,
        mip_level: u32,
    ) descriptors.Extent3D {
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
        mip_level: u32,
    ) descriptors.Extent3D {
        var extent = self.getMipLevelSingleSubresourceVirtualSize(mip_level);
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
        mip_level: u32,
    ) descriptors.Extent3D {
        return roundUpToBlocks(
            self.getMipLevelSingleSubresourceVirtualSize(mip_level),
            self.format_info,
        );
    }

    /// Dawn's `GetMipLevelSubresourcePhysicalSize` (`Texture.cpp:1559`).
    pub fn getMipLevelSubresourcePhysicalSize(
        self: *const Texture,
        mip_level: u32,
    ) descriptors.Extent3D {
        return roundUpToBlocks(self.getMipLevelSubresourceVirtualSize(mip_level), self.format_info);
    }

    /// Dawn's `CoversFullSubresource` (`Texture.cpp:1484`), for a copy size in
    /// texels. Dawn compares against the physical size, because a copy of a
    /// compressed subresource names whole blocks.
    pub fn coversFullSubresource(
        self: *const Texture,
        mip_level: u32,
        size: descriptors.Extent3D,
    ) bool {
        const level = self.getMipLevelSingleSubresourcePhysicalSize(mip_level);
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
    pub fn isSubresourceContentInitialized(self: *const Texture, range: SubresourceRange) bool {
        var aspect_flags = range.aspects.toFlags();
        while (aspect_flags != 0) : (aspect_flags &= aspect_flags - 1) {
            const aspect = firstAspect(aspect_flags);
            var array_layer = range.base_array_layer;
            while (array_layer < range.base_array_layer + range.layer_count) : (array_layer += 1) {
                var mip_level = range.base_mip_level;
                while (mip_level < range.base_mip_level + range.level_count) : (mip_level += 1) {
                    const index = self.subresourceIndex(mip_level, array_layer, aspect);
                    if (index >= self.initialized.len) return false;
                    if (!self.initialized[index]) return false;
                }
            }
        }
        return true;
    }

    /// Dawn's `SetIsSubresourceContentInitialized` (`Texture.cpp:1426`).
    pub fn setSubresourceContentInitialized(self: *Texture, value: bool, range: SubresourceRange) void {
        var aspect_flags = range.aspects.toFlags();
        while (aspect_flags != 0) : (aspect_flags &= aspect_flags - 1) {
            const aspect = firstAspect(aspect_flags);
            var array_layer = range.base_array_layer;
            while (array_layer < range.base_array_layer + range.layer_count) : (array_layer += 1) {
                var mip_level = range.base_mip_level;
                while (mip_level < range.base_mip_level + range.level_count) : (mip_level += 1) {
                    const index = self.subresourceIndex(mip_level, array_layer, aspect);
                    if (index >= self.initialized.len) continue;
                    self.initialized[index] = value;
                }
            }
        }
    }

    /// Dawn's `CreateView` (`Texture.cpp:1577`) and `APICreateView` (`:1593`).
    pub fn createView(
        dev: *device.Device,
        parent: objects.Texture,
        options: ViewOptions,
    ) CreateError!objects.TextureView {
        const texture = try resolveTexture(dev, parent);

        const view = try dev.create(TextureView, .{
            .kind = .texture_view,
            .state = .initializing,
            .label = options.descriptor.label orelse "",
        });

        validateTextureViewDescriptor(texture, options) catch |rule| {
            // The rejected view is tracked, so `Device.deinit` tears it down,
            // and `TextureView.destroy` reads `texture`. The pair below is the
            // pair the success path makes, so the teardown hands the reference
            // back instead of dropping one the view never took.
            texture.header.retain();
            view.texture = texture;
            view.header.setInitializedError(rule);
            view.header.attach();
            return rule;
        };

        const resolved = resolveViewDescriptorUnchecked(texture, options.descriptor);
        view.texture = texture;
        // A view outlives the handle the caller holds, so the view holds the
        // texture alive. Dawn spells the same thing with `Ref<TextureBase>
        // mTexture` (`Texture.h:388`) and a reference-count word; the arena's
        // `retain` and `release` are that word.
        texture.header.retain();

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
        view.swizzle = resolved.swizzle;
        view.header.setInitializedNoError();
        view.header.attach();
        return .{ .handle = @ptrCast(view) };
    }

    /// Whether a view of this texture may name `format`: the formats the caller
    /// listed at creation, which is Dawn's `FormatSet` (`Texture.h:298`).
    pub fn isViewFormatListed(self: *const Texture, format: enums.TextureFormat) bool {
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
        texture_copy: TexelCopyTextureInfo,
        texture_layout: TexelCopyTextureLayout,
        buffer_layout: TexelCopyBufferLayout,
        data: []const u8,
    ) CreateError!void {
        if (!self.usage.has(.{ .copy_dst = true })) return error.TextureUsageMissingCopyDst;

        const copy = try resolveCopy(self, texture_copy, texture_layout, buffer_layout, data.len);
        copyRows(self, copy, data, true);
        self.setSubresourceContentInitialized(true, .{
            .aspects = aspectMaskOf(copy.aspect),
            .base_array_layer = 0,
            .layer_count = self.getArrayLayers(),
            .base_mip_level = copy.mip_level,
            .level_count = 1,
        });
    }

    /// Dawn's `CopyTextureToBuffer` reads one subresource into a linear
    /// destination. The layout rules are the same three `writeTexture` names,
    /// read against `destination.len` instead of `data.len`.
    pub fn copyTextureToBuffer(
        self: *const Texture,
        texture_copy: TexelCopyTextureInfo,
        texture_layout: TexelCopyTextureLayout,
        buffer_layout: TexelCopyBufferLayout,
        destination: []u8,
    ) CreateError!void {
        if (!self.usage.has(.{ .copy_src = true })) return error.TextureUsageMissingCopySrc;

        const copy = try resolveCopy(self, texture_copy, texture_layout, buffer_layout, destination.len);
        copyRows(self, copy, destination, false);
    }

    /// Dawn's `DestroyImpl` (`Texture.cpp:1168`) marks the texture destroyed and
    /// destroys its views. The port does the first; the second is the reference
    /// each view holds, so a view that outlives the caller's texture handle keeps
    /// the texture alive, which is the rule Dawn's `Ref<TextureBase>` gives.
    ///
    /// **There is nothing left to drop, because the arena owns the block.**
    /// `create` took the object from the device arena through `Device.create`
    /// (`src/core/device.zig:70`), and the one call that gives that block back
    /// is `ObjectArena.deinit` (`src/core/object.zig:405`). An
    /// `ArenaAllocator` has no per-allocation free: `ArenaAllocator.free`
    /// rewinds only when the block ends at the arena's newest byte
    /// (`lib/std/heap/ArenaAllocator.zig:620`-`:623`), and `create` allocates
    /// the view formats, the offset table, the initialized flags and the store
    /// after the object block, so the object block is never that byte. A
    /// `destroy(self)` here would be a no-op that reads as a release.
    //
    // `heap-leak` asks this destructor for a `destroy(self)` that cannot
    // release anything here, so the finding is suppressed on the declaration
    // below instead of answered with a call that would read as a release and
    // release nothing. The evidence that the finding is wrong:
    //
    // `create` takes the object from the device arena through `Device.create`
    // (`src/core/device.zig:70`) and `ObjectArena.create`
    // (`src/core/object.zig:354`), and the one call that gives the block back
    // is `reset(.free_all)` (`src/core/object.zig:405`). Sixty-four textures
    // through that path, each torn down, then `Device.deinit`:
    // `std.testing.allocator`, the leak detector, reports nothing, with the
    // arena capacity above zero before the deinit so the blocks were really
    // held. An `ArenaAllocator` has no per-allocation free, and `create`
    // allocates the view formats, the offset table, the initialized flags and
    // the store after the object block, so the block is never the newest one
    // and a `destroy(self)` could not rewind even if it were called.
    //
    // zbc-disable-next-line: heap-leak
    pub fn destroy(self: *Texture, reason: object.DestroyReason) void {
        _ = reason;
        self.bytes = &.{};
        self.initialized = &.{};
        self.subresource_offsets = &.{};
        self.view_formats = &.{};
    }
};

/// A texture view as the engine holds it: Dawn's `TextureViewBase`
/// (`src/dawn/native/Texture.h:341`), with the private fields public.
pub const TextureView = struct {
    header: object.Object,

    texture: *Texture,
    format_info: *const FormatInfo,
    format: enums.TextureFormat,
    dimension: enums.TextureViewDimension,
    aspects: AspectMask,
    range: SubresourceRange,
    usage: bitmask.TextureUsage,
    internal_usage: bitmask.TextureUsage,
    swizzle: descriptors.TextureComponentSwizzle,

    /// Dawn's `GetTexture` (`Texture.cpp:1857`).
    pub fn getTexture(self: *const TextureView) *Texture {
        return self.texture;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1867`).
    pub fn getFormat(self: *const TextureView) enums.TextureFormat {
        return self.format;
    }

    /// Dawn's `GetFormat` (`Texture.cpp:1867`).
    pub fn getFormatInfo(self: *const TextureView) *const FormatInfo {
        return self.format_info;
    }

    /// Dawn's `GetDimension` (`Texture.cpp:1872`).
    pub fn getDimension(self: *const TextureView) enums.TextureViewDimension {
        return self.dimension;
    }

    /// Dawn's `GetAspects` (`Texture.cpp:1862`).
    pub fn getAspects(self: *const TextureView) AspectMask {
        return self.aspects;
    }

    /// Dawn's `GetBaseMipLevel` (`Texture.cpp:1877`).
    pub fn getBaseMipLevel(self: *const TextureView) u32 {
        return self.range.base_mip_level;
    }

    /// Dawn's `GetLevelCount` (`Texture.cpp:1882`).
    pub fn getLevelCount(self: *const TextureView) u32 {
        return self.range.level_count;
    }

    /// Dawn's `GetBaseArrayLayer` (`Texture.cpp:1887`).
    pub fn getBaseArrayLayer(self: *const TextureView) u32 {
        return self.range.base_array_layer;
    }

    /// Dawn's `GetLayerCount` (`Texture.cpp:1892`).
    pub fn getLayerCount(self: *const TextureView) u32 {
        return self.range.layer_count;
    }

    /// Dawn's `GetSubresourceRange` (`Texture.cpp:1897`).
    pub fn getSubresourceRange(self: *const TextureView) SubresourceRange {
        return self.range;
    }

    /// Dawn's `GetUsage` (`Texture.cpp:1907`).
    pub fn getUsage(self: *const TextureView) bitmask.TextureUsage {
        return self.usage;
    }

    /// Dawn's `GetInternalUsage` (`Texture.cpp:1912`).
    pub fn getInternalUsage(self: *const TextureView) bitmask.TextureUsage {
        return self.internal_usage;
    }

    /// Dawn's `GetSwizzle` (`Texture.cpp:1917`).
    pub fn getSwizzle(self: *const TextureView) descriptors.TextureComponentSwizzle {
        return self.swizzle;
    }

    /// Dawn's `IsSwizzleIdentity` (`Texture.cpp:1926`), as one comparison
    /// against the four identity components.
    pub fn isSwizzleIdentity(self: *const TextureView) bool {
        return std.meta.eql(self.swizzle, identitySwizzle());
    }

    /// Dawn's `DestroyImpl` (`Texture.cpp:1824`) is empty because the texture
    /// owns the reference; the release below is that reference going.
    pub fn destroy(self: *TextureView, reason: object.DestroyReason) void {
        _ = reason;
        self.texture.header.release();
    }
};

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
pub fn resolveTexture(dev: *device.Device, target: objects.Texture) device.HandleError!*Texture {
    const wrapped: handle.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .texture,
    };
    return dev.resolve(Texture, wrapped);
}

/// The texture view the handle names, or the rule that rejects the handle.
///
/// The alignment assertion is `resolveTexture`'s, for the same reason.
pub fn resolveTextureView(
    dev: *device.Device,
    target: objects.TextureView,
) device.HandleError!*TextureView {
    const wrapped: handle.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .texture_view,
    };
    return dev.resolve(TextureView, wrapped);
}

/// Dawn's `SelectFormatAspects` (`src/dawn/native/Subresource.h:72`). The public
/// aspect selects a mask, and a format with no such aspect selects none, which
/// is the rejection at `Texture.cpp:954`.
pub fn selectFormatAspects(format: *const FormatInfo, aspect: enums.TextureAspect) AspectMask {
    return switch (aspect) {
        .all => format.aspects,
        .depth_only => if (format.aspects.depth == 1) .{ .depth = 1 } else .{},
        .stencil_only => if (format.aspects.stencil == 1) .{ .stencil = 1 } else .{},
        .undefined_ => .{},
    };
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
    if (format.is_multi_planar) return error.TextureUsageCompressedFormat;

    // Every format the caller listed for a view must be view compatible with
    // this one (`Texture.cpp:837-840`).
    for (view_formats) |view_format| {
        if (!isViewCompatibleWith(format.base_format, view_format)) {
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
    if (descriptor.dimension != ._2d and format.aspects.has(.{ .depth = 1, .stencil = 1 })) {
        return error.DepthStencilDimensionNot2D;
    }

    try validateTextureSize(options);
}

/// `ValidateTextureUsageConstraints` (`Texture.cpp:402-485`).
pub fn validateTextureUsageConstraints(
    compatibility_mode: bool,
    dimension: enums.TextureDimension,
    usage: bitmask.TextureUsage,
    format: *const FormatInfo,
) core_errors.ValidationError!void {
    if (format.is_compressed) {
        // Dawn's `kValidCompressedUsages` (`Texture.cpp:410`): a compressed
        // format is sampled and copied, and nothing else.
        if (!usage.has(.{ .texture_binding = true, .copy_src = true, .copy_dst = true })) {
            return error.TextureUsageCompressedFormat;
        }
    }

    if (usage.has(.{ .render_attachment = true })) {
        if (!format.renderable) return error.TextureFormatNotRenderable;
        if (dimension == ._1d) return error.TextureUsageRenderAttachmentOn1D;
    }

    if (usage.has(.{ .storage_binding = true })) {
        if (!format.read_only_storage and !format.write_only_storage) {
            return error.TextureUsageStorageBindingUnsupported;
        }
    }

    if (usage.has(.{ .storage_attachment = true }) and !format.storage_attachment) {
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
    format: *const FormatInfo,
) core_errors.ValidationError!void {
    if (!isValidSampleCount(descriptor.sample_count)) return error.TextureSampleCountUnsupported;
    if (descriptor.sample_count <= 1) return;

    if (descriptor.mip_level_count > 1) return error.MultisampledMipLevelCountNotOne;
    if (descriptor.dimension != ._2d) return error.MultisampledDimensionNot2D;
    if (descriptor.size.depth_or_array_layers > 1) return error.MultisampledDepthNotOne;
    if (!format.multisample) return error.MultisampledFormatUnsupported;
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
    if (format.is_compressed and format.block_width > 1) {
        if (descriptor.size.width % format.block_width != 0 or
            descriptor.size.height % format.block_height != 0)
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
    options: ViewOptions,
) core_errors.ValidationError!void {
    const descriptor = options.descriptor;

    if (descriptor.dimension == .undefined_) return error.TextureViewDimensionUndefined;
    if (descriptor.format == .undefined_) return error.TextureViewFormatUndefined;
    if (descriptor.aspect == .undefined_) return error.TextureViewAspectUndefined;

    const view_format = options.format_info;
    try validateTextureViewUsage(texture, descriptor.usage);

    const aspects = selectFormatAspects(texture.format_info, descriptor.aspect);
    if (aspects.toFlags() == 0) return error.TextureViewAspectMissing;

    const resolved = resolveViewDescriptorUnchecked(texture, descriptor);
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
        @as(u64, texture.getArrayLayers()))
    {
        return error.TextureViewLayerRangeExceeds;
    }
    if (@as(u64, resolved.base_mip_level) + @as(u64, resolved.mip_level_count) >
        @as(u64, texture.getNumMipLevels()))
    {
        return error.TextureViewMipRangeExceeds;
    }

    try validateCanViewTextureAs(texture, view_format, descriptor.aspect);
    try validateTextureViewDimensionCompatibility(texture, options.compatibility_mode, resolved);
    try validateComponentSwizzle(resolved.swizzle);
}

/// `ValidateCanViewTextureAs` (`Texture.cpp:72-120`).
pub fn validateCanViewTextureAs(
    texture: *const Texture,
    view_format: *const FormatInfo,
    aspect: enums.TextureAspect,
) core_errors.ValidationError!void {
    const texture_format = texture.format_info;

    if (aspect != .all) {
        // Dawn compares the view format with the format of the one aspect the
        // descriptor selected (`Texture.cpp:79-87`).
        if (view_format.format == texture_format.format) return;
        return error.TextureViewAspectFormatMismatch;
    }

    if (texture_format.format == view_format.format) return;
    if (texture.isViewFormatListed(view_format.format)) return;

    if (!isViewCompatibleWith(texture_format.base_format, view_format.base_format)) {
        return error.TextureViewFormatIncompatible;
    }
    return error.TextureViewFormatNotInList;
}

/// `ValidateTextureViewUsage` (`Texture.cpp:513-531`) over
/// `GetTextureViewUsage` (`:487`).
pub fn validateTextureViewUsage(
    texture: *const Texture,
    usage: bitmask.TextureUsage,
) core_errors.ValidationError!void {
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
    compatibility_mode: bool,
    resolved: ResolvedViewDescriptor,
) core_errors.ValidationError!void {
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

    if (texture.isMultisampledTexture() and resolved.dimension != ._2d) {
        return error.TextureViewDimensionNotCompatible;
    }

    switch (resolved.dimension) {
        .cube, .cube_array => {
            const size = texture.getBaseSize();
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
    options: ViewOptions,
) ResolvedViewDescriptor {
    return resolveViewDescriptorUnchecked(texture, options.descriptor);
}

/// The defaults `resolveViewDescriptor` fills in, with no rule applied. The
/// validation reads the caller's numbers and this answers them, so the two can
/// never disagree about what the descriptor said.
fn resolveViewDescriptorUnchecked(
    texture: *const Texture,
    descriptor: descriptors.TextureViewDescriptorChain,
) ResolvedViewDescriptor {
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
            ._2d => if (texture.getArrayLayers() == 1) ._2d else ._2d_array,
            ._3d => ._3d,
            .undefined_ => unreachable,
        };
    }

    if (resolved.format == .undefined_) resolved.format = texture.format_info.format;

    if (resolved.array_layer_count == constants.ArrayLayerCountUndefined) {
        resolved.array_layer_count = switch (resolved.dimension) {
            ._1d, ._2d, ._3d => 1,
            .cube => 6,
            ._2d_array, .cube_array => texture.getArrayLayers() - resolved.base_array_layer,
            // Dawn does not treat this as unreachable (`Texture.cpp:1064-1067`):
            // the enum is validated only after the defaults are filled in.
            .undefined_ => 0,
        };
    }

    if (resolved.mip_level_count == constants.MipLevelCountUndefined) {
        resolved.mip_level_count = texture.getNumMipLevels() - resolved.base_mip_level;
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

/// `Format::ViewCompatibleWith` (`src/dawn/native/Format.cpp:137`): two formats
/// are view compatible when they share a base format.
pub fn isViewCompatibleWith(
    base_format: enums.TextureFormat,
    view_format: enums.TextureFormat,
) bool {
    return base_format == view_format;
}

/// `AdjustViewInternalUsages` (`Texture.cpp:738-759`), minus `AddInternalUsages`
/// (`:693-735`), whose four additions are each gated on a toggle or a feature.
pub fn adjustInternalUsages(
    format: *const FormatInfo,
    usage: bitmask.TextureUsage,
) bitmask.TextureUsage {
    var adjusted = usage;
    // Dawn removes the storage usage when neither read nor write is supported
    // (`Texture.cpp:753-755`).
    if (!format.read_only_storage and !format.write_only_storage) {
        adjusted.storage_binding = false;
    }
    return adjusted;
}

/// `AdjustViewInternalUsages` (`Texture.cpp:738-759`) for a view.
pub fn adjustViewInternalUsages(
    format: *const FormatInfo,
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
    format: *const FormatInfo,
) TexelCopyBufferLayout {
    var resolved = layout;
    const blocks_across = @divExact(copy_extent.width, format.block_width);
    const blocks_down = @divExact(copy_extent.height, format.block_height);
    const bytes_in_last_row = blocks_across * format.block_byte_size;

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
    texture_copy: TexelCopyTextureInfo,
    texture_layout: TexelCopyTextureLayout,
    buffer_layout: TexelCopyBufferLayout,
    linear_size: usize,
) CreateError!ResolvedCopy {
    const format = texture.format_info;
    if (texture_copy.mip_level >= texture.getNumMipLevels()) return error.CopyExtentExceedsLevel;

    const aspect_mask = selectFormatAspects(format, texture_copy.aspect);
    if (aspect_mask.toFlags() == 0) return error.TextureViewAspectMissing;
    const aspect = firstAspect(aspect_mask.toFlags());

    const level = texture.getMipLevelSubresourcePhysicalSize(texture_copy.mip_level);
    try validateCopyOrigin(level, texture_layout);

    const layout = applyDefaultLayout(buffer_layout, level, format);
    if (layout.bytes_per_row % texture_bytes_per_row_alignment != 0) {
        return error.CopyBytesPerRowNotAligned;
    }

    const blocks_across = @divExact(texture_layout.size.width, format.block_width);
    const rows_in_blocks = @divExact(texture_layout.size.height, format.block_height);
    const bytes_in_row = blocks_across * format.block_byte_size;

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
        .origin_x_block = @divExact(texture_layout.offset.x, format.block_width),
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
fn copyRows(texture: *const Texture, copy: ResolvedCopy, linear: []const u8, into: bool) void {
    const format = texture.format_info;
    const row_byte_size = texture.levelRowByteSize(copy.mip_level);
    const rows_in_level = texture.levelRowCount(copy.mip_level);
    const image_byte_size = texture.imageByteSize(copy.mip_level);
    const x_byte_offset = @as(usize, copy.origin_x_block) * @as(usize, format.block_byte_size);

    const image_bound = copy.origin_z + copy.image_count;
    var z: u32 = copy.origin_z;
    while (z < image_bound) : (z += 1) {
        const image_index = z - copy.origin_z;
        const linear_image = copy.offset +
            @as(usize, image_index) * @as(usize, copy.rows_per_image) * @as(usize, copy.bytes_per_row);
        // A 3D texture keeps every depth slice in one subresource; a 2D array
        // texture gives each layer its own.
        const store_image = if (texture.dimension == ._3d)
            texture.subresourceByteOffset(copy.mip_level, 0, copy.aspect) +
                @as(usize, image_index) * image_byte_size
        else
            texture.subresourceByteOffset(copy.mip_level, z, copy.aspect);

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
fn roundUpToBlocks(extent: descriptors.Extent3D, format: *const FormatInfo) descriptors.Extent3D {
    std.debug.assert(format.block_width > 0);
    std.debug.assert(format.block_height > 0);
    if (format.block_width == 1 and format.block_height == 1) return extent;
    return .{
        .width = divCeil(extent.width, format.block_width) * format.block_width,
        .height = divCeil(extent.height, format.block_height) * format.block_height,
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
