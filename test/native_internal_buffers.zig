//! Internal buffer creation, native rollback, and unchanged public permissions.
//! The dispatch fixture tests ownership and masks. It does not execute GPU work.

const std = @import("std");
const dusk = @import("dusk");
const buffer = dusk.engine.buffer;
const dispatch = dusk.vk.dispatch;
const vulkan = dusk.platform.vulkan_bindings;
const HandleSet = dusk.engine.vulkan_device.HandleSet;

const copy_src = buffer.BufferUsage{ .copy_src = true };
const copy_dst = buffer.BufferUsage{ .copy_dst = true };
const uniform = buffer.BufferUsage{ .uniform = true };
const indirect = buffer.BufferUsage{ .indirect = true };
const allowed_usage: u32 = copy_src.toFlags() | copy_dst.toFlags() | uniform.toFlags() |
    indirect.toFlags() | buffer.internal_storage_buffer | buffer.read_only_storage_buffer |
    buffer.internal_copy_src_buffer;

const Fixture = struct {
    procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs),
    memory_properties: vulkan.VkPhysicalDeviceMemoryProperties =
        std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties),
    handles: HandleSet = .{},
    create_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    allocate_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    bind_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    create_calls: u32 = 0,
    allocate_calls: u32 = 0,
    bind_calls: u32 = 0,
    destroy_calls: u32 = 0,
    free_calls: u32 = 0,
    created_usage: vulkan.VkBufferUsageFlags = 0,
    created_size: u64 = 0,
    teardown_error: ?buffer.Error = null,
    copy_calls: u32 = 0,
    copied_size: u64 = 0,

    fn init(self: *Fixture) void {
        self.procs.create_buffer = createBuffer;
        self.procs.destroy_buffer = destroyBuffer;
        self.procs.get_buffer_memory_requirements = requirements;
        self.procs.allocate_memory = allocateMemory;
        self.procs.free_memory = freeMemory;
        self.procs.bind_buffer_memory = bindMemory;
        self.memory_properties.memoryTypeCount = 1;
        self.procs.cmd_copy_buffer = copyBuffer;
        self.memory_properties.memoryTypes[0].propertyFlags =
            @intCast(vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    }

    fn device(self: *Fixture) buffer.Device {
        return .{
            .allocator = std.testing.allocator,
            .dispatch = .{ .global = null, .instance = null, .device = &self.procs },
            .vk_device = @ptrCast(self),
            .memory_properties = &self.memory_properties,
            .non_coherent_atom_size = 4,
            .max_buffer_size = 1024,
            .handles = &self.handles,
        };
    }

    fn fromDevice(device_handle: vulkan.VkDevice) *Fixture {
        return @ptrCast(@alignCast(device_handle orelse unreachable));
    }

    fn destroy(self: *Fixture, subject: *buffer.Buffer) void {
        subject.destroy(std.testing.allocator) catch |err| {
            self.teardown_error = err;
        };
    }

    fn finish(self: *const Fixture) !void {
        if (self.teardown_error) |err| return err;
        try std.testing.expectEqual(@as(u32, 0), self.handles.totalCount());
    }

    fn createBuffer(
        device_handle: vulkan.VkDevice,
        info: [*c]const vulkan.VkBufferCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        output: [*c]vulkan.VkBuffer,
    ) callconv(.c) vulkan.VkResult {
        const self = fromDevice(device_handle);
        self.create_calls += 1;
        self.created_usage = info.*.usage;
        self.created_size = info.*.size;
        if (self.create_result != vulkan.VK_SUCCESS) return self.create_result;
        output.* = @ptrCast(self);
        return vulkan.VK_SUCCESS;
    }

    fn destroyBuffer(
        device_handle: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(device_handle).destroy_calls += 1;
    }

    fn requirements(
        device_handle: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        output: [*c]vulkan.VkMemoryRequirements,
    ) callconv(.c) void {
        output.* = .{
            .size = fromDevice(device_handle).created_size,
            .alignment = 4,
            .memoryTypeBits = 1,
        };
    }

    fn allocateMemory(
        device_handle: vulkan.VkDevice,
        _: [*c]const vulkan.VkMemoryAllocateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        output: [*c]vulkan.VkDeviceMemory,
    ) callconv(.c) vulkan.VkResult {
        const self = fromDevice(device_handle);
        self.allocate_calls += 1;
        if (self.allocate_result != vulkan.VK_SUCCESS) return self.allocate_result;
        output.* = @ptrCast(self);
        return vulkan.VK_SUCCESS;
    }

    fn freeMemory(
        device_handle: vulkan.VkDevice,
        _: vulkan.VkDeviceMemory,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        fromDevice(device_handle).free_calls += 1;
    }

    fn bindMemory(
        device_handle: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
    ) callconv(.c) vulkan.VkResult {
        const self = fromDevice(device_handle);
        self.bind_calls += 1;
        return self.bind_result;
    }

    fn copyBuffer(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkBuffer,
        _: vulkan.VkBuffer,
        region_count: u32,
        regions: [*c]const vulkan.VkBufferCopy,
    ) callconv(.c) void {
        const self: *Fixture = @ptrCast(@alignCast(command_buffer orelse unreachable));
        std.debug.assert(region_count == 1);
        self.copy_calls += 1;
        self.copied_size = regions.*.size;
    }
};

