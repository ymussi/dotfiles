#!/usr/bin/env bash

#==============================================================================
# Ubuntu DevOps Setup Script - AUTOMATED VERSION
# Para: Ubuntu 24.04 LTS
# Atualizado: Julho 2026
# Modo: Totalmente automatizado - sem interrupções
#
# Uso:
#   ./ubuntu-setup-automated.sh [caminho-do-backup]
#
#   caminho-do-backup   Diretorio gerado pelo backup.sh (contem dotfiles/,
#                       secrets.tar.gpg, inventory/, data/). Se omitido, o
#                       script procura automaticamente por algo em
#                       $HOME/ubuntu-backup/* e usa o mais recente. Se nada
#                       for encontrado, segue com defaults genericos (gera
#                       chave SSH nova, cria ambiente conda generico, etc).
#==============================================================================

set -uo pipefail
# Nao usamos "set -e" global: cada etapa de instalacao roda dentro de uma
# funcao chamada em contexto de teste (if funcao; then...), o que suspende
# errexit so para aquela etapa e permite logar e seguir em frente em vez de
# matar o script inteiro por causa de uma falha de rede/API pontual.

# ============================================
# CONFIGURAÇÕES FIXAS
# ============================================
GIT_USER_NAME="Yuri Mussi"
GIT_USER_EMAIL="ymussi@gmail.com"
GIT_EDITOR="vi"

# Token opcional do GitHub para levantar o rate limit da API (evita falhas
# esporadicas ao resolver "latest release" de k9s/stern/lazygit). Nao e
# obrigatorio.
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
skip()  { echo -e "${BLUE}[SKIP]${NC} $1"; }
section() { echo ""; echo "=============================================="; echo "$1"; echo "=============================================="; echo ""; }

# Roda uma funcao; se ela falhar, avisa e segue (nao mata o script).
run_step() {
    local desc="$1"; shift
    if "$@"; then
        return 0
    else
        warn "Etapa falhou, continuando mesmo assim: $desc"
        return 1
    fi
}

# Resolve a ultima tag de release de um repo GitHub, sem quebrar o script se
# a API falhar/der rate limit (ex.: chamadas anonimas sao limitadas a 60/h).
gh_latest_tag() {
    local repo="$1"
    local auth_header=()
    [ -n "$GITHUB_TOKEN" ] && auth_header=(-H "Authorization: token $GITHUB_TOKEN")
    curl -s "${auth_header[@]}" "https://api.github.com/repos/${repo}/releases/latest" \
        | grep -oP '"tag_name": *"\K[^"]+' || true
}

export DEBIAN_FRONTEND=noninteractive

#==============================================================================
# LOCALIZAR BACKUP
#==============================================================================
section "🚀 Iniciando Setup Automatizado"

BACKUP_DIR="${1:-}"
if [ -z "$BACKUP_DIR" ]; then
    CANDIDATE="$(ls -dt "$HOME"/ubuntu-backup/*/ 2>/dev/null | head -1 || true)"
    if [ -n "$CANDIDATE" ]; then
        BACKUP_DIR="${CANDIDATE%/}"
        info "Nenhum backup informado, usando o mais recente encontrado: $BACKUP_DIR"
    fi
fi

if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    info "📦 Backup: $BACKUP_DIR"
    HAS_BACKUP=true
else
    warn "Nenhum backup valido encontrado. Seguindo com configuracao genérica (sem restaurar dados antigos)."
    HAS_BACKUP=false
fi

info "Usuário: $GIT_USER_NAME"
info "Email: $GIT_USER_EMAIL"
info "Editor: $GIT_EDITOR"
echo ""

#==============================================================================
# ATUALIZAR SISTEMA
#==============================================================================
section "Atualizando sistema"

sudo rm -f /etc/apt/sources.list.d/spotify.list 2>/dev/null || true
sudo rm -f /etc/apt/trusted.gpg.d/spotify.gpg 2>/dev/null || true

sudo apt-get update
sudo apt-get upgrade -y

#==============================================================================
# FERRAMENTAS BÁSICAS
#==============================================================================
section "Instalando ferramentas básicas"

sudo apt-get install -y \
    curl wget git build-essential apt-transport-https ca-certificates \
    software-properties-common gnupg lsb-release jq unzip vim rsync \
    fonts-firacode xclip dconf-cli 2>/dev/null || true

info "✅ Ferramentas básicas instaladas"

