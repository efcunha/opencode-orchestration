# Config global do opencode

Providers, agentes, MCPs, plugins, skills e quests que o opencode carrega de
`~/.config/opencode` — funciona em qualquer projeto sem precisar config local.

Versionado em 2026-08-18. Templates com `{{nodeModules}}`, `{{userHome}}` e
`{{userAgents}}` sao resolvidos na instalacao, em
[`scripts/Install-Orchestration.ps1:Resolve-Template`](../../scripts/Install-Orchestration.ps1).

## O que esta aqui

| Caminho | O que e |
|---|---|
| `opencode.jsonc` | Config unica: providers (`minimax-coding-plan`, `deepseek`, `ollama`), agentes (`plan`, `build`, `review`, `bugfix`, `general`, `explore`), MCPs, plugins, skills. |
| `agents/*.yaml` | Quests globais com fallback — encontradas em qualquer projeto |
| `plugins/opencode-quests.ts` | Plugin de quests **achatado** (artefato que o opencode carrega) |
| `plugins/crg-plugin.ts` | Plugin do code-review-graph |
| `skills/` | Skills globais (playwright, memory, sequential-thinking, find-skills, etc.) |

## O que NAO vem para ca, e por que

| Item | Onde mora |
|---|---|
| `node_modules`, manifests npm da raiz, tui.json, lsp-install-decisions.json | Estado local — `~/.config/opencode/.gitignore` |
| MCPs por projeto (`opencode.json` no workspace) | Config do projeto, nao global |

Configs por projeto sao carregados pela config do workspace. A config global
nao precisa sabê-los. Cada projeto declara os seus proprios (no proprio
`opencode.json` ou `.opencode/` no repo).

## As duas coisas nao obvias

### O plugin de quests tem dois repositorios

`plugins/opencode-quests/` e um clone de
[lirrensi/opencode-quests](https://github.com/lirrensi/opencode-quests) — um
upstream de terceiro — com os patches de roteamento por estagio commitados
localmente na branch `fork/stage-routing`. Ele tem historia propria e esta
ignorado aqui: rastrea-lo criaria um gitlink apontando para um commit que nao
existe em nenhum remoto publicado, e um clone quebraria.

O que **esta** versionado aqui e `plugins/opencode-quests.ts`, o arquivo
achatado que `npm run deploy` gera e que o opencode realmente carrega. Ele e
autocontido, entao este repo sozinho basta para restaurar orquestracao
funcionando. O diretorio de fonte so e necessario para *desenvolver* o plugin.

Consequencia pratica: quem edita `plugins/opencode-quests/src/index.ts` precisa
commitar em **dois** lugares — no repo interno e, depois de `npm run deploy`,
aqui.

### O template de paths

O `opencode.jsonc` deste payload tem placeholders `{{nodeModules}}`,
`{{userHome}}`, `{{userAgents}}`. O instalador resolve na instalacao:

| Placeholder | Origem do valor resolvido |
|---|---|
| `{{nodeModules}}` | `npm root -g` (sobrescrito por `ORCH_NPM_GLOBAL_NODE_MODULES`) |
| `{{userHome}}`    | `$env:USERPROFILE` (sobrescrito por `ORCH_USER_HOME`) |
| `{{userAgents}}`  | `$userHome/.agents` (sobrescrito por `ORCH_USER_AGENTS`) |

Reinstalacao numa maquina nova reflete `npm root -g` local automaticamente;
nenhuma secao da config precisa ser editada.

Para adicionar um placeholder novo:

1. Adicionar deteccao em `scripts/Install-Orchestration.ps1:Resolve-Paths`.
2. Adicionar entrada em `vars` antes do bloco "Payload".
3. Usar `{{nome}}` no template.

## Estado medido da orquestracao

Medido em 2026-08-18 pelas quests `routing-probe` e `override-probe`, com
verificacao por metadado de API (`providerID`/`modelID` por mensagem), nao por
autorrelato do modelo:

- Roteamento por estagio acertou o modelo alvo em **5 de 5** rodadas.
- Contexto sobreviveu ao salto de modelo em **5 de 5** — o estagio destino citou
  verbatim um token que o anterior inventou em runtime e que nao existe em disco.
- O `model` do estagio **sobrepoe** o modelo declarado no agente. Foi o que
  permitiu em `finops-task` trocar de modelo mantendo `agent: build` e suas
  ferramentas de escrita.

Dois defeitos conhecidos do plugin, ambos medidos e nao corrigidos:

- **Estado da quest e global ao processo, nao por sessao.** Duas quests
  concorrentes se dividem entre sessoes — uma fica com o primeiro estagio, outra
  o segundo. Rode uma quest por vez.
- **Em execucao headless o estagio diferido as vezes se perde** (~1 em 3
  sessoes), porque o dispatch acontece no `session.idle` e o cliente
  `opencode run` pode sair antes. Em TUI persistente nao aparece.

A mitigacao esta escrita no contexto das quests: cada estagio registra no
proprio relatorio o que o proximo precisa, para que estagio perdido apareca como
falha explicita em vez de o modelo seguinte adivinhar.
