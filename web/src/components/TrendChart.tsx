import { useId, useMemo, useState } from 'react';
import { Area, AreaChart, CartesianGrid, XAxis, YAxis } from 'recharts';
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from '@/components/ui/chart';
import { cn } from '@/lib/utils';
import type { HeatmapDay } from '@/lib/stats';

export type TrendPoint = HeatmapDay;

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

// Keyed by Metric so the lookup in the component is total — no
// non-null assertion needed, and the compiler enforces that every key
// in the Metric union has a definition (adding a new metric forces
// filling this in).
const METRICS: Record<Metric, MetricDef> = {
  sessions: {
    key: 'sessions',
    label: 'Sessions',
    colorVar: 'var(--chart-1)',
    summary: 'total',
    pick: (p) => p.sessions,
    format: (v) => v.toLocaleString(),
  },
  messages: {
    key: 'messages',
    label: 'Messages',
    colorVar: 'var(--chart-2)',
    summary: 'total',
    pick: (p) => p.messages,
    format: (v) => v.toLocaleString(),
  },
  // Keep full precision in `pick` so summing 190 days doesn't drift; the
  // formatter rounds only at display time, matching the card total.
  active_hours: {
    key: 'active_hours',
    label: 'Active hours',
    colorVar: 'var(--chart-3)',
    summary: 'total',
    pick: (p) => p.active_minutes / 60,
    format: (v) => `${Math.round(v).toLocaleString()}h`,
  },
  // Summing project_count across days double-counts a project active on
  // many days. Show the per-day average instead — that's the number the
  // headline can honestly claim.
  project_count: {
    key: 'project_count',
    label: 'Projects',
    colorVar: 'var(--chart-4)',
    summary: 'average',
    pick: (p) => p.project_count,
    format: (v) => v.toLocaleString(),
  },
};

// Tab order is decoupled from the Record so the UI stays predictable
// even though Record key order isn't part of the type.
const METRIC_ORDER: Metric[] = ['sessions', 'messages', 'active_hours', 'project_count'];

interface Props {
  points: TrendPoint[];
  /** When true, clicking a point in the chart navigates to that day's diary. */
  linkable?: boolean;
}

export function TrendChart({ points, linkable = false }: Props) {
  const [metric, setMetric] = useState<Metric>('sessions');
  const def = METRICS[metric];

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

  const gradientId = `trend-fill-${useId().replace(/:/g, '')}`;

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
          {METRIC_ORDER.map((key) => {
            const m = METRICS[key];
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
        <ChartContainer
          config={config}
          className={cn(
            'aspect-auto h-[200px] w-full',
            linkable && '[&_.recharts-active-dot]:cursor-pointer',
          )}
        >
          <AreaChart
            data={data}
            margin={{ top: 8, right: 8, left: 0, bottom: 0 }}
            onClick={
              linkable
                ? (e) => {
                    // Recharts types `activeLabel` as `string | number`; our
                    // X axis is the ISO date string, but defend the type so a
                    // future recharts change can't turn this into `/123`.
                    const date = (e as { activeLabel?: unknown } | undefined)
                      ?.activeLabel;
                    if (typeof date === 'string' && date) {
                      window.location.href = `/${date}`;
                    }
                  }
                : undefined
            }
          >
            <defs>
              <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
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
              fill={`url(#${gradientId})`}
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
