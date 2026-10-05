# 02 — The Dawn codebase, mapped

Upstream is `google/dawn`, pinned at **`32f77c02294310054a660c393feded4bcb3f203c`**
(2026-10-03, `main`), read-only at
`/tmp/scratch/research/dawn`.

Every claim below cites `path:line` in that tree, or a command whose output is
quoted. Where a fact came from a count, the command is given. Where something is
not known, it says so and names what would settle it.

This document is the evidence base. `docs/30-port-design.md` and
`docs/40-plan.md` cite it and add no new upstream claims.

**What this document does not claim.** It claims no timing, throughput or
memory figure for Dawn; none has been measured. It claims no behaviour at any
revision other than the pin. Line and site counts are `wc -l` and
`git grep -o` over named files or globs, and each says which; a count taken
over a different set is a different number, not a rounding of this one.

---

## 1. Shape of the tree

Measured over the `.cc`, `.h` and `.cpp` files `git ls-files` reports for each
directory: lines are `wc -l` over those blobs, files are the blob count.

| Directory | Lines | Files | What it is |
| --- | ---: | ---: | --- |
| `src/tint` | 753,961 | 1,798 | **Vendored, not a submodule**: `.gitmodules` has no `src/tint` entry and `git ls-files src/tint` returns 2,232 tracked files. WGSL front end plus five back ends. **Out of scope.** |
| `src/dawn/tests` | 210,010 | 405 | googletest suites. Not ported; its *infrastructure* is. |
| `src/dawn/native` | 153,947 | 645 | The engine. Front end plus seven back ends. |
| `src/dawn/native/vulkan` | 27,763 | 102 | The only back end being ported. |
| `src/dawn/native/d3d12` | 19,470 | 82 | Skipped. |
| `src/dawn/native/d3d11` | 13,091 | 51 | Skipped. |
| `src/dawn/native/opengl` | 12,298 | 65 | Skipped. |
| `src/dawn/native/d3d` | 3,593 | 30 | Headers `d3d11` and `d3d12` share. Skipped. |
| `src/dawn/native/metal` | 2,039 | 23 | Skipped. |
| `src/dawn/native/null` | 1,019 | 3 | The smallest complete back end (§3). The port's template. |
| `src/dawn/common` | 11,229 | 83 | Platform-agnostic C++ foundation. |
| `src/dawn/wire` | 9,581 | 68 | Cross-process client/server split. Deferred. |
| `src/dawn/native/webgpu` | 8,935 | 54 | "WebGPU on WebGPU" forwarder. Skipped. |
| `src/dawn/utils` | 5,187 | 30 | Embedder, test and sample helpers. Optional. |
| `src/dawn/replay` | 3,733 | 16 | Capture/replay. Deferred. |
| `src/dawn/platform` | 854 | 8 | Embedder seam. Mostly dead code. |
| `src/dawn/partition_alloc` | 760 | 3 | A shim that collapses to `?*T`. Nothing to port. |

`src/dawn` alone is 420,338 lines in 1,359 files. `src/dawn` plus `include/dawn`
plus `include/webgpu` is **422,739 lines in 1,384 files**. The Vulkan-only port
reads the top-level `src/dawn/native` files (64,192), `src/dawn/native/vulkan`
(27,763), `src/dawn/native/stream` (1,013) and `src/dawn/native/utils` (534),
`src/dawn/common` (11,229) and `src/dawn/platform` (854). The six skipped back
ends — `d3d12`, `d3d11`, `metal`, `null`, `opengl`, `webgpu`, plus the `d3d`
headers they share — are 60,445 lines and are read by nobody.

---

## 2. The single most important structural fact

`src/dawn/dawn.json` is **199,060 bytes of flat JSON describing the entire public
API**, and it is the *only* source of truth for it. Python plus Jinja2 renders it
into the C header, the C++ header, the proc table, the wire client and server,
the gmock mock, and the emdawnwebgpu bindings (`generator/dawn_json_generator.py`,
2,272 lines; templates under `generator/templates/`).

Counted with a Python one-liner over the parsed JSON:

- **347 API objects**: 181 `structure`, 65 `enum`, 28 `object`, 18 `native`,
  14 `callback function`, 14 `callback info`, 12 `constant`, 6 `bitmask`,
  5 `function`, 4 `function pointer`.
