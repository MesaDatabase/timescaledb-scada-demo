# PostgreSQL / TimescaleDB DBA Tools

This folder contains DBA-facing scripts and lightweight standards to operate PostgreSQL and TimescaleDB.

## Folder layout

- `standards/` – baseline conventions
- `monitoring/` – read-only queries for triage and visibility
- `maintenance/` – operational checks and safe maintenance helpers (not all read-only)
- `security/` – role/privilege auditing queries
- `ha_replication/` – replication/HA visibility checks
- `toolbox/` – general utility queries/templates

## Safety

- **Monitoring scripts are intended to be safe in production** (read-only).
- Some scripts create **TEMP tables** for compatibility (still safe; session-scoped).
- **No secrets** in repo. No passwords, tokens, connection strings, or private hostnames.

## Prerequisites / permissions

Some views are restricted without appropriate privileges:

- `pg_stat_activity`, `pg_stat_statements` often require `pg_read_all_stats` (or elevated privileges) to see all sessions/queries.
- Timescale informational views require the `timescaledb` extension.


## How to run

### Using psql (recommended for repeatability)

PowerShell example:
```powershell
psql -h <host> -p 5432 -U <user> -d <db> -v ON_ERROR_STOP=1 -f .\postgres\monitoring\01_active_sessions.sql