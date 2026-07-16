# Справочник расширений: графы, GraphQL и HTTP из SQL

> Раздел `03-graph-api-net.md`. Источники — официальные README и SQL-исходники на GitHub
> (apache/age, supabase/pg_graphql, supabase/pg_net, pramsey/pgsql-http), актуально на дату составления.
> Базовый образ: `supabase/postgres:17.6.1.148` (PG 17, arm64).

---

## 1. Apache AGE

**Репозиторий:** https://github.com/apache/age · **Лицензия:** Apache-2.0

### Назначение
Расширение, превращающее PostgreSQL в мульти-модельную (реляционную + графовую) СУБД.
Поверх обычного SQL добавляет язык графовых запросов **openCypher**. Акроним AGE = «A Graph Extension»,
проект вдохновлён AgensGraph от Bitnine.

### Ключевой SQL API
Все объекты устанавливаются в схему **`ag_catalog`**. Базовый тип данных графа — **`agtype`**
(расширение jsonb-подобного типа для вершин, рёбер и путей).

Управление графами/метками (функции `ag_catalog`):
- `create_graph(graph_name name)` — создаёт граф (и одноимённую схему).
- `drop_graph(graph_name name, cascade boolean)` — удаляет граф.
- `create_vlabel(graph_name, label_name)` / `create_elabel(graph_name, label_name)` — метки вершин/рёбер.
- `drop_label(graph_name, label_name, force)` — удаление метки.
- `alter_graph(graph_name, operation, new_name)`.
- `load_labels_from_file(...)` / `load_edges_from_file(...)` — импорт CSV.

Точка входа для запросов — SQL-функция **`cypher(...)`**, возвращающая `setof record` (алиасы столбцов нужно
задавать явно с типом `agtype`):

```sql
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

SELECT create_graph('rag_kg');

SELECT * FROM cypher('rag_kg', $$
    CREATE (:Entity {name: 'PostgreSQL', kind: 'technology'})
$$) AS (v agtype);

SELECT * FROM cypher('rag_kg', $$
    MATCH (a:Entity {name: 'PostgreSQL'}), (b:Entity {name: 'AGE'})
    CREATE (a)-[:HAS_EXTENSION]->(b)
$$) AS (e agtype);

SELECT * FROM cypher('rag_kg', $$
    MATCH (a:Entity)-[:HAS_EXTENSION]->(b:Entity)
    RETURN a.name, b.name
$$) AS (a_name agtype, b_name agtype);
```

Операторы доступа к полям `agtype`: `->`, `->>`, `#>>` (jsonb-совместимые). Поддерживаются
property indexes на вершинах и рёбрах, иерархия меток (label inheritance), переменные пути (VLE).

### Роль в RAG/AI-стеке
**Граф знаний (Knowledge Graph) для RAG.** Сущности и отношения (извлечённые из документов LLM/NER)
хранятся как вершины и рёбра. Cypher-запросы дают multi-hop рассуждения и контекстный графовый поиск,
который дополняет векторный поиск `pgvector`/`pg_turboquant`. Гибридные SQL+Cypher запросы позволяют
сводить граф и реляционные таблицы в одном `SELECT`.

### Требования
- **shared_preload_libraries:** **НЕТ** (не требуется). Расширение подключается через `LOAD 'age'` в сессии;
  при желании можно добавить `age` в `shared_preload_libraries`, чтобы загружалось автоматически, но это необязательно.
- **CREATE EXTENSION:** **ДА** — `CREATE EXTENSION age;`
- **Дополнительно в сессии:** `LOAD 'age';` и `SET search_path = ag_catalog, "$user", public;`.
- **Схема по умолчанию:** `ag_catalog`.
- **Зависимости от других расширений:** нет.
- **Важно:** схему `ag_catalog` нельзя создавать заранее из-под другой роли — `CREATE EXTENSION age`
  откажется работать, если `ag_catalog` уже существует и принадлежит не инсталлятору (см. примечание в README).

### Установка в нашем образе
**Собираем из исходников.** AGE не входит в contrib и не предустановлено в supabase/postgres.
Клонируем репозиторий, переключаемся на ветку/релиз под нужную версию PG и выполняем
`make PG_CONFIG=/path/to/pg_config install`. Для PG 17 использовать ветку `PG17` или релизную ветку
(см. ниже). После сборки `CREATE EXTENSION age;` в целевой БД.

### Версия
AGE поддерживает PostgreSQL 11–18. Релизы ведутся **отдельными ветками под каждую мажорную версию PG**.
Для **PostgreSQL 17** актуальные стабильные релизы:
- `release/PG17/1.6.0`
- `release/PG17/1.7.0` ← последний стабильный для PG 17.

