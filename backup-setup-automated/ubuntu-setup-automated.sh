#!/usr/bin/env bash
#==============================================================================
# ubuntu-setup-automated.sh - setup de uma maquina Ubuntu 26.04 LTS do zero
# (dev/DevOps + harness de agentes), idempotente.
#
# Uso:
#   ./ubuntu-setup-automated.sh [opcoes]
#
#   --restore CAMINHO   restaura o backup cifrado gerado pelo backup.sh.
#                       CAMINHO e a pasta backup-ubuntu-<host>-<data> (ou o
#                       backup.tar.gpg dentro dela). A senha e pedida na hora.
#   --auto-restore      procura backup-ubuntu-* em /media/$USER/* e usa o mais novo.
#   --sem-harness       nao clona o dotfiles-claude nem roda o install.sh dele.
#   --sem-displaylink   pula o driver DisplayLink (dock USB).
#   --sem-projetos      no restore, nao re-clona os repos de ~/projects.
#   --pular ETAPA       pula uma etapa (repetivel). Nomes: apt docker node uv gh aws
#                       terraform kubectl cli-extra kiro claude rclone tailscale vpn apps
#                       displaylink zram playwright shell harness
#   --so ETAPA          roda so a etapa (repetivel; "restore" tambem vale).
#   --listar            lista as etapas e sai.
#   -h, --help
#
# Variaveis opcionais: GIT_USER_NAME, GIT_USER_EMAIL (so usadas se o backup nao
# trouxe o ~/.gitconfig), ZRAM_ALGO_0/ZRAM_ALGO_1, ZRAM_MB_0/ZRAM_MB_1,
# SWAP_FILE_GB (padrao 8), NODE_MAJOR (padrao 24), PY_VERSAO (padrao 3.12).
#
# Cada etapa checa o estado antes de agir: rodar de novo nao reinstala nem
# sobrescreve nada. Falha numa etapa e registrada e o script segue; o resumo no
# fim mostra o que falhou.
#==============================================================================
# shellcheck disable=SC2015,SC2016,SC2012
# (A && B || C e usado de proposito para logar aviso e seguir; aspas simples em sh -c; ls -dt em glob de /media)
set -uo pipefail

NODE_MAJOR="${NODE_MAJOR:-24}"
PY_VERSAO="${PY_VERSAO:-3.12}"
SWAP_FILE_GB="${SWAP_FILE_GB:-8}"
ZRAM_MB_0="${ZRAM_MB_0:-4096}"; ZRAM_ALGO_0="${ZRAM_ALGO_0:-lzo-rle}"
ZRAM_MB_1="${ZRAM_MB_1:-4096}"; ZRAM_ALGO_1="${ZRAM_ALGO_1:-zstd}"
HARNESS_REPO="${HARNESS_REPO:-git@github.com:ymussi/dotfiles-claude.git}"
HARNESS_DIR="${HARNESS_DIR:-$HOME/projects/dotfiles-claude}"
META=".backup-ubuntu-meta"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
erro()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }
skip()  { echo -e "${BLUE}[OK-JA-FEITO]${NC} $*"; }
secao() { echo; echo "=== $* ==="; }

export DEBIAN_FRONTEND=noninteractive
TMO() { timeout "$@"; }

ETAPAS=(apt docker node uv gh aws terraform kubectl cli-extra kiro claude rclone tailscale vpn apps displaylink zram playwright shell restore harness)
RESTORE_ARG=""; AUTO_RESTORE=false; SEM_PROJ=false
declare -A PULAR=() SO=()
FALHAS=()

uso() { sed -n '2,/^#====.*$/p' "$0" | sed -n '2,32p' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --restore) shift; RESTORE_ARG="${1:-}"; [ -n "$RESTORE_ARG" ] || { erro "--restore pede um caminho"; exit 2; } ;;
        --auto-restore) AUTO_RESTORE=true ;;
        --sem-harness) PULAR[harness]=1 ;;
        --sem-displaylink) PULAR[displaylink]=1 ;;
        --sem-projetos) SEM_PROJ=true ;;
        --pular) shift; PULAR["${1:-}"]=1 ;;
        --so) shift; SO["${1:-}"]=1 ;;
        --listar) printf '%s\n' "${ETAPAS[@]}"; exit 0 ;;
        -h|--help) uso; exit 0 ;;
        *) erro "opcao desconhecida: $1"; uso; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || { erro "rode como seu usuario (o sudo e chamado onde precisa)."; exit 1; }
[ -r /etc/os-release ] || { erro "sem /etc/os-release"; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { erro "script feito para Ubuntu (achei: ${ID:-?})"; exit 1; }
CODENAME="${VERSION_CODENAME:-resolute}"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) ARCH_ALT=x86_64; ARCH_GO=amd64 ;; arm64) ARCH_ALT=aarch64; ARCH_GO=arm64 ;; *) erro "arquitetura nao suportada: $ARCH"; exit 1 ;; esac
[ "${VERSION_ID%%.*}" -ge 24 ] || warn "pensado para o Ubuntu 26.04 (achei $VERSION_ID); pode funcionar, nao foi testado."
[ "${VERSION_ID:-}" = "26.04" ] || warn "versao $VERSION_ID (alvo: 26.04)."

