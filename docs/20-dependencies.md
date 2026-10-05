# 20 — Dependencies

## The ladder

Every dependency is taken at the first rung that works:

1. the Zig standard library;
2. a Zig package pinned in `build.zig.zon`;
3. a `translate-c` binding to a system C library;
4. a hand-written C shim.

Rung 4 needs a written reason: a macro, an opaque handle, a callback with a
non-representable type, or varargs. This project currently has no rung 4.

**No C++ is linked, built, or vendored at any point.** That is a hard
constraint, not a preference.

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

**Resolution.** Keep the pinned headers, drop the broken build glue. The
repository is consumed as a plain commit tarball and `zig translate-c` runs in
our own `build.zig`.

```text
$ zig translate-c -I<vulkan-headers>/vulkan <vulkan-headers>/vulkan/vulkan_core.h > vulkan.zig
exit 0, 0 errors, 22,360 lines, 0.457 s
```

and the result compiles, links, and drives the real loader:

```text
vkCreateInstance -> 0 (VK_SUCCESS=0), handle present = true
vkEnumeratePhysicalDevices -> 0, count = 4
vkDestroyInstance done
```

Four devices on this host. Zero C++.

**Pin.** `CoffeeImpliesCode/vulkan-headers` at commit
`8249cb829eb402c65cb7e3778c51b0f8edc4a4b6`, Vulkan-Headers **v1.4.365**
(`VK_HEADER_VERSION 365`). That package cannot be listed in `build.zig.zon`
because Zig executes a dependency's own `build.zig`, so the build translates
the nix `vulkan-headers` tree at 1.4.357 instead. The fields `gen_dispatch`
emits are the overlap set, which Dawn pins by writing the tier table from
`VulkanFunctions.{h,cpp}` at the pinned revision. `DUSK_VULKAN_HEADERS` in
`devenv.nix` names the tree actually translated, and the pin moves there when
the account package builds under Zig 0.16.0 again.

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

### Test shaders — WGSL sources plus generated `.spv`, compared

Chosen: commit the WGSL, regenerate the `.spv` in the gate, and fail if the
committed `.spv` drifts.

The WGSL→SPIR-V step is a **test-time external tool**. It never enters the
library and never appears in `build.zig.zon`.

**Where the translator comes from.** `pkgs.tint` resolves in nixpkgs at 0.1.7
but ships no binary, and no other nixpkgs package emits SPIR-V from WGSL. So the
translator is built from the pinned Dawn checkout, by the `devenv.nix` task
`dusk:build-tint`, and cached at `${cacheRoot}/tools/tint`, exported as
`DUSK_TINT`.

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

One entry. `build.zig.zon` at the time of writing:

```zig
.dependencies = .{
    .@"vulkan-headers" = .{
        .url = "https://codeload.github.com/CoffeeImpliesCode/vulkan-headers/tar.gz/8249cb829eb402c65cb7e3778c51b0f8edc4a4b6",
        // filled in by `zig build`
    },
},
```

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
