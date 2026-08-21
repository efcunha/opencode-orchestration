# Arquitetura

Como o roteamento multi-LLM funciona de fato, e por que cada peça está onde
está. Leia antes de mexer na configuração.

> **Idioma:** tambem disponivel em ingles ([`ARCHITECTURE.en.md`](ARCHITECTURE.en.md)).

## As três camadas

```
opencode.jsonc (global, ~/.config/opencode)
    providers  ->  quais modelos existem
    agents     ->  qual modelo cada papel usa
    model / small_model  ->  defaults
        |
        v
opencode.json (por projeto, opcional)
    overrides locais de mcp, lsp, plugin, skills
        |
        v
quest YAML (.agents/ do projeto, ou agents/ global)
    stage.agent + stage.model  ->  sobrepõem por estágio
```

Precedência do opencode: **user < workspace**. A config do projeto sobrepõe a
global. É por isso que providers e agentes saíram dos projetos: enquanto
estavam lá, cada repo redefinia o que `plan` e `build` significavam.

`enabled_providers` merece atenção porque o comportamento não é intuitivo: é
uma allowlist, e o projeto sobrepõe a global. Um provider definido globalmente
mas fora do `enabled_providers` do projeto fica **definido e filtrado** — os
modelos simplesmente não aparecem, sem erro. Em uma config de projeto que
declare `enabled_providers` sem incluir `deepseek`, nenhum `deepseek/*` aparece.

## Os slots de agente

| Slot | Modelo | Natureza |
|---|---|---|
| `plan` | `deepseek/deepseek-v4-pro` | Nativo, alternável com Tab no TUI |
| `build` | `minimax-coding-plan/MiniMax-M3` | Nativo, alternável com Tab |
| `review` | `deepseek/deepseek-v4-flash` | Customizado, só roda se invocado |
| `bugfix` | `deepseek/deepseek-v4-pro` | Customizado |
| `general` | `deepseek/deepseek-v4-flash` | Subagente — delegação |
| `explore` | `deepseek/deepseek-v4-flash` | Subagente — delegação |

`plan` e `build` são slots **nativos** do opencode. Sobrescrever esses nomes
reconfigura os embutidos, não cria agentes novos.

`general` e `explore` são slots de subagente. Sem `model` declarado eles herdam
o default da raiz, o que fazia toda delegação — exploração de código, research
amplo — ir para o MiniMax M3. Apontá-los para o Flash é o único roteamento
verdadeiramente automático que existe aqui: o agente primário decide delegar, e
o slot decide o modelo. Na prática disparam pouco, porque o M3 rodando como
`build` raramente delega.

`review` está apontado para o Flash e fica ocioso. Isso é deliberado, não
esquecimento — ver a seção sobre revisão abaixo.

## Roteamento por estágio de quest

O plugin de quests aceita `agent` e `model` por estágio:

```yaml
stages:
  - id: plan
    agent: plan
    model: deepseek/deepseek-v4-pro
  - id: build
    agent: build
    model: minimax-coding-plan/MiniMax-M3
  - id: evidence
    agent: build                      # ferramentas de escrita do slot build
    model: deepseek/deepseek-v4-flash # mas modelo barato
```

`model` precisa ter a forma `providerID/modelID` e é validado na carga da
quest. Referência malformada faz a quest falhar ao carregar, com erro explícito,
em vez de ser descartada em silêncio.

**O `model` do estágio sobrepõe o modelo do agente.** Medido pela quest
`override-probe`: `agent: build`, cujo modelo configurado é o M3, junto com
`model: deepseek/deepseek-v4-flash`, foi servido pelo Flash. É o que permite ao
estágio `evidence` trocar de modelo sem trocar de agente — trocar o agente
custaria as ferramentas de escrita e o estágio não conseguiria criar o arquivo.

### Como o despacho acontece

O plugin chama `client.session.promptAsync` com `agent` e `model` no corpo,
usando o `sessionID` obtido do `ToolContext`. O despacho é **diferido para o
evento `session.idle`**: o prompt do estágio só é entregue depois que o turno
atual fecha.

