#!/bin/sh
# Installs the cross-built llama.cpp (Vulkan) tools on the HiFive Unmatched.
# Run from the extracted tarball:  sudo ./install.sh   (PREFIX=/usr/local)
set -eu

PREFIX=${PREFIX:-/usr/local}
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(uname -m)" = riscv64 ] || { echo "error: this package is for riscv64 (got $(uname -m))" >&2; exit 1; }
# Root is needed for ldconfig and /etc/ld.so.conf.d, even for a writable PREFIX.
[ "$(id -u)" -eq 0 ] || { echo "error: run as root: sudo $0" >&2; exit 1; }

echo "Installing llama.cpp tools to $PREFIX/bin"
install -d "$PREFIX/bin" "$PREFIX/lib"
install -m 0755 "$HERE"/bin/* "$PREFIX/bin/"

# Shared ggml/llama libraries, only present in shared-library builds.
for lib in "$HERE"/lib/*.so*; do
  [ -e "$lib" ] || continue
  cp -a "$lib" "$PREFIX/lib/"
done

# Prefer the distro's Vulkan loader (libvulkan1, pulled in by Mesa); only
# install the bundled one if none is registered.
if ldconfig -p | grep -q 'libvulkan\.so\.1 '; then
  echo "System Vulkan loader found: $(ldconfig -p | grep 'libvulkan\.so\.1 ' | head -1 | sed 's/.*=> //')"
else
  echo "No system libvulkan.so.1; installing the bundled fallback loader to $PREFIX/lib"
  install -m 0644 "$HERE/lib/vulkan-fallback/libvulkan.so.1" "$PREFIX/lib/libvulkan.so.1"
fi

# The binaries carry no RPATH; make sure ld.so searches $PREFIX/lib.
case "$PREFIX" in
  /usr/local|/usr) ;;
  *) echo "$PREFIX/lib" > /etc/ld.so.conf.d/llamacpp-riscv64-unmatched.conf ;;
esac
ldconfig

if ldd "$PREFIX/bin/llama-cli" | grep 'not found'; then
  echo "error: llama-cli has unresolved libraries (see above)" >&2
  exit 1
fi
"$PREFIX/bin/llama-cli" --version
echo "Done. Check the GPU with: vulkaninfo --summary"
