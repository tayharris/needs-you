# Release signing and provenance

How needs-you releases prove where they came from, and the one step only the owner can take:
creating the Ed25519 release key. Background: [security audit #17](audit-2026-10-07.md#17-low-installer-and-release-integrity-mostly-fixed-the-signing-key-is-the-owners-step).

## What is in place

| Layer | Who checks it | Status |
|---|---|---|
| `SHA256SUMS` and `release-manifest.json` (sha256 and size of every asset) | Mac updater, `needs-you update`, the release job itself | Done |
| The invite installer checks every `/dl` file against the sha256 list on the join page | `install.sh` | Done (integrity, same source) |
| GitHub build provenance (`actions/attest-build-provenance`) for every release asset, `release-manifest.json` included | `gh attestation verify`; `needs-you update` when `gh` is installed | Done, **public repository only** (below) |
| Ed25519 signature over `release-manifest.json` (`release-manifest.json.sig`) | Mac updater, once a key is pinned | CI step done; **needs the owner's key** |

### Build provenance

The release job (`.github/workflows/release.yml`, "Attest build provenance") attests the DMG,
the app zip, the server tarball, the CLI, `release-manifest.json` (and `.sig` when present) and
`SHA256SUMS`. The attestation is a Sigstore-signed statement that this file was built by that
workflow, from that commit, in `tayharris/needs-you`. Verify any downloaded asset with:

```bash
gh attestation verify NeedsYou-1.2.3-macos.zip --repo tayharris/needs-you
gh attestation verify release-manifest.json --repo tayharris/needs-you
```

`needs-you update`, when `gh` is installed, downloads the release's `release-manifest.json`
and runs, on that downloaded file (argument array, 120 s timeout):

```bash
gh attestation verify release-manifest.json --repo tayharris/needs-you \
  --signer-workflow tayharris/needs-you/.github/workflows/release.yml \
  --source-ref refs/tags/vX.Y.Z --predicate-type https://slsa.dev/provenance/v1 \
  --deny-self-hosted-runners --format json
```

It then parses the JSON and requires one verified attestation whose subject sha256 equals the
sha256 it computed for that file, with SLSA provenance, `sourceRepositoryURI`
`https://github.com/tayharris/needs-you`, `sourceRepositoryRef` `refs/tags/vX.Y.Z`,
`buildSignerURI` the release workflow, and `runnerEnvironment` `github-hosted` (these
certificate fields come from GitHub's OIDC token, so a workflow can't forge them). A non-zero
exit, empty or invalid JSON, a timeout or any mismatch refuses the update, like the
release-match check.

**What this covers:** the CLI verifies provenance of the manifest only, and binds every file
it installs to it through checksums: each file from the hub must equal its copy in the
release's server tarball, and the tarball's sha256 must equal both its `SHA256SUMS` line and
its entry in the attested manifest.

**Self-hosted runners:** releases must be built on GitHub-hosted runners for this check to
pass. Pointing the `RELEASE_MAC_RUNNER` variable (on `main`) at a self-hosted Mac makes every
release fail `--deny-self-hosted-runners`, so `needs-you update` with `gh` refuses it. That is
deliberate: a self-hosted runner is a machine GitHub can't vouch for. If releases ever move
there for good, it is a trade-off to decide and document here (and drop the flag in the CLI
in the same change), never something to allow silently.

**Private repository:** GitHub creates artifact attestations for public repositories on this
plan (private ones need GitHub Enterprise Cloud). While `tayharris/needs-you` is private, the
release job skips the step and `needs-you update` says "no build provenance to check (… is
private …)" instead of refusing. Once the repository is public, every new release is attested
and a release without a valid attestation is refused.

### What a signature adds

A checksum or an attestation from the same repository proves the files came from its release
workflow. It doesn't stop someone who can push a tag (or steal a token that can) from running
that workflow on code of their choosing. A key that lives only offline and in one Actions
secret narrows that: the Mac app accepts an update only if `release-manifest.json.sig` verifies
against the key compiled into the app it is replacing.

## Owner steps: create and pin the signing key

Do this once, on a machine you trust, ideally offline. Never commit the private key, never
paste it into an issue, chat or agent session, and never let an agent generate it for you.
Nothing in this repository creates or stores it.

1. **Create the key pair** (OpenSSL 3; macOS's `/usr/bin/openssl` is LibreSSL and can't, so use
   Homebrew's `$(brew --prefix openssl@3)/bin/openssl`):

   ```bash
   umask 077
   openssl genpkey -algorithm ed25519 -out needs-you-release.key.pem
   openssl pkey -in needs-you-release.key.pem -pubout -out needs-you-release.pub.pem
   openssl pkey -in needs-you-release.key.pem -pubout -outform DER | tail -c 32 | base64
   ```

   The last line prints the **raw public key in base64** (44 characters, ending in `=`). Keep it;
   it is public.

2. **Store the private key as the Actions secret** `RELEASE_MANIFEST_SIGNING_KEY`, the whole PEM
   file including the `-----BEGIN PRIVATE KEY-----` lines:

   ```bash
   gh secret set RELEASE_MANIFEST_SIGNING_KEY --repo tayharris/needs-you < needs-you-release.key.pem
   ```

   Optional hardening: create a `release` environment with you as a required reviewer
   (Settings → Environments), set the secret there with `--env release`, and add
   `environment: release` to the `release` job, so no tag can use the key without your approval.

3. **Keep an offline backup** of `needs-you-release.key.pem` (an encrypted USB drive, or your
   password manager), then delete it from the machine you made it on:
   `rm -P needs-you-release.key.pem` on macOS, `shred -u` on Linux.

4. **Check the CI step** before pinning: run a release (or push a `v*` tag for the next
   version) and confirm the draft has `release-manifest.json.sig` and the job log says
   `signed release-manifest.json; public key (raw, base64): <the value from step 1>`. Then verify
   it by hand:

   ```bash
   gh release download v1.2.3 --repo tayharris/needs-you -p release-manifest.json -p release-manifest.json.sig
   base64 -d < release-manifest.json.sig > sig.bin
   openssl pkeyutl -verify -rawin -pubin -inkey needs-you-release.pub.pem -in release-manifest.json -sigfile sig.bin
   ```

   Without the secret the step prints a notice ("Unsigned release") and the release ships as
   before.

5. **Pin the public key in the app**: in `mac/Sources/NeedsYouCore/Updater.swift`, set

   ```swift
   public static let pinnedManifestKey: String? = "<raw public key, base64, from step 1>"
   ```

   and ship that in the next release. From then on that app refuses any update whose
   `release-manifest.json.sig` is missing or doesn't verify. Pin only after step 4 succeeded:
   an app with a pinned key and a workflow without the secret can't update itself.

### Rotating or revoking the key

If the key may have leaked: make a new pair (step 1), replace the secret (step 2), and release
an app that pins the new key. Apps in the field still check the old key, so that one release
must be signed with the old key; if the old key is lost or must not be used, users install that
release by hand (DMG) instead of through the updater. Mention the rotation in the release notes.

### Senders (the CLI)

The CLI can't verify Ed25519 with the Python standard library (hard rule 1: no dependencies),
so it relies on: the invite hub's `/dl/manifest.json` checksums, the transport rules in
`needs-you update` (https, loopback or the tailnet, pinned address), the GitHub release match,
and build provenance through `gh attestation verify` when `gh` is installed.
