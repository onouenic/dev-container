# Container único para múltiplos projetos

Diferente do dev container "por projeto" que te passei antes, esta versão sobe
**um único container persistente** com o seu diretório de projetos inteiro
montado em `/workspace`. Você entra nele quando quiser trabalhar, navega entre
os projetos como pastas normais, e sai/entra sem perder o estado do container.

## Setup inicial (uma vez só)

1. Coloque estes 4 arquivos numa pasta separada, **fora** dos seus repositórios
   de projeto — ex: `~/dev-sandbox/` (não dentro de nenhum projeto específico):
   ```
   ~/dev-sandbox/
   ├── docker-compose.yml
   ├── Dockerfile
   ├── init-firewall.sh
   └── .env.example
   ```

2. Copie `.env.example` para `.env` e ajuste o caminho para a pasta que contém
   TODOS os seus projetos:
   ```bash
   cp .env.example .env
   # edite .env e defina, por exemplo:
   # WORKSPACE_DIR=/home/seu-usuario/projects
   ```
   Essa pasta deve conter seus projetos como subpastas:
   ```
   /home/seu-usuario/projects/
   ├── projeto-a/
   ├── projeto-b/
   └── projeto-c/
   ```

3. Dê permissão de execução ao firewall e suba o container:
   ```bash
   chmod +x init-firewall.sh
   docker compose up -d --build
   ```
   Isso builda a imagem, sobe o container em background, e roda o firewall
   automaticamente (via `sudo`, restrito só a esse script — o usuário não é
   root o tempo todo).

4. Autentique (cada dev faz isso uma vez, sessão fica salva no volume —
   não precisa repetir a cada restart do container):
   ```bash
   docker exec -it dev-sandbox bash
   claude login
   codex login          # se for usar o Codex
   gh auth login        # navegador, autoriza a conta GitHub da pessoa
   gh auth setup-git    # configura o git pra usar essa sessão automaticamente
   ```
   **Por que HTTPS/`gh auth login` em vez de SSH:** este workspace é
   multi-projeto e pensado pra qualquer dev do time subir sem fricção. SSH
   exigiria gerar uma Deploy Key por repositório (alguém com admin no repo
   precisa cadastrar cada uma) — não escala bem conforme mais projetos e
   mais devs entram. `gh auth login` usa a permissão que a pessoa já tem
   na conta GitHub dela, cobre qualquer repo que ela acessa, e não depende
   de ninguém cadastrar nada manualmente. Se algum caso específico realmente
   precisar de SSH com Deploy Key (ex: automação restrita a um repo só),
   ainda dá pra configurar à parte — mas não é o padrão do template.

## Uso do dia a dia

Entrar no container (já cai em `/workspace`):
```bash
docker exec -it dev-sandbox bash
```

Dentro dele, navegue pra qualquer projeto normalmente:
```bash
cd /workspace/projeto-a
claude
# ou, se quiser rodar sem prompts de permissão:
claude --dangerously-skip-permissions
```

Trocar de projeto é só `cd` — mesmo container, mesmo terminal:
```bash
cd /workspace/projeto-b
claude
```

Parar o container quando não estiver usando (opcional — ele fica com
`restart: unless-stopped`, então sobrevive a reboots se você não parar
manualmente):
```bash
docker compose stop
```

Voltar a usar:
```bash
docker compose up -d
docker exec -it dev-sandbox bash
```

## Usando com VS Code (sem devcontainer.json por projeto)

Em vez de "Reopen in Container" (que espera um `.devcontainer/` dentro do
próprio repo), use **attach a um container já rodando**:

1. Instale a extensão **Dev Containers**.
2. `Ctrl+Shift+P` → **Dev Containers: Attach to Running Container...**
3. Selecione `dev-sandbox` na lista.
4. Uma nova janela do VS Code abre já dentro do container. Faça
   **File → Open Folder** e escolha `/workspace/projeto-a` (ou qualquer outro).

Isso te dá terminal integrado, extensões, IntelliSense, tudo rodando dentro
do container — sem precisar de `.devcontainer/` em cada repositório.

