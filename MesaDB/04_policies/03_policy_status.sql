-- ============================================================================
-- Script:        03_policy_status.sql
-- Folder:        04_policies
-- Purpose:       One-stop health check after the policies are installed:
--                every background job, compression posture per hypertable,
--                continuous aggregate state, and the retention audit trail.
--                (Deeper diagnostics live in 01_monitoring.)
-- Safe in prod:  YES (read-only)
-- Requires:      00..02 of this folder executed.
-- Compatibility: TimescaleDB 2.13+
-- ============================================================================

SET search_path = scada, public;

\echo '============================================================'
\echo ' 1) Every background job: compression, cagg refresh, and the'
\echo '    custom retention job, with run stats.'
\echo '============================================================'
SELECT j.job_id,
       j.application_name,
       coalesce(j.hypertable_name, j.proc_name) AS target,
       j.schedule_interval,
       js.last_run_status,
       js.last_successful_finish,
       js.next_start,
       js.total_runs, js.total_failures
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats js ON js.job_id = j.job_id
WHERE j.job_id >= 1000   -- user-space jobs (policies + custom)
ORDER BY j.job_id;

\echo '============================================================'
\echo ' 2) Compression posture: chunks compressed vs not, per'
\echo '    hypertable (includes the materialized cagg hypertables).'
\echo '============================================================'
SELECT c.hypertable_schema,
       c.hypertable_name,
       count(*)                                  AS chunks,
       count(*) FILTER (WHERE c.is_compressed)   AS compressed,
       count(*) FILTER (WHERE NOT c.is_compressed) AS uncompressed,
       min(c.range_start)                        AS oldest,
       max(c.range_end)                          AS newest
FROM timescaledb_information.chunks c
GROUP BY c.hypertable_schema, c.hypertable_name
ORDER BY c.hypertable_schema, c.hypertable_name;

\echo '============================================================'
\echo ' 3) Continuous aggregates: real-time flag and completion.'
\echo '    Note readings_1d builds on readings_1h (hierarchical).'
\echo '============================================================'
SELECT view_name,
       materialized_only,
       compression_enabled,
       materialization_hypertable_name
FROM timescaledb_information.continuous_aggregates
WHERE view_schema = 'scada'
ORDER BY view_name;

\echo '============================================================'
\echo ' 4) Retention: current targets and the audit trail. The'
\echo '    downsampling story in one screen -- raw readings retained'
\echo '    45 days, while readings_1h/_1d preserve aggregate history.'
\echo '============================================================'
SELECT hypertable_name, retention_days, updated_at
FROM scada.retention_settings
ORDER BY hypertable_name;

SELECT executed_at, hypertable_name, deleted_chunks, duration, status
FROM scada.retention_logs
ORDER BY log_id DESC
LIMIT 12;

\echo '============================================================'
\echo ' 5) Proof of downsampling: raw readings now start ~45 days'
\echo '    back; the daily cagg still covers the full 60.'
\echo '============================================================'
SELECT 'point_readings (raw)' AS source,
       min(event_time)        AS earliest,
       max(event_time)        AS latest
FROM scada.point_readings
UNION ALL
SELECT 'readings_1d (cagg)', min(bucket), max(bucket)
FROM scada.readings_1d;
