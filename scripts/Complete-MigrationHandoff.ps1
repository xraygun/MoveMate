# Handoff mover. Runs as SYSTEM at every sign-in while entries are pending (scheduled task from Add-MigrationHandoff).
# Lives in the tool folder's scripts\ (admin-only). Entries: handoff\<user>.json. When the signed-in user has an entry, moves
# C:\Migration\<folder> into their profile (files the profile already has newer copies of are kept), removes that entry, and
# removes its task when no entries are left. Everyone else's sign-in is ignored. Log: logs\handoff.log in the tool folder.
$ErrorActionPreference = 'SilentlyContinue'
# Data lives in the tool folder; this script is in its scripts\ subfolder (older installs: the folder itself).
$base = if ((Split-Path $PSScriptRoot -Leaf) -eq 'scripts') { Split-Path $PSScriptRoot } else { $PSScriptRoot }
$dir = Join-Path $base 'handoff'
$log = Join-Path $base 'logs\handoff.log'
# Our task = the one that runs THIS file (an older install in another folder may have its own task and entries).
$task = (Get-ScheduledTask | Where-Object { "$($_.Actions.Arguments)" -like "*$PSCommandPath*" } | Select-Object -First 1).TaskName
if (-not $task) { $task = 'MigrateUserFiles-Handoff' }
New-Item -ItemType Directory -Force (Split-Path $log), $dir | Out-Null
function Log($m) { "$(Get-Date -Format s)  $m" | Out-File $log -Append -Encoding utf8 }
function Test-Done {
    if (@(Get-ChildItem $dir -Filter '*.json').Count) { return }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false; Log 'No handoffs left - task removed.'
    # The user-side question task that runs this folder's Ask-MigrationChoice.ps1, if any
    Get-ScheduledTask | Where-Object { "$($_.Actions.Arguments)" -like "*$(Join-Path $PSScriptRoot 'Ask-MigrationChoice.ps1')*" } |
        ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false }
    # "Remove tool" was clicked while users were still waiting: now that they're done, remove what's left of the tool.
    if (Test-Path (Join-Path $base 'remove-when-done')) {
        $cs = Join-Path $env:ProgramData 'KitMigrate'
        if (-not (Test-Path "$cs\cable.json") -and -not (Test-Path "$cs\pair.json")) {
            foreach ($t in 'MigrateUserFiles-CableCleanup') { Unregister-ScheduledTask -TaskName $t -Confirm:$false }
        }
        Remove-Item -LiteralPath $base -Recurse -Force   # this script has already been read into memory
    }
    exit 0
}

# Older single-user format (handoff.json) -> one entry
$old = Join-Path $base 'handoff.json'
if (Test-Path $old) {
    $o = Get-Content $old -Raw | ConvertFrom-Json
    if ($o.User) { @{ User = $o.User; Folder = $o.User } | ConvertTo-Json | Set-Content (Join-Path $dir "$($o.User).json") -Encoding UTF8 }
    Remove-Item $old -Force
}
Test-Done

# Who signed in? (console user; give the logon a moment to settle)
$who = $null
for ($i = 0; $i -lt 30 -and -not $who; $i++) { $who = (Get-CimInstance Win32_ComputerSystem).UserName; if (-not $who) { Start-Sleep 2 } }
if (-not $who) { Log 'Could not tell who signed in - will retry next sign-in.'; exit 0 }
$name = ($who -split '\\')[-1]
$entryFile = Join-Path $dir "$name.json"
if (-not (Test-Path $entryFile)) { Log "Sign-in by '$who' - no files waiting for them."; exit 0 }
$h = Get-Content $entryFile -Raw | ConvertFrom-Json
if ("$($h.Folder)" -notmatch '^[A-Za-z0-9._ -]{1,64}$' -or "$($h.Folder)" -match '\.\.') { Log "Bad folder in $entryFile - skipped."; exit 0 }

$sid = (New-Object Security.Principal.NTAccount $who).Translate([Security.Principal.SecurityIdentifier]).Value
$profilePath = $null
for ($i = 0; $i -lt 60 -and -not $profilePath; $i++) {
    $profilePath = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
    if (-not $profilePath -or -not (Test-Path (Join-Path $profilePath 'Desktop'))) { $profilePath = $null; Start-Sleep 2 }
}
if (-not $profilePath) { Log "Profile for $who not ready - will retry next sign-in."; exit 0 }

$mig = Join-Path $env:SystemDrive 'Migration'
$src = Join-Path $mig $h.Folder
# Never follow a junction/symlink planted in place of the folder
foreach ($p in $mig, $src) { if ((Test-Path $p) -and ((Get-Item $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Log "$p is a link - refusing to move."; exit 0 } }
# "Ask" handoffs: wait (up to 15 min) for the user's answer from the question window (Ask-MigrationChoice.ps1).
# 'Same' = same locations; 'Backup' = Desktop\<BackupName> (the Migration Report still goes on the desktop itself).
$dest = $profilePath
if ($h.Ask -and (Test-Path $src)) {
    $choiceFile = Join-Path $env:SystemDrive "ProgramData\KitMigrate\choices\$name.txt"
    $choice = $null
    for ($i = 0; $i -lt 300 -and -not $choice; $i++) {
        if (Test-Path -LiteralPath $choiceFile) { $choice = "$((Get-Content -LiteralPath $choiceFile -TotalCount 1))".Trim() }
        if (-not $choice) { Start-Sleep 3 }
    }
    if ($choice -notin 'Same', 'Backup') { Log "No answer from $name (window closed or ignored) - files stay in $src; asking again next sign-in."; exit 0 }
    Remove-Item -LiteralPath $choiceFile -Force
    if ($choice -eq 'Backup') {
        $bn = ("$($h.BackupName)" -replace '[\\/:*?"<>|]', '').Trim(); if (-not $bn) { $bn = 'Migrated from old PC' }
        $dest = Join-Path $profilePath "Desktop\$bn"
        foreach ($r in @(Get-ChildItem (Join-Path $src 'Desktop') -Filter 'Migration Report*.txt' -File -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $r.FullName -Destination (Join-Path $profilePath 'Desktop') -Force   # receipt stays on the desktop
        }
    }
    Log "$name chose: $choice"
}
if (Test-Path $src) {
    Log "Moving $src -> $dest (for $who)"
    $rlog = Join-Path (Split-Path $log) "handoff-$name-$(Get-Date -Format yyyyMMdd_HHmmss).log"
    New-Item -ItemType Directory -Force $dest | Out-Null
    & robocopy.exe $src $dest /E /MOVE /XJ /XO /R:1 /W:1 /NP /NDL "/UNILOG:$rlog" | Out-Null
    $code = $LASTEXITCODE
    Log "robocopy exit $code (details: $rlog)"
    if ($code -ge 8) { Log 'Some files failed - left in place; will retry at their next sign-in.'; exit 0 }
    $left = @(Get-ChildItem $src -Recurse -File -Force)
    if ($left.Count) { Log "$($left.Count) file(s) kept in $src (their profile already had newer copies)." } else { Remove-Item $src -Recurse -Force }
} else { Log "$src not found (deleted?) - nothing to move." }
Remove-Item $entryFile -Force
Log "Handoff for $name complete."
Test-Done
