# cross-test profile for dusk.
#
# `zig-gate` section 9 runs this matrix. It is the only stage of the gate that
# leaves the host, and it is the project's only foreign-ABI and big-endian
# execution coverage. `zig-gate --no-cross` drops it; nothing else does.
#
# Read `~/zomp/cross-test.profile.sh` for the house
# commentary on the two properties this file must respect:
#
#   1. A green run reports `status=partial`, not `status=pass`, whenever a row
#      has no runner on this host. `partial` and `build_only` are judged by
#      `fail=0`. Do not pass `--require-runners` to turn that into a failure.
#   2. `status=fail` cannot tell a timeout from a wrong answer. A `timed out`
#      in a per-target build log is a budget problem; anything else is a real
#      failure. Keep the `CROSS_TIMEOUT` below set, because a `--timeout` on
#      the command line beats this file.
#
# Run the Debug shard through Zig's native and QEMU runner selection. Native
# `test` uses a shell launcher, which does not report counted results here.
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
# Vulkan itself is not exercised by a foreign row. No foreign architecture has
# a Vulkan loader or ICD here, so `src/vulkan/**` and every milestone that
# opens a `VkInstance` stay native-only and are proven by a native run against
# the host loader. What a foreign row proves is the half that must be portable:
# `src/core/**`, `src/math/**`, the wire encoding, and the Vulkan struct
# packing. Those are exactly the layers where an endianness or pointer-width
# bug hides, so the matrix earns its place.
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
# needed. The C half of the port, once it exists, will need a row per system
# library it links, because a `translate-c` binding that only works against the
# host glibc is not portable coverage. `docs/40-plan.md` names the milestone.
