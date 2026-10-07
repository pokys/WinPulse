# WinPulse – nálezy auditu seřazené podle ROI

Zdroj: `docs/audit-2026-10-06.md` (3 kola, 50 nálezů). Stav: **čeká na review
vlastníka**. Po review budeme opravovat shora dolů. Sloupec „Stav“ budu
průběžně aktualizovat.

## Jak se ROI počítá

**ROI = (Dopad × Pravděpodobnost) / Náročnost**

| Škála | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| **Dopad (D)** | kosmetika | zmatení, ztráta času | špatný výsledek nebo rozbitý flow | ztráta dat, falešný bezpečnostní závěr | eskalace práv, únik hesel, ztráta dat bez varování |
| **Pravděpodobnost (P)** | vyžaduje útočníka nebo exotickou situaci | občas | u části PC nebo flow | často | při každém běhu nebo na většině PC |
| **Náročnost (N)** | do 1 h, pár řádků | půl dne | den a víc, víc funkcí a testy | – | – |

Při shodě ROI rozhoduje vyšší dopad. Odhad náročnosti počítá s
implementací, Pester testem a smoke během.

**Upozornění k ROI:** vzorec trestá drahé opravy vzácných, ale kritických
rizik. Dva nálezy s dopadem 5 mají nízké ROI jen kvůli náročnosti: H1
(junction/LPE v `ProgramData`) a H2 (neověřené stažené binárky). Doporučuji
je zařadit do první vlny bez ohledu na pořadí. Jsou označené ⚑.

## Pořadí

| # | ID | Nález | D | P | N | ROI | Stav |
|---|----|-------|---|---|---|-----|------|
| 1 | TU3 | Enter v multi-selectu bez zaškrtnutí = zrušení (výběr uživatelů/složek) | 3 | 5 | 1 | **15** | čeká |
| 2 | N1 | Store/AppX oprava ukončí `WindowsTerminal`, tedy i samotný WinPulse | 4 | 3 | 1 | **12** | čeká |
| 3 | H3 | Zálohy v `C:\WinPulseBackups` čitelné a zapisovatelné pro všechny přihlášené uživatele | 4 | 3 | 1 | **12** | čeká |
| 4 | T1 | Dry run nebo druhá záloha přepíše `manifest.json` skutečné zálohy (chybí podsložka s časem) | 4 | 3 | 1 | **12** | čeká |
| 5 | N3 | AV „OK“ při jakékoli registraci třetí strany, `productState` se ignoruje | 4 | 3 | 1 | **12** | čeká |
| 6 | N4 | Ping 1.1.1.1 jako test internetu → repair plán „Network Stack“ smaže statickou IP | 4 | 3 | 1 | **12** | čeká |
| 7 | T6 | winget bez `--exact` (instaluje nebo odinstaluje jiný balíček, falešné „installed“) | 3 | 4 | 1 | **12** | čeká |
| 8 | TU7 | `Q` spustí destruktivní exit cleanup bez dotazu; nekonzistentní potvrzování | 3 | 4 | 1 | **12** | čeká |
| 9 | M5 | Restore, Verify a Apps nevidí zálohy v `C:\WinPulseBackups` | 2 | 5 | 1 | **10** | čeká |
| 10 | TU1 | Výběr zálohy zobrazuje celou cestu jako klávesu, název se uřízne | 2 | 5 | 1 | **10** | čeká (spolu s M5) |
| 11 | M2 | Exit maže celou PS historii účtu + skryté menu „no trace“ | 2 | 5 | 1 | **10** | **rozhodnutí vlastníka** |
| 12 | N5 | Firewall „OFF“ (Critical), když chrání firewall třetí strany | 3 | 3 | 1 | **9** | čeká |
| 13 | TU9 | Ověřit menu ve Windows Terminal (zmizení dashboardu) | 3 | 3 | 1 | **9** | ověření na Windows |
| 14 | M3 | TCP/IP reset, Winsock reset a restart adaptérů jedním stiskem bez varování | 4 | 2 | 1 | **8** | čeká |
| 15 | TU5 | Chybové hlášky (Ninite, Cancelled) se smažou dřív, než jdou přečíst | 2 | 4 | 1 | **8** | čeká |
| 16 | R6 | „Pending reboot“ trvale kvůli `PendingFileRenameOperations` | 2 | 4 | 1 | **8** | čeká |
| 17 | L7 | README a AGENTS.md neodpovídají realitě (cesty, módy, „no binary payloads“) | 2 | 4 | 1 | **8** | čeká |
| 18 | N2 | Záloha Firefoxu, Chrome a AppData obsahuje hesla a DPAPI klíče | 5 | 3 | 2 | **7.5** | čeká |
| 19 | R1 | Záloha ignoruje OneDrive KFM a přesměrované složky, takže dokumenty chybí | 5 | 4 | 3 | **6.7** | čeká |
| 20 | M1 | Elevace: `E:\` rozbije argumenty; TOCTOU temp skriptu | 3 | 2 | 1 | **6** | čeká |
| 21 | L4 | Ninite bez kontroly podpisu, pevný název v `bin` | 3 | 2 | 1 | **6** | čeká (spolu s H2) |
| 22 | T7 | Disk test měří cache, „RAM test“ netestuje RAM | 2 | 3 | 1 | **6** | čeká |
| 23 | T8 | DISM/SFC/netsh/Ninite hlásí úspěch bez kontroly exit kódů | 2 | 3 | 1 | **6** | čeká |
| 24 | N6 | Office: `FORCEAPPSHUTDOWN` zavře neuložené dokumenty; ODT bez podpisu; product ID | 3 | 2 | 1 | **6** | čeká |
| 25 | R5 | Deep suite: nafouknuté skóre, log krok téměř vždy CRIT, bez pageru | 2 | 3 | 1 | **6** | čeká |
| 26 | R3 | Exit smaže exportované reporty; Bundle ZIP nebalí HTML/JSON | 3 | 4 | 2 | **6** | čeká |
| 27 | H4 | Restore věří manifestu (path traversal, zápis kamkoli jako admin) | 5 | 1 | 1 | **5** | čeká, ⚑ doporučeno do 1. vlny se zálohami |
| 28 | L8 | Chybí CI (parser, ASCII, Pester, smoke) | 3 | 5 | 3 | **5** | čeká |
| 29 | L6 | Čeština v anglickém UI, `lang="cs"`, Back na `B` | 1 | 5 | 1 | **5** | čeká |
| 30 | R7 | „Weak service configs“: falešné nálezy na každém `svchost -k` | 1 | 5 | 1 | **5** | čeká |
| 31 | M4 | Live/restore: neexistující profil, pozdní validace RestoreAsUser, fáze 2 i po chybě | 4 | 3 | 3 | **4** | čeká |
| 32 | T4 | Hub, findings a deep suite mají tři různé sady prahů | 2 | 4 | 2 | **4** | čeká |
| 33 | T2 | `/LOG+` + parser čte první souhrn (zastaralé počty) | 2 | 2 | 1 | **4** | čeká (spolu s T1) |
| 34 | T5 | Chybějící winget blokuje i Ninite a Chocolatey | 2 | 2 | 1 | **4** | čeká |
| 35 | M6 | Chocolatey přes `iex` + `--force` | 2 | 2 | 1 | **4** | čeká |
| 36 | R2 | Profily z `C:\Users` místo `ProfileList`; pomalé 8× měření | 2 | 4 | 2 | **4** | čeká |
| 37 | H1 | Junction nebo podvržený EXE v `ProgramData\WinPulse` → mazání a spuštění jako admin | 5 | 2 | 3 | **3.3** | čeká, ⚑ doporučeno do 1. vlny |
| 38 | H2 | Stažené nástroje bez SHA256/podpisu, HTTP fallback, scrapování mirrorů | 5 | 2 | 3 | **3.3** | čeká, ⚑ doporučeno do 1. vlny |
| 39 | T3 | Cíl zálohy uvnitř zdroje (rekurzivní kopie) | 3 | 1 | 1 | **3** | čeká |
| 40 | TU2 | Single-select neumí scrollovat | 2 | 3 | 2 | **3** | čeká |
| 41 | L1 | Vzdálená verifikace bere „Copied“ místo „Total“; parser jen anglicky | 2 | 1 | 1 | **2** | čeká |
| 42 | L2 | Verifikace jen agregátem (existující soubory maskují chybějící) | 2 | 2 | 2 | **2** | čeká |
| 43 | R4 | Verify je jen kontrola počtů, ne integrity | 3 | 2 | 3 | **2** | čeká |
| 44 | TU8 | `winget list` pro každý balíček zvlášť, bez indikace průběhu | 1 | 4 | 2 | **2** | čeká |
| 45 | R8 | Memory Diagnostic: „reboot now“ nerestartuje | 1 | 2 | 1 | **2** | čeká |
| 46 | TU6 | Stránkovaný box jen dopředu, ořez dlouhých řádků | 1 | 3 | 2 | **1.5** | čeká |
| 47 | L5 | `continue` uvnitř `switch` (funguje náhodou) | 1 | 1 | 1 | **1** | čeká |
| 48 | TU4 | Multi-select fallback bez interaktivní konzole (číslování, separátory) | 1 | 1 | 1 | **1** | čeká |
| 49 | TU10 | Mrtvý kód (`Read-WinPulseSelection`, `Invoke-WinGetInstall`) | 1 | 1 | 1 | **1** | čeká |
| 50 | L3 | Soft access gate je offline brute-forcovatelný | 1 | 1 | 1 | **1** | navrhuji neopravovat (záměrně soft) |

Celkem 50 řádků = všech 50 nálezů ze 3 kol. TU9 je ověření na Windows, ne
samotná oprava.

## Navržené vlny (balíky podle ROI a sdíleného kódu)

Nálezy, které mění stejný kód, jsou sloučené do jednoho úkolu, aby se
stejná funkce neotvírala dvakrát.

| Vlna | Obsah | Proč takto |
|------|-------|-----------|
| **1 – rychlé výhry (každý ≤ 1 h)** | TU3, N1, H3, T1+T2, N3, N4, T6, TU7, M5+TU1, N5, M3, TU5, R6 | ROI 8–15, malé diffy, velký dojem i bezpečnost |
| **1⚑ – bezpečnostní dluh** | H1, H2+L4, H4, N2 | Dopad 5; nízké ROI jen kvůli náročnosti |
| **2 – správnost migrace** | R1, M4, T3, R2, M1 | Nejvíc práce, ale ztráta dat při výměně PC |
| **3 – kvalita a důvěryhodnost výsledků** | T4, T7, T8, R5, R7, R8, N6, T5, M6, R3, L7, L6 | Odstraní falešné nálezy a matoucí výstupy |
| **4 – infrastruktura a UX polish** | L8 (CI), TU2, TU6, TU8, L1, L2, R4, L5, TU4, TU10 | Až bude jádro opravené |

## Co od tebe potřebuji při review

1. U každého řádku: **opravit / neopravovat / jinak** (stačí poznámka
   do sloupce Stav nebo zpráva).
2. Rozhodnutí M2 (historie a skryté menu) a tři další otázky z
   `audit-2026-10-06.md` (NirSoft credential nástroje, SHA256 vs.
   vypuštění nepodepsaných nástrojů, povinný exit cleanup).
3. Ověřit na Windows Terminal TU9. Stačí mi popsat, jestli po startu
   zmizí dashboard, když se pod něj vykreslí menu.
