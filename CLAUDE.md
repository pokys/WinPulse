# WinPulse — poznámky pro Claude

## O projektu

WinPulse je PowerShell-based Windows diagnostický/IT nástroj s TUI (Text User Interface).
Hlavní soubor: `bootstrap.ps1`

## Důležité technické poznámky

- `Set-StrictMode -Version Latest` je zapnutý — vždy používat bracket notaci `$item['Key']` místo `$item.Key` pro hashtable přístupy
- Menu funkce: `Select-WinPulseMenuItem` (single-select) a `Select-WinPulseMultiMenuItem` (multi-select s Space toggle)
- Instalace vždy v separátním PowerShell okně (`Start-Process powershell -Wait`) aby crash instalátoru neshodil appku
- Šířka boxů: 88 znaků

## Potenciální nápady na budoucí upgrade

### Podpora myši v TUI menu
Klikání myší v `Select-WinPulseMenuItem` a `Select-WinPulseMultiMenuItem`.

Implementace přes Win32 P/Invoke:
- `ReadConsoleInput` z `kernel32.dll` místo `ReadKey()` — vrací keyboard i mouse eventy
- `SetConsoleMode` s `ENABLE_MOUSE_INPUT`
- C# struct `INPUT_RECORD` s union typem pro mouse/keyboard
- Při vykreslování uložit Y-souřadnici každé položky → mapovat klik na položku

Chování:
- Single-select: levý klik = vybrat a potvrdit
- Multi-select: levý klik = toggle, klik na potvrzovací řádek = confirm
- Scroll kolečkem pro dlouhé menu (Ninite katalog má 70+ položek)

Poznámka: funguje v klasickém PowerShell okně; Windows Terminal může vyžadovat extra nastavení.
