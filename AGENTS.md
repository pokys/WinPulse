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

## Work Queue - Batch 6 (queued 2026-06-11)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), one commit, do NOT
push to main, do NOT bump the version, keep `bootstrap.ps1` ASCII-only /
StrictMode-safe / PS 5.1, bracket notation for hashtable access. Report changes
plus full test output. Stop and ask if anything is ambiguous.

### Task C40 - Smoke coverage: diagnostics render functions must not throw on degenerate scans

Why: a string of StrictMode crashes shipped because the smoke harness never
calls the interactive Diagnostics functions, only the migration modes. Two
classes bit us repeatedly: (1) `$x = if (cond) { @(..) } else { @() }` collapses
to `$null` under StrictMode (an empty-array branch emits nothing) and `$null.Count`
then throws; (2) `$scan.Security` is an `[ordered]` hashtable, so guarding its
keys with `.PSObject.Properties[...]` silently fails (it does not see hashtable
keys) - use `.Contains('key')`. A non-elevated smoke that renders these functions
against empty/missing data would have caught every one. Build it.

This is pure non-elevated logic (no TUI rendering to eyeball, no elevation, no
real scan). It extends the EXISTING harness in
`tools/Invoke-WinPulseSmokeTest.ps1` - do NOT add a new test framework.

Scope:

- Add `Invoke-SmokeDiagnosticsRenderAssertions -BootstrapPath <path>`, modelled
  on the existing `Invoke-SmokeCleanupLogicAssertions` /
  `Invoke-SmokeLongPathEnumerationAssertions` blocks, and call it near the top of
  the smoke run (alongside those) so EVERY `-Mode` exercises it.
- Inside it: stub the host-interaction commands so the functions run headless and
  never block - define local `function Clear-Host {}`, `function Wait-WinPulseKey {}`,
  `function Write-WinPulseHeader { param($title) }`, and a `Write-Host` stub that
  swallows output. Stub any menu/selection helper a render path might call
  (`Select-WinPulseMenuItem`, `Select-WinPulseMultiMenuItem`,
  `Select-WinPulseFindingItem`, `Show-WinPulsePagedTextBox`) to return `$null`
  so nothing waits on a key.
- Dot-source the functions under test and their pure dependencies via the
  existing `Get-SmokeBootstrapFunctionText` AST helper (it already extracts named
  functions). At minimum: `Get-WinPulseTriageFindings`,
  `Get-WinPulseObjectValue`, `Get-WinPulseDiagnosticsCpuShort`,
  `Get-WinPulseStateFromPercent`, `ConvertTo-ReadableSize`,
  `Get-WinPulseFindingDetailTarget`, `Show-WinPulseFindingDetailTarget`,
  `Show-WinPulseDiagnosticsFindings`, `Show-WinPulseDiagnosticsDrivers`,
  `Show-WinPulseDiagnosticsServices`, `Show-WinPulseDiagnosticsSystem`,
  `Show-WinPulseDiagnosticsHardware`, `Show-WinPulseDiagnosticsSecurity`,
  `Show-WinPulseDiagnosticsNetwork`. Add any others these call that are not
  already stubbed (resolve missing-command errors by extracting more functions;
  do NOT stub a function whose real logic is under test).
- Build a matrix of degenerate `$scan` objects (use `[ordered]@{}` for the scan
  SECTIONS exactly as `Invoke-CoreScan` builds them - Security/Drivers/Startup/
  Hardware/etc. are ordered hashtables, not pscustomobjects). Cover at least:
  - all sections present but EMPTY arrays (Antivirus.Products `@()`, BitLocker
    `@()`, Drivers.Problematic/Unsigned `@()`, Startup.FailedAutoServices `@()`,
    Hardware.Disks `@()`) - this reproduces the shipped Security crash;
  - sections present with realistic data (ESET product, one BitLocker volume,
    one problematic driver, disks) - asserts correct, not just non-throwing;
  - a "minimal" scan where optional sub-keys are absent where the collectors can
    legitimately omit them.
- For EACH scan shape, call every `Show-WinPulseDiagnostics*` detail function
  (and `Show-WinPulseDiagnosticsFindings`) inside try/catch and FAIL the smoke
  with a clear message if any throws. For the data-present shape, also capture
  the `Write-Host` stub's collected lines and assert the AV product name appears
  in the Security output (guards against the hashtable-key regression).
- Clean up any temp artifacts in a `finally`.

Acceptance:

- Parser + ASCII clean; `git diff --check` clean.
- ALL five non-elevated smoke modes exit 0 with the new assertions running;
  MigrationPreflight needs elevation, skip it and say so.
- Sanity-check the test actually bites: temporarily reintroduce the
  `if(){...}else{@()}` empty-BitLocker pattern in `Show-WinPulseDiagnosticsSecurity`
  locally, confirm the new assertion FAILS, then revert. Report that you did this.

Out of scope: changing any diagnostics function's behavior, adding Pester, TUI
rendering/layout, the migration modes.

## Work Queue - Batch 7 (queued 2026-06-12)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), do NOT push to
main, do NOT bump the version, keep `bootstrap.ps1` ASCII-only /
StrictMode-safe / PS 5.1, bracket notation for hashtable access. Tasks are
SEQUENTIAL: C41 then C42 then C43, ONE commit per task (C42 builds on C41's
menu shape). If C40 is not yet done, do it first. Report changes plus full
test output. Stop and ask if anything is ambiguous.

Owner-approved UX redesign context (applies to C41+C42): WinPulse currently
has TWO top-level menus (`Show-WinPulseTriageMenu` is the default entry,
`Show-WinPulseMainMenu` hides behind its "Full menu" item) that overlap, and
five menus are defined but unreachable from any menu
(`Show-WinPulseNetworkMenu`, `Show-WinPulseSecurityMenu`,
`Show-WinPulseStressMenu`, `Show-WinPulseCleanupMenu`,
`Show-WinPulseTweaksMenu`). The owner approved collapsing to ONE main menu and
wiring the orphans back in (except Tweaks, which stays an unwired placeholder).

### Task C41 - Single main menu, wire orphaned menus, Back/breadcrumb consistency

Scope:

1. Delete `Show-WinPulseTriageMenu` entirely. In `Invoke-WinPulseMode`, the
   `'Triage'` branch calls `Show-WinPulseTriageMenu -scan $scan` - change it to
   `Show-WinPulseMainMenu -scan $scan`. Nothing else references the triage
   menu. Its unique items are NOT lost: "Findings & Details" was the
   Diagnostics hub (now main-menu `D`), "Safe actions" lives in Repairs, and
   "Re-scan" / "Inspect logs" move into the Diagnostics hub in C42 (they are
   intentionally unreachable for the one commit between C41 and C42 - do not
   re-add them elsewhere).

