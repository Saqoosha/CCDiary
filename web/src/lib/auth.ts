/**
 * Bearer-token check used by the ingest endpoint (`CCDIARY_INGEST_TOKEN`).
 * Browser sessions use `/login` and a signed cookie instead.
 */
export async function checkBearer(request: Request, secret: string | undefined): Promise<boolean> {
  if (!secret) return false;
  const header = request.headers.get('authorization') ?? '';
  if (!header.toLowerCase().startsWith('bearer ')) return false;
  const provided = header.slice(7).trim();
  return await timingSafeEqual(provided, secret);
}

/**
 * Constant-time comparison for the site password and other shared secrets.
 */
export async function compareSecret(a: string, b: string): Promise<boolean> {
  return timingSafeEqual(a, b);
}

/**
 * Constant-time string comparison via Web Crypto. We HMAC both sides with a
 * single-use random key so the byte length difference never short-circuits the
 * comparison — the early `length` check only matters once both inputs are the
 * same shape, after the equal-length tags are derived.
 */
async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const aBytes = enc.encode(a);
  const bBytes = enc.encode(b);
  const key = await crypto.subtle.generateKey(
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const [aTag, bTag] = await Promise.all([
    crypto.subtle.sign('HMAC', key, aBytes),
    crypto.subtle.sign('HMAC', key, bBytes),
  ]);
  const av = new Uint8Array(aTag);
  const bv = new Uint8Array(bTag);
  let diff = aBytes.byteLength ^ bBytes.byteLength;
  for (let i = 0; i < av.length; i++) diff |= av[i]! ^ bv[i]!;
  return diff === 0;
}

export function unauthorized(message = 'unauthorized'): Response {
  return new Response(JSON.stringify({ error: message }), {
    status: 401,
    headers: { 'content-type': 'application/json' },
  });
}
