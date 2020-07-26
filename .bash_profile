
# Setting PATH for Python 3.7
# The original version is saved in .bash_profile.pysave
PATH="/Library/Frameworks/Python.framework/Versions/3.7/bin:${PATH}"
export PATH

# added by Miniconda3 4.7.10 installer
# >>> conda init >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$(CONDA_REPORT_ERRORS=false '/Users/mussi/miniconda3/bin/conda' shell.bash hook 2> /dev/null)"
if [ $? -eq 0 ]; then
    \eval "$__conda_setup"
else
    if [ -f "/Users/mussi/miniconda3/etc/profile.d/conda.sh" ]; then
        . "/Users/mussi/miniconda3/etc/profile.d/conda.sh"
        CONDA_CHANGEPS1=false conda activate base
    else
        \export PATH="/Users/mussi/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda init zsh <<<

#aliases
CANDIDATURAS="~/projects/projects-python/candidaturas"
FRONT_DIR="~/projects/platform/front"
BACK_DIR="~/projects/platform"

alias jupy="cd ~/projects/jupyter && jupyter notebook"
alias ze="conda deactivate && conda activate ze"
alias mju="conda deactivate && conda activate maju"
alias labs="cd ${CANDIDATURAS}/luiza_labs/client-manager && conda deactivate && conda activate labs"
alias dev="conda deactivate && conda activate dev"
alias jupy="conda deactivate && conda activate dev && cd ~/projects/jupyter && jupyter notebook"
alias ger="conda deactivate && conda activate geru"
alias develop='conda deactivate && conda activate develop'
alias contratacao='conda deactivate && conda activate contratacao'
alias s="source ~/.bash_profile"
alias ls="ls -lha"
alias mysql="mysql -uroot"
alias frt="cd ${FRONT_DIR}"
alias back="cd ${BACK_DIR}"
alias tmt="cd ${BACK_DIR}/tomatico-cd"
alias proj="cd ~/projects"
alias buildtmt="docker build -t tomatico --build-arg RUN_ENVIRONMENT=development . && docker run -d -v Users/mussi/projects/platform/tomatico-cd:/var/www/html/api -p 8080:80 --name tmt tomatico"
alias delltmt="docker rm -f tmt && docker rmi -f tomatico"

#clusters aws ECS

AWS_KEY_JENKINS="~/projects/aws/jenkins/mussi.pem"
AWS_KEY="~/projects/aws/casede.pem"


alias jenkins="ssh -i ${AWS_KEY_JENKINS} ec2-user@ec2-54-207-30-125.sa-east-1.compute.amazonaws.com"
alias testec2="ssh -i ${AWS_KEY} ec2-user@ec2-18-231-49-177.sa-east-1.compute.amazonaws.com"
alias casedec2="ssh -i ${AWS_KEY} ubuntu@ec2-52-67-150-239.sa-east-1.compute.amazonaws.com"
alias metabasec2="ssh -i ${AWS_KEY} ubuntu@ec2-54-207-36-210.sa-east-1.compute.amazonaws.com"
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi
