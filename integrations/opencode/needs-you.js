// needs-you-version: 0.1.5
// needs-you.js: opencode plugin that mirrors "the agent is waiting on you" to needs-you.
//
// Installed by install-opencode-plugin.sh as <opencode config>/plugins/needs-you.js, next
// to <opencode config>/hooks/needs-you-hook.sh (the shared hook from integrations/claude-code).
// On these opencode events it starts that hook with `<mode> opencode` and a small JSON
// object on stdin, then returns at once:
//
//   permission.asked                       notify  (PermissionRequest)
//   question.asked                         notify  (Question, with its questions)
//   session.status idle / session.idle     notify  (Stop: the turn ended)
//   permission.replied, question.replied,
//   question.rejected, session.status busy resolve
//   session.deleted                        end
//
// The hook does the rest (opt-in gate, card text, links, lease, the CLI call); it is off
// unless NEEDS_YOU_AGENT_ALERTS=1 or the session runs in an Orca terminal. This file never
// throws, never makes opencode wait for the hook, and never changes a permission decision.
//
// Answers from the card (ADR 0009 B2): for a question the card can show whole (1-4
// questions, each with 1-8 options, labels as written, not a plan approval) the card is
// posted answerable, and the hook's `answer-wait` mode waits for the person's click (up to
// NEEDS_YOU_ANSWER_TIMEOUT s, default 600). A click's labels, checked against the options
// asked, go to opencode's own POST /question/{id}/reply; the TUI shows the question all the
// while, and whichever answer comes first wins. question.replied or question.rejected stops
// the wait. Nothing is ever answered on a timeout, an error or by default, and permission
// prompts are never answered.
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"

const HOOK =
  process.env.NEEDS_YOU_OPENCODE_HOOK ||
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "hooks", "needs-you-hook.sh")

function str(v) {
  return typeof v === "string" ? v : ""
}

// The question and its choices, for the card (the hook cleans, redacts and clamps them):
// only these fields, and only so much of each, so the hook's input stays small.
function questions(list) {
  if (!Array.isArray(list)) return []
  return list.slice(0, 10).filter((q) => q && typeof q === "object").map((q) => ({
    question: str(q.question).slice(0, 2000),
    header: str(q.header).slice(0, 200),
    options: (Array.isArray(q.options) ? q.options : []).slice(0, 20)
      .filter((o) => o && typeof o === "object")
      .map((o) => ({ label: str(o.label).slice(0, 200), description: str(o.description).slice(0, 400) })),
    multiple: q.multiple === true,
  }))
}

// One hook at a time per session, in event order, so a reply's resolve never overtakes
// the post it answers (question.asked then question.replied in the same instant).
// Handlers still return at once; only the hooks queue. Each is cut off after 20 s.
const queues = new Map()

function start(mode, payload) {
  return new Promise((done) => {
    try {
      if (!existsSync(HOOK)) return done()
      const child = spawn("bash", [HOOK, mode, "opencode"], {
        stdio: ["pipe", "ignore", "ignore"],
        detached: true,
      })
      const timer = setTimeout(() => {
        try { child.kill() } catch {}
        done()
      }, 20000)
      timer.unref()
      child.on("error", () => { clearTimeout(timer); done() })
      child.on("exit", () => { clearTimeout(timer); done() })
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(payload))
    } catch {
      done() // never fail opencode
    }
  })
}

function run(mode, payload) {
  const id = str(payload.session_id)
  const next = (queues.get(id) || Promise.resolve()).then(() => start(mode, payload))
  queues.set(id, next)
  next.then(() => { if (queues.get(id) === next) queues.delete(id) })
  return next
}

// Can the card answer this question? Only the question tool's own questions, shown whole:
// opencode's plan exit ("Build Agent", custom: false) is an approval, never answered here.
function answerable(list) {
  if (!Array.isArray(list) || list.length < 1 || list.length > 4) return false
  return list.every((q) => q && typeof q === "object" && q.custom !== false && str(q.header) !== "Build Agent" &&
    str(q.question).trim() !== "" && Array.isArray(q.options) && q.options.length >= 1 && q.options.length <= 8 &&
    q.options.every((o) => o && typeof o === "object" && str(o.label).trim() === str(o.label) &&
      str(o.label) !== "" && str(o.label).length <= 80 && !/[\u0000-\u001f\u007f-\u009f]/.test(str(o.label))))
}

// The answer the hook printed, as opencode's reply: one array of labels per question, in
// order, every label one of that question's options, one for a single-choice question. null
// for anything else (then nothing is answered).
function replyFor(list, printed, requestID) {
  let a
  try { a = JSON.parse(printed) } catch { return null }
  if (!a || a.question_id !== requestID || !Array.isArray(a.answers) || a.answers.length !== list.length) return null
  const out = []
  for (let i = 0; i < list.length; i++) {
    const sel = a.answers[i] && a.answers[i].selected
    const labels = list[i].options.map((o) => o.label)
    if (!Array.isArray(sel) || sel.length < 1 || (!list[i].multiple && sel.length !== 1)) return null
    if (!sel.every((l) => typeof l === "string" && labels.includes(l)) || new Set(sel).size !== sel.length) return null
    out.push(sel.slice())
  }
  return out
}

