# opencode-orchestration

Installable npm package for opencode's multi-LLM orchestration: example
**MiniMax M3** for implementation, **DeepSeek V4 Pro** for planning and
diagnosis, **DeepSeek V4 Flash** for review and sub-agents — with per-stage
quest routing, measured and verifiable.

The configuration is portable. `payload/opencode.jsonc` is a template with
placeholders `{{nodeModules}}`, `{{userHome}}` and `{{userAgents}}` that the
installer resolves to local paths on first run. No hardcoded machine path
survives across installs.

> **Language:** This README is also available in Portuguese
> ([`README.md`](README.md)).

## Quickstart

### Install (once per machine)

Requires Node 18+, npm 9+ and PowerShell 7+ (`pwsh`) on `PATH`.

```bash
git clone <this-repo>
cd opencode-orchestration
npm install -g .
```

The command does, in order:

1. Installs the MCP dependencies declared in `dependencies` of `package.json`
   (`@modelcontextprotocol/server-memory`, `server-sequential-thinking`) and
   the `optionalDependencies` (today: `opencode-rag-plugin`, a local-first
   semantic RAG tool the user activates per project with `opencode-rag init`).
2. Triggers `postinstall`, which runs `scripts/install.js`.
3. `install.js` detects `npm root -g`, `$USERPROFILE` and `$HOME`, and calls
   `Install-Orchestration.ps1 -Force`.
4. PowerShell renders the `opencode.jsonc` template with the local paths,
   installs missing MCP npm packages, copies the payload to
   `~/.config/opencode`, and runs `Test-Orchestration.ps1`.

To install **locally** (without `-g`):

```bash
npm install
.\scripts\Install-Orchestration.ps1 -Force
```

To only verify:

```bash
npm run verify         # offline
npm run verify:net     # with API test
```

To simulate without writing anything:

```powershell
.\scripts\Install-Orchestration.ps1
```

## What the installer does on each machine

| Step | How |
|---|---|
| Detect `npm root -g` | `npm root -g` when not provided via `ORCH_NPM_GLOBAL_NODE_MODULES` |
| Detect `$USERPROFILE` | native process env |
| Detect `~/.agents` | `$USERPROFILE/.agents` or `$HOME/.agents` |
| Install missing MCP npm packages | `npm install -g <pkg>` per item in `scripts/mcp-packages.json` |
| Clone skills from external sources | `git clone --depth 1` per item in `scripts/install-git-repos.json` |
| Render `opencode.jsonc` | substitution of `{{nodeModules}}`, `{{userHome}}`, `{{userAgents}}` (and LLM placeholders) |
| Render symlinks | `payload-symlinks.template.json` -> `~/.config/opencode/skills/<name>` |
| Copy payload | from `payload/` to `~/.config/opencode/` (with backup first) |
| Verify | `Test-Orchestration.ps1` (exits 1 on failure) |

## What's in this repo

| Path | What it is |
|---|---|
| `payload/opencode.jsonc` | Global config — providers, agents, MCPs. TEMPLATE with `{{...}}` placeholders |
| `payload-symlinks.template.json` | Lists expected symlinks with `targetTemplate` |
| `payload/agents/*.yaml` | Global quests with per-stage routing |
| `payload/plugins/*.ts` | Quests plugin and crg-plugin (flattened artifacts) |
| `payload/skills/` | Global skills loaded by opencode (`archify`, `find-skills`, `form-browser-validation`, `igniter`, `language`, `post-change-validation`, `trash`) |
| `payload/mcp-docs/` | Documentation on how to invoke MCP servers via `mavis mcp call` (reference, not loaded as a skill) |
| `scripts/Install-Orchestration.ps1` | Installs: detects paths, installs MCPs, renders templates, copies, verifies |
| `scripts/Test-Orchestration.ps1` | Independent verification, exits 1 on failure. Works as a CI gate |
| `scripts/Sync-Payload.ps1` | Compares the payload against the rendered destination (`-Check` exits 1 on drift) |
| `scripts/install.js` | npm entry point — detects local paths and calls PowerShell |
| `scripts/setup.js` | Bin: `opencode-orchestration` or `setup-orchestration` |
| `scripts/mcp-packages.json` | Manifest of npm packages the installer installs globally |
| `scripts/install-git-repos.json` | Manifest of git repos cloned at install time (skills from external sources) |
| `docs/` | Installation, architecture, measurements and troubleshooting |

## Template variables

