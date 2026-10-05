//! What a module says about itself: its entry points and its descriptor
//! bindings.
//!
//! `AGENTS.md` §3.2 makes this ours rather than Tint's: Dawn reads reflection
//! out of a `tint::Program` and the port reads it out of the binary. A
//! reflection result that disagrees with what the shader declares is a defect,
//! so this file re-derives every binding from `OpDecorate` and `OpTypeImage`
//! and never carries a value over from a previous pass.
//!
//! **What this file does not claim.** It does not claim to check the module's
//! types. It reads a module `validate` accepted and answers the question the
//! bind group layout needs: which descriptor sits at which set and binding, and
//! what kind of resource it is.

const std = @import("std");
const error_mod = @import("error.zig");
const grammar = @import("grammar.zig");
const header = @import("header.zig");
const instruction = @import("instruction.zig");
const version_mod = @import("version.zig");
const word = @import("word.zig");

const Error = error_mod.Error;
const ErrorOrOutOfMemory = error_mod.ErrorOrOutOfMemory;
const Dim = grammar.Dim;
const ExecutionModel = grammar.ExecutionModel;
const Version = version_mod.Version;
const Word = word.Word;

/// The `sampled` operand of `OpTypeImage` for a storage image. The other two
/// values are zero for a read-at-runtime image and one for a sampled image.
const storage_image_value: u32 = 2;

/// What a descriptor is, which is what a bind group layout has to name.
pub const ResourceKind = enum {
    uniform_buffer,
    storage_buffer,
    sampled_texture,
    sampled_buffer,
    storage_texture,
    storage_texture_buffer,
    sampler,
    input_attachment,
};

pub const Resource = struct {
    kind: ResourceKind,
    set: u32,
    binding: u32,
};

pub const EntryPoint = struct {
    execution_model: ExecutionModel,
    id: u32,

    /// Borrowed from the words `reflect` was given.
    name: []const u8,
    resources: []Resource,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    version: Version,
    generator_magic: u32,
    id_bound: u32,

    /// In the order the module declares them.
    entry_points: []EntryPoint,

    /// Entry point names borrow the words `reflect` was given, so a `Module`
    /// must not outlive them. Everything else here is owned.
    pub fn deinit(self: Module) void {
        for (self.entry_points) |entry_point| freeResources(self.allocator, entry_point.resources);
        self.allocator.free(self.entry_points);
    }

    pub fn findEntryPoint(self: Module, name: []const u8) ?EntryPoint {
        for (self.entry_points) |entry_point| {
            if (std.mem.eql(u8, entry_point.name, name)) return entry_point;
        }
        return null;
    }
};

/// The description of a module, read out of the caller's own words.
///
/// The words are borrowed, not copied and not rewritten: the same slice is what
/// reaches `vkCreateShaderModule` afterwards.
pub fn reflect(allocator: std.mem.Allocator, words: []const Word) ErrorOrOutOfMemory!Module {
    const module_header = try header.parse(words);

    var tables: Tables = .{ .allocator = allocator };
    defer tables.deinit();

    try tables.readDeclarations(words);
    try tables.readDecorations(words);
    try tables.applyGroups(words);
    try tables.applyRecords();

    return .{
        .allocator = allocator,
        .version = module_header.version,
        .generator_magic = module_header.generator_magic,
        .id_bound = module_header.id_bound,
        .entry_points = try readEntryPoints(allocator, words, &tables),
    };
}

fn readEntryPoints(
    allocator: std.mem.Allocator,
    words: []const Word,
    tables: *const Tables,
) ErrorOrOutOfMemory![]EntryPoint {
    var cursor: instruction.Cursor = instruction.Cursor.init(words);
    var entry_points: std.ArrayList(EntryPoint) = .empty;
    errdefer deinitEntryPoints(allocator, &entry_points);

    while (try cursor.next()) |inst| {
        if (inst.knownOpcode() != .entry_point) continue;

        const fields = try instruction.readEntryPoint(inst);
        const resources = try readResources(allocator, fields.interface, tables);
        errdefer freeResources(allocator, resources);

        try entry_points.append(allocator, .{
            .execution_model = fields.execution_model,
            .id = fields.id,
            .name = fields.name,
            .resources = resources,
        });
    }

    if (entry_points.items.len == 0) return error.SpirvNoEntryPoint;
    return entry_points.toOwnedSlice(allocator);
}

