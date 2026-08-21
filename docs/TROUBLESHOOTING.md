# Troubleshooting

Modos de falha observados, com o sintoma primeiro. Comece pelos checks locais:

```powershell
npm run validate:quests
npm run doctor -- --json --skip-opencode
.\scripts\Test-Orchestration.ps1 -SkipNetwork
```

O validador cobre quests YAML; `doctor` cobre config, placeholders, lockfile e
MCPs; o verificador PowerShell cobre a instalação completa e chama o validador
compartilhado. Cada seção abaixo aponta o próximo diagnóstico.

> **Idioma:** tambem disponivel em ingles ([`TROUBLESHOOTING.en.md`](TROUBLESHOOTING.en.md)).

## O estágio rodou no modelo errado

**Confirme antes de investigar.** O autorrelato do modelo não é evidência
suficiente; ele pode se identificar errado. Só o metadado de API decide:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

Se o metadado confirma o modelo errado, verifique nesta ordem:

1. **O estágio declara `model`?** Sem o campo, ele herda o modelo do agente.
2. **A referência existe?** `Test-Orchestration.ps1` confere cada referência
   contra a lista que o opencode resolve.
3. **Algum `opencode.json` de projeto está sobrepondo?** A config do projeto
   vence a global. Rode `opencode models` **de dentro do projeto** e compare com
   o resultado de um diretório vazio. Diferença aponta sobreposição local.
4. **`enabled_providers` no projeto filtra o provider?** É allowlist, e o
   projeto sobrepõe a global. Provider fora da lista fica definido e invisível,
   sem erro.

## O segundo estágio nunca rodou

Sintoma: a sessão para depois do primeiro estágio, geralmente com uma última
mensagem tipo "Stage `x` queued. Ending turn."

**Em headless é esperado**, cerca de 1 em 3. O despacho é diferido para o evento
`session.idle` e o cliente `opencode run` pode sair antes de ele disparar.
Contornos, em ordem de preferência:

- Rode a quest no **TUI persistente**, onde não acontece.
- Se precisar de headless, use `--attach` contra um `opencode serve` já rodando,
  para que o servidor sobreviva à saída do cliente.

Se acontecer no TUI, aí é outra coisa: verifique se o estágio anterior chamou
`quest_advance` e se o `next` do YAML aponta para um `id` que existe.

## O TUI travou em Plan Mode

Sintoma: o estágio roteado recebe a instrução, mas em vez de chamar
`quest_advance` o modelo emite um texto tipo "Estou em Plan Mode (read-only) —
não executo nada" e o turno fecha. Sem erro, sem toast, a quest para em
silêncio.

Causa: o opencode TUI tem dois modos acessíveis por Tab — Plan (read-only, o
modelo só planeja) e Build (o modelo pode usar ferramentas). São modos do TUI,
independentes dos agentes `plan`/`build` da orquestração — colisão de nome.
Quando o TUI está em Plan Mode e o plugin despacha um estágio via
`client.session.promptAsync`, a chamada retorna sucesso (o servidor não sabe
que o turno vai ser improdutivo) e o plugin não tem como distinguir isso de
um turno normal. O resultado é o modelo emitir o plano como texto puro, sem
chamar ferramentas — em particular, sem `quest_advance`.

Auto-recovery (watchdog). Desde 2026-08-19 o plugin detecta e recupera
automaticamente. Em
[`payload/plugins/opencode-quests.ts`](../../payload/plugins/opencode-quests.ts):

- Quando `flushPendingDispatch` entrega um estágio com sucesso, arma um flag
  (`dispatchedStageId`, `dispatchedStageMessage`).
- Se `quest_advance` é chamado antes do próximo `session.idle`, o flag é
  limpo — sinal positivo de que o modelo executou.
- Se o próximo `session.idle` chega com o flag armado, o estágio travou. O
  plugin mostra um toast de aviso e re-despacha usando o mesmo `agent`/`model`
  declarado, nunca o modo atual do TUI.
