#!/usr/bin/env bash
#==============================================================================
# backup.sh - backup completo e CIFRADO do HOME desta maquina Ubuntu para um
# disco externo (ou qualquer pasta fora do repo).
#
# Uso:
#   ./backup.sh DESTINO [--dry-run] [--sem-sudo] [--rapido] [--excluir CAMINHO]...
#   ./backup.sh --verificar PASTA_DO_BACKUP
#
#   DESTINO            pasta onde o backup sera criado (ex.: o disco externo em
#                      /media/$USER/<disco> ou /run/media/$USER/<disco>). Nunca um repo git.
#                      Aceita ext4, exFAT e NTFS; recusa FAT32 (limite de 4 GB por arquivo).
#   --dry-run          so lista o que entraria e o que fica de fora. Nao pede senha,
#                      nao grava nada no destino.
#   --sem-sudo         nao le /etc nem as VPNs do NetworkManager (sem pedir sudo).
#   --rapido           pula o sha256 por arquivo do grupo "config e segredos"
#                      (o sha256 do arquivo cifrado inteiro sempre e feito).
#   --excluir CAMINHO  caminho (relativo ao HOME) a deixar de fora; repetivel.
#   --verificar PASTA  confere SHA256SUMS, decifra e conta as entradas do tar,
#                      comparando com o MANIFESTO. Rode depois de desmontar e
#                      remontar o disco.
#
# O backup leva o HOME INTEIRO, menos a lista de exclusao (Downloads, cache regeneravel,
# node_modules, venvs, .terraform...). Exclusoes so desta maquina: uma por linha (relativas
# ao HOME, # comenta) em ~/.config/backup-ubuntu-excluir.txt, ou em BACKUP_EXCLUIR_FILE.
#
# Saida em DESTINO/backup-ubuntu-<host>-<data>/:
#   backup.tar.gpg   tar cifrado (gpg simetrico AES256). A senha e pedida na
#                    hora, duas vezes, e nunca e gravada em arquivo, argv ou log.
#   SHA256SUMS       sha256 do backup.tar.gpg (sha256sum -c SHA256SUMS)
#   MANIFESTO.txt    o que foi salvo e o que ficou fora (sem conteudo)
#
# Dentro do tar, .backup-ubuntu-meta/ traz inventarios (pacotes, crontab, units, dconf),
# copias de /etc, perfis de VPN do NetworkManager e o sha256 por arquivo. O
# ubuntu-setup-automated.sh --restore le tudo isso.
#==============================================================================
# shellcheck disable=SC2088,SC2016
# (~ literal nas mensagens; $HOME em aspas simples e expandido pelo bash -c / sh -c de proposito)
set -euo pipefail
umask 077

VERSAO_SCRIPT="2026-11b"
DRY_RUN=false
RAPIDO=false
SEM_SUDO=false
DESTINO=""
VERIFICAR=""
EXCLUIR_ARGS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
erro()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }
die()   { erro "$*"; exit 1; }

uso() { sed -n '2,/^#====.*$/p' "$0" | sed -n '2,36p' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --rapido) RAPIDO=true ;;
        --sem-sudo) SEM_SUDO=true ;;
        --excluir) shift; [ -n "${1:-}" ] || die "--excluir pede um caminho"; EXCLUIR_ARGS+=("$1") ;;
        --verificar) shift; VERIFICAR="${1:-}"; [ -n "$VERIFICAR" ] || die "--verificar pede a pasta do backup" ;;
        -h|--help) uso; exit 0 ;;
        -*) die "opcao desconhecida: $1 (use --help)" ;;
        *) [ -z "$DESTINO" ] || die "so um DESTINO"; DESTINO="$1" ;;
    esac
    shift
done
[ "$(id -u)" -ne 0 ] || die "rode como o seu usuario, nao como root (o sudo e chamado so onde precisa)"

