CREATE ROLE web_anon NOLOGIN;
CREATE TABLE public.skynet_postgrest_test_20261026 (
    id text PRIMARY KEY,
    task text NOT NULL,
    done boolean NOT NULL DEFAULT false
);
GRANT USAGE ON SCHEMA public TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.skynet_postgrest_test_20261026 TO web_anon;
