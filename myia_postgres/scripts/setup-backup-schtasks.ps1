<#
.SYNOPSIS
    Register the Postgres-Dump-Daily scheduled task.

.DESCRIPTION
    Must be run as Administrator. Creates a daily task at 03:33 that runs
    backup-pgdump.ps1 to dump the unified_store to GDrive offsite.

    Run from an elevated PowerShell:
      pwsh -File D:\postgres\myia_postgres\scripts\setup-backup-schtasks.ps1
#>
$ErrorActionPreference = 'Stop'
$debugLog = 'C:\Temp\schtask-setup-debug.log'

function Write-DebugLog([string]$msg) {
    Add-Content -Path $debugLog -Value "[$(Get-Date -Format 'HH:mm:ss')] $msg" -Encoding utf8
}

Write-DebugLog "Script started. IsAdmin: $([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))"

try {
$taskName = 'Postgres-Dump-Daily'
$script   = 'D:\postgres\myia_postgres\scripts\backup-pgdump.ps1'
$shared   = 'G:\Mon Drive\Backups-Cloud'

# Unregister if exists (idempotent)
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Unregistered existing task: $taskName"
}

$argString = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -LocalCopyDir `"`" -SharedPath `"$shared`""
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $argString
$trigger = New-ScheduledTaskTrigger -Daily -At '03:33'
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# Run as the logged-in user, NOT SYSTEM: the GDrive mount (G:) is per-user —
# under SYSTEM the offsite path does not exist and the backup silently degrades
# (incident 2026-06-12 03:33). Same principal as Qdrant-Snapshot-Daily (Interactive).
$user = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Daily pg_dump backup of unified_store (ai-01) to GDrive offsite'

Write-Host "Registered: $taskName (daily 03:33, $user, Interactive)"
Write-DebugLog "SUCCESS: $taskName registered"
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-DebugLog "ERROR: $($_.Exception.Message)"
    Write-DebugLog "StackTrace: $($_.ScriptStackTrace)"
}

# Keep window open for 3 seconds so user can see the result
Start-Sleep -Seconds 3
