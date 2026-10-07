//! The M21 acceptance shard: shared memory and external synchronisation.
//!
//! **What this shard asserts.** Three things, one test each.
//!
//! 1. A `VkImage`'s memory is exported as an OpaqueFD on the first device, a
//!    second `VkDevice` is opened on the same physical device, the descriptor
//!    is imported into it through `platform.Memory.importMemory`, the image is sampled
//!    back out through the second device, and the value the second device
//!    reads is the value the first device wrote.
//!    A second descriptor out of that same allocation is imported into the
//!    first device as the control that tells the two imports apart.
//! 2. The descriptor that export produced is a real, readable file descriptor
//!    and not a number that only cleared the negative check.
//! 3. Supported semaphore handle types complete a native fd round trip or
//!    SYNC_FD `fd = -1` wait. Unsupported types reject legal requests with
//!    `UnsupportedHandleType`, before creating a resource.
//!
//! **Why the shard opens the loader itself.** Every symbol below is reached
//! through the published module, so the shard needs no import but `dusk`:
//! `dusk.vk.dispatch` is the dispatch table and `platform.vulkan_bindings` the
//! generated bindings, and `platform.Loader` is the `dlopen` seam. It creates
//! its two `VkDevice`s rather than asking
//! `vulkan_device.Device.create` for them, because the only device extension
//! that call names is the render path's, at one slot
//! (`src/engine/vulkan_device.zig:953`-`:970`), and `loadDeviceProcs` leaves
//! every extension-gated block null for an extension the caller did not enable
//! (`src/vk/dispatch.zig:1068`-`:1069`). Both services here need
//! `vkGetMemoryFdKHR` and `vkImportSemaphoreFdKHR`, so the shard names the two
//! extensions itself. The instance, the physical device and the two devices
//! are test scaffolding rather than a claimed port: `DeviceVk.cpp` is M9's
//! file, and this shard deliberately enables more than M9 does.
//!
//! **What this shard does not claim.** It does not claim the dma-buf service
//! or the Android `AHardwareBuffer` service; `docs/40-plan.md` §M21 records
//! why both are skipped, and `src/platform/external_memory.zig` says the same.
//! It does not claim a disjoint image, because the fd family is never
//! disjoint. It does not claim that a duplicated descriptor is independent of
//! the original, which `dup(2)` does not promise.
//!
//! Memory imports must succeed on both logical devices. The descriptor carries
//! the original allocation's size and memory type index; both devices use one
//! physical device and driver. `vkGetMemoryFdPropertiesKHR` forbids OPAQUE_FD,
//! so this shard never uses it to choose an import memory type.
//!
//! Semaphore support is handle-type-specific. A supported OPAQUE_FD service
//! exports and imports a real semaphore, signals it on the first device, and
//! waits on the second. A supported SYNC_FD service imports `-1` temporarily
//! into a binary semaphore and completes a native wait. Unsupported services
//! reject a legal request; they do not claim a successful native import.
//! Negative opaque handles and sync handles below `-1` are always invalid.
//!
//! Zero physical devices, unavailable required external-memory support, failed
//! imports, and submission timeouts fail the shard. None become skipped tests.

const std = @import("std");

const dusk = @import("dusk");

const platform = dusk.platform;
const dispatch = dusk.vk.dispatch;
const vulkan = platform.vulkan_bindings;

/// The OpaqueFD memory service, reached the way a consumer reaches it.
const MemoryService = platform.Memory;
/// The fd external-semaphore service.
const SemaphoreService = platform.Semaphore;

/// The library the loader opens. The system loader resolves the ICD, so one
/// name covers the hardware driver and a software fallback alike.
const loader_path = "libvulkan.so.1";

/// OPAQUE_FD memory is required; semaphore fds are enabled when advertised.
const device_extension_names = [_][:0]const u8{
    "VK_KHR_external_memory_fd",
    "VK_KHR_external_semaphore_fd",
};

/// The fence-wait bound. `queue.fence_wait_timeout_ns`
/// (`src/engine/queue.zig:40`) is the same number for the same reason: a wait
/// that never retires has to fail visibly instead of hanging the gate.
const fence_wait_timeout_ns: u64 = 5_000 * std.time.ns_per_ms;

/// The queue family the two devices are created with. Dawn's `kUniversalFlags`
/// (`DeviceVk.cpp:740`) is graphics plus compute; the shard adds transfer,
/// because a copy is what carries the value between the devices.
const universal_queue_flags: vulkan.VkQueueFlags =
    vulkan.VK_QUEUE_GRAPHICS_BIT |
    vulkan.VK_QUEUE_COMPUTE_BIT |
    vulkan.VK_QUEUE_TRANSFER_BIT;

/// The sentinel `vkBindImageMemory` and `vkQueueSubmit` read as "the same
/// family". The pinned generated bindings carry no name for the `#define`
/// `VK_QUEUE_FAMILY_IGNORED`, so the shard names it once.
const queue_family_ignored: u32 = 0xFFFF_FFFF;

/// The value the first device writes and the second device must read back.
/// A pattern rather than a small integer, so a driver that left the image
/// undefined or that copied the staging buffer's unwritten tail cannot pass.
const written_value: u32 = 0x5A17_3C4B;

/// The image the two devices share. One row of `R32_UINT` texels is a `u32`,
/// so the sampled value is one number and each copy is one region.
const shared_format: vulkan.VkFormat = vulkan.VK_FORMAT_R32_UINT;
const shared_extent: vulkan.VkExtent3D = .{ .width = 4, .height = 1, .depth = 1 };
const shared_usage: vulkan.VkImageUsageFlags =
    vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
    vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT;

/// The bytes one copy moves: the four `R32_UINT` texels of `shared_extent`.
const shared_byte_count: vulkan.VkDeviceSize = shared_extent.width * @sizeOf(u32);

/// Everything this shard can fail on. `dispatch.Error` is the whole driver-code
/// set and both service error sets extend it, so this union is what the
/// loader, a Vulkan call or a service can report. The members below are the
/// refusals this shard names instead of letting a driver answer with a code.
const TestError = std.mem.Allocator.Error ||
    std.Io.File.StatError ||
    platform.Loader.OpenError ||
    dispatch.LoadError ||
    dispatch.Error ||
    platform.MemoryError ||
    platform.SemaphoreError ||
    // No separate duplicate set: `external_semaphore.Error` folds
    // `DuplicateFailed` in on purpose (`external_semaphore.zig:105`-`:115`),
    // because `importSemaphore` is what calls `duplicateHandle`, so a member
    // only `duplicateSemaphoreHandle` could return would be a member no
    // caller of the service could ever receive. `SemaphoreError` above is
    // therefore the whole set `platform.duplicateSemaphoreHandle` refuses.
    error{
        /// The instance reported no physical device at all.
        NoPhysicalDevice,
        /// Every physical device reported is below Vulkan 1.1, which is the
        /// floor `src/engine/vulkan_device.zig:39` sets.
        NoPhysicalDeviceAtFloor,
        /// A physical device at the floor lacks external-memory fd support.
        RequiredDeviceExtensionMissing,
        /// No family carries `universal_queue_flags`.
        NoUniversalQueueFamily,
        /// No memory type in the table satisfies the request.
        NoMemoryType,
        /// A create call succeeded and returned a null handle.
        HandleCreationReturnedNull,
        /// `vkWaitForFences` returned `VK_TIMEOUT` with the bound reached.
        FenceWaitTimedOut,
        /// `fcntl(F_GETFL)` refused the exported descriptor.
        DescriptorFlagsUnreadable,
    };

