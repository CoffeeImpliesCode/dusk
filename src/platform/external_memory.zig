//! OpaqueFD external memory: the file-descriptor handle family of Dawn's
//! `vulkan/external_memory/`.
//!
//! **What this file is.** The port of
//! `src/dawn/native/vulkan/external_memory/MemoryService.{h,cpp}` (9 rows),
//! `MemoryServiceImplementation.{h,cpp}` (2),
//! `MemoryImportParams.h` (a type, no row) and
//! `MemoryServiceImplementationOpaqueFD.{h,cpp}` (11) at Dawn revision
//! `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. `docs/40-plan.md` §2 gives the
//! `platform` module this upstream directory, and `#### M21` carries the
//! rows.
//!
//! **One merge, and why.** Dawn holds a `unique_ptr` per `ExternalImageType`
//! in a `Service` array (`MemoryService.h:89`-`:92`) and reaches each through
//! a seven-virtual `ServiceImplementation` base
//! (`MemoryServiceImplementation.h:47`-`:83`). With one handle family the
//! array has one slot and the base has no second implementation, so the port
//! has one struct with the five operations on it and no vtable. Every row
//! below is otherwise one to one.
//!
//! **What this file does not claim.** It does not port the dma-buf service or
//! the Android `AHardwareBuffer` service; `#### M21` records why. It does not
//! claim a shared-mode path: `queue_family_index` is the one external family
//! and upstream offers no other. It does not claim that the fd family is
//! disjoint, because there is no second plane to be disjoint with.
//!
//! **What it does not port from `MemoryService`.** `waitFDs` on
//! `ExternalImageDescriptorOpaqueFD` (`VulkanBackend.h:95`) is a
//! Chrome-raster-only field with no other reader in the port.
//! `GetQueueFamilyIndex` becomes `queue_family_index`, a constant, because
//! nothing varies it.

const std = @import("std");
const builtin = @import("builtin");

const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");

comptime {
    // Dawn's `ExternalMemoryHandle` is `int` on Linux (`ExternalHandle.h:53`)
    // and `void*` on the fallback (`:59`); only the semaphore handle is a
    // Windows `HANDLE` (`:37`). The fd family is the only one this port claims,
    // so a descriptor is all the handle type there is.
    if (builtin.os.tag != .linux) {
        @compileError("the OpaqueFD external-memory family is a Linux file descriptor");
    }
}

/// A file descriptor standing for an exported memory object.
///
/// Dawn's `ExternalMemoryHandle` (`ExternalHandle.h:53`).
// A type, so `AGENTS.md` §2 spells it `PascalCase`; `ziglint`'s Z006 resolves
// no type through a qualified path, so `@TypeOf` names the same descriptor.
pub const ExternalMemoryHandle = @TypeOf(@as(std.posix.fd_t, 0));

/// The queue family an exported image belongs to.
///
/// Dawn returns this from a virtual
/// (`MemoryServiceImplementationOpaqueFD.cpp:121`) because the dma-buf and
/// Android implementations answer differently. The port keeps it a constant
/// because only one family exists, and a constant cannot drift away from its
/// only call site.
pub const queue_family_index: u32 = vulkan.VK_QUEUE_FAMILY_EXTERNAL;

/// Whether the memory backing an imported image must be a dedicated
/// allocation.
///
/// Dawn's `NeedsDedicatedAllocation`, reached through `VulkanBackend.h`.
/// `detect` asks the device.
pub const NeedsDedicatedAllocation = enum {
    yes,
    no,
    detect,
};

/// The three fields that cross from parameter gathering to
/// `vkAllocateMemory`.
///
/// Dawn's `MemoryImportParams` (`MemoryImportParams.h:35`). Its three fields
/// are the whole surface between `GetMemoryImportParams` and
/// `ImportMemory`, and so are these three.
pub const MemoryImportParams = struct {
    allocation_size: vulkan.VkDeviceSize,
    memory_type_index: u32,
    dedicated_allocation: bool,
};

