# Engine for MoveMate (Migrate-UserFiles.ps1, dot-sourced). Robocopy only - nothing installed, no staging space needed.
# Roots are 'C:' (this PC) or '\\PC\C$' / '\\PC\KitMigrate$' (the other PC). Profiles live in <Root>\Users\<name>.
# Oversized files (> MaxBytes) are not sent over the network: they are moved/copied to <SourceRoot>\Migration-Oversized\<user>
# on the OLD PC (same relative paths, plus a manifest) so they can be carried over on an external drive.

# Where the tool installs on a PC (relative to the drive root) and its scheduled task names - change here only.
# Legacy: older versions used the names below; they're still recognized so pending handoffs keep working.
$MigToolName = 'MoveMate'   # shown in instructions/messages (the launcher is "<name>.cmd")
$MigToolVersion = '1.0.1'   # this copy's version - bump it with each GitHub release (tag v1.0.0); the update check compares to it
$MigUpdateRepo = 'xraygun/MoveMate'   # GitHub owner/repo the update check asks for its latest release
$MigToolRel = 'Program Files\MoveMate'
$MigLegacyToolRel = 'Program Files\MoveMate'
$HandoffTask = 'MigrateUserFiles-Handoff'
$CableCleanupTask = 'MigrateUserFiles-CableCleanup'
$MigLegacyTasks = @('MigrateUserFiles-Handoff', 'MigrateUserFiles-CableCleanup')

$MigSkip = 'Default', 'Default User', 'Public', 'All Users', 'defaultuser0', 'WDAGUtilityAccount'
$MigFolders = [ordered]@{
    'Desktop' = 'Desktop'; 'Documents' = 'Documents'; 'Downloads' = 'Downloads'; 'Pictures' = 'Pictures'
    'Videos' = 'Videos'; 'Music' = 'Music'; 'Favorites' = 'Favorites'
}
$MigBookmarks = [ordered]@{
    'Chrome'  = 'AppData\Local\Google\Chrome\User Data\Default\Bookmarks'
    'Edge'    = 'AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks'
    'Firefox' = 'AppData\Roaming\Mozilla\Firefox\Profiles'   # folder: each profile's newest bookmarkbackups\*.jsonlz4
}
$MigJunk = 'desktop.ini', 'Thumbs.db', '~$*', '*.tmp'

# ---------- Advanced options ("Advanced..." in the window). Saved in migrate-settings.json -> "Advanced" and read HERE,
# so background jobs (which load this file on their own) use the same options. Import-MigAdvanced re-reads them.
$MigAdvDefaults = [ordered]@{ Threads = 8; Retries = 1; WaitSec = 1; LimitMBps = 0; Compress = $false; ExcludeFiles = ''; ExcludeFolders = ''
    SkipOlderYears = 0; Verify = $false; ExtraFolders = @(); Installers = $false; CheckUpdates = $true }
