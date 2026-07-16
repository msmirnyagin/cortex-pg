# Расширения: оркестрация, очереди, планирование и тюнинг (05)

Справочный раздел по расширениям, отвечающим за фоновую оркестрацию рабочих процессов, очереди сообщений, cron-планирование и ручной/автоматический тюнинг планов запросов. Все API-имена взяты из официальных README и исходников (доступ проверен через `curl` на raw.githubusercontent.com). 

Замечание о базовом образе: `supabase/postgres:17.6.1.148` собирается через Nix и уже содержит `pg_cron 1.6.4`, `pgmq 1.5.1`, `hypopg 1.4.1` и `index_advisor 0.2.0` (источник: `nix/ext/versions.json` репозитория `supabase/postgres`). `pg_hint_plan` и `pg_durable` в базовый образ не входят — их нужно добавлять отдельно.

---

## pg_durable

- **Назначение**: Durable-оркестратор рабочих процессов (по сути — Temporal-внутри-Postgres). Определяет многошаговый граф из SQL-шагов, чекпоинтит состояние после каждого шага и автоматически возобновляет выполнение после падения/рестарта сервера или ошибки в шаге. Построен на pgrx поверх библиотек `duroxide` (рантайм оркестрации) и `duroxide-pg` (провайдер состояния в Postgres).
- **Ключевой SQL API**:
  - DSL-операторы: `~>` (последовательное соединение шагов), `|=>` (присвоение имени шагу / fan-out), а также функции `df.if()`, `df.join()`, `df.loop()`.
  - `df.start(graph_sql text)` — запускает durable-функцию, возвращает instance ID.
  - `df.cancel(instance_id)` — отмена экземпляра.
  - `df.grant_usage('role')` — выдача прав роли (CREATE EXTENSION ничего не выдаёт в PUBLIC).
  - Категории/таблицы для мониторинга: `df.instances`, `df.nodes`, `df.vars` (схема `df`); рантайм-состояние лежит в схеме `duroxide` (управляется `duroxide-pg`, трогать напрямую не нужно).
  - Пример из официального README:
    ```sql
    SELECT df.start(
        'SELECT id FROM documents WHERE processed = false LIMIT 100' |=> 'batch'
        ~> 'UPDATE documents SET processed = true WHERE id IN (SELECT id FROM $batch.*)'
    );
    ```
  - HTTP-вызовы: `df.http()` (полный набор GUC/опций уточнить по User Guide — egress управляется feature-флагом сборки, см. ниже).
- **Роль в RAG/AI-стеке**: основная «рабочая лошадка» для пайплайнов эмбеддингов (chunk → вызов embedding-API → upsert в `pgvector`), инкрементального переиндексирования, циклов обогащения/классификации с внешними API иscheduled-обслуживания (bloat-detect → notify → wait → action). Заменяет связку «cron + таблица статусов + воркер с ретраями».
- **Требования**:
  - shared_preload_libraries: **ДА** (регистрирует фоновый worker, выполняющий графы).
  - CREATE EXTENSION: **ДА** (`CREATE EXTENSION pg_durable;`), причём фоновый worker ставит расширение всегда в базу `postgres` (в опубликованном Docker-образе `POSTGRES_DB` игнорируется).
  - Схема по умолчанию: `df` (DSL) + `duroxide` (рантайм-состояние).
  - Зависимости: нет зависимостей от других Postgres-расширений; реализация на Rust/pgrx.
- **Установка в нашем образе**: **только из исходников**. Microsoft публикует `.deb`-пакеты и готовый Docker-образ `ghcr.io/microsoft/pg_durable` только под **amd64**; multi-arch (arm64) ещё не выпущен. Для arm64-образа Cortex собираем из исходников через `cargo-pgrx` с таргетом `pg17`. **Критично — feature-флаг egress**: дефолтный релиз собирается с `http-allow-azure-domains` (egress ограничен Azure-доменами); для неограниченного HTTP нам нужен флаг `http-allow-all`. В `Cargo.toml` доступны: `http-allow-all`, `http-allow-azure-domains`, `http-allow-test-domains` (последний включает azure-домены). Бэкграунд-worker-роль (`pg_durable.worker_role`, по умолчанию `postgres`) **обязана быть superuser** — она обходит RLS для управления чужими экземплярами.
- **Версия**: стабильная **v0.2.3** (релиз 2026-06-17); ветка `main` — PG17/18, статус «Preview». Для PG17 фича `pg17` включена в `default`.

