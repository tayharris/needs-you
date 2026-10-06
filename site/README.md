# site/

The needs-you marketing and docs-landing page. Plain HTML, CSS and a few lines of vanilla JS: no build step, no framework, no npm.

| File | What |
|---|---|
| `index.html` | The whole page: hero with the animated pill mock, how it works, quickstart, integrations, FAQ, footer |
| `styles.css` | All styles. Colors match the Mac app (`mac/Sources/NeedsYou/Views/Theme.swift`) |
| `site.js` | Copy buttons on code blocks (optional; the page works without JS) |
| `_headers` | Cloudflare Pages response headers (CSP and other security headers) |

The favicon is an inline SVG data URI in `index.html`, so there's no separate icon file.

## Preview

```bash
python3 -m http.server -d site 8000
# open http://localhost:8000
```

`_headers` is only applied by Cloudflare Pages, not by the local server. Because the CSP is strict (`script-src 'self'`, `style-src 'self'`), don't add inline `<script>` or `<style>` blocks or `style=""` attributes; put them in `site.js` / `styles.css`.

## Checks before publishing

- Width 375 px (DevTools device mode): no horizontal scroll.
- macOS **System Settings → Accessibility → Display → Reduce motion** on: the pill is static, showing the count.
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
