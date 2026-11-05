#!/usr/bin/env bash
#==============================================================================
# backup.sh - backup completo e CIFRADO desta maquina Ubuntu para um disco
# externo (ou qualquer pasta fora do repo).
#
# Uso:
#   ./backup.sh DESTINO [--dry-run] [--projeto-max-mb N] [--rapido]
#
#   DESTINO            pasta onde o backup sera criado (ex.: o disco externo
#                      montado em /media/$USER/<disco>). Nunca um repo git.
#   --dry-run          so lista o que entraria (MANIFESTO na tela). Nao pede
#                      senha, nao usa sudo para copiar, nao grava nada.
#   --projeto-max-mb N pasta de ~/projects fora do git so entra se tiver ate N
#                      MB (padrao 2048).
#   --ignorado-max-mb N arquivo/pasta ignorado pelo git (.env, .tfvars, .pem...) de um
#                      repo so entra se tiver ate N MB (padrao 100); o que passar e contado.
#   --sem-sudo         nao le /etc nem as VPNs do NetworkManager (sem pedir sudo).
#   --rapido           pula o sha256 por arquivo do grupo "config e segredos"
#                      (o sha256 do arquivo cifrado inteiro sempre e feito).
#
# Saida em DESTINO/backup-ubuntu-<host>-<data>/:
#   backup.tar.gpg   tar cifrado (gpg simetrico AES256). A senha e pedida na
#                    hora, duas vezes, e nunca e gravada em arquivo, argv ou log.
#   SHA256SUMS       sha256 do backup.tar.gpg (sha256sum -c SHA256SUMS)
#   MANIFESTO.txt    o que foi salvo (sem conteudo, so nomes/contagens/tamanhos)
#
# Dentro do tar, a pasta .backup-ubuntu-meta/ traz inventarios (pacotes,
# crontab, units, dconf), copias dos arquivos de /etc que mudaram, perfis de VPN
# do NetworkManager e o sha256 por arquivo. O ubuntu-setup-automated.sh --restore
# le tudo isso.
#
# Extras: liste caminhos (relativos ao HOME) em ~/.config/backup-ubuntu-extras.txt, ou
# aponte BACKUP_EXTRAS_FILE para outro arquivo. Assim nada especifico da sua conta fica no repo.
#
# NAO entram: ~/Downloads (decisao do dono), caches, node_modules, venvs,
# ~/.aws/sso/cache, plugin-cache do terraform. Repos de ~/projects so entram se
# tiverem mudanca nao enviada, ou nao estiverem no GitHub; os demais voltam por
# git clone no restore.
#==============================================================================
set -euo pipefail
umask 077

VERSAO_SCRIPT="2026-11"
DRY_RUN=false
RAPIDO=false
SEM_SUDO=false
PROJ_MAX_MB=2048
IGN_MAX_MB=100
DESTINO=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
erro()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }
die()   { erro "$*"; exit 1; }

uso() { sed -n '2,/^#====.*$/p' "$0" | sed -n '2,40p' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --rapido) RAPIDO=true ;;
        --sem-sudo) SEM_SUDO=true ;;
        --ignorado-max-mb) shift; IGN_MAX_MB="${1:-}"; [[ "$IGN_MAX_MB" =~ ^[0-9]+$ ]] || die "--ignorado-max-mb pede um numero" ;;
        --projeto-max-mb) shift; PROJ_MAX_MB="${1:-}"; [[ "$PROJ_MAX_MB" =~ ^[0-9]+$ ]] || die "--projeto-max-mb pede um numero" ;;
        -h|--help) uso; exit 0 ;;
        -*) die "opcao desconhecida: $1 (use --help)" ;;
        *) [ -z "$DESTINO" ] || die "so um DESTINO"; DESTINO="$1" ;;
    esac
    shift
done
[ -n "$DESTINO" ] || { uso; die "informe o DESTINO (ex.: /media/\$USER/<disco>)"; }
[ "$(id -u)" -ne 0 ] || die "rode como o seu usuario, nao como root (o sudo e chamado so onde precisa)"
[ -d "$DESTINO" ] || die "DESTINO nao existe ou nao esta montado: $DESTINO"
DESTINO="$(cd "$DESTINO" && pwd -P)"
[ -w "$DESTINO" ] || die "sem permissao de escrita em $DESTINO"

