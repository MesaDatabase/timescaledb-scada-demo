-- ============================================================================
-- Script:        01_seed_reference.sql
-- Folder:        03_data_generation
-- Purpose:       Build the plant: sites (with real coordinates and
--                timezones), the device fleet, the point catalog, device
--                properties used by the generator (ratings), a value map,
--                and alarm definitions. Config-driven and idempotent --
--                wipes and rebuilds everything via reset_demo_data().
-- Safe in prod:  N/A -- demo only.
-- Requires:      00_demo_config.sql
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- Notes:         point_kind codes (the generator joins on these):
--                  1 = inverter AC power (kW)     5 = battery state of charge (%)
--                  2 = inverter heatsink temp (C) 6 = irradiance / GHI (W/m2)
--                  3 = inverter status (enum)     7 = ambient temperature (C)
--                  4 = battery power (kW, +discharge/-charge)
--                  8 = wind speed (m/s)           9 = site meter power (kW)
-- ============================================================================

SET search_path = scada, public;

CREATE OR REPLACE FUNCTION scada.seed_reference_data()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _sites_count   INT := LEAST(GREATEST(scada.cfg_int('sites_count'), 1), 3);
    _inverters     INT := scada.cfg_int('inverters_per_site');
    _rated_kw      FLOAT8 := scada.cfg_float('inverter_rated_kw');
    _batt_kw       FLOAT8 := scada.cfg_float('battery_power_kw');
    _batt_kwh      FLOAT8 := scada.cfg_float('battery_capacity_kwh');

    _site          RECORD;
    _site_id       UUID;
    _plc_id        UUID;
    _dev_id        UUID;
    _point_id      UUID;
    _status_map_id UUID;
    _i             INT;
    _t_inverter    INT;
    _t_battery     INT;
    _t_meter       INT;
    _t_weather     INT;
    _t_controller  INT;
