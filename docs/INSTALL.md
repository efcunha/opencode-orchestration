# Instalacao

Instalar a orquestracao multi-LLM numa maquina nova. O `payload/` e completo
(nao precisa de rede nem de remoto git) e portatil (substitui placeholders com
paths locais na instalacao).

> **Idioma:** tambem disponivel em ingles ([`INSTALL.en.md`](INSTALL.en.md)).

## 1. Pre-requisitos

O instalador aborta cedo se faltar o obrigatorio. Os quatro primeiros itens da
tabela sao bloqueantes (verificados em `scripts/Install-Orchestration.ps1:Test-Prerequisites`):
sem `node`, `npm`, `opencode` ou `git`, a instalacao nao prossegue. `pwsh` e
tratado por `scripts/install.js:findPwsh` com fallback para `powershell.exe`;
se nenhum dos dois estiver no PATH, `install.js` aborta antes de chamar o
PowerShell.

| Ferramenta | Para que | Verificado por | Bloqueante? |
|---|---|---|---|
| `node` 18+ | Runtime do opencode e dos MCPs em Node | `node -v` | Sim |
| `npm` 9+ | Instalacao global das deps MCP e deste pacote | `npm -v` | Sim |
| `opencode` | Ferramenta que consome a config (`opencode serve` / `opencode run` / TUI) | `opencode --version` | Sim |
| `git` | Clone de skills externas em `scripts/install-git-repos.json` | `git --version` | Sim |
| `pwsh` (PowerShell 7+) | Instalador, verificador, syncer | `pwsh -v` | Sim (cai em `powershell.exe`) |

Opcionais, ausencia nao bloqueia a instalacao:

| Ferramenta | O que perde sem ela |
|---|---|
| `uv` / `uvx` | LSP `python` (`pyright-langserver`) e `browser-harness` (controle de browser via CDP — ver secao 9.1) |
| `ollama` | Embeddings locais para OpenCodeRAG (auto-instalado se ausente — ver secao 9) |

## 2. Variaveis de ambiente

O instalador **nao grava** variaveis de ambiente, de proposito: gravar por
script faria a chave passar por linha de comando e por historico de shell. Ele
checa presenca e reporta o que falta, sem nunca imprimir valor.

Obrigatorias — sem elas o provider carrega mas falha na primeira chamada:

| Variavel | Provider |
|---|---|
| `MINIMAX_API_KEY` | `minimax-coding-plan` (MiniMax M3) |
| `DEEPSEEK_API_KEY` | `deepseek` (V4 Pro e V4 Flash) |

Opcionais, usadas pelos MCP (nenhuma no momento):

Persistir no escopo de usuario no Windows:

```powershell
[Environment]::SetEnvironmentVariable('MINIMAX_API_KEY',  '<valor>', 'User')
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', '<valor>', 'User')
```

Abra um shell novo depois. Processos ja rodando nao veem variavel definida
depois de terem iniciado.

## 3. Instalar via npm

```bash
git clone <este-repo>
cd opencode-orchestration
npm install -g .
```

O `postinstall` deste pacote executa `scripts/install.js` em modo seguro:
instala dependencias npm, mas nao altera a configuracao global do OpenCode nem
chama PowerShell. A instalacao efetiva exige acao explicita:

```bash
npm run install:force
# ou, depois da instalacao global:
opencode-orchestration --force
```

A acao efetiva detecta `npm root -g`, `$USERPROFILE` e `$HOME`. Depois o
PowerShell instala deps MCP faltantes, renderiza templates, faz backup do
destino existente, copia payload, tenta criar symlinks e valida com
`Test-Orchestration.ps1`.

Instalar **local** (sem `-g`) tambem funciona:

```bash
npm install
.\scripts\Install-Orchestration.ps1 -Force
```

A diferenca e onde ficam as deps npm: em `-g` vao para o prefix global do
npm (`%APPDATA%\npm\node_modules` ou `~/.npm-global`), em local vao para
`node_modules/` deste repo. O resto do fluxo e identico.

## 4. Instalacao manual (sem npm)

Se preferir nao usar npm:

```powershell
cd D:\opencode-orchestration
.\scripts\Install-Orchestration.ps1           # simula, nao escreve nada
.\scripts\Install-Orchestration.ps1 -Force    # efetiva, com backup antes
.\scripts\Test-Orchestration.ps1              # verifica ponta a ponta
```

