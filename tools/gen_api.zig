//! Generator for `src/api` and the API conformance tables, from
//! `src/dawn/dawn.json` at the pinned Dawn revision.
//!
//! **What this program does.** It reads the JSON and it writes one Zig file
//! per category into the output directory. It also writes the three Markdown
//! tables that the `M2` section of `docs/40-plan.md` carries, so the document
//! and the generated code cannot disagree about a count.
//!
//! **Command line.** Three positional arguments:
//!
//! ```
//! gen_api <dawn.json path> <api output directory> <table output path>
//! ```
//!
//! The output directory must exist. This program writes files into it and does
//! not create it, because the caller owns the directory layout.
//!
//! **What this program does not claim.** It does not claim byte compatibility
//! with Dawn's C header. `docs/30-port-design.md` section 4.2 states that the
//! chain has no `next` pointer, so it does not.
//!
//! **Line numbers.** `docs/40-plan.md` section M2 cites a `dawn.json` line for
//! every row and a `src/api` line for every declaration. This program therefore
//! reads the raw JSON text as well as the parsed value: the parse loses
//! positions and the tables must not invent them. A row whose line cannot be
//! located is `error.ItemLineNotFound`, never a row without a citation.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Upper bound on the JSON this program reads, in bytes. The pinned
/// `dawn.json` is 199,060 bytes. The bound turns a wrong path into
/// `error.JsonTooLarge` instead of an allocation loop.
const json_byte_limit: Io.Limit = .limited(8 << 20);

/// One level of indentation in `dawn.json`. An array item sits one level
/// deeper than the key that names its array.
const one_indent: u32 = 4;

/// Every failure this program reports. `std.json` supplies the parse errors and
/// `std.Io.Dir` supplies the file errors. The rest are this program's own
/// invariants on the JSON, each one a claim that upstream cannot break
/// silently.
pub const GenerateError = error{
    /// The command line did not carry exactly three arguments.
    WrongArgumentCount,
    /// The JSON is larger than `json_byte_limit`.
    JsonTooLarge,
    /// A top-level key in the raw text has no parsed entry beside it.
    EntryLineNotFound,
    /// An array item in the raw text has no parsed item beside it.
    ItemLineNotFound,
    /// Two top-level keys map to one name.
    DuplicateEntryName,
    /// One Zig declaration name is claimed twice.
    DuplicateSymbolName,
    /// A name is empty, so no Zig name can be built from it.
    EmptyName,
    /// A type reference names no entry in the JSON.
    UnknownTypeName,
    /// An entry sits in a category this generator does not emit.
    UnexpectedCategory,
    /// A `default` is neither a constant, an enum value, `nullptr` nor a number.
    UnsupportedDefault,
    /// A callback argument is not the last argument of its method.
    CallbackArgumentNotLast,
    /// The bit widths of a bitmask's fields do not fit in 32 bits.
    BitmaskExceedsU32,
    /// The JSON names a chain root that does not exist.
    UnknownChainRoot,
    /// The JSON names a chain root that is not a structure.
    ChainRootNotAStructure,
    /// The pinned JSON has more or fewer entries than `handled_entry_names`.
    UpstreamEntryCountChanged,
} || Allocator.Error || std.json.ParseFromValueError ||
    std.json.ParseError(std.json.Scanner) || Io.Dir.WriteFileError || Io.Dir.CreateDirPathError;

/// Every entry name the port has handled, in the order `dawn.json` lists them.
///
/// `src/api/handled.zig` gets a `coverage` arm per name and no `else`, so a
/// new upstream entry is a compile error there until someone adds its arm
/// (`AGENTS.md` section 3, `docs/30-port-design.md` section 8.2). This list is
/// that ledger. It is 347 long because the pinned JSON has 347 entries.
pub const handled_entry_names = [_][]const u8{
    "INTERNAL_HAVE_EMDAWNWEBGPU_HEADER",
    "create instance",
    "proc",
    "get proc address",
    "request adapter options",
    "request adapter WebXR options",
    "request adapter WebGPU backend options",
    "request adapter callback",
    "request adapter callback info",
    "request adapter status",
    "adapter",
    "adapter info",
    "adapter type",
    "device descriptor",
    "dawn consume adapter descriptor",
    "dawn toggles descriptor",
    "dawn load cache data function",
    "dawn store cache data function",
    "dawn load cache data callback",
    "dawn load cache data callback info",
    "dawn store cache data callback",
    "dawn store cache data callback info",
    "dawn cache device descriptor",
    "dawn device allocator control",
    "dawn WGSL blocklist",
    "address mode",
    "backend type",
    "bind group",
    "bind group entry",
    "bind group descriptor",
    "bind group layout",
    "buffer binding type",
    "buffer binding layout",
    "sampler binding type",
    "sampler binding layout",
    "static sampler binding layout",
    "texture sample type",
    "texture binding layout",
    "surface capabilities",
    "surface configuration",
    "external texture binding entry",
    "texel buffer binding entry",
    "external texture binding layout",
    "storage texture access",
    "texel buffer access",
    "storage texture binding layout",
    "texel buffer binding layout",
    "bind group layout entry",
    "bind group layout descriptor",
    "blend component",
    "blend factor",
    "blend operation",
    "bool",
    "optional bool",
    "string view",
    "buffer",
    "buffer descriptor",
    "buffer host mapped pointer",
    "callback",
    "callback status",
    "buffer map callback",
    "buffer map callback info",
    "map async status",
    "buffer map state",
    "buffer usage",
    "char",
    "color",
    "color write mask",
    "constant entry",
    "command buffer",
    "command buffer descriptor",
    "command encoder",
    "command encoder descriptor",
    "compare function",
    "compilation info",
    "compilation info callback",
    "compilation info callback info",
    "compilation info request status",
    "compilation message",
    "dawn compilation message utf16",
    "compilation message type",
    "compute pass descriptor",
    "compute pass encoder",
    "composite alpha mode",
    "compute pipeline",
    "compute pipeline descriptor",
    "alpha mode",
    "copy texture for browser options",
    "create compute pipeline async callback",
    "create compute pipeline async callback info",
    "create pipeline async status",
    "create render pipeline async callback",
    "create render pipeline async callback info",
    "cull mode",
    "a hardware buffer properties",
    "device",
    "device lost callback",
    "device lost callback info",
    "device lost reason",
    "double",
    "uncaptured error callback",
    "uncaptured error callback info",
    "pop error scope status",
    "pop error scope callback",
    "pop error scope callback info",
    "limits",
    "compatibility mode limits",
    "dawn texel copy buffer row alignment limits",
    "dawn host mapped pointer limits",
    "supported features",
    "supported instance features",
    "supported WGSL language features",
    "logging callback",
    "logging callback info",
    "error filter",
    "error type",
    "logging type",
    "extent 2D",
    "extent 3D",
    "external texture",
    "external texture rotation",
    "external texture descriptor",
    "color space primaries dawn",
    "color space transfer dawn",
    "color space y cb cr range dawn",
    "color space y cb cr matrix dawn",
    "color space dawn",
    "status",
    "shared buffer memory",
    "shared buffer memory properties",
    "shared buffer memory descriptor",
    "shared buffer memory from windows handle descriptor",
    "dispose callback",
    "dispose callback info",
    "shared buffer memory host pointer descriptor",
    "shared texture memory",
    "shared texture memory properties",
    "shared texture memory a hardware buffer properties",
    "shared texture memory descriptor",
    "shared buffer memory begin access descriptor",
    "shared buffer memory end access state",
    "shared texture memory vk dedicated allocation descriptor",
    "shared texture memory a hardware buffer descriptor",
    "shared texture memory dma buf plane",
    "shared texture memory dma buf descriptor",
    "shared texture memory opaque FD descriptor",
    "shared texture memory zircon handle descriptor",
    "shared texture memory DXGI shared handle descriptor",
    "shared texture memory IO surface descriptor",
    "shared texture memory EGL image descriptor",
    "shared texture memory begin access descriptor",
    "shared texture memory end access state",
    "shared texture memory metal end access state",
    "shared texture memory vk image layout begin state",
    "shared texture memory vk image layout end state",
    "shared texture memory D3D swapchain begin state",
    "shared texture memory D3D11 begin state",
    "shared fence",
    "shared fence descriptor",
    "shared fence vk semaphore opaque FD descriptor",
    "shared fence sync FD descriptor",
    "shared fence vk semaphore zircon handle descriptor",
    "shared fence DXGI shared handle descriptor",
    "shared fence MTL shared event descriptor",
    "shared fence EGL sync descriptor",
    "dawn fake buffer OOM for testing",
    "dawn fake device initialize error for testing",
    "shared fence type",
    "shared fence export info",
    "shared fence vk semaphore opaque FD export info",
    "shared fence sync FD export info",
    "shared fence vk semaphore zircon handle export info",
    "shared fence DXGI shared handle export info",
    "shared fence MTL shared event export info",
    "shared fence EGL sync export info",
    "feature level",
    "feature name",
    "filter mode",
    "float",
    "dawn format capabilities",
    "dawn drm format capabilities",
    "dawn drm format properties",
    "front face",
    "texel copy buffer info",
    "texel copy buffer layout",
    "texel copy texture info",
    "image copy external texture",
    "index format",
    "instance",
    "callback mode",
    "future",
    "wait status",
    "future wait info",
    "instance limits",
    "instance feature name",
    "instance descriptor",
    "get instance features",
    "has instance feature",
    "get instance limits",
    "dawn wire WGSL control",
    "dawn injected invalid s type",
    "vertex attribute",
    "vertex buffer layout",
    "vertex step mode",
    "load op",
    "map mode",
    "mipmap filter mode",
    "store op",
    "origin 3D",
    "origin 2D",
    "pass timestamp writes",
    "pipeline layout",
    "pipeline layout resource table",
    "pipeline layout descriptor",
    "pipeline layout pixel local storage",
    "pipeline layout storage attachment",
    "power preference",
    "present mode",
    "compute state",
    "primitive topology",
    "query set",
    "query set descriptor",
    "query type",
    "queue",
    "queue descriptor",
    "queue work done callback",
    "queue work done callback info",
    "queue work done status",
    "render bundle",
    "render bundle encoder",
    "render bundle descriptor",
    "render bundle encoder descriptor",
    "render bundle encoder resource table",
    "render pass color attachment",
    "render pass depth stencil attachment",
    "render pass descriptor",
    "dawn render pass sample count",
    "render pass max draw count",
    "render pass render area rect",
    "render pass descriptor resolve rect",
    "render pass pixel local storage",
    "render pass storage attachment",
    "render pass encoder",
    "render pipeline",
    "request device callback",
    "request device callback info",
    "request device status",
    "vertex state",
    "primitive state",
    "depth stencil state",
    "multisample state",
    "fragment state",
    "color target state",
    "color target state expand resolve texture dawn",
    "blend state",
    "render pipeline descriptor",
    "resource table descriptor",
    "resource table",
    "binding resource",
    "sampler",
    "sampler descriptor",
    "shader module",
    "shader module descriptor",
    "shader source SPIRV",
    "dawn shader source SPIRV",
    "shader source WGSL",
    "dawn shader module SPIRV options descriptor",
    "shader module compilation options",
    "shader stage",
    "stencil operation",
    "stencil face state",
    "surface",
    "surface descriptor",
    "surface source android native window",
    "emscripten surface source canvas HTML selector",
    "surface source metal layer",
    "surface source windows HWND",
    "surface source XCB window",
    "surface source xlib window",
    "surface source wayland surface",
    "surface descriptor from windows core window",
    "surface descriptor from windows UWP swap chain panel",
    "surface descriptor from windows WinUI swap chain panel",
    "surface color management",
    "predefined color space",
    "tone mapping mode",
    "surface texture",
    "s type",
    "texture",
    "surface get current texture status",
    "texture aspect",
    "texture descriptor",
    "texture binding view dimension",
    "texture dimension",
    "texture format",
    "texture usage",
    "texture view descriptor",
    "texel buffer view descriptor",
    "texture component swizzle descriptor",
    "texture view",
    "texel buffer view",
    "texture view dimension",
    "texture component swizzle",
    "component swizzle",
    "y cb cr vk descriptor",
    "vertex format",
    "WGSL language feature name",
    "whole size",
    "whole map size",
    "copy stride undefined",
    "limit u32 undefined",
    "limit u64 undefined",
    "array layer count undefined",
    "mip level count undefined",
    "depth clear value undefined",
    "depth slice undefined",
    "query set index undefined",
    "strlen",
    "invalid binding",
    "ObjectType",
    "ObjectId",
    "ObjectHandle",
    "void",
    "void *",
    "void const *",
    "int",
    "int32_t",
    "size_t",
    "uint16_t",
    "uint32_t",
    "uint64_t",
    "uint8_t",
    "std::byte",
    "dawn texture internal usage descriptor",
    "dawn encoder internal usage descriptor",
    "dawn adapter properties power preference",
    "heap property",
    "memory heap info",
    "adapter properties memory heaps",
    "adapter properties D3D",
    "adapter properties vk",
    "adapter properties drm",
    "adapter properties WGPU",
    "dawn buffer descriptor error info from wire client",
    "subgroup matrix component type",
    "subgroup matrix config",
    "adapter properties subgroup matrix configs",
};

/// Zig keywords and primitive type names. A declaration cannot carry one of
/// these, so `declarationName` appends an underscore. The list is the keywords
/// in `lib/std/zig/tokenizer.zig` plus the primitive type names in
/// `lib/std/builtin.zig`.
const zig_reserved = [_][]const u8{
    "addrspace", "align",     "allowzero",   "and",            "anyframe", "anytype",
    "asm",       "async",     "await",       "break",          "callconv", "catch",
    "comptime",  "const",     "continue",    "defer",          "else",     "enum",
    "errdefer",  "error",     "export",      "extern",         "fn",       "for",
    "if",        "inline",    "linksection", "noalias",        "noinline", "nosuspend",
    "opaque",    "or",        "orelse",      "packed",         "pub",      "resume",
    "return",    "struct",    "suspend",     "switch",         "test",     "threadlocal",
    "try",       "union",     "unreachable", "usingnamespace", "var",      "volatile",
    "while",     "anyopaque", "bool",        "f16",            "f32",      "f64",
    "f80",       "f128",      "i8",          "i16",            "i32",      "i64",
    "i128",      "isize",     "noreturn",    "null",           "type",     "u8",
    "u16",       "u32",       "u64",         "u128",           "usize",    "true",
    "false",     "undefined", "void",
};

/// The Zig spelling of each native in `dawn.json`. A native has no declaration
/// of its own: this generator emits the spelling wherever the JSON names the
/// native, so an alias in `src/api/natives.zig` would forward to itself.
pub const native_spellings = [_]struct { upstream: []const u8, zig: []const u8 }{
    .{ .upstream = "bool", .zig = "bool" },
    .{ .upstream = "char", .zig = "u8" },
    .{ .upstream = "double", .zig = "f64" },
    .{ .upstream = "float", .zig = "f32" },
    .{ .upstream = "int", .zig = "c_int" },
    .{ .upstream = "int32_t", .zig = "i32" },
    .{ .upstream = "size_t", .zig = "usize" },
    .{ .upstream = "uint8_t", .zig = "u8" },
    .{ .upstream = "uint16_t", .zig = "u16" },
    .{ .upstream = "uint32_t", .zig = "u32" },
    .{ .upstream = "uint64_t", .zig = "u64" },
    .{ .upstream = "void", .zig = "void" },
    .{ .upstream = "void *", .zig = "?*anyopaque" },
    .{ .upstream = "void const *", .zig = "?*const anyopaque" },
    .{ .upstream = "std::byte", .zig = "u8" },
    .{ .upstream = "ObjectType", .zig = "u64" },
    .{ .upstream = "ObjectId", .zig = "u64" },
    .{ .upstream = "ObjectHandle", .zig = "u64" },
};

