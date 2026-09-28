#!/bin/sh
# Gera o squid.conf a partir do template e das variáveis de ambiente, valida
# e sobe o squid em foreground. O config gerado fica em /tmp (tmpfs): o
# filesystem do container é somente leitura.
set -eu

SANDBOX_SUBNET="${SANDBOX_SUBNET:?SANDBOX_SUBNET não definido}"
OLLAMA_HOST="${OLLAMA_HOST:-}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
CONF=/tmp/squid.conf
ALLOWLIST_DIR=/etc/squid/allowlists
LOCAL_ALLOWLIST="$ALLOWLIST_DIR/allowlist.local.txt"

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

# Allowlist local (opcional, fora do git): domínios internos deste host.
LOCAL_RULES="# allowlist.local.txt ausente: só a allowlist versionada"
if [ -f "$LOCAL_ALLOWLIST" ]; then
    LOCAL_RULES="acl allowlist dstdomain -n \"$LOCAL_ALLOWLIST\""
    echo "Allowlist local carregada: $LOCAL_ALLOWLIST"
fi

awk -v subnet="$SANDBOX_SUBNET" -v ollama="$OLLAMA_RULES" -v local_rules="$LOCAL_RULES" '
    { gsub(/@SANDBOX_SUBNET@/, subnet) }
    /@OLLAMA_RULES@/ { print ollama; next }
    /@ALLOWLIST_LOCAL@/ { print local_rules; next }
    { print }
' /etc/squid/squid.conf.template > "$CONF"

squid -k parse -f "$CONF"
echo "Egress proxy pronto. Domínios liberados: $ALLOWLIST_DIR/allowlist*.txt"
exec squid -N -f "$CONF"
