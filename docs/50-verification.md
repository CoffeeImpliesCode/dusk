# 50 — Verification

This document owns how correctness is proven on this machine: what a test may
observe, which layers and drivers it runs against, how a shader fixture is
produced, what the house gate proves, what a green gate leaves unproven, and
how a citation is resolved.


It adds no upstream claim of its own. Every statement about Dawn cites the
pinned tree at `32f77c02294310054a660c393feded4bcb3f203c` with a `path:line`,
or cites `docs/02-dawn-design.md`.

### Present implementation and evidence limits

The tree has a partial implementation, not just a design.
The formerly missing M6, M7, M18, and M19 families have landed and passed local
behavior tests. Nothing here establishes M1–M21 completion or WebGPU conformance.

The historical 138-row census covered M6 (63), M7 (32), M18 (38), and M19 (five).
It is neither a remaining count nor the whole backlog.
The counts come from issues
[#4](https://github.com/CoffeeImpliesCode/dusk/issues/4),
[#2](https://github.com/CoffeeImpliesCode/dusk/issues/2),
[#1](https://github.com/CoffeeImpliesCode/dusk/issues/1), and
[#3](https://github.com/CoffeeImpliesCode/dusk/issues/3).
M1's alternate symbol mappings and M19's two deliberate skips are separate.
M14's 63/341 triage budget does not subtract implementation backlog.
`docs/40-plan.md` owns selected remaining async, disk, persistent-cache, and
specialization groups.

#### Device weak canonical caches: 2026-10-08

**Status: SourceReadyFrozen.** This result covers live native BGL, PL, sampler, shader, attachment, and pipeline cache contracts.
It does not establish persisted `VkPipelineCache` data or driver-cache integration in pipeline creation.

The final combined Debug/ReleaseSafe run (`artifact://853`) completed in 750.26 seconds.
All 459 tests across 14 runs passed. The captured output contained no VUID or error report.

The exercised command ran from the Dusk checkout:

```sh
devenv shell -- zig fmt src/engine/render_pass_cache.zig \
  test/pipeline_canonical_layout.zig test/native_sampler.zig && \
devenv shell -- zig build test-native-sampler test-pipeline-canonical-layout \
  test-native-async-descriptors-release-safe test-native-async-pipeline-release-safe \
  test-native-async-map-queue-release-safe test-native-async-scope-info-release-safe \
  test-native-resource-store-release-safe test-native-sampler-release-safe \
  test-native-attachment-state-release-safe test-native-full256-immediate-release-safe \
  test-native-weak-index-release-safe test-native-attachment-store-release-safe \
  test-native-render-state-release-safe test-pipeline-canonical-layout-release-safe -j2
```

| Exercised shard | Debug | Actual ReleaseSafe |
| --- | ---: | ---: |
| Native weak index | — | 23/23 |
| Native resource store | — | 14/14 |
| Native sampler | 15/15 | 15/15 |
| Native scope/compilation info | — | 20/20 |
| Native render state | — | 14/14 |
| Native map/queue | — | 24/24 |
| Attachment state | — | 12/12 |
| Comprehensive native attachment store | — | 272/272 |
| Native async pipeline | — | 12/12 |
| Native async descriptors | — | 23/23 |
| Low canonical layout | 7/7 | 7/7 |
| Full256 readback | — | 1/1 |

These tests exercise actual concurrent native dedup, lease-only hits, logical binding order, compatibility domains, and pending GPU roots.
They also exercise pruning, missing cleanup procedures, reference overflow, fail-N rollback, and genuine native create/destroy counters.
Real render-pass fail-N tests destroy created-but-uninserted handles and check actual create/destroy balance.
These bounded counters and the tests' leak-detecting allocator are not a whole-program leak-absence or coverage proof.

The sampler fixture reads raw floats, not requantized output bytes (`test/native_sampler.zig:360-376`).
Its R/B midpoint property uses absolute tolerance `1/255`, derived from the UNORM8 source format.
G=0 and A=1 remain exact. The oracle rejects nearest-filter endpoints and checks untouched `0xa5` padding.
This fixture tolerance is not a universal Vulkan one-quantum guarantee.

The out-of-tree published Debug consumer, BG205, exercised real native compute and graphics readbacks.
Compute returned 113 with `0xa5` padding and completed serial.
LocalSizeId `(4,2,1)` produced invocation count 8 and mask 255.
RGBA8 graphics returned red, red, blue, blue with pitch 256 and `0xa5` padding.
Full256 returned word-63 values 113 and 173, with red, green, green, blue graphics.
The render bundle preserved its viewport. Cube-array creation used 12 layers.
Device, adapter-list, and Instance teardown completed cleanly.
BG205 exercised this published-module command:

```sh
devenv shell -- zig build --build-file /tmp/dusk-native-consumer/build.zig \
  run -Doptimize=Debug -j2
```

BG210 subsequently completed the entire external consumer chain with exit 0 in 153.63 seconds:

```sh
devenv shell -- zig fmt /tmp/dusk-native-consumer/src/async_proof.zig && \
devenv shell -- zig build --build-file /tmp/dusk-native-consumer/build.zig \
  async-proof -Doptimize=Debug -j2 && \
devenv shell -- zig build --build-file /tmp/dusk-native-consumer/build.zig \
  run -Doptimize=ReleaseSafe -j2 && \
devenv shell -- zig build --build-file /tmp/dusk-native-consumer/build.zig \
  async-proof -Doptimize=ReleaseSafe -j2
```

Thus the published synchronous consumer also has actual ReleaseSafe evidence.
The six-family async consumer passed in Debug and actual ReleaseSafe after the compilation-info alias-release oracle correction.
It exercised scope pop, compilation info, queue completion, map completion, compute pipeline creation, and render pipeline creation.
The compilation-info request survived public `Device.release` of its source alias before await.
Its empty result had zero metadata count and null data. The consumer released its owned span.
Pending compute creation settled the scope without a captured error. Cancellation delivered the cancelled callback result.
Queue completion retired an actual accepted serial.
Map readback returned 113 and red, red, blue, blue with pitch 256 and `0xa5` padding, then unmapped.
Generated ProcessEvents compute and WaitAnyOnly render callbacks preserved userdata and produced actual readbacks.
The consumer released their actual API aliases.
Async Full256 produced 113 and 173, red, green, green, blue graphics, and preserved the bundle viewport.
Alias, result, registry, Device, adapter-list, and Instance cleanup completed.
BG210 alone does not establish Adapter request, Device request, or device-lost future execution.
No utility GPU integration, platform completion, full gate, or protected-analyzer result is claimed here.

**Native async source inventory.** Source inspection finds routes for all eight generated callback-future starts.
The table records source presence, not additional exercised runtime results.

| Family | Generated callback bridge | Separate typed observer route |
| --- | --- | --- |
| Adapter request | `async_root_requests.zig:531-549` | `async_root_requests.zig:772-800` |
| Device request | `async_root_requests.zig:706-723` | `async_root_requests.zig:803-830` |
| Buffer map | `native_async_map_queue.zig:373-400` | `native_async_map_queue.zig:486-495` |
| Queue completion | `native_async_map_queue.zig:401` | `native_async_map_queue.zig:496-498` |
| Compute pipeline | `native_async_pipeline.zig:311-313` | `native_async_pipeline.zig:317` |
| Render pipeline | `native_async_pipeline.zig:314-316` | `native_async_pipeline.zig:320` |
| Scope pop | `native_async_scope_info.zig:414-417` | `native_async_scope_info.zig:470` |
| Compilation info | `native_async_scope_info.zig:203-208` | `native_async_scope_info.zig:235` |

All paths above are under `src/engine/`.
Device creation reserves request and loss cells together (`async_root_requests.zig:676-701`).
`getLostFutureApi` accesses that reserved ID (`native_async_device.zig:197-207`).
It is not a ninth operation start. Logging registration is callback control, not a future producer.
The eight starts plus logging account for nine generated callback-info arguments.
Typed observers use separate completion-cell routes. They do not adapt generated callbacks into std.Io.Future.
Device request copies descriptors into owned storage and places the high Device at its final address before publication.
Source inspection found no missing required native future family in these routes.
The generated ProcTable remains a type contract, not a full C dispatch implementation.
Wire and the browser forwarder remain outside this source inventory.
The request-device callback lacks the request-adapter fixture's explicit three-mode loop.
That test distinction does not establish an implementation gap or an additional runtime pass.

**External root requests and device loss.** BG219 completed both actual modes with exit 0 in 189.74 seconds:

```sh
devenv shell -- zig build --build-file /tmp/dusk-native-consumer/build.zig \
  root-async-proof -Doptimize=Debug -j1 && \
devenv shell -- zig build --build-file /tmp/dusk-native-consumer/build.zig \
  root-async-proof -Doptimize=ReleaseSafe -j1
```

The typed route requested an owned Adapter, then an owned Device at its final high-owner address.
It checked copied labels and limits after source mutation.
Distinct generated callback routes transferred real Adapter and Device results through ProcessEvents and released their public receipts.
Both modes printed:

```text
root-native-gpu: word63=113,173 guard-padding=0xa5 viewport-bundle=verified
root-loss: reserved-future=stable userdata-calls=1 reason=destroyed immutable-diagnostic=verified
root-canonical: process-events adapter=1 device=1 loss=1 real-gpu=verified owned-results=released
root-cleanup: device-results,adapter-results,registry,instance released
```

Each mode printed the loss line twice, once for each distinct real Device route.
The reserved loss Future ID remained stable after delivery and repeated destroy.
BG210 and BG219 together exercise all eight native future-start families and the reserved loss notification in Debug and ReleaseSafe.
This is bounded consumer evidence, not all callback-mode combinations, conformance, total coverage, or full C dispatch support.
These commands do not identify a zero-layer selection. No zero-layer claim follows from this root result.
Utility GPU integration and platform completion remain outside this proof.

BG221 then passed the current-source ReleaseSafe registry, root-request, and native-device regression batch.
The command exited 0 in 118.97 seconds:

```sh
devenv shell -- zig build test-async-registry-release-safe \
  test-async-root-requests-release-safe test-native-async-device-release-safe -j1
```

| Shard | Actual ReleaseSafe result |
| --- | ---: |
| Async registry | 42/42 |
| Async root requests | 29/29 |
| Native async Device | 14/14 |
| Total exercised scenarios | 85/85 |

The root fixtures used actual Vulkan Adapter and Device creation, not a zero-device skip.
They exercised fail-N preparation, atomic request/loss acceptance, final-address high ownership, hidden-owner cancellation cleanup, and consumed result receipts.
The batch also exercised Adapter/loss callback modes, timed cancellation, duplicate IDs, reentry, shutdown, detached loss, and reference overflow.
Request-device callback mode coverage remains distinct from the explicit Adapter/loss mode loops.
The previous BG210 and BG219 consumer runs remain separate evidence, not extra scenarios in this 85-test count.
This batch establishes no utility GPU completion, total coverage, full C dispatch, or platform completion.

#### Bounded native utility Debug evidence

BG222 ran the current native utility batch in 132.43 seconds and exited 1.
Nine of twelve roots passed. This is not a complete batch pass or a published utility-consumer GPU result.

```sh
devenv shell -- zig fmt src/engine/adapter.zig src/engine/external_texture.zig \
  test/native_timestamps.zig test/native_indirect.zig test/native_blit.zig \
  test/native_external_texture.zig && \
devenv shell -- zig build test-native-utilities-debug -j2
```

| Observed Debug root | Result |
| --- | ---: |
| Device policy | 2/2 |
| Native kernel | 19/19 |
| Combined reflection | 6/6 |
| Frontend | 13/13 |
| Derived state | 8/8 |
| Capability | 6/6 |
| Internal buffer | 17/17 |
| Internal resources | 4/4 |
| Timestamps | 9/9 |
| Indirect | 4/6 |
| Blit and external fixtures | Compilation failures |

Timestamp tests compare GPU u32 limbs with an independent u128 oracle across valid-bit masks and periods.
The 11,440-byte buffer case preserves `0xa5` guards. The batch includes fail-N and public CopySrc-only 352-byte-buffer paths.
The latter restored actual CopyDestination initialization, not a fixture bypass.
The two timestamp quantization policies had these observed frontend values:

| Quantization | Period bits | Valid bits | Mantissa | Shift | Mask | Delta ticks |
| --- | --- | ---: | ---: | ---: | --- | ---: |
| Disabled | `0x3f800000` | 64 | 8388608 | -23 | `0xffffffff` | 138061 |
| Enabled | `0x3f800000` | 64 | 8388608 | -23 | `0xffff0000` | 112580 |

Both paths checked raw query availability, exact mapped GPU results against the u128 oracle, and padding.
The Adapter-to-Device policy copy now preserves `timestamp_quantization`. Both device-policy regressions passed.
Two indirect tests returned `ResourceDestroyed` before submit.
Blit and external fixtures had compilation failures, not GPU passes.
These observed failures keep utility completion open.
The published utility Debug consumer had a temporary-root stride type compilation error.
Its source correction is not an observed GPU smoke result.
No whole utility batch, ReleaseSafe utility consumer, platform completion, or P6 closure follows from this result.

**Superseding published utility consumer evidence.** BG229 subsequently passed in Debug and actual ReleaseSafe.
The complete command exited 0 in 118.58 seconds:

```sh
devenv shell -- zig fmt /tmp/dusk-native-consumer/src/utilities_proof.zig && \
devenv shell -- env -u VK_INSTANCE_LAYERS -u VK_LOADER_LAYERS_ENABLE \
  -u VK_LOADER_LAYERS_ALLOW VK_LOADER_LAYERS_DISABLE=~all~ \
  VK_LOADER_DEBUG=layer LP_NUM_THREADS=2 \
  zig build --build-file /tmp/dusk-native-consumer/build.zig \
  utilities-proof -Doptimize=Debug -j1 && \
devenv shell -- env -u VK_INSTANCE_LAYERS -u VK_LOADER_LAYERS_ENABLE \
  -u VK_LOADER_LAYERS_ALLOW VK_LOADER_LAYERS_DISABLE=~all~ \
  VK_LOADER_DEBUG=layer LP_NUM_THREADS=2 \
  zig build --build-file /tmp/dusk-native-consumer/build.zig \
  utilities-proof -Doptimize=ReleaseSafe -j1
```

Each mode verified four genuine GPU consumer families:

1. Hardware timestamp queries, valid-bit/period handling, exact quantized output, and guard bytes.
2. Selected indirect ranges with firstInstance disabled and enabled, exact pixels, unchanged arguments, and guards.
3. Stencil offset-1 shader fallback with actual clear/copy, unchanged neighbors, and depth guards.
4. Owned external/browser color conversion, gamma, gamut, flip, and independently derived color and guard checks.

The external route survived caller-array mutation and original plane-alias release.
It also exercised preaccept checks and ExternalTexture destruction after acceptance while pending child leases retained the GPU inputs.
The loader output (`artifact://925`) showed four instance chains and four device chains without active VK_LAYER entries.
The chains connected Application, Loader, and driver/device.
KHRONOS validation was forced disabled in all four instance selections.
The actual driver was llvmpipe LLVM 21.1.8, Mesa 26.2.2.
`LP_NUM_THREADS=2` limited this driver's worker count for the run. It did not replace the Vulkan driver.
This supersedes the earlier published utility compilation failure, not BG222's incomplete permanent batch.
BG229 establishes zero-layer execution for this selected published consumer, not every utility path or platform.
The validation-enabled external fixtures in BG230 had partial results. They do not establish a complete utility batch.
No full utility batch, full gate, platform completion, or P6 closure is claimed here.

**Current native blit regression evidence.** BG231 exited 0 in 148.50 seconds:

```sh
devenv shell -- zig fmt test/native_blit.zig && \
devenv shell -- env LP_NUM_THREADS=2 zig build \
  test-native-blit test-native-blit-release-safe -j1
```

Debug and actual ReleaseSafe each passed 21/21 tests, with zero skips and no captured VUID or error report.
The four-sample depth32 case read 0.625 from all four samples.
Readbacks also checked padded RGBA/BGRA pack/unpack, float/signed/unsigned clears, inactive holes, sparse unsigned slot 7, and preserved stencil/depth neighbors.
Other cases checked offset-1 stencil fallback, offset-2 odd-width depth16, sampler RB swizzle, overlap staging, nonlinear alpha/flip, mip/layer selection, and sRGB formats.
The accepted frontend path released source-creator aliases before fence completion, then checked precise texels and guard bytes.
Fail-N cases exercised parameter/native-pipeline failure, recording poison, rollback, and refusal to accept a submission serial.
Invalid signed bounds, aspects, and mismatched ranges emitted no commands.

The nonconstant linear RGBA8-center oracle uses ideal values with tolerance `1/255 + 0.00002`.
Nearest, constant, and background checks retain tolerance `0.00002`.
This is a fixture quality policy, not a universal Vulkan one-quantum guarantee.
The sampler fixture's separate raw-float midpoint policy remains `1/255` for R/B and exact G/A.
The Vulkan push-constant validation errors were corrected by matching the actual all-stage range.
Multisampled depth validation now follows the declared multisampled layout.
This closes the observed blit shard failures, not the outstanding external fixtures or the entire utility batch.

**Additional current ReleaseSafe utility regressions.** BG232 exited 0 in 506.16 seconds:

```sh
devenv shell -- env LP_NUM_THREADS=2 zig build \
  test-native-kernels-release-safe test-native-indirect-release-safe \
  test-native-timestamps-release-safe test-native-internal-buffers-release-safe \
  test-native-derived-roots-release-safe test-native-internal-resources-release-safe \
  test-native-utility-device-release-safe test-native-utility-capabilities-release-safe \
  test-native-utility-frontend-release-safe test-native-combined-reflection-release-safe -j2
```

| Actual ReleaseSafe root | Result |
| --- | ---: |
| Native kernels | 19/19 |
| Indirect | 6/6 |
| Timestamps | 9/9 |
| Internal buffers | 17/17 |
| Derived roots | 8/8 |
| Internal resources | 4/4 |
| Device policy | 2/2 |
| Capabilities | 6/6 |
| Frontend | 13/13 |
| Combined reflection | 6/6 |
| Total | 90/90 |

The captured output contained no VUID or error report.
Together with BG231's 21/21 ReleaseSafe blit tests, these results cover eleven utility roots.
They supersede the earlier indirect failures and add actual ReleaseSafe evidence, not a complete twelve-root batch pass.
The hardware timestamp period bits remained `0x3f800000`, valid bits 64, mantissa 8388608, and shift -23.
Observed deltas were 75513 with mask `0xffffffff` and 80401 with quantization mask `0xffff0000`.
These values describe this run. They are not timing or throughput guarantees.

The external fixture still had four logical failures outside this passing command.
Previous mixed layouts with UINT_MAX auxiliary bindings returned actual `VkOutOfHostMemory`.
The driver's internal allocation mechanism is an inference, not an observed fact.
The selected bounded auxiliary ABI in `docs/30-port-design.md` preserves public bindings and unchanged caller SPIR-V.
Its source cutover alone is not a generated-artifact or GPU pass.
No whole twelve-root utility batch or P6 closure is claimed here.

#### Native SPIR-V stage constants: 2026-10-08

This evidence covers native `StageInput.constants`, not all M14 work or WebGPU conformance.
Generated WebGPU Device ABI integration and async pipeline creation remain outside this result.
No WGSL parser or uninitialized WGSL override behavior is claimed.

The observed RED run, BG93, gave `SpecId` 7 values `2` and `3` the same compute key.
The pipeline-cache shard passed 17/18 tests and failed the identity regression.
BG94 passed SPIR-V 14/14 and shader-module 7/7 tests.
Three other checks initially failed compilation because fixture device options and binding offsets needed fixes.
Those compilation failures were not runtime passes.
Before the final review fixes, BG95 passed all 10/10 build steps.
Its pipeline-cache shard passed 24/24 tests, including the former RED regression.

BG97 tested the reviewed shared-ID, host-read-barrier, and mixed-scalar-family implementation.
The focused command passed all 16/16 build steps:

```sh
zig build test-spirv test-shader-module test-pipeline-cache \
  test-compute-specialization test-compute-specialization-release-safe -j2 --summary all
```

SPIR-V passed 15/15 tests. Shader-module passed 7/7. Pipeline-cache passed 24/24.
Host tests cover alias and order identity, scalar normalization, and compute, vertex, and fragment stage ABI payloads.
They also cover invalid cached-input rejection, unaligned byte input, checked word counts, and fail-N key and factory rollback.
Mixed-scalar-family coverage permits identical size and bits, and rejects differing sizes or bits, negative zero, and range failures.
Native graphics stage information passed host inspection. No actual specialized graphics draw proof exists yet.

Both compute shards passed 4/4 tests: Debug and actual ReleaseSafe.
Each run contains two new compute scenarios and two existing imported triangle tests.
It does not contain four new compute tests.
Each mode performs ten actual dispatches and coherent readbacks.
Both scenarios record through `cmd.compute_encoder`, then replay through `engine.command_buffer`.
The dispatch-table `SHADER_WRITE` to `HOST_READ` barrier follows replay, before command-buffer completion.
The scenarios submit Vulkan work, wait, and read coherent memory.

| Scenario | Readbacks: default, named, numeric, reversed named, reversed numeric | Unique pipelines after each dispatch |
| --- | --- | --- |
| Distinct IDs | `113/25/35/25/35` | `1/2/3/3/3` |
| Shared ID | `121/44/55/44/55` | `1/2/3/3/3` |

The final two dispatches in each scenario reuse cached pipelines without changing their outputs.
Different converted values create distinct pipelines.
The shared-ID fixture gives two `uint32` shader result IDs one `SpecId` 7 and independent defaults.
BG97 observed these outputs after the review fixes.
The earlier BG95 results predate the host-read barrier and shared-ID corrections.

Final style and cleanup changes followed BG97.
BG99 passed 68/73 steps but failed root compilation in Debug and ReleaseSafe.
The new `TooManyConstants` test used invalid slice structure syntax.
This test-source error was not a production-code failure. Named GPU and host shards passed.
The repair uses an explicit pointer slice and checks whether the byte range fits the target.
The length rejection occurs before any dereference.
BG102 then passed all 73/73 aggregate steps (`artifact://366`) in 312.62 seconds.
Root tests passed 262/262 in Debug and 262/262 in actual ReleaseSafe.
All 11 contained codec tests ran, including mixed families, oversized input, fail-N allocation, and rounding.
Both GPU shards again passed 4/4, with ten real dispatch/readbacks per mode.
BG98 initially reported 35 `ziglint` style findings.
After fixes, BG100 passed `ziglint`, but `zlint` reported one unreachable-cleanup warning.
The final cleanup fix replaces that unreachable path with a panic.
Before the boundary-test repair, BG101 passed the selection of exactly 142 explicit files.
`ziglint` reported zero diagnostics. `zlint --deny-warnings` reported zero errors and zero warnings.
The reported durations were 7.05 seconds for `ziglint` and 208 ms for `zlint`.
BG104 passed final source lint after the boundary-test repair, with exactly 142 explicit files.
`ziglint` reported zero diagnostics in 8.52 seconds.
`zlint --deny-warnings` reported zero errors and zero warnings in 295 ms.
BG103 passed all three cross-test rows in 94.71 seconds.
Each row executed 262 root tests: `x86_64-linux`, `aarch64-linux`, and big-endian `powerpc64-linux`.
The summary reported `pass=3`, `fail=0`, `build_only=0`, and `partial=0`.
The run ID is `20261008-002745-1243037-21180`.
These rows prove foreign root-test execution, not foreign GPU execution.

BG105 passed the zero-layer compute run in 1.88 seconds (`artifact://371`), with all 7/7 build steps.
Debug and actual ReleaseSafe each passed 4/4 tests, with ten real dispatch/readbacks per mode.

```sh
env VK_INSTANCE_LAYERS= VK_LOADER_LAYERS_DISABLE='*' VK_LOADER_DEBUG=layer \
  zig build test-compute-specialization test-compute-specialization-release-safe -j2 --summary all
```

All eight instance call stacks showed Application → Loader → Drivers.
Device call stacks showed Application → Loader → Device, with lavapipe llvmpipe LLVM 21.1.8.
The empty layer variable caused a loader warning about `""`, but no call stack inserted a validation layer.
BG106 passed `devenv shell -- zig-gate --no-zbc` with exit code zero in 36.16 seconds.
It printed `GATE PASSED`.
Exactly five stages passed: `fmt --check`, build, test, ast-check, and `zlint`.
It explicitly omitted `zbc`, had no `zwanzig` stage, and left coverage off.
BG104 source lint and BG103 cross-tests supply separate supplemental evidence.
This is not a full ten-stage green result.
The full ten-stage contract remains unclaimed and outside the permitted analyzer boundary.
No current clean analyzer result is claimed.
The pre-feature analyzer snapshot does not establish a current warning count or clean analysis for the new source.
Workers did not rerun `zwanzig` or `zbc`.

#### Phase 1 current observations: 2026-10-08

BG108 (`artifact://412`) executed generator regeneration and source formatting before the focused checks.
The focused run passed 25/28 build steps in 263.91 seconds, then exited with code 1.
Phase 1 remains RED. Test-source repair and reverification are pending.

Pipeline-cache test compilation reported four errors, so that shard has no runtime result.
One compute key descriptor omitted `limits`.
Three device initializers omitted `uncaptured_context` and `uncaptured_callback`.
These compilation errors do not negate the runtime passes in the other focused shards.

| Focused shard | Observed result |
| --- | --- |
| API conformance, Debug | 14/14 tests passed |
| SPIR-V, Debug | 28/28 tests passed |
| Render pipeline, Debug and actual ReleaseSafe | 2/2 tests passed per mode |
| Triangle, Debug and actual ReleaseSafe | 5/5 tests passed per mode |
| Compute specialization, Debug and actual ReleaseSafe | 8/8 tests passed per mode |
| Pipeline cache, Debug | Compilation failed with four errors |

Each triangle shard contains five tests:

1. Existing 2×2 triangle draw and sixteen-channel readback.
2. Existing replayed blend-constant draw with clear and padding checks.
3. New vertex-specialization GPU scene with changed coverage and canonical cache identity.
4. New fragment-specialization GPU scene with changed color and canonical cache identity.
5. New host fail-N test for graphics specialization-key allocation rollback.

The specialized graphics scenes check changed pixels, preserved clear pixels and padding, and live pipeline reuse.
Each compute shard contains three compute tests and imports all five triangle tests.
Thus 8/8 is not eight new compute tests.
The two existing scalar scenarios passed defaults, overrides, shared-ID behavior, and canonical cache reuse.
The new workgroup scenario passed native invocation-count and coverage readbacks for `BuiltIn WorkgroupSize`, including shared IDs.

| Workgroup fixture | Invocation counts across five cases | Coverage masks across five cases | Unique pipelines |
| --- | --- | --- | --- |
| Distinct IDs | `4/6/8/6/8` | `15/63/255/63/255` | `1/2/3/3/3` |
| Shared ID | `4/9/16/9/16` | `15/511/65535/511/65535` | `1/2/3/3/3` |

BG108 does not establish a current root aggregate, zero-layer run, lint result, cross-test result, or procedure ABI compatibility result.
The API conformance pass does not establish C ABI compatibility.
The BG102 aggregate and BG105 zero-layer records above remain historical evidence for their earlier source state.
They do not establish those results for the Phase 1 source.
The protected analyzer boundary remains unchanged. Workers did not run `zwanzig` or `zbc`.

#### Phase 1 bounded GREEN, with review fixes pending: 2026-10-08

After the BG108 compilation repairs, BG109 (`artifact://419`) passed 75/77 aggregate steps.
Its pipeline-cache shard passed 28 tests and failed two.
The zero-axis case expected `WorkgroupAxisZero`, but the resolver returned `SpirvMalformed`.
The wrong-stage fixture retained an invalid workgroup mode, so decoding returned `SpirvMalformed` before the expected `StageMismatch`.
The test expectation and fixture were corrected before BG110.

BG110 (`artifact://426`) executed regeneration and formatting, then passed all 77/77 aggregate build steps.
This is a bounded GREEN result for that source state, not Phase 1 closure.

| Shard | BG110 aggregate result |
| --- | --- |
| API conformance, Debug | 15/15 tests passed |
| SPIR-V, Debug | 29/29 tests passed |
| Pipeline cache, Debug | 30/30 tests passed |
| Root, Debug and actual ReleaseSafe | 262/262 tests passed per mode |
| Triangle, Debug and actual ReleaseSafe | 5/5 tests passed per mode |
| Compute specialization, Debug and actual ReleaseSafe | 8/8 tests passed per mode |
| Render pipeline, Debug and actual ReleaseSafe | 2/2 tests passed per mode |

The triangle and compute test counts retain the composition described in the BG108 record.
They do not represent five new graphics tests or eight new compute tests.
BG110 also passed all 13/13 steps of this explicit zero-layer selection:

```sh
env VK_INSTANCE_LAYERS= VK_LOADER_LAYERS_DISABLE='*' VK_LOADER_DEBUG=layer \
  zig build test-triangle test-triangle-release-safe \
  test-compute-specialization test-compute-specialization-release-safe -j2 --summary all
```

Triangle passed 5/5 and compute specialization passed 8/8 in each mode.
Loader logs showed Application → Loader → Drivers and Application → Loader → Device call stacks.
The filter explicitly disabled `VK_LAYER_KHRONOS_validation`.
The driver was lavapipe, reported as llvmpipe LLVM 21.1.8.
These logs establish zero-layer execution for this selection and source state.

Source review then found six production issues with valid-input decoding, feature gates, and stage selection:

1. A `WorkgroupSize` builtin could hide the presence of `LocalSizeId` from the feature gate.
2. Entry selection needed both execution model and entry-point name.
3. Integer expression evaluation needed wrapping arithmetic.
4. Signed values needed bit-pattern handling.
5. Expression validation needed opcode-specific type and width rules.
6. `UDiv` and `UMod` needed unsigned interpretation.

Those corrections and final reverification are pending.
BG110 does not prove the corrected behavior or total coverage of the new implementation.
No current full gate, lint, cross-test, procedure ABI compatibility, or protected-analyzer result is claimed.
The protected analyzer boundary remains unchanged. Workers did not run `zwanzig` or `zbc`.

#### Phase 1 semantic corrections verified, final checks pending: 2026-10-08

BG111 (`artifact://436`) passed all 77/77 aggregate steps and exited with code zero in 287.82 seconds.
All six production findings listed in the BG110 record were corrected.
Their regressions passed after the corrections.
The evidence consists of source-backed defects and passing-after tests.
No failing-before execution was observed for these new review cases.

| Shard | BG111 aggregate result |
| --- | --- |
| API conformance, Debug | 15/15 tests passed |
| SPIR-V, Debug | 38/38 tests passed |
| Pipeline cache, Debug | 32/32 tests passed |
| Root, Debug and actual ReleaseSafe | 262/262 tests passed per mode |
| Triangle, Debug and actual ReleaseSafe | 5/5 tests passed per mode |
| Compute specialization, Debug and actual ReleaseSafe | 8/8 tests passed per mode |
| Render pipeline, Debug and actual ReleaseSafe | 2/2 tests passed per mode |

SPIR-V gained nine arithmetic and metadata tests compared with BG110.
Pipeline cache gained two stage-selection and feature-gate tests.
The graphics and compute counts retain the BG108 composition.
BG111 repeated current GPU readbacks with this explicit zero-layer selection:

```sh
env VK_INSTANCE_LAYERS= VK_LOADER_LAYERS_DISABLE='*' \
  zig build test-triangle test-triangle-release-safe \
  test-compute-specialization test-compute-specialization-release-safe -j2 --summary all
```

All 13/13 selected steps passed.
Triangle passed 5/5 and compute specialization passed 8/8 in Debug and actual ReleaseSafe.
This run did not request a verbose loader trace.
BG110 supplies the separate loader-call-stack evidence. BG111 supplies current execution and readback evidence under the explicit layer-disabling environment.
An `ast-check` selection of five touched production, build, and generator files also passed.

BG112 then reported 24 style findings across 13 explicit files.
The style corrections landed after that RED result.
The build now has three concrete ReleaseSafe regression selectors:
`test-spirv-release-safe`, `test-pipeline-cache-release-safe`, and `test-api-conformance-release-safe`.
BG113 aggregate, source lint, and formatting checks are pending.
No BG113 result or Phase 1 closure is claimed here.
No full gate, cross-test, procedure ABI compatibility, total-coverage, or protected-analyzer result is claimed.
Workers did not run `zwanzig` or `zbc`.

#### Phase 1 final bounded verification: 2026-10-08

BG113 (`artifact://441`) passed all 83/83 aggregate steps.
The added concrete ReleaseSafe shards executed their tests, not only compilation.

| Shard | Debug | Actual ReleaseSafe |
| --- | --- | --- |
| API conformance | 15/15 | 15/15 |
| SPIR-V | 38/38 | 38/38 |
| Pipeline cache | 32/32 | 32/32 |
| Root | 262/262 | 262/262 |
| Triangle | 5/5 | 5/5 |
| Compute specialization | 8/8 | 8/8 |
| Render pipeline | 2/2 | 2/2 |

All listed tests passed. The GPU counts retain the BG108 test composition and actual scene readbacks.
BG113 source lint was still RED despite the aggregate pass.
`ziglint` passed its 13-file selection, but `zlint` reported one `unsafe-undefined` field-default warning.
The repair moved the undefined path storage into the explicit `Evaluation` constructor.
BG114 then passed all 13/13 directed steps, with SPIR-V 38/38 and compute specialization 8/8 in both modes.
The compute shards also executed their five imported triangle tests.
BG114 remained RED because `zlint` required a safety comment.
The final comment explains the initialized dependency prefix: each slot is written before descendants read it.

The parent's final check command exited with code zero in 2.83 seconds.
`ziglint` reported zero diagnostics across 13 explicit files.
`zlint --deny-warnings` reported zero errors and zero warnings across those files in 16 ms.
Formatting checks passed for 15 files, including the two generated objects and procedure files.
Final `ast-check` passed for `workgroup.zig` and `build.zig`.
BG111 supplies the earlier five-file production, generator, and build `ast-check` result for the other unchanged files.
All changed-file LSP diagnostic checks passed.

This evidence proves the specified Phase 1 behavior within the recorded native scenarios and host regressions.
It does not claim a full gate, new cross-test coverage, total coverage, procedure ABI compatibility, or protected analysis.
It does not establish `NoWrap` behavior or native wide-integer feature support.
Phase 2 native integration is not implemented.
Workers did not run `zwanzig` or `zbc`.

#### Native integration prerequisites, bounded evidence: 2026-10-08

These observations cover header generation and native callback binding prerequisites.
They do not establish Phase 2 native integration success or native consumer execution.
The earlier native procedure-table and optional-buffer evidence remains unchanged.

BG117 failed the exact Vulkan header version 365 pin because the old development environment supplied version 357.
Despite that failure, generation published version 357 output.
The permanent environment fix fetches `CoffeeImpliesCode/vulkan-headers` at revision `8249cb829eb402c65cb7e3778c51b0f8edc4a4b6` as header data only.
The environment now supplies `/nix/store/q4y92hvwlq8k1bj7icm6xiyg7cvcyqr4-source/vulkan`.
Its actual `VK_HEADER_VERSION` is 365.
`UpdateSourceFiles` now depends transitively on `CheckFile`, so a failed pin check blocks publication.

| Run | Observed prerequisite result |
| --- | --- |
| BG123 | An isolated five-file generation workspace with actual version 357 headers failed 3/6 steps, as expected. |
| BG123 | `cmp` confirmed both copied outputs, `src/vulkan.zig` and `src/vk/dispatch.zig`, remained byte-identical afterward. |
| BG124 | Normal generation without overrides passed 6/6 steps and corrected the checked-in output to version 365. |

BG124 used the normal command:

```sh
devenv shell -- zig build generate -j2 --summary all
```

BG122 failed a real exported `api.LoggingCallback` definition and invocation.
Its C calling convention could not accept the native `[]const u8` parameter.
The generator now emits all 14 callback-function declarations with the native default calling convention.
The separate Vulkan and foreign function-pointer branch is unchanged.
Callback information, mode, userdata, and nullability are unchanged.
BG126 regenerated and formatted the output, then repeated the same actual callback-binding smoke.
Only the implementation's `.c` convention was removed.
The smoke passed 1/1 in Debug and 1/1 in explicitly optimized ReleaseSafe.

BG126's focused native, null, limits, worker, pipeline, and API selection remains RED.
The 12-shard selection encountered an ambiguous `Device.InitError` and three native-test initializers that omitted required `power_preference`.
The corrective owner is repairing these compilation blockers.
These failures do not establish native runtime success or a native consumer result.
No full gate or protected-analyzer result is claimed. Workers did not run `zwanzig` or `zbc`.

#### Native prerequisites and worker drain follow-up: 2026-10-08

BG127 passed 31/37 focused steps. The selection remains RED.
The earlier `Device.InitError` alias and required `power_preference` initialization blockers were resolved.
Native-device Debug and actual ReleaseSafe compilation then failed in `native_resources.validateFinished`.
Its declared error union omitted command-iterator errors.
The source correction landed after BG127 but has not yet compiled.
Three native capability review findings also remain under correction.
No native consumer execution is established.

| BG127 shard | Debug | Actual ReleaseSafe |
| --- | --- | --- |
| API conformance | 18/18 passed | 18/18 passed |
| Pipeline cache | 34/34 passed | 34/34 passed |
| Limits | 13/13 passed | 13/13 passed |
| Null device | 17/17 passed | 17/17 passed |
| Worker pool | 2/2 passed | 2/2 passed |
| Native device | Compilation blocked | Compilation blocked |

API conformance covers all nine method callback-information records and all five logical descriptor members.
The tests cover chain copies, mode, userdata, and nullable shape.
The census remains 347 objects, 205 methods, and 571 members.
Pipeline-cache tests include owned-hit aliasing and final destruction.

The worker proof preserves an observed failing-before result.
BG115's standalone accepted-task shutdown sentinel expected `1` but read `0`.
After the drain repair, BG116 passed that standalone regression 1/1 in Debug and actual ReleaseSafe.
BG127 passed both the ordinary 1,000-task test and the deterministic borrowed-context shutdown-drain regression in each mode.
Successful posts borrow contexts until `task.run` returns. Rejected posts do not borrow them.
Shutdown and exhaustion stop acceptance, then drain accepted tasks before worker exit.
The normal iteration limit permits a bounded queued tail, not unbounded execution.
The source contract does not establish an observed exhaustion-limit runtime test.

These results do not implement new async futures, events, or requests. Async Phase 3 remains pending.
No full gate, native consumer, or protected-analyzer result is claimed.
Workers did not run `zwanzig` or `zbc`.

#### Explicit worker Io and native safety RED evidence: 2026-10-08

The explicit Task-Io cutover changed `Task.run` to `*const fn (io: std.Io, context: *anyopaque) void`.
`QueuedTask` carries the exact `postTask` Io value through callback return.
The caller keeps that Io's backend state and task context alive until the callback returns.
Worker synchronization uses the explicit initialization Io passed at thread entry.
Its caller-owned backend state remains alive until `join` returns.
No global or pool-Io fallback supplies the callback Io.
Accepted-task drain and rejection-before-acceptance guarantees remain unchanged.

BG132 formatted the worker source, worker test, and standalone shutdown reproduction before executing the reproduction.
The standalone reproduction passed 1/1 in Debug and 1/1 in explicitly optimized ReleaseSafe.
The command exited with code zero in 31.58 seconds.
This is current standalone shutdown evidence, not a new Io-wiring test.
The full two-test worker shard after the Task-Io cutover remains pending.
BG127's 2/2 results in both modes predate this cutover.

BG131 ran five new native safety cases with `--test-filter 'native safety'` before production changes.
Debug reported zero passed and five failed, with exit code 1.
The observed failure classes were:

1. Teardown did not refuse an active wait.
2. A failed idle wait destroyed the owner.
3. Replay admitted a staged unmap.
4. A public wait raced low-level queue access.
5. An implicit-submit wait raced low-level queue access.

The native operation-safety owner is correcting production behavior.
No passing repair result or native consumer result is claimed.
Async Phase 3 remains pending. No full gate or protected-analyzer result is claimed.
Workers did not run `zwanzig` or `zbc`.

#### Native safety and owned-error component verification: 2026-10-08

BG134 passed the current native safety selection 10/10 in Debug and 10/10 in explicitly optimized ReleaseSafe.
The command exited with code zero in 113.56 seconds.
All five BG131 failing-before cases now pass.
The selection also covers queue leases, device loss, idle failure, and native mutex pins.
The four production safety corrections landed before this run.

`getQueue(io)` now returns `OperationError!QueueLease`.
The lease owns the queue gate and a lifetime pin, but stores no Io.
`deinit(io)` remains readable and is idempotent for the same lease.
Nonterminal failures preserve the owner.
`DeviceLost` permits lifetime-only retirement, with children destroyed before parents.
This path does not report normal completed-serial progress.
These selected tests do not establish full native consumer execution.
At this point, BG135's full 12-shard selection and BG136's Debug consumer execution were pending.

BG133 independently tested `test/error_sets.zig` through the exact exported core module.
The module mapping used `-Mdusk=/tmp/dusk-owned-errors-root.zig` and `-Mcore=src/core/root.zig`.
The temporary root contained `pub const core = @import("core");`.
The Debug and explicitly optimized ReleaseSafe runs each passed 15/15 tests.
The command exited with code zero in 38.99 seconds.
Each run contains ten new ownership tests and five existing tests.

The component supplies allocator-owned `ErrorDraft`, `ErrorReservation`, and `ErrorRef` nodes with immutable error views.
Node and payload allocators can differ. Each allocation returns to its exact allocator.
Reserved references and sealing require no allocation.
Static out-of-memory, device-loss, and `@errorName` messages remain available.
Retain uses bounded compare-and-swap. `releaseMany` consumes prepaid reference slots.
Owned nodes clear borrowed trace data.
`EssentialErrorData.init` now frees each owned context string if a later allocation fails.
The existing mutable draft API remains available.

These owning nodes are original Dusk glue, not an invented Dawn function port.
BG133 is component proof only. It does not implement async completion, error scopes, a registry, or callback delivery.
The current core scope still borrows error data. Its ownership cutover remains pending in Phase 3.
Snapshot diagnostics checks are not yet observed.
No full gate, native consumer, or protected-analyzer result is claimed.
Workers did not run `zwanzig` or `zbc`.

#### Post-cutover worker result and consumer compilation RED: 2026-10-08

BG135 (`artifact://529`) passed all 37/37 focused steps and exited with code zero in 263.17 seconds.
Each shard executed in Debug and actual ReleaseSafe:

| Shard | Tests passed per mode |
| --- | --- |
| Native device | 13/13 |
| Null device | 17/17 |
| Limits | 21/21 |
| Worker pool | 2/2 |
| Pipeline cache | 34/34 |
| API conformance | 18/18 |

Native device includes three earlier tests and ten safety tests.
Limits includes six budget and two hardware-admission regressions.
The worker result follows the explicit Task-Io cutover.
This focused proof predates the subsequent native-consumer contract corrections.

BG136 attempted real published-consumer Debug compilation.
It failed with four errors and exit code 1 in 19.68 seconds.
The high-level `OperationError` omitted existing compute and render `pipeline.CreateError` members.
`compatibleRenderPass` returned `RenderPassInfo` where the caller expected a Vulkan render-pass handle.
The temporary consumer's `tempSetPipeline` options omitted `requirements`.
The source fix composes the existing compute and render `pipeline.CreateError` sets into the finite `OperationError` set.
The native render-pass fix extracts `RenderPassInfo.render_pass`.
The temporary consumer now derives `requirements` from its actual empty layout.
No GPU consumer execution or readback proof is established by this failed compile.
The published consumer exposed lazy bodies that the focused shards had not compiled.
BG135's passes do not establish that consumer contract.

#### Owned shader diagnostics and consumer runtime RED: 2026-10-08

BG138 tested the shader-module shard through the published root.
`zig build test-shader-module` passed 4/4 Debug steps and 14/14 tests.
The separate `zig test test/shader_module.zig -OReleaseSafe` invocation explicitly optimized the root, dusk, and Vulkan modules.
That actual ReleaseSafe run passed 14/14 tests.
The combined command exited with code zero in 67.11 seconds.
Each run contains seven new ownership tests and seven earlier tests.
The new tests cover source-text overwrite, source-array and module destruction, cloning, borrowed builder text, and every allocation-failure rollback.

`snapshot(gpa, []Message)`, `Messages.clone(gpa, Messages)`, and `snapshotCompilationInfo(gpa, *ShaderModule)` produce owned snapshots.
Each snapshot owns its message array and one contiguous text allocation.
It preserves all metadata, including empty text.
The error-module constructor now owns caller-supplied text.
`getCompilationInfo` still returns an immutable module-lifetime borrow.
These snapshots are original Dusk glue, not fabricated Dawn function ports or a new async implementation.

BG137 compiled the published native consumer after the finite-error and `RenderPassInfo` source corrections.
Execution then terminated with `SIGABRT`.
The temporary consumer's deferred `pass.deinit`, at main line 196, reached double or poisoned `RenderEncoderBase.usage` cleanup.
`RenderEncoderBase.end` always defers `self.deinit`, on both success and failure.
That cleanup releases the lists and sets `self.* = undefined`.
The consumer's unconditional deferred cleanup therefore read poisoned usage and attempted a second cleanup.
This was a consumer ownership defect, not a library ABI defect.
The temporary render scope now tracks `owns_pass`.
It cleans up only when a recording step fails before `end`.
Immediately before `end`, it relinquishes ownership because `end` consumes the pass on both outcomes.
`ComputeEncoder.end` has a different contract: it transfers usage without deinitializing the encoder.
The consumer retains its compute cleanup.
BG137 did not establish a GPU consumer pass or complete readback result.

#### Published native consumer execution verified: 2026-10-08

BG139 ran the actual out-of-tree published-module consumer at `/tmp/dusk-native-consumer` after these fixes.
Debug and actual ReleaseSafe each passed all 4/4 build steps.
The combined command exited with code zero in 90.49 seconds.
Both runs explicitly set `VK_INSTANCE_LAYERS` to an empty value and `VK_LOADER_LAYERS_DISABLE` to `~all~`.
This records the selected zero-layer environment, not a new loader-call-stack inspection.

The consumer reported these five proof lines in each mode:

| Proof line | Observed result |
| --- | --- |
| Compute specialization and wait | Output `113`, preserved `A5` padding, and completed serial wait |
| `LocalSizeId` specialization | Workgroup `4×2×1`, invocation count `8`, coverage mask `255`, and preserved `A5` padding |
| Graphics specialization | RGBA8 pixels red/red/blue/blue, row pitch `256`, and preserved `A5` padding |
| `imageCubeArray` | Queried and enabled feature, then created a 12-layer view |
| Cleanup | Device, list, and instance cleanup completed |

The consumer used the published module, not manual `VkDevice`, queue, or backend assembly.
It used no fake runtime or GPU fallback and skipped no GPU case.
BG139 supplies actual compute, graphics, feature-query, and cleanup evidence for this consumer.
It does not replace the full affected-shard or aggregate checks after the source corrections.
BG135's 37/37 result predates those corrections. BG133, BG134, and BG138 retain their separate component scope.
Current full affected-shard, aggregate, and clean permitted-style results remain unobserved.
No coverage result, full gate, `zbc`, or `zwanzig` result is claimed.
This consumer does not prove async completion, driver-cache behavior, presentation, or mobile execution.
Phases 3 and 4 remain pending. The retained-shell and shared-`GuardRc` proposals are not implemented by this proof.

#### Post-consumer focused checks and style findings: 2026-10-08

BG140 followed the finite-error-set and render-pass source corrections.
It passed all 25/25 focused build steps and the default published build's 1/1 step.
The combined command exited with code zero in 101.36 seconds.

| Shard | BG140 result |
| --- | --- |
| Native device, Debug and actual ReleaseSafe | 13/13 tests passed per mode |
| Limits, Debug and actual ReleaseSafe | 21/21 tests passed per mode |
| Worker pool, Debug and actual ReleaseSafe | 2/2 tests passed per mode |
| Error sets, Debug through the published root | 15/15 tests passed |
| Shader module, Debug | Cached 14/14 passing result |

BG140 adds published-root error-set evidence. BG133 used the isolated exported-core mapping in both modes.
BG138 supplies the separate shader-module Debug and actual ReleaseSafe results.
BG140 is a focused selection, not a full affected-shard or aggregate result.
It precedes the subsequent source-style corrections.

Six LSP diagnostic requests returned `OK`.
They covered native device, context, capability, core errors, compilation messages, and native tests.
This records diagnostic requests, not an AST or runtime test result.

BG142 passed format checks for the explicit selection of 24 affected files.
The subsequent `ziglint` command reported warnings and exited with code 1 in 1.68 seconds.
The command used `&&`, so `zlint` did not execute.
Source owners corrected the import, line-style, allocator, comptime, and Io-order findings before BG143.
The exact false-positive contract report for the `Z030` deinitialization heuristics remains pending.
Refused or stopped owners must retain their safety contract. A style fix must not poison them to silence a heuristic.
No clean style, AST, full aggregate, coverage, full gate, or protected-analyzer result follows from these observations.

#### Source-style corrections and repeated native execution: 2026-10-08

BG143 formatted eight selected files, then repeated focused native checks and the actual published-module consumer.
The formatter changed three source files and collapsed several manual line breaks.
The focused selection passed all 21/21 build steps.

| Shard | BG143 result |
| --- | --- |
| Native device, Debug and actual ReleaseSafe | 13/13 tests passed per mode |
| Null device, Debug and actual ReleaseSafe | 17/17 tests passed per mode |
| Limits, Debug and actual ReleaseSafe | 21/21 tests passed per mode |

The actual consumer again passed all 4/4 steps in Debug and all 4/4 in actual ReleaseSafe.
Each mode reported the same five proof lines recorded for BG139.
The combined command exited with code zero in 185.25 seconds (`artifact://540`).
This is a focused and consumer result, not a full aggregate result.

BG144's directory-based `zlint` invocation reported zero errors and zero warnings across zero files.
That invocation checked no source files and supplies no valid lint proof.
BG145 reported `Z030`/`Z023` findings and eight remaining `Z024` long-line findings.
The later BG150 classification identifies six semantic false positives, not the initially reported seven.
Source owners corrected the remaining expressions without relying on manual line breaks that the formatter removes.
BG144 and BG145 ran concurrently with BG143's formatter.
Their outputs do not establish a stable post-format lint result.
At this point, serial checks against explicit file paths remained necessary after the remaining corrections.
No tool suppression or protected-analyzer change accompanies these results.
No clean style, AST, full aggregate, coverage, or full-gate result is claimed.

#### Serial format, AST, and explicit-file lint observations: 2026-10-08

BG146 passed two stable file paths through standard input to `zlint`.
It reported one unsafe-undefined warning. The owner corrected the location of the ownership `SAFETY` comment.
BG147 formatted four files and passed format checks for five files.
Its explicit-file `zlint` run checked 23 files and reported zero errors and seven warnings.
Three warnings concerned caught unreachable instance paths.
The other four concerned a Vulkan format-query comment, a `SafetyProbe` undefined default, queue initialization, and a contender-Io comment.
Source owners corrected the actual invariants and safety comments.
The fixture corrections attach the lifetime and use a literal queue, not `Queue.init`.

BG148 passed selected AST checks for errors, device, shader messages, shader module, threads, and build files.
The command exited with code zero in 3.11 seconds.
BG149 formatted six files and passed format checks for the 24-file selection.
Its AST checks passed for instance, native context, native resources, native capabilities, and native tests.
The command exited with code zero in 4.27 seconds.
These AST results cover the listed files, not the whole tree.

BG151 ran `zlint` after formatting with 23 explicit file paths through standard input.
It reported zero errors and zero warnings in 0.88 seconds.
Unlike BG144, this command checked source files.
This is a clean selected-file `zlint` result, not clean `ziglint` or a full-gate result.

BG150 ran `ziglint` after formatting and exited with code 1 in 1.71 seconds.
It reported six known semantic false positives and one new genuine Io-order finding in the static test initializer `initUnattached`.
Five false positives are `Z030` findings for instance, native instance, high-level device, `QueueLease`, and native context.
The sixth is a `Z023` finding for the nested `QueueLease`.
The initializer correction stayed queued while the source remained frozen for BG152.
No tool suppression, protected-analyzer change, coverage result, full aggregate, or full-gate result is claimed.

#### Frozen-source native and consumer checks: 2026-10-08

BG152 completed against the frozen source state and exited with code zero in 170.81 seconds.
The six focused shards passed all 19/19 build steps.

| Shard | BG152 result |
| --- | --- |
| Native device, Debug and actual ReleaseSafe | 13/13 tests passed per mode |
| Null device, Debug and actual ReleaseSafe | 17/17 tests passed per mode |
| Limits, Debug and actual ReleaseSafe | 21/21 tests passed per mode |

The actual out-of-tree published-module consumer passed all 4/4 steps in Debug and all 4/4 in actual ReleaseSafe.
Both runs explicitly set `VK_INSTANCE_LAYERS` to an empty value and `VK_LOADER_LAYERS_DISABLE` to `~all~`.
Each mode reported five proof lines:

| Proof line | BG152 observed result |
| --- | --- |
| Compute | Output `113` and preserved `0xa5` padding |
| `LocalSizeId` | Workgroup `4,2,1`, invocation count `8`, coverage mask `255`, and preserved `0xa5` padding |
| Graphics | Pixels red/red/blue/blue, row pitch `256`, and preserved `0xa5` padding |
| Cube array | Enabled feature and created a 12-layer view |
| Cleanup | Device, adapter list, and instance cleanup completed |

This records actual GPU execution, not test scaffolding or a full-gate result.
The owner then applied the test-only initializer Io-order correction.

#### Phase 2 bounded native-integration completion: 2026-10-08

BG153 followed the test-only initializer argument reorder.
It formatted the test source, passed format and AST checks, and passed all 7/7 native-device build steps.
Debug and actual ReleaseSafe each passed 13/13 native-device tests.
The final `ziglint` step returned six known semantic findings, so the combined command exited with code 1 in 57.11 seconds.
The genuine static-initializer Io-order finding no longer appeared.
No genuine warning remained in this observed `ziglint` output.

| Rule | Reported owner | Source line |
| --- | --- | --- |
| `Z030` | `Instance` | 254 |
| `Z030` | `NativeInstance` | 16 |
| `Z030` | High-level device | 227 |
| `Z030` | `QueueLease` | 397 |
| `Z030` | Native context | 447 |
| `Z023` | Nested `QueueLease` | 397 |

These six findings are semantic false positives, not a clean `ziglint` result.
The ownership and teardown contracts remain intact. No suppression removes these findings.
BG151's actual 23-file clean `zlint` result predates the test-only argument reorder.
No post-reorder `zlint` result is claimed.

This completes the bounded Phase 2 native-integration record before the Phase 3 core-guard cutover.
BG152 supplies the frozen-source GPU consumer proof. BG153 supplies the subsequent test-only correction and native-device proof.
Neither result establishes the Phase 3 or Phase 4 shared-`GuardRc` cutover.
No full clean gate, full aggregate, coverage, async, driver-cache, presentation, or mobile proof is claimed.
The protected `zbc` and `zwanzig` stages remain excluded.


#### Historical pre-feature snapshots: 2026-10-07

The following aggregate, gate, lint, cross-test, zero-layer, and analyzer records predate native stage constants.
They remain evidence for that earlier source state only.

On 2026-10-07, `devenv shell -- zig build test -j2 --summary all` passed 69/69 build steps.
The initial captured summary is `artifact://116`. Later `artifact://133` also passed.
`artifact://202` passed after safety, naming, and ring-constant placement changes.
The historical `artifact://211` aggregate passed 69/69 steps with 250 root tests per mode.
The pre-feature aggregate, `artifact://275`, passed 69/69 build steps.
The root suite passed 251 tests in Debug and 251 in actual ReleaseSafe.
The two added native-texture boundary regressions protect existing guards.
They do not establish a new panic fix.
The added render-bundle regression reproduced a real allocation-failure callback bug.
In `artifact://273`, 250 root tests passed and one aborted.
A custom allocator callback destroyed the encoder before allocation returned `OutOfMemory`.
The failure recorder then accessed a null context.
The fix preserves `OutOfMemory` and records failure only while the context remains live.
The private validation helper returns the borrowed context.
The fix adds no allocation or public API and does not prove general successful-operation reentrancy.
All 30 command-tag fixtures retain presence checks and direct expected-value comparisons.
Dispatch passed four tests in each mode. Separate acceptance shards run in Debug.
Recorded shards include Dawn pin 3, dispatch drift 1, memory 27, formats 8,
command replay 20, triangle 2, query-set 16, and shared-memory 3.
The query count includes the imported triangle tests.
The final private test-helper checks subsequently passed all 20 replay tests.
The pre-feature source-style closure used exactly 139 explicit file arguments.
Formatting, `ziglint`, and `zlint --deny-warnings` completed with exit code zero.
`ziglint` reported zero diagnostics. `zlint` reported zero errors and zero warnings
across 139 files in 85 ms.
This result follows the final alias and encoder-constructor declaration changes.
The pre-feature default analyzer run completed but was not clean.
The historical legacy gate passed. That supplemented ten-stage snapshot was not green.
The recorded `zbc` run analyzed 95 files and aborted on cleanup-depth handling
for 44 files. It reported 53 findings.
The user stopped further `zbc` source work and requested issue reports only.
All 13 observed diagnostic groups were reported externally.
The incomplete-depth evidence is tracked in [zbc #95](https://github.com/CoffeeImpliesCode/zbc/issues/95).
Integration-family reports include [#96](https://github.com/CoffeeImpliesCode/zbc/issues/96)
through [#101](https://github.com/CoffeeImpliesCode/zbc/issues/101).
Repairs remain unverified. No fresh reproduction after the source freeze is claimed.
The aborted run is not clean evidence, even when the legacy gate treats `zbc` as advisory.
`zbc` is now report-only under the user boundary.
The installed legacy gate ran once:
`devenv shell -- zig-gate --no-zbc`.
It completed with exit code 0 in 211.13 seconds and printed `GATE PASSED`.
Its five printed stages passed: formatting, build, tests, ast-check, and `zlint`.
The build and aggregate tests passed again after the last constructor-alias change.
`--no-zbc` explicitly skipped `zbc` under the user's report-only boundary.
It did not check `zbc` in advisory mode.
The script's `ziglint` block remains commented out.
It has no `zwanzig` or cross-test stage. Coverage remained off.
Supplemental `ziglint`, cross-tests, and zero-layer checks supply their separate evidence.
The pre-feature full default `zwanzig` result reported 107 warnings.
Thus the historical legacy pass did not establish a green ten-stage contract.

The historical `zwanzig` tool verification passed 976 tests: 924 unit tests and 52 fixtures.
Its six test steps and four ReleaseFast installation steps passed.
The actual default run (`artifact://303`) analyzed exactly 139 files with all 21
rules and 4,981 engine runs.
It reported 107 warnings, all `optional-unwrap`, with zero store errors and zero
findings in every other class.
No path exclusions, rule exclusions, or larger analysis budgets produced that result.
The 107 warnings are a subset of the previously triaged 145 optional warnings.
Exact diagnostic comparison found no new findings and removed 38 optional findings
plus two style findings.
The remaining findings are documented model limits, not a clean analyzer result.

The CLI control run retained exactly six expected diagnostics: resource leak,
double free, directory leak, double close, nullable argument, and trapping assertion.
The safe-directory and safe-guard controls produced zero diagnostics.
The unsafe-control command returned exit code 1 as expected.
The earlier store-only run reported zero findings across 139 files.
A store-only result does not replace full-rule evidence.
Earlier default snapshots reported 92 warnings (`artifact://186`) and 145 optional
warnings plus two aliases (`artifact://261`). All these counts are historical, not current feature counts.
The historical directory-argument `zlint` attempt selected only two files.
The corrected command passed exactly 139 explicit file paths to
`devenv shell -- zlint --deny-warnings`.
The validated, untruncated selection used the same hand-written source inventory.
It reported zero errors and zero warnings.

The triangle and query shards encode through the frontend and finish a `Finished` stream.
The engine replays that stream into Vulkan before submission.
Triangle readback checks pixels, blending, and untouched row padding.
Query readback checks real covering/clipped sample counts of 4/0 and unavailable-slot zero fill.
Shared memory proves GPU memory import.
The runtime only proves typed unsupported-capability rejection for semaphore FD services.
It does not prove successful native semaphore FD import.

The current runtime uses lavapipe device Vulkan 1.4.354 and loader Vulkan 1.4.357.
Admission requires Vulkan 1.1. The instance requests `min(loader, 1.3)`.
The native shader path uses the device's effective API version.
`docs/20-dependencies.md` records the loader `LD_LIBRARY_PATH` fix.
The pre-feature selected cross-test matrix and explicit zero-layer GPU checks passed.
The historical full default analyzer result was not clean.
The historical legacy gate passed with `zbc` explicitly skipped.
The stage-8 red run below also predates native stage constants.

The explicit zero-layer command ran inside `devenv`:

```sh
env VK_INSTANCE_LAYERS= VK_LOADER_LAYERS_DISABLE='*' VK_LOADER_DEBUG=layer \
  zig build test-triangle test-query-set test-buffer -j2 --summary all
```

The pre-feature zero-layer run, `artifact://278`, passed 10/10 build steps:
triangle 2, query-set 16, and buffer 4 tests.
Loader logs showed actual call chains without an inserted validation layer.
This proves zero-layer execution for those shards, not every GPU test.

Issue #1 now names M18 as verified. The issues remain open because the fixes
are local, not published. Published bootstrap history through `4645d5d0` remains unchanged.
The [issue #1 verification comment](https://github.com/CoffeeImpliesCode/dusk/issues/1#issuecomment-6043738680)
records the local outcomes without closing the issue or claiming a published fix.
Future phases use one green-phase commit, without history rewrites or force-pushes.
The accepted work does not authorize a commit or push.
See the [issue #6 policy decision](https://github.com/CoffeeImpliesCode/dusk/issues/6#issuecomment-6042784874).

Use named build steps to select acceptance shards:

```sh
zig build test-memory
zig build test-formats
zig build test-triangle
zig build test-query-set
zig build test-dawn-pin
```

`zig build test` runs the aggregate suite.
The former `b.args` forwarding did not filter tests by arguments after `--`.
A command such as `zig build test -- test-memory` is not shard selection.

### Recreating source references

`tools/dawn_pin.zon` records the repository, exact revision, and sparse paths.
Use the explicit network step:

```sh
zig build fetch-dawn
zig build fetch-dawn -Ddawn-dir=/absolute/path/to/research/dawn
```

The destination order is `-Ddawn-dir`, `DUSK_DAWN_SRC`,
`buildhost_SCRATCH_ROOT/research/dawn`, then
`$HOME/.cache/dusk-research/research/dawn`.
The fetch validates the exact revision and the `src`/`include` sparse set.
It refuses dirty checkouts without discarding local files.
This source-only step does not build or depend on Dawn C++ or Tint.
Ordinary builds do not depend on it.

The prerequisite checks recorded three passing source-tool tests, an exact
checkout HEAD and sparse set, and a clean idempotent fetch.
The dirty-checkout check returned `DirtyCheckout` and preserved the untracked
file and HEAD. The default build and development-shell evaluation also passed.
These checks do not replace the full gate or verify the analyzer repair.
The machine measurements, dates, and scratch paths below remain historical
evidence. They are not claims about the present workstation or required paths.

## Grades

Every claim in this document carries a grade.

| Grade | Meaning |
| --- | --- |
| A | Measured on this host. The command and its output are quoted. |
| B | Read from the pinned Dawn tree or the Vulkan registry, with `path:line`. |
| C | Decided here, with no measurement behind it. |

---

## 1. The host is headless

### 1.1 What was measured

Grade A. There is no display server.

```
$ echo "DISPLAY=[${DISPLAY-unset}] WAYLAND_DISPLAY=[${WAYLAND_DISPLAY-unset}]"
DISPLAY=[unset] WAYLAND_DISPLAY=[unset]
```

```
$ vulkaninfo --summary                      # inside devenv
'DISPLAY' environment variable not set... skipping surface info
```

The instance extension list outside devenv, on the four RTX A6000 devices,
holds 24 entries. Seven of them:

```
Vulkan Instance Version: 1.4.309
Instance Extensions: count = 24
VK_EXT_acquire_drm_display             : extension revision 1
VK_EXT_swapchain_colorspace           : extension revision 5
VK_KHR_display                         : extension revision 23
VK_KHR_surface                         : extension revision 25
VK_KHR_wayland_surface                 : extension revision 6
VK_KHR_xcb_surface                     : extension revision 6
VK_KHR_xlib_surface                    : extension revision 6
```

`VK_EXT_headless_surface` is not among the 24. `VK_KHR_display` is.

The instance extension list inside devenv, on lavapipe, holds 19 entries. Seven
of them:

```
Vulkan Instance Version: 1.4.357
Instance Extensions: count = 19
VK_EXT_debug_utils                    : extension revision 2
VK_EXT_headless_surface                : extension revision 1
VK_EXT_swapchain_colorspace           : extension revision 5
VK_KHR_surface                         : extension revision 25
VK_KHR_wayland_surface                 : extension revision 6
VK_KHR_xcb_surface                     : extension revision 6
VK_KHR_xlib_surface                    : extension revision 6
```

`VK_EXT_headless_surface` is present here. `VK_KHR_display` is not. The full
`vulkaninfo` output inside devenv holds zero lines matching `VK_KHR_display`:

```
$ vulkaninfo 2>/dev/null | grep -c "VK_KHR_display"
0
```

**This corrects the premise this document was written against.** The extension
is absent from the host list and present inside devenv. Neither list carries
both extensions, so no configuration on this machine can name a display for a
headless surface.

`AGENTS.md:174-176` states the corrected form: `VK_EXT_headless_surface` is
present inside devenv on lavapipe and absent outside it on NVIDIA, and
`VK_KHR_display` is the other way round. The rule it draws from that, at
`AGENTS.md:177-179`, is unchanged by the correction.

`UNKNOWN:` whether lavapipe accepts `vkCreateHeadlessSurfaceEXT` when
`VK_KHR_display` is absent. Settled by a small program that fills a
`VkHeadlessSurfaceCreateInfoEXT` with `.flags = 0` and
`.pNext = null`, calls `vkCreateHeadlessSurfaceEXT`, and prints the result
code. The outcome changes no decision in this document.

### 1.2 The decision

**Decision: a test observes a rendered result only by copying it out of an
image.**

- Priority: a test must observe a real rendered result, not a proxy for one.
- Constraint: no `DISPLAY`, no `WAYLAND_DISPLAY`, and no display in either
  extension list. A present path needs a display engine, and none exists.
- Cost imposed on consumers: `platform` ships no tested surface creation. A
  consumer that needs a window writes its own. The swapchain path, if it ever
  lands, has no test on this host.
- Counterchoice: `VK_EXT_headless_surface`. It genuinely wins on a machine that
  advertises both it and `VK_KHR_display` with a connected panel, because a
  present path exercises acquire and present, which a copy never touches. On
  this host neither configuration has both extensions.
- Grade: A for the measurements, C for the decision.

### 1.3 What the constraint permits

A test may create a `VkInstance`, an `XlibSurface`, and a `WaylandSurface`. The
window-system extensions are advertised on both drivers. A test may not create a
`VkSwapchainKHR`, because a swapchain needs a surface backed by a reachable
native window, and no such window exists. `AGENTS.md:177-179` states the same
rule for tests.

---

## 2. The offscreen render pipeline

### 2.1 The sequence at the WebGPU level

This is what a test writes. `command` records it and `engine` replays it into
`vk`, which is the split `docs/10-architecture.md:67-69` requires.

1. Create a texture with `usage = .render_attachment | .copy_src`,
   `format = .r8g8b8a8_unorm`, `size = { width_px, height_px, 1 }`, and a mip
   level count of 1.
2. Create a buffer with `usage = .copy_dst | .map_read` and
   `size = staging_byte_count` from §2.4.
3. `beginRenderPass` with one colour attachment whose `loadOp` is `.clear`,
   whose `clearValue` carries the expected bytes, and whose `storeOp` is
   `.store`.
4. `end`, then `copyTextureToBuffer` from that texture into that buffer.
5. `submit`.
6. `mapAsync(.read)`, wait, read the bytes, `unmap`.

### 2.2 The sequence at the Vulkan level

This is what `engine` and `vk` produce from those six steps.

1. `vkCreateImage` with `imageType = .e2d`,
   `format = VK_FORMAT_R8G8B8A8_UNORM`, `mipLevels = 1`, `arrayLayers = 1`,
   `samples = VK_SAMPLE_COUNT_1_BIT`, `tiling = VK_IMAGE_TILING_OPTIMAL`,
   `usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT`,
   `initialLayout = VK_IMAGE_LAYOUT_UNDEFINED`, `sharingMode = VK_SHARING_MODE_EXCLUSIVE`.
2. `vkCreateImageMemory`, `vkBindImageMemory`, `vkCreateImageView` with
   `viewType = VK_IMAGE_VIEW_TYPE_2D`, `subresourceRange` covering one layer and
   one mip level.
3. A `VkFramebuffer` with one `VkFramebufferAttachment`.
4. `vkCmdBeginRenderPass`. Its `renderArea` is
   `{{0, 0}, { width_px, height_px }}`, and its clear colour is a
   `VkClearColorValue` of the form `.{ .uint32 = { r, g, b, a } }`. Its single
   `VkAttachmentDescription` reads:

   | Field | Value |
   | --- | --- |
   | `format` | `VK_FORMAT_R8G8B8A8_UNORM` |
   | `samples` | `VK_SAMPLE_COUNT_1_BIT` |
   | `loadOp` | `VK_ATTACHMENT_LOAD_OP_CLEAR` |
   | `storeOp` | `VK_ATTACHMENT_STORE_OP_STORE` |
   | `stencilLoadOp` | `VK_ATTACHMENT_LOAD_OP_DONT_CARE` |
   | `stencilStoreOp` | `VK_ATTACHMENT_STORE_OP_DONT_CARE` |
   | `initialLayout` | `VK_IMAGE_LAYOUT_UNDEFINED` |
   | `finalLayout` | `VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL` |

   The image leaves the pass already in `TRANSFER_SRC_OPTIMAL`, so the copy
   needs no second barrier. A test that renders then copies therefore proves
   one layout transition, not two.
5. `vkCmdEndRenderPass`, then `vkCmdCopyImageToBuffer` with
   `srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL`.
6. `vkQueueSubmit` with one `VkSubmitInfo` whose `commandBufferCount` is 1,
   and a fence. The test waits on that fence with `vkWaitForFences`.
7. `vkMapMemory` at offset 0, read, `vkUnmapMemory`.

The staging buffer is a `VkBuffer` whose `usage` is
`VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_MAPPING_READ_BIT`, bound to
a memory type whose `memoryPropertyFlags` carry
`VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT`.
`HOST_COHERENT` means the test does not call `vkFlushMappedMemoryRanges` or
`vkInvalidateMappedMemoryRanges` after the map.

`docs/10-architecture.md:48` puts VMA under the device-memory layer. The
host-visible staging allocation is the one allocation a test asks VMA for by
hand, because the WebGPU surface has no concept of a host-visible heap.

### 2.3 The copy struct

The header is authoritative. `/usr/include/vulkan/vulkan_core.h:4083-4090`,
grade A for the file, grade B for the rule:

```c
typedef struct VkBufferImageCopy {
    VkDeviceSize                bufferOffset;
    uint32_t                    bufferRowLength;
    uint32_t                    bufferImageHeight;
    VkImageSubresourceLayers    imageSubresource;
    VkOffset3D                  imageOffset;
    VkExtent3D                  imageExtent;
} VkBufferImageCopy;
```

`src/vulkan.zig` is generated by `zig translate-c`
(`docs/10-architecture.md:13`, `docs/20-dependencies.md:52-55`). The generator
keeps the C spelling for these fields: `src/vulkan.zig:4531-4538` reads
`bufferOffset`, `bufferRowLength`, `bufferImageHeight`, `imageSubresource`,
`imageOffset` and `imageExtent`. The C names above are the contract, and they
are also the Zig names.

The mapping from the WebGPU copy fields:

| WebGPU field | `VkBufferImageCopy` field | Value in a test |
| --- | --- | --- |
| `buffer` | not a field | resolved to a `VkBuffer` by `engine` |
| `offset` | `bufferOffset` | `0` |
| `bytesPerRow` | `bufferRowLength` | `bytes_per_row / texel_block_size_byte_count` |
| `rowsPerImage` | `bufferImageHeight` | `height_texel_count`, or `0` for a single layer |
| `texture` | `imageSubresource` | `aspectMask = VK_IMAGE_ASPECT_COLOR_BIT`, `mipLevel = 0`, `baseArrayLayer = 0`, `layerCount = 1` |
| copy origin | `imageOffset` | `{ .x = 0, .y = 0, .z = 0 }` |
| `copySize` | `imageExtent` | `{ .width = width_texel_count, .height = height_texel_count, .depth = 1 }` |

`bufferRowLength` counts texels and `bytesPerRow` counts bytes. For
`R8G8B8A8_UNORM` the two are the same number. For a compressed format they are
not, and the division is required. Dawn makes the same conversion and says so
in a comment at `src/dawn/native/vulkan/UtilsVulkan.cpp:247-251`. Its block
overload converts blocks to texels at `UtilsVulkan.cpp:233`.

### 2.4 The alignment rule

Vulkan, grade B:

- `bufferRowLength` must be `0` or at least `imageExtent.width`.
  `/usr/share/vulkan/registry/validusage.json:39484-39486`,
  `VUID-VkBufferImageCopy-bufferRowLength-09101`.
- `bufferImageHeight` must be `0` or at least `imageExtent.height`.
  `validusage.json:39489-39490`,
  `VUID-VkBufferImageCopy-bufferImageHeight-09102`.
- `imageSubresource.aspectMask` must have one bit set.
  `validusage.json:39494-39495`,
  `VUID-VkBufferImageCopy-aspectMask-09103`.
- `imageExtent` must be non-zero in all three components.
  `validusage.json:39499-39511`.
- `bufferOffset` must be a multiple of `4` when the queue family supports
  neither graphics nor compute.
  `validusage.json:38936-38937`,
  `VUID-vkCmdCopyBufferToImage-commandBuffer-07737`.

Measured on lavapipe, grade A:

```
	optimalBufferCopyOffsetAlignment                = 0x00000080
	minMemoryMapAlignment                           = 64
	maxImageDimension2D                             = 16384
```

`0x00000080` is 128. The port uses `optimalBufferCopyOffsetAlignment` when the
device reports it non-zero, and `4` otherwise.

WebGPU is stricter than Vulkan here, and the port inherits that, grade B. Dawn
defines the constant at `src/dawn/common/Constants.h:44` and rejects a
misaligned stride at `src/dawn/native/CommandValidation.cpp:426-435`:

```cpp
    auto alignment = kTextureBytesPerRowAlignment;
    ...
        DAWN_INVALID_IF(texelCopyBufferInfo.layout.bytesPerRow % alignment != 0,
                        "bytesPerRow (%u) is not a multiple of %u.",
```

The port therefore computes:

```zig
texel_block_size_byte_count = 4;                      // R8G8B8A8_UNORM, 1 texel per pixel
bytes_per_row = alignForwardBytes(
    texel_block_size_byte_count * width_texel_count,
    256,
);
staging_byte_count = bytes_per_row * (height_texel_count - 1)
    + texel_block_size_byte_count * width_texel_count;
```

`alignForwardBytes` names its rounding rule in its own name, as
`AGENTS.md:58-59` requires. The result is a multiple of 128, so the Vulkan
offset rule holds for any buffer offset the port accepts, and a multiple of 256,
so the WebGPU stride rule holds by construction.

The staging size is the last row's true length, not the padded length. Padding
the final row as well is allowed and wastes at most 252 bytes, but the smaller
value keeps the test arithmetic checkable by hand.

### 2.5 The pixel format

`VK_FORMAT_R8G8B8A8_UNORM` is the default target. The Vulkan specification
makes it a mandatory format with `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT`,
`VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT`, `VK_FORMAT_FEATURE_TRANSFER_SRC_BIT` and
`VK_FORMAT_FEATURE_TRANSFER_DST_BIT`, so every conformant implementation
accepts it. Grade C, from the specification, because the bit values were not
read on this host.

A test still asserts the bits through `vkGetPhysicalDeviceFormatProperties`
rather than assuming them. A driver that disagrees is a defect the test should
report, not a condition it should tolerate.

Two other formats have their own jobs:

| Format | Used for | The test must first check |
| --- | --- | --- |
| `VK_FORMAT_R8G8B8A8_UNORM` | clear-only tests, exact byte comparison | mandatory, no check needed |
| `VK_FORMAT_R16G16B16A16_SFLOAT` | shader arithmetic, no format quantisation | `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT` |
| `VK_FORMAT_R4G4B4A4_UNORM` | the quantisation case in §3.3 | `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT` |

`VK_FORMAT_R4G4B4A4_UNORM` is not a mandatory format. A test that uses it skips
itself when the query reports the bit missing. That skip is the first real use
of the predicate in §9.3.

`UNKNOWN:` the `linearTilingFeatures` bits lavapipe reports for
`VK_FORMAT_R16G16B16A16_SFLOAT` and `VK_FORMAT_R4G4B4A4_UNORM`. The full
`vulkaninfo` output inside devenv is 1575 lines, ends in the device-features
section, and holds no `R8G8B8A8_UNORM` line, so this `vulkaninfo` does not
report per-format properties. Settled by the format-property query the test
performs anyway.

---

## 3. Turning pixels into an assertion

### 3.1 The readback helper

One helper owns the whole path, so no test repeats the alignment arithmetic:

```zig
// test/support/Readback.zig
pub const ReadbackOptions = struct {
    allocator: std.mem.Allocator,
    device: *core.Device,
    texture: api.Texture,
    origin_px: api.Origin2D,
    extent_px: api.Extent2D,
    format: api.TextureFormat,
};

pub fn readTextureToHostBytes(options: ReadbackOptions) ![]align(4) u8;
pub fn freeHostBytes(allocator: std.mem.Allocator, bytes: []align(4) u8) void;
```

The house form for six named inputs is an options struct. `AGENTS.md:56-57`
requires one as soon as two parameters share a type.

Two rules the helper enforces:

1. It never returns padding. It copies `texel_block_size_byte_count *
   width_texel_count` bytes out of each row and advances by `bytes_per_row`.
   Vulkan leaves the bytes between the end of one row and the start of the next
   undefined, so a test that reads them is nondeterministic.
2. It fails when `vkGetPhysicalDeviceFormatProperties` reports no
   `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT`, and it fails when device
   enumeration returned zero devices. See §5.3.

### 3.2 Exact equality

An exact comparison is right when the target carries no arithmetic. A
clear-only pass writes a byte quad that the driver copies without arithmetic,
so every bit is the caller's.

```zig
pub fn expectPixelsExact(options: PixelAssertOptions) !void;
```

`PixelAssertOptions` carries the same readback fields plus `expected: []const
u8`, one `u32` little-endian quad per pixel, and it compares with
`std.testing.expectEqualSlices(u8, ...)`.

A clear-only test proves: the clear value reached the attachment, the load and
store ops are the ones the pass asked for, the attachment format is the one the
test named, the copy read the right subresource, the extent is right, and no
missing barrier left the previous contents in place.

### 3.3 Approximate equality

An exact comparison is usually wrong for a floating-point target. A fragment
shader computes in `f32`, and the Vulkan specification grants no bit-exactness
across implementations. That is grade C, read from the specification rather
than measured. A driver may fuse a multiply and an add, reorder an expression,
or keep a different intermediate precision. llvmpipe and the NVIDIA driver are
two implementations, and a green suite must not depend on them agreeing bit for
bit.

```zig
pub fn expectPixelsAbsolute(options: PixelAssertOptions) !void;
```

The comparison is `@abs(actual - expected) <= tolerance` per channel, with the
expected values decoded into `[0, 1]`.

The tolerance follows the quantum of the target, not a habit:

| Target | Compare in | Tolerance | Reason |
| --- | --- | --- | --- |
| `R8G8B8A8_UNORM`, shader output | normalized `f32` | `1.0 / 255.0` | one code value of the format |
| `R16G16B16A16_SFLOAT`, shader output | `f32` | `1.0 / 512.0` | half a binary16 ULP at 1.0, which is `2^-11` |
| `R4G4B4A4_UNORM`, pass-through shader | code units | `0` | every expected value is exactly `k / 15` |
| `R4G4B4A4_UNORM`, shader with arithmetic | code units | `1` | one code value, which is `1 / 15` |

For a 4-bit unorm target the right tolerance is `0` when the shader writes
exactly representable values and the arithmetic is a copy. It is `1` code value
when a multiply or a divide sits in between, because a single rounding step can
cross a quantisation boundary. Compare in code units rather than in
normalized floats, so a failure reads "off by one code" instead of "off by
0.0667" and a rounding accident cannot satisfy the assertion.

Dawn draws the same line. `ExpectEq` takes a tolerance that defaults to zero
(`src/dawn/tests/DawnTest.h:1042`), `CheckImpl` for `float` compares
`abs(expected - actual) > tolerance` (`DawnTest.cpp:2552-2559`), the
`uint16_t` overload compares in integer code units (`DawnTest.cpp:2562-2571`),
and the macros `EXPECT_PIXEL_RGBA8_EQ` and
`EXPECT_PIXEL_FLOAT_TOLERANCE_EQ` select between them
(`DawnTest.h:125` and `DawnTest.h:134`).

### 3.4 Which catches which

| Defect | Exact on a clear | Absolute on a shader |
| --- | --- | --- |
| Wrong clear colour | catches | catches |
| Wrong `loadOp` or `storeOp` | catches | catches |
| Wrong attachment format | catches | catches |
| Wrong copy extent | catches | catches |
| Row pitch off by one byte | catches | catches |
| Missing layout transition before the copy | catches | catches |
| Wrong pipeline state | no coverage | catches |
| Wrong bind group or descriptor | no coverage | catches |
| Wrong vertex layout or interpolation | no coverage | catches |
| Driver rounding regression | no coverage | catches |

The exact comparison proves nothing about shader behaviour, because a
clear-only pass runs no shader. The approximate comparison cannot distinguish a
one-code difference from a real regression, so it never replaces the exact one.

### 3.5 The layer's contribution

A synchronisation defect, such as a barrier with the wrong stage mask, may not
change a single pixel on lavapipe, which executes serially. It is caught by the
layer, not by the readback. That is why the layer matrix in §4 and the readback
matrix here are both required. `devenv.nix:122-125` names the same two defects.

---

## 4. The layer matrix

### 4.1 What the shell sets

Grade A. `devenv.nix:114-137` sets, and the shell exports:

```
VK_LAYER_PATH=/nix/store/2p3ff6vbl8i2gyf2zvickc48k7hm9x0k-vulkan-validation-layers-1.4.357.0/share/vulkan/explicit_layer.d
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
VK_LAYER_VALIDATE_SYNC=1
VK_LAYER_LOG_PATH=stderr
VK_LAYER_LOG_LEVEL=info
```

Inside devenv the layer resolves and announces itself:

```
Instance Layers: count = 1
VK_LAYER_KHRONOS_validation Khronos Validation Layer 1.4.357  version 1
```

Outside devenv the same variables are exported and the layer does not load:

```
ERROR: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" was not found but was requested by env var VK_INSTANCE_LAYERS!
```

The cause is `VK_LAYER_PATH`, not a missing layer. It names a store path that
does not exist on this host:

```
$ ls -d /nix/store/2p3ff6vbl8i2gyf2zvickc48k7hm9x0k-vulkan-validation-layers-1.4.357.0
ls: cannot access '/nix/store/2p3ff6vbl8i2gyf2zvickc48k7hm9x0k-vulkan-validation-layers-1.4.357.0': No such file or directory
```

The host does carry a copy of the layer, at
`/usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json`, and it
loads when `VK_LAYER_PATH` is cleared. Grade A:

```
$ env -u VK_LAYER_PATH vulkaninfo --summary 2>/dev/null | sed -n '/^Instance Layers/,/^$/p'
Instance Layers: count = 3
VK_LAYER_KHRONOS_validation Khronos Validation Layer  1.4.309  version 1
VK_LAYER_NV_optimus         NVIDIA Optimus layer      1.4.351  version 1
VK_LAYER_NV_present         NVIDIA Presentation Layer 1.4.351  version 1
```

So the layer version a run reports is the one the search path names: 1.4.357
inside devenv, 1.4.309 outside it. Every layer-dependent result is an
inside-devenv result.

The layer writes to stderr, not to a file. Grade A, measured inside devenv:

```
$ vulkaninfo --summary 2>/dev/null | grep -c -E "^(WARNING|ERROR)"
0
$ vulkaninfo --summary 2>&1 >/dev/null | grep -c -E "^(WARNING|ERROR)"
2
```

### 4.2 The three configurations

A suite must cover three.

| Mode | Purpose | Environment |
| --- | --- | --- |
| `none` | prove the library runs with no layer | Remove `VK_INSTANCE_LAYERS`, `VK_LOADER_LAYERS_ENABLE`, and `VK_LOADER_LAYERS_ALLOW`. Set `VK_LOADER_LAYERS_DISABLE=~all~` for this process. |
| `validation` | prove the layer reports nothing | `VK_INSTANCE_LAYERS` removed, `VK_LOADER_LAYERS_ENABLE=VK_LAYER_KHRONOS_validation` |
| `validation_sync` | prove the barrier and queue hazards are absent | as above, plus the inherited `VK_LAYER_VALIDATE_SYNC=1` |

The process-scoped zero-layer recipe is:

```sh
env -u VK_INSTANCE_LAYERS -u VK_LOADER_LAYERS_ENABLE -u VK_LOADER_LAYERS_ALLOW \
  VK_LOADER_LAYERS_DISABLE=~all~ VK_LOADER_DEBUG=layer \
  zig build test-native-utilities-debug -j2
```

Keep the default validation configuration for permanent tests.
The [official loader filtering rules](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderLayerInterface.md#layer-filtering)
state that forced enable and allow variables can override disable filters.
An empty application `enabledLayerCount` alone does not prove zero layers.
Inspect the actual loader call chain before a zero-layer execution claim.
The historical output below only records that invocation's observed forced-disable warning:

```
$ VK_LOADER_LAYERS_DISABLE='*' vulkaninfo --summary 2>&1 | sed -n '/^Instance Layers/,/^$/p'
Instance Layers:
----------------
WARNING: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" forced disabled because name matches filter of env var 'VK_LOADER_LAYERS_DISABLE'.
```

Each enabled mode clears `VK_INSTANCE_LAYERS` and selects the layer through
`VK_LOADER_LAYERS_ENABLE` instead. Grade A:

```
$ env -u VK_INSTANCE_LAYERS VK_LOADER_LAYERS_ENABLE=VK_LAYER_KHRONOS_validation \
      vulkaninfo --summary 2>/dev/null | sed -n '/^Instance Layers/,/^$/p'
Instance Layers: count = 1
--------------------------
VK_LAYER_KHRONOS_validation Khronos Validation Layer 1.4.357  version 1
```

The loader confirms the selection on stderr:

```
WARNING: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" forced enabled due to env var 'VK_LOADER_LAYERS_ENABLE'
```

Clearing `VK_INSTANCE_LAYERS` is deliberate. It makes the selection explicit
in the child's environment instead of inherited from the shell, so a mode never
depends on what the shell happens to export.

The third mode inherits `VK_LAYER_VALIDATE_SYNC=1` from the shell as it stands.
§4.6 gives why that needs no adjustment per process.

### 4.3 How a suite selects the mode

A test binary spawns itself once per mode and reads the mode from
`DUSK_TEST_LAYER_MODE`. The parent owns no device and asserts only on the exit
code.

```zig
// test/support/LayerMatrix.zig
pub const LayerMode = enum { none, validation, validation_sync };

pub fn runLayerMatrix(self: *Self, run_child: *const fn (LayerMode) !void) !void;
```

`std.process.Child.env_map` replaces the child's whole environment, so the
parent builds it from `std.process.getEnvMap` and then applies the mode: it sets
the mode's keys and omits the keys the mode must not have. That keeps
`VK_DRIVER_FILES` from §5.1 and `VK_LAYER_PATH` from §4.1.

The child runs with `stdio = .{ .stdout = .inherit, .stderr = .pipe }`.
Nothing in the parent mutates the shell environment. `devenv.nix:116-119`
requires exactly this: the zero-layer path sets its variable per process rather
than in the shared shell.

This is the layer-matrix contract, not evidence that the current aggregate runs
all three modes. The explicit zero-layer run above verifies three selected GPU shards.

### 4.4 How a suite asserts the layer reported nothing

Two mechanisms. The first is primary because it needs nothing from the library.

**Primary: read the child's stderr.** The parent scans the captured byte stream
and fails when a line begins with `ERROR: [` or contains `Validation Error`. The
filter must not match `WARNING`, because the loader writes benign lines of its
own, measured above:

```
WARNING: [Loader Message] Code 0 : env var 'VK_INSTANCE_LAYERS' defined and adding layers "VK_LAYER_KHRONOS_validation"
```

**Secondary: a debug-utils messenger.** `VK_EXT_debug_utils` is advertised by
both drivers, measured in the two lists in §1.1. The test creates a
`VkDebugUtilsMessengerEXT` through `vkCreateDebugUtilsMessengerEXT`, collects
`VkDebugUtilsMessengerCallbackDataEXT` into a slice, and asserts the count is
zero. This mechanism survives a change to `VK_LAYER_LOG_PATH`, and it reports a
severity and a message id rather than a line of text.

The messenger needs the raw `VkInstance`. The native-handle accessor that
`docs/30-port-design.md` owns provides it. The test uses that accessor and the
library never reads it itself.

### 4.5 The rules

1. **The library must run correctly with zero layers.** A change that works
   only with the layer enabled is broken (`AGENTS.md:112-113`).
2. **The layer is never a runtime dependency.** `build.zig.zon` holds no entry
   for it, `.paths` names no layer file, and `platform` never opens
   `VK_LAYER_KHRONOS_validation` through `vkEnumerateInstanceLayerProperties`.
3. **A mode that reports a validation error fails the suite.** The layer does
   not decide pass or fail. `abort_on_error` stays off for the reason
   `devenv.nix:133-135` gives: a layer that aborts takes the whole shard with it.
4. **Every layer result names its mode.** A failure reported as "validation
   failed" without the mode is not evidence.

### 4.6 The modern spelling, and why the old one is absent

`devenv.nix:130` sets `VK_LAYER_VALIDATE_SYNC=1`, not `VK_LAYER_ENABLES`.
`devenv.nix:122-129` records why, and the reason is measured: the loader prints
this when both spellings are present.

```
WARNING: [Validation] Code 0 : vkCreateInstance(): Application is using deprecated "enables" (VK_LAYER_ENABLES) layer settings.
Deprecated settings and new settings cannot be mixed, and deprecated ones take precedence. Consider only using the new settings:
  Deprecated: VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT | New: "validate_sync" (VK_LAYER_VALIDATE_SYNC=1)
```

A child process inherits the shell's `VK_LAYER_VALIDATE_SYNC` and never reads it
if it also carries `VK_LAYER_ENABLES`, because the deprecated setting wins. So
the third mode in §4.2 has nothing to remove, and the shell needs no change.

---

## 5. The driver matrix

### 5.1 Inside devenv: lavapipe

Grade A. One device, and it is a CPU.

```
$ env | grep '^VK_DRIVER_FILES='
VK_DRIVER_FILES=/nix/store/0f4ri4jl678q74i5z0h9f4pg2sj59slp-mesa-26.2.2/share/vulkan/icd.d/lvp_icd.x86_64.json
$ vulkaninfo --summary 2>/dev/null | sed -n '/^Devices:/,$p'
GPU0:
	apiVersion         = 1.4.354
	deviceType         = PHYSICAL_DEVICE_TYPE_CPU
	deviceName         = llvmpipe (LLVM 21.1.8, 256 bits)
	driverName         = llvmpipe
	conformanceVersion = 1.3.1.1
```

The list holds one entry, `GPU0`.

`devenv.nix:155-173` explains why. The devenv container's `/usr` is not the
host's `/usr`, so `/usr/share/vulkan/icd.d` does not exist inside it and the
NVIDIA ICD is unreachable. The shell sets `VK_DRIVER_FILES` to the single
lavapipe ICD.

### 5.2 Outside devenv: four NVIDIA RTX A6000

Grade A. Four discrete devices.

```
$ vulkaninfo --summary 2>/dev/null | grep -E '^(GPU|	(apiVersion|deviceType|deviceName|driverName))'
GPU0:
	apiVersion         = 1.4.351
	deviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
	deviceName         = NVIDIA RTX A6000
	driverName         = NVIDIA
```

`GPU1`, `GPU2` and `GPU3` repeat those four fields with the same values. The
full summary also reports `driverVersion = 615.71.9.0`, `vendorID = 0x10de`,
`deviceID = 0x2230`, `driverID = DRIVER_ID_NVIDIA_PROPRIETARY`, and
`conformanceVersion = 1.4.3.3`. The loader reads
`/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json`, whose `library_path` is
`/usr/lib64/libGLX_nvidia.so.0`.

`DUSK_VK_DRIVER_FILES` overrides the list. `devenv.nix:175-196` builds
`VK_DRIVER_FILES` from it when it is non-empty, and otherwise from the single
lavapipe path. Outside devenv, pointing `VK_DRIVER_FILES` at `/nonexistent.json`
shows what a driver failure looks like, and it is what a device enumeration must
not be confused with:

```
ERROR: [Loader Message] Code 0 : loader_get_json: Failed to open JSON file /nonexistent.json
ERROR: [Loader Message] Code 0 : vkCreateInstance: Found no drivers!
Cannot create Vulkan instance.
This problem is often caused by a faulty installation of the Vulkan driver or attempting to use a GPU that does not support Vulkan.
ERROR at .../Vulkan-Tools-1.4.304/vulkaninfo/./vulkaninfo.h:456:vkCreateInstance failed with ERROR_INCOMPATIBLE_DRIVER
```

### 5.3 Zero devices must fail the run

A green run that enumerated nothing has proved nothing. Grade A for the
failure, grade C for the rule.

```zig
test "device enumeration is not empty" {
    const devices = try engine.enumeratePhysicalDevices(instance);
    try std.testing.expect(devices.len > 0);
}
```

The engine returns `error.NoPhysicalDevice` rather than an empty slice, so no
caller can mistake it for a healthy device with nothing to do. The staging and
readback helpers in §3.1 propagate that error rather than returning an empty
result.

### 5.4 What each configuration proves

| | lavapipe inside devenv | NVIDIA outside devenv |
| --- | --- | --- |
| reachable from the gate | yes | no |
| layer active | yes | no, `VK_LAYER_PATH` names a store path absent on this host (§4.1) |
| reproducible on any machine | yes | no |
| real device-local memory | no | yes |
| vendor queue families and limits | no | yes |
| vendor driver defects | no | yes |
| concurrency, because a real driver is not serial | no | yes |

lavapipe proves that the port issues a call sequence the specification permits,
and it proves it reproducibly. The NVIDIA run proves that a vendor driver
accepts the same sequence, and it is the only place a real memory heap, a real
queue family set, and a real driver bug appear. Neither substitutes for the
other: a suite that runs only on lavapipe cannot find a driver bug, and a suite
that runs only on NVIDIA cannot run on a machine without one.

The four identical A6000 devices are the reason per-adapter parameterisation
(§9.2) has an observable axis. Four rows with equal properties today mean that a
divergence tomorrow comes from the device or the driver, not from the test.

---

## 6. Shader fixtures

### 6.1 The layout

```
test/
  fixtures/
    triangle.vert.wgsl           committed
    triangle.vert.spv            committed, generated
    triangle.frag.wgsl           committed
    triangle.frag.spv            committed, generated
    occlusion.vert.wgsl          committed
    occlusion.vert.spv           committed, generated
    occlusion.frag.wgsl          committed
    occlusion.frag.spv           committed, generated
```

`docs/10-architecture.md:27` places `test/` at the top level. The WGSL file is
the source of truth for review, and the `.spv` file is the artefact the test
loads. One flat `fixtures/` directory holds the pairs: the stage already names
itself in the file name, so a subdirectory per shader would repeat it.

`test/spirv/corpus/`, its `MANIFEST.txt` and `test/support/` are not on disk.
§7.1 and §7.2 name what belongs there when it lands.

### 6.2 Regeneration

The regeneration step is a test-time external tool. It is never a build input
and never linked. `docs/20-dependencies.md` records the decision.

**Where the translator comes from.** `pkgs.tint` in nixpkgs is 0.1.7 and ships
no binary, so it cannot be used. The translator is built from the pinned Dawn
checkout, and `devenv.nix` task `dusk:build-tint` does it, caching the result
at `${cacheRoot}/tools/tint` and exporting it as `DUSK_TINT`.

It is built **inside devenv**, and that is not incidental. The devenv container
has no `/lib64` at all — only the nix glibc — so a binary linked against the
host toolchain dies there with `cannot execute: required file not found`. This
was observed, then fixed by building against the nix toolchain inside the
shell. The task disables the six back ends and both window systems, because
otherwise the configure step demands `xkbcommon`, which is absent.

The command line, measured against that binary:

```bash
"$DUSK_TINT" <fixture>.wgsl --format=spirv --ep <name> --ep <name> -o <out>.spv
```

Two flags were measured rather than assumed:

- the output-format flag is **`--format`**, not `--output-format`;
- a module with more than one entry point **refuses to emit** without an
  explicit `--ep` per entry point: `Emitting to a file but the module has
  multiple entry points. Please provide the '--ep <name>' option`.

Observed on `test/fixtures/triangle.vert.wgsl`, inside devenv:

```text
 0000000 03 02 23 07 00 03 01 00
SPIRV_VALID
```

`07230203` is the SPIR-V magic number and `00010300` is SPIR-V 1.3, little
endian. The `SPIRV_VALID` line is `spirv-val` from `spirv-tools`, run
separately.

**The build is byte-deterministic**, which the drift check in §6.3 depends on.
Regenerating one fixture twice and comparing:

```text
c72977d67e8e003d080c3bc0398a546635ff1257cb84ccc62b55797c1344081e  /tmp/tv1.spv
c72977d67e8e003d080c3bc0398a546635ff1257cb84ccc62b55797c1344081e  /tmp/tv2.spv
```

The translator is pinned twice: to the Dawn commit recorded in
`docs/02-dawn-design.md`, and to the host toolchain through the cache path.
Changing either changes the digests, which the drift check turns into a
visible failure rather than a silent one.

### 6.3 The drift check

The fixture contract requires regeneration into a scratch directory and comparison
with committed `.spv` files. The comparison is byte-for-byte, not semantic.
The installed legacy gate has no fixture regeneration stage.

```bash
for wgsl in test/fixtures/*.wgsl; do
  spv="${wgsl%.wgsl}.spv"
  generated="${SCRATCH}/$(basename "${wgsl%.wgsl}").spv"
  # Entry points come from a sidecar next to the fixture; `--ep` is mandatory
  # for a multi-entry-point module and `--format`, not `--output-format`, names
  # the output language.
  dusk-wgsl-to-spv "$wgsl" "$generated" --ep vs_main --ep fs_main
  cmp -s "$generated" "$spv" || {
    printf 'fixture drift: %s\n' "$wgsl" >&2
    exit 1
  }
done
```

Two of the four fixtures drift today, so the step is red on this tree:

```text
SAME test/fixtures/occlusion.frag.spv
SAME test/fixtures/occlusion.vert.spv
DRIFT test/fixtures/triangle.frag.spv
DRIFT test/fixtures/triangle.vert.spv
```

The committed `.spv` files are not regenerated here. A regeneration belongs to
the change that altered the WGSL, and this document is not that change.

The step runs inside devenv, where `DUSK_TINT` is exported, so the binary
matches the glibc the tests run on. `dusk-wgsl-to-spv` is the `devenv.nix` task
of that name; it fails with a clear message when the translator has not been
built.

A drift failure names the WGSL file and does not modify the committed `.spv`. A
developer who changed a shader and forgot to regenerate sees the failure, runs
the regeneration, and commits both files in the same change.

`.paths` in `build.zig.zon:25-34` lists `build.zig`, `build.zig.zon`, `src`,
`docs`, `README.md`, `AGENTS.md`, `test` and `tools`. A consumer who installs
the package by hash therefore receives the fixtures and the generators.

### 6.4 The rule

The library never links the translator. `src/spirv` never parses WGSL, and
`build.zig.zon` holds no entry for `tint` (`AGENTS.md:116-123`). A shader that
reaches `vkCreateShaderModule` reached it as the caller's own words
(`docs/10-architecture.md:133-137`).

---

## 7. SPIR-V validation in tests

### 7.1 `spirv-val` proves a fixture before the engine sees it

`spirv-tools` is a test-time tool. Grade A:

```
$ devenv shell -- command -v spirv-val
/nix/store/v7n98xb3g3xfrlqg4kdpiq47k7jcjg2h-spirv-tools-1.4.357.0/bin/spirv-val
$ spirv-val --version
SPIRV-Tools v2026.3 unknown hash, 1980-01-01T00:00:00+00:00
Targets:
  SPIR-V 1.0 ... SPIR-V 1.6
  SPIR-V 1.0 (under Vulkan 1.0 semantics)
  ...
  SPIR-V 1.6 (under Vulkan 1.4 semantics)
```

The fixture contract requires this supplemental validation before loading fixtures:

```bash
spirv-val --target-env vulkan1.3 test/fixtures/*.spv
```

`docs/20-dependencies.md:97-99` states the rule: `spirv-tools` is in
`devenv.nix`, absent from `build.zig.zon`, and not linked. `devenv.nix:50-51`
puts it in the shell.

The reason is diagnostic. A fixture that `spirv-val` rejects fails with the
tool's own message and the file name, instead of failing later as a
`vkCreateShaderModule` error or a validation error with no source location.

### 7.2 The Zig validator is tested separately

`spirv-val` proves the fixture. It does not prove `src/spirv.validate`. Those
are two different implementations of the same specification, and the second one
is ours.

The corpus in §6.1 tests the Zig validator directly. It has not landed, so the
tests below name the shape rather than the file list:

```zig
test "every valid corpus module passes the Zig validator" {
    for (corpus_paths("valid")) |path| {
        const words = try readSpv(path);
        try spirv.validate(words);
    }
}

test "every invalid corpus module is rejected with its recorded rule" {
    for (corpus_paths("invalid")) |path| {
        const words = try readSpv(path);
        try std.testing.expectError(
            error.InvalidModule,
            spirv.validate(words),
        );
        try expectRecordedRule(path, try lastRuleId());
    }
}
```

`MANIFEST.txt` records the expected outcome and the rule identity for every
corpus file, so a rejection for the wrong reason fails the test. A validator
that rejects everything passes the first test and fails the second.

Dawn does the same thing with the same library:
`src/dawn/native/SpirvValidation.cpp:37-79` builds a `spvtools::SpirvTools`,
sets a message consumer, calls `Validate`, and disassembles on failure. The
port replaces the library with Zig and keeps the corpus.

### 7.3 What this is not

`spirv-val` is not a build input. It never runs inside `zig build`.
It needs a supplemental fixture check. The installed legacy gate does not run it.

---

## 8. The house gate

### 8.1 The ten stages

The ten-stage contract and historical help transcript specify this order.
This is not the help output of the currently installed legacy script.

```
sections (in order)
  1 fmt         zig fmt --check over the project file list
  2 build       zig build
  3 test        zig build test
  4 ast-check   zig ast-check over the project file list
  5 ziglint     ziglint over the project file list          (asserts)
  6 zlint       zlint -S over the project file list         (asserts)
  7 zbc         zbc escape analysis                         (advisory)
  8 zwanzig     zwanzig over the project file list         (asserts all findings)
  9 cross-test  cross-test matrix, narrowed by ./cross-test.profile.sh
 10 zig-cov     coverage, opt-in via --cov                  (advisory)
```

The block above records the historical ten-stage interface.
On 2026-10-07, `~/.local/bin/zig-gate` is a 213-line legacy script.
It runs fmt, build, tests, ast-check, stdin-mode `zlint`, and advisory `zbc`.
Its `ziglint` block is commented out. It has no `zwanzig` or cross-test stage.
Coverage is optional and off by default. The script does not assert all nine
non-coverage contract stages, full foreign execution, fixture artifacts, or coverage.

Missing stages require supplemental `ziglint`, `zwanzig`, and `cross-test` commands.
Use the same hand-written source selection for each analyzer.
Assert every `zwanzig` finding class without suppression.
The user revised `zbc` handling to report-only and stopped further tool source work.
Retain explicit diagnostic counts and incomplete-analysis evidence.
Do not hide aborted files or claim unverified repairs as clean analysis.
Numeric warnings alone do not establish source bugs.
Run `cross-test` with `./cross-test.profile.sh` and retain its per-row status.
Run fixture regeneration and `spirv-val` separately when claiming fixture evidence.
The 2026-10-07 pre-feature legacy gate passed its five active stages.
That supplemented ten-stage snapshot was not green because it reported 107 optional-unwrap warnings.
BG106 passed the current legacy `zig-gate --no-zbc` run, with exactly five active stages.
BG104 passed final 142-file source lint with zero diagnostics, errors, or warnings.
The full ten-stage contract remains unclaimed and outside the permitted analyzer boundary.

What the ten-stage contract requires, not what the installed script proves:

| Stage | Required evidence | Does not prove |
| --- | --- | --- |
| 1 `fmt` | every project file parses and is formatted | that it compiles |
| 2 `build` | the published module compiles for the host in Debug | that any test passes |
| 3 `test` | root library and dispatch tests run in Debug and ReleaseSafe, with acceptance shards in Debug | both modes for every acceptance shard |
| 4 `ast-check` | every project file parses on its own, including a file the build graph does not reference | any semantics |
| 5 `ziglint` | the stage fails when `ziglint` reports one finding over the selected source | that the rules are the right ones |
| 6 `zlint -S` | the stage fails when `zlint` reports one error or one warning over the selected source | that the two sets are complete |
| 7 `zbc` | report-only under the user boundary, with explicit findings and incomplete-analysis disclosure | clean complete analysis or verified repairs |
| 8 `zwanzig` | the supplemental check must fail on any finding class | a current clean result. The pre-feature snapshot reported 107 optional-unwrap warnings. |
| 9 `cross-test` | the selected foreign Debug shard executes each profile row, with explicit partial status for omissions | full foreign Vulkan execution (§10) |
| 10 `zig-cov` | a coverage figure, when `--cov` is passed | anything: it is advisory and off by default |

`devenv.nix` defines `GATE_EXCLUDE` for generated SDK/API files and cache directories.
`src/vulkan.zig` and `src/api/` are generated. Fix their generators, not the output.
`src/vk/dispatch.zig` remains selected despite its generated declarations.
Its protected generated region requires the dispatch drift check.
`devenv.nix` runs the legacy script as `gate:dusk`.
`zbc` is advisory unless `ZBC_STRICT=1`.
The historical measurements below do not change this installed-script behavior.

### 8.2 The two safety modes

`build.zig` runs the library tests in **Debug** and **ReleaseSafe**, and it
applies an address-space ceiling of 4 GiB to each native run through
`ulimit -v`. That ceiling is what turns an unbounded allocation loop into a
fast, visible failure instead of a machine-wide problem.

### 8.3 What a green gate does not prove

1. **A coverage percentage.** `zig-cov` is advisory and off unless `--cov` is
   passed. Nothing in the gate asserts a figure, and a coverage number is not a
   quality measure.
2. **Fuzzing.** No stage runs a fuzzer. `AGENTS.md:94-95` requires fuzzing at
   every decoder boundary, and until that exists the gate proves nothing about
   malformed SPIR-V, a truncated buffer, or an out-of-range descriptor.
3. **Sanitizers.** No stage runs an address or undefined-behaviour sanitizer.
4. **`ReleaseFast` and `ReleaseSmall`.** `zig build test` runs Debug and
   ReleaseSafe. An optimization-mode-dependent defect passes the gate.
5. **The absence of a leak.** Zig's test runner installs a leak-detecting
   allocator, and it reports a leak only for what was allocated through it.
   `docs/10-architecture.md:79-80,88-90` gives every WebGPU object a
   `std.heap.ArenaAllocator` that is reclaimed in one step when the device is
   destroyed, so an object leak is invisible to the checker by construction. A
   test must pass an explicit `std.testing.allocator` to anything it wants
   watched.

A green gate would show that the tree compiles, the registered tests pass,
and the analyzer stages found nothing to fail on.
The aggregate test step runs library tests in Debug and ReleaseSafe.
Its separate acceptance shards run in Debug.
The historical cross-test result covers the selected Debug shard, not full foreign execution.
None of this establishes coverage, malformed-input robustness, or memory correctness.

The historical gate run ended red at stage 8 with nine asserted
`store-violations-engine` findings (§8.5.1). Its stage 7 reported zero errors.
That record predates the 2026-10-07 local acceptance run.
Analyzer repair does not by itself establish a new green gate.
The 2026-10-07 pre-feature supplemented result was not clean: it reported 107 optional-unwrap warnings.
The historical legacy gate passed with `zbc` explicitly skipped.
Neither result verifies the native stage-constant changes.

### 8.4 One run is a snapshot, not a gate

A single compile, test, or probe run samples one state of one tree. While other
workers are editing that tree, the sample may describe a file that no longer
exists in that form. A machine-level fact read off one such sample is a claim
about a moment, not about the machine. Two facts of that shape arose here:

- A missing Vulkan driver was reported from one probe run taken while a peer was
  mid-refactor. The host has four NVIDIA RTX A6000 devices at
  `apiVersion = 1.4.351`, loaded through `/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json`.
- A `MissingGlobalProc` was given two causes that were both wrong. The cause was
  a half-rewritten `src/engine/vulkan_device.zig`.

One environment trap makes the first shape easy to fall into, because it puts an
error on stderr in front of a working device. `VK_INSTANCE_LAYERS` is set in this
shell to `VK_LAYER_KHRONOS_validation`, and outside devenv `VK_LAYER_PATH` names a
store path absent on this host (§4.1), so `vulkaninfo` prints this before it
reports any device at all:

```
ERROR: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" was not found but was requested by env var VK_INSTANCE_LAYERS!
```

That line is a statement about the layer, not about a driver. Clearing
`VK_INSTANCE_LAYERS` removes it and leaves the device list unchanged:

```
$ env -u VK_INSTANCE_LAYERS vulkaninfo --summary 2>/dev/null | grep -c '^GPU'
4
```

So a loader error is read with the device list beside it, never alone.

`store-violations-engine` is not a class the gate sets aside. §8.5 measures
what it reports and what the stage does with it.

The rest of this document describes a settled tree. Where it quotes a run, the
run is named; where the tree was moving, the sentence records the measurement
and not the conclusion drawn from it.

### 8.5 Two analyser findings that are limits, not defects

**Historical evidence, retained on 2026-10-07.** The counts, line anchors, tool
behavior, and per-site exemptions below describe the earlier measured tree.
They do not describe current analyzer results or authorize new suppressions.

Two stages of the gate report findings that measurement, not argument, shows
to be limits of the analysers rather than defects in this tree. One is
asserted and leaves the stage red. The other is exempted per site and the
stage passes. Both are recorded here so the histogram is readable.

**A clean result is evidence only after the detector is shown to work.** The
ordering is the reusable part. A negative result from a leak detector or an
escape analyser is worthless until the same detector has been made to fail on
a deliberate violation, so that came first. Grade A, Zig 0.16.0:

```
$ zig test detector.zig        # a double free and a leak, one per run
1/2 ...a deliberate double free is caught...Segmentation fault at address 0x7f579f4c0000
std/mem/Allocator.zig:448:5: in free__anon_37932
    @memset(bytes, undefined);
detector.zig:11:31: in test.a deliberate double free is caught
error: the following test command terminated with signal ABRT
```

```
$ zig test leak_only.zig       # the leak half alone: the abort above kills the run
All 1 tests passed.
1 errors were logged.
1 tests leaked memory.
error: the following test command failed with exit code 1
```

So `std.testing.allocator` catches a double free on the second `free` and
fails a run that leaks, on this toolchain. The two halves cannot share a run,
because the first aborts the process before the second is reached.

#### 8.5.1 `store-violations-engine`: nine findings, all one class

`zwanzig` reports 9 findings over the 123 selected files, and every one is
`store-violations-engine`:

| File | Line | Finding |
| --- | --- | --- |
| `src/command/encoding_context.zig` | 413 | double free |
| `src/engine/vulkan_device.zig` | 1305 | resource leak |
| `src/platform/loader.zig` | 96 | double free |
| `src/spirv/reflect.zig` | 156 | double free |
| `tools/gen_api.zig` | 1063, 2720, 2749, 2769, 2879 | resource leak |

**The limit.** The rule does not model `errdefer` as an ownership transfer. A
correctly undone allocation, where the callee takes over the value and the
caller's `errdefer` must not run, reads as unreleased; a correctly moved
allocation reads as a double free. `AGENTS.md:82-85` makes `errdefer` mandatory
on every allocating function, so the code is written to a rule the analyser
does not implement.

**The load-bearing case is the five in `tools/gen_api.zig`.** They allocate
from `gpa`, which is `init.arena.allocator()` (`tools/gen_api.zig:3336`), and
`std.process.Init.arena` is documented at `lib/std/process.zig:33-35` as
"Permanent storage for the entire process, cleaned automatically on exit."
Satisfying the rule there would mean a per-allocation free of memory the arena
owns, which is a real defect. The other four are the same shape with a
caller-supplied allocator.

**The detector was checked on the two code paths the rule misreads.** Grade A,
every allocation-failure index from 0 up to the first success, with
`std.testing.allocator` as the back end:

```
$ zig test --dep dusk -Mroot=fail_n.zig -Mdusk=dusk_shim.zig
1/2 fail_n.test.fail-N over two commits and the merge in finish...OK
2/2 fail_n.test.fail-N over the iterator merge...OK
All 2 tests passed.

$ zig test --dep dusk -Mroot=loader_n.zig -Mdusk=dusk_shim.zig
1/1 loader_n.test.fail-N over the loader's joined candidate name...OK
All 1 tests passed.
```

Four of four passed: two through `src/command/encoding_context.zig`, whose
`freeBlocks` (`src/command/encoding_context.zig:412-415`) is the double-free
site, and one through `src/platform/loader.zig:96`, whose
`defer if (joined) |name| allocator.free(name);` is the other. Every
`error.OutOfMemory` path and every `errdefer` on those paths ran at least once
and released what it owned.

**The ruling.** The project owner owns `zwanzig` as a fork and has ruled the
`errdefer` correct as written, not to be rewritten to satisfy the rule. The
limit belongs to the tool. The stage is not exempted: `devenv.nix` sets no
`ZWANZIG_ARGS`, `zig-gate` asserts every class, and the 9 findings above make
stage 8 red.

#### 8.5.2 `heap-leak`: two findings, exempted per site

`zbc` reported 4 errors. Two were defects and were fixed. The remaining two are
`heap-leak` at `src/engine/query_set.zig` and `src/engine/texture.zig`, both
reading "destructor does not free `self`", and both wrong.

**The limit.** Both objects are arena objects. `Device.create` reaches
`ObjectArena.create` (`src/core/object.zig:354-361`), which takes the block with
`arena_allocator.create(T)`, and `ObjectArena.deinit`
(`src/core/object.zig:400-405`) reclaims every block with `reset(.free_all)`.
The rule classifies a factory named `create` as a heap factory and asks the
destructor for a call that cannot release anything.

**The proof is a leak-detector run, not an argument.** Sixty-four `QuerySet`s
and sixty-four `Texture`s through the real path, each torn down, then
`Device.deinit`, with the arena capacity asserted above zero beforehand so the
blocks were really held. `std.testing.allocator`, the leak detector, reports
nothing.

**The control.** `ArenaAllocator.free` rewinds only when the block ends at the
arena's newest byte, and returns otherwise
(`lib/std/heap/ArenaAllocator.zig:620-623`). Both constructors allocate after
the object block: `QuerySet.create` the availability vector, `Texture.create`
the view formats, the offset table, the initialized flags and the store. The
object block is therefore never that byte, and `allocator.destroy(self)` in
either destructor is a guaranteed no-op that reads as a release. The suggested
call is not merely redundant: the same `free` rewinds `end_index` by
`memory.len` when the block does end at the newest byte
(`lib/std/heap/ArenaAllocator.zig:625-635`), so whether it releases anything
depends on what the arena handed out afterwards. That is a live-block hazard,
not a redundant call.

**The rule's own escape is unavailable.** It is satisfied by renaming the
destructor, and `ObjectArena.assertHeader` requires the method be named
`destroy`: `@hasDecl(T, "destroy")` is a compile error otherwise
(`src/core/object.zig:286-288`). Renaming `Device.create` would clear the
finding and was refused, because renaming a public method so a pattern
detector stops matching costs the house naming convention and buys nothing.

**The exemption taken, and why that one.** `zbc --list-invariants` prints
`heap_leak`, and `--disable=heap_leak` does silence the rule, so the finding
can be exempted by id. It was not used: `--disable` is all-or-nothing for the
whole run, so it would also silence the rule for every genuine heap object in
the 123 files, which is worse than the finding. The exemption in the tree is
per site, one line above each declaration:

```
    // zbc-disable-next-line: heap-leak
    pub fn destroy(self: *QuerySet, reason: object.DestroyReason) void {
```

Measured: it takes the two findings to zero and changes nothing else, and
`src/platform/loader.zig` still reports its own unrelated warning. The
directive must be the line immediately above the declaration; with an evidence
block between them it applies to a comment and the finding returns, which was
observed and corrected. The evidence lives in the same comment block, where a
reader reaches it. Stage 7 now reports 0 errors and 21 warnings, and the
warnings do not fail it.

**What is not claimed.** Neither ruling claims the rules are correct
elsewhere, and neither is a precedent for exempting a class. A finding carries
its own evidence or it is answered with a fix.

---

## 9. The test taxonomy

`docs/02-dawn-design.md:372-375` names three cross-cutting mechanisms in Dawn.
This is the whole of the upstream test infrastructure that a port must
re-create. Each is decided here.

### 9.1 The deferred expectation engine

**Upstream.** `DawnTest.h:873-885` holds a `DeferredExpectation` list. A
`ReadbackSlot` at `DawnTest.h:849-851` names the buffer each expectation reads.
`TearDown` resolves everything: `DawnTest.cpp:1774-1775` calls
`ResolveDeferredExpectationsNow`, which at `DawnTest.cpp:2480-2494` maps every
slot synchronously, checks the replayed buffers, resolves the expectations, and
clears the lists. `ResolveExpectations` at `DawnTest.cpp:2329-2337` walks the
list once the data is mapped.

**Decision: keep it, in the same shape.**

- Priority: a WebGPU submission is asynchronous by contract, so an assertion
  written right after a submit has no data to read. Resolving at teardown is
  what makes `expectPixel` a one-line call at the point of interest.
- Constraint: the port has one device mutex and one serial timeline
  (`docs/10-architecture.md:102-103`), exactly the shape that makes a deferred
  list coherent.
- Cost imposed on consumers: a failing assertion reports at `TearDown`, not at
  the line that made it. The message must therefore carry the source location,
  which is what Dawn's `DeferredExpectation::file` and `::line` fields do at
  `DawnTest.h:874-875`.
- Counterchoice: resolve each expectation immediately, which removes the list
  and reports at the right line. It genuinely wins when the engine is
  synchronous, or when a test asserts once and then finishes. It loses here,
  because a render test that asserts four pixels then reads them back would
  wait four times instead of once.
- Grade: B for the upstream shape, C for the port's version.

Zig spelling, in `test/support/Expectation.zig`:

```zig
pub const Expectation = struct {
    file: []const u8,
    line: u32,
    slot_index: u32,
    check: *const CheckFn,
    context: *anyopaque,
};

pub fn expectPixel(self: *Self, options: PixelAssertOptions) !void;
```

`CheckFn` is a function pointer with the context last, matching the house
callback rule in `AGENTS.md:56-57`.

### 9.2 Per-adapter parameterisation

**Upstream.** `AdapterTestConfig.h:78-86` defines `AdapterTestParam`, which
carries the adapter properties, the forced workarounds, and the compatibility
flag. `DawnTest.h:938-939` makes it the default parameter type of
`DawnTestWithParams`.

**Decision: keep it, reduced to the axes that can differ here.**

- Priority: a test that runs once proves nothing about the other configuration.
  Inside devenv there is one device, so the axes that matter are the ones a
  driver can vary.
- Constraint: the port has one back end, so Dawn's seven back-end axes
  (`AdapterTestConfig.h:90-112`) collapse to one value.
- Cost imposed on consumers: a test runs N times. On this host N is 1 inside
  devenv and 4 outside it. A suite that runs the shader tests four times on a
  CPU rasteriser becomes slow, so the matrix is narrowed by a test's own
  declaration of which axes it is sensitive to.
- Counterchoice: run once against adapter 0. It genuinely wins when the driver
  is known uniform, which is the case for the four identical A6000 devices and
  is the reason a naive port would choose it. It loses on the day the four
  devices differ, because no test would notice.
- Grade: B for the upstream shape, A for the device counts in §5.

The axes are `driver_name`, `device_type`, `compatibility_mode` and `selected`.
`compatibility_mode` is a runtime derivation and never a build flag
(`docs/10-architecture.md:147-150`).

### 9.3 Skip predicates

**Upstream.** `DawnTest.h:900-907` defines `DAWN_SKIP_TEST_IF_BASE`.
`DAWN_TEST_UNSUPPORTED_IF` at `DawnTest.h:911` skips a test that needs a
feature or a toggle. `DAWN_SUPPRESS_TEST_IF` at `DawnTest.h:916` skips a test
that fails on a named hardware and backend combination, and it is cancelled by
`--run-suppressed-tests` (`DawnTest.cpp:623-624`).

**Decision: keep both, and make a skip visible.**

- Priority: a feature that the device does not expose must not fail the suite,
  and the reason must survive into the output.
- Constraint: a skip is silent coverage loss. It is the easiest way for a green
  suite to mean nothing.
- Cost imposed on consumers: every skip prints its predicate and its reason,
  the suite reports the skip count, and a suite whose skip ratio rises above a
  declared bound fails.
- Counterchoice: delete the predicates and let the device-dependent tests fail
  on the device that cannot run them. It genuinely wins when the whole matrix is
  known and small, because there is then no silent hole to guard. It loses as
  soon as a second driver appears, which §5.2 already provides.
- Grade: B for the upstream shape, C for the port's rules.

Zig spelling:

```zig
pub fn skipIfUnsupported(condition: bool, options: SkipOptions) error{Skipped}!void;
pub fn skipIfSuppressed(condition: bool, options: SkipOptions) error{Skipped}!void;
```

§2.5 gives the first real use. `VK_FORMAT_R4G4B4A4_UNORM` is not a mandatory
format, so a test that uses it skips itself when the format-property query
reports the bit missing.

---

## 10. Cross-test

**Current native stage-constant snapshot, 2026-10-08.** BG103 passed all three selected rows with 262 root tests each.
The summary reported `pass=3`, `fail=0`, `build_only=0`, and `partial=0`.
The run ID is `20261008-002745-1243037-21180`.
The summary file is `~/.cache/dusk/cross-test/cross-test-summary.json`.
This proves foreign root-test execution, not foreign GPU execution.

**Historical pre-feature snapshot, 2026-10-07.** The selected matrix passed all three rows:
`x86_64-linux`, `aarch64-linux`, and big-endian `powerpc64-linux`.
Each row executed 251 tests in that run.
The summary reported `pass=3`, `fail=0`, `build_only=0`, and `partial=0`.
The run ID is `20261007-223439-864143-20044`.
The historical run `20261007-211754-709407-22206` executed 250 tests per row.
The earlier run `20261007-171440-356118-5366` executed 248 tests per row.

```sh
devenv shell -- cross-test --profile ./cross-test.profile.sh \
  --output ~/.cache/dusk/cross-test --require-runners
```

This result covers the selected matrix, not full foreign execution of every subsystem.

### 10.1 The matrix

`cross-test.profile.sh` defines `CROSS_MATRIX` and sets `CROSS_REQUIRE_RUNNERS=1`.

| Row | What it is |
| --- | --- |
| `x86_64-linux` | the host target, so a gap in the matrix can never hide a native break |
| `aarch64-linux` | foreign 64-bit little-endian, the phone and embedded ABI |
| `powerpc64-linux` | foreign 64-bit **big-endian** |

`CROSS_REQUIRE_RUNNERS=1` makes a missing runner fail.
A missing runner must not silently turn execution coverage into compile-only coverage.
A broken QEMU installation must not look green.

`build.zig` wires the step as `cross-test`, which runs the Debug shard through
the build system's own runner selection, native for the host and `qemu_user` for
a foreign target. `cross_run.has_side_effects = true`, because a cached run
executes no test and would otherwise report coverage it never produced.

### 10.2 What a foreign row proves

`cross-test.profile.sh` states the native/foreign split:

- A foreign row exercises selected core, memory, format, and frontend code,
  plus fake Vulkan fixture state. It can check byte layout and ABI behavior.
  `powerpc64-linux` supplies the selected big-endian execution path.
  This is not full foreign execution of every library subsystem.
- A foreign row does not execute real GPU work. No foreign row has a Vulkan
  loader or ICD here. Generated declarations in `src/vulkan.zig` do not change
  that limit. Native runtime tests supply the real Vulkan evidence.

The consequence for this document: the readback pipeline in §2, the layer matrix
in §4, and the driver matrix in §5 are native-only evidence. The cross-test
shard does not open an instance and must not be given code that would make it
try.

### 10.3 Budgets

`cross-test.profile.sh` sets `CROSS_JOBS=2`, `CROSS_BUILD_JOBS=2`,
`CROSS_BUILD_TIMEOUT=3600`, and `CROSS_TIMEOUT=600`. The build budget is
generous because a foreign row builds every Zig dependency from source under
`qemu_user`.

`cross-test --help` names the evidence layout: `PREFIX/runs/RUN_ID/{build,run}-TARGET.log`
and `summary.json`, with `PREFIX/cross-test-summary.json` as the current-run
summary. `devenv.nix` defines `GATE_CROSS_OUTPUT` for the local evidence directory.

---

## 11. What counts as evidence

Three claims, and each is weaker than it sounds.

### 11.1 A build claim

> The code compiles for target T in mode M.

Established by gate stage 2, or by stage 9 for a foreign target. It establishes
that the compiler accepted the source and that the link resolved.

It does **not** establish that the code runs, that it produces the right answer,
or that it terminates. A build claim about the Vulkan half inside devenv is a
link claim only, because the container's loader reaches lavapipe and nothing
else (§5.1). Outside devenv the same loader reaches four NVIDIA devices, and a
link proves nothing about what they do with the call.

### 11.2 A test claim

> A named test passed, in a named layer mode, on a named driver, in a named
> optimisation mode, on a named target.

Established by gate stage 3, read together with the mode it ran in. The mode
must be in the claim, because §4.2 gives three modes and they prove different
things.

It does **not** establish that the test would fail without the change it is
testing. Nothing in this project runs a mutation, so a test that asserts
nothing passes exactly as loudly as a test that catches a bug.

### 11.3 A runtime observation

> This binary, in this environment, produced this output.

Established by a quoted command. The driver lists in §1.1, §5.1 and §5.2 are
runtime observations.

It does **not** establish generality. Four identical RTX A6000 devices say
nothing about a driver from another vendor, and one lavapipe run says nothing
about a machine whose Mesa is a different version.

### 11.4 The rule

Every claim in a commit message, a review, or a release note names its
configuration: layer mode, driver, target, optimisation mode. A claim without
one is an observation, and it is labelled as one.

---

## 12. Citations

A citation is checked in two places, and the two checks catch different
failures. Neither substitutes for the other.

### 12.1 A bare continuation inherits its file

**Rule: a bare continuation citation inherits its file from the nearest
preceding named citation in the same comment block, and a block whose named
file changes invalidates every bare line after it.**

Grade C, decided here. It is a rule rather than a caution because the failure
is silent: a bare `:210-259` carries no file name, so nothing fails to
compile and no reader can see which file it resolved to. The file has to be
re-derived before the line can be read.

Two obligations follow.

- Re-resolve per comment block, never once per file.
- Name the file when the claim outlives the block that named it.

Two measured instances, both from the audit in §12.4.

1. `src/pipeline/bind_group_descriptor_set.zig:130` carried a bare `:62` that
   resolved against the `BindGroupLayoutVk.cpp:56` named a line earlier in the
   same comment and landed on a texture-index comment at
   `src/dawn/native/vulkan/BindGroupLayoutVk.cpp:62`. The
   `DAWN_CHECK(count > 0)` it claims is at
   `src/dawn/native/vulkan/DescriptorSetAllocator.cpp:62`.
2. `src/engine/vulkan_device.zig:690` carried `:389` against `BackendVk.h`,
   which holds 128 lines. The loader gate it claims is
   `src/dawn/native/vulkan/VulkanInfo.cpp:86-94`.

Neither was visible before re-resolution. Grade B, read at the pin.

### 12.2 A full citation is checked on the line

**Rule: read the cited line, and where the row names a symbol, require that
symbol to be on it.**

Grade C, decided here. A line count is not the check. It catches a citation
that points past the end of its file and catches nothing else. The
`docs/40-plan.md` audit found both shapes. `DescriptorSetAllocator.h:154`
against a 117-line file and `Device.h:1755` against a 771-line file were out of
range. `BindGroupLayoutInternal.cpp:214`, corrected to `:917`, and
`BindingInfo.h:174`, corrected to `:267`, were both in range and both held
something else, and a length check passes them unchanged. Grade B for the four
file lengths, read at the pin.

A citation that points into a real file looks checked. That is the check a
reader skips.

### 12.3 What neither check settles

Rows whose symbol cell is prose rather than an identifier, the `the X check`
rows, cannot be settled by matching a symbol on a line. They are settled by
reading the surrounding statement rather than the cited line alone. That is
slower, and it is the honest reason a full audit costs what it does. A
surviving miss is most likely to hide in these rows.

A primary cite names its file. A bare continuation does not, which is why
§12.1 and §12.2 are separate rules and not one.

The rates that carry both mechanisms, counted by the `docs/40-plan.md` audit:
57 of 2,492 primary cites needed correcting, and 24 of 41 bare records in one
batch resolved to the wrong file. Grade A.

### 12.4 The `src/` and `test/` audit result

Grade A. One pass over `src/` and `test/` re-resolved every citation against
the pinned tree and read it.

| Records | Count |
| --- | --- |
| Total | 4,186 |
| Corrected | 1,278 |
| Read at the pin, already right | 2,908 |
| Unverifiable | 34 |

The 34 unverifiable are accounted and none of them blocks. 22 are
`vk_mem_alloc.h` cites in `src/memory/vma.zig` against a VMA header absent
from both the pinned Dawn tree and this host. 11 are Vulkan and C header cites
in generated or boundary files. 1 is in `src/vulkan.zig`, verified correct
against Zig 0.16.0 std and left alone.

The correction count does not read without its split. 1,499 of the 4,186
records are bare continuations, 1,204 of the form `:210-259` and 295 bare
`:NNN` with no file in reach, so more than a third inherit their file from the
block around them. What the audit mostly found was inherited-file risk caught
by re-resolution, not wrong citation text. Read alone, "1,278 corrected"
overstates how much individual text was wrong; the bulk is inherited-file
risk. §12.1 is the rule this tree needs, at 1,499 of 4,186 records.

`src/vulkan.zig` and everything under `src/api/` were never edited; both are
generated (`docs/10-architecture.md:13`, `:16`, `:24`). `src/api/` carries
`dawn.json:NNN` records its own generator emits, and `src/vulkan.zig` carries
only transpiler-warning paths. No claim in this project is authored in a
generated file, so every claim lives in hand-written source or hand-written
docs.

---

## Not claimed here

This document does not claim any of the following.

1. **Coverage.** No figure is claimed, and no stage of the gate asserts one.
2. **Fuzzing.** No decoder boundary is fuzzed. A malformed SPIR-V module, a
   truncated descriptor, or an out-of-range limit is not covered by anything
   described here.
3. **Sanitizers.** No address or undefined-behaviour sanitizer runs.
4. **`ReleaseFast` and `ReleaseSmall`.** `zig build test` runs Debug and
   ReleaseSafe. An optimization-mode defect passes the gate.
5. **The absence of a leak.** The default test allocator does not see an
   allocation made through a device arena.
6. **A swapchain, a surface, or a present.** No test on this host creates one,
   so the swapchain path is untested by construction. See §1.2.
7. **Vulkan on a foreign architecture.** No foreign row has a loader or an ICD.
   See §10.2.
8. **The NVIDIA driver from inside devenv.** It is unreachable there
   (§5.1), so a green gate never exercises it.
9. **A performance figure.** Nothing here was measured for speed, and no
   tolerance was chosen by timing.
10. **WebGPU conformance.** Nothing here runs `webgpu-cts`.
    `docs/02-dawn-design.md:463-464` records that the conformance list lives in
    a separate checkout.
11. **`tint`'s exact interface.** It is not installed, so §6.2 names the shape
    of the step and not its flags.
12. **The `linearTilingFeatures` bits of the two optional formats.** See §2.5.
13. **A current defect inferred from the historical analyzer counts.** Section
    8.5 records earlier detector limits and exemptions, not the current final gate.
14. **A current clean analyzer result.** The historical pre-feature default run reported 107 optional-unwrap warnings.
    No new analyzer run establishes a current count for native stage constants.
15. **Any machine-level fact from a run taken while the tree was moving.** A
    single run is a snapshot. See §8.4.

16. **A count of the citations in `docs/`.** The §12 figures cover `src/` and
    `test/` only.

## Open items

Each item is `UNKNOWN:` with the action that would settle it.

1. `VK_EXT_headless_surface` behaviour on lavapipe without `VK_KHR_display`.
   Settled by a small program that calls `vkCreateHeadlessSurfaceEXT`.
2. ~~The exact `tint` command line and whether it is byte-deterministic.~~ Both
   settled in §6.2: `--format=spirv` with an explicit `--ep` per entry point,
   and the output is byte-deterministic across runs.
3. `VK_FORMAT_R16G16B16A16_SFLOAT` and `VK_FORMAT_R4G4B4A4_UNORM`
   `linearTilingFeatures` on lavapipe. Settled by the format-property query the
   test performs.
4. ~~The `snake_case` spelling `zig translate-c` gives the `VkBufferImageCopy`
   fields.~~ It gives none: `src/vulkan.zig:4531-4538` keeps the C spelling, so
   the field is `bufferOffset`, not `buffer_offset`. §2.3 uses the C names.
5. ~~Whether `pkgs.tint` resolves in the pinned nixpkgs.~~ It resolves at
   0.1.7 and ships no binary, which is why the translator is built from the
   pinned Dawn checkout instead. Recorded in §6.2.
6. ~~`AGENTS.md` stated that `VK_EXT_headless_surface` is absent.~~ Corrected
   by the integration owner: it is present inside devenv on lavapipe and absent
   outside it on NVIDIA, while `VK_KHR_display` is the other way round. The
   offscreen-only decision rests on the absent display server, not the
   extension.
7. ~~`devenv.nix` did not provide a WGSL translator.~~ It now builds one with
   the `dusk:build-tint` task and exports it as `DUSK_TINT`. §6.2 is runnable.
8. ~~`.paths` in `build.zig.zon` did not list `test`.~~ It does, along with
   `tools` (`build.zig.zon:25-34`), and both directories exist. Recorded in §6.3.
