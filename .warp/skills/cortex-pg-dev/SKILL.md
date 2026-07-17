---
name: cortex-pg-dev
description: Помощь разработчику cortex-pg (PostgreSQL 17 Docker-образ для AI-agent памяти: vector+graph+FTS+security+orchestration). Используй когда: добавляешь/обновляешь расширение, чинишь сборку, разбираешься с vault/pgsodium/крипто, собираешь под arm64, правишь CI/теги, тюнишь tier-конфиги.
---

# cortex-pg — development skill

**Что это:** справка и готовые решения для разработки Docker-образа `cortex-pg`
(PostgreSQL 17 + ~20 расширений RAG/AI-стека). База образа — `postgres:17-bookworm`
(НЕ supabase, несмотря на то что часть расширений из репозиториев Supabase).

**Ленивое раскрытие:** этот файл — только диспетчер. НЕ читай все разделы сразу.
Найди свой сценарий ниже и **прочитай ровно один** файл раздела по ссылке.
Каждый раздел самодостаточен.

## Карта: какой раздел читать

| Ситуация / задача | Прочитай файл |
|---|---|
| Хочу общую карту стека: какие расширения, зачем, preload/create-ext, откуда ставятся | `extensions-overview.md` |
| Добавляю НОВОЕ расширение — как определить метод установки (pgrx? C/PGXS? .deb? apt?) | `adding-extension.md` |
| Собираю pgrx/Rust-расширение (pg_jsonschema, pg_graphql, pg_durable) — пиннинг cargo-pgrx, ошибки совместимости | `pgrx-builds.md` |
| Проблема с vault/pgsodium: FATAL root key, шифрование не работает, preload, формат ключа | `vault-pgsodium.md` |
| Грабли сборки: pgmq Makefile, uuid-ossp, pg_turboquant требует vector, PostGIS GDAL | `build-gotchas.md` |
| Multi-arch: amd64 + arm64, TARGETARCH, нативные раннеры, imagetools manifest | `multiarch.md` |
| CI падает на тегах / metadata-action / 503 Unicorn — API-free генерация тегов | `ci-tags.md` |
| Tier-конфиги (min/max), shared_preload_libraries, ресурсы под 1GB/2GB VPS | `tier-config.md` |

## Как пользоваться

1. Определи свой сценарий по таблице выше.
2. Прочитай **только** соответствующий `.md` файл (он рядом с этим `SKILL.md`).
3. В разделе могут быть ссылки на `.ext-research/` (детальные заметки по API каждого расширения) —
   открывай их только если нужен глубокий справочник по функциям/типам конкретного расширения.

## Сводка версий (проверено 2026-07-17)

> Это только ориентир. **Всегда сверяй свежую версию в интернете** (GitHub Releases / crates.io / PGDG)
> перед обновлением — см. процедуру в `adding-extension.md`.

| Компонент | В образе | Latest upstream | Заметка |
|---|---|---|---|
| pgvector | v0.8.1 | v0.8.1 | актуально; пин ради ABI pg_turboquant |
| pg_search (ParadeDB) | v0.24.1 | v0.24.3 | есть дрейф; .deb есть под amd64+arm64 |
| pg_durable (Microsoft) | v0.2.2 | v0.2.4 | дрейф; v0.2.4 чинит баг #266 (background worker + Unix socket) |
| cargo-pgrx | 0.16.1 | 0.19.1 | пин ОБЯЗАТЕЛЕН (0.19.x несовместим с lib 0.16.x) |
| supabase_vault | v0.3.1 | ~v0.3.x | C/PGXS, самодостаточен (без pgsodium) |

## Источники правды в репозитории

- `Dockerfile` — фактическая сборка (методы установки верифицированы по Cargo.toml/Makefile).
- `init.sql` + `sql/00..99` — порядок создания расширений (по зависимостям).
- `config/postgresql-{min,max}.conf` — tier-профили + `shared_preload_libraries`.
- `.ext-research/00-catalog.md` (+ `01..06`) — детальный справочник по API/типам всех ~20 расширений.
- `.github/workflows/build.yml` — multi-arch CI + генерация тегов.
