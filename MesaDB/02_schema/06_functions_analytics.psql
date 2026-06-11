-- ============================================================================
-- Script:        06_functions_analytics.sql
-- Folder:        02_schema
-- Purpose:       Read-path analytics API over point_readings:
--                  * reading_value / quality helpers
--                  * uom_conversion_factor
--                  * readings_gapfilled  (time_bucket_gapfill + locf)
--                  * readings_rollup     (bucketed min/avg/max/sum/first/last)
--                  * rollup_power_to_energy (kW samples -> kWh per bucket)
--                  * get_point_history   (single entry point a UI would call)
-- Safe in prod:  N/A -- demo schema bootstrap. All functions are read-only.
-- Requires:      00_init.sql .. 05_functions_config.sql
-- Compatibility: TimescaleDB 2.9+ (timezone-aware time_bucket /
--                time_bucket_gapfill), community edition features only --
--                no Toolkit dependency, so the stock docker image works.
-- Notes:         These are simplified generic equivalents of production
--                rollup machinery; the goal is to demonstrate the
--                TimescaleDB patterns (gapfill, locf, first/last, tz-aware
--                bucketing) in readable form.
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- reading_value: collapse the three typed storage columns to float8 according
-- to the point's declared value_type.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.reading_value(
    _value_bigint  BIGINT,
    _value_double  DOUBLE PRECISION,
    _value_numeric NUMERIC,
    _value_type    point_value_type
)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
AS $func$
    SELECT CASE _value_type
        WHEN 'int64'   THEN _value_bigint::float8
        WHEN 'float64' THEN _value_double
        WHEN 'numeric' THEN _value_numeric::float8
    END;
$func$;

-- ---------------------------------------------------------------------------
-- quality_to_aggregate: collapse raw reading quality into the smaller set
-- used by aggregates (range violations and errors count as offline).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.quality_to_aggregate(_q data_quality)
RETURNS data_quality
LANGUAGE sql
IMMUTABLE
AS $func$
    SELECT CASE _q
        WHEN 'online'      THEN 'online'::data_quality
        WHEN 'estimated'   THEN 'estimated'::data_quality
        ELSE 'offline'::data_quality
    END;
$func$;

-- ---------------------------------------------------------------------------
-- uom_conversion_factor: multiplier from a point's raw unit to its rollup
-- unit. Extend the CASE as new unit pairs appear; unknown pairs fall through
-- to 1 (no conversion).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.uom_conversion_factor(_uom TEXT, _rollup_uom TEXT)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
AS $func$
    SELECT CASE
        -- power -> energy pairs (time integration handled by the caller)
        WHEN _uom = 'W'   AND _rollup_uom = 'kWh'    THEN 0.001
        WHEN _uom = 'W'   AND _rollup_uom = 'MWh'    THEN 0.000001
        WHEN _uom = 'kW'  AND _rollup_uom = 'Wh'     THEN 1000
        WHEN _uom = 'kW'  AND _rollup_uom = 'kWh'    THEN 1
        WHEN _uom = 'kW'  AND _rollup_uom = 'MWh'    THEN 0.001
        WHEN _uom = 'MW'  AND _rollup_uom = 'Wh'     THEN 1000000
        WHEN _uom = 'MW'  AND _rollup_uom = 'kWh'    THEN 1000
        -- energy -> energy pairs
        WHEN _uom = 'Wh'  AND _rollup_uom = 'kWh'    THEN 0.001
        WHEN _uom = 'Wh'  AND _rollup_uom = 'MWh'    THEN 0.000001
        WHEN _uom = 'kWh' AND _rollup_uom = 'Wh'     THEN 1000
        WHEN _uom = 'kWh' AND _rollup_uom = 'MWh'    THEN 0.001
        WHEN _uom = 'MWh' AND _rollup_uom = 'kWh'    THEN 1000
        -- irradiance
        WHEN _uom = 'Wh/m2'  AND _rollup_uom = 'kWh/m2' THEN 0.001
        ELSE 1
    END;
$func$;