/// The first teardown failure a test body saw, if any.
///
/// Zig 0.16 has no `try` in a `defer` and no `return` in one either, so a
/// teardown that can fail has nowhere to put its error but a recorder. Each
/// test below owns one and reports it as its last statement. The first error
/// is the answer: a later teardown cannot be cleaner than an earlier one, and
/// the first is the one that says which proc was missing.
const TeardownErrors = struct {
    first: ?TestError = null,

    fn record(self: *TeardownErrors, err: TestError) void {
        if (self.first == null) self.first = err;
    }

    /// The body's last statement. A body with no deferred teardown still calls
    /// this, so every test reads the same way.
    fn report(self: *const TeardownErrors) TestError!void {
        if (self.first) |err| return err;
    }
};

/// The teardown entry points, one function each, so a `defer` has something it
/// can call that cannot fail. `AGENTS.md` §3.1 makes a null dispatch field a
/// typed error, and the typed error goes into the recorder rather than into a
/// forced unwrap.
fn destroyImage(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    image: vulkan.VkImage,
    teardowns: *TeardownErrors,
) void {
    const destroy = procs.destroy_image orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    destroy(handle, image, null);
}

fn freeMemory(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    memory: vulkan.VkDeviceMemory,
    teardowns: *TeardownErrors,
) void {
    const free = procs.free_memory orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    free(handle, memory, null);
}

fn destroySemaphore(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    semaphore: vulkan.VkSemaphore,
    teardowns: *TeardownErrors,
) void {
    const destroy = procs.destroy_semaphore orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    destroy(handle, semaphore, null);
}

fn destroyFence(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    fence: vulkan.VkFence,
    teardowns: *TeardownErrors,
) void {
    const destroy = procs.destroy_fence orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    destroy(handle, fence, null);
}

/// `Fixture.destroyDevice` is the method that frees the device tier as well,
/// so this one carries the handle unit to keep the two names apart.
fn destroyDeviceHandle(
    procs: *const dispatch.InstanceProcs,
    handle: vulkan.VkDevice,
    teardowns: *TeardownErrors,
) void {
    const destroy = procs.destroy_device orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    destroy(handle, null);
}

fn destroyInstance(
    global: *const dispatch.GlobalProcs,
    handle: vulkan.VkInstance,
    teardowns: *TeardownErrors,
) void {
    const destroy = global.destroy_instance orelse {
        teardowns.record(error.MissingGlobalProc);
        return;
    };
    destroy(handle, null);
}

fn destroyBuffer(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    buffer: vulkan.VkBuffer,
    teardowns: *TeardownErrors,
) void {
    const destroy = procs.destroy_buffer orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    destroy(handle, buffer, null);
}

fn freeCommandBuffers(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    pool: vulkan.VkCommandPool,
    command_buffer: *const vulkan.VkCommandBuffer,
    teardowns: *TeardownErrors,
) void {
    const free = procs.free_command_buffers orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    free(handle, pool, 1, command_buffer);
}

fn destroyCommandPool(
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    pool: vulkan.VkCommandPool,
    teardowns: *TeardownErrors,
) void {
    const destroy = procs.destroy_command_pool orelse {
        teardowns.record(error.MissingDeviceProc);
        return;
    };
    destroy(handle, pool, null);
}

/// One `VkDevice`, its device tier and its one queue. A value rather than a
/// heap object: the only allocation is the dispatch tier, which `deinit`
/// destroys.
const Device = struct {
    handle: vulkan.VkDevice,
    procs: *dispatch.DeviceProcs,
    queue: vulkan.VkQueue,
    /// The one family the device was created with, which every command pool
    /// it owns names.
    queue_family_index: u32,

    enabled_extensions: dispatch.EnabledDeviceExts,
};

