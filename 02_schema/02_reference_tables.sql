-- ============================================================================
-- Script:        02_reference_tables.sql
-- Folder:        02_schema
-- Purpose:       Configuration / reference layer: sites, settings, value
--                maps, device catalog and hierarchy, point catalog, derived
--                points, control schedules, and the retention framework
--                tables consumed by the custom retention job (04_policies).
-- Safe in prod:  N/A -- demo schema bootstrap.
-- Requires:      00_init.sql, 01_types.sql
-- Compatibility: PostgreSQL 14+
-- Notes:         updated_at + "last writer wins" upserts (05_functions_config)
--                let an external config-sync process replay safely.
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- Sites: one row per plant/installation. Timezone and coordinates drive
-- rollup bucketing and the synthetic solar curve in 03_data_generation.
-- ---------------------------------------------------------------------------
CREATE TABLE sites (
    site_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    timezone        TEXT NOT NULL DEFAULT 'UTC',     -- IANA name, e.g. 'America/Chicago'
    latitude        NUMERIC(9, 6),
    longitude       NUMERIC(9, 6),
    capacity_kw     NUMERIC(12, 2),                  -- nameplate, for context in demos
    commissioned_on DATE,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- Per-site key/value settings
-- ---------------------------------------------------------------------------
CREATE TABLE settings (
    setting_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id      UUID NOT NULL REFERENCES sites(site_id),
    setting_name TEXT NOT NULL,
    value        TEXT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ak_settings_site_name UNIQUE (site_id, setting_name)
);

-- ---------------------------------------------------------------------------
-- Value maps: translate integer telemetry into display labels, either as a
-- direct translation (0='Stopped', 1='Running') or as bit positions.
-- ---------------------------------------------------------------------------
CREATE TABLE value_maps (
    value_map_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name           TEXT NOT NULL,
    map_type       value_map_type NOT NULL DEFAULT 'translation',
    display_values TEXT[]    NOT NULL,
    int_values     INTEGER[] NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_value_maps_parallel_arrays
        CHECK (cardinality(display_values) = cardinality(int_values))
);

-- ---------------------------------------------------------------------------
-- Device catalog. device_types is a reference table (not an enum) so new
-- equipment classes are an INSERT, not a migration.
-- ---------------------------------------------------------------------------
CREATE TABLE device_types (
    device_type_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           TEXT NOT NULL UNIQUE      -- 'inverter', 'battery', 'meter', ...
);

CREATE TABLE devices (
    device_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id         UUID NOT NULL REFERENCES sites(site_id),
    name            TEXT NOT NULL,
    status          device_status NOT NULL DEFAULT 'active',
    device_type_id  INT NOT NULL REFERENCES device_types(device_type_id),
    device_model    TEXT,
    is_controllable BOOLEAN NOT NULL DEFAULT false,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX ix_devices_site_id ON devices (site_id, device_id);

-- Parent/child relationships (e.g. combiner -> inverter -> tracker rows)
CREATE TABLE device_hierarchy (
    parent_device_id UUID NOT NULL REFERENCES devices(device_id),
    child_device_id  UUID NOT NULL REFERENCES devices(device_id),
    alias_name       TEXT NOT NULL,
    PRIMARY KEY (parent_device_id, child_device_id),
    CONSTRAINT ck_device_hierarchy_no_self CHECK (parent_device_id <> child_device_id)
);

-- Named static or point-backed properties of a device
CREATE TABLE device_properties (
    device_property_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id          UUID NOT NULL REFERENCES devices(device_id),
    name               TEXT NOT NULL,
    static_value       DOUBLE PRECISION,
    point_id           UUID,            -- FK added after points exists (below)
    uom                TEXT,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- Point catalog: every measurable/controllable signal in the system.
-- Index shape mirrors a production pattern: (site_id, point_id) supports
-- the dominant "all points for a site" config queries.
-- ---------------------------------------------------------------------------
CREATE TABLE points (
    point_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id           UUID NOT NULL REFERENCES sites(site_id),
    name              TEXT NOT NULL,                -- machine name, e.g. 'INV01.AC_POWER'
    display_name      TEXT,
    description       TEXT,
    point_kind        INT,                          -- integrator-defined classification code
    value_type        point_value_type NOT NULL,
    eng_low           NUMERIC(24, 7) NOT NULL,      -- engineering range for scaling/validation
    eng_high          NUMERIC(24, 7) NOT NULL,
    low_label         TEXT,
    high_label        TEXT,
    uom               TEXT,                         -- raw unit, e.g. 'kW'
    display_uom       TEXT,
    rollup_method     rollup_method,
    rollup_uom        TEXT,                         -- e.g. 'kWh' for power_to_energy points
    display_rollup_uom TEXT,
    display_precision INT,
    value_map_id      UUID REFERENCES value_maps(value_map_id),
    is_derived        BOOLEAN NOT NULL DEFAULT false,
    is_analog         BOOLEAN NOT NULL DEFAULT true,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_points_eng_range CHECK (eng_high >= eng_low)
);

CREATE INDEX ix_points_site_point ON points (site_id, point_id);

ALTER TABLE device_properties
    ADD CONSTRAINT fk_device_properties_point
    FOREIGN KEY (point_id) REFERENCES points(point_id);

-- Device <-> point mapping
CREATE TABLE device_points (
    device_id UUID NOT NULL REFERENCES devices(device_id),
    point_id  UUID NOT NULL REFERENCES points(point_id),
    PRIMARY KEY (device_id, point_id)
);

CREATE INDEX ix_device_points_point ON device_points (point_id);

-- ---------------------------------------------------------------------------
-- Derived (calculated) points: a point whose value is computed from one or
-- more source points (e.g. site total = sum of inverter outputs).
-- ---------------------------------------------------------------------------
CREATE TABLE derived_points (
    point_id            UUID PRIMARY KEY REFERENCES points(point_id),
    calc_code           INT NOT NULL,               -- calculation selector for the calc engine
    constant_value      NUMERIC(20, 7),
    quality_point_id    UUID REFERENCES points(point_id),
    require_all_sources BOOLEAN NOT NULL DEFAULT false,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE derived_point_sources (
    point_id        UUID NOT NULL REFERENCES derived_points(point_id),
    source_point_id UUID NOT NULL REFERENCES points(point_id),
    parameter_order INT NOT NULL,
    PRIMARY KEY (point_id, source_point_id)
);

-- ---------------------------------------------------------------------------
-- Control schedules: recurring setpoint programs (e.g. battery charge windows)
-- ---------------------------------------------------------------------------
CREATE TABLE control_schedules (
    site_id         UUID NOT NULL REFERENCES sites(site_id),
    schedule_id     INT GENERATED ALWAYS AS IDENTITY,
    name            TEXT,
    priority        INT NOT NULL DEFAULT 100,
    start_at        TIMESTAMPTZ NOT NULL,
    repeat_interval INT NOT NULL DEFAULT 0,
    repeat_units    repeat_unit NOT NULL DEFAULT 'days',
    status          schedule_status NOT NULL DEFAULT 'draft',
    points_config   JSONB,                          -- point/value pairs the schedule applies
    is_ready        BOOLEAN NOT NULL DEFAULT false,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (site_id, schedule_id)
);

-- ---------------------------------------------------------------------------
-- Retention framework tables. The enforcement function + scheduled job that
-- consume these live in 04_policies (custom job with per-table logging --
-- richer observability than bare add_retention_policy).
-- ---------------------------------------------------------------------------
CREATE TABLE retention_settings (
    setting_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hypertable_name TEXT NOT NULL UNIQUE,
    retention_days  INT NOT NULL CHECK (retention_days >= 0),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE retention_logs (
    log_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    hypertable_name TEXT NOT NULL,
    deleted_chunks  INT DEFAULT 0,
    duration        INTERVAL,
    status          TEXT NOT NULL,
    error_message   TEXT
);

COMMENT ON TABLE sites            IS 'One row per plant/installation; timezone drives rollup bucketing.';
COMMENT ON TABLE points           IS 'Catalog of every measurable/controllable signal.';
COMMENT ON TABLE devices          IS 'Physical/logical equipment; points attach via device_points.';
COMMENT ON TABLE derived_points   IS 'Points computed from other points by the calc engine.';
COMMENT ON TABLE retention_settings IS 'Desired retention in days per hypertable; enforced by custom job in 04_policies.';