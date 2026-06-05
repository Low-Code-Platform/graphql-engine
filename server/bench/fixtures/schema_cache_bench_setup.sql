-- Benchmark fixture: 1 source, 5 schemas × 200 tables = 1 000 tables total.
-- Idempotent — safe to re-run.
DO $$
DECLARE
  s   text;
  i   int;
BEGIN
  FOREACH s IN ARRAY ARRAY['s1','s2','s3','s4','s5'] LOOP
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', s);
    FOR i IN 1..200 LOOP
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I.tbl_%s (id serial PRIMARY KEY, payload text)',
        s, i
      );
    END LOOP;
  END LOOP;
END$$;
