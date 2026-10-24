//! The sampler: the descriptor rules and the object.
//!
//! **What this file is.** `native/Sampler.{h,cpp}`: the descriptor rules at
//! `src/dawn/native/Sampler.cpp:40`, the ten accessors at
//! `src/dawn/native/Sampler.h:58-67`, and the three answers a bind group asks
//! of a sampler, which are the three answers at `Sampler.cpp:142`, `:146` and
//! `:151`.
//!
//! Native samplers keep this same core header and own their Vulkan handles.
//! The per-device weak cache lives in `native_resource_store.zig`.
//! Core-only creation produces metadata with no native handles.

const std = @import("std");

const api = @import("../api/api.zig");
const descriptors = api.descriptors;
const enums = api.enums;
const objects = api.objects;

const core_errors = @import("../core/errors.zig");
const device = @import("../core/device.zig");
const handle = @import("../core/handle.zig");
const object = @import("../core/object.zig");
const native_backend = @import("native_sampler_backend.zig");

pub const SemanticKey = native_backend.SemanticKey;
pub const NativeBackend = native_backend.Backend;
pub const NativePayload = native_backend.Payload;
pub const NativeError = native_backend.Error;

/// Every way `createSampler` can fail. The set is named rather than inferred so
/// a reader enumerates the obligations from the signature.
pub const CreateError = core_errors.ValidationError || object.CreateError;
pub const NativeCreateError = CreateError || NativeError;

/// Validates ordinary semantics, excludes labels, and gives signed zero one representation.
/// Conversion presence and every supplied conversion field remain part of identity.
pub fn semanticKey(descriptor: descriptors.SamplerDescriptorChain) CreateError!SemanticKey {
    var ordinary: descriptors.SamplerDescriptor = undefined;
    inline for (@typeInfo(descriptors.SamplerDescriptor).@"struct".field_names) |field_name| {
        @field(ordinary, field_name) = @field(descriptor, field_name);
    }
    try validateSamplerDescriptor(ordinary);
    return .{
        .address_mode_u = descriptor.address_mode_u,
        .address_mode_v = descriptor.address_mode_v,
        .address_mode_w = descriptor.address_mode_w,
        .mag_filter = descriptor.mag_filter,
        .min_filter = descriptor.min_filter,
        .mipmap_filter = descriptor.mipmap_filter,
        .lod_min_clamp = if (descriptor.lod_min_clamp == 0) 0 else descriptor.lod_min_clamp,
        .lod_max_clamp = if (descriptor.lod_max_clamp == 0) 0 else descriptor.lod_max_clamp,
        .compare_function = descriptor.compare,
        .max_anisotropy = descriptor.max_anisotropy,
        .y_cb_cr = descriptor.y_cb_cr_vk_descriptor,
    };
}

