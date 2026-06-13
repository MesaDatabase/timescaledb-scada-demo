#!/usr/bin/env bash
# =============================================================================
# 02_backup.sh -- logical backup of the demo database.
#
#   ./06_operations/02_backup.sh                 # -> backups/scada_demo_<ts>.dump
#   ./06_operations/02_backup.sh mylabel         # -> backups/mylabel.dump
#
# Produces:
#   * a pg_dump custom-format (-Fc) dump of scada_demo
#   * a globals file (roles) via pg_dumpall --globals-only, because role
#     definitions live at the cluster level and pg_dump does NOT include them
#
# TimescaleDB notes (the part interviews ask about):
#   * pg_dump works on TimescaleDB, but restore REQUIRES the pre/post hooks
#     (timescaledb_pre_restore/post_restore) -- 03_restore.sh handles it.
#   * The restore target must run the SAME TimescaleDB version the dump came
#     from (upgrade after restoring, not during).
#   * Logical dumps are fine at demo scale. At production scale, physical
#     backups (pgBackRest / WAL archiving / snapshots) are the real answer --
#     see 04_upgrade_and_dr_runbook.md.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root, where docker-compose.yml lives

LABEL="${1:-scada_demo_$(date +%Y%m%d_%H%M%S)}"
OUTDIR="backups"
mkdir -p "$OUTDIR"

echo "==> Recording versions (restore target must match TimescaleDB version)"
docker compose exec -T db psql -U scada -d scada_demo -At \
  -c "SELECT 'postgres ' || version();" \
  -c "SELECT 'timescaledb ' || extversion FROM pg_extension WHERE extname='timescaledb';" \
  | tee "$OUTDIR/${LABEL}.versions.txt"

echo "==> Dumping database scada_demo (custom format)"
docker compose exec -T db pg_dump -U scada -d scada_demo -Fc \
  > "$OUTDIR/${LABEL}.dump"

echo "==> Dumping cluster globals (roles)"
docker compose exec -T db pg_dumpall -U scada --globals-only \
  > "$OUTDIR/${LABEL}.globals.sql"

echo "==> Done:"
ls -lh "$OUTDIR/${LABEL}".*
echo
echo "Restore with:  ./06_operations/03_restore.sh $OUTDIR/${LABEL}.dump [target_db_name]"
