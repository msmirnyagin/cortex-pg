# Векторный поиск и квантование: pgvector, pg_turboquant

> Источники: официальные README и docs (`pgvector/pgvector` master, `mayflower/pg_turboquant` main). Имена типов/функций/операторов приведены по документации; где требуется проверка в конкретном образе — помечено «уточнить».

---

## 1. pgvector

**Репозиторий:** https://github.com/pgvector/pgvector

### Назначение
Открытое расширение для поиска ближайших соседей (ANN/exact) по векторам в PostgreSQL. Хранит эмбеддинги рядом с остальными данными, поддерживает точный и приближённый поиск, несколько типов расстояний и компактные форматы (half, binary, sparse).

### Ключевой SQL API

**Типы данных:**
- `vector(n)` — single-precision (float32), до 16 000 измерений в таблице / до 2 000 в индексе. Размер: `4 * dims + 8` байт.
- `halfvec(n)` — half-precision (float16), до 16 000 в таблице / до 4 000 в индексе. Размер: `2 * dims + 8` байт.
- `bit(n)` — бинарные векторы, до 64 000 измерений в индексе.
- `sparsevec(n)` — разреженные векторы, до 1 000 ненулевых элементов. Формат вставки: `'{1:1,3:2,5:3}/5'`.

**Операторы расстояния:**
- `<->` — L2 (евклидово)
- `<#>` — отрицательное скалярное произведение (negative inner product)
- `<=>` — косинусное расстояние
- `<+>` — L1 (манхэттенское/taxicab)
- `<~>` — расстояние Хэмминга (для `bit`)
- `<%>` — расстояние Жаккара (для `bit`)

**Функции:** `l2_distance`, `inner_product`, `cosine_distance`, `l1_distance`, `vector_dims`, `vector_norm`, `l2_normalize`, `subvector`, `binary_quantize` (для vector/halfvec), `hamming_distance`, `jaccard_distance`.

**Агрегаты:** `avg(vector|halfvec)`, `sum(vector|halfvec)`.

**Методы доступа (индексы):** `hnsw` и `ivfflat`.

**Операторные классы:** `vector_l2_ops`, `vector_ip_ops`, `vector_cosine_ops`, `vector_l1_ops`; аналоги `halfvec_*_ops`, `sparsevec_*_ops`; для бинарных — `bit_hamming_ops`, `bit_jaccard_ops`.

**Примеры:**
```sql
CREATE EXTENSION vector;

CREATE TABLE items (id bigserial PRIMARY KEY, embedding vector(3));
INSERT INTO items (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');

-- Точный поиск по L2
SELECT * FROM items ORDER BY embedding <-> '[3,1,2]' LIMIT 5;

-- HNSW-индекс по косинусному расстоянию
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- IVFFlat
CREATE INDEX ON items USING ivfflat (embedding vector_l2_ops) WITH (lists = 100);

-- Настройка качества/скорости запроса
SET hnsw.ef_search = 100;
SET ivfflat.probes = 10;
```

**Бинарное квантование (встроенное в pgvector):**
```sql
CREATE INDEX ON items USING hnsw ((binary_quantize(embedding)::bit(3)) bit_hamming_ops);
```

### Роль в RAG/AI-стеке
Базовый слой хранения и поиска эмбеддингов. На нём строятся: хранение векторов документов/чанков, ANN-поиск релевантного контекста, гибридный поиск (вместе с полнотекстовым `tsvector`), reranking. halfvec и binary quantization используются для уменьшения footprint и ускорения при больших объёмах.

### Требования
- **shared_preload_libraries:** нет (не требуется).
- **CREATE EXTENSION:** да, `CREATE EXTENSION vector;` в каждой БД.
- **Схема по умолчанию:** `public`.
- **Зависимости:** нет (самостоятельное расширение). Индексы HNSW/IVFFlat поставляются вместе с расширением.

