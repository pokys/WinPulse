# WinPulse

WinPulse is a transparent PowerShell-based Windows triage, repair, readiness, and migration toolkit for technicians moving Windows 10/11 devices, with no unknown binary payloads.

The current runtime is still a single PowerShell script: `bootstrap.ps1`.

## Direction

WinPulse is evolving from a Windows diagnostics and repair script into a technician toolkit for:

- triage diagnostics
- safe repair actions
- Windows 11 readiness checks
- migration preflight
- migration backup and restore (skeleton)
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
.\bootstrap.ps1 -Mode MigrationBackup
.\bootstrap.ps1 -Mode MigrationRestore
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

## Migration Backup

`MigrationBackup` is the backup skeleton. It uses explicit selection and safe defaults, and it stays read-only until the technician confirms the copy.

The flow is:

1. Scan local user profiles.
2. Pick which users to back up (multi-select).
3. Pick which known folders to back up: Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites. AppData is excluded by default.
4. Optionally widen scope (off by default, multi-select): include private keys (`.ssh`, `.gnupg`, `id_rsa`, `*.ppk`) and/or include the AppData folder. Each opt-in prints an explicit warning and is recorded in the manifest.
5. Choose a destination root (defaults under `C:\ProgramData\WinPulse\backups`, or point it at an external drive).
6. Review a dry-run copy plan with per-folder sizes and a total.
7. Choose **Dry run** (`robocopy /L`, copies nothing) or **Execute copy** (requires typing `YES`). After confirming an execute, you can optionally enable post-copy hash sampling (SHA256 of a random subset) for stronger verification.

Copying is done with a `robocopy` wrapper. Certificate files (`.pfx`, `.p12`, `.pem`, `.cer`, `.crt`) are intentionally **included** so they can be migrated. Standalone SSH/PuTTY private keys and registry hives are excluded by default (`*.ppk`, `id_rsa`/`id_dsa`/`id_ecdsa`/`id_ed25519`, `NTUSER.DAT`, `UsrClass.dat`, plus the `.ssh` and `.gnupg` folders) unless the private-keys opt-in is enabled. Registry hives stay excluded even then. No passwords, browser secrets, or DPAPI material are exported.

Each backup creates:

```text
C:\ProgramData\WinPulse\backups\MigrationBackup-<ComputerName>-<yyyyMMdd-HHmmss>\
  <UserName>\<Folder>\...        # copied files (skipped on dry run)
  manifest.json
  migration-backup-report.html  # printable human summary
  migration-backup-report.txt
  logs\migration-backup.log
  logs\robocopy-<User>-<Folder>.log
```

After an executed copy, each folder is verified by comparing the expected source set (with exclusions applied) against what landed at the destination. A folder is flagged as a mismatch if the destination is missing files or bytes the copy should have produced.

`manifest.json` records the selected users and folders, the destination, the applied exclusions, per-item robocopy exit codes, per-item verification (source/destination file and byte counts plus a Verified/Mismatch status), totals, the failed and mismatch counts, and the safety notes for the run.

## Migration Restore

`MigrationRestore` is the restore skeleton. It reads a backup `manifest.json` and copies the saved folders back, staying read-only until the technician confirms.

The flow is:

1. Pick a backup (any folder under `C:\ProgramData\WinPulse\backups` that has a `manifest.json`), or enter a path manually (for example an external drive).
2. Choose a restore root (defaults to `C:\Users`, restoring into `C:\Users\<User>\<Folder>`).
3. Select which folders to restore (multi-select). When the backup holds only one folder with data, this step is skipped and that folder is used.
4. Review a dry-run restore plan with per-folder sizes. Targets that already exist are flagged with `[!]` so overwrites are visible up front.
5. Choose **Dry run** (`robocopy /L`, copies nothing) or **Execute restore** (requires typing `YES`; warns first when any target would be overwritten).

Source paths are rebuilt under the selected backup folder, so a backup moved to a different drive letter still resolves. Restore only copies what the backup chose to keep, so no extra credential or private-key material is reintroduced.

To avoid breaking the Windows profile, restore never copies `desktop.ini` or `thumbs.db`, and it does not copy directory attributes onto the target. That keeps the system/read-only markers that identify Desktop, Documents, Pictures and other known folders intact, so file contents are restored without replacing the special folders themselves.

Each restore creates:

```text
C:\ProgramData\WinPulse\backups\MigrationRestore-<ComputerName>-<yyyyMMdd-HHmmss>\
  migration-restore.json
  migration-restore-report.html  # printable human summary
  migration-restore-report.txt
  logs\migration-restore.log
  logs\robocopy-<User>-<Folder>.log
```

As with backup, each restored folder is verified after the copy by comparing source and destination file and byte counts, with optional post-copy hash sampling.

`migration-restore.json` records the source backup, the restore root, per-item robocopy exit codes, per-item verification (Verified/Mismatch), which items overwrote an existing target, totals, the failed and mismatch counts, and the safety notes for the run.

## Relationship To WinMigraThor

WinMigraThor was an experimental Go-based migration tool. Its migration workflow ideas are being carried forward into WinPulse, but the Go implementation should be treated as reference/legacy rather than the future runtime.

New migration work belongs in WinPulse and should be PowerShell-first for transparency, auditability, and endpoint trust.

## Notes

- The script auto-elevates to Administrator.
- Existing diagnostics, dashboard, and guided repair flows remain available.
- Reports and local artifacts use `C:\ProgramData\WinPulse`.
