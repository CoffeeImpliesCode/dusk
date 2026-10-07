# 30 — Port design: the Zig-native contract

This document replaces Dawn's C++ idioms with Zig ones. It fixes the public
shape of the port: what a handle is, what an error is, what a future is, how a
descriptor chains, how a `VkResult` becomes a Zig error, how the dispatch table
is loaded, which container replaces which, and how `dawn.json` becomes Zig.

Every upstream claim cites `path:line` in the Dawn tree pinned at
`32f77c02294310054a660c393feded4bcb3f203c`. The original readings used
`/tmp/scratch/research/dawn`. This historical path is not a
required checkout location. `tools/dawn_pin.zon` records the source pin.
Recreate its `src`/`include` sparse checkout with `zig build fetch-dawn`.
Use `zig build fetch-dawn -Ddawn-dir=/absolute/path/to/research/dawn` to select
a destination. Without that option, the step uses `DUSK_DAWN_SRC`, then
`buildhost_SCRATCH_ROOT/research/dawn`, then
`$HOME/.cache/dusk-research/research/dawn`.
The explicit source-only fetch does not build or depend on Dawn C++ or Tint.
Ordinary builds do not depend on it.

Zig claims cite the 0.16.0 standard library or the generated `vulkan.zig`
in the historical probe directory. Those observations came from file readings.

A contested decision carries five parts: **Priority**, **Constraint**,
**Cost imposed on consumers**, **Counterchoice**, **Grade and origin**.

**What this document claims.** The typed native facade now integrates the implemented production subset.
It provides instance and adapter discovery, synchronous resource creation, recorded submission, serial wait, and ordered native cleanup.
The generated 205-method procedure table remains a separate API surface.
This result does not establish full public WebGPU parity, M1–M21 completion, or every native feature.
The historical proof records below do not establish the later native integration.

The formerly missing M6, M7, M18, and M19 families passed local behavior tests
on 2026-10-07. The following snapshots predate native stage constants.
Three selected cross-test rows and explicit zero-layer GPU checks passed.
Final test-helper replay checks passed.
The historical full `zwanzig` snapshot reported 107 optional-unwrap warnings, not a clean ten-stage contract.
The historical legacy `zig-gate --no-zbc` passed its five active stages.
It explicitly skipped `zbc`. It did not run `zwanzig`, cross-tests, or coverage.
The historical aggregate passed 69/69 build steps with 251 root tests in each safety mode.
The current full aggregate passed 73/73 steps, with 262 root tests each in Debug and actual ReleaseSafe.
Current cross-tests passed three rows with 262 root tests each, including big-endian `powerpc64-linux`.
Both compute shards passed again with zero validation layers.
Final 142-file source lint passed with zero diagnostics, errors, or warnings.
The current legacy `zig-gate --no-zbc` passed its five active stages.
The full ten-stage contract remains unclaimed and outside the permitted analyzer boundary.
A reproduced render-bundle allocation-failure callback bug now has a passing regression.
This fix does not establish general successful-operation reentrancy.
The historical 138-row census covered M6 (63), M7 (32), M18 (38), and M19 (five).
It is neither a remaining count nor the whole backlog.
M14's 63/341 triage budget does not subtract implementation backlog.
`docs/40-plan.md` owns the selected remaining async, disk, persistent-cache,
and specialization groups.
The triangle and query shards encode through the frontend and finish a `Finished` stream.
The engine replays that stream into Vulkan before submission.
No timing, throughput, or memory-performance figure is claimed here.
This document does not claim `dawn.json` output is byte-compatible with Dawn's
C header. Section 4 explains that decision.
It does not reopen decisions in `docs/20-dependencies.md`.

Use named acceptance steps, for example `zig build test-memory`,
`zig build test-formats`, `zig build test-triangle`, and `zig build test-query-set`.
`zig build test` runs the aggregate suite. Arguments after `--` did not filter
that suite through the former `b.args` forwarding.

---

## 1. Ownership and lifetime

### 1.1 The model

`docs/10-architecture.md` separates borrowed generated handles from typed native owners.
Core host objects occupy one arena per device.
Native payloads can be released before that arena.
This section states both contracts and their costs.

A generated handle is a pointer into the device arena with a kind tag.
It is not a generational ID or a slab index.

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

A generated handle carries no owned reference. Copying one is a pointer copy.
The value has no destructor, `deinit`, or `release`.
The following examples describe borrowed core handles, not the typed native facade.

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

Core destruction marks the host object and invokes its destruction callback.
The callback can release owned native payloads.
The arena retains host object storage until core device teardown.
It does not retain every Vulkan allocation until teardown.

**Typed native owners.** `engine.Device.release` checks device identity, pending GPU work, and live dependents before native destruction.
Bind groups, pipeline layouts, pipelines, and texture views retain their dependencies.
Pipeline-store cache hits return owned references.
These counts are not a complete Dawn `Ref<T>` replacement.

**Device-owned live object caches.** `ResourceStore` owns weak indices for bind-group layouts, pipeline layouts, samplers, shader modules, and attachment states.
The stable native device context owns this store (`src/engine/native_resource_store.zig:12-48`).
The original `ObjectGuard` serializes lookup, native creation, insertion, alias acquisition, and removal.
The index owns no reference. A hit acquires one user alias, including when only internal leases keep the object alive.
Bind groups, pipelines, recordings, and pending GPU roots retain internal leases in the same core ledger.
Final release or explicit payload retirement removes weak membership before native destruction.
Dead arena headers can remain, but a later lookup cannot return their retired payloads.

