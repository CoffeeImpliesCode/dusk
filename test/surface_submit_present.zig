const std = @import("std");
const vulkan = @import("vulkan");
const sc = @import("dusk").engine.swapchain;

fn fixture() sc.Native {
    var native: sc.Native = .{
        .backend = .{ .device = null, .queue = null, .procs = &procs, .swapchain_available = true },
        .handle = null,
        .generation = 4,
        .format = vulkan.VK_FORMAT_B8G8R8A8_UNORM,
        .image_usage = vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .extent = .{ .width = 64, .height = 64 },
        .present_mode = vulkan.VK_PRESENT_MODE_FIFO_KHR,
        .queue_family_index = 0,
        .acquire_semaphore = @ptrFromInt(16),
        .image_count = 2,
    };
    native.slots[0] = .{ .image = @ptrFromInt(32), .present_semaphore = @ptrFromInt(48), .state = .{ .acquired = 1 } };
    native.slots[1] = .{ .image = @ptrFromInt(64), .present_semaphore = @ptrFromInt(80) };
    native.acquire_epoch = 1;
    native.current_index = 0;
    return native;
}
const procs = blk: {
    var p = std.mem.zeroes(@import("dusk").vk.dispatch.DeviceProcs);
    p.create_swapchain_khr = Fake.createSwapchain;
    p.destroy_swapchain_khr = Fake.destroySwapchain;
    p.get_swapchain_images_khr = Fake.getImages;
    p.create_semaphore = Fake.createSemaphore;
    p.destroy_semaphore = Fake.destroySemaphore;
    p.acquire_next_image_khr = Fake.acquire;
    p.queue_present_khr = Fake.present;
    p.queue_wait_idle = Fake.idle;
    p.queue_submit = Fake.submit;
    break :blk p;
};

test "failed submit rollback preserves acquire semaphore and epoch" {
    var native = fixture();
    const stage = try native.stageSubmit(.{ .generation = 4, .index = 0, .acquire_epoch = 1 });
    try std.testing.expectEqual(native.acquire_semaphore, stage.wait.?);
    native.rollbackSubmit(stage);
    try std.testing.expectEqual(@as(u64, 1), native.slots[0].state.acquired);
    try std.testing.expectEqual(@as(u64, 0), native.acquire_consumed_serial);
}

test "accepted submit consumes acquire once and records owner serial" {
    var native = fixture();
    const token: sc.Token = .{ .generation = 4, .index = 0, .acquire_epoch = 1 };
    const stage = try native.stageSubmit(token);
    native.commitSubmit(stage, 7);
    try std.testing.expectEqual(@as(u64, 7), native.acquire_consumed_serial);
    const next = try native.stageSubmit(token);
    try std.testing.expectEqual(native.slots[0].present_semaphore, next.wait.?);
    native.rollbackSubmit(next);
    try std.testing.expectEqual(@as(u64, 7), native.slots[0].state.submit_accepted.serial);
}

test "generation and epoch reject stale borrowed image before submission" {
    var native = fixture();
    try std.testing.expectError(error.StaleSurfaceTexture, native.stageSubmit(.{ .generation = 3, .index = 0, .acquire_epoch = 1 }));
    try std.testing.expectError(error.StaleSurfaceTexture, native.stageSubmit(.{ .generation = 4, .index = 0, .acquire_epoch = 2 }));
    try std.testing.expectError(error.StaleSurfaceTexture, native.stageSubmit(.{ .generation = 4, .index = 8, .acquire_epoch = 1 }));
}

test "acquire epoch exhaustion precedes native acquisition" {
    var native = fixture();
    native.current_index = null;
    native.acquire_epoch = std.math.maxInt(u64);
    try std.testing.expectError(error.AcquireEpochExhausted, native.acquire(1, 0));
}

test "acquire semaphore cannot be reused before accepted serial completes" {
    var native = fixture();
    native.current_index = null;
    native.acquire_consumed_serial = 9;
    try std.testing.expectError(error.AcquireSemaphoreInUse, native.acquire(1, 8));
}

