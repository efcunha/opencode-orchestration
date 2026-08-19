---
name: form-browser-validation
description: Mandatory Playwright-driven validation of every CloudPilot form — empty state, happy path, sad path, with auto-correction of in-scope defects. Load whenever a browser session touches a form, runs homologação local, or performs a smoke test.
---

## Form Browser Validation (opencode skill)

This skill fires whenever opencode opens the browser to inspect CloudPilot.
The canonical rule lives at `.kiro/steering/form-browser-validation.md`
(loaded via AGENTS.md automatically). This skill is the opencode-specific
trigger and protocol summary.

## When to load

Load this skill if **any** of these match the current task:

- Task involves browser navigation via `playwright_browser_*` tools.
- Task is homologação local (step 3 of `cloudpilot-context.md` pipeline).
- Task touches a form under `frontend/src/routes/_auth/**`.
- User asks to "validate", "review", "smoke test", or "homologar" any form.

## Protocol (condensed)

For every form reachable from the routes in `frontend/docs/routes.md`:

### 1. Locate

```
playwright_browser_snapshot
playwright_browser_find text="<form label>"
```

Verify the form has stable accessibility hooks (`aria-label`, `<form>`,
testid). Missing hooks = defect.

### 2. Empty state (no rows / no config / no credentials)

| Check | Tool | Pass |
|-------|------|------|
| No console errors | `playwright_browser_console_messages level=error` | 0 errors |
| No 4xx/5xx in Network | `playwright_browser_network_requests filter="/api/"` | only auth/GET 200/401 |
| Submit disabled OR explanatory message | snapshot | yes |
| Helper text on required fields | snapshot | present |
| No raw error strings visible | snapshot | no `undefined`/`NaN`/`Error:` |

### 3. Happy path (valid values)

Fill all inputs → submit → verify success state visible + row appears in
list/detail + 0 console errors during submit.

### 4. Sad path (one required field invalid per round)

For each round: inline error appears, focus moves to first invalid field,
no POST is fired, error copy is human (no `undefined`, no raw HTTP status).

### 5. Auto-correct

- Frontend cosmetic / logic fix → fix in same PR.
- Backend contract mismatch → open follow-up task in
  `.kiro/specs/<slug>/tasks.md`, link to validation report.
- Multi-system (RLS, Celery, migrations) → never auto-fix from browser
  session; log and ask user.

Re-run the full loop for the form after every correction.

## Persist to memory

Append a new entry to `.kiro/memories/insights/form-browser-validation.md`
using the schema defined there. Also store a knowledge-graph entity via
`mcp-igniter_store_memory` (type=`user_preference`, tags=
`form-validation,browser,homologacao,playwright`).

## Boundaries

- **Auth walls**: log `blocked-by-auth` and move on. Never bypass SSO/MFA.
- **Destructive forms**: never submit delete / disconnect / revoke with
  real data. Use empty-state path or a dedicated test workspace.
- **Production**: only with explicit user authorization per
  `cloudpilot-context.md` rule 3.
- **Out of scope**: pure read-only pages follow existing E2E specs in
  `frontend/e2e/`.

## Quick checklist

```
[ ] Empty state: 0 console errors, 0 unexpected 4xx/5xx
[ ] Happy path: submit → success visible → row appears
[ ] Sad path: each required field → inline error → no POST
[ ] Auto-corrections applied (or follow-up spec created)
[ ] Memory entry appended to .kiro/memories/insights/form-browser-validation.md
[ ] Knowledge-graph entity stored via mcp-igniter_store_memory
```

## Source of truth

- Steering (always loaded): `.kiro/steering/form-browser-validation.md`
- Persistent memory (file): `.kiro/memories/insights/form-browser-validation.md`
- AGENTS.md DoD entry: `AGENTS.md:151`