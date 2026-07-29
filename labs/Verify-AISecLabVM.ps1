<#
================================================================================
 Verify-AISecLabVM.ps1

 Purpose : Standalone pre-flight check. Verifies that the isolation guarantees
           of the 'ai-sec-lab' VM still hold, and exits NON-ZERO if any fail.
           Run this before EVERY risky session.

 Why     : Configuration drifts. One stray click in the VirtualBox GUI can
           re-enable the clipboard or attach a shared folder, and nothing warns
           you. This script re-proves the boundary from the VM's actual state.

 Usage   : .\Verify-AISecLabVM.ps1
           .\Verify-AISecLabVM.ps1 -VMName "some-other-vm"

 Exit codes (check these in scripts / CI):
     0 = all assertions passed, safe to proceed
     1 = one or more assertions FAILED, do not run untrusted code
     2 = preflight error (VBoxManage missing, VM not found) - nothing verified

 Companion to Create-AISecLabVM.ps1. Deliberately standalone with no shared
 dependencies: a verification tool should not rely on the thing it verifies.

 Author  : Set up with Claude Code
================================================================================
#>

[CmdletBinding()]
param(
    [string]$VMName     = "ai-sec-lab",
    [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# OUTPUT HELPERS
# ==============================================================================

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Info { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Gray }

# ==============================================================================
# CORE HELPERS
# ==============================================================================

# Reads one key from `showvminfo --machinereadable` output.
# Returns $null when the key is ABSENT. That distinction is the entire point.
#
# WHY THIS HELPER EXISTS (this was a real bug, do not "simplify" it away):
#   The naive one-liner
#       $v = ($info | Select-String '^somekey=') -replace '.*="?([^"]*)"?$','$1'
#   is a TRAP. When the pattern matches nothing, the pipeline yields an EMPTY
#   ARRAY. In PowerShell, `@() -ne "expected"` is array FILTERING, not a
#   boolean comparison: it returns @(), which is FALSY. So `if ($v -ne "x")`
#   takes the ELSE branch and the assertion reports SUCCESS.
#   Net effect: a typo'd or renamed key makes the check silently pass.
#   An assertion that passes when it cannot find what it is checking is worse
#   than no assertion at all - it manufactures false confidence.
function Get-VMProp {
    param(
        [Parameter(Mandatory)][string[]]$Info,
        [Parameter(Mandatory)][string]$Key
    )
    $line = $Info | Select-String -Pattern ("^" + [regex]::Escape($Key) + "=") | Select-Object -First 1
    if (-not $line) { return $null }
    return $line.ToString().Trim().Substring($Key.Length + 1).Trim('"')
}

# Asserts a key EXISTS and equals the expected value.
# A missing key is an explicit FAILURE, never a silent pass.
function Assert-VMProp {
    param(
        [Parameter(Mandatory)][string[]]$Info,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = Get-VMProp -Info $Info -Key $Key
    if ($null -eq $actual) {
        $script:failures += "$Label - key '$Key' NOT FOUND in showvminfo output"
        Write-Fail "$Label - key '$Key' missing, CANNOT VERIFY"
        return
    }
    if ($actual -ne $Expected) {
        $script:failures += "$Label is '$actual', expected '$Expected'"
        Write-Fail "$Label = $actual  (expected: $Expected)"
        return
    }
    Write-Ok "$Label = $actual"
}

$script:failures = @()
$script:warnings = @()

# ==============================================================================
# PREFLIGHT - exit 2 if we cannot verify anything at all
# ==============================================================================

Write-Step "Preflight"

if (-not (Test-Path $VBoxManage)) {
    Write-Fail "VBoxManage not found at $VBoxManage"
    Write-Host "`nNOTHING VERIFIED. Exit code 2." -ForegroundColor Red
    exit 2
}
Write-Ok "VBoxManage: $((& $VBoxManage --version))"

# Pull the VM state once and reuse. If the VM does not exist, VBoxManage
# returns a non-zero exit code and we must NOT continue - reporting "all
# clear" for a VM we could not read would be the worst possible outcome.
$info = & $VBoxManage showvminfo $VMName --machinereadable
if ($LASTEXITCODE -ne 0) {
    Write-Fail "VM '$VMName' not found (VBoxManage exit $LASTEXITCODE)"
    Write-Host "`nNOTHING VERIFIED. Exit code 2." -ForegroundColor Red
    exit 2
}
Write-Ok "VM '$VMName' found, state readable"

# ==============================================================================
# ASSERTION 1 - NO shared folders, of any kind
# ==============================================================================
# Permanent shares appear as SharedFolderNameMachineMapping<N>, transient ones
# (added at runtime, and therefore the sneakier case) as
# SharedFolderNameTransientMapping<N>. Both are checked.
# Here ABSENCE is the pass condition, so the empty-array trap does not apply.

Write-Step "Isolation assertions"

$sharedFolders = $info | Select-String -Pattern "^SharedFolderNameMachineMapping|^SharedFolderNameTransientMapping"
if ($sharedFolders) {
    $script:failures += "SHARED FOLDERS PRESENT: $($sharedFolders -join '; ')"
    Write-Fail "Shared folders found - ISOLATION BROKEN"
    $sharedFolders | ForEach-Object { Write-Host ("         " + $_.ToString().Trim()) -ForegroundColor Red }
} else {
    Write-Ok "No shared folders (host filesystem unreachable from guest)"
}

# ==============================================================================
# ASSERTIONS 2-8 - value checks
# ==============================================================================
# CAUTION: machinereadable key names do NOT match the modifyvm flag names.
# Verified against real showvminfo output on VirtualBox 7.2.14:
#     modifyvm --clipboard-mode            -> reported as  clipboard=
#     modifyvm --clipboard-file-transfers  -> reported as  clipboard_file_transfers=
#     modifyvm --audio-enabled             -> reported as  audio=
#     modifyvm --usb-ohci/-ehci/-xhci      -> reported as  usb=
#     modifyvm --accelerate-3d             -> reported as  accelerate3d=
# Never assume the flag name is the report name. Verify against real output.

$checks = @(
    @{ Key = 'clipboard';                Expected = 'disabled'; Label = 'Clipboard mode' },
    @{ Key = 'clipboard_file_transfers'; Expected = 'off';      Label = 'Clipboard file transfers' },
    @{ Key = 'draganddrop';              Expected = 'disabled'; Label = 'Drag-and-drop' },
    @{ Key = 'accelerate3d';             Expected = 'off';      Label = '3D acceleration' },
    @{ Key = 'audio';                    Expected = 'none';     Label = 'Audio device' },
    @{ Key = 'usb';                      Expected = 'off';      Label = 'USB controller' },
    @{ Key = 'vrde';                     Expected = 'off';      Label = 'Remote display (VRDE)' }
)

foreach ($c in $checks) {
    Assert-VMProp -Info $info -Key $c.Key -Expected $c.Expected -Label $c.Label
}

# ==============================================================================
# INFORMATIONAL - does not affect exit code, but you should look at it
# ==============================================================================

Write-Step "Network posture (your call, not an assertion)"

# NAT is correct for setup and package installs. It is NOT correct for
# detonating genuinely untrusted code: NAT still reaches the internet and
# every device on your LAN. Cut it before a risky run.
$nic1  = Get-VMProp -Info $info -Key 'nic1'
$cable = Get-VMProp -Info $info -Key 'cableconnected1'

if ($null -eq $nic1)  { Write-Warn "nic1 key not found"; $script:warnings += "nic1 key missing" }
if ($null -eq $cable) { Write-Warn "cableconnected1 key not found"; $script:warnings += "cableconnected1 key missing" }

if ($nic1 -eq 'none' -or $cable -eq 'off') {
    Write-Ok "Network is CUT (nic1=$nic1, cable=$cable) - maximum isolation"
} else {
    Write-Warn "Network is LIVE (nic1=$nic1, cable=$cable)"
    Write-Info "Guest can reach the internet AND your LAN. Before untrusted code:"
    Write-Info "  VBoxManage modifyvm `"$VMName`" --cable-connected1 off"
    $script:warnings += "Network live (nic1=$nic1, cable=$cable)"
}

Write-Step "Rollback readiness (your call, not an assertion)"

# The snapshot IS the safety model. Without one there is nothing to roll back
# to, and a compromised guest stays compromised.
# NOTE: `snapshot list` exits 1 when a VM has no snapshots - that is expected
# behaviour, not an error, so we check the exit code deliberately here.
$snapOut  = & $VBoxManage snapshot $VMName list --machinereadable
$snapExit = $LASTEXITCODE

if ($snapExit -ne 0) {
    Write-Warn "NO SNAPSHOTS EXIST - you have nothing to roll back to"
    Write-Info "Create a baseline once the guest is installed and updated:"
    Write-Info "  VBoxManage snapshot `"$VMName`" take `"clean-baseline`" --description `"Fresh install + updates`""
    $script:warnings += "No snapshot to roll back to"
} else {
    $names = $snapOut | Select-String -Pattern '^SnapshotName' | ForEach-Object {
        ($_.ToString() -split '=', 2)[1].Trim('"')
    }
    Write-Ok ("Snapshots available: " + ($names -join ", "))
    Write-Info "Roll back after each risky run:"
    Write-Info "  VBoxManage snapshot `"$VMName`" restore `"clean-baseline`""
}

Write-Step "Current state"

$vmState = Get-VMProp -Info $info -Key 'VMState'
Write-Info "VM state: $vmState"
if ($vmState -eq 'running') {
    Write-Warn "VM is RUNNING. Transient shared folders can be added at runtime;"
    Write-Warn "this scan reflects the state as of right now, not a guarantee going forward."
    $script:warnings += "VM was running during verification"
}

# Full config dump. A key that cannot be found is reported LOUDLY, never
# skipped silently - silent omission is how a wrong key name hides itself.
$summaryKeys = @(
    'name','ostype','memory','cpus','vram','firmware','nestedpaging',
    'paravirtprovider','graphicscontroller','accelerate3d','audio','usb',
    'nic1','nictype1','cableconnected1','vrde','clipboard',
    'clipboard_file_transfers','draganddrop','boot1','boot2','VMState'
)
Write-Host ""
foreach ($k in $summaryKeys) {
    $v = Get-VMProp -Info $info -Key $k
    if ($null -eq $v) {
        Write-Host ("  {0,-26} <KEY NOT FOUND>" -f $k) -ForegroundColor Yellow
    } else {
        Write-Host ("  {0,-26} {1}" -f $k, $v)
    }
}

# ==============================================================================
# VERDICT
# ==============================================================================

Write-Host ""
Write-Host ("=" * 80)

if ($script:failures.Count -gt 0) {
    Write-Host " VERIFICATION FAILED - DO NOT RUN UNTRUSTED CODE IN THIS VM" -ForegroundColor Red
    Write-Host ("=" * 80)
    Write-Host "`nFailed assertions:" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "`nRepair with Create-AISecLabVM.ps1 settings, or inspect manually:" -ForegroundColor Red
    Write-Host "  VBoxManage showvminfo `"$VMName`"" -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host " ALL ISOLATION ASSERTIONS PASSED" -ForegroundColor Green
Write-Host ("=" * 80)

if ($script:warnings.Count -gt 0) {
    Write-Host "`nWarnings (do not affect exit code, but read them):" -ForegroundColor Yellow
    $script:warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

Write-Host "`nBoundary verified. Remember: a VM is a strong boundary, not a perfect" -ForegroundColor Green
Write-Host "one. Hypervisor escapes exist. For live malware use separate hardware." -ForegroundColor Green
Write-Host ""
exit 0
