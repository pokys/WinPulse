# Agent Instructions

This file is the canonical working guide for AI agents working on WinPulse,
including Codex, Claude Code, and similar coding assistants. Read this before
making changes.

## Agent Coordination

Claude Code is the lead agent for product and implementation direction in this
repository. Codex should act as an implementation assistant: do only the
specific work assigned by the user or Claude, avoid independent product
decisions, and ask before changing files when the requested change is not
explicit or when it conflicts with existing project rules. If Codex finds a
problem outside the assigned task, report it and wait for direction instead of
fixing it unilaterally.


## Resume Here (current state)

As of 2026-06-11, `dev/migration-preflight-foundation` carries version
`0.19.0-20260610` (Batch 5: long-path-safe verification, hardened
Repair-WindowsUpdate, OS junk cleanup, LOADED boot lines), awaiting the owner's
sign-off and merge to `main`. Check git for the exact branch sync.

Workflow: Codex implements assigned tasks; Claude reviews, verifies, bumps the
version, and merges. The owner confirms visually for any TUI change before
merge. Commit identity is `pokys`. The owner's merge signal is "hod to do mainu".

After any change to `bootstrap.ps1`: run the parser check, the ASCII check, and
all five non-elevated smoke modes (MigrationBackup/Restore/Verify/Apps/Live);
MigrationPreflight needs elevation. Keep `bootstrap.ps1` ASCII-only and
StrictMode-safe. Do not push TUI-rendering changes to `main` until the owner has
seen them.

PowerShell footgun: `continue`/`break` inside a `switch` do NOT control an
enclosing loop - control falls through past the switch. Never rely on it.

Completed task specs (Batches 1-5, C1-C39) are archived in
`docs/archive/work-queue-completed.md` - consult it for the rationale and
acceptance criteria of any shipped feature. This file keeps only live
instructions, the backlog, and the reference sections below.

### Backlog (not scheduled)

In rough priority:

- Deferred TUI (need an interactive session): C9 (boxed/paged Network and
  Security output with a breadcrumb), C11 (scrollable findings list with
  jump-to-detail), C7 (single-select viewport scrolling, low value).
- Live Migration over SMB: verification re-enumerates the remote source a second
  time over the wire; reuse the plan's source counts for remote sources.
- Pester unit tests for the pure parsers/builders (winget export, powercfg HTML,
  pnputil, plan builders) - currently only smoke-covered.
- Release tags plus a cheap startup "newer version available" check (today every
  run is HEAD of `main`; a saved local copy never learns it is stale).
- Incremental backup and selective AppData - see the Migration status checklist.

Declined by the owner: exit-prompt ZIP archive of exports; a startup spinner
(the LOADED boot lines are considered good enough).

## Project Direction

WinPulse is the main project going forward.

- Repository: `pokys/WinPulse`
- Main branch: `main`
- Runtime: single-file Windows PowerShell script, `bootstrap.ps1`
- Primary technician launch path:

```powershell
irm https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1 | iex
```

