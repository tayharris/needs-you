# needs-you for expiring certificates, domains and keys

`needs-you-expiry` is a daily poller for one sender machine that posts a card before something you own expires: the TLS certificate a host serves, a domain's registration (from RDAP) or an API key whose date you know. The card's priority rises as the date nears, and it clears itself once the date moves (you renewed) or you take the line out of the list. It's opt-in: it does nothing until `~/.config/needs-you/expiry.conf` exists.

Setup is in [docs/guides/expiry.md](../../docs/guides/expiry.md).

## Files

| File | What |
|---|---|
| [`needs-you-expiry`](needs-you-expiry) | The poller. Python 3.9+ stdlib, one file. Copy it to `~/.local/bin/` |
| [`expiry.conf.example`](expiry.conf.example) | An example list. Copy it to `~/.config/needs-you/expiry.conf` |
| [`crontab.example`](crontab.example) | The cron line (Linux), daily at 09:17 |
| [`systemd/needs-you-expiry.service`](systemd/needs-you-expiry.service), [`.timer`](systemd/needs-you-expiry.timer) | A systemd user timer instead of cron |
| [`io.needs-you.expiry.plist`](io.needs-you.expiry.plist) | A LaunchAgent (macOS) |

## The list

`~/.config/needs-you/expiry.conf` (next to the `env` file; `NEEDS_YOU_EXPIRY_CONFIG` points elsewhere), one thing per line, `#` comments, shell-style quotes:

```
tls     example.com                       # the certificate on port 443
tls     mail.example.com:993              # any port that speaks TLS from the first byte
domain  example.com                       # the registration's expiry, from RDAP
key     "Figma PAT"  2026-12-31           # the day it stops working
key     "Deploy key" 2027-03-01  renew=https://example.com/settings/keys  context=personal
```

| Option | Lines | What |
|---|---|---|
| `renew=<url>` | any | The card's **Renew** link. Must be `https` and fit the hub's link grammar, else the line is refused |
| `context=work\|personal` | any | The card's context and key prefix (default `NEEDS_YOU_EXPIRY_CONTEXT`) |
| `verify=no` | `tls` | Read the date of a self-signed or private-CA certificate without verifying it |

A line it can't read (unknown kind, bad date, bad option) is a failing check (below), so a typo doesn't go unnoticed. STARTTLS ports (SMTP 587, IMAP 143) aren't supported: use the implicit-TLS port, or a `key` line.

## How it works

Each run:

1. **TLS:** a TLS handshake with each host, verified against the system's CAs and the host name, then the certificate's `notAfter`. Nothing else is sent. An **expired** certificate fails verification, so that one connection is repeated without verifying, only to read its date. A certificate that fails verification for any other reason (wrong host name, untrusted chain) gets an urgent "not trusted" card at once, never a date: clients refuse it. `verify=no` on the line skips verification for that host.
2. **Domains:** the RDAP server for the TLD comes from IANA's bootstrap file `https://data.iana.org/rdap/dns.json` (the longest matching suffix, so `co.uk` before `uk`), cached for a week in `~/.local/state/needs-you/rdap-dns.json` and reused if a refresh fails. Then `GET <server>/domain/<name>` and the `expiration` event. Every fetch is HTTPS with the default verifying context; redirects off HTTPS are refused. Registries that publish no expiry date (some ccTLDs) are a failing check: use a `key` line for those.
3. **Keys:** the date on the line, read as 00:00 UTC that day.
4. **Cards:** one per thing inside the window, re-posted every run with `--expires-in` of 3x the interval (72 hours), so a poller that stops leaves nothing stale. Titles carry the date, not a countdown, so a daily re-post doesn't re-animate the card; only a priority change does. A thing out of the window, or gone from the list, has its card resolved. Deleting the whole list resolves everything it posted.

It posts through the `needs-you` CLI, so the outbox and hub failover apply. While the outbox has a backlog (no hub reachable), unchanged cards aren't renewed.

