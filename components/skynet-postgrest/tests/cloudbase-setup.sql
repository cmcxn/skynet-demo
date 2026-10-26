-- Applied individually via tcb db execute to the configured CloudBase PG env.
-- Do not rerun against an existing table; inspect its schema first.
CREATE TABLE public.skynet_postgrest_test_20261026 (
    id text PRIMARY KEY,
    task text NOT NULL,
    done boolean NOT NULL DEFAULT false
);
ALTER TABLE public.skynet_postgrest_test_20261026 ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.skynet_postgrest_test_20261026 TO service_role;
