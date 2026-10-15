<#
  Handoff on THIS PC: files waiting in C:\Migration\<user> move into that user's profile when they next sign in
  (Complete-MigrationHandoff.ps1, SYSTEM task at sign-in). Any number of users. MoveMate sets this up by itself;
  use this by hand to add users, list them, or cancel. Usage (admin):
    Set-MigrationHandoff.ps1 -User jsmith,adoe      add (folder = user name)
    Set-MigrationHandoff.ps1 -List                   show pending
    Set-MigrationHandoff.ps1 -Remove [-User jsmith]  cancel one / all (files stay in C:\Migration)
#>
param([string[]]$User, [switch]$Remove, [switch]$List)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MigrateCore.ps1')
$root = $env:SystemDrive
$dir = Join-Path $root "$MigToolRel\handoff"
if ($List) {
    $e = @(Get-MigrationHandoff $root)
    if (-not $e.Count) { 'No handoffs pending.' } else { $e | Select-Object User, Folder, SourcePc, Created | Format-Table -AutoSize | Out-String }
    return
}
if ($Remove) {
    $targets = if ($User) { $User | ForEach-Object { Join-Path $dir "$(Get-HandoffUser $_).json" } } else { @(Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object FullName) }
    foreach ($t in $targets) { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force; "Cancelled: $(Split-Path $t -Leaf)" } }
    if (-not @(Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue).Count) { Unregister-ScheduledTask -TaskName $HandoffTask -Confirm:$false -ErrorAction SilentlyContinue; 'Task removed (nothing pending).' }
    return
}
foreach ($u in $User) {
    $n = Get-HandoffUser $u
    New-Item -ItemType Directory -Force (Join-Path $root "Migration\$n") | Out-Null
    Add-MigrationHandoff -DstRoot $root -User $n -Folder $n
    "Handoff set: C:\Migration\$n moves into $n's profile at their next sign-in."
}
