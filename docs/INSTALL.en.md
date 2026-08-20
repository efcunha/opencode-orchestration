# Installation

Install the multi-LLM orchestration on a new machine. The `payload/` is
complete (no network or git remote needed) and portable (substitutes
placeholders with local paths at install time).

> **Language:** Also available in Portuguese
> ([`INSTALL.md`](INSTALL.md)).

## 1. Prerequisites

The installer aborts early if anything mandatory is missing. The first four
items in the table are blocking (checked in
`scripts/Install-Orchestration.ps1:Test-Prerequisites`): without `node`,
`npm`, `opencode` or `git`, install does not proceed. `pwsh` is handled by
`scripts/install.js:findPwsh` with fallback to `powershell.exe`; if neither is
on `PATH`, `install.js` aborts before calling PowerShell.

| Tool | Purpose | Verified by | Blocking? |
|---|---|---|---|
| `node` 18+ | Runtime for opencode and the Node-based MCPs | `node -v` | Yes |
| `npm` 9+ | Installs the MCP deps and this package globally | `npm -v` | Yes |
| `opencode` | Tool that consumes the config (`opencode serve` / `opencode run` / TUI) | `opencode --version` | Yes |
| `git` | Clones external skills from `scripts/install-git-repos.json` | `git --version` | Yes |
| `pwsh` (PowerShell 7+) | Installer, verifier, syncer | `pwsh -v` | Yes (falls back to `powershell.exe`) |

Optional — absence does not block install:

| Tool | What you lose without it |
|---|---|
| `uvx` | Python LSP (`pyright-langserver`) |
| `ollama` | Local embeddings for OpenCodeRAG (auto-installed if missing — see section 9) |

## 2. Environment variables

The installer **does not write** environment variables, by design: writing
keys via script would push them through the command line and shell history.
It checks presence and reports what is missing, never printing values.

Required — without them the provider loads but fails on the first call:

| Variable | Provider |
|---|---|
| `MINIMAX_API_KEY` | `minimax-coding-plan` (MiniMax M3) |
| `DEEPSEEK_API_KEY` | `deepseek` (V4 Pro and V4 Flash) |

Optional, used by the MCPs (none at the moment):

Persist at the user scope on Windows:

```powershell
[Environment]::SetEnvironmentVariable('MINIMAX_API_KEY',  '<value>', 'User')
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', '<value>', 'User')
```

Open a new shell afterwards. Processes already running do not see variables
set after they started.

## 3. Install via npm

```bash
git clone <this-repo>
cd opencode-orchestration
npm install -g .
```

This package's `postinstall` triggers `scripts/install.js`, which:

1. Detects `npm root -g`, `$USERPROFILE` and `$HOME`.
2. Forwards them as `ORCH_NPM_GLOBAL_NODE_MODULES`, `ORCH_USER_HOME`,
   `ORCH_USER_AGENTS`.
3. Calls `scripts/Install-Orchestration.ps1 -Force`.
4. PowerShell: installs missing MCP deps, renders templates, backs up the
   existing destination, copies payload, tries to create symlinks, validates
   with `Test-Orchestration.ps1`.

A **local** install (without `-g`) also works:

```bash
npm install
.\scripts\Install-Orchestration.ps1 -Force
```

The difference is where the npm deps land: with `-g` they go to npm's global
prefix (`%APPDATA%\npm\node_modules` or `~/.npm-global`); locally they go to
`node_modules/` in this repo. The rest of the flow is identical.

## 4. Manual install (without npm)

If you'd rather skip npm:

```powershell
cd D:\opencode-orchestration
.\scripts\Install-Orchestration.ps1           # simulates, writes nothing
.\scripts\Install-Orchestration.ps1 -Force    # effective, with backup first
.\scripts\Test-Orchestration.ps1              # end-to-end verification
```

The installer detects the local paths in the same places where `install.js`
sends them from its side, and falls back to the same `ORCH_*` variables when
they are set.

### Overriding detected paths

If automatic detection does not match what you want:

```powershell
$env:ORCH_NPM_GLOBAL_NODE_MODULES = 'C:\my\node\node_modules'
$env:ORCH_USER_HOME               = 'C:\Users\jane'
$env:ORCH_USER_AGENTS             = 'C:\Users\jane\.agents'
.\scripts\Install-Orchestration.ps1 -Force
```

