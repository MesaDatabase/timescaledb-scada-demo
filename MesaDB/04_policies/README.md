# 04_policies — Compression, Continuous Aggregates, Retention

The automation layer: what TimescaleDB does to the data *after* it lands.
Structure (segmentby/orderby, chunk intervals) was defined with the tables in
`02_schema`; this folder schedules the work and adds the observability.

## Install order

```bash
psql -d scada_demo -f 00_compression_policies.sql  # schedule + compress now
psql -d scada_demo -f 01_continuous_aggregates.sql # hourly + daily caggs
psql -d scada_demo -f 02_retention.sql             # logged retention + job
psql -d scada_demo -f 03_policy_status.sql         # verify everything
```

Run after `03_data_generation` so there's data to compress, materialize, and
expire. Everything is idempotent (`if_not_exists`, guarded `add_job`).

## What each piece demonstrates

**Compression (`00`)** — policies for all four hypertables, plus
`compress_eligible_now()` so the demo doesn't wait for the background worker:
it walks every uncompressed chunk older than each table's own policy
threshold and compresses synchronously. With 60 days of 1-day chunks and a
7-day threshold, expect ~53 compressed chunks and 90%+ ratios in
`01_monitoring/07_compression_overview.sql` — the screenshot for the repo
README.

**Continuous aggregates (`01`)** — three showcase features in one file:

- `readings_1h` is a **real-time aggregate** (`materialized_only = false`):
  queries transparently union materialized buckets with raw rows newer than
  the watermark. Insert a reading, query the view, it's there.
- `readings_1d` is **hierarchical** — built from the hourly cagg, not raw
  data. Note the sum/count parts stored precisely so the daily average is
  `sum(sum)/sum(n)`, never an average of averages.
- The hourly cagg is itself **compressed** (caggs are hypertables
  underneath).

**Retention (`02`)** — the logged custom-job pattern: per-table day counts in
`retention_settings`, a sweep function that logs actual dropped-chunk counts,
duration, and errors per table to `retention_logs` (one table's failure never
stops the sweep), a validated `set_retention_days()` helper, and a TimescaleDB
**custom job** (the `(job_id, config)` procedure adapter) running it daily.
The native `add_retention_policy()` one-liner is shown commented for
contrast — use it when you don't need the audit trail.

## The downsampling story (the best 30 seconds of the demo)

`point_readings` retains **45 days**, but the generator produced **60** — so
`02_retention.sql` visibly drops ~15 raw chunks the moment it runs, while
`readings_1h` and `readings_1d` keep the full aggregate history. Query 5 in
`03_policy_status.sql` proves it on one screen: raw data now starts ~45 days
back, the daily cagg still covers everything. Raw detail ages out, history
survives at lower resolution — the classic time-series tiering pattern,
happening live.

Ordering note: cagg refresh policies reach back 3–7 days; retention reaches
back 45+. Keep refresh windows shorter than retention or refreshes will chase
data that no longer exists.

## Files

| Script | Contents |
|---|---|
| `00_compression_policies.sql` | `add_compression_policy` × 4 + `compress_eligible_now()` |
| `01_continuous_aggregates.sql` | `readings_1h` (real-time, compressed), `readings_1d` (hierarchical), refresh policies |
| `02_retention.sql` | `retention_settings` seeds, `enforce_retention()` with logging, `set_retention_days()`, daily custom job |
| `03_policy_status.sql` | Jobs, compression posture, cagg state, retention audit, downsampling proof |