Hash equality alone never establishes identity. Each bucket uses a full semantic comparison.
Bind-group layouts normalize descriptor entry order but preserve logical binding numbers, visibility, types, dynamic offsets, minimum sizes, and validation counts.
Their compatibility token also belongs to identity (`native_resource_store.zig:58-76`).
Pipeline layouts compare ordered canonical group owners, including empty gaps and trailing groups, immediate byte size, and compatibility token.
Explicit token zero and nonzero domains remain distinct. Automatic layouts mint a token once per preparation.
Sampler identity includes every ordinary field and every supplied Y′CbCr conversion field, including conversion presence.
Labels do not affect identity. Sampler LOD signed zero has one representation (`src/engine/sampler.zig:38-56`).
Shader identity compares unchanged owned SPIR-V words, not labels (`native_resource_store.zig:51-56`).
Attachment identity includes color slots and formats, depth/stencil format, sample count, resolve-expansion masks, and pixel-local-storage slots.
The canonical constructors normalize ordinary resolve targets (`src/command/attachment_state.zig:229-261`).
Identity does not imply backend support for every binding kind, pixel-local storage, or resolve expansion.

Factories reject allocator mismatch, invalid dependencies, and missing cleanup procedures before native creation.
Reference overflow leaves existing aliases unchanged.
Failed insertion publishes no cache hook. Factory rollback releases temporary references and destroys initialized native payloads.
The render-pass cache also destroys a created-but-uninserted `VkRenderPass` if map insertion fails (`src/engine/render_pass_cache.zig:583-597`).
Its monotonic ID can advance on a failed native create or insertion. Rollback does not promise gap-free IDs.
The cutover has no compatibility shim or second ownership ledger.
These are live object caches, not persisted driver artifacts.
Actual `VkPipelineCache` persistence and its pipeline-create integration remain unimplemented.

**Selected native external auxiliary ABI.** Public logical bindings remain in `0..999`.
For external logical binding `N`, the private auxiliary block starts at `1000 + 4*N`.
The four roles occupy that block, with maximum private binding 4999.
The assignment is independent of descriptor input order and cannot collide with a public binding.
This is Dusk's selected native ABI, not a claim that Dawn's descending UINT_MAX binding scheme is a suitable Vulkan ABI.
Callers supply matching unchanged SPIR-V declarations. The runtime does not rewrite bindings or words.
The owned fixture cutover assigns logical binding 0 to private roles 1000, 1001, and 1002.
Its public sampler binding 2 and storage binding 4 do not change.
This selected source contract alone establishes no regenerated artifact, Vulkan layout, or GPU pass.

`native_resources.destroyAll` walks the core object list before the arena is released.
The core retirement hooks remove weak pipeline and resource memberships before payload destruction.
Current device destruction frees the native context and core arena.
It does not preserve a new reference-counted host shell.

**Stable placement.** Native contexts initialize at their final heap addresses.
Keep each high-level instance and device unmoved while children or operation pins borrow it.
Adapter lists own stable physical rows and retain the instance.
Devices retain their adapter, physical row, and instance through explicit counts.
List and instance teardown refuse live children without changing their counts.
`std.Io` stays explicit at each operation. Native owners do not capture it.

**Standalone native query borrows.** The caller uniquely owns a low-level queue and must not copy it.
The high-level facade instead lends its context-owned queue through `QueueLease`.
Construction may move a standalone queue before native query registration.
After registration, keep the queue and registered query-set storage alive and unmoved
until deregistration or queue teardown detaches every borrow.
Query-set destruction can defer detachment until the last submission completes.
These are caller obligations, not enforced runtime pins or a repaired observed use-after-free.
See `src/engine/queue.zig` and `src/engine/query_set.zig` for the native borrow contract.

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

- Borrowed handles cannot outlive their device arena.
  Copying a handle does not retain its device or native payload.
- Host wrapper storage follows the device's allocation high-water mark.
  Explicit native release can return GPU payload storage before teardown.
- The caller must keep parent instances, lists, and devices alive and unmoved.
  Typed dependency counts do not provide general surviving objects after device teardown.
- A live queue lease excludes high-level submit, unmap, and release.
  The caller must end that lease with explicit `Io`.

### 1.2 The decision record

**Priority.** Safety, first in the house order in `AGENTS.md` §2.

**Constraint.** The generated handle surface does not use refcounted smart pointers.
It uses arena host storage and borrowed handles.
The typed native facade separately counts resource dependencies and operation pins.
This does not adopt Dawn's general `Ref<T>` contract.
Dawn's `DeleteThis` override rule remains an upstream policy difference
(`src/dawn/native/ObjectBase.h:177-186`).

**Cost imposed on consumers.** The costs listed in §1.1.

**Counterchoice for generated handles.** General per-object reference counting with an explicit `release()`:

```zig
pub fn createBuffer(dev: *Device, alloc: std.mem.Allocator, desc: BufferDescriptor) Allocator.Error!Buffer {
    const object = try alloc.create(BufferImpl);
    object.* = .{ .device = dev, .descriptor = desc, .ref_count = .init(1) };
    return .{ .ptr = object, .kind = .buffer };
}

pub fn retain(buffer: Buffer) void { ... }
pub fn release(buffer: Buffer) void { ... }  // frees at zero
```

This alternative can keep a host shell alive after the device stops.
It does not make a destroyed native device or its payload valid for GPU work.
It can also reclaim host object storage at the last reference.
Current Dusk native release reclaims payloads, but keeps arena host storage.

**Grade and origin.** Settled for borrowed generated handles, not a prohibition on native dependency counts.
See `docs/10-architecture.md` "Object model" and this section.
Upstream evidence remains `src/dawn/common/RefCounted.h:69`,
`src/dawn/common/RefCounted.cpp:41-43`, and `src/dawn/common/RefBase.h:52-57`.
Dusk's typed facade has explicit release without Dawn's general intrusive smart-pointer surface.

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

### 1.4 Current native integration boundary

The published typed facade reaches real Vulkan discovery, device creation, resource factories, submission, serial wait, and cleanup.
`docs/40-plan.md` "Current native phase-2 integration" records the actual consumer proof and its verification-record link.
That consumer does not define generated procedure-table parity or full public WebGPU parity.