## O que você ganha e o que perde nesse modelo

**Ganha:**
- Zero configuração por projeto novo — só clonar dentro de `WORKSPACE_DIR` e
  já está disponível no container.
- Um único build, um único container pra manter.
- Histórico de shell e config do Claude Code persistem entre sessões (via
  volumes nomeados no compose).

**Perde (trade-off consciente):**
- **Isolamento entre projetos.** Todos compartilham o mesmo container, mesma
  rede, mesmo firewall allowlist. Se um projeto precisa de acesso a um domínio
  sensível, esse acesso fica disponível pra todos os projetos rodando ali dentro.
- **Ferramentas globais compartilhadas.** Se dois projetos exigem versões
  Node/Python globais diferentes, isso pode conflitar. Prefira instalar
  dependências localmente por projeto (`node_modules`, `venv` dentro de cada
  pasta) em vez de pacotes globais.
- **Firewall único.** Você vai precisar manter `init-firewall.sh` atualizado
  conforme os domínios que os VÁRIOS projetos precisam, não só um.

Se em algum momento um projeto específico precisar de isolamento mais forte
(ex: repositório não confiável, dependências sensíveis), vale rodar esse
projeto num container à parte, ou até numa VM dedicada, em vez de misturar
tudo neste sandbox compartilhado.

## Configurando cada LLM (credenciais e endpoints)

Nenhuma credencial fica no `Dockerfile` — ele só instala os binários.

**Padrão recomendado — login interativo, sessão fica no volume**
```bash
docker exec -it dev-sandbox bash
claude login   # sessão salva no volume claude-code-config
codex login    # sessão salva no volume codex-config
```
A chave nunca fica como variável de ambiente — só num arquivo de config que
o próprio binário lê, não é herdada por processos filhos.

**Alternativa — `.env`** (mais simples de automatizar, mas expõe a chave
pra qualquer subprocesso que o agente rodar — veja a seção de segurança
mais abaixo antes de optar por isso). Se preferir mesmo assim, descomente
`ANTHROPIC_API_KEY`/`OPENAI_API_KEY` no `.env.example` e adicione de volta
ao bloco `environment:` do `dev-sandbox` no `docker-compose.yml`.

### Claude Code
Usa `ANTHROPIC_API_KEY` (via `.env`) ou `claude login`. Sem conflito com os
outros dois.

### Codex
Usa `OPENAI_API_KEY` (via `.env`) ou `codex login`. Por padrão fala com a API
real da OpenAI.

### Qwen — cuidado com a colisão de variáveis
O Qwen Code usa o **mesmo padrão de variáveis** que o Codex (`OPENAI_API_KEY`,
`OPENAI_BASE_URL`), porque os dois seguem a spec OpenAI-compatible. Setar
`OPENAI_BASE_URL` global no `docker-compose.yml` quebraria o Codex (ele
tentaria falar com seu Ollama em vez da OpenAI real).

Duas formas de evitar o conflito:

**Opção 1 — flags na hora de rodar (recomendado, não toca em env global):**
```bash
qwen --openai-api-key "ollama-local" \
     --openai-base-url "http://IP-DO-SERVIDOR:11434/v1" \
     --model "qwen3-coder:30b"
```

**Opção 2 — `~/.qwen/settings.json`** (persiste no volume `qwen-config`,
não usa `OPENAI_*` do ambiente, então não colide com o Codex):
```json
{
  "modelProviders": {
    "ollama-local": {
      "envKey": "OLLAMA_API_KEY",
      "baseUrl": "http://IP-DO-SERVIDOR:11434/v1",
      "id": "qwen3-coder:30b"
    }
  }
}
```
E defina `OLLAMA_API_KEY` (nome customizado, não `OPENAI_API_KEY`) só nessa
sessão ou no `.env`, sem afetar o Codex.
## GitHub — autenticação sem deixar token em env var

Em vez de `GITHUB_TOKEN` como variável de ambiente global (que qualquer
processo filho herda automaticamente), use o `gh` CLI com login interativo,
uma vez, dentro do container:

```bash
docker exec -it dev-sandbox bash
gh auth login
gh auth setup-git   # configura o git pra usar a sessão do gh automaticamente
```

A sessão fica salva no volume `gh-config`, persiste entre restarts do
container. Depois disso, `git clone`, `git push`, `gh pr create`, etc.
funcionam sem token nenhum exposto como env var — a credencial só é lida
pelo próprio `gh`/`git` quando necessário, não fica visível pra todo
processo filho que o agente rodar.

**Se preferir a conveniência do token em env var mesmo assim** (ex: scripts
automatizados que não conseguem fazer login interativo), o `.env.example`
ainda tem `GITHUB_TOKEN` comentado como opção — mas saiba que isso volta a
expor o valor pra qualquer subprocesso.

### Pacotes privados do GitHub Packages (`@nicbrasil` e outros escopos)

Diferente de `git`/`gh`, o **npm/pnpm não sabe usar a sessão do `gh`**
sozinho — ele precisa de um token no `.npmrc` do projeto:
```
@nicbrasil:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```
Em vez de manter `GITHUB_TOKEN` como env var permanente só pra isso, o
`.bashrc` do container já tem uma função que injeta o token **só durante o
`pnpm install`**, puxando ele da sessão do `gh` já autenticada:
```bash
pnpm install   # já funciona normal, o token é injetado e descartado automaticamente
```
Depois que o `pnpm install` termina, a env var não existe mais na sessão —
só existiu durante aquele processo específico. Pra conferir que funcionou:
```bash
type pnpm   # deve mostrar que "pnpm" é uma função, não o binário direto
```

## Bancos de dados e autenticação (MySQL, MongoDB, etcd, Keycloak)

Esses serviços vêm no mesmo `docker-compose.yml`, atrás de **profiles**
(`db` e `auth`). Duas formas de trabalhar com isso:

### Opção 1 — `--profile` manual
```bash
docker compose --profile db --profile auth up -d
```
Fica explícito toda vez que você sobe o ambiente, mas exige lembrar da flag.

### Opção 2 — `COMPOSE_PROFILES` no `.env` (recomendado se você quase
sempre usa os bancos)
Descomente no `.env`:
```bash
COMPOSE_PROFILES=db,auth
```
A partir daí, `docker compose up -d` sozinho já sobe tudo — dev-sandbox,
bancos e Keycloak — sem precisar da flag. É a mesma mecânica dos profiles
por baixo, só muda o padrão.

### Qual usar?

- **Se o dia a dia envolve banco quase sempre** (a maioria dos projetos
  NestJS/TypeORM vai precisar de MySQL, por exemplo): vale usar
  `COMPOSE_PROFILES` no `.env` — menos fricção, `docker compose up -d`
  já faz tudo.
- **Se você alterna bastante entre "só código" e "código + infra"**
  (ex: trabalha em scripts/libs isolados boa parte do tempo, só sobe banco
  quando for testar integração): fica melhor deixar sem `COMPOSE_PROFILES`
  e usar `--profile` manual quando precisar — evita ter bancos pesados
  rodando à toa consumindo RAM/CPU da máquina.

Dá pra misturar também: deixar `COMPOSE_PROFILES=db` fixo (bancos sempre
ativos) e usar `--profile auth` manual só quando for mexer com login/token
via Keycloak, por exemplo.

Todos ficam numa rede Docker interna (`devnet`, subnet `172.28.0.0/24`) junto
com o `dev-sandbox`. O agente acessa **pelo nome do serviço**, sem precisar
descobrir IP nem abrir porta no host:

| Serviço | Host (de dentro do dev-sandbox) | Credenciais (`.env`) |
|---|---|---|
| MySQL | `mysql:3306` | `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_DATABASE` |
| PostgreSQL | `postgres:5432` | `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` (ou use `$DATABASE_URL` já pronta) |
| MongoDB | `mongodb:27017` | `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` (ou use `$MONGO_URI` já pronta) |
| Redis | `redis:6379` | `REDIS_PASSWORD` (ou use `$REDIS_URL` já pronta) |
| RabbitMQ | `rabbitmq:5672` (painel: `localhost:15672`) | `RABBITMQ_USER` / `RABBITMQ_PASSWORD` (ou use `$RABBITMQ_URL` já pronta) |
| etcd | `etcd:2379` | sem auth (dev only — `ALLOW_NONE_AUTHENTICATION`) |
| Keycloak | `keycloak:8080` | `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` (banco próprio, separado do Postgres geral) |

