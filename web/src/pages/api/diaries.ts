import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { listDiaries, upsertDiary, type UpsertDiaryInput } from '@/lib/db';
import { isIsoDate } from '@/lib/date';

export const prerender = false;

export const GET: APIRoute = async ({ url }) => {
  const from = url.searchParams.get('from') ?? undefined;
  const to = url.searchParams.get('to') ?? undefined;
  if (from && !isIsoDate(from)) return badRequest('from must be YYYY-MM-DD');
  if (to && !isIsoDate(to)) return badRequest('to must be YYYY-MM-DD');

  try {
    const rows = await listDiaries(env.DB, { from, to });
    return json(rows);
  } catch (err) {
    console.error('GET /api/diaries failed:', err);
    return internalError();
  }
};

export const POST: APIRoute = async ({ request }) => {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return badRequest('invalid JSON body');
  }

  const input = parseUpsert(body);
  if ('error' in input) return badRequest(input.error);

  try {
    const { inserted } = await upsertDiary(env.DB, input);
    return json(
      { date: input.date, inserted, updated: !inserted },
      inserted ? 201 : 200,
    );
  } catch (err) {
    console.error(`POST /api/diaries (date=${input.date}) failed:`, err);
    return internalError();
  }
};

function parseUpsert(body: unknown): UpsertDiaryInput | { error: string } {
  if (typeof body !== 'object' || body === null) return { error: 'body must be an object' };
  const b = body as Record<string, unknown>;

  if (typeof b.date !== 'string' || !isIsoDate(b.date)) {
    return { error: 'date must be a real YYYY-MM-DD calendar date' };
  }
  if (typeof b.markdown !== 'string' || b.markdown.length === 0) {
    return { error: 'markdown is required' };
  }
  if (typeof b.generated_at !== 'number' || !Number.isFinite(b.generated_at)) {
    return { error: 'generated_at must be a unix-ms number' };
  }

  const out: UpsertDiaryInput = {
    date: b.date,
    markdown: b.markdown,
    generated_at: b.generated_at,
  };
  if (typeof b.provider === 'string') out.provider = b.provider;
  if (typeof b.model === 'string') out.model = b.model;
  if (typeof b.source === 'string') out.source = b.source;

  if (b.stats && typeof b.stats === 'object') {
    const s = b.stats as Record<string, unknown>;
    const sources = parseSources(s.sources);
    if (sources && 'error' in sources) return { error: `stats.${sources.error}` };
    const projects = parseProjects(s.projects);
    if (projects && 'error' in projects) return { error: `stats.${projects.error}` };
    out.stats = {
      sessions: numberOr(s.sessions, 0),
      messages: numberOr(s.messages, 0),
      project_count: numberOr(s.project_count, 0),
      active_minutes: numberOr(s.active_minutes, 0),
      peak_hour: parsePeakHour(s.peak_hour),
      top_project: typeof s.top_project === 'string' ? s.top_project : null,
      sources: sources ?? undefined,
      projects: projects ?? undefined,
    };
  }

  return out;
}

function parsePeakHour(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  const intVal = Math.trunc(value);
  return intVal >= 0 && intVal <= 23 ? intVal : null;
}

const VALID_SOURCE_KEYS = new Set(['claudeCode', 'cursor', 'codex']);

function parseSources(value: unknown):
  | { claudeCode?: { sessions: number; messages: number };
      cursor?: { sessions: number; messages: number };
      codex?: { sessions: number; messages: number } }
  | { error: string }
  | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'object' || value === null) return { error: 'sources must be an object' };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const out: any = {};
  for (const [k, v] of Object.entries(value)) {
    if (!VALID_SOURCE_KEYS.has(k)) {
      return { error: `sources has unknown key "${k}"` };
    }
    if (!v || typeof v !== 'object') {
      return { error: `sources.${k} must be an object` };
    }
    const vv = v as Record<string, unknown>;
    out[k] = {
      sessions: numberOr(vv.sessions, 0),
      messages: numberOr(vv.messages, 0),
    };
  }
  return out;
}

function parseProjects(value: unknown):
  | Array<{ name: string; path: string; messageCount: number;
            timeRangeStart: string; timeRangeEnd: string; source: string }>
  | { error: string }
  | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) return { error: 'projects must be an array' };
  const out = [];
  for (let i = 0; i < value.length; i++) {
    const p = value[i];
    if (!p || typeof p !== 'object') return { error: `projects[${i}] must be an object` };
    const pp = p as Record<string, unknown>;
    if (typeof pp.name !== 'string' || typeof pp.path !== 'string' ||
        typeof pp.timeRangeStart !== 'string' || typeof pp.timeRangeEnd !== 'string' ||
        typeof pp.source !== 'string') {
      return { error: `projects[${i}] missing required string fields` };
    }
    out.push({
      name: pp.name,
      path: pp.path,
      messageCount: numberOr(pp.messageCount, 0),
      timeRangeStart: pp.timeRangeStart,
      timeRangeEnd: pp.timeRangeEnd,
      source: pp.source,
    });
  }
  return out;
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

function badRequest(message: string): Response {
  return json({ error: message }, 400);
}

function internalError(): Response {
  return json({ error: 'internal error' }, 500);
}