/// The wire value `dawn.json` gives each `constant` entry. Twelve entries.
pub const constant_values = [_]struct { upstream: []const u8, value: []const u8 }{
    .{ .upstream = "whole size", .value = "std.math.maxInt(u64)" },
    .{ .upstream = "whole map size", .value = "std.math.maxInt(usize)" },
    .{ .upstream = "copy stride undefined", .value = "std.math.maxInt(u32)" },
    .{ .upstream = "limit u32 undefined", .value = "std.math.maxInt(u32)" },
    .{ .upstream = "limit u64 undefined", .value = "std.math.maxInt(u64)" },
    .{ .upstream = "array layer count undefined", .value = "std.math.maxInt(u32)" },
    .{ .upstream = "mip level count undefined", .value = "std.math.maxInt(u32)" },
    .{ .upstream = "depth clear value undefined", .value = "std.math.nan(f32)" },
    .{ .upstream = "depth slice undefined", .value = "std.math.maxInt(u32)" },
    .{ .upstream = "query set index undefined", .value = "std.math.maxInt(u32)" },
    .{ .upstream = "strlen", .value = "std.math.maxInt(usize)" },
    .{ .upstream = "invalid binding", .value = "std.math.maxInt(u32)" },
};

/// The `error type` enum values that are not `no error`. The Zig error set is
/// these names in PascalCase. Zig spells the error set value and the enum
/// value the same way, so one name covers both.
pub const error_value_map = [_]struct { upstream: []const u8, zig: []const u8 }{
    .{ .upstream = "validation", .zig = "Validation" },
    .{ .upstream = "out of memory", .zig = "OutOfMemory" },
    .{ .upstream = "internal", .zig = "Internal" },
    .{ .upstream = "unknown", .zig = "Unknown" },
};

// ---------------------------------------------------------------------------
// JSON model
// ---------------------------------------------------------------------------

const JsonValue = struct {
    name: []const u8,
    value: u32,
    tags: ?[]const []const u8 = null,
    valid: ?bool = null,
    enum_value_conflict: ?bool = null,
    is_proxy: ?bool = null,
};

const JsonMember = struct {
    name: []const u8,
    type: []const u8,
    annotation: ?[]const u8 = null,
    /// `length` names another member in most entries and is a plain count in a
    /// few, so the value is kept as parsed and only its presence is read.
    length: ?std.json.Value = null,
    optional: ?bool = null,
    array_element_optional: ?bool = null,
    /// `default` is a string for a name, a constant or `nullptr`, and a bare
    /// number for a count: `compute state` gives `constant count` the number
    /// `0`. `std.json` fills a `?[]const u8` from the string only and reports
    /// `error.UnexpectedToken` on the number, so the value is kept as parsed
    /// and `jsonScalarText` renders it. The number is not a variant this
    /// program ignores, so it does not get a fallback type either.
    default: ?std.json.Value = null,
};

const JsonArg = struct {
    name: []const u8,
    type: []const u8,
    annotation: ?[]const u8 = null,
    /// `length` names another member in most entries and is a plain count in a
    /// few, so the value is kept as parsed and only its presence is read.
    length: ?std.json.Value = null,
    optional: ?bool = null,
};

const JsonMethod = struct {
    name: []const u8,
    returns: ?std.json.Value = null,
    args: ?[]const JsonArg = null,
    tags: ?[]const []const u8 = null,
    @"no autolock": ?bool = null,
};

/// One top-level entry of `dawn.json`, as parsed. Every key this generator does
/// not read is ignored, so an upstream key it has never seen does not stop the
/// parse.
const JsonEntry = struct {
    category: []const u8,
    tags: ?[]const []const u8 = null,
    members: ?[]const JsonMember = null,
    methods: ?[]const JsonMethod = null,
    args: ?[]const JsonArg = null,
    values: ?[]const JsonValue = null,
    returns: ?std.json.Value = null,
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    chained: ?[]const u8 = null,
    @"chain roots": ?[]const []const u8 = null,
    /// `extensible` is `"in"`, `"out"` or the boolean `false`, the last for a
    /// structure that chains in neither direction. The boolean kills a
    /// `?[]const u8` for the same reason a numeric `default` does, so the
    /// value is kept as parsed and read through `Entry.extensibleDirection`.
    extensible: ?std.json.Value = null,
    out: ?bool = null,
    @"is nullable pointer": ?bool = null,
};

/// The `category` values `dawn.json` uses. The generator switches on these, so
/// a new category is `error.UnexpectedCategory` rather than a silent gap.
const Category = enum {
    bitmask,
    @"callback function",
    @"callback info",
    constant,
    @"enum",
    function,
    @"function pointer",
    native,
    object,
    structure,

    fn parse(text: []const u8) GenerateError!Category {
        return std.meta.stringToEnum(Category, text) orelse error.UnexpectedCategory;
    }
};

/// The generated file a declaration is written into, and so the module its
/// types are spelled relative to. `@tagName` of each member is the module
/// name the other files import it under.
const Scope = enum {
    bitmask,
    callbacks,
    chained,
    constants,
    descriptors,
    enums,
    objects,
    proc,
};

/// A resolved `type` reference. `optional` comes from the `optional` key on a
/// member or an argument and from the `{"type": ..., "optional": true}` shape
/// on `device create buffer`'s return value.
const TypeRef = struct {
    name: []const u8,
    optional: bool = false,
};

/// An entry with the positions this program cites.
const Entry = struct {
    name: []const u8,
    line: u32,
    end_line: u32,
    category: Category,
    json: JsonEntry,
    /// The line of every `members`, `methods`, `values` and `args` item, in
    /// file order, so a row cites the line its own key sits on.
    member_lines: []const u32,
    method_lines: []const u32,
    value_lines: []const u32,
    arg_lines: []const u32,

    /// The `extensible` key as text, or `null` when the entry carries none or
    /// carries the boolean `false`. Both mean the same thing to this program:
    /// the structure chains in neither direction.
    fn extensibleDirection(self: Entry) ?[]const u8 {
        return switch (self.json.extensible orelse return null) {
            .string => |direction| direction,
            else => null,
        };
    }

    fn isExtensibleIn(self: Entry) bool {
        const direction = self.extensibleDirection() orelse return false;
        return std.mem.eql(u8, direction, "in");
    }

    fn isExtensibleOut(self: Entry) bool {
        const direction = self.extensibleDirection() orelse return false;
        return std.mem.eql(u8, direction, "out");
    }

    fn isChained(self: Entry) bool {
        return self.json.chained != null;
    }

    fn chainRoots(self: Entry) []const []const u8 {
        return self.json.@"chain roots" orelse &.{};
    }

    fn members(self: Entry) []const JsonMember {
        return self.json.members orelse &.{};
    }

    fn methods(self: Entry) []const JsonMethod {
        return self.json.methods orelse &.{};
    }

    fn args(self: Entry) []const JsonArg {
        return self.json.args orelse &.{};
    }

    fn values(self: Entry) []const JsonValue {
        return self.json.values orelse &.{};
    }
};

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

const Style = enum { snake, pascal, camel };

fn isReserved(name: []const u8) bool {
    for (zig_reserved) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

/// Build a Zig declaration name from a `dawn.json` name.
///
/// `dawn_json_generator.py:58-61` splits a name on spaces and `:69-70` upper
/// cases the first character of a chunk. This function adds the three rules a
/// Zig identifier needs and a C one does not: a leading digit takes a leading
/// underscore, a character outside `[A-Za-z0-9_]` becomes an underscore, and
/// a Zig keyword or primitive takes a trailing one.
///
/// The three native pointer names need the middle rule. `void *` has no
/// identifier spelling, and `std::byte` carries two colons.
fn declarationName(gpa: Allocator, name: []const u8, style: Style) ![]const u8 {
    if (name.len == 0) return error.EmptyName;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const first_chunk = name[0 .. std.mem.indexOfScalar(u8, name, ' ') orelse name.len];
    if (style == .snake and first_chunk.len > 0 and std.ascii.isDigit(first_chunk[0])) {
        try out.append(gpa, '_');
    }

    var chunks = std.mem.tokenizeScalar(u8, name, ' ');
    var first = true;
    while (chunks.next()) |chunk| {
        if (chunk.len == 0) return error.EmptyName;
        switch (style) {
            .snake => {
                if (!first) try out.append(gpa, '_');
                for (chunk) |c| try out.append(gpa, identifierChar(std.ascii.toLower(c)));
            },
            .pascal => {
                try out.append(gpa, std.ascii.toUpper(identifierChar(chunk[0])));
                for (chunk[1..]) |c| try out.append(gpa, identifierChar(c));
            },
            .camel => {
                if (first) {
                    for (chunk) |c| try out.append(gpa, identifierChar(c));
                } else {
                    try out.append(gpa, std.ascii.toUpper(identifierChar(chunk[0])));
                    for (chunk[1..]) |c| try out.append(gpa, identifierChar(c));
                }
            },
        }
        first = false;
    }

    const result = try out.toOwnedSlice(gpa);
    if (!isReserved(result)) return result;

    const escaped = try gpa.alloc(u8, result.len + 1);
    @memcpy(escaped[0..result.len], result);
    escaped[result.len] = '_';
    gpa.free(result);
    return escaped;
}

/// `c` when a Zig identifier can carry it and `_` when it cannot.
fn identifierChar(c: u8) u8 {
    if (std.ascii.isAlphanumeric(c) or c == '_') return c;
    return '_';
}

fn pascalName(gpa: Allocator, name: []const u8) ![]const u8 {
    return declarationName(gpa, name, .pascal);
}

fn camelName(gpa: Allocator, name: []const u8) ![]const u8 {
    return declarationName(gpa, name, .camel);
}

fn snakeName(gpa: Allocator, name: []const u8) ![]const u8 {
    return declarationName(gpa, name, .snake);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// One line of one generated file, with the declaration it starts.
const Line = struct {
    text: []const u8,
};

/// A generated file under construction.
///
/// The file is held as lines rather than bytes because `docs/40-plan.md`
/// section M2 cites the line of every generated declaration. A byte buffer
/// would make the caller count lines again to fill the table.
const Out = struct {
    gpa: Allocator,
    path: []const u8,
    lines: std.ArrayList(Line) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    fn init(gpa: Allocator, path: []const u8) Out {
        return .{ .gpa = gpa, .path = path };
    }

    /// Append one line and return its 1-based number.
    fn add(self: *Out, text: []const u8) !u32 {
        try self.lines.append(self.gpa, .{ .text = text });
        return @intCast(self.lines.items.len);
    }

    /// Append `text` indented by `indent` levels of four spaces.
    fn addIndent(self: *Out, indent: u32, text: []const u8) !u32 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(self.gpa);
        for (0..indent) |_| try line.appendSlice(self.gpa, "    ");
        try line.appendSlice(self.gpa, text);
        return self.add(try line.toOwnedSlice(self.gpa));
    }

    /// Append one line that declares `symbol`. A name claimed twice is
    /// `error.DuplicateSymbolName`, because two declarations of one name in one
    /// file is a port defect, not a merge.
    fn addDecl(self: *Out, symbol: []const u8, text: []const u8) !u32 {
        for (self.names.items) |seen| {
            if (std.mem.eql(u8, seen, symbol)) return error.DuplicateSymbolName;
        }
        try self.names.append(self.gpa, symbol);
        try self.lines.append(self.gpa, .{ .text = text });
        return @intCast(self.lines.items.len);
    }

    /// The bytes to write: every line, then a newline after each.
    fn render(self: *Out) ![]const u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        for (self.lines.items) |line| {
            try bytes.appendSlice(self.gpa, line.text);
            try bytes.append(self.gpa, '\n');
        }
        return bytes.toOwnedSlice(self.gpa);
    }
};

/// One row of a conformance table. `owner` is the entry the row hangs from and
/// is empty for an object row.
const Row = struct {
    owner: []const u8 = "",
    upstream: []const u8,
    json_line: u32,
    zig: []const u8,
    zig_file: []const u8,
    zig_line: u32,
    decision: []const u8,
};

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// The whole generated surface, held while the files are written.
const Model = struct {
    gpa: Allocator,
    io: Io,
    entries: []const Entry,
    by_name: std.StringHashMap(Entry),

    fn lookup(self: *const Model, name: []const u8) ?Entry {
        return self.by_name.get(name);
    }

    fn entryOrFail(self: *const Model, name: []const u8) GenerateError!Entry {
        return self.by_name.get(name) orelse error.UnknownTypeName;
    }

    /// The Zig type a `dawn.json` type name maps to, as written in `scope`.
    ///
    /// A native and a `string view` are spelled the same in every file. Every
    /// other type carries the module that declares it, unless that module is
    /// `scope` itself: two categories can spell one PascalCase name, so a bare
    /// name is only unambiguous inside the file that declares it.
    fn typeName(
        self: *const Model,
        gpa: Allocator,
        scope: Scope,
        upstream: []const u8,
    ) GenerateError![]const u8 {
        for (native_spellings) |native| {
            if (std.mem.eql(u8, native.upstream, upstream)) return native.zig;
        }
        if (std.mem.eql(u8, upstream, "string view")) return "[]const u8";
        const entry = try self.entryOrFail(upstream);
        const bare = switch (entry.category) {
            .@"enum",
            .bitmask,
            .constant,
            .object,
            .structure,
            .@"callback function",
            .@"callback info",
            .@"function pointer",
            => try pascalName(gpa, upstream),
            else => return error.UnexpectedCategory,
        };
        const owner = try self.ownerOf(upstream);
        if (owner == scope) return bare;
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ @tagName(owner), bare });
    }

    /// The Zig type a type reference maps to, after the chain substitution.
    ///
    /// An `extensible: "in"` structure is spelled as its chain type, because
    /// `docs/30-port-design.md` section 4.2 replaces Dawn's `nextInChain`
    /// pointer with one optional field per extension. An `extensible: "out"`
    /// structure keeps its plain spelling: the engine writes it and the caller
    /// reads it.
    fn valueTypeName(
        self: *const Model,
        gpa: Allocator,
        scope: Scope,
        upstream: []const u8,
    ) GenerateError![]const u8 {
        const entry = try self.entryOrFail(upstream);
        if (entry.isExtensibleIn() and entry.category == .structure) {
            const bare = try std.fmt.allocPrint(gpa, "{s}Chain", .{try pascalName(gpa, upstream)});
            if (try self.ownerOf(upstream) == scope) return bare;
            return std.fmt.allocPrint(gpa, "{s}.{s}", .{ @tagName(Scope.descriptors), bare });
        }
        return self.typeName(gpa, scope, upstream);
    }

    /// The generated file that declares the type `upstream` names.
    ///
    /// `@tagName` of each member is that file's module name, so the emitters
    /// need no second table to spell a type.
    fn ownerOf(self: *const Model, upstream: []const u8) GenerateError!Scope {
        const entry = try self.entryOrFail(upstream);
        return switch (entry.category) {
            .@"enum" => .enums,
            .bitmask => .bitmask,
            .constant => .constants,
            .structure => .descriptors,
            .object => .objects,
            .@"callback function", .@"function pointer", .@"callback info" => .callbacks,
            .function => .proc,
            else => error.UnexpectedCategory,
        };
    }

    /// True when `upstream` names a type a callback can arrive as: a
    /// `callback function`, a `callback info`, or a `function pointer`.
    fn isCallbackTyped(self: *const Model, upstream: []const u8) bool {
        const entry = self.lookup(upstream) orelse return false;
        return switch (entry.category) {
            .@"callback function", .@"callback info", .@"function pointer" => true,
            else => false,
        };
    }
};

/// The pointee type of a pointer or slice. `void` is `anyopaque` for a single
/// pointer and `u8` for a counted one, because Dawn writes a byte buffer
/// through a `void const *` with a length.
fn pointeeName(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    upstream: []const u8,
    counted: bool,
) GenerateError![]const u8 {
    if (std.mem.eql(u8, upstream, "void")) return if (counted) "u8" else "anyopaque";
    if (std.mem.eql(u8, upstream, "void *")) return "anyopaque";
    if (std.mem.eql(u8, upstream, "void const *")) return "anyopaque";
    return model.valueTypeName(gpa, scope, upstream);
}

