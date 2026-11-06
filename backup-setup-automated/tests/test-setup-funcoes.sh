#!/usr/bin/env bash
#==============================================================================
# Testes das funcoes do ubuntu-setup-automated.sh que tratam falhas vistas no restore real:
# snap que trava, restore/delta repetidos, repo git corrompido por hardlink, entrada EFI do Windows,
# perfis de VPN ausentes.
#
# Nao roda o setup: carrega so as funcoes (SETUP_SO_FUNCOES=1) com HOME temporario e comandos de
# sistema (sudo, snap, efibootmgr, nmcli...) trocados por shims. Nao usa sudo real, rede, ESP nem
# NetworkManager. Os testes com terminal usam `script` (pty).
#
# Uso: timeout 300 ./tests/test-setup-funcoes.sh
#==============================================================================
set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$AQUI/../ubuntu-setup-automated.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
RES="$T/resultados"; : > "$RES"   # arquivo, porque os testes rodam em subshells
ok()   { echo "ok" >> "$RES"; echo "  ok    $1"; }
nok()  { echo "falha" >> "$RES"; echo "  FALHA $1"; [ -z "${2:-}" ] || sed 's/^/        | /' "$2" | head -15; }
pula() { echo "pulou" >> "$RES"; echo "  pulou $1"; }
# chk "descricao" ARQUIVO_DE_SAIDA comando...: o comando precisa dar 0
chk() { local d="$1" out="$2"; shift 2; if "$@"; then ok "$d"; else nok "$d" "$out"; fi; }

# ---- shims -------------------------------------------------------------------------------------
cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
[ "$1" = "-v" ] && exit 0
exec "$@"
EOF
cat > "$BIN/snap" <<EOF
#!/bin/sh
echo "\$*" >> "$T/snap.calls"
case "\$1" in
    list) exit 1 ;;
    install) exec sleep 30 ;;
    changes) printf 'ID   Status  Spawn  Ready  Summary\n7    Doing   today  -      Install "spotify" snap\n6    Done    today  today  Install "btop" snap\n' ;;
    abort) echo "abort \$2" >> "$T/snap.log" ;;
