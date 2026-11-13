#!/usr/bin/env bash
# Cross-build llama.cpp (Vulkan backend) for the HiFive Unmatched (riscv64,
# SiFive U74, Ubuntu) on an x86-64 Ubuntu host, and package it as
# dist/llamacpp-riscv64-unmatched.tar.gz.
#
# Nothing here runs on the board. Environment overrides:
#   LLAMACPP_REF      llama.cpp release tag           (default below)
#   VULKAN_REF        Vulkan-Headers/Vulkan-Loader tag (default below)
#   SPIRV_HEADERS_REF SPIRV-Headers tag               (default below)
#   RISCV64_SYSROOT   riscv64 sysroot                 (default /usr/riscv64-linux-gnu)
#   WORK_DIR          sources + build trees           (default ./build-riscv64)
#   DIST_DIR          output directory                (default ./dist)
#   JOBS              parallel build jobs             (default nproc)
#   SKIP_APT=1        don't apt-get install host dependencies
#   LLAMACPP_EXTRA_CMAKE_ARGS  extra (space-separated) llama.cpp CMake args
set -euo pipefail

LLAMACPP_REF=${LLAMACPP_REF:-v1.0.0}
VULKAN_REF=${VULKAN_REF:-v1.4.368}
SPIRV_HEADERS_REF=${SPIRV_HEADERS_REF:-vulkan-sdk-1.4.363.0}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOOLCHAIN_FILE="$REPO_ROOT/ci/riscv64-linux-gnu.cmake"
WORK_DIR=$(realpath -m "${WORK_DIR:-$REPO_ROOT/build-riscv64}")
DIST_DIR=$(realpath -m "${DIST_DIR:-$REPO_ROOT/dist}")
JOBS=${JOBS:-$(nproc)}
SKIP_APT=${SKIP_APT:-0}

export RISCV64_SYSROOT=${RISCV64_SYSROOT:-/usr/riscv64-linux-gnu}
export RISCV64_STAGING_PREFIX="$WORK_DIR/staging"
SRC_DIR="$WORK_DIR/src"

PKG_NAME=llamacpp-riscv64-unmatched
PKG_DIR="$DIST_DIR/$PKG_NAME"
TARBALL="$DIST_DIR/$PKG_NAME.tar.gz"
LLAMA_BINS=(llama-cli llama-server llama-quantize llama-bench)

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

install_host_deps() {
  [[ $SKIP_APT == 1 ]] && return
  log "Installing host dependencies"
  local sudo=""
  [[ $(id -u) -ne 0 ]] && sudo=sudo
  $sudo apt-get update
  # glslc runs on the host to compile the Vulkan shaders at build time. On
  # Ubuntu the glslc binary is in the "glslc" package (built from shaderc).
  DEBIAN_FRONTEND=noninteractive $sudo apt-get install -y --no-install-recommends \
    gcc-riscv64-linux-gnu g++-riscv64-linux-gnu cmake ninja-build \
    glslang-tools libshaderc-dev glslc git python3 \
    build-essential pkg-config file ca-certificates
}

# fetch <url> <tag> <dir>: shallow clone of a pinned tag
fetch() {
  local url=$1 ref=$2 dir=$3
  if [[ -d $dir/.git ]]; then
    [[ $(git -C "$dir" describe --tags --exact-match 2>/dev/null) == "$ref" ]] && return
    rm -rf "$dir"
  fi
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$url" "$dir"
}

# cmake_cross <src> <build> [extra args...]: configure + build + install into staging
cmake_cross() {
  local src=$1 build=$2; shift 2
  cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$RISCV64_STAGING_PREFIX" \
    -DCMAKE_PREFIX_PATH="$RISCV64_STAGING_PREFIX" \
    "$@"
  cmake --build "$build" -j "$JOBS"
  cmake --install "$build"
}

