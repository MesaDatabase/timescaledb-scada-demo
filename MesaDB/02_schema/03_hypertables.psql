-- ============================================================================
-- Script:        03_hypertables.sql
-- Folder:        02_schema
-- Purpose:       The time-series core: point_readings (telemetry),
--                control_requests (live queue) and control_requests_history
--                (audit). Hypertable conversion, compression SETTINGS, and
--                the supporting indexes.
-- Safe in prod:  N/A -- demo schema bootstrap.
-- Requires:      00_init.sql, 01_types.sql, 02_reference_tables.sql
-- Compatibility: TimescaleDB 2.13+ (by_range dimension builder)
-- Notes:         Compression *settings* (segmentby/orderby) are structural
--                and belong here; compression/retention *policies* (the
--                scheduled jobs) live in 04_policies.
--                Chunk interval is 1 day -- small for production telemetry,
--                deliberate for the demo: seeding 60-90 days of data yields
--                enough chunks to make compression and retention visible.
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- point_readings: every value change reported from the field.
--
-- Design notes (these mirror hard-won production patterns):
--   * Wide value columns (one per storage type) instead of a single TEXT/JSONB
--     column: native types compress dramatically better and aggregate without
--     casting. points.value_type says which column is populated.
--   * PK (event_time, point_id): the partition column must lead any unique
--     constraint on a hypertable.
--   * Compression segmentby = point_id, orderby = event_time DESC: compressed
--     chunks are organized for the dominant query shape, "one point's history,
--     newest first". After compression these settings effectively REPLACE
--     b-tree indexes inside compressed chunks.
-- ---------------------------------------------------------------------------
CREATE TABLE point_readings (
    event_time    TIMESTAMPTZ NOT NULL,
    point_id      UUID NOT NULL,
    reading_type  reading_type NOT NULL DEFAULT 'raw',
    value_bigint  BIGINT,
    value_double  DOUBLE PRECISION,
    value_numeric NUMERIC,
    data_quality  data_quality NOT NULL,
    quality_flags INT,
    PRIMARY KEY (event_time, point_id)
);

SELECT create_hypertable('scada.point_readings', by_range('event_time', INTERVAL '1 day'));

ALTER TABLE point_readings SET (
    timescaledb.compress,
    timescaledb.compress_orderby   = 'event_time DESC',
    timescaledb.compress_segmentby = 'point_id'
);

-- Dominant access path on uncompressed chunks: one point, time-descending
CREATE INDEX ix_point_readings_point_time ON point_readings (point_id, event_time DESC);

-- ---------------------------------------------------------------------------
-- control_requests: live command queue (operator setpoints, dispatch, PLC).
-- PK (created_at, control_request_id) -- again, partition column leads.
-- ---------------------------------------------------------------------------
CREATE TABLE control_requests (
    control_request_id        UUID NOT NULL,
    parent_control_request_id UUID,
    cancel_control_request_id UUID,
    function_code             INT NOT NULL,
    value                     NUMERIC(18, 9)[] NOT NULL,
    executed_at               TIMESTAMPTZ,
    scheduled_at              TIMESTAMPTZ,
    device_id                 UUID,
    point_id                  UUID,
    mode                      INT,
    status                    control_status NOT NULL DEFAULT 'queued',
    dispatch_id               INT,
    description               TEXT,
    site_id                   UUID NOT NULL,
    source                    control_source,
    created_by                UUID NOT NULL,
    updated_by                UUID NOT NULL,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (created_at, control_request_id)
);

SELECT create_hypertable('scada.control_requests', by_range('created_at', INTERVAL '7 days'));

ALTER TABLE control_requests SET (
    timescaledb.compress,
    timescaledb.compress_orderby   = 'created_at DESC',
    timescaledb.compress_segmentby = 'device_id'
);

-- Expression index tuned to the hottest dashboard query: "open requests for a
-- site, newest first". The CASE collapses the four in-flight statuses to a
-- single leading value so the planner can range-scan straight to them --
-- a measured, significant win over a plain (site_id, status) index when the
-- query itself uses the same CASE.
CREATE INDEX ix_control_requests_open ON control_requests
(
    site_id,
    (CASE WHEN status IN ('queued', 'accepted', 'scheduled', 'active') THEN 1 ELSE 9 END),
    created_at DESC,
    control_request_id
) INCLUDE (status);

-- ---------------------------------------------------------------------------
-- control_requests_history: append-only audit of every request and update,
-- including internally-issued requests that never hit the live queue.
-- Written exclusively by scada.submit_control_request (05_functions_config).
-- ---------------------------------------------------------------------------
CREATE TABLE control_requests_history (
    control_request_id        UUID NOT NULL,
    parent_control_request_id UUID,
    cancel_control_request_id UUID,
    function_code             INT NOT NULL,
    value                     NUMERIC(18, 9)[] NOT NULL,
    executed_at               TIMESTAMPTZ,
    scheduled_at              TIMESTAMPTZ,
    device_id                 UUID,
    point_id                  UUID,
    mode                      INT,
    status                    control_status NOT NULL DEFAULT 'queued',
    dispatch_id               INT,
    description               TEXT,
    is_internal               BOOLEAN,
    site_id                   UUID NOT NULL,
    source                    control_source,
    created_by                UUID NOT NULL,
    updated_by                UUID NOT NULL,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

SELECT create_hypertable('scada.control_requests_history', by_range('created_at', INTERVAL '7 days'));

ALTER TABLE control_requests_history SET (
    timescaledb.compress,
    timescaledb.compress_orderby   = 'created_at DESC',
    timescaledb.compress_segmentby = 'device_id'
);

-- Audit lookups arrive by request id, not by time
CREATE INDEX ix_control_requests_history_request
    ON control_requests_history (control_request_id);

-- ---------------------------------------------------------------------------
-- No foreign keys FROM hypertables to reference tables: FK validation on
-- billions of rows is a write-amplification tax, and TimescaleDB compression
-- historically restricts them. Referential integrity for telemetry is
-- enforced at the ingest boundary (05_functions_config) -- a deliberate,
-- documented trade-off, not an oversight.
-- ---------------------------------------------------------------------------

COMMENT ON TABLE point_readings           IS 'Telemetry hypertable: one row per value change per point. 1-day chunks.';
COMMENT ON TABLE control_requests         IS 'Live control/command queue hypertable.';
COMMENT ON TABLE control_requests_history IS 'Append-only audit of all control requests, including internal.';