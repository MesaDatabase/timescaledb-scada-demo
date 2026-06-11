-- ============================================================================
-- Script:        04_showcase_queries.sql
-- Folder:        03_data_generation
-- Purpose:       A guided, read-only tour of the generated world -- run it
--                top to bottom (psql -f) and watch the story: solar curves
--                that clip at the inverter rating, storm days with crushed
--                energy, data gaps where equipment faulted, an alarm board
--                that matches the charts, and a control queue with a full
--                audit trail.
-- Safe in prod:  YES (read-only) -- though it only makes sense on demo data.
-- Requires:      00..03 of this folder executed.
-- Compatibility: PostgreSQL 14+ / TimescaleDB 2.13+
-- ============================================================================

SET search_path = scada, public;

\echo '============================================================'
\echo ' 1) Yesterday''s solar curve: 15-minute gapfilled power for'
\echo '    one inverter. Look for the bell shape, the flat "clipped"'
\echo '    top on clear days, and is_generated = t where an outage'
\echo '    gapped the data and locf carried the last value forward.'
\echo '============================================================'
SELECT bucket_time, round(value::numeric, 1) AS kw, data_quality, is_generated
FROM scada.readings_gapfilled(
        (SELECT ARRAY[p.point_id] FROM scada.points p
         WHERE p.point_kind = 1 ORDER BY p.name LIMIT 1),
        date_trunc('day', now()) - INTERVAL '1 day',
        date_trunc('day', now()),
        INTERVAL '15 minutes')
ORDER BY bucket_time;

\echo '============================================================'
\echo ' 2) Daily site energy, last 14 days: power integrated to kWh'
\echo '    by rollup_power_to_energy via get_point_history(...,''energy''),'
\echo '    bucketed in each site''s LOCAL day.'
\echo '============================================================'
SELECT s.name AS site, h.bucket_start::date AS local_day,
       round(h.value::numeric, 0) AS kwh
FROM scada.sites s
CROSS JOIN LATERAL scada.get_point_history(
        s.site_id,
        (SELECT ARRAY[p.point_id] FROM scada.points p
         WHERE p.site_id = s.site_id AND p.point_kind = 9),
        'day', now() - INTERVAL '14 days', now(), 'energy') h
ORDER BY s.name, local_day;

\echo '============================================================'
\echo ' 3) Weather explains output: join daily energy to the rolled'
\echo '    cloudiness. Storm days (< 0.40) should be the energy dips.'
\echo '============================================================'
SELECT s.name AS site, w.local_day, w.cloudiness,
       CASE WHEN w.cloudiness < 0.40 THEN '** storm **' ELSE '' END AS note,
       round(sum(h.value)::numeric, 0) AS kwh
FROM scada.sites s
JOIN scada.sim_weather_days w ON w.site_id = s.site_id
CROSS JOIN LATERAL scada.get_point_history(
        s.site_id,
        (SELECT ARRAY[p.point_id] FROM scada.points p
         WHERE p.site_id = s.site_id AND p.point_kind = 9),
        'day', w.local_day::timestamptz, (w.local_day + 1)::timestamptz, 'energy') h
WHERE w.local_day >= (now() - INTERVAL '14 days')::date
  AND w.local_day <  now()::date
GROUP BY s.name, w.local_day, w.cloudiness
ORDER BY s.name, w.local_day;

\echo '============================================================'
\echo ' 4) The alarm board: active alarms first (served by the'
\echo '    partial index ix_alarm_history_active), then recent'
\echo '    history. The active comms-lost alarm is the outage that'
\echo '    is still running "now" -- check sim_outages.'
\echo '============================================================'
SELECT ah.alarm_name, ah.source AS device, ah.severity, ah.is_active,
       ah.raised_at, ah.cleared_at,
       (ah.acknowledged_at IS NOT NULL) AS acked,
       left(ah.message, 60) AS message
FROM scada.alarm_history ah
ORDER BY ah.is_active DESC, ah.raised_at DESC
LIMIT 25;

\echo '============================================================'
\echo ' 5) Open control requests -- written with the exact CASE the'
\echo '    expression index ix_control_requests_open was built for.'
\echo '    Prove it: prefix with EXPLAIN and look for the index scan.'
\echo '============================================================'
SELECT cr.created_at, cr.status, cr.source, d.name AS device,
       cr.value[1] AS setpoint_kw, left(cr.description, 40) AS description
FROM scada.control_requests cr
LEFT JOIN scada.devices d ON d.device_id = cr.device_id
WHERE cr.site_id = (SELECT site_id FROM scada.sites ORDER BY name LIMIT 1)
  AND (CASE WHEN cr.status IN ('queued', 'accepted', 'scheduled', 'active')
            THEN 1 ELSE 9 END) = 1
ORDER BY cr.created_at DESC
LIMIT 20;

\echo '============================================================'
\echo ' 6) Full audit trail of one dispatch request: every status'
\echo '    transition submit_control_request appended to history.'
\echo '    The live queue holds only the final state.'
\echo '============================================================'
WITH pick AS (
    SELECT control_request_id FROM scada.control_requests_history
    GROUP BY control_request_id HAVING count(*) >= 4
    ORDER BY max(created_at) DESC LIMIT 1
)
SELECT h.updated_at, h.status, h.value[1] AS setpoint_kw, h.source
FROM scada.control_requests_history h
JOIN pick USING (control_request_id)
ORDER BY h.updated_at;

\echo '============================================================'
\echo ' 7) A battery day: state of charge riding its dispatch'
\echo '    schedule -- charging on midday solar, holding, then'
\echo '    discharging into the evening peak.'
\echo '============================================================'
SELECT rr.bucket_start, p.display_name,
       round(rr.avg_value::numeric, 1) AS avg_value
FROM scada.readings_rollup(
        (SELECT array_agg(p2.point_id) FROM scada.points p2
         WHERE p2.point_kind IN (4, 5)
           AND p2.site_id = (SELECT site_id FROM scada.sites ORDER BY name LIMIT 1)),
        date_trunc('day', now()) - INTERVAL '1 day',
        date_trunc('day', now()),
        INTERVAL '1 hour') rr
JOIN scada.points p ON p.point_id = rr.point_id
ORDER BY rr.bucket_start, p.display_name;

\echo '============================================================'
\echo ' 8) Data-quality sweep: the injected over_range sensor'
\echo '    glitches and offline outage markers, ready for a'
\echo '    monitoring/alerting story.'
\echo '============================================================'
SELECT r.data_quality, count(*) AS readings,
       min(r.event_time) AS first_seen, max(r.event_time) AS last_seen
FROM scada.point_readings r
WHERE r.data_quality <> 'online'
GROUP BY r.data_quality
ORDER BY readings DESC;

\echo '============================================================'
\echo ' 9) The plant itself: recursive device tree with points.'
\echo '============================================================'
SELECT repeat('  ', t.depth - 1) || t.name AS plant,
       t.node_type, t.device_type, t.uom
FROM scada.get_device_point_tree(
        (SELECT site_id FROM scada.sites ORDER BY name LIMIT 1)) t
LIMIT 40;
