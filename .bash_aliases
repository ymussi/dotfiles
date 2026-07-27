# ~/.bash_aliases
# Aliases DevOps canônicos - Yuri Mussi
# Compartilhado entre bash e zsh (sourced tanto de .bashrc quanto de .zshrc).
# Segredos (senhas, API keys, aliases com credenciais embutidas) NÃO ficam
# aqui - ficam em ~/.zsh_secrets (chmod 600, fora do git).

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

# Docker aliases (docker compose e plugin, sem hifen)
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

# Jupyter aliases (ajuste o nome do env conda conforme o ambiente atual)
alias jlab='conda activate jpyter && jupyter lab'
alias jnb='conda activate jpyter && jupyter notebook'
alias deact='conda deactivate'
alias condaoff='conda deactivate'

# AI aliases
alias gem='gemini'

# Funções úteis
awslogin() {
    aws sso login --profile "$1"
}

kubeconfig() {
    export KUBECONFIG=~/.kube/"$1"
}

parse_git_branch() {
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}
