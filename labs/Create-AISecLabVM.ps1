<#
================================================================================
 Create-AISecLabVM.ps1

 Purpose : Build an isolated VirtualBox VM for detonating risky AI agent code.
           Creates and configures the VM, attaches the Ubuntu Server ISO, and
           STOPS. It deliberately does not power the VM on.

 Target  : VirtualBox 7.2.14 on Windows 10 Home
           Host: AMD Ryzen 7 5800X (8C/16T), 48 GB RAM

 Isolation model:
   - NO shared folders (asserted at the end, not merely omitted)
   - NO clipboard sharing, NO drag-and-drop
   - NO USB passthrough, NO audio, NO 3D acceleration
   - NO Guest Additions (install nothing that reopens the above channels)
   Files move in over the network (scp / git clone), never via a host mount.

 IMPORTANT - flag naming:
   VirtualBox 7.x renamed many modifyvm options to hyphenated forms
   (--nested-paging, --audio-enabled, --accelerate-3d, --clipboard-mode ...).
   The pre-7.0 spellings (--nestedpaging, --audio, --accelerate3d) will fail
   on this build. Every flag below was verified against
   `VBoxManage modifyvm --help` on 7.2.14r174565.

 Usage   : Run from PowerShell. No admin required.
             .\Create-AISecLabVM.ps1
           Re-running with an existing VM name aborts safely (see preflight).

 Author  : Set up with Claude Code
================================================================================
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# CONFIGURATION - tune these, everything below reads from here
# ==============================================================================

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

$VMName     = "ai-sec-lab"                                        # VM display name
$BaseFolder = "E:\VMs"                                            # matches VirtualBox default machine folder
$IsoPath    = "E:\VMs\iso\ubuntu-26.04-live-server-amd64.iso"     # SHA256-verified by you

# --- Resource allocation (sized for a 48 GB / 8-core host) ---
$MemoryMB   = 8192      # 8 GB. Ubuntu Server idles ~1 GB; leaves ~40 GB for Windows.
                        # Raise to 16384 only if you run local models INSIDE the VM.
$CpuCount   = 4         # 4 of 16 logical CPUs. Stay at or below the 8 PHYSICAL cores -
                        # oversubscribing past physical count degrades performance.
$VramMB     = 16        # Minimum viable. Headless server: no GUI, no need for more.
$DiskMB     = 81920     # 80 GB, dynamically allocated (grows on demand).

# --- Firmware ---
# 'bios' is the reliable default: EFI in VirtualBox can drop to an EFI shell if
# the boot entry isn't found, which is a confusing first-VM failure mode.
# Ubuntu Server installs cleanly under either. Switch to 'efi' only if you
# specifically need Secure Boot testing.
$Firmware   = "bios"

# --- Derived paths ---
$VMFolder   = Join-Path $BaseFolder $VMName
$DiskPath   = Join-Path $VMFolder "$VMName.vdi"

# ==============================================================================
# HELPERS
# ==============================================================================

# Runs VBoxManage and aborts the script if it returns a non-zero exit code.
# VBoxManage reports failure via exit code, so we check it after every call
# rather than trusting output parsing.
function Invoke-VBox {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$VBArgs)
    Write-Host "  > VBoxManage $($VBArgs -join ' ')" -ForegroundColor DarkGray
    # NOTE: do NOT add 2>&1 here. In Windows PowerShell 5.1, redirecting a
    # NATIVE executable's stderr wraps each line in an ErrorRecord
    # (NativeCommandError). Combined with $ErrorActionPreference='Stop' that
    # turns harmless output into a fatal error - VBoxManage writes its
    # "0%...100%" progress meter to stderr, so `createmedium` would abort the
    # script despite succeeding. Let stderr flow to the console and judge
    # success by exit code alone.
    $out = & $VBoxManage @VBArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host $out -ForegroundColor Red
        throw "VBoxManage failed (exit $LASTEXITCODE): $($VBArgs -join ' ')"
    }
    return $out
}

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

