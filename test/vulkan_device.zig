//! M9 acceptance: one `VkInstance` per ICD in fallback-first order, a device on
//! the first physical device that reports Vulkan 1.1 or later, a `vkCmdFillBuffer`
//! into a 4 KiB buffer, a submit, a 5,000 ms fence wait, and a teardown that
//! leaves no live handle.
//!
//! **The gate line runs this shard with `VK_LOADER_LAYERS_DISABLE=*`.**
//! `docs/40-plan.md` §1 M9 names that environment, and
//! `docs/50-verification.md` §4.2 records the measured result: the loader forces
//! every layer off. The test asserts the variable when it is set, and the
//! instance requests no layer of its own, so a layer cannot reach Vulkan through
//! this path either way.
//!
//! **What this test does not claim.** It does not claim anything about memory
//! content. `vkCmdFillBuffer` is recorded, submitted and retired, but nothing
//! reads the buffer back: M10 owns the readback and its 1 MiB pattern, and a
//! test that asserted on bytes it never read would be an assertion on nothing.
//! It creates no surface and no swap chain, because the host is headless
//! (`AGENTS.md` §5).
//!
//! **The build wiring this shard needs.** The shard root is this file, the
//! library is `@import("dusk")` and the bindings are `@import("vulkan")`, the
//! two names the shard module declares for itself. Every type below is
//! therefore the one `src/engine/vulkan_device.zig` and `src/vk/dispatch.zig`
//! declare. A relative import into `src/` would instead pull a second copy of
//! each file into this module, and a shard that mixes the two styles then
//! holds two distinct `dispatch.DeviceProcs` types, which no build can
//! reconcile.

const std = @import("std");
const dusk = @import("dusk");
const vulkan = @import("vulkan");

const dispatch = dusk.vk.dispatch;
const platform = dusk.platform;
const vulkan_device = dusk.engine.vulkan_device;
const queue = dusk.engine.queue;

/// The size the acceptance names. 4 KiB is the smallest fill that spans more
/// than one page, so a driver that skipped the command would still retire the
/// fence and nothing else here would notice.
const fill_buffer_byte_count: vulkan.VkDeviceSize = 4096;

/// The value the fill writes. Its bits are not read by this test; it is fixed so
/// the same command is recorded on every run.
const fill_pattern: u32 = 0xCDAB_3412;

/// The buffer and the memory behind it.
const FillAllocation = struct {
    buffer: vulkan.VkBuffer,
    memory: vulkan.VkDeviceMemory,
};

/// The failures a `std.testing` assertion can report from a helper that
/// declares `SetupError`. `createFillAllocation` asserts, and a helper that
/// asserts cannot drop its assertion's error, so it is named here rather than
/// left off and rejected at the call site.
const AssertionError = error{TestUnexpectedResult};

/// The errors a test-local Vulkan call can report. `dispatch.Error` is the whole
/// driver-code set, the two `ProcError` sets are what the device, the backend
/// and the queue refuse with now that their teardowns report rather than
/// returning `void`, and `error.OutOfMemory` is the only allocation this test
/// can fail, because nothing else here allocates through `gpa`.
const SetupError = vulkan_device.ProcError ||
    queue.ProcError ||
    dispatch.Error ||
    std.mem.Allocator.Error ||
    AssertionError ||
    error{
        /// `vkCreateBuffer`, `vkAllocateMemory` or `vkBindBufferMemory` succeeded
        /// and returned a null handle.
        HandleCreationReturnedNull,
        /// No memory type is legal for the buffer. `vulkan_device.findMemoryTypeIndex`
        /// refuses the device-local types, and a driver whose every type is
        /// device-local cannot satisfy a fill that has to be real.
        NoMemoryType,
        /// `vkCmdFillBuffer` is not in the device tier, which `loadDeviceProcs`
        /// guarantees for core Vulkan 1.0. Reaching this means the dispatch table is
        /// not what `docs/40-plan.md` §1 M1 says it is.
        FillCommandUnavailable,
        /// The device tier did not supply one of the entry points this test calls.
        /// `dispatch.loadDeviceProcs` refuses with `MissingDeviceProc` for the same
        /// reason (`src/vk/dispatch.zig:1055`), and `AGENTS.md` §3.1 makes a missing
        /// entry point an error rather than a panic.
        MissingProc,
    };

