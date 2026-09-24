#!/bin/bash
# Roda no serviço one-shot "workspace-perms" (container separado, como root,
# só com CAP_CHOWN e CAP_DAC_READ_SEARCH, sem rede), antes do dev-sandbox
# subir. O agente não consegue executar este script como root.
#
# Garante que tudo em /workspace pertence ao HOST_UID/HOST_GID (que é o
# "node" dentro do dev-sandbox). A defesa principal é alinhar HOST_UID/GID
# no .env; isto é a rede de segurança para projeto clonado com sudo,
# copiado de outra máquina, extraído de .zip com UID de outro lugar, etc.
#
# find -P (padrão) não segue symlinks e chown -h altera o próprio link, não
# o alvo: um symlink plantado no workspace não consegue redirecionar o
# chown para fora dele. -xdev não atravessa outros filesystems montados.
set -euo pipefail

uid="${HOST_UID:?HOST_UID não definido}"
gid="${HOST_GID:?HOST_GID não definido}"

if [ ! -d /workspace ]; then
    echo "AVISO: /workspace não existe, pulando normalização de ownership"
    exit 0
fi

echo "Verificando ownership de /workspace (esperado $uid:$gid)..."
find /workspace -xdev \( ! -user "$uid" -o ! -group "$gid" \) -exec chown -h "$uid:$gid" {} +
echo "Ownership normalizado."