# ==============================================================================
# PREFLIGHT - fail early and loudly rather than half-building a VM
# ==============================================================================

Write-Step "Preflight checks"

if (-not (Test-Path $VBoxManage)) { throw "VBoxManage not found at $VBoxManage" }
Write-Ok "VBoxManage found: $VBoxManage"
Write-Ok "Version: $((& $VBoxManage --version))"

if (-not (Test-Path $IsoPath)) { throw "ISO not found at $IsoPath" }
$isoSize = [math]::Round((Get-Item $IsoPath).Length / 1GB, 2)
Write-Ok "ISO found: $IsoPath ($isoSize GB)"

# Refuse to clobber an existing VM of the same name. Deleting a VM is
# destructive and is not something a create script should do silently.
$existing = & $VBoxManage list vms
if ($existing -match "`"$VMName`"") {
    throw "A VM named '$VMName' already exists. Remove it manually first:`n" +
          "  VBoxManage unregistervm `"$VMName`" --delete"
}
Write-Ok "No existing VM named '$VMName'"

if (Test-Path $DiskPath) { throw "Disk image already exists at $DiskPath - remove it first." }
Write-Ok "No stale disk image at $DiskPath"

# ==============================================================================
# STEP 1 - Create and register the VM
# ==============================================================================

Write-Step "Creating VM"

# --ostype sets default hardware hints only (we override everything explicitly
# below, so it has little practical effect here).
# NOTE: VirtualBox 7.2.14 has NO 'Ubuntu26_LTS_64' type - the newest LTS profile
# available is Ubuntu24_LTS_64. That is expected and harmless for a 26.04 guest.
Invoke-VBox createvm `
    --name       $VMName `
    --ostype     "Ubuntu24_LTS_64" `
    --basefolder $BaseFolder `
    --register | Out-Null

Write-Ok "VM '$VMName' created and registered in $VMFolder"

# ==============================================================================
# STEP 2 - Core hardware: CPU, memory, firmware
# ==============================================================================

Write-Step "Configuring CPU / memory / firmware"

Invoke-VBox modifyvm $VMName `
    --memory            $MemoryMB `
    --cpus              $CpuCount `
    --firmware          $Firmware `
    --ioapic            on `
    --rtc-use-utc       on `
    --nested-paging     on `
    --paravirt-provider kvm | Out-Null

# --ioapic on           : REQUIRED for any VM with more than one vCPU.
# --rtc-use-utc on      : Linux expects the hardware clock in UTC. Without this
#                         the guest clock is skewed by your timezone offset.
# --nested-paging on    : AMD RVI (Rapid Virtualization Indexing). Lets the CPU
#                         handle guest page tables in hardware instead of costly
#                         software shadow paging. Big performance win.
# --paravirt-provider   : 'kvm' exposes the KVM paravirtualization interface,
#                         which Linux guests detect and use for efficient
#                         timekeeping and spinlocks. Best choice for Linux.

Write-Ok "$MemoryMB MB RAM, $CpuCount vCPU, firmware=$Firmware, nested paging on, paravirt=kvm"

# ==============================================================================
# STEP 3 - Graphics: minimal, no 3D
# ==============================================================================

Write-Step "Configuring graphics"

Invoke-VBox modifyvm $VMName `
    --vram               $VramMB `
    --graphicscontroller vmsvga `
    --accelerate-3d      off | Out-Null

# --accelerate-3d off   : SECURITY-RELEVANT. The 3D acceleration path has
#                         historically been a source of guest-to-host escape
#                         vulnerabilities in VirtualBox. A headless server has
#                         zero use for it. Leave it off.
# --graphicscontroller  : vmsvga is the recommended controller for Linux guests.

Write-Ok "$VramMB MB VRAM, vmsvga controller, 3D acceleration OFF"

# ==============================================================================
# STEP 4 - Strip unneeded hardware (audio, USB)
# ==============================================================================

Write-Step "Disabling audio and USB"

Invoke-VBox modifyvm $VMName `
    --audio-enabled off `
    --audio-driver  none | Out-Null

Invoke-VBox modifyvm $VMName `
    --usb-ohci off `
    --usb-ehci off `
    --usb-xhci off | Out-Null

# Every emulated device is host-side C code parsing guest-controlled input,
# i.e. attack surface. A lab VM needs neither audio nor USB, so remove both.
# Never pass a physical USB device into a detonation VM.

Write-Ok "Audio disabled (device + driver)"
Write-Ok "USB disabled (OHCI / EHCI / xHCI controllers all off)"

# ==============================================================================
# STEP 5 - Networking: NAT
# ==============================================================================

Write-Step "Configuring network"

Invoke-VBox modifyvm $VMName `
    --nic1      nat `
    --nic-type1 virtio `
    --nic2      none `
    --nic3      none `
    --nic4      none | Out-Null

Invoke-VBox modifyvm $VMName --vrde off | Out-Null

# --nic1 nat      : NAT gives the guest outbound internet (needed for apt/pip)
#                   while making it UNREACHABLE from your LAN. The guest gets
#                   no route back into the host filesystem - NAT is a network
#                   path only, never a file-sharing mechanism.
# --nic-type1     : virtio-net is paravirtualized and materially faster than
#                   emulating a physical Intel NIC. Ubuntu ships virtio drivers.
# --nic2..4 none  : No secondary adapters. Nothing on a second network.
# --vrde off      : No remote display server listening. Reduces exposed surface.
#
# *** ISOLATION CONTROL - read this ***
# NAT still lets the guest reach the internet AND other devices on your home
# LAN. That is fine for setup, but BEFORE running genuinely untrusted code,
# cut the network entirely with one of:
#
#   VBoxManage modifyvm "ai-sec-lab" --cable-connected1 off   # yank the cable
#   VBoxManage modifyvm "ai-sec-lab" --nic1 null              # no adapter at all
#
# Re-enable with --cable-connected1 on / --nic1 nat when you need packages.

Write-Ok "NIC1 = NAT (virtio), NICs 2-4 disabled, VRDE off"

# ==============================================================================
# STEP 6 - Isolation: clipboard and drag-and-drop OFF
# ==============================================================================

Write-Step "Disabling host/guest transfer channels"

Invoke-VBox modifyvm $VMName `
    --clipboard-mode           disabled `
    --clipboard-file-transfers disabled `
    --drag-and-drop            disabled | Out-Null

# These are the non-network paths between guest and host. Shared clipboard in
# particular is a real data-leak channel in both directions. All three are set
# to 'disabled' rather than left at defaults, and asserted at the end.
#
# NOTE: these channels are DELIVERED by Guest Additions. By not installing
# Guest Additions at all (see final notes), they are unavailable rather than
# merely switched off - a stronger guarantee.

Write-Ok "Clipboard disabled (including file transfers)"
Write-Ok "Drag-and-drop disabled"

# ==============================================================================
# STEP 7 - Storage: controllers, virtual disk, ISO
# ==============================================================================

Write-Step "Creating storage"

# SATA controller for the system disk (AHCI = modern, well supported by Linux).
Invoke-VBox storagectl $VMName `
    --name       "SATA" `
    --add        sata `
    --controller IntelAhci `
    --portcount  2 `
    --bootable   on | Out-Null
Write-Ok "SATA controller (IntelAhci) added"

# IDE controller for the installer DVD. Keeping the optical drive on a separate
# controller makes it trivial to detach the ISO after installation.
Invoke-VBox storagectl $VMName `
    --name       "IDE" `
    --add        ide `
    --controller PIIX4 | Out-Null
Write-Ok "IDE controller (PIIX4) added for optical drive"

# --variant Standard == dynamically allocated: the .vdi starts near-empty and
# grows as the guest writes. 'Fixed' would preallocate all 80 GB immediately.
Invoke-VBox createmedium disk `
    --filename $DiskPath `
    --size     $DiskMB `
    --format   VDI `
    --variant  Standard | Out-Null
Write-Ok "80 GB dynamically-allocated VDI created: $DiskPath"

# --nonrotational on tells the guest this is an SSD, so Linux picks appropriate
# I/O scheduling and enables periodic TRIM.
Invoke-VBox storageattach $VMName `
    --storagectl    "SATA" `
    --port          0 `
    --device        0 `
    --type          hdd `
    --medium        $DiskPath `
    --nonrotational on | Out-Null
Write-Ok "Disk attached to SATA port 0"

# Attach the installer ISO read-only on the IDE controller.
Invoke-VBox storageattach $VMName `
    --storagectl "IDE" `
    --port       0 `
    --device     0 `
    --type       dvddrive `
    --medium     $IsoPath | Out-Null
Write-Ok "ISO attached to IDE port 0: $(Split-Path $IsoPath -Leaf)"

# Boot DVD first (for the installer), then disk. After Ubuntu is installed,
# detach the ISO so it can't boot the installer again:
#   VBoxManage storageattach "ai-sec-lab" --storagectl "IDE" --port 0 --device 0 --medium none
Invoke-VBox modifyvm $VMName `
    --boot1 dvd `
    --boot2 disk `
    --boot3 none `
    --boot4 none | Out-Null
Write-Ok "Boot order: DVD -> disk"

# ==============================================================================
# STEP 8 - ASSERTIONS: verify the isolation guarantees actually hold
# ==============================================================================
# Configuring a setting and VERIFYING it are different things. This section
# reads the VM's real state back from VirtualBox and fails loudly on mismatch,
# so isolation never silently depends on a flag that didn't take.

Write-Step "Verifying isolation guarantees"

$info = & $VBoxManage showvminfo $VMName --machinereadable
$failures = @()

# Reads one key from `showvminfo --machinereadable` output.
# Returns $null when the key is ABSENT - that distinction is the whole point.
#
# WHY THIS HELPER EXISTS (important - this was a real bug):
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
    param([Parameter(Mandatory)][string[]]$Info, [Parameter(Mandatory)][string]$Key)
    $line = $Info | Select-String -Pattern ("^" + [regex]::Escape($Key) + "=") | Select-Object -First 1
    if (-not $line) { return $null }
    return $line.ToString().Trim().Substring($Key.Length + 1).Trim('"')
}

# Asserts a key EXISTS and equals the expected value. A missing key is a
# failure, never a pass.
function Assert-VMProp {
    param([string[]]$Info, [string]$Key, [string]$Expected, [string]$Label)
    $actual = Get-VMProp -Info $Info -Key $Key
    if ($null -eq $actual) {
        $script:failures += "$Label - key '$Key' NOT FOUND in showvminfo output"
        Write-Fail "$Label - key '$Key' missing, CANNOT VERIFY"
        return
    }
    if ($actual -ne $Expected) {
        $script:failures += "$Label is '$actual', expected '$Expected'"
        Write-Fail "$Label = $actual (expected $Expected)"
        return
    }
    Write-Ok "$Label = $actual"
}

# --- Assertion 1: NO shared folders exist, of any kind ---
# Shared folders appear in machinereadable output as SharedFolderNameMachineMapping<N>
# (permanent) or SharedFolderNameTransientMapping<N>. Any match is a failure.
# Here ABSENCE is the pass condition, so the empty-array trap does not apply.
$sharedFolders = $info | Select-String -Pattern "^SharedFolderNameMachineMapping|^SharedFolderNameTransientMapping"
if ($sharedFolders) {
    $failures += "SHARED FOLDERS PRESENT: $($sharedFolders -join '; ')"
    Write-Fail "Shared folders found - isolation BROKEN"
} else {
    Write-Ok "No shared folders (host filesystem is unreachable from guest)"
}

# --- Assertions 2-7: value checks ---
# CAUTION: the machinereadable key names do NOT match the modifyvm flag names.
# These were read from actual showvminfo output on VirtualBox 7.2.14:
#     modifyvm --clipboard-mode            -> reported as  clipboard=
#     modifyvm --clipboard-file-transfers  -> reported as  clipboard_file_transfers=
#     modifyvm --audio-enabled             -> reported as  audio=
#     modifyvm --usb-ohci/-ehci/-xhci      -> reported as  usb=
# Never assume the flag name is the report name. Verify against real output.
Assert-VMProp $info 'clipboard'                'disabled' 'Clipboard mode'
Assert-VMProp $info 'clipboard_file_transfers' 'off'      'Clipboard file transfers'
Assert-VMProp $info 'draganddrop'              'disabled' 'Drag-and-drop'
Assert-VMProp $info 'accelerate3d'             'off'      '3D acceleration'
Assert-VMProp $info 'audio'                    'none'     'Audio device'
Assert-VMProp $info 'usb'                      'off'      'USB controller'
Assert-VMProp $info 'VMState'                  'poweroff' 'VM state (must not be running)'

if ($failures.Count -gt 0) {
    Write-Host "`n*** ISOLATION ASSERTIONS FAILED ***" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "VM created but isolation guarantees are NOT met. Do not run untrusted code in it."
}

