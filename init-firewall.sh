#!/bin/bash
# Firewall default-deny compartilhado por TODOS os projetos do /workspace.
# Como é um único container pra múltiplos repos, esse allowlist precisa
# cobrir os domínios de todos os seus projetos, não só um.
set -euo pipefail
IFS=$'\n\t'

DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restaurando regras de DNS do Docker..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# DNS: restrito ao resolver embutido do Docker (127.0.0.11, via loopback),
# NÃO liberado para qualquer IP externo — evita DNS tunneling como canal
# de exfiltração que contornaria todo o resto do allowlist.
# SSH (porta 22) removido de propósito: não é mais necessário desde que o
# GitHub passou a autenticar via HTTPS + GITHUB_TOKEN. Porta aberta sem
# restrição de destino seria outro canal de bypass do firewall.
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

whitelist_domain() {
    local domain="$1"
    ips=$(dig +short "$domain" A | grep -E '^[0-9]+\.' || true)
    if [ -z "$ips" ]; then
        echo "  AVISO: não resolveu IP para $domain, pulando"
        return
    fi
    echo "Liberando: $domain"
    while read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
}

echo "Buscando ranges de IP do GitHub..."
gh_ranges=$(curl -s https://api.github.com/meta || true)
if [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    for category in web api git packages; do
        for cidr in $(echo "$gh_ranges" | jq -r ".${category}[]?" 2>/dev/null); do
            ipset add allowed-domains "$cidr" 2>/dev/null || true
        done
    done
else
    whitelist_domain "github.com"
    whitelist_domain "api.github.com"
    whitelist_domain "codeload.github.com"
    whitelist_domain "raw.githubusercontent.com"
fi

# GitHub Packages: registry privado (@nicbrasil e outros escopos privados).
# É um host separado de github.com/api.github.com, por isso mesmo com os
# ranges de "packages" acima, resolvo o domínio direto também como reforço
# (cobre o IP do momento, caso os ranges do meta não estejam 100% completos).
# github.com e api.github.com: reforço explícito via DNS, além dos ranges
# de IP buscados acima. A chamada pra api.github.com/meta pode falhar
# silenciosamente (rate limit de 60 req/hora sem autenticação — fácil de
# bater rebuildando o container várias vezes seguidas), deixando o
# github.com de fora do allowlist naquele boot específico sem aviso claro.
whitelist_domain "github.com"
whitelist_domain "api.github.com"
whitelist_domain "npm.pkg.github.com"
whitelist_domain "cli.github.com"

# ================= DOMÍNIOS PERMITIDOS (compartilhado entre projetos) =================
whitelist_domain "api.anthropic.com"
whitelist_domain "claude.ai"
whitelist_domain "platform.claude.com"
whitelist_domain "statsig.anthropic.com"

# npm / node
whitelist_domain "registry.npmjs.org"
whitelist_domain "registry.yarnpkg.com"

# Python
whitelist_domain "pypi.org"
whitelist_domain "files.pythonhosted.org"

# Debian/apt — a imagem base é node:22-bookworm, que é DEBIAN, não Ubuntu.
whitelist_domain "deb.debian.org"
whitelist_domain "security.debian.org"

# Go
whitelist_domain "proxy.golang.org"
whitelist_domain "sum.golang.org"

# Rust / Cargo
whitelist_domain "crates.io"
whitelist_domain "static.crates.io"
whitelist_domain "index.crates.io"

# Java / Maven / Gradle
whitelist_domain "repo.maven.apache.org"
whitelist_domain "repo1.maven.org"
whitelist_domain "plugins.gradle.org"
whitelist_domain "services.gradle.org"

# Ruby
whitelist_domain "rubygems.org"

# PHP / Composer
whitelist_domain "repo.packagist.org"
whitelist_domain "getcomposer.org"

# .NET / NuGet
whitelist_domain "api.nuget.org"

# OpenAI Codex CLI
whitelist_domain "api.openai.com"
whitelist_domain "chatgpt.com"
whitelist_domain "auth.openai.com"

# Qwen Code CLI (ajuste conforme o endpoint que você configurar:
# Qwen OAuth/dashscope da Alibaba, ou um endpoint OpenAI-compatible próprio)
whitelist_domain "dashscope.aliyuncs.com"
whitelist_domain "chat.qwen.ai"

whitelist_ip() {
    local ip_or_cidr="$1"
    echo "Liberando IP interno: $ip_or_cidr"
    ipset add allowed-domains "$ip_or_cidr" 2>/dev/null || true
}

# --- Adicione aqui domínios usados por QUALQUER um dos seus projetos ---
# Como o container é compartilhado, é normal essa lista crescer com o tempo:
# whitelist_domain "projeto-a.supabase.co"
# whitelist_domain "registry.projeto-b-privado.com"

# Servidor local rodando Ollama / Open WebUI (definido em OLLAMA_HOST no .env)
# Usamos ${VAR:-} porque o script roda via sudo (que limpa o ambiente) e set -u
# trata variável não-setada como erro.
if [ -n "${OLLAMA_HOST:-}" ]; then
    whitelist_ip "${OLLAMA_HOST}/32"
else
    echo "  AVISO: OLLAMA_HOST não definido, pulando"
fi

# Rede interna do docker-compose (mysql, mongodb, etcd, keycloak).
# É tráfego local entre containers, não sai pra internet — mas ainda passa
# pelo firewall porque tudo no OUTPUT é default-deny. Precisa do subnet
# fixo definido em "networks.devnet.ipam" no docker-compose.yml.
whitelist_ip "172.28.0.0/24"
# =========================================================================

HOST_IP=$(ip route | grep default | awk '{print $3}' || true)
if [ -n "$HOST_IP" ]; then
    ipset add allowed-domains "$HOST_IP/32" 2>/dev/null || true
fi

iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall inicializado. Domínios permitidos carregados."