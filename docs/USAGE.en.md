# Using the orchestrator in the opencode chat

How to start, manage and diagnose a quest from inside opencode. Focused on
the human user — what to type, what to expect, and the operational rules
that avoid the known pitfalls.

> **Language:** Also available in Portuguese ([`USAGE.md`](USAGE.md)).
> Plugin internals in [`ARCHITECTURE.md`](ARCHITECTURE.md); troubleshooting
> in [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 1. Starting a quest

The `quest` tool accepts four forms. With no argument at all, it shows
help.

```
quest()                  -> shows help and lists available quests
quest(file: "filename")  -> loads from .agents/filename.yaml
quest(name: "Name")      -> finds by the `name:` field (case-insensitive)
quest(schema: {...})     -> creates inline from a schema
```

### `quest()` — help

Type `quest()` in the chat and the plugin responds with the usage, the
directories it searches, and the `.yaml` files it found. This is the
right way to start if you don't remember the filename.

### `quest(file: "filename")` — by file

The most common form. The plugin searches in **two directories, in this
order**:

1. `<project>/.agents/` — project-specific quest
2. `~/.config/opencode/agents/` — global quests (shipped from the payload)

The first match wins. A project quest shadows a global one with the same
name — useful for a repo to customize a shared quest without editing the
global one.

`filename` can be passed with or without extension:

```
quest(file: "routing-probe")       # tries .yaml and .yml
quest(file: "routing-probe.yaml")  # explicit
```

Names with `..` or path separators are refused (anti path-traversal).

### `quest(name: "Quest Name")` — by name

When the project has several YAMLs and you'd rather not remember the
filename. The plugin scans every `.yaml` in the directories above and
compares case-insensitive against the YAML's `name:` field. Unique match
and the first hit wins.

### `quest(schema: {...})` — inline

For one-shot quests that aren't worth versioning as a file. The schema
goes through the same field validation as a file. Useful for
experimentation or when opencode is generating the quest dynamically.

## 2. Slash commands: `/quest`

Besides the `quest` tool (which **starts**), there is a `/quest` slash
command that **manages** the active quest. Use it in the chat like any
other opencode slash command.

| Command | Effect |
|---|---|
| `/quest` or `/quest status` | Shows current stage, dwell and status (idle/active). Equivalent to asking for status at any time. |
| `/quest pause` | Pauses heartbeat and dwell reminder. The quest freezes where it is. |
| `/quest resume` | Resumes from where it stopped. Re-arms heartbeat and dwell. |
| `/quest stop` | Ends the quest and clears state. Useful if you want to discard and start fresh. |

Unknown slash subcommands (e.g. `/quest restart`) trigger a toast
`Usage: /quest [status|pause|resume|stop]`.

## 3. How a quest executes — and what you see

The quest is NOT a synchronous call. The flow is:

1. You type `quest(file: "...")` in the chat.
2. The plugin loads the YAML, validates model references, arms the
   heartbeat, and shows a `Quest started: "Name"` toast.
3. The plugin delivers the **first stage** to the corresponding agent
   (`agent: build`, `agent: plan`, etc.) via `client.session.promptAsync`.
4. The stage's model receives the instruction, executes it, and when
   done calls the `quest_advance(stage: "next-id")` tool — **that is
   not yours to do**, the model does it itself.
5. The plugin validates the transition (YAML's `next`), switches state
   to the next stage, and dispatches it.
6. Back to step 3 until a stage calls `quest_advance("done")`.
7. Final: `Quest complete: "Name"` toast, state cleared.

### Toasts you will see during a quest

| Moment | Toast |
|---|---|
| Start | `Quest started: "Name"` |
| Every ~30s (heartbeat) | `Quest: Name \| Stage: id (i/n) \| elapsed \| status` |
| Dwell reminder (no output for 90s) | Re-delivers the current stage |
| Plan stall | `Stage "X" stalled (Plan Mode?) — retry 1/2 on current agent` |
| Stall after 2 retries | `Stage "X" stalled 2x — forcing TUI delivery` |
| End | `Quest complete: "Name"` |
| `/quest pause` | `Quest paused — "Name" at stage X` |
| `/quest resume` | `Quest resumed — "Name" at stage X` |
| `/quest stop` | `Quest stopped — "Name"` |

### Heartbeat and dwell reminder

Heartbeat runs every ~30s with stage status (idle/active, remaining
dwell). Useful to know whether something froze without opening logs.

The dwell reminder fires if the model produces no output for ~90s — the
plugin re-delivers the stage (does NOT create a new one). It is different
from the Plan Mode stall: stall = turn closed without `quest_advance`;
dwell = turn did not close.

## 4. Complete example: end-to-end

A **three-stage** quest that shows routing between models, model override
without changing agent, transitions driven by the model itself via
`quest_advance`, and the toasts you will see during execution. This
section is the concrete realization of sections 1 and 3 above.

### 4.1 The quest definition

Create `my-project/.agents/add-feature.yaml`:

```yaml
kind: quest
name: Add Feature
description: "Plan, implement and verify a small feature end-to-end across three stages"

stages:
  - id: design
    description: "Stage 1 — plan the feature"
    agent: plan
    model: deepseek/deepseek-v4-pro
    instruction: |
      You are designing a small feature for the user's request at hand.
      Do not write any code. Output ONLY a short Markdown design with:
        - Goal (1 sentence)
        - Files to add/modify (paths)
        - Public API change (if any)
        - Test cases (3-5 bullets)
      Then call quest_advance("implement").
    checklist:
      - "Design emitted in the 4-bullet format"
      - "No code produced"
      - "quest_advance(\"implement\") called"
    next:
      proceed: implement

  - id: implement
    description: "Stage 2 — write the code"
    agent: build
    model: minimax-coding-plan/MiniMax-M3
    instruction: |
      You are implementing the design from the previous stage.
      Read the prior turn's design output and translate it into code.
      Use write/edit tools to create or modify the files exactly as designed.
      When done, list the files you changed and call quest_advance("verify").
    checklist:
      - "Files mentioned in the design were touched"
      - "quest_advance(\"verify\") called"
    next:
      proceed: verify

  - id: verify
    description: "Stage 3 — cheap verification on a different model"
    agent: build                          # keep build's write tools
    model: deepseek/deepseek-v4-flash    # but a cheap model
    instruction: |
      You are verifying the implementation from the previous stage.
      Read the design and the files written. Confirm each test case from
      the design is plausibly satisfied. Reply with one of:
        VERIFIED: <one-line summary>
      or
        BLOCKED: <reason + next step>
      Then call quest_advance("done").
    checklist:
      - "VERIFIED or BLOCKED emitted"
      - "quest_advance(\"done\") called"
    next:
      proceed: done
```

The 3 stages exercise:

- Routing by agent (`plan` -> `build` -> `build`)
- Routing by model (DeepSeek Pro -> M3 -> DeepSeek Flash)
- **Model override without changing agent** (last stage: `agent: build`
  but `model: deepseek-v4-flash`) — the plugin uses the declared agent's
  tools and only swaps the model
- Transitions driven by the model via `quest_advance`, not by you

### 4.2 Firing

Persistent TUI (recommended):

```bash
cd my-project
opencode
```

In the TUI prompt, with Tab confirmed on **Build**:

```
quest(file: "add-feature")
```

Headless:

```bash
opencode run --auto 'quest(file: "add-feature")'
```

### 4.3 What you see — toast timeline

**Stage `design`** (DeepSeek V4 Pro, agent `plan`):

| Who | What |
|---|---|
| You | Type `quest(file: "add-feature")` |
| Plugin | Loads YAML, validates references, toast `Quest started: "Add Feature"` |
| Plugin | Dispatches the `design` stage instruction to DeepSeek V4 Pro |
| DeepSeek | Reads the request, emits a 4-bullet design, calls `quest_advance("implement")` |
| Plugin | Heartbeat: `Quest: Add Feature \| Stage: design (1/3) \| 0:08 \| 🟢 idle` |

**Stage `implement`** (MiniMax M3, agent `build`):

| Who | What |
|---|---|
| Plugin | Sees the transition, switches state to `implement`, dispatches to M3 |
| M3 | Reads the design DeepSeek just wrote (context crosses the handoff — `agent: plan` -> `agent: build`), writes the files, lists the diff, calls `quest_advance("verify")` |
| Plugin | Heartbeat: `Quest: Add Feature \| Stage: implement (2/3) \| 0:42 \| 🟢 idle` |

> M3 actually writes files. The plugin uses the **agent's** `build` tools
> (write/edit/bash) even with the model override — that is why the `verify`
> stage keeps `agent: build` and only swaps the model.

**Stage `verify`** (DeepSeek V4 Flash, agent `build`):

| Who | What |
|---|---|
| Plugin | Dispatches to DeepSeek V4 Flash (does not change agent — `agent: build` still applies) |
| Flash | Reads the design + the files written, replies `VERIFIED: ...` or `BLOCKED: ...`, calls `quest_advance("done")` |
| Plugin | Toast: `Quest complete: "Add Feature"` (info variant, 6000 ms) |

### 4.4 Inspecting during execution

At any moment, in the chat:

```
/quest status      # shows: Quest: Add Feature | Stage: implement (2/3) | 0:42 | ⏳ dwell 50s → remind
/quest pause       # freezes mid-run
/quest resume      # resumes from where it stopped
/quest stop        # aborts — clears everything
```

To confirm routing really hit the target models (don't trust self-report),
use the API metadata:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1
# in another terminal, while the quest runs:
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

You will see three `assistant` lines, one per stage, with `providerID/modelID`
swapping from `deepseek/...` to `minimax-coding-plan/...` and back to
`deepseek/...`. Real evidence, not self-report. Detail in
[`MEASUREMENTS.md`](MEASUREMENTS.md).

### 4.5 Extending this example

Natural extension points:

- **More agents**: add stages with `agent: bugfix` (DeepSeek Pro) or
  `agent: explore` (Flash) for specific tasks
- **Aggressive model override**: change `model` on any stage without
  touching `agent`, to cheapen while keeping tools
- **Inline schema**: replace the YAML with `quest(schema: {...})` for
  quick prototypes
- **More stages**: add a fourth stage (e.g. `document` with
  `agent: general`) without rework

The real quests `routing-probe` in
`payload/agents/routing-probe.yaml` (two stages, proves routing and
context) and `override-probe.yaml` (one stage, proves model override) are
minimal templates for your own YAMLs.

## 5. Three ways to fire

### Persistent TUI (recommended)

Open the TUI normally and type `quest(file: "...")` in the chat.
Persistent session, live context, automatic recovery in case of Plan Mode.

```bash
opencode
# in the TUI prompt:
quest(file: "routing-probe")
```

### Headless one-shot

To run from a script or CI without keeping the TUI open:

```bash
opencode run --auto 'quest(file: "routing-probe")'
```

Known limitation: the `opencode run` client can exit before the
`session.idle` event that dispatches the next stage. Result: the queued
stage is lost in roughly 1 of 3 runs. See
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) "The second stage never ran".

### Headless against a running server

Combines automation with survival: `opencode serve` stays in the
background, and each `opencode run --attach` connects and disconnects
without killing the server.

```bash
# terminal 1 (long-lived)
opencode serve --port 4599 --hostname 127.0.0.1

# terminal 2 (per run)
opencode run --attach http://127.0.0.1:4599 --dir <project> \
             --auto 'quest(file: "routing-probe")'
```

This is the mode used in [`MEASUREMENTS.md`](MEASUREMENTS.md) to
reproduce routing results.

## 6. Operational rules

### One quest at a time

Quest state lives in the opencode **process memory**, not per session.
Two concurrent quests split between sessions — one gets the first stage,
another the second. The orphan session reports `NO_CONTEXT`
**correctly** — it never had the previous stage.

Rule: **one quest at a time**. If you need to parallelize, run two
separate opencode processes.

### TUI in Build before firing

opencode's TUI has two modes via Tab — **Plan** (read-only, the model
only plans) and **Build** (the model can use tools). These are TUI
modes, not the orchestrator's `plan`/`build` agents — name collision.

If you fire a quest with the TUI in **Plan**, the routed stage receives
the instruction but cannot call tools — in particular, `quest_advance`.
The quest stops silently.

**Auto-recovery exists** since 2026-08-19: the plugin detects the stall
and re-dispatches up to 2 times, falling back to TUI injection in the
end. But that introduces delay and a warning toast. To avoid it: switch
to Build (Tab) before typing `quest(...)`. Technical detail in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) "The TUI stalled in Plan
Mode".

