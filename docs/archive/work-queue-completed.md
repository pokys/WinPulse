# WinPulse Work Queue - Completed Task Archive

Full specifications for tasks C1-C39 (Work Queue Batches 1-5), implemented and
shipped up to 2026-06-10. Kept verbatim for the rationale, scope, and acceptance
criteria behind each shipped feature. The live working guide is `AGENTS.md`;
this file is reference only and is not maintained going forward.

Deferred (not implemented) at archival time: C7, C9, C11 - see the Backlog in
`AGENTS.md`.

---
## Work Queue (assigned to Codex)

Prepared by Claude (lead). Do these in order. Claude reviews each before merge.
Work on branch `dev/migration-preflight-foundation`. **ALWAYS start by syncing
with main:**
```
git checkout dev/migration-preflight-foundation
git merge main --ff-only
```
If the merge fails (not fast-forward), stop and report to Claude before
proceeding. Do not push to `main`. Do not bump the version (Claude handles
version + merge). After each task: run the parser
check and the ASCII check (see Validation), keep `bootstrap.ps1` ASCII-only and
StrictMode-safe, and report what you changed plus your test output. If anything
is ambiguous or conflicts with a rule, stop and ask.

Environment constraint (important): Codex cannot run an elevated PowerShell
session. So everything you build here MUST be verifiable WITHOUT elevation:

- Validate with the parser check, the ASCII check, and the fixture-based smoke
  run only. All of these run non-elevated.
- Use throwaway fixtures under the per-user temp folder (`$env:TEMP`) for both
  the source profile data and the backup/restore destinations - never real
  `C:\Users` profiles and never admin-only locations.
- The real elevated end-to-end run against live profiles stays a human/Claude
  task; do not attempt it and do not claim it was done.

### Task C1 - Non-interactive parameters for backup and restore

Status: DONE - implemented by Codex, reviewed and polished by Claude, fixture
smoke passes non-elevated. (Kept below for reference.)

Why: the backup and restore modes are fully interactive (menus + a typed `YES`),
so they cannot be exercised by the smoke-test harness or scripted. This is the
blocker for the "real runtime test" open item. Add a non-interactive path while
leaving the interactive flow byte-for-byte unchanged when no params are passed.

Scope:

- Add parameters to the top `param()` block in `bootstrap.ps1`:
  - Backup: `-BackupUsers string[]`, `-BackupFolders string[]`,
    `-BackupDestination string`, `-BackupExecute switch`,
    `-BackupIncludePrivateKeys switch`, `-BackupIncludeAppData switch`,
    `-BackupHashSample switch`, `-BackupProfilesRoot string`.
  - Restore: `-RestoreBackupPath string`, `-RestoreRoot string`,
    `-RestoreFolders string[]`, `-RestoreExecute switch`,
    `-RestoreHashSample switch`.
- Parameterize the profiles root: give `Get-WinPulseMigrationProfiles` an
  optional `-Root` parameter defaulting to `C:\Users`, and pass
  `-BackupProfilesRoot` through to it. This is REQUIRED so the smoke test can
  point at a temp fixture root and run without elevation (no access to real
  `C:\Users`). Bonus: it is also the groundwork for the future SMB C$ candidate
  feature, so keep the default behavior identical when the param is absent.
- `Invoke-WinPulseMigrationBackup` and `Invoke-WinPulseMigrationRestore` take
  these as optional parameters. When the required ones are supplied, run
  non-interactively: skip `Select-WinPulse*` menus, the destination/root
  `Read-Host`, and the `YES` prompt.
- Safety: a non-interactive run is dry-run UNLESS `-BackupExecute` /
  `-RestoreExecute` is present. That switch IS the explicit confirmation -
  never copy for real without it. Keep all existing safe defaults (certificates
  kept, keys/hives excluded unless `-BackupIncludePrivateKeys`, AppData excluded
  unless `-BackupIncludeAppData`, restore still skips desktop.ini and protects
  known-folder attributes).
- Plumb the values into the existing helpers (`New-WinPulseBackupPlan`,
  `Get-WinPulseBackupExclusions -includePrivateKeys`, the folder list, the
  `$hashSampleSize`, `Select-WinPulseRestoreItems` equivalent filtering). Reuse,
  do not duplicate, the existing logic.

Acceptance (all of this must pass WITHOUT an elevated session):

- Make a temp fixture root, e.g. `$env:TEMP\wp-fix\Users\tester\Desktop` with a
  file in it, then:
  `bootstrap.ps1 -Mode MigrationBackup -BackupProfilesRoot <tmpFixtureUsers>`
  `-BackupUsers tester -BackupFolders Desktop -BackupDestination <tmpDest>`
  `-BackupExecute` completes with no prompts, writes `manifest.json` + reports,
  exit code 0, and the manifest shows zero failures/mismatches.
- `bootstrap.ps1 -Mode MigrationRestore -RestoreBackupPath <tmpDest>`
  `-RestoreRoot <tmpRestore> -RestoreFolders Desktop -RestoreExecute` completes
  with no prompts and writes the restore record + report.
- With no backup/restore params, the interactive menus behave exactly as today.
- Parser-clean, ASCII-only, StrictMode-safe.

Out of scope: changing the copy/verification logic, the manifest schema, or the
interactive UX text.

### Task C2 - Smoke-test coverage for backup and restore

Status: DONE - implemented by Codex, reviewed by Claude. Both modes pass
non-elevated with exit 0 and expected-files checks. (Kept below for reference.)

Why: `tools/Invoke-WinPulseSmokeTest.ps1` already accepts `MigrationBackup` and
`MigrationRestore` in its ValidateSet but cannot drive them. Use the Task C1
parameters to actually exercise them on a throwaway fixture.

Scope:

- In the smoke-test, for those two modes: build a small fixture user profile
  tree under a temp path (e.g. `<tmp>\Users\tester\Desktop\sample.txt`), then run
  an execute backup into a second temp dest via `-BackupProfilesRoot` and the
  other Task C1 params, then a restore into a third temp path.
- Assert: expected output files exist (`manifest.json`, the HTML/text report,
  logs), exit code 0, and the manifest reports zero failures and zero
  verification mismatches. Clean up the temp fixtures afterward.
- Must run and pass WITHOUT elevation (temp fixtures + `-BackupProfilesRoot`
  avoid any need for admin or access to real `C:\Users`).

Acceptance: `Invoke-WinPulseSmokeTest.ps1 -Mode MigrationBackup` and `-Mode
MigrationRestore`, run from a NON-elevated window, drive the real copy on the
fixture and report pass/fail with the expected-files check, mirroring the
existing MigrationPreflight smoke logic.

Out of scope: touching production `C:\Users` or real profiles - fixtures only.

### Task C3 - (optional, ask Claude first) BitLocker progressive load

Do NOT start this without confirming with Claude - it touches dashboard render
and is a UX trade-off. Goal would be to move the ~5s `Get-BitLockerVolume` call
off the startup critical path and enrich the dashboard after first paint. Flagged
here only so it is not forgotten.

## Work Queue - Batch 2 (UX/UI), active

Approved by the owner; prepared by Claude. THE TOP RULE: do not break the
working script. The startup scan, dashboard, the Quick Triage / Full menu flow,
and the migration backup/restore all work today - keep them working.

Status (Claude did this batch since Codex was out of limit):

