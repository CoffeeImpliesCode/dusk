//! The Vulkan half of a shader module: `vkCreateShaderModule` on the caller's
//! own words, and the destroy that undoes it.
//!
//! Ports `native/vulkan/ShaderModuleVk.{h,cpp}`. Dawn defers this call from
//! module creation to pipeline creation, because what it hands Vulkan is Tint's
//! regenerated words and they only exist once the entry point is compiled
//! (`ShaderModuleVk.h:68` `CompileParameters`, `:81` `GetHandleAndSpirv`). The
//! port has the caller's words at creation, so the port creates the handle at
//! creation and the 400-line body of `GetHandleAndSpirv`
//! (`ShaderModuleVk.cpp:130-532`) collapses to the tail at `:496-528`.
//!
//! **This is the row `docs/02-dawn-design.md` §4.9 says Dawn has no branch
//! for.** `ShaderModuleVk.cpp:500-501` points `codeSize` and `pCode` at
//! `compilation->spirv`, which is what `tint::spirv::writer::Generate` wrote
//! at `:429`, and the `#else` at `:529-530` is
//! `DAWN_UNRECOVERABLE_ERROR("TINT_BUILD_SPV_WRITER is not defined.")`. The
//! port points the same two fields at the words the caller handed over, and
//! `test/shader_module.zig` asserts they are word for word the input file.
//!
//! **Why the device arrives as a parameter.** `AGENTS.md` §3.1 makes the
//! dispatch table in `src/vk/dispatch.zig` the only door to Vulkan, and this
//! file names two of its fields and nothing else. `docs/10-architecture.md`
//! "Module boundaries" gives `pipeline` no Vulkan dependency, so the half of
//! the device this file needs is a value a caller fills in, and a test can fill
//! it with two null procs and read `error.MissingShaderModuleProc`.

const std = @import("std");
const spirv = @import("../spirv/root.zig");
const vk = @import("../vk/dispatch.zig");
const vulkan = @import("vulkan");

/// Everything the shader-module path needs from a device: the handle and the
/// two entry points. A `Device` is not a `VkDevice` alias and not a device
/// object; it is the seam, so `src/pipeline` needs no other module's fields.
///
/// The two proc fields carry no `?` of their own: the generated bindings
/// already make every `PFN_vk*` optional (`src/vulkan.zig:5145`), so a `?` here
/// would be a second one, and `procs` below would hand the call site an
/// optional it would have to unwrap a second time.
pub const Device = struct {
    handle: vulkan.VkDevice,
    create_shader_module: vulkan.PFN_vkCreateShaderModule,
    destroy_shader_module: vulkan.PFN_vkDestroyShaderModule,
    /// The two fields of `vk.DeviceProcs` this file calls, taken from the
    /// device tier the loader filled (`src/vk/dispatch.zig:191`, `:209`).
    /// Nothing else about `DeviceProcs` is read here.
    ///
    /// The parameter is `device_procs` because `procs` is `Device.procs` below,
    /// and a parameter of that name would shadow it.
    pub fn init(device_procs: *const vk.DeviceProcs, handle: vulkan.VkDevice) Device {
        return .{
            .handle = handle,
            .create_shader_module = device_procs.create_shader_module,
            .destroy_shader_module = device_procs.destroy_shader_module,
        };
    }

    /// Both entry points or neither. `create` reads the pair so a module whose
    /// destroy is missing never exists, and `destroy` reads it for the same
    /// reason. Both are core 1.0, so a null pair is a loader defect.
    fn procs(self: *const Device) ?Procs {
        return .{
            .create = self.create_shader_module orelse return null,
            .destroy = self.destroy_shader_module orelse return null,
        };
    }
};

/// The two function pointers, non-null once `Device.procs` has answered.
const Procs = struct {
    create: std.meta.Child(vulkan.PFN_vkCreateShaderModule),
    destroy: std.meta.Child(vulkan.PFN_vkDestroyShaderModule),
};

/// Why a module could not be created or could not be undone.
pub const CreateError = error{
    /// The device tier did not load `vkCreateShaderModule` or
    /// `vkDestroyShaderModule`. Both are core 1.0 entry points, so a tier that
    /// missed one is a broken loader and not a device limitation.
    MissingShaderModuleProc,

    /// Dawn reports `VK_ERROR_UNKNOWN` from this call as
    /// `DAWN_PIPELINE_UNCATEGORIZED_ERROR` (`ShaderModuleVk.cpp:512-514`) and
    /// every other code through `CheckVkSuccess` (`:516`). The port names the
    /// one code Dawn special-cases; `core/errors.zig:245` carries the same
    /// classification for the error a device reports upward.
    PipelineUncategorized,
} || vk.Error;

/// Creates the Vulkan shader module over `words`.
///
/// The two create-info fields that matter are set exactly as Dawn sets them
/// (`ShaderModuleVk.cpp:500-501`) and they are the whole port claim: the byte
/// count is the word count times four, and `pCode` is the caller's words.
pub fn create(device: *const Device, words: []const spirv.Word) CreateError!vulkan.VkShaderModule {
    const procs = device.procs() orelse return error.MissingShaderModuleProc;

    const create_info: vulkan.VkShaderModuleCreateInfo = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .codeSize = words.len * @sizeOf(spirv.Word),
        .pCode = words.ptr,
    };

    var handle: vulkan.VkShaderModule = null;
    const result = procs.create(device.handle, &create_info, null, &handle);
    try checkResult(result);

    // Dawn asserts the same at `ShaderModuleVk.cpp:519`. A `VK_SUCCESS` from
    // `vkCreateShaderModule` writes a handle, so a null one is a driver defect
    // and not a case to hand back.
    std.debug.assert(handle != null);
    return handle;
}

/// Releases the handle. Dawn's destroy lives in `DeviceVk.cpp`'s teardown and
/// not here, because Dawn's handle belongs to a pipeline; the port's belongs to
/// the module, so the module's owner calls this and reads the answer.
pub fn destroy(device: *const Device, handle: vulkan.VkShaderModule) CreateError!void {
    const procs = device.procs() orelse return error.MissingShaderModuleProc;
    procs.destroy(device.handle, handle, null);
}

/// One read of the result, with the code Dawn special-cases named first.
fn checkResult(code: vulkan.VkResult) CreateError!void {
    if (code == vulkan.VK_ERROR_UNKNOWN) return error.PipelineUncategorized;
    return vk.checkVkSuccess(code);
}
