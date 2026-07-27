# ~/.bash_profile - Ubuntu
# Bash so roda .bash_profile em login shells; para shells interativas nao-login
# o Ubuntu usa .bashrc. Este arquivo garante que .bashrc (e por consequencia
# .bash_aliases) tambem seja carregado em sessoes de login (ex: TTY, SSH).

[ -f ~/.bashrc ] && source ~/.bashrc

# Miniconda (gerenciado por 'conda init bash', mas garantimos o fallback aqui
# caso o bloco do conda init nao esteja presente no .bashrc)
if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
    . "$HOME/miniconda3/etc/profile.d/conda.sh"
fi

export PATH="$HOME/.local/bin:$PATH"