### Slash command vs tool

- `quest(...)` in the chat = **start** a quest. Tool.
- `/quest ...` in the chat = **manage** the active quest. Slash command.

Do not confuse: `/quest status` does not start anything, it only shows
status. And `quest(file: "...")` does not pause or stop anything — if
there is already an active quest, it replaces it.

### When to be suspicious

- **"stalled" warning toast**: the plugin is trying to recover. Wait
  ~10s. If it falls back to TUI injection, the quest continues with the
  caveat that the stage ran without tools.
- **Session stops after a stage with "queued" in the output**: probable
  headless dispatch loss. See
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
- **Two stages across different sessions**: global state clobbered.
  Stop the second one, let the first finish.
- **Heartbeat stops showing for >2 minutes**: probably frozen. Try
  `/quest status` to see where it is; `/quest stop` + redispatch is the
  pragmatic way out.

## 7. Typical workflow

1. Open the TUI: `opencode`.
2. Confirm you are in Build (footer).
3. Type `quest(file: "my-quest")`.
4. Follow along via the toasts (heartbeat every ~30s).
5. If you need to pause: `/quest pause`. Resume: `/quest resume`.
6. If something clearly froze: `/quest stop`, investigate, re-fire
   with `quest(file: "my-quest")`.
7. On finish: complete toast, state cleared, ready for the next.