2. Rebuild the `Show-WinPulseMainMenu` item list as (keys changed where noted):

   ```powershell
   $choice = Select-WinPulseMenuItem -Title 'Main Menu' -Items @(
       @{ Label = 'Diagnostics';      Key = 'D'; Hint = 'Findings & health' },
       @{ Label = 'Repairs (Guided)'; Key = 'R'; Hint = 'Fix issues' },
       @{ Label = 'Security';         Key = 'S'; Hint = 'Assessment/BitLocker' },
       @{ Label = 'Apps';             Key = 'A'; Hint = 'Install/remove/update' },
       @{ Label = 'Migration';        Key = 'M'; Hint = 'Backup/restore/verify' },
       @{ Label = 'W11 readiness';    Key = 'W'; Hint = 'Upgrade signals' },
       @{ Label = 'Tools';            Key = 'T'; Hint = 'Portable + stress tests' },
       @{ Label = 'Cleanup';          Key = 'C'; Hint = 'OS junk + WinPulse data' },
       @{ Label = 'Export';           Key = 'X'; Hint = 'JSON / HTML' },
       @{ Separator = $true },
       @{ Label = 'Exit';             Key = 'Q'; Color = 'DarkGray' }
   )
   ```

   Dispatch: `'D'` -> `Show-WinPulseDiagnosticsMenu -scan $scan` (NOT the old
   `Invoke-WinPulseDiagnostics` batch run - that gets re-homed in C42; it is
   intentionally unreachable for one commit). `'R'` ->
   `$scan = Invoke-WinPulseRepairs -scan $scan`. `'S'` ->
   `Show-WinPulseSecurityMenu`. `'A'` -> `Show-WinPulseInstallMenu`. `'M'` ->
   `Show-WinPulseMigrationMenu`. `'W'` -> `Show-WinPulseWindows11Readiness;
   Wait-WinPulseKey`. `'T'` -> `Show-WinPulseToolsMenu`. `'C'` ->
   `Show-WinPulseCleanupMenu` (the hub, NOT `Invoke-WinPulseOSJunkCleanupMenu`
   directly). `'X'` -> `Show-WinPulseExportMenu -scan $scan`. `'Q'` ->
   `Invoke-WinPulseExitCleanupPrompt; return` (exit behavior itself is
   unchanged - the owner explicitly declined changing it). Esc / `default`
   keeps looping (must NOT exit).

3. `Invoke-WinPulseRepairs`: add one item
   `@{ Label = 'Network repair'; Key = 'N'; Hint = 'DNS/TCP/adapters' }` ->
   `Show-WinPulseNetworkMenu` (it loops internally and returns; `$scan` is not
   involved). Keep the function returning `$scan` on every exit path.

4. `Show-WinPulseToolsMenu`: remove the `StressMyPC` and `FurMark` entries
   (they live in the stress submenu) and add
   `@{ Label = 'Stress tests'; Key = 'S'; Hint = 'CPU/RAM/disk/GPU' }` ->
   `Show-WinPulseStressMenu`. Flow fix while you are there: the trailing
   `Write-Host ''; Wait-WinPulseKey` after the switch currently also fires
   after returning from the NirSoft submenu, because `continue` inside a
   `switch` does NOT re-enter the `while` loop (documented footgun). Move the
   `Write-Host ''; Wait-WinPulseKey` pair INTO each tool-launcher branch and
   give the two submenu branches (`S` stress, `N` NirSoft) no trailing wait.

5. `Show-WinPulseCleanupMenu` (currently orphaned, becomes the `C` target):
   reorder so `OS junk cleanup` (key `O`) is FIRST, then a separator, then the
   WinPulse-artifact items (`Light cleanup`, `Full artifact cleanup`,
   `Remove WinPulse folder`). Drop the `Wait-WinPulseKey` after
   `Invoke-WinPulseOSJunkCleanupMenu` (it has its own loop and exit flow).

6. Back/breadcrumb convention, applied to EVERY submenu (this is the bulk of
   the diff - keep it mechanical):
   - First line after `Clear-Host`:
     `Write-Host '  Main > <Path>' -ForegroundColor DarkGray` with these exact
     paths: `Main > Diagnostics`, `Main > Repairs`,
     `Main > Repairs > Network`, `Main > Security`, `Main > Apps`,
     `Main > Apps > Office`, `Main > Migration`, `Main > Tools`,
     `Main > Tools > NirSoft`, `Main > Tools > Stress`, `Main > Cleanup`,
     `Main > Export`, `Main > Repairs > Safe actions` (Safe Actions is reached
     from Repairs). Update the two existing breadcrumbs (`Main > Network`,
     `Main > Security`) to match. `Show-WinPulseExportMenu` has no
     `Clear-Host` today - add one plus the breadcrumb at the top of its loop.
   - Last two items of every submenu: `@{ Separator = $true }` and
     `@{ Label = 'Back'; Key = '0'; Color = 'DarkGray' }`. Esc (null choice)
     must also return. Replace the existing nonstandard Back keys (NirSoft
     `X`, Migration `Q`, Network `B`, Security `X`) and add the Back item to
     menus that lack it (Tools, Apps, Office, Cleanup, Export, Stress, Safe
     Actions, Repairs). Digit keys are already supported
     (`Select-WinPulseMenuItem` repair-plan menus use them).
   - Do NOT touch the `Show-WinPulsePagedTextBox` breadcrumb parameters except
     where the path strings above changed (Network/Security ones).

Acceptance: parser + ASCII clean; `git diff --check` clean; all five
non-elevated smoke modes exit 0 (the smoke harness never opens the interactive
menus, so this guards regressions only); confirm by grep that
`Show-WinPulseTriageMenu` is gone and that every `Show-WinPulse*Menu` except
`Show-WinPulseTweaksMenu` now has at least one caller. The owner will verify
the TUI visually before any merge - do not attempt to screenshot it yourself.

Out of scope: exit-cleanup behavior, Tweaks menu, diagnostics hub content
(C42), any change to what the individual actions DO.

### Task C42 - Diagnostics hub: absorb deep suite, logs, re-scan; return the scan

Why: after C41 the old batch "Diagnostics" run (`Invoke-WinPulseDiagnostics`,
a 6-step suite including a 10s RAM test and a 512MB disk stress test) and the
triage menu's "Re-scan" / "Inspect logs" items have no home. They belong inside
the Diagnostics hub (`Show-WinPulseDiagnosticsMenu`).

