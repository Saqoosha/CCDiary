import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { buildStats, loadStatsRows, redactPublicStats } from '@/lib/stats';
import { renderStatsSvg } from '@/lib/stats-svg';

export const prerender = false;

/**
 * Public SVG badge for embedding in external pages (e.g. GitHub profile).
 *
 * Always served via `redactPublicStats` — never includes `top_project`,
 * since project names may be confidential. Cached for 5 minutes so the
 * GitHub camo proxy and Cloudflare edge absorb most traffic.
 */
export const GET: APIRoute = async () => {
  try {
    const rows = await loadStatsRows(env.DB, 'all');
    const stats = redactPublicStats(buildStats(rows, 'all'));
    const svg = renderStatsSvg(stats);

    return new Response(svg, {
      headers: {
        'content-type': 'image/svg+xml; charset=utf-8',
        'cache-control': 'public, max-age=300, s-maxage=300',
      },
    });
  } catch (err) {
    console.error('GET /stats.svg failed:', err);
    return new Response('', { status: 500 });
  }
};
