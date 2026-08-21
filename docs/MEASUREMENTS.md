# Medições

Registro detalhado do que foi medido em 2026-08-18, com método e dados brutos.
O resumo está no README; aqui está o que permite conferir em vez de acreditar.

> **Idioma:** tambem disponivel em ingles ([`MEASUREMENTS.en.md`](MEASUREMENTS.en.md)).

## Método

Duas perguntas, dois instrumentos.

**Roteamento chega ao modelo alvo?** Confirmado por **metadado de API**, não por
autorrelato. O servidor do opencode expõe, por mensagem, o `providerID` e o
`modelID` que atenderam aquele turno:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1   # noutra janela
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

Autorrelato do modelo foi coletado em paralelo, mas só como confirmação
secundária. Um modelo pode se identificar errado; o metadado do servidor não
opina.

**Contexto sobrevive ao salto?** O estágio A **inventa** um token em runtime, de
forma `A-NNNNN-NNNNN`, e o estágio B — em outro modelo — precisa citá-lo
verbatim. O token não existe em disco nenhum, então se B o cita, só pode ter
vindo pelo contexto. Isso fecha a única via de contaminação que existia numa
versão anterior do instrumento, em que o token estava no próprio YAML e B
poderia tê-lo lido.

Quests usadas: `routing-probe` (dois estágios, dois modelos) e `override-probe`
(um estágio, `model` divergindo do modelo do agente).

## Resultado — roteamento e contexto

| # | Sessão | Estágio A (API) | Token | Estágio B (API) | `PRIOR_TOKEN` |
|---|---|---|---|---|---|
| 1 | `ses_fe9be122a` | `deepseek/deepseek-v4-pro` | `A-73941-28560` | `minimax-coding-plan/MiniMax-M3` | `A-73941-28560` |
| 2 | `ses_fe9bc589d` | `deepseek/deepseek-v4-pro` | `A-73914-62805` | `minimax-coding-plan/MiniMax-M3` | `A-73914-62805` |
| 3 | `ses_fe9bbc19a` | `deepseek/deepseek-v4-pro` | `A-74092-31658` | `minimax-coding-plan/MiniMax-M3` | `A-74092-31658` |
| 4 | `ses_fe9b9f6b3` | `deepseek/deepseek-v4-pro` | `A-73914-82605` | `minimax-coding-plan/MiniMax-M3` | `A-73914-82605` |
| 5 | `ses_fe9b8c4bc` | `deepseek/deepseek-v4-pro` | `A-73921-48065` | `minimax-coding-plan/MiniMax-M3` | `A-73921-48065` |

**5 de 5** em ambas as perguntas.

## Resultado — override de modelo

As cinco rodadas acima não testavam override: `agent: plan` vinha com
`deepseek-v4-pro` e `agent: build` com `MiniMax-M3`, exatamente os modelos que
esses agentes já declaram na config. Se o servidor ignorasse o `model` do
estágio e usasse o do agente, o resultado seria idêntico e nada revelaria isso.

O `override-probe` isola a questão: `agent: build` (configurado em M3) com
`model: deepseek/deepseek-v4-flash`.

| Sessão | Esperado | API reportou | Autorrelato |
|---|---|---|---|
| `ses_fe9af8936` | `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4-flash` | `deepseek-v4-flash` |

O `model` do estágio ganha.

## Os falsos negativos

Duas medições anteriores relataram `NO_CONTEXT` e **ambas estavam erradas** —
erro do instrumento, não do sistema.

A instrução antiga dizia que a única fonte válida era o texto entregue pelo
motor de quests. Isso levou o modelo a raciocinar sobre design em vez de
inspecionar o próprio contexto. Em `ses_fe9c8cfb4`, o modelo escreveu no
raciocínio:

> However, the routing probe is specifically testing whether the routed stage
> has access to the previous stage's context. [...] The instruction text
> delivered to me by the quest engine is the only valid source.

E antes disso, na mesma mensagem, ele havia citado:

> I (this same assistant) in the prior turn DID write: `TOKEN_SEEN: A-31517-26261`

Ou seja: tinha o token à vista, reproduziu-o, e concluiu ausência. O outro caso,
`ses_fe9c41c83`, foi erro de parsing meu — o regex pegou o bloco citado em vez
da resposta; relendo, o valor estava correto e a rodada era positiva.

Correção aplicada ao instrumento: a instrução agora diz para reportar o que está
**literalmente presente** no contexto, proíbe raciocinar sobre como quests
"deveriam" funcionar, e avisa que declarar `NO_CONTEXT` com o valor visível é o
pior resultado possível porque corrompe a medição.

