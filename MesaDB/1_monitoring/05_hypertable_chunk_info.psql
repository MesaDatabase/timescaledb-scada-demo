-- ============================================================================
-- Script:        05_hypertable_chunk_inventory.sql
-- Folder:        01_monitoring
-- Purpose:       One row per chunk: parent hypertable, on-disk relation name
--                (compressed chunks live under a different relation), size,
--                compression status, and time range covered.
-- Safe in prod:  YES (read-only)
-- Requires:      TimescaleDB (timescaledb_information.chunks +
--                _timescaledb_catalog.chunk for the compressed-chunk mapping)
-- Compatibility: TimescaleDB 2.x
-- Notes:         pg_total_relation_size() on the *original* chunk name of a
--                compressed chunk reports near-zero -- the data lives in the
--                mapped compressed relation. That mapping is the reason for
--                the catalog joins below.
-- ============================================================================

WITH chunk_info AS (
  SELECT
    c.chunk_schema,
    c.chunk_name        AS original_chunk_name,   -- uncompressed relation name
    c.hypertable_schema,
    c.hypertable_name,
    c.is_compressed,
    c.range_start,
    c.range_end,
    cc.schema_name      AS compressed_chunk_schema,
    cc.table_name       AS compressed_chunk_name  -- actual on-disk relation when compressed
  FROM timescaledb_information.chunks c
  LEFT JOIN _timescaledb_catalog.chunk uc
    ON uc.schema_name = c.chunk_schema
   AND uc.table_name  = c.chunk_name
  LEFT JOIN _timescaledb_catalog.chunk cc
    ON uc.compressed_chunk_id = cc.id
)
SELECT
  now() AS as_of,
  format('%I.%I', ci.hypertable_schema, ci.hypertable_name) AS hypertable,
  ci.original_chunk_name,
  CASE
    WHEN ci.is_compressed THEN ci.compressed_chunk_name
    ELSE ci.original_chunk_name
  END AS on_disk_chunk_name,
  ROUND(
    pg_total_relation_size(
      format('%I.%I',
        CASE WHEN ci.is_compressed THEN ci.compressed_chunk_schema ELSE ci.chunk_schema END,
        CASE WHEN ci.is_compressed THEN ci.compressed_chunk_name   ELSE ci.original_chunk_name END
      )::regclass
    ) / 1024.0 / 1024 / 1024
  , 3) AS chunk_gb,
  pg_size_pretty(
    pg_total_relation_size(
      format('%I.%I',
        CASE WHEN ci.is_compressed THEN ci.compressed_chunk_schema ELSE ci.chunk_schema END,
        CASE WHEN ci.is_compressed THEN ci.compressed_chunk_name   ELSE ci.original_chunk_name END
      )::regclass
    )
  ) AS chunk_size,
  CASE WHEN ci.is_compressed THEN 'Compressed' ELSE 'Uncompressed' END AS compression_status,
  ci.range_start,
  ci.range_end,
  (ci.range_end - ci.range_start) AS chunk_interval
FROM chunk_info ci
ORDER BY ci.hypertable_schema, ci.hypertable_name, ci.range_start DESC;