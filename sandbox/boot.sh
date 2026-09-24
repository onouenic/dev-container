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

# Diretrizes nicrobots: aponta cada agente para /opt/nicrobots (montado
# read-only do host). É a fonte ÚNICA de regras — precede a pasta robots/ de
# cada projeto. Regenerado a todo boot; o conteúdo das regras é lido ao vivo
# do mount, então um `git pull` no host reflete sem rebuild.
if [ -f /opt/nicrobots/AGENTS.md ]; then
    POINTER='LEIA E SIGA `/opt/nicrobots/AGENTS.md` e as referências que ele indica (resolva os caminhos relativos a partir de `/opt/nicrobots`).

Esta é a fonte ÚNICA de diretrizes. Ela PRECEDE qualquer `AGENTS.md` ou pasta `robots/` que exista dentro de um projeto: em conflito, valem as regras de `/opt/nicrobots`.'
    # Claude Code, Codex e Qwen leem cada um o seu arquivo global.
    mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.qwen"
    printf '%s\n' "$POINTER" > "$HOME/.claude/CLAUDE.md"
    printf '%s\n' "$POINTER" > "$HOME/.codex/AGENTS.md"
    printf '%s\n' "$POINTER" > "$HOME/.qwen/QWEN.md"
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
    echo "AVISO: /opt/nicrobots/AGENTS.md ausente — confira NICROBOTS_DIR no .env."
fi

echo "Ambiente pronto."
exec sleep infinity