Scope:

1. In `Show-WinPulseDiagnosticsMenu`, append to the `$items` array after the
   seven section rows:

   ```powershell
   @{ Separator = $true }
   @{ Label = 'Deep test suite'; Key = 'T'; Hint = 'RAM+disk stress, takes minutes' }
   @{ Label = 'Inspect logs';    Key = 'L'; Hint = 'Last 24h' }
   @{ Label = 'Re-scan';         Key = 'R'; Hint = 'Refresh data' }
   @{ Separator = $true }
   @{ Label = 'Back';            Key = '0'; Color = 'DarkGray' }
   ```

   Switch branches (NO `continue` inside the switch - footgun):
   - `'T'`: plain `if` confirm, then run:
     ```powershell
     $answer = Read-Host '  Deep suite runs RAM + disk stress tests (several minutes). Continue? [y/N]'
     if ($answer -match '^[Yy]') { Invoke-WinPulseDiagnostics }
     ```
   - `'L'`: `Clear-Host; Show-WinPulseEventLogInspection -hourback 24 -maxitems 12; Write-Host ''; Wait-WinPulseKey`
     (verbatim from the deleted triage menu).
   - `'R'`: `$scan = Invoke-CoreScan` (the hub's badges recompute on the next
     loop iteration, which is the point).

2. The hub must now RETURN the (possibly refreshed) scan: change every exit
   path (`default` branch and the `'0'`/Esc path) to `return $scan`, and change
   the C41 main-menu call site to
   `$scan = Show-WinPulseDiagnosticsMenu -scan $scan`. StrictMode caution: the
   `Show-WinPulseDiagnostics*` detail calls are Write-Host based and emit
   nothing, but double-check nothing in the loop leaks objects into the output
   stream, otherwise the caller's `$scan` becomes an array.

Acceptance: parser + ASCII clean; `git diff --check` clean; five smoke modes
exit 0 (C40's `Invoke-SmokeDiagnosticsRenderAssertions` exercises the render
functions and must stay green); grep-confirm `Invoke-WinPulseDiagnostics` has
exactly one caller (the hub) and `Show-WinPulseDiagnosticsMenu` is assigned at
its call site.

Out of scope: the content/order of the deep suite itself, the seven detail
screens, dashboard.

### Task C43 - Startup access gate (soft technician code)

Why: WinPulse is fetched from a public repo and runs destructive-capable
actions. The owner wants a startup access code so a casual user who finds the
one-liner cannot stumble through it. This is EXPLICITLY a soft gate: the hash
lives in a public script and anyone can edit it out. Do not oversell it and do
not add anything beyond what is specced (no lockouts, no telemetry, no
obfuscation - the last one is a project non-goal).

Scope:

1. Param block: append `[switch]$AccessGranted` after `$_LiveProfilesRoot`.
   Do NOT add it to `Invoke-WinPulseMode`.

2. Near `$script:WinPulseVersion`, add:

   ```powershell
   # Soft startup gate. SHA256 of the access code; regenerate with:
   #   $sha=[Security.Cryptography.SHA256]::Create()
   #   ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('NewCode'))|%{$_.ToString('x2')})-join''
   $script:WinPulseAccessCodeHash = 'e3129f656b76c6fb238de685b85553b3851cc1d35d86cef5089f15853cc7fc82'
   ```

   (That is the hash of the initial code `WinPulse2026`; the owner will swap
   it before release.)

3. New function `Request-WinPulseAccessGate` (place it right after
   `Start-WinPulseElevation`):
   - Return immediately if `$AccessGranted` is set or
     `$env:WINPULSE_ACCESS_GRANTED -eq '1'`.
   - Otherwise up to 3 attempts: prompt
     `Read-Host -Prompt '  Access code' -AsSecureString` inside try/catch (a
     non-interactive host throws here - treat a throw OR an empty string as a
     failed attempt, never loop forever). Convert via
     `[Runtime.InteropServices.Marshal]::SecureStringToBSTR` /
     `PtrToStringBSTR` and free with `ZeroFreeBSTR` in a `finally`. Hash the
     UTF8 bytes with SHA256, hex-encode, compare to
     `$script:WinPulseAccessCodeHash` with `OrdinalIgnoreCase`.
   - On success: `$env:WINPULSE_ACCESS_GRANTED = '1'` (child and elevated
     processes inherit it) and return.
   - After 3 failures: `Write-Host 'Access denied.' -ForegroundColor Red`,
     `exit 1`.

4. Call site: in the top-level execution block, immediately BEFORE the
   `$elevationPassthrough = @()` line, call `Request-WinPulseAccessGate`.
   After the passthrough array is fully built, append
   `$elevationPassthrough += '-AccessGranted'` unconditionally (reaching that
   line means the gate passed or was bypassed), so the elevated relaunch via
   `-File` never re-prompts. The `irm | iex` path cannot carry parameters, but
   it relaunches through a temp file with passthrough args, and the env var
   covers same-process-tree cases anyway.

5. Smoke harness (`tools/Invoke-WinPulseSmokeTest.ps1`): set
   `$env:WINPULSE_ACCESS_GRANTED = '1'` right after the PowerShell executable
   is resolved (the `$powershell = (Get-Command ...)` line), with a short
   comment, and `Remove-Item Env:WINPULSE_ACCESS_GRANTED -ErrorAction
   SilentlyContinue` at the end of the run. Child processes inherit it, so all
   modes stay non-interactive.

Acceptance: parser + ASCII clean; `git diff --check` clean; all five
non-elevated smoke modes exit 0 WITHOUT any prompt appearing; negative test:
`powershell -NoProfile -NonInteractive -File .\bootstrap.ps1` with the env var
absent must print `Access denied.` and exit 1 within seconds (Read-Host throws
in NonInteractive mode, which counts as failed attempts - report the observed
output); positive test: same command with `WINPULSE_ACCESS_GRANTED=1` must get
past the gate (it will then start the interactive scan - kill it after the
`LOADED` lines appear and say so).

Out of scope: changing the elevation flow, persisting anything, rate limiting,
storing the plaintext code anywhere in the repo besides this spec.

## Work Queue - Batch 8 (queued 2026-06-16)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), ONE commit, do NOT
push to main, do NOT bump the version. Report changes plus full test output.
Stop and ask if anything is ambiguous.

### Task C45 - Pester unit tests for pure parsers/builders

