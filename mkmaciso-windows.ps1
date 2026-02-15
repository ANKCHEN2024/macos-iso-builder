# mkmaciso-windows.ps1
# Windows helper: trigger GitHub Actions to build macOS ISO/DMG and download the result.
# Requires: PowerShell 5.1+ (Windows 10+). Optional: GitHub CLI (gh) for one-click build+download.
# Usage: .\mkmaciso-windows.ps1
#        .\mkmaciso-windows.ps1 -Version Tahoe -Format iso
#        .\mkmaciso-windows.ps1 -Version 15 -Format dmg

param(
    [string]$Version = "",
    [string]$Format = "",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$WorkflowName = "Build Full Installer ISO/DMG image"
$WorkflowFile = "build.yml"

# Version display names (for menu and API)
$VersionList = @(
    @{ Num = "26";  Name = "Tahoe";      Year = "2025" },
    @{ Num = "15";  Name = "Sequoia";    Year = "2024" },
    @{ Num = "14";  Name = "Sonoma";     Year = "2023" },
    @{ Num = "13";  Name = "Ventura";    Year = "2022" },
    @{ Num = "12";  Name = "Monterey";   Year = "2021" },
    @{ Num = "11";  Name = "Big Sur";    Year = "2020" },
    @{ Num = "10.15"; Name = "Catalina"; Year = "2019" },
    @{ Num = "10.14"; Name = "Mojave";   Year = "2018" },
    @{ Num = "10.13"; Name = "High Sierra"; Year = "2017" },
    @{ Num = "10.12"; Name = "Sierra";   Year = "2016" },
    @{ Num = "10.11"; Name = "El Capitan"; Year = "2015" },
    @{ Num = "10.10"; Name = "Yosemite"; Year = "2014" },
    @{ Num = "10.9";  Name = "Mavericks"; Year = "2013" },
    @{ Num = "10.8";  Name = "Mountain Lion"; Year = "2012" },
    @{ Num = "10.7";  Name = "Lion";     Year = "2011" }
)

function Get-ChoiceName {
    param([string]$Num)
    $v = $VersionList | Where-Object { $_.Num -eq $Num }
    if ($v) { return $v.Name }
    return $Num
}

function Get-ChoiceNum {
    param([string]$Name)
    $n = $Name.Trim()
    $v = $VersionList | Where-Object { $_.Name -eq $n }
    if ($v) { return $v.Num }
    return $n
}

function Get-RepoRemote {
    $root = $PSScriptRoot
    if (-not $root) { $root = (Get-Location).Path }
    $gitDir = Join-Path $root ".git"
    if (-not (Test-Path $gitDir)) { return $null }
    $config = Get-Content (Join-Path $gitDir "config") -Raw -ErrorAction SilentlyContinue
    if (-not $config) { return $null }
    if ($config -match 'url\s*=\s*(?:https://github\.com/|git@github\.com:)([^/\s]+)/([^\s/.]+)') {
        return "https://api.github.com/repos/$($Matches[1])/$($Matches[2])"
    }
    return $null
}

function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  mkmaciso - Windows: build macOS installer ISO/DMG via GitHub Actions" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Step 1: Select macOS version" -ForegroundColor White
    Write-Host ""
    $i = 1
    foreach ($v in $VersionList) {
        Write-Host ("  {0,2}. {1,-12} {2,-16} {3}" -f $i, $v.Num, $v.Name, $v.Year)
        $i++
    }
    Write-Host ""
    $choice = Read-Host "  Enter number [1-$($VersionList.Count)] (default 1 = Tahoe)"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $VersionList.Count) {
        Write-Err "Invalid choice."
        exit 1
    }
    $script:SelectedVersion = $VersionList[$idx].Name
    $script:SelectedVersionNum = $VersionList[$idx].Num

    Clear-Host
    Write-Host ""
    Write-Host "  Step 2: Select image format" -ForegroundColor White
    Write-Host "  Selected: $script:SelectedVersion ($script:SelectedVersionNum)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  1. ISO - for virtual machines (Proxmox, QEMU, VMware, VirtualBox)"
    Write-Host "  2. DMG - for USB drive (Rufus on Windows, dd on Linux)"
    Write-Host ""
    $fmt = Read-Host "  Enter 1 or 2 (default 1 = ISO)"
    if ([string]::IsNullOrWhiteSpace($fmt)) { $fmt = "1" }
    if ($fmt -eq "2") { $script:SelectedFormat = "dmg" } else { $script:SelectedFormat = "iso" }

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $script:OutputDir = [Environment]::GetFolderPath("UserProfile")
        $script:OutputDir = Join-Path $script:OutputDir "Downloads"
    } else {
        $script:OutputDir = $OutputDir
    }
    if (-not (Test-Path $script:OutputDir)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }
}

