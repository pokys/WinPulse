# WinPulse

WinPulse is a transparent PowerShell-based Windows triage, repair, readiness, and migration toolkit for technicians moving Windows 10/11 devices, with no unknown binary payloads.

The current runtime is still a single PowerShell script: `bootstrap.ps1`.

## Direction

WinPulse is evolving from a Windows diagnostics and repair script into a technician toolkit for:

- triage diagnostics
- safe repair actions
- Windows 11 readiness checks
- migration preflight
- future migration backup/restore
- technician report and bundle export

The project is PowerShell-first. New migration work should remain readable, auditable, and friendly to endpoint trust controls: no packed binaries, no obfuscated payloads, no hidden migration agent, and no credential/password export.

## Primary Web Run

The primary technician launch path is the single-line GitHub bootstrap:

```powershell
irm https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1 | iex
```

This keeps the normal dashboard/menu flow and auto-elevates when needed.

To start a specific mode through the same `irm | iex` flow:

```powershell
$Global:WinPulseMode = 'MigrationPreflight'
irm https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1 | iex
Remove-Variable -Name WinPulseMode -Scope Global -ErrorAction SilentlyContinue
```

Environment variable override is also supported:

```powershell
$env:WINPULSE_MODE = 'W11Readiness'
irm https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1 | iex
Remove-Item Env:\WINPULSE_MODE -ErrorAction SilentlyContinue
```

## Local Run

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

## Modes

```powershell
.\bootstrap.ps1
.\bootstrap.ps1 -Mode Triage
.\bootstrap.ps1 -Mode Repair
.\bootstrap.ps1 -Mode W11Readiness
.\bootstrap.ps1 -Mode MigrationPreflight
.\bootstrap.ps1 -Mode ExportBundle
```

Running with no parameters keeps the normal dashboard/menu flow.

## Migration Preflight

`MigrationPreflight` is read-only. It inspects the device and generates technician reports without copying user data or exporting secrets.

It detects system identity, Windows 11 readiness signals, local user profiles, OneDrive/Known Folder Move hints, PST/OST and Thunderbird data, browser profile roots, Wi-Fi profile names, VPN phonebook files, installed applications, winget availability, and developer/config data hints.

It does not export browser passwords, DPAPI secrets, private keys, Wi-Fi keys, VPN credentials, or Windows Credential Manager data.

Reports are written under:

```text
C:\ProgramData\WinPulse\exports
```

Each migration preflight creates:

```text
C:\ProgramData\WinPulse\exports\MigrationPreflight-<ComputerName>-<yyyyMMdd-HHmmss>\
  migration-preflight.json
  migration-preflight.html
  migration-preflight.txt
  logs\migration-preflight.log
```

`ExportBundle` creates a ZIP from the latest export folder.

## Backup/Restore

Migration backup and restore are planned but not implemented in this milestone. Future work should keep the same safety stance: explicit selection, dry-run planning, clear manifests, no credentials/password export, and no private key export by default.

## Relationship To WinMigraThor

WinMigraThor was an experimental Go-based migration tool. Its migration workflow ideas are being carried forward into WinPulse, but the Go implementation should be treated as reference/legacy rather than the future runtime.

New migration work belongs in WinPulse and should be PowerShell-first for transparency, auditability, and endpoint trust.

## Notes

- The script auto-elevates to Administrator.
- Existing diagnostics, dashboard, and guided repair flows remain available.
- Reports and local artifacts use `C:\ProgramData\WinPulse`.
