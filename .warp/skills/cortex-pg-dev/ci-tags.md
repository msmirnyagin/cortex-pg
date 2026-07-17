# Раздел: CI и API-free генерация тегов

> Теги image генерируются **shell-ом из `github.ref`/`github.sha`**, без `docker/metadata-action`.

## Почему без metadata-action

`docker/metadata-action@v5` делает **API-запросы к GitHub** (за тегами/releases) на каждом шаге.
Во время сбоев платформы GitHub (Unicorn 503) action падает — и **сборка даже не запускается**,
хотя сам git push прошёл. Это давало ложные красные CI без единой ошибки в коде.

Решение: считать теги локально из `github.ref` и `github.sha` — без единого сетевого вызова.
Полностью устойчиво к API-инфраструктуре GitHub.

## Логика тегов

```bash
SHORT_SHA="sha-$(printf '%s' "$GITHUB_SHA" | cut -c1-7)"   # всегда
case "$GITHUB_REF" in
  refs/tags/v*)       # релизный тег → семвер: v1.0.0, 1.0
    VERSION="${GITHUB_REF#refs/tags/v}"
    TAGS="$SHORT_SHA $VERSION $(major.minor)"
    ;;
  refs/heads/*)       # ветка → имя ветки; main/master → ещё latest
    BRANCH_TAG="${GITHUB_REF#refs/heads/}"
    TAGS="$SHORT_SHA $BRANCH_TAG [+ latest для main/master]"
    ;;
esac
```

Всегда есть `sha-<short>` (неизменный идентификатор коммита). Плюс семвер/ветка/latest по контексту.

## Multi-arch: два этапа

Сами теги нельзя пушить из matrix-джобов (каждая арх → конфликт / неполный манифест).
Поэтому двухэтапно:

1. **build (matrix)** — каждая арх пушит **только** арх-суффиксный тег:
   `sha-<short>-amd64`, `sha-<short>-arm64`. `provenance: false`.
2. **manifest** (`needs: build`) — собирает **финальные** теги из обоих арх-тегов:
   ```bash
   docker buildx imagetools create $TAG_ARGS \
     $IMAGE:sha-<short>-amd64 $IMAGE:sha-<short>-arm64
   ```
   (подробно — `multiarch.md`).

## Smoke-тест ДО push

Порядок шагов в build-джобе: build (load, без push) → smoke → build+push.
Сначала образ собирается локально и проходит smoke-тест; push происходит только
после зелёного smoke. Так битый образ не попадает в registry.

Smoke проверяет: `pg_isready` (preload-библиотеки загрузились), `99-verify.sql`,
`>= 9` расширений, `vault` schema, `vault.create_secret` round-trip (см. `vault-pgsodium.md`).

## actions на Node 24

Все экшены — major-версии с Node 24-native рантаймом (убирает deprecation-warnings):
- `actions/checkout@v5`
- `docker/setup-buildx-action@v4`
- `docker/login-action@v4`
- `docker/build-push-action@v7`

## Авторизация в GHCR

Встроенный `GITHUB_TOKEN` (`secrets.GITHUB_TOKEN`) — право `packages: write`.
**Без дополнительных секретов.** Токен выдаётся автоматически для пуша в `ghcr.io/<owner>/<repo>`.

## Кэш сборки

`type=gha` (GitHub Actions cache), `mode=max` (кешировать все слои, не только финальный).
`scope` изолирован по арх (`scope=${{ matrix.arch }}`) — кэш amd64≠arm64.
На холодном кэше — полная пересборка (~30–45 мин), на тёплом — минуты.