/// A sampler as the engine holds it.
///
/// Dawn's `SamplerBase` is a `CachedObject`, so its fields are private and the
/// class is read through accessors. The port is an arena object with public
/// fields (`docs/10-architecture.md`, Object model), and the accessors below
/// are the named reads the callers use.
pub const Sampler = struct {
    header: object.Object,

    address_mode_u: enums.AddressMode,
    address_mode_v: enums.AddressMode,
    address_mode_w: enums.AddressMode,
    mag_filter: enums.FilterMode,
    min_filter: enums.FilterMode,
    mipmap_filter: enums.MipmapFilterMode,
    lod_min_clamp: f32,
    lod_max_clamp: f32,
    compare_function: enums.CompareFunction,
    max_anisotropy: u16,
    key: SemanticKey,
    /// Null means this object is genuine core-only metadata.
    native: ?NativePayload = null,
    cleanup_error: ?NativeError = null,
    cache_hash: u64 = 0,
    cache_next: ?*Sampler = null,

    /// Creates one owned user reference after guarded allocator and descriptor checks.
    /// On failure no object or reference is published. Release the result under its guard.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        guard: *const object.ObjectGuard,
        dev: *device.Device,
        descriptor: descriptors.SamplerDescriptor,
    ) CreateError!objects.Sampler {
        try dev.arena.checkAllocator(guard, gpa);
        var chain: descriptors.SamplerDescriptorChain = .{ .compare = descriptor.compare };
        inline for (@typeInfo(descriptors.SamplerDescriptor).@"struct".field_names) |field_name| {
            @field(chain, field_name) = @field(descriptor, field_name);
        }
        const key = try semanticKey(chain);
        const sampler = try dev.create(gpa, guard, Sampler, .{
            .kind = .sampler,
            .state = .initializing,
            .initial_reference = .user,
            .label = descriptor.label orelse "",
        });

        sampler.initializePayload(key, null);
        sampler.header.setInitializedNoError(guard);
        sampler.header.attach(guard, io);
        return .{ .handle = @ptrCast(dev.handleFor(guard, Sampler, sampler, .sampler).ptr) };
    }

    /// Creates one actual sampler owner under the original arena guard.
    /// Native rollback finishes before failure returns. No header attaches on failure.
    /// The result owns one user alias; its borrowed backend survives final payload retirement.
    pub fn createNative(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const object.ObjectGuard,
        arena: *object.ObjectArena,
        backend: NativeBackend,
        descriptor: descriptors.SamplerDescriptorChain,
    ) NativeCreateError!*Sampler {
        try arena.checkAllocator(guard, allocator);
        if (arena.objectList().marked_destroyed) return error.ResourceDestroyed;
        const key = try semanticKey(descriptor);
        var native = try NativePayload.create(backend, key);
        errdefer native.destroy() catch |err| backend.recordCleanup(err);
        const sampler = try arena.create(allocator, guard, Sampler, .{
            .kind = .sampler,
            .state = .initializing,
            .initial_reference = .user,
            .label = descriptor.label orelse "",
        });
        sampler.initializePayload(key, native);
        sampler.header.setInitializedNoError(guard);
        sampler.header.attach(guard, io);
        return sampler;
    }

    fn initializePayload(self: *Sampler, key: SemanticKey, native: ?NativePayload) void {
        self.address_mode_u = key.address_mode_u;
        self.address_mode_v = key.address_mode_v;
        self.address_mode_w = key.address_mode_w;
        self.mag_filter = key.mag_filter;
        self.min_filter = key.min_filter;
        self.mipmap_filter = key.mipmap_filter;
        self.lod_min_clamp = key.lod_min_clamp;
        self.lod_max_clamp = key.lod_max_clamp;
        self.compare_function = key.compare_function;
        self.max_anisotropy = key.max_anisotropy;
        self.key = key;
        self.native = native;
        self.cleanup_error = null;
        self.cache_hash = 0;
        self.cache_next = null;
    }

    /// The address mode on the `u` axis, `Sampler.h:58`.
    pub fn getAddressModeU(self: *const Sampler, guard: *const object.ObjectGuard) enums.AddressMode {
        guard.assertOwns(self.header.tracking);
        return self.address_mode_u;
    }

    /// The address mode on the `v` axis, `Sampler.h:59`.
    pub fn getAddressModeV(self: *const Sampler, guard: *const object.ObjectGuard) enums.AddressMode {
        guard.assertOwns(self.header.tracking);
        return self.address_mode_v;
    }

    /// The address mode on the `w` axis, `Sampler.h:60`.
    pub fn getAddressModeW(self: *const Sampler, guard: *const object.ObjectGuard) enums.AddressMode {
        guard.assertOwns(self.header.tracking);
        return self.address_mode_w;
    }

    /// The magnification filter, `Sampler.h:61`.
    pub fn getMagFilter(self: *const Sampler, guard: *const object.ObjectGuard) enums.FilterMode {
        guard.assertOwns(self.header.tracking);
        return self.mag_filter;
    }

    /// The minification filter, `Sampler.h:62`.
    pub fn getMinFilter(self: *const Sampler, guard: *const object.ObjectGuard) enums.FilterMode {
        guard.assertOwns(self.header.tracking);
        return self.min_filter;
    }

    /// The mipmap filter, `Sampler.h:63`.
    pub fn getMipmapFilter(
        self: *const Sampler,
        guard: *const object.ObjectGuard,
    ) enums.MipmapFilterMode {
        guard.assertOwns(self.header.tracking);
        return self.mipmap_filter;
    }

    /// The lower LOD bound, `Sampler.h:64`.
    pub fn getLodMinClamp(self: *const Sampler, guard: *const object.ObjectGuard) f32 {
        guard.assertOwns(self.header.tracking);
        return self.lod_min_clamp;
    }

    /// The upper LOD bound, `Sampler.h:65`.
    pub fn getLodMaxClamp(self: *const Sampler, guard: *const object.ObjectGuard) f32 {
        guard.assertOwns(self.header.tracking);
        return self.lod_max_clamp;
    }

    /// The comparison function, `Sampler.h:66`.
    pub fn getCompareFunction(
        self: *const Sampler,
        guard: *const object.ObjectGuard,
    ) enums.CompareFunction {
        guard.assertOwns(self.header.tracking);
        return self.compare_function;
    }

    /// The anisotropy sample count, `Sampler.h:67`.
    pub fn getMaxAnisotropy(self: *const Sampler, guard: *const object.ObjectGuard) u16 {
        guard.assertOwns(self.header.tracking);
        return self.max_anisotropy;
    }

    /// A sampler with a comparison function samples with one. Dawn reads the
    /// comparison function for the answer at `Sampler.cpp:143`.
    pub fn isComparison(self: *const Sampler, guard: *const object.ObjectGuard) bool {
        guard.assertOwns(self.header.tracking);
        return self.compare_function != .undefined_;
    }

    /// A sampler is filtering when any one of its three filters is linear
    /// (`Sampler.cpp:146-149`). The question reads exactly three fields and
    /// there is no fourth, so there is no loop to bound.
    pub fn isFiltering(self: *const Sampler, guard: *const object.ObjectGuard) bool {
        guard.assertOwns(self.header.tracking);
        return self.min_filter == .linear or
            self.mag_filter == .linear or
            self.mipmap_filter == .linear;
    }

    /// What a bind group layout entry must say to bind this sampler. Dawn
    /// answers it once, at `Sampler.cpp:151-160`, and a layout stores the
    /// answer, so a bind group never re-derives it.
    pub fn bindingType(
        self: *const Sampler,
        guard: *const object.ObjectGuard,
    ) enums.SamplerBindingType {
        guard.assertOwns(self.header.tracking);
        if (self.isComparison(guard)) return .comparison;
        if (self.isFiltering(guard)) return .filtering;
        return .non_filtering;
    }

    /// Destroys native handles once; saves cleanup failure while arena aliases survive.
    pub fn destroy(
        self: *Sampler,
        guard: *const object.ObjectGuard,
        io: std.Io,
        reason: object.DestroyReason,
    ) void {
        guard.assertOwns(self.header.tracking);
        _ = io;
        _ = reason;
        if (self.native) |*native| native.destroy() catch |err| {
            self.cleanup_error = err;
            native.backend.recordCleanup(err);
        };
    }
};