/// The loader, the instance, one physical device and the two devices the
/// acceptance names.
const Fixture = struct {
    lib: platform.Loader,
    global: *dispatch.GlobalProcs,
    instance_procs: *dispatch.InstanceProcs,
    instance: vulkan.VkInstance,
    physical_device: vulkan.VkPhysicalDevice,
    memory_properties: vulkan.VkPhysicalDeviceMemoryProperties,
    queue_family_index: u32,
    enabled_extensions: dispatch.EnabledDeviceExts,
    first: Device,
    second: Device,

    fn init(gpa: std.mem.Allocator, teardowns: *TeardownErrors) TestError!Fixture {
        // SAFETY: every field is assigned below before `selectPhysicalDevice`
        // reads any of them, and `init` returns only after that call.
        var fixture: Fixture = undefined;

        // SAFETY: `Loader.open` fills `lib` from its second statement, so the
        // placeholder is dead before anything reads it.
        fixture.lib = .{ .lib = undefined, .needs_close = false };
        try fixture.lib.open(gpa, .{ .path = loader_path });
        errdefer fixture.lib.deinit();

        fixture.global = try dispatch.loadGlobalProcs(gpa, &fixture.lib.lib);
        errdefer gpa.destroy(fixture.global);
        // `create_instance` and `get_instance_proc_addr` are the two global
        // fields `loadGlobalProcs` fills. `destroy_instance` is not one of them
        // (`src/vk/dispatch.zig:463`-`:465` puts it in `loadInstanceProcs`), so
        // the undo below reads it where the loader has written it.
        const create_instance = fixture.global.create_instance orelse
            return error.MissingGlobalProc;
        const get_instance_proc_addr = fixture.global.get_instance_proc_addr orelse
            return error.MissingGlobalProc;

        // `VulkanInstance::CreateVkInstance` (`BackendVk.cpp:486` and `:493`)
        // asks for the same floor and no layer, and the shard asks for no
        // extension either: both services are device extensions, and every
        // entry point they use is core in Vulkan 1.1.
        var application_info: vulkan.VkApplicationInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_APPLICATION_INFO),
            .pNext = null,
            .pApplicationName = "dusk test-shared-memory",
            .applicationVersion = @intCast(1),
            .pEngineName = "dusk",
            .engineVersion = @intCast(1),
            .apiVersion = vulkan.VK_API_VERSION_1_1,
        };
        var instance_info: vulkan.VkInstanceCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO),
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &application_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };
        var instance: vulkan.VkInstance = null;
        try dispatch.checkVkSuccess(create_instance(&instance_info, null, &instance));
        if (instance == null) return error.HandleCreationReturnedNull;
        fixture.instance = instance;
        errdefer destroyInstance(fixture.global, instance, teardowns);

        // The `errdefer` above is the whole undo: it fires after this call, so
        // it reads `destroy_instance` once `loadInstanceProcs` has filled it. It
        // hands a failure to the recorder rather than dropping it, because a
        // `defer` body cannot return and `AGENTS.md` §2 forbids going quiet.
        fixture.instance_procs = try dispatch.loadInstanceProcs(gpa, .{
            .get_instance_proc_addr = get_instance_proc_addr,
            .instance = instance,
            .global = fixture.global,
            .enabled_extensions = .{},
        });
        errdefer gpa.destroy(fixture.instance_procs);

        try fixture.selectPhysicalDevice(gpa, teardowns);
        return fixture;
    }

    /// Selects a device at the floor with external-memory fd support.
    fn selectPhysicalDevice(
        self: *Fixture,
        gpa: std.mem.Allocator,
        teardowns: *TeardownErrors,
    ) TestError!void {
        // The count query and the fetch below are the same entry point.
        const enumerate_physical_devices =
            self.instance_procs.enumerate_physical_devices orelse
            return error.MissingInstanceProc;
        const get_properties =
            self.instance_procs.get_physical_device_properties orelse
            return error.MissingInstanceProc;
        const get_memory_properties =
            self.instance_procs.get_physical_device_memory_properties orelse
            return error.MissingInstanceProc;
        var count: u32 = 0;
        try dispatch.checkVkSuccess(
            enumerate_physical_devices(self.instance, &count, null),
        );
        if (count == 0) return error.NoPhysicalDevice;

        const devices = try gpa.alloc(vulkan.VkPhysicalDevice, count);
        defer gpa.free(devices);
        try dispatch.checkVkSuccess(
            enumerate_physical_devices(
                self.instance,
                &count,
                devices.ptr,
            ),
        );

        // Bound: the devices the instance reported. A driver may report fewer
        // the second time and never more, so the second call cannot outrun the
        // array the first call sized.
        var reached_floor = false;
        var missing_extensions = false;
        var missing_family = false;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            // The handle the driver wrote into the scratch array, named once
            // because the body reads it four times. Naming it is a copy and
            // not a borrow: a `VkPhysicalDevice` is an opaque handle the
            // driver owns, not a view into `devices`, so the array is a
            // scratch buffer that the `defer` above may hand back the moment
            // this function returns while the handle stays valid until
            // `vkDestroyInstance`.
            const physical = devices[index];
            // SAFETY: `get_properties` writes every field of the struct before
            // it returns, and the `apiVersion` read below is the first read.
            var properties: vulkan.VkPhysicalDeviceProperties = undefined;
            get_properties(physical, &properties);
            if (properties.apiVersion < vulkan.VK_API_VERSION_1_1) continue;
            reached_floor = true;

            if (!try self.hasDeviceExtensions(gpa, physical)) {
                missing_extensions = true;
                continue;
            }
            const family = try self.findUniversalQueueFamily(gpa, physical) orelse {
                missing_family = true;
                continue;
            };

            self.physical_device = physical;
            self.queue_family_index = family;
            get_memory_properties(
                physical,
                &self.memory_properties,
            );

            // Two devices on one physical device, which is the whole point of
            // the milestone: a descriptor the first device exported has to
            // reach the second.
            self.first = try self.createDevice(gpa);
            errdefer self.destroyDevice(gpa, &self.first, teardowns);
            self.second = try self.createDevice(gpa);
            return;
        }
        // Each refusal names itself, so a host without the extensions is not
        // reported as a host without a universal queue family.
        if (!reached_floor) return error.NoPhysicalDeviceAtFloor;
        if (missing_family) return error.NoUniversalQueueFamily;
        return error.RequiredDeviceExtensionMissing;
    }

    /// Requires OPAQUE_FD memory and enables semaphore fds only if advertised.
    fn hasDeviceExtensions(
        self: *Fixture,
        gpa: std.mem.Allocator,
        physical: vulkan.VkPhysicalDevice,
    ) TestError!bool {
        // The count query and the fetch below are the same entry point.
        const enumerate_extensions =
            self.instance_procs.enumerate_device_extension_properties orelse
            return error.MissingInstanceProc;
        var count: u32 = 0;
        // A null `pLayerName` asks for the device's own list, which is the
        // list `vkCreateDevice` will be handed below.
        dispatch.checkVkSuccess(enumerate_extensions(
            physical,
            null,
            &count,
            null,
        )) catch |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => return err,
            else => return false,
        };
        if (count == 0) return false;

        const properties = try gpa.alloc(vulkan.VkExtensionProperties, count);
        defer gpa.free(properties);
        dispatch.checkVkSuccess(enumerate_extensions(
            physical,
            null,
            &count,
            properties.ptr,
        )) catch |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => return err,
            else => return false,
        };
        var enabled: dispatch.EnabledDeviceExts = .{};
        for (properties[0..count]) |property| {
            // `extensionName` is a fixed 256-byte array with no sentinel
            // (`src/vulkan.zig:4287`), so the terminator is a byte to find. A
            // driver that fills all 256 bytes is out of contract; the whole
            // array is then the name, which is what the comparison below says.
            const name_end = std.mem.indexOfScalar(u8, &property.extensionName, 0) orelse
                property.extensionName.len;
            const reported: [:0]const u8 = property.extensionName[0..name_end :0];
            if (std.mem.eql(u8, reported, device_extension_names[0])) {
                enabled = enabled.with(.external_memory_fd);
            } else if (std.mem.eql(u8, reported, device_extension_names[1])) {
                enabled = enabled.with(.external_semaphore_fd);
            }
        }
        self.enabled_extensions = enabled;
        return enabled.has(.external_memory_fd);
    }

    /// The first family carrying `universal_queue_flags`.
    fn findUniversalQueueFamily(
        self: *const Fixture,
        gpa: std.mem.Allocator,
        physical: vulkan.VkPhysicalDevice,
    ) TestError!?u32 {
        const get_family_properties =
            self.instance_procs.get_physical_device_queue_family_properties orelse
            return error.MissingInstanceProc;
        var count: u32 = 0;
        get_family_properties(physical, &count, null);
        if (count == 0) return null;

        const families = try gpa.alloc(vulkan.VkQueueFamilyProperties, count);
        defer gpa.free(families);
        get_family_properties(physical, &count, families.ptr);

        // Bound: the families the physical device reported.
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            if (families[index].queueFlags & universal_queue_flags ==
                universal_queue_flags) return index;
        }
        return null;
    }

    /// Creates one queue with the physical device's selected extension set.
    fn createDevice(self: *Fixture, gpa: std.mem.Allocator) TestError!Device {
        const priority: f32 = 0.0;
        var queue_create_info: vulkan.VkDeviceQueueCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO),
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        // `ppEnabledExtensionNames` is a C array of NUL-terminated names, and
        // `enabledExtensionCount` is the element count, so the array carries no
        // terminator of its own. Each `[:0]const u8` becomes a `[*c]const u8`
        // first: a slice would hand the driver a length it never reads, and a
        // `*[N][*:0]const u8` would not coerce element-wise to the pointer the
        // binding names.
        var enabled_names: [device_extension_names.len][*c]const u8 = undefined;
        enabled_names[0] = @ptrCast(device_extension_names[0]);
        var enabled_count: u32 = 1;
        if (self.enabled_extensions.has(.external_semaphore_fd)) {
            enabled_names[1] = @ptrCast(device_extension_names[1]);
            enabled_count += 1;
        }
        var create_info: vulkan.VkDeviceCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO),
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = enabled_count,
            .ppEnabledExtensionNames = &enabled_names,
            .pEnabledFeatures = null,
        };
        const create_device = self.instance_procs.create_device orelse
            return error.MissingInstanceProc;
        const destroy_device = self.instance_procs.destroy_device orelse
            return error.MissingInstanceProc;
        const get_device_proc_addr = self.instance_procs.get_device_proc_addr orelse
            return error.MissingInstanceProc;
        var handle: vulkan.VkDevice = null;
        try dispatch.checkVkSuccess(create_device(
            self.physical_device,
            &create_info,
            null,
            &handle,
        ));
        if (handle == null) return error.HandleCreationReturnedNull;
        // A resolved entry point, so the undo below is a call that cannot fail:
        // an `errdefer` has nowhere to put an error, and `AGENTS.md` §2 forbids
        // going quiet about one.
        errdefer destroy_device(handle, null);

        const procs = try dispatch.loadDeviceProcs(gpa, .{
            .get_device_proc_addr = get_device_proc_addr,
            .device = handle,
            .enabled_extensions = self.enabled_extensions,
        });
        errdefer gpa.destroy(procs);

        const get_device_queue = procs.get_device_queue orelse return error.MissingDeviceProc;
        var queue: vulkan.VkQueue = null;
        get_device_queue(handle, self.queue_family_index, 0, &queue);

        return .{
            .handle = handle,
            .procs = procs,
            .queue = queue,
            .queue_family_index = self.queue_family_index,
            .enabled_extensions = self.enabled_extensions,
        };
    }

    fn destroyDevice(
        self: *const Fixture,
        gpa: std.mem.Allocator,
        device: *Device,
        teardowns: *TeardownErrors,
    ) void {
        destroyDeviceHandle(self.instance_procs, device.handle, teardowns);
        gpa.destroy(device.procs);
        // SAFETY: the teardown above read every field, and the caller drops
        // the `Device` with the fixture, so nothing reads this again.
        device.* = undefined;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator, teardowns: *TeardownErrors) void {
        self.destroyDevice(gpa, &self.second, teardowns);
        self.destroyDevice(gpa, &self.first, teardowns);
        gpa.destroy(self.instance_procs);
        destroyInstance(self.global, self.instance, teardowns);
        gpa.destroy(self.global);
        self.lib.deinit();
        self.* = undefined;
    }
};

/// One image and its exported Vulkan allocation metadata.
const ImageAllocation = struct {
    image: vulkan.VkImage,
    memory: vulkan.VkDeviceMemory,
    allocation_size: vulkan.VkDeviceSize,
    memory_type_index: u32,

    /// The image before the memory that backs it, which is the order
    /// `FENCED_DELETER_TYPES` states at `FencedDeleter.h:46`-`:47`.
    fn deinit(self: ImageAllocation, device: Device, teardowns: *TeardownErrors) void {
        destroyImage(device.procs, device.handle, self.image, teardowns);
        freeMemory(device.procs, device.handle, self.memory, teardowns);
    }
};

/// One host-visible buffer and the memory behind it.
const HostBuffer = struct {
    buffer: vulkan.VkBuffer,
    memory: vulkan.VkDeviceMemory,

    fn deinit(self: HostBuffer, device: Device, teardowns: *TeardownErrors) void {
        destroyBuffer(device.procs, device.handle, self.buffer, teardowns);
        freeMemory(device.procs, device.handle, self.memory, teardowns);
    }
};

/// A command pool and the one command buffer taken from it.
const CommandPool = struct {
    pool: vulkan.VkCommandPool,
    command_buffer: vulkan.VkCommandBuffer,

    fn deinit(self: CommandPool, device: Device, teardowns: *TeardownErrors) void {
        freeCommandBuffers(
            device.procs,
            device.handle,
            self.pool,
            &self.command_buffer,
            teardowns,
        );
        destroyCommandPool(device.procs, device.handle, self.pool, teardowns);
    }
};

test "the value the first device wrote is the value the second device samples" {
    var teardowns: TeardownErrors = .{};
    var fixture = try Fixture.init(std.testing.allocator, &teardowns);
    defer fixture.deinit(std.testing.allocator, &teardowns);

    const first_service = MemoryService.init(.{
        .physical_device = fixture.physical_device,
        .device = fixture.first.handle,
        .instance_procs = fixture.instance_procs,
        .device_procs = fixture.first.procs,
        .enabled_extensions = fixture.first.enabled_extensions,
    });
    // `CheckSupport` is one extension bit
    // (`MemoryServiceImplementationOpaqueFD.cpp:47`), so the negative space
    // here is the service itself rather than a query against a device.
    try std.testing.expect(first_service.isSupported());
    try std.testing.expect(first_service.supportsCreateImage());
    // `SupportsImportMemory` (`MemoryServiceImplementationOpaqueFD.cpp:51`) is
    // what the import below depends on: without the importable feature bit the
    // second device cannot take the descriptor at all.
    try std.testing.expect(first_service.supportsImportMemory(.{
        .format = shared_format,
        .image_type = vulkan.VK_IMAGE_TYPE_2D,
        .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
        .usage = shared_usage,
    }));

    // The first device's half. `CreateImage`
    // (`MemoryServiceImplementationOpaqueFD.cpp:162`) is the ported entry
    // point that makes the image exportable, so the descriptor below names
    // this image's memory.
    const exported_image = try createSharedImage(&fixture, fixture.first);
    defer exported_image.deinit(fixture.first, &teardowns);

    // The write. A staging buffer the host fills and a copy into the image,
    // both on the first device, so the value under test was produced by a
    // submission rather than by a map on the memory being shared.
    const staging = try createHostBuffer(
        &fixture,
        fixture.first,
        shared_byte_count,
        vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    );
    defer staging.deinit(fixture.first, &teardowns);
    try writeThroughBuffer(fixture.first, staging, written_value);
    try copyBufferToImage(fixture.first, staging, exported_image.image, &teardowns);

    // The write is real before anything is shared. A copy that recorded
    // nothing, or recorded the wrong region, would leave the export of a
    // blank image intact and name the wrong step as the failure below.
    const probe = try createHostBuffer(
        &fixture,
        fixture.first,
        shared_byte_count,
        vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    );
    defer probe.deinit(fixture.first, &teardowns);
    try copyImageToBuffer(fixture.first, exported_image.image, probe, &teardowns);
    const written_back = try readThroughBuffer(fixture.first, probe);
    try std.testing.expectEqual(written_value, written_back);

    // The export. `vkGetMemoryFdKHR` hands over a descriptor the second
    // device can import; the memory stays alive until the test ends, which is
    // what the specification asks for while a descriptor is outstanding.
    const descriptor = try exportImageMemory(fixture.first, exported_image.memory);
    try std.testing.expect(descriptor >= 0);
    var descriptor_owned = true;
    defer if (descriptor_owned) platform.closeSemaphoreHandle(std.testing.io, descriptor);

    // The second device's half. The same ported `CreateImage` builds its side
    // of the shared allocation, which is the image `importMemory` measures and
    // the image the imported memory is bound to. It gets no allocation of its
    // own: `vkBindImageMemory` binds an image once, so the import is the only
    // memory this image ever names.
    const second_service = MemoryService.init(.{
        .physical_device = fixture.physical_device,
        .device = fixture.second.handle,
        .instance_procs = fixture.instance_procs,
        .device_procs = fixture.second.procs,
        .enabled_extensions = fixture.second.enabled_extensions,
    });
    const shared_image = try createImage(&fixture, fixture.second);
    // Torn down by hand rather than by `defer`, because the imported memory
    // below is bound to this image: the image goes first, then the memory the
    // import created.
    var imported_memory: ?vulkan.VkDeviceMemory = null;
    defer {
        destroyImage(fixture.second.procs, fixture.second.handle, shared_image, &teardowns);
        if (imported_memory) |memory| {
            freeMemory(fixture.second.procs, fixture.second.handle, memory, &teardowns);
        }
    }

    const readback = try createHostBuffer(
        &fixture,
        fixture.second,
        shared_byte_count,
        vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    );
    defer readback.deinit(fixture.second, &teardowns);

    // OPAQUE_FD preserves the exporting Vulkan allocation's memory type.
    // Both logical devices use this fixture's one physical device and driver,
    // so their memory type tables are compatible. Querying fd properties for
    // this handle type is forbidden by VUID-00674.
    const memory_type_index = exported_image.memory_type_index;

    // The control. A second descriptor out of the same allocation, imported
    // into the device that exported it, through the same service and with the
    // same shape of parameters: `vkGetMemoryFdKHR` may be called again for one
    // allocation, so the two descriptors name one piece of memory. A self
    // import that succeeds is what makes the second device's refusal a driver
    // fact rather than a port fact — the service, the arguments and the
    // allocation are the same and the device is the only thing that changed.
    // The imported memory is not bound to `control_image`: `importMemory`
    // allocates, and binding is the caller's own step, which the claim the
    // control supports is not about.
    const control_image = try createImage(&fixture, fixture.first);
    defer destroyImage(fixture.first.procs, fixture.first.handle, control_image, &teardowns);
    const control_descriptor = try exportImageMemory(fixture.first, exported_image.memory);
    var control_descriptor_owned = true;
    defer if (control_descriptor_owned) platform.closeSemaphoreHandle(std.testing.io, control_descriptor);
    const control_params = try first_service.getMemoryImportParams(.{
        .allocation_size = exported_image.allocation_size,
        .memory_type_index = exported_image.memory_type_index,
        .dedicated_allocation = .no,
    }, control_image);
    const control_memory = try first_service.importMemory(
        control_descriptor,
        control_params,
        control_image,
    );
    control_descriptor_owned = false;
    defer freeMemory(fixture.first.procs, fixture.first.handle, control_memory, &teardowns);

    // The control's own claim: a service that reports no support and imports
    // anyway is not a control, it is a coincidence.
    try std.testing.expect(control_memory != null);

    // The import. `getMemoryImportParams`
    // (`MemoryServiceImplementationOpaqueFD.cpp:105`) carries the descriptor's
    // own numbers through, and `importMemory` (`:123`) takes ownership of the
    // descriptor, so nothing closes it and nothing reads it afterwards.
    const params = try second_service.getMemoryImportParams(.{
        .allocation_size = exported_image.allocation_size,
        .memory_type_index = memory_type_index,
        .dedicated_allocation = .no,
    }, shared_image);
    try std.testing.expect(!params.dedicated_allocation);
    try std.testing.expectEqual(exported_image.allocation_size, params.allocation_size);

    imported_memory = try second_service.importMemory(
        descriptor,
        params,
        shared_image,
    );
    descriptor_owned = false;
    const bind_image_memory = fixture.second.procs.bind_image_memory orelse
        return error.MissingDeviceProc;
    // The import below is what wrote `imported_memory`, and a null one would
    // bind nothing: the shard made it, so a null handle is a port defect and
    // not a driver answer.
    const memory = imported_memory orelse return error.HandleCreationReturnedNull;
    try dispatch.checkVkSuccess(bind_image_memory(
        fixture.second.handle,
        shared_image,
        memory,
        0,
    ));

    // The sample. The second device copies the shared image back out to host
    // memory and the host reads what the second device produced, which is the
    // only observation that can tell two devices apart from one memory.
    try copyImageToBuffer(fixture.second, shared_image, readback, &teardowns);
    const sampled = try readThroughBuffer(fixture.second, readback);
    try std.testing.expectEqual(written_value, sampled);
    // The body's last statement: a deferred teardown that could not report its
    // own failure is reported here instead.
    try teardowns.report();
}

