# Kernel-Lix

**Autor:** Jefferson Silva de Souza Rios

---

## O que é o Kernel-Lix?

O Kernel-Lix é um kernel Linux personalizado, com suporte nativo a Rust, otimizado para desktops x86\_64 e enriquecido com o **Alinix Root Limiter** — um LSM (*Linux Security Module*) escrito em Rust que restringe operações sensíveis do superusuário até que uma chave de autenticação seja fornecida.

O sufixo **-lix** aparece na versão do kernel (`uname -r` retorna algo como `7.1.2-lix`) e é uma abreviação de **Alinix**.

---

## A origem do nome: Alinix

**Alinix** é uma palavra criada pela junção de dois nomes:

- **Aline** — minha esposa, a quem este projeto é dedicado com carinho.
- **Unix** — a família de sistemas operacionais que inspira o Linux e tudo que o rodeia.

**Alinix = Aline + Unix.**

O kernel recebeu o sufixo **-lix** como uma forma compacta e sonora de carregar esse nome em cada versão compilada.

---

## Funcionalidades

| Recurso | Descrição |
|---|---|
| **Rust no kernel** | `CONFIG_RUST=y` — suporte nativo a módulos Rust |
| **Alinix LSM** | Root Limiter em Rust via `/dev/alinix-auth` |
| **Otimizado para desktop** | Preempção total (`PREEMPT=y`), HZ=1000, P-State Intel |
| **Hardware alvo** | Qualquer CPU Intel x86_64, GPU Intel/AMD como módulo |
| **Virtualização** | VirtIO GPU, VMSVGA — funciona em QEMU/VirtualBox |
| **Hardening** | KASLR, PTI, STACKPROTECTOR\_STRONG, SLAB hardening |
| **BPF** | LSM BPF, JIT always-on, eBPF não-privilegiado desabilitado |

---

## Como o Alinix Root Limiter funciona

O LSM é composto por duas partes:

1. **Patch C no kernel** (`kernel/alinix.c` + `security/commoncap.c`) — intercepta chamadas de capability (`CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, `CAP_NET_ADMIN`, etc.) e bloqueia o UID 0 caso ele não esteja autenticado e uma chave já tenha sido definida.

2. **Módulo externo Rust** (`src/alinix-lsm/alinix_lsm.rs`) — expõe `/dev/alinix-auth`, aceita o comando `set_key <hex>` para ativar o limiter e `auth_uid <uid>` para liberar um processo.

Enquanto nenhuma chave for definida, o kernel se comporta normalmente — o root tem acesso irrestrito, evitando tela preta no boot antes de o servidor gráfico autenticar.

---

## Estrutura do projeto

```
Kernel-Lix/
├── build.sh                  # Script principal de build
├── put-on-my-host.sh         # Instala o kernel compilado no host
├── kernel.config.fragment    # Fragmento de configuração Alinix
├── patches/
│   └── 0001-alinix-core.patch
├── src/
│   └── alinix-lsm/
│       ├── alinix_lsm.rs     # Módulo Rust do Root Limiter
│       └── Makefile
├── scripts/
│   └── setup-fhs.sh
└── dist/                     # Artefatos publicados após o build
    ├── vmlinuz-<kver>-lix
    ├── initrd-<kver>-lix.img
    ├── System.map-<kver>-lix
    └── config-<kver>-lix
```

---

## Compilando

```bash
# Build completo (baixa fonte, aplica patches, compila kernel + módulo Rust)
./build.sh build

# Escolher versão do kernel base
./build.sh build          # seleciona interativamente (6.18.10 ou 7.1.2)
KERNEL_VERSION=7.1.2 ./build.sh build

# Recompilar sem re-baixar
./build.sh rebuild

# Build + instalação + FHS
./build.sh full
```

Os artefatos finais são publicados em `dist/` com o sufixo `-lix`.

---

## Instalando no host

```bash
# Usa os artefatos de dist/ automaticamente (não precisa recompilar)
sudo ./put-on-my-host.sh

# Forçar recompilação antes de instalar
sudo ./put-on-my-host.sh --rebuild

# Especificar versão
sudo ./put-on-my-host.sh --version=7.1.2
```

O script instala o kernel em `/boot`, gera o initramfs, configura uma entrada no GRUB chamada **"Zorin OS, com Kernel Lix"** e mantém o kernel padrão do sistema intacto (`GRUB_DEFAULT=0`).

---

## Dependências

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

## Versões suportadas do kernel base

| Versão | Status |
|---|---|
| 6.18.10 | Estável (padrão) |
| 7.1.2 | Suportado |

---

## Licença

Os patches e módulos originais deste projeto são distribuídos sob **GPL-2.0-only**, compatível com o kernel Linux.