- **205 methods**, **571 members**.
- Object-level keys in use: `category` (347), `members` (195), `tags` (135),
  `chained` (88), `chain roots` (88), `extensible` (73), `values` (71),
  `methods` (28), `args` (23), `no autolock` (7), `out` (3),
  `is nullable pointer` (2), `wire transparent` (1).

The generated C header carries **266 `WGPU*` free functions**: the 5
`function` entries, the 205 object methods, and 2 synthesised per object —
`add ref` and `release` — for 28 objects. No structure gets a `free members`
function at this revision, so `c_methods` yields nothing for them
(`generator/dawn_json_generator.py:1501-1511`,
`generator/templates/api.h:366-377`).

Sample of the schema (`src/dawn/dawn.json`, `buffer descriptor`):

```json
{ "category": "structure", "extensible": "in",
  "members": [ { "name": "label", "type": "string view", "optional": true },
               { "name": "usage",  "type": "buffer usage" },
               { "name": "size",   "type": "uint64_t" },
               { "name": "mapped at creation", "type": "bool", "default": "false" } ] }
```

**Consequence for the port.** The API surface is not something to transcribe by
hand. It is data. A Zig `comptime` generator that reads this JSON emits the
public types, the proc table and the mock. That is the difference between a
plan with 347 hand-written rows and a plan with one generator plus a 347-row
conformance table.

---

## 3. Layering

```
include/webgpu/webgpu.h                      <- 33-line shim, includes "dawn/webgpu.h"
   |  \
   |   +-- dawn/webgpu.h                      <- generated from dawn.json, C ABI
   |                                          266 WGPU* free functions (§2)
   |
include/dawn/native/DawnNative.h             <- second, Dawn-specific C++ ABI
   |
src/dawn/native/  Instance -> Adapter -> Device -> Queue -> CommandEncoder
   |                                    |
   |  ErrorSink / ErrorScope             |  CommandAllocator -> command stream
   |                                    v
   +-------------------------- BackendConnection (per back end)
                                     |
                    src/dawn/native/vulkan/  ->  VkInstance, VkDevice, VkQueue
```

There is **no `BackendBase` class** at this revision. The contract is one
abstract base per object (`DeviceBase`, `QueueBase`, `BufferBase`,
`TextureBase`, `SwapChainBase`, …), each with its own `*Impl` pure virtuals,
plus a trait-struct downcast layer. The smallest complete back end,
`src/dawn/native/null/`, is **1,019 lines, 62 `override` tokens of which 6 are
destructors, across 16 class definitions of which 10 declare overrides** — the
classes run from `DeviceNull.h:107` to `DeviceNull.cpp:142` — and one free
`Connect(InstanceBase*) -> BackendConnection*`. That is the template for the
first milestone and the size floor for a backend.

---

## 4. Subsystem findings

### 4.1 Object model and error propagation

`src/dawn/native/ObjectBase.h` (228 lines) layers three things:

1. `ErrorMonad` — embeds error state in the reference-count payload.
2. `ObjectBase` — adds the owning device.
3. `ApiObjectBase` — adds a label, an intrusive list node, a virtual
   `DestroyImpl`, and a `DeleteThis` override.

Reference counting is intrusive and packs **two payload bits into the refcount
word** (`src/dawn/common/RefCounted.h:1`, 107 lines). `Ref<T>` is a
zero-overhead smart pointer: `sizeof(Ref<T>) == sizeof(T)` is asserted
(`src/dawn/common/RefBase.h:1`, 207 lines).

Errors are values, not exceptions. `src/dawn/native/Error.h:43-50` defines
`InternalErrorType` as a bitmask — `None=0, Validation=1, BackendDeviceLost=2,
Unrecoverable=4, PipelineUncategorized=8, OutOfMemory=16` — and the result
aliases `MaybeError`, `MaybeValError`, `ResultOrError<T>`,
`ResultOrValError<T>`. `detail::ErrorAdapter` (`Error.h:181-224`) moves one
`ErrorData` and implicitly converts it to six different error types. The
macros are `DAWN_INVALID_IF`, `DAWN_VALIDATION_ERROR`,
`DAWN_UNRECOVERABLE_ERROR`, `DAWN_TRY`, `DAWN_TRY_ASSIGN`,
`DAWN_TRY_WITH_CLEANUP`, `DAWN_TRY_ASSIGN_WITH_CLEANUP`, and more.

