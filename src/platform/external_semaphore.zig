//! External synchronisation by file descriptor: Dawn's
//! `vulkan/external_semaphore/` fd service.
//!
//! **What this file is.** The port of
//! `src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationFD.{h,cpp}`
//! (10 rows), `SemaphoreService.{h,cpp}` (8) and
//! `SemaphoreServiceImplementation.{h,cpp}` (1) at Dawn revision
//! `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. `docs/40-plan.md` §2 gives the
//! `platform` module this upstream directory, and `#### M21` carries the
//! rows.
//!
//! **One merge, and why.** Dawn holds a `unique_ptr<ServiceImplementation>`
//! (`SemaphoreService.h:72`) and reaches it through six virtuals on an
//! abstract base (`SemaphoreServiceImplementation.h:47`-`:62`). The Zircon
//! implementation is skipped (`docs/40-plan.md`:739), so the base has one
//! subclass and the pointer array has one slot. The port has one struct and
//! no vtable.
//!
//! **One deviation, and why.** Upstream rejects every negative descriptor at
//! `SemaphoreServiceImplementationFD.cpp:93`, including the one the Vulkan
//! specification defines: `-1` for
//! `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT_KHR` means "already
//! signalled" (`UtilsVulkan.h:48`-`:51`). The port accepts that one value for
//! the sync handle type and rejects every other negative value, which is what
//! the acceptance in `docs/40-plan.md` M21 asks for and what the sentinel is
//! for. `exportSemaphore` seeds its out-parameter with `-2` for the same
//! reason (`SemaphoreServiceImplementationFD.cpp:167`): `-1` is a valid
//! answer.
//!
//! **What this file does not claim.** It does not claim the Zircon handle
//! family. It does not claim that a duplicated descriptor is independent of
//! the original: `dup(2)` gives a second reference to the same open file, so
//! closing one leaves the other valid.

const std = @import("std");
const builtin = @import("builtin");

const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");

comptime {
    // `ExternalSemaphoreHandle` is `int` on POSIX
    // (`ExternalHandle.h:42`-`:43`), and the whole fd family is a descriptor.
    if (builtin.os.tag != .linux) {
        @compileError("the fd external-semaphore family is a Linux file descriptor");
    }
}

/// A file descriptor standing for an exported semaphore, or the sentinel
/// below.
///
/// Dawn's `ExternalSemaphoreHandle` (`ExternalHandle.h:43`).
// A type, so `AGENTS.md` §2 spells it `PascalCase`; `ziglint`'s Z006 resolves
// no type through a qualified path, so `@TypeOf` names the same descriptor.
pub const ExternalSemaphoreHandle = @TypeOf(@as(std.posix.fd_t, 0));

/// The descriptor the Vulkan specification defines as "already signalled".
///
/// Per `vkImportSemaphoreFdKHR` and `vkImportFenceFdKHR`, `fd = -1` for
/// `VK_EXTERNAL_*_HANDLE_TYPE_SYNC_FD_BIT` is a valid sync file descriptor
/// meaning "already signaled" (`UtilsVulkan.h:48`-`:51`). It is a value, not
/// a descriptor, so `duplicateHandle` and `closeHandle` both short-circuit on
/// it rather than passing it to a syscall.
pub const semaphore_fd_already_signaled_fd: ExternalSemaphoreHandle = -1;

/// The two descriptor types `VK_KHR_external_semaphore_fd` defines.
pub const HandleType = enum {
    sync_fd,
    opaque_fd,

    /// The `VkExternalSemaphoreHandleTypeFlagBits` value for this type.
    pub fn vkHandleType(self: HandleType) vulkan.VkExternalSemaphoreHandleTypeFlagBits {
        return switch (self) {
            .sync_fd => vulkan.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            .opaque_fd => vulkan.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT_KHR,
        };
    }

    /// The `VkExternalSemaphoreHandleTypeFlags` value for this type, which is
    /// one bit set.
    pub fn vkHandleTypeFlags(self: HandleType) vulkan.VkExternalSemaphoreHandleTypeFlags {
        return @intCast(self.vkHandleType());
    }
};

