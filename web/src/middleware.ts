import { defineMiddleware } from 'astro:middleware';
import { env } from 'cloudflare:workers';
import { checkBearer, unauthorized } from '@/lib/auth';

/**
 * Bearer auth applies only to ingest writes. Everything else (calendar UI, GET
 * APIs) is gated upstream by Cloudflare Access, so the middleware no-ops.
 */
export const onRequest = defineMiddleware(async (ctx, next) => {
  const { request } = ctx;
  const url = new URL(request.url);
  const isIngest = url.pathname === '/api/diaries' && request.method === 'POST';

  if (isIngest && !(await checkBearer(request, env.CCDIARY_INGEST_TOKEN))) {
    return unauthorized();
  }

  return next();
});
