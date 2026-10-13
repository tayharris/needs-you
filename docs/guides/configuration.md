# Configuration

Every setting needs-you reads, on one page: the sender's env file and environment variables, the files that hold keys and tokens, a server hub's `hub.json` and `hub-update.json`, and the installers' flags. Each table gives the default, what the setting takes and what reads it; the linked guide explains when you'd change it. `needs-you doctor` checks all of it on a sender ([below](#checking-it-needs-you-doctor)).

A value a setting doesn't take is never silently ignored: the CLI and the pollers name the variable on stderr with what it takes and use the default, the hub refuses to start and names the key, and the installers stop before changing anything. None of them prints the value itself, since a token pasted onto the wrong line would be shown.

## Where settings live

- **On a sender** (any machine that posts: a laptop, a server, CI), the CLI, the agent hooks and the pollers read `~/.config/needs-you/env`: one `NAME=VALUE` per line, mode 600, written by the invite installer ([Add a sender](add-a-sender.md#the-senders-config)). `export NAME=VALUE`, spaces around `=` and quotes around the value are fine; `#` starts a comment. The file is read, never run by a shell, so `$HOME` in a value isn't expanded (the path settings take `~`).
- **The environment wins:** a variable set in the environment beats the same line in the file. An empty value in the environment counts as unset.
- **Some variables are environment only** (marked *env only* below): a line for them in the env file does nothing, and `needs-you doctor` says so.
- `$XDG_CONFIG_HOME` moves `~/.config` and `$XDG_STATE_HOME` moves `~/.local/state`, for everything.
- **On a server hub**, `hub.json` (and `hub-update.json` next to it) hold the settings; every `hub.json` key can also be a flag ([below](#hub-hubjson)).
- **The Mac app** keeps its own settings in Settings; nothing here applies to it, except `NEEDS_YOU_HUB_ALLOWED_HOSTS` for its built-in hub.

Accepted values, used in the tables: *on/off* is `1`, `true`, `yes` or `on`, and `0`, `false`, `no` or `off` (any case); a *context* is `work` or `personal`; a *priority* is `urgent`, `normal` or `low`.

## Sender settings

### The CLI

Read by `needs-you` itself, so by everything that runs it (hooks, pollers, CI, `needs-you run`). [Add a sender](add-a-sender.md#the-senders-config).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_URLS` | none (required) | Hub URLs, `http(s)://host:port`, comma-separated, tried in order (failover) |
| `NEEDS_YOU_URL` | none | The same, used when `NEEDS_YOU_URLS` is unset |
| `NEEDS_YOU_TOKEN` | none (required) | This machine's sender token. Never printed: `doctor` shows only its length |
| `NEEDS_YOU_TIMEOUT` | `3` | Seconds to wait for each hub, a number of at least 0.1 |
| `NEEDS_YOU_HOST` | the short hostname | The machine name on cards: letters, digits, `.`, `_`, `@` or `-` |
| `NEEDS_YOU_DEFAULT_CONTEXT` | `work` | A context: the one used when a sender doesn't give one |
| `NEEDS_YOU_OUTBOX_MAX` | `500` | How many queued requests the outbox keeps, a whole number of at least 1 |
| `NEEDS_YOU_OUTBOX_MAX_DAYS` | `7` | Queued requests older than this many days are dropped |
| `NEEDS_YOU_CONFIG` | `~/.config/needs-you/env` | *Env only.* Another env file, for the CLI, the hooks, the pollers and the installers |
| `NEEDS_YOU_ENV_FILE` | `NEEDS_YOU_CONFIG` | *Env only.* Another env file for the agent hooks, their installers and the usage helper only; `doctor` warns when it isn't the CLI's |
| `NEEDS_YOU_OUTBOX` | `~/.local/state/needs-you/outbox` | *Env only.* Where queued requests are kept |

### Updates

`needs-you update` and the daily automatic update the 5-minute flush runs. [Keeping up to date](updates.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_AUTO_UPDATE` | off; the installers write `1` | *on/off*: the flush runs `needs-you update` once a day. `needs-you update --enable-auto` / `--disable-auto` set it |
| `NEEDS_YOU_UPDATE_HUB` | the first hub in `NEEDS_YOU_URLS` | The one hub updates come from: an `http(s)://` URL |
| `NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH` | on for automatic updates, off by hand | *on/off*: refuse an update that can't be checked against the GitHub release |
| `NEEDS_YOU_GH` | `gh` on `PATH` | *Env only.* The `gh` to check releases with, or `none` (no check, as the tests do). The server hub's updater and `install-hub.sh` read it too |

### Agent hooks

The hook every agent shares (`needs-you-hook.sh`: Claude Code, Codex, Gemini, Copilot, Kimi, Grok, Cursor, Cline, Aider) and the opencode plugin. [Claude Code](claude-code.md), [Claude Code everywhere](claude-code-everywhere.md), and each agent's guide.

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_AGENT_ALERTS` | unset: on in Orca terminals only | *on/off*, lowercase: agent cards from every session on this machine |
| `NEEDS_YOU_AGENT_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | A context, lowercase |
| `NEEDS_YOU_AGENT_PRIORITY` | `normal` | A priority, lowercase |
| `NEEDS_YOU_AGENT_LINK` | automatic editor links | `none`, or one link `Label=url-template` (`{handle}`, `{session}`, `{cwd}`, `{host}`) |
| `NEEDS_YOU_AGENT_EXPIRY_HOURS` | `48` | Hours a card lives after its last post; `0` never expires |
| `NEEDS_YOU_AIDER_EXPIRY_HOURS` | `1` | The same for Aider's cards |
| `NEEDS_YOU_FINISHED_EXPIRY_HOURS` | `3` | Hours a finished turn's card ("Claude finished: …", "Codex finished its turn and is waiting for your next message", and the same for every agent) lives after its last post, never longer than `NEEDS_YOU_AGENT_EXPIRY_HOURS`; `0` uses that one. Approvals, questions and errors keep the long expiry |
| `NEEDS_YOU_AGENT_TURN_CARDS` | on | *on/off*: "finished its turn" cards (Codex, Gemini, opencode, Copilot, Grok, Kimi, Cursor, Cline; for Aider, its only card) |
| `NEEDS_YOU_TURN_TEXT` | on | *on/off*: a turn card names the session and shows the question the turn ended on; off keeps the plain card |
| `NEEDS_YOU_AGENT_QUESTIONS` | on | *on/off*: questions answerable from the card |
| `NEEDS_YOU_ANSWER_TIMEOUT` | `600` | Seconds a hook waits for an answer from the Mac, 30 to 3600; `0` or `off`: don't wait |
| `NEEDS_YOU_CONTEXT_ALERT_PCT` | `80` | Percent of the context window that posts a card; `0` or `off`: never |
| `NEEDS_YOU_CONTEXT_WINDOW` | `200000` (`1000000` for `[1m]` models) | The context window in tokens, a whole number |
| `NEEDS_YOU_SSH_ALIAS` | unset | This host's name in the Mac's `~/.ssh/config`: letters, digits, `.`, `_`, `@` or `-` |
| `NEEDS_YOU_ORCA_ENVIRONMENT` | unset | On a paired Orca server: its name in `orca environment list` on the Mac |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | The CLI's path (the pollers and `run-or-alert.sh` read it too) |
| `NEEDS_YOU_HOOK_LOG` | unset | *Env only.* Append one debug line per hook call to this file |
| `NEEDS_YOU_OPENCODE_HOOK` | next to the plugin | *Env only.* The hook the opencode plugin runs ([opencode](opencode.md)) |
| `LC_NEEDS_YOU_TERM` | unset | *Env only*, set in the Mac's shell and forwarded by ssh: which Mac terminal tab holds an SSH session ([Claude Code everywhere](claude-code-everywhere.md#terminal-button)) |

### Usage meters

Claude Code's status line helper (`needs-you-usage`) and Codex's hooks. [Claude Code](claude-code.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_USAGE_ALERT_PCT` | off | Percent of the 5-hour limit that posts a card, 0 to 100 |
| `NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT` | the 5-hour value | The same for the weekly limit; `0` turns it off |
| `NEEDS_YOU_USAGE_ACCOUNT` | none | A label for one of several logins: up to 40 letters, digits, `.`, `_` or `-` |
| `NEEDS_YOU_USAGE_METER` | on | *on/off*: send the usage meter to the Mac |

### Orca

[Orca](orca.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_ORCA_USAGE` | off | *on/off*: the 5-minute flush sends a usage meter per Orca account. `needs-you orca usage --enable` / `--disable` set it |
| `NEEDS_YOU_ORCA_BIN` | `orca` on `PATH`, else where Orca installs it | The Orca CLI's path |
| `NEEDS_YOU_ORCA_TIMEOUT` | `15` | Seconds `orca account list` may take, 1 to 60 |

### MCP server

[MCP server](mcp.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_CLI` | next to the server, then the repo, then `PATH`, then `~/.local/bin` | *Env only* (set in the agent's MCP config): the CLI's path |

### GitHub poller

`needs-you-github`. [GitHub](github.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_GITHUB_INCLUDE` | every repo | `owner` or `owner/repo`, comma-separated |
| `NEEDS_YOU_GITHUB_EXCLUDE` | none | The same; wins over include |
| `NEEDS_YOU_GITHUB_CONTEXTS` | `NEEDS_YOU_DEFAULT_CONTEXT` | `owner=work`, `owner/repo=personal` or `*=work`, comma-separated; a repo wins over its owner. `needs-you context github acme/side personal` sets one entry |
| `NEEDS_YOU_GITHUB_REASONS` | all | Reasons to post (`review`, `deploy`, `ci`, `mention`, `assign`, `merge`, `changes`, `conflict`, `checks`, `merged`), or only `-reason` items to turn some off |
| `NEEDS_YOU_GITHUB_INTERVAL` | `5` | Minutes between runs, at least 1 |
| `NEEDS_YOU_GITHUB_PR_DAYS` | `14` | Only your PRs updated in this many days, a whole number of at least 1 |
| `NEEDS_YOU_GITHUB_MAX_CARDS` | `20` | Cards open at once, a whole number of at least 1 |
| `NEEDS_YOU_GITHUB_PROJECT_STATUSES` | off | `Name` or `Name=priority`, comma-separated (no priority: `normal`) |
| `NEEDS_YOU_GITHUB_PROJECT_FIELD` | `Status` | The single-select field to watch |
| `NEEDS_YOU_GITHUB_SECURITY` | off | *on/off*: cards for open Dependabot alerts |
| `NEEDS_YOU_GITHUB_SECURITY_SEVERITIES` | `critical` | `critical`, `high`, `medium`, `low`, comma-separated |
| `NEEDS_YOU_GITHUB_SECURITY_PRIORITY` | `low` | A priority |
| `NEEDS_YOU_GITHUB_GH` | `gh` on `PATH` | The `gh` it runs |

### Linear poller

`needs-you-linear`. [Linear](linear.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_LINEAR_KEY_FILE` | `linear-key` next to the env file | The [key file](#key-and-token-files) |
| `NEEDS_YOU_LINEAR_KEY` | none | *Env only*, and only when there's no key file: the key itself. Prefer the file |
| `NEEDS_YOU_LINEAR_CATEGORIES` | all | `assigned`, `status`, `comment`, `mention`, comma-separated, or only `-category` items |
| `NEEDS_YOU_LINEAR_STATUSES` | `*=low` | `Name=priority` or `Name=off`, comma-separated; `*` is every other status |
| `NEEDS_YOU_LINEAR_TEAMS` | every team, default context, `low` | `KEY=context:priority`, comma-separated |
| `NEEDS_YOU_LINEAR_CONTEXTS` | the team's `NEEDS_YOU_LINEAR_TEAMS` context, else default context | `KEY=work\|personal` or `*=work\|personal`, comma-separated; only the context, never which teams are watched. `needs-you context linear ACME personal` sets one entry |
| `NEEDS_YOU_LINEAR_INTERVAL` | `5` | Minutes between runs, at least 1 |
| `NEEDS_YOU_LINEAR_MAX_CARDS` | `20` | Cards open at once, a whole number of at least 1 |
| `NEEDS_YOU_LINEAR_MAX_AGE_H` | `24` | Notifications older than this many hours are skipped, at least 1 |
| `NEEDS_YOU_LINEAR_API` | `https://api.linear.app/graphql` | An `https` URL (or `http` to loopback, for tests) |

### Jira poller

`needs-you-jira`. A bad Jira setting stops the run with a message rather than guessing. [Jira](jira.md).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_JIRA_SITE` | unset: off | `https://host[/path]` |
| `NEEDS_YOU_JIRA_AUTH` | `cloud` for `*.atlassian.net`, else `dc` | `cloud` or `dc` |
| `NEEDS_YOU_JIRA_EMAIL` | none | Your Atlassian account email (Cloud) |
| `NEEDS_YOU_JIRA_TOKEN_FILE` | `~/.config/needs-you/jira-token` | The [token file](#key-and-token-files) |
| `NEEDS_YOU_JIRA_CA_FILE` | the system CAs | A CA bundle file (Data Center with a private CA) |
| `NEEDS_YOU_JIRA_EVENTS` | all | `status`, `comment`, `assigned`, `mention`, comma-separated, or only `-event` items |
| `NEEDS_YOU_JIRA_STATUSES` | every status, `low` | `Name=priority` or `Name=off`, comma-separated; `*` is every other status |
| `NEEDS_YOU_JIRA_PROJECTS` | every project, default context, `low` | `KEY=context[:priority]`, comma-separated |
| `NEEDS_YOU_JIRA_CONTEXTS` | the project's `NEEDS_YOU_JIRA_PROJECTS` context, else default context | `KEY=work\|personal` or `*=work\|personal`, comma-separated; only the context, never which projects are watched. `needs-you context jira ACME personal` sets one entry |
| `NEEDS_YOU_JIRA_JQL_EXTRA` | none | A JQL clause ANDed on, up to 500 characters, no `ORDER BY` |
| `NEEDS_YOU_JIRA_WATCHING` | off | *on/off*: issues you watch too |
| `NEEDS_YOU_JIRA_INTERVAL` | `5` | Minutes between runs, at least 1 |
| `NEEDS_YOU_JIRA_MAX_CARDS` | `20` | Cards open at once, a whole number of at least 1 |

### Expiry poller

`needs-you-expiry`. What it watches is in `expiry.conf` ([Expiry dates](expiry.md)).

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_EXPIRY_CONFIG` | `expiry.conf` next to the env file | The list of certificates, domains and keys |
| `NEEDS_YOU_EXPIRY_DAYS` | `30=low,7=normal,1=urgent` | `days=priority`, comma-separated |
| `NEEDS_YOU_EXPIRY_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | A context. `needs-you context expiry "*" personal` sets it |
| `NEEDS_YOU_EXPIRY_FAILS` | `2` | Failed runs in a row before a "checks failing" card, a whole number of at least 1 |
| `NEEDS_YOU_EXPIRY_INTERVAL` | `24` | **Hours** between runs, at least 1 |
| `NEEDS_YOU_EXPIRY_MAX_CARDS` | `20` | Cards open at once, a whole number of at least 1 |
| `NEEDS_YOU_EXPIRY_TIMEOUT` | `10` | Seconds per network check, 1 to 60 |
| `NEEDS_YOU_EXPIRY_RDAP_BOOTSTRAP` | `https://data.iana.org/rdap/dns.json` | An `https` URL |

### The invite installer

The `curl` one-liner from an invite link (`/join/<code>/install.sh`). Its flags are in [Add a sender](add-a-sender.md); it writes the env file with `NEEDS_YOU_CONFIG` honoured.

| Variable | Default | Takes |
|---|---|---|
| `NEEDS_YOU_BIN_DIR` | `~/.local/bin` | *Env only.* Where it installs `needs-you` (no quotes, `$`, backticks, backslashes or newlines) |

## Key and token files

The pollers that need a secret read it from a file of its own, never from the env file. Each refuses a file that is a symlink, isn't yours, or that others can read or write; `needs-you doctor` names the problem and the fix.

| File | Default | Holds | Mode |
|---|---|---|---|
| Linear key | `~/.config/needs-you/linear-key` (next to the env file; `NEEDS_YOU_LINEAR_KEY_FILE`) | A Linear personal API key, one line | 600 |
| Jira token | `~/.config/needs-you/jira-token` (`NEEDS_YOU_JIRA_TOKEN_FILE`) | A Jira API token (Cloud) or personal access token (Data Center), one line | 600 |
| Env file | `~/.config/needs-you/env` | The sender token | 600 |
| `hub.json` | `~/.config/needs-you/hub.json` (`--user`), `/etc/needs-you/hub.json` | A server hub's config, with the peer secret | 600 (`--user`), 640 `root:needs-you` |
| `peer_secret_file` | none | A hub's peer secret, one line | 600: the hub won't start otherwise |

## Hub: hub.json

A server hub's config: plain JSON (see [`deploy/hub.example.json`](../../deploy/hub.example.json)), written by `install-hub.sh`. Every key can also be set by a flag on `needs_you_hub.py`, so no file is required: the flags named below, or `--set KEY=VALUE` for anything else (VALUE is parsed as JSON when it can be). `null` means unset. Numbers may also be given as strings (`"30"`). The hub refuses to start with a value of the wrong type or out of range, naming each bad key, and warns about a key it doesn't know (with "did you mean"). Check a config without starting anything:

```bash
python3 ~/.local/share/needs-you/hub/needs_you_hub.py --check-config --config ~/.config/needs-you/hub.json
```

Restart after editing: `systemctl --user restart needs-you-hub` (or `sudo systemctl restart needs-you-hub`). [Server hubs](../HUB.md).

| Key | Flag | Default | Takes, and what it does |
|---|---|---|---|
| `bind` | `--bind` (repeatable, or commas) | `127.0.0.1` | An address or a list. Listen addresses; `0.0.0.0`/`::` need `allow_any_interface` |
| `port` | `--port` | `8765` | A whole number, 0 to 65535 |
| `public_url` | `--public-url` | first bind address | A string: the URL others use. Put the MagicDNS name here |
| `db` | `--db` | `needs-you-hub.db` | A string: the SQLite path |
| `hub_id` | `--hub-id` | short hostname | 1-64 letters, digits, `.`, `_` or `-`. Unique per hub; LWW tie-break and self-peer detection |
| `peers` | `--peer` (repeatable) | `[]` | A list of strings: peer public URLs, used for replication and handed to senders as `hub_urls` |
| `peer_secret` | | | A string of 16+ characters, required when `peers` is set. Also `$NEEDS_YOU_PEER_SECRET` |
| `peer_secret_file` | `--peer-secret-file` | | A string: a file holding the peer secret, mode 600 (the hub won't start if group or others can read or write it) |
| `owner_token_file` | `--owner-token-file` | | A string or null. On start, make sure an owner token with the secret in this file exists (the Mac app uses this) |
| `owner_token_name` | `--owner-token-name` | `this-mac` | A string: its name. A changed secret replaces the old one |
| `parent_pid` | `--parent-pid` | | A whole number or null. Exit cleanly when that process is gone (checked every 2 s) |
| `install_dir` | `--install-dir` | the directory above `hub/` | A string: where `/dl/` files are read from |
| `text_retention_hours` | | `24` | A number. A closed or expired item's text is purged this long after it closed; a tombstone stays. `0` keeps the text until the item is deleted |
| `retention_days` | `--retention-days` | `30` | A number. Closed and expired items older than this are deleted. `0` keeps them forever |
| `freebind` | `--freebind` | `false` | `true` or `false`. Linux: bind before tailscaled has the address. The installer sets it |
| `allow_any_interface` | `--allow-any-interface` | `false` | `true` or `false`. Allow `0.0.0.0` / `::` |
| `allowed_hosts` | `--allowed-host` (repeatable) | `[]` | A list of strings (or one comma-separated string). Extra `Host` names the hub answers to, besides IP literals, `localhost`, bind names, `public_url`, and this machine's host and MagicDNS names. Anything else is a 421 (DNS-rebinding protection, [API.md](../API.md#conventions)). Also `$NEEDS_YOU_HUB_ALLOWED_HOSTS` (comma-separated), which is how to set it for the Mac app's hub (`launchctl setenv NEEDS_YOU_HUB_ALLOWED_HOSTS name`, then restart the app). `*` turns the check off |
| `self_update_dir` | | the config file's directory | A string or null: where the [updater's](../HUB.md#automatic-updates) `hub-update.json` and `hub-update-status.json` are, for `/v1/hub/update`. Without a config file (the Mac app's hub) there is none and the hub can't be asked to update |
| `update_request_interval_seconds` | | `900` | A number. At most one accepted `POST /v1/hub/update` per this many seconds (`429` with `Retry-After` otherwise) |
| `quiet` | `--quiet` | `false` | `true` or `false`. No access log |
| `access_log` | | `true` | `true` or `false`. One stderr line per request. Invite codes in `/join/` paths (and anything shaped like a code or token) are replaced with `<code>`/`<redacted>`, and control characters are escaped |
| `max_open_per_token` | | `60` | A whole number. Volume guard |
| `max_connections` | | `128` | A whole number. Connections served at once, across all binds (kept 64 under the file descriptor limit) |
| `request_read_seconds` | | `10` | A number. When `max_connections` is reached, a connection open longer than this (a slow request, or an answer its client stopped reading; never a reader's `/v1/stream`) is closed to make room; otherwise new ones are closed at once |
| `sse_heartbeat_seconds` | | `15` | A number of at least 0.1. How often `/v1/stream` sends a keep-alive |
| `default_expiry_hours` | | `24` | A number. Expiry for `done`/`info` items without `expires_at` |
| `maintenance_seconds` | | `600` | A number. Purge, WAL checkpoint and incremental vacuum interval |
| `vacuum_hours` | | `24` | A number. How often a full `VACUUM` may run (only when over 25% is free) |
| `redeem_fail_limit` | | `10` | A whole number. Failed invite redeems per client IP per window before `429` |
| `redeem_fail_window_seconds` | | `600` | A number |
| `answer_rate_limit` | | `30` | A whole number. Answers (`POST /v1/items/{id}/answer`, counted whether taken or not) per token per window before `429` |
| `answer_rate_window_seconds` | | `60` | A number |
| `answer_read_rate_limit` | | `120` | A whole number. Reads of an answer (`GET /v1/items/answer`) per token per `answer_rate_window_seconds` before `429` |
| `answer_waits_per_token` | | `4` | A whole number. Long polls for an answer one token may hold open |
| `post_rate_limit` | | `120` | A whole number. Posts (`POST /v1/items`, re-posts included) per token per window before `429 rate_limited` with `Retry-After`: a sender stuck in a loop (ADR 0010). Status sets and clears get a limit of the same size, counted apart. `0` is off |
| `post_rate_window_seconds` | | `60` | A number |
| `anti_entropy_seconds` | | `60` | A number. How often each peer is pulled |
| `outbox_poll_seconds` | | `2` | A number. Replication outbox check interval |
| `retry_base_seconds` | | `1` | A number. Push backoff, first wait |
| `retry_max_seconds` | | `300` | A number. Push backoff, longest wait |
| `peer_timeout_seconds` | | `5` | A number of at least 0.1. Per request to a peer |

Every number above is at least 0 unless it says otherwise.

## Hub: hub-update.json

The server hub's automatic updates, next to `hub.json`; `install-hub.sh` writes it and its flags change it ([Automatic updates](../HUB.md#automatic-updates)). A file that can't be read, or a value it doesn't take, turns automatic updates off, and the updater's log and `--check-config` name the key.

| Key | Flag | Default | Takes |
|---|---|---|---|
| `auto_update` | `--auto-update` / `--no-auto-update` | `true` (new installs) | `true` or `false` |
| `channel` | `--update-channel` | `stable` | `stable` or `prerelease` |
| `soak_hours` | `--update-soak-hours` | `24` | Hours to wait after a release is published, 0 to 720 |
| `gh` | `--update-gh` | `""` (`gh` on `PATH`) | `""` or an absolute path |

## Hub environment variables

| Variable | Read by | Takes |
|---|---|---|
| `NEEDS_YOU_PEER_SECRET` | the hub | The peer secret, when neither `peer_secret` nor `peer_secret_file` is set |
| `NEEDS_YOU_HUB_ALLOWED_HOSTS` | the hub | Extra `Host` names, comma-separated (how the Mac app's hub gets them: `launchctl setenv`) |
| `NEEDS_YOU_HUB_CONFIG` | `needs-you-admin` | The `hub.json` it reads (default: the one `install-hub.sh` wrote) |

## Installer flags

`scripts/install-hub.sh` (a server hub) checks every flag's value before installing anything, and runs the new `hub.json` through `--check-config` before it replaces the old one. `--help` lists them; [Server hubs](../HUB.md) explains them.

| Flag | Sets | Takes |
|---|---|---|
| `--user` | | install under your home directory, as a `systemd --user` service |
| `--bind ADDR` | `bind` | An address, repeatable or comma-separated (never `0.0.0.0`/`::`) |
| `--port N` | `port` | 1 to 65535 |
| `--hub-id ID` | `hub_id` | 1-64 letters, digits, `.`, `_` or `-` |
| `--public-url URL` | `public_url` | `http(s)://host:port` |
| `--peer URL` | `peers` | A hub's `http(s)://host:port`, repeatable |
| `--peer-secret-file F`, `--peer-secret S`, `--generate-peer-secret` | `peer_secret` | A secret of 16+ characters |
| `--join -` | a peer link | A peer invite link, `http(s)://<hub>/join/nyi_...`, on stdin |
| `--reconfigure`, `--no-start`, `--no-invite` | | |
| `--auto-update`, `--no-auto-update`, `--update-channel`, `--update-soak-hours`, `--update-gh` | `hub-update.json` | as in [hub-update.json](#hub-hub-updatejson) |

`scripts/setup-sender.sh` (a sender, from a checkout) writes the same env file as the invite installer; `--help` lists its flags. It checks `--url` (`http(s)://`), `--test-context` (a context), `--context-alert` (0 to 100), `--ssh-alias`, `--orca-environment` and `--agent-link` the same way the hook does, and exits 2 with what each takes.

## Set by needs-you itself

These are set by needs-you for its own child processes, or are seams for the tests. Never set them yourself; a line for one in the env file gets a `doctor` warning.

| Variable | Set by |
|---|---|
| `NEEDS_YOU_AGENT_SESSION` | the opencode plugin (and any connector), for the agent's commands |
| `NEEDS_YOU_WATCH_PID` | the hook, for `needs-you answer-wait` |
| `NEEDS_YOU_INSTALLER` | the invite installer and `needs-you install-*`, for the agent installers they run |
| `NEEDS_YOU_HOOK_PLATFORM`, `NEEDS_YOU_HOOK_TTY` | tests: the hook's platform and terminal |
| `NEEDS_YOU_HUB_UPDATE_NOW` | tests: the hub updater's clock |
| `NEEDS_YOU_INSTALL_CHECK_OWNERSHIP`, `NEEDS_YOU_RELEASE_OFFLINE` | tests: `install-hub.sh`'s root-only checks, and no GitHub |

## Development and release

Read by the scripts that build, release and check needs-you ([CONTRIBUTING](../../CONTRIBUTING.md)), never by a sender or a hub.

| Variable | Read by | Takes |
|---|---|---|
| `NEEDS_YOU_SKIP_APP` | `scripts/build-release.sh` | `1`: skip the Mac app |
| `NEEDS_YOU_TAG` | `scripts/build-release.sh` | `vX.Y.Z`: fail unless it matches `VERSION` |
| `NEEDS_YOU_TESTS_RESULT` | `scripts/build-release.sh` | The test job's result, recorded in the manifest |
| `NEEDS_YOU_VERSION`, `NEEDS_YOU_DIST` | `mac/scripts/bundle.sh`, from `build-release.sh` | The version and output directory |
| `NEEDS_YOU_PYTHON39` | `scripts/check.sh` | A Python 3.9 to run the suite on as well |
| `NEEDS_YOU_LINT_BASE` | `scripts/lint_repo.py`, `scripts/check.sh` | The base commit for the commit checks (default `origin/main`) |
| `NEEDS_YOU_LEAK_PATTERNS` | `scripts/lint_repo.py` | A file of extra leak patterns |

## Checking it: needs-you doctor

`needs-you doctor` ([Troubleshooting](troubleshooting.md#start-here-needs-you-doctor)) checks, besides the hubs and hooks:

- **config:** the env file exists, is mode 600, and sets a hub URL and a token.
- **settings:** every `NEEDS_YOU_*` name in the env file and the environment is one on this page (a typo gets "did you mean"), every value is one its setting takes, and no line is one that does nothing there (an *env only* variable, one needs-you sets itself, a hub's or a line that isn't `NAME=VALUE`). It names the setting and what it takes, never the value.
- **key files:** the Linear key and Jira token files, when there are any: a regular file, yours, mode 600.
- **hub config:** on a machine with a server hub, `hub.json` (and `hub-update.json`): its mode, and the hub's own `--check-config`.
