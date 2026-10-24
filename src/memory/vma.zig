//! The `vk_mem_alloc.h` binding: VMA's declaration half, in Zig.
//!
//! **What this file is.** The C declarations `zig translate-c` emits for the
//! Vulkan Memory Allocator, written by hand because the pinned header is
//! header-only and no C++ implementation is linked here.
//!
//! **What this file does not claim.** It does not claim a working VMA. Nothing
//! in it is called. `vk_mem_alloc.h` at v3.4.0 is 13,573 lines; lines 1-3047 are
//! the declaration half and `#ifdef VMA_IMPLEMENTATION` at `:3039` opens the C++
//! half, so a translation of the header yields declarations with no definition
//! anywhere in the closure. The nixpkgs package `vulkan-memory-allocator` is
//! `stdenvNoCC` and installs `include/` and the CMake config, nothing else, so
//! there is no object to bind to. The offset tree stays in Zig.
//!
//! **Layout is `extern`, not hand-computed.** Every struct below is an
//! `extern struct` in the declaration order of the header, so the C layout holds
//! by construction. The header's own changelog warning — "always fully
//! initialize structures with zeros and don't rely on their specific `sizeof`" —
//! is the caller's obligation and every `init` here starts from a zeroed record.
//!
//! **The Vulkan seam is ours.** `VMA_DYNAMIC_VULKAN_FUNCTIONS` defaults to 1
//! (`vk_mem_alloc.h:3099`), so every Vulkan call VMA makes goes through
//! `VmaVulkanFunctions`. dusk resolves its own device procs in
//! `src/vk/dispatch.zig` under `VK_NO_PROTOTYPES`, so this file never declares
//! a `libvulkan` symbol of its own.

const vulkan = @import("vulkan");

/// The header this file tracks. `#define VMA_VERSION (VK_MAKE_VERSION(3, 4,
/// 0))` at `vk_mem_alloc.h:136`, the version the nixpkgs derivation
/// `pkgs/by-name/vu/vulkan-memory-allocator/package.nix` pins.
pub const pinned_version = "3.4.0";

/// The dispatcher handle. `VK_DEFINE_HANDLE(VmaAllocator)` at
/// `vk_mem_alloc.h:903` makes it dispatchable: it points at a struct whose first
/// slot is the loader dispatch table. The port never looks through it, so it
/// stays opaque.
pub const VmaAllocatorT = opaque {};
pub const VmaAllocator = ?*VmaAllocatorT;

/// An allocation inside a block. `VK_DEFINE_NON_DISPATCHABLE_HANDLE` at
/// `vk_mem_alloc.h:895` makes this a pointer to a single object rather than a
/// dispatchable handle, but the C type is still a pointer.
pub const VmaAllocationT = opaque {};
pub const VmaAllocation = ?*VmaAllocationT;

/// A virtual block: a size range VMA sub-allocates from without a device memory
/// block behind it. `vk_mem_alloc.h:10446`.
pub const VmaVirtualBlockT = opaque {};
pub const VmaVirtualBlock = ?*VmaVirtualBlockT;

/// A pool of blocks with one memory type and one usage. `vk_mem_alloc.h:812`.
pub const VmaPoolT = opaque {};
pub const VmaPool = ?*VmaPoolT;

// ----------------------------------------------------------------------------
// Flags
// ----------------------------------------------------------------------------

/// `VkFlags` (`vk_mem_alloc.h:431`). A bitmask, not an enum: the header's own
/// `FlagBits` names stop at `0x7FFFFFFF` and the type stays open, so the port
/// keeps it `u32` and names the bits it reads.
///
/// The bits below are the header's `VMA_*_CREATE_*_BIT` macros.
pub const VmaAllocatorCreateFlags = vulkan.VkFlags;
pub const VmaAllocationCreateFlags = vulkan.VkFlags;
pub const VmaVirtualBlockCreateFlags = vulkan.VkFlags;

