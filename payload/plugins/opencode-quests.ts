// ═══════════════════════════════════════════════════════
//  Quest Plugin — labeled multi-next branching + context.
//  Pattern: TUI injection + idle-driven re-fire.
//  Prison-grade: agent cannot exit until quest complete.
// ═══════════════════════════════════════════════════════

import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"
import { execSync } from "child_process"
import { parse as parseYaml } from "yaml"
import { readFileSync, readdirSync, existsSync } from "node:fs"
import { join } from "node:path"
import { homedir } from "node:os"

const z = tool.schema

// ── types ──

type Stage = {
  id: string
  description?: string
  instruction?: string
  checklist?: string[]
  context?: string
  /** Route this stage to a named agent from opencode.json "agent". */
  agent?: string
  /** Route this stage to an explicit model, "providerID/modelID". */
  model?: string
  /** Next stage(s). String = shorthand for {default: target}. Record = labeled exits. */
  next?: string | Record<string, string>
}

type Quest = {
  name: string
  description?: string
  context?: string
  stages: Stage[]
}

type QuestState = {
  quest: Quest
  currentStageId: string
  startedAt: number
  paused: boolean
  /** The user's task/request, captured from the `input` tool arg. Shown to every stage. */
  input?: string
}

// ── constants ──

const DWELL_MS = 10_000
const HEARTBEAT_MS = 10_000
const FIRE_DEFER_MS = 100
const AGENTS_DIR = ".agents"

// ── helpers: yaml loading ──

/** User-global quest dir. Quests here are visible from every project. */
const GLOBAL_QUEST_DIR = join(homedir(), ".config", "opencode", "agents")

/**
 * Project-scoped root. Prefer the session's project directory
 * (ToolContext.directory) over process.cwd(): the opencode server's cwd is
 * whatever shell launched it, which is not necessarily the project.
 */
function questDir(cwd?: string): string {
  return join(cwd ?? process.cwd(), AGENTS_DIR)
}

/**
 * Candidate roots in PRECEDENCE ORDER: project first, then user-global.
 * A project quest shadows a global one with the same filename, so a repo can
 * override a shared quest without editing the global copy.
 */
function questDirs(cwd?: string): string[] {
  const project = questDir(cwd)
  return project === GLOBAL_QUEST_DIR ? [project] : [project, GLOBAL_QUEST_DIR]
}

/** Filename variants to try for a bare quest name. */
function fileCandidates(file: string): string[] {
  const candidates = [file]
  if (!file.endsWith(".yaml") && !file.endsWith(".yml")) {
    candidates.push(`${file}.yaml`, `${file}.yml`)
  }
  // Security: prevent path traversal — quest names are flat filenames only.
  return candidates.filter(n => !n.includes("..") && !n.includes("/") && !n.includes("\\"))
}

function resolveQuestFile(file: string, cwd?: string): string | null {
  for (const dir of questDirs(cwd)) {
    for (const name of fileCandidates(file)) {
      const fullPath = join(dir, name)
      if (existsSync(fullPath)) return fullPath
    }
  }
  return null
}

function resolveQuestByName(name: string, cwd?: string): { quest: Quest; path: string } | string {
  const dirs = questDirs(cwd)
  const target = name.trim().toLowerCase()
  const seen: string[] = []

  for (const dir of dirs) {
    if (!existsSync(dir)) continue
    let files: string[]
    try { files = readdirSync(dir) } catch { continue }
    const yamlFiles = files.filter(f => (f.endsWith(".yaml") || f.endsWith(".yml")) && !f.includes(".."))
    seen.push(...yamlFiles)

    for (const file of yamlFiles) {
      const fullPath = join(dir, file)
      try {
        const content = readFileSync(fullPath, "utf8")
        const doc = parseYaml(content)
        if (doc && doc.kind === "quest" && typeof doc.name === "string" && doc.name.trim().toLowerCase() === target) {
          const result = validateQuestSchema(doc)
          if (typeof result === "string") continue
          return { quest: result, path: fullPath }
        }
      } catch { continue }
    }
  }

  const where = dirs.join(" and ")
  return seen.length > 0
    ? `No quest found with name "${name}". Searched ${where}. Files seen: ${seen.map(f => `"${f}"`).join(", ")}`
    : `No quest found with name "${name}". Searched ${where} — no .yaml files in either.`
}

