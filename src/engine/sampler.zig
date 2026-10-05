//! The sampler: the descriptor rules and the object.
//!
//! **What this file is.** `native/Sampler.{h,cpp}`: the descriptor rules at
//! `src/dawn/native/Sampler.cpp:40`, the ten accessors at
//! `src/dawn/native/Sampler.h:58-67`, and the three answers a bind group asks
//! of a sampler, which are the three answers at `Sampler.cpp:142`, `:146` and
//! `:151`.
//!
//! **What this file does not claim.** It does not claim the content cache.
//! `ComputeContentHash` (`Sampler.cpp:171`) and `EqualityFunc`
//! (`Sampler.cpp:192`) exist for `CachedObject`, an unordered map keyed on the
//! content hash, and that map belongs to the milestone that owns the object
//! cache. It does not claim the Vulkan sampler either: `SamplerVk.cpp` is the
//! replay. It does not claim the YCbCr rules at `Sampler.cpp:74-91`; they are
//! gated on `Feature::YCbCrVulkanSamplers`, which the feature table owns, and a
//! rule that cannot read its feature is not a rule.

const std = @import("std");

const api = @import("../api/api.zig");
const descriptors = api.descriptors;
const enums = api.enums;
const objects = api.objects;

const core_errors = @import("../core/errors.zig");
const device = @import("../core/device.zig");
const handle = @import("../core/handle.zig");
const object = @import("../core/object.zig");

