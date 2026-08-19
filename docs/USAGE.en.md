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

## 4. Three ways to fire

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

## 5. Operational rules

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

## 6. Typical workflow

1. Open the TUI: `opencode`.
2. Confirm you are in Build (footer).
3. Type `quest(file: "my-quest")`.
4. Follow along via the toasts (heartbeat every ~30s).
5. If you need to pause: `/quest pause`. Resume: `/quest resume`.
6. If something clearly froze: `/quest stop`, investigate, re-fire
   with `quest(file: "my-quest")`.
7. On finish: complete toast, state cleared, ready for the next.
