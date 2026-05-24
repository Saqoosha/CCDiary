import { useId } from 'react';
import { Area, AreaChart } from 'recharts';
import { cn } from '@/lib/utils';

interface SparklineProps {
  values: number[];
  /** Any CSS color or var() reference. Defaults to the foreground color. */
  color?: string;
  width?: number;
  height?: number;
  className?: string;
}

/**
 * Tiny gradient area sparkline. No axes, no labels — meant to sit next to
 * a headline number in a stat card.
 */
export function Sparkline({
  values,
  color = 'currentColor',
  width = 84,
  height = 26,
  className,
}: SparklineProps) {
  const gid = useId().replace(/:/g, '');
  if (values.length === 0) {
    return <div style={{ width, height }} className={className} aria-hidden />;
  }

  const data = values.map((v, i) => ({ i, v }));

  return (
    <div style={{ width, height }} className={cn('shrink-0', className)} aria-hidden>
      <AreaChart
        width={width}
        height={height}
        data={data}
        margin={{ top: 2, right: 0, bottom: 1, left: 0 }}
      >
        <defs>
          <linearGradient id={`spark-${gid}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.55} />
            <stop offset="100%" stopColor={color} stopOpacity={0.04} />
          </linearGradient>
        </defs>
        <Area
          dataKey="v"
          type="monotone"
          stroke={color}
          strokeWidth={1.5}
          fill={`url(#spark-${gid})`}
          isAnimationActive={false}
          dot={false}
          activeDot={false}
        />
      </AreaChart>
    </div>
  );
}