**There is no message-id mechanism.** `src/dawn/native/ErrorData.h:1`
(111 lines) holds `mType`, `mMessage`, `mBacktrace`, `mContexts`,
`mDebugGroups`, `mBackendMessages` — a formatted string and a backtrace. No
identifier, no enum, no stable code. A Zig port gets to fix this for free:
a Zig error set *is* a stable, exhaustive, machine-checkable id.

### 4.2 `common/Result.h`

`src/dawn/common/Result.h` is **535 lines, 5 specialisations, a 2-bit tagged
pointer, and zero macros** (`Result.cpp`, 46 lines, `MakePayload`/`GetPayloadType`
on the low 2 bits). It is a sum type over `T` and an error, with the payload
packed next to the tag.

This is the one piece of `common/` that a Zig port should *not* reimplement in
the same shape. Zig's `!T` / `E!T` already is this, with the tag handled by the
language and the payload by the unwinder. The port's job is to map Dawn's
`InternalErrorType` bitmask onto three distinct Zig error sets (validation,
device-lost, unrecoverable) rather than to re-express `Result<T>`.

### 4.3 Command path

`src/dawn/native/Commands.h:55-94` is a **38-value `Command` tag enum**, each
value paired with a POD struct. The stream is a 4-byte tag then the struct,
each rounded up to `kMaxAllocatedCommandAlignment = sizeof(uint64_t)`
(`CommandAllocator.h:97`), so the per-command overhead is the tag plus up to
7 bytes of padding. There is no per-type size table; `Commands.cpp` carries an
exhaustive `FreeCommands` (`:43`, 38 cases) and `SkipCommand` (`:259`, 38
cases) switch.

The encoder hierarchy is **not** virtual-heavy: `CommandEncoder` is separate,
and `ProgrammableEncoder` is the shared pass base for `RenderPassEncoder` and
`ComputePassEncoder`. Only `GetType`, `DestroyImpl` and the destructor are
overridden.

`CommandBufferStateTracker` (`CommandBufferStateTracker.h:1`) is a six-aspect
bitmask used only for lazy *validation* — the Vulkan backend has its own
dirty-bit trackers for elision. Validation is a runtime atomic flag, never
compiled out.

### 4.4 Execution, tick and events

One serial GPU timeline owned by `ExecutionQueueBase` (an atomic
last-submitted versus a condvar-protected completed serial). Frontend commands
are recorded into a `CommandAllocator` block arena and replayed into native API
calls at submit — for Vulkan, `CommandBuffer::RecordCommands` at
`src/dawn/native/vulkan/CommandBufferVk.cpp:1132-1559`, a 428-line function.

Completion flows GPU fence → `UpdateCompletedSerialTo` (processors, then tasks)
→ `Queue::Tick` → `CallbackTaskManager` → the application thread.

**Threading inventory — the whole of it:** exactly one thread pool,
`AsyncWorkerThreadPool` (`src/dawn/platform/WorkerThread.h:1`, default 2 threads),
used for async pipeline compilation. There are no fence-poll threads. The files
`FenceMonitor.h`, `Serial.h`, `Timeline.h`, `Executor.h` and `Processor.cpp`
**do not exist at this revision** — that was checked and is recorded here
because an older description of Dawn names them.

`DynamicUploader` uses **4 MiB ring buffers** with a 16 MiB submit threshold
(`DynamicUploader.cpp`).

### 4.5 Memory

There is no `MemoryAllocator.h`, `Memory.h`, `StagingBuffer.h`, `BufferBase.h`
or `TextureBase.h` at this revision; those names were renamed. The real stack,
from `ResourceMemoryAllocatorVk.cpp:49-344` upward, is:

```
vkAllocateMemory
  -> SingleTypeAllocator          (8 MiB heaps, per memory type)
  -> PooledResourceMemoryAllocator(LIFO deque pool + size tracker)
  -> BuddyMemoryAllocator         (power-of-two + refcount)
  -> BuddyAllocator               (offset tree, 282 lines)
  -> ResourceMemoryAllocation     (offset, method, requested size, lazy flag)
  -> vkBindBufferMemory
```

