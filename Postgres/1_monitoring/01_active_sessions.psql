-- ============================================================================
-- Script:        01_active_sessions.sql
-- Folder:        01_monitoring
-- Purpose:       Snapshot of current sessions: who is connected, what is
--                running, wait events, and query/transaction durations.
--                Query 1 = counts by state; Query 2 = full session detail.
-- Safe in prod:  YES (read-only)
-- Requires:      pg_stat_activity access (pg_read_all_stats recommended;
--                otherwise query text is visible only for your own sessions).
-- Compatibility: PostgreSQL 12+
-- Notes:         Long "idle in transaction" sessions hold locks and block
--                vacuum -- they appear near the top of Query 2 by design.
-- ============================================================================

-- Query 1: quick health summary -- session counts by database and state
SELECT
  now()                                   AS as_of,
  a.datname                               AS db,
  a.state,
  COUNT(*)                                AS sessions,
  MAX(age(now(), a.query_start))          AS longest_query_age
FROM pg_stat_activity a
WHERE a.pid <> pg_backend_pid()
  AND a.backend_type = 'client backend'
GROUP BY a.datname, a.state
ORDER BY a.datname, sessions DESC;

-- Query 2: full session detail, active and longest-running first
SELECT
  now()                                   AS as_of,
  a.datname                               AS db,
  a.usename                               AS username,
  a.pid,
  a.application_name,
  a.client_addr,
  a.client_port,
  a.backend_type,
  a.state,
  a.wait_event_type,
  a.wait_event,
  a.xact_start,
  age(now(), a.xact_start)                AS xact_age,
  a.query_start,
  age(now(), a.query_start)               AS query_age,
  a.state_change,
  age(now(), a.state_change)              AS state_age,
  left(regexp_replace(a.query, '\s+', ' ', 'g'), 2000) AS query
FROM pg_stat_activity a
WHERE a.pid <> pg_backend_pid()
  -- Optional filters (uncomment and adjust as needed):
  -- AND a.datname = 'your_database'
  -- AND a.usename = 'your_user'
  -- AND a.state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
ORDER BY
  (a.state = 'active') DESC,
  age(now(), a.query_start) DESC NULLS LAST,
  a.datname,
  a.usename;