test "internal buffers: invalid engine masks refuse before host or native allocation" {
    var fixture: Fixture = .{};
    fixture.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    try std.testing.expectError(error.InternalBufferUsageInvalid, buffer.Buffer.createInternal(
        allocator,
        fixture.device(),
        .{ .size = 4, .native_usage = 0 },
    ));
    inline for (0..32) |shift| {
        const bit = @as(u32, 1) << shift;
        if (bit & allowed_usage == 0) {
            try std.testing.expectError(error.InternalBufferUsageInvalid, buffer.Buffer.createInternal(
                allocator,
                fixture.device(),
                .{ .size = 4, .native_usage = buffer.internal_storage_buffer | bit },
            ));
        }
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.create_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.allocate_calls);
    try fixture.finish();
}

test "internal buffers: size limits refuse before host or native allocation" {
    var fixture: Fixture = .{};
    fixture.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.BufferSizeAboveLimit, buffer.Buffer.createInternal(
        failing.allocator(),
        fixture.device(),
        .{ .size = 1025, .native_usage = buffer.internal_storage_buffer },
    ));
    try std.testing.expectEqual(@as(u32, 0), fixture.create_calls);
    try fixture.finish();
}

test "internal buffers: native creation refusal leaves no native owner" {
    var fixture: Fixture = .{};
    fixture.init();
    fixture.create_result = vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    try std.testing.expectError(error.OutOfDeviceMemory, buffer.Buffer.createInternal(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .native_usage = buffer.internal_storage_buffer },
    ));
    try std.testing.expectEqual(@as(u32, 1), fixture.create_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.allocate_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.destroy_calls);
    try fixture.finish();
}

test "internal buffers: native allocation refusal releases the created buffer" {
    var fixture: Fixture = .{};
    fixture.init();
    fixture.allocate_result = vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    try std.testing.expectError(error.OutOfDeviceMemory, buffer.Buffer.createInternal(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .native_usage = buffer.internal_storage_buffer },
    ));
    try std.testing.expectEqual(@as(u32, 1), fixture.create_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.allocate_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.bind_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.destroy_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.free_calls);
    try fixture.finish();
}

test "internal buffers: native binding refusal releases both acquired handles" {
    var fixture: Fixture = .{};
    fixture.init();
    fixture.bind_result = vulkan.VK_ERROR_DEVICE_LOST;
    try std.testing.expectError(error.DeviceLost, buffer.Buffer.createInternal(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .native_usage = buffer.internal_storage_buffer },
    ));
    try std.testing.expectEqual(@as(u32, 1), fixture.bind_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.destroy_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.free_calls);
    try fixture.finish();
}

test "internal buffers: scratch is unmapped and grants no public permissions" {
    var fixture: Fixture = .{};
    fixture.init();
    try scratchLifecycle(&fixture);
    try fixture.finish();
    try std.testing.expectEqual(@as(u32, 1), fixture.destroy_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.free_calls);
}

