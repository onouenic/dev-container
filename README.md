# dev-sandbox: ambiente isolado para agentes

Um container persistente onde agentes de código (Claude Code, Codex, Qwen)
podem fazer o que quiserem, com os bancos e serviços das aplicações ao lado,
**sem conseguir agir fora dele**: sem acesso ao host, à LAN, aos outros
containers do host ou à internet fora de uma allowlist de domínios.

## Modelo de segurança

```
internet ◄── egress-proxy (squid, allowlist por domínio, logs) ◄──┐
                                                                  │ rede "devnet"
dev-sandbox (sem capabilities, sem sudo, no-new-privileges,       │ (internal: sem gateway,
             rootfs read-only, limites de CPU/memória/processos) ─┘  sem rota pro host)
      │
      └──► mysql / postgres / mongodb / redis / rabbitmq / etcd / keycloak / minio / clamav
           (também só na devnet: sem internet, sem porta no host)

host 127.0.0.1:18080 / :18672 / :19001 ──► ui-gateway ──► painéis do Keycloak / RabbitMQ / MinIO
```

O que isso garante (validado ao subir a stack):

| Tentativa do agente | Resultado |
|---|---|
| Virar root / mexer em rede | Sem sudo, `CapEff=0`, `NoNewPrivs=1` |
| Sair direto pra internet, ignorando o proxy | `Network is unreachable` — a devnet não tem rota |
| Domínio fora da allowlist, ou IP literal | `403` no proxy (`TCP_DENIED` no log) |
| DNS externo (exfiltração por DNS) | `SERVFAIL` — o DNS da devnet não resolve nomes externos |
| Host, LAN, containers do host (`mysql8:3306`, `keycloak-local`...) | Sem rota; pelo proxy, destinos privados são bloqueados |
| Usar um banco como ponte (`COPY ... TO PROGRAM`, `REPLICAOF`) | Os serviços também estão sem rede externa |
| Alterar firewall, allowlist ou regras do Claude | Estão em outro container / em `/etc`, dono root, rootfs read-only |

**O que continua possível, por natureza** (risco residual, aceite consciente):

- Todo domínio liberado é também um canal de saída. Com `github.com` liberado,
  o agente pode enviar dados para um repositório; com `api.anthropic.com` /
  `api.openai.com`, para uma conta de LLM. Mantenha a allowlist enxuta.
- O agente lê tudo que ele usa: tokens em `/run/secrets`, logins dos LLMs,
  senhas dos bancos. A proteção é o **escopo** de cada credencial, não
  esconder o valor.
- O kernel é o do host. Para isolar também o kernel, use gVisor (abaixo).
- O agente escreve no `WORKSPACE_DIR`, que é uma pasta real do host (próxima
  seção).

## Onde ficam os projetos (`WORKSPACE_DIR`)

Use um **diretório dedicado ao agente**, com clones próprios dos projetos —
por exemplo `/opt/agent-workspace` — e **não** um diretório que o host executa
ou serve.

Tudo o que o agente escreve ali vira código no host. Se esse diretório for
usado por outra coisa, a escrita do agente sai do sandbox por tabela:

- **Containers do host que montam essa pasta**: se algum container do host
  monta o diretório com escrita (ex.: um servidor web servindo o document
  root de um site), um arquivo que o agente escrever ali passa a rodar na
  hora nesse container — que normalmente tem rede livre. Não use como
  `WORKSPACE_DIR` nenhuma pasta servida ou montada por outros containers.
- **Coisas que você roda no host**: `docker compose up` de um projeto
  (o agente pode ter adicionado `privileged` ou o `docker.sock` — e você está
  no grupo `docker`, equivalente a root), `npm install`/`npm run` (scripts do
  `package.json`), `.git/hooks`, `.vscode/tasks.json`, `.envrc`.

Regras práticas:

1. Deixe o agente trabalhar em `/opt/agent-workspace`; traga as mudanças para
   o resto do mundo **via git** (push de branch + PR revisado por você).
2. Não rode no host, sem revisar o diff, nada que o agente tenha editado.
3. Este repositório (`dev-container`) nunca deve ficar dentro do
   `WORKSPACE_DIR` — senão o agente edita a própria jaula.