Anything the `ORCH_*` variables do not cover is resolved by the installer's
own detection path.

### Installing to a different destination

```powershell
.\scripts\Install-Orchestration.ps1 -Force -TargetRoot D:\tmp\oc-test
```

## 5. Verify

```powershell
.\scripts\Test-Orchestration.ps1
```

Exits with code 0 if everything passes, 1 on any mandatory failure. What it
checks:

- `opencode.jsonc` exists and rendered with no remaining placeholders
  (`{{...}}` in the output indicates a partial install).
- Quests plugin and global quests are present.
- Environment variables are present (required ones fail, optional ones warn).
- Each MCP declared with `command: ["node", "<path>"]` points at a binary
  that exists on disk (errors if you installed without `npm install -g`
  first).
- `opencode models` is run from an empty directory — that is the point: it
  proves the resolution comes from the global config and not from some
  project's `opencode.json` in the current directory.
- The whitelist declared in the config matches exactly the models opencode
  resolves, in both directions.
- Every model reference — `model`, `small_model`, `agent.*.model`, and the
  `model:` of each quest stage — points at a model that exists.
- Real API call to DeepSeek and MiniMax.
- Ollama installed, service responding on port 11434,
  `nomic-embed-text:latest` model available locally, and embedding health
  check (all as non-blocking warnings).

Without network:

```powershell
.\scripts\Test-Orchestration.ps1 -SkipNetwork
```

The model reference check deserves a note. It exists because the global
`small_model` pointed at `deepseek-v4-flash-free`, a model that never existed
in the DeepSeek API. An invalid reference **does not** fail at config load —
it fails on the first call, silently, and the affected slot was the most
frequent one — session title, summarization, compaction.

## 6. Add a new MCP (that needs an npm binary)

1. Add the package in **two** places:
   - `package.json` `dependencies` — so `npm install -g .` does the work.
   - `scripts/mcp-packages.json` — so PowerShell checks/installs in the
     direct flow (`Install-Orchestration.ps1 -Force` without npm).
2. Add the `mcp.<name>` entry in `payload/opencode.jsonc` with the path
   `node {{nodeModules}}/<pkg>/...`.
3. The installer handles the rest — `Install-Orchestration.ps1 -Force` will
   check, install anything missing and re-render the template.

If the MCP **does not** need a binary (remote, or using `npx`/`uvx`/`docker`),
just edit `opencode.jsonc`.

## 7. Add a skill from an external source (git)

1. Add an entry to `scripts/install-git-repos.json`:
   ```json
   {
     "url": "https://github.com/user/skill.git",
     "ref": "main",
     "target": "{{userAgents}}/skills/<name>",
     "depth": 1,
     "why": "External skill for..."
   }
   ```
2. After cloning into the target directory, create or point the expected
   symlink in `payload-symlinks.template.json` (if you want the symlink in
   the global config).
3. `Install-Orchestration.ps1 -Force` clones when missing. Repos already
   present are not overwritten — update with `git pull` manually.

## 8. Switching LLM providers (Claude, GPT, Gemini, etc.)

LLMs/providers are not hardcoded in the template. The default (MiniMax +
DeepSeek + Ollama) comes from `scripts/llm-defaults.json`. To customize:

1. Copy the example to your config:
   ```powershell
   Copy-Item scripts/llm-providers.example.json config/llm-providers.json
   ```
2. Edit `config/llm-providers.json`:
   - `enabled_providers`: list of active providers
   - `model` / `small_model`: defaults
   - `agents.<slot>`: slot -> model mapping (plan, build, review, bugfix,
     general, explore). Each agent accepts `model`, `temperature`,
     `description`.
   - `providers.<name>`: full block per provider (npm, options, whitelist,
     models with limit).
3. Set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / etc. as environment
   variables (at the User scope, with
   `[Environment]::SetEnvironmentVariable]`).
4. Run `.\scripts\Install-Orchestration.ps1 -Force`.

The override file **fully replaces** the defaults. List every provider you
want to use — if you don't list one, it disappears from the rendered config.
This is deliberate: partial merge leads to inconsistencies (the `plan` agent
expects a model that the `provider` block doesn't have, and the silent result
is a broken stage).

