#!/usr/bin/env bash
#==============================================================================
# ubuntu-setup-automated.sh - setup de uma maquina Ubuntu 26.10 (aceita 26.04 LTS) do zero
# (dev/DevOps + harness de agentes), idempotente.
#
# Uso:
#   ./ubuntu-setup-automated.sh [opcoes]
#
#   --restore CAMINHO   restaura o backup cifrado gerado pelo backup.sh.
#                       CAMINHO e a pasta backup-ubuntu-<host>-<data> (ou o
#                       backup.tar.gpg dentro dela). A senha e pedida na hora.
#   --ignorar-sha256    segue o restore mesmo sem SHA256SUMS (por padrao a falta dele e erro).
#   --refazer-restore   decifra e extrai de novo mesmo que o restore ja tenha concluido antes
#                       (por padrao um restore concluido e pulado: nao pede senha nem le 30 GB de novo).
#   --delta ARQUIVO     depois do restore principal, restaura o pacote delta cifrado (tar.gpg com o que
#                       mudou depois do backup). SOBRESCREVE os arquivos (o delta e mais novo) e roda
#                       uma vez so. "--delta auto" procura delta-pos-backup-*.tar.gpg ao lado da pasta
#                       do backup principal.
#   --limpa-efi-windows remove a entrada "Windows Boot Manager" (efibootmgr) e EFI/Microsoft da ESP.
#                       So com esta opcao, so com terminal, e so depois de voce digitar APAGAR.
#   --acesso-remoto     instala o que abre a maquina para acesso pela rede: openssh-server (porta 22),
#                       xrdp (3389) e TeamViewer. Sem esta opcao ficam de fora (tambem na lista do backup).
#   --sem-suspender     maquina sempre ligada: ignora a tampa e o ocioso, mascara sleep/suspend/hibernate,
#                       Wi-Fi sem economia de energia e perfil de energia performance. Sem esta opcao,
#                       a energia fica como o Ubuntu entrega.
#   --auto-restore      procura backup-ubuntu-* em /media/$USER/* e usa o mais novo.
#   --sem-harness       nao clona o repositorio de harness nem roda o install.sh dele.
#   --sem-displaylink   pula o driver DisplayLink (dock USB).
#   --sem-projetos      no restore, nao re-clona os repos de ~/projects.
#   --pular ETAPA       pula uma etapa (repetivel). Nomes: apt restore docker node uv gh aws
#                       terraform kubectl cli-extra kiro claude cli-ia rclone tailscale vpn
#                       apps displaylink zram energia playwright shell pacotes projetos
#                       git-integridade harness efi-windows delta
#   --so ETAPA          roda so a etapa (repetivel; "restore" tambem vale).
#   --listar            lista as etapas e sai.
#   -h, --help
#
# Saida: 0 sem falhas; 1 se alguma etapa falhou; 3 se nenhuma falhou mas alguma pede atencao (a etapa harness,
# quando o install.sh dele sai 3: a maquina diverge do repositorio do harness e ele parou sem sobrescrever nada).
#
# Configuracao local (fora do repo): ~/.config/backup-ubuntu-setup.conf (ou SETUP_CONF), linhas CHAVE=valor,
# lidas e nunca executadas; variavel de ambiente com o mesmo nome vence. Como fica em ~/.config, vai junto no
# backup e ja esta la quando o restore termina. Chaves:
#   HARNESS_REPO       URL do repositorio de harness a clonar (sem ela, e sem HARNESS_DIR, a etapa harness e pulada)
#   HARNESS_REPO_SSH   URL SSH do mesmo repo (padrao: derivada da HARNESS_REPO quando e github.com)
#   HARNESS_DIR        onde fica o checkout (padrao: ~/projects/<nome do repo>)
#   HARNESS_BRANCH     branch exigida antes do install.sh (padrao: main)
#   SEGREDOS_EXTRA     caminhos relativos ao HOME, separados por espaco, que tambem levam chmod go-rwx no restore
#   NPM_GLOBAL         CLIs do npm global da etapa cli-ia (padrao: @google/gemini-cli)
#   AVISO_FIM          texto livre impresso no fim do setup (lembrete da maquina)
#
# Variaveis opcionais: GIT_USER_NAME, GIT_USER_EMAIL (so usadas se o backup nao
# trouxe o ~/.gitconfig), ZRAM_ALGO_0/ZRAM_ALGO_1, ZRAM_MB_0/ZRAM_MB_1
# (padrao: metade da RAM, dividida entre os dois),
# SWAP_DISK_SIZE (padrao 8G; so ajusta um /swap.img que ja existe), NODE_MAJOR (padrao 24), PY_VERSAO (padrao 3.12),
# SNAP_TMO (segundos por snap; padrao 300), SNAP_PULAR (snaps a nao instalar, separados por espaco;
# ex.: SNAP_PULAR=spotify se o snap travar de novo).
#
# Se uma etapa travar ou falhar por motivo externo (ex.: um snap), rode de novo com --pular <etapa>.
# Depois de um restore concluido, repita o comando com --pular restore (ou nada: o restore concluido
# e pulado sozinho).
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
# Tamanho do /swap.img no formato do fallocate/numfmt (8G, 4G, 2048M). SWAP_FILE_GB (numero em GB) ainda vale.
SWAP_DISK_SIZE="${SWAP_DISK_SIZE:-${SWAP_FILE_GB:+${SWAP_FILE_GB}G}}"; SWAP_DISK_SIZE="${SWAP_DISK_SIZE:-8G}"
SNAP_TMO="${SNAP_TMO:-300}"
SNAP_PULAR="${SNAP_PULAR:-}"
# zram: ~50% da RAM, metade em cada dispositivo. A MemTotal e arredondada para cima em multiplo de 2 GiB
# (o kernel reserva um pouco: 32 GB marca ~31264 MB), entao 16 GB -> 8 GB no total e 32 GB -> 16 GB.
# ZRAM_MB_0/1 sobrescrevem.
RAM_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"; RAM_MB="${RAM_MB:-8192}"
RAM_MB=$(( (RAM_MB + 2047) / 2048 * 2048 ))
ZRAM_MB_0="${ZRAM_MB_0:-$((RAM_MB / 4))}"; ZRAM_ALGO_0="${ZRAM_ALGO_0:-lzo-rle}"
ZRAM_MB_1="${ZRAM_MB_1:-$((RAM_MB / 4))}"; ZRAM_ALGO_1="${ZRAM_ALGO_1:-zstd}"
SETUP_CONF="${SETUP_CONF:-$HOME/.config/backup-ubuntu-setup.conf}"
# Versao fixa e sha256 de tudo que e baixado e executado fora do apt. Conferidos em 06/11/2026: os hashes vem do
# arquivo de checksums publicado no proprio release (k9s, stern, lazygit, trivy, actionlint, argocd, helm, uv, rclone)
# ou do download, quando o fornecedor nao publica (aws cli, aws_signing_helper, session-manager-plugin, nvm,
# oh-my-zsh, chave da Synaptics). Trocar a versao exige trocar os hashes.
AWS_CLI_V=2.39.5
AWS_CLI_SHA=(fe0553306b3d001d162bc193d3b040027aab3466b9f910b50e702c122c0f3ff9 ce7b03ebceed1dc6a0a8f27134a41a9a3b5671f09c57ab2e7fc6d43710dbaef3)
SIGNING_HELPER_V=1.8.5
SIGNING_HELPER_SHA=(beec9ed1c492d93db809890f16713e3556353294b823c2184ad4e891f1b2b54d 3d131aa888cd56da446f9c6bb460b1f0569f6c7edc74eae6193a2fe3928883ba)
SSM_PLUGIN_V=1.2.896.0
SSM_PLUGIN_SHA=(53f51fcc67314a4bf85888a38a3967cd41f8d0f28a60a9469a63acf935ba713e 914eeca87b18b55356c58be197080f73742b3ca60d3823f0a45670dc9056aa9c)
NVM_V=v0.40.3; NVM_SHA=2d8359a64a3cb07c02389ad88ceecd43f2fa469c06104f92f98df5b6f315275f
UV_V=0.13.7
UV_SHA=(c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83 71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc)
HELM_V=v3.22.1
HELM_SHA=(896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea 4c29e286b279d170fa048ddfc3e4e83dcd069ca9c52102766ba672d7149e694d)
K9S_V=v0.51.0
K9S_SHA=(c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7 3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c)
ARGOCD_V=v3.6.1
ARGOCD_SHA=(46d2fc941071f0a0c36326a67a431d34b1479e1a24737f7b367abc93968beadc 6636e9183de7dba666b673a417986e7ff54dbadd948b2f9f6c83bcf7d33ebb94)
STERN_V=v1.35.0
STERN_SHA=(03729b01a8fcfab25f6ea53389bd38bc37400ff86d90cd2dcda541f248cf843e b12f5e2ee0d01f6f21e0759cced0be2d8df9cd4e93e6a3cf11393170ae0f43cf)
LAZYGIT_V=v0.66.2
LAZYGIT_SHA=(158efc9ddfa1241fab5fb3526bb442c8dc6c4b1904d73213b9e4e93e03c52034 79a3161eeb642f0473e23db6341f7baabd4a5933e921a9c1167c5d5c765c41a4)
TRIVY_V=v0.76.2
TRIVY_SHA=(bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3)
ACTIONLINT_V=v1.7.12
ACTIONLINT_SHA=(8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6)
RCLONE_V=v1.76.0
RCLONE_SHA=(b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7 ee169016675e23a69d77240565133ff7dbc9b33d16fa8f7053d4af39f1eaeb78)
KUBECTX_V=v0.9.5; KUBECTX_COMMIT=92e5b5f43b94b06bc38b0fbde1ee51e00079c39c
OMZ_COMMIT=cca3bdfbef8c52ef8939ce7911ff68852b949daa; OMZ_SHA=5574b96e94dbcb769f0d1592fa83aeb6ca2caf41c6ae5d76fcc7f04c524b4f55
ZSH_PLUGINS=("zsh-users/zsh-syntax-highlighting 0.8.0 db085e4661f6aafd24e5acb5b2e17e4dd5dddf3e"
             "zsh-users/zsh-autosuggestions v0.7.1 e52ee8ca55bcc56a17c828767a3f98f22a68d4eb")