/// Names the entry point the device tier did not supply, and returns the
/// typed error the caller propagates.
///
/// `dispatch.loadDeviceProcs` fills every core entry point or refuses with
/// `MissingDeviceProc` (`src/vk/dispatch.zig:1055`), so a forced unwrap would
/// replace that named refusal with a panic. Every call below resolves the
/// entry point it needs and reports the same refusal. `error.MissingProc`
/// carries no call, so the symbol goes to the log beside it: the shard fails
/// on the returned error either way, so the log adds the name without
/// deciding the outcome. The argument is the symbol without its `vk` prefix.
fn missingProc(symbol_name: []const u8) SetupError {
    std.log.err("missing entry point: vk{s}", .{symbol_name});
    return error.MissingProc;
}

test "test-vulkan-device" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try expectNoLayersForced(std.testing.allocator);

    var handles: vulkan_device.HandleSet = .{};
    var device_mutex: platform.DeviceMutex = .{};

    // One `VkInstance` per ICD, fallback first (`BackendVk.cpp:590`-`:615`). An
    // ICD whose library will not open is skipped, and an ICD that reports no
    // device is skipped, so the first adapter may come from either entry.
    var backend = vulkan_device.Backend.init(std.testing.allocator, .{ .handles = &handles });
    var adapters = try backend.discoverPhysicalDevices(.{});
    try std.testing.expect(adapters.items.len != 0);

    // `discoverPhysicalDevices` already refused a device below the floor
    // (`VulkanInfo.cpp:92-94`), and the adapter taken is the first one that
    // survived the filter.
    const adapter = try adapters.first();
    try std.testing.expect(adapter.physical.supportsRequiredVersion());
    try std.testing.expect(adapter.physical.properties.apiVersion >=
        vulkan_device.required_vulkan_version);
    try std.testing.expect(adapter.instance.loader_api_version >=
        vulkan_device.required_vulkan_version);
    try std.testing.expect(adapter.physical.queue_families.len != 0);
    try std.testing.expect(adapter.physical.deviceName().len != 0);
    try std.testing.expectEqual(icdCount(), backend.instances.len);

    var device = try vulkan_device.Device.create(std.testing.allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });
    try std.testing.expectEqual(@as(u32, 1), handles.countOf(.device));
    try std.testing.expect(device.queue_family_index < adapter.physical.queue_families.len);

    var q = try queue.Queue.init(.{
        .context = .{
            .allocator = std.testing.allocator,
            .dispatch = device.dispatchTable(),
            .vk_device = device.vkDevice(),
            .vk_queue = try device.fetchQueue(),
            .queue_family_index = device.queue_family_index,
            .memory_properties = device.memoryProperties(),
            .handles = &handles,
        },
        .device_mutex = &device_mutex,
    });
    // `Queue::Initialize` allocates a pool and begins a buffer before any caller
    // sees the queue (`QueueVk.cpp:93`-`:101`).
    try std.testing.expect(q.commandPool() != null);
    try std.testing.expect(q.commandBuffer() != null);

    const allocation = try createFillAllocation(&device, &handles);
    try std.testing.expectEqual(@as(u32, 1), handles.countOf(.buffer));
    try std.testing.expectEqual(@as(u32, 1), handles.countOf(.memory));

    // The recorded command. M18 owns what a command buffer contains; this
    // milestone records the one command the acceptance names.
    const fill = device.deviceProcs().cmd_fill_buffer orelse
        return error.FillCommandUnavailable;
    fill(q.commandBuffer(), allocation.buffer, 0, fill_buffer_byte_count, fill_pattern);

    const serial_before_submit = q.timeline.lastSubmittedSerial();
    const submitted = try q.submit(.{ .command_buffers = &.{q.commandBuffer()} });
    // The serial is taken after the submit (`QueueVk.cpp:364`-`:367`), so it is
    // the one before plus one and the timeline agrees.
    try std.testing.expectEqual(serial_before_submit + 1, submitted.serial);
    try std.testing.expectEqual(submitted.serial, q.timeline.lastSubmittedSerial());

    // The acceptance's 5,000 ms bound, which the caller may tighten.
    try std.testing.expectEqual(@as(u64, 5_000_000_000), queue.fence_wait_timeout_ns);
    // `Queue::wait` is declared with `io` first (`src/engine/queue.zig:367`),
    // so it is not a member function and is called through the type name.
    const completed = try queue.Queue.wait(io, &q, .{
        .serial = submitted.serial,
        .timeout_ns = queue.fence_wait_timeout_ns,
    });
    try std.testing.expect(completed >= submitted.serial);

    // The assertion the acceptance names: the fence reads back signalled.
    const fence_status = try q.fenceStatus(submitted.fence);
    try std.testing.expectEqual(vulkan.VK_SUCCESS, fence_status);

    // Teardown, in the order the handles were created. The live-handle count is
    // the assertion that no destroy was missed.
    // Every teardown below reports rather than returning `void`
    // (`AGENTS.md` §3.1), and this test runs them as the last statements of its
    // body because a `defer` cannot hand an error back.
    try destroyFillAllocation(&device, allocation, &handles);
    try q.deinit();
    try device.deinit(std.testing.allocator);
    adapters.deinit();
    try backend.deinit();

    try std.testing.expect(handles.isEmpty());
    try std.testing.expectEqual(@as(?vulkan_device.HandleKind, null), handles.firstLeakedKind());
    try std.testing.expectEqual(@as(u32, 0), handles.totalCount());
}