---

## pg_cron

- **Назначение**: cron-планировщик, работающий как фоновый worker внутри Postgres. Выполняет произвольные SQL-команды по стандартному cron-расписанию Викси (поддержка секунд и «последний день месяца» через `$`). Запускает несколько джобов параллельно, но не более одного экземпляра одного и того же джоба одновременно.
- **Ключевой SQL API** (схема `cron`):
  - `cron.schedule(schedule text, command text) → bigint`
  - `cron.schedule(job_name text, schedule text, command text) → bigint`
  - `cron.schedule_in_database(job_name, schedule, command, database, username DEFAULT NULL, active DEFAULT true) → bigint`
  - `cron.unschedule(job_name text) → boolean` / `cron.unschedule(job_id bigint) → boolean`
  - `cron.alter_job(job_id, schedule, command, database, username, active)` — изменение параметров.
  - Таблицы: `cron.job` (определения джобов), `cron.job_run_details` (история запусков: status, return_message, start_time, end_time).
  - Примеры:
    ```sql
    SELECT cron.schedule('nightly-vacuum', '0 10 * * *', 'VACUUM');
    SELECT cron.schedule('run_every_30_seconds', '30 seconds', 'SELECT 1');
    SELECT cron.unschedule('nightly-vacuum');
    ```
  - GUC (в `postgresql.conf`): `cron.database_name` (по умолчанию `postgres` — worker регистрируется только в одной БД), `cron.host`, `cron.use_background_workers`, `cron.timezone`, `cron.max_running_jobs`, `cron.log_run`, `cron.log_statement`, `cron.launch_active_jobs`, `cron.enable_superuser_jobs`.
- **Роль в RAG/AI-стеке**: универсальный шедулер для регулярных задач — ночная очистка `cron.job_run_details`, ротация/сжатие партиций, пересчёт агрегатов для дашбордов, вызов хранимых процедур обслуживания (reindex, vacuum, обновление статистик для планировщика). Используется как «часы» системы.
- **Требования**:
  - shared_preload_libraries: **ДА** (`pg_cron`).
  - CREATE EXTENSION: **ДА** (`CREATE EXTENSION pg_cron;`).
  - Схема по умолчанию: `cron`.
  - Зависимости: нет. Важно: pg_cron устанавливается только в **одну** БД на кластер (`cron.database_name`); для меж-БД задач — `cron.schedule_in_database()`. По умолчанию открывает libpq-соединение к localhost — нужен `trust`/`.pgpass` в `pg_hba.conf`, либо режим `cron.use_background_workers = on`.
- **Установка в нашем образе**: **предустановлено** в supabase (версия 1.6.4 для PG17). В upstream доступно через PGDG apt: `postgresql-17-cron`, либо сборка из исходников.
- **Версия**: предустановлена **1.6.4**; актуальный upstream-стабильный релиз — **v1.6.7**.

---

## pgmq

- **Назначение**: лёгкая очередь сообщений в стиле AWS SQS / RSMQ, реализованная только SQL-объектами. Без фонового worker и без внешних зависимостей. Гарантирует exactly-once доставку в пределах visibility timeout; сообщения остаются в очереди, пока их явно не удалят/архивируют.
- **Ключевой SQL API** (схема `pgmq`):
  - `pgmq.create(queue_name text)` — создаёт очередь (физическая таблица `pgmq.q_<name>`).
  - `pgmq.send(queue_name text, msg jsonb, delay int DEFAULT 0) → bigint` — отправка, возвращает msg_id.
  - `pgmq.send_batch(queue_name text, msgs jsonb[]) → setof bigint`.
  - `pgmq.read(queue_name text, vt int, qty int)` — чтение N сообщений, делает их невидимыми на `vt` секунд.
  - `pgmq.pop(queue_name text)` — прочитать и сразу удалить.
  - `pgmq.archive(queue_name text, msg_id bigint) → boolean` / `pgmq.archive(queue_name, msg_ids bigint[])` — перенос в таблицу архива `pgmq.a_<name>`.
  - `pgmq.delete(queue_name text, msg_id bigint) → boolean` — полное удаление.
  - `pgmq.drop_queue(queue_name text) → boolean`.
  - Дополнительно: FIFO-очереди (message group keys) и topic-based routing с wildcard-паттернами (см. `docs/fifo-queues.md`, `docs/topics.md`).
  - Пример:
    ```sql
    SELECT pgmq.create('embed_jobs');
    SELECT pgmq.send('embed_jobs', '{"doc_id": 42}', 5);   -- задержка 5 сек
    SELECT * FROM pgmq.read('embed_jobs', 30, 10);          -- vt=30с, до 10 штук
    SELECT pgmq.delete('embed_jobs', 1);
    ```