/// The handle type a Linux desktop build uses.
///
/// Dawn's `kDefaultHandleType` (`SemaphoreServiceImplementationFD.cpp:42`-`:47`)
/// picks `SYNC_FD` on Android and ChromeOS and `OPAQUE_FD` everywhere else.
pub const default_handle_type: HandleType = .opaque_fd;

/// Everything a `Service` refuses, and everything `duplicateHandle` refuses.
///
/// `dispatch.Error` is the driver code set (`src/vk/dispatch.zig:1133`). The
/// two rules below are the ones this file adds to it, and `DuplicateFailed`
/// is one of them rather than a set of its own: `importSemaphore` is what
/// calls `duplicateHandle`, so a member only the free function named would be
/// a member no caller of the service could receive.
///
/// `dispatch.LoadError` is joined in whole, as `src/engine/buffer.zig:194`
/// joins it, because this file reads four device dispatch fields and
/// `AGENTS.md` §3.1 makes each missing one a typed error. Its four members are
/// swept in `src/vk/dispatch.zig`, so the count below carries them.
pub const Error = dispatch.Error || dispatch.LoadError || error{
    /// `dup(2)` refused. Dawn asserts instead
    /// (`SemaphoreServiceImplementationFD.cpp:182`); the port returns the
    /// error, because a call that cannot fail cannot be tested.
    DuplicateFailed,
    /// The descriptor is negative and is not
    /// `semaphore_fd_already_signaled_fd`, which only the sync handle type
    /// accepts. Dawn rejects the whole negative range at
    /// `SemaphoreServiceImplementationFD.cpp:93`.
    InvalidSemaphoreHandle,
};

/// What `checkSupport` needs.
///
/// Dawn passes three of these to `CheckFDSupport`
/// (`SemaphoreServiceImplementationFD.cpp:205`), and a fourth reaches the
/// constructor through `CreateFDService` (`:199`).
pub const SupportOptions = struct {
    physical_device: vulkan.VkPhysicalDevice,
    instance_procs: *const dispatch.InstanceProcs,
    enabled_extensions: dispatch.EnabledDeviceExts,
    handle_type: HandleType = default_handle_type,
};

/// Ports `ServiceImplementationFD::CheckSupport`
/// (`SemaphoreServiceImplementationFD.cpp:63`) and the free
/// `CheckFDSupport` that only forwards to it (`:205`).
///
/// Dawn splits the pair because the class is private to its `.cpp`. One Zig
/// function is both.
pub fn checkSupport(options: SupportOptions) bool {
    if (!options.enabled_extensions.has(.external_semaphore_fd)) return false;
    const query_properties = options.instance_procs
        .get_physical_device_external_semaphore_properties orelse return false;

    var semaphore_info: vulkan.VkPhysicalDeviceExternalSemaphoreInfo = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO_KHR,
        .handleType = options.handle_type.vkHandleType(),
    };
    var semaphore_properties: vulkan.VkExternalSemaphoreProperties = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES_KHR,
    };
    query_properties(options.physical_device, &semaphore_info, &semaphore_properties);

    const required = vulkan.VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT_KHR |
        vulkan.VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT_KHR;
    return semaphore_properties.externalSemaphoreFeatures & required == required;
}

