# syntax=docker/dockerfile:1
#
# cortex-pg — PostgreSQL 17 образ для RAG/AI-памяти агентов (векторный + графовый поиск).
# Целевые серверы: слабые amd64 Linux VPS (Tier 1: 1 ГБ/1 CPU; Tier 2: 2 ГБ/4 CPU).
# База: официальный postgres:17-bookworm (репозиторий PGDG уже подключён в образе).
#
# Стратегия (поэтапная):
#   • ЭТАП 1 (этот файл): всё, что ставится надёжно — apt из PGDG + Groonga,
#     сборка из исходников (pgvector v0.8.1, pg_turboquant), .deb (pg_durable),
#     язык plpython3u + pip baml-py.
#   • ЭТАП 2 (отдельный коммит): pgrx/Rust-расширения — pgsodium, supabase_vault,
#     pg_jsonschema, pg_graphql, pg_search, pgmq, pg_net. Сейчас они отсутствуют:
#     миграции обёрнуты в DO/EXCEPTION → NOTICE, поэтому инициализация не падает.
#     ВАЖНО: pgsodium и pg_net УБРАНЫ из shared_preload_libraries до ЭТАПА 2 —
#     иначе postgres не стартует (нет .so). Вернуть после установки pgrx-стека.
#
FROM postgres:17-bookworm

# Тир сервера (min = 1 ГБ, max = 2 ГБ). CI пробрасывает build-arg (см. .github/workflows/build.yml).
ARG CORTEX_TIER=max

# ----------------------------------------------------------------------------
# 1. apt: расширения из PGDG + инструменты сборки (C/PGXS) + python3 для BAML.
#    Имена пакетов сверены с apt.postgresql.org (dists/bookworm-pgdg/main).
# ----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # --- расширения PGDG (CREATE EXTENSION сработает сразу) ---
      # plpython3 — пакет из Debian main (НЕ PGDG), поэтому имя postgresql-plpython3-17,
      # а не postgresql-17-plpython3.
      postgresql-plpython3-17 \
      postgresql-17-age \
      postgresql-17-cron \
      postgresql-17-hypopg \
      postgresql-17-http \
      postgresql-17-pg-hint-plan \
      postgresql-17-rum \
      # --- инструменты для сборки C-расширений (pgvector, pg_turboquant) ---
      build-essential \
      postgresql-server-dev-17 \
      bison \
      flex \
      git \
      wget \
      ca-certificates \
      # --- Python: BAML (baml-py) вызывается из тел функций plpython3u ---
      python3 \
      python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 2. Groonga apt-репозиторий → pgroonga (мультиязычный FTS, особенно CJK).
#    В PGDG pgroonga отсутствует — нужен собственный репозиторий Groonga.
# ----------------------------------------------------------------------------
RUN wget -qO /tmp/groonga.deb https://packages.groonga.org/debian/groonga-apt-source-latest-bookworm.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/groonga.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-17-pgdg-pgroonga \
    && rm -f /tmp/groonga.deb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ----------------------------------------------------------------------------
# 3. pgvector v0.8.1.
#    ВЕРСИЯ ЗАФИКСИРОВАНА: pg_turboquant пинит контракт pgvector на v0.8.1
#    (apt отдал бы свежую — это сломало бы совместимость с turboquant).
# ----------------------------------------------------------------------------
RUN git clone --branch v0.8.1 --depth 1 https://github.com/pgvector/pgvector.git \
    && cd pgvector && make && make install && cd .. && rm -rf pgvector

# ----------------------------------------------------------------------------
# 4. pg_turboquant — компактный ANN-индекс (чистый C/PGXS), требует pgvector.
#    Альтернатива hnsw/ivfflat: индекс меньше в 3-4×, parity/быстрее на IVF.
# ----------------------------------------------------------------------------
RUN git clone https://github.com/mayflower/pg_turboquant.git \
    && cd pg_turboquant && ./scripts/bootstrap_dev.sh && make && make install \
    && cd .. && rm -rf pg_turboquant

# ----------------------------------------------------------------------------
# 5. pg_durable (Microsoft) — готовый amd64 .deb.
#    ⚠️ Только amd64: на arm64-сборке шаг упадёт (нужна сборка из исходников).
#    RAG-egress требует build-флага http-allow-all — проверить отдельно в .deb.
# ----------------------------------------------------------------------------
RUN wget -qO /tmp/pg-durable.deb \
      https://github.com/microsoft/pg_durable/releases/download/v0.2.2/pg-durable-postgresql-17_0.2.2-1_amd64.deb \
    && dpkg -i /tmp/pg-durable.deb \
    && rm -f /tmp/pg-durable.deb

# ----------------------------------------------------------------------------
# 6. BAML (baml-py) — глобально для системного python3 (plpython3u вызывает его).
#    --break-system-packages: обход PEP 668 в Debian 12 (bookworm).
# ----------------------------------------------------------------------------
RUN pip install --break-system-packages --no-cache-dir baml-py

# ----------------------------------------------------------------------------
# 7. Очистка тяжёлых инструментов сборки — компактнее образ для pull на слабый VPS.
#    Установленные .so/.control расширений это не затрагивает (runtime их не требует).
# ----------------------------------------------------------------------------
RUN apt-get purge -y --auto-remove build-essential postgresql-server-dev-17 bison flex \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /
RUN rm -rf /build

# ----------------------------------------------------------------------------
# 8. Профиль конфигурации по тиру (ДОБАВЛЯЕТСЯ к postgresql.conf.sample).
# ----------------------------------------------------------------------------
COPY config/postgresql-${CORTEX_TIER}.conf /tmp/tier.conf
RUN cat /tmp/tier.conf >> /usr/share/postgresql/postgresql.conf.sample && rm /tmp/tier.conf

# ----------------------------------------------------------------------------
# 9. SQL-инициализация: оркестратор init.sql + модульные миграции sql/.
# ----------------------------------------------------------------------------
COPY init.sql /docker-entrypoint-initdb.d/
COPY sql/    /docker-entrypoint-initdb.d/sql/
