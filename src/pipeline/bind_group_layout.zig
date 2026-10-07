//! The bind group layout a caller holds: a label, a compatibility token, and
//! the packed layout `layout_internal.zig` builds.
//!
//! **What this file is.** The port of `native/BindGroupLayout.{h,cpp}` at Dawn
//! `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. Dawn's frontend layout holds a
//! reference to a deduplicated internal layout and one `u64` token
//! (`BindGroupLayout.h:69`-`:72`); the port holds the packed layout by value
//! and gives it back to the caller to free, because `AGENTS.md` §1 fixes the
//! allocator as a parameter and the arena as M3's, not this file's.
//!
//! **The token, and what it decides.** `PipelineCompatibilityToken` is a
//! `TypedInteger` over `u64` (`src/dawn/native/IntegerTypes.h:139`-`:140`).
//! Zero is `kExplicitPCT`, reserved for a layout a caller wrote
//! (`IntegerTypes.h:140`). A layout deduced from a pipeline's shader carries a
//! non-zero token, and `ValidatePipelineLayoutDescriptor` refuses to mix the
//! two (`PipelineLayout.cpp:122`-`:125`). The port mints tokens from
//! `TokenCounter`, which is Dawn's device-atomic counter at `Device.cpp:283`
//! and `GetNextPipelineCompatibilityToken` at `Device.cpp:2522`-`:2524`.
//!
//! **What this file does not claim.** It does not claim Dawn's content-hash
//! dedup, which makes two equal layouts the same object; M14 owns that cache.
//! Two layouts built from equal descriptors compare equal here, which is what
//! the cache needs and is not the same claim.

const std = @import("std");
const layout_internal = @import("layout_internal.zig");

pub const ShaderStages = layout_internal.ShaderStages;
pub const BufferBindingType = layout_internal.BufferBindingType;
pub const SamplerBindingType = layout_internal.SamplerBindingType;
pub const TextureSampleType = layout_internal.TextureSampleType;
pub const TextureViewDimension = layout_internal.TextureViewDimension;
pub const StorageTextureAccess = layout_internal.StorageTextureAccess;
pub const TexelBufferAccess = layout_internal.TexelBufferAccess;
pub const StaticSamplerUse = layout_internal.StaticSamplerUse;
pub const Entry = layout_internal.Entry;
pub const EntryKind = layout_internal.EntryKind;
pub const Binding = layout_internal.Binding;
pub const BindingLayout = layout_internal.BindingLayout;
pub const BindingIndex = layout_internal.BindingIndex;
pub const ApiBindingIndex = layout_internal.ApiBindingIndex;
pub const BindingCounts = layout_internal.BindingCounts;
pub const ValidateOptions = layout_internal.ValidateOptions;
pub const max_bindings_per_bind_group = layout_internal.max_bindings_per_bind_group;

/// An identifier that says which pipeline a layout is compatible with.
/// `PipelineCompatibilityToken` (`src/dawn/native/IntegerTypes.h:139`-`:140`).
/// The port keeps the width and drops the wrapper, because the wrapper exists
/// to stop a token being compared against an id and a bare `u64` cannot be
/// compared against anything else at a call site the type checker sees.
pub const PipelineCompatibilityToken = u64;

/// `kExplicitPCT`, the token every caller-created layout carries
/// (`IntegerTypes.h:140`). A deduced layout mints a non-zero one, so the two can
/// never be equal and a deduced layout can never be mixed with a written one.
pub const explicit_compatibility_token: PipelineCompatibilityToken = 0;