pub const vma_allocator_create_externally_synchronized_bit: VmaAllocatorCreateFlags = 0x0000_0001;
pub const vma_allocator_create_khr_dedicated_allocation_bit: VmaAllocatorCreateFlags = 0x0000_0002;
pub const vma_allocator_create_khr_bind_memory2_bit: VmaAllocatorCreateFlags = 0x0000_0004;
pub const vma_allocator_create_ext_memory_budget_bit: VmaAllocatorCreateFlags = 0x0000_0008;
pub const vma_allocator_create_amd_device_coherent_memory_bit: VmaAllocatorCreateFlags = 0x0000_0010;
pub const vma_allocator_create_buffer_device_address_bit: VmaAllocatorCreateFlags = 0x0000_0020;
pub const vma_allocator_create_ext_memory_priority_bit: VmaAllocatorCreateFlags = 0x0000_0040;

/// `VmaMemoryUsage` (`vk_mem_alloc.h:513-587`).
///
/// The `GPU_ONLY`..`CPU_COPY` arm is `\deprecated Obsolete, preserved for
/// backward compatibility` upstream, so the port does not name those five and
/// leaves the numbering explicit.
pub const VmaMemoryUsage = enum(u32) {
    unknown = 0,
    gpu_only = 1,
    cpu_only = 2,
    cpu_to_gpu = 3,
    gpu_to_cpu = 4,
    cpu_copy = 5,
    gpu_lazily_allocated = 6,
    auto = 7,
    auto_prefer_device = 8,
    auto_prefer_host = 9,
    max_enum = 0x7FFF_FFFF,

    /// The `AUTO*` arm only works with the functions that see a
    /// `VkBufferCreateInfo` or `VkImageCreateInfo` (`vk_mem_alloc.h:552-556`),
    /// which rules it out for `vmaAllocateMemory`. The port refuses it rather
    /// than letting VMA pick a memory type the record cannot describe.
    pub fn needsResourceInfo(usage: VmaMemoryUsage) bool {
        return switch (usage) {
            .auto, .auto_prefer_device, .auto_prefer_host => true,
            else => false,
        };
    }
};

pub const vma_allocation_create_dedicated_memory_bit: VmaAllocationCreateFlags = 0x0000_0001;
pub const vma_allocation_create_never_allocate_bit: VmaAllocationCreateFlags = 0x0000_0002;
pub const vma_allocation_create_mapped_bit: VmaAllocationCreateFlags = 0x0000_0004;
pub const vma_allocation_create_user_data_copy_string_bit: VmaAllocationCreateFlags = 0x0000_0020;
pub const vma_allocation_create_upper_address_bit: VmaAllocationCreateFlags = 0x0000_0040;
pub const vma_allocation_create_dont_bind_bit: VmaAllocationCreateFlags = 0x0000_0080;
pub const vma_allocation_create_within_budget_bit: VmaAllocationCreateFlags = 0x0000_0100;
pub const vma_allocation_create_can_alias_bit: VmaAllocationCreateFlags = 0x0000_0200;
pub const vma_allocation_create_host_access_sequential_write_bit: VmaAllocationCreateFlags = 0x0000_0400;
pub const vma_allocation_create_host_access_random_bit: VmaAllocationCreateFlags = 0x0000_0800;
pub const vma_allocation_create_host_access_allow_transfer_instead_bit: VmaAllocationCreateFlags = 0x0000_1000;
pub const vma_allocation_create_strategy_min_memory_bit: VmaAllocationCreateFlags = 0x0001_0000;
pub const vma_allocation_create_strategy_min_time_bit: VmaAllocationCreateFlags = 0x0002_0000;

// ----------------------------------------------------------------------------
// Structures
// ----------------------------------------------------------------------------

/// `VmaDeviceMemoryCallbacks` (`vk_mem_alloc.h:940`). Informative only: VMA
/// still calls `vkAllocateMemory`, and these let a caller log the device
/// allocation the library would otherwise make invisible.
pub const VmaDeviceMemoryCallbacks = extern struct {
    pfnAllocate: ?*const fn (
        allocator: VmaAllocator,
        memory_type_index: u32,
        size_byte_count: vulkan.VkDeviceSize,
        pUserData: ?*anyopaque,
    ) callconv(.c) vulkan.VkDeviceMemory,
    pfnFree: ?*const fn (
        allocator: VmaAllocator,
        memory_type_index: u32,
        size_byte_count: vulkan.VkDeviceSize,
        pUserData: ?*anyopaque,
        pDeviceMemory: vulkan.VkDeviceMemory,
    ) callconv(.c) void,
    pUserData: ?*anyopaque,
};

