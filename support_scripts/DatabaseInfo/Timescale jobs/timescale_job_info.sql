-- See timescale jobs
SELECT *
FROM timescaledb_information.jobs
ORDER BY job_id;

-- Timescale job history
SELECT *
FROM _timescaledb_internal.bgw_job_stat_history
ORDER BY execution_start DESC
LIMIT 50;

-- See job definition
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = '_timescaledb_functions'
  AND p.proname = 'policy_job_stat_history_retention';  -- example