fn scratchLifecycle(fixture: *Fixture) !void {
    const native_usage = buffer.internal_storage_buffer | uniform.toFlags() |
        copy_src.toFlags() | copy_dst.toFlags();
    const subject = try buffer.Buffer.createInternal(std.testing.allocator, fixture.device(), .{
        .size = 17,
        .native_usage = native_usage,
    });
    defer fixture.destroy(subject);
    try std.testing.expectEqual(@as(u32, 0), subject.getUsage().toFlags());
    try std.testing.expectEqual(native_usage, subject.getInternalUsage());
    try std.testing.expectEqual(buffer.State.unmapped, subject.getState());
    try std.testing.expect(subject.mapped == null);
    try std.testing.expect(subject.staging == null);
    try std.testing.expect(!subject.is_mapped_at_creation);
    try std.testing.expect(!subject.is_data_initialized);
    try std.testing.expectEqual(@as(u64, 32), subject.getAllocatedSize());
    try std.testing.expectError(error.BufferUsageMissingCopyDst, subject.validateWriteBuffer(.{
        .data = &.{ 1, 2, 3, 4 },
    }));
    try std.testing.expectError(error.BufferMapModeMismatch, subject.validateMapAsync(
        .{ .read = true },
        0,
        4,
    ));
    try std.testing.expectError(error.BufferMapModeMismatch, subject.validateMapAsync(
        .{ .write = true },
        0,
        4,
    ));
    try std.testing.expectEqual(buffer.vulkanBufferUsage(native_usage), fixture.created_usage);
    try std.testing.expectEqual(@as(u32, 1), fixture.handles.countOf(.buffer));
    try std.testing.expectEqual(@as(u32, 1), fixture.handles.countOf(.memory));
}

test "internal buffers: indirect and query resolve derive native storage without public storage" {
    var fixture: Fixture = .{};
    fixture.init();
    try derivedStoragePermissions(&fixture, .{ .indirect = true }, buffer.read_only_storage_buffer);
    try derivedStoragePermissions(&fixture, .{ .query_resolve = true }, buffer.internal_storage_buffer);
    try fixture.finish();
}

fn derivedStoragePermissions(fixture: *Fixture, usage: buffer.BufferUsage, internal: u32) !void {
    const subject = try buffer.Buffer.create(std.testing.allocator, fixture.device(), .{
        .size = 16,
        .usage = usage,
    });
    defer fixture.destroy(subject);
    try std.testing.expectEqual(usage.toFlags(), subject.getUsage().toFlags());
    try std.testing.expect(!subject.getUsage().storage);
    try std.testing.expect(subject.getInternalUsage() & internal != 0);
    try std.testing.expect(fixture.created_usage & vulkan.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT != 0);
    if (usage.indirect) {
        try std.testing.expect(!subject.getUsage().copy_src);
        try std.testing.expect(subject.getInternalUsage() & buffer.internal_copy_src_buffer != 0);
        try std.testing.expect(fixture.created_usage & vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT != 0);
    }
}

test "internal buffers: private CopyDst preimage capability does not authorize public copy source" {
    var fixture: Fixture = .{};
    fixture.init();
    try copyDestinationPermissions(&fixture);
    try fixture.finish();
}

fn copyDestinationPermissions(fixture: *Fixture) !void {
    const subject = try buffer.Buffer.create(std.testing.allocator, fixture.device(), .{
        .size = 16,
        .usage = .{ .copy_dst = true },
    });
    defer fixture.destroy(subject);
    try std.testing.expect(!subject.getUsage().copy_src);
    try std.testing.expect(!subject.getUsage().storage);
    try std.testing.expect(subject.getInternalUsage() & buffer.internal_copy_src_buffer != 0);
    try std.testing.expect(fixture.created_usage & vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT != 0);
    try std.testing.expect(fixture.created_usage & vulkan.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT == 0);
    try std.testing.expectError(error.BufferUsageMissingCopySrc, subject.recordCopyBuffer(
        .{ .command_buffer = null, .pending_serial = 1 },
        subject,
        0,
        0,
        4,
    ));
}