SYNAPTICS_KEYRING_SHA=f83300928848f2f7605ff8438467267019c7cc5181ec8b9eabc7f1e05cbfacbe
RESTORE_DIR="$HOME/.local/share/backup-ubuntu-restore"
INV="$RESTORE_DIR/inventario"
HARNESS_DIR="${HARNESS_DIR:-}"
HARNESS_BRANCH="${HARNESS_BRANCH:-}"
META=".backup-ubuntu-meta"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
erro()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }
skip()  { echo -e "${BLUE}[OK-JA-FEITO]${NC} $*"; }
secao() { echo; echo "=== $* ==="; }

export DEBIAN_FRONTEND=noninteractive
TMO() { timeout "$@"; }

ETAPAS=(apt restore delta docker node uv gh aws terraform kubectl cli-extra kiro claude cli-ia rclone tailscale vpn apps displaylink zram energia playwright shell pacotes projetos git-integridade harness efi-windows)
RESTORE_ARG=""; AUTO_RESTORE=false; SEM_PROJ=false; IGNORA_SHA=false
REFAZ_RESTORE=false; DELTA_ARG=""; LIMPA_EFI=false
ACESSO_REMOTO=false; SEM_SUSPENDER=false
# Pacotes que abrem a maquina para acesso pela rede: so com --acesso-remoto
ACESSO_REMOTO_PKGS=(openssh-server xrdp)
declare -A PULAR=() SO=()
FALHAS=()
ATENCAO=()   # etapa que terminou com exit 3: divergencia que pede atencao, nem sucesso nem falha
NOTAS_FIM=()

uso() { sed -n '3,/^#====.*$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --restore) shift; RESTORE_ARG="${1:-}"; [ -n "$RESTORE_ARG" ] || { erro "--restore pede um caminho"; exit 2; } ;;
        --auto-restore) AUTO_RESTORE=true ;;
        --ignorar-sha256) IGNORA_SHA=true ;;
        --refazer-restore) REFAZ_RESTORE=true ;;
        --delta) shift; DELTA_ARG="${1:-}"; [ -n "$DELTA_ARG" ] || { erro "--delta pede um arquivo (ou auto)"; exit 2; } ;;
        --limpa-efi-windows) LIMPA_EFI=true ;;
        --acesso-remoto) ACESSO_REMOTO=true ;;
        --sem-suspender) SEM_SUSPENDER=true ;;
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
CODENAME="${VERSION_CODENAME:-stonking}"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) ARCH_ALT=x86_64; ARCH_GO=amd64 ;; arm64) ARCH_ALT=aarch64; ARCH_GO=arm64 ;; *) erro "arquitetura nao suportada: $ARCH"; exit 1 ;; esac
case "${VERSION_ID:-}" in
    26.10) ;;
    26.04) info "Ubuntu 26.04: aceito (alvo principal: 26.10)." ;;
    *) warn "versao ${VERSION_ID:-?} (alvo: 26.10; 26.04 tambem aceito); pode funcionar, nao foi testado." ;;
esac

executa_etapa() { # executa_etapa nome funcao
    local nome="$1" fn="$2"
    if [ ${#SO[@]} -gt 0 ] && [ -z "${SO[$nome]:-}" ]; then return 0; fi
    if [ -n "${PULAR[$nome]:-}" ]; then skip "etapa pulada: $nome"; return 0; fi
    secao "$nome"
    local rc=0
    "$fn" || rc=$?
    case "$rc" in
        0) ;;
        3) warn "etapa pede atencao: $nome (nao e falha do setup; veja o aviso acima)"; ATENCAO+=("$nome") ;;
        *) warn "etapa com falha: $nome"; FALHAS+=("$nome") ;;
    esac
}

# grava_root ARQUIVO CONTEUDO: grava como root so se o conteudo mudou.
# Retorno: 0 gravou, 1 ja estava igual, 2 falhou (o chamador trata 2 como falha da etapa).
grava_root() {
    local f="$1" novo="$2" d
    if [ -f "$f" ] && [ "$(sudo cat "$f")" = "$novo" ]; then skip "$f"; return 1; fi
    d="$(dirname "$f")"
    if [ ! -d "$d" ] && ! sudo install -d "$d"; then warn "nao criou o diretorio $d"; return 2; fi
    if printf '%s\n' "$novo" | sudo tee "$f" >/dev/null; then info "gravado: $f"; return 0; fi
    warn "nao gravou $f"; return 2
}

tem() { command -v "$1" >/dev/null 2>&1; }
# conf CHAVE: a variavel de ambiente/shell CHAVE; sem ela, a ultima linha CHAVE=valor do SETUP_CONF (lida, nunca executada).
conf() {
    local k="$1" v="${!1:-}"
    if [ -z "$v" ] && [ -f "$SETUP_CONF" ]; then
        v="$(sed -n "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//p" "$SETUP_CONF" | tail -1 \
            | sed -E -e 's/[[:space:]]+$//' -e "s/^([\"'])(.*)\\1\$/\\2/")"
    fi
    printf '%s' "$v"
}
pkg_instalado() { dpkg -s "$1" >/dev/null 2>&1; }
apt_i() { sudo apt-get install -y --no-install-recommends "$@"; }
# Nome do pacote no repo atual: o proprio, ou o unico provedor se for pacote virtual (ex.: dnsutils -> bind9-dnsutils).
apt_resolve() {
    local p="$1" prov cand
    # apt-cache show devolve 0 para pacote puramente virtual; o Candidate e que diz se ha versao instalavel
    cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
    if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then printf '%s\n' "$p"; return 0; fi
    prov="$(apt-cache showpkg "$p" 2>/dev/null | awk '/^Reverse Provides:/{f=1;next} f&&NF{print $1}' | sort -u)"
    [ -n "$prov" ] && [ "$(printf '%s\n' "$prov" | wc -l)" -eq 1 ] && printf '%s\n' "$prov"
}
apt_faltantes() { # imprime so os pacotes que ainda nao estao instalados e existem no repo (os que nao existem so avisam)
    local p r
    for p in "$@"; do
        pkg_instalado "$p" && continue
        r="$(apt_resolve "$p")" || r=""
        if [ -z "$r" ]; then warn "pacote nao existe neste release, pulado: $p"; continue; fi
        pkg_instalado "$r" || printf '%s\n' "$r"
    done
}
apt_garante() {
    local falt p rc=0
    apt_update_se_sujo || warn "apt update falhou; sigo com a lista atual"
    falt="$(apt_faltantes "$@")"
    [ -z "$falt" ] && return 0
    # shellcheck disable=SC2086
    TMO 1200 sudo apt-get install -y --no-install-recommends $falt && return 0
    # um pacote que nao instala nao derruba a lista: tenta um a um e so avisa dos que falharem
    warn "instalacao em lote falhou; tentando um a um"
    for p in $falt; do TMO 600 sudo apt-get install -y --no-install-recommends "$p" || { warn "nao instalou: $p"; rc=1; }; done
    return $rc
}
# "um ou outro": instala o primeiro nome da lista que existir neste release (renomeio/t64 entre releases).
apt_um_ou_outro() {
    local p
    for p in "$@"; do
        pkg_instalado "$p" && return 0
        if apt_resolve "$p" >/dev/null; then apt_garante "$p"; return; fi
    done
    warn "nenhum destes existe neste release: $*"; return 1
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
# O repo de terceiro pode ainda nao ter a suite do release novo: tenta a do release, depois resolute, questing e noble.
# A url vem com $CODENAME dentro e e trocada por cada suite. Segue redirect e recusa pagina de erro com status 200
# (o packages.openvpn.net responde 301 para /error.html quando a suite nao existe).
suite_ou_fallback() { # suite_ou_fallback url_com_CODENAME
    local s u final
    for s in "$CODENAME" resolute questing noble; do
        u="${1//$CODENAME/$s}"
        final="$(TMO 20 curl -fsIL -o /dev/null -w '%{url_effective}' "$u" 2>/dev/null)" || continue
        case "$final" in *error.html*|"") continue ;; esac
        echo "$s"; return 0
    done
    echo noble
}
APT_SUJO=false
apt_update_se_sujo() { if $APT_SUJO; then TMO 600 sudo apt-get update -y && APT_SUJO=false; fi; }