# O backup leva segredos: nunca dentro de um repo git nem dentro do HOME.
if git -C "$DESTINO" rev-parse --git-dir >/dev/null 2>&1; then
    die "DESTINO esta dentro de um repositorio git ($DESTINO). O backup leva segredos e nao pode ir para um repo."
fi
case "$DESTINO/" in
    "$HOME"/*) die "DESTINO esta dentro do seu HOME. Use o disco externo." ;;
esac

for c in tar gpg sha256sum find du git; do
    command -v "$c" >/dev/null 2>&1 || die "falta o comando: $c"
done

HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date +%Y%m%d-%H%M%S)"
NOME="backup-ubuntu-${HOST}-${STAMP}"
SAIDA="$DESTINO/$NOME"
META=".backup-ubuntu-meta"

# Area de trabalho em tmpfs (RAM, 0700): os segredos copiados com sudo nao tocam o disco.
RUNBASE="${XDG_RUNTIME_DIR:-/dev/shm}"
WORK="$(mktemp -d "$RUNBASE/backup-ubuntu.XXXXXX")"
STAGE="$WORK/stage"
mkdir -p "$STAGE/$META"
LISTA="$WORK/lista.nul"
LISTA_SHA="$WORK/lista-sha.nul"
: > "$LISTA"
: > "$LISTA_SHA"
MAN="$WORK/manifesto.txt"
: > "$MAN"
PASS=""
cleanup() { PASS=""; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'erro "falhou na linha $LINENO"' ERR

#------------------------------------------------------------------------------
# Excludes (padroes do tar; valem em qualquer profundidade)
#------------------------------------------------------------------------------
EXCL=(
    '.aws/sso/cache' '.aws/cli/cache'
    '.terraform.d/plugin-cache'
    '.kiro/crew-venv' '.kiro/.crew-venv-*' '.kiro/crew-python' '.kiro/extensions' '.kiro/logs'
    '.claude/cache' '.claude/shell-snapshots' '.claude/statsig' '.claude/telemetry'
    '.local/share/jarvis/venv' '.local/share/jarvis/venv.bak*' '.local/share/voz/venv' '.local/share/voz/venv.bak*'
    'node_modules' '__pycache__' '.venv' 'venv' '.terraform' '.pytest_cache' '.mypy_cache' '.nx'
    '*.pyc'
)
TAR_EXCL=(); DU_EXCL=()
for p in "${EXCL[@]}"; do
    TAR_EXCL+=("--exclude=$p")
    case "$p" in '*'*) DU_EXCL+=("--exclude=$p") ;; *) DU_EXCL+=("--exclude=*/$p") ;; esac
done

#------------------------------------------------------------------------------
# Itens do HOME: grupo|caminho relativo ao HOME
#------------------------------------------------------------------------------
ITENS=(
    'segredos|.ssh' 'segredos|.aws' 'segredos|.kube' 'segredos|.terraform.d'
    'segredos|.config/rclone' 'segredos|.config/gh' 'segredos|.gnupg' 'segredos|.cert'
    'segredos|.docker/config.json' 'segredos|.zsh_secrets' 'segredos|.claude.json'
    'segredos|.local/share/kiro-cli/data.sqlite3' 'segredos|.local/share/keyrings'
    'segredos|.gemini' 'segredos|.config/gcloud' 'segredos|.config/glab-cli' 'segredos|.config/hub'
    'segredos|.config/kiro-cli' 'segredos|.config/google-chrome-cli' 'segredos|.netrc' 'segredos|.npmrc'
    'segredos|.slack_secret' 'segredos|.config/xo-cli' 'segredos|.config/teamviewer'
    'segredos|.local/share/GitKrakenCLI/gk.cfg' 'segredos|.config/GitKrakenCLI'
    'segredos|.config/jarvis-polly' 'segredos|.config/helm' 'segredos|projects/OpenVPN'
    'config|.zshrc' 'config|.zprofile' 'config|.bashrc' 'config|.bash_profile' 'config|.profile'
    'config|.bash_aliases' 'config|.aliases' 'config|.tmux.conf' 'config|.gitconfig'
    'config|.zsh_history' 'config|.config/monitors.xml' 'config|.config/mimeapps.list'
    'config|.config/Code/User/settings.json' 'config|.config/Code/User/keybindings.json'
    'config|.config/Code/User/snippets' 'config|.config/Kiro/User/settings.json'
    'config|.config/Kiro/User/keybindings.json' 'config|.config/Kiro/User/snippets'
    'config|.config/remmina' 'config|.config/autostart' 'config|.local/share/fonts' 'config|.fonts'
    'config|.local/share/applications'
    'harness|.kiro' 'harness|.kiro-shared' 'harness|.claude'
    'harness|.local/share/jarvis' 'harness|.local/share/voz' 'harness|.local/share/escritorio'
    'harness|.config/systemd/user'
    'dados|Documentos' 'dados|Documents' 'dados|Pictures' 'dados|Desktop' 'dados|scratch'
    'dados|backup-git-2026-11-05'
)