const Fake = struct {
    var serial: u64 = 0;
    var submit_count: usize = 0;
    var present_count: usize = 0;
    var destroyed_semaphores: usize = 0;
    var destroyed_swapchains: usize = 0;
    var next_semaphore: usize = 128;
    var submit_result: vulkan.VkResult = vulkan.VK_SUCCESS;
    var present_result: vulkan.VkResult = vulkan.VK_SUCCESS;
    var acquire_result: vulkan.VkResult = vulkan.VK_SUCCESS;
    var acquire_count: usize = 0;
    var image_count: u32 = 2;
    var semaphore_fail_at: usize = 0;
    var semaphore_calls: usize = 0;

    fn reset() void {
        serial = 0;
        submit_count = 0;
        present_count = 0;
        destroyed_semaphores = 0;
        destroyed_swapchains = 0;
        next_semaphore = 128;
        submit_result = vulkan.VK_SUCCESS;
        present_result = vulkan.VK_SUCCESS;
        acquire_result = vulkan.VK_SUCCESS;
        acquire_count = 0;
        image_count = 2;
        semaphore_fail_at = 0;
        semaphore_calls = 0;
    }
    fn createSwapchain(_: vulkan.VkDevice, _: [*c]const vulkan.VkSwapchainCreateInfoKHR, _: [*c]const vulkan.VkAllocationCallbacks, out: [*c]vulkan.VkSwapchainKHR) callconv(.c) vulkan.VkResult {
        out[0] = @ptrFromInt(96);
        return vulkan.VK_SUCCESS;
    }
    fn destroySwapchain(_: vulkan.VkDevice, _: vulkan.VkSwapchainKHR, _: [*c]const vulkan.VkAllocationCallbacks) callconv(.c) void {
        destroyed_swapchains += 1;
    }
    fn getImages(_: vulkan.VkDevice, _: vulkan.VkSwapchainKHR, count: [*c]u32, images: [*c]vulkan.VkImage) callconv(.c) vulkan.VkResult {
        if (images != null) {
            const capacity = count[0];
            for (0..@min(capacity, image_count)) |i| images[i] = @ptrFromInt(256 + i * 16);
        }
        count[0] = image_count;
        return vulkan.VK_SUCCESS;
    }
    fn createSemaphore(_: vulkan.VkDevice, _: [*c]const vulkan.VkSemaphoreCreateInfo, _: [*c]const vulkan.VkAllocationCallbacks, out: [*c]vulkan.VkSemaphore) callconv(.c) vulkan.VkResult {
        semaphore_calls += 1;
        if (semaphore_fail_at == semaphore_calls) return vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        out[0] = @ptrFromInt(next_semaphore);
        next_semaphore += 16;
        return vulkan.VK_SUCCESS;
    }
    fn destroySemaphore(_: vulkan.VkDevice, _: vulkan.VkSemaphore, _: [*c]const vulkan.VkAllocationCallbacks) callconv(.c) void {
        destroyed_semaphores += 1;
    }
    fn acquire(_: vulkan.VkDevice, _: vulkan.VkSwapchainKHR, _: u64, _: vulkan.VkSemaphore, _: vulkan.VkFence, index: [*c]u32) callconv(.c) vulkan.VkResult {
        acquire_count += 1;
        index[0] = 0;
        return acquire_result;
    }
    fn submit(_: vulkan.VkQueue, count: u32, info: [*c]const vulkan.VkSubmitInfo, _: vulkan.VkFence) callconv(.c) vulkan.VkResult {
        std.debug.assert(count == 1 and info[0].commandBufferCount == 0);
        std.debug.assert(info[0].waitSemaphoreCount == 1 and info[0].signalSemaphoreCount == 1);
        submit_count += 1;
        return submit_result;
    }
    fn acceptedSubmit(_: *anyopaque, _: std.Io, info: *const vulkan.VkSubmitInfo) sc.BridgeSubmitError!u64 {
        try @import("dusk").vk.dispatch.checkVkSuccess(procs.queue_submit.?(null, 1, info, null));
        serial += 1;
        return serial;
    }
    fn present(_: vulkan.VkQueue, info: [*c]const vulkan.VkPresentInfoKHR) callconv(.c) vulkan.VkResult {
        std.debug.assert(info[0].waitSemaphoreCount == 1 and info[0].swapchainCount == 1);
        present_count += 1;
        return present_result;
    }
    fn idle(_: vulkan.VkQueue) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }
};

fn owner(context: *u8) sc.SerialOwner {
    return .{ .context = context, .submit_fn = Fake.acceptedSubmit };
}

