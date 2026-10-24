//! Creating a shader module from the caller's SPIR-V, reflecting it, and
//! keeping the diagnostics.
//!
//! Ports `native/ShaderModule.{h,cpp}`. `docs/10-architecture.md` "Shaders"
//! fixes the flow: SPIR-V bytes, then `spirv.validate`, then `spirv.reflect`,
//! then a `vkCreateShaderModule` on the caller's own words. Dawn cannot take
//! that third step, so Dawn's record is built
//! around a `tint::Program` it must keep alive (`ShaderModule.h:113-118`) and
//! every reflection row in it reads that program (`ShaderModule.cpp:795`
//! and `:1314`). The port has the words, and nothing here holds a program.
//!
//! **What this file is.** Three records and four functions: the descriptor a
//! caller fills in, the module a create returns, the entry-point reflection a
//! pipeline binds against, and the diagnostics a failed create carries.
//!
//! **What this file does not claim.** It does not claim to be the device's
//! object. `src/core/handle.zig:38-48` has no `shader_module` kind byte, and the
//! arena that would own one is the device layer's (`core.Device.create`,
//! `src/core/device.zig:70`), so a module is a value whose lifetime belongs to
//! whoever created it and `destroy` gives it back. It does not claim a WGSL
//! front end, so `Descriptor` has no source-text field and
//! no `strictMath` (`ShaderModule.cpp:1997`): there is no compiler whose
//! arithmetic could be strict.

const std = @import("std");
const spirv = @import("../spirv/root.zig");
const shader_compilation_messages = @import("shader_compilation_messages.zig");
const shader_module_vk = @import("shader_module_vk.zig");
const shader_reflect = @import("shader_reflect.zig");
const vulkan = @import("vulkan");

pub const Device = shader_module_vk.Device;
pub const Layout = shader_reflect.Layout;
pub const MessageType = shader_compilation_messages.MessageType;
pub const Messages = shader_compilation_messages.Messages;

/// What a caller hands over.
///
/// The words are borrowed for the module's whole life, and the label with
/// them: `ShaderModule.cpp:1821` copies the caller's words into
/// `mOriginalSpirv`; the port reads the caller's slice instead.
pub const Descriptor = struct {
    label: ?[]const u8 = null,

    /// The caller's own words, and the words `vkCreateShaderModule` is given.
    /// Nothing between this field and `pCode` rewrites them.
    words: []const spirv.Word,
};

/// The descriptor of a module that could not be made.
///
/// Dawn's `ShaderModuleParseSpirvDescription`
/// (`ShaderModuleParseRequest.h:63-69`) carries one flag,
/// `allowNonUniformDerivatives`, and the port has no field for it: the only
/// consumer is Tint's non-uniform-derivative rule, reached through `ParseSPIRV`
/// (`ShaderModule.cpp:1532-1533`), and `src/spirv/validate.zig` has no rule
/// that reads it. A field no code reads is a lie to a caller.
pub const ErrorModuleDescriptor = struct {
    label: ?[]const u8 = null,

    /// The text the one message carries. Dawn takes a whole message list here
    /// (`ShaderModule.cpp:1883-1885`) because Tint produces one per diagnostic; the
    /// port's create pass names the rule that failed, which is one message.
    /// Copied at creation; the caller may mutate or release it afterward.
    message: []const u8,
};

/// Every way creating a module can fail: a rule the reader broke, an allocation
/// that was refused, and a driver or a loader that would not take the call.
pub const CreateError = spirv.ErrorOrOutOfMemory || shader_module_vk.CreateError;

/// The content hash upstream keeps in `mHash` and reads through
/// `ComputeContentHash` (`ShaderModule.cpp:2006-2011`).
/// Hashing uses the standard library.
pub const ContentHash = [std.crypto.hash.sha3.Sha3_256.digest_length]u8;

/// One entry point and what it declares. The name borrows `ShaderModule.words`;
/// the layout is owned.
pub const EntryPoint = struct {
    name: []const u8,

    /// Read out of the module's own `OpEntryPoint`. Dawn's counterpart is
    /// `EntryPointMetadata::stage` (`ShaderModule.h:297`), which arrives from
    /// Tint's IR through `TintPipelineStageToShaderStage`
    /// (`ShaderModule.cpp:63`).
    execution_model: spirv.ExecutionModel,

    /// The descriptor bindings this entry point declares, which is the
    /// `bindings` member of `EntryPointMetadata` (`ShaderModule.h:277`).
    layout: shader_reflect.Layout,
};

