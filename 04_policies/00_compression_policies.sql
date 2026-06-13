-- ============================================================================
-- Script:        00_compression_policies.sql
-- Folder:        04_policies
-- Purpose:       Schedule compression for every hypertable, and provide
--                compress_eligible_now() so a demo gets compressed chunks
--                immediately instead of waiting for the background worker.
-- Safe in prod:  Policies: YES (standard practice). compress_eligible_now():
--                CAUTION -- compressing chunks takes locks and CPU; run in a
--                maintenance window on real systems.
-- Requires:      02_schema installed (compression SETTINGS -- segmentby/
--                orderby -- were defined with the tables; this script only
--                schedules WHEN compression happens).
-- Compatibility: TimescaleDB 2.13+
-- Notes:         compress_after thresholds are short by demo design: with
--                60 days of 1-day chunks, "compress after 7 days" leaves a
--                hot uncompressed week and ~53 compressed chunks -- enough
--                for 01_monitoring/07_compression_overview.sql to show real
--                before/after ratios.
-- ============================================================================

SET search_path = scada, public;

-- Idempotent: if_not_exists makes re-runs safe.
SELECT add_compression_policy('scada.point_readings',          INTERVAL '7 days',  if_not_exists => true);
SELECT add_compression_policy('scada.control_requests',        INTERVAL '14 days', if_not_exists => true);
SELECT add_compression_policy('scada.control_requests_history',INTERVAL '7 days',  if_not_exists => true);
SELECT add_compression_policy('scada.alarm_events',            INTERVAL '14 days', if_not_exists => true);

-- ---------------------------------------------------------------------------
-- compress_eligible_now: walk every compression-enabled hypertable in the
-- scada schema and synchronously compress chunks older than each table's
-- policy threshold (or an override you pass in). Skips already-compressed
-- chunks; logs per-chunk progress; returns a summary.
--
--   SELECT scada.compress_eligible_now();                 -- use policy ages
--   SELECT scada.compress_eligible_now(INTERVAL '1 day'); -- compress harder
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.compress_eligible_now(_older_than INTERVAL DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _chunk     RECORD;
    _threshold INTERVAL;
    _count     INT := 0;
    _bytes_before BIGINT := 0;
    _t0        TIMESTAMPTZ := clock_timestamp();
BEGIN
    FOR _chunk IN
        SELECT c.hypertable_schema, c.hypertable_name,
               c.chunk_schema, c.chunk_name, c.range_end,
               COALESCE(
                   _older_than,
                   -- fall back to each table's policy threshold
                   (j.config ->> 'compress_after')::interval,
                   INTERVAL '7 days'
               ) AS threshold
        FROM timescaledb_information.chunks c
        LEFT JOIN timescaledb_information.jobs j
               ON j.proc_name = 'policy_compression'
              AND j.hypertable_schema = c.hypertable_schema
              AND j.hypertable_name   = c.hypertable_name
        WHERE c.hypertable_schema = 'scada'
          AND NOT c.is_compressed
        ORDER BY c.hypertable_name, c.range_end
    LOOP
        IF _chunk.range_end < now() - _chunk.threshold THEN
            _bytes_before := _bytes_before + pg_total_relation_size(
                format('%I.%I', _chunk.chunk_schema, _chunk.chunk_name)::regclass);
            PERFORM compress_chunk(
                format('%I.%I', _chunk.chunk_schema, _chunk.chunk_name)::regclass);
            _count := _count + 1;
        END IF;
    END LOOP;

    RETURN format('Compressed %s chunks (%s uncompressed bytes in) in %s. '
                  'Run 01_monitoring/07_compression_overview.sql for the ratios.',
                  _count, pg_size_pretty(_bytes_before), clock_timestamp() - _t0);
END;
$func$;

-- Fire it once so the demo has compressed chunks right now.
SELECT scada.compress_eligible_now();

\echo ''
\echo 'Compression policies registered:'
SELECT j.job_id, j.hypertable_name, j.config ->> 'compress_after' AS compress_after,
       j.schedule_interval
FROM timescaledb_information.jobs j
WHERE j.proc_name = 'policy_compression'
ORDER BY j.hypertable_name;