test "present without draw bridges actual submit before native presentation" {
    Fake.reset();
    var context: u8 = 0;
    var native = fixture();
    try std.testing.expectEqual(sc.PresentResult.success, try native.present(std.testing.io, owner(&context)));
    try std.testing.expectEqual(@as(usize, 1), Fake.submit_count);
    try std.testing.expectEqual(@as(usize, 1), Fake.present_count);
    try std.testing.expectEqual(@as(u64, 1), native.slots[0].state.present_accepted.serial);
    try std.testing.expectEqual(@as(?u32, null), native.current_index);
}

test "bridge failure preserves acquired image and central serial" {
    Fake.reset();
    Fake.submit_result = vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    var context: u8 = 0;
    var native = fixture();
    try std.testing.expectError(error.OutOfDeviceMemory, native.present(std.testing.io, owner(&context)));
    try std.testing.expectEqual(@as(usize, 0), Fake.present_count);
    try std.testing.expectEqual(@as(u64, 0), Fake.serial);
    try std.testing.expectEqual(@as(u64, 1), native.slots[0].state.acquired);
    try std.testing.expect(!native.slots[0].staged);
}

test "native out of date presentation retires generation without fake acceptance" {
    Fake.reset();
    Fake.present_result = vulkan.VK_ERROR_OUT_OF_DATE_KHR;
    var context: u8 = 0;
    var native = fixture();
    try std.testing.expectEqual(sc.PresentResult.outdated, try native.present(std.testing.io, owner(&context)));
    try std.testing.expect(native.stale);
    try std.testing.expect(native.slots[0].state == .stale);
    try native.drain();
    try std.testing.expect(native.drained);
}

fn createInfo() vulkan.VkSwapchainCreateInfoKHR {
    return .{
        .sType = vulkan.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .minImageCount = 2,
        .imageFormat = vulkan.VK_FORMAT_B8G8R8A8_UNORM,
        .imageExtent = .{ .width = 64, .height = 64 },
        .imageArrayLayers = 1,
        .imageUsage = vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE,
        .presentMode = vulkan.VK_PRESENT_MODE_FIFO_KHR,
    };
}

test "each semaphore allocation failure destroys only created resources" {
    for (1..4) |fail_at| {
        Fake.reset();
        Fake.semaphore_fail_at = fail_at;
        const info = createInfo();
        var accepted = false;
        try std.testing.expectError(error.OutOfDeviceMemory, sc.Native.create(.{ .device = null, .queue = null, .procs = &procs, .swapchain_available = true }, &info, 1, 0, &accepted));
        try std.testing.expect(accepted);
        try std.testing.expectEqual(fail_at - 1, Fake.destroyed_semaphores);
        try std.testing.expectEqual(@as(usize, 1), Fake.destroyed_swapchains);
    }
}

test "bounded image count rejects driver excess and destroys swapchain" {
    Fake.reset();
    Fake.image_count = 9;
    const info = createInfo();
    var accepted = false;
    try std.testing.expectError(error.SwapchainImageCapacityExceeded, sc.Native.create(.{ .device = null, .queue = null, .procs = &procs, .swapchain_available = true }, &info, 1, 0, &accepted));
    try std.testing.expect(accepted);
    try std.testing.expectEqual(@as(usize, 1), Fake.destroyed_swapchains);
    try std.testing.expectEqual(@as(usize, 0), Fake.semaphore_calls);
}

test "successful native lifecycle destroys semaphores and swapchain not borrowed images" {
    Fake.reset();
    const info = createInfo();
    var accepted = false;
    var native = try sc.Native.create(.{ .device = null, .queue = null, .procs = &procs, .swapchain_available = true }, &info, 1, 0, &accepted);
    try std.testing.expect(accepted);
    const acquired = try native.acquire(1000, 0);
    try std.testing.expectEqual(@as(u64, 1), acquired.success.acquire_epoch);
    var context: u8 = 0;
    _ = try native.present(std.testing.io, owner(&context));
    try native.drain();
    native.deinit();
    try std.testing.expectEqual(@as(usize, 3), Fake.destroyed_semaphores);
    try std.testing.expectEqual(@as(usize, 1), Fake.destroyed_swapchains);
}

test "generation overflow rejects rather than aliases old textures" {
    try std.testing.expectError(error.SwapchainGenerationExhausted, sc.nextGeneration(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 5), try sc.nextGeneration(4));
}

