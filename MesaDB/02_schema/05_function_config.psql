-- ============================================================================
-- Script:        05_functions_config.sql
-- Folder:        02_schema
-- Purpose:       Write-path API: idempotent "last writer wins" upserts for
--                config entities, and submit_control_request -- the dual-write
--                pattern that keeps a live queue and a complete audit trail
--                in one transaction.
-- Safe in prod:  N/A -- demo schema bootstrap.
-- Requires:      00_init.sql .. 04_alarm_tables.sql
-- Compatibility: PostgreSQL 14+
-- Notes:         The upserts use ON CONFLICT ... WHERE EXCLUDED.updated_at >
--                target.updated_at: an out-of-order or replayed config sync
--                message can never overwrite newer data. Replay-safe ingest
--                without distributed locks.
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- upsert_device: insert or update, but never let stale data win.
-- Returns NULL when the row was skipped as stale -- callers can detect it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.upsert_device(
    _device_id       UUID,
    _site_id         UUID,
    _name            TEXT,
    _device_type_id  INT,
    _device_model    TEXT        DEFAULT NULL,
    _is_controllable BOOLEAN     DEFAULT false,
    _status          device_status DEFAULT 'active',
    _updated_at      TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _return_id UUID;
BEGIN
    _updated_at := COALESCE(_updated_at, CURRENT_TIMESTAMP);

    INSERT INTO devices (device_id, site_id, name, device_type_id,
                         device_model, is_controllable, status, updated_at)
    VALUES (_device_id, _site_id, _name, _device_type_id,
            _device_model, _is_controllable, _status, _updated_at)
    ON CONFLICT (device_id)
    DO UPDATE SET
        site_id         = EXCLUDED.site_id,
        name            = EXCLUDED.name,
        device_type_id  = EXCLUDED.device_type_id,
        device_model    = EXCLUDED.device_model,
        is_controllable = EXCLUDED.is_controllable,
        status          = EXCLUDED.status,
        updated_at      = EXCLUDED.updated_at
    WHERE EXCLUDED.updated_at > devices.updated_at
    RETURNING device_id INTO _return_id;

    RETURN _return_id;   -- NULL => skipped as stale
END;
$func$;

-- ---------------------------------------------------------------------------
-- upsert_point: same pattern for the point catalog.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.upsert_point(
    _point_id      UUID,
    _site_id       UUID,
    _name          TEXT,
    _value_type    point_value_type,
    _eng_low       NUMERIC(24,7),
    _eng_high      NUMERIC(24,7),
    _display_name  TEXT          DEFAULT NULL,
    _description   TEXT          DEFAULT NULL,
    _point_kind    INT           DEFAULT NULL,
    _low_label     TEXT          DEFAULT NULL,
    _high_label    TEXT          DEFAULT NULL,
    _uom           TEXT          DEFAULT NULL,
    _display_uom   TEXT          DEFAULT NULL,
    _rollup_method rollup_method DEFAULT NULL,
    _rollup_uom    TEXT          DEFAULT NULL,
    _display_rollup_uom TEXT     DEFAULT NULL,
    _display_precision  INT      DEFAULT NULL,
    _value_map_id  UUID          DEFAULT NULL,
    _is_derived    BOOLEAN       DEFAULT false,
    _is_analog     BOOLEAN       DEFAULT true,
    _updated_at    TIMESTAMPTZ   DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _return_id UUID;
BEGIN
    _updated_at := COALESCE(_updated_at, CURRENT_TIMESTAMP);

    INSERT INTO points (point_id, site_id, name, display_name, description,
                        point_kind, value_type, eng_low, eng_high, low_label,
                        high_label, uom, display_uom, rollup_method, rollup_uom,
                        display_rollup_uom, display_precision, value_map_id,
                        is_derived, is_analog, updated_at)
    VALUES (_point_id, _site_id, _name, _display_name, _description,
            _point_kind, _value_type, _eng_low, _eng_high, _low_label,
            _high_label, _uom, _display_uom, _rollup_method, _rollup_uom,
            _display_rollup_uom, _display_precision, _value_map_id,
            _is_derived, _is_analog, _updated_at)
    ON CONFLICT (point_id)
    DO UPDATE SET
        site_id            = EXCLUDED.site_id,
        name               = EXCLUDED.name,
        display_name       = EXCLUDED.display_name,
        description        = EXCLUDED.description,
        point_kind         = EXCLUDED.point_kind,
        value_type         = EXCLUDED.value_type,
        eng_low            = EXCLUDED.eng_low,
        eng_high           = EXCLUDED.eng_high,
        low_label          = EXCLUDED.low_label,
        high_label         = EXCLUDED.high_label,
        uom                = EXCLUDED.uom,
        display_uom        = EXCLUDED.display_uom,
        rollup_method      = EXCLUDED.rollup_method,
        rollup_uom         = EXCLUDED.rollup_uom,
        display_rollup_uom = EXCLUDED.display_rollup_uom,
        display_precision  = EXCLUDED.display_precision,
        value_map_id       = EXCLUDED.value_map_id,
        is_derived         = EXCLUDED.is_derived,
        is_analog          = EXCLUDED.is_analog,
        updated_at         = EXCLUDED.updated_at
    WHERE EXCLUDED.updated_at > points.updated_at
    RETURNING point_id INTO _return_id;

    RETURN _return_id;
END;
$func$;

-- ---------------------------------------------------------------------------
-- submit_control_request: the dual-write audit pattern.
--   * External requests upsert into the live queue (last-writer-wins on
--     updated_at, so status transitions replay safely)...
--   * ...and EVERY call -- external or internal, insert or update -- appends
--     an immutable row to control_requests_history.
-- One transaction, one function, no trigger magic: the audit trail can never
-- diverge from the queue, and internal/system requests are auditable without
-- polluting the operator-facing queue.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.submit_control_request(
    _control_request_id UUID,
    _function_code      INT,
    _value              NUMERIC(18,9)[],
    _status             control_status,
    _source             control_source,
    _site_id            UUID,
    _created_by         UUID,
    _updated_by         UUID,
    _parent_control_request_id UUID  DEFAULT NULL,
    _cancel_control_request_id UUID  DEFAULT NULL,
    _created_at   TIMESTAMPTZ DEFAULT NULL,
    _updated_at   TIMESTAMPTZ DEFAULT NULL,
    _executed_at  TIMESTAMPTZ DEFAULT NULL,
    _scheduled_at TIMESTAMPTZ DEFAULT NULL,
    _device_id    UUID        DEFAULT NULL,
    _point_id     UUID        DEFAULT NULL,
    _mode         INT         DEFAULT NULL,
    _dispatch_id  INT         DEFAULT NULL,
    _description  TEXT        DEFAULT NULL,
    _is_internal  BOOLEAN     DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _return_id UUID;
BEGIN
    _created_at := COALESCE(_created_at, CURRENT_TIMESTAMP);
    _updated_at := COALESCE(_updated_at, CURRENT_TIMESTAMP);

    -- Internal requests bypass the live queue; they exist only in the audit.
    IF _is_internal IS NOT TRUE THEN
        INSERT INTO control_requests (
            control_request_id, parent_control_request_id, cancel_control_request_id,
            function_code, value, executed_at, scheduled_at, device_id, point_id,
            mode, status, source, dispatch_id, description, site_id,
            created_by, updated_by, created_at, updated_at
        )
        VALUES (
            _control_request_id, _parent_control_request_id, _cancel_control_request_id,
            _function_code, _value, _executed_at, _scheduled_at, _device_id, _point_id,
            _mode, _status, _source, _dispatch_id, _description, _site_id,
            _created_by, _updated_by, _created_at, _updated_at
        )
        ON CONFLICT (created_at, control_request_id)
        DO UPDATE SET
            parent_control_request_id = EXCLUDED.parent_control_request_id,
            cancel_control_request_id = EXCLUDED.cancel_control_request_id,
            function_code = EXCLUDED.function_code,
            value         = EXCLUDED.value,
            executed_at   = EXCLUDED.executed_at,
            scheduled_at  = EXCLUDED.scheduled_at,
            device_id     = EXCLUDED.device_id,
            point_id      = EXCLUDED.point_id,
            mode          = EXCLUDED.mode,
            status        = EXCLUDED.status,
            source        = EXCLUDED.source,
            dispatch_id   = EXCLUDED.dispatch_id,
            description   = EXCLUDED.description,
            updated_by    = EXCLUDED.updated_by,
            updated_at    = EXCLUDED.updated_at
        WHERE EXCLUDED.updated_at > control_requests.updated_at
        RETURNING control_request_id INTO _return_id;
    END IF;

    -- Unconditional append to the audit trail.
    INSERT INTO control_requests_history (
        control_request_id, parent_control_request_id, cancel_control_request_id,
        function_code, value, executed_at, scheduled_at, device_id, point_id,
        mode, status, source, dispatch_id, description, is_internal, site_id,
        created_by, updated_by, created_at, updated_at
    )
    VALUES (
        _control_request_id, _parent_control_request_id, _cancel_control_request_id,
        _function_code, _value, _executed_at, _scheduled_at, _device_id, _point_id,
        _mode, _status, _source, _dispatch_id, _description, _is_internal, _site_id,
        _created_by, _updated_by, _created_at, _updated_at
    );

    RETURN _return_id;
END;
$func$;

-- ---------------------------------------------------------------------------
-- get_device_point_tree: the device hierarchy with attached points, as a
-- recursive CTE. Drives "site explorer" style UIs; also handy in the demo
-- to show what the seeder built.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.get_device_point_tree(_site_id UUID)
RETURNS TABLE (
    node_type        TEXT,
    depth            INT,
    device_id        UUID,
    parent_device_id UUID,
    name             TEXT,
    device_type      TEXT,
    point_id         UUID,
    uom              TEXT,
    is_analog        BOOLEAN
)
LANGUAGE sql
STABLE
SET search_path = scada, public
AS $func$
    WITH RECURSIVE tree AS (
        -- Roots: devices with no parent
        SELECT d.device_id, NULL::uuid AS parent_device_id, d.name,
               d.device_type_id, 1 AS depth
        FROM devices d
        WHERE d.site_id = _site_id
          AND NOT EXISTS (
              SELECT 1 FROM device_hierarchy h WHERE h.child_device_id = d.device_id
          )
        UNION ALL
        SELECT c.device_id, h.parent_device_id, c.name, c.device_type_id, t.depth + 1
        FROM device_hierarchy h
        JOIN tree    t ON t.device_id = h.parent_device_id
        JOIN devices c ON c.device_id = h.child_device_id
    )
    SELECT 'device' AS node_type, t.depth, t.device_id, t.parent_device_id,
           t.name, dt.name AS device_type,
           NULL::uuid AS point_id, NULL::text AS uom, NULL::boolean AS is_analog
    FROM tree t
    JOIN device_types dt ON dt.device_type_id = t.device_type_id

    UNION ALL

    SELECT 'point', t.depth + 1, NULL, t.device_id,
           COALESCE(p.display_name, p.name), NULL,
           p.point_id, p.uom, p.is_analog
    FROM tree t
    JOIN device_points dp ON dp.device_id = t.device_id
    JOIN points p         ON p.point_id   = dp.point_id
    ORDER BY depth, name;
$func$;