/**
 * D1 row types and helpers. Keep these aligned with `schema.sql`.
 */

export interface DiaryRow {
  date: string;
  markdown: string;
  generated_at: number;
  updated_at: number;
  provider: string | null;
  model: string | null;
  source: string;
  sessions: number;
  messages: number;
  project_count: number;
  active_minutes: number;
  peak_hour: number | null;
  top_project: string | null;
  sources_json: string | null;
  projects_json: string | null;
}

export type DiaryListRow = Pick<
  DiaryRow,
  'date' | 'generated_at' | 'sessions' | 'messages' | 'top_project'
>;

export interface SourcesBreakdown {
  claudeCode?: { sessions: number; messages: number };
  cursor?: { sessions: number; messages: number };
  codex?: { sessions: number; messages: number };
}

export interface ProjectSummary {
  name: string;
  path: string;
  messageCount: number;
  timeRangeStart: string;
  timeRangeEnd: string;
  source: string;
}

export interface DiaryStats {
  sessions: number;
  messages: number;
  project_count: number;
  active_minutes: number;
  peak_hour: number | null;
  top_project: string | null;
  sources?: SourcesBreakdown;
  projects?: ProjectSummary[];
}

export function rowToStats(row: DiaryRow): DiaryStats {
  return {
    sessions: row.sessions,
    messages: row.messages,
    project_count: row.project_count,
    active_minutes: row.active_minutes,
    peak_hour: row.peak_hour,
    top_project: row.top_project,
    sources: safeJsonParse<SourcesBreakdown>(row.sources_json, `${row.date}.sources_json`),
    projects: safeJsonParse<ProjectSummary[]>(row.projects_json, `${row.date}.projects_json`),
  };
}

function safeJsonParse<T>(raw: string | null, label: string): T | undefined {
  if (raw === null) return undefined;
  try {
    return JSON.parse(raw) as T;
  } catch (err) {
    console.warn(`Skipping malformed ${label}:`, err);
    return undefined;
  }
}

export async function getDiary(db: D1Database, date: string): Promise<DiaryRow | null> {
  const stmt = db.prepare('SELECT * FROM diaries WHERE date = ?').bind(date);
  return await stmt.first<DiaryRow>();
}

export async function listDiaries(
  db: D1Database,
  opts: { from?: string; to?: string } = {},
): Promise<DiaryListRow[]> {
  const where: string[] = [];
  const binds: unknown[] = [];
  if (opts.from) {
    where.push('date >= ?');
    binds.push(opts.from);
  }
  if (opts.to) {
    where.push('date <= ?');
    binds.push(opts.to);
  }
  const sql =
    'SELECT date, generated_at, sessions, messages, top_project FROM diaries' +
    (where.length ? ` WHERE ${where.join(' AND ')}` : '') +
    ' ORDER BY date DESC';
  const stmt = db.prepare(sql).bind(...binds);
  const result = await stmt.all<DiaryListRow>();
  return result.results ?? [];
}

export interface UpsertDiaryInput {
  date: string;
  markdown: string;
  generated_at: number;
  provider?: string;
  model?: string;
  source?: string;
  stats?: Partial<DiaryStats>;
}

/**
 * Idempotent upsert. Stats fields are optional — if `stats` is omitted, existing
 * column values stay put. The flat scalar columns (sessions, messages, …) are
 * gated by a single `hasStats` sentinel; sources_json and projects_json each
 * have their own gate so callers can supply totals without clobbering an
 * existing breakdown they didn't recompute.
 *
 * NOTE: the `inserted` flag is best-effort. We probe with a SELECT before
 * the upsert; under concurrent POSTs for the same date, two callers can
 * race and both report `inserted: true`. The diary content itself is
 * always correct since the upsert is a single statement — only the
 * 201-vs-200 status code is approximate.
 */
export async function upsertDiary(
  db: D1Database,
  input: UpsertDiaryInput,
): Promise<{ inserted: boolean }> {
  const now = Date.now();
  const stats = input.stats ?? null;
  const hasSources = stats?.sources !== undefined;
  const hasProjects = stats?.projects !== undefined;
  const sourcesJson = hasSources ? JSON.stringify(stats!.sources) : null;
  const projectsJson = hasProjects ? JSON.stringify(stats!.projects) : null;
  const hasStats = stats !== null;

  const before = await db.prepare('SELECT 1 FROM diaries WHERE date = ?').bind(input.date).first();
  const existed = before !== null;

  const sql = `
    INSERT INTO diaries (
      date, markdown, generated_at, updated_at, provider, model, source,
      sessions, messages, project_count, active_minutes, peak_hour, top_project,
      sources_json, projects_json
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
    ON CONFLICT(date) DO UPDATE SET
      markdown       = excluded.markdown,
      generated_at   = excluded.generated_at,
      updated_at     = excluded.updated_at,
      provider       = COALESCE(excluded.provider, diaries.provider),
      model          = COALESCE(excluded.model, diaries.model),
      source         = COALESCE(excluded.source, diaries.source),
      sessions       = CASE WHEN ?16 = 1 THEN excluded.sessions       ELSE diaries.sessions       END,
      messages       = CASE WHEN ?16 = 1 THEN excluded.messages       ELSE diaries.messages       END,
      project_count  = CASE WHEN ?16 = 1 THEN excluded.project_count  ELSE diaries.project_count  END,
      active_minutes = CASE WHEN ?16 = 1 THEN excluded.active_minutes ELSE diaries.active_minutes END,
      peak_hour      = CASE WHEN ?16 = 1 THEN excluded.peak_hour      ELSE diaries.peak_hour      END,
      top_project    = CASE WHEN ?16 = 1 THEN excluded.top_project    ELSE diaries.top_project    END,
      sources_json   = CASE WHEN ?17 = 1 THEN excluded.sources_json   ELSE diaries.sources_json   END,
      projects_json  = CASE WHEN ?18 = 1 THEN excluded.projects_json  ELSE diaries.projects_json  END
  `;

  await db
    .prepare(sql)
    .bind(
      input.date,
      input.markdown,
      input.generated_at,
      now,
      input.provider ?? null,
      input.model ?? null,
      input.source ?? 'cli',
      stats?.sessions ?? 0,
      stats?.messages ?? 0,
      stats?.project_count ?? 0,
      stats?.active_minutes ?? 0,
      stats?.peak_hour ?? null,
      stats?.top_project ?? null,
      sourcesJson,
      projectsJson,
      hasStats ? 1 : 0,
      hasSources ? 1 : 0,
      hasProjects ? 1 : 0,
    )
    .run();

  return { inserted: !existed };
}