build_vulkan_deps() {
  log "Cross-building Vulkan-Headers, SPIRV-Headers and Vulkan-Loader ($VULKAN_REF)"
  fetch https://github.com/KhronosGroup/Vulkan-Headers.git "$VULKAN_REF" "$SRC_DIR/Vulkan-Headers"
  fetch https://github.com/KhronosGroup/SPIRV-Headers.git "$SPIRV_HEADERS_REF" "$SRC_DIR/SPIRV-Headers"
  fetch https://github.com/KhronosGroup/Vulkan-Loader.git "$VULKAN_REF" "$SRC_DIR/Vulkan-Loader"

  cmake_cross "$SRC_DIR/Vulkan-Headers" "$WORK_DIR/build/Vulkan-Headers"
  # ggml-vulkan needs SPIRV-Headers' CMake package; header-only.
  cmake_cross "$SRC_DIR/SPIRV-Headers" "$WORK_DIR/build/SPIRV-Headers" \
    -DSPIRV_HEADERS_ENABLE_TESTS=OFF -DSPIRV_HEADERS_ENABLE_INSTALL=ON
  # Headless loader: llama.cpp only uses compute queues, so no X11/Wayland
  # WSI (which would also need riscv64 X11/Wayland dev packages). The loader
  # has no riscv64 assembly trampolines; it uses its C fallback.
  cmake_cross "$SRC_DIR/Vulkan-Loader" "$WORK_DIR/build/Vulkan-Loader" \
    -DBUILD_TESTS=OFF -DUSE_GAS=OFF \
    -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF \
    -DBUILD_WSI_XLIB_XRANDR_SUPPORT=OFF -DBUILD_WSI_WAYLAND_SUPPORT=OFF

  [[ -e $RISCV64_STAGING_PREFIX/lib/libvulkan.so.1 ]] || die "Vulkan-Loader did not produce libvulkan.so.1"
}

build_llamacpp() {
  log "Cross-building llama.cpp $LLAMACPP_REF (GGML_VULKAN=ON)"
  fetch https://github.com/ggml-org/llama.cpp.git "$LLAMACPP_REF" "$SRC_DIR/llama.cpp"

  local glslc extra_args
  read -ra extra_args <<<"${LLAMACPP_EXTRA_CMAKE_ARGS:-}"
  glslc=$(command -v glslc) || die "glslc not found on the host"

  # Fully static binaries are not possible with Vulkan: the loader is a
  # shared library that dlopen()s Mesa's RADV driver, which needs a dynamic
  # glibc. GGML_STATIC=ON + BUILD_SHARED_LIBS=OFF links ggml/llama statically
  # into each tool; with static libstdc++/libgcc and ggml's own thread pool
  # (no libgomp) the binaries only need libc, libm and libvulkan.so.1. No
  # RPATH is embedded so the build tree's staging path cannot leak.
  # The U74 is RV64GC + Zba/Zbb with no vector or half-float extensions, so
  # the CPU backend is built for -march=rv64gc_zba (ggml defaults to RVV).
  # Vulkan_* point FindVulkan at the cross-built loader/headers explicitly, so
  # the host's x86-64 libvulkan/headers can never be picked up.
  cmake -S "$SRC_DIR/llama.cpp" -B "$WORK_DIR/build/llama.cpp" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_PREFIX_PATH="$RISCV64_STAGING_PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_STATIC=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DGGML_OPENMP=OFF \
    -DCMAKE_SKIP_RPATH=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
    -DGGML_RVV=OFF -DGGML_RV_ZFH=OFF -DGGML_RV_ZVFH=OFF \
    -DGGML_RV_ZICBOP=OFF -DGGML_RV_ZIHINTPAUSE=OFF -DGGML_RV_ZBA=ON \
    -DVulkan_INCLUDE_DIR="$RISCV64_STAGING_PREFIX/include" \
    -DVulkan_LIBRARY="$RISCV64_STAGING_PREFIX/lib/libvulkan.so" \
    -DVulkan_GLSLC_EXECUTABLE="$glslc" \
    -DLLAMA_OPENSSL=OFF \
    "${extra_args[@]}"
  cmake --build "$WORK_DIR/build/llama.cpp" -j "$JOBS" --target "${LLAMA_BINS[@]}"
}

# Shared objects the binaries may depend on at runtime on the board.
ALLOWED_NEEDED='^(ld-linux-riscv64-lp64d\.so\.1|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libstdc\+\+\.so\.6|libgcc_s\.so\.1|libgomp\.so\.1|libvulkan\.so\.1|lib(ggml|llama|mtmd)[-a-z0-9_]*\.so(\.[0-9]+)*)$'