baixa() { TMO "${3:-300}" curl -fsSL --retry 3 -o "$2" "$1"; }
# baixa_conferido URL DESTINO SHA256 [timeout]: so fica com o arquivo se o sha256 bater com o fixo no script.
baixa_conferido() {
    local url="$1" dst="$2" sha="$3" got
    [ -n "$sha" ] || { erro "sem sha256 fixo para $url"; return 1; }
    baixa "$url" "$dst" "${4:-300}" || { warn "nao baixei $url"; return 1; }
    got="$(sha256sum "$dst" | cut -d' ' -f1)"
    [ "$got" = "$sha" ] && return 0
    erro "sha256 NAO confere, arquivo descartado: $url (esperado $sha, veio $got)"; rm -f -- "$dst"; return 1
}
# por_arch SHA_AMD64 SHA_ARM64: o valor da arquitetura desta maquina
por_arch() { if [ "$ARCH" = arm64 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
# git_clone_fixo URL TAG COMMIT DESTINO: clona a tag e so aceita se ela apontar para o commit fixo.
git_clone_fixo() {
    local url="$1" tag="$2" commit="$3" dst="$4" got
    TMO 120 git clone -q --depth 1 --branch "$tag" "$url" "$dst" </dev/null 2>/dev/null || { warn "nao clonei $url ($tag)"; return 1; }
    got="$(git -C "$dst" rev-parse HEAD 2>/dev/null)"
    [ "$got" = "$commit" ] && return 0
    erro "$url $tag aponta para $got, esperado $commit: descartado"; rm -rf -- "$dst"; return 1
}
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
        ripgrep fd-find fzf tree htop net-tools bind9-dnsutils iproute2 rsync xclip \
        openssh-client gpg-agent dconf-cli \
        python3 python3-venv python3-pip python3-dev pipx \
        dkms "linux-headers-$(uname -r)" linux-headers-generic \
        fuse3 \
        network-manager network-manager-openvpn network-manager-openvpn-gnome openvpn \
        ffmpeg libportaudio2 libsndfile1 espeak-ng pulseaudio-utils v4l-utils \
        libnss3-tools bash-completion shellcheck remmina remmina-plugin-rdp fastfetch
    apt_um_ou_outro libfuse2t64 libfuse2 || warn "libfuse2 nao instalou (AppImage)"
    # ferramentas de uso diario que estao nesta maquina (apt-mark showmanual): rede, arquivos, escritorio
    apt_garante aria2 cifs-utils nfs-common samba-common-bin ntfs-3g lvm2 efibootmgr nmap whois traceroute \
        sshpass sqlite3 redis-server wireguard wl-clipboard fonts-firacode fprintd libpam-fprintd \
        freerdp3-x11 libreoffice pdfarranger simple-scan vlc libvhdi-utils libpng-dev || warn "alguns pacotes extras do apt nao instalaram"
    if $ACESSO_REMOTO; then
        apt_garante "${ACESSO_REMOTO_PKGS[@]}" || warn "acesso remoto: alguns pacotes nao instalaram"
        warn "acesso remoto ligado: ssh (22) e xrdp (3389) escutam na rede. Feche com firewall (ufw) e 'PasswordAuthentication no' no sshd."
    else
        skip "acesso remoto (${ACESSO_REMOTO_PKGS[*]}, TeamViewer): fora sem --acesso-remoto"
        NOTAS_FIM+=("acesso remoto (${ACESSO_REMOTO_PKGS[*]}, TeamViewer) nao instalado: --acesso-remoto instala")
    fi
    return 0
}

#==============================================================================
# 2. Docker (repo oficial; cai para resolute/questing/noble se a suite nova ainda nao existe)
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
        local d; d="$(tmpd)"
        baixa_conferido "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_V/install.sh" "$d/nvm-install.sh" "$NVM_SHA" 60 \
            && PROFILE=/dev/null TMO 300 bash "$d/nvm-install.sh" </dev/null || { rm -rf "$d"; return 1; }
        rm -rf "$d"
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
# 4. uv + Python 3.12 do uv (para venvs que nao usam o Python do sistema)
#==============================================================================
etapa_uv() {
    if ! tem uv && [ ! -x "$HOME/.local/bin/uv" ]; then
        local d t; d="$(tmpd)"; t="uv-${ARCH_ALT}-unknown-linux-gnu"
        baixa_conferido "https://github.com/astral-sh/uv/releases/download/$UV_V/$t.tar.gz" "$d/uv.tgz" "$(por_arch "${UV_SHA[@]}")" 300 \
            && tar -xzf "$d/uv.tgz" -C "$d" && mkdir -p "$HOME/.local/bin" \
            && install -m 0755 "$d/$t/uv" "$d/$t/uvx" "$HOME/.local/bin/" || { rm -rf "$d"; return 1; }
        rm -rf "$d"
    else skip "uv"; fi
    export PATH="$HOME/.local/bin:$PATH"
    if ! uv python find "$PY_VERSAO" >/dev/null 2>&1; then TMO 600 uv python install "$PY_VERSAO" || return 1; else skip "python $PY_VERSAO (uv)"; fi
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
        baixa_conferido "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_ALT}-${AWS_CLI_V}.zip" "$d/aws.zip" "$(por_arch "${AWS_CLI_SHA[@]}")" 600 || { rm -rf "$d"; return 1; }
        unzip -q "$d/aws.zip" -d "$d" && TMO 300 sudo "$d/aws/install" --update || return 1
        rm -rf "$d"
    fi
    # aws_signing_helper (credencial do IAM Roles Anywhere por certificado)
    if ! tem aws_signing_helper && [ ! -x "$HOME/.local/bin/aws_signing_helper" ]; then
        local sh_a=X86_64 d; [ "$ARCH" = arm64 ] && sh_a=Aarch64
        mkdir -p "$HOME/.local/bin"; d="$(tmpd)"
        baixa_conferido "https://rolesanywhere.amazonaws.com/releases/$SIGNING_HELPER_V/$sh_a/Linux/Amzn2023/aws_signing_helper" "$d/aws_signing_helper" \
            "$(por_arch "${SIGNING_HELPER_SHA[@]}")" 300 \
            && install -m 0755 "$d/aws_signing_helper" "$HOME/.local/bin/aws_signing_helper" || warn "aws_signing_helper nao instalou"
        rm -rf "$d"
    else skip "aws_signing_helper"; fi
    if ! tem session-manager-plugin; then
        local d; d="$(tmpd)"
        local arq=ubuntu_64bit; [ "$ARCH" = arm64 ] && arq=ubuntu_arm64
        if baixa_conferido "https://s3.amazonaws.com/session-manager-downloads/plugin/$SSM_PLUGIN_V/$arq/session-manager-plugin.deb" "$d/ssm.deb" \
            "$(por_arch "${SSM_PLUGIN_SHA[@]}")" 300; then
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
        baixa_conferido "https://get.helm.sh/helm-$HELM_V-linux-$ARCH_GO.tar.gz" "$d/helm.tgz" "$(por_arch "${HELM_SHA[@]}")" 300 \
            && tar -xzf "$d/helm.tgz" -C "$d" && sudo install -m 0755 "$d/linux-$ARCH_GO/helm" "$bin/helm" || warn "helm nao instalou"
        rm -rf "$d"
    else skip "helm"; fi
    if ! tem k9s; then
        local d; d="$(tmpd)"
        if baixa_conferido "https://github.com/derailed/k9s/releases/download/$K9S_V/k9s_Linux_${ARCH_GO}.tar.gz" "$d/k9s.tgz" "$(por_arch "${K9S_SHA[@]}")" 300; then
            tar -xzf "$d/k9s.tgz" -C "$d" k9s && sudo install -m 0755 "$d/k9s" "$bin/k9s"
        else warn "k9s nao instalou"; fi
        rm -rf "$d"
    else skip "k9s"; fi
    if ! tem argocd; then
        local d; d="$(tmpd)"
        baixa_conferido "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_V/argocd-linux-$ARCH_GO" "$d/argocd" "$(por_arch "${ARGOCD_SHA[@]}")" 300 \
            && sudo install -m 0755 "$d/argocd" "$bin/argocd" || warn "argocd nao instalou"
        rm -rf "$d"
    else skip "argocd"; fi
    return 0
}

#==============================================================================
# 6b. CLIs extras (binarios de release do GitHub, sem repo apt)
#==============================================================================
instala_release() { # instala_release comando repo tag asset binario sha256
    local cmd="$1" repo="$2" tag="$3" asset="$4" bin="$5" sha="$6" d url
    tem "$cmd" && { skip "$cmd"; return 0; }
    url="https://github.com/$repo/releases/download/$tag/$asset"
    d="$(tmpd)"
    if baixa_conferido "$url" "$d/a" "$sha" 300 && tar -xzf "$d/a" -C "$d" "$bin" 2>/dev/null; then
        sudo install -m 0755 "$d/$bin" "/usr/local/bin/$bin"
    else warn "$cmd nao instalou ($url)"; rm -rf "$d"; return 1; fi
    rm -rf "$d"
}

etapa_cli_extra() {
    local rc=0
    local lg_a=x86_64 tv_a=64bit; [ "$ARCH" = arm64 ] && { lg_a=arm64; tv_a=ARM64; }
    instala_release stern stern/stern "$STERN_V" "stern_${STERN_V#v}_linux_${ARCH_GO}.tar.gz" stern "$(por_arch "${STERN_SHA[@]}")" || rc=1
    instala_release lazygit jesseduffield/lazygit "$LAZYGIT_V" "lazygit_${LAZYGIT_V#v}_linux_${lg_a}.tar.gz" lazygit "$(por_arch "${LAZYGIT_SHA[@]}")" || rc=1
    instala_release trivy aquasecurity/trivy "$TRIVY_V" "trivy_${TRIVY_V#v}_Linux-${tv_a}.tar.gz" trivy "$(por_arch "${TRIVY_SHA[@]}")" || rc=1
    instala_release actionlint rhysd/actionlint "$ACTIONLINT_V" "actionlint_${ACTIONLINT_V#v}_linux_${ARCH_GO}.tar.gz" actionlint "$(por_arch "${ACTIONLINT_SHA[@]}")" || rc=1
    if ! tem kubectx; then
        if [ ! -d /opt/kubectx ]; then
            local d; d="$(tmpd)"
            if git_clone_fixo https://github.com/ahmetb/kubectx "$KUBECTX_V" "$KUBECTX_COMMIT" "$d/kubectx"; then
                sudo cp -a "$d/kubectx" /opt/kubectx && sudo chown -R root:root /opt/kubectx || rc=1
            else rc=1; fi
            rm -rf "$d"
        fi
        [ -d /opt/kubectx ] && { sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx; sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens; }
    else skip "kubectx"; fi
    return $rc
}

# snap com timeout: o snapd ja travou no download do spotify (restore de 06/11, etapa apps parada ate
# o timeout de 900 s). Passou de SNAP_TMO, aborta a mudanca pendente e segue, em vez de prender o setup.
snap_aborta_pendentes() { # snap_aborta_pendentes nome
    local id
    TMO 20 snap changes 2>/dev/null | awk -v n="\"$1\"" '($2=="Doing" || $2=="Do") && index($0, n) {print $1}' | while read -r id; do
        sudo snap abort "$id" >/dev/null 2>&1 && info "snap abort $id ($1)"
    done
    return 0
}
snap_instala() { # snap_instala nome [--classic]
    local nome="$1" rc; shift
    case " $SNAP_PULAR " in *" $nome "*) skip "snap $nome (SNAP_PULAR)"; return 0 ;; esac
    snap list "$nome" >/dev/null 2>&1 && { skip "snap $nome"; return 0; }
    TMO -k 15 "$SNAP_TMO" sudo snap install "$nome" "$@" </dev/null; rc=$?
    [ $rc -eq 0 ] && return 0
    if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
        warn "snap $nome passou de ${SNAP_TMO}s: abortei a mudanca pendente do snapd e sigo. Para nao tentar de novo: SNAP_PULAR=\"$nome\" ou --pular apps."
        snap_aborta_pendentes "$nome"
    else warn "snap $nome falhou (rc=$rc)"; fi
    return 1
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
    local app fl
    # spotify por ultimo: foi o que travou no restore de 06/11
    for app in firefox telegram-desktop slack postman btop dbeaver-ce spotify; do
        fl=(); [ "$app" = slack ] && fl=(--classic)
        snap_instala "$app" "${fl[@]}" || rc=1
    done
    # TeamViewer (deb oficial; o pacote cria o repo apt dele): acesso remoto, so com --acesso-remoto
    if ! $ACESSO_REMOTO; then skip "teamviewer (so com --acesso-remoto)"
    elif ! tem teamviewer; then
        local d; d="$(tmpd)"
        if baixa https://download.teamviewer.com/download/linux/teamviewer_amd64.deb "$d/tv.deb" 600; then
            TMO 900 sudo apt-get install -y "$d/tv.deb" || { warn "teamviewer nao instalou"; rc=1; }
        else warn "nao baixei o teamviewer"; rc=1; fi
        rm -rf "$d"
    else skip "teamviewer"; fi
    # NoMachine: o link do deb muda a cada versao e exige a pagina de download; fica manual
    pkg_instalado nomachine-personal-edition || warn "NoMachine: baixe o deb em nomachine.com/download e rode: sudo apt install ./nomachine_*.deb"
    # GitKraken CLI (gk): sem URL estavel verificada; fica manual (gitkraken.com/cli)
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
    # Kiro IDE: deb oficial da ultima versao estavel (o metadata do site diz qual)
    if tem kiro; then skip "kiro IDE"; elif [ "$ARCH" = amd64 ]; then
        local v d; d="$(tmpd)"
        v="$(TMO 30 curl -fsSL https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json | grep -oP '"currentRelease":"\K[^"]+' | head -1)"
        if [ -n "$v" ] && baixa "https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/$v/deb/kiro-ide-$v-stable-linux-x64.deb" "$d/kiro.deb" 900; then
            TMO 900 sudo apt-get install -y "$d/kiro.deb" || { warn "kiro IDE nao instalou"; rm -rf "$d"; return 1; }
        else warn "nao baixei o Kiro IDE (versao '$v')"; rm -rf "$d"; return 1; fi
        rm -rf "$d"
    else warn "Kiro IDE: sem build para $ARCH"; fi
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
    if tem rclone || [ -x "$HOME/.local/bin/rclone" ]; then skip "rclone"; return 0; fi
    # binario oficial (o do apt costuma estar atrasado para os remotes novos), em ~/.local/bin como nesta maquina
    local d; d="$(tmpd)"
    if baixa_conferido "https://downloads.rclone.org/$RCLONE_V/rclone-$RCLONE_V-linux-${ARCH_GO}.zip" "$d/r.zip" "$(por_arch "${RCLONE_SHA[@]}")" 300 \
        && unzip -q "$d/r.zip" -d "$d"; then
        mkdir -p "$HOME/.local/bin"
        install -m 0755 "$d"/rclone-*/rclone "$HOME/.local/bin/rclone"; rm -rf "$d"; return 0
    fi
    rm -rf "$d"; warn "rclone oficial nao baixou; tentando o do apt"
    apt_garante rclone
}

#==============================================================================
# 7a. CLIs que vivem no npm global (nvm): NPM_GLOBAL da configuracao local (padrao: Gemini CLI).
#     No restore, a etapa pacotes reinstala tambem a lista npm global do backup.
#==============================================================================
carrega_nvm() { export NVM_DIR="$HOME/.nvm"; # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; tem npm; }
npm_garante() { # npm_garante pacote...
    local pk rc=0
    for pk in "$@"; do
        npm ls -g --depth=0 "$pk" 2>/dev/null | grep -q "$pk@" && { skip "npm -g $pk"; continue; }
        TMO 600 npm install -g "$pk" </dev/null || { warn "npm -g $pk falhou"; rc=1; }
    done
    return $rc
}
etapa_cli_ia() {
    carrega_nvm || { warn "npm ausente (etapa node)"; return 1; }
    local l; l="$(conf NPM_GLOBAL)"
    # shellcheck disable=SC2086
    npm_garante ${l:-@google/gemini-cli}
}

#==============================================================================
# 7. Tailscale, openvpn (3 e NetworkManager)
#==============================================================================
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
    [ -e "/lib/modules/$k/build" ] || warn "sem headers do kernel em uso ($k): reinicie no kernel mais novo e rode --so displaylink."
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
        baixa_conferido https://www.synaptics.com/sites/default/files/Ubuntu/pool/stable/main/all/synaptics-repository-keyring.deb "$d/k.deb" "$SYNAPTICS_KEYRING_SHA" 120 \
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
# 9. zram (50% da RAM: zram0 lzo-rle + zram1 zstd, metade cada) e o tamanho do /swap.img que ja existe
#==============================================================================
etapa_zram() {
    apt_garante systemd-zram-generator || return 1
    local rc=0 g novo
    novo="$(printf '[zram0]\nzram-size = %s\ncompression-algorithm = %s\nswap-priority = 100\n\n[zram1]\nzram-size = %s\ncompression-algorithm = %s\nswap-priority = 100' \
        "$ZRAM_MB_0" "$ZRAM_ALGO_0" "$ZRAM_MB_1" "$ZRAM_ALGO_1")"
    grava_root /etc/systemd/zram-generator.conf "$novo"; g=$?
    case $g in
        0) sudo systemctl daemon-reload
           info "zram: ${ZRAM_MB_0} MB + ${ZRAM_MB_1} MB (RAM ${RAM_MB} MB); se o zram ja estava ativo, o tamanho novo vale no proximo boot" ;;
        2) return 1 ;;
    esac
    local u zram_ok=true
    for u in systemd-zram-setup@zram0.service systemd-zram-setup@zram1.service; do
        systemctl is-active --quiet "$u" 2>/dev/null || sudo systemctl start "$u" 2>/dev/null \
            || { warn "nao subiu $u (confira no proximo boot)"; zram_ok=false; }
    done
    # swappiness 180 so faz sentido com o zram de pe: sem ele, nao grava
    if $zram_ok; then
        grava_root /etc/sysctl.d/99-zram.conf 'vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125'; g=$?
        case $g in
            0) sudo sysctl -q -p /etc/sysctl.d/99-zram.conf || { warn "sysctl do zram nao aplicou"; rc=1; } ;;
            2) rc=1 ;;
        esac
    else
        warn "zram nao subiu: /etc/sysctl.d/99-zram.conf (swappiness 180) NAO gravado"; rc=1
    fi
    swap_disco || rc=1
    return $rc
}

