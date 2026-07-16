-- 02. Валидация и безопасность.
-- Требования к preload: pgsodium (для Server Key Management / TCE / vault).
-- В supabase-образе серверный ключ уже настроен. На чистом bookworm нужно
-- shared_preload_libraries='pgsodium' + pgsodium.getkey_script.
\echo '== 02 validation & security =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_jsonschema;     -- функции json_matches_schema / jsonb_matches_schema
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_jsonschema: %', SQLERRM; END $$;
-- ⚠️ Имя API: json_matches_schema/jsonb_matches_schema (НЕ jsonschema_matches).
-- Для повторных проверок быстрее тип 'jsonschema' + json_matches_compiled_schema (~1.8x).

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgsodium;          -- схема 'pgsodium' (строго), TCE, key mgmt
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pgsodium: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS supabase_vault;  -- vault.secrets / vault.decrypted_secrets
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'supabase_vault: %', SQLERRM; END $$;
-- vault v0.3.1 — C/PGXS, линкует libsodium сам, больше НЕ зависит от pgsodium.
-- pgsodium создаётся выше отдельно (для SQL-API TCE).
-- Рекомендация: ALTER SYSTEM SET log_statement = 'none', чтобы секреты не утекали в логи.
