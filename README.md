# opencode-orchestration

Pacote npm instalavel da orquestracao multi-LLM do opencode: Exemplo **MiniMax M3**
para implementacao, **DeepSeek V4 Pro** para planejamento e diagnostico,
**DeepSeek V4 Flash** para revisao e subagentes — com roteamento por estagio de
quest, medido e verificavel.

> **Idioma:** tambem disponivel em ingles ([`README.en.md`](README.en.md)).

A configuracao e portatil. `payload/opencode.jsonc` e um template com placeholders
`{{nodeModules}}`, `{{userHome}}` e `{{userAgents}}` que o instalador resolve
para paths locais na primeira execucao. Nenhum caminho hardcoded de maquina
sobrevive entre instalacoes.

## Quickstart

### Instalar (uma vez por maquina)

Requer Node 18+, npm 9+ e PowerShell 7+ (`pwsh`) no PATH.

```bash
git clone <este-repo>
cd opencode-orchestration
npm install -g .
```

O comando faz, em ordem:

1. Instala as dependencias MCP declaradas em `dependencies` do `package.json`
   (`@modelcontextprotocol/server-memory`, `server-sequential-thinking`) e as
   `optionalDependencies` (hoje: `opencode-rag-plugin`, RAG semantico
   local-first — Ollama + `nomic-embed-text` sao auto-instalados).
2. Dispara o `postinstall`, que executa `scripts/install.js`.
3. `install.js` detecta `npm root -g`, `$USERPROFILE` e `$HOME`, e chama o
   `Install-Orchestration.ps1 -Force`.
4. O PowerShell renderiza o template `opencode.jsonc` com os paths locais,
   instala MCPs npm faltantes, copia o payload para `~/.config/opencode` e
   roda `Test-Orchestration.ps1`.

Para instalar **localmente** (sem `-g`):

```bash
npm install
.\scripts\Install-Orchestration.ps1 -Force
```

Para apenas verificar:

```bash
npm run verify         # offline
npm run verify:net     # com teste de API
```

Para simular sem escrever nada:

```powershell
.\scripts\Install-Orchestration.ps1
```

## O que o instalador faz em cada maquina

| Etapa | Como |
|---|---|
| Detectar `npm root -g` | `npm root -g` quando nao vem em `ORCH_NPM_GLOBAL_NODE_MODULES` |
| Detectar `$USERPROFILE` | env nativo do processo |
| Detectar `~/.agents` | `$USERPROFILE/.agents` ou `$HOME/.agents` |
| Instalar MCPs npm faltantes | `npm install -g <pkg>` por item em `scripts/mcp-packages.json` |
| Clonar skills de sources externas | `git clone --depth 1` por item em `scripts/install-git-repos.json` |
| Instalar Ollama + modelo embedding | Auto-instala Ollama se ausente, puxa `nomic-embed-text:latest` (non-blocking) |
| Renderizar `opencode.jsonc` | substituicao de `{{nodeModules}}`, `{{userHome}}`, `{{userAgents}}` |
| Renderizar symlinks | `payload-symlinks.template.json` -> `~/.config/opencode/skills/<name>` |
| Copiar payload | de `payload/` para `~/.config/opencode/` (com backup antes) |
| Verificar | `Test-Orchestration.ps1` (sai 1 em falha) |

## O que esta aqui

| Caminho | O que e |
|---|---|
| `payload/opencode.jsonc` | Config global — providers, agentes, MCPs. TEMPLATE: placeholders `{{...}}` |
| `payload-symlinks.template.json` | Lista os symlinks esperados com `targetTemplate` |
| `payload/agents/*.yaml` | Quests globais com roteamento por estagio |
| `payload/plugins/*.ts` | Plugin de quests e crg-plugin (artefatos achatados) |
| `payload/skills/` | Skills globais carregadas pelo opencode (`archify`, `find-skills`, `form-browser-validation`, `igniter`, `language`, `post-change-validation`, `trash`) |
| `payload/mcp-docs/` | Documentacao de como invocar MCP servers via `mavis mcp call` (referencia, nao e carregada como skill) |
| `scripts/Install-Orchestration.ps1` | Instala: detecta paths, instala MCPs, renderiza templates, copia, verifica |
| `scripts/Install-Ollama.ps1` | Instala Ollama silenciosamente, puxa `nomic-embed-text:latest`, valida embedding |
| `scripts/Test-Orchestration.ps1` | Verificacao independente, sai 1 em falha. Serve de gate em CI |
| `scripts/Sync-Payload.ps1` | Compara o payload contra o destino renderizado (`-Check` sai 1 em divergencia) |
| `scripts/install.js` | Entry point do npm — detecta paths locais e chama PowerShell |
| `scripts/setup.js` | Bin: `opencode-orchestration` ou `setup-orchestration` |
| `scripts/mcp-packages.json` | Manifesto de pacotes npm que o instalador instala globalmente |
| `scripts/install-git-repos.json` | Manifesto de repos git clonados na instalacao (skills de sources externas) |
| `docs/` | Instalacao, arquitetura, medicoes e troubleshooting |

## Variaveis de template

