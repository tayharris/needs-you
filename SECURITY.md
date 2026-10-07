# Security

needs-you moves short alerts between your own machines over your own network (normally a Tailscale tailnet). This page says how to report a problem and what the security model is, so you can tell a bug from expected behavior.

## Reporting a vulnerability

Report privately: on GitHub, open this repository's **Security** tab → **Report a vulnerability** (a private advisory only the maintainers see). If that option isn't there, open an issue that says only "security report, please give me a private contact", with no details.

Please don't open a public issue for anything that could let someone read items, mint, guess or reuse tokens, redeem invites, reach a hub from outside the tailnet, or make the Mac app open a link or run something unexpected.

Include:

- the version (`needs-you --version`, the app's version in Finder's **Get Info**, or the commit),
- what you did and what happened, ideally against a throwaway hub (`python3 hub/needs_you_hub.py --bind 127.0.0.1 --db /tmp/ny.db`).

**Never include real tokens, invite links or codes, or peer secrets.** Describe them (`a sender token`, `a 1-use invite`) or use ones from a throwaway hub.

You'll get an answer within a week. Fixes ship in a release, with credit in the changelog unless you'd rather not.

## Supported versions

While the project is pre-1.0, only the latest release gets fixes.

## Security model

What's protected, and how:

- **Tokens.** Every machine has its own token with a role (`sender` posts, `reader` reads, `owner` also manages invites and tokens). Tokens are printed once, when minted, and never logged; hubs store only their sha256. Any token can be revoked on its own (**Settings… → Access** in the Mac app, or `needs-you-admin token revoke`).
- **Invite links.** A link (`/join/<code>`) mints a token per machine, up to its number of uses, until it expires (at most 90 days) or is revoked. Failed redeem attempts are rate-limited per address. The hub's access log never shows the code. When a `needsyou://connect` link is opened from outside the app (any web page can open one), the app asks before it joins that hub, and a hub it didn't know before can't replace the tokens of hubs it already has.
- **Network.** Hubs listen on `127.0.0.1` and the tailnet address only, and refuse `0.0.0.0` or `::` unless explicitly overridden. Hubs replicate with a shared peer secret.
- **Links in items.** The hub and the Mac app accept only `https`, `orca`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord` and `linear` links. The exceptions are the app's own actions, `needsyou://orca/terminal?handle=…` and `needsyou://terminal/focus?app=…` (one table in the hub and the app): the app parses each into a typed value, validates every parameter, and runs only `orca terminal switch`, `wezterm cli activate-pane` or `tmux select-window`/`select-pane` from fixed paths with argument arrays (no shell), or a fixed AppleScript handler (opt-in) with the value as a typed parameter. Worst case for a sender: the Mac shows a different terminal tab. A terminal link opened from outside the app asks first.
- **Item text.** Titles, bodies, labels and sources can't carry control characters or bidi override characters (so a label can't be made to read backwards), and link URLs can't hide spaces or invisible characters. The CLI escapes control characters in anything a hub sends it before printing.
- **The panel** never takes keyboard focus, so a new item can't capture what you type.
- **Senders' local files.** `~/.config/needs-you/env` (the token) is mode 600; the Mac app keeps hub tokens in `~/Library/Application Support/NeedsYou/tokens.json`, mode 600.

Expected behavior, not vulnerabilities:

- A link's label is whatever the sender wrote, like any Markdown link: `[GitHub PR](https://…)` can point anywhere on `https`. Check where a link goes before you sign in or approve anything on the page it opens.

- Anyone holding a sender token can post items with any title, body and allowed link, and resolve any open item by key (keys aren't scoped per token). Each token has a cap on open items. Item text is shown, never executed. Revoke a token you don't trust.
- Anyone on your tailnet who can reach port 8765 can open a join page if they have its code, and can read `/v1/health` (no token needed; it reveals the hub's id, version and item counts). Use Tailscale access rules to limit who reaches the hub ([docs/guides/tailscale.md](docs/guides/tailscale.md)).
- Traffic between machines is plain `http` inside the tailnet; Tailscale encrypts it. Over any other network, use `https`.
- A hub started with `--allow-any-interface` is exposed on every interface by your choice.
- The Mac app is ad-hoc signed, not notarized, until there's a Developer ID build ([docs/roadmap/distribution.md](docs/roadmap/distribution.md)). Check downloads against `SHA256SUMS` on the release page.
