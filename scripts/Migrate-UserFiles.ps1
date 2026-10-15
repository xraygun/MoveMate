<#
  MoveMate (Migrate-UserFiles.ps1) - copy user profile folders from an old PC to a new PC (robocopy, nothing installed).
  Run on EITHER PC from any flash drive (double-click "MoveMate.cmd"). Two choices at the top:
    How:        Network (same network/domain) | Direct cable (one Ethernet cable between the PCs) | External drive |
                Server offload (upload to a share, optionally encrypted; -KeyFile = open a "Restore <OLDPC>" key to download)
    This PC is: the OLD PC (send)             | the NEW PC (receive)
  Network: \\PC\C$ works for domain admins (Connect... -> admin login). Otherwise click "Allow access" on the OTHER PC
  (shows a 4-character code) and Connect... -> code here. A PC's IP address works as its name.
  Direct cable: click "Start cable link" on both PCs (temporary addresses 10.99.99.1/.2, sharing, temporary login with a
  fixed password when the PC is on no other network) - they find and connect to each other by themselves.
  Everything is undone by End cable link / closing the window, or at the next boot (start-up task) after a crash.
  Network/cable: files over the size limit are not sent; they go to C:\Migration-Oversized\<user> on the OLD PC.
  -PrimaryUser: preset "Copy into" (e.g. from an imaging or domain-join script); files then wait in C:\Migration\<user> until that user
  signs in (Set-MigrationHandoff.ps1). -SourceRoot / -DestRoot: testing overrides (fake Users tree).
  Layout: <tool>\MoveMate.cmd, HOW-TO.txt, logs\, scripts\ (this file, engine, settings).
#>
param(
    [ValidateSet('Network', 'Cable', 'Drive', 'Server')][string]$Method = 'Network',
    [ValidateSet('Old', 'New')][string]$Role = 'Old',
    [switch]$StartCable,
    [string]$PrimaryUser,
    [string]$KeyFile,          # restore key from a Server offload upload: opens ready to download (and unlock) that package
    [string]$SourceRoot, [string]$DestRoot
)

# Self-elevate (reading/writing other users' profiles needs admin). No #Requires: it would block this at parse time.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Run from a mapped network drive (S:\Tools\...)? The elevated window doesn't see that letter: pass \\server\share paths.
    $toUnc = { param($p) if ("$p" -match '^([A-Za-z]):\\') { $u = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Matches[1]):'" -ErrorAction SilentlyContinue).ProviderName; if ($u) { return $u.TrimEnd('\') + "$p".Substring(2) } }; $p }
    $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(& $toUnc $PSCommandPath)`""
    foreach ($kv in $PSBoundParameters.GetEnumerator()) { if ($kv.Value -is [switch]) { if ($kv.Value) { $a += " -$($kv.Key)" } } else { $a += " -$($kv.Key) `"$(& $toUnc $kv.Value)`"" } }
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $a   # hidden: only the window shows, no console
    exit
}

# Started some other way (right-click > Run with PowerShell, an admin prompt...)? Hide our console - but only if it is ours
# alone: a console shared with the window that started us (e.g. an IT admin's prompt) is left alone.
if (-not ('KitMig.Con' -as [type])) {
    Add-Type -Namespace KitMig -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);'
}
$conList = New-Object 'UInt32[]' 4   # ('uint' is not a type name in PowerShell 5.1)
if ([KitMig.Con]::GetConsoleProcessList($conList, 4) -le 1) { [void][KitMig.Con]::ShowWindow([KitMig.Con]::GetConsoleWindow(), 0) }

