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

$taskName = 'Postgres-Dump-Daily'
$script   = 'D:\postgres\myia_postgres\scripts\backup-pgdump.ps1'
$shared   = 'G:\Mon Drive\Backups-Cloud'

# Unregister if exists (idempotent)
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Unregistered existing task: $taskName"
}

$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $script,
    '-LocalCopyDir', '""',
    '-SharedPath', "`"$shared`""
)
$trigger = New-ScheduledTaskTrigger -Daily -At '03:33'
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Daily pg_dump backup of unified_store (ai-01) to GDrive offsite'

Write-Host "Registered: $taskName (daily 03:33, SYSTEM, Highest)"
