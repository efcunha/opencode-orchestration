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
| `agents/*.yaml` | Quests globais — encontradas em qualquer projeto |
| `plugins/opencode-quests.ts` | Plugin de quests **achatado** (artefato que o opencode carrega) |
| `plugins/crg-plugin.ts` | Plugin do code-review-graph |
| `skills/` | Skills globais carregadas via `skills.paths` no `opencode.jsonc` (`archify`, `find-skills`, `form-browser-validation`, `igniter`, `language`, `post-change-validation`, `trash`) |
| `mcp-docs/` | Documentacao de como invocar MCP servers via `mavis mcp call`. NAO e skill opencode — apenas referencia. |

## O que NAO vem para ca, e por que

| Item | Onde mora |
|---|---|
| `node_modules`, manifests npm da raiz, tui.json, lsp-install-decisions.json | Estado local — `~/.config/opencode/.gitignore` |
| MCPs por projeto (`opencode.json` no workspace) | Config do projeto, nao global |

Configs por projeto sao carregados pela config do workspace. A config global
nao precisa sabê-los. Cada projeto declara os seus proprios (no proprio
`opencode.json` ou `.opencode/` no repo).

## As duas coisas nao obvias

### O plugin de quests tem um repositorio proprio

O codigo-fonte do plugin vive em um repositorio interno separado
(lirrensi/opencode-quests como upstream, com patches de roteamento na branch
local `fork/stage-routing`). Esse repositorio nao e este repo de config e nem
e gitlink — tem historia propria e fica ignorado aqui. Rastrear o fonte aqui
criaria um gitlink apontando para um commit que nao existe em nenhum remoto
publicado, e um clone quebraria.

O que **esta** versionado neste repo e `plugins/opencode-quests.ts`, o arquivo
achatado que o opencode realmente carrega. Ele e autocontido — este repo sozinho
basta para restaurar orquestracao funcionando. O diretorio de fonte so e
necessario para *desenvolver* o plugin a partir do upstream.

Consequencia pratica: quem edita `plugins/opencode-quests/src/index.ts` no repo
interno precisa, depois do build, copiar o `.ts` achatado resultante para
`payload/plugins/opencode-quests.ts` aqui e commitar.

### O template

O `opencode.jsonc` deste payload tem tres grupos de placeholders, todos
resolvidos na instalacao por `scripts/Install-Orchestration.ps1`:

**Paths de maquina** (vem de `Resolve-Paths`):

| Placeholder | Origem do valor resolvido |
|---|---|
| `{{nodeModules}}` | `npm root -g` (sobrescrito por `ORCH_NPM_GLOBAL_NODE_MODULES`) |
| `{{userHome}}`    | `$env:USERPROFILE` (sobrescrito por `ORCH_USER_HOME`) |
| `{{userAgents}}`  | `$userHome/.agents` (sobrescrito por `ORCH_USER_AGENTS`) |

**Configuracao de LLM/providers** (vem de `Resolve-LlmConfig`, na ordem
config/llm-providers.json -> scripts/llm-defaults.json):

| Placeholder | Conteudo |
|---|---|
| `{{enabledProvidersList}}` | Array JSON inline `["a","b","c"]` |
| `{{modelDefault}}`         | Campo `model` da raiz |
| `{{smallModelDefault}}`    | Campo `small_model` da raiz |
| `{{modelAgent<Slot>}}`     | `agents.<slot>.model` (Plan/Build/Review/Bugfix/General/Explore) |
| `{{tempAgent<Slot>}}`      | `agents.<slot>.temperature` (numero, sem aspas) |
| `{{descAgent<Slot>}}`      | `agents.<slot>.description` (string com aspas) |
| `{{providersBlock}}`       | Bloco JSON completo do `provider` |

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