O instalador detecta os caminhos locais nos mesmos lugares onde o `install.js`
manda do lado dele, e cai nas mesmas variaveis `ORCH_*` quando elas estao
definidas.

### Sobrescrever caminhos detectados

Se a deteccao automatica nao bater o que voce quer:

```powershell
$env:ORCH_NPM_GLOBAL_NODE_MODULES = 'C:\meu\node\node_modules'
$env:ORCH_USER_HOME               = 'C:\Users\fulano'
$env:ORCH_USER_AGENTS             = 'C:\Users\fulano\.agents'
.\scripts\Install-Orchestration.ps1 -Force
```

O que o `ORCH_*` nao substitui e resolvido pelo caminho de deteccao do
instalador.

### Instalacao em outro destino

```powershell
.\scripts\Install-Orchestration.ps1 -Force -TargetRoot D:\tmp\oc-teste
```

## 5. Verificar

```powershell
.\scripts\Test-Orchestration.ps1
```

Sai com codigo 0 se tudo passar, 1 em qualquer falha obrigatoria. O que ele
checa:

- `opencode.jsonc` existe e renderizou sem placeholders restantes (`{{...}}`
  na saida indica install parcial).
- Plugin de quests e quests globais presentes.
- Variaveis de ambiente presentes (obrigatorias como falha, opcionais como
  aviso).
- Cada MCP declarado com `command: ["node", "<path>"]` aponta para binario
  que existe no disco (erro se instalar sem `npm install -g` primeiro).
- `opencode models` rodado de um diretorio vazio — isso e o ponto: prova que
  a resolucao vem da config global e nao de algum `opencode.json` de projeto
  que estivesse no diretorio atual.
- O whitelist declarado na config corresponde exatamente aos modelos que o
  opencode resolve, em ambas as direcoes.
- Cada referencia de modelo — `model`, `small_model`, `agent.*.model` e o
  `model:` de cada estagio de quest — aponta para um modelo que existe.
- Chamada real de API ao DeepSeek e ao MiniMax.
- Ollama instalado, servico respondendo na porta 11434, modelo
  `nomic-embed-text:latest` disponivel localmente e health check de embedding
  (tudo como aviso nao-bloqueante).
- Browser Harness: `uv` no PATH, `browser-harness` instalado, skill
  registrada em `skills/browser-harness/SKILL.md`, e `--doctor` reportando
  Chrome + daemon OK (tudo como aviso nao-bloqueante).

Sem rede:

```powershell
.\scripts\Test-Orchestration.ps1 -SkipNetwork
```

A checagem de referencias de modelo merecia uma nota. Ela existe porque o
`small_model` global apontou para `deepseek-v4-flash-free`, um modelo que nunca
existiu na API do DeepSeek. Referencia invalida **nao** falha ao carregar a
config: falha na primeira chamada, em silencio, e o slot afetado era o de maior
frequencia — titulo de sessao, sumarizacao, compaction.

## 6. Adicionar um novo MCP (que precisa de binario npm)

1. Adicione o pacote em **dois** lugares:
   - `package.json` `dependencies` — para `npm install -g .` fazer o trabalho.
   - `scripts/mcp-packages.json` — para o PowerShell checar/instalar no fluxo
     direto (`Install-Orchestration.ps1 -Force` sem npm).
2. Adicione a entrada `mcp.<nome>` em `payload/opencode.jsonc` com o caminho
   `node {{nodeModules}}/<pkg>/...`.
3. O instalador cuida do resto — `Install-Orchestration.ps1 -Force` vai
     conferir, instalar o que faltar e re-renderizar o template.

Se o MCP **nao** precisa de binario (e remoto, ou usa `npx`/`uvx`/`docker`),
so editar `opencode.jsonc`.

## 7. Adicionar uma skill de source externa (git)

1. Adicione uma entrada em `scripts/install-git-repos.json`:
   ```json
   {
     "url": "https://github.com/user/skill.git",
     "ref": "main",
     "target": "{{userAgents}}/skills/<name>",
     "depth": 1,
     "why": "Skill externa para..."
   }
   ```
2. Apos clonar no diretorio alvo, crie ou aponte o symlink esperado em
   `payload-symlinks.template.json` (se quiser o symlink na config global).
3. `Install-Orchestration.ps1 -Force` faz o clone quando faltando. Repos ja
   presentes nao sao sobrescritos — atualize com `git pull` na mao.