/// The sampler the handle names, or the rule that rejects the handle.
///
/// **This is where the alignment comes back.** `src/api/objects.zig` is
/// generated and types every `handle` field `?*anyopaque`, so the guarantee
/// `core.Handle.ptr` carries is lost at the API boundary. It is asserted once
/// here, where the loss happens, rather than at every read of the handle.
/// `create` publishes the canonical header through `Device.handleFor`, preserving
/// its alignment; the assertion cannot fail for a handle this module produced.
pub fn resolveSampler(
    dev: *device.Device,
    guard: *const object.ObjectGuard,
    target: objects.Sampler,
) device.HandleError!*Sampler {
    const wrapped: handle.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .sampler,
    };
    return dev.resolve(guard, Sampler, wrapped);
}

/// The rules in `ValidateSamplerDescriptor` (`Sampler.cpp:40-94`).
///
/// The order is the order upstream checks in, so a descriptor that breaks two
/// rules reports the one upstream reports first.
pub fn validateSamplerDescriptor(
    descriptor: descriptors.SamplerDescriptor,
) core_errors.ValidationError!void {
    if (!std.math.isFinite(descriptor.lod_min_clamp)) return error.SamplerLodClampNotFinite;
    if (!std.math.isFinite(descriptor.lod_max_clamp)) return error.SamplerLodClampNotFinite;
    if (descriptor.lod_min_clamp < 0 or descriptor.lod_max_clamp < 0) {
        return error.SamplerLodClampNegative;
    }
    if (descriptor.lod_min_clamp > descriptor.lod_max_clamp) return error.SamplerLodMinAboveMax;

    // The two branches are exclusive, as upstream: above one all three filters
    // must be linear (`Sampler.cpp:52-59`), and zero is rejected on its own
    // (`Sampler.cpp:60-63`).
    if (descriptor.max_anisotropy > 1) {
        if (descriptor.min_filter != .linear or
            descriptor.mag_filter != .linear or
            descriptor.mipmap_filter != .linear)
        {
            return error.SamplerAnisotropyRequiresLinear;
        }
    } else if (descriptor.max_anisotropy == 0) {
        return error.SamplerAnisotropyBelowOne;
    }

    if (descriptor.min_filter == .undefined_) return error.SamplerFieldUndefined;
    if (descriptor.mag_filter == .undefined_) return error.SamplerFieldUndefined;
    if (descriptor.mipmap_filter == .undefined_) return error.SamplerFieldUndefined;
    if (descriptor.address_mode_u == .undefined_) return error.SamplerFieldUndefined;
    if (descriptor.address_mode_v == .undefined_) return error.SamplerFieldUndefined;
    if (descriptor.address_mode_w == .undefined_) return error.SamplerFieldUndefined;
}