- Se retries falharem, pausa a quest como `blocked` e cancela timers ativos.
  Não há fallback silencioso para Build, injeção inline ou execução no agente
  errado.
- O watchdog é resetado em `clear()` e em `quest_advance` bem-sucedido, para
  não disparar falsos positivos em quests futuras.

O que você vê durante a recuperação:

```
Stage "preflight" stalled (Plan Mode?) — retry 1/2 on routed agent
```

Se o retry funcionar, a quest continua no agente/modelo declarado. Se todos
falharem, a mensagem informa que a quest foi pausada; corrija o despacho ou
retome após verificar a sessão. O plugin não executa o estágio no modo atual
do TUI.

## Uma sessão tentou assumir a quest ativa

Sintoma: uma sessão recebe uma mensagem de ownership, ou eventos de outra
sessão parecem não fazer nada.

Causa: o plugin mantém uma quest por processo e registra o `sessionID`
proprietário. Operações (`quest_advance`) e eventos de outra sessão são
rejeitados ou ignorados em modo fail-closed. Isso evita que sessões concorrentes
corrompam o runtime, mas não habilita quests paralelas no mesmo processo.

Solução: use a sessão proprietária para continuar a quest. Para iniciar uma
quest diferente, use `/quest stop` na sessão atual ou abra um processo opencode
separado. Quest `timed_out` não pode ser retomada; investigue, pare e inicie
uma nova. Quest `blocked` pode ser retomada após corrigir o problema de
roteamento.

## Um estágio relata não ver o estágio anterior

Contexto **sobrevive** ao salto de modelo, medido em 5 de 5. Então esse relato
costuma ser uma de três coisas, nesta ordem de probabilidade:

1. **Quest partida entre sessões** — ver acima. O relato está correto.
2. **Estágio perdido** — o anterior nunca rodou nesta sessão.
3. **Falso negativo do instrumento** — se você escreveu a instrução do estágio,
   verifique se ela não sugere a conclusão. Instrução dizendo que "só o texto
   entregue pelo motor vale como fonte" faz o modelo declarar ausência mesmo com
   o valor à vista. Pergunte o que ele **vê**, não o que ele **deveria** ver.

Para distinguir 1 de 2, liste quais estágios cada sessão recebeu:

```powershell
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
  Where-Object { $_.info.role -eq 'user' } |
  ForEach-Object {
      (($_.parts | Where-Object { $_.type -eq 'text' }).text -split "`n" |
       Select-String 'Stage:') -join ' '
  }