function loadQuestFromFile(file: string, cwd?: string): { quest: Quest; path: string } | string {
  const resolved = resolveQuestFile(file, cwd)
  if (!resolved) return `No quest file "${file}" in ${questDirs(cwd).join(" nor ")}`

  let doc: any
  try {
    const content = readFileSync(resolved, "utf8")
    doc = parseYaml(content)
  } catch (e: any) {
    return `Failed to parse ${resolved}: ${e.message}`
  }

  if (!doc || doc.kind !== "quest") {
    return `File ${resolved} is not a quest (missing or wrong "kind" field).`
  }

  const result = validateQuestSchema(doc)
  if (typeof result === "string") return result
  return { quest: result, path: resolved }
}

/**
 * Quest filenames visible from this session, project root first.
 * Deduped by filename: a project file shadows the global one, and the shadowed
 * global copy is NOT listed twice.
 */
function listQuestFiles(cwd?: string): string[] {
  const out: string[] = []
  for (const dir of questDirs(cwd)) {
    if (!existsSync(dir)) continue
    try {
      for (const f of readdirSync(dir)) {
        if (!f.endsWith(".yaml") && !f.endsWith(".yml")) continue
        if (f.includes("..")) continue
        if (!out.includes(f)) out.push(f)
      }
    } catch { continue }
  }
  return out
}

// ── helpers: model routing ──

/**
 * Parse a "providerID/modelID" reference into the shape the SDK expects.
 * Splits on the FIRST slash so nested model ids survive (e.g. "openrouter/a/b").
 * Returns undefined when the ref is absent or malformed.
 */
function parseModelRef(ref?: string): { providerID: string; modelID: string } | undefined {
  if (typeof ref !== "string") return undefined
  const trimmed = ref.trim()
  const i = trimmed.indexOf("/")
  if (i < 1 || i === trimmed.length - 1) return undefined
  return { providerID: trimmed.slice(0, i), modelID: trimmed.slice(i + 1) }
}

/** True when a stage asks to be run somewhere other than the current agent. */
function stageNeedsRouting(stage?: Stage): boolean {
  return Boolean(stage?.agent || stage?.model)
}

/** Human-readable routing target, for handoff notices and toasts. */
function describeRoute(stage: Stage): string {
  const parts: string[] = []
  if (stage.agent) parts.push(`agent="${stage.agent}"`)
  if (stage.model) parts.push(`model="${stage.model}"`)
  return parts.join(" ") || "(none)"
}

// ── helpers: schema validation ──

