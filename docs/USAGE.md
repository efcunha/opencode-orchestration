# Uso do orquestrador no chat do opencode

Como iniciar, gerenciar e diagnosticar uma quest de dentro do opencode. Foco
no usuário humano — o que digitar, o que esperar, e as regras operacionais
que evitam as armadilhas conhecidas.

> **Idioma:** tambem disponivel em ingles ([`USAGE.en.md`](USAGE.en.md)).
> Detalhes internos do plugin em [`ARCHITECTURE.md`](ARCHITECTURE.md);
> troubleshooting em [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 1. Iniciando uma quest

A tool `quest` aceita quatro formas. Sem argumento nenhum, mostra ajuda.

```
quest()                  -> mostra ajuda e lista quests disponiveis
quest(file: "filename")  -> carrega de .agents/filename.yaml
quest(name: "Nome")      -> acha pelo campo `name:` (case-insensitive)
quest(schema: {...})     -> cria inline a partir de um schema
```

> **Importante:** Todos os parâmetros são nomeados. Argumentos posicionais
> não são suportados. Para passar a tarefa do usuário para a quest, sempre
> escreva `input: "..."` explicitamente:
>
> ```
> quest(file: "model-routed-dev", input: "Crie uma página HTML de Boas Vindas")
> ```
>
> Sem `input:`, o bloco Task mostrado a cada estágio fica vazio.
> O estágio plan tem fallback (lê do contexto da conversa), mas
> explícito é melhor.

### `quest()` — ajuda

Digite `quest()` no chat e o plugin responde com o uso, os diretorios
pesquisados, e os arquivos `.yaml` que encontrou. E a forma certa de
comecar se voce nao lembra o nome do arquivo.

### `quest(file: "filename")` — por arquivo

A forma mais comum. O plugin procura em **dois diretorios, nesta ordem**:

1. `<projeto>/.agents/` — quest especifica do projeto
2. `~/.config/opencode/agents/` — quests globais (vem do payload)

A primeira que casar ganha. Uma quest no projeto faz shadow de uma global
com mesmo nome — util para um repo customizar uma quest compartilhada
sem editar o global.

O `filename` pode ser passado com ou sem extensao:

```
quest(file: "routing-probe")       # tenta .yaml e .yml
quest(file: "routing-probe.yaml")  # explicito
```

Nome com `..` ou separadores e recusado (anti path-traversal).

### `quest(name: "Nome da Quest")` — por nome

Quando o projeto tem varios YAMLs e voce prefere nao lembrar o arquivo.
O plugin faz scan em todos os `.yaml` dos diretorios acima e compara
case-insensitive com o campo `name:` do YAML. Case unico e a primeira
casada vence.

### `quest(schema: {...})` — inline

Para quests one-shot que nao vale a pena versionar em arquivo. O schema
passa pela mesma validacao de campos que o arquivo. Util para experimentacao
ou quando o opencode esta gerando a quest dinamicamente.

## 2. Slash commands: `/quest`

Alem da tool `quest` (que **inicia**), existe um slash command `/quest`
que **gerencia** a quest ativa. Use no chat como qualquer outro slash
command do opencode.

| Comando | Efeito |
|---|---|
| `/quest` ou `/quest status` | Mostra estagio atual, dwell e status (idle/active). Equivalente a pedir status a qualquer momento. |
| `/quest pause` | Pausa o heartbeat e a dwell reminder. A quest fica congelada onde esta. |
| `/quest resume` | Retoma de onde parou. Re-arma heartbeat e dwell. |
| `/quest stop` | Encerra a quest e limpa o estado. Util se voce quer descartar e comecar do zero. |

Slash command desconhecido (ex.: `/quest restart`) gera toast
`Usage: /quest [status|pause|resume|stop]`.

## 3. Como uma quest executa — e o que voce ve

A quest NAO e uma chamada sincrona. O fluxo e:

1. Voce digita `quest(file: "...")` no chat.
2. O plugin carrega o YAML, valida referencias de modelo, arma o
   heartbeat, e mostra um toast `Quest started: "Nome"`.
3. O plugin entrega o **primeiro estagio** ao agente correspondente
   (`agent: build`, `agent: plan`, etc.) via `client.session.promptAsync`.
4. O modelo do estagio recebe a instrucao, executa, e quando termina
   chama a tool `quest_advance(stage: "proximo-id")` — **isso nao e
   coisa sua**, e o proprio modelo.
5. O plugin valida a transicao (`next` do YAML), troca o estado para o
   proximo estagio, e dispara o despacho dele.
6. Volta ao passo 3 ate o estagio chamar `quest_advance("done")`.
7. Final: toast `Quest complete: "Nome"`, estado zerado.

### Toasts que voce vera durante uma quest

| Momento | Toast |
|---|---|
| Inicio | `Quest started: "Nome"` |
| A cada ~30s (heartbeat) | `Quest: Nome \| Stage: id (i/n) \| elapsed \| status` |
| Dwell reminder (sem output por 90s) | Re-dispara o estagio atual |
| Plano stall (Plan Mode) | `Stage "X" stalled (Plan Mode?) — retry 1/2 on current agent` |
| Stall apos 2 retries | `Stage "X" stalled 2x — forcing TUI delivery` |
| Final | `Quest complete: "Nome"` |
| `/quest pause` | `Quest paused — "Nome" at stage X` |
| `/quest resume` | `Quest resumed — "Nome" at stage X` |
| `/quest stop` | `Quest stopped — "Nome"` |

### Heartbeat e dwell reminder

O heartbeat roda a cada ~30s com status do estagio (idle/active, dwell
remanescente). Util para saber se algo travou sem precisar abrir os logs.

A dwell reminder dispara se o modelo nao produz output por ~90s — o plugin
re-entrega o estagio (nao cria um novo). E diferente do stall por Plan Mode:
stall = turno fechou sem `quest_advance`; dwell = turno nao fechou.

## 4. Exemplo completo: ponta-a-ponta

Uma quest de **tres estagios** mostrando roteamento entre modelos, override
de modelo sem trocar de agente, transicoes controladas pelo proprio modelo
via `quest_advance`, e os toasts que voce vera durante a execucao. Esta
secao e a concretizacao das secoes 1 e 3 acima.

### 4.1 Definicao da quest

Crie `meu-projeto/.agents/add-feature.yaml`:

```yaml
kind: quest
name: Add Feature
description: "Plan, implement and verify a small feature end-to-end across three stages"

stages:
  - id: design
    description: "Stage 1 — plan the feature"
    agent: plan
    model: deepseek/deepseek-v4-pro
    instruction: |
      You are designing a small feature for the user's request at hand.
      Do not write any code. Output ONLY a short Markdown design with:
        - Goal (1 sentence)
        - Files to add/modify (paths)
        - Public API change (if any)
        - Test cases (3-5 bullets)
      Then call quest_advance("implement").
    checklist:
      - "Design emitted in the 4-bullet format"
      - "No code produced"
      - "quest_advance(\"implement\") called"
    next:
      proceed: implement

  - id: implement
    description: "Stage 2 — write the code"
    agent: build
    model: minimax-coding-plan/MiniMax-M3
    instruction: |
      You are implementing the design from the previous stage.
      Read the prior turn's design output and translate it into code.
      Use write/edit tools to create or modify the files exactly as designed.
      When done, list the files you changed and call quest_advance("verify").
    checklist:
      - "Files mentioned in the design were touched"
      - "quest_advance(\"verify\") called"
    next:
      proceed: verify

  - id: verify
    description: "Stage 3 — cheap verification on a different model"
    agent: build                          # keep build's write tools
    model: deepseek/deepseek-v4-flash    # but a cheap model
    instruction: |
      You are verifying the implementation from the previous stage.
      Read the design and the files written. Confirm each test case from
      the design is plausibly satisfied. Reply with one of:
        VERIFIED: <one-line summary>
      or
        BLOCKED: <reason + next step>
      Then call quest_advance("done").
    checklist:
      - "VERIFIED or BLOCKED emitted"
      - "quest_advance(\"done\") called"
    next:
      proceed: done
```

Os 3 estagios exercitam:

- Roteamento por agente (`plan` -> `build` -> `build`)
- Roteamento por modelo (DeepSeek Pro -> M3 -> DeepSeek Flash)
- **Override de modelo sem trocar de agente** (ultimo estagio: `agent: build`
  mas `model: deepseek-v4-flash`) — o plugin usa as ferramentas do agente
  declarado e so troca o modelo
- Transicoes controladas pelo modelo via `quest_advance`, nao por voce

### 4.2 Disparando

TUI persistente (recomendado):

```bash
cd meu-projeto
opencode
```

No prompt do TUI, com Tab confirmado em **Build**:

```
quest(file: "add-feature")
```

Headless:

```bash
opencode run --auto 'quest(file: "add-feature")'
```

### 4.3 O que voce vera — timeline de toasts

**Estagio `design`** (DeepSeek V4 Pro, agente `plan`):

| Quem | O que |
|---|---|
| Voce | Digita `quest(file: "add-feature")` |
| Plugin | Carrega YAML, valida referencias, toast `Quest started: "Add Feature"` |
| Plugin | Despacha a instrucao do estagio `design` para DeepSeek V4 Pro |
| DeepSeek | Le o pedido, produz design em 4 bullets, chama `quest_advance("implement")` |
| Plugin | Heartbeat: `Quest: Add Feature \| Stage: design (1/3) \| 0:08 \| 🟢 idle` |

**Estagio `implement`** (MiniMax M3, agente `build`):

| Quem | O que |
|---|---|
| Plugin | Ve a transicao, troca estado para `implement`, despacha para M3 |
| M3 | Le o design que DeepSeek acabou de escrever (contexto atravessa o salto — `agent: plan` -> `agent: build`), escreve os arquivos, lista diff, chama `quest_advance("verify")` |
| Plugin | Heartbeat: `Quest: Add Feature \| Stage: implement (2/3) \| 0:42 \| 🟢 idle` |

> O M3 escreve arquivos de verdade. O plugin usa as ferramentas do **agente**
> `build` (write/edit/bash) mesmo com override de modelo — e por isso que o
> estagio `verify` mantem `agent: build` mas troca o modelo.

**Estagio `verify`** (DeepSeek V4 Flash, agente `build`):

| Quem | O que |
|---|---|
| Plugin | Despacha para DeepSeek V4 Flash (sem trocar agente — `agent: build` continua valendo) |
| Flash | Le o design + os arquivos escritos, responde `VERIFIED: ...` ou `BLOCKED: ...`, chama `quest_advance("done")` |
| Plugin | Toast: `Quest complete: "Add Feature"` (variant info, 6000 ms) |

### 4.4 Inspecionando durante a execucao

A qualquer momento, no chat:

```
/quest status      # mostra: Quest: Add Feature | Stage: implement (2/3) | 0:42 | ⏳ dwell 50s → remind
/quest pause       # congela no meio
/quest resume      # retoma de onde parou
/quest stop        # aborta — esquece tudo
```

Para confirmar que o roteamento realmente acertou os modelos (sem confiar em
autorrelato), use o metadado de API:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1
# em outro terminal, com a quest rodando:
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

Voce vera tres linhas de `assistant`, uma por estagio, com `providerID/modelID`
trocando de `deepseek/...` para `minimax-coding-plan/...` e voltando para
`deepseek/...`. Evidencia real, nao autorrelato. Detalhe em
[`MEASUREMENTS.md`](MEASUREMENTS.md).

### 4.5 Adapte este exemplo

Pontos de extensao naturais:

- **Mais agentes**: adicione estagios com `agent: bugfix` (DeepSeek Pro) ou
  `agent: explore` (Flash) para tarefas especificas
- **Override agressivo de modelo**: troque `model` em qualquer estagio sem
  mexer no `agent`, para baratear enquanto mantem ferramentas
- **Schema inline**: substitua o YAML por `quest(schema: {...})` para
  prototipos rapidos
- **Mais estagios**: adicione um quarto estagio (ex.: `document` com
  `agent: general`) sem retrabalhar o resto

As quests reais `routing-probe` em `payload/agents/routing-probe.yaml` (dois
estagios, prova roteamento e contexto) e `override-probe.yaml` (um estagio,
prova override de modelo) sao templates minimas para seus proprios YAMLs.

## 5. Tres jeitos de disparar

### TUI persistente (recomendado)

Abre o TUI normalmente e digita `quest(file: "...")` no chat. Sessao
persistente, contexto vivo, recovery automatico em caso de Plan Mode.

```bash
opencode
# no prompt do TUI:
quest(file: "routing-probe")
```

### Headless one-shot

Para rodar em script ou CI sem manter o TUI aberto:

```bash
opencode run --auto 'quest(file: "routing-probe")'
```

Limitacao conhecida: o cliente `opencode run` pode sair antes do evento
`session.idle` que dispara o despacho do proximo estagio. Resultado: o
estagio enfileirado se perde em cerca de 1 de 3 execucoes. Ver
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) "O segundo estagio nunca
rodou".

