# 03_data_generation — Config-Driven Synthetic Plant Data

Generates a coherent, explorable solar + battery plant: realistic solar
curves, weather, equipment outages, a living control queue, and an alarm
board where **every alarm is explainable by the data**. One config table
controls everything.

## Quick start

```bash
psql -d scada_demo -f 00_demo_config.sql       # config table + reset function
psql -d scada_demo -f 01_seed_reference.sql    # sites, devices, points, alarm defs
psql -d scada_demo -f 02_generate_readings.sql # ~0.8M telemetry rows (defaults)
psql -d scada_demo -f 03_generate_activity.sql # control requests + alarms
psql -d scada_demo -f 04_showcase_queries.sql  # guided tour of the result
```

Re-running 02 or 03 wipes and rebuilds their own data, so tweak → re-run →
look is the whole workflow. `SELECT scada.reset_demo_data();` clears
everything (config survives).

## The config table

Everything tunable lives in `scada.demo_config` — amounts, cadence, dates,
fleet size, chaos levels:

| Key | Default | What it does |
|---|---|---|
| `sites_count` | 2 | 1–3 sites, each with its own timezone and weather |
| `inverters_per_site` | 6 | Fleet size; each inverter = 3 points |
| `inverter_rated_kw` | 250 | The AC rating clear days will clip against |
| `dc_ac_ratio` | 1.25 | Panel oversizing — the *cause* of clipping |
| `battery_power_kw` / `battery_capacity_kwh` | 500 / 2000 | Battery size |
| `history_days` | 60 | Days of history (more days = more chunks to compress) |
| `reading_interval` | 5 minutes | Telemetry cadence (1 min ≈ 5× the rows) |
| `outage_rate_per_month` | 1.5 | Equipment failures per inverter per month |
| `storm_day_chance` | 0.12 | Probability a day's output gets crushed by weather |
| `dispatch_per_day` | 24 | Battery control requests per site per day |
| `random_seed` | 0.42 | Same seed + same config ⇒ same demo (near enough)* |

```sql
UPDATE scada.demo_config SET value = '90' WHERE key = 'history_days';
-- then re-run 02 and 03
```

\* `setseed()` makes the random stream repeatable, but parallel plans can
reorder evaluation — treat it as "deterministic enough for a demo."

Default volume: 2 sites × 24 points × 288 samples/day × 60 days ≈ **0.8M
readings**, plus ~9K control audit rows and a few hundred alarms. Generates
in well under a minute; `history_days = 365` + `reading_interval = 1 minute`
≈ 25M rows if you want compression numbers that impress.

## How the story hangs together

The trick that makes the demo *coherent* is that all randomness is rolled
**once** into two inspectable tables, then everything derives from them:

- **`sim_weather_days`** — one cloudiness factor per site per day. Drives
  irradiance, which drives inverter power, which drives the meter, which
  drives daily energy, which the storm-advisory alarms annotate. A cloudy
  day is cloudy *everywhere you look*.
- **`sim_outages`** — equipment failure windows. Each one gaps the readings
  (gateways go silent — that's what real bad data looks like), leaves a
  status=2 'Faulted' + quality='offline' marker at onset, raises a
  comms-lost alarm 5 minutes in (debounce), and logs raise/clear alarm
  events. The most recent outage is stretched past "now" so the alarm board
  always has a live incident.

Over-temperature alarms go one better: `03_generate_activity` **scans the
generated readings** for actual threshold crossings — the alarm board and
the temperature chart agree because the alarms came *from* the data.

## What a viewer should notice (the demo pop)

1. **Clipped solar curves** — clear-day power flat-tops at the inverter
   rating because the DC field is oversized (`dc_ac_ratio`). Domain people
   smile; beginners learn why the bell curve has a haircut.
2. **Gaps, then gapfill** — outages cut data mid-stream; query 1 in the
   showcase shows `readings_gapfilled` carrying values through with
   `is_generated` flagging what's interpolation vs measurement.
3. **Audit ≠ queue** — every dispatch request walks queued → accepted →
   active → completed through `submit_control_request`, so history holds
   ~4× the live rows, plus internal requests that exist *only* in history.
4. **Timezone-aware energy** — daily kWh buckets in each site's local day;
   the Arizona site (no DST) exists specifically to make that interesting.
5. **A coherent incident** — pick any alarm and you can find its outage
   window, its data gap, its status flip, and its event log entries.

## Files

| Script | Contents |
|---|---|
| `00_demo_config.sql` | Config table + typed getters + `reset_demo_data()` + `sim_*` tables |
| `01_seed_reference.sql` | Sites (real coords/timezones), fleet, point catalog, value map, alarm definitions |
| `02_generate_readings.sql` | Set-based telemetry generator (solar physics explained in comments) |
| `03_generate_activity.sql` | Control lifecycle simulation + data-derived alarms |
| `04_showcase_queries.sql` | Narrated, read-only tour — run with `psql -f` and scroll |