**Dawn does not use VMA.** Verified: `grep -rn 'VulkanMemoryAllocator\|VmaAllocator'
--include=CMakeLists.txt src/ third_party/CMakeLists.txt` returns nothing.

Upload path: `Buffer::WriteBuffer` → `UploadData` (`Buffer.cpp:1183`) →
`DynamicUploader` 4 MiB ring → `memcpy` → `DeviceVk.cpp:796`
`CopyFromStagingToBuffer` → reclaim on the completed serial.

### 4.6 Vulkan backend

102 `.cc`/`.h`/`.cpp` files, 27,763 lines. Key entries:

| Concern | File | Lines |
| --- | --- | ---: |
| Backend / instance / adapter discovery | `BackendVk.cpp` | 646 |
| Device, tick, staging copy | `DeviceVk.cpp` | 1,339 |
| Queue, fence recycling, submit | `QueueVk.cpp` | 540 |
| Command recording | `CommandBufferVk.cpp` | 2,167 |
| Buffer | `BufferVk.cpp` | 898 |
| Texture | `TextureVk.cpp` | 2,309 |
| Memory allocator | `ResourceMemoryAllocatorVk.cpp` | 386 |
| Vulkan loader | `VulkanFunctions.cpp` + `.h` | 909 |

Required Vulkan version is **1.1** (`src/dawn/native/vulkan/BackendVk.h:53`,
`kRequiredVulkanVersion = VK_API_VERSION_1_1`).

`Backend::DiscoverPhysicalDevices` walks an ICD list in *fallback-first* order
and creates **one `VkInstance` per ICD**
(`src/dawn/native/vulkan/BackendVk.cpp:576`) so unused ones can be released.

### 4.7 The Vulkan loader — hand-rolled, no volk

`src/dawn/native/vulkan/VulkanFunctions.cpp:92` opens `libvulkan.so.1` through
`src/dawn/common/DynamicLib.cpp`, resolves `vkGetInstanceProcAddr`, then fills a
three-tier function-pointer struct in stages:

- `LoadGlobalProcs` — `vkCreateInstance`,
  `vkEnumerateInstanceExtensionProperties`,
  `vkEnumerateInstanceLayerProperties`, and optionally
  `vkEnumerateInstanceVersion` (allowed to be null on Vulkan 1.0).
- instance tier, via `vkGetInstanceProcAddr(instance, …)`.
- device tier, via `vkGetDeviceProcAddr`.

A missing global proc is a hard `DAWN_UNRECOVERABLE_ERROR`; a missing device
proc is tolerated by macro (`GET_INSTANCE_PROC_NO_ERROR_BASE` vs
`GET_INSTANCE_PROC_BASE`).

`grep -rn 'volk' --include=CMakeLists.txt .` returns **nothing**. Dawn does not
use volk, and neither should the port.

### 4.8 Validation

There is **no `src/dawn/native/validation/` directory and no `*Validator*` file**
at this revision. Validation is hand-written, co-located free functions named
`ValidateXxx` in the same `.cpp` as the code they validate, returning
`MaybeValError` / `ResultOrValError<T>`. Rules are `DAWN_INVALID_IF` /
`DAWN_VALIDATION_ERROR` calls: **772 sites** across the top-level `.cpp` and
`.h` of `src/dawn/native`, and **975** across the whole of it, the skipped
back ends included. The port's own inventory is the **865** that remain once
they are excluded: 772 top level, 91 in `vulkan`, 2 in `stream`. Both figures
count the tokens of
`git grep -o -E 'DAWN_INVALID_IF|DAWN_VALIDATION_ERROR' 32f77c0 --
'src/dawn/native/*.cpp' 'src/dawn/native/*.h' | wc -l`, the top-level count
taking a `:(glob)` pathspec.

There is no rule generator and no message-id mechanism (see 4.1). Switching is
runtime-only: `DeviceBase::IsValidationEnabled()` reads `Toggle::SkipValidation`.

Stateful validation is six named machines: `RenderPassValidationState`,
`AttachmentState`, `CommandBufferStateTracker`,
`SyncScopeUsageTracker`/`Compute`/`RenderPassResourceUsageTracker`,
`BindGroupTrackerBase`, `IndirectDrawMetadata`. Bind-group compatibility is a
`PipelineCompatibilityToken` (a `u64` id), not a class.