## 8. Trocar providers de LLM (Claude, GPT, Gemini, etc.)

LLM/providers nao sao hardcoded no template. O default (MiniMax + DeepSeek +
Ollama) vem de `scripts/llm-defaults.json`. Para customizar:

1. Copie o exemplo para a sua config:
   ```powershell
   Copy-Item scripts/llm-providers.example.json config/llm-providers.json
   ```
2. Edite `config/llm-providers.json`:
   - `enabled_providers`: lista de provedores ativos
   - `model` / `small_model`: defaults
   - `agents.<slot>`: mapeamento slot -> modelo (plan, build, review, bugfix,
     general, explore). Cada agente aceita `model`, `temperature`, `description`.
   - `providers.<nome>`: bloco completo de cada provider (npm, options,
     whitelist, models com limit)
3. Defina `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / etc. como variavel de
   ambiente (no escopo User, com `[Environment]::SetEnvironmentVariable`)
4. Rode `.\scripts\Install-Orchestration.ps1 -Force`

O arquivo de override **substitui** os defaults integralmente. Liste
todos os providers que quer usar — se voce nao listar um, ele some da config
renderizada. Esta e uma escolha deliberada: merge parcial leva a inconsistencias
(o agente `plan` espera um modelo que o `provider` nao tem, e o resultado
silencioso e um stage quebrado).

O exemplo em `scripts/llm-providers.example.json` mostra Anthropic + MiniMax
+ Ollama. Ele e a fonte de verdade para o schema. `scripts/llm-defaults.json`
tambem e fonte: se faltar um campo no seu override, copie de la.

## 9. Ollama + OpenCodeRAG (auto-instalado)

O instalador cuida automaticamente do Ollama e do modelo de embedding
necessario para o `opencode-rag-plugin` funcionar. O passo roda entre os
pre-requisitos e a auto-descoberta de modelos (step 0.3 no
`Install-Orchestration.ps1`) e **nao bloqueia** a instalacao se falhar.

O que acontece com `-Force`:

1. **Ollama ausente?** Instala silenciosamente via script oficial
   (`irm https://ollama.com/install.ps1 | iex`). Se o script falhar, faz
   fallback para download direto do `OllamaSetup.exe` com flags
   `/VERYSILENT /NORESTART /SP-`.
2. **Servico parado?** Inicia `ollama serve` em background e aguarda ate
   120s pela porta 11434 responder.
3. **Modelo `nomic-embed-text:latest` ausente?** Executa
   `ollama pull nomic-embed-text:latest` (~274 MB na primeira vez).
4. **Health check.** Envia um embedding de teste para
   `http://localhost:11434/api/embeddings` e valida que o vetor retornado
   tem dimensao > 0.

Se qualquer passo falhar, o instalador imprime instrucoes manuais e segue
com o resto da orquestracao normalmente.

### Rodar manualmente (se o auto nao funcionou)

```powershell
# Instalar Ollama
irm https://ollama.com/install.ps1 | iex

# Iniciar servico (se nao subiu automaticamente)
ollama serve

# Puxar modelo de embedding (em outro terminal)
ollama pull nomic-embed-text:latest

# Verificar
ollama list
```

### Pular Ollama na instalacao

Se voce nao pretende usar OpenCodeRAG e quer evitar o download:

```powershell
# Chamar Install-Ollama.ps1 diretamente com -SkipInstall
.\scripts\Install-Ollama.ps1 -Force -SkipInstall
```

Ou simplesmente remover `ollama` de `enabled_providers` no
`config/llm-providers.json` — o instalador so tenta instalar Ollama se ele
consta como provider no manifesto ativo.

### Trocar o modelo de embedding

```powershell
.\scripts\Install-Ollama.ps1 -Force -ModelName "mxbai-embed-large:latest"
```

Lembre de atualizar o whitelist do provider `ollama` em
`config/llm-providers.json` para refletir o novo modelo.

## 9.1. Browser Harness (controle de browser via CDP)