BEGIN
    PERFORM scada.reset_demo_data();

    -- Equipment classes (reference table, not enum: adding one is an INSERT)
    INSERT INTO device_types (name) VALUES
        ('plant_controller'), ('inverter'), ('battery'), ('meter'), ('weather_station')
    ON CONFLICT (name) DO NOTHING;
    SELECT device_type_id INTO _t_controller FROM device_types WHERE name = 'plant_controller';
    SELECT device_type_id INTO _t_inverter   FROM device_types WHERE name = 'inverter';
    SELECT device_type_id INTO _t_battery    FROM device_types WHERE name = 'battery';
    SELECT device_type_id INTO _t_meter      FROM device_types WHERE name = 'meter';
    SELECT device_type_id INTO _t_weather    FROM device_types WHERE name = 'weather_station';

    -- How integer telemetry translates to operator-friendly labels
    INSERT INTO value_maps (name, map_type, display_values, int_values)
    VALUES ('Inverter Status', 'translation',
            ARRAY['Stopped', 'Running', 'Faulted', 'Curtailed'],
            ARRAY[0, 1, 2, 3])
    RETURNING value_map_id INTO _status_map_id;

    -- -----------------------------------------------------------------------
    -- Sites: real places, real timezones. Two in different timezones by
    -- default so timezone-aware rollups have something to prove.
    -- -----------------------------------------------------------------------
    FOR _site IN
        SELECT * FROM (VALUES
            (1, 'Pecos Valley Solar + Storage', 'America/Chicago',    31.4199, -103.4938, 'TX high desert: big sun, big heat'),
            (2, 'Sonoran Flats Energy Center',  'America/Phoenix',    33.0431, -112.0476, 'AZ: no DST, great tz test case'),
            (3, 'High Plains Hybrid',           'America/Denver',     35.1245, -101.8412, 'Panhandle: windier, cooler')
        ) AS s(ord, name, tz, lat, lon, note)
        WHERE s.ord <= _sites_count
        ORDER BY s.ord
    LOOP
        INSERT INTO sites (name, timezone, latitude, longitude, capacity_kw, commissioned_on)
        VALUES (_site.name, _site.tz, _site.lat, _site.lon,
                _inverters * _rated_kw, DATE '2023-06-01')
        RETURNING site_id INTO _site_id;

        INSERT INTO settings (site_id, setting_name, value) VALUES
            (_site_id, 'note', _site.note),
            (_site_id, 'data_provider', 'demo-generator');

        -- Plant controller is the hierarchy root
        INSERT INTO devices (site_id, name, device_type_id, is_controllable)
        VALUES (_site_id, 'PLC01', _t_controller, true)
        RETURNING device_id INTO _plc_id;

        -- ------------------------- Inverters --------------------------------
        FOR _i IN 1.._inverters LOOP
            INSERT INTO devices (site_id, name, device_type_id, device_model, is_controllable)
            VALUES (_site_id, format('INV%s', lpad(_i::text, 2, '0')), _t_inverter,
                    'GenericPV-250', true)
            RETURNING device_id INTO _dev_id;

            INSERT INTO device_hierarchy VALUES (_plc_id, _dev_id, format('Inverter %s', _i));
            INSERT INTO device_properties (device_id, name, static_value, uom)
            VALUES (_dev_id, 'rated_kw', _rated_kw, 'kW');

            -- AC power: the star of the show. rollup_method power_to_energy
            -- means get_point_history(..., 'energy') integrates it into kWh.
            INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                                eng_low, eng_high, uom, display_uom,
                                rollup_method, rollup_uom, display_rollup_uom, display_precision)
            VALUES (_site_id, format('INV%s.AC_POWER', lpad(_i::text, 2, '0')),
                    format('Inverter %s AC Power', _i), 1, 'float64',
                    0, _rated_kw * 1.1, 'kW', 'kW',
                    'power_to_energy', 'kWh', 'kWh', 1)
            RETURNING point_id INTO _point_id;
            INSERT INTO device_points VALUES (_dev_id, _point_id);

            INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                                eng_low, eng_high, uom, rollup_method, display_precision)
            VALUES (_site_id, format('INV%s.HEATSINK_TEMP', lpad(_i::text, 2, '0')),
                    format('Inverter %s Heatsink Temp', _i), 2, 'float64',
                    -20, 100, 'degC', 'avg', 1)
            RETURNING point_id INTO _point_id;
            INSERT INTO device_points VALUES (_dev_id, _point_id);

            -- Digital status point: int values + value map = label translation demo
            INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                                eng_low, eng_high, value_map_id, is_analog)
            VALUES (_site_id, format('INV%s.STATUS', lpad(_i::text, 2, '0')),
                    format('Inverter %s Status', _i), 3, 'int64',
                    0, 3, _status_map_id, false)
            RETURNING point_id INTO _point_id;
            INSERT INTO device_points VALUES (_dev_id, _point_id);
        END LOOP;

        -- ------------------------- Battery ----------------------------------
        INSERT INTO devices (site_id, name, device_type_id, device_model, is_controllable)
        VALUES (_site_id, 'BESS01', _t_battery, 'GenericESS-2MWh', true)
        RETURNING device_id INTO _dev_id;
        INSERT INTO device_hierarchy VALUES (_plc_id, _dev_id, 'Battery 1');
        INSERT INTO device_properties (device_id, name, static_value, uom) VALUES
            (_dev_id, 'rated_kw',     _batt_kw,  'kW'),
            (_dev_id, 'capacity_kwh', _batt_kwh, 'kWh');

        INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                            eng_low, eng_high, uom, rollup_method, rollup_uom, display_precision)
        VALUES (_site_id, 'BESS01.POWER', 'Battery Power (+discharge / -charge)', 4, 'float64',
                -_batt_kw * 1.1, _batt_kw * 1.1, 'kW', 'power_to_energy', 'kWh', 1)
        RETURNING point_id INTO _point_id;
        INSERT INTO device_points VALUES (_dev_id, _point_id);

        INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                            eng_low, eng_high, uom, rollup_method, display_precision)
        VALUES (_site_id, 'BESS01.SOC', 'Battery State of Charge', 5, 'float64',
                0, 100, '%', 'avg', 1)
        RETURNING point_id INTO _point_id;
        INSERT INTO device_points VALUES (_dev_id, _point_id);

        -- ------------------------- Weather station --------------------------
        INSERT INTO devices (site_id, name, device_type_id)
        VALUES (_site_id, 'WS01', _t_weather)
        RETURNING device_id INTO _dev_id;
        INSERT INTO device_hierarchy VALUES (_plc_id, _dev_id, 'Weather Station');

        INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                            eng_low, eng_high, uom, rollup_method, display_precision)
        VALUES
            (_site_id, 'WS01.GHI', 'Global Horizontal Irradiance', 6, 'float64',
             0, 1400, 'W/m2', 'avg', 0),
            (_site_id, 'WS01.AMBIENT_TEMP', 'Ambient Temperature', 7, 'float64',
             -30, 55, 'degC', 'avg', 1),
            (_site_id, 'WS01.WIND_SPEED', 'Wind Speed', 8, 'float64',
             0, 40, 'm/s', 'avg', 1);
        INSERT INTO device_points
            SELECT _dev_id, p.point_id FROM points p
            WHERE p.site_id = _site_id AND p.point_kind IN (6, 7, 8);

        -- ------------------------- Site meter --------------------------------
        INSERT INTO devices (site_id, name, device_type_id)
        VALUES (_site_id, 'MTR01', _t_meter)
        RETURNING device_id INTO _dev_id;
        INSERT INTO device_hierarchy VALUES (_plc_id, _dev_id, 'Revenue Meter');

        INSERT INTO points (site_id, name, display_name, point_kind, value_type,
                            eng_low, eng_high, uom, rollup_method, rollup_uom, display_precision)
        VALUES (_site_id, 'MTR01.NET_POWER', 'Site Net Power', 9, 'float64',
                -_batt_kw * 1.2, _inverters * _rated_kw * 1.2, 'kW',
                'power_to_energy', 'kWh', 1)
        RETURNING point_id INTO _point_id;
        INSERT INTO device_points VALUES (_dev_id, _point_id);

        -- ------------------------- Alarm definitions -------------------------
        -- Wired to the same point_kind codes the generator uses, so injected
        -- outages and hot afternoons raise exactly these alarms.
        INSERT INTO alarm_definitions
            (site_id, name, description, resolution, severity, analysis_type,
             alarm_type, raise_occurrence_limit, raise_timeframe_s,
             clear_occurrence_limit, clear_timeframe_s, require_acknowledgement)
        VALUES
            (_site_id, 'Inverter Communications Lost',
             'No telemetry received from inverter.',
             'Check gateway, network path, and inverter comms card.',
             'high', 'duration', 'missing_data', 1, 300, 1, 60, true),
            (_site_id, 'Inverter Over Temperature',
             'Heatsink temperature above 75 degC.',
             'Verify fans and airflow; derate if persistent.',
             'medium', 'duration', 'point_analysis', 3, 900, 1, 600, false),
            (_site_id, 'Battery SOC Low',
             'State of charge below 15%.',
             'Review dispatch schedule headroom.',
             'medium', 'duration', 'point_analysis', 1, 300, 1, 300, false),
            (_site_id, 'Storm Output Degradation',
             'Site output far below clear-sky expectation.',
             'Informational: weather-driven.',
             'information', 'rate', 'performance_analysis', 1, 3600, 1, 3600, false);

        -- One worked example of the expression model (raise + clear pair)
        INSERT INTO alarm_definition_expressions
            (alarm_definition_id, point_id, point_value, comparison_operator,
             evaluation_order, role)
        SELECT ad.alarm_definition_id, p.point_id, v.val, v.op, 1, v.role::expression_role
        FROM alarm_definitions ad
        JOIN points p ON p.site_id = ad.site_id
                     AND p.point_kind = 2
                     AND p.name = 'INV01.HEATSINK_TEMP'
        CROSS JOIN (VALUES (75::numeric, '>', 'raise'), (65::numeric, '<=', 'clear')) AS v(val, op, role)
        WHERE ad.site_id = _site_id AND ad.name = 'Inverter Over Temperature';
    END LOOP;

    RETURN format('Seeded %s site(s): %s devices, %s points, %s alarm definitions.',
        _sites_count,
        (SELECT count(*) FROM devices),
        (SELECT count(*) FROM points),
        (SELECT count(*) FROM alarm_definitions));
END;
$func$;

SELECT scada.seed_reference_data();

\echo 'Reference data seeded. Explore the plant:'
\echo '  SELECT * FROM scada.get_device_point_tree((SELECT site_id FROM scada.sites LIMIT 1));'