# Swap em disco: o instalador do Ubuntu cria /swap.img. So ajusta o tamanho de um /swap.img que JA existe; sem ele,
# nao cria swap do zero nem mexe no fstab (a instalacao pode ter escolhido outro esquema). O arquivo novo e montado
# ao lado e so substitui o antigo depois do mkswap; se faltar espaco ou algo falhar, o antigo continua.
# SWAP_IMG: so para teste.
swap_disco() {
    local img="${SWAP_IMG:-/swap.img}" alvo atual novo
    alvo="$(numfmt --from=iec "$SWAP_DISK_SIZE" 2>/dev/null)" || alvo=""
    [ -n "$alvo" ] && [ "$alvo" -gt 0 ] 2>/dev/null || { warn "SWAP_DISK_SIZE invalido: $SWAP_DISK_SIZE"; return 1; }
    if ! sudo test -f "$img"; then
        skip "$img nao existe: nao crio swap em disco do zero (fica so o zram)"; return 0
    fi
    atual="$(sudo stat -c %s "$img")"
    if [ "$atual" -eq "$alvo" ]; then skip "$img ja tem $SWAP_DISK_SIZE"; return 0; fi
    info "ajustando $img de $(numfmt --to=iec "$atual") para $SWAP_DISK_SIZE"
    novo="$img.novo"
    sudo rm -f -- "$novo"
    if ! { sudo fallocate -l "$alvo" "$novo" && sudo chmod 600 "$novo" && sudo mkswap "$novo" >/dev/null; }; then
        sudo rm -f -- "$novo"; warn "nao montei o $img novo (espaco?); o antigo continua"; return 1
    fi
    sudo swapoff "$img" 2>/dev/null || true
    if sudo mv -f -- "$novo" "$img" && sudo swapon "$img"; then
        info "$img com $SWAP_DISK_SIZE e ativo"
    else
        warn "$img trocado mas o swapon falhou (confira a linha do swap no /etc/fstab)"; return 1
    fi
    awk -v i="$img" '$1 == i {f=1} END {exit !f}' /etc/fstab 2>/dev/null || warn "$img sem linha no /etc/fstab: nao vale no proximo boot (nao edito o fstab)"
    return 0
}

#==============================================================================
# 9b. Energia: driver de video Intel; com --sem-suspender, sempre ligado (tampa, ocioso, sleep) e performance
#==============================================================================
etapa_energia() {
    local rc=0
    if tem lspci && lspci 2>/dev/null | grep -Ei 'vga|3d|display' | grep -qi intel; then
        apt_garante intel-media-va-driver-non-free vainfo || rc=1
    else skip "sem GPU Intel: driver de video pulado"; fi
    if ! $SEM_SUSPENDER; then
        skip "energia como o Ubuntu entrega (suspende, tampa e economia de energia normais)"
        NOTAS_FIM+=("maquina sempre ligada (tampa, sleep mascarado, Wi-Fi sem economia, perfil performance) nao aplicada: --sem-suspender aplica")
        return $rc
    fi
    # a regra da tampa vale no proximo boot (reiniciar o logind derruba a sessao grafica)
    grava_root /etc/systemd/logind.conf.d/10-sempre-ligado.conf '[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore'
    [ $? -eq 2 ] && rc=1
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target >/dev/null 2>&1 \
        || { warn "nao mascarou os alvos de sleep"; rc=1; }
    # nao reinicia o NetworkManager no setup: vale na proxima conexao ou boot
    grava_root /etc/NetworkManager/conf.d/wifi-powersave-off.conf '[connection]
wifi.powersave = 2'
    case $? in
        0) warn "Wi-Fi sem powersave: vale na proxima conexao ou no proximo boot" ;;
        2) rc=1 ;;
    esac
    if tem powerprofilesctl; then
        if [ "$(powerprofilesctl get 2>/dev/null)" = performance ]; then skip "perfil de energia: performance"
        else powerprofilesctl set performance || { warn "powerprofilesctl set performance falhou"; rc=1; }; fi
    else warn "powerprofilesctl ausente (power-profiles-daemon); perfil de energia nao ajustado"; fi
    return $rc
}