# Itens de topo que sao symlink (ex.: ~/.zsh_secrets -> repo do harness) viram copia
# real em $META/deref/, porque o tar guardaria so o link.
DEREF_LIST="$STAGE/$META/deref.txt"; : > "$DEREF_LIST"

fmt_bytes() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
mline() { printf '%s\n' "$*" >> "$MAN"; }

# Conta so o que o tar levaria (respeita os excludes)
conta_arquivos() {
    tar -C "$HOME" "${TAR_EXCL[@]}" -cvf /dev/null "$1" 2>/dev/null | grep -vc '/$' || true
}

# Caminhos que ja estao no tar por outro item (evita duplicar projects/OpenVPN
# quando a pasta entra por "projetos").
declare -A JA=()

adiciona_item() {
    local grupo="$1" rel="$2" abs="$HOME/$2"
    [ -e "$abs" ] || [ -L "$abs" ] || return 0
    [ -z "${JA[$rel]:-}" ] || return 0
    JA[$rel]=1
    local bytes files
    if [ -L "$abs" ]; then
        local alvo; alvo="$(readlink -f "$abs" 2>/dev/null || true)"
        [ -e "$alvo" ] || { warn "symlink quebrado, ignorado: ~/$rel"; return 0; }
        bytes="$(du -sb "$alvo" 2>/dev/null | cut -f1)"; files="$(find "$alvo" -type f 2>/dev/null | wc -l)"
        printf '%s\n' "$rel" >> "$DEREF_LIST"
        mline "$grupo | ~/$rel (symlink, entra como copia real) | $files arquivos | $(fmt_bytes "${bytes:-0}")"
        return 0
    fi
    bytes="$(du -sb "${DU_EXCL[@]}" "$abs" 2>/dev/null | cut -f1 || true)"
    files="$(conta_arquivos "$rel")"
    printf '%s\0' "$rel" >> "$LISTA"
    case "$grupo" in segredos|config) printf '%s\0' "$rel" >> "$LISTA_SHA" ;; esac
    mline "$grupo | ~/$rel | $files arquivos | $(fmt_bytes "${bytes:-0}")"
}

#------------------------------------------------------------------------------
# Projetos: so repos com mudanca nao enviada ou fora do GitHub; pastas fora do git
# ate o limite de tamanho. Registra tambem a lista de clones para o restore.
#------------------------------------------------------------------------------
CLONAR="$STAGE/$META/projetos-clonar.tsv"; : > "$CLONAR"
PROJ_MAN="$WORK/projetos.txt"; : > "$PROJ_MAN"

# Pasta fora do git entra se couber no limite; pasta que tem repos dentro e percorrida (arquivos soltos
# e subpastas sem git entram; os repos seguem a regra de cima).
IGN_LISTA="$STAGE/$META/inventario/gitignored-incluidos.txt"
IGN_N=0; IGN_PULADOS=0; IGN_BYTES=0
NAOGIT_N=0; NAOGIT_PULADOS=0

tem_git_dentro() { find "$1" -maxdepth 6 -name .git -print -quit 2>/dev/null | grep -q .; }

inclui_naogit() { # inclui_naogit caminho_absoluto
    local d="$1" rel mb
    rel="${d#"$HOME"/}"
    [ -z "${JA[$rel]:-}" ] || return 0
    mb=$(( $(du -sb "${DU_EXCL[@]}" "$d" 2>/dev/null | cut -f1 || echo 0) / 1048576 ))
    if [ "$mb" -le "$PROJ_MAX_MB" ]; then
        JA[$rel]=1; NAOGIT_N=$((NAOGIT_N+1))
        printf '%s\0' "$rel" >> "$LISTA"
        printf 'INCLUIDO | ~/%s | fora-do-git | %s MB\n' "$rel" "$mb" >> "$PROJ_MAN"
    else
        NAOGIT_PULADOS=$((NAOGIT_PULADOS+1))
        printf 'IGNORADO (fora do git, %s MB > limite %s MB; use --projeto-max-mb) | ~/%s\n' "$mb" "$PROJ_MAX_MB" "$rel" >> "$PROJ_MAN"
    fi
}

