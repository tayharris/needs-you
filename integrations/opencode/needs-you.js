// needs-you-version: 0.1.3
// needs-you.js: opencode plugin that mirrors "the agent is waiting on you" to needs-you.
//
// Installed by install-opencode-plugin.sh as <opencode config>/plugins/needs-you.js, next
// to <opencode config>/hooks/needs-you-hook.sh (the shared hook from integrations/claude-code).
// On these opencode events it starts that hook with `<mode> opencode` and a small JSON
// object on stdin, then returns at once:
//
//   permission.asked                       notify  (PermissionRequest)
//   question.asked                         notify  (Question)
//   session.status idle / session.idle     notify  (Stop: the turn ended)
//   permission.replied, question.replied,
//   question.rejected, session.status busy resolve
//   session.deleted                        end
//
// The hook does the rest (opt-in gate, card text, links, lease, the CLI call); it is off
// unless NEEDS_YOU_AGENT_ALERTS=1 or the session runs in an Orca terminal. This file never
// throws, never waits for the hook, and never changes a permission decision.
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

function run(mode, payload) {
  try {
    if (!existsSync(HOOK)) return
    const child = spawn("bash", [HOOK, mode, "opencode"], {
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    })
    child.on("error", () => {})
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify(payload))
    child.unref()
  } catch {
    // never fail opencode
  }
}

export const NeedsYou = async ({ directory, worktree }) => {
  const cwd = str(directory) || str(worktree) || process.cwd()
  // Session -> the event behind its card, so the frequent resolve events cost nothing
  // otherwise, and session.idle plus session.status idle post once.
  const open = new Map()

  function notify(sessionID, data) {
    if (!sessionID) return
    if (data.hook_event_name === "Stop" && open.get(sessionID) === "Stop") return
    open.set(sessionID, data.hook_event_name)
    run("notify", { session_id: sessionID, cwd, ...data })
  }
  function resolve(sessionID, mode = "resolve") {
    if (!sessionID || !open.has(sessionID)) return
    open.delete(sessionID)
    run(mode, { session_id: sessionID, cwd, hook_event_name: mode === "end" ? "SessionEnd" : "Resolve" })
  }

  return {
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
            notify(sid, { hook_event_name: "Question" })
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
          case "permission.replied":
          case "question.replied":
          case "question.rejected":
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
