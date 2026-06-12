-- ============================================================================
-- Script:        03_generate_activity.sql
-- Folder:        03_data_generation
-- Purpose:       Bring the control room to life:
--                  * Battery dispatch requests on a schedule, walked through
--                    their real lifecycle (queued -> accepted -> active ->
--                    completed) via submit_control_request -- so the audit
--                    history holds ~4x the rows of the live queue, exactly
--                    as production behaves.
--                  * Occasional operator curtailments and internal system
--                    requests (audit-only -- the is_internal path).
--                  * Alarms DERIVED FROM THE DATA: comms-lost alarms from
--                    the same sim_outages that gapped the readings, over-temp
--                    alarms wherever generated temperatures actually crossed
--                    the threshold, storm advisories on heavy-cloud days.
--                    Every alarm on the board is explainable by the charts.
-- Safe in prod:  N/A -- demo only. Wipes and rebuilds control + alarm data.
-- Requires:      00_demo_config.sql .. 02_generate_readings.sql
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- ============================================================================

SET search_path = scada, public;

CREATE OR REPLACE FUNCTION scada.generate_activity()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _per_day    INT  := GREATEST(scada.cfg_int('dispatch_per_day'), 1);
    _days       INT  := scada.cfg_int('history_days');
    _end        TIMESTAMPTZ := date_bin(scada.cfg_interval('reading_interval'),
                                        now(), TIMESTAMPTZ '2000-01-01');
    _start      TIMESTAMPTZ;
    _step       INTERVAL;
    _t0         TIMESTAMPTZ := clock_timestamp();

    _site       RECORD;
    _ts         TIMESTAMPTZ;
    _local_h    FLOAT8;
    _cr_id      UUID;
    _batt_point UUID;
    _batt_dev   UUID;
    _batt_kw    FLOAT8;
    _operator   UUID := gen_random_uuid();   -- demo operator identity
    _system     UUID := gen_random_uuid();   -- demo system identity
    _setpoint   NUMERIC(18,9);
    _roll       FLOAT8;
    _n_requests INT := 0;
