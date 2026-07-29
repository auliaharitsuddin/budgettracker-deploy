# BudgetTracker — Deployment Pipeline

Container + CI/CD pipeline for **FinanceFlow / BudgetTracker**, a single-file
budget tracker (HTML + CSS + JS, no build step, all data in browser
`localStorage`).

The app is fully static, so the whole pipeline costs **$0**: GitHub Actions is
free for public repos, and the image is published to the GitHub Container
Registry (ghcr.io), also free on the public tier.

**Live:** https://auliaharitsuddin.github.io/budgettracker-deploy/

## Contents

| File | Purpose |
|---|---|
| `public/index.html` | the app itself (byte-identical copy of `BudgetTracker/BudgetTrackerWebApp.html`) |
| `Dockerfile` | non-root nginx (`nginx-unprivileged`, UID 101, port 8080) |
| `nginx.conf` | server block: SPA fallback, `/healthz`, security headers, gzip |
| `docker-compose.yml` | runs the container locally, read-only filesystem |
| `tests/smoke.sh` | 11 HTTP assertions, two modes: `--target=container` / `--target=pages` |
| `tests/e2e/` | 10 Playwright scenarios (transactions, persistence, budgets, theme, i18n) |
| `tests/pages_sim.py` | GitHub Pages simulator, for testing `pages` mode without a real deploy |
| `scripts/prepare-pages-artifact.sh` | injects the build marker + `404.html` SPA fallback for Pages |
| `.github/workflows/` | 8 workflows covering Stages 1–10 (see below) |

### Workflows

| File | Trigger | Stages |
|---|---|---|
| `ci.yml` | PR, push to non-main | 1–4 |
| `release.yml` | push to `main` | 1–9 |
| `rollback.yml` | manual | 9 |
| `monitor.yml` | cron, every 30 min | 10 |
| `deploy-container.yml` | manual | optional Render container path |
| `_test-suite.yml`, `_deploy-and-verify.yml`, `_rollback.yml` | reusable | shared by the workflows above |

Rollback reuses the **exact same** deploy-and-verify code path as a normal
release. A rollback with its own separate deploy logic only gets exercised
during an actual incident — precisely when it can least afford to fail.

## Pipeline

```
push to main
  → Stage 1  static analysis (hadolint, actionlint, yamllint, shellcheck, gitleaks)
  → Stage 2  build image, Trivy scan (gate: no fixable HIGH/CRITICAL), SBOM
  → Stage 3  runtime smoke test against the built container
  → Stage 4  Playwright functional tests against the built container
  → Stage 5  publish image + SBOM to ghcr.io
  → Stage 6  deploy to GitHub Pages
  → Stage 7  verify the live production URL (smoke + Playwright, again — this
              time against the real deployment, not the local container)
  → Stage 8  tag `last-good` at this commit (only if Stage 7 passed)
  → Stage 9  automatic rollback to `last-good` if Stage 7 failed, with an
              incident issue opened automatically
  → Stage 10 (monitor.yml, independent cron) health + drift check every 30 min
```

## Run locally

```bash
docker compose up --build          # then open http://localhost:8080
bash tests/smoke.sh                # smoke test against the container

# Browser tests against the running container
npm ci && npx playwright install chromium
PLAYWRIGHT_BASE_URL=http://localhost:8080 npx playwright test
```

Test the Pages path without deploying (no Docker needed):

```bash
bash scripts/prepare-pages-artifact.sh testsha dist
python tests/pages_sim.py dist 8097 &
bash tests/smoke.sh http://localhost:8097 --target=pages --marker=testsha
```

## Design decisions

**Base image is `nginxinc/nginx-unprivileged`, not `nginx`.** The official
nginx image runs its master process as root. The unprivileged variant runs as
UID 101 and listens on 8080, so the container needs no root at all —
`read_only: true` + `no-new-privileges` in compose work out of the box.

**No Content-Security-Policy.** The app loads Chart.js from jsdelivr and
Tesseract.js from unpkg; Tesseract also pulls a worker (`blob:`), a wasm core,
and language data at runtime. A CSP tight enough to be useful would break
receipt OCR. Vendor those two libraries into `public/` first, then add a CSP
in `nginx.conf`.

**`index.html` is served `no-cache`.** Otherwise users keep seeing the old
version after a deploy, because the browser caches the app's one and only
file.

**Push only from `main`.** The publish job is guarded on `github.ref` — PRs
from forks have no write access to the registry, and shouldn't.

**Security headers live in two places in `nginx.conf`, not one.** nginx's
`index` directive serves `/` via an internal redirect to the exact-match
`location = /index.html` block. That block has its own `add_header` for
`Cache-Control`, and once a location defines its own `add_header`, it stops
inheriting the server-level ones — so `X-Content-Type-Options`,
`X-Frame-Options`, and `Referrer-Policy` were silently dropped on every
request to `/` until this was caught by a real production run and fixed.

## What's actually been verified

Every stage has been run for real against live infrastructure — not just
linted or simulated locally. Four real bugs were found and fixed along the
way:

1. **Trivy CVE gate failure** — the originally pinned
   `nginx-unprivileged:1.27-alpine` carried 33 fixable HIGH and 2 CRITICAL
   CVEs (libexpat). Bumped to `1.31-alpine`.
2. **Security headers silently dropped on `/`** — see the nginx design note
   above.
3. **Stage 7's Playwright suite tested the wrong URL** — `page.goto("/")`
   resolves via `new URL("/", baseURL)`, and a leading slash discards
   baseURL's path. Against the Pages URL
   (`https://<user>.github.io/budgettracker-deploy/`) that resolved to the
   domain root — a different site — so every test timed out waiting for
   elements that could never exist. Fixed by using `page.goto("./")`.
4. **The rollback itself failed to redeploy**, found by deliberately breaking
   the Pages artifact and letting Stage 9 fire for real: both the release
   job's deploy and the rollback job's redeploy call the same reusable
   workflow within a single GitHub Actions run, and `upload-pages-artifact`'s
   default artifact name (`github-pages`) collided between the two. Fixed by
   naming the artifact per label (`github-pages-release` /
   `github-pages-rollback`).

After the fix, the rollback was re-tested end-to-end: Stage 7 correctly
caught an injected fault, Stage 9 redeployed `last-good` successfully, and an
incident issue was opened automatically. The full spec and the running log of
what was found and fixed live in
[docs/PIPELINE-SPEC.md](docs/PIPELINE-SPEC.md) and
[docs/IMPLEMENTATION-STATUS.md](docs/IMPLEMENTATION-STATUS.md).

## Deploying elsewhere

The image is a plain static nginx container, so it runs anywhere Docker
runs: Fly.io, Railway, Oracle Cloud's free tier, or a cheap VPS. Once CI has
run once, the image is available at:

```
ghcr.io/<user>/<repo>:latest
```

For pure static hosting (GitHub Pages, Cloudflare Pages, Netlify) the
container isn't needed at all — just serve `public/`. The container is useful
when the target is a VPS/orchestrator, or when you need a reverse proxy and
consistent headers.

## Known gaps

- A deliberate mobile CSS overflow bug is marked `test.fail()` rather than
  fixed, since the fix belongs in the upstream BudgetTracker app repo, not
  here.
- No preview/staging environment per PR (Cloudflare Pages supports this,
  GitHub Pages doesn't).
- The optional container path (Render) is wired up via `workflow_dispatch`
  but has not been exercised end-to-end.
- Monitoring is alert-only (Slack/issue) — no uptime dashboard or history.
