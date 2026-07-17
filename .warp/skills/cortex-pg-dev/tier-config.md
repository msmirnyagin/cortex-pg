# Раздел: tier-конфиги (min / max)

> Два профиля ресурсов под целевое железо. Выбираются build-arg `CORTEX_TIER`.

## Два тира

| Параметр | Tier 1 `min` (1 ГБ / 1 CPU) | Tier 2 `max` (2 ГБ / 4 CPU) |
|---|---|---|
| `shared_buffers` | 192 МБ | 512 МБ |
| `max_connections` | 12 | 25 |
| Параллелизм | выкл (1 CPU) | 2 воркера на gather |
| `shared_preload_libraries` | `supabase_vault` | `pg_cron, pg_durable, pg_search, supabase_vault, pg_net` |
| Назначение | эконом-режим, оркестрация в приложении | полный стек |

Файлы: `config/postgresql-min.conf`, `config/postgresql-max.conf`.

## Как работает выбор тира

```dockerfile
ARG CORTEX_TIER=max
COPY config/postgresql-${CORTEX_TIER}.conf /tmp/tier.conf
RUN cat /tmp/tier.conf >> /usr/share/postgresql/postgresql.conf.sample && rm /tmp/tier.conf
```

Tier-конфиг **добавляется** (append) к `postgresql.conf.sample`. CI пробрасывает build-arg;
локально — `--build-arg CORTEX_TIER=min`. Один образ = один tier (tier фиксирован при сборке).

## shared_preload_libraries — главное различие

**Tier `min` (1 ГБ):** только `supabase_vault`. Каждый background worker ест RAM,
на 1 ГБ не напасёшься. Оркестрацию (очереди, cron, durable) выносят в приложение.

**Tier `max` (2 ГБ):** полный набор preload — `pg_cron, pg_durable, pg_search, supabase_vault, pg_net`.
Все background workers активны.

> **vault есть в ОБЕИХ** tier-ах — `supabase_vault` обязателен (секреты нужны всегда).
> `vault.getkey_script` тоже в обоих. См. `vault-pgsodium.md`.

## Почему жёсткие лимиты

Цель — слабые amd64/arm64 VPS за $5. На 1 ГБ обычный Postgres умирает от OOM при
коннект-шторме от агентов. Поэтому:
- Маленький `shared_buffers` (192 МБ) — оставляем RAM под work_mem и кэш ОС.
- Мало `max_connections` — реальные коннекты пулируются через **PgBouncer** (transaction-mode).
- Параллелизм выкл на 1 CPU (нет смысла).

## PgBouncer — обязательный sidecar (поверх tier-а)

На обоих tier-ах поверх Postgres поднимается PgBouncer (transaction-mode, ~8 коннектов на БД).
Защищает от коннект-штормов. Конфиг: `config/pgbouncer.ini`.
`pgbouncer-userlist.txt` — gitignored (там нет секретов, но convention).

## Тюнинг: что менять осторожно

- `shared_buffers` — поднимая, оставляй RAM для work_mem × max_connections.
- `max_connections` — НЕ поднимай выше; PgBouncer держит пул, не postgres.
- `shared_preload_libraries` — добавление preload-расширения = больше RSS в простое.

## Добавление preload-расширения

Если новое расширение требует preload (`_PG_init` проверяет shared preload):
1. Добавить в `shared_preload_libraries` в `config/postgresql-{min,max}.conf`.
2. Решить, в обоих tier-ах или только в `max` (по потреблению RAM).
3. Проверить: образ стартует без FATAL на целевом tier-е.
