//! Buffers: creation, CPU mapping, usage barriers, and the upload path.
//!
//! **What this file is.** The port of
//! `src/dawn/native/Buffer.{h,cpp}` and `src/dawn/native/vulkan/BufferVk.{h,cpp}`
//! at Dawn `32f77c02294310054a660c393feded4bcb3f203c`.
//!
//! **Why one file and not two.** Dawn splits the front-end state machine from
//! the Vulkan object so a second back end can answer six pure virtuals
//! (`Buffer.h:244-261`). `dusk` has one back end, so there is
//! no seam to keep: this file is the front-end rules and the concrete Vulkan
//! buffer, in that order.
//!
//! **What is a parameter and what is not.** `Device` is the Vulkan state that
//! never changes for the life of a `VkDevice`, taken by value and stored. A
//! `Recording` is the one piece that changes per submission: the queue hands
//! out a fresh command buffer each time it recycles a context
//! (`QueueVk.cpp:398`), so a buffer holds no pointer to one and every recording
//! call takes the current one. No global, no clock, no hidden state.
//!
//! **What this file does not claim.** It does not claim shared buffer memory
//! import, which needs the external-memory path and lands with M21. It does not
//! claim a texel buffer view. It does not claim the oversized-row split of a
//! texture copy, which is a front-end rewrite that needs block info.

const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");
const recording_context = @import("recording_context.zig");
const RingAllocator = @import("../memory/ring_allocator.zig").RingAllocator;
const vk = @import("../vk/dispatch.zig");
const vulkan = @import("vulkan");
const vulkan_device = @import("vulkan_device.zig");

/// The public usage bits, as `dawn.json` numbers them (`src/api/bitmask.zig:8`).
pub const BufferUsage = api.BufferUsage;
/// The public map mode bits (`src/api/bitmask.zig:117`).
pub const MapMode = api.MapMode;
/// The public shader stage bits (`src/api/bitmask.zig:158`).
pub const ShaderStage = api.ShaderStage;
/// The caller's descriptor (`src/api/descriptors.zig:397`).
pub const BufferDescriptor = api.BufferDescriptor;

/// Library-only creation flags use the engine mask, not Vulkan usage values.
pub const InternalBufferDescriptor = struct {
    size: u64,
    native_usage: u32,
};
/// An execution serial. The same type as `platform.Serial`, taken from there
/// rather than restated so the serial timeline has one authority.
pub const Serial = platform.Serial;

/// `kCopyBufferToBufferOffsetAlignment` (`Constants.h:86`). A `vkCmdCopyBuffer`
/// source offset must be a multiple of four.
pub const copy_offset_alignment: u64 = 4;
/// The size alignment `vkCmdFillBuffer` needs (`BufferVk.cpp:237`).
pub const fill_alignment: u64 = 4;
/// The map offset rule at `Buffer.cpp:1075`.
pub const map_offset_alignment: u64 = 8;
/// The map size rule at `Buffer.cpp:1076`.
pub const map_size_alignment: u64 = 4;
/// The mapped-at-creation size rule at `Buffer.cpp:476`.
pub const mapped_at_creation_size_alignment: u64 = 4;
/// `BufferVk.cpp:256`. Vulkan rejects a zero-sized buffer, and a clamped access
/// must stay in bounds, so the allocation is at least this large.
pub const minimum_allocated_size: u64 = 4;
/// `BufferVk.cpp:243`. One extra byte makes a zero-length binding at
/// `offset == size` legal, which `vkCmdSetVertexBuffer` and
/// `vkCmdSetIndexBuffer` otherwise refuse.
pub const vertex_index_extra_byte_count: u64 = 1;
/// `BufferVk.cpp:266`. A uniform buffer is polyfilled as `array<vec4u, ...>`,
/// so its allocation is rounded to sixteen bytes.
pub const uniform_allocated_alignment: u64 = 16;
/// `kRingBufferSize` (`DynamicUploader.cpp:43`).
pub const upload_ring_size: u64 = 4 * 1024 * 1024;
/// The reservation alignment of `RingBufferAllocator::Allocate`, which
/// `DynamicUploader::Reserve` reaches through `Align(allocationSize, 8)`
/// (`DynamicUploader.cpp:51`). It is what makes a ring offset a legal mapping
/// offset as well as a legal copy offset.
pub const upload_reservation_alignment: u64 = 8;
/// `whole_map_size` (`wgpu::kWholeMapSize`), the `size` that means "to the end".
pub const whole_map_size: u64 = std.math.maxInt(u64);

// The public bits as a `u32`, so a mask and a bitwise operation share a type.
const usage_map_read: u32 = 1;
const usage_map_write: u32 = 2;
const usage_copy_src: u32 = 4;
const usage_copy_dst: u32 = 8;
const usage_index: u32 = 16;
const usage_vertex: u32 = 32;
const usage_uniform: u32 = 64;
const usage_storage: u32 = 128;
const usage_indirect: u32 = 256;
const usage_query_resolve: u32 = 512;
const usage_texel_buffer: u32 = 1024;

// The internal usage bits of `dawn_platform.h:52-76`. They sit above the twelve
// public bits of `dawn.json:811`, so they do not fit `api.BufferUsage` and the
// combined set is a plain `u32`. Each bit is named here so no call site spells
// a shift.
pub const internal_storage_buffer: u32 = 1 << 31;
pub const read_only_storage_buffer: u32 = 1 << 30;
pub const internal_copy_src_buffer: u32 = 1 << 29;
pub const indirect_buffer_for_backend_resource_tracking: u32 = 1 << 28;
pub const read_only_texel_buffer: u32 = 1 << 27;

const internal_creation_usages: u32 = usage_copy_src | usage_copy_dst | usage_uniform |
    usage_indirect | internal_storage_buffer | read_only_storage_buffer |
    internal_copy_src_buffer;

/// `kReadOnlyBufferUsages` (`Buffer.h:57`).
pub const read_only_buffer_usages: u32 = usage_map_read | usage_copy_src | usage_index |
    usage_vertex | usage_uniform | read_only_texel_buffer | read_only_storage_buffer |
    usage_indirect | indirect_buffer_for_backend_resource_tracking | internal_copy_src_buffer;
/// `kMappableBufferUsages` (`Buffer.h:63`).
pub const mappable_buffer_usages: u32 = usage_map_read | usage_map_write;
/// `kShaderBufferUsages` (`Buffer.h:66`).
pub const shader_buffer_usages: u32 = usage_uniform | usage_storage | usage_texel_buffer |
    internal_storage_buffer | read_only_storage_buffer | read_only_texel_buffer;
/// `kReadOnlyShaderBufferUsages` (`Buffer.h:70`).
pub const read_only_shader_buffer_usages: u32 =
    shader_buffer_usages & read_only_buffer_usages;

/// `BufferState` (`Buffer.h:109`), the seven states and nothing else.
pub const State = enum {
    /// The buffer is held exclusively by a map, an unmap, or the queue. A
    /// second holder is `error.BufferUseWhileInUse`.
    in_use,
    unmapped,
    pending_map,
    mapped,
    mapped_at_creation,
    shared_memory_no_access,
    destroyed,
};

/// `IsMappedState` (`Buffer.cpp:493`). Both mapped states answer a mapped-range
/// request; the rest do not.
pub fn isMappedState(state: State) bool {
    return state == .mapped or state == .mapped_at_creation;
}

/// `stateName` names every `State` value, the second closed domain a caller
/// matches on. The switch has no `else`, and `test/buffer.zig` sweeps the
/// enumeration against it.
pub fn stateName(state: State) []const u8 {
    return switch (state) {
        .in_use => "in use",
        .unmapped => "unmapped",
        .pending_map => "pending map",
        .mapped => "mapped",
        .mapped_at_creation => "mapped at creation",
        .shared_memory_no_access => "shared memory no access",
        .destroyed => "destroyed",
    };
}

/// Every rule this module owns, one member per `DAWN_INVALID_IF` site.
/// `BufferUsageMissingCopyDst` is a member of `core.ValidationError` as well
/// (`src/core/errors.zig:21`), and it is here too because both sites that
/// raise it declare `Rule!void`: `validateWriteBuffer` and `recordCopyBuffer`
/// would not compile against a set that did not carry it. The rest are here
/// because `src/core/errors.zig` is not this milestone's file.
pub const Rule = error{
    BufferUsageEmpty,
    InternalBufferUsageInvalid,
    BufferUsageMapReadWithOtherUsages,
    BufferUsageMapWriteWithOtherUsages,
    BufferUsageMissingCopyDst,
    BufferUsageMissingCopySrc,
    BufferMappedAtCreationSizeNotAligned,
    BufferSizeAboveLimit,
    BufferAllocationOverflow,
    BufferAllocationHuge,
    BufferHostVisibleExpected,
    BufferMappedRangeNotAligned,
    BufferMappedRangeOutsideBuffer,
    BufferAlreadyMapped,
    BufferMapAlreadyPending,
    BufferMapModeMismatch,
    BufferMapRangeOutsideBuffer,
    BufferNotMapped,
    BufferUseWhileInUse,
    BufferUseWhileMapped,
    BufferUseWhilePendingMap,
    BufferUseWithoutSharedMemoryAccess,
    BufferUseWhileDestroyed,
    BufferWriteOffsetNotAligned,
    BufferWriteSizeNotAligned,
    BufferWriteOutsideBuffer,
    UploadRingRequestTooLarge,
    UploadRingExhausted,
    UploadRingReservationNotLast,
    UploadRingDeviceMismatch,
    ZeroSizedCopy,
};

/// The whole error surface of one buffer operation. `vk.Error` is the
/// `VkResult` mapping `src/vk/dispatch.zig:1133` owns, so this file never names
/// a Vulkan result code. `vk.LoadError` reports a dispatch field the loader
/// left null as a typed error, never as a panic.
pub const Error = Rule || core.ValidationError || vk.Error || vk.LoadError ||
    std.mem.Allocator.Error || RingAllocator.AllocateError ||
    error{ MapGenerationExhausted, BufferMapAborted };

/// The error set `create` reports. It is `Error`; the alias names the call site
/// rather than widening the set for it.
pub const CreateError = Error;

/// The error set a map, a mapped-range request, or an unmap reports.
pub const MapError = Error;

/// The error set an unmap reports.
pub const UnmapError = Error;

/// Ownership returned by a successful unmap. A recorded staging upload must
/// remain alive until its submission completes or native work is safely abandoned.
/// Reserve queue ownership capacity before unmap, then adopt this buffer without
/// a fallible intervening step. A failed unmap leaves staging owned by the buffer.
pub const UnmapResult = struct {
    staging_upload: ?*Buffer = null,
};

