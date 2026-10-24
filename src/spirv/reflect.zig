//! What a module says about itself: its entry points and its descriptor
//! bindings.
//!
//! Dawn reads reflection
//! out of a `tint::Program` and the port reads it out of the binary. A
//! reflection result that disagrees with what the shader declares is a defect,
//! so this file re-derives every binding from `OpDecorate` and `OpTypeImage`
//! and never carries a value over from a previous pass.
//!
//! This pass does not check all module types. It checks the scalar declarations
//! needed for specialization and reads descriptor types for bind group layouts.

const std = @import("std");
const error_mod = @import("error.zig");
const grammar = @import("grammar.zig");
const header = @import("header.zig");
const instruction = @import("instruction.zig");
const version_mod = @import("version.zig");
const word = @import("word.zig");
const workgroup = @import("workgroup.zig");

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
    array_size: u32 = 1,
    /// True only for an OpTypeSampledImage descriptor, not separate image/sampler use.
    combined_image_sampler: bool = false,
    buffer_read_only: bool = false,
    image_dimension: ?Dim = null,
    image_arrayed: bool = false,
    image_multisampled: bool = false,
    image_depth: bool = false,
    sampled_scalar: ?ScalarType = null,
    /// Raw Depth operand: 2 means the declaration does not decide depth use.
    image_depth_mode: ?u32 = null,
    /// Raw Sampled operand: 0 leaves sampled versus storage use undecided.
    image_sampled: ?u32 = null,
    image_format: ?u32 = null,
    storage_read_only: bool = false,
    storage_write_only: bool = false,
};

pub const EntryPoint = struct {
    execution_model: ExecutionModel,
    id: u32,

    /// Borrowed from the words `reflect` was given.
    name: []const u8,
    resources: []Resource,
    /// Compute dimensions, borrowed ID declarations, or an absent declaration.
    workgroup_size: workgroup.Size = .missing,
    /// Presence for this entry, independent of WorkgroupSize built-in precedence.
    has_local_size_id: bool = false,
};

pub const ScalarType = union(enum) {
    boolean,
    signed_integer: u32,
    unsigned_integer: u32,
    float: u32,
};