- **Роль в RAG/AI-стеке**: очередь заданий для воркеров эмбеддингов/классификации, развязка «постановщик задачи ↔ фоновый обработчик». Worker читает `pgmq.read()`, вызывает модель, по успеху — `pgmq.archive()`/`pgmq.delete()`, при сбое сообщение снова станет видимым после vt. Хорошо стыкуется с pg_durable для асинхронной очереди на запуск durable-функций.
- **Требования**:
  - shared_preload_libraries: **НЕТ** (чистые SQL-объекты, без фонового worker).
  - CREATE EXTENSION: **ДА** (`CREATE EXTENSION pgmq;`), либо SQL-only установка через `psql -f pgmq-extension/sql/pgmq.sql`.
  - Схема по умолчанию: `pgmq`.
  - Зависимости: нет.
- **Установка в нашем образе**: **предустановлено** в supabase (версия 1.5.1 для PG17). Доступен также готовый Docker-образ `ghcr.io/pgmq/pg17-pgmq`, PGXN, либо сборка из исходников.
- **Версия**: предустановлена **1.5.1**; актуальный upstream-стабильный релиз — **v1.12.0** (обратите внимание: репозиторий мигрировал `tembo-io/pgmq` → `pgmq/pgmq`).

---

## pg_hint_plan

- **Назначение**: ручное управление планом выполнения запроса через «хинты» в SQL-комментариях вида `/*+ ... */`. Позволяет форсировать метод сканирования (`SeqScan`, `IndexScan`, `BitmapScan`), метод соединения (`HashJoin`, `NestLoop`, `MergeJoin`), порядок соединения (`Leading`), число параллельных воркеров (`Parallel`), корректировать оценку строк (`Rows`) и подменять GUC на время планирования (`Set`).
- **Ключевой SQL API**:
  - Синтаксис хинта: блок `/*+ HintName(args) HintName2(args) ... */` непосредственно перед запросом.
  - Пример (форсировать hash join + seq scan):
    ```sql
    /*+
      HashJoin(a b)
      SeqScan(a)
    */
    EXPLAIN SELECT *
      FROM pgbench_branches b
      JOIN pgbench_accounts a ON b.bid = a.bid
      ORDER BY a.aid;
    ```
  - Основные хинты (точный список — `docs/hint_list.md`): `SeqScan(table)`, `TidScan`, `IndexScan(table [index...])`, `IndexOnlyScan`, `BitmapScan`, `NoSeqScan`/`NoIndexScan`/`NoBitmapScan` и т.п., `DisableIndex(table index...)`, `NestLoop`/`HashJoin`/`MergeJoin` (и их `No*`-варианты), `Leading(...)`, `Memoize`/`NoMemoize`, `Rows(tables correction)`, `Parallel(table #workers [soft|hard])`, `Set(GUC value)`.
  - Опциональная **hint table**: вместо комментариев хинты хранятся в таблице `hint_plan.hints`, привязанной по `norm_query_string`. Включается `SET pg_hint_plan.enable_hint_table TO on` после `CREATE EXTENSION`.
  - GUC: `pg_hint_plan.enable_hint` (on/off), `pg_hint_plan.enable_hint_table`, `pg_hint_plan.parse_messages`, `pg_hint_plan.debug_print`.
