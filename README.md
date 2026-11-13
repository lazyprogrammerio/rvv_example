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
