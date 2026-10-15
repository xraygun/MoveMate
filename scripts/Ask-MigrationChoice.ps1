# Runs as the signed-in USER at sign-in (task MigrateUserFiles-Ask) while a handoff with "ask" is waiting for them.
# Shows the IT-editable question with two buttons and writes the answer ('Same' or 'Backup') to
# C:\ProgramData\KitMigrate\choices\<user>.txt; the SYSTEM mover (Complete-MigrationHandoff.ps1) waits for it and moves
# the files. Closing the window without choosing = ask again at the next sign-in. Nothing here moves files itself.
$ErrorActionPreference = 'SilentlyContinue'
$base = if ((Split-Path $PSScriptRoot -Leaf) -eq 'scripts') { Split-Path $PSScriptRoot } else { $PSScriptRoot }
$entryFile = Join-Path $base "handoff\$env:USERNAME.json"
if (-not (Test-Path -LiteralPath $entryFile)) { exit 0 }   # nothing waiting for this user
$h = Get-Content -LiteralPath $entryFile -Raw | ConvertFrom-Json
if (-not $h.Ask) { exit 0 }
$choiceDir = Join-Path $env:SystemDrive 'ProgramData\KitMigrate\choices'
$choiceFile = Join-Path $choiceDir "$env:USERNAME.txt"
if (Test-Path -LiteralPath $choiceFile) { exit 0 }         # already answered

$folder = if ($h.BackupName) { "$($h.BackupName)" } else { 'Migrated from old PC' }
$msg = if ($h.Message) { "$($h.Message)" } else { "Your files have been copied from your old computer. Where would you like them?" }
$msg = $msg.Replace('{OldPC}', $(if ($h.SourcePc) { "$($h.SourcePc)" } else { 'old computer' })).Replace('{Folder}', $folder).Replace('{User}', $env:USERNAME)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Start-Sleep 5   # let the desktop finish loading so the window isn't hidden behind it
$f = New-Object Windows.Forms.Form -Property @{
    Text = 'Files from your old computer'; ClientSize = (New-Object Drawing.Size 560, 300); StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; TopMost = $true; Font = New-Object Drawing.Font('Segoe UI', 11)
}
$lbl = New-Object Windows.Forms.Label -Property @{ Text = $msg; Location = (New-Object Drawing.Point 20, 18); Size = (New-Object Drawing.Size 520, 170) }
$b1 = New-Object Windows.Forms.Button -Property @{ Text = 'Place files in same locations'; Location = (New-Object Drawing.Point 20, 200); Size = (New-Object Drawing.Size 255, 64); Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold) }
$b2 = New-Object Windows.Forms.Button -Property @{ Text = "Place files in migration folder on my desktop"; Location = (New-Object Drawing.Point 285, 200); Size = (New-Object Drawing.Size 255, 64); Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold) }
$hint = New-Object Windows.Forms.Label -Property @{ Text = "Not sure? Close this window and you'll be asked again next time you sign in."; Location = (New-Object Drawing.Point 20, 272); Size = (New-Object Drawing.Size 520, 22); ForeColor = [Drawing.Color]::DimGray; Font = New-Object Drawing.Font('Segoe UI', 9) }
$f.Controls.AddRange(@($lbl, $b1, $b2, $hint))
$script:answer = $null
$b1.Add_Click({ $script:answer = 'Same'; $f.Close() })
$b2.Add_Click({ $script:answer = 'Backup'; $f.Close() })
$f.Add_Shown({ $f.Activate() })
[void]$f.ShowDialog()
if (-not $script:answer) { exit 0 }

New-Item -ItemType Directory -Force $choiceDir | Out-Null
Set-Content -LiteralPath $choiceFile -Value $script:answer -Encoding ASCII
$where = if ($script:answer -eq 'Same') { 'into the same folders as on your old computer' } else { "into the folder '$folder' on your desktop" }
[void][Windows.Forms.MessageBox]::Show("Thanks! Your files are being moved $where now. This can take a few minutes; a 'Migration Report' file on your desktop lists everything.", 'Files from your old computer', 'OK', 'Information')
