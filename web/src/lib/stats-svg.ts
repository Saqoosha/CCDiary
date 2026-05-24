import type { HeatmapDay, StatsResponse } from './stats';

const WIDTH = 820;
const PAD = 0; // GitHub profile already provides outer margin around the image.
const INNER_W = WIDTH - PAD * 2;

const CARD_RADIUS = 8; // matches --radius-md (Stat)
const HEAT_RADIUS = 3; // matches rounded-[3px]

const COLS = 4;
const CARD_GAP = 10;
const CARD_W = (INNER_W - CARD_GAP * (COLS - 1)) / COLS;
const CARD_H1 = 92;
const CARD_H2 = 56;

const HEAT_CELL = 12;
const HEAT_GAP = 3;
const HEAT_WEEK = HEAT_CELL + HEAT_GAP;
const HEAT_MAX_WEEKS = 52;
const HEAT_GRID_H = 7 * HEAT_WEEK - HEAT_GAP;

const SPARK_W = 70;
const SPARK_H = 24;
const SPARK_WINDOW = 60;

const SECTION_GAP = 28;
const FOOTER_GAP = 18;

// Web --chart-N (oklch); pass through to modern browsers verbatim.
const COLOR_C1 = 'oklch(0.62 0.18 255)';
const COLOR_C2 = 'oklch(0.68 0.16 195)';
const COLOR_C3 = 'oklch(0.72 0.17 60)';
const COLOR_C5 = 'oklch(0.65 0.16 145)';

const WEB_URL = 'https://ccdiary.saqoo.sh';

interface Point {
  x: number;
  y: number;
}

export function renderStatsSvg(stats: StatsResponse): string {
  const heatmap = stats.heatmap;
  const sparkSlice = heatmap.slice(-SPARK_WINDOW);
  const sparks = {
    sessions: sparkSlice.map((d) => d.sessions),
    messages: sparkSlice.map((d) => d.messages),
    activeHours: sparkSlice.map((d) => d.active_minutes / 60),
    activeDays: runningStreak(heatmap).slice(-SPARK_WINDOW),
  };

  const cardsTop = PAD;
  const cardsBottom = cardsTop + CARD_H1 + CARD_GAP + CARD_H2;

  const heatTop = cardsBottom + SECTION_GAP;
  const heatGridBottom = heatTop + HEAT_GRID_H;
  const heatLegendY = heatGridBottom + 16;

  const footerY = heatLegendY + FOOTER_GAP;
  const HEIGHT = footerY + 6;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}" role="img" aria-label="CCDiary stats">
  <title>CCDiary stats</title>
  <style>${baseStyle()}</style>
  <defs>${gradientDefs()}</defs>
  ${renderCards(stats, sparks)}
  ${renderHeatmapSection(heatmap, { top: heatTop, legendY: heatLegendY })}
  ${renderFooter(footerY)}
