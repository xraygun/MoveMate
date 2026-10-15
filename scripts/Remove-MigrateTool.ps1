<#
  Removes MoveMate from this PC (<drive>\Program Files\MoveMate).
  Started by the tool's "Remove tool from this PC" button from a copy in %TEMP% (it waits for the tool's window to close
  first), or run by hand as admin. NEVER touches C:\Migration (users' files), their profiles, or C:\Migration-Oversized.
  Users still waiting for their first sign-in (handoff entries): keeps only handoff\ + scripts\Complete-MigrationHandoff.ps1
  (+ its log) and leaves a 'remove-when-done' marker; the mover deletes the rest when the last of them has signed in.
  Usage: Remove-MigrateTool.ps1 [-WaitPid <pid>]
#>
param([int]$WaitPid)
$ErrorActionPreference = 'SilentlyContinue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit
}
if ($WaitPid) { try { (Get-Process -Id $WaitPid).WaitForExit(30000) | Out-Null } catch {} ; Start-Sleep 2 }

$cs = Join-Path $env:ProgramData 'KitMigrate'
$cableLeft = (Test-Path "$cs\cable.json") -or (Test-Path "$cs\pair.json")
if (-not $cableLeft) { foreach ($t in 'MigrateUserFiles-CableCleanup') { Unregister-ScheduledTask -TaskName $t -Confirm:$false } }

foreach ($rel in @('Program Files\MoveMate')) {
    $tool = Join-Path $env:SystemDrive $rel
    if (-not (Test-Path $tool)) { continue }
    if (-not $cableLeft) { Remove-Item (Join-Path $tool 'cable') -Recurse -Force }
    $pending = @(Get-ChildItem (Join-Path $tool 'handoff') -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($pending.Count) {
        # Keep only what the waiting users need; this folder's own task keeps running the mover
        Get-ChildItem $tool -Force | Where-Object { $_.Name -notin 'handoff', 'scripts', 'logs', 'cable' } | Remove-Item -Recurse -Force
        Get-ChildItem (Join-Path $tool 'scripts') -Force | Where-Object { $_.Name -ne 'Complete-MigrationHandoff.ps1' } | Remove-Item -Recurse -Force
        Get-ChildItem (Join-Path $tool 'logs') -Force | Where-Object { $_.Name -ne 'handoff.log' } | Remove-Item -Recurse -Force
        Set-Content (Join-Path $tool 'remove-when-done') "Remove tool requested $(Get-Date -Format s); waiting for: $($pending.BaseName -join ', ')" -Encoding UTF8
    } else {
        # No one waiting: remove the task that runs this folder's mover, then the folder
        Get-ScheduledTask | Where-Object { "$($_.Actions.Arguments)" -like "*$tool*" } | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false }
        if (-not $cableLeft) { Remove-Item -LiteralPath $tool -Recurse -Force }
        else { Get-ChildItem $tool -Force | Where-Object { $_.Name -ne 'cable' } | Remove-Item -Recurse -Force }   # cable clean-up still needs its folder
    }
    $parent = Split-Path $tool
    if ((Test-Path $parent) -and -not @(Get-ChildItem $parent -Force).Count) { Remove-Item $parent -Force }   # empty parent folder
}
Remove-Item -LiteralPath $PSCommandPath -Force   # this temp copy
