# opencode global config

Providers, agents, MCPs, plugins, skills and quests that opencode loads from
`~/.config/opencode` — works in any project without needing a local config.

Versioned 2026-08-18. Templates with `{{nodeModules}}`, `{{userHome}}` and
`{{userAgents}}` are resolved at install time in
[`scripts/Install-Orchestration.ps1:Resolve-Template`](../../scripts/Install-Orchestration.ps1).

> **Language:** Also available in Portuguese
> ([`README.md`](README.md)).

## What's here

| Path | What it is |
|---|---|
| `opencode.jsonc` | Single config: providers (`minimax-coding-plan`, `deepseek`, `ollama`), agents (`plan`, `build`, `review`, `bugfix`, `general`, `explore`), MCPs, plugins, skills. |
| `agents/*.yaml` | Global quests — found in any project |
| `plugins/opencode-quests.ts` | Quests plugin **flattened** (artifact that opencode loads) |
| `plugins/crg-plugin.ts` | code-review-graph plugin |
| `skills/` | Global skills loaded via `skills.paths` in `opencode.jsonc` (`archify`, `find-skills`, `form-browser-validation`, `igniter`, `language`, `post-change-validation`, `trash`) |
| `mcp-docs/` | Documentation on how to invoke MCP servers via `mavis mcp call`. NOT an opencode skill — reference only. |

## What does NOT come here, and why

| Item | Where it lives |
|---|---|
| `node_modules`, root npm manifests, `tui.json`, `lsp-install-decisions.json` | Local state — `~/.config/opencode/.gitignore` |
| Per-project MCPs (`opencode.json` in workspace) | Project config, not global |

Per-project configs are loaded by the workspace config. The global config
does not need to know about them. Each project declares its own (in its own
`opencode.json` or `.opencode/` in the repo).

## The two non-obvious things

### The quests plugin has its own repository

The plugin's source code lives in a separate internal repository
(lirrensi/opencode-quests as upstream, with routing patches in the local
`fork/stage-routing` branch). That repository is not this config repo and
is not a gitlink — it has its own history and is ignored here. Tracking the
source here would create a gitlink pointing at a commit that no published
remote has, and a clone would break.

What **is** versioned in this repo is `plugins/opencode-quests.ts`, the
flattened file opencode actually loads. It is self-contained — this repo
alone is enough to restore a working orchestration. The source directory is
only needed to *develop* the plugin from the upstream.

Practical consequence: anyone editing
`plugins/opencode-quests/src/index.ts` in the internal repo needs, after the
build, to copy the resulting flattened `.ts` to
`payload/plugins/opencode-quests.ts` here and commit.

### The template

The `opencode.jsonc` of this payload has three groups of placeholders, all
resolved at install time by `scripts/Install-Orchestration.ps1`:

**Machine paths** (from `Resolve-Paths`):

| Placeholder | Source of resolved value |
|---|---|
| `{{nodeModules}}` | `npm root -g` (overridden by `ORCH_NPM_GLOBAL_NODE_MODULES`) |
| `{{userHome}}`    | `$env:USERPROFILE` (overridden by `ORCH_USER_HOME`) |
| `{{userAgents}}`  | `$userHome/.agents` (overridden by `ORCH_USER_AGENTS`) |

**LLM/provider configuration** (from `Resolve-LlmConfig`, in the order
config/llm-providers.json -> scripts/llm-defaults.json):

| Placeholder | Content |
|---|---|
| `{{enabledProvidersList}}` | Inline JSON array `["a","b","c"]` |
| `{{modelDefault}}`         | Root `model` field |
| `{{smallModelDefault}}`    | Root `small_model` field |
| `{{modelAgent<Slot>}}`     | `agents.<slot>.model` (Plan/Build/Review/Bugfix/General/Explore) |
| `{{tempAgent<Slot>}}`      | `agents.<slot>.temperature` (number, no quotes) |
| `{{descAgent<Slot>}}`      | `agents.<slot>.description` (quoted string) |
| `{{providersBlock}}`       | Full JSON block of `provider` |

Reinstalling on a new machine reflects the local `npm root -g` automatically;
no section of the config needs editing.

To add a new placeholder:

1. Add detection in `scripts/Install-Orchestration.ps1:Resolve-Paths` or
   `Resolve-LlmConfig`.
2. Add the entry to `vars` before the "Payload" block.
3. Use `{{name}}` in the template.

## Measured state of the orchestration

Measured 2026-08-18 via the `routing-probe` and `override-probe` quests,
with verification by API metadata (`providerID`/`modelID` per message), not
by model self-report:

- Per-stage routing hit the target model in **5 of 5** runs.
- Context survived the model handoff in **5 of 5** — the destination stage
  quoted verbatim a token the previous stage invented at runtime and that
  does not exist on disk.
- Stage `model` **overrides** the model declared on the agent. This is what
  made it possible, in `finops-task`, to swap model while keeping
  `agent: build` and its write tools.

Two known defects in the plugin, both measured and uncorrected:

- **Quest state is process-global, not per session.** Two concurrent quests
  split between sessions — one gets the first stage, another the second. Run
  one quest at a time.
- **In headless execution the deferred stage sometimes gets lost** (~1 in 3
  sessions), because dispatch happens on `session.idle` and the `opencode
  run` client can exit before that. In a persistent TUI it does not appear.

The mitigation is written into the quests' context: each stage records in
its own report what the next one needs, so a lost stage shows up as an
explicit failure instead of the next model guessing.