/// The error set `writeBuffer` reports.
pub const WriteError = Error;

/// The error set a ring reservation reports.
pub const ReserveError = Error;

/// Only the newest unsubmitted reservation can be cancelled.
pub const CancelReservationError = error{UploadRingReservationNotLast};

/// `ruleName` names every `Rule` member. The switch has no `else`, so a member
/// added without a name here is a compile error, and `test/buffer.zig` calls it
/// for each member of the set.
pub fn ruleName(rule: Rule) []const u8 {
    return switch (rule) {
        error.BufferUsageMissingCopyDst => "buffer usage is missing copy dst",
        error.BufferUsageEmpty => "buffer usages must not be 0",
        error.InternalBufferUsageInvalid => "the internal buffer usage mask is invalid",
        error.BufferUsageMapReadWithOtherUsages => "map read allows only copy dst beside it",
        error.BufferUsageMapWriteWithOtherUsages => "map write allows only copy src beside it",
        error.BufferUsageMissingCopySrc => "buffer usage is missing copy src",
        error.BufferMappedAtCreationSizeNotAligned => {
            return "a buffer mapped at creation needs a size that is a multiple of 4";
        },
        error.BufferSizeAboveLimit => "buffer size is above the max buffer size limit",
        error.BufferAllocationOverflow => "buffer allocation is too large to align",
        error.BufferAllocationHuge => "buffer size is huge and could overflow a driver",
        error.BufferHostVisibleExpected => "a host visible memory type was required and none was reported",
        error.BufferMappedRangeNotAligned => "mapped range offset must be a multiple of 8 and size a multiple of 4",
        error.BufferMappedRangeOutsideBuffer => "the mapped range is outside the buffer",
        error.BufferAlreadyMapped => "the buffer is already mapped",
        error.BufferMapAlreadyPending => "the buffer already has an outstanding map pending",
        error.BufferMapModeMismatch => "the map mode does not match the buffer usages",
        error.BufferMapRangeOutsideBuffer => "the mapping range does not fit in the buffer",
        error.BufferNotMapped => "the buffer is not mapped",
        error.BufferUseWhileInUse => "concurrent buffer operations are not allowed",
        error.BufferUseWhileMapped => "the buffer is used while mapped",
        error.BufferUseWhilePendingMap => "the buffer is used while a map is pending",
        error.BufferUseWithoutSharedMemoryAccess => "the buffer is used without shared memory access",
        error.BufferUseWhileDestroyed => "the buffer is used while destroyed",
        error.BufferWriteOffsetNotAligned => "the write offset must be a multiple of 4",
        error.BufferWriteSizeNotAligned => "the write size must be a multiple of 4",
        error.BufferWriteOutsideBuffer => "the write range is outside the buffer",
        error.UploadRingRequestTooLarge => "the upload request is larger than the ring",
        error.UploadRingExhausted => "the upload ring has no free space before GPU completion",
        error.UploadRingReservationNotLast => "only the newest ring reservation can be cancelled",
        error.UploadRingDeviceMismatch => "the upload ring belongs to a different Vulkan device",
        error.ZeroSizedCopy => "a buffer copy must cover at least one byte",
    };
}

/// The Vulkan state that does not change for the life of a `VkDevice`, taken by
/// value. Nothing in this file reaches for a global, and nothing here is a
/// pointer to the engine's device object.
///
/// Field names match `queue.Context` (`src/engine/queue.zig:62`) so a caller
/// that already holds a queue builds this without restating five values.
pub const Device = struct {
    /// Where a buffer and its staging allocation come from.
    allocator: std.mem.Allocator,
    /// The three-tier Vulkan dispatch table.
    dispatch: vk.Dispatch,
    vk_device: vulkan.VkDevice,
    /// Borrowed physical-device identity for native format capability queries.
    physical_device: vulkan.VkPhysicalDevice = null,
    /// The memory-type table the allocation reads
    /// (`vulkan_device.findMemoryTypeIndex`).
    memory_properties: *const vulkan.VkPhysicalDeviceMemoryProperties,
    /// `nonCoherentAtomSize` from `VkPhysicalDeviceLimits`, which a flush or an
    /// invalidate range must be aligned to (`BufferVk.cpp:197`).
    non_coherent_atom_size: u64,
    /// `maxBufferSize` from `VkPhysicalDeviceMaintenance4Properties`
    /// (`PhysicalDeviceVk.cpp:942`), which creation checks against
    /// (`Buffer.cpp:481`). It is not a `VkPhysicalDeviceLimits` field; the 1.3
    /// block carries a promoted copy upstream does not read.
    max_buffer_size: u64,
    /// The live-handle counter. Every `VkBuffer` and `VkDeviceMemory` this
    /// module creates is counted here and released on destroy, so a teardown
    /// that missed one is a named handle kind rather than a silent leak
    /// (`vulkan_device.HandleSet`).
    handles: *vulkan_device.HandleSet,
};

/// Where one submission's commands go. The queue recycles its recording context
/// per submit (`QueueVk.cpp:376`), so this is a value and not a field.
pub const Recording = struct {
    /// The queue's current recording buffer, begun and not ended
    /// (`Queue.commandBuffer`).
    command_buffer: vulkan.VkCommandBuffer,
    /// The serial this submission will carry
    /// (`Queue::GetPendingCommandSerial`, read at `Buffer.cpp:1169`).
    pending_serial: Serial,
};

/// The device tier of the dispatch table. A device with no loaded table cannot
/// exist: `loadDeviceProcs` returns `error.MissingDeviceProc` before the caller
/// gets here, so a null here is a caller that built a `Device` by hand
/// (`docs/30-port-design.md` §6.3). That is a typed error rather than a panic.
fn procs(device: Device) Error!*const vk.DeviceProcs {
    return device.dispatch.device orelse return error.MissingDeviceProc;
}

/// `GetMemoryKindFor` (`BufferVk.cpp:172`). The kind is the buffer's policy, so
/// it is decided here and handed to the memory type search.
pub const MemoryKind = struct {
    /// `MemoryKind::DeviceLocal` (`BufferVk.cpp:189`).
    device_local: bool,
    /// `MemoryKind::ReadMappable` (`BufferVk.cpp:175`).
    host_readable: bool,
    /// `MemoryKind::WriteMappable` (`BufferVk.cpp:178`).
    host_writable: bool,
};

/// One `VkDeviceMemory` binding, read through the four accessors
/// `BufferVk.cpp:310`-`:322` need.
pub const Allocation = struct {
    memory: vulkan.VkDeviceMemory,
    /// Byte offset into `memory` where this allocation starts.
    offset: u64,
    /// Bytes this allocation owns, as `vkGetBufferMemoryRequirements` reported.
    size: u64,
    /// The memory type's index, which is how the host-visible and host-coherent
    /// flags are read (`BufferVk.cpp:317`).
    memory_type_index: u32,
};

/// `ComputeInternalBufferUsages` (`Buffer.cpp:216`). The returned set is what
/// `getInternalUsage` reports and what every Vulkan mask is derived from.
pub fn computeInternalBufferUsages(usage: BufferUsage) u32 {
    var internal: u32 = usage.toFlags();
    // A storage buffer also gets the read-only bit, and the pass resource
    // tracker keeps the two from being used together.
    if (usage.storage) internal |= read_only_storage_buffer;
    // A texel buffer supports read-only access without the storage bit.
    if (usage.texel_buffer) internal |= read_only_texel_buffer;
    // The query resolve buffer is read by an internal compute pipeline as a
    // storage buffer, so it needs the internal storage bit and not the public
    // one.
    if (usage.query_resolve) internal |= internal_storage_buffer;
    // Sanitizers read arguments and stage records across descriptor-window boundaries.
    if (usage.indirect) internal |= read_only_storage_buffer | internal_copy_src_buffer;
    // Packed blits preserve destination bytes without public copy-source permission.
    if (usage.copy_dst) internal |= internal_copy_src_buffer;
    return internal;
}

/// `ValidateBufferUsageCombinations` (`Buffer.cpp:143`).
///
/// Dawn reads three device features here. `dusk` has no feature table of its own
/// until M7, and a device without `core features and limits` is in compatibility
/// mode (`docs/10-architecture.md` "Compatibility mode"), where the strict rule
/// is the one that applies: map read takes `copy_dst` and nothing else, and map
/// write takes `copy_src` and nothing else.
pub fn validateBufferUsageCombinations(usage: BufferUsage) Rule!void {
    if (usage.toFlags() == 0) return error.BufferUsageEmpty;
    const flags = usage.toFlags();
    if (flags & usage_map_read != 0 and flags & ~(usage_map_read | usage_copy_dst) != 0) {
        return error.BufferUsageMapReadWithOtherUsages;
    }
    if (flags & usage_map_write != 0 and flags & ~(usage_map_write | usage_copy_src) != 0) {
        return error.BufferUsageMapWriteWithOtherUsages;
    }
    return {};
}

/// `ValidateBufferDescriptor` (`Buffer.cpp:438`), minus the host-mapped chain
/// entry, which is M21's row.
pub fn validateBufferDescriptor(
    device: Device,
    descriptor: BufferDescriptor,
) Rule!void {
    try validateBufferUsageCombinations(descriptor.usage);
    if (descriptor.mapped_at_creation) {
        if (descriptor.size % mapped_at_creation_size_alignment != 0) {
            return error.BufferMappedAtCreationSizeNotAligned;
        }
    }
    if (descriptor.size > device.max_buffer_size) return error.BufferSizeAboveLimit;
    return {};
}

