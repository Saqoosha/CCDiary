import { Marked } from 'marked';
import { createHighlighter, type Highlighter } from 'shiki';

let highlighterPromise: Promise<Highlighter> | null = null;

async function getHighlighter(): Promise<Highlighter> {
  highlighterPromise ??= createHighlighter({
    themes: ['github-light'],
    langs: ['typescript', 'javascript', 'tsx', 'jsx', 'swift', 'bash', 'json', 'sql', 'markdown'],
  });
  return await highlighterPromise;
}

const marked = new Marked({
  gfm: true,
  breaks: false,
  async: true,
});

marked.use({
  async: true,
  async walkTokens(token) {
    if (token.type === 'code') {
      const highlighter = await getHighlighter();
      const lang = token.lang && highlighter.getLoadedLanguages().includes(token.lang)
        ? token.lang
        : 'text';
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const html = highlighter.codeToHtml(token.text, { lang, theme: 'github-light' });
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (token as any).text = html;
        // Set `escaped` only AFTER Shiki succeeds: on failure the token still
        // carries raw markdown, and we want the renderer below to escape it.
        token.escaped = true;
      } catch (err) {
        // Leave token.text/escaped untouched so the renderer escapes manually.
        console.warn(`shiki failed for lang=${lang}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  },
  renderer: {
    code({ text, escaped }) {
      if (escaped) return text;
      const safe = text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
      return `<pre><code>${safe}</code></pre>`;
    },
  },
});

/** Render diary markdown to HTML. The first H1 (date heading) is stripped — the
 *  page already shows the date in the page title, so a duplicate looks noisy. */
export async function renderDiaryMarkdown(markdown: string): Promise<string> {
  const stripped = markdown.replace(/^#\s+.+\n+/, '');
  return await marked.parse(stripped);
}