function validateQuestSchema(doc: any): Quest | string {
  if (!doc || typeof doc !== "object") return "Schema error: expected an object."
  if (doc.kind !== "quest") return `Schema error: kind must be "quest".`
  if (typeof doc.name !== "string" || !doc.name.trim()) return "Schema error: name is required."
  if (doc.description !== undefined && typeof doc.description !== "string") return "Schema error: description must be a string."
  if (doc.context !== undefined && typeof doc.context !== "string") return "Schema error: context must be a string."
  if (!Array.isArray(doc.stages) || doc.stages.length === 0) return "Schema error: stages must be a non-empty array."

  const stageIds = new Set<string>()
  const stageNexts: { id: string; rawNext: string | Record<string, string> | undefined }[] = []

  for (let i = 0; i < doc.stages.length; i++) {
    const s = doc.stages[i]
    if (!s || typeof s !== "object") return `Schema error: stages[${i}] must be an object.`
    if (typeof s.id !== "string" || !s.id.trim()) return `Schema error: stages[${i}].id is required.`
    if (stageIds.has(s.id)) return `Schema error: duplicate stage id "${s.id}".`
    stageIds.add(s.id)
    if (s.description !== undefined && typeof s.description !== "string") return `Schema error: stages[${i}].description must be a string.`
    if (s.instruction !== undefined && typeof s.instruction !== "string") return `Schema error: stages[${i}].instruction must be a string.`
    if (s.checklist !== undefined) {
      if (!Array.isArray(s.checklist)) return `Schema error: stages[${i}].checklist must be an array.`
      for (let j = 0; j < s.checklist.length; j++) {
        if (typeof s.checklist[j] !== "string") return `Schema error: stages[${i}].checklist[${j}] must be a string.`
      }
    }
    if (s.context !== undefined && typeof s.context !== "string") return `Schema error: stages[${i}].context must be a string.`
    if (s.agent !== undefined) {
      if (typeof s.agent !== "string") return `Schema error: stages[${i}].agent must be a string.`
      if (!s.agent.trim()) return `Schema error: stages[${i}].agent cannot be empty.`
    }
    if (s.model !== undefined) {
      if (typeof s.model !== "string") return `Schema error: stages[${i}].model must be a string.`
      if (!s.model.trim()) return `Schema error: stages[${i}].model cannot be empty.`
      if (!parseModelRef(s.model)) return `Schema error: stages[${i}].model must be "providerID/modelID", got "${s.model}".`
    }

    if (s.next !== undefined) {
      if (typeof s.next === "string") {
        if (!s.next.trim()) return `Schema error: stages[${i}].next cannot be empty.`
      } else if (typeof s.next === "object" && !Array.isArray(s.next)) {
        const entries = Object.entries(s.next)
        if (entries.length === 0)
          return `Schema error: stages[${i}].next cannot be empty (no labels).`
        for (const [label, target] of entries) {
          if (typeof target !== "string" || !target.trim())
            return `Schema error: stages[${i}].next["${label}"] must be a non-empty string.`
        }
      } else {
        return `Schema error: stages[${i}].next must be a string or an object with labeled exits.`
      }
    }

    stageNexts.push({ id: s.id, rawNext: s.next })
  }

  for (const { id, rawNext } of stageNexts) {
    if (rawNext === undefined) continue
    const targets: string[] = typeof rawNext === "string"
      ? [rawNext.trim()]
      : Object.values(rawNext).map((v: any) => v.trim())
    for (const target of targets) {
      if (!stageIds.has(target))
        return `Schema error: stage "${id}" next target "${target}" does not exist.`
    }
  }

  return {
    name: doc.name.trim(),
    description: typeof doc.description === "string" ? doc.description.trim() : undefined,
    context: typeof doc.context === "string" ? doc.context.trim() : undefined,
    stages: doc.stages.map((s: any) => ({
      id: s.id.trim(),
      description: typeof s.description === "string" ? s.description.trim() : undefined,
      instruction: s.instruction?.trim(),
      checklist: s.checklist?.map((c: string) => c.trim()),
      context: typeof s.context === "string" ? s.context.trim() : undefined,
      agent: typeof s.agent === "string" ? s.agent.trim() : undefined,
      model: typeof s.model === "string" ? s.model.trim() : undefined,
      next: typeof s.next === "string"
        ? { default: s.next.trim() }
        : s.next
          ? Object.fromEntries(
              Object.entries(s.next).map(([k, v]) => [k, (v as string).trim()])
            )
          : undefined,
    })),
  }
}

// ── helpers: state machine ──

function getCurrentStage(state: QuestState): Stage | undefined {
  return state.quest.stages.find(s => s.id === state.currentStageId)
}

function getValidNext(state: QuestState): string[] {
  const stage = getCurrentStage(state)
  if (!stage?.next) return ["done"]
  if (typeof stage.next === "string") return [stage.next]
  return Object.values(stage.next)
}

function getNextLabels(state: QuestState): Record<string, string> | undefined {
  const next = getCurrentStage(state)?.next
  return typeof next === "string" ? undefined : next
}

function isValidTransition(state: QuestState, targetId: string): boolean {
  return getValidNext(state).includes(targetId)
}

function stageIndex(state: QuestState): number {
  return state.quest.stages.findIndex(s => s.id === state.currentStageId)
}

function totalStages(state: QuestState): number {
  return state.quest.stages.length
}

// ── helpers: formatting ──

function fmtElapsed(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  const m = Math.floor(s / 60), h = Math.floor(m / 60)
  if (s < 60) return `${s}s`
  if (m < 60) return `${m}m`
  if (m % 60 === 0) return `${h}h`
  return `${h}h ${m % 60}m`
}

