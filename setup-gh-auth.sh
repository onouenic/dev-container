#!/bin/bash
# Persiste o token do GitHub no gh config (~/.config/gh, volume gh-config)
# e configura o git credential helper. Roda no boot, como o node (não-root).
#
# Escreve o hosts.yml diretamente em vez de usar `gh auth login --with-token`,
# por dois motivos:
#   1. Com GH_TOKEN setado no ambiente (como é o caso aqui), o gh recusa
#      persistir a credencial e sai com erro;
#   2. O `gh auth login` valida escopos e exige read:org — rejeita tokens
#      classic/fine-grained só com escopo repo, que já bastam pra git e
#      pra a maioria dos comandos do gh.
#
# Nunca loga o token. Falhas viram aviso no log de boot (o boot completa;
# um git push sem auth vai falhar de forma visível quando for tentar).
set -u

if [ -z "${GH_TOKEN:-}" ]; then
    echo "AVISO: GH_TOKEN vazio — pulando auth do GitHub (git/gh vão desautenticados)."
    exit 0
fi

mkdir -p "$HOME/.config/gh"
printf 'github.com:\n    oauth_token: %s\n' "$GH_TOKEN" > "$HOME/.config/gh/hosts.yml"

# Resolve o usuário (opcional — só faz o "gh auth status" mostrar o login)
GITHUB_USER=$(gh api user --jq .login 2>/dev/null) || GITHUB_USER=""
if [ -n "$GITHUB_USER" ]; then
    printf 'github.com:\n    oauth_token: %s\n    user: %s\n' "$GH_TOKEN" "$GITHUB_USER" > "$HOME/.config/gh/hosts.yml"
    echo "GitHub auth configured (user: $GITHUB_USER)."
else
    echo "AVISO: token do GitHub nao validado (gh api user falhou) — confira se o token no .env e valido."
fi

if gh auth setup-git; then
    echo "git credential helper configurado."
else
    echo "AVISO: gh auth setup-git falhou — git vai autenticar so via env var."
fi

exit 0
