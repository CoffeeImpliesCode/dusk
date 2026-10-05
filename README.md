# dusk

A pure Zig reimplementation of the [Dawn](https://dawn.googlesource.com) WebGPU
engine, with Vulkan as its only back end.

Zero C++ is linked, built, or vendored. The build system is `build.zig`. Shaders
arrive as SPIR-V.

## Status

The project is at its design stage. The gate is green; there is no engine code
yet. `docs/40-plan.md` names the milestones and their order.

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
zig build test          # Debug and ReleaseSafe
zig-gate                # the house gate, ten stages
```

The toolchain is Zig 0.16.0. `build.zig.zon` is the only version authority.

### Vulkan inside the development shell

`devenv` runs its shell in a container that cannot see the host GPU, so the
driver in there is **lavapipe**, Mesa's software rasteriser. Set
`DUSK_VK_DRIVER_FILES` to point elsewhere. The Khronos validation layer is
enabled for tests and is never a runtime dependency.

The host is headless: there is no display and no `VK_EXT_headless_surface`. GPU
tests render to an offscreen texture and read the pixels back. No test requires a
surface or a swapchain.

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