Why: the recurring bug class in WinPulse is logic errors in pure functions that
the smoke harness does not cover. Two recent shipped bugs prove it: (a) the tool
catalog read keys with `$tool.PSObject.Properties['Urls']` on an `[ordered]`
hashtable (always empty -> every tool download failed), and (b) the HTML report
hit `.Count` on a single-object scan section under StrictMode. Both are pure
logic a unit test would have caught. Add real unit tests for the pure functions.

This INTRODUCES Pester deliberately (the smoke harness in
`tools/Invoke-WinPulseSmokeTest.ps1` intentionally avoids it; leave that file
alone). The new tests are a SEPARATE, dev-only project under a new `tests/`
folder. They must NOT change `bootstrap.ps1` behavior at all.

Hard constraint - loading functions without running the script: `bootstrap.ps1`
is a single file whose top level runs the access gate, elevation, and menu, so
you CANNOT dot-source it. Reuse the exact approach the smoke harness already
uses: `Get-SmokeBootstrapFunctionText -BootstrapPath <path> -Name @(...)` in
`tools/Invoke-WinPulseSmokeTest.ps1` (around line 132) extracts named function
source via the AST. Either dot-source that helper from the test bootstrap or
copy the same ~15-line AST extractor into a `tests/` helper. Extract only the
functions under test (plus any pure dependency they call) and `Invoke-Expression`
the extracted text into the test scope. Define `$script:WinPulsePaths` as a
stub hashtable if any extracted function references it.

Scope - first batch, genuinely pure / fixture-pure functions only (line numbers
approximate, find by name):

- `ConvertTo-ReadableSize` (~L223): `0 -> '0 B'`, `1536 -> '1.50 KB'`,
  boundaries at 1KB/1MB/1GB/1TB, large TB value. Culture-invariant dot decimal.
- `Get-WinPulseStateFromPercent` (~L261): default thresholds (warning 70,
  critical 90) -> OK/Warning/Critical at representative percents; `-inverse`
  flips the comparison (low values are Critical).
- `Get-WinPulseObjectValue` (~L3595): the dual dictionary/pscustomobject reader.
  Assert it returns the value for an existing key on BOTH an `[ordered]@{}` and a
  `[pscustomobject]`, and `$null` for a missing key on both. This is the helper
  that prevents the catalog-class bug - test it hard.
- `Get-WinPulseToolCatalog` (~L8288): CATALOG-SHAPE REGRESSION TEST. For every
  entry `$tool = (Get-WinPulseToolCatalog)[$key]`, assert
  `$tool.Contains('Urls') -or $tool.Contains('Url')` AND the value is non-empty,
  and `$tool.Contains('BinaryCandidates') -or $tool.Contains('Binary')`. Also
  assert that reading via `.Contains()`/bracket yields a non-empty source list
  while `$tool.PSObject.Properties['Urls']` is empty (encodes WHY bracket access
  is required, so a regression to PSObject.Properties is caught).
- `Get-WinPulseWingetExportPackageIds` (~L6880): write temp winget-export JSON
  fixtures under `[IO.Path]::GetTempPath()` (clean up in a finally). Cover:
  a normal export with several packages -> sorted, de-duplicated ids; duplicate
  ids collapsed; missing `Sources`/`Packages` -> empty array; empty/whitespace
  file -> empty array; malformed JSON -> does not crash the test harness (the
  function uses `-ErrorAction Stop` on ConvertFrom-Json, so wrap the malformed
  case in try/catch and assert it throws rather than returning garbage).
- `New-WinPulseWingetInstallCommandText` (~L6943) and
  `Get-WinPulseRobocopyFailedEntries` (~L5515): inspect each signature first,
  then add focused tests - command-text builder against a couple of ids; the
  robocopy parser against sample lines containing `ERROR` entries vs clean
  output (assert it extracts the failed paths and returns empty on clean input).

Deliverables:

- `tests/WinPulse.Pure.Tests.ps1` - Pester 5.x test file (Describe/Context/It,
  `Should -Be` / `-BeNullOrEmpty` / `-Throw`). Group by function.
- `tests/Invoke-WinPulseTests.ps1` - a tiny runner: resolve repo root, verify
  Pester >= 5 is available (if not, print the exact
  `Install-Module -Name Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck`
  line and exit 1 - do NOT silently fall back to Pester 3.4, whose syntax
  differs), then `Invoke-Pester` the tests with a non-zero exit on failure.
- A short `tests/README.md` (how to run, Pester requirement).

Acceptance:

- `tests/Invoke-WinPulseTests.ps1` runs green on a machine with Pester 5.x.
- Report the full Pester summary output.
- "Does it bite" check (like C40): temporarily revert `Get-WinPulseObjectValue`
  or the catalog read to the broken `PSObject.Properties` form OR break
  `ConvertTo-ReadableSize`, confirm a test FAILS, then revert. Report that you
  did this.
- `bootstrap.ps1` is unchanged (the tests only READ it). `git diff` touches only
  the new `tests/` files.

Out of scope (note as a follow-up Batch, do NOT attempt now): functions that
touch the filesystem or real machine state - the plan builders
(`New-WinPulseBackupPlan`, `New-WinPulseRestorePlanObject`),
`Get-WinPulseTriageFindings` (needs a full scan fixture), and anything calling
`robocopy`/`winget`/CIM. Those need heavier fixtures and come later once the
harness pattern is proven. Do NOT modify `bootstrap.ps1` or the smoke harness.

## Work Queue - Batch 9 (queued 2026-06-16)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), ONE commit, do NOT
push to main, do NOT bump the version. Report changes plus full test output.
Stop and ask if anything is ambiguous. PREREQUISITE: C45 (Batch 8) must be in
already - this builds on the `tests/` Pester harness it created.

### Task C46 - Pester unit tests, wave 2 (plan totals, exclusions, triage)

Why: C45 covered the leaf pure helpers; this wave covers the next layer that is
still pure-or-fixture-testable and carries real safety/logic weight. Extend the
EXISTING `tests/WinPulse.Pure.Tests.ps1` (same harness, same AST extractor, same
runner) - add Describe blocks, do not create a second test file. Add each
function under test plus its pure dependencies to the `$functionNames` extraction
list in the `BeforeAll`. `bootstrap.ps1` stays UNCHANGED (tests only read it).

Functions and what to assert (find by name; line numbers approximate):

- `Get-WinPulseRestoreTargetUserName` (~L7440): pure name validation.
  `$null`/whitespace -> `$null`; a normal name -> trimmed; a name with
  surrounding spaces -> trimmed; `.`, `..`, and a name containing an invalid
  filename char (e.g. `a\b` or `a:b`) -> THROWS. (ASCII the test strings.)