BEGIN
    _start := _end - make_interval(days => _days);
    _step  := make_interval(secs => 86400.0 / _per_day);
    PERFORM setseed(scada.cfg_float('random_seed') / 2.0);

    TRUNCATE control_requests, control_requests_history, alarm_events;
    DELETE FROM alarm_history;

    -- =======================================================================
    -- 1) Battery dispatch: the control-room heartbeat. Each request is
    --    submitted, then re-submitted with advancing status -- the upsert
    --    keeps ONE row current in the live queue while every transition
    --    lands in control_requests_history.
    -- =======================================================================
    FOR _site IN SELECT s.site_id, s.timezone FROM sites s LOOP
        SELECT p.point_id, d.device_id, dp2.static_value
          INTO _batt_point, _batt_dev, _batt_kw
        FROM points p
        JOIN device_points dpt ON dpt.point_id = p.point_id
        JOIN devices d         ON d.device_id = dpt.device_id
        JOIN device_properties dp2 ON dp2.device_id = d.device_id AND dp2.name = 'rated_kw'
        WHERE p.site_id = _site.site_id AND p.point_kind = 4;

        _ts := _start;
        WHILE _ts < _end LOOP
            _local_h  := EXTRACT(EPOCH FROM (_ts AT TIME ZONE _site.timezone)::time) / 3600.0;
            _setpoint := round((CASE
                            WHEN _local_h >= 10 AND _local_h < 14 THEN -0.75 * _batt_kw
                            WHEN _local_h >= 18 AND _local_h < 21 THEN  0.90 * _batt_kw
                            ELSE 0.0 END)::numeric, 1);
            _cr_id := gen_random_uuid();
            _roll  := random();

            -- Born queued...
            PERFORM scada.submit_control_request(
                _control_request_id := _cr_id,
                _function_code := 10,                -- "set active power"
                _value         := ARRAY[_setpoint],
                _status        := 'queued',
                _source        := 'dispatch',
                _site_id       := _site.site_id,
                _created_by    := _system,
                _updated_by    := _system,
                _created_at    := _ts,
                _updated_at    := _ts,
                _device_id     := _batt_dev,
                _point_id      := _batt_point,
                _description   := format('Dispatch setpoint %s kW', _setpoint));

            -- ...accepted moments later...
            PERFORM scada.submit_control_request(
                _control_request_id := _cr_id, _function_code := 10,
                _value := ARRAY[_setpoint],
                _status := (CASE WHEN _roll < 0.03 THEN 'rejected' ELSE 'accepted' END)::control_status,
                _source := 'dispatch', _site_id := _site.site_id,
                _created_by := _system, _updated_by := _system,
                _created_at := _ts, _updated_at := _ts + INTERVAL '5 seconds',
                _device_id := _batt_dev, _point_id := _batt_point);

            -- ...then runs to completion (or failure), unless it's recent
            -- enough to still be in flight -- those stay on the open board.
            IF _roll >= 0.03 AND _ts < _end - INTERVAL '2 hours' THEN
                PERFORM scada.submit_control_request(
                    _control_request_id := _cr_id, _function_code := 10,
                    _value := ARRAY[_setpoint], _status := 'active',
                    _source := 'dispatch', _site_id := _site.site_id,
                    _created_by := _system, _updated_by := _system,
                    _created_at := _ts, _updated_at := _ts + INTERVAL '1 minute',
                    _executed_at := _ts + INTERVAL '1 minute',
                    _device_id := _batt_dev, _point_id := _batt_point);

                PERFORM scada.submit_control_request(
                    _control_request_id := _cr_id, _function_code := 10,
                    _value := ARRAY[_setpoint],
                    _status := (CASE WHEN _roll < 0.07 THEN 'failed' ELSE 'completed' END)::control_status,
                    _source := 'dispatch', _site_id := _site.site_id,
                    _created_by := _system, _updated_by := _system,
                    _created_at := _ts, _updated_at := _ts + INTERVAL '30 minutes',
                    _executed_at := _ts + INTERVAL '1 minute',
                    _device_id := _batt_dev, _point_id := _batt_point);
            END IF;

            _n_requests := _n_requests + 1;
            _ts := _ts + _step;
        END LOOP;

        -- A daily internal system request: audit-only (is_internal => never
        -- appears in the live queue). This is why history > live counts.
        _ts := _start + INTERVAL '6 hours';
        WHILE _ts < _end LOOP
            PERFORM scada.submit_control_request(
                _control_request_id := gen_random_uuid(),
                _function_code := 99, _value := ARRAY[0::numeric],
                _status := 'completed', _source := 'system',
                _site_id := _site.site_id,
                _created_by := _system, _updated_by := _system,
                _created_at := _ts, _updated_at := _ts,
                _description := 'Internal watchdog sync', _is_internal := true);
            _n_requests := _n_requests + 1;
            _ts := _ts + INTERVAL '1 day';
        END LOOP;
    END LOOP;

    -- Sprinkle operator curtailments: an HMI user trimming an inverter.
    -- Routed through submit_control_request like everything else -- the
    -- history table has exactly one writer.
    DECLARE
        _curt RECORD;
    BEGIN
        FOR _curt IN
            SELECT d.site_id, d.device_id, p.point_id,
                   round((rp.static_value * 0.5)::numeric, 1) AS setpoint, t.ts
            FROM devices d
            JOIN device_types dt ON dt.device_type_id = d.device_type_id AND dt.name = 'inverter'
            JOIN device_properties rp ON rp.device_id = d.device_id AND rp.name = 'rated_kw'
            JOIN device_points dp ON dp.device_id = d.device_id
            JOIN points p ON p.point_id = dp.point_id AND p.point_kind = 1
            CROSS JOIN LATERAL generate_series(_start, _end, INTERVAL '1 day') AS t(ts)
            WHERE random() < 0.04
        LOOP
            _cr_id := gen_random_uuid();
            PERFORM scada.submit_control_request(
                _control_request_id := _cr_id, _function_code := 20,
                _value := ARRAY[_curt.setpoint], _status := 'queued',
                _source := 'hmi', _site_id := _curt.site_id,
                _created_by := _operator, _updated_by := _operator,
                _created_at := _curt.ts, _updated_at := _curt.ts,
                _device_id := _curt.device_id, _point_id := _curt.point_id,
                _description := 'Manual curtailment to 50%');
            PERFORM scada.submit_control_request(
                _control_request_id := _cr_id, _function_code := 20,
                _value := ARRAY[_curt.setpoint], _status := 'completed',
                _source := 'hmi', _site_id := _curt.site_id,
                _created_by := _operator, _updated_by := _operator,
                _created_at := _curt.ts, _updated_at := _curt.ts + INTERVAL '15 minutes',
                _executed_at := _curt.ts + INTERVAL '1 minute',
                _device_id := _curt.device_id, _point_id := _curt.point_id,
                _description := 'Manual curtailment to 50%');
            _n_requests := _n_requests + 1;
        END LOOP;
    END;

    RAISE NOTICE 'Control requests: % live, % audit rows (% elapsed)',
        (SELECT count(*) FROM control_requests),
        (SELECT count(*) FROM control_requests_history),
        clock_timestamp() - _t0;

    -- =======================================================================
    -- 2) Comms-lost alarms: one per outage, from the SAME sim_outages that
    --    gapped the telemetry. Detection lags onset by 5 minutes (the
    --    missing-data debounce); ~70% get acknowledged; outages still
    --    running at "now" stay active on the board.
    -- =======================================================================
    INSERT INTO alarm_history (alarm_definition_id, site_id, alarm_name, source,
        device_id, point_id, severity, is_active, message,
        raised_at, cleared_at, acknowledged_at, created_at, updated_at)
    SELECT ad.alarm_definition_id, o.site_id, ad.name, d.name,
           o.device_id, p.point_id, ad.severity,
           (o.end_at > now()),
           format('No telemetry from %s for 5 minutes', d.name),
           o.start_at + INTERVAL '5 minutes',
           CASE WHEN o.end_at <= now() THEN o.end_at END,
           CASE WHEN random() < 0.7
                THEN o.start_at + make_interval(mins => (10 + random() * 110)::int) END,
           o.start_at + INTERVAL '5 minutes',
           GREATEST(o.start_at + INTERVAL '5 minutes', LEAST(o.end_at, now()))
    FROM sim_outages o
    JOIN devices d ON d.device_id = o.device_id
    JOIN alarm_definitions ad ON ad.site_id = o.site_id
                             AND ad.name = 'Inverter Communications Lost'
    LEFT JOIN LATERAL (
        SELECT p.point_id FROM device_points dp
        JOIN points p ON p.point_id = dp.point_id AND p.point_kind = 1
        WHERE dp.device_id = o.device_id LIMIT 1
    ) p ON true;

    -- =======================================================================
    -- 3) Over-temperature alarms: scan the generated readings for the first
    --    moment each device-day actually crossed 78 degC. The alarm board
    --    and the temperature chart will agree exactly.
    -- =======================================================================
    INSERT INTO alarm_history (alarm_definition_id, site_id, alarm_name, source,
        device_id, point_id, severity, is_active, message,
        raised_at, cleared_at, acknowledged_at, created_at, updated_at)
    SELECT ad.alarm_definition_id, p.site_id, ad.name, d.name,
           d.device_id, p.point_id, ad.severity, false,
           format('%s heatsink exceeded 78 degC (peak %s)', d.name, hot.peak),
           hot.first_cross, hot.first_cross + INTERVAL '2 hours',
           hot.first_cross + INTERVAL '20 minutes',
           hot.first_cross, hot.first_cross + INTERVAL '2 hours'
    FROM (
        SELECT r.point_id,
               time_bucket(INTERVAL '1 day', r.event_time) AS day,
               min(r.event_time) AS first_cross,
               round(max(r.value_double)::numeric, 1) AS peak
        FROM point_readings r
        JOIN points pk ON pk.point_id = r.point_id AND pk.point_kind = 2
        WHERE r.value_double > 78
        GROUP BY r.point_id, time_bucket(INTERVAL '1 day', r.event_time)
    ) hot
    JOIN points p  ON p.point_id = hot.point_id
    JOIN device_points dp ON dp.point_id = p.point_id
    JOIN devices d ON d.device_id = dp.device_id
    JOIN alarm_definitions ad ON ad.site_id = p.site_id
                             AND ad.name = 'Inverter Over Temperature';

    -- =======================================================================
    -- 4) Storm advisories on heavy-cloud days (informational severity)
    -- =======================================================================
    INSERT INTO alarm_history (alarm_definition_id, site_id, alarm_name,
        severity, is_active, is_system_alarm, message,
        raised_at, cleared_at, created_at, updated_at)
    SELECT ad.alarm_definition_id, w.site_id, ad.name,
           ad.severity, false, true,
           format('Output degraded by weather: cloud factor %s', round(w.cloudiness::numeric, 2)),
           (w.local_day + TIME '11:00') AT TIME ZONE s.timezone,
           (w.local_day + TIME '16:00') AT TIME ZONE s.timezone,
           (w.local_day + TIME '11:00') AT TIME ZONE s.timezone,
           (w.local_day + TIME '16:00') AT TIME ZONE s.timezone
    FROM sim_weather_days w
    JOIN sites s ON s.site_id = w.site_id
    JOIN alarm_definitions ad ON ad.site_id = w.site_id
                             AND ad.name = 'Storm Output Degradation'
    WHERE w.cloudiness < 0.40
      AND (w.local_day + TIME '16:00') AT TIME ZONE s.timezone <= now();

    -- =======================================================================
    -- 5) Alarm events: the raise (and clear, where cleared) evaluations
    --    behind every alarm occurrence -- feeds the alarm_events hypertable.
    -- =======================================================================
    INSERT INTO alarm_events (site_id, alarm_event_id, alarm_history_id,
        alarm_definition_id, event_time, message, event_condition, point_id, created_at)
    SELECT ah.site_id, gen_random_uuid(), ah.alarm_history_id,
           ah.alarm_definition_id, ah.raised_at,
           coalesce(ah.message, ah.alarm_name), 'raise', ah.point_id, ah.raised_at
    FROM alarm_history ah
    UNION ALL
    SELECT ah.site_id, gen_random_uuid(), ah.alarm_history_id,
           ah.alarm_definition_id, ah.cleared_at,
           'Condition cleared', 'clear', ah.point_id, ah.cleared_at
    FROM alarm_history ah
    WHERE ah.cleared_at IS NOT NULL;

    RETURN format('Activity generated: %s control submissions -> %s live / %s audit rows; %s alarms (%s active) + %s alarm events. (%s elapsed)',
        _n_requests,
        (SELECT count(*) FROM control_requests),
        (SELECT count(*) FROM control_requests_history),
        (SELECT count(*) FROM alarm_history),
        (SELECT count(*) FROM alarm_history WHERE is_active),
        (SELECT count(*) FROM alarm_events),
        clock_timestamp() - _t0);
END;
$func$;

SELECT scada.generate_activity();

\echo ''
\echo 'Control room is live. Try:'
\echo '  SELECT alarm_name, severity, is_active, raised_at FROM scada.alarm_history ORDER BY raised_at DESC LIMIT 15;'