esac
EOF
cat > "$BIN/gpg" <<EOF
#!/bin/sh
echo CHAMOU >> "$T/gpg-shim.log"; exit 1
EOF
cat > "$BIN/efibootmgr" <<EOF
#!/bin/sh
if [ "\$1" = "-b" ]; then echo "\$*" >> "$T/efi.log"; exit 0; fi
cat "$T/efi.out"
EOF
printf '#!/bin/sh\nexit 0\n' > "$BIN/mountpoint"
printf '#!/bin/sh\necho /dev/nvme0n1p1\n' > "$BIN/findmnt"
cat > "$BIN/lsblk" <<EOF
#!/bin/sh
case "\$*" in *PKNAME*) echo nvme0n1 ;; *) cat "$T/lsblk.fs" ;; esac
EOF
printf '#!/bin/sh\ncat "%s"\n' "$T/nm.out" > "$BIN/nmcli"
chmod +x "$BIN"/*

# ambiente comum de cada teste: funcoes carregadas, HOME proprio, git isolado
prologo() { # prologo NOME
    export HOME="$T/home-$1" PATH="$BIN:$PATH" SETUP_SO_FUNCOES=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GNUPGHOME="$T/gnupg-$1"; mkdir -p "$HOME" "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    # sem parametros: o source herda $@ de quem chama e o parser de opcoes do setup sairia com 2
    set --
    # shellcheck disable=SC1090
    source "$SETUP" >/dev/null 2>&1
    # o declare -A do setup, executado dentro desta funcao, vira local a ela: recria no escopo global
    declare -gA SO=() PULAR=()
    if ! declare -F etapa_delta >/dev/null; then nok "prologo $1: funcoes do setup nao carregaram"; exit 1; fi
}

echo "== CLI (sai antes de qualquer etapa)"
bash "$SETUP" --listar > "$T/o" 2>&1; rc=$?
chk "--listar tem delta, git-integridade e efi-windows" "$T/o" bash -c "[ $rc -eq 0 ] && grep -qx delta '$T/o' && grep -qx git-integridade '$T/o' && grep -qx efi-windows '$T/o'"
bash "$SETUP" --help > "$T/o" 2>&1; rc=$?
chk "--help documenta as opcoes novas" "$T/o" bash -c "[ $rc -eq 0 ] && grep -q -- '--delta' '$T/o' && grep -q -- '--limpa-efi-windows' '$T/o' && grep -q -- '--refazer-restore' '$T/o' && grep -q SNAP_PULAR '$T/o'"
bash "$SETUP" --delta > "$T/o" 2>&1; rc=$?
chk "--delta sem argumento sai com 2" "$T/o" test "$rc" -eq 2

echo "== snap com timeout (spotify travou no restore de 06/11)"
(
    prologo snap
    : > "$T/snap.calls"; : > "$T/snap.log"
    SNAP_TMO=2; t0=$SECONDS
    snap_instala spotify > "$T/o" 2>&1; rc=$?; dt=$((SECONDS - t0))
    chk "snap que passa do tempo: rc 1, em segundos, aborta a mudanca pendente" "$T/o" bash -c "[ $rc -eq 1 ] && [ $dt -lt 20 ] && grep -qx 'abort 7' '$T/snap.log'"
    chk "so aborta a mudanca do snap pedido (nao a do btop)" "$T/o" bash -c "! grep -q 'abort 6' '$T/snap.log'"
    : > "$T/snap.calls"; SNAP_PULAR="spotify slack"
    snap_instala spotify > "$T/o" 2>&1; rc=$?
    chk "SNAP_PULAR nao chama o snap" "$T/o" bash -c "[ $rc -eq 0 ] && ! grep -q install '$T/snap.calls'"
)

echo "== restore concluido nao repete"
(
    prologo restore
    mkdir -p "$RESTORE_DIR"; echo "2026-11-06T14:00:00-03:00 backup-ubuntu-x" > "$RESTORE_DIR/restore-concluido"
    rm -f "$T/gpg-shim.log"; RESTORE_ARG="$T/nao-existe"
    etapa_restore > "$T/o" 2>&1; rc=$?
    chk "com a marca: pula, rc 0, nao pede senha nem chama gpg" "$T/o" bash -c "[ $rc -eq 0 ] && grep -q 'ja concluido' '$T/o' && [ ! -e '$T/gpg-shim.log' ]"
    REFAZ_RESTORE=true
    etapa_restore > "$T/o" 2>&1; rc=$?
    chk "--refazer-restore ignora a marca" "$T/o" bash -c "[ $rc -eq 1 ] && ! grep -q 'ja concluido' '$T/o'"
)

echo "== delta"
(
    prologo delta0
    DELTA_ARG=""; RESTORE_ARG=""
    etapa_delta > "$T/o" 2>&1; rc=$?
    chk "sem --delta: pula" "$T/o" bash -c "[ $rc -eq 0 ] && grep -q 'sem --delta' '$T/o'"
    mkdir -p "$T/mussi/backup-ubuntu-x"; RESTORE_ARG="$T/mussi/backup-ubuntu-x"
    etapa_delta > "$T/o" 2>&1; rc=$?
    chk "sem --delta mas com delta ao lado: so avisa" "$T/o" bash -c "[ $rc -eq 0 ] && ! grep -q delta-pos '$T/o'"
    : > "$T/mussi/delta-pos-backup-2026-11-06.tar.gpg"
    etapa_delta > "$T/o" 2>&1; rc=$?
    chk "delta ao lado do backup: avisa para usar --delta auto" "$T/o" bash -c "[ $rc -eq 0 ] && grep -q -- '--delta auto' '$T/o'"
    DELTA_ARG=auto; FALHAS=(restore)
    etapa_delta > "$T/o" 2>&1; rc=$?
    chk "restore principal falhou: recusa o delta" "$T/o" bash -c "[ $rc -eq 1 ] && grep -q 'restore principal falhou' '$T/o'"
    FALHAS=(); RESTORE_ARG="$T/vazio"; mkdir -p "$T/vazio"
    etapa_delta > "$T/o" 2>&1; rc=$?
    chk "--delta auto sem arquivo: erro" "$T/o" bash -c "[ $rc -eq 1 ] && grep -q 'nao achei' '$T/o'"
    mkdir -p "$RESTORE_DIR"; echo "2026-11-06T15:00:00-03:00 d.tar.gpg" > "$RESTORE_DIR/delta-concluido"
    etapa_delta > "$T/o" 2>&1; rc=$?
    chk "delta ja restaurado: nao sobrescreve de novo" "$T/o" bash -c "[ $rc -eq 0 ] && grep -q 'ja restaurado' '$T/o'"
)

# restauracao de verdade, com terminal (pty) e gpg real num GNUPGHOME temporario
if command -v script >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
    REAL_GPG="$(command -v gpg)"
    mkdir -p "$T/real"
    printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_GPG" > "$T/real/gpg"; chmod +x "$T/real/gpg"
    ( # monta o delta de teste
        export GNUPGHOME="$T/gnupg-mk"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
        mkdir -p "$T/src/.claude/jobs"; echo novo > "$T/src/.claude/jobs/x.txt"
        tar -C "$T/src" -cf - .claude 2>/dev/null \
            | "$REAL_GPG" --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric -o "$T/delta.tar.gpg" 3< <(printf '%s' 'senha-de-teste') 2>/dev/null
    )
    cat > "$T/pty-delta.sh" <<EOF
#!/usr/bin/env bash
export PATH="$T/real:$BIN:\$PATH"
export HOME="$T/home-delta1" SETUP_SO_FUNCOES=1 GNUPGHOME="$T/gnupg-delta1"
mkdir -p "\$HOME/.claude/jobs" "\$GNUPGHOME"; chmod 700 "\$GNUPGHOME"
echo velho > "\$HOME/.claude/jobs/x.txt"
rm -f "$T/gpg-shim.log"
source "$SETUP" >/dev/null 2>&1
RESTORE_ARG=""; DELTA_ARG="$T/delta.tar.gpg"
etapa_delta; echo "RC=\$?"
cat "\$HOME/.claude/jobs/x.txt"
[ -f "\$RESTORE_DIR/delta-concluido" ] && echo MARCA || echo SEM-MARCA
EOF
    # PATH com o gpg real na frente do shim que falha
    echo "== delta com terminal (gpg real, GNUPGHOME temporario)"
    (sleep 2; printf 'senha-errada\n') | timeout 90 script -qec "bash $T/pty-delta.sh" /dev/null > "$T/o" 2>&1
    chk "senha errada: falha, arquivo intacto, sem marca" "$T/o" bash -c "grep -q 'RC=1' '$T/o' && grep -q '^velho' '$T/o' && grep -q SEM-MARCA '$T/o'"
    rm -rf "$T/home-delta1"
    (sleep 2; printf 'senha-de-teste\n') | timeout 90 script -qec "bash $T/pty-delta.sh" /dev/null > "$T/o" 2>&1
    chk "senha certa: sobrescreve com o conteudo do delta e grava a marca" "$T/o" bash -c "grep -q 'RC=0' '$T/o' && grep -q '^novo' '$T/o' && grep -q '^MARCA' '$T/o'"
else
    pula "delta com terminal (falta script ou gpg)"
fi

echo "== integridade dos repos git"
(
    prologo git
    mk() { # mk nome: repo com 1 commit e arquivo
        git init -q -b main "$HOME/projects/$1" && ( cd "$HOME/projects/$1" && echo a > a && git add a \
            && git -c user.name=t -c user.email=t@t commit -q -m x )
    }
    for r in ok indexruim refruim hl; do mk $r; done
    printf 'texto de um arquivo de memoria\n' > "$HOME/projects/indexruim/.git/index"
    printf 'lixo\n' > "$HOME/projects/refruim/.git/refs/heads/main"
    echo conteudo > "$HOME/file-history-x"; ln -f "$HOME/projects/hl/.git/index" "$HOME/hl-index"
    [ "$(stat -c %h "$HOME/projects/hl/.git/index")" -ge 2 ] && ok "preparo: .git/index do repo hl tem 2 links" || nok "preparo do hardlink"
    etapa_git_integridade > "$T/o" 2>&1; rc=$?
    chk "detecta index e ref corrompidos (rc 1, 2 de 4 repos)" "$T/o" bash -c "[ $rc -eq 1 ] && grep -q '2 de 4' '$T/o' && grep -q 'indexruim' '$T/o' && grep -q 'refruim' '$T/o'"
    chk "nao acusa o repo bom nem o do hardlink" "$T/o" bash -c "! grep -E 'falhou em .*/(ok|hl)\b' '$T/o'"
    chk "hardlink dentro de .git deixou de ser link" "$T/o" bash -c "[ \$(stat -c %h '$HOME/projects/hl/.git/index') -eq 1 ]"
    chk "nao apagou nada (index corrompido continua la)" "$T/o" test -e "$HOME/projects/indexruim/.git/index"
    rm -rf "$HOME/projects/indexruim" "$HOME/projects/refruim"
    etapa_git_integridade > "$T/o" 2>&1; rc=$?
    chk "todos bons: rc 0" "$T/o" bash -c "[ $rc -eq 0 ] && grep -q 'nenhum com problema' '$T/o'"
)

