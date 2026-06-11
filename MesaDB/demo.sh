#!/usr/bin/env bash
# =============================================================================
# demo.sh -- the one button.
#
#   ./demo.sh            # everything: start DB, build schema, generate data,
#                        #   apply policies, run the showcase tour
#   ./demo.sh up         # just start (or restart) the database container
#   ./demo.sh run        # just (re)run all SQL against a running container
#   ./demo.sh psql       # open an interactive psql shell inside the container
#   ./demo.sh status     # policy/job/compression health check
#   ./demo.sh monitor    # run the 01_monitoring diagnostic suite
#   ./demo.sh down       # stop the container (data volume kept)
#   ./demo.sh clean      # stop AND delete all data -- full reset
#
# Requires: Docker Desktop (or docker engine + compose plugin). Nothing else.
# All SQL runs via the psql bundled INSIDE the container against the repo
# mounted read-only at /repo -- the host machine needs no database tooling.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE="docker compose"
PSQL="$COMPOSE exec -T db psql -U scada -d scada_demo -v ON_ERROR_STOP=1"

# The whole build, in order. Add a file to the repo, add a line here.
SCRIPTS=(
  02_schema/00_init.sql
  02_schema/01_types.sql
  02_schema/02_reference_tables.sql
  02_schema/03_hypertables.sql
  02_schema/04_alarm_tables.sql
  02_schema/05_functions_config.sql
  02_schema/06_functions_analytics.sql
  03_data_generation/00_demo_config.sql
  03_data_generation/01_seed_reference.sql
  03_data_generation/02_generate_readings.sql
  03_data_generation/03_generate_activity.sql
  04_policies/00_compression_policies.sql
  04_policies/01_continuous_aggregates.sql
  04_policies/02_retention.sql
  04_policies/03_policy_status.sql
  03_data_generation/04_showcase_queries.sql   # the grand finale
)

MONITORING=(
  01_monitoring/00_database_info.sql
  01_monitoring/01_active_sessions.sql
  01_monitoring/02_blocking_locks.sql
  01_monitoring/03_top_queries_pg_stat_statements.sql
  01_monitoring/04_table_and_hypertable_sizes.sql
  01_monitoring/05_hypertable_chunk_inventory.sql
  01_monitoring/06_bgw_job_stats.sql
  01_monitoring/07_compression_overview.sql
)

banner() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

wait_for_db() {
  banner "Waiting for TimescaleDB to accept connections..."
  for _ in $(seq 1 60); do
    if $COMPOSE exec -T db pg_isready -U scada -d scada_demo >/dev/null 2>&1; then
      banner "Database is ready."
      return 0
    fi
    sleep 2
  done
  echo "Database did not become ready in time. Check: docker compose logs db" >&2
  exit 1
}

cmd_up() {
  banner "Starting TimescaleDB container (first run downloads the image)..."
  $COMPOSE up -d
  wait_for_db
}

cmd_run() {
  for f in "${SCRIPTS[@]}"; do
    banner "Running $f"
    $PSQL -f "/repo/$f"
  done
  banner "Build complete."
  echo "Connect from your own tools:  psql -h localhost -p 5439 -U scada -d scada_demo"
  echo "Interactive shell:            ./demo.sh psql"
  echo "Diagnostics suite:            ./demo.sh monitor"
}

case "${1:-all}" in
  all)     cmd_up; cmd_run ;;
  up)      cmd_up ;;
  run)     cmd_run ;;
  psql)    $COMPOSE exec db psql -U scada -d scada_demo ;;
  status)  $PSQL -f /repo/04_policies/03_policy_status.sql ;;
  monitor) for f in "${MONITORING[@]}"; do banner "Running $f"; $PSQL -f "/repo/$f"; done ;;
  down)    banner "Stopping (data kept)..."; $COMPOSE down ;;
  clean)   banner "Stopping and DELETING all data..."; $COMPOSE down -v ;;
  *)       grep -E '^#   \./demo' "$0" | sed 's/^# //' ;;
esac
