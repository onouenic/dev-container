#!/bin/bash
# Grava o token do GitHub no gh config (~/.config/gh, volume gh-config) e
# configura o git credential helper. Roda no boot, como node.
#
# O token vem de um secret montado em arquivo (/run/secrets/gh_token), não
# de variável de ambiente: assim ele não é herdado por todo processo filho
# (pnpm install, postinstall de pacote, testes...). O agente ainda consegue
# ler o arquivo — a proteção real é o escopo do token (ver README).
#
# Escreve o hosts.yml diretamente em vez de usar `gh auth login --with-token`,
# porque o `gh auth login` valida escopos e exige read:org, o que um token
# fine-grained só com Contents não tem.
#
# Nunca loga o token. Falhas viram aviso no log de boot.
set -u

TOKEN_FILE=/run/secrets/gh_token
HOSTS_FILE="$HOME/.config/gh/hosts.yml"

GH_TOKEN_VALUE=""
if [ -r "$TOKEN_FILE" ]; then
    GH_TOKEN_VALUE=$(tr -d '[:space:]' < "$TOKEN_FILE")
fi

if [ -z "$GH_TOKEN_VALUE" ]; then
    echo "AVISO: secret gh_token vazio — git/gh ficam sem autenticação no GitHub."
    rm -f "$HOSTS_FILE"
    exit 0
fi

umask 077
mkdir -p "$HOME/.config/gh"
printf 'github.com:\n    oauth_token: %s\n' "$GH_TOKEN_VALUE" > "$HOSTS_FILE"

# Resolve o usuário (opcional — só faz o "gh auth status" mostrar o login)
GITHUB_USER=$(gh api user --jq .login 2>/dev/null) || GITHUB_USER=""
if [ -n "$GITHUB_USER" ]; then
    printf 'github.com:\n    oauth_token: %s\n    user: %s\n' "$GH_TOKEN_VALUE" "$GITHUB_USER" > "$HOSTS_FILE"
    echo "GitHub auth configurado (usuário: $GITHUB_USER)."
else
    echo "AVISO: token do GitHub não validado (gh api user falhou) — confira o secret gh_token e o egress-proxy."
fi

if gh auth setup-git; then
    echo "git credential helper configurado."
else
    echo "AVISO: gh auth setup-git falhou — git push vai falhar sem credencial."
fi

# Clones feitos no host costumam usar SSH, mas o egress-proxy só deixa passar
# HTTP(S). Reescreve remotes SSH do GitHub para HTTPS, só dentro do sandbox:
# o .git/config do projeto não muda e o host continua usando SSH.
git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null
git config --global --add url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

exit 0
