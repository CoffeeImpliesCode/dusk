//! The M16 shard: the compatibility profile, re-gated.
//!
//! **What this file is.** `docs/40-plan.md` §M16 names nine restrictions that
//! apply when the `core features and limits` feature is absent, and its
//! re-gate checklist says each must fail by a named error on a compatibility
//! device. This file drives all nine and names the error each one produces.
//!
//! **Why this is a milestone of its own.** M7 writes the compat column, M8
//! writes a device that reports it, M11 writes the texture rules, M14 writes
//! the pipeline and binding-count rules, and M15 writes the command rules. Each
//! of those could declare the profile done by construction alone. This file
//! asserts none of them: it takes a real compatibility device and asks each
//! validator to refuse a call Dawn refuses. A rule no caller can reach, or one
//! wired to the wrong flag, fails here.
//!
//! **The profile is a derived fact, not a flag.** Dawn derives compatibility
//! from the absence of a feature: `IsCompatibilityMode() { return
//! !HasFeature(Feature::CoreFeaturesAndLimits); }` (`Device.cpp:1840-1842`),
//! and the feature level is chosen on the adapter (`PhysicalDevice.cpp:55-57`,
//! `Adapter.cpp:56`). So the device here is built through `enumerateAdapters`
//! with `.feature_level = .compatibility`, and every validator is handed
//! `device.isCompatibilityMode()` rather than a literal `true`. A literal would
//! prove the validator and nothing else; the derived value proves the device
//! and the validator agree on which profile is in force.
//!
//! **What this file does not claim.** It does not claim the nine restrictions
//! are the whole profile: upstream carries 21 compat checks across the eight
//! re-gated files, and this shard asserts the nine §M16 names. It does not
//! claim a physical device, a driver or a `VkDevice`; every rule below is a
//! front-end validator reachable with none of them, which is what the split in
//! `docs/10-architecture.md` between `command`/`pipeline` and `engine` buys. It
//! does not claim the checks are enforced where §M16's table says: two of the
//! nine live outside the eight re-gated files, and the checklist records the
//! real site.
//!
//! **Two rows have narrower coverage.** Row 7 requests an sRGB view that the
//! texture did not declare in `view_formats`. Canonical linear and sRGB formats
//! share a view family, so this test does not establish the compatibility-only
//! declared-view restriction. Row 9 drives only texture-to-buffer copies.

const std = @import("std");

const dusk = @import("dusk");
const api = dusk.api;
const command = dusk.command;
const core = dusk.core;
const engine = dusk.engine;
const pipeline = dusk.pipeline;
const texture = engine.texture;

/// The compat storage-buffer ceilings at the pinned revision, read off the
/// compat column of the limit table (`src/dawn/native/Limits.cpp:95-96`):
/// four in the fragment stage and zero in the vertex stage.
///
/// The vertex value is the load-bearing one: it is why restriction 2 refuses a
/// single vertex-visible storage buffer rather than a count above a limit.
/// Dawn's own row for `maxStorageBuffersInVertexStage` is `:96`; §M16's table
/// cites `:80`, which is the *storage texture* row.
const compat_fragment_storage_buffer_limit: u32 = 4;
const compat_vertex_storage_buffer_limit: u32 = 0;

/// One past the fragment ceiling, so the count is out of range by exactly one.
const fragment_storage_buffer_count_over_limit: u32 =
    compat_fragment_storage_buffer_limit + 1;

/// Every error a restriction below can raise.
const RestrictionError = pipeline.PipelineError || texture.CreateError || command.Error;

/// One restriction from §M16's table, with the error it must produce.
///
/// The error is the assertion. A rule that refuses the call for a different
/// reason passes neither this table nor the test that reads it.
const Restriction = struct {
    number: u8,
    upstream_site: []const u8,
    failure: RestrictionError,
};

/// One row per restriction, in the order §M16 lists them.
///
/// Row 3 names only the first of Dawn's two depth-texture checks
/// (`Pipeline.cpp:138`); the second (`Pipeline.cpp:143`) has its own test.
/// `upstream_site` is the site §M16's table cites, not the one this shard
/// reaches: for row 7 those are different rules, and the file header says so.
const restrictions = [_]Restriction{
    .{
        .number = 1,
        .upstream_site = "BindingInfo.cpp:299",
        .failure = error.StorageBuffersInFragmentStageAboveLimit,
    },
    .{
        .number = 2,
        .upstream_site = "BindingInfo.cpp:309",
        .failure = error.StorageBuffersInVertexStageAboveLimit,
    },
    .{
        .number = 3,
        .upstream_site = "Pipeline.cpp:138",
        .failure = error.CompatibilityTextureLoadWithDepthTexture,
    },
    .{
        .number = 4,
        .upstream_site = "Pipeline.cpp:149",
        .failure = error.CompatibilityFineDerivativeBuiltin,
    },
    .{
        .number = 5,
        .upstream_site = "RenderPipeline.cpp:345",
        .failure = error.CompatibilityDepthBiasClampNonZero,
    },
    .{
        .number = 6,
        .upstream_site = "Texture.cpp:269",
        .failure = error.TextureViewDimensionNotCompatible,
    },
    .{
        .number = 7,
        .upstream_site = "Texture.cpp:66",
        .failure = error.TextureViewFormatNotInList,
    },
    .{
        .number = 8,
        .upstream_site = "CommandBufferStateTracker.cpp:396",
        .failure = error.ConflictingTextureViews,
    },
    .{
        .number = 9,
        .upstream_site = "CommandEncoder.cpp:413",
        .failure = error.CompressedTextureCopy,
    },
};