test "internal buffers: public usage validation remains strict" {
    var fixture: Fixture = .{};
    fixture.init();
    try std.testing.expectError(error.BufferUsageEmpty, buffer.Buffer.create(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .usage = .none },
    ));
    try std.testing.expectError(error.BufferUsageMapReadWithOtherUsages, buffer.Buffer.create(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .usage = .{ .map_read = true, .storage = true } },
    ));
    try std.testing.expectError(error.BufferUsageMapWriteWithOtherUsages, buffer.Buffer.create(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .usage = .{ .map_write = true, .copy_dst = true } },
    ));
    try std.testing.expectEqual(@as(u32, 0), fixture.create_calls);
    try fixture.finish();
}

test "internal buffers: each accepted engine bit has native usage stage and access" {
    inline for (.{
        copy_src.toFlags(),
        copy_dst.toFlags(),
        uniform.toFlags(),
        indirect.toFlags(),
        buffer.internal_storage_buffer,
        buffer.read_only_storage_buffer,
        buffer.internal_copy_src_buffer,
    }) |usage| {
        try std.testing.expect(buffer.vulkanBufferUsage(usage) != 0);
        try std.testing.expect(buffer.vulkanPipelineStage(usage, .{ .compute = true }) != 0);
        try std.testing.expect(buffer.vulkanAccessFlags(usage) != 0);
    }
    try std.testing.expect(buffer.read_only_buffer_usages & buffer.internal_copy_src_buffer != 0);
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT)),
        buffer.vulkanAccessFlags(buffer.internal_copy_src_buffer),
    );
    try std.testing.expectEqual(
        @as(vulkan.VkPipelineStageFlags, @intCast(vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT)),
        buffer.vulkanPipelineStage(buffer.internal_copy_src_buffer, .none),
    );
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, @intCast(vulkan.VK_ACCESS_INDIRECT_COMMAND_READ_BIT)),
        buffer.vulkanAccessFlags(indirect.toFlags()),
    );
}

test "internal buffers: private copy reads preimage without adding public CopySrc" {
    var fixture: Fixture = .{};
    fixture.init();
    try internalCopyPreimage(&fixture);
    try fixture.finish();
    try std.testing.expectEqual(@as(u32, 1), fixture.copy_calls);
    try std.testing.expectEqual(@as(u64, 4), fixture.copied_size);
}

fn internalCopyPreimage(fixture: *Fixture) !void {
    const source = try buffer.Buffer.create(std.testing.allocator, fixture.device(), .{
        .size = 16,
        .usage = .{ .copy_dst = true },
    });
    defer fixture.destroy(source);
    const destination = try buffer.Buffer.createInternal(std.testing.allocator, fixture.device(), .{
        .size = 16,
        .native_usage = copy_dst.toFlags() | buffer.internal_storage_buffer,
    });
    defer fixture.destroy(destination);
    source.is_data_initialized = true;
    destination.is_data_initialized = true;
    try destination.recordCopyBufferInternal(
        .{ .command_buffer = @ptrCast(fixture), .pending_serial = 1 },
        source,
        0,
        0,
        4,
    );
    try std.testing.expect(!source.getUsage().copy_src);
    try std.testing.expectEqual(@as(u32, 0), destination.getUsage().toFlags());
}

test "internal buffers: private preimage read tracks transfer hazards as a read" {
    var fixture: Fixture = .{};
    fixture.init();
    try preimageHazards(&fixture);
    try fixture.finish();
}

fn preimageHazards(fixture: *Fixture) !void {
    const subject = try buffer.Buffer.create(std.testing.allocator, fixture.device(), .{
        .size = 16,
        .usage = .{ .copy_dst = true },
    });
    defer fixture.destroy(subject);
    const recording: buffer.Recording = .{ .command_buffer = null, .pending_serial = 1 };
    const first = subject.trackUsageAndGetResourceBarrier(recording, copy_dst.toFlags(), .none);
    try std.testing.expectEqual(@as(vulkan.VkAccessFlags, 0), first.src_access_mask);
    const read = subject.trackUsageAndGetResourceBarrier(
        recording,
        buffer.internal_copy_src_buffer,
        .none,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT)),
        read.src_access_mask,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT)),
        read.dst_access_mask,
    );
    try std.testing.expectEqual(copy_dst.toFlags(), subject.last_write_usage);
    try std.testing.expect(subject.read_usage & buffer.internal_copy_src_buffer != 0);
    const write = subject.trackUsageAndGetResourceBarrier(recording, copy_dst.toFlags(), .none);
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, @intCast(vulkan.VK_ACCESS_TRANSFER_READ_BIT)),
        write.src_access_mask,
    );
    try std.testing.expectEqual(
        @as(vulkan.VkAccessFlags, @intCast(vulkan.VK_ACCESS_TRANSFER_WRITE_BIT)),
        write.dst_access_mask,
    );
}

