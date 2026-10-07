# 20 — Dependencies

## The ladder

Every dependency is taken at the first rung that works:

1. the Zig standard library;
2. a Zig package pinned in `build.zig.zon`;
3. a `translate-c` binding to a system C library;
4. a hand-written C shim.

Rung 4 needs a written reason: a macro, an opaque handle, a callback with a
non-representable type, or varargs. This project currently has no rung 4.

**No C++ enters the library build or runtime.** The external Tint fixture tool
is the test-time exception described below.

---

## Decisions taken

The user was asked to choose a C library for each slot where one fits, rather
than have it ported to Zig. The answers, and the evidence behind each:

### Vulkan bindings — `translate-c` over the account's pinned headers

Chosen: use `CoffeeImpliesCode/vulkan-headers`, plus a hand-written dispatch
layer.

**That package does not build under Zig 0.16.0.** Proved, not inferred. Its
`toolbox` 2.2.5 dependency fails to compile:

```text
zig-pkg/toolbox-2.2.5-…/build.zig:170:30: error: no field named 'root' in struct 'Build'
zig-pkg/toolbox-2.2.5-…/build.zig:263:35: error: no field named 'root' in struct 'Build'
zig-pkg/toolbox-2.2.5-…/build.zig:819:24: error: member function expected 2 argument(s), found 1
```

Exit code 2. Both errors are Zig 0.16 build-API changes: `Build.root` is gone,
and `findProgram` now takes a `paths` argument. The `.minimum_zig_version =
"0.16.0"` in that manifest is therefore a false claim.

The standalone `vk.zig` in `nogui` that the user mentioned does not exist:
`gh search repos nogui --owner CoffeeImpliesCode` returns `[]`,
`gh search code 'filename:vk.zig owner:CoffeeImpliesCode'` returns nothing, and
`find ~/ -maxdepth 4 -iname 'vk.zig' -o -iname '*nogui*'` finds nothing.

**Resolution.** Fetch the pinned repository as header data, without its Zig
package build script. `devenv.nix` uses `pkgs.fetchzip` with this fixed source:

```text
URL: https://codeload.github.com/CoffeeImpliesCode/vulkan-headers/tar.gz/8249cb829eb402c65cb7e3778c51b0f8edc4a4b6
SHA-256 (Nix base32): 0z89r39v4ivhfc6c1km0bgxgddyy7fdsy88bgr5rw0afzfcahwpa
```

**Pin.** The authority is `CoffeeImpliesCode/vulkan-headers` at commit
`8249cb829eb402c65cb7e3778c51b0f8edc4a4b6`, Vulkan-Headers **v1.4.365**
(`VK_HEADER_VERSION 365`). The unpacked source contains
`vulkan/vulkan/vulkan_core.h` and `vulkan/vk_video`.
`DUSK_VULKAN_HEADERS` names `${vulkanHeadersSource}/vulkan`, the include directory
that contains both `vulkan` and `vk_video`.

Our `build.zig` translates that C header data and requires version 365.
The Nix fixed-output fetch does not execute the repository's `build.zig` or
compile or link C++. It is an external environment input, not a Zig dependency.
There is no fallback to the nixpkgs 1.4.357 headers.

The installed Vulkan loader, validation layers, tools, and driver keep their
own package versions. Their versions do not define the C header authority.
The dispatch generator uses Dawn's pinned `VulkanFunctions.{h,cpp}` tier table.

This source pin does not prove generation, compilation, or runtime checks passed.
It also does not prove platform SDK or future platform-header readiness.
`docs/50-verification.md` owns execution evidence.

### Dispatch — hand-written, mirroring Dawn

Dawn does not use volk. It hand-rolls a three-tier function-pointer struct in
`src/dawn/native/vulkan/VulkanFunctions.cpp` (909 lines) loaded through
`DynamicLib`. `grep -rn 'volk' --include=CMakeLists.txt .` in Dawn returns
nothing. The port does the same, with the three tiers and the same
tolerated-missing rule for device procs.

`volk` is available in nixpkgs (1.4.357.0) and is listed in `devenv.nix` as a
considered-and-rejected option, with the reason recorded here.

### SPIR-V — validate in Zig, no optimiser

Chosen: port SPIR-V validation to Zig; do not port the optimiser.

Dawn agrees: `src/dawn/native/SpirvValidation.cpp:37-79` builds a
`spvtools::SpirvTools`, calls `SetMessageConsumer` and `Validate`, and
`Disassemble`s on failure. **No optimiser and no legalisation** run in
`src/dawn`; the legalisation-like passes live inside Tint's SPIR-V reader.