/// The OpaqueFD half of Dawn's `ExternalImageDescriptorOpaqueFD`
/// (`VulkanBackend.h:102`-`:107`).
///
/// There is no descriptor field: `importMemory` takes the descriptor as a
/// parameter, because `vkAllocateMemory` takes ownership of it
/// (`MemoryServiceImplementationOpaqueFD.cpp:142`) and a struct field cannot
/// be handed over.
pub const Descriptor = struct {
    allocation_size: vulkan.VkDeviceSize,
    /// For OPAQUE_FD this is the exporting Vulkan allocation's type index.
    /// The exporter and importer must have compatible physical-device and
    /// driver properties. vkGetMemoryFdPropertiesKHR cannot query OPAQUE_FD.
    memory_type_index: u32,
    dedicated_allocation: NeedsDedicatedAllocation = .detect,
};

/// What `supportsImportMemory` asks the physical device about an image.
///
/// Dawn passes the same five values as parameters
/// (`MemoryServiceImplementationOpaqueFD.cpp:51`-`:55`); the house rule in
/// `AGENTS.md` §2 moves them into a struct because they travel together.
pub const FormatQuery = struct {
    format: vulkan.VkFormat,
    image_type: vulkan.VkImageType,
    tiling: vulkan.VkImageTiling,
    usage: vulkan.VkImageUsageFlags,
    flags: vulkan.VkImageCreateFlags = 0,
};

/// Everything an entry point needs to name the device it works on.
///
/// Dawn reaches all of it through `Device*`
/// (`MemoryServiceImplementationOpaqueFD.cpp:44`). The port passes one
/// struct, so a `Service` can be built and queried with no device behind it,
/// which is what makes the negative-space tests possible (`AGENTS.md` §3).
pub const DeviceOptions = struct {
    physical_device: vulkan.VkPhysicalDevice,
    device: vulkan.VkDevice,
    instance_procs: *const dispatch.InstanceProcs,
    device_procs: *const dispatch.DeviceProcs,
    enabled_extensions: dispatch.EnabledDeviceExts,
};

/// Everything the OpaqueFD family refuses.
///
/// `dispatch.Error` is the driver code set (`src/vk/dispatch.zig:1133`). The
/// two members below are the ones upstream raises through `DAWN_INVALID_IF`,
/// which reports a validation error rather than a Vulkan one.
///
/// `dispatch.LoadError` is joined in whole, as `src/engine/buffer.zig:194`
/// joins it, because this file reads three device dispatch fields and
/// `AGENTS.md` §3.1 makes each missing one a typed error. Its four members are
/// swept in `src/vk/dispatch.zig`, so the count below carries them.
pub const Error = dispatch.Error || dispatch.LoadError || error{
    /// `requirements.size` is above `params.allocation_size`. Dawn checks
    /// this at `MemoryServiceImplementationOpaqueFD.cpp:130`.
    AllocationTooSmall,
    /// `handle` is negative. `VkImportMemoryFdInfoKHR::fd` is a valid
    /// descriptor, so no negative value is one; Dawn checks this at
    /// `MemoryServiceImplementationOpaqueFD.cpp:126`.
    InvalidMemoryHandle,
    /// The exporting allocation's type must also be accepted by the image.
    InvalidMemoryType,
};

/// Ports `ServiceImplementationOpaqueFD::CheckSupport`
/// (`MemoryServiceImplementationOpaqueFD.cpp:47`) and the free
/// `CheckOpaqueFDSupport` that only forwards to it (`:193`).
///
/// Dawn splits the pair because the class is private to its `.cpp`. One Zig
/// function is both.
pub fn checkSupport(enabled_extensions: dispatch.EnabledDeviceExts) bool {
    return enabled_extensions.has(.external_memory_fd);
}