fn deinitEntryPoints(
    allocator: std.mem.Allocator,
    entry_points: *std.ArrayList(EntryPoint),
) void {
    // Indexed rather than `for (entry_points.items)`. The body releases each
    // entry's own resource array, so re-reading `entry_points.items` per step
    // keeps the walk on the list's current storage instead of one slice taken
    // before the first release.
    var index: usize = 0;
    while (index < entry_points.items.len) : (index += 1) {
        freeResources(allocator, entry_points.items[index].resources);
    }
    entry_points.deinit(allocator);
}

/// `std.ArrayList.toOwnedSlice` hands back a static empty slice for a list that
/// never grew, and a static empty slice is not the allocator's to free.
fn freeResources(allocator: std.mem.Allocator, resources: []Resource) void {
    if (resources.len == 0) return;
    allocator.free(resources);
}

/// The descriptor bindings one entry point declares, ordered by set and then by
/// binding so two runs of the reflector produce the same order.
///
/// Two variables at one set and binding is a module Vulkan rejects, so it is
/// rejected here rather than reported twice.
fn readResources(
    allocator: std.mem.Allocator,
    interface: []const Word,
    tables: *const Tables,
) ErrorOrOutOfMemory![]Resource {
    var resources: std.ArrayList(Resource) = .empty;
    errdefer resources.deinit(allocator);

    for (interface) |variable_id| {
        const resource = tables.resourceFor(variable_id) orelse continue;
        try resources.append(allocator, resource);
    }

    std.mem.sort(Resource, resources.items, NoContext{}, lessBySetThenBinding);
    for (resources.items, 0..) |resource, index| {
        if (index == 0) continue;
        const previous = resources.items[index - 1];
        if (previous.set == resource.set and previous.binding == resource.binding) {
            return error.SpirvMalformed;
        }
    }

    return resources.toOwnedSlice(allocator);
}

const NoContext = struct {};

fn lessBySetThenBinding(_: NoContext, left: Resource, right: Resource) bool {
    if (left.set != right.set) return left.set < right.set;
    return left.binding < right.binding;
}

/// `OpTypeImage` with the two operands that decide the bind group entry: the
/// dimension that separates a texel buffer from an image, and `sampled` that
/// separates a sampled image from a storage one.
const ImageType = struct {
    dim: Dim,
    sampled: u32,
};

/// `Block` and `BufferBlock` name different bindings. SPIR-V 1.3 gave a
/// storage buffer its own storage class, so `BufferBlock` is how a storage
/// buffer was spelled before it.
const Block = enum {
    uniform,
    storage,
};

const TypeInfo = union(enum) {
    structure,
    pointer: u32,
    image: ImageType,
    sampler,
    block: Block,
};

const Variable = struct {
    pointer_type: u32,
    storage_class: grammar.StorageClass,
    set: ?u32 = null,
    binding: ?u32 = null,
    input_attachment_index: ?u32 = null,
};

/// The decorations the reflector acts on. A module decorates far more than
/// this, and `validate` is where the rest are checked.
const DecorationRecord = struct {
    set: ?u32 = null,
    binding: ?u32 = null,
    input_attachment_index: ?u32 = null,
    block: ?Block = null,

    /// A target can carry its own decoration and a group's at once, so the two
    /// records combine rather than one replacing the other.
    fn merge(have: DecorationRecord, other: DecorationRecord) DecorationRecord {
        return .{
            .set = other.set orelse have.set,
            .binding = other.binding orelse have.binding,
            .input_attachment_index = other.input_attachment_index orelse have.input_attachment_index,
            .block = other.block orelse have.block,
        };
    }
};

