//! Bounded evaluation of compute workgroup declarations. Words remain borrowed.
//! Supports 32-bit workgroup axes and 8/16/32/64-bit integer dependencies,
//! vector composites, CompositeExtract, integer add/subtract/multiply,
//! unsigned divide/modulo, logical shifts, and bitwise operations.
//! Other expression forms return SpirvWorkgroupUnsupported.
//! Evaluation is limited to 64 nested dependencies and 4096 visited nodes.
const instruction = @import("instruction.zig");
const error_mod = @import("error.zig");
const word = @import("word.zig");

/// The declaration form, not the Vulkan feature-support decision.
pub const Size = union(enum) {
    missing,
    literal: [3]u32,
    ids: [3]u32,
    builtin: u32,
};

/// Mode presence remains available when the built-in takes size precedence.
pub const Metadata = struct {
    size: Size = .missing,
    has_local_size_id: bool = false,
};

/// A canonical SpecId value, with the byte size and bits already normalized.
pub const Override = struct { spec_id: u32, size: u8, bits: u64 };
/// Malformed operands use SpirvMalformed. Unsupported forms and resource
/// exhaustion have separate errors; no error owns an allocated payload.
pub const Error = error_mod.Error || error{
    SpirvWorkgroupEntryPoint,
    SpirvWorkgroupMissing,
    SpirvWorkgroupUnsupported,
    SpirvWorkgroupCycle,
    SpirvWorkgroupOverflow,
    SpirvWorkgroupLimit,
    SpirvWorkgroupOverride,
};

/// A borrowed view of normalized values, never a second conversion authority.
pub const Overrides = union(enum) {
    slice: []const Override,
    canonical: []const u8,

    fn iterator(self: Overrides) Iterator {
        return .{ .source = self };
    }
};

const Iterator = struct {
    source: Overrides,
    index: usize = 0,

    fn next(self: *Iterator) Error!?Override {
        switch (self.source) {
            .slice => |values| {
                if (self.index == values.len) return null;
                const value = values[self.index];
                self.index += 1;
                return value;
            },
            .canonical => |bytes| {
                if (self.index == bytes.len) return null;
                const remaining = bytes[self.index..];
                if (remaining.len < 7) return error.SpirvWorkgroupOverride;
                const size = remaining[6];
                if (size != 1 and size != 2 and size != 4 and size != 8)
                    return error.SpirvWorkgroupOverride;
                if (remaining.len < 7 + @as(usize, size)) return error.SpirvWorkgroupOverride;
                if (remaining[4] > 3) return error.SpirvWorkgroupOverride;
                var spec_id: u32 = 0;
                for (0..4) |index| {
                    spec_id |= @as(u32, remaining[index]) << @as(u5, @intCast(index * 8));
                }
                var bits: u64 = 0;
                for (remaining[7..][0..size], 0..) |byte, index| {
                    bits |= @as(u64, byte) << @as(u6, @intCast(index * 8));
                }
                self.index += 7 + @as(usize, size);
                return .{ .spec_id = spec_id, .size = size, .bits = bits };
            },
        }
    }
};

pub fn read(words: []const u32, entry_id: u32, compute: bool) error_mod.Error!Metadata {
    var result: Size = .missing;
    var has_local_size_id = false;
    var builtin: ?u32 = null;
    var cursor = instruction.Cursor.init(words);
    while (try cursor.next()) |inst| {
        const operands = inst.operands();
        if (inst.opcode() == 16 or inst.opcode() == 331) {
            if (operands.len < 2) return error.SpirvMalformed;
            if (operands[1] != 17 and operands[1] != 38) continue;
            if (operands.len != 5) return error.SpirvMalformed;
            if ((operands[1] == 17) != (inst.opcode() == 16)) return error.SpirvMalformed;
            try checkModeTarget(words, operands[0]);
            if (operands[0] != entry_id) continue;
            if (!compute or result != .missing) return error.SpirvMalformed;
            const axes: [3]u32 = .{ operands[2], operands[3], operands[4] };
            if (operands[1] == 17) {
                for (axes) |axis| if (axis == 0) return error.SpirvMalformed;
                result = .{ .literal = axes };
            } else {
                for (axes) |axis| try checkId(words, axis);
                result = .{ .ids = axes };
                has_local_size_id = true;
            }
        } else if (inst.opcode() == 71) {
            if (operands.len < 2) return error.SpirvMalformed;
            if (operands[1] != 11) continue;
            if (operands.len != 3) return error.SpirvMalformed;
            if (operands[2] != 25) continue;
            try checkId(words, operands[0]);
            var targets = instruction.Cursor.init(words);
            var is_group = false;
            while (try targets.next()) |target| {
                if (target.opcode() != 73) continue;
                if (target.operands().len != 1) return error.SpirvMalformed;
                if (target.operands()[0] == operands[0]) is_group = true;
            }
            if (!is_group) {
                if (builtin != null) return error.SpirvMalformed;
                builtin = operands[0];
            } else {
                targets = instruction.Cursor.init(words);
                while (try targets.next()) |target| {
                    if (target.opcode() != 74) continue;
                    const group = target.operands();
                    if (group.len < 2) return error.SpirvMalformed;
                    if (group[0] != operands[0]) continue;
                    for (group[1..]) |id| {
                        try checkId(words, id);
                        if (builtin != null) return error.SpirvMalformed;
                        builtin = id;
                    }
                }
            }
        }
    }
    // Vulkan gives the WorkgroupSize built-in precedence over execution modes.
    if (compute) if (builtin) |id| {
        return .{ .size = .{ .builtin = id }, .has_local_size_id = has_local_size_id };
    };
    return .{ .size = result, .has_local_size_id = has_local_size_id };
}

