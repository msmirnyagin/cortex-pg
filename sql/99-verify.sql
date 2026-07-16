-- 99. Верификация установленного стека.
-- Запускается последним; выводит установленные расширения и их версии,
-- что закрывает все «уточнить версию»-пункты из исследования.
\echo '== installed extensions =='

SELECT extname AS extension, extversion AS version
FROM pg_extension
ORDER BY extname;

-- Ожидаемые версии (база postgres:17-bookworm + PGDG apt):
--   vector          0.8.1    (пин ради совместимости с pg_turboquant)
--   age, pg_cron, rum, hypopg, http, pg_hint_plan, pgroonga  — из apt
--   pg_turboquant   из исходников (C/PGXS)
--   pg_durable      .deb v0.2.2 (Microsoft)
--   pg_search       .deb v0.24.1 (ParadeDB)
--   pgmq, index_advisor, pg_net — SQL/C из исходников
--   pgsodium, supabase_vault, pg_jsonschema, pg_graphql — pgrx/Rust

\echo '== shared_preload_libraries (min: pgsodium; max: pg_cron,pg_durable,pg_search,pgsodium,pg_net) =='
SELECT name, setting FROM pg_settings WHERE name = 'shared_preload_libraries';

\echo '== background worker slots =='
SELECT name, setting FROM pg_settings
WHERE name IN ('max_worker_processes', 'shared_preload_libraries')
ORDER BY name;