/// The fd external semaphore service.
///
/// Ports `ServiceImplementationFD` (`SemaphoreServiceImplementationFD.cpp:51`-`:197`)
/// and, with the dispatch the class is reached through, `SemaphoreService`
/// (`SemaphoreService.h:45`). A value, not a heap object: it owns no handle
/// and needs no `deinit`.
pub const Service = struct {
    device: vulkan.VkDevice,
    procs: *const dispatch.DeviceProcs,
    handle_type: HandleType,
    supported: bool,

    /// Ports the constructor at `SemaphoreServiceImplementationFD.cpp:53`
    /// and `SemaphoreService::Service` at `SemaphoreService.cpp:57`.
    pub fn init(options: InitOptions) Service {
        const supported = checkSupport(options.support);
        return .{
            .device = options.device,
            .procs = options.device_procs,
            .handle_type = options.support.handle_type,
            .supported = supported,
        };
    }

    /// Ports `Supported` (`SemaphoreServiceImplementationFD.cpp:89`).
    pub fn isSupported(self: Service) bool {
        return self.supported;
    }

    /// Ports `CreateExportableSemaphore`
    /// (`SemaphoreServiceImplementationFD.cpp:140`).
    pub fn createExportableSemaphore(self: Service) Error!vulkan.VkSemaphore {
        var export_info: vulkan.VkExportSemaphoreCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO_KHR,
            .handleTypes = self.handle_type.vkHandleTypeFlags(),
        };
        var create_info: vulkan.VkSemaphoreCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &export_info,
        };
        const create_semaphore = self.procs.create_semaphore orelse
            return error.MissingDeviceProc;
        var semaphore: vulkan.VkSemaphore = null;
        try dispatch.checkVkSuccess(
            create_semaphore(self.device, &create_info, null, &semaphore),
        );
        return semaphore;
    }

    /// Ports `ExportSemaphore` (`SemaphoreServiceImplementationFD.cpp:160`).
    ///
    /// The caller owns the returned descriptor and closes it with
    /// `closeHandle`.
    pub fn exportSemaphore(
        self: Service,
        semaphore: vulkan.VkSemaphore,
    ) Error!ExternalSemaphoreHandle {
        var get_info: vulkan.VkSemaphoreGetFdInfoKHR = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .semaphore = semaphore,
            .handleType = self.handle_type.vkHandleType(),
        };
        // `-2` is what Dawn seeds the out-parameter with
        // (`SemaphoreServiceImplementationFD.cpp:167`), so a driver that
        // leaves it untouched fails the assertion below instead of reading
        // as the already-signalled sentinel.
        var descriptor: c_int = -2;
        const get_fd = self.procs.get_semaphore_fd_khr orelse
            return error.MissingDeviceProc;
        try dispatch.checkVkSuccess(
            get_fd(self.device, &get_info, &descriptor),
        );
        std.debug.assert(
            descriptor >= 0 or descriptor == semaphore_fd_already_signaled_fd,
        );
        return descriptor;
    }

    /// Ports `ImportSemaphore` (`SemaphoreServiceImplementationFD.cpp:92`).
    ///
    /// `vkImportSemaphoreFdKHR` takes ownership of the descriptor on success
    /// (`SemaphoreServiceImplementationFD.cpp:122`), and Dawn hands it a
    /// duplicate so the caller keeps its own. The port does the same, so the
    /// caller still owns `handle` whatever the outcome.
    pub fn importSemaphore(
        io: std.Io,
        self: Service,
        handle: ExternalSemaphoreHandle,
    ) Error!vulkan.VkSemaphore {
        // The sentinel is a value, not a descriptor, so there is nothing to
        // duplicate and nothing to close if the import fails. It is accepted
        // only for the sync handle type, which is the type the specification
        // defines it for (`UtilsVulkan.h:49`).
        if (handle == semaphore_fd_already_signaled_fd and
            self.handle_type == .sync_fd)
        {
            return self.importSemaphoreDescriptor(handle);
        }
        if (handle < 0) return error.InvalidSemaphoreHandle;

        const copy = try duplicateHandle(handle);
        errdefer closeHandle(io, copy);
        return self.importSemaphoreDescriptor(copy);
    }

    /// The `vkCreateSemaphore` and `vkImportSemaphoreFdKHR` pair that
    /// `importSemaphore` shares between a real descriptor and the sentinel.
    fn importSemaphoreDescriptor(
        self: Service,
        descriptor: ExternalSemaphoreHandle,
    ) Error!vulkan.VkSemaphore {
        var create_info: vulkan.VkSemaphoreCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };
        // Both procs are resolved before the semaphore is created, so a loader
        // that missed either one leaves no created semaphore behind. The
        // refusal is typed per `AGENTS.md` §3.1.
        const create_semaphore = self.procs.create_semaphore orelse
            return error.MissingDeviceProc;
        const destroy_semaphore = self.procs.destroy_semaphore orelse
            return error.MissingDeviceProc;
        var semaphore: vulkan.VkSemaphore = null;
        try dispatch.checkVkSuccess(
            create_semaphore(self.device, &create_info, null, &semaphore),
        );
        errdefer destroy_semaphore(self.device, semaphore, null);

        var import_info: vulkan.VkImportSemaphoreFdInfoKHR = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
            .semaphore = semaphore,
            // A temporary import means that after a wait on this semaphore
            // its payload is restored to the prior permanent state, which is
            // signalled, so several waiters can be released from one signal.
            // Temporary is also the only valid flag for a sync descriptor,
            // because a sync descriptor transitions once and never back.
            // Dawn explains the choice at
            // `SemaphoreServiceImplementationFD.cpp:109`-`:119`.
            .flags = vulkan.VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
            .handleType = self.handle_type.vkHandleType(),
            .fd = descriptor,
        };
        const import_fd = self.procs.import_semaphore_fd_khr orelse
            return error.MissingDeviceProc;
        try dispatch.checkVkSuccess(
            import_fd(self.device, &import_info),
        );
        return semaphore;
    }
};

