#!/bin/bash
# Roda como root no boot do container (antes do node assumir).
# Garante que TUDO em /workspace pertence de fato ao usuário "node",
# não só que ele tenha acesso — normaliza a ownership, não só a permissão.
#
# A defesa principal contra esse problema é alinhar HOST_UID/HOST_GID no
# .env com o seu usuário real do host (veja docker-compose.yml): projetos
# clonados/criados normalmente por você já nascem com o dono certo, sem
# precisar deste script. Isso aqui é a rede de segurança pros casos que
# fogem disso: projeto clonado com sudo, copiado de outra máquina, extraído
# de um .zip preservando UID de outro lugar, etc.
#
# Usa `find ! -user node -exec chown` em vez de `chown -R` direto:
# só toca no que realmente está com dono errado, então depois do primeiro
# boot (quando a maioria já está correta), fica rápido nos boots seguintes.
set -uo pipefail

if [ ! -d /workspace ]; then
    echo "AVISO: /workspace não existe, pulando normalização de ownership"
    exit 0
fi

echo "Verificando ownership de /workspace..."

find /workspace -xdev \( ! -user node -o ! -group node \) -exec chown node:node {} + 2>/dev/null

echo "Ownership normalizado — tudo em /workspace pertence ao node."