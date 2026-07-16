# Каталог расширений cortex-pg

Единый указатель по всем расширениям RAG/AI-стека. Подробности — в разделах `01–06`. Базовый образ: `supabase/postgres:17.6.1.148` (PG 17, arm64).

> Обозначения столбцов:
> - **preload** — нужно ли добавлять в `shared_preload_libraries`.
> - **CREATE EXT** — нужно ли `CREATE EXTENSION`.
> - **Источник** — откуда берём в нашем образе: **supabase** (предустановлено), **apt** (PGDG), **src** (сборка из исходников), **contrib** (входит в postgresql-contrib), **pip** (Python-пакет).
> - **Версия** — в образе / upstream-стабильная (где применимо).

---

## 1. Векторный поиск и квантование → `01-vectors.md`

| Расширение | Назначение | preload | CREATE EXT | Схема | Источник | Версия |
|---|---|---|---|---|---|---|
| **pgvector** | Хранение и ANN/точный поиск эмбеддингов (HNSW/IVFFlat); типы `vector`/`halfvec`/`bit`/`sparsevec` | нет | да | `public` | supabase | ~v0.8.5 / v0.8.5 |
| **pg_turboquant** | Компактный ANN-индекс `turboquant` (TurboQuant v2 + SIMD) — **альтернатива** HNSW/IVFFlat, требует pgvector первым | нет | да (после `vector`) | `public` | src (PGXS) | 0.1.0 (pre-1.0) |

**Ключевое:** pg_turboquant — это не надстройка над HNSW, а отдельный access method. На одну колонку либо `hnsw`/`ivfflat`, либо `turboquant`. pg_turboquant CI пинит pgvector v0.8.1; проверить совместимость с v0.8.5 из supabase тестами `make installcheck`.

---

## 2. Полнотекстовый / гибридный поиск → `02-search.md`

| Расширение | Назначение | preload | CREATE EXT | Access method | Источник | Версия |
|---|---|---|---|---|---|---|
| **pgroonga** | Мультиязычный FTS (особенно CJK); `&@~` query-поиск, `&@*` similar | нет | да | `pgroonga` | src / apt groonga | 4.0.6 |
| **pg_search** (ParadeDB BM25) | BM25-ранжирование на Tantivy; операторы `\|\|\|`, `&&&`, `===`; `pdb.score()` | нет | да (`pg_search` + опц. `paradedb`) | `bm25` | src (cargo pgrx) / paradedb-образ | v0.24.3 |
| **rum** | GIN-наследник для `tsvector`: ранжирование/фразы/recency **без heap scan** | нет | да | `rum` | src (PGXS) | 1.3.15 |

**Ключевое:** ни одно не требует preload. pg_search — **ровно один** bm25-индекс на таблицу. Ниша: CJK → pgroonga; BM25+RRF для гибрида → pg_search; честный `tsvector` с быстрым ранжированием → rum.

---

## 3. Графы, GraphQL, HTTP из SQL → `03-graph-api-net.md`

| Расширение | Назначение | preload | CREATE EXT | Схема | Источник | Версия |
|---|---|---|---|---|---|---|
| **Apache AGE** | Графовая СУБД поверх PG; openCypher через `cypher()`, тип `agtype` | нет (`LOAD 'age'` в сессии) | да | `ag_catalog` | src (`release/PG17/1.7.0`) | 1.7.0 |
| **pg_graphql** | Авто-генерация GraphQL-схемы из SQL-схемы; `graphql.resolve()` / `graphql_public.graphql()` | нет | да | `graphql` / `graphql_public` | supabase | 1.6.1 |
| **pg_net** | **Асинхронный** HTTP-клиент (background worker); `net.http_get/post/delete`, request_id → ответ позже | **ДА** | да | `net` | supabase | 0.20.5 |
| **http** (pgsql-http) | **Синхронный** HTTP-клиент; `http_get/post/...` → ответ сразу | нет | да | `public` | apt PGDG / src | 1.7.2 |

**Ключевое:** pg_net и http дополняют друг друга (неблокирующий фон vs inline). pg_net: один worker на кластер, привязан к `pg_net.database_name` (по умолчанию `postgres`). AGE: нельзя создать `ag_catalog` заранее из другой роли.

---

## 4. Валидация и безопасность → `04-validation-security.md`

| Расширение | Назначение | preload | CREATE EXT | Схема | Источник | Версия |
|---|---|---|---|---|---|---|
| **pg_jsonschema** | Валидация json/jsonb по JSON Schema | нет | да | `public` | supabase | v0.3.4 |
| **pgcrypto** | Хеши, HMAC, `crypt`/`gen_salt` (bcrypt), PGP-шифрование, armor | нет | да | `public` | contrib (в supabase) | 17.x (contrib) |
| **pgsodium** | libsodium-крипто + Server Key Management + Transparent Column Encryption (TCE) | **ДА** | да | `pgsodium` | supabase | v3.1.11 |
| **vault** (supabase_vault) | Шифрованное хранилище секретов; `vault.secrets` + `vault.decrypted_secrets` | ДА (через pgsodium) | да (`CASCADE`) | `vault` | supabase | v0.3.1 |

**⚠️ Корректировка имени API:** функции валидации называются `json_matches_schema` / `jsonb_matches_schema` (и `_compiled_`-варианты), **не** `jsonschema_matches`. Тип `jsonschema` + `json_matches_compiled_schema` — для повторных проверок (~1.8×).

