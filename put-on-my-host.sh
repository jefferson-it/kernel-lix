#!/usr/bin/env bash
# ==============================================================================
#   put-on-my-host.sh
#   Compila e instala o Kernel-Lix e o módulo alinix-lsm no host atual.
#   Configura uma entrada no GRUB personalizada para o "Zorin Kernel Lix".
# ==============================================================================
set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $1"; }

# ── Verificação root ─────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    log_error "Este script precisa ser executado como root: sudo ./put-on-my-host.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSM_DIR="${SCRIPT_DIR}/src/alinix-lsm"
DIST_DIR="${SCRIPT_DIR}/dist"

# ── Flags ────────────────────────────────────────────────────────────────────
FORCE_REBUILD=false
KERNEL_VERSION_ARG=""
for arg in "$@"; do
    case "$arg" in
        --rebuild|-r) FORCE_REBUILD=true ;;
        --version=*) KERNEL_VERSION_ARG="${arg#--version=}" ;;
        7|7.*) KERNEL_VERSION_ARG="7.1.2" ;;
        6|6.*) KERNEL_VERSION_ARG="6.18.10" ;;
    esac
done

# ── Detecta artefatos em dist/ (padrão: vmlinuz-*-lix) ──────────────────────
detect_dist_artifact() {
    local prefix="${1:-}"
    if [[ -n "$prefix" ]]; then
        # Busca pelo prefixo de versão informado (ex: 7.1.2 → vmlinuz-7.1.2*-lix)
        find "$DIST_DIR" -maxdepth 1 -name "vmlinuz-${prefix}*-lix" 2>/dev/null | sort -V | tail -1
    else
        find "$DIST_DIR" -maxdepth 1 -name "vmlinuz-*-lix" 2>/dev/null | sort -V | tail -1
    fi
}

# ── Detecta versão do kernel já compilado (bzImage existente) ────────────────
detect_kernel_src() {
    for v in 7.1.2 6.18.10; do
        if [[ -f "${SCRIPT_DIR}/linux-${v}/arch/x86/boot/bzImage" ]]; then
            echo "${SCRIPT_DIR}/linux-${v}"
            return
        fi
    done
}

# ── Resolução de fonte: dist/ primeiro, depois linux-*/ ──────────────────────
DIST_VMLINUZ=""
KERNEL_SRC=""

if [[ "$FORCE_REBUILD" == "false" ]]; then
    DIST_VMLINUZ="$(detect_dist_artifact "${KERNEL_VERSION_ARG%%.*}")"
fi

if [[ -n "$DIST_VMLINUZ" ]]; then
    # Extrai a versão a partir do nome do arquivo (vmlinuz-<kver>)
    KVER="$(basename "$DIST_VMLINUZ" | sed 's/^vmlinuz-//')"
    log_info "Artefatos encontrados em dist/ — usando ${DIST_VMLINUZ}"
    log_info "Versão do kernel: $KVER"
else
    # Fallback: compilar a partir do código-fonte
    if [[ -n "$KERNEL_VERSION_ARG" ]]; then
        KERNEL_SRC="${SCRIPT_DIR}/linux-${KERNEL_VERSION_ARG}"
    else
        KERNEL_SRC="$(detect_kernel_src)"
    fi
    [[ -z "$KERNEL_SRC" ]] && KERNEL_SRC="${SCRIPT_DIR}/linux-6.18.10"

    # ── Configurar o PATH para usar o rustc do usuário real ──────────────────
    REAL_USER="${SUDO_USER:-root}"
    REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    if [[ -n "${SUDO_USER:-}" ]]; then
        export PATH="/home/${SUDO_USER}/.cargo/bin:$PATH"
    fi

    log_info "Verificando compilador Rust..."
    RUST_VER=$(rustc --version 2>/dev/null || echo "não encontrado")
    log_info "Usando rustc: $RUST_VER"

    # ── 1. Compilar Kernel-Lix e módulo alinix-lsm ───────────────────────────
    BZIMAGE="${KERNEL_SRC}/arch/x86/boot/bzImage"
    if [[ -f "$BZIMAGE" ]]; then
        log_info "Kernel já compilado em ${KERNEL_SRC} — pulando compilação."
        log_info "Use --rebuild para forçar recompilação."
    else
        log_info "Compilando Kernel-Lix..."
        KVER_ENV="${KERNEL_VERSION_ARG:-}"
        [[ -z "$KVER_ENV" ]] && KVER_ENV="${KERNEL_SRC##*linux-}"

        if [[ -n "${SUDO_USER:-}" ]]; then
            sudo -u "$REAL_USER" env PATH="$PATH" HOME="$REAL_HOME" KERNEL_VERSION="${KVER_ENV}" bash "${SCRIPT_DIR}/build.sh" build
        else
            KERNEL_VERSION="${KVER_ENV}" bash "${SCRIPT_DIR}/build.sh" build
        fi
    fi

    KVER=$(make -s -C "$KERNEL_SRC" kernelrelease 2>/dev/null || echo "6.18.10")
    log_info "Versão do kernel compilado: $KVER"

    # Atualiza dist/ após compilação
    DIST_VMLINUZ="${DIST_DIR}/vmlinuz-${KVER}"
fi

# ── 2. Instalar módulos no host ───────────────────────────────────────────────
if [[ -n "$KERNEL_SRC" ]] && [[ -d "$KERNEL_SRC" ]]; then
    log_info "Instalando módulos no host..."
    make -C "$KERNEL_SRC" modules_install
else
    log_warn "Código-fonte não disponível — módulos do kernel não instalados."
    log_warn "Se necessário, recompile com --rebuild."
fi

