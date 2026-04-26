import { compareSecret } from '@/lib/auth';

export const SESSION_COOKIE = 'ccdiary_sess';

/** 30 days */
const SESSION_TTL_SEC = 60 * 60 * 24 * 30;

export function readSessionCookie(request: Request): string | null {
  const raw = request.headers.get('cookie');
  if (!raw) return null;
  for (const part of raw.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const k = part.slice(0, idx).trim();
    if (k === SESSION_COOKIE) return decodeURIComponent(part.slice(idx + 1).trim());
  }
  return null;
}

export async function createSessionValue(sessionSecret: string, nowSec = Math.floor(Date.now() / 1000)): Promise<string> {
  const exp = nowSec + SESSION_TTL_SEC;
  const sig = await hmacHex(sessionSecret, String(exp));
  return `${exp}.${sig}`;
}

export async function sessionValueValid(sessionSecret: string, value: string | null): Promise<boolean> {
  if (!value || !sessionSecret) return false;
  const dot = value.lastIndexOf('.');
  if (dot <= 0) return false;
  const expStr = value.slice(0, dot);
  const sig = value.slice(dot + 1);
  const exp = Number.parseInt(expStr, 10);
  if (!Number.isFinite(exp) || exp * 1000 <= Date.now()) return false;
  const expected = await hmacHex(sessionSecret, expStr);
  return compareSecret(sig, expected);
}

export function sessionCookieHeader(
  request: Request,
  value: string,
  maxAgeSec: number,
): string {
  const https = new URL(request.url).protocol === 'https:';
  const secure = https ? ' Secure;' : '';
  return `${SESSION_COOKIE}=${encodeURIComponent(value)}; HttpOnly;${secure} Path=/; SameSite=Lax; Max-Age=${maxAgeSec}`;
}

export function clearSessionCookieHeader(request: Request): string {
  const https = new URL(request.url).protocol === 'https:';
  const secure = https ? ' Secure;' : '';
  return `${SESSION_COOKIE}=; HttpOnly;${secure} Path=/; SameSite=Lax; Max-Age=0`;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  const bytes = new Uint8Array(mac);
  let hex = '';
  for (let i = 0; i < bytes.length; i++) hex += bytes[i]!.toString(16).padStart(2, '0');
  return hex;
}

export { SESSION_TTL_SEC };