# ==============================================================================
# CONFIGURATION SUMMARY
# ==============================================================================

Write-Step "Final configuration"

# Real machinereadable key names (verified against VirtualBox 7.2.14 output),
# not the modifyvm flag spellings.
$summaryKeys = @(
    'name','ostype','memory','cpus','vram','firmware','nestedpaging',
    'paravirtprovider','graphicscontroller','accelerate3d','audio','usb',
    'nic1','nictype1','vrde','clipboard','clipboard_file_transfers',
    'draganddrop','boot1','boot2','VMState'
)
# A key that cannot be found is reported LOUDLY in yellow, never skipped
# silently. Silent omission is how a wrong key name hides itself.
foreach ($k in $summaryKeys) {
    $v = Get-VMProp -Info $info -Key $k
    if ($null -eq $v) {
        Write-Host ("  {0,-26} <KEY NOT FOUND>" -f $k) -ForegroundColor Yellow
    } else {
        Write-Host ("  {0,-26} {1}" -f $k, $v)
    }
}

Write-Host @"

================================================================================
 VM '$VMName' created successfully. IT HAS NOT BEEN STARTED.
================================================================================

NEXT STEPS
  1. Start it when you are ready (GUI is fine for the install):
       VBoxManage startvm "$VMName" --type gui

  2. Install Ubuntu Server. During install choose "Install OpenSSH server"
     so you can scp files in later without any shared folder.

  3. After install completes, detach the ISO so it stops booting the installer:
       VBoxManage storageattach "$VMName" --storagectl "IDE" --port 0 --device 0 --medium none

  4. Update, then take a CLEAN BASELINE snapshot you can always roll back to:
       sudo apt update && sudo apt upgrade -y      # inside the guest
       VBoxManage snapshot "$VMName" take "clean-baseline" --description "Fresh 26.04 + updates"

  5. Roll back after every risky run - this is the whole point of the setup:
       VBoxManage snapshot "$VMName" restore "clean-baseline"

BEFORE RUNNING UNTRUSTED CODE
       VBoxManage modifyvm "$VMName" --cable-connected1 off

DO NOT INSTALL GUEST ADDITIONS
  Guest Additions is what provides shared folders, clipboard sync, and
  drag-and-drop. Skipping it makes those channels unavailable rather than
  merely disabled. You lose auto-resize and seamless mouse - neither matters
  for a headless server you will mostly reach over SSH.

REMEMBER
  A VM is a strong boundary, not a perfect one. Hypervisor escapes exist.
  This setup is proportionate for untrusted agent code, prompt-injection
  experiments, and tool-misuse testing. For live malware, use a separate
  physical machine or a disposable cloud instance.

"@ -ForegroundColor Cyan