/// A created shader module.
///
/// The two outcomes are exclusive, exactly as Dawn asserts them
/// (`ShaderModule.cpp:1561`): a module that reached Vulkan has a handle and an
/// empty message record, and a failed module has a message and no handle.
pub const ShaderModule = struct {
    allocator: std.mem.Allocator,
    label: []const u8,

    /// The words `vkCreateShaderModule` was given, word for word what the
    /// descriptor carried.
    words: []const spirv.Word,

    entry_points: []EntryPoint,
    /// Owned metadata; names borrow `words`, as entry-point names do.
    specialization_constants: []spirv.SpecializationConstant = &.{},
    messages: Messages,
    hash: ContentHash,

    /// The Vulkan handle, and null for a failed module. Dawn hides this one
    /// inside its compiled state and creates it per entry point per pipeline at
    /// `ShaderModuleVk.cpp:130`; the port holds the caller's words at creation,
    /// so the handle exists here or never.
    vk_module: vulkan.VkShaderModule,

    /// Dawn tags a failed module with `ObjectBase::ErrorTag`
    /// (`ShaderModule.cpp:1867-1874`) and every use of one fails.
    failed: bool,

    /// The entry point named `name`, or null. Dawn has `HasEntryPoint`
    /// (`:1980`) and `GetEntryPoint` (`:2001`); the port has one lookup and
    /// answers null where Dawn asserts the name is there.
    pub fn findEntryPoint(self: *const ShaderModule, name: []const u8) ?EntryPoint {
        // Bound: the slice reflection built.
        for (self.entry_points) |entry_point| {
            if (std.mem.eql(u8, entry_point.name, name)) return entry_point;
        }
        return null;
    }

    /// How many entry points run on `execution_model`. Dawn's
    /// `GetEntryPointCount` (`ShaderModule.h:386`) counts per stage, and M14
    /// asks that question once per pipeline stage.
    pub fn countEntryPoints(
        self: *const ShaderModule,
        execution_model: spirv.ExecutionModel,
    ) usize {
        // Bound: the slice reflection built.
        var count: usize = 0;
        for (self.entry_points) |entry_point| {
            if (entry_point.execution_model == execution_model) count += 1;
        }
        return count;
    }

    /// Dawn's `EqualityFunc` (`ShaderModule.cpp:2013-2020`) compares the source
    /// and the flags around it and then asserts that the hashes agree with the
    /// members (`:2018`). The port has the words and nothing else, and it checks
    /// the hash and the words rather than assuming the hash implies them.
    pub fn eql(left: *const ShaderModule, right: *const ShaderModule) bool {
        return left.hash == right.hash and
            std.mem.eql(spirv.Word, left.words, right.words);
    }

    /// Releases everything the module owns: the Vulkan handle first, then the
    /// entry-point layouts, the entry-point slice and the messages.
    ///
    /// Dawn's destroy is `DestroyImpl` (`ShaderModule.cpp:1878`), which
    /// uncaches the blob. The port has no blob, so the handle and the
    /// allocations are the whole of it. A failed module has no handle and its
    /// owner passes no device; the pair is asserted at `:169`, and the
    /// destroy path states the half it depends on at `:178` instead of
    /// unwrapping it blind.
    pub fn destroy(
        self: *ShaderModule,
        device: ?*const shader_module_vk.Device,
    ) shader_module_vk.CreateError!void {
        std.debug.assert((self.vk_module == null) == (device == null));
        if (self.vk_module) |handle| {
            // `self.vk_module` is non-null in this branch, and the assert above
            // pairs the two, so `device` is non-null here too. A missing proc is
            // not what a null device would mean: that is a broken loader and
            // `shader_module_vk.destroy` reports a missing proc as a typed error.
            // A live handle must still have the device that created it.
            const owner = device orelse @panic("a module with a handle has no device");
            try shader_module_vk.destroy(owner, handle);
        }
        freeEntryPoints(self.allocator, self.entry_points);
        self.entry_points = &.{};
        self.allocator.free(self.specialization_constants);
        self.specialization_constants = &.{};
        self.messages.deinit();
    }
};