**Порядок инициализации:** `shared_preload_libraries='pgsodium'` → настроить `pgsodium.getkey_script` → в каждой БД: `pgcrypto`, `pg_jsonschema`, `pgsodium`, `supabase_vault CASCADE`. Отключить `log_statement`, чтобы секреты не утекали в логи.

---

## 5. Оркестрация, очереди, планирование, тюнинг → `05-orchestration-tuning.md`

| Расширение | Назначение | preload | CREATE EXT | Схема | Источник | Версия |
|---|---|---|---|---|---|---|
| **pg_durable** | Durable-оркестратор (Temporal-in-PG); графы шагов, чекпоинты, ретраи; `df.start()`, `~>`, `\|=>` | **ДА** | да (только в БД `postgres`) | `df`, `duroxide` | **src** (`http-allow-all`) | v0.2.3 |
| **pg_cron** | Cron-планировщик (background worker); `cron.schedule()` | **ДА** | да | `cron` | supabase | 1.6.4 / v1.6.7 |
| **pgmq** | SQS-подобная очередь на чистом SQL; `pgmq.send/read/archive` | нет | да | `pgmq` | supabase | 1.5.1 / v1.12.0 |
| **pg_hint_plan** | Ручные хинты плана в `/*+ ... */`; стабилизация планов RAG-запросов | опц. | опц. (только hint table) | `hint_plan` | **src** (`REL17_1_7_1`) | 1.7.1 |
| **hypopg** | Виртуальные индексы для what-if без физического создания | нет | да | `hypopg` | supabase | 1.4.1 / 1.4.3 |
| **index_advisor** | Рекомендация индексов по тексту запроса (требует hypopg) | нет | да (`CASCADE`) | `public` | supabase | 0.2.0 |

**Критичные нюансы:**
- **pg_durable arm64**: официальных arm64-артефактов нет (.deb/Docker — только amd64) → обязательная сборка из исходников. Флаг egress **`http-allow-all`** обязателен для RAG (дефолт `http-allow-azure-domains` режет не-Azure домены). Worker-роль должна быть **superuser** (обходит RLS).
- **pg_durable ставится только в БД `postgres`** (POSTGRES_DB игнорируется).
- pg_cron/pgmq/pg_durable **комплементарны**, не взаимоисключающи: pg_cron = часы, pgmq = входная очередь, pg_durable = надёжное исполнение сложного workflow.
- Минимальный preload: `pg_cron, pg_durable` (+ опц. `pg_hint_plan`). Следить за `max_worker_processes`.
- pg_hint_plan: строго ветка под мажор PG (PG17 → `REL17_1_7_1`), ветка `master` уже под PG20.
- pg_cron single-DB: worker в одной БД (`cron.database_name`); меж-БД → `cron.schedule_in_database()`.

---

## 6. Языки и AI-интеграция → `06-lang-ai.md`

| Компонент | Слой | Назначение | preload | CREATE EXT / pip | Источник | Версия |
|---|---|---|---|---|---|---|
| **plpython3u** | расширение PG (untrusted) | Хранимки на Python 3; `plpy`, `SD`/`GD` | нет | да (`CREATE EXTENSION plpython3u`) | apt PGDG `postgresql-plpython3-17` | 17.x |
| **baml-py** (BoundaryML) | Python-библиотека (НЕ расширение) | Типобезопасные LLM-вызовы из plpython3u; структурированный вывод, retry | нет | `pip install baml-py` | pip | 0.223.0 |

**Ключевое:**
- **BAML — не расширение PG.** В `task.md` фигурирует `pip install baml`; канонический рантайм — **`baml-py`** (импортируется как `baml_py`), а не legacy-пакет `baml` 0.19.1.
- plpython3u — untrusted: только суперпользователь создаёт функции; не давать `CREATE` ролям приложений.
- `libpython3` должна совпадать с Python, куда ставится baml-py (проверить `python3 --version` в образе).
- plpython3u в supabase-базе **обычно не предустановлен** — ставить отдельно.

---

## Сводная карта `shared_preload_libraries`

Обязательные (по сценарию):
```
shared_preload_libraries = 'pg_cron, pg_durable, pg_net, pgsodium'
```
Опционально: `pg_hint_plan` (глобальная активация хинтов).

> Внимание к `max_worker_processes` — pg_cron (в режиме `cron.use_background_workers`) и pg_durable расходуют слоты фоновых воркеров.

## Что НЕ предустановлено в supabase (нужно добавлять вручную)

- **pg_durable** → src, arm64, `http-allow-all`
- **pg_turboquant** → src (PGXS)
- **pg_search** (ParadeDB) → src (cargo pgrx)
- **rum** → src (PGXS)
- **Apache AGE** → src (`release/PG17/1.7.0`)
- **pgroonga** → apt groonga / src
- **http** (pgsql-http) → apt PGDG
- **pg_hint_plan** → src (`REL17_1_7_1`) или apt PGDG
- **plpython3u** → apt PGDG `postgresql-plpython3-17`
- **baml-py** → pip (не расширение)

## Что предустановлено в supabase:17.6.1.148

pgvector, pg_jsonschema, pgcrypto, pgsodium, vault, pg_graphql, pg_net, pg_cron, pgmq, hypopg, index_advisor (+ postgis, timescaledb, rum? — **проверить `SELECT * FROM pg_available_extensions`**).
