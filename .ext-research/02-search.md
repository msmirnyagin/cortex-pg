# Расширения полнотекстового / гибридного поиска для RAG

> Раздел 02. Акцент — полнотекстовый и гибридный (sparse + dense) поиск в RAG/AI-стеке.
> Все имена типов, функций и операторов ниже сверены с официальной документацией (PGroonga reference, ParadeDB docs, postgrespro/rum README). Версии — последние релизы на GitHub на момент составления (2026-07).
> Три расширения в этом разделе: **pgroonga**, **pg_search** (он же ParadeDB BM25), **rum**.

Общее для всех трёх: **ни одно не требует** `shared_preload_libraries` и **все три** требуют `CREATE EXTENSION`. Все три реализуют собственный *индексный метод доступа* (access method), а не фоновый воркер.

---

## 1. PGroonga

**Назначение.** Индексный метод доступа на основе поисковой библиотеки [Groonga](https://groonga.org/), дающий быстрый полнотекстовый поиск в PostgreSQL для **всех языков**, включая CJK (китайский/японский/корейский), где встроенный `tsvector` работает плохо. Поддерживает поиск по запросам (AND/OR/NOT), похожим документам, префиксам, регулярным выражениям и скриптовой Groonga-синтаксис.

### Ключевой SQL API

Установка и индекс:

```sql
CREATE EXTENSION pgroonga;

CREATE INDEX pgroonga_content_idx ON docs
  USING pgroonga (content);          -- текст (text/varchar)

-- с явным opclass v2 (рекомендуется для новых проектов):
CREATE INDEX pgroonga_content_idx ON docs
  USING pgroonga (content pgroonga_text_full_text_search_ops_v2);
```

Операторы поиска (v2 — актуальные; устаревшие `&?`, `&@>` и т.п. не используйте):

| Оператор | Назначение |
| --- | --- |
| `&@` | Полнотекстовый поиск по **одному** ключевому слову |
| `&@~` | Поиск по **запросу** (query-синтаксис как в веб-поиске: `a b`, `a OR b`, `a -b`) |
| `&@*` | Поиск **похожих** документов (similar search) |
| <code>&`</code> | Поиск по **скрипту** Groonga (полная мощь: FTS + диапазоны + условия) |
| `&@|` | Поиск по **массиву ключевых слов** (совпадение по любому) |
| `&@~|` | Поиск по **массиву запросов** (совпадение по любому) |
| `&^` | **Префиксный** поиск |
| `&^|` | Префиксный поиск по массиву |
| `&~` | Поиск по **регулярному выражению** (синтаксис Onigmo/Ruby) |

Примеры:

```sql
-- поиск по запросу (AND/OR/NOT)
SELECT id, content FROM docs
WHERE content &@~ 'postgres OR mysql -oracle';

-- релевантность как число
SELECT id, pgroonga_score(docs) AS score
FROM docs
WHERE content &@~ 'hybrid search'
ORDER BY score DESC
LIMIT 10;

-- поиск похожих документов (только в index scan)
SELECT id FROM docs WHERE content &@* 'reference text about RAG';
```

Функции:
- `double precision pgroonga_score(tableoid, ctid)` и `double precision pgroonga_score(record)` — оценка релевантности.
- `pgroonga_highlight_html(text, query)` — подсветка совпадений.
- `pgroonga_query_extract_keywords(query)` — извлечение ключевых слов.
- `pgroonga_match_positions_byte(text, keywords)` / `pgroonga_match_positions_character(...)` — позиции совпадений (для сниппетов).
- `pgroonga_normalize(text)` — нормализация текста.
- `pgroonga_language_model_vectorize(...)` — встроенный хелпер векторизации (в контексте RAG — потенциально полезно, требует настройки плагинов Groonga; **уточнить** доступность в вашей сборке).

Настройка индекса через `WITH`: `tokenizer` (по умолчанию зависит от языка; для японского — `TokenMecab`, иначе биграммы), `normalizer` (`NormalizerAuto`), `token_filters`, `plugins` (для скриптового поиска и семантических плагинов).

### Роль в RAG/AI-стеке

- **Мультиязычный FTS**, в т.ч. для CJK, где `tsvector`/`rum`/`pg_search` слабее — основная ниша PGroonga в стеке.
- Альтернатива/дополнение BM25: даёт sparse-ретривал для **гибридного поиска** совместно с `pgvector`/`pg_turboquant`.
- Подсветка и сниппеты (`pgroonga_highlight_html`, `pgroonga_match_positions_*`) для генерации контекста промпта.

### Требования

- `shared_preload_libraries` — **нет**.
- `CREATE EXTENSION pgroonga` — **да** (в каждой БД).
- Схема по умолчанию — нет выделенной (объекты создаются в текущей схеме, обычно `public`).
- Зависимости — нет (Groonga линкуется статически в пакет/сборку).

### Установка в нашем образе

- **Не входит** в `contrib` и, как правило, **не предустановлено** в базовом `supabase/postgres:17.6.1.148` — **уточнить** в Dockerfile вашего образа.
- Варианты: apt из собственного репозитория Groonga (`packages.groonga.org` / `ppa:groonga/ppa`) либо сборка из исходников (`make USE_PGXS=1`). Для arm64/Ubuntu — apt-пакет `postgresql-17-pgroonga` доступен в репозитории Groonga.

### Версия

- Последний стабильный релиз: **4.0.6** (tag на GitHub `pgroonga/pgroonga`).

---

## 2. pg_search (ParadeDB BM25)

**Назначение.** Полнотекстовый поиск качества Elasticsearch **внутри PostgreSQL** с **BM25-ранжированием**, построенный на Rust-движке [Tantivy](https://github.com/quick-oss/tantivy) через [pgrx](https://github.com/pgcentralfoundation/pgrx). Даёт релевантный поиск, топ-K, токенизаторы/токен-фильтры, агрегаты (фасеты) и джойны — без отдельной поисковой системы.

### Ключевой SQL API

Индексный метод — **`bm25`**. На таблицу допускается **ровно один** BM25-индекс; в нём индексируют все колонки, которые могут участвовать в поиске/сортировке/фильтрации/агрегации.

```sql
-- key_field обязателен: UNIQUE, первая колонка, нетокенизируемая
CREATE INDEX search_idx ON docs
USING bm25 (id, title, content, category, created_at)
WITH (key_field = 'id');
```

Токенизаторы задаются **приведением типа** (кастом) при создании индекса/в запросе:

```sql
CREATE INDEX search_idx ON docs
USING bm25 (id, (content::pdb.icu), category)        -- ICU-токенизатор (мультиязычный)
WITH (key_field = 'id');

-- английский стемминг через simple-токенизатор
CREATE INDEX search_idx ON docs
USING bm25 (id, (content::pdb.simple('stemmer = english')), category)
WITH (key_field = 'id');
```

Операторы поиска (современный SQL-API ParadeDB):

| Оператор | Назначение |
| --- | --- |
| `\|\|\|` | **Match disjunction** (matchAny): документ содержит **хотя бы один** токен из запроса |
| `&&&` | **Match conjunction** (matchAll): документ содержит **все** токены |
| `===` | **Term**: точное совпадение токена (с учётом регистра, без токенизации); `=== ARRAY[...]` — term-set |

Примеры:

```sql
-- любой из токенов
SELECT id, category FROM docs WHERE content ||| 'vector search';

-- все токены
SELECT id FROM docs WHERE content &&& 'vector search';

-- BM25-ранжирование
SELECT id, pdb.score(id) AS score
FROM docs
WHERE content ||| 'hybrid search'
ORDER BY pdb.score(id) DESC, id ASC   -- id как tiebreaker для детерминизма
LIMIT 10;
```

Функции/схемы:
- `pdb.score(<key_field>)` — **BM25-оценка** релевантности.
- Схема **`pdb`**: операторы, `pdb.score(...)`, типы-токенизаторы (`pdb.icu`, `pdb.whitespace`, `pdb.simple`, `pdb.literal`).
- Схема **`paradedb`**: хелперы, напр. `CALL paradedb.create_bm25_test_table(schema_name => 'public', table_name => 'docs', table_type => 'Docs')`.
- (Расширенный query-builder) оператор `@@@` с `paradedb.match(...)`, `paradedb.phrase(...)`, `paradedb.fuzzy(...)` и др. — для сложных булевых/фразовых запросов. Базовые операции перекрыты простыми операторами выше.

Важные нюансы API:
- Только **один** `bm25`-индекс на таблицу. Для смены конфигурации — `DROP INDEX` + пересоздание.
- Для попадания поля в BM25-оценку оно должно быть в индексе.
- Топ-K оптимизация срабатывает, если все колонки `ORDER BY` (включая tiebreaker) проиндексированы.
- `VACUUM` очищает мёртвые строки и освежает скоры.

### Роль в RAG/AI-стеке

- **BM25 sparse-ретривал** для гибридного поиска: текстовая выдача объединяется с dense-векторами (`pgvector`/`pg_turboquant`) через **RRF (Reciprocal Rank Fusion)** — ParadeDB явно документирует RRF-паттерн.
- Ранжирование источников для реранкера/LLM, top-K, фасеты по категориям, фильтрация.
- Мультиязычная токенизация (ICU) и стемминг для предобработки корпуса.

### Требования

- `shared_preload_libraries` — **нет** (в документации по install/indexing/performance упоминаний нет).
- `CREATE EXTENSION pg_search` — **да**; опционально также `paradedb` для хелпер-процедур.
- Схемы: операторы/`score`/токенизаторы — **`pdb`**; хелперы — **`paradedb`**.
- Зависимости — runtime pgrx; на практике рядом ставят `pgvector` для векторов (нативная векторная поддержка в разработке).

### Установка в нашем образе

- **Не входит** в `contrib` и **не предустановлено** в `supabase/postgres:17.6.1.148`.
- Варианты: сборка из исходников на Rust через `cargo pgrx` (в контексте кастомного Dockerfile — скорее всего этот путь), либо готовые пакеты из репозитория/Docker-образа `paradedb/paradedb`. Требует PostgreSQL 15+.
- **Уточнить**: точный способ установки в вашем `task.md`/Dockerfile.

### Версия

- Последний стабильный релиз репозитория `paradedb/paradedb`: **v0.24.3** (расширение `pg_search`). Образ `latest` официально поставляется с PostgreSQL 18.

---

## 3. RUM

**Назначение.** Индексный метод доступа, наследник **GIN**, оптимизированный под полнотекстовый поиск по `tsvector`: хранит **позиционную и дополнительную информацию** в дереве постингов, что даёт быстрое ранжирование, фразовый поиск и упорядочивание по timestamp **без обращения к таблице (heap scan)**.

### Ключевой SQL API

```sql
CREATE EXTENSION rum;

CREATE INDEX rum_idx ON docs
  USING rum (fts rum_tsvector_ops);     -- fts : tsvector
```

Классы операторов (основные):

| Класс | Тип | Назначение |
| --- | --- | --- |
| `rum_tsvector_ops` | `tsvector` | Лексемы + позиции; поддерживает `<=>` (ранжирование) и prefix-поиск |
| `rum_tsvector_hash_ops` | `tsvector` | Хэш лексем + позиции; поддерживает `<=>`, **без** prefix-поиска |
| `rum_tsvector_addon_ops` | `tsvector` | Лексемы + произвольное доп. поле (напр. `timestamp`) через `WITH (attach=..., to=...)` |
| `rum_tsvector_hash_addon_ops` | `tsvector` | То же с хэшем; без prefix |
| `rum_tsquery_ops` | `tsquery` | Хранит дерево запроса (обратный поиск: «какие запросы матчат документ») |
| `rum_anyarray_ops` | `anyarray` | Элементы массива + длина; `&&`, `@>`, `<@`, `=`, `%`, `<=>` |
| `rum_TYPE_ops` | int/float/money/oid/time/date/... | Упорядочивание `<=>`, `<=|`, `\|=>` |

Операторы:

| Оператор | Возвращает | Назначение |
| --- | --- | --- |
| `tsvector <=> tsquery` | `float4` | «Дистанция»/ранг для упорядочивания по релевантности |
| `timestamp <=> timestamp` | `float8` | Дистанция между timestamp (для recency-сортировки) |
| `<=|`, `\|=>` | `float8` | Односторонняя дистанция (только левое / только правое значение) |
| `@@` | `bool` | Совпадение (наследие GIN): `tsvector @@ tsquery` |

Пример (ранжирование + top-N, индекс отдаёт результат сразу):

```sql
SELECT t, a <=> to_tsquery('english', 'beautiful | place') AS rank
FROM test_rum
WHERE a @@ to_tsquery('english', 'beautiful | place')
ORDER BY a <=> to_tsquery('english', 'beautiful | place')
LIMIT 10;
```

Addon-индекс для упорядочивания по recency (без heap scan):

```sql
CREATE TABLE tsts (id int, t tsvector, d timestamp);
CREATE INDEX tsts_idx ON tsts
  USING rum (t rum_tsvector_addon_ops, d)
  WITH (attach = 'd', to = 't');

-- ORDER BY по d идёт прямо из индекса
SELECT id, d, d <=> '2016-05-16 14:21:25'
FROM tsts
WHERE t @@ 'wr&qh'
ORDER BY d <=> '2016-05-16 14:21:25'
LIMIT 5;
```

Функции интроспекции страниц: `rum_metapage_info(rel, blk)`, `rum_page_opaque_info(...)`, `rum_internal_entry_page_items(...)`, `rum_leaf_entry_page_items(...)`, `rum_internal_data_page_items(...)`, `rum_leaf_data_page_items(...)`.

### Чем RUM лучше GIN для `tsvector` и ранжирования

- **Быстрее ранжирование**: GIN не хранит позиции, поэтому для `ts_rank` нужен heap scan за позициями; RUM хранит позиции в индексе — ранг считается без обращения к таблице.
- **Быстрее фразовый поиск** (`phraseto_tsquery`) — нужны позиции, они уже в индексе.
- **Быстрее упорядочивание по timestamp/recency** — доп. поле хранится рядом с лексемами, heap scan не нужен.
- **Top-N сразу**: поддержка depth-first обхода позволяет отдавать первые результаты немедленно.
- **Цена**: медленнее вставка/построение, чем у GIN (больше данных + generic WAL). Для read-heavy RAG-нагрузки это обычно оправдано.

### Роль в RAG/AI-стек

- Lexeme-based ретривал поверх `tsvector` с **ранжированием без heap scan** — быстрая sparse-составляющая гибридного поиска.
- Сортировка выдачи по **recency** (`rum_tsvector_addon_ops` + timestamp) — свежесть источников для RAG.
- Когда нужен «честный» PostgreSQL-FTS (без внешнего движка) с хорошим ранжированием — альтернатива BM25/PGroonga.

### Требования

- `shared_preload_libraries` — **нет**.
- `CREATE EXTENSION rum` — **да**.
- Схема по умолчанию — нет выделенной (объекты в текущей схеме, обычно `public`).
- Зависимости — нет (PostgreSQL 12+).

### Установка в нашем образе

- **Не входит** в `contrib` и, как правило, **не предустановлено** в `supabase/postgres:17.6.1.148` — **уточнить** в Dockerfile.
- Варианты: сборка из исходников (`make USE_PGXS=1` из `postgrespro/rum`), установка через **PGXN** (`USE_PGXS=1 pgxn install rum`) или apt-пакеты из репозитория Postgres Professional. Для arm64/Ubuntu — вероятнее всего исходники через PGXS.

### Версия

- Последний стабильный релиз: **1.3.15** (tag на GitHub `postgrespro/rum`).

---

## Краткая сравнительная сводка

| | PGroonga | pg_search (ParadeDB) | RUM |
| --- | --- | --- | --- |
| Метод доступа | `pgroonga` | `bm25` | `rum` |
| Движок | Groonga (C) | Tantivy (Rust, pgrx) | ядро GIN (C) |
| Ранжирование | `pgroonga_score()` | **BM25** (`pdb.score()`) | `<=>` (дистанция tsvector/tsquery) |
| Основной поиск | `&@~` (query), `&@`, `&@*` | `\|\|\|`, `&&&`, `===` | `@@` + `ORDER BY ... <=>` |
| Мультиязычность | **сильная** (CJK) | ICU-токенизатор | встроенные словари PG |
| `shared_preload_libraries` | нет | нет | нет |
| `CREATE EXTENSION` | да (`pgroonga`) | да (`pg_search`, `paradedb`) | да (`rum`) |
| Версия | 4.0.6 | v0.24.3 | 1.3.15 |

### Замечания и «уточнить»

- **Предзагрузка**: ни одно из расширений не требует `shared_preload_libraries` — это упрощает встраивание в `supabase/postgres` (где слот часто занят другими модулями).
- **Конфликты**: у `pg_search` лимит **один bm25-индекс на таблицу**; PGroonga и RUM можно совмещать на разных колонках/таблицах. Использовать несколько FTS-методов на одной колонке бессмысленно — выбирайте по задаче (CJK/мультиязык → PGroonga; BM25-релевантность + RRF → pg_search; классический `tsvector` с быстрым ранжированием → RUM).
- **Уточнить в Dockerfile**: подтверждён ли факт отсутствия этих расширений в базовом образе и выбранный способ установки (apt vs PGXS vs cargo pgrx) для `task.md`.
- **pg_search**: нативная векторная поддержка внутри bm25-индекса пока в разработке — до неё векторы берутся через `pgvector`.
- **PGroonga**: доступность `pgroonga_language_model_vectorize` и плагинов зависит от сборки Groonga — проверить наличие плагинов в вашем пакете.