# ── 3. Instalar o módulo Rust alinix-lsm no host ──────────────────────────────
LSM_KO="${LSM_DIR}/alinix_lsm.ko"
if [[ -f "$LSM_KO" ]]; then
    log_info "Instalando módulo Rust alinix_lsm em /lib/modules/${KVER}..."
    mkdir -p "/lib/modules/${KVER}/kernel/security"
    cp -v "$LSM_KO" "/lib/modules/${KVER}/kernel/security/"
    depmod -a "$KVER"
else
    log_warn "Módulo Rust alinix_lsm.ko não encontrado. Verifique se ele compilou."
fi

# ── 4. Copiar imagem do kernel e configs para /boot ───────────────────────────
log_info "Copiando kernel e System.map para /boot..."
cp -v "$DIST_VMLINUZ" "/boot/vmlinuz-${KVER}"
[[ -f "${DIST_DIR}/System.map-${KVER}" ]] && cp -v "${DIST_DIR}/System.map-${KVER}" "/boot/System.map-${KVER}"
[[ -f "${DIST_DIR}/config-${KVER}"     ]] && cp -v "${DIST_DIR}/config-${KVER}"     "/boot/config-${KVER}"

# ── 5. Gerar initramfs do host ────────────────────────────────────────────────
# Se dist/ já tem um initrd, usa ele; senão gera com as ferramentas do sistema.
DIST_INITRD="${DIST_DIR}/initrd-${KVER}.img"
if [[ -f "$DIST_INITRD" ]]; then
    log_info "Usando initrd pré-gerado de dist/..."
    cp -v "$DIST_INITRD" "/boot/initrd.img-${KVER}"
else
    log_info "Gerando initramfs para o host..."
    if command -v update-initramfs &>/dev/null; then
        update-initramfs -c -k "$KVER" || update-initramfs -u -k "$KVER"
    elif command -v dracut &>/dev/null; then
        dracut --force "/boot/initrd.img-${KVER}" "$KVER"
    else
        log_warn "Nenhuma ferramenta padrão (update-initramfs/dracut) encontrada. Gerando initramfs básico..."
        mkinitramfs -o "/boot/initrd.img-${KVER}" "$KVER" || true
    fi
fi

# ── 6. Adicionar entrada Zorin Kernel Lix no GRUB ─────────────────────────────
log_info "Configurando entrada no GRUB..."
UUID=$(findmnt -no UUID -T /)
if [[ -z "$UUID" ]]; then
    UUID=$(blkid -o value -s UUID "$(findmnt -no SOURCE /)" 2>/dev/null || true)
fi

# Pegar opções de boot atuais do cmdline do host (removendo BOOT_IMAGE)
CMDLINE=$(cat /proc/cmdline | sed -e 's/BOOT_IMAGE=[^ ]* //g')

# Usar Python para atualizar o /etc/grub.d/40_custom de forma segura e idempotente
python3 - "$UUID" "$KVER" "$CMDLINE" << 'EOF'
import sys
import os

uuid = sys.argv[1]
kver = sys.argv[2]
cmdline = sys.argv[3]

filepath = '/etc/grub.d/40_custom'

menuentry = f"""menuentry "Zorin OS, com Kernel Lix" --class zorin --class gnu-linux --class gnu --class os {{
	recordfail
	load_video
	insmod gzio
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root {uuid}
	linux /boot/vmlinuz-{kver} {cmdline}
	initrd /boot/initrd.img-{kver}
}}
"""

if os.path.exists(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
else:
    content = "#!/bin/sh\nexec tail -n +3 $0\n"

# Remover entrada antiga se houver
start_idx = content.find('menuentry "Zorin OS, com Kernel Lix"')
if start_idx != -1:
    # Contar chaves para achar o final do bloco
    brace_count = 0
    end_idx = -1
    for i in range(start_idx, len(content)):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                end_idx = i + 1
                break
    if end_idx != -1:
        content = content[:start_idx].rstrip() + "\n" + content[end_idx:].lstrip()

# Adicionar a nova entrada no final do arquivo
if not content.endswith('\n'):
    content += '\n'
content += menuentry

with open(filepath, 'w') as f:
    f.write(content)

os.chmod(filepath, 0o755)
print("Entrada 'Zorin OS, com Kernel Lix' adicionada/atualizada no 40_custom.")
EOF

# Atualizar GRUB
log_info "Atualizando GRUB..."
if command -v update-grub &>/dev/null; then
    update-grub
elif command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# ── 7. Garantir que o kernel genérico do sistema continua como padrão ─────────
# GRUB_DEFAULT=0 aponta para a primeira entrada do menu principal,
# que é sempre o kernel mais recente do sistema (gerado pelo 10_linux).
# A entrada Lix fica disponível em "Advanced options" ou pelo menu completo.
log_info "Mantendo kernel padrão do sistema (GRUB_DEFAULT=0)..."
GRUB_DEFAULT_CONF="/etc/default/grub"
if grep -q "^GRUB_DEFAULT=" "$GRUB_DEFAULT_CONF"; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' "$GRUB_DEFAULT_CONF"
else
    echo 'GRUB_DEFAULT=0' >> "$GRUB_DEFAULT_CONF"
fi

# Salvar entrada padrão atual via grub-set-default para o kernel genérico
# (a entrada 0 é sempre o kernel padrão do sistema no Zorin/Ubuntu)
if command -v grub-set-default &>/dev/null; then
    grub-set-default 0
fi

# Regenerar grub.cfg com o padrão atualizado
if command -v update-grub &>/dev/null; then
    update-grub
elif command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
fi

log_ok "Kernel Lix ($KVER) instalado com sucesso no host!"
log_ok "Kernel padrão: mantido como o kernel genérico do sistema."
log_ok "Para usar o Lix: reinicie e escolha 'Zorin OS, com Kernel Lix' no GRUB."
