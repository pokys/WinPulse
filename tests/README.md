# WinPulse Tests

These are dev-only Pester 5.x tests for pure WinPulse parser and builder
functions. They do not dot-source `bootstrap.ps1`; the test file extracts only
the named functions it needs through the same AST helper pattern used by the
smoke harness.

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-WinPulseTests.ps1
```

Pester 5.x is required. If it is missing, install it with:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```
