<#
  DayLenGitHub.ps1 - Tu dong tinh SHA-256, cap nhat manifest.json va day ban cap nhat len GitHub.
  Repo: https://github.com/ntsingle/Update.git
#>
param(
    [string]$Message = ''
)
$ErrorActionPreference = 'Stop'
$upd = $PSScriptRoot
$repoUrl = 'https://github.com/ntsingle/Update.git'

Write-Host '============================================================'
Write-Host '  DONG BO & DAY BAN CAP NHAT LEN GITHUB'
Write-Host "  Repo: $repoUrl"
Write-Host '============================================================'

# 1. Tim tat ca thu muc goi cap nhat vX.Y.Z
$pkgs = @(Get-ChildItem -LiteralPath $upd -Directory | Where-Object {
        $_.Name -match '^v(\d+)\.(\d+)\.(\d+)' -and (Test-Path (Join-Path $_.FullName 'files')) } |
    Sort-Object { $null = $_.Name -match '^v(\d+)\.(\d+)\.(\d+)'; [int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000 + [int]$Matches[3] })

if (-not $pkgs.Count) {
    Write-Host 'Khong tim thay thu muc goi cap nhat nao (dang vX.Y.Z co thu muc files\).'
    exit 1
}

# 2. Tinh lai SHA256SUMS.txt cho moi goi de bao dam khong bao gio lech hash
foreach ($p in $pkgs) {
    $filesRoot = Join-Path $p.FullName 'files'
    $allFiles = @(Get-ChildItem -LiteralPath $filesRoot -File -Recurse | Sort-Object FullName)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($filesRoot.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        $lines.Add("$hash  $rel")
    }
    $sumsPath = Join-Path $p.FullName 'SHA256SUMS.txt'
    [IO.File]::WriteAllLines($sumsPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  [OK] $($p.Name): $($allFiles.Count) file -> da cap nhat SHA256SUMS.txt")
}

# 3. Tao manifest.json
$pkgNames = @($pkgs | ForEach-Object { $_.Name })
$latestPkg = $pkgNames[-1]
$manifestObj = [ordered]@{
    latest = $latestPkg
    updatedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    packages = $pkgNames
}
$manifestJson = $manifestObj | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $upd 'manifest.json'), $manifestJson + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  [OK] Da tao manifest.json (latest: $latestPkg)"

# 4. Khoi tao git & day len GitHub
Push-Location $upd
try {
    if (-not (Test-Path -LiteralPath (Join-Path $upd '.git'))) {
        git init -b main | Out-Null
        git remote add origin $repoUrl
    }
    else {
        $curOrigin = (git remote get-url origin 2>$null)
        if ($curOrigin -ne $repoUrl) {
            git remote set-url origin $repoUrl
        }
    }

    git add -A
    $status = git status --porcelain
    if (-not $status) {
        Write-Host 'Khong co thay doi moi can day len GitHub.'
    }
    else {
        if (-not $Message) {
            $Message = "Cap nhat $latestPkg ($(Get-Date -Format 'dd/MM/yyyy HH:mm'))"
        }
        git commit -m $Message
    }

    Write-Host 'Dang day len GitHub (branch main)...'
    git push -u origin main
    Write-Host ''
    Write-Host 'HOAN TAT! Ban cap nhat da co mat tren GitHub.'
    Write-Host "Nguoi choi mo Launcher se tu dong kiem tra va tai tu: https://github.com/ntsingle/Update"
}
finally {
    Pop-Location
}
