-- ============================================================================
-- Script:        02_cagg_vs_raw_benchmark.sql
-- Folder:        05_performance
-- Purpose:       The "why continuous aggregates" headline: the same daily
--                report computed three ways --
--                  A. aggregating raw readings
--                  B. reading the readings_1d continuous aggregate
--                  C. the hierarchical middle path: readings_1h
--                Same answers, wildly different work.
-- Safe in prod:  YES (read-only). Run twice; trust the warm pass.
-- Requires:      Full demo built (caggs refreshed by 04_policies).
-- Compatibility: TimescaleDB 2.13+
-- Notes:         Window = last 40 days (inside raw retention of 45, so all
--                three sources can answer). Bonus at the end: the cagg can
--                answer for days 45-60 where raw data no longer exists.
-- ============================================================================

SET search_path = scada, public;
\timing on

\echo '============================================================'
\echo ' A) RAW: daily avg/max for every point, 40 days, computed'
\echo '    from ~point-count x 288 readings/day. This is the query'
\echo '    your dashboard would run without caggs.'
\echo '============================================================'
SELECT time_bucket(INTERVAL '1 day', r.event_time) AS day,
       r.point_id,
       avg(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8)) AS avg_v,
       max(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8)) AS max_v
FROM point_readings r
WHERE r.event_time >= now() - INTERVAL '40 days'
GROUP BY 1, 2
ORDER BY 1, 2
\g /dev/null

\echo '(result routed to /dev/null -- we are timing the work, not the scroll)'

\echo '============================================================'
\echo ' B) CAGG: identical report from readings_1d -- one'
\echo '    pre-materialized row per point per day.'
\echo '============================================================'
SELECT d.bucket AS day, d.point_id, d.avg_value, d.max_value
FROM readings_1d d
WHERE d.bucket >= now() - INTERVAL '40 days'
ORDER BY 1, 2
\g /dev/null

\echo '============================================================'
\echo ' C) HOURLY CAGG: when you need finer grain than daily but'
\echo '    still not raw -- 24 rows/point/day instead of 288.'
\echo '============================================================'
SELECT h.bucket, h.point_id, h.avg_value, h.max_value
FROM readings_1h h
WHERE h.bucket >= now() - INTERVAL '40 days'
ORDER BY 1, 2
\g /dev/null

\echo '============================================================'
\echo ' Sanity: the answers agree. One site-meter point, last 5'
\echo '    days, raw-computed vs cagg, side by side.'
\echo '============================================================'
WITH raw AS (
    SELECT time_bucket(INTERVAL '1 day', r.event_time) AS day,
           round(avg(r.value_double)::numeric, 2) AS raw_avg
    FROM point_readings r
    WHERE r.point_id = (SELECT point_id FROM points WHERE point_kind = 9 ORDER BY point_id LIMIT 1)
      AND r.event_time >= now() - INTERVAL '5 days'
    GROUP BY 1
)
SELECT raw.day, raw.raw_avg, round(d.avg_value::numeric, 2) AS cagg_avg
FROM raw
JOIN readings_1d d
  ON d.bucket = raw.day
 AND d.point_id = (SELECT point_id FROM points WHERE point_kind = 9 ORDER BY point_id LIMIT 1)
ORDER BY raw.day;

\echo '============================================================'
\echo ' The kicker: days 50-55 ago. Raw was dropped by retention at'
\echo ' 45 days -- zero rows. The daily cagg still answers. Storage'
\echo ' of raw detail is finite; aggregate history is cheap.'
\echo '============================================================'
SELECT 'raw readings' AS source, count(*) AS rows_available
FROM point_readings
WHERE event_time BETWEEN now() - INTERVAL '55 days' AND now() - INTERVAL '50 days'
UNION ALL
SELECT 'readings_1d cagg', count(*)
FROM readings_1d
WHERE bucket BETWEEN now() - INTERVAL '55 days' AND now() - INTERVAL '50 days';

\timing off
