#!/usr/bin/env bash
#==============================================================================
# backup.sh - Backup completo do ambiente Ubuntu (configs + segredos + dados)
#
# Gera um diretorio autocontido que o ubuntu-setup-automated.sh consegue
# consumir para reconstruir o ambiente em outra maquina Ubuntu.
#
# Uso:
#   ./backup.sh [destino] [--with-downloads[=LIMITE_MB]]
#
#   destino               Diretorio onde o backup sera criado.
#                         Default: $HOME/ubuntu-backup
#   --with-downloads      Inclui ~/Downloads (por padrao NAO e incluido:
#                         normalmente e a maior parte de lixo/instaladores/
#                         Google Takeout, nao configuracao de ambiente).
#                         Aceita limite opcional de tamanho por arquivo em MB
#                         (default 500) para nao copiar arquivos gigantes.
#
# O backup fica dentro de <destino>/<hostname>-<data>/ e contem:
#   dotfiles/     arquivos de configuracao de shell/git (texto puro, sem segredo)
#   secrets.tar.gpg  tar criptografado (AES256, senha) com ssh/aws/kube/docker/
#                    gnupg/terraform.d/.zsh_secrets
#   inventory/    listas de pacotes/extensoes/envs conda/versao node/dconf/crontab
#   data/         Documents, Pictures, projects (e Downloads se pedido)
#   MANIFEST.md   resumo humano do que foi incluido/excluido
#==============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
DEST_BASE="${1:-$HOME/ubuntu-backup}"
WITH_DOWNLOADS=false
DOWNLOADS_LIMIT_MB=500

for arg in "$@"; do
    case "$arg" in
        --with-downloads)
            WITH_DOWNLOADS=true
            ;;
        --with-downloads=*)
            WITH_DOWNLOADS=true
            DOWNLOADS_LIMIT_MB="${arg#*=}"
            ;;
    esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_SAFE="$(hostname -s 2>/dev/null || hostname)"
BACKUP_DIR="${DEST_BASE%/}/${HOSTNAME_SAFE}-${STAMP}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; }
section() { echo ""; echo "=============================================="; echo "$1"; echo "=============================================="; }

mkdir -p "$BACKUP_DIR"/{dotfiles,inventory/conda,data}
info "Backup sera criado em: $BACKUP_DIR"

MANIFEST="$BACKUP_DIR/MANIFEST.md"
{
    echo "# Backup Ubuntu - $HOSTNAME_SAFE"
    echo ""
    echo "- Data: $(date -Iseconds)"
    echo "- Usuario: $(whoami)"
    echo "- Ubuntu: $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "- Kernel: $(uname -r)"
    echo "- Arquitetura: $(uname -m)"
    echo ""
} > "$MANIFEST"

#==============================================================================
# 1. DOTFILES (texto puro, sem segredo)
#==============================================================================
section "Copiando dotfiles"

DOTFILES=(.zshrc .zshrc.local .bashrc .bash_profile .bash_aliases .profile .gitconfig .condarc .npmrc .vimrc .fzf.zsh .fzf.bash)
for f in "${DOTFILES[@]}"; do
    if [ -f "$HOME/$f" ]; then
        cp -p "$HOME/$f" "$BACKUP_DIR/dotfiles/$f"
        info "✓ $f"
    fi
done

if [ -f "$HOME/.ssh/config" ]; then
    cp -p "$HOME/.ssh/config" "$BACKUP_DIR/dotfiles/ssh_config"
    info "✓ .ssh/config"
fi

echo "## Dotfiles incluidos" >> "$MANIFEST"
ls "$BACKUP_DIR/dotfiles" | sed 's/^/- /' >> "$MANIFEST"
echo "" >> "$MANIFEST"

#==============================================================================
# 2. SEGREDOS (criptografado)
#==============================================================================
section "Empacotando segredos (SSH, AWS, kube, docker, gnupg, terraform, zsh_secrets)"

SECRETS_STAGE="$(mktemp -d)"
trap 'rm -rf "$SECRETS_STAGE"' EXIT

secret_paths_found=()
copy_if_exists() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$SECRETS_STAGE/$dst")"
        cp -rp "$src" "$SECRETS_STAGE/$dst"
        secret_paths_found+=("$dst")
    fi
}

