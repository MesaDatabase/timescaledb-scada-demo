-- ============================================================================
-- Script:        02_generate_readings.sql
-- Folder:        03_data_generation
-- Purpose:       Generate the telemetry. Fully set-based (generate_series +
--                joins, no row-by-row loops): the default ~0.8M rows insert
--                in seconds, and scaling history_days to 365 just works.
--
--                The physics, in one paragraph: the sun rises, arcs, and
--                sets -- irradiance follows a sine "bell" whose width tracks
--                the season. Each day rolls dice for cloud cover. Inverters
--                convert irradiance to AC power, flat-topping ("clipping")
--                at their rating on clear middays because panels are
--                oversized vs the inverter (dc_ac_ratio). Heatsinks run
--                hotter as load and ambient rise. The battery charges from
--                midday surplus and discharges into the evening peak.
--                Equipment outages (sim_outages) cut a device's data off
--                mid-stream -- a status=2 'Faulted' reading, one 'offline'
--                zero, then silence until recovery. Those gaps are exactly
--                what 06_functions_analytics gapfill exists to handle.
-- Safe in prod:  N/A -- demo only. Truncates point_readings and rebuilds.
-- Requires:      00_demo_config.sql, 01_seed_reference.sql
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- ============================================================================

SET search_path = scada, public;

CREATE OR REPLACE FUNCTION scada.generate_readings()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _interval   INTERVAL := scada.cfg_interval('reading_interval');
    _days       INT      := scada.cfg_int('history_days');
    _storm_p    FLOAT8   := scada.cfg_float('storm_day_chance');
    _outage_pm  FLOAT8   := scada.cfg_float('outage_rate_per_month');
    _dc_ratio   FLOAT8   := scada.cfg_float('dc_ac_ratio');

    -- Snap the window to clean bucket boundaries
    _end        TIMESTAMPTZ := date_bin(_interval, now(), TIMESTAMPTZ '2000-01-01');
    _start      TIMESTAMPTZ;
    _t0         TIMESTAMPTZ := clock_timestamp();
    _rows       BIGINT := 0;
    _n          BIGINT;
