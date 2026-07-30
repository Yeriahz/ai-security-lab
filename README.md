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

Regenerate the baseline after a deliberate config or VirtualBox change. Never to
silence a failure you have not read.

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
