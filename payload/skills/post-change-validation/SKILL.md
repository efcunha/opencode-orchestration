---
name: post-change-validation
description: Mandatory full-stack browser validation after any backend or frontend code change — rebuild ALL containers, flush stale caches, trigger Celery sync, validate ALL 8 pages, diagnose failures. Load whenever a backend/*.py file is edited, docker compose rebuilds, or the user asks for "análise e revisão" / "validação" / homologação.
---

## Post-Change Validation (opencode skill)

This skill fires whenever opencode finishes a backend or frontend code change.
The canonical rule lives at `.kiro/steering/post-change-validation.md`
(`inclusion: always` for Kiro sessions). This skill is the opencode-specific
trigger and protocol summary.

**Classifying broken pages as "acceptable" is FORBIDDEN** unless they match
the "Acceptable empty" column in the validation table below.

## When to load

Load this skill if **any** of these match the current task:

- Task edited `backend/**/*.py` or `frontend/src/**`.
- Task ran `docker compose up` / `docker compose build` / rebuild.
- User asks to "validate", "review", "homologar", "smoke test", or "análise e revisão".
- Task is the final step of an implementation phase or task list.

## Protocol (execute in this exact order)

### Step 0 — Rebuild ALL containers that share code

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.local.yml \
  up -d --force-recreate --no-deps backend celery_worker celery_beat
```

**NEVER rebuild only backend.** The celery_worker and celery_beat share
the same Python codebase. If you change `backend/app/**`, ALL THREE must
restart.

### Step 1 — Flush stale caches

```bash
docker compose exec redis redis-cli -a cloudpilot_redis KEYS "swr:*" | \
  ForEach-Object { docker compose exec redis redis-cli -a cloudpilot_redis DEL $_ }
docker compose exec redis redis-cli -a cloudpilot_redis KEYS "dashboard:*" | \
  ForEach-Object { docker compose exec redis redis-cli -a cloudpilot_redis DEL $_ }
docker compose exec redis redis-cli -a cloudpilot_redis DEL \
  "ce_budget:24c5b7f5-99b7-480d-b418-57640c6128ce:$(Get-Date -Format 'yyyy-MM-dd')"
```

### Step 2 — Wait for backend healthy

```bash
docker compose ps --format "table {{.Name}}\t{{.Status}}" | Select-String "backend"
# Must show "(healthy)" before proceeding
```

### Step 3 — Trigger budget actuals sync

```bash
docker compose exec backend /bin/bash -c \
  'python -c "from app.tasks.budget_actuals_sync import sync_all_budget_actuals; print(sync_all_budget_actuals())"'
```

Wait 30 seconds for celery_worker to process.

### Step 4 — Login and validate ALL pages

Login: `admin@cloudpilot.io` (password from MCP Memory entity
"CloudPilot Local Login").

For EACH page below, navigate, wait 8-12s for data load, then verify:

| Page | Route | MUST show non-zero | Acceptable empty |
|------|-------|-------------------|------------------|
| Dashboard | /dashboard | "Total em Custos" ≠ $0, "Contas Conectadas" > 0 | "Nenhuma atividade recente" |
| Custos | /costs | "Custo Total" ≠ $0, breakdown table with $X.XX values | — |
| FinOps | /finops | "Gasto Acumulado" ≠ $0, "Em Risco" or "No Prazo" > 0 | — |
| Security | /security | "Score de Segurança" ≠ 0, findings count > 0 | — |
| K8s FinOps | /finops/kubernetes | "Total Monthly Cost" ≠ $0 | — |
| Drift | /finops/drift | "Cobertura IaC" percentage shown | "Nunca escaneado" for last scan |
| Operations | /operations | "Cost Today" ≠ $0, "Accounts" > 0 | — |
| Compliance | /compliance | CIS controls listed, findings present | — |

### Step 5 — Verify console and network

```
playwright_browser_console_messages level=error  → MUST be 0
playwright_browser_network_requests filter="/api/" → ALL must be 200 OK
```

### Step 6 — If ANY check fails: diagnose and fix

**DO NOT classify as "acceptable" unless it matches the "Acceptable empty"
column above.** If a value shows $0 or "Data unavailable" when it SHOULD
have data:

1. Check Redis `ce_budget:{workspace_id}:{date}` — if ≥ 200, budget exhausted
2. Check `swr:costs:unified:*` — if contains `budget_exceeded:true`, flush
3. Check celery_worker logs for `payer_consolidation_failed` — note the error
4. Check if end_date exceeds today (AWS CE rejects future dates)
5. Check if UUID↔AWS account number mapping is correct in decomposer output

**Fix the code, rebuild ALL containers, re-run from Step 0.**

## Known Pitfalls (learn from past mistakes)

| Mistake | Correct behavior |
|---------|-----------------|
| Restart only backend after code change | Restart backend + celery_worker + celery_beat |
| Declare "$0 is acceptable because no sync ran" | Trigger sync manually and verify data appears |
| Say "decomposer mapping is pre-existing, not my bug" | If it blocks validation, fix it NOW |
| Check only /costs/unified response | Also trigger budget_actuals_sync and verify /finops |
| First SWR request shows `_warming:true` with $0 | Wait 15s, reload — second request must show real data |
| Budget counter at limit after trend fan-out | Payer consolidation must use `is_daily_sync=True` |

## Architecture: How Cost Data Flows

```
AWS CE API
    ↓ (1 payer call via PayerQueryConsolidator)
ResponseDecomposer.decompose()
    ↓ (keys: AWS account numbers like "713291430945")
multicloud_dashboard.get_unified_costs()
    ↓ (maps: acc.external_account_id → decomposed result)
SWR cache (Redis: swr:costs:unified:{workspace}:...)
    ↓
/costs/unified endpoint → frontend Custos page

AWS CE API (same payer call, or from CostCacheManager payer cache)
    ↓
budget_actuals_sync._try_payer_consolidation()
    ↓ (maps: cloud_account UUID → AWS number via uuid_to_aws_number reverse map)
_materialize_consolidation_from_payer_response()
    ↓
budget_cost_snapshots table (spent_usd per budget)
    ↓
/finops/budgets endpoint → frontend FinOps page
```

## Config That Must Be Correct Locally

| Setting | Value | Where |
|---------|-------|-------|
| COST_EXPLORER_DAILY_BUDGET | 200 | docker-compose.local.yml (backend env) |
| CE_DAILY_CALL_LIMIT (hard cap) | 100 | backend/app/config.py (default) |
| Redis password | cloudpilot_redis | docker-compose.yml |
| Workspace ID (primary) | 24c5b7f5-99b7-480d-b418-57640c6128ce | DB |
| Payer account | fc853b96-5d39-439c-9dba-ec9cfddd05fe (713291430945) | DB |

## Boundaries

- **Production**: never run this protocol against Railway. Only local.
- **Auth walls**: if a page redirects to login, log `blocked-by-auth` and
  move on. Never bypass SSO/MFA.
- **Destructive actions**: never submit disconnect / revoke with real data.
  Use a dedicated test workspace.
- **Out of scope**: per-form validation follows the
  `form-browser-validation` skill (separate concern).

## Quick checklist

```
[ ] Step 0: backend + celery_worker + celery_beat all rebuilt
[ ] Step 1: swr:*, dashboard:*, ce_budget:* flushed
[ ] Step 2: backend container shows "(healthy)"
[ ] Step 3: sync_all_budget_actuals() ran, 30s waited
[ ] Step 4: ALL 8 pages visited, MUST-show values verified
[ ] Step 5: 0 console errors, 0 4xx/5xx on /api/*
[ ] Step 6: any failure diagnosed + fixed + re-run from Step 0
[ ] Memory entry appended (if a new pitfall was discovered)
```

## Persist to memory

If a new pitfall or diagnostic step is discovered during validation,
append to `.kiro/memories/insights/post-change-validation.md` (create the
file if needed) and store a knowledge-graph entity via
`mcp-igniter_store_memory` (type=`bug_pattern`,
tags=`post-change-validation,homologacao,playwright,docker`).

## Source of truth

- Steering (always loaded in Kiro): `.kiro/steering/post-change-validation.md`
- This skill: `.opencode/skills/post-change-validation/SKILL.md`
- Pipeline rule (high level): `AGENTS.md` rule 1 "Homologação local-first"