Essas variáveis já são injetadas automaticamente no ambiente do `dev-sandbox`
(veja a seção `environment` do serviço no compose) — o agente pode simplesmente
ler `$MYSQL_HOST`, `$MONGO_URI`, `$KEYCLOAK_URL`, etc. em vez de você precisar
falar o endereço toda vez que pedir uma tarefa.

Exemplo de prompt pro agente:
> "Conecte no MySQL usando as variáveis de ambiente MYSQL_HOST/USER/PASSWORD
> e crie a tabela X"

**Por que essa é a abordagem certa** (em vez de instalar esses serviços
direto no host ou no próprio container do dev-sandbox):
- Isolamento: cada serviço no seu próprio container, com sua própria imagem
  oficial, sem poluir o ambiente de desenvolvimento.
- Dados persistem em volumes nomeados (`mysql-data`, `mongo-data`, etc.),
  sobrevivem a rebuild do dev-sandbox.
- Não passa pelo firewall de egress público — é tráfego interno Docker,
  só precisei liberar o subnet `172.28.0.0/24` no `init-firewall.sh`.
- `profiles` evita rodar bancos pesados quando você só quer codar sem eles.

**Keycloak em modo dev**: o `start-dev` é só pra desenvolvimento local —
não use essa config em produção (roda sem HTTPS, sem cluster). Se seu
projeto realmente precisa reproduzir produção, ajuste as env vars `KC_*`
conforme a documentação oficial do Keycloak.

Pra derrubar só os bancos, mantendo o dev-sandbox rodando:
```bash
docker compose --profile db --profile auth down
# (se estiver usando COMPOSE_PROFILES no .env, o "--profile" aqui é opcional)
```

## Permissão negada (EACCES) ao instalar dependências

Resolvido em duas camadas, funcionando juntas:

**1. Defesa principal — `HOST_UID`/`HOST_GID` no `.env`**
Se você alinhar esses valores com seu usuário real do host (`id -u` / `id -g`),
qualquer projeto que você clonar/criar normalmente já nasce pertencendo ao
UID certo — dentro do container isso já *é* o `node`, porque o UID bate.
Sem script, sem boot-time fix, é assim que deveria funcionar por padrão.

**2. Rede de segurança — `fix-permissions.sh` no boot**
Cobre os casos que fogem da defesa principal: projeto clonado com `sudo`,
copiado de outra máquina, extraído de um `.zip` que preservou UID de outro
lugar, etc. Ele roda como root (sudo restrito) uma vez a cada boot do
container e faz o `node` virar **dono de verdade** de tudo em `/workspace`:
```bash
find /workspace -xdev \( ! -user node -o ! -group node \) -exec chown node:node {} +
```
Só toca no que está com dono errado (não refaz o que já está certo), então
fica rápido nos boots depois do primeiro.

**Por que ownership de verdade (`chown`) em vez de ACL:** já que este é um
workspace pessoal seu, onde tudo que está ali é seu pra usar via `node`, não
faz muito sentido preservar a ownership original de quem criou o arquivo —
o ideal é o `node` simplesmente ser o dono, ponto. Isso também deixa
`ls -l` e outras ferramentas mostrando ownership consistente, em vez de
uma mistura de ACL por cima de dono "errado".

Pra conferir que funcionou:
```bash
docker exec -it dev-sandbox bash
ls -ln /workspace/nome-do-projeto | head   # dono deve aparecer como 1000
```



```bash
docker exec -it dev-sandbox bash
sudo iptables -L -v -n
nslookup dominio-que-falhou.com
```

Adicione o domínio faltante em `init-firewall.sh` no host, depois:
```bash
docker compose up -d --build   # rebuilda com o script atualizado
```