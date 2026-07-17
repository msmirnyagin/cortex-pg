# syntax=docker/dockerfile:1
#
# cortex-pg — PostgreSQL 17 образ для RAG/AI-памяти агентов (векторный + графовый поиск).
# Целевые серверы: слабые amd64/arm64 Linux VPS (Tier 1: 1 ГБ/1CPU; Tier 2: 2 ГБ/4CPU).
# База: официальный postgres:17-bookworm (репозиторий PGDG уже подключён в образе).
#
# MULTI-STAGE: тулчейн (Rust/clang/server-dev) живёт ТОЛЬКО в `builder` и не попадает
#   в финальный образ. В слоистой overlay-FS `RUN purge`/`--auto-remove` в позднем слое
#   НЕ убирает файлы из ранних слоёв — поэтому без multi-stage Rust (~1.5 ГБ) остаётся
#   в образе замаскированным. Здесь финал получает только явно скопированные артефакты.
#
# Полный стек расширений (методы сборки ВЕРИФИЦИРОВАНЫ по Cargo.toml/Makefile):
#   • apt/PGDG:      age, pg_cron, hypopg, http, pg_hint_plan, rum, plpython3, postgis
#   • apt/Groonga:   pgroonga
#   • .deb:          pg_search (ParadeDB, arch=TARGETARCH)
#   • source C/PGXS: pgvector v0.8.1, pg_turboquant, pg_net, supabase_vault  ← builder
#   • SQL/PGXS:      pgmq, index_advisor                                      ← builder
#   • pgrx/Rust:     pg_jsonschema, pg_graphql, pg_durable (Microsoft)        ← builder
#   • pip:           baml-py (для plpython3u)                                 ← builder → COPY
#
# MULTI-ARCH: amd64 + arm64 (нативные раннеры CI). pg_search .deb параметризуется
#   по TARGETARCH; pg_durable собирается из исходников (pgrx =0.16.1) — .deb был
#   amd64-only. Остальные шаги арх-нейтральны.
#
# pgrx: pg_jsonschema=0.16.0, pg_graphql==0.16.1, pg_durable==0.16.1 → cargo-pgrx
#   ПИН к 0.16.1 (latest=0.19.1 НЕсовместим с lib 0.16.x — без пина сборка упадёт).
#
# КРИПТО: pgsodium УБРАН (Supabase не рекомендует, deprecated). Секреты — через
#   supabase_vault v0.3.1 (C/PGXS, самодостаточен). vault грузит корневой ключ через
#   vault.getkey_script (HEX, 32 байта) при старте → скрипт обязан быть в образе и
#   supabase_vault в shared_preload_libraries.
#

# ============================================================================
# Stage 1 — BUILDER: тяжёлый тулчейн живёт ТОЛЬКО здесь.
# Ставит ТОЛЬКО build-зависимости и source/pgrx-расширения (apt-расширения НЕ здесь,
# чтобы PG-директории builder'а оставались чистыми = база + source-артефакты).
# ============================================================================
FROM postgres:17-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      # --- инструменты сборки C/PGXS + pgrx/bindgen ---
      build-essential \
      postgresql-server-dev-17 \
      bison \
      flex \
      git \
      wget \
      curl \
      ca-certificates \
      pkg-config \
      clang \
      libclang-dev \
      # --- dev-заголовки source-расширений ---
      libsodium-dev \
      libcurl4-openssl-dev \
      # --- python для baml-py (plpython3u вызывает его из тел функций) ---
      python3 \
      python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ---------------------------------------------------------------------------- (лёгкое)
# SQL/PGXS: pgmq (Makefile в подкаталоге pgmq-extension/), index_advisor (в корне).
# ---------------------------------------------------------------------------- (лёгкое)
RUN git clone --depth 1 https://github.com/tembo-io/pgmq.git \
    && cd pgmq/pgmq-extension && make && make install \
    && cd /build && rm -rf pgmq
RUN git clone --depth 1 https://github.com/supabase/index_advisor.git \
    && cd index_advisor && make && make install && cd /build && rm -rf index_advisor

# ---------------------------------------------------------------------------- (среднее)
# C/PGXS: pgvector v0.8.1 (пин ради ABI pg_turboquant), pg_turboquant, pg_net, vault.
# ---------------------------------------------------------------------------- (среднее)
RUN git clone --branch v0.8.1 --depth 1 https://github.com/pgvector/pgvector.git \
    && cd pgvector && make && make install && cd /build && rm -rf pgvector
RUN git clone https://github.com/mayflower/pg_turboquant.git \
    && cd pg_turboquant && ./scripts/bootstrap_dev.sh && make && make install \
    && cd /build && rm -rf pg_turboquant
RUN git clone --depth 1 https://github.com/supabase/pg_net.git \
    && cd pg_net && make && make install && cd /build && rm -rf pg_net
RUN git clone --depth 1 https://github.com/supabase/vault.git \
    && cd vault && make && make install && cd /build && rm -rf vault

# baml-py → /usr/local/lib/python3.11/dist-packages/ (COPY в финал без pip/python3-pip).
RUN pip install --break-system-packages --no-cache-dir baml-py

# ---------------------------------------------------------------------------- (тяжёлое)
# Rust/pgrx-тулчейн. bookworm rustc слишком стар для pgrx → свежий stable через rustup.
# pgrx init регистрирует системный PG17 (без скачивания/сборки PG).
# ---------------------------------------------------------------------------- (тяжёлое)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install --locked cargo-pgrx@0.16.1 \
    && cargo pgrx init --pg17=/usr/lib/postgresql/17/bin/pg_config