// Start the hook's answer-wait mode; resolves with what it printed ("" on anything else).
function waitForAnswer(payload, pending) {
  return new Promise((done) => {
    try {
      if (!existsSync(HOOK)) return done("")
      const child = spawn("bash", [HOOK, "answer-wait", "opencode"], {
        stdio: ["pipe", "pipe", "ignore"],
        detached: true,
      })
      pending.child = child
      let out = ""
      child.stdout.on("data", (b) => { if (out.length < 65536) out += b })
      child.on("error", () => done(""))
      child.on("exit", () => done(out))
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(payload))
    } catch {
      done("")
    }
  })
}

// Stop a wait: its hook and the CLI under it (their own process group).
function stopWait(pending) {
  pending.stopped = true
  const child = pending.child
  if (!child || child.exitCode !== null) return
  try { process.kill(-child.pid, "SIGTERM") } catch {
    try { child.kill() } catch {}
  }
}

// POST /question/{id}/reply through the plugin's own client (in-process when opencode runs
// without a server port, with its auth and directory), else at serverUrl.
async function reply(client, serverUrl, requestID, answers) {
  const inner = client && client._client
  if (inner && typeof inner.post === "function") {
    const r = await inner.post({
      url: "/question/{requestID}/reply",
      path: { requestID },
      body: { answers },
      headers: { "Content-Type": "application/json" },
    })
    return !(r && r.error)
  }
  const url = new URL("/question/" + encodeURIComponent(requestID) + "/reply", serverUrl)
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ answers }) })
  return r.ok
}

export const NeedsYou = async (input) => {
  const { directory, worktree, client } = input || {}
  const cwd = str(directory) || str(worktree) || process.cwd()
  // Question request id -> its wait for an answer from the card.
  const waits = new Map()

  function ask(sid, p) {
    const requestID = str(p.id).slice(0, 200)
    const list = Array.isArray(p.questions) ? p.questions : []
    const canAnswer = requestID !== "" && answerable(list)
    const posted = notify(sid, { hook_event_name: "Question", question_id: requestID, questions: questions(p.questions),
      ...(canAnswer ? { answerable: true } : {}) })
    if (!canAnswer || !posted) return
    const pending = { stopped: false, child: null }
    waits.set(requestID, pending)
    posted
      .then(() => (pending.stopped ? "" : waitForAnswer({ session_id: sid, cwd, hook_event_name: "AnswerWait" }, pending)))
      .then(async (printed) => {
        if (waits.get(requestID) === pending) waits.delete(requestID)
        if (pending.stopped || !printed) return
        const answers = replyFor(list, printed, requestID)
        if (!answers) return
        let serverUrl
        try { serverUrl = input.serverUrl } catch {}
        await reply(client, serverUrl, requestID, answers)
      })
      .catch(() => {}) // never fail opencode
  }
  function answered(p) {
    const pending = waits.get(str(p.requestID))
    if (pending) {
      waits.delete(str(p.requestID))
      stopWait(pending)
    }
  }
  // Session -> the event behind its card, so the frequent resolve events cost nothing
  // otherwise, and session.idle plus session.status idle post once.
  const open = new Map()

  function notify(sessionID, data) {
    if (!sessionID) return
    if (data.hook_event_name === "Stop" && open.get(sessionID) === "Stop") return
    open.set(sessionID, data.hook_event_name)
    return run("notify", { session_id: sessionID, cwd, ...data })
  }
  function resolve(sessionID, mode = "resolve") {
    if (!sessionID || !open.has(sessionID)) return
    open.delete(sessionID)
    run(mode, { session_id: sessionID, cwd, hook_event_name: mode === "end" ? "SessionEnd" : "Resolve" })
  }

  return {
    // The agent's commands learn their session, so `needs-you add` from this session notes
    // its item for the hook (one card for one wait). Only the id; nothing else changes.
    "shell.env": async (input, output) => {
      try {
        const sid = str(input && input.sessionID)
        if (sid && output && output.env && typeof output.env === "object") output.env.NEEDS_YOU_AGENT_SESSION = sid
      } catch {
        // never fail opencode
      }
    },
    event: async ({ event }) => {
      try {
        const type = str(event && event.type)
        const p = (event && event.properties) || {}
        const sid = str(p.sessionID)
        switch (type) {
          case "permission.asked": {
            const patterns = Array.isArray(p.patterns) ? p.patterns.filter((x) => typeof x === "string") : []
            notify(sid, { hook_event_name: "PermissionRequest", tool_name: str(p.permission), patterns: patterns.slice(0, 5) })
            break
          }
          case "question.asked":
            ask(sid, p)
            break
          case "session.idle":
            notify(sid, { hook_event_name: "Stop" })
            break
          case "session.status": {
            const st = str(p.status && p.status.type)
            if (st === "idle") notify(sid, { hook_event_name: "Stop" })
            else if (st === "busy") resolve(sid)
            break
          }
          case "question.replied":
          case "question.rejected":
            answered(p)
            resolve(sid)
            break
          case "permission.replied":
            resolve(sid)
            break
          case "session.deleted":
            resolve(sid || str(p.info && p.info.id), "end")
            break
        }
      } catch {
        // never fail opencode
      }
    },
  }
}
