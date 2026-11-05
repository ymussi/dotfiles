# backup-setup-automated

Backup completo e setup de uma máquina Ubuntu 26.04 LTS (dev/DevOps + harness de agentes).

| Script | O que faz |
|---|---|
| `backup.sh` | Gera um backup **cifrado** (gpg simétrico AES256) da máquina atual num destino que você informa (disco externo). Escreve `backup.tar.gpg`, `SHA256SUMS` e `MANIFESTO.txt`. |
| `ubuntu-setup-automated.sh` | Instala o ambiente numa máquina nova, idempotente. Com `--restore` devolve o backup. |

## Uso

```bash
# 1. máquina antiga: conferir o que entra (não grava nada, não pede senha)
./backup.sh /media/$USER/<disco> --dry-run

# 2. máquina antiga: backup de verdade (pede sudo e a senha, duas vezes; a senha nunca é gravada)
./backup.sh /media/$USER/<disco>

# 3. máquina nova (Ubuntu 26.04 recém-instalado, disco montado)
./ubuntu-setup-automated.sh --restore /media/$USER/<disco>/backup-ubuntu-<host>-<data>
```

`./ubuntu-setup-automated.sh --help` lista as opções (`--pular`, `--so`, `--sem-harness`, `--sem-displaylink`...).
Depois do setup: logout/login (grupo docker, shell zsh) e reboot (o `claude-remote` sobe no boot).

## O que o backup leva

`~/.ssh`, `~/.aws` (sem cache de SSO), `~/.kube`, `~/.terraform.d` (sem plugin-cache), `~/.config/rclone`, `~/.config/gh`,
`~/.gnupg`, extras da sua máquina (lista em `~/.config/backup-ubuntu-extras.txt`, fora do repo), perfis de VPN (NetworkManager, via sudo, e arquivos `.ovpn`), `~/.zsh_secrets` e aliases, `~/.gitconfig`,
`~/.kiro`, `~/.claude`, `~/.local/share/jarvis`, `~/Documentos`, `~/Documents`, `~/Pictures`, repos de `~/projects` com
mudança não enviada (ou fora do GitHub), inventários (apt, snap, flatpak, pip, npm, uv, extensões, dconf, crontab, units
systemd) e os arquivos de `/etc` que não são de pacote (zram, DKMS, modprobe, sysctl...).
`~/Downloads` fica de fora de propósito. `--sem-sudo` pula `/etc` e as VPNs do NetworkManager.

O destino não pode estar num repo git nem no HOME: o arquivo leva segredos.

## O que o setup instala

Base e build, Docker (repo oficial), Node (nvm + NodeSource), uv + Python 3.12 (as venvs do Jarvis), gh, AWS CLI v2 e
session-manager-plugin, Terraform, kubectl/helm/k9s/argocd, stern/lazygit/trivy/actionlint/kubectx, Kiro CLI, Claude Code,
rclone, Tailscale, OpenVPN 3 e plugin do NetworkManager, Chrome/VS Code/Slack/Spotify/Postman/DBeaver, DisplayLink (evdi por
DKMS, com o conserto do módulo que não recompila quando o kernel muda de build), zram (zram0 4 GB lzo-rle + zram1 4 GB zstd)
e `/swap.img`, libs do WebKit do Playwright, zsh + oh-my-zsh, e o harness (clona `dotfiles-claude`, roda o `install.sh`,
liga linger e os serviços `claude-remote`/`jarvis`).

Repos de terceiros sem a suite do Ubuntu novo caem para a `noble` automaticamente.

## Não vai para o repo

Nenhum segredo, e-mail, hostname interno, IP ou dado pessoal. A identidade do git vem do `~/.gitconfig` do backup ou das
variáveis `GIT_USER_NAME`/`GIT_USER_EMAIL`.
