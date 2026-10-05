# 30 — Port design: the Zig-native contract

This document replaces Dawn's C++ idioms with Zig ones. It fixes the public
shape of the port: what a handle is, what an error is, what a future is, how a
descriptor chains, how a `VkResult` becomes a Zig error, how the dispatch table
is loaded, which container replaces which, and how `dawn.json` becomes Zig.

Every upstream claim cites `path:line` in the Dawn tree pinned at
`32f77c02294310054a660c393feded4bcb3f203c`, read-only at
`/tmp/scratch/research/dawn`. Zig claims cite a file and line in
the 0.16.0 standard library, or the generated `vulkan.zig` in the probe
directory, and those observations were made by reading the file.

A contested decision carries five parts: **Priority**, **Constraint**,
**Cost imposed on consumers**, **Counterchoice**, **Grade and origin**.

**What this document does not claim.** It does not claim the port compiles; no
code exists yet. It does not claim any timing, throughput, or memory figure,
because none has been measured. It does not claim `dawn.json` output is
byte-compatible with Dawn's C header, and §4 says why that is not the goal. It
does not reopen any decision in `docs/20-dependencies.md`.

---

## 1. Ownership and lifetime

### 1.1 The model

`docs/10-architecture.md` fixes the shape: one arena per device, every object is
a handle, no per-object free. This section states what that means at the type
level and what it costs.

A handle is a pointer into the device's arena, plus one byte of kind for the
boundary check below. Not a tagged integer, not a generational id, not an index
into a slab.

```zig
// src/core/handle.zig
pub const Handle = struct {
    ptr: *anyopaque,
    kind: Kind,

    /// GENERATED from the 28 `object` entries in dawn.json, the same list that
    /// src/api/handles.zig turns into aliases. Every object type therefore
    /// carries a kind byte. A new upstream object adds a member here, so every
    /// switch over Kind must name it.
    pub const Kind = enum(u8) {
        adapter,
        bind_group,
        bind_group_layout,
        buffer,
        command_buffer,
        command_encoder,
        compute_pass_encoder,
        compute_pipeline,
        device,
        external_texture,
        instance,
        pipeline_layout,
        query_set,
        queue,
        render_bundle,
        render_bundle_encoder,
        render_pass_encoder,
        render_pipeline,
        resource_table,
        sampler,
        shader_module,
        shared_buffer_memory,
        shared_fence,
        shared_texture_memory,
        surface,
        texel_buffer_view,
        texture,
        texture_view,
    };
};
```

The public typed aliases come from the same 28 `object` entries as `Kind`, and
§8 owns the generator:

```zig
// src/api/handles.zig — GENERATED from the 28 `object` entries in dawn.json
pub const Buffer = Handle;
pub const Device = Handle;
pub const ShaderModule = Handle;
```

`Buffer` and `Device` are both `Handle`, so a consumer cannot pass a buffer
where a device belongs without a cast. `kind` exists so the API layer can
reject that cast at a boundary with a message rather than with a crash. It is
one byte; it is not a type-level guarantee.

A handle carries no state of its own. Copying one is a pointer copy. There is
no destructor, no `deinit`, no `release`.

```zig
// src/engine/device.zig
pub fn createBuffer(
    alloc: std.mem.Allocator,
    dev: *Device,
    desc: BufferDescriptor,
) Allocator.Error!Buffer {
    const object = try alloc.create(BufferImpl);
    object.* = .{ .device = dev, .descriptor = desc };
    return .{ .ptr = object, .kind = .buffer };
}

pub fn destroyBuffer(dev: *Device, buffer: Buffer) void {
    const object: *BufferImpl = @ptrCast(@alignCast(buffer.ptr));
    if (object.state != .alive) return dev.reportStaleHandle(buffer);
    object.state = .destroyed;
}
```

`destroyBuffer` marks, and frees nothing. Memory returns to the arena when the
device is destroyed, through `Device.deinit`.

```zig
pub fn deinit(dev: *Device) void {
    dev.pending_fences.waitAll();
    dev.arena.deinit();
}
```

**When memory is released.** Only in `Device.deinit`. The arena is the whole
object heap for that device.
Every constructor call site passes `dev.arena.allocator()`, which is what makes
the M3 `queryCapacity == 0` assertion in `docs/40-plan.md` meaningful.

**What a stale handle does.** It reads memory the arena still owns, so the read
is defined behaviour rather than undefined behaviour. Three cases, in order:

1. The object is alive. The call works.
2. The object was destroyed. `object.state == .destroyed`, so the call is a
   validation error, returned as `error.StaleHandle`.
3. The device was destroyed and the arena released. The pointer dangles. This
   is the one case the model does not cover, and it is the case the
   counterchoice below wins.

```zig
pub fn writeBuffer(
    dev: *Device,
    buffer: Buffer,
    options: WriteBufferOptions,
) (ValidationError || UnrecoverableError)!void {
    const object = dev.resolve(buffer) orelse return error.StaleHandle;
    // ...
}
```

`resolve` reads `state` under the device mutex and returns `null` for case 2.

**Cost imposed on consumers.**

- Objects cannot outlive their device. A consumer that wants a buffer to
  survive device teardown must keep the device alive, or copy the bytes out
  first. Dawn permits the first and permits the second through `Ref<T>`; the
  port permits both only if the consumer holds the device.
- Peak memory is the high-water mark of the device's lifetime, not the live
  set. A consumer that creates and destroys a texture every frame pays for the
  whole run. Dawn's refcount returns the allocation at the last release.
- A consumer cannot port a Dawn object graph by copying the `Ref<T>` fields. It
  has to model device ownership explicitly.

### 1.2 The decision record

**Priority.** Safety, first in the house order in `AGENTS.md` §2.

**Constraint.** Zig has no refcounted smart pointer. `AGENTS.md` §3 lists
per-object refcounting as one of two options, and `docs/10-architecture.md`
already chose the arena. Dawn's own record of why its model is hard is the
`DeleteThis` comment at `src/dawn/native/ObjectBase.h:177-186`: a derived class
must override `DeleteThis` so that `DestroyImpl` runs while the derived class is
still intact, and every class that overrides `DeleteThis` again must remember to
call the base. That is a footgun the port declines to carry.

**Cost imposed on consumers.** The three costs listed in §1.1.

**Counterchoice.** Per-object reference counting with an explicit `release()`:

```zig
pub fn createBuffer(dev: *Device, alloc: std.mem.Allocator, desc: BufferDescriptor) Allocator.Error!Buffer {
    const object = try alloc.create(BufferImpl);
    object.* = .{ .device = dev, .descriptor = desc, .ref_count = .init(1) };
    return .{ .ptr = object, .kind = .buffer };
}

pub fn retain(buffer: Buffer) void { ... }
pub fn release(buffer: Buffer) void { ... }  // frees at zero
```

This genuinely wins in one setting: a long-lived engine whose objects must
outlive the device that made them. A compositor holding a swapchain image and a
device that is being torn down and rebuilt is exactly that case — the image
outlives the device, refcounting keeps it valid, and an arena cannot. It also
wins when peak memory matters more than safety: it returns allocation at the
last release, so a per-frame create/destroy loop does not grow.

**Grade and origin.** Settled. `docs/10-architecture.md` "Object model";
`AGENTS.md` §2 and §3; upstream evidence `src/dawn/common/RefCounted.h:69`,
`src/dawn/common/RefCounted.cpp:41-43` (`kPayloadBits = 2`), and
`src/dawn/common/RefBase.h:52-57`, which asserts `sizeof(RefBase<T>) ==
sizeof(T)` and so makes `Ref<T>` zero-overhead at the cost of a manual
`release()` discipline the type system cannot check.

### 1.3 What the arena does not replace

Dawn packs two payload bits into the refcount word and uses them to carry error
state (`src/dawn/common/RefCounted.cpp:41-43`, `:56-62`). The port puts that
state in the object, where it is readable:

```zig
const BufferImpl = struct {
    device: *Device,
    descriptor: BufferDescriptor,
    state: State,
    last_error: ?ValidationError,  // Dawn's two payload bits, named
};

pub const State = enum { alive, destroyed, error };
```

Dawn reads and writes the payload through `PayloadFetchAnd` and
`PayloadFetchOr` with relaxed ordering (`src/dawn/common/RefCounted.cpp:64-77`).
The port has no equivalent atomic to reason about, and a named field is one
assertion instead of a bit-mask argument.

---

## 2. Errors

### 2.1 Three error sets

Dawn defines `InternalErrorType` as a bitmask
(`src/dawn/native/Error.h:43-50`):

```cpp
enum class InternalErrorType : uint32_t {
    None = 0, Validation = 1, BackendDeviceLost = 2,
    Unrecoverable = 4, PipelineUncategorized = 8, OutOfMemory = 16
};
```

The bitmask form lets `HandleError` test a set of allowed types with one `&`
(`src/dawn/native/Device.cpp:639-648`), and lets the same error convert
implicitly to six different types through `detail::ErrorAdapter`
(`src/dawn/native/Error.h:181-224`). Both are conveniences C++ needs and Zig
does not.

The port declares three error sets. They are separate types, so a function that
can return a validation error cannot silently return a device-lost error:

```zig
// src/core/errors.zig
pub const ValidationError = error{
    BufferSizeTooSmall,
    BufferUsageMissingCopyDst,
    TextureFormatNotRenderable,
    BindGroupLayoutMismatch,
    EncoderAlreadyFinished,
    StaleHandle,
    RequiredFeatureMissing,
    SliceLengthMismatch,
    LimitExceeded,
};

pub const DeviceLostError = error{
    DeviceLost,
    DeviceDestroyed,
};

pub const UnrecoverableError = error{
    OutOfDeviceMemory,
    OutOfHostMemory,
    PipelineUncategorized,
    InternalInvariantViolated,
    Unimplemented,
};
```

The mapping from Dawn's six bits:

| Dawn `InternalErrorType` | Port | Note |
| --- | --- | --- |
| `Validation = 1` | `ValidationError` | one member per rule |
| `BackendDeviceLost = 2` | `DeviceLostError` | |
| `Unrecoverable = 4` | `UnrecoverableError` | |
| `PipelineUncategorized = 8` | `UnrecoverableError.PipelineUncategorized` | a member, not a set |
| `OutOfMemory = 16` | `UnrecoverableError.OutOfDeviceMemory` / `.OutOfHostMemory` | split, because the two are distinguishable and mean different things |
| `None = 0` | no error | |

Splitting `OutOfMemory` is a change, not a translation. Dawn folds both Vulkan
memory codes into one bit at `src/dawn/native/vulkan/VulkanError.cpp:117-118`.
The port keeps them apart because a consumer that can retry host allocation
should not be told to free device memory.

`PipelineUncategorized` becomes a member of `UnrecoverableError` rather than a
set bit. A bitmask needs the bit to test it against a mask
(`src/dawn/native/Device.cpp:642`); a member needs nothing.

### 2.2 What an error carries

Dawn's `ErrorData` holds six members
(`src/dawn/native/ErrorData.h:101-106`): `mType`, `mMessage`, `mBacktrace`,
`mContexts`, `mDebugGroups`, `mBackendMessages`. The port's `Error` holds four:

```zig
// src/core/Error.zig
pub const Error = struct {
    code: Code,
    message: []const u8,
    context: []const Context,
    backtrace: ?*std.builtin.StackTrace,

    pub const Code = union(enum) {
        validation: ValidationError,
        device_lost: DeviceLostError,
        unrecoverable: UnrecoverableError,
    };

    pub const Context = struct {
        text: []const u8,
        offset: u64,   // byte offset in a buffer, when the context is a range
    };
};

pub fn init(
    allocator: std.mem.Allocator,
    code: Error.Code,
    backtrace: ?*std.builtin.StackTrace,
    comptime fmt: []const u8,
    args: anytype,
    context: []const Context,
) Allocator.Error!Error
```

`code` is the machine-readable id. `message` is a formatted string for a human.
`context` is the port's `mContexts`. `backtrace` is `mBacktrace`. The two
dropped members are `mDebugGroups` and `mBackendMessages`, which Dawn uses to
relay messages from a back end that has its own diagnostics; the port's only
back end is Vulkan, and its messages reach the log through the same `message`
field.

`message` is allocated from the allocator `init` takes, never from a global, per
`AGENTS.md` §2. On the out-of-memory path the caller passes a comptime string
with no arguments, so the only allocation is a constant-size copy of that
string. If that copy fails, the caller has an `error.OutOfMemory` and no
`Error`, which is the honest outcome: an allocator that cannot allocate cannot
carry a message.

### 2.3 `DAWN_INVALID_IF` becomes a typed error plus a message table

Dawn's macro is one statement plus a trailing unroll hint, at
`src/dawn/native/Error.h:277-282`:

```cpp
#define DAWN_INVALID_IF(EXPR, ...)                                       \
    if (EXPR) [[unlikely]] {                                             \
        return DAWN_MAKE_VALIDATION_ERROR(absl::StrFormat(__VA_ARGS__)); \
    }
                                                                    \
    for (;;)                                                         \
    break
```

There are **975** call sites across `src/dawn/native` — 956 in `.cpp` and 19 in
`.h` — counting both `DAWN_INVALID_IF` and `DAWN_VALIDATION_ERROR`:
`git grep -o -E 'DAWN_INVALID_IF|DAWN_VALIDATION_ERROR' 32f77c0 --
'src/dawn/native/*.cpp' 'src/dawn/native/*.h' | wc -l`. No `.inl` file in the
directory carries either macro. The skipped back ends hold 110 of those sites:
`d3d12` 35, `opengl` 32, `d3d11` 21, `d3d` 10, `webgpu` 9, `null` 3 and
`metal` 0. Subtracting them leaves 975 - 110 = 865: 772 in the top-level
`.cpp`/`.h`, 91 in `vulkan` and 2 in `stream`. Each site is a rule, and each
rule has no identity beyond its message text. `docs/02-dawn-design.md` §4.8
records the same fact: there is no message-id mechanism at this revision.

The port gives every rule a name and keeps the text in a table.

```zig
// The rule, at the call site:
if (desc.size < @sizeOf(u32)) return error.BufferSizeTooSmall;

// The table, generated or hand-written once per module:
pub const message_table = std.StaticStringMap([]const u8{
    .{ "BufferSizeTooSmall", "buffer size {d} is smaller than the 4 bytes a u32 requires" },
    .{ "BufferUsageMissingCopyDst", "buffer usage is missing BufferUsage.copy_dst" },
    .{ "TextureFormatNotRenderable", "texture format {s} cannot be a render attachment" },
});
```

The rule returns the error. The formatting happens once, at the point where the
error becomes a message, using the table:

```zig
pub fn format(allocator: std.mem.Allocator, err: Error) Allocator.Error![]u8 {
    return switch (err.code) {
        .validation => |code| try formatRule(allocator, code, err.context),
        else => try allocator.dupe(u8, err.message),
    };
}

fn formatRule(allocator: std.mem.Allocator, code: ValidationError, context: []const Context) Allocator.Error![]u8 {
    const template = message_table.get(@errorName(code)) orelse
        return error.MissingMessageTableEntry;
    return renderTemplate(allocator, template, context);
}
```

