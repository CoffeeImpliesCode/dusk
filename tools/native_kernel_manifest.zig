const std = @import("std");

pub const pin = @import("dawn_pin.zon");
pub const provenance_path = "src/engine/shaders/native_kernels.provenance.json";
pub const Origin = enum { tint_wgsl, fixed_zig_spirv };
pub const Stage = enum { compute, vertex, fragment };
pub const BindingKind = enum {
    uniform,
    storage_read,
    storage_write,
    sampled_float,
    sampled_uint,
    sampled_sint,
    sampled_depth,
    sampler,
    combined_y_cb_cr,
};
pub const Binding = struct {
    binding: u32,
    kind: BindingKind,
    min_size: u32 = 0,
    dimension: enum { none, d1, d2, d2_array, d3 } = .none,
    multisampled: bool = false,
    uniform_words: []const enum { padding, f32, u32 } = &.{},
};
pub const Entry = struct {
    source: []const u8,
    output: []const u8,
    entry_point: [:0]const u8,
    stage: Stage,
    origin: Origin = .tint_wgsl,
    bindings: []const Binding = &.{},
    parameter_size: u32 = 0,
    workgroup_size: [3]u32 = .{ 0, 0, 0 },
    private_depth_range_bytes: u32 = 0,
    fixed_stencil_mask: u32 = 0,
};

// Reviewed finite sources. Ordinary builds never invoke their generator.
pub const entries: []const Entry = @import("native_kernel_sources.zig").entries(Entry);

test "every fixed source output and binding identity is unique" {
    for (entries, 0..) |entry, index| {
        try std.testing.expect(entry.source.len != 0);
        try std.testing.expect(entry.output.len != 0);
        for (entries[0..index]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, previous.output, entry.output));
            try std.testing.expect(!std.mem.eql(u8, previous.source, entry.source));
        }
        for (entry.bindings, 0..) |binding, binding_index| {
            for (entry.bindings[0..binding_index]) |previous| {
                try std.testing.expect(previous.binding != binding.binding);
            }
            if (binding.uniform_words.len != 0) {
                try std.testing.expect(binding.kind == .uniform);
                try std.testing.expectEqual(binding.min_size, binding.uniform_words.len * 4);
            }
        }
        try std.testing.expect(entry.private_depth_range_bytes == 0 or
            entry.private_depth_range_bytes == 8);
    }
}

test "eight fixed stencil artifacts cover each write bit exactly once" {
    var masks_seen: u32 = 0;
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.fixed_stencil_mask == 0) continue;
        count += 1;
        try std.testing.expect(entry.fixed_stencil_mask <= 128);
        try std.testing.expectEqual(@as(u32, 1), @popCount(entry.fixed_stencil_mask));
        try std.testing.expectEqual(@as(u32, 0), masks_seen & entry.fixed_stencil_mask);
        masks_seen |= entry.fixed_stencil_mask;
        try std.testing.expectEqual(@as(u32, 64), entry.parameter_size);
        try std.testing.expectEqual(@as(usize, 2), entry.bindings.len);
        try std.testing.expectEqual(@as(u32, 64), entry.bindings[1].min_size);
    }
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expectEqual(@as(u32, 255), masks_seen);
}

test "ordinary raw uniform words remain distinct from hardware typed uniforms" {
    const ordinary = for (entries) |entry| {
        if (std.mem.eql(u8, entry.entry_point, "external_ordinary")) break entry;
    } else return error.TestUnexpectedResult;
    const hardware = for (entries) |entry| {
        if (std.mem.eql(u8, entry.entry_point, "external_ycbcr")) break entry;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 72), ordinary.bindings[3].uniform_words.len);
    try std.testing.expectEqual(@as(usize, 40), ordinary.bindings[4].uniform_words.len);
    for (ordinary.bindings[3].uniform_words) |word| {
        try std.testing.expect(word == .u32);
    }
    for (ordinary.bindings[4].uniform_words) |word| {
        try std.testing.expect(word == .u32);
    }
    try std.testing.expect(hardware.bindings[1].uniform_words[2] == .padding);
    try std.testing.expect(hardware.bindings[1].uniform_words[4] == .f32);
    try std.testing.expect(hardware.bindings[2].uniform_words[0] == .f32);
    try std.testing.expect(hardware.bindings[2].uniform_words[6] == .u32);
    try std.testing.expect(hardware.bindings[2].uniform_words[31] == .padding);
}

test "external expanded probe uses bounded auxiliary bindings" {
    const probe = for (entries) |entry| {
        if (std.mem.eql(u8, entry.entry_point, "external_expanded_probe")) break entry;
    } else return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(
        "test/fixtures/external_expanded_probe.comp.wgsl",
        probe.source,
    );
    try std.testing.expectEqualStrings(
        "test/fixtures/external_expanded_probe.comp.spv",
        probe.output,
    );
    try std.testing.expectEqual(Stage.compute, probe.stage);
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, probe.workgroup_size);

    const expected_bindings = [_]u32{ 1000, 1001, 1002, 2, 4 };
    const expected_kinds = [_]BindingKind{
        .sampled_float,
        .sampled_float,
        .uniform,
        .sampler,
        .storage_write,
    };
    try std.testing.expectEqual(@as(usize, expected_bindings.len), probe.bindings.len);
    for (probe.bindings, 0..) |binding, index| {
        try std.testing.expectEqual(expected_bindings[index], binding.binding);
        try std.testing.expectEqual(expected_kinds[index], binding.kind);
    }

    for (probe.bindings[0..2]) |binding| {
        try std.testing.expectEqual(.d2, binding.dimension);
        try std.testing.expect(!binding.multisampled);
    }

    const metadata = probe.bindings[2];
    try std.testing.expectEqual(@as(u32, 288), metadata.min_size);
    try std.testing.expectEqual(@as(usize, 72), metadata.uniform_words.len);
    for (metadata.uniform_words) |word| {
        try std.testing.expectEqual(.u32, word);
    }

    try std.testing.expectEqual(@as(u32, 544), probe.bindings[4].min_size);
}
