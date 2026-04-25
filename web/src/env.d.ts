/// <reference types="astro/client" />
/// <reference types="@cloudflare/workers-types/2023-07-01" />

declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    ASSETS: Fetcher;
    CCDIARY_INGEST_TOKEN: string;
  }
}
