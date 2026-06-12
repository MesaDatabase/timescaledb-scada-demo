-- ============================================================================
-- Script:        04_alarm_tables.sql
-- Folder:        02_schema
-- Purpose:       Alarm subsystem: definitions (what to watch), expressions
--                (raise/clear conditions), dependencies (suppression),
--                history (one row per alarm occurrence lifecycle), and
--                events (high-volume evaluation log, hypertable).
-- Safe in prod:  N/A -- demo schema bootstrap.
-- Requires:      00_init.sql .. 03_hypertables.sql
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- alarm_definitions: configured rules. Raise/clear occurrence limits within
-- a timeframe implement debouncing (N occurrences in M seconds), optionally
-- gated to a time-of-day window.
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_definitions (
    alarm_definition_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id               UUID NOT NULL REFERENCES sites(site_id),
    name                  TEXT NOT NULL,
    description           TEXT,
    resolution            TEXT,                 -- operator guidance when it fires
    device_id             UUID REFERENCES devices(device_id),
    point_id              UUID REFERENCES points(point_id),
    severity              alarm_severity NOT NULL,
    analysis_type         analysis_type NOT NULL,
    alarm_type            alarm_type NOT NULL,
    raise_occurrence_limit INT NOT NULL DEFAULT 1,
    raise_timeframe_s      INT NOT NULL DEFAULT 0,
    clear_occurrence_limit INT NOT NULL DEFAULT 1,
    clear_timeframe_s      INT NOT NULL DEFAULT 0,
    raise_window_start_s   INT,                 -- seconds past local midnight; NULL = always
    clear_window_start_s   INT,
    can_be_shelved         BOOLEAN NOT NULL DEFAULT true,
    require_acknowledgement BOOLEAN NOT NULL DEFAULT false,
    require_cleared_acknowledged BOOLEAN NOT NULL DEFAULT false,
    raise_match_operator   boolean_operator NOT NULL DEFAULT 'any',
    clear_match_operator   boolean_operator NOT NULL DEFAULT 'any',
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX ix_alarm_definitions_site ON alarm_definitions (site_id);

-- ---------------------------------------------------------------------------
-- alarm_definition_expressions: the individual conditions. Expressions share
-- a group_number; groups combine via group_operator, groups-of-groups via
-- the definition's raise/clear match operator.
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_definition_expressions (
    expression_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alarm_definition_id UUID NOT NULL REFERENCES alarm_definitions(alarm_definition_id),
    device_id           UUID REFERENCES devices(device_id),
    point_id            UUID REFERENCES points(point_id),
    point_value         NUMERIC,
    comparison_operator TEXT,                   -- '>', '>=', '=', '<>', '<', '<='
    evaluation_order    INT,
    bit_position        INT,                    -- for bitmask analysis
    role                expression_role NOT NULL DEFAULT 'raise',
    group_operator      boolean_operator NOT NULL DEFAULT 'any',
    group_number        INT NOT NULL DEFAULT 1
);

CREATE INDEX ix_alarm_expressions_definition
    ON alarm_definition_expressions (alarm_definition_id);

-- ---------------------------------------------------------------------------
-- alarm_definition_dependencies: suppression -- "don't raise X while Y is
-- active" (e.g. suppress per-inverter alarms during a site-wide outage).
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_definition_dependencies (
    dependent_alarm_definition_id  UUID NOT NULL REFERENCES alarm_definitions(alarm_definition_id),
    limited_by_alarm_definition_id UUID NOT NULL REFERENCES alarm_definitions(alarm_definition_id),
    PRIMARY KEY (dependent_alarm_definition_id, limited_by_alarm_definition_id)
);

-- ---------------------------------------------------------------------------
-- alarm_history: one row per alarm occurrence, mutated through its lifecycle
-- (raised -> acknowledged -> cleared). Regular table: bounded row count,
-- heavy updates -- a poor compression candidate by design.
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_history (
    alarm_history_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alarm_definition_id UUID NOT NULL REFERENCES alarm_definitions(alarm_definition_id),
    site_id             UUID NOT NULL REFERENCES sites(site_id),
    alarm_name          TEXT,
    source              TEXT,
    is_system_alarm     BOOLEAN NOT NULL DEFAULT false,
    alarm_hash          TEXT,                   -- dedup key for the alarm engine
    instance            TEXT,
    device_id           UUID REFERENCES devices(device_id),
    point_id            UUID REFERENCES points(point_id),
    severity            alarm_severity,
    is_active           BOOLEAN NOT NULL,
    message             TEXT,
    note                TEXT,
    raised_at           TIMESTAMPTZ NOT NULL,
    cleared_at          TIMESTAMPTZ,
    acknowledged_at     TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Partial index: the active-alarm board is the hottest alarm query, and
-- active rows are a tiny fraction of the table.
CREATE INDEX ix_alarm_history_active
    ON alarm_history (site_id, severity, raised_at DESC)
    WHERE is_active;

CREATE INDEX ix_alarm_history_raised ON alarm_history (site_id, raised_at DESC);

-- ---------------------------------------------------------------------------
-- alarm_events: every evaluation that contributed to an occurrence --
-- high-volume, append-only, time-ordered: a hypertable.
--
-- Design note vs. a regular table: a hypertable cannot carry a UNIQUE
-- constraint that omits the partition column, so the source pattern of a
-- global UNIQUE(alarm_event_id) is traded away for (created_at,
-- alarm_event_id). Uniqueness of the UUID is enforced at the writer.
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_events (
    site_id             UUID NOT NULL,
    alarm_event_id      UUID NOT NULL,
    alarm_history_id    UUID NOT NULL,
    alarm_definition_id UUID,
    event_time          TIMESTAMPTZ NOT NULL,
    message             TEXT NOT NULL,
    event_condition     TEXT NOT NULL,          -- 'raise' / 'clear' / expression text
    alarm_inputs        TEXT,
    alarm_outputs       TEXT,
    point_id            UUID,
    bit_position        INT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (created_at, alarm_event_id)
);

SELECT create_hypertable('scada.alarm_events', by_range('created_at', INTERVAL '7 days'));

ALTER TABLE alarm_events SET (
    timescaledb.compress,
    timescaledb.compress_orderby   = 'created_at DESC',
    timescaledb.compress_segmentby = 'alarm_definition_id'
);

CREATE INDEX ix_alarm_events_history ON alarm_events (alarm_history_id, created_at DESC);

COMMENT ON TABLE alarm_definitions IS 'Configured alarm rules with debounce and time-of-day gating.';
COMMENT ON TABLE alarm_history     IS 'One row per alarm occurrence lifecycle (raise/ack/clear).';
COMMENT ON TABLE alarm_events      IS 'High-volume evaluation log; hypertable with compression.';