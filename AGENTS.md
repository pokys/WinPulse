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

## Resume Here (next session)

Current state: `main` and `dev/migration-preflight-foundation` are in sync at
`0.14.0-20260603`. Clean tree.

Done 2026-06-03 (second batch, not in previous note):
- C23: CPU load % in Hardware row; WiFi SSID+signal in Network row (segment renderer).
- C24: Findings count in separator `╠══ Findings (N) ══╣`; battery ChargePercent.
- C25: Navigable Diagnostics menu replacing Findings & Details — 7 sections
  (Findings/Drivers/Services/System/Hardware/Security/Network) each with
  colored [CRIT]/[WARN]/[ OK ] badge, one-line summary hint, drill-down detail.
  Badge/BadgeColor support added to Select-WinPulseMenuItem.
- Adaptive findings: dashboard shows `max(1, WindowHeight-30)` findings so
  menu never gets pushed off-screen on short terminals.
- Dashboard: black bg + yellow borders; inline colored values (disk red if
  >90%, BitLocker ON = cyan, Reboot YES = yellow); Scanned inside box.
- Battery row with powercfg fallback (UTF-16 aware, all-mWh regex). Clean tree,
nothing pending uncommitted. Verified: parser + ASCII clean, all fixture smoke
tests pass non-elevated.

Done 2026-06-03 (not yet version-bumped):
- C18: `-SkipBackupAppList` opt-out for backup app-list capture (Codex + review).
- MigrationApps UX batch (Claude): sort not-installed first with labeled separator,
  pre-tick not-installed items via new `Selected` property on multi-select items,
  summary line after selection (Selected | Not installed | Already installed),
  progress counter X/N during install, removed double-confirm (`YES` prompt gone),
  "already installed" winget output treated as success (DarkGreen, not FAILED).
- `Select-WinPulseMultiMenuItem` now pre-ticks items with `Selected = $true`.

Working today: triage scan + dashboard, Quick Triage / Full menu, W11 readiness,
migration preflight, migration backup + restore (interactive AND non-interactive
params) with verification, hash sampling, and HTML/text reports, plus the
startup-perf work, the UX batch (C4-C6, C8, C10), and live copy progress (the
current file streams to a status line during a real backup/restore via robocopy
`/TEE` in `Invoke-WinPulseRobocopy`).

Pick up next, in priority order:

1. Manual elevated live test - DONE end to end (both directions confirmed):
   - BACKUP (2026-06-01, not-logged-in profile): doc folders OK; AppData Partial
     from locked system DBs/caches (WebCache, Comms store, UWP settings.dat) and
     Store-app alias stubs - benign, expected on a live machine; WindowsApps stubs
     excluded in 0.9.6.
   - RESTORE (2026-06-02, 0.10.2): a real CROSS-MACHINE migration (backup from a
     notebook `d:\vokurka` restored onto `DESKTOP-UJTQHBL`), 67.79 GB, 7 folders
     including a 5298-file Chrome profile that round-tripped exactly. Failed=0,
     Partial=0, Mismatch=0, all Verified. Non-destructive (robocopy extras kept).
   The copy path is now proven live in both directions. Remaining live-only ideas
   are the backlog items below (long paths, VSS, the C16 winget reinstall).
2. Interactive TUI session for the deferred UX items C7 / C9 / C11 (see
   "Work Queue - Batch 2"). These change live rendering the smoke tests cannot
   see, so build them on `dev`, confirm visually at >= 90 columns (must look
   unchanged), then merge. C7 is optional/low-value; C9 and C11 are the wins.
3. Optional perf: C3 BitLocker progressive load (~5s off time-to-dashboard;
   touches dashboard render, so also an interactive-session item).

Backlog (not scheduled): remote backup/restore over SMB C$ (Phase 1 groundwork
already exists via `Get-WinPulseMigrationProfiles -root`), restore remap to a
different user name, selective AppData, incremental backup. See the migration
"Backlog" and "Candidate feature: Remote over SMB (C$)" sections below.

Workflow reminder: commit identity is `pokys`; after any change run the parser
check + ASCII check + both fixture smoke tests; do not push TUI-rendering
changes to `main` until visually verified; Claude bumps the version and merges.

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

### Task C30 - Remote backup via SMB C$ (Phase 1 MVP)

Why: technicians often need to pull a user's data from a remote PC over the
network without logging into it physically. WinPulse's robocopy engine already
handles UNC paths natively and `Get-WinPulseMigrationProfiles` already accepts a
`-Root` parameter from Task C1. This task adds source selection and UNC plumbing.

Safety boundaries (FIXED - do not change without asking Claude):
- Use the technician's current Windows token only (transparent Kerberos/NTLM).
  No `Get-Credential`, no `New-SmbMapping`, no credential prompts in Phase 1.
- No PSRemoting (`Enter-PSSession`, `Invoke-Command`), no remote WMI execution.
  SMB file copy does not execute code on the remote host - this is by design.
- Locked files on a live PC (NTUSER.DAT, open browser DBs, OST) will silently
  fail to copy. This is expected for live machines; document it in the plan
  summary but do not treat it as a backup failure.
