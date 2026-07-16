-- 00. Базовые contrib-расширения (входят в ядро/supabase-образ).
-- Каждое создание обёрнуто в DO/EXCEPTION, чтобы отсутствующее расширение
-- не прерывало всю инициализацию — выводится NOTICE с причиной.
\echo '== 00 base extensions =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- статистика запросов (нужен preload для сбора)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_stat_statements: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- digest/hmac, crypt/gen_salt (bcrypt), PGP, armor
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pgcrypto: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- триграммы, нечёткий текстовый поиск
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_trgm: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS btree_gin;  -- комбинированные GIN-индексы для гибридного поиска
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'btree_gin: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS btree_gist;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'btree_gist: %', SQLERRM; END $$;
