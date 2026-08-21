# Troubleshooting

Observed failure modes, with the symptom first. Start with the local checks:

```powershell
npm run validate:quests
npm run doctor -- --json --skip-opencode
.\scripts\Test-Orchestration.ps1 -SkipNetwork
```

The validator covers quest YAML; `doctor` covers config, placeholders, lockfile,
and MCPs; the PowerShell verifier covers the complete installation and calls
the shared validator. Each section below points to the next diagnostic.

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

- When `flushPendingDispatch` delivers a stage successfully, it arms
  (`dispatchedStageId`, `dispatchedStageMessage`).
- If `quest_advance` is called before the next `session.idle`, the flag is
  cleared — positive signal that the model executed.
- If the next `session.idle` arrives with the flag armed, the stage stalled.
  The plugin shows a warning toast and redispatches using the same declared
  `agent`/`model`, never the TUI's current mode.
- If retries fail, the quest is paused as `blocked` and active timers are
  cancelled. There is no silent fallback to Build, inline injection, or
  execution on the wrong agent.
- The watchdog resets in `clear()` and after successful `quest_advance`, so it
  does not create false positives in future quests.

What you see during recovery:

```
Stage "preflight" stalled (Plan Mode?) — retry 1/2 on routed agent
```

If the retry works, the quest continues on the declared agent/model. If all
retries fail, the message says the quest was paused; fix dispatch or resume
after checking the session. The plugin never executes the stage in the TUI's
current mode.

## A session tried to take over the active quest

Symptom: a session receives an ownership message, or events from another
session appear to do nothing.

Cause: the plugin keeps one quest per process and records its owning `sessionID`.
Operations (`quest_advance`) and events from another session are rejected or
ignored fail-closed. This prevents concurrent sessions from corrupting the
runtime, but it does not enable parallel quests in one process.

Solution: use the owning session to continue the quest. To start a different
quest, use `/quest stop` in the current session or open a separate opencode
process. A `timed_out` quest cannot be resumed; investigate, stop it, and start
a new run. A `blocked` quest can be resumed after fixing routing.

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

The `payload/` is the package source of truth and does not update the
installed system automatically:

```powershell
.\scripts\Sync-Payload.ps1 -Check   # exits 1 when drift exists
.\scripts\Install-Orchestration.ps1 -Force  # installs the current payload
```

Use `-Check` before committing. To change quests or plugins, edit the payload
in this repository and reinstall; the sync script only compares and reports
drift, it does not overwrite the source.

`npm install` and `npm install -g .` run `postinstall` in safe mode: they install
dependencies but do not invoke PowerShell or change global configuration. To
apply the installation, use an explicit action:

```powershell
npm run install:force
# or
opencode-orchestration --force
```

Do not run `Install-Orchestration.ps1 -Force` without confirming `TargetRoot`:
it creates a backup and modifies the selected global configuration.

## I changed the plugin and nothing happened

The artifact loaded by opencode is `payload/plugins/opencode-quests.ts`.
For changes in this repository:

1. Edit the flattened file under `payload/plugins/`.
2. Run the TypeScript check:
   `npx --yes esbuild payload/plugins/opencode-quests.ts --loader:.ts=ts --format=esm --platform=node --outfile=NUL`.
3. Run `npm run validate:quests`, `npm run doctor -- --json --skip-opencode`,
   and `git diff --check`.
4. Use `npm run sync:check` to inspect the installed destination.
5. Explicitly reinstall with `Install-Orchestration.ps1 -Force` and restart
   opencode so open sessions load the new plugin.

An external source repository may exist for upstream development, but it is not
required at runtime and is not synchronized automatically by this repository.
The versioned payload is the package source of truth.

## A skill does not load

It's probably the symlink. `payload-symlinks.template.json` lists the expected
links, and the installer reports whether the target exists. Git stores the link,
not the content.

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

Main causes, in order of probability.

Before investigating manually, run:

```powershell
npm run doctor -- --json --skip-opencode
npm run verify
```

`doctor` checks local binaries declared in `opencode.jsonc`; the verifier also
checks dependencies and rendered configuration.

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

## What the checks do not cover

- **Project quests by default.** `npm run validate:quests` validates
  `payload/agents` by default, but accepts `--dir=<path>`. The PowerShell
  verifier validates the installed global quest directory and does not discover
  hidden quests in other locations automatically.
- **MCP reachability.** Binary presence is checked; whether the server starts
  and responds is not.
- **End-to-end routing.** The checks validate references and configuration, not
  that a stage was actually served by the target model. For that, run
  `routing-probe` and read the metadata — see
  [`MEASUREMENTS.en.md`](MEASUREMENTS.en.md).
- **True concurrency.** Ownership prevents cross-session corruption, but the
  process does not provide independent concurrent runtimes.

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

Symptom: the toast reads `Stage "X" timed out (300s without quest_advance) —
quest remains timed_out for diagnosis`.

Cause: the model produced output but did not call `quest_advance` within the
configured timeout (default: 5 minutes or the value in `timeout:`). This can
happen when:

1. The model misunderstood the instruction and did not call `quest_advance`.
2. An API error truncated the response before the tool call.
3. The TUI was in Plan Mode and watchdog retries also failed.

The quest remains `timed_out` for diagnosis and is **not force-completed or
resumable**. Investigate the stage, stop the quest, and start a new run. A
dispatch failure uses `blocked`; after fixing routing, use `/quest resume`.

To change the timeout per quest, add a top-level `timeout:` field (seconds):

```yaml
kind: quest
name: My Quest
timeout: 600   # 10 minutes instead of default 5
stages:
  - id: ...
```

## If backtick-wrapped text is executed

The plugin does not interpret Markdown as shell. Backtick-wrapped text in
input, context, or instructions is preserved literally; commands are executed
only when the agent sends them through an authorized tool. If an older
installation replaces backticks with command output, reinstall the current
payload and restart opencode so the corrected plugin is loaded.