| Placeholder | Resolves to | Source |
|---|---|---|
| `{{nodeModules}}` | Global `node_modules` path | `npm root -g` |
| `{{userHome}}` | User's home directory | `$env:USERPROFILE` or `$env:HOME` |
| `{{userAgents}}` | `~/.agents` | derived from `{{userHome}}` |
| `{{enabledProvidersList}}`, `{{modelDefault}}`, `{{smallModelDefault}}` | Providers/LLM | `scripts/llm-defaults.json` or `config/llm-providers.json` override |
| `{{modelAgent<Slot>}}`, `{{tempAgent<Slot>}}`, `{{descAgent<Slot>}}` | Per agent slot | same source |
| `{{providersBlock}}` | Full `provider` JSON block | same source |

LLMs/providers are not hardcoded: the default comes from
`scripts/llm-defaults.json` and anyone can copy `scripts/llm-providers.example.json`
to `config/llm-providers.json` (gitignored) and customize. Switch from MiniMax
to Anthropic, add GPT, change temperatures per agent — all via that file.
See [`docs/INSTALL.md`](docs/INSTALL.md) section 8.

To add a new placeholder: extend `scripts/Install-Orchestration.ps1:Resolve-Paths`
or `Resolve-LlmConfig` and use it directly in the template.

### Auto-discovery of providers/models

The installer runs `opencode models --verbose` in an empty directory (to
ensure the resolved config comes from the global
`~/.config/opencode/opencode.jsonc`, not from a project's `opencode.json`) and
discovers exactly the models opencode has locally configured. The result
appears in the install's initial report, and validates
`scripts/llm-defaults.json` or `config/llm-providers.json` against what was
discovered — referenced models that were not discovered become warnings
(expired credential? unconfigured provider?).

When running `npm install -g .` on a new machine **and** the shell is
interactive (TTY) **and** `config/llm-providers.json` does not yet exist, the
installer triggers the **wizard** (`scripts/wizard.js`):

```
$ npm install -g .
[wizard] discovering models that opencode has configured...
[wizard] 3 chat model(s) discovered:
  opencode/gpt-5             - GPT-5 (OpenCode Zen)
  opencode/claude-sonnet-4-5 - Claude Sonnet 4.5 (OpenCode Zen)
  opencode/o3-mini           - o3-mini (OpenCode Zen)

  Slot: plan (planning, architecture and defect reproduction)
  Available models:
     1. opencode/gpt-5             GPT-5   [no key]
     2. opencode/claude-sonnet-4-5 Claude Sonnet 4.5 [no key]
     3. opencode/o3-mini           o3-mini [no key]
     0. (skip)
  Choice [1-3 or 0] [default: 1]:
```

The user answers 9 prompts (6 slots + model default + small model + y/n to
confirm), and the wizard generates `config/llm-providers.json` with:

- `enabled_providers` derived from what was chosen
- `provider.<name>` block with `npm`, `options.baseURL`, `options.apiKey`
  pointing at the env var that `opencode providers list` reported
- `models.<id>` block with `name`, `limit.context`, `limit.output` (from
  `models.dev`)
- Mapping of the 6 slots (plan/build/review/bugfix/general/explore) to the
  chosen models

The wizard configures **6 agent slots** (plan, build, review, bugfix, general,
explore). The `model-routed-dev` quest uses **3 of them** (plan, build,
review). The remaining slots serve other quests, sub-agent delegation, and
direct agent switching in the TUI. Assigning the same model to multiple slots
is valid if you have limited providers — the orchestrator works regardless.

From there the installer continues with `-Force` automatically. It works for
any machine where opencode has **any** provider configured (OpenCode Zen,
Anthropic, OpenRouter, Cloudflare, MiniMax, etc.).

To skip the wizard (silent install / CI): copy
`scripts/llm-providers.example.json` to `config/llm-providers.json` before
running `npm install`. To run the wizard manually at any time:

```bash
node scripts/wizard.js --output config/llm-providers.json --force
```

If stdin is not a TTY (CI, `npm install -g`, redirections), the wizard does
not run — install proceeds with defaults. Deliberate: the default install
must be non-interactive.

## Measured state

Verified on 2026-08-18 by API metadata (`providerID`/`modelID` per message),
not by model self-report:

- Per-stage routing hit the target model in **5 of 5** runs.
- Context survived the model handoff in **5 of 5**.
- Stage `model` overrides the model declared on the agent.

Method, sessions and the false negatives the instrument produced before being
fixed: [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md).

Two known and uncorrected defects in the quests plugin — process-global
state and stage loss in headless — are covered in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Reading

| Document | When |
|---|---|
| [`docs/INSTALL.md`](docs/INSTALL.md) | Install / reinstall / uninstall |
| [`docs/USAGE.md`](docs/USAGE.md) | Use the orchestrator in chat: `quest(...)`, `/quest`, operational rules |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Understand how routing works before touching it |
| [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md) | Check the evidence instead of trusting claims |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Something didn't route, or a stage didn't run |