- `New-WinPulseRestorePlanObject` (~L7471): pure totals builder (deps:
  `Get-WinPulseRestoreTargetUserName`, `ConvertTo-ReadableSize` - add both to the
  extraction list). Build a hand-made `$items` array of
  `[pscustomobject]`s with `Exists`, `Bytes`, `TargetExists` fields and assert
  the returned plan: `ItemCount` = total items; `ExistingCount` = count where
  `Exists`; `OverwriteCount` = count where `Exists -AND TargetExists`;
  `TotalBytes` = sum of `Bytes` over `Exists` items only (a non-existing item
  with Bytes must NOT be summed); `TotalSize` = `ConvertTo-ReadableSize` of that;
  `RestoreRoot` echoes the input; `RestoreAsUser` echoes the validated name.
  Also cover the empty-array case -> all counts 0, TotalBytes 0, '0 B'.
- `Get-WinPulseBackupExclusions` (~L5150): SAFETY-BOUNDARY regression test - this
  is the highest-value one. Default (no switch): the `Files` list MUST contain the
  SSH/PuTTY key patterns (`*.ppk`, `id_rsa`) and the registry hive patterns
  (`NTUSER.DAT`), and the `Dirs` list MUST contain `.ssh`/`.gnupg`. Certificate
  patterns (`*.pfx`, `*.p12`, `*.pem`, `*.cer`, `*.crt`) MUST NOT appear anywhere
  in Files/Dirs (they are deliberately INCLUDED in backups - a regression that
  excludes them would silently drop certs). With `-includePrivateKeys`: hives
  (`NTUSER.DAT`) still excluded, but the SSH/PuTTY key patterns are NO LONGER in
  the Files list. Assert both shapes have the documented structure (Files/Dirs/
  Note properties).
- `Get-WinPulseTriageFindings` (~L2933): pure given a `$scan` (deps: extract
  `Get-WinPulseObjectValue`). FIXTURE NOTE: build `$scan` the way `Invoke-CoreScan`
  does - a `[pscustomobject]` whose SECTIONS (`Health`, `System`, `Security`,
  `Network`, `Hardware`, `Drivers`, `TPM`, etc.) are `[ordered]@{}` hashtables,
  and list sub-keys (e.g. `Drivers.Problematic`, `Hardware.Disks`) are real
  ARRAYS `@(...)` (a single bare object would hit the StrictMode `.Count` trap -
  that is realistic, the collectors build arrays). Cover at least:
  - a HEALTHY scan (firewall on, realtime AV on, internet ok, no pending reboot,
    empty driver/disk arrays, TPM 2.0 present+compatible) -> ZERO findings.
  - a scan that trips specific rules and assert the matching finding by Severity
    + a Message substring: Firewall OFF -> a `Critical` finding mentioning
    'Firewall'; `Security.Antivirus.EffectiveRealtimeProtection = $false` ->
    `Critical` 'real-time'; `Health.PendingReboot = $true` -> `Warning`
    'reboot'; a C: disk at `UsedPercent = 95` -> `Warning` about the system
    drive; `Drivers.Problematic` with 4 entries -> a `Critical` finding (the
    `> 3` threshold) mentioning the count.
  - DEGENERATE shape: sections present but list keys EMPTY arrays, and optional
    sub-objects (`System.DumpInfo`, `TPM`) absent -> must NOT throw and returns a
    sane (possibly empty) finding set. This guards the StrictMode null/Count traps.
  Return value is an array of objects with `Severity` and `Message`; wrap calls
  in `@(...)` before `.Count`.

Deliverables: the new Describe blocks appended to
`tests/WinPulse.Pure.Tests.ps1`, with the extraction list extended. Update
`tests/README.md` only if the function list there is enumerated.

Acceptance:

- `tests/Invoke-WinPulseTests.ps1` runs green; report the full Pester summary.
- "Does it bite" check: temporarily break ONE assertion's target (e.g. flip a
  threshold in the test's expectation OR temporarily remove `*.pfx` from the
  cert-exclusion negative check by asserting it IS excluded), confirm a test
  FAILS, then revert. Report it.
- `git diff` touches only `tests/` files; `bootstrap.ps1` unchanged.

Out of scope (still deferred): `New-WinPulseBackupPlan` and the restore plan
build that call `Get-WinPulsePathSize`/`Get-WinPulseBackupAppTargets` (need real
temp-profile fixtures - a later batch); robocopy/winget/CIM-invoking functions.

## Work Queue - Batch 10 (queued 2026-06-23)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), do NOT push to main,
do NOT bump the version, keep `bootstrap.ps1` ASCII-only / StrictMode-safe /
PS 5.1, bracket notation for hashtable access. Tasks are INDEPENDENT, ONE commit
per task. Report changes plus full test output. Stop and ask if anything is
ambiguous.

### Task C47 - Startup "newer version available" check (best-effort, non-blocking)

Why: WinPulse runs are HEAD of `main` via `irm | iex`, but a technician who saved
a local copy (or an elevated relaunch from a temp file) never learns it is stale.
Add a cheap startup check that compares the running version against the version
in the published `main` script and prints a one-line notice. This is a courtesy
signal only - it must NEVER block, prompt, auto-update, or change the exit code.

Context: `$script:WinPulseVersion` (~L72) is `'MAJOR.MINOR.PATCH-YYYYMMDD'`. The
published raw URL is already hardcoded at the elevation call site (~L13685):
`https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1`. The
startup banner prints `WinPulse {version}` in the `Triage`/`Repair` branches of
`Invoke-WinPulseMode` (~L13468/L13478) right before `Invoke-CoreScan`.

Scope:

1. New function `Get-WinPulseLatestPublishedVersion` (place it near the other
   network/util helpers): downloads ONLY enough of the published script to read
   its `$script:WinPulseVersion` line and returns that string, or `$null` on any
   failure. Hard requirements:
   - Wrap everything in try/catch; return `$null` on ANY error (offline, DNS,
     TLS, 404, parse miss). It must be impossible for this to throw.
   - Set `[Net.ServicePointManager]::SecurityProtocol` to include TLS 1.2 the
     same way the existing tool-download path does (grep for the existing
     `SecurityProtocol` usage and match it - do NOT introduce a second pattern).
   - Use a short timeout (e.g. `Invoke-WebRequest -UseBasicParsing -TimeoutSec 3`)
     so a slow/blocked network cannot stall startup. Read the body and regex out
     `\$script:WinPulseVersion\s*=\s*'([^']+)'`; return the capture or `$null`.
   - Do NOT use `Invoke-Expression` and do NOT dot-source the downloaded text
     (project non-goal + safety boundary). Parse the version string textually
     ONLY.