/// The device-atomic counter Dawn mints tokens from
/// (`Device.cpp:283`, `:2522`-`:2524`). The port keeps the counter in the
/// object that owns it rather than in a file-scope global, because
/// `AGENTS.md` §2 makes hidden state a review finding.
pub const TokenCounter = struct {
    /// Dawn starts the counter at one so that the first token is not the
    /// explicit token (`Device.cpp:283`).
    next_token: PipelineCompatibilityToken = 1,

    pub const MintError = error{TokenCounterExhausted};

    /// Hands out the next token. Ports `GetNextPipelineCompatibilityToken`
    /// (`Device.cpp:2522`).
    pub fn mint(self: *TokenCounter) MintError!PipelineCompatibilityToken {
        const token = self.next_token;
        // The counter wraps only after every u64 has been handed out, which no
        // device reaches; a silent wrap would reuse a live token, so it is an
        // error instead.
        if (token == std.math.maxInt(PipelineCompatibilityToken)) {
            return error.TokenCounterExhausted;
        }
        self.next_token += 1;
        return token;
    }
};

pub const Error = layout_internal.Error || TokenCounter.MintError;

/// One bind group layout. `BindGroupLayoutBase`
/// (`BindGroupLayout.h:41`), with `Ref<BindGroupLayoutInternalBase>` replaced
/// by an owned packed layout.
pub const BindGroupLayout = struct {
    internal: layout_internal.Layout,
    compatibility_token: PipelineCompatibilityToken,
    label: []const u8,

    /// Creates one layout. Ports `DeviceBase::GetOrCreateBindGroupLayout`
    /// (`Device.cpp:1039`-`:1057`) with `BindGroupLayoutInternalBase`'s
    /// constructor (`BindGroupLayoutInternal.cpp:766`-`:771`).
    ///
    /// `compatibility_token` is `explicit_compatibility_token` for a layout a
    /// caller wrote, and a token from `TokenCounter` for one deduced from a
    /// pipeline's shader.
    pub fn init(
        allocator: std.mem.Allocator,
        descriptor: layout_internal.Descriptor,
        compatibility_token: PipelineCompatibilityToken,
        options: ValidateOptions,
    ) Error!BindGroupLayout {
        return .{
            .internal = try layout_internal.Layout.init(allocator, descriptor, options),
            .compatibility_token = compatibility_token,
            .label = descriptor.label,
        };
    }

    pub fn deinit(self: *BindGroupLayout, allocator: std.mem.Allocator) void {
        self.internal.deinit(allocator);
        self.* = undefined;
    }

    /// `GetPipelineCompatibilityToken` (`BindGroupLayout.h:56`).
    pub fn pipelineCompatibilityToken(
        self: *const BindGroupLayout,
    ) PipelineCompatibilityToken {
        return self.compatibility_token;
    }

    /// `IsLayoutEqual` (`BindGroupLayout.cpp:67`): the token first, then the
    /// internal layout. `exclude_compatibility_token` is what the implicit
    /// layout cache needs (`Device.cpp:2152`), where a pipeline may reach its
    /// own deduced layout through a different token.
    pub fn isLayoutEqual(
        self: *const BindGroupLayout,
        other: *const BindGroupLayout,
        exclude_compatibility_token: bool,
    ) bool {
        if (!exclude_compatibility_token and
            self.compatibility_token != other.compatibility_token)
        {
            return false;
        }
        return layout_internal.Layout.eql(&self.internal, &other.internal);
    }

    /// `IsEmpty` (`BindGroupLayout.cpp:53`).
    pub fn isEmpty(self: *const BindGroupLayout) bool {
        return self.internal.isEmpty();
    }

    /// `GetBindingCount` (`BindGroupLayoutInternal.h:136`-`:137`): the number of
    /// user-facing entries, which is not the stored count when an external
    /// texture grew private entries in.
    pub fn queryBindingCount(self: *const BindGroupLayout) u32 {
        return self.internal.queryBindingCount();
    }

    /// The stored entry at a whole-vector index.
    pub fn binding(self: *const BindGroupLayout, index: BindingIndex) *const Binding {
        return self.internal.binding(index);
    }

    /// The stored entry at a user-facing index, or null for a private one.
    pub fn apiBinding(
        self: *const BindGroupLayout,
        index: ApiBindingIndex,
    ) ?*const Binding {
        return self.internal.apiBinding(index);
    }

    /// The entry a caller wrote at one binding number, or null. A caller that
    /// reflects a shader needs exactly this: a set, a binding number and a
    /// kind, with no index in between.
    pub fn findBindingByNumber(
        self: *const BindGroupLayout,
        binding_number: u32,
    ) ?*const Binding {
        return self.internal.findBindingByNumber(binding_number);
    }

    /// Every stored entry of one order.
    pub fn bindingsOfType(
        self: *const BindGroupLayout,
        order: layout_internal.BindingTypeOrder,
    ) []const Binding {
        return self.internal.bindingsOfType(order);
    }

    /// The counts `ValidatePipelineLayoutDescriptor` accumulates
    /// (`PipelineLayout.cpp:127`-`:128`).
    pub fn validationCounts(self: *const BindGroupLayout) BindingCounts {
        return self.internal.validation_counts;
    }

    /// `ComputeContentHash` (`BindGroupLayoutInternal.cpp:835`).
    pub fn contentHash(self: *const BindGroupLayout) u64 {
        return self.internal.content_hash;
    }

    /// `GetDynamicStorageBufferCount`, the counter
    /// `Constants.h:114` bounds.
    pub fn dynamicStorageBufferCount(self: *const BindGroupLayout) u32 {
        return self.internal.dynamic_storage_buffer_count;
    }

    /// `GetUnverifiedBufferCount`, the buffers whose minimum size is zero.
    pub fn unverifiedBufferCount(self: *const BindGroupLayout) u32 {
        return self.internal.unverified_buffer_count;
    }
};

