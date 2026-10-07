//! Canonical semantic attachments in the existing device arena.
//! The weak root owns no references and removes membership before payload retirement.
const std = @import("std");
const core = @import("../core/root.zig");
const attachments = @import("../command/attachment_state.zig");
const resource_store = @import("native_resource_store.zig");

pub const Error = core.CreateError || core.ReferenceError ||
    attachments.AttachmentError || error{ ResourceDestroyed, ResourceDeviceMismatch };

/// Returns one actual user alias under the original guard. The value is copied once on misses.
/// Allocator/index failure publishes no membership and consumes all temporary references.
pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    store: *resource_store.ResourceStore,
    value: attachments.AttachmentState,
) Error!*attachments.CanonicalAttachmentState {
    try arena.checkAllocator(guard, allocator);
    if (store.objects != arena.objectList()) return error.ResourceDeviceMismatch;
    guard.assertOwns(store.objects);
    if (store.objects.marked_destroyed) return error.ResourceDestroyed;
    try value.validateCanonical();
    const hash = value.computeContentHash();
    if (store.attachments.find(guard, hash, value, resource_store.attachmentMatches)) |existing| {
        try existing.header.acquireUserLocked(guard);
        return existing;
    }
    const object = try arena.create(allocator, guard, attachments.CanonicalAttachmentState, .{
        .kind = .attachment_state,
        .initial_reference = .user,
    });
    object.value = value;
    object.cache_hash = 0;
    object.cache_next = null;
    object.header.attach(guard, io);
    errdefer object.header.releaseUserLocked(guard, io) catch unreachable;
    try store.attachments.insert(guard, object, hash);
    return object;
}
