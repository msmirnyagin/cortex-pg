-- 99. Верификация установленного стека.
-- Запускается последним; выводит установленные расширения и их версии,
-- что закрывает все «уточнить версию»-пункты из исследования.
\echo '== installed extensions =='

SELECT extname AS extension, extversion AS version
FROM pg_extension
ORDER BY extname;

-- Ожидаемые версии (база supabase:17.6.1.148):
--   vector          ~0.8.5   (pg_turboquant CI пинит 0.8.1 — проверять совместимость)
--   pg_cron         1.6.4    (upstream 1.6.7)
--   pgmq            1.5.1    (upstream 1.12.0)
--   hypopg          1.4.1    (upstream 1.4.3)
--   index_advisor   0.2.0
--   pgsodium        3.1.11 ; supabase_vault 0.3.1 ; pg_jsonschema 0.3.4
--   pg_graphql      1.6.1 ; pg_net 0.20.5

\echo '== shared_preload_libraries (ожидаются pg_cron,pg_durable,pg_net,pgsodium) =='
SELECT name, setting FROM pg_settings WHERE name = 'shared_preload_libraries';

\echo '== background worker slots =='
SELECT name, setting FROM pg_settings
WHERE name IN ('max_worker_processes', 'shared_preload_libraries')
ORDER BY name;
