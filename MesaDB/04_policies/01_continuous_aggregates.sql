-- ============================================================================
-- Script:        01_continuous_aggregates.sql
-- Folder:        04_policies
-- Purpose:       Continuous aggregates -- TimescaleDB's flagship feature:
--                  * readings_1h: hourly stats per point, incrementally
--                    maintained, REAL-TIME (queries union in raw rows newer
--                    than the last materialization -- always current).
--                  * readings_1d: a HIERARCHICAL cagg -- daily stats built
--                    from the hourly cagg, not from raw data.
--                  * Refresh policies for both, compression on the hourly.
-- Safe in prod:  YES -- this is exactly how production caggs are built.
--                Initial refresh over deep history can be heavy; here it is
--                chunked by the refresh window.
-- Requires:      02_schema + 03_data_generation (data to materialize).
-- Compatibility: TimescaleDB 2.13+ (hierarchical caggs need 2.9+).
-- Notes:         Why store sum AND count AND avg? Hierarchical rollups can't
--                average averages -- the daily avg must be sum(sum)/sum(n).
--                Storing the parts makes every downstream rollup exact.
--
--                The typed value columns collapse via COALESCE rather than
--                scada.reading_value() + a join to points: cagg definitions
--                are restricted (and join-free caggs stay restriction-proof
--                across TimescaleDB versions). Same result -- a point only
--                ever populates its declared column.
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- Hourly rollup per point. WITH NO DATA: create instantly, refresh below.
-- materialized_only = false ==> "real-time aggregate": SELECTs transparently
-- union materialized buckets with raw rows newer than the materialization
-- watermark. Dashboards read one view and it is always up to date.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS scada.readings_1h
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    r.point_id,
    time_bucket(INTERVAL '1 hour', r.event_time) AS bucket,
    count(*)                                     AS n,
    sum(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8)) AS sum_value,
    avg(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8)) AS avg_value,
    min(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8)) AS min_value,
    max(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8)) AS max_value,
    first(COALESCE(r.value_double, r.value_bigint::float8, r.value_numeric::float8), r.event_time) AS first_value,
    last(COALESCE(r.value_double,  r.value_bigint::float8, r.value_numeric::float8), r.event_time) AS last_value,
    -- CASE-in-sum, not count(*) FILTER: cagg definitions don't allow FILTER
    sum(CASE WHEN r.data_quality <> 'online' THEN 1 ELSE 0 END) AS not_online_n
FROM scada.point_readings r
WHERE r.reading_type = 'raw'
GROUP BY r.point_id, time_bucket(INTERVAL '1 hour', r.event_time)
WITH NO DATA;

-- ---------------------------------------------------------------------------
-- Daily rollup built FROM THE HOURLY CAGG (hierarchical): each day reads 24
-- hourly rows per point instead of thousands of raw readings. avg is derived
-- exactly as sum/count.
-- (If your TimescaleDB version rejects real-time mode on a hierarchical
--  cagg, fall back with:
--    ALTER MATERIALIZED VIEW scada.readings_1d
--      SET (timescaledb.materialized_only = true); )
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS scada.readings_1d
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    h.point_id,
    time_bucket(INTERVAL '1 day', h.bucket) AS bucket,
    sum(h.n)                                AS n,
    sum(h.sum_value)                        AS sum_value,
    sum(h.sum_value) / NULLIF(sum(h.n), 0)  AS avg_value,
    min(h.min_value)                        AS min_value,
    max(h.max_value)                        AS max_value,
    first(h.first_value, h.bucket)          AS first_value,
    last(h.last_value, h.bucket)            AS last_value,
    sum(h.not_online_n)                     AS not_online_n
FROM scada.readings_1h h
GROUP BY h.point_id, time_bucket(INTERVAL '1 day', h.bucket)
WITH NO DATA;

-- ---------------------------------------------------------------------------
-- Materialize history now (outside the policies) so the demo is instant.
-- NULL start = from the beginning; end stops shy of "now" -- the real-time
-- union covers the rest.
-- ---------------------------------------------------------------------------
CALL refresh_continuous_aggregate('scada.readings_1h', NULL, now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('scada.readings_1d', NULL, now() - INTERVAL '1 day');

-- ---------------------------------------------------------------------------
-- Keep them fresh automatically. start_offset > end_offset defines the
-- maintenance window each run re-materializes; end_offset stays >= one
-- bucket so in-flight buckets are served by the real-time union instead of
-- being repeatedly re-materialized.
-- ---------------------------------------------------------------------------
SELECT add_continuous_aggregate_policy('scada.readings_1h',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes',
    if_not_exists     => true);

SELECT add_continuous_aggregate_policy('scada.readings_1d',
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '6 hours',
    if_not_exists     => true);

-- ---------------------------------------------------------------------------
-- Caggs are hypertables underneath -- so they compress too. Hourly data
-- older than two weeks is read-mostly: compress it.
-- ---------------------------------------------------------------------------
ALTER MATERIALIZED VIEW scada.readings_1h SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby = 'point_id'
);
SELECT add_compression_policy('scada.readings_1h', INTERVAL '14 days', if_not_exists => true);

\echo ''
\echo 'Continuous aggregates ready. Real-time check (includes raw rows newer'
\echo 'than the materialization -- run it, insert a reading, run it again):'
\echo '  SELECT * FROM scada.readings_1h WHERE bucket > now() - INTERVAL ''3 hours'' LIMIT 12;'
SELECT view_name, materialized_only, finalized
FROM timescaledb_information.continuous_aggregates
WHERE view_schema = 'scada';