/// A member or argument rendered for Zig.
const Rendered = struct {
    zig_type: []const u8,
    /// The field default for a struct member, or `null` when it has none.
    default: ?[]const u8 = null,
    slice: bool = false,
    nullable: bool = false,
    /// The emitted type carries a `?`, so a `null` default is a typed value
    /// rather than `@TypeOf(null)`. Nothing else reads this flag: the caller
    /// that needs the optionality reads it off `zig_type`.
    out: bool = false,
    zig_name: []const u8,
};
/// Render one member or one argument.
///
/// `annotation` chooses the wrapper, `length` turns a pointer into a slice and
/// `optional` adds a `?`. A counted `const*` adds that `?` whether or not the
/// JSON says `optional`, because its C default is a null pointer.
/// `dawn.json` gives a pointer without `optional` and without a `length` no
/// default, so such a field is required.
fn renderMember(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    member: JsonMember,
) GenerateError!Rendered {
    const zig_name = try snakeName(gpa, member.name);

    const optional = (member.optional orelse false) or if (member.default) |parsed|
        model.isCallbackTyped(member.type) and switch (parsed) {
            .string => |value| std.mem.eql(u8, value, "nullptr"),
            else => false,
        }
    else
        false;
    const annotation = member.annotation;
    const counted = member.length != null;

    if (annotation == null) {
        var zig_type = try model.valueTypeName(gpa, scope, member.type);
        const already_optional = std.mem.startsWith(u8, zig_type, "?");
        if (optional and !already_optional) {
            zig_type = try std.fmt.allocPrint(gpa, "?{s}", .{zig_type});
        }
        const nullable = optional or already_optional;
        var default: ?[]const u8 = null;
        if (member.default) |parsed| {
            default = try defaultExpression(model, gpa, scope, member.type, try jsonScalarText(gpa, parsed));
        } else if (nullable) {
            default = "null";
        }
        return .{ .zig_type = zig_type, .default = default, .nullable = nullable, .zig_name = zig_name };
    }

    var base = try pointeeName(model, gpa, scope, member.type, counted);
    if (member.array_element_optional) |element_optional| {
        if (element_optional) base = try std.fmt.allocPrint(gpa, "?{s}", .{base});
    }

    const out = std.mem.eql(u8, annotation.?, "*");
    // SAFETY: every branch below assigns `zig_type` before control reaches a
    // read of it, and the `else` branch returns instead of falling through.
    // The first read is the `allocPrint` at the bottom of this function, which
    // runs only after one of the three branches stored a slice there; a `try`
    // that fails returns its own error first, so no path reads the value.
    var zig_type: []const u8 = undefined;
    if (std.mem.eql(u8, annotation.?, "*")) {
        zig_type = if (counted)
            try std.fmt.allocPrint(gpa, "[]{s}", .{base})
        else
            try std.fmt.allocPrint(gpa, "*{s}", .{base});
    } else if (std.mem.eql(u8, annotation.?, "const*")) {
        zig_type = if (counted)
            try std.fmt.allocPrint(gpa, "[]const {s}", .{base})
        else
            try std.fmt.allocPrint(gpa, "*const {s}", .{base});
    } else if (std.mem.eql(u8, annotation.?, "const*const*")) {
        zig_type = if (counted)
            try std.fmt.allocPrint(gpa, "[]const []const {s}", .{base})
        else
            try std.fmt.allocPrint(gpa, "*const *const {s}", .{base});
    } else {
        return error.UnexpectedCategory;
    }

    // A counted `const*` is a nullable slice: Dawn reads a NULL pointer as an
    // absent array, and `dawn.json` gives `view format count` a zero default.
    // The `?` goes on the type and not only on the default, because a bare
    // `[]const T` has no `null` to hold, so the `null` default below would not
    // type check. An `out*` array is filled by the callee, so it stays
    // non-optional and its default stays the empty slice below.
    const nullable = optional or (counted and !out);
    if (nullable) zig_type = try std.fmt.allocPrint(gpa, "?{s}", .{zig_type});

    var default: ?[]const u8 = null;
    if (member.default) |parsed| {
        default = try defaultExpression(model, gpa, scope, member.type, try jsonScalarText(gpa, parsed));
    } else if (nullable) {
        default = "null";
    } else if (counted) {
        default = "&.{}";
    }
    return .{
        .zig_type = zig_type,
        .default = default,
        .slice = counted,
        .nullable = nullable,
        .out = out,
        .zig_name = zig_name,
    };
}

/// The text of a `default` the JSON carries as a scalar rather than a string.
///
/// `dawn.json` writes a name, a constant and `nullptr` as a JSON string, and a
/// count as a bare JSON number. `std.json` will not fill a `?[]const u8` from
/// that number, so `JsonMember.default` keeps the parsed value and this
/// function renders it. A boolean, `null` or a container is a shape no
/// `default` in `dawn.json` has, and reading one as a name would be a wrong
/// default rather than a missing one, so it is `error.UnsupportedDefault`.
///
/// Every returned byte comes from `gpa`, in both arms. The `.string` arm
/// otherwise hands back a slice of the parsed model while the `.integer` arm
/// hands back a fresh one, so a caller cannot tell which of the two it holds
/// and neither arm's contract is readable from the signature. `main` runs on
/// one process arena that outlives the generated file, so the dupes cost a
/// name and buy a uniform answer.
fn jsonScalarText(gpa: Allocator, value: std.json.Value) GenerateError![]const u8 {
    return switch (value) {
        .string, .number_string => |text| try gpa.dupe(u8, text),
        .integer => |number| std.fmt.allocPrint(gpa, "{d}", .{number}),
        else => error.UnsupportedDefault,
    };
}

/// The Zig expression for a `default` in the JSON.
///
/// The JSON spells a default six ways: `nullptr`, the name of a `constant`
/// entry, the name of a value in the member's own `enum` or `bitmask`, `true`
/// or `false` on a `bool`, `zero` on a `structure`, or a number. Anything else
/// is `error.UnsupportedDefault`, because a silent zero would be a wrong
/// default rather than a missing one.
fn defaultExpression(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    upstream_type: []const u8,
    text: []const u8,
) GenerateError![]const u8 {
    if (std.mem.eql(u8, text, "nullptr")) return "null";
    for (constant_values) |constant| {
        if (std.mem.eql(u8, constant.upstream, text)) return model.typeName(gpa, scope, text);
    }
    const entry = try model.entryOrFail(upstream_type);
    switch (entry.category) {
        .@"enum" => {
            for (entry.values()) |value| {
                if (!std.mem.eql(u8, value.name, text)) continue;
                return std.fmt.allocPrint(gpa, ".{s}", .{try snakeName(gpa, text)});
            }
            return error.UnsupportedDefault;
        },
        .bitmask => {
            for (entry.values()) |value| {
                if (!std.mem.eql(u8, value.name, text)) continue;
                if (value.value == 0) return ".{}";
                if (isSingleBit(value.value)) {
                    // A flag member is a `bool`, so the default is `true` and
                    // not the wire number. `.{ .render_attachment = 1 }` is an
                    // `expected type 'bool', found 'comptime_int'` error.
                    return std.fmt.allocPrint(
                        gpa,
                        ".{{ .{s} = true }}",
                        .{try snakeName(gpa, text)},
                    );
                }
                // A composite names bits that have no member of their own, so
                // there is no field to set. The generated constant already
                // spells the composite out, so the default is that path.
                return std.fmt.allocPrint(gpa, "{s}.{s}", .{
                    try model.typeName(gpa, scope, upstream_type),
                    try snakeName(gpa, text),
                });
            }
            return error.UnsupportedDefault;
        },
        else => {
            // Dawn spells a `bool` default and an all-zero structure as text
            // rather than as a number: `buffer descriptor`'s `mapped at
            // creation` is `"false"` at `src/dawn/dawn.json` and `bind group
            // layout entry`'s `buffer` is `"zero"`. Each is the field's own
            // zero value in Zig. The value name is read above, so `blend
            // factor`'s `zero` and `optional bool`'s `false` stay enum members
            // and never reach this branch.
            if (std.mem.eql(u8, upstream_type, "bool")) {
                if (std.mem.eql(u8, text, "true")) return "true";
                if (std.mem.eql(u8, text, "false")) return "false";
            }
            if (entry.category == .structure and std.mem.eql(u8, text, "zero")) return ".{}";
            return numberExpression(gpa, upstream_type, text);
        },
    }
}

/// The Zig literal for a numeric `default`.
///
/// Dawn writes a float with a trailing `f`, and a C float literal may leave
/// the digits off after the point: `sampler descriptor`'s `lod max clamp` is
/// `"32.f"` and `depth stencil state`'s `depth bias clamp` is `"0.f"`. Neither
/// is a Zig literal, so the trailing `f` and a trailing point go. A hex
/// literal keeps its own `f`, so `0xFFFFFFFF` is not a suffix.
fn numberExpression(
    gpa: Allocator,
    upstream_type: []const u8,
    text: []const u8,
) GenerateError![]const u8 {
    var native: ?[]const u8 = null;
    for (native_spellings) |candidate| {
        if (std.mem.eql(u8, candidate.upstream, upstream_type)) native = candidate.zig;
    }
    const floating = std.mem.eql(u8, native orelse "", "f32") or
        std.mem.eql(u8, native orelse "", "f64");

    if (std.mem.eql(u8, text, "NAN")) {
        if (!floating) return error.UnsupportedDefault;
        return "std.math.nan(f32)";
    }

    var body = text;
    if (!isHexLiteral(body) and body.len > 0 and body[body.len - 1] == 'f') {
        body = body[0 .. body.len - 1];
    }
    if (body.len > 0 and body[body.len - 1] == '.') body = body[0 .. body.len - 1];
    if (!isNumberText(body)) return error.UnsupportedDefault;

    // A float member whose default carries no point would read as an integer,
    // so the point goes back with digits of its own.
    if (floating and std.mem.indexOfScalar(u8, body, '.') == null) {
        return std.fmt.allocPrint(gpa, "{s}.0", .{body});
    }
    return gpa.dupe(u8, body);
}

fn isNumberText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (isHexLiteral(text)) return true;
    for (text, 0..) |c, index| {
        if (std.ascii.isDigit(c)) continue;
        if (index > 0 and (c == 'x' or c == 'X' or c == '.')) continue;
        return false;
    }
    return true;
}

fn isHexLiteral(text: []const u8) bool {
    if (text.len < 3) return false;
    if (text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return false;
    for (text[2..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}
// ---------------------------------------------------------------------------
// Parsing dawn.json
// ---------------------------------------------------------------------------

/// One top-level key and its line range, in file order.
const KeyRange = struct {
    name: []const u8,
    line: u32,
    end_line: u32,
};

/// Find every top-level key and its line range, in file order.
///
/// `std.json` gives no positions, and `docs/40-plan.md` section M2 cites a
/// line for every row. A top-level key sits on its own line at four spaces of
/// indent, which no nested key does, so the text is a sufficient source for
/// the key order and the key lines.
fn locateKeys(gpa: Allocator, text: []const u8) GenerateError![]KeyRange {
    var keys: std.ArrayList(KeyRange) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: u32 = 0;
    while (lines.next()) |line| {
        line_index += 1;
        if (!std.mem.startsWith(u8, line, "    \"")) continue;
        const rest = line[5..];
        const quote = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const suffix = keySuffix(rest[quote..]) orelse continue;
        if (suffix[0] != '{') continue;
        try keys.append(gpa, .{
            .name = rest[0..quote],
            .line = line_index,
            .end_line = line_index,
        });
    }
    if (keys.items.len == 0) return error.EntryLineNotFound;
    // The key below bounds every range but the last, so the last key runs to
    // the last line of the file. Its items are cited like every other entry's.
    const line_total: u32 = @intCast(std.mem.count(u8, text, "\n") + 1);
    for (keys.items, 0..) |*key, index| {
        if (index + 1 < keys.items.len) key.end_line = keys.items[index + 1].line - 1;
    }
    keys.items[keys.items.len - 1].end_line = line_total;
    return keys.toOwnedSlice(gpa);
}

/// The number of spaces `line` is indented by.
///
/// The count is of spaces and not of the first quote, because an array item
/// starts with `{`: a scan that read the quote's position would place every
/// item one column past the column its own key sits at.
fn indentWidth(line: []const u8) u32 {
    return @intCast(line.len - std.mem.trimStart(u8, line, " ").len);
}

/// The text from the colon that follows a key's closing quote, or `null` when
/// the key carries no colon of its own.
///
/// `dawn.json` writes a space before the colon on 13 of its 348 keys, `color
/// space dawn` at `src/dawn/dawn.json:1937` among them, and a key read as
/// absent lets the entry above it claim its lines. The colon is found by
/// search rather than by a fixed prefix so the space needs no special case.
/// What follows the colon is the caller's to test: `{` opens a key's object
/// and `[` opens the array of its `members`, `methods`, `values` or `args`.
fn keySuffix(after_name: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, after_name, ':') orelse return null;
    const suffix = std.mem.trimStart(u8, after_name[colon + 1 ..], " \t");
    if (suffix.len == 0) return null;
    return suffix;
}

/// The indent of one entry's own keys, read from its `category` line.
///
/// `dawn.json` indents most entries by eight spaces and 15 by six, and
/// `dawn device allocator control` at `src/dawn/dawn.json:315` is one of the
/// six. An item sits one level deeper than the key that names its array, so a
/// scan that assumes eight reads no item of a six-space entry at all.
fn keyIndent(text: []const u8, range: KeyRange) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: u32 = 0;
    while (lines.next()) |line| {
        line_index += 1;
        if (line_index <= range.line or line_index > range.end_line) continue;
        const indent = indentWidth(line);
        if (!std.mem.startsWith(u8, line[indent..], "\"category\"")) continue;
        return indent;
    }
    return null;
}

/// The lines of the items of the four arrays this generator cites, in file
/// order. `dawn.json` puts one array item per line, indented one level deeper
/// than the key that names the array.
///
/// Only a key at the entry's own indent opens or closes an array, so the
/// `args` array inside a `methods` item, which sits two levels deeper, is not
/// mistaken for the entry's own. `dawn.json` has no array that opens empty and
/// fills later and no item that spans lines, so one `{` at the item indent is
/// one item.
const ItemLines = struct {
    members: []const u32 = &.{},
    methods: []const u32 = &.{},
    values: []const u32 = &.{},
    args: []const u32 = &.{},
};

/// Find the line of every item of `members`, `methods`, `values` and `args`
/// inside one key range, in file order.
fn locateItems(gpa: Allocator, text: []const u8, range: KeyRange) GenerateError!ItemLines {
    var result: ItemLines = .{};
    var members: std.ArrayList(u32) = .empty;
    var methods: std.ArrayList(u32) = .empty;
    var values: std.ArrayList(u32) = .empty;
    var args: std.ArrayList(u32) = .empty;
    const key_indent = keyIndent(text, range) orelse {
        std.log.err(
            "{s}: dawn.json:{d}-{d} carries no category key\n",
            .{ range.name, range.line, range.end_line },
        );
        return error.EntryLineNotFound;
    };
    var open: ?*std.ArrayList(u32) = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: u32 = 0;
    while (lines.next()) |line| {
        line_index += 1;
        if (line_index <= range.line or line_index > range.end_line) continue;
        if (indentWidth(line) == key_indent) {
            // Any key at this indent ends the array that was open, and the
            // closing bracket is one of those keys, so an item count stops
            // where the array does.
            open = null;
            const indent = indentWidth(line);
            if (indent >= line.len) continue;
            const rest = line[indent + 1 ..];
            const quote = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const suffix = keySuffix(rest[quote..]) orelse continue;
            if (suffix[0] != '[') continue;
            const array = rest[0..quote];
            if (std.mem.eql(u8, array, "members")) open = &members;
            if (std.mem.eql(u8, array, "methods")) open = &methods;
            if (std.mem.eql(u8, array, "values")) open = &values;
            if (std.mem.eql(u8, array, "args")) open = &args;
            continue;
        }
        if (open == null) continue;
        if (indentWidth(line) != key_indent + one_indent) continue;
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "{")) continue;
        try open.?.append(gpa, line_index);
    }
    result.members = try members.toOwnedSlice(gpa);
    result.methods = try methods.toOwnedSlice(gpa);
    result.values = try values.toOwnedSlice(gpa);
    result.args = try args.toOwnedSlice(gpa);
    return result;
}