Esse diferimento explica a limitação de headless: `opencode run` pode sair
antes de `session.idle`, perdendo o estágio enfileirado em parte das sessões.
Em TUI persistente isso é menos provável. O watchdog detecta estágio sem
`quest_advance`, tenta até dois redispatches no `agent`/`model` declarado e,
se falhar, marca a quest como `blocked` — sem fallback silencioso para o modo
atual do TUI. `DWELL_MS` e `HEARTBEAT_MS` são atualmente 10 segundos. Cada
estágio também tem timeout padrão de 300 segundos (configurável no YAML); o
estouro preserva a quest como `timed_out` para diagnóstico. Texto entre crases
é transportado literalmente; o plugin não executa Markdown como shell.

### Contexto atravessa o salto

O estágio destino **vê** a conversa dos estágios anteriores. Medido em 5 de 5
rodadas: o segundo estágio citou verbatim um token que o primeiro inventou em
runtime e que não existe em disco nenhum.

Isso é contraintuitivo o suficiente para ter produzido dois falsos negativos
antes de o instrumento ser corrigido — o modelo citava o token no próprio
raciocínio e ainda assim declarava `NO_CONTEXT`. Detalhe em
[`MEASUREMENTS.md`](MEASUREMENTS.md).

Consequência de design: não é preciso passar estado entre estágios por arquivo
para que o próximo estágio *entenda* o anterior.

### Por que revisão roteada não é revisão independente

O `model-routed-dev` roteia o estágio `review` para DeepSeek V4 Flash e o
`handoff` para o mesmo slot. Isso melhora separação de modelo, mas não cria
fronteira de segurança nem revisão independente: o contexto anterior continua
visível na mesma sessão. Para aprovação independente, o Kiro ou outro processo
precisa reler o diff e rerodar as validações.

## O plugin tem um repositório próprio

O código-fonte do plugin vive em um repositório interno separado
(lirrensi/opencode-quests como upstream, com patches de roteamento na branch
local `fork/stage-routing`). Esse repositório não é este repo de config e nem
é gitlink — tem história própria e fica fora daqui. Rastreá-lo aqui criaria um
gitlink para um commit que nenhum remoto publicado tem.

O artefato que o opencode carrega é o **arquivo achatado**
`plugins/opencode-quests.ts`. Esse arquivo é versionado **neste** repo e é o
único que precisa estar presente para a orquestração funcionar — ele é
autocontido.

Consequência prática: alterar o plugin é editar `plugins/opencode-quests.ts`
direto aqui, commitar e rodar `.\scripts\Sync-Payload.ps1 -Check` antes do
push. O repositório de fonte só é necessário para desenvolver o plugin a partir
do upstream; para usar, este repo basta.

## Estado da quest e isolamento de sessão

O plugin mantém um único runtime de quest em memória por processo, mas esse
runtime agora registra o `sessionID` proprietário. Operações (`quest_advance`) e
eventos de outra sessão são rejeitados ou ignorados em modo fail-closed. Uma
nova quest na mesma sessão substitui a anterior; uma sessão diferente não pode
assumir a quest ativa.

Isso **não** é um mapa de runtimes concorrentes: o processo ainda suporta uma
quest ativa por vez. Para paralelizar, use processos opencode separados. A
proteção atual evita que sessões concorrentes corrompam o estado compartilhado,
mas não transforma um único processo em scheduler multi-quest.

Estados observáveis: `running`, `paused`, `blocked`, `timed_out` e
`completed`. Timeout, erro de despacho e stall preservam diagnóstico em vez de
limpar ou completar a quest silenciosamente. Quest `timed_out` deve ser parada
e iniciada novamente depois da investigação; quests `blocked` podem ser
retomadas após corrigir o problema de roteamento.

## Validação e diagnóstico

Antes de executar quests globais, rode:

```powershell
npm run validate:quests
npm run validate:quests -- --json
npm run doctor -- --json --skip-opencode
```

`validate:quests` valida YAML, IDs de estágio, referências de modelo e alvos
de transição. `doctor` valida configuração renderizada, placeholders,
quests, lockfile e binários MCP. O verificador PowerShell também chama o
validador compartilhado para o diretório de quests instalado.

## Mitigação que sobrevive a perda de estágio

Cada estágio registra no próprio relatório o que o próximo precisa. Não é
proteção contra perda de contexto — contexto sobrevive quando a sessão é a
mesma. É proteção contra **perda de estágio**: se o `build` começa sem ver a
reprodução que o `plan` deveria ter escrito, isso indica estágio perdido, e a
instrução manda parar e reportar em vez de adivinhar o defeito.

O custo é uma frase a mais no relatório do plan. Vale, porque a alternativa é
um estágio trabalhando com premissa inventada.