## Cards

`<ctx>` is the line's context. Thresholds come from `NEEDS_YOU_EXPIRY_DAYS` (default `30=low,7=normal,1=urgent`): a card appears inside the largest one and takes the priority of the nearest one it's inside. Expired is always urgent.

| Thing | Title | Key | Links |
|---|---|---|---|
| `tls` | TLS certificate for example.com expires 2026-10-21 (or *expired*) | `<ctx>:expiry:tls:example.com` (`:993` kept for other ports) | Renew, if set |
| `tls`, not trusted | TLS certificate for example.com not trusted: *reason* (urgent) | the same key | Renew, if set |
| `domain` | Domain example.com expires 2027-08-13 | `<ctx>:expiry:domain:example.com` | Renew, if set; RDAP (the record, https only) |
| `key` | Figma PAT expires 2026-12-31 | `<ctx>:expiry:key:Figma-PAT` (characters a key can't hold become `-`) | Renew, if set |
| checks failing | Expiry checks failing on devbox: 2 checks (low) | `<default ctx>:expiry:devbox:checks-failing` | body: each failing check, its error and the day it started |
| poller crashed | Expiry checks stopped on devbox: needs-you-expiry failed (low) | `<default ctx>:expiry:devbox:poller-failing` | body: run `needs-you-expiry -v` |

A check that fails (host unreachable, timeout, RDAP error, an unreadable line, even a bug in one check) keeps its last date, so a card already up stays up, and the run carries on with the other checks. Once any check has failed `NEEDS_YOU_EXPIRY_FAILS` (2) runs in a row, one low card per machine lists all of them: one card when the network is down, never one per host. It clears on the run where every check works again. A bug that stops the whole run posts the `poller-failing` card once; the next good run resolves it. No `source.event` is sent.

At most `NEEDS_YOU_EXPIRY_MAX_CARDS` (20) expiry cards are open at once, the nearest dates first.

## Config

In `~/.config/needs-you/env` (or the environment). All optional.

| Variable | Default | What |
|---|---|---|
| `NEEDS_YOU_EXPIRY_CONFIG` | `expiry.conf` next to the env file | The list |
| `NEEDS_YOU_EXPIRY_DAYS` | `30=low,7=normal,1=urgent` | Thresholds, `days=priority` |
| `NEEDS_YOU_EXPIRY_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | Context for lines without `context=` and for the failing cards |
| `NEEDS_YOU_EXPIRY_FAILS` | `2` | Failed runs in a row before the checks-failing card |
| `NEEDS_YOU_EXPIRY_INTERVAL` | `24` | Hours between runs; cards expire after 3x this. Match your schedule |
| `NEEDS_YOU_EXPIRY_MAX_CARDS` | `20` | Cap on open expiry cards |
| `NEEDS_YOU_EXPIRY_TIMEOUT` | `10` | Seconds per check |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | Path to the CLI |

Run it on **one** machine per list. Keys dedupe, but two machines with different lists would resolve each other's cards.

## Safety

- No tokens: TLS needs none, RDAP is public. The list holds names and dates only; never put a key's value in it.
- Only text you wrote (names, dates) and dates read from certificates and RDAP reach a card. Names are cleaned (control, bidi and zero-width characters removed) and truncated. RDAP's other fields are never copied.
- Links are `https` only and checked against the hub's link grammar (a copy of `LINK_RAW_PATTERN`; `tests/test_expiry.py` checks it matches).
- It always exits 0, and writes one stderr line per problem.

## Test

```bash
/usr/bin/python3 -m unittest discover -s tests -p test_expiry.py   # loopback TLS server, fake RDAP, real local hub; no network
needs-you-expiry --dry-run -v                                        # your real list: prints what it would post, posts nothing
```

The TLS tests make a self-signed certificate with `openssl` and skip without it.
