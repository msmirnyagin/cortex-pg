# Раздел: добавление нового расширения

> Чеклист: КАК определить метод установки расширения и вписать его в сборку.

## Шаг 1. Найди upstream

- GitHub-репозиторий расширения. Проверь: поддерживает ли **PG 17**? Есть ли релизы?
- Сверь **latest версию** в интернете (GitHub Releases / crates.io / PGDG `apt-cache madison <pkg>`).
- Не полагайся на память о версиях.

## Шаг 2. Определи метод установки (в порядке предпочтения)

Осмотри upstream-репозиторий. Проверяй **по наличию файлов**, не по догадкам:

1. **Есть `.deb` на GitHub Releases под обе арх?**
   → Самый лёгкий. Качай через `wget` + `apt-get install ./file.deb`.
   (Пример: `pg_search` — см. `multiarch.md` про `TARGETARCH`.)

2. **Есть пакет в PGDG apt?** (`apt-cache madison postgresql-17-<name>` или поиск на apt.postgresql.org)
   → `postgresql-17-<name>` одной строкой в apt-блоке. (age, pg_cron, hypopg, http, rum, postgis.)

3. **В корне репо есть `Makefile` с `PGXS` / `MODULES` / `EXTENSION`?**
   → source C/PGXS: `git clone ... && make && make install`.
   (pgvector, pg_turboquant, pg_net, supabase_vault, index_advisor.)

4. **Есть `Cargo.toml` с `pgrx` в `[dependencies]`?**
   → pgrx/Rust. Самый тяжёлый путь. Нужен pinned `cargo-pgrx` — см. `pgrx-builds.md`.
   (pg_jsonschema, pg_graphql, pg_durable.)

> **Важно:** `pgsodium` и `supabase_vault` — C/PGXS, **НЕ** pgrx, несмотря на «supabase» в имени.
> Всегда проверяй реальный `Cargo.toml`/`Makefile`, а не угадывай по автору.

## Шаг 3. Выясни preload-требование

- Читай `_PG_init` в исходниках: ищи `process_shared_preload_libraries_in_progress` или
  `IsUnderPostmaster`. Если проверяет preload → **обязательно** в `shared_preload_libraries`.
- Background worker (`RegisterBackgroundWorker`) → почти всегда требует preload.
- Чисто индексный access method → preload НЕ нужен.

## Шаг 4. Зависимости от других расширений

- Проверь поле `requires` в `<name>.control` upstream.
- Пример: `pg_turboquant` → `requires = 'vector'` (создать vector ПЕРВЫМ).
- `supabase_vault` v0.3.1 — `requires` НЕТ (самодостаточен, вопреки ожиданиям).

## Шаг 5. Впиши в сборку

- Добавь шаг в `Dockerfile` в правильном месте: лёгкое (apt/.deb/SQL) → C/PGXS → pgrx (последним).
- Добавь `CREATE EXTENSION` в нужный `sql/NN-*.sql` (соблюдая порядок зависимостей), обёрнутое в `DO/EXCEPTION`.
- При необходимости — в `shared_preload_libraries` обоих tier-конфигов (`config/postgresql-{min,max}.conf`).
- Smoke-тест: добавь имя в список `extname IN (...)` в `build.yml` (порог `>= 9` расширений).

## Шаг 6. Проверь

- Локально: `docker build --build-arg CORTEX_TIER=max -t cortex-pg:test .` затем smoke-контейнер.
- `psql -c "SELECT extname, extversion FROM pg_extension ORDER BY 1;"`.
- Для preload-расширений: убедись, что образ **стартует** без FATAL (preload-библиотеки грузятся до приёма коннектов).