percorre_naogit() { # percorre_naogit dir profundidade
    local dir="$1" nivel="$2" c
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        if [ -d "$c" ] && [ ! -L "$c" ]; then
            if [ -e "$c/.git" ]; then continue
            elif tem_git_dentro "$c"; then
                if [ "$nivel" -lt 5 ]; then percorre_naogit "$c" $((nivel+1)); fi
            else inclui_naogit "$c"; fi
        elif [ -f "$c" ] || [ -L "$c" ]; then
            [ "$nivel" -ge 1 ] || continue
            local rel="${c#"$HOME"/}"
            [ -z "${JA[$rel]:-}" ] || continue
            JA[$rel]=1; printf '%s\0' "$rel" >> "$LISTA"
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
}

# Arquivos ignorados pelo git (.env, .tfvars, .pem...) de cada repo que NAO entra inteiro.
# Fora: node_modules, .terraform, venv, .venv, __pycache__, dist, build, target. Entrada acima de
# --ignorado-max-mb (padrao 100) e pulada e contada.
coleta_ignorados() { # coleta_ignorados repo_absoluto
    local d="$1" rel e abs sz
    rel="${d#"$HOME"/}"
    while IFS= read -r -d '' e; do
        abs="$d/${e%/}"
        sz="$(du -sb "${DU_EXCL[@]}" "$abs" 2>/dev/null | cut -f1 || echo 0)"; sz="${sz:-0}"
        if [ "$sz" -gt $((IGN_MAX_MB * 1048576)) ]; then IGN_PULADOS=$((IGN_PULADOS+1)); continue; fi
        printf '%s\0' "$rel/${e%/}" >> "$LISTA"
        printf '%s/%s\n' "$rel" "${e%/}" >> "$IGN_LISTA"
        IGN_N=$((IGN_N+1)); IGN_BYTES=$((IGN_BYTES+sz))
    done < <(timeout 120 git -C "$d" ls-files -z --others --ignored --exclude-standard --directory 2>/dev/null \
                | grep -zEv '(^|/)(node_modules|\.terraform|venv|\.venv|__pycache__|dist|build|target|\.pytest_cache|\.mypy_cache|\.nx|\.git)(/|$)' || true)
}

avalia_projetos() {
    local base="$HOME/projects" d rel motivo url eh_wt dirty ahead
    [ -d "$base" ] || return 0
    mkdir -p "$(dirname "$IGN_LISTA")"; : > "$IGN_LISTA"
    local -a repos=()
    while IFS= read -r g; do repos+=("$(dirname "$g")"); done < <(find "$base" -maxdepth 6 -name .git -not -path '*/node_modules/*' 2>/dev/null | sort)
    for d in "${repos[@]}"; do
        rel="${d#"$HOME"/}"
        eh_wt=false; [ -f "$d/.git" ] && eh_wt=true
        motivo=""
        url="$(timeout 20 git -C "$d" remote get-url origin 2>/dev/null || true)"
        dirty="$(timeout 60 git -C "$d" status --porcelain 2>/dev/null | head -1 || true)"
        ahead="$(timeout 60 git -C "$d" log --branches --not --remotes --oneline -1 2>/dev/null || true)"
        if [ -n "$dirty" ]; then motivo="mudanca-local"
        elif [ -n "$ahead" ] && ! $eh_wt; then motivo="commit-nao-enviado"
        elif [ -z "$url" ] && ! $eh_wt; then motivo="sem-remoto"
        elif [ -n "$url" ] && ! $eh_wt && ! printf '%s' "$url" | grep -q 'github\.com'; then motivo="fora-do-github"
        fi
        if [ -n "$motivo" ]; then
            [ -z "${JA[$rel]:-}" ] || continue
            JA[$rel]=1
            local bytes files
            bytes="$(du -sb "${DU_EXCL[@]}" "$d" 2>/dev/null | cut -f1 || true)"
            files="$(conta_arquivos "$rel")"
            printf '%s\0' "$rel" >> "$LISTA"
            printf 'INCLUIDO | ~/%s | %s | %s arquivos | %s\n' "$rel" "$motivo" "$files" "$(fmt_bytes "${bytes:-0}")" >> "$PROJ_MAN"
        else
            if ! $eh_wt && [ -n "$url" ]; then
                printf '%s\t%s\n' "$rel" "$url" >> "$CLONAR"
                printf 'CLONAR NO SETUP | ~/%s\n' "$rel" >> "$PROJ_MAN"
            else
                printf 'IGNORADO (worktree limpo; a branch vive no repo principal) | ~/%s\n' "$rel" >> "$PROJ_MAN"
            fi
            coleta_ignorados "$d"
        fi
    done
    # Pastas e arquivos fora do git, em qualquer nivel (ate 5) de ~/projects
    percorre_naogit "$base" 0
}

