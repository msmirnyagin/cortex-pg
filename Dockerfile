# syntax=docker/dockerfile:1
#
# cortex-pg — PostgreSQL 17 образ для RAG/AI-памяти агентов (векторный + графовый поиск).
# Целевые серверы: слабые amd64 Linux VPS (Tier 1: 1 ГБ/1CPU; Tier 2: 2 ГБ/4CPU).
# База: официальный postgres:17-bookworm (репозиторий PGDG уже подключён в образе).
#
# Полный стек расширений (методы сборки ВЕРИФИЦИРОВАНЫ по Cargo.toml/Makefile):
#   • apt/PGDG:      age, pg_cron, hypopg, http, pg_hint_plan, rum, plpython3
#   • apt/Groonga:   pgroonga
#   • source C/PGXS: pgvector v0.8.1, pg_turboquant, pg_net, pgsodium, supabase_vault
#   • .deb:          pg_durable (Microsoft), pg_search (ParadeDB)
#   • SQL/PGXS:      pgmq, index_advisor
#   • pgrx/Rust:     pg_jsonschema, pg_graphql   ← только эти 2
#   • pip:           baml-py (для plpython3u)
#
# ПОРЯДОК СБОРКИ: лёгкое → тяжёлое (ради кеширования слоёв GHA).
#   1-6   apt / .deb / SQL / pip   — быстрые, надёжные
#   7-11  C/PGXS                   — pgvector, turboquant, pg_net, pgsodium, vault
#   12-14 Rust/pgrx                — pg_jsonschema, pg_graphql (самый тяжёлый блок)
#
# pgrx: pg_jsonschema=0.16.0, pg_graphql==0.16.1 → cargo-pgrx ПИН к 0.16.1.
#   (cargo-pgrx latest=0.19.1 НЕсовместим с lib 0.16.x — без пина сборка упадёт.)
#
# ПРИМЕЧАНИЕ: pgsodium помечен Supabase как deprecated, но оставлен — он
#   единственный даёт SQL-API для TCE (transparent column encryption). vault
#   v0.3.1 больше НЕ зависит от pgsodium (линкует libsodium сам, vendored crypto).
#
FROM postgres:17-bookworm

# Тир сервера (min = 1 ГБ, max = 2 ГБ). CI пробрасывает build-arg.
ARG CORTEX_TIER=max

# ============================================================================
# ЛЁГКИЕ ШАГИ (кешируются первыми, быстрая обратная связь)
# ============================================================================

# ----------------------------------------------------------------------------
# 1. apt: расширения PGDG + инструменты сборки (C + Rust/bindgen) + python3.
#    Имена пакетов сверены с apt.postgresql.org (dists/bookworm-pgdg/main).
# ----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # --- расширения PGDG (CREATE EXTENSION сработает сразу) ---
      postgresql-plpython3-17 \
      postgresql-17-age \
      postgresql-17-cron \
      postgresql-17-hypopg \
      postgresql-17-http \
      postgresql-17-pg-hint-plan \
      postgresql-17-rum \
      # --- инструменты для сборки C-расширений ---
      build-essential \
      postgresql-server-dev-17 \
      bison \
      flex \
      git \
      wget \
      curl \
      ca-certificates \
      # --- Python: BAML (baml-py) вызывается из тел функций plpython3u ---
      python3 \
      python3-pip \
      # --- libsodium: pgsodium + supabase_vault (C, SHLIB_LINK=-lsodium) ---
      libsodium-dev \
      # --- libcurl: pg_net (background worker) ---
      libcurl4-openssl-dev \
      # --- pgrx/bindgen: только pg_jsonschema + pg_graphql ---
      pkg-config \
      clang \
      libclang-dev \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 2. Groonga apt-репозиторий → pgroonga (мультиязычный FTS, особенно CJK).
# ----------------------------------------------------------------------------
RUN wget -q --tries=3 --retry-connrefused --waitretry=3 -O /tmp/groonga.deb \
      https://packages.groonga.org/debian/groonga-apt-source-latest-bookworm.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/groonga.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-17-pgdg-pgroonga \
    && rm -f /tmp/groonga.deb \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 3. pg_durable (Microsoft) — готовый amd64 .deb.  ⚠️ amd64-only.
# ----------------------------------------------------------------------------
RUN wget -q --tries=3 --retry-connrefused --waitretry=3 -O /tmp/pg-durable.deb \
      https://github.com/microsoft/pg_durable/releases/download/v0.2.2/pg-durable-postgresql-17_0.2.2-1_amd64.deb \
    && dpkg -i /tmp/pg-durable.deb \
    && rm -f /tmp/pg-durable.deb

# ----------------------------------------------------------------------------
# 4. pg_search (ParadeDB BM25 / Tantivy) — готовый .deb с GitHub Releases.
#    amd64-only. Требует shared_preload_libraries='pg_search'.
# ----------------------------------------------------------------------------
RUN wget -q --tries=3 --retry-connrefused --waitretry=3 -O /tmp/pg-search.deb \
      https://github.com/paradedb/paradedb/releases/download/v0.24.1/postgresql-17-pg-search_0.24.1-1PARADEDB-bookworm_amd64.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/pg-search.deb \
    && rm -f /tmp/pg-search.deb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ----------------------------------------------------------------------------
# 5. Чистый SQL/PGXS: pgmq (очередь) + index_advisor (советник индексов).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/tembo-io/pgmq.git \
    && cd pgmq && make && make install && cd .. && rm -rf pgmq
RUN git clone --depth 1 https://github.com/supabase/index_advisor.git \
    && cd index_advisor && make && make install && cd .. && rm -rf index_advisor

