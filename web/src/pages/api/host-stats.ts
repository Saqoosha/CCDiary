import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { getHostStats, upsertHostStats } from '@/lib/db';
import { isIsoDate } from '@/lib/date';

export const prerender = false;

export const POST: APIRoute = async ({ request }) => {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }), { status: 400 });
  }

  const { date, host, stats, digest } = body as {
    date?: string;
    host?: string;
    stats?: Record<string, unknown>;
    digest?: Record<string, unknown>;
    updatedAt?: number;
  };

  if (!date || !isIsoDate(date)) {
    return new Response(JSON.stringify({ error: 'Invalid or missing date' }), { status: 400 });
  }
  if (!host || typeof host !== 'string' || host.trim().length === 0) {
    return new Response(JSON.stringify({ error: 'Invalid or missing host' }), { status: 400 });
  }
  if (!stats || typeof stats !== 'object') {
    return new Response(JSON.stringify({ error: 'Invalid or missing stats' }), { status: 400 });
  }

  try {
    const result = await upsertHostStats(env.DB, {
      date: date.trim(),
      host: host.trim(),
      stats,
      digest: digest && typeof digest === 'object' ? digest : null,
    });
    return new Response(
      JSON.stringify({ date: date.trim(), host: host.trim(), inserted: result.inserted }),
      { status: result.inserted ? 201 : 200 },
    );
  } catch (err) {
    console.error('Failed to upsert host stats:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), { status: 500 });
  }
};

export const GET: APIRoute = async ({ request }) => {
  const url = new URL(request.url);
  const date = url.searchParams.get('date');

  if (!date || !isIsoDate(date)) {
    return new Response(JSON.stringify({ error: 'Invalid or missing date parameter' }), { status: 400 });
  }

  try {
    const rows = await getHostStats(env.DB, date);
    const hosts = rows.map((row) => ({
      date: row.date,
      host: row.host,
      stats: JSON.parse(row.stats_json),
      digest: row.digest_json ? JSON.parse(row.digest_json) : null,
      updatedAt: row.updated_at,
    }));

    return new Response(JSON.stringify({ date, hosts }), { status: 200 });
  } catch (err) {
    console.error('Failed to fetch host stats:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), { status: 500 });
  }
};