#------------------------------------------------------------------------------
# --verificar: sha256 do arquivo cifrado + decifra e conta entradas do tar
#------------------------------------------------------------------------------
if [ -n "$VERIFICAR" ]; then
    for c in gpg tar sha256sum wc; do command -v "$c" >/dev/null 2>&1 || die "falta o comando: $c"; done
    V="${VERIFICAR%/}"
    [ -d "$V" ] || die "pasta nao existe: $V"
    [ -f "$V/backup.tar.gpg" ] || die "sem backup.tar.gpg em $V"
    [ -f "$V/SHA256SUMS" ] || die "sem SHA256SUMS em $V"
    [ -f "$V/MANIFESTO.txt" ] || die "sem MANIFESTO.txt em $V"
    info "1/2 sha256sum -c SHA256SUMS"
    ( cd "$V" && sha256sum -c SHA256SUMS ) || die "sha256 NAO confere: arquivo corrompido."
    ESPERADO="$(grep -m1 '^Entradas no tar:' "$V/MANIFESTO.txt" | grep -o '[0-9]*$' || true)"
    [ -n "$ESPERADO" ] || die "MANIFESTO sem a linha 'Entradas no tar:'."
    [ -t 0 ] || die "preciso de um terminal para pedir a senha."
    IFS= read -rs -p "Senha do backup: " PASS; echo >&2
    info "2/2 gpg -d | tar -tf - | wc -l (le o arquivo todo; pode levar bastante)"
    LST="$(mktemp "${XDG_RUNTIME_DIR:-/dev/shm}/verifica.XXXXXX")"; trap 'rm -f "$LST"' EXIT
    set +e
    gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d "$V/backup.tar.gpg" 3< <(printf '%s' "$PASS") 2>/dev/null | tar -tf - > "$LST"
    RC=("${PIPESTATUS[@]}")
    set -e
    N="$(wc -l < "$LST" | tr -d ' ')"
    PASS=""
    [ "${RC[0]}" -eq 0 ] && [ "${RC[1]}" -eq 0 ] || die "falha ao decifrar/listar (senha errada? gpg=${RC[0]} tar=${RC[1]})."
    if [ "$N" = "$ESPERADO" ]; then
        info "OK: $N entradas no tar, igual ao MANIFESTO ($ESPERADO). Backup integro e abre com a senha."
        exit 0
    fi
    die "entradas no tar ($N) diferente do MANIFESTO ($ESPERADO)."
fi

[ -n "$DESTINO" ] || { uso; die "informe o DESTINO (ex.: /media/\$USER/<disco>)"; }
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

FSTIPO="$(df --output=fstype "$DESTINO" | tail -1 | tr -d ' ')"
case "$FSTIPO" in
    vfat|msdos|fat|fat32) die "o disco de destino e FAT32 ($FSTIPO; limite de 4 GB por arquivo). Use NTFS, exFAT ou ext4." ;;
    ntfs3|ntfs|ntfs-3g|fuseblk|exfat|ext4|ext3|ext2|xfs|btrfs) ;;
    *) warn "sistema de arquivos do destino nao previsto: $FSTIPO (siga se aceitar arquivos de dezenas de GB)." ;;
esac
LIVRE="$(df -B1 --output=avail "$DESTINO" | tail -1 | tr -d ' ')"

HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date +%Y%m%d-%H%M%S)"
NOME="backup-ubuntu-${HOST}-${STAMP}"
SAIDA="$DESTINO/$NOME"
META=".backup-ubuntu-meta"

