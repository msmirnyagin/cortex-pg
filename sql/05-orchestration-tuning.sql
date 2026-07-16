-- 05. Оркестрация, очереди, планирование, тюнинг.
-- Preload: pg_cron, pg_durable (опц. pg_hint_plan). pg_durable ставится ТОЛЬКО в БД 'postgres'.
\echo '== 05 orchestration & tuning =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;        -- cron.schedule(); схема 'cron'
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgmq;           -- pgmq.send/read/archive (чистый SQL, без worker)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pgmq: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_durable;     -- df.start(), ~>, |=>  (только БД postgres)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_durable: %', SQLERRM; END $$;
-- pg_durable: worker-role обязана быть superuser (обходит RLS). Для RAG обязателен
-- build-флаг http-allow-all (иначе egress порезан до Azure-доменов).

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_hint_plan;   -- хинты плана в /*+ ... */; нужен только для hint table
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_hint_plan: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS hypopg;         -- виртуальные (гипотетические) индексы
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'hypopg: %', SQLERRM; END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS index_advisor CASCADE;  -- рекомендация индексов (CASCADE тянет hypopg)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'index_advisor: %', SQLERRM; END $$;

-- Обслуживание pg_cron: ежедневная очистка истории запусков старше 7 дней (best practice).
DO $body$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'cron-job-cleanup',
      '0 3 * * *',
      $cmd$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$cmd$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'cron cleanup schedule: %', SQLERRM;
END $body$;
