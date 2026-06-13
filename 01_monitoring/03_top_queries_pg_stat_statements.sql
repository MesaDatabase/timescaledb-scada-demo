-- ============================================================================
-- Script:        03_top_queries_pg_stat_statements.sql
-- Folder:        01_monitoring
-- Purpose:       Top 50 queries by total execution time from
--                pg_stat_statements, normalized to seconds, with cache hit
--                ratio and rows-per-call. Version-adaptive: detects whether
--                the installed extension exposes *_exec_time (PG 13+) or
--                *_time (PG <= 12 era) column names and builds accordingly.
-- Safe in prod:  YES (read-only; creates a session-local TEMP table only)
-- Requires:      pg_stat_statements extension + access
--                (pg_read_all_stats recommended)
-- Compatibility: PostgreSQL 12+; any pg_stat_statements version
-- Notes:         To rank by a different metric, change the ORDER BY expression
--                passed as %1$s (e.g. rank by mean_s for "slowest per call",
--                or by calls for "chattiest"). Reset counters with:
--                  SELECT pg_stat_statements_reset();  -- requires privilege
-- ============================================================================

DROP TABLE IF EXISTS tmp_pgss_top;
CREATE TEMP TABLE tmp_pgss_top
(
  rank                 integer,
  dbname               text,
  username             text,
  queryid              bigint,
  calls                bigint,
  total_s              double precision,
  mean_s               double precision,
  min_s                double precision,
  max_s                double precision,
  rows                 bigint,
  rows_per_call        numeric,
  shared_blks_hit      bigint,
  shared_blks_read     bigint,
  cache_hit_pct        numeric,
  temp_blks_written    bigint,
  query                text
);

DO $$
DECLARE
  pgss_oid    oid;
  pgss_schema text;
  pgss_rel    text;

  -- Timing expressions in milliseconds (as reported by pg_stat_statements)
  total_expr_ms text;
  mean_expr_ms  text;
  min_expr_ms   text;
  max_expr_ms   text;

  has_pgss boolean;

  has_total_exec boolean;
  has_total_time boolean;
  has_mean_exec  boolean;
  has_mean_time  boolean;
  has_min_exec   boolean;
  has_min_time   boolean;
  has_max_exec   boolean;
  has_max_time   boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
  INTO has_pgss;

  IF NOT has_pgss THEN
    INSERT INTO tmp_pgss_top(rank, query)
    VALUES (1, 'pg_stat_statements extension is not installed in this database.');
    RETURN;
  END IF;

  -- Find the schema/oid where the view is installed (usually public)
  SELECT c.oid, n.nspname
  INTO pgss_oid, pgss_schema
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relname = 'pg_stat_statements'
    AND c.relkind IN ('v','m')
  ORDER BY n.nspname
  LIMIT 1;

  IF pgss_oid IS NULL THEN
    INSERT INTO tmp_pgss_top(rank, query)
    VALUES (1, 'pg_stat_statements relation not found (installed in another schema or not visible).');
    RETURN;
  END IF;

  pgss_rel := format('%I.%I', pgss_schema, 'pg_stat_statements');

  -- Detect which timing columns this extension version exposes
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'total_exec_time' AND NOT attisdropped) INTO has_total_exec;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'total_time'      AND NOT attisdropped) INTO has_total_time;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'mean_exec_time'  AND NOT attisdropped) INTO has_mean_exec;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'mean_time'       AND NOT attisdropped) INTO has_mean_time;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'min_exec_time'   AND NOT attisdropped) INTO has_min_exec;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'min_time'        AND NOT attisdropped) INTO has_min_time;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'max_exec_time'   AND NOT attisdropped) INTO has_max_exec;
  SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pgss_oid AND attname = 'max_time'        AND NOT attisdropped) INTO has_max_time;

  -- Build millisecond expressions for whichever columns exist
  IF has_total_exec THEN total_expr_ms := 's.total_exec_time';
  ELSIF has_total_time THEN total_expr_ms := 's.total_time';
  ELSE total_expr_ms := 'NULL::double precision';
  END IF;

  IF has_mean_exec THEN mean_expr_ms := 's.mean_exec_time';
  ELSIF has_mean_time THEN mean_expr_ms := 's.mean_time';
  ELSE mean_expr_ms := format('(%s / NULLIF(s.calls, 0))', total_expr_ms);
  END IF;

  IF has_min_exec THEN min_expr_ms := 's.min_exec_time';
  ELSIF has_min_time THEN min_expr_ms := 's.min_time';
  ELSE min_expr_ms := 'NULL::double precision';
  END IF;

  IF has_max_exec THEN max_expr_ms := 's.max_exec_time';
  ELSIF has_max_time THEN max_expr_ms := 's.max_time';
  ELSE max_expr_ms := 'NULL::double precision';
  END IF;

  -- Insert results, converting ms -> seconds and deriving ratios
  EXECUTE format($sql$
    INSERT INTO tmp_pgss_top
    SELECT
      row_number() OVER (ORDER BY %1$s DESC NULLS LAST) AS rank,
      d.datname AS dbname,
      r.rolname AS username,
      s.queryid,
      s.calls,
      (%1$s / 1000.0) AS total_s,
      (%2$s / 1000.0) AS mean_s,
      (%3$s / 1000.0) AS min_s,
      (%4$s / 1000.0) AS max_s,
      s.rows,
      ROUND(s.rows::numeric / NULLIF(s.calls, 0), 1) AS rows_per_call,
      s.shared_blks_hit,
      s.shared_blks_read,
      ROUND(
        100.0 * s.shared_blks_hit
        / NULLIF(s.shared_blks_hit + s.shared_blks_read, 0), 1
      ) AS cache_hit_pct,
      s.temp_blks_written,
      left(regexp_replace(s.query, '\s+', ' ', 'g'), 2000) AS query
    FROM %5$s s
    JOIN pg_database d ON d.oid = s.dbid
    JOIN pg_roles r    ON r.oid = s.userid
    WHERE d.datname NOT IN ('template0', 'template1')
    ORDER BY %1$s DESC NULLS LAST
    LIMIT 50
  $sql$, total_expr_ms, mean_expr_ms, min_expr_ms, max_expr_ms, pgss_rel);

END $$;

SELECT *
FROM tmp_pgss_top
ORDER BY rank;