**Consequence.** A Zig port must *write* the rules rather than translate a rule
table, but it should give each rule a stable identity, which upstream lacks.
Dawn's 865 call sites are the inventory the port starts from; the message ids
are ours to invent.

### 4.9 Pipelines, shaders, and the SPIR-V seam

This is the most consequential finding for scope.

**Dawn does not pass caller SPIR-V through to Vulkan.** It round-trips:
SPIR-V → Tint IR → WGSL → `tint::Program` → lowered IR → regenerated SPIR-V,
then always calls `vkCreateShaderModule` on the *regenerated* words
(`src/dawn/native/vulkan/ShaderModuleVk.cpp:130-532`, `GetHandleAndSpirv`).
The `#else` branch at `:529` returns an unrecoverable error; **there is no
pass-through branch**.

Reflection is not derived from parsing SPIR-V either. It is read out of the
WGSL-side `tint::Program` by `tint::inspector::Inspector`
(`src/dawn/native/ShaderModule.cpp:1314-1352`).

The only SPIRV-Tools use in `src/dawn` is validation:
`src/dawn/native/SpirvValidation.cpp:37-79` builds a `spvtools::SpirvTools`
with `SPV_ENV_VULKAN_1_1_SPIRV_1_4`, calls `SetMessageConsumer` and `Validate`,
and `Disassemble`s on failure. **No optimiser, no legalisation.** The
legalisation-like passes (`SplitCombinedImageSamplerPass`,
`ResolveBindingConflictsPass`) live inside Tint's SPIR-V *reader*, not in
`src/dawn`.

Caching is three-tier: `ObjectContentHasher`/`HashCombine` for an in-memory
content hash; a SHA3-256 `ShaderModuleHash` for shader identity; and a
`StreamIn`-serialised `CacheKey` byte blob for persistent keys. The in-memory
`ContentLessObjectCache` sets and `InternalPipelineStore` are **unbounded**, with
eviction only on object destroy.

**Consequence.** A Vulkan-only port that takes SPIR-V and hands it to
`vkCreateShaderModule` is *strictly simpler* than Dawn, owes nothing to Tint's
front end, and must reimplement exactly one thing Tint was hiding: **SPIR-V
reflection**. That is a SPIR-V binary parser plus `OpDecorate` /
`OpEntryPoint` / `OpName` interpretation, and it replaces the whole 754k-line
`tint` dependency.

### 4.10 Tint, deferred

`src/tint` is **753,961 lines**, vendored not submoduled. The WGSL front end is
a 1,427-line lexer (`lang/wgsl/reader/parser/lexer.cc`), a 3,556-line
recursive-descent parser (`lang/wgsl/reader/parser/parser.cc`), a 3,685-line
validator (`lang/wgsl/resolver/validator.cc`), a 2,371-line uniformity analysis
(`lang/wgsl/resolver/uniformity.cc`) and a 17,352-line generated intrinsic
table (`lang/wgsl/intrinsic/data.cc`). The SPIR-V back end has a 3,160-line
printer (`lang/spirv/writer/printer/printer.cc`) and a 43-transform raise
pipeline (`lang/spirv/writer/raise/raise.cc:75-302`); the SPIR-V *reader* is a
5,065-line binary parser (`lang/spirv/reader/parser/parser.cc`).

Not ported. See `docs/30-port-design.md` for the decision and the reflection
substitute.

### 4.11 `common/` inventory

86 tracked files, 11,762 lines; the `.cc`/`.h`/`.cpp` subset of §1 is 83 files
and 11,229. Families: `Result.h`; intrusive refcounting
(`RefCounted.h` 107, `RefBase.h` 207, `Ref.h` 93, `WeakRef.h` 150,
`WeakRefSupport.h` 93, `RefCountedWithExternalCount.h` 98); containers and locks
(`MutexProtected.h`, `LinkedList.h`, `LRUCache.h`, `SerialQueue.h`,
`SerialMap.h`, `SerialStorage.h`, `SlabAllocator.h`, `MemoryBlockAllocator.h`);
math (`Math.h` 185, `Algebra.h` 419, `ColorSpace.h` 320); OS glue
(`DynamicLib.cpp`, `SystemHandle.h`, `AlignedAlloc.h`, DRM/Win32/IOSurface
helpers); and X-macros (`Preprocessor.h`, `Strings.h`, `Compiler.h`).

