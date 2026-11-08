<#
.SYNOPSIS
  Install or upgrade to the Crexi build of git-ai (configurable metrics retention) on Windows.
.DESCRIPTION
  Downloads git-ai-windows-x64.exe from the crexi/git-ai GitHub releases, verifies its checksum,
  swaps it into %USERPROFILE%\.git-ai\bin (refreshing the git.exe shim upstream's installer
  creates), turns off auto-updates, sets the transcript-event retention, and restarts the daemon.
  First-time git-ai users: run the upstream installer first (https://usegitai.com) so hooks and
  PATH get set up, then run this to swap in the Crexi build.
.PARAMETER Tag
  Release tag to install (default: latest).
.PARAMETER RetentionDays
  Days of streamed transcript events to keep (default 7).
.PARAMETER Shrink
  Also delete transcript events older than RetentionDays and VACUUM (needs sqlite3 on PATH).
#>
param(
    [string]$Tag = "",
    [int]$RetentionDays = 7,
    [switch]$Shrink
)
$ErrorActionPreference = 'Stop'
function Test-DaemonRunning([string]$Exe) { (& $Exe bg status 2>$null) -match '"daemon_running": true' }
function Wait-Daemon([string]$Exe, [bool]$Running, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if ((Test-DaemonRunning $Exe) -eq $Running) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}
$Repo = if ($env:GIT_AI_CREXI_REPO) { $env:GIT_AI_CREXI_REPO } else { 'crexi/git-ai' }
$Asset = 'git-ai-windows-x64.exe'
$Base = if ($Tag) { "https://github.com/$Repo/releases/download/$Tag" } else { "https://github.com/$Repo/releases/latest/download" }

$InstallDir = Join-Path $HOME '.git-ai\bin'
$Bin = Join-Path $InstallDir 'git-ai.exe'
$GitShim = Join-Path $InstallDir 'git.exe'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("git-ai-crexi-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null

try {
    Write-Host "Downloading $Asset from $Repo $(if ($Tag) { $Tag } else { '(latest)' })"
    Invoke-WebRequest -Uri "$Base/$Asset" -OutFile (Join-Path $Tmp $Asset)
    Invoke-WebRequest -Uri "$Base/SHA256SUMS" -OutFile (Join-Path $Tmp 'SHA256SUMS')

    $line = Select-String -Path (Join-Path $Tmp 'SHA256SUMS') -Pattern " \*?$([regex]::Escape($Asset))$"
    if (-not $line) { throw "no checksum for $Asset" }
    $expected = $line.Line.Split(' ')[0].ToLower()
    $actual = (Get-FileHash -Path (Join-Path $Tmp $Asset) -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "checksum mismatch for $Asset" }

    $fresh = -not (Test-Path -LiteralPath $Bin)
    if (-not $fresh) {
        Write-Host "Stopping the running daemon"
        & $Bin bg shutdown *> $null
        if (-not (Wait-Daemon $Bin $false 20)) { Write-Host "warning: daemon still running; continuing" }
        Copy-Item -Force -Path $Bin -Destination "$Bin.bak-$(Get-Date -Format yyyyMMddHHmmss)"
    }

    Move-Item -Force -Path (Join-Path $Tmp $Asset) -Destination $Bin
    try { Unblock-File -Path $Bin -ErrorAction SilentlyContinue } catch { }
    if (Test-Path -LiteralPath $GitShim) {
        # upstream installs git.exe as a copy of git-ai.exe, not a symlink; keep them identical
        Copy-Item -Force -Path $Bin -Destination $GitShim
        try { Unblock-File -Path $GitShim -ErrorAction SilentlyContinue } catch { }
    }

    & $Bin config set disable_auto_updates true | Out-Null
    & $Bin config set session_event_retention_days $RetentionDays | Out-Null

    if ($fresh) {
        Write-Host "Fresh install: setting up editor hooks and PATH"
        & $Bin install-hooks --env
    }

    if ($Shrink) {
        $Db = Join-Path $HOME '.git-ai\internal\metrics-db'
        if ((Test-Path -LiteralPath $Db) -and (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
            Write-Host "Deleting transcript events older than $RetentionDays days and compacting $Db"
            & sqlite3 $Db "PRAGMA busy_timeout=600000; DELETE FROM metrics WHERE event_kind=5 AND event_ts < strftime('%s','now')-$RetentionDays*86400; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);"
        } else {
            Write-Host "skipping -Shrink: metrics-db or sqlite3 not found"
        }
    }

    & $Bin bg start *> $null
    if (Wait-Daemon $Bin $true 15) { Write-Host "Daemon running" }
    else { Write-Host "note: daemon not running yet; it starts automatically on the next git command" }
    Write-Host "Installed $(& $Bin --version) at $Bin"
    Write-Host "session_event_retention_days = $(& $Bin config session_event_retention_days)"
}
finally {
    Remove-Item -Recurse -Force -Path $Tmp -ErrorAction SilentlyContinue
}