```

## Provider carrega mas a chamada falha

Sintoma: `opencode models` lista o modelo, mas usá-lo dá erro de autenticação.

A variável de ambiente referenciada por `{env:...}` não está definida **no
processo que está rodando**. Variável definida depois de o processo iniciar não
é vista por ele. Abra um shell novo.

```powershell
.\scripts\Test-Orchestration.ps1   # checa presença sem imprimir valor
```

## Um modelo "existe" na config mas a API o rejeita

Sintoma: erro tipo `The supported API model names are X or Y, but you passed Z`.

Foi exatamente o caso do `deepseek-v4-flash-free`, que ficou no `small_model`
global apontando para um modelo inexistente. Referência inválida **não** falha
ao carregar a config — falha na primeira chamada, em silêncio.

`Test-Orchestration.ps1` pega isso comparando o whitelist declarado com os
modelos resolvidos, nas duas direções, e validando cada referência individual.
Se ele passa e a API ainda rejeita, o whitelist está declarando um modelo que o
provider não serve mais: confirme direto contra a API.

## `opencode models` não lista nada, ou lista o conjunto errado

Rode de um **diretório vazio**. É o único jeito de saber se a resolução vem da
config global:

```powershell
$d = Join-Path $env:TEMP "oc-check"; New-Item -ItemType Directory $d -Force | Out-Null
Push-Location $d; opencode models; Pop-Location
Remove-Item $d -Recurse -Force
```

Vazio ou incompleto aponta para `opencode.jsonc` que não parseia, ou
`enabled_providers` filtrando. O verificador cobre os dois.

## Mudei a config e a instalação numa outra máquina veio velha

O `payload/` é a fonte de verdade do pacote e não se atualiza sozinho no
sistema instalado:

```powershell
.\scripts\Sync-Payload.ps1 -Check   # sai 1 se houver divergência
.\scripts\Install-Orchestration.ps1 -Force  # instala o payload atual
```

Use `-Check` antes de commitar. Para alterar quests ou plugins, edite o
payload deste repositório e reinstale; o script de sync apenas compara e
reporta drift, não sobrescreve a fonte.

`npm install` e `npm install -g .` executam `postinstall` em modo seguro:
instalam dependências, mas não chamam PowerShell nem alteram a configuração
global. Para efetivar a instalação, use explicitamente:

```powershell
npm run install:force
# ou
opencode-orchestration --force
```

Não execute `Install-Orchestration.ps1 -Force` sem confirmar o `TargetRoot`:
ele cria backup e modifica a configuração global indicada.

## Mudei o plugin e nada aconteceu

O artefato carregado pelo opencode é `payload/plugins/opencode-quests.ts`.
Para alterações neste repositório:

1. Edite o arquivo achatado no `payload/plugins/`.
2. Rode o check TypeScript:
   `npx --yes esbuild payload/plugins/opencode-quests.ts --loader:.ts=ts --format=esm --platform=node --outfile=NUL`.
3. Rode `npm run validate:quests`, `npm run doctor -- --json --skip-opencode`
   e `git diff --check`.
4. Use `npm run sync:check` para conferir o destino instalado.
5. Reinstale explicitamente com `Install-Orchestration.ps1 -Force` e reinicie o
   opencode para sessões abertas carregarem o plugin novo.

Um repositório-fonte externo pode existir para desenvolvimento upstream, mas
não é requisito de execução nem é sincronizado automaticamente por este repo.
O payload versionado é a fonte de verdade do pacote.

## Uma skill não carrega

Provavelmente é o symlink. `payload-symlinks.template.json` lista os links
esperados, e o instalador reporta se o alvo existe. Git guarda o link, não o
conteúdo.

```powershell
Get-Item "$env:USERPROFILE\.config\opencode\skills\archify" -Force |
    Select-Object LinkType, Target
```

Se o alvo não existir, crie o link — exige Developer Mode ou shell elevado:

```powershell
New-Item -ItemType SymbolicLink `
         -Path "$env:USERPROFILE\.config\opencode\skills\archify" `
         -Target "$env:USERPROFILE\.agents\skills\archify"
