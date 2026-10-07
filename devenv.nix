{ pkgs, lib, config, inputs, ... }:

let
  # Zig 0.16.0 cannot keep its caches on a network filesystem: the package
  # unpacker mis-stats the files it writes and reports them as "illegal file
  # type 'unknown'", and the cache-rename path panics on an EINVAL from
  # `access`. Identical sources build cleanly on local disk, so every cache
  # lives there and the build root points at it.
  #
  # This checkout is under $HOME on NFS, so the default resolves to
  # $XDG_CACHE_HOME/dusk. `~/.dev-env.sh` points XDG_CACHE_HOME at the host
  # scratch mount, which is local disk. DUSK_CACHE_ROOT wins over that; set it
  # explicitly when the XDG default is not local.
  cacheRoot =
    let
      duskCacheRoot = builtins.getEnv "DUSK_CACHE_ROOT";
      xdgCacheHome = builtins.getEnv "XDG_CACHE_HOME";
    in
    if duskCacheRoot != "" then
      duskCacheRoot
    else if xdgCacheHome != "" then
      "${xdgCacheHome}/dusk"
    else
      "${builtins.getEnv "HOME"}/.cache/dusk-zig";

  # This source reference is fetched only by `zig build fetch-dawn`.
  # The translator uses the same revision but needs a complete source tree.
  scratchRoot =
    let s = builtins.getEnv "buildhost_SCRATCH_ROOT";
    in if s != "" then s else "${builtins.getEnv "HOME"}/.cache/dusk-research";
  dawnSrc =
    let override = builtins.getEnv "DUSK_DAWN_SRC";
    in if override != "" then override else "${scratchRoot}/research/dawn";
  dawnPinText = builtins.readFile ./tools/dawn_pin.zon;
  pinString = field:
    builtins.head (lib.splitString "\""
      (builtins.elemAt (lib.splitString ".${field} = \"" dawnPinText) 1));
  dawnRevision = pinString "revision";
  dawnUrl = pinString "url";
  tintBin = "${cacheRoot}/tools/tint";

  # Header data only. Do not execute the repository's Zig build script.
  # Keep this C header pin separate from the installed loader and tools.
  vulkanHeadersSource = pkgs.fetchzip {
    url = "https://codeload.github.com/CoffeeImpliesCode/vulkan-headers/tar.gz/8249cb829eb402c65cb7e3778c51b0f8edc4a4b6";
    # The codeload URL ends in a commit hash, not an archive filename.
    extension = "tar.gz";
    sha256 = "0z89r39v4ivhfc6c1km0bgxgddyy7fdsy88bgr5rw0afzfcahwpa";
  };

  # Packages alone do not expose libraries opened through std.DynLib.
  runtimePackages = [ pkgs.vulkan-loader ];