- **Роль в RAG/AI-стеке**: точечная коррекция планов для тяжёлых запросов по векторам и гибридного поиска, когда cost-based оптимизатор ошибается из-за корреляций колонок или слабой статистики по `vector`/GIN-индексам. Полезно для стабилизации планов на «горячих» путях запросов RAG (ANN + фильтры по метаданным), где нестабильный план критичен для latency.
- **Требования**:
  - shared_preload_libraries: **опционально** (для глобальной активации). Также активируется через `LOAD 'pg_hint_plan';` в сессии или `ALTER USER/DATABASE SET`.
  - CREATE EXTENSION: **опционально** (требуется **только** если используется hint table; для обычных хинтов в комментариях `CREATE EXTENSION` не нужен).
  - Схема по умолчанию: `hint_plan` (при использовании hint table).
  - Зависимости: нет.
- **Установка в нашем образе**: **собираем из исходников** (в supabase не предустановлено). PGDG apt: `postgresql-17-pg-hint-plan`. ВАЖНО: версии строго привязаны к мажору PG — для PG17 нужна ветка `REL17_1.7.x`, для PG18 — `REL18_1.8.x`; ветка `master` (2.0) уже требует PG20.
- **Версия**: для PG17 — **1.7.1** (тег `REL17_1_7_1`). Обязательно использовать соответствующую мажору PG ветку.

---

## hypopg

- **Назначение**: гипотетические (виртуальные) индексы — можно проверить «использовал бы ли Postgres этот индекс» и насколько он улучшит план, **не создавая** его физически (без затрат CPU/диска/WAL). Виртуальные индексы существуют только в текущем бэкенде и видны только в `EXPLAIN` (без `ANALYZE`).
- **Ключевой SQL API**:
  - `hypopg_create_index(create_index_stmt text)` — создаёт виртуальный индекс по обычному `CREATE INDEX ...`.
  - `hypopg_list_indexes()` — список виртуальных индексов в текущем бэкенде.
  - `hypopg()` — детальная информация в формате `pg_index`.
  - `hypopg_drop_index(indexrelid oid)` — удалить один виртуальный индекс.
  - `hypopg_reset()` — удалить все виртуальные индексы в бэкенде.
  - Пример:
    ```sql
    SELECT * FROM hypopg_create_index('CREATE INDEX ON hypo (id)');
    EXPLAIN SELECT * FROM hypo WHERE id = 1;   -- покажет Index Scan по виртуальному индексу
    EXPLAIN ANALYZE SELECT * FROM hypo WHERE id = 1; -- виртуальный индекс НЕ применяется
    ```
- **Роль в RAG/AI-стеке**: быстрый what-if анализ — стоит ли добавлять btree/GIN-индекс на колонку фильтра (например, tenant_id перед векторным поиском), без нагрузки на боевую базу. Является зависимостью для `index_advisor`.
- **Требования**:
  - shared_preload_libraries: **НЕТ**.
  - CREATE EXTENSION: **ДА** (`CREATE EXTENSION hypopg;`).
  - Схема по умолчанию: `hypopg` (функции в публичной, без отдельной схемы).
  - Зависимости: нет; но **index_advisor требует именно hypopg**.
- **Установка в нашем образе**: **предустановлено** в supabase (версия 1.4.1 для PG17). Из исходников: `make && sudo make install`.
- **Версия**: предустановлена **1.4.1**; актуальный upstream-стабильный релиз — **1.4.3**.

---

## index_advisor (Supabase)

- **Назначение**: рекомендация индексов для заданного запроса. По тексту запроса подбирает набор `CREATE INDEX` DDL, минимизирующих cost выполнения, и возвращает cost «до/после».
- **Ключевой SQL API**:
  - `index_advisor(query text) RETURNS TABLE (startup_cost_before jsonb, startup_cost_after jsonb, total_cost_before jsonb, total_cost_after jsonb, index_statements text[], errors text[])`.
  - Поддерживает generic-параметры (`$1`, `$2`), материализованные представления и раскрывает колонки, скрытые за view.
  - Пример:
    ```sql
    CREATE EXTENSION IF NOT EXISTS index_advisor CASCADE;  -- CASCADE тянет hypopg
    SELECT * FROM index_advisor('select id from book where title = $1');
    -- index_statements: {"CREATE INDEX ON public.book USING btree (title)"}
    ```
