# Sharing checklist

Status (2026-10-06): ready to share with **invited collaborators**. Not ready to make public.

## Done

- License: **Apache-2.0** (`LICENSE`), chosen 2026-10-06 while the repo is private; revisit before going public if needed.
- CI on every push (Ubuntu 22.04 and latest with the system python3, macOS with `/usr/bin/python3` 3.9, the Mac app's tests and build, and shellcheck at warning level). The site is checked by `tests/test_site.py`.
- A release workflow: a `v*.*.*` tag drafts a GitHub Release with the app zip, the server tarball, the CLI, `SHA256SUMS`, and notes with the Gatekeeper steps. First tag: `v0.1.1`.
- The tree has no personal hostnames, tailnet names, employer or client names (`docs/PLAN.md` is gone; its generic design is in [ADR 0007](../adr/0007-founding-design.md)). Demo data uses `acme` and `ACME-123`.
- `README.md` has a status line and "Install from a release". `CONTRIBUTING.md` and `SECURITY.md` exist, and the issue chooser links to private security reports.
- [fresh-user-test-plan.md](fresh-user-test-plan.md) is the check before anyone new gets a link.
- Bundle id: **`app.needsyou.mac`** (the project's domain, needsyou.app). Moving to it resets settings and the login item once ([updates.md](../guides/updates.md#upgrade-note-the-bundle-id-moved-to-appneedsyoumac)).

## Waiting on a decision

| # | Decision | Why it matters | Suggestion |
|---|---|---|---|
| 2 | **Who sees it**: collaborators or public | The repo is owned by a personal account, so a collaborator (Settings → Collaborators → **Add people**) always gets **write** access: they can see drafts and releases and download assets with `gh` or the browser, and they can also push branches, open and close issues, and edit releases. The read-only **Read** role exists only for repos owned by an organization. Anonymous `curl` of release assets (the server installer in `distribution.md`) only works on a public repo. Testers: [testers.md](../guides/testers.md). | Collaborators now (protect `main` so a collaborator can't push to it), or move the repo to an organization for the Read role; public once 3 is done. |
| 3 | **Git history** | Old commits contain personal host and tailnet names (they were cleaned from the tree, not from history). Fine for collaborators. Before going public: publish from a fresh history (one squashed commit in a new public repo, this one stays private), or rewrite history (needs `git filter-repo`, and every clone must re-clone). | A fresh public repo from a squashed snapshot: simplest, nothing to rewrite here. |
| 5 | **Developer ID** (personal, org, or wait) | Without it, every download needs the Gatekeeper workaround, managed Macs may block it, and the firewall prompt comes back after updates. | Wait unless testers hit EDR blocks; then a personal account is the quickest. |
| 6 | **Private vulnerability reporting** | `SECURITY.md` points at GitHub's **Report a vulnerability**, which must be switched on (Settings → Code security). It's available on public repos. | Switch it on when the repo goes public; until then collaborators can open a private issue or contact you directly. |
| 7 | **CLAUDE.md "In flux" and branch naming** | Mentions in-progress branches and your branch prefix; fine for collaborators, worth a pass before public. | Review at launch. |

## License options

All four are OSI-approved and fit an open-source non-profit; the choice is about what forks may do.

| License | In one line | Good for |
|---|---|---|
| **Apache-2.0** | Permissive, with an explicit patent grant and a NOTICE file | Infrastructure tools that companies install on their own machines. Most common choice for this kind of project. |
| **MIT** | Permissive, a few lines, no patent clause | The simplest option; maximum reuse. |
| **MPL-2.0** | Changes to *these files* must stay open; can be combined with closed code | Keeping improvements to the hub and CLI open without scaring off companies. |
| **AGPL-3.0** | Anyone running a modified hub as a service must publish their changes | Stopping a closed hosted fork. Some companies ban AGPL, which cuts adoption. |

Suggestion: **Apache-2.0**. needs-you is a tool people run on their own machines and servers, so a hosted closed fork isn't the main risk; broad adoption by teams is the goal, and the patent grant is the main thing MIT lacks. When you decide, add `LICENSE`, update `README.md` and `CONTRIBUTING.md` (drop the "no license yet" lines), and the release notes.

## Before the first public release

- [ ] Self-hosted runners: delete the `CI_*_RUNNER(S)`/`RELEASE_MAC_RUNNER` variables or lock the runners down first ([ci-cd.md](ci-cd.md#self-hosted-runners)).
- [ ] Decisions 2 and 3 above.
- [ ] Run [fresh-user-test-plan.md](fresh-user-test-plan.md) on a second Mac and fix what it finds.
- [ ] Site deployed ([site-deploy.md](site-deploy.md)), or the site's links point at the repo.
