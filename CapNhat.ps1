<#
  CapNhat.ps1 - Trình cập nhật Phong Thần (hỗ trợ cập nhật từ xa qua GitHub + dự phòng ngoại tuyến).
    -Part All | Client | Server     phần được cài (file ngoài Client\ thuộc phía Server)
    -Only <tên gói>                 chỉ cài một gói
    -Yes                            không hỏi lại
    -CheckOnly                      chỉ kiểm tra có file cần cập nhật, không ghi vào runtime
    -StatusFile <đường dẫn>         ghi tiến độ cho Launcher đọc
    -RemoteUrl <url>                URL raw GitHub (mặc định: https://raw.githubusercontent.com/ntsingle/Update/main)
    -LocalOnly                      bỏ qua kiểm tra GitHub, chỉ dùng gói có sẵn trong thư mục Update\
#>
param(
    [string]$Target,
    [ValidateSet('All', 'Client', 'Server')][string]$Part = 'All',
    [string]$Only,
    [switch]$Yes,
    [switch]$CheckOnly,
    [string]$StatusFile,
    [int]$LauncherProcessId = 0,
    [string]$RemoteUrl = 'https://raw.githubusercontent.com/ntsingle/Update/main',
    [switch]$LocalOnly
)
$ErrorActionPreference = 'Stop'
$upd = $PSScriptRoot

# Cho phép ghi đè URL từ file Update\update_url.txt nếu có
$urlConfigFile = Join-Path $upd 'update_url.txt'
if (-not $PSBoundParameters.ContainsKey('RemoteUrl') -and (Test-Path -LiteralPath $urlConfigFile)) {
    $customUrl = ([IO.File]::ReadAllText($urlConfigFile, [Text.Encoding]::UTF8)).Trim().TrimEnd('/')
    if ($customUrl -match '^https?://') { $RemoteUrl = $customUrl }
}
$RemoteUrl = $RemoteUrl.TrimEnd('/')

# Bật TLS 1.2 để kết nối GitHub ổn định trên mọi máy Windows
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Set-UpdateStatus {
    param([string]$State, [int]$Current = 0, [int]$Total = 0, [string]$Message = '')
    if (-not $StatusFile) { return }
    $safeMessage = $Message.Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ')
    $line = "PTUPDATE|$State|$Current|$Total|$safeMessage"
    for ($i = 0; $i -lt 40; $i++) {
        try { [IO.File]::WriteAllText($StatusFile, $line); return } catch { Start-Sleep -Milliseconds 25 }
    }
}

function Build-RemoteUrl {
    param([string]$RelPath)
    $segments = $RelPath.Replace('\', '/').Split('/') | Where-Object { $_ -ne '' } | ForEach-Object { [Uri]::EscapeDataString($_) }
    $bust = [DateTime]::UtcNow.Ticks
    return "$RemoteUrl/" + ($segments -join '/') + "?t=$bust"
}

function Download-RemoteString {
    param([string]$RelPath, [int]$TimeoutMs = 12000)
    $url = Build-RemoteUrl $RelPath
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.UserAgent = 'PhongThan-Launcher/1.5'
    $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    $resp = $req.GetResponse()
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    finally { $resp.Close() }
}

function Download-RemoteFile {
    param([string]$RelPath, [string]$DestPath, [string]$ExpectedHash = '', [int]$TimeoutMs = 60000)
    $url = Build-RemoteUrl $RelPath
    $destDir = Split-Path -Parent $DestPath
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    $tmp = $DestPath + '.downloading'
    $lastErr = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            $req = [Net.HttpWebRequest]::Create($url)
            $req.Method = 'GET'
            $req.Timeout = $TimeoutMs
            $req.ReadWriteTimeout = $TimeoutMs
            $req.UserAgent = 'PhongThan-Launcher/1.5'
            $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
            $resp = $req.GetResponse()
            try {
                $inStream = $resp.GetResponseStream()
                $outStream = [IO.File]::Create($tmp)
                try {
                    $buf = New-Object byte[] 65536
                    while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $outStream.Write($buf, 0, $read)
                    }
                }
                finally { $outStream.Dispose(); $inStream.Dispose() }
            }
            finally { $resp.Close() }

            if ($ExpectedHash) {
                $actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
                if ($actual -ne $ExpectedHash) {
                    throw "SHA-256 khong khop sau khi tai ($RelPath): $actual != $ExpectedHash"
                }
            }
            if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force }
            Move-Item -LiteralPath $tmp -Destination $DestPath -Force
            return
        }
        catch {
            $lastErr = $_
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (600 * $attempt) }
        }
    }
    throw "Khong tai duoc $RelPath tu GitHub: $($lastErr.Exception.Message)"
}