`error.MissingMessageTableEntry` is deliberate. A rule with no table entry is a
defect, and the port says so instead of printing a bare name.

**Why a Zig error set is a better stable id.** A Dawn error is a formatted
string and nothing else (`src/dawn/native/ErrorData.h:102`: `std::string
mMessage`). There is no identifier, so a consumer cannot match on it. The
established workaround is substring matching on the text, which breaks the
moment a message is reworded. A Zig error set member is:

- **exhaustive at compile time.** `switch (err)` with no `else` fails to
  compile when a member is added. A `std.StaticStringMap` entry does not.
- **sweepable at compile time.** `AGENTS.md` §3 requires an `inline for` over
  `@typeInfo(ErrorSet).error_set.?` so every member is named by a test. The
  reflection field exists in 0.16.0 at `lib/std/builtin.zig:725`
  (`pub const ErrorSet = ?[]const Error`).
- **zero-sized and non-allocating.** The id costs one byte in the error-union
  tag. Dawn's string costs a heap allocation on every error.

```zig
test "every validation rule has a message" {
    inline for (@typeInfo(ValidationError).error_set.?) |code| {
        const name = @errorName(code);
        try std.testing.expect(message_table.get(name) != null);
    }
}
```

**How a caller matches on a specific validation error.**

```zig
createBuffer(dev, alloc, .{ .usage = .copy_dst, .size = 2 }) catch |err| switch (err) {
    error.BufferSizeTooSmall => useFourBytes(),
    error.BufferUsageMissingCopyDst => addCopyDst(),
    else => return err,
};
```

Three error sets do not compose into one signature. A function that can fail
validation and can lose the device returns:

```zig
pub fn createRenderPipeline(
    dev: *Device,
    io: std.Io,
    alloc: std.mem.Allocator,
    desc: RenderPipelineDescriptor,
) (ValidationError || DeviceLostError || UnrecoverableError)!RenderPipeline
```

Zig infers the union, so the declaration names the obligation rather than
computing it. `AGENTS.md` §2 forbids `anyerror` and this signature satisfies
that rule: a reader can enumerate every failure mode without reading the body.

Dawn cannot express this. `detail::ErrorAdapter` implicitly converts one
`ErrorData` to eight types (`src/dawn/native/Error.h:181-224`), so the caller
must know which one it got. The commented-out assert at
`src/dawn/native/Error.h:62` is the residue of that problem.

### 2.4 The decision record

**Priority.** Safety, then correctness of the error contract.

**Constraint.** `AGENTS.md` §2: "An API declares its own error set and never
leaks `anyerror`." `AGENTS.md` §3: "Errors are values. Declare the error set.
Sweep it at compile time."

**Cost imposed on consumers.** A consumer writes `catch |err| switch (err)`
with an `else` arm, because a function's error set is a union of three sets
and the switch must be exhaustive over all of them. A consumer that only cares
about validation still names the device-lost arm. Dawn's implicit conversion
hides that, and the hiding is what produced
`src/dawn/native/Error.h:62`.

**Counterchoice.** One `Error` struct returned by value, with `code` as a tagged
union, and no error sets at all. This genuinely wins in one setting: a
cross-language boundary. When the C ABI milestone adds a C header, a C caller
cannot match on a Zig error set, so a `struct Error` with an integer `code` and
a `const char *message` is directly expressible, while an error set needs a
parallel mapping table and a per-call-site wrapper. It also wins when a
consumer wants to attach data to an error and pass it across a thread without
a second allocation.

**Grade and origin.** Settled for the Zig-native surface.
`docs/02-dawn-design.md` §4.1 and §4.2 established that `Result<T>` is not to
be reimplemented and that the `InternalErrorType` mapping is the port's job.
`AGENTS.md` §2 and §3 fix the error-set form. The C-ABI alternative is
recorded in `docs/40-plan.md` as a later milestone.

---

## 3. Futures and async

### 3.1 What Dawn has

Dawn's async machinery is five files.

| Piece | Where | What it does |
| --- | --- | --- |
| `Future` | `src/dawn/common/FutureUtils.h:38` | a `uint64_t` id; `kNullFutureID = 0` at `:39` |
| `EventManager` | `src/dawn/native/EventManager.h:68` | owns the id→event map at `:93` and hands out ids at `:76` |
| `TrackedEvent` | `src/dawn/native/EventManager.h:134` | refcounted base for anything a `Future` completes |
| `CallbackTaskManager` | `src/dawn/native/CallbackTaskManager.h:65` | a mutex-guarded queue of `CallbackTask`, flushed by the tick |
| `WaitListEvent` | `src/dawn/native/WaitListEvent.h:47` | a counting event with `mSyncWaiters` and `mAsyncWaiters` |

`dawn.json` types them as `future` (`src/dawn/dawn.json:2750-2755`, one `uint64_t`
member named `id`) and `future wait info`
(`src/dawn/dawn.json:2766-2772`, a `future` plus a `bool completed`).

Two public entry points depend on this. Async pipeline creation runs through
`CreatePipelineAsyncEvent` (`src/dawn/native/CreatePipelineAsyncEvent.h:52`),
which is a `TrackedEvent` with an `InitializeAsync` at `:71` that posts to the
worker pool. Buffer mapping returns a future from
`BufferBase::APIMapAsync` (`src/dawn/native/Buffer.h:199`), backed by a
`MapAsyncEvent` declared at `src/dawn/native/Buffer.h:240`.

The whole of Dawn's threading is one pool: `AsyncWorkerThreadPool`
(`src/dawn/platform/WorkerThread.h:87`), defaulting to
`kDefaultTaskHandlingJobCount = 2` at `src/dawn/platform/WorkerThread.h:89`.
There are no fence-poll threads; `docs/02-dawn-design.md` §4.4 records that
`FenceMonitor.h`, `Serial.h`, `Timeline.h`, `Executor.h` and `Processor.cpp` do
not exist at this revision.

### 3.2 What replaces it

Zig 0.16.0 ships an `Io` interface with futures as a primitive, not a library
layer. `lib/std/Io.zig:1176` defines `Future(Result)` as a struct of a
`?*AnyFuture` and a `result`, with `await(io)` at `:1199` and `cancel(io)` at
`:1191`. `io.async` at `:2326` spawns a task and returns the future;
`io.concurrent` at `:2365` does the same but returns
`error.ConcurrencyUnavailable` when the implementation cannot supply a unit of
concurrency. `Io.Group` at `:1218` is an unordered set of tasks awaited as a
whole, with `async` at `:1240`, `concurrent` at `:1261`, `await` at `:1282`,
and `cancel` at `:1298`.

The pool is `Io.Threaded` (`lib/std/Io/Threaded.zig`), `init` at `:1607` with
`InitOptions` at `:1573`. The size limit is `async_limit: ?Io.Limit` at
`:1586`, and `Io.Limit` is an enum with `limited(n)` at `lib/std/Io.zig:632`.
The `Io` value comes from `Threaded.io` at
`lib/std/Io/Threaded.zig:1806`.

So Dawn's two-thread pool is one option value:

```zig
// src/platform/pool.zig
pub fn initPool(gpa: std.mem.Allocator) std.Io.Threaded {
    return .init(gpa, .{
        .async_limit = worker_thread_count,
        .concurrent_limit = worker_thread_count,
    });
}
```

The two limits are separate fields in 0.16.0. `async_limit` is at
`lib/std/Io/Threaded.zig:1586` and governs `Io.async`: past the limit, the task
runs immediately on the calling thread instead of spawning. `concurrent_limit`
is at `lib/std/Io/Threaded.zig:1592` and defaults to `.unlimited`; past it,
`Io.concurrent` returns `error.ConcurrencyUnavailable`. The port sets both to
`.limited(2)` so a bound is a bound rather than a default.

This is a different failure mode from Dawn's `std::queue`-backed `TaskTracking`
(`src/dawn/platform/WorkerThread.h:101-107`), which queues and never refuses.
Under `dusk`, a third `Io.async` task runs inline on the submitting thread: it
is still validated, it is just not parallel. A third `Io.concurrent` call fails
with `error.ConcurrencyUnavailable`. Both are recorded because they change
latency, not correctness, and `docs/50-verification.md` owns what a timing claim
needs.

**Decision: `std.Io.Future`, passed by value, awaited by the caller.**

```zig
// src/pipeline/pipeline.zig
pub fn createRenderPipelineAsync(
    dev: *Device,
    io: std.Io,
    desc: RenderPipelineDescriptor,
) std.Io.Future(PipelineResult) {
    return io.async(createRenderPipelineTask, .{ dev, desc });
}

fn createRenderPipelineTask(dev: *Device, desc: RenderPipelineDescriptor) PipelineResult {
    // SPIR-V validation happens here, off the submitting thread.
    // ...
    return .{ .pipeline = pipeline, .error = null };
}
```

Buffer mapping is the same shape:

```zig
// src/engine/buffer.zig
pub fn mapAsync(
    dev: *Device,
    io: std.Io,
    buffer: Buffer,
    options: MapAsyncOptions,
) std.Io.Future(MapResult) {
    return io.async(mapAsyncTask, .{ dev, buffer, options });
}

pub const MapResult = struct {
    data: ?[*]u8,
    error: ?Error,
};
```

**`Io` is a parameter, never global.** `AGENTS.md` §3 makes this mandatory and
`docs/10-architecture.md` repeats it. Every signature above takes `io`. A test
builds its own `Io` — `std.Io.failing` at `lib/std/Io.zig:2512` refuses every
operation, `Io.Threaded.init_single_threaded` at
`lib/std/Io/Threaded.zig:1674` runs tasks inline — so a deterministic back end
is a parameter swap.

**Cancellation is free.** `Future.cancel(io)` at `lib/std/Io.zig:1191` asks the
task to return `error.Canceled` at its next cancelation point. Dawn has no
equivalent on the path that matters. `PostWorkerTask` returns a
`std::unique_ptr<WaitableEvent>` whose only operations are `Wait` and
`IsComplete` (`src/dawn/platform/WorkerThread.h:93`, implemented at
`src/dawn/platform/WorkerThread.cpp:36-45`); it has no cancel.
`PostWorkerJob` returns a `JobHandle` that does have `Cancel`
(`src/dawn/platform/WorkerThread.h:95`, `src/dawn/platform/WorkerThread.cpp:50-59`),
but a `JobHandle` is a long-running loop rather than one task, and neither is
reachable from a `Future`. A Dawn future cannot be withdrawn. A `dusk` future can.

### 3.3 The decision record

**Priority.** Safety and determinism. `AGENTS.md` §3 orders it that way, and a
deterministic test is a hard requirement there.

**Constraint.** `AGENTS.md` §3: "`io` threaded explicitly, never global. Every
function that can block or perform I/O takes `io` as a parameter." Dawn's
`EventManager` is documented at `src/dawn/native/EventManager.h:59` as a
"Subcomponent of the Instance" and is reached through `InstanceBase`, which is
exactly the hidden state the house rule forbids.

**Cost imposed on consumers.**

- Every async call takes `io` and returns a `std.Io.Future`, which must be
  awaited or dropped. A consumer that drops a future without awaiting leaks the
  task's resources; `Io.Group`'s doc comment at
  `lib/std/Io.zig:1215-1217` says so explicitly.
- The `Io` value is threaded through call sites that do no I/O themselves. That
  is the price of the no-global rule.
- The third concurrent async task runs inline rather than queueing (§3.2). A
  consumer that depends on the pool never blocking the caller must pass a
  larger `async_limit`.

**Counterchoice.** A plain callback, last parameter, named
`<caller>_callback`, per `AGENTS.md` §2:

```zig
pub fn createRenderPipelineAsync(
    dev: *Device,
    io: std.Io,
    desc: RenderPipelineDescriptor,
    completion_callback: PipelineCallback,
) void
```

This genuinely wins in one setting: a consumer with an existing event loop and
no interest in Zig futures. A C-ABI consumer, or a consumer embedding `dusk` in
a browser-facing shim, already has a completion path and a future adds a second
one. It also wins when there is exactly one completion and no cancellation to
express: `Future` returns a two-field struct and requires an `await` that a
callback makes unnecessary.

`dusk` ships the future because `Io` gives cancellation and composability for
free, and because the callback form has no way to express `mapAsync` failure
without the callback's parameter becoming an error union the caller must
inspect immediately.

**Grade and origin.** Settled. `AGENTS.md` §3 (io threading),
`docs/10-architecture.md` "Threading" (one worker pool, two jobs). Upstream
evidence: `src/dawn/native/EventManager.h:68`, `:134`;
`src/dawn/platform/WorkerThread.h:87-89`;
`src/dawn/native/Buffer.h:199`; `src/dawn/native/CreatePipelineAsyncEvent.h:52`.

---

## 4. Descriptors and chaining

### 4.1 What Dawn does

Dawn's extensible structures chain through a raw `next` pointer. In C the
generator emits:

```c
typedef struct WGPUChainedStruct {
    struct WGPUChainedStruct * next;
    WGPUSType sType;
} WGPUChainedStruct;
```

(`generator/templates/api.h:300-303`.) An extensible struct gets a
`nextInChain` member (`generator/templates/api.h:127`); a chained struct
gets a `chain` member (`generator/templates/api.h:130`). The C++ header
splits the two into `ChainedStruct` and `ChainedStructOut` with `const` and
non-`const` `nextInChain`
(`generator/templates/api_cpp_chained_struct.h:47-56`).

The C++ native side unpacks the chain into a typed tuple. `UnpackedPtr<T>` at
`src/dawn/native/ChainUtils.h:90` holds the raw pointer plus a
`TupleType` (`:97`) and a `BitsetType` (`:98`), and exposes `Get<In>()` at
`:112`, `Has<In>()` at `:114`, `ValidateBranches<...>()` at `:118` and
`ValidateSubset<...>()` at `:120`. `Unpack` is declared at `:71` and `:74`;
`ValidateAndUnpack` at `:79` and `:82`. The per-type specializations —
`STypeForImpl` and `AdditionalExtensions` — live in
`src/dawn/native/ChainUtilsImpl.inl:60-63` and `:101-107`, and they are
hand-written per back end, which is why `d3d11`, `d3d12`, `opengl` and `vulkan`
specializations exist side by side (`src/dawn/native/ChainUtilsImpl.inl:61-108`).

In `dawn.json` this is data. **88** objects carry `chained` and `chain roots`,
**73** carry `extensible`, of which **58** are `"in"` and **11** are `"out"`;
the remaining four carry `"extensible": false`. Counted with a Python one-liner
over the parsed JSON. `s type` has **99** values
(`src/dawn/dawn.json:4133-4137` onwards). An example, at
`src/dawn/dawn.json:83-90`:

```json
"request adapter WebXR options": {
    "category": "structure",
    "chained": "in",
    "chain roots": ["request adapter options"],
    "members": [
        {"name": "xr compatible", "type": "bool"}
    ]
},
```

### 4.2 The generated optional-chain type

The port replaces the pointer walk with a comptime-generated struct of optionals.
For each extensible root, the generator emits one Zig struct whose members are
the root's own fields plus one `?T` per chained struct that lists the root in
its `chain roots`.

