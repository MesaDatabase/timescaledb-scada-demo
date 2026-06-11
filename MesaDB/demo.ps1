# =============================================================================
# demo.ps1 -- the one button, Windows edition.
#
#   .\demo.ps1            # everything: start DB, schema, data, policies, tour
#   .\demo.ps1 up         # just start the database container
#   .\demo.ps1 run        # just (re)run all SQL against a running container
#   .\demo.ps1 psql       # interactive psql shell inside the container
#   .\demo.ps1 status     # policy/job/compression health check
#   .\demo.ps1 monitor    # run the 01_monitoring diagnostic suite
#   .\demo.ps1 down       # stop the container (data volume kept)
#   .\demo.ps1 clean      # stop AND delete all data -- full reset
#
# Requires: Docker Desktop. Nothing else -- all SQL runs via the psql inside
# the container against the repo mounted at /repo.
# If scripts are blocked, run once:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# =============================================================================
param([string]$Command = "all")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$Scripts = @(
  "02_schema/00_init.sql",
  "02_schema/01_types.sql",
  "02_schema/02_reference_tables.sql",
  "02_schema/03_hypertables.sql",
  "02_schema/04_alarm_tables.sql",
  "02_schema/05_functions_config.sql",
  "02_schema/06_functions_analytics.sql",
  "03_data_generation/00_demo_config.sql",
  "03_data_generation/01_seed_reference.sql",
  "03_data_generation/02_generate_readings.sql",
  "03_data_generation/03_generate_activity.sql",
  "04_policies/00_compression_policies.sql",
  "04_policies/01_continuous_aggregates.sql",
  "04_policies/02_retention.sql",
  "04_policies/03_policy_status.sql",
  "03_data_generation/04_showcase_queries.sql"   # the grand finale
)

$Monitoring = @(
  "01_monitoring/00_database_info.sql",
  "01_monitoring/01_active_sessions.sql",
  "01_monitoring/02_blocking_locks.sql",
  "01_monitoring/03_top_queries_pg_stat_statements.sql",
  "01_monitoring/04_table_and_hypertable_sizes.sql",
  "01_monitoring/05_hypertable_chunk_inventory.sql",
  "01_monitoring/06_bgw_job_stats.sql",
  "01_monitoring/07_compression_overview.sql"
)

function Banner($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Invoke-Sql($file) {
    Banner "Running $file"
    docker compose exec -T db psql -U scada -d scada_demo -v ON_ERROR_STOP=1 -f "/repo/$file"
    if ($LASTEXITCODE -ne 0) { throw "psql failed on $file" }
}

function Wait-ForDb {
    Banner "Waiting for TimescaleDB to accept connections..."
    foreach ($i in 1..60) {
        docker compose exec -T db pg_isready -U scada -d scada_demo *> $null
        if ($LASTEXITCODE -eq 0) { Banner "Database is ready."; return }
        Start-Sleep -Seconds 2
    }
    throw "Database did not become ready. Check: docker compose logs db"
}

function Start-Db {
    Banner "Starting TimescaleDB container (first run downloads the image)..."
    docker compose up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
    Wait-ForDb
}

function Run-All {
    foreach ($f in $Scripts) { Invoke-Sql $f }
    Banner "Build complete."
    Write-Host "Connect from your own tools:  psql -h localhost -p 5439 -U scada -d scada_demo"
    Write-Host "Interactive shell:            .\demo.ps1 psql"
    Write-Host "Diagnostics suite:            .\demo.ps1 monitor"
}

switch ($Command) {
    "all"     { Start-Db; Run-All }
    "up"      { Start-Db }
    "run"     { Run-All }
    "psql"    { docker compose exec db psql -U scada -d scada_demo }
    "status"  { Invoke-Sql "04_policies/03_policy_status.sql" }
    "monitor" { foreach ($f in $Monitoring) { Invoke-Sql $f } }
    "down"    { Banner "Stopping (data kept)..."; docker compose down }
    "clean"   { Banner "Stopping and DELETING all data..."; docker compose down -v }
    default   { Get-Content $PSCommandPath | Select-String '^#   \.\\demo' | ForEach-Object { $_.Line.TrimStart('# ') } }
}
