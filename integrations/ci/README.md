# needs-you from CI, cron and systemd

Jobs that run unattended should tell you when they fail and clear the alert when they pass again. Use one stable key per job (`<context>:<project>:<job>`), post on failure, resolve on success.

| File | Use it for |
|---|---|
| [`github-actions.yml`](github-actions.yml) | GitHub Actions: joins the tailnet with the Tailscale action, then `curl`s the hub (with failover). No CLI install. |
| [`run-or-alert.sh`](run-or-alert.sh) | Wrap any command: failure posts, success resolves, exit code passes through. |
| [`crontab.example`](crontab.example) | cron lines: `needs-you flush`, a wrapped nightly job, a `done` FYI. |
| [`systemd/needs-you-failed@.service`](systemd/needs-you-failed@.service) | `OnFailure=` template for any unit. |
| [`systemd/backup.service.example`](systemd/backup.service.example) | A job unit wired to it, with resolve-on-success. |

## GitHub Actions

1. **Tailscale:** create an OAuth client (Tailscale admin → Settings → OAuth clients) with write access to auth keys for `tag:ci`, and allow `tag:ci` to reach the hubs on `tcp:8765` in your ACL. Runners join as ephemeral nodes.
2. **Token:** mint a token for this repo's CI on the hub (one per repo, never a machine's token). See [docs/HUB.md](../../docs/HUB.md).
3. **Secrets:** `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `NEEDS_YOU_URLS` (comma-separated hubs), `NEEDS_YOU_TOKEN`.
4. Copy the Tailscale step and the `needs-you` step from [`github-actions.yml`](github-actions.yml) to the end of your job. Both run with `if: always()`, and the needs-you step has `continue-on-error: true`, so alerting can't fail the build.

The step posts `kind=needs` with a link to the run when the job fails, and resolves the same key when it succeeds. The key is `work:<repo>:<workflow>:failed`; change the `work` prefix and `context` for personal repos.

Other CI systems: the same `curl` body works anywhere that can reach the tailnet. The shape is in [docs/AGENT-GUIDE.md](../../docs/AGENT-GUIDE.md#with-curl).

## cron

```bash
# one-time: make this machine a sender (installs the CLI to ~/.local/bin)
./scripts/setup-sender.sh

crontab -e
```

```cron
*/10 * * * *  /home/me/.local/bin/needs-you flush >/dev/null 2>&1
0 3 * * *     /home/me/needs-you/integrations/ci/run-or-alert.sh --key personal:hub-b:backup --priority urgent --title "hub-b nightly backup failed" -- /usr/local/bin/backup.sh
```

`run-or-alert.sh` never puts the command's output in the item (output is where secrets leak). Link to your logs with `--link "Logs=https://..."` instead. Its context defaults to `personal` for `personal:*` keys and `work` otherwise.

## systemd

```bash
sudo cp integrations/ci/systemd/needs-you-failed@.service /etc/systemd/system/
sudoedit /etc/systemd/system/needs-you-failed@.service   # set User= and the CLI path
sudo systemctl daemon-reload
```

Then add `OnFailure=needs-you-failed@%n.service` to any unit (directly, or with `systemctl edit <unit>`), and optionally an `ExecStartPost=-…needs-you resolve…` line like the one in [`backup.service.example`](systemd/backup.service.example) to clear the item on the next success.

Test it: `sudo systemctl start needs-you-failed@test.service` should post "test failed on <host>".
