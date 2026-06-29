# Kernel-Lix

Kernel Linux customizado para o Alinix — distribuição desktop x86_64 com Rust, LSM próprio e hierarquia de arquivos inspirada no macOS (ver [Alinix-FHS](../Alinix-Deb/plano/fhs.md)).

## O que tem aqui

- **Linux 6.18.10** compilado com suporte nativo a Rust
- **Alinix Root Limiter** — LSM + módulo Rust que restringe o root até uma chave ser fornecida
- Otimizações para processadores AMD Zen (64-bit / Ryzen & EPYC)
- Preempção desktop (`CONFIG_PREEMPT=y`, HZ=1000)
- Hardening completo (KASLR, KPTI, stack protector, Spectre/Meltdown mitigations)
- Integração com o initramfs Rust do JSR-OS (`alinix-init`)

---

## O que é o LSM (Linux Security Module)

O **LSM** é a camada de segurança do kernel Linux. Funciona como uma série de "ganchos" (_hooks_) que o kernel chama antes de executar operações sensíveis — montar um sistema de arquivos, carregar um módulo, abrir um socket raw, etc. Cada hook pode retornar `0` (permitido) ou `-EPERM` (negado).

Exemplos de LSMs que você conhece: **SELinux** (Android, RHEL), **AppArmor** (Ubuntu), **Yama**, **BPF LSM**. O Alinix usa um LSM próprio: o **Alinix Root Limiter**.

### Alinix Root Limiter

O problema que ele resolve: no Linux padrão, qualquer processo com UID 0 tem poder total — `CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, raw I/O, etc. Para um desktop com a [hierarquia Alinix](../Alinix-Deb/plano/fhs.md), isso é um problema porque caminhos como `/Exec`, `/Library/64` e `/Volumes` são symlinks/bind mounts sobre o FHS real — um root irrestrito pode desfazer toda essa camada sem aviso.

A solução é em duas camadas:

**Camada C** (`kernel/alinix.c` + hook em `security/commoncap.c`):
- Mantém um bitmap de UIDs autorizados
- Intercepta `cap_capable()` — a função central de verificação de capabilities
- Se o limitador estiver ativo e o UID 0 não estiver autorizado, bloqueia `CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, `CAP_SYS_RAWIO`, `CAP_SYS_BOOT`, `CAP_SYS_TIME`, `CAP_NET_ADMIN` e `CAP_LINUX_IMMUTABLE`

**Camada Rust** (`src/alinix-lsm/alinix_lsm.rs`):
- Módulo carregável (`alinix_lsm.ko`)
- Expõe `/dev/alinix-auth` como misc device
- Gerencia uma **chave mestra** armazenada como SHA-256: nunca a chave raw, sempre o hash
- Chama `alinix_set_uid_auth()` para autorizar ou desautorizar UIDs no bitmap do C core

A comparação de chave usa comparação byte-a-byte com OR acumulado para resistir a timing attacks.

### Por que isso importa para o FHS Alinix

A [hierarquia Alinix](../Alinix-Deb/plano/fhs.md) expõe `/Users`, `/Library`, `/Exec`, `/Volumes` e `/Progs` como "porta da frente" via symlinks e bind mounts sobre o FHS Unix padrão. Um root irrestrito poderia, por exemplo:

- Desmontar `/Volumes` (que é bind de `/mnt`) e expor o FHS nu
- Carregar módulos que reescrevem regras udev (quebrando automontagem em `/Volumes/<label>`)
- Modificar `/etc` diretamente (caminho FHS oculto do usuário comum, mas ainda operacional)

Com o Root Limiter ativo, mesmo um processo UID 0 sem a chave não consegue executar essas operações — o kernel retorna `-EPERM` antes de qualquer userspace ter chance de agir.

---

## Como desbloquear o root (tornar-se super user)

O desbloqueio é feito via `/dev/alinix-auth`. O fluxo completo:

### 1. Definir a chave mestra (uma vez, no primeiro boot ou setup)

A chave é um valor hexadecimal de **64 caracteres** (32 bytes = 256 bits). Escolha uma chave segura e guarde-a:

```sh
# Gere uma chave aleatória
KEY=$(openssl rand -hex 32)
echo "$KEY"   # guarde isso em local seguro

# Defina no kernel (só funciona se nenhuma chave ainda foi definida)
echo "set_key $KEY" > /dev/alinix-auth
```

Depois que a chave é definida, o limitador entra em ação automaticamente. A chave **não pode ser redefinida** sem reiniciar o kernel — o módulo rejeita um segundo `set_key` com `-EPERM`.

### 2. Autenticar para obter poderes de root

Em qualquer sessão posterior, para executar operações que exigem capabilities restritas:

```sh
echo "auth $SUA_CHAVE" > /dev/alinix-auth
```

Se a chave bater, seu UID é marcado como autorizado no bitmap do kernel. A partir daí, `sudo`, `su`, `mount`, `modprobe` e similares funcionam normalmente.

### 3. Revogar a autorização

```sh
echo "deauth" > /dev/alinix-auth
```

Seu UID volta ao estado restrito imediatamente.

### 4. Verificar o estado atual

```sh
cat /dev/alinix-auth
```

Saída esperada:

```
Alinix Root Limiter
Ativo:      sim
Chave:      definida
Seu UID:    1000
Autorizado: não
```

### Fluxo resumido

```
boot
 └─ alinix_lsm.ko carregado (limitador inativo, aguardando set_key)
     └─ set_key <64hex>  →  limitador ATIVO, UID 0 restrito
         └─ auth <64hex>  →  UID autorizado, root pleno
         └─ deauth        →  UID restrito novamente
```

---

## Build

```sh
# Dependências (Debian/Ubuntu)
sudo apt-get install -y wget xz-utils patch bc bison flex gcc make \
  python3 rsync libelf-dev libssl-dev dwarves pahole
rustup install stable && rustup component add rust-src rustfmt
cargo install bindgen-cli

# Build completo
./build.sh build

# Opções disponíveis
./build.sh menuconfig    # configuração interativa
./build.sh install       # instala kernel + módulos + atualiza GRUB
./build.sh initramfs     # compila initramfs Rust do JSR-OS
./build.sh full          # build → initramfs → install → FHS Alinix
./build.sh clean         # limpa tudo
```

O script se recusa a instalar em `/` de outra máquina — é seguro rodar do repositório.

---

## Estrutura

```
Kernel-Lix/
├── build.sh                  # script principal de build
├── kernel.config.fragment    # config Alinix aplicada sobre defconfig
├── src/
│   └── alinix-lsm/
│       └── alinix_lsm.rs     # módulo Rust: /dev/alinix-auth + gerência de chave
├── patches/
│   └── 0001-alinix-core.patch
├── scripts/
│   └── setup-fhs.sh          # aplica hierarquia Alinix no sistema instalado
└── linux-6.18.10/            # fonte do kernel (gerado pelo build.sh)
    ├── kernel/alinix.c       # C core: bitmap de UIDs + hook cap_capable()
    ├── include/linux/alinix.h
    └── security/commoncap.c  # hook injetado pelo patch
```
