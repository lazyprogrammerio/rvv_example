CROSS ?= riscv64-linux-gnu-
CC_RV := $(CROSS)gcc
QEMU ?= qemu-riscv64

.PHONY: go bananapi licheepi clean

# Build the RVV 1.0 binary and run it under QEMU
go: bananapi
	$(QEMU) -cpu rv64,v=true,zba=true,vlen=128,rvv_ta_all_1s=on,rvv_ma_all_1s=on ./main

# Banana Pi F3 (SpacemiT K1): ratified RVV 1.0 + Zba
bananapi: main.c vec.S makefile
	$(CC_RV) -O main.c vec.S -o main -march=rv64gcv_zba -lm

# Lichee Pi 4A (T-Head TH1520 / C910): RVV 0.7.1 draft via XTheadVector (GCC 14+)
licheepi: main.c vec_0p7.S makefile
	$(CC_RV) -O main.c vec_0p7.S -o main -march=rv64gc_xtheadvector -lm

clean:
	rm -f main
