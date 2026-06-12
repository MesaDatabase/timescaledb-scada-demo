-- ============================================================================
-- Script:        01_maintenance_checks.sql
-- Folder:        06_operations
-- Purpose:       Routine maintenance health: is autovacuum keeping up, what
--                is bloated, what has never been analyzed -- with the
--                hypertable twist: chunks are the tables that matter, so
--                everything here rolls chunk stats up to their hypertable.
-- Safe in prod:  YES -- diagnostics are read-only; analyze_all() runs
--                ANALYZE only (cheap, lock-light). Heavier remediation
--                commands are commented.
-- Requires:      pg_stat access; TimescaleDB for the chunk rollups.
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.x
-- Notes:         TimescaleDB nuances worth knowing cold:
--                  * autovacuum visits CHUNKS individually -- a quiet parent
--                    hypertable is normal and meaningless.
--                  * compressed chunks barely need vacuum (rewritten on
--                    compress); dead-tuple pressure lives in the hot,
--                    uncompressed tail -- exactly what Query 1 surfaces.
--                  * retention (drop_chunks) deletes whole files: no bloat,
--                    no vacuum debt. DELETE-based purging creates both;
--                    that asymmetry is half the reason retention policies
--                    exist.
-- ============================================================================

SET search_path = scada, public;

\echo '============================================================'
\echo ' 1) Dead-tuple pressure by hypertable (chunk stats rolled up)'
\echo '    and by regular table. High dead_pct on the hot tail is'
\echo '    the thing to watch.'
\echo '============================================================'
WITH chunk_map AS (
    SELECT h.hypertable_name,
           c.chunk_schema, c.chunk_name
    FROM timescaledb_information.chunks c
    JOIN timescaledb_information.hypertables h
      ON h.hypertable_schema = c.hypertable_schema
     AND h.hypertable_name   = c.hypertable_name
)
SELECT cm.hypertable_name                       AS relation,
       'hypertable (chunks rolled up)'          AS kind,
       count(*)                                 AS parts,
       sum(s.n_live_tup)                        AS live_tup,
       sum(s.n_dead_tup)                        AS dead_tup,
       round(100.0 * sum(s.n_dead_tup)
             / NULLIF(sum(s.n_live_tup) + sum(s.n_dead_tup), 0), 1) AS dead_pct,
       max(s.last_autovacuum)                   AS newest_autovacuum
FROM chunk_map cm
JOIN pg_stat_all_tables s
  ON s.schemaname = cm.chunk_schema AND s.relname = cm.chunk_name
GROUP BY cm.hypertable_name

UNION ALL

SELECT s.relname, 'regular table', 1,
       s.n_live_tup, s.n_dead_tup,
       round(100.0 * s.n_dead_tup
             / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 1),
       s.last_autovacuum
FROM pg_stat_user_tables s
WHERE s.schemaname = 'scada'
ORDER BY dead_pct DESC NULLS LAST, relation;

\echo '============================================================'
\echo ' 2) Stale or missing statistics: planner quality depends on'
\echo '    analyze recency. NULL everywhere = never analyzed.'
\echo '============================================================'
SELECT s.schemaname, s.relname,
       s.last_analyze, s.last_autoanalyze,
       s.n_mod_since_analyze AS modified_since_analyze
FROM pg_stat_user_tables s
WHERE s.schemaname = 'scada'
ORDER BY GREATEST(s.last_analyze, s.last_autoanalyze) ASC NULLS FIRST
LIMIT 20;

\echo '============================================================'
\echo ' 3) Hot-tail focus: the 10 chunks with the most dead tuples.'
\echo '    These are the individual vacuum targets if autovacuum is'
\echo '    behind.'
\echo '============================================================'
SELECT s.schemaname || '.' || s.relname AS chunk,
       cm.hypertable_name,
       s.n_dead_tup, s.n_live_tup,
       s.last_autovacuum
FROM pg_stat_all_tables s
JOIN (
    SELECT c.chunk_schema, c.chunk_name, c.hypertable_name
    FROM timescaledb_information.chunks c
) cm ON cm.chunk_schema = s.schemaname AND cm.chunk_name = s.relname
ORDER BY s.n_dead_tup DESC
LIMIT 10;

\echo '============================================================'
\echo ' 4) Transaction-ID age (wraparound runway) for this database.'
\echo '    Comfortable < 200M; investigate autovacuum freeze if it'
\echo '    climbs toward 1B+.'
\echo '============================================================'
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database
WHERE datname = current_database();

\echo '============================================================'
\echo ' 5) Vacuum blockers: long-running transactions pin the xmin'
\echo '    horizon -- vacuum cannot reclaim what an old snapshot can'
\echo '    still see. Anything hours old here explains bloat better'
\echo '    than any autovacuum setting.'
\echo '============================================================'
SELECT pid,
       usename,
       state,
       age(now(), xact_start) AS xact_age,
       backend_xmin,
       left(regexp_replace(query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND pid <> pg_backend_pid()
ORDER BY xact_start
LIMIT 10;

-- ---------------------------------------------------------------------------
-- analyze_all: refresh planner statistics for the application schema (a
-- hypertable ANALYZE recurses into its chunks). Run after any bulk load --
-- the demo generator being the canonical example. ANALYZE only: no rewrite,
-- brief locks, safe anytime.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.analyze_all()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _t  RECORD;
    _n  INT := 0;
    _t0 TIMESTAMPTZ := clock_timestamp();
BEGIN
    FOR _t IN
        SELECT format('%I.%I', schemaname, relname) AS qualified
        FROM pg_stat_user_tables
        WHERE schemaname = 'scada'
    LOOP
        EXECUTE 'ANALYZE ' || _t.qualified;
        _n := _n + 1;
    END LOOP;
    RETURN format('Analyzed %s tables in %s.', _n, clock_timestamp() - _t0);
END;
$func$;

\echo ''
\echo 'Refreshing statistics now (post-bulk-load best practice):'
SELECT scada.analyze_all();

-- ---------------------------------------------------------------------------
-- Remediation toolbox (deliberate, manual):
--
--   VACUUM (ANALYZE, VERBOSE) scada.alarm_history;          -- one table
--   VACUUM ANALYZE _timescaledb_internal._hyper_X_Y_chunk;  -- one hot chunk
--   ANALYZE scada.point_readings;                           -- stats only
--
-- Per-table autovacuum tuning for the update-heavy outlier:
--   ALTER TABLE scada.alarm_history
--     SET (autovacuum_vacuum_scale_factor = 0.05);
--
-- Never: VACUUM FULL on a live system without a maintenance window --
-- it takes ACCESS EXCLUSIVE and rewrites the table.
-- ---------------------------------------------------------------------------