**There is no SIMD in `common/`, and no Dawn-owned string type.** For strings,
`common/` only has five `WGPUStringView` helpers
(`StringViewUtils.h:1`, 59 lines). Zig's `[]const u8` replaces the lot.

### 4.12 Third-party volume

`third_party/CMakeLists.txt` wires Abseil, SPIRV-Headers, SPIRV-Tools,
Vulkan::Headers, Vulkan::Loader (fuzzers only), Vulkan::UtilityHeaders,
RenderDocApi and `dawn_khronos_platform`. **VMA is present in `third_party/` as
a directory but is not linked by any Dawn target.**

### 4.13 Wire and replay — deferred

`src/dawn/wire` is a transport-agnostic client/server split: a generated
client and server over `dawn_wire.json` (16 commands, 11 return commands),
object identity crossing as `(ObjectId, ObjectGeneration)`, bulk data bypassing
the command stream via `MemoryTransferService`, and oversized commands
fragmented by `ChunkedCommandSerializer`. `src/dawn/replay` is a two-stream
capture/replay library over an X-macro schema in
`src/dawn/serialization/Schema.h`.

Neither is needed for an in-process engine. Both are recorded here so the deferral
is a decision with a size behind it.

### 4.14 Test infrastructure

Dawn uses a vendored googletest/gmock plus three layers of its own:
`DawnTest.h` (adapter parameterisation + the deferred `Expectation` engine),
`AdapterTestConfig.h` (the per-adapter axis), and per-suite bases. Test binaries:
`dawn_unittests`, `dawn_end2end_tests`, `dawn_perf_tests`, `dawn_benchmarks`.

Three cross-cutting mechanisms a port must re-create: the **deferred
expectation** engine (`ExpectBuffer`, `ExpectPixel`, resolved at `TearDown`),
**per-adapter parameterisation**, and **skip predicates**
(`DAWN_TEST_UNSUPPORTED_IF`, `DAWN_SUPPRESS_TEST_IF`).

`white_box` differs from `unittests` only in intent: same binary, same sources,
reaching private state by including private headers.

### 4.15 Platform, tracing, partition_alloc

- `src/dawn/platform/` — one abstract base per concern
  (`Platform`, `CachingInterface`, `WaitableEvent`, `JobHandle`,
  `WorkerTaskPool`) with all-no-op defaults. `Platform::AddTraceEvent`,
- Tracing is 4 hand-written Perfetto categories
  (`platform/tracing/trace_categories.h:37-43`) and 39 distinct event-name
  literals across `src/dawn`. No generator. Metrics are 19 macros, all in
  `platform/metrics/HistogramMacros.h:40-147`, with no generated name table.
- `src/dawn/partition_alloc/` vendors 3 Chromium headers (760 lines, header-only)
  and by default uses **Dawn's own no-op implementation**, so the dependency
  collapses to `?*T`. Dawn never calls a PartitionAlloc API. **Nothing to port.**

---

## 5. Mobile and the compatibility profile

`src/dawn/dawn.json` carries the whole feature and limit contract.

Compatibility mode in Dawn is a **runtime derivation**, not a build flag: it is
the absence of the `core features and limits` feature, exposed as
`DeviceBase::IsCompatibilityMode()` and driven down three paths:

1. adapter selection, where `SortAdapters` at `Adapter.cpp:452` ranks by
   adapter type (`:471`) then backend type (`:485`), the latter Core → Compat →
   Testing (`:487`);
2. 12 `LIMITS_*` macro tables in `src/dawn/native/Limits.cpp:43-144` carrying
   36 distinct limit names over 47 tiered rows, plus per-stage compat columns;
3. explicit `IsCompatibilityMode()` checks in `BindingInfo.cpp`, `Pipeline.cpp`,
   `RenderPipeline.cpp`, `Texture.cpp`, `CommandValidation.cpp` and the
   `Format.cpp` capability table.

