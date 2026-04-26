# ccdiary-web

Cloudflare-hosted archive UI for [CCDiary](../README.md). Aggregates the
markdown diaries the macOS LaunchAgent generates each morning and presents
them through a calendar + GitHub-style activity heatmap.

- **Runtime**: Cloudflare Workers (Astro 6 SSR via `@astrojs/cloudflare`)
- **Storage**: D1 (`ccdiary` database) — markdown + per-day stats
- **UI**: Tailwind v4 + shadcn/ui (`new-york`, `neutral`, light-mode only)
- **Auth**: `/login` + signed cookie (`CCDIARY_SITE_PASSWORD` / `CCDIARY_SESSION_SECRET`); bearer token for `POST /api/diaries`. A Worker deploy **without** a site password stays locked; use `CCDIARY_OPEN_WITHOUT_PASSWORD=1` in `.dev.vars` for `wrangler dev` only, or rely on `astro dev` (unlocked when no password is set).

See [`docs/WEB_DEPLOYMENT.md`](../docs/WEB_DEPLOYMENT.md) for the full
deployment runbook.

## Local development

```bash
cd web
bun install
cp .dev.vars.example .dev.vars
bun run db:apply:local    # creates the local D1 file under .wrangler/state
bun run dev               # localhost:4321
```

API smoke test:

```bash
curl -X POST http://localhost:4321/api/diaries \
  -H "Authorization: Bearer dev-local-token" \
  -H "Content-Type: application/json" \
  -d '{"date":"2026-04-25","markdown":"# Test\n\n- hello","generated_at":'$(date +%s000)',"provider":"claude","model":"x","stats":{"sessions":3,"messages":42,"project_count":2,"active_minutes":120,"peak_hour":14,"top_project":"CCDiary"}}'

curl http://localhost:4321/api/stats
curl http://localhost:4321/api/diaries/2026-04-25
open http://localhost:4321/
```

## Deploying

```bash
bun run build
bunx wrangler deploy
```

Set the production secret once:

```bash
echo "$CCDIARY_INGEST_TOKEN" | bunx wrangler secret put CCDIARY_INGEST_TOKEN
```

The custom domain (`ccdiary.saqoo.sh`) is configured in the dashboard; set the
login secrets with `wrangler secret put` — see the deployment doc.