test "missing central capability never reaches native create" {
    Fake.reset();
    const info = createInfo();
    var accepted = true;
    try std.testing.expectError(error.SwapchainUnavailable, sc.Native.create(.{ .device = null, .queue = null, .procs = &procs, .swapchain_available = false }, &info, 1, 0, &accepted));
    try std.testing.expect(!accepted);
    try std.testing.expectEqual(@as(usize, 0), Fake.destroyed_swapchains);
}

test "present uses accepted user submit serial without another bridge" {
    Fake.reset();
    var context: u8 = 0;
    var native = fixture();
    const stage = try native.stageSubmit(try native.currentToken());
    native.commitSubmit(stage, 15);
    _ = try native.present(std.testing.io, owner(&context));
    try std.testing.expectEqual(@as(usize, 0), Fake.submit_count);
    try std.testing.expectEqual(@as(u64, 15), native.slots[0].state.present_accepted.serial);
}

test "native acquisition timeout preserves epoch and leaves no current image" {
    Fake.reset();
    Fake.acquire_result = vulkan.VK_TIMEOUT;
    var native = fixture();
    native.current_index = null;
    const result = try native.acquire(1000, 0);
    try std.testing.expect(result == .timeout);
    try std.testing.expectEqual(@as(u64, 1), native.acquire_epoch);
    try std.testing.expectEqual(@as(?u32, null), native.current_index);
}

test "suboptimal present records actual acceptance and requires replacement" {
    Fake.reset();
    Fake.present_result = vulkan.VK_SUBOPTIMAL_KHR;
    var context: u8 = 0;
    var native = fixture();
    try std.testing.expectEqual(sc.PresentResult.suboptimal, try native.present(std.testing.io, owner(&context)));
    try std.testing.expect(native.reconfigure_needed);
    try std.testing.expect(!native.stale);
    try std.testing.expectEqual(vulkan.VK_SUBOPTIMAL_KHR, native.slots[0].state.present_accepted.result);
}

test "suboptimal acquire permits genuine image use while requesting reconfigure" {
    Fake.reset();
    Fake.acquire_result = vulkan.VK_SUBOPTIMAL_KHR;
    var native = fixture();
    native.current_index = null;
    const acquired = try native.acquire(1000, 0);
    try std.testing.expect(acquired == .suboptimal);
    try std.testing.expect(native.reconfigure_needed);
    try std.testing.expect(!native.stale);
    const stage = try native.stageSubmit(acquired.suboptimal);
    native.rollbackSubmit(stage);
}

test "native device loss acquisition reports terminal lost generation" {
    Fake.reset();
    Fake.acquire_result = vulkan.VK_ERROR_DEVICE_LOST;
    var native = fixture();
    native.current_index = null;
    const acquired = try native.acquire(1000, 0);
    try std.testing.expect(acquired == .lost);
    try std.testing.expect(native.stale);
    try std.testing.expect(native.device_lost);
    try std.testing.expect(native.drained);
}

test "reacquisition preserves image content state shared by aliases" {
    Fake.reset();
    var context: u8 = 0;
    var native = fixture();
    native.slots[0].initialized[0] = true;
    _ = try native.present(std.testing.io, owner(&context));
    const result = try native.acquire(1000, Fake.serial);
    try std.testing.expect(result == .success);
    try std.testing.expect(native.slots[0].initialized[0]);
}

test "repeated acquire keeps the exact suboptimal epoch without native reacquire" {
    Fake.reset();
    Fake.acquire_result = vulkan.VK_SUBOPTIMAL_KHR;
    var native = fixture();
    native.current_index = null;
    const first = try native.acquire(1000, 0);
    const repeated = try native.acquire(1000, 0);
    try std.testing.expect(first == .suboptimal);
    try std.testing.expect(repeated == .suboptimal);
    try std.testing.expectEqual(first.suboptimal.acquire_epoch, repeated.suboptimal.acquire_epoch);
    try std.testing.expectEqual(@as(usize, 1), Fake.acquire_count);
}

test "native usage retains exact accepted swapchain create usage" {
    Fake.reset();
    var info = createInfo();
    info.imageUsage = vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    var accepted = false;
    var native = try sc.Native.create(.{ .device = null, .queue = null, .procs = &procs, .swapchain_available = true }, &info, 1, 0, &accepted);
    defer native.deinit();
    try std.testing.expectEqual(info.imageUsage, native.image_usage);
}
