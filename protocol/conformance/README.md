# Hub conformance suite

Black-box tests every needs-you hub implementation must pass ([ADR 0004](../../docs/adr/0004-always-on-hub.md),
[ADR 0012](../../docs/adr/0012-mac-hub-peers.md)). They talk to a running hub over HTTP and
check the contract in [API.md](../../docs/API.md): health, roles, validation (including the
shared link cases in `tests/fixtures/link_cases.json`), upsert and dedupe, resolve, patch,
`cursor`/`since` paging, the volume guard, answers, invites and peer invites, and replication
(last writer wins, the same-key merge, a second hub catching writes, tokens and answers).

Python 3.9+ standard library only. Run it against a throwaway hub: it writes items, mints
tokens and pairs (then removes) a fake peer.

```bash
NEEDS_YOU_CONFORMANCE_URL=http://127.0.0.1:8765 \
NEEDS_YOU_CONFORMANCE_OWNER=<an owner token on that hub> \
NEEDS_YOU_CONFORMANCE_PEER_SECRET=<its peer secret> \
NEEDS_YOU_CONFORMANCE_URL_B=http://127.0.0.1:8766 \
python3 -m unittest discover -s protocol/conformance -v
```

| Variable | Needed for |
|---|---|
| `NEEDS_YOU_CONFORMANCE_URL` | Everything (without it every case is skipped) |
| `NEEDS_YOU_CONFORMANCE_OWNER` | Everything: the suite mints its own sender and reader tokens through invites |
| `NEEDS_YOU_CONFORMANCE_PEER_SECRET` | The `/v1/replicate` cases |
| `NEEDS_YOU_CONFORMANCE_URL_B` | The cross-hub cases: a second hub peered with the first |
| `NEEDS_YOU_CONFORMANCE_MAX_OPEN` | The volume guard, when the hub's `max_open_per_token` isn't 60 |
| `NEEDS_YOU_CONFORMANCE_WAIT` | Seconds to wait for replication (default 20) |

`tests/test_conformance.py` starts two peered reference hubs (`hub/needs_you_hub.py`) as
separate processes and runs this suite against them, so CI runs it with the rest of the tests.
When the wire contract changes, change the suite in the same branch (the `api-change` skill).
