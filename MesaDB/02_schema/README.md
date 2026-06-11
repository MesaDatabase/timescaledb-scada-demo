# 02_schema — Generic SCADA Time-Series Schema

A vendor-neutral schema for SCADA/EMS telemetry on PostgreSQL + TimescaleDB,
flavored for a solar + battery plant: sites, devices, points, high-volume
readings, a control/command pipeline with a full audit trail, and an alarm
subsystem. This is the structure that `03_data_generation` seeds and that
every monitoring script in `01_monitoring` reports on.

## Install order

```bash
psql -d scada_demo -f 00_init.sql
psql -d scada_demo -f 01_types.sql
psql -d scada_demo -f 02_reference_tables.sql
psql -d scada_demo -f 03_hypertables.sql
psql -d scada_demo -f 04_alarm_tables.sql
psql -d scada_demo -f 05_functions_config.sql
psql -d scada_demo -f 06_functions_analytics.sql
```

Requires TimescaleDB 2.13+ (community edition is sufficient — no Toolkit
dependency anywhere in this folder).

## What's where

| Script | Contents |
|---|---|
| `00_init.sql` | Extensions, the `scada` schema, search_path conventions |
| `01_types.sql` | All enum types (statuses, qualities, severities) |
| `02_reference_tables.sql` | Sites, settings, value maps, devices + hierarchy, points, derived points, schedules, retention framework tables |
| `03_hypertables.sql` | `point_readings`, `control_requests`, `control_requests_history` — hypertables, compression settings, indexes |
| `04_alarm_tables.sql` | Alarm definitions/expressions/dependencies, `alarm_history`, `alarm_events` hypertable |
| `05_functions_config.sql` | Last-writer-wins upserts, `submit_control_request` dual-write audit, device tree |
| `06_functions_analytics.sql` | Gapfill, rollups, power→energy, `get_point_history` API |

## Design decisions worth reading the comments for

**Hypertable vs regular table is a per-table decision.** `point_readings`,
`control_requests`, and `alarm_events` are append-heavy and time-ordered —
hypertables with compression. `alarm_history` is bounded and update-heavy —
deliberately a regular table.

**Compression settings live with the table; policies live in `04_policies`.**
`segmentby`/`orderby` choices are structural (they define how compressed
chunks are organized and effectively replace b-tree indexes inside them);
*when* compression runs is an operational policy.

**Primary keys on hypertables lead with the partition column.** A hypertable
cannot enforce uniqueness that omits the partition column — see the comment
on `alarm_events` for the trade-off this forces.

**No foreign keys from hypertables.** FK validation on billions of telemetry
rows is a write tax; integrity is enforced at the ingest boundary. Reference
tables keep full FK discipline.

**Typed value columns, not JSONB.** `point_readings` carries
`value_bigint` / `value_double` / `value_numeric` with `points.value_type`
selecting the populated column — native columns compress and aggregate far
better than document storage.

**Replay-safe writes.** All config upserts use
`ON CONFLICT ... WHERE EXCLUDED.updated_at > target.updated_at`: stale or
replayed sync messages can never clobber newer data.

**The expression index on `control_requests`** collapses four in-flight
statuses into a single leading key value, matching the hottest dashboard
query's CASE exactly — an example of indexing for the query you actually run.

## Entity overview

```
sites ─┬─ settings, value_maps, control_schedules, alarm_definitions
       ├─ devices ─┬─ device_hierarchy (self-ref)
       │           ├─ device_properties
       │           └─ device_points ── points ─┬─ derived_points ── derived_point_sources
       │                                       └─ point_readings (hypertable)
       ├─ control_requests (hypertable) ──→ control_requests_history (hypertable, audit)
       └─ alarm_definitions ─┬─ alarm_definition_expressions
                             ├─ alarm_definition_dependencies
                             ├─ alarm_history ── alarm_events (hypertable)
```