/// Creates a module and hands back a future for it.
/// The module comes out of the `await`, and an `Io` that cannot go concurrent
/// answers `error.ConcurrencyUnavailable` instead of quietly validating on the
/// calling thread.
/// SPIR-V above the device's core Vulkan limit fails before reflection or
/// native creation; no SPIR-V extension support is assumed.
pub fn createShaderModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *const shader_module_vk.Device,
    descriptor: Descriptor,
) std.Io.ConcurrentError!std.Io.Future(CreateError!ShaderModule) {
    return io.concurrent(validateAndCreate, .{ allocator, device, descriptor });
}

/// The failed module, for a caller that reports a shader failure of its own.
///
/// Ports `ShaderModuleBase::MakeError` (`ShaderModule.cpp:1883`) with the
/// error-tag constructor at `:1867`. There is no device and no handle: the
/// module records the message and every use of it fails, which is what
/// `createErrorShaderModule` in the generated API is for
/// (`src/api/objects.zig:390`).
pub fn createErrorShaderModule(
    allocator: std.mem.Allocator,
    descriptor: ErrorModuleDescriptor,
) std.mem.Allocator.Error!ShaderModule {
    const message = shader_compilation_messages.Message.unanchored(
        descriptor.message,
        .error_,
    );
    return .{
        .allocator = allocator,
        .label = descriptor.label orelse "",
        .words = &.{},
        .entry_points = &.{},
        .messages = try shader_compilation_messages.snapshot(allocator, &.{message}),
        // Dawn's error constructor never fills `mHash`
        // (`ShaderModule.cpp:1867`), so the port's is the zero digest and not
        // the hash of an empty word stream, which could collide with nothing
        // and mean nothing.
        .hash = @splat(0),
        .vk_module = null,
        .failed = true,
    };
}

/// What `getCompilationInfo` answers.
///
/// Ports `OwnedCompilationMessages::GetCompilationInfo`
/// (`CompilationMessages.cpp:271-273`), which returns the API graph the
/// constructor at `:236` built. The port's answer is a slice, and the generated
/// `api.CompilationInfoChain` (`src/api/descriptors.zig:492`) is the device
/// method layer's projection of it, because `pipeline` imports no API surface.
///
/// Borrows the module's item array and text until `destroy`. Do not call
/// `deinit` on this view. Use `snapshotCompilationInfo` to retain diagnostics.
pub fn getCompilationInfo(module: *const ShaderModule) Messages {
    return module.messages;
}

/// Owns a copy of the module's diagnostics, independent of module lifetime.
/// The module must stay alive and unchanged through the call. Release the
/// result once with `deinit`. Allocation or size overflow returns
/// `error.OutOfMemory` with no partial owner and leaves the module unchanged.
pub fn snapshotCompilationInfo(
    allocator: std.mem.Allocator,
    module: *const ShaderModule,
) std.mem.Allocator.Error!Messages {
    return Messages.clone(allocator, module.messages);
}

/// The log text, or an empty string when there is nothing to report.
///
/// Ports `ShaderModuleBase::GetCompilationLog` (`ShaderModule.cpp:2112-2126`),
/// which answers `""` for a module with no warning and no error (`:2114-2116`)
/// and otherwise a header naming the module followed by the formatted messages.
pub fn getCompilationLog(
    allocator: std.mem.Allocator,
    module: *const ShaderModule,
) std.mem.Allocator.Error![]u8 {
    // Nothing to report is the empty log, which is what Dawn answers
    // (`ShaderModule.cpp:2114-2116`). Binding the payload here, where the
    // formatter's null is answered, is what leaves the loop below with a slice
    // rather than an optional it has to unwrap again.
    const formatted = try shader_compilation_messages.formattedLog(allocator, module.messages) orelse
        return allocator.dupe(u8, "");

    var log: std.ArrayList(u8) = .empty;
    errdefer log.deinit(allocator);
    try log.print(allocator, "Compilation log for {s}:\n", .{module.label});
    // Bound: the slice the formatter allocated.
    for (formatted) |byte| {
        try log.append(allocator, byte);
    }
    const owned = try log.toOwnedSlice(allocator);
    return owned;
}

