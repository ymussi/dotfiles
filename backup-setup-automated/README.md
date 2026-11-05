# backup-setup-automated

Backup completo e setup de uma máquina Ubuntu 26.04 LTS (dev/DevOps + harness de agentes).

| Script | O que faz |
|---|---|
| `backup.sh` | Gera um backup **cifrado** (gpg simétrico AES256) da máquina atual num destino que você informa (disco externo). Escreve `backup.tar.gpg`, `SHA256SUMS` e `MANIFESTO.txt`. |
| `ubuntu-setup-automated.sh` | Instala o ambiente numa máquina nova, idempotente. Com `--restore` devolve o backup. |

## Uso

```bash
# 1. máquina antiga: conferir o que entra e o que fica fora (não grava nada, não pede senha)
./backup.sh /run/media/$USER/<disco> --dry-run   # --sem-sudo se quiser conferir sem sudo

# 2. máquina antiga: backup de verdade (pede sudo e a senha, duas vezes; a senha nunca é gravada)
./backup.sh /run/media/$USER/<disco>

# 3. desmonte e remonte o disco, depois confira (sha256 + decifra + conta as entradas do tar contra o MANIFESTO)
./backup.sh --verificar /run/media/$USER/<disco>/backup-ubuntu-<host>-<data>

# 4. máquina nova (Ubuntu 26.04 recém-instalado, disco montado)
./ubuntu-setup-automated.sh --restore /run/media/$USER/<disco>/backup-ubuntu-<host>-<data>
```

`./ubuntu-setup-automated.sh --help` lista as opções (`--pular`, `--so`, `--sem-harness`, `--ignorar-sha256`...).
Depois do setup: logout/login (grupo docker, shell zsh) e reboot (o `claude-remote` sobe no boot).
Destino aceito: NTFS, exFAT, ext4. FAT32 é recusado (limite de 4 GB por arquivo).

## O que o backup leva

**O HOME inteiro**, menos uma lista de exclusão. Entra tudo: segredos e logins (`~/.ssh`, `~/.aws`, `~/.kube`, `~/.gnupg`,
keyrings, tokens), harness e Jarvis, configs, documentos, `~/projects` inteiro (pastas sem git, arquivos ignorados, stash),
perfis de navegador, o que mais houver.

**Fica de fora** (e o fim da execução imprime a seção "FORA DO BACKUP", com tamanho de cada item):
`~/Downloads`, `~/.cache`, lixeira, `**/node_modules`, `**/.terraform` (o `.terraform.lock.hcl` fica), `**/.venv`, `**/venv`,
`**/__pycache__`, `~/.npm`, `~/.cargo/registry`, `~/snap/*/common/.cache`, venvs da voz, caches do Chrome e do Firefox,
containers e docker do usuário, o cache de SSO da AWS e o plugin-cache do terraform.
Exclusões só desta máquina (um caminho relativo ao HOME por linha) ficam em `~/.config/backup-ubuntu-excluir.txt`
(ou em `BACKUP_EXCLUIR_FILE`, ou `--excluir CAMINHO`), fora do repo.

Erro de leitura (arquivo sem permissão etc.) não passa em silêncio: o script lista tudo no fim e sai com código diferente de zero.

- **Listas de pacotes** (em `.backup-ubuntu-meta/inventario/`, o restore reinstala a partir delas): `apt-manual`, `snap`, `npm-global`,
  extensões do VS Code e do Kiro, `pip-user`, `uv-tools`, `pipx`, `cargo`, `gh-extensoes`, `crontab`, `dconf.ini`, `deb-externos`,
  `apt-repos`, `bin-fora-do-apt`, `appimages`, `fontes-usuario`, `systemd-user-enabled`, `dkms-status`, `versoes-ferramentas`.
- **Repos de `~/projects`**: a lista com o remoto de cada um vai junto; o setup reclona o que faltar.
- **Sistema (sudo)**: `/etc/NetworkManager/system-connections`, `zram-generator.conf`, `sudoers.d`, `apt/sources.list.d` e chaves,
  DKMS, e o que em `/etc` não vem de pacote. `--sem-sudo` pula essa parte. No restore, vai com `sudo install -o root -g root`
  e `sudoers.d` só entra se passar no `visudo -c`.

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

## Não vai para o repo

Nenhum segredo, e-mail, hostname interno, IP ou dado pessoal. A identidade do git vem do `~/.gitconfig` do backup ou das
variáveis `GIT_USER_NAME`/`GIT_USER_EMAIL`.
