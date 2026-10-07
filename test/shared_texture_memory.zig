const std = @import("std");
const dusk = @import("dusk");
const shared = dusk.engine.shared_texture_memory;
const api = dusk.api;
const vk = dusk.platform.vulkan_bindings;

test "begin rejects mismatched counts before ownership mutation" {
    const descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = false, .initialized = false, .fence_count = 1,
        .signaled_value_count = 0,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    };
    try std.testing.expectError(error.InvalidFenceCount, shared.validateBeginDescriptor(&descriptor));
}

test "begin rejects concurrent reading even without fences" {
    const descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = true, .initialized = true, .fence_count = 0,
    };
    try std.testing.expectError(error.ConcurrentReadUnsupported, shared.validateBeginDescriptor(&descriptor));
}

test "begin requires Vulkan layout and rejects foreign descriptor arms" {
    var descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = false, .initialized = false, .fence_count = 0,
    };
    try std.testing.expectError(error.UnsupportedImageLayout, shared.validateBeginDescriptor(&descriptor));
    descriptor.shared_texture_memory_vk_image_layout_begin_state = .{
        .old_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
    };
    try shared.validateBeginDescriptor(&descriptor);
    descriptor.shared_texture_memory_d3d11_begin_state = .{};
    try std.testing.expectError(error.UnsupportedImageLayout, shared.validateBeginDescriptor(&descriptor));
}

test "begin rejects more than eight waits without reading caller pointers" {
    const descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = false, .initialized = false, .fence_count = 9,
        .signaled_value_count = 9,
    };
    try std.testing.expectError(error.InvalidFenceCount, shared.validateBeginDescriptor(&descriptor));
}

test "undefined layout is allowed only for uninitialized acquire source" {
    try std.testing.expect(shared.supportedLayout(vk.VK_IMAGE_LAYOUT_UNDEFINED, true));
    try std.testing.expect(!shared.supportedLayout(vk.VK_IMAGE_LAYOUT_UNDEFINED, false));
    try std.testing.expect(!shared.supportedLayout(vk.VK_IMAGE_LAYOUT_PREINITIALIZED, false));
}

test "begin rejects nonbinary wait values before resolving handles" {
    var marker: u64 = 0;
    const fences = [_]api.objects.SharedFence{.{ .handle = @ptrCast(&marker) }};
    const values = [_]u64{2};
    const descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = false, .initialized = false, .fence_count = 1,
        .fences = &fences, .signaled_value_count = 1, .signaled_values = &values,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    };
    try std.testing.expectError(error.InvalidFenceValue, shared.validateBeginDescriptor(&descriptor));
    try std.testing.expectEqual(@as(u64, 0), marker);
}

test "begin rejects duplicate binary waits before resolving handles" {
    var marker: u64 = 0;
    const fence: api.objects.SharedFence = .{ .handle = @ptrCast(&marker) };
    const fences = [_]api.objects.SharedFence{ fence, fence };
    const values = [_]u64{ 1, 1 };
    const descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = false, .initialized = true, .fence_count = 2,
        .fences = &fences, .signaled_value_count = 2, .signaled_values = &values,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    };
    try std.testing.expectError(error.InvalidFenceCount, shared.validateBeginDescriptor(&descriptor));
}

test "initialized access cannot acquire undefined contents" {
    const descriptor: api.descriptors.SharedTextureMemoryBeginAccessDescriptorChain = .{
        .concurrent_read = false, .initialized = true, .fence_count = 0,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    };
    try std.testing.expectError(error.UnsupportedImageLayout, shared.validateBeginDescriptor(&descriptor));
}

test "recording requires the exact active texture header and epoch" {
    var first: dusk.core.Object = undefined;
    var alias: dusk.core.Object = undefined;
    const access: shared.Access = .{ .begun = .{
        .texture_header = &first, .acquire_epoch = 7, .fence_count = 0,
        .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL, .initialized = true,
    } };
    try shared.validateAccess(&access, &first, 7);
    try std.testing.expectError(error.TextureProvenanceMismatch,
        shared.validateAccess(&access, &alias, 7));
    try std.testing.expectError(error.TextureProvenanceMismatch,
        shared.validateAccess(&access, &first, 6));
    try std.testing.expectEqual(@as(u64, 7), access.begun.acquire_epoch);
}

test "recording rejects idle shared backing without changing it" {
    var texture: dusk.core.Object = undefined;
    const access: shared.Access = .idle;
    try std.testing.expectError(error.SharedMemoryAccessNotBegun,
        shared.validateAccess(&access, &texture, 1));
    try std.testing.expect(access == .idle);
}

test "shared texture descriptor cannot widen imported usage or change extent" {
    var imported: shared.ImportedImage = undefined;
    imported.properties = .{
        .usage = .{ .copy_src = true, .copy_dst = true },
        .size = .{ .width = 4, .height = 8, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
    };
    imported.mip_levels = 1;
    imported.sample_count = 1;
    var descriptor: api.descriptors.TextureDescriptorChain = .{
        .usage = .{ .copy_src = true },
        .size = imported.properties.size, .format = .rgba8_unorm,
    };
    try shared.validateTextureDescriptor(&imported, &descriptor);
    descriptor.usage = .{ .render_attachment = true };
    try std.testing.expectError(error.UnsupportedTextureUsage,
        shared.validateTextureDescriptor(&imported, &descriptor));
    descriptor.usage = .{ .copy_src = true };
    descriptor.size.width = 5;
    try std.testing.expectError(error.UnsupportedTextureExtent,
        shared.validateTextureDescriptor(&imported, &descriptor));
}

test "accepted release state forbids recording and preserves its export retry receipt" {
    var texture: dusk.core.Object = undefined;
    var fence: dusk.engine.shared_fence.SharedFence = undefined;
    const access: shared.Access = .{ .end_accepted = .{
        .texture_header = &texture, .acquire_epoch = 9, .fence = &fence,
        .serial = 31, .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .end_layout = vk.VK_IMAGE_LAYOUT_GENERAL, .initialized = false,
    } };
    try std.testing.expectError(error.SharedMemoryAccessNotBegun,
        shared.validateAccess(&access, &texture, 9));
    try std.testing.expectEqual(@as(u64, 31), access.end_accepted.serial);
    try std.testing.expect(access.end_accepted.fence == &fence);
    try std.testing.expect(!access.end_accepted.initialized);
}

test "authoritative shared subresource count includes every mip layer and aspect" {
    var imported: shared.ImportedImage = undefined;
    imported.mip_levels = 3;
    imported.array_layers = 2;
    imported.aspect_mask = vk.VK_IMAGE_ASPECT_DEPTH_BIT | vk.VK_IMAGE_ASPECT_STENCIL_BIT;
    try std.testing.expectEqual(@as(usize, 12), try shared.subresourceCount(&imported));
    imported.aspect_mask = 0;
    try std.testing.expectError(error.UnsupportedTextureExtent, shared.subresourceCount(&imported));
}

test "authoritative shared subresource size rejects arithmetic overflow" {
    var imported: shared.ImportedImage = undefined;
    imported.mip_levels = std.math.maxInt(u32);
    imported.array_layers = std.math.maxInt(u32);
    imported.aspect_mask = vk.VK_IMAGE_ASPECT_DEPTH_BIT | vk.VK_IMAGE_ASPECT_STENCIL_BIT;
    try std.testing.expectError(error.UnsupportedTextureExtent, shared.subresourceCount(&imported));
}