function formatStageMessage(state: QuestState): string {
  const stage = getCurrentStage(state)
  const idx = stageIndex(state) + 1
  const total = totalStages(state)
  const lines: string[] = []

  // Header
  lines.push("━".repeat(40))
  lines.push(`Quest: ${state.quest.name}`)
  if (state.quest.description) lines.push(state.quest.description)
  lines.push("━".repeat(40))

  // Stage header
  if (stage?.description) {
    lines.push(`📋 Stage: ${stage.id} (${idx}/${total})`)
    lines.push(`     ${stage.description}`)
  } else {
    lines.push(`📋 Stage: ${stage?.id ?? "?"} (${idx}/${total})`)
  }
  lines.push("━".repeat(40))

  // Task block — the user's request, shown every message
  if (state.input) {
    lines.push("📋 Task:")
    lines.push(`  ${state.input}`)
    lines.push("━".repeat(40))
  }

  // Context block — shown every message
  if (state.quest.context || stage?.context) {
    lines.push("📋 Context:")
    if (state.quest.context) lines.push(`  ${state.quest.context}`)
    if (stage?.context) lines.push(`  ${stage.context}`)
    lines.push("━".repeat(40))
  }

  lines.push("")

  // Instruction
  if (stage?.instruction) {
    lines.push(stage.instruction)
    lines.push("")
  }

  // Checklist — loud, with todowrite directive
  if (stage?.checklist && stage.checklist.length > 0) {
    lines.push("━".repeat(40))
    lines.push("⚠️  CHECKLIST — you MUST call todowrite with these:")
    lines.push("━".repeat(40))
    for (const item of stage.checklist) {
      lines.push(`  ☐ ${item}`)
    }
    lines.push("")
  }

  // Next steps
  const validNext = getValidNext(state)
  const nextLabels = getNextLabels(state)

  lines.push("━".repeat(40))
  if (validNext[0] === "done") {
    lines.push('→ Final stage. Call quest_advance("done") to complete.')
  } else if (validNext.length === 1) {
    lines.push(`→ Next: ${validNext[0]}`)
    lines.push(`  Call quest_advance("${validNext[0]}") when ready.`)
  } else {
    lines.push("→ Options:")
    if (nextLabels) {
      const maxLabelLen = Math.max(...Object.keys(nextLabels).map(k => k.length))
      for (const [label, stageId] of Object.entries(nextLabels)) {
        lines.push(`   [${label}]${" ".repeat(maxLabelLen - label.length)} → ${stageId}`)
      }
    }
    const targets = validNext.map(v => `"${v}"`).join(" or ")
    lines.push(`  Call quest_advance(${targets}) when ready.`)
  }
  lines.push("━".repeat(40))

  return lines.join("\n")
}

function formatCompleteMessage(state: QuestState): string {
  const total = totalStages(state)
  const elapsed = fmtElapsed(Date.now() - state.startedAt)
  const lines: string[] = []
  lines.push("━".repeat(40))
  lines.push(`✅ Quest Complete: ${state.quest.name}`)
  lines.push(`   ${total}/${total} stages finished.`)
  lines.push(`   Started: ${elapsed} ago.`)
  lines.push("━".repeat(40))
  return lines.join("\n")
}

// ── helpers: backtick eval ──

const MAX_BACKTICK_OUTPUT_LENGTH = 2_000

