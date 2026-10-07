# Message to testers (draft)

Status: draft for the owner to send. Fill in the placeholders: `<RELEASE_URL>` (for example `https://github.com/tayharris/needs-you/releases/tag/v0.1.1`), `<VERSION>`, `<NAME>`, and pick option A or B. Before sending: run [fresh-user-test-plan.md](fresh-user-test-plan.md) on the build, add each tester as a collaborator (option A), and protect `main` ([sharing-checklist.md](sharing-checklist.md) #2).

---

Hi <NAME>,

I've been building **needs-you**, a small Mac app that tells me when an AI agent, server or CI job is blocked on me. Claude Code sessions, cron jobs and scripts post a short item ("approve the deploy", "Claude is waiting for you"); a little floating pill on the Mac shows it, with a link to where I act, and it goes away once it's handled. Everything runs on your own machines: no cloud, no account.

Would you try it and tell me where it breaks or confuses you? It takes about 15 minutes on a Mac with macOS 14 or later; a second machine and Claude Code make it more interesting but are optional.

**Option A (GitHub):** I've added you as a collaborator on the private repo; accept the invite from GitHub's email. Then:

- Download: <RELEASE_URL> (`NeedsYou-<VERSION>.dmg`)
- Install guide: https://github.com/tayharris/needs-you/blob/main/docs/guides/testers.md
- Report problems: https://github.com/tayharris/needs-you/issues/new/choose → **Tester report**

(GitHub gives collaborators on a personal repo write access; please don't push to `main`.)

**Option B (no GitHub):** the DMG and the install guide are attached. Reply to this message with anything that goes wrong: your macOS version, the app version (right-click the pill → About Needs You), what you did and what happened.

Two heads-ups:

- The app isn't notarized yet, so macOS blocks the first launch. The guide has the two clicks (System Settings → Privacy & Security → **Open Anyway**).
- Please never send me a token or an invite link in a report; the guide says how to grab a log with them masked.

"I had to guess what to do here" is as useful as a crash. Thanks!
