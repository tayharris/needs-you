# Sharing checklist

Status (2026-10-08): the repo is **public** on GitHub with its full history, releases are published, private vulnerability reporting is on, and the site is live. What's left is in "Still open" below.

## Done

- License: **Apache-2.0** (`LICENSE`).
- CI on every push (Ubuntu 22.04 and latest with the system python3, macOS with `/usr/bin/python3` 3.9, the Mac app's tests and build, and shellcheck at warning level). The site is checked by `tests/test_site.py`.
- A release workflow: a `v*.*.*` tag drafts a GitHub Release with the DMG and zip, the server tarball, the CLI, `release-manifest.json` and `SHA256SUMS` (with build provenance), and notes with the Gatekeeper steps. Published: 0.1.2 to 0.1.5.
- The repo is public (decisions 2 and 3 below are settled: public, with the existing history) and **Report a vulnerability** is switched on (decision 6).
- The site is live at https://needsyou.app ([site-deploy.md](site-deploy.md)).
- The tree has no personal hostnames, tailnet names, employer or client names (`docs/PLAN.md` is gone; its generic design is in [ADR 0007](../adr/0007-founding-design.md)). Demo data uses `acme` and `ACME-123`.
- `README.md` has a status line and "Install from a release". `CONTRIBUTING.md` and `SECURITY.md` exist, and the issue chooser links to private security reports.
- [fresh-user-test-plan.md](fresh-user-test-plan.md) is the check before anyone new gets a link.
- Bundle id: **`app.needsyou.mac`** (the project's domain, needsyou.app). Moving to it resets settings and the login item once ([updates.md](../guides/updates.md#upgrade-note-the-bundle-id-moved-to-appneedsyoumac)).

## Still open

| # | Decision | Why it matters | Suggestion |
|---|---|---|---|
| 5 | **Developer ID** (personal, org, or wait) | Without it, every download needs the Gatekeeper workaround, managed Macs may block it, and the firewall prompt comes back after updates. | Wait unless testers hit EDR blocks; then a personal account is the quickest. |
| 7 | **CLAUDE.md "In flux" and branch naming** | Mentions in-progress branches and the owner's branch prefix. | Review the "In flux" section; the invite branches it names have merged. |
| 8 | **Self-hosted runners on a public repo** | The CI variables point at self-hosted runners. Fork pull requests use GitHub's images (the `runs-on` expressions check `head.repo.fork`), but a collaborator's branch still runs on them. | Keep the fork check, require approval for fork-PR workflows (Settings → Actions), and keep the runners on dedicated accounts ([ci-cd.md](ci-cd.md#self-hosted-runners)). |
| 9 | **Fresh-user test** | Nobody outside the repo has run [fresh-user-test-plan.md](fresh-user-test-plan.md) on a second Mac yet (no recorded findings). | Run it before inviting more testers. |

## License options

All four are OSI-approved and fit an open-source non-profit; the choice is about what forks may do.

| License | In one line | Good for |
|---|---|---|
| **Apache-2.0** | Permissive, with an explicit patent grant and a NOTICE file | Infrastructure tools that companies install on their own machines. Most common choice for this kind of project. |
| **MIT** | Permissive, a few lines, no patent clause | The simplest option; maximum reuse. |
| **MPL-2.0** | Changes to *these files* must stay open; can be combined with closed code | Keeping improvements to the hub and CLI open without scaring off companies. |
| **AGPL-3.0** | Anyone running a modified hub as a service must publish their changes | Stopping a closed hosted fork. Some companies ban AGPL, which cuts adoption. |

Chosen: **Apache-2.0**. needs-you is a tool people run on their own machines and servers, so a hosted closed fork isn't the main risk; broad adoption by teams is the goal, and the patent grant is the main thing MIT lacks.