/// How many ICDs the search order holds, which is how many per-ICD tables the
/// backend keeps. Dawn's `kICDCount` (`BackendVk.h:59`).
fn icdCount() usize {
    return vulkan_device.icd_search_order.len;
}

/// Creates the 4 KiB transfer-destination buffer and binds memory to it.
///
/// The buffer is created here rather than through `src/engine/buffer.zig`
/// because M10 owns the WebGPU buffer, and `vkAllocateMemory` is not a
/// milestone-9 upstream file: `ResourceMemoryAllocatorVk.cpp` is absent from
/// §1 M9's module list. This is test scaffolding, not a claimed port, and the
/// memory-type rule it uses is `vulkan_device.findMemoryTypeIndex`.
fn createFillAllocation(
    device: *const vulkan_device.Device,
    handles: *vulkan_device.HandleSet,
) SetupError!FillAllocation {
    const vk_device = device.vkDevice();
    const procs = device.deviceProcs();

    // Every entry point this helper calls, resolved once and up here so each
    // call below reads a field that cannot be null. A missing one is a broken
    // loader, because all six are core Vulkan 1.0.
    const create_buffer = procs.create_buffer orelse return missingProc("CreateBuffer");
    const destroy_buffer = procs.destroy_buffer orelse return missingProc("DestroyBuffer");
    const allocate_memory = procs.allocate_memory orelse return missingProc("AllocateMemory");
    const free_memory = procs.free_memory orelse return missingProc("FreeMemory");
    const bind_buffer_memory = procs.bind_buffer_memory orelse
        return missingProc("BindBufferMemory");
    const get_buffer_memory_requirements = procs.get_buffer_memory_requirements orelse
        return missingProc("GetBufferMemoryRequirements");

    const buffer_create_info: vulkan.VkBufferCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO),
        .flags = 0,
        .size = fill_buffer_byte_count,
        .usage = vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = @intCast(vulkan.VK_SHARING_MODE_EXCLUSIVE),
    };
    var buffer: vulkan.VkBuffer = null;
    try dispatch.checkVkSuccess(
        create_buffer(vk_device, &buffer_create_info, null, &buffer),
    );
    if (buffer == null) return error.HandleCreationReturnedNull;
    handles.acquire(.buffer);
    errdefer handles.release(.buffer);
    errdefer destroy_buffer(vk_device, buffer, null);

    // SAFETY: `vkGetBufferMemoryRequirements` is an out-parameter call: the
    // driver writes every field before the statement returns, and the
    // `expect` below is the first read.
    var requirements: vulkan.VkMemoryRequirements = undefined;
    get_buffer_memory_requirements(vk_device, buffer, &requirements);
    try std.testing.expect(requirements.size >= fill_buffer_byte_count);
    try std.testing.expect(requirements.memoryTypeBits != 0);
    try std.testing.expect(requirements.alignment != 0);

    // `vkCmdFillBuffer` on device-local memory is legal and a driver may satisfy
    // it by doing nothing, so the type is chosen with that flag forbidden. See
    // `vulkan_device.findMemoryTypeIndex`.
    const type_index = try vulkan_device.findMemoryTypeIndex(
        device.memoryProperties(),
        requirements.memoryTypeBits,
        0,
        vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    );

    const allocate_info: vulkan.VkMemoryAllocateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO),
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: vulkan.VkDeviceMemory = null;
    try dispatch.checkVkSuccess(
        allocate_memory(vk_device, &allocate_info, null, &memory),
    );
    if (memory == null) return error.HandleCreationReturnedNull;
    handles.acquire(.memory);
    errdefer handles.release(.memory);
    errdefer free_memory(vk_device, memory, null);

    // Offset zero is aligned for every `VkMemoryRequirements`, so the alignment
    // rule needs no arithmetic here.
    try dispatch.checkVkSuccess(bind_buffer_memory(vk_device, buffer, memory, 0));

    return .{ .buffer = buffer, .memory = memory };
}