function Invoke-GhWorkflow {
    param([string]$MacosVersion, [string]$ImageFormat)
    $repo = Get-RepoRemote
    if (-not $repo) {
        Write-Warn "Not a git repo or no GitHub remote; using current directory name as repo."
        $repo = "https://api.github.com/repos/LongQT-sea/macos-iso-builder"
    }
    Write-Info "Triggering workflow: $MacosVersion, format: $ImageFormat"
    $body = @{
        ref     = "main"
        inputs  = @{
            macos_version = $MacosVersion
            image_format  = $ImageFormat
        }
    } | ConvertTo-Json
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        Push-Location $PSScriptRoot
        try {
            & gh workflow run $WorkflowFile --ref main -f "macos_version=$MacosVersion" -f "image_format=$ImageFormat"
            if ($LASTEXITCODE -ne 0) {
                Write-Err "gh workflow run failed. Is 'gh auth login' done?"
                return $false
            }
            Write-Info "Workflow triggered ($MacosVersion, $ImageFormat). Waiting for our run to appear..."
            $runId = $null
            $pollTimeout = 90
            $pollElapsed = 0
            while ($pollElapsed -lt $pollTimeout) {
                Start-Sleep -Seconds 5
                $pollElapsed += 5
                $runsJson = & gh run list --workflow $WorkflowFile --limit 10 --json databaseId,status,createdAt 2>$null
                $runs = $runsJson | ConvertFrom-Json
                if ($runs -isnot [Array]) { $runs = @($runs) }
                $candidates = $runs | Where-Object { $_.status -eq "queued" -or $_.status -eq "in_progress" }
                if ($candidates) {
                    $newest = $candidates | Sort-Object -Property createdAt -Descending | Select-Object -First 1
                    $runId = $newest.databaseId
                }
                if ($runId) { break }
                Write-Host "  ... waiting for run to appear ($pollElapsed s)"
            }
            if (-not $runId) {
                Write-Err "Could not find the run we just started. Please download from Actions page manually."
                return $false
            }
            Write-Info "Tracking run ID: $runId (requested: $MacosVersion, $ImageFormat)"
            Write-Info "Workflow started. Waiting for run to complete (may take 10-60 minutes)..."
            $maxWait = 7200
            $step = 30
            $elapsed = 0
            while ($elapsed -lt $maxWait) {
                Start-Sleep -Seconds $step
                $elapsed += $step
                $r = & gh run view $runId --json status,conclusion -q "."
                if ($r.status -eq "completed") {
                    if ($r.conclusion -eq "success") {
                        Write-Info "Run succeeded. Downloading artifact..."
                        $outDir = $script:OutputDir
                        & gh run download $runId -D $outDir
                        if ($LASTEXITCODE -eq 0) {
                            Write-Info "Downloaded to: $outDir"
                            return $true
                        }
                    } else {
                        Write-Err "Run finished with: $($r.conclusion)"
                    }
                    return $false
                }
                Write-Host "  ... still running ($elapsed s)"
            }
            Write-Err "Timeout waiting for workflow."
            return $false
        } finally {
            Pop-Location
        }
    } else {
        Write-Warn "GitHub CLI (gh) not found."
        Write-Host ""
        Write-Host "  Option A: Install GitHub CLI, then run this script again:" -ForegroundColor Yellow
        Write-Host "    winget install GitHub.cli"
        Write-Host "    gh auth login"
        Write-Host ""
        Write-Host "  Option B: Trigger and download manually:" -ForegroundColor Yellow
        Write-Host "    1. Open: https://github.com/LongQT-sea/macos-iso-builder/actions"
        Write-Host "    2. Click 'Build Full Installer ISO/DMG image' -> Run workflow"
        Write-Host "    3. Select macOS: $MacosVersion, Format: $ImageFormat, then Run"
        Write-Host "    4. When done, open the run -> Artifacts -> download"
        Write-Host ""
        $open = Read-Host "  Open Actions page in browser now? (Y/n)"
        if ($open -ne "n" -and $open -ne "N") {
            Start-Process "https://github.com/LongQT-sea/macos-iso-builder/actions/workflows/build.yml"
        }
        return $false
    }
}

# Resolve version/format from params or menu
if ([string]::IsNullOrWhiteSpace($Version) -or [string]::IsNullOrWhiteSpace($Format)) {
    Show-Menu
    $Version = $script:SelectedVersion
    $Format = $script:SelectedFormat
} else {
    $verNum = Get-ChoiceNum $Version
    $script:SelectedVersion = Get-ChoiceName $verNum
    if (-not $script:SelectedVersion) { $script:SelectedVersion = $Version }
    $script:SelectedFormat = $Format.ToLower()
    if ($script:SelectedFormat -ne "iso" -and $script:SelectedFormat -ne "dmg") {
        $script:SelectedFormat = "iso"
    }
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $script:OutputDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
    } else {
        $script:OutputDir = $OutputDir
    }
}

Write-Host ""
Write-Info "macOS version: $script:SelectedVersion, Format: $script:SelectedFormat"
Write-Info "Output directory: $script:OutputDir"
Write-Host ""

$ok = Invoke-GhWorkflow -MacosVersion $script:SelectedVersion -ImageFormat $script:SelectedFormat
if (-not $ok) { exit 1 }
Write-Info "Done."
