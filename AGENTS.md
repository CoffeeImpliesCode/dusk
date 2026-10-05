# dusk — agent rules

Read this file first. Then `docs/00-index.md`, then `docs/02-dawn-design.md`,
then `docs/30-port-design.md` and `docs/40-plan.md` when they land. Read
`skill://asd-ste100` before you write prose.

## 1. What this project is

`dusk` is a pure Zig reimplementation of Google's Dawn WebGPU engine, with
Vulkan as its only back end. It re-implements the WebGPU object model, the
command encoding path, the resource and memory management, the pipeline cache
and the Vulkan back end. It runs on desktop, on mobile, and — through the
browser's own WebGPU — on the web.

Three constraints bind every decision in this repository.

1. **Zero C++.** No C++ is linked, built, vendored, or compiled. No
   `CMakeLists.txt`, no `BUILD.gn`, no `.cc`, no `.cpp`. Dawn's vendored
   `src/tint` — 753,961 lines of WGSL front end and SPIR-V back end — is not
   ported and is not depended on. `dawn.json` and the Vulkan C headers are data
   and headers, not C++.
2. **Pure Zig build system.** `build.zig` and `build.zig.zon` are the only build
   inputs. A generator is a Zig program under `tools/`, never a shell script and
   never a Python one. `zig` on `PATH` is an anyzig shim that reads
   `.minimum_zig_version` from the manifest; do not install a second compiler.
3. **SPIR-V is the shader input on native targets.** The port does not parse
   WGSL. It validates SPIR-V, reflects it, and hands the caller's own words to
   `vkCreateShaderModule`. Dawn cannot do this — it round-trips through Tint and
   regenerates — which is exactly why the port is smaller.

The Zig version is **0.16.0**. `build.zig.zon` holds
`.minimum_zig_version`, and that file is the single version authority for the
project and for every tool the gate runs.

## 2. Golden rules

Safety before performance before developer experience. When two conflict, take
them in that order.

- **Explicit everything.** An allocator is a parameter, never a global. An API
  declares its own error set and never leaks `anyerror`. Control flow is
  explicit. No hidden allocation, no hidden state, no macro that hides a branch.
- **Handle every error.** Never discard one with `_ =`. Ask of every `if` whether
  its `else` branch needs handling. Assert the positive space and the negative
  space at every boundary.
- **Pair the assertions.** Write a value, then read it back. Split a compound
  assertion into `assert(a);` and `assert(b);` so the failure names one field.
  State a compile-time relationship with `comptime assert(...)`.
- **Bound every loop.** Give it a fixed upper bound, name the bound, and report
  exhaustion as its own error.
- **Keep functions small.** Push `if`s up and `for`s down. The parent owns the
  mutable state. A helper computes and returns; it does not apply.
- **Name as the house names.** Functions `camelCase`, types `PascalCase`,
  variables and struct fields `snake_case`. Append the unit to the name, as in
  `timeout_ms`, `byte_count` and `frame_index`. Do not abbreviate. Two or more
  parameters of the same type become an options struct. A callback is the last
  parameter and is named `<caller>_callback`.
- **Make division explicit.** Use `@divExact`, `@divFloor` or `div_ceil`, and put
  the rounding rule in the name of the result.
- **Format with the tool.** Run `zig fmt`. Keep a line under 100 columns. Put
  braces on a multi-line `if`.
- **A comment says why.** Delete a comment that restates the code.
- **No backwards compatibility.** Delete, do not deprecate. No alias, no shim,
  no unused parameter, no deprecation note.
- **Zero dependencies unless a document justifies one.** `docs/20-dependencies.md`
  owns every entry and the reason the standard library does not cover the slot.

## 3. Architecture: extreme testable by default

Mandatory for new code, the default for a refactor, and a review finding when it
is missing.

- **`io` threaded explicitly, never global.** Every function that can block or
  perform I/O takes `io` as a parameter. No module holds an `Io` in a file-scope
  variable, and no module reaches for a global one. A test builds its own `Io`,
  so a deterministic back end is a parameter swap.
- **The front end holds no Vulkan.** `command` records intent; `engine` replays
  it into `vk`. This split is what lets the whole front end be tested with no
  device. Do not merge the two modules.
- **State is a parameter, not a capture.** Pass it, as in `step(event, &state)`.
  A pure function returns the new state.
- **Allocator injection and fail-N.** Every allocating function takes a
  `std.mem.Allocator` as its first parameter. A test fails the Nth allocation,
  from 0 up to the first success, so every `error.OutOfMemory` path and every
  `errdefer` runs at least once.
- **Errors are values.** Declare the error set. Sweep it at compile time with
  `inline for` over `@typeInfo(ErrorSet)` so every member is named by a test.
- **Comptime exhaustiveness is the strongest coverage substitute Zig has.** Run
  `try comptime testFn();` and an `inline for` over every enumerable domain. The
  347 API objects in `dawn.json` are such a domain, so a new upstream object
  must be a compile error until the port handles it.
- **`unreachable` is a claim.** Use it only for a case that cannot occur, and
  say why in a comment.
- **Determinism is a feature.** Inject the seed. Read no clock in logic. Fuzz
  at every decoder boundary with a metamorphic oracle.
- **Wire compatibility is a test, not a comment.** A claim of byte compatibility
  with upstream is a fixture test carrying recorded bytes.

A module that cannot be driven deterministically, or that cannot have a failure
injected into it, is a review finding and not a documented limitation.

### 3.1 The Vulkan seam