# pgrx: pg_jsonschema (0.16.0), pg_graphql (=0.16.1), pg_durable (=0.16.1).
RUN git clone --depth 1 https://github.com/supabase/pg_jsonschema.git \
    && cd pg_jsonschema \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd /build && rm -rf pg_jsonschema
RUN git clone --depth 1 https://github.com/supabase/pg_graphql.git \
    && cd pg_graphql \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd /build && rm -rf pg_graphql
RUN git clone --branch v0.2.2 --depth 1 https://github.com/microsoft/pg_durable.git \
    && cd pg_durable \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd /build && rm -rf pg_durable

# ============================================================================
# Stage 2 — FINAL: lean runtime, БЕЗ тулчейна (-dev/build tools/Rust НЕ ставим).
# ============================================================================
FROM postgres:17-bookworm

ARG CORTEX_TIER=max
ARG TARGETARCH

# ---------------------------------------------------------------------------- (1)
# apt: ТОЛЬКО runtime apt-расширения (без -dev, без build tools) + runtime-либы
# source-расширений. --auto-remove НЕ используем — он снёс бы нужные runtime-либы.
#   • libsodium23 — runtime-зависимость supabase_vault (.so линкуется к ней).
#   • libcurl4    — runtime-зависимость pg_net.
#   • PostGIS тянет GEOS/PROJ/protobuf-c транзитивно; --no-install-recommends отсекает GDAL/растры.
# ---------------------------------------------------------------------------- (1)
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-plpython3-17 \
      postgresql-17-age \
      postgresql-17-cron \
      postgresql-17-hypopg \
      postgresql-17-http \
      postgresql-17-pg-hint-plan \
      postgresql-17-rum \
      postgresql-17-postgis-3 \
      postgresql-17-postgis-3-scripts \
      python3 \
      libsodium23 \
      libcurl4 \
      wget \
      ca-certificates \
      gnupg \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------- (2)
# Groonga apt-репозиторий → pgroonga (мультиязычный FTS, особенно CJK).
# ---------------------------------------------------------------------------- (2)
RUN wget -q --tries=3 --retry-connrefused --waitretry=3 -O /tmp/groonga.deb \
      https://packages.groonga.org/debian/groonga-apt-source-latest-bookworm.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/groonga.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-17-pgdg-pgroonga \
    && rm -f /tmp/groonga.deb \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------- (3)
# pg_search (ParadeDB BM25 / Tantivy) — готовый .deb с GitHub Releases.
# MULTI-ARCH: URL параметризуется по TARGETARCH (amd64/arm64 .deb существуют).
# ---------------------------------------------------------------------------- (3)
RUN wget -q --tries=3 --retry-connrefused --waitretry=3 -O /tmp/pg-search.deb \
      https://github.com/paradedb/paradedb/releases/download/v0.24.1/postgresql-17-pg-search_0.24.1-1PARADEDB-bookworm_${TARGETARCH}.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/pg-search.deb \
    && rm -f /tmp/pg-search.deb \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------- (4)
# Source/pgrx-расширения из builder. PG-директории builder'а = базовые postgres-файлы
# + ТОЛЬКО source-артефакты (apt-exts туда не ставились). COPY аддитивен: apt-файлы
# финала (postgis/age/...) остаются, source-артефакты добавляются поверх без коллизий имён.
# ---------------------------------------------------------------------------- (4)
COPY --from=builder /usr/lib/postgresql/17/lib/ /usr/lib/postgresql/17/lib/
COPY --from=builder /usr/share/postgresql/17/extension/ /usr/share/postgresql/17/extension/
COPY --from=builder /usr/local/lib/python3.11/dist-packages/ /usr/local/lib/python3.11/dist-packages/

# ---------------------------------------------------------------------------- (5)
# vault root-key: скрипт generate-on-first-use (HEX 32 байта), ключ в PGDATA.
# vault грузит ключ через vault.getkey_script при старте (preload). Без скрипта postgres FATAL.
# Формат HEX (не base64!) — vault/pgsodium hex_decode'ют вывод скрипта.
# ---------------------------------------------------------------------------- (5)
RUN cat > /usr/local/bin/vault-getkey.sh <<'EOF'
#!/bin/sh
KEY="${PGDATA:-/var/lib/postgresql/data}/vault_root.key"
if [ ! -f "$KEY" ]; then
  /usr/bin/head -c 32 /dev/urandom | /usr/bin/od -A n -t x1 | /usr/bin/tr -d ' \n' > "$KEY"
fi
/usr/bin/cat "$KEY"
EOF
RUN chmod +x /usr/local/bin/vault-getkey.sh

# ---------------------------------------------------------------------------- (6)
# Профиль конфигурации по тиру (ДОБАВЛЯЕТСЯ к postgresql.conf.sample).
# ---------------------------------------------------------------------------- (6)
COPY config/postgresql-${CORTEX_TIER}.conf /tmp/tier.conf
RUN cat /tmp/tier.conf >> /usr/share/postgresql/postgresql.conf.sample && rm /tmp/tier.conf

# ---------------------------------------------------------------------------- (7)
# SQL-инициализация: оркестратор init.sql + модульные миграции sql/.
# ---------------------------------------------------------------------------- (7)
COPY init.sql /docker-entrypoint-initdb.d/
COPY sql/    /docker-entrypoint-initdb.d/sql/
