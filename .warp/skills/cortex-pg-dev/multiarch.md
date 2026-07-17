# Раздел: multi-arch (amd64 + arm64)

> Образ собирается под linux/amd64 + linux/arm64. **Нативные раннеры**, без QEMU.

## Зачем нативные раннеры (не QEMU)

QEMU-эмуляция одной арх под другую — **неприемлемо** для тяжёлых Rust/C-сборок:
pgrx + cargo + bindgen под эмуляцией идёт часами или падает по OOM/таймауту.
GitHub даёт **нативные arm64-раннеры бесплатно** для публичных репозиториев.

## Matrix в CI

```yaml
build:
  strategy:
    fail-fast: false
    matrix:
      include:
        - arch: amd64
          runner: ubuntu-latest
        - arch: arm64
          runner: ubuntu-24.04-arm
  runs-on: ${{ matrix.runner }}
```

- `fail-fast: false` — падение одной арх не отменяет вторую (независимый результат).
- `timeout-minutes: 60` — на холодном кэше pgrx-сборка долгая.
- Кэш изолирован по арх: `cache-from/to: type=gha,scope=${{ matrix.arch }}`
  (кэш amd64 бесполезен для arm64 и наоборот).

## TARGETARCH в Dockerfile

Docker автоматически выставляет `TARGETARCH` (amd64/arm64). Используем для `.deb`:

```dockerfile
ARG TARGETARCH
RUN wget -O /tmp/pg-search.deb \
      https://github.com/paradedb/paradedb/releases/download/v0.24.1/postgresql-17-pg-search_0.24.1-1PARADEDB-bookworm_${TARGETARCH}.deb \
    && apt-get install -y --no-install-recommends /tmp/pg-search.deb
```

ParadeDB публикует **обе** архитектуры `.deb`: `..._amd64.deb` и `..._arm64.deb`.

## pg_durable: был amd64-only .deb → стал source-build

Раньше pg_durable распространялся как `.deb`, но **только amd64**. Для multi-arch
переведён на сборку из исходников (pgrx) — тот же тулчейн, что pg_jsonschema/pg_graphql:

```dockerfile
RUN git clone --branch v0.2.2 --depth 1 https://github.com/microsoft/pg_durable.git \
    && cd pg_durable \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/17/bin/pg_config \
    && cd .. && rm -rf pg_durable
```

pgrx-сборки **арх-нейтральны** — одна команда работает на обоих раннерах. См. `pgrx-builds.md`.

## Финальный multi-arch манифест

Сборка пушит **арх-специфичные** теги: `sha-<short>-amd64`, `sha-<short>-arm64`.
Отдельный job `manifest` (после обоих build) объединяет их:

```bash
docker buildx imagetools create \
  -t ghcr.io/owner/cortex-pg:sha-<short> \
  -t ghcr.io/owner/cortex-pg:latest \
  ghcr.io/owner/cortex-pg:sha-<short>-amd64 \
  ghcr.io/owner/cortex-pg:sha-<short>-arm64
```

→ `docker pull ...:latest` сам выбирает нужную арх на хосте (через manifest list).
`provenance: false` при пуше арх-тегов — иначе imagetools путается в аттачах.

## Локальная сборка под другую арх

```bash
docker build --platform linux/arm64 --build-arg CORTEX_TIER=min -t cortex-pg:arm64 .
```

Все расширения кросс-архитектурно совместимы (включая Rust-овые).