# Area de trabalho em tmpfs (RAM, 0700): os segredos copiados com sudo nao tocam o disco.
RUNBASE="${XDG_RUNTIME_DIR:-/dev/shm}"
WORK="$(mktemp -d "$RUNBASE/backup-ubuntu.XXXXXX")"
STAGE="$WORK/stage"
mkdir -p "$STAGE/$META/inventario"
LISTA="$WORK/lista.nul"
LISTA_SHA="$WORK/lista-sha.nul"
: > "$LISTA"; : > "$LISTA_SHA"
MAN="$WORK/manifesto.txt"; : > "$MAN"
FORA="$WORK/fora.txt"; : > "$FORA"
PASS=""
cleanup() { PASS=""; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'erro "falhou na linha $LINENO"' ERR

fmt_bytes() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
mline() { printf '%s\n' "$*" >> "$MAN"; }

#------------------------------------------------------------------------------
# Exclusoes
#------------------------------------------------------------------------------
# Ancoradas no HOME (caminho completo relativo ao HOME)
EXCL_ANC=(
    '.cache' '.local/share/Trash' '.npm' '.cargo/registry'
    '.local/share/containers' '.local/share/docker'
    'snap/*/common/.cache'
    '.aws/sso/cache' '.aws/cli/cache' '.terraform.d/plugin-cache'
    '.nvm/versions'
    '.kiro/crew-venv' '.kiro/.crew-venv-*' '.kiro/crew-python' '.kiro/extensions' '.kiro/logs'
    '.claude/cache' '.claude/shell-snapshots' '.claude/statsig' '.claude/telemetry'
)
# Em qualquer profundidade
EXCL_ANY=(
    'node_modules' '.terraform' '.venv' 'venv' 'venv.bak*' '__pycache__' '.pytest_cache' '.mypy_cache' '*.pyc'
    '.config/google-chrome/*/Cache' '.config/google-chrome/*/Code Cache'
    '.config/google-chrome/*/Service Worker/CacheStorage'
    '.mozilla/*/cache2'
)
# Topo do HOME que ficam de fora: Downloads (decisao do dono) + o arquivo local de exclusoes
TOPO_FORA=('Downloads')
EXCLUIR_FILE="${BACKUP_EXCLUIR_FILE:-$HOME/.config/backup-ubuntu-excluir.txt}"
EXTRA_FORA=()
if [ -f "$EXCLUIR_FILE" ]; then
    while IFS= read -r linha; do
        linha="${linha%%#*}"; linha="${linha//[$'\r']/}"; linha="${linha#"$HOME"/}"; linha="${linha#\~/}"; linha="${linha%/}"
        [ -n "${linha// /}" ] || continue
        EXTRA_FORA+=("$linha")
    done < "$EXCLUIR_FILE"
fi
for a in "${EXCLUIR_ARGS[@]+"${EXCLUIR_ARGS[@]}"}"; do a="${a#"$HOME"/}"; a="${a%/}"; EXTRA_FORA+=("$a"); done
for e in "${EXTRA_FORA[@]+"${EXTRA_FORA[@]}"}"; do
    case "$e" in */*) EXCL_ANC+=("$e") ;; *) TOPO_FORA+=("$e") ;; esac
done

TAR_EXCL=(--anchored)
for p in "${EXCL_ANC[@]}"; do TAR_EXCL+=("--exclude=$p"); done
TAR_EXCL+=(--no-anchored)
for p in "${EXCL_ANY[@]}"; do TAR_EXCL+=("--exclude=$p"); done
DU_EXCL=()
for p in "${EXCL_ANC[@]}" "${EXCL_ANY[@]}"; do
    case "$p" in '*'*) DU_EXCL+=("--exclude=$p") ;; *) DU_EXCL+=("--exclude=*/$p") ;; esac
done

eh_topo_fora() { local t; for t in "${TOPO_FORA[@]}"; do [ "$1" = "$t" ] && return 0; done; return 1; }

#------------------------------------------------------------------------------
# Itens: tudo no topo do HOME, menos a exclusao. Symlink de topo vira tambem copia real.
#------------------------------------------------------------------------------
DEREF_LIST="$STAGE/$META/deref.txt"; : > "$DEREF_LIST"
ERROS_LEITURA="$WORK/erros.txt"; : > "$ERROS_LEITURA"
EST=0

monta_itens() {
    local p rel bytes alvo
    while IFS= read -r -d '' p; do
        rel="${p#"$HOME"/}"
        if eh_topo_fora "$rel"; then continue; fi
        printf '%s\0' "$rel" >> "$LISTA"
        case "$rel" in .ssh|.aws|.kube|.gnupg|.zsh*|.bash*|.profile|.zprofile|.gitconfig|.config|.cert|.docker|.netrc|.npmrc|.claude.json|.terraform.d)
            printf '%s\0' "$rel" >> "$LISTA_SHA" ;; esac
        if [ -L "$p" ]; then
            alvo="$(readlink -f "$p" 2>/dev/null || true)"
            if [ -e "$alvo" ]; then
                bytes="$(du -sb "$alvo" 2>/dev/null | cut -f1 || echo 0)"; bytes="${bytes:-0}"
                if [ "$bytes" -le 209715200 ]; then
                    printf '%s\n' "$rel" >> "$DEREF_LIST"
                    mline "~/$rel (symlink; entra o link e uma copia real) | $(fmt_bytes "$bytes")"
                    EST=$((EST + bytes))
                else
                    printf 'symlink ~/%s aponta para %s (%s, grande demais para copiar: so o link entra)\n' "$rel" "$alvo" "$(fmt_bytes "$bytes")" >> "$ERROS_LEITURA"
                fi
            else
                mline "~/$rel (symlink quebrado; so o link entra)"
            fi
            continue
        fi
        bytes="$(du -sb "${DU_EXCL[@]}" "$p" 2>>"$ERROS_LEITURA" | cut -f1 || true)"; bytes="${bytes:-0}"
        EST=$((EST + bytes))
        mline "~/$rel | $(fmt_bytes "$bytes")"
    done < <(find "$HOME" -mindepth 1 -maxdepth 1 -print0 | sort -z)
}

