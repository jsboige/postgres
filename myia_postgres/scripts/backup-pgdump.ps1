<#
.SYNOPSIS
    PostgreSQL unified_store backup (offsite GDrive + local copy) with poison-guard.

.DESCRIPTION
    Canonical daily backup for the unified conversation store on ai-01.
    Modeled after qdrant_snapshot_backup.ps1 (same guards, same retention pattern).

    Pipeline:
      1. POISON-GUARD: query pg_tables; abort (exit 2) if conversations table is
         missing or has fewer rows than -MinRows.
      2. pg_dump in custom format (-Fc) via docker exec.
      3. Copy to GDrive offsite (-SharedPath) and local disk (-LocalCopyDir).
      4. SIZE-GUARD: if the new dump is < 50% of the largest existing one, skip
         retention and warn.
      5. Retention: 30 daily + 4 weekly Mondays (per destination).

.PARAMETER ContainerName
    Docker container name. Default 'postgres_production'.

.PARAMETER DbUser
    PostgreSQL user. Default 'unified_store'.

.PARAMETER DbName
    PostgreSQL database. Default 'unified_store'.

.PARAMETER MinRows
    Poison-guard floor on conversations table. Default 0 (accept empty on bootstrap).

.PARAMETER LocalCopyDir
    Local backup directory. Default 'D:\postgres-backups'. Pass '' to skip.

.PARAMETER SharedPath
    GDrive offsite root. Default $env:ROOSYNC_SHARED_PATH. Pass '-' to skip offsite.

.NOTES
    Password read from myia_postgres/.env (POSTGRES_PASSWORD). Never printed.
    Sister restore: restore-pgdump.ps1 (TODO).
    Refs: roo-extensions #2553 / EPIC #2191.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ContainerName = 'postgres_production',
    [string]$DbUser        = 'unified_store',
    [string]$DbName        = 'unified_store',
    [string]$MachineId     = '',
    [string]$SharedPath    = '',
    [string]$LocalCopyDir  = 'D:\postgres-backups',
    [int]$MinRows          = 0,
    [string]$LogDir        = ''
)

$ErrorActionPreference = 'Stop'

# ========== RESOLVE INPUTS ==========

if ([string]::IsNullOrWhiteSpace($MachineId)) {
    $MachineId = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLowerInvariant() } else { (hostname).ToLowerInvariant() }
}

# Password: env > fork .env. Never echoed.
$pgPassword = $env:PGPASSWORD
if ([string]::IsNullOrWhiteSpace($pgPassword)) {
    $envFile = Join-Path $PSScriptRoot '..\.env'
    if (Test-Path $envFile) {
        $line = (Get-Content $envFile | Where-Object { $_ -match '^POSTGRES_PASSWORD=' } | Select-Object -First 1)
        if ($line) { $pgPassword = ($line -replace '^POSTGRES_PASSWORD=', '').Trim().Trim('"').Trim("'") }
    }
}
if ([string]::IsNullOrWhiteSpace($pgPassword)) {
    [Console]::Error.WriteLine('ERROR: POSTGRES_PASSWORD not found ($env:PGPASSWORD or .env).')
    exit 1
}

if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $PSScriptRoot '..\backups\logs' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$dateStamp = Get-Date -Format 'yyyyMMdd'
$today     = Get-Date -Format 'yyyy-MM-dd'
$logFile   = Join-Path $LogDir "pgdump-backup-$dateStamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Information $line -InformationAction Continue
}