pub const SpecializationConstant = struct {
    result_id: u32,
    spec_id: u32,
    /// Borrowed from the module words; empty when no OpName is present.
    name: []const u8,
    scalar_type: ScalarType,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    version: Version,
    generator_magic: u32,
    id_bound: u32,
    /// Borrowed words must remain live and unchanged until deinit.
    words: []const Word,

    /// In the order the module declares them.
    entry_points: []EntryPoint,
    specialization_constants: []SpecializationConstant,

    /// Names borrow the words `reflect` was given, so a `Module` must not
    /// outlive them. Both metadata slices and resource arrays are owned.
    pub fn deinit(self: Module) void {
        for (self.entry_points) |entry_point| freeResources(self.allocator, entry_point.resources);
        self.allocator.free(self.entry_points);
        self.allocator.free(self.specialization_constants);
    }

    pub const WorkgroupOverride = workgroup.Override;
    pub const WorkgroupError = workgroup.Error;

    /// Resolve encoded defaults and canonical SpecId overrides without allocation.
    /// Unsupported expressions are distinct from malformed declarations.
    pub fn resolveWorkgroupSize(
        self: Module,
        entry_id: u32,
        overrides: []const WorkgroupOverride,
    ) WorkgroupError![3]u32 {
        for (self.entry_points) |entry| {
            if (entry.id != entry_id) continue;
            if (@backingInt(entry.execution_model) != 5)
                return error.SpirvWorkgroupEntryPoint;
            return workgroup.resolve(
                self.words,
                entry.workgroup_size,
                .{ .slice = overrides },
                self.specialization_constants,
            );
        }
        return error.SpirvWorkgroupEntryPoint;
    }

    /// Borrow the normalized specialization encoding: LE SpecId, type, width,
    /// byte size, then LE bits. This does not convert scalar values.
    pub fn resolveWorkgroupSizeCanonical(
        self: Module,
        entry_id: u32,
        canonical_bytes: []const u8,
    ) WorkgroupError![3]u32 {
        for (self.entry_points) |entry| {
            if (entry.id != entry_id) continue;
            if (@backingInt(entry.execution_model) != 5)
                return error.SpirvWorkgroupEntryPoint;
            return workgroup.resolve(
                self.words,
                entry.workgroup_size,
                .{ .canonical = canonical_bytes },
                self.specialization_constants,
            );
        }
        return error.SpirvWorkgroupEntryPoint;
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

    var tables: Tables = .{ .allocator = allocator, .id_bound = module_header.id_bound };
    defer tables.deinit();

    try tables.readDeclarations(words);
    try tables.readDecorations(words);
    try tables.applyGroups(words);
    try tables.applyRecords();
    if (module_header.version.minor < 4 and tables.variables.count() != 0)
        try tables.readFunctions(words);

    const specialization_constants = try tables.readSpecializationConstants();
    errdefer allocator.free(specialization_constants);

    return .{
        .allocator = allocator,
        .version = module_header.version,
        .generator_magic = module_header.generator_magic,
        .id_bound = module_header.id_bound,
        .words = words,
        .entry_points = try readEntryPoints(allocator, words, &tables),
        .specialization_constants = specialization_constants,
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
        if (fields.id == 0 or fields.id >= tables.id_bound) return error.SpirvMalformed;
        const workgroup_size = try workgroup.read(
            words,
            fields.id,
            @backingInt(fields.execution_model) == 5,
        );
        const resources = try readResources(
            allocator,
            words,
            fields,
            tables,
        );
        errdefer freeResources(allocator, resources);

        try entry_points.append(allocator, .{
            .execution_model = fields.execution_model,
            .id = fields.id,
            .name = fields.name,
            .resources = resources,
            .workgroup_size = workgroup_size.size,
            .has_local_size_id = workgroup_size.has_local_size_id,
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
    words: []const Word,
    fields: instruction.EntryPointFields,
    tables: *const Tables,
) ErrorOrOutOfMemory![]Resource {
    var resources: std.ArrayList(Resource) = .empty;
    errdefer resources.deinit(allocator);

    const version = try version_mod.decode(words[1]);
    if (version.minor >= 4) {
        for (fields.interface) |variable_id| {
            try tables.checkId(variable_id);
            const resource = try tables.resourceFor(variable_id) orelse continue;
            try resources.append(allocator, resource);
        }
    } else if (tables.variables.count() != 0) {
        try readStaticResources(allocator, words, fields.id, tables, &resources);
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

const FunctionBody = struct {
    start: usize,
    end: usize,
};

/// Index function bodies once. Each entry visits each reachable body once, even with cycles.
fn readStaticResources(
    allocator: std.mem.Allocator,
    words: []const Word,
    entry_id: u32,
    tables: *const Tables,
    resources: *std.ArrayList(Resource),
) ErrorOrOutOfMemory!void {
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);
    var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer used.deinit(allocator);
    try enqueueFunction(allocator, entry_id, tables, &visited, &pending);
    var next: usize = 0;
    const function_bound = tables.functions.count();
    while (next < pending.items.len and next < function_bound) : (next += 1) {
        const body = tables.functions.get(pending.items[next]) orelse return error.SpirvMalformed;
        var body_cursor: instruction.Cursor = .{ .words = words[0..body.end], .index = body.start };
        while (try body_cursor.next()) |inst| {
            if (inst.opcode() == 57) {
                const operands = inst.operands();
                if (operands.len < 3) return error.SpirvMalformed;
                try enqueueFunction(
                    allocator,
                    operands[2],
                    tables,
                    &visited,
                    &pending,
                );
            }
            try recordStaticOperands(allocator, inst, tables, &used, resources);
        }
    }
    if (next != pending.items.len) return error.SpirvMalformed;
}

fn enqueueFunction(
    allocator: std.mem.Allocator,
    id: u32,
    tables: *const Tables,
    visited: *std.AutoHashMapUnmanaged(u32, void),
    pending: *std.ArrayList(u32),
) ErrorOrOutOfMemory!void {
    try tables.checkId(id);
    if (!tables.functions.contains(id)) return error.SpirvMalformed;
    const record = try visited.getOrPut(allocator, id);
    if (record.found_existing) return;
    try pending.append(allocator, id);
}

/// Only ID operands that can name a global pointer are resource references.
/// Literal masks, alignment, member indices, and debug line numbers are not IDs.
/// Operand positions follow SPIRV-Headers cb42dec3830d3ac67fa449ecdc0c0f73d5e74498.
fn recordStaticOperands(
    allocator: std.mem.Allocator,
    inst: instruction.Instruction,
    tables: *const Tables,
    used: *std.AutoHashMapUnmanaged(u32, void),
    resources: *std.ArrayList(Resource),
) ErrorOrOutOfMemory!void {
    const operands = inst.operands();
    const range: struct { start: usize, end: usize } = switch (inst.opcode()) {
        12 => .{ .start = 4, .end = operands.len }, // OpExtInst arguments.
        57 => .{ .start = 3, .end = operands.len }, // OpFunctionCall arguments.
        59 => .{ .start = 3, .end = operands.len }, // OpVariable initializer.
        60, 61, 65, 66, 67, 68, 69, 70, 81, 83, 117, 121, 122, 123, 124, 227, 229...242, 318, 321, 400, 4457, 5302, 5359, 5367, 5398, 5614, 5615, 5934, 5938, 6035, 6258 => .{ .start = 2, .end = 3 },
        80 => .{ .start = 2, .end = operands.len }, // Composite constituent IDs.
        79, 82 => .{ .start = 2, .end = 4 }, // Exclude literal component indices.
        62, 63, 64 => .{ .start = 0, .end = 2 }, // Store and memory copies.
        228, 256, 257, 319, 4458, 5290, 5291, 5303, 5360, 5368, 6259 => .{ .start = 0, .end = 1 },
        259 => .{ .start = 3, .end = 5 }, // Group copy destination/source.
        169 => .{ .start = 3, .end = 5 }, // OpSelect pointer values.
        245 => .{ .start = 2, .end = operands.len }, // OpPhi value/label pairs.
        254 => .{ .start = 0, .end = 1 }, // OpReturnValue.
        401, 402, 403 => .{ .start = 2, .end = 4 }, // Pointer comparison/difference.
        else => return,
    };
    if (range.start > range.end or range.end > operands.len) return error.SpirvMalformed;
    for (operands[range.start..range.end]) |id| {
        try tables.checkId(id);
        if (used.contains(id)) continue;
        const resource = try tables.resourceFor(id) orelse continue;
        const record = try used.getOrPut(allocator, id);
        if (!record.found_existing) try resources.append(allocator, resource);
    }
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
    sampled_type: u32,
    depth: u32,
    arrayed: bool,
    multisampled: bool,
    format: u32,
    access: ?u32,
};

/// `Block` and `BufferBlock` name different bindings. SPIR-V 1.3 gave a
/// storage buffer its own storage class, so `BufferBlock` is how a storage
/// buffer was spelled before it.
const Block = enum {
    uniform,
    storage,
};

const TypeInfo = union(enum) {
    scalar: ScalarType,
    structure: []const Word,
    pointer: u32,
    image: ImageType,
    sampled_image: u32,
    sampler,
    array: struct { element: u32, length: u32 },
    block: struct { kind: Block, members: []const Word },
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
    spec_id: ?u32 = null,
    non_writable: bool = false,
    non_readable: bool = false,

    /// A target can carry its own decoration and a group's at once, so the two
    /// records combine rather than one replacing the other.
    fn merge(have: DecorationRecord, other: DecorationRecord) Error!DecorationRecord {
        if (have.spec_id != null and other.spec_id != null) return error.SpirvMalformed;
        return .{
            .set = other.set orelse have.set,
            .binding = other.binding orelse have.binding,
            .input_attachment_index = other.input_attachment_index orelse have.input_attachment_index,
            .block = other.block orelse have.block,
            .spec_id = other.spec_id orelse have.spec_id,
            .non_writable = have.non_writable or other.non_writable,
            .non_readable = have.non_readable or other.non_readable,
        };
    }
};

const SpecDeclaration = struct {
    type_id: u32,
    opcode: grammar.Opcode,
    literal_word_count: usize,
};

/// What the walks over a module learned, keyed by id.
///
/// The maps are sparse on purpose. A module declares tens of ids and reserves a
/// bound far above them, so a table indexed by the bound would allocate for ids
/// no module uses.
const Tables = struct {
    allocator: std.mem.Allocator,
    id_bound: u32,
    types: std.AutoHashMapUnmanaged(u32, TypeInfo) = .empty,
    variables: std.AutoHashMapUnmanaged(u32, Variable) = .empty,
    functions: std.AutoHashMapUnmanaged(u32, FunctionBody) = .empty,
    constants: std.AutoHashMapUnmanaged(u32, []const Word) = .empty,
    member_access: std.AutoHashMapUnmanaged(u64, DecorationRecord) = .empty,
    decorations: std.AutoHashMapUnmanaged(u32, DecorationRecord) = .empty,
    names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    groups: std.AutoHashMapUnmanaged(u32, void) = .empty,
    specs: std.AutoHashMapUnmanaged(u32, SpecDeclaration) = .empty,

    fn deinit(self: *Tables) void {
        self.types.deinit(self.allocator);
        self.variables.deinit(self.allocator);
        self.decorations.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.member_access.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.specs.deinit(self.allocator);
        // `HashMapUnmanaged.deinit` leaves the fields as it found them, so the
        // maps keep pointing at freed memory. Nothing reads `tables` after the
        // `defer` in `reflect` runs, so the struct is destroyed rather than
        // left half-valid.
        self.* = undefined;
    }

    fn checkId(self: *const Tables, id: u32) Error!void {
        if (id == 0 or id >= self.id_bound) return error.SpirvMalformed;
    }

    fn readFunctions(self: *Tables, words: []const Word) ErrorOrOutOfMemory!void {
        var cursor = instruction.Cursor.init(words);
        var current_id: ?u32 = null;
        var start: usize = 0;
        while (try cursor.next()) |inst| {
            const operands = inst.operands();
            switch (inst.opcode()) {
                54 => {
                    if (current_id != null or operands.len != 4) return error.SpirvMalformed;
                    try self.checkId(operands[1]);
                    current_id = operands[1];
                    start = cursor.index;
                },
                56 => {
                    const id = current_id orelse return error.SpirvMalformed;
                    if (operands.len != 0) return error.SpirvMalformed;
                    const record = try self.functions.getOrPut(self.allocator, id);
                    if (record.found_existing) return error.SpirvMalformed;
                    record.value_ptr.* = .{
                        .start = start,
                        .end = cursor.index - inst.words.len,
                    };
                    current_id = null;
                },
                else => {},
            }
        }
        if (current_id != null) return error.SpirvMalformed;
    }

    fn readDeclarations(self: *Tables, words: []const Word) ErrorOrOutOfMemory!void {
        var cursor: instruction.Cursor = instruction.Cursor.init(words);
        var in_function = false;
        while (try cursor.next()) |inst| {
            const raw_operands = inst.operands();
            if (inst.opcode() == 27) {
                if (raw_operands.len != 2) return error.SpirvMalformed;
                for (raw_operands) |id| try self.checkId(id);
                try self.types.put(self.allocator, raw_operands[0], .{
                    .sampled_image = raw_operands[1],
                });
            }
            if (inst.opcode() == 28) {
                if (raw_operands.len != 3) return error.SpirvMalformed;
                for (raw_operands) |id| try self.checkId(id);
                try self.types.put(self.allocator, raw_operands[0], .{ .array = .{
                    .element = raw_operands[1],
                    .length = raw_operands[2],
                } });
            } else if (inst.opcode() == 43) {
                if (raw_operands.len < 3) return error.SpirvMalformed;
                try self.checkId(raw_operands[0]);
                try self.checkId(raw_operands[1]);
                try self.constants.put(self.allocator, raw_operands[1], raw_operands);
            }
            // An opcode the reader does not model is an instruction this pass
            // has no use for, not a malformed module: a module may legally
            // carry hundreds of them, and each declares its own word count, so
            // skipping one leaves the walk exact. The skip joins the modelled
            // opcodes these tables do not act on.
            const opcode = inst.knownOpcode() orelse continue;
            const operands = inst.operands();
            switch (opcode) {
                .function => in_function = true,
                .function_end => in_function = false,
                .name => {
                    if (operands.len < 2) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    const name = try word.decodeString(operands[1..]);
                    try self.names.put(self.allocator, operands[0], name);
                },
                .decoration_group => {
                    if (operands.len != 1) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    try self.groups.put(self.allocator, operands[0], {});
                },
                .type_boolean => {
                    if (operands.len != 1) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    try self.types.put(self.allocator, operands[0], .{ .scalar = .boolean });
                },
                .type_integer => {
                    if (operands.len != 3) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    const width = operands[1];
                    if (width != 8 and width != 16 and width != 32 and width != 64)
                        return error.SpirvMalformed;
                    if (operands[2] > 1) return error.SpirvMalformed;
                    const scalar: ScalarType = if (operands[2] == 0)
                        .{ .unsigned_integer = width }
                    else
                        .{ .signed_integer = width };
                    try self.types.put(self.allocator, operands[0], .{ .scalar = scalar });
                },
                .type_float => {
                    if (operands.len != 2) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    const width = operands[1];
                    if (width != 16 and width != 32 and width != 64)
                        return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .{
                        .scalar = .{ .float = width },
                    });
                },
                .spec_constant_true, .spec_constant_false, .spec_constant => {
                    if (operands.len < 2) return error.SpirvMalformed;
                    if (in_function) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    try self.checkId(operands[1]);
                    const result = try self.specs.getOrPut(self.allocator, operands[1]);
                    if (result.found_existing) return error.SpirvMalformed;
                    result.value_ptr.* = .{
                        .type_id = operands[0],
                        .opcode = opcode,
                        .literal_word_count = operands.len - 2,
                    };
                },
                .type_structure => {
                    if (operands.len < 1) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    try self.types.put(self.allocator, operands[0], .{
                        .structure = operands[1..],
                    });
                },
                .type_pointer => {
                    if (operands.len != 3) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    try self.checkId(operands[2]);
                    try self.types.put(self.allocator, operands[0], .{ .pointer = operands[2] });
                },
                .type_image => {
                    if (operands.len < 8 or operands.len > 9) return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    try self.checkId(operands[1]);
                    if (operands[3] > 2 or operands[4] > 1 or
                        operands[5] > 1 or operands[6] > 2) return error.SpirvMalformed;
                    const dim = grammar.Dim.fromRaw(operands[2]) orelse
                        return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .{
                        .image = .{
                            .dim = dim,
                            .sampled = operands[6],
                            .sampled_type = operands[1],
                            .depth = operands[3],
                            .arrayed = operands[4] == 1,
                            .multisampled = operands[5] == 1,
                            .format = operands[7],
                            .access = if (operands.len == 9) operands[8] else null,
                        },
                    });
                },
                .type_sampler => {
                    if (operands.len < 1) return error.SpirvMalformed;
                    try self.types.put(self.allocator, operands[0], .sampler);
                },
                .variable => {
                    if (operands.len < 3) return error.SpirvMalformed;
                    if (in_function) continue;
                    try self.checkId(operands[0]);
                    try self.checkId(operands[1]);
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
                    if (record.spec_id != null and opcode != .decorate)
                        return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    // A target carries `DescriptorSet` and `Binding` in two
                    // separate instructions, so the records merge rather than
                    // the later one replacing the earlier, which would leave
                    // every descriptor without a set or without a binding.
                    const own = self.decorations.get(operands[0]);
                    const merged = if (own) |have| try have.merge(record) else record;
                    try self.decorations.put(self.allocator, operands[0], merged);
                },
                .member_decorate, .member_decorate_string => {
                    if (operands.len < 3) return error.SpirvMalformed;
                    if (operands[2] == @backingInt(grammar.Decoration.spec_id))
                        return error.SpirvMalformed;
                    try self.checkId(operands[0]);
                    const record = try readDecorationRecord(operands[2..]) orelse continue;
                    if (record.non_writable or record.non_readable)
                        try self.mergeMemberAccess(operands[0], operands[1], record);
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
            if (inst.opcode() == 75) {
                if (operands.len < 3 or operands.len % 2 != 1)
                    return error.SpirvMalformed;
                if (!self.groups.contains(operands[0])) return error.SpirvMalformed;
                const group = self.decorations.get(operands[0]) orelse continue;
                if (!group.non_writable and !group.non_readable) continue;
                var index: usize = 1;
                while (index < operands.len) : (index += 2) {
                    try self.mergeMemberAccess(operands[index], operands[index + 1], group);
                }
                continue;
            }
            if (inst.knownOpcode() != .group_decorate) continue;
            if (operands.len < 2) return error.SpirvMalformed;
            if (!self.groups.contains(operands[0])) return error.SpirvMalformed;

            const group = self.decorations.get(operands[0]) orelse continue;
            for (operands[1..]) |target| {
                const own = self.decorations.get(target);
                if (self.groups.contains(target)) return error.SpirvMalformed;
                const merged = if (own) |have| try have.merge(group) else group;
                try self.decorations.put(self.allocator, target, merged);
            }
        }
    }

    fn mergeMemberAccess(
        self: *Tables,
        structure_id: u32,
        member_index: u32,
        record: DecorationRecord,
    ) ErrorOrOutOfMemory!void {
        try self.checkId(structure_id);
        const structure = self.types.get(structure_id) orelse return error.SpirvMalformed;
        const members = switch (structure) {
            .structure => |values| values,
            .block => |block| block.members,
            else => return error.SpirvMalformed,
        };
        if (member_index >= members.len) return error.SpirvMalformed;
        const key = (@as(u64, structure_id) << 32) | member_index;
        const own = self.member_access.get(key);
        const merged = if (own) |have| try have.merge(record) else record;
        try self.member_access.put(self.allocator, key, merged);
    }

    /// Moves each collected record onto the thing it decorates. A binding names
    /// a variable and `Block` names a struct, so a record aimed at anything
    /// else is a module that does not say what it means.
    fn applyRecords(self: *Tables) ErrorOrOutOfMemory!void {
        var records = self.decorations.iterator();
        while (records.next()) |record| {
            const id = record.key_ptr.*;
            const value = record.value_ptr.*;
            if (self.groups.contains(id)) continue;
            if (value.spec_id != null) {
                if (!self.specs.contains(id)) return error.SpirvMalformed;
                if (value.block != null or value.set != null or value.binding != null or
                    value.input_attachment_index != null) return error.SpirvMalformed;
                continue;
            }

            if (value.block) |block| {
                // The id must already be declared as the struct the block
                // names. The optional is unwrapped first: `.structure` would
                // otherwise be read as an optional payload or as a union tag,
                // and the two cannot be told apart in one literal.
                const existing = self.types.get(id) orelse
                    return error.SpirvMalformed;
                if (existing != .structure) return error.SpirvMalformed;
                try self.types.put(self.allocator, id, .{ .block = .{
                    .kind = block,
                    .members = existing.structure,
                } });
                continue;
            }
            if (value.set == null and value.binding == null and
                value.input_attachment_index == null) continue;

            const variable = self.variables.getPtr(id) orelse
                return error.SpirvMalformed;
            variable.set = value.set orelse variable.set;
            variable.binding = value.binding orelse variable.binding;
            variable.input_attachment_index =
                value.input_attachment_index orelse variable.input_attachment_index;
        }
    }

    fn readSpecializationConstants(
        self: *const Tables,
    ) ErrorOrOutOfMemory![]SpecializationConstant {
        var constants: std.ArrayList(SpecializationConstant) = .empty;
        errdefer constants.deinit(self.allocator);
        var declarations = self.specs.iterator();
        while (declarations.next()) |entry| {
            const id = entry.key_ptr.*;
            const declaration = entry.value_ptr.*;
            const type_info = self.types.get(declaration.type_id) orelse
                return error.SpirvMalformed;
            const scalar = switch (type_info) {
                .scalar => |value| value,
                else => return error.SpirvMalformed,
            };
            const expected_words: usize = switch (scalar) {
                .boolean => blk: {
                    if (declaration.opcode != .spec_constant_true and
                        declaration.opcode != .spec_constant_false) return error.SpirvMalformed;
                    break :blk 0;
                },
                .signed_integer, .unsigned_integer, .float => |width| blk: {
                    if (declaration.opcode != .spec_constant) return error.SpirvMalformed;
                    break :blk @divFloor(width + 31, 32);
                },
            };
            if (declaration.literal_word_count != expected_words) return error.SpirvMalformed;
            const decorations = self.decorations.get(id) orelse continue;
            const spec_id = decorations.spec_id orelse continue;
            try constants.append(self.allocator, .{
                .result_id = id,
                .spec_id = spec_id,
                .name = self.names.get(id) orelse "",
                .scalar_type = scalar,
            });
        }
        std.mem.sort(SpecializationConstant, constants.items, {}, lessBySpecId);
        return constants.toOwnedSlice(self.allocator);
    }

    /// The descriptor at one global variable, or null when the variable is not
    /// a descriptor. An `Input`, an `Output` or a `Private` global is an
    /// interface variable, not a binding, and carries no `Binding` decoration.
    fn resourceFor(self: *const Tables, variable_id: u32) Error!?Resource {
        const variable = self.variables.get(variable_id) orelse return null;
        const set = variable.set orelse return null;
        const binding = variable.binding orelse return null;
        const pointer = self.types.get(variable.pointer_type) orelse
            return error.SpirvMalformed;
        var pointee_id = switch (pointer) {
            .pointer => |id| id,
            else => return error.SpirvMalformed,
        };
        var array_size: u32 = 1;
        var remaining = self.types.count();
        var pointee: TypeInfo = undefined;
        while (remaining != 0) : (remaining -= 1) {
            pointee = self.types.get(pointee_id) orelse return error.SpirvMalformed;
            if (pointee != .array) break;
            const length = try self.arrayLength(pointee.array.length);
            const product = @mulWithOverflow(array_size, length);
            if (product[1] != 0) return error.SpirvMalformed;
            array_size = product[0];
            pointee_id = pointee.array.element;
        }
        if (remaining == 0) return error.SpirvMalformed;
        const combined_image_sampler = pointee == .sampled_image;
        if (combined_image_sampler) {
            pointee_id = pointee.sampled_image;
            pointee = self.types.get(pointee_id) orelse return error.SpirvMalformed;
            if (pointee != .image) return error.SpirvMalformed;
            if (pointee.image.sampled == storage_image_value) return error.SpirvMalformed;
        }
        const kind = classify(variable, pointee) orelse return null;
        const own_access = self.decorations.get(variable_id) orelse DecorationRecord{};
        const pointer_access = self.decorations.get(variable.pointer_type) orelse
            DecorationRecord{};
        const type_access = self.decorations.get(pointee_id) orelse DecorationRecord{};
        const non_writable = own_access.non_writable or pointer_access.non_writable or
            type_access.non_writable;
        const non_readable = own_access.non_readable or pointer_access.non_readable or
            type_access.non_readable;
        var resource: Resource = .{
            .kind = kind,
            .set = set,
            .binding = binding,
            .array_size = array_size,
            .combined_image_sampler = combined_image_sampler,
            .buffer_read_only = non_writable or self.allMembersNonWritable(pointee_id, pointee),
            .storage_read_only = non_writable,
            .storage_write_only = non_readable,
        };
        if (pointee == .image) {
            const image = pointee.image;
            const sampled_type = self.types.get(image.sampled_type) orelse
                return error.SpirvMalformed;
            resource.image_dimension = image.dim;
            resource.image_depth = image.depth == 1;
            resource.image_depth_mode = image.depth;
            resource.image_sampled = image.sampled;
            resource.image_arrayed = image.arrayed;
            resource.image_multisampled = image.multisampled;
            resource.image_format = image.format;
            resource.sampled_scalar = switch (sampled_type) {
                .scalar => |scalar| scalar,
                else => return error.SpirvMalformed,
            };
            if (image.access) |access| {
                if (access > 2) return error.SpirvMalformed;
                resource.storage_read_only = resource.storage_read_only or access == 0;
                resource.storage_write_only = resource.storage_write_only or access == 1;
            }
        }
        return resource;
    }

    fn arrayLength(self: *const Tables, id: u32) Error!u32 {
        const constant = self.constants.get(id) orelse return error.SpirvMalformed;
        const type_info = self.types.get(constant[0]) orelse return error.SpirvMalformed;
        const scalar = switch (type_info) {
            .scalar => |value| value,
            else => return error.SpirvMalformed,
        };
        switch (scalar) {
            .unsigned_integer, .signed_integer => |width| {
                const expected_words: usize = if (width == 64) 4 else 3;
                if (constant.len != expected_words or constant[2] == 0)
                    return error.SpirvMalformed;
                if (width == 64 and constant[3] != 0) return error.SpirvMalformed;
                if (width < 32 and constant[2] >> @as(u5, @intCast(width)) != 0)
                    return error.SpirvMalformed;
                if (scalar == .signed_integer and width <= 32 and
                    constant[2] >> @as(u5, @intCast(width - 1)) != 0)
                    return error.SpirvMalformed;
            },
            else => return error.SpirvMalformed,
        }
        return constant[2];
    }

    fn allMembersNonWritable(
        self: *const Tables,
        id: u32,
        type_info: TypeInfo,
    ) bool {
        const members = switch (type_info) {
            .block => |block| block.members,
            .structure => |values| values,
            else => return false,
        };
        if (members.len == 0) return false;
        for (members, 0..) |_, index| {
            const key = (@as(u64, id) << 32) | @as(u32, @intCast(index));
            const access = self.member_access.get(key) orelse return false;
            if (!access.non_writable) return false;
        }
        return true;
    }
};

fn lessBySpecId(_: void, left: SpecializationConstant, right: SpecializationConstant) bool {
    if (left.spec_id != right.spec_id) return left.spec_id < right.spec_id;
    return left.result_id < right.result_id;
}

/// The three decorations that name a bind group entry, plus the two that make
/// a struct a block, or null when the instruction carries none of them.
fn readDecorationRecord(literal_words: []const Word) Error!?DecorationRecord {
    if (literal_words.len == 0) return null;

    const decoration = grammar.Decoration.fromRaw(literal_words[0]) orelse return null;
    return switch (decoration) {
        .spec_id => blk: {
            if (literal_words.len != 2) return error.SpirvMalformed;
            break :blk .{ .spec_id = literal_words[1] };
        },
        .descriptor_set => .{ .set = try readLiteral(literal_words[1..]) },
        .binding => .{ .binding = try readLiteral(literal_words[1..]) },
        .input_attachment_index => .{
            .input_attachment_index = try readLiteral(literal_words[1..]),
        },
        .block => .{ .block = .uniform },
        .buffer_block => .{ .block = .storage },
        .non_writable => .{ .non_writable = true },
        .non_readable => .{ .non_readable = true },
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
            .block => |block| switch (block.kind) {
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
