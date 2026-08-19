# Troubleshooting

Observed failure modes, with the symptom first. Start by running
`.\scripts\Test-Orchestration.ps1` — it covers most cases below and points to
the exact item.

> **Language:** Also available in Portuguese
> ([`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)).

## The stage ran on the wrong model

**Confirm before investigating.** The model's self-report is not sufficient
evidence; it can mis-identify itself. Only API metadata decides:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

If the metadata confirms the wrong model, check in this order:

1. **Does the stage declare `model`?** Without the field, it inherits the
   agent's model.
2. **Does the reference exist?** `Test-Orchestration.ps1` checks each
   reference against the list opencode resolves.
3. **Is some project's `opencode.json` overriding?** The project config wins
   over the global one. Run `opencode models` **from inside the project** and
   compare with the result from an empty directory. A difference points at a
   local override.
4. **Is `enabled_providers` in the project filtering the provider?** It is an
   allowlist, and the project overrides the global. A provider outside the
   list becomes defined and invisible, with no error.

## The second stage never ran

Symptom: the session stops after the first stage, usually with a last
message like "Stage `x` queued. Ending turn."

**In headless it is expected**, about 1 in 3. Dispatch is deferred to the
`session.idle` event and the `opencode run` client can exit before it fires.
Workarounds, in order of preference:

- Run the quest in a **persistent TUI**, where this does not happen.
- If you need headless, use `--attach` against an already-running
  `opencode serve`, so the server survives the client's exit.

If it happens in the TUI, then it is something else: check that the previous
stage called `quest_advance` and that the YAML's `next` points at an `id`
that exists.

## The TUI stalled in Plan Mode

Symptom: the routed stage receives the instruction, but instead of calling
`quest_advance` the model emits text like "I'm in Plan Mode (read-only) — I
don't execute anything" and the turn closes. No error, no toast — the quest
stops silently.

Cause: the opencode TUI has two modes accessible via Tab — Plan (read-only,
the model only plans) and Build (the model can use tools). These are TUI
modes, independent of the orchestrator's `plan`/`build` agents — name
collision. When the TUI is in Plan Mode and the plugin dispatches a stage via
`client.session.promptAsync`, the call returns success (the server has no
way to know the turn will be unproductive) and the plugin cannot distinguish
that from a normal turn. The result is the model emitting the plan as plain
text, without calling tools — in particular, without `quest_advance`.

Auto-recovery (watchdog). Since 2026-08-19 the plugin detects and recovers
automatically. In
[`payload/plugins/opencode-quests.ts`](../../payload/plugins/opencode-quests.ts):

- When `flushPendingDispatch` delivers a stage successfully, it arms a flag
  (`dispatchedStageId`, `dispatchedStageMessage`). Lines 587-591.
- If `quest_advance` is called before the next `session.idle`, the flag is
  cleared — positive signal that the model executed. Lines 740-742.
- If the next `session.idle` arrives with the flag still armed, the stage
  stalled. The plugin shows a warning toast and re-dispatches without
  `agent`/`model`, going to whichever agent the TUI is currently on. If the
  user already pressed Tab to Build, the retry lands there. Lines 783-811.
- If the retry also stalls, it tries once more (maximum of 2 retries,
  `MAX_STALL_RETRIES`). Lines 795, 481.
- After 2 failures, it falls back to TUI injection
  (`clearPrompt` → `appendPrompt` → `submitPrompt`), which works regardless
  of mode. Lines 813-817.
- The watchdog is reset in `clear()` (quest finalized/stopped) and in a
  successful `quest_advance`, so it does not fire false positives in future
  quests. Lines 614-616, 740-742.

What you see during recovery:

```
Stage "preflight" stalled (Plan Mode?) — retry 1/2 on current agent
```

If the retry works, the toast disappears and the quest continues. If it
falls back to TUI injection, the quest also continues — but with the caveat
that the stage ran without tools, so the result is plain text (which the
next stage receives as context).

If you need to avoid the root cause: switch the TUI to Build before
firing the quest, or adjust the YAML so stages that depend on tools are
not routed to the `plan` agent.

## A quest split between two sessions

Symptom: one session has only the first stage, another only the second. The
second one typically reports not seeing anything from the previous stage —
and is **correct**, it never had it.

Cause: quest state is process-global, not per session. Two concurrent
quests get in each other's way.

Solution: one quest at a time. There is no better workaround without
changing the plugin.

## A stage reports not seeing the previous stage

Context **survives** the model handoff, measured 5 of 5. So this report is
usually one of three things, in this order of probability:

1. **Quest split between sessions** — see above. The report is correct.
2. **Lost stage** — the previous one never ran in this session.
3. **Instrument false negative** — if you wrote the stage's instruction,
   check that it doesn't suggest the conclusion. An instruction saying
   "only the text delivered by the engine is a valid source" makes the
   model declare absence even with the value in view. Ask what it
   **sees**, not what it **should** see.

To distinguish 1 from 2, list which stages each session received:

```powershell
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
  Where-Object { $_.info.role -eq 'user' } |
  ForEach-Object {
      (($_.parts | Where-Object { $_.type -eq 'text' }).text -split "`n" |
       Select-String 'Stage:') -join ' '
  }
```

## Provider loads but the call fails

Symptom: `opencode models` lists the model, but using it gives an
authentication error.

The environment variable referenced by `{env:...}` is not defined **in the
process that is running**. A variable set after the process started is not
seen by it. Open a new shell.

```powershell
.\scripts\Test-Orchestration.ps1   # checks presence without printing the value
```

## A model "exists" in the config but the API rejects it

Symptom: error like `The supported API model names are X or Y, but you
passed Z`.

This was exactly the case for `deepseek-v4-flash-free`, which stayed in the
global `small_model` pointing at a non-existent model. An invalid reference
**does not** fail at config load — it fails on the first call, silently.

`Test-Orchestration.ps1` catches this by comparing the declared whitelist
with the resolved models, in both directions, and validating each reference
individually. If it passes and the API still rejects, the whitelist is
declaring a model the provider no longer serves: confirm directly against the
API.

## `opencode models` lists nothing, or lists the wrong set

Run it from an **empty directory**. That is the only way to know if the
resolution comes from the global config:

```powershell
$d = Join-Path $env:TEMP "oc-check"; New-Item -ItemType Directory $d -Force | Out-Null
Push-Location $d; opencode models; Pop-Location
Remove-Item $d -Recurse -Force
```

Empty or incomplete output points to an `opencode.jsonc` that doesn't parse,
or `enabled_providers` filtering. The verifier covers both.

## I changed the config and the install on another machine came out stale

The `payload/` is derived from the live config and does not refresh itself:

```powershell
.\scripts\Sync-Payload.ps1 -Check   # exits 1 if divergent
.\scripts\Sync-Payload.ps1          # syncs
```

Use `-Check` before committing. Without it the payload ages silently.

If you edited `payload/` by hand, you lost it: the sync overwrites in the
live -> payload direction. Edit the live config.

## I changed the plugin and nothing happened

For those editing the quests plugin from the source repository (upstream +
local patches), three things, all necessary:

1. Rebuild the flattened artifact in the source repo — it generates the
   `.ts` opencode loads. Editing only the source changes nothing.
2. Copy the generated `plugins/opencode-quests.ts` to `payload/plugins/` in
   this repo and commit.
3. **Restart opencode.** Already-open TUI sessions keep the old plugin. And
   `Sync-Payload.ps1` for the new flattened file to reach the installed
   destination.

Note: the plugin has two repositories (this config one + the source one).
`payload/plugins/opencode-quests.ts` may have an uncommitted change even
with the source updated — or vice versa. `git status` in both shows it.

## A skill does not load

It's probably the symlink. `payload-symlinks.json` lists the ones the config
expects, and the installer reports whether the target exists. Git stores the
link, not the content.

```powershell
Get-Item "$env:USERPROFILE\.config\opencode\skills\archify" -Force |
    Select-Object LinkType, Target
```

If the target doesn't exist, create the link — it requires Developer Mode
or an elevated shell:

```powershell
New-Item -ItemType SymbolicLink `
         -Path "$env:USERPROFILE\.config\opencode\skills\archify" `
         -Target "$env:USERPROFILE\.agents\skills\archify"
```

## An MCP won't start

Four reasons, in order of probability.

**1. npm binary not installed.** The global config points at
`{{nodeModules}}/<pkg>`, which the installer resolves to the local
`npm root -g`. If you overrode the path with `ORCH_NPM_GLOBAL_NODE_MODULES`
and it doesn't match where npm actually installed the deps, the MCP's
`node <path>` command fails with ENOENT. Use `npm root -g` in the same
shell where opencode will run to confirm.

**2. External binary not on PATH.** When an MCP uses `npx`, `uvx` or its own
CLI binaries, they must be on PATH. `uvx` in particular is what enables the
Python LSP via `pyright-langserver`.

**3. Package version changed.** The `opencode`/`mcp` we are routing to a
`node <path>/dist/index.js` assumes a folder structure that the original npm
package ships. If an upgrade breaks this, the installer will pass the
template but the binary won't be where we expect — compare
`npm ls -g <pkg> <pkg>@<version>` with what the config's `command` points at.

To add a new MCP or update an existing one, see the "Add a new MCP" section
in [`INSTALL.md`](INSTALL.md).

## "Placeholder {{...}} was not resolved"

Symptom: the installed config at `~/.config/opencode/opencode.jsonc` still
contains the literal string `{{nodeModules}}` or similar.

Cause: the local detection (in `Install-Orchestration.ps1:Resolve-Paths`)
could not get `npm root -g` and there was no `ORCH_NPM_GLOBAL_NODE_MODULES`
defined. Without a path, nothing substitutes.

Check:

```powershell
$env:ORCH_NPM_GLOBAL_NODE_MODULES = (npm root -g)
.\scripts\Install-Orchestration.ps1 -Force
```

## What the verifier does not cover

- **Project quests.** It only validates the globals at
  `~/.config/opencode/agents`. Any quests in `.agents/` of a project
  (local or external) are not verified — the verifier only sees the globals.
- **MCP reachability.** Binary presence is checked; whether the server
  starts and responds is not.
- **End-to-end routing.** It checks that references resolve, not that a
  stage was actually served by the target model. For that, run
  `routing-probe` and read the metadata — see
  [`MEASUREMENTS.md`](MEASUREMENTS.md).

## Quest started but Task block is empty

Symptom: the quest starts and the first stage (usually `plan`) reports an
empty "Task" block, or produces a generic plan without addressing the user's
request.

Cause: the `input` parameter was not passed correctly. All `quest()` tool
parameters are **named** — positional arguments are not supported.

Wrong:
```
quest(file: "model-routed-dev", "Create an HTML welcome page")
```

Right:
```
quest(file: "model-routed-dev", input: "Create an HTML welcome page")
```

The plugin shows a toast hint when `input` is missing and a quest file/name
is specified: `Tip: pass the task as input: "your task here" (named
parameter)`.

Mitigation built into `model-routed-dev.yaml`: the plan stage's instruction
includes a fallback — "If that block is empty, read the user's original
request from the conversation context." This works when the user typed a
request in the chat before calling `quest()`, but is unreliable if `quest()`
was the first message in the session. Use the named `input:` parameter.

## Stage timed out

Symptom: toast reads `Stage "X" timed out (300s without quest_advance) —
forcing quest completion`.

Cause: the model produced output but never called `quest_advance` within
the configured timeout (default: 5 minutes). This can happen when:

1. The model misunderstood the instruction and did not call `quest_advance`.
2. An API error caused the model's response to be truncated before the tool
   call.
3. The TUI was in Plan Mode and the watchdog retries were also exhausted
   before the timeout fired.

Resolution: re-fire the quest. If it persists, check whether the model
supports tool calling reliably (some models drop tool calls under high
output volume). Consider switching the affected stage to a more capable
model via the `model:` field in the YAML.

To change the timeout per quest, add a top-level `timeout:` field (seconds):

```yaml
kind: quest
name: My Quest
timeout: 600   # 10 minutes instead of default 5
stages:
  - id: ...
```