#------------------------------------------------------------------------------
# Inventarios (texto, sem segredo)
#------------------------------------------------------------------------------
inv() { # inv ARQUIVO comando...
    local f="$STAGE/$META/inventario/$1"; shift
    mkdir -p "$(dirname "$f")"
    "$@" > "$f" 2>/dev/null || { rm -f "$f"; return 0; }
    [ -s "$f" ] || rm -f "$f"
}

coleta_inventarios() {
    inv apt-manual.txt apt-mark showmanual
    inv os-release.txt cat /etc/os-release
    inv kernel.txt uname -r
    inv home-origem.txt printf '%s\n' "$HOME"
    inv usuario-origem.txt id -un
    inv snap.txt bash -c "snap list | awk 'NR>1{print \$1, \$4}'"
    inv snap-classic.txt bash -c "snap list | awk 'NR>1 && \$NF ~ /classic/{print \$1}'"
    command -v flatpak >/dev/null 2>&1 && inv flatpak.txt flatpak list --app --columns=application,origin
    inv pip-user.txt python3 -m pip list --user --format=freeze
    # shellcheck disable=SC2016
    inv npm-global.txt bash -c 'source "$HOME/.nvm/nvm.sh" 2>/dev/null; npm ls -g --depth=0 --parseable | tail -n +2 | sed "s#.*/node_modules/##"'
    # shellcheck disable=SC2016
    inv npm-global-versoes.txt bash -c 'source "$HOME/.nvm/nvm.sh" 2>/dev/null; npm ls -g --depth=0 | tail -n +2 | sed "s/^[^a-zA-Z@]*//"'
    inv deb-externos.txt bash -c "apt list --installed 2>/dev/null | grep ',local\]' | cut -d/ -f1"
    inv apt-repos.txt bash -c 'ls /etc/apt/sources.list.d /etc/apt/keyrings 2>/dev/null'
    inv go-bin.txt ls "$HOME/go/bin"
    inv bin-fora-do-apt.txt bash -c 'find "$HOME/.local/bin" /usr/local/bin /opt -maxdepth 1 \( -type f -o -type d \) ! -type l -printf "%p\n" 2>/dev/null | sort'
    inv appimages.txt bash -c 'find "$HOME" -maxdepth 3 -iname "*.AppImage" -not -path "*/projects/*" 2>/dev/null'
    inv fontes-usuario.txt bash -c 'fc-list : file 2>/dev/null | grep -v "^/usr/" | sort'
    inv gnome-extensoes.txt gnome-extensions list
    [ -d "$HOME/.kiro/extensions" ] && inv kiro-extensoes.txt bash -c 'ls "$HOME/.kiro/extensions" | grep -v "\.json$" | sed -E "s/-[0-9][0-9.]*(-.*)?$//"'
    [ -d "$HOME/.nvm/versions/node" ] && inv node-versoes.txt ls "$HOME/.nvm/versions/node"
    command -v uv >/dev/null 2>&1 && inv uv-tools.txt uv tool list
    command -v pipx >/dev/null 2>&1 && inv pipx.txt pipx list --short
    command -v cargo >/dev/null 2>&1 && inv cargo.txt cargo install --list
    command -v conda >/dev/null 2>&1 && inv conda-envs.txt conda env list
    [ -x "$HOME/miniconda3/bin/conda" ] && inv conda-envs.txt "$HOME/miniconda3/bin/conda" env list
    command -v code >/dev/null 2>&1 && inv vscode-extensoes.txt code --list-extensions
    command -v gh >/dev/null 2>&1 && inv gh-extensoes.txt gh extension list
    command -v dconf >/dev/null 2>&1 && inv dconf.ini dconf dump /
    inv crontab.txt crontab -l
    inv systemd-user-enabled.txt systemctl --user list-unit-files --state=enabled --no-pager --no-legend
    inv systemd-sistema-enabled.txt systemctl list-unit-files --state=enabled --no-pager --no-legend
    inv linger.txt loginctl show-user "$(id -un)" -p Linger
    inv dkms-status.txt dkms status
    inv zram.txt zramctl
    inv swap.txt swapon --show
    # shellcheck disable=SC2016
    inv versoes-ferramentas.txt bash -c 'for c in docker node uv gh aws terraform kubectl helm k9s argocd kiro kiro-cli claude gemini rclone tailscale openvpn teamviewer; do printf "%s: " "$c"; ( "$c" --version 2>&1 || "$c" version --client 2>&1 ) | head -1; done'
    # units do usuario que NAO sao symlink (os symlinks para o repo do harness o install.sh recria)
    if [ -d "$HOME/.config/systemd/user" ]; then
        find "$HOME/.config/systemd/user" -maxdepth 2 -type f -printf '%P\n' 2>/dev/null > "$STAGE/$META/inventario/systemd-user-units-proprias.txt" || true
        [ ! -s "$STAGE/$META/inventario/systemd-user-units-proprias.txt" ] && rm -f "$STAGE/$META/inventario/systemd-user-units-proprias.txt"
    fi
}

