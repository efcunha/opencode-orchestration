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
opencode.json (por projeto)
    mcp, lsp, plugin, skills  ->  só o que é local
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

Esse diferimento é a origem de um defeito. Em execução headless o cliente
`opencode run` pode sair antes do `idle`, e o estágio enfileirado se perde —
aconteceu em cerca de 1 de 3 sessões nas medições. Em TUI persistente não
aparece. A alternativa era despacho inline, que quebra o split de modelos, então
o diferimento ficou.

Se o despacho for recusado, o plugin cai para injeção de texto no TUI,
preservando o comportamento anterior do plugin em vez de falhar.

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

### Por que a revisão não é roteada

Rotear um estágio de revisão para outro modelo parece resolver autoavaliação,
mas não resolve. O modelo roteado percebe a saída do estágio anterior como
autoria própria — "I emitted them", verbatim de um probe. Isso vem de ele ver
aquele texto como turno dele no mesmo contexto, não de compartilhar pesos.
Trocar o modelo não desfaz a percepção. Revisão roteada seria autorrevisão com
outros pesos.

Por isso a revisão roteada por estágio costuma ser omitida — o estágio de
revisão fica externo, em sessão separada, em vez de compartilhada com o
mesmo modelo que acabou de escrever.

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

## Estado da quest é global ao processo

O plugin guarda o estado da quest em memória do processo, não por sessão. Duas
quests concorrentes se dividem: uma sessão recebe o primeiro estágio, outra o
segundo. Foi observado com sessões reais, e o `NO_CONTEXT` que a sessão órfã
reportou estava **correto** — aquela sessão de fato nunca teve o estágio
anterior.

Regra operacional: uma quest por vez.

## Mitigação que sobrevive aos dois defeitos

Cada estágio registra no próprio relatório o que o próximo precisa. Não é
proteção contra perda de contexto — contexto sobrevive. É proteção contra
**perda de estágio**: se o `build` começa sem ver a reprodução que o `plan`
deveria ter escrito, isso indica estágio perdido, e a instrução manda parar e
reportar em vez de adivinhar o defeito.

O custo é uma frase a mais no relatório do plan. Vale, porque a alternativa é
um estágio trabalhando com premissa inventada.
