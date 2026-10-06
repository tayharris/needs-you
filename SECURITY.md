# Security

needs-you moves alerts between your machines over your own network. The parts that matter for security: hub tokens (stored as sha256 on hubs), invite links (each one mints tokens), peer secrets between hubs, the hub's network binding (loopback and the tailnet only), and the link scheme allow-list in the hub and the Mac app.

## Reporting a vulnerability

Report privately: on GitHub, **Security → Report a vulnerability** on this repository. Please don't open a public issue for anything that could let someone read items, mint or reuse tokens, redeem invites, reach a hub from outside the tailnet, or open an unexpected link on someone's Mac.

Include the version (`needs-you --version`, the app's version, or the commit), what you did, and what happened. **Never include real tokens, invite links or codes, or peer secrets**: describe them (`a sender token`, `a 1-use invite`) or use ones from a throwaway hub.

You'll get an answer within a week. Fixes ship in a release, with credit in the changelog unless you'd rather not.

## Supported versions

Only the latest release gets fixes while the project is pre-1.0.

## Design notes

- Tokens are printed once, when minted, and never logged; hubs keep only their sha256.
- Hubs refuse to bind `0.0.0.0` or `::` unless explicitly overridden.
- The Mac app opens only `https`, `orca`, `slack`, `vscode`, `cursor`, `figma`, `msteams` and `discord` links, and never takes keyboard focus from the panel.
- The Mac app ships ad-hoc signed until there's a Developer ID build; see `docs/roadmap/distribution.md`.
