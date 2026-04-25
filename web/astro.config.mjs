// @ts-check
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
//
// The earlier `import.meta.env?.PROD` check evaluated at Node config load
// time, before Vite's env was wired up — so the alias never applied and
// production builds shipped node-targeted `react-dom/server` instead of the
// Workers-friendly `.edge` build. `astro build` sets NODE_ENV=production, so
// keying the swap off that runs the alias only during builds.
// `astro build` sets `NODE_ENV=production`. Skip @types/node by reading via
// `globalThis.process` — Node 20+ guarantees the global, and avoids pulling
// node typings into the Worker bundle.
const isProdBuild =
  /** @type {{ env?: Record<string, string | undefined> }} */
  (/** @type {any} */ (globalThis).process)?.env?.NODE_ENV === 'production';

export default defineConfig({
  output: 'server',
  adapter: cloudflare(),
  integrations: [react()],
  vite: {
    plugins: [tailwindcss()],
    resolve: {
      // Workaround for `react-dom/server` resolution under the Workers runtime.
      alias: isProdBuild
        ? { 'react-dom/server': 'react-dom/server.edge' }
        : undefined,
    },
  },
});