```zig
// src/api/chains.zig — GENERATED
pub const RequestAdapterOptionsChain = extern struct {
    // The root's own fields.
    power_preference: PowerPreference = .none,
    force_fallback_adapter: bool = false,
    compatibility_mode: ?bool = null,

    // One optional per chained struct whose `chain roots` names this root.
    webxr_options: ?WebXrOptions = null,
    webgpu_backend_options: ?WebGpuBackendOptions = null,
};

pub const WebXrOptions = extern struct {
    xr_compatible: bool = false,
};

pub const WebGpuBackendOptions = extern struct {
    // No members; the JSON entry at src/dawn/dawn.json:91-97 has an empty list.
};
```

The `?T` is `null` when the consumer did not set the extension. There is no
`next` pointer, no `sType`, no tuple, no bitset. A consumer sets an extension
member by name:

```zig
const options: RequestAdapterOptionsChain = .{
    .power_preference = .high_performance,
    .webxr_options = .{ .xr_compatible = true },
};

const adapter = try requestAdapter(dev, io, alloc, options);
```

The extension travels as a value inside the descriptor struct. The engine reads
it by field name:

```zig
pub fn requestAdapter(
    dev: *Device,
    io: std.Io,
    alloc: std.mem.Allocator,
    options: RequestAdapterOptionsChain,
) (ValidationError || UnrecoverableError)!Adapter {
    if (options.webxr_options) |webxr| {
        // The engine's own XR path, or error.WebgpuOnlyBackend.
    }
    // ...
}
```

That reads as an `if (options.x) |x|` on a nullable, not as a chain traversal.
It also makes an impossible chain unrepresentable: two copies of the same
extension cannot be expressed, where Dawn's `UnpackedPtr` doc comment at
`src/dawn/native/ChainUtils.h:65-67` has to say "If the same structure is
duplicated in the chain, it is unspecified which one the result of Get will be."

**Duplicate detection is free.** Because there is one slot per extension, the
duplicate case cannot be written. Dawn needs a bitset
(`src/dawn/native/ChainUtils.h:98`) to remember which slots were filled.

**Exhaustive by construction.** The generator emits a member per chained struct.
A new chained struct in `dawn.json` is a new member, and the engine body that
does not read it is a compile error only if it is required to. To make it a
hard requirement, the generator emits a `switch` over an enumeration of present
extensions:

```zig
// GENERATED, from the same 88 entries
pub fn forEachPresent(
    chain: RequestAdapterOptionsChain,
    comptime Context: type,
    context: Context,
    webxr_callback: *const fn (Context, WebXrOptions) void,
    backend_callback: *const fn (Context, WebGpuBackendOptions) void,
) void {
    if (chain.webxr_options) |value| webxr_callback(context, value);
    if (chain.webgpu_backend_options) |value| backend_callback(context, value);
}
```

Adding a chained struct adds a parameter. A call site that does not name it
fails to compile. That is the same property Dawn gets from a hand-written
`AdditionalExtensions` specialization
(`src/dawn/native/ChainUtilsImpl.inl:101-107`) and loses when a back end forgets
one.

**Out-chain structures.** The 11 `"out"` roots get a different shape, because
the engine fills them. `src/dawn/dawn.json:2773-2779` shows `instance limits` as
`"extensible": "out"` with one member. The port's version is a struct the engine
returns:

```zig
// GENERATED
pub const InstanceLimits = struct {
    timed_wait_any_max_count: usize = 0,
};

pub fn getLimits(instance: Instance, out: *InstanceLimits) void {
    out.* = .{ .timed_wait_any_max_count = 64 };
}
```

`InstanceLimits` stays mutable rather than becoming a chain of `?T`, because the
engine writes it and the caller reads it. A chain of optionals in the output
direction would only add a null check on the read side.

**Not byte-compatible, on purpose.** Dawn's `nextInChain` is a real pointer
(`generator/templates/api.h:128`). The port's chain has no pointer, so
`dusk`'s descriptors do not have Dawn's layout. The Zig package is the ABI
(`docs/02-dawn-design.md` §7); a C ABI is a later milestone with its own
generated header. `AGENTS.md` §6 forbids a shim, so there is no compatibility
struct.

### 4.3 The decision record

**Priority.** Correctness of the public surface first, then the cost to a
consumer.

**Constraint.** `AGENTS.md` §3: "Comptime exhaustiveness is the strongest
coverage substitute Zig has." `docs/02-dawn-design.md` §6 lists
`UnpackedPtr<T>` as one of the C++ facilities that force a decision.

**Cost imposed on consumers.**

- A consumer cannot build a chain dynamically. Dawn can assemble a chain in a
  loop; the port's chain is a struct literal. A caller that must select among
  many extension combinations writes a switch over its own cases, which is more
  code than a loop.
- A consumer that wants to forward an unknown extension through the port has
  nowhere to put it. Dawn's `next` pointer is extensible by third parties
  without a port change; `dusk`'s is not. This is the strongest argument for
  Dawn's design and it is a real loss.
- Descriptors are larger: `RequestAdapterOptionsChain` carries one byte of
  discriminant per extension inline. Dawn's chain is out of line. For 88
  chained structs across 11 roots the average is small, but a root with many
  extensions pays.

**Counterchoice.** A hand-rolled `next_in_chain` over the port's own tagged
union, keeping Dawn's shape:

```zig
pub const Chain = extern union {
    base: Base,
    webxr: WebXrOptions,
};

pub const ChainedStruct = extern struct {
    next: ?*ChainedStruct,
    s_type: SType,
};
```

This genuinely wins in one setting: the third-party extension case above. A
consumer that has an extension the port has never heard of can append it to the
list and have it reach the engine untouched. It also wins when the chain must
cross a process or a language boundary, because a pointer chain is the only
representation both understand. It is what the port would have to build if the
C ABI milestone needed Dawn-compatible descriptors.

`dusk` does not build it because a pointer chain cannot be type-checked, and
because the WebGPU spec does not require forwarding an extension the
implementation does not recognise.

**Grade and origin.** Settled. `AGENTS.md` §3 (comptime exhaustiveness),
§6 (no shim); `docs/02-dawn-design.md` §2 (the counts above) and §6. Upstream
evidence: `src/dawn/native/ChainUtils.h:90`, `:97-98`, `:112-120`,
`src/dawn/native/ChainUtilsImpl.inl:60-63`, `generator/templates/api.h:300-303`.

---

## 5. The `VkResult` problem

### 5.1 The observation

`zig translate-c` maps `VkResult` to `c_int`. This was observed, not assumed.
`vulkan.zig` generated from the pinned `vulkan_core.h`
(Vulkan-Headers v1.4.365, `VK_HEADER_VERSION 365`, commit
`8249cb829eb402c65cb7e3778c51b0f8edc4a4b6`) contains, at line 920 and 921:

```zig
pub const enum_VkResult = c_int;
pub const VkResult = enum_VkResult;
```

The constants are `pub const`, not enum fields. `VK_SUCCESS` is `c_int = 0` at
line 858, `VK_NOT_READY` is `c_int = 1` at 859, `VK_ERROR_OUT_OF_HOST_MEMORY`
is `c_int = -1` at 864, `VK_ERROR_DEVICE_LOST` is `c_int = -4` at 867,
`VK_ERROR_VALIDATION_FAILED` is `c_int = -1000011001` at 877,
`VK_PIPELINE_COMPILE_REQUIRED` is `c_int = 1000297000` at 882, and
`VK_RESULT_MAX_ENUM` is `c_int = 2147483647` at 919.

`VkStructureType` is the same shape: `pub const enum_VkStructureType = c_uint;`
at line 2420. Every Vulkan enum is a bare integer alias. The generated header
gives 4,490 `pub const VK_*: c_int` declarations.

This is a deliberate difference from the enum types in the header, and it is
worth stating why it matters here. An integer alias means the compiler cannot
tell a `VkResult` from a `VkStructureType` from a `VkFormat` at the type
level, and it means an out-of-range value from a driver is not a compile-time
problem.

### 5.2 The mapping

The mapping lives in `src/vk.zig` and nowhere else. `AGENTS.md` §3.1 states
this.

**Step 1: split by meaning, not by sign.** Vulkan result codes do not split
cleanly on sign. `VK_NOT_READY` (1) and `VK_TIMEOUT` (2) are positive and are
not successes. `VK_SUBOPTIMAL_KHR` (1000001003) and
`VK_PIPELINE_COMPILE_REQUIRED` (1000297000) are positive and mean "it worked,
but look again". The port classifies by meaning:

```zig
// src/vk/result.zig
pub const Outcome = union(enum) {
    success,
    incomplete,          // VK_INCOMPLETE: more items remain, call again
    not_ready,           // VK_NOT_READY
    timeout,             // VK_TIMEOUT
    event_set,           // VK_EVENT_SET
    event_reset,         // VK_EVENT_RESET
    suboptimal,          // VK_SUBOPTIMAL_KHR: swapchain needs recreation
    pipeline_compile_required, // VK_PIPELINE_COMPILE_REQUIRED
    error: Error,
};

pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    Unknown,
    SurfaceLost,
    NativeWindowInUse,
    OutOfDate,
    ValidationFailed,
    UnknownResult,
};
```

`Incomplete`, `NotReady`, `Timeout`, `EventSet`, `EventReset`, `Suboptimal` and
`PipelineCompileRequired` have **no error meaning**. They are values the caller
must branch on. `Incomplete` in particular is not a failure: it is how
`vkGetPhysicalDeviceMemoryProperties` says "your buffer was too small, call
again". Mapping it to an error would make a correct call look like a bug.

**Step 2: the mapping function.**

```zig
// src/vk/result.zig
pub fn classify(code: vulkan.VkResult) Outcome {
    return switch (code) {
        vulkan.VK_SUCCESS => .success,
        vulkan.VK_INCOMPLETE => .incomplete,
        vulkan.VK_NOT_READY => .not_ready,
        vulkan.VK_TIMEOUT => .timeout,
        vulkan.VK_EVENT_SET => .event_set,
        vulkan.VK_EVENT_RESET => .event_reset,
        vulkan.VK_SUBOPTIMAL_KHR => .suboptimal,
        vulkan.VK_PIPELINE_COMPILE_REQUIRED => .pipeline_compile_required,

        vulkan.VK_ERROR_OUT_OF_HOST_MEMORY => .{ .error = .OutOfHostMemory },
        vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY => .{ .error = .OutOfDeviceMemory },
        vulkan.VK_ERROR_INITIALIZATION_FAILED => .{ .error = .InitializationFailed },
        vulkan.VK_ERROR_DEVICE_LOST => .{ .error = .DeviceLost },
        vulkan.VK_ERROR_MEMORY_MAP_FAILED => .{ .error = .MemoryMapFailed },
        vulkan.VK_ERROR_LAYER_NOT_PRESENT => .{ .error = .LayerNotPresent },
        vulkan.VK_ERROR_EXTENSION_NOT_PRESENT => .{ .error = .ExtensionNotPresent },
        vulkan.VK_ERROR_FEATURE_NOT_PRESENT => .{ .error = .FeatureNotPresent },
        vulkan.VK_ERROR_INCOMPATIBLE_DRIVER => .{ .error = .IncompatibleDriver },
        vulkan.VK_ERROR_TOO_MANY_OBJECTS => .{ .error = .TooManyObjects },
        vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED => .{ .error = .FormatNotSupported },
        vulkan.VK_ERROR_FRAGMENTED_POOL => .{ .error = .FragmentedPool },
        vulkan.VK_ERROR_UNKNOWN => .{ .error = .Unknown },
        vulkan.VK_ERROR_SURFACE_LOST_KHR => .{ .error = .SurfaceLost },
        vulkan.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => .{ .error = .NativeWindowInUse },
        vulkan.VK_ERROR_OUT_OF_DATE_KHR => .{ .error = .OutOfDate },
        vulkan.VK_ERROR_VALIDATION_FAILED => .{ .error = .ValidationFailed },

        // Extension results Dawn never names but a driver may return. Grouped,
        // because the port acts on none of them individually.
        vulkan.VK_ERROR_FRAGMENTATION,
        vulkan.VK_ERROR_NOT_PERMITTED,
        vulkan.VK_ERROR_COMPRESSION_EXHAUSTED,
        vulkan.VK_ERROR_INVALID_EXTERNAL_HANDLE,
        vulkan.VK_ERROR_OUT_OF_POOL_MEMORY,
        vulkan.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS,
        vulkan.VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT,
        => .{ .error = .Unknown },

        else => .{ .error = .UnknownResult },
    };
}
```

The `else` arm is not laziness. A driver may return a result code from a newer
extension than the pinned headers, and `VkResult` is a `c_int`, so the compiler
cannot reject it. `UnknownResult` carries the numeric code forward (§5.3).

**Step 3: the checked wrapper.**

```zig
// src/vk/result.zig
pub fn check(code: vulkan.VkResult, comptime context: []const u8) Error!void {
    switch (classify(code)) {
        .success => {},
        .incomplete => |_| {},  // not reached; use `query` for enumerations
        .error => |err| return err,
        else => |other| {
            // A non-error, non-success outcome at a site that expects success
            // is a real defect, so it is named rather than swallowed.
            std.log.scoped(.vk).warn("unexpected VkResult outcome {s} at {s}", .{
                @tagName(other), context,
            });
            return error.UnexpectedOutcome;
        },
    }
}
```

`check` takes the context as a `comptime` string, so the diagnostic costs
nothing at runtime. `AGENTS.md` §2 forbids discarding an error with `_ =`, and
this is where that rule bites: `VK_SUBOPTIMAL_KHR` on a
`vkQueuePresent` is normal and must not become an error, while
`VK_SUBOPTIMAL_KHR` on a `vkCreateBuffer` is a defect. `check` cannot tell them
apart from the code, so the caller picks the right wrapper at each site.

**The enumerating wrapper**, for the two-result protocols:

```zig
pub fn query(
    code: vulkan.VkResult,
    comptime context: []const u8,
    out_count: *u32,
) Error!bool {
    _ = context;
    switch (classify(code)) {
        .success => return true,
        .incomplete => return false,  // out_count already holds the written count
        .error => |err| return err,
        else => return error.UnexpectedOutcome,
    }
}
```

### 5.3 The original code survives

`code` is a `c_int` and the mapping is a `switch` over constants, so the
numeric value is available at every call site without storing it. The port
keeps it in the error message by formatting at the boundary:

```zig
// src/vk/result.zig
pub fn name(code: vulkan.VkResult) []const u8 {
    return switch (code) {
        vulkan.VK_SUCCESS => "VK_SUCCESS",
        vulkan.VK_NOT_READY => "VK_NOT_READY",
        // ...
        else => "VkResult(unmapped)",
    };
}
```

Dawn does the same thing with a hand-written `switch` and a `std::stringstream`
fallback (`src/dawn/native/vulkan/VulkanError.cpp:34-93`, with
`"<Unknown VkResult: " << code << ">"` at `:89-90`). The port produces the same
information without a heap allocation: `name` returns a `[]const u8` pointing
into the generated file's string data, and the numeric code is formatted by the
caller:

```zig
const outcome = vk.classify(code);
if (outcome == .error) {
    std.log.scoped(.vk).warn("{s} returned {s} ({d})", .{
        context, vk.name(code), @as(i32, @intCast(code)),
    });
}
```

The numeric value is preserved because a driver returning an unmapped code is
the case where the number matters and the name does not exist.

Dawn's two fake codes for tests become port constants, not Vulkan values:
`VK_FAKE_ERROR_FOR_TESTING = VK_RESULT_MAX_ENUM` and
`VK_FAKE_DEVICE_OOM_FOR_TESTING = VK_RESULT_MAX_ENUM - 1` at
`src/dawn/native/vulkan/VulkanError.h:36-37`. The port keeps them in `core`,
not in `vk`, because they are not Vulkan results:

```zig
// src/core/fault_injection.zig
pub const injected_result: i32 = @intCast(vulkan.VK_RESULT_MAX_ENUM);
pub const injected_oom_result: i32 = @intCast(vulkan.VK_RESULT_MAX_ENUM) - 1;
```

### 5.4 Relationship to the three error sets

`vk.Error` is not one of §2's three sets. It is the Vulkan-level code, and the
engine translates it:

```zig
// src/engine/device.zig
pub fn translate(err: vk.Error) UnrecoverableError!void {
    return switch (err) {
        error.DeviceLost => error.DeviceLost,
        error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.ValidationFailed => error.InternalInvariantViolated,
        else => error.InternalInvariantViolated,
    };
}
```

Dawn does this translation at
`src/dawn/native/vulkan/VulkanError.cpp:96-107`, where `VK_ERROR_DEVICE_LOST`
becomes `DAWN_BACKEND_DEVICE_LOST_ERROR` and everything else becomes
`DAWN_UNRECOVERABLE_ERROR`. The port splits it further, because
`VK_ERROR_OUT_OF_HOST_MEMORY` and `VK_ERROR_OUT_OF_DEVICE_MEMORY` are
distinguishable and mean different things to a consumer retrying allocation.

Dawn's `CheckVkOOMThenSuccess` at
`src/dawn/native/vulkan/VulkanError.cpp:109-121` treats the two memory codes and
the fake OOM code as out-of-memory and everything else as unrecoverable. The
port's `classify` separates them first and `translate` regroups them, so the
translation is explicit rather than folded into the string builder.

### 5.5 The decision record

**Priority.** Correctness at an ABI boundary. A wrong code here is a wrong
memory decision.

**Constraint.** `AGENTS.md` §3.1: "`VkResult` is `c_int`, not a Zig enum. The
mapping to a Zig error set lives in `src/vk.zig` and nowhere else." Observed at
`vulkan.zig:920-921`.

**Cost imposed on consumers.**

- An error crossing the `vk` boundary loses its original number unless the
  caller formats it. `vk.Error` has no payload, so a consumer that must recover
  the numeric code reads `vulkan.VkResult` directly.
- `classify` returns a union, not an error set, so a call site must destructure
  it. `check` hides that but also hides the distinction between
  `incomplete` and `success`, which is why `query` exists as a second entry
  point.
- The switch must be extended when the pinned headers gain a result code. That
  is a compile-time obligation, which is the point.

**Counterchoice.** A Zig enum mirroring `VkResult`, generated by
`tools/gen_dispatch.zig` rather than by `translate-c`, with a non-exhaustive
tag:

```zig
pub const VkResult = enum(c_int) {
    success = 0,
    not_ready = 1,
    error_out_of_host_memory = -1,
    // ... every code the headers define
    _, // drivers return codes from newer extensions
};
```

This genuinely wins in one setting: a consumer that wants to write an exhaustive
`switch` over results, or hand a result to `std.fmt` and get a readable name.
`@tagName` on a non-exhaustive enum field prints `error_out_of_host_memory`,
which is more legible than `"VK_ERROR_OUT_OF_HOST_MEMORY"` looked up in a
function. It also catches a typo at the call site: `@intFromEnum(code)` on a
typo is a compile error, while `classify(vulkan.VK_SUCESS)` on a typo is a
compile error too, but `@intFromEnum` on a hand-written wrong mapping is not.

`dusk` does not generate one because `translate-c` already owns `vulkan.zig`
and `AGENTS.md` §3.1 says never hand-edit it; a second definition of the same
enum in `vk.zig` is a second source of truth for the same numbers.

**Grade and origin.** Settled. `AGENTS.md` §3.1; `docs/20-dependencies.md`
"Vulkan bindings"; observation at `vulkan.zig:920-921` in the probe output.
Upstream evidence for the classification: `src/dawn/native/vulkan/VulkanError.cpp:34-121`.

---

## 6. The dispatch layer

### 6.1 The shape

Dawn hand-rolls a three-tier function-pointer struct. `VulkanFunctions` at
`src/dawn/native/vulkan/VulkanFunctions.h:70` declares the four load functions
at `:71-79` and then 221 `VkFn<PFN_vk*>` members. `LoadGlobalProcs` is at
`src/dawn/native/vulkan/VulkanFunctions.cpp:91`, `LoadInstanceProcs` at `:120`,
`LoadDeviceProcs` at `:262`, and `TryLoadEXTDebugUtils` at `:219`.

The tiers and their counts, counted from the macro *call sites* in that file:

| Tier | Loaded by | Procs |
| --- | --- | ---: |
| global | `GetInstanceProcAddr(nullptr, …)` | 3 required + 1 optional |
| instance | `GetInstanceProcAddr(instance, …)` | 41 required + 12 optional |
| device | `GetDeviceProcAddr(device, …)` | 164 required |

The macro row is not a proc. `GET_INSTANCE_PROC` is *defined* at
`VulkanFunctions.cpp:117`, `GET_INSTANCE_PROC_NO_ERROR` at `:118` and
`GET_DEVICE_PROC` at `:254`; a count that takes the `#define` line with the
call sites reports one more member than the tier has.

`LoadGlobalProcs` loads three procs through the hard-error `GET_GLOBAL_PROC`
macro and allows `vkEnumerateInstanceVersion` to be null because it does not
exist on Vulkan 1.0 (`src/dawn/native/vulkan/VulkanFunctions.cpp:96-102`).
`vkDestroyInstance` is loaded in the *instance* tier first
(`src/dawn/native/vulkan/VulkanFunctions.cpp:127`) but lives in the global
struct (`src/dawn/native/vulkan/VulkanFunctions.h:91`), because the loader needs
it to clean up after a failed instance creation.

A missing global proc is a hard `DAWN_UNRECOVERABLE_ERROR`
(`src/dawn/native/vulkan/VulkanFunctions.cpp:86-89`). A missing instance proc is
a hard error under `GET_INSTANCE_PROC` (`:109-115`) and tolerated under
`GET_INSTANCE_PROC_NO_ERROR` (`:107-108`). A missing device proc is a hard
error under `GET_DEVICE_PROC` (`:254-260`); device procs are only *attempted*
when the extension is enabled (`if (deviceInfo.HasExt(DeviceExt::Swapchain))`
at `:446`, and 11 such blocks between `:405` and `:467`).

### 6.2 The port

```zig
// src/vk/dispatch.zig
pub const Dispatch = struct {
    global: GlobalProcs,
    instance: InstanceProcs,
    device: DeviceProcs,
};

pub const GlobalProcs = struct {
    get_instance_proc_addr: ?vulkan.PFN_vkGetInstanceProcAddr,
    create_instance: ?vulkan.PFN_vkCreateInstance,
    enumerate_instance_extension_properties: ?vulkan.PFN_vkEnumerateInstanceExtensionProperties,
    enumerate_instance_layer_properties: ?vulkan.PFN_vkEnumerateInstanceLayerProperties,
    destroy_instance: ?vulkan.PFN_vkDestroyInstance,
    enumerate_instance_version: ?vulkan.PFN_vkEnumerateInstanceVersion,
};

pub const InstanceProcs = struct {
    create_device: ?vulkan.PFN_vkCreateDevice,
    enumerate_device_extension_properties: ?vulkan.PFN_vkEnumerateDeviceExtensionProperties,
    // ... 41 required, 12 optional
    get_physical_device_cooperative_matrix_properties_khr: ?vulkan.PFN_vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR,
};

pub const DeviceProcs = struct {
    create_buffer: ?vulkan.PFN_vkCreateBuffer,
    destroy_buffer: ?vulkan.PFN_vkDestroyBuffer,
    // ... 164 members
};
```

Every field is optional (`?PFN_vk*`), because a `PFN_vk*` is itself
`?*const fn …` in the generated bindings — `vulkan.zig:5065` shows
`pub const PFN_vkCreateInstance = ?*const fn (…) callconv(.c) VkResult;`. A
double optional would be redundant, so the port uses a single one and states
that a `null` field means "not loaded".

**The three load functions.** Each returns an error set that says which tier
failed:

```zig
// src/vk/dispatch.zig
pub const LoadError = error{
    LibraryNotFound,
    MissingGlobalProc,
    MissingInstanceProc,
    MissingDeviceProc,
    VulkanVersionTooOld,
};

pub fn loadGlobalProcs(lib: *std.DynLib) LoadError!*GlobalProcs { ... }
pub fn loadInstanceProcs(
    lib: *std.DynLib,
    get_instance_proc_addr: vulkan.PFN_vkGetInstanceProcAddr,
    instance: vulkan.VkInstance,
    info: *const InstanceInfo,
) LoadError!*InstanceProcs { ... }
pub fn loadDeviceProcs(
    get_device_proc_addr: vulkan.PFN_vkGetDeviceProcAddr,
    device: vulkan.VkDevice,
    info: *const DeviceInfo,
) LoadError!*DeviceProcs { ... }
```

Three error members, not one, because the call site must react differently: a
missing global proc means the loader is broken and the process should stop; a
missing device proc for an extension the caller asked for means the caller
asked for something wrong. Dawn encodes the same distinction in the macro
choice (`GET_INSTANCE_PROC` versus `GET_INSTANCE_PROC_NO_ERROR`) and loses the
distinction in the returned error, because both become
`DAWN_UNRECOVERABLE_ERROR` with a formatted message
(`src/dawn/native/vulkan/VulkanFunctions.cpp:113`).

**The lookup helper.**

```zig
fn loadGlobal(
    lib: *std.DynLib,
    comptime name: [:0]const u8,
    comptime T: type,
    out: *?T,
) LoadError!void {
    out.* = lib.lookup(T, name) orelse return error.MissingGlobalProc;
}

fn loadInstanceRequired(
    get_proc_addr: vulkan.PFN_vkGetInstanceProcAddr,
    instance: vulkan.VkInstance,
    comptime name: [:0]const u8,
    comptime T: type,
    out: *?T,
) LoadError!void {
    out.* = @ptrCast(get_proc_addr.?(instance, name.ptr)) orelse
        return error.MissingInstanceProc;
}

fn loadInstanceOptional(
    get_proc_addr: vulkan.PFN_vkGetInstanceProcAddr,
    instance: vulkan.VkInstance,
    comptime name: [:0]const u8,
    comptime T: type,
    out: *?T,
) void {
    out.* = @ptrCast(get_proc_addr.?(instance, name.ptr));
}
```

`loadInstanceOptional` returns `void` and cannot fail. That is the
tolerated-missing rule, and it is a *type* difference, not a runtime branch.
Dawn's `GET_INSTANCE_PROC_NO_ERROR` is a macro whose two bodies differ in
whether they return an error
(`src/dawn/native/vulkan/VulkanFunctions.cpp:107-108` versus `:109-115`); the
port's two functions differ in return type.

For the device tier the tolerated-missing rule is different: Dawn only attempts
a device proc when its extension is enabled
(`src/dawn/native/vulkan/VulkanFunctions.cpp:446-452`), so a missing device proc
is always a real failure. The port makes the enablement a parameter so the
attempt itself is conditional:

```zig
pub fn loadDeviceProcs(
    get_device_proc_addr: vulkan.PFN_vkGetDeviceProcAddr,
    device: vulkan.VkDevice,
    info: *const DeviceInfo,
) LoadError!*DeviceProcs {
    const procs = try info.allocator.create(DeviceProcs);
    errdefer info.allocator.destroy(procs);

    loadDeviceRequired(get_device_proc_addr, device, "vkCreateBuffer", &procs.CreateBuffer) catch
        return error.MissingDeviceProc;
    // ... 164 required

    if (info.has_extension(.swapchain)) {
        loadDeviceRequired(get_device_proc_addr, device, "vkCreateSwapchainKHR", &procs.CreateSwapchainKHR) catch
            return error.MissingDeviceProc;
        // ... 5 more
    }
    return procs;
}
```

**Every entry point is reached through the table.** `AGENTS.md` §3.1: "Every
Vulkan entry point is reached through the dispatch table in `src/vk.zig`, never
called directly from `vulkan.zig`. A direct call is a review finding." The
call sites therefore look like:

```zig
// src/engine/buffer.zig
const code = dispatch.device.?.create_buffer.?(device, &create_info, null, &vk_buffer);
vk.check(code, "vkCreateBuffer") catch |err| return translate(err);
```

Note `.?.CreateBuffer.?`: the first `?.` unwraps the optional
`Dispatch.device` pointer, the second unwraps the optional function pointer. A
missing proc is an `error.UnexpectedOutcome` at the call site rather than a
null-pointer dereference, and the `catch` forces the site to name what it does
with the failure, per `AGENTS.md` §2.

`src/vulkan.zig` is generated and checked in so a consumer needs no C
toolchain; `build.zig` regenerates it when the pinned commit changes
(`docs/10-architecture.md`).

### 6.3 The decision record

**Priority.** Correctness, then the loader tier's integrity.

**Constraint.** `AGENTS.md` §3.1. `docs/20-dependencies.md` "Dispatch":
Dawn does not use volk — `grep -rn 'volk' --include=CMakeLists.txt .` in Dawn
returns nothing — and the port does the same with `std.DynLib`
(`lib/std/dynamic_library.zig:14`, `open` at `:32`, `lookup` at `:54`).

**Cost imposed on consumers.**

- `Dispatch` is a large struct. 221 optional function pointers is 1,768 bytes,
  allocated once per device. Dawn's is a member of
  `VulkanInstance` and a `Ref` shared across devices
  (`src/dawn/native/vulkan/VulkanFunctions.h:70`); the port's is per-device
  because the device tier differs per device.
- The double-optional call syntax `.?.CreateBuffer.?` is noisier than Dawn's
  `device->fn.CreateBuffer(...)`. There is no way to remove it without
  asserting non-null at load time, which would lose the distinction between
  "not loaded" and "loaded as null".
- A consumer writing its own Vulkan code against `dusk` cannot call
  `vulkan.vkCreateBuffer` directly without a review finding.

**Counterchoice.** `translate-c` with `-fno-builtin` and the loader's own
dispatch, or a `pub usingnamespace vulkan` that re-exports every function
pointer already bound. That genuinely wins in one setting: source-level
fidelity. Call sites read exactly as they do in C, `vulkan.zkCreateBuffer(...)`
compiles, and a reviewer diffing against upstream sees the same call. It also
wins when the port needs an entry point Dawn does not load — the re-export is
already there.

