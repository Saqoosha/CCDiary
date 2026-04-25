import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { buildStats, loadStatsRows, type StatsRange } from '@/lib/stats';

export const prerender = false;

export const GET: APIRoute = async ({ url }) => {
  const raw = url.searchParams.get('range');
  const range = parseRange(raw);
  if (range === null) {
    return new Response(
      JSON.stringify({ error: `range must be one of: all, 30d, 7d (got ${JSON.stringify(raw)})` }),
      { status: 400, headers: { 'content-type': 'application/json; charset=utf-8' } },
    );
  }

  try {
    const rows = await loadStatsRows(env.DB, range);
    const stats = buildStats(rows, range);
    return new Response(JSON.stringify(stats), {
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'private, max-age=60',
      },
    });
  } catch (err) {
    console.error('GET /api/stats failed:', err);
    return new Response(JSON.stringify({ error: 'internal error' }), {
      status: 500,
      headers: { 'content-type': 'application/json; charset=utf-8' },
    });
  }
};

function parseRange(raw: string | null): StatsRange | null {
  if (raw === null) return 'all';
  if (raw === 'all' || raw === '7d' || raw === '30d') return raw;
  return null;
}