/// A device built the way a caller builds one: an instance, the null back end,
/// one adapter at a chosen feature level, and the device that adapter makes.
///
/// The instance is owned by value and the device holds a pointer to its
/// adapter, which points into the instance, so the whole struct must stay put.
/// `init` takes a `*Harness` for that reason and never returns one by value.
const Harness = struct {
    instance: engine.Instance,
    /// The device borrows the adapter list, which borrows the instance.
    adapters: engine.AdapterList,
    device: engine.Device,
    object_mutex: std.Io.Mutex = .init,
    /// The compatibility rules in this shard return their error to the caller.
    /// None reports one through the device's error sink, so a non-zero count
    /// here means a rule double-reported: an `expectError` could then pass on an
    /// unrelated error and prove nothing.
    uncaptured_error_count: u64 = 0,

    fn init(
        self: *Harness,
        allocator: std.mem.Allocator,
        level: api.FeatureLevel,
    ) !void {
        self.* = .{
            .instance = engine.Instance.init(.{ .backend_type = .null_ }),
            // SAFETY: `enumerateAdapters` writes `adapters` on its next
            // statement and `createDevice` writes `device` before the last
            // one, so no read sees either field before its own writer; the
            // `errdefer` at `:188` releases `adapters` if the device is
            // refused.
            .adapters = undefined,
            // SAFETY: `createDevice` on the last statement of `init` writes
            // `device` before this function returns, so nothing reads the
            // field while it is still undefined.
            .device = undefined,
        };
        errdefer self.instance.deinit(allocator, std.testing.io) catch @panic("compatibility instance rollback failed");

        self.adapters = try self.instance.enumerateAdapters(allocator, std.testing.io, .{
            .feature_level = level,
            .power_preference = .undefined_,
            // The instance was built on the null back end, and
            // `backendOf` (`src/engine/instance.zig:250`) prefers the named
            // back end over the instance's, so the request says the same
            // thing the caller already chose at `.init` (`:164`).
            .backend_type = .null_,
        });
        // The device holds a pointer into the list, so a device the adapter
        // refuses must still release it.
        errdefer self.adapters.deinit(std.testing.io) catch @panic("compatibility adapter rollback failed");

        // The null back end always reports exactly one (`DeviceNull.cpp:147-158`),
        // so any other count is a port defect, not an environment to tolerate.
        if (self.adapters.items.len != 1) return error.UnexpectedAdapterCount;

        self.device = try self.adapters.items[0].createDevice(allocator, std.testing.io, .{
            .adapter = &self.adapters.items[0],
            .object_mutex = &self.object_mutex,
            .feature_level = level,
            .uncaptured_context = @ptrCast(self),
            .uncaptured_callback = recordUncapturedError,
        });
    }

    fn lockObjects(self: *Harness) core.ObjectGuard {
        const host = self.device.coreDevice();
        const guard = core.ObjectGuard.lockUncancelable(std.testing.io, host.borrow().objects);
        host.bindTrackingOwner(&guard, @ptrCast(&self.device));
        return guard;
    }

    fn deinit(self: *Harness, allocator: std.mem.Allocator) void {
        std.debug.assert(self.uncaptured_error_count == 0);
        // The device first: it points into the adapter list it was built from.
        self.device.deinit(allocator, std.testing.io) catch @panic("compatibility device teardown failed");
        self.adapters.deinit(std.testing.io) catch @panic("compatibility adapter teardown failed");
        self.instance.deinit(allocator, std.testing.io) catch @panic("compatibility instance teardown failed");
        self.* = undefined;
    }

    /// The uncaptured sink the device installs. `context` is this harness,
    /// handed in as `.uncaptured_context` (`:197`), so the callback counts on
    /// the harness it was given rather than on a global.
    ///
    /// The signature is `error_scope.UncapturedErrorCallback`
    /// (`src/core/error_scope.zig:125`): the context arrives as `*anyopaque`,
    /// so the cast back to the harness is here.
    fn recordUncapturedError(
        allocator: std.mem.Allocator,
        _: std.Io,
        context: *anyopaque,
        data: core.ErrorView,
    ) void {
        const self: *Harness = @ptrCast(@alignCast(context));
        // Field by field because Zig 0.16.0 has no `==` for a struct. `ptr`
        // alone would not identify an allocator: a stateless allocator may
        // carry `undefined` there, so the vtable is the half that names it.
        std.debug.assert(allocator.vtable == std.testing.allocator.vtable);
        std.debug.assert(data.message.len > 0);
        self.uncaptured_error_count += 1;
    }

    /// The compatibility flag every validator below is handed.
    fn compatibility(self: *const Harness) bool {
        return self.device.isCompatibilityMode();
    }
};

