// needs-you-version: 0.3.2
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
//   session.created/updated, message.updated, message.part.updated: remembered (the
//   session's title, its last assistant text) for the Stop card, nothing sent
//
// The hook does the rest (opt-in gate, card text, links, lease, the CLI call); it is off
// unless NEEDS_YOU_AGENT_ALERTS=1 or the session runs in an Orca terminal. This file never
// throws, never makes opencode wait for the hook, and never changes a permission decision.
//
// Answers from the card (ADR 0009 B2): for a question the card can show whole (1-4
// questions, each with 1-8 options, labels as written, not a plan approval) the card is
// posted answerable, and the hook's `answer-wait` mode waits for the person's click (up to
// NEEDS_YOU_ANSWER_TIMEOUT s, default 600). opencode lets the person type their own answer
// ("Type your own answer") to such a question, so the card offers "Other…" too. A click's
// labels, or the words typed on the Mac, checked against the question asked, go to
// opencode's own POST /question/{id}/reply; the TUI shows the question all the
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
    new Set(q.options.map((o) => str(o && o.label))).size === q.options.length &&
    q.options.every((o) => o && typeof o === "object" && str(o.label).trim() === str(o.label) &&
      str(o.label) !== "" && str(o.label).length <= 80 && !/[\u0000-\u001f\u007f-\u009f]/.test(str(o.label))))
}

// The person's own words from an answer ("Other"): undefined when there are none, null when
// they aren't what the hub takes (one line, 1-1000 characters, no control or bidi characters).
function ownWords(v) {
  if (v === undefined || v === null) return undefined
  if (typeof v !== "string" || v.trim() === "") return null
  const t = v.trim()
  if ([...t].length > 1000 || /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/.test(t)) return null
  return t
}

// The answer the hook printed, as opencode's reply: one array per question, in order, of
// labels from that question's options and then the person's own words if they typed any; one
// label or the words for a single-choice question. null for anything else (then nothing is
// answered).
function replyFor(list, printed, requestID) {
  let a
  try { a = JSON.parse(printed) } catch { return null }
  if (!a || a.question_id !== requestID || !Array.isArray(a.answers) || a.answers.length !== list.length) return null
  const out = []
  for (let i = 0; i < list.length; i++) {
    const ans = a.answers[i]
    const sel = ans && ans.selected
    const words = ans ? ownWords(ans.text) : null
    const labels = list[i].options.map((o) => o.label)
    if (!Array.isArray(sel) || words === null) return null
    const given = sel.length + (words === undefined ? 0 : 1)
    if (given < 1 || (!list[i].multiple && given !== 1)) return null
    if (!sel.every((l) => typeof l === "string" && labels.includes(l)) || new Set(sel).size !== sel.length) return null
    out.push(words === undefined ? sel.slice() : [...sel, words])
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
      ...(canAnswer ? { answerable: true, allow_other: true } : {}) })
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
  // Session -> its title (not opencode's "New session - <date>" placeholder), the id of its
  // latest assistant message, and that message's latest text (its end only). The turn card
  // names the session and, when that text ends on a question, shows the question (the hook
  // redacts and cuts it).
  const titles = new Map()
  const lastAssistant = new Map()
  const lastText = new Map()

  function noteSession(info) {
    if (!info || typeof info !== "object") return
    const id = str(info.id)
    const title = str(info.title)
    if (!id) return
    if (title && !/^(New|Child) session - /.test(title)) titles.set(id, title.slice(0, 200))
    else titles.delete(id)
  }
  function noteMessage(info) {
    if (info && typeof info === "object" && info.role === "assistant" && str(info.sessionID) && str(info.id)) {
      if (lastAssistant.get(str(info.sessionID)) !== str(info.id)) lastText.delete(str(info.sessionID))
      lastAssistant.set(str(info.sessionID), str(info.id))
    }
  }
  function notePart(part) {
    if (!part || typeof part !== "object" || part.type !== "text" || part.synthetic === true) return
    const sid = str(part.sessionID)
    if (sid && lastAssistant.get(sid) === str(part.messageID)) lastText.set(sid, tail(str(part.text), 4000))
  }
  // The end of a text; a cut drops the partial word at the front, so a token cut in two
  // can't slip past the hook's redaction.
  function tail(t, n) {
    return t.length <= n ? t : t.slice(-n).replace(/^\S*\s*/, "")
  }
  function forget(sid) {
    titles.delete(sid)
    lastAssistant.delete(sid)
    lastText.delete(sid)
  }

  function notify(sessionID, data) {
    if (!sessionID) return
    if (data.hook_event_name === "Stop" && open.get(sessionID) === "Stop") return
    open.set(sessionID, data.hook_event_name)
    const extra = {}
    if (titles.has(sessionID)) extra.session_title = titles.get(sessionID)
    if (data.hook_event_name === "Stop" && lastText.has(sessionID)) extra.last_assistant_message = lastText.get(sessionID)
    return run("notify", { session_id: sessionID, cwd, ...extra, ...data })
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
          case "session.created":
          case "session.updated":
            noteSession(p.info)
            break
          case "message.updated":
            noteMessage(p.info)
            break
          case "message.part.updated":
            notePart(p.part)
            break
          case "session.deleted":
            resolve(sid || str(p.info && p.info.id), "end")
            forget(sid || str(p.info && p.info.id))
            break
        }
      } catch {
        // never fail opencode
      }
    },
  }
}