. (Join-Path $PSScriptRoot 'MigrateCore.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:cancel = $false
$script:busy = $false
$script:mapped = @()
$script:cableOn = $false
$script:hostOn = $false    # Network mode: "Allow access" is on
$NoLimit = 4TB   # a drive export carries everything, so nothing is "oversized"

# MoveMate's own icon (title bars and taskbar). Missing file -> Windows' default icon.
$script:migIcon = try { New-Object Drawing.Icon (Join-Path $PSScriptRoot 'MoveMate.ico') } catch { $null }
function P($x, $y) { New-Object Drawing.Point $x, $y }
function S($w, $h) { New-Object Drawing.Size $w, $h }
$form = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = "$MigToolName $MigToolVersion  -  this PC: $env:COMPUTERNAME"; ClientSize = (S 905 900); StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedSingle'; MaximizeBox = $false; Font = New-Object Drawing.Font('Segoe UI', 9) }
function Add-Ctl([string]$Type, [hashtable]$Props, $Parent = $form) { $c = New-Object "Windows.Forms.$Type" -Property $Props -ErrorAction Stop; $Parent.Controls.Add($c); $c }
function Add-Head([string]$Text, $y) { [void](Add-Ctl Label @{ Text = $Text; Location = (P 12 $y); AutoSize = $true; Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }) }

# 1. How + which PC (two radio groups need two panels)
Add-Head '1. How are the files moving, and which PC is this?' 10
# Running from a flash drive -> "Run from this PC" (copy to C:, reopen, free the stick). Running from C: -> "Remove tool".
$script:installDir = Join-Path $env:SystemDrive $MigToolRel
$script:toolDir = Split-Path $PSScriptRoot
$script:runningLocal = $script:toolDir.TrimEnd('\') -eq $script:installDir.TrimEnd('\')
# Started from a network share (\\server\... or a mapped drive)? Then the copy-to-C: button is about working offline, not the stick.
$script:fromNetwork = $script:toolDir -like '\\*' -or ($script:toolDir -match '^([A-Za-z]):' -and (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Matches[1]):'" -ErrorAction SilentlyContinue).DriveType -eq 4)
$btnHere = Add-Ctl Button @{ Text = $(if ($script:runningLocal) { 'Remove tool from this PC' } elseif ($script:fromNetwork) { 'Run from this PC (works offline)' } else { 'Run from this PC (free the stick)' }); Location = (P 690 5); Size = (S 200 24) }
# Help window (button, F1): HOW-TO.txt next to the tool, split at its "== Topic ==" lines - topics + search on the left,
# one scrolling page on the right. Not modal (read it while working). F1 opens the topic for the current "How".
$script:help = $null
function Show-Help([string]$Topic) {
    $h = Join-Path $script:toolDir 'HOW-TO.txt'
    if (-not (Test-Path -LiteralPath $h)) { [void][Windows.Forms.MessageBox]::Show("The help file isn't here: $h", $MigToolName); return }
    if (-not $script:help -or $script:help.Form.IsDisposed) {
        $topics = New-Object Collections.Generic.List[object]; $cur = $null
        foreach ($l in [IO.File]::ReadAllLines($h)) {
            if ($l -match '^==\s*(.+?)\s*==\s*$') { $cur = [pscustomobject]@{ Title = $Matches[1]; Lines = New-Object Collections.Generic.List[string]; Start = 0 }; $topics.Add($cur) }
            elseif ($cur) { $cur.Lines.Add($l) }
        }
        $f = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = "$MigToolName Help"; Size = (S 980 680); MinimumSize = (S 600 400); StartPosition = 'Manual'; Font = $form.Font; KeyPreview = $true }
        $f.Location = New-Object Drawing.Point ([math]::Max(0, $form.Left + ($form.Width - 980) / 2)), ([math]::Max(0, $form.Top + 40))
        # Docking goes from the last-added control inwards: add the Fill control first
        $page = New-Object Windows.Forms.Panel -Property @{ Dock = 'Fill'; Padding = (New-Object Windows.Forms.Padding 18, 12, 6, 6); BackColor = [Drawing.Color]::White }
        $rtb = New-Object Windows.Forms.RichTextBox -Property @{ Dock = 'Fill'; ReadOnly = $true; BorderStyle = 'None'; BackColor = [Drawing.Color]::White; ScrollBars = 'Vertical'; DetectUrls = $false; HideSelection = $true; TabStop = $false }
        $page.Controls.Add($rtb)
        $side = New-Object Windows.Forms.Panel -Property @{ Dock = 'Left'; Width = 230; Padding = (New-Object Windows.Forms.Padding 8) }
        $list = New-Object Windows.Forms.ListBox -Property @{ Dock = 'Fill'; IntegralHeight = $false; BorderStyle = 'None'; ItemHeight = 24; DrawMode = 'OwnerDrawFixed' }
        $search = New-Object Windows.Forms.TextBox -Property @{ Dock = 'Top' }
        $lblS = New-Object Windows.Forms.Label -Property @{ Dock = 'Top'; Text = 'Search:'; Height = 20 }
        $gap = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 8 }
        # Under the topics: the author's "Buy me a coffee" (the button picture, or a plain button if the picture is missing)
        $script:coffeeUrl = 'https://www.buymeacoffee.com/printerjammed'
        $cof = New-Object Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 66; Padding = (New-Object Windows.Forms.Padding 0, 10, 0, 0) }
        $img = Join-Path $PSScriptRoot 'coffee.png'
        $cb = if (Test-Path -LiteralPath $img) {
            New-Object Windows.Forms.PictureBox -Property @{ Image = [Drawing.Image]::FromFile($img); SizeMode = 'Zoom'; Dock = 'Fill'; Cursor = [Windows.Forms.Cursors]::Hand }
        } else { New-Object Windows.Forms.Button -Property @{ Text = "$([char]::ConvertFromUtf32(0x2615)) Buy me a coffee"; Dock = 'Fill'; Cursor = [Windows.Forms.Cursors]::Hand } }
        (New-Object Windows.Forms.ToolTip).SetToolTip($cb, "Like $($MigToolName)? Buy the author a coffee: $($script:coffeeUrl)")
        $cb.Add_Click({ Start-Process explorer.exe "`"$($script:coffeeUrl)`"" })
        $cof.Controls.Add($cb)
        $side.Controls.AddRange(@($list, $gap, $search, $lblS, $cof))
        $bottom = New-Object Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 40 }
        $bText = New-Object Windows.Forms.Button -Property @{ Text = 'Open as text file'; Size = (S 130 28); Location = (P 8 6) }
        $bClose = New-Object Windows.Forms.Button -Property @{ Text = 'Close'; Size = (S 90 28); Anchor = 'Top, Right' }
        $bottom.Controls.AddRange(@($bText, $bClose)); $bClose.Location = P ($bottom.Width - 98) 6
        $f.Controls.AddRange(@($page, $side, $bottom))
        $f.CancelButton = $bClose
        # The page: each topic = a heading + its text; Start = where it begins (for jumping and for following the scroll)
        $hFont = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold); $bFont = New-Object Drawing.Font('Segoe UI', 10)
        $navy = [Drawing.Color]::FromArgb(0, 70, 140)
        foreach ($t in $topics) {
            $t.Start = $rtb.TextLength
            $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionFont = $hFont; $rtb.SelectionColor = $navy; $rtb.SelectionHangingIndent = 0
            $rtb.AppendText("$($t.Title)`n")
            $body = @($t.Lines); while ($body.Count -and -not $body[-1].Trim()) { $body = @($body | Select-Object -SkipLast 1) }
            foreach ($l in $body) {
                $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionFont = $bFont; $rtb.SelectionColor = [Drawing.Color]::Black
                # list items ("- x", "1. x") wrap under their text, not under the bullet
                $rtb.SelectionHangingIndent = if ($l -match '^\s*(-|\d+\.)\s') { 16 } else { 0 }
                $rtb.AppendText("$l`n")
            }
            $rtb.AppendText("`n")
        }
        $script:help = @{ Form = $f; Rtb = $rtb; List = $list; Search = $search; Topics = $topics; Shown = @(0..($topics.Count - 1)); Sync = $false }
        foreach ($t in $topics) { [void]$list.Items.Add($t.Title) }
        $list.Add_DrawItem({ param($s, $e)
            if ($e.Index -lt 0) { return }
            $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
            $bg = if ($sel) { [Drawing.Color]::FromArgb(0, 95, 184) } else { [Drawing.Color]::White }
            $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $bg), $e.Bounds)
            $fg = if ($sel) { [Drawing.Color]::White } else { [Drawing.Color]::Black }
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, "$($s.Items[$e.Index])", $s.Font, (New-Object Drawing.Rectangle ($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height), $fg, [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis, NoPrefix')
        })
        # Jump: scroll to the end first, then back, so the heading lands at the TOP of the page
        $script:help.Go = { param([int]$i)
            $r = $script:help.Rtb; $r.SelectionStart = $r.TextLength; $r.ScrollToCaret()
            $r.SelectionStart = $script:help.Topics[$i].Start; $r.SelectionLength = 0; $r.ScrollToCaret()
        }
        $list.Add_SelectedIndexChanged({ if (-not $script:help.Sync -and $script:help.List.SelectedIndex -ge 0) { & $script:help.Go $script:help.Shown[$script:help.List.SelectedIndex] } })
        # Scrolling the page selects the topic you're reading
        $rtb.Add_VScroll({
            $hp = $script:help; $at = $hp.Rtb.GetCharIndexFromPosition((P 4 4)); $i = 0
            for ($k = 0; $k -lt $hp.Topics.Count; $k++) { if ($hp.Topics[$k].Start -le $at) { $i = $k } }
            $pos = [array]::IndexOf([int[]]$hp.Shown, $i)
            if ($pos -ge 0 -and $hp.List.SelectedIndex -ne $pos) { $hp.Sync = $true; $hp.List.SelectedIndex = $pos; $hp.Sync = $false }
        })
        # Search: list only the topics that mention it, highlight it on the page, jump to the first one
        $search.Add_TextChanged({
            $hp = $script:help; $q = $hp.Search.Text.Trim(); $r = $hp.Rtb
            $r.SelectAll(); $r.SelectionBackColor = [Drawing.Color]::White
            $hp.Shown = @(for ($k = 0; $k -lt $hp.Topics.Count; $k++) { $t = $hp.Topics[$k]; if (-not $q -or $t.Title -like "*$q*" -or (@($t.Lines) -join "`n") -like "*$q*") { $k } })
            if ($q.Length -ge 2) {
                $i = $r.Find($q, 0, [Windows.Forms.RichTextBoxFinds]::None)
                while ($i -ge 0) { $r.SelectionBackColor = [Drawing.Color]::Gold; $i = if ($i + $q.Length -lt $r.TextLength) { $r.Find($q, $i + $q.Length, [Windows.Forms.RichTextBoxFinds]::None) } else { -1 } }
            }
            $r.SelectionLength = 0
            $hp.Sync = $true; $hp.List.Items.Clear(); foreach ($k in $hp.Shown) { [void]$hp.List.Items.Add($hp.Topics[$k].Title) }; $hp.Sync = $false
            if ($hp.Shown.Count) { $hp.List.SelectedIndex = -1; $hp.List.SelectedIndex = 0 }
        })
        $bText.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$(Join-Path $script:toolDir 'HOW-TO.txt')`"" })
        $bClose.Add_Click({ $script:help.Form.Close() })
        $f.Add_KeyDown({ param($s, $e) if ($e.Control -and $e.KeyCode -eq 'F') { $script:help.Search.Focus(); $e.Handled = $true } })
        $f.Show()
    }
    $hp = $script:help
    if ($hp.Form.WindowState -eq 'Minimized') { $hp.Form.WindowState = 'Normal' }
    $hp.Form.Activate()
    $i = 0; if ($Topic) { for ($k = 0; $k -lt $hp.Topics.Count; $k++) { if ($hp.Topics[$k].Title -eq $Topic) { $i = $k; break } } }
    if ($hp.Search.Text) { $hp.Search.Text = '' }
    $hp.List.SelectedIndex = -1; $hp.List.SelectedIndex = $i
}
$btnHelp = Add-Ctl Button @{ Text = 'Help'; Location = (P 610 5); Size = (S 72 24) }
$btnHelp.Add_Click({ Show-Help })
$form.KeyPreview = $true
$form.Add_KeyDown({ param($s, $e)
    if ($e.KeyCode -ne 'F1') { return }
    # F1 = help on what you're doing (the "How" picked in section 1)
    Show-Help $(if ($rbCable.Checked) { 'Direct cable' } elseif ($rbDrive.Checked) { 'External drive' } elseif ($rbServer.Checked) { 'Server offload' } else { 'Network' })
    $e.Handled = $true
})
$form.Add_FormClosed({ if ($script:help -and -not $script:help.Form.IsDisposed) { $script:help.Form.Close() } })
[void](Add-Ctl Label @{ Text = 'How:'; Location = (P 24 35); AutoSize = $true })
$pnlHow = Add-Ctl Panel @{ Location = (P 100 30); Size = (S 790 26) }
$rbNet = Add-Ctl RadioButton @{ Text = 'Network'; Location = (P 0 3); AutoSize = $true; Checked = $true } $pnlHow
$rbCable = Add-Ctl RadioButton @{ Text = 'Direct cable'; Location = (P 110 3); AutoSize = $true } $pnlHow
$rbDrive = Add-Ctl RadioButton @{ Text = 'External drive'; Location = (P 235 3); AutoSize = $true } $pnlHow
$rbServer = Add-Ctl RadioButton @{ Text = 'Server offload'; Location = (P 375 3); AutoSize = $true } $pnlHow
$howTips = New-Object Windows.Forms.ToolTip -Property @{ AutoPopDelay = 20000; InitialDelay = 300 }
$howTips.SetToolTip($rbNet, "Both PCs on the same network (wired or Wi-Fi): copy straight from one to the other.`r`nWi-Fi works but is usually much slower than a cable. Guest Wi-Fi often blocks PC-to-PC traffic.")
$howTips.SetToolTip($rbCable, 'One Ethernet cable straight between the two PCs (no network needed).')
$howTips.SetToolTip($rbDrive, 'OLD PC: copy to an external drive. NEW PC: copy from it.')
$howTips.SetToolTip($rbServer, "OLD PC: upload to a server share (optionally encrypted). NEW PC: download from it - with the restore`r`nkey from your stick it opens and unlocks by itself. The server copy is deleted once the download is verified.")
[void](Add-Ctl Label @{ Text = 'This PC is:'; Location = (P 24 61); AutoSize = $true })
$pnlRole = Add-Ctl Panel @{ Location = (P 100 56); Size = (S 790 26) }
$rbOld = Add-Ctl RadioButton @{ Text = 'the OLD PC (send files)'; Location = (P 0 3); AutoSize = $true; Checked = $true } $pnlRole
$rbNew = Add-Ctl RadioButton @{ Text = 'the NEW PC (receive files)'; Location = (P 240 3); AutoSize = $true } $pnlRole

$lblPcName = Add-Ctl Label @{ Text = 'Other PC name/IP:'; Location = (P 24 93); AutoSize = $true }
$txtPc = Add-Ctl TextBox @{ Location = (P 135 90); Size = (S 150 23) }
$lblShare = Add-Ctl Label @{ Text = 'Share:'; Location = (P 293 93); AutoSize = $true }
$txtShare = Add-Ctl TextBox @{ Location = (P 337 90); Size = (S 80 23); Text = 'C$' }
$btnTest = Add-Ctl Button @{ Text = 'Test'; Location = (P 424 89); Size = (S 60 26) }
$btnConnect = Add-Ctl Button @{ Text = 'Connect as...'; Location = (P 490 89); Size = (S 95 26) }
$btnCable = Add-Ctl Button @{ Text = 'Start cable link'; Location = (P 600 89); Size = (S 140 26); Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
# Server offload controls (same row as the network ones; only one set is visible)
$lblProt = Add-Ctl Label @{ Text = 'Protection:'; Location = (P 24 93); AutoSize = $true; Visible = $false }
$cmbProt = Add-Ctl ComboBox @{ Location = (P 100 89); Size = (S 290 23); DropDownStyle = 'DropDownList'; Visible = $false }
[void]$cmbProt.Items.AddRange(@('None - plain copy, not encrypted (fastest)', 'Key file - AES-256, key saved to your stick', 'Password - AES-256, typed at download'))
$cmbProt.SelectedIndex = 1
$btnSrvConnect = Add-Ctl Button @{ Text = 'Connect...'; Location = (P 398 89); Size = (S 90 26); Visible = $false }
$btnSrvNew = Add-Ctl Button @{ Text = 'New folder...'; Location = (P 494 89); Size = (S 100 26); Visible = $false }
$lblDrive = Add-Ctl Label @{ Text = 'Drive / folder:'; Location = (P 24 123); AutoSize = $true }
$txtDrive = Add-Ctl TextBox @{ Location = (P 135 120); Size = (S 340 23) }
$btnBrowse = Add-Ctl Button @{ Text = 'Browse...'; Location = (P 482 119); Size = (S 80 26) }
# Admin user for "Connect as": a bare name gets this PC's domain (e.g. jdoe -> DOMAIN\jdoe); only the password is asked.
# Signed in with a domain account -> that domain; else ask Windows, but give up after 3 s (offline / on a cable it can hang);
# else the name saved from an earlier run (Read-Settings).
$script:adminDomain = if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { $env:USERDOMAIN } else {
    $q = [powershell]::Create().AddScript({ "$((Get-CimInstance Win32_NTDomain -ErrorAction SilentlyContinue | Where-Object DomainName | Select-Object -First 1).DomainName)" })
    $h = $q.BeginInvoke()
    if ($h.AsyncWaitHandle.WaitOne(3000)) { "$($q.EndInvoke($h))" } else { '' }
}
$lblAdmin = Add-Ctl Label @{ Text = $(if ($script:adminDomain) { "Admin user ($($script:adminDomain)\):" } else { 'Admin user:' }); Location = (P 575 123); AutoSize = $true }
$txtAdmin = Add-Ctl TextBox @{ Location = (P 725 120); Size = (S 165 23) }
$lblConn = Add-Ctl Label @{ Location = (P 24 150); Size = (S 866 32); ForeColor = [Drawing.Color]::DimGray }

# 2. Profiles
Add-Head '2. Profiles  (tick who to copy; click the blue "Copy into" to change who gets the files)' 186
$btnScan = Add-Ctl Button @{ Text = 'Scan profiles'; Location = (P 785 182); Size = (S 105 26) }
$grid = Add-Ctl DataGridView @{ Location = (P 12 212); Size = (S 878 140); AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; BackgroundColor = [Drawing.Color]::White }
$colChk = New-Object Windows.Forms.DataGridViewCheckBoxColumn -Property @{ HeaderText = 'Copy'; Width = 45 }
[void]$grid.Columns.Add($colChk)
foreach ($c in @(@('Profile', 150, $true), @('Last used', 115, $true), @('Copy into  (click to change)', 330, $true), @('Status', 225, $true))) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ HeaderText = $c[0]; Width = $c[1]; ReadOnly = $c[2] }
    [void]$grid.Columns.Add($col)
}
# "Copy into" (column 3) is set with a picker (Show-CopyInto): looks like a link. Row.Tag = the choice; $null = own account (name in the cell).
$grid.Columns[3].DefaultCellStyle.ForeColor = [Drawing.Color]::Blue
$grid.Columns[3].DefaultCellStyle.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Underline)

# 3. Folders
Add-Head '3. What to copy' 360
$flow = Add-Ctl FlowLayoutPanel @{ Location = (P 20 380); Size = (S 870 52) }
$folderBoxes = @{}
foreach ($k in $MigFolders.Keys) { $cb = New-Object Windows.Forms.CheckBox -Property @{ Text = $k; AutoSize = $true; Checked = $true }; $flow.Controls.Add($cb); $folderBoxes[$k] = $cb }
# Bookmarks: one switch for every browser the user has data for (found per user on the old PC - not "is it installed"),
# plus a dropdown to leave a browser out. $bmBoxes = the dropdown's items (each has .Checked).
$cbBookmarks = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Browser bookmarks'; AutoSize = $true; Checked = $true }
$flow.Controls.Add($cbBookmarks)
$btnBm = New-Object Windows.Forms.Button -Property @{ Text = 'All browsers  ▾'; AutoSize = $true; Height = 24; Margin = (New-Object Windows.Forms.Padding 0, 0, 12, 0) }
$flow.Controls.Add($btnBm)
$bmMenu = New-Object Windows.Forms.ContextMenuStrip
$bmBoxes = @{}
foreach ($k in $MigBookmarks.Keys) {
    $mi = New-Object Windows.Forms.ToolStripMenuItem -Property @{ Text = $k; Checked = $true; CheckOnClick = $true }
    $mi.Add_CheckedChanged({ Update-BookmarkButton }); [void]$bmMenu.Items.Add($mi); $bmBoxes[$k] = $mi
}
$bmMenu.Add_Closing({ param($s, $e) if ($e.CloseReason -eq 'ItemClicked') { $e.Cancel = $true } })   # stay open while ticking
$btnBm.Add_Click({ $bmMenu.Show($btnBm, (P 0 $btnBm.Height)) })
function Update-BookmarkButton {
    $off = @($MigBookmarks.Keys | Where-Object { -not $bmBoxes[$_].Checked })
    $btnBm.Text = if (-not $off.Count) { 'All browsers  ▾' } elseif ($off.Count -eq $bmBoxes.Count) { 'None  ▾' } else { "Not $($off -join ', ')  ▾" }
}
$cbBookmarks.Add_CheckedChanged({ $btnBm.Enabled = $cbBookmarks.Checked })
function Get-SelectedBookmarks { if ($cbBookmarks.Checked) { @($MigBookmarks.Keys | Where-Object { $bmBoxes[$_].Checked }) } else { @() } }
$cbOneDrive = New-Object Windows.Forms.CheckBox -Property @{ Text = 'OneDrive folders (careful: cloud-only files get downloaded)'; AutoSize = $true }
$flow.Controls.Add($cbOneDrive)
# "Settings & lists": small things people miss. Files land in the user's Documents\Migrated Settings; the drives/printers
# list is also printed on their receipt; the programs list is for IT (a searchable page in the run's logs / IT report).
$MigSettingItems = [ordered]@{ StickyNotes = 'Sticky Notes'; Wallpaper = 'Desktop wallpaper'; DrivesPrinters = 'List of network drives + printer connections (on the receipt)'
    Software = 'Application inventory for IT: installed programs + printers (name, IP, driver)'; PrintersMove = 'Printers: carry over to the new PC (drivers + settings, Windows PrintBrm)' }
$cbSettings = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Settings && lists'; AutoSize = $true; Checked = $true }
$flow.Controls.Add($cbSettings)
$btnSet = New-Object Windows.Forms.Button -Property @{ Text = 'All  ▾'; AutoSize = $true; Height = 24; Margin = (New-Object Windows.Forms.Padding 0, 0, 12, 0) }
$flow.Controls.Add($btnSet)
$setMenu = New-Object Windows.Forms.ContextMenuStrip
$setBoxes = @{}
function Update-SetText {
    $on = @($MigSettingItems.Keys | Where-Object { $setBoxes[$_].Checked })
    $btnSet.Text = if ($on.Count -eq $setBoxes.Count) { 'All  ▾' } elseif (-not $on.Count) { 'None  ▾' } else { "$($on.Count) of $($setBoxes.Count)  ▾" }
}
foreach ($k in $MigSettingItems.Keys) {
    $mi = New-Object Windows.Forms.ToolStripMenuItem -Property @{ Text = $MigSettingItems[$k]; CheckOnClick = $true; Checked = ($k -ne 'PrintersMove') }   # carry-over installs drivers: opt in
    $mi.Add_CheckedChanged({ Update-SetText }); [void]$setMenu.Items.Add($mi); $setBoxes[$k] = $mi
}
$setMenu.Add_Closing({ param($s, $e) if ($e.CloseReason -eq 'ItemClicked') { $e.Cancel = $true } })   # stays open while ticking
$btnSet.Add_Click({ $setMenu.Show($btnSet, (P 0 $btnSet.Height)) })
$cbSettings.Add_CheckedChanged({ $btnSet.Enabled = $cbSettings.Checked })
function Get-SelectedSettings { if ($cbSettings.Checked) { @(@('StickyNotes', 'Wallpaper', 'DrivesPrinters') | Where-Object { $setBoxes[$_].Checked }) } else { @() } }
function Test-WantSoftware { $cbSettings.Checked -and $setBoxes['Software'].Checked }
function Test-WantPrintersMove { $cbSettings.Checked -and $setBoxes['PrintersMove'].Checked }
[void](Add-Ctl Label @{ Text = 'Other folders inside the profile (separate with ;):'; Location = (P 20 438); AutoSize = $true })
$txtExtra = Add-Ctl TextBox @{ Location = (P 300 435); Size = (S 590 23) }

# 4. Destination
Add-Head '4. Where on the NEW PC' 466
$rbIntoProfile = Add-Ctl RadioButton @{ Text = "Into the user's folders. No profile there yet? Waits in C:\Migration\<user>; the handoff moves it in at their first sign-in."; Location = (P 24 486); AutoSize = $true; Checked = $true }
$rbMigration = Add-Ctl RadioButton @{ Text = 'Always via C:\Migration\<user>; the handoff moves it into their profile when they next sign in.'; Location = (P 24 508); AutoSize = $true }
$tips = New-Object Windows.Forms.ToolTip -Property @{ AutoPopDelay = 20000; InitialDelay = 300 }
$handoffTip = "HANDOFF: if the user has no profile on the new PC yet, their files are copied to the temporary folder C:\Migration\<user>.`r`n" +
    "A small task on the new PC (Complete-MigrationHandoff.ps1) moves them from there into that user's own folders the first time`r`n" +
    "THEY sign in (anyone else signing in is ignored). Works for any number of users. Don't need someone's backup?`r`n" +
    "Delete C:\Migration\<user> on the new PC. Log: C:\$MigToolRel\logs\handoff.log"
$tips.SetToolTip($rbIntoProfile, $handoffTip); $tips.SetToolTip($rbMigration, $handoffTip)
[void](Add-Ctl Label @{ Text = 'Folders:'; Location = (P 24 535); AutoSize = $true })
$pnlLayout = Add-Ctl Panel @{ Location = (P 100 530); Size = (S 790 26) }
$rbSame = Add-Ctl RadioButton @{ Text = 'Same folders as the old PC'; Location = (P 0 3); AutoSize = $true; Checked = $true } $pnlLayout
$rbBackup = Add-Ctl RadioButton @{ Text = 'Desktop folder'; Location = (P 180 3); AutoSize = $true } $pnlLayout
$rbAsk = Add-Ctl RadioButton @{ Text = 'Ask at sign-in'; Location = (P 295 3); AutoSize = $true } $pnlLayout
# Other: a folder you pick on the NEW PC (or a share); each user gets <folder>\<user>. Text shows the chosen path.
$rbOther = Add-Ctl RadioButton @{ Text = 'Other location...'; Location = (P 405 3); Size = (S 180 20); AutoSize = $false; AutoEllipsis = $true } $pnlLayout
$script:otherPath = ''
$tips.SetToolTip($rbSame, 'Desktop to Desktop, Documents to Documents, ... as on the old PC.')
$tips.SetToolTip($rbBackup, 'Everything in one folder on the user''s desktop (name: Message / folder name...).')
$tips.SetToolTip($rbAsk, 'Files wait in C:\Migration\<user>; at sign-in the user picks: same folders, or the desktop folder.')
$tips.SetToolTip($rbOther, 'Pick a folder on the NEW PC (or a share) - each user gets a subfolder.')
$btnAskMsg = Add-Ctl Button @{ Text = 'Message / folder name...'; Location = (P 590 0); Size = (S 170 25) } $pnlLayout
# Desktop folder name + sign-in question (saved in migrate-settings.json)
$script:backupName = $MigBackupName
$script:askMessage = $MigAskMessage
$tips.SetToolTip($rbBackup, 'Everything goes in one folder on the user''s desktop (name set with "Message / folder name...") - easy to sort and delete later.')
$tips.SetToolTip($rbAsk, "Everyone is staged in C:\Migration\<user>. When THEY sign in (first time, or next time if they already use this PC) a window`r`nasks: 'Place files in same locations' or 'Place files in migration folder on my desktop'. Closing it = asked again next sign-in.")

# 5. Large files (network/cable only)
Add-Head '5. Large files (network and cable only; off = everything is copied)' 564
$cbLarge = Add-Ctl CheckBox @{ Text = 'Set aside files over'; Location = (P 24 587); AutoSize = $true; Checked = $false }
# Built step by step: a -Property hashtable has no order, and Value must be set after Maximum (else it throws and the box is missing).
$numMax = New-Object Windows.Forms.NumericUpDown
$numMax.Location = P 160 585; $numMax.Size = S 75 23; $numMax.Maximum = 100000; $numMax.Minimum = 50; $numMax.Increment = 256; $numMax.Value = 1024
$form.Controls.Add($numMax); $numMax.BringToFront()
[void](Add-Ctl Label @{ Text = 'MB:'; Location = (P 240 588); AutoSize = $true })
$cmbOver = Add-Ctl ComboBox @{ Location = (P 275 585); Size = (S 615 23); DropDownStyle = 'DropDownList' }
[void]$cmbOver.Items.AddRange(@(
    'MOVE them to C:\Migration-Oversized\<user> on the OLD PC (carry over on an external drive)',
    'COPY them to C:\Migration-Oversized\<user> on the OLD PC (needs free space there)',
    'Just LIST them (leave in place, do not transfer)'))
$cmbOver.SelectedIndex = 0

# 6. Report (saved with the large-file settings in migrate-settings.json)
Add-Head '6. Notify IT when finished  (stats CSV + a summary file in a folder on that person''s desktop, plus a popup)' 616
$cbReport = Add-Ctl CheckBox @{ Text = 'Send to PC:'; Location = (P 24 639); AutoSize = $true; Checked = $false }
$txtReport = Add-Ctl TextBox @{ Location = (P 115 636); Size = (S 140 23) }
[void](Add-Ctl Label @{ Text = 'User:'; Location = (P 262 639); AutoSize = $true })
$txtReportUser = Add-Ctl TextBox @{ Location = (P 300 636); Size = (S 100 23) }
$btnTestReport = Add-Ctl Button @{ Text = 'Test'; Location = (P 408 635); Size = (S 60 26) }
$lblReport = Add-Ctl Label @{ Location = (P 476 633); Size = (S 414 32); ForeColor = [Drawing.Color]::DimGray; Text = 'e.g. PC IT-PC01, user jdoe -> C:\Users\jdoe\Desktop\Migration Reports on that PC. Test sends a test popup.' }

# Actions + log
$btnPreview = Add-Ctl Button @{ Text = 'Preview (sizes, large files)'; Location = (P 12 672); Size = (S 190 30) }
$btnStart = Add-Ctl Button @{ Text = 'Start copy'; Location = (P 210 672); Size = (S 120 30); Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
$btnCancel = Add-Ctl Button @{ Text = 'Cancel'; Location = (P 338 672); Size = (S 90 30); Enabled = $false }
$btnWalk = Add-Ctl Button @{ Text = 'Start && walk away...'; Location = (P 436 672); Size = (S 140 30) }
$btnLogs = Add-Ctl Button @{ Text = 'Open logs'; Location = (P 800 672); Size = (S 90 30) }
$lblStatus = Add-Ctl Label @{ Location = (P 584 679); Size = (S 210 20); ForeColor = [Drawing.Color]::DimGray }
# After a run with failed files: copy again - robocopy skips what's already there, so only missing/failed files go
$btnRetry = Add-Ctl Button @{ Text = 'Retry failed'; Location = (P 584 672); Size = (S 110 30); Visible = $false }
function Set-RetryButton([int]$N) {
    $btnRetry.Visible = $N -gt 0; $btnRetry.Text = "Retry failed ($N)"
    $lblStatus.Location = if ($N -gt 0) { P 700 679 } else { P 584 679 }; $lblStatus.Width = if ($N -gt 0) { 95 } else { 210 }
}
# Top row (left of Help): [Installers] [Advanced...] [Help] [Run from this PC]
$btnAdv = Add-Ctl Button @{ Text = 'Advanced...'; Location = (P 522 5); Size = (S 82 24) }
$btnInst = Add-Ctl Button @{ Text = 'Installers'; Location = (P 436 5); Size = (S 80 24); Visible = $false }
$txtLog = Add-Ctl TextBox @{ Location = (P 12 710); Size = (S 878 130); Multiline = $true; ScrollBars = 'Vertical'; ReadOnly = $true; Font = New-Object Drawing.Font('Consolas', 9); BackColor = [Drawing.Color]::White }
# Progress of the running transfer (bytes): bar + "42%  1.2 GB of 2.9 GB  85 MB/s  ~3 min left"
# Current = the user\folder being copied (encrypted server modes: the file itself); Total = the whole transfer
[void](Add-Ctl Label @{ Text = 'Current:'; Location = (P 12 850); AutoSize = $true; ForeColor = [Drawing.Color]::DimGray })
$curBar = Add-Ctl ProgressBar @{ Location = (P 66 848); Size = (S 466 18); Minimum = 0; Maximum = 1000; Style = 'Continuous' }
$lblCur = Add-Ctl Label @{ Location = (P 540 850); Size = (S 350 18); ForeColor = [Drawing.Color]::DimGray; AutoEllipsis = $true }
[void](Add-Ctl Label @{ Text = 'Total:'; Location = (P 12 874); AutoSize = $true; ForeColor = [Drawing.Color]::DimGray })
$prgBar = Add-Ctl ProgressBar @{ Location = (P 66 872); Size = (S 466 18); Minimum = 0; Maximum = 1000; Style = 'Continuous' }
$lblProg = Add-Ctl Label @{ Location = (P 540 874); Size = (S 350 18); ForeColor = [Drawing.Color]::DimGray }

$logRoot = Join-Path (Split-Path $PSScriptRoot) 'logs'   # <tool>\logs (this script is in <tool>\scripts)
# Everything shown in the log box is also saved: logs\sessions\<PC>_<time>.log (to compare both sides afterwards)
$script:sessionLog = Join-Path $logRoot ("sessions\{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format yyyyMMdd_HHmmss))
function Write-Log([string]$m) {
    $txtLog.AppendText("$m`r`n")
    try {
        if (-not (Test-Path (Split-Path $script:sessionLog))) { New-Item -ItemType Directory -Force (Split-Path $script:sessionLog) | Out-Null }
        Add-Content -LiteralPath $script:sessionLog -Value "$(Get-Date -Format 'HH:mm:ss')  $m" -Encoding UTF8
    } catch {}
    if ($script:ovStatus -and $m.Trim()) { $script:ovStatus.Text = $m.Trim() }   # progress line on the walk-away screen
    [Windows.Forms.Application]::DoEvents()
}

# ---------- Walk-away mode: password lock + full-screen message while copying, completion message after ----------
# Messages are saved in migrate-settings.json; the password is kept only in memory (SHA-256) for this run.
# Placeholders: {ReportFile} {OldPC} {NewPC}. A deterrent, not a kiosk: Ctrl+Alt+Del / the power button still work.
$script:walk = @{
    During    = 'Please do not attempt to change or power off PC until data transfer is complete.'
    Done      = 'Data transfer complete. Transfer log saved to {ReportFile} on your desktop.'
    DoneCable = 'Data transfer complete. Transfer log saved to {ReportFile}. Please contact IT to reconnect your computer to the network.'
}
$script:locked = $false; $script:pwHash = $null; $script:overlay = $null; $script:ovStatus = $null; $script:ovClose = $false
$script:jobDone = $false   # walk-away job finished: closing is allowed without the password, using the tool still is not
# When finished (OK): close MoveMate after the report went to IT; Remove = also uninstall it, ONLY when running from this
# PC's own copy ($script:runningLocal) - never from a stick or a network share. Saved in settings.
$script:walkAuto = @{ Close = $false; Remove = $true; SignOut = $false }
$script:walkMode = 'App'; $script:walkOn = $false; $script:ovExtra = @(); $script:sessionUser = ''
$script:reportSent = $false
if (-not ('KitMig.Guard' -as [type])) {
    Add-Type -Namespace KitMig -Name Guard -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool ShutdownBlockReasonCreate(IntPtr hWnd, string reason);
[DllImport("user32.dll")] public static extern bool ShutdownBlockReasonDestroy(IntPtr hWnd);
'@
}
function Get-Hash([string]$s) { [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) }
# Keeps the PC awake and makes Windows' Shut down / Restart show the message (until the copy ends).
function Set-WalkGuard([bool]$On) {
    # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED - decimal: PowerShell reads 0x80000000 as a negative Int32
    if ($On) { [void][KitMig.Guard]::SetThreadExecutionState([uint32]2147483651); [void][KitMig.Guard]::ShutdownBlockReasonCreate($form.Handle, $script:walk.During) }
    else { [void][KitMig.Guard]::SetThreadExecutionState([uint32]2147483648); [void][KitMig.Guard]::ShutdownBlockReasonDestroy($form.Handle) }
}

function Read-Password([string]$Prompt, [switch]$Plain) {
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = $(if ($Plain) { 'Pairing code' } else { 'IT password' }); ClientSize = (S 320 120); StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; TopMost = $true; Font = $form.Font }
    $l = New-Object Windows.Forms.Label -Property @{ Text = $Prompt; Location = (P 12 6); Size = (S 296 30) }
    $t = New-Object Windows.Forms.TextBox -Property @{ Location = (P 12 38); Size = (S 296 23); UseSystemPasswordChar = (-not $Plain); CharacterCasing = $(if ($Plain) { 'Upper' } else { 'Normal' }) }
    $ok = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = (P 152 78); Size = (S 75 28); DialogResult = 'OK' }
    $no = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 233 78); Size = (S 75 28); DialogResult = 'Cancel' }
    $d.Controls.AddRange(@($l, $t, $ok, $no)); $d.AcceptButton = $ok; $d.CancelButton = $no
    if ($d.ShowDialog() -eq 'OK') { $t.Text } else { $null }
}
function Test-ItPassword { if (-not $script:pwHash) { return $true }; $p = Read-Password 'Enter the IT password to unlock:'; ($null -ne $p) -and ((Get-Hash $p) -eq $script:pwHash) }
# The Windows password of whoever is signed in at this PC's screen (interactive logon check: cached passwords work offline,
# e.g. on a direct cable). Used to lift the lockdown screen only - MoveMate itself stays locked for IT.
if (-not ('KitMig.Logon' -as [type])) {
    Add-Type -Namespace KitMig -Name Logon -MemberDefinition @"
[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
"@
}
function Get-SessionUser { try { "$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName)" } catch { '' } }
function Test-WindowsPassword([string]$Account, [string]$Password) {
    if (-not $Account -or -not $Password) { return $false }
    $dom = '.'; $u = $Account; if ($Account -match '^([^\\]+)\\(.+)$') { $dom = $Matches[1]; $u = $Matches[2] }
    $tok = [IntPtr]::Zero
    $ok = [KitMig.Logon]::LogonUser($u, $dom, $Password, 2, 0, [ref]$tok)   # 2 = interactive
    if ($ok) { [void][KitMig.Logon]::CloseHandle($tok) }
    $ok
}

function Set-Locked([bool]$On) {
    $script:locked = $On
    if (-not $On) { $script:pwHash = $null; $script:walkOn = $false; foreach ($c in $form.Controls) { $c.Enabled = $true } }
    $btnWalk.Text = $(if ($On) { 'IT unlock...' } else { 'Start && walk away...' })
    if ($On -and $form.Text -notlike '*LOCKED*') { $form.Text += '   [LOCKED by IT - transfer running]' }
    elseif (-not $On) { $form.Text = $form.Text -replace '\s+\[LOCKED by IT[^\]]*\]', '' }
    Update-ModeUi
}

# Setup dialog. Returns $true when the user chose a password, a lock mode and messages (saved for next time, not the password).
#   App    = lock MoveMate only: the PC stays usable (someone keeps working); MoveMate needs the IT password.
#   Screen = full-screen lockdown on every monitor (nobody around); the signed-in Windows user's password lifts the
#            screen (MoveMate stays locked), the IT password unlocks everything.
function Show-WalkDialog {
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = 'Start and walk away'; ClientSize = (S 560 690); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font }
    $add = { param($c) $d.Controls.Add($c); $c }
    $gray = [Drawing.Color]::DimGray
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = 'IT password to unlock MoveMate (not saved anywhere):'; Location = (P 12 12); Size = (S 536 20) }))
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = 'IT password:'; Location = (P 12 40); AutoSize = $true }))
    $p1 = & $add (New-Object Windows.Forms.TextBox -Property @{ Location = (P 110 37); Size = (S 150 23); UseSystemPasswordChar = $true })
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = 'Again:'; Location = (P 275 40); AutoSize = $true }))
    $p2 = & $add (New-Object Windows.Forms.TextBox -Property @{ Location = (P 320 37); Size = (S 150 23); UseSystemPasswordChar = $true })
    $who = Get-SessionUser
    $rbApp = & $add (New-Object Windows.Forms.RadioButton -Property @{ Text = 'Lock MoveMate only  (someone keeps working on this PC)'; Location = (P 12 74); AutoSize = $true })
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = 'Only this window is locked; the PC stays usable. The IT password unlocks MoveMate.'; Location = (P 30 96); Size = (S 518 18); ForeColor = $gray }))
    $rbScr = & $add (New-Object Windows.Forms.RadioButton -Property @{ Text = 'Full-screen lockdown, all monitors  (nobody around)'; Location = (P 12 120); AutoSize = $true })
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Location = (P 30 142); Size = (S 518 34); ForeColor = $gray
        Text = "Shows the message below. Back to the desktop: the Windows password of $(if ($who) { $who } else { 'the signed-in user' }) (MoveMate stays locked), or the IT password. Ctrl+Alt+Del > Switch user also works." }))
    if ($script:walkMode -eq 'Screen') { $rbScr.Checked = $true } else { $rbApp.Checked = $true }
    $cbAt = & $add (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Start at:'; Location = (P 12 188); AutoSize = $true; Checked = $false })
    $dtAt = New-Object Windows.Forms.DateTimePicker; $dtAt.Format = 'Time'; $dtAt.ShowUpDown = $true; $dtAt.Location = P 92 185; $dtAt.Size = S 110 23
    $dtAt.Value = (Get-Date).Date.AddHours(16); [void](& $add $dtAt)
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = 'later today (tomorrow if that time has passed) - it waits locked, the PC stays awake; IT unlock cancels'; Location = (P 210 188); Size = (S 340 34); ForeColor = $gray }))
    $boxes = @{}
    $y = 226
    foreach ($k in @(@('During', 'While copying (lockdown screen):'), @('Done', 'When finished:'), @('DoneCable', 'When finished (Direct cable):'))) {
        [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = $k[1]; Location = (P 12 $y); AutoSize = $true }))
        $boxes[$k[0]] = & $add (New-Object Windows.Forms.TextBox -Property @{ Location = (P 12 ($y + 20)); Size = (S 536 42); Multiline = $true; ScrollBars = 'Vertical'; Text = $script:walk[$k[0]] })
        $y += 70
    }
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = '{ReportFile} = the Migration Report file name on the user''s desktop;  {OldPC} {NewPC} = PC names.'; Location = (P 12 $y); Size = (S 536 20); ForeColor = $gray }))
    $y += 30
    $sendIt = $cbReport.Checked -and $txtReport.Text.Trim()
    $cbAuto = & $add (New-Object Windows.Forms.CheckBox -Property @{ Location = (P 12 $y); AutoSize = $true; Checked = $script:walkAuto.Close
        Text = "When it finishes OK, close $MigToolName$(if ($sendIt) { " (after the report is sent to $($txtReport.Text.Trim()))" })" })
    $cbRemove = & $add (New-Object Windows.Forms.CheckBox -Property @{ Location = (P 30 ($y + 24)); AutoSize = $true; Checked = $script:walkAuto.Remove; Visible = $script:runningLocal
        Text = "...and remove $MigToolName from this PC" })
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Location = (P 30 ($y + 48)); Size = (S 518 34); ForeColor = $gray
        Text = $(if ($script:runningLocal) { "It runs from this PC's copy ($($script:installDir)), made by 'Run from this PC'. Users' files are not touched. With problems it stays open for IT." }
                 else { "Running from a stick / network share: $MigToolName is never removed from there. With problems it stays open for IT." }) }))
    $cbOut = & $add (New-Object Windows.Forms.CheckBox -Property @{ Location = (P 12 ($y + 88)); AutoSize = $true; Checked = $script:walkAuto.SignOut
        Text = 'Sign out of Windows when it finishes  (60-second warning first)' })
    [void](& $add (New-Object Windows.Forms.Label -Property @{ Location = (P 30 ($y + 110)); Size = (S 518 34); ForeColor = $gray
        Text = "So your login isn't left open. Also with problems: the log is saved (and sent to IT) first, and $MigToolName closes first (network back to normal)." }))
    $syncAuto = { $cbRemove.Enabled = $cbAuto.Checked -or $cbOut.Checked }; & $syncAuto; $cbAuto.Add_CheckedChanged($syncAuto); $cbOut.Add_CheckedChanged($syncAuto)
    $ok = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Lock and start'; Location = (P 352 652); Size = (S 110 30) })
    $no = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 470 652); Size = (S 78 30); DialogResult = 'Cancel' })
    $d.CancelButton = $no
    $ok.Add_Click({
        if (-not $p1.Text) { [void][Windows.Forms.MessageBox]::Show('Choose an IT password.', 'Walk away'); return }
        if ($p1.Text -cne $p2.Text) { [void][Windows.Forms.MessageBox]::Show('The two passwords are different.', 'Walk away'); return }
        $d.DialogResult = 'OK'
    })
    if ($d.ShowDialog($form) -ne 'OK') { return $false }
    foreach ($k in 'During', 'Done', 'DoneCable') { if ($boxes[$k].Text.Trim()) { $script:walk[$k] = $boxes[$k].Text.Trim() } }
    $script:pwHash = Get-Hash $p1.Text
    $script:walkMode = if ($rbScr.Checked) { 'Screen' } else { 'App' }
    $script:walkAuto.Close = $cbAuto.Checked; $script:walkAuto.Remove = $cbRemove.Checked; $script:walkAuto.SignOut = $cbOut.Checked
    $script:walkStartAt = $null
    if ($cbAt.Checked) { $at = (Get-Date).Date + $dtAt.Value.TimeOfDay; if ($at -le (Get-Date)) { $at = $at.AddDays(1) }; $script:walkStartAt = $at }
    Save-Settings
    $true
}

# Lockdown screen: one topmost dark window per monitor (the main one has the buttons). No close; Unlock asks for a password:
# IT password = unlock everything; the signed-in Windows user's password = back to the desktop, MoveMate stays locked.
# Done mode adds OK (clears the screen, MoveMate stays locked) and Close transfer wizard.
function Show-Overlay([string]$Text) {
    $script:sessionUser = Get-SessionUser
    $bg = [Drawing.Color]::FromArgb(16, 24, 32)
    $prim = [Windows.Forms.Screen]::PrimaryScreen
    $o = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; FormBorderStyle = 'None'; TopMost = $true; ShowInTaskbar = $false; BackColor = $bg; StartPosition = 'Manual'; Bounds = $prim.Bounds }
    $msg = New-Object Windows.Forms.Label -Property @{ Text = $Text; Dock = 'Fill'; TextAlign = 'MiddleCenter'; ForeColor = [Drawing.Color]::White; Font = New-Object Drawing.Font('Segoe UI', 26) }
    $help = New-Object Windows.Forms.Label -Property @{ Dock = 'Bottom'; Height = 60; TextAlign = 'MiddleCenter'; ForeColor = [Drawing.Color]::Silver; Font = New-Object Drawing.Font('Segoe UI', 12)
        Text = "Need this PC? Click Unlock and enter the Windows password of $(if ($script:sessionUser) { $script:sessionUser } else { 'the signed-in user' }),`r`nor press Ctrl+Alt+Del > Switch user and sign in as yourself. The transfer keeps running." }
    $bottom = New-Object Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 70 }
    $status = New-Object Windows.Forms.Label -Property @{ Dock = 'Fill'; TextAlign = 'MiddleLeft'; ForeColor = [Drawing.Color]::Gray; Font = New-Object Drawing.Font('Segoe UI', 10); Padding = New-Object Windows.Forms.Padding(20, 0, 0, 0) }
    $unlock = New-Object Windows.Forms.Button -Property @{ Text = 'Unlock'; Dock = 'Right'; Width = 140; ForeColor = [Drawing.Color]::White; FlatStyle = 'Flat'; Font = New-Object Drawing.Font('Segoe UI', 12) }
    $okBtn = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Dock = 'Right'; Width = 120; Visible = $false; ForeColor = [Drawing.Color]::White; FlatStyle = 'Flat'; Font = New-Object Drawing.Font('Segoe UI', 14) }
    $closeBtn = New-Object Windows.Forms.Button -Property @{ Text = 'Close transfer wizard'; Dock = 'Right'; Width = 260; Visible = $false; ForeColor = [Drawing.Color]::White; FlatStyle = 'Flat'; Font = New-Object Drawing.Font('Segoe UI', 14) }
    $bottom.Controls.AddRange(@($status, $closeBtn, $okBtn, $unlock))
    $o.Controls.AddRange(@($msg, $help, $bottom))
    $unlock.Add_Click({ Unlock-Overlay })
    $okBtn.Add_Click({ Close-Overlay })                      # clears the screen; the tool stays locked
    $closeBtn.Add_Click({ Close-Overlay; $form.Close() })    # job done: closing needs no password
    $guard = { param($s, $e) if (-not $script:ovClose) { $e.Cancel = $true } }
    $o.Add_FormClosing($guard)
    $o.Tag = @{ Msg = $msg; Ok = $okBtn; Close = $closeBtn; Help = $help }
    $script:overlay = $o; $script:ovStatus = $status; $script:ovClose = $false
    # the other monitors: the same message, nothing to click
    $script:ovExtra = @(foreach ($sc in @([Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary })) {
        $x = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; FormBorderStyle = 'None'; TopMost = $true; ShowInTaskbar = $false; BackColor = $bg; StartPosition = 'Manual'; Bounds = $sc.Bounds }
        $xl = New-Object Windows.Forms.Label -Property @{ Text = $Text; Dock = 'Fill'; TextAlign = 'MiddleCenter'; ForeColor = [Drawing.Color]::White; Font = New-Object Drawing.Font('Segoe UI', 26) }
        $x.Controls.Add($xl); $x.Tag = $xl; $x.Add_FormClosing($guard); $x.Show(); $x
    })
    $o.Show(); $o.Activate()
}
function Unlock-Overlay {
    $p = Read-Password "IT password, or the Windows password of $(if ($script:sessionUser) { $script:sessionUser } else { 'the signed-in user' }):"
    if ($null -eq $p) { return }
    if ($script:pwHash -and (Get-Hash $p) -eq $script:pwHash) { Close-Overlay; Set-Locked $false; Write-Log 'Unlocked by IT.'; return }
    if (Test-WindowsPassword $script:sessionUser $p) {
        Close-Overlay
        Write-Log "Screen unlocked by $($script:sessionUser) (Windows password) - $MigToolName stays locked until the IT password is entered."
        return
    }
    if ($script:ovStatus) { $script:ovStatus.Text = 'Wrong password.' }
}
function Set-OverlayDone([string]$Text) {
    if (-not $script:overlay) { return }
    $script:overlay.Tag.Msg.Text = $Text; $script:overlay.Tag.Ok.Visible = $true; $script:overlay.Tag.Close.Visible = $true; $script:ovStatus.Text = ''
    $script:overlay.Tag.Help.Visible = $false
    foreach ($x in @($script:ovExtra)) { if ($x -and -not $x.IsDisposed) { $x.Tag.Text = $Text } }
}
function Close-Overlay {
    $script:ovClose = $true
    foreach ($x in @($script:ovExtra)) { if ($x -and -not $x.IsDisposed) { $x.Close() } }; $script:ovExtra = @()
    if (-not $script:overlay) { return }
    $script:ovStatus = $null
    $script:overlay.Close(); $script:overlay = $null
}
# Lock MoveMate only: the finished message in a small window (the PC is in use - no full screen)
function Show-DoneNote([string]$Text) {
    $n = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = $MigToolName; ClientSize = (S 480 180); StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; TopMost = $true; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font }
    $l = New-Object Windows.Forms.Label -Property @{ Text = $Text; Location = (P 16 16); Size = (S 448 110); Font = New-Object Drawing.Font('Segoe UI', 11) }
    $b = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = (P 374 136); Size = (S 90 30); DialogResult = 'OK' }
    $b.Add_Click({ $this.FindForm().Close() })
    $n.Controls.AddRange(@($l, $b)); $n.AcceptButton = $b
    $n.Show()
    $script:doneNote = $n
}
# ---------- Saved preferences (next to this script, so the flash drive / the clone's copy remembers them) ----------
$settingsFile = Join-Path $PSScriptRoot 'migrate-settings.json'
function Read-Settings {
    try { $s = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return }
    if ($s.ReportTo) { $txtReport.Text = $s.ReportTo }
    if ($s.ReportUser) { $txtReportUser.Text = $s.ReportUser }
    if ($s.AdminUser) { $txtAdmin.Text = $s.AdminUser }
    if (-not $script:adminDomain -and $s.AdminDomain) { $script:adminDomain = $s.AdminDomain; $lblAdmin.Text = "Admin user ($($script:adminDomain)\):" }
    $cbReport.Checked = [bool]$s.ReportEnabled
    $cbLarge.Checked = [bool]$s.LargeFiles   # off unless turned on (older settings files: off)
    if ($null -ne $s.Bookmarks) { $cbBookmarks.Checked = [bool]$s.Bookmarks }
    foreach ($k in @($s.BookmarksExcluded)) { if ($k -and $bmBoxes.ContainsKey($k)) { $bmBoxes[$k].Checked = $false } }
    if ($s.MaxMB -ge $numMax.Minimum -and $s.MaxMB -le $numMax.Maximum) { $numMax.Value = $s.MaxMB }
    if ($s.Oversize -ge 0 -and $s.Oversize -lt $cmbOver.Items.Count) { $cmbOver.SelectedIndex = $s.Oversize }
    if ($s.OtherPath) { $script:otherPath = $s.OtherPath; Set-OtherText }
    if ($null -ne $s.Settings) { $cbSettings.Checked = [bool]$s.Settings }
    foreach ($k in @($s.SettingsExcluded)) { if ($k -and $setBoxes.ContainsKey($k)) { $setBoxes[$k].Checked = $false } }
    Import-MigAdvanced; $btnInst.Visible = [bool]$MigAdv.Installers
    if ($s.BackupPath) { $script:backupPath = $s.BackupPath }   # last "backup folder only" (Copy into)
    $script:cableNoAsk = [bool]$s.CableNoAsk   # "Don't ask again" on the Start cable link note
    if ($s.Layout -eq 'Backup') { $rbBackup.Checked = $true } elseif ($s.Layout -eq 'Ask') { $rbAsk.Checked = $true }
    elseif ($s.Layout -eq 'Other' -and $script:otherPath) { $rbOther.Checked = $true }
    if ($s.BackupName) { $script:backupName = $s.BackupName }
    if ($s.AskMessage) { $script:askMessage = $s.AskMessage }
    if ($s.ServerPath) { $script:serverPath = $s.ServerPath }
    if ($s.Protection -ge 0 -and $s.Protection -lt $cmbProt.Items.Count) { $cmbProt.SelectedIndex = $s.Protection }
    foreach ($k in 'During', 'Done', 'DoneCable') { if ($s."Walk$k") { $script:walk[$k] = $s."Walk$k" } }
    $script:walkAuto.Close = [bool]$s.WalkAutoClose; if ($null -ne $s.WalkAutoRemove) { $script:walkAuto.Remove = [bool]$s.WalkAutoRemove }
    $script:walkAuto.SignOut = [bool]$s.WalkSignOut; if ($s.WalkMode -in 'App', 'Screen') { $script:walkMode = $s.WalkMode }
}
function Save-Settings {
    try {
        [ordered]@{ ReportEnabled = $cbReport.Checked; ReportTo = $txtReport.Text.Trim(); ReportUser = $txtReportUser.Text.Trim(); AdminUser = $txtAdmin.Text.Trim(); AdminDomain = $script:adminDomain
            Bookmarks = $cbBookmarks.Checked; BookmarksExcluded = @($MigBookmarks.Keys | Where-Object { -not $bmBoxes[$_].Checked })
            LargeFiles = $cbLarge.Checked; MaxMB = [int]$numMax.Value; Oversize = $cmbOver.SelectedIndex; Layout = $(if ($rbBackup.Checked) { 'Backup' } elseif ($rbAsk.Checked) { 'Ask' } elseif ($rbOther.Checked) { 'Other' } else { 'Same' }); OtherPath = $script:otherPath; BackupPath = $script:backupPath; CableNoAsk = [bool]$script:cableNoAsk
            Settings = $cbSettings.Checked; SettingsExcluded = @($MigSettingItems.Keys | Where-Object { -not $setBoxes[$_].Checked }); Advanced = $MigAdv
            BackupName = $script:backupName; AskMessage = $script:askMessage
            ServerPath = $script:serverPath; Protection = $cmbProt.SelectedIndex
            WalkDuring = $script:walk.During; WalkDone = $script:walk.Done; WalkDoneCable = $script:walk.DoneCable
            WalkAutoClose = $script:walkAuto.Close; WalkAutoRemove = $script:walkAuto.Remove; WalkSignOut = $script:walkAuto.SignOut; WalkMode = $script:walkMode } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsFile -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Log "Could not save settings: $($_.Exception.Message)" }
}

# ---------- IT notification: <PC>\C$\Users\<user>\Desktop\Migration Reports gets MigrationStats.csv + '<run> - OK.txt', plus a msg.exe popup ----------
# No user = Public desktop (everyone on that PC). A path with '\' = that folder as-is. OneDrive-redirected desktops are detected.
function Get-ReportDir([string]$To, [string]$User) {
    $To = $To.Trim(); $User = ($User.Trim() -split '\\')[-1]
    if ($To -match '\\') { return $To.TrimEnd('\') }
    $h = if ($script:reportHost) { $script:reportHost } else { $To.TrimStart('\') }   # the name or IP that Connect-ReportPc got in with
    $users = "\\$h\C`$\Users"
    if (-not $User) { return "$users\Public\Desktop\Migration Reports" }
    $uhome = "$users\$User"
    $od = @(Get-ChildItem -LiteralPath $uhome -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'Desktop' } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    "$(if ($od) { $od } else { "$uhome\Desktop" })\Migration Reports"
}
# Log in to the IT PC's C$ (this tool may run as a local account the IT PC doesn't accept, e.g. the new PC's local admin).
# Tries: as-is, the Admin user's saved login from this run, then (with -Prompt) asks for the Admin user's password.
# Falls back to the IT PC's IP when Windows refuses a second login to the same name (error 1219).
$script:reportHost = $null; $script:reportCred = $null
function Connect-ReportPc([string]$To, [switch]$Prompt) {
    $To = $To.Trim()
    if ($To -match '\\') { return [bool](Test-Path -LiteralPath $To) }   # a \\server\share folder: current login only
    $pc = $To.TrimStart('\')
    $hosts = @($pc); try { $hosts += @([Net.Dns]::GetHostAddresses($pc) | Where-Object AddressFamily -eq 'InterNetwork' | ForEach-Object IPAddressToString | Select-Object -First 1) } catch {}
    foreach ($h in $hosts) { if (Test-Path -LiteralPath "\\$h\C`$\Users") { $script:reportHost = $h; return $true } }
    $creds = @()
    if ($script:reportCred) { $creds += $script:reportCred }
    if ($script:remoteCred -and $script:adminDomain -and $script:remoteCred.UserName -like "$($script:adminDomain)\*") { $creds += $script:remoteCred }
    if ($Prompt) {
        $admin = $txtAdmin.Text.Trim()
        if ($admin -and $admin -notmatch '[\\@]' -and $script:adminDomain) { $admin = "$($script:adminDomain)\$admin" }
        $c = if ($admin) { Get-Credential -UserName $admin -Message "Login for the IT PC $pc (to put the report on its desktop)" } else { Get-Credential -Message "Admin login for the IT PC $pc (e.g. DOMAIN\user)" }
        if ($c) { $creds += $c }
    }
    foreach ($c in $creds) {
        foreach ($h in $hosts) {
            $path = "\\$h\C`$"
            try {
                Remove-SmbMapping -RemotePath $path -Force -ErrorAction SilentlyContinue
                New-SmbMapping -RemotePath $path -UserName $c.UserName -Password $c.GetNetworkCredential().Password -ErrorAction Stop | Out-Null
                $script:mapped += $path
                if (Test-Path -LiteralPath "$path\Users") { $script:reportHost = $h; $script:reportCred = $c; return $true }
            } catch { if ($_.Exception.Message -notmatch '1219|multiple connections') { break } }
        }
    }
    $false
}

# Reads a stats CSV that may have been opened and re-saved in Excel: any line breaks (Excel can save bare CR), and
# Excel's date/time formats put back to the tool's (Date yyyy-MM-dd HH:mm, TransferTime hh:mm:ss).
function Read-StatsCsv([string]$Csv) {
    $text = [IO.File]::ReadAllText($Csv) -replace "`r`n", "`n" -replace "`r", "`n"
    $rows = @($text.TrimEnd("`n") | ConvertFrom-Csv)
    foreach ($r in $rows) {
        if ($r.PSObject.Properties['Date']) { try { $r.Date = ([datetime]::Parse($r.Date, [Globalization.CultureInfo]::GetCultureInfo('en-US'))).ToString('yyyy-MM-dd HH:mm') } catch {} }
        if ($r.PSObject.Properties['TransferTime'] -and $r.TransferTime -match '^(\d+):(\d+):(\d+)$') { $r.TransferTime = '{0:D2}:{1:D2}:{2:D2}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3] }
    }
    $rows
}
# Appends rows to a stats CSV, skipping runs already in it (RunFolder). Retries ~10 s if the file is open (e.g. in Excel,
# which locks it). If the new rows bring new columns, the whole file is rewritten once with all columns (older rows keep
# their values, new columns blank) so every row lines up. Returns $true when written.
function Add-StatsRows([string]$Csv, [object[]]$Rows) {
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $old = @(); if (Test-Path -LiteralPath $Csv) { $old = @(Read-StatsCsv $Csv) }
            $cols = New-Object Collections.Generic.List[string]
            if ($old.Count) { foreach ($n in $old[0].PSObject.Properties.Name) { $cols.Add($n) } }
            $newRows = @($Rows | Where-Object { @($old | ForEach-Object RunFolder) -notcontains $_.RunFolder })
            foreach ($r in $newRows) { foreach ($n in $r.PSObject.Properties.Name) { if (-not $cols.Contains($n)) { $cols.Add($n) } } }
            if (-not $newRows.Count) { return $true }
            $grew = $old.Count -and $cols.Count -gt $old[0].PSObject.Properties.Name.Count
            if ($grew) {
                $tmp = "$Csv.tmp"
                @($old) + @($newRows) | Select-Object $cols.ToArray() | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                Move-Item -LiteralPath $tmp -Destination $Csv -Force -ErrorAction Stop   # fails while the CSV is open -> retry
            } elseif ($old.Count) {
                $newRows | Select-Object $cols.ToArray() | Export-Csv -LiteralPath $Csv -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            } else {
                $newRows | Select-Object $cols.ToArray() | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }
            return $true
        } catch { Remove-Item -LiteralPath "$Csv.tmp" -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
    }
    $false
}
# Dashboard support: MigrationStats.js (the CSV as a JS string - browsers may load a local script but not read a local
# file) + Migration Dashboard.html, both next to the CSV, so double-clicking the dashboard shows the data.
function Update-Dashboard([string]$Dir) {
    try {
        $csv = Join-Path $Dir 'MigrationStats.csv'
        if (Test-Path -LiteralPath $csv) {
            $text = [IO.File]::ReadAllText($csv)
            $js = "window.MIGRATION_CSV = $($text | ConvertTo-Json -Compress);`r`nwindow.MIGRATION_CSV_UPDATED = '$(Get-Date -Format 'yyyy-MM-dd HH:mm')';`r`n"
            [IO.File]::WriteAllText((Join-Path $Dir 'MigrationStats.js'), $js, (New-Object Text.UTF8Encoding $false))
        }
        $mine = Join-Path $script:toolDir 'extras\Migration Dashboard.html'; $theirs = Join-Path $Dir 'Migration Dashboard.html'
        if ((Test-Path -LiteralPath $mine) -and (-not (Test-Path -LiteralPath $theirs) -or (Get-FileHash -LiteralPath $mine).Hash -ne (Get-FileHash -LiteralPath $theirs).Hash)) { Copy-Item -LiteralPath $mine $theirs -Force }
    } catch { Write-Log "Dashboard files not updated in ${Dir}: $($_.Exception.Message)" }
}
# Sends one finished run (its folder holds stats.json + summary.txt). Throws only if nothing could be delivered.
# Order: summary file first (that's the notification), then the CSV row. CSV open/locked -> the row is parked in
# 'MigrationStats - add <run>.csv' next to it, and merged in (then deleted) by the next delivery that can write the CSV.
function Send-RunReport([string]$To, [string]$User, [string]$RunDir) {
    $row = Get-Content -LiteralPath (Join-Path $RunDir 'stats.json') -Raw | ConvertFrom-Json
    if (-not (Connect-ReportPc $To)) { throw "Can't log in to $To (access denied). Click Test in section 6 and sign in with your admin user." }
    $dir = Get-ReportDir $To $User
    if ($User -and -not (Test-Path -LiteralPath (Split-Path $dir))) { throw "No folder for user '$User' on $To ($(Split-Path (Split-Path $dir))) - has that user signed in there?" }
    New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath (Join-Path $RunDir 'summary.txt') -Destination (Join-Path $dir "$($row.RunFolder) - $($row.Result).txt") -Force -ErrorAction Stop
    Get-ChildItem -LiteralPath $RunDir -Filter 'Application inventory - *.html' -File -ErrorAction SilentlyContinue | Copy-Item -Destination $dir -Force -ErrorAction SilentlyContinue
    $csv = Join-Path $dir 'MigrationStats.csv'
    $parked = @(Get-ChildItem -LiteralPath $dir -Filter 'MigrationStats - add *.csv' -File -ErrorAction SilentlyContinue)
    $rows = @($parked | ForEach-Object { Import-Csv -LiteralPath $_.FullName }) + @($row)
    if (Add-StatsRows $csv $rows) {
        foreach ($p in $parked) { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue }
        if ($parked.Count) { Write-Log "Merged $($parked.Count) parked stats row(s) into MigrationStats.csv." }
        Update-Dashboard $dir
    } else {
        $row | Export-Csv -LiteralPath (Join-Path $dir "MigrationStats - add $($row.RunFolder).csv") -NoTypeInformation -ErrorAction Stop
        Write-Log "MigrationStats.csv is open on $To (Excel?) - row saved as 'MigrationStats - add $($row.RunFolder).csv'; merged automatically next time."
    }
}
# Popup via msg.exe <user> /server:<PC>. Shows only if that PC allows remote messages
# (HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server AllowRemoteRPC=1); the desktop folder is the reliable notice.
function Send-Popup([string]$To, [string]$User, [string]$Text) {
    $pc = if ($To -match '^\\\\([^\\]+)') { $Matches[1] } elseif ($script:reportHost) { $script:reportHost } elseif ($To -notmatch '\\') { $To.Trim() } else { return $false }
    $who =if ($User.Trim()) { ($User.Trim() -split '\\')[-1] } else { '*' }
    $msgExe = Join-Path $env:SystemRoot 'System32\msg.exe'
    if (-not (Test-Path $msgExe)) { return $false }
    $p = Start-Process $msgExe -ArgumentList "$who /server:$pc /time:0 `"$($Text.Replace('"', "'"))`"" -WindowStyle Hidden -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; return $false }
    $p.ExitCode -eq 0
}
# Unsent reports (IT PC unreachable, e.g. on a direct cable) are queued here and retried after the next run or Test.
$unsentFile = Join-Path $logRoot 'unsent-reports.txt'
# The queue holds run FOLDER NAMES (not full paths): the flash drive gets a different letter on every PC.
function Send-Reports([string]$To, [string]$User, [string]$RunDir) {
    $queue = @(); if (Test-Path $unsentFile) { $queue = @(Get-Content $unsentFile | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf }) }
    if ($RunDir) { $queue += (Split-Path $RunDir -Leaf) }
    $left = @(); $sent = 0
    foreach ($name in ($queue | Select-Object -Unique)) {
        $d = Join-Path $logRoot $name
        if (-not (Test-Path -LiteralPath (Join-Path $d 'stats.json'))) { Write-Log "Queued report $name not found in $logRoot - dropped."; continue }
        try { Send-RunReport $To $User $d; $sent++ } catch { $left += $name; Write-Log "Report not sent ($name): $($_.Exception.Message)" }
    }
    if ($left.Count) { Set-Content $unsentFile $left -Encoding UTF8 } elseif (Test-Path $unsentFile) { [IO.File]::Delete($unsentFile) }
    [pscustomobject]@{ Sent = $sent; Left = $left.Count; Dir = (Get-ReportDir $To $User) }
}
function Set-Conn([string]$Text, [string]$Color = 'DimGray') { $lblConn.ForeColor = [Drawing.Color]::$Color; $lblConn.Text = $Text; [Windows.Forms.Application]::DoEvents() }
$waitBlock = { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100; Update-RoboProgress; $script:cancel }

# ---------- Progress bar (bottom of the window) ----------
# Start-Progress sets the total for one phase. Robocopy phases: Update-RoboProgress (called while robocopy runs) adds up
# the bytes of the file lines appearing in the run's UTF-16 logs, reading only what's new. Unchanged files (a rerun) are
# not logged, so a rerun may jump to 100% at the end.
$script:prog = $null
function Format-Eta([double]$Sec) { if ($Sec -lt 60) { '<1 min' } elseif ($Sec -lt 3600) { '~{0} min' -f [math]::Ceiling($Sec / 60) } else { '~{0:N1} h' -f ($Sec / 3600) } }
# $Parts (robocopy phases): log file name -> @{ Bytes; Label } per user\folder, for the Current bar.
function Start-Progress([long]$Total, [string]$What, [string]$LogDir, [hashtable]$Parts = @{}) {
    $script:prog = @{ Total = [math]::Max($Total, 1); What = $What; LogDir = $LogDir; Offsets = @{}; Done = [long]0; T0 = Get-Date; Last = [datetime]::MinValue
        Parts = $Parts; PartDone = @{} }
    $prgBar.Style = 'Continuous'; $prgBar.Value = 0; $lblProg.Text = "$What..."
    $curBar.Value = 0; $lblCur.Text = ''
}
function Set-Current([long]$Done, [long]$Total, [string]$Label) {
    if ($Total -le 0) { $curBar.Value = 0; $lblCur.Text = $Label; return }
    $Done = [math]::Min($Done, $Total)
    $curBar.Value = [int](1000 * $Done / $Total)
    $lblCur.Text = '{0}  {1}%  {2} of {3}' -f $Label, [int](100 * $Done / $Total), (Format-Size $Done), (Format-Size $Total)
}
function Set-Progress([long]$Done, [long]$Total = 0) {
    if (-not $script:prog) { return }
    if ($Total -gt 0) { $script:prog.Total = $Total }
    $t = $script:prog.Total; $Done = [math]::Min($Done, $t); $script:prog.Done = $Done
    $prgBar.Value = [int](1000 * $Done / $t)
    $sec = ((Get-Date) - $script:prog.T0).TotalSeconds
    $rate = if ($sec -gt 2) { $Done / $sec } else { 0 }
    $txt = '{0}  {1}%  {2} of {3}' -f $script:prog.What, [int](100 * $Done / $t), (Format-Size $Done), (Format-Size $t)
    if ($rate -gt 0) { $txt += '  {0}/s  {1} left' -f (Format-Size ([long]$rate)), (Format-Eta (($t - $Done) / $rate)) }
    $lblProg.Text = $txt
}
function Update-RoboProgress {
    $p = $script:prog
    if (-not $p -or -not $p.LogDir -or ((Get-Date) - $p.Last).TotalMilliseconds -lt 800) { return }
    $p.Last = Get-Date
    $done = $p.Done; $cur = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $p.LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
        $off = [long]$p.Offsets[$f.FullName]
        try {
            # the size in a directory listing lags while robocopy has the log open - ask the open file instead
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -le $off) { continue }
                [void]$fs.Seek($off, 'Begin'); $buf = New-Object byte[] ($fs.Length - $off); $n = $fs.Read($buf, 0, $buf.Length)
            } finally { $fs.Close() }
            $text = [Text.Encoding]::Unicode.GetString($buf, 0, $n - ($n % 2))
            $cut = $text.LastIndexOf("`n"); if ($cut -lt 0) { continue }   # only whole lines; the rest is read next time
            $add = [long]0
            foreach ($l in $text.Substring(0, $cut).Split("`n")) { if ($l -match $MigFileLine) { $add += [long]$Matches[2] } }
            $done += $add; $p.PartDone[$f.Name] = [long]$p.PartDone[$f.Name] + $add; $cur = $f.Name   # the log that just grew = the folder being copied
            $p.Offsets[$f.FullName] = $off + [Text.Encoding]::Unicode.GetByteCount($text.Substring(0, $cut + 1))
        } catch {}
    }
    Set-Progress $done
    if ($cur -and $p.Parts.ContainsKey($cur)) { Set-Current $p.PartDone[$cur] $p.Parts[$cur].Bytes $p.Parts[$cur].Label }
}
function Stop-Progress([bool]$Finished) {
    if ($script:prog -and $Finished) { $prgBar.Value = 1000; $lblProg.Text = "Done - $(Format-Size $script:prog.Total) in $('{0:hh\:mm\:ss}' -f ((Get-Date) - $script:prog.T0))" }
    elseif ($script:prog) { $lblProg.Text = "Stopped at $([int]($prgBar.Value / 10))%" }
    if ($Finished) { $curBar.Value = 1000 }; $lblCur.Text = ''
    $script:prog = $null
}

# Runs a slow step (SMB login, \\PC checks, name lookup, cleanup) in the background so the window keeps responding.
# The script block gets the engine path as its first argument (dot-source it if needed). Gives up after $TimeoutSec or,
# with -Cancelable, when Cancel is clicked - a stuck call is abandoned, never waited for.
# Returns @{ Ok; Output; Error; TimedOut; Cancelled }.
$script:corePath = Join-Path $PSScriptRoot 'MigrateCore.ps1'
function Invoke-Bg([scriptblock]$Script, [object[]]$ArgList = @(), [int]$TimeoutSec = 30, [switch]$Cancelable, [string]$Status) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script).AddArgument($script:corePath)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $h = $ps.BeginInvoke()
    $t0 = Get-Date
    $res = @{ Ok = $false; Output = $null; Error = $null; TimedOut = $false; Cancelled = $false }
    while (-not $h.IsCompleted) {
        if ($Status) { $lblStatus.Text = "$Status ($([int]((Get-Date) - $t0).TotalSeconds) s)" }
        [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
        if ($Cancelable -and $script:cancel) { $res.Cancelled = $true; break }
        if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) { $res.TimedOut = $true; break }
    }
    if ($res.Cancelled -or $res.TimedOut) { try { [void]$ps.BeginStop($null, $null) } catch {}; return $res }   # abandon, don't wait
    try { $res.Output = $ps.EndInvoke($h) } catch { $res.Error = $_.Exception.InnerException.Message; if (-not $res.Error) { $res.Error = $_.Exception.Message } }
    if (-not $res.Error -and $ps.Streams.Error.Count) { $res.Error = "$($ps.Streams.Error[0])" }
    $res.Ok = -not $res.Error
    $ps.Dispose()
    $res
}

