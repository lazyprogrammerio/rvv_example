Simple RISC-V Vector example
============================

This is an example of writing the same vector processing function in C
and in assembly language for the RISC-V Vector extension, and comparing
the results. There are two assembly versions of `vec_len_rvv`:

* `vec.S` — ratified RVV 1.0 (+ Zba), e.g. Banana Pi F3
* `vec_0p7.S` — RVV 0.7.1 draft (T-Head XTheadVector), e.g. Lichee Pi 4A

Both export the same `vec_len_rvv` symbol and signature, so `main.c` is shared.

By default the generated program is run in qemu, but another emulator such
as Spike could also be used, or run on real RVV-capable hardware if you have
it.

### Getting the toolchain

I'm using the "embedded" toolchain which uses the Newlib C library and statically
links all needed libraries into the main program. This is more convenient for
running on emulators or downloading to a microcontroller-style boars, but will
also work on a native RISC-V Linux system.

Your favourite software repository might have a recent enough RISC-V toolchain,
but maybe not as the B and V extensions are still quite new as I write this.

Check out the latest version from https://github.com/riscv-collab/riscv-gnu-toolchain

Support for B and V extensions are already included in master branch.

Follow the instructions there, or copy what I use:

    # first install any neccessary packages for your OS, then....
    git clone https://github.com/riscv-collab/riscv-gnu-toolchain.git --recursive
    cd riscv-gnu-toolchain
    ./configure 
    make
    make build-qemu

Notes:

The instructions say you don't need recursive, but I find it more convenient
to get everything at one time so the build itself is faster.

Unusually, there is no "make install" step, so you need write permissions for the installation
location, or run "make" with sudo (ugh)

As always, add --prefix=<path> to ./configure if you don't want the RISC-V toolchain in /usr/local

By default you will get libraries for rv64gc only. If you want a good set of libraries so you
can experiment with rv32i, rv64i or other reduced configurations then add "--enable-multilib"
to the ./configure.

### Building for a board

The two vector ISAs are encoded differently, so the binaries are **not
cross-compatible**: an RVV 1.0 binary will not run correctly on the C910, and an
RVV 0.7.1 binary will not run on RVV 1.0 hardware. Build on (or for) the board you
will run on. Both targets write `./main`.

| Target          | Board                          | Vector ISA                | Source      | `-march`                |
|-----------------|--------------------------------|---------------------------|-------------|-------------------------|
| `make bananapi` | Banana Pi F3 (SpacemiT K1)     | RVV 1.0, VLEN=256, + Zba  | `vec.S`     | `rv64gcv_zba`           |
| `make licheepi` | Lichee Pi 4A (T-Head TH1520)   | RVV 0.7.1 draft (C910)    | `vec_0p7.S` | `rv64gc_xtheadvector`   |

The compiler defaults to `riscv64-linux-gnu-gcc`; override the prefix with
`CROSS`, e.g. `make licheepi CROSS=riscv64-unknown-linux-gnu-`.

`make clean` removes `./main`.

### CI

`.github/workflows/build.yml` has one job per board. Each job builds with the
make target above and runs `ci/check.c` (which compares `vec_len_rvv` with a
scalar reference) under QEMU. `bananapi` uses Ubuntu's QEMU at vlen=128 and
vlen=256. `licheepi` uses T-Head's XuanTie QEMU fork (`-cpu c910v`).

#### `make licheepi` toolchain requirements

