const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../src/vk/dispatch.zig");
const external = @import("../src/platform/external_semaphore.zig");

var imported_fd: c_int = -2;
var import_result: vulkan.VkResult = vulkan.VK_SUCCESS;
var creates: usize = 0;
var destroys: usize = 0;
var output_fd: c_int = -1;
var queried_type: vulkan.VkExternalSemaphoreHandleTypeFlagBits = 0;
var support_bits: vulkan.VkExternalSemaphoreFeatureFlags = 0;
var imported_export_bits: vulkan.VkExternalSemaphoreHandleTypeFlags = 0;

fn query(_: vulkan.VkPhysicalDevice, info: [*c]const vulkan.VkPhysicalDeviceExternalSemaphoreInfo, out: [*c]vulkan.VkExternalSemaphoreProperties) callconv(.c) void {
    queried_type = info.*.handleType;
    out.*.externalSemaphoreFeatures = support_bits;
    out.*.compatibleHandleTypes = info.*.handleType;
    out.*.exportFromImportedHandleTypes = imported_export_bits;
}
fn create(_: vulkan.VkDevice, _: [*c]const vulkan.VkSemaphoreCreateInfo, _: [*c]const vulkan.VkAllocationCallbacks, out: [*c]vulkan.VkSemaphore) callconv(.c) vulkan.VkResult {
    creates += 1;
    out.* = @ptrFromInt(0x1000);
    return vulkan.VK_SUCCESS;
}
fn destroy(_: vulkan.VkDevice, _: vulkan.VkSemaphore, _: [*c]const vulkan.VkAllocationCallbacks) callconv(.c) void {
    destroys += 1;
}
fn importFd(_: vulkan.VkDevice, info: [*c]const vulkan.VkImportSemaphoreFdInfoKHR) callconv(.c) vulkan.VkResult {
    imported_fd = info.*.fd;
    if (import_result == vulkan.VK_SUCCESS and imported_fd >= 0) external.closeHandle(std.testing.io, imported_fd);
    return import_result;
}
fn exportFd(_: vulkan.VkDevice, _: [*c]const vulkan.VkSemaphoreGetFdInfoKHR, out: [*c]c_int) callconv(.c) vulkan.VkResult {
    out.* = output_fd;
    return vulkan.VK_SUCCESS;
}
fn deviceProcs() dispatch.DeviceProcs {
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_semaphore = create;
    procs.destroy_semaphore = destroy;
    procs.import_semaphore_fd_khr = importFd;
    procs.get_semaphore_fd_khr = exportFd;
    return procs;
}
fn service(procs: *const dispatch.DeviceProcs, kind: external.HandleType) external.Service {
    return .{ .device = null, .procs = procs, .handle_type = kind, .supported = true };
}
fn reset() void {
    imported_fd = -2;
    import_result = vulkan.VK_SUCCESS;
    creates = 0;
    destroys = 0;
}

test "SyncFD minus one reaches actual Vulkan import and no FD syscall" {
    reset();
    const procs = deviceProcs();
    const native = try external.Service.importSemaphore(std.testing.io, service(&procs, .sync_fd), -1);
    defer destroy(null, native, null);
    try std.testing.expectEqual(@as(c_int, -1), imported_fd);
    try std.testing.expectEqual(@as(usize, 1), creates);
}

test "OpaqueFD minus one is refused before native creation" {
    reset();
    const procs = deviceProcs();
    try std.testing.expectError(error.InvalidSemaphoreHandle, external.Service.importSemaphore(std.testing.io, service(&procs, .opaque_fd), -1));
    try std.testing.expectEqual(@as(usize, 0), creates);
}

test "successful Vulkan import consumes duplicate only and preserves caller FD" {
    reset();
    const procs = deviceProcs();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "caller", .{});
    defer file.close(std.testing.io);
    const native = try external.Service.importSemaphore(std.testing.io, service(&procs, .opaque_fd), file.handle);
    defer destroy(null, native, null);
    try std.testing.expect(imported_fd != file.handle);
    _ = try file.stat(std.testing.io);
}

