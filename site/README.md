# site/

The needs-you site: the landing page, and the guides from `docs/` as pages. Plain HTML, CSS and a few lines of vanilla JS: no framework, no npm. The only build step is the guides generator, a stdlib Python script whose output is committed.

| File | What |
|---|---|
| `index.html` | The whole page: what it is, the live pill demo (`#demo`), how it works, how agents use it (a command and the card it makes, drawn in HTML), what it looks like (the panel and the pill's states), under the hood (architecture diagram, measured resource use), Works with, Install, Open source |
| `styles.css` | All styles. Built on the owner's shared design tokens: primitives (the only hexes, `tests/test_site.py` enforces it) then semantic variables on `:root`. Dark-first, light via `prefers-color-scheme: light`. IBM Plex Sans/Mono bundled in `fonts/` (Latin1 woff2 subsets, `fonts/OFL.txt`); the pill's priority colours and link button match the Mac app (`mac/Sources/NeedsYou/Views/Theme.swift`). Landing-page sections space every block by one rule (the `.home section > * + *` flow margins), and text stops at `--measure` |
| `site.js` | `REPO_URL`, the one GitHub constant, Copy buttons on code blocks marked `data-copy`, and the live demo (the page works without JS) |
| `guides/` | **Generated, don't edit.** One page per guide, plus `guides/index.html`, built from the markdown by `scripts/build_site_guides.py` (see [Guides](#guides)) |
| `_headers` | Cloudflare Pages response headers (CSP and other security headers) |
| `img/` | Screenshots of the app (2x PNGs, each under 200 KB), made from example items by `mac/scripts/screenshots.sh`, then optimised by hand (the flat backdrop around the panel made transparent, a 256-colour palette; any PNG optimiser will do). The guides in `docs/guides/` use these same files. Retake them when the panel or Settings changes visibly; check each one by eye for names, hosts or tokens before committing |

The favicon is an inline SVG data URI in `index.html`, so there's no separate icon file.

## The live demo

`#demo` on the landing page is a working model of the pill, drawn in HTML and CSS (`.pv` for the pill, `.pp` for the panel) and run by `site.js` (vanilla JS, no libraries). The examples are `EXAMPLES` in `site.js`; each has the `needs-you add` command that would have posted it.

- **Visitors can press it.** The link button shows the real destination and the result ("Opened VS Code · marked done") without going anywhere, and the card is done. The card itself (`.pv-hit`, a button under the card's text) opens the panel at that card; the pill opens the panel when it's idle ("All clear in Work") or showing a count. In the panel, Done removes a card, its link button says it opened but leaves the card (as in the app), and Close or Escape goes back to the pill. **Send a test alert** brings in the next example and shows its command (to read: no Copy button, like every example on the site).
- **Left alone, it plays itself:** each example springs out of the pill, a pointer presses its link button, the card is marked done. A press, key or focus in the demo stops the pointer; it comes back after 10 s without one (mouse movement over it keeps it waiting, and it never comes back while keyboard focus is in the screen). It pauses while the tab is hidden, while it's off screen and when the reader presses Pause.
- **Accessible:** all real buttons, keyboard operable, with focus moved sensibly (to the card when the panel opens, to the next card after Done, back to the pill on Close). The caption is a live region only for what the visitor did; the self-playing loop stays quiet.
- **Reduced motion:** no pointer, no springs, no Pause button, but it all still works.
- **Without JS** the screen is `inert` and shows the first alert, still: the HTML is that frame, so keep the markup and `EXAMPLES[0]` the same (`tests/test_site.py` checks).

The layout follows the app: title and meta on full-width lines, the link button (label, the fainter real destination, an arrow) on its own row below. On wide screens it sits in a right-hand rail and stays in view as you scroll; under 68rem it's inline under the intro, so it never covers text, and opening the panel only makes the screen taller. Examples use placeholder names only (`devbox`, `build-box`, `acme-api`, `ci.example.com`, `github.com/acme`).

Screenshots sit on a `.stage` (a quiet backdrop with room around the image) with the caption under it, outside the frame. CSS sets how big each is shown, so a retaken PNG with new dimensions only needs its `width`/`height` attributes updated (half the pixels; `tests/test_site.py` checks).

## Guides

`site/guides/` is the markdown in `docs/` as pages: every `docs/guides/*.md`, plus `docs/HUB.md`, `docs/AGENT-GUIDE.md` and `docs/API.md`. After editing any of them:

```bash
python3 scripts/build_site_guides.py           # rewrite site/guides/
python3 scripts/build_site_guides.py --check   # exit 1 if site/guides/ is stale (what the test checks)
```

and commit the markdown and the pages together; `tests/test_site_guides.py` fails when they differ, so CI catches a forgotten rebuild.

- **Which pages, in which order:** `GROUPS` (the index's sections, in order: Start here, Agents, Servers, CI and tools, More guides, Run it, Reference) and `CURATED` (group, source, page name, short title, summary for the index, in order within each group) at the top of the script. A new `docs/guides/*.md` that isn't listed is published anyway, under *More guides* (after the setup guides, before Run it), with its `# ` title and first paragraph; add it to `CURATED` to place and describe it.
- **Markdown:** the subset `docs/` uses: headings (with GitHub's anchor ids, so `file.md#section` links keep working), paragraphs, nested and task lists, fenced code, tables, blockquotes, links, bold, italic. All HTML in the markdown is escaped, except `<img>` tags pointing into `site/img/` (rebuilt from `src`, `width` and `alt`, with the height read from the PNG). A line of images becomes a figure on a stage; a one-line italic paragraph right after it (`*Settings → Panel → Opacity, at the defaults.*`) becomes its caption.
- **Links:** a relative link to a published doc becomes a link to its page (link text that is just a file name, like `tailscale.md`, shows the page's title); `site/img/...` becomes `../img/...`; anything else in the repo goes to GitHub through `REPO_URL`. A link to a missing file or anchor, or a plain `http://` link, fails the build. Each page ends with a link to its markdown on GitHub.
- **Copy buttons:** only on shell blocks that run exactly as written (`copyable()` in the script: no `<placeholders>`, `...`, example hosts or names, tokens). The real setup commands come from the app's invite flow, so examples are there to read, not paste.
- **Look:** the same header, footer and `styles.css` as the landing page (the `.doc` rules). Tables and code blocks scroll inside themselves on a phone.

## Works with

The agents list is one block in `index.html` (`<section id="works">`), with a matching "Works with" line in the top-level `README.md`. Move an entry from **Coming soon** to **Supported**, with a `data-repo` link to its guide, only once its integration is merged and tested. Text only, no third-party logos.

## Preview

```bash
python3 -m http.server -d site 8000
# open http://localhost:8000
```

`_headers` is only applied by Cloudflare Pages, not by the local server. Because the CSP is strict (`script-src 'self'`, `style-src 'self'`, `font-src 'self'`), don't add inline `<script>` or `<style>` blocks or `style=""` attributes; put them in `site.js` / `styles.css`.

## Before going live

- **GitHub links** 404 for visitors while the repo is private. They all come from `REPO_URL` in `site.js` (each link has `data-repo="<path>"` and a matching `href` for no-JS readers; `tests/test_site.py` keeps them equal). Deploy with the public repo.

## Checks before publishing

- Width 375 px (DevTools device mode): no horizontal scroll.
- macOS **System Settings → Accessibility → Display → Reduce motion** on: the demo shows one alert, still, with no Pause button, and pressing it (and Send a test alert) still works.
- Light and dark appearance both read well.
- Tab through the page: every link and button shows a focus ring; the "Skip to content" link appears first.

## Deploy

`.github/workflows/site.yml` deploys on every push to `main` that touches `docs/`, `site/`, `README.md` or the generator (or by hand: Actions → site → Run workflow). It never runs on pull requests, so code from a fork or a PR can't reach the self-hosted runner while it holds the deploy key. On the self-hosted Linux runner (`vars.CI_LINUX_RUNNER`), in the GitHub Environment `site`, it rebuilds the guides and runs the site tests with no secrets in reach, then, in a separate step that runs only `rsync` and `ssh`:

```bash
rsync -a --exclude README.md --exclude _headers site/ "$SITE_DEPLOY_TARGET"
```

with a key used only for this deploy, written to a mode-600 temp file and deleted afterwards, and the server's host key pinned (`StrictHostKeyChecking=yes`, no `ssh-keyscan`). rsync doesn't delete: a page removed from the site stays on the server until removed there.

**Setting it up (owner, once).** No host name lives in the repo; it all comes from repo settings:

1. Make a key for this deploy only, on any machine: `ssh-keygen -t ed25519 -N '' -C needsyou-site-deploy -f site-deploy`.
2. On the web server, restrict it to writing into the site directory, one line in the deploy user's `~/.ssh/authorized_keys` (`rrsync` ships with rsync; on Debian/Ubuntu it may be `/usr/share/doc/rsync/scripts/rrsync`, copy it onto `PATH`):

   ```
   command="rrsync -wo ~/sites/needsyou.app",restrict ssh-ed25519 AAAA... needsyou-site-deploy
   ```

3. Set the repo's settings (with `rrsync` the destination path is relative to that directory, so the target ends in `:`):

   ```bash
   gh secret set SITE_DEPLOY_KEY < site-deploy                       # then delete site-deploy
   gh variable set SITE_DEPLOY_KNOWN_HOSTS --body "$(ssh-keyscan -t ed25519 <host>)"   # check the fingerprint
   gh variable set SITE_DEPLOY_TARGET --body '<user>@<host>:'
   ```

   Optionally add protection rules (required reviewers, `main` only) to the `site` environment under Settings → Environments.

Without `SITE_DEPLOY_TARGET` the deploy job is skipped; with it but without the key or known hosts it fails with a message.

## Cloudflare Pages

An alternative host, not used today. The plan is in [docs/roadmap/site-deploy.md](../docs/roadmap/site-deploy.md). Settings if it is:

| Setting | Value |
|---|---|
| Framework preset | None |
| Build command | *(none: `site/guides/` is committed)* |
| Build output directory | `site` |
| Root directory | *(repo root)* |
| Production branch | `main` |

The site's domain is **https://needsyou.app** (`canonical` and `og:url` in `index.html`; `tests/test_site.py` checks them). Still to do: an `og:image` (a 1200×630 PNG; most crawlers ignore SVG).