#==============================================================================
# 10. Playwright e as libs do WebKit (faltam no 26.04/26.10)
#     O playwright-core 1.65 trata qualquer 26.x como ubuntu26.04 (lista de pacotes e build do WebKit);
#     no 26.10 ele avisa 'plataforma nao oficial', e esperado. Os 79 pacotes da lista existem no 26.10.
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
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        local d; d="$(tmpd)"
        baixa_conferido "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/$OMZ_COMMIT/tools/install.sh" "$d/omz.sh" "$OMZ_SHA" 60 \
            && RUNZSH=no CHSH=no KEEP_ZSHRC=yes TMO 300 sh "$d/omz.sh" </dev/null || warn "oh-my-zsh nao instalou"
        rm -rf "$d"
    else skip "oh-my-zsh"; fi
    local zc="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}" pl repo tag commit
    for pl in "${ZSH_PLUGINS[@]}"; do
        read -r repo tag commit <<<"$pl"
        local n="${repo#*/}"
        [ -d "$zc/plugins/$n" ] && { skip "plugin $n"; continue; }
        git_clone_fixo "https://github.com/$repo" "$tag" "$commit" "$zc/plugins/$n" || warn "plugin $n nao instalou"
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
        info "backup encontrado: $alvo" >&2
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
    tem gh && gh auth status >/dev/null 2>&1 && gh auth setup-git >/dev/null 2>&1
    while IFS=$'\t' read -r rel url; do
        [ -n "$rel" ] || continue
        [ -d "$HOME/$rel/.git" ] && continue
        mkdir -p "$(dirname "$HOME/$rel")"
        TMO 300 git clone -q "$url" "$HOME/$rel" 2>/dev/null </dev/null && n=$((n+1)) || warn "nao clonei ~/$rel"
    done < "$tsv"
    info "$n repositorios clonados"
}

# Estado de guardrail do harness (as aprovacoes de mudanca registradas e a chave do bypass da trava, em
# ~/.claude/change-*) vale so na maquina onde foi criado: nao migra no restore nem no delta.
RESTORE_NAO_MIGRA=('.claude/change-*')
tar_nao_migra() { local p; for p in "${RESTORE_NAO_MIGRA[@]}"; do printf -- '--exclude=%s\n--exclude=./%s\n' "$p" "$p"; done; }