#------------------------------------------------------------------------------
# Arquivos do sistema (sudo): /etc mudados + perfis de VPN do NetworkManager
#------------------------------------------------------------------------------
SUDO_OK=false
prepara_sudo() {
    if $SEM_SUDO; then SUDO_OK=false; return 0; fi
    if $DRY_RUN; then
        sudo -n true 2>/dev/null && SUDO_OK=true || SUDO_OK=false
    else
        info "Preciso do sudo para ler /etc (VPNs do NetworkManager, zram, DKMS)."
        sudo -v || die "sudo negado; sem ele o backup perderia as VPNs do NetworkManager."
        SUDO_OK=true
    fi
}

ETC_FIXOS=(
    /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.d
    /etc/dkms /etc/docker/daemon.json /etc/hosts
    /etc/NetworkManager/system-connections /etc/NetworkManager/conf.d
    /etc/openvpn /etc/netplan
)
ETC_NAO_PACOTE=(
    /etc/modprobe.d /etc/modules-load.d /etc/sysctl.d /etc/udev/rules.d /etc/apt/sources.list.d
    /etc/apt/preferences.d /etc/apt/apt.conf.d /etc/sudoers.d /etc/ssh/sshd_config.d
    /etc/security/limits.d /etc/systemd/system /etc/systemd/user /etc/systemd/logind.conf.d
)

coleta_sistema() {
    local dest="$STAGE/$META/raiz" p f n=0
    if ! $SUDO_OK; then
        mline "sistema | /etc (zram, DKMS, NetworkManager, modprobe etc.) | NAO LISTADO (sem sudo: use sem --sem-sudo, ou rode "sudo -v" antes do --dry-run)"
        return 0
    fi
    for p in "${ETC_FIXOS[@]}"; do
        sudo test -e "$p" || continue
        if $DRY_RUN; then
            n="$(sudo find "$p" -type f 2>/dev/null | wc -l)"
            mline "sistema | $p | $n arquivos"
        else
            sudo mkdir -p "$dest$(dirname "$p")"
            sudo cp -a "$p" "$dest$(dirname "$p")/" 2>/dev/null || warn "nao copiei $p"
            n="$(sudo find "$dest$p" -type f 2>/dev/null | wc -l)"
            mline "sistema | $p | $n arquivos"
        fi
    done
    for p in "${ETC_NAO_PACOTE[@]}"; do
        [ -d "$p" ] || continue
        n=0
        while IFS= read -r f; do
            # so o que nenhum pacote entrega (config da propria maquina)
            dpkg -S "$f" >/dev/null 2>&1 && continue
            [ -L "$f" ] && continue
            n=$((n+1))
            if ! $DRY_RUN; then
                sudo mkdir -p "$dest$(dirname "$f")"
                sudo cp -a "$f" "$dest$f" 2>/dev/null || warn "nao copiei $f"
            fi
        done < <(sudo find "$p" -maxdepth 1 -type f 2>/dev/null | sort)
        [ "$n" -eq 0 ] || mline "sistema | $p (so arquivos fora de pacote) | $n arquivos"
    done
    if ! $DRY_RUN; then
        sudo chown -R "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
        chmod -R u+rwX,go-rwx "$dest" 2>/dev/null || true
    fi
}

#------------------------------------------------------------------------------
# Monta tudo
#------------------------------------------------------------------------------
info "Destino: $SAIDA"
$DRY_RUN && info "Modo --dry-run: nada sera gravado."