# Destinations: list of @{ Name; Root } where Root/<date>/ holds the .dump files.
$destinations = @()
if ([string]::IsNullOrWhiteSpace($SharedPath)) { $SharedPath = $env:ROOSYNC_SHARED_PATH }
if ($SharedPath -eq '-') {
    Write-Log 'Offsite leg skipped (-SharedPath -)' 'WARN'
} elseif ([string]::IsNullOrWhiteSpace($SharedPath)) {
    Write-Log 'Offsite leg skipped: $env:ROOSYNC_SHARED_PATH not set and -SharedPath not provided' 'WARN'
} elseif (-not (Test-Path $SharedPath)) {
    Write-Log "Offsite leg skipped: SharedPath does not exist: $SharedPath" 'WARN'
} else {
    $destinations += @{ Name = 'offsite'; Root = "$SharedPath/postgres-backups/$MachineId/$DbName" }
}
if (-not [string]::IsNullOrWhiteSpace($LocalCopyDir)) {
    $destinations += @{ Name = 'local'; Root = "$LocalCopyDir/$MachineId/$DbName" }
}
if ($destinations.Count -eq 0) {
    [Console]::Error.WriteLine('ERROR: no backup destination (offsite skipped and LocalCopyDir empty).')
    exit 1
}

Write-Log "Backup start: machine=$MachineId db=$DbName container=$ContainerName dests=$([string]::Join(',', ($destinations | ForEach-Object { $_.Name })))"

# ========== POISON-GUARD ==========

try {
    $guardOut = docker exec $ContainerName psql -U $DbUser -d $DbName -t -A -c 'SELECT count(*) FROM conversations;' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql exit ${LASTEXITCODE}: $guardOut" }
    $rowCount = [int]($guardOut | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
} catch {
    Write-Log "FATAL: cannot query conversations table: $($_.Exception.Message)" 'ERROR'
    [Console]::Error.WriteLine("Cannot query conversations: $($_.Exception.Message)")
    exit 1
}
Write-Log "Poison-guard: conversations rows=$rowCount (min=$MinRows)"
if ($rowCount -lt $MinRows) {
    Write-Log "POISON-GUARD TRIPPED: rows=$rowCount < MinRows=$MinRows. Aborting." 'ERROR'
    [Console]::Error.WriteLine("POISON-GUARD: conversations has only $rowCount rows (< $MinRows). Refusing to back up a possibly-wiped database.")
    exit 2
}

# ========== IDEMPOTENCY (per-destination) ==========

$missing = @()
$existingTodayPath = $null
foreach ($d in $destinations) {
    $dayDir = "$($d.Root)/$today"
    $ex = @()
    if (Test-Path $dayDir) { $ex = @(Get-ChildItem -Path $dayDir -Filter '*.dump' -File -ErrorAction SilentlyContinue) }
    if ($ex.Count -gt 0) {
        if (-not $existingTodayPath) { $existingTodayPath = $ex[0].FullName }
        Write-Log "$($d.Name) already has today's dump ($($ex[0].Name))"
    } else {
        $missing += $d
    }
}

$newDumpSize = 0L
$sourceFile = $null
$tmp = $null
$dumpLeaf = "$DbName-$dateStamp.dump"

if ($missing.Count -eq 0) {
    Write-Log 'Idempotent: all destinations have today''s dump.'
} elseif ($existingTodayPath) {
    $sourceFile = $existingTodayPath
    $newDumpSize = (Get-Item $sourceFile).Length
    Write-Log "Reusing existing dump for $($missing.Count) missing dest(s): $sourceFile ($newDumpSize bytes)"
} else {
    # No destination has today's: create a fresh pg_dump.
    $tmp = Join-Path $env:TEMP $dumpLeaf
    if ($PSCmdlet.ShouldProcess("${ContainerName}:${DbName}", 'pg_dump -Fc')) {
        try {
            $dumpOut = docker exec $ContainerName pg_dump -U $DbUser -d $DbName -Fc --no-password 2>&1
            if ($LASTEXITCODE -ne 0) { throw "pg_dump exit ${LASTEXITCODE}: $dumpOut" }
            # pg_dump to stdout inside container, redirect to file on host
            $null = docker exec $ContainerName pg_dump -U $DbUser -d $DbName -Fc --no-password 2>$null |
                Set-Content -Path $tmp -AsByteStream -ErrorAction Stop
            # Note: docker exec pipe to host file. Alternative: docker cp after writing inside container.
            # The pipe approach avoids intermediate container filesystem writes.
        } catch {
            # Fallback: dump inside container then docker cp
            Write-Log "Direct pipe failed, trying docker cp fallback: $($_.Exception.Message)" 'WARN'
            $containerPath = "/tmp/$dumpLeaf"
            $null = docker exec $ContainerName pg_dump -U $DbUser -d $DbName -Fc -f $containerPath 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "FATAL: pg_dump failed" 'ERROR'; exit 1 }
            docker cp "${ContainerName}:${containerPath}" $tmp
            if ($LASTEXITCODE -ne 0) { Write-Log "FATAL: docker cp failed" 'ERROR'; exit 1 }
            docker exec $ContainerName rm -f $containerPath
        }

        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) {
            Write-Log 'FATAL: dump file is empty or missing' 'ERROR'; exit 1
        }
        $sourceFile = $tmp
        $newDumpSize = (Get-Item $tmp).Length
        Write-Log "Dump created: size=$newDumpSize bytes"
    } else {
        Write-Log 'WhatIf: would create pg_dump, then distribute to all destinations'
    }
}

