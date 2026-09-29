#!/bin/bash
# Boot do dev-sandbox, como node (sem root, sem capabilities).
# Configura identidade e auth do git, depois mantém o container vivo.
set -euo pipefail

git config --global user.name "${GIT_USER_NAME:?GIT_USER_NAME não definido}"
git config --global user.email "${GIT_USER_EMAIL:?GIT_USER_EMAIL não definido}"

bash /opt/sandbox/setup-gh-auth.sh

# Config do Docker CLI: injeta o egress-proxy em `docker build` e `docker
# run` automaticamente. Referencia o proxy por IP porque os containers
# aninhados no docker-engine não resolvem nomes do compose. Sem isso, todo
# acesso à internet dentro de build/run falha (a devnet não tem rota direta).
if [ -n "${EGRESS_PROXY_IP:-}" ]; then
    mkdir -p "$HOME/.docker"
    cat > "$HOME/.docker/config.json" <<JSON
{
  "proxies": {
    "default": {
      "httpProxy": "http://${EGRESS_PROXY_IP}:3128",
      "httpsProxy": "http://${EGRESS_PROXY_IP}:3128",
      "noProxy": "localhost,127.0.0.1,::1,docker-engine"
    }
  }
}
JSON
    echo "Docker CLI apontado para o egress-proxy (${EGRESS_PROXY_IP}:3128)."
fi

# Política de git do sandbox: o token do GitHub é um PAT clássico, que
# consegue abrir e mergear PR em qualquer repo do dono. Esta orientação é
# defesa em profundidade, não barreira (a barreira são os rulesets no GitHub
# — ver README). Vai para os três agentes, com ou sem nicrobots.
GIT_POLICY='## Política de git deste sandbox (obrigatória)

Com o GitHub, use SOMENTE: `git pull` (ou `git fetch`), `git add`, `git commit` e, no máximo, `git push` da branch de trabalho.

- NÃO crie, aprove, edite, feche nem faça merge de pull request — nem por `gh`, nem pela API (`gh api`, `curl`), nem por qualquer outro meio.
- NÃO faça merge no remoto e NÃO faça push para `main`/`master` (nem via `HEAD:main`). Sem `git merge` para integrar branches; quem integra é o usuário.
- NÃO use `git push --force`/`-f`/`--force-with-lease` nem apague branches ou tags remotas.
- NÃO crie tags, releases, repositórios, secrets ou workflows no GitHub.
- Se a tarefa parecer exigir algo fora disso, pare e peça ao usuário.'

# Como o token do GitHub Packages chega aos comandos: sem isto o agente vê
# GITHUB_TOKEN vazia e conclui que não há token. Vai para os três agentes.
PKG_TOKEN_NOTE='## Token do GitHub Packages (@nicbrasil) neste sandbox

- `GITHUB_TOKEN` fica vazia no ambiente DE PROPÓSITO. O token (classic, só `read:packages`) está em `/run/secrets/gh_packages_token`.
- Os wrappers de `npm`, `pnpm` e `docker` (em `/opt/sandbox/bin`) exportam `GITHUB_TOKEN` a partir desse arquivo só nos comandos que baixam pacotes ou fazem build: `npm install|ci|add|update|view`, `pnpm install|add|update|fetch|dlx`, `docker build`, `docker buildx build|bake`, `docker compose build|up`. Assim `${GITHUB_TOKEN}` no `.npmrc` e `secrets: <id>: environment: GITHUB_TOKEN` no compose funcionam sem nada extra.
- Chame `npm`, `pnpm` e `docker` pelo nome — não por caminho absoluto, `npx` ou `corepack` —, senão o token não é injetado e o registry responde 401.
- Fora desses casos, passe o token só ao comando que precisa: `GITHUB_TOKEN="$(cat /run/secrets/gh_packages_token)" <comando>`.
- NUNCA imprima o token, nem grave em arquivo, nem passe como `--build-arg`/`ARG` ou copie para a imagem. Em Dockerfile, use BuildKit secret (`RUN --mount=type=secret,...`).'

# Diretrizes nicrobots: aponta cada agente para /opt/nicrobots (montado
# read-only do host). É a fonte ÚNICA de regras — precede a pasta robots/ de
# cada projeto. Regenerado a todo boot; o conteúdo das regras é lido ao vivo
# do mount, então um `git pull` no host reflete sem rebuild.
if [ -f /opt/nicrobots/AGENTS.md ]; then
    POINTER='LEIA E SIGA `/opt/nicrobots/AGENTS.md` e as referências que ele indica (resolva os caminhos relativos a partir de `/opt/nicrobots`).

Esta é a fonte ÚNICA de diretrizes. Ela PRECEDE qualquer `AGENTS.md` ou pasta `robots/` que exista dentro de um projeto: em conflito, valem as regras de `/opt/nicrobots`.'
    echo "Diretrizes nicrobots ligadas (/opt/nicrobots)."

    # Skills nicrobots: symlinks do repo central para o dir de skills do
    # Claude Code. Ficam vivas (git pull no host reflete) e read-only. O boot
    # limpa symlinks antigos que apontem para o repo antes de recriar, para
    # skills removidas no repo sumirem também.
    if [ -d /opt/nicrobots/robots/skills ]; then
        mkdir -p "$HOME/.claude/skills"
        find "$HOME/.claude/skills" -maxdepth 1 -type l -lname '/opt/nicrobots/*' -delete 2>/dev/null || true
        n=0
        for skill in /opt/nicrobots/robots/skills/*/; do
            [ -f "$skill/SKILL.md" ] || continue
            ln -sfn "${skill%/}" "$HOME/.claude/skills/$(basename "$skill")"
            n=$((n + 1))
        done
        echo "Skills nicrobots ligadas ($n)."
    fi
else
    POINTER=""
    echo "AVISO: /opt/nicrobots/AGENTS.md ausente — confira NICROBOTS_DIR no .env."
fi

# Claude Code, Codex e Qwen leem cada um o seu arquivo global.
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.qwen"
for f in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.qwen/QWEN.md"; do
    if [ -n "$POINTER" ]; then
        printf '%s\n\n%s\n\n%s\n' "$POINTER" "$GIT_POLICY" "$PKG_TOKEN_NOTE" > "$f"
    else
        printf '%s\n\n%s\n' "$GIT_POLICY" "$PKG_TOKEN_NOTE" > "$f"
    fi
done
echo "Política de git e nota do token de pacotes gravadas nas diretrizes dos agentes."

echo "Ambiente pronto."
exec sleep infinity