test "the exported descriptor is a real, readable descriptor" {
    var teardowns: TeardownErrors = .{};
    var fixture = try Fixture.init(std.testing.allocator, &teardowns);
    defer fixture.deinit(std.testing.allocator, &teardowns);

    // The descriptor below comes from the family this service supports, so
    // the service is built here and its answer is part of the claim: a
    // descriptor from a service that reports no support would prove nothing.
    const service = MemoryService.init(.{
        .physical_device = fixture.physical_device,
        .device = fixture.first.handle,
        .instance_procs = fixture.instance_procs,
        .device_procs = fixture.first.procs,
        .enabled_extensions = fixture.first.enabled_extensions,
    });
    try std.testing.expect(service.isSupported());

    const image = try createSharedImage(&fixture, fixture.first);
    defer image.deinit(fixture.first, &teardowns);

    const descriptor = try exportImageMemory(fixture.first, image.memory);

    // The descriptor is open and names a real file. `stat` is the check that
    // cannot pass on a bare number: it asks the kernel for the inode behind
    // the descriptor-table entry, and a descriptor that is closed or was never
    // open has no entry to ask about.
    const stat = try platform
        .fileFromSemaphoreDescriptor(descriptor)
        .stat(std.testing.io);
    try std.testing.expect(stat.inode != 0);

    // The access mode is a reading one. `fcntl(F_GETFL)` is behind the syscall
    // layer because `std.posix` at 0.16.0 wraps no `fcntl`, which is the same
    // reason `src/platform/external_semaphore.zig` calls `dup` there.
    const raw = std.os.linux.fcntl(descriptor, @intCast(std.os.linux.F.GETFL), 0);
    if (std.os.linux.errno(raw) != .SUCCESS) return error.DescriptorFlagsUnreadable;
    const flags: u32 = @intCast(@as(isize, @bitCast(raw)));
    // `std.os.linux.O` is a `packed struct(u32)` with no `decode` at 0.16.0, so
    // the flag word is bit-cast into the layout and the access mode is read
    // from it. `ACCMODE` is the low two bits, which is why a packed view of
    // the whole word is exact rather than a slice of it.
    const open_flags: std.os.linux.O = @bitCast(flags);
    try std.testing.expect(open_flags.ACCMODE != .WRONLY);

    // `dup(2)` is the strongest cheap proof that the entry is live, because
    // the kernel refuses a descriptor that is closed or was never open. The
    // copy is a second reference to the same open file, so it reports the
    // same inode and closes without touching the original.
    const duplicate = try platform.duplicateSemaphoreHandle(descriptor);
    defer platform.closeSemaphoreHandle(std.testing.io, duplicate);
    try std.testing.expect(duplicate >= 0);
    try std.testing.expect(duplicate != descriptor);
    const duplicate_stat = try platform
        .fileFromSemaphoreDescriptor(duplicate)
        .stat(std.testing.io);
    try std.testing.expectEqual(stat.inode, duplicate_stat.inode);

    // The descriptor family closes through the port's own entry point, which
    // is the only ownership the shard claims for it: `CloseHandle`
    // (`SemaphoreServiceImplementationFD.cpp:186`) short-circuits on the `-1`
    // sentinel and otherwise hands the descriptor to `close(2)`.
    platform.closeSemaphoreHandle(std.testing.io, descriptor);
    try teardowns.report();
}

test "native semaphore fd operations honor capability and sync-fd sentinel semantics" {
    var teardowns: TeardownErrors = .{};
    var fixture = try Fixture.init(std.testing.allocator, &teardowns);
    defer fixture.deinit(std.testing.allocator, &teardowns);

    const opaque_service = SemaphoreService.init(.{
        .device = fixture.first.handle,
        .device_procs = fixture.first.procs,
        .support = opaqueSupport(&fixture),
    });
    try std.testing.expectError(
        error.InvalidSemaphoreHandle,
        SemaphoreService.importSemaphore(std.testing.io, opaque_service, -1),
    );
    if (opaque_service.isSupported()) {
        const exported = try opaque_service.createExportableSemaphore();
        defer destroySemaphore(fixture.first.procs, fixture.first.handle, exported, &teardowns);
        const descriptor = try opaque_service.exportSemaphore(exported);
        defer platform.closeSemaphoreHandle(std.testing.io, descriptor);
        const second = SemaphoreService.init(.{
            .device = fixture.second.handle,
            .device_procs = fixture.second.procs,
            .support = opaqueSupport(&fixture),
        });
        const imported = try SemaphoreService.importSemaphore(std.testing.io, second, descriptor);
        defer destroySemaphore(fixture.second.procs, fixture.second.handle, imported, &teardowns);
        const signaled = try submitSignalOnly(fixture.first, exported);
        defer destroyFence(fixture.first.procs, fixture.first.handle, signaled, &teardowns);
        try waitForFence(fixture.first, signaled);
        const waited = try submitWaitOnly(fixture.second, imported);
        defer destroyFence(fixture.second.procs, fixture.second.handle, waited, &teardowns);
        try waitForFence(fixture.second, waited);
    } else {
        // A legal creation request must fail before allocating a semaphore.
        try std.testing.expectError(error.UnsupportedHandleType, opaque_service.createExportableSemaphore());
    }

    var sync_support = opaqueSupport(&fixture);
    sync_support.handle_type = .sync_fd;
    const sync_service = SemaphoreService.init(.{
        .device = fixture.second.handle,
        .device_procs = fixture.second.procs,
        .support = sync_support,
    });
    try std.testing.expectError(
        error.InvalidSemaphoreHandle,
        SemaphoreService.importSemaphore(std.testing.io, sync_service, -2),
    );
    if (sync_service.isSupported()) {
        const already_signaled = try SemaphoreService.importSemaphore(
            std.testing.io,
            sync_service,
            platform.semaphore_fd_already_signaled_fd,
        );
        defer destroySemaphore(fixture.second.procs, fixture.second.handle, already_signaled, &teardowns);
        const waited = try submitWaitOnly(fixture.second, already_signaled);
        defer destroyFence(fixture.second.procs, fixture.second.handle, waited, &teardowns);
        try waitForFence(fixture.second, waited);
    } else {
        // -1 is a legal SYNC_FD import, but does not waive device capability.
        try std.testing.expectError(
            error.UnsupportedHandleType,
            SemaphoreService.importSemaphore(
                std.testing.io,
                sync_service,
                platform.semaphore_fd_already_signaled_fd,
            ),
        );
    }
    try teardowns.report();
}

