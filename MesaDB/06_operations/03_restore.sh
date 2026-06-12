#!/usr/bin/env bash
# =============================================================================
# 03_restore.sh -- restore a 02_backup.sh dump into a NEW database, the
# TimescaleDB way.
#
#   ./06_operations/03_restore.sh backups/scada_demo_20260611.dump
#   ./06_operations/03_restore.sh backups/x.dump scada_restored
#
# Restores side-by-side (default target: scada_restored) so the original is
# never touched -- verify, then rename/repoint when satisfied.
#
# THE CRITICAL SEQUENCE (this ordering is the whole trick):
#   1. CREATE DATABASE
#   2. CREATE EXTENSION timescaledb  (same version as the dump!)
#   3. SELECT timescaledb_pre_restore();   -- pauses background workers &
#                                             catalog protection
#   4. pg_restore
#   5. SELECT timescaledb_post_restore();  -- re-enables everything
# Skip 3/5 and the restore fails or corrupts the TimescaleDB catalog.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

DUMP="${1:?Usage: 03_restore.sh <dumpfile> [target_db]}"
TARGET="${2:-scada_restored}"
PSQL="docker compose exec -T db psql -U scada -v ON_ERROR_STOP=1"

[[ -f "$DUMP" ]] || { echo "Dump file not found: $DUMP" >&2; exit 1; }

echo "==> Creating target database: $TARGET"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS ${TARGET};"
$PSQL -d postgres -c "CREATE DATABASE ${TARGET} OWNER scada;"

echo "==> Installing TimescaleDB extension in $TARGET"
$PSQL -d "$TARGET" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

echo "==> timescaledb_pre_restore()"
$PSQL -d "$TARGET" -c "SELECT timescaledb_pre_restore();"

echo "==> pg_restore (this is the long part)"
docker compose exec -T db pg_restore -U scada -d "$TARGET" \
  --no-owner --exit-on-error < "$DUMP"

echo "==> timescaledb_post_restore()"
$PSQL -d "$TARGET" -c "SELECT timescaledb_post_restore();"

echo "==> Sanity checks"
$PSQL -d "$TARGET" -c "
  SELECT 'hypertables' AS check, count(*)::text AS value
    FROM timescaledb_information.hypertables
  UNION ALL
  SELECT 'readings rows', count(*)::text FROM scada.point_readings
  UNION ALL
  SELECT 'background jobs', count(*)::text
    FROM timescaledb_information.jobs WHERE job_id >= 1000;"

echo
echo "Restored into '${TARGET}'. Inspect with:"
echo "  docker compose exec db psql -U scada -d ${TARGET}"
