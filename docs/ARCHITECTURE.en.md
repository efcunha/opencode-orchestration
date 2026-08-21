# Architecture

How multi-LLM routing actually works, and why each piece is where it is. Read
this before touching the configuration.

> **Language:** Also available in Portuguese
> ([`ARCHITECTURE.md`](ARCHITECTURE.md)).

## The three layers

```
opencode.jsonc (global, ~/.config/opencode)
    providers  ->  which models exist
    agents     ->  which model each role uses
    model / small_model  ->  defaults
         |
         v
opencode.json (per project, optional)
    local overrides for mcp, lsp, plugin, skills
         |
         v
quest YAML (.agents/ in project, or agents/ globally)
    stage.agent + stage.model  ->  override per stage
```

opencode precedence: **user < workspace**. The project's config overrides the
global one. That is why providers and agents moved out of projects: while
they lived there, each repo redefined what `plan` and `build` meant.

`enabled_providers` deserves attention because the behavior is not intuitive:
it is an allowlist, and the project overrides the global. A provider defined
globally but outside the project's `enabled_providers` becomes **defined and
filtered** — the models simply do not show up, with no error. In a project
config that declares `enabled_providers` without including `deepseek`, no
`deepseek/*` appears.

## Agent slots

| Slot | Model | Nature |
|---|---|---|
| `plan` | `deepseek/deepseek-v4-pro` | Native, switchable with Tab in TUI |
| `build` | `minimax-coding-plan/MiniMax-M3` | Native, switchable with Tab |
| `review` | `deepseek/deepseek-v4-flash` | Custom, only runs if invoked |
| `bugfix` | `deepseek/deepseek-v4-pro` | Custom |
| `general` | `deepseek/deepseek-v4-flash` | Sub-agent — delegation |
| `explore` | `deepseek/deepseek-v4-flash` | Sub-agent — delegation |

`plan` and `build` are **native** slots of opencode. Overwriting those names
reconfigures the built-ins — it does not create new agents.

`general` and `explore` are sub-agent slots. Without a `model` declared they
inherit the root default, which used to make every delegation — code
exploration, broad research — go to MiniMax M3. Pointing them at Flash is the
only truly automatic routing that exists here: the primary agent decides to
delegate, and the slot decides the model. In practice they fire rarely,
because M3 running as `build` rarely delegates.

`review` is pointed at Flash and stays idle. This is deliberate, not an
oversight — see the section on review below.

## Per-stage quest routing

The quests plugin accepts `agent` and `model` per stage:

```yaml
stages:
  - id: plan
    agent: plan
    model: deepseek/deepseek-v4-pro
  - id: build
    agent: build
    model: minimax-coding-plan/MiniMax-M3
  - id: evidence
    agent: build                      # write tools from the build slot
    model: deepseek/deepseek-v4-flash # but a cheap model
```

`model` must be of the form `providerID/modelID` and is validated when the
quest loads. A malformed reference makes the quest fail to load, with an
explicit error, instead of being silently dropped.

**Stage `model` overrides the agent's model.** Measured by the
`override-probe` quest: `agent: build` (whose configured model is M3) together
with `model: deepseek/deepseek-v4-flash` was served by Flash. This is what
lets the `evidence` stage swap model without swapping agent — swapping agent
would cost the write tools and the stage could not create the file.

### How dispatch happens

The plugin calls `client.session.promptAsync` with `agent` and `model` in
the body, using the `sessionID` obtained from `ToolContext`. Dispatch is
**deferred to the `session.idle` event**: the stage's prompt is only delivered
after the current turn closes.

That deferral explains the headless limitation: `opencode run` can exit before
`session.idle`, losing the queued stage in some sessions. It is less likely in
persistent TUI. The watchdog detects a stage that ended without
`quest_advance`, tries up to two redispatches on the declared `agent`/`model`,
and then marks the quest `blocked` if dispatch still fails — with no silent
fallback to the TUI's current mode. `DWELL_MS` and `HEARTBEAT_MS` are currently
10 seconds. Each stage also has a 300-second default timeout (configurable in
YAML); timeout preserves the quest as `timed_out` for diagnosis. Backtick-wrapped
text is transported literally; the plugin does not execute Markdown as shell.

### Context crosses the handoff

The destination stage **sees** the conversation of previous stages. Measured
in 5 of 5 runs: the second stage quoted verbatim a token the first stage
invented at runtime and that does not exist on disk anywhere.

This is counterintuitive enough to have produced two false negatives before
the instrument was corrected — the model cited the token in its own
reasoning and still declared `NO_CONTEXT`. Detail in
[`MEASUREMENTS.md`](MEASUREMENTS.md).

Design consequence: there is no need to pass state between stages via file
for the next stage to *understand* the previous one.

### Why routed review is not independent review

`model-routed-dev` routes the `review` stage to DeepSeek V4 Flash and the
`handoff` stage to the same slot. This improves model separation, but it does
not create a security boundary or independent review: prior context remains
visible in the same session. For independent approval, Kiro or another process
must reread the diff and rerun validation.

## The plugin has its own repository

The plugin's source code lives in a separate internal repository
(lirrensi/opencode-quests as upstream, with routing patches in the local
`fork/stage-routing` branch). That repository is not this config repo and
is not a gitlink — it has its own history and stays outside of here. Tracking
it here would create a gitlink pointing at a commit that no published remote
has.

The artifact that opencode actually loads is the **flattened file**
`plugins/opencode-quests.ts`. That file is versioned **in this** repo and is
the only thing that needs to be present for the orchestration to work — it
is self-contained.

Practical consequence: to change the plugin, edit
`plugins/opencode-quests.ts` directly here, commit, and run
`.\scripts\Sync-Payload.ps1 -Check` before pushing. The source repository is
only needed to develop the plugin from the upstream; for use, this repo is
enough.

## Quest state and session isolation

The plugin keeps one quest runtime in process memory, but that runtime now
records its owning `sessionID`. Operations (`quest_advance`) and events from
another session are rejected or ignored fail-closed. A new quest in the same
session replaces the previous one; a different session cannot take over the
active quest.

This is **not** a map of concurrent runtimes: one process still supports one
active quest at a time. To parallelize, use separate opencode processes. The
current protection prevents concurrent sessions from corrupting shared state,
but it does not turn one process into a multi-quest scheduler.

Observable states are `running`, `paused`, `blocked`, `timed_out`, and
`completed`. Timeout, dispatch errors, and stalls preserve diagnostic state
instead of silently clearing or completing the quest. A `timed_out` quest must
be stopped and started again after investigation; a `blocked` quest can be
resumed after fixing the routing problem.

## Validation and diagnostics

Before running global quests:

```powershell
npm run validate:quests
npm run validate:quests -- --json
npm run doctor -- --json --skip-opencode
```

`validate:quests` validates YAML, stage IDs, model references, and transition
targets. `doctor` validates rendered configuration, placeholders, quests,
lockfile, and MCP binaries. The PowerShell verifier also calls the shared
validator for the installed quest directory.

## Mitigation that survives lost stages

Each stage records in its own report what the next one needs. This is not
protection against context loss — context survives when the session is the
same. It is protection against **stage loss**: if `build` starts without
seeing the reproduction `plan` should have written, that signals a lost stage,
and the instruction tells it to stop and report instead of guessing the defect.

The cost is one extra sentence in `plan`'s report. Worth it, because the
alternative is a stage working from an invented premise.