`-march=rv64gc_xtheadvector` needs GCC 14+ with a matching binutils (2.42+).
Older distro toolchains (e.g. Ubuntu 22.04's GCC 11 / binutils 2.38) reject it.
On Ubuntu 24.04, install `gcc-14-riscv64-linux-gnu` and run
`make licheepi CC_RV=riscv64-linux-gnu-gcc-14`.
Upstream binutils spells the 0.7.1 instructions with a `th.` prefix
(`th.vsetvli`, `th.vlseg3e.v`, `th.vse.v`, ...); `vec_0p7.S` adds the prefix
automatically when `__riscv_xtheadvector` is defined.

If your toolchain lacks XTheadVector, the alternative is T-Head's toolchain fork
(Xuantie GNU toolchain) with `-march=rv64gcv0p7`, which uses the unprefixed 0.7.1
mnemonics:

    riscv64-unknown-linux-gnu-gcc -O main.c vec_0p7.S -o main -march=rv64gcv0p7 -lm

Notable differences from `vec.S`: no `ta,ma` policy flags on `vsetvli`, SEW-sized
`vlseg3e.v`/`vse.v` instead of `vlseg3e32.v`/`vse32.v`, and no Zba on the C910
(`sh1add`/`sh2add` become `slli` + `add`).

### Running under QEMU

    make go

builds the RVV 1.0 (`bananapi`) binary and runs it in QEMU with `vlen=128`.
This needs a QEMU recent enough to support RVV 1.0 and the
`rvv_ta_all_1s`/`rvv_ma_all_1s` options (Ubuntu 22.04's QEMU 6.2 is too old). Upstream QEMU does not emulate
the RVV 0.7.1 draft. Point `QEMU` at a different binary if needed, e.g.
`make go QEMU="/path/to/qemu-riscv64 -L /usr/riscv64-linux-gnu"` for a
glibc-linked build.

Expected output (timings will vary):

    $ make
    riscv64-linux-gnu-gcc -O main.c vec.S -o main -march=rv64gcv_zba -lm
    qemu-riscv64 -cpu rv64,v=true,zba=true,vlen=128,rvv_ta_all_1s=on,rvv_ma_all_1s=on ./main
    now: 2026-11-13 18:06:53
    time taken for C implementation: 0.013043
    time taken for vector implementation: 0.007188

You can trace the qemu execution by adding "-singlestep -d nochain,cpu" to the qemu command line.
Cross-reference instruction addresses with the output from "riscv64-linux-gnu-objdump -d main".

### Performance under QEMU

QEMU checks correctness, not speed. Its timings do not predict how fast the
code runs on the boards, and under emulation the vector version is often the
slower one. The C-vs-vector ranking can flip with the compiler and QEMU build,
even when the vector code is unchanged.

These are the best of 10 runs over 100,000 points, measured on an x86-64 host
with QEMU linux-user:

| Emulator                             | Compiler for the C side | C       | Vector  |
|--------------------------------------|-------------------------|---------|---------|
| Ubuntu QEMU 8.2, vlen=256            | GCC 11                  | 5.8 ms  | 3.0 ms  |
| Ubuntu QEMU 8.2, vlen=256            | GCC 16                  | 2.0 ms  | 3.0 ms  |
| XuanTie QEMU, vlen=256               | GCC 11                  | 12.5 ms | 4.7 ms  |
| XuanTie QEMU, vlen=256               | GCC 16                  | 2.2 ms  | 4.7 ms  |
| XuanTie QEMU, `c910v` (`vec_0p7.S`)  | GCC 16                  | 2.2 ms  | 5.4 ms  |

Why this happens:

* QEMU runs each vector instruction through a software helper that loops over
  the elements one at a time. Segmented loads such as `vlseg3` are especially
  costly. Scalar float instructions are translated into much faster host code.
  So under emulation, vector code often loses even where it would win on
  hardware.
* The C side depends on the compiler. GCC 11 surrounds each `sqrtf` with
  `frflags`/`fsflags` for its errno check, and QEMU emulates those slowly.
  GCC 13+ does not emit them, so its scalar loop runs about 5x faster under
  QEMU. CI uses Ubuntu 24.04's GCC 13/14, which is why the vector version looks
  slower there.
* First-touch page faults on the output arrays add only a little, and in
  `main.c` both versions pay that cost.

On the boards, VLEN=256 on the Banana Pi F3 processes 8 floats per instruction,
so `vec.S` is expected to beat the scalar loop. On the C910 (VLEN=128, 4 floats)
the margin is less certain, since segmented loads are slow on some
implementations. Neither has been measured here. To get real numbers, run
`./main` on the board, ideally repeating each version several times.

### llama.cpp on HiFive Unmatched + RX 580

`.github/workflows/cross-build.yml` cross-builds [llama.cpp](https://github.com/ggml-org/llama.cpp)
with the Vulkan backend for the SiFive HiFive Unmatched (riscv64, Ubuntu 26.04)
with an AMD RX 580 driven by `amdgpu` + Mesa RADV. Everything is built on an
x86-64 runner; nothing is compiled on the board. This is separate from the
RVV benchmark above (the U74 cores have no vector unit) and does not touch
the `make` targets.

What the build does (`ci/build-llamacpp.sh`, toolchain in `ci/riscv64-linux-gnu.cmake`):

* Cross-builds Khronos Vulkan-Headers, SPIRV-Headers and a headless
  Vulkan-Loader (`libvulkan.so.1`) into a staging prefix, and points
  llama.cpp's `Vulkan_INCLUDE_DIR`/`Vulkan_LIBRARY` at it so no host x86-64
  Vulkan libraries are used.
* Builds llama.cpp (pinned tag) with `GGML_VULKAN=ON`, `GGML_NATIVE=OFF`,
  `GGML_STATIC=ON`, CPU code for `-march=rv64gc_zba` (no RVV), and compiles the
  Vulkan shaders with the host's `glslc`.
* Checks with `file` and `riscv64-linux-gnu-readelf -d` that every binary is
  riscv64 and only needs `libc`, `libm` and `libvulkan.so.1`.
* Produces `dist/llamacpp-riscv64-unmatched.tar.gz` with `llama-cli`,
  `llama-server`, `llama-quantize`, `llama-bench`, a fallback `libvulkan.so.1`
  and `install.sh`.

The binaries are not fully static. The Vulkan loader must be a shared library
because it `dlopen()`s Mesa's RADV driver. ggml and llama are linked statically
into each tool, along with libstdc++ and libgcc.

To rebuild locally on an x86-64 Ubuntu 24.04+ host: `ci/build-llamacpp.sh`
(override `LLAMACPP_REF`, `VULKAN_REF`, `WORK_DIR`, `DIST_DIR` as needed).

#### Install on the board

1. Download the tarball: either the `llamacpp-riscv64-unmatched` artifact from
   a [cross-build-llamacpp](https://github.com/lazyprogrammerio/rvv_example/actions/workflows/cross-build.yml) run, or the
   asset of a GitHub Release (pushing a `v*` tag publishes one).
2. Install:

       tar -xzf llamacpp-riscv64-unmatched.tar.gz
       cd llamacpp-riscv64-unmatched
       sudo ./install.sh

   This copies the tools to `/usr/local/bin` and runs `ldconfig`. The bundled
   `libvulkan.so.1` is installed to `/usr/local/lib` only if the system has no
   Vulkan loader (normally Mesa's `libvulkan1` provides it).
3. Check that RADV sees the card (`vulkaninfo` is in `vulkan-tools`):

       vulkaninfo --summary

   The device list should show the RX 580 as a `RADV POLARIS...` device
   with `driverID = DRIVER_ID_MESA_RADV`. If only `llvmpipe` appears, the
   amdgpu/RADV setup is not working, and llama.cpp will not use the GPU.
4. Run with all layers offloaded to the GPU:

       llama-cli -m model.gguf -ngl 99

   At startup llama.cpp should log `ggml_vulkan: Found 1 Vulkan devices`
   followed by the RX 580.

Caveats:

* **PCIe Gen2 x8.** The Unmatched's PCIe slot runs at Gen2 x8, about 4 GB/s,
  while the RX 580 supports Gen3 x16. Loading the model and offloading layers is slow, and
  any layers left on the CPU make every token cross the bus. Use a model
  that fits in the card's 4/8 GB of VRAM and keep `-ngl 99`.
* **U74 CPU.** Four in-order 1.2 GHz cores with no vector extension. Tokenizing,
  sampling and any layers not offloaded run here, so CPU-only inference is
  very slow. Set `-t 4`.
* CI cannot test the GPU. The smoke-test job only runs `llama-cli --version`
  under `qemu-riscv64`, so GPU inference has to be checked on the board.
* The runner's `glslc` may not support some newer shader extensions
  (cooperative matrix, bfloat16, integer dot product). Those shader
  variants are skipped at build time. Polaris does not support the
  cooperative-matrix paths anyway.