// Every rule a bind group layout can report reaches a caller through this set.
// The `errors.ValidationError` members come from `src/core/errors.zig`, which
// M11 extended; the layout's own members are declared in `layout_internal.zig`
// because the packed layout is what enforces them.
comptime {
    // `AGENTS.md` §3 asks for a compile-time sweep over an error domain. A rule
    // the packed layout can report but this set cannot would reach no caller,
    // so every one of them is checked for membership here.
    //
    // The two lists are walked together rather than one rule against every
    // exposed member. A joined error set appends the members it adds, so the
    // packed rules are a prefix of the exposed rules and one pass of
    // comparisons covers the whole domain. The nested form does not fit: the
    // comptime branch quota is spent by the byte loop inside `std.mem.eql`,
    // and seventy-eight rules against seventy-nine members is six thousand
    // calls, so the sweep runs out of quota inside a single comparison. A set
    // that lost its packed prefix fails here loudly rather than silently, and
    // the member it names is the first rule out of place.
    const packed_rules = @typeInfo(layout_internal.Error).error_set.?;
    const exposed_rules = @typeInfo(Error).error_set.?;
    if (exposed_rules.len < packed_rules.len) {
        @compileError(std.fmt.comptimePrint(
            "the exposed error set has {d} members and the packed layout has {d}",
            .{ exposed_rules.len, packed_rules.len },
        ));
    }
    var swept_count: usize = 0;
    for (packed_rules, exposed_rules[0..packed_rules.len]) |rule, exposed| {
        if (!exposedNames(exposed.name, rule.name)) {
            @compileError("a packed-layout rule is not in the exposed error set: " ++ rule.name);
        }
        swept_count += 1;
    }
    // The sweep has to reach every member of the domain, and a loop that
    // stopped short of it would still be green on the rules it skipped. The
    // count names what was walked, so a narrowed loop fails here instead of
    // losing coverage quietly. Zig 0.16 has no `assert` builtin, so the
    // relationship is stated as a compile error rather than a trap.
    if (swept_count != packed_rules.len) {
        @compileError(std.fmt.comptimePrint(
            "the packed-rule sweep walked {d} of {d} members",
            .{ swept_count, packed_rules.len },
        ));
    }
}

/// The one comparison the sweep makes per member, and one call rather than an
/// expression in the loop body so the per-member work is a single line.
fn exposedNames(member_name: []const u8, packed_name: []const u8) bool {
    return std.mem.eql(u8, member_name, packed_name);
}