prepara_sudo
# Itens extras da sua maquina (credenciais de trabalho etc.), fora do repo: um caminho
# relativo ao HOME por linha, opcionalmente "grupo|caminho"; # comenta.
EXTRAS_FILE="${BACKUP_EXTRAS_FILE:-$HOME/.config/backup-ubuntu-extras.txt}"
if [ -f "$EXTRAS_FILE" ]; then
    while IFS= read -r linha; do
        linha="${linha%%#*}"; linha="${linha//[$'\r']/}"; [ -n "${linha// /}" ] || continue
        case "$linha" in *"|"*) ITENS+=("$linha") ;; *) ITENS+=("segredos|$linha") ;; esac
    done < "$EXTRAS_FILE"
fi
for it in "${ITENS[@]}"; do adiciona_item "${it%%|*}" "${it#*|}"; done
info "Avaliando ~/projects (git status em cada repo; pode levar alguns minutos)..."
avalia_projetos
coleta_inventarios
coleta_sistema

# Espaco: estimativa sobre o que vai para o tar
EST=0
while IFS= read -r -d '' rel; do
    s="$(du -sb "${DU_EXCL[@]}" "$HOME/$rel" 2>/dev/null | cut -f1 || echo 0)"; EST=$((EST + ${s:-0}))
done < "$LISTA"
LIVRE="$(df -B1 --output=avail "$DESTINO" | tail -1 | tr -d ' ')"
FSTIPO="$(df --output=fstype "$DESTINO" | tail -1 | tr -d ' ')"
[ "$FSTIPO" != "vfat" ] || die "o disco de destino e FAT32 (limite de 4 GB por arquivo). Formate em exFAT ou ext4."

