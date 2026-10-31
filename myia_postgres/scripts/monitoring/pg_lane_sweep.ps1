<#
.SYNOPSIS
    Postgres lane surveillance sweep (12h cadence) — local probes only, read-only.

.DESCRIPTION
    One-shot probe bundle for the myia-ai-01:postgres surveillance lane. Covers:
    container health, DB vitals (row counts, per-machine writers, ingest
    staleness, size, ssl, connections), today's backup state on BOTH legs
    (GDrive offsite + USB F: local), schtask last result, disk floors (C: hosts
    the Docker VHDX), and TCP reachability (localhost:5433 + pg.myia.io:5432).

    Non-goals (agent-side, see .claude/skills/pg-sweep): threshold judgement,
    self-heal re-run of the backup, inbox triage, dashboard [DONE], cron re-arm.

.NOTES
    Read-only; never echoes the DB password (docker exec uses trust inside the
    container). Probes modeled on qdrant_lane_sweep.ps1 (proven since 2026-08-17).
#>
$ErrorActionPreference = 'SilentlyContinue'

Write-Output '=== 1. CONTAINER ==='
docker ps -a --filter 'name=postgres_production' --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'

Write-Output '=== 2. DB VITALS ==='
$sql = @"
SELECT 'conversations='||count(*) FROM conversations
UNION ALL SELECT 'messages='||count(*) FROM messages
UNION ALL SELECT 'ingest_staleness_h='||round(extract(epoch from (now()-max(ingested_at)))/3600.0,1) FROM conversations
UNION ALL SELECT 'last_ingest_utc='||coalesce(max(ingested_at)::text,'none') FROM conversations
UNION ALL SELECT 'db_size='||pg_size_pretty(pg_database_size('unified_store'))
UNION ALL SELECT 'ssl='||current_setting('ssl')
UNION ALL SELECT 'active_connections='||count(*) FROM pg_stat_activity WHERE datname='unified_store'
"@
docker exec postgres_production psql -U unified_store -d unified_store -t -A -c $sql 2>&1

Write-Output '--- rows by machine (top)'
docker exec postgres_production psql -U unified_store -d unified_store -t -A -c "SELECT machine_id||'='||count(*) FROM conversations GROUP BY machine_id ORDER BY count(*) DESC;" 2>&1

Write-Output '=== 3. BACKUP DU JOUR (GDrive offsite + USB F: local) ==='
$stamp = Get-Date -Format 'yyyyMMdd'
$today = Get-Date -Format 'yyyy-MM-dd'
$log   = "D:\postgres\myia_postgres\backups\logs\pgdump-backup-$stamp.log"
if (Test-Path $log) {
    Write-Output "log($stamp) tail:"
    Get-Content $log -Tail 3 | ForEach-Object { "  $_" }
} else { Write-Output "LOG $stamp ABSENT (normal avant ~02:40, le schtask est a 02:33/03:33 selon heure d'ete)" }

foreach ($leg in @(
    @{ name = 'offsite_GDrive'; path = "G:\Mon Drive\Backups-Cloud\postgres-backups\myia-ai-01\unified_store" },
    @{ name = 'local_USB_F'  ; path = 'F:\Backups\postgres-backups\myia-ai-01\unified_store' }
)) {
    $dump = Join-Path $leg.path "$today\unified_store-$stamp.dump"
    if (Test-Path $dump) {
        $mb = [math]::Round((Get-Item $dump).Length/1MB,1)
        Write-Output "dump_$($leg.name)=$today OK (${mb} MB)"
    } else { Write-Output "dump_$($leg.name)=$today ABSENT ($($leg.path))" }
}
Write-Output '--- schtask'
schtasks /query /tn 'Postgres-Dump-Daily' /v /fo LIST 2>&1 | Select-String 'Derni.re ex.cution|R.sultat|Prochaine ex.cution|Statut'

Write-Output '=== 4. DISQUES (C: heberge le VHDX docker_data) ==='
Get-Volume | Where-Object { $_.DriveLetter -in 'C','D','F' } |
    ForEach-Object { "$($_.DriveLetter): free=$([math]::Round($_.SizeRemaining/1GB))GB / $([math]::Round($_.Size/1GB))GB" }

Write-Output '=== 5. ENDPOINT TCP ==='
foreach ($t in @(@{h='localhost';p=5433}, @{h='pg.myia.io';p=5432})) {
    $c = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $c.ConnectAsync($t.h, $t.p)
        if ($task.Wait(5000) -and $c.Connected) { Write-Output "$($t.h):$($t.p) -> OPEN" }
        else { Write-Output "$($t.h):$($t.p) -> CLOSED/TIMEOUT" }
    } catch { Write-Output "$($t.h):$($t.p) -> FAIL ($($_.Exception.InnerException.Message))" }
    finally { $c.Dispose() }
}
