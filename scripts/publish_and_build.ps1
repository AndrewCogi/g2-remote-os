<#
.SYNOPSIS
    One-click script to push G2RemoteOS to GitHub, run the free macOS GitHub Actions build,
    wait for unit tests + IPA packaging, and download build\G2RemoteOS.ipa locally.
.PARAMETER RepoName
    GitHub repository name to create (default: g2-remote-os).
.PARAMETER Public
    Create a public repository (recommended for unlimited free GitHub Actions macOS minutes).
    Without this flag, creates a private repository (uses free account monthly Actions quota).
#>
param(
    [string]$RepoName = "g2-remote-os",
    [switch]$Public
)

# Use Continue so Windows PowerShell 5.1 does not abort on native CLI stderr output;
# check $LASTEXITCODE explicitly after every command.
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")

Write-Host "=== 1. Checking GitHub CLI login ===" -ForegroundColor Cyan
$null = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub CLI is not logged in. Starting browser login..." -ForegroundColor Yellow
    & gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub login failed or canceled." -ForegroundColor Red
        exit 1
    }
}

$ghUser = (& gh api user --jq ".login" 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or -not $ghUser) {
    Write-Host "Could not determine GitHub username." -ForegroundColor Red
    exit 1
}
Write-Host "Logged in as: $ghUser" -ForegroundColor Green

Write-Host "`n=== 2. Checking Git remote & pushing to GitHub ===" -ForegroundColor Cyan
$remotes = & git remote
if (-not ($remotes -contains "origin")) {
    $visibility = if ($Public) { "--public" } else { "--private" }
    Write-Host "Creating GitHub repo $ghUser/$RepoName ($visibility) and pushing..." -ForegroundColor Yellow
    & gh repo create $RepoName $visibility --source=. --remote=origin --push
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create/push repository." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Remote 'origin' already exists. Pushing latest commits..." -ForegroundColor Yellow
    & git push -u origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "git push failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n=== 3. Waiting for GitHub Actions macOS build ===" -ForegroundColor Cyan
Start-Sleep -Seconds 5
$runId = (& gh run list --workflow "build-ios.yml" --limit 1 --json databaseId --jq ".[0].databaseId" 2>$null).Trim()
if (-not $runId) {
    Write-Host "Triggering workflow manually..." -ForegroundColor Yellow
    & gh workflow run "build-ios.yml"
    Start-Sleep -Seconds 6
    $runId = (& gh run list --workflow "build-ios.yml" --limit 1 --json databaseId --jq ".[0].databaseId" 2>$null).Trim()
}

if (-not $runId) {
    Write-Host "Could not find workflow run ID. Check GitHub Actions tab." -ForegroundColor Red
    exit 1
}

Write-Host "Watching run #$runId (usually takes 3-6 minutes on macos-15)..." -ForegroundColor Yellow
& gh run watch $runId --exit-status
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nBuild failed! Let Antigravity inspect the log via: gh run view $runId --log-failed" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== 4. Downloading G2RemoteOS.ipa ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path ".\build" | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue ".\build\G2RemoteOS.ipa"
& gh run download $runId --name "G2RemoteOS-ipa" --dir ".\build"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to download artifact." -ForegroundColor Red
    exit 1
}

$ipa = Get-Item ".\build\G2RemoteOS.ipa"
Write-Host "`nSUCCESS! Ready for SideStore: $($ipa.FullName) ($([math]::Round($ipa.Length / 1MB, 2)) MB)" -ForegroundColor Green
explorer.exe "/select,$($ipa.FullName)"
