//! Stable storage for the native backend and its borrowed handle ledger.
//! Instance allocates this owner once and releases it after all child lists/devices.
const std = @import("std");
const native = @import("vulkan_device.zig");

pub const NativeInstanceContext = struct {
    handles: native.HandleSet = .{},
    backend: native.Backend,

    /// Initializes only at the final heap address; backend borrows `handles`.
    pub fn init(self: *NativeInstanceContext, allocator: std.mem.Allocator) void {
        self.handles = .{};
        self.backend = native.Backend.init(allocator, .{ .handles = &self.handles });
    }
    /// Releases physical caches and loader instances in backend dependency order.
    pub fn deinit(self: *NativeInstanceContext) native.ProcError!void {
        try self.backend.deinit();
    }
};