# Permissao certa em tudo que e segredo (o tar de usuario comum aplica umask, entao fecha de novo)
fecha_permissoes() {
    local p
    local extra; extra="$(conf SEGREDOS_EXTRA)"
    # shellcheck disable=SC2086
    for p in .ssh .aws .kube .gnupg .terraform.d .docker .config/gh .config/rclone .config/gcloud \
             .local/share/keyrings .netrc .npmrc $extra; do
        case "$p" in /*|*..*) warn "SEGREDOS_EXTRA ignora $p (precisa ser relativo ao HOME)"; continue ;; esac
        [ -e "$HOME/$p" ] && chmod -R go-rwx "$HOME/$p" 2>/dev/null
    done
    [ -d "$HOME/.ssh" ] && { chmod 700 "$HOME/.ssh"; find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} +; }
    [ -d "$HOME/.gnupg" ] && find "$HOME/.gnupg" -type d -exec chmod 700 {} +
    return 0
}

# /etc do backup. O tar extrai em ~/.backup-ubuntu-meta/raiz, pasta que o usuario escreve; por isso nada e
# instalado de la: tudo e copiado antes para uma pasta de root (0700) e validado e instalado dessa copia, de
# modo que o arquivo conferido e o instalado sao o mesmo. O que da poder de root (sudoers, ssh, systemd, udev,
# modprobe, apt, openvpn) so entra depois de mostrar a lista e digitar RESTAURAR no terminal.
# ETC_DEST e ETC_STAGE_BASE: so para teste (prefixo do destino e base da pasta de root).
ETC_DEST="${ETC_DEST:-}"
ETC_STAGE_BASE="${ETC_STAGE_BASE:-/root}"
etc_sensivel() {
    case "$1" in
        /etc/sudoers.d/*|/etc/ssh/*|/etc/systemd/*|/etc/udev/*|/etc/modprobe.d/*|/etc/modules-load.d/*|/etc/apt/*|/etc/openvpn/*) return 0 ;;
    esac
    return 1
}
sed_padrao() { printf '%s' "$1" | sed 's/[]\/$*.^[#]/\\&/g'; }
sed_troca()  { printf '%s' "$1" | sed 's/[\/&#]/\\&/g'; }
restaura_etc() { # restaura_etc PASTA_RAIZ_DO_BACKUP HOME_DE_ORIGEM
    local raiz="$1" origem="$2" rs f rel modo r n=0 rc=0 nm=false
    [ -d "$raiz/etc" ] || return 0
    rs="$(sudo mktemp -d "$ETC_STAGE_BASE/backup-ubuntu-etc.XXXXXX")" || { warn "nao criei a pasta de root para o /etc do backup: /etc NAO restaurado"; return 1; }
    if ! { sudo cp -a --no-preserve=ownership "$raiz/etc" "$rs/" && sudo chown -R 0:0 "$rs" && sudo chmod -R go-rwx "$rs"; }; then
        sudo rm -rf -- "$rs"; warn "nao copiei o /etc do backup para a pasta de root: /etc NAO restaurado"; return 1
    fi
    # perfis do NetworkManager: o HOME de origem vira o atual, ja na copia de root
    if [ -n "$origem" ] && [ "$origem" != "$HOME" ] && sudo test -d "$rs/etc/NetworkManager/system-connections"; then
        sudo find "$rs/etc/NetworkManager/system-connections" -type f -exec \
            sed -i "s#$(sed_padrao "$origem")#$(sed_troca "$HOME")#g" {} + || { warn "nao reescrevi o HOME nos perfis do NetworkManager"; rc=1; }
    fi
    local -a inst=() sens=()
    while IFS= read -r f; do
        rel="${f#"$rs"}"
        case "$rel" in /etc/systemd/zram-generator.conf*|/etc/hosts) continue ;; esac
        if sudo test -e "$ETC_DEST$rel"; then skip "/etc: $rel ja existe"; continue; fi
        if etc_sensivel "$rel"; then sens+=("$f"); else inst+=("$f"); fi
    done < <(sudo find "$rs/etc" -type f | sort)
    mkdir -p "$RESTORE_DIR"; : > "$RESTORE_DIR/etc-nao-restaurado.txt"
    if [ ${#sens[@]} -gt 0 ]; then
        warn "${#sens[@]} arquivo(s) do backup em /etc dao poder de root (sudoers, ssh, systemd, udev, modprobe, apt, openvpn):"
        for f in "${sens[@]}"; do printf '    %s\n' "${f#"$rs"}" >&2; done
        r=""; if [ -t 0 ]; then IFS= read -r -p "Restaurar estes arquivos em /etc? Digite RESTAURAR (outra coisa pula): " r; fi
        if [ "$r" = RESTAURAR ]; then inst+=("${sens[@]}")
        else
            for f in "${sens[@]}"; do printf '%s\n' "${f#"$rs"}" >> "$RESTORE_DIR/etc-nao-restaurado.txt"; done
            warn "NAO restaurados (lista em $RESTORE_DIR/etc-nao-restaurado.txt). Para restaurar depois: --so restore --refazer-restore e responder RESTAURAR."
        fi
    fi
    for f in "${inst[@]+"${inst[@]}"}"; do
        rel="${f#"$rs"}"; modo=644
        case "$rel" in /etc/sudoers.d/*) modo=440 ;; /etc/NetworkManager/*|/etc/openvpn/*|/etc/ssh/*|/etc/netplan/*) modo=600 ;; esac
        if [ "$modo" = 440 ] && ! sudo visudo -cf "$f" >/dev/null 2>&1; then warn "sudoers invalido no backup, NAO restaurado: $rel"; rc=1; continue; fi
        if sudo install -D -o root -g root -m "$modo" "$f" "$ETC_DEST$rel"; then
            n=$((n+1))
            case "$rel" in /etc/apt/*) APT_SUJO=true ;; /etc/NetworkManager/system-connections/*) nm=true ;; esac
        else warn "nao restaurei $rel"; rc=1; fi
    done
    [ -s "$RESTORE_DIR/etc-nao-restaurado.txt" ] || rm -f "$RESTORE_DIR/etc-nao-restaurado.txt"
    if sudo test -f "$rs/etc/hosts"; then
        # shellcheck disable=SC2024  # a copia e do usuario, de proposito (so para conferir)
        sudo cat "$rs/etc/hosts" > "$RESTORE_DIR/hosts.origem" 2>/dev/null \
            && info "hosts de origem em $RESTORE_DIR/hosts.origem (nao aplicado automaticamente; confira)."
    fi
    sudo rm -rf -- "$rs"
    $nm && { sudo nmcli connection reload 2>/dev/null || true; }
    # fonte/chave do apt restaurada: o proximo apt-get install precisa de um update antes
    $APT_SUJO && info "fontes do apt restauradas: o apt update roda antes da proxima instalacao."
    info "/etc: $n arquivo(s) restaurado(s)."
    return $rc
}

etapa_restore() {
    local arq
    if [ -z "$RESTORE_ARG" ] && ! $AUTO_RESTORE; then
        warn "sem --restore: nada restaurado (SSH, AWS, VPN, harness e dados ficam por fazer)."
        return 0
    fi
    local marca="$RESTORE_DIR/restore-concluido"
    if [ -f "$marca" ] && ! $REFAZ_RESTORE; then
        skip "restore ja concluido em $(cut -d' ' -f1 "$marca") (use --refazer-restore para decifrar e extrair de novo)"
        return 0
    fi
    arq="$(acha_backup "$RESTORE_ARG")" || return 1
    local dir; dir="$(dirname "$arq")"
    if [ -f "$dir/SHA256SUMS" ]; then
        info "conferindo sha256 do backup..."
        ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null ) || { erro "sha256 NAO confere: backup corrompido ou adulterado. Abortando o restore."; return 1; }
    elif $IGNORA_SHA; then warn "sem SHA256SUMS ao lado do backup; seguindo por causa de --ignorar-sha256 (so a integridade interna do gpg sera conferida)."
    else erro "sem SHA256SUMS ao lado do backup: nao da para conferir a integridade. Copie o arquivo ou use --ignorar-sha256 se aceitar o risco."; return 1; fi
    [ -t 0 ] || { erro "preciso de um terminal para pedir a senha."; return 1; }
    local PASS; IFS= read -rs -p "Senha do backup: " PASS; echo
    info "extraindo para $HOME (arquivos que ja existem NAO sao sobrescritos; os pulados sao listados)..."
    local rc tarerr excl=(); tarerr="$(mktemp)"
    mapfile -t excl < <(tar_nao_migra)
    set +e
    gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d "$arq" 3< <(printf '%s' "$PASS") 2>/dev/null \
        | LC_ALL=C tar -x --keep-old-files --no-same-owner --anchored "${excl[@]}" -C "$HOME" 2>"$tarerr"
    rc=("${PIPESTATUS[@]}")
    PASS=""
    # --keep-old-files avisa "Cannot open: File exists" por arquivo pulado e segue; qualquer outro erro e falha.
    # O tar roda com LC_ALL=C: em pt_BR a mensagem sai traduzida e o parse abaixo nao a reconheceria.
    local pulados outros
    pulados="$(sed -n 's/^[^ ]*tar: \(.*\): Cannot open: File exists$/\1/p' "$tarerr")"
    outros="$(grep -v 'Cannot open: File exists$' "$tarerr" | grep -v 'tar: Exiting with failure status due to previous errors$' || true)"
    rm -f "$tarerr"
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -gt 2 ] || { [ "${rc[1]}" -ne 0 ] && [ -n "$outros" ]; }; then
        erro "falha ao decifrar/extrair (senha errada? gpg=${rc[0]} tar=${rc[1]})"; [ -z "$outros" ] || printf '%s\n' "$outros" | head -10 >&2; return 1
    fi
    if [ -n "$pulados" ]; then
        warn "$(printf '%s\n' "$pulados" | wc -l) arquivo(s) ja existiam e NAO foram sobrescritos (confira se o do backup deveria vencer; ex.: .gitconfig, .zshrc):"
        printf '%s\n' "$pulados" | head -60 | sed 's/^/    ~\//' >&2
    fi
    local meta="$HOME/$META"
    [ -d "$meta" ] || { erro "backup sem $META: nao foi gerado pelo backup.sh"; return 1; }

    # Itens que eram symlink na origem entram como arquivo real se ainda nao existem
    if [ -d "$meta/deref" ]; then
        ( cd "$meta/deref" && find . -type f -o -type l | sed 's#^\./##' ) | while IFS= read -r f; do
            [ -e "$HOME/$f" ] || [ -L "$HOME/$f" ] || { mkdir -p "$(dirname "$HOME/$f")"; cp -a "$meta/deref/$f" "$HOME/$f"; }
        done
    fi
    fecha_permissoes

    # /etc do backup (perfis do NetworkManager inclusos): validado e instalado a partir de uma copia de root
    local origem; origem="$(cat "$meta/inventario/home-origem.txt" 2>/dev/null || true)"
    restaura_etc "$meta/raiz" "$origem" || warn "parte do /etc do backup nao foi restaurada (veja os avisos acima)"
    # Listas de pacotes (alimentam a etapa "pacotes"), lista de repos a clonar (etapa "projetos") e manifesto
    mkdir -p "$RESTORE_DIR"
    cp -a "$meta/inventario" "$RESTORE_DIR/" 2>/dev/null || true
    [ -f "$meta/projetos-clonar.tsv" ] && cp -a "$meta/projetos-clonar.tsv" "$RESTORE_DIR/" || true
    [ -f "$meta/MANIFESTO.txt" ] && cp -a "$meta/MANIFESTO.txt" "$RESTORE_DIR/" || true

    # sha256 por arquivo (config e segredos)
    if [ -f "$meta/SHA256-ARQUIVOS.txt" ]; then
        local ruins; ruins="$( cd "$HOME" && sha256sum -c "$meta/SHA256-ARQUIVOS.txt" 2>/dev/null | grep -vc ': OK$' || true )"
        info "sha256 por arquivo: $ruins divergentes (arquivos que ja existiam antes do restore divergem de proposito)."
    fi
    rm -rf "$meta"
    mkdir -p "$RESTORE_DIR" && printf '%s %s\n' "$(date -Is)" "$(basename "$dir")" > "$marca"
    info "restore concluido (pacotes e repos vem nas etapas pacotes e projetos)."
    return 0
}

#==============================================================================
# 12a. Pacote delta: o que mudou entre o backup principal e o desligamento da maquina antiga
#      (tar.gpg cifrado a parte). Vai DEPOIS do principal e SOBRESCREVE (e mais novo); por isso
#      roda uma vez so (marca delta-concluido) e nunca sem pedido explicito (--delta).
#==============================================================================
acha_delta() { # acha_delta ARQUIVO|auto
    local a="$1" base c
    if [ "$a" = auto ]; then
        base="${RESTORE_ARG%/}"
        [ -f "$base" ] && base="$(dirname "$base")"
        if [ -n "$base" ]; then c="$(ls -t "$(dirname "$base")"/delta-pos-backup-*.tar.gpg 2>/dev/null | head -1)"; fi
        [ -n "${c:-}" ] || c="$(ls -t /media/"$USER"/*/delta-pos-backup-*.tar.gpg /run/media/"$USER"/*/delta-pos-backup-*.tar.gpg 2>/dev/null | head -1)"
        [ -n "$c" ] || { erro "nao achei delta-pos-backup-*.tar.gpg ao lado do backup nem em /media/$USER/*"; return 1; }
        a="$c"
    fi
    [ -f "$a" ] || { erro "nao achei o delta: $a"; return 1; }
    printf '%s' "$a"
}

etapa_delta() {
    local marca="$RESTORE_DIR/delta-concluido" arq
    if [ -z "$DELTA_ARG" ]; then
        # avisa se ha um delta ao lado do backup, para nao esquecer
        if [ -n "$RESTORE_ARG" ] && acha_delta auto >/dev/null 2>&1; then
            warn "ha um pacote delta ao lado do backup ($(basename "$(acha_delta auto)")); para restaurar depois do principal: --delta auto"
        else skip "delta (sem --delta)"; fi
        return 0
    fi
    if [ -f "$marca" ] && ! $REFAZ_RESTORE; then
        skip "delta ja restaurado em $(cut -d' ' -f1 "$marca") (--refazer-restore sobrescreve de novo)"; return 0
    fi
    case " ${FALHAS[*]:-} " in *" restore "*) erro "o restore principal falhou: o delta vai DEPOIS dele, nao restaurei."; return 1 ;; esac
    [ -f "$RESTORE_DIR/restore-concluido" ] || warn "sem marca de restore principal concluido; o delta sobrescreve, confirme que o principal ja foi restaurado."
    arq="$(acha_delta "$DELTA_ARG")" || return 1
    if [ -f "$arq.sha256" ]; then
        ( cd "$(dirname "$arq")" && sha256sum -c "$(basename "$arq").sha256" >/dev/null ) || { erro "sha256 do delta NAO confere."; return 1; }
        info "sha256 do delta conferido."
    else warn "sem $(basename "$arq").sha256 ao lado: so a integridade interna do gpg sera conferida."; fi
    [ -t 0 ] || { erro "preciso de um terminal para pedir a senha do delta."; return 1; }
    local PASS; IFS= read -rs -p "Senha do pacote delta: " PASS; echo
    info "extraindo o delta em $HOME (sobrescreve; diretorios existentes mantem permissao)..."
    local rc tarerr excl=(); tarerr="$(mktemp)"
    mapfile -t excl < <(tar_nao_migra)
    gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d "$arq" 3< <(printf '%s' "$PASS") 2>/dev/null \
        | LC_ALL=C tar -x --no-same-owner --no-overwrite-dir --anchored "${excl[@]}" -C "$HOME" 2>"$tarerr"
    rc=("${PIPESTATUS[@]}")
    PASS=""
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then
        erro "falha ao decifrar/extrair o delta (senha errada? gpg=${rc[0]} tar=${rc[1]})"; head -10 "$tarerr" >&2; rm -f "$tarerr"; return 1
    fi
    rm -f "$tarerr"
    fecha_permissoes
    mkdir -p "$RESTORE_DIR" && printf '%s %s\n' "$(date -Is)" "$(basename "$arq")" > "$marca"
    info "delta restaurado."
    return 0
}

#==============================================================================
# 12b. Pacotes a partir das listas do backup: apt, snap, npm global, extensoes
#      do VS Code e do Kiro, pip --user, uv tool, pipx, extensoes do gh, dconf, cron
#==============================================================================
etapa_pacotes() {
    [ -d "$INV" ] || { warn "sem inventario do backup ($INV): etapa pacotes pulada (use --restore)."; return 0; }
    local ret=0 l nome have ext flag
    # apt: o que foi instalado a mao la, menos pacote de sistema, kernel, bootloader e metapacote de desktop
    if [ -s "$INV/apt-manual.txt" ]; then
        local fora_rede=(); $ACESSO_REMOTO || fora_rede=("${ACESSO_REMOTO_PKGS[@]}" teamviewer)
        l="$(grep -vE '^(linux-|grub|shim|ubuntu-|language-pack|ibus|libchewing|libpinyin|libopencc|libm17n|libotf|m17n|wbritish|bsdutils|dash$|diffutils|findutils|grep$|gzip|hostname|init$|login$|ncurses|python3-minimal|tailscale-archive|synaptics-repository)' "$INV/apt-manual.txt" | grep -vxF -f <(printf '%s\n' "${fora_rede[@]+"${fora_rede[@]}"}" "#") || true)"
        # shellcheck disable=SC2086
        [ -z "$l" ] || apt_garante $l || { warn "apt: alguns pacotes da lista nao instalaram"; ret=1; }
    fi
    # snap
    if [ -s "$INV/snap.txt" ]; then
        while read -r nome _; do
            case "$nome" in ""|bare|core*|gnome-*|gtk-common-themes|mesa-*|snapd|snapd-desktop-integration|snap-store|firmware-updater|desktop-security-center|prompting-client) continue ;; esac
            flag=(); grep -qx "$nome" "$INV/snap-classic.txt" 2>/dev/null && flag=(--classic)
            snap_instala "$nome" "${flag[@]}" || ret=1
        done < "$INV/snap.txt"
    fi
    # npm global (nvm)
    if [ -s "$INV/npm-global.txt" ] && carrega_nvm; then
        while read -r nome; do
            case "$nome" in ""|npm|corepack) continue ;; esac
            npm_garante "$nome" || ret=1
        done < "$INV/npm-global.txt"
    fi
    # extensoes do VS Code e do Kiro
    local ed lista
    for ed in code:vscode-extensoes.txt kiro:kiro-extensoes.txt; do
        nome="${ed%%:*}"; lista="$INV/${ed#*:}"
        tem "$nome" && [ -s "$lista" ] || continue
        have="$(TMO 60 "$nome" --list-extensions 2>/dev/null || true)"
        while read -r ext; do
            [ -n "$ext" ] || continue
            grep -qixF "$ext" <<<"$have" && continue
            TMO 300 "$nome" --install-extension "$ext" </dev/null >/dev/null 2>&1 || { warn "$nome: extensao $ext nao instalou"; ret=1; }
        done < "$lista"
    done
    # python --user, uv tool, pipx, extensoes do gh
    if [ -s "$INV/pip-user.txt" ]; then
        sed 's/==.*//' "$INV/pip-user.txt" | grep -v '^#' | xargs -r python3 -m pip install --user --break-system-packages -q 2>/dev/null || { warn "pip --user: alguns pacotes falharam"; ret=1; }
    fi
    export PATH="$HOME/.local/bin:$PATH"
    if [ -s "$INV/uv-tools.txt" ] && tem uv; then
        grep -vE '^(-|[[:space:]]|$)' "$INV/uv-tools.txt" | awk '{print $1}' | while read -r nome; do uv tool install "$nome" </dev/null || true; done
    fi
    if [ -s "$INV/pipx.txt" ] && tem pipx; then awk '{print $1}' "$INV/pipx.txt" | while read -r nome; do pipx install "$nome" </dev/null || true; done; fi
    if [ -s "$INV/gh-extensoes.txt" ] && tem gh && gh auth status >/dev/null 2>&1; then
        awk -F'\t' '{print $2}' "$INV/gh-extensoes.txt" | while read -r nome; do [ -n "$nome" ] && gh extension install "$nome" </dev/null || true; done
    fi
    [ -d "$HOME/.local/share/fonts" ] && tem fc-cache && fc-cache -f "$HOME/.local/share/fonts" >/dev/null 2>&1
    # cron do usuario
    if [ -s "$INV/crontab.txt" ] && ! crontab -l >/dev/null 2>&1; then crontab "$INV/crontab.txt" && info "crontab restaurado"; fi
    # configuracao do GNOME (guarda a atual antes)
    if [ -s "$INV/dconf.ini" ] && tem dconf; then
        dconf dump / > "$RESTORE_DIR/dconf.antes.ini" 2>/dev/null || true
        dconf load / < "$INV/dconf.ini" 2>/dev/null && info "dconf (GNOME) aplicado" \
            || warn "dconf nao aplicado (precisa de sessao grafica). Depois: dconf load / < $INV/dconf.ini"
    fi
    return $ret
}

