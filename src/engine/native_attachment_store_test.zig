//! Exercises complete semantic attachment identity and original-arena retirement.
const std = @import("std");
const core = @import("../core/root.zig");
const api = @import("../api/api.zig");
const attachments = @import("../command/attachment_state.zig");
const ResourceStore = @import("native_resource_store.zig").ResourceStore;
const factory = @import("native_attachment_store.zig");

fn colorValue() attachments.AttachmentState {
    var value: attachments.AttachmentState = .{};
    value.color_attachments_set = 1;
    value.color_formats[0] = @intFromEnum(api.TextureFormat.rgba8_unorm);
    return value;
}

test "native attachment aliases compare complete metadata and prune before last release" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(gpa, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
    defer guard.unlock(io);
    defer arena.deinit(gpa, &guard) catch unreachable;
    var store = ResourceStore.init(gpa, arena.objectList());
    defer store.deinit(&guard);
    const value = colorValue();
    const first = try factory.create(gpa, io, &guard, &arena, &store, value);
    const alias = try factory.create(gpa, io, &guard, &arena, &store, value);
    try std.testing.expect(first == alias);
    var changed = value;
    changed.sample_count = 4;
    const multisampled = try factory.create(gpa, io, &guard, &arena, &store, changed);
    try std.testing.expect(multisampled != first);
    changed.expand_resolve = .{ .attachments_to_expand_resolve = 1, .resolve_targets_mask = 1 };
    const expanded = try factory.create(gpa, io, &guard, &arena, &store, changed);
    try std.testing.expect(expanded != multisampled);
    changed = value;
    changed.color_formats[0] = @intFromEnum(api.TextureFormat.bgra8_unorm);
    const other_color = try factory.create(gpa, io, &guard, &arena, &store, changed);
    try std.testing.expect(other_color != first);
    changed = value;
    changed.depth_stencil_format = @intFromEnum(api.TextureFormat.depth32_float);
    const depth = try factory.create(gpa, io, &guard, &arena, &store, changed);
    try std.testing.expect(depth != first);
    changed = value;
    changed.color_attachments_set = 2;
    changed.color_formats = @splat(0);
    changed.color_formats[1] = @intFromEnum(api.TextureFormat.rgba8_unorm);
    const hole = try factory.create(gpa, io, &guard, &arena, &store, changed);
    try std.testing.expect(hole != first);
    changed = value;
    changed.has_pls = true;
    changed.storage_attachment_slot_count = 1;
    changed.storage_attachment_slots[0] = @intFromEnum(api.TextureFormat.r32_uint);
    const storage = try factory.create(gpa, io, &guard, &arena, &store, changed);
    try std.testing.expect(storage != first);
    first.header.retirePayloadLocked(&guard, io, .early_destroy);
    const fresh = try factory.create(gpa, io, &guard, &arena, &store, value);
    try std.testing.expect(fresh != first);
    try first.header.releaseUserLocked(&guard, io);
    try alias.header.releaseUserLocked(&guard, io);
    try fresh.header.releaseUserLocked(&guard, io);
    try multisampled.header.releaseUserLocked(&guard, io);
    try depth.header.releaseUserLocked(&guard, io);
    try hole.header.releaseUserLocked(&guard, io);
    try storage.header.releaseUserLocked(&guard, io);
    try expanded.header.releaseUserLocked(&guard, io);
    try other_color.header.releaseUserLocked(&guard, io);
    try std.testing.expect(store.attachments.isEmpty(&guard));
}

test "native attachment final insertion allocation failures leave no membership" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var succeeded = false;
    for (0..32) |failure_index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = failure_index });
        const allocator = failing.allocator();
        var mutex: std.Io.Mutex = .init;
        var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &mutex });
        var guard = core.ObjectGuard.lockUncancelable(io, arena.objectList());
        defer guard.unlock(io);
        defer arena.deinit(allocator, &guard) catch unreachable;
        var store = ResourceStore.init(allocator, arena.objectList());
        defer store.deinit(&guard);
        const object = factory.create(allocator, io, &guard, &arena, &store, colorValue()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(store.attachments.isEmpty(&guard));
            continue;
        };
        try object.header.releaseUserLocked(&guard, io);
        try std.testing.expect(store.attachments.isEmpty(&guard));
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
}