/// The OpaqueFD external memory service.
///
/// Ports `ServiceImplementationOpaqueFD` (`:41`-`:191`) and, with the
/// dispatch the class is reached through, `Service` (`MemoryService.cpp:49`).
/// A value, not a heap object: it owns no handle and needs no `deinit`.
pub const Service = struct {
    options: DeviceOptions,
    supported: bool,

    /// Ports the constructor at `MemoryServiceImplementationOpaqueFD.cpp:43`
    /// and `Service::Service` at `MemoryService.cpp:61`, which installs the
    /// implementation when `CheckSupport` passes.
    pub fn init(options: DeviceOptions) Service {
        return .{
            .options = options,
            .supported = checkSupport(options.enabled_extensions),
        };
    }

    /// Ports `Supported` (`MemoryServiceImplementationOpaqueFD.cpp:187`).
    pub fn isSupported(self: Service) bool {
        return self.supported;
    }

    /// Ports `SupportsImportMemory`
    /// (`MemoryServiceImplementationOpaqueFD.cpp:51`), which
    /// `Service::SupportsImportMemory` (`MemoryService.cpp:87`) forwards.
    pub fn supportsImportMemory(self: Service, query: FormatQuery) bool {
        // Dawn early-outs before it touches an extension proc
        // (`MemoryServiceImplementationOpaqueFD.cpp:57`).
        if (!self.supported) return false;
        const query_format_properties = self.options.instance_procs
            .get_physical_device_image_format_properties2 orelse return false;

        var external_format_info: vulkan.VkPhysicalDeviceExternalImageFormatInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO_KHR,
            .handleType = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        var format_info: vulkan.VkPhysicalDeviceImageFormatInfo2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2_KHR,
            .pNext = &external_format_info,
            .format = query.format,
            .type = query.image_type,
            .tiling = query.tiling,
            .usage = query.usage,
            .flags = query.flags,
        };
        var external_format_properties: vulkan.VkExternalImageFormatProperties = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES_KHR,
        };
        var format_properties: vulkan.VkImageFormatProperties2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2_KHR,
            .pNext = &external_format_properties,
        };

        const result = query_format_properties(
            self.options.physical_device,
            &format_info,
            &format_properties,
        );
        // A format the handle type cannot carry comes back as
        // `VK_ERROR_FORMAT_NOT_SUPPORTED`, which is a "no" and not a failure
        // (`MemoryServiceImplementationOpaqueFD.cpp:88`).
        if (dispatch.classify(result) != .success) return false;

        const features = external_format_properties.externalMemoryProperties
            .externalMemoryFeatures;
        return features & vulkan.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT_KHR != 0;
    }

    /// Ports `SupportsCreateImage`
    /// (`MemoryServiceImplementationOpaqueFD.cpp:97`).
    ///
    /// Dawn answers `mSupported` and writes `false` through the
    /// `supportsDisjoint` out-parameter (`:101`). The fd family is never
    /// disjoint, so the port keeps the boolean and names the second answer
    /// here rather than paying for an out-parameter that can only be false.
    pub fn supportsCreateImage(self: Service) bool {
        return self.supported;
    }

    /// Ports `GetMemoryImportParams`
    /// (`MemoryServiceImplementationOpaqueFD.cpp:105`).
    ///
    /// Upstream rejects a descriptor that is not OpaqueFD (`:108`). With one
    /// family in the port there is no other descriptor, so the check has
    /// nothing to read and is not a row here.
    ///
    /// A `.detect` request reads the device, so this can report
    /// `error.MissingDeviceProc`; `.yes` and `.no` answer from the descriptor
    /// alone and cannot fail.
    pub fn getMemoryImportParams(
        self: Service,
        descriptor: Descriptor,
        image: vulkan.VkImage,
    ) Error!MemoryImportParams {
        return .{
            .allocation_size = descriptor.allocation_size,
            .memory_type_index = descriptor.memory_type_index,
            .dedicated_allocation = try requiresDedicatedAllocation(
                self.options.device,
                self.options.device_procs,
                descriptor.dedicated_allocation,
                image,
            ),
        };
    }

    /// Ports `ImportMemory` (`MemoryServiceImplementationOpaqueFD.cpp:123`).
    ///
    /// Takes ownership of `handle` on success, because `vkAllocateMemory`
    /// does (`MemoryServiceImplementationOpaqueFD.cpp:156`). On failure the
    /// caller still owns it.
    pub fn importMemory(
        self: Service,
        handle: ExternalMemoryHandle,
        params: MemoryImportParams,
        image: vulkan.VkImage,
    ) Error!vulkan.VkDeviceMemory {
        if (handle < 0) return error.InvalidMemoryHandle;

        const get_requirements = self.options.device_procs.get_image_memory_requirements orelse
            return error.MissingDeviceProc;
        // SAFETY: `vkGetImageMemoryRequirements` is an out-parameter call: the
        // driver writes every field of the struct before the statement
        // returns, and the `if` below is the first read.
        var requirements: vulkan.VkMemoryRequirements = undefined;
        get_requirements(self.options.device, image, &requirements);
        if (requirements.size > params.allocation_size) return error.AllocationTooSmall;
        if (params.memory_type_index >= 32 or
            requirements.memoryTypeBits & (@as(u32, 1) << @intCast(params.memory_type_index)) == 0)
        {
            return error.InvalidMemoryType;
        }

        var import_info: vulkan.VkImportMemoryFdInfoKHR = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
            .handleType = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
            .fd = handle,
        };
        var dedicated_info: vulkan.VkMemoryDedicatedAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = image,
        };
        var allocate_info: vulkan.VkMemoryAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &import_info,
            .allocationSize = params.allocation_size,
            .memoryTypeIndex = params.memory_type_index,
        };
        // Dawn appends the dedicated struct only when it is asked for
        // (`MemoryServiceImplementationOpaqueFD.cpp:150`), and the chain it
        // builds is allocate, then import, then dedicated (`:148`-`:152`).
        if (params.dedicated_allocation) {
            import_info.pNext = &dedicated_info;
        }

        const allocate_memory = self.options.device_procs.allocate_memory orelse
            return error.MissingDeviceProc;
        var allocated: vulkan.VkDeviceMemory = null;
        try dispatch.checkVkSuccess(
            allocate_memory(self.options.device, &allocate_info, null, &allocated),
        );
        return allocated;
    }

    /// Ports `CreateImage` (`MemoryServiceImplementationOpaqueFD.cpp:162`).
    ///
    /// Dawn takes `const VkImageCreateInfo&` by reference and copies it
    /// (`MemoryServiceImplementationOpaqueFD.cpp:164`). The port takes the
    /// value, which is that same copy, and does not hide it from the caller.
    pub fn createImage(
        self: Service,
        base: vulkan.VkImageCreateInfo,
    ) Error!vulkan.VkImage {
        var external_info: vulkan.VkExternalMemoryImageCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .handleTypes = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        var create_info = base;
        create_info.flags |= vulkan.VK_IMAGE_CREATE_ALIAS_BIT_KHR;
        create_info.tiling = vulkan.VK_IMAGE_TILING_OPTIMAL;
        create_info.initialLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED;
        create_info.pNext = &external_info;

        const create_image = self.options.device_procs.create_image orelse
            return error.MissingDeviceProc;
        var image: vulkan.VkImage = null;
        try dispatch.checkVkSuccess(
            create_image(self.options.device, &create_info, null, &image),
        );
        return image;
    }
};

