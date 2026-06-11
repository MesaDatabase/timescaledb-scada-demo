-- ============================================================================
-- Script:        02_blocking_locks.sql
-- Folder:        01_monitoring
-- Purpose:       Identify blocked sessions and their blockers.
--                Query 1 = summary (is anything blocked right now, by whom?)
--                Query 2 = one row per blocked_pid -> blocking_pid pair,
--                          with the SQL on both sides.
-- Safe in prod:  YES (read-only)
-- Requires:      pg_stat_activity access (pg_read_all_stats recommended)
-- Compatibility: PostgreSQL 12+
-- Notes:         A reproducible two-session demo of this scenario lives in
--                05_performance/demo_blocking_locks.sql.
--                Remediation (use deliberately, never reflexively):
--                  SELECT pg_cancel_backend(<pid>);     -- cancel query only
--                  SELECT pg_terminate_backend(<pid>);  -- kill the session
-- ============================================================================

-- Query 1: summary -- sessions currently blocked, with their blocking PIDs
SELECT
  now()                            AS as_of,
  a.datname                        AS db,
  a.usename                        AS blocked_user,
  a.pid                            AS blocked_pid,
  a.application_name               AS blocked_app,
  a.client_addr                    AS blocked_client,
  a.state                          AS blocked_state,
  a.wait_event_type,
  a.wait_event,
  a.query_start,
  age(now(), a.query_start)        AS blocked_query_age,
  pg_blocking_pids(a.pid)          AS blocking_pids,
  left(regexp_replace(a.query, '\s+', ' ', 'g'), 2000) AS blocked_query
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY blocked_query_age DESC;

-- Query 2: detail -- one row per blocked -> blocker pair, SQL on both sides.
-- Use this to decide exactly which session to cancel or terminate.
SELECT
  now()                            AS as_of,
  b.datname                        AS db,
  b.pid                            AS blocked_pid,
  b.usename                        AS blocked_user,
  b.application_name               AS blocked_app,
  age(now(), b.query_start)        AS blocked_query_age,
  left(regexp_replace(b.query, '\s+', ' ', 'g'), 1000)   AS blocked_query,
  blk.pid                          AS blocking_pid,
  blk.usename                      AS blocking_user,
  blk.application_name             AS blocking_app,
  blk.state                        AS blocking_state,
  age(now(), blk.query_start)      AS blocking_query_age,
  age(now(), blk.xact_start)       AS blocking_xact_age,
  left(regexp_replace(blk.query, '\s+', ' ', 'g'), 1000) AS blocking_query
FROM pg_stat_activity b
JOIN LATERAL unnest(pg_blocking_pids(b.pid)) AS p(blocking_pid) ON true
JOIN pg_stat_activity blk ON blk.pid = p.blocking_pid
ORDER BY blocked_query_age DESC, blocking_query_age DESC;