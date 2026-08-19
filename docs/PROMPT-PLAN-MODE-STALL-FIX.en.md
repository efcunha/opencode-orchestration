# Prompt: Verify and fix the Plan Mode Stall bug in the quests plugin

> Paste this entire prompt into a Kiro, Copilot or another agent session
> that has filesystem access on the machine where opencode runs. It
> diagnoses whether the problem exists and applies the fix.

> **Language:** Also available in Portuguese
> ([`PROMPT-PLAN-MODE-STALL-FIX.md`](PROMPT-PLAN-MODE-STALL-FIX.md)).

---

## Problem context

The `opencode-quests` plugin implements multi-LLM orchestration by quest
stage. Each stage can declare `agent:` and `model:` in YAML, and the
plugin dispatches via `client.session.promptAsync`.

There is a bug where **the quest silently stalls** if opencode's TUI is
in Plan Mode (Tab toggles between Plan/Build). What happens:

1. The plugin successfully dispatches a routed stage (promptAsync returns null)
2. The model receives the instruction, but Plan Mode blocks tool calls
3. The model emits the plan as plain text, does not call `quest_advance`
4. The turn closes, `session.idle` arrives, and the quest simply stops
5. No error, no toast, no recovery attempt

The visible symptom is the model saying something like:

```
I'm in Plan Mode (read-only) — I don't execute anything.
```

And the quest never advances to the next stage.

## Diagnosis — check whether this machine is affected

Run these commands in a PowerShell terminal:

```powershell
# 1. Locate the flattened plugin that opencode loads
$plugin = "$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts"
if (-not (Test-Path $plugin)) {
    Write-Host "PLUGIN NOT FOUND at $plugin" -ForegroundColor Red
    Write-Host "This machine does not have the quests plugin installed."
    exit
}

# 2. Check whether the watchdog is already present
$conteudo = Get-Content $plugin -Raw
if ($conteudo -match 'dispatchedStageId') {
    Write-Host "WATCHDOG ALREADY PRESENT — this machine has the fix." -ForegroundColor Green
    Write-Host "Size: $((Get-Item $plugin).Length) bytes"
    Write-Host "Modified: $((Get-Item $plugin).LastWriteTime)"
    exit
}

Write-Host "VULNERABLE — plugin without Plan Mode stall watchdog." -ForegroundColor Yellow
Write-Host "Size: $((Get-Item $plugin).Length) bytes"
Write-Host "Modified: $((Get-Item $plugin).LastWriteTime)"
```

The presence of the string `dispatchedStageId` in the flattened file is
what counts — the watchdog exists in five blocks (state variables, arm in
`flushPendingDispatch`, detect in `session.idle`, clear in
`quest_advance`, clear in `clear()`), but a single reference is enough
to know the patch has been applied.

## Fix — if the machine is vulnerable

Three paths, from simplest to most involved. Pick the one that fits your
situation.

### Option A — Reinstall this package (recommended)

If you have `opencode-orchestration` installed globally:

```bash
npm install -g opencode-orchestration --force
```

Or, if you have the repository cloned locally:

```powershell
cd <opencode-orchestration-repo>
.\scripts\Install-Orchestration.ps1 -Force
```

The installer copies `payload/plugins/opencode-quests.ts` (with the
watchdog) to `~/.config/opencode/plugins/`. Restart opencode afterwards
(close and reopen the TUI).

### Option B — Copy just the fixed plugin

If you don't want to reinstall everything (preserving other files in
`~/.config/opencode/` that you may have customized):

```powershell
# From a local clone of the opencode-orchestration repo:
$src = "<repo-path>/payload/plugins/opencode-quests.ts"
$dst = "$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts"
Copy-Item $src $dst -Force

# Restart opencode (close and reopen the TUI)
```

To fetch the file without cloning the whole repo:

```powershell
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/efcunha/opencode-orchestration/master/payload/plugins/opencode-quests.ts" `
  -OutFile "$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts"