test "internal buffers: every accepted engine bit creates an unmapped private allocation" {
    var fixture: Fixture = .{};
    fixture.init();
    inline for (.{
        copy_src.toFlags(),
        copy_dst.toFlags(),
        uniform.toFlags(),
        indirect.toFlags(),
        buffer.internal_storage_buffer,
        buffer.read_only_storage_buffer,
        buffer.internal_copy_src_buffer,
    }) |usage| {
        try acceptedEngineUsage(&fixture, usage);
    }
    try fixture.finish();
    try std.testing.expectEqual(@as(u32, 7), fixture.create_calls);
    try std.testing.expectEqual(@as(u32, 7), fixture.destroy_calls);
    try std.testing.expectEqual(@as(u32, 7), fixture.free_calls);
}

fn acceptedEngineUsage(fixture: *Fixture, usage: u32) !void {
    const subject = try buffer.Buffer.createInternal(std.testing.allocator, fixture.device(), .{
        .size = 0,
        .native_usage = usage,
    });
    defer fixture.destroy(subject);
    try std.testing.expectEqual(@as(u32, 0), subject.getUsage().toFlags());
    try std.testing.expectEqual(usage, subject.getInternalUsage());
    try std.testing.expectEqual(buffer.State.unmapped, subject.getState());
    try std.testing.expect(subject.mapped == null);
    try std.testing.expectEqual(@as(u64, 0), subject.getSize());
    const expected_size: u64 = if (usage == uniform.toFlags()) 16 else 4;
    try std.testing.expectEqual(expected_size, subject.getAllocatedSize());
    try std.testing.expectEqual(
        buffer.vulkanBufferUsage(usage | copy_dst.toFlags()),
        fixture.created_usage,
    );
}

test "internal buffers: host allocation refusal records no native creation" {
    var fixture: Fixture = .{};
    fixture.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, buffer.Buffer.createInternal(
        failing.allocator(),
        fixture.device(),
        .{ .size = 4, .native_usage = buffer.internal_storage_buffer },
    ));
    try std.testing.expectEqual(@as(u32, 0), fixture.create_calls);
    try fixture.finish();
}

test "internal buffers: missing creation procedure refuses without native ownership" {
    var fixture: Fixture = .{};
    fixture.init();
    fixture.procs.create_buffer = null;
    try std.testing.expectError(error.MissingDeviceProc, buffer.Buffer.createInternal(
        std.testing.allocator,
        fixture.device(),
        .{ .size = 4, .native_usage = buffer.internal_storage_buffer },
    ));
    try std.testing.expectEqual(@as(u32, 0), fixture.create_calls);
    try fixture.finish();
}

test "internal buffers: Indirect stages boundary records without public CopySrc" {
    var fixture: Fixture = .{};
    fixture.init();
    try indirectBoundaryRecord(&fixture);
    try fixture.finish();
    try std.testing.expectEqual(@as(u32, 1), fixture.copy_calls);
    try std.testing.expectEqual(@as(u64, 20), fixture.copied_size);
}

