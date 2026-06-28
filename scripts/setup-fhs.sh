#!/usr/bin/env bash
#=============================================================================
# setup-fhs.sh — Aplica o FHS customizado Alinix
#
# Cria a estrutura de diretórios e symlinks do FHS Alinix com merged-usr
# total (estilo Arch) e os nomes de topo do Alinix.
#
# Mapa:
#   /Users        → /home              (mount bind no fstab)
#   /Library      → diretório real
#   /Library/64   → /usr/lib           (symlink)
#   /Library/32   → /usr/lib32         (symlink)
#   /Exec         → /usr/bin           (symlink)
#   /Volumes      → diretório real     (montagens)
#   /mnt, /media  → /Volumes           (symlink)
#   /Progs        → diretório real     (apps universais)
#   /opt          → /Progs             (symlink)
#
# merged-usr total:
#   /bin → /usr/bin, /sbin → /usr/bin, /usr/sbin → /usr/bin
#   /lib → /usr/lib, /lib64 → /usr/lib
#=============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Este script precisa ser executado como root."
fi

# ============================================================================
# 1. merged-usr total (Arch-style)
# ============================================================================
info "Aplicando merged-usr total..."
declare -A MERGE=(
    ["/bin"]="/usr/bin"
    ["/sbin"]="/usr/bin"
    ["/usr/sbin"]="/usr/bin"
    ["/lib"]="/usr/lib"
    ["/lib64"]="/usr/lib"
)

for src in "${!MERGE[@]}"; do
    dst="${MERGE[$src]}"
    if [[ -L "$src" ]]; then
        # Já é symlink: verifica se aponta para o destino correto
        current="$(readlink "$src")"
        if [[ "$current" != "$dst" ]]; then
            info "  Atualizando $src → $dst (era → $current)"
            rm -f "$src" && ln -sf "$dst" "$src"
        fi
    elif [[ -d "$src" ]]; then
        # Diretório real: move conteúdo e substitui por symlink
        info "  Mesclando $src → $dst"
        if [[ "$src" != "$dst" ]]; then
            cp -a "$src"/* "$dst"/ 2>/dev/null || true
            rm -rf "$src"
            ln -sf "$dst" "$src"
        fi
    else
        # Não existe: cria symlink
        info "  Criando $src → $dst"
        ln -sf "$dst" "$src" 2>/dev/null || true
    fi
done

# ============================================================================
# 2. Nomes Alinix no raiz
# ============================================================================
info "Criando estrutura Alinix (/Users, /Library, /Exec, /Volumes, /Progs)..."
echo ""

# /Users → bind mount para /home (configurado no fstab depois)
if [[ ! -d "/Users" ]]; then
    mkdir -p /Users
    info "  /Users criado (bind mount para /home no fstab)"
fi

# /Library (diretório real)
if [[ ! -d "/Library" ]]; then
    mkdir -p /Library
fi
# /Library/64 → /usr/lib
[[ -L "/Library/64" ]] && rm -f /Library/64
ln -sf /usr/lib /Library/64
info "  /Library/64 → /usr/lib"
# /Library/32 → /usr/lib32
if [[ -d "/usr/lib32" ]]; then
    [[ -L "/Library/32" ]] && rm -f /Library/32
    ln -sf /usr/lib32 /Library/32
    info "  /Library/32 → /usr/lib32"
fi

# /Exec → /usr/bin
[[ -L "/Exec" ]] && rm -f /Exec
ln -sf /usr/bin /Exec
info "  /Exec → /usr/bin"

# /Volumes (diretório real para montagens)
if [[ ! -d "/Volumes" ]]; then
    mkdir -p /Volumes
fi
info "  /Volumes criado"

# /mnt → /Volumes, /media → /Volumes
for old in /mnt /media; do
    if [[ -L "$old" ]]; then
        rm -f "$old"
    elif [[ -d "$old" && ! -L "$old" ]]; then
        # Move conteúdo antigo
        if [[ -d "$old" ]] && [[ -n "$(ls -A "$old" 2>/dev/null)" ]]; then
            cp -a "$old"/* /Volumes/ 2>/dev/null || true
        fi
        rmdir "$old" 2>/dev/null || rm -rf "$old"
    fi
    ln -sf /Volumes "$old"
    info "  $old → /Volumes"
done

# /Progs (diretório real para aplicações universais)
if [[ ! -d "/Progs" ]]; then
    mkdir -p /Progs
fi
info "  /Progs criado"

# /opt → /Progs
[[ -L "/opt" ]] && rm -f /opt
ln -sf /Progs /opt
info "  /opt → /Progs"

# ============================================================================
# 3. fstab: bind mount /home → /Users
# ============================================================================
FSTAB="/etc/fstab"
FSTAB_ENTRY="/home    /Users    none    bind    0    0"

if grep -q "^/home.*/Users" "$FSTAB" 2>/dev/null; then
    info "  fstab: bind mount /home → /Users já existe"
else
    echo "$FSTAB_ENTRY" >> "$FSTAB"
    info "  fstab: adicionado bind mount /home → /Users"
    # Monta agora
    mount /Users 2>/dev/null || warn "  Não foi possível montar /Users agora (execute 'mount /Users' depois)"
fi

# ============================================================================
# 4. Esconder nomes FHS minúsculos do ls (opcional)
# ============================================================================
info ""
info "DICA: Para esconder os nomes FHS antigos do 'ls /',"
info "adicione estas linhas ao /etc/bash.bashrc ou ~/.bashrc:"
echo ""
echo '  alias ls="/usr/bin/ls --hide=bin --hide=sbin --hide=lib --hide=lib64 --hide=opt --hide=mnt --hide=media --hide=home"'
echo ""
info "Assim 'ls /' mostra apenas: Users  Library  Exec  Volumes  Progs"

# ============================================================================
# 5. Verificação
# ============================================================================
echo ""
info "Verificando estrutura:"
ls -la /Users /Library /Library/64 /Exec /Volumes /Progs /opt 2>&1 | head -20 || true

echo ""
info "FHS Alinix aplicado com sucesso!"
info "Reinicie ou execute 'source /etc/bash.bashrc' para ver os efeitos."
