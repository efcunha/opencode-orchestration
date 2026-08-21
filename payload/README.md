# Config global do opencode

Providers, agentes, MCPs, plugins, skills e quests que o opencode carrega de
`~/.config/opencode` — funciona em qualquer projeto sem precisar config local.

Versionado em 2026-08-21. Templates com `{{nodeModules}}`, `{{userHome}}` e
`{{userAgents}}` sao resolvidos na instalacao, em
[`scripts/Install-Orchestration.ps1:Resolve-Template`](../../scripts/Install-Orchestration.ps1).

> **Idioma:** tambem disponivel em ingles ([`README.en.md`](README.en.md)).

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

## Estado atual da orquestracao

O plugin de quests mantém um único runtime em memória por processo, com
ownership explícito por `sessionID`. Operações e eventos de outras sessões são
rejeitados ou ignorados em modo fail-closed. Isso impede corrupção entre
sessões, mas não habilita quests concorrentes no mesmo processo; use processos
opencode separados para paralelismo.

Estados possíveis: `running`, `paused`, `blocked`, `timed_out` e `completed`.
Timeouts e falhas de roteamento permanecem visíveis para diagnóstico, em vez
de completar ou limpar a quest silenciosamente. Estágio roteado nunca cai para
o agente atual quando o despacho falha.

Agentes `plan`, `review` e `explore` têm permissões read-only no template:
`edit`, `bash` e `task` são negados; ferramentas de leitura permanecem
permitidas.

## Validação e instalação

O payload é fonte de verdade, mas a instalação global exige ação explícita:
`postinstall` instala dependências sem alterar a configuração global; use
`npm run install:force` ou `opencode-orchestration --force` para efetivar.

Checks disponíveis no repositório:

```powershell
npm run validate:quests
npm run validate:quests -- --json
npm run doctor -- --json --skip-opencode
npm run sync:check
```

`validate:quests` valida quests YAML. `doctor` produz diagnósticos estruturados
para config, placeholders, quests, lockfile e MCPs. `sync:check` apenas compara
o payload com o destino instalado e retorna código `1` quando há drift.

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

Limitações atuais e histórico relevante:

- **Execução headless.** O estágio diferido pode se perder (~1 em 3 nas
  medições históricas) porque o dispatch acontece em `session.idle` e o
  cliente `opencode run` pode sair antes. TUI persistente ou `--attach` com
  `opencode serve` é preferível.
- **Uma quest ativa por processo.** Ownership por `sessionID` impede que outra
  sessão corrompa ou assuma a quest, mas não fornece um mapa de runtimes
  concorrentes. Use processos separados para paralelismo.
- **Medições históricas.** Os testes de roteamento e contexto foram realizados
  antes do hardening de sessão; consulte `docs/MEASUREMENTS.md` para separar
  comportamento medido de comportamento atual.