comptime {
    // The fields the rules above read. A descriptor field that no rule reads is
    // a field the sampler drops on creation, and a silent loss is a defect, so
    // the build fails instead of the loss.
    const rule_fields = [_][]const u8{
        "min_filter",
        "mag_filter",
        "mipmap_filter",
        "address_mode_u",
        "address_mode_v",
        "address_mode_w",
        "compare",
        "lod_min_clamp",
        "lod_max_clamp",
        "max_anisotropy",
    };
    for (rule_fields) |name| {
        if (!@hasField(descriptors.SamplerDescriptor, name)) {
            @compileError("the sampler rules read a field the descriptor does not have");
        }
    }
}

fn samplerTestUncaptured(
    gpa: std.mem.Allocator,
    io: std.Io,
    context: *anyopaque,
    view: core_errors.ErrorView,
) void {
    _ = gpa;
    _ = io;
    _ = context;
    _ = view;
    @panic("unexpected sampler error callback");
}

test "sampler validation and allocator refusal leave no creator reference" {
    // Refusal happens before arena mutation; successful publication owns one user ref.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var dev = device.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = samplerTestUncaptured,
    });
    var guard = object.ObjectGuard.lockUncancelable(io, dev.borrow().objectList());
    defer guard.unlock(io);
    defer dev.deinit(gpa, &guard) catch @panic("sampler references leaked");
    var foreign_storage: [64]u8 = undefined;
    var foreign = std.heap.FixedBufferAllocator.init(&foreign_storage);
    try std.testing.expectError(error.AllocatorMismatch, Sampler.create(
        foreign.allocator(),
        io,
        &guard,
        &dev,
        .{ .compare = .never, .max_anisotropy = 0 },
    ));
    try std.testing.expectError(error.SamplerAnisotropyBelowOne, Sampler.create(
        gpa,
        io,
        &guard,
        &dev,
        .{ .compare = .never, .max_anisotropy = 0 },
    ));
    try std.testing.expectEqual(@as(usize, 0), dev.arena.queryCapacity(&guard));
    try std.testing.expectEqual(@as(u64, 0), dev.arena.objects.total_reference_count);
    try std.testing.expectEqual(@as(u64, 0), dev.arena.objects.user_reference_count);
    try std.testing.expectEqual(@as(usize, 0), dev.arena.queryTrackedCount(&guard));
    const target = try Sampler.create(gpa, io, &guard, &dev, .{ .compare = .never });
    const sampler = try resolveSampler(&dev, &guard, target);
    defer sampler.header.releaseUserLocked(&guard, io) catch @panic("sampler release failed");
    try std.testing.expectEqual(@as(u32, 1), sampler.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), sampler.header.user_reference_count);
    try std.testing.expect(sampler.header.reference_escaped);
    try std.testing.expectEqual(enums.SamplerBindingType.comparison, sampler.bindingType(&guard));
}