# Push / Pull / Export / Import / Receive (cable, NEW PC: only opens the share)
function Get-Mode {
    if ($rbDrive.Checked) { if ($rbOld.Checked) { 'Export' } else { 'Import' } }
    elseif ($rbServer.Checked) { if ($rbOld.Checked) { 'Upload' } else { 'Download' } }
    elseif ($rbOld.Checked) { 'Push' } else { 'Pull' }   # network or direct cable: either PC can run the copy
}

$hints = @{
    Push    = 'Type the NEW PC''s name, then Connect... (your admin login) and Test. Not working? On the NEW PC click Allow access and use its code here.'
    Pull    = 'Type the OLD PC''s name, then Connect... (your admin login) and Test. Not working? On the OLD PC click Allow access and use its code here.'
    Export  = 'Plug in the external drive and Browse to it. A PCMigration-<this PC> folder is created on it. Then Scan profiles.'
    Import  = 'Browse to the external drive (or its PCMigration-<OLD PC> folder). Then Scan profiles.'
    Upload  = 'Type or Browse to the server folder (\\server\share\folder; Connect... = your admin login). A <this PC>_<date> package is made there. Pick Protection, then Scan profiles.'
    Download = 'Double-click the "Restore <OLD PC>" key on your stick (opens and unlocks by itself), or Browse to the <OLD PC>_<date> package on the server. Then Scan profiles.'
    Cable   = '1) Open this tool on BOTH PCs while still on the network (Windows checks your admin login).  2) Click Start cable link on both - it waits for you to connect the two PCs with one Ethernet cable.  3) They find and connect to each other by themselves; then Scan profiles on the PC you work from.'
}

function Update-ModeUi {
    $mode = Get-Mode
    $net = $rbNet.Checked; $cable = $rbCable.Checked; $drive = $rbDrive.Checked; $server = $rbServer.Checked; $idle = -not $script:busy
    # Row 2: the other PC (network/cable/drive) or the server's protection + login (server)
    foreach ($c in $lblPcName, $txtPc, $lblShare, $txtShare, $btnTest, $btnConnect) { $c.Visible = -not $server }
    foreach ($c in $btnSrvConnect, $btnSrvNew) { $c.Visible = $server; $c.Enabled = $idle }
    $btnSrvNew.Visible = $server -and $rbOld.Checked   # downloading never creates folders
    foreach ($c in $lblProt, $cmbProt) { $c.Visible = $server -and $rbOld.Checked }   # a download reads it from the package
    $cmbProt.Enabled = $idle
    $lblDrive.Text = $(if ($server) { 'Server folder:' } else { 'Drive / folder:' })
    foreach ($c in $txtPc, $txtShare, $btnTest, $btnConnect) { $c.Enabled = $idle -and ($net -or ($cable -and $script:cableOn)) }
    $txtAdmin.Enabled = $idle -and ($net -or $server)   # a cable uses the pairing code instead
    $btnConnect.Text = $(if ($cable) { 'Enter code...' } else { 'Connect...' })
    # One button, by mode: Network = let the other PC in with a code; Cable = the whole cable link; Drive/Server = not used
    $btnCable.Visible = -not ($drive -or $server)
    $btnCable.Enabled = $idle -and ($cable -or ($net -and -not $script:cableOn))
    $btnCable.Text = if ($cable) { if ($script:cableOn) { 'End cable link' } else { 'Start cable link' } }
                     elseif ($script:hostOn) { 'Stop allowing access' } else { 'Allow access (code)' }
    foreach ($c in $txtDrive, $btnBrowse) { $c.Enabled = $idle -and ($drive -or $server) }
    $cbLarge.Enabled = -not ($drive -or $server)   # drive / server carry everything
    foreach ($c in $numMax, $cmbOver) { $c.Enabled = $cbLarge.Enabled -and $cbLarge.Checked }
    $sending = ($drive -or $server) -and $rbOld.Checked   # to a drive/server: no "where on the new PC" yet
    $pnlLayout.Enabled = -not $sending
    foreach ($c in $rbIntoProfile, $rbMigration) { $c.Enabled = -not $sending -and -not $rbAsk.Checked }   # Ask = always via C:\Migration
    foreach ($c in $btnScan, $btnPreview, $btnStart) { $c.Enabled = $idle }
    foreach ($c in $pnlHow, $pnlRole) { $c.Enabled = $idle -and -not $script:cableOn -and -not $script:hostOn }
    if (-not $script:cableOn -and -not $script:hostOn -and -not $script:busy) {
        if ($cable -and $script:fromNetwork -and -not $script:runningLocal) { Set-Conn 'This tool is running from the network share, which is gone once you switch to the cable. Click "Run from this PC (works offline)" (top right) first, on BOTH PCs.' 'DarkOrange' }
        else { Set-Conn $(if ($cable) { $hints.Cable } else { $hints[$mode] }) }
    }
    # Cancel while something runs; Reset (clean slate) while a cable link / Allow access is set up but idle
    $btnCancel.Enabled = $script:busy -or $script:cableOn -or $script:hostOn
    $btnCancel.Text = $(if ($script:busy) { 'Cancel' } else { 'Reset' })
    # Walk-away lock: everything off except the unlock button and the log
    if ($script:locked) { foreach ($c in $form.Controls) { if ($c -ne $btnWalk -and $c -ne $txtLog) { $c.Enabled = $false } }; $btnWalk.Enabled = $true }
}

# Src/Dst roots for the current mode, or $null (after a message).
function Get-Roots {
    if ($SourceRoot -and $DestRoot) { return @{ Src = $SourceRoot; Dst = $DestRoot; Remote = $DestRoot; Other = 'TEST'; Mode = 'Push' } }
    $mode = Get-Mode
    $local = $env:SystemDrive
    if ($mode -eq 'Upload' -or $mode -eq 'Download') {
        $dir = $txtDrive.Text.Trim().TrimEnd('\')
        if (-not $dir) { [void][Windows.Forms.MessageBox]::Show('Type or Browse to the server folder first (\\server\share\folder).', $MigToolName); return $null }
        if (-not (Test-Path -LiteralPath $dir)) { [void][Windows.Forms.MessageBox]::Show("Can't open $dir.`r`n`r`nCheck the path, or click Connect... and log in with your admin user$(if ($mode -eq 'Upload') { ' (New folder... creates a folder)' }).", $MigToolName); return $null }
        $script:serverPath = if (Test-Path -LiteralPath (Join-Path $dir $PkgHeader)) { Split-Path $dir } else { $dir }   # remembered: the folder, not a package
        $srv = if ($dir -match '^\\\\([^\\]+)') { $Matches[1] } else { 'server' }
        if ($mode -eq 'Upload') {
            if ($dir -like "$local*") { [void][Windows.Forms.MessageBox]::Show('That is on this PC''s own drive. Pick a folder on the server.', $MigToolName); return $null }
            if (Test-Path -LiteralPath (Join-Path $dir $PkgHeader)) { [void][Windows.Forms.MessageBox]::Show('That folder is an upload package. Pick the folder it is in.', $MigToolName); return $null }
            if (-not $script:pkgName) { $script:pkgName = '{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmm') }
            $pkg = Join-Path $dir $script:pkgName
            return @{ Src = $local; Dst = $pkg; Remote = $pkg; Other = $srv; Mode = $mode; Server = $dir }
        }
        # Download: the package itself, or the folder holding exactly one
        $pkg = $dir
        if (-not (Test-Path -LiteralPath (Join-Path $pkg $PkgHeader))) {
            $found = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $PkgHeader) })
            if ($found.Count -ne 1) { [void][Windows.Forms.MessageBox]::Show("Pick the <OLD PC>_<date> package folder ($($found.Count) packages in $dir).", $MigToolName); return $null }
            $pkg = $found[0].FullName; $txtDrive.Text = $pkg
        }
        try { $hdr = Get-Content -LiteralPath (Join-Path $pkg $PkgHeader) -Raw -Encoding UTF8 | ConvertFrom-Json } catch { [void][Windows.Forms.MessageBox]::Show("Can't read the package header in ${pkg}: $($_.Exception.Message)", $MigToolName); return $null }
        if ($hdr.Format -ne 'MigrateUserFiles-Package') { [void][Windows.Forms.MessageBox]::Show("$pkg is not an upload package.", $MigToolName); return $null }
        return @{ Src = $pkg; Dst = $local; Remote = $pkg; Other = "$($hdr.OldPC)"; Mode = $mode; Header = $hdr; Server = (Split-Path $pkg) }
    }
    if ($mode -eq 'Export' -or $mode -eq 'Import') {
        $dir = $txtDrive.Text.Trim().TrimEnd('\')
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { [void][Windows.Forms.MessageBox]::Show('Pick the external drive or folder first (Browse...).', $MigToolName); return $null }
        if ($dir -eq $local) { [void][Windows.Forms.MessageBox]::Show('That is this PC''s own drive. Pick the external drive.', $MigToolName); return $null }
        if ($mode -eq 'Export') {
            $root = Join-Path $dir "PCMigration-$env:COMPUTERNAME"
            return @{ Src = $local; Dst = $root; Remote = $root; Other = 'drive'; Mode = $mode }
        }
        $root = $dir
        if (-not (Test-Path -LiteralPath (Join-Path $root 'Users'))) {
            $found = @(Get-ChildItem -LiteralPath $dir -Directory -Filter 'PCMigration-*' -ErrorAction SilentlyContinue)
            if ($found.Count -ne 1) { [void][Windows.Forms.MessageBox]::Show("Pick the PCMigration-<OLDPC> folder on the drive ($($found.Count) found in $dir).", $MigToolName); return $null }
            $root = $found[0].FullName; $txtDrive.Text = $root
        }
        return @{ Src = $root; Dst = $local; Remote = $root; Other = 'drive'; Mode = $mode }
    }
    $pc = $txtPc.Text.Trim().TrimStart('\')
    if (-not $pc) { [void][Windows.Forms.MessageBox]::Show('Type the other PC''s name or IP address first.', $MigToolName); return $null }
    if ($pc -eq $env:COMPUTERNAME) { [void][Windows.Forms.MessageBox]::Show('That is this PC. Type the OTHER PC''s name.', $MigToolName); return $null }
    $share = $txtShare.Text.Trim().Trim('\'); if (-not $share) { $share = 'C$' }
    $remote = "\\$pc\$share"
    if ($mode -eq 'Push') { return @{ Src = $local; Dst = $remote; Remote = $remote; Other = $pc; Mode = $mode } }
    return @{ Src = $remote; Dst = $local; Remote = $remote; Other = $pc; Mode = $mode }
}

function Get-SelectedRows {
    [void]$grid.EndEdit()   # returns True - without [void] that True became an extra, nameless "row"
    @($grid.Rows | Where-Object { $_ -is [Windows.Forms.DataGridViewRow] -and $_.Cells[0].Value -eq $true -and "$($_.Cells[1].Value)".Trim() })
}

# Folders (relative to the profile) for one source profile.
function Get-FolderList([string]$ProfilePath) {
    $list = @($MigFolders.Keys | Where-Object { $folderBoxes[$_].Checked } | ForEach-Object { $MigFolders[$_] })
    if ($cbOneDrive.Checked) { $list += @(Get-ChildItem -LiteralPath $ProfilePath -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object Name) }
    $list += @($txtExtra.Text -split ';' | ForEach-Object { $_.Trim().Trim('\') } | Where-Object { $_ -and $_ -notmatch '\.\.|:' })
    $list | Select-Object -Unique
}

function Set-Busy([bool]$On) {
    $script:busy = $On
    if ($On) { $script:cancel = $false }
    $form.Cursor = $(if ($On) { [Windows.Forms.Cursors]::AppStarting } else { [Windows.Forms.Cursors]::Default })
    Update-ModeUi
}

foreach ($rb in $rbNet, $rbCable, $rbDrive, $rbServer, $rbOld, $rbNew) { $rb.Add_CheckedChanged({ if ($this.Checked) { $grid.Rows.Clear(); $lblStatus.Text = ''; $script:pkgName = $null; Update-ModeUi } }) }
# The path box is shared: the drive path and the server path are each remembered while the other mode is shown
$script:serverPath = ''; $script:drivePath = ''
$rbServer.Add_CheckedChanged({
    if ($rbServer.Checked) { $script:drivePath = $txtDrive.Text; $txtDrive.Text = $script:serverPath }
    else { if ($txtDrive.Text.Trim()) { $script:serverPath = $txtDrive.Text.Trim() }; $txtDrive.Text = $script:drivePath }
})
foreach ($rb in $rbSame, $rbBackup, $rbAsk, $rbOther) { $rb.Add_CheckedChanged({ if ($this.Checked) { Update-ModeUi } }) }

# Other location: pick a folder ON THE NEW PC (when this is the old PC: browsed through \\NEWPC\C$, saved as C:\...),
# or a network share. Each user's files go to <folder>\<user>.
function Set-OtherText {
    $rbOther.Text = if ($script:otherPath) { "Other: $($script:otherPath)" } else { 'Other location...' }
    $tips.SetToolTip($rbOther, $(if ($script:otherPath) { "Each user's files go to $($script:otherPath)\<user> on the NEW PC. Their receipt still goes on their desktop.`r`nClick again to pick another folder." } else { 'Pick a folder on the NEW PC (or a share) - each user gets a subfolder.' }))
}
# Path usable from THIS PC for a path on the NEW PC: copying TO another PC (Push), D:\Data -> \\NEWPC\D$\Data.
function Resolve-OtherRoot([string]$Path, $Roots) {
    if ($Roots.Dst -like '\\*' -and $Path -match '^([A-Za-z]):\\?(.*)$') { "\\$(($Roots.Dst -split '\\')[2])\$($Matches[1])`$\$($Matches[2])".TrimEnd('\') } else { $Path.TrimEnd('\') }
}
# Folder browser for a folder ON THE NEW PC (or a share); returns it as the new PC sees it (D:\Data) or $null.
function Select-NewPcFolder([string]$Current, [string]$Description, $Owner = $form) {
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ ShowNewFolderButton = $true; Description = $Description }
    $pc = $txtPc.Text.Trim().TrimStart('\')
    if ((Get-Mode) -eq 'Push' -and $pc) {
        if ($Current -match '^([A-Za-z]):\\?(.*)$') { $d.SelectedPath = "\\$pc\$($Matches[1])`$\$($Matches[2])" } else { $d.SelectedPath = "\\$pc\C`$" }
    } elseif ($Current -and (Test-Path -LiteralPath $Current)) { $d.SelectedPath = $Current }
    if ($d.ShowDialog($Owner) -ne 'OK') { return $null }
    $p = $d.SelectedPath.TrimEnd('\')
    if ($p -match '^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$' -and $Matches[1] -eq $pc) { $p = "$($Matches[2]):$($Matches[3])" }   # the new PC's own drive
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    if ($p -match '^[A-Za-z]:\\(Users|Windows|Program Files.*|Migration.*)?$' -and $p -notmatch '^[A-Za-z]:\\$') {
        [void][Windows.Forms.MessageBox]::Show("Pick a folder outside $p (system folder).", $MigToolName); return $null
    }
    $p
}
function Select-OtherPath {
    $p = Select-NewPcFolder $script:otherPath "Folder on the NEW PC for the files (Make New Folder creates one). Each user gets a subfolder: <folder>\<user>."
    if (-not $p) { return $false }
    $script:otherPath = $p; Set-OtherText; Save-Settings
    Write-Log "Other location: files go to $p\<user> on the NEW PC."
    $true
}
$rbOther.Add_Click({ if (-not (Select-OtherPath) -and -not $script:otherPath) { $rbSame.Checked = $true } })

# ---------- "Copy into" picker (one row = one old-PC profile) ----------
# Row.Tag: $null = their own account (user name = the cell), @{ Kind = 'User'; User = 'mjones' } = someone else gets them
# (replacement: one folder on that person's desktop, "Files from <old user>"), @{ Kind = 'Backup'; Path = 'D:\Old Staff' } =
# nobody yet: <path>\<old user> with the report inside, no desktop receipt, no sign-in handoff.
$script:backupPath = ''
function Get-ReplaceFolderName([string]$Name) { "Files from $(Get-HandoffUser $Name)" }
# The new PC's Users folder as seen from here ($null = not reachable)
function Get-NewPcUsersDir {
    $users = if ($DestRoot) { Join-Path $DestRoot 'Users' } elseif ((Get-Mode) -eq 'Push') { $pc = $txtPc.Text.Trim().TrimStart('\'); if ($pc) { "\\$pc\C`$\Users" } } else { Join-Path $env:SystemDrive 'Users' }
    if ($users -and (Test-Path -LiteralPath $users)) { $users }
}
# Copy into + Status cells follow the choice
function Set-CopyIntoCell($Row) {
    $p = "$($Row.Cells[1].Value)"; $t = $Row.Tag; $users = Get-NewPcUsersDir
    $send = (Get-Mode) -in 'Export', 'Upload'   # old PC -> drive/server: the choice travels with the copy (copy-into.json)
    $who = if ($t -and $t.Kind -eq 'User') { $t.User } elseif (-not $t) { "$($Row.Cells[3].Value)".Trim() }
    if ($t -and $t.Kind -eq 'User') { $Row.Cells[3].Value = "$($t.User)  (desktop folder '$(Get-ReplaceFolderName $p)')" }
    elseif ($t -and $t.Kind -eq 'Later') { $Row.Cells[3].Value = if ($send) { 'Decide on the new PC (just a copy)' } else { 'NOT DECIDED - click to pick who gets them' } }
    elseif ($t) { $Row.Cells[3].Value = "Backup only: $($t.Path.TrimEnd('\'))\$(Get-HandoffUser $p)" }
    if ($send) {
        $Row.Cells[4].Value = if ($t -and $t.Kind -eq 'Later') { 'copied as-is; pick who gets it on the new PC' } else { "copied; on the new PC it goes to $who" }
        return
    }
    $Row.Cells[4].Value = if ($t -and $t.Kind -eq 'Later') { 'pick who gets these before Start' }
        elseif ($t -and $t.Kind -eq 'Backup') { 'backup only - no receipt, no sign-in handoff' }
        elseif (-not $users) { 'new PC not reachable yet' }
        elseif ($who -and (Resolve-DestProfile $users $who)) { "profile found on new PC$(if ($t) { " ($who)" })" }
        else { "no profile yet: waits in C:\Migration\$who, moves in at their first sign-in" }
}
# The old PC's choices travel with a drive export / server upload: <folder>\copy-into.json (user names only, no files).
# { "jsmith": { "Kind": "User", "User": "mjones" }, "kdoe": { "Kind": "Later" }, "alice": { "Kind": "Self", "User": "alice" } }
$CopyIntoFile = 'copy-into.json'
function Read-CopyInto([string]$Dir) {
    $h = @{}
    try { $j = Get-Content -LiteralPath (Join-Path $Dir $CopyIntoFile) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { return $h }
    foreach ($pp in $j.PSObject.Properties) {
        $v = $pp.Value; $u = Get-HandoffUser "$($v.User)"; $okU = $u -match '^[A-Za-z0-9._-]{1,64}$'
        if ($v.Kind -eq 'Later') { $h[$pp.Name] = @{ Kind = 'Later' } }
        elseif ($v.Kind -in 'User', 'Self' -and $okU) { $h[$pp.Name] = @{ Kind = "$($v.Kind)"; User = $u } }
    }
    $h
}
function Save-CopyInto([string]$Dir, $Rows) {
    $h = Read-CopyInto $Dir   # an export folder can be added to: keep the other profiles' choices
    foreach ($row in $Rows) {
        $t = $row.Tag
        $h["$($row.Cells[1].Value)"] = if ($t -and $t.Kind -in 'User', 'Later') { $t } else { @{ Kind = 'Self'; User = "$($row.Cells[3].Value)".Trim() } }
    }
    $o = [ordered]@{}; foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
    [IO.File]::WriteAllText((Join-Path $Dir $CopyIntoFile), ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
# User names on the new PC (profile folders) for the "someone else" list
function Get-NewPcUserNames {
    $users = Get-NewPcUsersDir
    if (-not $users) { return @() }
    @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users', 'defaultuser0', 'WDAGUtilityAccount' } | ForEach-Object { Get-HandoffUser $_.Name } | Sort-Object -Unique)
}
function Show-CopyInto($Row) {
    $send = (Get-Mode) -in 'Export', 'Upload'   # choice is saved with the copy and filled in on the new PC (still changeable there)
    $prof = "$($Row.Cells[1].Value)"; $old = Get-HandoffUser $prof; $t = $Row.Tag
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = "Copy into - $prof's files"; ClientSize = (S 620 330); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font }
    $gray = [Drawing.Color]::DimGray
    $rSelf = New-Object Windows.Forms.RadioButton -Property @{ Text = 'Their own account on the new PC.  User name:'; Location = (P 12 12); AutoSize = $true }
    $tSelf = New-Object Windows.Forms.TextBox -Property @{ Location = (P 330 10); Size = (S 170 23); Text = $(if ($t) { $old } else { "$($Row.Cells[3].Value)" }) }
    $hSelf = New-Object Windows.Forms.Label -Property @{ Text = 'Change the name only if they sign in with a different name on the new PC. Section 4 decides the folders.'; Location = (P 30 36); Size = (S 580 18); ForeColor = $gray }
    $rUser = New-Object Windows.Forms.RadioButton -Property @{ Text = "Someone else (replacing $old):"; Location = (P 12 70); AutoSize = $true }
    $cUser = New-Object Windows.Forms.ComboBox -Property @{ Location = (P 330 68); Size = (S 170 23); DropDownStyle = 'DropDown' }
    foreach ($u in (Get-NewPcUserNames)) { if ($u -ne $old) { [void]$cUser.Items.Add($u) } }
    if ($t -and $t.Kind -eq 'User') { $cUser.Text = $t.User }
    $hUser = New-Object Windows.Forms.Label -Property @{ Text = "Everything goes in ONE folder on that person's desktop: '$(Get-ReplaceFolderName $prof)' (nothing of theirs is overwritten), with the receipt. Not signed in on the new PC yet? Type their user name: the files wait in C:\Migration and move in at their first sign-in."; Location = (P 30 94); Size = (S 580 50); ForeColor = $gray }
    $rBak = New-Object Windows.Forms.RadioButton -Property @{ Text = 'Nobody yet - backup folder only:'; Location = (P 12 156); AutoSize = $true }
    $tBak = New-Object Windows.Forms.TextBox -Property @{ Location = (P 330 154); Size = (S 190 23); Text = $(if ($t -and $t.Kind -eq 'Backup') { $t.Path } else { $script:backupPath }) }
    $bBak = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...'; Location = (P 525 153); Size = (S 80 25) }
    $hBak = New-Object Windows.Forms.Label -Property @{ Text = "Files go to <folder>\$old on the NEW PC (or a \\server\share), with the report inside. No desktop receipt, nothing waits for a sign-in. Make sure only the right people can open that folder."; Location = (P 30 180); Size = (S 580 50); ForeColor = $gray }
    $all = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Use this for every ticked profile'; Location = (P 12 250); AutoSize = $true }
    $ok = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = (P 430 288); Size = (S 85 30) }
    $cancel = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 520 288); Size = (S 85 30); DialogResult = 'Cancel' }
    $d.Controls.AddRange(@($rSelf, $tSelf, $hSelf, $rUser, $cUser, $hUser, $rBak, $tBak, $bBak, $hBak, $all, $ok, $cancel))
    $d.AcceptButton = $ok; $d.CancelButton = $cancel
    if ($send) {
        # Old PC, copying to a drive/server: the new PC isn't known yet -> type the name, or leave it for the new PC
        $hSelf.Text = 'Their user name on the new PC (change it only if different). Section 4 on the new PC decides the folders.'
        $cUser.Items.Clear()
        $hUser.Text = "Type their user name. On the new PC everything goes in ONE folder on their desktop: '$(Get-ReplaceFolderName $prof)' (nothing of theirs is overwritten). Not signed in there yet? The files wait until their first sign-in."
        $rBak.Text = 'Decide on the new PC (just keep a copy for now)'
        $tBak.Visible = $false; $bBak.Visible = $false
        $hBak.Text = "When you download/import on the new PC, $old shows 'NOT DECIDED': click it there and pick anyone's account or desktop, or a backup folder."
    }
    if (-not $t) { $rSelf.Checked = $true } elseif ($t.Kind -eq 'User') { $rUser.Checked = $true }
    elseif ($t.Kind -eq 'Backup' -or ($t.Kind -eq 'Later' -and $send)) { $rBak.Checked = $true }
    $tSelf.Add_Enter({ $rSelf.Checked = $true }); $cUser.Add_Enter({ $rUser.Checked = $true }); $tBak.Add_Enter({ $rBak.Checked = $true })
    $bBak.Add_Click({
        $rBak.Checked = $true
        $p = Select-NewPcFolder $tBak.Text.Trim() "Backup folder on the NEW PC (or a share). Each profile gets a subfolder: <folder>\<user>." $d
        if ($p) { $tBak.Text = $p }
    })
    $ok.Add_Click({
        $okName = '^[A-Za-z0-9._-]{1,64}$'   # what the sign-in handoff accepts
        if ($rSelf.Checked -and $tSelf.Text.Trim() -notmatch $okName) { [void][Windows.Forms.MessageBox]::Show('Type their user name (letters, digits, . _ -).', $MigToolName); return }
        if ($rUser.Checked) {
            $u = Get-HandoffUser $cUser.Text
            if ($u -notmatch $okName) { [void][Windows.Forms.MessageBox]::Show('Pick or type the user name of the person who gets the files.', $MigToolName); return }
            if ($u -eq $old) { [void][Windows.Forms.MessageBox]::Show("That is $old - pick 'Their own account' instead.", $MigToolName); return }
        }
        if (-not ($rSelf.Checked -or $rUser.Checked -or $rBak.Checked)) { [void][Windows.Forms.MessageBox]::Show('Pick one of the three.', $MigToolName); return }
        if ($rBak.Checked -and -not $send) {
            $p = $tBak.Text.Trim().TrimEnd('\'); if ($p -match '^[A-Za-z]:$') { $p += '\' }
            if ($p -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') { [void][Windows.Forms.MessageBox]::Show('Type or Browse to a folder (D:\Old Staff, or \\server\share\folder).', $MigToolName); return }
            if ($p -match '^[A-Za-z]:\\(Users|Windows|Program Files.*|Migration.*)$') { [void][Windows.Forms.MessageBox]::Show("Pick a folder outside $p (system folder).", $MigToolName); return }
            $tBak.Text = $p
        }
        $d.DialogResult = 'OK'
    })
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $targets = @($Row); if ($all.Checked) { $targets += @(Get-SelectedRows | Where-Object { $_ -ne $Row }) }
    foreach ($x in $targets) {
        $xo = Get-HandoffUser "$($x.Cells[1].Value)"
        if ($rSelf.Checked) {
            # the clicked row takes the typed name; the others go back to their own name
            if ($x -eq $Row) { $x.Cells[3].Value = $tSelf.Text.Trim() } elseif ($x.Tag) { $x.Cells[3].Value = $xo }
            $x.Tag = $null
        } elseif ($rUser.Checked) {
            $u = Get-HandoffUser $cUser.Text
            if ($u -eq $xo) { continue }   # (nobody replaces themselves)
            $x.Tag = @{ Kind = 'User'; User = $u }
        } elseif ($send) {
            $x.Tag = @{ Kind = 'Later' }
        } else {
            $x.Tag = @{ Kind = 'Backup'; Path = $tBak.Text }
            $script:backupPath = $tBak.Text; Save-Settings
        }
        Set-CopyIntoCell $x
        $x.Cells[0].Value = $true   # picking where it goes = you want it copied
    }
}
$grid.Add_CellClick({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { Show-CopyInto $grid.Rows[$e.RowIndex] } })
$grid.Add_CellMouseEnter({ param($s, $e) $grid.Cursor = if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default } })

# Editor for the sign-in question and the desktop folder name (both saved). Placeholders: {OldPC} {Folder} {User}.
$btnAskMsg.Add_Click({
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = 'Sign-in question and desktop folder'; ClientSize = (S 600 360); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font }
    $l1 = New-Object Windows.Forms.Label -Property @{ Text = 'Desktop folder name (used by "All in a desktop folder" and by the user''s second button):'; Location = (P 12 12); Size = (S 576 20) }
    $tName = New-Object Windows.Forms.TextBox -Property @{ Location = (P 12 34); Size = (S 300 23); Text = $script:backupName }
    $l2 = New-Object Windows.Forms.Label -Property @{ Text = 'Question shown to the user at sign-in ({OldPC} = old PC name, {Folder} = folder name above, {User} = their name):'; Location = (P 12 68); Size = (S 576 34) }
    $tMsg = New-Object Windows.Forms.TextBox -Property @{ Location = (P 12 104); Size = (S 576 170); Multiline = $true; ScrollBars = 'Vertical'; Text = $script:askMessage; AcceptsReturn = $true }
    $l3 = New-Object Windows.Forms.Label -Property @{ Text = 'Buttons the user sees:  [Place files in same locations]   [Place files in migration folder on my desktop]'; Location = (P 12 280); Size = (S 576 20); ForeColor = [Drawing.Color]::DimGray }
    $bDef = New-Object Windows.Forms.Button -Property @{ Text = 'Default text'; Location = (P 12 316); Size = (S 110 30) }
    $bOk = New-Object Windows.Forms.Button -Property @{ Text = 'Save'; Location = (P 418 316); Size = (S 80 30); DialogResult = 'OK' }
    $bNo = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 508 316); Size = (S 80 30); DialogResult = 'Cancel' }
    $bDef.Add_Click({ $tMsg.Text = $MigAskMessage; $tName.Text = $MigBackupName })
    $d.Controls.AddRange(@($l1, $tName, $l2, $tMsg, $l3, $bDef, $bOk, $bNo)); $d.CancelButton = $bNo
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $n = ($tName.Text -replace '[\\/:*?"<>|]', '').Trim()
    if ($n) { $script:backupName = $n }
    if ($tMsg.Text.Trim()) { $script:askMessage = $tMsg.Text.Trim() }
    Save-Settings
    Write-Log "Saved: desktop folder '$($script:backupName)' and the sign-in question."
})

$btnBrowse.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = if ($rbServer.Checked) { if ($rbOld.Checked) { 'Server folder for the upload (a <this PC>_<date> package is created in it). Network shares: type \\server\share in the box first, or open Network.' } else { 'The <OLD PC>_<date> package on the server (or the folder it is in)' } }
                     elseif ($rbOld.Checked) { 'External drive (a PCMigration-<this PC> folder is created on it)' } else { 'Drive or the PCMigration-<OLDPC> folder' }
    $cur = $txtDrive.Text.Trim(); if ($cur -and (Test-Path -LiteralPath $cur)) { $d.SelectedPath = $cur }
    if ($d.ShowDialog() -eq 'OK') { $txtDrive.Text = $d.SelectedPath }
})

# Small text prompt (folder name, password). -Confirm asks twice. Returns the text, or $null when cancelled.
function Show-Prompt([string]$Title, [string]$Label, [switch]$Password, [switch]$Confirm, [string]$Default = '') {
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = $Title; ClientSize = (S 420 $(if ($Confirm) { 190 } else { 140 })); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font }
    $l = New-Object Windows.Forms.Label -Property @{ Text = $Label; Location = (P 12 12); Size = (S 396 40) }
    $t1 = New-Object Windows.Forms.TextBox -Property @{ Location = (P 12 56); Size = (S 396 23); UseSystemPasswordChar = [bool]$Password; Text = $Default }
    $d.Controls.AddRange(@($l, $t1))
    $t2 = $null; $y = 96
    if ($Confirm) {
        $d.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = 'Type it again:'; Location = (P 12 90); AutoSize = $true }))
        $t2 = New-Object Windows.Forms.TextBox -Property @{ Location = (P 12 110); Size = (S 396 23); UseSystemPasswordChar = [bool]$Password }
        $d.Controls.Add($t2); $y = 146
    }
    $bOk = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = (P 238 $y); Size = (S 80 30); DialogResult = 'OK' }
    $bNo = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 328 $y); Size = (S 80 30); DialogResult = 'Cancel' }
    $d.Controls.AddRange(@($bOk, $bNo)); $d.AcceptButton = $bOk; $d.CancelButton = $bNo
    while ($true) {
        if ($d.ShowDialog($form) -ne 'OK') { return $null }
        if (-not $t1.Text) { continue }
        if ($t2 -and $t1.Text -cne $t2.Text) { [void][Windows.Forms.MessageBox]::Show('The two entries don''t match.', $Title); $t2.Text = ''; continue }
        return $t1.Text
    }
}

