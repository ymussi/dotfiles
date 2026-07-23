#!/bin/bash

#==============================================================================
# Ubuntu DevOps Setup Script - AUTOMATED VERSION
# Para: Ubuntu 24.04 LTS
# Atualizado: November 2025
# Modo: Totalmente automatizado - sem interrupções
#==============================================================================

set -e  # Exit on error

# ============================================
# CONFIGURAÇÕES FIXAS
# ============================================
GIT_USER_NAME="Yuri Mussi"
GIT_USER_EMAIL="ymussi@gmail.com"
GIT_EDITOR="vi"
BACKUP_DIR="${HOME}/Documents/backup-thinkpad-1"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para print colorido
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo ""
    echo "=============================================="
    echo "$1"
    echo "=============================================="
    echo ""
}

print_skip() {
    echo -e "${BLUE}[SKIP]${NC} $1"
}

#==============================================================================
# CONFIGURAÇÃO INICIAL
#==============================================================================

print_section "🚀 Iniciando Setup Automatizado"
print_info "Usuário: $GIT_USER_NAME"
print_info "Email: $GIT_USER_EMAIL"
print_info "Editor: $GIT_EDITOR"
print_info "Backup: $BACKUP_DIR"
echo ""

print_section "Atualizando sistema"

# Remover repositório Spotify problemático se existir
sudo rm -f /etc/apt/sources.list.d/spotify.list 2>/dev/null || true
sudo rm -f /etc/apt/trusted.gpg.d/spotify.gpg 2>/dev/null || true

sudo apt-get update
sudo apt-get upgrade -y

#==============================================================================
# FERRAMENTAS BÁSICAS
#==============================================================================

print_section "Instalando ferramentas básicas"

sudo apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    apt-transport-https \
    ca-certificates \
    software-properties-common \
    gnupg \
    lsb-release \
    jq \
    unzip \
    vim \
    fonts-firacode \
    xclip 2>/dev/null || true

print_info "✅ Ferramentas básicas instaladas"

#==============================================================================
# GIT CONFIGURATION
#==============================================================================

print_section "Configurando Git"

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global core.editor "$GIT_EDITOR"
git config --global pull.rebase false
git config --global init.defaultBranch main
git config --global core.autocrlf input

print_info "✅ Git configurado"

#==============================================================================
# SSH KEY & AWS CONFIG RESTORE
#==============================================================================

print_section "Configurando SSH e AWS"

mkdir -p ~/.ssh
mkdir -p ~/.aws