Raw Vulkan querying and frontend capability projection remain separate.
Core admission gates robust access, compression eligibility, four descriptor-array dynamic-indexing flags, fragment atomics, and full draw indices.
It also gates independent blend, depth-bias clamp, cube arrays, and sample-rate shading.
Native creation enables the queried baseline flags.
The prior missing-baseline-guard observation is obsolete.
This corrected hardware baseline does not establish full Dawn Core parity.

The native projection advertises `core_features_and_limits` only when Core hardware guards and offered limits pass.
It advertises `depth_clip_control` only when queried `depthClamp` is present.
The caller must require depth-clip control to enable native depth clamp.
Optional compression feature bits remain unadvertised, despite hardware compression eligibility.
Other required native features fail with a typed error.

Offered limits respect queried descriptor budgets, per-stage resources, and fragment-output resources.
They cap bind groups at `4`, bindings per group at `1000`, and immediate data at `256` bytes.
Device creation bounds level defaults by offered capabilities and preserves accepted required values.
Maximum limits are upper bounds. Alignment limits are lower bounds.
Maintenance4 support controls the native LocalSizeId path.
These formulas and feature policies are partial merges, not literal Dawn normalization.


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
dropped members are `mDebugGroups` and `mBackendMessages`.
Dawn uses them for backend diagnostics.
Vulkan is Dusk's implemented native backend. The null backend remains a test path.
Native errors use typed error values and diagnostics.

The mutable `core.ErrorData` API remains available for synchronous callers.
`ErrorData.init` owns its message and copied context text.
Its failure cleanup frees all copied context text, including failures after earlier context copies.
Its optional backtrace remains borrowed.

#### 2.2.1 Owned diagnostic publication

`src/core/errors.zig` adds `ErrorDraft`, `ErrorReservation`, `ErrorRef`, and `ErrorView`.
`src/core/root.zig` exports these APIs.
These are original Dusk glue, not ports of Dawn functions.
These diagnostic components alone do not implement async requests, owned scopes, registries, or callbacks.
The native owned-scope stack retains `ErrorRef` diagnostics and pending-task leases (`src/core/error_scope.zig:71-95,582-606`).
Current native async source and exercised consumer status are in §3.2 and `docs/50-verification.md`.

`ErrorDraft` singly owns mutable payload storage and records its payload allocator.
`init` copies table-based diagnostics. `initMessage` copies an exact message and its context.
`fromOwned` moves an existing `ErrorData` without copying its bytes.
`discard` frees a losing draft once. Copies are not independent owners.

`ErrorReservation.prepare` allocates a stable header with a separate recorded allocator.
`reserveReferences` prepays additional reference slots without allocation.
`seal` consumes the reservation and draft without allocation or failure.
It clears the borrowed backtrace before publication.
The caller must synchronize publication before readers access the sealed payload.

`sealOutOfMemory` uses static host-OOM text.
`sealDeviceLostFallback` preserves the supplied loss code when copying the first loss message fails.
`sealNativeError` uses compiler-static `@errorName` text from a finite native error set.
These seal paths allocate no payload storage.

`ErrorRef.view` returns an `ErrorView` with const message and context slices.
The view borrows storage through the caller-held reference. It never owns a trace.
`retain` uses at most 64 strong-CAS attempts.
Overflow or contention returns a typed error without creating a reference.
Retain belongs before an infallible terminal claim.
Copies consume prepaid slots or require a successful retain.
`releaseMany` consumes a nonzero number of caller-owned slots, including unused prepaid slots.
The last release frees the payload and header exactly once with their respective allocators.
Both allocator backing states must remain live through that release.

BG133 exercised this component through `core/root`: 15/15 tests in Debug and 15/15 in explicit ReleaseSafe.
The recorded run exited 0 in 38.99 seconds, with ten new ownership tests and five existing tests.
This result does not establish native consumer integration or a full gate.

#### 2.2.2 Shader diagnostic ownership

`src/pipeline/shader_compilation_messages.zig` defines immutable `Message` records and the owning `Messages` container.
`shader_module.getCompilationInfo(module)` returns a borrowed `Messages` view, not a new owner.
Its item array and text remain valid only until `ShaderModule.destroy`.
Do not call `deinit` on that view.
The synchronous borrow does not implement Dawn's future or callback contract.
Native async completion now uses `native_async_scope_info.getCompilationInfo` and the separate typed `Device.getCompilationInfoAsync` observer.
The accepted operation owns a snapshot. Callback views borrow through return, while typed results require `deinit`.

`shader_compilation_messages.snapshot(allocator, source)` copies a `[]const Message`.
`Messages.clone(allocator, source)` copies a `Messages` record.
`shader_module.snapshotCompilationInfo(allocator, module)` copies the module's diagnostics.
These helpers are original Dusk glue, not additional Dawn function ports.
Each result owns its item array and all diagnostic text, independent of the source lifetime.
Copies preserve every message type and byte/UTF-16 position field.
Empty text becomes `""` without retaining a source pointer.
Nonempty records use one item allocation and at most one contiguous text allocation.
An empty record allocates nothing.

Keep the source alive and unchanged through the copy.
Release each result once with `Messages.deinit`.
Assignment aliases storage and does not create another owner.
The result's allocator backing state must outlive that release.
Allocation failure or checked-size overflow returns `error.OutOfMemory`, frees partial storage, and leaves the source unchanged.

`shader_compilation_messages.one` owns its item array but borrows the supplied message text.
Its caller keeps that text alive and unchanged until release.
`shader_module.createErrorShaderModule` instead snapshots `ErrorModuleDescriptor.message` into module-owned diagnostic storage.
The caller may change or release the input text after construction returns.
This contract owns diagnostic text, not the descriptor's optional label.
Module destruction frees the diagnostic array and copied text.

BG138 exercised the published-root shader-module shard: 4/4 Debug build steps and 14/14 tests, plus 14/14 explicit ReleaseSafe tests.
The recorded run exited 0 in 67.11 seconds.
Seven new tests cover text ownership, source-array overwrite, module destruction, cloning, borrowed-builder cleanup, and allocation-failure rollback.
This bounded result does not establish public async completion, native GPU consumer integration, or a full gate.

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

