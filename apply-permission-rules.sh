#!/bin/bash
# Roda no HOST (não dentro do container). Aplica as regras de "ask" do
# Claude Code no volume claude-code-config já existente, sem precisar
# recriar o volume do zero. Útil se você já tinha feito `claude login`
# antes desta mudança (o rebuild sozinho não sobrescreve volume existente).
set -euo pipefail

docker exec dev-sandbox bash -c 'cat > ~/.claude/settings.json << "EOF"
{
  "permissions": {
    "ask": [
      "Bash(git push *)",
      "Bash(git push --force*)",
      "Bash(git branch -D *)",
      "Bash(git branch --delete *)",
      "Bash(gh repo delete *)",
      "Bash(gh repo create *)",
      "Bash(gh secret set *)",
      "Bash(gh workflow *)"
    ]
  }
}
EOF'

echo "Regras aplicadas em ~/.claude/settings.json dentro do dev-sandbox."
docker exec dev-sandbox cat /home/node/.claude/settings.json