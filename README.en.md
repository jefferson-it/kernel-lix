# Kernel-Lix

**Author:** Jefferson Silva de Souza Rios

---

## What is Kernel-Lix?

Kernel-Lix is a custom Linux kernel with native Rust support, optimized for x86\_64 desktops and enriched with the **Alinix Root Limiter** — a Linux Security Module (LSM) written in Rust that restricts sensitive superuser operations until an authentication key is provided.

The **-lix** suffix appears in the kernel version string (`uname -r` returns something like `7.1.2-lix`) and is a short form of **Alinix**.

---

## The name: Alinix

**Alinix** is a word crafted by combining two names:

- **Aline** — my wife, to whom this project is lovingly dedicated.
- **Unix** — the family of operating systems that inspired Linux and everything around it.

**Alinix = Aline + Unix.**

The kernel carries the **-lix** suffix as a compact, sonorous way to embed that name in every compiled version.

---

## Features

| Feature | Description |
|---|---|
| **Rust in the kernel** | `CONFIG_RUST=y` — native Rust module support |
| **Alinix LSM** | Root Limiter in Rust via `/dev/alinix-auth` |
| **Desktop-optimized** | Full preemption (`PREEMPT=y`), HZ=1000, Intel P-State |
| **Target hardware** | Any Intel x86_64 CPU, Intel/AMD GPU as modules |
| **Virtualization** | VirtIO GPU, VMSVGA — works under QEMU/VirtualBox |
| **Hardening** | KASLR, PTI, STACKPROTECTOR\_STRONG, SLAB hardening |
| **BPF** | LSM BPF, JIT always-on, unprivileged eBPF disabled |

---

## How the Alinix Root Limiter works

The LSM is made up of two parts:

1. **C patch in the kernel** (`kernel/alinix.c` + `security/commoncap.c`) — intercepts capability checks (`CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, `CAP_NET_ADMIN`, etc.) and blocks UID 0 if it is not authenticated and a key has already been set.

2. **External Rust module** (`src/alinix-lsm/alinix_lsm.rs`) — exposes `/dev/alinix-auth`, accepts the command `set_key <hex>` to activate the limiter and `auth_uid <uid>` to grant access to a process.

As long as no key has been defined, the kernel behaves normally — root has unrestricted access, preventing a black screen at boot before the display server has authenticated.

---

## Project structure

```
Kernel-Lix/
├── build.sh                  # Main build script
├── put-on-my-host.sh         # Installs the compiled kernel on the host
├── kernel.config.fragment    # Alinix configuration fragment
├── patches/
│   └── 0001-alinix-core.patch
├── src/
│   └── alinix-lsm/
│       ├── alinix_lsm.rs     # Root Limiter Rust module
│       └── Makefile
├── scripts/
│   └── setup-fhs.sh
└── dist/                     # Published artifacts after build
    ├── vmlinuz-<kver>-lix
    ├── initrd-<kver>-lix.img
    ├── System.map-<kver>-lix
    └── config-<kver>-lix
```

---

## Building

```bash
# Full build (downloads source, applies patches, compiles kernel + Rust module)
./build.sh build

# Choose the base kernel version
./build.sh build          # interactive selection (6.18.10 or 7.1.2)
KERNEL_VERSION=7.1.2 ./build.sh build

# Rebuild without re-downloading
./build.sh rebuild

# Build + install + FHS
./build.sh full
```

Final artifacts are published in `dist/` with the `-lix` suffix.

---

## Installing on the host

```bash
# Uses dist/ artifacts automatically (no recompilation needed)
sudo ./put-on-my-host.sh

# Force recompilation before installing
sudo ./put-on-my-host.sh --rebuild

# Specify version
sudo ./put-on-my-host.sh --version=7.1.2
```

The script installs the kernel in `/boot`, generates the initramfs, adds a GRUB entry called **"Zorin OS, com Kernel Lix"**, and leaves the system default kernel untouched (`GRUB_DEFAULT=0`).

---

## Dependencies

```bash
# Debian/Ubuntu
sudo apt-get install -y wget xz-utils patch bc bison flex gcc make \
  python3 rsync libelf-dev libssl-dev dwarves pahole

# Rust toolchain
curl https://sh.rustup.rs -sSf | sh
rustup component add rust-src rustfmt
cargo install bindgen-cli
```

---

## Supported base kernel versions

| Version | Status |
|---|---|
| 6.18.10 | Stable (default) |
| 7.1.2 | Supported |

---

## License

The original patches and modules in this project are distributed under **GPL-2.0-only**, compatible with the Linux kernel.
