  -- ============================================================================
  -- Script:        04_table_and_hypertable_sizes.sql
  -- Folder:        01_monitoring
  -- Purpose:       One row per user-facing object, largest first:
  --                  - hypertables: base + ALL chunks rolled together, with
  --                    compressed vs uncompressed chunk counts and size split
  --                  - continuous aggregates: their materialized hypertable's
  --                    chunks, labeled with the friendly view name
  --                  - regular tables / matviews: total relation size
  --                The internal hypertables TimescaleDB creates under the hood
  --                (_compressed_hypertable_*, _materialized_hypertable_*) are
  --                NOT shown as their own rows -- their bytes roll up into the
  --                hypertable or continuous aggregate they belong to, so there
  --                is no double counting.
  --                Query 2 lists the largest indexes with usage counts, to
  --                surface bloated or never-scanned indexes.
  -- Output:        Sizes in GiB (bytes / 1024^3). pg_total_relation_size()
  --                includes heap + indexes + TOAST.
  -- Safe in prod:  YES (read-only)
  -- Requires:      TimescaleDB installed (reads _timescaledb_catalog for the
  --                chunk -> compressed-chunk mapping and the continuous-agg map).
  --                For a plain PostgreSQL server, run only Query 2.
  -- Compatibility: PostgreSQL 12+ / TimescaleDB 2.x (incl. 2.27)
  -- ============================================================================

  -- Query 1: tables, hypertables, and continuous aggregates by total size.
  WITH
  -- Storage-bearing hypertables = user hypertables + continuous-aggregate
  -- materialized hypertables. compression_state = 2 marks an *internal*
  -- compressed hypertable; skip those as standalone objects -- their bytes are
  -- attributed to the parent below via the chunk -> compressed-chunk mapping.
  -- A row joining to continuous_agg is a continuous aggregate's materialized
  -- hypertable, which we relabel with its user-facing view name.
  ht AS (
    SELECT
      h.id                               AS hypertable_id,
      h.schema_name                      AS ht_schema,
      h.table_name                       AS ht_name,
      ca.user_view_schema,
      ca.user_view_name,
      (ca.mat_hypertable_id IS NOT NULL) AS is_cagg
    FROM _timescaledb_catalog.hypertable h
    LEFT JOIN _timescaledb_catalog.continuous_agg ca
      ON ca.mat_hypertable_id = h.id
    WHERE h.compression_state <> 2
  ),
  -- Every chunk of those hypertables, resolved to the relation that actually
  -- holds its bytes on disk: the mapped compressed chunk if the chunk has been
  -- compressed, otherwise the chunk itself. Chunks of internal compressed
  -- hypertables are never iterated here (their parents were excluded above),
  -- so each compressed chunk is counted exactly once -- under its parent.
  chunks AS (
    SELECT
      h.hypertable_id,
      (uc.compressed_chunk_id IS NOT NULL) AS is_compressed,
      CASE WHEN uc.compressed_chunk_id IS NOT NULL
           THEN cc.schema_name ELSE uc.schema_name END AS measure_schema,
      CASE WHEN uc.compressed_chunk_id IS NOT NULL
           THEN cc.table_name  ELSE uc.table_name  END AS measure_name
    FROM _timescaledb_catalog.chunk uc
    JOIN ht h ON h.hypertable_id = uc.hypertable_id
    LEFT JOIN _timescaledb_catalog.chunk cc
      ON cc.id = uc.compressed_chunk_id
  ),
  chunk_sizes AS (
    SELECT
      hypertable_id,
      COUNT(*) FILTER (WHERE NOT is_compressed) AS uncompressed_chunk_count,
      COUNT(*) FILTER (WHERE is_compressed)     AS compressed_chunk_count,
      COALESCE(SUM(pg_total_relation_size(format('%I.%I', measure_schema, measure_name)::regclass))
                 FILTER (WHERE NOT is_compressed), 0) AS uncompressed_bytes,
      COALESCE(SUM(pg_total_relation_size(format('%I.%I', measure_schema, measure_name)::regclass))
                 FILTER (WHERE is_compressed), 0)     AS compressed_bytes
    FROM chunks
    GROUP BY hypertable_id
  ),
  hypertable_totals AS (
    SELECT
      CASE WHEN h.is_cagg THEN h.user_view_schema ELSE h.ht_schema END AS schema_name,
      CASE WHEN h.is_cagg THEN h.user_view_name   ELSE h.ht_name   END AS rel_name,
      (CASE WHEN h.is_cagg THEN 'continuous_aggregate' ELSE 'hypertable' END)::text AS object_type,
      pg_total_relation_size(format('%I.%I', h.ht_schema, h.ht_name)::regclass)
        + COALESCE(cs.uncompressed_bytes, 0)
        + COALESCE(cs.compressed_bytes, 0)        AS total_bytes,
      pg_total_relation_size(format('%I.%I', h.ht_schema, h.ht_name)::regclass)
                                                  AS table_and_metadata_bytes,
      COALESCE(cs.uncompressed_bytes, 0)          AS uncompressed_chunks_bytes,
      COALESCE(cs.compressed_bytes, 0)            AS compressed_chunks_bytes,
      COALESCE(cs.uncompressed_chunk_count, 0)    AS uncompressed_chunk_count,
      COALESCE(cs.compressed_chunk_count, 0)      AS compressed_chunk_count
    FROM ht h
    LEFT JOIN chunk_sizes cs ON cs.hypertable_id = h.hypertable_id
  ),
  regular_tables AS (
    SELECT
      n.nspname                       AS schema_name,
      c.relname                       AS rel_name,
      'table'::text                   AS object_type,
      pg_total_relation_size(c.oid)   AS total_bytes,
      pg_total_relation_size(c.oid)   AS table_and_metadata_bytes,
      0::bigint AS uncompressed_chunks_bytes,
      0::bigint AS compressed_chunks_bytes,
      0::bigint AS uncompressed_chunk_count,
      0::bigint AS compressed_chunk_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN _timescaledb_catalog.hypertable ht
      ON ht.schema_name = n.nspname
     AND ht.table_name  = c.relname
    WHERE c.relkind IN ('r', 'm')          -- ordinary tables + materialized views
      AND c.relpersistence <> 't'          -- skip other sessions' TEMP tables
      AND ht.id IS NULL                    -- hypertables handled above
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND n.nspname NOT LIKE '\_timescaledb\_%' ESCAPE '\'
      AND n.nspname NOT LIKE 'pg\_temp\_%' ESCAPE '\'
      AND n.nspname NOT LIKE 'pg\_toast\_temp\_%' ESCAPE '\'
  )
  SELECT
    now() AS as_of,
    q.schema_name,
    q.rel_name,
    q.object_type,
    ROUND(q.total_bytes / 1024.0 / 1024 / 1024, 3)               AS total_gb,
    ROUND(q.table_and_metadata_bytes / 1024.0 / 1024 / 1024, 3)  AS table_and_metadata_gb,
    ROUND(q.uncompressed_chunks_bytes / 1024.0 / 1024 / 1024, 3) AS uncompressed_chunks_gb,
    ROUND(q.compressed_chunks_bytes / 1024.0 / 1024 / 1024, 3)   AS compressed_chunks_gb,
    q.uncompressed_chunk_count,
    q.compressed_chunk_count
  FROM (
    SELECT * FROM hypertable_totals
    UNION ALL
    SELECT * FROM regular_tables
  ) q
  ORDER BY q.total_bytes DESC, q.schema_name, q.rel_name
  LIMIT 200;

  -- Query 2: largest indexes with usage counts (works on plain PostgreSQL too).
  -- idx_scan = 0 on a large, long-lived index suggests it may be droppable --
  -- verify against replicas and recent workload before acting. Note: chunk
  -- indexes appear individually under _timescaledb_internal.
  SELECT
    now()                                       AS as_of,
    s.schemaname                                AS schema_name,
    s.relname                                   AS table_name,
    s.indexrelname                              AS index_name,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
    ROUND(pg_relation_size(s.indexrelid) / 1024.0 / 1024 / 1024, 3) AS index_gb,
    s.idx_scan                                  AS index_scans,
    s.idx_tup_read                              AS tuples_read,
    s.idx_tup_fetch                             AS tuples_fetched
  FROM pg_stat_user_indexes s
  ORDER BY pg_relation_size(s.indexrelid) DESC
  LIMIT 50;