/// What the walks over a module learned, keyed by id.
///
/// The maps are sparse on purpose. A module declares tens of ids and reserves a
/// bound far above them, so a table indexed by the bound would allocate for ids
/// no module uses.
const Tables = struct {
    allocator: std.mem.Allocator,
    types: std.AutoHashMapUnmanaged(u32, TypeInfo) = .empty,
    variables: std.AutoHashMapUnmanaged(u32, Variable) = .empty,
    decorations: std.AutoHashMapUnmanaged(u32, DecorationRecord) = .empty,

    fn deinit(self: *Tables) void {
        self.types.deinit(self.allocator);
        self.variables.deinit(self.allocator);
        self.decorations.deinit(self.allocator);
        // `HashMapUnmanaged.deinit` leaves the fields as it found them, so the
        // maps keep pointing at freed memory. Nothing reads `tables` after the
        // `defer` in `reflect` runs, so the struct is destroyed rather than
        // left half-valid.
        self.* = undefined;
    }

    fn readDeclarations(self: *Tables, words: []const Word) ErrorOrOutOfMemory!void {
        var cursor: instruction.Cursor = instruction.Cursor.init(words);
        while (try cursor.next()) |inst| {
            // An opcode the reader does not model is an instruction this pass
            // has no use for, not a malformed module: a module may legally
            // carry hundreds of them, and each declares its own word count, so
            // skipping one leaves the walk exact. The skip joins the modelled
            // opcodes these tables do not act on.
            const opcode = inst.knownOpcode() orelse continue;
            const operands = inst.operands();
            switch (opcode) {
                .type_structure => {
                    if (operands.len < 1) return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .structure);
                },
                .type_pointer => {
                    if (operands.len < 3) return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .{ .pointer = operands[2] });
                },
                .type_image => {
                    if (operands.len < 7) return error.SpirvMalformed;
                    const dim = grammar.Dim.fromRaw(operands[2]) orelse
                        return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .{
                        .image = .{ .dim = dim, .sampled = operands[6] },
                    });
                },
                .type_sampler => {
                    if (operands.len < 1) return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .sampler);
                },
                .variable => {
                    if (operands.len < 3) return error.SpirvMalformed;
                    const storage_class = grammar.StorageClass.fromRaw(operands[2]) orelse
                        return error.SpirvMalformed;
                    try self.variables.put(self.allocator, operands[1], .{
                        .pointer_type = operands[0],
                        .storage_class = storage_class,
                    });
                },
                else => {},
            }
        }
    }

    fn readDecorations(self: *Tables, words: []const Word) ErrorOrOutOfMemory!void {
        var cursor: instruction.Cursor = instruction.Cursor.init(words);
        while (try cursor.next()) |inst| {
            // Same rule as `readDeclarations`: an unmodelled instruction is
            // skipped, and the switch keeps its own `else` for the rest.
            const opcode = inst.knownOpcode() orelse continue;
            const operands = inst.operands();
            switch (opcode) {
                .decorate, .decorate_string => {
                    if (operands.len < 2) return error.SpirvMalformed;
                    const record = try readDecorationRecord(operands[1..]) orelse continue;
                    // A target carries `DescriptorSet` and `Binding` in two
                    // separate instructions, so the records merge rather than
                    // the later one replacing the earlier, which would leave
                    // every descriptor without a set or without a binding.
                    const own = self.decorations.get(operands[0]);
                    const merged = if (own) |have| have.merge(record) else record;
                    try self.decorations.put(self.allocator, operands[0], merged);
                },
                else => {},
            }
        }
    }

    /// A decoration may reach its target through a decoration group, and the
    /// group may be declared after the instruction that applies it. The records
    /// are therefore collected first and copied to the group's targets here.
    fn applyGroups(self: *Tables, words: []const Word) ErrorOrOutOfMemory!void {
        var cursor: instruction.Cursor = instruction.Cursor.init(words);
        while (try cursor.next()) |inst| {
            const operands = inst.operands();
            if (inst.knownOpcode() != .group_decorate) continue;
            if (operands.len < 2) return error.SpirvMalformed;

            const group = self.decorations.get(operands[0]) orelse continue;
            for (operands[1..]) |target| {
                const own = self.decorations.get(target);
                const merged = if (own) |have| have.merge(group) else group;
                try self.decorations.put(self.allocator, target, merged);
            }
        }
    }

    /// Moves each collected record onto the thing it decorates. A binding names
    /// a variable and `Block` names a struct, so a record aimed at anything
    /// else is a module that does not say what it means.
    fn applyRecords(self: *Tables) ErrorOrOutOfMemory!void {
        var records = self.decorations.iterator();
        while (records.next()) |record| {
            const id = record.key_ptr.*;
            const value = record.value_ptr.*;

            if (value.block) |block| {
                // The id must already be declared as the struct the block
                // names. The optional is unwrapped first: `.structure` would
                // otherwise be read as an optional payload or as a union tag,
                // and the two cannot be told apart in one literal.
                const existing = self.types.get(id) orelse
                    return error.SpirvMalformed;
                if (existing != .structure) return error.SpirvMalformed;
                try self.types.put(self.allocator, id, .{ .block = block });
                continue;
            }

            const variable = self.variables.getPtr(id) orelse
                return error.SpirvMalformed;
            variable.set = value.set orelse variable.set;
            variable.binding = value.binding orelse variable.binding;
            variable.input_attachment_index =
                value.input_attachment_index orelse variable.input_attachment_index;
        }
    }

    /// The descriptor at one global variable, or null when the variable is not
    /// a descriptor. An `Input`, an `Output` or a `Private` global is an
    /// interface variable, not a binding, and carries no `Binding` decoration.
    fn resourceFor(self: *const Tables, variable_id: u32) ?Resource {
        const variable = self.variables.get(variable_id) orelse return null;
        const set = variable.set orelse return null;
        const binding = variable.binding orelse return null;

        const pointer = self.types.get(variable.pointer_type) orelse return null;
        const pointee_id = switch (pointer) {
            .pointer => |id| id,
            else => return null,
        };
        const pointee = self.types.get(pointee_id) orelse return null;

        const kind = classify(variable, pointee) orelse return null;
        return .{ .kind = kind, .set = set, .binding = binding };
    }
};

