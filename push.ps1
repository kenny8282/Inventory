# push.ps1 â€” sync files from OneDrive working folder to the git repo, commit, push.
# Usage:
#   .\push.ps1 -Message "v1.11.0: my change"
#   .\push.ps1 -Message "..." -DryRun        (preview without committing)
#   .\push.ps1 -Message "..." -NoPush        (commit locally but don't push)

param(
    [Parameter(Mandatory=$true)][string]$Message,
    [switch]$DryRun,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

# Source = OneDrive working folder (where files land from Downloads).
# Repo   = git working tree (this script's folder).
$src  = "$env:USERPROFILE\OneDrive\Projects\Gridfinity"
$repo = $PSScriptRoot

if (-not (Test-Path $src)) {
    Write-Host "Source folder not found: $src" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==> Syncing files from OneDrive -> repo" -ForegroundColor Cyan
Write-Host "    src:  $src"
Write-Host "    repo: $repo"
Write-Host ""

# Map: working-folder filename -> repo destination
# These are the "ship to GitHub" canonical paths. Adjust if your repo layout changes.
$mappings = @(
    @{ Src = "gridfinity_backend.py";              Dst = "backend\gridfinity_backend.py" }
    @{ Src = "index.html";                         Dst = "frontend\index.html" }
    @{ Src = "gridfinity-label-forge.html";        Dst = "frontend\forge\index.html" }
    @{ Src = "gridfinity-inventory.html";          Dst = "frontend\inventory\index.html" }
    @{ Src = "gridfinity-wifi.html";               Dst = "frontend\wifi\index.html" }
    @{ Src = "install.sh";                         Dst = "install.sh" }
    @{ Src = "update.sh";                          Dst = "update.sh" }
    @{ Src = "wifi-bootstrap.sh";                  Dst = "wifi-bootstrap.sh" }
    @{ Src = "gridfinity-nginx.conf";              Dst = "etc\gridfinity-nginx.conf" }
    @{ Src = "gridfinity-backend.service";         Dst = "etc\gridfinity-backend.service" }
    @{ Src = "gridfinity-wifi-sudoers.template";   Dst = "etc\gridfinity-wifi-sudoers.template" }
    @{ Src = "prepare-sd.ps1";                     Dst = "prepare-sd.ps1" }
    @{ Src = "FRIEND_QUICKSTART.md";               Dst = "FRIEND_QUICKSTART.md" }
)

$copied = 0
foreach ($m in $mappings) {
    $sFile = Join-Path $src $m.Src
    $dFile = Join-Path $repo $m.Dst

    if (-not (Test-Path $sFile)) {
        Write-Host "    skip: $($m.Src) (not in OneDrive)" -ForegroundColor DarkGray
        continue
    }

    # Make sure destination folder exists
    $dDir = Split-Path $dFile -Parent
    if (-not (Test-Path $dDir)) { New-Item -ItemType Directory -Force -Path $dDir | Out-Null }

    Copy-Item $sFile $dFile -Force
    Write-Host "    ok:   $($m.Src) -> $($m.Dst)" -ForegroundColor Green
    $copied++
}

# Linux files MUST use LF endings. Force-convert any CRLF that crept in.
$lfFiles = @('install.sh','update.sh','wifi-bootstrap.sh','etc\gridfinity-nginx.conf','etc\gridfinity-backend.service')
foreach ($rel in $lfFiles) {
    $p = Join-Path $repo $rel
    if (Test-Path $p) {
        $c = Get-Content $p -Raw
        $clean = $c -replace "`r`n","`n"
        if ($c -ne $clean) {
            [System.IO.File]::WriteAllText($p, $clean)
            Write-Host "    fix:  $rel (CRLF -> LF)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "==> $copied files copied" -ForegroundColor Cyan
Write-Host ""

Set-Location $repo

# Show what changed
Write-Host "==> Git status" -ForegroundColor Cyan
git status --short
Write-Host ""

if ($DryRun) {
    Write-Host "DryRun: stopping here. No git changes made." -ForegroundColor Yellow
    exit 0
}

# Check if there's anything to commit
$pending = git status --porcelain
if (-not $pending) {
    Write-Host "Nothing to commit. Working tree clean." -ForegroundColor Yellow
    exit 0
}

Write-Host "==> Committing" -ForegroundColor Cyan
git add .
git commit -m $Message

if ($NoPush) {
    Write-Host ""
    Write-Host "Committed locally. NoPush set -- skipping push." -ForegroundColor Yellow
    Write-Host "To push later: git push" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "==> Pushing to GitHub" -ForegroundColor Cyan
git push

Write-Host ""
Write-Host "Done." -ForegroundColor Green
