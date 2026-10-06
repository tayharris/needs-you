# needs-you

One inbox for "Taylor has to do something", fed by every VM, project and agent over Tailscale, and shown on the Mac as a small floating panel.

- `docs/PLAN.md`: design, API, Mac app, build order
- `docs/AGENT-GUIDE.md`: how senders post items

Layout (in progress):

- `mac/`: NeedsTay.app (SwiftUI + NSPanel)
- `hub/`: HTTP + SQLite service (tailnet only)
- `cli/`: `needs-tay` sender CLI with offline outbox
- `scripts/`: setup helpers
