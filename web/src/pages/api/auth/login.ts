import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { compareSecret } from '@/lib/auth';
import { createSessionValue, sessionCookieHeader, SESSION_TTL_SEC } from '@/lib/session';

export const prerender = false;

export const POST: APIRoute = async ({ request }) => {
  const expected = env.CCDIARY_SITE_PASSWORD;
  const sessionSecret = env.CCDIARY_SESSION_SECRET;
  if (!expected?.trim() || !sessionSecret) {
    return new Response(JSON.stringify({ error: 'login not configured' }), {
      status: 503,
      headers: { 'content-type': 'application/json; charset=utf-8' },
    });
  }

  const password = await readPassword(request);
  if (password === undefined) {
    return new Response(JSON.stringify({ error: 'password required' }), {
      status: 400,
      headers: { 'content-type': 'application/json; charset=utf-8' },
    });
  }

  if (!(await compareSecret(password, expected))) {
    const wantsJson = (request.headers.get('accept') ?? '').includes('application/json');
    if (wantsJson) {
      return new Response(JSON.stringify({ error: 'invalid password' }), {
        status: 401,
        headers: { 'content-type': 'application/json; charset=utf-8' },
      });
    }
    return Response.redirect(new URL('/login?bad=1', request.url).toString(), 303);
  }

  const token = await createSessionValue(sessionSecret);
  const setCookie = sessionCookieHeader(request, token, SESSION_TTL_SEC);
  const wantsJson = (request.headers.get('accept') ?? '').includes('application/json');
  if (wantsJson) {
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'set-cookie': setCookie,
      },
    });
  }
  return new Response(null, {
    status: 303,
    headers: {
      location: new URL('/', request.url).toString(),
      'set-cookie': setCookie,
    },
  });
};

async function readPassword(request: Request): Promise<string | undefined> {
  const ct = request.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) {
    try {
      const b = (await request.json()) as { password?: unknown };
      return typeof b.password === 'string' ? b.password : undefined;
    } catch {
      return undefined;
    }
  }
  try {
    const fd = await request.formData();
    const p = fd.get('password');
    return typeof p === 'string' ? p : undefined;
  } catch {
    return undefined;
  }
}