2. New pure helper `Compare-WinPulseVersion -current <string> -latest <string>`
   returning `$true` when `latest` is strictly newer. Compare the numeric
   `MAJOR.MINOR.PATCH` first (split on `.`, cast to `[int]`, guard non-numeric ->
   treat as not-newer), then fall back to the `-YYYYMMDD` date suffix only when
   the numeric parts tie. Must be total: any malformed input returns `$false`.
   This is the unit-test target (see below).
3. Wire a single best-effort call into the interactive startup path only (the
   `Triage` and `Repair` branches, right after the `WinPulse {version}` banner
   line, BEFORE `Invoke-CoreScan`). If `Compare-WinPulseVersion` says newer:
   `Write-Host ('  Update available: {0} (you have {1}) - re-run the one-liner to update.' -f $latest, $current) -ForegroundColor Yellow`
   then a blank line. Skip the check entirely for the non-interactive modes
   (Migration*/W11Readiness/ExportBundle) so scripted/smoke runs make no network
   call. Honor a `WINPULSE_SKIP_UPDATE_CHECK` env var (set -> skip) so the smoke
   harness and offline techs can suppress it; set that env var in
   `tools/Invoke-WinPulseSmokeTest.ps1` next to the existing
   `WINPULSE_ACCESS_GRANTED` line (and remove it in the same cleanup block).
4. Add Pester coverage for `Compare-WinPulseVersion` in the EXISTING
   `tests/WinPulse.Pure.Tests.ps1` (same AST-extraction harness; add the function
   name to the extraction list): newer patch, newer minor, newer major, newer
   date suffix with equal numeric, EQUAL versions -> `$false`, OLDER -> `$false`,
   malformed/empty inputs -> `$false`. Do NOT unit-test the network function.

Acceptance:
- Parser + ASCII clean; `git diff --check` clean.
- All five non-elevated smoke modes exit 0 with NO network call and NO update
  line (the env var suppresses it); confirm and report.
- `tests/Invoke-WinPulseTests.ps1` green; report the Pester summary.
- "Does it bite" check: temporarily make `Compare-WinPulseVersion` return `$true`
  for equal versions, confirm a test FAILS, then revert. Report it.
- Manually confirm the offline path is silent: temporarily point the function at
  a bogus host (or unplug), confirm `Get-WinPulseLatestPublishedVersion` returns
  `$null` and startup proceeds with no notice and no error. Report what you saw.

Out of scope: release tags / GitHub API (a later task may switch the source to a
tags endpoint - keep `Get-WinPulseLatestPublishedVersion` the single seam so that
swap is local), any auto-update or download, changing the exit code, prompting.

### Task C48 - Live/remote migration: reuse planned source counts in verification

Why: `Get-WinPulseCopyVerification` (~L5733) re-enumerates the SOURCE a second
time (`Measure-WinPulseFolderFiltered -path $source`) after the copy. For a
local source that is cheap, but for a remote SMB source
(`\\HOST\C$\Users\...`, the Live migration path) it walks the whole tree over the
wire a second time. The source file/byte counts were already produced once during
the copy. Thread them through so the remote source is enumerated once.

IMPORTANT semantics gotcha - read before coding: the verification's source
measurement applies the COPY EXCLUSIONS (`-excludeFiles`/`-excludeDirs` via
`Get-WinPulseFilteredFiles`). The backup PLAN's per-item `Bytes` come from
`Get-WinPulsePathSize` / `Measure-WinPulseBackupPlanItem`, which use DIFFERENT
exclusion semantics. So you must NOT naively feed the plan's `Bytes` into
verification - that would change what "Verified" means and could mask a real
mismatch. The correct precomputed counts are the FILTERED source measurement
(`Measure-WinPulseFolderFiltered` with the same exclusions), captured once at copy
time. Confirm this by reading both call sites (backup ~L6551, restore ~L7820) and
the Live flow before changing anything.

Scope:

1. Add two optional params to `Get-WinPulseCopyVerification`:
   `[Nullable[int]]$knownSourceFiles = $null` and
   `[Nullable[double]]$knownSourceBytes = $null` (or a single
   `[object]$knownSource` carrying both - your call, but keep it explicit and
   StrictMode-safe). When BOTH are supplied (non-null), skip the
   `Measure-WinPulseFolderFiltered -path $source` call and use the provided
   numbers as `$src.Files`/`$src.Bytes`. When either is absent, behave EXACTLY as
   today (measure the source). The hash-sampling branch still enumerates the
   source on its own and is unaffected - leave it alone; it is opt-in and only
   used when `-hashSampleSize > 0`.
2. At the Live/remote copy site, capture the filtered source measurement that the
   copy already needs (or compute it once with `Measure-WinPulseFolderFiltered`
   using the SAME exclusions the copy used) and pass it into
   `Get-WinPulseCopyVerification` via the new params ONLY for remote/UNC sources.
   Detect "remote" by the source being a UNC path (starts with `\\`) - do not add
   a new flag if a path test suffices; if the Live flow already tracks a
   `SourceHost`/remote marker, reuse that instead. For LOCAL sources, change
   nothing about the call (keep re-measuring; it is cheap and avoids any risk).
3. Do NOT change the returned object shape or any field name - reports and
   manifests consume `SourceFiles`/`SourceBytes`/`Status`/`Note` and the two
   report exporters must stay compatible. The only behavioral change is WHERE the
   source numbers come from for remote sources.

Acceptance:
- Parser + ASCII clean; `git diff --check` clean.
- All five non-elevated smoke modes exit 0 (the smoke harness drives a real
  local backup+restore on a temp fixture - those must still verify Verified with
  the unchanged local path). Report the output.
- Add/extend Pester coverage in `tests/WinPulse.Pure.Tests.ps1` for the new
  override: with `knownSourceFiles`/`knownSourceBytes` supplied, the function
  returns those as `SourceFiles`/`SourceBytes` WITHOUT touching the source path
  (point `-source` at a non-existent path to prove it was not enumerated), and
  with them absent it still measures a real temp fixture. Keep `-hashSampleSize 0`
  in these tests. Report the Pester summary.
- "Does it bite" check: temporarily ignore the override (always re-measure),
  confirm the new "did not enumerate source" test FAILS, then revert. Report it.

