# Runs as SYSTEM at start-up while a direct cable link was left set up (task MigrateUserFiles-CableCleanup, from Register-CableCleanup).
# Undoes the temporary pairing login, the sharing/remote-admin change and the cable address, then removes itself.
# Lives in <drive>\Program Files\MoveMate\cable next to MigrateCore.ps1. Log: logs\cable-cleanup.log
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'MigrateCore.ps1')
$log = Join-Path $PSScriptRoot 'logs\cable-cleanup.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function Log($m) { if ($m) { "$(Get-Date -Format s)  $m" | Out-File $log -Append -Encoding utf8 } }
Log 'Start-up cleanup of a direct cable link.'
Log (Stop-PairingHost)
Log (Restore-CableLink)
Unregister-CableCleanup
Log 'Done - cleanup task removed.'