/// The subset of a device's limits `validateBindingCounts` reads
/// (`BindingInfo.cpp:174-331`).
///
/// Both blocks are read. The compat block is non-null on every device, because
/// `Device.init` refuses a device without one
/// (`error.LimitsCompatibilityBlockMissing`, `Limits.cpp:475-481`).
///
/// `BindingLimits` declares the two *dynamic* per-pipeline-layout ceilings and
/// no other layout-wide one, so the device's own values are what this reads.
/// That is safe here because of what this shard builds: every count is zero
/// except the one storage-buffer count under test, and neither ceiling compares
/// a non-zero count.
fn bindingLimits(device: *const engine.Device) !pipeline.BindingLimits {
    const combined = device.limits;
    const v1 = combined.v1;
    const compat = combined.compatibility orelse return error.NoCompatibilityLimits;
    // The two pipeline-layout counts get named because `zig fmt` keeps these
    // assignments on one line, so a shorter right-hand side is what buys the
    // wrap. The value is unchanged; only the spelling of it is.
    const dynamic_uniform_layout_buffers = v1.max_dynamic_uniform_buffers_per_pipeline_layout;
    const dynamic_storage_layout_buffers = v1.max_dynamic_storage_buffers_per_pipeline_layout;

    return .{
        .max_dynamic_uniform_buffers_per_pipeline_layout = dynamic_uniform_layout_buffers,
        .max_dynamic_storage_buffers_per_pipeline_layout = dynamic_storage_layout_buffers,
        .max_sampled_textures_per_shader_stage = v1.max_sampled_textures_per_shader_stage,
        .max_samplers_per_shader_stage = v1.max_samplers_per_shader_stage,
        .max_uniform_buffers_per_shader_stage = v1.max_uniform_buffers_per_shader_stage,
        .max_storage_buffers_per_shader_stage = v1.max_storage_buffers_per_shader_stage,
        .max_storage_textures_per_shader_stage = v1.max_storage_textures_per_shader_stage,
        .max_storage_buffers_in_vertex_stage = compat.max_storage_buffers_in_vertex_stage,
        .max_storage_buffers_in_fragment_stage = compat.max_storage_buffers_in_fragment_stage,
        .max_storage_textures_in_vertex_stage = compat.max_storage_textures_in_vertex_stage,
        .max_storage_textures_in_fragment_stage = compat.max_storage_textures_in_fragment_stage,
    };
}

/// Binding counts for one stage. Every other count stays zero, so a ceiling
/// this shard does not exercise is never compared against a non-zero count.
fn countsForStage(stage: pipeline.Stage, storage_buffer_count: u32) pipeline.BindingCounts {
    var counts: pipeline.BindingCounts = .{};
    counts.per_stage[@intFromEnum(stage)].storage_buffer_count = storage_buffer_count;
    return counts;
}

/// The options `validateStage` takes. The flag is the device's derived value,
/// never a literal; see the file header. The combination cap is left at its
/// default because no restriction in §M16's table is the combination rule, so
/// this shard does not claim to re-gate it.
fn stageOptions(compat: *const Harness) pipeline.StageValidationOptions {
    return .{ .compatibility = compat.compatibility() };
}

test "the restriction table covers §M16's nine rows with no gap and no repeat" {
    // Rows are 1..=9 in order, so dropping one fails here rather than quietly
    // shrinking what the shard claims to re-gate.
    try std.testing.expectEqual(@as(usize, 9), restrictions.len);
    for (restrictions, 0..) |restriction, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), restriction.number);
        try std.testing.expect(restriction.upstream_site.len > 0);
    }
}

