# Config global do opencode

Providers, agentes e quests do opencode para **todas** as máquinas e projetos.
Versionado em 2026-08-18, depois de a orquestração multi-LLM passar a depender
deste diretório e ele existir em uma única cópia, num perfil de usuário.

## Por que este repo existe

Antes da consolidação, cada projeto declarava seus próprios providers e agentes.
`agent: plan` significava `deepseek-v4-pro` no cloudpilot, `9router/smart` no
ameg e `nvidia-nim/nemotron` no cip. Quest com roteamento por estágio não tinha
como funcionar: o mesmo YAML pedia um agente que resolvia para modelos
diferentes conforme o diretório de onde rodava.

A consolidação moveu providers e agentes para cá e removeu essas chaves dos
projetos. O efeito colateral é que **este diretório passou a ser ponto único de
falha** — os projetos agora dependem dele para saber o que é `plan` e o que é
`build`. Daí o versionamento.

## O que está aqui

| Caminho | O que é |
|---|---|
| `opencode.jsonc` | Providers (`minimax-coding-plan`, `deepseek`, `ollama`), agentes (`plan`, `build`, `review`, `bugfix`, `general`, `explore`), `model` e `small_model` default |
| `agents/*.yaml` | Quests com fallback global — encontradas de qualquer projeto |
| `plugins/opencode-quests.ts` | Plugin de quests **achatado**, o artefato que o opencode carrega |
| `plugins/crg-plugin.ts` | Plugin do code-review-graph |
| `project-configs/*.json` | Cópias versionadas dos `opencode.json` de projeto (ver abaixo) |
| `scripts/sync-project-configs.ps1` | Move essas cópias nas duas direções |
| `skills/` | Skills globais |
| `_backup-20260818-151256/` | Retrato pré-consolidação, mantido como único registro do "antes" |

Fora do versionamento, de propósito: `node_modules/`, os manifests npm da raiz
(que o opencode gerencia), `tui.json` e `lsp-install-decisions.json` (estado de
UI por máquina).

## As duas coisas não óbvias

### O plugin de quests tem dois repositórios

`plugins/opencode-quests/` é um clone de
[lirrensi/opencode-quests](https://github.com/lirrensi/opencode-quests) —
upstream de terceiro — com os patches de roteamento por estágio commitados
localmente na branch `fork/stage-routing`. Ele tem história própria e está
ignorado aqui: rastreá-lo criaria um gitlink apontando para um commit que não
existe em nenhum remoto publicado, e um clone quebraria.

O que **está** versionado aqui é `plugins/opencode-quests.ts`, o arquivo
achatado que `npm run deploy` gera e que o opencode realmente carrega. Ele é
autocontido, então este repo sozinho basta para restaurar orquestração
funcionando. O diretório de fonte só é necessário para *desenvolver* o plugin.

Consequência prática: quem edita `plugins/opencode-quests/src/index.ts` precisa
commitar em **dois** lugares — no repo interno e, depois de `npm run deploy`,
aqui.

### Os configs de projeto vivem aqui, não nos projetos

`opencode.json` está ignorado em ameg (`.gitignore:71`) e cip
(`.gitignore:104`), e essa decisão está certa: eles carregam caminho absoluto de
máquina (`C:/nvm4w/nodejs/node_modules/...`,
`C:\Users\ECUNHA\.pencil\...\mcp-server-windows-x64.exe`). Commitá-los nos repos
de projeto empurraria configuração pessoal para dentro de código compartilhado.

Só que ignorado nos projetos significava existir em uma cópia apenas. O script
`sync-project-configs.ps1` resolve isso dando a eles um lar aqui, onde caminho
de máquina é esperado:

```powershell
.\scripts\sync-project-configs.ps1 -Backup           # projeto  -> repo
.\scripts\sync-project-configs.ps1 -Restore          # só relata o que faria
.\scripts\sync-project-configs.ps1 -Restore -Force   # repo -> projeto
```

Não usa symlink de propósito: symlink no Windows exige Developer Mode ou shell
elevado, o que tornaria o restore inutilizável exatamente na hora em que ele
importa — máquina nova, sem setup.

Como são cópias, elas divergem se você mexer num `opencode.json` e esquecer o
`-Backup`. O script não tem como detectar isso sozinho.

## Restaurar numa máquina nova

1. Clonar este repo em `~/.config/opencode`.
2. Definir as variáveis de ambiente que a config referencia via `{env:}` —
   sem elas os providers carregam mas falham na primeira chamada:
   - `MINIMAX_API_KEY`, `DEEPSEEK_API_KEY` (providers)
   - `CONTEXT7_API_KEY`, `GITHUB_API_KEY`, `JIRA_API_TOKEN` (MCP dos projetos)
3. `.\scripts\sync-project-configs.ps1 -Restore -Force` para os projetos que
   existirem na máquina.
4. Conferir de um diretório vazio, que é o que prova que a resolução vem da
   config global e não de algum projeto:
   ```powershell
   opencode models      # deve listar exatamente os 4 modelos
   opencode agent list  # deve mostrar plan, build, review, bugfix, general, explore
   ```

Dependências externas que este repo **não** carrega:

- `skills/archify` é symlink para `~/.agents/skills/archify`. Git guarda o link,
  não o conteúdo. Se o destino não existir, a skill não carrega.
- `plugins/crg-plugin.ts` e os MCP dos projetos assumem binários instalados
  (`uvx`, `railway`, Docker, `node_modules` globais em `C:/nvm4w/`).

## Estado medido da orquestração

Medido em 2026-08-18 pelas quests `routing-probe` e `override-probe`, com
verificação por metadado de API (`providerID`/`modelID` por mensagem), não por
autorrelato do modelo:

- Roteamento por estágio acertou o modelo alvo em **5 de 5** rodadas.
- Contexto sobreviveu ao salto de modelo em **5 de 5** — o estágio destino citou
  verbatim um token que o anterior inventou em runtime e que não existe em disco.
- O `model` do estágio **sobrepõe** o modelo declarado no agente. Foi o que
  permitiu ao estágio `evidence` do `finops-task` trocar para
  `deepseek-v4-flash` mantendo `agent: build` e suas ferramentas de escrita.

Dois defeitos conhecidos do plugin, ambos medidos e não corrigidos:

- **Estado da quest é global ao processo, não por sessão.** Duas quests
  concorrentes se dividem entre sessões — uma fica com o primeiro estágio, outra
  com o segundo. Rode uma quest por vez.
- **Em execução headless o estágio diferido às vezes se perde** (~1 em 3
  sessões), porque o dispatch acontece no `session.idle` e o cliente
  `opencode run` pode sair antes. Em TUI persistente não aparece.

A mitigação está escrita no contexto das quests: cada estágio registra no
próprio relatório o que o próximo precisa, para que estágio perdido apareça como
falha explícita em vez de o modelo seguinte adivinhar.