/// Destroys the fill buffer and its memory. The buffer goes first, because
/// freeing memory a resource is still bound to is invalid, which is the rule
/// `FENCED_DELETER_TYPES` states at `FencedDeleter.h:46`-`:47`.
/// It reports rather than returning `void`, because a teardown that reaches a
/// dispatch field has no other way to name a missing entry point
/// (`AGENTS.md` §3.1), and the test runs it as a statement because a `defer`
/// cannot hand one back.
fn destroyFillAllocation(
    device: *const vulkan_device.Device,
    allocation: FillAllocation,
    handles: *vulkan_device.HandleSet,
) SetupError!void {
    const vk_device = device.vkDevice();
    const procs = device.deviceProcs();
    const destroy_buffer = procs.destroy_buffer orelse return missingProc("DestroyBuffer");
    const free_memory = procs.free_memory orelse return missingProc("FreeMemory");
    destroy_buffer(vk_device, allocation.buffer, null);
    handles.release(.buffer);
    free_memory(vk_device, allocation.memory, null);
    handles.release(.memory);
}

/// Asserts the gate line's no-layer environment when the variable is present.
///
/// `docs/50-verification.md` §4.2 records that `VK_LOADER_LAYERS_DISABLE=*`
/// makes the loader force every layer off, and §4.3 says the setting is
/// per-process. A run without the variable still exercises the same code path,
/// because the instance asks for no layer, so the absence is not a failure; a
/// run with the variable set to anything else is a different configuration, and
/// this says which one it was.
fn expectNoLayersForced(gpa: std.mem.Allocator) !void {
    // 0.16 removed `std.process.getEnvVarOwned`: the process environment now
    // reaches a test through `std.testing.environ`, which the test runner
    // fills from the environment the process was started with, and `getAlloc`
    // is the owned read that replaced it. A variable that is not set reports
    // `error.EnvironmentVariableMissing` rather than an empty optional, so
    // the absence is still not a failure.
    const value = std.testing.environ.getAlloc(
        gpa,
        "VK_LOADER_LAYERS_DISABLE",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => |other| return other,
    };
    defer gpa.free(value);
    try std.testing.expectEqualStrings("*", value);
}