# Fan out the source file to every missing destination.
if ($sourceFile) {
    foreach ($d in $missing) {
        $dayDir = "$($d.Root)/$today"
        if ($PSCmdlet.ShouldProcess("$dayDir/$dumpLeaf", "copy dump to $($d.Name)")) {
            if (-not (Test-Path $dayDir)) { New-Item -ItemType Directory -Path $dayDir -Force | Out-Null }
            Copy-Item -Path $sourceFile -Destination "$dayDir/$dumpLeaf" -Force
            Write-Log "Copied to $($d.Name): $dayDir/$dumpLeaf"
        }
    }
}
if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

# ========== RETENTION (per destination), with SIZE-GUARD ==========

foreach ($d in $destinations) {
    $root = $d.Root
    if (-not (Test-Path $root)) { Write-Log "No root yet for $($d.Name) ($root); retention skipped"; continue }

    # SIZE-GUARD: if the new dump is anomalously small vs the biggest existing, skip retention.
    if ($newDumpSize -gt 0) {
        $maxExisting = (Get-ChildItem -Path $root -Recurse -Filter '*.dump' -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Maximum).Maximum
        if ($maxExisting -and $newDumpSize -lt ($maxExisting * 0.5)) {
            Write-Log "SIZE-GUARD ($($d.Name)): new=$newDumpSize < 50% of max=$maxExisting. Skipping retention (keeping all)." 'ERROR'
            continue
        }
    }

    $dayDirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }
    $keep = New-Object System.Collections.Generic.HashSet[string]
    # 30 daily retention (decision Q3 — 30-day backup retention)
    foreach ($x in ($dayDirs | Sort-Object Name -Descending | Select-Object -First 30)) { [void]$keep.Add($x.Name) }
    # + 4 weekly Mondays
    $mondays = $dayDirs | Where-Object {
        try { ([DateTime]::ParseExact($_.Name, 'yyyy-MM-dd', $null)).DayOfWeek -eq [DayOfWeek]::Monday } catch { $false }
    } | Sort-Object Name -Descending | Select-Object -First 4
    foreach ($m in $mondays) { [void]$keep.Add($m.Name) }

    $deleted = 0
    foreach ($x in $dayDirs) {
        if (-not $keep.Contains($x.Name)) {
            if ($PSCmdlet.ShouldProcess($x.FullName, 'Remove old dump dir')) {
                try { Remove-Item -Path $x.FullName -Recurse -Force; $deleted++; Write-Log "Retention ($($d.Name)) deleted: $($x.Name)" }
                catch { Write-Log "WARN: delete failed $($x.Name): $($_.Exception.Message)" 'WARN' }
            } else { Write-Log "WhatIf ($($d.Name)): would delete $($x.Name)" }
        }
    }
    Write-Log "Retention ($($d.Name)) complete: kept=$($keep.Count) deleted=$deleted"
}

Write-Log 'Backup done'
exit 0
