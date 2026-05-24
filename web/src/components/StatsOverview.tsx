import { useEffect, useMemo, useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Separator } from '@/components/ui/separator';
import { cn } from '@/lib/utils';
import type { HeatmapDay } from '@/lib/stats';
import { HeatmapGrid } from './HeatmapGrid';
import { Sparkline } from './Sparkline';
import { TrendChart } from './TrendChart';

type Range = 'all' | '30d' | '7d';

interface StatCard {
  value: string | number;
  unit?: string;
  label?: string;
}

interface StatsResponse {
  range: Range;
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

interface Props {
  initial: StatsResponse;
  /** Heatmap cell tooltips; off when the visitor cannot open diary pages. */
  showHeatmapTooltips?: boolean;
}

export function StatsOverview({ initial, showHeatmapTooltips = true }: Props) {
  const [range, setRange] = useState<Range>(initial.range);
  const [data, setData] = useState<StatsResponse>(initial);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (range === initial.range) {
      setData(initial);
      return;
    }
    let cancelled = false;
    setLoading(true);
    fetch(`/api/stats?range=${range}`)
      .then(async (r) => {
        if (!r.ok) throw new Error(`stats endpoint returned ${r.status}`);
        return (await r.json()) as StatsResponse;
      })
      .then((next) => {
        if (!cancelled) setData(next);
      })
      .catch((err) => {
        // Surface the failure in devtools but don't blow away the existing
        // data — keeping the previous range visible is friendlier than a
        // half-rendered card grid.
        console.error('Failed to refresh stats:', err);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [range, initial]);

  const heatmapWindow = useMemo(() => {
    if (range === '7d') return 7;
    if (range === '30d') return 30;
    return null;
  }, [range]);

  const trendPoints = data.heatmap;
  const sparkSlice = useMemo(() => {
    // Sparklines hug the same time window as the selected range so the
    // headline number and the line tell the same story.
    const window = range === '7d' ? 7 : range === '30d' ? 30 : 60;
    return trendPoints.slice(-window);
  }, [trendPoints, range]);

  return (
    <Card className="overflow-hidden">
      <CardContent className="px-6">
        <div className="flex items-center justify-end">
          <SegmentedTabs<Range>
            value={range}
            options={[
              { value: 'all', label: 'All' },
              { value: '30d', label: '30d' },
              { value: '7d', label: '7d' },
            ]}
            onChange={setRange}
          />
        </div>

        <Separator className="my-4" />

        <div className={cn('transition-opacity', loading && 'opacity-60')}>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            <Stat
              label="Sessions"
              card={data.cards.sessions}
              spark={sparkSlice.map((p) => p.sessions)}
              sparkColor="var(--chart-1)"
            />
            <Stat
              label="Messages"
              card={data.cards.messages}
              spark={sparkSlice.map((p) => p.messages)}
              sparkColor="var(--chart-2)"
            />
            <Stat
              label="Active hours"
              card={data.cards.active_hours}
              spark={sparkSlice.map((p) => p.active_minutes / 60)}
              sparkColor="var(--chart-3)"
            />
            <Stat label="Active days" card={data.cards.diaries} />
            <Stat label="Current streak" card={data.cards.current_streak} />
            <Stat label="Longest streak" card={data.cards.longest_streak} />
            <Stat label="Peak hour" card={data.cards.peak_hour} />
            <Stat label="Top project" card={data.cards.top_project} />
          </div>

          <div className="mt-6">
            <TrendChart points={trendPoints} />
          </div>

          <div className="mt-6">
            <HeatmapGrid
              days={data.heatmap}
              windowDays={heatmapWindow}
              showCellTooltips={showHeatmapTooltips}
            />
          </div>

          {data.fun_fact && (
            <p className="mt-3 text-xs text-muted-foreground">{data.fun_fact}</p>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

function Stat({
  label,
  card,
  spark,
  sparkColor,
}: {
  label: string;
  card: StatCard;
  spark?: number[];
  sparkColor?: string;
}) {
  const display = formatCard(card);
  return (
    <div className="rounded-md bg-muted/50 px-3 py-2">
      <div className="text-[11px] uppercase tracking-wider text-muted-foreground">{label}</div>
      <div className="mt-1 flex items-end justify-between gap-2">
        <div className="text-base font-semibold tabular-nums">{display}</div>
        {spark && spark.length > 1 && <Sparkline values={spark} color={sparkColor} />}
      </div>
    </div>
  );
}

function formatCard(card: StatCard): string {
  const v = typeof card.value === 'number' ? card.value.toLocaleString() : card.value;
  return card.unit ? `${v}${card.unit}` : `${v}`;
}

interface SegmentedOption<T extends string> {
  value: T;
  label: string;
  disabled?: boolean;
}

function SegmentedTabs<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: SegmentedOption<T>[];
  onChange: (next: T) => void;
}) {
  return (
    <div className="inline-flex rounded-md bg-muted/60 p-0.5 text-sm">
      {options.map((opt) => {
        const selected = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            disabled={opt.disabled}
            onClick={() => !opt.disabled && onChange(opt.value)}
            className={cn(
              'rounded-[5px] px-2.5 py-1 transition-colors',
              selected
                ? 'bg-background text-foreground shadow-xs'
                : 'text-muted-foreground hover:text-foreground',
              opt.disabled && 'cursor-not-allowed opacity-50 hover:text-muted-foreground',
            )}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}