echo "== entrada EFI do Windows"
efi_ambiente() { # efi_ambiente NOME: ESP de mentira com Windows e Ubuntu
    ESP="$T/esp-$1"; rm -rf "$ESP"; mkdir -p "$ESP/EFI/Microsoft/Boot" "$ESP/EFI/ubuntu"
    echo x > "$ESP/EFI/Microsoft/Boot/bootmgfw.efi"; echo y > "$ESP/EFI/ubuntu/shimx64.efi"
    printf 'BootCurrent: 0002\nBootOrder: 0002,0001\nBoot0001* Windows Boot Manager\tHD(1,GPT)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)\nBoot0002* ubuntu\tHD(1,GPT)/File(\\EFI\\ubuntu\\shimx64.efi)\n' > "$T/efi.out"
    printf 'vfat\next4\n' > "$T/lsblk.fs"; : > "$T/efi.log"
    mkdir -p "$T/sysfs-efi"
}
(
    prologo efi0
    efi_ambiente a; ESP_DIR="$ESP"; EFI_SYSFS="$T/sysfs-efi"
    etapa_efi_windows > "$T/o" 2>&1; rc=$?
    chk "sem --limpa-efi-windows: nao faz nada" "$T/o" bash -c "[ $rc -eq 0 ] && [ -d '$ESP/EFI/Microsoft' ] && [ ! -s '$T/efi.log' ]"
    LIMPA_EFI=true
    etapa_efi_windows > "$T/o" 2>&1 < /dev/null; rc=$?
    chk "sem terminal: recusa, nada apagado" "$T/o" bash -c "[ $rc -eq 1 ] && [ -d '$ESP/EFI/Microsoft' ] && [ ! -s '$T/efi.log' ]"
    printf 'BootOrder: 0001\nBoot0001* Windows Boot Manager\tHD(1,GPT)\n' > "$T/efi.out"
    etapa_efi_windows > "$T/o" 2>&1 < /dev/null; rc=$?
    chk "sem entrada do Ubuntu: recusa antes de qualquer coisa" "$T/o" bash -c "[ $rc -eq 1 ] && grep -q 'Ubuntu nao tem entrada' '$T/o' && [ -d '$ESP/EFI/Microsoft' ]"
    efi_ambiente b; rm "$ESP/EFI/ubuntu/shimx64.efi"; ESP_DIR="$ESP"
    etapa_efi_windows > "$T/o" 2>&1 < /dev/null; rc=$?
    chk "sem loader do Ubuntu na ESP: recusa" "$T/o" bash -c "[ $rc -eq 1 ] && [ -d '$ESP/EFI/Microsoft' ]"
)
if command -v script >/dev/null 2>&1; then
    cat > "$T/pty-efi.sh" <<EOF
