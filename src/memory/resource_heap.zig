//! The heap a resource memory is sub-allocated out of.
//!
//! **What this file is.** The port of `ResourceHeapBase`
//! (`src/dawn/native/ResourceHeap.h:36-40`), which upstream is an empty class
//! with no data and no methods, plus the one concrete subclass the Vulkan tree
//! has. It exists only so `ResourceMemoryAllocation.h:38` can forward-declare
//! one name and `ResourceHeapAllocator.h:43-45` can hand out owning pointers to
//! an abstract thing.
//!
//! **Why a concrete struct and not a vtable.** Upstream is polymorphic with one
//! target per back end: `vulkan::ResourceHeap`
//! (`src/dawn/native/vulkan/ResourceHeapVk.h:37-49`) holds three fields and three
//! getters, and `ToBackend.h:110-113` maps `ResourceHeapBase*` to
//! `BackendTraits::ResourceHeapType`, so the "downcast" is a static one. There is
//! also a D3D12 subclass (`HeapD3D12.h:42`), and this port does not carry D3D12.
//! A struct with the three Vulkan fields is therefore the smaller change, and it
//! is the shape `test/memory.zig` needs: the pool hands a heap back and the test
//! asserts it is the same heap, which a type-erased handle cannot answer.
//!
//! **What this file does not claim.** It does not claim a device. `memory` is a
//! `VkDeviceMemory` handle value, not a call, and every field is settable to
//! `null`, so a test drives the whole layer without one. The memory type index
//! and the size land in M11, when `ResourceHeapVk` is M11's.

const vulkan = @import("vulkan");

/// One device memory allocation that resources are sub-allocated out of.
///
/// Ports `vulkan::ResourceHeap` (`ResourceHeapVk.h:37-49`). The three fields are
/// `mMemory`, `mMemoryType` and `mSize` in that order; the three upstream
/// getters only read them, so the fields carry the value and no getter
/// survives.
pub const Heap = struct {
    /// The `VkDeviceMemory`. `null` is a legal value here and not a defect:
    /// nothing in `memory` calls Vulkan, so a test heap has none.
    memory: vulkan.VkDeviceMemory,

    /// The memory type this heap was allocated from. It never changes for the
    /// life of the heap, which is what makes it usable as a pool key.
    memory_type_index: u32,

    /// The size the heap was allocated with, in bytes. A pool hit returns a heap
    /// whose size is the pool's own, never the caller's request; see
    /// `HeapPool.allocateResourceHeap`.
    size_byte_count: vulkan.VkDeviceSize,
};