copy_if_exists "$HOME/.ssh"            "ssh"
copy_if_exists "$HOME/.aws"            "aws"
copy_if_exists "$HOME/.kube/config"    "kube/config"
copy_if_exists "$HOME/.docker/config.json" "docker/config.json"
copy_if_exists "$HOME/.gnupg"          "gnupg"
copy_if_exists "$HOME/.terraform.d"    "terraform.d"
copy_if_exists "$HOME/.zsh_secrets"    "zsh_secrets"
copy_if_exists "$HOME/tfc-github-key"        "extra/tfc-github-key"
copy_if_exists "$HOME/tfc-github-key.pub"    "extra/tfc-github-key.pub"

# PATs opcionais que o usuario queira incluir para automatizar auth na maquina
# nova (ex: gh, terraform cloud). So entram se o arquivo existir - nunca gerados.
copy_if_exists "$HOME/.config/gh/hosts.yml"        "gh/hosts.yml"
copy_if_exists "$HOME/.terraformrc"                "extra/.terraformrc"

if [ "${#secret_paths_found[@]}" -eq 0 ]; then
    warn "Nada encontrado para o bundle de segredos, pulando."
else
    info "Itens no bundle de segredos: ${secret_paths_found[*]}"

    TAR_PATH="$(mktemp -u).tar"
    tar -C "$SECRETS_STAGE" -cf "$TAR_PATH" .

    info "Digite uma senha para criptografar o bundle de segredos (sera pedida de novo no restore)."
    while true; do
        read -r -s -p "Senha: " PASS1; echo
        read -r -s -p "Confirme a senha: " PASS2; echo
        if [ -z "$PASS1" ]; then
            warn "Senha vazia nao e permitida."
            continue
        fi
        if [ "$PASS1" = "$PASS2" ]; then
            break
        fi
        warn "Senhas nao conferem, tente novamente."
    done

    gpg --batch --yes --pinentry-mode loopback --passphrase "$PASS1" \
        --symmetric --cipher-algo AES256 -o "$BACKUP_DIR/secrets.tar.gpg" "$TAR_PATH"
    unset PASS1 PASS2
    shred -u "$TAR_PATH" 2>/dev/null || rm -f "$TAR_PATH"

    info "✅ secrets.tar.gpg criado (AES256, protegido por senha)"
    {
        echo "## Segredos (secrets.tar.gpg, criptografado AES256)"
        printf -- '- %s\n' "${secret_paths_found[@]}"
        echo ""
        echo "> Guarde a senha em um cofre de senhas. Sem ela o backup de segredos e inutil."
        echo ""
    } >> "$MANIFEST"
fi

rm -rf "$SECRETS_STAGE"
trap - EXIT

#==============================================================================
# 3. INVENTARIO (pacotes, extensoes, envs conda, versao node, gnome, crontab)
#==============================================================================
section "Gerando inventario de pacotes e configuracoes"

INV="$BACKUP_DIR/inventory"

apt-mark showmanual > "$INV/apt-manual.txt" 2>/dev/null || true
info "✓ pacotes apt (manuais): $(wc -l < "$INV/apt-manual.txt" 2>/dev/null || echo 0)"

command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | tail -n +2 | awk '{print $1}' > "$INV/snap-list.txt" || true
info "✓ pacotes snap: $(wc -l < "$INV/snap-list.txt" 2>/dev/null || echo 0)"

if command -v npm >/dev/null 2>&1; then
    npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -r -n1 basename > "$INV/npm-global.txt" || true
    info "✓ pacotes npm globais: $(wc -l < "$INV/npm-global.txt" 2>/dev/null || echo 0)"
fi

if command -v code >/dev/null 2>&1; then
    code --list-extensions > "$INV/vscode-extensions.txt" 2>/dev/null || true
    info "✓ extensoes VS Code: $(wc -l < "$INV/vscode-extensions.txt" 2>/dev/null || echo 0)"
fi

if command -v node >/dev/null 2>&1; then
    node --version > "$INV/node-version.txt"
    info "✓ versao node: $(cat "$INV/node-version.txt")"
fi