/// The bytes of `words` as one content hash.
///
/// Dawn hashes the source, the source's length and every flag around it
/// (`ShaderModule.cpp:1839-1857`), because its key is a blob-cache key that
/// must separate two descriptors differing only in a flag. The port's
/// descriptor has the words and a label, and a label is not content: Dawn does
/// not hash it either.
pub fn contentHash(words: []const spirv.Word) ContentHash {
    var hasher: std.crypto.hash.sha3.Sha3_256 = .init(.{});
    hasher.update(std.mem.sliceAsBytes(words));
    // SAFETY: `Sha3_256.final` is an out-parameter call: it writes all
    // `digest_length` bytes of the slice before the statement returns, and
    // the `return` below is the first read.
    var digest: ContentHash = undefined;
    hasher.final(&digest);
    return digest;
}

/// The three steps, in the order `docs/10-architecture.md` "Shaders" fixes:
/// validate, reflect, then hand the caller's own words to Vulkan.
fn validateAndCreate(
    allocator: std.mem.Allocator,
    device: *const shader_module_vk.Device,
    descriptor: Descriptor,
) CreateError!ShaderModule {
    // Dawn validates first and parses only when the words are sound
    // (`ShaderModule.cpp:1522-1534`), and reflects last (`:1554-1556`).
    try device.validateSpirvVersion(descriptor.words);
    try spirv.validate(descriptor.words);

    var reflected = try spirv.reflect(allocator, descriptor.words);
    // The names reflection returned borrow the caller's words, so they outlive
    // this scope; the resource slices are its own and go back here.
    defer reflected.deinit();

    const entry_points = try readEntryPoints(allocator, reflected.entry_points);
    errdefer freeEntryPoints(allocator, entry_points);

    // Last, because a Vulkan handle is not something an `errdefer` can unwind
    // and one must not leak when a later step fails.
    const vk_module = try shader_module_vk.create(device, descriptor.words);
    const specialization_constants = reflected.specialization_constants;
    reflected.specialization_constants = &.{};

    return .{
        .allocator = allocator,
        .label = descriptor.label orelse "",
        .words = descriptor.words,
        .entry_points = entry_points,
        .specialization_constants = specialization_constants,
        .messages = shader_compilation_messages.empty(allocator),
        .hash = contentHash(descriptor.words),
        .vk_module = vk_module,
        .failed = false,
    };
}

/// One `EntryPoint` per entry point the module declares, in declaration order,
/// which is the order `spirv.reflect` returned them in.
///
/// Ports `ReflectEntryPointUsingTint` (`ShaderModule.cpp:795`), which builds one
/// `EntryPointMetadata` per entry point out of Tint's inspector.
fn readEntryPoints(
    allocator: std.mem.Allocator,
    reflected: []const spirv.EntryPoint,
) spirv.ErrorOrOutOfMemory![]EntryPoint {
    var entry_points: std.ArrayList(EntryPoint) = .empty;
    errdefer deinitEntryPoints(allocator, &entry_points);

    // Bound: the slice reflection returned.
    for (reflected) |entry_point| {
        const layout = try shader_reflect.layoutFromResources(allocator, entry_point.resources);
        errdefer layout.deinit();

        try entry_points.append(allocator, .{
            .name = entry_point.name,
            .execution_model = entry_point.execution_model,
            .layout = layout,
        });
    }
    return entry_points.toOwnedSlice(allocator);
}

/// The error path for the list, whose memory the `ArrayList` still owns.
fn deinitEntryPoints(
    allocator: std.mem.Allocator,
    entry_points: *std.ArrayList(EntryPoint),
) void {
    // Bound: the slice the list holds.
    for (entry_points.items) |entry_point| entry_point.layout.deinit();
    entry_points.deinit(allocator);
}

/// Releases what `readEntryPoints` built. An empty slice is the static one
/// `toOwnedSlice` hands back for a list that never grew, and a static slice is
/// not the allocator's to free (`src/spirv/reflect.zig:152-153`).
fn freeEntryPoints(allocator: std.mem.Allocator, entry_points: []EntryPoint) void {
    if (entry_points.len == 0) return;
    // Bound: the slice reflection built.
    for (entry_points) |entry_point| entry_point.layout.deinit();
    allocator.free(entry_points);
}
