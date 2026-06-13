# 05_performance — Benchmarks, Plans, and a Lock You Can Watch

Narrated, matched-pair performance demos. Each script shows the query a
design decision serves **and** the query it doesn't — because knowing where
a technique stops working is the actual expertise.

Run after the full demo is built (`./demo.sh`), then:

```bash
./demo.sh bench        # runs 00 -> 02 below
```

…or individually with `docker compose exec -T db psql -U scada -d scada_demo -f /repo/05_performance/<file>`.
Timings are cache-sensitive: run twice, trust the warm pass.

| Script | The lesson |
|---|---|
| `00_benchmark_compression.sql` | Compressed vs uncompressed query behavior; why `segmentby = point_id` makes point-filtered queries cheap and value-filtered scans expensive; the before/after storage receipt |
| `01_explain_walkthrough.sql` | Chunk exclusion (and the no-time-filter smell); the CASE expression index matching exactly or not at all; the partial index that stays tiny forever |
| `02_cagg_vs_raw_benchmark.sql` | The same daily report from raw vs hourly cagg vs daily cagg — plus the kicker: the cagg answers for dates raw retention already deleted |
| `demo_blocking_locks.sql` | Two-terminal reproducible row-lock block; watch detection live with `01_monitoring/02_blocking_locks.sql`, then resolve it |

## Demo geometry these scripts assume

1-day chunks · compression after 7 days · raw retention 45 days · 60 days
generated. That layout is what makes "2 days ago" uncompressed, "30 days
ago" compressed, and "50 days ago" cagg-only. If you've changed
`demo_config`, adjust the intervals in the scripts to taste.