/// `VmaVulkanFunctions` (`vk_mem_alloc.h:954-1000`).
///
/// The `#if` arms in the header all evaluate true on the pinned Vulkan 1.4
/// headers, because each is `VMA_VULKAN_VERSION >= 1001000` or `1003000`, so
/// all twenty-seven members exist and the declaration order below is the C one.
/// The KHR-suffixed members are the promoted aliases the header itself uses.
pub const VmaVulkanFunctions = extern struct {
    // Required when `VMA_DYNAMIC_VULKAN_FUNCTIONS` is 1, which it is by
    // default (`vk_mem_alloc.h:3099`).
    vkGetInstanceProcAddr: vulkan.PFN_vkGetInstanceProcAddr,
    vkGetDeviceProcAddr: vulkan.PFN_vkGetDeviceProcAddr,
    vkGetPhysicalDeviceProperties: vulkan.PFN_vkGetPhysicalDeviceProperties,
    vkGetPhysicalDeviceMemoryProperties: vulkan.PFN_vkGetPhysicalDeviceMemoryProperties,
    vkAllocateMemory: vulkan.PFN_vkAllocateMemory,
    vkFreeMemory: vulkan.PFN_vkFreeMemory,
    vkMapMemory: vulkan.PFN_vkMapMemory,
    vkUnmapMemory: vulkan.PFN_vkUnmapMemory,
    vkFlushMappedMemoryRanges: vulkan.PFN_vkFlushMappedMemoryRanges,
    vkInvalidateMappedMemoryRanges: vulkan.PFN_vkInvalidateMappedMemoryRanges,
    vkBindBufferMemory: vulkan.PFN_vkBindBufferMemory,
    vkBindImageMemory: vulkan.PFN_vkBindImageMemory,
    vkGetBufferMemoryRequirements: vulkan.PFN_vkGetBufferMemoryRequirements,
    vkGetImageMemoryRequirements: vulkan.PFN_vkGetImageMemoryRequirements,
    vkCreateBuffer: vulkan.PFN_vkCreateBuffer,
    vkDestroyBuffer: vulkan.PFN_vkDestroyBuffer,
    vkCreateImage: vulkan.PFN_vkCreateImage,
    vkDestroyImage: vulkan.PFN_vkDestroyImage,
    vkCmdCopyBuffer: vulkan.PFN_vkCmdCopyBuffer,
    vkGetBufferMemoryRequirements2KHR: vulkan.PFN_vkGetBufferMemoryRequirements2KHR,
    vkGetImageMemoryRequirements2KHR: vulkan.PFN_vkGetImageMemoryRequirements2KHR,
    vkBindBufferMemory2KHR: vulkan.PFN_vkBindBufferMemory2KHR,
    vkBindImageMemory2KHR: vulkan.PFN_vkBindImageMemory2KHR,
    vkGetPhysicalDeviceMemoryProperties2KHR: vulkan.PFN_vkGetPhysicalDeviceMemoryProperties2KHR,
    vkGetDeviceBufferMemoryRequirements: vulkan.PFN_vkGetDeviceBufferMemoryRequirements,
    vkGetDeviceImageMemoryRequirements: vulkan.PFN_vkGetDeviceImageMemoryRequirements,
};

