-- ============================================================================
-- Script:        00_database_info.sql
-- Folder:        01_monitoring
-- Purpose:       Inventory of all databases on the server: size, owner,
--                encoding/locale, connection settings, tablespace, current
--                connection counts, and transaction-ID age (wraparound risk).
-- Safe in prod:  YES (read-only)
-- Requires:      pg_catalog access. pg_database_size() requires CONNECT
--                privilege on each database (or pg_read_all_stats).
-- Compatibility: PostgreSQL 12+
-- Notes:         On managed services (RDS, Cloud SQL, Timescale Cloud),
--                visibility into other databases may be restricted.
--                xid_age approaching ~2,000,000,000 indicates urgent
--                wraparound risk; autovacuum freeze should keep this low.
-- ============================================================================

WITH conn_counts AS (
  SELECT
    datname,
    COUNT(*)                                  AS total_connections,
    COUNT(*) FILTER (WHERE state = 'active')  AS active_connections
  FROM pg_stat_activity
  WHERE datname IS NOT NULL
  GROUP BY datname
)
SELECT
  now()                                        AS as_of,
  d.datname                                    AS database_name,
  pg_size_pretty(pg_database_size(d.datname))  AS total_size,
  ROUND(pg_database_size(d.datname) / 1024.0 / 1024 / 1024, 3) AS total_gb,
  u.usename                                    AS owner_name,
  pg_encoding_to_char(d.encoding)              AS encoding,
  d.datcollate                                 AS collation,
  d.datctype                                   AS character_type,
  d.datallowconn                               AS allow_connections,
  d.datconnlimit                               AS connection_limit,
  COALESCE(cc.total_connections, 0)            AS current_connections,
  COALESCE(cc.active_connections, 0)           AS active_connections,
  age(d.datfrozenxid)                          AS xid_age,
  ts.spcname                                   AS tablespace_name
FROM pg_database d
LEFT JOIN pg_tablespace ts ON ts.oid = d.dattablespace
LEFT JOIN pg_user u        ON u.usesysid = d.datdba
LEFT JOIN conn_counts cc   ON cc.datname = d.datname
WHERE NOT d.datistemplate
ORDER BY pg_database_size(d.datname) DESC, d.datname;