### Headless contra servidor rodando

Combina automacao com sobrevivencia: o `opencode serve` fica no
background, e cada `opencode run --attach` se conecta e desconecta
sem matar o servidor.

```bash
# terminal 1 (longa-vida)
opencode serve --port 4599 --hostname 127.0.0.1

# terminal 2 (a cada execucao)
opencode run --attach http://127.0.0.1:4599 --dir <projeto> \
             --auto 'quest(file: "routing-probe")'
```

E o modo usado em [`MEASUREMENTS.md`](MEASUREMENTS.md) para reproduzir
os resultados de roteamento.

## 6. Regras operacionais

### Uma quest por vez

O estado da quest vive em **memoria do processo** do opencode, nao por
sessao. Duas quests concorrentes se dividem entre sessoes — uma fica
com o primeiro estagio, outra com o segundo. A sessao orfã reporta
`NO_CONTEXT` **corretamente** — ela nunca teve o estagio anterior.

Regra: **uma quest por vez**. Se voce precisa paralelizar, abra dois
processos opencode separados.

### TUI em Build antes de disparar

O TUI do opencode tem dois modos via Tab — **Plan** (read-only, modelo
so planeja) e **Build** (modelo pode usar ferramentas). Sao modos do
TUI, nao dos agentes `plan`/`build` da orquestracao — colisão de nome.