function Import-MigAdvanced {
    $a = [ordered]@{}; foreach ($k in $MigAdvDefaults.Keys) { $a[$k] = $MigAdvDefaults[$k] }
    try {
        $s = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'migrate-settings.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($s.Advanced) { foreach ($k in $MigAdvDefaults.Keys) { if ($null -ne $s.Advanced.$k) { $a[$k] = $s.Advanced.$k } } }
    } catch {}
    $a.ExtraFolders = @($a.ExtraFolders | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim().TrimEnd('\') })
    $script:MigAdv = $a
}
Import-MigAdvanced
# robocopy /COMPRESS (SMB compression) exists on Windows 11 / Server 2022 and later
function Test-RoboCompress { if ($null -eq $script:MigHasCompress) { $script:MigHasCompress = [bool](& robocopy.exe /? 2>$null | Select-String -SimpleMatch '/COMPRESS') }; $script:MigHasCompress }
# What to leave out (listing AND copying, so sizes/progress match): junk + Advanced exclusions + "older than N years"
function Get-MigFilterOpts {
    $xf = @($MigJunk) + @("$($MigAdv.ExcludeFiles)" -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $xd = @("$($MigAdv.ExcludeFolders)" -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $o = @('/XF') + $xf
    if ($xd.Count) { $o += @('/XD') + $xd }
    if ([int]$MigAdv.SkipOlderYears -gt 0) { $o += "/MAXAGE:$([int]$MigAdv.SkipOlderYears * 365)" }
    $o
}
# Speed/retry options for the copy. A speed limit uses /IPG (pause between 64 KB blocks), which robocopy can't combine
# with /MT - so a limited copy is one paced stream.
function Get-MigRoboOpts {
    $o = @("/R:$([int]$MigAdv.Retries)", "/W:$([int]$MigAdv.WaitSec)")
    if ([double]$MigAdv.LimitMBps -gt 0) { $o += "/IPG:$([math]::Max(1, [int](65536 / ([double]$MigAdv.LimitMBps * 1048.576))))" }
    else { $o += "/MT:$([math]::Min(128, [math]::Max(1, [int]$MigAdv.Threads)))" }
    if ($MigAdv.Compress -and (Test-RoboCompress)) { $o += '/COMPRESS' }
    $o + (Get-MigFilterOpts)
}

# Firefox bookmark backups are "mozLz40\0" + uint32 size + one LZ4 block
if (-not ('KitMig.MozLz4' -as [type])) {
    Add-Type -TypeDefinition @'
namespace KitMig {
    public static class MozLz4 {
        public static byte[] Decode(byte[] src) {
            string magic = System.Text.Encoding.ASCII.GetString(src, 0, 8);
            if (magic != "mozLz40\0") throw new System.IO.InvalidDataException("not a Firefox jsonlz4 file");
            int size = System.BitConverter.ToInt32(src, 8);
            byte[] dst = new byte[size];
            int ip = 12, op = 0, end = src.Length;
            while (ip < end) {
                int token = src[ip++];
                int lit = token >> 4;
                if (lit == 15) { int b; do { b = src[ip++]; lit += b; } while (b == 255); }
                System.Array.Copy(src, ip, dst, op, lit); ip += lit; op += lit;
                if (ip >= end) break;
                int off = src[ip] | (src[ip + 1] << 8); ip += 2;
                int ml = token & 15;
                if (ml == 15) { int b; do { b = src[ip++]; ml += b; } while (b == 255); }
                ml += 4;
                for (int i = 0; i < ml; i++) { dst[op] = dst[op - off]; op++; }
            }
            return dst;
        }
    }
}
'@
}

if (-not ('KitMig.Disk' -as [type])) {
    Add-Type -Namespace KitMig -Name Disk -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool GetDiskFreeSpaceEx(string dir, out ulong free, out ulong total, out ulong totalFree);'
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-FreeBytes([string]$Root) {
    $f = [uint64]0; $t = [uint64]0; $tf = [uint64]0
    while ($Root -and -not (Test-Path -LiteralPath $Root)) { $Root = Split-Path $Root }   # folder not created yet: ask its parent
    if ($Root -and [KitMig.Disk]::GetDiskFreeSpaceEx($Root.TrimEnd('\') + '\', [ref]$f, [ref]$t, [ref]$tf)) { return [long]$f }
    return [long]-1
}

# Real user profiles (folder with NTUSER.DAT), or profiles exported to a drive (_Migration-Report.txt), newest first.
function Get-MigrationProfiles([string]$UsersRoot) {
    Get-ChildItem -LiteralPath $UsersRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $MigSkip -notcontains $_.Name -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
            $nt = Get-Item -LiteralPath (Join-Path $_.FullName 'NTUSER.DAT') -Force -ErrorAction SilentlyContinue
            if (-not $nt) { $nt = Get-Item -LiteralPath (Join-Path $_.FullName '_Migration-Report.txt') -Force -ErrorAction SilentlyContinue }
            if ($nt) { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; LastUsed = $nt.LastWriteTime } }
        } | Sort-Object LastUsed -Descending
}

# Destination profile folder for a source profile: same name, or same base name ('jsmith' ~ 'jsmith.DOMAIN'). $null = not there yet.
function Resolve-DestProfile([string]$DestUsersRoot, [string]$SourceName) {
    if (Test-Path -LiteralPath (Join-Path $DestUsersRoot $SourceName)) { return $SourceName }
    $base = ($SourceName -split '\.')[0]
    $m = Get-ChildItem -LiteralPath $DestUsersRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $base -or $_.Name -like "$base.*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($m) { return $m.Name }
    return $null
}

# robocopy /L (list only) over a folder; junctions skipped. Read from a UTF-16 log, NOT the console: PowerShell reads
# console output in the OEM code page, which garbles accented names (e.g. Résumé) so the files can't be found later.
function Invoke-RoboList([string]$Src, [string[]]$Opts) {
    $nul = Join-Path $env:TEMP 'kitmig-list-only'
    $log = Join-Path $env:TEMP ("kitmig-list-{0}.log" -f [guid]::NewGuid().ToString('n'))
    & robocopy.exe $Src $nul /L /E /XJ /R:0 /W:0 /NP /BYTES /NC /NDL /FP /NJH @Opts "/UNILOG:$log" 2>$null | Out-Null
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Encoding Unicode; Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
}

function Get-FolderStats([string]$Src, [long]$MaxBytes) {
    $s = [pscustomobject]@{ Files = 0; Bytes = [long]0 }
    foreach ($l in (Invoke-RoboList $Src (@('/NFL', "/MAX:$MaxBytes") + (Get-MigFilterOpts)))) {
        # Summary columns: Total, Copied, Skipped... - "Copied" is what would actually be transferred.
        if ($l -match '^\s*Files\s*:\s*\d+\s+(\d+)') { $s.Files = [int]$Matches[1] }
        elseif ($l -match '^\s*Bytes\s*:\s*\d+\s+(\d+)') { $s.Bytes = [long]$Matches[1] }
    }
    $s
}

function Get-LargeFiles([string]$Src, [long]$MaxBytes) {
    foreach ($l in (Invoke-RoboList $Src (@('/NJS', "/MIN:$($MaxBytes + 1)") + (Get-MigFilterOpts)))) {
        if ($l -match '^\s*(\d+)\s+(\S.*?)\s*$') { [pscustomobject]@{ Path = $Matches[2]; Bytes = [long]$Matches[1] } }
    }
}

# Runs robocopy without blocking the GUI: $Wait is called while it runs and returns $true to cancel. Returns the exit code (-1 = cancelled).
function Invoke-Robo([string]$Src, [string]$Dst, [string[]]$Opts, [string]$LogFile, [scriptblock]$Wait) {
    $al = (@($Src, $Dst) + $Opts + "/UNILOG:$LogFile") | ForEach-Object { '"' + $_ + '"' }
    $p = Start-Process robocopy.exe -ArgumentList ($al -join ' ') -WindowStyle Hidden -PassThru
    $null = $p.Handle   # keeps ExitCode readable
    while (-not $p.HasExited) {
        if ($Wait) { if (& $Wait) { try { $p.Kill() } catch {}; return -1 } } else { Start-Sleep -Milliseconds 300 }
    }
    $p.WaitForExit()
    return $p.ExitCode
}

# Chrome/Edge 'Bookmarks' (JSON) -> bookmarks.html that Chrome/Edge can import (Settings > Import bookmarks > HTML file).
function ConvertTo-BookmarkHtml([string]$JsonPath, [string]$HtmlPath) {
    $j = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    [void]$sb.AppendLine('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    [void]$sb.AppendLine('<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1><DL><p>')
    foreach ($r in 'bookmark_bar', 'other', 'synced') { if ($j.roots.$r) { Add-BookmarkNode $sb $j.roots.$r } }
    [void]$sb.AppendLine('</DL><p>')
    [IO.File]::WriteAllText($HtmlPath, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}
function Add-BookmarkNode($sb, $n) {
    $name = [Net.WebUtility]::HtmlEncode("$($n.name)")
    if ($n.type -eq 'folder') {
        [void]$sb.AppendLine("<DT><H3>$name</H3><DL><p>")
        foreach ($c in @($n.children)) { if ($c) { Add-BookmarkNode $sb $c } }
        [void]$sb.AppendLine('</DL><p>')
    } elseif ($n.url) {
        [void]$sb.AppendLine("<DT><A HREF=`"$([Net.WebUtility]::HtmlEncode($n.url))`">$name</A>")
    }
}

# Firefox backup JSON (typeCode 1 = bookmark, 2 = folder) -> the same HTML format. Returns the number of bookmarks.
function ConvertTo-FirefoxBookmarkHtml([string]$Json, [string]$HtmlPath) {
    $j = $Json | ConvertFrom-Json
    $roots = @{ 'menu________' = 'Bookmarks Menu'; 'toolbar_____' = 'Bookmarks Toolbar'; 'unfiled_____' = 'Other Bookmarks'; 'mobile______' = 'Mobile Bookmarks' }
    $sb = New-Object Text.StringBuilder; $count = [ref]0
    [void]$sb.AppendLine('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    [void]$sb.AppendLine('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    [void]$sb.AppendLine('<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1><DL><p>')
    $add = $null
    $add = {
        param($n)
        if ($n.typeCode -eq 2) {
            $t = if ($roots.ContainsKey("$($n.guid)")) { $roots["$($n.guid)"] } else { "$($n.title)" }
            [void]$sb.AppendLine("<DT><H3>$([Net.WebUtility]::HtmlEncode($t))</H3><DL><p>")
            foreach ($c in @($n.children)) { if ($c) { & $add $c } }
            [void]$sb.AppendLine('</DL><p>')
        } elseif ($n.typeCode -eq 1 -and $n.uri -and "$($n.uri)" -notlike 'place:*') {
            $count.Value++
            [void]$sb.AppendLine("<DT><A HREF=`"$([Net.WebUtility]::HtmlEncode($n.uri))`">$([Net.WebUtility]::HtmlEncode("$($n.title)"))</A>")
        }
    }
    foreach ($c in @($j.children)) { if ($c) { & $add $c } }   # the four roots
    [void]$sb.AppendLine('</DL><p>')
    [IO.File]::WriteAllText($HtmlPath, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
    $count.Value
}

# Bookmark files for one browser in a profile folder: @{ Path; Name; Note }. Chrome/Edge: the Bookmarks file.
# Firefox: per Firefox profile, its newest automatic backup (bookmarkbackups\*.jsonlz4, written about daily).
function Get-BookmarkFiles([string]$ProfilePath, [string]$Key) {
    $p = Join-Path $ProfilePath $MigBookmarks[$Key]
    if ($Key -ne 'Firefox') { if (Test-Path -LiteralPath $p -PathType Leaf) { @{ Path = $p; Name = $Key; Note = '' } }; return }
    $ff = @(Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $b = Get-ChildItem -LiteralPath (Join-Path $_.FullName 'bookmarkbackups') -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.jsonlz4' -or $_.Name -like '*.json' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($b) { @{ Path = $b.FullName; Profile = ($_.Name -replace '^[^.]+\.', ''); Date = $b.LastWriteTime } }
    })
    foreach ($b in $ff) {
        @{ Path = $b.Path; Name = $(if ($ff.Count -gt 1) { "Firefox-$($b.Profile)" } else { 'Firefox' }); Note = "Firefox backup from $($b.Date.ToString('yyyy-MM-dd'))" }
    }
}

# Writes <Name>-bookmarks.html (import in any browser) + the original file (Chrome/Edge .json; Firefox backup, which
# Firefox can restore: Bookmarks > Manage bookmarks > Import and Backup > Restore > Choose File). Returns @{ Html; Raw; Count }.
function Export-Bookmarks([string]$Key, [string]$SrcFile, [string]$DestDir, [string]$Name) {
    New-Item -ItemType Directory -Force $DestDir | Out-Null
    $html = Join-Path $DestDir "$Name-bookmarks.html"
    if ($Key -eq 'Firefox') {
        $ext = if ($SrcFile -like '*.jsonlz4') { '.jsonlz4' } else { '.json' }
        $raw = Join-Path $DestDir "$Name-bookmarks-backup$ext"
        Copy-Item -LiteralPath $SrcFile $raw -Force -ErrorAction Stop
        $bytes = [IO.File]::ReadAllBytes($SrcFile)
        $json = if ($ext -eq '.jsonlz4') { [Text.Encoding]::UTF8.GetString([KitMig.MozLz4]::Decode($bytes)) } else { [Text.Encoding]::UTF8.GetString($bytes) }
        $count = ConvertTo-FirefoxBookmarkHtml $json $html
    } else {
        $raw = Join-Path $DestDir "$Name-Bookmarks.json"
        Copy-Item -LiteralPath $SrcFile $raw -Force -ErrorAction Stop
        ConvertTo-BookmarkHtml $SrcFile $html
        $count = ([regex]::Matches((Get-Content -LiteralPath $SrcFile -Raw), '"type"\s*:\s*"url"')).Count
    }
    @{ Html = $html; Raw = $raw; Count = $count }
}

# Totals from the LAST robocopy job summary in a log (/BYTES, /UNILOG): Copied files, Copied bytes, Failed files.
# A copied-file line in a robocopy log: 1 class, 2 bytes, 3 date (only with /TS), 4 full source path
# With /MT, robocopy can glue its retry notes onto a path in the log ("...\a.docxWaiting 1 seconds... Retrying...")
function Get-CleanRoboPath([string]$Path) { ($Path -replace '(\s*(Waiting \d+ seconds\.\.\.|Retrying\.\.\.))+\s*$', '').Trim() }
$MigFileLine = '^\s*(New File|Newer|Older|Changed|Modified|Tweaked)\s+(\d+)\s+(?:(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s+)?(\S.*?)\s*$'

# ---------- Run statistics for MigrationStats.csv (dashboard data) ----------
# File types by extension (anything else = Other)
$MigTypeMap = [ordered]@{
    Docs     = 'doc docx docm pdf xls xlsx xlsm csv ppt pptx pptm txt rtf odt ods odp one pub md xps'
    Images   = 'jpg jpeg png gif bmp tif tiff heic heif webp svg ico raw cr2 nef dng psd'
    Video    = 'mp4 mov avi mkv wmv m4v mpg mpeg webm 3gp flv'
    Audio    = 'mp3 wav m4a wma aac flac ogg aif aiff'
    Archives = 'zip rar 7z iso tar gz tgz cab'
}
$MigStatFolders = 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Favorites', 'OneDrive'
# Every column the stats add (also used to upgrade an older CSV)
# Megabits columns are named *Mbit_s: PowerShell property names ignore case, so 'AvgMbps' would BE the existing 'AvgMBps'.
$MigStatColumns = @('AvgMbit_s', 'PeakMbit_s', 'LinkSpeed', 'LargestFileMB', 'LargestFileType', 'LargestFileUser', 'AvgFileKB') +
    @($MigTypeMap.Keys + 'Other' | ForEach-Object { "$($_)_GB"; "$($_)_Files" }) +
    @($MigStatFolders + 'OtherFolders' | ForEach-Object { "$($_)_GB" }) +
    @('OldestFileYear', 'PctOlderThan3Yrs', 'SkippedFiles', 'BookmarksCount', 'OldPCModel', 'OldPCWindows', 'NewPCModel', 'NewPCWindows', 'Layout')

# Reads a run's robocopy logs (<profile>.<folder>.log) and returns the file statistics as an ordered hashtable.
# Works on older runs too (no dates without /TS -> age columns blank). The largest file is reported by size, type and
# its user - never its name or path.
function Get-RunFileStats([string]$RunDir) {
    $ext2cat = @{}; foreach ($k in $MigTypeMap.Keys) { foreach ($e in ($MigTypeMap[$k] -split ' ')) { $ext2cat[".$e"] = $k } }
    $catB = @{}; $catN = @{}; foreach ($k in @($MigTypeMap.Keys) + 'Other') { $catB[$k] = [long]0; $catN[$k] = 0 }
    $fold = @{}; foreach ($k in $MigStatFolders + 'OtherFolders') { $fold[$k] = [long]0 }
    $files = 0; $bytes = [long]0; $big = [long]0; $bigType = ''; $bigUser = ''; $dated = 0; $old = 0; $oldest = $null; $skipped = 0
    $cut = (Get-Date).AddYears(-3)
    foreach ($log in @(Get-ChildItem -LiteralPath $RunDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
        if ($log.BaseName -notmatch '^([^.]+)\.(.+)$') { continue }
        $user = $Matches[1]; $f = $Matches[2]
        $fk = if ($f -like 'OneDrive*') { 'OneDrive' } elseif ($fold.ContainsKey($f)) { $f } else { 'OtherFolders' }
        $lastSkip = 0
        foreach ($l in @(Get-Content -LiteralPath $log.FullName -ErrorAction SilentlyContinue)) {   # BOM-detected: Unicode or older ANSI logs
            if ($l -match $MigFileLine) {
                $b = [long]$Matches[2]; $p = $Matches[4]; $d = $Matches[3]
                $ext = ''; try { $ext = [IO.Path]::GetExtension($p).ToLower() } catch {}
                $cat = if ($ext2cat.ContainsKey($ext)) { $ext2cat[$ext] } else { 'Other' }
                $catB[$cat] += $b; $catN[$cat]++; $fold[$fk] += $b; $files++; $bytes += $b
                if ($b -gt $big) { $big = $b; $bigType = $(if ($ext) { $ext } else { '(none)' }); $bigUser = $user }
                if ($d) {
                    try { $dt = [datetime]::ParseExact($d, 'yyyy/MM/dd HH:mm:ss', $null); $dated++; if ($dt -lt $cut) { $old++ }; if (-not $oldest -or $dt -lt $oldest) { $oldest = $dt } } catch {}
                }
            } elseif ($l -match '^\s*Files\s*:\s*\d+\s+\d+\s+(\d+)') { $lastSkip = [int]$Matches[1] }
        }
        $skipped += $lastSkip
    }
    $o = [ordered]@{
        LargestFileMB = [math]::Round($big / 1MB, 1); LargestFileType = $bigType; LargestFileUser = $bigUser
        AvgFileKB = $(if ($files) { [math]::Round($bytes / $files / 1KB, 1) } else { 0 })
    }
    foreach ($k in @($MigTypeMap.Keys) + 'Other') { $o["$($k)_GB"] = [math]::Round($catB[$k] / 1GB, 3); $o["$($k)_Files"] = $catN[$k] }
    foreach ($k in $MigStatFolders + 'OtherFolders') { $o["$($k)_GB"] = [math]::Round($fold[$k] / 1GB, 3) }
    $o.OldestFileYear = $(if ($oldest) { $oldest.Year } else { '' })
    $o.PctOlderThan3Yrs = $(if ($dated) { [math]::Round(100 * $old / $dated, 1) } else { '' })
    $o.SkippedFiles = $skipped
    $o
}

# Model and Windows version of this PC (no -Computer) or another one (DCOM, optional login). Blank on failure.
function Get-PcInfo([string]$Computer, [pscredential]$Credential) {
    $c = @{}
    if ($Computer) {
        $p = @{ ComputerName = $Computer; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        try { $c.CimSession = New-CimSession @p } catch { return [pscustomobject]@{ Model = ''; Windows = '' } }
    }
    try {
        $cs = Get-CimInstance @c Win32_ComputerSystem -ErrorAction Stop; $os = Get-CimInstance @c Win32_OperatingSystem -ErrorAction Stop
        [pscustomobject]@{ Model = "$($cs.Manufacturer) $($cs.Model)".Trim(); Windows = "$($os.Caption -replace '^Microsoft ', '') (build $($os.BuildNumber))" }
    } catch { [pscustomobject]@{ Model = ''; Windows = '' } }
    finally { if ($c.CimSession) { Remove-CimSession $c.CimSession } }
}

# Speed of this PC's network adapter that leads to $Target (name or IP), e.g. "1 Gbps". Blank if unknown.
function Get-LinkSpeedTo([string]$Target) {
    try {
        $ip = if ($Target -match '^\d+\.\d+\.\d+\.\d+$') { $Target } else { ([Net.Dns]::GetHostAddresses($Target) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1).IPAddressToString }
        $idx = (Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop | Where-Object InterfaceIndex | Select-Object -First 1).InterfaceIndex
        "$((Get-NetAdapter -InterfaceIndex $idx -ErrorAction Stop).LinkSpeed)"
    } catch { '' }
}

function Get-RoboSummary([string]$LogFile) {
    $s = [pscustomobject]@{ Files = 0; Bytes = [long]0; Failed = 0 }
    foreach ($l in @(Get-Content -LiteralPath $LogFile -Tail 40 -Encoding Unicode -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*Files\s*:\s*\d+\s+(\d+)\s+\d+\s+\d+\s+(\d+)') { $s.Files = [int]$Matches[1]; $s.Failed = [int]$Matches[2] }
        elseif ($l -match '^\s*Bytes\s*:\s*\d+\s+(\d+)') { $s.Bytes = [long]$Matches[1] }
    }
    $s
}

# Folder layout on the new PC: same folders as the old PC, or everything under one easy-to-delete Desktop folder
# (its name is a setting; this is the default). Also used when the user picks "desktop folder" at sign-in.
$MigBackupName = 'Migrated from old PC'
$MigAskMessage = "Your files have been copied from your old computer ({OldPC}).`r`n`r`nWould you like them placed in the same locations as on your old computer (Desktop, Documents, Pictures, ...), or all together in a folder on your desktop called '{Folder}' so you can sort them as you wish?"
$MigChoiceRel = 'ProgramData\KitMigrate\choices'   # users write their answer here (<user>.txt); SYSTEM reads it
$AskTask = 'MigrateUserFiles-Ask'

# One profile. $Folders are paths relative to the profile; $Bookmarks are keys of $MigBookmarks.
# Target 'Profile' = into <DstRoot>\Users\<DestName> (falls back to Migration if missing); 'Migration' = <DstRoot>\Migration\<DestName or profile>;
# 'Mirror' = <DstRoot>\Users\<profile>, created (export to an external drive, which Import then scans like a PC).
# Layout 'Same' = Desktop -> Desktop...; 'Backup' = Desktop -> Desktop\<BackupName>\Desktop... (ignored for 'Mirror').
# Unless exporting, writes "Migration Report - <PC> <date>.txt" on the destination Desktop: every copied file and where it went.
# -ReportNote: extra line for that report (e.g. "you'll be asked where to put them at sign-in").
function Invoke-ProfileMigration {
    param(
        [string]$SrcRoot, [string]$DstRoot, [string]$ProfileName, [string]$DestName,
        [string[]]$Folders, [string[]]$Bookmarks,
        [ValidateSet('Profile', 'Migration', 'Mirror')][string]$Target = 'Profile',
        [ValidateSet('Same', 'Backup', 'Other')][string]$Layout = 'Same',
        # Layout Other: files go to <OtherRoot>\<user> (path usable from here, e.g. \\NEWPC\D$\Data); OtherLabel = how the
        # user sees it (D:\Data). The receipt still goes on their desktop (staged in C:\Migration\<user> if no profile yet).
        [string]$OtherRoot, [string]$OtherLabel,
        # With Layout Other: a backup nobody receives yet - the report goes only in that folder (no desktop receipt, no staging)
        [switch]$BackupOnly,
        [switch]$ForSomeoneElse,   # DestName is another person (replacing the old user): the receipt says whose files they are
        [string]$BackupName = $MigBackupName, [string]$ReportNote = '',
        [long]$MaxBytes = 1GB,
        [ValidateSet('Move', 'Copy', 'List')][string]$Oversize = 'Move',
        [string]$LogDir, [string]$SourcePc = '', [string]$DestPc = '',
        [string]$OldRoot,   # what $SrcRoot was on the old PC (e.g. 'C:' for a server package), for the user's report
        [string[]]$Settings = @(),   # "Settings & lists": StickyNotes, Wallpaper, DrivesPrinters (Export-MigratedSettings)
        [scriptblock]$Log = { param($m) Write-Host $m },
        [scriptblock]$Wait
    )
    if ($MaxBytes -lt 1MB) { throw "Large-file limit is $MaxBytes bytes - refusing (it would set aside almost every file)." }
    if (-not "$ProfileName".Trim()) { throw 'No profile name - refusing (that would mean the whole Users folder).' }
    if ($Target -eq 'Mirror') { $Layout = 'Same' }
    if ($Layout -eq 'Other' -and -not "$OtherRoot".Trim()) { throw 'Other location: no folder chosen.' }
    $src = Join-Path (Join-Path $SrcRoot 'Users') $ProfileName
    $dstBase = $null
    $userName = if ($DestName) { $DestName } else { $ProfileName }
    if ($Layout -eq 'Other') { $dstBase = Join-Path $OtherRoot $userName }
    if (-not $dstBase -and $Target -eq 'Profile' -and $DestName) {
        $p = Join-Path (Join-Path $DstRoot 'Users') $DestName
        if (Test-Path -LiteralPath $p) { $dstBase = $p } else { & $Log "  ! Profile '$DestName' not found on the destination." }
    }
    if ($Target -eq 'Mirror') { $dstBase = Join-Path (Join-Path $DstRoot 'Users') $ProfileName }   # (Mirror forces Same above)
    if (-not $dstBase) { $dstBase = Join-Path (Join-Path $DstRoot 'Migration') $(if ($DestName) { $DestName } else { $ProfileName }) }
    $BackupName = ($BackupName -replace '[\\/:*?"<>|]', '').Trim(); if (-not $BackupName) { $BackupName = $MigBackupName }
    $prefix = if ($Layout -eq 'Backup') { "Desktop\$BackupName" } else { '' }
    & $Log "  Destination: $dstBase$(if ($prefix) { "\$prefix" })"
    $overRoot = Join-Path (Join-Path $SrcRoot 'Migration-Oversized') $ProfileName
    New-Item -ItemType Directory -Force $LogDir, $dstBase | Out-Null
    $res = [pscustomobject]@{ Profile = $ProfileName; Dest = $dstBase; Errors = 0; Oversized = @(); Cancelled = $false; Log = $LogDir
        Files = 0; Bytes = [long]0; FailedFiles = 0; Seconds = 0.0; PeakBps = 0.0   # what was actually transferred (reruns count only changes)
        Copied = New-Object Collections.Generic.List[object]; FolderMap = New-Object Collections.Generic.List[object]; Report = ''; BookmarksCount = 0
        ReceiptStaged = ''     # Other layout, no profile yet: C:\Migration\<this> holds only the receipt -> handoff puts it on the desktop
        Verified = 0; Settings = @() }

    foreach ($rel in $Folders) {
        $s = Join-Path $src $rel
        if (-not (Test-Path -LiteralPath $s)) { & $Log "  - $rel : not found, skipped"; continue }
        foreach ($b in @(Get-LargeFiles $s $MaxBytes)) {
            $to = Join-Path $overRoot $b.Path.Substring($src.Length).TrimStart('\')
            $action = 'left in place'
            if ($Oversize -ne 'List') {
                try {
                    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
                    if ($Oversize -eq 'Move') { Move-Item -LiteralPath $b.Path -Destination $to -Force -ErrorAction Stop; $action = 'moved' }
                    else { Copy-Item -LiteralPath $b.Path -Destination $to -Force -ErrorAction Stop; $action = 'copied' }
                } catch { $action = "FAILED (still in original place): $($_.Exception.Message)" }
            }
            & $Log "  ! Large file ($(Format-Size $b.Bytes)) $action : $($b.Path)"
            $res.Oversized += [pscustomobject]@{ Original = $b.Path; SizeMB = [math]::Round($b.Bytes / 1MB); Action = $action; NewPath = $(if ($action -eq 'moved' -or $action -eq 'copied') { $to } else { '' }) }
        }
        $destRel = if ($prefix) { Join-Path $prefix $rel } else { $rel }
        & $Log "  > $rel -> $destRel ..."
        # /TS: each file's date goes in the log too (for the "how old is the data" stats)
        $opts = @('/E', '/XJ', '/COPY:DAT', '/DCOPY:T', "/MAX:$MaxBytes", '/NP', '/NDL', '/FP', '/TS', '/BYTES') + (Get-MigRoboOpts)
        # One UTF-16 log per folder (robocopy /UNILOG+ appends in the OEM code page and garbles accented names)
        $logFile = Join-Path $LogDir ("{0}.{1}.log" -f $ProfileName, ($rel -replace '[\\/:*?"<>| ]', '_'))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $code = Invoke-Robo $s (Join-Path $dstBase $destRel) $opts $logFile $Wait
        $sw.Stop()
        $sum = Get-RoboSummary $logFile
        $res.Files += $sum.Files; $res.Bytes += $sum.Bytes; $res.FailedFiles += $sum.Failed; $res.Seconds += $sw.Elapsed.TotalSeconds
        # Peak = fastest folder with at least 20 MB moved (small folders are dominated by per-file overhead)
        if ($sum.Bytes -ge 20MB) { $bps = $sum.Bytes / [math]::Max($sw.Elapsed.TotalSeconds, 0.001); if ($bps -gt $res.PeakBps) { $res.PeakBps = $bps } }
        # Files robocopy copied in this run (lines: <class> <bytes> [<yyyy/mm/dd hh:mm:ss> with /TS] <full source path>)
        $thisFolder = New-Object Collections.Generic.List[object]
        $logLines = @(Get-Content -LiteralPath $logFile -Encoding Unicode -ErrorAction SilentlyContinue)
        # robocopy writes the "New File" line BEFORE trying: a file that then failed ("ERROR nn (0x..) Copying File <path>") wasn't copied
        $failedPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($l in $logLines) { if ($l -match 'ERROR \d+ \(0x[0-9A-Fa-f]+\) Copying File (.+?)\s*$') { [void]$failedPaths.Add((Get-CleanRoboPath $Matches[1])) } }
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($l in $logLines) {
            if ($l -notmatch $MigFileLine) { continue }
            $fp = Get-CleanRoboPath $Matches[4]; $fb = [long]$Matches[2]
            if ($fp.StartsWith($s, [StringComparison]::OrdinalIgnoreCase) -and -not $failedPaths.Contains($fp) -and $seen.Add($fp)) {   # (a retried file is logged again)
                $c = [pscustomobject]@{ To = Join-Path $destRel $fp.Substring($s.Length).TrimStart('\'); From = $fp; Bytes = $fb }
                $res.Copied.Add($c); $thisFolder.Add($c)
            }
        }
        # Advanced "Verify copies": SHA-256 of each file copied in this run, here and there (robocopy only checks sizes/dates)
        if ($MigAdv.Verify -and $code -ne -1 -and $thisFolder.Count) {
            & $Log "    verifying $($thisFolder.Count) file(s)..."
            $bad = 0
            foreach ($c in $thisFolder) {
                if ($Wait -and (& $Wait)) { break }
                try { $ok = (Get-FileHash -LiteralPath $c.From -Algorithm SHA256 -ErrorAction Stop).Hash -eq (Get-FileHash -LiteralPath (Join-Path $dstBase $c.To) -Algorithm SHA256 -ErrorAction Stop).Hash }
                catch { $ok = $false }
                if (-not $ok) { $bad++; & $Log "    ! verify FAILED: $($c.From)" }
            }
            $res.Verified += $thisFolder.Count - $bad
            if ($bad) { $res.FailedFiles += $bad; $res.Errors++; & $Log "    $bad file(s) differ - run it again (Retry failed) to copy them again." } else { & $Log '    verified: identical.' }
        }
        $res.FolderMap.Add([pscustomobject]@{ From = $rel; To = $destRel; Files = $sum.Files; Bytes = $sum.Bytes; Failed = $sum.Failed })
        if ($code -eq -1) { & $Log '  CANCELLED.'; $res.Cancelled = $true; break }
        if ($code -ge 8) { $res.Errors++; & $Log "    some files failed (robocopy code $code) - see $logFile" } else { & $Log "    ok - $($sum.Files) files, $(Format-Size $sum.Bytes) in $([math]::Round($sw.Elapsed.TotalSeconds))s" }
    }

    if (-not $res.Cancelled) {
        $bmRel = if ($prefix) { Join-Path $prefix 'Browser Bookmarks' } else { 'Documents\Migrated Bookmarks' }
        foreach ($k in $Bookmarks) {
            $found = @(Get-BookmarkFiles $src $k)
            if (-not $found.Count) { & $Log "  - $k bookmarks: none found"; continue }
            foreach ($bk in $found) {
                try {
                    $x = Export-Bookmarks $k $bk.Path (Join-Path $dstBase $bmRel) $bk.Name
                    $leaf = Split-Path $x.Html -Leaf
                    $res.BookmarksCount += $x.Count
                    $how = if ($k -eq 'Firefox') { 'import the HTML in any browser, or in Firefox: Manage bookmarks > Import and Backup > Restore > Choose File > the -backup file' } else { 'import it in the browser: Import bookmarks > HTML file' }
                    $res.Copied.Add([pscustomobject]@{ To = Join-Path $bmRel $leaf; From = "$($bk.Name) bookmarks, $($x.Count) ($how)"; Bytes = (Get-Item -LiteralPath $x.Html).Length })
                    & $Log "  > $($bk.Name) bookmarks ($($x.Count)) -> $bmRel\$leaf$(if ($bk.Note) { "  [$($bk.Note)]" })"
                } catch { $res.Errors++; & $Log "  ! $($bk.Name) bookmarks failed: $($_.Exception.Message)" }
            }
        }
    }

    if (-not $res.Cancelled -and $Settings.Count) {
        $msRel = if ($prefix) { Join-Path $prefix 'Documents\Migrated Settings' } else { 'Documents\Migrated Settings' }
        try {
            $made = @(Export-MigratedSettings $src (Join-Path $dstBase $msRel) $Settings $SourcePc)
            foreach ($m in $made) { $res.Copied.Add([pscustomobject]@{ To = Join-Path $msRel $m.Substring((Join-Path $dstBase $msRel).Length).TrimStart('\'); From = "settings: $(Split-Path $m -Leaf)"; Bytes = (Get-Item -LiteralPath $m).Length }) }
            if ($made.Count) { & $Log "  > settings & lists -> $msRel ($(@($made | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))" }
        } catch { & $Log "  ! settings & lists: $($_.Exception.Message)" }
    }
    # Sticky Notes: put the notes where the app reads them - only same-folders layout, and only if there are no notes there yet
    if (-not $res.Cancelled -and $Layout -eq 'Same' -and $Target -ne 'Mirror') {
        $msDir = Join-Path $dstBase 'Documents\Migrated Settings\Sticky Notes'
        $ls = Join-Path $dstBase 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'
        $placed = Join-Path $ls 'plum.sqlite'; $copy = Join-Path $msDir 'plum.sqlite'
        if ((Test-Path -LiteralPath $copy) -and (Test-Path -LiteralPath $placed) -and (Get-FileHash -LiteralPath $copy).Hash -eq (Get-FileHash -LiteralPath $placed).Hash) { $res.Settings += 'StickyNotesPlaced' }   # (a rerun)
        elseif ((Test-Path -LiteralPath $copy) -and -not (Test-Path -LiteralPath $placed)) {
            try { New-Item -ItemType Directory -Force $ls | Out-Null; Copy-Item (Join-Path $msDir 'plum.sqlite*') $ls -Force -ErrorAction Stop; $res.Settings += 'StickyNotesPlaced'; & $Log '  > Sticky Notes put in place (they show the next time Sticky Notes opens).' }
            catch { & $Log "  ! Sticky Notes not put in place ($($_.Exception.Message)) - the copy is in Documents\Migrated Settings." }
        }
    }

    if ($res.Oversized.Count) {
        $res.Oversized | Export-Csv (Join-Path $LogDir "$ProfileName.oversized.csv") -NoTypeInformation
        if (Test-Path -LiteralPath $overRoot) {
            $res.Oversized | Export-Csv (Join-Path $overRoot '_oversized-manifest.csv') -NoTypeInformation
            "Large files from $ProfileName's folders, set aside on $(Get-Date -Format 'yyyy-MM-dd HH:mm') by MoveMate (over $(Format-Size $MaxBytes)).`r`nThey were NOT copied over the network. Carry this folder to the new PC on an external drive.`r`nOriginal locations: _oversized-manifest.csv" |
                Set-Content (Join-Path $overRoot 'README.txt') -Encoding UTF8
        }
    }

    if ($Target -eq 'Mirror') {
        # Export to a drive: marker that Import's profile scan looks for.
        "Exported $(Get-Date -Format 'yyyy-MM-dd HH:mm') from $SourcePc $src`r`nFolders: $($Folders -join ', ')  Errors: $($res.Errors)  Cancelled: $($res.Cancelled)" |
            Set-Content (Join-Path $dstBase '_Migration-Report.txt') -Encoding UTF8
    } else {
        # The user's own report, on THEIR desktop (C:\Migration\<user>\Desktop moves there at the handoff).
        $oldPath = { param($p) if ($OldRoot -and $p.StartsWith($SrcRoot, [StringComparison]::OrdinalIgnoreCase)) { $OldRoot + $p.Substring($SrcRoot.TrimEnd('\').Length) } else { $p -replace '^\\\\[^\\]+\\[A-Za-z]\$', 'C:' } }
        $L = New-Object Collections.Generic.List[string]
        # Someone else gets them (replacing the old user), or nobody yet (backup): say whose files these are
        $oldUser = Get-HandoffUser $ProfileName
        $forOther = [bool]$ForSomeoneElse
        $L.Add($(if ($BackupOnly) { "BACKUP OF $($oldUser.ToUpper())'S FILES FROM $SourcePc" } elseif ($forOther) { "FILES FROM $($oldUser.ToUpper())'S ACCOUNT ON THE OLD COMPUTER" } else { 'FILES COPIED FROM YOUR OLD COMPUTER' })); $L.Add('')
        if ($forOther -and -not $BackupOnly) { $L.Add("These are $oldUser's files, given to you ($userName)."); $L.Add('') }
        $L.Add("Old computer : $SourcePc   ($(if ($BackupOnly -or $forOther) { "$oldUser's" } else { 'user' }) folder $(& $oldPath $src))")
        $L.Add("New computer : $DestPc   on $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
        $L.Add("Copied       : $($res.Files) files, $(Format-Size $res.Bytes)$(if ($res.FailedFiles) { "   ($($res.FailedFiles) could not be copied - ask IT)" })")
        # string, not Join-Path: the label is a path on the NEW PC (its D: may not exist here)
        $otherDir = if ($Layout -eq 'Other') { "$("$(if ($OtherLabel) { $OtherLabel } else { $OtherRoot })".TrimEnd('\'))\$userName" }
        if ($otherDir) {
            $L.Add(''); $L.Add("Everything is in the folder:  $otherDir")
            if (-not $BackupOnly) { $L.Add('(not in your usual Desktop / Documents folders - open that folder to find your files)') }
        } elseif ($prefix) {
            $L.Add(''); $L.Add("Everything is in the folder `"$BackupName`" on your Desktop.")
            $L.Add("Move what you need into your normal folders; when you are done, you can delete `"$BackupName`".")
        } else { $L.Add(''); $L.Add('Your files went into the same folders as on the old computer (Desktop, Documents, ...).') }
        if ($ReportNote) { $L.Add($ReportNote) }
        $msBase = Join-Path $dstBase $(if ($prefix) { Join-Path $prefix 'Documents\Migrated Settings' } else { 'Documents\Migrated Settings' })
        $dp = Join-Path $msBase 'Drives and printers.txt'
        if (Test-Path -LiteralPath $dp) { $L.Add(''); foreach ($x in @(Get-Content -LiteralPath $dp -Encoding UTF8)) { $L.Add($x) } }
        if (Test-Path -LiteralPath (Join-Path $msBase 'Sticky Notes')) {
            $L.Add(''); $L.Add($(if ($res.Settings -contains 'StickyNotesPlaced') { 'STICKY NOTES: copied - open Sticky Notes to see them.' } else { 'STICKY NOTES: a copy is in Documents\Migrated Settings\Sticky Notes (ask IT to put it in place).' }))
        }
        $wp = @(Get-ChildItem -LiteralPath $msBase -Filter 'Wallpaper.*' -File -ErrorAction SilentlyContinue)[0]
        if ($wp) { $L.Add(''); $L.Add("WALLPAPER: your old desktop picture is Documents\Migrated Settings\$($wp.Name) - right-click it > Set as desktop background.") }
        $L.Add(''); $L.Add('FOLDERS')
        foreach ($m in $res.FolderMap) { $L.Add(('  {0,-14} -> {1,-45} {2,6} files  {3}' -f $m.From, $m.To, $m.Files, (Format-Size $m.Bytes))) }
        if ($res.Oversized.Count) {
            $L.Add(''); $L.Add("LARGE FILES NOT COPIED ($($res.Oversized.Count)) - still on the old computer; ask IT if you need them:")
            foreach ($o in $res.Oversized) { $L.Add(('  {0,8} MB  {1}{2}' -f $o.SizeMB, (& $oldPath $o.Original), $(if ($o.NewPath) { "   (now in $(& $oldPath $o.NewPath))" }))) }
        }
        $L.Add(''); $L.Add("EVERY FILE COPIED   (location in $(if ($otherDir) { $otherDir } else { 'your user folder' })   <-   where it was on the old computer)")
        foreach ($c in ($res.Copied | Sort-Object To)) { $L.Add("  $($c.To)   <-   $(& $oldPath $c.From)") }
        if (-not $res.Copied.Count) { $L.Add('  (nothing new - everything was already copied)') }
        $name = "Migration Report - {0} {1}.txt" -f $SourcePc, (Get-Date -Format 'yyyy-MM-dd HHmm')
        if ($otherDir) {
            # A copy in the folder itself; the one on the desktop is what the user sees first
            [IO.File]::WriteAllLines((Join-Path $dstBase $name), $L, (New-Object Text.UTF8Encoding $true))
            $prof = Join-Path (Join-Path $DstRoot 'Users') $userName
            if ($BackupOnly) { $desk = $dstBase }   # the copy in the folder is the only one
            elseif ($Target -eq 'Profile' -and (Test-Path -LiteralPath $prof)) { $desk = Join-Path $prof 'Desktop' }
            else { $desk = Join-Path (Join-Path (Join-Path $DstRoot 'Migration') $userName) 'Desktop'; $res.ReceiptStaged = $userName }
        } else { $desk = Join-Path $dstBase 'Desktop' }
        New-Item -ItemType Directory -Force $desk | Out-Null
        $res.Report = Join-Path $desk $name
        [IO.File]::WriteAllLines($res.Report, $L, (New-Object Text.UTF8Encoding $true))
        & $Log "  Report for the user: $($res.Report)"
    }
    $res
}

# ---------- "Settings & lists" extras ----------
# Who is signed in / which file-locking apps run on the OLD PC (this PC, or another over DCOM): App + owner user name.
function Get-SourceActivity([string]$Computer, [pscredential]$Credential) {
    $c = @{}
    if ($Computer) {
        $p = @{ ComputerName = $Computer; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        $c.CimSession = New-CimSession @p
    }
    try {
        $f = (@('explorer.exe', 'OUTLOOK.EXE', 'ONENOTE.EXE', 'WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'MSACCESS.EXE') | ForEach-Object { "Name='$_'" }) -join ' OR '
        @(Get-CimInstance @c Win32_Process -Filter $f -ErrorAction Stop | ForEach-Object {
            $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
            [pscustomobject]@{ App = $_.Name; User = "$($o.User)" } })
    } finally { if ($c.CimSession) { Remove-CimSession $c.CimSession } }
}

# Mapped drives and printer connections of one profile (listed for the user and IT; NOT moved - drivers and print servers
# differ). Signed in on this PC: read from their loaded registry; otherwise a temporary copy of NTUSER.DAT is loaded.
function Get-UserNetworkItems([string]$ProfilePath) {
    $r = [pscustomobject]@{ Drives = @(); Printers = @(); Note = '' }
    $read = { param($root)
        $r.Drives = @(Get-ChildItem "$root\Network" -ErrorAction SilentlyContinue | ForEach-Object { '{0}:  {1}' -f $_.PSChildName.ToUpper(), (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath })
        $r.Printers = @(Get-ChildItem "$root\Printers\Connections" -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName -replace ',', '\' })
    }
    $sid = $null
    if ($ProfilePath -notlike '\\*') { $sid = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -eq $ProfilePath })[0].SID }
    if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) { & $read "Registry::HKEY_USERS\$sid"; return $r }
    $tmp = Join-Path $env:TEMP "kitmig-hive-$([guid]::NewGuid().ToString('n')).dat"
    try { Copy-Item -LiteralPath (Join-Path $ProfilePath 'NTUSER.DAT') $tmp -Force -ErrorAction Stop }
    catch { $r.Note = 'could not be read (the user is probably signed in on the old PC)'; return $r }
    $key = 'KitMig_' + [guid]::NewGuid().ToString('n').Substring(0, 8)
    & reg.exe load "HKU\$key" $tmp 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $r.Note = 'could not be read'; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; return $r }
    try { & $read "Registry::HKEY_USERS\$key" }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$key" 2>$null | Out-Null
        Get-ChildItem -Path "$tmp*" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $r
}
# Writes the chosen extras of one profile into $DestDir (the user's Documents\Migrated Settings). Returns the files written.
#   StickyNotes    -> Sticky Notes\plum.sqlite(-wal/-shm)  (+ put in place on the new PC by Invoke-ProfileMigration)
#   Wallpaper      -> Wallpaper.jpg/.png (the current desktop picture)
#   DrivesPrinters -> Drives and printers.txt (also printed on the user's receipt)
function Export-MigratedSettings([string]$ProfilePath, [string]$DestDir, [string[]]$Which, [string]$OldPc) {
    $out = @()
    if ($Which -contains 'StickyNotes') {
        $f = @(Get-ChildItem -LiteralPath (Join-Path $ProfilePath 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState') -Filter 'plum.sqlite*' -File -Force -ErrorAction SilentlyContinue)
        if ($f.Count) {
            $d = Join-Path $DestDir 'Sticky Notes'; New-Item -ItemType Directory -Force $d | Out-Null
            foreach ($x in $f) { try { Copy-Item -LiteralPath $x.FullName (Join-Path $d $x.Name) -Force -ErrorAction Stop; $out += Join-Path $d $x.Name } catch {} }
        }
    }
    if ($Which -contains 'Wallpaper') {
        $w = Join-Path $ProfilePath 'AppData\Roaming\Microsoft\Windows\Themes\TranscodedWallpaper'
        if (Test-Path -LiteralPath $w) {
            $head = New-Object byte[] 2; $fs = [IO.File]::OpenRead($w); [void]$fs.Read($head, 0, 2); $fs.Close()
            $t = Join-Path $DestDir $(if ($head[0] -eq 0x89 -and $head[1] -eq 0x50) { 'Wallpaper.png' } else { 'Wallpaper.jpg' })
            New-Item -ItemType Directory -Force $DestDir | Out-Null; Copy-Item -LiteralPath $w $t -Force; $out += $t
        }
    }
    if ($Which -contains 'DrivesPrinters') {
        $n = Get-UserNetworkItems $ProfilePath
        $L = @("NETWORK DRIVES AND PRINTERS on $OldPc (listed, not moved - ask IT if you still need one):")
        if ($n.Note) { $L += "  ($($n.Note))" }
        else {
            $L += '  Drives:   ' + $(if ($n.Drives.Count) { $n.Drives -join '   ' } else { 'none' })
            $L += '  Printers: ' + $(if ($n.Printers.Count) { $n.Printers -join '   ' } else { 'none' })
        }
        New-Item -ItemType Directory -Force $DestDir | Out-Null
        $t = Join-Path $DestDir 'Drives and printers.txt'; [IO.File]::WriteAllLines($t, $L, (New-Object Text.UTF8Encoding $true)); $out += $t
    }
    $out
}

# Installed programs (Apps & features) of this PC, or another one over DCOM (registry via StdRegProv), WITHOUT Windows'
# own parts: no system components, updates, runtimes / redistributables. Name, Version, Publisher, Installed (yyyyMMdd).
$MigSoftSkip = '^(KB\d+|Update for |Security Update|Hotfix)|Microsoft Visual C\+\+ .*Redistributable|Microsoft \.NET|Microsoft Windows Desktop Runtime|Microsoft ASP\.NET|^Microsoft Edge( Update| WebView2.*)?$|Microsoft Update Health Tools|Windows (SDK|Software Development Kit|Driver Package)|Microsoft GameInput|Teams Machine-Wide Installer|Windows PC Health Check'
function Get-InstalledSoftware([string]$Computer, [pscredential]$Credential) {
    $paths = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $items = New-Object Collections.Generic.List[object]
    if ($Computer) {
        $p = @{ ComputerName = $Computer; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        $cs = New-CimSession @p
        try {
            $reg = { param($m, $a) Invoke-CimMethod -CimSession $cs -Namespace root/default -ClassName StdRegProv -MethodName $m -Arguments $a -ErrorAction SilentlyContinue }
            $HKLM = [uint32]2147483650
            foreach ($path in $paths) {
                foreach ($k in @((& $reg EnumKey @{ hDefKey = $HKLM; sSubKeyName = $path }).sNames)) {
                    if (-not $k) { continue }
                    $sub = "$path\$k"; $v = { param($n) (& $reg GetStringValue @{ hDefKey = $HKLM; sSubKeyName = $sub; sValueName = $n }).sValue }
                    $name = & $v 'DisplayName'; if (-not $name) { continue }
                    $items.Add([pscustomobject]@{ Name = $name; Version = (& $v 'DisplayVersion'); Publisher = (& $v 'Publisher'); Installed = (& $v 'InstallDate')
                        System = (& $reg GetDWORDValue @{ hDefKey = $HKLM; sSubKeyName = $sub; sValueName = 'SystemComponent' }).uValue; Parent = (& $v 'ParentKeyName'); Release = (& $v 'ReleaseType') })
                }
            }
        } finally { Remove-CimSession $cs }
    } else {
        $roots = @('HKLM:') + @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)" })
        foreach ($root in $roots) {
            foreach ($path in $paths) {
                foreach ($k in @(Get-ChildItem "$root\$path" -ErrorAction SilentlyContinue)) {
                    $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                    if ($v.DisplayName) { $items.Add([pscustomobject]@{ Name = $v.DisplayName; Version = $v.DisplayVersion; Publisher = $v.Publisher; Installed = $v.InstallDate; System = $v.SystemComponent; Parent = $v.ParentKeyName; Release = $v.ReleaseType }) }
                }
            }
        }
    }
    @($items | Where-Object { "$($_.Name)".Trim() -and $_.System -ne 1 -and -not $_.Parent -and -not $_.Release -and $_.Name -notmatch $MigSoftSkip } |
        Sort-Object Name -Unique | Select-Object @{ n = 'Name'; e = { "$($_.Name)".Trim() } }, Version, Publisher, Installed)
}
# Searchable page for IT ("Application inventory"): the old PC's printers (name, driver, IP) and every program with a "search the
# web for it" link, plus the matching entry from the Installers list (extras\installers.csv) when there is one.
function New-SoftwareReport([object[]]$Software, [string]$OldPc, [string]$Path, [object[]]$Installers = @(), [object[]]$Printers = @()) {
    $enc = { param($t) [Net.WebUtility]::HtmlEncode("$t") }
    $rows = foreach ($s in $Software) {
        $q = [Uri]::EscapeDataString("$($s.Name) download")
        $inst = $Installers | Where-Object { $m = if ($_.Match) { $_.Match } else { $_.Name }; $s.Name -like "*$m*" -or $s.Name -like $m } | Select-Object -First 1
        $date = if ("$($s.Installed)" -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { '' }
        $instCell = ''
        if ($inst) { $instCell = '<a href="' + (& $enc $inst.Url) + '" target="_blank">' + (& $enc $inst.Name) + '</a>'; if ($inst.File) { $instCell += ' (on the stick)' } }
        '<tr><td><a href="https://www.google.com/search?q=' + $q + '" target="_blank">' + (& $enc $s.Name) + '</a></td><td>' + (& $enc $s.Version) + '</td><td>' + (& $enc $s.Publisher) + '</td><td>' + $date + '</td><td>' + $instCell + '</td></tr>'
    }
    $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>Application inventory - $(& $enc $OldPc)</title>
<style>body{font:14px Segoe UI,sans-serif;margin:24px;color:#222}h1{font-size:20px}input{font:inherit;padding:6px 10px;width:320px;margin:8px 0 14px}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #e3e3e3}th{background:#f3f5f8;position:sticky;top:0}
a{color:#0a58ca;text-decoration:none}a:hover{text-decoration:underline}.n{color:#666}</style></head><body>
<h1>$(& $enc $OldPc) - printers and installed software</h1>
$(if ($Printers.Count) { '<h2 style="font-size:16px">Printers</h2><table><thead><tr><th>Printer</th><th>IP / host</th><th>Driver</th><th>Port</th></tr></thead><tbody>' + (($Printers | ForEach-Object { '<tr><td>' + (& $enc $_.Name) + $(if ($_.Default) { ' <b>(default)</b>' }) + '</td><td>' + (& $enc $_.IP) + '</td><td>' + (& $enc $_.Driver) + '</td><td>' + (& $enc $_.Port) + '</td></tr>' }) -join "`n") + '</tbody></table><h2 style="font-size:16px;margin-top:24px">Programs</h2>' })<div class="n">$($Software.Count) programs (Windows' own parts, updates and runtimes left out) - listed $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $MigToolName. Click a name to search for its download.</div>
<input id="q" placeholder="Search..." oninput="var v=this.value.toLowerCase();document.querySelectorAll('#progs tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(v)<0?'none':''})">
<table id="progs"><thead><tr><th>Program</th><th>Version</th><th>Publisher</th><th>Installed</th><th>Installers list</th></tr></thead><tbody>
$($rows -join "`n")
</tbody></table></body></html>
"@
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
}
# Printers installed on this PC or another (DCOM): name, driver, port, IP/host of a TCP/IP port. Windows' virtual ones left out.
function Get-PrinterList([string]$Computer, [pscredential]$Credential) {
    $c = @{}
    if ($Computer) {
        $p = @{ ComputerName = $Computer; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        $c.CimSession = New-CimSession @p
    }
    try {
        $ports = @{}; foreach ($t in @(Get-CimInstance @c Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue)) { $ports[$t.Name] = $t.HostAddress }
        @(Get-CimInstance @c Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -notmatch '^(Microsoft (Print to PDF|XPS Document Writer)|Fax|OneNote|Send To OneNote|Adobe PDF)' } |
            Sort-Object Name | ForEach-Object {
                $ip = if ($ports.ContainsKey($_.PortName)) { $ports[$_.PortName] } elseif ($_.PortName -match '^(IP_)?(\d+\.\d+\.\d+\.\d+)') { $Matches[2] } else { '' }
                [pscustomobject]@{ Name = $_.Name; Driver = $_.DriverName; Port = $_.PortName; IP = $ip; Default = [bool]$_.Default; Shared = [bool]$_.Shared }
            })
    } finally { if ($c.CimSession) { Remove-CimSession $c.CimSession } }
}
# Print-server printers (\\server\printer) the given profiles are connected to: each user's own connections, which
# PrintBrm does not carry (it carries the PC's printers). Unique, sorted.
function Get-ProfilePrinterConnections([string]$UsersRoot, [string[]]$Users) {
    @($Users | ForEach-Object { (Get-UserNetworkItems (Join-Path $UsersRoot $_)).Printers } | Where-Object { "$_" -like '\\*' } | Sort-Object -Unique)
}
# Print-server printers for EVERY user of a PC (this one, or -Computer): per-machine connections (printui /ga), which
# Windows adds to each user's printers when they sign in - existing users and new ones alike. The spooler is restarted
# so they take effect; the print server must be reachable then for the driver to come down. Returns lines for the log.
function Add-GlobalPrinterConnection([string[]]$Names, [string]$Computer) {
    $pc = if ($Computer) { $Computer.TrimStart('\') } else { '' }
    $on = if ($pc) { " /c\\$pc" } else { '' }
    $lines = @()
    foreach ($n in $Names) {
        $p = Start-Process rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /ga /q /n`"$n`"$on" -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; $lines += "  $n - no answer in 2 minutes (print server not reachable?)" }
    }
    # Which ones Windows now has as per-machine connections (/ge lists them)
    $list = Join-Path $env:TEMP "kitmig-ge-$([guid]::NewGuid().ToString('n')).txt"
    $p = Start-Process rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /ge /q /f`"$list`"$on" -PassThru -WindowStyle Hidden
    [void]$p.WaitForExit(60000)
    $have = if (Test-Path -LiteralPath $list) { Get-Content -LiteralPath $list -Raw -ErrorAction SilentlyContinue } else { $null }
    Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
    foreach ($n in $Names) {
        if (@($lines | Where-Object { $_ -like "  $n -*" }).Count) { continue }
        $lines += if ($null -eq $have) { "  $n - requested for every user (could not be checked)" }
                  elseif ($have -match [regex]::Escape($n)) { "  $n - added for every user" }
                  else { "  $n - NOT added (print server not reachable, or a Point and Print policy blocks it)" }
    }
    try {
        if ($pc) { Get-Service -ComputerName $pc -Name Spooler -ErrorAction Stop | Restart-Service -Force -ErrorAction Stop }
        else { Restart-Service -Name Spooler -Force -ErrorAction Stop }
    } catch { $lines += "  (print spooler not restarted: $($_.Exception.Message) - the printers appear after the PC restarts)" }
    $lines
}
# Printer carry-over with Windows' own Printer Migration tool (PrintBrm): queues + drivers + ports + settings.
# -Backup: from this PC or \\Computer into $File. -Restore: $File onto this PC or \\Computer (existing printers are kept,
# not overwritten). Returns @{ Ok; Output }.
function Invoke-PrintBrm([switch]$Backup, [switch]$Restore, [string]$File, [string]$Computer) {
    $exe = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return @{ Ok = $false; Output = 'PrintBrm.exe is not on this PC (Windows edition without the Printer Migration tool).' } }
    $a = @($(if ($Backup) { '-B' } else { '-R' }))
    if ($Computer) { $a += @('-S', "\\$($Computer.TrimStart('\'))") }
    $a += @('-F', $File)
    $out = & $exe @a 2>&1 | Out-String
    @{ Ok = ($LASTEXITCODE -eq 0); Output = $out.Trim() }
}

# The Installers list: <tool>\extras\installers.csv  (Name, Url, File, Args, Match, Notes)
function Read-InstallerList([string]$Csv) {
    if (-not (Test-Path -LiteralPath $Csv)) { return @() }
    @(Import-Csv -LiteralPath $Csv -Encoding UTF8 | Where-Object { "$($_.Name)".Trim() } | ForEach-Object {
        [pscustomobject]@{ Name = "$($_.Name)".Trim(); Url = "$($_.Url)".Trim(); File = "$($_.File)".Trim(); Args = "$($_.Args)".Trim(); Match = "$($_.Match)".Trim(); Notes = "$($_.Notes)".Trim() } })
}

# ---------- Server offload packages ----------
# A package is a folder on a share: header.json (plain: protection, salt/verifier, old PC, user names, sizes) and either
#   Protection None: Users\<user>\... plain copy (same layout as a drive export), or
#   Protection Key/Password: data\NNNNNN.bin blobs + manifest.bin. Every file: 'MUF1' + IV(16) + AES-256-CBC + HMAC-SHA256(32)
#   over IV+ciphertext (encrypt-then-MAC). File names/paths live only in the encrypted manifest.
# Keys: a 32-byte master (random for Key mode, PBKDF2-SHA256 200k from the password for Password mode) -> enc/mac keys.
$PkgMagic = [byte[]](0x4D, 0x55, 0x46, 0x31)   # 'MUF1'
$PkgHeader = 'header.json'

function New-PkgMaster { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); $b }
function Get-PkgMasterFromPassword([string]$Password, [byte[]]$Salt) {
    (New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)).GetBytes(32)
}
function Get-PkgKeys([byte[]]$Master) {
    $h = New-Object Security.Cryptography.HMACSHA256(, $Master)
    @{ Enc = $h.ComputeHash([Text.Encoding]::ASCII.GetBytes('MigrateUserFiles-enc')); Mac = $h.ComputeHash([Text.Encoding]::ASCII.GetBytes('MigrateUserFiles-mac')) }
}
# Proves a password/key is right without decrypting anything
function Get-PkgVerifier($Keys) { [Convert]::ToBase64String((New-Object Security.Cryptography.HMACSHA256(, $Keys.Mac)).ComputeHash([Text.Encoding]::ASCII.GetBytes('MigrateUserFiles-verify'))) }

# $Sync (optional): FileDone/FileTotal are updated as the file streams through (progress inside big files).
function Protect-PkgFile([string]$In, [string]$Out, $Keys, $Sync) {
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $Keys.Enc; $aes.GenerateIV()
    $hmac = New-Object Security.Cryptography.HMACSHA256(, $Keys.Mac)
    $fo = [IO.File]::Create($Out)
    try {
        $fo.Write($PkgMagic, 0, 4); $fo.Write($aes.IV, 0, 16)
        [void]$hmac.TransformBlock($aes.IV, 0, 16, $null, 0)
        # plaintext -> AES -> HMAC (pass-through) -> file
        $macS = New-Object Security.Cryptography.CryptoStream($fo, $hmac, [Security.Cryptography.CryptoStreamMode]::Write, $true)
        $encS = New-Object Security.Cryptography.CryptoStream($macS, $aes.CreateEncryptor(), [Security.Cryptography.CryptoStreamMode]::Write, $true)
        $fi = [IO.File]::Open($In, 'Open', 'Read', 'ReadWrite')
        try {
            if ($Sync) { $Sync.FileDone = [long]0; $Sync.FileTotal = $fi.Length }
            $buf = New-Object byte[] 1MB
            while (($n = $fi.Read($buf, 0, $buf.Length)) -gt 0) { $encS.Write($buf, 0, $n); if ($Sync) { $Sync.FileDone += $n } }
        } finally { $fi.Close() }
        $encS.FlushFinalBlock()   # also finalizes the inner HMAC stream (CryptoStream cascades)
        $fo.Write($hmac.Hash, 0, 32)
    } catch { $fo.Close(); Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue; throw }
    $fo.Close()
}

# Verifies the tag; on a wrong key or a damaged/tampered blob the output is deleted and it throws.
function Unprotect-PkgFile([string]$In, [string]$Out, $Keys, $Sync) {
    $fi = [IO.File]::OpenRead($In); $fo = $null
    try {
        $len = $fi.Length
        if ($len -lt 52) { throw 'not a package file (too short)' }
        $hdr = New-Object byte[] 20; [void]$fi.Read($hdr, 0, 20)
        for ($i = 0; $i -lt 4; $i++) { if ($hdr[$i] -ne $PkgMagic[$i]) { throw 'not a package file' } }
        $iv = $hdr[4..19]
        $hmac = New-Object Security.Cryptography.HMACSHA256(, $Keys.Mac); [void]$hmac.TransformBlock([byte[]]$iv, 0, 16, $null, 0)
        $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $Keys.Enc; $aes.IV = [byte[]]$iv
        $fo = [IO.File]::Create($Out)
        $decS = New-Object Security.Cryptography.CryptoStream($fo, $aes.CreateDecryptor(), [Security.Cryptography.CryptoStreamMode]::Write, $true)
        $buf = New-Object byte[] 1MB; $remaining = $len - 52
        if ($Sync) { $Sync.FileDone = [long]0; $Sync.FileTotal = $remaining }
        while ($remaining -gt 0) {
            $n = $fi.Read($buf, 0, [int][math]::Min($buf.Length, $remaining)); if ($n -le 0) { throw 'unexpected end of file' }
            [void]$hmac.TransformBlock($buf, 0, $n, $null, 0); $decS.Write($buf, 0, $n); $remaining -= $n
            if ($Sync) { $Sync.FileDone += $n }
        }
        $tag = New-Object byte[] 32; [void]$fi.Read($tag, 0, 32)
        [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $diff = 0; for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($tag[$i] -bxor $hmac.Hash[$i]) }
        if ($diff) { throw 'wrong key/password, or the file was changed on the server' }
        $decS.FlushFinalBlock(); $decS.Dispose(); $fo.Close(); $fo = $null
    } catch {
        if ($fo) { $fo.Close() }; Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue; throw
    } finally { $fi.Close() }
}

# Files to send for one user/folder (robocopy listing: junctions skipped, junk excluded). Returns @{Path; Bytes; Date}.
function Get-PkgFileList([string]$Folder) {
    foreach ($l in (Invoke-RoboList $Folder (@('/NJS', '/TS') + (Get-MigFilterOpts)))) {
        if ($l -match '^\s*(\d+)\s+(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s+(\S.*?)\s*$') { [pscustomobject]@{ Path = $Matches[3]; Bytes = [long]$Matches[1]; Date = $Matches[2] } }
    }
}

# Encrypted upload of several users into $PkgDir (runs in a background runspace; $Sync gets progress, honors $Sync.Cancel).
# $Users: @(@{ Name; Folders = @(rel...); Bookmarks = @(keys) }). Writes data\*.bin, manifest.bin, header.json and, in
# $LogDir, robocopy-style logs (<user>.<folder>.log) so the run's stats work like any other transfer.
function Export-PkgEncrypted {
    param([string]$SrcRoot, [string]$PkgDir, [object[]]$Users, $Keys, [string]$Protection, [byte[]]$Salt, [string]$OldPc, [string]$LogDir, $Sync)
    New-Item -ItemType Directory -Force (Join-Path $PkgDir 'data'), $LogDir | Out-Null
    $files = New-Object Collections.Generic.List[object]; $n = 0; $userInfo = @()
    $tmp = Join-Path $env:TEMP "migpkg-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
    foreach ($u in $Users) {
        $src = Join-Path (Join-Path $SrcRoot 'Users') $u.Name; $uFiles = 0; $uBytes = [long]0; $uFailed = 0
        $items = New-Object Collections.Generic.List[object]
        foreach ($rel in $u.Folders) {
            $s = Join-Path $src $rel
            if (-not (Test-Path -LiteralPath $s)) { continue }
            $Sync.Step = "Listing $($u.Name)\$rel"
            foreach ($f in @(Get-PkgFileList $s)) { $items.Add([pscustomobject]@{ Abs = $f.Path; Rel = $f.Path.Substring($src.Length).TrimStart('\'); Bytes = $f.Bytes; Date = $f.Date; Folder = $rel }) }
        }
        foreach ($k in $u.Bookmarks) {   # browser bookmarks (importable HTML + original/backup file), like the other modes
            foreach ($bk in @(Get-BookmarkFiles $src $k)) {
                try {
                    $x = Export-Bookmarks $k $bk.Path (Join-Path $tmp $u.Name) $bk.Name
                    foreach ($bf in $x.Html, $x.Raw) {
                        $items.Add([pscustomobject]@{ Abs = $bf; Rel = "Documents\Migrated Bookmarks\$(Split-Path $bf -Leaf)"; Bytes = (Get-Item -LiteralPath $bf).Length; Date = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss'); Folder = 'Bookmarks' })
                    }
                } catch { $uFailed++ }
            }
        }
        if ($u.Settings) {   # "Settings & lists" -> Documents\Migrated Settings, like the other modes
            try {
                $msTmp = Join-Path $tmp "$($u.Name)\Migrated Settings"
                foreach ($m in @(Export-MigratedSettings $src $msTmp @($u.Settings) $OldPc)) {
                    $items.Add([pscustomobject]@{ Abs = $m; Rel = "Documents\Migrated Settings\$($m.Substring($msTmp.Length).TrimStart('\'))"; Bytes = (Get-Item -LiteralPath $m).Length; Date = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss'); Folder = 'Settings' })
                }
            } catch { $uFailed++ }
        }
        $Sync.Total += ($items | Measure-Object Bytes -Sum).Sum
        $logs = @{}
        foreach ($it in $items) {
            if ($Sync.Cancel) { break }
            $n++; $blob = 'data\{0:D6}.bin' -f $n
            $Sync.Step = "Encrypting $($u.Name)\$($it.Rel)"
            try {
                Protect-PkgFile $it.Abs (Join-Path $PkgDir $blob) $Keys $Sync
                $files.Add([ordered]@{ u = $u.Name; r = $it.Rel; s = $it.Bytes; t = $it.Date; b = $blob })
                $uFiles++; $uBytes += $it.Bytes
                $line = "`t    New File  `t`t{0,12}`t{1}`t{2}" -f $it.Bytes, $it.Date, $it.Abs
            } catch { $uFailed++; $line = "ERROR (skipped): $($it.Abs) - $($_.Exception.Message)" }
            $key = ($it.Folder -replace '[\\/:*?"<>| ]', '_'); if (-not $logs.ContainsKey($key)) { $logs[$key] = New-Object Collections.Generic.List[string] }
            $logs[$key].Add($line)
            $Sync.FileDone = [long]0; $Sync.Done += $it.Bytes   # file finished: its bytes move from FileDone to Done
        }
        foreach ($k in $logs.Keys) { [IO.File]::WriteAllLines((Join-Path $LogDir "$($u.Name).$k.log"), $logs[$k], [Text.Encoding]::Unicode) }
        $userInfo += [ordered]@{ Name = $u.Name; Files = $uFiles; Bytes = $uBytes; Failed = $uFailed }
        if ($Sync.Cancel) { break }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # Encrypted manifest (names + where each blob goes), then the plain header
    $mf = Join-Path $env:TEMP "migpkg-manifest-$PID.json"
    ([ordered]@{ Version = 1; OldPC = $OldPc; Created = (Get-Date).ToString('s'); Files = $files } | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $mf -Encoding UTF8
    Protect-PkgFile $mf (Join-Path $PkgDir 'manifest.bin') $Keys; Remove-Item -LiteralPath $mf -Force
    [ordered]@{ Format = 'MigrateUserFiles-Package'; Version = 1; Protection = $Protection; Salt = $(if ($Salt) { [Convert]::ToBase64String($Salt) } else { '' })
        Verifier = (Get-PkgVerifier $Keys); OldPC = $OldPc; Created = (Get-Date).ToString('s'); Complete = (-not $Sync.Cancel)
        Users = $userInfo; FileCount = $files.Count; TotalBytes = [long](($files | ForEach-Object { $_.s } | Measure-Object -Sum).Sum) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PkgDir $PkgHeader) -Encoding UTF8
    [pscustomobject]@{ Users = $userInfo; Files = $files.Count; Cancelled = [bool]$Sync.Cancel }
}

# Decrypts the chosen users of an encrypted package into $Staging\Users\<user>\... (dates restored). Background-safe.
function Import-PkgEncrypted {
    param([string]$PkgDir, $Keys, [string[]]$UserNames, [string]$Staging, $Sync)
    $mf = Join-Path $env:TEMP "migpkg-manifest-in-$PID.json"
    Unprotect-PkgFile (Join-Path $PkgDir 'manifest.bin') $mf $Keys
    $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json; Remove-Item -LiteralPath $mf -Force
    $todo = @($m.Files | Where-Object { $UserNames -contains $_.u })
    $Sync.Total = [long](($todo | ForEach-Object { [long]$_.s } | Measure-Object -Sum).Sum)
    $ok = 0; $bad = New-Object Collections.Generic.List[string]
    foreach ($f in $todo) {
        if ($Sync.Cancel) { break }
        if ("$($f.r)" -match '(^|\\)\.\.(\\|$)' -or "$($f.r)" -match '^[A-Za-z]:|^\\') { $bad.Add("$($f.u)\$($f.r) (bad path)"); continue }   # never write outside the staging folder
        $out = Join-Path (Join-Path (Join-Path $Staging 'Users') $f.u) $f.r
        $Sync.Step = "Decrypting $($f.u)\$($f.r)"
        try {
            New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
            Unprotect-PkgFile (Join-Path $PkgDir $f.b) $out $Keys $Sync
            try { [IO.File]::SetLastWriteTime($out, [datetime]::ParseExact($f.t, 'yyyy/MM/dd HH:mm:ss', $null)) } catch {}
            $ok++
        } catch { $bad.Add("$($f.u)\$($f.r): $($_.Exception.Message)") }
        $Sync.FileDone = [long]0; $Sync.Done += [long]$f.s
    }
    [pscustomobject]@{ Expected = $todo.Count; Ok = $ok; Failed = $bad; Cancelled = [bool]$Sync.Cancel }
}

# ---------- Direct cable: one Ethernet cable between the PCs, temporary fixed addresses OLD 10.99.99.1 / NEW 10.99.99.2 ----------
$CableAddr = @{ Old = '10.99.99.1'; New = '10.99.99.2' }
$CableState = Join-Path $env:ProgramData 'KitMigrate\cable.json'

function Test-Port([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000) {
    $c = New-Object Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($HostName, $Port, $null, $null); ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) } catch { $false } finally { $c.Close() }
}

# One check: the wired adapter with a link and NO gateway (= the cable). Returns the adapter, $null (no link yet),
# or throws if the only linked wired port is on a real network.
function Find-CableAdapter {
    $up = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless|WLAN|Bluetooth|Virtual|Hyper-V' })
    foreach ($a in $up) { if (-not (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) { return $a } }
    if ($up.Count) { throw "The wired port '$($up[0].Name)' is on a real network (it has a gateway). Use Network instead, or plug the PC-to-PC cable into that port." }
    $null
}

# Gives $Nic the temporary address for $Role (state saved first so Restore-CableLink can always undo it).
function Enable-CableLink($Nic, [ValidateSet('Old', 'New')][string]$Role) {
    if (Test-Path $CableState) { [void](Restore-CableLink) }
    $ip = $CableAddr[$Role]
    $wasDhcp = "$((Get-NetIPInterface -InterfaceIndex $Nic.ifIndex -AddressFamily IPv4).Dhcp)" -eq 'Enabled'
    New-Item -ItemType Directory -Force (Split-Path $CableState) | Out-Null
    @{ IfIndex = $Nic.ifIndex; Alias = $Nic.Name; TempIp = $ip; WasDhcp = $wasDhcp; Role = $Role } | ConvertTo-Json | Set-Content $CableState -Encoding UTF8
    # ActiveStore only: the change is NOT saved, so a reboot always gives the PC its normal network settings back.
    if ($wasDhcp) { Set-NetIPInterface -InterfaceIndex $Nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled -PolicyStore ActiveStore }
    New-NetIPAddress -InterfaceIndex $Nic.ifIndex -IPAddress $ip -PrefixLength 24 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    for ($i = 0; $i -lt 15; $i++) {
        $st = "$((Get-NetIPAddress -InterfaceIndex $Nic.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue).AddressState)"
        if ($st -eq 'Preferred') { break }
        if ($st -eq 'Duplicate') { throw "$ip is already in use on the cable - is the other PC also set to $Role?" }
        Start-Sleep 1
    }
    $ip
}

function Restore-CableLink {
    if (-not (Test-Path $CableState)) { return }
    $s = Get-Content $CableState -Raw | ConvertFrom-Json
    # Both stores: also heals PCs changed by older versions, which saved the temporary address permanently.
    foreach ($ps in 'ActiveStore', 'PersistentStore') {
        Get-NetIPAddress -InterfaceIndex $s.IfIndex -AddressFamily IPv4 -PolicyStore $ps -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like '10.99.99.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        if ($s.WasDhcp) { Set-NetIPInterface -InterfaceIndex $s.IfIndex -AddressFamily IPv4 -Dhcp Enabled -PolicyStore $ps -ErrorAction SilentlyContinue }
    }
    [IO.File]::Delete($CableState)
    "Network adapter '$($s.Alias)' restored$(if ($s.WasDhcp) { ' (automatic IP again)' })."
}

# ---------- Pairing (direct cable): no domain controller on a cable, so domain logins can't be checked across it. ----------
# Each PC creates a temporary local admin 'KitMigrate' whose password is a one-time pairing code shown on its screen; the
# other PC connects with that code. Also: LocalAccountTokenFilterPolicy=1 (local admin over the network) and the File and
# Printer Sharing firewall rules on. Everything is undone by Stop-PairingHost (window close, or next start after a crash).
$PairUser = 'KitMigrate'
$PairState = Join-Path $env:ProgramData 'KitMigrate\pair.json'
$PairPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

# Pairing codes are 4 characters (offline, temporary account). Normalizes what someone typed (" 7q4m ") or returns $null.
function Format-PairCode([string]$Text) {
    $b = $Text.ToUpper() -replace '[^A-Z0-9]', ''
    if ($b.Length -ne 4) { return $null }
    $b
}
# The real password wraps the code in fixed text nobody types, so it passes length/complexity policies (up to 20 chars).
function Get-PairPassword([string]$Code) { "KitPair-$Code-TempCable!" }
# Direct cable with no other network: a fixed code, so the PCs connect to each other with nothing to type.
$PairAutoCode = 'AUTO'
# Is this PC on any real network (a default gateway on any adapter)? Then a fixed password would be exposed there.
function Test-OnNetwork { [bool](Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' }) }
# Same question, fast (.NET, no CIM) for the pairing watch that asks every few seconds: the name of an adapter that is
# up with an IPv4 default gateway, or $null. The cable adapter itself never has a gateway.
function Get-GatewayAdapter {
    foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne 'Up') { continue }
        $gw = @($n.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and "$($_.Address)" -ne '0.0.0.0' })
        if ($gw.Count) { return $n.Name }
    }
    $null
}

# -Auto: use the fixed cable code ONLY if this PC is on no other network; otherwise a random 4-character code.
function Start-PairingHost([switch]$Auto) {
    if (Test-Path $PairState) { [void](Stop-PairingHost) }
    if ($Auto -and -not (Test-OnNetwork)) { $code = $PairAutoCode } else {
        $alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()   # no 0/O/1/I
        $bytes = New-Object byte[] 4; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $code = Format-PairCode (-join ($bytes | ForEach-Object { $alpha[$_ % $alpha.Length] }))
    }
    $old = (Get-ItemProperty $PairPolicyKey -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    $fw = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -Direction Inbound -ErrorAction SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'False' } | ForEach-Object Name)
    New-Item -ItemType Directory -Force (Split-Path $PairState) | Out-Null
    [ordered]@{ PolicyOld = $old; Firewall = $fw; Created = (Get-Date).ToString('s'); Auto = ($code -eq $PairAutoCode) } | ConvertTo-Json | Set-Content $PairState -Encoding UTF8   # before changing anything
    try {
        # Login first, file-sharing port LAST: when the other PC can reach port 445 here, this PC is fully ready.
        Set-ItemProperty $PairPolicyKey -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
        if (Get-LocalUser -Name $PairUser -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $PairUser }
        $pw = ConvertTo-SecureString (Get-PairPassword $code) -AsPlainText -Force
        # Description max 48 characters (New-LocalUser limit)
        New-LocalUser -Name $PairUser -Password $pw -AccountNeverExpires -PasswordNeverExpires -Description 'Temp cable pairing (MoveMate)' -ErrorAction Stop | Out-Null
        # Pass the account object, not its name: a bare name is looked up on the DOMAIN first, which hangs with no network.
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member (Get-LocalUser -Name $PairUser) -ErrorAction Stop
        if ((Get-Service LanmanServer).Status -ne 'Running') { Start-Service LanmanServer }
        foreach ($n in $fw) { Enable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue }
    } catch {
        [void](Stop-PairingHost)   # undo whatever was done, then report
        throw "Pairing setup failed: $($_.Exception.Message)"
    }
    $code
}

# How this PC reaches another one: 'Wi-Fi', 'Wired' or '' (unknown). Over Wi-Fi a copy works but is usually much slower.
function Get-LinkMedium([string]$Computer) {
    try {
        $ip = if ($Computer -match '^\d+\.\d+\.\d+\.\d+$') { $Computer } else { @([Net.Dns]::GetHostAddresses($Computer) | Where-Object AddressFamily -eq 'InterNetwork')[0].IPAddressToString }
        $route = @(Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop)[0]
        $nic = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        if ($nic.NdisPhysicalMedium -eq 9 -or $nic.PhysicalMediaType -match '802\.11|Wireless') { 'Wi-Fi' } else { 'Wired' }
    } catch { '' }
}

# Is file sharing on this PC reachable over the cable? (firewall on + its SMB rule off for the cable's network = blocked)
function Get-SharingProblem {
    if ((Get-Service LanmanServer).Status -ne 'Running') { return 'The Server service (file sharing) is not running.' }
    $prof = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' } | ForEach-Object Name)
    if (-not $prof.Count) { return $null }   # firewall off (e.g. by Group Policy)
    $smb = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -Direction Inbound -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'SMB-In' -and "$($_.Enabled)" -eq 'True' })
    if (-not $smb.Count) { return 'The firewall blocks file sharing (SMB-In rule is off), and it could not be turned on - Group Policy may manage it.' }
    $null
}

function Stop-PairingHost {
    if (-not (Test-Path $PairState)) { return }
    $s = Get-Content $PairState -Raw | ConvertFrom-Json
    Remove-LocalUser -Name $PairUser -ErrorAction SilentlyContinue
    $prof = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -like "*\$PairUser" }
    if ($prof) { $prof | Remove-CimInstance -ErrorAction SilentlyContinue }
    if ($null -eq $s.PolicyOld) { Remove-ItemProperty $PairPolicyKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $PairPolicyKey -Name LocalAccountTokenFilterPolicy -Value ([int]$s.PolicyOld) -Type DWord }
    foreach ($n in @($s.Firewall)) { if ($n) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue } }
    [IO.File]::Delete($PairState)
    "Temporary admin account '$PairUser' deleted from this PC; sharing settings restored."
}

# Safety net for the AUTOMATIC cable login (its password is fixed and published with the source): if this PC joins any
# other network while that login exists (e.g. Wi-Fi reconnects mid-copy), delete it at once and drop every session of
# it that is not from the cable peer. Random-code logins (Allow access on a network) are left alone - they are meant
# for a network. Returns a line for the log when it acted, else $null.
function Assert-PairingOffline {
    if (-not (Test-Path $PairState)) { return $null }
    try { $s = Get-Content $PairState -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $s.Auto) { return $null }
    $net = Get-GatewayAdapter
    if (-not $net) { return $null }
    Get-SmbSession -ErrorAction SilentlyContinue | Where-Object { $_.ClientUserName -match "\\$PairUser$" -and $_.ClientComputerName -notlike '10.99.99.*' } |
        Close-SmbSession -Force -ErrorAction SilentlyContinue
    "! This PC joined a network ('$net') while the automatic cable login was on. $(Stop-PairingHost)"
}

# ---------- Update check: asks GitHub for the latest release of $MigUpdateRepo (nothing about this PC is sent) ----------
# Returns @{ Version; Tag; Url; Newer }. Throws when GitHub can't be reached or no release is published (404).
function Get-MigLatestRelease([int]$TimeoutSec = 8) {
    # Windows PowerShell 5.1 may still offer only TLS 1.0/1.1, which GitHub refuses
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$MigUpdateRepo/releases/latest" -TimeoutSec $TimeoutSec -UseBasicParsing `
        -Headers @{ 'User-Agent' = "$MigToolName/$MigToolVersion"; Accept = 'application/vnd.github+json' }
    if ("$($r.tag_name)" -notmatch '\d+(\.\d+){1,3}') { throw "Unexpected release tag '$($r.tag_name)'." }
    $v = [version]$Matches[0]
    @{ Version = $v; Tag = "$($r.tag_name)"; Url = "$($r.html_url)"; Newer = ($v -gt [version]$MigToolVersion) }
}

# Leftovers of the retired "Open Transfer Share" window (share KitMigrate$, firewall rules, token policy; state.json).
function Stop-LegacyTransferShare {
    $sf = Join-Path $env:ProgramData 'KitMigrate\state.json'
    if (-not (Test-Path $sf)) { return }
    $s = Get-Content $sf -Raw | ConvertFrom-Json
    Remove-SmbShare -Name 'KitMigrate$' -Force -ErrorAction SilentlyContinue
    foreach ($n in @($s.FirewallEnabled)) { if ($n) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue } }
    if ($s.TokenPolicySet) {
        if ($null -eq $s.TokenPolicyOld) { Remove-ItemProperty $PairPolicyKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $PairPolicyKey -Name LocalAccountTokenFilterPolicy -Value ([int]$s.TokenPolicyOld) -Type DWord }
    }
    if ($s.ServerStarted) { Stop-Service LanmanServer -Force -ErrorAction SilentlyContinue }
    [IO.File]::Delete($sf)
    'Old transfer share removed (from the retired Open Transfer Share window).'
}

# Start-up safety net while a cable link is set up: task $CableCleanupTask (SYSTEM, at boot) undoes the pairing login,
# sharing change and cable address even if the tool was killed - no admin password needed offline. Runs from
# <drive>\$MigToolRel\cable (copied there, since the flash drive may be gone). Removed when the link ends cleanly.
function Register-CableCleanup {
    $tool = Join-Path $env:SystemDrive "$MigToolRel\cable"   # own folder: doesn't touch an installed (maybe older) tool
    New-Item -ItemType Directory -Force $tool | Out-Null
    foreach ($f in 'MigrateCore.ps1', 'CableCleanup.ps1') {
        $mine = Join-Path $MigCoreDir $f; $theirs = Join-Path $tool $f
        if ($mine -ne $theirs -and ((-not (Test-Path $theirs)) -or (Get-FileHash $mine).Hash -ne (Get-FileHash $theirs).Hash)) { Copy-Item $mine $theirs -Force }
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tool\CableCleanup.ps1`""
    Register-ScheduledTask -TaskName $CableCleanupTask -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) -Force -ErrorAction Stop | Out-Null
}
function Unregister-CableCleanup { foreach ($t in @($CableCleanupTask, 'MigrateUserFiles-CableCleanup')) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } }

# The other PC's computer name over a bare cable (no DNS): reverse lookup, then NetBIOS.
# Cached: each lookup can take seconds over a bare cable, and connecting retries often.
$script:RemoteNames = @{}
function Get-RemoteName([string]$Ip) {
    if ($script:RemoteNames.ContainsKey($Ip)) { return $script:RemoteNames[$Ip] }
    $n = $null
    try { $h = ([Net.Dns]::GetHostEntry($Ip).HostName -split '\.')[0]; if ($h -and $h -ne $Ip) { $n = $h.ToUpper() } } catch {}
    if (-not $n) { foreach ($l in @(& nbtstat.exe -A $Ip 2>$null)) { if ($l -match '^\s*(\S+)\s+<00>\s+UNIQUE') { $n = $Matches[1]; break } } }
    if ($n) { $script:RemoteNames[$Ip] = $n }   # only cache a real answer (the other PC may not be up yet)
    $n
}

# ---------- Handoff: files waiting in C:\Migration\<folder> move into the user's profile at THAT user's next sign-in ----------
# One entry per user: <Root>\$MigToolRel\handoff\<user>.json (admin-only folder, so nobody can add entries).
# Task $HandoffTask (SYSTEM, at every sign-in) runs Complete-MigrationHandoff.ps1 from that folder; it handles each
# user when they sign in and removes itself when no entries are left. Any number of users; delete C:\Migration\<user> to drop one.
$MigCoreDir = $PSScriptRoot
function Get-HandoffUser([string]$Name) { (($Name -split '\\')[-1] -split '\.')[0].Trim() }   # DOMAIN\jsmith / jsmith.DOMAIN -> jsmith

# $DstRoot = 'C:' (this PC) or '\\PC\C$' (then $RemotePc + optional $Credential register the task over WMI/DCOM).
# Throws if the task can't be registered; the entry and files stay, and Set-MigrationHandoff.ps1 on that PC finishes it.
# -Ask: at sign-in the user is asked (Ask-MigrationChoice.ps1, runs as them) whether to place the files in the same
# locations or in Desktop\<BackupName>; the files must have been staged with the 'Same' layout. -Message: the question text.
function Add-MigrationHandoff {
    param([string]$DstRoot, [string]$User, [string]$Folder, [string]$SourcePc = '', [string]$RemotePc, [pscredential]$Credential,
          [switch]$Ask, [string]$Message = $MigAskMessage, [string]$BackupName = $MigBackupName)
    $User = Get-HandoffUser $User
    if (-not $Folder) { $Folder = $User }
    if ($User -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw "Invalid user name '$User'." }
    if ($Folder -notmatch '^[A-Za-z0-9._ -]{1,64}$' -or $Folder -match '\.\.') { throw "Invalid folder name '$Folder'." }
    $tool = Join-Path $DstRoot $MigToolRel
    New-Item -ItemType Directory -Force (Join-Path $tool 'handoff') | Out-Null
    # The mover must live on that PC (not on a flash drive that will be unplugged)
    New-Item -ItemType Directory -Force (Join-Path $tool 'scripts') | Out-Null
    foreach ($f in 'Complete-MigrationHandoff.ps1', 'Ask-MigrationChoice.ps1') {
        $mine = Join-Path $MigCoreDir $f; $theirs = Join-Path $tool "scripts\$f"
        if (-not (Test-Path -LiteralPath $theirs) -or (Get-FileHash -LiteralPath $mine).Hash -ne (Get-FileHash -LiteralPath $theirs).Hash) { Copy-Item -LiteralPath $mine $theirs -Force }
    }
    $BackupName = ($BackupName -replace '[\\/:*?"<>|]', '').Trim(); if (-not $BackupName) { $BackupName = $MigBackupName }
    [ordered]@{ User = $User; Folder = $Folder; SourcePc = $SourcePc; Created = (Get-Date).ToString('s')
        Ask = [bool]$Ask; Message = $Message; BackupName = $BackupName } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $tool "handoff\$User.json") -Encoding UTF8
    if ($Ask) {
        # Answers folder: users may create their <user>.txt here (SYSTEM only accepts 'Same' or 'Backup' from it)
        $ch = Join-Path $DstRoot $MigChoiceRel
        New-Item -ItemType Directory -Force $ch | Out-Null
        try {
            $di = New-Object IO.DirectoryInfo $ch
            $acl = $di.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            $di.SetAccessControl($acl)
        } catch { Write-Warning "Could not open $ch for users' answers: $($_.Exception.Message)" }
        Remove-Item -LiteralPath (Join-Path $ch "$User.txt") -Force -ErrorAction SilentlyContinue   # fresh question
    }
    # C:\Migration: admins + SYSTEM only, so another user can't plant files or a junction for SYSTEM to move
    $mig = Join-Path $DstRoot 'Migration'
    try {
        # DACL only (Set-Acl/Get-Acl also touch the audit list, which needs SeSecurityPrivilege)
        $di = New-Object IO.DirectoryInfo $mig
        $acl = $di.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($a in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRule($a) }
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        $di.SetAccessControl($acl)
    } catch { Write-Warning "Could not lock $mig to admins: $($_.Exception.Message)" }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\$MigToolRel\scripts\Complete-MigrationHandoff.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    # The question window runs as the signed-in user (any member of Users), not as SYSTEM, so it can show on their screen
    $askAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\$MigToolRel\scripts\Ask-MigrationChoice.ps1`""
    $askPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $cimArgs = @{}
    if ($RemotePc) {
        $p = @{ ComputerName = $RemotePc; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        $cimArgs.CimSession = New-CimSession @p
    }
    try {
        Register-ScheduledTask @cimArgs -TaskName $HandoffTask -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        if ($Ask) { Register-ScheduledTask @cimArgs -TaskName $AskTask -Action $askAction -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $askPrincipal -Force -ErrorAction Stop | Out-Null }
    } finally { if ($cimArgs.CimSession) { Remove-CimSession $cimArgs.CimSession } }
}

# Pending entries on a PC ('C:' or '\\PC\C$').
function Get-MigrationHandoff([string]$Root) {
    @($MigToolRel, $MigLegacyToolRel) | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $Root "$_\handoff") -Filter '*.json' -ErrorAction SilentlyContinue } |
        ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} }
}
