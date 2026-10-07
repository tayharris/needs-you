# site/

The needs-you landing page: one screen. Plain HTML, CSS and a few lines of vanilla JS: no build step, no framework, no npm.

| File | What |
|---|---|
| `index.html` | The whole page: what it is, a CSS mock of the pill and a card, how it works, Install, Open source, Support |
| `styles.css` | All styles. System fonts, dark and light via `prefers-color-scheme`; priority colors match the Mac app (`mac/Sources/NeedsYou/Views/Theme.swift`) |
| `site.js` | `REPO_URL`, the one GitHub constant, and copy buttons on code blocks (the page works without JS) |
| `_headers` | Cloudflare Pages response headers (CSP and other security headers) |

The favicon is an inline SVG data URI in `index.html`, so there's no separate icon file.

## Preview

```bash
python3 -m http.server -d site 8000
# open http://localhost:8000
```

`_headers` is only applied by Cloudflare Pages, not by the local server. Because the CSP is strict (`script-src 'self'`, `style-src 'self'`), don't add inline `<script>` or `<style>` blocks or `style=""` attributes; put them in `site.js` / `styles.css`.

## Before going live

- **GitHub links** 404 for visitors while the repo is private. They all come from `REPO_URL` in `site.js` (each link has `data-repo="<path>"` and a matching `href` for no-JS readers; `tests/test_site.py` keeps them equal). Deploy with the public repo.
- **Donate**: the link is the placeholder `#donate-tbd` until the service is chosen. `NEEDS_YOU_SITE_RELEASE=1 python3 -m unittest discover -s tests` fails while it's there; run that before deploying.

## Checks before publishing

- Width 375 px (DevTools device mode): no horizontal scroll.
- macOS **System Settings → Accessibility → Display → Reduce motion** on: the card doesn't animate in.
- Light and dark appearance both read well.
- Tab through the page: every link and button shows a focus ring; the "Skip to content" link appears first.

## Cloudflare Pages

Not deployed yet. The plan is in [docs/roadmap/site-deploy.md](../docs/roadmap/site-deploy.md). Settings when it is:

| Setting | Value |
|---|---|
| Framework preset | None |
| Build command | *(none, leave empty)* |
| Build output directory | `site` |
| Root directory | *(repo root)* |
| Production branch | `main` |

Add `og:url` and an `og:image` (a 1200×630 PNG; most crawlers ignore SVG) once the domain is chosen.