**Generated callback-info contract.** The pinned revision is `32f77c02294310054a660c393feded4bcb3f203c`.
The generated API preserves each callback-info argument as a record value named `callback_info`.
The record stays last and outside grouped options.
Its schema fields and synthetic Zig `userdata` remain together.
`tools/gen_api.zig.emitCallbackFunction` renders the schema's `callback function` category with the default native Zig calling convention.
Each callback retains its existing synthetic userdata-first parameter.
Callback functions, enclosing generated methods, and the procedure table do not promise Dawn's C ABI.
The native convention permits the projected Zig slices and object values in callback signatures.
This mapping belongs to Dusk's generator, not Dawn's native implementation.

The following paths are relative to the pinned Dawn checkout.
Native signatures receive the corresponding `WGPU*CallbackInfo` by const reference.
Zig passes its existing callback-info record by value.

| Method | `src/dawn/dawn.json` argument | Native record signature |
| --- | --- | --- |
| `Adapter.requestDevice` | `:163-165` | `src/dawn/native/Adapter.h:68-69` |
| `Buffer.mapAsync` | `:660-662` | `src/dawn/native/Buffer.h:198-202` |
| `Device.createComputePipelineAsync` | `:1365-1367` | `src/dawn/native/Device.h:282-286` |
| `Device.createRenderPipelineAsync` | `:1401-1403` | `src/dawn/native/Device.h:282-286` |
| `Device.setLoggingCallback` | `:1584-1586` | `src/dawn/native/Device.h:328-330` |
| `Device.popErrorScope` | `:1598-1600` | `src/dawn/native/Device.h:328-330` |
| `Instance.requestAdapter` | `:2722-2724` | `src/dawn/native/Instance.h:82-83` |
| `Queue.onSubmittedWorkDone` | `:3065-3067` | `src/dawn/native/Queue.h:78-79` |
| `ShaderModule.getCompilationInfo` | `:3859-3861` | `src/dawn/native/ShaderModule.h:417` |

Five descriptor fields also retain their schema names and callback-info record types.
Device loss and uncaptured error fields come from `src/dawn/dawn.json:220-223`, including the generated device-descriptor chain copy.
Cache load and store fields come from `src/dawn/dawn.json:310-313`.
The host-pointer disposal field comes from `src/dawn/dawn.json:2048-2057`.
Nullable callbacks inside these records retain typed `null` defaults.
No global userdata or separate callback registration substitutes for these records.
Native events consume record mode, callback, and userdata at `src/dawn/native/Buffer.cpp:296-305`,
`src/dawn/native/CreatePipelineAsyncEvent.cpp:91-118`, and `src/dawn/native/Queue.cpp:193-211`.
This generated contract does not establish an implemented async runtime.


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

**Implemented worker pool.** `src/platform/threads.zig` owns a fixed set of
`std.Thread` workers and uses `std.Io.Mutex` and `std.Io.Condition` for synchronization.
The default worker count is two. Its bounded queue holds at most 4096 tasks.
Tasks run only on worker threads, never inline on the submitting thread.
This is not an `Io.Threaded` pool or an implemented public async runtime.

`postTask` accepts a task only after it acquires the mutex and checks the pool state and queue capacity.
It returns `Canceled`, `PoolShutDown`, `WorkerExhausted`, or `TaskQueueFull` before acceptance.
A rejected task does not borrow its context or `Io` backend state, or enter the queue.
A successful post copies the exact supplied `Io` into `QueuedTask` and borrows its backend state and the caller-owned context.
`Task.run` receives that same `Io`, not the worker synchronization `Io`.
The caller keeps the task context and its `Io` backend state alive until `Task.run` returns.

`join` and `deinit` stop acceptance, drain every accepted task, and join every worker.
Shutdown does not cancel queued tasks or free their contexts.
Worker synchronization and shutdown synchronization are uncancelable.
`init` passes its `Io` explicitly to each worker's thread entry for synchronization.
The caller keeps that `Io` backend state alive until `join` returns.
Neither task execution nor worker synchronization uses a global or pool-stored `Io` fallback.
Canceled `Io` therefore does not abandon accepted work.
See §9.3 for the normal loop bound and accepted queued tail.

The `std.Io.Future` examples below are design sketches, not exact current entry-point signatures.
Their scheduling and cancellation behavior must not be applied to the worker-pool task itself.

**Runtime status.** All eight generated callback-future starts have native callback bridges and separate typed `std.Io.Future` observer routes.
They cover adapter/device requests, map, queue completion, compute/render pipeline creation, scope pop, and compilation info.
`Device.getLostFuture` accesses the loss Future reserved during device creation. It does not start a ninth operation.
Logging registration is callback control, not a future start.
The registry owns callback modes, completion, cancellation, and late-result disposal (`src/engine/async_registry.zig`).
Typed cancellation abandons observation, not accepted work.
The high Device occupies its final owned address before async publication.
Generated ProcTable types do not establish a complete C dispatch table, wire support, or the browser forwarder.
`docs/50-verification.md` separates this source inventory from the six-family Debug/ReleaseSafe external smoke.

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

**Proposed future cancellation.** This is not cancellation of an accepted `WorkerPool.Task`.
`Future.cancel(io)` at `lib/std/Io.zig:1191` asks the
task to return `error.Canceled` at its next cancelation point. Dawn has no
equivalent on the path that matters. `PostWorkerTask` returns a
`std::unique_ptr<WaitableEvent>` whose only operations are `Wait` and
`IsComplete` (`src/dawn/platform/WorkerThread.h:93`, implemented at
`src/dawn/platform/WorkerThread.cpp:36-45`); it has no cancel.
`PostWorkerJob` returns a `JobHandle` that does have `Cancel`
(`src/dawn/platform/WorkerThread.h:95`, `src/dawn/platform/WorkerThread.cpp:50-59`),
but a `JobHandle` is a long-running loop rather than one task, and neither is
reachable from a `Future`. A Dawn future cannot be withdrawn.
Native typed observers now expose cancellation without withdrawing accepted work.