Out of scope: implementing remote VSS / locked-file handling, changing the copy
engine, the dry-run sizing path, hash sampling behavior, report layout.

## Work Queue - Batch 11 (queued 2026-06-23)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), ONE commit, do NOT
push to main, do NOT bump the version, keep `bootstrap.ps1` ASCII-only /
StrictMode-safe / PS 5.1, bracket notation for hashtable access. Report changes
plus full test output. Stop and ask if anything is ambiguous. PREREQUISITE: C48
(Batch 10) must be in already - this finishes the optimization it set up.

### Task C49 - Make remote verification a real wire saving via robocopy summary counts

Why: C48 added the `-knownSourceFiles`/`-knownSourceBytes` seam to
`Get-WinPulseCopyVerification` and wired the backup caller to pass precomputed
filtered source counts for UNC sources. But it obtains those counts with a NEW
`Measure-WinPulseFolderFiltered` walk BEFORE `robocopy` and reuses it in verify -
so the number of times the remote source is enumerated over the wire is UNCHANGED
(pre-measure walk + robocopy walk == old robocopy walk + verify walk). The seam is
correct; the count SOURCE is not. robocopy already enumerates and copies the
source once and prints a summary table with total Files and Bytes copied. Parse
THAT and feed it through the existing seam, eliminating the separate measure walk.

Read first (do not change behavior until you understand both):
- `Invoke-WinPulseRobocopy` (grep for the function) returns
  `[ordered]@{ ExitCode; Success; Partial; DryRun; LogPath; Note }` and does NOT
  currently parse copied-file/byte totals. It writes a `$logPath`.
- `Invoke-WinPulseMigrationBackup`: the C48 block that sets `$knownSourceMeasure`
  via `Measure-WinPulseFolderFiltered` before the robocopy call (UNC-only), then
  passes it into `Get-WinPulseCopyVerification`.
- `Get-WinPulseCopyVerification`: the `-knownSourceFiles`/`-knownSourceBytes`
  override branch (leave its signature and the override logic AS IS).

Scope:

1. Add a robocopy summary parser. Prefer a small PURE helper
   `Get-WinPulseRobocopySummaryCounts -logPath <path>` (or `-logText <string>`)
   that reads the robocopy log/output and returns
   `[pscustomobject][ordered]@{ Files = <int>; Bytes = <double> }` for the COPIED
   totals, or `$null` if the summary cannot be parsed. robocopy's summary block is
   the `Total / Copied / Skipped / Mismatch / FAILED / Extras` table; the "Copied"
   column of the "Files :" and "Bytes :" rows is what verification's expected
   source set corresponds to (it copies exactly the filtered set). Note the
   "Bytes" row uses human units (e.g. `1.5 m`, `812 k`, `0`) and may be a bare
   number; parse defensively and return `$null` on anything you cannot read
   cleanly. Make it total: malformed/missing input -> `$null`, never throws.
   EXCLUSION ALIGNMENT: robocopy is already invoked with the SAME `/XF`/`/XD`
   exclusions verification uses, so its Copied totals match the filtered source
   set by construction. Call this out in a short comment so the equivalence is not
   re-broken later.
2. Have `Invoke-WinPulseRobocopy` parse its own summary on a real (non-dry-run)
   run and ADD two fields to its returned object: `CopiedFiles` and `CopiedBytes`
   (`$null` when dry-run or unparseable). Do NOT remove or rename existing fields
   (reports/manifests depend on the shape). If you parse from the log file, read
   it after robocopy exits; if you already capture stdout lines, parse those.
3. In `Invoke-WinPulseMigrationBackup`: DELETE the C48 pre-robocopy
   `Measure-WinPulseFolderFiltered` walk. After the robocopy call, for UNC sources
   only, if `$rc.CopiedFiles`/`$rc.CopiedBytes` are non-null, pass them as
   `-knownSourceFiles`/`-knownSourceBytes` to `Get-WinPulseCopyVerification`. If
   parsing failed (null), FALL BACK to the existing measure path (call verify
   without the known params - it will measure the source itself). Local (non-UNC)
   sources stay exactly as today: no known counts, verify measures locally. Net
   effect: a remote source is now enumerated ONCE (the robocopy copy) instead of
   twice.
4. Partial-copy caution: when robocopy returns Partial (exit 8-15) the Copied
   totals are LESS than the full source set, so using them as the "expected"
   baseline would mask the shortfall and wrongly report Verified. Therefore only
   pass the parsed counts when `$rc.Success` is true (NOT on Partial); on Partial,
   fall back to measuring the source so the existing mismatch detection still
   fires. Document this in a comment.

Tests (extend `tests/WinPulse.Pure.Tests.ps1`, add the parser to the extraction
list):
- `Get-WinPulseRobocopySummaryCounts`: a realistic robocopy summary fixture
  (multi-line, the `Total/Copied/...` table) -> correct Files and Bytes; a
  human-unit Bytes row (`1.5 m`, `812 k`) -> correct byte math; missing summary /
  empty / garbage -> `$null` (and does not throw). ASCII fixtures only.
- Reuse the existing C48 `Get-WinPulseCopyVerification` override tests as-is
  (the seam is unchanged).

Acceptance:
- Parser + ASCII clean; `git diff --check` clean.
- All five non-elevated smoke modes exit 0 (local backup+restore on the temp
  fixture still verifies Verified via the unchanged LOCAL path; this task does not
  touch local sources). Report the output.
- `tests/Invoke-WinPulseTests.ps1` green; report the Pester summary.
- "Does it bite" check: feed `Get-WinPulseRobocopySummaryCounts` a summary with a
  known Files total, temporarily assert the wrong number, confirm it FAILS, revert.
- Confirm by grep that the C48 pre-robocopy `Measure-WinPulseFolderFiltered` walk
  in `Invoke-WinPulseMigrationBackup` is GONE and the counts now come from `$rc`.

Out of scope: changing the verify override logic itself, restore-side counts
(restore is not the remote-pull direction in MVP), report/manifest shape, hash
sampling, dry-run sizing, anything in the copy engine beyond reading robocopy's
own summary.

## Work Queue - Batch 12 (queued 2026-06-23)

Standard rules: sync first (`git checkout dev/migration-preflight-foundation`
then `git merge main --ff-only`; stop if not fast-forward), ONE commit, do NOT
push to main, do NOT bump the version, keep `bootstrap.ps1` ASCII-only /
StrictMode-safe / PS 5.1, bracket notation for hashtable access. Report changes
plus full test output. Stop and ask if anything is ambiguous.