#!/usr/bin/env bash
NOME="\$1"; set --
export PATH="$BIN:\$PATH" HOME="$T/home-efi-\$NOME" SETUP_SO_FUNCOES=1
mkdir -p "\$HOME"
source "$SETUP" >/dev/null 2>&1
LIMPA_EFI=true; ESP_DIR="$T/esp-\$NOME"; EFI_SYSFS="$T/sysfs-efi"
etapa_efi_windows; echo "RC=\$?"
EOF
    ( efi_ambiente c; printf 'vfat\nntfs\n' > "$T/lsblk.fs"
      (sleep 2; printf 'nao\n') | timeout 60 script -qec "bash $T/pty-efi.sh c" /dev/null > "$T/o" 2>&1
      chk "responder outra coisa que APAGAR cancela; avisa do NTFS no mesmo disco" "$T/o" bash -c "grep -q 'RC=0' '$T/o' && grep -q cancelado '$T/o' && grep -q NTFS '$T/o' && [ -d '$ESP/EFI/Microsoft' ] && [ ! -s '$T/efi.log' ]" )
    ( efi_ambiente d
      (sleep 2; printf 'APAGAR\n') | timeout 60 script -qec "bash $T/pty-efi.sh d" /dev/null > "$T/o" 2>&1
      chk "APAGAR: remove so a entrada do Windows (0001) e a pasta Microsoft" "$T/o" bash -c "grep -q 'RC=0' '$T/o' && grep -qx -- '-b 0001 -B' '$T/efi.log' && [ \$(wc -l < '$T/efi.log') -eq 1 ] && [ ! -e '$ESP/EFI/Microsoft' ] && [ -f '$ESP/EFI/ubuntu/shimx64.efi' ]"
      chk "guarda copia de EFI/Microsoft antes de apagar" "$T/o" bash -c "tar -tf '$T/home-efi-d/.local/share/backup-ubuntu-restore/'EFI-Microsoft-*.tar | grep -q bootmgfw.efi" )
