# Раздел: грабли сборки

> Конкретные баги/нюансы, на которые реально потратили время в CI.

## 1. pgmq — Makefile переехал в `pgmq-extension/`

В корне репо `tembo-io/pgmq` Makefile **отсутствует** (только Rust-код pgmq-core).
Сборочный Makefile для SQL-расширения лежит в подкаталоге `pgmq-extension/`.

```dockerfile
RUN git clone --depth 1 https://github.com/tembo-io/pgmq.git \
    && cd pgmq/pgmq-extension && make && make install \
    && cd /build && rm -rf pgmq
```

**Симптом ошибки:** `make: *** No rule to make target ... . Stop.` в корне pgmq.
**Фикс:** `cd pgmq/pgmq-extension` перед make.

## 2. uuid-ossp НЕ нужен

Везде используется `gen_random_uuid()` — встроено в ядро PostgreSQL **с PG 13**.
`CREATE EXTENSION "uuid-ossp"` не нужно (он устаревший для генерации UUID).

**Симптом ошибки:** кто-то добавляет `uuid-ossp` — лишний contrib без причины.
**Фикс:** убрать; `gen_random_uuid()` доступна из коробки.

## 3. pg_turboquant требует pgvector

`pg_turboquant.control` → `requires = 'vector'`. Это **единственное** расширение
в образе с такой жёсткой зависимостью.

→ Порядок в `sql/01-vectors.sql`: `CREATE EXTENSION vector` **до** `CREATE EXTENSION pg_turboquant`.
Иначе: `ERROR: required extension "vector" is not installed`.

## 4. PostGIS и `--no-install-recommends`

`postgresql-17-postgis-3` тянет **рекомендуемые** пакеты (GDAL, растры, ~200+ МБ).
Для слабого VPS — критично. Решение: `--no-install-recommends` в apt-блоке отсекает
GDAL/растры (~60 МБ вместо 200+), оставляя нужное для векторных/гибридных индексов.

PostGIS — **opt-in**: пакет в образе, но `CREATE EXTENSION postgis` НЕ в базовом `init.sql`
(только по требованию, в схеме `geo`). Preload НЕ нужен — в простое не ест RAM.

## 5. index_advisor — Makefile в корне

В отличие от pgmq, у `supabase/index_advisor` Makefile **в корне** (с `include $(PGXS)`).
Просто `cd index_advisor && make && make install`.

## 6. pg_jsonschema — правильные имена функций

В заданиях/доках встречается `jsonschema_matches` — **такой функции нет** в актуальной
версии (v0.3.4, master). Реальные имена:
- `json_matches_schema(...)`
- `jsonb_matches_schema(...)`

## 7. Groonga apt-repo — двухфазный install

pgroonga ставится из отдельного apt-repo Groonga (не PGDG). Нужен двухфазный шаг:
1. Скачать `groonga-apt-source-latest-bookworm.deb`, `apt-get install ./...deb`
2. `apt-get update` (подхватить новый repo)
3. `apt-get install postgresql-17-pgdg-pgroonga`

Скип любого шага → `Unable to locate package postgresql-17-pgdg-pgroonga`.

## 8. Очистка vs runtime-libs

После сборки C/pgrx удаляем **dev**-инструменты (build-essential, clang, rust),
НО оставляем runtime-библиотеки: `libsodium23`/`libsodium-dev`, `libcurl4`/`libcurl4-openssl-dev`.
`.so` расширений динамически линкуются к ним. Удаление → FATAL при загрузке расширения.

## 9. plpython3u + baml-py

`baml-py` ставится через pip **глобально** для системного python3:
```
pip install --break-system-packages --no-cache-dir baml-py
```
`--break-system-packages` нужен под bookworm PEP 668. plpython3u вызывает его из тел функций.