/// The three decorations that name a bind group entry, plus the two that make
/// a struct a block, or null when the instruction carries none of them.
fn readDecorationRecord(literal_words: []const Word) Error!?DecorationRecord {
    if (literal_words.len == 0) return null;

    const decoration = grammar.Decoration.fromRaw(literal_words[0]) orelse return null;
    return switch (decoration) {
        .descriptor_set => .{ .set = try readLiteral(literal_words[1..]) },
        .binding => .{ .binding = try readLiteral(literal_words[1..]) },
        .input_attachment_index => .{
            .input_attachment_index = try readLiteral(literal_words[1..]),
        },
        .block => .{ .block = .uniform },
        .buffer_block => .{ .block = .storage },
        else => null,
    };
}

fn readLiteral(words: []const Word) Error!u32 {
    if (words.len == 0) return error.SpirvMalformed;
    return words[0];
}

fn classify(variable: Variable, pointee: TypeInfo) ?ResourceKind {
    return switch (variable.storage_class) {
        .storage_buffer => .storage_buffer,
        .uniform => switch (pointee) {
            .block => |block| switch (block) {
                .uniform => .uniform_buffer,
                .storage => .storage_buffer,
            },
            .image => |image| classifyImage(variable, image),
            else => null,
        },
        .uniform_constant => switch (pointee) {
            .sampler => .sampler,
            .image => |image| classifyImage(variable, image),
            else => null,
        },
        // SPIR-V before 1.3 spelled a storage image with its own storage
        // class; from 1.3 it shares `Uniform` with a uniform buffer.
        .image => switch (pointee) {
            .image => .storage_texture,
            else => null,
        },
        else => null,
    };
}

/// A sampled image and a storage image can share a storage class, so `sampled`
/// on `OpTypeImage` is what separates them. `Dim.buffer` separates a texel
/// buffer from an image, and a bind group layout keeps the two apart.
fn classifyImage(variable: Variable, image: ImageType) ResourceKind {
    if (image.sampled == storage_image_value) {
        return if (image.dim == .buffer) .storage_texture_buffer else .storage_texture;
    }
    if (variable.input_attachment_index != null) return .input_attachment;
    return if (image.dim == .buffer) .sampled_buffer else .sampled_texture;
}
