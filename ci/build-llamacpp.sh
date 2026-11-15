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
#   RISCV64_MARCH     -march for all code             (default rv64gc, the U74 ISA)
#   WORK_DIR          sources + build trees           (default ./build-riscv64)
#   DIST_DIR          output directory                (default ./dist)
#   JOBS              parallel build jobs             (default nproc)
#   GLIBC_MAX         newest glibc symbol version allowed (default 2.39, Ubuntu 24.04)
#   GLIBCXX_MAX       newest libstdc++ symbol version allowed (default 3.4.33, Ubuntu 24.04)
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
GLIBC_MAX=${GLIBC_MAX:-2.39}
GLIBCXX_MAX=${GLIBCXX_MAX:-3.4.33}

export RISCV64_SYSROOT=${RISCV64_SYSROOT:-/usr/riscv64-linux-gnu}
export RISCV64_STAGING_PREFIX="$WORK_DIR/staging"
export RISCV64_MARCH=${RISCV64_MARCH:-rv64gc}
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

# ISA extensions the FU740's U74 cores implement (RV64GC). zca/zcd are the
# C extension split out; zmmul/zaamo/zalrsc are subsets of M/A.
ALLOWED_ISA_EXTS=' i m a f d c zicsr zifencei zmmul zaamo zalrsc zca zcd '

# check_isa <elf>: the ELF's merged Tag_RISCV_arch must stay within RV64GC.
# The linker merges the attribute of every input object, including the
# toolchain's static libstdc++/libgcc/crt objects, so this also catches a
# toolchain whose runtime libraries were built for a newer profile (RVA23).
check_isa() {
  local f=$1 arch ext exts bad=()
  arch=$(riscv64-linux-gnu-readelf -A "$f" | sed -n 's/.*Tag_RISCV_arch: "\(.*\)"/\1/p')
  [[ -n $arch ]] || die "$f has no Tag_RISCV_arch attribute; cannot verify its ISA"
  echo "  ISA: $arch"
  IFS=_ read -ra exts <<<"${arch#rv64}"
  for ext in "${exts[@]}"; do
    ext=$(sed -E 's/[0-9]+p[0-9]+$//' <<<"$ext")
    [[ $ALLOWED_ISA_EXTS == *" $ext "* ]] || bad+=("$ext")
  done
  ((${#bad[@]} == 0)) || die "$f uses ISA extensions the U74 lacks: ${bad[*]}"
}

# check_symver <elf> <prefix> <max>: no <prefix>_x.y symbol versions newer
# than the board's (GLIBC from libc, GLIBCXX from libstdc++).
check_symver() {
  local f=$1 pfx=$2 max=$3 newest
  newest=$(riscv64-linux-gnu-readelf -V "$f" | { grep -o "${pfx}_[0-9][0-9.]*" || true; } | sed "s/${pfx}_//" | sort -uV | tail -1)
  echo "  newest $pfx symbol: ${newest:-none}"
  [[ -z $newest || $(printf '%s\n' "$newest" "$max" | sort -V | tail -1) == "$max" ]] \
    || die "$f needs ${pfx}_$newest, newer than the board's $max"
}

# Fail fast if the cross toolchain's own static runtime (libstdc++, libgcc,
# crt) uses extensions the U74 lacks, e.g. Ubuntu 25.10+'s RVA23 toolchain.
preflight_toolchain() {
  log "Checking that the cross toolchain can target $RISCV64_MARCH"
  local probe="$WORK_DIR/isa-probe"
  printf '#include <iostream>\n#include <string>\nint main(int c, char**) { std::string s(c, 42); std::cout << s << std::endl; }\n' \
    | riscv64-linux-gnu-g++ -x c++ -O2 -march="$RISCV64_MARCH" -mabi=lp64d \
        -static-libstdc++ -static-libgcc -o "$probe" - \
    || die "riscv64-linux-gnu-g++ cannot build for -march=$RISCV64_MARCH"
  riscv64-linux-gnu-g++ --version | head -1
  ( check_isa "$probe" ) \
    || die "the cross toolchain's runtime libraries are built for a newer RISC-V profile than the U74 supports; build on Ubuntu 24.04"
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
  # into each tool, with ggml's own thread pool (no libgomp).
  # libstdc++/libgcc stay shared: Mesa's drivers (via LLVM) load the system
  # libstdc++.so.6, and a second static copy exported from the executable
  # interposes on it and aborts with "free(): invalid pointer" as soon as the
  # Vulkan loader opens a driver. No RPATH is embedded so the build tree's
  # staging path cannot leak.
  # The Unmatched's FU740 U74 cores are plain RV64GC (no vector, half-float
  # or bitmanip extensions). The toolchain file sets -march=rv64gc for all
  # code; the GGML_RV* switches stop ggml-cpu from adding RVV & co.
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
    -DCMAKE_EXE_LINKER_FLAGS="" \
    -DGGML_RVV=OFF -DGGML_RV_ZFH=OFF -DGGML_RV_ZVFH=OFF \
    -DGGML_RV_ZICBOP=OFF -DGGML_RV_ZIHINTPAUSE=OFF -DGGML_RV_ZBA=OFF \
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
  # A static libstdc++ in the tool hijacks Mesa's shared one (see build_llamacpp).
  ! riscv64-linux-gnu-nm -D --defined-only "$f" | grep -qE ' _ZNSt9basic_iosIcSt11char_traitsIcEE4init|_ZNSt6locale5_Impl' \
    || die "$f contains a static libstdc++; Mesa's Vulkan drivers would crash it"
  check_isa "$f"
  check_symver "$f" GLIBC "$GLIBC_MAX"
  check_symver "$f" GLIBCXX "$GLIBCXX_MAX"
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
target         riscv64 Linux glibc >= $GLIBC_MAX, libstdc++ >= GLIBCXX_$GLIBCXX_MAX, -march=$RISCV64_MARCH (SiFive U74, HiFive Unmatched)
isa            $(riscv64-linux-gnu-readelf -A "$PKG_DIR/bin/llama-cli" | sed -n 's/.*Tag_RISCV_arch: "\(.*\)"/\1/p')
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
  preflight_toolchain
  build_vulkan_deps
  build_llamacpp
  verify
  package
}

main "$@"