$statusCurrent = 0
$statusTotal = 0
trap {
    Set-UpdateStatus 'ERROR' $statusCurrent $statusTotal $_.Exception.Message
    Write-Error $_
    exit 1
}

Set-UpdateStatus 'CHECKING' 0 0 'Dang kiem tra phien ban cap nhat...'
if (-not $Target) { $Target = Join-Path $upd '..' }   # <root> (Update -> root)
$Target = [IO.Path]::GetFullPath($Target)
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Set-UpdateStatus 'ERROR' 0 0 "Khong tim thay runtime: $Target"
    Write-Host "Khong tim thay runtime: $Target"
    exit 1
}

# ---- Dong bo metadata (manifest.json, SHA256SUMS.txt, NOI_DUNG_UPDATE.txt, XOA_FILE.txt) tu GitHub
$remoteOnline = $false
$remotePackages = @()
if (-not $LocalOnly -and $RemoteUrl) {
    try {
        Set-UpdateStatus 'CHECKING' 0 0 'Dang ket noi may chu cap nhat GitHub...'
        $manifestJson = Download-RemoteString 'manifest.json' 10000
        $manifest = $manifestJson | ConvertFrom-Json
        if ($manifest -and $manifest.packages) {
            $remoteOnline = $true
            $remotePackages = @($manifest.packages)
            foreach ($pkgName in $remotePackages) {
                if (-not $pkgName -or $pkgName -notmatch '^v(\d+)\.(\d+)\.(\d+)') { continue }
                $pkgDir = Join-Path $upd $pkgName
                if (-not (Test-Path -LiteralPath $pkgDir)) {
                    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
                }
                # Tai SHA256SUMS.txt (bat buoc)
                $sumsText = Download-RemoteString "$pkgName/SHA256SUMS.txt" 10000
                [IO.File]::WriteAllText((Join-Path $pkgDir 'SHA256SUMS.txt'), $sumsText, [Text.Encoding]::UTF8)

                # Tai NOI_DUNG_UPDATE.txt (neu co - de Launcher hien thi thong bao moi nhat)
                try {
                    $notesText = Download-RemoteString "$pkgName/NOI_DUNG_UPDATE.txt" 8000
                    [IO.File]::WriteAllText((Join-Path $pkgDir 'NOI_DUNG_UPDATE.txt'), $notesText, [Text.Encoding]::UTF8)
                } catch {}

                # Tai XOA_FILE.txt (neu co)
                try {
                    $delText = Download-RemoteString "$pkgName/XOA_FILE.txt" 8000
                    [IO.File]::WriteAllText((Join-Path $pkgDir 'XOA_FILE.txt'), $delText, [Text.Encoding]::UTF8)
                } catch {}
            }
            Write-Host "Da dong bo danh sach cap nhat tu GitHub ($($remotePackages.Count) goi)."
        }
    }
    catch {
        Write-Host "Khong ket noi duoc GitHub ($($_.Exception.Message)) -> dung goi cuc bo."
    }
}

