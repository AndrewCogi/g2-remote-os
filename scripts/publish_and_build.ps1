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

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

Write-Host "=== 1. Checking GitHub CLI login ===" -ForegroundColor Cyan
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub CLI is not logged in. Opening browser login..." -ForegroundColor Yellow
    gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw "GitHub login failed or canceled." }
}

$ghUser = (gh api user --jq ".login").Trim()
if (-not $ghUser) { throw "Could not determine GitHub username." }
Write-Host "Logged in as: $ghUser" -ForegroundColor Green

Write-Host "`n=== 2. Checking Git remote & pushing to GitHub ===" -ForegroundColor Cyan
$hasOrigin = (git remote) -contains "origin"
if (-not $hasOrigin) {
    $visibility = if ($Public) { "--public" } else { "--private" }
    Write-Host "Creating GitHub repo $ghUser/$RepoName ($visibility) and pushing..." -ForegroundColor Yellow
    gh repo create $RepoName $visibility --source=. --remote=origin --push
} else {
    Write-Host "Remote 'origin' already exists. Pushing latest commits..." -ForegroundColor Yellow
    git push -u origin main
}

Write-Host "`n=== 3. Waiting for GitHub Actions macOS build ===" -ForegroundColor Cyan
Start-Sleep -Seconds 5
$runId = (gh run list --workflow "build-ios.yml" --limit 1 --json databaseId --jq ".[0].databaseId").Trim()
if (-not $runId) {
    Write-Host "Triggering workflow manually..." -ForegroundColor Yellow
    gh workflow run "build-ios.yml"
    Start-Sleep -Seconds 6
    $runId = (gh run list --workflow "build-ios.yml" --limit 1 --json databaseId --jq ".[0].databaseId").Trim()
}

Write-Host "Watching run #$runId (this usually takes 3-6 minutes on macos-15)..." -ForegroundColor Yellow
gh run watch $runId --exit-status

Write-Host "`n=== 4. Downloading G2RemoteOS.ipa ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path ".\build" | Out-Null
gh run download $runId --name "G2RemoteOS-ipa" --dir ".\build"

$ipa = Get-Item ".\build\G2RemoteOS.ipa"
Write-Host "`nSUCCESS! Ready for SideStore: $($ipa.FullName) ($([math]::Round($ipa.Length / 1MB, 2)) MB)" -ForegroundColor Green
explorer.exe "/select,$($ipa.FullName)"
