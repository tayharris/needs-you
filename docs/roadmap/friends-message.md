# Message to testers

A message the owner can send. Fill in `<NAME>`.

---

Hi <NAME>,

I've been building **needs-you**, a small Mac app that tells me when an AI agent, server or CI job is blocked on me. Claude Code sessions, cron jobs and scripts post a short item ("approve the deploy", "Claude is waiting for you"); a little floating pill on the Mac shows it, with a link to where I act, and it goes away once it's handled. Everything runs on your own machines: no cloud, no account.

Would you try it and tell me where it breaks or confuses you? It takes about 15 minutes on a Mac with macOS 14 or later; a second machine and Claude Code make it more interesting but are optional.

- Site: https://needsyou.app
- Download: https://github.com/tayharris/needs-you/releases/latest (`NeedsYou-<version>.dmg`)
- Install guide: https://github.com/tayharris/needs-you/blob/main/docs/guides/testers.md
- Report problems: https://github.com/tayharris/needs-you/issues/new/choose → **Tester report** (or just reply to me)

Two heads-ups:

- The app isn't notarized yet, so macOS blocks the first launch. The guide has the two clicks (System Settings → Privacy & Security → **Open Anyway**).
- Please never send me a token or an invite link in a report; the guide says how to grab a log with them masked.

"I had to guess what to do here" is as useful as a crash. Thanks!
