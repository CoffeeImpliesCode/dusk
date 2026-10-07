# dusk

A pure Zig reimplementation of the [Dawn](https://dawn.googlesource.com) WebGPU
engine, with Vulkan as its only back end.

Zero C++ is linked, built, or vendored. The build system is `build.zig`. Shaders
arrive as SPIR-V.

## Status

The project has a partial implementation. The formerly missing M6, M7, M18,
and M19 families have landed and passed local behavior tests.
M1–M21 are not complete. These tests do not prove WebGPU conformance or every
native feature.

The historical 138-row census covered M6 (63), M7 (32), M18 (38), and M19 (five).
It is neither a remaining count nor the whole backlog.
See issues [#4](https://github.com/CoffeeImpliesCode/dusk/issues/4),
[#2](https://github.com/CoffeeImpliesCode/dusk/issues/2),
[#1](https://github.com/CoffeeImpliesCode/dusk/issues/1), and
[#3](https://github.com/CoffeeImpliesCode/dusk/issues/3).
Issue #1 now names M18 as verified. These issues remain open because the fixes
are local, not published.
`docs/40-plan.md` owns the milestone mappings and selected remaining async,
disk, persistent-cache, and specialization groups.
M14's 63/341 triage budget is not a backlog subtraction.

The triangle and query shards encode through the frontend, finish a `Finished`
stream, replay through the engine, and submit Vulkan work.
The historical 2026-10-07 snapshot predates native stage constants.
It passed 69/69 build steps, including 251 root tests in each of Debug and ReleaseSafe.
Three selected cross-test rows passed with 251 tests each.
Explicit zero-layer triangle, query, and buffer checks passed.
The historical full `zwanzig` snapshot reported 107 optional-unwrap warnings.
The historical legacy `zig-gate --no-zbc` passed its five active stages.
It explicitly skipped `zbc` and did not run `zwanzig` or cross-tests.
These snapshots do not verify the new specialization source.
The current full aggregate passed 73/73 steps, with 262 root tests each in Debug and actual ReleaseSafe.
Current cross-tests passed three rows with 262 root tests each, including big-endian `powerpc64-linux`.
Both compute shards passed again with zero validation layers.
Final 142-file source lint passed with zero diagnostics, errors, or warnings.
The current legacy `zig-gate --no-zbc` passed its five active stages.
The full ten-stage contract remains unclaimed and outside the permitted analyzer boundary.
`zbc` defects are reported externally. The user stopped further `zbc` source work.
See [`docs/50-verification.md`](docs/50-verification.md) for evidence limits.

Native SPIR-V `StageInput.constants` now applies borrowed `api.ConstantEntry` values to compute, vertex, and fragment stages.
Keys accept canonical decimal `SpecId` strings or unambiguous `OpName` aliases.
Validation and scalar normalization occur before cache lookup or native creation.
Equivalent aliases, order, and converted bits share a pipeline. Different bits produce different keys.
The reviewed `test-compute-specialization` shard passed 4/4 tests in Debug and actual ReleaseSafe in BG97.
Each run includes two new compute scenarios and two existing imported triangle tests.
Ten dispatches per mode produced `113/25/35/25/35` and `121/44/55/44/55`.
Each scenario produced unique pipeline counts `1/2/3/3/3`.
Host tests cover compute and both graphics stage ABI payloads. Specialized graphics draws remain unproven.
Review fixes added a host-read barrier and support for multiple shader result IDs with one `SpecId`.
BG102 repeated the reviewed GPU proof and passed the full aggregate after the final boundary-test repair.
This is a native SPIR-V contract, not generated WebGPU Device ABI integration or async pipeline support.
See [`docs/30-port-design.md`](docs/30-port-design.md) §7.3 for input, numeric, ownership, and cache rules.

## What it will be

- The WebGPU object model: instance, adapter, device, queue, buffers, textures,
  bind groups, pipelines, and the encoders that record work into them.
- A command stream that records on the CPU and replays into Vulkan at submit, so
  the whole front end is testable with no device.
- SPIR-V validation and reflection in Zig, then a straight hand-off of the
  caller's own words to `vkCreateShaderModule`.
- Device memory through VMA, with the WebGPU-specific allocation layers above it.
- The WebGPU **mobile compatibility profile** as a hard requirement.

## What it is not

- Not a wrapper. No Dawn binary, no Dawn header, no Dawn C++ is linked.
- Not a WGSL compiler. `src/tint` — 753,961 lines — is not ported. Test shaders
  are compiled by an external tool, never by the library.
- Not multi-backend. D3D11, D3D12, Metal, OpenGL, OpenGL ES, Null and
  WebGPU-on-WebGPU are skipped.
- Not a network engine. Dawn's wire client/server and its replay layer are
  deferred.

## Targets

| Target | How |
| --- | --- |
| Desktop (Linux, Windows, macOS) | Vulkan 1.1 or newer |
| Mobile (Android, iOS) | Vulkan, under the mobile compatibility profile |
| Web | The browser's own WebGPU; `dusk` is not shipped there |

## Building

```sh
direnv allow .          # once
devenv shell
zig build               # builds the published `dusk` module
zig build test          # aggregate library tests and acceptance shards
zig build test-memory   # selects the memory acceptance shard
zig build test-triangle # frontend stream → engine replay → Vulkan pixels
zig build test-query-set # frontend stream → engine replay → Vulkan queries
zig-gate                # installed legacy subset, not the ten-stage contract
```

The toolchain is Zig 0.16.0. `build.zig.zon` is the only version authority.

Select acceptance shards by their named build steps. `zig build test -- test-memory`
does not select a shard. The former `b.args` forwarding did not filter tests.

`docs/50-verification.md` §8 defines the ten-stage gate contract.
The installed legacy script omits active `ziglint`, `zwanzig`, and cross-tests.
Those checks need supplemental commands. A legacy `GATE PASSED` is not a full
ten-stage result.
Published bootstrap history through `4645d5d0` remains unchanged.
Future phases use one green-phase commit, without history rewrites or force-pushes.
The accepted work does not authorize a commit or push.
See the [issue #6 policy decision](https://github.com/CoffeeImpliesCode/dusk/issues/6#issuecomment-6042784874).

### Recreating the Dawn source reference

`tools/dawn_pin.zon` records the repository, exact revision, and sparse paths.
Fetch the reference source explicitly:

```sh
zig build fetch-dawn
zig build fetch-dawn -Ddawn-dir=/absolute/path/to/research/dawn
zig build test-dawn-pin
```

The destination order is `-Ddawn-dir`, `DUSK_DAWN_SRC`,
`buildhost_SCRATCH_ROOT/research/dawn`, then
`$HOME/.cache/dusk-research/research/dawn`.
The fetch checks the exact revision and the `src`/`include` sparse set.
It refuses a dirty checkout rather than discarding local files.
This source-only fetch does not build or depend on Dawn C++ or Tint.
Ordinary builds do not depend on the fetch step.

### Vulkan inside the development shell

The development shell uses **lavapipe**, Mesa's software rasterizer.
The current runtime reports device Vulkan 1.4.354 and loader Vulkan 1.4.357.
Admission requires Vulkan 1.1. The instance requests `min(loader, 1.3)`.
The native shader path uses the device's effective API version.
`docs/20-dependencies.md` records the loader `LD_LIBRARY_PATH` fix.
Set `DUSK_VK_DRIVER_FILES` to select another reachable driver.
The Khronos validation layer is enabled for tests, not required by the library.

Tests render to offscreen textures and read the pixels back.
No acceptance test requires a surface or swapchain.
The shared-memory shard proves GPU memory import.
This runtime only proves typed unsupported-capability rejection for semaphore FD
services, not successful native semaphore FD import.

## Documents

| Document | Owns |
| --- | --- |
| [`docs/02-dawn-design.md`](docs/02-dawn-design.md) | The upstream codebase, mapped at a pinned revision |
| [`docs/10-architecture.md`](docs/10-architecture.md) | Module layout and boundaries |
| [`docs/20-dependencies.md`](docs/20-dependencies.md) | The dependency ladder and every C-library decision |
| [`docs/30-port-design.md`](docs/30-port-design.md) | The Zig-native public contract |
| [`docs/40-plan.md`](docs/40-plan.md) | Milestones and the function-level mapping table |
| [`docs/50-verification.md`](docs/50-verification.md) | How correctness is proven headless |

## Licence

To be decided. Dawn is BSD-3-Clause; a port derived from its design records that
attribution.