- The remote root must resolve to a UNC path `\\HOST\C$\Users`. Reject anything
  that does not produce a valid UNC.

Scope:

**1. Top-level parameter**

Add `-BackupSourceHost <string>` to the top `param()` block. Plumb it through
`Invoke-WinPulseMode` to `Invoke-WinPulseMigrationBackup` and the elevation
passthrough (mirror `-BackupHashSample` and other backup switches).

**2. Helper: `Get-WinPulseRemoteUsersRoot`**

Add near the other `Get-WinPulse*` migration helpers:

```powershell
function Get-WinPulseRemoteUsersRoot {
    param([Parameter(Mandatory)][string]$Hostname)
    $hostname = $Hostname.Trim().TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($hostname)) { return $null }
    $uncRoot = '\\{0}\C$\Users' -f $hostname
    Write-Host ('  Checking reachability: {0} ...' -f $uncRoot) -ForegroundColor Gray
    try {
        if (-not (Test-Path -LiteralPath ('\\{0}\C$' -f $hostname) -ErrorAction Stop)) {
            Write-Host '  Remote C$ not reachable. Check hostname, admin rights and firewall.' -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host ('  Remote C$ not reachable: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $null
    }
    Write-Host '  Remote C$ reachable.' -ForegroundColor Green
    return $uncRoot
}
```

**3. Source selection in `Invoke-WinPulseMigrationBackup`**

At the very start of `Invoke-WinPulseMigrationBackup`, before profile discovery,
determine the profiles root. This REPLACES the existing `$profilesRoot = $null`
or `-BackupProfilesRoot` default assignment. Use the existing `-BackupProfilesRoot`
parameter to pass the UNC root through to `Get-WinPulseMigrationProfiles -Root`
(it already exists from Task C1 — do not add a second root parameter).

Non-interactive (when `-BackupSourceHost` is provided):
```powershell
if (-not [string]::IsNullOrWhiteSpace($BackupSourceHost)) {
    $resolvedRoot = Get-WinPulseRemoteUsersRoot -Hostname $BackupSourceHost
    if (-not $resolvedRoot) { return }
    $BackupProfilesRoot = $resolvedRoot
}
```

Interactive (when `-BackupSourceHost` is absent AND `-BackupProfilesRoot` is not
already set by the caller):
```powershell
$srcChoice = Select-WinPulseMenuItem -Title 'Backup source' -Items @(
    @{ Label = 'This PC';              Key = 'L'; Hint = 'Local C:\Users' }
    @{ Label = 'Remote PC  (via C$)';  Key = 'R'; Hint = 'Pull from another PC over the network' }
)
if (-not $srcChoice) { return }
if ($srcChoice -eq 'R') {
    $hostname = Read-Host '  Remote hostname or IP'
    if ([string]::IsNullOrWhiteSpace($hostname)) { return }
    $resolvedRoot = Get-WinPulseRemoteUsersRoot -Hostname $hostname
    if (-not $resolvedRoot) { return }
    $BackupProfilesRoot = $resolvedRoot
}
# else: BackupProfilesRoot stays null = existing default (C:\Users)
```

Guard the interactive block with the same non-interactive check used elsewhere
in the function (i.e. do NOT show the picker when the caller is already running
non-interactively via params).

**4. Manifest**

Add `SourceHost` to the manifest Tool section:
```powershell
SourceHost = if (-not [string]::IsNullOrWhiteSpace($BackupSourceHost)) { $BackupSourceHost } else { $env:COMPUTERNAME }
```

**5. Plan/summary display**

When a remote root is in use, add two lines to the pre-copy plan output
(near where `Excluded files` and `Opt-in scope` are shown):
```
  Source host : \\HOSTNAME\C$\Users
  Note: locked files on a live PC (open DBs, NTUSER.DAT) will be skipped.
```

**6. Repeat-command hint (C10)**

In the post-backup repeat-command hint, append `-BackupSourceHost <hostname>`
when a remote source was used.

**7. Visual verification required**

The two-item source picker (This PC / Remote PC) uses `Select-WinPulseMenuItem`.
Build on `dev`, validate parser + ASCII + all smoke modes, then report.
Claude will verify the picker visually before merge to main.

Acceptance (non-elevated, temp fixtures):

- Parser clean, ASCII check empty, git diff --check clean.
- All four migration smoke modes exit 0. Smoke uses local `-BackupProfilesRoot`
  so the remote path is never exercised - this confirms nothing regressed.
- Code review: `Get-WinPulseRemoteUsersRoot` contains no PSRemoting or remote
  WMI; the UNC root is passed through the existing `-BackupProfilesRoot`
  mechanism; the locked-files note appears in the plan summary when remote is used.
- Visual check (Claude before merge): source picker shows "This PC / Remote PC";
  selecting Remote prompts for hostname; unreachable host prints a clear red error
  and cancels without crashing.

Out of scope: `Get-Credential`, `New-SmbMapping`, remote restore or verify,
VSS shadow copies, drive label enumeration, incremental over slow links,
PSRemoting or any remote code execution.

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