CONDA_BIN="$HOME/miniconda3/bin/conda"
if [ -x "$CONDA_BIN" ]; then
    while IFS= read -r env_name; do
        [ "$env_name" = "base" ] && continue
        [ -z "$env_name" ] && continue
        "$CONDA_BIN" env export -n "$env_name" --no-builds > "$INV/conda/${env_name}.yml" 2>/dev/null \
            && info "✓ conda env exportado: $env_name" \
            || warn "Falha ao exportar conda env: $env_name"
    done < <("$CONDA_BIN" env list 2>/dev/null | grep -v '^#' | awk '{print $1}')
fi

if command -v dconf >/dev/null 2>&1; then
    dconf dump / > "$INV/gnome-dconf.txt" 2>/dev/null || true
    info "✓ configuracoes GNOME (dconf)"
fi

crontab -l > "$INV/crontab.txt" 2>/dev/null || true

{
    echo "## Inventario"
    echo "- apt-manual.txt, snap-list.txt, npm-global.txt, vscode-extensions.txt"
    echo "- node-version.txt: $(cat "$INV/node-version.txt" 2>/dev/null || echo 'n/a')"
    echo "- conda/*.yml: $(ls "$INV/conda" 2>/dev/null | wc -l) ambiente(s)"
    echo "- gnome-dconf.txt, crontab.txt"
    echo ""
} >> "$MANIFEST"

#==============================================================================
# 4. DADOS DO USUARIO (Documents, Pictures, projects, [Downloads opcional])
#==============================================================================
section "Copiando dados do usuario"

RSYNC_EXCLUDES=(
    --exclude "node_modules/" --exclude ".venv/" --exclude "venv/"
    --exclude "__pycache__/" --exclude ".terraform/" --exclude "dist/"
    --exclude "build/" --exclude "target/" --exclude ".next/" --exclude ".cache/"
)

sync_dir() {
    local src="$1" name="$2"
    shift 2
    if [ -d "$src" ]; then
        info "Sincronizando $name ..."
        mkdir -p "$BACKUP_DIR/data/$name"
        rsync -a --info=progress2 "$@" "$src"/ "$BACKUP_DIR/data/$name/" 2>/dev/null || warn "rsync teve avisos em $name (continuando)"
    fi
}

sync_dir "$HOME/Documents" "Documents" "${RSYNC_EXCLUDES[@]}"
sync_dir "$HOME/Pictures"  "Pictures"
sync_dir "$HOME/projects"  "projects" "${RSYNC_EXCLUDES[@]}"
sync_dir "$HOME/Music"     "Music"
sync_dir "$HOME/Desktop"   "Desktop"
sync_dir "$HOME/Templates" "Templates"

echo "## Dados incluidos" >> "$MANIFEST"
echo "- Documents, Pictures, projects, Music, Desktop, Templates" >> "$MANIFEST"

if [ "$WITH_DOWNLOADS" = true ]; then
    info "Sincronizando Downloads (limite ${DOWNLOADS_LIMIT_MB}MB por arquivo)..."
    mkdir -p "$BACKUP_DIR/data/Downloads"
    rsync -a --max-size="${DOWNLOADS_LIMIT_MB}m" "$HOME/Downloads"/ "$BACKUP_DIR/data/Downloads/" 2>/dev/null || warn "rsync teve avisos em Downloads"
    echo "- Downloads (arquivos > ${DOWNLOADS_LIMIT_MB}MB pulados)" >> "$MANIFEST"
else
    warn "Downloads NAO incluido (use --with-downloads para incluir)"
    echo "- Downloads: NAO incluido (rode com --with-downloads se precisar)" >> "$MANIFEST"
fi
echo "" >> "$MANIFEST"

#==============================================================================
# FIM
#==============================================================================
section "🎉 Backup concluido"

TOTAL_SIZE="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
{
    echo "## Tamanho total"
    echo "$TOTAL_SIZE"
} >> "$MANIFEST"

echo ""
info "Backup completo em: $BACKUP_DIR"
info "Tamanho total: $TOTAL_SIZE"
info "Manifesto: $MANIFEST"
echo ""
echo "Proximos passos:"
echo "  1. Copie a pasta '$BACKUP_DIR' para um HD externo / pendrive / scp / S3."
echo "  2. Na maquina nova, rode:"
echo "       ./ubuntu-setup-automated.sh /caminho/para/$(basename "$BACKUP_DIR")"
echo "  3. Guarde a senha do secrets.tar.gpg em lugar seguro (cofre de senhas)."
echo ""
