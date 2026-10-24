//! The record every resource memory allocation is described by.
//!
//! **What this file is.** The port of `ResourceMemoryAllocation`
//! (`src/dawn/native/ResourceMemoryAllocation.h:40-99` and
//! `src/dawn/native/ResourceMemoryAllocation.cpp:34-64`). It is a four-field
//! value with a defaulted copy constructor, so it is a plain Zig struct with no
//! vtable and no destructor: `ResourceMemoryAllocatorVk.cpp:296` copies one by
//! value into a serial queue and `:345` reads it back by reference.
//!
//! **What this file does not claim.** It does not own the heap.
//! `mResourceHeap` upstream is `raw_ptr<ResourceHeapBase, DanglingUntriaged>`
//! (`ResourceMemoryAllocation.h:96-97`) — a bare, non-owning pointer, with an
//! upstream `TODO(crbug.com/485825675)` next to it saying the pointer dangles
//! and the port does not yet know why. Heap ownership lives in the allocator's
//! refcount table (`BuddyMemoryAllocator.h:79-84`). The one exception is a
//! direct allocation, where `ResourceMemoryAllocatorVk.cpp:262` calls
//! `resourceHeap.release()` and hands the heap to the record's owner by hand.
//! Here that is `?*Heap`, taken out of the owner and never freed by the record.
//!
//! **Why the two offsets do not share a name.** `mBlockOffset` is
//! allocator-global and `mOffset` is heap-local; `BuddyMemoryAllocator.cpp:104`
//! computes the second from the first as `blockOffset % mMemoryBlockSize`.
//!
//! **Why the accessors return errors.** `GetResourceHeap` (`.cpp:43`) and
//! `GetOffset` (`.cpp:48`) each assert `mMethod != kInvalid`, and
//! `DAWN_ASSERT` expands to nothing in a release build
//! (`src/utils/assert.h:96-99`). `GetInfo` (`.cpp:52-54`) and `GetMappedSpan`
//! (`.cpp:56-58`) carry no guard, because the deallocate switch reads the method
//! through them first (`ResourceMemoryAllocatorVk.cpp:266`). The port keeps that
//! split exactly: two checked accessors and two infallible ones.

const std = @import("std");
const Heap = @import("resource_heap.zig").Heap;

/// How the memory behind an allocation was obtained.
///
/// Ports `AllocationMethod` (`ResourceMemoryAllocation.h:42-54`), all four
/// enumerators under their port names.
///
/// The member order is not upstream's. Upstream declares `kDirect` first
/// (`ResourceMemoryAllocation.h:44`), which leaves `kInvalid` at ordinal 3 and
/// so makes a zero-initialised `AllocationInfo` read as `kDirect`. The port puts
/// `.invalid` first, because it is the value a default-constructed record has
/// to carry and `std.mem.zeroes` has to agree with it: the `comptime` block at
/// the end of `ResourceMemoryAllocation` checks exactly that. Moving the member
/// costs nothing, because nothing outside this file names an `AllocationMethod`
/// and no code takes its ordinal.
pub const AllocationMethod = enum {
    /// Not allocated, or already freed. The default, the zero value, and the
    /// value `BuddyMemoryAllocator.cpp:61`-`:84` returns on every failure path.
    /// The caller tests for it at `ResourceMemoryAllocatorVk.cpp:230`.
    invalid,

    /// A whole heap, not sub-divided. Upstream produces one at
    /// `ResourceMemoryAllocatorVk.cpp:259`.
    direct,

    /// A region inside a shared heap. Upstream produces one at
    /// `BuddyMemoryAllocator.cpp:100`.
    sub_allocated,

    /// Memory Dawn did not allocate. One back end produces it and that is D3D12
    /// (`BufferD3D12.cpp:183`, `TextureD3D12.cpp:231`); nothing under
    /// `src/dawn/native/vulkan/` produces one, and
    /// `ResourceMemoryAllocatorVk.cpp:267-310` switches the other three tags and
    /// falls through to `DAWN_UNREACHABLE()`. The D3D12 resource allocator builds
    /// direct records, not these (`ResourceAllocatorManagerD3D12.cpp:598`). The
    /// external-image path (`TextureVk.cpp:1969`) binds memory directly and never
    /// holds a record.
    ///
    /// The port keeps the tag for parity with the record's meaning and makes the
    /// deallocate switch exhaustive over all four rather than three, so adding a
    /// fourth method is a compile error until it is handled.
    external,
};

