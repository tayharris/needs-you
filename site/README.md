# site/

The needs-you landing page: one screen. Plain HTML, CSS and a few lines of vanilla JS: no build step, no framework, no npm.

| File | What |
|---|---|
| `index.html` | The whole page: what it is, a CSS mock of the pill and a card, how it works, screenshots, Install, Open source, Support |
| `styles.css` | All styles. Built on the owner's shared design tokens: primitives (the only hexes, `tests/test_site.py` enforces it) then semantic variables on `:root`. Dark-first, light via `prefers-color-scheme: light`. IBM Plex Sans/Mono bundled in `fonts/` (Latin1 woff2 subsets, `fonts/OFL.txt`); the mock's amber matches the Mac app (`mac/Sources/NeedsYou/Views/Theme.swift`) |
| `site.js` | `REPO_URL`, the one GitHub constant, and copy buttons on code blocks (the page works without JS) |
| `_headers` | Cloudflare Pages response headers (CSP and other security headers) |
| `img/` | Screenshots of the app (2x PNGs, each under 200 KB), made from example items by `mac/scripts/screenshots.sh`, then optimised by hand (the flat backdrop around the panel made transparent, a 256-colour palette; any PNG optimiser will do). The guides in `docs/guides/` use these same files. Retake them when the panel or Settings changes visibly; check each one by eye for names, hosts or tokens before committing |

The favicon is an inline SVG data URI in `index.html`, so there's no separate icon file.

## Preview

```bash
python3 -m http.server -d site 8000
# open http://localhost:8000
```

`_headers` is only applied by Cloudflare Pages, not by the local server. Because the CSP is strict (`script-src 'self'`, `style-src 'self'`, `font-src 'self'`), don't add inline `<script>` or `<style>` blocks or `style=""` attributes; put them in `site.js` / `styles.css`.

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

Once the domain is chosen, uncomment the `SITE_DOMAIN` placeholder block in `index.html` (`canonical` and `og:url`) with the real origin and add an `og:image` (a 1200×630 PNG; most crawlers ignore SVG). `tests/test_site.py` fails if either is live before then.
