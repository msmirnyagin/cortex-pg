# Раздел: общая карта стека расширений

> Источник: `Dockerfile` (верифицировано по Cargo.toml/Makefile), `.ext-research/00-catalog.md`.
> База образа: **`postgres:17-bookworm`** (PGDG apt уже подключён).

## Методы установки (по возрастанию тяжести сборки)

| Метод | Расширения | Заметка |
|---|---|---|
| **apt/PGDG** | `age`, `pg_cron`, `hypopg`, `http`, `pg_hint_plan`, `rum`, `plpython3`, `postgis` | `CREATE EXTENSION` срабатывает сразу; самый лёгкий путь |
| **apt/Groonga** | `pgroonga` | нужен apt-repo Groonga (CJK-поиск) |
| **.deb (GitHub Releases)** | `pg_search` (ParadeDB) | параметризован по `TARGETARCH`; amd64+arm64 |
| **source C/PGXS** | `pgvector` v0.8.1, `pg_turboquant`, `pg_net`, `supabase_vault` | `make && make install` |
| **SQL/PGXS** | `pgmq`, `index_advisor` | чистый SQL, компиляции почти нет |
| **pgrx/Rust** | `pg_jsonschema`, `pg_graphql`, `pg_durable` | самый тяжёлый; нужен pinned `cargo-pgrx@0.16.1` |
| **pip** | `baml-py` | для вызова LLM из тел plpython3u |

## preload vs CREATE EXTENSION

| Расширение | preload? | CREATE EXT? | Назначение |
|---|---|---|---|
| `pg_cron` | да | да | cron-задачи в БД |
| `pg_durable` | да | да | durable-функции/агенты |
| `pg_search` | да | да | BM25 (Tantivy) |
| `supabase_vault` | да | да | шифрованные секреты |
| `pg_net` | да | да | асинхронный HTTP (webhooks) |
| `age`, `pg_graphql`, `vector`, `pgmq`... | нет | да | индексные/функциональные |

**Правило:** preload нужен для расширений, запускающих **background worker** или
загружающих состояние при старте сервера (`_PG_init` читает shared preload флаги).
Индексные методы доступа (pgroonga, rum, pg_search-индекс) **не** требуют preload —
но `pg_search` требует, т.к. запускает фоновую переиндексацию.

## Ключевые дедупликации

- **FTS-поиск:** `pgroonga` (CJK, Groonga), `pg_search` (BM25/Tantivy), `rum` (tsvector+recency).
  Три разных движка — не дублируют, а покрывают разные ниши.
- **HTTP из SQL:** `http` (синхронный, apt), `pg_net` (асинхронный, preload). Webhooks → pg_net.
- **Крипто:** `pgcrypto` (contrib, базовая крипто), `supabase_vault` (секреты, libsodium).
  **`pgsodium` убран** (deprecated) — см. `vault-pgsodium.md`.
- **Очереди:** `pgmq` (SQL-only брокер). Дублирует внешние RabbitMQ, но дешевле для агента.

## Порядок создания в init.sql (критично)

`init.sql` → `sql/00-base` → `01-vectors` → `02-validation-security` → `03-search` →
`04-graph-api-net` → `05-orchestration-tuning` → `06-lang-ai` → `99-verify`.

`01-vectors`: `vector` **до** `pg_turboquant` (второй требует первого). Каждое `CREATE EXTENSION`
обёрнуто в `DO/EXCEPTION` — отсутствие не роняет старт.

> Глубокий справочник по API/типам/операторам каждого расширения — в `.ext-research/01..06`.