fn indirectBoundaryRecord(fixture: *Fixture) !void {
    const source = try buffer.Buffer.create(std.testing.allocator, fixture.device(), .{
        .size = 272,
        .usage = .{ .indirect = true },
    });
    defer fixture.destroy(source);
    try std.testing.expect(!source.getUsage().copy_src);
    try std.testing.expect(!source.getUsage().storage);
    try std.testing.expect(source.getInternalUsage() & buffer.internal_copy_src_buffer != 0);
    try std.testing.expect(source.getInternalUsage() & buffer.read_only_storage_buffer != 0);
    try std.testing.expect(fixture.created_usage & vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT != 0);
    const destination = try buffer.Buffer.createInternal(std.testing.allocator, fixture.device(), .{
        .size = 20,
        .native_usage = copy_dst.toFlags() | buffer.internal_storage_buffer,
    });
    defer fixture.destroy(destination);
    source.is_data_initialized = true;
    destination.is_data_initialized = true;
    const recording: buffer.Recording = .{
        .command_buffer = @ptrCast(fixture),
        .pending_serial = 1,
    };
    try std.testing.expectError(error.BufferUsageMissingCopySrc, destination.recordCopyBuffer(
        recording,
        source,
        252,
        0,
        20,
    ));
    try std.testing.expectEqual(@as(u32, 0), fixture.copy_calls);
    try destination.recordCopyBufferInternal(recording, source, 252, 0, 20);
    try std.testing.expectEqual(@as(u32, 0), source.last_write_usage);
    try std.testing.expect(source.read_usage & (copy_src.toFlags() | buffer.internal_copy_src_buffer) != 0);
    try std.testing.expect(!source.getUsage().copy_src);
    try std.testing.expectEqual(@as(u32, 0), destination.getUsage().toFlags());
}

const native_device_module = dusk.engine.vulkan_device;
const NativeTeardownError = buffer.Error || native_device_module.ProcError;

const NativeTeardowns = struct {
    first: ?NativeTeardownError = null,

    fn record(self: *NativeTeardowns, err: NativeTeardownError) void {
        if (self.first == null) self.first = err;
    }

    fn report(self: *const NativeTeardowns) !void {
        if (self.first) |err| return err;
    }
};

const NativeCreationFault = struct {
    original_create: vulkan.PFN_vkCreateBuffer,
    original_allocate: vulkan.PFN_vkAllocateMemory,
    refuse_create: bool = false,
    refuse_allocate: bool = false,
    created_usage: vulkan.VkBufferUsageFlags = 0,

    threadlocal var active: ?*NativeCreationFault = null;

    fn create(
        device_handle: vulkan.VkDevice,
        info: [*c]const vulkan.VkBufferCreateInfo,
        callbacks: [*c]const vulkan.VkAllocationCallbacks,
        output: [*c]vulkan.VkBuffer,
    ) callconv(.c) vulkan.VkResult {
        const self = active orelse unreachable;
        self.created_usage = info.*.usage;
        if (self.refuse_create) return vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        return self.original_create.?(device_handle, info, callbacks, output);
    }

    fn allocate(
        device_handle: vulkan.VkDevice,
        info: [*c]const vulkan.VkMemoryAllocateInfo,
        callbacks: [*c]const vulkan.VkAllocationCallbacks,
        output: [*c]vulkan.VkDeviceMemory,
    ) callconv(.c) vulkan.VkResult {
        const self = active orelse unreachable;
        if (self.refuse_allocate) return vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        return self.original_allocate.?(device_handle, info, callbacks, output);
    }
};

test "internal buffers: actual native creation preserves private permissions and fail-N ownership" {
    var teardowns: NativeTeardowns = .{};
    try actualNativeCreation(&teardowns);
    try teardowns.report();
}

