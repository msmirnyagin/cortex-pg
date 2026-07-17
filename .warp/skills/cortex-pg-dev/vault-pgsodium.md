# Раздел: vault / pgsodium / крипто

> Секреты в образе — через `supabase_vault`. `pgsodium` УБРАН (deprecated).

## Главный вывод: vault — НЕ pgrx

`supabase_vault` и `pgsodium` — это **C/PGXS** (`make && make install`), **НЕ** pgrx,
несмотря на «supabase» в имени. Не путать с pg_jsonschema/pg_graphql/pg_durable.
Всегда проверяй реальный `Makefile`/`Cargo.toml`.

## pgsodium убран — почему

- Supabase **не рекомендует** новые инсталляции (deprecated).
- `supabase_vault` v0.3.1 **самодостаточен**: C/PGXS, линкует libsodium напрямую,
  vendored-крипто (`crypto_aead_det_xchacha20`).
- У vault v0.3.1 **нет поля `requires`** → формально не зависит от pgsodium.

## Формат корневого ключа — HEX, не base64

**Критично.** vault (и pgsodium) вызывают `hex_decode` на вывод `getkey_script`.
Если скрипт вернёт base64 — **FATAL** при старте.

Скрипт в образе (`/usr/local/bin/vault-getkey.sh`) генерирует **HEX 32 байта**:

```sh
KEY="${PGDATA:-/var/lib/postgresql/data}/vault_root.key"
if [ ! -f "$KEY" ]; then
  /usr/bin/head -c 32 /dev/urandom | /usr/bin/od -A n -t x1 | /usr/bin/tr -d ' \n' > "$KEY"
fi
/usr/bin/cat "$KEY"
```

- `od -t x1` → hex. `tr -d ' \n'` → убирает пробелы/переносы od.
- Ключ **персистентен** в PGDATA — один data-том = один ключ.
- При пересоздании тома генерируется новый (старые секреты расшифровать нельзя).

## preload обязателен

vault грузит корневой ключ **только** если `supabase_vault` в `shared_preload_libraries`:

```c
// _PG_init проверяет:
if (!process_shared_preload_libraries_in_progress) { /* не загружает ключ */ }
```

→ Без preload: postgres стартует, `vault` schema создаётся, но `vault.create_secret`
**падает** при первой попытке шифрования (ключ не загружен).

### Tier-конфиги

- `postgresql-min.conf`: `shared_preload_libraries = 'supabase_vault'` + `vault.getkey_script = '/usr/local/bin/vault-getkey.sh'`
- `postgresql-max.conf`: `'pg_cron, pg_durable, pg_search, supabase_vault, pg_net'` + getkey_script

(см. `tier-config.md`)

## Диагностика

| Симптом | Причина | Фикс |
|---|---|---|
| `FATAL: ...getkey_script...` при старте | скрипт не найден / не исполняемый | `chmod +x`, путь в getkey_script |
| FATAL при старте, base64 в выводе | getkey вернул не-HEX | проверь формат (od -t x1) |
| postgres стартует, `vault.create_secret` падает | vault не в preload → ключ не загружён | добавить в shared_preload_libraries |
| `vault schema` отсутствует после init | `CREATE EXTENSION` не выполнилось | проверь `sql/02-validation-security.sql`, логи initdb |

## Smoke-тест (что реально проверяем)

В CI (`build.yml`) smoke-тест доказывает, что ключ загружён, **круговым шифрованием**:

```sql
SELECT vault.create_secret('smoke-test-secret', 'smoke');
```

Если проходит — корневой ключ есть (загружён из preload), libsodium работает, getkey отдал HEX.
Это покрывает preload + getkey + libsodium одним запросом.