# Server login: \\server\share with the Admin user (section 1), like Connect... for a PC
$btnSrvConnect.Add_Click({
    $p = $txtDrive.Text.Trim().TrimEnd('\')
    if ($p -notmatch '^(\\\\[^\\]+\\[^\\]+)') { [void][Windows.Forms.MessageBox]::Show('Type the server folder first, e.g. \\server\share\Migrations', $MigToolName); return }
    $share = $Matches[1]
    $admin = $txtAdmin.Text.Trim()
    if ($admin -and $admin -notmatch '[\\@]' -and $script:adminDomain) { $admin = "$($script:adminDomain)\$admin" }
    $c = if ($admin) { Get-Credential -UserName $admin -Message "Login for $share" } else { Get-Credential -Message "Login for $share (e.g. DOMAIN\user)" }
    if (-not $c) { return }
    Set-Busy $true
    $err = Add-SmbLogin $share $c.UserName $c.GetNetworkCredential().Password
    Set-Busy $false
    if ($err -match '1219|multiple connections') { $err = "Windows is already logged in to that server as someone else. Close File Explorer windows on it (or sign out), then try again. ($err)" }
    if ($err) { Set-Conn "Can't log in to ${share}: $err" 'Firebrick'; return }
    $script:srvCred = $c
    if (Test-Path -LiteralPath $p) { Set-Conn "Connected to $share as $($c.UserName). $(if ($rbOld.Checked) { 'Now Scan profiles.' } else { 'Now Scan profiles (Browse to pick the package).' })" 'DarkGreen'; Save-Settings }
    else { Set-Conn "Connected to $share, but $p doesn't exist.$(if ($rbOld.Checked) { ' New folder... creates it.' })" 'DarkOrange' }
})

$btnSrvNew.Add_Click({
    $p = $txtDrive.Text.Trim().TrimEnd('\')
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
        # the typed folder doesn't exist yet: offer to create exactly that path
        if (-not $p) { [void][Windows.Forms.MessageBox]::Show('Type or Browse to the server folder to create the new folder in.', $MigToolName); return }
        if ([Windows.Forms.MessageBox]::Show("Create $p ?", 'New folder', 'YesNo', 'Question') -ne 'Yes') { return }
        $new = $p
    } else {
        $n = Show-Prompt 'New folder' "New folder in $p :" -Default 'PC Migrations'
        if (-not $n) { return }
        $n = ($n -replace '[\\/:*?"<>|]', '').Trim(); if (-not $n) { return }
        $new = Join-Path $p $n
    }
    try { New-Item -ItemType Directory -Force $new -ErrorAction Stop | Out-Null; $txtDrive.Text = $new; Set-Conn "Folder ready: $new" 'DarkGreen'; Write-Log "Created server folder $new" }
    catch { Set-Conn "Couldn't create ${new}: $($_.Exception.Message) - Connect... first?" 'Firebrick' }
})

# SMB login to \\host\share in the background (an unreachable PC can block this call ~30-60 s). Returns $null when it
# worked, else the error text. Cancel / 25 s give up without waiting.
function Add-SmbLogin([string]$Path, [string]$User, [string]$Password) {
    $r = Invoke-Bg -Script {
        param($core, $p, $u, $pw)
        Remove-SmbMapping -RemotePath $p -Force -ErrorAction SilentlyContinue
        New-SmbMapping -RemotePath $p -UserName $u -Password $pw -ErrorAction Stop | Out-Null
    } -ArgList @($Path, $User, $Password) -TimeoutSec 25 -Cancelable -Status "Logging in to $Path"
    $lblStatus.Text = ''
    if ($r.Cancelled) { return 'cancelled' }
    if ($r.TimedOut) { return "no answer from $Path in 25 s" }
    if ($r.Ok) { $script:mapped += $Path; return $null }
    $r.Error
}

# -Code: log in with the other PC's pairing login without asking (the automatic cable password). -Quiet: no error text.
function Connect-Other([string]$Code, [switch]$Quiet) {
    $pc = $txtPc.Text.Trim().TrimStart('\'); $share = $txtShare.Text.Trim().Trim('\')
    if (-not $pc) { [void][Windows.Forms.MessageBox]::Show('Type the other PC''s name or IP first.', $MigToolName); return $false }
    $useCode = [bool]$Code -or $script:cableOn
    if (-not $useCode) {
        # Network: admin login, or the code the other PC shows after "Allow access"
        $ans = [Windows.Forms.MessageBox]::Show("How do you want to connect to $pc?`r`n`r`nYes = my admin login$(if ($txtAdmin.Text.Trim()) { " ($(if ($txtAdmin.Text -notmatch '\\' -and $script:adminDomain) { "$($script:adminDomain)\" })$($txtAdmin.Text.Trim()))" })`r`nNo = the 4-character code shown on $pc (after Allow access there)", 'Connect', 'YesNoCancel', 'Question')
        if ($ans -eq 'Cancel') { return $false }
        $useCode = $ans -eq 'No'
    }
    if ($useCode) {
        # The other PC's temporary pairing login (its code is on its screen; on a cable usually the automatic one).
        if (-not $Code) {
            $typed = Read-Password "Code shown on the OTHER PC's screen (4 characters, e.g. 7Q4M):" -Plain
            if ($null -eq $typed) { return $false }
            $Code = Format-PairCode $typed
            if (-not $Code) { Set-Conn 'That is not a pairing code: it is 4 letters/digits, like 7Q4M.' 'Firebrick'; return $false }
        }
        $code = $Code
        $rn = if ($script:RemoteNames.ContainsKey($pc)) { $script:RemoteNames[$pc] } else {
            $q = Invoke-Bg -Script { param($core, $ip) . $core; Get-RemoteName $ip } -ArgList @($pc) -TimeoutSec 10 -Cancelable -Status 'Looking up the other PC''s name'
            $n = "$(@($q.Output) | Select-Object -Last 1)"; if ($n) { $script:RemoteNames[$pc] = $n }; $n }
        $names = @(); if ($rn) { $names += "$rn\$PairUser" }; $names += @($PairUser, "$pc\$PairUser")
        $last = ''
        foreach ($u in $names) {
            if ($script:cancel) { return $false }
            $path = "\\$pc\$share"
            $err = Add-SmbLogin $path $u (Get-PairPassword $code)
            if (-not $err) {
                $script:remoteCred = New-Object Management.Automation.PSCredential($u, (ConvertTo-SecureString (Get-PairPassword $code) -AsPlainText -Force))
                Set-Conn "Connected to $(if ($rn) { $rn } else { $pc })$(if ($script:cableOn) { ' over the cable' })." 'ForestGreen'; return $true
            }
            $last = $err
            if ($err -eq 'cancelled' -or $err -like 'no answer*') { break }   # another name won't help
        }
        if (-not $Quiet) { Set-Conn "Connect with code failed: $last  (Check the code on the other PC's screen; is its Allow access / Start cable link done?)" 'Firebrick' }
        return $false
    }
    # Admin user box: "jdoe" -> "<domain>\jdoe" (or "<other PC>\jdoe" off the domain); a name with \ or @ is used as typed.
    $admin = $txtAdmin.Text.Trim()
    if ($admin -and $admin -notmatch '[\\@]') { $admin = "$(if ($script:adminDomain) { $script:adminDomain } else { $pc })\$admin" }
    $msg = "Password for $(if ($admin) { $admin } else { 'an admin account' }) on $pc. (Local account instead? Use $pc\localadmin.)"
    $cred = if ($admin) { Get-Credential -UserName $admin -Message $msg } else { Get-Credential -Message $msg }
    if (-not $cred) { return $false }
    Save-Settings
    $pw = $cred.GetNetworkCredential().Password
    # A bare name ("localadmin") is ambiguous: try it as typed, then as a local account of the other PC.
    $names = @($cred.UserName); if ($cred.UserName -notmatch '[\\@]') { $names += "$pc\$($cred.UserName)" }
    # Windows allows one set of credentials per server name (error 1219, e.g. after Test connected as this PC's user).
    # The other PC's IP counts as a different server, so it's the fallback.
    $hosts = @($pc)
    if ($pc -notmatch '^\d+\.\d+\.\d+\.\d+$') { try { $hosts += @([Net.Dns]::GetHostAddresses($pc) | Where-Object AddressFamily -eq 'InterNetwork' | ForEach-Object IPAddressToString | Select-Object -First 1) } catch {} }
    $last = ''
    foreach ($h in $hosts) {
        foreach ($u in $names) {
            if ($script:cancel) { return $false }
            $path = "\\$h\$share"
            $err = Add-SmbLogin $path $u $pw
            if (-not $err) {
                $script:remoteCred = New-Object Management.Automation.PSCredential($u, $cred.Password)   # also used to set up the handoff there
                if ($h -ne $pc) { $txtPc.Text = $h }   # keep using the address that worked
                Set-Conn "Connected to $path as $u." 'ForestGreen'; return $true
            }
            $last = $err
            if ($err -eq 'cancelled') { return $false }
            if ($last -match '1219|multiple connections') { break }   # same server name: go straight to the IP
        }
    }
    $hint = if ($last -match 'password|logon|1326') { ' Check the password, and include the prefix (DOMAIN\you, or PCNAME\localadmin).' }
            elseif ($last -match '1219|multiple connections') { " Close other windows connected to $pc (or run: net use * /delete /y), then try again." }
            elseif ($last -match 'denied|1907|1909') { ' That account is not allowed (not an admin there, disabled, or must change its password).' } else { '' }
    Set-Conn "Connect failed: $last$hint" 'Firebrick'; return $false
}
$btnConnect.Add_Click({ if (Connect-Other) { $btnTest.PerformClick() } })

function Test-Other {
    $r = Get-Roots; if (-not $r) { return $false }
    Set-Conn "Testing $($r.Other)..."
    if ($r.Other -ne 'TEST' -and -not (Test-Port $r.Other 445 3000)) {
        Set-Conn "Can't reach $($r.Other) on port 445 (file sharing). Check the name/IP and cable; or click Allow access on $($r.Other) and connect with its code." 'Firebrick'; return $false
    }
    $chk = Invoke-Bg -Script { param($core, $p) Test-Path -LiteralPath $p } -ArgList @((Join-Path $r.Remote 'Users')) -TimeoutSec 25 -Cancelable -Status "Opening $($r.Remote)\Users"
    $lblStatus.Text = ''
    if (-not ($chk.Ok -and @($chk.Output)[-1] -eq $true)) {
        $why = if ($chk.Cancelled) { 'cancelled' } elseif ($chk.TimedOut) { 'no answer in 25 s' } else { 'access denied?' }
        Set-Conn "Reached $($r.Other) but can't open $($r.Remote)\Users ($why). Click Connect... (admin login), or Allow access on that PC and connect with its code." 'Firebrick'; return $false
    }
    $write = $false
    try { $tf = Join-Path $r.Remote "Windows\Temp\kitmig-$([guid]::NewGuid().ToString('n')).tmp"; [IO.File]::WriteAllText($tf, 'x'); Remove-Item -LiteralPath $tf -Force; $write = $true } catch {}
    $free = Get-FreeBytes $r.Dst
    $wifi = $r.Other -ne 'TEST' -and (Get-LinkMedium $r.Other) -eq 'Wi-Fi'
    Set-Conn "OK: $($r.Remote) readable$(if ($write) { ' and writable' } else { ' (write test failed)' }). Free on the new PC: $(if ($free -ge 0) { Format-Size $free } else { 'unknown' })$(if ($wifi) { '.  Over Wi-Fi: works, usually much slower than a cable.' })" 'ForestGreen'
    if ($wifi) { Write-Log "This PC reaches $($r.Other) over Wi-Fi - fine, but usually much slower than a cable. Big copy? Plug both into the network, or use Direct cable." }
    $true
}
$btnTest.Add_Click({ [void](Test-Other) })

# ---------- Direct cable ----------
# Undo everything this PC did for the cable (pairing login, sharing change, address, start-up safety task).
# Runs in the background (removing a login / re-enabling DHCP can take a while) - the window keeps responding.
function Stop-CableLink {
    $maps = @($script:mapped); $script:mapped = @()
    Set-Conn 'Putting the network back to normal...'
    $r = Invoke-Bg -Script {
        param($core, $maps)
        . $core
        foreach ($m in $maps) { Remove-SmbMapping -RemotePath $m -Force -ErrorAction SilentlyContinue }
        Stop-PairingHost; Restore-CableLink; Unregister-CableCleanup
    } -ArgList @(, $maps) -TimeoutSec 90 -Status 'Cleaning up'
    $lblStatus.Text = ''
    foreach ($m in @($r.Output)) { if ($m) { Write-Log $m } }
    if ($r.TimedOut) { Write-Log '! Clean-up is taking long; it continues in the background. Restarting this PC also finishes it.' }
    $script:cableOn = $false; $script:hostOn = $false; $script:pairCode = $null; $lblConn.Font = $form.Font
    Write-Log 'Cable link ended - this PC is back to its normal network settings.'
}

# Cancel when nothing is running = Reset: undo any cable link / Allow access and go back to a clean step 1.
function Reset-Window {
    if ($script:cableOn -or $script:hostOn -or (Test-Path $CableState) -or (Test-Path $PairState)) { Stop-CableLink }
    $grid.Rows.Clear(); $script:cancel = $false
    if ($rbCable.Checked) { $txtPc.Text = '' }
    $lblStatus.Text = 'Reset - start again from step 1.'
    Write-Log '--- Reset: clean slate ---'
    Update-ModeUi
}

# Before Start cable link: what will change on this PC, Continue / Cancel, "set it up by hand" link, "Don't ask again"
# (saved: CableNoAsk; Shift+click shows it again). Returns $true = go ahead.
$script:cableNoAsk = $false
function Show-CableManual($Owner) {
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = 'Direct cable by hand'; ClientSize = (S 540 400); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font; ShowInTaskbar = $false }
    $txt = "On BOTH PCs:`r`n" +
        "1. If the current IPv4 settings are not automatic, write them down.`r`n" +
        "2. Connect the two PCs with one Ethernet cable.`r`n" +
        "3. Open Network Connections  (or Win+R, ncpa.cpl, Enter).`r`n" +
        "4. Right-click Ethernet > Properties > Internet Protocol Version 4 (TCP/IPv4) > Properties.`r`n" +
        "5. Use the following IP address:  OLD PC 10.99.99.1,  NEW PC 10.99.99.2,  subnet mask 255.255.255.0.  Leave gateway and DNS empty.  OK, OK.`r`n`r`n" +
        "Then in MoveMate (How = Network on both):`r`n" +
        "6. OLD PC: click Allow access (code).`r`n" +
        "7. NEW PC: type 10.99.99.1, Connect... > No (code) > the code. Scan and copy as usual.`r`n`r`n" +
        "When done: IPv4 back to 'Obtain an IP address automatically' (or what you wrote down) on both PCs, and Stop allowing access on the old PC."
    $ll = New-Object Windows.Forms.LinkLabel -Property @{ Text = $txt; Location = (P 14 14); Size = (S 512 330); LinkBehavior = 'HoverUnderline' }
    $k = 'Open Network Connections'; [void]$ll.Links.Clear(); [void]$ll.Links.Add($txt.IndexOf($k), $k.Length, 'ncpa')
    $ll.Add_LinkClicked({ param($s, $e) Start-Process control.exe -ArgumentList 'ncpa.cpl' })
    $ok = New-Object Windows.Forms.Button -Property @{ Text = 'Close'; Location = (P 436 358); Size = (S 90 30); DialogResult = 'OK' }
    $d.Controls.AddRange(@($ll, $ok)); $d.AcceptButton = $ok; $d.CancelButton = $ok
    [void]$d.ShowDialog($Owner)
}
function Show-CableConfirm {
    if ($script:cableNoAsk -and -not ([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Shift)) { return $true }
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = 'Start cable link'; ClientSize = (S 500 250); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font; ShowInTaskbar = $false }
    $h1 = New-Object Windows.Forms.Label -Property @{ Text = 'This PC will switch to the cable.'; Location = (P 16 14); AutoSize = $true; Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) }
    $b1 = New-Object Windows.Forms.Label -Property @{ Location = (P 16 42); Size = (S 470 100)
        Text = "While the link is on, its Ethernet adapter uses a temporary address (10.99.99.x) instead of the normal network, and file sharing plus a temporary login let the other PC connect.`r`n`r`nAll of it goes back to how it was when you end the link, click Cancel, or restart the PC." }
    $lnk = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Rather set it up by hand?'; Location = (P 16 148); AutoSize = $true; LinkBehavior = 'HoverUnderline' }
    $lnk.Add_LinkClicked({ Show-CableManual $d })
    $cb = New-Object Windows.Forms.CheckBox -Property @{ Text = "Don't ask again"; Location = (P 16 212); AutoSize = $true }
    $go = New-Object Windows.Forms.Button -Property @{ Text = 'Continue'; Location = (P 300 206); Size = (S 90 30); DialogResult = 'OK' }
    $no = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 396 206); Size = (S 90 30); DialogResult = 'Cancel' }
    $d.Controls.AddRange(@($h1, $b1, $lnk, $cb, $go, $no)); $d.AcceptButton = $go; $d.CancelButton = $no
    $tips.SetToolTip($cb, 'Start cable link then switches straight away. Shift+click Start cable link to see this again.')
    if ($d.ShowDialog($form) -ne 'OK') { return $false }
    if ($cb.Checked -ne $script:cableNoAsk) { $script:cableNoAsk = $cb.Checked; Save-Settings }
    $true
}

# Setup runs in the background (it can stall on an offline PC); the window stays responsive and shows each step.
$btnCable.Add_Click({
    if ($rbCable.Checked -and -not $script:cableOn -and $script:fromNetwork -and -not $script:runningLocal) {
        [void][Windows.Forms.MessageBox]::Show("This tool is running from the network share ($($script:toolDir)). Once the cable replaces the network, the share is gone and the cable link would break half-way.`r`n`r`nClick 'Run from this PC (works offline)' (top right) on BOTH PCs first, then Start cable link in the window that opens.", 'Direct cable', 'OK', 'Warning')
        return
    }
    if ($rbNet.Checked) {
        # Network: let the other PC in with a code (temporary login + sharing), or stop doing so
        if ($script:hostOn) { $m = Stop-PairingHost; if ($m) { Write-Log $m }; $script:hostOn = $false; $lblConn.Font = $form.Font; Update-ModeUi; return }
        try {
            $code = Start-PairingHost
            $script:hostOn = $true
            $w = Get-SharingProblem; if ($w) { Write-Log "! THIS PC: $w" }
            $lblConn.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
            Write-Log "Temporary admin account '$PairUser' created on this PC (password = the code $code) - deleted by Stop allowing access or closing this window."
            Write-Log "Access allowed on $env:COMPUTERNAME with code $code."
            Update-ModeUi
            Set-Conn "THIS PC: $env:COMPUTERNAME   CODE: $code     On the other PC: type $env:COMPUTERNAME, click Connect... -> No (code) -> $code" 'DarkGreen'
        } catch { Set-Conn "Allow access failed: $($_.Exception.Message)" 'Firebrick' }
        return
    }
    if ($script:cableOn -and -not $script:busy) {   # button reads "End cable link"
        if ([Windows.Forms.MessageBox]::Show('End the cable link and put this PC''s network back to normal?', 'Direct cable', 'YesNo', 'Question') -eq 'Yes') { Stop-CableLink; Update-ModeUi }
        return
    }
    # (continuing a link left by an earlier window: already agreed to)
    if ($script:cableResume) { $script:cableResume = $false } elseif (-not (Show-CableConfirm)) { return }
    Set-Busy $true; $script:cancel = $false
    $role = $(if ($rbOld.Checked) { 'Old' } else { 'New' })
    $sync = [hashtable]::Synchronized(@{ Step = 'Starting...'; Done = $false; Error = $null; Ip = $null; Code = $null; Nic = $null; Warn = $null; Cancel = $false })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($core, $role, $sync)
        try {
            . $core
            # Waits up to 10 minutes: you can click Start first and swap the cables after.
            $nic = $null
            for ($i = 0; $i -lt 300 -and -not $nic -and -not $sync.Cancel; $i++) {
                try {
                    $nic = Find-CableAdapter
                    if (-not $nic) { $sync.Step = 'Step 1/4: waiting for the cable - plug ONE Ethernet cable straight between the two PCs (both on)' }
                } catch { $sync.Step = 'Step 1/4: still on the network - plug the PC-to-PC cable into this Ethernet port now' }
                if (-not $nic) { Start-Sleep 2 }
            }
            if ($sync.Cancel) { return }
            if (-not $nic) { throw 'No cable link after 10 minutes. Check the cable at both ends and that the other PC is on.' }
            $sync.Nic = "$($nic.Name) ($($nic.LinkSpeed))"
            $sync.Step = "Step 2/4: giving $($nic.Name) its temporary cable address"
            $sync.Ip = Enable-CableLink $nic $role
            $sync.Step = 'Step 3/4: start-up safety net (undo at next boot if this window is killed)'
            try { Register-CableCleanup } catch { $sync.Warn = "Start-up safety net not set ($($_.Exception.Message)). " }
            if ($sync.Cancel) { return }
            $sync.Step = 'Step 4/4: turning on file sharing and creating the temporary login'
            $sync.Code = Start-PairingHost -Auto   # fixed password unless this PC is also on another network
            $w = Get-SharingProblem; if ($w) { $sync.Warn += $w }
        } catch { $sync.Error = $_.Exception.Message } finally { $sync.Done = $true }
    }).AddArgument((Join-Path $PSScriptRoot 'MigrateCore.ps1')).AddArgument($role).AddArgument($sync)
    $h = $ps.BeginInvoke()
    $last = ''; $cancelAt = $null
    while (-not $sync.Done) {
        if ($sync.Step -ne $last) { $last = $sync.Step; Write-Log $last; $lblStatus.Text = 'Setting up the cable link...' }
        Set-Conn "$($sync.Step)   (Cancel to stop)"
        & $waitBlock | Out-Null
        if ($script:cancel -and -not $cancelAt) { $sync.Cancel = $true; $cancelAt = Get-Date; Write-Log 'Cancelling...' }
        # Stuck step: abandon it (BeginStop never blocks; Stop()/Dispose() would wait for the stuck call)
        if ($cancelAt -and ((Get-Date) - $cancelAt).TotalSeconds -gt 3) { Write-Log "Step stuck: '$last' - abandoned."; try { [void]$ps.BeginStop($null, $null) } catch {}; break }
    }
    if ($sync.Done) { try { $ps.Dispose() } catch {} }
    if ($sync.Ip) { $script:cableOn = $true }
    if ($sync.Error -or $script:cancel -or -not $sync.Code) {
        if ($sync.Error) { Set-Conn "Cable: $($sync.Error)" 'Firebrick'; Write-Log "Cable FAILED at: $last - $($sync.Error)" }
        Stop-CableLink   # never leave this PC on the cable address
        Set-Busy $false; return
    }
    $code = $sync.Code; $script:pairCode = $code; $ip = $sync.Ip
    $auto = $code -eq $PairAutoCode
    $show = if ($auto) { "$code (automatic - only needed if the other PC asks)" } else { "$code  (this PC is also on another network, so it uses a code)" }
    if ($sync.Warn) { Write-Log "! THIS PC: $($sync.Warn) The other PC may not reach this one (working FROM this PC still works)." }
    $lblConn.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    Write-Log "Temporary admin account '$PairUser' created on this PC for the cable link$(if ($auto) { ' (automatic login - deleted at once if this PC joins another network)' } else { " (password = the code $code)" }) - deleted when the link ends."
    Write-Log "Cable link on $($sync.Nic); this PC is $ip. Login for the other PC: $show"
    $other = $CableAddr[$(if ($role -eq 'Old') { 'New' } else { 'Old' })]
    $ok = $false; $t0 = Get-Date
    while (-not $ok -and -not $script:cancel -and ((Get-Date) - $t0).TotalMinutes -lt 20) {
        $ok = Test-Port $other 445 700
        if (-not $ok) {
            Set-Conn "CODE HERE: $code   Cable ready (this PC $ip). Waiting for the other PC at $other ($([int]((Get-Date) - $t0).TotalSeconds) s) - click Start cable link on it. Cancel to stop." 'DarkSlateBlue'
            for ($j = 0; $j -lt 6; $j++) { & $waitBlock | Out-Null }
        }
    }
    if (-not $ok) {
        Write-Log $(if ($script:cancel) { 'Cancelled while waiting for the other PC.' } else { "The other PC never answered at $other in 20 minutes." })
        Stop-CableLink; Set-Busy $false; return
    }
    $txtPc.Text = $other; $txtShare.Text = 'C$'
    Write-Log "Other PC found at $other. Connecting..."
    # Connect with the automatic password. A slow PC may still be finishing its setup: keep trying (status shown)
    # until it works or Cancel - no short time-out. After 1 minute, Enter code is also offered (the other PC shows its code).
    $connected = $false; $t1 = Get-Date
    while (-not $connected -and -not $script:cancel) {
        $connected = Connect-Other -Code $PairAutoCode -Quiet
        if ($connected) { break }
        $s = [int]((Get-Date) - $t1).TotalSeconds
        Set-Conn "CODE HERE: $code   Other PC found at $other - waiting for it to finish setting up ($s s). $(if ($s -ge 60) { 'If its screen shows a code other than AUTO, Cancel and use Enter code. ' })Cancel to stop." 'DarkSlateBlue'
        for ($j = 0; $j -lt 30; $j++) { & $waitBlock | Out-Null }
    }
    Set-Busy $false
    if ($connected -and (Test-Other)) {
        Write-Log 'Connected over the cable. Scanning profiles...'
        $btnScan.PerformClick()
        Set-Conn "CODE HERE: $code   Connected to the other PC over the cable. Pick profiles and Start copy here - or do it on the other PC (this one shows incoming copies)." 'DarkGreen'
    } else {
        Set-Conn "CODE HERE: $code   Not connected yet. Click Enter code and type the code shown on the other PC (AUTO if it shows AUTO). The other PC can still push files to this one." 'DarkGoldenrod'
    }
    $script:cancel = $false
})

# Receiving side: when the other PC pushes to this one, show it (SMB sessions/open files from the other PC), every 3 s.
$script:incoming = @{ Seen = $false; Quiet = 0 }
$inTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 3000 }
$inTimer.Add_Tick({
    if ($script:busy -or -not ($script:cableOn -or $script:hostOn)) { return }
    try {
        $sess = @(Get-SmbSession -ErrorAction Stop | Where-Object { $_.ClientUserName -match $PairUser -or $_.ClientComputerName -like '10.99.99.*' })
        $open = @(Get-SmbOpenFile -ErrorAction Stop | Where-Object { $_.ClientUserName -match $PairUser -or $_.ClientComputerName -like '10.99.99.*' })
    } catch { return }
    if ($open.Count) {
        if (-not $script:incoming.Seen) { Write-Log "Incoming copy from $($open[0].ClientComputerName) started." }
        $script:incoming.Seen = $true; $script:incoming.Quiet = 0
        $p = "$($open[-1].Path)"; if ($p.Length -gt 90) { $p = '...' + $p.Substring($p.Length - 87) }
        $lblStatus.Text = "Receiving: $($open.Count) file(s) open"
        Set-Conn "INCOMING COPY from $($open[0].ClientComputerName): writing $p" 'DarkGreen'
    } elseif ($script:incoming.Seen) {
        $script:incoming.Quiet++
        if ($script:incoming.Quiet -eq 10) {   # ~30 s with nothing open
            $w = @(Get-MigrationHandoff $env:SystemDrive | ForEach-Object User)
            Write-Log "Incoming copy looks finished (nothing written for 30 s).$(if ($w.Count) { " Waiting for first sign-in: $($w -join ', ')." }) See the summary on the other PC."
            $lblStatus.Text = 'Incoming copy finished.'
            Set-Conn "Incoming copy finished.$(if ($w.Count) { " Files wait in C:\Migration for: $($w -join ', ')." }) End cable link when the other PC is done." 'DarkGreen'
            $script:incoming.Seen = $false
        }
    } elseif ($sess.Count) { $lblStatus.Text = "Other PC connected ($($sess[0].ClientComputerName))" }
})
$inTimer.Start()

# Pairing watch, every 4 s (also while copying): the automatic cable login must never exist while this PC is on another
# network - Wi-Fi reconnecting mid-copy, a second cable. Assert-PairingOffline deletes it then. Starts only once the
# cable setup has finished ($script:pairCode set), so it never races the setup that creates the login.
$pairWatch = New-Object Windows.Forms.Timer -Property @{ Interval = 4000 }
$pairWatch.Add_Tick({
    if ($script:pairCode -ne $PairAutoCode) { return }
    $m = Assert-PairingOffline
    if (-not $m) { return }
    $script:pairCode = $null
    Write-Log $m
    Write-Log '  The other PC can no longer log in to this one (a copy running over the cable may stop). Disconnect the other network (or forget the Wi-Fi), then End cable link and Start cable link again.'
    Set-Conn 'Temporary login deleted: this PC joined another network. Disconnect it, then End cable link and Start cable link again.' 'Firebrick'
})
$pairWatch.Start()

