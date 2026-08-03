# ai-security-lab

A hardened VirtualBox sandbox for safely running AI agent frameworks that execute
model-generated code, plus scripts that verify the isolation actually holds.

Built while studying NVIDIA's NOOA agent framework, whose own documentation is
blunt about the risk: generated code may delete files, send private data to
uncontrolled locations, or modify its environment, and the containment boundary
has to be OS-level isolation rather than in-process validation.

Writeup: [The Security Check That Couldn't Fail](https://dev.to/yeriahz/the-security-check-that-couldnt-fail-2d4h)

## Scripts

Both are PowerShell, tested on Windows 10 with VirtualBox 7.2.

### `labs/Create-AISecLabVM.ps1`

Creates the sandbox VM with isolation settings baked in rather than clicked
through a GUI:

- No shared folders
- Clipboard and clipboard file transfers disabled
- Drag and drop disabled
- 3D acceleration off
- Audio and USB controllers off
- Remote display (VRDE) off
- NAT networking with a virtio NIC

After creating the VM it reads the settings back via
`showvminfo --machinereadable` and asserts each one. Setting a control and
verifying it applied are different things, and the script fails loudly if any
guarantee can't be confirmed.

```powershell
powershell -ExecutionPolicy Bypass -File .\labs\Create-AISecLabVM.ps1
```

### `labs/Verify-AISecLabVM.ps1`

Standalone verification, meant to be run before every risky session. Config
drifts, and a stray GUI click can re-enable the clipboard.

It shares no code with the creation script by design: the thing that builds the
configuration should not be the thing that certifies it.

```powershell
powershell -ExecutionPolicy Bypass -File .\labs\Verify-AISecLabVM.ps1
```

**`-Detonate`**

Adds an egress assertion. Without it the script reports network posture
informationally; with it, a guest that can still reach the internet or your LAN
is a failure.

```powershell
powershell -ExecutionPolicy Bypass -File .\labs\Verify-AISecLabVM.ps1 -Detonate
```

Off by default because you need network to install packages, and a check that
always fails is one people learn to ignore.

**Key-set drift**

Always on. The value assertions can only catch settings someone thought to list.
This compares the full property key set VirtualBox reports against
`labs/baseline-keys.txt`:

- a key in the baseline the platform no longer reports is a **failure**, since
  an assertion would be searching for something that is gone
- a key the platform reports that is not in the baseline is a **warning**, worth
  reviewing before you refresh the baseline

The reported key set depends on VM state. A running VM emits runtime-only keys
(`GuestAdditionsFacility_*`, `SessionName`, `VideoMode`, `VRDEClients` and
others) that a powered-off VM does not, so there is one baseline per state:
`labs/baseline-keys-poweroff.txt` and `labs/baseline-keys-running.txt`. The
verifier selects the one matching the live `VMState`, and warns that drift was
**not checked** if that state has no baseline yet. A single baseline would leave
drift unchecked in whichever state it was not captured in, and for this VM that
would be the running one, which is exactly when untrusted code is executing.

Each file also carries a `#vmstate=` header, so the filename and the contents
state the same fact independently. If they disagree, a file was renamed or
hand-edited and the thing that decides which comparison is valid is itself
wrong, so that is a failure rather than a warning.

Capture a running baseline only after the guest has finished booting. Four keys
(`GuestAdditionsFacility_*`, `GuestAdditionsVersion`) appear a minute or so in,
once the guest registers its facilities, so a baseline taken at boot is already
stale.

**Exit codes**

| Code | Meaning |
|------|---------|
| 0 | All isolation assertions passed |
| 1 | An assertion failed. Do not run untrusted code in this VM |
| 2 | Preflight error (VBoxManage missing, VM not found). Nothing was verified |

Exit 2 is deliberately distinct from exit 1. Reporting "all clear" for a VM the
script could not read would be the worst possible failure mode, so it refuses to
report at all.

Every value check goes through a helper that treats a missing key as an explicit
failure rather than a silent pass. That guard exists because the first version of
this script did the opposite: one check searched for a setting under the wrong
name, got an empty result, and took the success branch. It would have printed a
green `[OK]` with the clipboard wide open. The writeup linked above is about that
bug.

The verifier has been tested against a deliberately broken configuration (a
shared folder pointed at the host drive, clipboard set to bidirectional) to
confirm it fails when it should. A control reporting success only proves it can
produce that output.

### `labs/Update-AISecLabBaseline.ps1`

The only supported way to regenerate the baseline. What it refuses to do is the
point:

- there is no `-Force` and no non-interactive mode, so the silencing cannot be
  scripted or scheduled away
- a key that disappeared has to be typed back by hand before it is dropped. That
  is the rename case, the one that leaves an assertion searching for something
  that no longer exists, and accepting it should cost more than pressing y
- new keys are accepted in bulk, but every one is printed first
- every accepted change is appended to `labs/baseline-history.log` with a
  timestamp, so "when did this key go away and who decided that was fine" has an
  answer later
- if nothing changed, the file is not rewritten at all

```powershell
powershell -ExecutionPolicy Bypass -File .\labs\Update-AISecLabBaseline.ps1
```

Regenerate after a deliberate config or VirtualBox change. Never to silence a
failure you have not read.

The first thing this script caught was a bug in the check it maintains. The
original baseline was captured while the VM was running, so a later comparison
against a powered-off VM reported ten runtime-only keys as renames. A bulk
regenerate would have dropped them silently. Hence the `#vmstate=` header.

## Layout

```
frameworks/    reference material
labs/          the scripts above
notes/         study notes (gitignored)
tools/         cloned repos for study
local-models/  open-weight models (gitignored)
```

## Caveats

A VM is a strong boundary, not a perfect one. Hypervisor escapes exist. This
setup is proportionate for studying agent frameworks and prompt-injection
behavior; live malware analysis wants separate physical hardware.

Skipping VirtualBox Guest Additions is intentional. Guest Additions is what
provides shared folders, clipboard sync, and drag and drop, so not installing it
makes those channels absent rather than merely disabled.

The scripts were built with AI assistance.