#==============================================================================
# 12c. Repos de ~/projects que nao estavam no tar (precisa do gh logado ou da chave SSH, que vieram no restore)
#==============================================================================
etapa_projetos() {
    if $SEM_PROJ; then skip "projetos (--sem-projetos)"; return 0; fi
    [ -s "$RESTORE_DIR/projetos-clonar.tsv" ] || { warn "sem lista de repos ($RESTORE_DIR/projetos-clonar.tsv): nada a clonar."; return 0; }
    restaura_projetos "$RESTORE_DIR/projetos-clonar.tsv"
}

#==============================================================================
# 12d. Integridade dos repos git depois do restore
#      No restore de 06/11 o .git/index e um ref de um repo viraram o texto de um arquivo do
#      file-history do Claude (o index era hardlink dele no tar). Aqui: separa hardlinks dentro de .git
#      (copia para inode proprio, para uma escrita no outro arquivo nao corromper o repo) e roda
#      git status + fsck em cada repo. So le e reporta; nao apaga nada. Roda antes do harness porque
#      o harness faz git pull.
#==============================================================================
git_erro_curto() { head -c 300 "$1" | head -1 | tr -cd '[:print:]'; }
etapa_git_integridade() {
    tem git || { warn "git ausente"; return 1; }
    local g d f n=0 ruins=0 desfeitos=0 err rc hl
    err="$(mktemp)"
    while IFS= read -r g; do
        d="${g%/.git}"; n=$((n+1))
        hl=()
        mapfile -d '' -t hl < <(find "$g" -type f -links +1 -print0 2>/dev/null)
        for f in "${hl[@]}"; do
            cp -p -- "$f" "$f.sep.$$" && mv -f -- "$f.sep.$$" "$f" && desfeitos=$((desfeitos+1))
        done
        GIT_OPTIONAL_LOCKS=0 TMO 60 git -C "$d" status --porcelain >/dev/null 2>"$err" </dev/null; rc=$?
        if [ $rc -ne 0 ]; then
            warn "git status falhou em ${d/#$HOME/\~}: $(git_erro_curto "$err")"; ruins=$((ruins+1)); continue
        fi
        TMO 120 git -C "$d" fsck --connectivity-only --no-progress >/dev/null 2>"$err" </dev/null; rc=$?
        if [ $rc -eq 124 ]; then warn "git fsck passou de 120 s em ${d/#$HOME/\~} (nao conferido)"
        elif [ $rc -ne 0 ]; then
            warn "git fsck falhou em ${d/#$HOME/\~}: $(git_erro_curto "$err")"; ruins=$((ruins+1))
        fi
    done < <(TMO 120 find "$HOME" -maxdepth 5 \( -name node_modules -o -name .cache -o -name .nvm -o -name .oh-my-zsh \
                -o -name .terraform -o -name snap -o -name .local -o -name miniconda3 \) -prune -o -type d -name .git -print -prune 2>/dev/null)
    rm -f "$err"
    [ "$desfeitos" -eq 0 ] || info "$desfeitos arquivo(s) dentro de .git deixaram de ser hardlink"
    if [ "$ruins" -gt 0 ]; then
        warn "$ruins de $n repo(s) com problema. Conserto do index/ref de remoto: guarde o .git/index (ou o ref) como .corrompido, apague-o, rode 'git fetch' e 'git reset'. Nada foi apagado por este script."
        return 1
    fi
    info "$n repositorio(s) git conferidos (status + fsck), nenhum com problema"
    return 0
}

#==============================================================================
# 13. Harness (opcional): clona o repositorio configurado (HARNESS_REPO), roda o install.sh dele e liga o linger.
#     Precisa de git e de acesso ao repo (gh logado ou chave SSH, que vem no restore). Sem HARNESS_REPO nem
#     HARNESS_DIR, a etapa e pulada.
#==============================================================================
# Lista as units do usuario que estavam ligadas na origem (inventario do backup) e estao desligadas aqui.
harness_units_desligadas() {
    local lista="$INV/systemd-user-enabled.txt" u n=0
    [ -s "$lista" ] || return 0
    while read -r u _; do
        case "$u" in snap.*|gnome*|gcr*|gpg*|dirmngr*|keyboxd*|org.*|pipewire*|wireplumber*|obex*|mpris*|xdg*|spice*|upgrade*|user-session*|ubuntu*|filter-chain*|openvpn3*|dbus*|"") continue ;; esac
        [ -e "$HOME/.config/systemd/user/$u" ] || continue
        systemctl --user is-enabled --quiet "$u" 2>/dev/null && continue
        [ $n -eq 0 ] && warn "ligadas na maquina de origem e DESLIGADAS aqui (opt-in; ligue numa maquina so):"
        printf '    systemctl --user enable --now %s\n' "$u" >&2; n=$((n+1))
    done < "$lista"
    [ $n -eq 0 ] || NOTAS_FIM+=("$n unit(s) do usuario ligadas na origem ficaram desligadas: a lista esta na etapa harness")
    return 0
}
etapa_harness() {
    export PATH="$HOME/.local/bin:$PATH"
    local repo repo_ssh
    repo="$(conf HARNESS_REPO)"; repo_ssh="$(conf HARNESS_REPO_SSH)"
    HARNESS_DIR="$(conf HARNESS_DIR)"; HARNESS_BRANCH="$(conf HARNESS_BRANCH)"; HARNESS_BRANCH="${HARNESS_BRANCH:-main}"
    [ -n "$HARNESS_DIR" ] || [ -z "$repo" ] || HARNESS_DIR="$HOME/projects/$(basename "$repo" .git)"
    if [ -z "$HARNESS_DIR" ]; then
        skip "harness: sem HARNESS_REPO nem HARNESS_DIR (variavel de ambiente ou $SETUP_CONF)"; return 0
    fi
    if [ -z "$repo_ssh" ]; then
        case "$repo" in https://github.com/*) repo_ssh="git@github.com:${repo#https://github.com/}"; repo_ssh="${repo_ssh%.git}.git" ;; esac
    fi
    if [ ! -d "$HARNESS_DIR/.git" ]; then
        [ -n "$repo" ] || { erro "harness: $HARNESS_DIR nao e um checkout e falta HARNESS_REPO para clonar."; return 1; }
        mkdir -p "$(dirname "$HARNESS_DIR")"
        if tem gh && gh auth status >/dev/null 2>&1; then
            gh auth setup-git >/dev/null 2>&1
            TMO 600 git clone "$repo" "$HARNESS_DIR" </dev/null || return 1
        elif [ -n "$repo_ssh" ] && ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -qi 'successfully authenticated'; then
            GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" TMO 600 git clone "$repo_ssh" "$HARNESS_DIR" </dev/null || return 1
        else
            erro "sem acesso ao repositorio do harness. Restaure o backup (--restore, traz ~/.config/gh e ~/.ssh) ou rode 'gh auth login' e repita com --so harness."
            return 1
        fi
    else
        skip "harness ja clonado em $HARNESS_DIR"
    fi
    # O install.sh linka a trava de mudanca e os hooks a partir deste checkout: so roda na branch principal,
    # sem commit local fora do remoto.
    local br; br="$(git -C "$HARNESS_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ "$br" != "$HARNESS_BRANCH" ]; then
        erro "harness em '${br:-HEAD solto}', nao em $HARNESS_BRANCH: install.sh NAO rodado. Rode 'git -C $HARNESS_DIR switch $HARNESS_BRANCH' e repita com --so harness."
        return 1
    fi
    TMO 120 git -C "$HARNESS_DIR" pull --ff-only </dev/null >/dev/null 2>&1 || warn "git pull do harness nao avancou (mudanca local ou sem rede)."
    local fora; fora="$(git -C "$HARNESS_DIR" rev-list --count "origin/$HARNESS_BRANCH..HEAD" 2>/dev/null || echo '?')"
    if [ "$fora" != 0 ]; then
        erro "o $HARNESS_BRANCH local do harness tem commit fora do origin/$HARNESS_BRANCH ($fora): install.sh NAO rodado."
        return 1
    fi
    [ -z "$(git -C "$HARNESS_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ] \
        || warn "harness com arquivo versionado alterado localmente; o install.sh linka a versao do disco."
    # linger: os servicos do usuario sobem no boot sem login grafico
    loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' || sudo loginctl enable-linger "$USER"
    # O install.sh linka config, binarios e units systemd --user, cria as venvs e liga o que e padrao dele
    # Exit 3 do install.sh = a maquina diverge do que o repositorio do harness declara. Ele parou sem sobrescrever nada
    # e avisou: nao e erro (1) nem sucesso (0). A etapa para aqui (sem daemon-reload nem lista de units) e devolve 3.
    local rc=0
    ( cd "$HARNESS_DIR" && TMO 1800 ./install.sh ) || rc=$?
    if [ "$rc" -eq 3 ]; then
        warn "install.sh do harness terminou com exit 3: esta maquina diverge do que o repositorio do harness declara. Ele parou sem sobrescrever nada e avisou acima o que difere. A etapa NAO foi concluida (nao e erro do setup): resolva a divergencia e repita com --so harness."
        NOTAS_FIM+=("harness: install.sh parou com divergencia (exit 3); etapa nao concluida, repita com --so harness depois de resolver")
        return 3
    fi
    [ "$rc" -eq 0 ] || { erro "install.sh do harness falhou (saida $rc)"; return 1; }
    systemctl --user daemon-reload 2>/dev/null || true
    # Nao religa nada por conta propria: o que estava ligado na maquina de origem e o install.sh deixou
    # desligado e opt-in (rotinas que gastam credito, sessoes remotas). Ligar nas duas maquinas duplica custo.
    harness_units_desligadas
    return 0
}