fn opaqueSupport(fixture: *Fixture) platform.SemaphoreSupportOptions {
    return .{
        .physical_device = fixture.physical_device,
        .instance_procs = fixture.instance_procs,
        .enabled_extensions = fixture.first.enabled_extensions,
        .handle_type = .opaque_fd,
    };
}

/// The base create info the shard owns for the shared image. The service
/// replaces the tiling, the initial layout and the `pNext` chain
/// (`MemoryServiceImplementationOpaqueFD.cpp:166`-`:175`), so the base carries
/// only what the caller chose: the format, the extent and the usage.
fn sharedImageBase() vulkan.VkImageCreateInfo {
    return .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .imageType = @intCast(vulkan.VK_IMAGE_TYPE_2D),
        .format = shared_format,
        .extent = shared_extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
        .tiling = @intCast(vulkan.VK_IMAGE_TILING_OPTIMAL),
        .usage = shared_usage,
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
    };
}

/// `memory_service.Service.createImage`
/// (`MemoryServiceImplementationOpaqueFD.cpp:162`) over that base: the
/// exportable image, with nothing bound to it. The second device's half of the
/// first test binds an import to the image this returns, so the image and the
/// memory behind it are two steps here.
fn createImage(fixture: *Fixture, device: Device) TestError!vulkan.VkImage {
    const service = MemoryService.init(.{
        .physical_device = fixture.physical_device,
        .device = device.handle,
        .instance_procs = fixture.instance_procs,
        .device_procs = device.procs,
        .enabled_extensions = device.enabled_extensions,
    });
    return service.createImage(sharedImageBase());
}

/// The image `createImage` built and the exportable allocation behind it, with
/// the two numbers an import needs to name that memory.
fn createSharedImage(fixture: *Fixture, device: Device) TestError!ImageAllocation {
    // Every entry point this helper calls, resolved once and up here so each
    // call below reads a field that cannot be null. All of them are core
    // Vulkan 1.0.
    const destroy_image = device.procs.destroy_image orelse
        return error.MissingDeviceProc;
    const get_image_memory_requirements = device.procs.get_image_memory_requirements orelse
        return error.MissingDeviceProc;
    const allocate_memory = device.procs.allocate_memory orelse
        return error.MissingDeviceProc;
    const free_memory = device.procs.free_memory orelse return error.MissingDeviceProc;
    const bind_image_memory = device.procs.bind_image_memory orelse
        return error.MissingDeviceProc;

    const image = try createImage(fixture, device);
    errdefer destroy_image(device.handle, image, null);

    // SAFETY: `get_image_memory_requirements` writes the whole struct before
    // it returns, and the `memoryTypeBits` read below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    get_image_memory_requirements(device.handle, image, &requirements);
    if (requirements.memoryTypeBits == 0) return error.NoMemoryType;
    const type_index = try findMemoryTypeIndex(
        &fixture.memory_properties,
        requirements.memoryTypeBits,
        vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        0,
    );

    // The export is the allocation side of the descriptor: `VkExportMemoryAllocateInfo`
    // is what `ResourceMemoryAllocatorVk.cpp` builds for a resource that will
    // be exported, and this shard is that side for one image.
    var export_info: vulkan.VkExportMemoryAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO),
        .pNext = null,
        .handleTypes = @intCast(vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT),
    };
    var allocate_info: vulkan.VkMemoryAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO),
        .pNext = &export_info,
        // `VK_IMAGE_CREATE_ALIAS_BIT` is what `createImage` sets, and an
        // aliased image's memory is bound whole, so the allocation is exactly
        // the requirement and not a round-up of it.
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: vulkan.VkDeviceMemory = null;
    try dispatch.checkVkSuccess(allocate_memory(
        device.handle,
        &allocate_info,
        null,
        &memory,
    ));
    errdefer free_memory(device.handle, memory, null);
    try dispatch.checkVkSuccess(bind_image_memory(
        device.handle,
        image,
        memory,
        0,
    ));

    return .{
        .image = image,
        .memory = memory,
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    };
}

/// A buffer over host-visible, host-coherent memory, so the host can fill it
/// and read it without a flush and without an invalidate. The flags are the
/// ones `findMemoryTypeIndex` filters on, and they are the reason the value
/// crossing between the two devices can be compared as a number.
fn createHostBuffer(
    fixture: *Fixture,
    device: Device,
    size: vulkan.VkDeviceSize,
    usage: vulkan.VkBufferUsageFlags,
) TestError!HostBuffer {
    const create_info: vulkan.VkBufferCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = usage,
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    const create_buffer = device.procs.create_buffer orelse return error.MissingDeviceProc;
    const destroy_buffer = device.procs.destroy_buffer orelse return error.MissingDeviceProc;
    const get_buffer_memory_requirements = device.procs.get_buffer_memory_requirements orelse
        return error.MissingDeviceProc;
    const allocate_memory = device.procs.allocate_memory orelse
        return error.MissingDeviceProc;
    const free_memory = device.procs.free_memory orelse return error.MissingDeviceProc;
    const bind_buffer_memory = device.procs.bind_buffer_memory orelse
        return error.MissingDeviceProc;
    var buffer: vulkan.VkBuffer = null;
    try dispatch.checkVkSuccess(create_buffer(
        device.handle,
        &create_info,
        null,
        &buffer,
    ));
    if (buffer == null) return error.HandleCreationReturnedNull;
    errdefer destroy_buffer(device.handle, buffer, null);

    // SAFETY: `get_buffer_memory_requirements` writes the whole struct before
    // it returns, and the `memoryTypeBits` read below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    get_buffer_memory_requirements(device.handle, buffer, &requirements);
    if (requirements.memoryTypeBits == 0) return error.NoMemoryType;
    const type_index = try findMemoryTypeIndex(
        &fixture.memory_properties,
        requirements.memoryTypeBits,
        vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        0,
    );
    var allocate_info: vulkan.VkMemoryAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO),
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: vulkan.VkDeviceMemory = null;
    try dispatch.checkVkSuccess(allocate_memory(
        device.handle,
        &allocate_info,
        null,
        &memory,
    ));
    errdefer free_memory(device.handle, memory, null);
    try dispatch.checkVkSuccess(bind_buffer_memory(
        device.handle,
        buffer,
        memory,
        0,
    ));

    return .{ .buffer = buffer, .memory = memory };
}