fn actualNativeCreation(teardowns: *NativeTeardowns) !void {
    const allocator = std.testing.allocator;
    var handles: HandleSet = .{};
    var backend = native_device_module.Backend.init(allocator, .{ .handles = &handles });
    defer backend.deinit() catch |err| teardowns.record(err);
    var adapters = try backend.discoverPhysicalDevices(.{});
    defer adapters.deinit();
    const adapter = try adapters.first();
    var native_device = try native_device_module.Device.create(allocator, .{
        .instance = adapter.instance,
        .physical = &adapter.physical,
        .handles = &handles,
    });
    defer native_device.deinit(allocator) catch |err| teardowns.record(err);
    const original_procs = native_device.dispatchTable().device orelse
        return error.MissingDeviceProc;
    var fault: NativeCreationFault = .{
        .original_create = original_procs.create_buffer orelse return error.MissingDeviceProc,
        .original_allocate = original_procs.allocate_memory orelse return error.MissingDeviceProc,
    };
    std.debug.assert(NativeCreationFault.active == null);
    NativeCreationFault.active = &fault;
    defer NativeCreationFault.active = null;
    var local_procs = original_procs.*;
    local_procs.create_buffer = NativeCreationFault.create;
    local_procs.allocate_memory = NativeCreationFault.allocate;
    var buffers: buffer.Device = .{
        .allocator = allocator,
        .dispatch = native_device.dispatchTable(),
        .vk_device = native_device.vk_device,
        .physical_device = adapter.physical.handle,
        .memory_properties = native_device.memoryProperties(),
        .non_coherent_atom_size = native_device.physicalProperties().limits.nonCoherentAtomSize,
        .max_buffer_size = native_device.maxBufferSize(),
        .handles = &handles,
    };
    buffers.dispatch.device = &local_procs;
    const baseline = handles.totalCount();
    try std.testing.checkAllAllocationFailures(allocator, nativeAllocationCycle, .{buffers});
    try std.testing.expectEqual(baseline, handles.totalCount());
    const options: buffer.InternalBufferDescriptor = .{
        .size = 288,
        .native_usage = uniform.toFlags() | copy_dst.toFlags(),
    };
    fault.refuse_create = true;
    try std.testing.expectError(
        error.OutOfDeviceMemory,
        buffer.Buffer.createInternal(allocator, buffers, options),
    );
    try std.testing.expectEqual(baseline, handles.totalCount());
    fault.refuse_create = false;
    fault.refuse_allocate = true;
    try std.testing.expectError(
        error.OutOfDeviceMemory,
        buffer.Buffer.createInternal(allocator, buffers, options),
    );
    try std.testing.expectEqual(baseline, handles.totalCount());
    fault.refuse_allocate = false;
    try actualPrivatePermissions(buffers, &fault, teardowns);
    try std.testing.expectEqual(baseline, handles.totalCount());
}

fn nativeAllocationCycle(allocator: std.mem.Allocator, device: buffer.Device) !void {
    const subject = try buffer.Buffer.createInternal(allocator, device, .{
        .size = 288,
        .native_usage = uniform.toFlags() | copy_dst.toFlags(),
    });
    try subject.destroy(allocator);
}

fn actualPrivatePermissions(
    device: buffer.Device,
    fault: *NativeCreationFault,
    teardowns: *NativeTeardowns,
) !void {
    const allocator = std.testing.allocator;
    const scratch = try buffer.Buffer.createInternal(allocator, device, .{
        .size = 17,
        .native_usage = buffer.internal_storage_buffer | uniform.toFlags() | copy_dst.toFlags(),
    });
    defer scratch.destroy(allocator) catch |err| teardowns.record(err);
    try std.testing.expectEqual(@as(u32, 0), scratch.getUsage().toFlags());
    try std.testing.expectEqual(buffer.State.unmapped, scratch.getState());
    try std.testing.expectEqual(@as(u64, 32), scratch.getAllocatedSize());
    try std.testing.expect(scratch.mapped == null);
    try std.testing.expect(!scratch.is_data_initialized);
    const argument_buffer = try buffer.Buffer.create(allocator, device, .{
        .size = 272,
        .usage = .{ .indirect = true },
    });
    defer argument_buffer.destroy(allocator) catch |err| teardowns.record(err);
    try std.testing.expect(!argument_buffer.getUsage().storage);
    try std.testing.expect(!argument_buffer.getUsage().copy_src);
    try std.testing.expect(
        argument_buffer.getInternalUsage() & buffer.read_only_storage_buffer != 0,
    );
    try std.testing.expect(
        argument_buffer.getInternalUsage() & buffer.internal_copy_src_buffer != 0,
    );
    try std.testing.expect(fault.created_usage & vulkan.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT != 0);
    try std.testing.expect(fault.created_usage & vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT != 0);
    const preimage = try buffer.Buffer.create(allocator, device, .{
        .size = 16,
        .usage = .{ .copy_dst = true },
    });
    defer preimage.destroy(allocator) catch |err| teardowns.record(err);
    try std.testing.expect(!preimage.getUsage().storage);
    try std.testing.expect(!preimage.getUsage().copy_src);
    try std.testing.expect(preimage.getInternalUsage() & buffer.internal_copy_src_buffer != 0);
    try std.testing.expect(fault.created_usage & vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT != 0);
    try std.testing.expect(fault.created_usage & vulkan.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT == 0);
    try std.testing.expectError(error.BufferUsageEmpty, buffer.Buffer.create(
        allocator,
        device,
        .{ .size = 4, .usage = .none },
    ));
}