/// `VulkanBufferUsage` (`BufferVk.cpp:59`).
pub fn vulkanBufferUsage(usage: u32) vulkan.VkBufferUsageFlags {
    var flags: u32 = 0;
    if (usage & (usage_copy_src | internal_copy_src_buffer) != 0) {
        flags |= @intCast(vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    }
    if (usage & usage_copy_dst != 0) flags |= @intCast(vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    if (usage & usage_index != 0) flags |= @intCast(vulkan.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    if (usage & usage_vertex != 0) flags |= @intCast(vulkan.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    if (usage & usage_uniform != 0) flags |= @intCast(vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    if (usage & (usage_storage | internal_storage_buffer | read_only_storage_buffer) != 0) {
        flags |= @intCast(vulkan.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    }
    if (usage & (usage_texel_buffer | read_only_texel_buffer) != 0) {
        // Both bits are set so one `VkBufferView` serves either descriptor type
        // at bind-group creation, depending on the access mode.
        flags |= @intCast(vulkan.VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT);
        flags |= @intCast(vulkan.VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT);
    }
    if (usage & usage_indirect != 0) flags |= @intCast(vulkan.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
    // A query resolve buffer is written by a transfer, which the copy dst bit
    // alone would not have granted.
    if (usage & usage_query_resolve != 0) flags |= @intCast(vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    return @intCast(flags);
}

/// `VulkanPipelineStage` (`BufferVk.cpp:97`).
pub fn vulkanPipelineStage(
    usage: u32,
    shader_stage: ShaderStage,
) vulkan.VkPipelineStageFlags {
    var flags: u32 = 0;
    if (usage & mappable_buffer_usages != 0) flags |= @intCast(vulkan.VK_PIPELINE_STAGE_HOST_BIT);
    if (usage & (usage_copy_src | usage_copy_dst | internal_copy_src_buffer) != 0) {
        flags |= @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT);
    }
    if (usage & (usage_index | usage_vertex) != 0) {
        flags |= @intCast(vulkan.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT);
    }
    if (usage & shader_buffer_usages != 0) {
        if (shader_stage.vertex) flags |= @intCast(vulkan.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT);
        if (shader_stage.fragment) flags |= @intCast(vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
        if (shader_stage.compute) flags |= @intCast(vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
    }
    if (usage & (usage_indirect | indirect_buffer_for_backend_resource_tracking) != 0) {
        flags |= @intCast(vulkan.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT);
    }
    if (usage & usage_query_resolve != 0) flags |= @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT);
    return @intCast(flags);
}

/// `VulkanAccessFlags` (`BufferVk.cpp:131`).
pub fn vulkanAccessFlags(usage: u32) vulkan.VkAccessFlags {
    var flags: u32 = 0;
    if (usage & usage_map_read != 0) flags |= @intCast(vulkan.VK_ACCESS_HOST_READ_BIT);
    if (usage & usage_map_write != 0) flags |= @intCast(vulkan.VK_ACCESS_HOST_WRITE_BIT);
    if (usage & (usage_copy_src | internal_copy_src_buffer) != 0) {
        flags |= @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT);
    }
    if (usage & usage_copy_dst != 0) flags |= @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT);
    if (usage & usage_index != 0) flags |= @intCast(vulkan.VK_ACCESS_INDEX_READ_BIT);
    if (usage & usage_vertex != 0) flags |= @intCast(vulkan.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT);
    if (usage & usage_uniform != 0) flags |= @intCast(vulkan.VK_ACCESS_UNIFORM_READ_BIT);
    if (usage & (usage_storage | internal_storage_buffer | usage_texel_buffer) != 0) {
        flags |= @intCast(vulkan.VK_ACCESS_SHADER_READ_BIT);
        flags |= @intCast(vulkan.VK_ACCESS_SHADER_WRITE_BIT);
    }
    if (usage & (read_only_storage_buffer | read_only_texel_buffer) != 0) {
        flags |= @intCast(vulkan.VK_ACCESS_SHADER_READ_BIT);
    }
    if (usage & (usage_indirect | indirect_buffer_for_backend_resource_tracking) != 0) {
        flags |= @intCast(vulkan.VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
    }
    if (usage & usage_query_resolve != 0) flags |= @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT);
    return @intCast(flags);
}

/// `memoryKindFor` (`BufferVk.cpp:172`).
pub fn memoryKindFor(usage: u32) MemoryKind {
    // `kDeviceLocalBufferUsages` (`BufferVk.cpp:183`) is every usage that prefers
    // `VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT`.
    const device_local_usages: u32 = usage_index | usage_query_resolve | usage_storage |
        usage_uniform | usage_texel_buffer | usage_vertex | internal_storage_buffer |
        read_only_storage_buffer | read_only_texel_buffer |
        indirect_buffer_for_backend_resource_tracking;
    return .{
        .device_local = usage & device_local_usages != 0,
        .host_readable = usage & usage_map_read != 0,
        .host_writable = usage & usage_map_write != 0,
    };
}

/// `Buffer` is both the front-end object and its Vulkan resource. `usage` is
/// what the caller asked for; `internal_usage` is what the masks come from
/// (`Buffer.h:133`).
///
/// A buffer owns its `VkBuffer`, its `VkDeviceMemory`, and any mapping of that
/// memory, and frees all three in `destroy`. When `staging` is non-null it is a
/// buffer this one created for its own mapped-at-creation range, and this one
/// frees it too.
pub const Buffer = struct {
    device: Device,
    handle: vulkan.VkBuffer,
    allocation: Allocation,
    /// Host pointer over `[allocation.offset, allocation.offset +
    /// allocation.size)`, non-null exactly when the memory kind asked for host
    /// access. It is mapped once at creation and unmapped in `destroy`, which
    /// is what `crbug.com/dawn/774` asks for and what makes the fast upload path
    /// free of a `vkMapMemory` per write.
    mapped: ?[*]u8,
    /// `GetSize` (`Buffer.h:126`).
    size: u64,
    /// `GetAllocatedSize` (`Buffer.h:127`), which is what the `VkBuffer` was
    /// created with.
    allocated_size: u64,
    /// `GetUsage` (`Buffer.h:134`).
    usage: BufferUsage,
    /// `GetInternalUsage` (`Buffer.h:133`).
    internal_usage: u32,
    state: State,
    /// Monotonic map identity. Exhaustion refuses before changing the buffer.
    map_generation: u64 = 0,
    /// Immutable usage target of the current generation; native callers supply
    /// only the serial that actually passed queue submission.
    map_usage_serial: Serial = 0,
    /// `MapMode` (`Buffer.cpp:751`).
    map_mode: MapMode,
    /// `MapOffset` (`Buffer.cpp:755`).
    map_offset: u64,
    /// `MapSize` (`Buffer.cpp:759`). The API-visible length of the mapping,
    /// which is the buffer size at creation and the requested size later.
    map_size: u64,
    is_mapped_at_creation: bool,
    /// `mIsDataInitialized` (`Buffer.cpp:1163`).
    is_data_initialized: bool,
    /// The staging buffer backing a mapped-at-creation range when the
    /// allocation is not CPU writable (`Buffer.cpp:719`).
    staging: ?*Buffer,
    /// `GetLastUsageSerial` (`Buffer.cpp:1179`).
    last_usage_serial: Serial,
    last_write_usage: u32,
    last_write_shader_stage: ShaderStage,
    read_usage: u32,
    read_shader_stages: ShaderStage,
    /// Read from the chosen memory type, not from the descriptor
    /// (`BufferVk.cpp:316`).
    host_visible: bool,
    host_coherent: bool,

    /// `Buffer::Create` (`BufferVk.cpp:224`) plus the `BufferBase` constructor
    /// (`Buffer.cpp:498`).
    ///
    /// Dawn validates, creates, parks the create error, tries the map at
    /// creation, and only then surfaces the parked error (`Device.cpp:1224`
    /// through `:1284`), so a create failure outranks a map failure. The port
    /// reports a typed error instead of an error object and returns in the same
    /// order: a create failure first, a map failure second.
    ///
    /// Nothing is recorded here. Dawn clears the allocation's tail padding at
    /// creation (`BufferVk.cpp:323`), but only because its lazy clear is
    /// toggle-gated; this port always clears on first use, and that clear
    /// covers the whole allocation including the padding, so the creation-time
    /// clear would be a second command for the same bytes.
    ///
    /// The returned buffer belongs to the caller: `destroy` then
    /// `allocator.destroy` returns it.
    pub fn create(
        allocator: std.mem.Allocator,
        device: Device,
        descriptor: BufferDescriptor,
    ) CreateError!*Buffer {
        try validateBufferDescriptor(device, descriptor);
        return createRaw(allocator, device, descriptor, computeInternalBufferUsages(descriptor.usage));
    }

    /// Creates unmapped library storage with no public usage permissions or queue work.
    /// The caller owns the returned allocation and releases it with destroy.
    pub fn createInternal(
        allocator: std.mem.Allocator,
        device: Device,
        options: InternalBufferDescriptor,
    ) CreateError!*Buffer {
        if (options.native_usage == 0 or options.native_usage & ~internal_creation_usages != 0) {
            return error.InternalBufferUsageInvalid;
        }
        if (options.size > device.max_buffer_size) return error.BufferSizeAboveLimit;
        return createRaw(allocator, device, .{
            .size = options.size,
            .usage = .none,
        }, options.native_usage);
    }

    fn createRaw(
        allocator: std.mem.Allocator,
        device: Device,
        descriptor: BufferDescriptor,
        native_usage: u32,
    ) CreateError!*Buffer {
        const self = try allocator.create(Buffer);
        errdefer allocator.destroy(self);
        self.* = .{
            .device = device,
            .handle = null,
            .allocation = .{ .memory = null, .offset = 0, .size = 0, .memory_type_index = 0 },
            .mapped = null,
            .size = descriptor.size,
            .allocated_size = 0,
            .usage = descriptor.usage,
            .internal_usage = native_usage,
            .state = .unmapped,
            .map_mode = .none,
            .map_offset = 0,
            .map_size = 0,
            .is_mapped_at_creation = false,
            .is_data_initialized = false,
            .staging = null,
            .last_usage_serial = 0,
            .last_write_usage = 0,
            .last_write_shader_stage = .none,
            .read_usage = 0,
            .read_shader_stages = .none,
            .host_visible = false,
            .host_coherent = false,
        };

        try self.initialize();
        if (descriptor.label) |label| self.setLabel(label);
        if (descriptor.mapped_at_creation) self.mapAtCreation() catch |err| {
            // Native initialization has already acquired both handles. A failed
            // creation-stage allocation must unwind them before the outer
            // allocator errdefer returns the parent descriptor storage.
            if (self.staging) |staging| {
                try staging.destroy(self.device.allocator);
                self.staging = null;
            }
            try self.destroyVulkan(try procs(self.device));
            return err;
        };
        return self;
    }

    /// `Buffer::Initialize` (`BufferVk.cpp:236`), including the size arithmetic
    /// the driver needs. `InitializeHostMapped` (`BufferVk.cpp:365`) is not
    /// ported: it needs the external-memory import, which is M21.
    fn initialize(self: *Buffer) Error!void {
        var extra_byte_count: u64 = 0;
        if (self.internal_usage & (usage_vertex | usage_index) != 0) {
            extra_byte_count = vertex_index_extra_byte_count;
        }
        if (self.size > std.math.maxInt(u64) - extra_byte_count) {
            return error.BufferAllocationOverflow;
        }
        var size = self.size + extra_byte_count;
        if (size > std.math.maxInt(u64) - fill_alignment) return error.BufferAllocationOverflow;
        size = @max(size, minimum_allocated_size);

        self.allocated_size = std.mem.alignForward(u64, size, fill_alignment);
        if (self.internal_usage & usage_uniform != 0) {
            if (size > std.math.maxInt(u64) - (uniform_allocated_alignment - 1)) {
                return error.BufferAllocationOverflow;
            }
            self.allocated_size = std.mem.alignForward(u64, size, uniform_allocated_alignment);
        }
        // Drivers add constants to the size they are given and align it, so a
        // size with two of the top bits of `VkDeviceSize` set overflows inside
        // the driver and it returns a bad size (khronos issue 1904). Any such
        // size is a HUGE allocation and an out-of-memory one.
        if (self.allocated_size & (@as(u64, 3) << @intCast(62)) != 0) {
            return error.BufferAllocationHuge;
        }

        const create_info: vulkan.VkBufferCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = self.allocated_size,
            // `CopyDst` is always added (`BufferVk.cpp:289`) so initialization can
            // be a `vkCmdFillBuffer` and a mapped-at-creation staging copy can
            // land in a device-local allocation.
            .usage = vulkanBufferUsage(self.internal_usage | usage_copy_dst),
            .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
        };
        const device_procs = try procs(self.device);
        const create_buffer = device_procs.create_buffer orelse
            return error.MissingDeviceProc;
        try vk.checkVkOomThenSuccess(create_buffer(
            self.device.vk_device,
            &create_info,
            null,
            &self.handle,
        ));
        self.device.handles.acquire(.buffer);

        // Everything past the create has something to undo, and the undo reaches
        // three dispatch fields of its own, so it can fail with a typed error
        // (`destroyVulkan`'s own doc comment says so).
        // An `errdefer` cannot carry a second failure, so the tail is one call
        // and the undo is an ordinary statement in its handler: the undo's
        // error replaces the one that entered the handler, because a caller
        // that read the first would go on believing the teardown finished.
        self.requireAndAllocate(device_procs) catch |err| {
            try self.destroyVulkan(device_procs);
            return err;
        };
    }

    /// The half of `initialize` that runs once the `VkBuffer` exists: the memory
    /// requirements the driver reports, then the allocation and the bind.
    ///
    /// Split out so `initialize` can undo it on the failure path: an `errdefer`
    /// would have to drop the undo's own error.
    fn requireAndAllocate(self: *Buffer, device_procs: *const vk.DeviceProcs) Error!void {
        // SAFETY: `get_requirements` writes the whole struct before it returns,
        // and `allocateMemory` reading it below is the first read.
        var requirements: vulkan.VkMemoryRequirements = undefined;
        const get_requirements = device_procs.get_buffer_memory_requirements orelse
            return error.MissingDeviceProc;
        get_requirements(
            self.device.vk_device,
            self.handle,
            &requirements,
        );
        try self.allocateMemory(requirements, memoryKindFor(self.internal_usage));
    }

    /// The `vkAllocateMemory` and `vkBindBufferMemory` pair of `Initialize`
    /// (`BufferVk.cpp:301` through `:314`), with the memory type chosen by M9's
    /// rule and a mapping taken once if the kind asked for host access.
    ///
    /// Each buffer gets its own `VkDeviceMemory`. Dawn sub-allocates through
    /// `ResourceMemoryAllocatorVk`, which is the `memory` module's job; until
    /// that module is in the module graph a dedicated allocation is what
    /// `vkGetBufferMemoryRequirements` asks for, and the `#### M10` table names
    /// this body as the call site that module replaces.
    fn allocateMemory(
        self: *Buffer,
        requirements: vulkan.VkMemoryRequirements,
        kind: MemoryKind,
    ) Error!void {
        var required_flags: vulkan.VkMemoryPropertyFlags = 0;
        if (kind.host_readable or kind.host_writable) {
            required_flags |= @intCast(vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        }
        // `HOST_CACHED` is a preference in Dawn's selector, not a requirement:
        // requiring it would refuse a driver that exposes no cached type for a
        // buffer whose readback is served by an invalidate instead.

        const type_index = vulkan_device.findMemoryTypeIndex(
            self.device.memory_properties,
            requirements.memoryTypeBits,
            required_flags,
            0,
        ) catch |err| switch (err) {
            error.NoMemoryType => return error.BufferHostVisibleExpected,
        };

        const allocate_info: vulkan.VkMemoryAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = type_index,
        };
        var memory: vulkan.VkDeviceMemory = null;
        const device_procs = try procs(self.device);
        const allocate_memory = device_procs.allocate_memory orelse
            return error.MissingDeviceProc;
        try vk.checkVkOomThenSuccess(allocate_memory(
            self.device.vk_device,
            &allocate_info,
            null,
            &memory,
        ));
        // The undo below is scoped to the window in which `memory` is a local
        // nobody else owns. It has to end before `self.allocation` takes it,
        // because an `errdefer` cannot be disarmed: left armed past the
        // assignment, a later refusal (the map below) would free the handle a
        // second time — once here and once again in `destroyVulkan`, which
        // `initialize` runs as the undo of this function. Two frees of one
        // `VkDeviceMemory`, and two `release` calls against one `acquire`.
        bound: {
            const free_memory = device_procs.free_memory orelse
                return error.MissingDeviceProc;
            errdefer free_memory(self.device.vk_device, memory, null);
            self.device.handles.acquire(.memory);
            errdefer self.device.handles.release(.memory);

            const bind_buffer_memory = device_procs.bind_buffer_memory orelse
                return error.MissingDeviceProc;
            try vk.checkVkSuccess(bind_buffer_memory(
                self.device.vk_device,
                self.handle,
                memory,
                0,
            ));
            break :bound;
        }

        const type_properties = self.device.memory_properties.memoryTypes[type_index].propertyFlags;
        const host_visible_bit: vulkan.VkMemoryPropertyFlags =
            @intCast(vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        const host_coherent_bit: vulkan.VkMemoryPropertyFlags =
            @intCast(vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        self.allocation = .{
            .memory = memory,
            .offset = 0,
            .size = requirements.size,
            .memory_type_index = type_index,
        };
        self.host_visible = type_properties & host_visible_bit != 0;
        self.host_coherent = type_properties & host_coherent_bit != 0;

        const wants_host_access = kind.host_readable or kind.host_writable;
        if (wants_host_access and !self.host_visible) return error.BufferHostVisibleExpected;
        if (!wants_host_access) return;

        var data: ?*anyopaque = null;
        const map_memory = device_procs.map_memory orelse
            return error.MissingDeviceProc;
        try vk.checkVkSuccess(map_memory(
            self.device.vk_device,
            memory,
            0,
            requirements.size,
            0,
            &data,
        ));
        self.mapped = @ptrCast(data orelse return error.BufferHostVisibleExpected);
    }

    /// `SetLabelImpl` (`BufferVk.cpp:858`). A null proc is `VK_EXT_debug_utils`
    /// not being enabled, which is not a failure.
    pub fn setLabel(self: *Buffer, label: []const u8) void {
        const instance = self.device.dispatch.instance orelse return;
        const set_object_name = instance.set_debug_utils_object_name_ext orelse return;
        var name_info: vulkan.VkDebugUtilsObjectNameInfoEXT = std.mem.zeroes(
            vulkan.VkDebugUtilsObjectNameInfoEXT,
        );
        // `VkObjectType` is `c_uint` in this translation of the header
        // (`src/vulkan.zig:2484`-`:2485`), not an enumeration, so the constant is cast
        // rather than converted with `@enumFromInt`.
        name_info.objectType = @intCast(vulkan.VK_OBJECT_TYPE_BUFFER);
        name_info.objectHandle = @intFromPtr(self.handle orelse return);
        name_info.pObjectName = @ptrCast(label.ptr);
        _ = set_object_name(self.device.vk_device, &name_info);
    }

    /// `Buffer::DestroyImpl` (`BufferVk.cpp:756`) without the fenced deleter,
    /// which is M9's handle accounting, and without the host-mapped dispose
    /// callback, which is M21's row.
    ///
    /// A mapped-at-creation staging range is dropped rather than copied, because
    /// the contents are about to be freed with the buffer (`Buffer.cpp:971`).
    ///
    /// **This frees the descriptor too.** `Buffer` is not an arena object: it
    /// has no `Object` header, so nothing else owns the block `create` took and
    /// the destructor is the only place that can return it. `allocator` is the
    /// one `create` was given, named here because the caller is the only holder
    /// of it. `Device.deinit` takes its allocator the same way.
    pub fn destroy(self: *Buffer, allocator: std.mem.Allocator) Error!void {
        // The staging buffer came from `self.device.allocator` (`create` is
        // called with it), not from `allocator`, so it goes back where it came
        // from. Each staging buffer destroys itself, so this is one call.
        if (self.staging) |staging| {
            try staging.destroy(self.device.allocator);
            self.staging = null;
        }
        self.state = .destroyed;
        try self.destroyVulkan(try procs(self.device));
        // The teardown above read every field, so the block goes back last.
        allocator.destroy(self);
    }

    /// The Vulkan teardown, separated so `initialize` can `errdefer` it without
    /// touching the state machine or freeing a staging buffer that does not
    /// exist yet.
    ///
    /// It reports rather than returning `void`, because each of the three
    /// procs it reaches is a dispatch field and a null one is a typed error.
    /// The table is a parameter so `initialize` can hand
    /// over the one it already resolved.
    fn destroyVulkan(self: *Buffer, device_procs: *const vk.DeviceProcs) Error!void {
        if (self.mapped) |_| {
            const unmap_memory = device_procs.unmap_memory orelse
                return error.MissingDeviceProc;
            unmap_memory(self.device.vk_device, self.allocation.memory);
            self.mapped = null;
        }
        if (self.handle != null) {
            const destroy_buffer = device_procs.destroy_buffer orelse
                return error.MissingDeviceProc;
            destroy_buffer(self.device.vk_device, self.handle, null);
            self.device.handles.release(.buffer);
            self.handle = null;
        }
        if (self.allocation.memory != null) {
            const free_memory = device_procs.free_memory orelse
                return error.MissingDeviceProc;
            free_memory(self.device.vk_device, self.allocation.memory, null);
            self.device.handles.release(.memory);
            self.allocation.memory = null;
        }
    }

    /// `Buffer::GetHandle` (`BufferVk.cpp:458`).
    pub fn getHandle(self: *const Buffer) vulkan.VkBuffer {
        return self.handle;
    }

    /// `GetState` (`Buffer.cpp:747`).
    pub fn getState(self: *const Buffer) State {
        return self.state;
    }

    /// `GetMapMode` (`Buffer.cpp:751`).
    pub fn getMapMode(self: *const Buffer) MapMode {
        return self.map_mode;
    }

    /// `MapOffset` (`Buffer.cpp:755`).
    pub fn getMapOffset(self: *const Buffer) u64 {
        return self.map_offset;
    }

    /// `MapSize` (`Buffer.cpp:759`).
    pub fn getMapSize(self: *const Buffer) u64 {
        return self.map_size;
    }

    /// `GetSize` (`Buffer.h:126`).
    pub fn getSize(self: *const Buffer) u64 {
        return self.size;
    }

    /// `GetAllocatedSize` (`Buffer.h:127`).
    pub fn getAllocatedSize(self: *const Buffer) u64 {
        return self.allocated_size;
    }

    /// `GetUsage` (`Buffer.h:134`).
    pub fn getUsage(self: *const Buffer) BufferUsage {
        return self.usage;
    }

    /// `GetInternalUsage` (`Buffer.h:133`).
    pub fn getInternalUsage(self: *const Buffer) u32 {
        return self.internal_usage;
    }

    /// `NeedsInitialization` (`Buffer.cpp:1162`). Dawn gates this on
    /// `Toggle::LazyClearResourceOnFirstUse`, which defaults on
    /// (`Adapter.cpp:254`). The port has no toggle table until M7 and keeps the
    /// on behaviour, so a created buffer is zero on first use.
    pub fn needsInitialization(self: *const Buffer) bool {
        return !self.is_data_initialized;
    }

    /// `MarkUsedInPendingCommands` (`Buffer.cpp:1172`).
    pub fn markUsedInPendingCommands(self: *Buffer, pending_serial: Serial) void {
        self.last_usage_serial = pending_serial;
    }

    /// `GetLastUsageSerial` (`Buffer.cpp:1179`).
    pub fn getLastUsageSerial(self: *const Buffer) Serial {
        return self.last_usage_serial;
    }

    /// `IsFullBufferRange` (`Buffer.cpp:1229`).
    pub fn isFullBufferRange(self: *const Buffer, offset: u64, size: u64) bool {
        return offset == 0 and size == self.size;
    }

    /// `FinishUse` (`Buffer.cpp:791`), reached through the scope that
    /// `validateCanUseOnQueueNow` opens.
    pub fn finishUse(self: *Buffer) void {
        std.debug.assert(self.state == .in_use);
        self.state = .unmapped;
    }

    /// `ValidateCanUseOnQueueNow` (`Buffer.cpp:769`), which every queue-side
    /// entry point runs before it touches a buffer. On success the state is
    /// `in_use` and `finishUse` closes the scope.
    pub fn validateCanUseOnQueueNow(self: *Buffer) Rule!void {
        return switch (self.state) {
            .destroyed => error.BufferUseWhileDestroyed,
            .mapped, .mapped_at_creation => error.BufferUseWhileMapped,
            .pending_map => error.BufferUseWhilePendingMap,
            .shared_memory_no_access => error.BufferUseWithoutSharedMemoryAccess,
            .in_use => error.BufferUseWhileInUse,
            .unmapped => {
                self.state = .in_use;
                return {};
            },
        };
    }

    /// `TransitionState` (`Buffer.cpp:1262`). The port holds the state in one
    /// field under the device mutex rather than in an atomic with compare and
    /// exchange, so a lost race is the caller's error to name, not a spin.
    fn transitionState(self: *Buffer, current: State, desired: State) Rule!void {
        if (self.state != current) return error.BufferUseWhileInUse;
        self.state = desired;
        return {};
    }

    /// `TrackUsageAndGetResourceBarrier` (`BufferVk.cpp:470`). One function,
    /// one order, because every buffer barrier in the back end comes through it.
    ///
    /// The barrier returned is `recording_context.BufferBarrier` and is
    /// submitted by `recording_context.emitBufferBarrierIfNecessary`: both are
    /// the one `vkCmdPipelineBarrier` this row reaches
    /// (`CommandRecordingContextVk.cpp:42`), so `recording_context.zig` owns
    /// them and this file carries no second copy.
    pub fn trackUsageAndGetResourceBarrier(
        self: *Buffer,
        recording: Recording,
        usage: u32,
        shader_stage: ShaderStage,
    ) recording_context.BufferBarrier {
        // A usage in no shader stage drops the shader bits: a uniform buffer no
        // shader reads is not a shader read (`BufferVk.cpp:472`).
        var wanted = usage;
        if (shader_stage.toFlags() == ShaderStage.none.toFlags()) {
            wanted &= ~shader_buffer_usages;
        }

        const is_map_usage = wanted & mappable_buffer_usages != 0;
        if (!is_map_usage) {
            // A non-CPU usage means the buffer is used by pending commands.
            self.markUsedInPendingCommands(recording.pending_serial);
        }
        // A map usage gets no HOST to GPU barrier, and none is needed: a map
        // read is ordered by the submit that follows it, and a map write is made
        // available by the flush or by coherence, which `vkQueueSubmit` turns
        // into a host to device dependency (`BufferVk.cpp:481` through `:487`).

        const read_only = wanted & ~read_only_buffer_usages == 0;
        var src_access: vulkan.VkAccessFlags = 0;
        var src_stages: vulkan.VkPipelineStageFlags = 0;

        if (read_only) {
            // The vertex stage to fragment stage dependency is implicit, so a
            // fragment read after a vertex read needs no barrier of its own.
            // Recording the fragment stage is what makes the next write wait.
            if (shader_stage.fragment and self.read_shader_stages.vertex) {
                self.read_shader_stages.fragment = true;
            }
            if (wanted & ~self.read_usage == 0 and
                shader_stage.toFlags() & ~self.read_shader_stages.toFlags() == 0)
            {
                // This usage and this stage already waited for the last write.
                return .{};
            }
            // Widen to every read-only shader usage now, so a later read needs
            // no barrier of its own (`BufferVk.cpp:510`).
            if (wanted & read_only_shader_buffer_usages != 0) {
                wanted |= self.internal_usage & read_only_shader_buffer_usages;
            }
            if (!is_map_usage) {
                self.read_usage |= wanted;
                self.read_shader_stages = self.read_shader_stages.merge(shader_stage);
            }
            if (self.last_write_usage == 0) {
                // A read with no prior write needs no barrier.
                return .{};
            }
            src_access = vulkanAccessFlags(self.last_write_usage);
            src_stages = vulkanPipelineStage(self.last_write_usage, self.last_write_shader_stage);
        } else {
            var skip_barrier = false;
            if (self.last_write_usage == 0 and self.read_usage == 0) {
                // The buffer has never been used.
                skip_barrier = true;
            } else if (self.read_usage == 0) {
                // Write after write.
                src_access = vulkanAccessFlags(self.last_write_usage);
                src_stages = vulkanPipelineStage(
                    self.last_write_usage,
                    self.last_write_shader_stage,
                );
            } else {
                // Read after write.
                src_access = vulkanAccessFlags(self.read_usage);
                src_stages = vulkanPipelineStage(self.read_usage, self.read_shader_stages);
            }
            if (!is_map_usage) {
                self.last_write_usage = wanted;
                self.last_write_shader_stage = shader_stage;
                self.read_usage = 0;
                self.read_shader_stages = .none;
            }
            if (skip_barrier) return .{};
        }

        return .{
            .src_stage_mask = src_stages,
            .dst_stage_mask = vulkanPipelineStage(wanted, shader_stage),
            .src_access_mask = src_access,
            .dst_access_mask = vulkanAccessFlags(wanted),
        };
    }

    /// `TransitionUsageNow` (`BufferVk.cpp:462`).
    pub fn transitionUsageNow(
        self: *Buffer,
        recording: Recording,
        usage: u32,
        shader_stage: ShaderStage,
    ) Error!void {
        const barrier = self.trackUsageAndGetResourceBarrier(
            recording,
            usage,
            shader_stage,
        );
        recording_context.emitBufferBarrierIfNecessary(
            .{
                .procs = try procs(self.device),
                .vk_device = self.device.vk_device,
            },
            recording.command_buffer,
            barrier,
        );
    }

    /// `TransitionMappableBuffersEagerly` (`BufferVk.cpp:840`), one barrier per
    /// buffer merged into one emission. The queue calls this at submit for the
    /// buffers it collected (`QueueVk.cpp:314`).
    ///
    /// The slice must not be empty, because a zero-count walk emits nothing and
    /// a caller that reached it with an empty slice has already lost its list.
    pub fn transitionMappableBuffersEagerly(
        buffers: []const *Buffer,
        recording: Recording,
    ) Error!void {
        std.debug.assert(buffers.len > 0);
        var barrier: recording_context.BufferBarrier = .{};
        for (buffers) |buffer| {
            const one = buffer.trackUsageAndGetResourceBarrier(
                recording,
                buffer.internal_usage & mappable_buffer_usages,
                .none,
            );
            // `BufferBarrier::Merge` (`BufferVk.cpp:891`) unions the four masks
            // and does nothing else, so the union is written here: the type is
            // `recording_context.BufferBarrier` beside the row that submits it,
            // and a method on it belongs to that file.
            barrier.src_stage_mask |= one.src_stage_mask;
            barrier.dst_stage_mask |= one.dst_stage_mask;
            barrier.src_access_mask |= one.src_access_mask;
            barrier.dst_access_mask |= one.dst_access_mask;
        }
        recording_context.emitBufferBarrierIfNecessary(
            .{
                .procs = try procs(buffers[0].device),
                .vk_device = buffers[0].device.vk_device,
            },
            recording.command_buffer,
            barrier,
        );
    }

    /// `ClearBuffer` (`BufferVk.cpp:870`). `vkCmdFillBuffer` needs a size that is
    /// a multiple of four, which is why every caller aligns its size first.
    fn clearBuffer(
        device: Device,
        recording: Recording,
        handle: vulkan.VkBuffer,
        offset: u64,
        size: u64,
        data: u32,
    ) Error!void {
        if (size == 0) return;
        std.debug.assert(size % fill_alignment == 0);
        const device_procs = try procs(device);
        const cmd_fill_buffer = device_procs.cmd_fill_buffer orelse
            return error.MissingDeviceProc;
        cmd_fill_buffer(
            recording.command_buffer,
            handle,
            offset,
            size,
            data,
        );
    }

    /// `InitializeToZero` (`BufferVk.cpp:862`).
    fn initializeToZero(self: *Buffer, recording: Recording) Error!void {
        try self.transitionUsageNow(recording, usage_copy_dst, .none);
        try clearBuffer(self.device, recording, self.handle, 0, self.allocated_size, 0);
        self.is_data_initialized = true;
    }

    /// `EnsureDataInitializedAsDestination(offset, size)`
    /// (`BufferVk.cpp:808`).
    pub fn ensureDataInitializedAsDestination(
        self: *Buffer,
        recording: Recording,
        offset: u64,
        size: u64,
    ) Error!void {
        if (!self.needsInitialization()) return;
        if (self.isFullBufferRange(offset, size)) {
            // Every byte is overwritten, so a clear would be a wasted command.
            self.is_data_initialized = true;
            return;
        }
        try self.initializeToZero(recording);
    }

    /// `GetMappedMemoryRange` (`BufferVk.cpp:197`). The offset goes down to an
    /// atom boundary and the size up to one, then the result is clamped to the
    /// allocation, which is what a flush or an invalidate range must be.
    fn mappedMemoryRange(
        self: *const Buffer,
        offset: u64,
        size: u64,
    ) vulkan.VkMappedMemoryRange {
        const atom = self.device.non_coherent_atom_size;
        const full_offset = self.allocation.offset + offset;
        const aligned_offset = std.mem.alignBackward(u64, full_offset, atom);
        const aligned_size = std.mem.alignForward(u64, full_offset - aligned_offset + size, atom);
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = self.allocation.memory,
            .offset = aligned_offset,
            .size = @min(aligned_size, self.allocation.size - aligned_offset),
        };
    }

    /// The invalidate of `FinalizeMapImpl` (`BufferVk.cpp:604` through `:620`).
    fn invalidateRange(self: *const Buffer, offset: u64, size: u64) Error!void {
        const range = self.mappedMemoryRange(offset, size);
        const device_procs = try procs(self.device);
        const invalidate = device_procs.invalidate_mapped_memory_ranges orelse
            return error.MissingDeviceProc;
        try vk.checkVkSuccess(invalidate(
            self.device.vk_device,
            1,
            &range,
        ));
    }

    /// The flush of `UnmapImpl` (`BufferVk.cpp:623` through `:635`).
    fn flushRange(self: *const Buffer, offset: u64, size: u64) Error!void {
        const range = self.mappedMemoryRange(offset, size);
        const device_procs = try procs(self.device);
        const flush = device_procs.flush_mapped_memory_ranges orelse
            return error.MissingDeviceProc;
        try vk.checkVkSuccess(flush(
            self.device.vk_device,
            1,
            &range,
        ));
    }

    /// `MapMemoryAndPerformOperation` (`BufferVk.cpp:689`) over the mapping this
    /// buffer keeps for its whole life, which is what `crbug.com/dawn/774` asks
    /// for. The operation is a context and a function rather than a closure, so
    /// nothing is captured and the caller names its own state.
    fn mapMemoryAndPerformOperation(
        self: *const Buffer,
        requested_offset: u64,
        requested_size: u64,
        context: anytype,
        perform: *const fn (context: @TypeOf(context), mapped: []u8) void,
    ) Error!void {
        const base = self.mapped orelse return error.BufferHostVisibleExpected;
        const whole = base[self.allocation.offset..][0..self.allocation.size];

        if (!self.host_coherent) try self.invalidateRange(0, self.allocation.size);
        perform(context, whole[requested_offset..][0..requested_size]);
        if (!self.host_coherent) try self.flushRange(0, self.allocation.size);
        return;
    }

    /// The bytes behind the current mapping, which is either this allocation's
    /// or the staging buffer's. A buffer with no mapping has no map usage, and
    /// every caller of this runs only once a mapping exists.
    pub fn mappedSpan(self: *const Buffer) []u8 {
        if (self.staging) |staging| return staging.mappedSpan();
        const base = self.mapped orelse unreachable;
        return base[self.allocation.offset..][0..self.allocation.size];
    }

    /// `IsCPUWritableAtCreation` (`BufferVk.cpp:565`). Dawn answers it as "the
    /// allocation has a mapped span"; this port answers the same fact.
    pub fn isCpuWritableAtCreation(self: *const Buffer) bool {
        return self.mapped != null;
    }

    /// `MapAtCreation` (`Buffer.cpp:673`) and `MapAtCreationInternal`
    /// (`Buffer.cpp:707`), together.
    fn mapAtCreation(self: *Buffer) CreateError!void {
        // The state only becomes mapped at creation once nothing below has
        // failed, so a buffer that fails to map is still destroyable as
        // unmapped (`Buffer.cpp:735`).
        if (self.size != 0 and !self.isCpuWritableAtCreation()) {
            // Sub-path B: an allocation the CPU cannot write gets a staging
            // buffer the size of the whole allocation, so every byte the caller
            // writes has somewhere to land (`Buffer.cpp:719` through `:733`).
            self.staging = try Buffer.create(self.device.allocator, self.device, .{
                .label = "Dawn_MappedAtCreationStaging",
                .usage = .{ .copy_src = true, .map_write = true },
                .size = std.mem.alignForward(
                    u64,
                    self.allocated_size,
                    mapped_at_creation_size_alignment,
                ),
                .mapped_at_creation = true,
            });
        }

        self.map_mode = .{ .write = true };
        self.map_offset = 0;
        self.map_size = self.size;
        self.is_mapped_at_creation = true;
        try self.finalizeMap(.mapped_at_creation);
        // Staging was itself created mapped and zeroed across the full allocated
        // range. Mark either path initialized so no later clear overwrites it.

        // Sub-path A: the caller is about to write this allocation directly, so
        // it holds the initial bytes. The whole allocated range is zeroed, not
        // the user-visible one, because the internal full-range view reaches the
        // padding (`Buffer.cpp:688` through `:696`). Marking it initialized
        // stops a later clear from overwriting what the caller writes
        // (`Buffer.cpp:702`).
        if (self.staging == null and self.size != 0) @memset(self.mappedSpan()[0..self.allocated_size], 0);
        self.is_data_initialized = true;
        return;
    }

    /// `FinalizeMap` (`Buffer.cpp:630`). The only two transitions are
    /// `pending_map` to `mapped` and `unmapped` to `mapped_at_creation`.
    fn finalizeMap(self: *Buffer, new_state: State) Error!void {
        const pending_to_mapped = self.state == .pending_map and new_state == .mapped;
        const unmapped_to_at_creation = self.state == .unmapped and
            new_state == .mapped_at_creation;
        std.debug.assert(pending_to_mapped or unmapped_to_at_creation);

        // A failure here leaves the state as it was, so the buffer is still
        // destroyable (`Buffer.cpp:638`).
        errdefer self.state = .unmapped;
        try self.finalizeMapImpl(new_state);
        self.state = new_state;
    }

    /// `FinalizeMapImpl` (`BufferVk.cpp:578`).
    fn finalizeMapImpl(self: *Buffer, new_state: State) Error!void {
        // A mapped-at-creation range was already zeroed by `mapAtCreation`, so
        // the lazy clear belongs to a real map only (`BufferVk.cpp:583`).
        if (self.needsInitialization() and self.size != 0 and new_state == .mapped) {
            @memset(self.mappedSpan()[0..self.allocated_size], 0);
            self.is_data_initialized = true;
            if (!self.host_coherent and
                (self.map_mode.read or self.map_offset != 0 or self.map_size != self.size))
            {
                // The unmap will not flush the whole allocation, so this clear
                // has to be written back now.
                try self.flushRange(0, self.allocation.size);
            }
        }
        if (self.host_coherent) return;
        // A map read always needs an invalidate. A map write needs one unless
        // nothing on the GPU could have written the range, which is the case for
        // a buffer mapped at creation and for a buffer nothing else writes
        // (`BufferVk.cpp:607`).
        const gpu_writable = self.internal_usage & ~(read_only_buffer_usages | usage_map_write) != 0;
        if (self.map_mode.read or (new_state != .mapped_at_creation and gpu_writable)) {
            try self.invalidateRange(self.map_offset, self.map_size);
        }
    }

    /// `ValidateMapAsync` (`Buffer.cpp:1067`).
    pub fn validateMapAsync(
        self: *const Buffer,
        mode: MapMode,
        offset: u64,
        size: u64,
    ) Rule!void {
        if (mode.toFlags() != 1 and mode.toFlags() != 2) return error.BufferMapModeMismatch;
        if (offset > self.size) return error.BufferMapRangeOutsideBuffer;
        if (offset % map_offset_alignment != 0) return error.BufferMappedRangeNotAligned;
        if (size % map_size_alignment != 0) return error.BufferMappedRangeNotAligned;
        if (size > self.size - offset) return error.BufferMapRangeOutsideBuffer;
        if (mode.read) {
            if (!self.usage.map_read) return error.BufferMapModeMismatch;
        } else if (mode.write) {
            if (!self.usage.map_write) return error.BufferMapModeMismatch;
        } else return error.BufferMapModeMismatch;
        return {};
    }

    /// `CanGetMappedRange` (`Buffer.cpp:1104`).
    ///
    /// `writable` is upstream's first parameter and the only input the mode
    /// check reads; a read request never fails that check.
    fn canGetMappedRange(self: *const Buffer, writable: bool, offset: u64, size: u64) Rule!void {
        switch (self.state) {
            // A mapped-at-creation range is always writable.
            .mapped_at_creation => {},
            .mapped => {
                // Exactly one mode bit is set while mapped, which is the XOR
                // `Buffer.cpp:1119`-`:1120` asserts. Only a writable request
                // reads the write bit: a read-only mapping serves
                // `GetConstMappedRange` and hands the caller a read-only span,
                // so refusing it here would leave no way to read at all.
                // Dawn logs "GetMappedRange: Mapping is read-only. Use
                // GetConstMappedRange instead." at `:1122` before returning
                // false; the port has no device to log through, and the
                // refused call is the error itself.
                if (writable and !self.map_mode.write) return error.BufferMapModeMismatch;
            },
            .pending_map => return error.BufferUseWhilePendingMap,
            .unmapped => return error.BufferNotMapped,
            .in_use => return error.BufferUseWhileInUse,
            .shared_memory_no_access => return error.BufferUseWithoutSharedMemoryAccess,
            .destroyed => return error.BufferUseWhileDestroyed,
        }
        if (offset % map_offset_alignment != 0 or size % map_size_alignment != 0) {
            return error.BufferMappedRangeNotAligned;
        }
        if (offset < self.map_offset or offset > self.size) {
            return error.BufferMappedRangeOutsideBuffer;
        }
        if (size > self.map_size) return error.BufferMappedRangeOutsideBuffer;
        if (offset - self.map_offset > self.map_size - size) {
            return error.BufferMappedRangeOutsideBuffer;
        }
        return {};
    }

    /// `GetMappedRange` (`Buffer.cpp:897`), over `GetMappedRangeInternal` with
    /// `writable` true.
    pub fn getMappedRange(self: *const Buffer, offset: u64, size: u64) MapError![]u8 {
        return self.getMappedRangeInternal(offset, size, true);
    }

    /// `APIGetConstMappedRange` (`Buffer.cpp:873`), over `GetMappedRangeInternal`
    /// with `writable` false.
    ///
    /// Upstream returns `const void*` here, so this returns `[]const u8`. A
    /// read-only mapping must not hand out a slice its caller can write
    /// through; a `[]u8` would defeat the check at `Buffer.cpp:1121`, which
    /// exists for exactly that reason.
    pub fn getConstMappedRange(
        self: *const Buffer,
        offset: u64,
        size: u64,
    ) MapError![]const u8 {
        return self.getMappedRangeInternal(offset, size, false);
    }

    /// `GetMappedRangeInternal` (`Buffer.cpp:903`).
    ///
    /// `whole_map_size` means "to the end of the buffer", which is the WebGPU
    /// default at `Buffer.cpp:810`.
    fn getMappedRangeInternal(
        self: *const Buffer,
        offset: u64,
        size: u64,
        writable: bool,
    ) MapError![]u8 {
        if (offset > self.size) return error.BufferMappedRangeOutsideBuffer;
        const wanted = if (size == whole_map_size) self.size - offset else size;
        try self.canGetMappedRange(writable, offset, wanted);
        if (wanted == 0) return &.{};
        const span = self.mappedSpan();
        return span[offset..][0..wanted];
    }

    /// Byte range for a pending map. `whole_map_size` maps to the buffer end.
    pub const MapBeginOptions = struct {
        mode: MapMode,
        offset: u64 = 0,
        size: u64 = whole_map_size,
        /// Null preserves standalone raw pending-use semantics. Native admission
        /// supplies its actual accepted target under queue gate + ObjectGuard.
        submitted_usage_serial: ?Serial = null,
    };
    pub const MapCompletion = enum { mapped, aborted };

    /// Validates and reserves a generation, leaving the buffer pending, not mapped.
    /// Caller holds the owning ObjectGuard and queue admission gate.
    /// No GPU serial is completed here. On failure the prior state is unchanged.
    pub fn beginMap(self: *Buffer, options: MapBeginOptions) MapError!u64 {
        const offset = options.offset;
        var size = options.size;
        if (size == whole_map_size and offset <= self.size) size = self.size - offset;

        switch (self.state) {
            .mapped, .mapped_at_creation => return error.BufferAlreadyMapped,
            .in_use => return error.BufferUseWhileInUse,
            .pending_map => return error.BufferMapAlreadyPending,
            .destroyed => return error.BufferUseWhileDestroyed,
            .shared_memory_no_access => return error.BufferUseWithoutSharedMemoryAccess,
            .unmapped => {},
        }
        try self.validateMapAsync(options.mode, offset, size);
        if (self.map_generation == std.math.maxInt(u64)) return error.MapGenerationExhausted;
        self.map_generation += 1;
        self.map_mode = options.mode;
        self.map_offset = offset;
        self.map_size = size;
        self.map_usage_serial = options.submitted_usage_serial orelse self.last_usage_serial;
        self.state = .pending_map;
        return self.map_generation;
    }

    /// Completes only the matching alive pending generation after real fence completion.
    /// Unmap, destruction, or a later map makes an old generation permanently aborted.
    pub fn completeMap(self: *Buffer, generation: u64, completed_serial: Serial) MapError!MapCompletion {
        if (self.state != .pending_map or self.map_generation != generation) return .aborted;
        if (self.map_usage_serial > completed_serial) return error.BufferUseWhileInUse;
        try self.finalizeMap(.mapped);
        return .mapped;
    }

    /// Cancels only the named pending generation. Staging ownership is unchanged.
    pub fn cancelMap(self: *Buffer, generation: u64) bool {
        if (self.state != .pending_map or self.map_generation != generation) return false;
        self.state = .unmapped;
        self.map_mode = .none;
        self.map_offset = 0;
        self.map_size = 0;
        return true;
    }

    /// `ValidateUnmap` (`Buffer.cpp:1156`). A host-mapped buffer is the only one
    /// that cannot be unmapped, and that is M21's row, so nothing is refused
    /// here yet.
    pub fn validateUnmap(self: *const Buffer) Rule!void {
        _ = self;
        return {};
    }

    /// Cancels a pending map or ends a mapped range without retiring staged GPU bytes.
    ///
    /// The caller owns the returned staging upload. Recording a copy does not
    /// submit it or end its lifetime; transfer it to the queue's reserved slot.
    pub fn unmap(self: *Buffer, recording: Recording) UnmapError!UnmapResult {
        try self.validateUnmap();
        var result: UnmapResult = .{};
        switch (self.state) {
            .destroyed, .unmapped => return result,
            .pending_map => {
                const canceled = self.cancelMap(self.map_generation);
                std.debug.assert(canceled);
                return result;
            },
            .in_use => return error.BufferUseWhileInUse,
            .shared_memory_no_access => return error.BufferUseWithoutSharedMemoryAccess,
            .mapped => {
                try self.transitionState(.mapped, .in_use);
                errdefer self.state = .mapped;
                try self.unmapImpl(.mapped);
            },
            .mapped_at_creation => {
                try self.transitionState(.mapped_at_creation, .in_use);
                errdefer self.state = .mapped_at_creation;
                if (self.staging != null) {
                    result.staging_upload = try self.copyFromStagingBuffer(recording);
                } else if (self.size != 0 and self.isCpuWritableAtCreation()) {
                    try self.unmapImpl(.mapped_at_creation);
                }
                self.is_mapped_at_creation = false;
            },
        }
        self.state = .unmapped;
        return result;
    }

    /// `UnmapImpl` (`BufferVk.cpp:623`). CPU-visible memory stays mapped for
    /// ever, so the only thing an unmap does is flush a write.
    fn unmapImpl(self: *const Buffer, old_state: State) Error!void {
        if (!self.host_coherent and isMappedState(old_state) and self.map_mode.write) {
            try self.flushRange(self.map_offset, self.map_size);
        }
    }

    /// `CopyFromStagingBuffer` (`Buffer.cpp:933`): the staged bytes reach the
    /// destination as one recorded `vkCmdCopyBuffer`. Ownership transfers only
    /// after recording succeeds; the caller retires the upload by submission serial.
    fn copyFromStagingBuffer(self: *Buffer, recording: Recording) Error!*Buffer {
        const staging = self.staging.?;
        // The CPU keeps the staging mapping while a failed recording can retry.
        // Flush its actual writes before recording; ownership transfers only
        // after the native copy succeeds, not after public usage validation.
        try staging.unmapImpl(.mapped_at_creation);
        try self.recordCopyBufferNative(recording, staging, 0, 0, self.allocated_size);
        self.staging = null;
        return staging;
    }

    /// `WriteBufferOptions`.
    pub const WriteBufferOptions = struct {
        buffer_offset: u64 = 0,
        data: []const u8 = &.{},
        /// The serial the caller has completed, which is what decides between
        /// the two upload paths (`BufferVk.cpp:648`).
        completed_serial: Serial = 0,
    };

    /// `ValidateWriteBuffer` (`CommandValidation.cpp:228`), the four rules a
    /// write runs before it reaches an upload path.
    pub fn validateWriteBuffer(
        self: *const Buffer,
        options: WriteBufferOptions,
    ) Rule!void {
        if (!self.usage.copy_dst) return error.BufferUsageMissingCopyDst;
        if (options.buffer_offset % copy_offset_alignment != 0) {
            return error.BufferWriteOffsetNotAligned;
        }
        if (options.data.len % copy_offset_alignment != 0) return error.BufferWriteSizeNotAligned;
        if (options.buffer_offset > self.size) return error.BufferWriteOutsideBuffer;
        if (options.data.len > self.size - options.buffer_offset) {
            return error.BufferWriteOutsideBuffer;
        }
        return {};
    }

    /// `QueueBase::WriteBufferImpl` (`Queue.cpp:338`) into
    /// `vulkan::Buffer::UploadData` (`BufferVk.cpp:641`).
    ///
    /// The buffer leaves this call unmapped or unmapped-and-freed of the use
    /// scope, whichever it entered in: `validateCanUseOnQueueNow` opens the
    /// scope and `finishUse` closes it on both paths.
    pub fn writeBuffer(
        self: *Buffer,
        ring: *UploadRing,
        recording: Recording,
        options: WriteBufferOptions,
    ) WriteError!void {
        try self.validateWriteBuffer(options);
        try self.validateCanUseOnQueueNow();
        errdefer self.finishUse();
        try self.uploadData(ring, recording, options);
        self.finishUse();
        return;
    }

    /// `vulkan::Buffer::UploadData` (`BufferVk.cpp:641`): the fast path, and the
    /// fallback that reaches the staging ring whenever a precondition for the
    /// fast path fails.
    fn uploadData(
        self: *Buffer,
        ring: *UploadRing,
        recording: Recording,
        options: WriteBufferOptions,
    ) WriteError!void {
        if (options.data.len == 0) return;
        const is_in_use = self.last_usage_serial > options.completed_serial;
        // Even a finished write workload may still need a barrier to become
        // visible, and only a map-write buffer is known to have had its GPU to
        // host barrier emitted eagerly (`BufferVk.cpp:652`).
        const has_pending_writes = self.internal_usage & usage_map_write == 0 and
            self.last_write_usage != 0;
        if (is_in_use or has_pending_writes or !self.isCpuWritableAtCreation()) {
            return self.uploadThroughRing(ring, recording, options);
        }
        return self.uploadDirect(options);
    }

    /// `BufferBase::UploadData` (`Buffer.cpp:1183`): the bytes go through the
    /// staging ring and reach the destination as a recorded `vkCmdCopyBuffer`.
    /// The destination's own memory is never touched on the CPU.
    fn uploadThroughRing(
        self: *Buffer,
        ring: *UploadRing,
        recording: Recording,
        options: WriteBufferOptions,
    ) WriteError!void {
        if (self.device.vk_device != ring.device.vk_device) return error.UploadRingDeviceMismatch;
        const reservation = try UploadRing.reserve(
            ring.device.allocator,
            ring,
            .{ .byte_count = options.data.len, .at_serial = recording.pending_serial },
        );
        errdefer ring.cancelLast(reservation) catch
            @panic("buffer: failed to cancel the newest ring reservation");
        @memcpy(reservation.mapped[0..options.data.len], options.data);
        try self.recordCopyBuffer(
            recording,
            reservation.buffer,
            reservation.offset,
            options.buffer_offset,
            options.data.len,
        );
        return;
    }

    /// The second half of `vulkan::Buffer::UploadData` (`BufferVk.cpp:674`):
    /// write into the destination's own mapping. A partial write clears the
    /// whole allocation first, so the bytes outside the write are zero rather
    /// than whatever was there.
    fn uploadDirect(self: *Buffer, options: WriteBufferOptions) WriteError!void {
        const zero_first = self.needsInitialization() and options.data.len < self.size;
        var context: DirectUpload = .{
            .buffer = self,
            .data = options.data,
            .buffer_offset = options.buffer_offset,
            .zero_first = zero_first,
        };
        try self.mapMemoryAndPerformOperation(
            if (zero_first) 0 else options.buffer_offset,
            if (zero_first) self.allocated_size else options.data.len,
            &context,
            DirectUpload.perform,
        );
        return;
    }

    /// The operation `uploadDirect` runs over the mapped range. Its state is a
    /// parameter rather than a capture.
    const DirectUpload = struct {
        buffer: *Buffer,
        data: []const u8,
        buffer_offset: u64,
        zero_first: bool,

        fn perform(self: *DirectUpload, mapped: []u8) void {
            if (self.zero_first) @memset(mapped, 0);
            const destination: usize = if (self.zero_first) @intCast(self.buffer_offset) else 0;
            @memcpy(mapped[destination..][0..self.data.len], self.data);
            // The buffer is initialized either by the explicit zero above or by
            // the copy, so no later clear can overwrite it (`BufferVk.cpp:682`).
            self.buffer.is_data_initialized = true;
        }
    };

    /// `Device::CopyFromStagingToBuffer` (`DeviceVk.cpp:796`) plus the
    /// buffer-to-buffer replay of `CommandBufferVk.cpp:1172`. The receiver is
    /// the destination, as it is in Dawn: initialize it, transition both sides,
    /// and record one `vkCmdCopyBuffer`.
    ///
    /// This is the primitive `command` replays for a buffer-to-buffer copy and
    /// the one both upload paths use, so they order their barriers the same way.
    pub fn recordCopyBuffer(
        self: *Buffer,
        recording: Recording,
        source: *Buffer,
        source_offset: u64,
        destination_offset: u64,
        byte_count: u64,
    ) Error!void {
        if (byte_count == 0) return error.ZeroSizedCopy;
        if (!source.usage.copy_src) return error.BufferUsageMissingCopySrc;
        if (!self.usage.copy_dst) return error.BufferUsageMissingCopyDst;
        try self.recordCopyBufferNative(recording, source, source_offset, destination_offset, byte_count);
    }

    /// Copies library ranges using native engine permissions, not public usage grants.
    /// The caller validates ranges and initializes the source before this operation.
    pub fn recordCopyBufferInternal(
        self: *Buffer,
        recording: Recording,
        source: *Buffer,
        source_offset: u64,
        destination_offset: u64,
        byte_count: u64,
    ) Error!void {
        if (byte_count == 0) return error.ZeroSizedCopy;
        if (source.internal_usage & (usage_copy_src | internal_copy_src_buffer) == 0) {
            return error.BufferUsageMissingCopySrc;
        }
        if (self.internal_usage & usage_copy_dst == 0) return error.BufferUsageMissingCopyDst;
        try self.recordCopyBufferNative(recording, source, source_offset, destination_offset, byte_count);
    }

    /// Internal initialization uploads can write the native allocation without
    /// granting public COPY_DST permission. Every native VkBuffer has that bit.
    fn recordCopyBufferNative(
        self: *Buffer,
        recording: Recording,
        source: *Buffer,
        source_offset: u64,
        destination_offset: u64,
        byte_count: u64,
    ) Error!void {
        std.debug.assert(byte_count != 0);
        const device_procs = try procs(self.device);
        const cmd_copy_buffer = device_procs.cmd_copy_buffer orelse
            return error.MissingDeviceProc;

        try self.ensureDataInitializedAsDestination(recording, destination_offset, byte_count);
        const source_usage = if (source.internal_usage & usage_copy_src != 0)
            usage_copy_src
        else
            internal_copy_src_buffer;
        try source.transitionUsageNow(recording, source_usage, .none);
        try self.transitionUsageNow(recording, usage_copy_dst, .none);

        const region: vulkan.VkBufferCopy = .{
            .srcOffset = source_offset,
            .dstOffset = destination_offset,
            .size = byte_count,
        };
        cmd_copy_buffer(
            recording.command_buffer,
            source.handle,
            self.handle,
            1,
            &region,
        );
    }
};

/// `UploadReservation` (`DynamicUploader.h:50`): the staging bytes and where
/// they live.
pub const Reservation = struct {
    /// The staging buffer the bytes go into. The caller does not own it.
    buffer: *Buffer,
    /// Host bytes over `[offset, offset + byte_count)` of that buffer.
    mapped: [*]u8,
    /// Byte offset into `buffer`.
    offset: u64,
    byte_count: u64,
    ring_reservation: RingAllocator.Reservation,
};

/// `DynamicUploader` (`DynamicUploader.{h,cpp}`) with one ring buffer instead of
/// a list of them.
///
/// A staging region remains live until the owner observes GPU completion and
/// calls `reclaim`. Failed command recording cancels only the newest reservation.
pub const UploadRing = struct {
    device: Device,
    /// The staging buffer, created on the first reservation
    /// (`DynamicUploader.cpp:110`).
    staging: ?*Buffer,
    offsets: RingAllocator,
    ring_size: u64,

    pub const InitOptions = struct {
        /// `kRingBufferSize` unless a caller needs less.
        ring_size: u64 = upload_ring_size,
    };

    /// `DynamicUploader`'s constructor (`DynamicUploader.cpp:46`). The staging
    /// buffer does not exist yet: Dawn creates it lazily on the first reserve.
    pub fn init(device: Device, options: InitOptions) UploadRing {
        return .{
            .device = device,
            .staging = null,
            .offsets = RingAllocator.init(options.ring_size),
            .ring_size = options.ring_size,
        };
    }

    /// Drops the staging buffer and forgets the accounting, so a caller that
    /// frees the ring before every reservation was released leaks no handle.
    pub fn deinit(self: *UploadRing) Error!void {
        if (self.staging) |staging| {
            try staging.destroy(self.device.allocator);
        }
        self.offsets.deinit(self.device.allocator);
        // The ring is gone and nothing reads the value again, so the receiver is
        // poisoned rather than half reset.
        self.* = undefined;
    }

    pub const ReserveOptions = struct {
        byte_count: u64,
        at_serial: Serial,
    };

    /// Use `device.allocator`, which also frees these reservations at teardown.
    pub fn reserve(
        allocator: std.mem.Allocator,
        self: *UploadRing,
        options: ReserveOptions,
    ) ReserveError!Reservation {
        if (options.byte_count > self.ring_size) return error.UploadRingRequestTooLarge;
        const ring_reservation = RingAllocator.allocate(allocator, &self.offsets, .{
            .byte_count = options.byte_count,
            .at_serial = options.at_serial,
            .alignment_byte_count = upload_reservation_alignment,
        }) catch |err| switch (err) {
            error.RingBufferFull => return error.UploadRingExhausted,
            else => return err,
        };
        errdefer self.offsets.cancelLast(ring_reservation) catch
            @panic("buffer: failed to undo the newest staging reservation");
        const start = ring_reservation.offset_byte_count;
        const staging = try ensureStagingBuffer(allocator, self);
        const span = staging.mappedSpan();
        std.debug.assert(span.len >= start + options.byte_count);
        return .{
            .buffer = staging,
            .mapped = span[start..].ptr,
            .offset = start,
            .byte_count = options.byte_count,
            .ring_reservation = ring_reservation,
        };
    }

    /// The lazily created `Dawn_DynamicUploaderStaging` of `Reserve`
    /// (`DynamicUploader.cpp:110`): a copy-source, map-write buffer mapped at
    /// creation, so its whole range is host memory for the ring to carve up.
    fn ensureStagingBuffer(
        allocator: std.mem.Allocator,
        self: *UploadRing,
    ) ReserveError!*Buffer {
        if (self.staging) |staging| return staging;
        if (self.ring_size > std.math.maxInt(u64) - (mapped_at_creation_size_alignment - 1)) {
            return error.BufferAllocationOverflow;
        }
        const staging = try Buffer.create(allocator, self.device, .{
            .label = "Dawn_DynamicUploaderStaging",
            .usage = .{ .copy_src = true, .map_write = true },
            .size = std.mem.alignForward(
                u64,
                self.ring_size,
                mapped_at_creation_size_alignment,
            ),
            .mapped_at_creation = true,
        });
        self.staging = staging;
        return staging;
    }

    pub fn reclaim(
        allocator: std.mem.Allocator,
        self: *UploadRing,
        completed_serial: Serial,
    ) std.mem.Allocator.Error!void {
        try RingAllocator.deallocate(allocator, &self.offsets, completed_serial);
    }

    pub fn cancelLast(self: *UploadRing, reservation: Reservation) CancelReservationError!void {
        self.offsets.cancelLast(reservation.ring_reservation) catch
            return error.UploadRingReservationNotLast;
    }

    /// The bytes the ring still holds, which is the observable a caller reads
    /// after a submit to know the ring is free again.
    pub fn pendingByteCount(self: *const UploadRing) u64 {
        return self.offsets.used_size_byte_count;
    }
};

comptime {
    // `Rule` is the set a caller matches on, so every member is named. The
    // switch in `ruleName` has no `else`, so a member added without a name
    // there is already a compile error; the loop below is the sweep that
    // asserts it from the module, so the two cannot drift apart.
    var named: usize = 0;
    for (@typeInfo(Rule).error_set.error_names.?) |member_name| {
        named += 1;
        // Reflection hands back a member's name, not a `Rule` value, so
        // `@field` is what turns a swept member into the one `ruleName` takes
        // (`test/buffer.zig:652`-`:655` sweeps the same set the same way).
        if (ruleName(@field(Rule, member_name)).len == 0) {
            @compileError("a buffer rule has no name: " ++ member_name);
        }
    }
    if (named != @typeInfo(Rule).error_set.error_names.?.len) {
        @compileError("the buffer rule sweep missed a member");
    }
    // `State` is the other closed domain a caller matches on, so it is swept
    // the same way.
    const states = @typeInfo(State).@"enum".field_names;
    var named_states: usize = 0;
    for (states) |field_name| {
        named_states += 1;
        if (stateName(@field(State, field_name)).len == 0) {
            @compileError("a buffer state has no name: " ++ field_name);
        }
    }
    if (named_states != states.len) @compileError("the buffer state sweep missed a member");
}