#------------------------------------------------------------------------------
# Lista de repos de ~/projects (o setup reclona o que faltar; o conteudo ja vai inteiro no tar)
#------------------------------------------------------------------------------
CLONAR="$STAGE/$META/projetos-clonar.tsv"; : > "$CLONAR"
lista_repos() {
    local base="$HOME/projects" g d url rel n=0
    [ -d "$base" ] || return 0
    while IFS= read -r g; do
        d="$(dirname "$g")"
        [ -d "$g" ] || continue
        url="$(timeout 20 git -C "$d" remote get-url origin 2>/dev/null || true)"
        [ -n "$url" ] || continue
        rel="${d#"$HOME"/}"
        printf '%s\t%s\n' "$rel" "$url" >> "$CLONAR"; n=$((n+1))
    done < <(find "$base" -maxdepth 6 -name .git -not -path '*/node_modules/*' -not -path '*/.terraform/*' 2>/dev/null | sort)
    mline "projetos | $n repositorios com remoto (lista para o setup reclonar se precisar; o conteudo entra inteiro)"
}

#------------------------------------------------------------------------------
# FORA DO BACKUP: o que foi excluido, com tamanho
#------------------------------------------------------------------------------
fora_item() { # fora_item rotulo caminho...
    local rot="$1" b=0 p; shift
    local -a ex=()
    for p in "$@"; do [ -e "$p" ] && ex+=("$p"); done
    [ "${#ex[@]}" -gt 0 ] || return 0
    b="$(du -sbc "${ex[@]}" 2>/dev/null | tail -1 | cut -f1 || true)"; b="${b:-0}"
    printf '%s | %s\n' "$rot" "$(fmt_bytes "$b")" >> "$FORA"
}

