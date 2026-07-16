# syntax=docker/dockerfile:1
#
# cortex-pg — PostgreSQL 17 образ для RAG/AI-памяти агентов (векторный + графовый поиск).
# Целевые серверы: слабые amd64 Linux VPS (Tier 1: 1 ГБ/1CPU; Tier 2: 2 ГБ/4CPU).
# База: официальный postgres:17-bookworm (репозиторий PGDG уже подключён в образе).
#
# Полный стек расширений:
#   • apt/PGDG:      age, pg_cron, hypopg, http, pg_hint_plan, rum, plpython3
#   • apt/Groonga:   pgroonga
#   • source C/PGXS: pgvector v0.8.1, pg_turboquant, pg_net
#   • .deb:          pg_durable (Microsoft), pg_search (ParadeDB)
#   • SQL/PGXS:      pgmq, index_advisor
#   • pgrx/Rust:     pgsodium, supabase_vault, pg_jsonschema, pg_graphql
#   • pip:           baml-py (для plpython3u)
#
# ПОРЯДОК СБОРКИ: лёгкое → тяжёлое (ради кеширования слоёв GHA).
#   1-6   apt / .deb / SQL / pip   — быстрые, надёжные, кешируются в первую очередь
#   7-9   C/PGXS                   — средние (компиляция C)
#   10-15 Rust/pgrx                — ТЯЖЁЛЫЕ (cargo), основной риск версий pgrx
# Если Rust-блок упадёт, лёгкие слои уже в кеше → пересоберётся только Rust.
#
# ⚠️ ЗОНА РИСКА (pgrx): версии pgrx в Cargo.toml каждого supabase-расширения
#    могут не совпасть с cargo-pgrx CLI. Первая CI-сборка выявит несовпадения;
#    фикс — пин cargo-pgrx@<version> под конкретное расширение.
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
      # --- инструменты для сборки C-расширений (pgvector, pg_turboquant, pg_net) ---
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
      # --- pgrx/Rust-сборка: bindgen (libclang), libsodium (pgsodium), libcurl (pg_net) ---
      pkg-config \
      clang \
      libclang-dev \
      libsodium-dev \
      libcurl4-openssl-dev \
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
# C/PGXS-СБОРКИ (средняя тяжесть: компиляция C)
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

# ============================================================================
# ТЯЖЁЛЫЕ ШАГИ: Rust/pgrx (основной риск, кешируется последним)
# ============================================================================

# ----------------------------------------------------------------------------
# 10. Rust/pgrx-тулчейн.
#     bookworm rustc слишком стар для pgrx → свежий stable через rustup.
#     pgrx init регистрирует системный PG17 (без скачивания/сборки PG).
# ----------------------------------------------------------------------------
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install --locked cargo-pgrx \
    && cargo pgrx init --pg17=/usr/lib/postgresql/17/bin/pg_config

# ----------------------------------------------------------------------------
# 11. pgsodium — крипто-ядро (pgrx + libsodium). База для supabase_vault.
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/michelp/pgsodium.git \
    && cd pgsodium \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf pgsodium

# ----------------------------------------------------------------------------
# 12. supabase_vault — секреты (pgrx, зависит от pgsodium).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/supabase/supabase_vault.git \
    && cd supabase_vault \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf supabase_vault

# ----------------------------------------------------------------------------
# 13. pg_jsonschema — JSON Schema валидация (pgrx).
# ----------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/supabase/pg_jsonschema.git \
    && cd pg_jsonschema \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf pg_jsonschema

# ----------------------------------------------------------------------------
# 14. pg_graphql — GraphQL резолвер (pgrx).
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
# 16. Очистка тяжёлых инструментов: Rust-тулчейн + C-компилятор.
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
