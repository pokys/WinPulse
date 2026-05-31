# Windows Codex Bootstrap Prompt

Paste this into Codex running on the Windows development machine after cloning
the dev branch.

```text
You are Codex running on a Windows machine. Continue development and validation
of the existing GitHub repository pokys/WinPulse.

Repository state:
- Branch to use: dev/migration-preflight-foundation
- Runtime file: bootstrap.ps1
- Canonical agent instructions: AGENTS.md
- Claude compatibility file: CLAUDE.md points to AGENTS.md
- Primary production launch path must remain:
  irm https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1 | iex

Important constraints:
- Read AGENTS.md first and follow it.
- Do not push to main.
- Do not ship Go EXEs, packed binaries, obfuscation, Defender exclusions,
  AMSI bypasses, credential/password export, browser password export, DPAPI
  secret export, Wi-Fi key export, VPN secret export, or private key export.
- Keep bootstrap.ps1 PowerShell 5.1 compatible and ASCII-only.
- Preserve single-file runtime behavior and auto-elevation.
- MigrationPreflight must remain read-only.

Current goal:
Validate and fix the Migration Preflight Foundation on real Windows PowerShell
5.1. The macOS Codex session could only run static checks, so Windows runtime
testing is required.

Start here:
1. Check the repo:
   git status --short --branch
   git branch --show-current

2. Confirm you are on:
   dev/migration-preflight-foundation

3. Read:
   AGENTS.md
   README.md
   bootstrap.ps1
   tools/Invoke-WinPulseSmokeTest.ps1

4. From an elevated Windows PowerShell 5.1 window, run parser validation:
   $tokens = $null
   $errors = $null
   [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\bootstrap.ps1), [ref]$tokens, [ref]$errors) | Out-Null
   $errors | Format-List *
   if ($errors.Count -gt 0) { throw "PowerShell parser errors found." }

5. Verify bootstrap.ps1 is ASCII-only:
   $bad = Select-String -Path .\bootstrap.ps1 -Pattern '[^\x00-\x7F]'
   if ($bad) { $bad; throw "Non-ASCII characters found in bootstrap.ps1." }

6. Run the smoke wrapper from elevated Windows PowerShell:
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-WinPulseSmokeTest.ps1 -Mode MigrationPreflight

7. Inspect smoke logs:
   Get-ChildItem .\smoke-logs | Sort-Object LastWriteTime -Descending | Select-Object -First 6

8. Inspect latest migration export:
   $latest = Get-ChildItem C:\ProgramData\WinPulse\exports -Directory |
     Where-Object { $_.Name -like 'MigrationPreflight-*' } |
     Sort-Object LastWriteTime -Descending |
     Select-Object -First 1
   $latest.FullName
   Get-ChildItem $latest.FullName -Recurse

9. Validate JSON:
   $jsonPath = Join-Path $latest.FullName 'migration-preflight.json'
   $json = Get-Content $jsonPath -Raw | ConvertFrom-Json
   $json.Tool
   $json.Windows11Readiness
   $json.Migration.RiskSummary

10. Also test:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Mode W11Readiness
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Mode ExportBundle

11. Test default interactive flow enough to confirm it starts:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1

If anything fails:
- Patch the smallest safe fix.
- Keep bootstrap.ps1 ASCII-only and PowerShell 5.1 compatible.
- Re-run parser validation, ASCII validation, and smoke test.
- Report exact files changed, commands run, outputs, and remaining risks.
- Do not commit or push unless explicitly asked.

Known background:
- An earlier local Windows test from a Parallels shared Z: path exposed
  mojibake/parser failures caused by UTF-8 without BOM and Unicode em dashes.
  bootstrap.ps1 has since been converted to ASCII-only.
- Avoid testing from mapped/shared drives when UAC/elevation is involved.
  Prefer a local path such as C:\Users\<user>\source\WinPulse.
```
