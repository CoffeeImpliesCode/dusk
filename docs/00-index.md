# 00 — Index

Read in this order. Each document owns its scope and states what it does not
claim.

| # | Document | Owns |
| --- | --- | --- |
| 02 | [`02-dawn-design.md`](02-dawn-design.md) | The upstream codebase, mapped at Dawn `32f77c02294310054a660c393feded4bcb3f203c`. The evidence base for everything else. |
| 10 | [`10-architecture.md`](10-architecture.md) | Module layout, boundaries, dependency direction, object model, threading. |
| 20 | [`20-dependencies.md`](20-dependencies.md) | The dependency ladder, every C-library decision, and the Vulkan environment inside devenv. |
| 30 | [`30-port-design.md`](30-port-design.md) | The Zig-native public contract: ownership, errors, futures, descriptors, dispatch, containers. |
| 40 | [`40-plan.md`](40-plan.md) | Milestones, the module table, and the function-level mapping table. |
| 50 | [`50-verification.md`](50-verification.md) | Offscreen readback, the layer and driver matrices, shader fixtures, and what a green gate does not prove. |

`AGENTS.md` at the repository root holds the house rules. `README.md` is the
entry point for a reader.

## The three sentences

1. **Zero C++.** Not linked, not built, not vendored. Dawn's vendored `src/tint`
   — 753,961 lines — is not ported.
2. **SPIR-V in, SPIR-V out.** The port validates and reflects a SPIR-V binary,
   then hands the caller's own words to `vkCreateShaderModule`. Dawn cannot do
   this: it round-trips through Tint and regenerates. That is where the size
   saving comes from.
3. **The public API is data.** `src/dawn/dawn.json` describes 347 API objects,
   205 methods and 571 members. A Zig `comptime` generator turns it into the
   public surface. Nothing about the API is transcribed by hand.
