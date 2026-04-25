-- CCDiary D1 schema
-- Apply locally:  bunx wrangler d1 execute ccdiary --local --file=./schema.sql
-- Apply remote:   bunx wrangler d1 execute ccdiary --remote --file=./schema.sql
--
-- Idempotent: every CREATE uses IF NOT EXISTS. Re-running this file is safe
-- (FTS triggers, however, are dropped + recreated to stay in sync with logic).

CREATE TABLE IF NOT EXISTS diaries (
    date           TEXT PRIMARY KEY,
    markdown       TEXT NOT NULL,
    generated_at   INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    provider       TEXT,
    model          TEXT,
    source         TEXT NOT NULL DEFAULT 'cli',

    sessions       INTEGER NOT NULL DEFAULT 0,
    messages       INTEGER NOT NULL DEFAULT 0,
    project_count  INTEGER NOT NULL DEFAULT 0,
    active_minutes INTEGER NOT NULL DEFAULT 0,
    peak_hour      INTEGER,
    top_project    TEXT,
    sources_json   TEXT,
    projects_json  TEXT
);

CREATE INDEX IF NOT EXISTS idx_diaries_year_month   ON diaries(substr(date, 1, 7));
CREATE INDEX IF NOT EXISTS idx_diaries_generated_at ON diaries(generated_at);

-- FTS5 virtual table for future /search endpoint.
CREATE VIRTUAL TABLE IF NOT EXISTS diaries_fts USING fts5(
    date UNINDEXED,
    markdown,
    content='diaries',
    content_rowid='rowid'
);

-- Keep FTS index in sync with the diaries table.
DROP TRIGGER IF EXISTS diaries_ai;
DROP TRIGGER IF EXISTS diaries_au;
DROP TRIGGER IF EXISTS diaries_ad;

CREATE TRIGGER diaries_ai AFTER INSERT ON diaries BEGIN
    INSERT INTO diaries_fts(rowid, date, markdown)
    VALUES (new.rowid, new.date, new.markdown);
END;

CREATE TRIGGER diaries_au AFTER UPDATE ON diaries BEGIN
    INSERT INTO diaries_fts(diaries_fts, rowid, date, markdown)
    VALUES ('delete', old.rowid, old.date, old.markdown);
    INSERT INTO diaries_fts(rowid, date, markdown)
    VALUES (new.rowid, new.date, new.markdown);
END;

CREATE TRIGGER diaries_ad AFTER DELETE ON diaries BEGIN
    INSERT INTO diaries_fts(diaries_fts, rowid, date, markdown)
    VALUES ('delete', old.rowid, old.date, old.markdown);
END;