- **`src/vulkan.zig` is generated.** `zig translate-c` over the pinned
  `vulkan_core.h`. Never hand-edit it. Regenerate it through `build.zig`.
- **Every Vulkan entry point is reached through the dispatch table in
  `src/vk/dispatch.zig`,** never called directly from `src/vulkan.zig`. A
  direct call is a review finding: it bypasses the loader tier and the
  missing-proc rule.
- **`VkResult` is `c_int`, not a Zig enum.** The mapping to a Zig error set
  lives in `src/vk/dispatch.zig` and nowhere else.
- **The library must run with zero validation layers.** The layer is a test tool.
  A change that only works with the layer enabled is broken.

### 3.2 Shaders

- **SPIR-V in, SPIR-V out.** `src/spirv` validates, reflects and returns. It
  never rewrites the caller's words.
- **Reflection is ours.** Dawn reads reflection out of a `tint::Program`; the
  port reads it from the SPIR-V binary. A reflection result that does not match
  what the shader declares is a defect, not a warning.
- **No WGSL parser.** If a change needs to understand WGSL, it is in the wrong
  module. Test shaders are compiled by an external `tint` binary, never by the
  library.

  The translator is `DUSK_TINT`, built by `devenv tasks run dusk:build-tint`.
  It is built inside devenv because that container has no `/lib64`: a binary
  linked against the host toolchain will not run there. The command line is in
  `docs/50-verification.md` §6.2.

## 4. The build

- Enter the environment through direnv. `.envrc` sources `$HOME/.dev-env.sh` and
  then runs `use devenv`. If `ZIG_GLOBAL_CACHE_DIR` is empty in your shell, run
  `devenv shell`.
- Run the gate with `zig-gate`. Inside devenv use `devenv shell -- gate:dusk`.
  The gate runs ten stages in order: `fmt`, `build`, `test`, `ast-check`,
  `ziglint`, `zlint`, `zbc`, `zwanzig`, `cross-test`, `zig-cov`. The first nine
  are on by default and the tenth is advisory and off.
- `zig build` runs the default step and builds the published `dusk` module.
- `zig build test` runs the library tests in **Debug and ReleaseSafe**.
- `zig build cross-test` runs the Debug shard through the build system's own
  runner selection, native for the host and `qemu_user` for a foreign target.
- **Keep `.zig-cache` and `zig-pkg` as symlinks to local disk.** They point into
  `/tmp/cache/dusk/`. This checkout is on NFS and Zig 0.16.0
  cannot write its cache there. If either path is a real directory, run
  `devenv shell`. Do not remove the contents by hand.
- **Adding a dependency.** Add an entry to `build.zig.zon` pinned by commit, and
  record in `docs/20-dependencies.md` why the standard library is not enough.
  Pin by commit, never by a moving branch, never by a tag alone.

### 4.1 The Vulkan environment inside devenv

Two facts that will otherwise waste your afternoon, both established by
running the commands, not by reading:

- **Inside devenv the host GPU is unreachable.** The shell runs in a container
  whose `/usr` is not the host's `/usr`; `/usr/share/vulkan/icd.d` does not
  exist in there. The driver is **lavapipe**. Set `DUSK_VK_DRIVER_FILES` to
  reach anything else.
- **A green run that found zero devices proves nothing.** Any test that needs a
  device must fail, loudly, when enumeration returns none.

## 5. Testing and verification

- **The gate is `zig-gate`.** Run it once, after the work lands, not while
  editing.
- **A green gate does not prove** a coverage figure, fuzzing, a sanitizer,
  `ReleaseFast` or `ReleaseSmall`, foreign execution where a runner is missing,
  or the absence of a leak unless the tests use a leak-detecting allocator.
  `docs/50-verification.md` owns that list; do not restate it in a note.
- **The host is headless.** `DISPLAY` and `WAYLAND_DISPLAY` are unset in both
  configurations, so there is no display server to present to. The offscreen
  path stands on that, not on an extension: `VK_EXT_headless_surface` is present
  inside devenv on lavapipe and absent outside it on NVIDIA, while
  `VK_KHR_display` is the other way round. Neither configuration has both. The
  only way to observe a rendered result is to render to an offscreen texture,
  copy to a host-visible buffer, and read it back. No test may require a
  swapchain or a surface.
- **Never add a test to raise a coverage number.** Add one to catch a bug you
  can name.

## 6. Porting rules

- **One upstream file becomes one Zig file** unless the mapping table says
  otherwise, and the table gives the reason.
- **Record the mapping function by function.** One row per upstream function,
  with the upstream `path:line`, the Zig name, the Zig `path:line`, and the
  decision. `docs/40-plan.md` owns that table. A module with no row is a module
  whose port is not claimed. Do not invent a row for something not ported.
- **No shim survives the cutover.** No `compat.zig`, no `deprecated.zig`, no
  alias that forwards to a new name. Change the caller and delete the old path
  in the same commit.
- **Take the decision order for each new binding.** Standard library, then a
  pinned Zig package, then `translate-c`, then a hand-written C shim with the
  reason named in the row.
- **Cite upstream.** A claim about Dawn is a `path:line` into the pinned
  revision or it is not a claim.

## 7. Documentation

- `docs/02-dawn-design.md` is the evidence base. The other documents cite it
  and add no new upstream claims.
- Every document states what it does **not** claim.
- Write in the house voice: terse, declarative, no inflation. Read
  `skill://asd-ste100`.

## 8. Commits

- One commit per green phase, named for the phase.
- Never commit a red tree, never commit unrequested work, and never force a
  commit the repository does not expect. This repository uses `jj`.
