# WinPulse

Single-file PowerShell IT diagnostics and repair tool for Windows 10/11.

## Run (recommended)

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

## Run from GitHub

```powershell
irm https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1 | iex
```

## Notes

- Only one runtime file exists: `bootstrap.ps1`
- The script auto-elevates to Administrator
- On startup it runs core scan, shows dashboard, and then quick actions/menu