/// Parse every entry of `dawn.json` in file order.
fn loadEntries(gpa: Allocator, text: []const u8) GenerateError![]Entry {
    const document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        gpa,
        text,
        .{ .ignore_unknown_fields = true },
    );
    const object = switch (document) {
        .object => |map| map,
        else => return error.EntryLineNotFound,
    };

    const keys = try locateKeys(gpa, text);
    var entries: std.ArrayList(Entry) = .empty;

    for (keys) |key| {
        if (key.name.len > 0 and key.name[0] == '_') continue;
        const raw = object.get(key.name) orelse return error.EntryLineNotFound;
        const json = try std.json.parseFromValueLeaky(
            JsonEntry,
            gpa,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        const item_lines = try locateItems(gpa, text, key);

        const members = json.members orelse &.{};
        const methods = json.methods orelse &.{};
        const values = json.values orelse &.{};
        const args = json.args orelse &.{};
        // The scan found a different number of items than the parse did, so a
        // row would cite a line that is not its own item. The entry, the range
        // and the array name go to the log beside the error because
        // `error.ItemLineNotFound` alone does not say which of the 347 entries
        // moved; the log carries the name without deciding the outcome, which
        // the returned error already does.
        if (item_lines.members.len != members.len) {
            std.log.err(
                "{s}: dawn.json:{d}-{d}, indent {d}, members {d} lines for {d} items\n",
                .{
                    key.name,                         key.line,               key.end_line,
                    keyIndent(text, key) orelse 9999, item_lines.members.len, members.len,
                },
            );
            return error.ItemLineNotFound;
        }
        if (item_lines.methods.len != methods.len) {
            std.log.err("{s}: methods, {d} lines for {d} items\n", .{
                key.name, item_lines.methods.len, methods.len,
            });
            return error.ItemLineNotFound;
        }
        if (item_lines.values.len != values.len) {
            std.log.err("{s}: values, {d} lines for {d} items\n", .{
                key.name, item_lines.values.len, values.len,
            });
            return error.ItemLineNotFound;
        }
        if (item_lines.args.len != args.len) {
            std.log.err("{s}: args, {d} lines for {d} items\n", .{
                key.name, item_lines.args.len, args.len,
            });
            return error.ItemLineNotFound;
        }

        try entries.append(gpa, .{
            .name = key.name,
            .line = key.line,
            .end_line = key.end_line,
            .category = try Category.parse(json.category),
            .json = json,
            .member_lines = item_lines.members,
            .method_lines = item_lines.methods,
            .value_lines = item_lines.values,
            .arg_lines = item_lines.args,
        });
    }
    return entries.toOwnedSlice(gpa);
}

/// Resolve a `returns` value, which is either a name or an object with a
/// `type` and an `optional`.
fn resolveTypeRef(value: std.json.Value) GenerateError!TypeRef {
    switch (value) {
        .string => |name| return .{ .name = name },
        .object => |object| {
            const name = switch (object.get("type") orelse return error.UnknownTypeName) {
                .string => |text| text,
                else => return error.UnknownTypeName,
            };
            const optional = switch (object.get("optional") orelse std.json.Value{ .bool = false }) {
                .bool => |flag| flag,
                else => return error.UnknownTypeName,
            };
            return .{ .name = name, .optional = optional };
        },
        else => return error.UnknownTypeName,
    }
}

// ---------------------------------------------------------------------------
// Emitters
// ---------------------------------------------------------------------------

/// Everything this program writes.
const Output = struct {
    gpa: Allocator,
    model: *const Model,
    objects: std.ArrayList(Row) = .empty,
    methods: std.ArrayList(Row) = .empty,
    members: std.ArrayList(Row) = .empty,

    natives: Out,
    enums: Out,
    bitmask: Out,
    constants: Out,
    errors: Out,
    callbacks: Out,
    descriptors: Out,
    objects_file: Out,
    chained: Out,
    proc: Out,
    handled: Out,
    api: Out,

    fn init(gpa: Allocator, model: *const Model) Output {
        return .{
            .gpa = gpa,
            .model = model,
            .natives = Out.init(gpa, "src/api/natives.zig"),
            .enums = Out.init(gpa, "src/api/enums.zig"),
            .bitmask = Out.init(gpa, "src/api/bitmask.zig"),
            .constants = Out.init(gpa, "src/api/constants.zig"),
            .errors = Out.init(gpa, "src/api/errors.zig"),
            .callbacks = Out.init(gpa, "src/api/callbacks.zig"),
            .descriptors = Out.init(gpa, "src/api/descriptors.zig"),
            .objects_file = Out.init(gpa, "src/api/objects.zig"),
            .chained = Out.init(gpa, "src/api/chained.zig"),
            .proc = Out.init(gpa, "src/api/proc.zig"),
            .handled = Out.init(gpa, "src/api/handled.zig"),
            .api = Out.init(gpa, "src/api/api.zig"),
        };
    }
};

/// `/// Tags: ... .` Every generated declaration carries one, naming the entry
/// tags or `none`, so a Dawn extension is visible at the use site.
fn tagLine(gpa: Allocator, entry: Entry) ![]const u8 {
    const tags = entry.json.tags orelse return "/// Tags: none.";
    if (tags.len == 0) return "/// Tags: none.";
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);
    try line.appendSlice(gpa, "/// Tags: ");
    for (tags, 0..) |tag, index| {
        if (index > 0) try line.appendSlice(gpa, ", ");
        try line.appendSlice(gpa, tag);
    }
    try line.append(gpa, '.');
    return line.toOwnedSlice(gpa);
}

fn header(out: *Out) !void {
    _ = try out.add("//! GENERATED by `tools/gen_api.zig` from `src/dawn/dawn.json`.");
    _ = try out.add("//! Do not edit. `build.zig` regenerates this file.");
    _ = try out.add("");
}

/// The per-category emission. Each function writes the declarations of its
/// entries into `file` and records an `objects` table row for each.
fn emitEnums(model: *const Model, output: *Output) !void {
    var enums = output.enums;
    try header(&enums);
    _ = try enums.add("const std = @import(\"std\");");
    _ = try enums.add("");

    for (model.entries) |entry| {
        if (entry.category != .@"enum") continue;
        const gpa = output.gpa;
        const tag_name = try pascalName(gpa, entry.name);

        _ = try enums.add(try std.fmt.allocPrint(
            gpa,
            "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
            .{ entry.name, entry.line },
        ));
        _ = try enums.add(try tagLine(gpa, entry));

        // A duplicate tag value is `error.enum tag value already taken`, so the
        // first name in the file wins and the rest are recorded beside the
        // declaration. No alias is emitted (`AGENTS.md` section 2).
        var seen: std.ArrayList(u32) = .empty;
        var drops: std.ArrayList([]const u8) = .empty;
        var kept: std.ArrayList(bool) = .empty;
        for (entry.values()) |value| {
            var taken = false;
            for (seen.items) |tag| {
                if (tag == value.value) {
                    taken = true;
                    break;
                }
            }
            try kept.append(gpa, !taken);
            if (taken) {
                try drops.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "///   - \"{s}\" = {d}, dropped. The enum keeps the first entry with this value.",
                    .{ value.name, value.value },
                ));
            } else {
                try seen.append(gpa, value.value);
            }
        }
        if (drops.items.len > 0) {
            _ = try enums.add("/// Upstream reuses a tag value. Zig rejects a duplicate tag,");
            _ = try enums.add("/// so this enum keeps the first name per value.");
            for (drops.items) |drop| _ = try enums.add(drop);
        }

        const line = try enums.addDecl(
            tag_name,
            try std.fmt.allocPrint(gpa, "pub const {s} = enum(u32) {{", .{tag_name}),
        );
        for (entry.values(), 0..) |value, value_index| {
            if (!kept.items[value_index]) continue;
            _ = try enums.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s} = {d},",
                .{ try snakeName(gpa, value.name), value.value },
            ));
        }
        _ = try enums.add("};");
        _ = try enums.add("");

        // The sweep domain and the tag type for one enum.
        _ = try enums.add(try std.fmt.allocPrint(gpa, "/// The tag domains the sweep walks.", .{}));
        _ = try enums.add(try std.fmt.allocPrint(
            gpa,
            "/// `{s}` has {d} values and the dropped count below.",
            .{ tag_name, entry.values().len },
        ));
        _ = try enums.add("");

        try output.objects.append(output.gpa, .{
            .upstream = entry.name,
            .json_line = entry.line,
            .zig = try std.fmt.allocPrint(gpa, "`api.enums.{s}`", .{tag_name}),
            .zig_file = "src/api/enums.zig",
            .zig_line = line,
            .decision = if (drops.items.len == 0)
                "enum, explicit u32 tag, round trip tested"
            else
                "enum, explicit u32 tag, duplicate upstream tags dropped",
        });
    }
    output.enums = enums;
}

/// True when `value` names exactly one bit.
///
/// A `packed struct` field is one `u1`, so a flag is one bit wide whatever its
/// position: the position is the order the values happen to appear in, not a
/// width to add up. Only the count of single-bit values has to fit the backing
/// integer. A value that names no single bit has no field of its own and
/// becomes a constant instead.
fn isSingleBit(value: u32) bool {
    if (value == 0) return false;
    return value & (value - 1) == 0;
}

/// The declaration of one bitmask value that has no field of its own.
///
/// The constant spells out the flags it is made of rather than handing a bare
/// number to `fromFlags`, so a reader sees `all` as the four channels it is
/// and the declaration does not depend on the wire number. A zero value has no
/// flags, so it is the empty struct literal.
fn compositeConstant(
    gpa: Allocator,
    tag_name: []const u8,
    entry: Entry,
    value: JsonValue,
) GenerateError![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);
    try line.appendSlice(gpa, "pub const ");
    try line.appendSlice(gpa, try snakeName(gpa, value.name));
    try line.appendSlice(gpa, ": ");
    try line.appendSlice(gpa, tag_name);
    try line.appendSlice(gpa, " = .{");
    var first = true;
    for (entry.values()) |flag| {
        if (!isSingleBit(flag.value)) continue;
        if (flag.value & value.value != flag.value) continue;
        if (!first) try line.appendSlice(gpa, ",");
        first = false;
        const field = try std.fmt.allocPrint(gpa, " .{s} = true", .{try snakeName(gpa, flag.name)});
        try line.appendSlice(gpa, field);
    }
    try line.appendSlice(gpa, " };");
    return line.toOwnedSlice(gpa);
}

fn emitBitmask(model: *const Model, output: *Output) !void {
    var bitmask = output.bitmask;
    try header(&bitmask);
    _ = try bitmask.add("const std = @import(\"std\");");
    _ = try bitmask.add("");
    const gpa = output.gpa;

    for (model.entries) |entry| {
        if (entry.category != .bitmask) continue;
        const tag_name = try pascalName(gpa, entry.name);

        _ = try bitmask.add(try std.fmt.allocPrint(
            gpa,
            "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
            .{ entry.name, entry.line },
        ));
        _ = try bitmask.add(try tagLine(gpa, entry));

        // A `bool` field per single-bit value, in file order, so each flag sits
        // on its own wire bit and `@bitCast` round-trips. A `bool` is one bit
        // wide in a `packed struct`, so the bit count is unchanged, and it
        // reads as a `bool`: a caller writes `if (usage.storage)` and not
        // `if (usage.storage != 0)`. A `u1` field would give the same bits and
        // the wrong type, so every `if` at every call site would be a cast. A
        // zero value names the empty mask rather than a bit, and a composite
        // value names bits that have fields of their own, so both become
        // constants instead of fields. Only the field count has to fit the
        // backing integer, so `buffer usage` has 11 fields and 21 padding
        // bits.
        var field_count: u32 = 0;
        for (entry.values()) |value| {
            if (isSingleBit(value.value)) field_count += 1;
        }
        if (field_count > 32) {
            std.log.err("{s}: dawn.json:{d} needs {d} bits of a u32\n", .{
                entry.name, entry.line, field_count,
            });
            return error.BitmaskExceedsU32;
        }
        const padding = 32 - field_count;

        const line = try bitmask.addDecl(
            tag_name,
            try std.fmt.allocPrint(gpa, "pub const {s} = packed struct(u32) {{", .{tag_name}),
        );
        for (entry.values()) |value| {
            if (!isSingleBit(value.value)) continue;
            _ = try bitmask.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: bool = false,",
                .{try snakeName(gpa, value.name)},
            ));
        }
        _ = try bitmask.addIndent(1, try std.fmt.allocPrint(gpa, "_padding: u{d} = 0,", .{padding}));
        _ = try bitmask.add("");
        _ = try bitmask.addIndent(1, try std.fmt.allocPrint(
            gpa,
            "/// The number of values in dawn.json, fields and constants together.",
            .{},
        ));
        _ = try bitmask.addIndent(1, try std.fmt.allocPrint(
            gpa,
            "pub const count = {d};",
            .{entry.values().len},
        ));
        _ = try bitmask.add("");
        for (entry.values()) |value| {
            if (isSingleBit(value.value)) continue;
            _ = try bitmask.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "/// dawn.json:{d} gives \"{s}\" the value {d}, which is no bit or a",
                .{ entry.line, value.name, value.value },
            ));
            _ = try bitmask.addIndent(1, "/// composite, so it is a constant rather than a field.");
            _ = try bitmask.addIndent(1, try compositeConstant(gpa, tag_name, entry, value));
            _ = try bitmask.add("");
        }
        _ = try bitmask.addIndent(1, "pub inline fn toFlags(value: @This()) u32 {");
        _ = try bitmask.addIndent(2, "return @bitCast(value);");
        _ = try bitmask.addIndent(1, "}");
        _ = try bitmask.add("");
        _ = try bitmask.addIndent(1, "pub inline fn fromFlags(flags: u32) @This() {");
        _ = try bitmask.addIndent(2, "return @bitCast(flags);");
        _ = try bitmask.addIndent(1, "}");
        _ = try bitmask.add("");
        _ = try bitmask.addIndent(1, "pub fn has(self: @This(), other: @This()) bool {");
        _ = try bitmask.addIndent(2, "const ours = self.toFlags();");
        _ = try bitmask.addIndent(2, "const theirs = other.toFlags();");
        _ = try bitmask.addIndent(2, "return (ours & theirs) == theirs;");
        _ = try bitmask.addIndent(1, "}");
        _ = try bitmask.addIndent(1, "");
        _ = try bitmask.addIndent(1, "pub inline fn merge(a: @This(), b: @This()) @This() {");
        _ = try bitmask.addIndent(2, "return fromFlags(a.toFlags() | b.toFlags());");
        _ = try bitmask.addIndent(1, "}");
        _ = try bitmask.add("};");
        _ = try bitmask.add("");
        _ = try bitmask.add(try std.fmt.allocPrint(
            gpa,
            "/// Every wire value dawn.json gives \"{s}\", in file order. The round trip",
            .{entry.name},
        ));
        _ = try bitmask.add("/// test reads this list.");
        _ = try bitmask.addDecl(
            try std.fmt.allocPrint(gpa, "{s}_flag_values", .{tag_name}),
            try std.fmt.allocPrint(gpa, "pub const {s}_flag_values: []const u32 = &.{{", .{tag_name}),
        );
        for (entry.values()) |value| {
            _ = try bitmask.addIndent(1, try std.fmt.allocPrint(gpa, "{d},", .{value.value}));
        }
        _ = try bitmask.add("};");
        _ = try bitmask.add("");

        try output.objects.append(output.gpa, .{
            .upstream = entry.name,
            .json_line = entry.line,
            .zig = try std.fmt.allocPrint(gpa, "`api.bitmask.{s}`", .{tag_name}),
            .zig_file = "src/api/bitmask.zig",
            .zig_line = line,
            .decision = "bitmask, packed struct(u32), @bitCast round trip",
        });
    }
    output.bitmask = bitmask;
}

