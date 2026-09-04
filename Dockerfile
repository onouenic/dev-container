# Base genérica: Node LTS em Debian (Node é obrigatório porque o Claude Code
# é um binário Node, independente da linguagem dos seus projetos).
FROM node:22-bookworm

ARG TZ
ENV TZ="$TZ"
ENV DEBIAN_FRONTEND=noninteractive

# --- Pacotes de sistema ---
# Toolchain genérico o bastante pra cobrir a maioria dos projetos.
# Adicione o que faltar pra sua stack específica (Go, Rust, Java, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    sudo \
    jq \
    less \
    procps \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code, Codex, Qwen (CLI) ---
RUN npm install -g \
    @anthropic-ai/claude-code@latest \
    @openai/codex@latest \
    @qwen-code/qwen-code@latest

# --- GitHub CLI ---
# Instalado via repositório oficial do GitHub (build-time, roda no host,
# não passa pelo firewall de runtime do container).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Usuário não-root ---
# node:*-bookworm já vem com usuário "node" (uid/gid 1000).
# Ajuste USER_UID/USER_GID se o seu usuário no host tiver outro uid (rode `id -u`).
ARG USERNAME=node
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupmod --gid $USER_GID $USERNAME 2>/dev/null || true \
    && usermod --uid $USER_UID --gid $USER_GID $USERNAME 2>/dev/null || true \
    && chown -R $USER_UID:$USER_GID /home/$USERNAME

# Histórico de shell persistente (via volume no compose)
RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME /commandhistory \
    && echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/$USERNAME/.bashrc \
    && echo 'export PROMPT_COMMAND="history -a"' >> /home/$USERNAME/.bashrc \
    && echo 'cd /workspace 2>/dev/null' >> /home/$USERNAME/.bashrc \
    && cat >> /home/$USERNAME/.bashrc << 'BASHRCEOF'

# Injeta o token do gh (já autenticado via `gh auth login`) só durante o
# "pnpm install", pra ele conseguir autenticar no npm.pkg.github.com
# (@nicbrasil). O token existe só nesse processo, não fica setado pro
# resto da sessão. Precisa do "command" pra não recursar na própria função.
pnpm() {
    if [ "$1" = "install" ] || [ "$1" = "i" ]; then
        GITHUB_TOKEN="$(gh auth token 2>/dev/null)" command pnpm "$@"
    else
        command pnpm "$@"
    fi
}
BASHRCEOF

RUN mkdir -p /home/$USERNAME/.claude \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME/.claude

# O volume gh-config é inicializado a partir deste diretório (ownership do node)
# na primeira montagem: sem isso, o volume vazio nasce root:root e o
# setup-gh-auth.sh (rodando como node) não consegue gravar o hosts.yml.
RUN mkdir -p /home/$USERNAME/.config/gh \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/gh

# Regras de permissão do Claude Code, no nível de usuário (não por projeto)
# — cobrem automaticamente QUALQUER projeto dentro de /workspace. Fetch,
# pull e commit local rodam livres (baixo risco: só trazem/gravam dados
# que o agente já enxerga localmente). Ações que saem do container e
# afetam o repositório compartilhado — push, PR, secrets, workflows —
# exigem sua confirmação explícita.
#
# Editar um workflow do GitHub Actions localmente não tem efeito nenhum
# até ser dado push, então gatear o push já cobre esse risco por tabela,
# sem precisar de uma regra separada pra edição de arquivo.
RUN cat > /home/$USERNAME/.claude/settings.json << 'SETTINGSEOF'
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
SETTINGSEOF
RUN chown $USERNAME:$USERNAME /home/$USERNAME/.claude/settings.json

# --- Firewall ---
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# --- Fix de permissões do workspace (normaliza ownership pro node, ver script) ---
COPY fix-permissions.sh /usr/local/bin/fix-permissions.sh
RUN chmod +x /usr/local/bin/fix-permissions.sh

# --- Auth do GitHub no boot (persiste o token no gh config, ver script) ---
COPY setup-gh-auth.sh /usr/local/bin/setup-gh-auth.sh
RUN chmod +x /usr/local/bin/setup-gh-auth.sh

# sudo SEM SENHA restrito a comandos específicos. "node" NÃO tem sudo geral:
# - init-firewall.sh: única forma de alterar as regras (roda uma vez no boot)
# - fix-permissions.sh: normaliza ownership do /workspace pro node (roda no boot)
# - iptables -L / ipset list: só leitura, pra debugar sem poder alterar nada
RUN { \
      echo "$USERNAME ALL=(root) NOPASSWD: SETENV: /usr/local/bin/init-firewall.sh"; \
      echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/fix-permissions.sh"; \
      echo "$USERNAME ALL=(root) NOPASSWD: /usr/sbin/iptables -L *"; \
      echo "$USERNAME ALL=(root) NOPASSWD: /usr/sbin/ipset list*"; \
    } > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

WORKDIR /workspace

# Container inteiro roda como não-root a partir daqui.
USER $USERNAME