in
{
  packages = runtimePackages ++ [
    pkgs.git
    pkgs.pkg-config

    # `vulkaninfo` is how a test proves the loader sees a device at all, and
    # `glslangValidator`/`spirv-val` are how a test proves a SPIR-V fixture is
    # well formed before the engine ever sees it.
    pkgs.vulkan-tools
    pkgs.spirv-tools

    # `volk` is the Vulkan dispatch loader. It is a C library and a candidate
    # consume-don't-port dependency for the loader slot; `docs/20-dependencies.md`
    # owns that decision and the user has not made it yet.
    pkgs.vulkan-volk

    # The WGSL to SPIR-V translator, built from the pinned Dawn checkout rather
    # than taken from nixpkgs: `pkgs.tint` (0.1.7) ships no binary, and no other
    # nixpkgs package emits SPIR-V from WGSL.
    #
    # It is a C++ tool and it is built here, inside devenv, because the devenv
    # container has no `/lib64`: a binary linked against the host glibc dies
    # with "cannot execute: required file not found". Building against the nix
    # toolchain is what makes it runnable in the shell that runs the tests.
    #
    # None of this reaches `build.zig.zon`. The translator is a test-time tool;
    # the library never links it.
    pkgs.cmake
    pkgs.ninja
    pkgs.gcc
    pkgs.python3
    pkgs.python3Packages.jinja2
    pkgs.python3Packages.markupsafe

    # SPIRV-Tools: `spirv-val` proves a committed `.spv` fixture is well formed
    # before the engine sees it. The port's own validator is Zig and needs no
    # C++ at all; see `docs/20-dependencies.md`.

    # The Khronos validation layer. A verification tool, never a runtime
    # dependency: the library must run correctly with zero layers enabled.
    pkgs.vulkan-validation-layers
  ];

  # A build that dies holding a global-cache manifest wedges every later build
  # wanting the same cache, so it is per-project and off the checkout's
  # filesystem.
  env.ZIG_GLOBAL_CACHE_DIR = "${cacheRoot}/global";
  env.DUSK_DAWN_SRC = dawnSrc;

  # Replace inherited audio/scanner library paths only in this project shell.
  # Use Nix library paths, not shell substitutions or host library directories.
  env.LD_LIBRARY_PATH = lib.makeLibraryPath runtimePackages;

  # The house gate otherwise inherits the shared host cache. Keep this
  # project's build products and cross-test evidence with its own caches.
  env.GATE_CACHE_DIR = "${cacheRoot}/build";
  env.GATE_CROSS_OUTPUT = "${cacheRoot}/cross-test";

  # Keep all source checks enabled. Exclude generated caches at any depth, and
  # the two GENERATED source trees: `src/vulkan.zig` is `zig translate-c`
  # output over the pinned header and `src/api/` comes from `tools/gen_api.zig`.
  # Both carry a "do not edit" banner, so a finding in either is a finding in
  # its generator, not in this tree, and a hand fix would be erased by the next
  # `zig build generate`. `docs/50-verification.md` §8.1 records the scope.
  env.GATE_EXCLUDE = "/[.]zig-cache/ /zig-out/ /zig-cache/ /.jj/ /devenv/ /.direnv/ /src/vulkan[.]zig /src/api/";

  # Vulkan-Headers v1.4.365. The source root contains vulkan/vulkan and
  # vulkan/vk_video, so `build.zig` needs the outer vulkan include directory.
  env.DUSK_VULKAN_HEADERS = "${vulkanHeadersSource}/vulkan";

  # Driver discovery is a SHELL-time concern, decided in `enterShell` below.

  # Layer discovery. The nix layer wins over any host copy, so the version the
  # gate reports is the version the package pins rather than whatever the host
  # distribution happens to ship.
  env.VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";

  # Force-enable the layer for every Vulkan instance the shell creates,
  # including the ones a test binary opens. `VK_LOADER_LAYERS_DISABLE` is
  # deliberately NOT set here: a test that must prove the zero-layer path sets
  # it per process, rather than mutating the shared shell.
  env.VK_INSTANCE_LAYERS = "VK_LAYER_KHRONOS_validation";

  # Synchronisation validation catches the two mistakes a headless port makes
  # most often: a barrier with the wrong stage mask, and a resource read while
  # another queue still writes it. Both are invisible to a render-only test.
  #
  # `VK_LAYER_VALIDATE_SYNC=1`, not `VK_LAYER_ENABLES`. The layer prints
  # "Deprecated settings and new settings cannot be mixed, and deprecated ones
  # take precedence" for the old spelling, and a child process that inherits
  # `VK_LAYER_ENABLES` never reads this variable.
  env.VK_LAYER_VALIDATE_SYNC = "1";

  # Report to stderr. The default log is a file under $HOME, which is NFS here,
  # and a test that cannot see the layer's output cannot assert on it.
  # `abort_on_error` stays off: failing an assertion is the test's job, and a
  # layer that aborts takes the whole shard with it.
  env.VK_LAYER_LOG_PATH = "stderr";
  env.VK_LAYER_LOG_LEVEL = "info";

  enterShell = ''
    # Create this project's cache targets before linking the build root.
    mkdir -p -- "${cacheRoot}/build" "${cacheRoot}/pkg" "$ZIG_GLOBAL_CACHE_DIR"

    # `.zig-cache` and `zig-pkg` must be symlinks to local disk. A real
    # directory on a network filesystem is the failure this guards against,
    # so say so rather than silently moving a populated cache.
    for d in .zig-cache zig-pkg; do
      if [ -e "$d" ] && [ ! -L "$d" ]; then
        echo "dusk: $PWD/$d is a real directory; Zig 0.16.0 cannot build here." >&2
        echo "dusk: remove it and let devenv link it to ${cacheRoot}." >&2
      else
        case $d in
          .zig-cache) ln -sfn "${cacheRoot}/build" "$d" ;;
          zig-pkg) ln -sfn "${cacheRoot}/pkg" "$d" ;;
        esac
      fi
    done

    # Vulkan driver discovery. See the note in the `let` block.
    #
    # Inside devenv this shell runs in a container whose `/usr` is NOT the
    # host's `/usr`: `/usr/share/vulkan/icd.d` does not exist in here at all, so
    # the host NVIDIA ICD is unreachable and `libvulkan` reports
    # `vkCreateInstance: Found no drivers!`. That is the observed failure, and
    # it is a container fact, not a search-path bug.
    #
    # So the driver inside devenv is lavapipe, Mesa's software rasteriser. It
    # needs no GPU and no display, which is what a headless test wants, and it
    # makes the suite reproducible on any machine.
    #
    # Mesa also installs intel, freedreno, radeon, nouveau, virtio and ten more
    # ICDs. They are excluded deliberately: each probes DRM nodes it does not
    # own and prints a `VK_ERROR_INCOMPATIBLE_DRIVER` error, which would drown
    # a real failure in noise.
    #
    # DUSK_VK_DRIVER_FILES overrides the whole list, which is how a run reaches
    # real hardware: leave devenv and point it at the NVIDIA ICD, or bind
    # /usr/share/vulkan/icd.d and /dev/nvidia* into the devenv container.
    # `docs/50-verification.md` owns that matrix.
    _dusk_icds=""
    if [ -n "$DUSK_VK_DRIVER_FILES" ]; then
      _dusk_list="$DUSK_VK_DRIVER_FILES"
    else
      _dusk_list=""
    fi
    for _icd in $_dusk_list "${pkgs.mesa}"/share/vulkan/icd.d/lvp_icd.*.json; do
      if [ -e "$_icd" ]; then
        _dusk_icds="$_dusk_icds:$_icd"
      fi
    done
    if [ -n "$_dusk_icds" ]; then
      export VK_DRIVER_FILES="$(printf '%s' "$_dusk_icds" | cut -c2-)"
    else
      echo "dusk: no lavapipe ICD under ${pkgs.mesa}/share/vulkan/icd.d. Every GPU test reports zero devices." >&2
      echo "dusk: check with: devenv shell -- vulkaninfo --summary" >&2
    fi
    unset _dusk_icds _icd _dusk_list

    # Export only a cached translator with the current pin's revision sidecar.
    # A test that does not need Tint is not blocked by an unset variable.
    if [ -x "${tintBin}" ] && [ -f "${tintBin}.revision" ] &&
       [ "$(cat "${tintBin}.revision")" = "${dawnRevision}" ]; then
      export DUSK_TINT="${tintBin}"
    fi
  '';

  # The installed legacy gate skips ziglint, zwan, and the cross-test matrix.
  # zbc is advisory unless ZBC_STRICT=1. Run missing stages separately.
  tasks."gate:dusk".exec = "zig-gate";
  tasks."gate:dusk".description = "Run the installed house gate; supplemental analysis and cross-tests are separate";

  # Print what the loader can actually see. A green test run that silently
  # found zero devices proves nothing, so the driver list is part of the
  # environment contract and is worth printing on entry.
  tasks."dusk:vulkan-doctor".exec = "vulkaninfo --summary";
  tasks."dusk:vulkan-doctor".description = "Report the Vulkan devices and layers this shell can see";

  # The WGSL to SPIR-V translator. Built from the pinned Dawn checkout, inside
  # this shell, so it links against the same glibc the tests run on.
  #
  # The result is cached in `tools/` under the scratch cache root and exported
  # as `DUSK_TINT`. It is a test-time tool: `build.zig.zon` has no entry for it
  # and the library never links it. `docs/50-verification.md` owns the fixture
  # pipeline that consumes it.
  tasks."dusk:build-tint" = {
    description = "Build the pinned Dawn tint binary used to compile WGSL test fixtures";
    exec = ''
      set -eu
      src="${dawnSrc}"
      out="${tintBin}"
      build="${scratchRoot}/tint-build"
      if [ ! -d "$src/.git" ]; then
        echo "dusk: no standalone Dawn checkout at $src" >&2
        echo "dusk: run zig build fetch-dawn first; see docs/20-dependencies.md" >&2
        exit 1
      fi
      if [ "$(git -C "$src" rev-parse HEAD)" != "${dawnRevision}" ] ||
         [ "$(git -C "$src" remote get-url origin)" != "${dawnUrl}" ]; then
        echo "dusk: Dawn checkout does not match tools/dawn_pin.zon" >&2
        exit 1
      fi
      if [ -x "$out" ] && [ -f "$out.revision" ] &&
         [ "$(cat "$out.revision")" = "${dawnRevision}" ]; then
        echo "dusk: pinned tint already built at $out"
        exit 0
      fi
      if [ ! -d "$src/tools" ] || [ ! -d "$src/third_party" ]; then
        echo "dusk: sparse source reference is not a complete Tint build tree" >&2
        echo "dusk: prepare complete pinned sources and dependencies separately; see docs/20-dependencies.md" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$out")"
      cmake -GNinja -B "$build" -S "$src" \
        -DCMAKE_BUILD_TYPE=Release \
        -DDAWN_BUILD_TESTS=OFF -DTINT_BUILD_TESTS=OFF -DDAWN_WERROR=OFF \
        -DDAWN_BUILD_FUZZERS=OFF -DTINT_BUILD_FUZZERS=OFF \
        -DDAWN_BUILD_PROTOBUF=OFF -DTINT_BUILD_IR_BINARY=OFF \
        -DTINT_BUILD_CMD_TOOLS=ON -DTINT_BUILD_WGSL_READER=ON \
        -DTINT_BUILD_SPV_WRITER=ON \
        -DDAWN_USE_WAYLAND=OFF -DDAWN_USE_X11=OFF \
        -DDAWN_ENABLE_DESKTOP_GL=OFF -DDAWN_ENABLE_OPENGLES=OFF \
        -DDAWN_ENABLE_D3D11=OFF -DDAWN_ENABLE_D3D12=OFF \
        -DDAWN_ENABLE_METAL=OFF -DDAWN_ENABLE_WEBGPU_ON_WEBGPU=OFF
      ninja -j2 -C "$build" tint
      cp "$build/tint" "$out"
      printf '%s\n' "${dawnRevision}" > "$out.revision"
      echo "dusk: built $out"
    '';
  };

  # Compile one WGSL fixture to SPIR-V. The flag is `--format`, not
  # `--output-format`, and a module with more than one entry point needs an
  # explicit `--ep` per entry point; both were measured, not assumed.
  tasks."dusk:wgsl-to-spv".exec = ''
    set -eu
    if [ -z "$DUSK_TINT" ] || [ ! -x "$DUSK_TINT" ]; then
      echo "dusk: DUSK_TINT is unset. Run: devenv shell -- dusk:build-tint" >&2
      exit 1
    fi
    "$DUSK_TINT" "$1" --format=spirv -o "$2" "$@"
  '';
  tasks."dusk:wgsl-to-spv".description = "Compile one WGSL file to SPIR-V";

  enterTest = ''
    zig version
    vulkaninfo --summary
    zig-gate
  '';
}