На `master` бейдж показывает **v1.8.0**, но это ветки PG18/PG19 (`release/PG18/1.8.0`, `release/PG19/1.8.0`).
**Для нашего образа (PG 17) следует брать `release/PG17/1.7.0`.**

---

## 2. pg_graphql

**Репозиторий:** https://github.com/supabase/pg_graphql · **Лицензия:** Apache-2.0

### Назначение
Расширение, которое **автоматически строит GraphQL-схему поверх существующей SQL-схемы** и выполняет
GraphQL-запросы прямо на сервере БД — без отдельных сервисов, процессов или библиотек. Требует PostgreSQL 14+.

### Ключевой SQL API
Публичный SQL-интерфейс — единственная функция-резолвер. Вся остальная «механика» живёт в приватной схеме `graphql`.

**Функция резолвера:**
```sql
graphql.resolve(
    query        text,                              -- GraphQL query/mutation
    variables    jsonb  DEFAULT '{}'::jsonb,
    "operationName" text DEFAULT null,
    extensions   jsonb  DEFAULT null
) RETURNS jsonb
```
Возвращает JSONB вида `{"data": {...}, "errors": [...]}`.

**В базовом образе supabase/postgres** поверх неё дополнительно создан публичный security-definer-варпер в схеме **`graphql_public`**:
```sql
graphql_public.graphql(query text, variables jsonb, "operationName" text, extensions jsonb)
```
Именно `graphql_public.graphql(...)` — стандартная точка входа для внешних GraphQL-клиентов (через PostgREST/Supabase API).

Пример прямого вызова из SQL:
```sql
SELECT graphql.resolve($$
query {
  bookCollection {
    edges { node { id title } }
  }
}
$$);
-- => {"data": {"bookCollection": {"edges": [{"node": {"id": 1, "title": "book 1"}}]}}, "errors": []}
```

**Директивы конфигурации** задаются через `COMMENT` на SQL-сущностях (формат `@graphql(<JSON>)`):
```sql
COMMENT ON SCHEMA public IS e'@graphql({"inflect_names": true, "max_rows": 100, "introspection": true})';
COMMENT ON TABLE  book_post IS e'@graphql({"max_rows": 20})';
COMMENT ON COLUMN account.name IS '@graphql.name: myField';
```
- `inflect_names` — snake_case → PascalCase (типы) / camelCase (поля).
- `max_rows` — размер страницы коллекции (по умолчанию 30).
- `introspection` — включение GraphQL-интроспекции (`__schema`/`__type`; по умолчанию выключена).
- Вспомогательные функции: `graphql.comment_directive(comment text) RETURNS jsonb`,
  `graphql.increment_schema_version()`, `graphql.get_schema_version()`.

**Безопасность:** расширение полностью уважает стандартные роли PostgreSQL и **Row Level Security (RLS)** —
видимость таблиц/колонок в GraphQL-схеме определяется правами роли, выполняющей запрос.

### Роль в RAG/AI-стеке
**GraphQL-шлюз над базой знаний** (документы, чанки, эмбеддинги, граф сущностей). Агенты и LLM-приложения
могут единым GraphQL-запросом тянуть связанные сущности, чанки документов и метаданные без ручного
сборки JOIN'ов. Хорошо сочетается с AGE: графовые таблицы тоже отражаются в GraphQL-схему.

### Требования
- **shared_preload_libraries:** **НЕТ**.
- **CREATE EXTENSION:** **ДА** — `CREATE EXTENSION pg_graphql;`
- **Схема по умолчанию:** `graphql` (внутренняя, приватная). Публичный API — в `graphql_public` (создаётся
  инициализацией образа supabase).
- **Зависимости от других расширений:** нет. Уважает RLS и гранты ролей.

### Установка в нашем образе
**Предустановлено в supabase/postgres** (входит в набор расширений базового образа).
Достаточно `CREATE EXTENSION IF NOT EXISTS pg_graphql;` в нужной БД.

### Версия
Последний стабильный релиз — **v1.6.1** (релиз от 2026-05-07). Требует PostgreSQL 14+.

---

## 3. pg_net

**Репозиторий:** https://github.com/supabase/pg_net · **Лицензия:** Apache-2.0

### Назначение
**Асинхронный (неблокирующий) HTTP/HTTPS-клиент из SQL.** Запрос ставится в очередь и выполняется
фоновым worker'ом (background worker на базе libcurl), а функция немедленно возвращает `request_id`.
Требует PostgreSQL 12+, libcurl >= 7.83.

### Ключевой SQL API
Все объекты — в схеме **`net`**.

Таблицы очереди/ответов (обе `UNLOGGED`):
- `net.http_request_queue` (id, method, url, headers, body, timeout_milliseconds) — очередь запросов.
- `net._http_response` (id, status_code, content_type, headers, content, timed_out, error_msg, created) — ответы.