### 3.3 The decision record

**Priority.** Safety and determinism. `AGENTS.md` §3 orders it that way, and a
deterministic test is a hard requirement there.

**Constraint.** `AGENTS.md` §3: "`io` threaded explicitly, never global. Every
function that can block or perform I/O takes `io` as a parameter." Dawn's
`EventManager` is documented at `src/dawn/native/EventManager.h:59` as a
"Subcomponent of the Instance" and is reached through `InstanceBase`, which is
exactly the hidden state the house rule forbids.

**Cost imposed on consumers.**

- The proposed async API takes `io` and returns a `std.Io.Future`.
  The consumer must await or cancel it to release task resources.
  `Io.Group`'s doc comment at `lib/std/Io.zig:1215-1217` states this resource obligation.
- The `Io` value is threaded through call sites that do no I/O themselves. That
  is the price of the no-global rule.
- An accepted worker task borrows its context until `run` returns.
  The consumer must keep that context alive through task completion.
  `join` establishes completion for every accepted task.

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

The proposed future design uses `Io` cancellation and composability.
It does not establish implemented `mapAsync` or pipeline-request completion behavior.
Accepted worker tasks have no cancellation disposer and must run to completion.

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
| `LinkedList<T>` (`common/LinkedList.h`, 268) | 268 | `std.SinglyLinkedList` / `std.DoublyLinkedList` | stdlib | `lib/std/std.zig:26` and `:10`. Dusk does not copy Dawn's `ApiObjectBase` list implementation (`src/dawn/native/ObjectBase.h:147`). The core object list still tracks arena objects. `native_resources.destroyAll` walks that list. |
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

The port replaces the virtual eviction hook with caller-owned cleanup.
Its live LRU consumer is `FramebufferCache`
(`src/engine/framebuffer_cache.zig:155,231-249`).
That caller creates entries on misses and sends evicted handles to a fenced
destruction callback.
Dawn also uses its LRU for framebuffers
(`src/dawn/native/vulkan/FramebufferCache.h:95-100`).

`PipelineStore.pipeline_caches` declares a separate Vk-driver cache map
(`src/pipeline/pipeline.zig:673-674`).
It has no producer or create-path consumer. Teardown only destroys stored
entries (`src/pipeline/pipeline.zig:688-704`).
The declaration does not establish an implemented Vk driver cache.
Driver-cache persistence remains an optional, unimplemented optimization.

This sketch describes the container policy, not the current implementation.
The implementation is `src/pipeline/cache.zig:238-415`.

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

The implementation scans entries to find the oldest one
(`src/pipeline/cache.zig:388-397`).
Eviction uses `swapRemove` and repairs the index (`:378-385,400-412`).
Dawn stores recency in a `std::list`
(`src/dawn/common/LRUCache.h:159-165`).
The port retains linear eviction to avoid a separate intrusive list.
This is a design choice, not a measured performance advantage.
Framebuffer use does not imply one access per pipeline creation.
`docs/50-verification.md` owns any future measurement.

The pipeline object map and shader digest have separate roles.
`CacheKey.contentHash` uses Wyhash to select map buckets
(`src/pipeline/cache_key.zig:109-115`).
Shader words use stdlib SHA3-256
(`src/pipeline/shader_module.zig:275-284`).
Neither implements SHA3-224 persistent artifact validation.
Dawn uses SHA3-224 for BlobCache validation
(`src/dawn/native/BlobCache.cpp:46-50`).

**Native SPIR-V stage constants.** `StageInput.constants` borrows a slice of `api.ConstantEntry`, with `f64` input values.
The default is an empty slice.
Keep the slice, its keys, and shader content live through the synchronous pipeline call.
Compute, vertex, and fragment stages use the same normalization contract.
This native API does not implement generated WebGPU Device ABI entry points or async pipeline creation.
It does not parse WGSL or establish rules for uninitialized WGSL overrides.

`StageInput.content_bytes` supplies authoritative metadata for every compute pipeline, even without constants.
Graphics stages decode and reflect these bytes when constants are nonempty.
The path uses `wordsFromBytes`, validates the words, and reflects module-scope specialization constants.
Caller-supplied shader handles do not replace this metadata source.
The path validates and normalizes once, before cache lookup or native calls.
The same normalized payload supplies cache identity and Vulkan stage data.
Empty constants require no specialization normalization and pass a null `pSpecializationInfo`.
Compute still decodes and reflects the workgroup source, then validates its encoded default size.
The path does not rewrite caller shader words.

