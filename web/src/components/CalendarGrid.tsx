import { useMemo, useState } from 'react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

export interface CalendarEntry {
  date: string;
  sessions: number;
  messages: number;
  top_project: string | null;
}

interface Props {
  entries: CalendarEntry[];
  /** When false, days with diaries look the same but are not links (public calendar). */
  linkToDiaries?: boolean;
}

const WEEKDAY_LABELS = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
const MONTH_NAMES = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

export function CalendarGrid({ entries, linkToDiaries = true }: Props) {
  const map = useMemo(() => new Map(entries.map((e) => [e.date, e])), [entries]);
  const years = useMemo(() => yearsFromEntries(entries), [entries]);
  const [year, setYear] = useState<number>(years[0] ?? new Date().getUTCFullYear());

  return (
    <section>
      <div className="mb-3 flex items-center gap-1">
        {years.map((y) => (
          <Button
            key={y}
            type="button"
            variant={y === year ? 'secondary' : 'ghost'}
            size="sm"
            onClick={() => setYear(y)}
          >
            {y}
          </Button>
        ))}
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 12 }, (_, m) => (
          <MonthBlock key={m} year={year} month={m} entryMap={map} linkToDiaries={linkToDiaries} />
        ))}
      </div>
    </section>
  );
}

function MonthBlock({
  year,
  month,
  entryMap,
  linkToDiaries,
}: {
  year: number;
  month: number;
  entryMap: Map<string, CalendarEntry>;
  linkToDiaries: boolean;
}) {
  const cells = monthCells(year, month);
  const todayIso = new Date().toISOString().slice(0, 10);

  return (
    <div className="rounded-lg border bg-card px-3 py-3">
      <div className="mb-1.5 text-sm font-semibold">{MONTH_NAMES[month]} {year}</div>
      <div className="grid grid-cols-7 gap-1 text-center text-[10px] text-muted-foreground">
        {WEEKDAY_LABELS.map((label, i) => (
          <div key={i}>{label}</div>
        ))}
      </div>
      <div className="mt-1 grid grid-cols-7 gap-1">
        {cells.map((cell, i) => {
          if (cell === null) return <div key={i} className="aspect-square" />;
          const iso = cell.iso;
          const entry = entryMap.get(iso);
          const isFuture = iso > todayIso;
          const has = entry !== undefined;
          const level = has ? levelFor(entry!.sessions) : 0;
          const cls = cn(
            'aspect-square flex items-center justify-center rounded-[5px] text-[11px] tabular-nums transition-colors',
            isFuture && 'text-muted-foreground/40',
            !isFuture && !has && 'text-muted-foreground/70 bg-muted/30',
            has && HEAT_BG[level],
            has && HEAT_TEXT[level],
            has && linkToDiaries && 'cursor-pointer hover:brightness-95',
            has && !linkToDiaries && 'cursor-default',
            iso === todayIso && 'ring-2 ring-ring/40 ring-offset-1 ring-offset-card',
          );
          if (has) {
            const title = linkToDiaries ? tooltipFor(entry!) : undefined;
            if (linkToDiaries) {
              return (
                <a key={i} href={`/${iso}`} title={title} className={cls}>
                  {cell.day}
                </a>
              );
            }
            return (
              <div key={i} className={cls}>
                {cell.day}
              </div>
            );
          }
          return (
            <div key={i} className={cls}>
              {cell.day}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// Same buckets the HeatmapGrid above uses, so a day reads the same in both.
function levelFor(sessions: number): 0 | 1 | 2 | 3 | 4 {
  if (sessions <= 0) return 0;
  if (sessions <= 2) return 1;
  if (sessions <= 5) return 2;
  if (sessions <= 10) return 3;
  return 4;
}

// Text color flips at level 3 — the OKLCH lightness of heat-3 (0.68) and
// heat-4 (0.55) is dark enough that light text reads better than the
// default foreground.
const HEAT_BG = [
  'bg-heat-0',
  'bg-heat-1',
  'bg-heat-2',
  'bg-heat-3',
  'bg-heat-4',
] as const;

const HEAT_TEXT = [
  'text-foreground/80',
  'text-foreground',
  'text-foreground',
  'text-background',
  'text-background',
] as const;

function tooltipFor(entry: CalendarEntry): string {
  const parts = [`${entry.date}`, `${entry.sessions} sessions`, `${entry.messages} msgs`];
  if (entry.top_project) parts.push(entry.top_project);
  return parts.join(' · ');
}

function monthCells(year: number, month: number): ({ day: number; iso: string } | null)[] {
  const first = new Date(Date.UTC(year, month, 1));
  const offset = first.getUTCDay();
  const daysInMonth = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const cells: ({ day: number; iso: string } | null)[] = [];
  for (let i = 0; i < offset; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) {
    const iso = `${year}-${String(month + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    cells.push({ day: d, iso });
  }
  while (cells.length % 7 !== 0) cells.push(null);
  return cells;
}

function yearsFromEntries(entries: CalendarEntry[]): number[] {
  const set = new Set<number>();
  for (const e of entries) set.add(parseInt(e.date.slice(0, 4), 10));
  set.add(new Date().getUTCFullYear());
  return [...set].sort((a, b) => b - a);
}
