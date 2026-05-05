import { defineMiddleware } from 'astro:middleware';
import { env } from 'cloudflare:workers';
import { checkBearer, unauthorized } from '@/lib/auth';

/** Bearer auth for ingest endpoints. Browser access to diaries uses `/login` + cookie. */
export const onRequest = defineMiddleware(async (ctx, next) => {
  const { request } = ctx;
  const url = new URL(request.url);
  const isApiAuth = url.pathname === '/api/diaries' || url.pathname === '/api/host-stats';

  if (isApiAuth && !(await checkBearer(request, env.CCDIARY_INGEST_TOKEN))) {
    return unauthorized();
  }

  return next();
});
