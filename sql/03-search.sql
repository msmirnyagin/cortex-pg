-- 03. Полнотекстовый / гибридный поиск.
-- Ни одно не требует shared_preload_libraries — все три реализуют свой access method.
\echo '== 03 search =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgroonga;   -- мультиязычный FTS (особенно CJK): &@~ (query), &@* (similar)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pgroonga: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_search;  -- ParadeDB BM25 (Tantivy): pdb.score(), операторы ||| &&& ===
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_search: %', SQLERRM; END $$;
-- Примечание: ровно ОДИН bm25-индекс на таблицу; для смены конфигурации — DROP + пересоздание.

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS rum;        -- tsvector + ранжирование/recency без heap scan
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'rum: %', SQLERRM; END $$;
