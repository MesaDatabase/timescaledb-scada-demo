-- ============================================================================
-- Script:        01_types.sql
-- Folder:        02_schema
-- Purpose:       All enumerated types for the SCADA demo schema, created
--                up front so every later script can reference them.
-- Safe in prod:  N/A -- demo schema bootstrap.
-- Requires:      00_init.sql
-- Compatibility: PostgreSQL 14+
-- Notes:         Enums are used where the value set is owned by the database
--                design (statuses, qualities). Operator-extensible lists
--                (device types) use reference tables instead -- adding an
--                enum label requires DDL; adding a reference row does not.
-- ============================================================================

SET search_path = scada, public;

-- How a point's value is physically stored in readings
CREATE TYPE point_value_type AS ENUM ('int64', 'float64', 'numeric');

-- How a point's raw values convert into rollups/reports
CREATE TYPE rollup_method AS ENUM (
    'sum', 'avg', 'power_to_energy', 'sum_hour_avg', 'accumulator_to_energy'
);

-- Quality attached to each reading / aggregate
CREATE TYPE data_quality AS ENUM (
    'online', 'offline', 'mixed', 'over_range', 'under_range', 'estimated', 'error'
);

-- Raw change events vs keep-alive heartbeats from the field gateway
CREATE TYPE reading_type AS ENUM ('raw', 'heartbeat');

-- Device lifecycle
CREATE TYPE device_status AS ENUM ('active', 'disabled');

-- Value-map flavor: translate ints to labels, or decode bit positions
CREATE TYPE value_map_type AS ENUM ('translation', 'bitmask');

-- Control request lifecycle
CREATE TYPE control_status AS ENUM (
    'queued', 'accepted', 'rejected', 'scheduled', 'active',
    'completed', 'failed', 'cancelled', 'not_found', 'superseded'
);

-- Where a control request originated
CREATE TYPE control_source AS ENUM (
    'hmi', 'api', 'plc', 'scheduler', 'dispatch', 'system'
);

-- Control schedule lifecycle and repeat units
CREATE TYPE schedule_status AS ENUM ('draft', 'ready', 'active', 'disabled');
CREATE TYPE repeat_unit     AS ENUM ('minutes', 'hours', 'days', 'weeks');

-- Alarm subsystem
CREATE TYPE alarm_severity AS ENUM ('information', 'low', 'medium', 'high', 'critical');

CREATE TYPE alarm_type AS ENUM (
    'point_analysis', 'point_group_deviation', 'performance_analysis',
    'missing_data', 'data_quality', 'point_activity', 'device_analysis',
    'bitmask_analysis', 'suppression', 'system'
);

CREATE TYPE analysis_type AS ENUM ('rate', 'duration');

CREATE TYPE boolean_operator AS ENUM ('all', 'any');

CREATE TYPE expression_role AS ENUM ('raise', 'clear');