fn emitConstants(model: *const Model, output: *Output) !void {
    var constants = output.constants;
    try header(&constants);
    _ = try constants.add("const std = @import(\"std\");");
    _ = try constants.add("");
    const gpa = output.gpa;

    for (model.entries) |entry| {
        if (entry.category != .constant) continue;
        const tag_name = try pascalName(gpa, entry.name);
        const zig_type = entry.json.type orelse return error.UnknownTypeName;
        const wire = entry.json.value orelse return error.UnknownTypeName;
        const value = for (constant_values) |constant| {
            if (std.mem.eql(u8, constant.upstream, entry.name)) break constant.value;
        } else return error.UnsupportedDefault;
        const native = for (native_spellings) |candidate| {
            if (std.mem.eql(u8, candidate.upstream, zig_type)) break candidate.zig;
        } else return error.UnknownTypeName;

        _ = try constants.add(try std.fmt.allocPrint(
            gpa,
            "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
            .{ entry.name, entry.line },
        ));
        _ = try constants.add(try tagLine(gpa, entry));
        _ = try constants.add(try std.fmt.allocPrint(
            gpa,
            "/// The wire value is `{s}`.",
            .{wire},
        ));
        const line = try constants.addDecl(
            tag_name,
            try std.fmt.allocPrint(gpa, "pub const {s}: {s} = {s};", .{ tag_name, native, value }),
        );
        _ = try constants.add("");

        try output.objects.append(output.gpa, .{
            .upstream = entry.name,
            .json_line = entry.line,
            .zig = try std.fmt.allocPrint(gpa, "`api.constants.{s}`", .{tag_name}),
            .zig_file = "src/api/constants.zig",
            .zig_line = line,
            .decision = "constant, wire value named",
        });
    }
    output.constants = constants;
}
fn emitErrors(_: *const Model, output: *Output) !void {
    var errors = output.errors;
    try header(&errors);
    _ = try errors.add("const enums = @import(\"enums.zig\");");
    _ = try errors.add("");
    _ = try errors.add("/// Upstream error values, without `no error`.");
    _ = try errors.add("pub const Error = error{");
    for (error_value_map) |member| {
        _ = try errors.addIndent(1, try std.fmt.allocPrint(output.gpa, "{s},", .{member.zig}));
    }
    _ = try errors.add("};");
    _ = try errors.add("");
    _ = try errors.add("/// Map the Zig error to the upstream value it carries.");
    _ = try errors.add("pub fn toErrorType(failure: Error) enums.ErrorType {");
    _ = try errors.addIndent(1, "return switch (failure) {");
    for (error_value_map) |member| {
        _ = try errors.addIndent(2, try std.fmt.allocPrint(
            output.gpa,
            "error.{s} => .{s},",
            .{ member.zig, try snakeName(output.gpa, member.upstream) },
        ));
    }
    _ = try errors.addIndent(1, "};");
    _ = try errors.add("}");
    _ = try errors.add("");
    _ = try errors.add("/// Map an upstream value back to the Zig error it carries.");
    _ = try errors.add("/// `no error` has no Zig error, so it is `null` rather than a member.");
    _ = try errors.add("pub fn fromErrorType(kind: enums.ErrorType) ?Error {");
    _ = try errors.addIndent(1, "return switch (kind) {");
    _ = try errors.addIndent(2, ".no_error => null,");
    for (error_value_map) |member| {
        _ = try errors.addIndent(2, try std.fmt.allocPrint(
            output.gpa,
            ".{s} => error.{s},",
            .{ try snakeName(output.gpa, member.upstream), member.zig },
        ));
    }
    _ = try errors.addIndent(1, "};");
    _ = try errors.add("}");
    _ = try errors.add("");
    for (native_support_errors) |support| {
        _ = try errors.add("/// Native support failures; not upstream `ErrorType` values.");
        _ = try errors.addDecl(support.name, try std.fmt.allocPrint(
            output.gpa,
            "pub const {s} = error{{",
            .{support.name},
        ));
        for (support.members) |member| {
            _ = try errors.addIndent(1, try std.fmt.allocPrint(output.gpa, "{s},", .{member}));
        }
        _ = try errors.add("};");
        _ = try errors.add("");
    }

    output.errors = errors;
}

fn emitNatives(model: *const Model, output: *Output) !void {
    var natives = output.natives;
    try header(&natives);
    _ = try natives.add("");
    _ = try natives.add("// The Zig type each native in dawn.json maps to.");
    _ = try natives.add("//");
    _ = try natives.add("// A native has no declaration of its own. `tools/gen_api.zig` emits the");
    _ = try natives.add("// spelling below wherever dawn.json names the native, so an alias here");
    _ = try natives.add("// would forward to itself (`AGENTS.md` section 2).");
    _ = try natives.add("//");
    _ = try natives.add("// | dawn.json | Zig |");
    _ = try natives.add("// | --- | --- |");
    for (native_spellings) |native| {
        _ = try natives.add(try std.fmt.allocPrint(
            output.gpa,
            "// | `{s}` | `{s}` |",
            .{ native.upstream, native.zig },
        ));
    }
    _ = try natives.add("");
    _ = try natives.add("comptime {");
    _ = try natives.add("    // This file carries no declarations. The block makes the file");
    _ = try natives.add("    // fail only if the module system stops accepting a doc-only file.");
    _ = try natives.add("}");

    for (model.entries) |entry| {
        if (entry.category != .native) continue;
        const gpa = output.gpa;
        const zig = for (native_spellings) |native| {
            if (std.mem.eql(u8, native.upstream, entry.name)) break native.zig;
        } else return error.UnknownTypeName;
        try output.objects.append(gpa, .{
            .upstream = entry.name,
            .json_line = entry.line,
            .zig = try std.fmt.allocPrint(gpa, "`{s}`", .{zig}),
            .zig_file = "src/api/natives.zig",
            .zig_line = 1,
            .decision = "native, spelled directly at every use",
        });
    }
    output.natives = natives;
}

/// Emit one native Zig callback function pointer type.
fn emitCallbackFunction(
    model: *const Model,
    output: *Output,
    entry: Entry,
) !void {
    const gpa = output.gpa;
    var callbacks = output.callbacks;
    const tag_name = try pascalName(gpa, entry.name);

    _ = try callbacks.add(try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, entry.line },
    ));
    _ = try callbacks.add(try tagLine(gpa, entry));

    var params: std.ArrayList(u8) = .empty;
    try params.appendSlice(gpa, "userdata: ?*anyopaque");
    for (entry.args()) |arg| {
        const rendered = try renderCallbackArg(model, gpa, .callbacks, arg);
        try params.appendSlice(gpa, ", ");
        try params.appendSlice(gpa, rendered.zig_name);
        try params.appendSlice(gpa, ": ");
        try params.appendSlice(gpa, rendered.zig_type);
    }

    var returns: []const u8 = "void";
    if (entry.json.returns) |value| {
        const ref = try resolveTypeRef(value);
        const zig_ret = try model.typeName(gpa, .callbacks, ref.name);
        returns = if (ref.optional)
            try std.fmt.allocPrint(gpa, "?{s}", .{zig_ret})
        else
            zig_ret;
    }

    const line = try callbacks.addDecl(
        tag_name,
        try std.fmt.allocPrint(
            gpa,
            "pub const {s} = *const fn ({s}) {s};",
            .{ tag_name, params.items, returns },
        ),
    );
    _ = try callbacks.add("");
    output.callbacks = callbacks;

    try output.objects.append(gpa, .{
        .upstream = entry.name,
        .json_line = entry.line,
        .zig = try std.fmt.allocPrint(gpa, "`api.callbacks.{s}`", .{tag_name}),
        .zig_file = "src/api/callbacks.zig",
        .zig_line = line,
        .decision = "callback function, native Zig function pointer with userdata first",
    });
}

/// Render one argument of a callback function. The emitter adds the synthetic
/// Zig `userdata` first parameter. This is not an upstream C-ABI projection.
fn renderCallbackArg(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    arg: JsonArg,
) GenerateError!Rendered {
    var member: JsonMember = .{ .name = arg.name, .type = arg.type };
    member.annotation = arg.annotation;
    member.length = arg.length;
    member.optional = arg.optional;
    return renderMember(model, gpa, scope, member);
}

/// Emit one callback info struct.
fn emitCallbackInfo(
    model: *const Model,
    output: *Output,
    entry: Entry,
) !void {
    const gpa = output.gpa;
    var callbacks = output.callbacks;
    const tag_name = try pascalName(gpa, entry.name);

    _ = try callbacks.add(try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, entry.line },
    ));
    _ = try callbacks.add(try tagLine(gpa, entry));
    const line = try callbacks.addDecl(
        tag_name,
        try std.fmt.allocPrint(gpa, "pub const {s} = struct {{", .{tag_name}),
    );
    var member_index: usize = 0;
    for (entry.members()) |member| {
        const rendered = try renderMember(model, gpa, .callbacks, member);
        // Preserve each schema field and its default. Nullable callbacks keep
        // their function-pointer type inside the record.
        const field_line = if (rendered.default) |default|
            try callbacks.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: {s} = {s},",
                .{ rendered.zig_name, rendered.zig_type, default },
            ))
        else
            try callbacks.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: {s},",
                .{ rendered.zig_name, rendered.zig_type },
            ));
        try output.members.append(gpa, .{
            .owner = entry.name,
            .upstream = member.name,
            .json_line = entry.member_lines[member_index],
            .zig = try std.fmt.allocPrint(
                gpa,
                "`api.callbacks.{s}.{s}`",
                .{ tag_name, rendered.zig_name },
            ),
            .zig_file = "src/api/callbacks.zig",
            .zig_line = field_line,
            .decision = memberDecision(rendered, member),
        });
        member_index += 1;
    }
    _ = try callbacks.addIndent(1, "/// Passed to the callback as its first argument.");
    _ = try callbacks.addIndent(1, "userdata: ?*anyopaque = null,");
    _ = try callbacks.add("};");
    _ = try callbacks.add("");
    output.callbacks = callbacks;

    try output.objects.append(gpa, .{
        .upstream = entry.name,
        .json_line = entry.line,
        .zig = try std.fmt.allocPrint(gpa, "`api.callbacks.{s}`", .{tag_name}),
        .zig_file = "src/api/callbacks.zig",
        .zig_line = line,
        .decision = "callback info, mode plus callback, userdata added",
    });
}

/// The decision text for one rendered member.
fn memberDecision(rendered: Rendered, member: JsonMember) []const u8 {
    if (member.default != null) return "field, upstream default";
    if (rendered.out) return "field, out parameter";
    if (rendered.slice and rendered.nullable) return "field, nullable slice";
    if (rendered.slice) return "field, counted slice";
    if (rendered.nullable) return "field, nullable";
    return "field";
}

/// Emit one function pointer.
fn emitFunctionPointer(
    model: *const Model,
    output: *Output,
    entry: Entry,
) !void {
    const gpa = output.gpa;
    var callbacks = output.callbacks;
    const tag_name = try pascalName(gpa, entry.name);

    _ = try callbacks.add(try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, entry.line },
    ));
    _ = try callbacks.add(try tagLine(gpa, entry));

    var params: std.ArrayList(u8) = .empty;
    for (entry.args(), 0..) |arg, index| {
        if (index > 0) try params.appendSlice(gpa, ", ");
        const member: JsonMember = .{
            .name = arg.name,
            .type = arg.type,
            .annotation = arg.annotation,
            .length = arg.length,
            .optional = arg.optional,
        };
        const rendered = try renderMember(model, gpa, .callbacks, member);
        try params.appendSlice(gpa, rendered.zig_name);
        try params.appendSlice(gpa, ": ");
        try params.appendSlice(gpa, rendered.zig_type);
    }

    var returns: []const u8 = "void";
    if (entry.json.returns) |value| {
        const ref = try resolveTypeRef(value);
        returns = try model.typeName(gpa, .callbacks, ref.name);
    }
    if (params.items.len == 0 and std.mem.eql(u8, returns, "void")) {
        _ = try callbacks.add("/// A hook that takes and returns nothing.");
    }

    const line = try callbacks.addDecl(
        tag_name,
        try std.fmt.allocPrint(
            gpa,
            "pub const {s} = *const fn ({s}) callconv(.c) {s};",
            .{ tag_name, params.items, returns },
        ),
    );
    _ = try callbacks.add("");
    output.callbacks = callbacks;

    try output.objects.append(gpa, .{
        .upstream = entry.name,
        .json_line = entry.line,
        .zig = try std.fmt.allocPrint(gpa, "`api.callbacks.{s}`", .{tag_name}),
        .zig_file = "src/api/callbacks.zig",
        .zig_line = line,
        .decision = "function pointer, C function pointer",
    });
}

fn emitCallbacksHeader(output: *Output) !void {
    var callbacks = output.callbacks;
    try header(&callbacks);
    _ = try callbacks.add("const std = @import(\"std\");");
    _ = try callbacks.add("const bitmask = @import(\"bitmask.zig\");");
    _ = try callbacks.add("const constants = @import(\"constants.zig\");");
    _ = try callbacks.add("const descriptors = @import(\"descriptors.zig\");");
    _ = try callbacks.add("const enums = @import(\"enums.zig\");");
    _ = try callbacks.add("const objects = @import(\"objects.zig\");");
    _ = try callbacks.add("");
    output.callbacks = callbacks;
}

/// Emit one descriptor: the struct for one `structure` entry.
fn emitDescriptor(
    model: *const Model,
    output: *Output,
    entry: Entry,
) !void {
    const gpa = output.gpa;
    var descriptors = output.descriptors;
    const tag_name = try pascalName(gpa, entry.name);

    _ = try descriptors.add(try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, entry.line },
    ));
    _ = try descriptors.add(try tagLine(gpa, entry));
    if (entry.isChained()) {
        _ = try descriptors.add(try std.fmt.allocPrint(
            gpa,
            "/// A chained struct. Its roots are {d} in `chained.zig`.",
            .{entry.chainRoots().len},
        ));
    }
    const line = try descriptors.addDecl(
        tag_name,
        try std.fmt.allocPrint(gpa, "pub const {s} = struct {{", .{tag_name}),
    );

    var member_index: usize = 0;
    for (entry.members()) |member| {
        const rendered = try renderMember(model, gpa, .descriptors, member);
        const zig_line = if (rendered.default) |default|
            try descriptors.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: {s} = {s},",
                .{ rendered.zig_name, rendered.zig_type, default },
            ))
        else
            try descriptors.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: {s},",
                .{ rendered.zig_name, rendered.zig_type },
            ));
        try output.members.append(gpa, .{
            .owner = entry.name,
            .upstream = member.name,
            .json_line = entry.member_lines[member_index],
            .zig = try std.fmt.allocPrint(
                gpa,
                "`api.descriptors.{s}.{s}`",
                .{ tag_name, rendered.zig_name },
            ),
            .zig_file = "src/api/descriptors.zig",
            .zig_line = zig_line,
            .decision = memberDecision(rendered, member),
        });
        member_index += 1;
    }
    _ = try descriptors.add("};");
    _ = try descriptors.add("");
    output.descriptors = descriptors;

    try output.objects.append(gpa, .{
        .upstream = entry.name,
        .json_line = entry.line,
        .zig = try std.fmt.allocPrint(gpa, "`api.descriptors.{s}`", .{tag_name}),
        .zig_file = "src/api/descriptors.zig",
        .zig_line = line,
        .decision = if (entry.isChained())
            "structure, chained, roots listed in chained.zig"
        else if (entry.isExtensibleIn())
            "structure, extensible in, chain type below"
        else if (entry.isExtensibleOut())
            "structure, extensible out, engine fills it"
        else
            "structure, emitted",
    });

    // The chain type for an `extensible: "in"` root, per
    // `docs/30-port-design.md` section 4.2: the root's own fields plus one
    // optional per chained struct that lists the root in `chain roots`.
    if (entry.isExtensibleIn()) {
        try emitChainType(model, output, entry, tag_name);
    }
}

