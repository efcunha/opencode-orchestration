# Measurements

Detailed record of what was measured on 2026-08-18, with method and raw data.
The summary is in the README; what is here is what lets you verify instead of
trust.

> **Language:** Also available in Portuguese
> ([`MEASUREMENTS.md`](MEASUREMENTS.md)).

## Method

Two questions, two instruments.

**Does routing reach the target model?** Confirmed by **API metadata**, not by
self-report. The opencode server exposes, per message, the `providerID` and
`modelID` that served that turn:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1   # in another window
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

Model self-report was collected in parallel, but only as secondary
confirmation. A model can mis-identify itself; the server metadata has no
opinion.

**Does context survive the handoff?** Stage A **invents** a token at runtime,
of the form `A-NNNNN-NNNNN`, and stage B — on another model — must quote it
verbatim. The token does not exist on disk anywhere, so if B quotes it, it
could only have come through context. This closes the only contamination
channel that existed in a previous version of the instrument, where the
token was in the YAML itself and B could have read it.

Quests used: `routing-probe` (two stages, two models) and `override-probe`
(one stage, with `model` diverging from the agent's model).

## Result — routing and context

| # | Session | Stage A (API) | Token | Stage B (API) | `PRIOR_TOKEN` |
|---|---|---|---|---|---|
| 1 | `ses_fe9be122a` | `deepseek/deepseek-v4-pro` | `A-73941-28560` | `minimax-coding-plan/MiniMax-M3` | `A-73941-28560` |
| 2 | `ses_fe9bc589d` | `deepseek/deepseek-v4-pro` | `A-73914-62805` | `minimax-coding-plan/MiniMax-M3` | `A-73914-62805` |
| 3 | `ses_fe9bbc19a` | `deepseek/deepseek-v4-pro` | `A-74092-31658` | `minimax-coding-plan/MiniMax-M3` | `A-74092-31658` |
| 4 | `ses_fe9b9f6b3` | `deepseek/deepseek-v4-pro` | `A-73914-82605` | `minimax-coding-plan/MiniMax-M3` | `A-73914-82605` |
| 5 | `ses_fe9b8c4bc` | `deepseek/deepseek-v4-pro` | `A-73921-48065` | `minimax-coding-plan/MiniMax-M3` | `A-73921-48065` |

**5 of 5** on both questions.

## Result — model override

The five runs above did not test override: `agent: plan` came with
`deepseek-v4-pro` and `agent: build` with `MiniMax-M3` — exactly the models
those agents already declare in the config. If the server ignored the
stage's `model` and used the agent's, the result would be identical and
nothing would reveal it.

`override-probe` isolates the question: `agent: build` (configured to M3)
with `model: deepseek/deepseek-v4-flash`.

| Session | Expected | API reported | Self-report |
|---|---|---|---|
| `ses_fe9af8936` | `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4-flash` | `deepseek-v4-flash` |

The stage's `model` wins.

## The false negatives

Two earlier measurements reported `NO_CONTEXT` and **both were wrong** —
instrument error, not system error.

The old instruction said the only valid source was the text delivered by the
quest engine. That led the model to reason about design instead of inspecting
its own context. In `ses_fe9c8cfb4`, the model wrote in its reasoning:

> However, the routing probe is specifically testing whether the routed stage
> has access to the previous stage's context. [...] The instruction text
> delivered to me by the quest engine is the only valid source.

And before that, in the same message, it had quoted:

> I (this same assistant) in the prior turn DID write: `TOKEN_SEEN: A-31517-26261`

In other words: it had the token in view, reproduced it, and concluded
absence. The other case, `ses_fe9c41c83`, was a parsing error on my side —
the regex caught the quoted block instead of the answer; re-reading, the
value was correct and the run was positive.

Correction applied to the instrument: the instruction now says to report
what is **literally present** in the context, forbids reasoning about how
quests "should" work, and warns that declaring `NO_CONTEXT` with the value
visible is the worst possible outcome because it corrupts the measurement.

Lesson that goes beyond this case: an instrument that suggests the conclusion
contaminates the measurement. Asking "what do you see?" gets a different
answer than "should you be seeing this?".

## Observed anomalies

**Quest split between sessions.** I fired overlapping runs and one quest got
split: `ses_fe9bb28ac` received only `probe-a`, `ses_fe9bb05dd` only
`probe-b`. The `NO_CONTEXT` reported by the latter was **correct** — that
session never had stage A. The cause is quest state being process-global. It
does not count as a context failure.

**Stage lost in headless.** Four sessions ended up with only `probe-a`
(`fe9bb28ac`, `fe9b8897c`, `fe9ca1636`, `fe9ca47b2`). It is the cost of the
dispatch deferral on `session.idle`: the `opencode run` client exits before
the event fires. Roughly 1 in 3 in headless; not observed in a persistent
TUI.

**Duplicate delivery.** Some sessions received the same stage twice
(`fe9bc589d` with `probe-b` duplicated, `fe9b8897c` with `probe-a`
duplicated), despite the `cancelDwell` guard. Not investigated in depth.

**Malformed tool call serialization in M3.** MiniMax M3 outputs sometimes
carry template artifacts like `]<]minimax[>[<tool_call>`. `quest_advance`
still registered as a tool part in the affected runs. This is from the
provider, not the plugin.

## A configuration defect the measurement exposed

When checking which DeepSeek models actually respond:

```
deepseek-v4-flash       => OK
deepseek-v4-flash-free  => FAILED — "The supported API model names are
                           deepseek-v4-pro or deepseek-v4-flash, but you
                           passed deepseek-v4-flash-free."
deepseek-v4-pro         => OK
```

The global `small_model` pointed at `deepseek-v4-flash-free`, a model that
never existed. That is why it was in the `whitelist` with no corresponding
entry in the `models` block.

`small_model` is the highest-frequency slot: session title, summarization,
compaction. An invalid reference does not fail at config load — it fails on
the first call, silently.

Fixed to `deepseek/deepseek-v4-flash`. And the lesson became automatic
verification: `Test-Orchestration.ps1` now checks **every** model reference
against the list opencode resolves.

## Reproduce

```powershell
# terminal 1
opencode serve --port 4599 --hostname 127.0.0.1

# terminal 2
opencode run --attach http://127.0.0.1:4599 --dir <project> --auto 'quest(file: "routing-probe")'
Start-Sleep -Seconds 70

# read the metadata
$s = (Invoke-RestMethod "http://127.0.0.1:4599/session")[0]
Invoke-RestMethod "http://127.0.0.1:4599/session/$($s.id)/message" |
  Where-Object { $_.info.role -eq 'assistant' } |
  ForEach-Object {
      $t = ($_.parts | Where-Object { $_.type -eq 'text' }).text -join "`n"
      "$($_.info.providerID)/$($_.info.modelID) :: $($t -replace '\s+',' ')"
  }
```

One quest at a time. Overlapping runs split the quest between sessions and
produce data that looks like context failure without being one.
