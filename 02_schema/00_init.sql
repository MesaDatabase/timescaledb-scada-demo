-- ============================================================================
-- Script:        00_init.sql
-- Folder:        02_schema
-- Purpose:       Bootstrap the demo database: required extensions, the
--                dedicated application schema, and search_path guidance.
-- Safe in prod:  N/A -- demo schema bootstrap. Idempotent (IF NOT EXISTS).
-- Requires:      PostgreSQL 14+ with TimescaleDB 2.13+ available
--                (timescale/timescaledb-ha docker image has everything).
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- Notes:         Run order for this folder:
--                  00_init -> 01_types -> 02_reference_tables ->
--                  03_hypertables -> 04_alarm_tables ->
--                  05_functions_config -> 06_functions_analytics
--                Compression/retention POLICIES and continuous aggregates are
--                deliberately not here -- structure lives in 02_schema,
--                scheduled jobs live in 04_policies.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- All application objects live in a dedicated schema rather than public:
-- cleaner grants, cleaner pg_dump, no collisions with extension objects.
CREATE SCHEMA IF NOT EXISTS scada;

COMMENT ON SCHEMA scada IS
  'Generic SCADA time-series demo: sites, devices, points, readings, controls, alarms.';

-- Make objects resolvable without qualification for this session.
-- Application roles should have this in their role-level search_path:
--   ALTER ROLE app_role SET search_path = scada, public;
SET search_path = scada, public;