# Используем официальный образ PostgreSQL 17 на базе Debian
FROM postgres:17-bookworm

# Устанавливаем зависимости для сборки (C, Rust, Python)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    postgresql-server-dev-17 \
    postgresql-plpython3-17 \
    git \
    bison \
    flex \
    wget \
    ca-certificates \
    python3 \
    python3-pip \
    curl \
    # Устанавливаем Rust (нужен для BAML и современных расширений)
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Добавляем Rust в PATH
ENV PATH="/root/.cargo/bin:${PATH}"

# Создаем рабочую директорию для сборки
WORKDIR /build

# 1. Сборка Apache AGE (ветка PG17)
RUN git clone https://github.com/apache/age.git \
    && cd age \
    && git checkout PG17 \
    && make \
    && make install \
    && cd .. \
    && rm -rf age

# 2. Сборка pgvector (ветка v0.8.1)
RUN git clone --branch v0.8.1 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install \
    && cd .. \
    && rm -rf pgvector

# 3. Сборка pg_turboquant (требует установленного pgvector)
RUN git clone https://github.com/mayflower/pg_turboquant.git \
    && cd pg_turboquant \
    && ./scripts/bootstrap_dev.sh \
    && make \
    && make install \
    && cd .. \
    && rm -rf pg_turboquant

# 4. Установка pg_durable (готовый пакет от Microsoft)
RUN wget https://github.com/microsoft/pg_durable/releases/download/v0.2.2/pg-durable-postgresql-17_0.2.2-1_amd64.deb \
    && dpkg -i pg-durable-postgresql-17_0.2.2-1_amd64.deb \
    && rm *.deb

# Примечание: lakebase_text находится в стадии активной разработки (2026), 
# его сборка зависит от ParadeDB. Если появится открытый исходный код на C/Rust, 
# он собирается аналогично шагам 2 или 3.

# Устанавливаем BAML глобально для системного Python (чтобы plpython3u мог его вызывать)
RUN pip install --break-system-packages baml

# Очищаем рабочую директорию
WORKDIR /
RUN rm -rf /build

# Профиль конфига по тиру сервера (min = 1 ГБ, max = 2 ГБ).
# Соответствующий конфиг ДОБАВЛЯЕТСЯ к postgresql.conf.sample → влияет на
# shared_buffers / shared_preload_libraries / parallelism и т.д.
# CI передаёт CORTEX_TIER как build-arg (см. .github/workflows/build.yml).
ARG CORTEX_TIER=max
COPY config/postgresql-${CORTEX_TIER}.conf /tmp/tier.conf
RUN cat /tmp/tier.conf >> /usr/share/postgresql/postgresql.conf.sample && rm /tmp/tier.conf

# Копируем скрипт инициализации и модульные миграции
COPY init.sql /docker-entrypoint-initdb.d/
COPY sql/    /docker-entrypoint-initdb.d/sql/
