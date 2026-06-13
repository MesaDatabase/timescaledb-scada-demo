-- ============================================================================
-- Script:        02_retention.sql
-- Folder:        04_policies
-- Purpose:       Data retention with an audit trail. Instead of one opaque
--                add_retention_policy() per table, this uses:
--                  * retention_settings -- desired days per hypertable (SQL-
--                    editable config, seeded below)
--                  * enforce_retention() -- drops eligible chunks for every
--                    configured table, logging chunk counts, duration, and
--                    errors per table to retention_logs, never letting one
--                    table's failure stop the others
--                  * set_retention_days() -- validated upsert helper
--                  * a TimescaleDB custom job running it daily
-- Safe in prod:  CAUTION -- retention DELETES DATA (whole chunks). The
--                pattern itself is production-grade; the seeded day counts
--                are demo values.
-- Requires:      02_schema, 03_data_generation, 00_compression_policies.sql
-- Compatibility: TimescaleDB 2.13+
-- Notes:         Why custom instead of add_retention_policy()? Three wins:
--                per-table config lives in a queryable table, every run
--                leaves an audit row (your compliance/postmortem story),
--                and one failing table can't silently starve the rest.
--                Native policies are simpler when you don't need any of
--                that -- equivalents are commented at the bottom.
--
--                THE DOWNSAMPLING STORY: point_readings retention (45d) is
--                shorter than the demo's 60 days of data, so raw chunks
--                visibly drop -- but readings_1h / readings_1d keep the
--                hourly and daily history. Raw detail ages out; aggregate
--                history survives. That is the classic TimescaleDB tiering
--                pattern, live in the demo.
-- ============================================================================

SET search_path = scada, public;

-- ---------------------------------------------------------------------------
-- Seed desired retention (table created in 02_schema). Demo values: raw
-- readings kept 45 days (15 days of the generated 60 will drop on first
-- enforcement -- intentional, watch it happen), business records longer.
-- ---------------------------------------------------------------------------
INSERT INTO retention_settings (hypertable_name, retention_days) VALUES
    ('point_readings',           45),
    ('control_requests',        180),
    ('control_requests_history', 90),
    ('alarm_events',             90)
ON CONFLICT (hypertable_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- set_retention_days: validated upsert.
--   SELECT scada.set_retention_days('point_readings', 30);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.set_retention_days(_hypertable TEXT, _days INT)
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _name TEXT := lower(btrim(_hypertable));
BEGIN
    IF _days IS NULL OR _days < 0 THEN
        RAISE EXCEPTION 'Retention days must be a non-negative integer.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables h
        WHERE h.hypertable_schema = 'scada' AND h.hypertable_name = _name
    ) THEN
        RAISE EXCEPTION '"%" is not a hypertable in the scada schema.', _name;
    END IF;

    INSERT INTO retention_settings (hypertable_name, retention_days)
    VALUES (_name, _days)
    ON CONFLICT (hypertable_name)
    DO UPDATE SET retention_days = EXCLUDED.retention_days,
                  updated_at     = CURRENT_TIMESTAMP;

    RETURN format('Retention for %s set to %s days (enforced on next run).', _name, _days);
END;
$func$;

-- ---------------------------------------------------------------------------
-- enforce_retention: the worker. One log row per table per run + a summary
-- row; per-table exception handling so a single failure never blocks the
-- sweep. drop_chunks() returns the dropped chunk names -- we count actuals,
-- not estimates.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION scada.enforce_retention()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = scada, public
AS $func$
DECLARE
    _setting      RECORD;
    _table_t0     TIMESTAMPTZ;
    _run_t0       TIMESTAMPTZ := clock_timestamp();
    _dropped      INT;
    _total        INT := 0;
    _failures     INT := 0;
BEGIN
    FOR _setting IN
        SELECT rs.hypertable_name, rs.retention_days
        FROM retention_settings rs
        ORDER BY rs.hypertable_name
    LOOP
        _table_t0 := clock_timestamp();
        BEGIN
            -- Validate it's still a real hypertable (tables get dropped,
            -- settings linger -- log it instead of exploding).
            IF NOT EXISTS (
                SELECT 1 FROM timescaledb_information.hypertables h
                WHERE h.hypertable_schema = 'scada'
                  AND h.hypertable_name = _setting.hypertable_name
            ) THEN
                RAISE EXCEPTION 'not a hypertable in schema scada';
            END IF;

            SELECT count(*) INTO _dropped
            FROM drop_chunks(
                format('%I.%I', 'scada', _setting.hypertable_name)::regclass,
                older_than => make_interval(days => _setting.retention_days));

            INSERT INTO retention_logs
                (hypertable_name, deleted_chunks, duration, status)
            VALUES
                (_setting.hypertable_name, _dropped,
                 clock_timestamp() - _table_t0,
                 CASE WHEN _dropped > 0 THEN 'success' ELSE 'no_chunks_eligible' END);

            _total := _total + _dropped;

        EXCEPTION WHEN OTHERS THEN
            _failures := _failures + 1;
            INSERT INTO retention_logs
                (hypertable_name, duration, status, error_message)
            VALUES
                (_setting.hypertable_name, clock_timestamp() - _table_t0,
                 'failed', SQLERRM);
            -- continue with the next table
        END;
    END LOOP;

    INSERT INTO retention_logs (hypertable_name, deleted_chunks, duration, status)
    VALUES ('ALL', _total, clock_timestamp() - _run_t0,
            format('completed (%s failures)', _failures));

    RETURN format('Retention sweep: %s chunks dropped across %s tables, %s failures (%s).',
        _total, (SELECT count(*) FROM retention_settings), _failures,
        clock_timestamp() - _run_t0);
END;
$func$;

-- ---------------------------------------------------------------------------
-- Schedule it: a TimescaleDB CUSTOM JOB. add_job requires the signature
-- (job_id INT, config JSONB) -- this thin procedure adapts it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE scada.retention_job(job_id INT, config JSONB)
LANGUAGE plpgsql
SET search_path = scada, public
AS $proc$
BEGIN
    PERFORM scada.enforce_retention();
END;
$proc$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'scada' AND proc_name = 'retention_job'
    ) THEN
        PERFORM add_job('scada.retention_job', INTERVAL '1 day',
                        config => '{}'::jsonb);
    END IF;
END $$;

-- Run it once, live: with 60 days generated and 45 days retained,
-- point_readings drops ~15 one-day chunks right here.
SELECT scada.enforce_retention();

\echo ''
\echo 'Retention log (newest first):'
SELECT executed_at, hypertable_name, deleted_chunks, duration, status,
       left(coalesce(error_message, ''), 40) AS error
FROM scada.retention_logs
ORDER BY log_id DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- The native one-liner alternative, for comparison (don't run both -- two
-- janitors, one hallway):
--   SELECT add_retention_policy('scada.point_readings', INTERVAL '45 days');
-- ---------------------------------------------------------------------------
