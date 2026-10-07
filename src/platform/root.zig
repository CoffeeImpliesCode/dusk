//! `platform`: the loader, the serial timeline, the worker pool, the
//! colour-space tables and the surface path.
//!
//! **What this file is.** The namespace for milestone M1's
//! `platform/loader.zig`, milestone M4's `platform/serial.zig` and
//! `platform/threads.zig`, and milestone M20's `platform/color_space.zig`,
//! `platform/surface.zig` and `platform/x11_functions.zig`. Later milestones
//! extend it in their own change.

const dispatch = @import("../vk/dispatch.zig");
const loader = @import("loader.zig");
const serial = @import("serial.zig");
const threads = @import("threads.zig");
const vulkan = @import("vulkan");

/// The `common/ColorSpace.h` tables. M20.
pub const color_space = @import("color_space.zig");
/// The nine-way window-system sum type and its rules. M20.
pub const surface = @import("surface.zig");
/// The four libX11 entry points, behind two `dlopen` calls. M20.
pub const x11_functions = @import("x11_functions.zig");

/// `std.DynLib` with the `needs_close` flag and the out-parameter folded into
/// a declared error set.
pub const Loader = loader.Loader;

/// The monotonic GPU serial and its submission-ordered queue.
pub const Serial = serial.Serial;
pub fn SerialQueue(comptime Value: type) type {
    return serial.SerialQueue(Value);
}
pub const Timeline = serial.Timeline;

/// The device mutex, the completion event, the wait-any union, and the worker
/// pool with one monotonic clock.
pub const DeviceMutex = threads.DeviceMutex;
pub const CompletionEvent = threads.CompletionEvent;
pub const WaitAnyResult = threads.WaitAnyResult;
pub const Task = threads.Task;
pub const WorkerPool = threads.WorkerPool;
pub const WaitError = threads.WaitError;
pub const WaitUntilOptions = threads.WaitUntilOptions;
pub const WaitAnyOptions = threads.WaitAnyOptions;
pub const monotonic_clock = threads.monotonic_clock;
pub fn waitUntil(io: std.Io, options: WaitUntilOptions) WaitError!void {
    return threads.waitUntil(io, options);
}
pub fn waitAny(comptime capacity: usize, io: std.Io, options: WaitAnyOptions) WaitAnyResult {
    return threads.waitAny(capacity, io, options);
}

// --- M20: the colour-space tables, one constant at a time ----------------

pub const Vec3 = color_space.Vec3;
pub const Vec4 = color_space.Vec4;
pub const Matrix3 = color_space.Matrix3;
pub const Matrix4x3 = color_space.Matrix4x3;
pub const TransferFunction = color_space.TransferFunction;

pub const ycbcr_range_full = color_space.ycbcr_range_full;
pub const ycbcr_range_narrow = color_space.ycbcr_range_narrow;
pub const ycbcr_range_narrow_y_factor = color_space.ycbcr_range_narrow_y_factor;
pub const ycbcr_range_narrow_chroma_factor = color_space.ycbcr_range_narrow_chroma_factor;

pub const ycbcr_to_rgb_rec_601 = color_space.ycbcr_to_rgb_rec_601;
pub const ycbcr_to_rgb_rec_709 = color_space.ycbcr_to_rgb_rec_709;
pub const ycbcr_to_rgb_rec_2020 = color_space.ycbcr_to_rgb_rec_2020;

pub const rgb_to_xyz_rec_601 = color_space.rgb_to_xyz_rec_601;
pub const rgb_to_xyz_rec_709 = color_space.rgb_to_xyz_rec_709;
pub const rgb_to_xyz_srgb = color_space.rgb_to_xyz_srgb;
pub const rgb_to_xyz_rec_2020 = color_space.rgb_to_xyz_rec_2020;
pub const rgb_to_xyz_display_p3 = color_space.rgb_to_xyz_display_p3;
pub const xyz_to_rgb_rec_601 = color_space.xyz_to_rgb_rec_601;
pub const xyz_to_rgb_rec_709 = color_space.xyz_to_rgb_rec_709;
pub const xyz_to_rgb_srgb = color_space.xyz_to_rgb_srgb;
pub const xyz_to_rgb_rec_2020 = color_space.xyz_to_rgb_rec_2020;
pub const xyz_to_rgb_display_p3 = color_space.xyz_to_rgb_display_p3;

pub const eotf_identity = color_space.eotf_identity;
pub const eotf_srgb = color_space.eotf_srgb;
pub const eotf_inverse_srgb = color_space.eotf_inverse_srgb;
pub const eotf_bt_1886 = color_space.eotf_bt_1886;
pub const eotf_display_p3 = color_space.eotf_display_p3;
pub const eotf_inverse_display_p3 = color_space.eotf_inverse_display_p3;
pub const eotf_smpte_170m = color_space.eotf_smpte_170m;

pub const default_hdr_reference_white_luminance =
    color_space.default_hdr_reference_white_luminance;
pub const pq_luminance_of_1 = color_space.pq_luminance_of_1;
pub const hlg_luminance_of_1 = color_space.hlg_luminance_of_1;

// --- M20: the surface path ------------------------------------------------