Keys accept canonical decimal `SpecId` strings, such as `"7"`, or unambiguous `OpName` aliases.
Aliases and numeric keys resolve to the same module-scope specialization ID.
Multiple shader result IDs can legally share one `SpecId`.
Reflection retains their aliases and independent encoded defaults.
Declarations with one specialization ID form one external value target, even when their scalar types differ.
The codec converts the requested `f64` value for every declaration, with each type's raw range checks.
It accepts the family only when every conversion produces the same payload size and bits.
Different payload sizes or bits return `AmbiguousConstant`.
Range and nonfinite failures retain their scalar errors.
An `OpName` shared by different specialization IDs also returns `AmbiguousConstant`.
Reflection does not require matching scalar types or encoded defaults.
Two caller entries that resolve to one specialization ID return `DuplicateConstant`, even when their values agree.
Unknown keys also fail validation.
This rejects duplicate caller entries, not legal shared-ID shader declarations.
See the [SPIR-V committee clarification, Registry issue 357](https://github.com/KhronosGroup/SPIRV-Registry/issues/357).
Vulkan `VkSpecializationInfo` VUID 04911 requires unique map-entry IDs, not unique shader result IDs.
Only directly decorated specialization constants accept external values.
Derived `OpSpecConstantOp` results do not become separate external IDs.
See [SPIR-V 1.6 §2.12 and §3.20](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#SpecializationSection).

| Scalar | Conversion from the finite `f64` input |
| --- | --- |
| Boolean | Zero becomes false. Any other finite value becomes true. Vulkan uses four-byte `VkBool32`. |
| Signed or unsigned integer | Widths 8, 16, 32, and 64 check the raw value against bounds before truncation toward zero. |
| Floating point | Widths 16, 32, and 64 check finite range before rounding to the destination type. |

The 64-bit integer upper bounds are exclusive to reject overflow.
Nonfinite values, out-of-range values, and unsupported scalar widths fail validation.
Malformed SPIR-V returns the existing `SpirvMalformed` error.
The specialization codec exposes named errors for key and scalar failures.
Invalid input fails even when an otherwise matching pipeline already exists in the cache.

Cache identity sorts entries by ID and records ID, scalar type, width, size, and little-endian value bits.
For shared-ID families, the codec selects the minimum canonical type tag and width.
This deterministic choice keeps numeric keys, aliases, and metadata order equivalent.
The canonical bytes contain no ABI padding.
Equivalent aliases, input order, and converted bits share a pipeline.
Different converted bits produce different keys.
Omission preserves encoded defaults. An explicit value equal to a default can still have a different key.

Vulkan receives native-endian values at packed byte offsets.
The map entries, data, and `VkSpecializationInfo` pointers stay valid through the native creation call.
They do not borrow transient loop-local stage data.
`spirv.reflect.Module.specialization_constants` owns its metadata array. Names borrow the shader words.
`ShaderModule` takes ownership of that array without a copy.

The nonempty codec uses three allocations: sorted scratch, map entries, and a payload buffer.
The payload buffer holds native and canonical views.
After scratch cleanup, the codec owns two buffers and releases each once during deinitialization.
The raw-handle path must decode and reflect every compute module and graphics modules with nonempty constants.
This is a cold-path cost description, not a measured speed or memory-performance claim.
`docs/50-verification.md` records reviewed compute runtime proof, current scoped verification, and the graphics proof limit.

**Phase-1 workgroup contract (source only).** M5 records `LocalSize`, `LocalSizeId`,
and `WorkgroupSize` builtin metadata per entry point. The builtin takes precedence.
The borrowed module words must remain immutable during resolution.
`Module.resolveWorkgroupSizeCanonical` uses the specialization codec's canonical bytes.
It does not convert scalar inputs again or rewrite shader words.
Its bounded evaluator rejects missing, unsupported, cyclic, malformed, or excessive dependencies.
It preserves signed two's-complement bit patterns.
Supported scalar integer arithmetic wraps at the component width.
Expression dependencies can use 8-, 16-, 32-, or 64-bit integers.
Final workgroup axes require 32-bit integers.
Opcode-specific rules determine valid operand types and widths.
Shift counts can have an independent integer width.
`UDiv` and `UMod` require the exact unsigned operand/result type.
Literal `LocalSize` zero is malformed. Evaluated zero reaches M14's `AxisZero` policy error.

M14 `prepareCompute` selects the `(name, .gl_compute)` pair before validation, keys, lookup, or native creation.
A same-name vertex entry does not hide a compute entry, in either declaration order.
A wrong-model error applies only when no matching compute entry exists.
The descriptor requires caller-supplied `ComputeLimits` from the selected or negotiated device.
The pipeline module has no engine dependency or default limit ceiling.
It checks nonzero dimensions, axis limits, checked product overflow, and the invocation limit.
`local_size_id_supported` defaults to false.
`EntryPoint.has_local_size_id` records mode presence independently of the effective builtin size.
M14 gates this presence before lookup or native creation, even when the builtin takes precedence.
Vulkan [VUID-RuntimeSpirv-LocalSizeId-06434](https://docs.vulkan.org/refpages/latest/refpages/source/RuntimeSpirv.html#VUID-RuntimeSpirv-LocalSizeId-06434)
requires enabled `maintenance4` whenever `LocalSizeId` is used.

The integer contract follows SPIR-V's
[integer types](https://registry.khronos.org/SPIR-V/specs/1.0/SPIRV.html#OpTypeInt),
[constant bit patterns](https://registry.khronos.org/SPIR-V/specs/1.0/SPIRV.html#OpConstant),
[addition operands](https://registry.khronos.org/SPIR-V/specs/1.0/SPIRV.html#OpIAdd),
[unsigned division](https://registry.khronos.org/SPIR-V/specs/1.0/SPIRV.html#OpUDiv),
and [shift operands](https://registry.khronos.org/SPIR-V/specs/1.0/SPIRV.html#OpShiftLeftLogical).
The [no-wrap decorations](https://github.khronos.org/SPIRV-Registry/extensions/KHR/SPV_KHR_no_integer_wrap_decoration.html#_decorations)
specify undefined behavior when their decorated operation wraps.
This evaluator adds no `NoUnsignedWrap` or `NoSignedWrap` validation policy.
Dependency decoding does not claim enabled native int8/int16/int64 features or full SPIR-V conformance.
M5's decoder and evaluator are new code, not ports of Tint's reflection functions.
Workgroup storage accounting, subgroup checks, and a public size getter remain open.
Public async creation, object-cache integration, platform execution, and persistence remain separate open groups.
Parent generation, builds, and runtime checks remain pending for phase 1.

**Native render-pipeline contract.** The current path uses a traditional compatible
render pass, not dynamic rendering.
`RenderPipelineDescriptor.compatible_render_pass` in `src/pipeline/pipeline.zig`
is required and borrowed through native creation.
The pass must have compatible attachment formats and sample count at subpass zero.
The raw handle is not part of cache identity.
`createRenderPipeline` rejects a null handle with `CompatibleRenderPassMissing`.

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

**The proc table.** `proc` is a generic function-pointer type with no arguments.
`get proc address` returns it. It is not the return type of every method.
The pinned Dawn template uses each method's declared return type
(`docs/02-dawn-design.md` §2).

`tools/gen_api.zig` uses `methodReturnType` for object methods and `ProcTable` fields.
The chosen native projection returns `void` when the JSON has no return declaration.
An explicit return becomes `errors.Error!T`, where `T` is the projected Zig type.
Structured return declarations preserve schema nullability.
A buffer return with `optional: true` becomes `errors.Error!?objects.Buffer`
in both object methods and procedure-table fields.
Mapped-pointer returns retain their existing single optional pointer, without a second optional layer.
These source-contract examples require parent regeneration and verification:

```zig
// Native Zig procedure-table field types.
buffer_destroy: *const fn (objects.Buffer) void,
adapter_get_instance: *const fn (objects.Adapter) errors.Error!objects.Instance,
adapter_get_limits: *const fn (objects.Adapter, *descriptors.Limits) errors.Error!enums.Status,
```

The table uses the native Zig calling convention, with no `callconv(.c)`.
Its arguments remain ungrouped, unlike object-method options structs.
`callbacks.Proc` remains `*const fn () callconv(.c) void`.
That individual type does not give the generated package a Dawn-compatible C ABI.
Generated descriptors, handles, slices, and error unions are native Zig contracts.
Dawn's C proc table is the upstream reference, not an ABI promise.

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

### 8.4 Canonical formats and typed block geometry

**Status.** Canonical formats, typed block geometry, and consumer migration have
landed and passed local behavior tests.
The aggregate includes eight format-shard tests and root format cases.
This does not establish support for every format on every device or a green final gate.
See `docs/40-plan.md` §M7 and `docs/50-verification.md` "Present implementation and evidence limits".

`FormatName` in `src/engine/format.zig` declares the canonical identity domain.
It carries 101 physical API formats and eight prefixed Dawn entries.
Undefined is separate and has no table slot. `FormatTable` has 109 rows.
`buildFormatTable(enabled, out)` takes runtime `FeaturesSet` membership and a
caller-owned `*FormatTable`. It allocates nothing and captures no device.
Static metadata remains comptime data. Feature-dependent capabilities do not.
There is no separate comptime-only `EnabledFeatures` type.
Consumers use this canonical table, not a second format identity domain.

`FeaturesSet` in `src/engine/features.zig` stores two `u64` words for 67
representable feature names.
`enable` and `isEnabled` operate on that domain.
`fromApiName` converts a typed API name before membership.
The implementation does not claim the upstream 91-name feature domain.
It has no string-by-name membership method or 91-row feature-info table.
`toSupportedFeatures` writes into caller-owned `[67]api.FeatureName` storage.

**Source identity.** These references use Dawn
`32f77c02294310054a660c393feded4bcb3f203c` at
`~/.cache/dusk-research/research/dawn`.
`src/dawn/dawn.json:4501-4508` lists eight raw Dawn values 0–7.
`src/dawn/native/dawn_platform.h:135-136` defines prefix `0x00050000` and mask
`0xffff0000`. `src/dawn/native/Format.cpp:172-198` maps prefixed formats after
the physical API formats.
The generator omits those eight names from `api.TextureFormat`.
They are canonical internal entries, not restored API aliases.

`computeFormatIndex` in `src/engine/format.zig` maps API identity to `?usize`.
`computeCanonicalFormatIndex` also handles the prefixed entries.
`fromApiFormat` widens retained API identity.
`toApiFormat` returns `UnrepresentableFormat` for a prefixed identity.
`UnsupportedReason` separates required features, compatibility mode, and excluded features.
`UnavailableFeature` names excluded planar and unorm16 gates.
Pixel-local-storage gates add no capability.
No retained feature with a colliding raw tag substitutes for an excluded feature.

**Aspect selection.** `Format.getAspectInfo` accepts API selection.
`getAspectInfoForAspect` accepts an internal aspect.
`AspectError` names `InvalidAspect`, `MultipleAspects`, and `AspectNotPresent`.
Stencil metadata retains slot 1. Stencil-only `aspectCount` therefore returns 2.
`sampleTypeBit` returns `UndefinedSampleType` for undefined selection.
`UnsupportedReason.format` writes through `*std.Io.Writer`.

**Native units.** `src/engine/block_info.zig` declares distinct `TexelCount`
and `BlockCount` structs, each with a `u64` value.
Typed origins and extents use those wrappers, not integer aliases.
Origins default to zero. Extents default to width 0, height 1, and depth 1.
Aggregate equality uses `std.meta.eql`, not aggregate `==` or invented wrapper methods.

`TypedTexelBlockInfo` stores byte size and typed texel geometry.
`fromTexelBlockInfo` imports untyped metadata.
`toTexelBlockInfo`, `TexelOrigin3D.toOrigin3D`, and `TexelExtent3D.toExtent3D`
reject API narrowing with `NarrowingOverflow`.
`toBytes` multiplies block count by bytes per block.
`bytesToBlocks`, `toBlockHeight`, and `toBlockWidth` require exact division.
`toTexelWidth` and `toTexelHeight` check multiplication overflow.
`ConversionError` names `InvalidBlockInfo`, `NonExactDivision`, and `Overflow`.
Zero metadata is unset and arithmetic rejects it.
Depth conversions are identities because blocks are two-dimensional.
Origin and extent conversions preserve depth.

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
    // Io is supplied by each operation, not stored.

    /// Illustrative recorded entry. Native lifetime admission is separate.
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

The recorded surface validates and appends commands.
Native resource creation instead calls synchronous factories.
`Device.wait(io, serial)` explicitly waits for GPU completion.
No enqueue-only rule covers every public entry.

**Current native operation safety.** The example above does not describe the complete native lifetime contract.
`src/engine/device.zig` pins each admitted operation before it accesses native context or waits for `DeviceMutex`.
`destroy` refuses active pins without changing ownership or admission.
A nonterminal completion failure keeps the stopped owner and GPU-referenced children live for a later retry.
Successful completion or terminal Vulkan device loss permits child-before-parent retirement.
Device loss supplies lifetime-only retirement permission, not a normal completed serial or valid readback.

`Device.getQueue(io)` returns `OperationError!QueueLease`, not a bare queue pointer.
The lease owns one device pin and the queue-operation gate. It stores no `Io`.
Do not copy the lease, move its device, or independently deinitialize its queue.
The queue borrow lasts until `lease.deinit(io)`.
That call publishes real low-level submissions, releases the gate and pin, and leaves the receiver readable.
Deinitialization is idempotent on the same lease, not on independent copies.
High-level submit, unmap, and release refuse a live lease.

BG134 passed 10/10 native safety tests in Debug and explicit ReleaseSafe, with exit 0 in 113.56 seconds.
The five original BG131 regressions now pass, alongside queue-lease, loss, idle-failure, and mutex-wait pin tests.
This component result alone does not establish native consumer integration, async Phase 3, or a full gate.

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

**Implemented substrate.** `src/platform/threads.zig` defines `Task` and `WorkerPool`.
The pool owns two workers by default and allows one through eight workers.
Its fixed queue holds at most `max_queued_task_count` (4096) tasks without allocation.
The intended jobs are SPIR-V validation and requested asynchronous pipeline creation.
This pool does not establish that those public async entry points exist.

`Task.run` has type `*const fn (io: std.Io, context: *anyopaque) void`.
`Task` also contains the borrowed context pointer.
The submitter owns the context and keeps it alive until `Task.run` returns.
Tasks run on pool threads, never on the submitting thread.
`postTask` returns `Canceled` if mutex acquisition fails.
Under the mutex, it rejects shutdown, worker exhaustion, and a full queue before acceptance.
Those failures return `PoolShutDown`, `WorkerExhausted`, and `TaskQueueFull`, respectively.
A failed post creates no borrow of the task context or `Io` backend state.
An accepted post copies the exact supplied `Io` and task into `QueuedTask` and increments the posted count.
The worker calls `queued_task.task.run(queued_task.io, queued_task.task.context)` outside the pool lock.
The submitter keeps that `Io` backend state alive until the callback returns.
The queued `Io` value does not transfer ownership of its backend state.

`init` passes its `Io` explicitly to each worker's thread entry for worker synchronization.
The caller keeps that synchronization `Io` backend state alive until `join` returns.
The worker does not substitute its synchronization `Io` for the task's `Io`.
Neither path uses a global or pool-stored `Io` fallback.

`join` and `deinit` stop acceptance before they join the workers.
Workers continue to execute accepted queued tasks after shutdown or exhaustion.
They increment the completed count only after `run` returns.
When `join` returns, every accepted task has returned and every worker has joined.
Shutdown neither frees caller-owned contexts nor abandons queued tasks.
Worker waits, queue access, completion accounting, and shutdown use uncancelable synchronization.
Canceled `Io` cannot bypass this accepted-task drain.
The drain depends on each task returning. It does not interrupt a task that fails to return.

Each worker has a normal bound of `max_worker_iteration_count` (`1 << 24`) loop iterations.
At that bound, the worker sets `worker_exhausted` under the mutex before it drains the queued tail.
All later posts fail before acceptance.
The queue then contains at most `max_queued_task_count` tasks.
Each worker allows at most that many additional iterations to drain accepted work.
The total per-worker bound is the normal bound plus the queue bound.
This is a runaway guard, not an accepted-task quota.
Shutdown and exhaustion end a worker only after the queue is empty.

Dawn's pool defaults to two workers (`src/dawn/platform/WorkerThread.h:87-89`).
Dawn validates shaders on the calling thread
(`src/dawn/native/SpirvValidation.cpp:37-79`).
Moving validation onto this pool remains separate from its implemented acceptance and drain contract.

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
- `postTask` rejects work before acceptance when the queue is full or the pool has stopped accepting tasks.
  The caller must handle rejection and retain ownership of its context.
- Shutdown waits for every accepted task to return.
  The caller must keep borrowed contexts alive until completion, including during shutdown.

**Counterchoice.** Use `Io.Threaded` task scheduling instead of a fixed `std.Thread` pool.
`Io.async` can run a task inline when its concurrency limit is reached.
`Io.concurrent` can instead return `ConcurrencyUnavailable`.
Neither behavior is the implemented bounded queue contract.

The port uses `std.Thread` workers with explicit `io` for synchronization.
This preserves worker-only execution and drains caller-owned borrowed contexts before shutdown returns.
It does not add cancellation of accepted tasks.

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

### 11.1 General reference counting for generated handles

**Alternative.** A `Ref<T>` equivalent with intrusive counts, `retain`, and `release` on every generated handle.
This rejected alternative does not prohibit the typed native facade's dependency counts, operation pins, or explicit payload release.

**Why it lost.** `AGENTS.md` §3 requires a failure to be injectable and a module
to be deterministically drivable; a refcount bug is a use-after-free that a
`checkAllAllocationFailures` run does not catch. Dawn's own record shows the
cost: the `DeleteThis` override contract at
`src/dawn/native/ObjectBase.h:176-186`, and the `LockAndDeleteThis` variant at
`:188` that some classes must also override. The arena has no such invariant.

**What would change the answer.** A requirement for retained host objects after device teardown, or measured excess host-storage growth.
Current native payload release does not provide that retained-host-object contract.
See §1.1 and §1.2 for the separate native ownership policy.

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

### 11.9 `Io.Threaded` scheduling instead of the fixed worker pool

**Alternative.** Schedule tasks through `Io.async` or `Io.concurrent` instead of the queue in `src/platform/threads.zig`.

**Why it lost for the worker substrate.** `Io.async` can run tasks inline.
`Io.concurrent` rejects work when it cannot supply concurrency.
The implemented pool instead queues accepted tasks and executes them only on worker threads.
Its explicit shutdown protocol drains borrowed contexts through `run` return.
It uses `Io` synchronization without canceling accepted tasks (§9.3).

**What would change the answer.** A public async design could use `std.Io.Future`.
That design remains separate from the implemented worker acceptance and shutdown contract (§3.2).

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