Se voce disparar uma quest com o TUI em **Plan**, o estagio roteado
recebe a instrucao mas nao pode chamar ferramentas, em particular
`quest_advance`. A quest trava em silencio.

**Auto-recovery existe** desde 2026-08-19: o plugin detecta o stall e
re-despacha ate 2 vezes, caindo para TUI injection no fim. Mas isso
introduz delay e toast de aviso. Para evitar: troque para Build (Tab)
antes de digitar `quest(...)`. Detalhe tecnico em
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) "O TUI travou em Plan Mode".

### Slash command vs tool

- `quest(...)` no chat = **iniciar** uma quest. Tool.
- `/quest ...` no chat = **gerenciar** a quest ativa. Slash command.

Nao confunda: `/quest status` nao inicia nada, so mostra status. E
`quest(file: "...")` nao pausa nem para nada — se ja existe quest
ativa, ela substitui.

### Quando desconfiar

- **Toast de aviso "stalled"**: o plugin esta tentando recuperar. Espere
  ~10s. Se cair no fallback de TUI injection, a quest continua com a
  ressalva de que o estagio rodou sem ferramentas.
- **Sessao para depois de um estagio com "queued" no output**: provavel
  perda de despacho headless. Ver [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
- **Dois estagios em sessoes diferentes**: estado global atropelado.
  Pare a segunda, deixe a primeira terminar.
- **Heartbeat para de aparecer por >2 minutos**: provavelmente travou.
  Tente `/quest status` para ver onde esta; `/quest stop` + redispatch
  e a saida pragmatica.

## 7. Workflow tipico

1. Abre o TUI: `opencode`.
2. Confirma que esta em Build (rodape).
3. Digita `quest(file: "minha-quest")`.
4. Acompanha pelos toasts (heartbeat a cada ~30s).
5. Se precisar pausar: `/quest pause`. Retomar: `/quest resume`.
6. Se algo claramente travou: `/quest stop`, investigar, recarregar
   com `quest(file: "minha-quest")`.
7. No final: toast de complete, estado limpo, pronto para a proxima.