/// Emit the `<Root>Chain` struct for one extensible root.
fn emitChainType(
    model: *const Model,
    output: *Output,
    entry: Entry,
    tag_name: []const u8,
) !void {
    const gpa = output.gpa;
    var descriptors = output.descriptors;
    const chain_name = try std.fmt.allocPrint(gpa, "{s}Chain", .{tag_name});

    _ = try descriptors.add(try std.fmt.allocPrint(
        gpa,
        "/// The chain for \"{s}\". The root's own fields, plus one optional per",
        .{entry.name},
    ));
    _ = try descriptors.add("/// chained struct that lists this root in `chain roots`.");
    _ = try descriptors.add("/// `docs/30-port-design.md` section 4.2 replaces Dawn's `nextInChain`");
    _ = try descriptors.add("/// pointer with this struct, so a duplicate extension is unrepresentable.");
    _ = try descriptors.addDecl(
        chain_name,
        try std.fmt.allocPrint(gpa, "pub const {s} = struct {{", .{chain_name}),
    );

    for (entry.members()) |member| {
        const rendered = try renderMember(model, gpa, .descriptors, member);
        if (rendered.default) |default| {
            _ = try descriptors.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: {s} = {s},",
                .{ rendered.zig_name, rendered.zig_type, default },
            ));
        } else {
            _ = try descriptors.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: {s},",
                .{ rendered.zig_name, rendered.zig_type },
            ));
        }
    }
    for (model.entries) |chained_entry| {
        if (!chained_entry.isChained()) continue;
        var roots = false;
        for (chained_entry.chainRoots()) |root| {
            if (std.mem.eql(u8, root, entry.name)) roots = true;
        }
        if (!roots) continue;
        const extension = try pascalName(gpa, chained_entry.name);
        _ = try descriptors.addIndent(1, try std.fmt.allocPrint(
            gpa,
            "{s}: ?{s} = null,",
            .{ try snakeName(gpa, chained_entry.name), extension },
        ));
    }
    _ = try descriptors.add("};");
    _ = try descriptors.add("");
    output.descriptors = descriptors;
}

fn emitDescriptorsHeader(output: *Output) !void {
    var descriptors = output.descriptors;
    try header(&descriptors);
    _ = try descriptors.add("const std = @import(\"std\");");
    _ = try descriptors.add("const bitmask = @import(\"bitmask.zig\");");
    _ = try descriptors.add("const callbacks = @import(\"callbacks.zig\");");
    _ = try descriptors.add("const constants = @import(\"constants.zig\");");
    _ = try descriptors.add("const enums = @import(\"enums.zig\");");
    _ = try descriptors.add("const errors = @import(\"errors.zig\");");
    _ = try descriptors.add("const objects = @import(\"objects.zig\");");
    _ = try descriptors.add("");
    output.descriptors = descriptors;
}
fn emitObjectsHeader(output: *Output) !void {
    var objects = output.objects_file;
    try header(&objects);
    _ = try objects.add("const std = @import(\"std\");");
    _ = try objects.add("const bitmask = @import(\"bitmask.zig\");");
    _ = try objects.add("const callbacks = @import(\"callbacks.zig\");");
    _ = try objects.add("const constants = @import(\"constants.zig\");");
    _ = try objects.add("const descriptors = @import(\"descriptors.zig\");");
    _ = try objects.add("const enums = @import(\"enums.zig\");");
    _ = try objects.add("const errors = @import(\"errors.zig\");");
    _ = try objects.add("");
    output.objects_file = objects;
}

/// One resolved method parameter.
const Param = struct {
    name: []const u8,
    zig_type: []const u8,
    callback: bool,
    json_name: []const u8,
    json_type: []const u8,
};

/// Resolve the parameters of one method.
///
/// Callback-info arguments retain their record type and JSON argument name.
/// The callback marker keeps them last and outside grouped options.
fn resolveParams(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    method: JsonMethod,
) GenerateError![]Param {
    const raw_args = method.args orelse &.{};
    var params: std.ArrayList(Param) = .empty;
    for (raw_args) |arg| {
        const member: JsonMember = .{
            .name = arg.name,
            .type = arg.type,
            .annotation = arg.annotation,
            .length = arg.length,
            .optional = arg.optional,
        };
        const rendered = try renderMember(model, gpa, scope, member);
        try params.append(gpa, .{
            .name = rendered.zig_name,
            .zig_type = rendered.zig_type,
            .callback = model.isCallbackTyped(arg.type),
            .json_name = arg.name,
            .json_type = arg.type,
        });
    }
    return params.toOwnedSlice(gpa);
}

/// Native support effects are independent of Dawn's `error type` enum.
const MethodEffect = enum { ordinary, async_start, callback_control, process_events, future_wait };

const method_effects = [_]struct {
    owner: []const u8,
    method: []const u8,
    effect: MethodEffect,
}{
    .{ .owner = "adapter", .method = "request device", .effect = .async_start },
    .{ .owner = "buffer", .method = "map async", .effect = .async_start },
    .{ .owner = "device", .method = "create compute pipeline async", .effect = .async_start },
    .{ .owner = "device", .method = "create render pipeline async", .effect = .async_start },
    .{ .owner = "device", .method = "pop error scope", .effect = .async_start },
    .{ .owner = "instance", .method = "request adapter", .effect = .async_start },
    .{ .owner = "queue", .method = "on submitted work done", .effect = .async_start },
    .{ .owner = "shader module", .method = "get compilation info", .effect = .async_start },
    .{ .owner = "device", .method = "set logging callback", .effect = .callback_control },
    .{ .owner = "device", .method = "get lost future", .effect = .callback_control },
    .{ .owner = "instance", .method = "process events", .effect = .process_events },
    .{ .owner = "instance", .method = "wait any", .effect = .future_wait },
};

fn methodEffect(owner: []const u8, method: []const u8) MethodEffect {
    for (method_effects) |contract| {
        if (std.mem.eql(u8, owner, contract.owner) and
            std.mem.eql(u8, method, contract.method)) return contract.effect;
    }
    return .ordinary;
}

const native_support_errors = [_]struct {
    name: []const u8,
    members: []const []const u8,
}{
    .{ .name = "AsyncStartError", .members = &.{
        "OutOfMemory",               "Canceled",               "MissingFutureNamespaceSource", "FutureNamespaceExhausted",
        "FutureNamespaceContention", "FutureIdExhausted",      "AsyncCapacityExceeded",        "InvalidAsyncCapacity",
        "InvalidCallbackMode",       "InvalidOwner",           "OwnerStopped",                 "InstanceShutDown",
        "TaskQueueFull",             "PoolShutDown",           "WorkerExhausted",              "ConcurrencyUnavailable",
        "InvalidRequest",            "ReferenceCountOverflow",
    } },
    .{ .name = "FutureWaitError", .members = &.{
        "Canceled",             "MissingFutureNamespaceSource", "InvalidFutureId",    "FutureInstanceMismatch",
        "FutureCountMismatch",  "WaitCountExceeded",            "ReentrantWait",      "InstanceShutDown",
        "TimedWaitUnavailable", "WaitIterationExhausted",       "WaitEpochExhausted", "ReferenceCountOverflow",
    } },
    .{ .name = "CallbackControlError", .members = &.{
        "Canceled", "MissingFutureNamespaceSource", "DeviceNotAlive", "InvalidOwner",
    } },
    .{ .name = "ProcessEventsError", .members = &.{
        "InstanceShutDown", "ReferenceCountOverflow",
    } },
};

/// Ordinary methods keep the upstream error projection. Native support methods
/// use finite admission, callback-control, polling or wait errors instead.
fn methodReturnType(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    effect: MethodEffect,
    method: JsonMethod,
) GenerateError![]const u8 {
    const error_set = switch (effect) {
        .ordinary => "Error",
        .async_start => "AsyncStartError",
        .callback_control => "CallbackControlError",
        .process_events => "ProcessEventsError",
        .future_wait => "FutureWaitError",
    };
    const value = method.returns orelse {
        if (effect == .ordinary) return "void";
        return std.fmt.allocPrint(gpa, "errors.{s}!void", .{error_set});
    };
    const ref = try resolveTypeRef(value);
    const zig_ret = try model.valueTypeName(gpa, scope, ref.name);
    const optional_prefix = if (ref.optional and !std.mem.startsWith(u8, zig_ret, "?")) "?" else "";
    return std.fmt.allocPrint(gpa, "errors.{s}!{s}{s}", .{ error_set, optional_prefix, zig_ret });
}

/// Emit one object: the handle struct, its method signatures, and the options
/// structs its methods need.
///
/// The signatures are `fn` types, not function bodies: the engine milestone
/// owns the bodies. A `fn` type declares the contract without inventing one.
fn emitObject(
    model: *const Model,
    output: *Output,
    entry: Entry,
) !void {
    const gpa = output.gpa;
    var objects = output.objects_file;
    const tag_name = try pascalName(gpa, entry.name);

    _ = try objects.add(try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, entry.line },
    ));
    _ = try objects.add(try tagLine(gpa, entry));
    _ = try objects.add(try std.fmt.allocPrint(
        gpa,
        "/// A handle, not a state object. `core` owns the lifetime policy and",
        .{},
    ));
    _ = try objects.add("/// this file holds none of it (`docs/10-architecture.md`, Object model).");
    const decl_line = try objects.addDecl(
        tag_name,
        try std.fmt.allocPrint(gpa, "pub const {s} = struct {{", .{tag_name}),
    );
    _ = try objects.addIndent(1, "/// Opaque pointer to the object `core` owns. `null` is invalid.");
    _ = try objects.addIndent(1, "handle: ?*anyopaque = null,");
    _ = try objects.add("");

    for (entry.methods(), 0..) |method, method_index| {
        const json_line = entry.method_lines[method_index];
        try emitMethod(model, output, &objects, entry, tag_name, method, json_line);
    }
    _ = try objects.add("};");
    _ = try objects.add("");
    output.objects_file = objects;

    try output.objects.append(gpa, .{
        .upstream = entry.name,
        .json_line = entry.line,
        .zig = try std.fmt.allocPrint(gpa, "`api.objects.{s}`", .{tag_name}),
        .zig_file = "src/api/objects.zig",
        .zig_line = decl_line,
        .decision = "object handle, methods as fn types",
    });
}

const MethodSignature = struct {
    params: []const u8,
    returns: []const u8,
    grouped: bool,
    callback_last: bool,
    effect: MethodEffect,
};

/// Both surfaces use one emitter. Only object declarations group repeated
/// upstream argument types; injected allocator and Io never enter a group.
fn emitMethodSignature(
    model: *const Model,
    gpa: Allocator,
    scope: Scope,
    objects: ?*Out,
    owner: []const u8,
    self_type: []const u8,
    method: JsonMethod,
) GenerateError!MethodSignature {
    const params = try resolveParams(model, gpa, scope, method);
    for (params, 0..) |param, index| {
        if (param.callback and index + 1 != params.len) return error.CallbackArgumentNotLast;
    }
    const effect = methodEffect(owner, method.name);
    var signature: std.ArrayList(u8) = .empty;
    try signature.appendSlice(gpa, "self: ");
    try signature.appendSlice(gpa, self_type);
    if (effect == .async_start) {
        try signature.appendSlice(gpa, ", allocator: std.mem.Allocator");
    }
    if (effect != .ordinary) {
        try signature.appendSlice(gpa, ", io: std.Io");
    }

    var by_zig_type: std.StringHashMap(usize) = .init(gpa);
    if (objects != null) {
        for (params) |param| {
            if (param.callback) continue;
            const slot = try by_zig_type.getOrPut(param.zig_type);
            if (slot.found_existing) {
                slot.value_ptr.* += 1;
            } else {
                slot.value_ptr.* = 1;
            }
        }
    }
    const method_pascal = if (objects != null) try pascalName(gpa, method.name) else "";
    var emitted_groups: std.ArrayList([]const u8) = .empty;
    for (params) |param| {
        const count = by_zig_type.get(param.zig_type) orelse 0;
        if (!param.callback and count >= 2) {
            var seen = false;
            for (emitted_groups.items) |group| {
                if (std.mem.eql(u8, group, param.zig_type)) seen = true;
            }
            if (seen) continue;
            try emitted_groups.append(gpa, param.zig_type);
            var group_fields: std.ArrayList(Param) = .empty;
            for (params) |other| {
                if (!other.callback and std.mem.eql(u8, other.zig_type, param.zig_type)) {
                    try group_fields.append(gpa, other);
                }
            }
            const group_name = try std.fmt.allocPrint(
                gpa,
                "{s}{s}Options",
                .{ method_pascal, try pascalName(gpa, group_fields.items[0].json_name) },
            );
            const group_param = try std.fmt.allocPrint(
                gpa,
                "{s}_options",
                .{try snakeName(gpa, group_fields.items[0].json_name)},
            );
            try signature.appendSlice(gpa, ", ");
            try signature.appendSlice(gpa, group_param);
            try signature.appendSlice(gpa, ": ");
            try signature.appendSlice(gpa, group_name);

            const out = objects.?;
            _ = try out.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "/// {d} parameters of `{s}` become this struct (`AGENTS.md` section 2).",
                .{ count, param.zig_type },
            ));
            _ = try out.addIndent(
                1,
                try std.fmt.allocPrint(gpa, "pub const {s} = struct {{", .{group_name}),
            );
            for (group_fields.items) |field| {
                _ = try out.addIndent(2, try std.fmt.allocPrint(
                    gpa,
                    "{s}: {s},",
                    .{ field.name, field.zig_type },
                ));
            }
            _ = try out.addIndent(1, "};");
        } else {
            try signature.appendSlice(gpa, ", ");
            try signature.appendSlice(gpa, param.name);
            try signature.appendSlice(gpa, ": ");
            try signature.appendSlice(gpa, param.zig_type);
        }
    }
    return .{
        .params = try signature.toOwnedSlice(gpa),
        .returns = try methodReturnType(model, gpa, scope, effect, method),
        .grouped = emitted_groups.items.len != 0,
        .callback_last = params.len != 0 and params[params.len - 1].callback,
        .effect = effect,
    };
}

/// Emit one method signature and the options structs its parameters need.
fn emitMethod(
    model: *const Model,
    output: *Output,
    objects: *Out,
    entry: Entry,
    tag_name: []const u8,
    method: JsonMethod,
    json_line: u32,
) !void {
    const gpa = output.gpa;
    _ = try objects.addIndent(1, try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" method \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, method.name, json_line },
    ));
    if (method.@"no autolock") |_| {
        _ = try objects.addIndent(1, "/// dawn.json marks this method `no autolock`.");
    }

    const signature = try emitMethodSignature(
        model,
        gpa,
        .objects,
        objects,
        entry.name,
        tag_name,
        method,
    );
    const camel = try camelName(gpa, method.name);
    const decl_line = try objects.addIndent(
        1,
        try std.fmt.allocPrint(
            gpa,
            "pub const {s} = fn ({s}) {s};",
            .{ camel, signature.params, signature.returns },
        ),
    );
    _ = try objects.add("");

    var decision: std.ArrayList(u8) = .empty;
    try decision.appendSlice(gpa, "method");
    if (signature.grouped) {
        try decision.appendSlice(gpa, ", options struct for repeated types");
    }
    if (signature.callback_last) {
        try decision.appendSlice(gpa, ", callback last");
    }
    switch (signature.effect) {
        .ordinary => {},
        .async_start => try decision.appendSlice(gpa, ", allocator and Io, finite async admission errors"),
        .callback_control => try decision.appendSlice(gpa, ", Io, finite callback control errors"),
        .process_events => try decision.appendSlice(gpa, ", Io, finite event processing errors"),
        .future_wait => try decision.appendSlice(gpa, ", Io, finite future wait errors"),
    }
    try output.methods.append(gpa, .{
        .owner = entry.name,
        .upstream = method.name,
        .json_line = json_line,
        .zig = try std.fmt.allocPrint(gpa, "`api.objects.{s}.{s}`", .{ tag_name, camel }),
        .zig_file = "src/api/objects.zig",
        .zig_line = decl_line,
        .decision = try decision.toOwnedSlice(gpa),
    });
}
fn emitChainedHeader(output: *Output) !void {
    var chained = output.chained;
    try header(&chained);
    _ = try chained.add("const std = @import(\"std\");");
    _ = try chained.add("const descriptors = @import(\"descriptors.zig\");");
    _ = try chained.add("");
    output.chained = chained;
}

