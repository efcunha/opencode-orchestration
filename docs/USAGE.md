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

## 4. Tres jeitos de disparar

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

## 5. Regras operacionais

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

## 6. Workflow tipico

1. Abre o TUI: `opencode`.
2. Confirma que esta em Build (rodape).
3. Digita `quest(file: "minha-quest")`.
4. Acompanha pelos toasts (heartbeat a cada ~30s).
5. Se precisar pausar: `/quest pause`. Retomar: `/quest resume`.
6. Se algo claramente travou: `/quest stop`, investigar, recarregar
   com `quest(file: "minha-quest")`.
7. No final: toast de complete, estado limpo, pronto para a proxima.
