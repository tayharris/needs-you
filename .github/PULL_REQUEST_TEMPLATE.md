## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## How it was tested

<!-- Commands you ran and what you checked by hand. -->

## Checklist

- [ ] Tests pass: `/usr/bin/python3 -m unittest discover -s tests` and, if `mac/` changed, `mac/scripts/test.sh`
- [ ] Python stays `/usr/bin/python3` 3.9 compatible and standard-library only (no `match`, no runtime `X | Y` unions, no `tomllib`, no new dependencies)
- [ ] The panel never takes focus or activates the app (`FloatingPanelTests` still pass; no focusable views in the panel)
- [ ] Docs updated (guides, `docs/API.md` for any wire change, and both the hub and the Mac client for API changes)
- [ ] No secrets, tokens, invite codes or personal hostnames in code, docs, tests or screenshots
