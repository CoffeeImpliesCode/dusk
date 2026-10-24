# Architecture

## Package layout

`build.zig` publishes one module, `dusk`, rooted at `src/root.zig`.
The root exports nine namespaces:

| Namespace | Implementation |
| --- | --- |
| `api` | Generated handles, descriptors, enums, callbacks, and procedure declarations. |
| `core` | Object tracking, arenas, errors, error scopes, and shared containers. |
| `engine` | Instances, adapters, devices, native resources, queues, and command replay. |
| `command` | Command allocation, typed encoders, passes, validation, and finished streams. |
| `memory` | Allocation records, pools, buddy/slab/ring allocators, and VMA declarations. |
| `pipeline` | Shader modules, reflection, layouts, specialization, and pipeline caches. |
| `platform` | Dynamic loading, worker threads, surfaces, and external resource interfaces. |
| `spirv` | SPIR-V parsing, validation, and reflection. |
| `vk` | Vulkan result handling and global, instance, and device dispatch tables. |

`src/vulkan.zig` contains generated C bindings. `src/vk/dispatch.zig` contains the
generated dispatch table. `tools/` contains generators and source-fetch tooling.
`test/` contains acceptance shards. `src/engine/shaders/` contains WGSL sources,
SPIR-V binaries, and native-kernel provenance data.

Generated declarations describe an API surface. They do not establish that every
procedure has a complete implementation. The typed native facade exposes
`engine.Instance`, `engine.Adapter`, and `engine.Device`.

## Command and resource path

Native resource factories create Vulkan buffers, textures, and pipelines
synchronously. Encoders record typed commands in host memory. A finished stream
passes to `Device.submit`, which replays it into Vulkan and returns a serial.
`Device.wait` waits for GPU completion.

The record/replay boundary permits CPU-only command validation tests.
The explicit null backend provides test devices without Vulkan.
Native execution uses dynamically loaded Vulkan entry points through dispatch
tables. The published module links libc for system dynamic-library loading.
The library does not link Dawn or Tint.

The device tracks user references, strong dependencies, and GPU use separately.
Queue submission retains resources until their serial completes. The host object
arena can outlive native payload destruction. See the
[ownership contracts](30-port-design.md#ownership-and-lifetime).

## Shaders and capabilities

The native shader path accepts SPIR-V, validates it, and reflects entry points
and resource bindings. Vulkan shader modules use the supplied shader words.
Native-kernel WGSL compilation uses external Tint during generation, not runtime.

Raw Vulkan capabilities and frontend feature policy are separate.
`engine.native_capabilities` projects queried hardware features and limits into
frontend capabilities. Device creation checks requested features and limits.
Feature names in generated declarations do not imply native support.

`engine.format` holds canonical format metadata and feature-dependent capability
rows. `engine.block_info` separates texel counts from block counts and checks
conversion overflow, exact division, and API narrowing.

Vulkan is the native backend. Platform surface and external-resource interfaces
have additional driver and operating-system requirements. Their presence does
not establish a cross-platform support matrix.

## Generation inputs

The Vulkan header source is
[`CoffeeImpliesCode/vulkan-headers`](https://github.com/CoffeeImpliesCode/vulkan-headers)
at `8249cb829eb402c65cb7e3778c51b0f8edc4a4b6`, Vulkan-Headers v1.4.365.
`devenv.nix` fetches the source as header data and exports its include directory
through `DUSK_VULKAN_HEADERS`. It does not run that repository's build script.

`zig build generate -Dheader-dir=/path/to/include` invokes `zig translate-c`
on `vulkan/vulkan_core.h` and runs `tools/gen_dispatch.zig`.
The build checks `VK_HEADER_VERSION` 365 before updating both checked-in files.
Generation is explicit and does not run in the default build or ordinary tests.

`tools/dawn_pin.zon` records the upstream Dawn source URL, revision, and sparse
paths. `zig build fetch-dawn -Ddawn-dir=/path/to/dawn` fetches that source
reference. The tool rejects a dirty destination. Normal builds do not fetch or
compile Dawn. `tools/gen_api.zig` consumes Dawn's `dawn.json` API schema.

`tools/gen_native_kernels.zig` generates native utility shaders and checks
committed output. The explicit `generate-native-kernels` and
`check-native-kernels` steps require a pinned external Tint executable through
`-Dtint-path` or `DUSK_TINT`. Its revision must match the Dawn pin.
Committed shader binaries and provenance data are runtime assets, not caches.

## Tests and environment

The `test` build step includes Debug and ReleaseSafe library tests, dispatch
checks, generator drift checks, and acceptance shards. Selected native and
lifetime shards also run in ReleaseSafe. Individual acceptance steps select a
shard directly. Arguments after `--` do not select a shard.

The development shell supplies the Vulkan loader search path and selects
lavapipe. `DUSK_VK_DRIVER_FILES` overrides its driver list. A different driver
must be reachable from the shell environment. Vulkan headers, loader, driver,
and validation layers have separate versions.

Offscreen rendering tests do not require a window. Surface tests and
platform-specific resource imports need their respective platform services.
Test coverage does not imply WebGPU conformance.
