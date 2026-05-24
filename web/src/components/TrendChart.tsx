import { useMemo, useState } from 'react';
import { Area, AreaChart, CartesianGrid, XAxis, YAxis } from 'recharts';
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from '@/components/ui/chart';
import { cn } from '@/lib/utils';

export interface TrendPoint {
  date: string;
  sessions: number;
  messages: number;
  active_minutes: number;
  project_count: number;
}

type Metric = 'sessions' | 'messages' | 'active_hours' | 'project_count';

type Summary = 'total' | 'average';

interface MetricDef {
  key: Metric;
  label: string;
  colorVar: string;
  /** How the headline number summarises the visible range. */
  summary: Summary;
  pick: (p: TrendPoint) => number;
  format: (v: number) => string;
}

const METRICS: MetricDef[] = [
  {
    key: 'sessions',
    label: 'Sessions',
    colorVar: 'var(--chart-1)',
    summary: 'total',
    pick: (p) => p.sessions,
    format: (v) => v.toLocaleString(),
  },
  {
    key: 'messages',
    label: 'Messages',
    colorVar: 'var(--chart-2)',
    summary: 'total',
    pick: (p) => p.messages,
    format: (v) => v.toLocaleString(),
  },
  {
    // Keep full precision in `pick` so summing 190 days doesn't drift; the
    // formatter rounds only at display time, matching the card total.
    key: 'active_hours',
    label: 'Active hours',
    colorVar: 'var(--chart-3)',
    summary: 'total',
    pick: (p) => p.active_minutes / 60,
    format: (v) => `${Math.round(v).toLocaleString()}h`,
  },
  {
    key: 'project_count',
    // Summing project_count across days double-counts a project active on many
    // days. Show the per-day average instead — that's the number the headline
    // can honestly claim.
    label: 'Projects',
    colorVar: 'var(--chart-4)',
    summary: 'average',
    pick: (p) => p.project_count,
    format: (v) => v.toLocaleString(),
  },
];

interface Props {
  points: TrendPoint[];
}

export function TrendChart({ points }: Props) {
  const [metric, setMetric] = useState<Metric>('sessions');
  const def = METRICS.find((m) => m.key === metric)!;

  const data = useMemo(
    () =>
      points.map((p) => ({
        date: p.date,
        value: def.pick(p),
      })),
    [points, def],
  );

  const { headline, headlineLabel, peak } = useMemo(() => {
    const peak = data.reduce((acc, d) => Math.max(acc, d.value), 0);
    const sum = data.reduce((acc, d) => acc + d.value, 0);
    if (def.summary === 'average') {
      const avg = data.length > 0 ? sum / data.length : 0;
      return {
        headline: def.format(Math.round(avg * 10) / 10),
        headlineLabel: 'avg/day',
        peak,
      };
    }
    return { headline: def.format(sum), headlineLabel: 'total', peak };
  }, [data, def]);

  const config = {
    value: { label: def.label, color: def.colorVar },
  } satisfies ChartConfig;

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h3 className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
            Daily trend
          </h3>
          <div className="mt-1 flex items-baseline gap-3">
            <span
              className="text-2xl font-semibold tabular-nums"
              style={{ color: def.colorVar }}
            >
              {headline}
            </span>
            <span className="text-xs text-muted-foreground">
              {headlineLabel} · peak {def.format(peak)}
            </span>
          </div>
        </div>
        <div className="inline-flex rounded-md bg-muted/60 p-0.5 text-xs">
          {METRICS.map((m) => {
            const selected = metric === m.key;
            return (
              <button
                key={m.key}
                type="button"
                onClick={() => setMetric(m.key)}
                className={cn(
                  'rounded-[5px] px-2 py-1 transition-colors',
                  selected
                    ? 'bg-background text-foreground shadow-xs'
                    : 'text-muted-foreground hover:text-foreground',
                )}
              >
                {m.label}
              </button>
            );
          })}
        </div>
      </div>

      {data.length === 0 ? (
        <div className="flex h-[180px] items-center justify-center text-xs text-muted-foreground">
          No data yet.
        </div>
      ) : (
        <ChartContainer config={config} className="aspect-auto h-[200px] w-full">
          <AreaChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <defs>
              <linearGradient id="trend-fill" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={def.colorVar} stopOpacity={0.45} />
                <stop offset="100%" stopColor={def.colorVar} stopOpacity={0.02} />
              </linearGradient>
            </defs>
            <CartesianGrid vertical={false} strokeDasharray="3 3" opacity={0.4} />
            <XAxis
              dataKey="date"
              tickLine={false}
              axisLine={false}
              tickMargin={6}
              minTickGap={32}
              tickFormatter={shortDate}
              fontSize={10}
            />
            <YAxis
              tickLine={false}
              axisLine={false}
              tickMargin={4}
              width={32}
              fontSize={10}
              tickFormatter={shortNumber}
            />
            <ChartTooltip
              cursor={{ stroke: def.colorVar, strokeOpacity: 0.4, strokeDasharray: '3 3' }}
              content={
                <ChartTooltipContent
                  indicator="dot"
                  labelFormatter={(label) => label}
                  formatter={(value) => def.format(Number(value))}
                />
              }
            />
            <Area
              dataKey="value"
              type="monotone"
              stroke={def.colorVar}
              strokeWidth={2}
              fill="url(#trend-fill)"
              activeDot={{ r: 4, strokeWidth: 0 }}
            />
          </AreaChart>
        </ChartContainer>
      )}
    </div>
  );
}

function shortDate(iso: string): string {
  // 2026-05-23 → 5/23
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  return `${Number(m[2])}/${Number(m[3])}`;
}

function shortNumber(n: number): string {
  if (n >= 1000) return `${(n / 1000).toFixed(n >= 10_000 ? 0 : 1)}k`;
  return n.toLocaleString();
}
