-- 01. Векторный поиск.
-- ПОРЯДОК КРИТИЧЕН: pg_turboquant требует, чтобы 'vector' был создан ПЕРВЫМ
-- (жёсткая зависимость от типов vector/halfvec из pgvector).
\echo '== 01 vectors =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS vector;          -- pgvector: hnsw/ivfflat, типы vector/halfvec/bit/sparsevec
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'vector: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_turboquant;   -- access method 'turboquant' (TurboQuant v2 + SIMD)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_turboquant: %', SQLERRM; END $$;
-- Примечание: pg_turboquant — АЛЬТЕРНАТИВА hnsw/ivfflat (не комбинация).
-- На одну колонку создаётся либо hnsw/ivfflat, либо turboquant.