Функции (каждая возвращает `bigint` — `request_id`):
```sql
net.http_get(
    url                 text,
    params              jsonb DEFAULT '{}'::jsonb,
    headers             jsonb DEFAULT '{}'::jsonb,
    timeout_milliseconds int  DEFAULT 1000
) RETURNS bigint

net.http_post(
    url                 text,
    body                jsonb DEFAULT '{}'::jsonb,
    params              jsonb DEFAULT '{}'::jsonb,
    headers             jsonb DEFAULT '{Content-Type: application/json}'::jsonb,
    timeout_milliseconds int  DEFAULT 1000
) RETURNS bigint

net.http_delete(
    url                 text,
    params              jsonb DEFAULT '{}'::jsonb,
    headers             jsonb DEFAULT '{}'::jsonb,
    timeout_milliseconds int  DEFAULT 2000
) RETURNS bigint
```

Пример — асинхронный вызов embedding-API:
```sql
-- Постановка запроса в очередь (не блокирует транзакцию)
SELECT net.http_post(
    url     := 'https://api.example.com/v1/embeddings',
    body    := '{"input": "текст чанка"}'::jsonb,
    headers := '{"Authorization": "Bearer {{EMBED_API_KEY}}"}'::jsonb
) AS request_id;

-- Забрать ответ позже
SELECT id, status_code, content
FROM net._http_response
WHERE id = <request_id>;
```

Управление worker'ом: `net.worker_restart()`.
Параметры GUC (через `postgresql.conf` / `ALTER SYSTEM` + `pg_reload_conf()`):
- `pg_net.batch_size` (по умолч. 200) — макс. число строк очереди за проход.
- `pg_net.ttl` (по умолч. 6 часов) — время жизни строк в `_http_response`.
- `pg_net.database_name` (по умолч. `'postgres'`) — **важно**: worker привязан к одной БД на кластер.
- `pg_net.username` (по умолч. NULL → bootstrap-пользователь).

### Роль в RAG/AI-стеке
**Fire-and-forget HTTP из триггеров и cron-задач:** вебхуки, уведомления, фоновые вызовы
внешних embedding/rerank/LLM API без блокировки транзакции. Отлично сочетается с **pg_cron**
(расписание) и **pgmq** (очереди). На pg_net, в частности, построена Supabase Webhooks.

### Требования
- **shared_preload_libraries:** **ДА** — обязательно `'pg_net'` (иначе фоновый worker не стартует).
- **CREATE EXTENSION:** **ДА** — `CREATE EXTENSION pg_net;`
- **Схема по умолчанию:** `net`.
- **Ограничение:** один worker на кластер, привязан к `pg_net.database_name` — **одновременно на нескольких
  БД кластера не работает**. Если основная БД не `postgres`, задайте `pg_net.database_name = '<dbname>';`.
- **Зависимости:** libcurl >= 7.83 (системная библиотека).
- Прямая вставка в `net.http_request_queue` **не** обрабатывается worker'ом — обязательно вызывать функции.

### Установка в нашем образе
**Предустановлено в supabase/postgres.** Требуется лишь прописать `shared_preload_libraries = '...,pg_net'`
и при необходимости `pg_net.database_name`. `CREATE EXTENSION pg_net;` в целевой БД.

### Версия
Последний стабильный релиз — **v0.20.5** (от 2026-07-09).

---

## 4. http (pgsql-http)

**Репозиторий:** https://github.com/pramsey/pgsql-http · **Лицензия:** MIT

### Назначение
**Синхронный (блокирующий) HTTP-клиент из SQL** на базе libcurl. В отличие от pg_net, вызов
выполняется сразу и возвращает полный ответ в той же транзакции. Удобен, когда результат нужен
«здесь и сейчас» (inline), но блокирует запрос до завершения HTTP-вызова.

### Ключевой SQL API
Объекты создаются в схеме **`public`**.

Составные типы:
- `public.http_method` (enum) — `GET, POST, PUT, PATCH, DELETE, HEAD`.
- `public.http_header` — `(field varchar, value varchar)`.
- `public.http_request` — `(method, uri, headers http_header[], content_type, content)`.
- `public.http_response` — `(status int, content_type, headers http_header[], content varchar)`.

Главная функция + обёртки:
```sql
http(request http_request) RETURNS http_response   -- мастер-функция

http_get(uri varchar)                              RETURNS http_response
http_get(uri varchar, data jsonb)                  RETURNS http_response
http_post(uri varchar, content varchar, content_type varchar) RETURNS http_response
http_post(uri varchar, data jsonb)                 RETURNS http_response
http_put  (uri varchar, content varchar, content_type varchar) RETURNS http_response
http_patch(uri varchar, content varchar, content_type varchar) RETURNS http_response
http_delete(uri varchar, content varchar, content_type varchar) RETURNS http_response
http_head (uri varchar)                            RETURNS http_response
```

