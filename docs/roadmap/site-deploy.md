# Site deployment plan

Status: plan only. `site/` exists and previews locally (`python3 -m http.server -d site`); it is not deployed.

## Cloudflare Pages

1. Cloudflare dashboard → Workers & Pages → Create → Pages → **Connect to Git** → `tayharris/needs-you`. (The repo is private for now; Pages can read private repos through the GitHub app.)
2. Build settings:

   | Setting | Value |
   |---|---|
   | Framework preset | None |
   | Build command | *(empty)* |
   | Build output directory | `site` |
   | Root directory | *(empty, repo root)* |
   | Production branch | `main` |

3. **Preview deployments:** on for PRs (each gets a `*.pages.dev` URL). Restrict with Cloudflare Access while the repo is private, so previews aren't public.
4. **Build watch paths:** include `site/**` only, so code changes don't redeploy the site.
5. `site/_headers` is applied automatically (CSP, HSTS, `X-Frame-Options`, etc.). Check with `curl -sI https://<project>.pages.dev/`.
6. Analytics: Cloudflare Web Analytics is cookieless, but it adds a beacon script (CSP change). Default: none, which matches the "no telemetry" promise on the page.

Alternative to Git integration: `wrangler pages deploy site --project-name needs-you` from CI on `main` (a `CLOUDFLARE_API_TOKEN` secret with Pages:Edit). Prefer Git integration until CI exists.

## Domain

The domain is **`needsyou.app`** (HSTS-preloaded, so HTTPS-only; it matches `NeedsYou.app` and the app's bundle id `app.needsyou.mac`). `index.html` already names `https://needsyou.app/` as `canonical` and `og:url`.

On Cloudflare: add it under the Pages project → Custom domains; redirect `www` to the apex with a Bulk Redirect; then add an `og:image` (1200×630 PNG in `site/`) to `index.html`. Until the domain points at Pages, `needs-you.pages.dev` serves the same site.

## Docs hosting

The guides live in `docs/` as Markdown and render fine on GitHub. Options when the repo goes public:

1. **Link to GitHub** (today's site does this). Zero work; needs a public repo.
2. **Render `docs/` into `site/docs/` at deploy time** with a tiny stdlib Python script (Markdown subset → HTML using the site's CSS). Keeps "no build step" for the landing page but adds one for docs. Pages would run `python3 scripts/build-docs.py` as the build command.
3. **A docs generator** (MkDocs Material, Astro Starlight). Best search and navigation, but adds a toolchain, which the project avoids elsewhere.

Recommendation: 1 at launch, 2 if people ask for searchable docs. Keep `docs/` as the single source either way.

While the repo is private, GitHub links on the site 404 for visitors. Don't deploy the site publicly before the repo is public, or point the links at the site's own docs (option 2).

## Open decisions

1. Domain name.
2. Deploy before the repo is public (behind Access) or only at launch?
3. Docs: GitHub links or rendered into the site?
