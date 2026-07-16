-- 06. Процедурные языки и AI-интеграция.
-- BAML — это Python-библиотека (pip install baml-py), НЕ расширение PG;
-- вызывается из тела функций plpython3u. Здесь только язык.
\echo '== 06 languages =='

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS plpython3u;   -- untrusted: создавать функции может только суперпользователь
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'plpython3u: %', SQLERRM; END $$;
-- Предостережение: не выдавать CREATE ролям приложений; для делегирования — SECURITY DEFINER
-- с жёсткой валидацией. libpython3 должна совпадать с Python, куда ставится baml-py.