# Verificar e restaurar backup automaticamente
if [ -d "$BACKUP_DIR" ]; then
    print_info "🔍 Backup encontrado em: $BACKUP_DIR"
    
    # Restaurar SSH
    if [ -d "$BACKUP_DIR/.ssh" ]; then
        print_info "Restaurando SSH do backup..."
        cp -rp "$BACKUP_DIR/.ssh/"* ~/.ssh/ 2>/dev/null || true
        
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/id_rsa 2>/dev/null || true
        chmod 600 ~/.ssh/argocd_deploy_key 2>/dev/null || true
        chmod 644 ~/.ssh/*.pub 2>/dev/null || true
        chmod 600 ~/.ssh/known_hosts 2>/dev/null || true
        chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
        
        eval "$(ssh-agent -s)" >/dev/null 2>&1
        ssh-add ~/.ssh/id_rsa 2>/dev/null && print_info "✓ id_rsa adicionado"
        ssh-add ~/.ssh/argocd_deploy_key 2>/dev/null && print_info "✓ argocd_deploy_key adicionado"
        
        print_info "✅ SSH restaurado do backup"
    fi
    
    # Restaurar AWS
    if [ -d "$BACKUP_DIR/.aws" ]; then
        print_info "Restaurando AWS do backup..."
        cp -rp "$BACKUP_DIR/.aws/"* ~/.aws/ 2>/dev/null || true
        
        chmod 700 ~/.aws
        chmod 600 ~/.aws/credentials 2>/dev/null || true
        chmod 600 ~/.aws/config 2>/dev/null || true
        
        print_info "✅ AWS restaurado do backup"
    fi
else
    print_warn "Backup não encontrado em: $BACKUP_DIR"
fi

# Gerar nova chave SSH se não existir
if [ ! -f ~/.ssh/id_rsa ]; then
    print_info "Gerando nova chave SSH..."
    ssh-keygen -t rsa -b 4096 -C "$GIT_USER_EMAIL" -f ~/.ssh/id_rsa -N "" -q
    eval "$(ssh-agent -s)" >/dev/null 2>&1
    ssh-add ~/.ssh/id_rsa 2>/dev/null
    
    print_info "✅ Nova chave SSH gerada"
    echo ""
    echo "====== SUA CHAVE SSH PÚBLICA ======"
    cat ~/.ssh/id_rsa.pub
    echo "==================================="
    echo ""
else
    print_info "✅ Chave SSH já existe"
fi

#==============================================================================
# ZSH & OH-MY-ZSH
#==============================================================================

print_section "Instalando ZSH e Oh-My-Zsh"

if ! command -v zsh &> /dev/null; then
    sudo apt-get install -y zsh
    print_info "✅ ZSH instalado"
else
    print_skip "ZSH já instalado"
fi

# Remover Oh-My-Zsh antigo se existir e reinstalar
if [ -d ~/.oh-my-zsh ]; then
    print_info "Removendo Oh-My-Zsh antigo..."
    rm -rf ~/.oh-my-zsh
fi

print_info "Instalando Oh-My-Zsh..."
RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended > /dev/null 2>&1 || true
print_info "✅ Oh-My-Zsh instalado"

# Plugins do ZSH
print_info "Instalando plugins do ZSH..."
rm -rf ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions 2>/dev/null || true
rm -rf ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting 2>/dev/null || true

git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

# Configurar .zshrc com suas preferências
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

# Bash Profile compatibility
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

# Docker aliases
alias d='docker'
alias dc='docker-compose'
alias dps='docker ps'
alias di='docker images'
alias dex='docker exec -it'
alias dlog='docker logs -f'
alias dprune='docker system prune -af'
alias aws-nuke='docker run --rm -v ~/.aws:/home/aws-nuke/.aws -v $(pwd):/tmp quay.io/rebuy/aws-nuke:latest'

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
alias jpy='cd ~/projects/notebooks && conda activate jupyter && jupyter notebook'
alias jlab='conda activate jupyter && jupyter lab'
alias jnb='conda activate jupyter && jupyter notebook'
alias deact='conda deactivate'
alias condaoff='conda deactivate'

# Funções úteis
awslogin() {
    aws sso login --profile $1
}

kubeconfig() {
    export KUBECONFIG=~/.kube/$1
}

# Git branch no prompt
parse_git_branch() {
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

ZSHRC_EOF

print_info "✅ .zshrc configurado com suas preferências"

# Tornar ZSH o shell padrão (sem pedir confirmação)
if [ "$SHELL" != "$(which zsh)" ]; then
    print_info "Configurando ZSH como shell padrão..."
    sudo usermod -s $(which zsh) $USER
    print_info "✅ ZSH configurado como shell padrão (aplicará após reboot)"
fi

print_info "✅ ZSH e Oh-My-Zsh configurados"

#==============================================================================
# FZF
#==============================================================================

print_section "Instalando FZF"

if [ ! -d ~/.fzf ]; then
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
    yes | ~/.fzf/install --all --no-bash --no-fish --key-bindings --completion --no-update-rc
    print_info "✅ FZF instalado"
else
    print_skip "FZF já instalado"
fi

#==============================================================================
# PYTHON
#==============================================================================

print_section "Instalando Python"

sudo apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev

print_info "✅ Python instalado"

#==============================================================================
# MINICONDA & JUPYTER
#==============================================================================

print_section "Instalando Miniconda"

if [ ! -d "$HOME/miniconda3" ]; then
    print_info "Baixando Miniconda..."
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
    
    print_info "Instalando Miniconda..."
    bash /tmp/miniconda.sh -b -p $HOME/miniconda3
    rm /tmp/miniconda.sh
    
    # Inicializar conda
    $HOME/miniconda3/bin/conda init bash
    $HOME/miniconda3/bin/conda init zsh
    
    # Configurar conda
    eval "$($HOME/miniconda3/bin/conda shell.bash hook)"
    
    # Aceitar termos automaticamente
    print_info "Aceitando termos do Conda..."
    conda config --set channel_priority flexible
    conda config --set auto_activate_base false
    
    print_info "Criando ambiente Jupyter..."
    conda create -n jupyter python=3.11 -y
    
    # Ativar ambiente
    source $HOME/miniconda3/bin/activate jupyter
    
    print_info "Instalando pacotes Python..."
    conda install -y -c conda-forge \
        jupyter \
        jupyterlab \
        notebook \
        pandas \
        numpy \
        matplotlib \
        seaborn \
        scikit-learn \
        boto3 \
        requests
    
    pip install \
        jupyterlab-git \
        ipywidgets
    
    conda deactivate
    
    print_info "✅ Miniconda e Jupyter instalados"
else
    print_skip "Miniconda já instalado"
fi

#==============================================================================
# NODE.JS (via NVM)
#==============================================================================

print_section "Instalando Node.js via NVM"

if [ ! -d "$HOME/.nvm" ]; then
    print_info "Instalando NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    print_info "Instalando Node.js LTS..."
    nvm install --lts
    nvm use --lts
    nvm alias default lts/*
    
    print_info "✅ Node.js $(node --version) instalado"
else
    print_skip "NVM já instalado"
fi

#==============================================================================
# AWS CLI V2
#==============================================================================

print_section "Instalando AWS CLI v2"

if ! command -v aws &> /dev/null; then
    print_info "Baixando AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip /tmp/awscliv2.zip -d /tmp/
    
    print_info "Instalando AWS CLI..."
    sudo /tmp/aws/install --update
    rm -rf /tmp/aws /tmp/awscliv2.zip
    
    print_info "Instalando Session Manager Plugin..."
    curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "/tmp/session-manager.deb"
    sudo dpkg -i /tmp/session-manager.deb
    rm /tmp/session-manager.deb
    
    print_info "✅ AWS CLI $(aws --version) instalado"
else
    print_skip "AWS CLI já instalado"
fi

#==============================================================================
# DOCKER
#==============================================================================

print_section "Instalando Docker"

if ! command -v docker &> /dev/null; then
    print_info "Configurando repositório Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    print_info "Instalando Docker..."
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    sudo usermod -aG docker $USER
    
    print_info "✅ Docker $(docker --version) instalado"
else
    print_skip "Docker já instalado"
fi

#==============================================================================
# TERRAFORM
#==============================================================================

print_section "Instalando Terraform"

if ! command -v terraform &> /dev/null; then
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    
    sudo apt-get update
    sudo apt-get install -y terraform
    
    print_info "✅ Terraform $(terraform --version | head -1) instalado"
else
    print_skip "Terraform já instalado"
fi

#==============================================================================
# KUBECTL
#==============================================================================

print_section "Instalando kubectl"

if ! command -v kubectl &> /dev/null; then
    curl -LO -s "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    
    print_info "✅ kubectl $(kubectl version --client --short 2>/dev/null) instalado"
else
    print_skip "kubectl já instalado"
fi

#==============================================================================
# HELM
#==============================================================================

print_section "Instalando Helm"

if ! command -v helm &> /dev/null; then
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1
    print_info "✅ Helm $(helm version --short) instalado"
else
    print_skip "Helm já instalado"
fi

#==============================================================================
# K9S
#==============================================================================

print_section "Instalando k9s"

if ! command -v k9s &> /dev/null; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        K9S_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        K9S_ARCH="arm64"
    fi
    
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    print_info "Baixando k9s..."
    wget https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${K9S_ARCH}.tar.gz
    tar -xzf k9s_Linux_${K9S_ARCH}.tar.gz k9s
    sudo mv k9s /usr/local/bin/
    rm k9s_Linux_${K9S_ARCH}.tar.gz
    
    print_info "✅ k9s instalado"
else
    print_skip "k9s já instalado"
fi

#==============================================================================
# ARGOCD CLI
#==============================================================================

print_section "Instalando ArgoCD CLI"

if ! command -v argocd &> /dev/null; then
    curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
    rm /tmp/argocd
    
    print_info "✅ ArgoCD CLI instalado"
else
    print_skip "ArgoCD CLI já instalado"
fi

#==============================================================================
# VSCODE
#==============================================================================

print_section "Instalando VS Code"

if ! command -v code &> /dev/null; then
    wget -O /tmp/packages.microsoft.gpg https://packages.microsoft.com/keys/microsoft.asc
    gpg --dearmor < /tmp/packages.microsoft.gpg > /tmp/packages.microsoft.gpg.dearmored 2>/dev/null || true
    sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg.dearmored /etc/apt/keyrings/packages.microsoft.gpg
    sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
    rm -f /tmp/packages.microsoft.gpg
    
    sudo apt-get update -qq
    sudo apt-get install -y -qq code
    
    print_info "Instalando extensões do VS Code..."
    code --install-extension ms-python.python --force 2>&1 | grep -v "is already installed" || true
    code --install-extension ms-azuretools.vscode-docker --force 2>&1 | grep -v "is already installed" || true
    code --install-extension hashicorp.terraform --force 2>&1 | grep -v "is already installed" || true
    code --install-extension ms-kubernetes-tools.vscode-kubernetes-tools --force 2>&1 | grep -v "is already installed" || true
    code --install-extension eamodio.gitlens --force 2>&1 | grep -v "is already installed" || true
    code --install-extension esbenp.prettier-vscode --force 2>&1 | grep -v "is already installed" || true
    code --install-extension dbaeumer.vscode-eslint --force 2>&1 | grep -v "is already installed" || true
    code --install-extension ms-vscode-remote.remote-ssh --force 2>&1 | grep -v "is already installed" || true
    code --install-extension redhat.vscode-yaml --force 2>&1 | grep -v "is already installed" || true
    code --install-extension golang.go --force 2>&1 | grep -v "is already installed" || true
    
    print_info "✅ VS Code instalado"
else
    print_skip "VS Code já instalado"
fi

#==============================================================================
# GOOGLE CHROME
#==============================================================================

print_section "Instalando Google Chrome"

if ! command -v google-chrome &> /dev/null; then
    print_info "Configurando repositório Google Chrome..."
    wget -q -O /tmp/google-chrome.gpg https://dl.google.com/linux/linux_signing_key.pub
    sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg < /tmp/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
    rm /tmp/google-chrome.gpg
    
    sudo apt-get update
    sudo apt-get install -y google-chrome-stable
    
    print_info "✅ Google Chrome instalado"
else
    print_skip "Google Chrome já instalado"
fi

#==============================================================================
# SLACK
#==============================================================================

print_section "Instalando Slack"

if ! command -v slack &> /dev/null; then
    print_info "Baixando Slack (latest)..."
    # Usar snap que sempre pega a versão mais recente
    sudo snap install slack --classic
    
    print_info "✅ Slack instalado"
else
    print_skip "Slack já instalado"
fi

#==============================================================================
# DBEAVER
#==============================================================================

print_section "Instalando DBeaver"

if ! command -v dbeaver &> /dev/null; then
    print_info "Configurando repositório DBeaver..."
    wget -O /tmp/dbeaver.gpg https://dbeaver.io/debs/dbeaver.gpg.key
    sudo gpg --dearmor -o /usr/share/keyrings/dbeaver.gpg < /tmp/dbeaver.gpg
    echo "deb [signed-by=/usr/share/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" | sudo tee /etc/apt/sources.list.d/dbeaver.list > /dev/null
    rm /tmp/dbeaver.gpg
    
    sudo apt-get update
    sudo apt-get install -y dbeaver-ce
    
    print_info "✅ DBeaver instalado"
else
    print_skip "DBeaver já instalado"
fi

#==============================================================================
# SPOTIFY
#==============================================================================

print_section "Instalando Spotify"

if ! command -v spotify &> /dev/null; then
    # Usar snap para Spotify (mais confiável)
    sudo snap install spotify
    
    print_info "✅ Spotify instalado"
else
    print_skip "Spotify já instalado"
fi

#==============================================================================
# FERRAMENTAS ADICIONAIS
#==============================================================================

print_section "Instalando ferramentas adicionais"

# Kubectx & Kubens
if [ ! -f /usr/local/bin/kubectx ]; then
    sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx 2>&1 | grep -v "already exists" || true
    sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx 2>/dev/null || true
    sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens 2>/dev/null || true
    print_info "✓ kubectx/kubens instalados"
fi

# Stern
if ! command -v stern &> /dev/null; then
    STERN_VERSION=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    print_info "Baixando stern..."
    wget https://github.com/stern/stern/releases/download/${STERN_VERSION}/stern_${STERN_VERSION#v}_linux_amd64.tar.gz -O /tmp/stern.tar.gz
    tar -xzf /tmp/stern.tar.gz -C /tmp/ stern
    sudo mv /tmp/stern /usr/local/bin/
    rm /tmp/stern.tar.gz
    print_info "✓ stern instalado"
fi

# Trivy
if ! command -v trivy &> /dev/null; then
    wget -O - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
    echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee -a /etc/apt/sources.list.d/trivy.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y trivy
    print_info "✓ trivy instalado"
fi

# Lazygit
if ! command -v lazygit &> /dev/null; then
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    curl -sLo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar xf /tmp/lazygit.tar.gz -C /tmp/ lazygit
    sudo install /tmp/lazygit /usr/local/bin
    rm /tmp/lazygit /tmp/lazygit.tar.gz
    print_info "✓ lazygit instalado"
fi

# Btop
if ! command -v btop &> /dev/null; then
    sudo snap install btop 2>/dev/null || true
    print_info "✓ btop instalado"
fi

# Neofetch
if ! command -v neofetch &> /dev/null; then
    sudo apt-get install -y neofetch
    print_info "✓ neofetch instalado"
fi

print_info "✅ Ferramentas adicionais instaladas"

#==============================================================================
# CRIAR ESTRUTURA DE DIRETÓRIOS
#==============================================================================

print_section "Criando estrutura de diretórios"

mkdir -p ~/projects/{backend,frontend,infra,scripts,learning,notebooks}
mkdir -p ~/.kube

print_info "✅ Estrutura de diretórios criada"

#==============================================================================
# GNOME SETTINGS
#==============================================================================

print_section "Configurando GNOME"

gsettings set org.gnome.mutter workspaces-only-on-primary false 2>/dev/null || true
gsettings set org.gnome.desktop.wm.preferences num-workspaces 4 2>/dev/null || true

print_info "✅ GNOME configurado"

#==============================================================================
# CLEANUP
#==============================================================================

print_section "Limpando arquivos temporários"

sudo apt-get autoremove -y
sudo apt-get clean

print_info "✅ Limpeza concluída"

#==============================================================================
# FINALIZAÇÃO
#==============================================================================

print_section "🎉 Setup Completo!"

echo ""
echo "=============================================="
echo "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "=============================================="
echo ""
echo "📦 Ferramentas instaladas:"
echo "  ✓ Git (configurado)"
echo "  ✓ SSH keys (restauradas ou geradas)"
echo "  ✓ ZSH + Oh-My-Zsh + plugins"
echo "  ✓ Miniconda + Jupyter Lab/Notebook"
echo "  ✓ Node.js (via NVM)"
echo "  ✓ Docker + Docker Compose"
echo "  ✓ AWS CLI v2 + Session Manager"
echo "  ✓ Terraform"
echo "  ✓ kubectl + Helm + k9s"
echo "  ✓ ArgoCD CLI"
echo "  ✓ VS Code + extensões"
echo "  ✓ Chrome, Slack, Spotify, DBeaver"
echo "  ✓ kubectx, kubens, stern, trivy, lazygit, btop"
echo ""
echo "📝 Configurações aplicadas:"
echo "  ✓ Git: $GIT_USER_NAME <$GIT_USER_EMAIL>"
echo "  ✓ Editor: $GIT_EDITOR"
echo "  ✓ Shell padrão: ZSH"
echo "  ✓ Aliases personalizados carregados"
echo ""
echo "🔑 Sua chave SSH:"
cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "  (Não foi possível exibir a chave)"
echo ""
echo "💡 Próximos passos:"
echo "  1. Adicione sua chave SSH ao GitHub/GitLab"
echo "  2. Configure AWS SSO (instruções abaixo)"
echo "  3. Configure Terraform Cloud (opcional)"
echo "  4. Reinicie o sistema para aplicar todas as mudanças"
echo ""
echo "🚀 Aliases úteis configurados:"
echo "  jlab       - Jupyter Lab"
echo "  jpy        - Jupyter Notebook"
echo "  k          - kubectl"
echo "  tf         - terraform"
echo "  lg         - lazygit"
echo "  atualizar  - apt update + upgrade + autoremove"
echo ""
echo "=============================================="
echo "📋 CONFIGURAÇÃO AWS SSO"
echo "=============================================="
echo ""
echo "Para configurar AWS SSO, execute:"
echo "  aws configure sso"
echo ""
echo "Você precisará informar:"
echo "  • SSO start URL (ex: https://sua-empresa.awsapps.com/start)"
echo "  • SSO Region (ex: us-east-1)"
echo "  • Profile name (ex: default ou tecksol-prod)"
echo ""
echo "Ou se preferir, edite manualmente:"
echo "  vi ~/.aws/config"
echo ""
echo "Exemplo de configuração SSO:"
echo "  [profile tecksol-prod]"
echo "  sso_start_url = https://tecksol.awsapps.com/start"
echo "  sso_region = us-east-1"
echo "  sso_account_id = 123456789012"
echo "  sso_role_name = AdministratorAccess"
echo "  region = us-east-1"
echo "  output = json"
echo ""
echo "Para fazer login:"
echo "  aws sso login --profile tecksol-prod"
echo ""
echo "=============================================="
echo "📋 CONFIGURAÇÃO TERRAFORM CLOUD (Opcional)"
echo "=============================================="
echo ""
echo "Se você usa Terraform Cloud, configure o token:"
echo "  terraform login"
echo ""
echo "Ou manualmente:"
echo "  vi ~/.terraform.d/credentials.tfrc.json"
echo ""
echo "Exemplo:"
echo '  {'
echo '    "credentials": {'
echo '      "app.terraform.io": {'
echo '        "token": "seu-token-aqui"'
echo '      }'
echo '    }'
echo '  }'
echo ""
echo "=============================================="
echo "Desenvolvido por Yuri Mussi - November 2025"
echo "=============================================="
echo ""

# Informar sobre reinicialização sem perguntar
echo "⚠️  É ALTAMENTE RECOMENDADO REINICIAR O SISTEMA!"
echo ""
print_info "Lembre-se de reiniciar o sistema para aplicar todas as mudanças:"
echo "  sudo reboot"
echo ""
