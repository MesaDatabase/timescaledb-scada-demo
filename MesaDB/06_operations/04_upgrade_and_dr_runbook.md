# Upgrade & DR Runbook — TimescaleDB on PostgreSQL

The judgment layer: what to do, in what order, and which mistakes are
expensive. Commands assume the demo's docker setup; the sequences are the
same on metal, VMs, or managed services.

## 1. The golden rule of ordering

There are two different upgrades, and they never happen at the same time:

1. **TimescaleDB extension upgrade** (e.g. 2.13 → 2.15) — within the same
   PostgreSQL major version.
2. **PostgreSQL major upgrade** (e.g. 15 → 16) — with the TimescaleDB
   version held constant.

Mixing them in one step is the classic self-inflicted outage. Extension
first, verify, then the PG major, verify again.

## 2. TimescaleDB extension upgrade

```sql
-- BEFORE: record state and back up (02_backup.sh)
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
SELECT count(*) FROM timescaledb_information.jobs;

-- What could these binaries run? (installed vs available)
SELECT e.extname, e.extversion AS installed, a.default_version AS available
FROM pg_extension e
JOIN pg_available_extensions a ON a.name = e.extname
WHERE e.extname = 'timescaledb';

-- The upgrade must be the FIRST command in a fresh session
-- (psql -X to skip .psqlrc), with no other connections active:
ALTER EXTENSION timescaledb UPDATE;

-- AFTER: verify
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
SELECT job_id, application_name, scheduled
FROM timescaledb_information.jobs ORDER BY job_id;   -- jobs intact?
CALL refresh_continuous_aggregate('scada.readings_1h',
     now() - INTERVAL '2 hours', now() - INTERVAL '1 hour');  -- caggs OK?
```

In this docker demo, the extension binary comes from the image: bump the
tag (`timescale/timescaledb-ha:pg16` → newer), `docker compose up -d`,
then run `ALTER EXTENSION timescaledb UPDATE;`. The new binaries can load
an old catalog; the `ALTER` migrates the catalog forward. **Never skip it.**

Read the release notes for the target version every time — deprecations
(e.g. old policy APIs, multi-node removal) land in minor versions.

## 3. PostgreSQL major upgrade

Three strategies, in order of preference at small-to-medium scale:

**A. Dump & restore (this repo's tooling)** — simplest, requires downtime
proportional to data size. `02_backup.sh` on the old, `03_restore.sh` on
the new, with the *same TimescaleDB version installed on both sides*.
Upgrade the extension afterward if desired.

**B. `pg_upgrade`** — in-place, fast (hard links), but both clusters must
have the same TimescaleDB version compiled for their respective PG majors,
and you must run `timescaledb_pre_restore`-equivalent discipline: follow
Timescale's documented pg_upgrade procedure exactly.

**C. Logical replication cutover** — near-zero downtime, but logical
replication does not carry TimescaleDB catalog/internal chunk structure
cleanly; it's an advanced migration pattern, not a default.

Container reality check: a PG major bump means a **new data directory** —
the volume initialized by pg15 will not start under a pg16 image. Plan A
side-steps this completely: new volume, restore into it.

## 4. Disaster recovery posture (and honest demo limits)

This repo ships **logical** backup/restore because it demos cleanly. Know
its limits out loud:

| | Logical (pg_dump) | Physical (pgBackRest / WAL archiving) |
|---|---|---|
| Restore granularity | whole database | cluster, to any point in time (PITR) |
| RPO | since last dump | seconds (continuous WAL) |
| Speed at scale | hours on TBs | fast, incremental, parallel |
| TimescaleDB fit | needs pre/post hooks | transparent — it's just PostgreSQL files |
| Right tool when | small DBs, migrations, dev seeding | production |

Production answer in one line: **pgBackRest with WAL archiving for PITR,
plus a streaming replica for availability** — backups solve "we lost data,"
replicas solve "we lost a server," and neither substitutes for the other.

**Test the restore, not the backup.** A backup that has never been restored
is a hope, not a backup. `03_restore.sh` restores side-by-side into
`scada_restored` precisely so the drill is cheap — run it monthly, check
the sanity counts, drop the database.

## 5. Pre-flight checklist (any upgrade, any environment)

- [ ] Fresh backup taken **and restore-verified** (`03_restore.sh`)
- [ ] `SELECT extversion ...` and PG version recorded
- [ ] Release notes read for *every* version being crossed
- [ ] Background jobs inventoried (`timescaledb_information.jobs`)
- [ ] App connections drained / maintenance window declared
- [ ] Rollback plan written down *before* starting (usually: restore the
      verified backup) — if the rollback plan is "hope," stop
