# backup-setup-automated

Backup completo e setup de uma máquina Ubuntu 26.04 LTS (dev/DevOps + harness de agentes).

| Script | O que faz |
|---|---|
| `backup.sh` | Gera um backup **cifrado** (gpg simétrico AES256) da máquina atual num destino que você informa (disco externo). Escreve `backup.tar.gpg`, `SHA256SUMS` e `MANIFESTO.txt`. |
| `ubuntu-setup-automated.sh` | Instala o ambiente numa máquina nova, idempotente. Com `--restore` devolve o backup. |

## Uso

```bash
# 1. máquina antiga: conferir o que entra (não grava nada, não pede senha)
./backup.sh /media/$USER/<disco> --dry-run   # --sem-sudo se quiser conferir sem sudo

# 2. máquina antiga: backup de verdade (pede sudo e a senha, duas vezes; a senha nunca é gravada)
./backup.sh /media/$USER/<disco>

# 3. máquina nova (Ubuntu 26.04 recém-instalado, disco montado)
./ubuntu-setup-automated.sh --restore /media/$USER/<disco>/backup-ubuntu-<host>-<data>
```

`./ubuntu-setup-automated.sh --help` lista as opções (`--pular`, `--so`, `--sem-harness`, `--sem-displaylink`...).
Depois do setup: logout/login (grupo docker, shell zsh) e reboot (o `claude-remote` sobe no boot).

## O que o backup leva

- **Segredos e logins** (grupo `segredos`): `~/.ssh`, `~/.aws` (sem cache de SSO), `~/.kube`, `~/.terraform.d` (sem plugin-cache),
  `~/.config/gh`, `~/.config/rclone`, `~/.docker/config.json`, `~/.gnupg`, `~/.cert`, `~/.gemini`, `~/.config/gcloud` e `~/.config/kiro-cli`
  (se existirem), token do Kiro CLI, keyring do GNOME (`~/.local/share/keyrings`), `~/.zsh_secrets`, `~/.claude.json`,
  `.netrc`/`.npmrc`, VPNs (NetworkManager via sudo, `.ovpn`, `~/.cert`) e os extras da máquina (`~/.config/backup-ubuntu-extras.txt`, fora do repo).
- **Harness, Jarvis e segundo cérebro**: `~/.claude` (inclui `.credentials.json`, `projects`, `jobs` e memória; sem caches),
  `~/.kiro`, `~/.local/share/jarvis` e `~/.local/share/voz` (modelos incluídos; as venvs ficam de fora e o `install.sh` do
  harness recria), `~/.config/systemd/user`.
- **Config**: shell, `~/.gitconfig`, `~/.tmux.conf`, VS Code/Kiro (settings, atalhos, snippets), fontes do usuário, `.desktop` do usuário, dconf (GNOME).
- **Dados**: `~/Documentos`, `~/Documents`, `~/Pictures`, `~/Desktop`, `~/scratch` e as pastas de `~/backup-git-*`. `~/Downloads` fica de fora.
- **`~/projects`**: repo com mudança não enviada, commit não enviado, sem remoto ou fora do GitHub entra inteiro; os demais voltam por
  `git clone` e só levam os **arquivos ignorados pelo git** (`.env`, `.tfvars`, `.pem`...; sem `node_modules`, `.terraform`, venv,
  `__pycache__`, `dist`, `build`, `target`; passou de `--ignorado-max-mb`, 100 por padrão, é pulado e contado no manifesto).
  Pastas e arquivos fora do git, em qualquer nível, entram até `--projeto-max-mb` (2048 por padrão).
- **Listas de pacotes** (em `.backup-ubuntu-meta/inventario/`, o restore reinstala a partir delas): `apt-manual`, `snap` (+ `snap-classic`),
  `npm-global`, `vscode-extensoes`, `kiro-extensoes`, `pip-user`, `uv-tools`, `pipx`, `cargo`, `gh-extensoes`, `crontab`, `dconf.ini`,
  mais `deb-externos`, `apt-repos`, `bin-fora-do-apt`, `appimages`, `fontes-usuario`, `systemd-user-enabled`, `versoes-ferramentas`.
- **Sistema (sudo)**: `/etc` que não é de pacote (zram, DKMS, modprobe, sysctl, `apt/sources.list.d`...), `/etc/NetworkManager/system-connections`,
  `/etc/systemd/zram-generator.conf`. `--sem-sudo` pula essa parte.

O destino não pode estar num repo git nem no HOME: o arquivo leva segredos.

## O que o setup faz, na ordem

`apt` (base + extras de uso) → `restore` (devolve o backup: segredos e logins vêm antes de tudo) → `docker` → `node` (nvm + NodeSource) →
`uv` (+ Python 3.12) → `gh` → `aws` (CLI v2, session-manager-plugin, aws_signing_helper) → `terraform` → `kubectl` (helm, k9s, argocd) →
`cli-extra` (stern, lazygit, trivy, actionlint, kubectx) → `kiro` (CLI **e IDE**) → `claude` → `cli-ia` (Gemini CLI, xo-cli) → `rclone` →
`tailscale` → `vpn` (openvpn3) → `apps` (Chrome, VS Code, Firefox, Telegram, Slack, Spotify, Postman, btop, DBeaver, TeamViewer) →
`displaylink` → `zram` → `playwright` → `shell` (zsh + oh-my-zsh) → `pacotes` (reinstala as listas do backup: apt, snap, npm -g,
extensões do VS Code e do Kiro, pip, uv, pipx, gh, dconf, cron) → `projetos` (clona os repos que não estavam no tar) →
`harness` (clona `dotfiles-claude`, roda o `install.sh`, liga linger e as units que estavam ligadas).

Cada etapa confere o estado antes de agir; rodar de novo só refaz o que falta. Repos de terceiros sem a suite do Ubuntu novo caem para a `noble`.

### Pré-requisitos do harness (`dotfiles-claude`, privado)

`git`, `gh` **logado** (o login vem do backup; senão `gh auth login`), `tmux`, `jq`, `python3` do sistema, Node do sistema, `curl`, `unzip`,
`kiro-cli` e `claude` em `~/.local/bin`, systemd `--user` com linger, libs de áudio (portaudio, sndfile, espeak-ng, ffmpeg). O `install.sh`
do harness instala o `uv` com sha256 fixo e cria as venvs da voz/Jarvis (Python 3.12, pacotes com hash).

### Fica manual

Logins que o backup não garante: `gh auth login` (se o token expirou), `aws sso login`, `kiro-cli login`, `claude`, `gemini`,
`sudo tailscale up` (e refazer o `tailscale serve` do Jarvis), chave MOK do DKMS com Secure Boot. NoMachine e GitKraken CLI: baixar à mão.
Perfis do Chrome e do Firefox (favoritos, senhas) não entram no backup.

## Não vai para o repo

Nenhum segredo, e-mail, hostname interno, IP ou dado pessoal. A identidade do git vem do `~/.gitconfig` do backup ou das
variáveis `GIT_USER_NAME`/`GIT_USER_EMAIL`.