Lição que vale além deste caso: instrumento que sugere a conclusão contamina a
medição. Perguntar "o que você vê" dá resposta diferente de "você deveria ver
isso?".

## Anomalias observadas

**Quest partida entre sessões.** Disparei runs sobrepostos e uma quest se
dividiu: `ses_fe9bb28ac` recebeu só o `probe-a`, `ses_fe9bb05dd` só o `probe-b`.
O `NO_CONTEXT` reportado pela segunda estava **correto** — aquela sessão nunca
teve o estágio A. A causa histórica foi o estado da quest ser global sem ownership por sessão. O plugin atual registra `sessionID` e rejeita operações de outra sessão; um único processo ainda suporta uma quest ativa por vez, mas não divide mais o runtime silenciosamente.

**Estágio perdido em headless.** Quatro sessões ficaram só com o `probe-a`
(`fe9bb28ac`, `fe9b8897c`, `fe9ca1636`, `fe9ca47b2`). É o custo do despacho
diferido no `session.idle`: o cliente `opencode run` sai antes de o evento
disparar. Cerca de 1 em 3 em headless; não observado em TUI persistente.
Essa limitação ainda existe, embora falhas de despacho agora preservem a quest
como `blocked`.

**Entrega duplicada — comportamento histórico.** Algumas sessões receberam o mesmo estágio duas vezes
(`fe9bc589d` com `probe-b` duplicado, `fe9b8897c` com `probe-a` duplicado),
apesar do guard de `cancelDwell`. O watchdog atual limita retries e não faz
fallback silencioso, mas a medição histórica não prova ausência de duplicação
em todos os ambientes.

**Serialização malformada de tool call no M3.** Saídas do MiniMax M3 às vezes
trazem artefatos de template tipo `]<]minimax[>[<tool_call>`. O `quest_advance`
ainda registrou como tool part nas rodadas afetadas. É do provider, não do
plugin.

## Um defeito de configuração que a medição expôs

Ao verificar quais modelos DeepSeek de fato respondem:

```
deepseek-v4-flash       => OK
deepseek-v4-flash-free  => FALHOU — "The supported API model names are
                           deepseek-v4-pro or deepseek-v4-flash, but you
                           passed deepseek-v4-flash-free."
deepseek-v4-pro         => OK
```

O `small_model` global apontava para `deepseek-v4-flash-free`, um modelo que
nunca existiu. É por isso que ele estava no `whitelist` sem entrada
correspondente no bloco `models`.

`small_model` é o slot de maior frequência: título de sessão, sumarização,
compaction. Referência inválida não falha ao carregar a config — falha na
primeira chamada, em silêncio.

Corrigido para `deepseek/deepseek-v4-flash`. E a lição virou verificação
automática: `Test-Orchestration.ps1` agora confere **toda** referência de modelo
contra a lista que o opencode resolve.

## Validação atual do projeto

Além das medições históricas acima, a revisão atual foi validada com:

- `npm run validate:quests`: 4 de 4 quests válidas.
- `npm run validate:quests -- --json`: diagnóstico estruturado sem falhas.
- `npm run doctor -- --json --skip-opencode`: configuração, placeholders,
  quests, lockfile e binários MCP verificados.
- `esbuild payload/plugins/opencode-quests.ts`: TypeScript compilado sem erro.
- Parser do PowerShell: scripts de verificação e instalação válidos.

Esses checks são validação estática e de ambiente. Não substituem um teste de
roteamento ponta a ponta contra cada provider.

## Reproduzir

```powershell
# terminal 1
opencode serve --port 4599 --hostname 127.0.0.1

# terminal 2
opencode run --attach http://127.0.0.1:4599 --dir <projeto> --auto 'quest(file: "routing-probe")'
Start-Sleep -Seconds 70

# ler o metadado
$s = (Invoke-RestMethod "http://127.0.0.1:4599/session")[0]
Invoke-RestMethod "http://127.0.0.1:4599/session/$($s.id)/message" |
  Where-Object { $_.info.role -eq 'assistant' } |
  ForEach-Object {
      $t = ($_.parts | Where-Object { $_.type -eq 'text' }).text -join "`n"
      "$($_.info.providerID)/$($_.info.modelID) :: $($t -replace '\s+',' ')"
  }
```

Uma quest por vez. Runs sobrepostos partem a quest entre sessões e produzem
dados que parecem falha de contexto sem serem.
