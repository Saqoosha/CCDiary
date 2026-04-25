# CCDiary Web — Cloudflare Deployment

This doc walks through bringing the [`web/`](../web/) Astro Worker online at
`https://ccdiary.saqoo.sh`. Run these steps once; afterwards the LaunchAgent
keeps the archive in sync automatically.

## Prereqs

- Cloudflare account with `saqoo.sh` zone connected
- `bun` (already on the dev box) and `wrangler` (installed via `bun install`)
- macOS Keychain access (the LaunchAgent runs unattended, so the token must
  live in Keychain — the prompt-on-first-use should be approved with
  **Always Allow**)

## 1. Provision D1

```bash
cd web
bun install
bunx wrangler login            # opens a browser
bunx wrangler d1 create ccdiary
```

Copy the printed `database_id` into [`web/wrangler.toml`](../web/wrangler.toml),
replacing `REPLACE_WITH_DATABASE_ID`. The placeholder is intentional: D1
identifiers are personal-account-scoped and aren't useful to commit to a
public repo. If you want to keep it out of git after editing, copy the file
to `wrangler.local.toml` and pass `-c wrangler.local.toml` to wrangler, or
add it to your local `.git/info/exclude`.

Then apply the schema:

```bash
bun run db:apply:remote
```

## 2. Set the ingest secret

Generate a random token, put it in both Cloudflare and macOS Keychain:

```bash
TOKEN=$(openssl rand -base64 32)
echo "$TOKEN" | bunx wrangler secret put CCDIARY_INGEST_TOKEN
security add-generic-password -U -s sh.saqoo.CCDiary.cloud-token    -a "$USER" -w "$TOKEN"
security add-generic-password -U -s sh.saqoo.CCDiary.cloud-endpoint -a "$USER" -w "https://ccdiary.saqoo.sh"
```

The `-U` flag updates the entry if it already exists. Approve **Always Allow**
the first time `ccdiary-cli` reads either entry, otherwise launchd will hang
waiting for keychain consent.

## 3. Deploy the Worker

```bash
bun run deploy        # = astro build && wrangler deploy
```

The first deploy will publish to `ccdiary.<account>.workers.dev`. Verify it
boots:

```bash
curl https://ccdiary.<account>.workers.dev/api/stats
# → {"range":"all","cards":{"diaries":{"value":0,...},...},"heatmap":[],"fun_fact":null}
```

## 4. Custom domain

Cloudflare dashboard → **Workers & Pages → ccdiary → Settings → Domains & Routes**
→ **Add → Custom domain** → `ccdiary.saqoo.sh`. Cloudflare provisions the cert.

## 5. Cloudflare Access (Zero Trust)

Dashboard → **Zero Trust → Access → Applications** → **Add application**:

- Type: **Self-hosted**
- Application domain: `ccdiary.saqoo.sh`
- Identity provider: Google (saqoo.sh tenant)
- **Policy 1 — humans**:
  - Action: **Allow**
  - Include: `Emails ends with @whatever.co` (or just `saqoosha@whatever.co`)
- **Policy 2 — ingest bypass**:
  - Action: **Bypass**
  - Path includes: `/api/diaries`
  - Method: `POST`
  - (Bearer auth is enforced inside the Worker via the secret from step 2)

Save. Visit `https://ccdiary.saqoo.sh/` in a browser — you should be bounced
through the Google login the first time.

## 6. Backfill historical diaries

After the secret is in Keychain you can push every existing local diary in
one shot:

```bash
xcodebuild -scheme ccdiary-cli -configuration Release -derivedDataPath build build
./build/Build/Products/Release/ccdiary-cli sync-cloud
```

Add `--from YYYY-MM-DD` / `--to YYYY-MM-DD` to limit the range. Diaries that
have a matching `~/Library/Caches/CCDiary/statistics/<date>.json` are uploaded
with full stats; older ones land without stats (that just means the heatmap
cell renders at activity level 0 — the markdown still shows on the day page).

## 7. Wire up the LaunchAgent

Already-installed agent works as-is — re-running the install script renders
the new template (now passing `--post-cloud`) into
`~/Library/LaunchAgents/sh.saqoo.CCDiary.daily.plist`:

```bash
scripts/install-daily-launch-agent.sh
launchctl kickstart -k gui/$(id -u)/sh.saqoo.CCDiary.daily
tail -f ~/Library/Logs/CCDiary/daily.err.log
```

The next 04:00 run will generate yesterday's diary, post to Slack, and push
to D1 in one shot.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Cloud ingest token not configured` | `security find-generic-password -s sh.saqoo.CCDiary.cloud-token` returns nothing — re-run step 2 |
| `Cloud ingest error (401)` | Token in Keychain doesn't match the Worker secret. Repush both with the same `$TOKEN` |
| `database_id` placeholder still in `wrangler.toml` | Re-run step 1 and update the file |
| Cloudflare Access blocks `POST /api/diaries` | Bypass policy missing or wrong path. Re-check step 5 policy 2 |
| Browser shows the page but stats panel is empty | D1 has no rows yet — run step 6 |