verify_elf() {
  local f=$1 desc needed bad
  desc=$(file -L "$f")
  echo "$desc"
  [[ $desc == *"ELF 64-bit LSB"*"UCB RISC-V"* ]] || die "$f is not a riscv64 ELF"

  local dyn
  dyn=$(riscv64-linux-gnu-readelf -d "$f")
  needed=$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn")
  echo "  NEEDED: $(tr '\n' ' ' <<<"$needed")"
  bad=$(grep -Ev "$ALLOWED_NEEDED" <<<"$needed" || true)
  [[ -z $bad ]] || die "$f has unexpected shared library dependencies: $bad"
  local rpath
  rpath=$(sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p' <<<"$dyn")
  # shellcheck disable=SC2016  # literal $ORIGIN
  [[ -z $rpath || $rpath == '$ORIGIN'* ]] || die "$f embeds a build-host RPATH: $rpath"
  if riscv64-linux-gnu-readelf -l "$f" | grep -q 'program interpreter'; then
    riscv64-linux-gnu-readelf -l "$f" | grep -q '/lib/ld-linux-riscv64-lp64d.so.1' \
      || die "$f uses an unexpected program interpreter"
  fi
}

verify() {
  log "Verifying riscv64 binaries"
  local bin_dir="$WORK_DIR/build/llama.cpp/bin" f
  for f in "${LLAMA_BINS[@]}"; do
    [[ -x $bin_dir/$f ]] || die "missing $bin_dir/$f"
    verify_elf "$bin_dir/$f"
  done
  for f in "$bin_dir"/lib{ggml,llama,mtmd}*.so; do
    [[ -e $f ]] && verify_elf "$f"
  done
  verify_elf "$RISCV64_STAGING_PREFIX/lib/libvulkan.so.1"
}

package() {
  log "Packaging $TARBALL"
  local bin_dir="$WORK_DIR/build/llama.cpp/bin" f
  rm -rf "$PKG_DIR" "$TARBALL"
  mkdir -p "$PKG_DIR/bin" "$PKG_DIR/lib/vulkan-fallback"

  for f in "${LLAMA_BINS[@]}"; do
    riscv64-linux-gnu-strip --strip-unneeded -o "$PKG_DIR/bin/$f" "$bin_dir/$f"
  done
  # Only present when built with BUILD_SHARED_LIBS=ON.
  for f in "$bin_dir"/lib{ggml,llama,mtmd}*.so*; do
    [[ -e $f ]] && cp -a "$f" "$PKG_DIR/lib/"
  done
  cp -L "$RISCV64_STAGING_PREFIX/lib/libvulkan.so.1" "$PKG_DIR/lib/vulkan-fallback/"
  riscv64-linux-gnu-strip --strip-unneeded "$PKG_DIR/lib/vulkan-fallback/libvulkan.so.1"

  install -m 0755 "$REPO_ROOT/ci/unmatched-install.sh" "$PKG_DIR/install.sh"
  # shellcheck disable=SC1091
  cat >"$PKG_DIR/BUILD-INFO" <<INFO
llama.cpp      $LLAMACPP_REF ($(git -C "$SRC_DIR/llama.cpp" rev-parse --short HEAD))
Vulkan-Loader  $VULKAN_REF
target         riscv64 Linux glibc, -march=rv64gc_zba (SiFive U74, HiFive Unmatched)
backends       CPU + Vulkan
compiler       $(riscv64-linux-gnu-gcc --version | head -1)
glslc          $(glslc --version 2>&1 | head -1)
host           $(. /etc/os-release && echo "$PRETTY_NAME")
INFO

  tar -C "$DIST_DIR" -czf "$TARBALL" "$PKG_NAME"
  tar -tzvf "$TARBALL"
}

main() {
  install_host_deps
  mkdir -p "$SRC_DIR" "$RISCV64_STAGING_PREFIX"
  build_vulkan_deps
  build_llamacpp
  verify
  package
}

main "$@"