test "a compatibility device is derived from the absent core feature, not set" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // The derivation, read two ways. A port that stored a boolean would pass all
    // nine restrictions below and fail here, which is the cheaper failure.
    try std.testing.expect(compat.device.isCompatibilityMode());
    try std.testing.expect(!compat.device.hasFeature(.core_features_and_limits));
    try std.testing.expectEqual(
        @as(api.FeatureLevel, .compatibility),
        compat.device.getFeatureLevel(),
    );

    // The compat column survives the port: `Limits.cpp:426-459` leaves it alone
    // in compatibility mode and collapses it outside one.
    const compat_limits = compat.device.limits.compatibility orelse
        return error.NoCompatibilityLimits;
    try std.testing.expectEqual(
        compat_vertex_storage_buffer_limit,
        compat_limits.max_storage_buffers_in_vertex_stage,
    );
    try std.testing.expectEqual(
        compat_fragment_storage_buffer_limit,
        compat_limits.max_storage_buffers_in_fragment_stage,
    );
}

test "device format rows use enabled features rather than adapter capabilities" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var core_harness: Harness = undefined;
    try core_harness.init(std.testing.allocator, .core);
    defer core_harness.deinit(std.testing.allocator);

    const compat_info = compat.device.formatInfo(.bgra8_unorm_srgb) orelse
        return error.FormatRowMissing;
    const core_info = core_harness.device.formatInfo(.bgra8_unorm_srgb) orelse
        return error.FormatRowMissing;
    try std.testing.expect(!compat_info.isSupported());
    try std.testing.expect(compat_info.unsupported_reason == .compatibility_mode);
    try std.testing.expect(core_info.isSupported());
    try std.testing.expect(compat_info != core_info);
    try std.testing.expect(compat.device.formatInfo(.undefined_) == null);
    try std.testing.expect(core_harness.device.formatInfo(.undefined_) == null);
}

test "restriction 1: a fragment-stage storage buffer above the ceiling is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    const limits = try bindingLimits(&compat.device);
    try std.testing.expectError(
        restrictions[0].failure,
        pipeline.validateBindingCounts(
            limits,
            countsForStage(.fragment, fragment_storage_buffer_count_over_limit),
        ),
    );
}

test "restriction 1: the fragment ceiling itself is accepted" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // The positive half. A rule that refused at the ceiling is not the rule Dawn
    // wrote, and only this assertion tells the two apart.
    const limits = try bindingLimits(&compat.device);
    try pipeline.validateBindingCounts(
        limits,
        countsForStage(.fragment, compat_fragment_storage_buffer_limit),
    );
}

test "restriction 2: one vertex-stage storage buffer is refused, because the ceiling is zero" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    const limits = try bindingLimits(&compat.device);
    try std.testing.expectEqual(
        compat_vertex_storage_buffer_limit,
        limits.max_storage_buffers_in_vertex_stage,
    );
    try std.testing.expectError(
        restrictions[1].failure,
        pipeline.validateBindingCounts(limits, countsForStage(.vertex, 1)),
    );
}

test "restriction 2: the core device accepts the binding the compatibility device refuses" {
    var core_device: Harness = undefined;
    try core_device.init(std.testing.allocator, .core);
    defer core_device.deinit(std.testing.allocator);

    // The pair that makes restriction 2 meaningful. Upstream does not gate this
    // check on compatibility mode at all: `Limits.cpp:440-459` overwrites the
    // compat values with the per-stage limit in core mode, which is what lets
    // the check stay unconditional. A port that keeps a static compat column
    // without that overwrite is stricter than Dawn, and this test is where that
    // shows.
    try std.testing.expect(!core_device.compatibility());

    const limits = try bindingLimits(&core_device.device);
    try pipeline.validateBindingCounts(limits, countsForStage(.vertex, 1));
}

test "restriction 3: textureLoad on a depth texture is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // Dawn's `Pipeline.cpp:138-142`. The check reads reflected metadata, not the
    // shader words: the port takes that metadata as a plain struct, so no `.spv`
    // fixture is needed to reach it and no device is consulted.
    try std.testing.expectError(
        restrictions[2].failure,
        pipeline.validateStage(.{
            .stage = .fragment,
            .entry_point = "main",
            .usage = .{ .texture_load_with_depth_texture = true },
        }, stageOptions(&compat)),
    );
}

test "restriction 3: a depth texture with a non-comparison sampler is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // The second of Dawn's two checks, `Pipeline.cpp:143-147`.
    try std.testing.expectError(
        error.CompatibilityDepthTextureWithNonComparisonSampler,
        pipeline.validateStage(.{
            .stage = .fragment,
            .entry_point = "main",
            .usage = .{ .depth_texture_with_non_comparison_sampler = true },
        }, stageOptions(&compat)),
    );
}

