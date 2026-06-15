-- Transfer ownership of noetl.event + all its partitions to the NoETL app DB
-- role (`noetl`), so the server can DROP old partitions for drop-based event
-- retention (noetl/ai-meta#96).  DROP requires ownership; the app role usually
-- has only DELETE/INSERT/SELECT, so without this the scheduled-cleanup logs a
-- WARN and drops nothing.
--
-- Run ONCE per cluster as a SUPERUSER (or the current table owner).  Idempotent
-- and cheap (catalog-only); re-run after new event partitions are added.  On
-- managed Postgres (Cloud SQL — GKE prod) run it with the instance superuser;
-- the app `noetl` user cannot transfer ownership to itself.
--
--   psql -U <superuser> -d noetl -f event-partition-ownership.sql

DO $$
DECLARE r record;
BEGIN
    EXECUTE 'ALTER TABLE noetl.event OWNER TO noetl';
    FOR r IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE n.nspname = 'noetl' AND p.relname = 'event'
    LOOP
        EXECUTE format('ALTER TABLE noetl.%I OWNER TO noetl', r.relname);
    END LOOP;
    RAISE NOTICE 'noetl.event + partitions now owned by noetl';
END $$;