calcula_fora() {
    local t p
    for t in "${TOPO_FORA[@]}"; do
        if [ "$t" = Downloads ]; then fora_item "~/Downloads (decisao do dono)" "$HOME/Downloads"
        else fora_item "~/$t (exclusao local desta maquina)" "$HOME/$t"; fi
    done
    for p in "${EXCL_ANC[@]}"; do
        case "$p" in
            *'*'*) # padrao com curinga: expande so o que existe
                local -a m=(); local f
                shopt -s nullglob
                for f in "$HOME"/$p; do m+=("$f"); done
                shopt -u nullglob
                if [ "${#m[@]}" -gt 0 ]; then fora_item "~/$p (cache/regeneravel)" "${m[@]}"; fi ;;
            *) fora_item "~/$p (cache/regeneravel)" "$HOME/$p" ;;
        esac
    done
    # Em qualquer profundidade: um find so, agrupado por nome
    local bk="$WORK/fora-busca"; mkdir -p "$bk"
    local -a prune=()
    for t in "${TOPO_FORA[@]}"; do prune+=(-path "$HOME/$t" -o); done
    for p in .cache .npm .local/share/Trash .local/share/containers .local/share/docker; do prune+=(-path "$HOME/$p" -o); done
    prune+=(-path "$HOME/.cargo/registry")
    while IFS= read -r -d '' p; do
        printf '%s\0' "$p" >> "$bk/n-$(basename "$p")"   # prefixo: o glob abaixo nao pega nome com ponto (.venv)
    done < <(find "$HOME" \( "${prune[@]}" \) -prune -o -type d \( -name node_modules -o -name .terraform -o -name .venv -o -name venv -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache \) -prune -print0 2>/dev/null)
    local f nome b
    for f in "$bk"/*; do
        [ -f "$f" ] || continue
        nome="$(basename "$f")"; nome="${nome#n-}"
        b="$(du -sbc --files0-from="$f" 2>/dev/null | tail -1 | cut -f1 || true)"; b="${b:-0}"
        printf '**/%s (em qualquer pasta; .terraform.lock.hcl fica) | %s (%s pastas)\n' "$nome" "$(fmt_bytes "$b")" "$(tr -cd '\0' < "$f" | wc -c)" >> "$FORA"
    done
    fora_item "Cache do Chrome (Cache, Code Cache, Service Worker/CacheStorage)" "$HOME"/.config/google-chrome/*/Cache "$HOME"/.config/google-chrome/*/"Code Cache" "$HOME"/.config/google-chrome/*/"Service Worker"/CacheStorage
    fora_item "Cache do Firefox (cache2)" "$HOME"/.mozilla/*/cache2 "$HOME"/.mozilla/firefox/*/cache2
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
        if [ ! -s "$STAGE/$META/inventario/systemd-user-units-proprias.txt" ]; then rm -f "$STAGE/$META/inventario/systemd-user-units-proprias.txt"; fi
    fi
}

#------------------------------------------------------------------------------
# Arquivos do sistema (sudo): /etc + perfis de VPN do NetworkManager
#------------------------------------------------------------------------------
SUDO_OK=false
prepara_sudo() {
    if $SEM_SUDO; then SUDO_OK=false; return 0; fi
    if $DRY_RUN; then
        if sudo -n true 2>/dev/null; then SUDO_OK=true; else SUDO_OK=false; fi
    else
        info "Preciso do sudo para ler /etc (VPNs do NetworkManager, zram, sudoers, apt, DKMS)."
        sudo -v || die "sudo negado; sem ele o backup perderia as VPNs do NetworkManager."
        SUDO_OK=true
    fi
}

ETC_FIXOS=(
    /etc/NetworkManager/system-connections /etc/NetworkManager/conf.d
    /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.d
    /etc/sudoers.d /etc/apt/sources.list.d /etc/apt/keyrings /etc/apt/trusted.gpg.d
    /etc/dkms /etc/docker/daemon.json /etc/hosts /etc/openvpn /etc/netplan
)
ETC_NAO_PACOTE=(
    /etc/modprobe.d /etc/modules-load.d /etc/sysctl.d /etc/udev/rules.d
    /etc/apt/preferences.d /etc/apt/apt.conf.d /etc/ssh/sshd_config.d
    /etc/security/limits.d /etc/systemd/system /etc/systemd/user /etc/systemd/logind.conf.d
)

coleta_sistema() {
    local dest="$STAGE/$META/raiz" p f n=0
    if ! $SUDO_OK; then
        mline "sistema | /etc (NetworkManager, zram, sudoers, apt, DKMS, modprobe...) | NAO LISTADO (sem sudo: rode sem --sem-sudo, ou 'sudo -v' antes do --dry-run)"
        return 0
    fi
    for p in "${ETC_FIXOS[@]}"; do
        sudo test -e "$p" || continue
        if $DRY_RUN; then
            n="$(sudo find "$p" -type f 2>/dev/null | wc -l)"
        else
            sudo mkdir -p "$dest$(dirname "$p")"
            sudo cp -a "$p" "$dest$(dirname "$p")/" 2>/dev/null || warn "nao copiei $p"
            n="$(sudo find "$dest$p" -type f 2>/dev/null | wc -l)"
        fi
        mline "sistema | $p | $n arquivos"
    done
    for p in "${ETC_NAO_PACOTE[@]}"; do
        [ -d "$p" ] || continue
        n=0
        while IFS= read -r f; do
            # so o que nenhum pacote entrega (config da propria maquina)
            if dpkg -S "$f" >/dev/null 2>&1; then continue; fi
            if [ -L "$f" ]; then continue; fi
            n=$((n+1))
            if ! $DRY_RUN; then
                sudo mkdir -p "$dest$(dirname "$f")"
                sudo cp -a "$f" "$dest$f" 2>/dev/null || warn "nao copiei $f"
            fi
        done < <(sudo find "$p" -maxdepth 1 -type f 2>/dev/null | sort)
        if [ "$n" -gt 0 ]; then mline "sistema | $p (so arquivos fora de pacote) | $n arquivos"; fi
    done
    if ! $DRY_RUN; then
        sudo chown -R "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
        chmod -R u+rwX,go-rwx "$dest" 2>/dev/null || true
    fi
}

#------------------------------------------------------------------------------
# Monta tudo
#------------------------------------------------------------------------------
info "Destino: $SAIDA (fs: $FSTIPO, livre: $(fmt_bytes "$LIVRE"))"
if $DRY_RUN; then info "Modo --dry-run: nada sera gravado."; fi

prepara_sudo
info "Medindo o HOME (du por item; pode levar alguns minutos)..."
monta_itens
lista_repos
coleta_inventarios
coleta_sistema
info "Calculando o que fica FORA do backup..."
calcula_fora

monta_manifesto() {
    local arq_info="${1:-}" entradas="${2:-}"
    echo "MANIFESTO DO BACKUP - ubuntu ($NOME)"
    echo "Gerado em: $(date '+%Y-%m-%d %H:%M:%S %z')   script: backup.sh $VERSAO_SCRIPT"
    # shellcheck disable=SC1091
    echo "Maquina: $HOST   usuario: $(id -un)   SO: $(. /etc/os-release; echo "$PRETTY_NAME")   kernel: $(uname -r)"
    echo "Modo: $($DRY_RUN && echo 'DRY-RUN (nada foi gravado)' || echo 'COMPLETO')"
    echo
    echo "== Itens do HOME (HOME inteiro menos a exclusao) e sistema =="
    cat "$MAN"
    echo
    echo "== Inventarios (dentro do tar, em $META/inventario/) =="
    local f
    for f in "$STAGE/$META/inventario"/*; do
        [ -f "$f" ] && printf '%s (%s linhas)\n' "$(basename "$f")" "$(wc -l < "$f")"
    done
    echo
    echo "== FORA DO BACKUP (excluido de proposito, com tamanho) =="
    sort "$FORA"
    echo "Nao salvo (refaz no setup): login do tailscale, login do gh/aws sso, chaves MOK do DKMS, token do Kiro se expirado."
    echo "Fora do HOME e fora do backup: volumes e imagens do Docker (/var/lib/docker), /opt e /usr/local/bin (bin-fora-do-apt.txt so lista os nomes)."
    echo "Node do nvm (~/.nvm/versions) fica fora: o setup reinstala o Node e os pacotes npm globais da lista."
    echo
    echo "== Tamanho =="
    echo "Dados a arquivar (sem compressao): $(fmt_bytes "$EST")   espaco livre no destino: $(fmt_bytes "$LIVRE")   fs: $FSTIPO"
    [ -z "$entradas" ] || echo "Entradas no tar: $entradas"
    [ -z "$arq_info" ] || { echo; echo "== Arquivo =="; echo "$arq_info"; }
    echo
    echo "== Conferir e restaurar =="
    echo "./backup.sh --verificar <esta pasta>   (depois de desmontar e remontar o disco)"
    echo "./ubuntu-setup-automated.sh --restore <esta pasta>   (pede a senha na hora)"
}

imprime_fora() {
    echo
    echo "=============== FORA DO BACKUP ==============="
    sort "$FORA"
    echo "=============================================="
}

if $DRY_RUN; then
    monta_manifesto
    imprime_fora
    [ "$EST" -lt "$LIVRE" ] || warn "o destino tem menos espaco livre que o total a arquivar (sem contar compressao)."
    info "Total estimado a arquivar (sem compressao): $(fmt_bytes "$EST"). Dry-run concluido. Nada foi gravado."
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
    cp -aL "$HOME/$rel" "$STAGE/$META/deref/$rel" || printf 'nao copiei o alvo do symlink ~/%s\n' "$rel" >> "$ERROS_LEITURA"
done < "$DEREF_LIST"

if ! $RAPIDO; then
    info "Calculando sha256 por arquivo (config e segredos)..."
    tar --null "${TAR_EXCL[@]}" -C "$HOME" -T "$LISTA_SHA" -cvf /dev/null 2>/dev/null \
        | grep -v '/$' | tr '\n' '\0' \
        | (cd "$HOME" && xargs -0 -r sh -c 'for f; do [ -f "$f" ] && [ ! -L "$f" ] && printf "%s\0" "$f"; done; exit 0' _ \
            | xargs -0 -r -n50 sha256sum 2>>"$ERROS_LEITURA") \
        > "$STAGE/$META/SHA256-ARQUIVOS.txt" || true
fi

cp "$0" "$STAGE/$META/backup.sh.usado" 2>/dev/null || true

if [ ! -t 0 ]; then die "preciso de um terminal para pedir a senha."; fi
IFS= read -rs -p "Senha do backup (nao sera gravada): " PASS; echo >&2
IFS= read -rs -p "Repita a senha: " PASS2; echo >&2
[ "$PASS" = "$PASS2" ] || die "as senhas nao conferem."
PASS2=""
[ "${#PASS}" -ge 10 ] || die "use uma senha com pelo menos 10 caracteres (o arquivo leva chaves e tokens)."

#------------------------------------------------------------------------------
# Tar -> gpg direto para o disco (sem copia intermediaria em claro)
#------------------------------------------------------------------------------
mkdir -p "$SAIDA.parcial"
ALVO="$SAIDA.parcial/backup.tar.gpg"
INDICE="$WORK/indice.txt"
info "Arquivando e cifrando (pode levar bastante; ~$(fmt_bytes "$EST") sem compressao)..."

# Sem --ignore-failed-read: arquivo ilegivel vira erro listado no fim (tar rc 2), nunca silencio.
trap - ERR
set +e
# --hard-dereference: hardlink entra como arquivo proprio (no restore de 06/11 o .git/index era hardlink de outro
# arquivo e virou o conteudo dele).
tar --null --hard-dereference --warning=no-file-changed --warning=no-file-ignored --index-file="$INDICE" -v \
    "${TAR_EXCL[@]}" -cf - -C "$HOME" -T "$LISTA" -C "$STAGE" "$META" 2>"$WORK/tar.err" \
  | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric \
        --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
        -z 1 -o "$ALVO" 3< <(printf '%s' "$PASS") 2>"$WORK/gpg.err"
RC=("${PIPESTATUS[@]}")
set -e
trap 'erro "falhou na linha $LINENO"' ERR
PASS=""
if [ "${RC[0]}" -gt 2 ] || [ "${RC[1]}" -ne 0 ]; then
    erro "tar rc=${RC[0]} gpg rc=${RC[1]}"; tail -5 "$WORK/tar.err" "$WORK/gpg.err" >&2 || true
    rm -rf "$SAIDA.parcial"; exit 1
fi
if [ "${RC[0]}" -ne 0 ] && [ -s "$WORK/tar.err" ]; then cat "$WORK/tar.err" >> "$ERROS_LEITURA"; fi
ENTRADAS="$(wc -l < "$INDICE" | tr -d ' ')"

info "Calculando sha256 do arquivo cifrado..."
( cd "$SAIDA.parcial" && sha256sum backup.tar.gpg > SHA256SUMS )
TAM="$(stat -c %s "$ALVO")"
SHA="$(cut -d' ' -f1 "$SAIDA.parcial/SHA256SUMS")"
{
    monta_manifesto "backup.tar.gpg | $(fmt_bytes "$TAM") | sha256 $SHA | cifrado gpg simetrico AES256" "$ENTRADAS"
    if [ -s "$ERROS_LEITURA" ]; then echo; echo "== ERROS DE LEITURA (nao entraram) =="; cat "$ERROS_LEITURA"; fi
} > "$SAIDA.parcial/MANIFESTO.txt"
sync
mv "$SAIDA.parcial" "$SAIDA"

info "Conferindo o sha256 gravado..."
( cd "$SAIDA" && sha256sum -c SHA256SUMS >&2 )

imprime_fora
if [ -s "$ERROS_LEITURA" ]; then
    echo
    erro "ERROS DE LEITURA (o backup foi gravado, mas estes itens NAO entraram):"
    cat "$ERROS_LEITURA" >&2
    erro "Corrija (permissao/dono) e rode de novo antes de apagar a maquina. Saida: $SAIDA"
    exit 1
fi
info "Pronto: $SAIDA  ($ENTRADAS entradas no tar, $(fmt_bytes "$TAM"))"
info "Depois de desmontar e remontar o disco: ./backup.sh --verificar $SAIDA"
info "Guarde a senha fora deste computador. Sem ela o backup nao abre."
