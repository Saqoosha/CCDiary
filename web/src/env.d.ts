/// <reference types="astro/client" />
/// <reference types="@cloudflare/workers-types/2023-07-01" />

declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    ASSETS: Fetcher;
    SESSION: KVNamespace;
    CCDIARY_INGEST_TOKEN: string;
    /** When set, visitors need /login + session cookie to open diary pages and GET /api/diaries. */
    CCDIARY_SITE_PASSWORD?: string;
    /** Random secret for signing `ccdiary_sess` (required when CCDIARY_SITE_PASSWORD is set). */
    CCDIARY_SESSION_SECRET?: string;
    /**
     * Local/dev only: if `CCDIARY_SITE_PASSWORD` is unset, set to `1` or `true`
     * so the UI behaves like the old “open” mode. Omit in production.
     */
    CCDIARY_OPEN_WITHOUT_PASSWORD?: string;
  }
}