pub const Surface = surface.Surface;
pub const SurfaceError = surface.SurfaceError;
pub const SurfaceRequest = surface.Request;
pub const Source = surface.Source;
pub const SourceType = surface.SourceType;
pub const WaylandSource = surface.WaylandSource;
pub const WindowsHwndSource = surface.WindowsHwndSource;
pub const XlibSource = surface.XlibSource;
pub const X11Functions = x11_functions.X11Functions;
pub const X11Error = x11_functions.X11Error;

pub fn surfaceMessage(err: SurfaceError) []const u8 {
    return surface.message(err);
}
pub fn validateSurfaceDescriptor(request: SurfaceRequest) SurfaceError!void {
    return surface.validateSurfaceDescriptor(request);
}

/// The Vulkan surface handle the out-slot of `createSurface` and
/// `createVulkanSurface` is a pointer to. Re-exported so an acceptance shard
/// can own the slot without importing the generated bindings.
pub const VkSurfaceHandle = vulkan.VkSurfaceKHR;

/// `VK_NULL_HANDLE` (`vulkan_core.h:40-49`). The value a surface request that
/// created nothing leaves behind.
///
/// The generated bindings spell that macro `?*anyopaque`
/// (`src/vulkan.zig:20767`) while a `VkSurfaceKHR` is
/// `?*struct_VkSurfaceKHR_T` (`src/vulkan.zig:8311`). No coercion joins a
/// child pointer to its parent, so this declaration names the handle type and
/// `@ptrCast` casts into it.
pub const null_surface_handle: VkSurfaceHandle =
    @ptrCast(vulkan.VK_NULL_HANDLE);
pub fn createVulkanSurface(
    subject: *const Surface,
    x11: ?*const X11Functions,
    out_vk_surface: *vulkan.VkSurfaceKHR,
) SurfaceError!void {
    return surface.createVulkanSurface(subject, x11, out_vk_surface);
}
pub fn createSurface(
    request: SurfaceRequest,
    x11: ?*const X11Functions,
    out_vk_surface: *vulkan.VkSurfaceKHR,
) SurfaceError!Surface {
    return surface.createSurface(request, x11, out_vk_surface);
}

// --- M21: the external-memory and external-synchronisation services -------

const external_memory = @import("external_memory.zig");
const external_semaphore = @import("external_semaphore.zig");

/// The generated Vulkan bindings. The M21 acceptance shard builds two
/// `VkDevice`s and the image, buffer and semaphore handles between them, so
/// it needs the handle types and the enum values the services take.
pub const vulkan_bindings = vulkan;

/// OpaqueFD external memory. Importing an image's memory into a second
/// `VkDevice` through a file descriptor.
pub const Memory = external_memory.Service;
pub const MemoryDeviceOptions = external_memory.DeviceOptions;
pub const MemoryImportParams = external_memory.MemoryImportParams;
pub const MemoryDescriptor = external_memory.Descriptor;
pub const MemoryFormatQuery = external_memory.FormatQuery;
pub const MemoryError = external_memory.Error;
pub const ExternalMemoryHandle = external_memory.ExternalMemoryHandle;
pub const NeedsDedicatedAllocation = external_memory.NeedsDedicatedAllocation;
pub const memory_queue_family_index = external_memory.queue_family_index;
pub fn checkMemorySupport(ext: dispatch.EnabledDeviceExts) bool {
    return external_memory.checkSupport(ext);
}
pub fn requiresDedicatedAllocation(
    device: vulkan.VkDevice,
    device_procs: *const dispatch.DeviceProcs,
    need: NeedsDedicatedAllocation,
    image: vulkan.VkImage,
) MemoryError!bool {
    return external_memory.requiresDedicatedAllocation(device, device_procs, need, image);
}

/// External synchronisation by file descriptor, including the `-1` sentinel
/// the specification defines as already signalled.
pub const Semaphore = external_semaphore.Service;
pub const SemaphoreInitOptions = external_semaphore.InitOptions;
pub const SemaphoreSupportOptions = external_semaphore.SupportOptions;
pub const SemaphoreError = external_semaphore.Error;
pub const SemaphoreHandleType = external_semaphore.HandleType;
pub const ExternalSemaphoreHandle = external_semaphore.ExternalSemaphoreHandle;
pub const semaphore_fd_already_signaled_fd =
    external_semaphore.semaphore_fd_already_signaled_fd;
pub const default_semaphore_handle_type = external_semaphore.default_handle_type;
pub fn checkSemaphoreSupport(options: SemaphoreSupportOptions) bool {
    return external_semaphore.checkSupport(options);
}
pub fn duplicateSemaphoreHandle(
    handle: ExternalSemaphoreHandle,
) SemaphoreError!ExternalSemaphoreHandle {
    return external_semaphore.duplicateHandle(handle);
}
pub fn closeSemaphoreHandle(io: std.Io, handle: ExternalSemaphoreHandle) void {
    external_semaphore.closeHandle(io, handle);
}
pub fn fileFromSemaphoreDescriptor(handle: ExternalSemaphoreHandle) std.Io.File {
    return external_semaphore.fileFromDescriptor(handle);
}

const std = @import("std");
