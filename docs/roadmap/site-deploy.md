# Site deployment plan

Status (2026-10-08): the site is live at https://needsyou.app. It's deployed by hand with the same `rsync` the workflow runs, to a plain web server; `.github/workflows/site.yml` can do the same on every push to `main` once the owner sets its `SITE_DEPLOY_*` settings ([site/README.md](../../site/README.md#deploy)), and skips the deploy until then. The guides are rendered into `site/guides/` from `docs/` (option 2 below, `scripts/build_site_guides.py`). Cloudflare Pages, below, wasn't used; it stays here as an alternative.

## Cloudflare Pages

1. Cloudflare dashboard → Workers & Pages → Create → Pages → **Connect to Git** → `tayharris/needs-you`. 
2. Build settings:

   | Setting | Value |
   |---|---|
   | Framework preset | None |
   | Build command | *(empty)* |
   | Build output directory | `site` |
   | Root directory | *(empty, repo root)* |
   | Production branch | `main` |

3. **Preview deployments:** on for PRs (each gets a `*.pages.dev` URL). 
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

Done: option 2, with `docs/` as the single source.

The repo is public, so the site's GitHub links work for everyone.

## Open decisions

1. Turn on the `site.yml` deploy (set `SITE_DEPLOY_TARGET`, `SITE_DEPLOY_KNOWN_HOSTS`, `SITE_DEPLOY_KEY`), or keep deploying by hand?

Settled: the domain (`needsyou.app`), deploying once the repo was public, and rendering the docs into the site.