4. O agente pode apagar o que estiver no workspace. Tudo que importa deve
   estar num remote git.

## Autenticação do agente

| Credencial | Onde fica | Para quê | Pode |
|---|---|---|---|
| **Classic PAT `repo`** | `secrets/gh_token` → `/run/secrets/gh_token` → gh config | `git clone/pull/push`, `gh` de leitura | push de branches (em todo repo que o dono acessa) |
| **Classic PAT `read:packages`** | `secrets/gh_packages_token` | `npm/pnpm install` de `@nicbrasil` (npm.pkg.github.com) | só baixar pacotes |
| `claude login` | volume `claude-code-config` | Claude Code | — |
| `codex login` | volume `codex-config` | Codex | — |
| Qwen (backend LLM) | `.env` (`OPENAI_*`) ou `~/.qwen/settings.json` (volume) | Qwen Code | — |
| Senhas dos bancos / Keycloak | `.env` → env vars do sandbox | serviços locais | só na devnet |

Nenhum token do GitHub fica em variável de ambiente: o `gh_token` é gravado no
gh config no boot, e o `gh_packages_token` é injetado pelos wrappers de
`npm`/`pnpm` só nos subcomandos que baixam pacotes.

### 1. Token de push (`secrets/gh_token`) — classic PAT

Crie em *GitHub → Settings → Developer settings → Personal access tokens →
Tokens (classic)*:

- **Scopes**: só **`repo`** (clone, pull e push em repositórios privados;
  se o agente só mexer em repos públicos, `public_repo` basta).
- **Nada além disso**: sem `workflow` (o push de mudanças em
  `.github/workflows/` é recusado), sem `admin:*`, `delete_repo`,
  `write:packages`, `read:org` etc.
- **Expiration**: curta (30–90 dias).
- Se a org usa SSO/SAML, autorize o token para a org (*Configure SSO*).

**O que isso implica.** Diferente de um fine-grained, o clássico não se
restringe a repositórios escolhidos nem a permissões por tipo: com `repo`, o
agente lê todo repositório privado que o dono do token acessa, faz push em
todos em que ele tem escrita e, pela API, consegue abrir, aprovar e mergear
PR. Por isso o sandbox combina três camadas:

- **Rulesets no GitHub** (item 2) — a única barreira real, do lado do servidor.
- **Política de git nas diretrizes** — o `boot.sh` grava em
  `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` e `~/.qwen/QWEN.md` que o agente
  só usa `git pull`, `git add`, `git commit` e, no máximo, `git push` da
  branch de trabalho: nada de PR, merge, push na `main`/`master`, force push
  ou apagar branch remota. Vale para os três agentes, mas é orientação: não
  resiste a prompt injection.
- **`managed-settings.json`** (item 4) — nega esses comandos no Claude Code.

### 2. Barreira contra merge: rulesets no GitHub (obrigatório)

O token sozinho **não impede merge**: o agente pode dar `git merge` local e
push na `main`, ou mergear um PR pela API. A barreira real é um **ruleset** na
branch padrão de cada repositório (*Settings → Rules → Rulesets*), alvo
`main`/`master`:

- **Restrict updates** — só quem está na lista de bypass atualiza a branch
  (isso bloqueia push direto *e* merge de PR)
- **Require a pull request before merging**
- **Block force pushes** e **Restrict deletions**
- Opcional: um segundo ruleset para tags (`Restrict creations/updates`), para
  o agente não criar tag/release que dispare deploy.

**Atenção à identidade:** o token age como o usuário dono dele. Se esse
usuário estiver na lista de bypass (ou for admin com bypass), o agente
também está. Bloquear push direto na `main` **não** impede o dono do token
de mergear o próprio PR: para o GitHub, o agente *é* você. Isso só fecha se o
ruleset exigir aprovação de **outra pessoa** (e o dono do token não tiver
bypass) ou se o merge ficar restrito a quem não é o dono do token. Se você
usa a própria conta e mergeia com ela, o merge pelo agente fica contido só
pelas diretrizes e pelo `managed-settings.json`. Uma **conta dedicada**
(machine user) com escrita apenas nos repositórios do agente separa as duas
identidades e reduz o raio de dano do clássico.