`spirv-tools` is in `devenv.nix` as a **test-time tool only** — `spirv-val` proves
a checked-in `.spv` fixture is well formed before the engine sees it. It is not a
build input and not linked.

### Memory — VMA

Chosen: consume `vulkan-memory-allocator`.

Note the divergence from Dawn, which uses no VMA and keeps its own ~900-line
buddy stack (`docs/02-dawn-design.md` §4.5). VMA replaces the *device-memory*
layer of that stack. The WebGPU-specific layers above it — the size tracker, the
serial reclamation, the lazy-allocation flag, and the per-resource
`ResourceMemoryAllocation` record — remain ours, because VMA does not model them.

`pkgs.vulkan-memory-allocator` is available in nixpkgs.

### Dawn source reference — explicit, pinned Git checkout

`tools/dawn_pin.zon` owns the source URL, revision, and sparse directory set:

```zig
.{
    .url = "https://dawn.googlesource.com/dawn",
    .revision = "32f77c02294310054a660c393feded4bcb3f203c",
    .sparse_paths = .{ "src", "include" },
}
```

Git is required for this explicit tool. The Zig standard library does not
implement the Git fetch protocol or sparse checkout.
The source reference is not a package dependency.
The default library build does not fetch or compile Dawn.

From a fresh dusk clone, select a nonexistent destination on local disk:

```bash
zig build fetch-dawn -Ddawn-dir="$HOME/.cache/dusk-research/research/dawn"
git -C "$HOME/.cache/dusk-research/research/dawn" rev-parse HEAD
git -C "$HOME/.cache/dusk-research/research/dawn" sparse-checkout list
git -C "$HOME/.cache/dusk-research/research/dawn" rev-parse --is-shallow-repository
```

HEAD must equal the full revision above. The sparse list must contain exactly
`src` and `include`, in either order. Repeating the fetch command is safe for a
clean checkout with the same origin. The tool verifies HEAD, sparse paths, and
cone mode after checkout. Git cone mode also includes files at the repository
root. It does not include the other root directories.

`-Ddawn-dir` overrides `DUSK_DAWN_SRC`. Without either value, the destination is
`$buildhost_SCRATCH_ROOT/research/dawn` when that variable is nonempty.
Otherwise it is `$HOME/.cache/dusk-research/research/dawn`.
`devenv.nix` exports the same default as `DUSK_DAWN_SRC`.
Entering devenv does not fetch Dawn sources.

The fetch requests the exact commit with `--depth=1` and checks out detached HEAD.
A fresh checkout is shallow. An existing checkout can retain older objects,
refs, and shallow boundaries. The tool reports Git's actual shallow state.
It does not promise a one-commit object database or complete history.
It does not fetch submodules, run hooks, download build dependencies, or compile C++.
The upstream server must permit fetching the pinned commit by hash.

Before changing an existing checkout, the tool rejects tracked changes,
untracked files, and ignored files. It also rejects a different origin and a
destination without its own `.git` directory. It never resets or cleans files.
Use a new destination for a checkout that contains local work.
A failed network request can leave an initialized checkout for the next attempt.
Do not edit the destination concurrently with the tool.

This sparse tree is a source reference, not a complete Tint build tree.
Tint needs a separate, complete checkout at the same pin and its upstream build
dependencies. Point `DUSK_DAWN_SRC` at that checkout before entering devenv.
The `dusk:build-tint` task checks the exact HEAD and origin before it builds.
Its cached binary carries a revision sidecar. A cache without that sidecar does
not qualify as a pinned translator.
Source fetching and translator compilation remain separate actions.
This section does not claim a fresh Tint build or a complete upstream dependency
checkout. `docs/50-verification.md` owns translator execution evidence.

### Test shaders — WGSL sources plus generated `.spv`, compared

Chosen: commit the WGSL, regenerate the `.spv` in the gate, and fail if the
committed `.spv` drifts.

The WGSL→SPIR-V step is a **test-time external tool**. It never enters the
library and never appears in `build.zig.zon`.

**Where the translator comes from.** `pkgs.tint` resolves in nixpkgs at 0.1.7
but ships no binary, and no other nixpkgs package emits SPIR-V from WGSL. So the
translator is built from a complete checkout at the source-reference pin, by
the `devenv.nix` task `dusk:build-tint`. It is cached at
`${cacheRoot}/tools/tint`, exported as `DUSK_TINT`.

It is built **inside devenv**. The container has no `/lib64` at all — only the
nix glibc — so a binary linked against the host toolchain fails there with
`cannot execute: required file not found`. That was observed before it was
fixed. The task also disables the six back ends and both window systems,
because otherwise the configure step requires `xkbcommon`, which is absent.

The command line, measured:

```bash
"$DUSK_TINT" <fixture>.wgsl --format=spirv --ep <name> --ep <name> -o <out>.spv
```

`--format` is the output-language flag; there is no `--output-format`. A module
with more than one entry point refuses to emit without an explicit `--ep` per
entry point. Output is byte-deterministic across runs, which is what makes the
drift check in `docs/50-verification.md` meaningful.

---

## The dependency manifest

Zero Zig package dependencies. `build.zig.zon` declares:

```zig
.dependencies = .{},
```

The pinned Vulkan header data enters through `DUSK_VULKAN_HEADERS`, as described
above. Nix fetches it separately from the Zig package manager.

Everything else the port needs is either Zig standard library or a system C
library reached through `translate-c`:

| Slot | Source | Rung |
| --- | --- | --- |
| Vulkan types | `translate-c` of the pinned `vulkan_core.h` | 3 |
| Vulkan loader | `libvulkan.so.1` via `std.DynLib` | 3 |
| Device memory | VMA (`translate-c`) | 3 |
| Containers, hashing, sorting | Zig stdlib | 1 |
| Threads, mutexes, conditions | Zig stdlib | 1 |
| Dynamic library | `std.DynLib` | 1 |
| Formatting | Zig stdlib | 1 |

Pipeline map buckets use `std.hash.Wyhash`, not a cryptographic digest
(`src/pipeline/cache_key.zig:109-115`). Key equality compares the stored bytes.
Shader SPIR-V words use stdlib SHA3-256
(`src/pipeline/shader_module.zig:72-76,275-284`).
Dusk does not implement SHA3-224 persistent artifact validation.
Dawn uses SHA3-224 for that role (`src/dawn/native/BlobCache.cpp:46-50`,
at pin `32f77c02294310054a660c393feded4bcb3f203c`).
Persistent artifact caching remains outside the selected runtime scope.

Adding an entry requires writing here, in the same change, why the standard
library does not cover the slot.

---

## Verification tools, not build inputs

Present in `devenv.nix`, absent from `build.zig.zon`, and never linked:

| Tool | Why |
| --- | --- |
| `vulkan-validation-layers` | Catches our own mistakes during a test run. |
| `spirv-tools` | Proves a `.spv` fixture is well formed before the engine sees it. |
| `vulkan-tools` | `vulkaninfo` proves the loader sees a device at all. |
| `pkg-config` | Fails early when a system header is missing. |
| `tint` | Test-time WGSL→SPIR-V, built from the pinned Dawn checkout. |

---

## Validation layers are not a runtime dependency

`devenv.nix` force-enables `VK_LAYER_KHRONOS_validation` with synchronisation
validation on, and points `VK_LAYER_LOG_PATH` at stderr.

**The shipped library must run correctly with zero layers enabled.** A test that
must prove the no-layer path sets `VK_LOADER_LAYERS_DISABLE` per process rather
than mutating the shared shell. `docs/50-verification.md` owns that matrix.

---

## The driver question

`devenv.nix` sets `LD_LIBRARY_PATH` with `lib.makeLibraryPath` for the runtime
packages, including `vulkan-loader`. Package installation alone does not expose
`libvulkan.so.1` to `std.DynLib`. This project shell replaces inherited audio and
scanner library paths. It does not change the global environment or the pinned
lavapipe ICD.

Inside devenv the shell runs in a container whose `/usr` is **not** the host's
`/usr`: `/usr/share/vulkan/icd.d` does not exist in there, so the host NVIDIA ICD
is unreachable and `libvulkan` reports `vkCreateInstance: Found no drivers!`.
An eval-time `builtins.pathExists` cannot decide this either — nix evaluates in
the same container and answers `false` for a file that is demonstrably present.
The check therefore runs in `enterShell`, where the filesystem is the real one.

The driver inside devenv is **lavapipe**, Mesa's software rasteriser. It needs no
GPU and no display, which is what a headless test wants. Mesa also installs
fourteen other ICDs; they are excluded because each probes DRM nodes it does not
own and prints a `VK_ERROR_INCOMPATIBLE_DRIVER` error that would drown a real
failure in noise.

Observed inside devenv:

```text
VK_LAYER_KHRONOS_validation Khronos Validation Layer 1.4.357  version 1
apiVersion = 1.4.354
deviceType = PHYSICAL_DEVICE_TYPE_CPU
deviceName = llvmpipe (LLVM 21.1.8, 256 bits)
driverName = llvmpipe
```

`DUSK_VK_DRIVER_FILES` overrides the list. Real hardware is four NVIDIA RTX A6000
reachable outside devenv; `docs/50-verification.md` owns the matrix.
