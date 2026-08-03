# Update-AISecLabBaseline.ps1
#
# Regenerates labs/baseline-keys.txt for Verify-AISecLabVM.ps1.
#
# The point of this script is what it REFUSES to do. A drift failure is only
# useful if the cheapest way to make it go away is to read it. So:
#
#   * There is no -Force, no -Yes, no non-interactive mode. If you cannot
#     script the silencing, you cannot cron it away.
#   * A key that disappeared must be typed back by hand before it is dropped.
#     That is the rename case, and it is the one that kills an assertion:
#     Verify-AISecLabVM.ps1 would be searching for a key that no longer
#     exists. Accepting it should cost more than pressing y.
#   * Every accepted change is appended to labs/baseline-history.log with a
#     timestamp, so "when did this key go away and who said it was fine"
#     has an answer.
#   * If nothing changed, the file is not rewritten at all.
#
# Exit codes:
#   0  baseline is current, or was updated after confirmation
#   1  the operator declined a change, so nothing was written
#   2  preflight error - nothing was compared, nothing was written

param(
    [string]$VMName     = "ai-sec-lab",
    [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
    [string]$BaselinePath = ""
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# $PSScriptRoot is not populated when PowerShell 5.1 evaluates param block
# defaults, so the paths are resolved here instead.
if (-not $BaselinePath) {
    $BaselinePath = Join-Path $PSScriptRoot "baseline-keys.txt"
}
$HistoryPath = Join-Path $PSScriptRoot "baseline-history.log"

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Info { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Gray }

# ==============================================================================
# PREFLIGHT - exit 2 if we cannot read the VM at all
# ==============================================================================

Write-Step "Preflight"

if (-not (Test-Path $VBoxManage)) {
    Write-Fail "VBoxManage not found at '$VBoxManage'"
    Write-Host "`nNOTHING COMPARED. Exit code 2." -ForegroundColor Red
    exit 2
}
Write-Ok "VBoxManage found"

$info = & $VBoxManage showvminfo $VMName --machinereadable 2>$null
if ($LASTEXITCODE -ne 0 -or -not $info) {
    Write-Fail "VM '$VMName' not found (VBoxManage exit $LASTEXITCODE)"
    Write-Host "`nNOTHING COMPARED. Exit code 2." -ForegroundColor Red
    exit 2
}
Write-Ok "VM '$VMName' found, state readable"

# ==============================================================================
# CURRENT KEY SET
# ==============================================================================

$current = @(
    $info |
    Where-Object { $_ -match '=' } |
    ForEach-Object { ($_ -split '=')[0] } |
    Sort-Object -Unique
)

if ($current.Count -eq 0) {
    Write-Fail "showvminfo returned no parseable keys"
    Write-Host "`nNOTHING COMPARED. Exit code 2." -ForegroundColor Red
    exit 2
}
Write-Ok "Read $($current.Count) keys from showvminfo"

# The key set depends on VM state, so the baseline records the state it was
# captured in and the verifier refuses to compare across states.
$stateLine    = $info | Where-Object { $_ -match '^VMState=' } | Select-Object -First 1
$currentState = ($stateLine -replace '^VMState=', '').Trim('"')
if (-not $currentState) {
    Write-Fail "Could not read VMState"
    Write-Host "`nNOTHING COMPARED. Exit code 2." -ForegroundColor Red
    exit 2
}
Write-Ok "VM state: $currentState"

# One baseline per VM state. See Assert-KeySet in Verify-AISecLabVM.ps1 for why:
# a running VM reports runtime-only keys that a powered-off one does not, so a
# single baseline can only ever be valid in one state.
$dir          = Split-Path $BaselinePath -Parent
$stem         = [System.IO.Path]::GetFileNameWithoutExtension($BaselinePath)
$BaselinePath = Join-Path $dir "$stem-$currentState.txt"
Write-Info "Baseline for this state: $BaselinePath"

# ==============================================================================
# BOOTSTRAP - no baseline yet
# ==============================================================================

if (-not (Test-Path $BaselinePath)) {
    Write-Step "No baseline found"
    Write-Info "'$BaselinePath' does not exist."
    Write-Info "This will record the CURRENT state as known-good. Only do this on"
    Write-Info "a VM you have already verified, or you are baselining a problem."
    $answer = Read-Host "`nCreate baseline from the current $($current.Count) keys? (yes/no)"
    if ($answer -ne "yes") {
        Write-Host "`nDeclined. Nothing written. Exit code 1." -ForegroundColor Yellow
        exit 1
    }
    @("#vmstate=$currentState") + $current | Set-Content $BaselinePath
    Add-Content $HistoryPath "$(Get-Date -Format o)  CREATED  $($current.Count) keys  vm=$VMName"
    Write-Ok "Baseline created with $($current.Count) keys"
    exit 0
}

# ==============================================================================
# DIFF
# ==============================================================================

Write-Step "Comparing against baseline"

$baseline = @(Get-Content $BaselinePath | Where-Object { $_ -ne '' -and $_ -notmatch '^#' })
$removed  = @($baseline | Where-Object { $current -notcontains $_ })
$added    = @($current  | Where-Object { $baseline -notcontains $_ })

if ($removed.Count -eq 0 -and $added.Count -eq 0) {
    Write-Ok "Key set matches baseline ($($baseline.Count) keys). Nothing to update."
    exit 0
}

Write-Info "Baseline: $($baseline.Count) keys.  Current: $($current.Count) keys."

# ==============================================================================
# REMOVED KEYS - the dangerous direction, confirmed one at a time
# ==============================================================================

$acceptedRemovals = @()

if ($removed.Count -gt 0) {
    Write-Step "Keys in the baseline that this VirtualBox no longer reports"
    Write-Warn "These are the renames. An assertion pointed at one of these is"
    Write-Warn "now searching for something that does not exist."
    Write-Info ""
    Write-Info "Before accepting any of these, find where it went. A key that was"
    Write-Info "renamed will usually show up in the ADDED list below under a new"
    Write-Info "name, and the setting it controls is still live."
    Write-Info ""

    foreach ($k in $removed) {
        Write-Host "  MISSING: $k" -ForegroundColor Red
        $typed = Read-Host "  Type the key name exactly to accept its removal (or press Enter to abort)"
        if ($typed -ne $k) {
            Write-Host "`nNot confirmed. Nothing written. Exit code 1." -ForegroundColor Yellow
            exit 1
        }
        $acceptedRemovals += $k
        Write-Ok "Removal accepted: $k"
    }
}

# ==============================================================================
# ADDED KEYS - reviewed in bulk, but every one is printed
# ==============================================================================

$acceptedAdditions = @()

if ($added.Count -gt 0) {
    Write-Step "Keys this VirtualBox reports that are not in the baseline"
    Write-Info "New keys usually mean a VirtualBox upgrade added a capability, or"
    Write-Info "you took a snapshot (snapshot keys are per-snapshot). Read them:"
    Write-Info "a new key can be a new channel between guest and host, and nothing"
    Write-Info "in Verify-AISecLabVM.ps1 asserts a value for it yet."
    Write-Info ""
    foreach ($k in $added) { Write-Host "  NEW: $k" -ForegroundColor Yellow }

    $answer = Read-Host "`nAccept all $($added.Count) new keys into the baseline? (yes/no)"
    if ($answer -ne "yes") {
        Write-Host "`nDeclined. Nothing written. Exit code 1." -ForegroundColor Yellow
        exit 1
    }
    $acceptedAdditions = $added
    Write-Ok "$($added.Count) new keys accepted"
}

# ==============================================================================
# WRITE - only after every change above was confirmed
# ==============================================================================

Write-Step "Updating baseline"

@("#vmstate=$currentState") + $current | Set-Content $BaselinePath

$stamp = Get-Date -Format o
Add-Content $HistoryPath "$stamp  UPDATED  vm=$VMName  keys=$($current.Count)"
foreach ($k in $acceptedRemovals)  { Add-Content $HistoryPath "$stamp    -removed  $k" }
foreach ($k in $acceptedAdditions) { Add-Content $HistoryPath "$stamp    +added    $k" }

Write-Ok "Baseline updated to $($current.Count) keys"
Write-Info "Change recorded in $HistoryPath"
Write-Info ""
Write-Info "Now re-run the verifier to confirm it comes back green:"
Write-Info "  powershell -ExecutionPolicy Bypass -File .\labs\Verify-AISecLabVM.ps1"

exit 0