monta_manifesto() {
    local arq_info="${1:-}"
    echo "MANIFESTO DO BACKUP - ubuntu ($NOME)"
    echo "Gerado em: $(date '+%Y-%m-%d %H:%M:%S %z')   script: backup.sh $VERSAO_SCRIPT"
    echo "Maquina: $HOST   usuario: $(id -un)   SO: $(. /etc/os-release; echo "$PRETTY_NAME")   kernel: $(uname -r)"
    echo "Modo: $($DRY_RUN && echo 'DRY-RUN (nada foi gravado)' || echo 'COMPLETO')"
    echo
    echo "== Itens do HOME e sistema (grupo | caminho | arquivos | tamanho) =="
    cat "$MAN"
    echo
    echo "== Projetos em ~/projects =="
    echo "Regra: repo so entra inteiro se tiver mudanca nao enviada, commit nao enviado, sem remoto ou fora do GitHub (os outros so levam os arquivos ignorados pelo git);"
    echo "os demais sao re-clonados no restore. Pasta fora do git entra ate ${PROJ_MAX_MB} MB."
    sort "$PROJ_MAN"
    echo "Resumo: $(grep -c '^INCLUIDO' "$PROJ_MAN" || true) incluidos, $(grep -c '^CLONAR' "$PROJ_MAN" || true) a clonar no setup, $(grep -c '^IGNORADO' "$PROJ_MAN" || true) ignorados"
    echo "Pastas fora do git incluidas: $NAOGIT_N (puladas por tamanho: $NAOGIT_PULADOS)"
    echo "Ignorados pelo git (.env, .tfvars, .pem etc., sem node_modules/.terraform/venv/dist/build/target): $IGN_N itens, $(fmt_bytes "$IGN_BYTES"); pulados por passar de ${IGN_MAX_MB} MB: $IGN_PULADOS"
    echo
    echo "== Inventarios (dentro do tar, em $META/inventario/) =="
    if [ -d "$STAGE/$META/inventario" ]; then
        for f in "$STAGE/$META/inventario"/*; do
            [ -f "$f" ] && printf '%s (%s linhas)\n' "$(basename "$f")" "$(wc -l < "$f")"
        done
    fi
    echo
    echo "== Fora do backup, de proposito =="
    echo "Downloads do HOME (decisao do dono)"
    echo "Padroes excluidos: ${EXCL[*]}"
    echo "Nao salvo (refaz no setup): login do tailscale, login do gh/aws sso, chaves MOK do DKMS, token do Kiro se expirado."
    echo
    echo "== Tamanho =="
    echo "Dados a arquivar (sem compressao): $(fmt_bytes "$EST")   espaco livre no destino: $(fmt_bytes "$LIVRE")   fs: $FSTIPO"
    [ -z "$arq_info" ] || { echo; echo "== Arquivo =="; echo "$arq_info"; }
    echo
    echo "== Restaurar =="
    echo "sha256sum -c SHA256SUMS   (dentro desta pasta)"
    echo "./ubuntu-setup-automated.sh --restore <esta pasta>   (pede a senha na hora)"
}

if $DRY_RUN; then
    monta_manifesto
    [ "$EST" -lt "$LIVRE" ] || warn "o destino tem menos espaco livre que o total a arquivar (sem contar compressao)."
    info "Dry-run concluido. Nada foi gravado."
    exit 0
fi

[ "$EST" -lt "$LIVRE" ] || die "espaco insuficiente em $DESTINO: precisa de ~$(fmt_bytes "$EST") sem compressao, livre $(fmt_bytes "$LIVRE")."

#------------------------------------------------------------------------------
# Copia dos symlinks de topo, sha256 por arquivo e senha
#------------------------------------------------------------------------------
mkdir -p "$STAGE/$META/deref"
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$STAGE/$META/deref/$(dirname "$rel")"
    cp -aL "$HOME/$rel" "$STAGE/$META/deref/$rel"
done < "$DEREF_LIST"

if ! $RAPIDO; then
    info "Calculando sha256 por arquivo (config e segredos)..."
    tar --null "${TAR_EXCL[@]}" -C "$HOME" -T "$LISTA_SHA" -cvf /dev/null 2>/dev/null \
        | grep -v '/$' | tr '\n' '\0' | (cd "$HOME" && xargs -0 -r -n50 sha256sum 2>/dev/null) \
        > "$STAGE/$META/SHA256-ARQUIVOS.txt" || true
fi

cp "$0" "$STAGE/$META/backup.sh.usado" 2>/dev/null || true

if [ ! -t 0 ]; then die "preciso de um terminal para pedir a senha."; fi
read -rs -p "Senha do backup (nao sera gravada): " PASS; echo >&2
read -rs -p "Repita a senha: " PASS2; echo >&2
[ "$PASS" = "$PASS2" ] || die "as senhas nao conferem."
PASS2=""
[ "${#PASS}" -ge 10 ] || die "use uma senha com pelo menos 10 caracteres (o arquivo leva chaves e tokens)."

#------------------------------------------------------------------------------
# Tar -> gpg direto para o disco (sem copia intermediaria em claro)
#------------------------------------------------------------------------------
mkdir -p "$SAIDA.parcial"
ALVO="$SAIDA.parcial/backup.tar.gpg"
info "Arquivando e cifrando (pode levar bastante; ~$(fmt_bytes "$EST"))..."

set +e
tar --null --warning=no-file-changed --warning=no-file-ignored --ignore-failed-read \
    "${TAR_EXCL[@]}" -cf - -C "$HOME" -T "$LISTA" -C "$STAGE" "$META" 2>"$WORK/tar.err" \
  | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric \
        --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
        -z 1 -o "$ALVO" 3< <(printf '%s' "$PASS") 2>"$WORK/gpg.err"
RC=("${PIPESTATUS[@]}")
set -e
PASS=""
if [ "${RC[0]}" -gt 1 ] || [ "${RC[1]}" -ne 0 ]; then
    erro "tar rc=${RC[0]} gpg rc=${RC[1]}"; tail -5 "$WORK/tar.err" "$WORK/gpg.err" >&2 || true
    rm -rf "$SAIDA.parcial"; exit 1
fi
[ "${RC[0]}" -eq 0 ] || warn "tar terminou com aviso (arquivo mudou durante a leitura, normal em ~/.claude); backup valido."

info "Calculando sha256 do arquivo cifrado..."
( cd "$SAIDA.parcial" && sha256sum backup.tar.gpg > SHA256SUMS )
TAM="$(stat -c %s "$ALVO")"
SHA="$(cut -d' ' -f1 "$SAIDA.parcial/SHA256SUMS")"
monta_manifesto "backup.tar.gpg | $(fmt_bytes "$TAM") | sha256 $SHA | cifrado gpg simetrico AES256" > "$SAIDA.parcial/MANIFESTO.txt"
sync
mv "$SAIDA.parcial" "$SAIDA"

info "Conferindo o sha256 gravado..."
( cd "$SAIDA" && sha256sum -c SHA256SUMS >&2 )
info "Pronto: $SAIDA"
info "Guarde a senha fora deste computador. Sem ela o backup nao abre."