fn checkModeTarget(words: []const u32, id: u32) error_mod.Error!void {
    try checkId(words, id);
    var cursor = instruction.Cursor.init(words);
    while (try cursor.next()) |inst| {
        if (inst.opcode() != 15) continue;
        const entry = try instruction.readEntryPoint(inst);
        try word.validateString(entry.name_words);
        if (entry.id != id) continue;
        if (@backingInt(entry.execution_model) != 5) return error.SpirvMalformed;
        return;
    }
    return error.SpirvMalformed;
}

fn checkId(words: []const u32, id: u32) error_mod.Error!void {
    if (id == 0 or id >= words[3]) return error.SpirvMalformed;
}

fn declaration(words: []const u32, id: u32, type_id: bool) Error!instruction.Instruction {
    try checkId(words, id);
    var found: ?instruction.Instruction = null;
    var cursor = instruction.Cursor.init(words);
    while (try cursor.next()) |inst| {
        const operands = inst.operands();
        const index: usize = if (type_id) 0 else 1;
        const relevant = if (type_id)
            inst.opcode() >= 19 and inst.opcode() <= 39
        else
            inst.opcode() >= 41 and inst.opcode() <= 52;
        if (!relevant) continue;
        if (operands.len <= index) return error.SpirvMalformed;
        if (operands[index] != id) continue;
        if (found != null) return error.SpirvMalformed;
        found = inst;
    }
    return found orelse error.SpirvMalformed;
}

