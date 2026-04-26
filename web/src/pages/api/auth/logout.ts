import type { APIRoute } from 'astro';
import { clearSessionCookieHeader } from '@/lib/session';

export const prerender = false;

export const POST: APIRoute = async ({ request }) => {
  const clear = clearSessionCookieHeader(request);
  const wantsJson = (request.headers.get('accept') ?? '').includes('application/json');
  if (wantsJson) {
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'set-cookie': clear,
      },
    });
  }
  return new Response(null, {
    status: 303,
    headers: {
      location: new URL('/', request.url).toString(),
      'set-cookie': clear,
    },
  });
};