/// The metadata half of the record.
///
/// Ports `AllocationInfo` (`ResourceMemoryAllocation.h:57-71`). The field
/// order is `u64, enum, u64, bool` upstream and is kept: nothing reads it by
/// layout and upstream declares no `static_assert` on its size.
pub const AllocationInfo = struct {
    /// Allocator-global offset into the sub-allocation system. Only the buddy
    /// memory allocator reads it, to find the heap (`BuddyMemoryAllocator.cpp:115`)
    /// and to free the block (`:125`).
    block_offset_byte_count: u64 = 0,

    /// The state tag. See `AllocationMethod`.
    method: AllocationMethod = .invalid,

    /// The pre-padding, pre-rounding request, captured at
    /// `BuddyMemoryAllocator.cpp:72` before `NextPowerOfTwo` at `:74`. This is
    /// what WebGPU validates a size against, so it is not the rounded size and
    /// not `VmaAllocationInfo::size`.
    requested_size_byte_count: u64 = 0,

    /// Whether the memory carries `VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT`
    /// (`ResourceMemoryAllocation.h:70`).
    ///
    /// Written at `BuddyMemoryAllocator.cpp:101` and
    /// `ResourceMemoryAllocatorVk.cpp:261`; read at `:232`, `:256`, `:280` and
    /// `:299`. It selects which of a *pair* of size trackers moves — a
    /// non-lazy allocation still increments the lazy tracker, by zero — so it is
    /// a routing key and not a note. VMA takes `requiredFlags` at create time
    /// and exposes nothing afterwards that says "allocated lazily", which is why
    /// the bit stays here.
    is_lazy_allocated: bool = false,
};