const traversal_depth_max = 64;
const evaluation_count_max = 4096;
const Evaluation = struct {
    path: [traversal_depth_max]u32,
    count: usize = 0,

    fn scalar(
        self: *Evaluation,
        words: []const u32,
        id: u32,
        component: ?u32,
        overrides: Overrides,
        constants: anytype,
        depth: usize,
        axis: bool,
    ) Error!u64 {
        if (depth == traversal_depth_max or self.count == evaluation_count_max)
            return error.SpirvWorkgroupLimit;
        for (self.path[0..depth]) |ancestor| if (ancestor == id)
            return error.SpirvWorkgroupCycle;
        self.path[depth] = id;
        self.count += 1;
        const inst = try declaration(words, id, false);
        const operands = inst.operands();
        const type_inst = try declaration(words, operands[0], true);
        const type_operands = type_inst.operands();
        if (component) |index| {
            if (type_inst.opcode() != 23 or type_operands.len != 3)
                return error.SpirvMalformed;
            if (type_operands[2] < 2) return error.SpirvMalformed;
            if (type_operands[2] > 4) return error.SpirvWorkgroupUnsupported;
            if (index >= type_operands[2]) return error.SpirvMalformed;
            if (inst.opcode() != 44 and inst.opcode() != 51)
                return error.SpirvWorkgroupUnsupported;
            if (operands.len != 2 + type_operands[2]) return error.SpirvMalformed;
            const child = try declaration(words, operands[2 + index], false);
            if (child.operands()[0] != type_operands[1]) return error.SpirvMalformed;
            return self.scalar(words, operands[2 + index], null, overrides, constants, depth + 1, axis);
        }
        if (type_inst.opcode() != 21 or type_operands.len != 3)
            return error.SpirvMalformed;
        const width = type_operands[1];
        if (type_operands[2] > 1 or (axis and width != 32)) return error.SpirvMalformed;
        const mask: u64 = switch (width) {
            8 => 0xff,
            16 => 0xffff,
            32 => 0xffff_ffff,
            64 => 0xffff_ffff_ffff_ffff,
            else => return error.SpirvMalformed,
        };
        if (inst.opcode() == 43 or inst.opcode() == 50) {
            if (operands.len != (if (width == 64) @as(usize, 4) else 3))
                return error.SpirvMalformed;
        }
        if (inst.opcode() == 50) {
            for (constants) |constant| {
                if (constant.result_id != id) continue;
                var values = overrides.iterator();
                while (try values.next()) |override| {
                    if (override.spec_id != constant.spec_id) continue;
                    if (override.size != width / 8 or override.bits > mask)
                        return error.SpirvWorkgroupOverride;
                    return override.bits;
                }
            }
        }
        if (inst.opcode() == 43 or inst.opcode() == 50) {
            const bits = @as(u64, operands[2]) |
                (if (width == 64) @as(u64, operands[3]) << 32 else 0);
            return bits & mask;
        }
        if (inst.opcode() != 52) return error.SpirvWorkgroupUnsupported;
        if (operands.len < 3) return error.SpirvMalformed;
        if (operands[2] == 81) {
            if (operands.len != 5) return error.SpirvMalformed;
            const composite = try declaration(words, operands[3], false);
            const vector = try declaration(words, composite.operands()[0], true);
            if (vector.opcode() != 23 or vector.operands().len != 3)
                return error.SpirvMalformed;
            if (vector.operands()[1] != operands[0]) return error.SpirvMalformed;
            return self.scalar(words, operands[3], operands[4], overrides, constants, depth + 1, axis);
        }
        switch (operands[2]) {
            128, 130, 132, 134, 137, 194, 196, 197, 198, 199 => {},
            else => return error.SpirvWorkgroupUnsupported,
        }
        if (operands.len != 5) return error.SpirvMalformed;
        for (operands[3..5], 0..) |child_id, child_index| {
            const child = try declaration(words, child_id, false);
            const child_type = try declaration(words, child.operands()[0], true);
            const child_type_operands = child_type.operands();
            if (child_type.opcode() != 21 or child_type_operands.len != 3 or
                child_type_operands[2] > 1) return error.SpirvMalformed;
            switch (operands[2]) {
                // Unsigned divide/modulo require the result type itself.
                134, 137 => {
                    if (type_operands[2] != 0 or child.operands()[0] != operands[0])
                        return error.SpirvMalformed;
                },
                // The shift amount need not have the base's width or signedness.
                194, 196 => {
                    if (child_index == 0 and child_type_operands[1] != width)
                        return error.SpirvMalformed;
                },
                else => if (child_type_operands[1] != width) return error.SpirvMalformed,
            }
        }
        const left = try self.scalar(words, operands[3], null, overrides, constants, depth + 1, false);
        const right = try self.scalar(words, operands[4], null, overrides, constants, depth + 1, false);
        // SPIR-V integer operations preserve the low component-width bits.
        const result: u64 = switch (operands[2]) {
            128 => left +% right,
            130 => left -% right,
            132 => left *% right,
            134, 137 => blk: {
                if (right == 0) return error.SpirvMalformed;
                break :blk if (operands[2] == 134) @divFloor(left, right) else @mod(left, right);
            },
            194, 196 => blk: {
                if (right >= width) return error.SpirvMalformed;
                const shift: u6 = @intCast(right);
                if (operands[2] == 194) break :blk left >> shift;
                break :blk left << shift;
            },
            197 => left | right,
            198 => left ^ right,
            199 => left & right,
            else => return error.SpirvWorkgroupUnsupported,
        };
        return result & mask;
    }
};

pub fn resolve(words: []const u32, size: Size, overrides: Overrides, constants: anytype) Error![3]u32 {
    var values = overrides.iterator();
    var count: usize = 0;
    while (try values.next()) |override| {
        var previous_values = overrides.iterator();
        for (0..count) |_| {
            const previous = (try previous_values.next()) orelse
                return error.SpirvWorkgroupOverride;
            if (previous.spec_id == override.spec_id) return error.SpirvWorkgroupOverride;
        }
        count += 1;
        var found = false;
        for (constants) |constant| {
            if (constant.spec_id == override.spec_id) found = true;
        }
        if (!found) return error.SpirvWorkgroupOverride;
    }
    // SAFETY: Each active dependency writes its path slot before descendants read that prefix.
    var evaluation: Evaluation = .{ .path = undefined };
    var result: [3]u32 = undefined;
    switch (size) {
        .missing => return error.SpirvWorkgroupMissing,
        .literal => |axes| result = axes,
        .ids => |ids| {
            for (ids, 0..) |id, index| {
                result[index] = @intCast(try evaluation.scalar(
                    words,
                    id,
                    null,
                    overrides,
                    constants,
                    0,
                    true,
                ));
            }
        },
        .builtin => |id| {
            const value = try declaration(words, id, false);
            const vector = try declaration(words, value.operands()[0], true);
            if (vector.opcode() != 23 or vector.operands().len != 3 or vector.operands()[2] != 3)
                return error.SpirvMalformed;
            for (0..3) |index| {
                result[index] = @intCast(try evaluation.scalar(
                    words,
                    id,
                    @intCast(index),
                    overrides,
                    constants,
                    0,
                    true,
                ));
            }
        },
    }
    // Specialized values are metadata; compute validation owns zero-axis policy.
    return result;
}