- C4 DONE - default backup to C:\WinPulseBackups (on main).
- C5 DONE - Tweaks hidden, version in header (on main).
- C6 DONE - English UI + InvariantCulture numbers (on main).
- C8 DONE - responsive box width, identical at >= 90 cols (on main).
- C10 DONE - repeat-command hint after interactive backup/restore (on main).
Deferred to a future INTERACTIVE TUI session (owner's call, option 3): C7, C9,
and C11 all change live TUI rendering, which the smoke tests cannot verify. They
are NOT abandoned - they are held until they can be built and checked with the
owner watching a real terminal, so a blind change cannot quietly break the UI.

- C7 - single-select menu viewport scrolling. Lowest value of the three
  (overflow only on tiny windows, already handled by the Clear-Host safeguard)
  and highest risk (the render loop is behind every menu). Revisit only during
  the interactive session, if at all.
- C9 - boxed + paged Network/Security output, consistent loop/back, breadcrumb.
- C11 - scrollable findings list with jump-to-detail.

When starting the interactive session: do these on `dev`, keep each change a
separate commit, validate parser + ASCII + both fixture smoke tests, and confirm
visually at >= 90 columns (must look unchanged) before merging to main.

How to work this batch:

- One task per commit, in order, on `dev/migration-preflight-foundation`. Do not
  push to main and do not bump the version (Claude does that).
- After EACH task: run the parser check, the ASCII check, AND both fixture smoke
  tests (`Invoke-WinPulseSmokeTest.ps1 -Mode MigrationBackup` / `-Mode
  MigrationRestore`) - all must stay green. Report what you changed + test output.
- For any task that touches box drawing or menu rendering (C8, C9, C10): on a
  normal terminal (>= 90 columns) the output MUST look identical to today. Only
  add new behavior for the small/overflow case. If unsure, stop and ask Claude.
- Do not refactor unrelated code. Keep diffs minimal and reviewable.

### Task C4 - Default backup location outside the exit-cleanup zone (do FIRST)

Why: exit cleanup (`Invoke-WinPulseFullArtifactCleanup`, run on Exit) deletes
everything under `C:\ProgramData\WinPulse\backups`. The owner WANTS that cleanup
to stay. So real backups must not default there or they get wiped on exit.

Scope:

- Change ONLY the default backup destination in `Invoke-WinPulseMigrationBackup`
  from `$script:WinPulsePaths.Backups\MigrationBackup-...` to a persistent
  location that exit cleanup does not touch. Use `C:\WinPulseBackups\
  MigrationBackup-<computer>-<stamp>` as the default (create the folder if
  missing). The interactive prompt and `-BackupDestination` still let the user
  type any path.
- Leave exit cleanup, the working dir under `C:\ProgramData\WinPulse`, and
  preflight/exports behaviour unchanged (reports staying ephemeral is fine).
- Restore records may stay where they are (they are logs, not user data).

Acceptance: a default-destination backup lands under `C:\WinPulseBackups` and
survives an Exit; smoke tests still green (they pass explicit temp destinations,
so they are unaffected).

### Task C5 - Hide Tweaks; show version in the dashboard header

- Remove the `Tweaks` entry (and its `'W'` handler) from the main menu - it is a
  disabled stub. Keep `Show-WinPulseTweaksMenu` in the file for later.
- In the dashboard top border (`Show-WinPulseDashboard`), show `WinPulse
  <version>` using `$script:WinPulseVersion`, without changing the box width.

Acceptance: Tweaks is no longer reachable; the dashboard header shows the
version; width/layout unchanged on a normal terminal.

### Task C6 - Full English UI + culture-invariant numbers

- Replace any remaining non-English UI strings (e.g. the `Nacitam systemove
  informace...` startup line) with English.
- Make numeric formatting culture-invariant so it shows `49.58%` not `49,58%`.
  Fix `ConvertTo-ReadableSize` (the `{0:N2}` formats) and any percent formatting
  to use `[System.Globalization.CultureInfo]::InvariantCulture`. Logic unchanged,
  formatting only.

Acceptance: no Czech strings in the UI; sizes/percentages use a dot; smoke green.

### Task C7 - Single-select menu viewport scrolling

- Port the viewport/scroll logic from `Select-WinPulseMultiMenuItem` into
  `Select-WinPulseMenuItem` so long menus scroll instead of relying on the
  `Clear-Host` safeguard.
- CRITICAL: menus that already fit must render and behave EXACTLY as today,
  including the Quick Triage dashboard-then-menu flow we just fixed. Only add
  scrolling when items exceed the visible viewport.

Acceptance: a long menu scrolls; short menus unchanged; the triage dashboard
still shows and does not flash/disappear on return from a submenu.

### Task C8 - Responsive box width (careful)

- Replace the hardcoded `$w = 88` in the header, dashboard, and menus with a
  computed width: `min(88, [Console]::WindowWidth - 2)` clamped to a floor of 60.
- CRITICAL: on a window >= 90 columns the result MUST be 88 (identical to today).
  Only narrow on smaller terminals. Test at 90+, 80, and 70 columns.

Acceptance: identical look at >= 90 cols; no wrapping/garbling at 70 cols.

### Task C9 - Unify raw submenu output + consistent loop/back + breadcrumb

- Network, Security (and any other `Format-Table/Format-List | Out-Host` dumps):
  render inside the existing boxed style and add simple paging for long output
  (page with space/enter, Esc to stop).
- Make these submenus loop until Esc/Back like the others, and add a one-line
  breadcrumb (e.g. `Main > Network`) plus the standard footer help bar.
- Keep it readable - do not over-decorate.

Acceptance: Network/Security match the app style, long output pages instead of
dumping, Esc backs out consistently; smoke green.

### Task C10 - Equivalent-command hint after interactive backup/restore

- After an interactive backup or restore completes, print the equivalent
  non-interactive command line (the `-Backup*` / `-Restore*` form, including
  `-BackupExecute`/`-RestoreExecute`) so a technician can script it.

Acceptance: a copy-pasteable command is shown after an interactive run; nothing
changes for the non-interactive path.

### Task C11 - Scrollable findings list with jump-to-detail (keep it clean)

- Make the triage findings reviewable: a scrollable list of all findings (not
  just top 3 + "+N more"), and selecting one jumps to its relevant detail.
- Priority is readability - do not clutter. Reuse existing menu/scroll helpers.

Acceptance: all findings are reachable and readable; selecting one shows detail;
the dashboard summary (top findings) is unchanged.

## Work Queue - Batch 3 (logic, Codex-friendly)

This batch is non-TUI logic that can be fully verified WITHOUT elevation and
WITHOUT a visual check - exactly what Codex can do. Same rules as before: one
commit per task on `dev`, do not push to main, do not bump the version, run
parser + ASCII + both fixture smoke tests after each, report changes + output,
ask if anything is ambiguous. Use only temp fixtures, never real C:\Users.

### Task C12 - Restore to a different target user (cross-account migration)

Status: DONE - implemented by Codex (`-RestoreAsUser`, validated name, plan
remap, manifest/report fields, elevation passthrough), reviewed by Claude. The
restore smoke test now covers both the default and the remap path. Path names
are guarded against traversal. (Kept below for reference.)

Why: a backup taken from user "old" usually needs to land in user "new" on the
replacement machine. Today restore always writes back under the original
`<UserName>` subfolder.

Scope:

- Add `-RestoreAsUser <string>` to the top `param()` block and forward it through
  `Invoke-WinPulseMode` to `Invoke-WinPulseMigrationRestore` (mirror how
  `-RestoreFolders` is plumbed).
- Interactive restore: after choosing the restore root, prompt "Restore into
  which user name? (Enter = keep original)". Non-interactive: use
  `-RestoreAsUser` when provided.
- Plumb a target-user value into `New-WinPulseRestorePlan` (and the per-folder
  filter path). When set, the per-item Target becomes
  `<restoreRoot>\<targetUser>\<relative>` instead of `<originalUser>\<relative>`.
  The Source (under the backup root) is unchanged. Do not change anything when
  no target user is given - behaviour must be identical to today.
- Record the remap in the restore manifest (e.g. add `RestoreAsUser` and keep
  the per-item original UserName) and mention it in a safety note.
- Keep ALL existing safety and behaviour: desktop.ini/thumbs.db still skipped,
  directory attributes still re-asserted, PARTIAL handling intact, verification
  still runs (it already rebuilds the destination path from the item Target, so
  confirm it verifies the remapped target).

Acceptance (non-elevated, temp fixtures):

- Build a fixture backup (run a MigrationBackup into a temp dest as the smoke
  test does), then:
  `bootstrap.ps1 -Mode MigrationRestore -RestoreBackupPath <dest> -RestoreRoot`
  `<tmp> -RestoreAsUser newuser -RestoreExecute` restores the folders under
  `<tmp>\newuser\...`, exit 0, manifest FailedCount 0.
- Without `-RestoreAsUser`, restore still lands under the original user name
  (unchanged).
- Optionally extend the smoke test with a remap assertion.
- Parser + ASCII clean; both existing fixture smoke tests still exit 0.

Out of scope: SMB/remote sources, AppData internals, any TUI rendering changes.

### Task C13 - MigrationVerify mode: re-check an existing backup vs its manifest

Status: DONE - implemented by Codex (`-Mode MigrationVerify`, `-VerifyBackupPath`,
read-only re-measure vs manifest, Intact/Drift, JSON record outside the backup,
Full-menu entry, smoke covering intact + drift), reviewed by Claude. Confirmed
read-only (no robocopy/Remove-Item; `Initialize-WinPulse` skipped for this mode).
(Kept below for reference.)

Why: before wiping the source machine, a technician wants to confirm a backup on
disk is still complete and intact - no files lost or shrunk since it was written.
This is read-only and never copies, deletes, or modifies anything.

Scope:

- Add `MigrationVerify` to every `-Mode` ValidateSet: the top `param()` block,
  `Invoke-WinPulseMode`, and the smoke wrapper's `ValidateSet`. Add it to the
  `Invoke-WinPulseMode` switch (call `Invoke-WinPulseMigrationVerify`). Add ONE
  menu item for it in the Full menu and its handler (a single `@{...}` line plus
  a `switch` case - do NOT touch menu rendering/scroll logic).
- Add `-VerifyBackupPath <string>` (non-interactive). Interactive: reuse
  `Get-WinPulseAvailableBackups` to pick a backup, or enter a path - mirror how
  `Invoke-WinPulseMigrationRestore` selects the backup (factor out or copy the
  selection block; do not change restore's behaviour).
- New `Invoke-WinPulseMigrationVerify`:
  - Read the manifest with `Read-WinPulseBackupManifest`. If invalid, message and
    return.
  - For each manifest item that actually has data (its `Verification` is not null
    and recorded `DestFiles` > 0), rebuild the backed-up folder path as
    `<backupRoot>\<UserName>\<relative>` (map Folder->relative via
    `Get-WinPulseBackupFolderCatalog`, fallback to the folder name - same pattern
    as restore), then re-measure it NOW with `Measure-WinPulseFolderFiltered`
    (NO exclusions - the backup is already filtered).
  - Compare current Files/Bytes against the manifest's recorded `DestFiles` /
    `DestBytes`. Status `Intact` when current files >= recorded AND current bytes
    >= recorded; otherwise `Drift` (record how many short).
  - Items that were dry-run (no data recorded) are reported as `Skipped`.
  - Print a per-item result and a summary line; write a `migration-verify.json`
    record under `C:\ProgramData\WinPulse\backups\MigrationVerify-<computer>-<stamp>`
    (use the same non-elevated fixture-safe record location pattern the restore
    flow already uses, so the smoke test can run unelevated). An HTML/text report
    is optional - JSON record + on-screen output is enough.
  - Return an object; exit/return should make a drift detectable (e.g. a
    `DriftCount` field), but do NOT throw on drift - report it.
- Read-only guarantee: no robocopy, no New-Item except the record folder, no
  deletes.

Acceptance (non-elevated, temp fixtures):

- Build a fixture backup (as the smoke test does), then
  `bootstrap.ps1 -Mode MigrationVerify -VerifyBackupPath <dest>` exits 0, reports
  every item `Intact`, and writes `migration-verify.json` with DriftCount 0.
- Then delete (or shrink) a file inside the backup and re-run: the matching item
  reports `Drift` and DriftCount > 0.
- Add a `MigrationVerify` smoke mode that asserts both (intact, then drift).
- Parser + ASCII clean; the existing MigrationBackup/MigrationRestore smoke tests
  still exit 0.

Out of scope: per-file hashing of the whole backup (manifests do not store
per-file hashes), TUI rendering changes, anything that writes into the backup.

### Task C14 - Per-application data backup targets (Chrome / Firefox / Outlook)

Status: DONE - implemented by Codex (`-BackupApps`, detection, app targets with
`Relative` + per-item `ExtraExcludeFiles`, Outlook `*.ost` excluded from copy AND
verification, manifest `Apps`, Relative-aware restore/verify round-trip with
catalog fallback for old manifests), reviewed by Claude. Smoke covers the
Chrome/Firefox/Outlook backup -> restore -> verify round-trip and asserts the
`.ost` is neither copied nor restored. (Kept below for reference.)

Why: a technician usually wants a specific app's data, not the whole noisy
AppData. Detect installed app data under the chosen profile and offer each as its
own backup target. All product decisions below are FIXED by Claude (lead) - do
not change them; ask if something is unclear.

Targets (detect by folder existence under `<profile>`):

- chrome   - if `AppData\Local\Google\Chrome\User Data` exists -> back up the
             whole `AppData\Local\Google` folder. Label "Chrome data".
- firefox  - if `AppData\Roaming\Mozilla\Firefox\Profiles` exists -> back up
             `AppData\Roaming\Mozilla\Firefox`. Label "Firefox profile".
- outlook  - if `AppData\Local\Microsoft\Outlook` exists -> back up
             `AppData\Local\Microsoft\Outlook` but EXCLUDE `*.ost` (OST is a
             re-downloadable cache; this keeps PST + autocomplete RoamCache
             `*.dat` + `*.nk2`). Label "Outlook data (PST + autocomplete, no OST)".

These are independent selections, separate from and in addition to the whole
"AppData" opt-in. A user may pick Chrome data without backing up all of AppData.

Scope:

- New `Get-WinPulseBackupAppTargets -profileRoot <root> -userName <name>`: returns
  the detected targets for that user, each `[ordered]@{ Key; Label; Relative;
  ExcludeFiles }` (ExcludeFiles only set for outlook = `@('*.ost')`). Detection is
  folder-existence under `<root>\<userName>\<Relative...>`.
- Selection: interactive - after the existing folder multi-select, build the union
  of detected app targets across the selected users and show a multi-select
  "Detected application data (optional)". Non-interactive: add `-BackupApps
  string[]` to the top param block and plumb it through (mirror `-BackupFolders`).
  The plan includes an app target for a given user only if that user has it.
- Plan items: add two fields to EACH backup plan item - `Relative` (the relative
  path used; for standard folders it is the catalog Relative, for app targets the
  app Relative) and `ExtraExcludeFiles` (per-item, e.g. `*.ost`; empty for normal
  folders). Source = `<profile>\<Relative>`, Dest = `<destRoot>\<user>\<Relative>`
  (so the relative structure is preserved and restore can place it back).
- Robocopy: in the backup loop, pass the global exclusions PLUS the item's
  `ExtraExcludeFiles` to `Invoke-WinPulseRobocopy -excludeFiles`. Do not change
  the wrapper's signature unless needed.
- Manifest: record the selected app keys (e.g. `Apps = @($appKeys)`) and make sure
  each item carries its `Relative` so restore/verify can use it.
- Restore round-trip: `New-WinPulseRestorePlan` must use the manifest item's
  `Relative` when present for BOTH source and target (fallback to the catalog /
  folder name when an older manifest has no Relative, so existing backups still
  restore). App data then restores to its original relative location.
- Verify round-trip: `Get-WinPulseManifestItemBackupPath` must also prefer the
  item's `Relative` when present (fallback as today).
- Safety note in the manifest: browser profiles include the user's
  DPAPI-encrypted credential store; this is an explicit per-app opt-in and the
  encrypted data does not decrypt on another account/machine.

Acceptance (non-elevated, temp fixtures):

- Build a fixture profile with fake `AppData\Local\Google\Chrome\User Data\...`,
  `AppData\Roaming\Mozilla\Firefox\Profiles\...`, and
  `AppData\Local\Microsoft\Outlook\` containing a `test.pst`, a `RoamCache\x.dat`,
  AND a `big.ost`. Run a non-interactive backup selecting `-BackupApps
  Chrome,Firefox,Outlook` and assert: Chrome/Firefox/Outlook data copied under
  the right relative paths in the destination, the `.ost` was NOT copied, exit 0.
- Restore that backup into a temp root and assert the app data lands back under
  the same relative paths (e.g. `<root>\<user>\AppData\Local\Google\...`).
- Run MigrationVerify on the backup -> Intact.
- Without `-BackupApps` and with no detected apps, behaviour is unchanged.
- Extend the smoke test to cover the above. Parser + ASCII clean; existing
  Backup/Restore/Verify smoke still exit 0.

Out of scope: decrypting/transforming any app data, deduplicating Chrome cache,
TUI rendering-engine changes (adding selection items reuses the existing menu).

### Task C15 - Capture the installed-app list at backup (for winget reinstall)

Status: DONE - implemented by Codex (`Invoke-WinPulseBackupAppCapture`: non-fatal
`apps\installed-apps.json` + best-effort `winget export`, manifest `AppCapture`,
execute-only, additive - not in plan/items/counts), reviewed by Claude. (Kept
below for reference.)

Why: at backup time, capture which apps are installed so a later restore can
offer to reinstall them via winget on the new machine. This task is ONLY the
capture (read-only inventory + `winget export`). The reinstall offer is C16.

Scope:

- On an EXECUTED backup only (not dry-run), best-effort capture into a new
  `<destinationRoot>\apps\` folder:
  - `winget-packages.json` via `winget export -o <file> --accept-source-agreements`
    (this is the importable list with package IDs). Only if winget is available
    (reuse the existing winget detection, e.g. `Test-WinGetAvailable` /
    `Find-WinPulseExecutable`). winget export does NOT require elevation.
  - `installed-apps.json` from the existing inventory
    (`Get-WinPulseMigrationApplicationInventory` or `Get-WinPulseSoftwareInventory`)
    - this covers apps winget does not know, for manual follow-up.
- Make the whole capture wrapped in try/catch and NON-FATAL: a failure (winget
  missing, export error) must not fail the backup. Record the outcome in the
  manifest as e.g. `AppCapture = [pscustomobject]@{ WingetAvailable=$bool;
  WingetExportFile='apps\winget-packages.json' or $null; InventoryFile=
  'apps\installed-apps.json' or $null; Note='...' }`.
- Do not change the file-copy flow, the existing `-BackupApps` (app DATA) feature,
  or any verification. This is additive: a sidecar `apps\` folder + one manifest
  field. The apps folder is NOT a copied user folder, so it must not appear in
  the plan/items or counts.
- Note in a manifest SafetyNote that the captured list reveals installed software
  names but contains no secrets.

Acceptance (non-elevated, temp fixtures):

- An executed fixture backup creates `<dest>\apps\installed-apps.json` and, when
  winget is present, `<dest>\apps\winget-packages.json` that parses as JSON; the
  manifest has an `AppCapture` field. When winget is absent, the backup still
  succeeds, `WingetAvailable=$false`, and `WingetExportFile=$null` (no throw).
- A dry-run backup does NOT write the apps folder.
- Existing Backup/Restore/Verify smoke still exit 0 (the new apps sidecar must not
  break verification counts). Extend the backup smoke to assert the AppCapture
  field and the installed-apps.json file.

Out of scope: any installing/reinstalling (that is C16), choco/Store capture,
parsing or transforming the winget export.

### Task C16 - Offer winget reinstall from a backup's captured app list

Status: DONE - implemented by Codex (`MigrationApps` mode, `-AppsBackupPath/
-AppsExecute/-AppsSelect`, parse winget export, multi-select, dry-run default
that provably never invokes winget install, execute only after -AppsExecute/YES,
call operator not Invoke-Expression), reviewed by Claude. The live `winget
install` is owner-verified; dry-run is smoke-covered. (Kept below for reference.)

Why: after C15 captures `apps\winget-packages.json` at backup, let the technician
reinstall those apps via winget on the new machine. Owner-approved decisions
(FIXED): (1) granular multi-select of which apps to install, NOT a blind
`winget import`; (2) a SEPARATE action in the Migration submenu, not baked into
the file restore; (3) winget only for v1; (4) install runs only after explicit
confirmation (dry-run by default).

TESTABILITY BOUNDARY (important): the parse / selection / command-build /
dry-run path is fully Codex-testable non-elevated and MUST be covered by smoke.
The actual `winget install` execution needs admin + network + winget and is
OWNER-verified - Codex must NOT run a real install in tests and must NOT claim it
did. Structure the code so dry-run never invokes winget install.

Scope:

- New mode `MigrationApps` in every `-Mode` ValidateSet (top param block,
  `Invoke-WinPulseMode`, smoke wrapper), an `Invoke-WinPulseMode` switch case, and
  ONE item in the Migration submenu (`Show-WinPulseMigrationMenu`, e.g. key 'A'
  "Reinstall apps"). Add `MigrationApps` to the auto-elevate list (it installs)
  and to the elevation passthrough, mirroring the other modes.
- Params (top block + plumbed through): `-AppsBackupPath <string>` (the backup
  folder, the one whose `apps\winget-packages.json` to read), `-AppsExecute
  <switch>` (install for real; absent = dry-run), optional `-AppsSelect
  <string[]>` (package IDs to install; non-interactive default = all parsed IDs).
- `Invoke-WinPulseMigrationAppReinstall`:
  - Pick the backup (non-interactive `-AppsBackupPath`; interactive: reuse the
    `Get-WinPulseAvailableBackups` selection like restore/verify).
  - Read `<backup>\apps\winget-packages.json`, parse package IDs robustly under
    StrictMode: iterate `$data.Sources[].Packages[].PackageIdentifier`, guarding
    every property with `PSObject.Properties[...]`; dedupe + sort. If the file is
    missing/empty/invalid, message and return (no throw).
  - Show a multi-select of the IDs (interactive) or use `-AppsSelect` / all
    (non-interactive).
  - DRY-RUN (default): print the apps and the exact `winget install` command that
    WOULD run for each, write a record, and DO NOT call winget. Exit cleanly.
  - EXECUTE (`-AppsExecute` or an interactive YES): ensure winget is present
    (reuse `Ensure-WinGet` / the existing winget detection); for each selected ID
    run `winget install --id <id> -e --accept-package-agreements
    --accept-source-agreements` via the call operator (capture exit code per app),
    report per-app OK/failed, write the record. Never use Invoke-Expression.
  - Write a `migration-apps.json` record (Action DryRun/Execute, per-app results,
    counts) under a record folder using the same non-elevated fixture-safe record
    location pattern restore/verify already use.
  - Return an object with the selected/installed/failed counts.

Acceptance (non-elevated, temp fixtures - DRY-RUN only):

- Create a fixture backup folder containing
  `apps\winget-packages.json` with a couple of known IDs (e.g. a minimal valid
  winget export: `{"Sources":[{"Packages":[{"PackageIdentifier":"Foo.Bar"},
  {"PackageIdentifier":"Baz.Qux"}]}]}`). Run
  `bootstrap.ps1 -Mode MigrationApps -AppsBackupPath <backup>` (NO -AppsExecute):
  it parses both IDs, writes a DryRun `migration-apps.json` listing them and the
  would-run commands, calls NO winget install, exit 0.
- A bad/missing `winget-packages.json` is handled gracefully (message, no throw).
- Parser + ASCII clean; existing Backup/Restore/Verify smoke still exit 0; add a
  `MigrationApps` dry-run smoke mode.
- Do NOT add a smoke assertion that requires a real install.

Out of scope: choco/Microsoft Store reinstall, mapping winget IDs to friendly
names, upgrading vs installing, anything that runs a real install in tests.

### Task C17 - Human reports for MigrationVerify and MigrationApps

Status: DONE - implemented by Codex (HTML + text reports for both modes via a
shared `Get-WinPulseMigrationReportCss` + the existing table/KV helpers; apps
report driven by the dry-run path with a "nothing installed" note), reviewed by
Claude. Additive (240 insertions, 0 deletions); smoke asserts the new reports.
(Kept below for reference.)

Why: MigrationBackup and MigrationRestore write an HTML + text report next to
their JSON; MigrationVerify and MigrationApps only write JSON. Add matching
human-readable reports so a technician can read the outcome at a glance.

Scope:

- MigrationVerify (`Invoke-WinPulseMigrationVerify`): next to
  `migration-verify.json`, also write `migration-verify-report.html` and
  `migration-verify-report.txt`. Content: header (machine, generated time,
  WinPulse version, backup root), a summary (Intact / Drift / Skipped counts),
  and a per-item table (User, Folder, Status, recorded vs current files/bytes,
  Note). Drift rows should stand out (e.g. the attention/warn style).
- MigrationApps (`Invoke-WinPulseMigrationAppReinstall`): next to
  `migration-apps.json`, also write `migration-apps-report.html` and
  `migration-apps-report.txt`. Content: header (machine, time, version, backup
  root, Action DryRun/Execute), a summary (Selected / Installed / Failed /
  DryRun counts), and a per-package table (PackageId, Result OK/FAILED/DRY-RUN,
  ExitCode, the winget command). For a dry run make clear nothing was installed.
- REUSE the existing report helpers/styling: `ConvertTo-WinPulseHtmlText`,
  `ConvertTo-WinPulseMigrationHtmlTable`, `Add-WinPulseMigrationHtmlKv`, and the
  same CSS chrome the backup/restore HTML report uses (a small shared page
  wrapper helper is fine if it avoids copy-paste). Keep it ASCII-only and
  StrictMode-safe. Do not change the JSON records, the copy/verify/install
  logic, or any counts.

Acceptance (non-elevated, temp fixtures):

- After a MigrationVerify run the verify record folder contains
  `migration-verify-report.html` and `.txt`; both reflect the intact/drift items.
- After a MigrationApps DRY-RUN run the apps record folder contains
  `migration-apps-report.html` and `.txt` listing the selected packages and the
  would-run commands, and stating nothing was installed.
- Extend the MigrationVerify and MigrationApps smoke modes to assert the two new
  report files exist. Parser + ASCII clean; all existing smoke modes still exit 0.
- Do NOT run a real winget install; the apps report must be produced from the
  dry-run path.

Out of scope: changing the JSON schema, TUI rendering, the copy/install logic.

### Task C18 - Make the installed-software-list capture a visible backup choice

Why: today `Invoke-WinPulseBackupAppCapture` runs on EVERY executed backup with no
way to decline it (and `winget export` adds ~5-15s). The owner wants it as a
visible, declinable choice that stays ON by default (decision A).

Scope:

- Add `-SkipBackupAppList` switch to the top `param()` block and plumb it through
  `Invoke-WinPulseMode` to `Invoke-WinPulseMigrationBackup` and the elevation
  passthrough (mirror the existing backup switches like `-BackupHashSample`).
- In `Invoke-WinPulseMigrationBackup` compute `$captureAppList`:
  - Non-interactive: `$captureAppList = -not $SkipBackupAppList` (so the default,
    with no switch, still captures - keeps current behaviour).
  - Interactive: ask once, default YES. Use a small 2-item single-select with
    "Yes" first (so Enter keeps it on), e.g. title "Capture the installed
    software list (for later winget reinstall)?" with Yes/No. Treat Esc/null as
    Yes (the default-on intent).
- Gate the capture on it: change the existing `if (-not $dryRun) { ...capture... }`
  to `if (-not $dryRun -and $captureAppList) { ...capture... }`. When not
  captured, `AppCapture` stays `$null` in the manifest (already nullable) and the
  `apps\` folder is not created.
- Surface it: show a line in the plan/summary area (near the opt-in scope / app
  targets display) like "Installed software list: yes" / "no", and in the
  "repeat this without prompts" command append `-SkipBackupAppList` when it was
  declined.
- Do NOT change `Invoke-WinPulseBackupAppCapture` itself, the copy flow, app DATA
  (`-BackupApps`), verification, or any counts.

Acceptance (non-elevated, temp fixtures):

- Default (no `-SkipBackupAppList`): an executed backup still writes
  `apps\installed-apps.json` and a non-null `AppCapture` (existing C15 smoke must
  still pass unchanged).
- With `-SkipBackupAppList`: the executed backup writes NO `apps\` folder and
  `AppCapture` is `$null`; exit 0.
- Add a smoke assertion for the skip case. Parser + ASCII clean; all migration
  smoke modes still exit 0.

Out of scope: changing what the capture collects, the report files, TUI rendering.

### Task C19 - MigrationApps: per-package result Status field and AlreadyInstalled count in record/report

Why: the install loop (as of 2026-06-03) correctly treats "already installed"
winget output as success (`$wasAlreadyInstalled`), but the JSON record and
HTML/text report do not distinguish "newly installed", "already installed", and
"failed" - all collapse into Success true/false. Owner wants AlreadyInstalled
visible separately so a re-run on the same machine produces a clear summary.

Scope:

- Add a `Status` string to each per-package result object (alongside the
  existing `Success`, `ExitCode`, `DryRun`, `Note` fields):
    - `'DryRun'`            when $dryRun
    - `'Installed'`         when exitCode 0 (fresh install)
    - `'AlreadyInstalled'`  when $wasAlreadyInstalled (non-zero exit but
                            "already installed" / "no applicable upgrade" text)
    - `'Failed'`            otherwise
  Do NOT change $success or $wasAlreadyInstalled logic.
- Add `AlreadyInstalledCount` to the record object (alongside InstalledCount,
  FailedCount, DryRunCount) and to the summary line in the text report:
  "Summary: Selected X | Installed Y | AlreadyInstalled Z | Failed W | DryRun V".
- HTML report: add a Status column (or replace the existing Result column if
  one exists). Style: green for Installed, muted green for AlreadyInstalled,
  red for Failed, grey for DryRun. Reuse the existing CSS classes from the
  backup/restore HTML reports.
- Text report: show the Status string per package.
- Do NOT change: the $success/$wasAlreadyInstalled logic, the nonInteractive
  path, -AppsSelect, the interactive selection block, the console output (the
  OK / Already installed / FAILED lines), or any other mode's code.

Acceptance (non-elevated, dry-run only):

- After a MigrationApps dry-run, `migration-apps.json` has an
  `AlreadyInstalledCount` field (0 for dry-run; all items Status='DryRun').
- HTML and text reports contain "AlreadyInstalled" in per-item output and
  summary.
- Extend the MigrationApps smoke to assert `AlreadyInstalledCount` exists in
  the JSON record (0 for dry-run is correct).
- Parser + ASCII clean; all existing smoke modes still exit 0.

Out of scope: real winget install in tests, changing interactive menus or
console output, touching other modes.

### Task C21 - Battery health row in dashboard

Why: technicians need to know battery wear before recommending a battery swap or
before working with storage/boot on a device that might shut down unexpectedly.
The data is already collected in `$scan.HardwareDetail.Battery` by
`Get-WinPulseHardwareDetail` (called in `Invoke-CoreScan`, line ~1489) — nothing
new to collect, just display it.

`$scan.HardwareDetail.Battery` fields (all may be null on desktops):
  - `Present`              bool   — true only if Win32_Battery found a battery
  - `HealthPercent`        double — FullChargedCapacity / DesignedCapacity * 100
  - `DesignCapacityWh`     double — original design capacity in Wh
  - `FullChargeCapacityWh` double — current max charge in Wh
  - `CycleCount`           int    — charge cycles (may be null if unavailable)

Scope:

- In `Show-WinPulseDashboard` (inside `bootstrap.ps1`), after the Drivers row
  and before the findings separator, add a conditional Battery row:

  ```powershell
  if ($scan.HardwareDetail -and $scan.HardwareDetail.Battery.Present) {
      $bat       = $scan.HardwareDetail.Battery
      $batState  = if (-not $bat.HealthPercent) { 'OK' } `
                   elseif ($bat.HealthPercent -lt 60) { 'Critical' } `
                   elseif ($bat.HealthPercent -lt 80) { 'Warning' } `
                   else { 'OK' }
      $batHColor = switch ($batState) { 'Critical'{'Red'} 'Warning'{'Yellow'} default{'Gray'} }
      $batSegs   = [System.Collections.Generic.List[hashtable]]::new()
      if ($bat.HealthPercent) {
          $batSegs.Add(@{ Text = 'Health {0}%' -f $bat.HealthPercent; Color = $batHColor })
      }
      if ($bat.DesignCapacityWh -and $bat.FullChargeCapacityWh) {
          $batSegs.Add(@{ Text = ' | '; Color = 'Gray' })
          $batSegs.Add(@{ Text = '{0} / {1} Wh' -f $bat.FullChargeCapacityWh, $bat.DesignCapacityWh; Color = 'Gray' })
      }
      if ($bat.CycleCount) {
          $batSegs.Add(@{ Text = ' | Cycles {0}' -f $bat.CycleCount; Color = 'Gray' })
      }
      if ($batSegs.Count -gt 0) {
          Write-WinPulseDashboardSegLine -Label 'Battery' -State $batState -Segments $batSegs.ToArray()
      }
  }
  ```

- Also update `Get-WinPulseTriageFindings` (line ~2417): the existing finding
  fires at HealthPercent < 50 with Severity Warning. Add a second finding for
  HealthPercent < 30 with Severity Critical ("Battery critically degraded: X%").
  Keep the existing <50 finding as Warning.

- Do NOT change: the battery data collection, HardwareDetail, any other row,
  or any non-dashboard code.

Acceptance (non-elevated, temp fixtures):

- On a desktop fixture (no battery), the Battery row must NOT appear and smoke
  must exit 0. The existing smoke test already covers this implicitly — just
  verify it still passes.
- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes still exit 0.
- Visual check (Claude): run on a real laptop with a battery and confirm the row
  appears with correct colors (green/yellow/red based on health).

Out of scope: current charge level (%), charging status, per-cell data, any
change to how battery data is collected.

### Task C20 - TUI folder picker for backup destination and restore root

Why: technicians picking a backup target or source have to type a path from
memory (`E:\Backups\Petr`). A folder browser lets them navigate drives and
directories with arrow keys and pick the folder visually. Manual typing must
stay available as a fallback (for UNC paths, etc.).

**IMPORTANT - visual verification required.** This task changes live TUI
rendering. Build it on `dev`, validate parser + ASCII + all smoke modes, then
report. Claude will confirm visually on a real terminal before merging to main.
Do NOT push to main until Claude approves.

#### New function: `Select-WinPulseFolderPath`

Add `Select-WinPulseFolderPath` near the other `Select-WinPulse*` helpers.

Signature:
```powershell
function Select-WinPulseFolderPath {
    param(
        [string]$Title = 'Select folder',
        [string]$StartPath = $null   # optional; defaults to drives list
    )
    # Returns: selected path string, or $null if cancelled
}
```

Behaviour:

- **Start view** (when `$StartPath` is null or empty): list available filesystem
  drives from `Get-PSDrive -PSProvider FileSystem | Sort-Object Name`. Each
  drive is shown as e.g. `C:\`, `D:\`, `E:\`. Arrow keys + Enter navigates into
  that drive root.
- **Directory view**: show items in this order:
  1. `[Select this folder]` — Enter on this item returns the current path.
  2. `..  (go up)` — Enter goes to parent; at a drive root, goes back to drives
     list. Omit this item when showing the drives list.
  3. Sorted subdirectories of the current path (via
     `Get-ChildItem -LiteralPath $current -Directory -ErrorAction SilentlyContinue`).
     If the listing fails (access denied etc.), show a one-line note and treat
     the folder as having no children, but keep `[Select this folder]` active.
- **Keyboard:**
  - `↑`/`↓` — move cursor (viewport-scroll if list is long; reuse the
    `$maxViewport` / `$viewTop` pattern from `Select-WinPulseMultiMenuItem`).
  - `Enter` — navigate into directory, or confirm `[Select this folder]`, or
    go up from `..`.
  - `Esc` — cancel, return `$null`.
  - `T` (or `M`) — switch to a `Read-Host` prompt so the user can type any
    path (UNC, absolute, etc.). Validate that the typed path is non-empty;
    return it as-is (the caller validates existence if needed). If the user
    presses Enter on an empty string, re-show the picker.
- **Header**: the current path (or "Drives" for the start view) in the box
  title, using the existing WinPulse box style.
- **Help bar**: `↑/↓ Navigate  Enter Select/Open  T Type path  Esc Cancel`
- **Non-interactive fallback**: if `$Host.UI.RawUI.KeyAvailable` throws (i.e.
  non-interactive), fall back to a `Read-Host` prompt immediately (same guard
  pattern as the existing menus).

#### Plug-in points (three places, all in `bootstrap.ps1`)

Replace each interactive `Read-Host` path prompt with `Select-WinPulseFolderPath`.
Do NOT touch the non-interactive branches (they use params directly).

**1. Backup destination** (inside `Invoke-WinPulseMigrationBackup`, the `else`
branch around line 5198):
```powershell
# BEFORE:
$destInput = Read-Host '  Where to save the backup?  (Enter for default, or a path like E:\Backups\Name)'
$destinationRoot = if ([string]::IsNullOrWhiteSpace($destInput)) { $defaultRoot } else { $destInput.Trim() }

# AFTER:
$destPicked = Select-WinPulseFolderPath -Title 'Backup destination'
$destinationRoot = if ([string]::IsNullOrWhiteSpace($destPicked)) { $defaultRoot } else { $destPicked }
```
(Esc from the picker = use default, just like pressing Enter on the old prompt.)

**2. Restore root** (inside `Invoke-WinPulseMigrationRestore`, the `else`
branch around line 6391):
```powershell
# BEFORE:
$rootInput = Read-Host '  Restore into where?  (Enter for C:\Users)'
$restoreRoot = if ([string]::IsNullOrWhiteSpace($rootInput)) { 'C:\Users' } else { $rootInput.Trim() }

# AFTER:
$rootPicked = Select-WinPulseFolderPath -Title 'Restore root'
$restoreRoot = if ([string]::IsNullOrWhiteSpace($rootPicked)) { 'C:\Users' } else { $rootPicked }
```

**3. Manual backup-source path** — there are three identical `__manual__`
fallback blocks (in Restore, Verify, and Apps backup-source selection). Each
looks like:
```powershell
if (-not $selectedBackupRoot) {
    $manualInput = Read-Host '  Path to the backup folder (the one with manifest.json)'
    ...
    $selectedBackupRoot = $manualInput.Trim()
}
```
Replace the `Read-Host` line in each block with:
```powershell
$manualInput = Select-WinPulseFolderPath -Title 'Backup folder'
```
The surrounding null-check and cancellation logic stays unchanged.

#### Constraints

- Keep all non-interactive param paths (`-BackupDestination`, `-RestoreRoot`,
  `AppsBackupPath`, `VerifyBackupPath`) byte-for-byte unchanged.
- Do not add UNC / network share browsing — if the user needs a UNC path, `T`
  (type manually) is the escape hatch.
- ASCII-only, StrictMode-safe, PowerShell 5.1 compatible.
- `Get-ChildItem` errors (access denied, empty drive) must never crash the
  picker — catch and continue.
- Do not change any other function's behaviour.

#### Acceptance

- Parser clean, ASCII check empty, `git diff --check` clean.
- All four smoke modes exit 0 (smoke uses non-interactive params, so the
  picker is never called — this verifies nothing regressed).
- **Visual check (Claude does this before merge):** on a real terminal, the
  picker opens, shows drives, navigates into a subfolder, `[Select this folder]`
  returns the path, `T` falls through to typed input, `Esc` cancels with the
  default used, help bar is visible and correct.

Out of scope: UNC browsing, file-level picker, multiple-folder selection,
drive labels/sizes, clipboard paste, any non-path prompt.

### Task C22 - Fix powercfg battery report parsing (replace fragile regex)

Status: DONE - implemented by Codex (simpler all-mWh approach), reviewed by
Claude, verified on a real laptop: shows `[CRIT] Battery  Health 36.7% | 17.4 / 47.5 Wh`.


Why: the current powercfg fallback in `Get-WinPulseHardwareDetail` (inside
`bootstrap.ps1`, around line 587) consistently fails on real laptops and shows
"wear data unavailable". The root cause is a fragile regex that requires the
HTML table cells to be adjacent with no nested tags between them:

```
'(?i)<td[^>]*>[^<]*</td>[^<]*<td[^>]*>([\d\s,\.]+)\s*mWh</td>...'
```

`[^<]*` between `</td>` and `<td>` fails the moment there is ANY HTML tag
(whitespace element, attribute, newline with indentation that has been wrapped
in a tag, etc.) between the cells. powercfg HTML structure varies across Windows
versions, locales, and OEMs.

**Root cause analysis before you write a single line of code:**

First, add a temporary diagnostic block that writes what powercfg produces to
`$batteryInfo` as a `ParseDiag` key (or to a local variable you can inspect):

```powershell
# After [System.IO.File]::ReadAllText($tmpHtml):
$batteryInfo['ParseDiag'] = ('len={0} dcPos={1} mwhCount={2}' -f
    $html.Length,
    $html.IndexOf('DESIGN CAPACITY', [System.StringComparison]::OrdinalIgnoreCase),
    ([regex]::Matches($html, 'mWh')).Count)
```

Run WinPulse on the laptop, then read `ParseDiag` from a debug run to
understand the actual structure. Then remove the diagnostic before committing.

**Fix — replace the fragile table-row regex with a simpler two-step approach:**

Instead of matching the full table row structure, just:
1. Find the position of "DESIGN CAPACITY" in the HTML.
2. Take a 3000-char window starting there.
3. Find ALL occurrences of `(\d[\d,\.\s]*)\s*mWh` in that window.
4. The FIRST match is the design capacity value; the SECOND is the full charge
   capacity value. (In the report, design capacity column comes before full
   charge capacity column, both in the same data row, in document order.)
5. Strip non-digits, convert to int, divide by 1000 for Wh.

```powershell
$dcPos = $html.IndexOf('DESIGN CAPACITY', [System.StringComparison]::OrdinalIgnoreCase)
if ($dcPos -ge 0) {
    $window  = $html.Substring($dcPos, [math]::Min(3000, $html.Length - $dcPos))
    $mwhAll  = [regex]::Matches($window, '(\d[\d,\.\s]*)\s*mWh')
    if ($mwhAll.Count -ge 2) {
        $dc = [int]($mwhAll[0].Groups[1].Value -replace '[^\d]', '')
        $fc = [int]($mwhAll[1].Groups[1].Value -replace '[^\d]', '')
        if ($dc -gt 0 -and $fc -gt 0) {
            $batteryInfo.DesignCapacityWh    = [math]::Round($dc / 1000, 1)
            $batteryInfo.FullChargeCapacityWh = [math]::Round($fc / 1000, 1)
            $batteryInfo.HealthPercent        = [math]::Round(($fc / $dc) * 100, 1)
        }
    }
    # Cycle count: look for a plain integer in a <td> that follows the two mWh cells
    # (third data column). Only attempt if not already set by WMI.
    if (-not $batteryInfo.CycleCount -and $mwhAll.Count -ge 2) {
        $afterFc = $window.Substring($mwhAll[1].Index + $mwhAll[1].Length)
        $cycleM  = [regex]::Match($afterFc, '<td[^>]*>\s*(\d+)\s*</td>')
        if ($cycleM.Success) { $batteryInfo.CycleCount = [int]$cycleM.Groups[1].Value }
    }
}
```

Replace the current regex block (lines ~598-614) with this. Keep everything
else (file creation, ReadAllText, Remove-Item, outer try/catch) unchanged.

**Also verify:** ensure `powercfg` is actually producing the file. Add exit-code
capture and guard on non-zero exit:

```powershell
$null = & $pcfg /batteryreport /output $tmpHtml 2>&1
$pcfgOk = ($LASTEXITCODE -eq 0)
if ($pcfgOk -and (Test-Path -LiteralPath $tmpHtml)) { ... }
```

**Acceptance:**

- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0 (no battery on desktop = no change to smoke).
- The fix is self-contained to `Get-WinPulseHardwareDetail` in `bootstrap.ps1`.
- No other functions or modes touched.

Visual laptop check remains for Claude/owner: confirm battery row shows
`Health XX% | YY.Y / ZZ.Z Wh` instead of "wear data unavailable".

### Task C25 - Diagnostics menu replacing Findings & Details

Why: `Show-WinPulseFindingsDetail` (called by [F] in the Quick Triage menu) is
a flat wall of raw `Write-Host` output with no navigation, no consistent style,
and no way to drill into a specific section. Replace it with a proper navigable
diagnostics menu that reuses the existing WinPulse TUI infrastructure.

**IMPORTANT — visual verification required.** This task changes live TUI
rendering. Build on `dev`, run parser + ASCII + all smoke modes, then report.
Claude will confirm visually on a real terminal before merging to main.
Do NOT push to main until Claude approves.

#### New function: `Show-WinPulseDiagnosticsMenu`

Replace `Show-WinPulseFindingsDetail` entirely. Wire the new function in its
place (find all call sites of `Show-WinPulseFindingsDetail` and replace with
`Show-WinPulseDiagnosticsMenu -scan $scan`).

The function shows a `Select-WinPulseMenuItem`-based menu of 7 sections.
Each item has a badge-prefixed Label and a Hint with the one-line summary.
Loop until the user presses Esc or selects Back.

**Menu items** (Key, Label pattern, Hint content, badge state logic):

| Key | Label prefix | Hint | State |
|-----|-------------|------|-------|
| `F` | Findings | `N critical · M warning` or `No issues` | Critical if any Critical; Warning if any Warning; OK if none |
| `D` | Drivers | `N problematic · M unsigned` or `OK` | Warning if Problematic.Count > 0; OK otherwise |
| `V` | Services | `N failed auto-start` or `OK` | Warning if > 3; OK if ≤ 3 (noisy threshold) |
| `S` | System | `Hostname · OS build · Uptime` | OK |
| `H` | Hardware | `CPU model short · RAM · C:XX% · Battery XX%` | Critical/Warning based on disk/battery |
| `X` | Security | `AV name · FW ON/OFF · BL ON/OFF` | Critical if no AV/FW; OK otherwise |
| `N` | Network | `IP · GW · Net OK/FAIL` + WiFi if available | Warning if no internet |

Use `[CRIT]`/`[WARN]`/`[ OK ]` as the label prefix (NOT as the `Key` field —
Key is the single letter above). Example item:
```powershell
@{ Label = '[WARN] Drivers'; Key = 'D'; Hint = '2 problematic · 1 unsigned' }
```

Add a separator then:
```powershell
@{ Separator = $true }
@{ Label = 'Back'; Key = 'B'; Color = 'DarkGray' }
```

When the user selects a section (Enter), call the corresponding detail function
(see below). When Esc or 'B' → return.

#### Detail functions (one per section)

Each detail function:
- `Clear-Host`
- `Write-WinPulseHeader -title '<Section Name>'`
- Outputs content using plain `Write-Host` (keep existing formatting style —
  do NOT try to put everything in boxes, that would be a rendering-complexity
  risk)
- Calls `Wait-WinPulseKey` at the end

**`Show-WinPulseDiagnosticsFindings -scan $scan`**
Show ALL findings from `Get-WinPulseTriageFindings -scan $scan`, grouped:
Critical first (red `[CRIT]`), then Warning (yellow `[WARN]`). Format:
```
  [CRIT] System drive C: usage is above 90%.
  [WARN] Problematic device drivers: 2
  ...
  No issues detected.   ← if empty, green
```

**`Show-WinPulseDiagnosticsDrivers -scan $scan`**
Existing Problematic drivers + Unsigned drivers list from `$scan.Drivers`.

**`Show-WinPulseDiagnosticsServices -scan $scan`**
Existing FailedAutoServices list from `$scan.Startup`.

**`Show-WinPulseDiagnosticsSystem -scan $scan`**
Existing System Details block: Hostname, OS, Build, Uptime, CPU (cleaned model
name), RAM type/total, TPM version, BIOS version/date from
`$scan.HardwareDetail.Motherboard`.

**`Show-WinPulseDiagnosticsHardware -scan $scan`**
RAM usage, all disks (drive, size, free, used%), SMART status, temperatures if
available, battery health + charge + cycles if present.

**`Show-WinPulseDiagnosticsSecurity -scan $scan`**
AV products list, Firewall state, BitLocker volumes, Secure Boot state from
`$scan.Security` / `$scan.W11Readiness`.

**`Show-WinPulseDiagnosticsNetwork -scan $scan`**
IPv4, gateway, DNS servers, internet reachability, WiFi SSID/signal/channel/
band if available, all from `$scan.Network` and `$scan.NetworkDetail`.

#### Wire-up

Find all call sites of `Show-WinPulseFindingsDetail` and replace with
`Show-WinPulseDiagnosticsMenu -scan $scan` (there should be 1-2 call sites in
`Show-WinPulseTriageMenu`). Keep `Show-WinPulseFindingsDetail` in the file
as a fallback/reference but stop calling it.

#### Constraints

- Do NOT change the dashboard, the Quick Triage menu structure, or any other
  existing function.
- ASCII-only, StrictMode-safe, PS 5.1 compatible.
- All detail functions must null-guard every scan field (some may be null if
  collection failed).
- Do not add new WMI calls or scan logic — only use data already in `$scan`.

#### Acceptance

- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0.
- Visual check (Claude/owner): menu shows 7 sections with badges; each section
  opens a detail view; Esc/Back returns to menu; Esc from menu returns to
  Quick Triage; no crashes on sections with null data.

### Task C24 - Findings count in separator + current battery charge in Battery row

Two small additive dashboard improvements. Both are visually safe — no layout
risk. Do them in one commit.

#### Part A — Findings count in the separator line

Currently the separator between status rows and findings is:
```
╠══════════════════════════════════════════════╣
```
Change it to show the findings count:
```
╠══ Findings (5) ══════════════════════════════╣
```
When there are no findings: `╠══ No findings ══════════════════════════════╣`

In `Show-WinPulseDashboard` (around line 2366 — the findings separator
`Write-Host`), replace the plain `$hLine` with a labeled separator that embeds
the count. The findings array `$findings` is populated just after this line,
so compute the label AFTER `$findings = @(Get-WinPulseTriageFindings -scan $scan)`.
Move the separator `Write-Host` to just after that line.

```powershell
$findings = @(Get-WinPulseTriageFindings -scan $scan)
$fLabel   = if ($findings.Count -gt 0) { ' Findings ({0}) ' -f $findings.Count } else { ' No findings ' }
$fLine    = '{0}{1}{2}' -f ([string][char]0x2550 * 2), $fLabel, ([string][char]0x2550 * [math]::Max(1, $w - 4 - $fLabel.Length))
Write-Host ('  {0}{1}{2}' -f ([char]0x2560), $fLine, ([char]0x2563)) -ForegroundColor Yellow
```

Color: Yellow when `$findings.Count -gt 0`, Gray when 0.
Do NOT change anything else about the findings rendering.

#### Part B — Current charge % in Battery row

`Win32_Battery.EstimatedChargeRemaining` is the current charge level (0-100 %).
This is DIFFERENT from health — health is wear, charge is how full right now.

In `Get-WinPulseHardwareDetail` (`bootstrap.ps1`, in the battery collection
block around line 555), add `ChargePercent` to `$batteryInfo`:

```powershell
$batteryInfo['ChargePercent'] = $null
if ($battery) {
    ...existing code...
    $chg = $battery | Select-Object -ExpandProperty EstimatedChargeRemaining -ErrorAction SilentlyContinue
    if ($null -ne $chg) { $batteryInfo.ChargePercent = [int]$chg }
}
```

Also add `ChargePercent = $null` to the default stub at the top of
`$batteryInfo`.

In `Show-WinPulseDashboard`, in the Battery row block, append a charge segment
ONLY when non-null, AFTER the existing segments:

```powershell
if ($null -ne $bat.ChargePercent) {
    $chgColor = if ($bat.ChargePercent -le 20) { 'Red' } `
                elseif ($bat.ChargePercent -le 40) { 'Yellow' } `
                else { 'Gray' }
    $batSegs.Add(@{ Text = ' | {0}% charged' -f $bat.ChargePercent; Color = $chgColor })
}
```

Length: `| X% charged` = max 14 chars. Battery row base is ~35 chars max.
Combined stays well under 66. Safe.

**Acceptance:**
- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0.
- On a desktop (no battery), Battery row does not appear — unchanged.
- Findings separator shows `╠══ Findings (N) ══...╣` with count.
- Visual check (Claude/owner): separator label visible; battery charge visible
  on a laptop; no layout breakage.

### Task C23 - Add CPU load to Hardware row; add WiFi SSID+signal to Network row

**CRITICAL layout constraint:** Both additions must NEVER push the right box
border out of position. The value area in `Write-WinPulseDashboardSegLine` is
~66 chars (BoxWidth 88). If the total segment text exceeds this, the border
misaligns. Guard every addition with a `if ($total -le 66)` check or keep
individual additions short enough that the combined line stays under 55 chars
(leave headroom for all combinations). When in doubt, omit the optional segment
rather than risk overflow.

#### Part A — CPU load in Hardware row

**Data:** `Win32_Processor.LoadPercentage` (int, 0-100). Not currently in
`$scan.Hardware` — add it.

1. In `Invoke-CoreScan` (`bootstrap.ps1`, inside the hardware scan try-block
   around line 1340), add a CPU load query alongside the existing RAM/disk
   queries:

   ```powershell
   $cpuLoad = $null
   try {
       $cpuObj = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
       if ($cpuObj -and $cpuObj.PSObject.Properties['LoadPercentage'] -and $null -ne $cpuObj.LoadPercentage) {
           $cpuLoad = [int]$cpuObj.LoadPercentage
       }
   } catch {}
   ```

   Add `CpuLoadPercent = $cpuLoad` to the `$result.Hardware` ordered dict (line
   ~1388). Also add `CpuLoadPercent = $null` to the default stub at line ~1270.

2. In `Show-WinPulseDashboard`, in the Hardware row block, append a CPU load
   segment ONLY when the value is non-null:

   ```powershell
   if ($null -ne $scan.Hardware.CpuLoadPercent) {
       $cpuLColor = if ($scan.Hardware.CpuLoadPercent -ge 80) { 'Red' } `
                    elseif ($scan.Hardware.CpuLoadPercent -ge 60) { 'Yellow' } `
                    else { 'Gray' }
       $hwSegs.Add(@{ Text = ' | CPU {0}%' -f $scan.Hardware.CpuLoadPercent; Color = $cpuLColor })
   }
   ```

   Add this AFTER the temperature segment (which is already the last optional
   add). Keep the Add call on the `$hwSegs` List before `.ToArray()`.

   Current Hardware segments: `RAM X% | C: X% XGB | SMART OK` + optional
   `| CPU XC` (temp) = max ~55 chars. Adding `| CPU X%` (9 chars max) stays
   well under 66. Safe.

#### Part B — WiFi SSID + signal in Network row

**Data:** `$scan.NetworkDetail.WiFi` — already collected in `Invoke-CoreScan`
(line ~1599). Fields: `SSID` (string), `SignalPercent` (int or null).
`$scan.NetworkDetail` may be null if the network detail scan failed — guard it.

1. Convert the Network row from `Write-WinPulseDashboardLine` (plain string)
   to `Write-WinPulseDashboardSegLine` (segments). Replicate the same content
   as segments first, then conditionally append WiFi.

   ```powershell
   $netState = if ($scan.Network.Internet) { 'OK' } else { 'Warning' }
   $netSegs  = [System.Collections.Generic.List[hashtable]]::new()
   $netSegs.Add(@{ Text = [string]$scan.Network.IPv4; Color = 'Gray' })
   $netSegs.Add(@{ Text = ' | GW {0}' -f $scan.Network.Gateway; Color = 'Gray' })
   $netSegs.Add(@{ Text = ' | Net {0}' -f $(if ($scan.Network.Internet) { 'OK' } else { 'FAIL' }); Color = $(if ($scan.Network.Internet) { 'Gray' } else { 'Red' }) })
   if ($scan.NetworkDetail -and $scan.NetworkDetail.WiFi -and $scan.NetworkDetail.WiFi.SSID) {
       $ssid = [string]$scan.NetworkDetail.WiFi.SSID
       if ($ssid.Length -gt 15) { $ssid = $ssid.Substring(0, 15) }
       $sig  = $scan.NetworkDetail.WiFi.SignalPercent
       $wifiText = if ($sig) { ' | WiFi: {0} {1}%' -f $ssid, $sig } else { ' | WiFi: {0}' -f $ssid }
       $wifiColor = if ($sig -and $sig -lt 40) { 'Red' } elseif ($sig -and $sig -lt 70) { 'Yellow' } else { 'Gray' }
       $netSegs.Add(@{ Text = $wifiText; Color = $wifiColor })
   }
   Write-WinPulseDashboardSegLine -Label 'Network' -State $netState -Segments $netSegs.ToArray()
   ```

   Length check: base Network value is ~46 chars. WiFi addition max:
   ` | WiFi: 123456789012345 100%` = 29 chars. Total max = 75 chars > 66.
   Add a guard: only add WiFi segment when `$ssid.Length + 16 + (total so far) -le 62`:

   ```powershell
   $baseLen = ($netSegs | ForEach-Object { ([string]$_['Text']).Length } | Measure-Object -Sum).Sum
   if (($baseLen + $wifiText.Length) -le 62) {
       $netSegs.Add(@{ Text = $wifiText; Color = $wifiColor })
   }
   ```

   When the combined line would overflow, silently omit the WiFi segment.

**Do NOT change:** any other dashboard row, any non-dashboard code, smoke tests,
the existing segment infrastructure.

**Acceptance:**
- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0.
- On a machine with no WiFi, Network row looks identical to today.
- On a machine under low CPU load, Hardware row shows `| CPU X%` in gray.
- Visual check (Claude/owner): confirm layout is intact at >= 90 columns on
  both WiFi and non-WiFi machines; no right-border misalignment.

### Task C26 - Problematic PnP devices: triage finding + Diagnostics surface

Why: a device in Windows error state (yellow/red exclamation in Device Manager)
is a direct indicator that a driver or hardware component is broken.
`pnputil /enum-devices /problem /ids` returns exactly these devices in one shot.
WinPulse already shows driver counts in the Diagnostics Drivers section (C25) but
has no explicit finding for error-state devices. This task makes it a triage signal.

Scope:

- In `Invoke-CoreScan`, inside the drivers scan block that populates `$scan.Drivers`,
  add a pnputil call and store the results:

  ```powershell
  $problemDevices = @()
  try {
      $pnpOut = & pnputil /enum-devices /problem /ids 2>$null
      if ($LASTEXITCODE -eq 0 -and $pnpOut) {
          $problemDevices = @($pnpOut |
              Where-Object { $_ -match '^\s*Instance ID:\s+(.+)$' } |
              ForEach-Object { $Matches[1].Trim() })
      }
  } catch {}
  ```

  Add `ProblemDevices = $problemDevices` to `$result.Drivers` (follow the same
  pattern as the existing `Problematic` / `Unsigned` fields). Also add
  `ProblemDevices = @()` to the default/stub at the top of the drivers block.

- In `Get-WinPulseTriageFindings`, add a finding when
  `$scan.Drivers.ProblemDevices.Count -gt 0`:

  ```
  Severity: Warning
  Message: "X device(s) in error state: <ID1>, <ID2>..."
  ```

  Cap the inline ID list at 2 entries; if more, append "... (see Diagnostics)".
  Null-guard: skip if `$scan.Drivers` or `$scan.Drivers.ProblemDevices` is null.

- In `Show-WinPulseDiagnosticsDrivers` (the detail function added in C25), after
  the existing problematic/unsigned driver lists, add a "Devices in error state"
  block:
  - If `$scan.Drivers.ProblemDevices.Count -gt 0`, list each instance ID with a
    `[WARN]` prefix (yellow).
  - If empty, print "  No PnP error-state devices." in gray.

Acceptance (non-elevated, temp fixtures):

- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0. pnputil absent or returning empty must not throw.
- On a clean machine: no problem devices -> no extra finding; Diagnostics Drivers
  shows "No PnP error-state devices."
- Smoke: run MigrationPreflight / Triage fixtures — both exit 0 even when pnputil
  returns nothing (test the guard, not real hardware).

Out of scope: device detail beyond the instance ID, driver repair actions, inf
copy, any TUI rendering engine changes.

### Task C27 - Crash dump detection finding

Why: the presence of minidump or full memory dump files is strong evidence of
recent blue-screen crashes. A technician triaging an unstable machine should see
this immediately in the findings. Detection is read-only and cheap.

Scope:

- In `Invoke-CoreScan`, add a dump detection block (place it near the system /
  OS info collection, before the hardware scan). Store results in `$result`:

  ```powershell
  $dumpInfo = [ordered]@{
      MinidumpCount  = 0
      MinidumpNewest = $null
      FullDumpExists = $false
  }
  try {
      $mdPath = Join-Path $env:SystemRoot 'Minidump'
      if (Test-Path -LiteralPath $mdPath -ErrorAction SilentlyContinue) {
          $mdFiles = @(Get-ChildItem -LiteralPath $mdPath -Filter '*.dmp' `
                       -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
          $dumpInfo['MinidumpCount']  = $mdFiles.Count
          if ($mdFiles.Count -gt 0) { $dumpInfo['MinidumpNewest'] = $mdFiles[0].LastWriteTime }
      }
      $dumpInfo['FullDumpExists'] = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'memory.dmp') `
                                              -ErrorAction SilentlyContinue
  } catch {}
  ```

  Add `DumpInfo = $dumpInfo` to `$result.System` (or wherever OS/boot facts live;
  check the existing scan object shape and follow its pattern). Also add a
  `DumpInfo = $null` stub in the default/empty result so null-guards are consistent.

- In `Get-WinPulseTriageFindings`, add findings:
  - If `MinidumpCount -gt 0`: Warning — "X minidump(s) found (newest: <date>).
    Machine may have crashed recently."
  - If `FullDumpExists`: Warning — "Full memory dump found in Windows root.
    Machine has had a kernel crash."
  Null-guard both against a null DumpInfo.

- In `Show-WinPulseDiagnosticsSystem` (the System detail from C25), after the
  OS/uptime/TPM block, add a Crash Dumps section:
  - "Crash dumps: X minidump(s), newest <date>" or "No crash dumps found" (green/gray).
  - "Full memory dump: Yes / No".

Non-admin note: `Test-Path` + `Get-ChildItem` on `C:\Windows\Minidump` may fail
without elevation. WinPulse auto-elevates, but wrap entirely in try/catch so a
permission error never crashes the scan — partial data (e.g. only FullDumpExists
checked) is acceptable.

Acceptance (non-elevated, temp fixtures):

- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0. Test-Path / Get-ChildItem on non-existent paths
  must not throw.
- Smoke: fixture has no dump files -> `MinidumpCount = 0`, no finding, System
  section shows "No crash dumps found." Entire block in try/catch so even a
  blocked directory does not fail the scan.

Out of scope: reading or analysing dump file contents, uploading dumps, WER
integration, any admin-only copy action.

### Task C28 - Select-all / deselect-all shortcut in multi-select menus

Why: multi-select menus (backup folder/user/app selection, etc.) have no way to
quickly toggle all items. A single keypress to select or deselect everything
saves time when a technician wants to start from "all on" or "all off".

Scope:

- In `Select-WinPulseMultiMenuItem` (the function that drives all multi-select
  menus in bootstrap.ps1), inside the key-dispatch loop, add a case for `A`:

  ```powershell
  'A' {
      $allSelected = @($menuItems | Where-Object { -not $_.Separator -and $_.Selected }).Count -eq @($menuItems | Where-Object { -not $_.Separator }).Count
      foreach ($item in $menuItems) {
          if (-not $item.Separator) { $item.Selected = -not $allSelected }
      }
  }
  ```

  Logic: if every non-separator item is already selected, deselect all;
  otherwise select all. One press toggles the whole list either way.

- Update the help bar line inside `Select-WinPulseMultiMenuItem` to include
  the new shortcut, e.g.:
  `Space Toggle  A All/None  Enter Confirm  Esc Cancel`

- Do NOT change any other key handler, the scroll/viewport logic, the item
  rendering, or any other function.

Acceptance (non-elevated, no visual check required for logic; visual check
for help bar):

- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0 (smoke drives non-interactive paths, multi-select
  is not exercised — this just confirms nothing regressed).
- Code review: confirm the new `A` case does not touch any existing case and
  that the help bar string is ASCII-only and fits within the box width (88 chars).

Out of scope: single-select menus (`Select-WinPulseMenuItem`), Ctrl+A, any
change to menu rendering beyond the help bar text.

### Task C29 - Reduce services-finding noise: whitelist and threshold

Why: the triage finding "Failed auto-start services: N" fires when more than 3
auto-start services are stopped. Update agents (Google, Edge), telemetry
(DiagTrack), and on-demand services (Maps, Smart Card) are routinely stopped on
managed or user-configured machines and do not indicate a real problem. The
finding produces noise that distracts from genuine issues.

Scope:

- Add a `$script:WinPulseServiceNoiselist` array near the version/color constants
  at the top of `bootstrap.ps1`:

  ```powershell
  $script:WinPulseServiceNoiselist = @(
      'DiagTrack', 'dmwappushservice', 'DoSvc',
      'edgeupdate', 'edgeupdatem',
      'gupdate', 'gupdatem',
      'MapsBroker', 'SCardSvr', 'sppsvc',
      'MozillaMaintenance', 'AdobeARMservice', 'Fax', 'WbioSrvc'
  )
  ```

- In `Get-WinPulseTriageFindings`, replace the existing services finding block:

  ```powershell
  if ($scan.Startup -and $scan.Startup.FailedAutoServices) {
      $problematic = @($scan.Startup.FailedAutoServices | Where-Object {
          $n = [string]$_['Name']
          ($n -notin $script:WinPulseServiceNoiselist) -and ($n -notlike 'GoogleUpdater*')
      })
      if ($problematic.Count -gt 5) {
          $findings += [pscustomobject]@{
              Severity = 'Warning'
              Message  = ('Failed auto-start services: {0} (of {1} total stopped)' -f
                          $problematic.Count, $scan.Startup.FailedAutoServices.Count)
          }
      }
  }
  ```

  Key changes: filter out known-noisy services; raise threshold from 3 to 5;
  include total count in message for context.

- In `Show-WinPulseDiagnosticsServices` (Services detail from C25), add a note
  below the failed services list showing how many were hidden:

  ```powershell
  $noisy = @($scan.Startup.FailedAutoServices | Where-Object {
      $n = [string]$_['Name']
      ($n -in $script:WinPulseServiceNoiselist) -or ($n -like 'GoogleUpdater*')
  })
  if ($noisy.Count -gt 0) {
      Write-Host ('  ({0} update/telemetry/on-demand services hidden - likely benign)' -f
                  $noisy.Count) -ForegroundColor DarkGray
  }
  ```

- Do NOT change `Get-WinPulseStartupAnalysis` - it still collects all failed
  auto-start services. Filtering is only in findings and display.

Acceptance (non-elevated, no visual check needed):

- Parser clean, ASCII check empty, git diff --check clean.
- All four smoke modes exit 0.
- Code review: whitelist is at script scope; filter uses `-notin` (not `-ne`);
  threshold is 5; hidden-services note appears only when `$noisy.Count -gt 0`.

Out of scope: changing what `Get-WinPulseStartupAnalysis` collects, filtering by
DisplayName, adding more services to the whitelist beyond those listed above.

### Task C30 - Live Migration (pull from remote PC via SMB C$)

Why: a technician setting up a new PC wants one guided workflow — enter the old
PC's hostname, pick users and folders, confirm — and WinPulse pulls the data
over the network and drops it into the new machine's C:\Users. No manual steps,
no separate backup-then-restore dance. This is a new first-class mode built on
top of the existing backup and restore engines.

#### Safety boundaries (FIXED — do not change without asking Claude)

- Use the technician's current Windows token (transparent Kerberos/NTLM auth).
  No `Get-Credential`, no `New-SmbMapping`, no credential prompts.
- No PSRemoting (`Enter-PSSession`, `Invoke-Command`), no remote WMI execution.
  The copy is purely SMB file I/O — robocopy over `\\HOST\C$\Users`. No code
  runs on the remote host.
- Locked files on a live source PC (NTUSER.DAT, open browser DBs, open OST
  files) will silently fail to copy. This is expected and acceptable for a live
  machine. Show a clear note in the plan; do not treat it as a failure.
- The remote UNC root must be `\\HOSTNAME\C$\Users`. Reject anything that does
  not produce this form.
- The local temp backup is kept after migration so the technician can verify
  or re-run restore. Never auto-delete it.

#### Overview of the new mode

```
MigrationLive
  Invoke-WinPulseMigrationLive
    Step 1  Get remote hostname (interactive prompt or -LiveSourceHost param)
    Step 2  Reachability check  ->  Get-WinPulseRemoteUsersRoot
    Step 3  Profile discovery   ->  Get-WinPulseMigrationProfiles -Root \\HOST\C$\Users
    Step 4  User selection      ->  Select-WinPulseBackupUsers  (reuse existing)
    Step 5  Folder selection    ->  Select-WinPulseBackupFolders  (reuse existing)
    Step 6  Plan + confirmation
    Step 7  Phase 1 Pull        ->  Invoke-WinPulseMigrationBackup (non-interactive params)
    Step 8  Phase 2 Restore     ->  Invoke-WinPulseMigrationRestore (non-interactive params)
    Step 9  Summary
```

Steps 7 and 8 call the EXISTING backup and restore functions in full
non-interactive mode (all params provided). Do NOT duplicate their copy,
verification, manifest, or report logic. This keeps Live Migration a thin
orchestrator over proven code.

#### 1. Top-level parameters

Add to the top `param()` block:

```powershell
[string]$LiveSourceHost   = $null,
[string[]]$LiveUsers      = @(),
[string[]]$LiveFolders    = @(),
[string]$LiveDestination  = $null,
[string]$LiveRestoreRoot  = $null,
[switch]$LiveExecute
```

Plumb all six through `Invoke-WinPulseMode` to `Invoke-WinPulseMigrationLive`
(mirror how `-BackupUsers`, `-BackupFolders`, etc. are plumbed for
`Invoke-WinPulseMigrationBackup`). Add `MigrationLive` to the elevation
passthrough so it auto-elevates (it needs admin for C$ access and writing to
C:\Users).

#### 2. Mode registration

Add `'MigrationLive'` to every `-Mode` ValidateSet in the file (top param block,
`Invoke-WinPulseMode` switch, smoke wrapper). Add a `switch` case in
`Invoke-WinPulseMode` that calls `Invoke-WinPulseMigrationLive` and passes all
six Live* params through. Add `MigrationLive` to the auto-elevate list.

#### 3. Migration menu entry

In `Show-WinPulseMigrationMenu`, add ONE item before the existing Back/Esc entry:

```powershell
@{ Label = 'Live Migration'; Key = 'V'; Hint = 'Pull data from a remote PC directly' }
```

And its handler calls `Invoke-WinPulseMode -Mode MigrationLive` (no Live* params
— fully interactive). Key 'V' is free; do not reuse existing keys.

#### 4. Helper: `Get-WinPulseRemoteUsersRoot`

Add near the other migration helper functions:

```powershell
function Get-WinPulseRemoteUsersRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Hostname)
    $h = $Hostname.Trim().TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($h)) { return $null }
    $adminShare = '\\{0}\C$' -f $h
    $uncRoot    = '{0}\Users' -f $adminShare
    Write-Host ('  Checking reachability of {0} ...' -f $adminShare) -ForegroundColor Gray
    try {
        if (-not (Test-Path -LiteralPath $adminShare -ErrorAction Stop)) {
            Write-Host '  Not reachable. Verify hostname, admin rights, C$ share and firewall.' `
                       -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host ('  Not reachable: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $null
    }
    Write-Host ('  Reachable: {0}' -f $uncRoot) -ForegroundColor Green
    return $uncRoot
}
```

#### 5. Main function: `Invoke-WinPulseMigrationLive`

Full function signature and flow. Keep each step clearly separated with a
comment header so the code is readable.

```powershell
function Invoke-WinPulseMigrationLive {
    [CmdletBinding()]
    param(
        [string]$LiveSourceHost  = $null,
        [string[]]$LiveUsers     = @(),
        [string[]]$LiveFolders   = @(),
        [string]$LiveDestination = $null,
        [string]$LiveRestoreRoot = $null,
        [switch]$LiveExecute
    )
```

**Determine interactive vs non-interactive:**

```powershell
$nonInteractive = (-not [string]::IsNullOrWhiteSpace($LiveSourceHost))
```

**Step 1 — Get hostname:**

```powershell
if ($nonInteractive) {
    $hostname = $LiveSourceHost.Trim()
} else {
    Clear-Host
    Write-WinPulseHeader -title 'Live Migration'
    Write-Host ''
    Write-Host '  Pull data from a remote PC directly over the network.' -ForegroundColor Gray
    Write-Host '  The remote PC must be on, reachable, and you need admin rights on it.' -ForegroundColor Gray
    Write-Host ''
    $hostname = Read-Host '  Source PC hostname or IP'
    if ([string]::IsNullOrWhiteSpace($hostname)) { return }
}
```

**Step 2 — Reachability:**

```powershell
$remoteUsersRoot = Get-WinPulseRemoteUsersRoot -Hostname $hostname
if (-not $remoteUsersRoot) { if (-not $nonInteractive) { Wait-WinPulseKey }; return }
```

**Step 3 — Profile discovery:**

```powershell
$profiles = @(Get-WinPulseMigrationProfiles -Root $remoteUsersRoot)
if ($profiles.Count -eq 0) {
    Write-Host '  No user profiles found on remote PC.' -ForegroundColor Yellow
    if (-not $nonInteractive) { Wait-WinPulseKey }
    return
}
```

**Step 4 — User selection:**

```powershell
if ($nonInteractive -and $LiveUsers.Count -gt 0) {
    $selectedUsers = @($profiles | Where-Object { $_.UserName -in $LiveUsers })
} else {
    $selectedUsers = @(Select-WinPulseBackupUsers -profiles $profiles)
    if ($selectedUsers.Count -eq 0) { return }
}
```

**Step 5 — Folder selection:**

```powershell
if ($nonInteractive -and $LiveFolders.Count -gt 0) {
    $selectedFolders = $LiveFolders
} else {
    $selectedFolders = @(Select-WinPulseBackupFolders)
    if ($selectedFolders.Count -eq 0) { return }
}
```

**Step 6 — Destination and restore root:**

```powershell
# Local temp backup destination
if ([string]::IsNullOrWhiteSpace($LiveDestination)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $destination = 'C:\WinPulseBackups\LiveMigration-{0}-{1}' -f $hostname, $stamp
} else {
    $destination = $LiveDestination
}

# Local restore root
$restoreRoot = if ([string]::IsNullOrWhiteSpace($LiveRestoreRoot)) { 'C:\Users' } else { $LiveRestoreRoot }
```

**Step 6b — Plan display and confirmation (interactive only):**

When NOT non-interactive, show a summary before proceeding:

```powershell
if (-not $nonInteractive) {
    Write-Host ''
    Write-Host '  Migration plan:' -ForegroundColor White
    Write-Host ('    Source  : {0}' -f $remoteUsersRoot) -ForegroundColor Gray
    Write-Host ('    Users   : {0}' -f ($selectedUsers | ForEach-Object { $_.UserName }) -join ', ') `
               -ForegroundColor Gray
    Write-Host ('    Folders : {0}' -f ($selectedFolders -join ', ')) -ForegroundColor Gray
    Write-Host ('    Temp    : {0}' -f $destination) -ForegroundColor Gray
    Write-Host ('    Restore : {0}' -f $restoreRoot) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  NOTE: locked files on the live source PC (open DBs, NTUSER.DAT)' `
               -ForegroundColor Yellow
    Write-Host '        will be skipped — this is normal for a running machine.' `
               -ForegroundColor Yellow
    Write-Host ''
    $confirm = Select-WinPulseMenuItem -Title 'Start live migration?' -Items @(
        @{ Label = 'Yes — copy now'; Key = 'Y'; Hint = 'Pull data and restore locally' }
        @{ Label = 'No — cancel';    Key = 'N'; Hint = '' }
    )
    if ($confirm -ne 'Y') { return }
    $LiveExecute = $true
}
```

**Step 7 — Phase 1: Pull (remote backup):**

```powershell
Write-Host ''
Write-Host '  ═══ Phase 1/2: Pulling data from remote PC ═══' -ForegroundColor White
Write-Host ''

Invoke-WinPulseMigrationBackup `
    -BackupProfilesRoot $remoteUsersRoot `
    -BackupUsers        ($selectedUsers | ForEach-Object { $_.UserName }) `
    -BackupFolders      $selectedFolders `
    -BackupDestination  $destination `
    -BackupExecute:$LiveExecute
```

If `$LiveExecute` is false (dry-run), the backup runs as dry-run too and shows
the plan without copying.

**Step 8 — Phase 2: Restore (local):**

Only run Phase 2 when Phase 1 was not a dry-run AND the destination folder exists:

```powershell
if ($LiveExecute -and (Test-Path -LiteralPath $destination)) {
    Write-Host ''
    Write-Host '  ═══ Phase 2/2: Restoring data to local PC ═══' -ForegroundColor White
    Write-Host ''

    Invoke-WinPulseMigrationRestore `
        -RestoreBackupPath $destination `
        -RestoreRoot       $restoreRoot `
        -RestoreFolders    $selectedFolders `
        -RestoreExecute
}
```

**Step 9 — Summary:**

```powershell
Write-Host ''
if ($LiveExecute) {
    Write-Host '  Live migration complete.' -ForegroundColor Green
    Write-Host ('  Source backup is kept at: {0}' -f $destination) -ForegroundColor Gray
    Write-Host '  Run MigrationVerify on the backup folder to confirm integrity.' -ForegroundColor Gray
} else {
    Write-Host '  Dry-run complete. Add -LiveExecute to copy for real.' -ForegroundColor Yellow
    Write-Host ('  Equivalent command:') -ForegroundColor Gray
    $userList    = ($selectedUsers | ForEach-Object { $_.UserName }) -join ','
    $folderList  = $selectedFolders -join ','
    Write-Host ('  bootstrap.ps1 -Mode MigrationLive -LiveSourceHost "{0}" ' -f $hostname) `
               -ForegroundColor Gray
    Write-Host ('    -LiveUsers {0} -LiveFolders {1} -LiveExecute' -f $userList, $folderList) `
               -ForegroundColor Gray
}
if (-not $nonInteractive) { Wait-WinPulseKey }
```

#### 6. Smoke test coverage

Add `'MigrationLive'` to the smoke wrapper `ValidateSet`. The smoke test for
this mode should:
- Build a fixture source profile (like MigrationBackup smoke does) under a temp
  folder simulating the remote root (use `-LiveSourceHost` is not testable without
  a real network; instead pass `-LiveDestination` and fake the remote root as a
  local temp path via the `Get-WinPulseMigrationProfiles -Root` mechanism).
- Since `Get-WinPulseRemoteUsersRoot` would fail on a local path, the smoke test
  should call `Invoke-WinPulseMigrationLive` with a MOCKED remote root — skip
  the reachability helper and pass `-BackupProfilesRoot` directly to the backup
  call. Add a `-LiveProfilesRoot` internal override param OR just make the smoke
  test bypass `Get-WinPulseRemoteUsersRoot` by passing a pre-validated local
  temp root via a test-only code path.

  **Simplest viable approach:** Add an internal undocumented `-_LiveProfilesRoot`
  override param that, when set, skips the reachability check and uses the
  provided value as `$remoteUsersRoot` directly. Use this ONLY in the smoke test.
  Name it with a leading underscore to signal it is test-only.

- Assert: dry-run (no `-LiveExecute`) prints the plan and exits 0. The smoke
  test does not need to exercise the real copy.
- Parser clean, ASCII check, all existing smoke modes still exit 0.

#### 7. Visual verification (Claude before merge)

This task touches the Migration menu (new item) and the interactive confirmation
picker. Build on `dev`, run parser + ASCII + all smoke modes, report. Claude will
verify:
- Migration menu shows "Live Migration" item
- Selecting it prompts for hostname
- Unreachable host shows clear red error and cancels
- Plan display is readable
- Confirmation picker works
- Phase separators are visible during copy

Do NOT merge to main until Claude approves visually.

#### Acceptance summary

- `'MigrationLive'` in every ValidateSet; auto-elevate list updated.
- `Get-WinPulseRemoteUsersRoot` does only `Test-Path` on `\\HOST\C$` — no
  PSRemoting, no WMI, no credential prompts.
- Phase 1 calls `Invoke-WinPulseMigrationBackup` with all params set (fully
  non-interactive). Phase 2 calls `Invoke-WinPulseMigrationRestore` with all
  params set. Neither copy loop, manifest, verification, nor report logic is
  duplicated in `Invoke-WinPulseMigrationLive`.
- Dry-run (no `-LiveExecute`) runs Phase 1 as dry-run, skips Phase 2, prints
  the equivalent command.
- Locked-file note is shown in the plan before confirmation.
- Local temp backup is never auto-deleted.
- Parser clean, ASCII-only, StrictMode-safe, PS 5.1 compatible.
- All existing smoke modes still exit 0.

Out of scope: `Get-Credential`, `New-SmbMapping`, VSS shadow copies, remote
restore or verify, incremental copy, drive label enumeration, PSRemoting.

### Task C31 - Post-run "open report / log / folder" action menu

Why: after a migration backup/restore/verify/apps/live run completes, the report
and log paths are printed but the technician has to copy-paste them into Explorer
to view them. A small action menu that opens the report, the log, or the
containing folder with one keypress saves friction.

**IMPORTANT - visual verification required.** This adds an interactive menu.
Build on `dev`, validate parser + ASCII + all smoke modes, then report. Claude
verifies visually before merge to main.

**CRITICAL smoke-safety rule:** the action menu is interactive and MUST NEVER be
shown on a non-interactive/scripted run (it would hang waiting for a key and
break every smoke test). Only call it from interactive code paths - see wiring
below. Each migration function already distinguishes interactive vs
non-interactive; respect that.

#### New helper: `Show-WinPulsePostRunActions`

Add near the other `Show-WinPulse*` helpers:

```powershell
function Show-WinPulsePostRunActions {
    [CmdletBinding()]
    param(
        [string]$ReportPath = $null,
        [string]$LogPath = $null
    )

    # Folder is derived from whichever artifact exists (report preferred).
    $folderPath = $null
    foreach ($p in @($ReportPath, $LogPath)) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) {
            $folderPath = Split-Path -Path $p -Parent
            break
        }
    }

    while ($true) {
        $items = @()
        if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and (Test-Path -LiteralPath $ReportPath)) {
            $items += @{ Label = 'Open report (HTML)'; Key = 'O' }
        }
        if (-not [string]::IsNullOrWhiteSpace($LogPath) -and (Test-Path -LiteralPath $LogPath)) {
            $items += @{ Label = 'Open log';            Key = 'L' }
        }
        if (-not [string]::IsNullOrWhiteSpace($folderPath) -and (Test-Path -LiteralPath $folderPath)) {
            $items += @{ Label = 'Open containing folder'; Key = 'F' }
        }
        $items += @{ Separator = $true }
        $items += @{ Label = 'Continue'; Key = 'C'; Color = 'DarkGray' }

        $choice = Select-WinPulseMenuItem -Title 'Done - open results?' -Items $items
        switch ($choice) {
            'O' {
                # Open the HTML report in Edge InPrivate (Edge is present on all
                # target machines); fall back to the default handler if Edge is
                # missing.
                $opened = $false
                try {
                    Start-Process -FilePath 'msedge.exe' -ArgumentList '--inprivate', ('"{0}"' -f $ReportPath)
                    $opened = $true
                }
                catch { $opened = $false }
                if (-not $opened) {
                    try { Start-Process -FilePath $ReportPath }
                    catch { Write-Host ('  Could not open report: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
                }
            }
            'L' { try { Start-Process -FilePath 'notepad.exe' -ArgumentList $LogPath } catch { Write-Host ('  Could not open log: {0}' -f $_.Exception.Message) -ForegroundColor Yellow } }
            'F' { try { Start-Process -FilePath 'explorer.exe' -ArgumentList $folderPath } catch { Write-Host ('  Could not open folder: {0}' -f $_.Exception.Message) -ForegroundColor Yellow } }
            default { return }
        }
    }
}
```

Note on Edge InPrivate: `Start-Process msedge.exe` resolves via the App Paths
registry key on a standard Windows install. The try/catch fallback to the default
handler covers the rare machine where `msedge.exe` is not on PATH/App Paths.

Notes:
- `Select-WinPulseMenuItem` returns the `Key` of the chosen item, `$null` on Esc.
  Esc / 'C' both return (the `default` switch arm).
- Loop so the user can open several artifacts before continuing.
- Every open is wrapped in try/catch and is non-fatal.

#### Wiring (do NOT change the migration functions' internals or returns)

The migration functions already return objects carrying `ReportHtmlPath` and
`LogPath`. Wire the helper at the INTERACTIVE call sites only.

**1. `Show-WinPulseMigrationMenu`** - this is the interactive menu. It currently
does e.g. `Invoke-WinPulseMigrationBackup | Out-Null; Wait-WinPulseKey`. For
Backup, Restore, Verify, and Apps, capture the return and replace the trailing
`Wait-WinPulseKey` with the action menu (fall back to `Wait-WinPulseKey` when the
run returned nothing, e.g. cancelled):

```powershell
'B' {
    $r = Invoke-WinPulseMigrationBackup
    if ($r) { Show-WinPulsePostRunActions -ReportPath $r.ReportHtmlPath -LogPath $r.LogPath }
    else { Wait-WinPulseKey }
}
```
Apply the same pattern to 'R' (Restore), 'V' (Verify), 'A' (Apps) using their
returned objects' `ReportHtmlPath` / `LogPath`. (Restore/Verify/Apps all expose
`ReportHtmlPath` and `LogPath`; confirm each return object before wiring - if a
field is absent on one, pass `$null` for it, do not invent it.)

**2. `Invoke-WinPulseMigrationLive`** - it has its own trailing
`if (-not $nonInteractive) { Wait-WinPulseKey }`. Replace that single line with:

```powershell
if (-not $nonInteractive) {
    if ($LiveExecute -and $backupResult) {
        Show-WinPulsePostRunActions -ReportPath $backupResult.ReportHtmlPath -LogPath $backupResult.LogPath
    }
    else {
        Wait-WinPulseKey
    }
}
```
(Use the Phase-1 backup result's report/log - that is the live run's artifact.)

#### Constraints

- Do NOT call `Show-WinPulsePostRunActions` from any non-interactive path, the
  `Invoke-WinPulseMode` dispatch, or anywhere a scripted run reaches. Smoke MUST
  stay green.
- Do NOT change what the migration functions collect, return, or print, beyond
  swapping the trailing interactive `Wait-WinPulseKey` for the action menu.
- `Start-Process` opening a local file the tool just wrote is allowed and is not a
  safety-boundary concern (no remote execution, no secrets).
- ASCII-only, StrictMode-safe, PS 5.1 compatible.

#### Acceptance

- Parser clean, ASCII check empty, git diff --check clean.
- All four (or five, if MigrationLive smoke is present) smoke modes exit 0 - this
  proves the interactive menu is never reached on a scripted run.
- Visual check (Claude): after an interactive backup/restore/verify/apps/live run,
  the "Done - open results?" menu appears, shows only the actions whose files
  exist, opens report/log/folder, loops, and Continue/Esc returns to the menu.

Out of scope: opening artifacts on non-interactive runs, a "delete backup" action,
emailing/uploading reports, changing report/log content or location.

## Work Queue - Batch 4 (2026-06-10 code review)

Claude did a full product/code review on 2026-06-10. The complete findings list
is below (kept here so nothing is lost); the top issues became tasks C32-C36.
C32 was implemented by Claude the same day. Codex: do C33 and C34 first (pure
logic, smoke-verifiable), then C35 and C36 (TUI changes, Claude verifies
visually before merge). Same rules as previous batches: one task per commit on
`dev/migration-preflight-foundation`, sync with main first, do not push to
main, do not bump the version, run parser + ASCII + ALL smoke modes after each
task (MigrationPreflight, MigrationBackup, MigrationRestore, MigrationVerify,
MigrationApps, MigrationLive), report changes + test output, ask when unsure.

### Review findings 2026-06-10 (full list, with disposition)

Functionality / reliability:

1. Backup/restore did not check destination free space -> Task C32 (DONE).
2. Long paths (>260 chars): robocopy copies them but the verification
   enumeration (`Get-ChildItem` in PS 5.1) fails on them -> false
   Mismatch/Verified. BACKLOG - needs `\\?\`-prefixed .NET enumeration in
   `Get-WinPulseFilteredFiles` / `Measure-WinPulseFolderFiltered`.
3. `Repair-WindowsUpdate` is all `-ErrorAction SilentlyContinue`: when the
   service stop or rename fails it still prints a green success line, and the
   `SoftwareDistribution.bak.<stamp>` folders are never cleaned up (disk leak).
   BACKLOG - verify service stop, report the real outcome, clean old .bak.
4. PARTIAL results name no files; technician must grep robocopy logs by hand
   -> Task C33.
5. Exit cleanup wipes Exports (preflight/verify reports) with no archive
   offer. BACKLOG - offer ExportBundle ZIP in the exit prompt.

Security:

6. Downloaded external tools are not integrity-checked (only a ZIP magic-byte
   probe) -> Task C34.
7. `irm | iex` always runs HEAD of main; no release tagging, and a locally
   saved copy never learns it is stale. BACKLOG - release tags + a cheap
   startup version check against GitHub.

UX / UI:

8. No way to filter long multi-select lists (MigrationApps can have 100+
   packages) -> Task C35.
9. Startup spinner (option A: spinner + phase name) approved earlier, still
   not implemented. BACKLOG.
10. Dry-run vs Execute flows look identical until the very end. BACKLOG -
    colored mode banner above the plan.
11. No overall copy progress (current file only) -> folded into Task C36.
12. Deferred TUI items C7 / C9 / C11 still waiting for an interactive session.

Performance:

13. Robocopy runs single-threaded -> Task C36 (/MT).
14. Verification re-enumerates source over SMB on Live Migration (second full
    network pass). BACKLOG - reuse plan counts for remote sources.

Maintainability:

15. 10k+ lines in one file is a distribution decision, not necessarily a
    development one. IDEA - build step assembling bootstrap.ps1 from src/
    modules; large, strategic, not scheduled.
16. No Pester unit tests for pure logic (winget export parser, powercfg HTML
    parser, pnputil parser, plan builders). BACKLOG.
17. AGENTS.md carries ~2400 lines of mostly DONE tasks. BACKLOG - archive done
    task specs into docs/ and keep only live instructions here.

### Task C32 - Free-space guard for backup and restore destinations

Status: DONE - implemented by Claude 2026-06-10 (version 0.15.3-20260610).
Kept for reference.

- New helper `Get-WinPulseDestinationFreeBytes -path <string>`: free bytes on
  the drive holding the path via `System.IO.DriveInfo`; returns `$null` for
  UNC paths and unmapped/not-ready drives ($null = unknown, never zero).
- Backup: after the plan summary, prints "Free space on destination drive: X"
  (red when below plan TotalBytes * 1.05) plus a red warning line. On execute:
  non-interactive aborts (`return $null`) when low; interactive shows the red
  warning before the YES prompt.
- Restore: same display after the plan; non-interactive execute aborts only
  when `OverwriteCount -eq 0` (an overwrite restore lands largely in place,
  and on a fresh profile the known folders always exist), otherwise warns.
- Verified: parser clean, ASCII clean, all six smoke modes exit 0; helper
  unit-checked against local, UNC, not-ready (D:) and nonexistent (Z:) drives.

### Task C33 - Name the files that failed to copy (parse robocopy logs)

Status: DONE - implemented by Codex (`Get-WinPulseRobocopyFailedEntries`,
uniform `FailedEntries`/`FailedEntryCount` on backup+restore items, console
summary via `Write-WinPulseFailedEntrySummary`, text/HTML report sections,
locked-file smoke fixture), reviewed by Claude 2026-06-10. Verified live in
smoke output: locked file surfaces as `ERROR 32: Copying File ... - <message>`.
(Kept below for reference.)

Why: a PARTIAL backup/restore says only "some files could not be copied". The
detail is in the per-item robocopy log, but nobody greps logs during a
migration. Parse the log, surface the failed entries in the manifest, the
reports, and the console so the technician immediately knows what was skipped
(and can e.g. re-run after the user logs off). This is finding #4 and the main
practical pain of Live Migration until VSS exists.

Scope:

- New helper `Get-WinPulseRobocopyFailedEntries -logPath <string>`:
  - Read the log (if missing/unreadable return `@()`; never throw).
  - Match lines like
    `2026/06/05 12:00:00 ERROR 32 (0x00000020) Copying File C:\Users\x\file.dat`
    with a regex anchored on `ERROR \d+ \(0x[0-9A-Fa-f]{8}\)`. Capture the
    error code and the tail after the closing paren (action + full path) as
    one detail string. Do NOT try to surgically split action from path -
    the combined tail is what a technician needs.
  - If the immediately following line is a non-empty plain message (e.g. "The
    process cannot access the file..."), append it to the detail as
    ` - <message>`.
  - Dedupe (with `/R:1` each failure can appear twice), preserve order, cap at
    200 entries. Return an array of strings.
- Backup loop (`Invoke-WinPulseMigrationBackup`) and restore loop
  (`Invoke-WinPulseMigrationRestore`): when `$rc.Partial` or (not `$rc.Success`
  and not dry-run), call the helper on `$itemLog` and add to the per-item
  result object: `FailedEntries = @(...)` and `FailedEntryCount = <int>`.
  For clean items set `FailedEntries = @()` / `FailedEntryCount = 0` so the
  manifest shape is uniform. Additive only - do not change any existing field.
- Console: after the per-item result list, when any item has FailedEntryCount
  > 0, print up to 10 entries total (yellow), then
  `(+N more - see the robocopy logs and the report)`.
- Reports: in `ConvertTo-WinPulseCopyReportRows` /
  `Export-WinPulseMigrationCopyReportText` / `...Html`, under each item with
  FailedEntryCount > 0 list up to 50 entries (text: indented lines; HTML: a
  sub-list with the warn style), then a `+N more` line. Reuse existing CSS.
- MigrationVerify is untouched (it has no robocopy logs).

Acceptance (non-elevated, temp fixtures):

- Extend the MigrationBackup smoke: create the fixture, open one fixture file
  with an exclusive lock (`[System.IO.File]::Open(path, 'Open', 'Read',
  'None')` held in the smoke process), run the executed backup, assert the
  item is Partial AND its `FailedEntries` in manifest.json is non-empty and
  mentions the locked file name; release the lock, clean up. (`/R:1 /W:1`
  adds ~2s - acceptable.)
- A fully clean backup run has `FailedEntryCount = 0` everywhere and reports
  render without the new section.
- Parser + ASCII clean; ALL smoke modes still exit 0.

Out of scope: changing robocopy flags, retrying failed files, VSS, parsing
non-error log lines.

### Task C34 - Integrity verification for downloaded external tools

Status: DONE - implemented by Codex (`Test-WinPulseDownloadedBinary`,
`VerifySignature` on Autoruns/SysinternalsSuite/OOSU10 only, pre-extraction
Sha256 hook, cached-binary re-check, cleanup+throw on failure, OOShutUp
rerouted through Ensure-ToolInstalled, Process Explorer live-path check,
no-network smoke assertions incl. compiled unsigned exe), reviewed by Claude
2026-06-10. NirSoft/OpenHardwareMonitor left unverified by design (unsigned
vendors). (Kept below for reference.)

Why: `Ensure-ToolInstalled` downloads EXEs/ZIPs and runs them with admin
rights after only a ZIP magic-byte probe. A compromised mirror means arbitrary
code execution. WinPulse's whole identity is "transparent, no unknown
binaries" - verify what we fetch (finding #6).

Scope:

- Catalog (`Get-WinPulseToolCatalog`): support two OPTIONAL per-tool fields:
  - `VerifySignature = $true` - the resolved binary must carry a VALID
    embedded Authenticode signature (`Get-AuthenticodeSignature` Status
    `Valid`).
  - `Sha256 = '<64 hex chars>'` - pinned hash of the downloaded artifact
    (only for stable, versioned URLs - do NOT pin "latest" URLs).
  Defaults absent = current behavior (no check) so nothing breaks.
- New helper `Test-WinPulseDownloadedBinary -path <file> -requireSignature
  <bool> -sha256 <string>` returning `[pscustomobject]@{ Ok; Note }`:
  - sha256 given: compute `Get-FileHash -Algorithm SHA256`, case-insensitive
    compare; mismatch -> Ok=$false with both hashes in Note.
  - requireSignature: `Get-AuthenticodeSignature` must return Status `Valid`;
    anything else (NotSigned, HashMismatch, UnknownError) -> Ok=$false with
    the status in Note.
  - Both checks requested -> both must pass. Neither requested -> Ok=$true.
- `Ensure-ToolInstalled`:
  - Sha256 check runs on the downloaded artifact BEFORE extraction/copy;
    failure -> delete the download, try the next URL source, and if all
    sources fail throw a clear error.
  - Signature check runs on the RESOLVED binary path before returning it;
    failure -> `Remove-Item` the tool's target dir and throw
    `"<name> failed signature verification - not running it."`.
  - When a tool has neither field, after install print ONE yellow line:
    `  Note: <name> is not signature-verified (vendor ships unsigned binaries).`
- Setting the flags: inspect the catalog and set `VerifySignature = $true`
  ONLY for vendors that embed Authenticode signatures (Microsoft/Sysinternals
  Suite, O&O ShutUp10). NirSoft tools are unsigned - leave them unset. When
  unsure about a vendor, leave it unset and note it in your report. Do not
  pin Sha256 for any moving "latest" URL.

Acceptance (non-elevated, NO network in tests):

- Smoke-style unit assertions (add to an existing smoke mode or a small
  dedicated check the smoke wrapper runs): temp file + correct Sha256 ->
  Ok=$true; wrong Sha256 -> Ok=$false; temp .exe (any bytes) with
  requireSignature -> Ok=$false (NotSigned). No download is attempted.
- Code review: failure paths delete the artifact/tool dir; the thrown messages
  are clear; catalog defaults unchanged for unset tools.
- Parser + ASCII clean; ALL smoke modes still exit 0.
- Real signed-tool download verification (Sysinternals, OOSU10) is
  Claude/owner with network - do not claim it.

Out of scope: GPG/cosign, certificate pinning to a specific publisher CN
(nice-to-have later), changing download URLs, verifying winget/choco installs.

### Task C35 - Type-to-filter ('/') in multi-select menus

Status: DONE - implemented by Codex (92210f6), reviewed by Claude. Claude fixed
a real bug (04a02ef): 'continue' inside a switch does NOT re-iterate the while
loop in PowerShell, so filter-edit keystrokes leaked into the main key switch
(typing 'a' triggered All/None, Enter confirmed the menu). Rewrote filter-edit
as an if/elseif chain ending in one 'continue' inside the if; shortened the
help bar to 83 chars to avoid wrapping at 88 cols. Awaiting owner visual
verify. (Kept below for reference.)

**IMPORTANT - visual verification required.** TUI rendering change. Build on
`dev`, validate parser + ASCII + all smoke modes, report; Claude verifies
visually before merge.

Why: `Select-WinPulseMultiMenuItem` lists can be long (MigrationApps winget
packages 100+, users on a terminal server). Arrow keys alone are slow even
with the C28 select-all. A `/` filter narrows the list as you type (finding #8).

Scope (all inside `Select-WinPulseMultiMenuItem`; single-select is NOT touched):

- State: `$filterText = ''`, `$filterEditing = $false`. The visible item set is
  the items whose Label contains `$filterText` (case-insensitive); empty filter
  = all items. Separators stay visible only when adjacent to visible items
  (simplest acceptable: hide separators while a filter is active).
- Keys:
  - `/` (when not editing) -> enter filter-edit mode.
  - While editing: printable chars (letters, digits, space, dot, dash,
    underscore) append; Backspace deletes last char; Enter -> stop editing,
    keep the filter; Esc -> clear the filter AND stop editing. Arrow keys also
    stop editing (keep filter) and then navigate.
  - While NOT editing: all existing keys keep their meaning (Space toggle,
    `A` select/deselect all, Enter confirm, Esc cancel). `A` applies to the
    currently VISIBLE (filtered) items only when a filter is active.
- Selection state (`Selected`) lives on the underlying item objects, so it
  must survive filter changes - confirm, do not copy items.
- Cursor/viewport reset to the top whenever the filter text changes.
- Help bar: append `/ Filter` and, while a filter is active, show
  `Filter: <text>` (editing: trailing `_` cursor) on its own line in the
  existing style. Box width must not change.
- CRITICAL: with no `/` ever pressed, rendering and behavior must be
  byte-identical to today, including the non-interactive RawUI guard.

Acceptance:

- Parser + ASCII clean; ALL smoke modes exit 0 (smoke never opens menus -
  proves no regression).
- Visual check (Claude): filter narrows the MigrationApps package list while
  typing; Space/A work on the filtered view; ticks survive clearing the
  filter; Esc-Esc cancels; menus without filtering look unchanged.

Out of scope: `Select-WinPulseMenuItem` (single-select), fuzzy matching,
highlighting matched substrings, the folder picker.

### Task C36 - Robocopy /MT multithreading + copy progress counter

Status: DONE - implemented by Codex (dfe722e), reviewed by Claude (matches
spec: -multiThread param, /MT:8 on real backup/restore copies only, '~N files
done' counter throttled every 25 lines, per-file line unchanged when
multiThread=0, item size added to real copy lines). Smoke drives real /MT
copies, all green. Awaiting owner visual verify on a real multi-GB copy.
(Kept below for reference.)

**IMPORTANT - visual verification required.** Changes the live copy status
line. Build on `dev`, validate parser + ASCII + all smoke modes, report;
Claude verifies visually on a real copy before merge.

Why: the copy is single-threaded; `/MT:8` typically speeds up many-small-file
profiles (Chrome = thousands of tiny files) 2-4x (finding #13). With /MT the
per-file `/TEE` stream interleaves, so the "current file" status line must
become a counter - which also addresses the missing overall progress
(finding #11).

Scope:

- `Invoke-WinPulseRobocopy`: add `[int]$multiThread = 0`. When `> 0` AND not
  `-DryRun`, append `/MT:<n>` to the arguments. Default 0 = today's behavior,
  byte-identical (dry-run never gets /MT).
- Status line in the non-dry-run branch when `$multiThread -gt 0`: replace the
  current-file display with a throttled counter - count streamed lines that
  end in a path-ish token (simplest: every non-empty line that is not a header
  separator), and every 25 lines rewrite the status line as
  `    copying... ~{N} files done` (same `\r`-rewrite, same 84-char pad).
  When `$multiThread -eq 0`, keep the existing per-file line EXACTLY as is.
- Call sites: backup loop and restore loop pass `-multiThread 8`. The
  per-item line gains the planned size for context, e.g.
  `  Copying user\Desktop (12.3 GB)...` using the plan item's `Size` (both
  loops already have the item in scope). MigrationVerify and dry-runs are
  untouched.
- Robocopy notes: `/MT` is incompatible with `/IPG` and `/EFSRAW` (we use
  neither); log writes stay coherent with `/LOG+`; verification is
  count/byte-based and unaffected by copy order. C33's log parser must still
  work - /MT error lines keep the same `ERROR n (0x...)` shape.

Acceptance:

- Parser + ASCII clean; ALL smoke modes exit 0 (smoke executes real copies
  through the wrapper, so the /MT path is exercised end-to-end; manifests
  must still show zero failures/mismatches).
- Visual check (Claude/owner): on a real multi-GB backup the counter line
  updates smoothly, no garbled interleaving, and the copy is measurably
  faster on a many-small-files folder.

Out of scope: /MT tuning per folder size, robocopy /NP changes, bandwidth
limiting, progress bars in Write-Progress beyond what exists.

## Work Queue - Batch 5 (queued 2026-06-10)

Prepared by Claude after the owner reviewed the Batch 4 backlog. Do these in
order. Same rules as every batch: sync first (`git checkout
dev/migration-preflight-foundation` then `git merge main --ff-only`; stop if not
fast-forward), ONE commit per task, do NOT push to main, do NOT bump the version
(Claude does that), keep `bootstrap.ps1` ASCII-only / StrictMode-safe / PS 5.1
compatible, use bracket notation for hashtable access. After EACH task run the
parser check, the ASCII check, `git diff --check`, and ALL five non-elevated
smoke modes (MigrationBackup/Restore/Verify/Apps/Live) - all exit 0;
MigrationPreflight needs elevation, skip it and say so. Report changes + full
test output. Use temp fixtures only, never real C:\Users or real OS paths, never
run an elevated/destructive action in tests, never claim you verified something
you could not run. PowerShell footgun reminder: `continue`/`break` inside a
`switch` do NOT control an enclosing loop - never rely on that (this bit C35).

Do C37 and C38 first (pure logic, smoke-verifiable). C39 changes live TUI AND
deletes real OS data - build + validate it, but the owner/Claude verify it
visually and on a real machine before merge; do NOT claim it works for real.

### Task C37 - Long-path-safe verification enumeration

Status: DONE - implemented by Codex (cd71a35: Get-WinPulseExtendedPath +
ConvertFrom-WinPulseExtendedPath + stack-based .NET DirectoryInfo walk in
Get-WinPulseFilteredFiles, smoke with a >260-char deep file asserting Verified).
Reviewed by Claude, who also made hash sampling long-path-safe (Get-FileHash via
the `\\?\` extended path - it fails on a normal >260 path, which would have been
a new false-Mismatch). All five smoke modes green. (Kept below for reference.)

Why: robocopy copies paths longer than 260 chars fine, but the verification
file walk (`Get-WinPulseFilteredFiles`, bootstrap.ps1 ~5405, used by
`Measure-WinPulseFolderFiltered` and `Get-WinPulseCopyVerification`) uses
`Get-ChildItem -LiteralPath -Recurse`, which in Windows PowerShell 5.1 silently
fails on >260-char paths. Result: files that copied are not counted, producing a
false Mismatch (or, symmetrically, a false Verified). This corrupts the core
backup/restore integrity signal.

Scope:

- Add a helper `Get-WinPulseExtendedPath -path <string>` that returns the
  extended-length form so .NET enumeration can exceed MAX_PATH:
  - Already prefixed (`\\?\...`) -> return as-is.
  - UNC (`\\server\share\...`) -> `\\?\UNC\server\share\...`.
  - Local rooted (`C:\...`) -> `\\?\C:\...`.
  - Anything else (relative, empty) -> return unchanged (caller still works).
  Resolve to a full path first via `[System.IO.Path]::GetFullPath` inside
  try/catch; on any failure return the original path.
- Rewrite the enumeration inside `Get-WinPulseFilteredFiles` to a manual,
  stack-based recursive walk using `[System.IO.DirectoryInfo]` on the extended
  path, so >260-char trees are fully enumerated:
  - Push the root DirectoryInfo (built from the extended path). For each dir,
    wrap `EnumerateFiles()` and `EnumerateDirectories()` in their OWN try/catch
    (skip on UnauthorizedAccess/IO, mirroring today's `-ErrorAction
    SilentlyContinue` tolerance) and push child dirs onto the stack.
  - For each file, return an object the existing consumers can use unchanged:
    they read `.Name`, `.Length`, `.DirectoryName`. `System.IO.FileInfo` already
    exposes all three, so emitting FileInfo is fine. Strip any `\\?\` (and
    `\\?\UNC\`) prefix from `.DirectoryName` before the /XD relative-segment
    comparison so the exclude-dir logic still matches (the prefix must not leak
    into the relative path math; compute the relative path against the ORIGINAL
    root length, not the extended one).
  - Keep the /XF (`-like` on file name) and /XD (excluded dir segment) semantics
    byte-identical to today. Keep returning `$out.ToArray()` (StrictMode: do not
    `@()`-wrap a Generic.List).
- Do NOT change `Measure-WinPulseFolderFiltered`, `Get-WinPulseCopyVerification`,
  the robocopy wrapper, or the manifest. This is an internal enumeration swap.

Acceptance (non-elevated, temp fixtures):

- Extend the MigrationBackup smoke: build a fixture whose Desktop contains a
  directory chain deep enough that a leaf file's full path exceeds 260 chars
  (nest e.g. 12 x a 30-char folder name, with a file inside), run an executed
  backup, and assert the deep file is copied AND the item verifies as Verified
  (NOT Mismatch) - i.e. `Measure-WinPulseFolderFiltered` counted it. Before this
  fix that file would be uncounted.
- A normal (short-path) fixture still verifies exactly as today; exclude-file
  and exclude-dir filtering still work (add/keep an assertion that an excluded
  file is not counted).
- Parser + ASCII clean; all five smoke modes exit 0.

Out of scope: changing robocopy flags, hashing, manifest schema, or making the
copy itself long-path aware (robocopy already is).

### Task C38 - Harden Repair-WindowsUpdate (real status + clean old .bak)

Status: DONE - implemented by Codex (243a00c: per-service stop/start verify via
a 20x500ms poll, guarded renames, old SoftwareDistribution.bak.*/catroot2.bak.*
cleanup before the new rename, truthful issue summary). Reviewed by Claude, who
fixed a runtime bug: Codex logged `Write-Log -level 'WARN'` but Write-Log's
ValidateSet only allows INFO/WARNING/ERROR, so every issue path would have
thrown (parser can't catch a runtime ValidateSet; no smoke covers this elevated
function) - changed all 'WARN' to 'WARNING'. The real elevated run stays an
owner task. (Kept below for reference.)

Why: `Repair-WindowsUpdate` (bootstrap.ps1 ~9120) stops services, renames
`SoftwareDistribution` + `catroot2`, restarts services - every step with
`-ErrorAction SilentlyContinue`, then unconditionally prints green
"reset complete". If a service will not stop or the rename fails, the technician
is told it worked when it did not. Also each run leaves a
`SoftwareDistribution.bak.<stamp>` (often several GB) and `catroot2.bak.<stamp>`
that nothing ever deletes - a disk leak.

Scope (this function only; do not touch `Restart-WindowsUpdateServices` or
`Invoke-WinPulseTempCleanup`):

- Stop each of wuauserv/bits/cryptsvc/msiserver, then VERIFY it actually
  stopped: poll `Get-Service` Status up to a few seconds (e.g. 10 x 500ms) and
  record which services did not reach Stopped. Collect failures into a list.
- Only attempt each rename when its source folder exists; capture success/
  failure per rename (try/catch with `-ErrorAction Stop`). A failed rename while
  its service is still running is the common real failure - report it clearly.
- Restart the services and verify they reach Running; record any that did not.
- Replace the single green line with a truthful summary: green "Windows Update
  components reset complete." ONLY when all services stopped, both renames
  succeeded (or the folder was absent), and services restarted; otherwise a
  yellow/red summary listing exactly what failed (e.g. "wuauserv did not stop;
  SoftwareDistribution not reset"). Log each outcome via `Write-Log`.
- Clean up OLD leftovers from previous runs: BEFORE creating today's .bak, find
  `SoftwareDistribution.bak.*` under `%SystemRoot%` and `catroot2.bak.*` under
  `%SystemRoot%\System32`, and remove them (`Remove-Item -Recurse -Force` in
  try/catch, non-fatal, log freed names). Do NOT delete today's freshly created
  .bak - only prior ones (delete the old ones first, then do the rename so the
  new .bak is never a target).

Acceptance:

- Parser + ASCII clean; `git diff --check` clean; all five smoke modes exit 0
  (this function is not on any smoke path - this just proves no regression).
- Code review: no blanket green on failure; per-service stop/start verification;
  renames guarded and reported; old .bak cleanup runs before the new rename and
  is wrapped non-fatally. The real elevated run stays an owner/Claude task -
  Codex must NOT run it and must NOT claim it ran.

Out of scope: DISM/SFC, resetting more services, BITS queue, changing
`Restart-WindowsUpdateServices`.

### Task C39 - OS junk cleanup in the Cleanup menu

Status: BUILT by Codex (d185db9: Get-WinPulseCleanupTargets catalog,
Measure-WinPulseCleanupTarget, Resolve/Remove helpers,
Invoke-WinPulseCleanupSelected with per-path try/catch + service stop/start,
Invoke-WinPulseOSJunkCleanupMenu wired as a new Cleanup entry, confirm defaults
to No, non-destructive temp-fixture smoke). Reviewed by Claude: safe (deletes
only resolved catalog paths, Recycle Bin via Clear-RecycleBin, all guarded);
the catalog is fully parameterized so smoke tests it without touching real OS
paths. Known minor limitation: Firefox `Profiles\*\cache2` mid-path wildcard is
not expanded (off by default) - acceptable. AWAITING OWNER VISUAL + REAL-MACHINE
VERIFY before merge (it deletes real OS data; verify on a scratch machine).
(Kept below for reference.)

**IMPORTANT - visual verification required AND destructive.** This adds an
interactive menu that DELETES real OS data. Build + validate it (parser, ASCII,
smoke green), but the owner/Claude verify it visually and on a real machine
before merge. Codex must NEVER delete a real OS path in tests - test only the
size-scan/enumeration logic on temp fixtures, and the dry behavior. The existing
WinPulse-artifact cleanup (`Invoke-WinPulseFullArtifactCleanup`,
`Invoke-WinPulseLightCleanup`, `Remove-WinPulseCompletely`) MUST stay unchanged;
this is a NEW, separate action.

Why: the owner wants a real OS junk cleaner - select categories, see sizes,
confirm, delete - not just WinPulse's own artifacts.

Category catalog (FIXED by the owner; each is one selectable item):

- `usertemp`   - `%TEMP%` contents (current user). PRE-TICKED.
- `wintemp`    - `C:\Windows\Temp` contents. PRE-TICKED.
- `recyclebin` - Recycle Bin on all drives (use `Clear-RecycleBin -Force`, or
                 per-drive, in try/catch). PRE-TICKED.
- `windowsold` - `C:\Windows.old` (only OFFER when it exists). PRE-TICKED.
- `wucache`    - `C:\Windows\SoftwareDistribution\Download` contents. Default
                 OFF. Stop wuauserv/bits before clearing, restart after (reuse
                 the C38-hardened pattern conceptually, but do NOT call
                 Repair-WindowsUpdate; just stop/clear/start the two services).
- `deliveryopt`- Delivery Optimization cache
                 (`C:\Windows\SoftwareDistribution\DeliveryOptimization` or via
                 `Delete-DeliveryOptimizationFiles` if present). Default OFF.
- `thumbcache` - Thumbnail/icon cache
                 (`%LocalAppData%\Microsoft\Windows\Explorer\thumbcache_*.db`,
                 `iconcache_*.db`). Default OFF.
- `wer`        - Windows Error Reporting queue/archive
                 (`%ProgramData%\Microsoft\Windows\WER\*`). Default OFF.
- `cbslogs`    - `C:\Windows\Logs\CBS\*`. Default OFF.
- `prefetch`   - `C:\Windows\Prefetch\*` (regenerates). Default OFF.
- `browsercache` - per-user Edge/Chrome/Firefox HTTP cache dirs only (NOT
                 history, NOT passwords, NOT profiles). Default OFF. Note in the
                 confirm screen that open browsers will lock files.
- `memorydumps`- `C:\Windows\Minidump\*` and `C:\Windows\memory.dmp`. Default
                 OFF.

Add a couple more standard ones if obviously safe and easy (e.g. upgrade logs
`C:\Windows\Panther\*`); keep each guarded and OFF by default.

Scope:

- New `Get-WinPulseCleanupTargets`: return an ordered catalog, each item
  `[ordered]@{ Key; Label; Paths=@(...); Mode='contents'|'items'; PreTicked=
  $bool; NeedsServiceStop=$bool; Services=@(...); Note='' }`. Resolve env vars
  at call time. Include `windowsold` only when `C:\Windows.old` exists.
- New `Measure-WinPulseCleanupTarget` (read-only): sum bytes/files for a
  target's paths using the SAME long-path-safe walk built in C37 (share the
  helper) so deep temp trees are measured; tolerate access-denied.
- New `Invoke-WinPulseCleanupSelected`: delete the chosen targets'
  contents/items with per-path try/catch (non-fatal, skip locked/in-use);
  handle `recyclebin` via `Clear-RecycleBin`; for `NeedsServiceStop` stop the
  listed services first and restart after (verify like C38). Return per-target
  freed bytes + error count.
- Rework `Show-WinPulseCleanupMenu`: KEEP the three existing WinPulse-artifact
  entries, ADD "Clean OS junk (temp, caches, Recycle Bin...)". Selecting it:
  show "Scanning..." then build a `Select-WinPulseMultiMenuItem` of the catalog
  with each label showing the measured size (e.g. `User temp           1.2 GB`)
  and PreTicked items ticked via the `Selected` property. After selection show
  total reclaimable and a single-select confirm (Yes/No, DEFAULT No - it is
  destructive). On Yes run the deletion and print a per-category + total
  freed-space report. Esc/No cancels with nothing deleted.
- ASCII-only, StrictMode-safe. Wrap every deletion so one failure never aborts
  the rest. Never delete outside the catalog's resolved paths.

Acceptance:

- Parser + ASCII clean; `git diff --check` clean; all five smoke modes exit 0
  (the menu is interactive and never reached by scripted smoke).
- Add a NON-destructive smoke/unit assertion for the logic only: point
  `Measure-WinPulseCleanupTarget` at a temp fixture folder with known files and
  assert the byte/file totals; assert `Get-WinPulseCleanupTargets` returns the
  catalog with the right PreTicked flags and omits `windowsold` when the path is
  absent. If you exercise `Invoke-WinPulseCleanupSelected`, do it ONLY against a
  temp fixture dir, NEVER a real OS path.
- Visual/real-machine check (owner/Claude): the menu scans sizes, pre-ticks
  Recycle Bin + temps + Windows.old, lets you tick/untick (the new '/' filter
  works here too), the confirm defaults to No, and after Yes the freed-space
  report matches reality. Verify on a scratch machine first.

Out of scope: Disk Cleanup (cleanmgr) automation, DISM component-store cleanup
(`/StartComponentCleanup`), per-app cache deep cleaning, scheduling, registry
cleaning (never), touching the existing WinPulse-artifact cleanup behavior.