### Установка в нашем образе
Предустановлено в базовом образе `supabase/postgres` (pgvector входит в стандартный набор расширений supabase). Альтернативно — apt PGDG (`postgresql-17-pgvector`) или сборка из исходников (`make && make install`). Требуется только `CREATE EXTENSION`.

> Уточнить фактическую версию в образе `supabase/postgres:17.6.1.148`: `SELECT extversion FROM pg_extension WHERE extname='vector';` (актуальный релиз upstream — v0.8.5).

### Версия
**v0.8.5** (актуальный стабильный релиз по README). pg_turboquant в CI пинит контракт к pgvector **v0.8.1** — при обновлении pgvector выше этой версии стоит перепроверить совместимость (см. ниже).

---

## 2. pg_turboquant

**Репозиторий:** https://github.com/mayflower/pg_turboquant

### Назначение
Компактный ANN-индекс для PostgreSQL поверх типов `vector`/`halfvec` из pgvector. Даёт собственный метод доступа `turboquant` с плотным квантованным форматом (TurboQuant v2) и SIMD-скорингом (NEON/AVX2), оптимизированный под компактность и cache-friendly поиск внутри PostgreSQL.

### Ключевой SQL API

**Метод доступа:** `USING turboquant`

**Режимы:** flat-скан (`lists = 0`) и IVF-маршрутизация (`lists > 0`, K-means).

**Операторные классы:**
- Для `vector`: `tq_cosine_ops`, `tq_ip_ops`, `tq_l2_ops`
- Для `halfvec`: `tq_halfvec_cosine_ops`, `tq_halfvec_ip_ops`, `tq_halfvec_l2_ops`
- Фильтры по метаданным (fixed-width): `tq_bool_filter_ops`, `tq_int2_filter_ops`, `tq_int4_filter_ops`, `tq_int8_filter_ops`, `tq_date_filter_ops`, `tq_timestamptz_filter_ops`, `tq_uuid_filter_ops`

**Reloptions индекса:** `bits` (ширина квантования; v2 при `bits=4` хранит 3-битные скалярные коды + 1-битный QJL-скетч), `lists` (0 = flat, >0 = IVF), `transform` (`'hadamard'`), `normalized` (bool — включает code-domain fast path для косинуса/IP).

**Сессионные GUC:** `turboquant.probes`, `turboquant.oversample_factor`, `turboquant.max_visited_codes`, `turboquant.max_visited_pages`, `turboquant.iterative_scan` (`off`/`strict_order`/`relaxed_order`), `turboquant.min_rows_after_filter`, `turboquant.enable_summary_bounds`, `turboquant.decode_rescore_factor`.

**SQL-помощники:** `tq_rerank_candidates(...)`, `tq_approx_candidates(...)`, `tq_recommended_query_knobs(candidate_limit, final_limit)` (возвращает `probes`, `oversample_factor`, `max_visited_codes`, `max_visited_pages`), `tq_bitmap_cosine_filter(...)`, `tq_index_metadata(regclass)`, `tq_index_heap_stats(regclass)`, `tq_maintain_index(regclass)`, `tq_runtime_simd_features()`, `tq_last_scan_stats()`, `tq_smoke()` (smoke-тест установки).

**Примеры:**
```sql
CREATE EXTENSION vector;        -- обязательно ПЕРВЫМ
CREATE EXTENSION pg_turboquant;

CREATE INDEX docs_embedding_tq_idx
ON docs
USING turboquant (embedding tq_cosine_ops)
WITH (bits = 4, lists = 256, transform = 'hadamard', normalized = true);

-- Приближённый поиск с точным rerank на стороне SQL
SELECT *
FROM tq_rerank_candidates(
  'docs'::regclass,
  'id',
  'embedding',
  '[1,0,0,0]'::vector(4),
  'cosine',
  50,   -- candidate limit
  10    -- final limit
);

-- Диагностика последнего скана (ядро скоринга, режим, page pruning)
SELECT tq_last_scan_stats();
```

