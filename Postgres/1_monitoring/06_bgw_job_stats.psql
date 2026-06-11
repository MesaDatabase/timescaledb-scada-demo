-- ============================================================================
-- Script:        06_bgw_job_stats.sql
-- Folder:        01_monitoring
-- Purpose:       TimescaleDB background jobs (compression, retention,
--                continuous aggregate refresh, custom jobs) with run history,
--                plus the most recent job errors.
-- Safe in prod:  YES (read-only)
-- Requires:      TimescaleDB (timescaledb_information.jobs / job_stats /
--                job_errors). job_errors requires TimescaleDB 2.5+.
-- Compatibility: TimescaleDB 2.x
-- Notes:         total_failures > 0 with a recent last_successful_finish is
--                usually transient; failures with no recent success mean the
--                policy is silently not doing its work -- compression and
--                retention backlogs build up fast.
-- ============================================================================

-- Query 1: all jobs with status and run statistics
SELECT
  now() AS as_of,
  j.job_id,
  j.application_name,
  j.proc_schema,
  j.proc_name,
  j.hypertable_schema,
  j.hypertable_name,
  j.schedule_interval,
  j.max_runtime,
  j.retry_period,
  j.owner,
  j.scheduled,
  j.fixed_schedule,
  j.config,
  js.job_status,
  js.last_run_started_at,
  js.last_successful_finish,
  js.last_run_status,
  js.last_run_duration,
  js.next_start,
  js.total_runs,
  js.total_successes,
  js.total_failures
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats js
  ON js.job_id = j.job_id
ORDER BY
  js.last_run_started_at DESC NULLS LAST,
  j.job_id;

-- Query 2: most recent job errors (last 50)
SELECT
  now() AS as_of,
  e.job_id,
  j.application_name,
  e.proc_schema,
  e.proc_name,
  e.pid,
  e.start_time,
  e.finish_time,
  e.sqlerrcode,
  e.err_message
FROM timescaledb_information.job_errors e
LEFT JOIN timescaledb_information.jobs j
  ON j.job_id = e.job_id
ORDER BY e.finish_time DESC NULLS LAST
LIMIT 50;