# cross-test profile for dusk.
#
# Run this matrix separately from the installed legacy `zig-gate`, which has
# no cross-test stage. The house contract includes this as stage 9.
# Every selected row requires a runner; missing execution fails the check.
# Native `test` uses a shell launcher, which does not report counted results.
CROSS_BUILD_STEP=cross-test

# The matrix. Every row must have a runner on this host, because
# CROSS_REQUIRE_RUNNERS below turns a missing runner into a failure rather than
# silently degrading execution coverage into compile-only coverage.
#
#   x86_64-linux  the host target, so a matrix gap can never hide a native break
#   aarch64-linux foreign 64-bit little-endian, the common embedded and phone
#                 ABI, and the one with the best qemu_user support
#   powerpc64-linux foreign 64-bit BIG-endian, the only row that catches an
#                 endianness bug in the tree serialisation, the action channel
#                 marshalling, and the C ABI structs. Those are byte layouts, so
#                 a big-endian row is the only execution proof that they are
#                 written correctly.
#
# Foreign rows run the root Debug shard, including core objects, memory,
# canonical formats, command encoding, replay fixtures, and Vulkan ABI types.
# They use injected Vulkan procedures, not a foreign loader or device.
# Native GPU readback remains a separate acceptance check.
#
# The matrix grows as the port lands. `docs/40-plan.md` names the milestone
# that adds rows and the reason for each: riscv64 and loongarch64 for wider
# architecture coverage, and x86-linux for 32-bit pointer and alignment bugs.
CROSS_MATRIX=(
   'x86_64-linux|auto'
   'aarch64-linux|auto'
   'powerpc64-linux|auto'
)

# A missing runner fails rather than turning execution coverage into
# build-only. Without this a broken qemu install would look green.
CROSS_REQUIRE_RUNNERS=1

# Bound concurrent compiler work, and allow a cold build plus an emulated run.
# The foreign rows build every Zig dependency from source under qemu_user, so
# the build budget is generous and the run budget is not.
CROSS_JOBS=2
CROSS_BUILD_JOBS=2
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=600

# Foreign Linux rows build static musl, so no CROSS_LIBC_RUNTIMES loader is
# needed. This matrix does not claim foreign GPU execution.