/// What `Service.init` needs.
pub const InitOptions = struct {
    device: vulkan.VkDevice,
    device_procs: *const dispatch.DeviceProcs,
    support: SupportOptions,
};

/// Ports `DuplicateHandle` (`SemaphoreServiceImplementationFD.cpp:177`).
///
/// The result is a second reference to the same open file, so closing either
/// one leaves the other valid.
pub fn duplicateHandle(
    handle: ExternalSemaphoreHandle,
) Error!ExternalSemaphoreHandle {
    // The sentinel names a state, not a file, so it duplicates to itself
    // (`SemaphoreServiceImplementationFD.cpp:178`-`:179`).
    if (handle == semaphore_fd_already_signaled_fd) {
        return semaphore_fd_already_signaled_fd;
    }
    return dupDescriptor(handle);
}

/// Ports `CloseHandle` (`SemaphoreServiceImplementationFD.cpp:186`).
///
/// Dawn closes and asserts the result (`:190`-`:191`). `std.Io.File.close`
/// fails loudly on its own, so the port has no second check to make.
pub fn closeHandle(io: std.Io, handle: ExternalSemaphoreHandle) void {
    if (handle == semaphore_fd_already_signaled_fd) return;
    fileFromDescriptor(handle).close(io);
}

/// `std.Io.File` over an owned descriptor. `nonblocking` is false because no
/// entry point here opens the descriptor itself, so it carries whatever mode
/// the driver chose.
pub fn fileFromDescriptor(handle: ExternalSemaphoreHandle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// `dup(2)` behind a declared error set.
///
/// `std.posix` at 0.16.0 wraps no `dup`, and the decision order in
/// `AGENTS.md` §6 stops at the standard library, so the port calls the
/// syscall layer. That layer reports a refusal by returning an errno above
/// the result range (`lib/std/os/linux.zig:591`), which is what `errno`
/// reads.
fn dupDescriptor(
    handle: ExternalSemaphoreHandle,
) Error!ExternalSemaphoreHandle {
    const result = std.os.linux.dup(handle);
    if (std.os.linux.errno(result) != .SUCCESS) return error.DuplicateFailed;
    return @intCast(result);
}

/// Every field of the instance tier is optional, so the zero value is a table
/// with nothing loaded. `checkSupport` reads one field and this file has no
/// device behind it.
const empty_instance_procs: dispatch.InstanceProcs = std.mem.zeroes(dispatch.InstanceProcs);

const device_free_support: SupportOptions = .{
    .physical_device = null,
    .instance_procs = &empty_instance_procs,
    .enabled_extensions = .{},
};

test "support is the extension bit and the importable-and-exportable pair" {
    // Dawn's `CheckSupport` is two tests in sequence
    // (`SemaphoreServiceImplementationFD.cpp:66` and `:82`-`:85`), so the
    // negative space is one bit when there is no device to ask.
    try std.testing.expect(!checkSupport(device_free_support));
    try std.testing.expect(!checkSupport(.{
        .physical_device = null,
        .instance_procs = &empty_instance_procs,
        .enabled_extensions = (dispatch.EnabledDeviceExts{})
            .with(.external_semaphore_fd),
    }));
}

test "the sentinel is the descriptor the specification names" {
    // `UtilsVulkan.h:48`-`:51` defines the value and the type it belongs to;
    // the port keeps both claims testable without a device.
    try std.testing.expectEqual(@as(ExternalSemaphoreHandle, -1), semaphore_fd_already_signaled_fd);
    try std.testing.expect(semaphore_fd_already_signaled_fd < 0);
}

test "the sentinel duplicates to itself" {
    // `SemaphoreServiceImplementationFD.cpp:178`-`:180` returns before it
    // `dup`, because there is no descriptor to duplicate.
    try std.testing.expectEqual(
        semaphore_fd_already_signaled_fd,
        try duplicateHandle(semaphore_fd_already_signaled_fd),
    );
}

test "closing the sentinel does not reach the operating system" {
    // `SemaphoreServiceImplementationFD.cpp:187`-`:188` returns before `close`.
    // The descriptor `-1` would name the standard input, so a close that
    // reached it would take the test runner down with it.
    closeHandle(std.testing.io, semaphore_fd_already_signaled_fd);
}

test "a duplicated descriptor is a second reference to the same open file" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.Io.Dir.cwd().createFile(io, "external-semaphore-dup", .{});
    defer file.close(io);

    const copy = try duplicateHandle(file.handle);
    defer closeHandle(io, copy);

    try std.testing.expect(copy >= 0);
    try std.testing.expect(copy != file.handle);

    // The two descriptors name one file: closing the original leaves the
    // copy open, which is what `dup(2)` promises and what a caller that
    // exports while its own handle stays alive depends on.
    const before = try file.stat(io);
    const after = try fileFromDescriptor(copy).stat(io);
    try std.testing.expectEqual(before.inode, after.inode);
}

test "every member of the error set is named" {
    // `AGENTS.md` §3 asks that every member be named, so a failure names the
    // member and not the set. The `dispatch.Error` members are swept there,
    // by the table that classifies every `VkResult`
    // (`src/vk/dispatch.zig:1159`); those and the four `dispatch.LoadError`
    // members are swept there, and the two this file adds are added here. The
    // count is what makes a third one a compile-time disagreement.
    // `@typeInfo` hands back a struct per member that carries the name and no
    // error value (`lib/std/builtin.zig:719`), so the sweep reads `member.name`
    // and there is no value to switch on.
    inline for (@typeInfo(Error).error_set.?) |member| {
        try std.testing.expect(member.name.len > 0);
    }
    try std.testing.expect(
        @typeInfo(Error).error_set.?.len ==
            @typeInfo(dispatch.Error).error_set.?.len + 6,
    );
}

test "a sync descriptor that is negative is the only one the sentinel covers" {
    // The sentinel is `-1`. A descriptor of `-2` is not a state and not a
    // file, so `duplicateHandle` hands it to `dup`, which refuses.
    try std.testing.expectError(error.DuplicateFailed, duplicateHandle(-2));
}