The example in `scripts/llm-providers.example.json` shows Anthropic + MiniMax
+ Ollama. It is the source of truth for the schema. `scripts/llm-defaults.json`
is also a source: if a field is missing in your override, copy it from there.

## 9. Ollama + OpenCodeRAG (auto-installed)

The installer automatically handles Ollama and the embedding model required
for the `opencode-rag-plugin` to work. This step runs between the
prerequisites and the model auto-discovery (step 0.3 in
`Install-Orchestration.ps1`) and **does not block** the install on failure.

What happens with `-Force`:

1. **Ollama missing?** Installs silently via the official script
   (`irm https://ollama.com/install.ps1 | iex`). On failure, falls back to
   downloading `OllamaSetup.exe` directly with `/VERYSILENT /NORESTART /SP-`
   flags.
2. **Service not running?** Starts `ollama serve` in the background and waits
   up to 120s for port 11434 to respond.
3. **Model `nomic-embed-text:latest` missing?** Runs
   `ollama pull nomic-embed-text:latest` (~274 MB on first pull).
4. **Health check.** Sends a test embedding to
   `http://localhost:11434/api/embeddings` and validates the returned vector
   has dimension > 0.

If any step fails, the installer prints manual instructions and continues
with the rest of the orchestration normally.

### Run manually (if auto didn't work)

```powershell
# Install Ollama
irm https://ollama.com/install.ps1 | iex

# Start service (if it didn't come up automatically)
ollama serve

# Pull embedding model (in another terminal)
ollama pull nomic-embed-text:latest

# Verify
ollama list
```

### Skip Ollama during install

If you don't plan to use OpenCodeRAG and want to avoid the download:

```powershell
# Call Install-Ollama.ps1 directly with -SkipInstall
.\scripts\Install-Ollama.ps1 -Force -SkipInstall
```

Or simply remove `ollama` from `enabled_providers` in
`config/llm-providers.json` — the installer only attempts to install Ollama
if it is listed as a provider in the active manifest.

### Change the embedding model

```powershell
.\scripts\Install-Ollama.ps1 -Force -ModelName "mxbai-embed-large:latest"
```

Remember to update the `ollama` provider whitelist in
`config/llm-providers.json` to reflect the new model.

## 10. Dependencies the installer does not resolve

**Symlinks.** `payload-symlinks.template.json` lists the links the config
expects. Re-creating them on Windows requires Developer Mode or an elevated
shell, which cannot be assumed on a new machine, so the installer tries to
create and reports instead of pretending it succeeded. Today there is one:
`skills/archify` -> `~/.agents/skills/archify`.

**Quests plugin source.** The payload ships
`plugins/opencode-quests.ts`, the flattened file opencode loads — self-
contained, sufficient for the orchestration to work. The source directory
`plugins/opencode-quests/` **does not** come: it lives in a separate internal
repository (upstream
[lirrensi/opencode-quests](https://github.com/lirrensi/opencode-quests) with
local patches in the `fork/stage-routing` branch). It is only needed to
develop the plugin, not to use it.

**Local skills.** Every global skill in `payload/skills/` must also be at
`~/.agents/skills/` for the symlinks to resolve. The installer does not touch
`~/.agents/`.

## 11. After installing

Confirm that per-stage routing hits the right model, instead of trusting the
configuration:

```bash
opencode
# in the TUI:
quest(file: "routing-probe")
```

The probe runs two stages on different models and the second repeats a token
the first one invented. How to verify the actual model via API metadata, not
by what the model says about itself: [`MEASUREMENTS.md`](MEASUREMENTS.md).

For the full usage guide (modes of `quest(...)`, slash command `/quest`,
operational rules, three ways to fire), see
[`docs/USAGE.md`](docs/USAGE.md).

Run one quest at a time. Quest state is process-global, not per session —
two concurrent quests split between sessions. Detail in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 12. Uninstall

```bash
npm uninstall -g opencode-orchestration
```

npm removes the global npm deps. `~/.config/opencode` keeps the config the
installer wrote — to clean it up manually, delete the folder (or use the
backup at `<repo>/_backup-<timestamp>/` in this repo as comparison).

To reinstall from scratch after uninstalling:

```bash
git clone <this-repo>
cd opencode-orchestration
npm install -g .
```
