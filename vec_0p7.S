    # void vec_len_rvv(float *r, struct pt *pts, int n)
    #
    # RVV 0.7.1 (T-Head XTheadVector) port of vec.S for the C910 cores in
    # the Lichee Pi 4A (TH1520). Upstream GCC/binutils spell these
    # instructions with a "th." prefix under -march=..._xtheadvector;
    # T-Head's own toolchain fork (-march=rv64gcv0p7) uses bare mnemonics.

    #ifdef __riscv_xtheadvector
    #define TH(op) th.op
    #else
    #define TH(op) op
    #endif

    #define r a0
    #define pts a1
    #define n a2
    #define vl a3
    #define rstep t0
    #define pstep t1
    #define Xs v0
    #define Ys v1
    #define Zs v2
    #define lens v3
    #define sq v4

    .globl vec_len_rvv
vec_len_rvv:
    # 32 bit elements; 0.7.1 has no tail/mask policy flags
    TH(vsetvli) vl, n, e32
    TH(vlseg3e.v) Xs, (pts) # loads interleaved Xs, Ys, Zs into 3 registers (SEW-wide)
    TH(vfmul.vv) lens, Xs, Xs
    TH(vfmul.vv) sq, Ys, Ys
    TH(vfadd.vv) lens, lens, sq
    TH(vfmul.vv) sq, Zs, Zs
    TH(vfadd.vv) lens, lens, sq
    TH(vfsqrt.v) lens, lens
    TH(vse.v) lens, (r) # SEW-wide store
    sub n, n, vl
    # no Zba on C910: shift-and-add by hand
    slli rstep, vl, 2 # 4 bytes per float
    add r, r, rstep
    slli pstep, rstep, 1 # 8 * vl
    add pstep, pstep, rstep # 12 bytes per point
    add pts, pts, pstep
    bnez n, vec_len_rvv
    ret