executa_etapa() { # executa_etapa nome funcao
    local nome="$1" fn="$2"
    if [ ${#SO[@]} -gt 0 ] && [ -z "${SO[$nome]:-}" ]; then return 0; fi
    if [ -n "${PULAR[$nome]:-}" ]; then skip "etapa pulada: $nome"; return 0; fi
    secao "$nome"
    if ! "$fn"; then warn "etapa com falha: $nome"; FALHAS+=("$nome"); fi
}

tem() { command -v "$1" >/dev/null 2>&1; }
pkg_instalado() { dpkg -s "$1" >/dev/null 2>&1; }
apt_i() { sudo apt-get install -y --no-install-recommends "$@"; }
apt_faltantes() { # imprime so os pacotes que ainda nao estao instalados e existem no repo
    local p
    for p in "$@"; do
        pkg_instalado "$p" && continue
        apt-cache show "$p" >/dev/null 2>&1 && printf '%s\n' "$p" || warn "pacote nao existe no repo: $p"
    done
}
apt_garante() {
    local falt; falt="$(apt_faltantes "$@")"
    [ -z "$falt" ] && return 0
    # shellcheck disable=SC2086
    TMO 1200 sudo apt-get install -y --no-install-recommends $falt
}
# Repo apt de terceiro: baixa a chave e grava o .sources so se ainda nao existe.
repo_apt() { # repo_apt nome url_chave uris suites components [arch]
    local nome="$1" chave="$2" uris="$3" suites="$4" comps="$5" f="/etc/apt/sources.list.d/$1.sources"
    [ -f "$f" ] && { skip "repo apt $nome"; return 0; }
    sudo install -d -m 0755 /etc/apt/keyrings
    local tmp ext=asc; tmp="$(mktemp)"
    TMO 60 curl -fsSL "$chave" -o "$tmp" || { rm -f "$tmp"; return 1; }
    head -c 12 "$tmp" | grep -q 'BEGIN PGP' || ext=gpg   # chave binaria (dearmored) pede .gpg
    sudo install -m 0644 "$tmp" "/etc/apt/keyrings/$nome.$ext"; rm -f "$tmp"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/%s.%s\n' \
        "$uris" "$suites" "$comps" "$ARCH" "$nome" "$ext" | sudo tee "$f" >/dev/null
    APT_SUJO=true
}
# O repo de terceiro pode ainda nao ter a suite do release novo: cai para a anterior (noble).
suite_ou_fallback() { # suite_ou_fallback url_Release
    if TMO 20 curl -fsI "$1" >/dev/null 2>&1; then echo "$CODENAME"; else echo noble; fi
}
APT_SUJO=false
apt_update_se_sujo() { if $APT_SUJO; then TMO 600 sudo apt-get update -y && APT_SUJO=false; fi; }

baixa() { TMO "${3:-300}" curl -fsSL --retry 3 -o "$2" "$1"; }
gh_tag() { TMO 30 curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | grep -oP '"tag_name": *"\K[^"]+' | head -1; }
tmpd() { mktemp -d "${TMPDIR:-/tmp}/setup.XXXXXX"; }

#==============================================================================
# 1. APT: base, atualizacao e ferramentas de uso diario
#==============================================================================
etapa_apt() {
    sudo -v || return 1
    TMO 900 sudo apt-get update -y || return 1
    TMO 1800 sudo apt-get upgrade -y || warn "upgrade com aviso"
    # base e build
    apt_garante build-essential git curl wget ca-certificates gnupg unzip zip jq tmux zsh vim \
        software-properties-common apt-transport-https lsb-release pkg-config openssl age \
        ripgrep fd-find fzf tree htop net-tools dnsutils iproute2 rsync xclip \
        openssh-client openssh-server gpg-agent dconf-cli \
        python3 python3-venv python3-pip python3-dev pipx \
        dkms "linux-headers-$(uname -r)" linux-headers-generic \
        libfuse2t64 fuse3 \
        network-manager network-manager-openvpn network-manager-openvpn-gnome openvpn \
        ffmpeg libportaudio2 libsndfile1 espeak-ng pulseaudio-utils v4l-utils \
        libnss3-tools bash-completion shellcheck remmina remmina-plugin-rdp fastfetch
    # curl de snap/apt pode faltar zsh plugins: tratados na etapa shell
    return 0
}

#==============================================================================
# 2. Docker (repo oficial; cai para a suite noble se a nova ainda nao existe)
#==============================================================================
etapa_docker() {
    if ! tem docker; then
        local suite; suite="$(suite_ou_fallback "https://download.docker.com/linux/ubuntu/dists/$CODENAME/Release")"
        repo_apt docker https://download.docker.com/linux/ubuntu/gpg https://download.docker.com/linux/ubuntu "$suite" stable || return 1
        apt_update_se_sujo || return 1
        TMO 1200 sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    else skip "docker $(docker --version 2>/dev/null | cut -d, -f1)"; fi
    sudo systemctl enable --now docker 2>/dev/null || true
    id -nG "$USER" | tr ' ' '\n' | grep -qx docker || { sudo usermod -aG docker "$USER" && warn "grupo docker adicionado: faca logout/login para valer."; }
    return 0
}

#==============================================================================
# 3. Node (nvm, para os CLIs globais) e Node do sistema via NodeSource
#==============================================================================
etapa_node() {
    export NVM_DIR="$HOME/.nvm"
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        local tag; tag="$(gh_tag nvm-sh/nvm)"; tag="${tag:-v0.40.3}"
        TMO 300 bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh | PROFILE=/dev/null bash" || return 1
    else skip "nvm"; fi
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    if ! nvm ls "$NODE_MAJOR" >/dev/null 2>&1; then TMO 600 nvm install "$NODE_MAJOR" || return 1; else skip "node $NODE_MAJOR no nvm"; fi
    nvm alias default "$NODE_MAJOR" >/dev/null 2>&1 || true
    # Node do sistema (usado por servicos systemd que nao carregam o nvm)
    if ! pkg_instalado nodejs; then
        repo_apt nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key "https://deb.nodesource.com/node_${NODE_MAJOR}.x" nodistro main || return 1
        apt_update_se_sujo || return 1
        TMO 900 sudo apt-get install -y nodejs || return 1
    else skip "nodejs do sistema"; fi
    return 0
}

#==============================================================================
# 4. uv + Python 3.12 do uv (as venvs do Jarvis nao usam o Python 3.14 do sistema)
#==============================================================================
etapa_uv() {
    if ! tem uv && [ ! -x "$HOME/.local/bin/uv" ]; then
        TMO 300 bash -c 'curl -fsSL https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh' || return 1
    else skip "uv"; fi
    export PATH="$HOME/.local/bin:$PATH"
    if ! uv python find "$PY_VERSAO" >/dev/null 2>&1; then TMO 600 uv python install "$PY_VERSAO" || return 1; else skip "python $PY_VERSAO (uv)"; fi
    # As venvs exatas (versao e hashes fixos) sao criadas pelo install.sh do harness (voz-ambiente).
    return 0
}

#==============================================================================
# 5. gh, aws cli v2, terraform, kubectl e utilitarios de cluster
#==============================================================================
etapa_gh() {
    if ! tem gh; then
        repo_apt github-cli https://cli.github.com/packages/githubcli-archive-keyring.gpg https://cli.github.com/packages stable main || return 1
        apt_update_se_sujo || return 1
        TMO 600 sudo apt-get install -y gh || return 1
    else skip "gh"; fi
    return 0
}

etapa_aws() {
    if tem aws && aws --version 2>&1 | grep -q 'aws-cli/2'; then skip "aws cli v2"; else
        local d; d="$(tmpd)"
        baixa "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_ALT}.zip" "$d/aws.zip" 600 || return 1
        unzip -q "$d/aws.zip" -d "$d" && TMO 300 sudo "$d/aws/install" --update || return 1
        rm -rf "$d"
    fi
    if ! tem session-manager-plugin; then
        local d; d="$(tmpd)"
        local arq=ubuntu_64bit; [ "$ARCH" = arm64 ] && arq=ubuntu_arm64
        if baixa "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$arq/session-manager-plugin.deb" "$d/ssm.deb" 300; then
            sudo apt-get install -y "$d/ssm.deb" || warn "session-manager-plugin nao instalou"
        else warn "nao baixei o session-manager-plugin"; fi
        rm -rf "$d"
    else skip "session-manager-plugin"; fi
    return 0
}

etapa_terraform() {
    if ! tem terraform; then
        local suite; suite="$(suite_ou_fallback "https://apt.releases.hashicorp.com/dists/$CODENAME/Release")"
        repo_apt hashicorp https://apt.releases.hashicorp.com/gpg https://apt.releases.hashicorp.com "$suite" main || return 1
        apt_update_se_sujo || return 1
        TMO 600 sudo apt-get install -y terraform || return 1
    else skip "terraform"; fi
    # CLI de login do Terraform Cloud: o token vem do backup (~/.terraform.d/credentials.tfrc.json)
    [ -f "$HOME/.terraform.d/credentials.tfrc.json" ] || warn "sem credentials.tfrc.json: rode 'terraform login' ou restaure o backup."
    return 0
}

etapa_kubectl() {
    local bin=/usr/local/bin
    if ! tem kubectl; then
        local v d; v="$(TMO 30 curl -fsSL https://dl.k8s.io/release/stable.txt)" || return 1
        d="$(tmpd)"
        baixa "https://dl.k8s.io/release/$v/bin/linux/$ARCH_GO/kubectl" "$d/kubectl" 300 || return 1
        baixa "https://dl.k8s.io/release/$v/bin/linux/$ARCH_GO/kubectl.sha256" "$d/kubectl.sha256" 60 || return 1
        ( cd "$d" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - >/dev/null ) || { erro "sha256 do kubectl nao confere"; return 1; }
        sudo install -m 0755 "$d/kubectl" "$bin/kubectl"; rm -rf "$d"
    else skip "kubectl"; fi
    if ! tem helm; then
        local d; d="$(tmpd)"
        baixa https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 "$d/get-helm" 60 && TMO 300 bash "$d/get-helm" || warn "helm nao instalou"
        rm -rf "$d"
    else skip "helm"; fi
    if ! tem k9s; then
        local tag d; tag="$(gh_tag derailed/k9s)"; d="$(tmpd)"
        if [ -n "$tag" ] && baixa "https://github.com/derailed/k9s/releases/download/$tag/k9s_Linux_${ARCH_GO}.tar.gz" "$d/k9s.tgz" 300; then
            tar -xzf "$d/k9s.tgz" -C "$d" k9s && sudo install -m 0755 "$d/k9s" "$bin/k9s"
        else warn "k9s nao instalou"; fi
        rm -rf "$d"
    else skip "k9s"; fi
    if ! tem argocd; then
        local d; d="$(tmpd)"
        baixa "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-$ARCH_GO" "$d/argocd" 300 \
            && sudo install -m 0755 "$d/argocd" "$bin/argocd" || warn "argocd nao instalou"
        rm -rf "$d"
    else skip "argocd"; fi
    return 0
}

#==============================================================================
# 6b. CLIs extras (binarios de release do GitHub, sem repo apt)
#==============================================================================
instala_release() { # instala_release comando repo asset(@TAG@=tag, @VER@=tag sem v) binario
    local cmd="$1" repo="$2" asset="$3" bin="$4" tag d url
    tem "$cmd" && { skip "$cmd"; return 0; }
    tag="$(gh_tag "$repo")"; [ -n "$tag" ] || { warn "sem tag de $repo (rate limit do GitHub?)"; return 1; }
    asset="${asset//@TAG@/$tag}"; asset="${asset//@VER@/${tag#v}}"
    url="https://github.com/$repo/releases/download/$tag/$asset"
    d="$(tmpd)"
    if baixa "$url" "$d/a" 300 && tar -xzf "$d/a" -C "$d" "$bin" 2>/dev/null; then
        sudo install -m 0755 "$d/$bin" "/usr/local/bin/$bin"
    else warn "$cmd nao instalou ($url)"; rm -rf "$d"; return 1; fi
    rm -rf "$d"
}

etapa_cli_extra() {
    local rc=0
    instala_release stern stern/stern "stern_@VER@_linux_${ARCH_GO}.tar.gz" stern || rc=1
    instala_release lazygit jesseduffield/lazygit "lazygit_@VER@_Linux_${ARCH_ALT}.tar.gz" lazygit || rc=1
    instala_release trivy aquasecurity/trivy "trivy_@VER@_Linux-64bit.tar.gz" trivy || rc=1
    instala_release actionlint rhysd/actionlint "actionlint_@VER@_linux_${ARCH_GO}.tar.gz" actionlint || rc=1
    if ! tem kubectx; then
        [ -d /opt/kubectx ] || sudo git clone -q --depth 1 https://github.com/ahmetb/kubectx /opt/kubectx || rc=1
        sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx; sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
    else skip "kubectx"; fi
    return $rc
}

#==============================================================================
# 7b. Aplicativos de desktop: Chrome, VS Code, snaps (Slack, Spotify, Postman, btop, DBeaver)
#     Kiro IDE: instalar a mao pelo instalador do site (nao ha repo apt estavel verificado).
#==============================================================================
etapa_apps() {
    local rc=0
    if ! tem google-chrome; then
        repo_apt google-chrome https://dl.google.com/linux/linux_signing_key.pub http://dl.google.com/linux/chrome/deb stable main || return 1
        apt_update_se_sujo || return 1
        TMO 900 sudo apt-get install -y google-chrome-stable || rc=1
    else skip "google-chrome"; fi
    if ! tem code; then
        repo_apt vscode https://packages.microsoft.com/keys/microsoft.asc https://packages.microsoft.com/repos/code stable main || return 1
        apt_update_se_sujo || return 1
        TMO 900 sudo apt-get install -y code || rc=1
    else skip "vscode"; fi
    local app flag
    for app in slack spotify postman btop dbeaver-ce; do
        snap list "$app" >/dev/null 2>&1 && { skip "snap $app"; continue; }
        flag=""; [ "$app" = slack ] && flag="--classic"
        # shellcheck disable=SC2086
        TMO 900 sudo snap install "$app" $flag || { warn "snap $app falhou"; rc=1; }
    done
    return $rc
}

#==============================================================================
# 6. Kiro CLI e Claude Code (instaladores oficiais, em ~/.local)
#==============================================================================
etapa_kiro() {
    if tem kiro-cli || [ -x "$HOME/.local/bin/kiro-cli" ]; then skip "kiro-cli"; else
        TMO 600 bash -c 'curl -fsSL https://cli.kiro.dev/install | bash' || return 1
    fi
    warn "Kiro CLI: login com 'kiro-cli login' (o backup traz o token, mas ele pode ter expirado)."
    return 0
}

etapa_claude() {
    if tem claude || [ -x "$HOME/.local/bin/claude" ]; then skip "claude code"; else
        TMO 600 bash -c 'curl -fsSL https://claude.ai/install.sh | bash' || return 1
    fi
    return 0
}

#==============================================================================
# 7. rclone, Tailscale, openvpn (3 e NetworkManager)
#==============================================================================
etapa_rclone() {
    if tem rclone; then skip "rclone"; return 0; fi
    apt_garante rclone || return 1
    # O rclone do apt pode estar atrasado: se a versao nao suportar o remote do backup, use rclone selfupdate.
    return 0
}

etapa_tailscale() {
    if ! tem tailscale; then
        local suite; suite="$(suite_ou_fallback "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.noarmor.gpg")"
        repo_apt tailscale "https://pkgs.tailscale.com/stable/ubuntu/$suite.noarmor.gpg" https://pkgs.tailscale.com/stable/ubuntu "$suite" main || return 1
        apt_update_se_sujo || return 1
        TMO 600 sudo apt-get install -y tailscale || return 1
    else skip "tailscale"; fi
    sudo systemctl enable --now tailscaled 2>/dev/null || true
    tailscale status >/dev/null 2>&1 || warn "Tailscale sem login: rode 'sudo tailscale up'."
    return 0
}

etapa_vpn() {
    # openvpn3 (cliente com sessoes) e os pacotes do NetworkManager ja vieram na etapa apt.
    if ! pkg_instalado openvpn3; then
        local suite; suite="$(suite_ou_fallback "https://packages.openvpn.net/openvpn3/debian/dists/$CODENAME/Release")"
        repo_apt openvpn3 https://packages.openvpn.net/packages-repo.gpg https://packages.openvpn.net/openvpn3/debian "$suite" main || return 1
        apt_update_se_sujo || return 1
        TMO 600 sudo apt-get install -y openvpn3 || warn "openvpn3 nao instalou"
    else skip "openvpn3"; fi
    return 0
}

#==============================================================================
# 8. DisplayLink (dock USB): evdi por DKMS com o conserto de 04/11
#    O pacote muda de build mantendo o numero do kernel, o DKMS acha que o evdi
#    ja esta instalado e nao recompila; o modulo velho e recusado (Exec format
#    error) e o serviço entra em laco. O conserto: parar o servico, remover o evdi,
#    recompilar para o kernel em uso, depmod, modprobe, subir o servico.
#==============================================================================
conserta_evdi() {
    local k; k="$(uname -r)"
    local src ver
    src="$(find /usr/src -maxdepth 1 -name 'evdi-*' -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)"
    [ -n "$src" ] || { warn "fontes do evdi nao encontradas em /usr/src"; return 1; }
    ver="${src#evdi-}"
    if lsmod | grep -q '^evdi ' && systemctl is-active --quiet displaylink-driver.service 2>/dev/null; then
        skip "evdi carregado e displaylink-driver ativo"; return 0
    fi
    info "recompilando evdi $ver para $k"
    sudo systemctl stop displaylink-driver.service 2>/dev/null || true
    sudo modprobe -r evdi 2>/dev/null || true
    sudo dkms remove "evdi/$ver" --all >/dev/null 2>&1 || true
    sudo find "/lib/modules/$k" -name 'evdi.ko*' -delete 2>/dev/null || true
    TMO 900 sudo dkms install "evdi/$ver" -k "$k" || { erro "dkms install falhou (o evdi $ver pode nao suportar o kernel $k)"; return 1; }
    sudo depmod -a "$k"
    sudo modprobe evdi || { erro "modprobe evdi falhou"; return 1; }
    sudo systemctl start displaylink-driver.service 2>/dev/null || true
    systemctl is-active --quiet displaylink-driver.service && info "evdi carregado, displaylink ativo" || warn "displaylink-driver nao ficou ativo"
    return 0
}

etapa_displaylink() {
    if ! pkg_instalado displaylink-driver; then
        # Repo oficial da Synaptics (DisplayLink): o pacote de chaves vem do proprio site
        local d; d="$(tmpd)"
        baixa https://www.synaptics.com/sites/default/files/Ubuntu/pool/stable/main/all/synaptics-repository-keyring.deb "$d/k.deb" 120 \
            && sudo apt-get install -y "$d/k.deb" || { rm -rf "$d"; return 1; }
        rm -rf "$d"
        TMO 600 sudo apt-get update -y || return 1
        TMO 1800 sudo apt-get install -y displaylink-driver || return 1
    else skip "displaylink-driver"; fi
    # Secure Boot ligado exige assinar o modulo (MOK). Aviso so, nao da para automatizar sem reboot.
    if tem mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        warn "Secure Boot ligado: o DKMS vai pedir para cadastrar a chave MOK no proximo boot (tela azul)."
    fi
    conserta_evdi
}

#==============================================================================
# 9. zram (8 GB: zram0 4 GB lzo-rle + zram1 4 GB zstd) e swap em disco
#==============================================================================
etapa_zram() {
    apt_garante systemd-zram-generator || return 1
    local conf=/etc/systemd/zram-generator.conf novo
    novo="$(printf '[zram0]\nzram-size = %s\ncompression-algorithm = %s\nswap-priority = 100\n\n[zram1]\nzram-size = %s\ncompression-algorithm = %s\nswap-priority = 100\n' \
        "$ZRAM_MB_0" "$ZRAM_ALGO_0" "$ZRAM_MB_1" "$ZRAM_ALGO_1")"
    if [ -f "$conf" ] && [ "$(sudo cat "$conf")" = "$novo" ]; then skip "zram-generator.conf"; else
        printf '%s\n' "$novo" | sudo tee "$conf" >/dev/null
        sudo systemctl daemon-reload
    fi
    local u
    for u in systemd-zram-setup@zram0.service systemd-zram-setup@zram1.service; do
        systemctl is-active --quiet "$u" 2>/dev/null || sudo systemctl start "$u" 2>/dev/null || warn "nao subiu $u (confira no proximo boot)"
    done
    # swap em disco: o instalador do Ubuntu cria /swap.img; so ajusta se o tamanho divergir.
    if [ -f /swap.img ]; then
        local atual alvo; atual="$(sudo stat -c %s /swap.img)"; alvo=$((SWAP_FILE_GB * 1073741824))
        if [ "$atual" -ne "$alvo" ]; then
            info "ajustando /swap.img para ${SWAP_FILE_GB}G"
            sudo swapoff /swap.img 2>/dev/null || true
            sudo rm -f /swap.img && sudo fallocate -l "${SWAP_FILE_GB}G" /swap.img && sudo chmod 600 /swap.img \
                && sudo mkswap /swap.img >/dev/null && sudo swapon /swap.img || return 1
        else skip "/swap.img ${SWAP_FILE_GB}G"; fi
    else
        info "criando /swap.img de ${SWAP_FILE_GB}G"
        sudo fallocate -l "${SWAP_FILE_GB}G" /swap.img && sudo chmod 600 /swap.img && sudo mkswap /swap.img >/dev/null \
            && sudo swapon /swap.img || return 1
    fi
    grep -qE '^/swap\.img[[:space:]]' /etc/fstab || echo '/swap.img none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    return 0
}

#==============================================================================
# 10. Playwright e as libs do WebKit (faltam no 26.04)
#==============================================================================
etapa_playwright() {
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    tem npx || { warn "npx ausente (etapa node)"; return 1; }
    TMO 900 npx --yes playwright-core install-deps webkit chromium || return 1
    return 0
}

#==============================================================================
# 11. Shell: oh-my-zsh + plugins, zsh como padrao, fzf, git
#==============================================================================
etapa_shell() {
    [ -d "$HOME/.oh-my-zsh" ] || TMO 300 sh -c 'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"' || warn "oh-my-zsh nao instalou"
    local zc="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}" p
    for p in zsh-users/zsh-syntax-highlighting zsh-users/zsh-autosuggestions; do
        local n="${p#*/}"
        [ -d "$zc/plugins/$n" ] && skip "plugin $n" || TMO 120 git clone --depth 1 "https://github.com/$p" "$zc/plugins/$n" || warn "plugin $n nao clonou"
    done
    [ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ] || { sudo chsh -s "$(command -v zsh)" "$USER" && info "shell padrao: zsh (vale no proximo login)"; }
    [ -f "$HOME/.fzf.zsh" ] || true
    # git: identidade vem do ~/.gitconfig do backup; sem backup, usa as variaveis opcionais
    if [ -z "$(git config --global user.name 2>/dev/null)" ] && [ -n "${GIT_USER_NAME:-}" ]; then git config --global user.name "$GIT_USER_NAME"; fi
    if [ -z "$(git config --global user.email 2>/dev/null)" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then git config --global user.email "$GIT_USER_EMAIL"; fi
    [ -n "$(git config --global user.email 2>/dev/null)" ] || warn "git sem identidade: restaure o backup ou rode git config --global user.name/user.email."
    git config --global init.defaultBranch >/dev/null 2>&1 || git config --global init.defaultBranch main
    return 0
}

#==============================================================================
# 12. RESTORE do backup cifrado
#==============================================================================
acha_backup() {
    local alvo="$1"
    if $AUTO_RESTORE && [ -z "$alvo" ]; then
        alvo="$(ls -dt /media/"$USER"/*/backup-ubuntu-*/ /run/media/"$USER"/*/backup-ubuntu-*/ 2>/dev/null | head -1)"
        [ -n "$alvo" ] || { erro "nao achei backup-ubuntu-* em /media/$USER/*"; return 1; }
        info "backup encontrado: $alvo"
    fi
    [ -n "$alvo" ] || return 1
    if [ -d "$alvo" ]; then alvo="${alvo%/}/backup.tar.gpg"; fi
    [ -f "$alvo" ] || { erro "nao achei $alvo"; return 1; }
    printf '%s' "$alvo"
}

restaura_projetos() {
    local tsv="$1" n=0 rel url
    [ -s "$tsv" ] || return 0
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    while IFS=$'\t' read -r rel url; do
        [ -n "$rel" ] || continue
        [ -d "$HOME/$rel/.git" ] && continue
        mkdir -p "$(dirname "$HOME/$rel")"
        TMO 300 git clone -q "$url" "$HOME/$rel" 2>/dev/null && n=$((n+1)) || warn "nao clonei ~/$rel"
    done < "$tsv"
    info "$n repositorios clonados"
}

etapa_restore() {
    local arq
    if [ -z "$RESTORE_ARG" ] && ! $AUTO_RESTORE; then
        warn "sem --restore: nada restaurado (SSH, AWS, VPN, harness e dados ficam por fazer)."
        return 0
    fi
    arq="$(acha_backup "$RESTORE_ARG")" || return 1
    local dir; dir="$(dirname "$arq")"
    if [ -f "$dir/SHA256SUMS" ]; then
        info "conferindo sha256 do backup..."
        ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null ) || { erro "sha256 NAO confere: backup corrompido ou adulterado. Abortando o restore."; return 1; }
    else warn "sem SHA256SUMS ao lado do backup; so a integridade interna do gpg sera conferida."; fi
    [ -t 0 ] || { erro "preciso de um terminal para pedir a senha."; return 1; }
    local PASS; read -rs -p "Senha do backup: " PASS; echo
    info "extraindo para $HOME (arquivos que ja existem NAO sao sobrescritos)..."
    local rc
    set +e
    gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d "$arq" 3< <(printf '%s' "$PASS") 2>/dev/null \
        | tar -x --skip-old-files --no-same-owner -C "$HOME"
    rc=("${PIPESTATUS[@]}")
    PASS=""
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then erro "falha ao decifrar/extrair (senha errada? gpg=${rc[0]} tar=${rc[1]})"; return 1; fi
    local meta="$HOME/$META"
    [ -d "$meta" ] || { erro "backup sem $META: nao foi gerado pelo backup.sh"; return 1; }

    # Itens que eram symlink na origem (~/.zsh_secrets etc.) entram como arquivo real se ainda nao existem
    if [ -d "$meta/deref" ]; then
        ( cd "$meta/deref" && find . -type f -o -type l | sed 's#^\./##' ) | while IFS= read -r f; do
            [ -e "$HOME/$f" ] || [ -L "$HOME/$f" ] || { mkdir -p "$(dirname "$HOME/$f")"; cp -a "$meta/deref/$f" "$HOME/$f"; }
        done
    fi

    # Permissoes
    [ -d "$HOME/.ssh" ] && { chmod 700 "$HOME/.ssh"; find "$HOME/.ssh" -type f \( -name 'id_*' -o -name '*.pem' -o -name '*_key' \) ! -name '*.pub' -exec chmod 600 {} +; }
    [ -d "$HOME/.gnupg" ] && chmod 700 "$HOME/.gnupg"
    [ -d "$HOME/.aws" ] && chmod 700 "$HOME/.aws"
    [ -d "$HOME/.kube" ] && chmod 700 "$HOME/.kube"
    [ -f "$HOME/.zsh_secrets" ] && chmod 600 "$HOME/.zsh_secrets"
    [ -f "$HOME/.terraform.d/credentials.tfrc.json" ] && chmod 600 "$HOME/.terraform.d/credentials.tfrc.json"
    [ -d "$HOME/.cert" ] && find "$HOME/.cert" -type f -exec chmod 600 {} +

    # Perfis de VPN do NetworkManager (reescreve o HOME de origem, se o usuario mudou)
    local raiz="$meta/raiz" origem; origem="$(cat "$meta/inventario/home-origem.txt" 2>/dev/null || true)"
    if [ -d "$raiz/etc/NetworkManager/system-connections" ]; then
        local f
        for f in "$raiz/etc/NetworkManager/system-connections"/*; do
            [ -f "$f" ] || continue
            local dst; dst="/etc/NetworkManager/system-connections/$(basename "$f")"
            [ -f "$dst" ] && { skip "VPN $(basename "$f")"; continue; }
            if [ -n "$origem" ] && [ "$origem" != "$HOME" ]; then sed "s#$origem#$HOME#g" "$f" | sudo tee "$dst" >/dev/null; else sudo cp "$f" "$dst"; fi
            sudo chown root:root "$dst"; sudo chmod 600 "$dst"
        done
        sudo nmcli connection reload 2>/dev/null || true
    fi
    # /etc que mudou (zram e DKMS sao tratados nas proprias etapas; o resto vem so se ainda nao existe)
    if [ -d "$raiz/etc" ]; then
        local f rel
        while IFS= read -r f; do
            rel="${f#"$raiz"}"
            case "$rel" in /etc/NetworkManager/system-connections/*|/etc/systemd/zram-generator.conf*|/etc/hosts) continue ;; esac
            [ -e "$rel" ] && continue
            sudo mkdir -p "$(dirname "$rel")" && sudo cp -a "$f" "$rel"
        done < <(find "$raiz/etc" -type f)
        info "hosts de origem em $raiz/etc/hosts (nao aplicado automaticamente; confira)."
        mkdir -p "$HOME/.local/share/backup-ubuntu-restore" && cp -a "$raiz/etc/hosts" "$HOME/.local/share/backup-ubuntu-restore/hosts.origem" 2>/dev/null || true
    fi
    # Lista de pacotes de origem: guardada para consulta, nao reinstalada as cegas
    mkdir -p "$HOME/.local/share/backup-ubuntu-restore"
    cp -a "$meta/inventario" "$HOME/.local/share/backup-ubuntu-restore/" 2>/dev/null || true
    [ -f "$meta/MANIFESTO.txt" ] && cp -a "$meta/MANIFESTO.txt" "$HOME/.local/share/backup-ubuntu-restore/" || true

    # sha256 por arquivo (config e segredos)
    if [ -f "$meta/SHA256-ARQUIVOS.txt" ]; then
        local ruins; ruins="$( cd "$HOME" && sha256sum -c "$meta/SHA256-ARQUIVOS.txt" 2>/dev/null | grep -vc ': OK$' || true )"
        info "sha256 por arquivo: $ruins divergentes (arquivos que ja existiam antes do restore divergem de proposito)."
    fi

    # Repos de ~/projects que nao estavam no tar
    $SEM_PROJ || restaura_projetos "$meta/projetos-clonar.tsv"

    # Limpa a pasta de meta (os inventarios ficaram em ~/.local/share/backup-ubuntu-restore)
    rm -rf "$meta"
    info "restore concluido."
    return 0
}

#==============================================================================
# 13. Harness: clonar dotfiles-claude, install.sh, servicos e linger
#==============================================================================
etapa_harness() {
    export PATH="$HOME/.local/bin:$PATH"
    if [ ! -d "$HARNESS_DIR/.git" ]; then
        tem gh && gh auth status >/dev/null 2>&1 || ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -qi 'successfully authenticated' \
            || { erro "sem acesso ao GitHub (chave SSH ou gh auth). Restaure o backup (--restore) ou rode 'gh auth login' e repita com --so harness."; return 1; }
        mkdir -p "$(dirname "$HARNESS_DIR")"
        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" TMO 600 git clone "$HARNESS_REPO" "$HARNESS_DIR" || return 1
    else
        skip "harness ja clonado em $HARNESS_DIR"
        TMO 120 git -C "$HARNESS_DIR" pull --ff-only 2>/dev/null || warn "git pull do harness nao avancou (mudanca local ou sem rede); sigo com o que ha."
    fi
    # linger: os servicos do usuario (claude-remote, jarvis) sobem no boot sem login grafico
    loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' || sudo loginctl enable-linger "$USER"
    # O install.sh linka config, binarios, units systemd --user, venvs da voz (uv, python 3.12 fixo) e liga os timers essenciais
    ( cd "$HARNESS_DIR" && TMO 1800 ./install.sh ) || { erro "install.sh do harness falhou"; return 1; }
    systemctl --user daemon-reload 2>/dev/null || true
    local u
    for u in claude-remote.service jarvis.service escritorio-local.service; do
        [ -e "$HOME/.config/systemd/user/$u" ] || { warn "unit $u nao foi linkada pelo install.sh"; continue; }
        systemctl --user is-enabled --quiet "$u" 2>/dev/null || systemctl --user enable "$u" 2>/dev/null || warn "nao habilitei $u"
    done
    # jarvis e escritorio-local sobem agora; o claude-remote so no proximo boot (subir agora abriria uma segunda sessao do Head)
    for u in jarvis.service escritorio-local.service; do
        [ -e "$HOME/.config/systemd/user/$u" ] && { systemctl --user is-active --quiet "$u" || systemctl --user start "$u" 2>/dev/null || warn "$u nao subiu (veja journalctl --user -u $u)"; }
    done
    warn "Logins que o backup nao resolve: 'gh auth login' (se o token expirou), 'aws sso login', 'kiro-cli login', 'claude' (login), 'sudo tailscale up'."
    return 0
}

#==============================================================================
# Ordem de execucao
#==============================================================================
echo "Ubuntu $VERSION_ID ($CODENAME, $ARCH). Idempotente: pode rodar de novo."
if [ ${#SO[@]} -eq 0 ] && [ -z "$RESTORE_ARG" ] && ! $AUTO_RESTORE; then
    warn "Sem --restore, o setup instala so as ferramentas (SSH, AWS, VPN e harness dependem do backup)."
fi
sudo -v || { erro "preciso do sudo"; exit 1; }

executa_etapa apt etapa_apt
executa_etapa docker etapa_docker
executa_etapa node etapa_node
executa_etapa uv etapa_uv
executa_etapa gh etapa_gh
executa_etapa aws etapa_aws
executa_etapa terraform etapa_terraform
executa_etapa kubectl etapa_kubectl
executa_etapa cli-extra etapa_cli_extra
executa_etapa kiro etapa_kiro
executa_etapa claude etapa_claude
executa_etapa rclone etapa_rclone
executa_etapa tailscale etapa_tailscale
executa_etapa vpn etapa_vpn
executa_etapa apps etapa_apps
executa_etapa displaylink etapa_displaylink
executa_etapa zram etapa_zram
executa_etapa playwright etapa_playwright
executa_etapa shell etapa_shell
executa_etapa restore etapa_restore
executa_etapa harness etapa_harness

echo
if [ ${#FALHAS[@]} -eq 0 ]; then
    info "Setup concluido sem falhas. Faca logout/login (grupo docker, shell zsh) e reinicie para o claude-remote subir no boot."
else
    warn "Setup concluido com falhas em: ${FALHAS[*]}. Rode de novo (so refaz o que falta) ou use --so <etapa>."
    exit 1
fi