test "restriction 3: a depth texture with a comparison sampler is accepted" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // §M16's table says "a fragment shader sampling `texture_depth_2d` is
    // rejected". That overstates the rule: a depth texture sampled with a
    // *comparison* sampler is legal in compatibility mode. This is the positive
    // case that tells the real rule from the overstated one.
    try pipeline.validateStage(.{
        .stage = .fragment,
        .entry_point = "main",
    }, stageOptions(&compat));
}

test "restriction 4: a fine derivative builtin is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // Dawn's `Pipeline.cpp:149-152`, naming `dpdxFine`, `dpdyFine` and
    // `fwidthFine`. §M16's table writes "fwidth", which is not on the reject
    // list; only the three `Fine` builtins are.
    try std.testing.expectError(
        restrictions[3].failure,
        pipeline.validateStage(.{
            .stage = .fragment,
            .entry_point = "main",
            .usage = .{ .fine_derivative_builtin = true },
        }, stageOptions(&compat)),
    );
}

test "restriction 4: a fragment stage with no fine derivative is accepted" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    try pipeline.validateStage(.{
        .stage = .fragment,
        .entry_point = "main",
    }, stageOptions(&compat));
}

test "restriction 5: a non-zero depthBiasClamp is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // Dawn's `RenderPipeline.cpp:345-347`.
    try std.testing.expectError(
        restrictions[4].failure,
        pipeline.validateDepthStencil(
            .{ .format = pipeline.depth_format, .depth_bias_clamp = 0.5 },
            pipeline.depth_format,
            compat.compatibility(),
        ),
    );
}

test "restriction 5: a zero depthBiasClamp is accepted" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    try pipeline.validateDepthStencil(
        .{ .format = pipeline.depth_format, .depth_bias_clamp = 0.0 },
        pipeline.depth_format,
        compat.compatibility(),
    );
}

test "restriction 5: a pipeline with no depth-stencil state is not checked" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);

    // Dawn runs this inside `ValidateDepthStencilState`
    // (`RenderPipeline.cpp:314`), which the descriptor only calls when
    // `depthStencil` is non-null (`:902`). Hoisting the check out would refuse a
    // pipeline that never asked for a clamp.
    //
    // The attachment format must be `UNDEFINED` alongside the null state:
    // `pipeline_render.zig:415`-`:419` treats a format with no state as its own
    // error, so passing a real depth format here would test that rule instead.
    try pipeline.validateDepthStencil(
        null,
        pipeline.undefined_depth_format,
        compat.compatibility(),
    );
}

test "restriction 6: a cube-array texture view is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);

    const info = compat.device.formatInfo(.rgba8_unorm) orelse return error.FormatRowMissing;
    // Twelve layers so a cube-array view is in range: Dawn requires the array
    // layer count of a cube-array view to be a multiple of six
    // (`Texture.cpp:183`). A view outside the texture's layers would be refused
    // by a different rule, and then this test would prove nothing.
    const source = try texture.Texture.create(std.testing.allocator, std.testing.io, &guard, compat.device.coreDevice(), .{
        .descriptor = .{
            .usage = .{ .texture_binding = true },
            .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 12 },
            .format = .rgba8_unorm,
        },
        .format_info = info,
        .limits = textureLimits(&compat.device),
        .compatibility_mode = compat.compatibility(),
    });
    const source_texture = try texture.resolveTexture(compat.device.coreDevice(), &guard, source);
    defer source_texture.header.releaseUserLocked(&guard, std.testing.io) catch @panic("compatibility texture reference release failed");

    // Dawn checks this twice: `Texture.cpp:133` in
    // `IsTextureViewDimensionCompatibleWithTextureDimension` and `:269` in
    // `ValidateTextureViewDimensionCompatibility`. The first fires first, so
    // this assertion names `TextureViewDimensionNotCompatible`; the `:269`
    // cube-array branch behind it is unreachable for this descriptor, which is
    // why `restrictions[5].upstream_site` still cites it.
    try std.testing.expectError(
        restrictions[5].failure,
        texture.Texture.createView(std.testing.allocator, std.testing.io, &guard, compat.device.coreDevice(), source, .{
            .descriptor = .{
                .format = .rgba8_unorm,
                .dimension = .cube_array,
                .base_array_layer = 0,
                .array_layer_count = 12,
            },
            .format_info = info,
            .compatibility_mode = compat.compatibility(),
        }),
    );
}

