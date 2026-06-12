-- ============================================================================
-- Script:        00_roles_and_grants.sql
-- Folder:        06_operations
-- Purpose:       Production-pattern role architecture for the scada schema:
--                three NOLOGIN group roles (readonly / readwrite / app) plus
--                a monitoring role, with DEFAULT PRIVILEGES so objects
--                created later inherit the right grants automatically --
--                the step everyone forgets, and the reason "it worked until
--                we added a table" tickets exist.
-- Safe in prod:  YES as a pattern. Roles are cluster-wide: review names
--                before running on a shared server. Idempotent.
-- Requires:      02_schema installed. Run as a superuser/owner.
-- Compatibility: PostgreSQL 14+
-- Notes:         Group roles are NOLOGIN by design -- humans and services
--                get LOGIN roles GRANTed into a group (template at bottom).
--                No passwords live in this repo.
-- ============================================================================

SET search_path = scada, public;

-- Idempotent role creation (CREATE ROLE has no IF NOT EXISTS)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'scada_readonly') THEN
        CREATE ROLE scada_readonly NOLOGIN;
        COMMENT ON ROLE scada_readonly IS 'SELECT on scada tables/views; EXECUTE on read-path functions.';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'scada_readwrite') THEN
        CREATE ROLE scada_readwrite NOLOGIN;
        COMMENT ON ROLE scada_readwrite IS 'readonly + DML on scada tables. For ETL / integration services.';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'scada_app') THEN
        CREATE ROLE scada_app NOLOGIN;
        COMMENT ON ROLE scada_app IS 'Application identity: works through the function API where possible.';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'scada_monitor') THEN
        CREATE ROLE scada_monitor NOLOGIN;
        COMMENT ON ROLE scada_monitor IS 'For 01_monitoring tooling: stats visibility, read-only.';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Schema access
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA scada TO scada_readonly, scada_readwrite, scada_app, scada_monitor;

-- ---------------------------------------------------------------------------
-- readonly: everything visible, nothing touchable
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA scada TO scada_readonly;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA scada TO scada_readonly;

-- readwrite: inherits readonly, adds DML + sequence usage
GRANT scada_readonly TO scada_readwrite;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA scada TO scada_readwrite;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA scada TO scada_readwrite;

-- app: the service the platform runs as. Full DML today; the aspirational
-- posture (worth stating in interviews) is EXECUTE-only on the function API
-- with direct table grants withdrawn.
GRANT scada_readwrite TO scada_app;

-- monitor: read-only + the stats superpowers the 01_monitoring suite needs
GRANT scada_readonly TO scada_monitor;
GRANT pg_read_all_stats TO scada_monitor;

-- ---------------------------------------------------------------------------
-- DEFAULT PRIVILEGES: tables/functions created in scada FROM NOW ON get the
-- same grants automatically. Scoped to the role running this script (the
-- schema owner) -- objects created by other roles need their own defaults.
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA scada
    GRANT SELECT ON TABLES TO scada_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA scada
    GRANT INSERT, UPDATE, DELETE ON TABLES TO scada_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA scada
    GRANT USAGE ON SEQUENCES TO scada_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA scada
    GRANT EXECUTE ON FUNCTIONS TO scada_readonly;

-- ---------------------------------------------------------------------------
-- LOGIN role template (do NOT commit real passwords -- run interactively):
--
--   CREATE ROLE jane_analyst LOGIN PASSWORD '...';
--   GRANT scada_readonly TO jane_analyst;
--
--   CREATE ROLE svc_ingest LOGIN PASSWORD '...';
--   GRANT scada_readwrite TO svc_ingest;
--
--   CREATE ROLE grafana LOGIN PASSWORD '...';
--   GRANT scada_monitor TO grafana;
-- ---------------------------------------------------------------------------

\echo 'Role architecture applied:'
SELECT r.rolname,
       r.rolcanlogin AS can_login,
       array_remove(array_agg(m.rolname ORDER BY m.rolname), NULL) AS member_of
FROM pg_roles r
LEFT JOIN pg_auth_members am ON am.member = r.oid
LEFT JOIN pg_roles m         ON m.oid = am.roleid
WHERE r.rolname LIKE 'scada\_%'
GROUP BY r.rolname, r.rolcanlogin
ORDER BY r.rolname;
