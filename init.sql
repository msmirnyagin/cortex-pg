-- cortex-pg: мастер-инициализация расширений RAG/AI-стека.
-- Источник истины по составу/API: .ext-research/00-catalog.md
--
-- Запускается docker-entrypoint-initdb.d при первом старте (POSTGRES_DB=postgres).
-- Порядок важен из-за зависимостей:
--   01 vectors        — pg_turboquant требует 'vector' ПЕРВЫМ
--   02 security       — supabase_vault CASCADE тянет pgsodium
--   05 orchestration  — index_advisor CASCADE тянет hypopg
-- Каждое CREATE EXTENSION обёрнуто в DO/EXCEPTION → NOTICE: отсутствующее
-- (не собранное из исходников) расширение не прерывает инициализацию.
--
-- Требуется в shared_preload_libraries (настраивается в образе):
--   pg_cron, pg_durable, pg_net, pgsodium   (опц. pg_hint_plan, pg_stat_statements)

\set ON_ERROR_STOP off
\ir sql/00-base.sql
\ir sql/01-vectors.sql
\ir sql/02-validation-security.sql
\ir sql/03-search.sql
\ir sql/04-graph-api-net.sql
\ir sql/05-orchestration-tuning.sql
\ir sql/06-lang-ai.sql
\ir sql/99-verify.sql