```

### Option C — Apply the changes directly to the flattened file

If you don't have access to the `opencode-orchestration` repo and want to
patch the flattened file that's already installed:

> Open the file `$env:USERPROFILE\.config\opencode\plugins\opencode-quests.ts`
> and apply the five changes described in the "What the watchdog does"
> section below. Then restart opencode.

## What the watchdog does (5 changes to the flattened file)

### Change 1 — Declare state variables

Find the block that contains `let pendingDispatch` and `let dispatching`.
Add immediately after:

```typescript
let dispatchedStageId: string | null = null
let dispatchedStageMessage: string | null = null
let stallRetries = 0
const MAX_STALL_RETRIES = 2
```

### Change 2 — Arm the watchdog in `flushPendingDispatch`

Inside the `try` of the `flushPendingDispatch` function, locate:

```typescript
if (!failure) return
```

Replace with:

```typescript
if (!failure) {
  dispatchedStageId = stage.id
  dispatchedStageMessage = message
  return
}
```

### Change 3 — Detect stall in the `session.idle` handler

Inside the `event` handler that processes `t === "session.idle"`, find
the block that starts with `if (pendingDispatch)` and insert **before** it:

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

### Change 4 — Clear the watchdog in `quest_advance`

Inside the `execute` of the `quest_advance` tool, locate:

```typescript
if (!state) return "No active quest. Use quest() to start one."
```

Add immediately after:

```typescript
dispatchedStageId = null
dispatchedStageMessage = null
stallRetries = 0
```

### Change 5 — Clear the watchdog in `clear()`

Inside the `clear` function, locate:

```typescript
dispatching = false
```

Add immediately after:

```typescript
dispatchedStageId = null
dispatchedStageMessage = null
stallRetries = 0
```

## Post-fix validation

**First**: re-run the diagnosis above (step 2 of the PowerShell script).
It should now return `WATCHDOG ALREADY PRESENT`. If it still returns
`VULNERABLE`, one of the 5 changes didn't take — diff the file or re-read
the flattened file.

**Then**:

1. Restart opencode (already done in the install step, but confirm)
2. Open the TUI in Plan Mode (Tab until you see "Plan" in the footer)
3. Fire: `quest(file: "routing-probe")`
4. Wait ~10s
5. A toast should appear: `Stage "probe-a" stalled (Plan Mode?) — retry 1/2`
6. Press Tab (go to Build)
7. The retry should run the stage successfully

If the toast doesn't appear within 15s, the fix wasn't loaded — confirm
you restarted opencode after install.

## Immediate workaround (without applying the fix)

If you can't apply the fix right now, the manual mitigation is:

1. **Before** firing any quest, confirm the footer shows **Build**
2. If it stalled: press Tab → Build, then type `quest(file: "name")` again
3. Never paste the model's output into PowerShell — those numbered steps
   are instructions the model planned to execute inside opencode via tools,
   not terminal commands

## Reference

- **Installed flattened plugin** (what runs):
  `~/.config/opencode/plugins/opencode-quests.ts`
- **Plugin in this repo's payload** (source of the fix):
  `payload/plugins/opencode-quests.ts`
- **Commit that added the watchdog to this repo**:
  `843a50c` — "chore(payload): sync plugin with Plan Mode stall watchdog"
- **Full watchdog documentation** (including the auto-recovery theory):
  [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md), section "The TUI stalled in Plan Mode"
- **Usage documentation** (how to fire quests, slash commands, rules):
  [`docs/USAGE.md`](USAGE.md)
- **Repository**:
  https://github.com/efcunha/opencode-orchestration

> **Note on the plugin source**: this repo (`opencode-orchestration`)
> carries only the **flattened file** `payload/plugins/opencode-quests.ts`,
> self-contained and sufficient for opencode to run. The plugin's source
> repository (with `package.json`, tests and `npm run deploy`) lives in
> a separate internal repository and is not required for either
> installation or use.
