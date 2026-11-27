param([string]$Target, [ValidateSet('All','Client','Server')][string]$Part = 'All')
# Install this package into a PhongThan runtime (folder with Server\ and Client\).
# -Part All | Client | Server. Files outside Client\ (Server\, phongthan-manager) belong to the server side.
$ErrorActionPreference = 'Stop'
$pkg = Split-Path -Parent $MyInvocation.MyCommand.Path
$ver = Split-Path -Leaf $pkg
if (-not $Target -or -not (Test-Path $Target)) { Write-Host "Khong tim thay runtime: $Target"; exit 1 }
$procs = @()
if ($Part -ne 'Server') { $procs += 'Game' }
if ($Part -ne 'Client') { $procs += 'GameServer','Goddess','Bishop','PhongThanRelay','PhongThanAccountServer' }
foreach ($p in $procs) {
    if (Get-Process $p -ErrorAction SilentlyContinue) { Write-Host "Hay tat $p truoc khi cap nhat."; exit 1 }
}
$backup = Join-Path $Target ("Backups\update_" + ($ver -replace '[^A-Za-z0-9._-]','_') + "_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$lines = [IO.File]::ReadAllLines((Join-Path $pkg 'SHA256SUMS.txt'), [Text.Encoding]::UTF8)
$copied = 0; $same = 0; $skipped = 0
foreach ($line in $lines) {
    if (-not $line.Trim()) { continue }
    $hash = $line.Substring(0, 64); $rel = $line.Substring(66)
    $isClient = $rel.StartsWith('Client\', [StringComparison]::OrdinalIgnoreCase)
    if (($Part -eq 'Client' -and -not $isClient) -or ($Part -eq 'Server' -and $isClient)) { $skipped++; continue }
    $src = Join-Path (Join-Path $pkg 'files') $rel
    if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne $hash) { Write-Host "Goi hong: $rel"; exit 1 }
    $dst = Join-Path $Target $rel
    if ((Test-Path -LiteralPath $dst) -and (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -eq $hash) { $same++; continue }
    if (Test-Path -LiteralPath $dst) {
        $b = Join-Path $backup $rel
        New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
        Copy-Item -LiteralPath $dst -Destination $b -Force
    }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
    if ($rel -ieq 'Server\SuDo2008Startup.ini') {
        $realSudo = [IO.Path]::GetFullPath((Join-Path $Target 'Server\RuntimeData\SuDo2008'))
        New-Item -ItemType Directory -Force -Path $realSudo | Out-Null
        $text = [IO.File]::ReadAllText($dst)
        $text = [regex]::Replace($text, '(?im)^LedgerPath=.*$', "LedgerPath=$realSudo")
        [IO.File]::WriteAllText($dst, $text, [Text.Encoding]::ASCII)
    }
    $copied++
}
# Xoa file / thu muc theo XOA_FILE.txt
$delFile = Join-Path $pkg 'XOA_FILE.txt'
$deletedCount = 0
if (Test-Path -LiteralPath $delFile) {
    foreach ($line in [IO.File]::ReadAllLines($delFile, [Text.Encoding]::UTF8)) {
        $rel = $line.Trim().Replace('/', '\').TrimEnd('\')
        if (-not $rel -or $rel.StartsWith('#')) { continue }
        if ($rel -notmatch '^(Client|Server)\\.+' -or $rel -match '(^|\\)\.\.(\\|$)') { continue }
        $isClient = $rel.StartsWith('Client\', [StringComparison]::OrdinalIgnoreCase)
        if (($Part -eq 'Client' -and -not $isClient) -or ($Part -eq 'Server' -and $isClient)) { continue }
        $targetPath = Join-Path $Target $rel
        if (Test-Path -LiteralPath $targetPath) {
            $b = Join-Path $backup $rel
            New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
            Copy-Item -LiteralPath $targetPath -Destination $b -Recurse -Force
            Remove-Item -LiteralPath $targetPath -Recurse -Force
            Write-Host "  Da xoa muc cu: $rel"
            $deletedCount++
        }
    }
}
Write-Host "$ver [$Part]: chep $copied file, $same file da giong, xoa $deletedCount muc cu, bo qua $skipped file phan kia."
if ($copied -gt 0) { Write-Host "   Ban cu luu o $backup" }
exit 0
