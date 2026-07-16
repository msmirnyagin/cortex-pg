# Расширения валидации и безопасности

Справочный раздел по расширениям: `pg_jsonschema`, `pgcrypto`, `pgsodium`, `vault`.
Источники: официальные README (GitHub), документация PostgreSQL 17 (postgresql.org/docs/17/pgcrypto.html), теги релизов GitHub API. Все имена функций/типов проверены по первоисточникам.

---

## ⚠️ Важное замечание по именам API

В задании фигурирует функция `jsonschema_matches`. В **актуальной** версии `pg_jsonschema` (v0.3.4, master) такой функции нет. Реальные имена — `json_matches_schema` / `jsonb_matches_schema`. Вероятно, в задании приведено устаревшее/приблизительное имя. В образе нужно опираться на имена из раздела «Ключевой SQL API» ниже.

---

## 1. pg_jsonschema

**Репозиторий:** https://github.com/supabase/pg_jsonschema
**Версия (актуальная стабильная):** v0.3.4

### Назначение
Расширение для валидации значений `json`/`jsonb` по схеме [JSON Schema](https://json-schema.org/). Тонкая (pgrx) обёртка над Rust-крейтом `jsonschema`; работает значительно быстрее PL/pgSQL-аналогов (~10× по бенчмаркам автора).

### Ключевой SQL API
Базовые функции (возвращают `bool`):

```sql path=null start=null
-- Валидация json/jsonb-значения по схеме
json_matches_schema(schema json, instance json) RETURNS bool
jsonb_matches_schema(schema json, instance jsonb) RETURNS bool

-- Проверка, что сама схема валидна
jsonschema_is_valid(schema json) RETURNS bool

-- Массив текстовых сообщений об ошибках валидации
jsonschema_validation_errors(schema json, instance json) RETURNS text[]
```

«Скомпилированный» тип `jsonschema` (валидатор компилируется и кэшируется per callsite — выигрыш до ~1.8× на повторных проверках):

```sql path=null start=null
json_matches_compiled_schema(schema jsonschema, instance json) RETURNS bool
jsonb_matches_compiled_schema(schema jsonschema, instance jsonb) RETURNS bool
jsonschema_validation_errors_compiled(schema jsonschema, instance json) RETURNS text[]
jsonb_validation_errors_compiled(schema jsonschema, instance jsonb) RETURNS text[]
```

Типичный способ применения — `CHECK`-ограничение на столбце:

```sql path=null start=null
CREATE TABLE customer (
    id   serial PRIMARY KEY,
    meta jsonb,
    CHECK (jsonb_matches_schema(
        '{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string","maxLength":16}}}}',
        meta
    ))
);

-- Ошибки валидации:
SELECT jsonschema_validation_errors('{"maxLength":4}', '"123456789"');
-- => {"\"123456789\" is longer than 4 characters"}
```

### Роль в RAG/AI-стеке
Гарантирует структурную корректность `jsonb`-документов: метаданные чанков, описания эмбеддингов, конфигурации пайплайнов, payload tool-call’ов и ответов LLM. Позволяет отбраковывать некорректные документы ещё на уровне `INSERT`/`UPDATE`, не вынося валидацию в код приложения.

### Требования
- **`shared_preload_libraries`:** нет.
- **`CREATE EXTENSION`:** да — `CREATE EXTENSION pg_jsonschema;`
- **Схема по умолчанию:** `public` (специальной схемы не создаёт).
- **Зависимости от других расширений:** нет.
- **Зависимости для сборки:** Rust + [pgrx](https://github.com/tcdi/pgrx).

### Установка в нашем образе
**Предустановлено в базовом образе `supabase/postgres`** (Supabase включает pg_jsonschema в свой стек). При необходимости пересборки — `cargo pgrx` или PGDG/Supabase-пакет. Конфликтов с другими расширениями не выявлено.

---

## 2. pgcrypto

**Источник:** `contrib/pgcrypto` в дереве PostgreSQL (https://www.postgresql.org/docs/17/pgcrypto.html)
**Версия:** поставляется вместе с PostgreSQL 17 (как часть `postgresql-contrib`).

### Назначение
Шифрование, хеширование, MAC и функции для хеширования паролей в стиле `crypt(3)`. Включает PGP-совместимое симметричное/асимметричное шифрование и ASCII-armor.

### Ключевой SQL API

**Хеширование:**

```sql path=null start=null
digest(data text,  type text) RETURNS bytea
digest(data bytea, type text) RETURNS bytea
-- type: md5 | sha1 | sha224 | sha256 | sha384 | sha512 | blake2b512 и др.

SELECT encode(digest('secret', 'sha256'), 'hex');
```

**HMAC (ключевой MAC):**

```sql path=null start=null
hmac(data text,  key text,  type text) RETURNS bytea
hmac(data bytea, key bytea, type text) RETURNS bytea
```

**Хеширование паролей (`crypt` + `gen_salt`):**

```sql path=null start=null
crypt(password text, salt text) RETURNS text
gen_salt(type text [, iter_count integer]) RETURNS text
-- type: bf (bcrypt) | md5 | xdes | des
```

Сценарий проверки пароля (соль берётся из уже сохранённого хеша):

```sql path=null start=null
-- Сохранение:
UPDATE accounts SET pswhash = crypt('mypassword', gen_salt('bf', 8));

-- Проверка:
SELECT (pswhash = crypt('entered_password', pswhash)) AS pswmatch FROM accounts;
```

**PGP-шифрование (симметричное):**

```sql path=null start=null
pgp_sym_encrypt(data text,  psw text [, options text]) RETURNS bytea
pgp_sym_encrypt_bytea(data bytea, psw text [, options text]) RETURNS bytea
pgp_sym_decrypt(msg bytea, psw text [, options text]) RETURNS text
pgp_sym_decrypt_bytea(msg bytea, psw text [, options text]) RETURNS bytea
```

**PGP-шифрование (асимметричное, по ключу GPG):**

```sql path=null start=null
pgp_pub_encrypt(data text, key bytea [, options text]) RETURNS bytea
pgp_pub_decrypt(msg bytea, key bytea [, psw text [, options text]]) RETURNS text
```

**ASCII-armor:**

```sql path=null start=null
armor(data bytea [, keys text[], values text[]]) RETURNS text
dearmor(data text) RETURNS bytea
```

**Случайные данные:**

```sql path=null start=null
gen_random_bytes(count integer) RETURNS bytea
gen_random_uuid() RETURNS uuid
```

### Роль в RAG/AI-стеке
Хеширование паролей пользователей (`crypt`/`gen_salt` с bcrypt), целостность данных (`digest`/`hmac`), при необходимости — прямое PGP-шифрование отдельных полей. Базовый крипто-слой, не требующий внешних библиотек; более продвинутое шифрование/управление ключами даёт `pgsodium`.

### Требования
- **`shared_preload_libraries`:** нет.
- **`CREATE EXTENSION`:** да — `CREATE EXTENSION pgcrypto;`
- **Схема по умолчанию:** `public`.
- **Зависимости от других расширений:** нет.
- **Замечание:** функция `pgp_sym_encrypt` использует OpenSSL/внутренние реализации; на некоторых сборках части алгоритмов могут быть ограничены настройками OpenSSL.

### Установка в нашем образе
**Встроено в PostgreSQL (contrib)** — входит в стандартную поставку `supabase/postgres:17.6.1.148` через `postgresql-contrib`. Дополнительных шагов по установке не требуется; нужен только `CREATE EXTENSION` в каждой БД, где используется.

---

## 3. pgsodium

**Репозиторий:** https://github.com/michelp/pgsodium
**Версия (актуальная стабильная):** v3.1.11

### Назначение
Криптографическая библиотека для PostgreSQL поверх [libsodium](https://doc.libsodium.org/) (>= 1.0.18). Помимо прямого доступа к libsodium, предоставляет **Server Key Management** (корневой ключ загружается в память при старте и **недоступен из SQL**) и **Transparent Column Encryption (TCE)** — автоматическое шифрование/расшифрование столбцов через `SECURITY LABEL`.

### Ключевой SQL API

**Случайные данные:**

```sql path=null start=null
randombytes_random()                        RETURNS integer
randombytes_uniform(upper_bound integer)    RETURNS integer
randombytes_buf(size integer)               RETURNS bytea
```

**Симметричное шифрование (authenticated):**

```sql path=null start=null
crypto_secretbox_keygen()                       RETURNS bytea
crypto_secretbox_noncegen()                     RETURNS bytea
crypto_secretbox(message bytea, nonce bytea, key bytea)     RETURNS bytea
crypto_secretbox_open(ct bytea, nonce bytea, key bytea)     RETURNS bytea
```

**Шифрование с открытым ключом (`crypto_box`):**

```sql path=null start=null
crypto_box_new_keypair()   RETURNS (public bytea, secret bytea)
crypto_box_noncegen()      RETURNS bytea
crypto_box(message bytea, nonce bytea, public bytea, secret bytea)        RETURNS bytea
crypto_box_open(ct bytea, nonce bytea, public bytea, secret bytea)        RETURNS bytea
crypto_box_seal(message bytea, public bytea)   RETURNS bytea
crypto_box_seal_open(ct bytea, public bytea, secret bytea) RETURNS bytea
```

**ЭЦП (`crypto_sign`):**

```sql path=null start=null
crypto_sign_new_keypair()                  RETURNS (public bytea, secret bytea)
crypto_sign(message bytea, key bytea)      RETURNS bytea              -- combined
crypto_sign_open(signed bytea, key bytea)  RETURNS bytea
crypto_sign_detached(message bytea, key bytea)             RETURNS bytea
crypto_sign_verify_detached(sig bytea, message bytea, key bytea) RETURNS boolean
```

**Хеширование:**

```sql path=null start=null
crypto_generichash(data bytea [, key bytea]) RETURNS bytea
crypto_shorthash(data bytea, key bytea)       RETURNS bytea
```

**Хеширование паролей:**

```sql path=null start=null
crypto_pwhash_saltgen()                                 RETURNS bytea
crypto_pwhash(password bytea, salt bytea)               RETURNS bytea
crypto_pwhash_str(password text)                        RETURNS text
crypto_pwhash_str_verify(hashed text, password text)    RETURNS boolean
```

**Вывод ключей (KDF) и Server Key Management:**

```sql path=null start=null
derive_key(key_id bigint, key_size int DEFAULT 32, context bytea DEFAULT 'pgsodium') RETURNS bytea
crypto_kdf_keygen()                                  RETURNS bytea
crypto_kdf_derive_from_key(subkey_len int, subkey_id bigint, context bytea, key bytea) RETURNS bytea
```

**Key Management API (требует Server Key Management) — управляемые ключи с UUID:**

```sql path=null start=null
pgsodium.create_key(key_type text DEFAULT 'aead-det',
                    name text DEFAULT NULL,
                    raw_key bytea DEFAULT NULL,
                    key_context bytea DEFAULT 'pgsodium',
                    parent_key uuid DEFAULT NULL,
                    expires timestamptz DEFAULT NULL,
                    associated_data text DEFAULT '') RETURNS pgsodium.key
-- Поддерживаемые key_type: aead-det, aead-ietf, hmacsha512, hmacsha256,
--   auth, shorthash, generichash, kdf, secretbox, secretstream,
--   ipcrypt-det / ipcrypt-pfx / ipcrypt-nd / ipcrypt-ndx
```

Таблица `pgsodium.key` и представление `pgsodium.valid_keys` (фильтрует невалидные/просроченные). Роли: `pgsodium_keyiduser` (только по UUID) и `pgsodium_keymaker` (доступ к сырым ключам).

**Transparent Column Encryption (TCE):**

```sql path=null start=null
-- Один ключ на весь столбец:
SECURITY LABEL FOR pgsodium ON COLUMN private.users.secret
  IS 'ENCRYPT WITH KEY ID dfc44293-fa78-4a1a-9ef9-7e600e63e101';

-- Один ключ на строку (с nonce и associated data):
SECURITY LABEL FOR pgsodium ON COLUMN private.users.secret
  IS 'ENCRYPT WITH KEY COLUMN key_id NONCE nonce ASSOCIATED (id, associated_data)';
```

При таких метках pgsodium автоматически создаёт триггер шифрования и расшифровывающее view. Алгоритм по умолчанию для TCE — nonceless `crypto_aead_det_xchacha20()`.

### Роль в RAG/AI-стеке
Криптография «нового поколения» (XChaCha20, секретные/открытые ключи, TCE) для защиты PII и чувствительных данных. Серверное управление ключами позволяет хранить только ID ключей (`bigint`/`uuid`), а не сами ключи — кража дампа БД не даёт атакующему ключей. Является фундаментом для расширения `vault` (см. ниже).

### Требования
- **`shared_preload_libraries`:** **да** (`pgsodium`) — обязательно для Server Key Management, Key Management API и TCE. Базовые криптофункции работают и без предзагрузки, но тогда нужно своё внешнее управление ключами.
- **`CREATE EXTENSION`:** да — `CREATE EXTENSION pgsodium;` (автоматически создаёт схему `pgsodium`; расширение строго требует именно такое имя схемы из-за защиты от `search_path`-атак).
- **Схема по умолчанию:** `pgsodium`.
- **Зависимости:** libsodium >= 1.0.18 (+ dev-заголовки), заголовки PostgreSQL. PostgreSQL >= 14 (для старых версий — ветка pgsodium 2.0.x).
- **Конфигурация серверного ключа:** параметр `pgsodium.getkey_script = '/path/to/script'` (скрипт возвращает 32-байтовый libsodium-ключ). Поставляются примеры для `/dev/urandom`, AWS KMS, GCP KMS, Doppler, Zymkey HSM.

### Установка в нашем образе
**Предустановлено в базовом образе `supabase/postgres`** (Supabase использует pgsodium как ядро своей системы шифрования-at-rest). libsodium, как правило, уже присутствует в образе. Для кастомной сборки: `make install` из исходников либо `pgxn install pgsodium`.

### Версия
v3.1.11 (последний тег на момент составления).

---

## 4. vault (Supabase Vault)

**Репозиторий:** https://github.com/supabase/vault
**Версия (актуальная стабильная):** v0.3.1
**Имя расширения в SQL:** `supabase_vault`

### Назначение
Безопасное хранение секретов (API-ключей, токенов, паролей) в зашифрованном виде прямо в базе. Поверх `pgsodium` реализует таблицу `vault.secrets`, где значение `secret` хранится зашифрованным (через TCE pgsodium), а расшифровка выполняется on-the-fly через специальное view `vault.decrypted_secrets`.

### Ключевой SQL API

**Добавление секрета:**

```sql path=null start=null
-- Прямая вставка в таблицу:
INSERT INTO vault.secrets (secret) VALUES ('s3kre3t_k3y') RETURNING *;

-- Через функцию (возвращает UUID нового секрета):
vault.create_secret(secret text, name text DEFAULT NULL, description text DEFAULT NULL) RETURNS uuid

SELECT vault.create_secret('OPENAI_API_KEY_value', 'openai_key', 'Production OpenAI key');
```

**Чтение (расшифровка on-the-fly через view):**

```sql path=null start=null
-- Сама таблица хранит шифртекст:
SELECT id, name, secret, key_id, nonce FROM vault.secrets;

-- Расшифрованное значение доступно только через view:
SELECT id, name, decrypted_secret FROM vault.decrypted_secrets
WHERE name = 'openai_key';
```

**Обновление секрета:**

```sql path=null start=null
vault.update_secret(secret_id uuid, new_secret text DEFAULT NULL,
                    new_name text DEFAULT NULL, new_description text DEFAULT NULL) RETURNS void

SELECT vault.update_secret('7095d222-...', 'rotated_key_value', NULL, 'Rotated 2026-07');
```

Столбцы таблицы `vault.secrets`: `id` (uuid), `name` (уникальное, опц.), `description` (опц.), `secret` (шифртекст), `key_id` (uuid ключа pgsodium), `nonce` (bytea), `created_at`, `updated_at`.

### Роль в RAG/AI-стеке
Центральное хранилище секретов LLM-стека: API-ключи провайдеров (OpenAI, Anthropic и т.п.), токены доступа к внешним API, приватные ключи шифрования. Секреты хранятся зашифрованными на диске и в дамперах/репликах, а приложение получает их в открытом виде только через `vault.decrypted_secrets` (доступ к которому регулируется правами SQL). Избавляет от хардкода ключей в коде/конфигах и контейнерах.

### Требования
- **`shared_preload_libraries`:** **да** (косвенно). `vault` зависит от `pgsodium` и использует его TCE + серверное управление ключами, поэтому в образе фактически требуется `shared_preload_libraries = pgsodium` + настроенный `pgsodium.getkey_script`. Сам `vault` в `shared_preload_libraries` отдельно добавлять не нужно.
- **`CREATE EXTENSION`:** да — `CREATE EXTENSION supabase_vault CASCADE;` (`CASCADE` тянет за собой `pgsodium`).
- **Схема по умолчанию:** `vault`.
- **Зависимости:** расширение `pgsodium` (с настроенным серверным ключом).
- **Безопасность логов:** при использовании Vault настоятельно рекомендуется отключить логирование операторов, иначе секреты попадут в логи в открытом виде: `ALTER SYSTEM SET log_statement = 'none';` (или ограничить через политики логирования).

### Установка в нашем образе
**Предустановлено в базовом образе `supabase/postgres`** и включено по умолчанию (Supabase включает Vault в свой стек). Включается одним `CREATE EXTENSION supabase_vault CASCADE;`.

### Версия
v0.3.1 (последний тег на момент составления).

---

## Сводка по требованиям предзагрузки и зависимостей

| Расширение | `shared_preload_libraries` | `CREATE EXTENSION` | Схема | Зависимости |
| --- | --- | --- | --- | --- |
| pg_jsonschema | нет | да | `public` | нет |
| pgcrypto | нет | да | `public` | нет |
| pgsodium | **да** (`pgsodium`) | да | `pgsodium` | libsodium >= 1.0.18 |
| vault (supabase_vault) | **да** (через pgsodium) | да (`CASCADE`) | `vault` | pgsodium (+ серверный ключ) |

### Порядок инициализации в образе
1. В `postgresql.conf` / `docker run -c ...`: `shared_preload_libraries = 'pgsodium'` (и любые другие требующие предзагрузки расширения проекта).
2. Настроить `pgsodium.getkey_script` (скрипт получения 32-байтового корневого ключа) — иначе TCE/vault работать не будут.
3. В каждой целевой БД: `CREATE EXTENSION pgcrypto;`, `CREATE EXTENSION pg_jsonschema;`, `CREATE EXTENSION pgsodium;`, `CREATE EXTENSION supabase_vault CASCADE;`.
4. Отключить `log_statement` либо ограничить логирование, чтобы секреты не утекали в логи.

### Возможные конфликты / нюансы
- pgsodium **строго** требует имя схемы `pgsodium` (защита от `search_path`); всегда вызывайте функции по полному имени (`pgsodium.create_key(...)`).
- `pgcrypto` и `pgsodium` частично дублируют функциональность (хеширование, шифрование). Для паролей предпочтительнее `crypt`/`gen_salt` (pgcrypto) или `crypto_pwhash_str` (pgsodium); для шифрования столбцов — TCE pgsodium.
- `vault` полагается на шифрование столбца `secret` через pgsodium TCE; без корректно настроенного серверного ключа pgsodium Vault неработоспособен.
- `pg_jsonschema`: актуальный API — `jsonb_matches_schema`/`json_matches_schema` (имя `jsonschema_matches`, упомянутое в задании, в текущих релизах не существует).