test "failed Vulkan import destroys semaphore and preserves caller FD" {
    reset();
    import_result = vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    const procs = deviceProcs();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "caller", .{});
    defer file.close(std.testing.io);
    try std.testing.expectError(error.OutOfDeviceMemory, external.Service.importSemaphore(std.testing.io, service(&procs, .opaque_fd), file.handle));
    try std.testing.expectEqual(@as(usize, 1), destroys);
    _ = try file.stat(std.testing.io);
}

test "export returns actual caller owned FD without closing it" {
    const procs = deviceProcs();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "export", .{});
    defer file.close(std.testing.io);
    output_fd = try external.duplicateHandle(file.handle);
    const actual = try service(&procs, .opaque_fd).exportSemaphore(@ptrFromInt(0x1000));
    defer external.closeHandle(std.testing.io, actual);
    try std.testing.expectEqual(output_fd, actual);
    _ = try external.fileFromDescriptor(actual).stat(std.testing.io);
}

test "support queries exact type and requires both importable and exportable" {
    var procs = std.mem.zeroes(dispatch.InstanceProcs);
    procs.get_physical_device_external_semaphore_properties = query;
    const options: external.SupportOptions = .{ .physical_device = null, .instance_procs = &procs, .enabled_extensions = (dispatch.EnabledDeviceExts{}).with(.external_semaphore_fd), .handle_type = .sync_fd };
    support_bits = vulkan.VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT;
    try std.testing.expect(!external.checkSupport(options));
    support_bits |= vulkan.VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT;
    try std.testing.expect(external.checkSupport(options));
    try std.testing.expectEqual(external.HandleType.sync_fd.vkHandleType(), queried_type);
}

test "missing import proc causes no native allocation" {
    reset();
    var procs = deviceProcs();
    procs.import_semaphore_fd_khr = null;
    try std.testing.expectError(error.MissingDeviceProc, external.Service.importSemaphore(std.testing.io, service(&procs, .sync_fd), -1));
    try std.testing.expectEqual(@as(usize, 0), creates);
}

test "authorized service reports exact imported export property separately" {
    var instance = std.mem.zeroes(dispatch.InstanceProcs);
    instance.get_physical_device_external_semaphore_properties = query;
    const device = deviceProcs();
    const options: external.InitOptions = .{
        .device = null,
        .device_procs = &device,
        .support = .{
            .physical_device = null,
            .instance_procs = &instance,
            .enabled_extensions = (dispatch.EnabledDeviceExts{}).with(.external_semaphore_fd),
            .handle_type = .opaque_fd,
        },
    };
    support_bits = vulkan.VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT | vulkan.VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT;
    imported_export_bits = external.HandleType.sync_fd.vkHandleTypeFlags();
    const unsupported_export = try external.Service.initAuthorized(options, true);
    try std.testing.expect(!unsupported_export.export_from_imported);
    imported_export_bits = external.HandleType.opaque_fd.vkHandleTypeFlags();
    const supported_export = try external.Service.initAuthorized(options, true);
    try std.testing.expect(supported_export.export_from_imported);
    try std.testing.expectError(error.UnsupportedHandleType, external.Service.initAuthorized(options, false));
}

test "central authorization with missing native proc is a typed load error" {
    var instance = std.mem.zeroes(dispatch.InstanceProcs);
    instance.get_physical_device_external_semaphore_properties = query;
    var device = deviceProcs();
    device.get_semaphore_fd_khr = null;
    try std.testing.expectError(error.MissingDeviceProc, external.Service.initAuthorized(.{
        .device = null,
        .device_procs = &device,
        .support = .{
            .physical_device = null,
            .instance_procs = &instance,
            .enabled_extensions = (dispatch.EnabledDeviceExts{}).with(.external_semaphore_fd),
        },
    }, true));
}