-- ---------------------------------------------------------------------------
-- readings_gapfilled: a regular time grid per point, carrying the last known
-- value forward through gaps (locf), flagging which rows are real samples vs
-- generated fill. The classic TimescaleDB charting query, packaged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.readings_gapfilled(
    _point_ids UUID[],
    _start     TIMESTAMPTZ,
    _end       TIMESTAMPTZ,
    _bucket    INTERVAL,
    _timezone  TEXT DEFAULT 'UTC'
)
RETURNS TABLE (
    bucket_time  TIMESTAMPTZ,
    point_id     UUID,
    value        DOUBLE PRECISION,
    data_quality data_quality,
    is_generated BOOLEAN
)
LANGUAGE sql
STABLE
SET search_path = scada, public
AS $func$
    SELECT
        time_bucket_gapfill(_bucket, r.event_time, _timezone, _start, _end) AS bucket_time,
        r.point_id,
        locf(
            last(scada.reading_value(r.value_bigint, r.value_double,
                                     r.value_numeric, p.value_type),
                 r.event_time)
        ) AS value,
        locf(last(scada.quality_to_aggregate(r.data_quality), r.event_time)) AS data_quality,
        (count(r.event_time) = 0) AS is_generated   -- no raw samples in this bucket
    FROM point_readings r
    JOIN points p ON p.point_id = r.point_id
    WHERE r.point_id     = ANY(_point_ids)
      AND r.event_time  >= _start
      AND r.event_time  <  _end
      AND r.reading_type = 'raw'
    GROUP BY bucket_time, r.point_id
    ORDER BY r.point_id, bucket_time;
$func$;

-- ---------------------------------------------------------------------------
-- readings_rollup: bucketed statistics per point with quality aggregation
-- ('mixed' when a bucket contains more than one quality). Timezone-aware
-- bucketing matters for day/month buckets: a "day" is the site's local day.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.readings_rollup(
    _point_ids UUID[],
    _start     TIMESTAMPTZ,
    _end       TIMESTAMPTZ,
    _bucket    INTERVAL,
    _timezone  TEXT DEFAULT 'UTC'
)
RETURNS TABLE (
    point_id     UUID,
    bucket_start TIMESTAMPTZ,
    bucket_end   TIMESTAMPTZ,
    sample_count BIGINT,
    avg_value    DOUBLE PRECISION,
    min_value    DOUBLE PRECISION,
    max_value    DOUBLE PRECISION,
    sum_value    DOUBLE PRECISION,
    first_value  DOUBLE PRECISION,
    last_value   DOUBLE PRECISION,
    data_quality data_quality
)
LANGUAGE sql
STABLE
SET search_path = scada, public
AS $func$
    WITH typed AS (
        SELECT
            r.point_id,
            time_bucket(_bucket, r.event_time, _timezone) AS bucket_start,
            r.event_time,
            scada.reading_value(r.value_bigint, r.value_double,
                                r.value_numeric, p.value_type) AS value,
            scada.quality_to_aggregate(r.data_quality)         AS agg_quality
        FROM point_readings r
        JOIN points p ON p.point_id = r.point_id
        WHERE r.point_id     = ANY(_point_ids)
          AND r.event_time  >= _start
          AND r.event_time  <  _end
          AND r.reading_type = 'raw'
    )
    SELECT
        t.point_id,
        t.bucket_start,
        t.bucket_start + _bucket          AS bucket_end,
        count(*)                          AS sample_count,
        avg(t.value)                      AS avg_value,
        min(t.value)                      AS min_value,
        max(t.value)                      AS max_value,
        sum(t.value)                      AS sum_value,
        first(t.value, t.event_time)      AS first_value,
        last(t.value, t.event_time)       AS last_value,
        -- NB: first() not min() -- PostgreSQL has no min/max aggregates for enums
        CASE WHEN count(DISTINCT t.agg_quality) = 1
             THEN first(t.agg_quality, t.event_time)
             ELSE 'mixed'::data_quality
        END                               AS data_quality
    FROM typed t
    GROUP BY t.point_id, t.bucket_start
    ORDER BY t.point_id, t.bucket_start;
$func$;

