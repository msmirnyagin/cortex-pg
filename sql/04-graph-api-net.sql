-- 04. Графы, GraphQL, HTTP из SQL.
-- pg_net требует preload (background worker); http — синхронный, без preload.
\echo '== 04 graph / api / net =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS age;        -- Apache AGE: openCypher через cypher(), тип agtype
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'age: %', SQLERRM; END $$;
-- ⚠️ ag_catalog нельзя создавать заранее из другой роли — иначе CREATE EXTENSION age упадёт.

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_graphql; -- graphql.resolve() / graphql_public.graphql()
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_graphql: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_net;     -- net.http_get/post/delete (асинхронный, request_id)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_net: %', SQLERRM; END $$;
-- pg_net: один worker на кластер, привязан к pg_net.database_name (по умолчанию 'postgres').

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS http;       -- pgsql-http (синхронный): http_get/post/...
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'http: %', SQLERRM; END $$;

-- AGE: документированная настройка — ag_catalog первым в search_path (для cypher без квалификации).
-- Объекты public по-прежнему видны (public остаётся в пути). Применяйте, если AGE активно используется.
DO $$ BEGIN
  ALTER DATABASE postgres SET search_path = ag_catalog, "$user", public;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'AGE search_path: %', SQLERRM; END $$;
