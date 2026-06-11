-- ============================================================================
-- Script:        07_compression_overview.sql
-- Folder:        01_monitoring
-- Purpose:       Compression posture across all hypertables:
--                  Query 1 = settings (segmentby / orderby) per hypertable
--                  Query 2 = compression progress by chunk counts
--                  Query 3 = actual before/after bytes and compression ratio
-- Safe in prod:  YES (read-only; Query 3 scans compressed-chunk stats)
-- Requires:      TimescaleDB with compression in use
--                (timescaledb_information views + hypertable_compression_stats)
-- Compatibility: TimescaleDB 2.x
-- Notes:         A hypertable with settings but 0% chunks compressed usually
--                means the compression policy is missing, disabled, or failing
--                -- cross-check with 06_bgw_job_stats.sql.
-- ============================================================================

-- Query 1: compression settings per hypertable
WITH settings AS (
  SELECT
    hypertable_schema,
    hypertable_name,
    string_agg(attname, ', ' ORDER BY segmentby_column_index)
      FILTER (WHERE segmentby_column_index IS NOT NULL) AS segmentby,
    string_agg(
      attname
      || CASE WHEN orderby_asc        THEN ' ASC'         ELSE ' DESC'       END
      || CASE WHEN orderby_nullsfirst THEN ' NULLS FIRST' ELSE ' NULLS LAST' END,
      ', ' ORDER BY orderby_column_index
    ) FILTER (WHERE orderby_column_index IS NOT NULL) AS orderby
  FROM timescaledb_information.compression_settings
  GROUP BY hypertable_schema, hypertable_name
)
SELECT
  now() AS as_of,
  hypertable_schema,
  hypertable_name,
  COALESCE(segmentby, '') AS segmentby,
  COALESCE(orderby,   '') AS orderby
FROM settings
ORDER BY hypertable_schema, hypertable_name;

-- Query 2: compression progress by hypertable (chunk counts)
SELECT
  now() AS as_of,
  hypertable_schema,
  hypertable_name,
  COUNT(*)                                  AS chunk_count,
  COUNT(*) FILTER (WHERE is_compressed)     AS compressed_chunks,
  COUNT(*) FILTER (WHERE NOT is_compressed) AS uncompressed_chunks,
  ROUND(100.0 * COUNT(*) FILTER (WHERE is_compressed) / NULLIF(COUNT(*), 0), 1) AS pct_chunks_compressed,
  MIN(range_start) AS oldest_range_start,
  MAX(range_end)   AS newest_range_end
FROM timescaledb_information.chunks
GROUP BY hypertable_schema, hypertable_name
ORDER BY pct_chunks_compressed ASC, chunk_count DESC;

-- Query 3: actual compression ratios (before/after bytes per hypertable).
-- Only chunks that are currently compressed contribute to these stats.
SELECT
  now() AS as_of,
  h.hypertable_schema,
  h.hypertable_name,
  s.total_chunks,
  s.number_compressed_chunks,
  pg_size_pretty(s.before_compression_total_bytes) AS before_compression,
  pg_size_pretty(s.after_compression_total_bytes)  AS after_compression,
  ROUND(s.before_compression_total_bytes / 1024.0 / 1024 / 1024, 3) AS before_gb,
  ROUND(s.after_compression_total_bytes  / 1024.0 / 1024 / 1024, 3) AS after_gb,
  ROUND(
    100.0 * (1 - s.after_compression_total_bytes::numeric
                 / NULLIF(s.before_compression_total_bytes, 0)), 1
  ) AS space_saved_pct,
  ROUND(
    s.before_compression_total_bytes::numeric
    / NULLIF(s.after_compression_total_bytes, 0), 1
  ) AS compression_ratio_x
FROM timescaledb_information.hypertables h
JOIN LATERAL hypertable_compression_stats(
       format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass
     ) s ON true
WHERE s.number_compressed_chunks > 0
ORDER BY s.before_compression_total_bytes DESC NULLS LAST;