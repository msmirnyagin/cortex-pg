<div align="center">

# cortex-pg

**PostgreSQL 17 Docker-образ для памяти AI-агентов:** векторный + графовый + полнотекстовый поиск в одной БД.

Оптимизирован под **слабые amd64 Linux VPS** — те самые за $5, на которых обычный Postgres умирает от OOM.

[![CI](https://github.com/msmirnyagin/cortex-pg/actions/workflows/build.yml/badge.svg)](https://github.com/msmirnyagin/cortex-pg/actions/workflows/build.yml)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-336791?logo=postgresql&logoColor=white)
![Stage](https://img.shields.io/badge/stage-2%20complete%20%E2%9C%93-2ea44f)
![Architecture](https://img.shields.io/badge/arch-amd64%20Linux-blue)

</div>

---

## Что это

`cortex-pg` — это «база данных с суперсилой» для RAG/AI-приложений: PostgreSQL, заранее оснащённый расширениями для эмбеддингов (векторный ANN-поиск), графов знаний (Apache AGE, openCypher), гибридного полнотекстового поиска (BM25, триграммы, CJK) и оркестрации агентов (очереди pgmq, cron). Всё в одном контейнере, с двумя преднастроенными профилями ресурсов под железо разного класса.

### Дизайн-принципы

- **Один контейнер — весь стек памяти агента.** Не нужен внешний векторный-DB, графовый-DB, поисковый движок и брокер очередей.
- **Выживание на слабом сервере.** Жёсткие лимиты RAM, минимум воркеров, обязательный PgBouncer.
- **Отказоустойчивая инициализация.** Каждое `CREATE EXTENSION` обёрнуто в `DO/EXCEPTION` — отсутствующее расширение не роняет старт, а пишет `NOTICE`.
- **Предсказуемая сборка.** База `postgres:17-bookworm` + PGDG apt: собирается в CI за минуты, без хрупкого Nix-наследия.

---

## Состав расширений

### ✅ Stage 1 — установлено и проверено в CI

| Категория | Расширение | Источник | Назначение |
|---|---|---|---|
| **Векторы** | `vector` (pgvector) v0.8.1 | source (пин) | типы `vector`/`halfvec`, индексы hnsw/ivfflat |
| **Векторы** | `pg_turboquant` | source (C) | компактный ANN-индекс (×3–4 меньше HNSW) |
| **Поиск** | `pg_search` *(Stage 2)* | — | BM25 (Tantivy) |
| **Поиск** | `pgroonga` | apt (Groonga) | мультиязычный FTS, особенно CJK |
| **Поиск** | `rum` | apt (PGDG) | tsvector + recency без heap scan |
| **Поиск** | `pg_trgm`, `btree_gin`, `btree_gist` | contrib | триграммы, гибридные индексы |
| **Графы / API** | `age` (Apache AGE) | apt (PGDG) | openCypher через `cypher()`, тип `agtype` |
| **Графы / API** | `pg_graphql` *(Stage 2)* | — | GraphQL-резолвер |
| **Графы / API** | `http` | apt (PGDG) | синхронные HTTP-запросы из SQL |
| **Графы / API** | `pg_net` *(Stage 2)* | — | асинхронные HTTP (webhooks) |
| **Безопасность** | `pgcrypto` | contrib | digest/hmac, bcrypt, PGP |
| **Безопасность** | `pg_jsonschema` *(Stage 2)* | — | `json_matches_schema()` |
| **Безопасность** | `pgsodium`, `supabase_vault` *(Stage 2)* | — | TCE-шифрование, vault секретов |
| **Оркестрация** | `pg_cron` | apt (PGDG) | cron-задачи внутри БД |
| **Оркестрация** | `pg_durable` | .deb (Microsoft) | durable-функции/агенты |
| **Оркестрация** | `pgmq` *(Stage 2)* | — | SQL-очередь (брокер для агентов) |
| **Оркестрация** | `pg_hint_plan` | apt (PGDG) | хинты плана запроса |
| **Оркестрация** | `hypopg`, `index_advisor` *(Stage 2)* | apt/— | виртуальные индексы, советник |
| **Языки** | `plpython3u` | apt (Debian) | Python в БД + `baml-py` |

### Источники установки

Все расширения установлены. По способу установки: `.deb` (pg_durable, pg_search), apt/PGDG (age, pg_cron, hypopg, http, pg_hint_plan, rum), apt/Groonga (pgroonga), source C/PGXS (pgvector, pg_turboquant, pg_net, pgsodium, supabase_vault), SQL/PGXS (pgmq, index_advisor), pgrx/Rust (pg_jsonschema, pg_graphql), pip (baml-py).

> **pgsodium:** для работы TCE/vault требует корневой ключ. Образ содержит getkey-скрипт, который генерирует ключ при первом старте и хранит его в PGDATA (`$PGDATA/pgsodium.key`). Ключ персистентен в рамках одного data-тома — при пересоздании тома генерируется новый.

---

## Тиры серверов

Образ собирается с build-arg `CORTEX_TIER`, который подставляет готовый профиль ресурсов.

| Параметр | Tier 1 `min` (1 ГБ / 1 CPU) | Tier 2 `max` (2 ГБ / 4 CPU) |
|---|---|---|
| `shared_buffers` | 192 МБ | 512 МБ |
| `max_connections` | 12 | 25 |
| Параллелизм | выкл (1 CPU) | 2 воркера на gather |
| `shared_preload_libraries` | `pgsodium` | `pg_cron, pg_durable, pg_search, pgsodium, pg_net` |
| Назначение | эконом-режим, оркестрация в приложении | полный стек |

На обоих tier-ах поверх Postgres **обязательно** поднимается PgBouncer (transaction-mode), чтобы защитить сервер от коннект-штормов агентов.

---

## Быстрый старт

Образ публикуется в GHCR при каждом пуше в `main`:

```bash
docker pull ghcr.io/msmirnyagin/cortex-pg:latest
```

Запуск Tier 2 (по умолчанию):

```bash
docker run -d --name cortex-pg \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD=secret \
  -v cortex-pg-data:/var/lib/postgresql/data \
  ghcr.io/msmirnyagin/cortex-pg:latest
```

При первом старте автоматически выполняются миграции (`init.sql` → `sql/00…99`), создающие все доступные расширения. Список установленных расширений выводится в лог.

> **Теги:** `latest`, `main`, семвер (`v1.0.0`, `1.0`), и `sha-<short>`. Tier выбирается только при сборке (CI `workflow_dispatch` или локально).

---

## Архитектура

```mermaid
flowchart LR
    subgraph Clients["Клиенты (агенты / приложение)"]
        A[Python worker<br/>embedding pipeline]
    end

    subgraph Pool["Слой пулинга"]
        PB["PgBouncer :6432<br/>transaction-mode"]
    end

    subgraph DB["cortex-pg :5432"]
        PG["PostgreSQL 17<br/>shared_preload: pg_cron, pg_durable"]
        PG --> V["pgvector + turboquant<br/>векторный ANN"]
        PG --> G["Apache AGE<br/>графы / cypher"]
        PG --> S["pgroonga + rum<br/>гибридный FTS"]
        PG --> Q["pgmq / pg_durable<br/>очереди / агенты"]
    end

    A --> PB --> PG
    A -.->|httpx + tenacity<br/>внешние эмбеддинги| EXT["LLM / embedding API"]
```

**Ключевые архитектурные решения:**

- **PgBouncer как обязательный sidecar.** Соединения пулируются в transaction-mode (8 коннектов на БД + резерв). Сами миграции и `SET`/prepared statements между транзакциями не держатся.
- **Очереди = pgmq (SQL-only).** Нет отдельного брокера; сложный retry/branching живёт в Python-воркере (`httpx` + `tenacity`), а не в БД.
- **Embedding-pipeline — внешний.** pg_net зарезервирован только под webhooks; сами эмбеддинги считает внешний Python-воркер, пишущий векторы обратно через пул.

---

## Структура репозитория

```
cortex-pg/
├── Dockerfile                 # Сборка Stage 1: apt + source + .deb
├── init.sql                   # Оркестратор миграций (порядок по зависимостям)
├── sql/
│   ├── 00-base.sql            # contrib: pgcrypto, pg_trgm, btree_gin/gist...
│   ├── 01-vectors.sql         # vector → pg_turboquant (порядок критичен!)
│   ├── 02-validation-security.sql  # pgsodium, vault, jsonschema
│   ├── 03-search.sql          # pgroonga, pg_search, rum
│   ├── 04-graph-api-net.sql   # age, pg_graphql, pg_net, http
│   ├── 05-orchestration-tuning.sql # pg_cron, pgmq, pg_durable, hint_plan
│   ├── 06-lang-ai.sql         # plpython3u (BAML)
│   └── 99-verify.sql          # отчёт об установленных расширениях
├── config/
│   ├── postgresql-min.conf    # Tier 1 (1 ГБ)
│   ├── postgresql-max.conf    # Tier 2 (2 ГБ)
│   ├── pgbouncer.ini          # конфиг sidecar-пулера
│   └── pgbouncer-userlist.txt # userlist (gitignored — нет секретов)
└── .github/workflows/build.yml
```

---

## Сборка и CI

Сборка идёт на нативном amd64-раннере (`ubuntu-latest`) — без QEMU/Rosetta, что критично для тяжёлых C/Rust-сборок. Триггеры:

- **push в `main`** (при изменении `Dockerfile`, `init.sql`, `sql/`) → тег `latest` + `sha-<short>`
- **тег `v*`** → семверные теги (`v1.0.0`, `1.0`)
- **`workflow_dispatch`** → ручной запуск с выбором tier (`min` / `max`)

Кэш сборки — через GitHub Actions cache (`type=gha`). Авторизация в GHCR — встроенным `GITHUB_TOKEN`, без дополнительных секретов.

Локальная сборка (напр. Tier 1):

```bash
docker build --build-arg CORTEX_TIER=min -t cortex-pg:min .
```

> ⚠️ `pg_durable` распространяется как amd64 `.deb` — локальная сборка на Apple Silicon (arm64) упадёт на этом шаге. Для arm64-дева сборка из исходников будет добавлена позже; production-таргет всё равно amd64.

---

## Roadmap

- [x] **Stage 1** — надёжная база: apt + source + `.deb`, CI зелёный
- [x] **Stage 2** — pgrx/Rust-расширения (pgsodium, vault, pg_jsonschema, pg_graphql) + pg_search/pgmq/pg_net/index_advisor; preload восстановлен
- [ ] **arm64** — source-build `pg_durable`/`pg_search` для локальной разработки на Apple Silicon
- [ ] ** HEALTHCHECK + docker-compose** — готовый compose с PgBouncer sidecar
- [ ] **Тесты** — smoke-тест расширений в CI после сборки

---

## Источники и исследование

Подробный каталог всех ~20 рассматривавшихся расширений (источник установки, preload-требования, версии, дедупликация перекрывающегося функционала) собран в `.ext-research/00-catalog.md` и сопутствующих заметках.