/// Ports `ServiceImplementation::RequiresDedicatedAllocation`
/// (`MemoryServiceImplementation.cpp:37`).
///
/// Upstream ends the switch with `DAWN_UNREACHABLE` (`:67`). `need` is an
/// exhaustive Zig enum, so there is no case left for that arm to name.
///
/// `.detect` reads the device and so needs a dispatch field. A loader that
/// missed one is reported rather than answered, because `AGENTS.md` §3.1 makes
/// a missing proc a typed error and not a panic. `.yes` and `.no` answer from
/// the request and cannot fail.
pub fn requiresDedicatedAllocation(
    device: vulkan.VkDevice,
    device_procs: *const dispatch.DeviceProcs,
    need: NeedsDedicatedAllocation,
    image: vulkan.VkImage,
) Error!bool {
    return switch (need) {
        .yes => true,
        .no => false,
        .detect => blk: {
            var dedicated_requirements: vulkan.VkMemoryDedicatedRequirements = .{
                .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS,
            };
            var base_requirements: vulkan.VkMemoryRequirements2 = .{
                .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2,
                .pNext = &dedicated_requirements,
            };
            var image_info: vulkan.VkImageMemoryRequirementsInfo2 = .{
                .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
                .image = image,
            };
            const get_requirements2 = device_procs.get_image_memory_requirements2 orelse
                return error.MissingDeviceProc;
            get_requirements2(
                device,
                &image_info,
                &base_requirements,
            );
            // The specification requires `prefersDedicatedAllocation` to be
            // set whenever `requiresDedicatedAllocation` is, so upstream reads
            // only the first (`MemoryServiceImplementation.cpp:63`).
            break :blk dedicated_requirements.prefersDedicatedAllocation != 0;
        },
    };
}