| Placeholder | Resolve para | Origem |
|---|---|---|
| `{{nodeModules}}` | Caminho global de `node_modules` | `npm root -g` |
| `{{userHome}}` | Diretorio do usuario | `$env:USERPROFILE` ou `$env:HOME` |
| `{{userAgents}}` | `~/.agents` | derivado de `{{userHome}}` |
| `{{enabledProvidersList}}`, `{{modelDefault}}`, `{{smallModelDefault}}` | Providers/llm | `scripts/llm-defaults.json` ou override `config/llm-providers.json` |
| `{{modelAgent<Slot>}}`, `{{tempAgent<Slot>}}`, `{{descAgent<Slot>}}` | Por slot de agente | mesma fonte |
| `{{providersBlock}}` | Bloco JSON completo do `provider` | mesma fonte |

LLMs/providers nao sao hardcoded: o default vem de `scripts/llm-defaults.json`
e qualquer um pode copiar `scripts/llm-providers.example.json` para
`config/llm-providers.json` (gitignored) e customizar. Trocar de MiniMax para
Anthropic, adicionar GPT, mudar temperaturas por agente — tudo via esse arquivo.
Ver [`docs/INSTALL.md`](docs/INSTALL.md) secao 8.

Adicionar um placeholder novo: extensao em `scripts/Install-Orchestration.ps1:Resolve-Paths`
ou `Resolve-LlmConfig` e uso direto no template.

### Auto-descoberta de providers/models

O instalador roda `opencode models --verbose` em diretorio vazio (para
garantir que a config resolvida vem do `~/.config/opencode/opencode.jsonc`
global) e descobre exatamente os models que o opencode local tem
configurados. O resultado aparece no relatorio inicial da instalacao, e
valida o `scripts/llm-defaults.json` ou `config/llm-providers.json` contra
o que foi descoberto — models referenciados que nao foram descobertos viram
warnings (credencial expirada? provider nao configurado?).

Quando rodar `npm install -g .` em uma maquina nova **e** o shell for
interativo (TTY) **e** ainda nao existir `config/llm-providers.json`, o
instalador dispara o **wizard** (`scripts/wizard.js`):

```
$ npm install -g .
[wizard] descobrindo models que o opencode tem configurados...
[wizard] 3 model(s) de chat descoberto(s):
  opencode/gpt-5             - GPT-5 (OpenCode Zen)
  opencode/claude-sonnet-4-5 - Claude Sonnet 4.5 (OpenCode Zen)
  opencode/o3-mini           - o3-mini (OpenCode Zen)

  Slot: plan (planejamento, arquitetura e reproducao de defeito)
  Models disponiveis:
     1. opencode/gpt-5             GPT-5   [sem key]
     2. opencode/claude-sonnet-4-5 Claude Sonnet 4.5 [sem key]
     3. opencode/o3-mini           o3-mini [sem key]
     0. (pular)
  Escolha [1-3 ou 0] [default: 1]:
```

O usuario responde 9 vezes (6 slots + model default + small model + s/n para
confirmar), e o wizard gera `config/llm-providers.json` com:

- `enabled_providers` derivado do que foi escolhido
- Bloco `provider.<name>` com `npm`, `options.baseURL`, `options.apiKey`
  apontando para o env var que `opencode providers list` reportou
- Bloco `models.<id>` com `name`, `limit.context`, `limit.output` (do
  `models.dev`)
- Mapeamento dos 6 slots (plan/build/review/bugfix/general/explore) para
  os models escolhidos

O wizard configura **6 slots de agente** (plan, build, review, bugfix, general,
explore). A quest `model-routed-dev` usa **3 deles** (plan, build, review).
Os slots restantes servem outras quests, delegação para subagentes, e troca
direta de agente no TUI. Atribuir o mesmo modelo a múltiplos slots é válido
se você tem poucos providers — o orquestrador funciona independentemente.

A partir dai o instalador continua com `-Force` automaticamente. Funciona
para qualquer maquina onde o opencode tenha **qualquer** provider configurado
(OpenCode Zen, Anthropic, OpenRouter, Cloudflare, MiniMax, etc.).

Para pular o wizard (instalacao silenciosa / CI): copie
`scripts/llm-providers.example.json` para `config/llm-providers.json` antes
de rodar `npm install`. Para rodar o wizard manualmente a qualquer hora:

```bash
node scripts/wizard.js --output config/llm-providers.json --force
```

Se o stdin nao for TTY (CI, `npm install -g`, redirecionamentos), o wizard
nao roda — instalacao segue com defaults. Deliberado: a instalacao padrao
tem que ser nao-interativa.

## Estado medido

Verificado em 2026-08-18 por metadado de API (`providerID`/`modelID` por
mensagem), nao por autorrelato do modelo:

- Roteamento por estagio acertou o modelo alvo em **5 de 5** rodadas.
- Contexto sobreviveu ao salto entre modelos em **5 de 5**.
- O `model` do estagio sobrepoe o modelo declarado no agente.

Metodo, sessoes e os falsos negativos que o instrumento produzia antes de ser
corrigido: [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md).

Limitações conhecidas do plugin de quests — estado global ao processo e
possível perda de despacho em headless — estão em
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md). O watchdog recupera
estágios travados em Plan Mode; o modo TUI persistente continua recomendado.
Texto entre crases em instruções é preservado literalmente e nunca é executado
pelo plugin.

## Leitura

| Documento | Quando |
|---|---|
| [`docs/INSTALL.md`](docs/INSTALL.md) | Instalar / reinstalar / desinstalar |
| [`docs/USAGE.md`](docs/USAGE.md) | Usar o orquestrador no chat: `quest(...)`, `/quest`, regras operacionais |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Entender como o roteamento funciona antes de mexer |
| [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md) | Conferir a evidencia em vez de acreditar |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Algo nao roteou, ou um estagio nao rodou |