`dusk` does not do it because a direct call bypasses the loader tier, so a
missing proc becomes a null dereference deep in the engine instead of a named
error at load time, and because the "tolerated missing" rule becomes a runtime
`if` at every call site instead of a difference in return type.

**Grade and origin.** Settled. `AGENTS.md` §3.1; `docs/20-dependencies.md`
"Dispatch"; `docs/10-architecture.md` module table (`vk` owns "the three-tier
dispatch table, `VkResult` to Zig error mapping" and "never call a Vulkan entry
point directly"). Upstream evidence: `src/dawn/native/vulkan/VulkanFunctions.h:69-78`,
`src/dawn/native/vulkan/VulkanFunctions.cpp:86-89`, `:107-118`, `:254-260`.

---

## 7. Containers

Dawn's `common/` holds the container families. `docs/02-dawn-design.md` §4.11
lists them; the sizes below are `wc -l`.

| Dawn type | Lines | Zig replacement | Module | Why |
| --- | ---: | --- | --- | --- |
| `std::vector`, `absl::flat_hash_map` | — | `std.ArrayList(T)` | stdlib | 0.16.0 made `ArrayList` allocator-bound by construction: `pub fn ArrayList(comptime T: type) type` at `lib/std/std.zig:49`, with `init(gpa)` at `lib/std/array_list.zig:44` and `deinit(self)` at `:62`. No unmanaged variant to choose between. |
| `std::map<Serial, std::vector<Value>>` | — | `std.AutoHashMap(Serial, ArrayList(Value))` | stdlib | `AutoHashMap` at `lib/std/std.zig:1`, `getOrPut` at `lib/std/hash_map.zig:261`. |
| `std::string`-keyed map | — | `std.StringHashMap(V)` | stdlib | `lib/std/std.zig:28`. Replaces the five `WGPUStringView` helpers in `src/dawn/common/StringViewUtils.h` (59 lines), per `docs/02-dawn-design.md` §4.11. |
| insertion-ordered map | — | `std.ArrayHashMapUnmanaged(K, V)` | stdlib | `lib/std/std.zig:37`. For the few places Dawn uses `absl::btree_map` (`src/dawn/native/EventManager.h:94`). |
| `LinkedList<T>` (`common/LinkedList.h`, 268) | 268 | `std.SinglyLinkedList` / `std.DoublyLinkedList` | stdlib | `lib/std/std.zig:26` and `:10`. `ApiObjectBase` is a `LinkNode` (`src/dawn/native/ObjectBase.h:147`), which the arena model removes entirely (§1). |
| `MutexProtected<T>` (`common/MutexProtected.h`, 450) | 450 | `std.Io.Mutex` + explicit lock | stdlib | 0.16.0 has no `std.Thread.Mutex`. `std.Io.Mutex` is at `lib/std/Io.zig:1587`, with `lock(io)` at `:1602` and `unlock(io)` at `:1641`. It takes `io` because it is a cancelation point. |
| `MutexCondVarProtected<T>` (`common/MutexProtected.h:395`) | 450 | `std.Io.Condition` | stdlib | `lib/std/Io.zig:1653`, `wait(io, mutex)` at `:1668`. |
| `SlabAllocator<T>` (`common/SlabAllocator.h`, 222) | 222 | `src/core/Slab.zig` — port | port | Needs an index-encoded free list; the stdlib has no slab. |
| `SerialMap<Serial, Value>` (`common/SerialMap.h`, 115) | 115 | `src/core/SerialMap.zig` — port | port | Serials arrive out of order. |
| `SerialQueue<Serial, Value>` (`common/SerialQueue.h`, 103) | 103 | `src/core/SerialQueue.zig` — port | port | Serials arrive in order; needs contiguous storage. |
| `LRUCache<K, V>` (`common/LRUCache.h`, 170) | 170 | `src/core/LruCache.zig` — port | port | Needs eviction order; the stdlib has none. |
| `MemoryBlockAllocator` (`common/MemoryBlockAllocator.h`, 105) | 105 | `src/core/BlockPool.zig` — port | port | Fixed-size block recycling with a tick-evicted retention window. |
| `absl::flat_hash_map` inside `MutexProtected` | — | one `std.Io.Mutex` plus the map | stdlib | `src/dawn/native/vulkan/PipelineLayoutVk.h:91` combines both. |

`docs/20-dependencies.md` says every dependency is taken at the first rung
that works, and the standard library covers every row marked stdlib. The five
ported types have no rung-1 equivalent, which is why they are ports and not
`build.zig.zon` entries.

### 7.1 `SlabAllocator`

Dawn's `SlabAllocator` allocates fixed-size objects out of contiguous slabs,
holding slabs in three linked lists — AVAILABLE, FULL, RECYCLED — and storing
each block's own index plus the next free index inside the block
(`src/dawn/common/SlabAllocator.h:47-70`). Its only user in the Vulkan back end
is the bind group allocator
(`src/dawn/native/vulkan/BindGroupLayoutVk.h:111`, with `AllocateBindGroup` at
`src/dawn/native/vulkan/BindGroupLayoutVk.cpp:336` and `DeleteEmptySlabs` at
`:354`).

The port needs the property, not the three-list machinery. An arena over a
fixed-size block gives the same allocation speed for the one live user, because
a bind group outlives its allocation slot anyway and reclamation is by serial,
not by free:

```zig
// src/core/Slab.zig
pub fn Slab(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        items: std.ArrayList(*T),
        bytes_per_item: usize,
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, bytes_per_item: usize) Allocator.Error!Self {
            return .{
                .arena = .init(alloc),
                .items = .empty,
                .bytes_per_item = bytes_per_item,
                .alloc = alloc,
            };
        }

        pub fn create(self: *Self) Allocator.Error!*T {
            const bytes = try self.alloc.alloc(u8, self.bytes_per_item);
            errdefer self.alloc.free(bytes);
            const item: *T = @ptrCast(@alignCast(bytes));
            item.* = undefined;
            try self.items.append(item);
            return item;
        }

        pub fn deinit(self: *Self) void {
            for (self.items.items) |item| {
                self.alloc.free(@as([*]u8, @ptrCast(item))[0..self.bytes_per_item]);
            }
            self.items.deinit();
            self.arena.deinit();
        }
    };
}
```

`create` is two allocations where Dawn's is amortised zero. That is a real cost
and it is not hidden: `docs/50-verification.md` owns any future measurement.
The win is that `Slab` has no free-list invariants, so there is no index to
corrupt and no allocator-specific code to fuzz. Dawn's index-encoded free list
is the kind of code `AGENTS.md` §3 makes a review finding when it cannot be
driven deterministically.

### 7.2 `SerialQueue` and `SerialMap`

Dawn's `SerialStorage` is the shared base. `ClearUpTo` is declared at
`src/dawn/common/SerialStorage.h:125` and defined at `:171`. `SerialQueue`
(`src/dawn/common/SerialQueue.h:55-63`) requires non-decreasing serials and
stores them contiguously as `std::vector<SerialPair>`
(`src/dawn/common/SerialQueue.h:41-48`). `SerialMap`
(`src/dawn/common/SerialMap.h:56-64`) allows arbitrary order and stores
`std::map<Serial, std::vector<Value>>` (`src/dawn/common/SerialMap.h:46`).

Both are used for serial reclamation. `FencedDeleter` holds one `SerialQueue`
per Vulkan handle type via an X-macro
(`src/dawn/native/vulkan/FencedDeleter.h:93`, expanded over
`FENCED_DELETER_TYPES`), plus `SerialQueue<ExecutionSerial,
ResourceMemoryAllocation>` at
`src/dawn/native/vulkan/ResourceMemoryAllocatorVk.h:93` and
`SerialQueue<ExecutionSerial, Deallocation>` at
`src/dawn/native/vulkan/DescriptorSetAllocator.h:106`.

The X-macro is a preprocessor pass over a list of handle types. The port
replaces it with a comptime table, which is the same substitution the house
rules make for every other X-macro (`AGENTS.md` §2, "no macro that hides a
branch"):

```zig
// src/engine/reclaim.zig
fn FencedTypes(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            handle: T,
            destroy: *const fn (*engine.Device, T) void,
        };

        queues: std.AutoHashMap(Serial, std.ArrayList(T)),

        pub fn destroyAll(dev: *engine.Device, self: *Self, serial: Serial) void {
            const list = self.queues.fetchRemove(serial) orelse return;
            defer list.value.deinit();
            for (list.value.items) |handle| destroyOne(dev, handle);
        }

        fn destroyOne(dev: *engine.Device, handle: T) void {
            inline for (@typeInfo(T).@"struct".decls) |decl| {
                if (comptime !std.mem.eql(u8, decl.name, "destroy_fn")) continue;
                const destroy_fn = @field(T, decl.name);
                return destroy_fn(dev, handle);
            }
            @compileError("no destroy_fn on " ++ @typeName(T));
        }
    };
}
```

The last two lines are the point. Dawn's `FENCED_DELETER_TYPES` X-macro pairs a
handle with its destroy call
(`src/dawn/native/vulkan/FencedDeleter.h:49-67`), and nothing checks the
pairing. The port's `@compileError` fires when a type has no destroy function,
so a new Vulkan handle cannot be added to the reclamation set without one.

`Serial` is a `u64`. Dawn makes it a typed integer
(`src/dawn/native/IntegerTypes.h:131`: `using ExecutionSerial =
TypedInteger<struct QueueSerialT, uint64_t>;`) and stores two of them, one
condvar-protected and one atomic
(`src/dawn/native/ExecutionQueue.h:192-193`). The port uses `std.atomic.Value(u64)`
for the submitted serial — `lib/std/atomic.zig:9` defines `Value`, with `load`
at `:22`, `store` at `:26`, `swap` at `:30` and `cmpxchgStrong` at `:41` — and
guards the completed serial with a `std.Io.Condition`.

```zig
// src/engine/timeline.zig
pub const Timeline = struct {
    last_submitted: std.atomic.Value(u64) = .init(beginning_of_gpu_time),
    completed: u64 = beginning_of_gpu_time,
    completed_cond: std.Io.Condition = .init,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub const beginning_of_gpu_time: u64 = 0;

    pub fn submit(self: *Timeline) u64 {
        return self.last_submitted.fetchAdd(1, .monotonic);
    }

    pub fn updateCompletedTo(self: *Timeline, serial: u64) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        if (serial > self.completed) self.completed = serial;
        self.completed_cond.signal();
    }
};
```

Dawn's `UpdateCompletedSerialToInternal` — declared at
`src/dawn/native/ExecutionQueue.h:184`, defined at
`src/dawn/native/ExecutionQueue.cpp:272` — does the same thing behind the
`MutexCondVarProtected<uint64_t>` at `ExecutionQueue.h:192`.

### 7.3 `LRUCache`

Dawn's `LRUCache` (`src/dawn/common/LRUCache.h:89`) exposes `GetOrCreate` at
`:95` and a virtual `EvictedFromCache` at `:154`, and wraps the whole thing in
`MutexProtected<Cache>` at `:165`.

The port keeps the two functions and drops the inheritance, because the only
use is the pipeline cache and one eviction action:

```zig
// src/core/LruCache.zig
pub fn LruCache(
    comptime K: type,
    comptime V: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        entries: std.ArrayList(Entry),
        index: std.AutoHashMap(K, usize),

        pub const Entry = struct { key: K, value: V, last_used: u64 };
        clock: u64 = 0,

        pub fn get(self: *Self, key: K) ?V {
            const slot = self.index.get(key) orelse return null;
            self.clock += 1;
            self.entries.items[slot].last_used = self.clock;
            return self.entries.items[slot].value;
        }

        pub fn put(self: *Self, alloc: std.mem.Allocator, key: K, value: V) Allocator.Error!?V {
            self.clock += 1;
            if (self.index.get(key)) |slot| {
                self.entries.items[slot].value = value;
                self.entries.items[slot].last_used = self.clock;
                return null;
            }
            if (self.entries.items.len == capacity) {
                const evicted = self.evictOldest();
                _ = self.index.remove(evicted.key);
                return evicted.value;
            }
            try self.entries.append(.{ .key = key, .value = value, .last_used = self.clock });
            try self.index.put(key, self.entries.items.len - 1);
            return null;
        }

        fn evictOldest(self: *Self) Entry {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |entry, slot| {
                if (entry.last_used < self.entries.items[oldest].last_used) oldest = slot;
            }
            return self.entries.orderedRemove(oldest);
        }
    };
}
```

`evictOldest` is a linear scan over `capacity` entries. Dawn's is a
`std::list` splice, which is O(1). For `capacity` in the low hundreds and a
cache that is touched once per pipeline creation, the difference does not
justify a hand-rolled intrusive list. **This is a performance claim and it is
not measured.** It is a judgement about the size of `capacity`, and
`docs/50-verification.md` owns the measurement if one is ever made.

### 7.4 `MemoryBlockAllocator`

Dawn's `MemoryBlockAllocator`
(`src/dawn/common/MemoryBlockAllocator.h:58-79`) recycles fixed-size blocks,
defaulting to 16,352 bytes at `:63` with a keep-alive window of 60 ticks at
`:66`, and placement-news a `FreeBlock` list node inside each idle block so
recycling needs no separate allocation (`:52-57`).

The port's version is a ring, because the property Dawn needs — a warm block is
reused soon after it is returned — is a ring property:

```zig
// src/core/BlockPool.zig
pub fn BlockPool(comptime block_size: usize, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct { block: ?[]align(std.mem.Alignment.max_align) u8 };

        slots: [capacity]Slot = @splat(.{}),
        next: usize = 0,
        available: usize = 0,

        pub fn init() Self { return .{}; }

        pub fn acquire(self: *Self) ?[]align(std.mem.Alignment.max_align) u8 {
            if (self.available == 0) return null;
            self.available -= 1;
            const block = self.slots[self.next].block orelse return null;
            self.slots[self.next].block = null;
            self.next = (self.next + 1) % capacity;
            return block;
        }

        pub fn release(self: *Self, block: []align(std.mem.Alignment.max_align) u8) void {
            const slot = (self.next + self.available) % capacity;
            self.slots[slot].block = block;
            self.available += 1;
        }
    };
}
```

Capacity is a comptime parameter, so the pool has no allocation of its own and
no allocator to inject. The cost is that it is fixed-size: a request larger than
`block_size` cannot be served. Dawn's own allocator handles that case
explicitly, bypassing the pool for oversized requests
(`src/dawn/common/MemoryBlockAllocator.h:46-47`). The port's caller handles it
instead, because only the staging-buffer path uses this pool and its requests
are bounded by the 4 MiB ring size that
`docs/02-dawn-design.md` §4.4 records for `DynamicUploader`.

### 7.5 The decision record

**Priority.** Correctness and testability of the allocation layer.

**Constraint.** `AGENTS.md` §2: "An allocator is a parameter, never a global";
§3: "Allocator injection and fail-N." `docs/20-dependencies.md` says a
dependency needs a reason the standard library does not cover the slot.

**Cost imposed on consumers.**

- Five ported types are more code than five `translate-c` bindings, and each is
  a place a bug can hide. `Slab.create` is measurably slower than Dawn's
  amortised-free path (§7.1).
- `BlockPool` is fixed-size and fixed-capacity. A caller with a variable request
  size must branch before calling, and a caller that outgrows `capacity` must
  fall back to the allocator.
- `std.Io.Mutex` takes `io`, so `AGENTS.md` §3's no-global-`Io` rule now applies
  to every lock. A lock helper that did not need `io` now does.

**Counterchoice.** A pinned Zig package for the slab and the serial
containers. This genuinely wins in one setting: a container that is already
battle-tested and profiled. `std.ArrayHashMapUnmanaged`
(`lib/std/std.zig:37`) shows the stdlib is willing to grow into this space, and
a maintained slab allocator saves the port from owning index-encoded free-list
code. It also wins for `SerialQueue`, where contiguity is a real performance
property and a general-purpose package's implementation may not match Dawn's.

`dusk` ports them because each one is small (103 to 222 lines upstream) and each
has a property the general-purpose container does not offer: an index-encoded
free list, serial-ordered reclamation, LRU eviction, or block recycling with a
tick window. `docs/20-dependencies.md` requires a reason per dependency, and
"the stdlib has no slab" is that reason for `Slab`.

**Grade and origin.** Settled. `docs/20-dependencies.md` (the ladder);
`AGENTS.md` §2, §3. Upstream evidence: `src/dawn/common/SlabAllocator.h:47-70`,
`src/dawn/common/SerialMap.h:46`, `src/dawn/common/SerialQueue.h:41-48`,
`src/dawn/common/LRUCache.h:89-165`, `src/dawn/common/MemoryBlockAllocator.h:58-79`,
`src/dawn/native/vulkan/FencedDeleter.h:49-93`.

---

## 8. The public API surface

### 8.1 The generator

`src/dawn/dawn.json` is 199,060 bytes of flat JSON and the only source of truth
for the public API (`docs/02-dawn-design.md` §2). Dawn renders it with
`generator/dawn_json_generator.py` (2,272 lines) plus Jinja2 templates under
`generator/templates/`, producing the C header (`api.h`), the C++ header
(`api_cpp.h`, `api_cpp_chained_struct.h`), the proc table (`dawn_proc.cpp`,
`dawn_proc_table.h`), the mock (`mock_api.cpp`, `mock_api.h`) and the emscripten
bindings (`emdawnwebgpu/`).

The port's generator is a Zig program, `tools/gen_api.zig`, and `tools/` holds
nothing else (`docs/10-architecture.md`). It runs through `build.zig`, which
uses `b.addWriteFiles` (`lib/std/Build.zig:1099`) with `WriteFile.add` at
`lib/std/Build/Step/WriteFile.zig:104` to lay the output down.

The JSON is parsed with `std.json.parseFromValueLeaky`
(`lib/std/json/static.zig:177`) against a `std.json.Value`. `dawn.json` is a
flat object of 347 entries, each with a `category`, so the parse target is
`std.json.Value` plus a comptime schema walk rather than a single static type.

The counts, from a Python one-liner over the parsed JSON and confirmed in
`docs/02-dawn-design.md` §2:

| Category | Count |
| --- | ---: |
| structure | 181 |
| enum | 65 |
| object | 28 |
| native | 18 |
| callback function | 14 |
| callback info | 14 |
| constant | 12 |
| bitmask | 6 |
| function | 5 |
| function pointer | 4 |
| **total** | **347** |

205 methods and 571 members, counted as `sum(len(v['methods']))` and
`sum(len(v['members']))`.

**A generated enum.** `buffer usage` is a bitmask at
`src/dawn/dawn.json:811-827`, with values `none = 0`, `map read = 1`,
`map write = 2`, `copy src = 4`, `copy dst = 8`, `index = 16`, `vertex = 32`,
`uniform = 64`, `storage = 128`, `indirect = 256`, `query resolve = 512`,
`texel buffer = 1024`. `load op` is an enum at
`src/dawn/dawn.json:2864-2870` with `undefined = 0`, `load = 1`, `clear = 2`,
`expand resolve texture = 3`.

```zig
// src/api/enums.zig — GENERATED from dawn.json "load op" (src/dawn/dawn.json:2864)
pub const LoadOp = enum(u32) {
    undefined = 0,
    load = 1,
    clear = 2,
    expand_resolve_texture = 3,
};

/// Generated from dawn.json "buffer usage" (src/dawn/dawn.json:811).
pub const BufferUsage = packed struct(u32) {
    map_read: u1 = 0,
    map_write: u1 = 0,
    copy_src: u1 = 0,
    copy_dst: u1 = 0,
    index: u1 = 0,
    vertex: u1 = 0,
    uniform: u1 = 0,
    storage: u1 = 0,
    indirect: u1 = 0,
    query_resolve: u1 = 0,
    texel_buffer: u1 = 0,
    _padding: u21 = 0,

    /// "none" is 0, which is not one bit, so it is a value and not a field.
    pub const none: BufferUsage = .{};
    pub const count = 12;

    pub inline fn toFlags(value: BufferUsage) u32 {
        return @bitCast(value);
    }

    pub inline fn fromFlags(flags: u32) BufferUsage {
        return @bitCast(flags);
    }

    pub fn has(self: BufferUsage, other: BufferUsage) bool {
        return (self.toFlags() & other.toFlags()) == other.toFlags();
    }

    pub inline fn merge(a: BufferUsage, b: BufferUsage) BufferUsage {
        return fromFlags(a.toFlags() | b.toFlags());
    }
};

/// Generated from dawn.json "color write mask" (src/dawn/dawn.json:840).
pub const ColorWriteMask = packed struct(u32) {
    red: u1 = 0,
    green: u1 = 0,
    blue: u1 = 0,
    alpha: u1 = 0,
    _padding: u28 = 0,

    /// 0 and 15 are not one bit, so they are values and not fields.
    pub const none: ColorWriteMask = .{};
    pub const all: ColorWriteMask = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
};
```

A bitmask becomes a `packed struct` whose fields fill the backing integer.
`@bitCast` then round-trips a `u32`, and every flag has a field name.
`packed struct(u32)` holds 32 bits. The 11 `u1` flags of `BufferUsage` hold
11 of them, and `_padding: u21` holds the other 21. The deciding domain is
the `values` list of a `"category": "bitmask"` entry in `dawn.json`. A
value that is one bit becomes a `u1` field, and any other value becomes a
`pub const`, so `none` is a value and not a field. `count` counts the
values, so it is 12 while 11 of them are fields. `color write mask`
(`src/dawn/dawn.json:840`) shows both cases. Its `none = 0`
(`src/dawn/dawn.json:843`) and `all = 15` (`src/dawn/dawn.json:848`) are
values, and its flags `red = 1` to `alpha = 8` (`src/dawn/dawn.json:844-847`)
are fields. The wire value of a flag is the value `dawn.json` gives.
Dawn's equivalent is a
`WGPUBufferUsageFlags` bitmask typedef plus the operators in
`include/webgpu/webgpu_enum_class_bitmasks.h`. The `tags` key matters here:
`texel buffer` carries `"tags": ["dawn"]`
(`src/dawn/dawn.json:825`), so it is a Dawn extension, and the generator emits
it with a doc comment saying so. `texture usage` at
`src/dawn/dawn.json:4511-4522` has the same shape, and its `render attachment`
is 16, not 1 — so a hand-written default of `.copy_src` would be wrong.

**A generated descriptor.** `buffer descriptor` is at
`src/dawn/dawn.json:742-751`:

```json
"buffer descriptor": {
    "category": "structure",
    "extensible": "in",
    "members": [
        {"name": "label", "type": "string view", "optional": true},
        {"name": "usage", "type": "buffer usage"},
        {"name": "size", "type": "uint64_t"},
        {"name": "mapped at creation", "type": "bool", "default": "false"}
    ]
}
```

```zig
// src/api/descriptors.zig — GENERATED
pub const BufferDescriptor = struct {
    /// Dawn extension: none.
    label: ?[]const u8 = null,
    usage: BufferUsage,
    size: u64,
    mapped_at_creation: bool = false,

    /// Every chained struct whose `chain roots` names "buffer descriptor".
    /// Three do, at src/dawn/dawn.json:752, :2408 and :4930. Dawn spells
    /// this `WGPUChainedStruct *nextInChain` (generator/templates/api.h:128);
    /// see docs/30-port-design.md section 4.
    pub const Chain = struct {
        buffer_host_mapped_pointer: ?BufferHostMappedPointer = null,
        dawn_fake_buffer_oom_for_testing: ?DawnFakeBufferOomForTesting = null,
        dawn_buffer_descriptor_error_info_from_wire_client: ?DawnBufferDescriptorErrorInfoFromWireClient = null,
    };
};

/// GENERATED. `optional: true` in dawn.json makes the member a `?T`.
/// A `default` in dawn.json becomes the field's default value.
pub fn validateBufferDescriptor(desc: BufferDescriptor) ValidationError!void {
    if (@sizeOf(u32) > desc.size) return error.BufferSizeTooSmall;
    if (!desc.usage.has(.{ .copy_dst = 1 })) return error.BufferUsageMissingCopyDst;
}
```

The member-name mapping is mechanical: spaces become underscores
(`"mapped at creation"` → `mapped_at_creation`), and each becomes `snake_case`
per `AGENTS.md` §2. The `annotation: "const*"` plus `length` pair in the JSON
becomes a slice:

```zig
// GENERATED from "surface configuration" (src/dawn/dawn.json:486-500)
pub const SurfaceConfiguration = struct {
    device: Device,
    format: TextureFormat,
    usage: TextureUsage = .{ .render_attachment = 16 },
    width: u32,
    height: u32,
    view_format_count: usize = 0,
    view_formats: ?[]const TextureFormat = null,
    alpha_mode: CompositeAlphaMode = .auto,
    present_mode: PresentMode = .fifo,

    pub fn validate(self: SurfaceConfiguration) ValidationError!void {
        const formats = self.view_formats orelse return;
        if (self.view_format_count > formats.len) return error.SliceLengthMismatch;
    }
};
```

The count/length pair (`view format count` and `view formats` at
`src/dawn/dawn.json:495-496`) becomes one check rather than two, because the
count is derivable. `AGENTS.md` §2 forbids two parameters of the same type, so
the pair never becomes two function parameters.

**The proc table.** `proc` is a `function pointer` with no args
(`src/dawn/dawn.json:60-63`) and `get proc address` returns it
(`src/dawn/dawn.json:64-70`). The generator emits:

```zig
// src/api/proc.zig — GENERATED
pub const Proc = *const fn () callconv(.c) void;

pub const ProcTable = struct {
    instance_request_adapter: *const fn (*const RequestAdapterOptions, ...) callconv(.c) Proc,
    device_create_buffer: *const fn (*const BufferDescriptor, ...) callconv(.c) Proc,
    // one entry per method; 205 in total
};
```

Dawn emits the same table as `dawn_proc_table.h`
(`generator/templates/dawn_proc_table.h`).

### 8.2 The comptime exhaustiveness check

`AGENTS.md` §3: "Comptime exhaustiveness is the strongest coverage substitute
Zig has. Run `try comptime testFn();` and an `inline for` over every enumerable
domain. The 347 API objects in `dawn.json` are such a domain, so a new upstream
object must be a compile error until the port handles it."

The generated `handled.zig` makes that a compile error.

```zig
// src/api/handled.zig — GENERATED
/// Every object in dawn.json, by name. Adding an entry to dawn.json adds a
/// member here, and every `switch` over `Object` below fails to compile.
pub const Object = enum {
    adapter,
    bind_group,
    bind_group_layout,
    buffer,
    // ... 28 members
};

/// Port coverage for each object. A `pending` member is a compile error at the
/// point where it is switched on, so a new upstream object cannot be ignored.
pub const Coverage = enum { ported, pending };

pub fn coverage(object: Object) Coverage {
    return switch (object) {
        .adapter => .ported,
        .bind_group => .ported,
        .buffer => .ported,
        // ... one arm per object, each .ported or .pending
    };
}

test "every API object is ported" {
    inline for (@typeInfo(Object).@"enum".fields) |field| {
        const object: Object = @enumFromInt(field.value);
        try std.testing.expectEqual(Coverage.ported, coverage(object));
    }
}

test "every extensible root has a chain struct" {
    inline for (@typeInfo(Object).@"enum".fields) |field| {
        const object: Object = @enumFromInt(field.value);
        // The generated `Chain` for each root lists its extensions; this
        // asserts the generator and the JSON agree on the count.
        try std.testing.expect(extensibleCount(object) == chainMemberCount(object));
    }
}
```

The mechanism has three parts.

1. **`Object` is generated from the JSON.** A new entry in `dawn.json` adds an
   enum member.
2. **`coverage` has no `else`.** A new member is a compile error in the
   generator's own output until someone writes the arm. The error names the
   member, so it is a to-do list that cannot be ignored.
3. **`test "every API object is ported"` sweeps the domain.** Even if someone
   adds a `.pending` arm to make the switch compile, the `inline for` over
   `@typeInfo(Object).@"enum".fields` fails at comptime. `@typeInfo` for an enum
   has `fields: []const EnumField` at `lib/std/builtin.zig:738` in 0.16.0.

The same three parts apply to every other domain:

```zig
test "every validation rule has a message" {          // section 2.3
    inline for (@typeInfo(ValidationError).error_set.?) |code| { ... }
}

test "every VkResult is classified" {                 // section 5.2
    inline for (@typeInfo(vk.Error).error_set.?) |code| { ... }
}

test "every Dawn validation call site is ported" {    // 865 sites, section 2.3
    inline for (comptime ported_rule_count) |index| { ... }
}

test "every device proc in the table is loaded" {
    inline for (@typeInfo(vk.DeviceProcs).@"struct".fields) |field| { ... }
}
```

The last one is worth stating: it walks the 164 fields of `DeviceProcs` and
asserts each is non-null after a real load, so a proc added to the table and
forgotten in the loader is a test failure rather than a null dereference in the
field.

The 347-row conformance table the generator replaces
(`docs/02-dawn-design.md` §2) is what `test "every API object is ported"` reads.

### 8.3 The decision record

**Priority.** Correctness of the public surface.

**Constraint.** `AGENTS.md` §3 (comptime exhaustiveness), §6 ("One upstream
file becomes one Zig file unless the mapping table says otherwise"), and the
rule from `AGENTS.md` §2 that a generator is a Zig program under `tools/`.

**Cost imposed on consumers.**

- The generated types are not hand-editable, so a consumer who wants a
  different field default edits the generator, not the output.
- `src/api/` is checked in and regenerated by `build.zig`, so a stale checkout
  can disagree with `dawn.json`. The build regenerating it is the mitigation.
- A consumer reading `BufferDescriptor` in a debugger sees generated line
  numbers. `std.debug` prints the type name, not the source, so this is a
  source-navigation cost only.

**Counterchoice.** Hand-write the public surface and maintain a conformance
test against `dawn.json`. This genuinely wins in one setting: a surface that
diverges from the JSON on purpose. If `dusk` dropped a WebGPU feature the
hardware could not support, or added a Vulkan-only descriptor, a hand-written
surface plus a documented divergence list is smaller than a generator plus an
escape hatch. It also wins for build time: no generator run, no generated files
to read.

`dusk` generates because the JSON is the spec and the generator is the only way
a new upstream object becomes a compile error rather than a silent gap
(`AGENTS.md` §3). The divergence case is handled by a `pending` coverage arm,
which is visible in the source and fails the sweep test until it is resolved.

**Grade and origin.** Settled. `docs/02-dawn-design.md` §2 ("The API surface is
not something to transcribe by hand. It is data."); `AGENTS.md` §3;
`docs/10-architecture.md` (`tools/gen_api.zig`, `src/api/`). Upstream evidence:
`generator/dawn_json_generator.py` (2,272 lines),
`generator/templates/api.h:127-132`, `generator/templates/api_cpp_chained_struct.h:47-56`,
`generator/templates/dawn_proc_table.h`; JSON line references throughout.

---

## 9. Threading

`docs/10-architecture.md` fixes the shape: one device mutex, one serial
timeline, one worker pool of two jobs. This section says what is passed and what
is reached for.

### 9.1 The device mutex

Dawn's device mutex is a recursive mutex wrapped in an RAII guard.
`DeviceMutex` is at `src/dawn/native/DeviceGuard.h:48` and derives from
`RecursiveMutex` at `:49`; `DeviceGuard` at `:101`; the trait that finds the
mutex on the device at `:72-77`. Every public entry point takes one. Dawn needs
recursion because `HandleError` re-enters
(`src/dawn/native/Device.cpp:630` takes a guard, and the tick releases it
before flushing callbacks at `:1579-1583`).

The port's device mutex is `std.Io.Mutex`, which is not recursive
(`lib/std/Io.zig:1587`, `lock(io)` at `:1602`). Recursion is not needed because
the port never holds the lock across a call that re-enters: the tick releases it
first, exactly as Dawn's `APITick` does.

```zig
// src/engine/device.zig
pub fn Device = struct {
    mutex: std.Io.Mutex = .init,
    timeline: Timeline,
    arena: std.heap.ArenaAllocator,
    io: std.Io,

    /// Every public entry point. `io` is threaded, never global (AGENTS.md §3).
    pub fn writeBuffer(
        dev: *Device,
        io: std.Io,
        buffer: Buffer,
        options: WriteBufferOptions,
    ) (ValidationError || UnrecoverableError)!void {
        dev.mutex.lock(io) catch return error.Canceled;
        defer dev.mutex.unlock(io);
        // ...
    }
};
```

`AGENTS.md` §3 says public API calls never block; they enqueue. So the critical
section is short: validate, append to the command stream, submit.

### 9.2 The serial timeline

Dawn owns one serial timeline in `ExecutionQueueBase`
(`src/dawn/native/ExecutionQueue.h:73`), with an atomic
`mLastSubmittedSerial` and a condvar-protected `mCompletedSerial` at `:192-193`,
both starting at `kBeginningOfGPUTime`. Completion flows
`UpdateCompletedSerialTo` → processors → tasks, and the tick drains
(`src/dawn/native/ExecutionQueue.cpp:269`, `:272`). Dawn's Vulkan tick is
`Device::TickImpl` at `src/dawn/native/vulkan/DeviceVk.cpp:366`, which reads the
completed serial at `:369`, reclaims descriptor allocators at `:372-376`,
ticks the resource memory allocator at `:378`, submits at `:380` and generates
errors at `:381`.

The port's timeline is §7.2's `Timeline`. The port's tick is the same five
steps:

```zig
// src/engine/device.zig
pub fn tick(dev: *Device, io: std.Io) (ValidationError || UnrecoverableError)!void {
    dev.mutex.lock(io) catch return error.Canceled;
    defer dev.mutex.unlock(io);

    const completed = dev.timeline.completed;

    // 1. reclaim descriptor sets
    dev.descriptor_allocators.destroyAll(completed);

    // 2. reclaim device memory (VMA)
    dev.memory.tick(completed);

    // 3. submit pending commands
    try dev.queue.submitPending(io);

    // 4. generate errors from the debug layer
    try dev.collectBackendErrors();

    // 5. fire callbacks — outside the lock, because a callback may re-enter
    return dev.flushCallbacks(io);
}
```

Step 5 is the one that must be outside the lock. Dawn comments the same
constraint at `src/dawn/native/Device.cpp:1577-1578` ("we cannot hold the lock
when flushing the callbacks so have to limit the scope of the lock here") and
`src/dawn/native/Device.cpp:1572-1574` (hold a `Ref` to self so the tick cannot
delete the device mid-call). The port's arena model needs no self-reference —
the caller holds the device — which is one fewer thing the tick must get right.

**A fence is polled from the tick, never from a thread of its own.**
`docs/10-architecture.md` says so, and `docs/02-dawn-design.md` §4.4 confirms
Dawn has no fence-poll threads at this revision.

### 9.3 The worker pool

Two jobs only: SPIR-V validation at shader-module creation, and pipeline
creation when the caller asked for it asynchronously
(`docs/10-architecture.md`). Dawn's pool is
`src/dawn/platform/WorkerThread.h:87-89` with a default of two, and Dawn's
shader validation runs on the calling thread
(`src/dawn/native/SpirvValidation.cpp:37-79`, called directly).

The port moves validation onto the pool, because it is the one CPU-bound step in
shader-module creation and the port has no Tint to hide it:

```zig
// src/pipeline/shader_module.zig
pub fn createShaderModule(
    dev: *Device,
    io: std.Io,
    alloc: std.mem.Allocator,
    desc: ShaderModuleDescriptor,
) std.Io.ConcurrentError!std.Io.Future(ShaderModuleResult) {
    return io.concurrent(validateAndCreate, .{ dev, alloc, desc });
}

fn validateAndCreate(
    dev: *Device,
    alloc: std.mem.Allocator,
    desc: ShaderModuleDescriptor,
) ShaderModuleResult {
    // spirv.validate, then spirv.reflect, then vkCreateShaderModule on the
    // caller's own words (docs/10-architecture.md "Shaders").
}
```

`io.concurrent` rather than `io.async`, because a shader module's caller must
wait for it before submitting work: a validation failure has to reach the
caller as an error, and `concurrent` refuses with
`error.ConcurrencyUnavailable` (`lib/std/Io.zig:2352-2356`) rather than
silently running inline. With `concurrent_limit` set to `.limited(2)`
(`lib/std/Io/Threaded.zig:1592`, `Io.Limit.limited` at `lib/std/Io.zig:632`) a
third concurrent validation returns that error, and the caller decides whether
to retry or to fall back to inline validation. **The port chooses the explicit
failure over Dawn's queue** (`std::queue` at
`src/dawn/platform/WorkerThread.h:103`), and the cost is a call site that must
handle a case Dawn never presents.

### 9.4 What is passed and what is reached for

| Value | How it reaches the callee | Why |
| --- | --- | --- |
| allocator | parameter, first | `AGENTS.md` §2 |
| `io` | parameter | `AGENTS.md` §3 |
| device state | parameter (`dev: *Device`) | `AGENTS.md` §3, "State is a parameter, not a capture" |
| command stream | `command` module, passed as the encoder | `docs/10-architecture.md` |
| device memory | VMA, reached through `memory` | `docs/20-dependencies.md` |
| Vulkan entry points | `vk.Dispatch`, reached through `engine` | `AGENTS.md` §3.1 |
| SPIR-V words | parameter, copied out of the descriptor | §8 |
| clock | **not reached for**; `Io.Clock` only | `AGENTS.md` §3, "Read no clock in logic" |
| global state | **none** | `AGENTS.md` §2 |

Two rows are absences and they are the point. Nothing reaches for a clock: the
timeline is a counter, and a tick is driven by the caller
(`AGENTS.md` §3, "Determinism is a feature. Inject the seed. Read no clock in
logic"). Nothing reaches for a global: `io` is a parameter, so a test builds its
own.

### 9.5 The decision record

**Priority.** Safety and determinism.

**Constraint.** `docs/10-architecture.md` "Threading" fixes the model and says
it is Dawn's and that it is correct: "WebGPU's ordering guarantees are a serial
order." `AGENTS.md` §3 requires `io` threading and no globals.

**Cost imposed on consumers.**

- The consumer drives the tick. A consumer that never ticks sees no completion
  callbacks and no serial reclamation. Dawn's tick is also caller-driven
  (`src/dawn/native/Device.h:325`, `DeviceBase::APITick` at
  `src/dawn/native/Device.cpp:1569`), so this is not a new cost, but the port's
  documentation has to say it plainly.
- The mutex is not recursive, so a consumer calling a public entry point from
  inside a callback it registered must not already hold the lock. The tick
  releases it before step 5 for exactly this reason.
- `io.concurrent` can return `error.ConcurrencyUnavailable` where Dawn's pool
  would queue. A caller with three concurrent shader modules must handle it.

**Counterchoice.** `std.Thread` plus a hand-rolled pool with its own
`std.Thread.Mutex` and `std.Thread.Condition`, ignoring `Io` for the engine's
internals. This genuinely wins in one setting: single-threaded embedding. If a
consumer links `dusk` into a runtime that already owns its threads and refuses
to hand over an `Io` — a game engine's job system, a browser's event loop —
then threading `Io` through every signature is pure cost, and a pool built on
`std.Thread` plugs into what the consumer already has. It also wins when the
consumer needs more than two worker threads, because
`std.Io.Threaded`'s `async_limit` grows the pool but a single-threaded `Io`
implementation (`Io.Threaded.init_single_threaded`,
`lib/std/Io/Threaded.zig:1674`) cannot.

`dusk` uses `Io` because `AGENTS.md` §3 makes it a house rule and because it
gives cancellation (§3.2) and a deterministic test back end for free.

**Grade and origin.** Settled. `docs/10-architecture.md` "Threading";
`AGENTS.md` §3. Upstream evidence: `src/dawn/native/ExecutionQueue.h:73`,
`:192-193`; `src/dawn/native/vulkan/DeviceVk.cpp:366-383`;
`src/dawn/native/Device.cpp:1569-1583`; `src/dawn/native/DeviceGuard.h:48-101`;
`src/dawn/platform/WorkerThread.h:87-107`.

---

## 10. Verification hooks

Three hooks: inject a failure, fail the Nth allocation, drive the front end
with no GPU. Each is a parameter, not a build flag.

### 10.1 Inject a failure

Dawn uses a compile-time-gated macro, `INJECT_ERROR_OR_RUN`, at
`src/dawn/native/ErrorInjector.h:64-78`, which expands to the bare statement
when `DAWN_ENABLE_ERROR_INJECTION` is undefined. The fake codes are
`VK_FAKE_ERROR_FOR_TESTING` and `VK_FAKE_DEVICE_OOM_FOR_TESTING` at
`src/dawn/native/vulkan/VulkanError.h:36-37`, used by the `CheckVkSuccess` and
`CheckVkOOMThenSuccess` macros at `:52-62`. The comment at
`src/dawn/native/ErrorInjector.h:67` says the deoptimization is acceptable
because the path is for tests and fuzzing only.

The port makes the injection a parameter and keeps the code compiled in, so a
Debug run and a ReleaseSafe run both have it:

```zig
// src/core/fault_injection.zig
pub const Injector = struct {
    allocator: std.mem.Allocator,
    budget: ?usize = null,       // fail the next call, once
    memory_result: i32 = 0,      // substitute for a vk* return code
    memory_calls: usize = 0,

    pub const disabled: Injector = .{ .allocator = undefined, .budget = null };

    /// Returns a substituted `VkResult`, or `null` to run the real call.
    pub fn nextResult(self: *Injector) ?vulkan.VkResult {
        self.memory_calls += 1;
        if (self.budget) |remaining| {
            if (remaining == 0) {
                self.budget = null;
                return @intCast(self.memory_result);
            }
            self.budget = remaining - 1;
        }
        return null;
    }

    pub fn failNext(self: *Injector) void {
        self.budget = 0;
    }
};
```

It rides on the allocator rather than on a thread-local, because
`AGENTS.md` §3 already requires allocator injection and a test that already
builds a failing allocator should not build a second injection mechanism.

The `vk` layer consults it at the boundary:

```zig
// src/vk/result.zig
pub fn checkInjected(
    injector: *core.Injector,
    code: vulkan.VkResult,
    comptime context: []const u8,
) Error!void {
    if (injector.nextResult()) |substituted| {
        std.log.scoped(.vk).warn("injected {d} at {s}", .{ substituted, context });
        return check(substituted, context);
    }
    return check(code, context);
}
```

`VK_FAKE_ERROR_FOR_TESTING` becomes `core.injected_result`
(`vulkan.VK_RESULT_MAX_ENUM`), §5.3. The test:

```zig
test "vkCreateBuffer failure surfaces as an error" {
    var injector: core.Injector = .{ .allocator = std.testing.allocator };
    injector.failNext();

    const outcome = try createBufferExpectingFailure(injector);
    try std.testing.expectError(error.OutOfDeviceMemory, outcome);
}

test "an unmapped VkResult reaches the caller" {
    // A driver returning a code the pinned headers do not name must not crash.
    var injector: core.Injector = .{ .allocator = std.testing.allocator };
    injector.memory_result = -999999;

    const outcome = try classifyInjected(injector);
    try std.testing.expectEqual(vk.Error.UnknownResult, outcome);
}
```

### 10.2 Fail the Nth allocation

`AGENTS.md` §3: "Allocator injection and fail-N. Every allocating function takes
a `std.mem.Allocator` as its first parameter. A test fails the Nth allocation,
from 0 up to the first success."

Zig 0.16.0 ships this. `std.testing.FailingAllocator` is at
`lib/std/testing/FailingAllocator.zig`, with `Config` at `:21`, `fail_index` at
`:24`, `init` at `:30`, and the failure check at `:65`.
`std.testing.checkAllAllocationFailures` is at `lib/std/testing.zig:1115-1120`:

```zig
pub fn checkAllAllocationFailures(
    backing_allocator: std.mem.Allocator,
    comptime test_fn: anytype,
    extra_args: CheckAllAllocationFailuresExtraArgs(@TypeOf(test_fn)),
) !void
```

It runs `test_fn` once to learn the allocation count, then reruns with
`fail_index` from 0 to that count, and it checks `allocated_bytes ==
freed_bytes` on each failure (`lib/std/testing.zig:1136-1145`), so a leak
introduced by an error path is caught by the same call.

The port uses it directly. The rule is that every allocating function takes the
allocator first:

```zig
pub fn createTexture(
    dev: *Device,
    alloc: std.mem.Allocator,
    desc: TextureDescriptor,
) Allocator.Error!Texture
```

```zig
test "createTexture leaks nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createTextureTest, .{});
}

fn createTextureTest(alloc: std.mem.Allocator) !void {
    var dev = try Device.init(std.testing.allocator, {});
    defer dev.deinit();

    const texture = try createTexture(&dev, alloc, .{
        .usage = .{ .render_attachment = 1 },
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8unorm,
    });
    dev.destroyTexture(texture);
}
```

The `errdefer` in `createTexture` is what makes this pass: each allocation is
paired with a cleanup that runs when a later allocation fails.

### 10.3 Drive the front end with no GPU

`docs/10-architecture.md`: "`command` records intent; `engine` replays it into
`vk`. This split is what lets the whole front end be tested with no device. Do
not merge the two modules." And `AGENTS.md` §3: "The front end holds no Vulkan."

So a no-GPU test drives `api` and `command` and never imports `vk`:

```zig
test "a render pass records into the command stream" {
    var dev = try Device.init(std.testing.allocator, .{});
    defer dev.deinit();

    const encoder = try dev.createCommandEncoder(null);
    {
        const pass = try encoder.beginRenderPass(&.{
            .color_attachments = &.{.{ .view = color_view, .load_op = .clear, .store_op = .store }},
        });
        _ = try pass.setPipeline(render_pipeline);
        _ = try pass.draw(3);
        _ = try pass.end();
    }

    const buffer = try encoder.finish();
    try std.testing.expectEqual(@as(usize, 5), countCommands(buffer));
    dev.destroyCommandBuffer(buffer);
}
```

`Device.init` with no Vulkan means no arena leak, no `Io`, and no dispatch
table. `command` never imports `vk`
(`docs/10-architecture.md`: "`command` does not import `vk`"). A test that
needs the back end swaps in a recording one:

```zig
test "the replay reaches vkCreateCommandBuffers once" {
    var recorder: RecordingBackend = .{};
    var dev = try Device.init(std.testing.allocator, .{ .backend = &recorder });
    defer dev.deinit();

    // ... record a pass ...

    try dev.queue.submitPending(dev.io);
    try std.testing.expectEqual(@as(usize, 1), recorder.create_command_buffers);
    try std.testing.expectEqual(@as(usize, 1), recorder.begin_command_buffer);
}
```

`RecordingBackend` is a `anytype`-parameterised duck type, not a virtual base.
`docs/02-dawn-design.md` §6 lists "Virtual `BackendConnection` + trait-struct
downcast" as one of the facilities that force a decision; the null back end is
1,019 lines, 62 `override` tokens of which 6 are destructors, across 16 class
definitions of which 10 declare overrides
(`docs/02-dawn-design.md` §3), and the port does not pay that.

For determinism the `Io` is explicit:

```zig
test "async pipeline creation is deterministic under a failing Io" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    // Every io.async runs inline; the test controls ordering completely.
}
```

`std.Io.failing` (`lib/std/Io.zig:2512`) is the opposite: it refuses every
operation, refuses concurrency, and fills `random` with zeroes
(`lib/std/Io.zig:2502-2511`). A test that asserts an `Io` parameter is actually
used uses it.

### 10.4 The decision record

**Priority.** Testability, which `AGENTS.md` §3 calls the default rather than an
option.

**Constraint.** `AGENTS.md` §3 (allocator injection and fail-N, comptime
exhaustiveness, determinism), and the rule that a module which cannot be driven
deterministically is a review finding.

**Cost imposed on consumers.**

- Every allocating function takes an allocator it may not need. That is a real
  signature cost and it is why `AGENTS.md` §2 requires the allocator to be
  first, so it is at least uniform.
- A test written against a recording back end does not prove Vulkan behaviour. It
  proves the front end. The layer matrix in `docs/50-verification.md` owns the
  rest.
- The headless constraint means no test may require a surface or a swapchain
  (`AGENTS.md` §5). A consumer that needs swapchain behaviour tests it against
  a real window elsewhere.

**Counterchoice.** Dawn's approach: a compile-time-gated injection macro
(`src/dawn/native/ErrorInjector.h:64-78`) with no runtime cost and no signature
change. This genuinely wins in one setting: performance measurement. A
release build with injection compiled out has no parameter to pass and no branch
to predict. It also wins for code that is not on an allocation path and not
error-prone — a macro keeps the call site clean in a way an extra parameter does
not.

`dusk` uses parameters because `AGENTS.md` §3 requires it and because a
compile-time gate means the shipped library and the tested library are different
code, which is the failure mode a test is supposed to rule out. The counter is
that `injector.nextResult()` returns `null` on the common path, so the branch is
predicted and the parameter is unused; **this is a reasoning about a
predictable branch, not a measurement.**

**Grade and origin.** Settled. `AGENTS.md` §3, §5;
`docs/10-architecture.md` "Module boundaries". Upstream evidence:
`src/dawn/native/ErrorInjector.h:35-78`;
`src/dawn/native/vulkan/VulkanError.h:36-62`;
`src/dawn/native/vulkan/VulkanError.cpp:96-121`.

---

## 11. Rejected alternatives

Each entry names the alternative, why it lost, and what would change the answer.

### 11.1 Per-object reference counting

**Alternative.** `Ref<T>`-equivalent: intrusive refcount word, `retain` and
`release` on every handle.

**Why it lost.** `AGENTS.md` §3 requires a failure to be injectable and a module
to be deterministically drivable; a refcount bug is a use-after-free that a
`checkAllAllocationFailures` run does not catch. Dawn's own record shows the
cost: the `DeleteThis` override contract at
`src/dawn/native/ObjectBase.h:176-186`, and the `LockAndDeleteThis` variant at
`:188` that some classes must also override. The arena has no such invariant.

**What would change the answer.** A requirement that objects outlive their
device, or a measured peak-memory problem on a per-frame create/destroy loop.
Both are listed in §1.2 as the setting where it genuinely wins.

### 11.2 Reimplement `Result<T, E>` in Zig

**Alternative.** Port `src/dawn/common/Result.h` (535 lines) and
`Result.cpp` (46 lines) as a tagged union with the payload packed next to the
tag.

**Why it lost.** Zig's `!T` and `E!T` already are that, with the tag handled by
the language and the payload by the unwinder. `docs/02-dawn-design.md` §4.2
reaches the same conclusion and names it as the one piece of `common/` not to
reimplement.

**What would change the answer.** Nothing foreseeable. This is not a preference;
the language already provides the thing.

### 11.3 A plain callback for async work

**Alternative.** `createRenderPipelineAsync(dev, io, desc, completion_callback)`
with no future.

**Why it lost.** `std.Io.Future` gives cancellation
(`lib/std/Io.zig:1191`) and grouping (`Io.Group` at `:1218`) for free, and
`AGENTS.md` §3's deterministic-back-end rule is easier to satisfy with an `Io`
than with a callback queue. The callback form also cannot express "cancel the
in-flight map", which `mapAsync` needs.

**What would change the answer.** The C ABI milestone. A C caller has no future
to await, so the generated C header will need a callback form regardless, and
the Zig future would then be a thin wrapper over it.

### 11.4 A pointer chain for descriptors

**Alternative.** `next_in_chain` over a tagged union, matching Dawn's
`WGPUChainedStruct` (`generator/templates/api.h:300-303`).

**Why it lost.** A pointer chain cannot be type-checked and cannot be made
exhaustive by the compiler. `AGENTS.md` §3 makes comptime exhaustiveness the
coverage substitute, and a `?T` per extension is what makes the
`forEachPresent` signature in §4.2 grow a parameter when the JSON grows an
entry.

**What would change the answer.** A consumer with a third-party extension the
port has never heard of, or a requirement that descriptors cross a language
boundary with Dawn-compatible layout. §4.3 states both.

### 11.5 Generate a `VkResult` Zig enum

**Alternative.** `tools/gen_dispatch.zig` emits a non-exhaustive
`enum(c_int)` mirroring `VkResult`, and `translate-c` is told not to emit it.

**Why it lost.** `vulkan.zig` is generated and never hand-edited
(`AGENTS.md` §3.1), and it already owns `VkResult` at line 920. A second
definition of the same numbers in `vk.zig` is a second source of truth for the
same ABI, and the two can drift when the pinned headers change.

**What would change the answer.** A decision to stop using `translate-c` for the
enum types and generate the whole of `vulkan.zig` from the XML instead. That is a
rung-3 to rung-2 move on the dependency ladder and would need its own record in
`docs/20-dependencies.md`.

### 11.6 Re-export Vulkan entry points as callable functions

**Alternative.** Bind every proc at load time into a module-level namespace so
call sites read `vulkan.vkCreateBuffer(...)`.

**Why it lost.** `AGENTS.md` §3.1 makes a direct call a review finding: it
bypasses the loader tier, so a missing proc becomes a null dereference instead
of a named error, and the tolerated-missing rule becomes a runtime `if` at every
call site instead of a difference in return type (§6.2).

**What would change the answer.** Nothing within the current architecture. The
`reviewer` role exists to catch it.

### 11.7 A pinned Zig package for the slab and serial containers

**Alternative.** Add `slab_allocator` and `serial_collections` to
`build.zig.zon`.

**Why it lost.** `docs/20-dependencies.md` requires a reason the standard
library does not cover the slot, and the reasons here are specific properties —
index-encoded free lists, serial-ordered reclamation, LRU eviction, tick-windowed
block recycling — not generic container work. The upstream implementations are
103 to 222 lines each, so the port is smaller than the dependency.

**What would change the answer.** A maintained package that provides serial
*and* slab semantics with fuzz coverage, or an upstream line count that grows
past roughly a thousand lines for any one of them.

### 11.8 One error struct instead of three error sets

**Alternative.** A `struct Error` with a tagged-union `code`, returned by value,
with no error sets anywhere.

**Why it lost.** `AGENTS.md` §2 requires each API to declare its own error set
and forbids `anyerror`, and §3 requires a comptime sweep of the set. A struct
has no set to sweep.

**What would change the answer.** The C ABI milestone, where a C caller cannot
match on a Zig error set. §2.4 states this as the counterchoice's winning
setting.

### 11.9 `std.Thread` and a hand-rolled pool instead of `Io`

**Alternative.** `std.Thread.spawn` (`lib/std/Thread.zig:344`),
`std.Thread.Mutex`-equivalent primitives, and a hand-written two-thread pool
with its own shutdown protocol.

**Why it lost.** `AGENTS.md` §3 requires `io` as a parameter on anything that
can block. 0.16.0 has no `std.Thread.Mutex`; the mutex is `std.Io.Mutex`
(`lib/std/Io.zig:1587`) and takes `io`. A hand-rolled pool would have to own its
cancellation and its shutdown protocol, both of which `Io` already provides.

**What would change the answer.** A single-threaded embedding that will not
supply an `Io`, or a consumer needing more worker threads than
`std.Io.Threaded`'s `async_limit` allows. §9.5 states both.

### 11.10 Recursive device mutex

**Alternative.** Make the port's device mutex recursive, matching Dawn's
`DeviceMutex : RecursiveMutex` (`src/dawn/native/DeviceGuard.h:48-49`).

**Why it lost.** Dawn needs recursion because `HandleError` re-enters. The port
does not: the tick releases the lock before firing callbacks, exactly as
`src/dawn/native/Device.cpp:1577-1583` does, and `handleError` takes the same
non-recursive lock on a path that never holds it. A recursive mutex hides the
re-entrancy instead of fixing it, and `AGENTS.md` §2's "no hidden state" rule
argues against it.

**What would change the answer.** A new call path that must re-enter while
holding the lock. The fix is to release the lock, not to make it recursive.

### 11.11 Translate Dawn's validation rules mechanically

**Alternative.** A build-time translator that converts each of the 865
`DAWN_INVALID_IF` sites into a Zig rule.

**Why it lost.** `docs/02-dawn-design.md` §4.8 is explicit: "A Zig port must
*write* the rules rather than translate a rule table." The C++ sites embed C++
control flow — conditionals, loops, local variables — so there is nothing to
translate mechanically. The 865 sites are the inventory; the message ids are
the port's to invent (§2.3).

**What would change the answer.** Nothing. This is upstream's shape, not a
port limitation.

### 11.12 Port SPIR-V validation through a binding

**Alternative.** `translate-c` over SPIRV-Tools, as Dawn does at
`src/dawn/native/SpirvValidation.cpp:37-79`.

**Why it lost.** Already decided. `docs/20-dependencies.md` "SPIR-V — validate
in Zig, no optimiser" records that the port validates in Zig and does not link
SPIRV-Tools; `spirv-val` is a test-time tool that proves a fixture is well
formed before the engine sees it. Listed here so the reader knows it was
considered, not because it is open.

**What would change the answer.** A SPIR-V feature the Zig validator cannot yet
handle and a measurement showing the port's validator is the bottleneck. Not
applicable to this document.

---

## 12. Unknown

Each entry names what would settle it.

1. **Whether `std.Io.Limit.limited(2)` behaves acceptably under the port's
   actual load.** §3.2 records that the third concurrent task runs on the
   calling thread rather than queueing, and §9.3 records that `io.concurrent`
   refuses instead. Whether either matters depends on how many shader modules a
   consumer creates per frame. Settled by: a measurement, which
   `docs/50-verification.md` owns.

2. **Whether `Slab.create`'s two allocations are acceptable.** §7.1 states the
   cost and does not measure it. Settled by: a profile of the bind-group
   creation path under the port's slab, compared against the same path under a
   single-allocation variant.

3. **`LruCache.evictOldest`'s linear scan.** §7.3 states the reasoning about
   `capacity` and explicitly does not claim it is fast enough. Settled by: the
   same measurement as 2.

4. **Whether the driver-selection path needs `VK_KHR_portability_enumeration`.**
   `docs/02-dawn-design.md` §8 lists this as open upstream too. Settled by:
   reading `src/dawn/native/vulkan/PhysicalDeviceVk.cpp` once the port reaches
   that file.

5. **Whether the generated `BufferUsage` bitmask needs an `EnumSet` rather than
   a `packed struct`.** §8.1 emits a `packed struct` so `@bitCast` round-trips
   and fields have names. `std.enums.EnumSet` exists at
   `lib/std/enums.zig:241` and may be the better fit. Settled by: writing the
   one consumer that filters a usage set, and seeing whether `@bitCast` or
   `EnumSet` reads better there.

6. **Whether `CallbackTaskManager`'s `CallbackTask` states survive.**
   `src/dawn/native/CallbackTaskManager.h:57-59` declares three pure virtuals —
   `FinishImpl`, `HandleShutDownImpl`, `HandleDeviceLossImpl` — and
   `CallbackTask` holds a `CallbackState mState` at `:62` whose three values are
   `Normal`, `ShutDown` and `DeviceLoss` (`:42-46`). The port maps this to
   `Io.Group.cancel` and a device-lost sweep (§9.2 step 5), but has not been
   checked whether all three states are reachable in a Vulkan-only port.
   Settled by: reading the whole of `src/dawn/native/CallbackTaskManager.h` and
   `.cpp` when the tick lands.

7. **Whether the `no autolock` set needs porting at all.** Seven objects carry
   `"no autolock"` in `dawn.json`: adapter, command encoder, compute pass
   encoder, instance, render bundle encoder, render pass encoder, surface.
   These are the objects whose public methods do not take the device lock in
   Dawn. Whether the port's single device mutex (§9.1) covers them, or whether
   they need the lock-free treatment, is not settled. Settled by: reading
   `generator/dawn_json_generator.py` for what `no autolock` emits, and
   `src/dawn/native/DeviceGuard.h` for what it protects.

**The list is not empty.** Items 1 through 3 are performance questions that
`docs/50-verification.md` owns and that this document declines to guess at.
Items 4 through 7 are upstream-reading tasks with named files and named lines.