function evaluateBackticks(msg: string): string {
  return msg.replace(/`([^`]+)`/g, (_m: string, cmd: string) => {
    const c = cmd.trim()
    if (!c) return ""
    try {
      const o = (execSync(c, {
        encoding: "utf-8", timeout: 30_000, windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
      }) as string).trim()
      if (!o) return "(no output)"
      if (o.length > MAX_BACKTICK_OUTPUT_LENGTH) {
        return o.slice(0, MAX_BACKTICK_OUTPUT_LENGTH) +
          `\n… [truncated, ${o.length} total chars]`
      }
      return o
    } catch (e: any) {
      return `(error: ${e.message.split("\n")[0]})`
    }
  })
}

// ═══════════════════════════════════════════════════════
//  Plugin
// ═══════════════════════════════════════════════════════

export const QuestPlugin: Plugin = async ({ client }: any) => {
  let state: QuestState | null = null
  let dwellTimer: ReturnType<typeof setTimeout> | null = null
  let dwellStartedAt = 0
  let isIdle = false
  let inFlight = false
  let hb: ReturnType<typeof setInterval> | null = null
  /** Needed by session.promptAsync for stage routing. Learned from ToolContext, or from events as a fallback. */
  let sessionID: string | null = null
  /**
   * Routed stage waiting for the caller's turn to close before being dispatched.
   *
   * Why deferred: quest_advance runs INSIDE the calling agent's turn. Dispatching
   * from there raced the runtime's persistence of that turn's message — measured
   * 2026-08-18 across three sessions, the routed stage saw the prior stage twice
   * and started with an empty conversation once. Firing on session.idle means the
   * previous turn is closed by definition when the new prompt is assembled.
   */
  let pendingDispatch: { stage: Stage; message: string } | null = null
  let dispatching = false
  /**
   * Watchdog: tracks whether a routed dispatch produced a quest_advance call.
   * When flushPendingDispatch fires successfully, dispatchedStageId is set.
   * On the NEXT session.idle, if dispatchedStageId is still set (meaning the
   * model's turn ended without calling quest_advance), the plugin treats the
   * stage as stalled — typically because Plan Mode blocked tool calls.
   *
   * Recovery: re-dispatch the same stage WITHOUT specifying agent, which sends
   * it to whatever agent the TUI is currently on (likely Build after the user
   * pressed Tab). If that also fails, fall back to TUI injection. The goal is
   * never stall silently.
   */
  let dispatchedStageId: string | null = null
  let dispatchedStageMessage: string | null = null
  let stallRetries = 0
  const MAX_STALL_RETRIES = 2

  // ── shared infra ──

  const toast = (m: string, v = "info", d = 5000) =>
    client.tui.showToast({ body: { message: m, variant: v, duration: d } }).catch(() => {})

  const cancelDwell = () => {
    if (dwellTimer) { clearTimeout(dwellTimer); dwellTimer = null; dwellStartedAt = 0 }
  }

  const startDwell = () => {
    if (!state || state.paused) return
    cancelDwell()
    dwellStartedAt = Date.now()
    dwellTimer = setTimeout(() => {
      dwellTimer = null
      dwellStartedAt = 0
      if (!state || state.paused) return
      fireReminder()
    }, DWELL_MS)
  }

  /**
   * Send a stage's message to a specific agent/model inside the current session.
   * Returns null on success, or a human-readable reason on failure.
   * The SDK does not throw on HTTP errors by default, so the response is inspected too.
   */
  const dispatchStage = async (stage: Stage, message: string): Promise<string | null> => {
    if (!sessionID) return "session id unknown (no ToolContext or message event seen yet)"
    if (typeof client?.session?.promptAsync !== "function")
      return "client.session.promptAsync unavailable in this opencode build"

    const body: Record<string, any> = { parts: [{ type: "text", text: message }] }
    if (stage.agent) body.agent = stage.agent
    const model = parseModelRef(stage.model)
    if (model) body.model = model

    try {
      const res: any = await client.session.promptAsync({ path: { id: sessionID }, body })
      if (res?.error) return typeof res.error === "string" ? res.error : JSON.stringify(res.error)
      return null
    } catch (e: any) {
      return e?.message ?? String(e)
    }
  }

  const fire = async (message: string, stage?: Stage) => {
    if (inFlight) return
    inFlight = true
    try {
      const msg = evaluateBackticks(message)
      if (stageNeedsRouting(stage)) {
        const failure = await dispatchStage(stage!, msg)
        if (!failure) return
        toast(`Quest routing failed (${describeRoute(stage!)}): ${failure} — using current agent`, "warning")
      }
      await client.tui.clearPrompt()
      await client.tui.appendPrompt({ body: { text: msg } })
      await client.tui.submitPrompt()
    } catch (e: any) {
      toast(`Quest fail: ${e.message}`, "error")
    } finally {
      inFlight = false
    }
  }

  const fireReminder = () => {
    if (!state) return
    return fire(formatStageMessage(state), getCurrentStage(state))
  }

  /**
   * Build the tool result for the stage the quest is now on.
   * Unrouted stages return the stage message inline — original behaviour, unchanged.
   * Routed stages are dispatched to their target and the caller gets only a handoff
   * notice, so two agents never execute the same instruction.
   */
  const deliverStage = async (): Promise<string> => {
    if (!state) return "No active quest."
    const message = formatStageMessage(state)
    const stage = getCurrentStage(state)
    if (!stageNeedsRouting(stage)) return message

    // Queue instead of dispatching now: see pendingDispatch for the race this avoids.
    pendingDispatch = { stage: stage!, message: evaluateBackticks(message) }
    return [
      `Stage "${stage!.id}" queued for ${describeRoute(stage!)}.`,
      `It is dispatched when your turn closes, so that agent sees your output.`,
      `End your turn now — do not perform the stage work yourself.`,
    ].join("\n")
  }

  /**
   * Send the queued stage once the caller's turn has closed. Falls back to TUI
   * injection if the routed dispatch is refused, so the stage is never lost —
   * the caller was already told to stop, and silence would stall the quest.
   */
  const flushPendingDispatch = async () => {
    if (!pendingDispatch || dispatching) return
    dispatching = true
    const { stage, message } = pendingDispatch
    pendingDispatch = null
    try {
      const failure = await dispatchStage(stage, message)
      if (!failure) {
        // Arm the watchdog: if the next session.idle arrives without
        // quest_advance clearing this, the stage stalled (Plan Mode).
        dispatchedStageId = stage.id
        dispatchedStageMessage = message
        return
      }
      toast(`Quest routing failed (${describeRoute(stage)}): ${failure} — delivering inline`, "warning")
      await client.tui.clearPrompt()
      await client.tui.appendPrompt({ body: { text: message } })
      await client.tui.submitPrompt()
    } catch (e: any) {
      toast(`Quest dispatch error: ${e?.message ?? String(e)}`, "error")
    } finally {
      dispatching = false
    }
  }

  const clear = () => {
    cancelDwell()
    state = null
    inFlight = false
    isIdle = false
    // Drop any queued dispatch: the quest is over (completed, stopped, or a new
    // session took over). Firing it would push a stage of a quest that no longer exists.
    pendingDispatch = null
    dispatching = false
    // Reset watchdog so a stale stall detection doesn't fire in a future quest
    dispatchedStageId = null
    dispatchedStageMessage = null
    stallRetries = 0
    if (hb) { clearInterval(hb); hb = null }
  }

  const refreshHb = () => {
    if (state && !state.paused && !hb) {
      hb = setInterval(() => {
        if (!state || state.paused) return
        const elapsed = fmtElapsed(Date.now() - state.startedAt)
        const dwellLeft = dwellStartedAt > 0
          ? Math.round((DWELL_MS - (Date.now() - dwellStartedAt)) / 1000)
          : 0
        const status = dwellStartedAt > 0
          ? `⏳ dwell ${dwellLeft}s → remind`
          : isIdle ? "🟢 idle" : "🔴 active"
        const stage = getCurrentStage(state)
        const idx = stageIndex(state) + 1
        const total = totalStages(state)
        toast(`Quest: ${state.quest.name} | Stage: ${stage?.id ?? "?"} (${idx}/${total}) | ${elapsed} | ${status}`, "info", 4000)
      }, HEARTBEAT_MS)
    } else if (!state && hb) {
      clearInterval(hb)
      hb = null
    }
  }

  const startQuest = (quest: Quest, input?: string) => {
    clear()
    state = {
      quest,
      currentStageId: quest.stages[0]!.id,
      startedAt: Date.now(),
      paused: false,
      input: input?.trim() ? input.trim() : undefined,
    }
    refreshHb()
    toast(`Quest started: "${quest.name}"`, "info", 4000)
  }

  // ── hooks ──

  return {
    config: async (cfg: any) => {
      cfg.command ??= {}
      cfg.command.quest = {
        template: "[status|pause|resume|stop]",
        description: "Show active quest status",
      }
    },

    tool: {
      quest: tool({
        description: `Start a quest. No args = help. Use file: to load by filename, name: to find by quest name, or schema: to create inline. Pass input: to hand the quest a task (shown to every stage).`,
        args: {
          file: z.string().optional().describe(`Load from ${AGENTS_DIR}/name.yaml (matches filename).`),
          name: z.string().optional().describe("Find and load a quest by its name field (case-insensitive, scans all .yaml files)."),
          schema: z.record(z.string(), z.any()).optional().describe("Create inline from schema object."),
          input: z.string().optional().describe("The user's task/request this quest should accomplish. Injected into every stage as a 'Task' block."),
        },
        execute: async (args: { file?: string; name?: string; schema?: Record<string, any>; input?: string }, context?: { sessionID?: string; directory?: string }) => {
          if (context?.sessionID) sessionID = context.sessionID
          const dir = context?.directory

          // ── file mode ──
          if (args.file !== undefined && args.file !== "") {
            const result = loadQuestFromFile(args.file.trim(), dir)
            if (typeof result === "string") {
              const files = listQuestFiles(dir)
              const hint = files.length > 0
                ? ` Available files: ${files.join(", ")}`
                : ` No .yaml files in ${questDirs(dir).join(" nor ")} — is the session rooted at the right project?`
              return result + hint
            }
            startQuest(result.quest, args.input)
            return `Quest "${result.quest.name}" loaded from ${result.path}.\n\n${await deliverStage()}`
          }

          // ── name mode ──
          if (args.name !== undefined && args.name !== "") {
            const result = resolveQuestByName(args.name.trim(), dir)
            if (typeof result === "string") return result
            startQuest(result.quest, args.input)
            return `Quest "${result.quest.name}" loaded from ${result.path}.\n\n${await deliverStage()}`
          }

          // ── schema mode ──
          if (args.schema !== undefined) {
            const result = validateQuestSchema(args.schema)
            if (typeof result === "string") return result
            startQuest(result, args.input)
            return `Quest "${result.name}" created.\n\n${await deliverStage()}`
          }

          // ── help mode ──
          const files = listQuestFiles(dir)
          const fileList = files.length > 0
            ? files.map(f => `  - ${f}`).join("\n")
            : `  (no .yaml files found)`
          return `quest — start or manage a quest.

