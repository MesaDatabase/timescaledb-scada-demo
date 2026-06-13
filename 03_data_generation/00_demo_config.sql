-- ============================================================================
-- Script:        00_demo_config.sql
-- Folder:        03_data_generation
-- Purpose:       One place to tune the entire demo: how many sites and
--                devices, how much history, how often readings arrive, how
--                chaotic the weather and equipment are. Plus typed config
--                getters and a full reset function.
-- Safe in prod:  N/A -- demo only.
-- Requires:      02_schema installed.
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- Notes:         Change values with plain UPDATEs, e.g.:
--                  UPDATE scada.demo_config SET value = '90'
--                  WHERE key = 'history_days';
--                ...then re-run 02_generate_readings.sql and
--                03_generate_activity.sql. Both are fully idempotent: they
--                wipe and rebuild their own data.
-- ============================================================================

SET search_path = scada, public;

CREATE TABLE IF NOT EXISTS demo_config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    description TEXT NOT NULL
);

-- Defaults: ~0.8M readings across 2 sites / 60 days @ 5-minute cadence.
-- Generates in well under a minute on a laptop; scale knobs up freely.
INSERT INTO demo_config (key, value, description) VALUES
  ('sites_count',          '2',          'How many demo sites to create (1-3). Each has its own timezone and weather.'),
  ('inverters_per_site',   '6',          'Solar inverters per site. Each adds 3 points (power, temperature, status).'),
  ('inverter_rated_kw',    '250',        'AC nameplate rating per inverter, kW. Clear days flat-top ("clip") at this value.'),
  ('dc_ac_ratio',          '1.25',       'DC panel capacity vs AC rating. >1 causes midday clipping -- realistic and visible.'),
  ('battery_power_kw',     '500',        'Battery max charge/discharge rate per site, kW.'),
  ('battery_capacity_kwh', '2000',       'Battery energy capacity per site, kWh. Drives state-of-charge swing.'),
  ('history_days',         '60',         'Days of history to generate, ending now. More days = more chunks to compress.'),
  ('reading_interval',     '5 minutes',  'Telemetry cadence. 1 minute = 5x the rows; 15 minutes = 1/3.'),
  ('outage_rate_per_month','1.5',        'Average equipment outages per inverter per month. Outages gap the data, raise alarms.'),
  ('storm_day_chance',     '0.12',       'Probability any given day is heavily clouded (output crushed to 15-40%).'),
  ('dispatch_per_day',     '24',         'Battery dispatch control requests per site per day (the control-room heartbeat).'),
  ('random_seed',          '0.42',       'Seed in [-1,1] for setseed(). Same seed + same config => same demo, near enough.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Typed getters so generation code reads cleanly:
--   scada.cfg_int('history_days'), scada.cfg_interval('reading_interval'), ...
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.cfg_text(_key TEXT)
RETURNS TEXT LANGUAGE sql STABLE
SET search_path = scada, public
AS $$ SELECT value FROM demo_config WHERE key = _key $$;

CREATE OR REPLACE FUNCTION scada.cfg_int(_key TEXT)
RETURNS INT LANGUAGE sql STABLE
SET search_path = scada, public
AS $$ SELECT value::int FROM demo_config WHERE key = _key $$;

CREATE OR REPLACE FUNCTION scada.cfg_float(_key TEXT)
RETURNS FLOAT8 LANGUAGE sql STABLE
SET search_path = scada, public
AS $$ SELECT value::float8 FROM demo_config WHERE key = _key $$;

CREATE OR REPLACE FUNCTION scada.cfg_interval(_key TEXT)
RETURNS INTERVAL LANGUAGE sql STABLE
SET search_path = scada, public
AS $$ SELECT value::interval FROM demo_config WHERE key = _key $$;

-- ---------------------------------------------------------------------------
-- Simulation metadata tables. These are the "script" of the demo's story --
-- generated once, then consumed by readings, alarms, AND control requests so
-- everything agrees: a cloudy day shows low power and low energy; an outage
-- shows a data gap, a fault status, an alarm, and event log entries.
-- Inspect them! e.g.: SELECT * FROM scada.sim_outages ORDER BY start_at;
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sim_weather_days (
    site_id    UUID NOT NULL,
    local_day  DATE NOT NULL,
    cloudiness FLOAT8 NOT NULL,   -- 1.0 = perfectly clear, 0.15 = storm
    PRIMARY KEY (site_id, local_day)
);

CREATE TABLE IF NOT EXISTS sim_outages (
    outage_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id  UUID NOT NULL,
    site_id    UUID NOT NULL,
    start_at   TIMESTAMPTZ NOT NULL,
    end_at     TIMESTAMPTZ NOT NULL,
    CONSTRAINT ck_sim_outages_order CHECK (end_at > start_at)
);

-- ---------------------------------------------------------------------------
-- reset_demo_data: wipe everything the generators create (config survives).
--   SELECT scada.reset_demo_data();
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.reset_demo_data()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
BEGIN
    TRUNCATE point_readings, control_requests, control_requests_history,
             alarm_events, sim_weather_days, sim_outages;
    DELETE FROM alarm_history;
    DELETE FROM alarm_definition_dependencies;
    DELETE FROM alarm_definition_expressions;
    DELETE FROM alarm_definitions;
    DELETE FROM control_schedules;
    DELETE FROM derived_point_sources;
    DELETE FROM derived_points;
    DELETE FROM device_points;
    DELETE FROM device_properties;
    DELETE FROM device_hierarchy;
    DELETE FROM points;
    DELETE FROM devices;
    DELETE FROM settings;
    DELETE FROM value_maps;
    DELETE FROM sites;
    RETURN 'Demo data cleared. Re-run 01 -> 02 -> 03 to rebuild.';
END;
$func$;

\echo 'demo_config ready. Current settings:'
SELECT key, value, description FROM scada.demo_config ORDER BY key;