test "restriction 7: a view whose format differs from the texture is refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);

    const info = compat.device.formatInfo(.rgba8_unorm) orelse return error.FormatRowMissing;
    const srgb_info = compat.device.formatInfo(.rgba8_unorm_srgb) orelse
        return error.FormatRowMissing;
    const source = try texture.Texture.create(std.testing.allocator, std.testing.io, &guard, compat.device.coreDevice(), .{
        .descriptor = .{
            .usage = .{ .texture_binding = true },
            .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
        },
        .format_info = info,
        .limits = textureLimits(&compat.device),
        .compatibility_mode = compat.compatibility(),
    });
    const source_texture = try texture.resolveTexture(compat.device.coreDevice(), &guard, source);
    defer source_texture.header.releaseUserLocked(&guard, std.testing.io) catch @panic("compatibility texture reference release failed");

    // Canonical sRGB and linear rows share a view family. This descriptor still
    // refuses sRGB because the texture did not declare it in `view_formats`.
    try std.testing.expectError(
        restrictions[6].failure,
        texture.Texture.createView(std.testing.allocator, std.testing.io, &guard, compat.device.coreDevice(), source, .{
            .descriptor = .{
                .format = .rgba8_unorm_srgb,
                .dimension = ._2d,
                .base_array_layer = 0,
                .array_layer_count = 1,
            },
            .format_info = srgb_info,
            .compatibility_mode = compat.compatibility(),
        }),
    );
}

test "restriction 7: a view whose format matches the texture is accepted" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);

    const info = compat.device.formatInfo(.rgba8_unorm) orelse return error.FormatRowMissing;
    const source = try texture.Texture.create(std.testing.allocator, std.testing.io, &guard, compat.device.coreDevice(), .{
        .descriptor = .{
            .usage = .{ .texture_binding = true },
            .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
        },
        .format_info = info,
        .limits = textureLimits(&compat.device),
        .compatibility_mode = compat.compatibility(),
    });
    const source_texture = try texture.resolveTexture(compat.device.coreDevice(), &guard, source);
    defer source_texture.header.releaseUserLocked(&guard, std.testing.io) catch @panic("compatibility texture reference release failed");

    // Resolved rather than dropped: "accepted" is a claim about the view the
    // descriptor asked for, so the accepted view is read back and its format
    // and dimension are the ones asserted.
    const view = try texture.resolveTextureView(
        compat.device.coreDevice(),
        &guard,
        try texture.Texture.createView(std.testing.allocator, std.testing.io, &guard, compat.device.coreDevice(), source, .{
            .descriptor = .{
                .format = .rgba8_unorm,
                .dimension = ._2d,
                .base_array_layer = 0,
                .array_layer_count = 1,
            },
            .format_info = info,
            .compatibility_mode = compat.compatibility(),
        }),
    );
    defer view.header.releaseUserLocked(&guard, std.testing.io) catch @panic("compatibility view reference release failed");
    try std.testing.expectEqual(api.TextureFormat.rgba8_unorm, view.getFormat(&guard));
    try std.testing.expectEqual(api.TextureViewDimension._2d, view.getDimension(&guard));
}

test "restriction 8: two views of one texture in one draw are refused" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);
    const attachment = try createColorAttachmentState(
        std.testing.allocator,
        compat.device.coreDevice(),
        &guard,
    );
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("compatibility attachment reference release failed");

    // Dawn gates this on `HasFlexibleTextureViews()` rather than on
    // `IsCompatibilityMode()` (`Device.cpp:2746-2749`), and the device here does
    // not enable `flexible_texture_views`, so the rule is armed. Upstream
    // reaches it from the draw (`CommandBufferStateTracker.cpp:370`, through
    // `:513`) and never from the bind group record, so the error belongs to the
    // draw below and not to `setBindGroup`.
    var encoder = command.CommandEncoder.init(
        std.testing.allocator,
        compat.device.coreDevice().borrow(),
        .{ .compatibility_mode = compat.compatibility() },
    );
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);

    var pass = try encoder.beginRenderPass(std.testing.io, &guard, attachment, .{
        .color_attachments = &.{.{
            .view = @ptrCast(&color_target),
            .load_op = .load,
            .store_op = .store,
        }},
    });
    defer pass.deinit(std.testing.io, &guard);
    // The draw under test is refused, so the pass closes with nothing recorded.
    // `end()`'s own rules are M15's shard to assert, but a pass that cannot
    // close is a defect this shard would otherwise hide, so the refusal names
    // itself and fails the test rather than passing quietly.
    defer pass.end(std.testing.io, &guard) catch |err| std.debug.panic(
        "M16: the render pass refused to end after the refused draw: {s}",
        .{@errorName(err)},
    );

    try bindPipelineWithoutRequirements(&pass, &guard, attachment);

    // `var` because every one of these is named by a `commands.Ref`
    // (`src/command/commands.zig:63`), which is `?*anyopaque` and cannot carry
    // a const. See the stand-ins' own note at `:815`.
    var texture_object: TextureObject = .{};
    var view_a: TextureViewObject = .{ .texture = &texture_object };
    var view_b: TextureViewObject = .{ .texture = &texture_object };
    var group: BindGroupObject = .{};
    const bindings = [_]command.TextureBinding{
        .{ .texture = @ptrCast(&texture_object), .view = @ptrCast(&view_a), .slot = 0 },
        .{ .texture = @ptrCast(&texture_object), .view = @ptrCast(&view_b), .slot = 1 },
    };

    try pass.setBindGroup(.{
        .index = 0,
        .group = @ptrCast(&group),
        .texture_bindings = &bindings,
    });

    try std.testing.expectError(
        restrictions[7].failure,
        pass.draw(.{
            .vertex_count = 3,
            .instance_count = 1,
            .first_vertex = 0,
            .first_instance = 0,
        }),
    );
}