-- ---------------------------------------------------------------------------
-- rollup_power_to_energy: integrate power samples into energy per bucket:
-- avg power over the bucket x bucket hours x unit conversion. Honest
-- simplification of production accumulator machinery -- exact for the demo's
-- regular sample spacing; production systems handle irregular spacing,
-- counter resets, and bucket-edge deltas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.rollup_power_to_energy(
    _point_ids UUID[],
    _start     TIMESTAMPTZ,
    _end       TIMESTAMPTZ,
    _bucket    INTERVAL,
    _timezone  TEXT DEFAULT 'UTC'
)
RETURNS TABLE (
    point_id     UUID,
    bucket_start TIMESTAMPTZ,
    bucket_end   TIMESTAMPTZ,
    sample_count BIGINT,
    avg_power    DOUBLE PRECISION,
    energy       DOUBLE PRECISION,   -- in the point's rollup_uom
    energy_uom   TEXT,
    data_quality data_quality
)
LANGUAGE sql
STABLE
SET search_path = scada, public
AS $func$
    SELECT
        rr.point_id,
        rr.bucket_start,
        rr.bucket_end,
        rr.sample_count,
        rr.avg_value AS avg_power,
        rr.avg_value
          * (EXTRACT(EPOCH FROM _bucket) / 3600.0)
          * scada.uom_conversion_factor(p.uom, p.rollup_uom) AS energy,
        p.rollup_uom AS energy_uom,
        rr.data_quality
    FROM scada.readings_rollup(_point_ids, _start, _end, _bucket, _timezone) rr
    JOIN points p ON p.point_id = rr.point_id
    ORDER BY rr.point_id, rr.bucket_start;
$func$;

-- ---------------------------------------------------------------------------
-- get_point_history: the single entry point a UI/API layer would call.
-- Maps a friendly sample-time keyword to an interval, dispatches to the
-- right rollup based on each point's configured rollup_method, and returns
-- one value column selected by _value_kind.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.get_point_history(
    _site_id     UUID,
    _point_ids   UUID[],
    _sample_time TEXT,                    -- '5min'|'15min'|'hour'|'day'|'month'
    _start       TIMESTAMPTZ,
    _end         TIMESTAMPTZ,
    _value_kind  TEXT DEFAULT 'avg'       -- 'avg'|'min'|'max'|'sum'|'last'|'energy'
)
RETURNS TABLE (
    point_id     UUID,
    bucket_start TIMESTAMPTZ,
    bucket_end   TIMESTAMPTZ,
    value        DOUBLE PRECISION,
    value_kind   TEXT,
    data_quality data_quality
)
LANGUAGE plpgsql
STABLE
SET search_path = scada, public
AS $func$
DECLARE
    _bucket   INTERVAL;
    _timezone TEXT;
BEGIN
    _bucket := CASE lower(_sample_time)
        WHEN '5min'  THEN INTERVAL '5 minutes'
        WHEN '15min' THEN INTERVAL '15 minutes'
        WHEN 'hour'  THEN INTERVAL '1 hour'
        WHEN 'day'   THEN INTERVAL '1 day'
        WHEN 'month' THEN INTERVAL '1 month'
    END;
    IF _bucket IS NULL THEN
        RAISE EXCEPTION 'Unknown sample_time "%". Use 5min|15min|hour|day|month.', _sample_time;
    END IF;

    -- Bucket in the site's local timezone (a "day" is the site's day)
    SELECT s.timezone INTO _timezone FROM sites s WHERE s.site_id = _site_id;
    IF _timezone IS NULL THEN
        RAISE EXCEPTION 'Unknown site %.', _site_id;
    END IF;

    IF lower(_value_kind) = 'energy' THEN
        RETURN QUERY
        SELECT pe.point_id, pe.bucket_start, pe.bucket_end,
               pe.energy, 'energy'::text, pe.data_quality
        FROM scada.rollup_power_to_energy(_point_ids, _start, _end, _bucket, _timezone) pe;
    ELSE
        RETURN QUERY
        SELECT rr.point_id, rr.bucket_start, rr.bucket_end,
               CASE lower(_value_kind)
                   WHEN 'min'  THEN rr.min_value
                   WHEN 'max'  THEN rr.max_value
                   WHEN 'sum'  THEN rr.sum_value
                   WHEN 'last' THEN rr.last_value
                   ELSE rr.avg_value
               END,
               lower(_value_kind),
               rr.data_quality
        FROM scada.readings_rollup(_point_ids, _start, _end, _bucket, _timezone) rr;
    END IF;
END;
$func$;