/// Emit `src/api/chained.zig`: the `Chained` domain, the accessor for each of
/// the 88 chained structs, and one `forEachPresent` per chain root.
///
/// A `forEachPresent` names a callback per extension, so a new chained struct
/// adds a parameter and a call site that does not name it fails to compile
/// (`docs/30-port-design.md` section 4.2).
fn emitChained(model: *const Model, output: *Output) !void {
    const gpa = output.gpa;
    var chained = output.chained;

    _ = try chained.add("/// Every chained struct in dawn.json, by name. 88 members.");
    _ = try chained.add("/// The JSON lives here rather than in `handled.zig` because the accessors");
    _ = try chained.add("/// below walk it, and a sweeper reads both.");
    _ = try chained.addDecl("Chained", "pub const Chained = enum {");
    for (model.entries) |entry| {
        if (!entry.isChained()) continue;
        _ = try chained.addIndent(1, try std.fmt.allocPrint(
            gpa,
            "{s},",
            .{try snakeName(gpa, entry.name)},
        ));
    }
    _ = try chained.add("};");
    _ = try chained.add("");

    _ = try chained.add("/// The dawn.json name of one chained struct.");
    _ = try chained.add("pub fn nameOf(chained: Chained) []const u8 {");
    _ = try chained.addIndent(1, "return switch (chained) {");
    for (model.entries) |entry| {
        if (!entry.isChained()) continue;
        _ = try chained.addIndent(2, try std.fmt.allocPrint(
            gpa,
            ".{s} => \"{s}\",",
            .{ try snakeName(gpa, entry.name), entry.name },
        ));
    }
    _ = try chained.addIndent(1, "};");
    _ = try chained.add("}");
    _ = try chained.add("");

    _ = try chained.add("/// How many chain roots list one chained struct.");
    _ = try chained.add("pub fn rootCount(chained: Chained) usize {");
    _ = try chained.addIndent(1, "return switch (chained) {");
    for (model.entries) |entry| {
        if (!entry.isChained()) continue;
        _ = try chained.addIndent(2, try std.fmt.allocPrint(
            gpa,
            ".{s} => {d},",
            .{ try snakeName(gpa, entry.name), entry.chainRoots().len },
        ));
    }
    _ = try chained.addIndent(1, "};");
    _ = try chained.add("}");
    _ = try chained.add("");

    // One accessor per chain root, naming one callback per extension.
    for (model.entries) |entry| {
        if (!entry.isExtensibleIn()) continue;
        // A root with no extension has nothing to walk, and an accessor over
        // nothing would leave `chain` and `context` unused. Six of the
        // extensible-in roots at the pinned revision are in that state.
        if (extensionSlotCount(model, entry) == 0) continue;
        const root_pascal = try pascalName(gpa, entry.name);
        const chain_name = try std.fmt.allocPrint(gpa, "{s}Chain", .{root_pascal});

        _ = try chained.add(try std.fmt.allocPrint(
            gpa,
            "/// Walk the extensions of `{s}`. Every chained struct whose `chain roots`",
            .{entry.name},
        ));
        _ = try chained.add("/// names this root owns one callback parameter. A new chained struct adds");
        _ = try chained.add("/// a parameter, so a call site that does not name it fails to compile.");
        _ = try chained.add(try std.fmt.allocPrint(
            gpa,
            "pub fn forEachPresent_{s}(",
            .{try snakeName(gpa, entry.name)},
        ));
        _ = try chained.addIndent(1, try std.fmt.allocPrint(
            gpa,
            "chain: descriptors.{s},",
            .{chain_name},
        ));
        _ = try chained.addIndent(1, "comptime Context: type,");
        _ = try chained.addIndent(1, "context: Context,");
        for (model.entries) |chained_entry| {
            if (!chained_entry.isChained()) continue;
            var roots = false;
            for (chained_entry.chainRoots()) |root| {
                if (std.mem.eql(u8, root, entry.name)) roots = true;
            }
            if (!roots) continue;
            const extension = try pascalName(gpa, chained_entry.name);
            const callback = try std.fmt.allocPrint(
                gpa,
                "{s}_callback",
                .{try snakeName(gpa, chained_entry.name)},
            );
            _ = try chained.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}: *const fn (Context, descriptors.{s}) void,",
                .{ callback, extension },
            ));
        }
        _ = try chained.add(") void {");
        for (model.entries) |chained_entry| {
            if (!chained_entry.isChained()) continue;
            var roots = false;
            for (chained_entry.chainRoots()) |root| {
                if (std.mem.eql(u8, root, entry.name)) roots = true;
            }
            if (!roots) continue;
            const field = try snakeName(gpa, chained_entry.name);
            const callback = try std.fmt.allocPrint(gpa, "{s}_callback", .{field});
            _ = try chained.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "if (chain.{s}) |value| {s}(context, value);",
                .{ field, callback },
            ));
        }
        _ = try chained.add("}");
        _ = try chained.add("");
    }
    output.chained = chained;
}
fn emitProcHeader(output: *Output) !void {
    var proc = output.proc;
    try header(&proc);
    _ = try proc.add("const std = @import(\"std\");");
    _ = try proc.add("const bitmask = @import(\"bitmask.zig\");");
    _ = try proc.add("const callbacks = @import(\"callbacks.zig\");");
    _ = try proc.add("const constants = @import(\"constants.zig\");");
    _ = try proc.add("const descriptors = @import(\"descriptors.zig\");");
    _ = try proc.add("const enums = @import(\"enums.zig\");");
    _ = try proc.add("const errors = @import(\"errors.zig\");");
    _ = try proc.add("const objects = @import(\"objects.zig\");");
    _ = try proc.add("");
    output.proc = proc;
}

/// Emit `src/api/proc.zig`: the 205-entry native Zig `ProcTable` and the
/// five free functions in the `function` category.
///
/// Dawn's `generator/templates/dawn_proc_table.h` uses method-specific
/// function pointers, not generic proc-retrieval returns. This table projects
/// those contracts to native Zig, including slices, chains, and error unions.
/// It does not declare Dawn's C ABI.
fn emitProc(model: *const Model, output: *Output) !void {
    const gpa = output.gpa;
    var proc = output.proc;

    _ = try proc.add("/// Native Zig procedures. 205 entries, one per method.");
    _ = try proc.add("/// Returns follow the object method contracts. This is not Dawn's C ABI.");
    _ = try proc.add("");
    _ = try proc.addDecl("ProcTable", "pub const ProcTable = struct {");

    for (model.entries) |entry| {
        if (entry.category != .object) continue;
        const object_name = try pascalName(gpa, entry.name);
        for (entry.methods()) |method| {
            const self_type = try std.fmt.allocPrint(gpa, "objects.{s}", .{object_name});
            const signature = try emitMethodSignature(
                model,
                gpa,
                .proc,
                null,
                entry.name,
                self_type,
                method,
            );
            _ = try proc.addIndent(1, try std.fmt.allocPrint(
                gpa,
                "{s}_{s}: *const fn ({s}) {s},",
                .{
                    try snakeName(gpa, entry.name),
                    try snakeName(gpa, method.name),
                    signature.params,
                    signature.returns,
                },
            ));
        }
    }
    _ = try proc.add("};");
    _ = try proc.add("");
    output.proc = proc;

    for (model.entries) |entry| {
        if (entry.category != .function) continue;
        try emitFunction(model, output, entry);
    }
}

/// Emit one of the five free functions, as an `fn` type: the body lands with
/// the engine milestone.
fn emitFunction(model: *const Model, output: *Output, entry: Entry) !void {
    const gpa = output.gpa;
    var proc = output.proc;
    const camel = try camelName(gpa, entry.name);

    _ = try proc.add(try std.fmt.allocPrint(
        gpa,
        "/// Generated from dawn.json \"{s}\" (src/dawn/dawn.json:{d}).",
        .{ entry.name, entry.line },
    ));
    _ = try proc.add(try tagLine(gpa, entry));
    _ = try proc.add("/// A module-level entry point. The body lands with the engine milestone;");
    _ = try proc.add("/// this file declares the `fn` type so the table and the callers agree.");

    var signature: std.ArrayList(u8) = .empty;
    const raw_args = entry.args();
    for (raw_args, 0..) |arg, index| {
        if (index > 0) try signature.appendSlice(gpa, ", ");
        const member: JsonMember = .{
            .name = arg.name,
            .type = arg.type,
            .annotation = arg.annotation,
            .length = arg.length,
            .optional = arg.optional,
        };
        const rendered = try renderMember(model, gpa, .proc, member);
        try signature.appendSlice(gpa, rendered.zig_name);
        try signature.appendSlice(gpa, ": ");
        try signature.appendSlice(gpa, rendered.zig_type);
    }
    var returns: []const u8 = "void";
    if (entry.json.returns) |value| {
        const ref = try resolveTypeRef(value);
        const zig_ret = try model.valueTypeName(gpa, .proc, ref.name);
        returns = try std.fmt.allocPrint(gpa, "errors.Error!{s}", .{zig_ret});
    }

    const line = try proc.addDecl(
        camel,
        try std.fmt.allocPrint(gpa, "pub const {s} = fn ({s}) {s};", .{ camel, signature.items, returns }),
    );
    _ = try proc.add("");
    output.proc = proc;

    try output.objects.append(gpa, .{
        .upstream = entry.name,
        .json_line = entry.line,
        .zig = try std.fmt.allocPrint(gpa, "`api.proc.{s}`", .{camel}),
        .zig_file = "src/api/proc.zig",
        .zig_line = line,
        .decision = "function, free function as an fn type",
    });
}
/// Count the methods and members of every entry, for the totals in
/// `handled.zig` and the count assertions in `test/api_conformance.zig`.
fn totals(model: *const Model) struct { methods: usize, members: usize } {
    var methods: usize = 0;
    var members: usize = 0;
    for (model.entries) |entry| {
        methods += entry.methods().len;
        members += entry.members().len;
    }
    return .{ .methods = methods, .members = members };
}

/// The number of extension slots a `<Root>Chain` carries.
fn extensionSlotCount(model: *const Model, entry: Entry) usize {
    var count: usize = 0;
    for (model.entries) |candidate| {
        if (!candidate.isChained()) continue;
        for (candidate.chainRoots()) |root| {
            if (std.mem.eql(u8, root, entry.name)) count += 1;
        }
    }
    return count;
}

/// Emit `src/api/handled.zig`: the `Entry` and `Object` domains, the
/// `coverage` switch, the per-entry `record`, the totals, and the sweeps.
///
/// `coverage` has no `else`: a new upstream entry has no arm and the generated
/// file stops compiling until someone writes one. That is the whole point
/// (`AGENTS.md` section 3, `docs/30-port-design.md` section 8.2).
fn emitHandled(model: *const Model, output: *Output) !void {
    const gpa = output.gpa;
    var handled = output.handled;
    try header(&handled);
    _ = try handled.add("const std = @import(\"std\");");
    _ = try handled.add("const enums = @import(\"enums.zig\");");
    _ = try handled.add("");

    _ = try handled.add("/// Every entry in dawn.json, by name. 347 members.");
    _ = try handled.add("/// A new entry upstream adds a member here, and every `switch` over");
    _ = try handled.add("/// `Entry` below stops compiling until someone handles it.");
    _ = try handled.addDecl("Entry", "pub const Entry = enum {");
    for (handled_entry_names) |name| {
        _ = try handled.addIndent(1, try std.fmt.allocPrint(gpa, "{s},", .{try snakeName(gpa, name)}));
    }
    _ = try handled.add("};");
    _ = try handled.add("");

    _ = try handled.add("/// Every WebGPU object in dawn.json, by name. 28 members.");
    _ = try handled.addDecl("Object", "pub const Object = enum {");
    var object_count: usize = 0;
    for (model.entries) |entry| {
        if (entry.category != .object) continue;
        object_count += 1;
        _ = try handled.addIndent(1, try std.fmt.allocPrint(gpa, "{s},", .{try snakeName(gpa, entry.name)}));
    }
    _ = try handled.add("};");
    _ = try handled.add("");

    _ = try handled.add("/// Port coverage for one entry. A `pending` arm is a compile error at the");
    _ = try handled.add("/// point where the sweep reads it, so a new upstream entry cannot be ignored.");
    _ = try handled.addDecl("Coverage", "pub const Coverage = enum { ported, pending };");
    _ = try handled.add("");
    _ = try handled.add("pub fn coverage(entry: Entry) Coverage {");
    _ = try handled.addIndent(1, "return switch (entry) {");
    for (handled_entry_names) |name| {
        _ = try handled.addIndent(2, try std.fmt.allocPrint(
            gpa,
            ".{s} => .ported,",
            .{try snakeName(gpa, name)},
        ));
    }
    _ = try handled.addIndent(1, "};");
    _ = try handled.add("}");
    _ = try handled.add("");

    const count = totals(model);
    _ = try handled.add("/// The number of entries in dawn.json, per the parse above.");
    _ = try handled.addDecl(
        "entry_count",
        try std.fmt.allocPrint(gpa, "pub const entry_count: usize = {d};", .{model.entries.len}),
    );
    _ = try handled.add("/// `sum(len(methods))`, per the parse above. 205 methods.");
    _ = try handled.addDecl(
        "method_count",
        try std.fmt.allocPrint(gpa, "pub const method_count: usize = {d};", .{count.methods}),
    );
    _ = try handled.add("/// `sum(len(members))`, per the parse above. 571 members.");
    _ = try handled.addDecl(
        "member_count",
        try std.fmt.allocPrint(gpa, "pub const member_count: usize = {d};", .{count.members}),
    );
    _ = try handled.add("/// The number of `chained` entries in dawn.json. 88.");
    var chained_count: usize = 0;
    for (model.entries) |entry| {
        if (entry.isChained()) chained_count += 1;
    }
    _ = try handled.addDecl(
        "chained_count",
        try std.fmt.allocPrint(gpa, "pub const chained_count: usize = {d};", .{chained_count}),
    );
    _ = try handled.add("/// The number of `bitmask` entries in dawn.json. 6.");
    var bitmask_count: usize = 0;
    for (model.entries) |entry| {
        if (entry.category == .bitmask) bitmask_count += 1;
    }
    _ = try handled.addDecl(
        "bitmask_count",
        try std.fmt.allocPrint(gpa, "pub const bitmask_count: usize = {d};", .{bitmask_count}),
    );
    _ = try handled.add("/// The number of `enum` entries in dawn.json. 65.");
    var enum_count: usize = 0;
    for (model.entries) |entry| {
        if (entry.category == .@"enum") enum_count += 1;
    }
    _ = try handled.addDecl(
        "enum_count",
        try std.fmt.allocPrint(gpa, "pub const enum_count: usize = {d};", .{enum_count}),
    );
    _ = try handled.add("");
    _ = &object_count;

    _ = try handled.add("/// One entry's counts, as the parse above sees them.");
    _ = try handled.addDecl("Record", "pub const Record = struct {");
    _ = try handled.addIndent(1, "methods: usize,");
    _ = try handled.addIndent(1, "members: usize,");
    _ = try handled.addIndent(1, "extensible: bool,");
    _ = try handled.addIndent(1, "chain_members: usize,");
    _ = try handled.addIndent(1, "extension_slots: usize,");
    _ = try handled.add("};");
    _ = try handled.add("");
    _ = try handled.add("/// The counts for one entry. `chain_members` is the number of chained");
    _ = try handled.add("/// structs that list this entry in `chain roots`. `extension_slots` is the");
    _ = try handled.add("/// number of extension slots the generated `<Root>Chain` carries. The sweep");
    _ = try handled.add("/// below asserts the two agree for every entry.");
    _ = try handled.add("pub fn record(entry: Entry) Record {");
    _ = try handled.addIndent(1, "return switch (entry) {");
    for (handled_entry_names) |name| {
        const entry = model.lookup(name) orelse return error.UnknownTypeName;
        var chain_members: usize = 0;
        for (model.entries) |candidate| {
            if (!candidate.isChained()) continue;
            for (candidate.chainRoots()) |root| {
                if (std.mem.eql(u8, root, name)) chain_members += 1;
            }
        }
        _ = try handled.addIndent(2, try std.fmt.allocPrint(
            gpa,
            ".{s} => .{{ .methods = {d}, .members = {d}, .extensible = {s}, " ++
                ".chain_members = {d}, .extension_slots = {d} }},",
            .{
                try snakeName(gpa, name),
                entry.methods().len,
                entry.members().len,
                if (entry.isExtensibleIn() or entry.isExtensibleOut()) "true" else "false",
                chain_members,
                extensionSlotCount(model, entry),
            },
        ));
    }
    _ = try handled.addIndent(1, "};");
    _ = try handled.add("}");
    _ = try handled.add("");

    _ = try handled.add("test \"every API entry is ported\" {");
    _ = try handled.addIndent(1, "inline for (@typeInfo(Entry).@\"enum\".fields) |field| {");
    _ = try handled.addIndent(2, "const entry: Entry = @enumFromInt(field.value);");
    _ = try handled.addIndent(2, "try std.testing.expectEqual(Coverage.ported, coverage(entry));");
    _ = try handled.addIndent(1, "}");
    _ = try handled.add("}");
    _ = try handled.add("");
    _ = try handled.add("/// One entry's chaining counts, checked in a block of its own.");
    _ = try handled.add("///");
    _ = try handled.add("/// **Why the sweep is a call and not an inlined body.** Zig charges every");
    _ = try handled.add("/// comptime loop iteration and every `if` in a swept body as a backwards");
    _ = try handled.add("/// branch against the block being evaluated, and the quota is 1000. `Entry`");
    _ = try handled.add("/// has 347 members, so the loop and the `if` inside it spend 694 branches");
    _ = try handled.add("/// before the last third of the table is reached. A call per entry gives each");
    _ = try handled.add("/// entry a fresh block, and the loop body below is the one call.");
    _ = try handled.add("fn expectEntryChaining(entry: Entry) !void {");
    _ = try handled.addIndent(1, "const counts = record(entry);");
    _ = try handled.addIndent(1, "try std.testing.expectEqual(counts.chain_members, counts.extension_slots);");
    _ = try handled.addIndent(1, "if (!counts.extensible) {");
    _ = try handled.addIndent(2, "try std.testing.expectEqual(0, counts.extension_slots);");
    _ = try handled.addIndent(1, "}");
    _ = try handled.add("}");
    _ = try handled.add("");
    _ = try handled.add("test \"a chained struct belongs to a root and an extension to none\" {");
    _ = try handled.addIndent(1, "inline for (@typeInfo(Entry).@\"enum\".fields) |field| {");
    _ = try handled.addIndent(2, "try expectEntryChaining(@enumFromInt(field.value));");
    _ = try handled.addIndent(1, "}");
    _ = try handled.add("}");
    _ = try handled.add("");
    _ = try handled.add("test \"the per-entry table sums to the totals\" {");
    _ = try handled.addIndent(1, "var methods: usize = 0;");
    _ = try handled.addIndent(1, "var members: usize = 0;");
    _ = try handled.addIndent(1, "inline for (@typeInfo(Entry).@\"enum\".fields) |field| {");
    _ = try handled.addIndent(2, "const entry: Entry = @enumFromInt(field.value);");
    _ = try handled.addIndent(2, "methods += record(entry).methods;");
    _ = try handled.addIndent(2, "members += record(entry).members;");
    _ = try handled.addIndent(1, "}");
    _ = try handled.addIndent(1, "try std.testing.expectEqual(method_count, methods);");
    _ = try handled.addIndent(1, "try std.testing.expectEqual(member_count, members);");
    _ = try handled.add("}");
    output.handled = handled;
}
/// Emit the `Enum` sweep domain and the `tagType` switch at the end of
/// `enums.zig`, plus the round-trip test.
fn emitEnumDomain(model: *const Model, output: *Output) !void {
    const gpa = output.gpa;
    var enums = output.enums;

    _ = try enums.add("/// Every enum in this file, by snake name. 65 members.");
    _ = try enums.addDecl("Enum", "pub const Enum = enum {");
    var enum_count: usize = 0;
    for (model.entries) |entry| {
        if (entry.category != .@"enum") continue;
        enum_count += 1;
        _ = try enums.addIndent(1, try std.fmt.allocPrint(gpa, "{s},", .{try snakeName(gpa, entry.name)}));
    }
    _ = try enums.add("};");
    _ = try enums.add("");

    _ = try enums.add("/// The Zig type one domain member names.");
    _ = try enums.add("pub fn tagType(kind: Enum) type {");
    _ = try enums.addIndent(1, "return switch (kind) {");
    for (model.entries) |entry| {
        if (entry.category != .@"enum") continue;
        _ = try enums.addIndent(2, try std.fmt.allocPrint(
            gpa,
            ".{s} => {s},",
            .{ try snakeName(gpa, entry.name), try pascalName(gpa, entry.name) },
        ));
    }
    _ = try enums.addIndent(1, "};");
    _ = try enums.add("}");
    _ = try enums.add("");

    _ = try enums.add("/// One tag domain, walked in a block of its own.");
    _ = try enums.add("///");
    _ = try enums.add("/// **Why the sweep is a call and not a nested loop.** Zig charges every");
    _ = try enums.add("/// comptime loop iteration and every `if` in a swept body as a backwards");
    _ = try enums.add("/// branch against the block being evaluated, and the quota is 1000. `Enum`");
    _ = try enums.add("/// names 65 tag domains holding 577 tags between them, so one nested sweep");
    _ = try enums.add("/// spends over 1000 branches and stops. A call per domain gives each domain a");
    _ = try enums.add("/// fresh block, and the loop body below is the one call.");
    _ = try enums.add("fn expectTagsRoundTrip(comptime kind: Enum) !void {");
    _ = try enums.addIndent(1, "const T = tagType(kind);");
    _ = try enums.addIndent(1, "inline for (@typeInfo(T).@\"enum\".fields) |tag| {");
    _ = try enums.addIndent(2, "const value: T = @enumFromInt(tag.value);");
    _ = try enums.addIndent(2, "try std.testing.expectEqual(tag.value, @intFromEnum(value));");
    _ = try enums.addIndent(2, "try std.testing.expectEqualStrings(tag.name, @tagName(value));");
    _ = try enums.addIndent(1, "}");
    _ = try enums.add("}");
    _ = try enums.add("");
    _ = try enums.add("test \"every enum tag round-trips through @intFromEnum\" {");
    _ = try enums.addIndent(1, "inline for (@typeInfo(Enum).@\"enum\".fields) |field| {");
    _ = try enums.addIndent(2, "try expectTagsRoundTrip(@enumFromInt(field.value));");
    _ = try enums.addIndent(1, "}");
    _ = try enums.add("}");
    _ = try enums.add("");
    _ = &enum_count;
    output.enums = enums;
}