**CI:** um push do agente dispara os workflows `on: push` com o código dele.
Não exponha secrets de deploy a workflows que rodam em branches não
protegidas (use *Environments* com aprovação).

### 3. Token de pacotes (`secrets/gh_packages_token`) — classic PAT

O registry npm do GitHub Packages não aceita fine-grained tokens. Crie um
*classic* token só com o escopo **`read:packages`** (nada de `repo`). O
`.npmrc` dos projetos continua igual:

```
@nicbrasil:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

### 4. Camada extra no Claude Code

`/etc/claude-code/managed-settings.json` (dentro da imagem, dono root) nega
`gh pr create/merge/review/edit/ready/close/reopen`, `gh api`,
`gh repo create/delete`, `gh secret`, `gh workflow`, `gh release create`,
`git merge`, force push, `git push --delete` e push para `main`/`master`.
É só defesa em profundidade: vale para o Claude Code, não para Codex/Qwen nem
para outras formas de chamar a API (ex.: `curl`). A barreira real é o item 2.

## Pré-requisitos (no host)

Antes de subir, tenha no host:

- **Docker Engine + Docker Compose v2** — confira com `docker compose version`.
- **Um clone do `nicrobots-prompts`** — é a fonte ÚNICA de diretrizes e skills
  dos agentes. Clone em qualquer lugar do host e anote o caminho absoluto (vai
  em `NICROBOTS_DIR` no `.env`):
  ```bash
  git clone https://github.com/<org>/nicrobots-prompts.git /opt/nicrobots-prompts
  ```
- **Um diretório dedicado ao agente** para os projetos (`WORKSPACE_DIR`), fora
  de qualquer pasta que o host execute ou sirva — ver "Onde ficam os projetos".
- **Tokens do GitHub e contas dos LLMs** — ver "Autenticação do agente". Dá
  para subir sem eles (o GitHub fica sem auth e você loga nos LLMs depois).
- **(Opcional) IPv6 no daemon do host** — necessário só se o *agente* for
  buildar imagens base de um registry privado só com IPv6. O
  dev-container em si não precisa: a imagem base dele vem do Docker Hub.

## Setup inicial (passo a passo)

1. **Prepare o workspace** e clone nele os projetos em que o agente vai mexer:
   ```bash
   sudo mkdir -p /opt/agent-workspace && sudo chown "$(id -u):$(id -g)" /opt/agent-workspace
   git clone https://github.com/<org>/<projeto>.git /opt/agent-workspace/<projeto>
   ```
2. **Crie o `.env`** a partir do modelo:
   ```bash
   cp .env.example .env
   ```
   Preencha no mínimo (o compose recusa subir sem as obrigatórias):
   - `WORKSPACE_DIR` — o diretório do passo 1 (ex.: `/opt/agent-workspace`)
   - `NICROBOTS_DIR` — o clone do nicrobots-prompts (ver pré-requisitos)
   - `HOST_UID` / `HOST_GID` — saída de `id -u` e `id -g`
   - `GIT_USER_NAME` / `GIT_USER_EMAIL` — identidade dos commits do agente
   - Senhas dos serviços — gere cada uma com `openssl rand -hex 16`
   - (Opcional) `COMPOSE_PROFILES=db,auth` para já subir bancos + Keycloak
   - (Opcional) backend do Qwen — ver seção "Qwen"
3. **Crie os secrets do GitHub** (podem ficar vazios; aí o GitHub fica sem auth
   e você preenche depois):
   ```bash
   umask 077
   printf '%s' 'ghp_...'        > secrets/gh_token          # classic PAT, escopo repo (push)
   printf '%s' 'ghp_...'        > secrets/gh_packages_token  # classic PAT (read:packages)
   ```
4. **Suba a stack** e confira o boot:
   ```bash
   docker compose up -d --build
   docker compose logs dev-sandbox   # espere "GitHub auth configurado..." e "Skills nicrobots ligadas (N)."
   ```
5. **Faça login nos LLMs** (uma vez; fica nos volumes):
   ```bash
   docker exec -it dev-sandbox bash
   claude login      # e/ou: codex login
   ```
6. **Configure os rulesets no GitHub** (ver "Autenticação do agente", item 2) —
   é a barreira real contra merge/push direto na branch protegida.

> **Subiu com erro `defina X no .env`?** Falta uma variável obrigatória (as mais
> esquecidas: `NICROBOTS_DIR`, `HOST_UID/GID`). Preencha e rode
> `docker compose up -d` de novo.

## Uso do dia a dia

```bash
docker exec -it dev-sandbox bash     # já cai em /workspace
cd /workspace/projeto-a
claude --dangerously-skip-permissions
```

Parar / voltar:
```bash
docker compose stop
docker compose up -d
```

Instalações do agente: sem root, ele não instala pacotes de sistema. `npm i -g`,
`pnpm add -g`, `pip` em venv e binários em `~/.local/bin` funcionam (ficam no
volume `sandbox-home`). Ferramenta de sistema que faltar: adicione no
`sandbox/Dockerfile` e rebuilde.

## Liberando domínios

A allowlist fica em `proxy/allowlist.txt` (neste repositório, fora do alcance
do agente). Domínios internos ou específicos do seu host (registry privado,
gateway LLM da empresa) vão em `proxy/allowlist.local.txt`, que fica fora do
git: copie de `proxy/allowlist.local.txt.example`. Mesmo formato; o arquivo é
opcional e não deve repetir domínios da allowlist versionada. Para ver o que foi bloqueado:

```bash
docker logs -f dev-egress-proxy | grep TCP_DENIED
```

Adicione o domínio (`api.exemplo.com`, ou `.exemplo.com` para incluir
subdomínios) e reinicie só o proxy:

```bash
docker compose restart egress-proxy
```

O que respeita o proxy automaticamente: curl, git, gh, npm, pnpm/corepack,
pip, Claude Code, Codex e o `fetch` do Node (`NODE_USE_ENV_PROXY=1`).
Ferramentas que ignoram `HTTPS_PROXY` (ex: Maven/Gradle sem config de proxy,
alguns SDKs) simplesmente não saem — configure o proxy nelas
(`egress-proxy:3128`).

## Bancos, Keycloak, MinIO e ClamAV

Atrás de profiles (`db`, `auth` e `storage`):

```bash
docker compose --profile db --profile auth --profile storage up -d
# ou COMPOSE_PROFILES=db,auth,storage no .env
```

| Serviço | Host (de dentro do dev-sandbox) | Variáveis prontas |
|---|---|---|
| MySQL | `mysql:3306` | `MYSQL_HOST/PORT/USER/PASSWORD/DATABASE` |
| PostgreSQL | `postgres:5432` | `DATABASE_URL`, `POSTGRES_*` |
| MongoDB | `mongodb:27017` | `MONGO_URI` |
| Redis | `redis:6379` | `REDIS_URL` |
| RabbitMQ | `rabbitmq:5672` | `RABBITMQ_URL` |
| etcd | `etcd:2379` | `ETCD_ENDPOINTS` (sem auth, dev only) |
| Keycloak | `keycloak:8080` | `KEYCLOAK_URL`, `KEYCLOAK_ADMIN*` |
| MinIO (S3) | `minio:9000` | `MINIO_ENDPOINT/PORT/USE_SSL/ACCESS_KEY/SECRET_KEY`, `S3_ENDPOINT` |
| ClamAV (clamd) | `clamav:3310` | `CLAMAV_HOST/PORT` |

Painéis no navegador do host (só `127.0.0.1`, portas configuráveis no `.env`):

- Keycloak: http://localhost:18080
- RabbitMQ: http://localhost:18672
- MinIO (console): http://localhost:19001

Os bancos não têm porta no host de propósito. O Keycloak em `start-dev` é só
para desenvolvimento local.

MinIO: a MinIO parou de publicar imagens community no Docker Hub, então a
imagem vem de `MINIO_IMAGE` no `.env` (um espelho da oficial no seu registry). Os buckets não são
criados automaticamente: crie-os pela aplicação, pelo console ou com `mc`.

ClamAV: a imagem já traz assinaturas, então o clamd sobe sem internet (leva
~30 s para carregá-las). O `freshclam` as atualiza pelo egress-proxy
(`database.clamav.net` na allowlist) e as guarda no volume `clamav-data`. O
clamd ocupa ~1 GB de RAM, e o dobro durante o reload das assinaturas
(`CLAMAV_MEM_LIMIT`, padrão 3g). Para testar: arquivo EICAR via INSTREAM em
`clamav:3310`.

## VS Code

*Dev Containers: Attach to Running Container…* → `dev-sandbox` funciona, mas o
VS Code cria um canal entre o container e o host que não foi feito para
resistir a um container malicioso. Antes de anexar, desligue no VS Code do
host:

```json
{
  "dev.containers.copyGitConfig": false,
  "dev.containers.gitCredentialHelperConfigLocation": "none",
  "remote.autoForwardPorts": false
}
```

e não tenha um `ssh-agent` com chaves carregado (ele é repassado ao
container). Confira dentro do container: `echo $SSH_AUTH_SOCK` deve estar
vazio. Para máximo isolamento, use só o terminal (`docker exec`).

## Qwen

O Qwen Code fala com qualquer backend **compatível com a API da OpenAI**, pelas
variáveis `OPENAI_API_KEY`, `OPENAI_BASE_URL` e `OPENAI_MODEL` (as mesmas do
Codex — se usar os dois, não as compartilhe sem querer). Configure no `.env` e o
compose as repassa ao dev-sandbox; aplique com `docker compose up -d dev-sandbox`.

**Gateway compatível com a API da OpenAI** — recomendado:

```bash
# no .env  (troque pelos valores do seu gateway)
OPENAI_API_KEY=<sua-chave>
OPENAI_BASE_URL=https://<seu-gateway>/v1
OPENAI_MODEL=<id-do-modelo>
```

Três detalhes que evitam os erros mais comuns:

1. **Libere o domínio do gateway na allowlist local** (`proxy/allowlist.local.txt` +
   `docker compose restart egress-proxy`) — senão o proxy bloqueia a saída.
2. **O `OPENAI_BASE_URL` precisa terminar em `/v1`** — sem isso o gateway
   responde `405 Method Not Allowed`.
3. **Use o ID exato do modelo** que o gateway expõe, com prefixos e tudo
   (alguns gateways usam `provedor/modelo:tag`). Liste os disponíveis com:
   ```bash
   docker exec -u node dev-sandbox bash -lc \
     'curl -s -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models"'
   ```

**Ollama numa máquina da rede** — alternativa: defina `OLLAMA_HOST` (IPv4) e
`OLLAMA_PORT` no `.env` (o proxy libera só esse destino) e aponte o Qwen para
ele com as mesmas `OPENAI_*` (`OPENAI_BASE_URL=http://IP:11434/v1`) ou por
`~/.qwen/settings.json` (volume `qwen-config`) com `modelProviders`.