#==============================================================================
# GIT CONFIGURATION
#==============================================================================
section "Configurando Git"

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global core.editor "$GIT_EDITOR"
git config --global pull.rebase false
git config --global init.defaultBranch main
git config --global core.autocrlf input

info "✅ Git configurado"

#==============================================================================
# RESTAURAR SEGREDOS (SSH, AWS, kube, docker, gnupg, terraform, zsh_secrets)
#==============================================================================
section "Restaurando segredos e credenciais"

mkdir -p ~/.ssh ~/.aws ~/.kube ~/.docker
chmod 700 ~/.ssh ~/.aws

restore_secrets() {
    local secrets_tar="$BACKUP_DIR/secrets.tar.gpg"
    [ -f "$secrets_tar" ] || { warn "secrets.tar.gpg não encontrado no backup, pulando restauração de segredos."; return 1; }

    local stage; stage="$(mktemp -d)"
    info "Digite a senha usada no backup.sh para descriptografar os segredos:"
    if ! gpg --batch --yes --pinentry-mode loopback -o "$stage/secrets.tar" -d "$secrets_tar"; then
        error "Falha ao descriptografar secrets.tar.gpg (senha incorreta?)."
        rm -rf "$stage"
        return 1
    fi
    tar -C "$stage" -xf "$stage/secrets.tar"
    rm -f "$stage/secrets.tar"

    [ -d "$stage/ssh" ]    && cp -rp "$stage/ssh/." ~/.ssh/
    [ -d "$stage/aws" ]    && cp -rp "$stage/aws/." ~/.aws/
    [ -f "$stage/kube/config" ] && cp -p "$stage/kube/config" ~/.kube/config
    [ -f "$stage/docker/config.json" ] && { mkdir -p ~/.docker; cp -p "$stage/docker/config.json" ~/.docker/config.json; }
    [ -d "$stage/gnupg" ]  && cp -rp "$stage/gnupg/." ~/.gnupg/
    [ -d "$stage/terraform.d" ] && { mkdir -p ~/.terraform.d; cp -rp "$stage/terraform.d/." ~/.terraform.d/; }
    [ -f "$stage/zsh_secrets" ] && cp -p "$stage/zsh_secrets" ~/.zsh_secrets
    [ -f "$stage/extra/tfc-github-key" ] && cp -p "$stage/extra/tfc-github-key" ~/tfc-github-key
    [ -f "$stage/extra/tfc-github-key.pub" ] && cp -p "$stage/extra/tfc-github-key.pub" ~/tfc-github-key.pub
    [ -f "$stage/extra/.terraformrc" ] && cp -p "$stage/extra/.terraformrc" ~/.terraformrc
    if [ -f "$stage/gh/hosts.yml" ]; then
        mkdir -p ~/.config/gh
        cp -p "$stage/gh/hosts.yml" ~/.config/gh/hosts.yml
        chmod 600 ~/.config/gh/hosts.yml
    fi
    if [ -d "$stage/dbeaver/DBeaverData" ]; then
        mkdir -p ~/.local/share
        cp -rp "$stage/dbeaver/DBeaverData" ~/.local/share/DBeaverData
        info "✓ conexões do DBeaver restauradas"
    fi
    # Perfis openvpn3 so podem ser importados depois que o pacote "openvpn3"
    # estiver instalado (mais adiante no script), entao so guardamos os
    # arquivos .ovpn aqui num lugar persistente e importamos depois.
    if [ -d "$stage/openvpn3" ]; then
        mkdir -p ~/.cache/openvpn3-profiles-to-import
        cp -rp "$stage/openvpn3/." ~/.cache/openvpn3-profiles-to-import/
    fi

    # Permissões corretas
    chmod 700 ~/.ssh ~/.aws ~/.gnupg 2>/dev/null || true
    find ~/.ssh -type f ! -name "*.pub" -exec chmod 600 {} \; 2>/dev/null || true
    find ~/.ssh -type f -name "*.pub" -exec chmod 644 {} \; 2>/dev/null || true
    chmod 600 ~/.aws/credentials ~/.aws/config 2>/dev/null || true
    chmod 600 ~/.zsh_secrets ~/tfc-github-key 2>/dev/null || true

    # Adiciona todas as chaves privadas encontradas (nomes variam por projeto)
    eval "$(ssh-agent -s)" >/dev/null 2>&1
    for key in ~/.ssh/*; do
        base="$(basename "$key")"
        case "$base" in
            *.pub|config|known_hosts|known_hosts.old|authorized_keys) continue ;;
        esac
        ssh-add "$key" 2>/dev/null && info "✓ chave SSH adicionada: $base"
    done

    rm -rf "$stage"
    info "✅ Segredos restaurados (SSH, AWS, kube, docker, gnupg, terraform, zsh_secrets)"
    return 0
}

if [ "$HAS_BACKUP" = true ]; then
    run_step "restaurar segredos do backup" restore_secrets
fi

# Gerar chave SSH se, mesmo depois da restauração, nao existir nenhuma
if ! ls ~/.ssh/*.pub >/dev/null 2>&1; then
    info "Nenhuma chave SSH encontrada, gerando uma nova..."
    ssh-keygen -t ed25519 -C "$GIT_USER_EMAIL" -f ~/.ssh/id_ed25519 -N "" -q
    eval "$(ssh-agent -s)" >/dev/null 2>&1
    ssh-add ~/.ssh/id_ed25519 2>/dev/null
    echo ""
    echo "====== SUA CHAVE SSH PÚBLICA (adicione no GitHub/GitLab) ======"
    cat ~/.ssh/id_ed25519.pub
    echo "==============================================================="
    echo ""
else
    info "✅ Chaves SSH presentes em ~/.ssh"
fi

#==============================================================================
# ZSH & OH-MY-ZSH
#==============================================================================
section "Instalando ZSH e Oh-My-Zsh"

if ! command -v zsh &> /dev/null; then
    sudo apt-get install -y zsh
    info "✅ ZSH instalado"
else
    skip "ZSH já instalado"
fi

if [ ! -d ~/.oh-my-zsh ]; then
    info "Instalando Oh-My-Zsh..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended > /dev/null 2>&1 || true
    info "✅ Oh-My-Zsh instalado"
else
    skip "Oh-My-Zsh já instalado"
fi

install_zsh_plugin() {
    local name="$1" url="$2"
    local dest=~/.oh-my-zsh/custom/plugins/"$name"
    if [ ! -d "$dest" ]; then
        git clone --depth 1 "$url" "$dest"
    fi
}
run_step "plugin zsh-autosuggestions" install_zsh_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions
run_step "plugin zsh-syntax-highlighting" install_zsh_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting

# Se temos um .zshrc real no backup, usamos ele (preserva TODAS as
# customizações, aliases e o source de ~/.zsh_secrets). So cai no template
# generico abaixo se nao ha backup.
if [ "$HAS_BACKUP" = true ] && [ -f "$BACKUP_DIR/dotfiles/.zshrc" ]; then
    cp -p "$BACKUP_DIR/dotfiles/.zshrc" ~/.zshrc
    info "✅ .zshrc restaurado do backup (preferências originais preservadas)"
else
cat > ~/.zshrc << 'ZSHRC_EOF'
# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Theme
ZSH_THEME="robbyrussell"

# Plugins
plugins=(
    aws
    git
    docker
    kubectl
    terraform
    zsh-syntax-highlighting
    zsh-autosuggestions
)

source $ZSH/oh-my-zsh.sh

# ============================================
# Custom Aliases - Yuri Mussi DevOps
# ============================================

alias s='source ~/.zshrc'

# System aliases
alias ls='ls -lha'
alias ll='ls -lha'
alias la='ls -la'
alias ..='cd ..'
alias ...='cd ../..'
alias atualizar='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y && sudo apt autoclean'
alias myip='curl ifconfig.me'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit -m'
alias gp='git push'
alias gl='git pull'
alias gco='git checkout'
alias gb='git branch'
alias glog='git log --oneline --graph --decorate'
alias lg='lazygit'

# Docker aliases (docker-compose standalone nao existe mais - e plugin "docker compose")
alias d='docker'
alias dc='docker compose'
alias dps='docker ps'
alias di='docker images'
alias dex='docker exec -it'
alias dlog='docker logs -f'
alias dprune='docker system prune -af'

# Kubernetes aliases
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgd='kubectl get deploy'
alias kl='kubectl logs -f'
alias kex='kubectl exec -it'
alias kctx='kubectx'
alias kns='kubens'

# Terraform aliases
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfd='terraform destroy'
alias tfv='terraform validate'
alias tff='terraform fmt -recursive'

# AWS aliases
alias awsp='export AWS_PROFILE='
alias awsl='aws configure list-profiles'

# Jupyter aliases
alias jlab='conda activate jupyter && jupyter lab'
alias jnb='conda activate jupyter && jupyter notebook'
alias deact='conda deactivate'
alias condaoff='conda deactivate'

# Segredos (senhas, API keys) ficam fora do controle de versão
[ -f ~/.zsh_secrets ] && source ~/.zsh_secrets

# Funções úteis
awslogin() {
    aws sso login --profile $1
}

kubeconfig() {
    export KUBECONFIG=~/.kube/$1
}

parse_git_branch() {
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export PATH="$HOME/.local/bin:$PATH"
ZSHRC_EOF
    info "✅ .zshrc genérico criado (nenhum backup disponível)"
fi

if [ "$SHELL" != "$(which zsh)" ]; then
    info "Configurando ZSH como shell padrão..."
    sudo usermod -s "$(which zsh)" "$USER"
    info "✅ ZSH configurado como shell padrão (aplica após novo login)"
fi

#==============================================================================
# FZF
#==============================================================================
section "Instalando FZF"

if [ ! -d ~/.fzf ]; then
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
    yes | ~/.fzf/install --all --no-bash --no-fish --key-bindings --completion --no-update-rc
    info "✅ FZF instalado"
else
    skip "FZF já instalado"
fi

#==============================================================================
# PYTHON
#==============================================================================
section "Instalando Python"

sudo apt-get install -y python3 python3-pip python3-venv python3-dev
info "✅ Python instalado"

#==============================================================================
# MINICONDA & AMBIENTES CONDA
#==============================================================================
section "Instalando Miniconda"

if [ ! -d "$HOME/miniconda3" ]; then
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p "$HOME/miniconda3"
    rm /tmp/miniconda.sh

    "$HOME/miniconda3/bin/conda" init bash > /dev/null
    "$HOME/miniconda3/bin/conda" init zsh > /dev/null
    "$HOME/miniconda3/bin/conda" config --set channel_priority flexible
    "$HOME/miniconda3/bin/conda" config --set auto_activate_base false
    info "✅ Miniconda instalado"
else
    skip "Miniconda já instalado"
fi

CONDA_BIN="$HOME/miniconda3/bin/conda"

restore_conda_envs() {
    local any=false
    for yml in "$BACKUP_DIR"/inventory/conda/*.yml; do
        [ -f "$yml" ] || continue
        any=true
        local env_name; env_name="$(basename "$yml" .yml)"
        if "$CONDA_BIN" env list 2>/dev/null | grep -q "^${env_name} "; then
            skip "conda env '$env_name' já existe"
        else
            info "Recriando conda env '$env_name' a partir do backup..."
            "$CONDA_BIN" env create -f "$yml" 2>&1 | tail -5 || warn "Falha ao recriar env '$env_name'"
        fi
    done
    [ "$any" = true ]
}

if [ "$HAS_BACKUP" = true ] && ls "$BACKUP_DIR"/inventory/conda/*.yml >/dev/null 2>&1; then
    run_step "restaurar ambientes conda do backup" restore_conda_envs
else
    if ! "$CONDA_BIN" env list 2>/dev/null | grep -q "^jupyter "; then
        info "Nenhum backup de conda encontrado, criando ambiente genérico 'jupyter'..."
        "$CONDA_BIN" create -n jupyter python=3.11 -y
        source "$HOME/miniconda3/bin/activate" jupyter
        "$CONDA_BIN" install -y -c conda-forge jupyter jupyterlab notebook pandas numpy matplotlib seaborn scikit-learn boto3 requests
        pip install jupyterlab-git ipywidgets
        conda deactivate
        info "✅ Ambiente 'jupyter' criado"
    fi
fi

#==============================================================================
# NODE.JS (via NVM)
#==============================================================================
section "Instalando Node.js via NVM"

if [ ! -d "$HOME/.nvm" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

NODE_TARGET="--lts"
if [ "$HAS_BACKUP" = true ] && [ -f "$BACKUP_DIR/inventory/node-version.txt" ]; then
    NODE_TARGET="$(cat "$BACKUP_DIR/inventory/node-version.txt")"
fi
nvm install "$NODE_TARGET" >/dev/null 2>&1 || nvm install --lts
nvm alias default "$(nvm current)" >/dev/null 2>&1 || true
info "✅ Node.js $(node --version 2>/dev/null) instalado"

restore_npm_globals() {
    local list="$BACKUP_DIR/inventory/npm-global.txt"
    [ -f "$list" ] || return 1
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        case "$pkg" in npm|corepack) continue ;; esac
        npm install -g "$pkg" >/dev/null 2>&1 && info "✓ npm -g $pkg" || warn "Falha ao instalar npm -g $pkg"
    done < "$list"
    return 0
}

if [ "$HAS_BACKUP" = true ]; then
    run_step "restaurar pacotes npm globais" restore_npm_globals
fi

# Garantia extra: gemini-cli e usado direto (alias "gem") e pode ter sido
# instalado na maquina de origem via npm do sistema (fora do nvm), o que o
# backup antigo pode nao ter capturado - reinstala aqui independente do
# inventario, e' idempotente.
if ! command -v gemini >/dev/null 2>&1; then
    npm install -g @google/gemini-cli >/dev/null 2>&1 && info "✓ gemini-cli instalado" || warn "Falha ao instalar gemini-cli"
else
    skip "gemini-cli já instalado"
fi

#==============================================================================
# AWS CLI V2
#==============================================================================
section "Instalando AWS CLI v2"

if ! command -v aws &> /dev/null; then
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp/
    sudo /tmp/aws/install --update
    rm -rf /tmp/aws /tmp/awscliv2.zip

    curl -s "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "/tmp/session-manager.deb"
    sudo dpkg -i /tmp/session-manager.deb > /dev/null
    rm /tmp/session-manager.deb

    info "✅ AWS CLI $(aws --version) instalado"
else
    skip "AWS CLI já instalado"
fi

#==============================================================================
# DOCKER
#==============================================================================
section "Instalando Docker"

if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"

    info "✅ Docker $(docker --version) instalado (docker compose via plugin, sem hífen)"
else
    skip "Docker já instalado"
fi

#==============================================================================
# TERRAFORM
#==============================================================================
section "Instalando Terraform"

if ! command -v terraform &> /dev/null; then
    wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y terraform
    info "✅ Terraform $(terraform --version | head -1) instalado"
else
    skip "Terraform já instalado"
fi

#==============================================================================
# KUBECTL
#==============================================================================
section "Instalando kubectl"

install_kubectl() {
    local ver; ver="$(curl -Ls https://dl.k8s.io/release/stable.txt)"
    [ -n "$ver" ] || return 1
    curl -Ls "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl" -o /tmp/kubectl
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
}

if ! command -v kubectl &> /dev/null; then
    run_step "instalar kubectl" install_kubectl && info "✅ kubectl instalado"
else
    skip "kubectl já instalado"
fi

#==============================================================================
# HELM
#==============================================================================
section "Instalando Helm"

if ! command -v helm &> /dev/null; then
    run_step "instalar helm" bash -c 'curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1' \
        && info "✅ Helm instalado"
else
    skip "Helm já instalado"
fi

#==============================================================================
# K9S
#==============================================================================
section "Instalando k9s"

install_k9s() {
    local arch; arch="$(uname -m)"
    local k9s_arch="amd64"
    [ "$arch" = "aarch64" ] && k9s_arch="arm64"

    local version; version="$(gh_latest_tag derailed/k9s)"
    if [ -z "$version" ]; then
        warn "Não consegui resolver a última versão do k9s (rate limit da API do GitHub?). Pulando."
        return 1
    fi
    wget -q "https://github.com/derailed/k9s/releases/download/${version}/k9s_Linux_${k9s_arch}.tar.gz" -O /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
    sudo mv /tmp/k9s /usr/local/bin/
    rm -f /tmp/k9s.tar.gz
}

if ! command -v k9s &> /dev/null; then
    run_step "instalar k9s" install_k9s && info "✅ k9s instalado"
else
    skip "k9s já instalado"
fi

#==============================================================================
# ARGOCD CLI
#==============================================================================
section "Instalando ArgoCD CLI"

install_argocd() {
    curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
}

if ! command -v argocd &> /dev/null; then
    run_step "instalar argocd" install_argocd && info "✅ ArgoCD CLI instalado"
else
    skip "ArgoCD CLI já instalado"
fi

#==============================================================================
# GITHUB CLI (gh) - para auth não-interativa via hosts.yml restaurado
#==============================================================================
section "Instalando GitHub CLI"

if ! command -v gh &> /dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y gh
    info "✅ GitHub CLI instalado"
else
    skip "GitHub CLI já instalado"
fi

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    gh auth setup-git 2>/dev/null || true
    info "✅ gh já autenticado (restaurado do backup) - git via HTTPS configurado"
else
    warn "gh não autenticado. Se preferir HTTPS ao invés de SSH para o GitHub, rode manualmente: gh auth login"
fi

#==============================================================================
# OPENVPN3 & XFREERDP3
#==============================================================================
section "Instalando OpenVPN3 e FreeRDP3"

if ! command -v openvpn3 &> /dev/null; then
    install_openvpn3() {
        curl -fsSL https://packages.openvpn.net/packages-repo.gpg | sudo gpg --dearmor -o /usr/share/keyrings/openvpn.gpg
        echo "deb [signed-by=/usr/share/keyrings/openvpn.gpg] https://packages.openvpn.net/openvpn3/debian $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/openvpn3.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y openvpn3
    }
    run_step "instalar openvpn3" install_openvpn3 && info "✅ openvpn3 instalado"
else
    skip "openvpn3 já instalado"
fi

if ! command -v xfreerdp3 &> /dev/null; then
    sudo apt-get install -y freerdp3-x11 && info "✅ freerdp3-x11 instalado" || warn "Falha ao instalar freerdp3-x11"
else
    skip "xfreerdp3 já instalado"
fi

# Importa perfis openvpn3 extraídos do backup (deixados em
# ~/.cache/openvpn3-profiles-to-import pela etapa de restauração de segredos).
if command -v openvpn3 >/dev/null 2>&1 && [ -d ~/.cache/openvpn3-profiles-to-import ]; then
    for ovpn in ~/.cache/openvpn3-profiles-to-import/*.ovpn; do
        [ -f "$ovpn" ] || continue
        name="$(basename "$ovpn" .ovpn)"
        if openvpn3 configs-list 2>/dev/null | grep -q "^${name} "; then
            skip "perfil openvpn3 '$name' já existe"
        else
            openvpn3 config-import --config "$ovpn" --name "$name" --persistent >/dev/null 2>&1 \
                && info "✓ perfil openvpn3 '$name' importado" \
                || warn "Falha ao importar perfil openvpn3 '$name'"
        fi
    done
    rm -rf ~/.cache/openvpn3-profiles-to-import
fi

#==============================================================================
# VSCODE
#==============================================================================
section "Instalando VS Code"

if ! command -v code &> /dev/null; then
    wget -q -O /tmp/packages.microsoft.gpg https://packages.microsoft.com/keys/microsoft.asc
    gpg --dearmor < /tmp/packages.microsoft.gpg > /tmp/packages.microsoft.gpg.dearmored 2>/dev/null
    sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg.dearmored /etc/apt/keyrings/packages.microsoft.gpg
    sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
    rm -f /tmp/packages.microsoft.gpg /tmp/packages.microsoft.gpg.dearmored

    sudo apt-get update -qq
    sudo apt-get install -y -qq code
    info "✅ VS Code instalado"
else
    skip "VS Code já instalado"
fi

install_vscode_extensions() {
    local list="$BACKUP_DIR/inventory/vscode-extensions.txt"
    [ -f "$list" ] || return 1
    while IFS= read -r ext; do
        [ -z "$ext" ] && continue
        code --install-extension "$ext" --force > /dev/null 2>&1
    done < "$list"
    return 0
}

if [ "$HAS_BACKUP" = true ] && [ -f "$BACKUP_DIR/inventory/vscode-extensions.txt" ]; then
    run_step "restaurar extensões do VS Code" install_vscode_extensions && info "✅ Extensões do VS Code restauradas do backup"
else
    for ext in ms-python.python ms-azuretools.vscode-docker hashicorp.terraform \
               ms-kubernetes-tools.vscode-kubernetes-tools eamodio.gitlens \
               esbenp.prettier-vscode dbaeumer.vscode-eslint ms-vscode-remote.remote-ssh \
               redhat.vscode-yaml golang.go; do
        code --install-extension "$ext" --force > /dev/null 2>&1
    done
    info "✅ Extensões padrão do VS Code instaladas"
fi

if [ "$HAS_BACKUP" = true ] && [ -d "$BACKUP_DIR/inventory/vscode-user" ]; then
    mkdir -p ~/.config/Code/User
    cp -rp "$BACKUP_DIR"/inventory/vscode-user/. ~/.config/Code/User/
    info "✅ settings/keybindings/snippets do VS Code restaurados do backup"
fi

#==============================================================================
# APPS DE DESKTOP (Chrome, Slack, Spotify, DBeaver, Postman, Telegram)
#==============================================================================
section "Instalando aplicativos de desktop"

if ! command -v google-chrome &> /dev/null; then
    install_chrome() {
        wget -q -O /tmp/google-chrome.gpg https://dl.google.com/linux/linux_signing_key.pub
        sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg < /tmp/google-chrome.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
        rm -f /tmp/google-chrome.gpg
        sudo apt-get update
        sudo apt-get install -y google-chrome-stable
    }
    run_step "instalar Chrome" install_chrome && info "✅ Google Chrome instalado"
else
    skip "Google Chrome já instalado"
fi

for snap_app in slack spotify postman telegram-desktop; do
    if ! snap list 2>/dev/null | grep -q "^${snap_app} "; then
        classic_flag=""
        [ "$snap_app" = "slack" ] && classic_flag="--classic"
        sudo snap install "$snap_app" $classic_flag > /dev/null 2>&1 && info "✅ $snap_app instalado" || warn "Falha ao instalar $snap_app"
    else
        skip "$snap_app já instalado"
    fi
done

if ! command -v dbeaver &> /dev/null; then
    install_dbeaver() {
        wget -q -O /tmp/dbeaver.gpg https://dbeaver.io/debs/dbeaver.gpg.key
        sudo gpg --dearmor -o /usr/share/keyrings/dbeaver.gpg < /tmp/dbeaver.gpg
        echo "deb [signed-by=/usr/share/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" | sudo tee /etc/apt/sources.list.d/dbeaver.list > /dev/null
        rm -f /tmp/dbeaver.gpg
        sudo apt-get update
        sudo apt-get install -y dbeaver-ce
    }
    run_step "instalar DBeaver" install_dbeaver && info "✅ DBeaver instalado"
else
    skip "DBeaver já instalado"
fi

#==============================================================================
# FERRAMENTAS ADICIONAIS (kubectx/kubens, stern, trivy, lazygit, btop, neofetch)
#==============================================================================
section "Instalando ferramentas adicionais"

if [ ! -f /usr/local/bin/kubectx ]; then
    install_kubectx() {
        sudo git clone --depth 1 https://github.com/ahmetb/kubectx /opt/kubectx 2>&1 | grep -v "already exists" || true
        sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
        sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
    }
    run_step "instalar kubectx/kubens" install_kubectx && info "✓ kubectx/kubens instalados"
fi

if ! command -v stern &> /dev/null; then
    install_stern() {
        local version; version="$(gh_latest_tag stern/stern)"
        [ -n "$version" ] || return 1
        wget -q "https://github.com/stern/stern/releases/download/${version}/stern_${version#v}_linux_amd64.tar.gz" -O /tmp/stern.tar.gz
        tar -xzf /tmp/stern.tar.gz -C /tmp stern
        sudo mv /tmp/stern /usr/local/bin/
        rm -f /tmp/stern.tar.gz
    }
    run_step "instalar stern" install_stern && info "✓ stern instalado"
fi

if ! command -v trivy &> /dev/null; then
    install_trivy() {
        wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
        echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y trivy
    }
    run_step "instalar trivy" install_trivy && info "✓ trivy instalado"
fi

if ! command -v lazygit &> /dev/null; then
    install_lazygit() {
        local version; version="$(gh_latest_tag jesseduffield/lazygit | sed 's/^v//')"
        [ -n "$version" ] || return 1
        curl -sLo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_Linux_x86_64.tar.gz"
        tar -xf /tmp/lazygit.tar.gz -C /tmp lazygit
        sudo install /tmp/lazygit /usr/local/bin
        rm -f /tmp/lazygit /tmp/lazygit.tar.gz
    }
    run_step "instalar lazygit" install_lazygit && info "✓ lazygit instalado"
fi

if ! command -v btop &> /dev/null; then
    sudo snap install btop > /dev/null 2>&1 && info "✓ btop instalado" || warn "Falha ao instalar btop"
fi

if ! command -v neofetch &> /dev/null; then
    sudo apt-get install -y neofetch && info "✓ neofetch instalado"
fi

info "✅ Ferramentas adicionais instaladas"

#==============================================================================
# RESTAURAR DADOS (Documents, Pictures, projects, Downloads se presente)
#==============================================================================
section "Restaurando dados do usuário"

if [ "$HAS_BACKUP" = true ] && [ -d "$BACKUP_DIR/data" ]; then
    for dir in "$BACKUP_DIR"/data/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        mkdir -p "$HOME/$name"
        info "Restaurando $name ..."
        rsync -a "$dir" "$HOME/$name/" 2>/dev/null || warn "rsync teve avisos em $name (continuando)"
    done
    info "✅ Dados do usuário restaurados"
else
    mkdir -p ~/projects
    warn "Sem backup de dados: apenas ~/projects vazio foi criado"
fi

mkdir -p ~/.kube

#==============================================================================
# GNOME SETTINGS
#==============================================================================
section "Configurando GNOME"

if [ "$HAS_BACKUP" = true ] && [ -f "$BACKUP_DIR/inventory/gnome-dconf.txt" ] && command -v dconf &> /dev/null; then
    dconf load / < "$BACKUP_DIR/inventory/gnome-dconf.txt" 2>/dev/null \
        && info "✅ Configurações GNOME restauradas do backup" \
        || warn "Falha ao restaurar dconf, aplicando defaults"
else
    gsettings set org.gnome.mutter workspaces-only-on-primary false 2>/dev/null || true
    gsettings set org.gnome.desktop.wm.preferences num-workspaces 4 2>/dev/null || true
    info "✅ GNOME configurado com defaults"
fi

#==============================================================================
# CRONTAB
#==============================================================================
if [ "$HAS_BACKUP" = true ] && [ -s "$BACKUP_DIR/inventory/crontab.txt" ]; then
    crontab "$BACKUP_DIR/inventory/crontab.txt" && info "✅ Crontab restaurado do backup"
fi

#==============================================================================
# CLEANUP
#==============================================================================
section "Limpando arquivos temporários"

sudo apt-get autoremove -y
sudo apt-get clean

info "✅ Limpeza concluída"

#==============================================================================
# FINALIZAÇÃO
#==============================================================================
section "🎉 Setup Completo!"

echo ""
echo "=============================================="
echo "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "=============================================="
echo ""
echo "📦 Ferramentas instaladas:"
echo "  ✓ Git, SSH keys, ZSH + Oh-My-Zsh + plugins"
echo "  ✓ Miniconda + ambientes conda (restaurados ou genérico)"
echo "  ✓ Node.js (via NVM) + pacotes npm globais"
echo "  ✓ Docker + Docker Compose (plugin)"
echo "  ✓ AWS CLI v2 + Session Manager"
echo "  ✓ Terraform, kubectl, Helm, k9s, ArgoCD CLI"
echo "  ✓ GitHub CLI, OpenVPN3, FreeRDP3"
echo "  ✓ VS Code + extensões"
echo "  ✓ Chrome, Slack, Spotify, DBeaver, Postman, Telegram"
echo "  ✓ kubectx, kubens, stern, trivy, lazygit, btop, neofetch"
echo ""
if [ "$HAS_BACKUP" = true ]; then
echo "📁 Dados restaurados do backup: $BACKUP_DIR"
else
echo "⚠️  Nenhum backup foi usado - dados e credenciais são novos/vazios."
fi
echo ""
echo "🔑 Chaves SSH disponíveis:"
ls ~/.ssh/*.pub 2>/dev/null || echo "  (nenhuma)"
echo ""
echo "💡 Próximos passos manuais (não dá pra automatizar com segurança):"
echo "  1. Se a chave SSH é nova, adicione-a no GitHub/GitLab."
echo "  2. Se usa 'gh auth login' pela primeira vez (sem backup de ~/.config/gh), rode e autentique com seu usuário/token."
echo "  3. 'aws sso login --profile <perfil>' para renovar sessões SSO (tokens SSO expiram em horas, sempre exigem"
echo "     aprovação no navegador - isso é proposital, não dá pra pular)."
echo "  4. 'vpnup' (openvpn3) vai pedir usuário/senha na primeira conexão - a senha não é restaurada automaticamente"
echo "     de propósito (só o perfil de conexão foi importado, ver ~/.zsh_secrets pra lembrar a senha antiga)."
echo "  5. Login manual em apps com conta própria: Chrome, Slack, Spotify, Telegram, Postman (não são arquivo, são OAuth/conta)."
echo "  6. Imagens/containers/volumes do Docker da máquina antiga NÃO foram copiados (ficam só na origem)."
echo "  7. Reinicie a sessão (logout/login ou 'sudo reboot') para: grupo docker, shell padrão zsh."
echo ""
echo "=============================================="
echo "Desenvolvido por Yuri Mussi - Julho 2026"
echo "=============================================="
echo ""
echo "⚠️  É ALTAMENTE RECOMENDADO REINICIAR O SISTEMA!"
echo "  sudo reboot"
echo ""
