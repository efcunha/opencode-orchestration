# Prompt: Verificar e corrigir o bug de Plan Mode Stall no plugin de quests

> Cole este prompt inteiro numa sessão do Kiro, Copilot ou outro agente que
> tenha acesso ao filesystem da máquina onde o opencode roda. Ele diagnostica
> se o problema existe e aplica a correção.

> **Idioma:** tambem disponivel em ingles
> ([`PROMPT-PLAN-MODE-STALL-FIX.en.md`](PROMPT-PLAN-MODE-STALL-FIX.en.md)).

---

## Contexto do problema

O plugin `opencode-quests` implementa orquestração multi-LLM por estágio de
quest. Cada estágio pode declarar `agent:` e `model:` no YAML, e o plugin
despacha via `client.session.promptAsync`.

Existe um bug onde **a quest trava em silêncio** se o TUI do opencode estiver
em Plan Mode (Tab alterna entre Plan/Build). O que acontece:

1. O plugin despacha um estágio roteado com sucesso (promptAsync retorna null)
2. O modelo recebe a instrução, mas Plan Mode bloqueia chamadas de ferramenta
3. O modelo emite o plano como texto puro, não chama `quest_advance`
4. O turno fecha, `session.idle` chega, e a quest simplesmente para
5. Nenhum erro, nenhum toast, nenhuma tentativa de recovery

O sintoma visível é o modelo dizendo algo como:

```
Estou em Plan Mode (read-only) — não executo nada.
```

E a quest nunca avança para o próximo estágio.

## Diagnóstico — verificar se esta máquina está afetada

Execute estes comandos num terminal PowerShell:

```powershell
# 1. Localizar o plugin achatado que o opencode carrega
$plugin = "$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts"
if (-not (Test-Path $plugin)) {
    Write-Host "PLUGIN NAO ENCONTRADO em $plugin" -ForegroundColor Red
    Write-Host "Esta maquina nao tem o plugin de quests instalado."
    exit
}

# 2. Verificar se o watchdog já existe
$conteudo = Get-Content $plugin -Raw
if ($conteudo -match 'dispatchedStageId') {
    Write-Host "WATCHDOG JA PRESENTE — esta maquina tem a correcao." -ForegroundColor Green
    Write-Host "Tamanho: $((Get-Item $plugin).Length) bytes"
    Write-Host "Modificado: $((Get-Item $plugin).LastWriteTime)"
    exit
}

Write-Host "VULNERAVEL — plugin sem watchdog de Plan Mode stall." -ForegroundColor Yellow
Write-Host "Tamanho: $((Get-Item $plugin).Length) bytes"
Write-Host "Modificado: $((Get-Item $plugin).LastWriteTime)"
```

A presença da string `dispatchedStageId` no arquivo achatado é o que conta —
o watchdog existe em cinco blocos (variáveis de estado, armar em
`flushPendingDispatch`, detectar em `session.idle`, limpar em
`quest_advance`, limpar em `clear()`), mas basta uma das referências
existir para o patch estar aplicado.

## Correção — se a máquina está vulnerável

Três caminhos, do mais simples ao mais trabalhoso. Escolha o que cabe na
sua situação.

### Opção A — Reinstalar este pacote (recomendado)

Se você tem o `opencode-orchestration` instalado globalmente:

```bash
npm install -g opencode-orchestration --force
```

Ou, se você tem o repositório clonado localmente:

```powershell
cd <repo-do-opencode-orchestration>
.\scripts\Install-Orchestration.ps1 -Force
```

O instalador copia `payload/plugins/opencode-quests.ts` (com o watchdog)
para `~/.config/opencode/plugins/`. Reinicie o opencode depois
(fechar e abrir o TUI).

### Opção B — Copiar apenas o plugin corrigido

Se você não quer reinstalar tudo (preservando outros arquivos de
`~/.config/opencode/` que talvez você tenha customizado):

```powershell
# Do clone local do repo opencode-orchestration:
$src = "<caminho-do-repo>/payload/plugins/opencode-quests.ts"
$dst = "$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts"
Copy-Item $src $dst -Force

# Reiniciar o opencode (fechar e abrir o TUI)
```

Para baixar o repo sem clonar tudo:

```powershell
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/efcunha/opencode-orchestration/master/payload/plugins/opencode-quests.ts" `
  -OutFile "$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts"