- **Роль в RAG/AI-стеке**: автоматический советчик по индексам для тяжёлых запросов RAG (фильтры по метаданным, join-ы между таблицами документов и векторов). Позволяет в цикле (например, через pg_cron/pg_durable) собирать медленные запросы и получать готовые DDL-рекомендации.
- **Требования**:
  - shared_preload_libraries: **НЕТ**.
  - CREATE EXTENSION: **ДА** (`CREATE EXTENSION index_advisor;`, рекомендуется с `CASCADE` для подтягивания hypopg).
  - Схема по умолчанию: `public` (функция `index_advisor`).
  - Зависимости: **требует hypopg** (использует виртуальные индексы для оценки).
- **Установка в нашем образе**: **предустановлено** в supabase (версия 0.2.0 для PG17). Из исходников: `git clone supabase/index_advisor && sudo make install` (на машине уже должен стоять hypopg).
- **Версия**: предустановлена **0.2.0** (актуальный стабильный релиз проекта `supabase/index_advisor`).

---

## Сводная таблица требований

| Расширение | shared_preload_libraries | CREATE EXTENSION | Схема | Предустан. в supabase 17 | Версия (в образе / upstream) |
|---|---|---|---|---|---|
| pg_durable | ДА | ДА | `df`, `duroxide` | нет (сборка из исходников, флаг `http-allow-all`) | — / v0.2.3 |
| pg_cron | ДА | ДА | `cron` | да (1.6.4) | 1.6.4 / v1.6.7 |
| pgmq | нет | ДА | `pgmq` | да (1.5.1) | 1.5.1 / v1.12.0 |
| pg_hint_plan | опц. (LOAD/SPC) | опц. (только hint table) | `hint_plan` | нет (сборка из исходников, ветка `REL17_1_7_1`) | — / 1.7.1 |
| hypopg | нет | ДА | `hypopg` (pub funcs) | да (1.4.1) | 1.4.1 / 1.4.3 |
| index_advisor | нет | ДА (CASCADE → hypopg) | `public` | да (0.2.0) | 0.2.0 / 0.2.0 |

---

## Важные замечания и риски

- **pg_durable vs pg_cron/pgmq**: pg_durable перекрывает часть сценариев (многошаговые durable-пайплайны с чекпоинтами и ретраями), но **не заменяет** их полностью: pg_cron — это универсальный cron с cron-синтаксисом и меж-БД планированием, а pgmq — лёгкая очередь для коротких асинхронных задач без фонового worker. Логично использовать их вместе: pg_cron = «часы», pgmq = «входная очередь», pg_durable = «надёжное исполнение сложного workflow».
- **Предзагрузка**: суммарно в `shared_preload_libraries` нужно добавить минимум `pg_cron, pg_durable` (+ опционально `pg_hint_plan` для глобальной активации). Внимание к `max_worker_processes` — у pg_cron в режиме `cron.use_background_workers = on` и у pg_durable (свой worker) расходуются слоты фоновых воркеров.
- **pg_durable arm64**: официальных arm64-артефактов нет — только сборка из исходников через pgrx (Rust nightly). Запланировать долгую сборку в Dockerfile.
- **pg_durable egress**: по умолчанию релиз собран с `http-allow-azure-domains` — внешний HTTP ограничен Azure-доменами; нам обязателен feature-флаг `http-allow-all` (параметры полного GUC-контроля egress уточнить по `USER_GUIDE.md`).
- **pg_hint_plan версионность**: нельзя ставить ветку `master` (2.0 = PG20). Для PG17 — строго `REL17_1_7_1`.
- **pg_cron single-DB**: worker живёт в одной БД (`cron.database_name`); `CREATE EXTENSION pg_cron` выполняется именно в ней, для остальных БД используйте `cron.schedule_in_database()`.
- **pgmq репозиторий**: проект переехал `tembo-io/pgmq` → `pgmq/pgmq`; ссылаться на актуальный репозиторий при обновлении.
- **index_advisor + hypopg**: index_advisor жёстко зависит от hypopg; при `CREATE EXTENSION index_advisor CASCADE` hypopg подтянется автоматически. Если hypopg не установлен — index_advisor работать не будет.