test "restriction 8: one view of one texture in a draw is accepted" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);
    const attachment = try createColorAttachmentState(
        std.testing.allocator,
        compat.device.coreDevice(),
        &guard,
    );
    defer attachment.header.releaseUserLocked(&guard, std.testing.io) catch
        @panic("compatibility attachment reference release failed");

    var encoder = command.CommandEncoder.init(
        std.testing.allocator,
        compat.device.coreDevice().borrow(),
        .{ .compatibility_mode = compat.compatibility() },
    );
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);

    var pass = try encoder.beginRenderPass(std.testing.io, &guard, attachment, .{
        .color_attachments = &.{.{
            .view = @ptrCast(&color_target),
            .load_op = .load,
            .store_op = .store,
        }},
    });
    defer pass.deinit(std.testing.io, &guard);
    // The draw under test is accepted, so the pass closes with a real command
    // in it. Same rule as the refused-draw test above: the close is cleanup,
    // but a pass that cannot close is a defect, so the refusal names itself
    // and fails the test rather than passing quietly.
    defer pass.end(std.testing.io, &guard) catch |err| std.debug.panic(
        "M16: the render pass refused to end after the accepted draw: {s}",
        .{@errorName(err)},
    );

    try bindPipelineWithoutRequirements(&pass, &guard, attachment);

    // `var` for the reason at `:668`.
    var texture_object: TextureObject = .{};
    var view_a: TextureViewObject = .{ .texture = &texture_object };
    var group: BindGroupObject = .{};
    const bindings = [_]command.TextureBinding{
        .{ .texture = @ptrCast(&texture_object), .view = @ptrCast(&view_a), .slot = 0 },
    };

    try pass.setBindGroup(.{
        .index = 0,
        .group = @ptrCast(&group),
        .texture_bindings = &bindings,
    });

    try pass.draw(.{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
}

test "restriction 9: a compressed format cannot be a copy source" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);

    // Dawn's `CommandEncoder.cpp:413` for the texture-to-buffer direction and
    // `:422` for texture-to-texture. The port writes one of the two, inside
    // `copyTextureToBuffer`, so this row proves the texture-to-buffer half and
    // the texture-to-texture half is unproven. The port keys the rule off the
    // format recorded on the copy, because that is the field a replay reads.
    var encoder = command.CommandEncoder.init(
        std.testing.allocator,
        compat.device.coreDevice().borrow(),
        .{ .compatibility_mode = compat.compatibility() },
    );
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);

    // `var` for the reason at `:668`: the copy names both by a `Ref`.
    var source: TextureObject = .{};
    var destination: BufferObject = .{};

    try std.testing.expectError(
        restrictions[8].failure,
        encoder.copyTextureToBuffer(.{
            .source = .{
                .texture = @ptrCast(&source),
                .format = @intFromEnum(api.TextureFormat.bc1_rgba_unorm),
                // One row, so the 256-byte row alignment
                // (`command/constants.zig:32`) does not apply and the only rule
                // this copy can trip is the compressed-format one.
                .extent = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
            },
            .destination = .{ .buffer = @ptrCast(&destination), .blocks_per_row = 4 },
            .copy_size = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
        }),
    );
}

test "restriction 9: an uncompressed format is accepted as a copy source" {
    var compat: Harness = undefined;
    try compat.init(std.testing.allocator, .compatibility);
    defer compat.deinit(std.testing.allocator);
    var guard = compat.lockObjects();
    defer guard.unlock(std.testing.io);

    var encoder = command.CommandEncoder.init(
        std.testing.allocator,
        compat.device.coreDevice().borrow(),
        .{ .compatibility_mode = compat.compatibility() },
    );
    defer encoder.deinit(std.testing.allocator, std.testing.io, &guard);

    // `var` for the reason at `:668`.
    var source: TextureObject = .{};
    var destination: BufferObject = .{};

    try encoder.copyTextureToBuffer(.{
        .source = .{
            .texture = @ptrCast(&source),
            .format = @intFromEnum(api.TextureFormat.rgba8_unorm),
            .extent = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
        },
        .destination = .{ .buffer = @ptrCast(&destination), .blocks_per_row = 4 },
        .copy_size = .{ .width = 4, .height = 1, .depth_or_array_layers = 1 },
    });
}