/// `VmaAllocatorCreateInfo` (`vk_mem_alloc.h:1004-1157`).
///
/// Only `physicalDevice`, `device` and `instance` are unconditional
/// requirements. `preferredLargeHeapBlockSize` is where Dawn's
/// `GetHeapBlockSize` value lands: `allocatorHeapBlockSize` is a WebGPU ABI
/// field (`dawn.json:321`), so the knob stays Zig and only its value is
/// forwarded. `pVulkanFunctions` points at dusk's dispatch pointers, never at
/// VMA's own.
pub const VmaAllocatorCreateInfo = extern struct {
    flags: VmaAllocatorCreateFlags,
    physicalDevice: vulkan.VkPhysicalDevice,
    device: vulkan.VkDevice,
    preferredLargeHeapBlockSize: vulkan.VkDeviceSize,
    pAllocationCallbacks: ?*const vulkan.VkAllocationCallbacks,
    pDeviceMemoryCallbacks: ?*const VmaDeviceMemoryCallbacks,
    pHeapSizeLimit: ?[*]const vulkan.VkDeviceSize,
    pVulkanFunctions: ?*const VmaVulkanFunctions,
    instance: vulkan.VkInstance,
    vulkanApiVersion: u32,
    // Inside `#if VMA_EXTERNAL_MEMORY`, which is 1 whenever
    // `VK_KHR_external_memory` is defined (`vk_mem_alloc.h:236-243`), so the
    // member is present on the pinned headers.
    pTypeExternalMemoryHandleTypes: ?[*]const vulkan.VkExternalMemoryHandleTypeFlagsKHR,
};

/// `VmaAllocationCreateInfo` (`vk_mem_alloc.h:1307-1364`).
///
/// No member carries Dawn's `isLazyMemoryType`. VMA takes
/// `requiredFlags`/`preferredFlags` at create time and exposes nothing
/// afterwards on the handle that says "this one was allocated lazily", which is
/// why the lazy flag stays on dusk's own record. `minAlignment` is the last member and is new in
/// 3.4.0; it is absent from the copy Dawn vendors (`DEPS:365-368`), so a port
/// that was translated against Dawn's copy would be one member short.
pub const VmaAllocationCreateInfo = extern struct {
    flags: VmaAllocationCreateFlags,
    usage: VmaMemoryUsage,
    requiredFlags: vulkan.VkMemoryPropertyFlags,
    preferredFlags: vulkan.VkMemoryPropertyFlags,
    memoryTypeBits: u32,
    pool: VmaPool,
    pUserData: ?*anyopaque,
    priority: f32,
    minAlignment: vulkan.VkDeviceSize,
};

/// `VmaAllocationInfo` (`vk_mem_alloc.h:1465-1499`).
///
/// `offset` is relative to `deviceMemory` and `size` is the rounded size, not
/// the request. That is why `ResourceMemoryAllocation.info.requested_size` keeps
/// the pre-rounding value and never reads this one back.
pub const VmaAllocationInfo = extern struct {
    memoryType: u32,
    deviceMemory: vulkan.VkDeviceMemory,
    offset: vulkan.VkDeviceSize,
    size: vulkan.VkDeviceSize,
    pMappedData: ?*anyopaque,
    pUserData: ?*anyopaque,
    pName: ?[*:0]const u8,
};

/// `VmaStatistics` (`vk_mem_alloc.h:1111`). A "block" is a whole
/// `VkDeviceMemory`; an "allocation" is a region sub-allocated from one.
pub const VmaStatistics = extern struct {
    blockCount: u32,
    allocationCount: u32,
    blockBytes: vulkan.VkDeviceSize,
    allocationBytes: vulkan.VkDeviceSize,
};

/// `VmaDetailedStatistics` (`vk_mem_alloc.h:1151`).
pub const VmaDetailedStatistics = extern struct {
    statistics: VmaStatistics,
    unusedRangeCount: u32,
    allocationSizeMin: vulkan.VkDeviceSize,
    allocationSizeMax: vulkan.VkDeviceSize,
    unusedRangeSizeMin: vulkan.VkDeviceSize,
    unusedRangeSizeMax: vulkan.VkDeviceSize,
};

/// `VmaTotalStatistics` (`vk_mem_alloc.h:1173-1260`). A large out-parameter,
/// which is why it does not appear on a runtime path; a test calls it.
pub const VmaTotalStatistics = extern struct {
    memoryType: [vulkan.VK_MAX_MEMORY_TYPES]VmaDetailedStatistics,
    memoryHeap: [vulkan.VK_MAX_MEMORY_HEAPS]VmaDetailedStatistics,
    total: VmaDetailedStatistics,
};