```

## Um MCP nao sobe

Principais motivos, em ordem de probabilidade.

Antes de investigar manualmente, rode:

```powershell
npm run doctor -- --json --skip-opencode
npm run verify
```

O `doctor` verifica os binários locais declarados em `opencode.jsonc`; o
verificador também confere dependências e config renderizada. O config global aponta `{{nodeModules}}/<pkg>`,
que o instalador resolve para o `npm root -g` local. Se voce sobrescreveu o
caminho com `ORCH_NPM_GLOBAL_NODE_MODULES` e ele nao bate onde o npm realmente
instalou as deps, o comando `node <path>` do MCP falha com ENOENT. Use
`npm root -g` no mesmo shell onde o opencode vai rodar para confirmar.

**2. Binario externo nao esta no PATH.** Quando um MCP usar `npx`, `uvx` ou
binarios CLI proprios, eles precisam estar no PATH. `uvx` em particular e o
que habilita o LSP Python via `pyright-langserver`.

**3. Versao de pacote mudou.** O `opencode`/`mcp` que estamos roteando para
um `node <path>/dist/index.js` assume uma estrutura de pasta que o pacote npm
original entrega. Se um upgrade quebrar isso, o instalador vai conseguir
passar o template mas o binario nao vai estar onde esperamos — compare
`npm ls -g <pkg> <pkg>@<version>` com o que o `command` da config aponta.

Para gerar um MCP novo ou atualizar um existente, veja a secao
"Adicionar um novo MCP" em [`INSTALL.md`](INSTALL.md).

## "Placeholder {{...}} nao foi resolvido"

Sintoma: a config instalada em `~/.config/opencode/opencode.jsonc` ainda
contem a string literal `{{nodeModules}}` ou similar.

Causa: a deteccao local (em `Install-Orchestration.ps1:Resolve-Paths`) nao
conseguiu `npm root -g` e nao havia `ORCH_NPM_GLOBAL_NODE_MODULES` definido.
Sem caminho, nada substitui.

Conferir:

```powershell
$env:ORCH_NPM_GLOBAL_NODE_MODULES = (npm root -g)
.\scripts\Install-Orchestration.ps1 -Force
```

## O que os checks não cobrem

- **Quests de projeto por padrão.** `npm run validate:quests` valida
  `payload/agents` por padrão, mas aceita `--dir=<path>`. O verificador
  PowerShell valida o diretório global instalado e não descobre quests ocultas
  em outros caminhos automaticamente.
- **Alcançabilidade de MCP.** Presença de binário é checada; se o servidor sobe
  e responde, não.
- **Roteamento ponta a ponta.** Os checks conferem referências e configuração,
  não que um estágio foi realmente atendido pelo modelo alvo. Para isso, rode o
  `routing-probe` e leia o metadado — ver [`MEASUREMENTS.md`](MEASUREMENTS.md).
- **Concorrência real.** Ownership impede corrupção entre sessões, mas não
  fornece runtimes concorrentes independentes no mesmo processo.

## Quest iniciou mas o bloco Task está vazio

Sintoma: a quest inicia e o primeiro estágio (geralmente `plan`) reporta um
bloco "Task" vazio, ou produz um plano genérico sem endereçar o pedido do
usuário.

Causa: o parâmetro `input` não foi passado corretamente. Todos os parâmetros
da tool `quest()` são **nomeados** — argumentos posicionais não são suportados.

Errado:
```
quest(file: "model-routed-dev", "Crie uma página HTML de Boas Vindas")
```

Certo:
```
quest(file: "model-routed-dev", input: "Crie uma página HTML de Boas Vindas")
```

O plugin mostra um toast de dica quando `input` não é passado e um arquivo/nome
de quest é especificado: `Tip: pass the task as input: "your task here" (named
parameter)`.

Mitigação embutida no `model-routed-dev.yaml`: a instrução do estágio plan
inclui um fallback — "If that block is empty, read the user's original request
from the conversation context." Funciona quando o usuário digitou um pedido no
chat antes de chamar `quest()`, mas é pouco confiável se `quest()` foi a
primeira mensagem da sessão. Use o parâmetro nomeado `input:`.

## Estágio expirou por timeout

Sintoma: toast diz `Stage "X" timed out (300s without quest_advance) — quest
remains timed_out for diagnosis`.

Causa: o modelo produziu output mas não chamou `quest_advance` dentro do
(timeout padrão de 5 minutos ou valor configurado em `timeout:`). Isso pode
acontecer quando:

1. O modelo não entendeu a instrução e não chamou `quest_advance`.
2. Um erro de API fez a resposta ser truncada antes da tool call.
3. O TUI estava em Plan Mode e os retries do watchdog também falharam.

A quest permanece `timed_out` para diagnóstico e **não é force-completada nem
pode ser retomada**. Investigue o estágio, pare a quest e inicie uma nova
execução. Para falha de despacho, o status é `blocked`; depois de corrigir o
roteamento, use `/quest resume`.

Para alterar o timeout por quest, adicione um campo top-level `timeout:`
(segundos):

```yaml
kind: quest
name: Minha Quest
timeout: 600   # 10 minutos ao invés do default de 5
stages:
  - id: ...
```

## Se texto entre crases for executado

O plugin não interpreta Markdown como shell. Texto entre crases em input,
contexto ou instruções é preservado literalmente; comandos só são executados
quando o próprio agente os envia por uma ferramenta autorizada. Se uma
instalação antiga substituir crases por saída de comando, reinstale o payload
atual e reinicie o opencode para carregar o plugin corrigido.