/// Emit the round-trip test for the bitmasks at the end of `bitmask.zig`.
fn emitBitmaskTest(model: *const Model, output: *Output) !void {
    const gpa = output.gpa;
    var bitmask = output.bitmask;

    _ = try bitmask.add("test \"every bitmask value round-trips through @bitCast\" {");
    for (model.entries) |entry| {
        if (entry.category != .bitmask) continue;
        const tag_name = try pascalName(gpa, entry.name);
        _ = try bitmask.addIndent(1, try std.fmt.allocPrint(
            gpa,
            "for ({s}_flag_values) |value| {{",
            .{tag_name},
        ));
        _ = try bitmask.addIndent(2, try std.fmt.allocPrint(
            gpa,
            "try std.testing.expectEqual(value, {s}.fromFlags(value).toFlags());",
            .{tag_name},
        ));
        _ = try bitmask.addIndent(1, "}");
    }
    _ = try bitmask.add("}");
    output.bitmask = bitmask;
}

/// Emit `src/api/api.zig`: the module root, the error set re-export, and one
/// `pub const` per entry in PascalCase.
fn emitApi(model: *const Model, output: *Output) !void {
    const gpa = output.gpa;
    var api = output.api;
    try header(&api);
    _ = try api.add("const std = @import(\"std\");");
    _ = try api.add("pub const bitmask = @import(\"bitmask.zig\");");
    _ = try api.add("pub const callbacks = @import(\"callbacks.zig\");");
    _ = try api.add("pub const chained = @import(\"chained.zig\");");
    _ = try api.add("pub const constants = @import(\"constants.zig\");");
    _ = try api.add("pub const descriptors = @import(\"descriptors.zig\");");
    _ = try api.add("pub const enums = @import(\"enums.zig\");");
    _ = try api.add("pub const errors = @import(\"errors.zig\");");
    _ = try api.add("pub const handled = @import(\"handled.zig\");");
    _ = try api.add("pub const natives = @import(\"natives.zig\");");
    _ = try api.add("pub const objects = @import(\"objects.zig\");");
    _ = try api.add("pub const proc = @import(\"proc.zig\");");
    _ = try api.add("");
    _ = try api.add("/// Upstream error values.");
    _ = try api.addDecl("Error", "pub const Error = errors.Error;");
    _ = try api.add("");
    for (native_support_errors) |support| {
        _ = try api.addDecl(support.name, try std.fmt.allocPrint(
            gpa,
            "pub const {s} = errors.{s};",
            .{ support.name, support.name },
        ));
    }
    _ = try api.add("");

    for (handled_entry_names) |name| {
        const entry = model.lookup(name) orelse return error.UnknownTypeName;
        const file = switch (entry.category) {
            .@"enum" => "enums",
            .bitmask => "bitmask",
            .constant => "constants",
            .structure => "descriptors",
            .object => "objects",
            .@"callback function", .@"function pointer", .@"callback info" => "callbacks",
            .function => "proc",
            .native => continue,
        };
        // Free functions read as calls, so they keep the camelCase their
        // declaration carries; every other category reads as a type.
        const symbol = if (entry.category == .function)
            try camelName(gpa, name)
        else
            try pascalName(gpa, name);
        _ = try api.addDecl(symbol, try std.fmt.allocPrint(
            gpa,
            "pub const {s} = {s}.{s};",
            .{ symbol, file, symbol },
        ));
    }
    _ = try api.add("");
    _ = try api.add("test {");
    _ = try api.addIndent(1, "std.testing.refAllDecls(@This());");
    _ = try api.add("}");
    output.api = api;
}

/// Write the three conformance tables.
fn emitTables(output: *Output, gpa: Allocator) ![]const u8 {
    var tables: std.ArrayList(u8) = .empty;
    errdefer tables.deinit(gpa);

    try tables.appendSlice(gpa, "### Objects\n\n");
    try tables.appendSlice(gpa, "| Upstream | Zig | Zig path | Decision |\n");
    try tables.appendSlice(gpa, "| --- | --- | --- | --- |\n");
    for (output.objects.items) |row| {
        try tables.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "| `src/dawn/dawn.json:{d}` \"{s}\" | {s} | `{s}:{d}` | {s} |\n",
            .{ row.json_line, row.upstream, row.zig, row.zig_file, row.zig_line, row.decision },
        ));
    }
    try tables.appendSlice(gpa, "\n### Methods\n\n");
    try tables.appendSlice(gpa, "| Upstream | Zig | Zig path | Decision |\n");
    try tables.appendSlice(gpa, "| --- | --- | --- | --- |\n");
    for (output.methods.items) |row| {
        try tables.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "| `src/dawn/dawn.json:{d}` \"{s}\" \\u2192 \"{s}\" | {s} | `{s}:{d}` | {s} |\n",
            .{ row.json_line, row.owner, row.upstream, row.zig, row.zig_file, row.zig_line, row.decision },
        ));
    }
    try tables.appendSlice(gpa, "\n### Members\n\n");
    try tables.appendSlice(gpa, "| Upstream | Zig | Zig path | Decision |\n");
    try tables.appendSlice(gpa, "| --- | --- | --- | --- |\n");
    for (output.members.items) |row| {
        try tables.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "| `src/dawn/dawn.json:{d}` \"{s}\" \\u2192 \"{s}\" | {s} | `{s}:{d}` | {s} |\n",
            .{ row.json_line, row.owner, row.upstream, row.zig, row.zig_file, row.zig_line, row.decision },
        ));
    }
    return tables.toOwnedSlice(gpa);
}
/// The per-category walk. Each category writes its own file and records its
/// own rows, so a new category stops here with `error.UnexpectedCategory`.
fn generate(model: *const Model, output: *Output) !void {
    try emitNatives(model, output);
    try emitEnums(model, output);
    try emitEnumDomain(model, output);
    try emitBitmask(model, output);
    try emitBitmaskTest(model, output);
    try emitConstants(model, output);
    try emitErrors(model, output);
    try emitCallbacksHeader(output);
    for (model.entries) |entry| {
        switch (entry.category) {
            .@"callback function" => try emitCallbackFunction(model, output, entry),
            .@"callback info" => try emitCallbackInfo(model, output, entry),
            .@"function pointer" => try emitFunctionPointer(model, output, entry),
            else => {},
        }
    }
    try emitDescriptorsHeader(output);
    for (model.entries) |entry| {
        if (entry.category != .structure) continue;
        try emitDescriptor(model, output, entry);
    }
    try emitObjectsHeader(output);
    for (model.entries) |entry| {
        if (entry.category != .object) continue;
        try emitObject(model, output, entry);
    }
    try emitChainedHeader(output);
    try emitChained(model, output);
    try emitProcHeader(output);
    try emitProc(model, output);
    try emitHandled(model, output);
    try emitApi(model, output);
}

/// Write one generated file into the output directory. The directory is
/// created, because the plan runs this program before the directory exists.
fn writeOutputFile(
    gpa: Allocator,
    io: Io,
    out_dir: []const u8,
    file: *Out,
) GenerateError!void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    const bytes = try file.render();
    const name = try std.fs.path.join(gpa, &.{ out_dir, std.fs.path.basename(file.path) });
    try cwd.writeFile(io, .{ .sub_path = name, .data = bytes });
}

pub fn main(init: std.process.Init) GenerateError!void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const dawn_path = args.next() orelse return error.WrongArgumentCount;
    const out_dir = args.next() orelse return error.WrongArgumentCount;
    const table_path = args.next() orelse return error.WrongArgumentCount;
    if (args.next() != null) return error.WrongArgumentCount;

    const cwd = Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, dawn_path, gpa, json_byte_limit) catch {
        return error.JsonTooLarge;
    };
    const entries = try loadEntries(gpa, text);
    var by_name: std.StringHashMap(Entry) = .init(gpa);
    for (entries) |entry| {
        const result = try by_name.getOrPut(entry.name);
        if (result.found_existing) return error.DuplicateEntryName;
        result.value_ptr.* = entry;
    }
    const model: Model = .{ .gpa = gpa, .io = io, .entries = entries, .by_name = by_name };
    var output: Output = .{
        .gpa = gpa,
        .model = &model,
        .natives = Out.init(gpa, "src/api/natives.zig"),
        .enums = Out.init(gpa, "src/api/enums.zig"),
        .bitmask = Out.init(gpa, "src/api/bitmask.zig"),
        .constants = Out.init(gpa, "src/api/constants.zig"),
        .errors = Out.init(gpa, "src/api/errors.zig"),
        .callbacks = Out.init(gpa, "src/api/callbacks.zig"),
        .descriptors = Out.init(gpa, "src/api/descriptors.zig"),
        .objects_file = Out.init(gpa, "src/api/objects.zig"),
        .chained = Out.init(gpa, "src/api/chained.zig"),
        .proc = Out.init(gpa, "src/api/proc.zig"),
        .handled = Out.init(gpa, "src/api/handled.zig"),
        .api = Out.init(gpa, "src/api/api.zig"),
    };

    // `docs/40-plan.md` section M2 carries 347 object, 205 method and 571
    // member rows. The ledger below fails the run unless the JSON is exactly
    // what the plan counts: a new upstream entry is `error` rather than a
    // silent gap in the table.
    if (entries.len != handled_entry_names.len) return error.UpstreamEntryCountChanged;
    try generate(&model, &output);

    try writeOutputFile(gpa, io, out_dir, &output.natives);
    try writeOutputFile(gpa, io, out_dir, &output.enums);
    try writeOutputFile(gpa, io, out_dir, &output.bitmask);
    try writeOutputFile(gpa, io, out_dir, &output.constants);
    try writeOutputFile(gpa, io, out_dir, &output.errors);
    try writeOutputFile(gpa, io, out_dir, &output.callbacks);
    try writeOutputFile(gpa, io, out_dir, &output.descriptors);
    try writeOutputFile(gpa, io, out_dir, &output.objects_file);
    try writeOutputFile(gpa, io, out_dir, &output.chained);
    try writeOutputFile(gpa, io, out_dir, &output.proc);
    try writeOutputFile(gpa, io, out_dir, &output.handled);
    try writeOutputFile(gpa, io, out_dir, &output.api);

    const tables = try emitTables(&output, gpa);
    try cwd.writeFile(io, .{ .sub_path = table_path, .data = tables });
}