# ---------- Update check: in the background at start (Advanced > Updates, on by default) and 'Check now' there ----------
# A newer GitHub release makes the Advanced... button blink until Advanced is opened. Offline / blocked: nothing happens.
$script:update = $null; $script:updJob = $null; $script:blink = $false
$advBlink = New-Object Windows.Forms.Timer -Property @{ Interval = 600 }
$advBlink.Add_Tick({
    $script:blink = -not $script:blink
    if ($script:blink) { $btnAdv.BackColor = [Drawing.Color]::Gold } else { $btnAdv.BackColor = [Drawing.SystemColors]::Control }
})
function Stop-AdvBlink { $advBlink.Stop(); $script:blink = $false; $btnAdv.BackColor = [Drawing.SystemColors]::Control; $btnAdv.UseVisualStyleBackColor = $true }
function Show-UpdateAvailable($R) {
    $script:update = $R
    Write-Log "Update available: $MigToolName $($R.Version) (this copy is $MigToolVersion) - see Advanced... > Updates."
    $howTips.SetToolTip($btnAdv, "$MigToolName $($R.Version) is available (this copy is $MigToolVersion). Open Advanced... > Updates.")
    $advBlink.Start()
}
$updTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 500 }
$updTimer.Add_Tick({
    $j = $script:updJob
    if (-not $j.H.IsCompleted) {
        if (((Get-Date) - $j.T0).TotalSeconds -gt 20) { $updTimer.Stop(); try { [void]$j.Ps.BeginStop($null, $null) } catch {} }   # abandon, don't wait
        return
    }
    $updTimer.Stop()
    $r = try { @($j.Ps.EndInvoke($j.H))[0] } catch { $null }
    $j.Ps.Dispose()
    if ($r -and $r.Newer) { Show-UpdateAvailable $r }
})
function Start-UpdateCheck {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ param($core) . $core; Get-MigLatestRelease }).AddArgument($script:corePath)
    $script:updJob = @{ Ps = $ps; H = $ps.BeginInvoke(); T0 = Get-Date }
    $updTimer.Start()
}

$btnScan.Add_Click({
    $r = Get-Roots; if (-not $r) { return }
    $grid.Rows.Clear()
    $sending = $r.Mode -in 'Export', 'Upload'
    $srcUsers = Join-Path $r.Src 'Users'
    $hdr = $r.Header
    if ($hdr) {
        $p = if ($hdr.Protection -eq 'None') { 'not encrypted' } elseif ($hdr.Protection -eq 'Key') { 'encrypted, key file' } else { 'encrypted, password' }
        Write-Log "Package $(Split-Path $r.Src -Leaf): from $($hdr.OldPC), uploaded $($hdr.Created -replace 'T', ' '), $($hdr.FileCount) files, $(Format-Size ([long]$hdr.TotalBytes)), $p."
        if (-not $hdr.Complete) { Write-Log '! This upload was CANCELLED part-way - it does not hold everything. Upload again from the old PC if you can.' }
        if ($hdr.Protection -ne 'None') {
            if ($script:pkgKeys -and (Get-PkgVerifier $script:pkgKeys) -eq $hdr.Verifier) { Write-Log 'Unlocked with the restore key.' }
            elseif ($hdr.Protection -eq 'Key') { Write-Log 'Locked: needs its restore key (asked for at Start).' }
            else { Write-Log 'Locked: the password is asked for at Start.' }
        }
    }
    # Encrypted package: names are only in its header (the files are numbered blobs)
    # @( ) around the whole if: one profile alone would come back as a bare object, which has no .Count in PowerShell 5.1
    $profiles = @(if ($hdr -and $hdr.Protection -ne 'None') { $hdr.Users | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = ''; LastUsed = [datetime]$hdr.Created } } }
                  else { Get-MigrationProfiles $srcUsers })
    if (-not $profiles.Count) { Write-Log "No user profiles found in $srcUsers (wrong PC/folder, or no access - try Test)."; return }
    $dstUsers = Join-Path $r.Dst 'Users'
    $dstOk = (-not $sending) -and (Test-Path -LiteralPath $dstUsers)
    # "Copy into": the user's profile on the new PC if it exists, else their user name (jsmith.DOMAIN -> jsmith).
    # Primary user (clone first sign-in) goes to the most recently used profile that has no match, unless a name already matches.
    $pending = @(); if (-not $sending) { $pending = @(Get-MigrationHandoff $r.Dst | ForEach-Object User) }
    $pu = $PrimaryUser; if (-not $pu -and $pending.Count -eq 1) { $pu = $pending[0] }
    $puUsed = [bool]($pu -and @($profiles | Where-Object { (Get-HandoffUser $_.Name) -eq $pu }).Count)
    if ($pending.Count) { Write-Log "Already waiting on the new PC (handoff): $($pending -join ', ')" }
    foreach ($p in $profiles) {
        $d = $null; if ($dstOk) { $d = Resolve-DestProfile $dstUsers $p.Name }
        $found = [bool]$d
        if (-not $d) { if ($pu -and -not $puUsed) { $d = $pu; $puUsed = $true } else { $d = Get-HandoffUser $p.Name } }
        $status = if ($r.Mode -eq 'Export') { "to drive: $($r.Dst)" }
                  elseif ($r.Mode -eq 'Upload') { "to server: $($r.Dst)" }
                  elseif ($found) { 'profile found on new PC' }
                  elseif ($dstOk -or $r.Mode -in 'Import', 'Download') { "no profile yet: waits in C:\Migration\$d, moves in at their first sign-in" }
                  else { 'new PC not reachable yet' }
        [void]$grid.Rows.Add($false, $p.Name, $p.LastUsed.ToString('yyyy-MM-dd HH:mm'), "$d", $status)
    }
    # Choices made on the old PC (copy-into.json in the drive folder / server package): filled in, still changeable
    if ($r.Mode -in 'Import', 'Download') {
        $into = Read-CopyInto $r.Src; $told = @()
        foreach ($row in $grid.Rows) {
            $n = "$($row.Cells[1].Value)"; $c = $into[$n]; if (-not $c) { continue }
            if ($c.Kind -eq 'Self') { if ($c.User -eq (Get-HandoffUser $n)) { continue }; $row.Cells[3].Value = $c.User }   # (only a changed name)
            else { $row.Tag = $c }
            Set-CopyIntoCell $row
            $told += "$n -> $(if ($c.Kind -eq 'Later') { 'not decided' } else { $c.User })"
        }
        if ($told.Count) { Write-Log "Copy into, as picked on the old PC: $($told -join '; '). Click a blue name to change." }
    }
    Write-Log "Found $($profiles.Count) profile(s) in $(if ($hdr) { 'the package' } else { $srcUsers })."
})

function Get-MaxBytes { if ($rbDrive.Checked -or $rbServer.Checked -or -not $cbLarge.Checked) { $NoLimit } else { [long]$numMax.Value * 1MB } }
$cbLarge.Add_CheckedChanged({ Update-ModeUi })

$btnPreview.Add_Click({
    $r = Get-Roots; if (-not $r) { return }
    $rows = Get-SelectedRows
    if (-not $rows.Count) { [void][Windows.Forms.MessageBox]::Show('Scan, then tick at least one profile.', $MigToolName); return }
    if ($r.Mode -eq 'Download') {
        $need = Get-PkgSpaceNeeded $r.Header @($rows | ForEach-Object { "$($_.Cells[1].Value)" })
        foreach ($u in @($r.Header.Users | Where-Object { $need.Names -contains $_.Name })) { Write-Log ("   {0,-22} {1,8} files  {2,10}" -f $u.Name, $u.Files, (Format-Size ([long]$u.Bytes))) }
        $free = Get-FreeBytes $env:SystemDrive
        Write-Log ("TOTAL to download: {0}. Needs {1} free on {2}{3}. Free: {4}" -f (Format-Size $need.Bytes), (Format-Size $need.Needed), $env:SystemDrive, $(if ($need.Staged) { ' (decrypted next to the final copy first)' }), $(if ($free -ge 0) { Format-Size $free } else { 'unknown' }))
        if ($free -ge 0 -and $need.Needed -gt $free) { Write-Log '!! NOT ENOUGH SPACE on this PC for this selection.' }
        return
    }
    $max = Get-MaxBytes
    Set-Busy $true; $script:cancel = $false
    $total = [long]0; $bigTotal = [long]0; $bigCount = 0
    foreach ($row in $rows) {
        $name = "$($row.Cells[1].Value)"; $src = Join-Path (Join-Path $r.Src 'Users') $name
        Write-Log "== $name"
        foreach ($rel in (Get-FolderList $src)) {
            if ($script:cancel) { break }
            $s = Join-Path $src $rel
            if (-not (Test-Path -LiteralPath $s)) { continue }
            $lblStatus.Text = "Measuring $name\$rel ..."; [Windows.Forms.Application]::DoEvents()
            $st = Get-FolderStats $s $max; $total += $st.Bytes
            Write-Log ("   {0,-22} {1,8} files  {2,10}" -f $rel, $st.Files, (Format-Size $st.Bytes))
            if ($max -lt $NoLimit) { foreach ($b in @(Get-LargeFiles $s $max)) { $bigCount++; $bigTotal += $b.Bytes; Write-Log "      large: $(Format-Size $b.Bytes)  $($b.Path)" } }
        }
    }
    $free = Get-FreeBytes $r.Dst
    Write-Log ("TOTAL to copy: {0}.  Large files set aside: {1} ({2}).  Free at destination: {3}" -f (Format-Size $total), $bigCount, (Format-Size $bigTotal), $(if ($free -ge 0) { Format-Size $free } else { 'unknown' }))
    if ($free -ge 0 -and $total -gt $free) { Write-Log '!! NOT ENOUGH SPACE at the destination for this selection.' }
    $lblStatus.Text = 'Preview done.'
    Set-Busy $false
})

# Size of what will be copied, per user\folder (robocopy /L): @{ Bytes; Files; Parts } - Parts keyed by the robocopy log
# name Invoke-ProfileMigration uses (<user>.<folder>.log), for the Current progress bar. -AllFolders = every folder there
# (a server package / staging copy holds only what was uploaded).
function Measure-Selection([string]$Root, [string[]]$Users, [bool]$AllFolders) {
    $res = @{ Bytes = [long]0; Files = 0; Parts = @{} }
    $prgBar.Style = 'Marquee'; $lblProg.Text = 'Measuring...'
    foreach ($u in $Users) {
        $src = Join-Path (Join-Path $Root 'Users') $u
        $folders = if ($AllFolders) { @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object Name) } else { @(Get-FolderList $src) }
        foreach ($rel in $folders) {
            if ($script:cancel) { break }
            $s = Join-Path $src $rel; if (-not (Test-Path -LiteralPath $s)) { continue }
            $lblStatus.Text = "Measuring $u\$rel ..."; [Windows.Forms.Application]::DoEvents()
            $st = Get-FolderStats $s (Get-MaxBytes)
            $res.Bytes += $st.Bytes; $res.Files += $st.Files
            $res.Parts[('{0}.{1}.log' -f $u, ($rel -replace '[\\/:*?"<>| ]', '_'))] = @{ Bytes = $st.Bytes; Label = "$u\$rel" }
        }
    }
    $prgBar.Style = 'Continuous'; $lblProg.Text = ''; $lblStatus.Text = ''
    $res
}

# ---------- Server offload helpers ----------
# Space a download needs on C:. Encrypted = decrypted to a staging folder first, then copied into place (2x).
function Get-PkgSpaceNeeded($Hdr, [string[]]$Names) {
    $bytes = [long](($Hdr.Users | Where-Object { $Names -contains $_.Name } | ForEach-Object { [long]$_.Bytes } | Measure-Object -Sum).Sum)
    $staged = $Hdr.Protection -ne 'None'
    @{ Names = $Names; Bytes = $bytes; Staged = $staged; Needed = [long]($bytes * $(if ($staged) { 2 } else { 1 }) * 1.02 + 200MB) }
}

# Runs an encrypt/decrypt job in the background with live progress. The script block gets (core path, sync, args...).
# Cancel asks it to stop after the current file (never abandoned half-way: the package/staging must stay consistent).
function Invoke-PkgJob([scriptblock]$Script, [object[]]$ArgList, [string]$Verb) {
    $sync = [hashtable]::Synchronized(@{ Step = ''; Done = [long]0; Total = [long]0; Cancel = $false; FileDone = [long]0; FileTotal = [long]0 })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script).AddArgument($script:corePath).AddArgument($sync)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $h = $ps.BeginInvoke(); $t0 = Get-Date
    while (-not $h.IsCompleted) {
        if ($script:cancel -and -not $sync.Cancel) { $sync.Cancel = $true; Write-Log 'Stopping after the current file...' }
        # Total moves inside big files too (Done = finished files, FileDone = the file being processed)
        Set-Progress ([long]$sync.Done + [long]$sync.FileDone) ([long]$sync.Total)
        $step = "$($sync.Step)" -replace '^(Encrypting|Decrypting|Listing) ', ''
        Set-Current ([long]$sync.FileDone) ([long]$sync.FileTotal) $step
        [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150
    }
    $res = @{ Output = $null; Error = $null; Seconds = ((Get-Date) - $t0).TotalSeconds }
    try { $res.Output = @($ps.EndInvoke($h))[-1] } catch { $res.Error = $_.Exception.InnerException.Message; if (-not $res.Error) { $res.Error = $_.Exception.Message } }
    foreach ($e in $ps.Streams.Error) { Write-Log "  (note) $e" }
    $ps.Dispose(); $lblStatus.Text = ''
    $res
}

# Restore key file -> @{ Info; Keys } (Keys only for Key protection). Throws if it isn't one.
function Read-RestoreKey([string]$Path) {
    $k = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($k.Format -ne 'MigrateUserFiles-Key') { throw "$Path is not a $MigToolName restore key." }
    @{ Info = $k; Keys = $(if ($k.Key) { Get-PkgKeys ([Convert]::FromBase64String($k.Key)) } else { $null }) }
}

