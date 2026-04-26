import { readSessionCookie, sessionValueValid } from '@/lib/session';

/**
 * When `CCDIARY_SITE_PASSWORD` is unset, everyone is treated as the owner (local
 * dev). When set, a valid `ccdiary_sess` cookie (signed with
 * `CCDIARY_SESSION_SECRET`) is required for diary deep links, detail pages, and
 * `GET /api/diaries`.
 */
export async function isDiaryOwner(
  request: Request,
  env: { CCDIARY_SITE_PASSWORD?: string; CCDIARY_SESSION_SECRET?: string },
): Promise<boolean> {
  const gate = env.CCDIARY_SITE_PASSWORD?.trim();
  if (!gate) return true;
  const secret = env.CCDIARY_SESSION_SECRET;
  if (!secret) return false;
  return sessionValueValid(secret, readSessionCookie(request));
}