BEGIN
    _start := _end - make_interval(days => _days);
    PERFORM setseed(scada.cfg_float('random_seed'));

    TRUNCATE point_readings, sim_weather_days, sim_outages;

    -- =======================================================================
    -- 1) Roll the weather: one cloudiness factor per site per local day.
    --    1.0 = postcard-clear; storm days crush output to 15-40%.
    -- =======================================================================
    INSERT INTO sim_weather_days (site_id, local_day, cloudiness)
    SELECT s.site_id, d::date,
           CASE WHEN random() < _storm_p
                THEN 0.15 + random() * 0.25            -- storm
                ELSE 0.70 + random() * 0.30 END        -- clear-ish to clear
    FROM sites s
    CROSS JOIN LATERAL generate_series(
        ((_start AT TIME ZONE s.timezone)::date - 1),
        ((_end   AT TIME ZONE s.timezone)::date + 1),
        INTERVAL '1 day') AS d;

    -- =======================================================================
    -- 2) Roll the outages: each inverter has a small chance per day.
    --    Durations 30 min - 6 h. The most recent one is stretched past "now"
    --    so the demo always has a live, unresolved alarm on the board.
    -- =======================================================================
    INSERT INTO sim_outages (device_id, site_id, start_at, end_at)
    SELECT d.device_id, d.site_id, t.s, t.s + t.dur
    FROM devices d
    JOIN device_types dt ON dt.device_type_id = d.device_type_id AND dt.name = 'inverter'
    CROSS JOIN LATERAL generate_series(_start, _end - INTERVAL '1 day', INTERVAL '1 day') AS day
    CROSS JOIN LATERAL (
        SELECT day + make_interval(mins => (60 + random() * 1200)::int) AS s,
               make_interval(mins => (30 + random() * 330)::int)        AS dur
    ) t
    WHERE random() < _outage_pm / 30.0;

    IF NOT EXISTS (SELECT 1 FROM sim_outages) THEN
        -- Guarantee at least one for tiny configs
        INSERT INTO sim_outages (device_id, site_id, start_at, end_at)
        SELECT d.device_id, d.site_id, _end - INTERVAL '3 hours', _end + INTERVAL '12 hours'
        FROM devices d
        JOIN device_types dt ON dt.device_type_id = d.device_type_id AND dt.name = 'inverter'
        LIMIT 1;
    ELSE
        UPDATE sim_outages SET end_at = _end + INTERVAL '12 hours'
        WHERE outage_id = (SELECT outage_id FROM sim_outages ORDER BY start_at DESC LIMIT 1);
    END IF;

    -- =======================================================================
    -- 3) Shared environment grid: one row per site per timestamp carrying
    --    the solar position, irradiance, and ambient conditions that every
    --    signal derives from. Computed ONCE, read by every insert below.
    --
    --    Solar model (deliberately simple, surprisingly convincing):
    --      day_length = 12h +/- ~2.2h with the season (longest near Jun 21)
    --      solar_pos  = sin(pi * hours-since-sunrise / day_length), so it
    --                   rises from 0, peaks at solar noon, returns to 0.
    --      clear-sky GHI ~ 1080 * solar_pos^1.15 W/m2; cloudy days are both
    --      dimmer AND choppier (variability scales with cloud cover).
    -- =======================================================================
    DROP TABLE IF EXISTS sim_env;
    CREATE TEMP TABLE sim_env ON COMMIT DROP AS
    SELECT
        s.site_id,
        s.timezone,
        g.ts,
        e.local_h,
        w.cloudiness,
        GREATEST(0.0, e.solar_pos)                                   AS solar_pos,
        -- irradiance with cloud dimming + cloud-driven choppiness
        GREATEST(0.0,
            1080 * power(GREATEST(e.solar_pos, 0.0), 1.15)
                 * w.cloudiness
                 * (1.0 - (1.0 - w.cloudiness) * 0.6 * random())
                 * (0.97 + 0.06 * random()))                         AS ghi,
        -- ambient: seasonal swing + daily swing (warmest mid-afternoon)
        (17 + 12 * sin(2 * pi() * (e.doy - 105) / 365.0)
            +  8 * sin(2 * pi() * (e.local_h - 9) / 24.0)
            + random() * 1.5)                                        AS ambient_c,
        GREATEST(0.0, 4 + 2.5 * sin(2 * pi() * (e.local_h - 15) / 24.0)
                        + (random() - 0.5) * 3.0)                    AS wind_ms
    FROM sites s
    CROSS JOIN LATERAL generate_series(_start + _interval, _end, _interval) AS g(ts)
    CROSS JOIN LATERAL (
        SELECT
            EXTRACT(EPOCH FROM (g.ts AT TIME ZONE s.timezone)::time) / 3600.0 AS local_h,
            EXTRACT(DOY   FROM  g.ts AT TIME ZONE s.timezone)                 AS doy
    ) lt
    CROSS JOIN LATERAL (
        SELECT lt.local_h,
               lt.doy,
               12 + 2.2 * cos(2 * pi() * (lt.doy - 172) / 365.0) AS day_len
    ) dl
    CROSS JOIN LATERAL (
        SELECT dl.local_h, dl.doy,
               sin(pi() * (dl.local_h - (12 - dl.day_len / 2)) / dl.day_len) AS solar_pos
    ) e
    JOIN sim_weather_days w
      ON w.site_id = s.site_id
     AND w.local_day = (g.ts AT TIME ZONE s.timezone)::date;

    CREATE INDEX ON sim_env (site_id, ts);
    RAISE NOTICE 'Environment grid built: % rows (% elapsed)',
        (SELECT count(*) FROM sim_env), clock_timestamp() - _t0;

    -- =======================================================================
    -- 4) Weather station readings (GHI / ambient / wind). A ~0.08% sliver of
    --    GHI samples are injected as stuck-high 'over_range' glitches --
    --    fodder for data-quality queries.
    -- =======================================================================
    INSERT INTO point_readings (event_time, point_id, value_double, data_quality)
    SELECT e.ts, p.point_id,
           CASE p.point_kind
               WHEN 6 THEN CASE WHEN gl.glitch THEN 1425.0 ELSE round(e.ghi::numeric, 1)::float8 END
               WHEN 7 THEN round(e.ambient_c::numeric, 2)::float8
               WHEN 8 THEN round(e.wind_ms::numeric, 2)::float8
           END,
           CASE WHEN p.point_kind = 6 AND gl.glitch
                THEN 'over_range'::data_quality ELSE 'online'::data_quality END
    FROM sim_env e
    JOIN points p ON p.site_id = e.site_id AND p.point_kind IN (6, 7, 8)
    CROSS JOIN LATERAL (SELECT (p.point_kind = 6 AND random() < 0.0008) AS glitch) gl;
    GET DIAGNOSTICS _n = ROW_COUNT;  _rows := _rows + _n;
    RAISE NOTICE 'Weather readings: % rows', _n;

    -- =======================================================================
    -- 5) Inverter power, heatsink temp, status. Power clips at the AC rating
    --    on clear middays (panels oversized by dc_ac_ratio -- look for the
    --    flat-topped bell curves). Rows inside an outage window are simply
    --    NOT inserted: real gateways go silent, and real data has gaps.
    -- =======================================================================
    INSERT INTO point_readings (event_time, point_id, value_double, value_bigint, data_quality)
    SELECT e.ts,
           p.point_id,
           CASE p.point_kind
               WHEN 1 THEN round(inv.kw::numeric, 1)::float8
               WHEN 2 THEN round((e.ambient_c + 27 * inv.kw / rp.static_value
                                  + random() * 2)::numeric, 1)::float8
               ELSE NULL
           END,
           CASE p.point_kind
               WHEN 3 THEN CASE WHEN e.solar_pos <= 0 THEN 0 ELSE 1 END
               ELSE NULL
           END,
           'online'
    FROM sim_env e
    JOIN devices d        ON d.site_id = e.site_id
    JOIN device_types dt  ON dt.device_type_id = d.device_type_id AND dt.name = 'inverter'
    JOIN device_properties rp ON rp.device_id = d.device_id AND rp.name = 'rated_kw'
    JOIN device_points dp ON dp.device_id = d.device_id
    JOIN points p         ON p.point_id = dp.point_id AND p.point_kind IN (1, 2, 3)
    CROSS JOIN LATERAL (
        SELECT LEAST(rp.static_value,                          -- the clip
                     _dc_ratio * rp.static_value * (e.ghi / 1000.0) * 0.985)
               * (0.98 + 0.04 * random()) AS kw
    ) inv
    WHERE NOT EXISTS (                                          -- outage = silence
        SELECT 1 FROM sim_outages o
        WHERE o.device_id = d.device_id
          AND e.ts >= o.start_at AND e.ts < o.end_at
    );
    GET DIAGNOSTICS _n = ROW_COUNT;  _rows := _rows + _n;
    RAISE NOTICE 'Inverter readings: % rows', _n;

    -- Outage boundary markers: at the bucket where each outage begins, the
    -- inverter manages one last gasp -- status flips to 2 'Faulted' and
    -- power reads 0 with quality 'offline'. Then nothing until recovery.
    INSERT INTO point_readings (event_time, point_id, value_double, value_bigint, data_quality)
    SELECT DISTINCT ON (b.ts, p.point_id)
           b.ts,
           p.point_id,
           CASE p.point_kind WHEN 1 THEN 0.0 END,
           CASE p.point_kind WHEN 3 THEN 2 END,
           'offline'
    FROM sim_outages o
    CROSS JOIN LATERAL (
        SELECT date_bin(_interval, o.start_at, TIMESTAMPTZ '2000-01-01') AS ts
    ) b
    JOIN device_points dp ON dp.device_id = o.device_id
    JOIN points p         ON p.point_id = dp.point_id AND p.point_kind IN (1, 3)
    WHERE b.ts > _start
    ON CONFLICT (event_time, point_id) DO UPDATE
        SET value_double = EXCLUDED.value_double,
            value_bigint = EXCLUDED.value_bigint,
            data_quality = EXCLUDED.data_quality;
    GET DIAGNOSTICS _n = ROW_COUNT;  _rows := _rows + _n;
    RAISE NOTICE 'Outage boundary markers: % rows (across % outages)',
        _n, (SELECT count(*) FROM sim_outages);

    -- =======================================================================
    -- 6) Battery: charge from midday solar surplus (negative kW), discharge
    --    into the evening peak (positive kW). SOC follows the schedule in
    --    closed form -- 35% overnight, ramping to ~98% by 14:00, holding,
    --    then draining back through the evening. (Production systems
    --    integrate measured power instead; rollup_power_to_energy shows that
    --    integration pattern on the query side.)
    -- =======================================================================
    INSERT INTO point_readings (event_time, point_id, value_double, data_quality)
    SELECT e.ts, p.point_id,
           CASE p.point_kind
               WHEN 4 THEN round((bp.sched_kw * (0.97 + 0.06 * random()))::numeric, 1)::float8
               WHEN 5 THEN round((soc.pct + random())::numeric, 1)::float8
           END,
           'online'
    FROM sim_env e
    JOIN devices d        ON d.site_id = e.site_id
    JOIN device_types dt  ON dt.device_type_id = d.device_type_id AND dt.name = 'battery'
    JOIN device_properties rp ON rp.device_id = d.device_id AND rp.name = 'rated_kw'
    JOIN device_points dp ON dp.device_id = d.device_id
    JOIN points p         ON p.point_id = dp.point_id AND p.point_kind IN (4, 5)
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN e.local_h >= 10 AND e.local_h < 14 THEN -0.75 * rp.static_value  -- charging
            WHEN e.local_h >= 18 AND e.local_h < 21 THEN  0.90 * rp.static_value  -- discharging
            ELSE 0.0
        END AS sched_kw
    ) bp
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN e.local_h < 10 THEN 35.0
            WHEN e.local_h < 14 THEN 35.0 + 63.0 * (e.local_h - 10) / 4.0   -- charging ramp
            WHEN e.local_h < 18 THEN 98.0                                   -- full, waiting for peak
            WHEN e.local_h < 21 THEN 98.0 - 63.0 * (e.local_h - 18) / 3.0   -- discharge ramp
            ELSE 35.0
        END AS pct
    ) soc;
    GET DIAGNOSTICS _n = ROW_COUNT;  _rows := _rows + _n;
    RAISE NOTICE 'Battery readings: % rows', _n;

    -- =======================================================================
    -- 7) Site meter = what the grid actually sees: sum of everything behind
    --    it, minus ~1.5% collection losses. Computed FROM the generated
    --    readings, so inverter outages show up in the meter automatically.
    -- =======================================================================
    INSERT INTO point_readings (event_time, point_id, value_double, data_quality)
    SELECT r.event_time,
           mp.point_id,
           round((sum(r.value_double) * 0.985 + (random() * 4 - 2))::numeric, 1)::float8,
           'online'
    FROM point_readings r
    JOIN points p  ON p.point_id = r.point_id AND p.point_kind IN (1, 4)
    JOIN points mp ON mp.site_id = p.site_id AND mp.point_kind = 9
    GROUP BY r.event_time, mp.point_id;
    GET DIAGNOSTICS _n = ROW_COUNT;  _rows := _rows + _n;
    RAISE NOTICE 'Meter readings: % rows', _n;

    RETURN format('Generated %s readings across %s points, %s -> %s (%s elapsed).',
                  to_char(_rows, 'FM999,999,999'),
                  (SELECT count(*) FROM points),
                  _start, _end, clock_timestamp() - _t0);
END;
$func$;

SELECT scada.generate_readings();

\echo ''
\echo 'Telemetry generated. Peek at the story:'
\echo '  SELECT * FROM scada.sim_weather_days ORDER BY local_day DESC LIMIT 10;'
\echo '  SELECT * FROM scada.sim_outages ORDER BY start_at DESC;'
