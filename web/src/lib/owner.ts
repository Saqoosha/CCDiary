import { readSessionCookie, sessionValueValid } from '@/lib/session';

/**
 * When `CCDIARY_SITE_PASSWORD` is set, a valid `ccdiary_sess` cookie (signed
 * with `CCDIARY_SESSION_SECRET`) is required.
 *
 * When it is unset, production stays **closed** (fail-safe). Exceptions:
 * - `astro dev` (`import.meta.env.DEV`): open without password, same as before.
 * - `wrangler dev` / deployed Worker: set `CCDIARY_OPEN_WITHOUT_PASSWORD` to
 *   `1` / `true` / `yes` in `.dev.vars` (never in production secrets).
 */
export async function isDiaryOwner(
  request: Request,
  env: {
    CCDIARY_SITE_PASSWORD?: string;
    CCDIARY_SESSION_SECRET?: string;
    CCDIARY_OPEN_WITHOUT_PASSWORD?: string;
  },
): Promise<boolean> {
  const gate = env.CCDIARY_SITE_PASSWORD?.trim();
  if (!gate) {
    if (import.meta.env.DEV) return true;
    return openWithoutPasswordAllowed(env);
  }
  const secret = env.CCDIARY_SESSION_SECRET;
  if (!secret) return false;
  return sessionValueValid(secret, readSessionCookie(request));
}

function openWithoutPasswordAllowed(env: { CCDIARY_OPEN_WITHOUT_PASSWORD?: string }): boolean {
  const v = env.CCDIARY_OPEN_WITHOUT_PASSWORD?.trim();
  if (!v) return false;
  const lower = v.toLowerCase();
  return v === '1' || lower === 'true' || lower === 'yes';
}
