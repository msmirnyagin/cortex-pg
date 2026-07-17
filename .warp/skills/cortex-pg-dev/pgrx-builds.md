# Раздел: pgrx/Rust-сборки (pg_jsonschema, pg_graphql, pg_durable)

> Три pgrx-расширения в образе. Самый тяжёлый кусок сборки (~15–20 мин с холодным кэшем).

## Главное: пин cargo-pgrx к 0.16.1

Все три расширения используют **pgrx lib 0.16.x**:

| Расширение | pgrx lib (Cargo.toml) |
|---|---|
| `pg_jsonschema` | `0.16.0` |
| `pg_graphql` | `=0.16.1` |
| `pg_durable` | `=0.16.1` |

→ `cargo-pgrx` CLI **пин к 0.16.1**:

```dockerfile
RUN cargo install --locked cargo-pgrx@0.16.1 \
    && cargo pgrx init --pg17=/usr/lib/postgresql/17/bin/pg_config
```

**Почему пин критичен:** `cargo-pgrx` latest = 0.19.1, но он **несовместим** с lib 0.16.x.
Без пина сборка падает на этапе генерации SQL/bindings с непонятными ошибками.
Версия CLI должна быть совместима с версией lib, на которой собрано расширение.

## Тулчейн

- bookworm `rustc` слишком стар для pgrx → свежий stable через rustup:
  ```dockerfile
  RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  ENV PATH="/root/.cargo/bin:${PATH}"
  ```
- `pgrx init` регистрирует **системный** PG17 (`--pg17=...pg_config`) — НЕ скачивает/собирает PG.
- Нужны bindgen-зависимости: `clang`, `libclang-dev`, `pkg-config` (в apt-блоке).

## Унифицированная команда сборки

Одна и та же для всех трёх:

```dockerfile
RUN git clone --branch <tag> --depth 1 https://github.com/<org>/<repo>.git \
    && cd <repo> \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf <repo>
```

- `--release` — оптимизация (без неё расширение медленное).
- `--pg-config` — целевой PG (системный 17).
- `--depth 1` + `--branch <tag>` — минимальный клон, воспроизводимая версия.

## Очистка тулчейна (важно для размера образа)

После сборки всех pgrx-расширений — удаляем тяжёлое:

```dockerfile
RUN rustup self uninstall -y || true \
    && rm -rf /root/.pgrx /root/.cargo \
    && apt-get purge -y --auto-remove build-essential postgresql-server-dev-17 bison flex clang libclang-dev pkg-config
```

**НО runtime-libsodium/libcurl ОСТАВЛЯЕМ** (вместе с `-dev`): `.so` расширений
динамически линкуются к ним при загрузке. Удаление `libcurl4`/`libsodium23` → FATAL при старте.

## Частые ошибки

- **«cargo pgrx: incompatible version»** → поднимается `cargo-pgrx` 0.19.x. Проверь пин `@0.16.1`.
- **`bindgen` падает** → нет `libclang-dev`/`clang` в apt-блоке.
- **`pgrx init` качает/собирает PG** → забыт `--pg17=...`. Должен использовать системный PG17.
- **Несогласованные edition** — `pg_graphql` edition 2024, нужен свежий rustup (там есть).

## arm64

pgrx-сборки **арх-нейтральны** — те же команды работают на arm64 нативном раннере.
`pg_durable` раньше был amd64-only `.deb`; теперь собирается из исходников (pgrx) —
именно ради multi-arch (см. `multiarch.md`).