## Isolamento de kernel com gVisor (opcional)

O sandbox roda com o runtime padrão do Docker (`runc`), compartilhando o
kernel do host — uma falha de kernel seria o caminho restante de fuga. Se
quiser fechar também essa brecha, dá para trocar o runtime pelo gVisor, que
intercepta as syscalls do container:

```bash
# no host — https://gvisor.dev/docs/user_guide/install/
sudo runsc install && sudo systemctl restart docker
# no .env
SANDBOX_RUNTIME=runsc
docker compose up -d --force-recreate dev-sandbox
```

## Permissões de arquivo (EACCES)

`HOST_UID`/`HOST_GID` alinham o usuário `node` do container com o seu usuário
do host. Como rede de segurança, o serviço one-shot `workspace-perms` roda
antes do sandbox e passa para esse UID/GID tudo em `WORKSPACE_DIR` com dono
diferente (sem seguir symlinks). Ele roda como root só com `CAP_CHOWN` e
`CAP_DAC_READ_SEARCH`, sem rede, e sai — o agente não tem acesso a ele.

## Atualizando os CLIs

As versões ficam fixas em `sandbox/Dockerfile` (`CLAUDE_CODE_VERSION`,
`CODEX_VERSION`, `QWEN_CODE_VERSION`). Para atualizar:

```bash
npm view @anthropic-ai/claude-code version
# edite o ARG e:
docker compose build dev-sandbox && docker compose up -d dev-sandbox
```