/// One resource memory allocation.
///
/// Ports `ResourceMemoryAllocation` (`ResourceMemoryAllocation.h:74-99`).
/// Defaulted field values are the whole of `ResourceMemoryAllocation.cpp:34`,
/// and `method = .invalid` is not a convenience: it is the failure value
/// `BuddyMemoryAllocator.cpp:61`-`:84` hands back.
pub const ResourceMemoryAllocation = struct {
    /// The metadata, ports `mInfo`.
    info: AllocationInfo = .{},

    /// The heap-local offset in bytes, ports `mOffset`. `vkBindBufferMemory`
    /// and `vkBindImageMemory` read this one (`BufferVk.cpp:311`,
    /// `TextureVk.cpp:1552`).
    offset_byte_count: u64 = 0,

    /// The non-owning heap, ports `mResourceHeap`. Null when the method is
    /// `.invalid`; `invalidate` clears it.
    resource_heap: ?*Heap = null,

    /// The host-visible mapping, ports `mMappedSpan`. `RawSpan<std::byte>`
    /// (`src/utils/span.h:105`) is pointer plus length, and the upstream getter
    /// at `ResourceMemoryAllocation.h:88` hands out a mutable span, so this is
    /// `[]u8` and not `[]const u8`. Empty unless the allocation kind is
    /// mappable; emptiness is exactly the is-persistently-mapped predicate
    /// `BufferVk.cpp:567` reads.
    mapped_span: []u8 = &.{},

    /// The error the two guarded accessors report. Upstream returns a null heap
    /// and a stale offset with no diagnostic in a release build.
    pub const Error = error{
        /// The record has been invalidated, or was never allocated. Upstream
        /// asserts `mMethod != kInvalid` at `ResourceMemoryAllocation.cpp:43`
        /// and `:48`.
        AllocationIsInvalid,
    };

    pub const Invalid = Error;

    /// Ports the four-argument constructor (`ResourceMemoryAllocation.cpp:36-40`).
    pub fn init(
        info: AllocationInfo,
        offset_byte_count: u64,
        resource_heap: ?*Heap,
        mapped_span: []u8,
    ) ResourceMemoryAllocation {
        return .{
            .info = info,
            .offset_byte_count = offset_byte_count,
            .resource_heap = resource_heap,
            .mapped_span = mapped_span,
        };
    }

    /// Ports `GetResourceHeap` (`ResourceMemoryAllocation.cpp:42-45`).
    pub fn getResourceHeap(self: ResourceMemoryAllocation) Error!*Heap {
        if (self.info.method == .invalid) return error.AllocationIsInvalid;
        return self.resource_heap orelse return error.AllocationIsInvalid;
    }

    /// Ports `GetOffset` (`ResourceMemoryAllocation.cpp:47-50`).
    pub fn getOffset(self: ResourceMemoryAllocation) Error!u64 {
        if (self.info.method == .invalid) return error.AllocationIsInvalid;
        return self.offset_byte_count;
    }

    /// Ports `GetInfo` (`ResourceMemoryAllocation.cpp:52-54`). Infallible,
    /// because the deallocate switch reads the method through it before it
    /// reads anything guarded.
    pub fn getInfo(self: ResourceMemoryAllocation) AllocationInfo {
        return self.info;
    }

    /// Ports `GetMappedSpan` (`ResourceMemoryAllocation.cpp:56-58`).
    /// Infallible for the same reason.
    pub fn getMappedSpan(self: ResourceMemoryAllocation) []u8 {
        return self.mapped_span;
    }

    /// Ports `Invalidate` (`ResourceMemoryAllocation.cpp:60-64`), which zeroes
    /// the mapped span, the heap pointer and the info.
    ///
    /// `virtual` is dropped: the tree has exactly one override,
    /// `ResourceHeapAllocation::Invalidate`
    /// (`ResourceHeapAllocationD3D12.cpp:47-50`), and the Vulkan path stores a
    /// plain record (`ResourceMemoryAllocatorVk.h:59`). With one back end there
    /// is no second implementation.
    ///
    /// Upstream calls this twice on the same record —
    /// `ResourceMemoryAllocatorVk.cpp:283` and then unconditionally at `:312` —
    /// and a second `Deallocate` after it takes the `.invalid` arm and does
    /// nothing (`:270-271`). The port asserts the idempotence rather than
    /// trusting it, because that double call is the reason it is written to be.
    pub fn invalidate(self: *ResourceMemoryAllocation) void {
        self.mapped_span = &.{};
        self.resource_heap = null;
        self.info = .{};
    }

    /// True when a second `Deallocate` would find nothing to do. Ports the
    /// `kInvalid` arm of `ResourceMemoryAllocatorVk.cpp:270-271`, which exists
    /// for the double-deallocate case the comment at `:310-311` names.
    pub fn isInvalid(self: ResourceMemoryAllocation) bool {
        return self.info.method == .invalid;
    }

    comptime {
        // The default is the failure value, and the record is copied by value
        // into a serial queue upstream (`ResourceMemoryAllocatorVk.cpp:296`), so
        // a zeroed struct has to read as "nothing", never as "a zero-size
        // allocation at offset 0".
        const empty: ResourceMemoryAllocation = .{};
        if (empty.info.method != .invalid) @compileError("the default method must be .invalid");
        if (empty.resource_heap != null) @compileError("the default record holds no heap");
        if (empty.mapped_span.len != 0) @compileError("the default record maps nothing");

        // `std.mem.zeroes` and a `= {}` literal must agree, because the pool and
        // the record both rely on being able to build one without a constructor.
        const zeroed: ResourceMemoryAllocation = std.mem.zeroes(ResourceMemoryAllocation);
        if (zeroed.info.method != empty.info.method) @compileError("zeroed and defaulted disagree");
        if (zeroed.offset_byte_count != empty.offset_byte_count) {
            @compileError("zeroed and defaulted disagree");
        }
    }
};