</svg>`;
}

function baseStyle(): string {
  return `
    .card-bg { fill: oklch(0.985 0 0); }
    .label { fill: oklch(0.556 0 0); font: 600 11px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; letter-spacing: 0.06em; }
    .value { fill: oklch(0.145 0 0); font: 600 20px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; font-variant-numeric: tabular-nums; }
    .caption { fill: oklch(0.556 0 0); font: 500 10px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; font-variant-numeric: tabular-nums; }
    .legend-text { fill: oklch(0.556 0 0); font: 400 10px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
    .footer-text { fill: oklch(0.556 0 0); font: 400 11px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
    .footer-link { fill: oklch(0.62 0.18 255); font: 500 11px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; text-decoration: underline; }
    .heat-cell-0 { fill: oklch(0.96 0.005 250); }
    .heat-cell-1 { fill: oklch(0.86 0.06 245); }
    .heat-cell-2 { fill: oklch(0.78 0.10 245); }
    .heat-cell-3 { fill: oklch(0.68 0.14 250); }
    .heat-cell-4 { fill: oklch(0.55 0.17 255); }
    @media (prefers-color-scheme: dark) {
      .card-bg { fill: oklch(0.205 0 0); }
      .label, .caption, .legend-text, .footer-text { fill: oklch(0.708 0 0); }
      .value { fill: oklch(0.985 0 0); }
      .footer-link { fill: oklch(0.72 0.16 255); }
      .heat-cell-0 { fill: oklch(0.205 0 0); }
      .heat-cell-1 { fill: oklch(0.32 0.06 245); }
      .heat-cell-2 { fill: oklch(0.42 0.10 245); }
      .heat-cell-3 { fill: oklch(0.55 0.14 250); }
      .heat-cell-4 { fill: oklch(0.70 0.17 255); }
    }
  `;
}

function gradientDefs(): string {
  const spark = (id: string, color: string) => `
    <linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="${color}" stop-opacity="0.55" />
      <stop offset="100%" stop-color="${color}" stop-opacity="0.04" />
    </linearGradient>`;
  return [
    spark('spark-c1', COLOR_C1),
    spark('spark-c2', COLOR_C2),
    spark('spark-c3', COLOR_C3),
    spark('spark-c5', COLOR_C5),
  ].join('');
}

interface CardSparks {
  sessions: number[];
  messages: number[];
  activeHours: number[];
  activeDays: number[];
}

function renderCards(stats: StatsResponse, sparks: CardSparks): string {
  const { cards } = stats;
  const activeDays = Number(cards.diaries.value) || 0;
  const totalSessions = Number(cards.sessions.value) || 0;
  const totalMessages = Number(cards.messages.value) || 0;
  const totalHours = Number(cards.active_hours.value) || 0;

  const avgSessions = activeDays > 0 ? totalSessions / activeDays : null;
  const avgMessages = activeDays > 0 ? totalMessages / activeDays : null;
  const avgHours = activeDays > 0 ? totalHours / activeDays : null;

  const items = [
    {
      label: 'SESSIONS',
      value: formatNumber(cards.sessions.value),
      caption: avgSessions !== null ? `${formatDecimal(avgSessions, 1)}/d avg` : undefined,
      spark: sparks.sessions,
      gradId: 'spark-c1',
      color: COLOR_C1,
    },
    {
      label: 'MESSAGES',
      value: formatNumber(cards.messages.value),
      caption: avgMessages !== null ? `${formatDecimal(avgMessages, 0)}/d avg` : undefined,
      spark: sparks.messages,
      gradId: 'spark-c2',
      color: COLOR_C2,
    },
    {
      label: 'ACTIVE HOURS',
      value: `${formatNumber(cards.active_hours.value)}h`,
      caption: avgHours !== null ? `${formatDecimal(avgHours, 1)}h/d avg` : undefined,
      spark: sparks.activeHours,
      gradId: 'spark-c3',
      color: COLOR_C3,
    },
    {
      label: 'ACTIVE DAYS',
      value: formatNumber(cards.diaries.value),
      spark: sparks.activeDays,
      gradId: 'spark-c5',
      color: COLOR_C5,
    },
    { label: 'CURRENT STREAK', value: `${formatNumber(cards.current_streak.value)}d` },
    { label: 'LONGEST STREAK', value: `${formatNumber(cards.longest_streak.value)}d` },
    { label: 'PEAK HOUR', value: String(cards.peak_hour.value) },
    { label: 'FAVORITE AI', value: titleCase(String(cards.favorite_provider.value)) },
  ];

  return items
    .map((card, i) => {
      const col = i % COLS;
      const row = Math.floor(i / COLS);
      const isRow1 = row === 0;
      const h = isRow1 ? CARD_H1 : CARD_H2;
      const x = PAD + col * (CARD_W + CARD_GAP);
      const y = PAD + (isRow1 ? 0 : CARD_H1 + CARD_GAP);
      const labelY = isRow1 ? 22 : 22;
      const valueY = isRow1 ? 56 : 44;
      const sparkSvg =
        isRow1 && card.spark && card.spark.length > 1 && card.color && card.gradId
          ? renderSparkline(card.spark, card.color, card.gradId, CARD_W - 12 - SPARK_W, (h - SPARK_H) / 2)
          : '';
      const captionSvg = isRow1 && card.caption
        ? `<text class="caption" x="14" y="76">${escapeXml(card.caption)}</text>`
        : '';
      return `<g transform="translate(${x},${y})">
        <rect class="card-bg" width="${CARD_W}" height="${h}" rx="${CARD_RADIUS}" />
        <text class="label" x="14" y="${labelY}">${escapeXml(card.label)}</text>
        <text class="value" x="14" y="${valueY}">${escapeXml(card.value)}</text>
        ${captionSvg}
        ${sparkSvg}
      </g>`;
    })
    .join('');
}

function renderSparkline(values: number[], color: string, gradId: string, x: number, y: number): string {
  const linePath = sparkPath(values, SPARK_W, SPARK_H);
  const areaPath = `${linePath} L${fmt(SPARK_W)},${fmt(SPARK_H)} L0,${fmt(SPARK_H)} Z`;
  return `<g transform="translate(${fmt(x)},${fmt(y)})">
    <path d="${areaPath}" fill="url(#${gradId})" />
    <path d="${linePath}" fill="none" stroke="${color}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
  </g>`;
}

interface HeatLayout {
  top: number;
  legendY: number;
}

function renderHeatmapSection(heatmap: HeatmapDay[], layout: HeatLayout): string {
  if (heatmap.length === 0) return '';
  const grid = buildHeatmapGrid(heatmap);
  const visibleWeeks = grid.weeks.slice(-HEAT_MAX_WEEKS);
  const startX = PAD;
  const firstVisibleDate = firstNonNullDate(visibleWeeks);

  const cells = visibleWeeks
    .map((week, wi) =>
      week
        .map((cell, di) => {
          if (cell === null) return '';
          const cx = startX + wi * HEAT_WEEK;
          const cy = layout.top + di * HEAT_WEEK;
          const level = levelFor(cell.sessions);
          return `<rect class="heat-cell-${level}" x="${cx}" y="${cy}" width="${HEAT_CELL}" height="${HEAT_CELL}" rx="${HEAT_RADIUS}" />`;
        })
        .join(''),
    )
    .join('');

  // Legend on right: Less ▢▢▢▢▢ More
  const swatchSize = 10;
  const swatchGap = 3;
  const legendRight = WIDTH - PAD;
  let cursor = legendRight;
  const moreText = 'More';
  const moreW = measureText(moreText, 10);
  cursor -= moreW;
  const moreEl = `<text class="legend-text" x="${fmt(cursor)}" y="${layout.legendY}">${moreText}</text>`;
  cursor -= 4 + 5 * (swatchSize + swatchGap) - swatchGap;
  const swatches: string[] = [];
  for (let i = 0; i < 5; i++) {
    const sx = cursor + i * (swatchSize + swatchGap);
    swatches.push(
      `<rect class="heat-cell-${i}" x="${fmt(sx)}" y="${layout.legendY - swatchSize + 1}" width="${swatchSize}" height="${swatchSize}" rx="${HEAT_RADIUS}" />`,
    );
  }
  cursor -= 4 + measureText('Less', 10);
  const lessEl = `<text class="legend-text" x="${fmt(cursor)}" y="${layout.legendY}">Less</text>`;

  const firstDateEl = `<text class="legend-text" x="${startX}" y="${layout.legendY}">${escapeXml(firstVisibleDate ?? '')}</text>`;

  return `${cells}
    ${firstDateEl}
    ${lessEl}
    ${swatches.join('')}
    ${moreEl}`;
}

function renderFooter(y: number): string {
  const prefix = 'Created by ';
  const link = 'CCDiary';
  const prefixW = measureText(prefix, 11);
  const linkW = measureText(link, 11);
  const totalW = prefixW + linkW;
  const startX = (WIDTH - totalW) / 2;
  return `<text class="footer-text" x="${fmt(startX)}" y="${y}">${prefix}</text>
    <a href="${WEB_URL}" target="_blank"><text class="footer-link" x="${fmt(startX + prefixW)}" y="${y}">${link}</text></a>`;
}

function buildHeatmapGrid(days: HeatmapDay[]): { weeks: (HeatmapDay | null)[][] } {
  const map = new Map(days.map((d) => [d.date, d]));
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);
  const sorted = [...days].sort((a, b) => a.date.localeCompare(b.date));
  const earliest = sorted.length > 0 ? new Date(`${sorted[0]!.date}T00:00:00Z`) : today;
  const startSunday = new Date(earliest);
  startSunday.setUTCDate(startSunday.getUTCDate() - startSunday.getUTCDay());

  const weeks: (HeatmapDay | null)[][] = [];
  const cursor = new Date(startSunday);
  while (cursor <= today) {
    const week: (HeatmapDay | null)[] = [];
    for (let i = 0; i < 7; i++) {
      const iso = cursor.toISOString().slice(0, 10);
      const beforeStart = cursor < earliest;
      const afterToday = cursor > today;
      if (beforeStart || afterToday) {
        week.push(null);
      } else {
        week.push(map.get(iso) ?? { date: iso, sessions: 0, messages: 0, active_minutes: 0, project_count: 0 });
      }
      cursor.setUTCDate(cursor.getUTCDate() + 1);
    }
    weeks.push(week);
  }
  return { weeks };
}

function firstNonNullDate(weeks: (HeatmapDay | null)[][]): string | null {
  for (const week of weeks) {
    for (const cell of week) {
      if (cell !== null) return cell.date;
    }
  }
  return null;
}

function levelFor(sessions: number): 0 | 1 | 2 | 3 | 4 {
  if (sessions <= 0) return 0;
  if (sessions <= 2) return 1;
  if (sessions <= 5) return 2;
  if (sessions <= 10) return 3;
  return 4;
}

function runningStreak(days: HeatmapDay[]): number[] {
  let run = 0;
  return days.map((d) => {
    run = d.sessions > 0 ? run + 1 : 0;
    return run;
  });
}

function sparkPath(values: number[], w: number, h: number): string {
  const padY = 2;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;
  const innerH = h - padY * 2;
  const stepX = w / (values.length - 1);
  const pts: Point[] = values.map((v, i) => ({
    x: i * stepX,
    y: padY + innerH - ((v - min) / range) * innerH,
  }));
  return smoothPath(pts);
}

function smoothPath(pts: Point[]): string {
  if (pts.length === 0) return '';
  let d = `M${fmt(pts[0]!.x)},${fmt(pts[0]!.y)}`;
  for (let i = 1; i < pts.length; i++) {
    const p0 = pts[i - 1]!;
    const p1 = pts[i]!;
    const xm = (p0.x + p1.x) / 2;
    d += `C${fmt(xm)},${fmt(p0.y)} ${fmt(xm)},${fmt(p1.y)} ${fmt(p1.x)},${fmt(p1.y)}`;
  }
  return d;
}

function formatNumber(v: string | number): string {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return String(v);
  return n.toLocaleString('en-US');
}

function formatDecimal(n: number, places: number): string {
  if (!Number.isFinite(n)) return String(n);
  return n.toLocaleString('en-US', { minimumFractionDigits: places, maximumFractionDigits: places });
}

function titleCase(s: string): string {
  if (!s || s === '—') return s;
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}

function fmt(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(1);
}

/** Rough text-width estimate (in px) for system font; used for layout only. */
function measureText(s: string, fontSize: number): number {
  return s.length * fontSize * 0.6;
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}
