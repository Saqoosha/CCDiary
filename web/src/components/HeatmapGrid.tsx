import { useMemo } from 'react';
import { cn } from '@/lib/utils';

export interface HeatmapDay {
  date: string;
  sessions: number;
  messages: number;
}

interface HeatmapGridProps {
  days: HeatmapDay[];
  /** Limit how far back the chart goes; null/0 = show all data we have. */
  windowDays?: number | null;
  /** When false, cells have no `title` tooltip (public / logged-out view). */
  showCellTooltips?: boolean;
}

/**
 * GitHub-style activity heatmap. 7 rows (Sun→Sat) × N week-columns. Cells are
 * colored by `sessions` on a fixed 5-step scale. The right edge is "today";
 * empty days at the start of the window are rendered as level-0 cells so the
 * grid stays rectangular.
 */
export function HeatmapGrid({ days, windowDays = null, showCellTooltips = true }: HeatmapGridProps) {
  const grid = useMemo(() => buildGrid(days, windowDays), [days, windowDays]);

  return (
    <div className="overflow-x-auto">
      <div className="flex gap-[3px] py-2">
        {grid.weeks.map((week, wi) => (
          <div key={wi} className="flex flex-col gap-[3px]">
            {week.map((cell, ri) => (
              <Cell key={`${wi}-${ri}`} cell={cell} showTooltip={showCellTooltips} />
            ))}
          </div>
        ))}
      </div>
      <div className="mt-1 flex items-center justify-between text-[10px] text-muted-foreground">
        <span>{grid.firstDate}</span>
        <Legend />
      </div>
    </div>
  );
}

interface GridCell {
  date: string | null;
  sessions: number;
  messages: number;
  level: 0 | 1 | 2 | 3 | 4;
}

function Cell({ cell, showTooltip }: { cell: GridCell; showTooltip: boolean }) {
  if (cell.date === null) {
    return <div className="size-3 rounded-[3px] opacity-0" />;
  }
  const tooltip = `${cell.date} · ${cell.sessions} sessions · ${cell.messages} msgs`;
  return (
    <div
      title={showTooltip ? tooltip : undefined}
      className={cn(
        'size-3 rounded-[3px] transition-colors',
        cell.level === 0 && 'bg-heat-0',
        cell.level === 1 && 'bg-heat-1',
        cell.level === 2 && 'bg-heat-2',
        cell.level === 3 && 'bg-heat-3',
        cell.level === 4 && 'bg-heat-4',
      )}
    />
  );
}

function Legend() {
  return (
    <div className="flex items-center gap-1">
      <span>Less</span>
      <span className="size-3 rounded-[3px] bg-heat-0" />
      <span className="size-3 rounded-[3px] bg-heat-1" />
      <span className="size-3 rounded-[3px] bg-heat-2" />
      <span className="size-3 rounded-[3px] bg-heat-3" />
      <span className="size-3 rounded-[3px] bg-heat-4" />
      <span>More</span>
    </div>
  );
}

function buildGrid(days: HeatmapDay[], windowDays: number | null): { weeks: GridCell[][]; firstDate: string } {
  const map = new Map(days.map((d) => [d.date, d]));

  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);

  const earliest = days.length > 0 ? new Date(`${days[0]!.date}T00:00:00Z`) : today;
  const start = (() => {
    if (windowDays && windowDays > 0) {
      const s = new Date(today);
      s.setUTCDate(s.getUTCDate() - windowDays + 1);
      return s;
    }
    return earliest;
  })();

  // Snap start to the previous Sunday so each column is a clean week.
  const startSunday = new Date(start);
  startSunday.setUTCDate(startSunday.getUTCDate() - startSunday.getUTCDay());

  const weeks: GridCell[][] = [];
  const cursor = new Date(startSunday);
  while (cursor <= today) {
    const week: GridCell[] = [];
    for (let i = 0; i < 7; i++) {
      const iso = cursor.toISOString().slice(0, 10);
      const beforeStart = cursor < start;
      const afterToday = cursor > today;
      const day = map.get(iso);
      week.push({
        date: beforeStart || afterToday ? null : iso,
        sessions: day?.sessions ?? 0,
        messages: day?.messages ?? 0,
        level: levelFor(day?.sessions ?? 0),
      });
      cursor.setUTCDate(cursor.getUTCDate() + 1);
    }
    weeks.push(week);
  }

  return {
    weeks,
    firstDate: start.toISOString().slice(0, 10),
  };
}

function levelFor(sessions: number): 0 | 1 | 2 | 3 | 4 {
  if (sessions <= 0) return 0;
  if (sessions <= 2) return 1;
  if (sessions <= 5) return 2;
  if (sessions <= 10) return 3;
  return 4;
}