/// Every way `createSampler` can fail. The set is named rather than inferred so
/// a reader enumerates the obligations from the signature (`AGENTS.md` §2).
pub const CreateError = core_errors.ValidationError || std.mem.Allocator.Error;

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

    /// Creates a sampler, or reports the rule the descriptor broke.
    ///
    /// Dawn reaches a sampler that failed creation through the private
    /// constructor at `Sampler.cpp:124` and `MakeError` at `:134`, and guards
    /// every accessor with `IsError`. The port has one constructor and one
    /// state: a sampler whose descriptor was rejected is an arena object in the
    /// `failed` state, which is what `Object.setInitializedError` records and
    /// what `header.last_error` answers.
    pub fn create(
        dev: *device.Device,
        descriptor: descriptors.SamplerDescriptor,
    ) CreateError!objects.Sampler {
        const sampler = try dev.create(Sampler, .{
            .kind = .sampler,
            .state = .initializing,
            .label = descriptor.label orelse "",
        });

        // Both paths attach before they return. A rejected descriptor still
        // leaves a tracked object behind: `Device.deinit` is what runs its
        // teardown, and `attach` is the only call that puts it in that list.
        validateSamplerDescriptor(descriptor) catch |rule| {
            sampler.header.setInitializedError(rule);
            sampler.header.attach();
            return rule;
        };

        // Every field is written. The arena leaves the bytes after the header
        // undefined, so a field left out is a read of whatever was there.
        sampler.address_mode_u = descriptor.address_mode_u;
        sampler.address_mode_v = descriptor.address_mode_v;
        sampler.address_mode_w = descriptor.address_mode_w;
        sampler.mag_filter = descriptor.mag_filter;
        sampler.min_filter = descriptor.min_filter;
        sampler.mipmap_filter = descriptor.mipmap_filter;
        sampler.lod_min_clamp = descriptor.lod_min_clamp;
        sampler.lod_max_clamp = descriptor.lod_max_clamp;
        sampler.compare_function = descriptor.compare;
        sampler.max_anisotropy = descriptor.max_anisotropy;
        sampler.header.setInitializedNoError();
        // The state is written before the attach because `track` destroys an
        // object that arrives after the list is gone and marks it `destroyed`
        // (`src/core/object.zig:183-188`), and `setInitializedNoError` asserts
        // the header is still `initializing`.
        sampler.header.attach();
        return .{ .handle = @ptrCast(sampler) };
    }

    /// The address mode on the `u` axis, `Sampler.h:58`.
    pub fn getAddressModeU(self: *const Sampler) enums.AddressMode {
        return self.address_mode_u;
    }

    /// The address mode on the `v` axis, `Sampler.h:59`.
    pub fn getAddressModeV(self: *const Sampler) enums.AddressMode {
        return self.address_mode_v;
    }

    /// The address mode on the `w` axis, `Sampler.h:60`.
    pub fn getAddressModeW(self: *const Sampler) enums.AddressMode {
        return self.address_mode_w;
    }

    /// The magnification filter, `Sampler.h:61`.
    pub fn getMagFilter(self: *const Sampler) enums.FilterMode {
        return self.mag_filter;
    }

    /// The minification filter, `Sampler.h:62`.
    pub fn getMinFilter(self: *const Sampler) enums.FilterMode {
        return self.min_filter;
    }

    /// The mipmap filter, `Sampler.h:63`.
    pub fn getMipmapFilter(self: *const Sampler) enums.MipmapFilterMode {
        return self.mipmap_filter;
    }

    /// The lower LOD bound, `Sampler.h:64`.
    pub fn getLodMinClamp(self: *const Sampler) f32 {
        return self.lod_min_clamp;
    }

    /// The upper LOD bound, `Sampler.h:65`.
    pub fn getLodMaxClamp(self: *const Sampler) f32 {
        return self.lod_max_clamp;
    }

    /// The comparison function, `Sampler.h:66`.
    pub fn getCompareFunction(self: *const Sampler) enums.CompareFunction {
        return self.compare_function;
    }

    /// The anisotropy sample count, `Sampler.h:67`.
    pub fn getMaxAnisotropy(self: *const Sampler) u16 {
        return self.max_anisotropy;
    }

    /// A sampler with a comparison function samples with one. Dawn reads the
    /// comparison function for the answer at `Sampler.cpp:143`.
    pub fn isComparison(self: *const Sampler) bool {
        return self.compare_function != .undefined_;
    }

    /// A sampler is filtering when any one of its three filters is linear
    /// (`Sampler.cpp:146-149`). The question reads exactly three fields and
    /// there is no fourth, so there is no loop to bound.
    pub fn isFiltering(self: *const Sampler) bool {
        return self.min_filter == .linear or
            self.mag_filter == .linear or
            self.mipmap_filter == .linear;
    }

    /// What a bind group layout entry must say to bind this sampler. Dawn
    /// answers it once, at `Sampler.cpp:151-160`, and a layout stores the
    /// answer, so a bind group never re-derives it.
    pub fn bindingType(self: *const Sampler) enums.SamplerBindingType {
        if (self.isComparison()) return .comparison;
        if (self.isFiltering()) return .filtering;
        return .non_filtering;
    }

    /// Dawn's `DestroyImpl` (`Sampler.cpp:129`) only drops the cache entry,
    /// because the cache owns the reference. The port's arena owns the memory
    /// until `Device.deinit`, so there is nothing left to drop.
    pub fn destroy(self: *Sampler, reason: object.DestroyReason) void {
        _ = self;
        _ = reason;
    }
};

/// The sampler the handle names, or the rule that rejects the handle.
///
/// **This is where the alignment comes back.** `src/api/objects.zig` is
/// generated and types every `handle` field `?*anyopaque`, so the guarantee
/// `core.Handle.ptr` carries is lost at the API boundary. It is asserted once
/// here, where the loss happens, rather than at every read of the handle. The
/// only writer of that field is `create`, which returns `@ptrCast` of an arena
/// object, so the assertion cannot fail for a handle this module produced.
pub fn resolveSampler(dev: *device.Device, target: objects.Sampler) device.HandleError!*Sampler {
    const wrapped: handle.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .sampler,
    };
    return dev.resolve(Sampler, wrapped);
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
    if (descriptor.compare == .undefined_) return error.SamplerFieldUndefined;
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