### Task C50 - Make the startup update check asynchronous (zero added startup time)

Why: C47 added a startup "Update available" check, but it runs SYNCHRONOUSLY on
the critical path - `Show-WinPulseUpdateNotice` is called right after the banner
and BEFORE `Invoke-CoreScan`, and it does a blocking `Invoke-WebRequest
-TimeoutSec 3`. Online that is a few hundred ms of serial latency; offline / behind
a proxy / with slow DNS it is a flat ~3s tax before the scan even starts, on an
already slow startup. Move the network call OFF the critical path so it overlaps
the scan (which already takes seconds) and adds effectively zero wall-clock time.

Current shape (read before changing):
- `Get-WinPulseLatestPublishedVersion` - does the ranged `Invoke-WebRequest`
  (`Range: bytes=0-8191`, `-TimeoutSec 3`, TLS 1.2 via `-bor 3072`) and regexes
  out the version string; returns `$null` on any failure.
- `Compare-WinPulseVersion -current -latest` - pure, total comparator.
- `Show-WinPulseUpdateNotice -current` - the synchronous wrapper that honors
  `$env:WINPULSE_SKIP_UPDATE_CHECK`, calls the two above, and `Write-Host`s the
  yellow line. This is what is wired into the `Triage` and `Repair` branches of
  `Invoke-WinPulseMode` (right after the `WinPulse {version}` banner line).
- `Show-WinPulseMainMenu` - the main menu loop (clears the screen each iteration).

Design constraints:
- The web call must run in a background RUNSPACE, not `Start-Job` (a new process
  is heavyweight and defeats the point). Use `[powershell]::Create()` +
  `BeginInvoke()`. The runspace scriptblock must be SELF-CONTAINED (it cannot see
  the script's functions): inline the TLS-1.2 set, the ranged `Invoke-WebRequest`,
  and the version regex directly, all wrapped so it can never throw; it returns the
  latest version string or `$null`. Keep this inline logic byte-for-byte equivalent
  to `Get-WinPulseLatestPublishedVersion` (same URL, range, timeout, regex) so the
  two do not drift - add a comment on each pointing at the other.
- It must be impossible for this to crash or hang startup. Every path wrapped in
  try/catch; the PowerShell instance and its runspace ALWAYS disposed in a
  `finally`; no unbounded waits.
- A flash-then-erase is NOT acceptable: because the menu `Clear-Host`s, you cannot
  just `Write-Host` the notice after the scan and call the menu. The notice must be
  shown PERSISTENTLY. Stash the result in a script-scope field (e.g.
  `$script:WinPulseUpdateAvailable = '<latest>'` or `$null`) and have
  `Show-WinPulseMainMenu` render a single yellow line inside its header (under the
  `Main Menu` breadcrumb) on every loop iteration when it is set. The Repair path
  reuses the same script-scope field if its flow shows the menu; if Repair does not
  render a persistent header, a one-line print after its scan plus the existing
  flow is acceptable - keep Repair changes minimal and say what you did.

Scope:
1. `Start-WinPulseUpdateCheckAsync -current <ver>`: returns immediately with
   `$null` when `$env:WINPULSE_SKIP_UPDATE_CHECK` is set (so smoke/offline never
   spin a runspace). Otherwise create the runspace, `BeginInvoke()` the
   self-contained scriptblock, and return a small handle object
   `[pscustomobject]@{ PowerShell = $ps; Async = $async }` (or `$null` if creation
   threw).
2. `Complete-WinPulseUpdateNotice -handle <h> -current <ver>`: if `$handle` is
   `$null`, return. Otherwise bounded-wait for completion up to a small cap (e.g.
   `$handle.Async.AsyncWaitHandle.WaitOne(250)`) - by the time the scan finishes it
   is almost always already done, so this is normally instant; the cap protects the
   rare slow case so we never re-introduce a multi-second block. If completed,
   `EndInvoke()` to get the latest string, then
   `if (Compare-WinPulseVersion -current $current -latest $latest) {
   $script:WinPulseUpdateAvailable = $latest }`. ALWAYS dispose the PowerShell
   instance (and close/dispose the runspace) in a `finally`; if not completed
   within the cap, give up silently (still dispose). Never throw.
3. Wire-up in `Invoke-WinPulseMode`:
   - `Triage`: replace the synchronous `Show-WinPulseUpdateNotice` call. Before
     `Invoke-CoreScan`: `$updateHandle = Start-WinPulseUpdateCheckAsync -current
     $script:WinPulseVersion`. After `$scan = Invoke-CoreScan` and before
     `Show-WinPulseMainMenu`: `Complete-WinPulseUpdateNotice -handle $updateHandle
     -current $script:WinPulseVersion`.
   - `Repair`: same pattern around its `Invoke-CoreScan`.
4. `Show-WinPulseMainMenu`: after the `Main Menu` breadcrumb line, if
   `$script:WinPulseUpdateAvailable` is a non-empty string, `Write-Host` one yellow
   line: `  Update available: {0} (you have {1}) - re-run the one-liner to update.`
   with `$script:WinPulseUpdateAvailable` and `$script:WinPulseVersion`. Keep the
   exact wording from C47.
5. Initialize `$script:WinPulseUpdateAvailable = $null` near the other script-scope
   state. Remove `Show-WinPulseUpdateNotice` if it has no remaining callers (grep
   to confirm) OR keep it only if something still uses it - do not leave a dead
   function.

Acceptance:
- Parser + ASCII clean; `git diff --check` clean.
- All five non-elevated smoke modes exit 0 with NO network call and NO runspace
  spun (the env var short-circuits `Start-WinPulseUpdateCheckAsync` before it
  creates anything); confirm and report.
- `tests/Invoke-WinPulseTests.ps1` green (the pure `Compare-WinPulseVersion` tests
  still cover the comparison; do NOT unit-test the runspace/network). Report the
  summary.
- Manual timing check: with `WINPULSE_SKIP_UPDATE_CHECK` UNSET and the network
  reachable, confirm the runspace path does not block - i.e. startup proceeds into
  the scan without waiting on the web call (describe what you observed; you do not
  need exact millisecond numbers). Then simulate offline (bogus host in the inline
  block, temporarily) and confirm startup is NOT delayed by ~3s and shows no notice
  / no error. Revert the bogus host. Report both.
- The owner verifies the persistent menu notice visually before any merge - do not
  screenshot it yourself.

Out of scope: changing the URL/source of the version (still raw `main`), release
tags, the comparator logic, the access gate, anything outside the update-notice
path. Do not make the check run on the non-interactive modes.

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