Local execution must also continue to work:

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
.\bootstrap.ps1 -Mode Triage
.\bootstrap.ps1 -Mode Repair
.\bootstrap.ps1 -Mode W11Readiness
.\bootstrap.ps1 -Mode MigrationPreflight
.\bootstrap.ps1 -Mode ExportBundle
```

WinPulse is a transparent PowerShell-based Windows triage, repair, readiness,
and migration toolkit for technicians moving Windows 10/11 devices, with no
unknown binary payloads.

## Non-Goals And Safety Boundaries

Do not add or ship:

- Go executables or a Go migration runtime.
- Packed binaries, self-extracting EXEs, or obfuscated payloads.
- Base64 payload execution, AMSI bypasses, Defender exclusions, or hidden
  downloader behavior.
- New production use of `Invoke-Expression`.
- Automatic remote execution.
- Credential, password, DPAPI secret, browser password, Windows Credential
  Manager, Wi-Fi key, VPN secret, or private-key export features.
- Destructive changes without explicit confirmation and a safe user flow.

Use WinMigraThor only as legacy/reference material for migration workflow
ideas. New migration implementation belongs in WinPulse and must remain
PowerShell-first.

## Runtime Compatibility

- Target Windows PowerShell 5.1 first.
- Keep `bootstrap.ps1` runnable as a single-file release artifact.
- Preserve `irm ... | iex` behavior as the primary path.
- Keep `bootstrap.ps1` source ASCII-only. Windows PowerShell 5.1 can misread
  UTF-8 without BOM during local `-File` execution, and characters such as em
  dash can break parsing after mojibake.
- Preserve auto-elevation, default dashboard/menu flow, existing diagnostics,
  and guided repair behavior.
- Keep paths under `C:\ProgramData\WinPulse` compatible.
- Reports and exports should live under `C:\ProgramData\WinPulse\exports`.

## Coding Notes

- `Set-StrictMode -Version Latest` is enabled.
- Use bracket notation for hashtable and ordered dictionary access, for example
  `$item['Key']`.
- Under StrictMode, indexing an empty array throws (`@(...)[0]` on a filter that
  matched nothing is an IndexOutOfRange). Use `... | Select-Object -First 1`,
  which yields `$null` instead, for "first match or none" lookups.
- Under StrictMode in PS 5.1, `@()`-wrapping or outputting a
  `Generic.List[object]` throws "argument types do not match". Return
  `$list.ToArray()` instead of `@($list)`.
- Use approved PowerShell verbs where practical.
- Prefix new helper functions with `WinPulse` where it fits existing style.
- Prefer clear PowerShell 5.1-compatible code over clever syntax.
- Keep collectors fault-tolerant: catch optional subsystem errors and return
  partial data plus an error/status signal.
- Avoid global state unless matching existing script-level state.
- Keep comments short and useful.

## TUI Notes

- Single-select menu: `Select-WinPulseMenuItem`.
- Multi-select menu: `Select-WinPulseMultiMenuItem` with Space to toggle.
- Existing TUI box width is 88 characters.
- Installer flows should run in a separate PowerShell process where practical
  so an installer crash does not take down WinPulse.

## Startup Performance

The startup scan is split into a fast critical path and deferred work:

- `Invoke-CoreScan` collects only what the dashboard and triage findings need
  (system, hardware, security, health, network, plus drivers, startup, printers,
  license, hardware detail, temperatures, TPM). Keep it lean.
- `Complete-WinPulseDetailScan` lazily fills the detail-only sections (installed
  software, scheduled tasks, user accounts, network detail, virtualization). It
  is idempotent (guarded by `$scan.DetailScanned`) and is called by the consumers
  that need full data (Findings detail, Export menu, HTML report). Do not move
  these back into the startup path.
- Triage findings and the dashboard already null-guard every extended/detail
  section, so deferring a section is safe (it just will not surface until loaded).
- Known slow WMI: `SoftwareLicensingProduct` MUST be queried with a WQL `-Filter`
  (ApplicationID `55c92734-...` + `PartialProductKey IS NOT NULL`); unfiltered it
  enumerates hundreds of SKUs and costs ~10s. The BitLocker WMI provider costs
  ~5s to initialize regardless of query shape - do not "optimize" it by changing
  the query; only deferral would help, and that trades dashboard accuracy.

## Migration Work

### Status Checklist (keep this current)

This is the single source of truth for migration progress. Update it whenever a
piece moves between states.

Done (implemented and statically/functionally tested, NOT yet merged):

- [x] Migration Preflight (`-Mode MigrationPreflight`) - read-only reporting.
- [x] Migration Backup (`-Mode MigrationBackup`) - user/folder selection,
      dry-run plan, robocopy copy, `manifest.json`, YES confirmation.
- [x] Migration Restore (`-Mode MigrationRestore`) - manifest read, restore
      plan, overwrite flagging, profile-safe copy.
- [x] Backup/Restore verification (file count + byte comparison, exclusion
      aware), written to manifests and shown on screen.
- [x] Safety: certificates included in backup; SSH/PuTTY keys + hives excluded.
- [x] Safety: restore protects known folders (skips desktop.ini/thumbs.db,
      re-asserts directory attributes after robocopy).
- [x] Menu wiring (main + triage), mode dispatch, elevation, ValidateSets,
      smoke-test ValidateSet.
- [x] Per-run human summary report (HTML + text) written beside each backup and
      restore JSON manifest, matching the preflight report styling.

Half done / needs follow-up:

- [x] Automated non-elevated coverage: the smoke-test now drives a real
      backup + restore on a temp fixture (Task C2), and the non-interactive
      parameters (Task C1) make it scriptable. Both pass with exit 0.
- [ ] Elevated run against a REAL live profile (interactive menu flow + execute
      against `C:\Users`) still has not been done. Lower risk now that the copy
      path is covered on fixtures, but remains the last manual verification.

To do (next milestone: Backup/Restore Reporting And Selection):

- [x] Per-run human summary report (HTML/text) beside the JSON manifests,
      reusing the preflight HTML/text export style.
- [x] Selectable per-folder restore instead of whole-manifest restore
      (`Select-WinPulseRestoreItems`; single-folder backups skip the menu).
- [x] Opt-in toggles to widen scope into excluded categories, with explicit
      warnings (`Select-WinPulseBackupScopeOptIns`: private keys + AppData,
      off by default, recorded in the manifest as `OptInCategories`).
- [x] Optional hash sampling on top of count/byte verification (opt-in prompt
      after confirming an execute; SHA256 of a random sample, default 25 files).

Backlog (not scheduled):

- [ ] Incremental backup (opt-in `/MIR` for the backup destination only, never
      for restore - `/MIR` purges and would cause data loss in a live profile).
- [x] Restore remapping to a different target user name (cross-account moves) -
      done via `-RestoreAsUser` (Task C12).
- [ ] Selective AppData (per-application data); currently excluded by design.
- [ ] Remote backup/restore over an SMB admin share (`\\HOST\C$`). Candidate
      feature, decision pending. See "Candidate feature: Remote over SMB (C$)".

Implemented milestones:

- Migration Preflight Foundation (`-Mode MigrationPreflight`). Read-only. It
  inspects and reports without copying data or exporting secrets.
- Migration Backup Skeleton (`-Mode MigrationBackup`). Explicit user and folder
  selection, dry-run copy plan, `robocopy` wrapper, and a `manifest.json`. It
  stays read-only until the technician confirms the copy. Private keys and
  credential-like files are excluded by default.
- Migration Restore Skeleton (`-Mode MigrationRestore`). Reads a backup
  `manifest.json`, maps users/folders to restore targets, builds a dry-run
  restore plan, and copies files back with the shared `robocopy` wrapper. It
  flags existing targets before overwrite and stays read-only until confirmed.
- Backup/Restore Verification. After an executed copy, each folder is verified
  by comparing the expected source set (exclusions applied) against the
  destination file and byte counts. Per-item Verified/Mismatch status and a
  run-level mismatch count are written to the manifests and shown on screen.
  Optional SHA256 hash sampling (opt-in) adds a stronger per-file check.
- Backup/Restore Reporting And Selection. Per-run HTML + text summary reports
  beside each manifest; selectable per-folder restore; opt-in scope toggles for
  excluded categories (private keys, AppData); optional hash sampling.

Backup/restore implementation notes:

- Entry points: `Invoke-WinPulseMigrationBackup`, `Invoke-WinPulseMigrationRestore`.
- Backup helpers: `Get-WinPulseBackupFolderCatalog`, `Get-WinPulseBackupExclusions`,
  `Select-WinPulseBackupUsers`, `Select-WinPulseBackupFolders`,
  `New-WinPulseBackupPlan`, `Invoke-WinPulseRobocopy`.
- Restore helpers: `Read-WinPulseBackupManifest`, `Get-WinPulseAvailableBackups`,
  `Get-WinPulseRestoreExclusions`, `New-WinPulseRestorePlan` (reuses
  `Invoke-WinPulseRobocopy`).
- Verification helpers: `Get-WinPulseFilteredFiles` (shared filtered file set),
  `Measure-WinPulseFolderFiltered` (counts files/bytes honoring /XF and /XD
  style exclusions) and `Get-WinPulseCopyVerification` (source-vs-destination
  comparison plus optional `-hashSampleSize` SHA256 sampling). Verification runs
  only on executed copies.
- Selection helpers: `Select-WinPulseBackupScopeOptIns` (backup opt-in scope),
  `Select-WinPulseRestoreItems` and `New-WinPulseRestorePlanObject` (per-folder
  restore filtering with recomputed totals).
- Report helpers: `ConvertTo-WinPulseCopyReportRows`,
  `Export-WinPulseMigrationCopyReportText`, `Export-WinPulseMigrationCopyReportHtml`.
  One shared pair renders both backup and restore manifests (it branches on
  `Tool.Mode`), so keep the two manifest shapes report-compatible.
- Output lives under `C:\ProgramData\WinPulse\backups`.
- Default backup folder set is the known doc folders only; AppData is excluded.
- Certificate files (.pfx/.p12/.pem/.cer/.crt) are intentionally included in
  backups so technicians can migrate them. Only standalone SSH/PuTTY private
  keys (`*.ppk`, `id_rsa` family, `.ssh`, `.gnupg`) and registry hives are
  excluded. This is a deliberate project decision; keep it unless asked.
- Restore must not break the profile: it never copies `desktop.ini` or
  `thumbs.db` and never copies directory attributes onto targets, so the
  system/read-only markers on Desktop/Documents/Pictures known folders survive.
  `Invoke-WinPulseRobocopy -copyDirMetadata:$false` controls the directory part.
- Restore rebuilds source paths under the selected backup root, so a moved
  backup folder still resolves; the default restore root is `C:\Users`.
- `robocopy` is called with the call operator so paths with spaces are quoted
  correctly. Exit codes 0-7 are treated as success.

Future migration work must keep the same safety stance: explicit selection,
dry-run planning, clear manifests, and safe defaults. Private keys and
credential-like data must not be exported by default.

Suggested next milestone: Backup/Restore Polish And Coverage. Scope ideas:

- restore remapping to a different target user name (cross-account moves)
- an "open report / open folder" convenience action after a run completes
- non-interactive backup/restore parameters so the smoke-test harness can drive
  them (currently both modes are fully interactive and have no automated cover)
- resume/skip-existing option for very large backups (robocopy `/XO` style),
  kept opt-in and clearly separate from restore (never purge)

### Candidate feature: Remote over SMB (C$)

Status: proposed, not yet decided. Implement or drop in the future.

Goal: let a technician pull a user's data straight from the original PC over its
SMB admin share (`\\HOST\C$\Users\...`) into a backup on the local workstation
(and, symmetrically, push a restore back). This enables an online migration
without first logging into the old machine to run WinPulse there.

Why it is not a big rewrite: the copy engine is already UNC-capable.
`Invoke-WinPulseRobocopy` shells out to `robocopy`, which accepts `\\HOST\C$\...`
sources today, and both the backup destination and the restore root are already
free-form paths. The only hard coupling is profile discovery:
`Get-WinPulseMigrationProfiles` hardcodes `$usersRoot = 'C:\Users'`.

Scope (suggested phasing):

- Phase 1 (MVP): parameterize the users root so it can be `\\HOST\C$\Users`; add
  a source picker at the start of backup ("This PC" vs "Remote PC (C$)"); ask for
  the hostname; reachability check (`Test-Path \\HOST\C$`); rely on the
  technician's current admin token (transparent auth, no credential prompt);
  record `SourceHost` in the manifest.
- Phase 2: explicit credentials via `Get-Credential` + `New-SmbMapping`, with the
  mapping torn down afterwards; remote restore (push to `\\HOST\C$`); lighter or
  optional dry-run sizing to avoid slow recursive enumeration over the wire.

Constraints and gotchas:

- C$ requires local-admin rights on the remote host, admin shares enabled, and
  File and Printer Sharing reachable through the firewall.
- Live-PC locked files (NTUSER.DAT, browser DBs, OST, open documents) will not
  copy. The real fix is remote VSS shadow copies, which is a large separate
  effort and explicitly out of MVP scope.
- Over-the-wire recursive sizing and hashing are slow; keep them bounded/optional
  for remote sources.
- Using credentials to authenticate to a share is not credential export and does
  not breach the safety boundaries; never persist the credentials.
- SMB file copy runs no code on the remote host, so it stays within the
  "no automatic remote execution" non-goal. Do not add PSRemoting/WMI execution
  to make this work.

Complexity estimate: medium. Phase 1 alone is on the smaller side.

## Git Discipline

- Check `git status` before editing.
- Do not overwrite unrelated user changes.
- Do not commit or push unless explicitly asked.
- Keep changes reviewable and scoped to the request.

## Validation

On Windows, prefer validating the relevant mode directly, for example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Mode MigrationPreflight
```

For repeatable local Windows testing, use the smoke-test wrapper from an
elevated Windows PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-WinPulseSmokeTest.ps1 -Mode MigrationPreflight
```

On non-Windows systems, do not claim full runtime validation. Use available
static checks such as:

- PowerShell parser validation if `pwsh` is installed.
- `git diff --check`.
- Careful review of syntax and Windows-only assumptions.