```

### Opção C — Aplicar as mudanças no arquivo achatado diretamente

Se você não tem acesso ao repo `opencode-orchestration` e quer corrigir o
arquivo achatado que já está instalado:

> Abra o arquivo `$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts`
> e aplique as cinco mudanças descritas na seção "O que o watchdog faz"
> abaixo. Depois reinicie o opencode.

## O que o watchdog faz (5 mudanças no arquivo achatado)

### Mudança 1 — Declarar variáveis de estado

Procure pelo bloco que contém `let pendingDispatch` e `let dispatching`.
Adicione imediatamente após:

```typescript
let dispatchedStageId: string | null = null
let dispatchedStageMessage: string | null = null
let stallRetries = 0
const MAX_STALL_RETRIES = 2
```

### Mudança 2 — Armar watchdog no `flushPendingDispatch`

Dentro do `try` da função `flushPendingDispatch`, localize o trecho:

```typescript
if (!failure) return
```

E substitua por:

```typescript
if (!failure) {
  dispatchedStageId = stage.id
  dispatchedStageMessage = message
  return
}
```

### Mudança 3 — Detectar stall no handler de `session.idle`

Dentro do handler de `event` que trata `t === "session.idle"`, localize
o trecho que começa com `if (pendingDispatch)` e insira **antes** dele:

```typescript
if (dispatchedStageId && !pendingDispatch && state) {
  stallRetries++
  const stageId = dispatchedStageId
  const msg = dispatchedStageMessage!
  dispatchedStageId = null
  dispatchedStageMessage = null

  if (stallRetries <= MAX_STALL_RETRIES) {
    toast(`Stage "${stageId}" stalled (Plan Mode?) — retry ${stallRetries}/${MAX_STALL_RETRIES} on current agent`, "warning")
    const body: Record<string, any> = { parts: [{ type: "text", text: msg }] }
    try {
      const res: any = await client.session.promptAsync({ path: { id: sessionID }, body })
      if (res?.error) throw new Error(typeof res.error === "string" ? res.error : JSON.stringify(res.error))
      dispatchedStageId = stageId
      dispatchedStageMessage = msg
    } catch (e: any) {
      toast(`Stall retry failed: ${e?.message ?? String(e)} — TUI fallback`, "error")
      await client.tui.clearPrompt()
      await client.tui.appendPrompt({ body: { text: msg } })
      await client.tui.submitPrompt()
      stallRetries = 0
    }
  } else {
    toast(`Stage "${stageId}" stalled ${MAX_STALL_RETRIES}x — forcing TUI delivery`, "error")
    stallRetries = 0
    await client.tui.clearPrompt()
    await client.tui.appendPrompt({ body: { text: msg } })
    await client.tui.submitPrompt()
  }
  return
}
```

### Mudança 4 — Limpar watchdog em `quest_advance`

Dentro do `execute` da tool `quest_advance`, localize o trecho:

```typescript
if (!state) return "No active quest. Use quest() to start one."
```

Adicione imediatamente após:

```typescript
dispatchedStageId = null
dispatchedStageMessage = null
stallRetries = 0
```

### Mudança 5 — Limpar watchdog em `clear()`

Dentro da função `clear`, localize o trecho:

```typescript
dispatching = false
```

Adicione imediatamente após:

```typescript
dispatchedStageId = null
dispatchedStageMessage = null
stallRetries = 0
```

## Validação pós-fix

**Primeiro**: re-rote o diagnóstico acima (passo 2 do script PowerShell).
Agora ele deve retornar `WATCHDOG JA PRESENTE`. Se ainda retornar
`VULNERAVEL`, alguma das 5 mudanças não pegou — confira com `git diff` ou
releia o arquivo achatado.

**Depois**:

1. Reinicie o opencode (já feito no passo de instalação, mas confirme)
2. Abra o TUI em Plan Mode (Tab até ver "Plan" no rodapé)
3. Disparar: `quest(file: "routing-probe")`
4. Esperar ~10s
5. Deve aparecer toast: `Stage "probe-a" stalled (Plan Mode?) — retry 1/2`
6. Apertar Tab (ir para Build)
7. O retry deve rodar o estágio com sucesso

Se o toast não aparecer em 15s, o fix não foi carregado — confirme que
reiniciou o opencode depois da instalação.

## Workaround imediato (sem aplicar fix)

Se não puder aplicar o fix agora, a mitigação manual é:

1. **Antes** de disparar qualquer quest, confirme que o rodapé mostra **Build**
2. Se travou: aperte Tab → Build, depois digite `quest(file: "nome")` de novo
3. Nunca cole o output do modelo no PowerShell — aqueles passos numerados são
   instruções que o modelo planejou executar dentro do opencode via ferramentas,
   não comandos de terminal

## Referência

- **Plugin achatado instalado** (o que roda):
  `~/.config/opencode/plugins/opencode-quests.ts`
- **Plugin no payload deste repo** (a fonte da correção):
  `payload/plugins/opencode-quests.ts`
- **Commit que adicionou o watchdog a este repo**:
  `843a50c` — "chore(payload): sync plugin with Plan Mode stall watchdog"
- **Documentação completa do watchdog** (incluindo a teoria do auto-recovery):
  [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md), seção "O TUI travou em Plan Mode"
- **Documentação de uso** (como disparar quests, slash commands, regras):
  [`docs/USAGE.md`](USAGE.md)
- **Repositório**:
  https://github.com/efcunha/opencode-orchestration

> **Nota sobre o source do plugin**: este repo (`opencode-orchestration`)
> carrega apenas o **arquivo achatado** `payload/plugins/opencode-quests.ts`,
> autocontido e suficiente para o opencode rodar. O repositório de fonte
> do plugin (com `package.json`, testes e `npm run deploy`) vive em
> um repositório interno separado e não é necessário nem para instalar
> nem para usar.
