import type { DiaryRow } from './db';

export type StatsRange = 'all' | '30d' | '7d';

export interface StatCard {
  value: string | number;
  unit?: string;
  label?: string;
}

export interface StatsResponse {
  range: StatsRange;
  cards: {
    diaries: StatCard;
    sessions: StatCard;
    messages: StatCard;
    active_hours: StatCard;
    current_streak: StatCard;
    longest_streak: StatCard;
    peak_hour: StatCard;
    top_project: StatCard;
    favorite_provider: StatCard;
  };
  heatmap: HeatmapDay[];
  fun_fact: string | null;
}

export interface HeatmapDay {
  date: string;
  sessions: number;
  messages: number;
  active_minutes: number;
  project_count: number;
}

/**
 * SELECT only the columns stats needs. Keeps the worker memory profile flat
 * even when the diary count grows large.
 */
export type StatsRow = Pick<
  DiaryRow,
  | 'date'
  | 'markdown'
  | 'sessions'
  | 'messages'
  | 'active_minutes'
  | 'project_count'
  | 'peak_hour'
  | 'top_project'
  | 'provider'
>;

export async function loadStatsRows(db: D1Database, range: StatsRange): Promise<StatsRow[]> {
  const sql =
    range === 'all'
      ? `SELECT date, markdown, sessions, messages, active_minutes, project_count,
                peak_hour, top_project, provider
         FROM diaries
         ORDER BY date ASC`
      : `SELECT date, markdown, sessions, messages, active_minutes, project_count,
                peak_hour, top_project, provider
         FROM diaries
         WHERE date >= ?
         ORDER BY date ASC`;
  const stmt = range === 'all' ? db.prepare(sql) : db.prepare(sql).bind(rangeStart(range));
  const result = await stmt.all<StatsRow>();
  return result.results ?? [];
}

export function buildStats(rows: StatsRow[], range: StatsRange): StatsResponse {
  const totals = {
    sessions: 0,
    messages: 0,
    active_minutes: 0,
    chars: 0,
  };
  const peakHourCounts = new Array<number>(24).fill(0);
  const projectCounts = new Map<string, number>();
  const providerCounts = new Map<string, number>();

  for (const row of rows) {
    totals.sessions += row.sessions;
    totals.messages += row.messages;
    totals.active_minutes += row.active_minutes;
    totals.chars += row.markdown.length;

    if (row.peak_hour !== null && row.peak_hour >= 0 && row.peak_hour < 24) {
      peakHourCounts[row.peak_hour]! += Math.max(row.messages, 1);
    }
    if (row.top_project) {
      projectCounts.set(row.top_project, (projectCounts.get(row.top_project) ?? 0) + Math.max(row.messages, 1));
    }
    if (row.provider) {
      providerCounts.set(row.provider, (providerCounts.get(row.provider) ?? 0) + 1);
    }
  }

  const dates = rows.map((r) => r.date).sort();
  const { current, longest } = computeStreaks(dates);

  const peakHour = argmax(peakHourCounts);
  const topProject = argmaxMap(projectCounts);
  const favoriteProvider = argmaxMap(providerCounts);

  return {
    range,
    cards: {
      diaries: { value: rows.length, label: 'Active days' },
      sessions: { value: totals.sessions },
      messages: { value: totals.messages },
      active_hours: { value: Math.round(totals.active_minutes / 60), unit: 'h' },
      current_streak: { value: current, unit: 'd' },
      longest_streak: { value: longest, unit: 'd' },
      peak_hour: { value: peakHour !== null ? formatHour(peakHour) : '—' },
      top_project: { value: topProject ?? '—' },
      favorite_provider: { value: favoriteProvider ?? '—' },
    },
    heatmap: rows.map((r) => ({
      date: r.date,
      sessions: r.sessions,
      messages: r.messages,
      active_minutes: r.active_minutes,
      project_count: r.project_count,
    })),
    fun_fact: buildFunFact(totals.chars),
  };
}

/** Hide aggregated top project for public / logged-out visitors. */
export function redactPublicStats(stats: StatsResponse): StatsResponse {
  return {
    ...stats,
    cards: {
      ...stats.cards,
      top_project: { value: '—' },
    },
  };
}

function rangeStart(range: '30d' | '7d'): string {
  const days = range === '30d' ? 30 : 7;
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - days + 1);
  return d.toISOString().slice(0, 10);
}

function argmax(arr: number[]): number | null {
  let best = -1;
  let bestVal = 0;
  for (let i = 0; i < arr.length; i++) {
    if (arr[i]! > bestVal) {
      best = i;
      bestVal = arr[i]!;
    }
  }
  return best === -1 ? null : best;
}

function argmaxMap(map: Map<string, number>): string | null {
  let best: string | null = null;
  let bestVal = 0;
  for (const [k, v] of map) {
    if (v > bestVal) {
      best = k;
      bestVal = v;
    }
  }
  return best;
}

function formatHour(h: number): string {
  if (h === 0) return '12 AM';
  if (h === 12) return '12 PM';
  return h < 12 ? `${h} AM` : `${h - 12} PM`;
}

/**
 * Returns the current consecutive streak (counted from yesterday or today,
 * whichever is the most recent diary) and the longest run ever observed.
 */
function computeStreaks(sortedDates: string[]): { current: number; longest: number } {
  if (sortedDates.length === 0) return { current: 0, longest: 0 };
  const set = new Set(sortedDates);
  let longest = 0;
  let run = 0;
  let prev: string | null = null;
  for (const d of sortedDates) {
    if (prev !== null && nextDay(prev) === d) {
      run += 1;
    } else {
      run = 1;
    }
    longest = Math.max(longest, run);
    prev = d;
  }

  // Current streak counts back from today (allowing one day of grace if
  // today's diary hasn't been generated yet — the cron runs at 04:00 for
  // *yesterday*, so "today" is empty until tomorrow morning).
  const today = isoToday();
  let cursor = set.has(today) ? today : prevDay(today);
  let current = 0;
  while (set.has(cursor)) {
    current += 1;
    cursor = prevDay(cursor);
  }
  return { current, longest };
}

function isoToday(): string {
  return new Date().toISOString().slice(0, 10);
}

function nextDay(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

function prevDay(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Compare total diary character count against well-known short stories.
 * Picks the work whose multiplier lands closest to the ~16× sweet spot
 * (`10^1.2`); skips works where the user's text isn't at least 1.2× longer.
 */
function buildFunFact(totalChars: number): string | null {
  if (totalChars === 0) return null;
  const works: { name: string; chars: number }[] = [
    { name: '走れメロス', chars: 9_800 },
    { name: '山月記', chars: 6_500 },
    { name: '注文の多い料理店', chars: 6_200 },
    { name: 'The Little Prince', chars: 22_000 },
    { name: 'こころ', chars: 175_000 },
  ];
  let best: { name: string; ratio: number } | null = null;
  for (const w of works) {
    const ratio = totalChars / w.chars;
    if (ratio < 1.2) continue;
    const score = Math.abs(Math.log10(ratio) - 1.2); // prefer ~16× sweet spot
    if (best === null || score < Math.abs(Math.log10(best.ratio) - 1.2)) {
      best = { name: w.name, ratio };
    }
  }
  if (best === null) {
    return `You've written ${totalChars.toLocaleString()} characters of diary so far.`;
  }
  const rounded = best.ratio >= 10 ? Math.round(best.ratio) : best.ratio.toFixed(1);
  return `You've written ~${rounded}× more diary characters than ${best.name}.`;
}
