/**
 * Tiny date helpers shared by Astro pages and React components. Living in a
 * `.ts` file (rather than inside an Astro frontmatter) keeps the TypeScript
 * lib resolution simple — Astro frontmatter has occasional quirks around
 * `globalThis.Date` typing.
 */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** True iff `value` is a real calendar date in `YYYY-MM-DD` form. The regex
 * only validates shape — `2026-02-31` would slip through unchecked, then
 * round-trip through `new Date(...)` to `2026-03-03` and create a route whose
 * URL slug doesn't match the page title. The `toISOString` round-trip rejects
 * any value that gets normalized into a different day. */
export function isIsoDate(value: string): boolean {
  if (!ISO_DATE.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return false;
  return d.toISOString().slice(0, 10) === value;
}

export function shiftIsoDate(iso: string, deltaDays: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return d.toISOString().slice(0, 10);
}

export function formatJaLong(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  return new Intl.DateTimeFormat('ja-JP', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    weekday: 'long',
    timeZone: 'UTC',
  }).format(d);
}