O instalador cuida automaticamente do [browser-harness](https://github.com/browser-use/browser-harness),
uma CLI que conecta o LLM diretamente ao browser real do usuario via Chrome
DevTools Protocol. O passo roda entre o Ollama e a auto-descoberta de modelos
(step 0.4 no `Install-Orchestration.ps1`) e **nao bloqueia** a instalacao se
falhar.

**Requer:** `uv` (Python package manager) no PATH.

O que acontece com `-Force`:

1. **`uv` ausente?** Reporta aviso e pula. Instale com:
   `irm https://astral.sh/uv/install.ps1 | iex`
2. **Instala/atualiza** via `uv tool install --python 3.12 --upgrade --force browser-harness`.
3. **Registra a skill** executando `browser-harness skill` e gravando o
   resultado em `~/.config/opencode/skills/browser-harness/SKILL.md`.
4. **Desabilita recordings** (privacidade por default).
5. **Desabilita telemetria**.

Se qualquer passo falhar, o instalador imprime instrucoes manuais e segue
com o resto da orquestracao normalmente.

### Rodar manualmente (se o auto nao funcionou)

```powershell
# Instalar uv (se ausente)
irm https://astral.sh/uv/install.ps1 | iex

# Instalar browser-harness
uv tool install --python 3.12 --upgrade --force browser-harness

# Registrar skill
New-Item -ItemType Directory -Path "$env:USERPROFILE\.config\opencode\skills\browser-harness" -Force
browser-harness skill > "$env:USERPROFILE\.config\opencode\skills\browser-harness\SKILL.md"

# Testar conexao (Chrome precisa estar aberto com remote debugging)
browser-harness --doctor
```

### Habilitar Chrome para controle remoto

1. Abra `chrome://inspect/#remote-debugging` no Chrome.
2. Marque o checkbox "Allow remote debugging for this browser instance".
3. Teste: `browser-harness <<'PY'` `print(page_info())` `PY`

### Pular browser-harness na instalacao

Se voce nao pretende usar controle de browser e quer evitar a instalacao:
nao e necessario nenhuma acao — se `uv` nao estiver no PATH, o passo e
pulado automaticamente sem bloquear nada.

## 10. Dependencias que a instalacao nao resolve

**Symlinks.** `payload-symlinks.template.json` lista os links que a configuracao
espera. Recria-los no Windows exige Developer Mode ou shell elevado, o que nao se
pode assumir numa maquina nova, entao o instalador tenta criar e reporta em vez
de fingir que resolveu. Hoje ha dois:
- `skills/archify` -> `~/.agents/skills/archify`
- `skills/browser-harness` -> `~/.agents/skills/browser-harness`

**Plugin de quests como fonte.** O payload traz `plugins/opencode-quests.ts`, o
arquivo achatado que o opencode carrega — autocontido, suficiente para a
orquestracao funcionar. O diretorio de fonte `plugins/opencode-quests/` **nao**
vem: vive em um repositorio interno separado (upstream
[lirrensi/opencode-quests](https://github.com/lirrensi/opencode-quests) com
patches locais na branch `fork/stage-routing`). So e necessario para desenvolver
o plugin, nao para usa-lo.

**Skills locais.** Cada skill global em `payload/skills/` deve estar tambem em
`~/.agents/skills/` para os symlinks resolverem. O instalador nao mexe em
`~/.agents/`.

## 11. Depois de instalar

Confirme que o roteamento por estagio chega ao modelo certo, em vez de
confiar na configuracao:

```bash
opencode
# no TUI:
quest(file: "routing-probe")
```

O probe roda dois estagios em modelos diferentes e o segundo repete um token
que o primeiro inventou. Como conferir o modelo real por metadado de API, e nao
pelo que o modelo diz de si: [`MEASUREMENTS.md`](MEASUREMENTS.md).

Para o guia completo de uso (modos de `quest(...)`, slash command `/quest`,
regras operacionais, tres jeitos de disparar), ver
[`docs/USAGE.md`](docs/USAGE.md).

Rode uma quest por vez. O plugin mantém uma quest ativa por processo e registra
o `sessionID` proprietário: outra sessão não pode assumir nem corromper o
runtime, mas o processo ainda não oferece quests concorrentes independentes.
Para paralelizar, use processos opencode separados. Detalhe em
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 12. Desinstalar

```bash
npm uninstall -g opencode-orchestration
```

O npm remove as deps npm globais. O `~/.config/opencode` continua com a config
que o instalador escreveu — para limpar manualmente, apague a pasta (ou use
o backup em `<repo>/_backup-<timestamp>/` deste repo como comparacao).

Para reinstalar do zero depois de desinstalar:

```bash
git clone <este-repo>
cd opencode-orchestration
npm install -g .
```
