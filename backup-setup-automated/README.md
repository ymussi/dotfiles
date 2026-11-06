# backup-setup-automated

Backup completo e setup de uma máquina Ubuntu 26.10 "Stonking Stingray" (dev/DevOps + harness de agentes). O 26.04 LTS também é aceito.

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

# 4. máquina nova (Ubuntu 26.10 recém-instalado, disco montado)
./ubuntu-setup-automated.sh --restore /run/media/$USER/<disco>/backup-ubuntu-<host>-<data>
```

Duas coisas ficam de fora do padrão e o resumo do fim lembra como ligar:

- `--acesso-remoto`: `openssh-server` (porta 22), `xrdp` (3389) e TeamViewer. Sem a opção não entram, nem pela lista de
  pacotes do backup. Com ela, feche com firewall (`ufw`) e `PasswordAuthentication no` no `sshd`; o setup não faz isso.
- `--sem-suspender`: máquina sempre ligada (tampa e ocioso ignorados, sleep/suspend/hibernate mascarados, Wi-Fi sem economia,
  perfil performance). Sem a opção, a energia fica como o Ubuntu entrega.

`./ubuntu-setup-automated.sh --help` lista as opções (`--pular`, `--so`, `--sem-harness`, `--ignorar-sha256`, `--refazer-restore`, `--delta`, `--limpa-efi-windows`...).
Depois do setup: logout/login (grupo docker, shell zsh) e reboot (os serviços do usuário sobem no boot, com linger).
Destino aceito: NTFS, exFAT, ext4. FAT32 é recusado (limite de 4 GB por arquivo).

## Lições do restore real (06/11/2026)

| O que aconteceu | O que o setup faz agora |
|---|---|
| O `snap install spotify` travou na etapa `apps` (timeout de 900 s) e foi preciso cancelar e rodar de novo. | Cada snap tem timeout de `SNAP_TMO` (padrão 300 s); passou disso, aborta a mudança pendente do snapd e segue. `SNAP_PULAR="spotify"` não tenta o snap; `--pular apps` pula a etapa. O Spotify é o último da lista. |
| Rodar o comando de novo decifrava e extraía 30 GB outra vez. | Restore concluído grava uma marca (`~/.local/share/backup-ubuntu-restore/restore-concluido`) e é pulado nas repetições. `--refazer-restore` força. |
| O `.git/index` e um ref de um repo viraram o texto de um arquivo do `~/.claude/file-history` (o index era hardlink dele). | Etapa `git-integridade` (depois de `projetos`, antes de `harness`): separa hardlinks dentro de `.git`, roda `git status` e `git fsck --connectivity-only` em cada repo sob o HOME e lista os com problema (a etapa falha se houver). Só lê e reporta; o conserto do index ou do ref é manual (guarde como `.corrompido`, apague, `git fetch`, `git reset`). |
| O pacote delta (o que mudou depois do backup) é um tar.gpg à parte. | `--delta ARQUIVO` (ou `--delta auto`, que procura `delta-pos-backup-*.tar.gpg` ao lado da pasta do backup) restaura **depois** do principal, pede a senha dele, sobrescreve (o delta é mais novo) e roda uma vez só (marca `delta-concluido`). Recusa se o restore principal falhou. |
| A ESP de fábrica do notebook ficou com a entrada "Windows Boot Manager" e `EFI/Microsoft` sem Windows. | `--limpa-efi-windows` (nunca por padrão): confere que o Ubuntu tem entrada e loader próprios, avisa se há NTFS/BitLocker no mesmo disco, guarda uma cópia de `EFI/Microsoft` em `~/.local/share/backup-ubuntu-restore/`, e só remove (`efibootmgr -B` + a pasta) depois de digitar `APAGAR` no terminal. Sem terminal, não faz nada. |
| Os perfis de VPN do NetworkManager não vieram. | Ficam em `/etc/NetworkManager/system-connections` (root): só entram no backup com sudo. No fim, o setup avisa se não há perfil `vpn`/`wireguard` no NetworkManager e mostra como importar (`nmcli connection import`). |

Testes: `timeout 300 ./tests/test-setup-funcoes.sh` carrega só as funções (`SETUP_SO_FUNCOES=1`), com HOME temporário e `sudo`, `snap`, `efibootmgr`, `nmcli` trocados por shims. Não roda o setup, não usa sudo real nem toca a ESP.

## O que o backup leva

**O HOME inteiro**, menos uma lista de exclusão. Entra tudo: segredos e logins (`~/.ssh`, `~/.aws`, `~/.kube`, `~/.gnupg`,
keyrings, tokens), configs, documentos, `~/projects` inteiro (pastas sem git, arquivos ignorados, stash),
perfis de navegador, o que mais houver.

**Fica de fora** (e o fim da execução imprime a seção "FORA DO BACKUP", com tamanho de cada item):
`~/Downloads`, `~/.cache`, lixeira, `**/node_modules`, `**/.terraform` (o `.terraform.lock.hcl` fica), `**/.venv`, `**/venv`,
`**/__pycache__`, `~/.npm`, `~/.cargo/registry`, `~/snap/*/common/.cache`, caches do Chrome e do Firefox,
containers e docker do usuário, o cache de SSO da AWS e o plugin-cache do terraform.
Exclusões só desta máquina (um caminho relativo ao HOME por linha) ficam em `~/.config/backup-ubuntu-excluir.txt`
(ou em `BACKUP_EXCLUIR_FILE`, ou `--excluir CAMINHO`), fora do repo.

Erro de leitura (arquivo sem permissão etc.) não passa em silêncio: o script lista tudo no fim e sai com código diferente de zero.

- **Listas de pacotes** (em `.backup-ubuntu-meta/inventario/`, o restore reinstala a partir delas): `apt-manual`, `snap`, `npm-global`,
  extensões do VS Code e do Kiro, `pip-user`, `uv-tools`, `pipx`, `cargo`, `gh-extensoes`, `crontab`, `dconf.ini`, `deb-externos`,
  `apt-repos`, `bin-fora-do-apt`, `appimages`, `fontes-usuario`, `systemd-user-enabled`, `dkms-status`, `versoes-ferramentas`.
- **Repos de `~/projects`**: a lista com o remoto de cada um vai junto; o setup reclona o que faltar.
- **Sistema (sudo)**: `/etc/NetworkManager/system-connections`, `zram-generator.conf`, `sudoers.d`, `apt/sources.list.d` e chaves,
  DKMS, e o que em `/etc` não vem de pacote. `--sem-sudo` pula essa parte. Os perfis do NetworkManager levam também as
  senhas de Wi-Fi salvas. No restore, o `/etc` do backup é copiado para uma pasta de root (0700) e validado e instalado de
  lá (`sudo install -o root -g root`), nunca direto da pasta do usuário; `sudoers.d` só entra se passar no `visudo -c`.
  O que dá poder de root (`sudoers.d`, `ssh`, `systemd`, `udev`, `modprobe.d`, `apt`, `openvpn`) só entra depois de mostrar a
  lista e digitar `RESTAURAR`; sem isso fica de fora, listado em `~/.local/share/backup-ubuntu-restore/etc-nao-restaurado.txt`.

O destino não pode estar num repo git nem no HOME: o arquivo leva segredos.

## O que o setup faz, na ordem

`apt` (base + extras de uso) → `restore` (devolve o backup: segredos e logins vêm antes de tudo) → `delta` (só com `--delta`) → `docker` → `node` (nvm + NodeSource) →
`uv` (+ Python 3.12) → `gh` → `aws` (CLI v2, session-manager-plugin, aws_signing_helper) → `terraform` → `kubectl` (helm, k9s, argocd) →
`cli-extra` (stern, lazygit, trivy, actionlint, kubectx) → `kiro` (CLI **e IDE**) → `claude` → `cli-ia` (CLIs do npm global: `NPM_GLOBAL`, padrão Gemini CLI) → `rclone` →
`tailscale` → `vpn` (openvpn3) → `apps` (Chrome, VS Code, Firefox, Telegram, Slack, Spotify, Postman, btop, DBeaver; TeamViewer só com `--acesso-remoto`) →
`displaylink` → `zram` (50% da RAM, metade em cada dispositivo, mais `99-zram.conf`) → `energia` (driver de vídeo Intel só se houver GPU Intel; com `--sem-suspender`, nunca suspende: tampa, ocioso e sleep mascarado, Wi-Fi sem powersave, perfil performance) → `playwright` → `shell` (zsh + oh-my-zsh) → `pacotes` (reinstala as listas do backup: apt, snap, npm -g,
extensões do VS Code e do Kiro, pip, uv, pipx, gh, dconf, cron) → `projetos` (clona os repos que não estavam no tar) → `git-integridade` →
`harness` (opcional, só com `HARNESS_REPO`/`HARNESS_DIR` configurados: clona o repositório, só na branch `main` e sem commit local fora do remoto roda o `install.sh` e liga o linger; não liga unit nenhuma por conta própria: as que estavam ligadas na origem e o `install.sh` deixa desligadas são listadas no fim, para ligar numa máquina só). O estado de guardrail do harness (`~/.claude/change-*`: aprovações registradas e a chave do bypass) não migra: o restore e o delta não o extraem → `efi-windows` (só com `--limpa-efi-windows`).

O que é baixado e executado fora do apt tem versão e sha256 fixos no script (variáveis `*_V` e `*_SHA` no topo):
AWS CLI, `aws_signing_helper`, `session-manager-plugin`, nvm, uv, helm, k9s, argocd, stern, lazygit, trivy, actionlint, rclone,
o instalador do oh-my-zsh, a chave da Synaptics; kubectx e os plugins do zsh vêm por tag conferida contra o commit. Hash que não
bate descarta o arquivo e a etapa falha. Ficam sem hash: os instaladores `curl | bash` do Kiro CLI e do Claude Code, o deb do Kiro IDE
(versão lida do metadata do site), o TeamViewer (só com `--acesso-remoto`), o kubectl (versão `stable`, sha256 do próprio dl.k8s.io),
as chaves dos repos apt (baixadas por HTTPS, sem conferir a impressão digital) e os pacotes npm/pip/uv da lista do backup.

Cada etapa confere o estado antes de agir; rodar de novo só refaz o que falta. Repos de terceiros sem a suite do Ubuntu novo caem para a primeira que existir entre `resolute`, `questing` e `noble` (a checagem segue redirect e recusa página de erro). Pacote do apt que não existe no release é pulado com aviso, e se a instalação em lote falhar o script tenta um a um.

Conferido em 05/11/2026 contra o índice `stonking` do archive: Docker e Tailscale têm suite própria; HashiCorp e OpenVPN3 ainda não (HashiCorp cai para `resolute`, OpenVPN3 para `resolute`); gh, Chrome, VS Code, NodeSource e DisplayLink usam suite fixa (`stable`/`nodistro`), sem depender do release.

### Configuração local (fora do repo)

O que é desta máquina e não é genérico (repositório de harness, caminhos de segredo de ferramentas próprias, CLIs extras)
fica em `~/.config/backup-ubuntu-setup.conf` (ou `SETUP_CONF`), uma linha `CHAVE=valor` por item, lida e nunca executada.
Variável de ambiente com o mesmo nome vence. Como fica em `~/.config`, vai no backup e já está lá quando o restore termina.
Sem o arquivo, o setup faz só o genérico e pula a etapa `harness`.

```ini
HARNESS_REPO=https://github.com/<dono>/<repo-do-harness>.git
# HARNESS_DIR=~/projects/<repo-do-harness>   (padrão)
# HARNESS_BRANCH=main                        (padrão)
SEGREDOS_EXTRA=.config/<ferramenta> .local/share/<app>
NPM_GLOBAL=@google/gemini-cli <outro-cli>
AVISO_FIM=lembrete impresso no fim do setup
```

O harness precisa, além do que o setup instala, de `gh` logado ou chave SSH (vêm no restore) e do que o `install.sh` dele pedir.

### Fica manual

Logins que o backup não garante: `gh auth login` (se o token expirou), `aws sso login`, `kiro-cli login`, `claude`, `gemini`,
`sudo tailscale up`, chave MOK do DKMS com Secure Boot. NoMachine e GitKraken CLI: baixar à mão.

## Não vai para o repo

Nenhum segredo, e-mail, hostname interno, IP, dado pessoal nem nome de repositório privado: isso vai na configuração local acima. A identidade do git vem do `~/.gitconfig` do backup ou das
variáveis `GIT_USER_NAME`/`GIT_USER_EMAIL`.