Вспомогательные функции:
- `http_header(field, value)` → `http_header`; `http_headers(...)` → `http_header[]`.
- `urlencode(string varchar)` / `urlencode(data jsonb)` → text.
- `text_to_bytea(text)` / `bytea_to_text(bytea)` — для бинарных данных (обычный `varchar::bytea`
  **не работает** на нулевых байтах — нужно именно `text_to_bytea`).
- `http_set_curlopt(curlopt varchar, value varchar)`, `http_reset_curlopt()`, `http_list_curlopt()`.

Пример — синхронный вызов embedding-API с получением результата в том же запросе:
```sql
-- Параметры libcurl можно задать на сессию:
SET http.curlopt_timeout_ms = 5000;

SELECT
    (resp).status,
    (resp).content::jsonb -> 'data' -> 0 -> 'embedding' AS embedding
FROM (
    SELECT http_post(
        'https://api.example.com/v1/embeddings',
        '{"input": "текст чанка"}'::text,
        'application/json'
    ) AS resp
) s;
```

GUC-параметры libcurl задаются через `SET http.<curlopt> = ...` (например `http.curlopt_proxyport`,
`http.curlopt_timeout_ms`, `http.curlopt_tcp_keepalive`, `http.curlopt_useragent`, опции TLS/proxy и т.д.).
Таймаут по умолчанию — 5 секунд; при превышении выбрасывается SQL-ошибка.

### Роль в RAG/AI-стеке
**Синхронные inline-вызовы** embedding/rerank-моделей и LLM API, когда нужен результат прямо в `SELECT`/триггере
(например, сгенерировать вектор и вставить его одной транзакцией). Для фоновых/неблокирующих сценариев
предпочтительнее pg_net. Бинарные ответы (например, изображения) — через `text_to_bytea`.

### Требования
- **shared_preload_libraries:** **НЕТ**.
- **CREATE EXTENSION:** **ДА** — `CREATE EXTENSION http;`
- **Схема по умолчанию:** `public`.
- **Зависимости:** libcurl (системная библиотека + `-dev` заголовки для сборки).
- **Осторожность:** синхронный HTTP — это «footgun»: долгий ответ внешнего сервиса блокирует SQL-вызов.
  Обязательно ставить короткий `http.curlopt_timeout_ms`.

### Установка в нашем образе
В базовый supabase/postgres обычно **не входит**. Способы:
- **apt PGDG:** `apt install postgresql-17-http` (пакет `postgresql-<pg>-http` из apt.postgresql.org).
- **Из исходников:** `make && make install` (нужны `postgresql-server-dev-17` и `libcurl4-openssl-dev`).
После установки — `CREATE EXTENSION http;`.

### Версия
Последний стабильный релиз — **v1.7.2** (от 2026-07-09).

---

## Сводка: pg_net vs http

| Параметр | **pg_net** | **http (pgsql-http)** |
|---|---|---|
| Модель выполнения | Асинхронная (background worker, libcurl) | Синхронная (блокирующая) |
| Результат | `request_id` → ответ позже в `net._http_response` | Полный `http_response` сразу |
| shared_preload_libraries | **ДА** (`pg_net`) | НЕТ |
| Схема | `net` | `public` |
| Методы | GET / POST / DELETE | GET/POST/PUT/PATCH/DELETE/HEAD |
| Тело запроса | JSONB | text (content_type) или JSONB |
| Типичный сценарий RAG | Фоновые embedding/webhooks из триггеров и cron | Inline-вызов embedding/rerank в том же `SELECT` |

**Рекомендация для стека:** держать оба. pg_net — для неблокирующих фоновых операций (pg_cron, триггеры,
вебхуки), http — для случаев, когда результат API нужен синхронно внутри SQL-выражения.

## Сводка по предзагрузке и установке

| Расширение | shared_preload_libraries | CREATE EXTENSION | Схема | Установка в образе | Версия (PG 17) |
|---|---|---|---|---|---|
| Apache AGE | НЕТ (нужен `LOAD 'age'` в сессии) | ДА | `ag_catalog` | Из исходников (`release/PG17/1.7.0`) | 1.7.0 |
| pg_graphql | НЕТ | ДА | `graphql` / `graphql_public` | Предустановлено (supabase) | 1.6.1 |
| pg_net | **ДА** (`pg_net`) | ДА | `net` | Предустановлено (supabase) | 0.20.5 |
| http | НЕТ | ДА | `public` | apt PGDG `postgresql-17-http` или из исходников | 1.7.2 |