/// Stand-ins for the objects a command names.
///
/// `command` does not import `engine` (`docs/10-architecture.md`), so a command
/// names its objects by `Ref` into memory the caller owns and the rules that
/// need to look at one read it through that pointer. These carry the one field
/// each rule reads and nothing else: the tracker keys on the texture pointer and
/// compares the view pointer, and no rule in this shard dereferences one.
/// Every stand-in below is a `var`. The command records each of them by a
/// `commands.Ref` (`src/command/commands.zig:63`), which is `?*anyopaque`:
/// the port's reference cannot name a const object, so a `const` binding would
/// have to be cast away rather than handed over.
const TextureObject = struct {
    /// Present so the struct is not empty. No rule reads it.
    marker: u8 = 0,
};

const TextureViewObject = struct {
    texture: *const TextureObject,
    /// Present so the tracker has two distinct view pointers to compare. The
    /// pointer identity is the whole of what restriction 8 reads.
    marker: u8 = 0,
};

const BindGroupObject = struct {
    marker: u8 = 0,
};

/// A pipeline. No rule in this shard reads one: the tracker records the
/// pointer and compares the requirements, so the object behind it is only ever
/// a non-null `Ref`.
const PipelineObject = struct {
    marker: u8 = 0,
};

const BufferObject = struct {
    marker: u8 = 0,
};

fn createColorAttachmentState(
    allocator: std.mem.Allocator,
    device: *core.Device,
    guard: *const core.ObjectGuard,
) !*command.attachment_state.CanonicalAttachmentState {
    const value = try command.attachment_state.AttachmentState.fromRenderPipeline(.{
        .color_formats = &.{@intFromEnum(api.TextureFormat.rgba8_unorm)},
        .depth_stencil_format = 0,
        .sample_count = 1,
        .expand_resolve = .{},
        .pls = null,
    }, .{
        .max_color_attachments = 8,
        .max_storage_attachments = 4,
        .max_pls_bytes = 16,
    });
    const attachment = try device.create(
        allocator,
        guard,
        command.attachment_state.CanonicalAttachmentState,
        .{ .kind = .attachment_state, .initial_reference = .user },
    );
    attachment.value = value;
    attachment.cache_hash = 0;
    attachment.cache_next = null;
    attachment.header.attach(guard, std.testing.io);
    return attachment;
}

/// The render pass attachment's view. Nothing reads it past the non-null check
/// in `beginRenderPass`, but it must be a real pointer, and the attachment's
/// `view` is a `Ref`, so it is a `var`.
// SAFETY: `beginRenderPass` only checks that the attachment's `view` is a
// non-null pointer (`src/command/render_encoder_base.zig`), and nothing in this
// shard reads past that check, so the pointer value behind it is never
// dereferenced.
var color_target: TextureViewObject = .{ .texture = undefined };

/// The pipeline both restriction-8 tests draw with. A `var` for the reason
/// `color_target` is one.
var color_pipeline_object: PipelineObject = .{};

/// Binds the pipeline a draw needs before any rule of its own can run.
///
/// `Tracker.setPipeline` is the only writer of the `pipeline` bit, and
/// `checkMissingAspects` reports it ahead of every lazy bit
/// (`state_tracker.zig:414`), so a pass that reaches a draw with no pipeline is
/// refused with `MissingPipeline` and never gets as far as the rule under test.
/// The requirements are empty because that is the whole of what these two
/// draws need: a pipeline naming no bind group, no vertex buffer, no immediate
/// slot and no resource table lets each lazy aspect recompute clean
/// (`state_tracker.zig:366`-`:407`), which is what keeps the pass from failing
/// on `MissingBindGroup` one line earlier instead.
fn bindPipelineWithoutRequirements(
    pass: *command.render_encoder_base.RenderEncoderBase,
    guard: *const core.ObjectGuard,
    attachment: *command.attachment_state.CanonicalAttachmentState,
) command.Error!void {
    try pass.setPipeline(guard, .{
        .pipeline = @ptrCast(&color_pipeline_object),
        .requirements = .{},
        .attachment_state = attachment,
    });
}

fn textureLimits(device: *const engine.Device) texture.TextureLimits {
    return .{
        .max_texture_dimension_1d = device.limits.v1.max_texture_dimension_1d,
        .max_texture_dimension_2d = device.limits.v1.max_texture_dimension_2d,
        .max_texture_dimension_3d = device.limits.v1.max_texture_dimension_3d,
        .max_texture_array_layers = device.limits.v1.max_texture_array_layers,
    };
}
