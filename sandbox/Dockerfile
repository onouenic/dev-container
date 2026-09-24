# Imagem do dev-sandbox: onde os agentes (Claude Code, Codex, Qwen) rodam.
# Node é obrigatório porque os CLIs dos agentes são pacotes Node,
# independente da linguagem dos seus projetos.
FROM node:22-bookworm

ARG TZ=America/Sao_Paulo
ENV TZ="$TZ"
ENV DEBIAN_FRONTEND=noninteractive

# --- Pacotes de sistema ---
# Sem sudo, iptables ou ipset de propósito: o container roda sem nenhuma
# capability e sem caminho para virar root. O controle de rede fica FORA
# dele (egress-proxy + rede interna), onde o agente não consegue mexer.
# Adicione aqui o que faltar pra sua stack (Go, Rust, Java, etc.) — o
# agente não consegue instalar pacotes de sistema em runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    iproute2 \
    dnsutils \
    jq \
    less \
    procps \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code, Codex, Qwen (CLI) ---
# Versões fixas: atualize conscientemente (npm view <pacote> version) e
# rebuilde, em vez de pegar o que estiver em @latest no momento do build.
ARG CLAUDE_CODE_VERSION=2.1.280
ARG CODEX_VERSION=0.156.0
ARG QWEN_CODE_VERSION=0.24.4
RUN npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    @openai/codex@${CODEX_VERSION} \
    @qwen-code/qwen-code@${QWEN_CODE_VERSION} \
    && npm cache clean --force

# pnpm via corepack: respeita o "packageManager" de cada projeto.
RUN corepack enable pnpm

# --- GitHub CLI ---
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Docker CLI + buildx ---
# Só o cliente: o daemon é o sidecar docker-rootless (DOCKER_HOST aponta para
# ele). O agente usa `docker build`/`docker run`/`docker buildx` normalmente.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# --- Usuário não-root ---
# node:*-bookworm já vem com usuário "node" (uid/gid 1000). O compose passa
# HOST_UID/HOST_GID do .env para alinhar com o seu usuário no host.
ARG USERNAME=node
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupmod --gid $USER_GID $USERNAME \
    && usermod --uid $USER_UID --gid $USER_GID $USERNAME \
    && chown -R $USER_UID:$USER_GID /home/$USERNAME

# Diretórios que viram volumes nomeados: criados aqui com dono "node" para
# o volume nascer com essa ownership (volume vazio nasceria root:root).
RUN mkdir -p /commandhistory \
        /home/$USERNAME/.claude \
        /home/$USERNAME/.codex \
        /home/$USERNAME/.qwen \
        /home/$USERNAME/.config/gh \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME:$USERNAME /commandhistory /home/$USERNAME

# Config de shell em /etc (dono root): o agente não consegue alterá-la, e
# ela acompanha rebuilds da imagem (o ~/.bashrc fica no volume de home e só
# é copiado da imagem na primeira criação do volume).
COPY bash.bashrc.sandbox /etc/bash.bashrc.sandbox
RUN cat /etc/bash.bashrc.sandbox >> /etc/bash.bashrc && rm /etc/bash.bashrc.sandbox

# Regras do Claude Code no nível "managed" (dono root, maior precedência):
# o agente não consegue editá-las nem sobrescrevê-las pelo ~/.claude.
COPY managed-settings.json /etc/claude-code/managed-settings.json

# Scripts de boot e wrappers de npm/pnpm (ver cada arquivo).
COPY boot.sh setup-gh-auth.sh fix-permissions.sh /opt/sandbox/
COPY bin/ /opt/sandbox/bin/
RUN chmod 0755 /opt/sandbox/*.sh /opt/sandbox/bin/* \
    && chmod 0644 /etc/claude-code/managed-settings.json

# Instalações "globais" do agente vão para a home (volume), não para /usr.
ENV NPM_CONFIG_PREFIX=/home/$USERNAME/.npm-global
ENV PNPM_HOME=/home/$USERNAME/.local/share/pnpm
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
ENV PATH=/opt/sandbox/bin:/home/$USERNAME/.local/bin:/home/$USERNAME/.npm-global/bin:/home/$USERNAME/.local/share/pnpm:$PATH
# Shells de login (bash -l) reescrevem o PATH no /etc/profile e perderiam os
# wrappers de npm/pnpm; o profile.d devolve os caminhos acima.
RUN printf 'export PATH="/opt/sandbox/bin:/home/%s/.local/bin:/home/%s/.npm-global/bin:/home/%s/.local/share/pnpm:$PATH"\n' \
        "$USERNAME" "$USERNAME" "$USERNAME" > /etc/profile.d/00-sandbox-path.sh

WORKDIR /workspace

# Container inteiro roda como não-root a partir daqui.
USER $USERNAME