Usage:
  quest()                  → this help
  quest(file: "filename")  → load from ${AGENTS_DIR}/filename.yaml
  quest(name: "Quest Name")→ find by quest name (scans all files)
  quest(schema: {...})     → create inline from schema object
  quest(..., input: "...") → pass the user's task (shown to every stage)

Searching (project first, then global):
${questDirs(dir).map(d => `  ${d}`).join("\n")}

Available quest files:
${fileList}

Active quest commands: /quest [status|pause|resume|stop]`
        },
      }),

      quest_advance: tool({
        description: `Advance to the next stage. Pass "done" on the final stage to complete the quest.`,
        args: {
          stage: z.string().describe("Stage id to advance to. Use 'done' on final stage."),
        },
        execute: async (args: { stage: string }, context?: { sessionID?: string }) => {
          if (context?.sessionID) sessionID = context.sessionID
          if (!state) return "No active quest. Use quest() to start one."

          // ── Clear stall watchdog: quest_advance was called, so the stage ran ──
          dispatchedStageId = null
          dispatchedStageMessage = null
          stallRetries = 0

          const target = args.stage.trim()
          if (!isValidTransition(state, target)) {
            const valid = getValidNext(state)
            return `Cannot advance to "${target}". Expected: ${valid.map(v => `"${v}"`).join(" or ")}.`
          }

          if (target === "done") {
            const msg = formatCompleteMessage(state)
            const questName = state.quest.name
            clear()
            toast(`Quest complete: "${questName}"`, "info", 6000)
            return msg
          }

          state.currentStageId = target
          cancelDwell()
          return await deliverStage()
        },
      }),
    },

    event: async ({ event }: any) => {
      const t = event.type
      const p = event.properties || event.data || {}

      if (t === "message.updated") {
        const sid = p?.info?.sessionID
        if (typeof sid === "string" && sid) sessionID = sid
        if (p?.info?.role === "assistant") {
          isIdle = false
          cancelDwell()
        }
        return
      }

      if (t === "session.idle") {
        isIdle = true
        inFlight = false

        // ── Stall detection (Plan Mode watchdog) ──
        // If we dispatched a stage and the model's turn ended without calling
        // quest_advance, the stage stalled. Recover by re-dispatching without
        // a specific agent (goes to whatever the TUI is currently on), or fall
        // back to TUI injection after MAX_STALL_RETRIES.
        if (dispatchedStageId && !pendingDispatch && state) {
          stallRetries++
          const stageId = dispatchedStageId
          const msg = dispatchedStageMessage!
          dispatchedStageId = null
          dispatchedStageMessage = null

          if (stallRetries <= MAX_STALL_RETRIES) {
            toast(`Stage "${stageId}" stalled (Plan Mode?) — retry ${stallRetries}/${MAX_STALL_RETRIES} on current agent`, "warning")
            // Re-dispatch without agent/model — goes to whatever mode the TUI is on now
            const body: Record<string, any> = { parts: [{ type: "text", text: msg }] }
            try {
              const res: any = await client.session.promptAsync({ path: { id: sessionID }, body })
              if (res?.error) throw new Error(typeof res.error === "string" ? res.error : JSON.stringify(res.error))
              // Re-arm watchdog for this retry
              dispatchedStageId = stageId
              dispatchedStageMessage = msg
            } catch (e: any) {
              toast(`Stall retry failed: ${e?.message ?? String(e)} — TUI fallback`, "error")
              await client.tui.clearPrompt()
              await client.tui.appendPrompt({ body: { text: msg } })
              await client.tui.submitPrompt()
              stallRetries = 0
            }
          } else {
            toast(`Stage "${stageId}" stalled ${MAX_STALL_RETRIES}x — forcing TUI delivery`, "error")
            stallRetries = 0
            await client.tui.clearPrompt()
            await client.tui.appendPrompt({ body: { text: msg } })
            await client.tui.submitPrompt()
          }
          return
        }

        // A queued routed stage takes priority: the turn is now closed, which is
        // exactly the condition it was waiting for. Do NOT also arm the dwell
        // reminder — the dispatch IS the delivery, and firing both would send the
        // same stage twice.
        if (pendingDispatch) {
          cancelDwell()
          void flushPendingDispatch()
          return
        }
        if (state) startDwell()
      }

      if (t === "session.created") {
        if (state) {
          const name = state.quest.name
          clear()
          toast(`Quest auto-stopped (new session) — "${name}"`)
        }
      }
    },

    "command.execute.before": async (input: any, output: any) => {
      if (input.command !== "quest") return

      const args = (input.arguments ?? "").trim()

      if (!args || args === "status") {
        if (!state) {
          toast("No active quest.\nUse quest() to start one.", "error")
        } else {
          const msg = formatStageMessage(state)
          toast(msg.replace(/\n/g, "\n"), "info", 8000)
        }
      } else if (args === "stop") {
        if (!state) {
          toast("No active quest to stop.", "error")
        } else {
          const name = state.quest.name
          clear()
          toast(`Quest stopped — "${name}"`)
        }
      } else if (args === "pause") {
        if (!state) {
          toast("No active quest to pause.", "error")
        } else if (state.paused) {
          toast("Quest is already paused.", "error")
        } else {
          state.paused = true
          cancelDwell()
          if (hb) { clearInterval(hb); hb = null }
          toast(`Quest paused — "${state.quest.name}" at stage ${state.currentStageId}`)
        }
      } else if (args === "resume") {
        if (!state) {
          toast("No quest to resume.", "error")
        } else if (!state.paused) {
          toast("Quest is not paused.", "error")
        } else {
          state.paused = false
          refreshHb()
          toast(`Quest resumed — "${state.quest.name}" at stage ${state.currentStageId}`)
        }
      } else {
        // Unknown subcommand
        toast("Usage: /quest [status|pause|resume|stop]", "error")
      }

      // Silently abort the original /quest command by clearing its output parts.
      // Throwing is NOT supported by the opencode plugin contract — recent opencode
      // versions (June 2026 refactor) propagate unhandled errors to the chat UI as a
      // visible error block, which is the "spam" this guard avoids.
      if (output && Array.isArray(output.parts)) {
        output.parts.length = 0
      }
    },
  }
}