/// `vkGetMemoryFdKHR`. The port has no export entry point, because Dawn has
/// none either: export is the resource side of the allocation, which is
/// `ResourceMemoryAllocatorVk.cpp` and M11's, and this shard is that side for
/// one image.
fn exportImageMemory(
    device: Device,
    memory: vulkan.VkDeviceMemory,
) TestError!platform.ExternalMemoryHandle {
    var get_info: vulkan.VkMemoryGetFdInfoKHR = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR),
        .pNext = null,
        .memory = memory,
        .handleType = @intCast(vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT),
    };
    var descriptor: c_int = 0;
    const get_memory_fd_khr = device.procs.get_memory_fd_khr orelse
        return error.MissingDeviceProc;
    try dispatch.checkVkSuccess(get_memory_fd_khr(
        device.handle,
        &get_info,
        &descriptor,
    ));
    if (descriptor < 0) return error.InvalidMemoryHandle;
    return @intCast(descriptor);
}

/// Records one copy from `source` into `image` on `device` and submits it.
///
/// The image begins in `UNDEFINED` because `CreateImage` sets that initial
/// layout (`MemoryServiceImplementationOpaqueFD.cpp:167`), and the barrier is
/// what makes the host's staging write available to the transfer.
fn copyBufferToImage(
    device: Device,
    source: HostBuffer,
    image: vulkan.VkImage,
    teardowns: *TeardownErrors,
) TestError!void {
    const pool = try createPool(device);
    defer pool.deinit(device, teardowns);

    var buffer_barrier: vulkan.VkBufferMemoryBarrier = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER),
        .pNext = null,
        .srcAccessMask = @intCast(vulkan.VK_ACCESS_HOST_WRITE_BIT),
        .dstAccessMask = @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT),
        .srcQueueFamilyIndex = queue_family_ignored,
        .dstQueueFamilyIndex = queue_family_ignored,
        .buffer = source.buffer,
        .offset = 0,
        .size = vulkan.VK_WHOLE_SIZE,
    };
    var image_barrier: vulkan.VkImageMemoryBarrier = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER),
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT),
        .oldLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
        .newLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL),
        .srcQueueFamilyIndex = queue_family_ignored,
        .dstQueueFamilyIndex = queue_family_ignored,
        .image = image,
        .subresourceRange = colorSubresource(),
    };
    const region: vulkan.VkBufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = colorLayers(),
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = shared_extent,
    };

    const begin_command_buffer = device.procs.begin_command_buffer orelse
        return error.MissingDeviceProc;
    const cmd_pipeline_barrier = device.procs.cmd_pipeline_barrier orelse
        return error.MissingDeviceProc;
    const cmd_copy_buffer_to_image = device.procs.cmd_copy_buffer_to_image orelse
        return error.MissingDeviceProc;
    const end_command_buffer = device.procs.end_command_buffer orelse
        return error.MissingDeviceProc;
    try dispatch.checkVkSuccess(begin_command_buffer(
        pool.command_buffer,
        &one_time_begin_info,
    ));
    cmd_pipeline_barrier(
        pool.command_buffer,
        @intCast(vulkan.VK_PIPELINE_STAGE_HOST_BIT),
        @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
        0,
        0,
        null,
        1,
        &buffer_barrier,
        1,
        &image_barrier,
    );
    cmd_copy_buffer_to_image(
        pool.command_buffer,
        source.buffer,
        image,
        vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );
    try dispatch.checkVkSuccess(end_command_buffer(pool.command_buffer));
    try submitAndWait(device, pool.command_buffer, teardowns);
}

/// Records one copy from `image` into `destination` on `device` and submits
/// it. The image is read as `TRANSFER_SRC_OPTIMAL` and the barrier's old
/// layout is `UNDEFINED`, which discards whatever layout the image was in
/// rather than naming one: the two images this shard reads back are in
/// different layouts, the first device's copy left in `TRANSFER_DST_OPTIMAL`
/// and the second device's image is freshly created, and `UNDEFINED` is the one
/// old layout that is valid for both. The host read is made available by the
/// buffer barrier rather than by an invalidate, because the mapping is
/// coherent.
fn copyImageToBuffer(
    device: Device,
    image: vulkan.VkImage,
    destination: HostBuffer,
    teardowns: *TeardownErrors,
) TestError!void {
    const pool = try createPool(device);
    defer pool.deinit(device, teardowns);

    var buffer_barrier: vulkan.VkBufferMemoryBarrier = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER),
        .pNext = null,
        .srcAccessMask = @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT),
        .dstAccessMask = @intCast(vulkan.VK_ACCESS_HOST_READ_BIT),
        .srcQueueFamilyIndex = queue_family_ignored,
        .dstQueueFamilyIndex = queue_family_ignored,
        .buffer = destination.buffer,
        .offset = 0,
        .size = vulkan.VK_WHOLE_SIZE,
    };
    var image_barrier: vulkan.VkImageMemoryBarrier = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER),
        .pNext = null,
        .srcAccessMask = @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT),
        .dstAccessMask = @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT),
        .oldLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
        .newLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL),
        .srcQueueFamilyIndex = queue_family_ignored,
        .dstQueueFamilyIndex = queue_family_ignored,
        .image = image,
        .subresourceRange = colorSubresource(),
    };
    const region: vulkan.VkBufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = colorLayers(),
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = shared_extent,
    };

    const begin_command_buffer = device.procs.begin_command_buffer orelse
        return error.MissingDeviceProc;
    const cmd_pipeline_barrier = device.procs.cmd_pipeline_barrier orelse
        return error.MissingDeviceProc;
    const cmd_copy_image_to_buffer = device.procs.cmd_copy_image_to_buffer orelse
        return error.MissingDeviceProc;
    const end_command_buffer = device.procs.end_command_buffer orelse
        return error.MissingDeviceProc;
    try dispatch.checkVkSuccess(begin_command_buffer(
        pool.command_buffer,
        &one_time_begin_info,
    ));
    cmd_pipeline_barrier(
        pool.command_buffer,
        @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
        @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
        0,
        0,
        null,
        0,
        null,
        1,
        &image_barrier,
    );
    cmd_copy_image_to_buffer(
        pool.command_buffer,
        image,
        vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        destination.buffer,
        1,
        &region,
    );
    cmd_pipeline_barrier(
        pool.command_buffer,
        @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT),
        @intCast(vulkan.VK_PIPELINE_STAGE_HOST_BIT),
        0,
        0,
        null,
        1,
        &buffer_barrier,
        0,
        null,
    );
    try dispatch.checkVkSuccess(end_command_buffer(pool.command_buffer));
    try submitAndWait(device, pool.command_buffer, teardowns);
}

/// Maps `host_buffer` over the whole allocation and stores `value` at its
/// first texel. The mapping is coherent memory, so the write is available to
/// the device without a flush.
fn writeThroughBuffer(
    device: Device,
    host_buffer: HostBuffer,
    value: u32,
) TestError!void {
    const unmap_memory = device.procs.unmap_memory orelse return error.MissingDeviceProc;
    const mapped = try mapMemory(device, host_buffer.memory);
    defer unmap_memory(device.handle, host_buffer.memory);
    const first: *align(1) u32 = @ptrCast(@alignCast(mapped));
    first.* = value;
}

/// Maps `host_buffer` over the whole allocation and reads its first texel.
fn readThroughBuffer(device: Device, host_buffer: HostBuffer) TestError!u32 {
    const unmap_memory = device.procs.unmap_memory orelse return error.MissingDeviceProc;
    const mapped = try mapMemory(device, host_buffer.memory);
    defer unmap_memory(device.handle, host_buffer.memory);
    const first: *align(1) const u32 = @ptrCast(@alignCast(mapped));
    return first.*;
}

