-- 02. Валидация и безопасность.
-- Требования к preload: supabase_vault (шифрование секретов; грузит корневой
-- ключ через vault.getkey_script при старте, ТОЛЬКО из preload).
-- pgsodium УБРАН (Supabase deprecated) — vault v0.3.1 самодостаточен.
\echo '== 02 validation & security =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_jsonschema;     -- функции json_matches_schema / jsonb_matches_schema
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_jsonschema: %', SQLERRM; END $$;
-- ⚠️ Имя API: json_matches_schema/jsonb_matches_schema (НЕ jsonschema_matches).
-- Для повторных проверок быстрее тип 'jsonschema' + json_matches_compiled_schema (~1.8x).

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS supabase_vault;    -- vault.secrets / vault.decrypted_secrets
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'supabase_vault: %', SQLERRM; END $$;
-- vault v0.3.1 — C/PGXS, линкует libsodium сам, НЕ зависит от pgsodium.
-- Шифрование работает только если supabase_vault в shared_preload_libraries
-- (иначе _PG_init не грузит корневой ключ).
-- Рекомендация: ALTER SYSTEM SET log_statement = 'none', чтобы секреты не утекали в логи.
