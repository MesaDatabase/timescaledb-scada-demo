-- Script: 01_baseline_extensions.sql
-- Purpose: Audit + install baseline extensions for Postgres/TimescaleDB databases
-- Safe in prod: YES if only running the audit SELECTs
--              Installing extensions is a CHANGE (review required).
-- Requires: To CREATE EXTENSION you need superuser or appropriate privileges.

-- ===== Audit: what extensions exist in this database =====
SELECT
  now() AS as_of,
  extname,
  extversion,
  n.nspname AS schema
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY extname;

-- ===== Audit: are required extensions present? =====
WITH required(extname) AS (
  VALUES
    ('timescaledb'),
    ('pg_stat_statements')
    -- Optional extensions go here
    -- ('timescaledb_toolkit')
)
SELECT
  now() AS as_of,
  r.extname,
  CASE WHEN e.extname IS NOT NULL THEN 'PRESENT' ELSE 'MISSING' END AS status
FROM required r
LEFT JOIN pg_extension e ON e.extname = r.extname
ORDER BY r.extname;

-- ===== Install section (COMMENTED OUT by default) =====
-- NOTE: pg_stat_statements also requires shared_preload_libraries configuration at the cluster level.
--       If CREATE EXTENSION fails for pg_stat_statements, infra likely needs to add it and restart.

-- CREATE EXTENSION IF NOT EXISTS timescaledb;
-- CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
-- CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;