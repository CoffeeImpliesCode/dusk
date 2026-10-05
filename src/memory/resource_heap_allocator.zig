//! The interface a back end answers to create and destroy memory heaps.
//!
//! **What this file is.** The port of `ResourceHeapAllocator`
//! (`src/dawn/native/ResourceHeapAllocator.h:39-46`): two pure virtuals and a
//! defaulted virtual destructor. Ownership crosses the boundary by value in both
//! directions, and there is no `GetSize` on the interface — a caller learns the
//! size by construction or by asking the returned heap.
//!
//! **A vtable, not a generic.** Upstream's four implementors are two of ours and
//! two that are not: `PooledResourceMemoryAllocator` (M6), the test placeholder
//! (`BuddyMemoryAllocatorTests.cpp:40-46`), `SingleTypeAllocator`
//! (`ResourceMemoryAllocatorVk.cpp:61`, M11) and `d3d12::HeapAllocator`
//! (`HeapAllocatorD3D12.h:45`, not ported). A comptime parameter would make every
//! consumer monomorphic over all four. A two-entry table keeps the seam where
//! `AGENTS.md` §3 puts it, at the boundary, with the concrete type behind an
//! opaque context.
//!
//! **What this file does not claim.** It does not claim a Vulkan heap. The only
//! implementor in this milestone is the pool and the test fake; M11 supplies the
//! one that answers with a real `VkDeviceMemory`.
//!
//! **The size contract.** `AllocateResourceHeap(size)` upstream is
//! `ResultOrError<unique_ptr<ResourceHeapBase>>` and the one place that enforces
//! the request is `SingleTypeAllocator::AllocateResourceHeap`
//! (`ResourceMemoryAllocatorVk.cpp:101-103`), which reports an over-large
//! request as `DAWN_OUT_OF_MEMORY_ERROR`. That folds two different facts into
//! one bit. The port splits them: `OutOfDeviceMemory` and `OutOfHostMemory` are
//! the driver's answers, and `RequestExceedsMaximumHeapSize` is the caller's
//! request exceeding the heap. `docs/30-port-design.md` §2.1 owns the split
//! between the two OOM errors and says it is deliberate.

const std = @import("std");
const Heap = @import("resource_heap.zig").Heap;

/// What a heap allocator can report.
///
/// `AGENTS.md` §2: an API declares its own error set and never leaks `anyerror`.
pub const Error = error{
    /// `vkAllocateMemory` returned `VK_ERROR_OUT_OF_DEVICE_MEMORY`.
    OutOfDeviceMemory,
    /// `vkAllocateMemory` returned `VK_ERROR_OUT_OF_HOST_MEMORY`.
    OutOfHostMemory,
    /// The request exceeds the largest heap the device offers. Upstream reports
    /// this as an out-of-memory condition at
    /// `ResourceMemoryAllocatorVk.cpp:101-103`; the port names it separately
    /// because it is the caller's request and not the device's state.
    RequestExceedsMaximumHeapSize,
};

/// The allocation failure the interface adds to the injected allocator's.
pub const AllocateError = std.mem.Allocator.Error || Error;

/// The two methods `ResourceHeapAllocator.h:43-45` declares.
///
/// `allocateResourceHeap` receives the allocator because the heap it returns may
/// be heap-allocated; a vtable that closed over one would be a hidden allocator
/// and `AGENTS.md` §3 forbids that. `deallocateResourceHeap` receives no
/// allocator because it destroys what it was handed, exactly as upstream takes
/// the `unique_ptr` by value and drops it.
pub const VTable = struct {
    allocateResourceHeap: *const fn (
        allocator: std.mem.Allocator,
        context: *anyopaque,
        size_byte_count: u64,
    ) AllocateError!*Heap,

    deallocateResourceHeap: *const fn (context: *anyopaque, heap: *Heap) void,
};

/// A heap allocator: an opaque context and the table that reads it.
pub const ResourceHeapAllocator = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub fn init(context: *anyopaque, vtable: *const VTable) ResourceHeapAllocator {
        return .{ .context = context, .vtable = vtable };
    }

    /// Ports `ResourceHeapAllocator::AllocateResourceHeap`
    /// (`ResourceHeapAllocator.h:43-44`). The caller owns what it returns and
    /// hands it back to `deallocateResourceHeap` and to nothing else.
    pub fn allocateResourceHeap(
        self: ResourceHeapAllocator,
        allocator: std.mem.Allocator,
        size_byte_count: u64,
    ) AllocateError!*Heap {
        return self.vtable.allocateResourceHeap(
            allocator,
            self.context,
            size_byte_count,
        );
    }

    /// Ports `ResourceHeapAllocator::DeallocateResourceHeap`
    /// (`ResourceHeapAllocator.h:45`). Upstream takes ownership by value; here
    /// the ownership is the pointer, and destroying the heap is the
    /// implementation's job.
    pub fn deallocateResourceHeap(self: ResourceHeapAllocator, heap: *Heap) void {
        self.vtable.deallocateResourceHeap(self.context, heap);
    }
};