/// `VmaBudget` (`vk_mem_alloc.h:1185`). `usage` comes from
/// `VK_EXT_memory_budget`, so it is an instantaneous driver figure and not the
/// WebGPU-visible byte count `SizeTracker` keeps.
pub const VmaBudget = extern struct {
    statistics: VmaStatistics,
    usage: vulkan.VkDeviceSize,
    budget: vulkan.VkDeviceSize,
};

// ----------------------------------------------------------------------------
// Entry points
// ----------------------------------------------------------------------------

// Declared, not called. Zig emits no reference to an `extern` declaration that
// nothing takes the address of, so a translation unit that only imports this
// file links without a VMA implementation.

pub extern fn vmaCreateAllocator(
    pCreateInfo: *const VmaAllocatorCreateInfo,
    pAllocator: *VmaAllocator,
) callconv(.c) vulkan.VkResult;

pub extern fn vmaDestroyAllocator(allocator: VmaAllocator) callconv(.c) void;

pub extern fn vmaAllocateMemory(
    allocator: VmaAllocator,
    pVkMemoryRequirements: *const vulkan.VkMemoryRequirements,
    pCreateInfo: *const VmaAllocationCreateInfo,
    pAllocation: *VmaAllocation,
    pAllocationInfo: ?*VmaAllocationInfo,
) callconv(.c) vulkan.VkResult;

/// Takes the allocation by value and returns nothing. A null handle is a no-op
/// (`vk_mem_alloc.h:2107-2109`), which is why there is no error to handle.
pub extern fn vmaFreeMemory(
    allocator: VmaAllocator,
    allocation: VmaAllocation,
) callconv(.c) void;

pub extern fn vmaMapMemory(
    allocator: VmaAllocator,
    allocation: VmaAllocation,
    ppData: *?*anyopaque,
) callconv(.c) vulkan.VkResult;

pub extern fn vmaUnmapMemory(
    allocator: VmaAllocator,
    allocation: VmaAllocation,
) callconv(.c) void;

pub extern fn vmaGetAllocationInfo(
    allocator: VmaAllocator,
    allocation: VmaAllocation,
    pAllocationInfo: *VmaAllocationInfo,
) callconv(.c) void;

pub extern fn vmaSetAllocationUserData(
    allocator: VmaAllocator,
    allocation: VmaAllocation,
    pUserData: ?*anyopaque,
) callconv(.c) void;

pub extern fn vmaCalculateStatistics(
    allocator: VmaAllocator,
    pStats: *VmaTotalStatistics,
) callconv(.c) void;

pub extern fn vmaGetHeapBudgets(
    allocator: VmaAllocator,
    pBudgets: [*]VmaBudget,
) callconv(.c) void;

/// The memory-type search `MemoryTypeSelector::FindBestTypeIndex` performs.
pub extern fn vmaFindMemoryTypeIndex(
    pCreateInfo: *const VmaAllocationCreateInfo,
    pAllocationProperties: *const vulkan.VkPhysicalDeviceMemoryProperties,
    pMemoryTypeIndex: *u32,
) callconv(.c) vulkan.VkResult;

/// Fills `pVulkanFunctions` from a `vkGetInstanceProcAddr` pair. dusk does not
/// call it: `src/vk/dispatch.zig` already holds the pointers and the port
/// writes `VmaVulkanFunctions` directly, so a volk-shaped import would be a
/// second way to reach the same table.
pub extern fn vmaImportVulkanFunctions(
    pVulkanFunctions: *VmaVulkanFunctions,
    pGetInstanceProcAddr: vulkan.PFN_vkGetInstanceProcAddr,
) callconv(.c) void;

/// Declared for the same completeness as the rest of the binding. Not called.
pub extern fn vmaImportVulkanFunctionsFromVolk(
    pVulkanFunctions: *VmaVulkanFunctions,
) callconv(.c) void;