# ---- goi cap nhat, cu truoc moi sau (so sanh theo so phien ban, khong theo chu)
$pkgs = @(Get-ChildItem -LiteralPath $upd -Directory | Where-Object {
        $_.Name -match '^v(\d+)\.(\d+)\.(\d+)' -and (Test-Path (Join-Path $_.FullName 'SHA256SUMS.txt')) } |
    Sort-Object { $null = $_.Name -match '^v(\d+)\.(\d+)\.(\d+)'; [int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000 + [int]$Matches[3] })
if ($Only) { $pkgs = @($pkgs | Where-Object { $_.Name -eq $Only }) }
if (-not $pkgs.Count) {
    Set-UpdateStatus 'ERROR' 0 0 'Khong co goi cap nhat nao.'
    Write-Host 'Khong co goi cap nhat nao.'
    exit 1
}

# ---- gop: duong dan -> ban cua goi moi nhat
$win = @{}
$del = @{}
foreach ($p in $pkgs) {
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $p.FullName 'SHA256SUMS.txt'), [Text.Encoding]::UTF8)) {
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s+[*]?(\S.*)$') { continue }
        $rel = $Matches[2].Replace('/', '\')
        $isClient = $rel.StartsWith('Client\', [StringComparison]::OrdinalIgnoreCase)
        if (($Part -eq 'Client' -and -not $isClient) -or ($Part -eq 'Server' -and $isClient)) { continue }
        $win[$rel] = @{
            Hash = $Matches[1].ToUpper()
            Src = Join-Path (Join-Path $p.FullName 'files') $rel
            RemoteRel = "$($p.Name)/files/$($rel.Replace('\', '/'))"
            Pkg = $p.Name
        }
        $null = $del.Remove($rel)
    }
    $delFile = Join-Path $p.FullName 'XOA_FILE.txt'
    if (Test-Path -LiteralPath $delFile) {
        foreach ($line in [IO.File]::ReadAllLines($delFile, [Text.Encoding]::UTF8)) {
            $rel = $line.Trim().Replace('/', '\').TrimEnd('\')
            if (-not $rel -or $rel.StartsWith('#')) { continue }
            if ($rel -notmatch '^(Client|Server)\\.+' -or $rel -match '(^|\\)\.\.(\\|$)') { continue }
            $isClient = $rel.StartsWith('Client\', [StringComparison]::OrdinalIgnoreCase)
            if (($Part -eq 'Client' -and -not $isClient) -or ($Part -eq 'Server' -and $isClient)) { continue }
            $del[$rel] = $p.Name
            foreach ($k in @($win.Keys)) {
                if ($k -ieq $rel -or $k.StartsWith($rel + '\', [StringComparison]::OrdinalIgnoreCase)) { $win.Remove($k) }
            }
        }
    }
}

Write-Host '============================================================'
Write-Host (" Goi: " + (($pkgs | ForEach-Object { $_.Name -replace ' .*$', '' }) -join ', ') + $(if ($remoteOnline) { ' [GitHub]' } else { ' [Local]' }))
Write-Host " Phan: $Part    Runtime: $Target"
Write-Host '------------------------- XEM TRUOC ------------------------'
$todo = New-Object System.Collections.Generic.List[object]
$same = 0
foreach ($rel in ($win.Keys | Sort-Object)) {
    $w = $win[$rel]
    $dst = Join-Path $Target $rel
    $exists = Test-Path -LiteralPath $dst
    $caseRename = $false
    if ($exists) {
        $di = Get-Item -LiteralPath $dst
        $expectedName = [IO.Path]::GetFileName($rel)
        $caseRename = -not [string]::Equals($di.Name, $expectedName, [StringComparison]::Ordinal)
        if (-not $caseRename) {
            # Fast path neu file nguon da co san cuc bo va trung kich thuoc + thoi gian
            $fastMatch = $false
            if (Test-Path -LiteralPath $w.Src) {
                $si = Get-Item -LiteralPath $w.Src
                if ($di.Length -eq $si.Length -and $di.LastWriteTimeUtc -eq $si.LastWriteTimeUtc) {
                    $fastMatch = $true
                }
            }
            if ($fastMatch -or ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -eq $w.Hash)) {
                $same++
                continue
            }
        }
    }
    $tag = if ($caseRename) { '[TEN ]' } elseif ($exists) { '[THAY]' } else { '[MOI] ' }
    Write-Host ("  $tag $rel   <- " + ($w.Pkg -replace ' .*$', ''))
    $todo.Add(@{ Rel = $rel; Dst = $dst; Exists = $exists; CaseRename = $caseRename; W = $w })
}
$delTodo = @($del.Keys | Sort-Object | Where-Object { Test-Path -LiteralPath (Join-Path $Target $_) })
foreach ($rel in $delTodo) { Write-Host "  [XOA]  $rel   <- $($del[$rel] -replace ' .*$', '')" }
Write-Host "  => $($todo.Count) file can cap nhat, $($delTodo.Count) muc can xoa, $same file da dung phien ban."

# ---- pham vi: phan nao bi anh huong -> chi dung dung tien trinh can dung
$scope = @{}
foreach ($rel in @(@($todo | ForEach-Object { $_.Rel }) + $delTodo)) {
    if (-not $rel) { continue }
    if ($rel -ieq 'Client\PhongThan.exe' -or $rel -like 'Client\Launcher\*' -or $rel -ieq 'Client\Launcher') { $scope['launcher'] = 1 }
    elseif ($rel -like 'Client\*') { $scope['client'] = 1 }
    elseif ($rel -like 'Server\*') { $scope['server'] = 1 }
    elseif ($rel -like 'Tools\Studio\*') { $scope['studio'] = 1 }
    else { $scope['other'] = 1 }
}
$scopeText = (@($scope.Keys) | Sort-Object) -join ','
Write-Host "  Pham vi: $scopeText"
if ($CheckOnly) {
    if ($todo.Count -or $delTodo.Count) {
        Set-UpdateStatus 'CHECK_AVAILABLE' 0 ($todo.Count + $delTodo.Count) ("Co $($todo.Count + $delTodo.Count) muc can cap nhat. [scope=$scopeText]")
    }
    else {
        Set-UpdateStatus 'CHECK_CURRENT' 0 0 'Game da o phien ban moi nhat.'
    }
    exit 0
}

if (-not $todo.Count -and -not $delTodo.Count) {
    $last = $pkgs[-1].Name -replace ' .*$', ''
    Write-Host "Runtime DA CO DAY DU cac goi den $last ($Part) - khong can chep them file nao."
    Set-UpdateStatus 'DONE' 1 1 'Game da o phien ban moi nhat.'
    exit 0
}

# ---- tien trinh dang chay tu chinh runtime nay
$names = @()
if ($Part -ne 'Server' -and $scope['client']) { $names += 'Game' }
if ($Part -ne 'Client' -and $scope['server']) { $names += 'GameServer', 'Goddess', 'Bishop', 'PhongThanRelay', 'PhongThanAccountServer' }
if (-not $names.Count) { $names = @('__khong_co__') }
$running = @(Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object {
        -not $_.Path -or $_.Path.StartsWith($Target, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count) {
    $runningNames = ($running | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join ', '
    Set-UpdateStatus 'ERROR' 0 $todo.Count "Hay tat tien trinh dang chay truoc khi cap nhat: $runningNames"
    Write-Host ("Dang chay: " + $runningNames)
    Write-Host 'Hay tat truoc khi cap nhat.'
    exit 1
}
$launcherProcess = $null
$launcherIsRunning = $false
if ($LauncherProcessId -gt 0) {
    $launcherProcess = Get-Process -Id $LauncherProcessId -ErrorAction SilentlyContinue
    $launcherPath = Join-Path $Target 'Client\PhongThan.exe'
    $launcherIsRunning = $launcherProcess -and
        $launcherProcess.ProcessName -ieq 'PhongThan' -and
        (-not $launcherProcess.Path -or $launcherProcess.Path.Equals($launcherPath, [StringComparison]::OrdinalIgnoreCase))
}

if (-not $Yes) {
    $ok = Read-Host 'Cai that? (Y/N)'
    if ($ok -notmatch '^[Yy]') {
        Set-UpdateStatus 'CANCELLED' 0 $todo.Count 'Da huy cap nhat.'
        Write-Host 'Da huy, khong cai gi.'
        exit 0
    }
}

# ---- tai (neu can), kiem hash, sao luu, chep, kiem lai
$bkRoot = Join-Path (Split-Path $upd -Parent) 'Tool\Admin\Backups\cap_nhat'
if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $upd -Parent) 'Tool\Admin'))) { $bkRoot = Join-Path $upd 'Backups' }
Get-ChildItem -LiteralPath $bkRoot -Directory -Filter 'capnhat_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 4 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$backup = Join-Path $bkRoot ('capnhat_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$n = 0
$statusCurrent = 0
$statusTotal = $todo.Count
$launcherStaged = $false
Set-UpdateStatus 'PROGRESS' 0 $todo.Count 'Dang chuan bi cap nhat...'
foreach ($t in $todo) {
    # Kiem tra file cuc bo co san va dung SHA-256 chua; neu chua thi tai tu GitHub
    $needDownload = $true
    if (Test-Path -LiteralPath $t.W.Src) {
        if ((Get-FileHash -LiteralPath $t.W.Src -Algorithm SHA256).Hash -eq $t.W.Hash) {
            $needDownload = $false
        }
    }
    if ($needDownload) {
        if ($LocalOnly -or -not $RemoteUrl) {
            $message = "Thieu hoac hong goi cuc bo: $($t.W.Pkg)\files\$($t.Rel)"
            Set-UpdateStatus 'ERROR' $n $todo.Count $message
            Write-Host $message
            exit 1
        }
        Set-UpdateStatus 'PROGRESS' $n $todo.Count ("Dang tai file {0}/{1}: {2}" -f ($n + 1), $todo.Count, $t.Rel)
        Write-Host ("  [TAI ] $($t.Rel) ...")
        Download-RemoteFile -RelPath $t.W.RemoteRel -DestPath $t.W.Src -ExpectedHash $t.W.Hash
    }

    if ((Get-FileHash -LiteralPath $t.W.Src -Algorithm SHA256).Hash -ne $t.W.Hash) {
        $message = "Goi hong: $($t.W.Pkg)\files\$($t.Rel)"
        Set-UpdateStatus 'ERROR' $n $todo.Count $message
        Write-Host $message
        exit 1
    }
    if ($t.Exists) {
        $b = Join-Path $backup $t.Rel
        New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
        Copy-Item -LiteralPath $t.Dst -Destination $b -Force
    }
    if ($launcherIsRunning -and $t.Rel.Equals('Client\PhongThan.exe', [StringComparison]::OrdinalIgnoreCase)) {
        Set-UpdateStatus 'APPLYING' $n $todo.Count ("Dang chuan bi cap nhat Launcher ({0}/{1})." -f ($n + 1), $todo.Count)
        $stagedExe = Join-Path $Target 'Client\PhongThan.exe.update'
        Copy-Item -LiteralPath $t.W.Src -Destination $stagedExe -Force
        if ((Get-FileHash -LiteralPath $stagedExe -Algorithm SHA256).Hash -ne $t.W.Hash) {
            $message = 'Khong the xac minh ban Launcher da chuan bi.'
            Set-UpdateStatus 'ERROR' $n $todo.Count $message
            Write-Host $message
            exit 1
        }
        [IO.File]::WriteAllText(($stagedExe + '.sha256'), $t.W.Hash)
        $launcherStaged = $true
        $n++
        $statusCurrent = $n
        Set-UpdateStatus 'PROGRESS' $n $todo.Count ("Da chuan bi {0}/{1} file." -f $n, $todo.Count)
        continue
    }

    Set-UpdateStatus 'APPLYING' $n $todo.Count ("Dang cap nhat file {0}/{1}: {2}" -f ($n + 1), $todo.Count, $t.Rel)
    New-Item -ItemType Directory -Force (Split-Path $t.Dst) | Out-Null
    $caseTemp = $null
    if ($t.CaseRename) {
        $caseTemp = Join-Path (Split-Path -Parent $t.Dst) ('.rename-case-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Move-Item -LiteralPath $t.Dst -Destination $caseTemp
    }
    try {
        Copy-Item -LiteralPath $t.W.Src -Destination $t.Dst -Force
        if ((Get-FileHash -LiteralPath $t.Dst -Algorithm SHA256).Hash -ne $t.W.Hash) {
            throw "Chep loi (hash khong khop): $($t.Dst)"
        }
        if ($caseTemp) { Remove-Item -LiteralPath $caseTemp -Force }
        if ($t.Rel -ieq 'Server\SuDo2008Startup.ini') {
            $realSudo = [IO.Path]::GetFullPath((Join-Path $Target 'Server\RuntimeData\SuDo2008'))
            New-Item -ItemType Directory -Force -Path $realSudo | Out-Null
            $text = [IO.File]::ReadAllText($t.Dst)
            $text = [regex]::Replace($text, '(?im)^LedgerPath=.*$', "LedgerPath=$realSudo")
            [IO.File]::WriteAllText($t.Dst, $text, [Text.Encoding]::ASCII)
        }
    }
    catch {
        if (Test-Path -LiteralPath $t.Dst) { Remove-Item -LiteralPath $t.Dst -Force }
        if ($caseTemp -and (Test-Path -LiteralPath $caseTemp)) { Move-Item -LiteralPath $caseTemp -Destination $t.Dst }
        $message = "Chep loi: $($t.Dst) - $($_.Exception.Message)"
        Set-UpdateStatus 'ERROR' $n $todo.Count $message
        Write-Host $message
        exit 1
    }
    $n++
    $statusCurrent = $n
    Set-UpdateStatus 'PROGRESS' $n $todo.Count ("Da cap nhat {0}/{1} file." -f $n, $todo.Count)
}

# ---- xoa: sao luu truoc, roi xoa
foreach ($rel in $delTodo) {
    $dst = Join-Path $Target $rel
    $b = Join-Path $backup $rel
    New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
    Copy-Item -LiteralPath $dst -Destination $b -Recurse -Force
    Remove-Item -LiteralPath $dst -Recurse -Force
    Write-Host "  da xoa: $rel"
}

Write-Host "DA CAI: $n file, xoa $($delTodo.Count) muc."
if (Test-Path $backup) { Write-Host "Ban cu luu o: $backup" }
if ($launcherStaged) {
    Set-UpdateStatus 'RESTART_REQUIRED' $n $todo.Count "Cap nhat xong. Launcher se khoi dong lai. [scope=$scopeText]"
}
else {
    Set-UpdateStatus 'DONE' $n $todo.Count "Cap nhat hoan tat. [scope=$scopeText]"
}
exit 0
