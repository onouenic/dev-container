#!/bin/sh
# Gera o squid.conf a partir do template e das variáveis de ambiente, valida
# e sobe o squid em foreground. O config gerado fica em /tmp (tmpfs): o
# filesystem do container é somente leitura.
set -eu

SANDBOX_SUBNET="${SANDBOX_SUBNET:?SANDBOX_SUBNET não definido}"
OLLAMA_HOST="${OLLAMA_HOST:-}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
CONF=/tmp/squid.conf

ipv4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'

if ! echo "$SANDBOX_SUBNET" | grep -Eq "$cidr_re"; then
    echo "ERRO: SANDBOX_SUBNET inválido: $SANDBOX_SUBNET" >&2
    exit 1
fi

# Ollama/LLM local: liberado só no IP e porta informados, via HTTP simples.
OLLAMA_RULES="# OLLAMA_HOST não definido: nenhum servidor LLM local liberado"
if [ -n "$OLLAMA_HOST" ]; then
    if ! echo "$OLLAMA_HOST" | grep -Eq "$ipv4_re" || ! echo "$OLLAMA_PORT" | grep -Eq '^[0-9]{1,5}$'; then
        echo "ERRO: OLLAMA_HOST deve ser um IPv4 e OLLAMA_PORT um número (recebido: $OLLAMA_HOST:$OLLAMA_PORT)" >&2
        exit 1
    fi
    OLLAMA_RULES="acl ollama_dst dst $OLLAMA_HOST/32
acl ollama_port port $OLLAMA_PORT
http_access allow sandbox ollama_dst ollama_port !CONNECT"
    echo "Liberando LLM local: http://$OLLAMA_HOST:$OLLAMA_PORT"
fi

awk -v subnet="$SANDBOX_SUBNET" -v ollama="$OLLAMA_RULES" '
    { gsub(/@SANDBOX_SUBNET@/, subnet) }
    /@OLLAMA_RULES@/ { print ollama; next }
    { print }
' /etc/squid/squid.conf.template > "$CONF"

squid -k parse -f "$CONF"
echo "Egress proxy pronto. Domínios liberados: /etc/squid/allowlist.txt"
exec squid -N -f "$CONF"