#==============================================================================
# 14. Entrada EFI do Windows (opcional, so com --limpa-efi-windows)
#     Instalar o Ubuntu apagando o disco reaproveita a ESP de fabrica, que segue com a entrada "Windows
#     Boot Manager" e a pasta EFI/Microsoft sem Windows nenhum. Aqui: confere que o Ubuntu inicia sozinho,
#     avisa se ha NTFS/BitLocker no mesmo disco, guarda uma copia da pasta e so apaga depois de
#     digitar APAGAR no terminal.
#==============================================================================
etapa_efi_windows() {
    if ! $LIMPA_EFI; then skip "efi-windows (so roda com --limpa-efi-windows)"; return 0; fi
    [ -d "${EFI_SYSFS:-/sys/firmware/efi}" ] || { skip "boot BIOS/legado: nao ha ESP"; return 0; }
    tem efibootmgr || apt_garante efibootmgr || return 1
    local esp="${ESP_DIR:-/boot/efi}"  # ESP_DIR e EFI_SYSFS: so para teste
    mountpoint -q "$esp" || { warn "$esp nao esta montado: nada feito."; return 1; }
    local lista entradas ms=false
    lista="$(sudo efibootmgr 2>/dev/null)" || { warn "efibootmgr falhou"; return 1; }
    entradas="$(printf '%s\n' "$lista" | grep -iE '^Boot[0-9A-F]{4}\*? +Windows Boot Manager' || true)"
    sudo test -d "$esp/EFI/Microsoft" && ms=true
    if [ -z "$entradas" ] && ! $ms; then skip "sem entrada nem pasta do Windows na ESP"; return 0; fi
    # trava: o Ubuntu precisa ter entrada propria e loader na ESP, senao apagar o Windows deixa sem boot
    if ! printf '%s\n' "$lista" | grep -qiE '^Boot[0-9A-F]{4}\*? +ubuntu' \
        || ! { sudo test -e "$esp/EFI/ubuntu/shimx64.efi" || sudo test -e "$esp/EFI/ubuntu/grubx64.efi"; }; then
        erro "o Ubuntu nao tem entrada propria ou loader em $esp/EFI/ubuntu: nao mexo na entrada do Windows."; return 1
    fi
    local src disco ntfs=0
    src="$(findmnt -no SOURCE "$esp" 2>/dev/null)"; disco="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
    [ -n "$disco" ] && ntfs="$(lsblk -nro FSTYPE "/dev/$disco" 2>/dev/null | grep -ciE 'ntfs|bitlocker' || true)"
    info "entradas a remover:"; printf '%s\n' "$entradas" | sed 's/^/    /'
    $ms && info "pasta a remover: $esp/EFI/Microsoft ($(sudo du -sh "$esp/EFI/Microsoft" 2>/dev/null | cut -f1))"
    [ "${ntfs:-0}" -eq 0 ] || warn "ha $ntfs particao(oes) NTFS/BitLocker no mesmo disco (/dev/$disco): pode haver um Windows de verdade. Confira antes de seguir."
    [ -t 0 ] || { warn "sem terminal: nao apago a entrada do Windows sem confirmacao."; return 1; }
    local r; IFS= read -r -p "Digite APAGAR para remover a entrada e a pasta do Windows Boot Manager (outra coisa cancela): " r
    [ "$r" = APAGAR ] || { warn "cancelado; nada foi apagado."; return 0; }
    mkdir -p "$RESTORE_DIR"
    if $ms; then
        local copia; copia="$RESTORE_DIR/EFI-Microsoft-$(date +%Y%m%d).tar"
        sudo tar -C "$esp/EFI" -cf "$copia" Microsoft && sudo chown "$USER" "$copia" || { erro "nao consegui guardar a copia de EFI/Microsoft: nada apagado."; return 1; }
        info "copia da pasta em $copia"
    fi
    local num rc=0
    while IFS= read -r num; do
        [ -n "$num" ] || continue
        sudo efibootmgr -b "$num" -B >/dev/null || { warn "nao removi a entrada Boot$num"; rc=1; }
    done < <(printf '%s\n' "$entradas" | sed -nE 's/^Boot([0-9A-F]{4}).*/\1/p')
    $ms && { sudo rm -rf -- "$esp/EFI/Microsoft" || rc=1; }
    [ $rc -ne 0 ] || info "entrada e pasta do Windows removidas; confira com 'sudo efibootmgr'."
    return $rc
}

# Perfis de VPN do NetworkManager: ficam em /etc/NetworkManager/system-connections (root) e so voltam do
# backup se ele foi feito com sudo. No restore de 06/11 nao vieram.
confere_vpn_nm() {
    tem nmcli || return 0
    [ ${#SO[@]} -eq 0 ] || return 0
    if ! TMO 20 nmcli -t -f TYPE connection show 2>/dev/null | grep -qxE 'vpn|wireguard'; then
        warn "nenhum perfil de VPN (openvpn/wireguard) no NetworkManager. O backup so os leva com sudo (sem --sem-sudo); sem eles, recrie os perfis (nmcli connection import type openvpn file <arquivo.ovpn>). Usuario e senha/MFA voce digita ao conectar."
    fi
}

#==============================================================================
# Ordem de execucao
#==============================================================================
echo "Ubuntu $VERSION_ID ($CODENAME, $ARCH). Idempotente: pode rodar de novo."
# Gancho de teste: SETUP_SO_FUNCOES=1 carrega so as funcoes (testes/test-setup-funcoes.sh), sem rodar etapa.
# shellcheck disable=SC2317
if [ -n "${SETUP_SO_FUNCOES:-}" ]; then return 0 2>/dev/null || exit 0; fi
if [ ${#SO[@]} -eq 0 ] && [ -z "$RESTORE_ARG" ] && ! $AUTO_RESTORE; then
    warn "Sem --restore, o setup instala so as ferramentas (SSH, AWS, VPN e harness dependem do backup)."
fi
sudo -v || { erro "preciso do sudo"; exit 1; }

executa_etapa apt etapa_apt
executa_etapa restore etapa_restore
executa_etapa delta etapa_delta
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
executa_etapa cli-ia etapa_cli_ia
executa_etapa rclone etapa_rclone
executa_etapa tailscale etapa_tailscale
executa_etapa vpn etapa_vpn
executa_etapa apps etapa_apps
executa_etapa displaylink etapa_displaylink
executa_etapa zram etapa_zram
executa_etapa energia etapa_energia
executa_etapa playwright etapa_playwright
executa_etapa shell etapa_shell
executa_etapa pacotes etapa_pacotes
executa_etapa projetos etapa_projetos
executa_etapa git-integridade etapa_git_integridade
executa_etapa harness etapa_harness
executa_etapa efi-windows etapa_efi_windows
confere_vpn_nm

echo
warn "Logins que o backup nao resolve: 'gh auth login' (se o token expirou), 'aws sso login', 'kiro-cli login', 'claude' (login), 'gemini' (login), 'sudo tailscale up'."
AVISO_FIM="$(conf AVISO_FIM)"; [ -z "$AVISO_FIM" ] || warn "$AVISO_FIM"
if [ ${#NOTAS_FIM[@]} -gt 0 ]; then
    warn "Ficou de fora de proposito:"
    printf '    - %s\n' "${NOTAS_FIM[@]}"
fi
if [ ${#FALHAS[@]} -gt 0 ]; then
    warn "Setup concluido com falhas em: ${FALHAS[*]}. Rode de novo (so refaz o que falta) ou use --so <etapa>."
    [ ${#ATENCAO[@]} -eq 0 ] || warn "Alem disso, pede atencao (divergencia, nao falha): ${ATENCAO[*]}."
    exit 1
elif [ ${#ATENCAO[@]} -gt 0 ]; then
    warn "Setup concluido, mas pede atencao em: ${ATENCAO[*]} (divergencia, nao falha; a etapa parou sem terminar). Resolva e repita com --so <etapa>."
    exit 3
else
    info "Setup concluido sem falhas. Faca logout/login (grupo docker, shell zsh) e reinicie para os servicos do usuario subirem no boot."
fi
