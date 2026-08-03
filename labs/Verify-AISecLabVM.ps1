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
    [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",

    # -Detonate: assert the guest has no route out. Use this before running
    # untrusted code. Off by default because you need network to install
    # packages, and a check that always fails is one people learn to ignore.
    [switch]$Detonate,

    # Known-good key set. Regenerate after a deliberate config or
    # VirtualBox change, never to silence a failure you have not read.
    [string]$BaselinePath = ""
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# $PSScriptRoot is not populated when PowerShell 5.1 evaluates param block
# defaults, so the baseline path is resolved here instead.
if (-not $BaselinePath) {
    $BaselinePath = Join-Path $PSScriptRoot "baseline-keys.txt"
}

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

# Asserts the guest has no route out. Two ways to satisfy it:
#   nic1 is none/intnet/hostonly  -> no route regardless of cable
#   cable is disconnected         -> adapter could route, but link is down
# Fail-closed: a missing key is a failure, not a pass.
function Assert-EgressCut {
    param([Parameter(Mandatory)][string[]]$Info)

    $nic = Get-VMProp -Info $Info -Key 'nic1'
    if ($null -eq $nic) {
        $script:failures += "Egress - key 'nic1' NOT FOUND in showvminfo output"
        Write-Fail "Egress - key 'nic1' missing, CANNOT VERIFY"
        return
    }

    if (@('none','intnet','hostonly') -contains $nic) {
        Write-Ok "Egress cut - nic1 is '$nic' (no route out)"
        return
    }

    $cable = Get-VMProp -Info $Info -Key 'cableconnected1'
    if ($null -eq $cable) {
        $script:failures += "Egress - key 'cableconnected1' NOT FOUND (nic1='$nic' can route out)"
        Write-Fail "Egress - key 'cableconnected1' missing, CANNOT VERIFY"
        return
    }

    if ($cable -eq 'off') {
        Write-Ok "Egress cut - nic1 is '$nic' but cable is disconnected"
        return
    }

    $script:failures += "Egress is LIVE (nic1='$nic', cableconnected1='$cable')"
    Write-Fail "Egress is LIVE (nic1=$nic, cable=$cable) - guest can reach the internet and your LAN"
}

# Compares the FULL key set the platform reports against a known-good baseline.
# The value assertions above can only catch settings someone thought to list.
# This catches renames, removals, and keys that appear after an upgrade,
# including channels that were never enumerated in the first place.
#
#   in baseline, not reported  -> FAILURE. The rename case: an assertion
#                                 would be searching for a key that is gone.
#   reported, not in baseline  -> WARNING. Review it, then refresh the baseline.
function Assert-KeySet {
    param(
        [Parameter(Mandatory)][string[]]$Info,
        [Parameter(Mandatory)][string]$BaselinePath
    )

    # The reported key set depends on VM state: a running VM emits runtime-only
    # keys (GuestAdditionsFacility_*, SessionName, VideoMode, VRDEClients, and
    # others) that a powered-off VM does not. Comparing across states reports
    # every one of those as a rename, which is a false positive.
    #
    # One baseline per state, selected by the state we are actually in. A single
    # baseline would mean drift goes unchecked in whichever state it was not
    # captured in - and for this VM that would be the running one, which is
    # exactly when untrusted code is executing.
    $currentState = Get-VMProp -Info $Info -Key 'VMState'
    if (-not $currentState) {
        $script:failures += "Key set - VMState missing, CANNOT VERIFY"
        Write-Fail "Key set - VMState missing, CANNOT VERIFY"
        return
    }

    $dir       = Split-Path $BaselinePath -Parent
    $stem      = [System.IO.Path]::GetFileNameWithoutExtension($BaselinePath)
    $statePath = Join-Path $dir "$stem-$currentState.txt"

    if (-not (Test-Path $statePath)) {
        Write-Warn "No '$currentState' baseline at '$statePath' - key-set drift NOT checked"
        Write-Info "Capture one with Update-AISecLabBaseline.ps1 while the VM is $currentState"
        $script:warnings += "No baseline for state '$currentState' - drift not checked"
        return
    }

    $lines = @(Get-Content $statePath)

    # The filename and the #vmstate= header state the same fact independently.
    # If they disagree, a file was renamed or hand-edited, and the thing that
    # tells us which comparison is valid is itself wrong. That is a failure, not
    # a warning.
    $baselineState = ($lines | Where-Object { $_ -match '^#vmstate=' } |
                      Select-Object -First 1) -replace '^#vmstate=', ''
    if ($baselineState -ne $currentState) {
        $script:failures += "Baseline '$statePath' header says '$baselineState', filename says '$currentState'"
        Write-Fail "Baseline filename and header disagree - CANNOT VERIFY"
        return
    }

    $baseline = @($lines | Where-Object { $_ -ne '' -and $_ -notmatch '^#' })
    $current  = @($Info | Where-Object { $_ -match '=' } |
                 ForEach-Object { ($_ -split '=')[0] } | Sort-Object -Unique)

    $missing = @($baseline | Where-Object { $current -notcontains $_ })
    $added   = @($current  | Where-Object { $baseline -notcontains $_ })

    foreach ($k in $missing) {
        $script:failures += "Key '$k' in baseline but NOT reported by this VirtualBox"
        Write-Fail "Key '$k' missing from showvminfo output (renamed or removed?)"
    }

    foreach ($k in $added) {
        $script:warnings += "New key '$k' not in baseline"
        Write-Warn "New key '$k' - review it, then refresh the baseline"
    }

    if ($missing.Count -eq 0 -and $added.Count -eq 0) {
        Write-Ok "Key set matches baseline ($($baseline.Count) keys)"
    }
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

# Egress is an assertion only in detonation mode. Without -Detonate the
# network posture is still reported below, but informationally: it does
# not affect the exit code.
if ($Detonate) {
    Assert-EgressCut -Info $info
}

# Always on. The assertions above check settings someone chose to list;
# this checks the shape of the list itself.
Assert-KeySet -Info $info -BaselinePath $BaselinePath

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
    # modifyvm only works on a powered-off VM; a running one needs controlvm.
    # Printing the wrong command is advice that fails when you follow it.
    if ((Get-VMProp -Info $info -Key 'VMState') -eq 'running') {
        Write-Info "  VBoxManage controlvm `"$VMName`" setlinkstate1 off"
    } else {
        Write-Info "  VBoxManage modifyvm `"$VMName`" --cable-connected1 off"
    }
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
