-- ============================================================================
-- Script:        00_benchmark_compression.sql
-- Folder:        05_performance
-- Purpose:       What compression actually costs and buys at query time:
--                  1. identical query shapes against uncompressed (recent)
--                     vs compressed (older) chunks, timed
--                  2. why the segmentby column matters: point_id filters
--                     prune compressed segments; non-segmentby filters
--                     decompress everything
--                  3. the storage receipt
-- Safe in prod:  YES (read-only). Timings depend on cache state -- run twice
--                and trust the second pass.
-- Requires:      Full demo built (schema, data, policies).
-- Compatibility: TimescaleDB 2.13+
-- Notes:         Demo geometry reminder: 1-day chunks, compression policy at
--                7 days, retention at 45. So "2 days ago" = uncompressed,
--                "30 days ago" = compressed.
-- ============================================================================

SET search_path = scada, public;
\timing on

\echo '============================================================'
\echo ' 1) Same query, two eras. One inverter, one 24-hour window:'
\echo '    first in the uncompressed hot week, then 30 days back in'
\echo '    compressed territory. Watch the timings -- compressed is'
\echo '    usually competitive or better for this shape, because'
\echo '    segmentby=point_id means only this point''s segments are'
\echo '    even touched.'
\echo '============================================================'
SELECT count(*), round(avg(value_double)::numeric, 1) AS avg_kw
FROM point_readings r
WHERE r.point_id = (SELECT point_id FROM points WHERE point_kind = 1 ORDER BY name LIMIT 1)
  AND r.event_time >= now() - INTERVAL '3 days'
  AND r.event_time <  now() - INTERVAL '2 days';

SELECT count(*), round(avg(value_double)::numeric, 1) AS avg_kw
FROM point_readings r
WHERE r.point_id = (SELECT point_id FROM points WHERE point_kind = 1 ORDER BY name LIMIT 1)
  AND r.event_time >= now() - INTERVAL '31 days'
  AND r.event_time <  now() - INTERVAL '30 days';

\echo '============================================================'
\echo ' 2) The plan tells the story. On compressed chunks look for'
\echo '    the DecompressChunk node and -- because point_id is the'
\echo '    segmentby column -- a filter pushed down onto the'
\echo '    compressed segments themselves.'
\echo '============================================================'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*)
FROM point_readings r
WHERE r.point_id = (SELECT point_id FROM points WHERE point_kind = 1 ORDER BY name LIMIT 1)
  AND r.event_time >= now() - INTERVAL '31 days'
  AND r.event_time <  now() - INTERVAL '30 days';

\echo '============================================================'
\echo ' 3) The anti-pattern, on purpose: filter compressed data by a'
\echo '    NON-segmentby predicate (a value threshold) with no point'
\echo '    filter. Every segment in the window must be decompressed'
\echo '    to answer. Compare the runtime and buffers to query 2 --'
\echo '    this is why segmentby choice is a design decision, not a'
\echo '    default.'
\echo '============================================================'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*)
FROM point_readings r
WHERE r.value_double > 240
  AND r.event_time >= now() - INTERVAL '31 days'
  AND r.event_time <  now() - INTERVAL '30 days';

\echo '============================================================'
\echo ' 4) The storage receipt: actual before/after bytes.'
\echo '============================================================'
SELECT h.hypertable_name,
       s.number_compressed_chunks,
       pg_size_pretty(s.before_compression_total_bytes) AS before,
       pg_size_pretty(s.after_compression_total_bytes)  AS after,
       round(100.0 * (1 - s.after_compression_total_bytes::numeric
                        / NULLIF(s.before_compression_total_bytes, 0)), 1) AS saved_pct
FROM timescaledb_information.hypertables h
JOIN LATERAL hypertable_compression_stats(
       format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass) s ON true
WHERE h.hypertable_schema = 'scada'
  AND s.number_compressed_chunks > 0
ORDER BY s.before_compression_total_bytes DESC;

\timing off
