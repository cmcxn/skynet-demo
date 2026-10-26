-- Execute each statement separately via the CloudBase management SQL API.
-- Dedicated fixture: no changes to application tables or public access policies.
CREATE TABLE public.skynet_pgvector_test_20261026 (
    run_id text NOT NULL,
    label text NOT NULL,
    embedding public.vector(3) NOT NULL,
    PRIMARY KEY (run_id, label)
);
-- statement boundary
ALTER TABLE public.skynet_pgvector_test_20261026 ENABLE ROW LEVEL SECURITY;
-- statement boundary
GRANT SELECT, INSERT, UPDATE, DELETE ON public.skynet_pgvector_test_20261026 TO service_role;
-- statement boundary
CREATE FUNCTION public.skynet_pgvector_match_20261026(
    query_embedding public.vector, test_run text, metric text, match_count integer
) RETURNS TABLE(label text, distance double precision)
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF metric NOT IN ('l2', 'cosine', 'inner_product') OR metric IS NULL THEN
        RAISE EXCEPTION 'unsupported vector metric' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
        SELECT t.label,
            CASE metric
                WHEN 'l2' THEN t.embedding <-> query_embedding
                WHEN 'cosine' THEN t.embedding <=> query_embedding
                WHEN 'inner_product' THEN t.embedding <#> query_embedding
            END AS distance
        FROM public.skynet_pgvector_test_20261026 AS t
        WHERE t.run_id = test_run
        ORDER BY 2, t.label
        LIMIT greatest(1, least(match_count, 20));
END
$$;
-- statement boundary
REVOKE ALL ON FUNCTION public.skynet_pgvector_match_20261026(public.vector,text,text,integer) FROM PUBLIC;
-- statement boundary
GRANT EXECUTE ON FUNCTION public.skynet_pgvector_match_20261026(public.vector,text,text,integer) TO service_role;