else
    pula "EFI com terminal (falta script)"
fi

echo "== /etc do backup: copia de root, validacao e confirmacao"
# sudo de teste: sem root de verdade, chown vira no-op e install perde -o/-g. O visudo de mentira troca o
# arquivo da pasta do usuario (simula a troca entre validar e instalar) e so aceita o que tem VALIDO.
BINR="$T/bin-root"; mkdir -p "$BINR"
cat > "$BINR/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-v" ] && exit 0
case "$1" in
    chown) exit 0 ;;
    install) shift; a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; exec install "${a[@]}" ;;
esac
exec "$@"
EOF
cat > "$BINR/visudo" <<'EOF'
#!/usr/bin/env bash
[ -n "${TROCA_ORIGEM:-}" ] && echo 'ALL ALL=(ALL) NOPASSWD: ALL # EVIL' > "$TROCA_ORIGEM"
grep -q VALIDO "$2"
EOF
chmod +x "$BINR"/*
etc_ambiente() { # etc_ambiente NOME: raiz de backup com sudoers, apt, NetworkManager e um arquivo comum
    R="$T/raiz-$1"; rm -rf "$R" "$T/etcdest-$1" "$T/rootstage-$1"; mkdir -p "$T/etcdest-$1" "$T/rootstage-$1"
    mkdir -p "$R/etc/sudoers.d" "$R/etc/apt/sources.list.d" "$R/etc/NetworkManager/system-connections" "$R/etc/sysctl.d"
    echo 'usuario ALL=(ALL) ALL # VALIDO' > "$R/etc/sudoers.d/10-usuario"
    echo 'Types: deb' > "$R/etc/apt/sources.list.d/x.sources"
    printf '[vpn]\nca=/home/velho/.cert/ca.crt\n' > "$R/etc/NetworkManager/system-connections/vpn1.nmconnection"
    echo 'vm.x = 1' > "$R/etc/sysctl.d/90-x.conf"
    echo '127.0.0.1 localhost' > "$R/etc/hosts"
    echo invalido > "$R/etc/sudoers.d/99-ruim"
}
(
    prologo etc0
    export PATH="$BINR:$PATH"
    etc_ambiente a; ETC_DEST="$T/etcdest-a"; ETC_STAGE_BASE="$T/rootstage-a"; APT_SUJO=false
    restaura_etc "$R" /home/velho > "$T/o" 2>&1 < /dev/null; rc=$?
    D="$T/etcdest-a/etc"
    chk "sem terminal: comum entra, sudoers e apt ficam de fora e listados" "$T/o" bash -c "[ -f '$D/sysctl.d/90-x.conf' ] && [ ! -e '$D/sudoers.d/10-usuario' ] && [ ! -e '$D/apt/sources.list.d/x.sources' ] && grep -qx /etc/sudoers.d/10-usuario '$RESTORE_DIR/etc-nao-restaurado.txt' && grep -qx /etc/apt/sources.list.d/x.sources '$RESTORE_DIR/etc-nao-restaurado.txt'"
    chk "perfil do NetworkManager entra com o HOME novo, modo 600" "$T/o" bash -c "grep -qx 'ca=$HOME/.cert/ca.crt' '$D/NetworkManager/system-connections/vpn1.nmconnection' && [ \$(stat -c %a '$D/NetworkManager/system-connections/vpn1.nmconnection') = 600 ]"
    chk "a pasta do usuario nao muda (sed na copia de root) e a copia de root some no fim" "$T/o" bash -c "grep -q /home/velho '$R/etc/NetworkManager/system-connections/vpn1.nmconnection' && [ -z \"\$(ls -A '$T/rootstage-a')\" ]"
    chk "hosts de origem guardado, nao aplicado" "$T/o" bash -c "[ -f '$RESTORE_DIR/hosts.origem' ] && [ ! -e '$D/hosts' ]"
    restaura_etc "$R" /home/velho > "$T/o" 2>&1 < /dev/null
    chk "rodar de novo: o que ja existe e pulado" "$T/o" grep -q 'sysctl.d/90-x.conf ja existe' "$T/o"
)
if command -v script >/dev/null 2>&1; then
    cat > "$T/pty-etc.sh" <<EOF
#!/usr/bin/env bash
set --
export PATH="$BINR:$BIN:\$PATH" HOME="$T/home-etc1" SETUP_SO_FUNCOES=1
mkdir -p "\$HOME"
source "$SETUP" >/dev/null 2>&1
ETC_DEST="$T/etcdest-b"; ETC_STAGE_BASE="$T/rootstage-b"; APT_SUJO=false
export TROCA_ORIGEM="$T/raiz-b/etc/sudoers.d/10-usuario"
restaura_etc "$T/raiz-b" "\$HOME"; echo "RC=\$?"; echo "APT_SUJO=\$APT_SUJO"
EOF
    ( etc_ambiente b
      (sleep 2; printf 'RESTAURAR\n') | timeout 60 script -qec "bash $T/pty-etc.sh" /dev/null > "$T/o" 2>&1
      D="$T/etcdest-b/etc"
      chk "RESTAURAR: sudoers valido e apt entram, sudoers invalido nao (rc 1)" "$T/o" bash -c "grep -q 'RC=1' '$T/o' && [ -f '$D/sudoers.d/10-usuario' ] && [ ! -e '$D/sudoers.d/99-ruim' ] && [ -f '$D/apt/sources.list.d/x.sources' ] && [ \$(stat -c %a '$D/sudoers.d/10-usuario') = 440 ]"
      chk "troca do arquivo do usuario depois de validar nao chega ao /etc" "$T/o" bash -c "grep -q EVIL '$T/raiz-b/etc/sudoers.d/10-usuario' && ! grep -q EVIL '$D/sudoers.d/10-usuario'"
      chk "fonte do apt restaurada marca o apt para update" "$T/o" grep -q 'APT_SUJO=true' "$T/o" )
else
    pula "/etc com terminal (falta script)"
fi

echo "== perfis de VPN do NetworkManager"
(
    prologo vpn
    printf '802-11-wireless\ntun\n' > "$T/nm.out"
    confere_vpn_nm > "$T/o" 2>&1
    chk "sem perfil vpn/wireguard: avisa" "$T/o" grep -q 'nenhum perfil de VPN' "$T/o"
    printf '802-11-wireless\nvpn\n' > "$T/nm.out"
    confere_vpn_nm > "$T/o" 2>&1
    chk "com perfil vpn: silencio" "$T/o" test ! -s "$T/o"
)

echo
N_OK=$(grep -c '^ok$' "$RES"); N_FALHA=$(grep -c '^falha$' "$RES"); N_PULOU=$(grep -c '^pulou$' "$RES")
echo "Resultado: $N_OK ok, $N_FALHA falha(s), $N_PULOU pulado(s)"
[ "$N_FALHA" -eq 0 ]
