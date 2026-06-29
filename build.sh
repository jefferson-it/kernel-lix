#!/usr/bin/env bash
#=============================================================================
# build.sh — Kernel Alinix (Rust + C)
#   Kernel Linux 6.18.10 com suporte a Rust, otimizado para desktop x86_64,
#   com LSM limitador de root (Rust) e initramfs Rust do JSR-OS.
#
# Uso:
#   ./build.sh                    # build completo (kernel + módulos)
#   ./build.sh menuconfig         # configuração interativa
#   ./build.sh install            # instala kernel + módulos + initramfs
#   ./build.sh initramfs          # compila initramfs Rust do JSR-OS
#   ./build.sh clean              # limpa tudo
#   ./build.sh full               # build → install → initramfs → fhs
#
# Requer:  wget tar xz patch bc bison flex gcc make python3 rsync \
#          rustc bindgen cargo rust-src (rustup component add rust-src)
#=============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSR_OS_DIR="$(cd "${ROOT_DIR}/../JSR-OS" 2>/dev/null && pwd || echo "")"

KERNEL_VERSION="${KERNEL_VERSION:-}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }
header() { echo -e "\n${CYAN}═══ $* ═══${NC}\n"; }

select_kernel_version() {
    local cmd="${1:-}"
    if [[ -z "${KERNEL_VERSION}" ]]; then
        if [[ "$cmd" =~ ^(build|rebuild|menuconfig|config|install|modules|rust-module|full)$ ]] && { [ -t 0 ] || [ -t 1 ]; }; then
            echo -e "${CYAN}══ Seletor de Versão do Kernel Base ══${NC}"
            echo -e "1) 6.18.10 (Versão atual)"
            echo -e "2) 7.1.2 (Kernel 7.x)"
            read -rp "$(echo -e "${YELLOW}Escolha a versão [1-2] (padrão: 1):${NC} ")" choice
            case "$choice" in
                2) KERNEL_VERSION="7.1.2" ;;
                *) KERNEL_VERSION="6.18.10" ;;
            esac
        else
            KERNEL_VERSION="6.18.10"
        fi
    fi

    KERNEL_PATCHLEVEL="${KERNEL_VERSION%%.*}"
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_PATCHLEVEL}.x/linux-${KERNEL_VERSION}.tar.xz"
    KERNEL_SRC="${ROOT_DIR}/linux-${KERNEL_VERSION}"
    NPROC="$(nproc)"
}

select_kernel_version "${1:-build}"