Concrete compat restrictions Dawn enforces, all quotable from those files:
per-stage `maxStorageBuffers`/`maxStorageTextures` in fragment and vertex;
no depth-texture use, no fine derivatives, and a texture+sampler combination cap
in shaders; `vertex_index`/`instance_index` as attributes; `depthBiasClamp`;
`sample_mask`; blending and interpolation limits; no cube-array texture views;
`viewFormat == format`; a single view per draw; and compressed-format copy
rejection.

Tint owns 23 WGSL language features and 15 extensions. Dawn gates them
per-instance through `GatherWGSLFeatures` (toggles + feature status + an
optional name blocklist, `dawn WGSL blocklist` in the JSON).

**This is the checklist the port's compatibility mode must reproduce.**

---

## 6. C++ facilities that force an API-design decision

| Upstream facility | Where | Why Zig needs a decision |
| --- | --- | --- |
| `Ref<T>` intrusive refcount with 2 payload bits | `common/RefCounted.h` | Zig has no refcounted smart pointer. Pointer + arena, or explicit `release()` discipline. |
| `Result<T,E>` tagged pointer | `common/Result.h` | Superseded by Zig's `!T`. Map `InternalErrorType` onto three error sets instead. |
| `ErrorAdapter` implicit 6-way conversion | `native/Error.h:181` | Zig has no implicit conversions. The call site must say which set it means. |
| `DAWN_TRY` / `DAWN_INVALID_IF` macros | `native/Error.h` | Becomes `try` and `if (…) return error.…`. A macro-per-error-message becomes a typed error plus a message table. |
| Intrusive `ObjectBase` + `ApiObjectList` per object type | `native/ObjectBase.h` | Zig generics cannot do a per-type registry without a comptime-generated table. |
| Virtual `BackendConnection` + trait-struct downcast | `native/null/`, `vulkan/` | `anytype`-parameterised duck-typed calls, or a comptime-generated vtable. |
| `AsyncWorkerThreadPool` | `platform/WorkerThread.h` | `std.Thread.Pool` or a hand-rolled pool; the port owns the shutdown protocol. |
| `DynamicLib` dlopen shim | `common/DynamicLib.cpp` | `std.DynLib` exists. |
| `MutexProtected` / `MutexCondVarProtected` | `common/MutexProtected.h` | `std.Thread.Mutex` / `Condition`; the serial-keyed maps need a ported design. |
| X-macro `Result.h` / `Schema.h` / `Toggles.cpp` tables | several | A comptime table replaces a preprocessor pass. |
| `SlabAllocator`, `LRUCache`, `SerialMap` | `common/` | Zig stdlib has `ArrayList`; slab and serial maps need ports. |
| `UnpackedPtr<T>` chained descriptors | `native/ChainUtils.h` | Zig tagged-union chaining, or a comptime-generated `next` accessor. |

---

## 7. Scope decisions taken from this map

| Decision | Driver |
| --- | --- |
| **SPIR-V in, WGSL out.** | §4.9: Dawn has no pass-through branch, but a Vulkan-only port does not need one — except for reflection, which is ~5k lines of SPIR-V parsing rather than 754k lines of WGSL. |
| **SPIR-V validation ported to Zig, no optimiser.** | §4.9: Dawn itself only validates. |
| **Vulkan back end only.** | 27.8k of 154k in `native/`; six other back ends skipped. |
| **Wire and replay deferred.** | §4.13: cross-process split, not needed in-process. |
| **No `dawn_native.h` C++ ABI.** | The Zig package is the ABI. A C ABI is a later milestone if a consumer needs one. |
| **`tint` vendored inside Dawn is a submodule-free copy.** | §4.10: it is not a submodule, so a port cannot "just depend on it"; skipping it is a real 754k-line saving. |

---

## 8. What is not known

- `UNKNOWN:` whether the `vkGetDeviceProcAddr` device tier enumerates exactly the
  same set as Dawn's. Settled by reading `VulkanFunctions.cpp:110-476` in full.
- `UNKNOWN:` the exact Dawn revision's `webgpu-cts` conformance list, which lives
  in a separate checkout under `webgpu-cts/`. Settled by reading that directory.
- `UNKNOWN:` whether `VK_KHR_portability_enumeration` (present on this host)
  changes the device-selection path. Settled by reading
  `PhysicalDeviceVk.cpp` once the port reaches it.