/// A proc table with nothing loaded in it.
///
/// Every field of both tiers is a nullable function pointer and a null one is
/// all-zero bits, so `std.mem.zeroes` is the constructor the loaders use
/// (`src/vk/dispatch.zig:957` and `:1052`). The empty struct literal `.{}` is
/// not: Zig gives an optional field no implicit default, so `.{}` names none
/// of the roughly 250 fields and is a compile error.
const empty_instance_procs: dispatch.InstanceProcs = std.mem.zeroes(dispatch.InstanceProcs);
const empty_device_procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);

/// How many branches one `comptime` walk over a proc table may take. The
/// quota is raised because a walk over both tiers names every field.
const empty_procs_branch_budget: u32 = 100_000;

/// Fails to compile when a field of `table` is non-null.
///
/// `AGENTS.md` §3.1 makes a missing proc a typed error, so the property an
/// empty table has to hold is that nothing in it is loaded. Nothing below
/// would notice a default value added to a `dispatch.zig` field, and the
/// field name is what says which one changed.
fn assertAllProcsNull(comptime Procs: type, comptime table: *const Procs) void {
    @setEvalBranchQuota(empty_procs_branch_budget);
    for (@typeInfo(Procs).@"struct".fields) |field| {
        if (@field(table, field.name) != null) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} is non-null in an empty proc table",
                .{ @typeName(Procs), field.name },
            ));
        }
    }
}

comptime {
    assertAllProcsNull(dispatch.InstanceProcs, &empty_instance_procs);
    assertAllProcsNull(dispatch.DeviceProcs, &empty_device_procs);
}

/// A service with no device behind it and the extension off, which is the
/// shape the negative-space tests need: `supportsImportMemory` early-outs on
/// `supported`, and `importMemory` answers its handle guard before it reaches
/// a proc.
const device_free_service: Service = .{
    .options = .{
        .physical_device = null,
        .device = null,
        .instance_procs = &empty_instance_procs,
        .device_procs = &empty_device_procs,
        .enabled_extensions = .{},
    },
    .supported = false,
};

test "support is one extension bit" {
    // Dawn's `CheckSupport` is a single `HasExt` test
    // (`MemoryServiceImplementationOpaqueFD.cpp:48`), so the whole negative
    // space is one bit and is pinned here with no device.
    try std.testing.expect(!checkSupport(.{}));
    try std.testing.expect(checkSupport(
        (dispatch.EnabledDeviceExts{}).with(.external_memory_fd),
    ));
}

test "a service built without the extension answers no to every query" {
    try std.testing.expect(!device_free_service.isSupported());
    try std.testing.expect(!device_free_service.supportsCreateImage());
    try std.testing.expect(!device_free_service.supportsImportMemory(.{
        .format = vulkan.VK_FORMAT_R8G8B8A8_UNORM,
        .image_type = vulkan.VK_IMAGE_TYPE_2D,
        .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
        .usage = vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    }));
}

test "every member of the error set is named" {
    // `AGENTS.md` §3 asks that every member be named, so a failure names the
    // member and not the set. `@typeInfo` hands back a name per member rather
    // than an error value, and that is what this sweep reads.
    for (@typeInfo(Error).error_set.?) |member| {
        try std.testing.expect(member.name.len > 0);
    }
    // Dispatch sweeps driver and loader errors. The three service guards
    // (allocation size, handle, and memory type) are exercised below.
    try std.testing.expect(
        @typeInfo(Error).error_set.?.len ==
            @typeInfo(dispatch.Error).error_set.?.len + 7,
    );
}

test "the dedicated-allocation answer is a total function of the request" {
    // `.yes` and `.no` never reach the device
    // (`MemoryServiceImplementation.cpp:40`-`:45`), so they are testable with
    // no device behind them. `.detect` does reach it and needs one.
    try std.testing.expect(try requiresDedicatedAllocation(
        null,
        &empty_device_procs,
        .yes,
        null,
    ));
    try std.testing.expect(!try requiresDedicatedAllocation(
        null,
        &empty_device_procs,
        .no,
        null,
    ));
}

test "the import parameters carry the descriptor through unchanged" {
    const params = try device_free_service.getMemoryImportParams(.{
        .allocation_size = 4096,
        .memory_type_index = 3,
        .dedicated_allocation = .no,
    }, null);

    try std.testing.expectEqual(@as(vulkan.VkDeviceSize, 4096), params.allocation_size);
    try std.testing.expectEqual(@as(u32, 3), params.memory_type_index);
    try std.testing.expect(!params.dedicated_allocation);
}