# ----------------------------------------------------------------------------
# 6. BAML (baml-py) — глобально для системного python3 (plpython3u вызывает его).
# ----------------------------------------------------------------------------
RUN pip install --break-system-packages --no-cache-dir baml-py

# ============================================================================
# C/PGXS-СБОРКИ (средняя тяжесть: компиляция C, линковка libsodium/libcurl)
# ============================================================================

# ----------------------------------------------------------------------------
# 7. pgvector v0.8.1 (пин ради ABI-контракта pg_turboquant).
# ----------------------------------------------------------------------------
RUN git clone --branch v0.8.1 --depth 1 https://github.com/pgvector/pgvector.git \
    && cd pgvector && make && make install && cd .. && rm -rf pgvector

# ----------------------------------------------------------------------------
# 8. pg_turboquant — компактный ANN-индекс (чистый C/PGXS), требует pgvector.
# ----------------------------------------------------------------------------
RUN git clone https://github.com/mayflower/pg_turboquant.git \
    && cd pg_turboquant && ./scripts/bootstrap_dev.sh && make && make install \
    && cd .. && rm -rf pg_turboquant

# ----------------------------------------------------------------------------
# 9. pg_net — C-расширение (background worker, libcurl), НЕ pgrx.
#    Асинхронные HTTP-запросы. Требует shared_preload_libraries='pg_net'.
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/supabase/pg_net.git \
    && cd pg_net && make && make install && cd .. && rm -rf pg_net

# ----------------------------------------------------------------------------
# 10. pgsodium — крипто-ядро (C/PGXS + libsodium). SQL-API для TCE.
#     Стандартный PGXS: MODULE_big=pgsodium, SHLIB_LINK=-lsodium.
#     Требует shared_preload_libraries='pgsodium' + getkey_script (секция 15).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/michelp/pgsodium.git \
    && cd pgsodium && make && make install && cd .. && rm -rf pgsodium

# ----------------------------------------------------------------------------
# 11. supabase_vault — секреты (C/PGXS + libsodium). НЕ pgrx, НЕ зависит от pgsodium.
#     v0.3.1: SHLIB_LINK=-lsodium, vendored crypto (crypto_aead_det_xchacha20).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/supabase/vault.git \
    && cd vault && make && make install && cd .. && rm -rf vault

# ============================================================================
# ТЯЖЁЛЫЕ ШАГИ: Rust/pgrx — только pg_jsonschema + pg_graphql
# ============================================================================

# ----------------------------------------------------------------------------
# 12. Rust/pgrx-тулчейн.
#     bookworm rustc слишком стар для pgrx → свежий stable через rustup.
#     cargo-pgrx ПИН к 0.16.1: pg_jsonschema=pgrx 0.16.0, pg_graphql==pgrx 0.16.1.
#     (latest cargo-pgrx=0.19.1 несовместим с lib 0.16.x.)
#     pgrx init регистрирует системный PG17 (без скачивания/сборки PG).
# ----------------------------------------------------------------------------
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install --locked cargo-pgrx@0.16.1 \
    && cargo pgrx init --pg17=/usr/lib/postgresql/17/bin/pg_config

# ----------------------------------------------------------------------------
# 13. pg_jsonschema — JSON Schema валидация (pgrx 0.16.0).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/supabase/pg_jsonschema.git \
    && cd pg_jsonschema \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf pg_jsonschema

# ----------------------------------------------------------------------------
# 14. pg_graphql — GraphQL резолвер (pgrx =0.16.1, edition 2024).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/supabase/pg_graphql.git \
    && cd pg_graphql \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf pg_graphql

# ----------------------------------------------------------------------------
# 15. pgsodium root-key: скрипт generate-on-first-use, ключ хранится в PGDATA.
#     Без getkey_script postgres FATAL при старте с pgsodium в preload.
#     Ключ персистентен (переживает рестарты в рамках одного data-тома).
# ----------------------------------------------------------------------------
RUN cat > /usr/local/bin/pgsodium-getkey.sh <<'EOF'
#!/bin/sh
KEY="${PGDATA:-/var/lib/postgresql/data}/pgsodium.key"
if [ ! -f "$KEY" ]; then
  /usr/bin/head -c 32 /dev/urandom | /usr/bin/base64 > "$KEY"
fi
/usr/bin/cat "$KEY"
EOF
RUN chmod +x /usr/local/bin/pgsodium-getkey.sh

# ----------------------------------------------------------------------------
# 16. Очистка тяжёлых инструментов: Rust-тулчейн + C-компилятор + bindgen.
#     RUNTIME-библиотеки libsodium/libcurl ОСТАВЛЯЕМ (.so-расширений линкуются к ним).
# ----------------------------------------------------------------------------
RUN rustup self uninstall -y || true \
    && rm -rf /root/.pgrx /root/.cargo \
    && apt-get purge -y --auto-remove \
         build-essential postgresql-server-dev-17 bison flex clang libclang-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /
RUN rm -rf /build

# ----------------------------------------------------------------------------
# 17. Профиль конфигурации по тиру (ДОБАВЛЯЕТСЯ к postgresql.conf.sample).
# ----------------------------------------------------------------------------
COPY config/postgresql-${CORTEX_TIER}.conf /tmp/tier.conf
RUN cat /tmp/tier.conf >> /usr/share/postgresql/postgresql.conf.sample && rm /tmp/tier.conf

# ----------------------------------------------------------------------------
# 18. SQL-инициализация: оркестратор init.sql + модульные миграции sql/.
# ----------------------------------------------------------------------------
COPY init.sql /docker-entrypoint-initdb.d/
COPY sql/    /docker-entrypoint-initdb.d/sql/