prompt_confirm() {
    local msg="$1"
    local default="${2:-n}"
    local reply
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${YELLOW}${msg}${NC} [Y/n]: ")" reply
        [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
    else
        read -rp "$(echo -e "${YELLOW}${msg}${NC} [y/N]: ")" reply
        [[ -n "$reply" && "$reply" =~ ^[Yy]$ ]]
    fi
}

JSR_OS_INITRAMFS_SH="${JSR_OS_DIR}/apps/alinix-init/build-initramfs.sh"

# Configuração de logs de compilação
LOG_DIR="${ROOT_DIR}/logs"
BUILD_LOG="${LOG_DIR}/build.log"
mkdir -p "$LOG_DIR"

# Configuração de cache (ccache) para acelerar recompilações de C
CC_ARG=()
if command -v ccache &>/dev/null; then
    CC_ARG=(CC="ccache gcc")
fi

run_logged() {
    local step_name="$1"
    shift
    # Adiciona cabeçalho do passo no log
    echo -e "\n=== INÍCIO DO PASSO: $step_name [$(date)] ===" >> "$BUILD_LOG"
    echo "Comando: $*" >> "$BUILD_LOG"
    
    # Executa o comando em segundo plano
    "$@" >> "$BUILD_LOG" 2>&1 &
    local pid=$!
    
    local showing=false
    local tail_pid=""
    
    echo -e "${GREEN}[INFO]${NC} Passo iniciado: ${CYAN}$step_name${NC}"
    echo -e "${YELLOW}[DICA] Pressione Ctrl+O para alternar entre ver/esconder os detalhes em tempo real.${NC}"
    
    # Salva configurações do terminal para restaurar depois
    local old_stty=""
    if [ -t 0 ]; then
        old_stty=$(stty -g 2>/dev/null || echo "")
        # Desativa a interrupção padrão do Ctrl+O (eof) temporariamente para podermos lê-lo
        stty eof undef 2>/dev/null || true
    fi
    
    while kill -0 "$pid" 2>/dev/null; do
        # Aguarda entrada por 0.5s.
        local key=""
        if read -t 0.5 -r -n 1 key 2>/dev/null; then
            if [[ "$key" == $'\x0f' ]]; then
                if [[ "$showing" == "true" ]]; then
                    showing=false
                    if [[ -n "$tail_pid" ]]; then
                        kill "$tail_pid" 2>/dev/null || true
                        wait "$tail_pid" 2>/dev/null || true
                        tail_pid=""
                    fi
                    echo -e "\n${YELLOW}[OCULTO] Detalhes ocultados. Pressione Ctrl+O para exibir novamente.${NC}"
                else
                    showing=true
                    echo -e "\n${GREEN}[EXIBINDO] Detalhes do log (Ctrl+O para ocultar):${NC}"
                    tail -f "$BUILD_LOG" &
                    tail_pid=$!
                fi
            fi
        fi
    done
    
    # Restaura configurações do terminal
    if [[ -n "$old_stty" ]]; then
        stty "$old_stty" 2>/dev/null || true
    fi
    
    # Finaliza o tail se ainda estiver rodando
    if [[ -n "$tail_pid" ]]; then
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true
    fi
    
    # Obtém o status de retorno do comando em background
    wait "$pid"
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        echo -e "\n=== FALHA NO PASSO: $step_name [$(date)] ===" >> "$BUILD_LOG"
        # Cria cópia dedicada para depuração
        cp "$BUILD_LOG" "${LOG_DIR}/build-erro.log"
        echo -e "${RED}[ERRO] Falha no passo: $step_name${NC}"
        echo -e "${YELLOW}Últimas 30 linhas do log de compilação (mostrando o erro):${NC}\n"
        tail -n 30 "${LOG_DIR}/build-erro.log"
        echo
        error "A compilação falhou. O log completo foi salvo em: ${LOG_DIR}/build-erro.log"
    fi
    echo -e "=== FIM DO PASSO: $step_name ===\n" >> "$BUILD_LOG"
}


# ============================================================================
# 1.  Dependências
# ============================================================================
check_deps() {
    header "Verificando dependências"
    local deps_sys=(wget tar xz patch bc bison flex gcc make python3 rsync)
    local miss=()
    for d in "${deps_sys[@]}"; do command -v "$d" &>/dev/null || miss+=("$d"); done

    # libelf
    pkg-config --exists libelf 2>/dev/null || {
        ldconfig -p 2>/dev/null | grep -q libelf || miss+=("libelf-dev")
    }
    # openssl (para módulos)
    pkg-config --exists openssl 2>/dev/null || miss+=("libssl-dev")

    # --- Rust toolchain ---
    if ! command -v rustc &>/dev/null; then
        miss+=("rustc — instale via https://rustup.rs")
    fi
    if ! command -v bindgen &>/dev/null; then
        miss+=("bindgen (cargo install bindgen-cli)")
    fi
    if ! rustup component list --installed 2>/dev/null | grep -q rust-src; then
        miss+=("rust-src — rustup component add rust-src")
    fi
    if ! rustup component list --installed 2>/dev/null | grep -q rustfmt; then
        miss+=("rustfmt — rustup component add rustfmt")
    fi
    # cargo é necessário para bindgen
    command -v cargo &>/dev/null || miss+=("cargo")

    # pahole (BTF)
    command -v pahole &>/dev/null || miss+=("pahole (dwarves)")

    if [[ ${#miss[@]} -gt 0 ]]; then
        error "Dependências faltando:
  ${miss[*]}
Debian/Ubuntu: sudo apt-get install -y wget xz-utils patch bc bison flex gcc make \\
  python3 rsync libelf-dev libssl-dev dwarves pahole \\
  && rustup install stable && rustup component add rust-src \\
  && cargo install bindgen-cli
Arch:          sudo pacman -S --needed wget xz patch bc bison flex gcc make python3 \\
  rsync libelf openssl pahole rustup \\
  && rustup install stable && rustup component add rust-src \\
  && cargo install bindgen-cli"
    fi

    # Versão do rustc
    local rust_ver
    rust_ver=$(rustc --version | grep -oP '\d+\.\d+' | head -1)
    info "rustc ${rust_ver}  |  kernel ${KERNEL_VERSION}  |  $(nproc) threads"
}

# ============================================================================
# 2.  Baixar fonte
# ============================================================================
fetch_kernel() {
    header "Baixando kernel ${KERNEL_VERSION}"
    local tarball="${ROOT_DIR}/linux-${KERNEL_VERSION}.tar.xz"
    [[ -d "$KERNEL_SRC" ]] && { info "Fonte já existe, pulando."; return; }

    if [[ ! -f "$tarball" ]]; then
        wget -q --show-progress "$KERNEL_URL" -O "$tarball" || {
            rm -f "$tarball"
            error "Falha ao baixar ${KERNEL_URL}"
        }
    fi
    tar -xf "$tarball" -C "$ROOT_DIR"
    info "Extraído em ${KERNEL_SRC}"
}

# ============================================================================
# 3.  Aplicar patches Alinix
# ============================================================================
# apply_patches: aplica todas as mudanças Alinix diretamente via Python,
# sem depender de arquivo .patch externo. Idempotente — verifica se cada
# mudança já foi aplicada antes de aplicar novamente.
apply_patches() {
    header "Aplicando patches Alinix"

    cd "$KERNEL_SRC"
    # Invalida o cache de patches se a versão atual não tiver alinix_mark_key_defined
    if [[ -f ".alinix_patched" ]] && grep -q "alinix_mark_key_defined" "kernel/alinix.c" 2>/dev/null; then
        info "Patches já aplicados (versão atual)."; cd "$ROOT_DIR"; return
    fi
    [[ -f ".alinix_patched" ]] && rm -f ".alinix_patched"

    info "Aplicando correções Alinix via Python..."
    python3 - "$KERNEL_SRC" << 'PYEOF'
import sys, os, re

K = sys.argv[1]

def read(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def write(path, content):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

def patch_file(rel, check_str, old, new, desc):
    path = os.path.join(K, rel)
    if not os.path.exists(path):
        print(f"  [ERRO] Arquivo não encontrado: {rel}")
        return False
    content = read(path)
    if check_str in content:
        print(f"  [OK]   {rel} já possui '{desc}'")
        return True
    if old not in content:
        print(f"  [WARN] {rel}: contexto não encontrado para '{desc}' — verifique manualmente")
        return False
    write(path, content.replace(old, new, 1))
    print(f"  [FIX]  {rel}: '{desc}' aplicado")
    return True

def create_file(rel, content, desc):
    path = os.path.join(K, rel)
    if os.path.exists(path):
        print(f"  [OK]   {rel} já existe ({desc})")
        return True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write(path, content)
    print(f"  [FIX]  {rel}: criado ({desc})")
    return True

def overwrite_file(rel, content, check_str, desc):
    """Sempre sobrescreve arquivos gerados por nós (não são do kernel upstream)."""
    path = os.path.join(K, rel)
    if os.path.exists(path):
        existing = read(path)
        if check_str in existing:
            print(f"  [OK]   {rel} já está atualizado ({desc})")
            return True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write(path, content)
    print(f"  [FIX]  {rel}: escrito/atualizado ({desc})")
    return True

ok = True

# ── 1. rust/kernel/irq/request.rs — Fix E0310 (T: 'static nos callbacks) ─────
ok &= patch_file(
    "rust/kernel/irq/request.rs",
    "handle_irq_callback<T: Handler + 'static>",
    "unsafe extern \"C\" fn handle_irq_callback<T: Handler>(_irq: i32, ptr: *mut c_void) -> c_uint {",
    "unsafe extern \"C\" fn handle_irq_callback<T: Handler + 'static>(_irq: i32, ptr: *mut c_void) -> c_uint {",
    "handle_irq_callback + 'static"
)
ok &= patch_file(
    "rust/kernel/irq/request.rs",
    "handle_threaded_irq_callback<T: ThreadedHandler + 'static>",
    "unsafe extern \"C\" fn handle_threaded_irq_callback<T: ThreadedHandler>(\n    _irq: i32,\n    ptr: *mut c_void,\n) -> c_uint {",
    "unsafe extern \"C\" fn handle_threaded_irq_callback<T: ThreadedHandler + 'static>(\n    _irq: i32,\n    ptr: *mut c_void,\n) -> c_uint {",
    "handle_threaded_irq_callback + 'static"
)
ok &= patch_file(
    "rust/kernel/irq/request.rs",
    "thread_fn_callback<T: ThreadedHandler + 'static>",
    "unsafe extern \"C\" fn thread_fn_callback<T: ThreadedHandler>(_irq: i32, ptr: *mut c_void) -> c_uint {",
    "unsafe extern \"C\" fn thread_fn_callback<T: ThreadedHandler + 'static>(_irq: i32, ptr: *mut c_void) -> c_uint {",
    "thread_fn_callback + 'static"
)

# ── 1b. rust/kernel/lib.rs — Remove feature(used_with_arg) (Rust ≥1.96) ──────
# No Rust 1.96+, `used_with_arg` foi integrada ao comportamento padrão do
# compilador; a feature gate não existe mais e causa erro "declared but not used".
import re as _re
_lib_rs = os.path.join(K, "rust/kernel/lib.rs")
if os.path.exists(_lib_rs):
    _c = read(_lib_rs)
    _marker = "#![feature(used_with_arg)]"
    if _marker not in _c:
        print(f"  [OK]   rust/kernel/lib.rs: used_with_arg já removida")
    else:
        # Remove a linha e o comentário "// To be determined." associado
        _c = _re.sub(
            r'//\n// To be determined\.\n#!\[feature\(used_with_arg\)\]\n',
            '//\n',
            _c
        )
        if _marker in _c:
            _c = _c.replace(_marker + "\n", "")  # fallback: remove só a linha
        write(_lib_rs, _c)
        if _marker not in read(_lib_rs):
            print(f"  [FIX]  rust/kernel/lib.rs: '#![feature(used_with_arg)]' removida (Rust >=1.96)")
        else:
            print(f"  [ERRO] rust/kernel/lib.rs: falha ao remover used_with_arg")
            ok = False

# ── 2. include/linux/alinix.h — header do Alinix Root Limiter ────────────────
overwrite_file("include/linux/alinix.h", """\
/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LINUX_ALINIX_H
#define _LINUX_ALINIX_H

#include <linux/types.h>
#include <linux/uidgid.h>
#include <linux/stddef.h>

#ifdef CONFIG_SECURITY_ALINIX

void alinix_enable(void);
void alinix_disable(void);
void alinix_set_uid_auth(uid_t uid, bool auth);
bool alinix_uid_is_authed(uid_t uid);
bool alinix_is_enabled(void);
bool alinix_key_is_defined(void);
void alinix_mark_key_defined(void);

#else /* !CONFIG_SECURITY_ALINIX */

static inline bool alinix_uid_is_authed(uid_t uid) { return true; }
static inline bool alinix_is_enabled(void) { return false; }
static inline bool alinix_key_is_defined(void) { return false; }
static inline void alinix_mark_key_defined(void) { }
static inline void alinix_set_uid_auth(uid_t uid, bool auth) { }
static inline void alinix_enable(void) { }
static inline void alinix_disable(void) { }

#endif /* CONFIG_SECURITY_ALINIX */

#endif /* _LINUX_ALINIX_H */
""", "alinix_mark_key_defined", "Alinix header")

# ── 3. kernel/alinix.c — implementação do Root Limiter ───────────────────────
overwrite_file("kernel/alinix.c", """\
// SPDX-License-Identifier: GPL-2.0-only
/*
 * kernel/alinix.c  -  Alinix Root Limiter
 *
 * Fornece o mecanismo de autenticacao de root por chave no kernel.
 * O modulo Rust externo (alinix-lsm) usa estas funcoes para gerenciar
 * a autorizacao de UIDs via /dev/alinix-auth.
 *
 * A verificacao de capability e feita em security/commoncap.c.
 * O limiter so entra em vigor apos uma chave ser definida via set_key.
 * Antes disso, uid=0 tem acesso irrestrito (comportamento padrao do Linux).
 */
#include <linux/alinix.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/export.h>
#include <linux/printk.h>
#include <linux/bitmap.h>

#define ALINIX_MAX_AUTH_UID 65536

/* Mapa de bits: UIDs cujo root e autorizado */
static DECLARE_BITMAP(alinix_auth_bitmap, ALINIX_MAX_AUTH_UID);
static DEFINE_SPINLOCK(alinix_auth_lock);
static bool alinix_limiter_enabled;
static bool alinix_key_defined;

void alinix_enable(void)
{
\talinix_limiter_enabled = true;
\tpr_info("Alinix: root limiter ativo\\n");
}
EXPORT_SYMBOL_GPL(alinix_enable);

void alinix_disable(void)
{
\talinix_limiter_enabled = false;
\talinix_key_defined = false;
\tbitmap_zero(alinix_auth_bitmap, ALINIX_MAX_AUTH_UID);
\tpr_info("Alinix: root limiter desativado\\n");
}
EXPORT_SYMBOL_GPL(alinix_disable);

void alinix_set_uid_auth(uid_t uid, bool auth)
{
\tunsigned long flags;

\tif ((uid_t)uid >= ALINIX_MAX_AUTH_UID)
\t\treturn;

\tspin_lock_irqsave(&alinix_auth_lock, flags);
\tif (auth)
\t\t__set_bit(uid, alinix_auth_bitmap);
\telse
\t\t__clear_bit(uid, alinix_auth_bitmap);
\tspin_unlock_irqrestore(&alinix_auth_lock, flags);
}
EXPORT_SYMBOL_GPL(alinix_set_uid_auth);

void alinix_mark_key_defined(void)
{
\talinix_key_defined = true;
}
EXPORT_SYMBOL_GPL(alinix_mark_key_defined);

bool alinix_key_is_defined(void)
{
\treturn alinix_key_defined;
}
EXPORT_SYMBOL_GPL(alinix_key_is_defined);

bool alinix_uid_is_authed(uid_t uid)
{
\tbool ret;
\tunsigned long flags;

\tif (!alinix_limiter_enabled || !alinix_key_defined)
\t\treturn true;
\tif ((uid_t)uid >= ALINIX_MAX_AUTH_UID)
\t\treturn false;

\tspin_lock_irqsave(&alinix_auth_lock, flags);
\tret = test_bit(uid, alinix_auth_bitmap);
\tspin_unlock_irqrestore(&alinix_auth_lock, flags);
\treturn ret;
}
EXPORT_SYMBOL_GPL(alinix_uid_is_authed);

bool alinix_is_enabled(void)
{
\treturn alinix_limiter_enabled;
}
EXPORT_SYMBOL_GPL(alinix_is_enabled);
""", "alinix_mark_key_defined", "Alinix Root Limiter implementation")

# ── 4. kernel/Makefile — adiciona alinix.o ───────────────────────────────────
ok &= patch_file(
    "kernel/Makefile",
    "CONFIG_SECURITY_ALINIX",
    "obj-$(CONFIG_MULTIUSER) += groups.o",
    "obj-$(CONFIG_SECURITY_ALINIX) += alinix.o\nobj-$(CONFIG_MULTIUSER) += groups.o",
    "obj-$(CONFIG_SECURITY_ALINIX)"
)

# ── 5. security/commoncap.c — hook em cap_capable() ──────────────────────────
ok &= patch_file(
    "security/commoncap.c",
    "CONFIG_SECURITY_ALINIX",
    "#include <linux/user_namespace.h>\n#include <linux/binfmts.h>",
    "#include <linux/user_namespace.h>\n#include <linux/binfmts.h>\n#ifdef CONFIG_SECURITY_ALINIX\n#include <linux/alinix.h>\n#endif",
    "alinix.h include"
)
ok &= patch_file(
    "security/commoncap.c",
    "alinix_is_enabled",
    "\ttrace_cap_capable(cred, target_ns, cred_ns, cap, ret);\n\treturn ret;\n}",
    """\
#ifdef CONFIG_SECURITY_ALINIX
\t/*
\t * Alinix Root Limiter: so entra em vigor depois que uma chave for definida
\t * via `echo set_key <hex> > /dev/alinix-auth`. Antes disso, uid=0 tem
\t * acesso irrestrito (comportamento padrao do Linux), evitando tela preta
\t * no boot quando o servidor grafico ainda nao autenticou.
\t */
\tif (ret == 0 && alinix_is_enabled() && alinix_key_is_defined()) {
\t\tuid_t uid = from_kuid(&init_user_ns, cred->uid);
\t\tif (uid == 0 && !alinix_uid_is_authed(uid)) {
\t\t\tswitch (cap) {
\t\t\tcase CAP_SYS_ADMIN:
\t\t\tcase CAP_SYS_MODULE:
\t\t\tcase CAP_SYS_RAWIO:
\t\t\tcase CAP_SYS_BOOT:
\t\t\tcase CAP_SYS_TIME:
\t\t\tcase CAP_NET_ADMIN:
\t\t\tcase CAP_LINUX_IMMUTABLE:
\t\t\t\treturn -EPERM;
\t\t\t}
\t\t}
\t}
#endif /* CONFIG_SECURITY_ALINIX */
\ttrace_cap_capable(cred, target_ns, cred_ns, cap, ret);
\treturn ret;
}""",
    "cap_capable hook"
)

# ── 6. security/Kconfig — entrada CONFIG_SECURITY_ALINIX ─────────────────────
ok &= patch_file(
    "security/Kconfig",
    "config SECURITY_ALINIX",
    'source "security/integrity/Kconfig"',
    'source "security/integrity/Kconfig"\n\nconfig SECURITY_ALINIX\n\tbool "Alinix Root Limiter"\n\tdepends on SECURITY\n\thelp\n\t  Alinix Root Limiter - restringe operacoes sensiveis do root\n\t  (sysadmin, modulos, raw IO, boot, rede) ate que uma chave de\n\t  autenticacao seja fornecida pelo modulo Rust alinix-lsm.\n\t  Diz N se nao for usar.\n',
    "SECURITY_ALINIX Kconfig"
)

sys.exit(0 if ok else 1)
PYEOF

    local pyrc=$?
    if [[ $pyrc -eq 0 ]]; then
        info "Todas as correções Alinix aplicadas com sucesso."
        date > .alinix_patched
    else
        warn "Uma ou mais correções falharam — verifique o log acima."
    fi
    cd "$ROOT_DIR"
}

# ============================================================================
# 4.  Configurar kernel
# ============================================================================
configure_kernel() {
    header "Configurando kernel"
    cd "$KERNEL_SRC"

    # Se pediu menuconfig
    if [[ "${1:-}" == "menuconfig" ]]; then
        make menuconfig
        cd "$ROOT_DIR"; return
    fi

    # Se já configurado, só olddefconfig
    if [[ -f .config ]]; then
        run_logged "make olddefconfig" make olddefconfig
    else
        # Gera config base
        run_logged "make defconfig" make defconfig

        # Aplica fragmento Alinix
        local frag="${ROOT_DIR}/kernel.config.fragment"
        if [[ -f "$frag" ]]; then
            info "Aplicando otimizações Alinix (Rust + H/W + LSM)..."
            # Merge via script oficial
            if "${KERNEL_SRC}/scripts/kconfig/merge_config.sh" -n .config "$frag" 2>/dev/null; then
                : # ok
            else
                warn "merge_config.sh falhou, aplicando via scripts/config..."
                while IFS='=' read -r key val; do
                    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
                    key="${key%% #*}"
                    nkey="${key#CONFIG_}"
                    case "$val" in
                        y) ./scripts/config --enable "$nkey" 2>/dev/null || true ;;
                        m) ./scripts/config --module "$nkey" 2>/dev/null || true ;;
                        n) ./scripts/config --disable "$nkey" 2>/dev/null || true ;;
                        *) ;;
                    esac
                done < <(grep -v '^#' "$frag" | grep '=')
            fi
        fi

        run_logged "make olddefconfig" make olddefconfig
    fi

    # Validação obrigatória da configuração do Kernel
    info "Validando configurações críticas no .config..."
    local config_errors=()

    if ! grep -q '^CONFIG_RUST=y' .config; then
        config_errors+=("CONFIG_RUST=y (Suporte Rust no Kernel desabilitado)")
    fi
    if ! grep -q '^CONFIG_SECURITY_ALINIX=y' .config; then
        config_errors+=("CONFIG_SECURITY_ALINIX=y (LSM Alinix desabilitado)")
    fi
    if ! grep -q '^CONFIG_MODULES=y' .config; then
        config_errors+=("CONFIG_MODULES=y (Suporte a módulos desabilitado)")
    fi

    if [[ ${#config_errors[@]} -gt 0 ]]; then
        echo -e "${RED}[ERRO] Validação da configuração do kernel falhou!${NC}"
        echo -e "${YELLOW}As seguintes opções obrigatórias não estão habilitadas no .config:${NC}"
        for err in "${config_errors[@]}"; do
            echo -e "  - ${RED}${err}${NC}"
        done
        error "A compilação seria abortada mais tarde. Verifique kernel.config.fragment e conflitos de dependências Kconfig."
    fi

    info "Configuração salva e validada com sucesso em ${KERNEL_SRC}/.config"
    cd "$ROOT_DIR"
}

# ============================================================================
# 5.  Construir kernel (C + módulos Rust)
# ============================================================================
build_kernel() {
    header "Compilando kernel (C + suporte Rust)"
    cd "$KERNEL_SRC"

    # Exporta vars que o build Rust precisa
    export RUSTC_BOOTSTRAP=1
    # O Rust ≥1.96 requer -Zunstable-options para carregar target.json customizado
    export KRUSTFLAGS="-Zunstable-options"
    if command -v rustc &>/dev/null; then
        export RUSTC="$(command -v rustc)"
        export BINDGEN="$(command -v bindgen)"
    fi

    info "Kernel: ${KERNEL_VERSION}  |  Alvo: x86_64 Alinix Desktop (Rust enabled)"
    # Limpa log antigo para o novo build
    echo "=== Início do Build: $(date) ===" > "$BUILD_LOG"
    
    info "Compilando bzImage (isso pode demorar)..."
    run_logged "make bzImage" make "${CC_ARG[@]}" -j"${NPROC}" bzImage
    info "Kernel compilado: arch/x86/boot/bzImage"

    info "Compilando módulos do Kernel..."
    run_logged "make modules" make "${CC_ARG[@]}" -j"${NPROC}" modules
    info "Módulos C compilados"

    # Compila Rust modules (se CONFIG_RUST=y)
    if grep -q 'CONFIG_RUST=y' .config 2>/dev/null; then
        info "Compilando módulos Rust..."
        run_logged "make modules (Rust)" make "${CC_ARG[@]}" -j"${NPROC}" modules
    fi

    cd "$ROOT_DIR"
}

# ============================================================================
# 6.  Compilar módulo Rust externo (alinix-lsm)
# ============================================================================
build_rust_module() {
    header "Compilando módulo Rust: alinix-lsm (root limiter)"
    local mod_src="${ROOT_DIR}/src/alinix-lsm"
    [[ ! -d "$mod_src" ]] && { info "Diretório $mod_src não existe, pulando."; return; }

    cd "$mod_src"
    info "Compilando módulo alinix-lsm..."
    run_logged "make alinix-lsm" make KERNEL_DIR="${KERNEL_SRC}"
    info "Módulo Rust compilado: $(ls -la *.ko 2>/dev/null || echo 'sem .ko gerado')"
    cd "$ROOT_DIR"
}

# ============================================================================
# 6.5  Publicar artefatos em dist/ (vmlinuz + initrd com sufixo -lix)
# ============================================================================
publish_dist() {
    header "Publicando artefatos em dist/"

    local bz="${KERNEL_SRC}/arch/x86/boot/bzImage"
    if [[ ! -f "$bz" ]]; then
        warn "bzImage não encontrado — pulando publicação em dist/"
        return
    fi

    local kver
    kver=$(make -s -C "$KERNEL_SRC" kernelrelease 2>/dev/null || echo "${KERNEL_VERSION}-lix")

    local dist="${ROOT_DIR}/dist"
    mkdir -p "$dist"

    cp -v "$bz" "${dist}/vmlinuz-${kver}"
    info "Kernel publicado: dist/vmlinuz-${kver}"

    # initramfs: preferir o Rust (JSR-OS) se existir, senão gerar com mkinitramfs/dracut
    if [[ -f "${ROOT_DIR}/initramfs.img" ]]; then
        cp -v "${ROOT_DIR}/initramfs.img" "${dist}/initrd-${kver}.img"
        info "initrd publicado (Rust): dist/initrd-${kver}.img"
    elif command -v mkinitramfs &>/dev/null; then
        mkinitramfs -o "${dist}/initrd-${kver}.img" "$kver" 2>/dev/null || true
        [[ -f "${dist}/initrd-${kver}.img" ]] && \
            info "initrd publicado (mkinitramfs): dist/initrd-${kver}.img" || \
            warn "mkinitramfs falhou — dist/initrd-${kver}.img não gerado"
    elif command -v dracut &>/dev/null; then
        dracut --force "${dist}/initrd-${kver}.img" "$kver" 2>/dev/null || true
        [[ -f "${dist}/initrd-${kver}.img" ]] && \
            info "initrd publicado (dracut): dist/initrd-${kver}.img" || \
            warn "dracut falhou — dist/initrd-${kver}.img não gerado"
    else
        warn "Nenhuma ferramenta de initramfs disponível — dist/initrd-${kver}.img não gerado"
    fi

    # System.map e config (úteis para debug)
    [[ -f "${KERNEL_SRC}/System.map" ]] && cp -v "${KERNEL_SRC}/System.map" "${dist}/System.map-${kver}"
    [[ -f "${KERNEL_SRC}/.config"    ]] && cp -v "${KERNEL_SRC}/.config"    "${dist}/config-${kver}"

    info "dist/ atualizado: $(ls -lh "$dist" | tail -n +2 | awk '{print $NF}' | tr '\n' '  ')"
    cd "$ROOT_DIR"
}

# ============================================================================
# 7.  Compilar initramfs Rust do JSR-OS (alinix-init + xbootscreen)
# ============================================================================
build_initramfs() {
    header "Compilando initramfs Rust (JSR-OS alinix-init)"
    if [[ ! -f "$JSR_OS_INITRAMFS_SH" ]]; then
        info "JSR-OS não encontrado em ${JSR_OS_DIR}"
        info "Pule com '--no-initramfs' ou clone JSR-OS em ../JSR-OS/"
        return 1
    fi

    info "Usando ${JSR_OS_INITRAMFS_SH}"
    bash "$JSR_OS_INITRAMFS_SH" \
        --output "${ROOT_DIR}/initramfs.img" || {
        warn "Falha ao compilar initramfs"
        return 1
    }

    local sz
    sz="$(du -sh "${ROOT_DIR}/initramfs.img" 2>/dev/null | cut -f1)"
    info "initramfs gerado: ${ROOT_DIR}/initramfs.img (${sz:-?})"
}

# ============================================================================
# 8.  Instalar kernel + módulos + initramfs
# ============================================================================
install_kernel() {
    local bz="${KERNEL_SRC}/arch/x86/boot/bzImage"
    [[ -f "$bz" ]] || error "Kernel não compilado (faltando ${bz}). Execute ./build.sh build primeiro."

    header "Instalando kernel Alinix"
    cd "$KERNEL_SRC"

    local kver
    kver="$(make -s kernelrelease 2>/dev/null)"

    # Módulos (C + Rust)
    info "Instalando módulos do kernel..."
    make modules_install 2>&1 | tail -3

    # Módulo Rust externo (alinix-lsm root limiter)
    local rmod="${ROOT_DIR}/src/alinix-lsm"
    if [[ -d "$rmod" ]] && [[ -f "${rmod}/alinix_lsm.ko" ]]; then
        info "Instalando módulo Rust alinix_lsm..."
        cp -v "${rmod}/alinix_lsm.ko" "/lib/modules/${kver}/kernel/security/"
        depmod "${kver}"
    fi

    # Kernel image + map + config
    cp -v "$bz" "/boot/vmlinuz-${kver}"
    cp -v "${KERNEL_SRC}/System.map" "/boot/System.map-${kver}"
    cp -v "${KERNEL_SRC}/.config" "/boot/config-${kver}"

    # Initramfs (Rust do JSR-OS ou fallback)
    if [[ -f "${ROOT_DIR}/initramfs.img" ]]; then
        info "Copiando initramfs Rust (alinix-init)..."
        cp -v "${ROOT_DIR}/initramfs.img" "/boot/initramfs-${kver}.img"
    else
        info "initramfs.img não encontrado, gerando com ferramenta do sistema..."
        local initrd_cmd=""
        if command -v mkinitcpio &>/dev/null; then
            initrd_cmd="mkinitcpio -k ${kver} -g /boot/initramfs-${kver}.img"
        elif command -v dracut &>/dev/null; then
            initrd_cmd="dracut --force /boot/initramfs-${kver}.img ${kver}"
        elif command -v initramfs-tools &>/dev/null || command -v update-initramfs &>/dev/null; then
            initrd_cmd="update-initramfs -u -k ${kver}"
        fi
        if [[ -n "$initrd_cmd" ]]; then
            info "Gerando initramfs..."
            eval "$initrd_cmd" || warn "initramfs pode não ter sido gerado"
        fi
    fi

    # GRUB
    if command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    elif command -v update-grub &>/dev/null; then
        update-grub 2>/dev/null || true
    fi

    info "Kernel ${kver} instalado. Reinicie e selecione Alinix no GRUB."
    cd "$ROOT_DIR"
}

# ============================================================================
# 8.  Limpeza
# ============================================================================
clean_all() {
    header "Limpando"
    if [[ -d "$KERNEL_SRC" ]]; then
        cd "$KERNEL_SRC"
        make clean 2>/dev/null || true
        make mrproper 2>/dev/null || true
        cd "$ROOT_DIR"
        rm -f .alinix_patched
    fi
    # Limpa módulo Rust
    local rmod="${ROOT_DIR}/src/alinix-lsm"
    [[ -d "$rmod" ]] && make -C "$rmod" clean 2>/dev/null || true
    # Limpa initramfs
    rm -f "${ROOT_DIR}/initramfs.img"
    info "Limpeza concluída"
}

# ============================================================================
# 9.  FHS Alinix
# ============================================================================
setup_fhs() {
    local s="${ROOT_DIR}/scripts/setup-fhs.sh"
    if [[ -f "$s" ]]; then
        header "Aplicando FHS Alinix"
        bash "$s"
    else
        warn "scripts/setup-fhs.sh não encontrado"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    local cmd="${1:-build}"
    case "$cmd" in
        build)
            check_deps
            fetch_kernel
            apply_patches
            configure_kernel
            build_kernel
            build_rust_module
            publish_dist
            ;;
        rebuild)
            check_deps
            if [[ ! -d "$KERNEL_SRC" ]]; then
                local tarball="${ROOT_DIR}/linux-${KERNEL_VERSION}.tar.xz"
                if [[ -f "$tarball" ]]; then
                    info "Extraindo ${tarball}..."
                    tar -xf "$tarball" -C "$ROOT_DIR"
                    info "Extraído em ${KERNEL_SRC}"
                    apply_patches
                    configure_kernel
                elif prompt_confirm "Código fonte do kernel não encontrado. Deseja baixar/extrair?" "y"; then
                    fetch_kernel
                    apply_patches
                    configure_kernel
                else
                    error "Não é possível continuar sem o código fonte do kernel."
                fi
            else
                if prompt_confirm "Deseja reextrair o código fonte original do kernel (isso apagará modificações manuais)?" "n"; then
                    rm -rf "$KERNEL_SRC"
                    fetch_kernel
                    apply_patches
                    configure_kernel
                elif prompt_confirm "Deseja limpar os arquivos da compilação anterior (make clean)?" "n"; then
                    info "Limpando compilação anterior..."
                    cd "$KERNEL_SRC"
                    make clean
                    cd "$ROOT_DIR"
                fi
            fi

            build_kernel
            build_rust_module
            publish_dist
            ;;
        menuconfig|config)
            check_deps
            fetch_kernel
            apply_patches
            configure_kernel menuconfig
            ;;
        install)
            install_kernel
            ;;
        initramfs)
            build_initramfs
            ;;
        modules)
            check_deps
            fetch_kernel
            apply_patches
            configure_kernel
            build_kernel
            build_rust_module
            publish_dist
            ;;
        rust-module)
            check_deps
            fetch_kernel
            apply_patches
            configure_kernel
            build_rust_module
            ;;
        clean)
            clean_all
            ;;
        fhs)
            setup_fhs
            ;;
        full)
            check_deps
            fetch_kernel
            apply_patches
            configure_kernel
            build_kernel
            build_rust_module
            build_initramfs || true
            publish_dist
            install_kernel
            setup_fhs
            ;;
        *)
            echo "Uso: $0 {build|rebuild|config|install|initramfs|modules|rust-module|clean|fhs|full}"
            echo ""
            echo "  build        — baixa, configura e compila kernel + Rust module"
            echo "  rebuild      — compila kernel + Rust module diretamente"
            echo "  config       — menuconfig interativo"
            echo "  install      — instala kernel + módulos + initramfs + GRUB"
            echo "  initramfs    — compila initramfs Rust do JSR-OS (alinix-init)"
            echo "  modules      — compila kernel + módulos (incl. Rust)"
            echo "  rust-module  — só compila o módulo Rust alinix-lsm"
            echo "  clean        — limpa fonte e builds"
            echo "  fhs          — aplica FHS Alinix no sistema"
            echo "  full         — build → initramfs → install → fhs"
            exit 0
    esac
}

main "$@"