test "a supported service with an absent proc answers no instead of panicking" {
    // Dawn early-outs before it touches an extension proc
    // (`MemoryServiceImplementationOpaqueFD.cpp:57`), which is the `orelse`
    // at `supportsImportMemory`: a table with the extension enabled and the
    // proc absent is a "no", and an answer that dereferenced the null field
    // would take the process down instead.
    //
    // Built through `init`, the port of the upstream constructor
    // (`MemoryService.cpp:61`). `device_free_service` is a literal, so with
    // only it and `checkSupport` under test nothing reached `init`, and a
    // `Service` that stopped consulting `checkSupport` would still be green.
    const service: Service = .init(.{
        .physical_device = null,
        .device = null,
        .instance_procs = &empty_instance_procs,
        .device_procs = &empty_device_procs,
        .enabled_extensions = (dispatch.EnabledDeviceExts{}).with(.external_memory_fd),
    });

    try std.testing.expect(service.isSupported());
    try std.testing.expect(service.supportsCreateImage());
    try std.testing.expect(!service.supportsImportMemory(.{
        .format = vulkan.VK_FORMAT_R8G8B8A8_UNORM,
        .image_type = vulkan.VK_IMAGE_TYPE_2D,
        .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
        .usage = vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    }));
}

/// The size the stubbed requirement query below reports. It only has to
/// differ from the allocation the test offers, because the test is about the
/// comparison and not about any driver's number.
const stub_requirement_size: vulkan.VkDeviceSize = 8192;

/// The one proc the import tests load. Asserting the arguments is what keeps
/// the stub honest: a size that came from a different call would still be a
/// number, and not the bound the test is about.
fn stubGetImageMemoryRequirements(
    device: vulkan.VkDevice,
    image: vulkan.VkImage,
    p_memory_requirements: [*c]vulkan.VkMemoryRequirements,
) callconv(.c) void {
    std.debug.assert(device == null);
    std.debug.assert(image == null);
    p_memory_requirements.*.size = stub_requirement_size;
    p_memory_requirements.*.memoryTypeBits = 1;
}

test "an allocation below the requirement is refused before it allocates" {
    // Dawn checks the size before it allocates
    // (`MemoryServiceImplementationOpaqueFD.cpp:130`). `allocate_memory`
    // stays null here, so a bound that was not checked would be a panic on
    // the null proc and not `error.AllocationTooSmall`.
    var device_procs: dispatch.DeviceProcs = std.mem.zeroes(dispatch.DeviceProcs);
    device_procs.get_image_memory_requirements = stubGetImageMemoryRequirements;
    const service: Service = .init(.{
        .physical_device = null,
        .device = null,
        .instance_procs = &empty_instance_procs,
        .device_procs = &device_procs,
        .enabled_extensions = (dispatch.EnabledDeviceExts{}).with(.external_memory_fd),
    });

    try std.testing.expectError(
        error.AllocationTooSmall,
        service.importMemory(0, .{
            .allocation_size = 4096,
            .memory_type_index = 0,
            .dedicated_allocation = false,
        }, null),
    );
}

test "a negative handle is refused before any proc is reached" {
    // The guard is the first statement of `importMemory`
    // (`MemoryServiceImplementationOpaqueFD.cpp:126`), so it answers with
    // both proc tables still empty. A guard that moved below the requirements
    // query would be a panic on the null proc and not the typed error.
    try std.testing.expectError(
        error.InvalidMemoryHandle,
        device_free_service.importMemory(-1, .{
            .allocation_size = 4096,
            .memory_type_index = 0,
            .dedicated_allocation = false,
        }, null),
    );
}

test "an incompatible memory type is refused before allocation" {
    var procs = empty_device_procs;
    procs.get_image_memory_requirements = stubGetImageMemoryRequirements;
    var service = device_free_service;
    service.options.device_procs = &procs;
    for ([_]u32{ 1, 32, std.math.maxInt(u32) }) |index| {
        try std.testing.expectError(error.InvalidMemoryType, service.importMemory(0, .{
            .allocation_size = stub_requirement_size,
            .memory_type_index = index,
            .dedicated_allocation = false,
        }, null));
    }
}