### Роль в RAG/AI-стеке
Альтернатива HNSW/IVFFlat для больших баз эмбеддингов, где важна компактность индекса (по бенчмаркам README — в 3–4 раза меньше HNSW при сопоставимой/лучшей латентности). Хорош для основного хранилища векторов RAG-чанков при дефиците памяти; точный rerank делается отдельно в SQL через `tq_rerank_candidates`.

### Требования
- **shared_preload_libraries:** нет (обычное C-расширение + `CREATE ACCESS METHOD` через `CREATE EXTENSION`).
- **CREATE EXTENSION:** да, `CREATE EXTENSION pg_turboquant;`, причём **строго после** `CREATE EXTENSION vector;`.
- **Схема по умолчанию:** `public`.
- **Зависимости:** жёсткая зависимость от **pgvector** (нужны типы `vector`/`halfvec`). Контракт CI пинит pgvector к v0.8.1. Расширение помечено `superuser = true`. Поддержка PostgreSQL 16 и 17.
- **Перестройка:** при смене формата (v2) старые индексы надо пересоздать через `REINDEX`.

### Установка в нашем образе
**Собираем из исходников** через PGXS (`./scripts/bootstrap_dev.sh` при необходимости, затем `make && make install`). Требуются dev-заголовки PostgreSQL 17 и `pgvector`, установленный в целевом инстансе. `make install` ставит только `pg_turboquant` — pgvector нужно провижинить отдельно (он уже есть в supabase-базе).

### Версия
**0.1.0** (pre-1.0). On-disk формат может меняться — это событие совместимости, индексы пересоздаются через `REINDEX`.

### Дополнительно: квантование, зависимость от pgvector, совместимость с HNSW/IVFFlat

**Поддерживаемые форматы квантования:**
- Входные типы: `vector` и `halfvec` (из pgvector).
- Внутренний компактный код — **TurboQuant v2**: при `bits = 4` хранит `b - 1` = 3-битные скалярные коды stage-1 + 1-битный остаточный QJL-скетч + сохранённую остаточную норму `gamma`, со структурированным преобразованием Хadamarda. Формат страниц — SoA с 4-битными упакованными dimension-major nibbles для zero-copy SIMD-скоринга (NEON TBL / AVX2 VPSHUFB, аккумулирование в int16 со сбросом в int32, стиль Faiss FastScan).
- **Бинарное квантование в смысле pgvector (`binary_quantize`, 1-бит) расширением НЕ делается.** Это другая схема компрессии. Встроенный pgvector-ный `binary_quantize()` остаётся доступным отдельно.
- Fast path (code-domain) работает только для **нормализованных** косинуса и inner product (`normalized = true`). L2 и ненормализованные метрики уходят в fallback decode-score.

**Зависимость от pgvector:** **да, обязательная.** pg_turboquant — отдельный метод доступа; он использует типы `vector`/`halfvec` от pgvector, но НЕ разделяет его внутренний access-method surface (использует собственные `tq_*` wrapper-функции, а не pgvector-овские имена).

**Совместное использование с HNSW/IVFFlat:** pg_turboquant **не используется вместе** с HNSW/IVFFlat — это **альтернатива**, собственный метод доступа `turboquant`. Внутри него есть свои режимы: flat-скан (`lists = 0`, аналог полного скана) и IVF-маршрутизация (`lists > 0`, K-means + delta-tier для изменчивых данных). На одну колонку создаётся либо `hnsw`/`ivfflat`, либо `turboquant`-индекс. В README pg_turboquant напрямую сравнивается с HNSW и IVFFlat как более компактная альтернатива.

> Замечание: при наличии обоих индексов на разных колонках/таблицах конфликта нет, т.к. это разные access methods. Но pgvector v0.8.5 (вероятная версия в supabase) выше пина CI pg_turboquant (v0.8.1) — перед production стоит прогнать полный набор тестов `make unitcheck && make installcheck && make tapcheck` против фактической связки версий.
