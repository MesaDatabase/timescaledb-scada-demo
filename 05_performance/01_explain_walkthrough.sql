-- ============================================================================
-- Script:        01_explain_walkthrough.sql
-- Folder:        05_performance
-- Purpose:       Three planner lessons, each shown as a matched pair (the
--                query the design serves vs the one it doesn't):
--                  1. chunk exclusion -- the core hypertable win
--                  2. the CASE expression index on control_requests
--                  3. the partial index on alarm_history
-- Safe in prod:  YES (read-only EXPLAINs).
-- Requires:      Full demo built.
-- Compatibility: TimescaleDB 2.13+
-- ============================================================================

SET search_path = scada, public;

\echo '============================================================'
\echo ' 1a) CHUNK EXCLUSION. A time-bounded query plans only the'
\echo '     chunks that can contain matches -- count the chunk scans'
\echo '     in this plan: ~2 of the ~45 that exist.'
\echo '============================================================'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM point_readings
WHERE event_time >= now() - INTERVAL '2 days';

\echo '============================================================'
\echo ' 1b) Now the same count with NO time predicate: every chunk,'
\echo '     compressed and not, gets scanned. On a hypertable, "no'
\echo '     time filter" is a design smell -- this plan is the smell'
\echo '     made visible.'
\echo '============================================================'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM point_readings;

\echo '============================================================'
\echo ' 2a) THE EXPRESSION INDEX. The open-requests dashboard query'
\echo '     repeats the exact CASE the index ix_control_requests_open'
\echo '     was built on -- the planner matches expression to'
\echo '     expression and range-scans straight to the open rows.'
\echo '============================================================'
EXPLAIN (COSTS OFF)
SELECT created_at, status, control_request_id
FROM control_requests
WHERE site_id = (SELECT site_id FROM sites ORDER BY name LIMIT 1)
  AND (CASE WHEN status IN ('queued', 'accepted', 'scheduled', 'active')
            THEN 1 ELSE 9 END) = 1
ORDER BY created_at DESC
LIMIT 20;

\echo '============================================================'
\echo ' 2b) Semantically identical intent, written as a plain IN'
\echo '     list: the expression no longer matches the index'
\echo '     definition, so the planner falls back to scanning. Same'
\echo '     question, different SQL, different plan -- expression'
\echo '     indexes only pay when queries quote them exactly.'
\echo '============================================================'
EXPLAIN (COSTS OFF)
SELECT created_at, status, control_request_id
FROM control_requests
WHERE site_id = (SELECT site_id FROM sites ORDER BY name LIMIT 1)
  AND status IN ('queued', 'accepted', 'scheduled', 'active')
ORDER BY created_at DESC
LIMIT 20;

\echo '============================================================'
\echo ' 3a) THE PARTIAL INDEX. The active-alarm board hits'
\echo '     ix_alarm_history_active -- an index that only contains'
\echo '     the handful of is_active rows, so it stays tiny no'
\echo '     matter how much history accumulates.'
\echo '============================================================'
EXPLAIN (COSTS OFF)
SELECT alarm_name, severity, raised_at
FROM alarm_history
WHERE is_active
  AND site_id = (SELECT site_id FROM sites ORDER BY name LIMIT 1)
ORDER BY severity, raised_at DESC;

\echo '============================================================'
\echo ' 3b) Drop the is_active predicate and the partial index is'
\echo '     ineligible -- the planner uses the full history index'
\echo '     instead. Partial indexes trade generality for size.'
\echo '============================================================'
EXPLAIN (COSTS OFF)
SELECT alarm_name, severity, raised_at
FROM alarm_history
WHERE site_id = (SELECT site_id FROM sites ORDER BY name LIMIT 1)
ORDER BY raised_at DESC
LIMIT 50;
