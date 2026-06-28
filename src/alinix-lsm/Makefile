# SPDX-License-Identifier: GPL-2.0
#
# Makefile — Módulo Rust alinix-lsm (root limiter)
#
# Uso (dentro da árvore do kernel):
#   make M=src/alinix-lsm modules
#
# Ou via build.sh:
#   ./build.sh rust-module

obj-m := alinix_lsm.o

# Flags para compilação Rust
KBUILD_HOSTCFLAGS += -I$(src)
KBUILD_RUSTFLAGS += -C debuginfo=0 -C opt-level=3

all:
	$(MAKE) -C "$(KERNEL_DIR)" M="$(PWD)" modules

clean:
	$(MAKE) -C "$(KERNEL_DIR)" M="$(PWD)" clean
	rm -f *.o *.ko *.mod* .*.cmd *.symvers Module.symvers modules.order

.PHONY: all clean
