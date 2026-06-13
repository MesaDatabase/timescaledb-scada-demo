-- ============================================================================
-- Script:        05_hypertable_chunk_inventory.sql
-- Folder:        01_monitoring
-- Purpose:       One row per chunk, with the user-facing object it belongs to
--                spelled out (parent_object / parent_type), the on-disk
--                relation name (compressed chunks live under a different
--                relation), size, compression status, and time range covered.
--                Continuous-aggregate chunks live under an internal
--                _materialized_hypertable_N; this resolves them back to the
--                friendly view name (e.g. scada.readings_1h) so you can tell
--                which chunk belongs to point_readings, control_requests, a
--                continuous aggregate, etc.
-- Safe in prod:  YES (read-only)
-- Requires:      TimescaleDB (timescaledb_information.chunks +
--                _timescaledb_catalog.chunk for the compressed-chunk mapping +
--                _timescaledb_catalog.continuous_agg for the cagg name map)
-- Compatibility: TimescaleDB 2.x (incl. 2.27)
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
    uc.hypertable_id,                             -- owning hypertable (internal)
    cc.schema_name      AS compressed_chunk_schema,
    cc.table_name       AS compressed_chunk_name  -- actual on-disk relation when compressed
  FROM timescaledb_information.chunks c
  LEFT JOIN _timescaledb_catalog.chunk uc
    ON uc.schema_name = c.chunk_schema
   AND uc.table_name  = c.chunk_name
  LEFT JOIN _timescaledb_catalog.chunk cc
    ON cc.id = uc.compressed_chunk_id
),
-- Resolve each chunk's owning hypertable to a user-facing name. For a
-- continuous aggregate, the chunk's hypertable is an internal
-- _materialized_hypertable_N; continuous_agg maps it to the view the user
-- actually queries. For a plain hypertable, the parent is the hypertable.
parent AS (
  SELECT
    ci.*,
    (ca.mat_hypertable_id IS NOT NULL)                  AS is_cagg,
    COALESCE(ca.user_view_schema, ci.hypertable_schema) AS parent_schema,
    COALESCE(ca.user_view_name,   ci.hypertable_name)   AS parent_name
  FROM chunk_info ci
  LEFT JOIN _timescaledb_catalog.continuous_agg ca
    ON ca.mat_hypertable_id = ci.hypertable_id
)
SELECT
  now() AS as_of,
  format('%I.%I', p.parent_schema, p.parent_name) AS parent_object,
  CASE WHEN p.is_cagg THEN 'continuous_aggregate' ELSE 'hypertable' END AS parent_type,
  p.original_chunk_name,
  CASE
    WHEN p.is_compressed THEN p.compressed_chunk_name
    ELSE p.original_chunk_name
  END AS on_disk_chunk_name,
  ROUND(
    pg_total_relation_size(
      format('%I.%I',
        CASE WHEN p.is_compressed THEN p.compressed_chunk_schema ELSE p.chunk_schema END,
        CASE WHEN p.is_compressed THEN p.compressed_chunk_name   ELSE p.original_chunk_name END
      )::regclass
    ) / 1024.0 / 1024 / 1024
  , 3) AS chunk_gb,
  pg_size_pretty(
    pg_total_relation_size(
      format('%I.%I',
        CASE WHEN p.is_compressed THEN p.compressed_chunk_schema ELSE p.chunk_schema END,
        CASE WHEN p.is_compressed THEN p.compressed_chunk_name   ELSE p.original_chunk_name END
      )::regclass
    )
  ) AS chunk_size,
  CASE WHEN p.is_compressed THEN 'Compressed' ELSE 'Uncompressed' END AS compression_status,
  p.range_start,
  p.range_end,
  (p.range_end - p.range_start) AS chunk_interval
FROM parent p
ORDER BY p.parent_schema, p.parent_name, p.range_start DESC;