# Keys for an encrypted download: the restore key it was opened with, a picked .key file, or the password. $null = cancelled.
function Get-DownloadKeys($Hdr) {
    if ($script:pkgKeys -and (Get-PkgVerifier $script:pkgKeys) -eq $Hdr.Verifier) { return $script:pkgKeys }
    if ($Hdr.Protection -eq 'Key') {
        while ($true) {
            [void][Windows.Forms.MessageBox]::Show("This upload from $($Hdr.OldPC) is locked with a key file. Pick its `"Restore $($Hdr.OldPC) ....key`" (saved on the stick at upload).", 'Restore key')
            $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Restore key (*.key)|*.key'; Title = "Restore key for $($Hdr.OldPC)" }
            $kd = Join-Path $script:toolDir 'keys'; if (Test-Path -LiteralPath $kd) { $d.InitialDirectory = $kd }
            if ($d.ShowDialog() -ne 'OK') { return $null }
            try { $k = Read-RestoreKey $d.FileName } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Restore key'); continue }
            if ($k.Keys -and (Get-PkgVerifier $k.Keys) -eq $Hdr.Verifier) { $script:pkgKeys = $k.Keys; $script:keyPath = $d.FileName; return $k.Keys }
            [void][Windows.Forms.MessageBox]::Show('That key is for a different upload.', 'Restore key')
        }
    }
    $salt = [Convert]::FromBase64String($Hdr.Salt)
    while ($true) {
        $pw = Show-Prompt 'Password' "Password for the upload from $($Hdr.OldPC) ($($Hdr.Created -replace 'T', ' ')):" -Password
        if ($null -eq $pw) { return $null }
        $lblStatus.Text = 'Checking password...'; [Windows.Forms.Application]::DoEvents()
        $keys = Get-PkgKeys (Get-PkgMasterFromPassword $pw $salt); $lblStatus.Text = ''
        if ((Get-PkgVerifier $keys) -eq $Hdr.Verifier) { $script:pkgKeys = $keys; return $keys }
        [void][Windows.Forms.MessageBox]::Show('Wrong password.', 'Password')
    }
}

# After an upload: 'Restore <OLDPC> <date>.key' + '.cmd' (same name). The .cmd finds the tool (this stick, any drive, or
# the copy on C:) and opens it on the NEW PC ready to download - and, for Key protection, to unlock - that package.
function Save-RestoreKey([string]$Pkg, [string]$Protection, [byte[]]$Master, [string[]]$Users, [switch]$Auto) {
    $name = "Restore $env:COMPUTERNAME $(Get-Date -Format 'yyyy-MM-dd HHmm')"
    $kd = Join-Path $script:toolDir 'keys'
    if (-not $script:runningLocal) { New-Item -ItemType Directory -Force $kd -ErrorAction SilentlyContinue | Out-Null }
    if ($Auto) {
        # walk-away: no one to answer a Save dialog -> the stick's keys folder (or C:\Migration-Keys when run from C:)
        if ($script:runningLocal -or -not (Test-Path -LiteralPath $kd)) { $kd = Join-Path $env:SystemDrive 'Migration-Keys'; New-Item -ItemType Directory -Force $kd | Out-Null }
        $d = @{ FileName = (Join-Path $kd "$name.key") }
    }
    else { while ($true) {
        $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'Restore key (*.key)|*.key'; FileName = "$name.key"; Title = 'Save the restore key (keep it on your stick)'; OverwritePrompt = $true }
        if (Test-Path -LiteralPath $kd) { $d.InitialDirectory = $kd }
        if ($d.ShowDialog() -eq 'OK') { break }
        if ($Protection -ne 'Key') { return $null }
        if ([Windows.Forms.MessageBox]::Show("Without the key file NOBODY can open this upload (it is encrypted with a random key that is not stored anywhere else).`r`n`r`nSave it now?", 'Restore key', 'YesNo', 'Warning') -ne 'Yes') {
            Write-Log "! Restore key NOT saved - the upload in $Pkg can't be opened. Delete it and upload again."; return $null
        }
    } }
    $keyFile = $d.FileName; $cmd = [IO.Path]::ChangeExtension($keyFile, '.cmd')
    [ordered]@{ Format = 'MigrateUserFiles-Key'; Version = 1; Package = $Pkg; Protection = $Protection
        Key = $(if ($Protection -eq 'Key') { [Convert]::ToBase64String($Master) } else { '' }); OldPC = $env:COMPUTERNAME; Users = $Users; Created = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content -LiteralPath $keyFile -Encoding UTF8
    $c = @(
        '@echo off'
        "rem Restore $env:COMPUTERNAME's files ($MigToolName, server offload). Double-click on the NEW PC: opens the tool"
        "rem ready to download $Pkg$(if ($Protection -eq 'Key') { ' and unlock it. KEEP PRIVATE: with the .key next to it, it opens the upload.' } else { '.' })"
        'set "KEY=%~dpn0.key"'
        'set "PS1="'
        'for %%P in ("%~dp0..\scripts\Migrate-UserFiles.ps1" "%~dp0scripts\Migrate-UserFiles.ps1") do if not defined PS1 if exist %%P set "PS1=%%~fP"'
        'if not defined PS1 for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do for %%S in ("%%D:\MoveMate" "%%D:\Tools\MoveMate") do if not defined PS1 if exist "%%~S\scripts\Migrate-UserFiles.ps1" set "PS1=%%~S\scripts\Migrate-UserFiles.ps1"'
        'if not defined PS1 if exist "%ProgramFiles%\MoveMate\scripts\Migrate-UserFiles.ps1" set "PS1=%ProgramFiles%\MoveMate\scripts\Migrate-UserFiles.ps1"'
        "if not defined PS1 (echo $MigToolName not found - plug in the stick that has the tool, then run this again. & pause & exit /b 1)"
        'start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%" -Method Server -Role New -KeyFile "%KEY%"'
    )
    [IO.File]::WriteAllLines($cmd, $c, [Text.Encoding]::ASCII)
    Write-Log "Restore key saved: $cmd (+ .key). On the NEW PC double-click it$(if ($Protection -eq 'Password') { ' and type the password' })."
    $cmd
}

# Step-by-step restore instructions for an upload (popup on the old PC + 'HOW TO RESTORE.txt' in the package). No secrets.
function Get-RestoreInstructions([string]$Pkg, [string]$Protection, [string]$KeyCmd) {
    $old = $env:COMPUTERNAME
    $unlock = @{ None = ''; Key = ' and unlocks it'; Password = '' }[$Protection]
    $L = @("HOW TO RESTORE $old's FILES ON THE NEW PC", '', "Upload: $Pkg", "Protection: $(@{ None = 'none (not encrypted)'; Key = 'AES-256, restore key file'; Password = 'AES-256, password' }[$Protection])", '')
    if ($KeyCmd) {
        $L += 'EASIEST - with the restore key:'
        $L += "  1. Sign in on the NEW PC (your admin account) and plug in the stick with the restore key."
        $L += "  2. Double-click  $(Split-Path $KeyCmd -Leaf)  and approve the admin prompt."
        $L += "     It's in the keys folder on your stick (on this PC that was $(Split-Path $KeyCmd))."
        $L += "  3. $MigToolName opens on this upload$unlock and lists its users. Can't reach the server? Click Connect... and log in."
        $L += '  4. Tick who to restore, pick section 4 (where the files go). "Copy into" shows what was picked at upload; click it to change'
        $L += '     (their own account / someone else''s desktop / a backup folder). NOT DECIDED rows must be picked before Start.'
        $L += "  5. Start copy.$(if ($Protection -eq 'Password') { ' Type the upload password when asked.' })"
        $L += ''
        $L += 'OR BY HAND:'
    } else { $L += 'STEPS:' }
    $L += "  1. Start $MigToolName on the NEW PC ($MigToolName.cmd, from the stick or the network share)."
    $L += '  2. How: Server offload.   This PC is: the NEW PC (receive files).'
    $L += "  3. Server folder: type or Browse... to  $Pkg"
    $L += '     Not opening? Click Connect... and log in with your admin user, then try again.'
    $L += '  4. Scan profiles, tick who to restore, pick section 4 (where the files go); "Copy into" shows what was picked at upload - click to change.'
    $L += "  5. Start copy.$(switch ($Protection) { 'Key' { ' When asked, pick the restore key file (.key from the stick).' } 'Password' { ' Type the upload password when asked.' } default { '' } })"
    $L += ''
    $L += 'Every file is checked. When ALL users of this upload are restored without errors, the upload is deleted from the'
    $L += 'server (and its restore key from the stick). Otherwise both are kept, and the summary says why.'
    $L -join "`r`n"
}

function Invoke-StartCopy([bool]$Walk) {
    $r = Get-Roots; if (-not $r) { return }
    $rows = Get-SelectedRows
    if (-not $rows.Count) { [void][Windows.Forms.MessageBox]::Show('Scan, then tick at least one profile.', $MigToolName); return }
    $net = $r.Mode -eq 'Push' -or $r.Mode -eq 'Pull'
    $sending = $r.Mode -in 'Export', 'Upload'          # to a drive/server: no new PC yet
    $server = $r.Mode -in 'Upload', 'Download'
    $hdr = $r.Header
    $prot = if ($r.Mode -eq 'Upload') { @('None', 'Key', 'Password')[$cmbProt.SelectedIndex] } elseif ($hdr) { "$($hdr.Protection)" } else { '' }
    $enc = $server -and $prot -ne 'None'
    $userNames = [string[]]@($rows | ForEach-Object { "$($_.Cells[1].Value)" })
    $over = @('Move', 'Copy', 'List')[$cmbOver.SelectedIndex]
    $ask = $rbAsk.Checked -and -not $sending
    # Ask: everyone is staged in C:\Migration with the same-folders layout; the user's answer decides where it goes
    $target = if ($sending) { 'Mirror' } elseif ($ask -or $rbMigration.Checked) { 'Migration' } else { 'Profile' }
    $layout = if ($ask -or $sending) { 'Same' } elseif ($rbBackup.Checked) { 'Backup' } elseif ($rbOther.Checked) { 'Other' } else { 'Same' }
    $otherRoot = $null
    if ($layout -eq 'Other') {
        if (-not $script:otherPath -and -not (Select-OtherPath)) { return }
        $otherRoot = Resolve-OtherRoot $script:otherPath $r
        try { New-Item -ItemType Directory -Force $otherRoot -ErrorAction Stop | Out-Null }
        catch { [void][Windows.Forms.MessageBox]::Show("Can't use $($script:otherPath) on the new PC ($otherRoot):`r`n$($_.Exception.Message)", 'Other location'); return }
    }
    # "Copy into" choices per profile (Show-CopyInto). Sending to a drive/server: saved with the copy (copy-into.json), used on the new PC.
    $undecided = @($rows | Where-Object { -not $sending -and $_.Tag -and $_.Tag.Kind -eq 'Later' } | ForEach-Object { "$($_.Cells[1].Value)" })
    if ($undecided.Count) { [void][Windows.Forms.MessageBox]::Show("Pick who gets these files first - click their blue 'Copy into':`r`n  $($undecided -join "`r`n  ")", $MigToolName); return }
    $rowInto = @{}; $bakRoots = @{}
    foreach ($row in $rows) {
        $ci = if ($sending) { $null } else { $row.Tag }
        $rowInto["$($row.Cells[1].Value)"] = $ci
        if ($ci -and $ci.Kind -eq 'Backup' -and -not $bakRoots.ContainsKey($ci.Path)) {
            $br = Resolve-OtherRoot $ci.Path $r
            try { New-Item -ItemType Directory -Force $br -ErrorAction Stop | Out-Null; $bakRoots[$ci.Path] = $br }
            catch { [void][Windows.Forms.MessageBox]::Show("Can't use the backup folder $($ci.Path) ($br):`r`n$($_.Exception.Message)", $MigToolName); return }
        }
    }
    $names = ($rows | ForEach-Object {
        $p = "$($_.Cells[1].Value)"; $ci = $rowInto[$p]
        if ($sending -and $_.Tag -and $_.Tag.Kind -eq 'User') { "  $p  ->  on the new PC: $($_.Tag.User)'s desktop, folder '$(Get-ReplaceFolderName $p)'" }
        elseif ($sending -and $_.Tag -and $_.Tag.Kind -eq 'Later') { "  $p  (who gets them: decided on the new PC)" }
        elseif ($ci -and $ci.Kind -eq 'User') { "  $p  ->  $($ci.User)'s desktop, folder '$(Get-ReplaceFolderName $p)'" }
        elseif ($ci) { "  $p  ->  BACKUP ONLY: $($ci.Path.TrimEnd('\'))\$(Get-HandoffUser $p)  (no receipt, no sign-in handoff)" }
        else { "  $p" }
    }) -join "`r`n"
    $to = if ($layout -eq 'Other') { "$($script:otherPath)\<user>  (on the NEW PC; the receipt goes on each user's desktop)" }
          elseif ($target -eq 'Migration') { "$($r.Dst)\Migration\<user>" } else { "$($r.Dst)\Users\<profile>" }
    $protText = @{ None = 'not encrypted'; Key = 'encrypted, unlocked by the restore key'; Password = 'encrypted with a password' }[$prot]

    # Server offload: space check, keys / password - all before Start, so nothing waits on a question later (walk-away)
    $keys = $null; $master = $null; $salt = $null
    if ($r.Mode -eq 'Upload') {
        Set-Busy $true
        $meas = Measure-Selection $r.Src $userNames $false
        Set-Busy $false
        $t = $meas.Bytes; $nf = $meas.Files
        $need = [long]($t * 1.02 + $nf * 64 + 100MB)
        $free = Get-FreeBytes $r.Server
        Write-Log "Upload size: $nf files, $(Format-Size $t). Free on the server: $(if ($free -ge 0) { Format-Size $free } else { 'unknown' })."
        if ($free -ge 0 -and $need -gt $free) { [void][Windows.Forms.MessageBox]::Show("Not enough space on the server: this upload needs about $(Format-Size $need), $(Format-Size $free) is free in $($r.Server).`r`n`r`nPick another folder, or fewer profiles/folders.", $MigToolName); return }
        if ($prot -eq 'Key') { $master = New-PkgMaster }
        if ($prot -eq 'Password') {
            $pw = Show-Prompt 'Upload password' 'Password for this upload (you type it again on the NEW PC to download - it is not stored anywhere):' -Password -Confirm
            if ($null -eq $pw) { return }
            $salt = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
            $master = Get-PkgMasterFromPassword $pw $salt; $pw = $null
        }
        if ($master) { $keys = Get-PkgKeys $master }
        $to = "$($r.Dst)  ($protText)"
    }
    if ($r.Mode -eq 'Download') {
        if (-not $hdr.Complete -and [Windows.Forms.MessageBox]::Show('This upload was cancelled part-way on the old PC, so it is incomplete. Download what it has anyway?', $MigToolName, 'YesNo', 'Warning') -ne 'Yes') { return }
        $need = Get-PkgSpaceNeeded $hdr $userNames
        $free = Get-FreeBytes $env:SystemDrive
        if ($free -ge 0 -and $need.Needed -gt $free) { [void][Windows.Forms.MessageBox]::Show("Not enough space on this PC: needs about $(Format-Size $need.Needed)$(if ($need.Staged) { ' (encrypted uploads are unpacked next to the final copy first)' }), $(Format-Size $free) is free on $env:SystemDrive.", $MigToolName); return }
        if ($enc) { $keys = Get-DownloadKeys $hdr; if (-not $keys) { return } }
    }

    $fromText = if ($r.Mode -eq 'Download') { "$($r.Src)  (upload from $($hdr.OldPC), $protText)" } else { "$($r.Src)\Users" }
    # Check before starting: sign-ins / file-locking apps on the old PC, and room on the destination
    $pre = Get-Preflight $r $userNames
    if ($pre.Stop) { [void][Windows.Forms.MessageBox]::Show($pre.Stop, $MigToolName, 'OK', 'Warning'); return }
    $msg = "Copy these profile(s)`r`n$names`r`n`r`nFROM $fromText`r`nTO   $to`r`n`r`n"
    if ($script:retryRun) { $msg = "RETRY: only files that are missing or changed are copied again (the ones that failed).`r`n`r`n" + $msg }
    if ($pre.Lines.Count) { $msg += "CHECK FIRST:`r`n" + (($pre.Lines | ForEach-Object { "  - $_" }) -join "`r`n") + "`r`n`r`n" }
    if ($net -and $over -eq 'Move' -and (Get-MaxBytes) -lt $NoLimit) { $msg += "Files over $($numMax.Value) MB will be MOVED out of the user's folders on the OLD PC into C:\Migration-Oversized\<user> (not copied over the network).`r`n`r`n" }
    if ($r.Mode -eq 'Download') { $msg += "When every file is verified, the upload is DELETED from the server$(if ($script:keyPath) { ' (and its restore key from the stick)' }).`r`n`r`n" }
    if ([Windows.Forms.MessageBox]::Show($msg + 'Start?', $MigToolName, 'YesNo', 'Question') -ne 'Yes') { return }
    if ($Walk -and -not (Show-WalkDialog)) { return }
    # Log in to the IT PC now, so the report can be delivered at the end without asking (e.g. in walk-away mode).
    if ($cbReport.Checked -and $txtReport.Text.Trim() -and -not $script:cableOn) {
        if (-not (Connect-ReportPc $txtReport.Text -Prompt)) {
            if ([Windows.Forms.MessageBox]::Show("Can't log in to $($txtReport.Text.Trim()) for the IT report. Start anyway? (The report is saved and sent after the next transfer or Test in section 6.)", $MigToolName, 'YesNo', 'Warning') -ne 'Yes') { return }
        }
    }

    Set-Busy $true; $script:cancel = $false
    $from = if ($r.Mode -in 'Push', 'Export', 'Upload') { $env:COMPUTERNAME } else { $r.Other }
    $toPc = if ($r.Mode -in 'Pull', 'Import', 'Download') { $env:COMPUTERNAME } else { $r.Other }
    if ($from -match '^\d+\.\d+\.\d+\.\d+$') { $n = Get-RemoteName $from; if ($n) { $from = $n } }   # cable: names, not 10.99.99.x
    if ($toPc -match '^\d+\.\d+\.\d+\.\d+$') { $n = Get-RemoteName $toPc; if ($n) { $toPc = $n } }
    $fill = { param($s) $s.Replace('{OldPC}', $from).Replace('{NewPC}', $toPc) }
    Set-WalkGuard $true
    if ($Walk) {
        $script:jobDone = $false; $script:walkOn = $true; Set-Locked $true
        if ($script:walkMode -eq 'Screen') { Show-Overlay (& $fill $script:walk.During) }
        Write-Log "Walk away: $(if ($script:walkMode -eq 'Screen') { 'full-screen lockdown' } else { "$MigToolName locked (the PC stays usable)" })$(if ($script:walkAuto.SignOut) { '; signs out of Windows when finished' })."
    }
    Set-RetryButton 0
    if ($Walk -and $script:walkStartAt) {
        Write-Log "Walk away: waiting - the copy starts at $($script:walkStartAt.ToString('ddd HH:mm'))."
        while ((Get-Date) -lt $script:walkStartAt) {
            if (-not $script:locked) { Write-Log 'Scheduled start cancelled (unlocked by IT).'; $script:walkStartAt = $null; Set-WalkGuard $false; Set-Busy $false; $lblStatus.Text = ''; return }
            $left = $script:walkStartAt - (Get-Date)
            $t = "Starts at $($script:walkStartAt.ToString('HH:mm')) (in $(if ($left.TotalHours -ge 1) { '{0} h {1:D2} min' -f [int][math]::Floor($left.TotalHours), $left.Minutes } else { '{0} min' -f [math]::Ceiling($left.TotalMinutes) }))."
            $lblStatus.Text = $t; if ($script:ovStatus) { $script:ovStatus.Text = $t }
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250
        }
        $script:walkStartAt = $null
        Write-Log 'Scheduled time reached - starting.'
    }
    $runDir = Join-Path $logRoot ("{0}_{1}_{2}-to-{3}" -f (Get-Date -Format yyyyMMdd_HHmmss), $r.Mode, $from, $toPc)
    Save-Settings
    $results = @(); $handoffs = @(); $handoffFail = @()
    $t0 = Get-Date
    $srcRoot = $r.Src; $copyRows = $rows; $staging = $null; $dlProblem = $null; $dec = $null
    # Progress: total + per user\folder sizes (robocopy /L, same as Preview). Upload already measured; an encrypted
    # download is measured after it's unpacked (the package itself has only numbered blobs).
    $meas = if ($r.Mode -eq 'Upload') { $meas } elseif ($r.Mode -eq 'Download' -and $enc) { @{ Bytes = $need.Bytes; Parts = @{} } }
            elseif ($pre.Meas) { $pre.Meas } else { Measure-Selection $r.Src $userNames ($r.Mode -eq 'Download') }
    $verb = @{ Upload = 'Uploading'; Download = 'Downloading'; Export = 'Copying to drive'; Import = 'Copying from drive' }[$r.Mode]; if (-not $verb) { $verb = 'Copying' }
    if ($enc) { Start-Progress $meas.Bytes $(if ($r.Mode -eq 'Upload') { 'Encrypting + uploading' } else { 'Downloading + decrypting' }) $null }
    else { Start-Progress $meas.Bytes $verb $runDir $meas.Parts }
    $failRow = { param($n, $why) [pscustomobject]@{ Profile = $n; Dest = ''; Errors = 1; Oversized = @(); Cancelled = $false; Log = $runDir; Files = 0; Bytes = [long]0; FailedFiles = 0; Seconds = 0.0; PeakBps = 0.0; Report = ''; BookmarksCount = 0 } }
    if ($r.Mode -eq 'Upload' -and $enc) {
        # Encrypted upload: one background job for all users (numbered blobs + encrypted manifest), no robocopy
        $copyRows = @()
        foreach ($row in $rows) { $row.Cells[4].Value = 'waiting...' }
        $up = @(foreach ($n in $userNames) { $src = Join-Path (Join-Path $r.Src 'Users') $n; @{ Name = $n; Folders = @(Get-FolderList $src); Bookmarks = @(Get-SelectedBookmarks); Settings = @(Get-SelectedSettings) } })
        Write-Log "== Encrypting + uploading $($userNames -join ', ') to $($r.Dst)"
        $job = Invoke-PkgJob -Verb 'Encrypting + uploading' -ArgList @($r.Src, $r.Dst, $up, $keys, $prot, $salt, $env:COMPUTERNAME, $runDir) -Script {
            param($core, $sync, $srcRoot, $pkg, $users, $keys, $prot, $salt, $oldPc, $logDir)
            . $core
            Export-PkgEncrypted -SrcRoot $srcRoot -PkgDir $pkg -Users $users -Keys $keys -Protection $prot -Salt $salt -OldPc $oldPc -LogDir $logDir -Sync $sync
        }
        if ($job.Error -or -not $job.Output) {
            Write-Log "  ! Upload FAILED: $($job.Error)"
            foreach ($row in $rows) { $row.Cells[4].Value = "FAILED: $($job.Error)"; $results += & $failRow "$($row.Cells[1].Value)" }
        } else {
            $o = $job.Output; $tot = [long]0; foreach ($u in $o.Users) { $tot += [long]$u.Bytes }
            foreach ($u in $o.Users) {
                $part = if ($tot) { [long]$u.Bytes / $tot } else { 1 / @($o.Users).Count }
                $results += [pscustomobject]@{ Profile = $u.Name; Dest = $r.Dst; Errors = $(if ($u.Failed) { 1 } else { 0 }); Oversized = @(); Cancelled = $o.Cancelled; Log = $runDir
                    Files = [int]$u.Files; Bytes = [long]$u.Bytes; FailedFiles = [int]$u.Failed; Seconds = $job.Seconds * $part; PeakBps = $(if ($job.Seconds) { $tot / $job.Seconds } else { 0 }); Report = ''; BookmarksCount = 0 }
                Write-Log "  $($u.Name): $($u.Files) files, $(Format-Size ([long]$u.Bytes))$(if ($u.Failed) { ", $($u.Failed) could NOT be read (in use?) - see $runDir" })"
                $row = $rows | Where-Object { "$($_.Cells[1].Value)" -eq $u.Name } | Select-Object -First 1
                if ($row) { $row.Cells[4].Value = if ($o.Cancelled) { 'CANCELLED' } elseif ($u.Failed) { "uploaded, $($u.Failed) file(s) failed" } else { 'uploaded (encrypted)' } }
            }
        }
    }
    if ($r.Mode -eq 'Download' -and $enc) {
        # Encrypted download: verify + decrypt into a staging folder on this PC, then the normal copy from there
        $staging = Join-Path $env:SystemDrive ("Migration-Incoming\" + (Split-Path $r.Src -Leaf))
        foreach ($row in $rows) { $row.Cells[4].Value = 'downloading...' }
        Write-Log "== Downloading + decrypting $($userNames -join ', ') from $($r.Src)"
        $job = Invoke-PkgJob -Verb 'Downloading + decrypting' -ArgList @($r.Src, $keys, $userNames, $staging) -Script {
            param($core, $sync, $pkg, $keys, $names, $staging)
            . $core
            Import-PkgEncrypted -PkgDir $pkg -Keys $keys -UserNames $names -Staging $staging -Sync $sync
        }
        if ($job.Error -or -not $job.Output) {
            $dlProblem = "download failed: $($job.Error)"; Write-Log "  ! $dlProblem"; $copyRows = @()
            foreach ($row in $rows) { $row.Cells[4].Value = "FAILED: $($job.Error)"; $results += & $failRow "$($row.Cells[1].Value)" }
        } else {
            $dec = $job.Output
            Write-Log "  Verified + decrypted $($dec.Ok) of $($dec.Expected) files."
            foreach ($f in $dec.Failed) { Write-Log "  ! $f" }
            if ($dec.Cancelled) { $dlProblem = 'cancelled' }
            elseif ($dec.Failed.Count -or $dec.Ok -ne $dec.Expected) { $dlProblem = "$($dec.Expected - $dec.Ok) file(s) failed the check (see log)" }
        }
        $srcRoot = $staging
        $m2 = Measure-Selection $staging $userNames $true   # local, quick
        Start-Progress $m2.Bytes 'Copying into place' $runDir $m2.Parts
    }
    foreach ($row in $copyRows) {
        if ($script:cancel) { break }
        $name = "$($row.Cells[1].Value)"
        $row.Cells[4].Value = 'copying...'; $lblStatus.Text = "Copying $name ..."
        Write-Log "== $name"
        $src = Join-Path (Join-Path $srcRoot 'Users') $name
        # Copy into: own account (section 4 decides), someone else (one desktop folder "Files from <old user>"),
        # or backup only (<folder>\<old user>, report inside, no receipt/handoff)
        $ci = $rowInto[$name]
        $rDest = "$($row.Cells[3].Value)".Trim(); $rTarget = $target; $rLayout = $layout; $rAsk = $ask
        $rOtherRoot = $otherRoot; $rOtherLabel = $script:otherPath; $rBackupName = $script:backupName; $rBackupOnly = $false
        if ($ci -and $ci.Kind -eq 'User') {
            $pf = Resolve-DestProfile (Join-Path $r.Dst 'Users') $ci.User   # mjones -> mjones.DOMAIN if that is their folder
            $rDest = if ($pf) { $pf } else { $ci.User }; $rAsk = $false; $rLayout = 'Backup'; $rBackupName = Get-ReplaceFolderName $name
            $rTarget = if ($rbMigration.Checked) { 'Migration' } else { 'Profile' }
            Write-Log "  Copy into: $($ci.User) (replacing $(Get-HandoffUser $name)), Desktop\$rBackupName"
        } elseif ($ci) {
            $rDest = Get-HandoffUser $name; $rAsk = $false; $rLayout = 'Other'; $rTarget = 'Profile'; $rBackupOnly = $true
            $rOtherRoot = $bakRoots[$ci.Path]; $rOtherLabel = $ci.Path
            Write-Log "  Copy into: backup only, $($ci.Path.TrimEnd('\'))\$rDest"
        }
        # From a server package: everything in it (folders were picked at upload; bookmarks are already converted)
        $folders = if ($r.Mode -eq 'Download') { @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object Name) } else { @(Get-FolderList $src) }
        $bms = if ($r.Mode -in 'Download', 'Import') { @() } else { @(Get-SelectedBookmarks) }
        $sets = if ($r.Mode -in 'Download', 'Import') { @() } else { @(Get-SelectedSettings) }
        if ($r.Mode -eq 'Import' -and $folders -notcontains 'Documents') {   # made on the old PC: they travel inside Documents
            foreach ($x in 'Documents\Migrated Settings', 'Documents\Migrated Bookmarks') { if (Test-Path -LiteralPath (Join-Path $src $x)) { $folders += $x } }
        }
        try {
            $res = Invoke-ProfileMigration -SrcRoot $srcRoot -DstRoot $r.Dst -ProfileName $name -DestName $rDest `
                -Folders $folders -Bookmarks $bms -Settings $sets -OldRoot $(if ($r.Mode -eq 'Download') { 'C:' } else { '' }) `
                -Target $rTarget -Layout $rLayout -OtherRoot $rOtherRoot -OtherLabel $rOtherLabel -BackupOnly:$rBackupOnly -ForSomeoneElse:($ci -and $ci.Kind -eq 'User') `
                -BackupName $rBackupName -MaxBytes (Get-MaxBytes) -Oversize $over -SourcePc $from -DestPc $toPc `
                -ReportNote $(if ($rAsk) { "When you sign in you'll be asked whether to put them in the same folders or in '$($script:backupName)' on your desktop." } else { '' }) `
                -LogDir $runDir -Log { param($m) Write-Log $m } -Wait $waitBlock
        } catch {
            # One profile failing must not crash the window or stop the others
            Write-Log "  ! $name FAILED: $($_.Exception.Message)"
            $row.Cells[4].Value = "FAILED: $($_.Exception.Message)"
            $results += & $failRow $name
            continue
        }
        $results += $res
        $row.Cells[4].Value = if ($res.Cancelled) { 'CANCELLED' } elseif ($res.Errors) { "done with $($res.Errors) error(s)" } else { "done$(if ($res.Oversized.Count) { ", $($res.Oversized.Count) large set aside" })" }
        # Landed in C:\Migration\<user> (no profile yet, or chosen): queue the handoff on the new PC for that user.
        # (Other location: only the receipt waits there, when the user has no profile yet)
        $hfFolder = if ($res.ReceiptStaged) { $res.ReceiptStaged } elseif ((Split-Path (Split-Path $res.Dest) -Leaf) -eq 'Migration') { Split-Path $res.Dest -Leaf }
        if (-not $sending -and -not $res.Cancelled -and $hfFolder) {
            $folder = $hfFolder; $hu = Get-HandoffUser $folder
            try {
                $remote = if ($r.Dst -like '\\*') { $r.Other } else { $null }
                Add-MigrationHandoff -DstRoot $r.Dst -User $hu -Folder $folder -SourcePc $from -RemotePc $remote -Credential $script:remoteCred `
                    -Ask:$rAsk -Message $script:askMessage -BackupName $script:backupName
                $handoffs += "$hu (C:\Migration\$folder)"
                $when = if ($rAsk) { "when $hu signs in on $toPc they choose: same locations or Desktop\$($script:backupName)" } else { "moves into $hu's folders when $hu signs in on $toPc" }
                Write-Log "  Handoff set: C:\Migration\$folder - $when."
                $row.Cells[4].Value = "$($row.Cells[4].Value) - waits in C:\Migration\$folder$(if ($rAsk) { ' (user is asked at sign-in)' })"
            } catch {
                $handoffFail += "$hu"
                Write-Log "  ! Handoff NOT set for $hu ($($_.Exception.Message)). Files are in C:\Migration\$folder on $toPc - finish it there: Set-MigrationHandoff.ps1 -User $hu"
                $row.Cells[4].Value = "$($row.Cells[4].Value) - HANDOFF NOT SET (see log)"
            }
        }
    }
    $extraNote = ''; $swNote = ''
    if (-not $script:cancel) { $extraNote = Copy-ExtraFolders $r $runDir }
    if (-not $script:cancel -and (Test-WantSoftware)) { $swNote = Save-PcInventory $r $runDir $from }
    $prnNote = ''; if (-not $script:cancel -and (Test-WantPrintersMove)) { $prnNote = Move-Printers $r $runDir }
    if ($prnNote) { $swNote = (@($swNote, $prnNote) | Where-Object { $_ }) -join "`r`n" }
    $big = @($results | ForEach-Object { $_.Oversized })
    Update-RoboProgress
    Stop-Progress (-not $script:cancel -and -not @($results | Where-Object Cancelled).Count)
    # Files that failed the download check count as failed files of their user (stats, Result, summary)
    if ($dec -and $dec.Failed.Count) {
        foreach ($f in $dec.Failed) {
            $res = $results | Where-Object { "$f".StartsWith("$($_.Profile)\", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
            if ($res) { $res.FailedFiles++; $res.Errors = [math]::Max($res.Errors, 1) }
        }
    }

    # Download: drop the decrypted staging copy; delete the server package (and its restore key) only when it's all verified
    $pkgNote = ''
    if ($r.Mode -eq 'Download') {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            $lblStatus.Text = 'Cleaning up the unpacked copy...'; [Windows.Forms.Application]::DoEvents()
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            $sp = Split-Path $staging; if (-not (Get-ChildItem -LiteralPath $sp -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $staging) { Write-Log "! Couldn't fully remove the unpacked copy $staging - delete it by hand." }
        }
        $why = @()
        if ($dlProblem) { $why += $dlProblem }
        if ($script:cancel -or @($results | Where-Object Cancelled).Count) { $why += 'cancelled' }
        $e = [int](($results | Measure-Object Errors -Sum).Sum) + [int](($results | Measure-Object FailedFiles -Sum).Sum)
        if ($e) { $why += "$e error(s) copying into place" }
        if (-not $hdr.Complete) { $why += 'the upload itself was incomplete' }
        $left = @($hdr.Users | ForEach-Object { $_.Name } | Where-Object { $userNames -notcontains $_ })
        if ($left.Count) { $why += "it still holds $($left -join ', ') (not downloaded)" }
        if ($why.Count) { $pkgNote = "SERVER COPY KEPT ($(($why | Select-Object -Unique) -join '; ')):`r`n$($r.Src)" }
        else {
            $lblStatus.Text = 'Every file verified - deleting the server copy...'; [Windows.Forms.Application]::DoEvents()
            Remove-Item -LiteralPath $r.Src -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $r.Src) { $pkgNote = "Every file verified, but the server copy couldn't be fully deleted - delete it by hand:`r`n$($r.Src)" }
            else {
                $pkgNote = "Every file verified - server copy deleted ($($r.Src))."
                # its restore key (+ .cmd) is useless now
                if ($script:keyPath -and (Test-Path -LiteralPath $script:keyPath)) {
                    try {
                        $ki = (Read-RestoreKey $script:keyPath).Info
                        if ("$($ki.Package)".TrimEnd('\') -eq $r.Src.TrimEnd('\')) {
                            foreach ($f in $script:keyPath, [IO.Path]::ChangeExtension($script:keyPath, '.cmd')) { if (Test-Path -LiteralPath $f) { [IO.File]::Delete($f) } }
                            $pkgNote += " Restore key removed from $(Split-Path $script:keyPath)."
                        }
                    } catch { Write-Log "! Restore key not removed: $($_.Exception.Message)" }
                }
            }
        }
        Write-Log $pkgNote
    }

    # Stats row: logs\MigrationStats.csv on this drive always, plus the report PC if enabled.
    $elapsed = (Get-Date) - $t0
    $bytes = [long](($results | Measure-Object Bytes -Sum).Sum)
    $copySec = [double](($results | Measure-Object Seconds -Sum).Sum)
    $errs = [int](($results | Measure-Object Errors -Sum).Sum)
    $stats = [pscustomobject][ordered]@{
        Date = $t0.ToString('yyyy-MM-dd HH:mm'); Result = $(if (@($results | Where-Object Cancelled).Count) { 'CANCELLED' } elseif ($errs) { 'ERRORS' } else { 'OK' })
        Method = $(if ($rbCable.Checked) { 'Direct cable' } elseif ($rbDrive.Checked) { 'External drive' } elseif ($server) { 'Server offload' } else { 'Network' }); Mode = $r.Mode
        FromPC = $from; ToPC = $toPc; Profiles = (($results | ForEach-Object Profile) -join '; '); ProfileCount = $results.Count
        Files = [int](($results | Measure-Object Files -Sum).Sum); DataGB = [math]::Round($bytes / 1GB, 2); DataBytes = $bytes
        TransferTime = '{0:hh\:mm\:ss}' -f $elapsed; Seconds = [int]$elapsed.TotalSeconds
        AvgMBps = $(if ($copySec -gt 0) { [math]::Round($bytes / 1MB / $copySec, 1) } else { 0 })
        PeakMBps = [math]::Round((($results | Measure-Object PeakBps -Maximum).Maximum) / 1MB, 1)
        FailedFiles = [int](($results | Measure-Object FailedFiles -Sum).Sum); Errors = $errs
        LargeFilesSetAside = $big.Count; LargeFilesGB = [math]::Round((($big | Measure-Object SizeMB -Sum).Sum) / 1024, 2)
        LargeFileLimitMB = $(if ((Get-MaxBytes) -ge $NoLimit) { '' } else { [int]$numMax.Value })
        Operator = [Security.Principal.WindowsIdentity]::GetCurrent().Name; RunFolder = (Split-Path $runDir -Leaf)
    }
    # Dashboard columns: speeds in megabits, link speed, file types / folders / ages from the logs, PC models
    $lblStatus.Text = 'Gathering statistics...'; [Windows.Forms.Application]::DoEvents()
    $extra = [ordered]@{
        AvgMbit_s = $(if ($copySec -gt 0) { [math]::Round($bytes * 8 / 1e6 / $copySec, 1) } else { 0 })
        PeakMbit_s = [math]::Round((($results | Measure-Object PeakBps -Maximum).Maximum) * 8 / 1e6, 1)
        LinkSpeed = $(if ($r.Mode -in 'Push', 'Pull') { Get-LinkSpeedTo $r.Other } elseif ($server -and $r.Remote -match '^\\\\([^\\]+)') { Get-LinkSpeedTo $Matches[1] } else { '' })
    }
    $fs = Get-RunFileStats $runDir
    foreach ($k in $fs.Keys) { $extra[$k] = $fs[$k] }
    $extra.BookmarksCount = [int](($results | Measure-Object BookmarksCount -Sum).Sum)
    $here = Get-PcInfo
    $there = [pscustomobject]@{ Model = ''; Windows = '' }
    if ($r.Mode -in 'Push', 'Pull') {
        $q = Invoke-Bg -Script { param($core, $pc, $cred) . $core; Get-PcInfo -Computer $pc -Credential $cred } -ArgList @($r.Other, $script:remoteCred) -TimeoutSec 20 -Status 'Asking the other PC for its model'
        if ($q.Ok -and $q.Output) { $there = @($q.Output)[-1] }
    }
    if ($r.Mode -eq 'Download') { $there = [pscustomobject]@{ Model = "$($hdr.OldPCModel)"; Windows = "$($hdr.OldPCWindows)" } }   # noted at upload
    $oldInfo = if ($r.Mode -in 'Push', 'Export', 'Upload') { $here } else { $there }
    $newInfo = if ($r.Mode -in 'Pull', 'Import', 'Download') { $here } else { $there }
    $extra.OldPCModel = $oldInfo.Model; $extra.OldPCWindows = $oldInfo.Windows; $extra.NewPCModel = $newInfo.Model; $extra.NewPCWindows = $newInfo.Windows
    $extra.Layout = if ($sending) { '' } elseif ($ask) { 'Ask user' } elseif ($layout -eq 'Backup') { "Desktop folder ($($script:backupName))" } elseif ($layout -eq 'Other') { "Other ($($script:otherPath))" } else { 'Same folders' }
    # Copy into someone else / backup only: noted after the layout (e.g. "Same folders; jsmith -> mjones; backup: kdoe -> D:\Old Staff")
    $intoNotes = @(foreach ($k in $rowInto.Keys) { $ci = $rowInto[$k]; if ($ci -and $ci.Kind -eq 'User') { "$k -> $($ci.User)" } elseif ($ci) { "backup: $k -> $($ci.Path)" } })
    if ($intoNotes.Count) { $extra.Layout = (@($extra.Layout) + $intoNotes | Where-Object { $_ }) -join '; ' }
    $extra.Protection = if ($server) { $prot } else { '' }
    foreach ($k in $extra.Keys) { $stats | Add-Member -NotePropertyName $k -NotePropertyValue $extra[$k] -Force }
    $lblStatus.Text = ''
    New-Item -ItemType Directory -Force $runDir | Out-Null
    $stats | ConvertTo-Json | Set-Content (Join-Path $runDir 'stats.json') -Encoding UTF8
    if (Add-StatsRows (Join-Path $logRoot 'MigrationStats.csv') @($stats)) { Update-Dashboard $logRoot }
    else { Write-Log '! Could not update logs\MigrationStats.csv (open in Excel?) - the run''s stats.json has everything.' }
    if ($fs.LargestFileUser) { Write-Log ("Largest file: {0} MB ({1}) - kudos to {2}" -f $fs.LargestFileMB, $fs.LargestFileType, $fs.LargestFileUser) }
    Write-Log ("STATS: {0} files, {1} GB in {2}  (avg {3} MB/s, peak {4} MB/s), failed files {5}" -f $stats.Files, $stats.DataGB, $stats.TransferTime, $stats.AvgMBps, $stats.PeakMBps, $stats.FailedFiles)

    if ($sending -and (Test-Path -LiteralPath $r.Dst)) {
        try { Save-CopyInto $r.Dst $rows; Write-Log "Copy into choices saved with the copy ($CopyIntoFile) - filled in on the new PC." }
        catch { Write-Log "! $CopyIntoFile not written ($($_.Exception.Message)) - pick who gets what on the new PC." }
    }
    # Upload: header for a plain package (encrypted ones wrote their own), old PC model for the download's stats, restore key
    $keyCmd = $null
    if ($r.Mode -eq 'Upload' -and (Test-Path -LiteralPath $r.Dst)) {
        $hf = Join-Path $r.Dst $PkgHeader
        try {
            if (-not $enc) {
                [ordered]@{ Format = 'MigrateUserFiles-Package'; Version = 1; Protection = 'None'; Salt = ''; Verifier = ''; OldPC = $env:COMPUTERNAME; Created = $t0.ToString('s')
                    Complete = -not ($script:cancel -or @($results | Where-Object Cancelled).Count)
                    Users = @($results | ForEach-Object { [ordered]@{ Name = $_.Profile; Files = $_.Files; Bytes = $_.Bytes; Failed = $_.FailedFiles } })
                    FileCount = $stats.Files; TotalBytes = $stats.DataBytes } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $hf -Encoding UTF8 -ErrorAction Stop
            }
            $h = Get-Content -LiteralPath $hf -Raw -Encoding UTF8 | ConvertFrom-Json
            $h | Add-Member -NotePropertyName OldPCModel -NotePropertyValue $here.Model -Force
            $h | Add-Member -NotePropertyName OldPCWindows -NotePropertyValue $here.Windows -Force
            $h | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $hf -Encoding UTF8 -ErrorAction Stop
        } catch { Write-Log "! Package header not written ($($_.Exception.Message)) - the NEW PC can't open this upload. Upload again." }
        if ((Test-Path -LiteralPath $hf) -and $stats.Result -ne 'CANCELLED') {
            $lblStatus.Text = 'Save the restore key...'
            $keyCmd = Save-RestoreKey $r.Dst $prot $master $userNames -Auto:([bool]$script:walkOn)
            if ($keyCmd -and $keyCmd -like "$env:SystemDrive\Migration-Keys\*") { Write-Log "! The restore key is on THIS PC ($(Split-Path $keyCmd)) - copy it to your stick, then delete it here." }
        }
        $master = $null; $keys = $null
        $script:pkgName = $null   # the next upload gets its own package
        # Instructions next to the files (plain text, no secrets) - whoever restores finds them on the server
        $howTo = $null
        if ((Test-Path -LiteralPath $hf) -and $stats.Result -ne 'CANCELLED' -and -not ($prot -eq 'Key' -and -not $keyCmd)) {
            $howTo = Get-RestoreInstructions $r.Dst $prot $keyCmd
            try { [IO.File]::WriteAllText((Join-Path $r.Dst 'HOW TO RESTORE.txt'), $howTo, (New-Object Text.UTF8Encoding $true)) } catch { Write-Log "! HOW TO RESTORE.txt not written: $($_.Exception.Message)" }
        }
    }

    Set-Busy $false
    $lblStatus.Text = 'Finished.'
    # Failed files and a rerun can fix them (not an upload: that would make a new package)? -> Retry failed (N)
    $nFail = [int](($results | Measure-Object FailedFiles -Sum).Sum)
    $retryable = $r.Mode -ne 'Upload' -and -not $script:cancel -and -not @($results | Where-Object Cancelled).Count -and @($results | Where-Object { $_.Errors -or $_.FailedFiles }).Count
    Set-RetryButton $(if ($retryable) { [math]::Max($nFail, 1) } else { 0 })
    $sum = "Finished. Logs: $runDir`r`n`r`n" + (($results | ForEach-Object { "$($_.Profile): $(if ($_.Cancelled) { 'CANCELLED' } else { "$($_.Errors) error(s)" }) -> $($_.Dest)" }) -join "`r`n")
    if ($r.Mode -eq 'Export') { $sum += "`r`n`r`nOn the NEW PC: External drive + NEW PC, Browse to $($r.Dst)." }
    elseif ($r.Mode -eq 'Upload') {
        $sum += "`r`n`r`nUploaded to $($r.Dst) ($protText)."
        if ($prot -eq 'Key' -and -not $keyCmd) { $sum += "`r`nRESTORE KEY NOT SAVED - this upload can't be opened. Delete it and upload again." }
        elseif ($howTo) { $sum += "`r`nHow to restore it: shown next, and saved on the server as $($r.Dst)\HOW TO RESTORE.txt" }
    }
    else { $sum += "`r`n`r`nEach user has a `"Migration Report`" on their Desktop listing every file and where it went." }
    if ($pkgNote) { $sum += "`r`n`r`n$pkgNote" }
    if ($extraNote) { $sum += "`r`n`r`n$extraNote" }
    if ($swNote) { $sum += "`r`n`r`n$swNote" }
    $vf = [int](($results | Where-Object { $_.PSObject.Properties['Verified'] } | Measure-Object Verified -Sum).Sum); if ($vf) { $sum += "`r`n`r`nVerified (SHA-256): $vf file(s) identical." }
    if ($handoffs.Count) { $sum += "`r`n`r`nWAITING FOR FIRST SIGN-IN (handoff): $($handoffs -join ', ').`r`nEach user's files move from C:\Migration into their own folders the first time they sign in on $toPc. Not needed? Delete that C:\Migration folder." }
    if ($handoffFail.Count) { $sum += "`r`n`r`nHANDOFF NOT SET for: $($handoffFail -join ', '). Their files are in C:\Migration on $toPc; run Set-MigrationHandoff.ps1 -User <name> there (as admin)." }
    if ($script:cableOn) { $sum += "`r`n`r`nCable: click End cable link (or close this window) on BOTH PCs to put their network back to normal." }
    if ($big.Count) {
        $moved = @($big | Where-Object { $_.NewPath })
        $sum += "`r`n`r`nLARGE FILES NOT TRANSFERRED: $($big.Count) ($(Format-Size (($big | Measure-Object SizeMB -Sum).Sum * 1MB)))."
        if ($moved.Count) { $sum += "`r`n$($moved.Count) are in C:\Migration-Oversized\<user> on the OLD PC (see README.txt and _oversized-manifest.csv there). Carry them over on an external drive." }
        if ($big.Count -gt $moved.Count) { $sum += "`r`n$($big.Count - $moved.Count) were left in place - list in the log folder (*.oversized.csv)." }
    }
    $sum = "$($stats.Result): $($stats.Files) files, $($stats.DataGB) GB in $($stats.TransferTime) (avg $($stats.AvgMBps) MB/s, peak $($stats.PeakMBps) MB/s).`r`n" + $sum
    Set-Content (Join-Path $runDir 'summary.txt') ("$MigToolName - $($stats.Date)  $($stats.FromPC) -> $($stats.ToPC)`r`n`r`n" + $sum) -Encoding UTF8
    if ($cbReport.Checked -and $txtReport.Text.Trim()) {
        $lblStatus.Text = "Sending report to $($txtReport.Text.Trim()) ..."; [Windows.Forms.Application]::DoEvents()
        $rep = Send-Reports $txtReport.Text.Trim() $txtReportUser.Text $runDir
        $script:reportSent = $rep.Left -eq 0
        if ($rep.Left -eq 0) {
            $pop = Send-Popup $txtReport.Text.Trim() $txtReportUser.Text "Migration $($stats.Result): $($stats.FromPC) -> $($stats.ToPC), $($stats.Files) files, $($stats.DataGB) GB in $($stats.TransferTime). See Desktop\Migration Reports."
            $sum += "`r`n`r`nReport sent to $($rep.Dir)$(if ($pop) { ' (popup shown there)' })."
        } else { $sum += "`r`n`r`nReport could NOT be sent to $($txtReport.Text.Trim()) - saved here and sent automatically after the next transfer (or Test in section 6)." }
        $lblStatus.Text = 'Finished.'
    }
    if (-not ($cbReport.Checked -and $txtReport.Text.Trim())) { $script:reportSent = $false }
    Write-Log $sum
    Set-WalkGuard $false
    if ($script:walkOn) {
        # Walk-away: completion message for whoever comes back; IT reads the summary in the log after unlocking.
        $reports = @($results | Where-Object { $_.Report } | ForEach-Object { Split-Path $_.Report -Leaf })
        $rf = if ($reports.Count) { '"' + ($reports -join '", "') + '"' } else { 'the Migration Report' }
        $done = if ($stats.Result -ne 'OK') { "Data transfer finished with problems ($($stats.Result)). Please contact IT." }
                elseif ($rbCable.Checked) { $script:walk.DoneCable } else { $script:walk.Done }
        $doneText = (& $fill $done).Replace('{ReportFile}', $rf)
        if ($script:overlay) { Set-OverlayDone $doneText } elseif (-not $script:walkAuto.SignOut) { Show-DoneNote $doneText }
        $script:jobDone = $true
        $lblStatus.Text = 'Finished - you can close this window.'
        $okRun = $stats.Result -eq 'OK'
        # Sign out: always (your login must not stay open) - removal only after a clean run. Close only: only after a clean run.
        if ($script:walkAuto.SignOut) { Start-WalkAutoClose $doneText $runDir -SignOut -AllowRemove $okRun }
        elseif ($script:walkAuto.Close -and $okRun) { Start-WalkAutoClose $doneText $runDir -AllowRemove $true }
        elseif ($script:walkAuto.Close) { Write-Log "Walk away: NOT closing by itself - the transfer finished with $($stats.Result)." }
    } else {
        [void][Windows.Forms.MessageBox]::Show($sum, $MigToolName)
        if ($r.Mode -eq 'Upload' -and $howTo) { Show-Instructions "How to restore $env:COMPUTERNAME's files" $howTo }
    }
    if ($r.Mode -eq 'Upload' -and $howTo) { Write-Log $howTo }   # walk-away: in the log (and on the server) for after unlocking
}

# Read-only text window with Copy and Print-friendly Save, for instructions
function Show-Instructions([string]$Title, [string]$Text) {
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = $Title; ClientSize = (S 900 470); StartPosition = 'CenterParent'; FormBorderStyle = 'Sizable'; MinimizeBox = $false; Font = $form.Font }
    $t = New-Object Windows.Forms.TextBox -Property @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Text = $Text; Font = New-Object Drawing.Font('Consolas', 9.5); BackColor = [Drawing.Color]::White
        Location = (P 12 12); Size = (S 876 410); Anchor = 'Top, Bottom, Left, Right' }
    $bCopy = New-Object Windows.Forms.Button -Property @{ Text = 'Copy'; Location = (P 716 432); Size = (S 80 28); Anchor = 'Bottom, Right' }
    $bOk = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = (P 808 432); Size = (S 80 28); Anchor = 'Bottom, Right'; DialogResult = 'OK' }
    $bCopy.Add_Click({ [Windows.Forms.Clipboard]::SetText($t.Text); $bCopy.Text = 'Copied' })
    $d.Controls.AddRange(@($t, $bCopy, $bOk)); $d.AcceptButton = $bOk; $d.CancelButton = $bOk
    $t.Select(0, 0)
    [void]$d.ShowDialog($form)
}
# ---------- Check before starting ----------
# Lines to show under "CHECK FIRST" in the Start question, Stop = can't start (no room). Meas = the measured selection
# (reused for the progress bar). The old PC is this PC (Push/Export/Upload) or the other one (Pull, over DCOM).
function Get-Preflight($r, [string[]]$Users) {
    $res = @{ Lines = @(); Stop = $null; Meas = $null }
    $act = @()
    try {
        if ($r.Mode -in 'Push', 'Export', 'Upload' -and $r.Other -ne 'TEST') { $act = @(Get-SourceActivity) }
        elseif ($r.Mode -eq 'Pull' -and $r.Other -ne 'TEST') {
            $q = Invoke-Bg -Script { param($core, $pc, $cred) . $core; Get-SourceActivity -Computer $pc -Credential $cred } -ArgList @($r.Other, $script:remoteCred) -TimeoutSec 25 -Status "Checking $($r.Other)"
            if ($q.Ok) { $act = @($q.Output | Where-Object { $_.App }) }
        }
    } catch {}
    $sel = @($Users | ForEach-Object { Get-HandoffUser $_ })
    $mine = @($act | Where-Object { $_.User -and $sel -contains (Get-HandoffUser $_.User) })
    $old = if ($r.Mode -in 'Push', 'Export', 'Upload') { $env:COMPUTERNAME } else { $r.Other }
    foreach ($u in @($mine | Where-Object { $_.App -eq 'explorer.exe' } | ForEach-Object User | Sort-Object -Unique)) {
        $res.Lines += "$u is signed in on $old - files can change while copying. Best: they save their work and sign out."
    }
    $ol = @($mine | Where-Object { $_.App -eq 'OUTLOOK.EXE' } | ForEach-Object User | Sort-Object -Unique)
    if ($ol.Count) { $res.Lines += "Outlook is open ($($ol -join ', ')) - its .pst data files are locked and will fail. Close Outlook first." }
    $apps = @{ 'WINWORD.EXE' = 'Word'; 'EXCEL.EXE' = 'Excel'; 'POWERPNT.EXE' = 'PowerPoint'; 'ONENOTE.EXE' = 'OneNote'; 'MSACCESS.EXE' = 'Access' }
    $off = @($mine | Where-Object { $apps.ContainsKey($_.App) } | ForEach-Object { "$($apps[$_.App]) ($($_.User))" } | Sort-Object -Unique)
    if ($off.Count) { $res.Lines += "Open in Office: $($off -join ', ') - open files are copied as last saved; OneNote/Access files may fail." }
    # Room on the destination (new PC or drive). Server modes check their own space.
    if ($r.Mode -in 'Push', 'Pull', 'Export', 'Import') {
        $res.Meas = Measure-Selection $r.Src $Users $false
        $free = Get-FreeBytes $r.Dst
        $need = [long]($res.Meas.Bytes * 1.05 + 300MB)
        if ($free -ge 0 -and $need -gt $free) {
            $res.Stop = "Not enough space on $($r.Dst): this copy needs about $(Format-Size $need), $(Format-Size $free) is free.`r`n`r`nFree up space, pick fewer folders or profiles, or set large files aside (section 5)."
        } elseif ($free -ge 0 -and $free - $need -lt 5GB) { $res.Lines += "Space is tight on $($r.Dst): $(Format-Size $free) free, about $(Format-Size $need) needed." }
    }
    $res
}

# ---------- Advanced: extra folders outside the profiles (same path on the new PC) ----------
# A path on a PC (C:\Data) as seen from here, given that PC's root: \\PC\C$ -> \\PC\C$\Data, C: -> C:\Data,
# a test root folder -> <root>\Data.
function Resolve-OnRoot([string]$Root, [string]$Path) {
    if ($Path -notmatch '^([A-Za-z]):\\?(.*)$') { return $null }
    $d = $Matches[1]; $rest = $Matches[2]
    if ($Root -match '^\\\\([^\\]+)\\[A-Za-z]\$') { "\\$($Matches[1])\$d`$\$rest".TrimEnd('\') }
    elseif ($Root -match '^[A-Za-z]:\\?$') { "${d}:\$rest".TrimEnd('\') }
    else { (Join-Path $Root $rest).TrimEnd('\') }
}
# Network/cable: old PC -> same path on the new PC. Drive: into <export>\Extra Folders\<C>\... (+ list.txt), and back on
# Import. Not with Server offload. Returns a summary line ('' = none).
function Copy-ExtraFolders($r, [string]$RunDir) {
    if ($r.Mode -in 'Upload', 'Download') {
        if ($MigAdv.ExtraFolders.Count -and $r.Mode -eq 'Upload') { Write-Log '! Extra folders (Advanced) are not sent with Server offload - use Network, Direct cable or External drive for them.' }
        return ''
    }
    $exRoot = if ($r.Mode -eq 'Export') { Join-Path $r.Dst 'Extra Folders' } elseif ($r.Mode -eq 'Import') { Join-Path $r.Src 'Extra Folders' }
    $paths = if ($r.Mode -eq 'Import') { @(Get-Content -LiteralPath (Join-Path $exRoot 'list.txt') -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ }) } else { @($MigAdv.ExtraFolders) }
    if (-not $paths.Count) { return '' }
    $done = @(); $copied = @()
    foreach ($p in $paths) {
        if ($script:cancel) { break }
        $rel = $p -replace '^([A-Za-z]):\\?', '$1\'
        $src = if ($r.Mode -eq 'Import') { Join-Path $exRoot $rel } else { Resolve-OnRoot $r.Src $p }
        $dst = if ($r.Mode -eq 'Export') { Join-Path $exRoot $rel } else { Resolve-OnRoot $r.Dst $p }
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { Write-Log "  - extra folder $p : not found, skipped"; continue }
        Write-Log "== Extra folder $p"; $lblStatus.Text = "Copying $p ..."
        New-Item -ItemType Directory -Force $RunDir | Out-Null
        $log = Join-Path $RunDir ("_extra.{0}.log" -f ($p -replace '[\\/:*?"<>| ]', '_'))
        $opts = @('/E', '/XJ', '/COPY:DAT', '/DCOPY:T', '/NP', '/NDL', '/FP', '/TS', '/BYTES') + (Get-MigRoboOpts)
        $code = Invoke-Robo $src $dst $opts $log $waitBlock
        $st = Get-RoboSummary $log
        Write-Log $(if ($code -ge 8) { "  ! some files failed (robocopy $code) - see $log" } else { "  ok - $($st.Files) files, $(Format-Size $st.Bytes) -> $dst" })
        $done += "$p ($($st.Files) files$(if ($code -ge 8) { ', ERRORS' }))"; $copied += $p
    }
    if ($r.Mode -eq 'Export' -and $copied.Count) { New-Item -ItemType Directory -Force $exRoot | Out-Null; $copied | Set-Content -LiteralPath (Join-Path $exRoot 'list.txt') -Encoding UTF8 }
    if ($done.Count) { "Extra folders: $($done -join '; ')" } else { '' }
}

# ---------- Application inventory for IT (programs + printers of the OLD PC) ----------
# Old PC = this PC (Push/Export/Upload), the other one (Pull, DCOM), or the lists saved with a drive/server copy
# (software.csv / printers.csv). Writes "Application inventory - <OLDPC>.html" into the run's logs (also sent with the IT report).
function Save-PcInventory($r, [string]$RunDir, [string]$OldPc) {
    $sw = $null; $pr = @()
    try {
        if ($r.Mode -in 'Push', 'Export', 'Upload') {
            $lblStatus.Text = 'Listing installed programs and printers...'; [Windows.Forms.Application]::DoEvents()
            $sw = @(Get-InstalledSoftware); $pr = @(Get-PrinterList)
        } elseif ($r.Mode -eq 'Pull' -and $r.Other -ne 'TEST') {
            $q = Invoke-Bg -Script { param($core, $pc, $cred) . $core; @{ Sw = @(Get-InstalledSoftware -Computer $pc -Credential $cred); Pr = @(Get-PrinterList -Computer $pc -Credential $cred) } } -ArgList @($r.Other, $script:remoteCred) -TimeoutSec 240 -Status "Listing programs and printers on $($r.Other)"
            if ($q.Ok -and $q.Output) { $o = @($q.Output)[-1]; $sw = @($o.Sw); $pr = @($o.Pr) }
        } else {
            foreach ($n in 'software', 'printers') {
                $csv = Join-Path $r.Src "$n.csv"
                if (Test-Path -LiteralPath $csv) { $x = @(Import-Csv -LiteralPath $csv -Encoding UTF8); if ($n -eq 'software') { $sw = $x } else { $pr = @($x | ForEach-Object { $_.Default = $_.Default -eq 'True'; $_ }) } }
            }
        }
    } catch { Write-Log "! Application inventory: $($_.Exception.Message)" }
    if (-not $sw -and -not $pr.Count) { return $(if ($r.Mode -in 'Import', 'Download') { '' } else { 'Application inventory: could not be listed.' }) }
    if (-not $sw) { $sw = @() }
    if ($r.Mode -in 'Export', 'Upload' -and (Test-Path -LiteralPath $r.Dst)) {   # travels with the copy (names only)
        $sw | Export-Csv -LiteralPath (Join-Path $r.Dst 'software.csv') -NoTypeInformation -Encoding UTF8
        if ($pr.Count) { $pr | Export-Csv -LiteralPath (Join-Path $r.Dst 'printers.csv') -NoTypeInformation -Encoding UTF8 }
    }
    New-Item -ItemType Directory -Force $RunDir | Out-Null
    $html = Join-Path $RunDir "Application inventory - $OldPc.html"
    New-SoftwareReport $sw $OldPc $html (Read-InstallerList $script:instCsv) $pr
    [ordered]@{ Pc = $OldPc; Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Sw = @($sw); Pr = @($pr) } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath ([IO.Path]::ChangeExtension($html, '.json')) -Encoding UTF8
    Write-Log "Application inventory of ${OldPc}: $($sw.Count) programs, $($pr.Count) printers - $html"
    foreach ($p in $pr) { Write-Log ("  printer: {0}{1}  {2}  [{3}]" -f $p.Name, $(if ($p.Default) { ' (default)' }), $(if ($p.IP) { $p.IP } else { $p.Port }), $p.Driver) }
    "Application inventory of ${OldPc}: $($sw.Count) programs, $($pr.Count) printers (with IP and driver): $html"
}

# ---------- Printers: carry over (opt-in) with Windows' Printer Migration tool ----------
# Backup on the old PC (this one, or \\OLDPC for Pull), restore on the new PC (this one, or \\NEWPC for Push).
# Drive/server: printers.printerExport travels with the copy and is restored on Import/Download (if ticked there).
# Printers already on the new PC are kept as they are.
function Move-Printers($r, [string]$RunDir) {
    if ($r.Other -eq 'TEST') { return '' }
    New-Item -ItemType Directory -Force $RunDir | Out-Null
    $file = Join-Path $RunDir 'printers.printerExport'
    $carried = if ($r.Mode -in 'Import', 'Download') { Join-Path $r.Src 'printers.printerExport' }
    if ($carried -and -not (Test-Path -LiteralPath $carried)) { Write-Log 'Printers: no printer backup came with this copy (tick it on the old PC).'; return '' }
    if (-not $carried) {
        $from = if ($r.Mode -eq 'Pull') { $r.Other } else { '' }
        $q = Invoke-Bg -Script { param($core, $f, $pc) . $core; Invoke-PrintBrm -Backup -File $f -Computer $pc } -ArgList @($file, $from) -TimeoutSec 600 -Status 'Backing up printers (drivers + settings)'
        $o = if ($q.Ok) { @($q.Output)[-1] }
        if (-not $o -or -not $o.Ok) { Write-Log "! Printer backup failed: $(if ($o) { $o.Output } else { 'no answer' })"; return 'Printers: NOT carried over (backup failed - see log). The Application inventory lists them with IP and driver.' }
        Write-Log "Printers backed up: $file"
        if ($r.Mode -in 'Export', 'Upload') { Copy-Item -LiteralPath $file (Join-Path $r.Dst 'printers.printerExport') -Force; return 'Printers: backed up with the copy - restored on the new PC at Import/Download (tick "Printers: carry over" there).' }
    } else { Copy-Item -LiteralPath $carried $file -Force }
    $to = if ($r.Mode -eq 'Push') { $r.Other } else { '' }
    $q = Invoke-Bg -Script { param($core, $f, $pc) . $core; Invoke-PrintBrm -Restore -File $f -Computer $pc } -ArgList @($file, $to) -TimeoutSec 900 -Status 'Restoring printers on the new PC (drivers + settings)'
    $o = if ($q.Ok) { @($q.Output)[-1] }
    Set-Content -LiteralPath (Join-Path $RunDir 'printers-restore.txt') -Value $(if ($o) { $o.Output } else { 'no answer' }) -Encoding UTF8
    if ($o -and $o.Ok) { Write-Log 'Printers restored on the new PC (existing printers kept).'; 'Printers: carried over to the new PC (drivers + settings).' }
    else { Write-Log "! Printer restore had problems - see $RunDir\printers-restore.txt"; 'Printers: restore had problems (see printers-restore.txt in the logs) - the Application inventory lists them with IP and driver.' }
}

# ---------- Advanced... ----------
function Show-Advanced {
    $a = $script:MigAdv
    Stop-AdvBlink
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = "$MigToolName - Advanced"; ClientSize = (S 640 772); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $form.Font }
    $add = { param($c) $d.Controls.Add($c); $c }
    $gray = [Drawing.Color]::DimGray; $bold = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
    $head = { param($t, $y) [void](& $add (New-Object Windows.Forms.Label -Property @{ Text = $t; Location = (P 12 $y); AutoSize = $true; Font = $bold })) }
    $lbl = { param($t, $x, $y, $w, $c) $l = New-Object Windows.Forms.Label -Property @{ Text = $t; Location = (P $x $y) }; if ($w) { $l.Size = S $w 18 } else { $l.AutoSize = $true }; if ($c) { $l.ForeColor = $c }; [void](& $add $l) }
    $num = { param($x, $y, $min, $max, $val) $n = New-Object Windows.Forms.NumericUpDown; $n.Location = P $x $y; $n.Size = S 60 23; $n.Minimum = $min; $n.Maximum = $max; $n.Value = [math]::Min($max, [math]::Max($min, [decimal]$val)); & $add $n }

    & $head 'Speed' 12
    & $lbl 'Copy threads:' 24 40
    $nThr = & $num 120 37 1 32 $a.Threads
    & $lbl 'Speed limit:' 210 40
    $nLim = & $num 290 37 0 1000 $a.LimitMBps
    & $lbl 'MB/s  (0 = full speed)' 356 40
    & $lbl 'A speed limit (daytime, busy network) copies one paced stream - robocopy cannot limit several at once.' 24 64 600 $gray
    $hasC = Test-RoboCompress
    $cbComp = & $add (New-Object Windows.Forms.CheckBox -Property @{ Location = (P 24 86); AutoSize = $true; Checked = ([bool]$a.Compress -and $hasC); Enabled = $hasC
        Text = $(if ($hasC) { 'SMB compression (helps on Wi-Fi and slow links; costs some CPU)' } else { "SMB compression - not available on this PC's Windows (Windows 11 / Server 2022 and later)" }) })

    & $head 'Reliability' 118
    & $lbl 'Retries per file:' 24 146
    $nRet = & $num 130 143 0 20 $a.Retries
    & $lbl 'Wait between retries:' 210 146
    $nWait = & $num 345 143 0 60 $a.WaitSec
    & $lbl 's  (more retries help on flaky Wi-Fi)' 410 146
    $cbVer = & $add (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Verify copies: SHA-256 of every copied file, here and there (slower; network, cable, drive)'; Location = (P 24 172); AutoSize = $true; Checked = [bool]$a.Verify })

    & $head 'Leave out' 204
    & $lbl 'File types:' 24 231
    $tXf = & $add (New-Object Windows.Forms.TextBox -Property @{ Location = (P 130 228); Size = (S 490 23); Text = "$($a.ExcludeFiles)" })
    & $lbl 'e.g.  *.iso; *.vhdx; *.bak     (separate with ;)' 130 253 400 $gray
    & $lbl 'Folder names:' 24 279
    $tXd = & $add (New-Object Windows.Forms.TextBox -Property @{ Location = (P 130 276); Size = (S 490 23); Text = "$($a.ExcludeFolders)" })
    & $lbl 'e.g.  node_modules; Cache; Old Backups' 130 301 400 $gray
    & $lbl 'Skip files older than' 24 327
    $nAge = & $num 160 324 0 50 $a.SkipOlderYears
    & $lbl 'years  (0 = keep everything)' 226 327

    & $head 'Extra folders outside the profiles' 360
    $tEx = & $add (New-Object Windows.Forms.TextBox -Property @{ Location = (P 24 384); Size = (S 490 56); Multiline = $true; ScrollBars = 'Vertical'; Text = (@($a.ExtraFolders) -join "`r`n") })
    $bExAdd = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Add...'; Location = (P 522 383); Size = (S 98 26) })
    & $lbl 'One per line, e.g. C:\Data (the path on the OLD PC) - copied to the same path on the new PC. Network, cable, drive.' 24 444 600 $gray
    $bExAdd.Add_Click({
        $f = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Folder on the OLD PC (this PC when it is the old one)' }
        if ($f.ShowDialog($d) -eq 'OK') { $tEx.Text = (@($tEx.Text.Trim(), $f.SelectedPath) | Where-Object { $_ }) -join "`r`n" }
    })

    & $head 'Installers' 474
    $cbInst = & $add (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Show the Installers button: your list of programs - download links, installers on the stick or a server'; Location = (P 24 498); AutoSize = $true; Checked = [bool]$a.Installers })

    & $head 'Clean up this PC' 530
    $sz = { param($p) if (Test-Path -LiteralPath $p) { $b = [long](Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; Format-Size $b } }
    $sys = $env:SystemDrive
    $clean = @(
        @{ Path = "$sys\Migration-Incoming"; Text = 'Download leftovers'; Del = $true; Why = 'decrypted server downloads left behind' },
        @{ Path = "$sys\Migration-Oversized"; Text = 'Set-aside large files'; Del = $true; Why = "large files set aside for an external drive - make sure they were carried over" },
        @{ Path = "$sys\Migration-Keys"; Text = 'Restore keys here'; Del = $true; Why = 'restore keys saved on this PC - without them those uploads can NOT be opened' },
        @{ Path = (Join-Path $env:ProgramData "$MigToolName\logs"); Text = 'Kept logs'; Del = $true; Why = 'logs kept when the tool removed itself' })
    $x = 24
    foreach ($c in $clean) {
        $s = & $sz $c.Path
        $b = & $add (New-Object Windows.Forms.Button -Property @{ Location = (P $x 554); Size = (S 116 42); Text = "$($c.Text)`r`n$(if ($s) { $s } else { '(none)' })"; Enabled = [bool]$s; Tag = $c })
        $b.Add_Click({
            $c = $this.Tag
            $ans = [Windows.Forms.MessageBox]::Show("$($c.Path)`r`n($($c.Why))`r`n`r`nYes = open it    No = DELETE it    Cancel = nothing", $MigToolName, 'YesNoCancel', 'Question')
            if ($ans -eq 'Yes') { Start-Process explorer.exe "`"$($c.Path)`"" }
            elseif ($ans -eq 'No' -and [Windows.Forms.MessageBox]::Show("Delete $($c.Path) and everything in it?", $MigToolName, 'YesNo', 'Warning') -eq 'Yes') {
                try { [IO.Directory]::Delete($c.Path, $true); Write-Log "Cleaned up: deleted $($c.Path)"; $this.Text = "$($c.Text)`r`n(deleted)"; $this.Enabled = $false }
                catch { [void][Windows.Forms.MessageBox]::Show("Couldn't delete it all: $($_.Exception.Message)", $MigToolName) }
            }
        })
        $x += 122
    }
    $pend = @(Get-MigrationHandoff $sys | ForEach-Object User)
    $bH = & $add (New-Object Windows.Forms.Button -Property @{ Location = (P $x 554); Size = (S 106 42); Text = "Waiting handoffs`r`n$(if ($pend.Count) { $pend.Count } else { '(none)' })"; Enabled = [bool]$pend.Count })
    $bH.Add_Click({
        $u = Show-Prompt 'Waiting handoffs' "Files waiting in C:\Migration for their first sign-in:  $($pend -join ', ')`r`n`r`nType a user name to CANCEL theirs (their files in C:\Migration stay until you delete them):"
        if (-not $u) { return }
        $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Set-MigrationHandoff.ps1')`" -Remove -User `"$($u.Trim())`"" -WindowStyle Hidden -Wait -PassThru
        Write-Log "Handoff for $($u.Trim()) cancelled (exit $($p.ExitCode))."
        [void][Windows.Forms.MessageBox]::Show("Handoff for $($u.Trim()) cancelled. C:\Migration\$($u.Trim()) is still there - delete it if it isn't needed.", $MigToolName)
    })

    & $head 'Updates' 612
    $cbUpd = & $add (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Check for updates when MoveMate starts (asks GitHub for the latest release - nothing else is sent)'; Location = (P 24 636); AutoSize = $true; Checked = [bool]$a.CheckUpdates })
    $bUpd = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Check now'; Location = (P 24 660); Size = (S 100 26) })
    $lUpd = & $add (New-Object Windows.Forms.LinkLabel -Property @{ Location = (P 132 665); Size = (S 490 18); LinkArea = (New-Object Windows.Forms.LinkArea(0, 0)) })
    $setUpd = {
        param($t, $link)
        $lUpd.Text = $t
        $lUpd.LinkArea = if ($link) { New-Object Windows.Forms.LinkArea($t.IndexOf($link), $link.Length) } else { New-Object Windows.Forms.LinkArea(0, 0) }
    }
    if ($script:update) { & $setUpd "$MigToolName $($script:update.Version) is available (this copy is $MigToolVersion).  Download page" 'Download page' }
    else { & $setUpd "This copy is $MigToolName $MigToolVersion." $null }
    $lUpd.Add_LinkClicked({ Start-Process explorer.exe "`"$(if ($script:update.Url) { $script:update.Url } else { "https://github.com/$MigUpdateRepo/releases/latest" })`"" })
    $bUpd.Add_Click({
        $bUpd.Enabled = $false
        $r = Invoke-Bg -Script { param($core) . $core; Get-MigLatestRelease 10 } -TimeoutSec 15 -Status 'Checking for updates'
        $lblStatus.Text = ''; $bUpd.Enabled = $true
        $rel = @($r.Output)[0]
        if ($r.TimedOut) { & $setUpd "No answer from GitHub (offline, or the network blocks it). This copy is $MigToolVersion." $null }
        elseif (-not $r.Ok -or -not $rel) {
            $why = if ("$($r.Error)" -match '404') { 'no release is published on GitHub yet' } else { "$($r.Error)" }
            & $setUpd "Couldn't check: $why. This copy is $MigToolVersion." $null
        }
        elseif ($rel.Newer) { $script:update = $rel; & $setUpd "$MigToolName $($rel.Version) is available (this copy is $MigToolVersion).  Download page" 'Download page'; Write-Log "Update available: $MigToolName $($rel.Version) (this copy is $MigToolVersion)." }
        else { & $setUpd "You have the latest version ($MigToolVersion)." $null }
    })

    & $head 'Settings' 698
    $bExp = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Export settings...'; Location = (P 24 722); Size = (S 130 28) })
    $bImp = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Import settings...'; Location = (P 160 722); Size = (S 130 28) })
    $bRst = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Reset to defaults'; Location = (P 296 722); Size = (S 130 28) })
    & $lbl 'Same setup on every stick: export, then import.' 24 754 400 $gray
    $ok = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = (P 452 730); Size = (S 84 30) })
    $no = & $add (New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 542 730); Size = (S 84 30); DialogResult = 'Cancel' })
    $d.CancelButton = $no
    $bExp.Add_Click({
        Save-Settings
        $f = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'Settings (*.json)|*.json'; FileName = "$MigToolName settings.json" }
        if ($f.ShowDialog($d) -eq 'OK') { Copy-Item -LiteralPath $settingsFile $f.FileName -Force; Write-Log "Settings exported to $($f.FileName)" }
    })
    $bImp.Add_Click({
        $f = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Settings (*.json)|*.json' }
        if ($f.ShowDialog($d) -ne 'OK') { return }
        try { [void](Get-Content -LiteralPath $f.FileName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { [void][Windows.Forms.MessageBox]::Show('That is not a settings file.', $MigToolName); return }
        Copy-Item -LiteralPath $f.FileName $settingsFile -Force; Read-Settings
        Write-Log "Settings imported from $($f.FileName)"
        [void][Windows.Forms.MessageBox]::Show('Settings imported.', $MigToolName); $d.Close()
    })
    $bRst.Add_Click({
        if ([Windows.Forms.MessageBox]::Show('Reset every setting to the default (messages, report PC, Advanced options...)? MoveMate then needs to be closed and opened again.', $MigToolName, 'YesNo', 'Warning') -ne 'Yes') { return }
        Remove-Item -LiteralPath $settingsFile -Force -ErrorAction SilentlyContinue; $script:skipSave = $true; Import-MigAdvanced
        Write-Log 'Settings reset to defaults - close and reopen MoveMate.'
        [void][Windows.Forms.MessageBox]::Show('Defaults restored. Close MoveMate and open it again.', $MigToolName); $d.Close()
    })
    $ok.Add_Click({
        $bad = @($tEx.Lines | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^[A-Za-z]:\\[^*?"<>|]+$' })
        if ($bad.Count) { [void][Windows.Forms.MessageBox]::Show("Extra folders need a full path like C:\Data:`r`n$($bad -join "`r`n")", $MigToolName); return }
        $sysd = @($tEx.Lines | Where-Object { $_.Trim() -match '^[A-Za-z]:\\(Windows|Program Files.*|Users|ProgramData)\\?$' })
        if ($sysd.Count) { [void][Windows.Forms.MessageBox]::Show("Not a system folder:`r`n$($sysd -join "`r`n")", $MigToolName); return }
        $d.DialogResult = 'OK'
    })
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $a.Threads = [int]$nThr.Value; $a.LimitMBps = [int]$nLim.Value; $a.Compress = $cbComp.Checked; $a.Retries = [int]$nRet.Value; $a.WaitSec = [int]$nWait.Value
    $a.Verify = $cbVer.Checked; $a.ExcludeFiles = $tXf.Text.Trim(); $a.ExcludeFolders = $tXd.Text.Trim(); $a.SkipOlderYears = [int]$nAge.Value
    $a.ExtraFolders = @($tEx.Lines | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ })
    $a.Installers = $cbInst.Checked; $a.CheckUpdates = $cbUpd.Checked
    $btnInst.Visible = [bool]$a.Installers
    Save-Settings
    $on = @()
    if ($a.LimitMBps) { $on += "limit $($a.LimitMBps) MB/s" } elseif ($a.Threads -ne 8) { $on += "$($a.Threads) threads" }
    if ($a.Compress) { $on += 'compression' }; if ($a.Verify) { $on += 'verify' }
    if ($a.ExcludeFiles -or $a.ExcludeFolders -or $a.SkipOlderYears) { $on += 'leave-out rules' }
    if ($a.ExtraFolders.Count) { $on += "$($a.ExtraFolders.Count) extra folder(s)" }
    Write-Log "Advanced: $(if ($on.Count) { $on -join ', ' } else { 'defaults' })."
}

# ---------- Installers (Advanced: "Show the Installers button") ----------
# extras\installers.csv = the list: Name, Url (download page = the blue link), File, Args (silent switches), Match (name in
# Apps & features, wildcards, for "On this PC"), Notes. File = a name in MoveMate\extras\installers, OR a full path /
# \\server\share path. Ticked rows install one after another; no file = its download page opens.
$script:instCsv = Join-Path $script:toolDir 'extras\installers.csv'
$script:instDir = Join-Path $script:toolDir 'extras\installers'
$script:instDirShown = (Split-Path $script:toolDir -Leaf) + '\extras\installers'
function Get-InstallerPath($E) { if (-not $E.File) { $null } elseif ($E.File -match '^(\\\\|[A-Za-z]:\\)') { $E.File } else { Join-Path $script:instDir $E.File } }
function Update-InstallerGrid {
    $q = $script:inst; $g = $q.Grid; $g.Rows.Clear()
    foreach ($e in @(Read-InstallerList $script:instCsv)) {
        $p = Get-InstallerPath $e
        $where = if (-not $p) { '-' } elseif (-not (Test-Path -LiteralPath $p)) { "MISSING: $($e.File)" } elseif ($p -like '\\*') { "on the server: $(Split-Path $p -Leaf)" } else { $(if ($e.File -match '^[A-Za-z]:') { $p } else { "in $($script:instDirShown): $($e.File)" }) }
        $m = if ($e.Match) { $e.Match } else { $e.Name }
        $have = @($q.Have | Where-Object { $_ -like "*$m*" -or $_ -like $m }).Count
        $i = $g.Rows.Add($false, $e.Name, $where, $(if ($have) { 'yes' } else { '' }), $e.Notes, '')
        $g.Rows[$i].Tag = $e
        if (-not $e.Url) { $g.Rows[$i].Cells[1] = New-Object Windows.Forms.DataGridViewTextBoxCell -Property @{ Value = $e.Name } }
    }
    $q.Count.Text = "$($g.Rows.Count) program(s) in $script:instCsv"
}
function Show-Installers {
    if (-not (Test-Path -LiteralPath $script:instCsv)) { New-Item -ItemType Directory -Force (Split-Path $script:instCsv) | Out-Null; 'Name,Url,File,Args,Match,Notes' | Set-Content -LiteralPath $script:instCsv -Encoding UTF8 }
    $f = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = "$MigToolName - Installers"; ClientSize = (S 990 540); MinimumSize = (S 760 380); StartPosition = 'CenterParent'; Font = $form.Font }
    $g = New-Object Windows.Forms.DataGridView -Property @{ Location = (P 12 12); Size = (S 966 446); Anchor = 'Top, Bottom, Left, Right'; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; BackgroundColor = [Drawing.Color]::White }
    [void]$g.Columns.Add((New-Object Windows.Forms.DataGridViewCheckBoxColumn -Property @{ HeaderText = 'Pick'; Width = 50 }))
    [void]$g.Columns.Add((New-Object Windows.Forms.DataGridViewLinkColumn -Property @{ HeaderText = 'Program (opens its page)'; Width = 230; ReadOnly = $true; TrackVisitedState = $false }))
    foreach ($c in @(@('Installer', 230), @('On this PC', 75), @('Notes', 230), @('Status', 145))) { [void]$g.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ HeaderText = $c[0]; Width = $c[1]; ReadOnly = $true })) }
    $cnt = New-Object Windows.Forms.Label -Property @{ Location = (P 12 464); Size = (S 740 18); ForeColor = [Drawing.Color]::DimGray; Anchor = 'Bottom, Left, Right'; AutoEllipsis = $true }
    $bGo = New-Object Windows.Forms.Button -Property @{ Text = 'Install checked'; Location = (P 12 496); Size = (S 120 32); Anchor = 'Bottom, Left'; Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
    $bRm = New-Object Windows.Forms.Button -Property @{ Text = 'Remove checked'; Location = (P 138 496); Size = (S 110 32); Anchor = 'Bottom, Left' }
    $bEd = New-Object Windows.Forms.Button -Property @{ Text = 'Edit list...'; Location = (P 254 496); Size = (S 96 32); Anchor = 'Bottom, Left' }
    $bIm = New-Object Windows.Forms.Button -Property @{ Text = 'Import CSV...'; Location = (P 356 496); Size = (S 100 32); Anchor = 'Bottom, Left' }
    $bEx = New-Object Windows.Forms.Button -Property @{ Text = 'Save CSV as...'; Location = (P 462 496); Size = (S 104 32); Anchor = 'Bottom, Left' }
    $bDir = New-Object Windows.Forms.Button -Property @{ Text = 'Installers folder'; Location = (P 572 496); Size = (S 116 32); Anchor = 'Bottom, Left' }
    $bOld = New-Object Windows.Forms.Button -Property @{ Text = 'App inventory  ▾'; Location = (P 694 496); Size = (S 130 32); Anchor = 'Bottom, Left' }
    $bCl = New-Object Windows.Forms.Button -Property @{ Text = 'Close'; Location = (P 888 496); Size = (S 90 32); Anchor = 'Bottom, Right'; DialogResult = 'Cancel' }
    # Printer check after setting up a PC: test pages
    $lTest = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Print a test page: paperjammed.net'; Location = (P 762 464); Size = (S 216 18); TextAlign = 'TopRight'; Anchor = 'Bottom, Right'; LinkBehavior = 'HoverUnderline' }
    $lTest.Add_LinkClicked({ Start-Process explorer.exe 'https://paperjammed.net/' })
    $f.Controls.AddRange(@($g, $cnt, $bGo, $bRm, $bEd, $bIm, $bEx, $bDir, $bOld, $lTest, $bCl)); $f.CancelButton = $bCl
    $script:inst = @{ Form = $f; Grid = $g; Count = $cnt; Go = $bGo; Have = @(); Queue = (New-Object Collections.Generic.List[object]); Proc = $null; Row = $null; Timer = $null }
    $cnt.Text = 'Checking what is installed on this PC...'
    $f.Add_Shown({ [Windows.Forms.Application]::DoEvents(); $script:inst.Have = @(Get-InstalledSoftware | ForEach-Object Name); Update-InstallerGrid })
    $g.Add_CellContentClick({ param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 1) { return }
        $u = $s.Rows[$e.RowIndex].Tag.Url
        if ($u) { Start-Process explorer.exe "`"$u`"" }   # opens in the signed-in user's browser (not as admin)
    })
    $bGo.Add_Click({
        $q = $script:inst
        foreach ($row in $q.Grid.Rows) { if ($row.Cells[0].Value -eq $true) { $q.Queue.Add($row); $row.Cells[5].Value = 'queued' } }
        if (-not $q.Queue.Count) { [void][Windows.Forms.MessageBox]::Show('Tick the programs to install first.', $MigToolName); return }
        $q.Go.Enabled = $false
        $q.Timer = New-Object Windows.Forms.Timer -Property @{ Interval = 800 }
        $q.Timer.Add_Tick({ Step-InstallQueue }); $q.Timer.Start(); Step-InstallQueue
    })
    # Remove checked: takes the ticked programs off the list (after a confirm). Installer files are left where they are.
    $bRm.Add_Click({
        $q = $script:inst
        if ($q.Proc -or $q.Queue.Count) { [void][Windows.Forms.MessageBox]::Show('Wait until the installs are finished.', $MigToolName); return }
        $rows = @($q.Grid.Rows | Where-Object { $_.Cells[0].Value -eq $true })
        if (-not $rows.Count) { [void][Windows.Forms.MessageBox]::Show('Tick the programs to remove from the list first.', $MigToolName); return }
        $names = @($rows | ForEach-Object { $_.Tag.Name })
        if ([Windows.Forms.MessageBox]::Show("Remove $($names.Count) program(s) from the Installers list?`r`n`r`n  $($names -join "`r`n  ")`r`n`r`nOnly the list lines are removed - installer files stay in $($script:instDirShown).", $MigToolName, 'YesNo', 'Question') -ne 'Yes') { return }
        $gone = @($rows | ForEach-Object { "$($_.Tag.Name)|$($_.Tag.Url)|$($_.Tag.File)" })
        $keep = @(Read-InstallerList $script:instCsv | Where-Object { $gone -notcontains "$($_.Name)|$($_.Url)|$($_.File)" })
        if ($keep.Count) { $keep | Export-Csv -LiteralPath $script:instCsv -NoTypeInformation -Encoding UTF8 } else { 'Name,Url,File,Args,Match,Notes' | Set-Content -LiteralPath $script:instCsv -Encoding UTF8 }
        Write-Log "Installers list: removed $($names -join ', ')."
        Update-InstallerGrid
    })
    $bEd.Add_Click({ if (Show-InstallerEditor) { Update-InstallerGrid } })
    $bIm.Add_Click({
        $o = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'CSV (*.csv)|*.csv' }
        if ($o.ShowDialog($script:inst.Form) -ne 'OK') { return }
        $new = @(Read-InstallerList $o.FileName)
        if (-not $new.Count) { [void][Windows.Forms.MessageBox]::Show('No rows with a Name column in that file. Columns: Name, Url, File, Args, Match, Notes.', $MigToolName); return }
        $ans = [Windows.Forms.MessageBox]::Show("$($new.Count) program(s) in that file.`r`n`r`nYes = REPLACE your list    No = ADD to it (same names are updated)", $MigToolName, 'YesNoCancel', 'Question')
        if ($ans -eq 'Cancel') { return }
        $list = if ($ans -eq 'Yes') { $new } else { $names = @($new | ForEach-Object Name); @(@(Read-InstallerList $script:instCsv | Where-Object { $names -notcontains $_.Name }) + $new) }
        $list | Export-Csv -LiteralPath $script:instCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Installers list: imported $($new.Count) from $($o.FileName)."; Update-InstallerGrid
    })
    $bEx.Add_Click({
        $s = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'CSV (*.csv)|*.csv'; FileName = 'installers.csv' }
        if ($s.ShowDialog($script:inst.Form) -eq 'OK') { Copy-Item -LiteralPath $script:instCsv $s.FileName -Force }
    })
    $bDir.Add_Click({ New-Item -ItemType Directory -Force $script:instDir | Out-Null; Start-Process explorer.exe "`"$script:instDir`"" })
    # Application inventory menu: the ones made so far (each copy makes one when 'Settings & lists' > 'Application inventory for IT' is on),
    # or list one NOW - for this PC, or the other PC typed in section 1 (needs Connect... for its admin access).
    $bOld.Add_Click({
        $m = New-Object Windows.Forms.ContextMenuStrip
        $have = @(Get-ChildItem -LiteralPath $logRoot -Recurse -Include 'Application inventory - *.json', 'PC inventory - *.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12)
        foreach ($h in $have) {
            $it = $m.Items.Add("$($h.BaseName -replace '^(Application|PC) inventory - ', '')    (copy of $($h.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"); $it.Tag = $h.FullName
            $it.Add_Click({
                if ($this.Tag -like '*.html') { Start-Process explorer.exe "`"$($this.Tag)`""; return }   # (older runs: the page only)
                $j = Get-Content -LiteralPath $this.Tag -Raw -Encoding UTF8 | ConvertFrom-Json
                Show-AppInventory @{ Pc = $j.Pc; Date = $j.Date; Sw = @($j.Sw); Pr = @($j.Pr) }
            })
        }
        if (-not $have.Count) { $x = $m.Items.Add('(none saved yet - each copy saves one; or list one now:)'); $x.Enabled = $false }
        [void]$m.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        $mine = $m.Items.Add("List programs on this PC ($env:COMPUTERNAME)"); $mine.Tag = ''
        $mine.Add_Click({ New-PcInventoryNow '' })
        $other = $txtPc.Text.Trim().TrimStart('\')
        if (($rbNet.Checked -or $rbCable.Checked) -and $other -and $other -ne 'TEST') {
            $o = $m.Items.Add("List programs on $other (the other PC)"); $o.Tag = $other
            $o.Add_Click({ New-PcInventoryNow $this.Tag })
        }
        $m.Show($this, (P 0 $this.Height))
    })
    $f.Add_FormClosing({ param($s, $e)
        $q = $script:inst
        if ($q.Proc -or $q.Queue.Count) {
            if ([Windows.Forms.MessageBox]::Show('Installs are still queued. Close anyway? (The one running keeps running; the rest are not started.)', $MigToolName, 'YesNo', 'Question') -ne 'Yes') { $e.Cancel = $true; return }
            $q.Queue.Clear()
        }
        if ($q.Timer) { $q.Timer.Stop() }
    })
    [void]$f.ShowDialog($form)
}
# Application inventory on demand (programs + printers), without a copy: this PC, or another over DCOM (Connect... first).
# Shown in the viewer only - nothing is saved (copies save their own).
function New-PcInventoryNow([string]$Computer) {
    $pc = if ($Computer) { $Computer.ToUpper() } else { $env:COMPUTERNAME }
    $script:inst.Form.Cursor = 'WaitCursor'
    try {
        $q = Invoke-Bg -Script { param($core, $c, $cred) . $core
            if ($c) { @{ Sw = @(Get-InstalledSoftware -Computer $c -Credential $cred); Pr = @(Get-PrinterList -Computer $c -Credential $cred) } }
            else { @{ Sw = @(Get-InstalledSoftware); Pr = @(Get-PrinterList) } }
        } -ArgList @($Computer, $script:remoteCred) -TimeoutSec 240 -Status "Listing programs and printers on $pc"
    } finally { $script:inst.Form.Cursor = 'Default' }
    $o = if ($q.Ok -and $q.Output) { @($q.Output)[-1] }
    if (-not $o -or -not $o.Sw) { [void][Windows.Forms.MessageBox]::Show("Couldn't list $pc's programs$(if ($Computer) { ' - is it on, and did you Connect... with your admin login?' }).", $MigToolName); return }
    Show-AppInventory @{ Pc = $pc; Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Sw = @($o.Sw); Pr = @($o.Pr) }
}
# "7-Zip 26.03 (x64)" -> "7-Zip": a name for the Installers list (versions/bitness change; Match gets a * after it)
function Get-CleanAppName([string]$Name) {
    $n = $Name -replace '\s*[\(\[]?(x64|x86|64-bit|32-bit|amd64|arm64)[\)\]]?', '' -replace '\s+v?\d+(\.\d+)+.*$', '' -replace '\s+-\s*$', ''
    if ($n.Trim()) { $n.Trim() } else { $Name.Trim() }
}
# The viewer: programs (search, tick, add to the Installers list, search the web) and printers (name, IP, driver).
function Show-AppInventory($Data) {
    $f = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = "Application inventory - $($Data.Pc)"; ClientSize = (S 960 620); MinimumSize = (S 760 420); StartPosition = 'CenterParent'; Font = $form.Font }
    $hdr = New-Object Windows.Forms.Label -Property @{ Location = (P 12 10); Size = (S 600 20); Text = "$($Data.Pc): $(@($Data.Sw).Count) programs (Windows' own parts left out), $(@($Data.Pr).Count) printers - listed $($Data.Date)" }
    $lS = New-Object Windows.Forms.Label -Property @{ Text = 'Search:'; Location = (P 640 10); AutoSize = $true; Anchor = 'Top, Right' }
    $tS = New-Object Windows.Forms.TextBox -Property @{ Location = (P 692 7); Size = (S 256 23); Anchor = 'Top, Right' }
    $g = New-Object Windows.Forms.DataGridView -Property @{ Location = (P 12 36); Size = (S 936 380); Anchor = 'Top, Bottom, Left, Right'; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; BackgroundColor = [Drawing.Color]::White }
    [void]$g.Columns.Add((New-Object Windows.Forms.DataGridViewCheckBoxColumn -Property @{ HeaderText = 'Add'; Width = 40 }))
    foreach ($c in @(@('Program', 330), @('Version', 120), @('Publisher', 220), @('Installers list', 200))) { [void]$g.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ HeaderText = $c[0]; Width = $c[1]; ReadOnly = $true })) }
    $lP = New-Object Windows.Forms.Label -Property @{ Text = 'Printers'; Location = (P 12 424); AutoSize = $true; Anchor = 'Bottom, Left'; Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
    $gp = New-Object Windows.Forms.DataGridView -Property @{ Location = (P 12 444); Size = (S 936 120); Anchor = 'Bottom, Left, Right'; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false; ReadOnly = $true; BackgroundColor = [Drawing.Color]::White }
    foreach ($c in @(@('Printer', 300), @('IP / host', 140), @('Driver', 300), @('Port', 170))) { [void]$gp.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ HeaderText = $c[0]; Width = $c[1] })) }
    foreach ($p in @($Data.Pr)) { [void]$gp.Rows.Add("$($p.Name)$(if ("$($p.Default)" -eq 'True') { '  (default)' })", $p.IP, $p.Driver, $p.Port) }
    $bAdd = New-Object Windows.Forms.Button -Property @{ Text = 'Add checked to Installers list'; Location = (P 12 576); Size = (S 200 32); Anchor = 'Bottom, Left'; Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
    $bWeb = New-Object Windows.Forms.Button -Property @{ Text = 'Search the web for it'; Location = (P 220 576); Size = (S 150 32); Anchor = 'Bottom, Left' }
    $lMsg = New-Object Windows.Forms.Label -Property @{ Location = (P 378 584); Size = (S 468 18); ForeColor = [Drawing.Color]::DarkSlateBlue; Anchor = 'Bottom, Left, Right'; AutoEllipsis = $true }
    $bCl = New-Object Windows.Forms.Button -Property @{ Text = 'Close'; Location = (P 858 576); Size = (S 90 32); Anchor = 'Bottom, Right'; DialogResult = 'Cancel' }
    $f.Controls.AddRange(@($hdr, $lS, $tS, $g, $lP, $gp, $bAdd, $bWeb, $lMsg, $bCl)); $f.CancelButton = $bCl
    $script:ainv = @{ Data = $Data; Grid = $g; Search = $tS; Msg = $lMsg }
    $fill = {
        $q = $script:ainv.Search.Text.Trim(); $list = @(Read-InstallerList $script:instCsv); $gg = $script:ainv.Grid
        $gg.Rows.Clear()
        foreach ($s in @($script:ainv.Data.Sw)) {
            if ($q -and "$($s.Name) $($s.Publisher)" -notlike "*$q*") { continue }
            $in = @($list | Where-Object { $m = if ($_.Match) { $_.Match } else { $_.Name }; $s.Name -like "*$m*" -or $s.Name -like $m })[0]
            $i = $gg.Rows.Add($false, $s.Name, $s.Version, $s.Publisher, $(if ($in) { "yes ($($in.Name))" } else { '' }))
            $gg.Rows[$i].Tag = $s
        }
    }
    $script:ainv.Fill = $fill; & $fill
    $tS.Add_TextChanged({ & $script:ainv.Fill })
    $bWeb.Add_Click({
        $row = $script:ainv.Grid.CurrentRow; if (-not $row) { return }
        Start-Process explorer.exe "`"https://www.google.com/search?q=$([Uri]::EscapeDataString("$($row.Tag.Name) download"))`""
    })
    $bAdd.Add_Click({
        $picked = @($script:ainv.Grid.Rows | Where-Object { $_.Cells[0].Value -eq $true } | ForEach-Object Tag)
        if (-not $picked.Count) { $script:ainv.Msg.Text = 'Tick the programs to add first.'; return }
        $list = New-Object Collections.Generic.List[object]; foreach ($x in @(Read-InstallerList $script:instCsv)) { $list.Add($x) }
        $added = @()
        foreach ($s in $picked) {
            $n = Get-CleanAppName $s.Name
            if (@($list | Where-Object { $_.Name -eq $n }).Count) { continue }
            $list.Add([pscustomobject]@{ Name = $n; Url = "https://www.google.com/search?q=$([Uri]::EscapeDataString("$n download"))"; File = ''; Args = ''; Match = "$n*"
                Notes = "from $($script:ainv.Data.Pc) - add the installer or its download page (Edit list)" })
            $added += $n
        }
        if ($added.Count) {
            New-Item -ItemType Directory -Force (Split-Path $script:instCsv) | Out-Null
            $list | Export-Csv -LiteralPath $script:instCsv -NoTypeInformation -Encoding UTF8
            Write-Log "Installers list: added $($added -join ', ') (from $($script:ainv.Data.Pc))."
            if ($script:inst -and $script:inst.Grid -and -not $script:inst.Grid.IsDisposed) { Update-InstallerGrid }
        }
        $script:ainv.Msg.Text = if ($added.Count) { "Added $($added.Count) to the Installers list: $($added -join ', ')" } else { 'Already in the Installers list.' }
        & $script:ainv.Fill
    })
    [void]$f.ShowDialog()
}
# One step of the install queue: finish the running one (exit code), start the next. Timer-driven (window stays usable).
function Step-InstallQueue {
    $q = $script:inst
    if ($q.Proc) {
        if (-not $q.Proc.HasExited) { return }
        $code = $q.Proc.ExitCode; $q.Proc = $null
        $q.Row.Cells[5].Value = switch ($code) { 0 { 'installed' } 3010 { 'installed - restart needed' } 1641 { 'installed - restarting' } 1602 { 'cancelled' } default { "failed (code $code)" } }
        Write-Log "Installer: $($q.Row.Tag.Name) -> $($q.Row.Cells[5].Value)"
    }
    if (-not $q.Queue.Count) {
        if ($q.Timer) { $q.Timer.Stop() }; $q.Go.Enabled = $true
        $q.Have = @(Get-InstalledSoftware | ForEach-Object Name)
        foreach ($row in $q.Grid.Rows) { $e = $row.Tag; $m = if ($e.Match) { $e.Match } else { $e.Name }; $row.Cells[3].Value = if (@($q.Have | Where-Object { $_ -like "*$m*" -or $_ -like $m }).Count) { 'yes' } else { '' } }
        return
    }
    $row = $q.Queue[0]; $q.Queue.RemoveAt(0); $row.Cells[0].Value = $false; $q.Row = $row
    $e = $row.Tag; $p = Get-InstallerPath $e
    if ($p -and (Test-Path -LiteralPath $p)) {
        $ext = [IO.Path]::GetExtension($p).ToLower()
        $exe, $argl = switch ($ext) {
            '.msi' { 'msiexec.exe', ("/i `"$p`" $($e.Args)".Trim()) }
            { $_ -in '.cmd', '.bat' } { 'cmd.exe', "/c `"`"$p`" $($e.Args)`"" }
            default { $p, $e.Args }
        }
        try {
            $q.Proc = if ($argl) { Start-Process $exe -ArgumentList $argl -PassThru } else { Start-Process $exe -PassThru }
            $null = $q.Proc.Handle; $row.Cells[5].Value = 'installing...'
            Write-Log "Installer: $($e.Name) - $exe $argl"
        } catch { $row.Cells[5].Value = "could not start: $($_.Exception.Message)"; $q.Proc = $null }
    } elseif ($e.Url) { Start-Process explorer.exe "`"$($e.Url)`""; $row.Cells[5].Value = $(if ($p) { 'file missing - page opened' } else { 'download page opened' }) }
    else { $row.Cells[5].Value = 'no installer or link' }
}
# The list itself: Name, Url, File, Args, Match, Notes. "Add installer file..." copies a local file to extras\installers
# (on the stick) - a file on a server (\\...) or a network drive is used where it is.
function Show-InstallerEditor {
    $d = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = 'Edit the Installers list'; ClientSize = (S 1000 520); MinimumSize = (S 760 380); StartPosition = 'CenterParent'; Font = $form.Font }
    $g = New-Object Windows.Forms.DataGridView -Property @{ Location = (P 12 12); Size = (S 976 400); Anchor = 'Top, Bottom, Left, Right'; AllowUserToAddRows = $true; AllowUserToDeleteRows = $true; BackgroundColor = [Drawing.Color]::White }
    foreach ($c in @(@('Name', 170), @('Url', 250), @('File', 190), @('Args', 110), @('Match', 120), @('Notes', 130))) { [void]$g.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ HeaderText = $c[0]; Name = $c[0]; Width = $c[1] })) }
    foreach ($e in @(Read-InstallerList $script:instCsv)) { [void]$g.Rows.Add($e.Name, $e.Url, $e.File, $e.Args, $e.Match, $e.Notes) }
    $hint = New-Object Windows.Forms.Label -Property @{ Location = (P 12 418); Size = (S 976 54); ForeColor = [Drawing.Color]::DimGray; Anchor = 'Bottom, Left, Right'
        Text = "Url = download/install page (the blue link).   File = installer name in $($script:instDirShown), or a full path such as \\server\share\setup.exe.`r`nArgs = silent-install switches, e.g. /qn for .msi, /S for many .exe (empty = the normal installer window).   Match = its name in Apps & features (wildcards *) for 'On this PC'.`r`nAdd installer file: click a row's File cell first to fill that row - otherwise it adds a new row. Select a row and press Delete to remove it." }
    $bAdd = New-Object Windows.Forms.Button -Property @{ Text = 'Add installer file...'; Location = (P 12 478); Size = (S 150 30); Anchor = 'Bottom, Left' }
    $bSave = New-Object Windows.Forms.Button -Property @{ Text = 'Save'; Location = (P 808 478); Size = (S 86 30); Anchor = 'Bottom, Right' }
    $bNo = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (P 902 478); Size = (S 86 30); Anchor = 'Bottom, Right'; DialogResult = 'Cancel' }
    $d.Controls.AddRange(@($g, $hint, $bAdd, $bSave, $bNo)); $d.CancelButton = $bNo
    # Status of a background copy (big installers on a slow stick take minutes - the window must keep responding)
    $lCopy = New-Object Windows.Forms.Label -Property @{ Location = (P 172 485); Size = (S 620 18); ForeColor = [Drawing.Color]::DarkSlateBlue; Anchor = 'Bottom, Left, Right'; AutoEllipsis = $true }
    $d.Controls.Add($lCopy)
    $script:edCopy = $null
    # Add installer file: into the File cell you clicked (that row), otherwise a NEW row at the bottom. A local file is copied
    # to extras\installers in the background; a file on a server (\\...) or a network drive is used where it is.
    $bAdd.Add_Click({
        if ($script:edCopy) { [void][Windows.Forms.MessageBox]::Show('One copy at a time - wait for the current one to finish.', $MigToolName); return }
        $cc = $g.CurrentCell
        $target = if ($cc -and $g.Columns[$cc.ColumnIndex].Name -eq 'File' -and -not $g.Rows[$cc.RowIndex].IsNewRow) { $g.Rows[$cc.RowIndex] }
        if ($script:pickOverride) { $src = $script:pickOverride }   # (automated tests)
        else {
            $o = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Installers (*.msi;*.exe;*.cmd;*.bat)|*.msi;*.exe;*.cmd;*.bat|All files|*.*' }
            if ($o.ShowDialog($d) -ne 'OK') { return }
            $src = $o.FileName
        }
        $drv = if ($src -match '^([A-Za-z]):') { (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Matches[1]):'" -ErrorAction SilentlyContinue) }
        # Already in the list (same file)? Point at that row instead of adding a duplicate
        $leafIn = Split-Path $src -Leaf
        $dup = if (-not $target) { @($g.Rows | Where-Object { -not $_.IsNewRow -and ("$($_.Cells['File'].Value)" -eq $leafIn -or "$($_.Cells['File'].Value)" -eq $src) })[0] }
        if ($dup) { $g.CurrentCell = $dup.Cells['File']; $lCopy.Text = "$leafIn is already in the list ($($dup.Cells['Name'].Value))."; return }
        $row = if ($target) { $target } else { $g.Rows[$g.Rows.Add([IO.Path]::GetFileNameWithoutExtension($src), '', '', '', '', '')] }
        if (-not "$($row.Cells['Args'].Value)" -and $src -like '*.msi') { $row.Cells['Args'].Value = '/qn' }
        $g.CurrentCell = $row.Cells['File']
        if ($src -like '\\*' -or $drv.DriveType -eq 4) {
            # on a server: keep the path (a mapped letter becomes \\server\share so it works on every PC)
            if ($drv.DriveType -eq 4 -and $drv.ProviderName) { $src = $drv.ProviderName + $src.Substring(2) }
            $row.Cells['File'].Value = $src; return
        }
        $leaf = Split-Path $src -Leaf; $dst = Join-Path $script:instDir $leaf
        New-Item -ItemType Directory -Force $script:instDir | Out-Null
        $len = (Get-Item -LiteralPath $src).Length
        if (Test-Path -LiteralPath $dst) {
            if ((Get-Item -LiteralPath $dst).Length -eq $len) { $row.Cells['File'].Value = $leaf; $lCopy.Text = "$leaf is already in $($script:instDirShown)."; return }
            if ([Windows.Forms.MessageBox]::Show("A different $leaf is already in $($script:instDirShown). Replace it?", $MigToolName, 'YesNo', 'Question') -ne 'Yes') { return }
        }
        $row.Cells['File'].Value = "copying... $leaf"
        $sync = [hashtable]::Synchronized(@{ Done = [long]0; Total = $len; Error = $null; Finished = $false; Cancel = $false })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($src, $dst, $sync)
            $tmp = "$dst.part"
            try {
                $in = [IO.File]::OpenRead($src); $out = [IO.File]::Create($tmp)
                try {
                    $buf = New-Object byte[] 4MB
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { if ($sync.Cancel) { throw 'cancelled' }; $out.Write($buf, 0, $n); $sync.Done += $n }
                    $out.Flush($true)
                } finally { $in.Close(); $out.Close() }
                Move-Item -LiteralPath $tmp $dst -Force   # only a complete copy gets the real name
            } catch { $sync.Error = "$_"; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            $sync.Finished = $true
        }).AddArgument($src).AddArgument($dst).AddArgument($sync)
        $script:edCopy = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Row = $row; Leaf = $leaf; Timer = (New-Object Windows.Forms.Timer -Property @{ Interval = 300 }) }
        $bSave.Enabled = $false
        $script:edCopy.Timer.Add_Tick({
            $c = $script:edCopy; if (-not $c) { return }
            $sy = $c.Sync
            $pct = if ($sy.Total) { [int](100 * $sy.Done / $sy.Total) } else { 100 }
            $lCopy.Text = "Copying $($c.Leaf) to the stick... $pct%  ($(Format-Size $sy.Done) of $(Format-Size $sy.Total)) - you can keep editing."
            if (-not $sy.Finished) { return }
            $c.Timer.Stop(); [void]$c.Ps.EndInvoke($c.Handle); $c.Ps.Dispose()
            if ($sy.Error) { $c.Row.Cells['File'].Value = ''; $lCopy.Text = "Copy failed: $($sy.Error)" }
            else { $c.Row.Cells['File'].Value = $c.Leaf; $lCopy.Text = "$($c.Leaf) copied to $($script:instDirShown)."; Write-Log "Installers: $($c.Leaf) copied to $script:instDir" }
            $script:edCopy = $null; $bSave.Enabled = $true
        })
        $script:edCopy.Timer.Start()
    })
    # Closing during a copy: stop it (the partial file is removed)
    $d.Add_FormClosing({ param($s, $e)
        $c = $script:edCopy; if (-not $c) { return }
        if ([Windows.Forms.MessageBox]::Show("Still copying $($c.Leaf). Stop the copy and close?", $MigToolName, 'YesNo', 'Question') -ne 'Yes') { $e.Cancel = $true; return }
        $c.Sync.Cancel = $true; $c.Timer.Stop()
        $t0 = Get-Date; while (-not $c.Sync.Finished -and ((Get-Date) - $t0).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
        $script:edCopy = $null
    })
    $bSave.Add_Click({
        [void]$g.EndEdit()
        $rows = @(foreach ($row in $g.Rows) { if (-not $row.IsNewRow -and "$($row.Cells['Name'].Value)".Trim()) {
            [pscustomobject]@{ Name = "$($row.Cells['Name'].Value)".Trim(); Url = "$($row.Cells['Url'].Value)".Trim(); File = "$($row.Cells['File'].Value)".Trim(); Args = "$($row.Cells['Args'].Value)".Trim(); Match = "$($row.Cells['Match'].Value)".Trim(); Notes = "$($row.Cells['Notes'].Value)".Trim() } } })
        if ($rows.Count) { $rows | Export-Csv -LiteralPath $script:instCsv -NoTypeInformation -Encoding UTF8 } else { 'Name,Url,File,Args,Match,Notes' | Set-Content -LiteralPath $script:instCsv -Encoding UTF8 }
        Write-Log "Installers list saved ($($rows.Count) program(s))."
        $d.DialogResult = 'OK'
    })
    $d.ShowDialog($script:inst.Form) -eq 'OK'
}

$btnStart.Add_Click({ Invoke-StartCopy $false })
$btnRetry.Add_Click({ $script:retryRun = $true; try { Invoke-StartCopy $false } finally { $script:retryRun = $false } })
$btnAdv.Add_Click({ if ($script:busy -or $script:locked) { return }; Show-Advanced })
$btnInst.Add_Click({ if ($script:locked) { return }; Show-Installers })
$btnWalk.Add_Click({
    if ($script:locked) { if (Test-ItPassword) { Close-Overlay; Set-Locked $false } else { [void][Windows.Forms.MessageBox]::Show('Wrong password.', $MigToolName) } }
    else { Invoke-StartCopy $true }
})

# Test = check the report PC is reachable and writable; also sends any queued (unsent) reports.
$btnTestReport.Add_Click({
    $to = $txtReport.Text.Trim()
    if (-not $to) { $lblReport.Text = 'Type the PC name (or \\server\share) first.'; return }
    $lblReport.ForeColor = [Drawing.Color]::DimGray; $lblReport.Text = "Checking $to ..."; [Windows.Forms.Application]::DoEvents()
    try {
        $user = $txtReportUser.Text
        if (-not (Connect-ReportPc $to -Prompt)) { throw "can't log in to $to (access denied or wrong password). Use your admin user (Admin user box in section 1)." }
        $dir = Get-ReportDir $to $user
        if ($user.Trim() -and -not (Test-Path -LiteralPath (Split-Path $dir))) { throw "no folder for user '$($user.Trim())' on $to - has that user signed in there?" }
        New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null
        $tf = Join-Path $dir ".write-test-$([guid]::NewGuid().ToString('n'))"; [IO.File]::WriteAllText($tf, 'x'); [IO.File]::Delete($tf)
        $rep = Send-Reports $to $user $null
        Save-Settings
        $pop = Send-Popup $to $user "$($MigToolName): test notification from $env:COMPUTERNAME. Reports will go to Desktop\Migration Reports."
        $lblReport.ForeColor = [Drawing.Color]::ForestGreen
        $lblReport.Text = "OK: $dir$(if ($rep.Sent) { " ($($rep.Sent) queued sent)" }). Popup: $(if ($pop) { 'sent' } else { 'blocked on that PC (files still arrive)' })"
    } catch { $lblReport.ForeColor = [Drawing.Color]::Firebrick; $lblReport.Text = "Can't write to $to : $($_.Exception.Message)" }
})

$btnCancel.Add_Click({
    if ($script:busy) { $script:cancel = $true; $lblStatus.Text = 'Cancelling...'; Write-Log 'Cancel clicked.'; return }
    if ([Windows.Forms.MessageBox]::Show('Reset: end the cable link / Allow access, put the network back to normal and start again from step 1?', 'Reset', 'YesNo', 'Question') -eq 'Yes') { Reset-Window }
})
$btnLogs.Add_Click({ New-Item -ItemType Directory -Force $logRoot | Out-Null; Start-Process explorer.exe $logRoot })

$btnHere.Add_Click({
    if ($script:busy -or $script:cableOn -or $script:hostOn -or $script:locked) {
        [void][Windows.Forms.MessageBox]::Show('Finish first: no copy running, cable link ended, access not allowed, not locked.', $MigToolName); return
    }
    if (-not $script:runningLocal) {
        # Copy the tool (NOT the stick's logs - they hold other users' file lists) to C:, reopen from there, close this window.
        try {
            Save-Settings
            New-Item -ItemType Directory -Force "$($script:installDir)\scripts" | Out-Null
            foreach ($f in "$MigToolName.cmd", 'HOW-TO.txt') { $p = Join-Path $script:toolDir $f; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p $script:installDir -Force } }
            $oldCmd = Join-Path $script:installDir 'Migrate User Files.cmd'; if (Test-Path -LiteralPath $oldCmd) { [IO.File]::Delete($oldCmd) }   # launcher before the MoveMate name
            Get-ChildItem -LiteralPath $PSScriptRoot -File | Copy-Item -Destination "$($script:installDir)\scripts" -Force
            # extras: dashboard + the Installers list (installer files stay on the stick - they can be big)
            $ex = Join-Path $script:toolDir 'extras'; if (Test-Path -LiteralPath $ex) { New-Item -ItemType Directory -Force "$($script:installDir)\extras" | Out-Null; Get-ChildItem -LiteralPath $ex -File | Copy-Item -Destination "$($script:installDir)\extras" -Force }
            $bad = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { (Get-FileHash $_.FullName).Hash -ne (Get-FileHash (Join-Path "$($script:installDir)\scripts" $_.Name)).Hash })
            if ($bad.Count) { throw "copy check failed: $($bad.Name -join ', ')" }
        } catch { [void][Windows.Forms.MessageBox]::Show("Couldn't copy the tool to this PC: $($_.Exception.Message)", $MigToolName); return }
        $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script:installDir)\scripts\Migrate-UserFiles.ps1`" -Method $(if ($rbCable.Checked) { 'Cable' } elseif ($rbDrive.Checked) { 'Drive' } elseif ($rbServer.Checked) { 'Server' } else { 'Network' }) -Role $(if ($rbOld.Checked) { 'Old' } else { 'New' })"
        if ($PrimaryUser) { $a += " -PrimaryUser `"$PrimaryUser`"" }
        Write-Log "Tool copied to $($script:installDir). Reopening from there - you can EJECT the stick and take it to the other PC."
        Start-Process powershell.exe -ArgumentList $a   # inherits admin rights from this window
        $form.Close()
        return
    }
    # Remove the tool from this PC. Users still waiting for their first sign-in keep the small mover until they're done.
    $pending = @(Get-MigrationHandoff $env:SystemDrive | ForEach-Object User)
    $msg = "Remove $MigToolName from this PC ($($script:installDir))?`r`n`r`nUsers' files in C:\Migration and their profiles are NOT touched."
    if ($pending.Count) { $msg += "`r`n`r`nStill waiting for first sign-in: $($pending -join ', '). Their small mover stays until the last of them signs in, then removes itself." }
    if ([Windows.Forms.MessageBox]::Show($msg, 'Remove tool', 'YesNo', 'Question') -ne 'Yes') { return }
    [void](Start-ToolRemoval)
    $form.Close()
})
# Remove C:\...\Migrate after this window closes (Remove-MigrateTool waits for this process). Only for this PC's own copy.
function Start-ToolRemoval {
    if (-not $script:runningLocal) { return }   # never from a stick or a network share
    $rm = Join-Path $env:TEMP "Remove-MigrateTool-$PID.ps1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Remove-MigrateTool.ps1') $rm -Force
    $p = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$rm`" -WaitPid $PID" -PassThru
    $script:skipSave = $true
    if ($p) { $p.Id }
}
# Sign this Windows session out once MoveMate (it puts the network back as it closes) and the tool removal are done.
# A small separate process does it, so it outlives this window.
function Invoke-SignOut([int[]]$WaitPids) {
    $w = (@($WaitPids | Where-Object { $_ }) | ForEach-Object { "Wait-Process -Id $_ -Timeout 180 -ErrorAction SilentlyContinue;" }) -join ' '
    $ps = "$w shutdown.exe /l /f"
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps)))"
}
# Walk away finished: count down (30 s close / 60 s sign out), then close - and remove this PC's copy, sign out, if chosen.
# Close only: the done message stays up afterwards in a plain message box. Sign out: a warning window counts down
# ("Sign out now"; "Cancel sign-out" only when nobody is locked out, i.e. no lockdown screen). IT unlock stops it all.
function Start-WalkAutoClose([string]$Message, [string]$RunDir, [switch]$SignOut, [bool]$AllowRemove) {
    $script:ac = @{ Left = $(if ($SignOut) { 60 } else { 30 }); Msg = $Message; RunDir = $RunDir; SignOut = [bool]$SignOut; Win = $null
        Remove = ($AllowRemove -and $script:walkAuto.Remove -and $script:runningLocal) }
    if ($SignOut) {
        $w = New-Object Windows.Forms.Form -Property @{ Icon = $script:migIcon; Text = $MigToolName; ClientSize = (S 470 170); StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; ControlBox = $false; TopMost = $true; Font = $form.Font }
        $wl = New-Object Windows.Forms.Label -Property @{ Location = (P 16 14); Size = (S 438 100); Font = New-Object Drawing.Font('Segoe UI', 11); Text = 'Transfer finished. Signing out of Windows in 60 s - save your work.' }
        $now = New-Object Windows.Forms.Button -Property @{ Text = 'Sign out now'; Location = (P 214 126); Size = (S 110 30) }
        $stop = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel sign-out'; Location = (P 334 126); Size = (S 120 30); Visible = (-not $script:overlay) }
        $now.Add_Click({ $script:ac.Left = 1 })
        $stop.Add_Click({ $script:ac.Timer.Stop(); $script:ac.Win.Close(); Write-Log 'Walk away: sign-out cancelled at this PC.'; $lblStatus.Text = 'Finished - sign-out cancelled.' })
        $w.Controls.AddRange(@($wl, $now, $stop)); $w.Tag = @{ Label = $wl; Stop = $stop }
        $script:ac.Win = $w; $w.Show()
    }
    $script:ac.Timer = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
    $script:ac.Timer.Add_Tick({
        $ac = $script:ac
        if (-not $script:locked) { $ac.Timer.Stop(); if ($ac.Win) { $ac.Win.Close() }; Write-Log 'Walk away: auto-close / sign-out stopped (unlocked by IT).'; return }
        $ac.Left--
        $t = if ($ac.SignOut) { "Transfer finished. Signing out of Windows in $($ac.Left) s - save your work.$(if ($ac.Remove) { " $MigToolName removes itself from this PC first." })" }
             else { "$MigToolName closes in $($ac.Left) s$(if ($ac.Remove) { ' and removes itself from this PC' })." }
        if ($script:ovStatus) { $script:ovStatus.Text = $t }; $lblStatus.Text = $t
        if ($script:overlay) { $script:overlay.Tag.Help.Text = $t; $script:overlay.Tag.Help.Visible = $true }   # big, on the lockdown screen
        if ($ac.Win -and -not $ac.Win.IsDisposed) { $ac.Win.Tag.Label.Text = $t; $ac.Win.Tag.Stop.Visible = -not $script:overlay; $ac.Win.BringToFront() }
        if ($ac.Left -gt 0) { return }
        $ac.Timer.Stop()
        if ($ac.Remove -and -not $script:reportSent) {
            # The logs live in the tool folder that is about to go: keep this run's (not sent to IT) on the PC
            $keep = Join-Path $env:ProgramData "$MigToolName\logs"
            try { New-Item -ItemType Directory -Force $keep | Out-Null; Copy-Item -LiteralPath $ac.RunDir $keep -Recurse -Force; Copy-Item -LiteralPath (Join-Path $logRoot 'MigrationStats.csv') $keep -Force -ErrorAction SilentlyContinue
                Write-Log "Report not sent to IT - this run's logs kept in $keep." } catch { Write-Log "! Could not keep the logs: $($_.Exception.Message) - NOT removing $MigToolName."; $ac.Remove = $false }
        }
        Write-Log "Walk away: closing$(if ($ac.Remove) { " and removing $MigToolName from this PC" })$(if ($ac.SignOut) { ', then signing out of Windows' })."
        if (-not $ac.SignOut) {
            # The done message outlives the window (its own small process; nothing from the tool folder needed)
            $ps = "Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show('$($ac.Msg.Replace("'", "''"))', '$MigToolName', 'OK', 'Information', 'Button1', 'DefaultDesktopOnly')"
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps)))"
        }
        $rmPid = $null; if ($ac.Remove) { $rmPid = Start-ToolRemoval }
        if ($ac.SignOut) { Invoke-SignOut @($PID, $rmPid) }
        if ($ac.Win -and -not $ac.Win.IsDisposed) { $ac.Win.Close() }
        $form.Close()
    })
    $script:ac.Timer.Start()
    Write-Log "Walk away: finished - $(if ($SignOut) { 'signing out of Windows in 60 s' } else { 'closing in 30 s' })$(if ($script:ac.Remove) { ', removing this PC''s copy' })."
}$form.Add_FormClosing({
    param($s, $e)
    if ($e.CloseReason -eq 'WindowsShutDown' -and $script:busy) { $e.Cancel = $true; return }   # shutdown block shows the walk-away message
    if ($script:locked -and $script:jobDone) { Close-Overlay; return }   # job finished: anyone may close it
    if ($script:locked) { if (Test-ItPassword) { Close-Overlay; Set-Locked $false } else { $e.Cancel = $true; return } }
    if ($script:busy) { $script:cancel = $true; $e.Cancel = $true; $lblStatus.Text = 'Cancelling - close again when it stops.' }
})
$form.Add_FormClosed({
    if (-not $script:skipSave) { Save-Settings }   # not when the tool is being removed
    foreach ($m in $script:mapped) { Remove-SmbMapping -RemotePath $m -Force -ErrorAction SilentlyContinue }
    if ($script:cableOn -or (Test-Path $CableState) -or (Test-Path $PairState)) { Stop-CableLink }
})

# Startup state from parameters
$script:pkgKeys = $null; $script:keyPath = $null; $script:pkgName = $null
switch ($Method) { 'Cable' { $rbCable.Checked = $true } 'Drive' { $rbDrive.Checked = $true } 'Server' { $rbServer.Checked = $true } default { $rbNet.Checked = $true } }
if ($Role -eq 'New' -or $PrimaryUser) { $rbNew.Checked = $true } else { $rbOld.Checked = $true }
if ($PrimaryUser) { $form.Text += "  -  primary user: $PrimaryUser" }
if ($SourceRoot -and $DestRoot) { $txtPc.Text = 'TEST' }
$lm = Stop-LegacyTransferShare; if ($lm) { Write-Log $lm }   # from the retired Open Transfer Share window
# A cable link left set up by an earlier window (closed by force / crashed): continue it, or undo it.
if ((Test-Path $CableState) -or (Test-Path $PairState)) {
    $prevRole = $null
    try { $cs = Get-Content $CableState -Raw | ConvertFrom-Json; $prevRole = if ($cs.Role) { $cs.Role } elseif ($cs.TempIp -like '*.1') { 'Old' } else { 'New' } } catch {}
    $q = "A direct cable link from an earlier window is still set up on this PC$(if ($prevRole) { " (as the $($prevRole.ToUpper()) PC)" }).`r`n`r`nYes = continue it (a new pairing code is shown)`r`nNo = undo it and put the network back to normal"
    if ($prevRole -and [Windows.Forms.MessageBox]::Show($q, 'Direct cable', 'YesNo', 'Question') -eq 'Yes') {
        $rbCable.Checked = $true; if ($prevRole -eq 'Old') { $rbOld.Checked = $true } else { $rbNew.Checked = $true }
        $StartCable = $true   # Start cable link redoes each step safely
    } else { Stop-CableLink }
}
Read-Settings
if ($rbServer.Checked -and -not $txtDrive.Text) { $txtDrive.Text = $script:serverPath }
# Opened from a "Restore <OLD PC>" key: download that package (unlocked with a Key-protection key)
if ($KeyFile) {
    try {
        $k = Read-RestoreKey $KeyFile
        $rbServer.Checked = $true; $rbNew.Checked = $true
        $txtDrive.Text = $k.Info.Package; $script:keyPath = $KeyFile; $script:pkgKeys = $k.Keys
        $form.Text += "  -  restore $($k.Info.OldPC)"
        Write-Log "Restore key for $($k.Info.OldPC) ($($k.Info.Users -join ', ')), uploaded $($k.Info.Created -replace 'T', ' '): $($k.Info.Package)"
        $form.Add_Shown({
            if (-not (Test-Path -LiteralPath $txtDrive.Text)) {
                Write-Log "Can't open $($txtDrive.Text) with the current login - Connect... (admin user)."
                $btnSrvConnect.PerformClick()
            }
            if (Test-Path -LiteralPath $txtDrive.Text) { $btnScan.PerformClick() }
            else { Write-Log '! The package is not there (already downloaded and deleted? wrong server login?).' }
        })
    } catch { Write-Log "! Restore key not usable: $($_.Exception.Message)" }
}
if (Test-Path $unsentFile) { Write-Log "$(@(Get-Content $unsentFile).Count) report(s) waiting to be sent - they go out after the next transfer, or click Test in section 6." }
Update-ModeUi
if ($SourceRoot -and $DestRoot) { Set-Conn "TEST MODE: $SourceRoot -> $DestRoot" }
if ($StartCable) { $form.Add_Shown({ $script:cableResume = $true; $btnCable.PerformClick() }) }
if ($MigAdv.CheckUpdates -and -not ($SourceRoot -and $DestRoot)) { $form.Add_Shown({ Start-UpdateCheck }) }
[void]$form.ShowDialog()
