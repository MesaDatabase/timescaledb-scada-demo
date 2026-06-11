-- ============================================================================
-- Script:        04_table_and_hypertable_sizes.sql
-- Folder:        01_monitoring
-- Purpose:       One row per relation, largest first:
--                  - hypertables: base + all chunks, with compressed vs
--                    uncompressed chunk counts and size breakdown
--                  - regular tables / matviews: total relation size
--                Query 2 lists the largest indexes with usage counts, to
--                surface bloated or never-scanned indexes.
-- Output:        Sizes in GiB (bytes / 1024^3). pg_total_relation_size()
--                includes heap + indexes + TOAST.
-- Safe in prod:  YES (read-only)
-- Requires:      TimescaleDB installed (reads _timescaledb_catalog for the
--                chunk -> compressed-chunk mapping). For a plain PostgreSQL
--                server, run only Query 2 or drop the hypertable CTEs.
-- Compatibility: PostgreSQL 12+ / TimescaleDB 2.x
-- ============================================================================

-- Query 1: tables and hypertables by total size
WITH rels AS (
  SELECT
    c.oid,
    n.nspname AS schema_name,
    c.relname AS rel_name,
    c.relkind
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
),
ht AS (
  SELECT
    id          AS hypertable_id,
    schema_name AS hypertable_schema,
    table_name  AS hypertable_name
  FROM _timescaledb_catalog.hypertable
),
ht_base AS (
  SELECT
    h.hypertable_id,
    h.hypertable_schema,
    h.hypertable_name,
    pg_total_relation_size(format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass) AS base_bytes
  FROM ht h
),
chunks AS (
  SELECT
    h.hypertable_id,
    h.hypertable_schema,
    h.hypertable_name,
    uc.schema_name AS uncompressed_chunk_schema,
    uc.table_name  AS uncompressed_chunk_name,
    cc.schema_name AS compressed_chunk_schema,
    cc.table_name  AS compressed_chunk_name,
    (uc.compressed_chunk_id IS NOT NULL) AS is_compressed
  FROM _timescaledb_catalog.chunk uc
  JOIN ht h ON h.hypertable_id = uc.hypertable_id
  LEFT JOIN _timescaledb_catalog.chunk cc
    ON uc.compressed_chunk_id = cc.id
),
chunk_sizes AS (
  SELECT
    hypertable_id,
    hypertable_schema,
    hypertable_name,
    COUNT(*) FILTER (WHERE NOT is_compressed) AS uncompressed_chunk_count,
    COUNT(*) FILTER (WHERE is_compressed)     AS compressed_chunk_count,
    COALESCE(
      SUM(pg_total_relation_size(format('%I.%I', uncompressed_chunk_schema, uncompressed_chunk_name)::regclass))
        FILTER (WHERE NOT is_compressed),
      0
    ) AS uncompressed_bytes,
    COALESCE(
      SUM(pg_total_relation_size(format('%I.%I', compressed_chunk_schema, compressed_chunk_name)::regclass))
        FILTER (WHERE is_compressed),
      0
    ) AS compressed_bytes
  FROM chunks
  GROUP BY hypertable_id, hypertable_schema, hypertable_name
),
hypertable_totals AS (
  SELECT
    b.hypertable_schema AS schema_name,
    b.hypertable_name   AS rel_name,
    TRUE                AS is_hypertable,
    (b.base_bytes
      + COALESCE(cs.uncompressed_bytes, 0)
      + COALESCE(cs.compressed_bytes, 0))     AS total_bytes,
    b.base_bytes                              AS table_and_metadata_bytes,
    COALESCE(cs.uncompressed_bytes, 0)        AS uncompressed_chunks_bytes,
    COALESCE(cs.compressed_bytes, 0)          AS compressed_chunks_bytes,
    COALESCE(cs.uncompressed_chunk_count, 0)  AS uncompressed_chunk_count,
    COALESCE(cs.compressed_chunk_count, 0)    AS compressed_chunk_count
  FROM ht_base b
  LEFT JOIN chunk_sizes cs ON cs.hypertable_id = b.hypertable_id
),
regular_tables AS (
  SELECT
    r.schema_name,
    r.rel_name,
    FALSE                          AS is_hypertable,
    pg_total_relation_size(r.oid)  AS total_bytes,
    pg_total_relation_size(r.oid)  AS table_and_metadata_bytes,
    0::bigint AS uncompressed_chunks_bytes,
    0::bigint AS compressed_chunks_bytes,
    0::bigint AS uncompressed_chunk_count,
    0::bigint AS compressed_chunk_count
  FROM rels r
  LEFT JOIN ht
    ON ht.hypertable_schema = r.schema_name
   AND ht.hypertable_name   = r.rel_name
  WHERE ht.hypertable_id IS NULL
    AND r.relkind IN ('r', 'm')
    AND r.schema_name NOT LIKE '\_timescaledb\_%' ESCAPE '\'
)
SELECT
  now() AS as_of,
  q.schema_name,
  q.rel_name,
  q.is_hypertable,
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