fn mapMemory(device: Device, memory: vulkan.VkDeviceMemory) TestError!*anyopaque {
    var mapped: ?*anyopaque = null;
    const map = device.procs.map_memory orelse return error.MissingDeviceProc;
    try dispatch.checkVkSuccess(map(
        device.handle,
        memory,
        0,
        vulkan.VK_WHOLE_SIZE,
        0,
        &mapped,
    ));
    return mapped orelse error.HandleCreationReturnedNull;
}

/// The command pool each copy records into, and the one command buffer taken
/// from it. A transient pool, because both submissions are one-shot.
fn createPool(device: Device) TestError!CommandPool {
    const create_command_pool = device.procs.create_command_pool orelse
        return error.MissingDeviceProc;
    const destroy_command_pool = device.procs.destroy_command_pool orelse
        return error.MissingDeviceProc;
    const allocate_command_buffers = device.procs.allocate_command_buffers orelse
        return error.MissingDeviceProc;
    const pool_info: vulkan.VkCommandPoolCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO),
        .pNext = null,
        .flags = @intCast(vulkan.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT),
        .queueFamilyIndex = device.queue_family_index,
    };
    var vk_pool: vulkan.VkCommandPool = null;
    try dispatch.checkVkSuccess(create_command_pool(
        device.handle,
        &pool_info,
        null,
        &vk_pool,
    ));
    if (vk_pool == null) return error.HandleCreationReturnedNull;
    errdefer destroy_command_pool(device.handle, vk_pool, null);

    var allocate_info: vulkan.VkCommandBufferAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO),
        .pNext = null,
        .commandPool = vk_pool,
        .level = @intCast(vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY),
        .commandBufferCount = 1,
    };
    var command_buffer: vulkan.VkCommandBuffer = null;
    try dispatch.checkVkSuccess(allocate_command_buffers(
        device.handle,
        &allocate_info,
        &command_buffer,
    ));
    return .{ .pool = vk_pool, .command_buffer = command_buffer };
}

fn submitAndWait(
    device: Device,
    command_buffer: vulkan.VkCommandBuffer,
    teardowns: *TeardownErrors,
) TestError!void {
    const queue_submit = device.procs.queue_submit orelse return error.MissingDeviceProc;
    const fence = try createFence(device);
    defer destroyFence(device.procs, device.handle, fence, teardowns);

    // `pCommandBuffers` is a C array, not a slice, so the one command buffer
    // gets an array of its own. `&.{...}` would peer-resolve against the
    // handle type, which is an opaque pointer, and array-init syntax needs a
    // concrete element type.
    var command_buffers = [1]vulkan.VkCommandBuffer{command_buffer};
    var submit: vulkan.VkSubmitInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO),
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffers,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    try dispatch.checkVkSuccess(queue_submit(
        device.queue,
        1,
        &submit,
        fence,
    ));
    try waitForFence(device, fence);
}

/// Submits no command buffer and waits on `semaphore`, which is how "already
/// signalled" becomes observable: nothing signals the fence except the wait
/// being satisfied.
fn submitWaitOnly(device: Device, semaphore: vulkan.VkSemaphore) TestError!vulkan.VkFence {
    const destroy_fence = device.procs.destroy_fence orelse return error.MissingDeviceProc;
    const queue_submit = device.procs.queue_submit orelse return error.MissingDeviceProc;
    const fence = try createFence(device);
    // `pWaitSemaphores` is a C array, for the same reason `pCommandBuffers` is.
    var wait_semaphores = [1]vulkan.VkSemaphore{semaphore};
    // One nonzero execution stage per binary semaphore.
    var wait_stages = [1]vulkan.VkPipelineStageFlags{
        @intCast(vulkan.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT),
    };
    var submit: vulkan.VkSubmitInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO),
        .pNext = null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 0,
        .pCommandBuffers = null,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    dispatch.checkVkSuccess(queue_submit(
        device.queue,
        1,
        &submit,
        fence,
    )) catch |err| {
        destroy_fence(device.handle, fence, null);
        return err;
    };
    return fence;
}

fn submitSignalOnly(device: Device, semaphore: vulkan.VkSemaphore) TestError!vulkan.VkFence {
    const destroy_fence = device.procs.destroy_fence orelse return error.MissingDeviceProc;
    const queue_submit = device.procs.queue_submit orelse return error.MissingDeviceProc;
    const fence = try createFence(device);
    errdefer destroy_fence(device.handle, fence, null);
    var semaphores = [1]vulkan.VkSemaphore{semaphore};
    var submit: vulkan.VkSubmitInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO),
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &semaphores,
    };
    try dispatch.checkVkSuccess(queue_submit(device.queue, 1, &submit, fence));
    return fence;
}

fn createFence(device: Device) TestError!vulkan.VkFence {
    const fence_info: vulkan.VkFenceCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
    };
    var fence: vulkan.VkFence = null;
    const create_fence = device.procs.create_fence orelse return error.MissingDeviceProc;
    try dispatch.checkVkSuccess(create_fence(
        device.handle,
        &fence_info,
        null,
        &fence,
    ));
    if (fence == null) return error.HandleCreationReturnedNull;
    return fence;
}

fn waitForFence(device: Device, fence: vulkan.VkFence) TestError!void {
    // `pFences` is a C array for the same reason `pCommandBuffers` is above.
    var fence_array = [1]vulkan.VkFence{fence};
    const wait_for_fences = device.procs.wait_for_fences orelse
        return error.MissingDeviceProc;
    const result = wait_for_fences(
        device.handle,
        1,
        &fence_array,
        vulkan.VK_TRUE,
        fence_wait_timeout_ns,
    );
    // A fence that never retires is `VK_TIMEOUT`, which the bound turns into a
    // failure instead of a hang.
    if (result == vulkan.VK_TIMEOUT) return error.FenceWaitTimedOut;
    try dispatch.checkVkSuccess(result);
}

/// The first memory type whose bits intersect `type_bits` and whose properties
/// carry every required flag and none of the forbidden ones. Dawn's selector
/// (`MemoryTypeSelector.cpp`) reports an invalid index rather than a null, so
/// this reports an error rather than an index, per `AGENTS.md` §3.
fn findMemoryTypeIndex(
    properties: *const vulkan.VkPhysicalDeviceMemoryProperties,
    type_bits: u32,
    required_flags: vulkan.VkMemoryPropertyFlags,
    forbidden_flags: vulkan.VkMemoryPropertyFlags,
) TestError!u32 {
    // Bound: the types the device reported.
    var index: u32 = 0;
    while (index < properties.memoryTypeCount) : (index += 1) {
        if (type_bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
        const flags = properties.memoryTypes[index].propertyFlags;
        if (flags & required_flags != required_flags) continue;
        if (forbidden_flags != 0 and flags & forbidden_flags != 0) continue;
        return index;
    }
    return error.NoMemoryType;
}

const one_time_begin_info: vulkan.VkCommandBufferBeginInfo = .{
    .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO),
    .pNext = null,
    .flags = @intCast(vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT),
    .pInheritanceInfo = null,
};

fn colorSubresource() vulkan.VkImageSubresourceRange {
    return .{
        .aspectMask = @intCast(vulkan.VK_IMAGE_ASPECT_COLOR_BIT),
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

fn colorLayers() vulkan.VkImageSubresourceLayers {
    return .{
        .aspectMask = @intCast(vulkan.VK_IMAGE_ASPECT_COLOR_BIT),
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}
