# Request update: why a hub can't make a machine run anything

The Mac app's **Request update** (Settings → Access, the machine list) lets the owner ask a
sender machine to update. This note records the threat model behind its design. Contract:
[API.md](../API.md#post-v1tokensid-or-namerequest-update-owner); user guide:
[updates.md](../guides/updates.md#sender-machines).

## What travels

- **Mac → hub:** `POST /v1/tokens/<id>/request-update`, owner token only. Sender and reader
  tokens get 403; a non-sender target gets 400. The hub stores a row (token id, time, the CLI
  version last reported) in its own database. Nothing replicates.
- **Hub → sender:** one boolean, `"update_requested": true`, in 2xx responses to that sender's own
  requests. No URL, version, file name, command or text comes with it.
- **Sender:** the CLI reads only that boolean (`is True`; any other value is ignored).

## What the CLI does with it, and nothing else

1. With `NEEDS_YOU_AUTO_UPDATE=1` (the machine's owner opted in at install, `--auto-update`),
   it runs `[sys.executable, <its own path>, "update", "--auto"]`: a fixed argument list built
   in the CLI, no shell, detached (`start_new_session`, stdio to `/dev/null`, `cwd=/`), at most
   once every 6 hours (state in `~/.local/state/needs-you/update.json`).
2. Otherwise it prints one fixed line to stderr at most once a day. The hub name in it comes
   from the machine's own `NEEDS_YOU_URLS`, not from the response, and is passed through the
   CLI's control-character filter anyway.

`needs-you update --auto` is the same routine the daily flush already runs with auto-update on.
It keeps every existing check: it talks only to the machine's configured update hub (the first
`NEEDS_YOU_URLS` entry or `NEEDS_YOU_UPDATE_HUB`, never the hub that set the flag and never a URL
from a response), over https, loopback or the tailnet only, pinned to the one address it
resolved, without redirects; every file must match the hub's `/dl/manifest.json` sha256 and
size; the CLI must compile; it never downgrades; with `gh`, every file must match the GitHub
release and its build provenance, and without `gh` an automatic update is refused unless
`NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH=0`. See [audit item 17](audit-2026-10-07.md) and
[release-signing.md](release-signing.md).

## What a malicious or compromised hub can do with it

- **Set the flag on its own:** it can make an opted-in machine run its update check at most
  every 6 hours instead of once a day, or make a non-opted-in machine print a reminder once a
  day. A hub that can already serve `/dl` files to that machine gains nothing: the update
  checks above decide what installs, exactly as on the daily run.
- **Not:** choose what runs, where it downloads from, which version installs, or the exit code
  of the caller's command. The flag never changes exit codes or output on stdout; `-q`/`--json`
  suppress the reminder, and a failing background update is invisible to the caller.
- **Not on a machine without auto-update:** nothing runs there at all; a person decides.

## Other properties

- **Senders never fail the caller's job:** the handling runs after the command's work, inside a
  catch-all, and the background process is never waited for.
- **No token or secret in any of it:** the request is keyed by token id; responses carry only the
  boolean; `GET /v1/tokens` adds a timestamp.
- **Stops by itself:** the hub clears the request when the machine reports a different CLI
  version (or one at least the hub's own), when the owner cancels it, or when the token is revoked.
- **Old clients:** CLIs that predate this ignore the unknown field; old hubs return 404 to the
  endpoints, which the Mac shows as an error.
